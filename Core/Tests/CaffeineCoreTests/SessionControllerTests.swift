import Foundation
import Testing
@testable import CaffeineCore

@MainActor
private final class ManualClock: ElapsedTimeSource {
    var now: TimeInterval = 0
    func advance(_ seconds: TimeInterval) { now += seconds }
}

@MainActor
private final class MemoryPreferences: SessionPreferences {
    var onlyWhenCharging = false
    var closedLidMode = true
    var timerPreset: TimerPreset = .noLimit
}

@MainActor
private final class ControlledBackend: SessionBackend {
    var isSimulated = true
    var holdEnabled = false
    var changes: [Bool] = []
    var modes: [Bool] = []
    var prepareError: SessionBackendError?
    var failEnable = false
    var failDisable = false
    var suspendEnable = false
    var suspendDisable = false
    var suspendPrepare = false
    private var enableContinuation: CheckedContinuation<Void, Never>?
    private var disableContinuation: CheckedContinuation<Void, Never>?
    private var prepareContinuation: CheckedContinuation<Void, Never>?

    func prepare() async throws {
        if suspendPrepare {
            await withCheckedContinuation { prepareContinuation = $0 }
        }
        if let prepareError { throw prepareError }
    }

    func setHoldEnabled(_ enabled: Bool, closedLidMode: Bool) async throws {
        modes.append(closedLidMode)
        changes.append(enabled)
        if enabled, suspendEnable {
            await withCheckedContinuation { enableContinuation = $0 }
        }
        if !enabled, suspendDisable {
            await withCheckedContinuation { disableContinuation = $0 }
        }
        // An enable may have applied before its acknowledgement fails.
        if enabled { holdEnabled = true }
        if enabled ? failEnable : failDisable {
            throw SessionBackendError.unavailable("Test service acknowledgement failed.")
        }
        holdEnabled = enabled
    }

    var isEnableSuspended: Bool { enableContinuation != nil }
    var isDisableSuspended: Bool { disableContinuation != nil }
    var isPrepareSuspended: Bool { prepareContinuation != nil }
    func finishEnable() {
        let continuation = enableContinuation
        enableContinuation = nil
        continuation?.resume()
    }
    func finishDisable() {
        suspendDisable = false
        let continuation = disableContinuation
        disableContinuation = nil
        continuation?.resume()
    }
    func finishPrepare() {
        let continuation = prepareContinuation
        prepareContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private func waitFor(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    throw SessionBackendError.unavailable("Test operation did not reach its suspension point.")
}

@Suite("Session intentions, elapsed time, and serialized cleanup")
@MainActor
struct SessionControllerTests {
    @Test func closedLidModeDefaultsOnAndPersistsOffWithoutRestoringSession() async {
        let suite = "CaffeineModeChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsSessionPreferences(defaults: defaults)
        #expect(preferences.closedLidMode)
        let first = SessionController(backend: ControlledBackend(), preferences: preferences)
        first.setClosedLidMode(false)
        let second = SessionController(backend: ControlledBackend(), preferences: UserDefaultsSessionPreferences(defaults: defaults))
        #expect(!second.closedLidMode)
        #expect(!second.requested)
    }

    @Test func previewModeChangesPreserveTimerAndDoNotArmOffSession() async {
        let backend = ControlledBackend(), clock = ManualClock()
        let model = SessionController(backend: backend, clock: clock, preferences: MemoryPreferences())
        model.setClosedLidMode(false)
        #expect(backend.changes.isEmpty)
        model.selectTimer(.fifteenMinutes)
        model.setKeepAwake(true)
        await model.waitUntilSettled()
        clock.advance(10)
        model.tick()
        model.setClosedLidMode(true)
        await model.waitUntilSettled()
        #expect(model.remainingSeconds == 890)
        #expect(backend.modes == [false, true])
        #expect(model.state == .active)
        model.setKeepAwake(false)
        await model.waitUntilSettled()
        #expect(!backend.holdEnabled)
    }

    @Test func freshControllerRestoresPreferencesButNeverSession() async {
        let preferences = MemoryPreferences()
        let first = SessionController(backend: ControlledBackend(), preferences: preferences)
        first.setOnlyWhenCharging(true)
        first.selectTimer(.thirtyMinutes)
        first.setKeepAwake(true)
        await first.waitUntilSettled()
        #expect(first.requested)

        let second = SessionController(backend: ControlledBackend(), preferences: preferences)
        #expect(second.onlyWhenCharging)
        #expect(second.timerPreset == .thirtyMinutes)
        #expect(!second.requested)
        #expect(second.state == .off)
        #expect(second.remainingSeconds == nil)
    }

    @Test func unavailableBuildNeverReportsActiveOrArmsTimer() async {
        let model = SessionController(preferences: MemoryPreferences(), initialPowerSource: .external)
        model.selectTimer(.fifteenMinutes)
        model.setKeepAwake(true)
        await model.waitUntilSettled()
        #expect(model.state == .setupRequired)
        #expect(!model.requested)
        #expect(model.remainingSeconds == nil)
        #expect(model.actionTitle == nil)
        #expect(!model.isPreview)
        #expect(await model.stopForQuit())
    }

    @Test func thirtyMinuteDeadlineIncludesTimeWaitingForPower() async {
        let clock = ManualClock()
        let backend = ControlledBackend()
        let model = SessionController(backend: backend, clock: clock, preferences: MemoryPreferences(), initialPowerSource: .external)
        model.setOnlyWhenCharging(true)
        model.selectTimer(.thirtyMinutes)
        model.setKeepAwake(true)
        await model.waitUntilSettled()
        #expect(model.state == .active)
        clock.advance(300)
        model.updatePower(.battery)
        await model.waitUntilSettled()
        #expect(model.state == .waitingForPower)
        #expect(model.requested)
        #expect(!backend.holdEnabled)

        clock.advance(300)
        model.updatePower(.external)
        await model.waitUntilSettled()
        #expect(model.state == .active)
        #expect(model.remainingSeconds == 1200)
        #expect(model.timerDisplayValue == "20:00 left")
        #expect(backend.changes == [true, false, true])
    }

    @Test func expiryWhileWaitingDoesNotResumeOnLaterPower() async {
        let clock = ManualClock()
        let backend = ControlledBackend()
        let model = SessionController(backend: backend, clock: clock, preferences: MemoryPreferences(), initialPowerSource: .battery)
        model.setOnlyWhenCharging(true)
        model.selectTimer(.fifteenMinutes)
        model.setKeepAwake(true)
        await model.waitUntilSettled()
        clock.advance(1_000)
        // The power event itself must check expiry, even before the next UI tick.
        model.updatePower(.external)
        await model.waitUntilSettled()
        #expect(model.state == .off)
        #expect(!model.requested)
        #expect(!backend.changes.contains(true))
        #expect(model.timerDisplayValue == "15 min")
    }

    @Test func unknownPowerWithholdsHoldOnlyWhenRestricted() async {
        let backend = ControlledBackend()
        let model = SessionController(backend: backend, preferences: MemoryPreferences())
        model.setOnlyWhenCharging(true)
        model.setKeepAwake(true)
        await model.waitUntilSettled()
        #expect(model.state == .powerSourceUnavailable)
        #expect(backend.changes.isEmpty)
        model.setOnlyWhenCharging(false)
        await model.waitUntilSettled()
        #expect(model.state == .active)
    }

    @Test func timerSelectionRestartsOnlyWhenValueChanges() async {
        let clock = ManualClock()
        let model = SessionController(backend: ControlledBackend(), clock: clock, preferences: MemoryPreferences())
        model.selectTimer(.thirtyMinutes)
        model.setKeepAwake(true)
        await model.waitUntilSettled()
        clock.advance(600)
        model.tick()
        model.selectTimer(.thirtyMinutes)
        #expect(model.remainingSeconds == 1200)
        model.selectTimer(.oneHour)
        #expect(model.remainingSeconds == 3600)
        #expect(model.timerDisplayValue == "1:00:00 left")
        clock.advance(60)
        model.tick()
        #expect(model.remainingSeconds == 3540)
        model.selectTimer(.noLimit)
        clock.advance(100_000)
        model.tick()
        #expect(model.requested)
        #expect(model.remainingSeconds == nil)
    }

    @Test func changingPresetCannotResurrectAnAlreadyExpiredSession() async {
        let clock = ManualClock()
        let backend = ControlledBackend()
        let model = SessionController(backend: backend, clock: clock, preferences: MemoryPreferences())
        model.selectTimer(.fifteenMinutes)
        model.setKeepAwake(true)
        await model.waitUntilSettled()
        clock.advance(901)
        model.selectTimer(.eightHours)
        await model.waitUntilSettled()
        #expect(!model.requested)
        #expect(model.state == .off)
        #expect(!backend.holdEnabled)
        #expect(model.timerPreset == .eightHours)
    }

    @Test func activeTimerExpiryReleasesHold() async {
        let clock = ManualClock()
        let backend = ControlledBackend()
        let model = SessionController(backend: backend, clock: clock, preferences: MemoryPreferences())
        model.selectTimer(.fifteenMinutes)
        model.setKeepAwake(true)
        await model.waitUntilSettled()
        clock.advance(900)
        model.tick()
        await model.waitUntilSettled()
        #expect(model.state == .off)
        #expect(!backend.holdEnabled)
        #expect(backend.changes == [true, false])
    }

    @Test func stopSupersedesAnEnableReplyAndRejectsRestartUntilSettled() async throws {
        let backend = ControlledBackend()
        backend.suspendEnable = true
        let model = SessionController(backend: backend, preferences: MemoryPreferences())
        model.setKeepAwake(true)
        try await waitFor { backend.isEnableSuspended }
        #expect(model.state == .starting)
        model.setKeepAwake(false)
        model.setKeepAwake(true)
        #expect(!model.requested)
        backend.finishEnable()
        await model.waitUntilSettled()
        #expect(model.state == .off)
        #expect(!backend.holdEnabled)
        #expect(backend.changes == [true, false])
    }

    @Test func powerLossDuringPendingEnableImmediatelyReleasesAfterAcknowledgement() async throws {
        let backend = ControlledBackend()
        backend.suspendEnable = true
        let model = SessionController(backend: backend, preferences: MemoryPreferences(), initialPowerSource: .external)
        model.setOnlyWhenCharging(true)
        model.setKeepAwake(true)
        try await waitFor { backend.isEnableSuspended }
        model.updatePower(.battery)
        backend.finishEnable()
        await model.waitUntilSettled()
        #expect(model.requested)
        #expect(model.state == .waitingForPower)
        #expect(!backend.holdEnabled)
    }

    @Test func failedEnableReplyAfterStopSettlesOffAfterCleanup() async throws {
        let backend = ControlledBackend()
        backend.suspendEnable = true
        backend.failEnable = true
        let model = SessionController(backend: backend, preferences: MemoryPreferences())
        model.setKeepAwake(true)
        try await waitFor { backend.isEnableSuspended }
        model.setKeepAwake(false)
        backend.finishEnable()
        await model.waitUntilSettled()
        #expect(model.state == .off)
        #expect(!model.requested)
        #expect(!backend.holdEnabled)
        #expect(!model.isCleanupUncertain)
        #expect(backend.changes == [true, false])
    }

    @Test func failedEnableReplyAfterDeadlineSettlesOffWithoutNeedingTick() async throws {
        let clock = ManualClock()
        let backend = ControlledBackend()
        backend.suspendEnable = true
        backend.failEnable = true
        let model = SessionController(backend: backend, clock: clock, preferences: MemoryPreferences())
        model.selectTimer(.fifteenMinutes)
        model.setKeepAwake(true)
        try await waitFor { backend.isEnableSuspended }
        clock.advance(901)
        backend.finishEnable()
        await model.waitUntilSettled()
        #expect(model.state == .off)
        #expect(!model.requested)
        #expect(model.remainingSeconds == nil)
        #expect(!backend.holdEnabled)
        #expect(backend.changes == [true, false])
    }

    @Test func userCanCancelArmedSessionWhilePowerPauseReleaseIsPending() async throws {
        let backend = ControlledBackend()
        let model = SessionController(backend: backend, preferences: MemoryPreferences(), initialPowerSource: .external)
        model.setOnlyWhenCharging(true)
        model.setKeepAwake(true)
        await model.waitUntilSettled()
        backend.suspendDisable = true
        model.updatePower(.battery)
        try await waitFor { backend.isDisableSuspended }
        #expect(model.state == .stopping)
        #expect(model.requested)
        #expect(model.canToggleKeepAwake)
        model.setKeepAwake(false)
        #expect(!model.canToggleKeepAwake)
        model.setKeepAwake(true)
        #expect(!model.requested)
        model.updatePower(.external)
        backend.finishDisable()
        await model.waitUntilSettled()
        #expect(model.state == .off)
        #expect(!model.requested)
        #expect(!backend.holdEnabled)
        #expect(backend.changes.filter { $0 }.count == 1)
    }

    @Test func partialStartFailureEntersVerifiedCleanupBeforeSafeFailure() async {
        let backend = ControlledBackend()
        backend.failEnable = true
        let model = SessionController(backend: backend, preferences: MemoryPreferences())
        model.setKeepAwake(true)
        await model.waitUntilSettled()
        #expect(!model.requested)
        #expect(!backend.holdEnabled)
        #expect(backend.changes == [true, false])
        #expect(model.state == .failed("Test service acknowledgement failed."))
        #expect(!model.isCleanupUncertain)
        #expect(await model.stopForQuit())
    }

    @Test func failedReleasePreventsQuitUntilRetryAcknowledged() async {
        let backend = ControlledBackend()
        let model = SessionController(backend: backend, preferences: MemoryPreferences())
        model.setKeepAwake(true)
        await model.waitUntilSettled()
        backend.failDisable = true
        #expect(!(await model.stopForQuit()))
        #expect(model.isCleanupUncertain)
        #expect(model.state == .cleanupRequired("Test service acknowledgement failed."))
        #expect(!model.canToggleKeepAwake)
        #expect(backend.holdEnabled)
        backend.failDisable = false
        model.retry()
        await model.waitUntilSettled()
        #expect(model.state == .off)
        #expect(!model.isCleanupUncertain)
        #expect(!backend.holdEnabled)
        #expect(await model.stopForQuit())
    }

    @Test func quitDuringPendingEnableWaitsForRelease() async throws {
        let backend = ControlledBackend()
        backend.suspendEnable = true
        let model = SessionController(backend: backend, preferences: MemoryPreferences())
        model.setKeepAwake(true)
        try await waitFor { backend.isEnableSuspended }
        let quit = Task { await model.stopForQuit() }
        try await waitFor { !model.requested }
        model.setKeepAwake(true)
        #expect(!model.requested)
        backend.finishEnable()
        #expect(await quit.value)
        #expect(!backend.holdEnabled)
        #expect(model.state == .off)
    }

    @Test func cancelledPreparationFailureDoesNotReplaceOffWithOldError() async throws {
        let backend = ControlledBackend()
        backend.suspendPrepare = true
        backend.prepareError = .setupRequired
        let model = SessionController(backend: backend, preferences: MemoryPreferences())
        model.setKeepAwake(true)
        try await waitFor { backend.isPrepareSuspended }
        model.setKeepAwake(false)
        backend.finishPrepare()
        await model.waitUntilSettled()
        #expect(model.state == .off)
        #expect(backend.changes.isEmpty)
    }

    @Test func corruptSavedPresetFallsBackToNoLimitWithoutRestoringRequest() throws {
        let name = "CaffeineCoreTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(123, forKey: "caffeine.timerPreset")
        defaults.set(true, forKey: "caffeine.keepAwake")
        let preferences = UserDefaultsSessionPreferences(defaults: defaults)
        let model = SessionController(preferences: preferences)
        #expect(model.timerPreset == .noLimit)
        #expect(!model.requested)
    }
}
