import Foundation
import Testing
import CaffeineServiceProtocol
@testable import CaffeineHelperCore

private final class FakeExecutable: HelperExecutableInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var current: HelperExecutableIdentity?
    private var valid = false
    private var afterValidation: HelperExecutableIdentity?
    private var count = 0

    init(_ inode: UInt64?) { current = inode.map(Self.file) }

    static func file(_ inode: UInt64) -> HelperExecutableIdentity {
        .init(device: 1, inode: inode, size: 4_096, modifiedSeconds: 100, modifiedNanoseconds: 0)
    }
    var validations: Int { lock.withLock { count } }
    func place(_ inode: UInt64?, valid: Bool = false) {
        lock.withLock { current = inode.map(Self.file); self.valid = valid }
    }
    func setValid(_ valid: Bool) { lock.withLock { self.valid = valid } }
    func replaceDuringValidation(with inode: UInt64) { lock.withLock { afterValidation = Self.file(inode) } }

    func identity() -> HelperExecutableIdentity? { lock.withLock { current } }
    func hasValidSignature() -> Bool {
        lock.withLock {
            count += 1
            if let afterValidation { current = afterValidation; self.afterValidation = nil }
            return valid
        }
    }
}

/// Swift Testing evaluates expectations through immutable captures.
private final class Probe {
    private var monitor: HelperReplacementMonitor
    init(_ file: FakeExecutable) { monitor = HelperReplacementMonitor(executable: file) }
    func ready() -> Bool { monitor.replacementIsReady() }
}

@Suite struct HelperReplacementMonitorTests {
    @Test func unchangedExecutableIsNeverValidatedOrReplaced() {
        let file = FakeExecutable(7)
        file.setValid(true)
        let monitor = Probe(file)
        for _ in 0..<50 { #expect(!monitor.ready()) }
        #expect(file.validations == 0)
    }

    @Test func unknownLaunchFileNeverAuthorizesRetirement() {
        let file = FakeExecutable(nil)
        let monitor = Probe(file)
        file.place(8, valid: true)
        for _ in 0..<50 { #expect(!monitor.ready()) }
        #expect(file.validations == 0)
    }

    @Test func settledSignedReplacementIsReadyAfterASecondObservation() {
        let file = FakeExecutable(7)
        let monitor = Probe(file)
        file.place(8, valid: true)
        #expect(!monitor.ready())
        #expect(file.validations == 0)
        #expect(monitor.ready())
        for _ in 0..<20 { #expect(monitor.ready()) }
        #expect(file.validations == 1)
    }

    @Test func copyInProgressAndRemovedBundleAreNotReplacements() {
        let file = FakeExecutable(7)
        let monitor = Probe(file)
        for inode in UInt64(8)..<40 {
            file.place(inode, valid: true)
            #expect(!monitor.ready())
        }
        file.place(nil)
        for _ in 0..<5 { #expect(!monitor.ready()) }
        #expect(file.validations == 0)
        // The original file returning is not a replacement either.
        file.place(7, valid: true)
        for _ in 0..<5 { #expect(!monitor.ready()) }
        #expect(file.validations == 0)
    }

    @Test func rejectedReplacementIsRevalidatedOnlyOccasionally() {
        let file = FakeExecutable(7)
        let monitor = Probe(file)
        file.place(8, valid: false)
        #expect(!monitor.ready())
        #expect(!monitor.ready())
        #expect(file.validations == 1)
        for _ in 0..<HelperReplacementMonitor.checksBetweenValidations { #expect(!monitor.ready()) }
        #expect(file.validations == 1)
        file.setValid(true)
        #expect(monitor.ready())
        #expect(file.validations == 2)
    }

    @Test func changeDuringValidationIsNotAccepted() {
        let file = FakeExecutable(7)
        let monitor = Probe(file)
        file.place(8, valid: true)
        file.replaceDuringValidation(with: 9)
        #expect(!monitor.ready())
        #expect(!monitor.ready())
        #expect(file.validations == 1)
        // The newer file starts its own two observations.
        #expect(!monitor.ready())
        #expect(monitor.ready())
        #expect(file.validations == 2)
    }
}

private actor RetirementBackend: RuntimeSleepBackend {
    var calls: [String] = []
    var recoveryError: ServiceFailure?
    var disableError: ServiceFailure?
    var enableContinuation: CheckedContinuation<Void, Never>?
    var suspendEnable = false

    func configure(recoveryError: ServiceFailure? = nil, disableError: ServiceFailure? = nil, suspendEnable: Bool = false) {
        self.recoveryError = recoveryError; self.disableError = disableError; self.suspendEnable = suspendEnable
    }
    func recover() async throws {
        calls.append("recover")
        if let recoveryError { throw recoveryError }
    }
    func enable(closedLidMode: Bool) async throws {
        calls.append("enable")
        if suspendEnable { await withCheckedContinuation { enableContinuation = $0 } }
    }
    func disable() async throws {
        calls.append("disable")
        if let disableError { throw disableError }
    }
    var enableIsSuspended: Bool { enableContinuation != nil }
    func finishEnable() {
        let continuation = enableContinuation
        enableContinuation = nil
        suspendEnable = false
        continuation?.resume()
    }
}

private final class RetirementTime: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Double = 0
    var source: HelperTimeSource {
        HelperTimeSource(continuousSeconds: { self.lock.withLock { self.now } },
                         awakeSeconds: { self.lock.withLock { self.now } })
    }
    func advance(_ seconds: Double) { lock.withLock { now += seconds } }
}

@Suite struct HelperRetirementTests {
    private func request(_ action: ServiceAction, _ generation: UUID, revision: UInt64,
                         charging: Bool = false) -> ServiceRequest {
        .init(action: action, generation: generation, revision: revision, onlyWhenCharging: charging,
              closedLidMode: true, durationSeconds: 0)
    }

    @Test func settledHelperRetiresOnceAndRefusesLaterSessions() async {
        let backend = RetirementBackend()
        let authority = HelperSessionAuthority(backend: backend)
        await authority.prepare()
        #expect(await authority.retireIfSettled())
        #expect(await !authority.retireIfSettled())
        let reply = await authority.handle(request(.start, UUID(), revision: 1), connectionID: UUID())
        #expect(reply.failure?.code == .unavailable)
        #expect(!reply.snapshot.requested && !reply.snapshot.readyForSession)
        #expect(await backend.calls == ["recover"])
    }

    @Test func activeAndWaitingSessionsDeferRetirementUntilStopped() async {
        for power in [ServicePowerSource.external, .battery] {
            let backend = RetirementBackend()
            let authority = HelperSessionAuthority(backend: backend)
            let connection = UUID(), generation = UUID()
            await authority.prepare()
            await authority.powerSourceChanged(power)
            let started = await authority.handle(request(.start, generation, revision: 1, charging: true), connectionID: connection)
            #expect(started.snapshot.requested)
            #expect(await !authority.retireIfSettled())
            // A refused retirement must leave the live session fully usable.
            let renewed = await authority.handle(request(.heartbeat, generation, revision: 2), connectionID: connection)
            #expect(renewed.failure == nil && renewed.snapshot.requested)
            _ = await authority.handle(request(.stop, generation, revision: 3), connectionID: connection)
            #expect(await authority.retireIfSettled())
        }
    }

    @Test func expiredOwnerIsCleanedUpBeforeRetirement() async {
        let backend = RetirementBackend(), time = RetirementTime()
        let authority = HelperSessionAuthority(backend: backend, timeSource: time.source)
        await authority.prepare()
        await authority.powerSourceChanged(.external)
        _ = await authority.handle(request(.start, UUID(), revision: 1), connectionID: UUID())
        #expect(await !authority.retireIfSettled())
        time.advance(21)
        // The lapsed owner's hold is released before the helper may exit.
        #expect(await authority.retireIfSettled())
        #expect(await backend.calls == ["recover", "enable", "disable"])
    }

    @Test func unresolvedRecoveryAndCleanupBlockRetirement() async {
        let failedRecovery = RetirementBackend()
        await failedRecovery.configure(recoveryError: .init(.cleanupRequired, "Previous recovery is unfinished."))
        let blocked = HelperSessionAuthority(backend: failedRecovery)
        await blocked.prepare()
        #expect(await !blocked.retireIfSettled())

        let failedCleanup = RetirementBackend()
        let authority = HelperSessionAuthority(backend: failedCleanup)
        let connection = UUID(), generation = UUID()
        await authority.prepare()
        await authority.powerSourceChanged(.external)
        _ = await authority.handle(request(.start, generation, revision: 1), connectionID: connection)
        await failedCleanup.configure(disableError: .init(.cleanupRequired, "Restoration is unconfirmed."))
        let stopped = await authority.handle(request(.stop, generation, revision: 2), connectionID: connection)
        #expect(stopped.snapshot.phase == .cleanupRequired)
        #expect(await !authority.retireIfSettled())
    }

    @Test func retirementWaitsForAPendingActivationAndThenDefers() async throws {
        let backend = RetirementBackend()
        let authority = HelperSessionAuthority(backend: backend)
        let connection = UUID(), generation = UUID()
        await authority.prepare()
        await authority.powerSourceChanged(.external)
        await backend.configure(suspendEnable: true)
        let start = Task { await authority.handle(request(.start, generation, revision: 1), connectionID: connection) }
        for _ in 0..<10_000 where await !backend.enableIsSuspended { await Task.yield() }
        #expect(await backend.enableIsSuspended)
        // The decision follows the operation in progress; it never interrupts it.
        let retirement = Task { await authority.retireIfSettled() }
        for _ in 0..<1_000 { await Task.yield() }
        #expect(await backend.calls == ["recover", "enable"])
        await backend.finishEnable()
        #expect(await start.value.snapshot.phase == .active)
        #expect(await !retirement.value)
        #expect(await authority.snapshot().requested)
        #expect(await backend.calls == ["recover", "enable"])
    }
}
