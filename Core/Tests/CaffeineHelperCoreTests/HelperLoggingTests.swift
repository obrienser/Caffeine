import Foundation
import Testing
import CaffeineLogging
import CaffeineServiceProtocol
@testable import CaffeineHelperCore

private actor LoggedBackend: RuntimeSleepBackend {
    var enableError: ServiceFailure?
    var disableError: ServiceFailure?
    func configure(enableError: ServiceFailure? = nil, disableError: ServiceFailure? = nil) {
        self.enableError = enableError; self.disableError = disableError
    }
    func recover() async throws {}
    func enable(closedLidMode: Bool) async throws { if let enableError { throw enableError } }
    func disable() async throws { if let disableError { throw disableError } }
}

private final class LoggedTime: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Double = 0
    var source: HelperTimeSource {
        HelperTimeSource(continuousSeconds: { self.lock.withLock { self.now } }, awakeSeconds: { self.lock.withLock { self.now } })
    }
    func advance(_ seconds: Double) { lock.withLock { now += seconds } }
}

private struct Logged {
    let sink = MemoryLogSink()
    let backend = LoggedBackend()
    let time = LoggedTime()
    let authority: HelperSessionAuthority
    let connection = UUID(), generation = UUID()

    init() {
        authority = HelperSessionAuthority(backend: backend, timeSource: time.source, log: EventLog(sinks: [sink]))
    }
    func send(_ action: ServiceAction, revision: UInt64, duration: Int = 0) async -> ServiceReply {
        await authority.handle(.init(action: action, generation: generation, revision: revision, onlyWhenCharging: false,
                                     closedLidMode: true, durationSeconds: duration), connectionID: connection)
    }
    /// What the file keeps: everything except repetitive detail.
    var kept: [LogEntry] { sink.entries.filter { $0.level >= .info } }
    func contains(_ level: LogLevel, _ text: String) -> Bool {
        sink.entries.contains { $0.level == level && $0.message.contains(text) }
    }
}

@Suite struct HelperLoggingTests {
    @Test func aSessionIsRecordedFromRequestToRelease() async {
        let f = Logged()
        await f.authority.prepare()
        await f.authority.powerSourceChanged(.external)
        #expect(f.contains(.notice, "Recovery finished") && f.contains(.info, "Power source: unknown → external"))

        _ = await f.send(.start, revision: 1, duration: 900)
        let session = String(f.generation.uuidString.prefix(8))
        #expect(f.contains(.notice, "Accepted start from connection \(f.connection.uuidString.prefix(8)), revision 1, session \(session), timer 900 s, only when charging off, Closed Lid Mode on"))
        #expect(f.contains(.notice, "The hold is active and verified, Closed Lid Mode on"))
        #expect(f.contains(.notice, "Answered start") && f.contains(.notice, "phase active"))

        _ = await f.send(.stop, revision: 2)
        #expect(f.contains(.notice, "Session \(session) ended: stop requested"))
        #expect(f.contains(.notice, "The hold is released and verified"))
        #expect(!f.sink.entries.contains { $0.level >= .error })
        // Identifiers are shortened; a full session identifier is never written.
        #expect(!f.sink.entries.contains { $0.message.contains(f.generation.uuidString) })
    }

    @Test func routineRenewalsAndStatusReadsStayOutOfTheFile() async {
        let f = Logged()
        await f.authority.prepare()
        await f.authority.powerSourceChanged(.external)
        _ = await f.send(.start, revision: 1)
        let before = f.kept.count
        for revision in 2..<40 {
            _ = await f.send(.heartbeat, revision: UInt64(revision))
            _ = await f.authority.handle(.init(action: .status), connectionID: f.connection)
            await f.authority.powerSourceChanged(.external)
            await f.authority.tick()
            _ = await f.authority.retireIfSettled()
        }
        #expect(f.kept.count == before)
        #expect(f.contains(.debug, "Accepted heartbeat") && f.contains(.debug, "Answered status"))
    }

    @Test func everyReasonForEndingASessionIsNamed() async {
        let expired = Logged()
        await expired.authority.prepare()
        await expired.authority.powerSourceChanged(.external)
        _ = await expired.send(.start, revision: 1, duration: 900)
        expired.time.advance(21)
        await expired.authority.tick()
        #expect(expired.contains(.notice, "ended: supervision lease expired"))
        let late = await expired.send(.heartbeat, revision: 2)
        #expect(late.failure?.code == .notOwner && expired.contains(.info, "Rejected heartbeat"))

        let timed = Logged()
        await timed.authority.prepare()
        await timed.authority.powerSourceChanged(.external)
        _ = await timed.send(.start, revision: 1, duration: 900)
        for second in 1...180 {
            timed.time.advance(5)
            _ = await timed.send(.heartbeat, revision: UInt64(second + 1))
        }
        #expect(timed.contains(.notice, "ended: timer expired"))

        let closed = Logged()
        await closed.authority.prepare()
        await closed.authority.powerSourceChanged(.external)
        _ = await closed.send(.start, revision: 1)
        await closed.authority.connectionInvalidated(closed.connection)
        #expect(closed.contains(.info, "Connection \(closed.connection.uuidString.prefix(8)) ended"))
        #expect(closed.contains(.notice, "ended: owner disconnected"))

        let stopping = Logged()
        await stopping.authority.prepare()
        await stopping.authority.powerSourceChanged(.external)
        _ = await stopping.send(.start, revision: 1)
        await stopping.authority.shutdown()
        #expect(stopping.contains(.notice, "The service is stopping") && stopping.contains(.notice, "ended: service stopping"))
        #expect(stopping.sink.flushes == 1)
    }

    @Test func failuresAndRefusalsAreErrors() async {
        let f = Logged()
        await f.authority.prepare()
        await f.authority.powerSourceChanged(.external)
        await f.backend.configure(enableError: .init(.externalOverride, "Sleep is already disabled by another setting."))
        _ = await f.send(.start, revision: 1)
        #expect(f.contains(.error, "Applying the hold failed: externalOverride – Sleep is already disabled by another setting."))
        #expect(f.contains(.notice, "ended: activation failed"))

        await f.backend.configure()
        let other = UUID()
        _ = await f.authority.handle(.init(action: .start, generation: UUID(), revision: 1, onlyWhenCharging: false,
                                           closedLidMode: true, durationSeconds: 123), connectionID: other)
        #expect(f.contains(.error, "Rejected start from connection \(other.uuidString.prefix(8)), revision 1: invalidRequest"))
        _ = await f.authority.handle(.init(action: .start, generation: UUID(), revision: 1, onlyWhenCharging: false,
                                           closedLidMode: true, durationSeconds: 0, version: 7), connectionID: other)
        #expect(f.contains(.error, "protocol 7, this service uses \(CaffeineServiceIdentity.protocolVersion)"))

        let cleanup = Logged()
        await cleanup.authority.prepare()
        await cleanup.authority.powerSourceChanged(.external)
        _ = await cleanup.send(.start, revision: 1)
        await cleanup.backend.configure(disableError: .init(.cleanupRequired, "Restoration is unconfirmed."))
        _ = await cleanup.send(.stop, revision: 2)
        #expect(cleanup.contains(.error, "Releasing the hold failed; cleanup is unresolved"))
    }

    @Test func retirementIsRecordedOnceAccepted() async {
        let f = Logged()
        await f.authority.prepare()
        _ = await f.send(.start, revision: 1)
        #expect(await !f.authority.retireIfSettled())
        #expect(f.contains(.debug, "Retirement deferred") && !f.contains(.notice, "Retiring"))
        _ = await f.send(.stop, revision: 2)
        #expect(await f.authority.retireIfSettled())
        #expect(f.contains(.notice, "Retiring: the executable was replaced and the service is settled"))
    }

    @Test func withoutALogTheAuthorityBehavesTheSame() async {
        let backend = LoggedBackend()
        let authority = HelperSessionAuthority(backend: backend)
        await authority.prepare()
        await authority.powerSourceChanged(.external)
        let generation = UUID(), connection = UUID()
        let reply = await authority.handle(.init(action: .start, generation: generation, revision: 1, onlyWhenCharging: false,
                                                 closedLidMode: true, durationSeconds: 0), connectionID: connection)
        #expect(reply.snapshot.phase == .active && reply.failure == nil)
    }
}
