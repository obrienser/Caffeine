import CaffeineLogging
import Foundation
import Observation

@MainActor
protocol LidMonitoring: AnyObject {
    var currentState: Bool? { get }
    func start(_ handler: @escaping @MainActor (LidEvent) -> Void) throws
    func stop()
}

enum LidEvent {
    case changed(Bool?)
    case suspend(LidSuspensionReason)
    case resume(LidSuspensionReason)
}

enum LidSuspensionReason: Hashable, Sendable { case systemSleep, inactiveUser }

@MainActor
protocol LidActionPerforming: AnyObject {
    var needsDisplayRestoration: Bool { get }
    func turnOffBuiltInDisplay() throws
    func restoreBuiltInDisplay() throws
    func lockScreen() throws
    func screenIsLocked() -> Bool?
    /// Nil when the displays cannot be read.
    func builtInDisplayIsOff() -> Bool?
}

/// User-session work belongs to the app, not the root helper or the disposable card.
@Observable @MainActor
final class LidActionsModel {
    private(set) var turnOffDisplayOnLidClose: Bool
    private(set) var lockScreenOnLidClose: Bool
    private(set) var monitoringMessage: String?
    private(set) var displayMessage: String?
    /// Kept after the lid opens, like an unconfirmed lock: the card can't be read while the lid is closed.
    private(set) var displayOffMessage: String?
    private(set) var lockMessage: String?
    private(set) var restorationRequired = false
    var message: String? {
        let messages = [monitoringMessage, displayMessage, displayOffMessage, lockMessage].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let monitor: (any LidMonitoring)?
    @ObservationIgnored private let actions: (any LidActionPerforming)?
    @ObservationIgnored private let keepAwakeIsActive: () -> Bool
    @ObservationIgnored private let waitForLock: () async throws -> Void
    @ObservationIgnored private let waitForDisplay: () async throws -> Void
    @ObservationIgnored private let log: EventLog
    @ObservationIgnored private var lockCheck: Task<Void, Never>?
    @ObservationIgnored private var lockAttempt = UUID()
    @ObservationIgnored private var displayCheck: Task<Void, Never>?
    @ObservationIgnored private var displayAttempt = UUID()
    @ObservationIgnored private var lastState: Bool?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var suspensions: Set<LidSuspensionReason> = []
    @ObservationIgnored private var quitting = false

    init(preview: Bool = false, defaults: UserDefaults? = .standard,
         monitor: (any LidMonitoring)? = nil, actions: (any LidActionPerforming)? = nil,
         keepAwakeIsActive: @escaping () -> Bool,
         waitForLock: @escaping () async throws -> Void = { try await SuspendingClock().sleep(for: .seconds(2)) },
         waitForDisplay: @escaping () async throws -> Void = { try await SuspendingClock().sleep(for: .seconds(2)) },
         log: EventLog = .disabled) {
        self.log = log
        self.defaults = preview ? nil : defaults
        self.monitor = preview ? nil : (monitor ?? SystemLidMonitor())
        self.actions = preview ? nil : (actions ?? SystemLidActions())
        self.keepAwakeIsActive = keepAwakeIsActive
        self.waitForLock = waitForLock
        self.waitForDisplay = waitForDisplay
        turnOffDisplayOnLidClose = self.defaults?.object(forKey: "caffeine.turnOffDisplayOnLidClose") as? Bool ?? true
        lockScreenOnLidClose = self.defaults?.object(forKey: "caffeine.lockScreenOnLidClose") as? Bool ?? false
    }

    func start() {
        guard !started else { return }
        started = true
        suspensions.removeAll()
        do {
            try monitor?.start { [weak self] event in self?.receive(event) }
            // Launching with the lid closed is not a new close event.
            lastState = monitor?.currentState
            monitoringMessage = nil
            log.info(.lid, "Watching the lid: it is \(Self.describe(lastState)). On close: turn off screen \(turnOffDisplayOnLidClose ? "on" : "off")"
                + ", lock screen \(lockScreenOnLidClose ? "on" : "off")")
        } catch {
            monitor?.stop()
            monitoringMessage = "Caffeine couldn’t monitor the lid. Close-lid actions are unavailable."
            log.error(.lid, "The lid cannot be watched: \(error.localizedDescription)")
        }
    }

    /// For the exported log.
    var preferenceSummary: String {
        "Turn Off Screen on Close \(turnOffDisplayOnLidClose ? "on" : "off"), Lock Screen on Close \(lockScreenOnLidClose ? "on" : "off")"
    }

    private static func describe(_ closed: Bool?) -> String {
        closed.map { $0 ? "closed" : "open" } ?? "unavailable"
    }

    func setTurnOffDisplayOnLidClose(_ enabled: Bool) {
        guard turnOffDisplayOnLidClose != enabled else { return }
        log.notice(.lid, "User set Turn Off Screen on Close to \(enabled ? "on" : "off")")
        turnOffDisplayOnLidClose = enabled
        defaults?.set(enabled, forKey: "caffeine.turnOffDisplayOnLidClose")
        if !enabled { cancelDisplayCheck(); displayOffMessage = nil; restoreDisplay() }
    }

    func setLockScreenOnLidClose(_ enabled: Bool) {
        guard lockScreenOnLidClose != enabled else { return }
        log.notice(.lid, "User set Lock Screen on Close to \(enabled ? "on" : "off")")
        lockScreenOnLidClose = enabled
        defaults?.set(enabled, forKey: "caffeine.lockScreenOnLidClose")
        if !enabled { cancelLockCheck(); lockMessage = nil }
        // Preference changes never synthesize another lid closure or unlock a session.
    }

    func sessionChanged() {
        guard !keepAwakeIsActive() else { return }
        cancelLockCheck()
        cancelDisplayCheck()
        restoreDisplay()
    }

    func prepareForQuit() -> Bool {
        quitting = true
        cancelLockCheck()
        cancelDisplayCheck()
        restoreDisplay()
        return !restorationRequired
    }

    func cancelQuit() { quitting = false }

    func stop() {
        started = false
        cancelLockCheck()
        cancelDisplayCheck()
        monitor?.stop()
        restoreDisplay()
        lastState = nil
    }

    func retry() {
        log.notice(.lid, "User asked to restore the built-in display or lid monitoring")
        restoreDisplay()
        if monitoringMessage != nil {
            monitor?.stop()
            started = false
            start()
        }
    }

    func waitUntilSettled() async {
        await lockCheck?.value
        await displayCheck?.value
    }

    private func receive(_ event: LidEvent) {
        guard started else { return }
        switch event {
        case .suspend(let reason):
            log.info(.lid, "Lid actions paused: \(reason == .systemSleep ? "the system is going to sleep" : "this user is not at the console")")
            suspensions.insert(reason)
            cancelLockCheck()
            cancelDisplayCheck()
            restoreDisplay()
            lastState = nil
        case .resume(let reason):
            suspensions.remove(reason)
            // Waking the Mac does not put a switched-away user back on console.
            guard suspensions.isEmpty else { return }
            // Reconcile after wake/user switching without replaying a stale closure.
            lastState = monitor?.currentState
            log.info(.lid, "Lid actions resumed after \(reason == .systemSleep ? "wake" : "this user returned"); the lid is \(Self.describe(lastState))")
            if lastState != true || !keepAwakeIsActive() { restoreDisplay() }
        case .changed(let closed):
            let previous = lastState
            lastState = closed
            // The same notification also reports policy changes; log lid movement only.
            if previous != closed { log.notice(.lid, "Lid \(Self.describe(closed)) (was \(Self.describe(previous)))") }
            guard let closed else {
                cancelLockCheck()
                cancelDisplayCheck()
                restoreDisplay()
                monitoringMessage = "The lid state is unavailable. Close-lid actions are paused."
                return
            }
            monitoringMessage = nil
            if !closed {
                cancelLockCheck()
                cancelDisplayCheck()
                restoreDisplay()
                return
            }
            guard previous == false, suspensions.isEmpty, !quitting, keepAwakeIsActive() else {
                if previous == false {
                    log.info(.lid, "No action on close: "
                        + (!suspensions.isEmpty ? "lid actions are paused" : quitting ? "Caffeine is quitting" : "Keep awake is not active"))
                }
                return
            }
            if !lockScreenOnLidClose && !turnOffDisplayOnLidClose { log.info(.lid, "No action on close: both functions are off") }
            // Request the lock synchronously, before macOS can sleep after the close.
            if lockScreenOnLidClose { requestLock() }
            if turnOffDisplayOnLidClose {
                displayOffMessage = nil
                log.notice(.lid, "Asking macOS to turn off the built-in display")
                do { try actions?.turnOffBuiltInDisplay(); displayMessage = nil; confirmDisplayOff() }
                catch {
                    displayMessage = error.localizedDescription
                    log.error(.lid, "The built-in display could not be turned off: \(error.localizedDescription)")
                }
                restorationRequired = actions?.needsDisplayRestoration == true
            }
        }
    }

    private func requestLock() {
        cancelLockCheck()
        lockMessage = nil
        guard let actions else { return }
        if actions.screenIsLocked() == true {
            log.info(.lid, "The screen is already locked")
            return
        }
        log.notice(.lid, "Asking macOS to lock the screen")
        do { try actions.lockScreen() }
        catch {
            lockMessage = error.localizedDescription
            log.error(.lid, "The screen could not be locked: \(error.localizedDescription)")
            return
        }
        let attempt = lockAttempt
        lockCheck = Task { @MainActor [weak self, waitForLock, log] in
            do { try await waitForLock() } catch { return }
            guard let self, !Task.isCancelled, self.lockAttempt == attempt else { return }
            // The private lock function has no reliable success result.
            if actions.screenIsLocked() != true {
                self.lockMessage = "macOS hasn’t confirmed the screen lock. Check your screen before leaving your Mac."
                log.error(.lid, "macOS has not confirmed the screen lock")
            } else {
                log.notice(.lid, "The screen is locked")
            }
        }
    }

    private func cancelLockCheck() {
        lockAttempt = UUID()
        lockCheck?.cancel(); lockCheck = nil
    }

    /// A display request reports no dependable result either. Read the panel back,
    /// so a request that macOS ignored becomes a visible error.
    private func confirmDisplayOff() {
        cancelDisplayCheck()
        guard let actions else { return }
        let attempt = displayAttempt
        displayCheck = Task { @MainActor [weak self, waitForDisplay, log] in
            do { try await waitForDisplay() } catch { return }
            guard let self, !Task.isCancelled, self.displayAttempt == attempt else { return }
            let state = actions.builtInDisplayIsOff()
            if state != true {
                self.displayOffMessage = "macOS hasn’t confirmed that the built-in display turned off."
                log.error(.lid, state == false ? "The built-in display is still on after the request"
                                               : "The displays could not be read after the request")
            } else {
                log.notice(.lid, "The built-in display is off")
            }
        }
    }

    private func cancelDisplayCheck() {
        displayAttempt = UUID()
        displayCheck?.cancel(); displayCheck = nil
    }

    private func restoreDisplay() {
        guard let actions, actions.needsDisplayRestoration else { restorationRequired = false; return }
        do {
            try actions.restoreBuiltInDisplay()
            restorationRequired = actions.needsDisplayRestoration
            displayMessage = nil
            log.notice(.lid, "The built-in display is connected again")
        } catch {
            restorationRequired = true
            displayMessage = "Caffeine couldn’t confirm that the built-in display was restored. Open the lid and try restoring it before quitting."
            log.error(.lid, "The built-in display could not be restored: \(error.localizedDescription)")
        }
    }
}
