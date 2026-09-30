import Foundation
import Observation

@Observable
@MainActor
public final class SessionController {
    public private(set) var requested = false
    public private(set) var onlyWhenCharging: Bool
    public private(set) var closedLidMode: Bool
    public private(set) var timerPreset: TimerPreset
    public private(set) var powerSource: PowerSource
    public private(set) var state: SessionState = .off
    public private(set) var remainingSeconds: Int?
    public let isPreview: Bool

    @ObservationIgnored private let backend: any SessionBackend
    @ObservationIgnored private let clock: any ElapsedTimeSource
    @ObservationIgnored private let preferences: any SessionPreferences
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var armed = false
    @ObservationIgnored private var holdEnabled = false
    @ObservationIgnored private var heldClosedLidMode: Bool?
    @ObservationIgnored private var cleanupUncertain = false
    @ObservationIgnored private var deadline: TimeInterval?
    @ObservationIgnored private var settledFailure: SessionState?
    @ObservationIgnored private var quitting = false

    public init(
        backend: any SessionBackend = UnavailableSessionBackend(),
        clock: any ElapsedTimeSource = ContinuousElapsedTimeSource(),
        preferences: any SessionPreferences = UserDefaultsSessionPreferences(),
        initialPowerSource: PowerSource = .unknown
    ) {
        self.backend = backend
        self.clock = clock
        self.preferences = preferences
        onlyWhenCharging = preferences.onlyWhenCharging
        closedLidMode = preferences.closedLidMode
        timerPreset = preferences.timerPreset
        powerSource = initialPowerSource
        isPreview = backend.isSimulated
    }

    public var statusTitle: String {
        switch state {
        case .off: "Keep awake is off"
        case .starting: "Starting…"
        case .active: "Keeping your Mac awake"
        case .waitingForPower: "Waiting for power"
        case .powerSourceUnavailable: "Power source unavailable"
        case .stopping: "Stopping…"
        case .setupRequired: "Setup required"
        case .failed: "Couldn’t start Keep awake"
        case .cleanupRequired: "Couldn’t stop Keep awake"
        }
    }

    public var statusMessage: String? {
        switch state {
        case .setupRequired:
            "Closed-lid support is not available in this build. Keep awake hasn’t started."
        case .failed(let message): message
        case .cleanupRequired:
            "Your Mac may still stay awake. Try restoring Caffeine’s sleep settings before quitting."
        case .powerSourceUnavailable:
            "Caffeine is waiting for a known external power source."
        default: nil
        }
    }

    public var actionTitle: String? {
        switch state {
        case .failed, .cleanupRequired: "Try Again"
        default: nil
        }
    }

    public var isActive: Bool { state == .active }

    public var isPending: Bool { state == .starting || state == .stopping }
    public var isCleanupUncertain: Bool { cleanupUncertain }
    public var canToggleKeepAwake: Bool {
        // Releasing a hold for a power pause must not prevent cancellation of
        // the still-armed session. A new session waits for release to settle.
        requested || (state != .stopping && !cleanupUncertain && !quitting)
    }

    public var timerDisplayValue: String {
        guard requested, let seconds = remainingSeconds else { return timerPreset.title }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d left", hours, minutes, remainder)
        }
        return String(format: "%d:%02d left", minutes, remainder)
    }

    public func setKeepAwake(_ enabled: Bool) {
        if enabled {
            guard !requested, canToggleKeepAwake else { return }
            requested = true
            settledFailure = nil
            state = .starting
        } else {
            guard requested || cleanupUncertain else { return }
            requested = false
            clearTimer()
            state = .stopping
        }
        scheduleReconciliation()
    }

    public func setOnlyWhenCharging(_ enabled: Bool) {
        guard onlyWhenCharging != enabled else { return }
        onlyWhenCharging = enabled
        preferences.onlyWhenCharging = enabled
        if requested { scheduleReconciliation() }
    }

    public func selectTimer(_ preset: TimerPreset) {
        guard timerPreset != preset else { return }
        if requested, armed { refreshRemainingTime() }
        timerPreset = preset
        preferences.timerPreset = preset
        if requested, armed {
            deadline = preset.duration.map { clock.now + $0 }
            refreshRemainingTime()
        }
        if !requested, prepared { scheduleReconciliation() }
    }

    public func setClosedLidMode(_ enabled: Bool) {
        guard closedLidMode != enabled else { return }
        closedLidMode = enabled
        preferences.closedLidMode = enabled
        if requested { scheduleReconciliation() }
    }

    public func updatePower(_ source: PowerSource) {
        guard powerSource != source else { return }
        powerSource = source
        if requested { scheduleReconciliation() }
    }

    /// Called by an application-lifetime timer, never by a disposable card task.
    public func tick() {
        guard requested, armed else { return }
        refreshRemainingTime()
        if !requested { scheduleReconciliation() }
    }

    public func retry() {
        if cleanupUncertain {
            state = .stopping
            scheduleReconciliation()
        } else if case .failed = state {
            setKeepAwake(true)
        }
    }

    /// Keeps the process resident if release could not be acknowledged.
    public func stopForQuit() async -> Bool {
        quitting = true
        requested = false
        clearTimer()
        if prepared || holdEnabled || cleanupUncertain || worker != nil { state = .stopping }
        scheduleReconciliation()
        await worker?.value
        let canQuit = !holdEnabled && !cleanupUncertain && !prepared
        if !canQuit { quitting = false }
        return canQuit
    }

    /// Lets tests await outstanding backend work.
    public func waitUntilSettled() async { await worker?.value }

    private func scheduleReconciliation() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.reconcile()
            self.worker = nil
        }
    }

    private func reconcile() async {
        // Re-read intent after every await. No later operation can overtake an
        // earlier backend mutation, including enable replies arriving after Stop.
        while true {
            if requested, armed { refreshRemainingTime() }
            if !requested {
                clearTimer()
                if prepared || holdEnabled || cleanupUncertain {
                    state = .stopping
                    do {
                        try await backend.setHoldEnabled(false, closedLidMode: closedLidMode)
                        holdEnabled = false
                        prepared = false
                        cleanupUncertain = false
                    } catch {
                        cleanupUncertain = true
                        state = .cleanupRequired(error.localizedDescription)
                        return
                    }
                }
                state = settledFailure ?? .off
                return
            }

            if !prepared {
                state = .starting
                do {
                    try await backend.prepare()
                    prepared = true
                } catch {
                    // Preparation is readiness-only and must not acquire holds.
                    guard requested else {
                        state = .off
                        return
                    }
                    requested = false
                    clearTimer()
                    if case SessionBackendError.setupRequired = error {
                        settledFailure = .setupRequired
                    } else {
                        settledFailure = .failed(error.localizedDescription)
                    }
                    state = settledFailure ?? .off
                    return
                }
                guard requested else { continue }
                armed = true
                deadline = timerPreset.duration.map { clock.now + $0 }
                refreshRemainingTime()
            }

            guard requested else { continue }
            let wantsHold = !onlyWhenCharging || powerSource == .external
            if holdEnabled != wantsHold || (wantsHold && heldClosedLidMode != closedLidMode) {
                state = wantsHold ? .starting : .stopping
                let mode = closedLidMode
                do {
                    try await backend.setHoldEnabled(wantsHold, closedLidMode: mode)
                    holdEnabled = wantsHold
                    heldClosedLidMode = mode
                } catch {
                    if requested, armed { refreshRemainingTime() }
                    let failedLiveRequest = requested
                    requested = false
                    clearTimer()
                    cleanupUncertain = true
                    if wantsHold {
                        settledFailure = failedLiveRequest ? .failed(error.localizedDescription) : nil
                        continue // A possibly partial enable always enters cleanup.
                    }
                    state = .cleanupRequired(error.localizedDescription)
                    return
                }
                continue
            }

            if wantsHold {
                state = .active
            } else {
                state = powerSource == .unknown ? .powerSourceUnavailable : .waitingForPower
            }
            return
        }
    }

    private func refreshRemainingTime() {
        guard let deadline else {
            remainingSeconds = nil
            return
        }
        let remaining = deadline - clock.now
        remainingSeconds = max(0, Int(ceil(remaining)))
        if remaining <= 0 {
            requested = false
            clearTimer()
            state = .stopping
        }
    }

    private func clearTimer() {
        deadline = nil
        remainingSeconds = nil
        armed = false
    }
}
