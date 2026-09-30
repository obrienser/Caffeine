import Foundation
import Testing
import CaffeineServiceProtocol
@testable import CaffeineHelperCore

private final class TestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var continuous: Double = 0
    private var awake: Double = 0
    var source: HelperTimeSource {
        HelperTimeSource(continuousSeconds: { self.lock.withLock { self.continuous } },
                         awakeSeconds: { self.lock.withLock { self.awake } })
    }
    func advance(_ seconds: Double, asleep: Bool = false) {
        lock.withLock {
            continuous += seconds
            if !asleep { awake += seconds }
        }
    }
}

private actor TestBackend: RuntimeSleepBackend {
    var calls: [String] = []
    var held = false
    var modes: [Bool] = []
    var enableError: ServiceFailure?
    var disableError: ServiceFailure?
    var recoveryError: ServiceFailure?
    var suspendEnable = false
    var suspendDisable = false
    var enableContinuation: CheckedContinuation<Void, Never>?
    var disableContinuation: CheckedContinuation<Void, Never>?
    var concurrentOperations = 0
    var maximumConcurrentOperations = 0

    func configure(enableError: ServiceFailure? = nil, disableError: ServiceFailure? = nil,
                   recoveryError: ServiceFailure? = nil, suspendEnable: Bool = false,
                   suspendDisable: Bool = false) {
        self.enableError = enableError
        self.disableError = disableError
        self.recoveryError = recoveryError
        self.suspendEnable = suspendEnable
        self.suspendDisable = suspendDisable
    }
    func begin(_ name: String) {
        calls.append(name)
        concurrentOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, concurrentOperations)
    }
    func recover() async throws {
        begin("recover")
        defer { concurrentOperations -= 1 }
        if let recoveryError { throw recoveryError }
        held = false
    }
    func enable(closedLidMode: Bool) async throws {
        modes.append(closedLidMode)
        begin("enable")
        defer { concurrentOperations -= 1 }
        if suspendEnable { await withCheckedContinuation { enableContinuation = $0 } }
        held = true
        if let enableError { throw enableError }
    }
    func disable() async throws {
        begin("disable")
        defer { concurrentOperations -= 1 }
        if suspendDisable { await withCheckedContinuation { disableContinuation = $0 } }
        if let disableError { throw disableError }
        held = false
    }
    func finishEnable() {
        let continuation = enableContinuation
        enableContinuation = nil
        suspendEnable = false
        continuation?.resume()
    }
    func finishDisable() {
        let continuation = disableContinuation
        disableContinuation = nil
        suspendDisable = false
        continuation?.resume()
    }
    var enableIsSuspended: Bool { enableContinuation != nil }
    var disableIsSuspended: Bool { disableContinuation != nil }
}

private struct Fixture {
    let backend: TestBackend
    let time: TestTime
    let authority: HelperSessionAuthority
    let connection = UUID()
    let generation = UUID()
    init() {
        backend = TestBackend()
        time = TestTime()
        authority = HelperSessionAuthority(backend: backend, timeSource: time.source)
    }
    func ready(_ power: ServicePowerSource = .external) async {
        await authority.prepare()
        await authority.powerSourceChanged(power)
    }
    func send(_ action: ServiceAction, revision: UInt64 = 1, duration: Int = 0,
              charging: Bool = false, closedLidMode: Bool = true) async -> ServiceReply {
        await authority.handle(.init(action: action, generation: generation, revision: revision,
                                     onlyWhenCharging: charging, closedLidMode: closedLidMode, durationSeconds: duration),
                               connectionID: connection)
    }
}

private func waitUntil(_ condition: () async -> Bool) async throws {
    for _ in 0..<10_000 {
        if await condition() { return }
        await Task.yield()
    }
    throw ServiceFailure(.unavailable, "The expected suspended operation did not occur.")
}

@Test func startupRecoversAndNeverResumesAnOldSession() async {
    let f = Fixture()
    await f.ready()
    let snapshot = await f.authority.snapshot()
    #expect(snapshot.phase == .off)
    #expect(snapshot.readyForSession)
    #expect(!snapshot.requested)
    #expect(await f.backend.calls == ["recover"])
}

@Test func activeStartAndIdempotentStop() async {
    let f = Fixture()
    await f.ready()
    #expect(await f.send(.start).snapshot.phase == .active)
    #expect(await !f.authority.snapshot().readyForSession)
    #expect(await f.send(.stop, revision: 2).snapshot.phase == .off)
    #expect(await f.send(.stop, revision: 2).failure == nil)
    #expect(await f.backend.calls == ["recover", "enable", "disable"])
}

@Test func powerPauseRetainsSessionButReleasesCombinedHold() async {
    let f = Fixture()
    await f.ready(.battery)
    #expect(await f.send(.start, duration: 900, charging: true).snapshot.phase == .waitingForPower)
    await f.authority.powerSourceChanged(.external)
    #expect(await f.authority.snapshot().phase == .active)
    await f.authority.powerSourceChanged(.unknown)
    let snapshot = await f.authority.snapshot()
    #expect(snapshot.phase == .powerSourceUnavailable)
    #expect(snapshot.requested)
    #expect(await f.backend.calls == ["recover", "enable", "disable"])
}

@Test func heartbeatDoesNotExtendTimerAndLeaseUsesAwakeTime() async {
    let f = Fixture()
    await f.ready(.battery)
    _ = await f.send(.start, duration: 900, charging: true)
    await f.authority.systemWillSleep()
    f.time.advance(880, asleep: true)
    await f.authority.systemDidWake()
    let heartbeat = await f.send(.heartbeat, revision: 2)
    #expect(heartbeat.snapshot.requested)
    #expect(heartbeat.snapshot.remainingSeconds == 20)
    f.time.advance(20)
    await f.authority.tick()
    #expect(await f.authority.snapshot().phase == .off)
    #expect(await f.backend.calls == ["recover"])
}

@Test func awakeLeaseExpiresAndHeartbeatCannotResurrectSession() async {
    let f = Fixture()
    await f.ready()
    _ = await f.send(.start)
    f.time.advance(20)
    let reply = await f.send(.heartbeat, revision: 2)
    #expect(reply.failure?.code == .notOwner)
    #expect(reply.snapshot.phase == .off)
    #expect(await f.backend.calls == ["recover", "enable", "disable"])
}

@Test func wakeRequiresFreshOwnerExchangeBeforePowerCanResume() async {
    let f = Fixture()
    await f.ready(.battery)
    _ = await f.send(.start, charging: true)
    await f.authority.systemWillSleep()
    f.time.advance(300, asleep: true)
    await f.authority.systemDidWake()
    await f.authority.powerSourceChanged(.external)
    #expect(await f.authority.snapshot().phase == .waitingForPower)
    _ = await f.send(.status)
    #expect(await f.backend.calls == ["recover"])
    #expect(await f.send(.heartbeat, revision: 2).snapshot.phase == .active)
}

@Test func wakeHeartbeatCannotUseCachedPreSleepExternalPower() async {
    let f = Fixture()
    await f.ready()
    _ = await f.send(.start, charging: true)
    await f.authority.systemWillSleep()
    f.time.advance(300, asleep: true)
    await f.authority.systemDidWake()
    let reply = await f.send(.heartbeat, revision: 2)
    #expect(reply.snapshot.phase == .powerSourceUnavailable)
    #expect(await f.backend.calls == ["recover", "enable", "disable"])
    await f.authority.powerSourceChanged(.external)
    #expect(await f.authority.snapshot().phase == .active)
}

@Test func sameTimerValueDoesNotResetButChangedTimerDoes() async {
    let f = Fixture()
    await f.ready()
    _ = await f.send(.start, duration: 900)
    f.time.advance(10)
    #expect(await f.send(.update, revision: 2, duration: 900).snapshot.remainingSeconds == 890)
    f.time.advance(5)
    #expect(await f.send(.update, revision: 3, duration: 1800).snapshot.remainingSeconds == 1800)
}

@Test func expiredTimerCannotBeExtendedByLateUpdate() async {
    let f = Fixture()
    await f.ready(.battery)
    _ = await f.send(.start, duration: 900, charging: true)
    f.time.advance(901, asleep: true)
    let reply = await f.send(.update, revision: 2, duration: 1800, charging: true)
    #expect(reply.failure?.code == .notOwner)
    #expect(reply.snapshot.phase == .off)
}

@Test func anotherConnectionCannotAdoptOrStopOwner() async {
    let f = Fixture()
    await f.ready()
    _ = await f.send(.start)
    let other = UUID()
    for action in [ServiceAction.update, .heartbeat, .stop] {
        let reply = await f.authority.handle(.init(action: action, generation: f.generation,
                                                   revision: 2, onlyWhenCharging: false, closedLidMode: true, durationSeconds: 0),
                                             connectionID: other)
        #expect(reply.failure?.code == .notOwner)
        #expect(reply.snapshot.phase == .active)
    }
}

@Test func stopBeforeDelayedStartTombstonesGeneration() async {
    let f = Fixture()
    await f.ready()
    _ = await f.send(.stop, revision: 2)
    #expect(await f.send(.stop, revision: 2).failure == nil)
    #expect(await f.send(.start).failure?.code == .staleRevision)
    #expect(await f.send(.start, revision: 3).failure?.code == .staleRevision)
    #expect(await f.backend.calls == ["recover"])
}

@Test func replayedHeartbeatDoesNotRenewLease() async {
    let f = Fixture()
    await f.ready()
    _ = await f.send(.start)
    f.time.advance(5)
    _ = await f.send(.heartbeat, revision: 2)
    f.time.advance(10)
    #expect(await f.send(.heartbeat, revision: 2).failure?.code == .staleRevision)
    f.time.advance(10)
    await f.authority.tick()
    #expect(await f.authority.snapshot().phase == .off)
}

@Test func invalidatedConnectionCannotStartEvenWhenItNeverOwnedAnything() async {
    let f = Fixture()
    await f.ready()
    await f.authority.connectionInvalidated(f.connection)
    #expect(await f.send(.start).failure?.code == .notOwner)
    #expect(await f.backend.calls == ["recover"])
}

@Test func invalidationReleasesActiveSession() async {
    let f = Fixture()
    await f.ready()
    _ = await f.send(.start)
    await f.authority.connectionInvalidated(f.connection)
    #expect(await f.authority.snapshot().phase == .off)
    #expect(await f.backend.held == false)
}

@Test func stopDuringSuspendedEnableSerializesRelease() async throws {
    let f = Fixture()
    await f.ready()
    await f.backend.configure(suspendEnable: true)
    let start = Task { await f.send(.start) }
    try await waitUntil { await f.backend.enableIsSuspended }
    let stop = Task { await f.send(.stop, revision: 2) }
    try await waitUntil { await !f.authority.snapshot().requested }
    #expect(await f.backend.calls == ["recover", "enable"])
    await f.backend.finishEnable()
    #expect(await stop.value.snapshot.phase == .off)
    #expect(await start.value.snapshot.phase == .off)
    #expect(await f.backend.calls == ["recover", "enable", "disable"])
    #expect(await f.backend.maximumConcurrentOperations == 1)
}

@Test func lateEnableErrorAfterCancellationStillCleansWithoutStaleFailure() async throws {
    let f = Fixture()
    await f.ready()
    await f.backend.configure(enableError: .init(.unavailable, "Test failure"), suspendEnable: true)
    let start = Task { await f.send(.start) }
    try await waitUntil { await f.backend.enableIsSuspended }
    let stop = Task { await f.send(.stop, revision: 2) }
    try await waitUntil { await !f.authority.snapshot().requested }
    await f.backend.finishEnable()
    #expect(await start.value.failure == nil)
    #expect(await stop.value.snapshot.phase == .off)
    #expect(await f.backend.held == false)
}

@Test func deadlineDuringSuspendedEnableCannotPublishActive() async throws {
    let f = Fixture()
    await f.ready()
    await f.backend.configure(suspendEnable: true)
    let start = Task { await f.send(.start, duration: 900) }
    try await waitUntil { await f.backend.enableIsSuspended }
    f.time.advance(901, asleep: true)
    await f.backend.finishEnable()
    #expect(await start.value.snapshot.phase == .off)
    #expect(await f.backend.calls == ["recover", "enable", "disable"])
}

@Test func powerPauseCanBeCancelledWhileReleaseIsPending() async throws {
    let f = Fixture()
    await f.ready()
    _ = await f.send(.start, charging: true)
    await f.backend.configure(suspendDisable: true)
    let pause = Task { await f.authority.powerSourceChanged(.battery) }
    try await waitUntil { await f.backend.disableIsSuspended }
    let stop = Task { await f.send(.stop, revision: 2) }
    try await waitUntil { await !f.authority.snapshot().requested }
    await f.backend.finishDisable()
    await pause.value
    #expect(await stop.value.snapshot.phase == .off)
    await f.authority.powerSourceChanged(.external)
    #expect(await f.backend.calls == ["recover", "enable", "disable"])
}

@Test func cleanupFailureBlocksStartAndPollingDoesNotRepeatWrites() async {
    let f = Fixture()
    await f.ready()
    _ = await f.send(.start)
    await f.backend.configure(disableError: .init(.cleanupRequired, "Test cleanup failure"))
    #expect(await f.send(.stop, revision: 2).snapshot.phase == .cleanupRequired)
    #expect(await !f.authority.snapshot().readyForSession)
    await f.authority.tick()
    _ = await f.send(.status)
    #expect(await f.backend.calls == ["recover", "enable", "disable"])
    #expect(await f.send(.start, revision: 3).failure?.code == .cleanupRequired)
    await f.backend.configure()
    #expect(await f.send(.stop, revision: 2).snapshot.phase == .off)
}

@Test func freshConnectionCanRetryAbandonedCleanupButNotTakeOverLiveOwner() async {
    let f = Fixture()
    await f.ready()
    _ = await f.send(.start)
    let fresh = UUID()
    let request = ServiceRequest(action: .stop, revision: 1)
    #expect(await f.authority.handle(request, connectionID: fresh).failure?.code == .notOwner)
    await f.backend.configure(disableError: .init(.cleanupRequired, "Test cleanup failure"))
    await f.authority.connectionInvalidated(f.connection)
    await f.backend.configure()
    #expect(await f.authority.handle(request, connectionID: fresh).snapshot.phase == .off)
}

@Test func failedStartupRecoveryRequiresExplicitRetryAndCannotArm() async {
    let f = Fixture()
    await f.backend.configure(recoveryError: .init(.cleanupRequired, "Invalid recovery record"))
    await f.ready()
    #expect(await f.send(.start).failure?.code == .cleanupRequired)
    _ = await f.send(.status)
    #expect(await f.backend.calls == ["recover"])
    await f.backend.configure()
    let reply = await f.authority.handle(.init(action: .stop, revision: 2), connectionID: f.connection)
    #expect(reply.snapshot.phase == .off)
    #expect(await f.backend.calls == ["recover", "recover"])
}

@Test func externalOverrideIsVisibleAndNeverReportedAsActive() async {
    let f = Fixture()
    await f.ready()
    await f.backend.configure(enableError: .init(.externalOverride, "Sleep was already disabled"))
    let reply = await f.send(.start)
    #expect(reply.snapshot.phase == .externalOverride)
    #expect(!reply.snapshot.requested)
    #expect(await f.backend.calls == ["recover", "enable", "disable"])
}

@Test func successfulCleanupAfterAmbiguousEnableIsAFailedStartNotUnresolvedRecovery() async {
    let f = Fixture()
    await f.ready()
    await f.backend.configure(enableError: .init(.cleanupRequired, "Activation read-back failed"))
    let reply = await f.send(.start)
    #expect(reply.snapshot.phase == .unavailable)
    #expect(reply.snapshot.readyForSession)
    #expect(reply.failure?.code == .unavailable)
    #expect(reply.failure?.message == "Activation read-back failed")
    #expect(!reply.snapshot.requested)
    #expect(await f.backend.held == false)
    #expect(await f.backend.calls == ["recover", "enable", "disable"])
}

@Test func malformedAndIncompatibleRequestsHaveNoPowerSideEffects() async {
    let f = Fixture()
    await f.ready()
    #expect(await f.send(.start, duration: 13).failure?.code == .invalidRequest)
    let request = ServiceRequest(action: .start, generation: f.generation, revision: 1,
                                 onlyWhenCharging: false, closedLidMode: true, durationSeconds: 0, version: 999)
    #expect(await f.authority.handle(request, connectionID: f.connection).failure?.code == .incompatibleVersion)
    #expect(await f.backend.calls == ["recover"])
}

@Test func shutdownReleasesAndRejectsFurtherActivation() async {
    let f = Fixture()
    await f.ready()
    _ = await f.send(.start)
    await f.authority.shutdown()
    #expect(await f.authority.snapshot().phase == .off)
    #expect(await !f.authority.snapshot().readyForSession)
    #expect(await f.send(.start, revision: 2).failure?.code == .unavailable)
    #expect(await f.backend.held == false)
}

@Test func closedLidModeChangesDoNotRestartSessionDeadline() async {
    let f = Fixture()
    await f.ready()
    _ = await f.send(.start, duration: 900, closedLidMode: false)
    f.time.advance(10)
    let enabled = await f.send(.update, revision: 2, duration: 900, closedLidMode: true)
    #expect(enabled.snapshot.phase == .active)
    #expect(enabled.snapshot.closedLidMode)
    #expect(enabled.snapshot.remainingSeconds == 890)
    f.time.advance(5)
    let disabled = await f.send(.update, revision: 3, duration: 900, closedLidMode: false)
    #expect(!disabled.snapshot.closedLidMode)
    #expect(disabled.snapshot.remainingSeconds == 885)
    #expect(await f.backend.modes == [false, true, false])
    _ = await f.send(.update, revision: 4, duration: 900, closedLidMode: false)
    #expect(await f.backend.modes.count == 3)
}

@Test func modeChosenWhileWaitingAppliesOnlyWhenPowerBecomesEligible() async {
    let f = Fixture()
    await f.ready(.battery)
    _ = await f.send(.start, charging: true)
    _ = await f.send(.update, revision: 2, charging: true, closedLidMode: false)
    #expect(await f.backend.modes.isEmpty)
    await f.authority.powerSourceChanged(.external)
    #expect(await f.backend.modes == [false])
    await f.authority.systemWillSleep()
    await f.authority.systemDidWake()
    await f.authority.powerSourceChanged(.external)
    #expect(await f.backend.modes == [false])
    _ = await f.send(.heartbeat, revision: 3)
    #expect(await f.backend.modes == [false, false])
}

@Test func modeChangeDuringPendingOperationReconcilesNewestValue() async throws {
    let f = Fixture()
    await f.ready()
    _ = await f.send(.start, closedLidMode: false)
    await f.backend.configure(suspendEnable: true)
    let upgrade = Task { await f.send(.update, revision: 2, closedLidMode: true) }
    try await waitUntil { await f.backend.enableIsSuspended }
    let downgrade = Task { await f.send(.update, revision: 3, closedLidMode: false) }
    try await waitUntil { await f.authority.snapshot().closedLidMode == false }
    await f.backend.finishEnable()
    _ = await upgrade.value
    let result = await downgrade.value
    #expect(result.snapshot.phase == .active)
    #expect(!result.snapshot.closedLidMode)
    #expect(await f.backend.modes == [false, true, false])
    #expect(await f.backend.maximumConcurrentOperations == 1)
}

@Test func stopDuringModeChangeWinsAndFailureDoesNotFallBack() async throws {
    let f = Fixture()
    await f.ready()
    _ = await f.send(.start, closedLidMode: false)
    await f.backend.configure(suspendEnable: true)
    let upgrade = Task { await f.send(.update, revision: 2, closedLidMode: true) }
    try await waitUntil { await f.backend.enableIsSuspended }
    let stop = Task { await f.send(.stop, revision: 3) }
    try await waitUntil { await !f.authority.snapshot().requested }
    await f.backend.finishEnable()
    _ = await upgrade.value
    #expect(await stop.value.snapshot.phase == .off)
    #expect(await !f.backend.held)

    let failed = Fixture()
    await failed.ready()
    _ = await failed.send(.start)
    await failed.backend.configure(enableError: .init(.cleanupRequired, "Restoration failed"),
                                   disableError: .init(.cleanupRequired, "Still unresolved"))
    let reply = await failed.send(.update, revision: 2, closedLidMode: false)
    #expect(!reply.snapshot.requested)
    #expect(reply.snapshot.phase == .cleanupRequired)
    #expect(!reply.snapshot.readyForSession)
}

@Test func missingModeAndPreviousProtocolCannotSilentlyUseCombinedHold() async {
    let f = Fixture()
    await f.ready()
    let missing = await f.authority.handle(.init(action: .start, generation: f.generation,
        revision: 1, onlyWhenCharging: false, durationSeconds: 0), connectionID: f.connection)
    #expect(missing.failure?.code == .invalidRequest)
    for version in [2, 3, 4, 5, 6, 7] {
        let old = await f.authority.handle(.init(action: .start, generation: f.generation,
            revision: 1, onlyWhenCharging: false, closedLidMode: false, durationSeconds: 0, version: version), connectionID: f.connection)
        #expect(old.failure?.code == .incompatibleVersion)
    }
    #expect(await f.backend.modes.isEmpty)
}
