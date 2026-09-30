import AppKit
import CaffeineCore
import CaffeineLogging
import CaffeineServiceProtocol
import Foundation
import Observation

@MainActor
protocol CaffeineSessionPresenting: AnyObject {
    var requested: Bool { get }
    var onlyWhenCharging: Bool { get }
    var closedLidMode: Bool { get }
    var timerPreset: TimerPreset { get }
    var statusTitle: String { get }
    var statusMessage: String? { get }
    var actionTitle: String? { get }
    var isActive: Bool { get }
    var isPending: Bool { get }
    var isCleanupUncertain: Bool { get }
    var canToggleKeepAwake: Bool { get }
    var timerDisplayValue: String { get }
    var isPreview: Bool { get }
    func setKeepAwake(_ enabled: Bool)
    func setOnlyWhenCharging(_ enabled: Bool)
    func setClosedLidMode(_ enabled: Bool)
    func selectTimer(_ preset: TimerPreset)
    func retry()
    func stopForQuit() async -> Bool
}

extension SessionController: CaffeineSessionPresenting {}

/// The helper owns power, policy and expiry. This model owns UI intent and preferences.
/// Serial requests ensure a later Stop supersedes every pending Start/update reply.
@Observable
@MainActor
final class CaffeineSessionModel: CaffeineSessionPresenting, SetupGuidePresenting {
    private enum Phase: String {
        case off, checking, starting, active, waitingForPower, powerSourceUnavailable, stopping
        case setupRequired, approvalRequired, failed, externalOverride, cleanupRequired
        case serviceUpdateRequired, updatingService
    }

    private(set) var requested = false
    private(set) var onlyWhenCharging: Bool
    private(set) var closedLidMode: Bool
    private(set) var timerPreset: TimerPreset
    private var phase: Phase = .off {
        didSet { if phase != oldValue { log.notice(.session, "State: \(oldValue.rawValue) → \(phase.rawValue)") } }
    }
    private var detail: String?
    private var serviceUpdateAvailable = false
    private var remainingSeconds: Int?
    private var loginMessage: String?
    private var loginAction: String?
    /// What macOS reports, for the setup screen. Copied whenever registration status is read.
    private var registeredService: SetupStep
    private(set) var loginStep: SetupStep
    private(set) var isReconnecting = false
    let isPreview = false

    static let reconnectDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(10), .seconds(20)]
    /// macOS announces no approval. Five awake minutes of status-only checks.
    static let approvalPollInterval: Duration = .seconds(2)
    static let approvalPollLimit = 150

    @ObservationIgnored private let client: any HelperRequesting
    @ObservationIgnored private let setup: any SystemServiceManaging
    @ObservationIgnored private let preferences: any SessionPreferences
    @ObservationIgnored private let playActivationSound: () -> Void
    @ObservationIgnored private let waitToReconnect: (Duration) async throws -> Void
    @ObservationIgnored private let waitForApproval: (Duration) async throws -> Void
    @ObservationIgnored private let log: EventLog
    @ObservationIgnored private var hasPlayedActivationSound = false
    /// Observed, unlike its neighbors: the setup screen tells a failed start from a service that does not answer.
    private var ready = false
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var ownsConnectionGeneration = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var mayNeedCleanup = false
    @ObservationIgnored private var quitting = false
    @ObservationIgnored private var needsStart = false
    @ObservationIgnored private var needsUpdate = false
    @ObservationIgnored private var needsStop = false
    @ObservationIgnored private var needsHeartbeat = false
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var needsServiceUpdate = false
    @ObservationIgnored private var needsReconnectStatus: UUID?
    @ObservationIgnored private var reconnectID = UUID()
    @ObservationIgnored private var reconnectAllowed = true
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var approvalWatchID = UUID()
    @ObservationIgnored private var approvalWatchAllowed = true
    @ObservationIgnored private var approvalWatch: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pulse: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var countdownOrigin: ContinuousClock.Instant?
    @ObservationIgnored private var snapshotRemaining: Int?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var started = false

    init(client: any HelperRequesting = HelperClient(), setup: any SystemServiceManaging = SystemServiceSetup(),
         preferences: any SessionPreferences = UserDefaultsSessionPreferences(),
         playActivationSound: @escaping () -> Void = {},
         waitToReconnect: @escaping (Duration) async throws -> Void = { try await SuspendingClock().sleep(for: $0) },
         waitForApproval: @escaping (Duration) async throws -> Void = { try await SuspendingClock().sleep(for: $0) },
         log: EventLog = .disabled) {
        self.log = log
        self.client = client
        self.setup = setup
        self.preferences = preferences
        self.playActivationSound = playActivationSound
        self.waitToReconnect = waitToReconnect
        self.waitForApproval = waitForApproval
        onlyWhenCharging = preferences.onlyWhenCharging
        closedLidMode = preferences.closedLidMode
        timerPreset = preferences.timerPreset
        registeredService = setup.helperStep
        loginStep = setup.loginStep
        client.onDisconnect = { [weak self] error in self?.connectionLost(error) }
    }

    var statusTitle: String {
        if isReconnecting && !mayNeedCleanup { return "Reconnecting…" }
        return switch phase {
        case .off: "Keep awake is off"
        case .checking: "Checking session…"
        case .starting: "Starting…"
        case .active: "Keeping your Mac awake"
        case .waitingForPower: "Waiting for power"
        case .powerSourceUnavailable: "Power source unavailable"
        case .stopping: "Stopping…"
        case .setupRequired: "Setup required"
        case .approvalRequired: "Approval required"
        case .failed: "Couldn’t start Keep awake"
        case .externalOverride: "Sleep is already disabled"
        case .cleanupRequired: "Couldn’t stop Keep awake"
        case .serviceUpdateRequired: "Service update required"
        case .updatingService: "Updating background service…"
        }
    }

    var statusMessage: String? {
        if isReconnecting {
            return mayNeedCleanup
                ? (detail ?? "Restoration is unconfirmed.") + " Reconnecting to verify recovery. Keep awake won’t restart automatically."
                : "Reconnecting to Caffeine’s background service. Keep awake will stay off."
        }
        return switch phase {
        case .setupRequired:
            "Allow Caffeine to keep your Mac awake with the lid closed. macOS will ask you to approve its background service."
        case .approvalRequired:
            "Approve Caffeine in System Settings → General → Login Items & Extensions. Then turn on Keep awake."
        case .failed: detail ?? "Caffeine couldn’t connect to its background service. Keep awake hasn’t started."
        case .serviceUpdateRequired: detail
        case .updatingService: "Keep awake will stay off after the update."
        case .externalOverride: "Sleep was disabled outside Caffeine. Restore that setting before starting a session."
        case .cleanupRequired: detail ?? "Your Mac may still stay awake. Try restoring Caffeine’s sleep settings before quitting."
        case .powerSourceUnavailable: "Caffeine is waiting for a known external power source."
        default: loginMessage
        }
    }

    var actionTitle: String? {
        switch phase {
        case .setupRequired: "Set Up…"
        case .approvalRequired: "Open System Settings"
        case .failed, .cleanupRequired: "Try Again"
        case .externalOverride: "Try Again"
        case .serviceUpdateRequired: serviceUpdateAvailable ? "Update Service" : "Check Again"
        case .updatingService: nil
        case .powerSourceUnavailable: nil
        default: loginAction
        }
    }

    var isActive: Bool { phase == .active }
    var isPending: Bool { isReconnecting || phase == .starting || phase == .stopping || phase == .checking || phase == .updatingService }
    var isCleanupUncertain: Bool { phase == .cleanupRequired }
    var canToggleKeepAwake: Bool { requested || (!quitting && !mayNeedCleanup && !isPending && phase != .serviceUpdateRequired) }
    var timerDisplayValue: String {
        guard requested, let seconds = remainingSeconds else { return timerPreset.title }
        if seconds >= 3600 { return String(format: "%d:%02d:%02d left", seconds / 3600, (seconds % 3600) / 60, seconds % 60) }
        return String(format: "%d:%02d left", seconds / 60, seconds % 60)
    }

    func start() {
        guard !started else { return }
        started = true
        log.info(.session, "Saved preferences: \(preferenceSummary). Keep awake starts off")
        setup.prepareServices()
        copySetupStatus()
        refresh()
    }

    /// For the exported log: what the card shows and the saved choices.
    var preferenceSummary: String {
        "Closed Lid Mode \(closedLidMode ? "on" : "off"), Only When Charging \(onlyWhenCharging ? "on" : "off"), Timer \(timerPreset.title)"
    }

    func shutdown() {
        started = false
        cancelReconnect()
        cancelApprovalWatch()
        pulse?.cancel(); pulse = nil
        ticker?.cancel(); ticker = nil
        endActivity()
        client.invalidate()
    }

    /// Called on activation, wake and card opening. It reads status only; the
    /// disposable card owns no timer, registration or session.
    func refresh() {
        setup.refreshLoginStatus()
        copySetupStatus()
        if requested {
            needsHeartbeat = true
        } else {
            needsRefresh = true
        }
        schedule()
    }

    func setKeepAwake(_ enabled: Bool) {
        if enabled {
            guard !requested, canToggleKeepAwake else {
                log.info(.session, "Keep awake on was ignored in state \(phase.rawValue)")
                return
            }
            // Completing setup never revives this attempt. A fresh toggle is required.
            guard ready else {
                log.notice(.session, "User turned Keep awake on, but the service is not ready (\(phase.rawValue)); reading its status instead")
                refresh()
                return
            }
            cancelReconnect(resetBudget: true)
            generation = UUID()
            log.notice(.session, "User turned Keep awake on: session \(Self.short(generation)), \(preferenceSummary)")
            hasPlayedActivationSound = false
            requested = true
            needsStart = true
            phase = .starting
            detail = nil
            synchronizeActivity()
        } else {
            guard requested || mayNeedCleanup else { return }
            log.notice(.session, "\(quitting ? "Quit" : "User") turned Keep awake off\(requested ? "" : " to retry unconfirmed restoration")")
            cancelReconnect()
            requested = false
            needsStart = false
            needsUpdate = false
            needsHeartbeat = false
            needsStop = true
            phase = .stopping
            clearCountdown()
            synchronizeActivity()
        }
        schedule()
    }

    func setOnlyWhenCharging(_ enabled: Bool) {
        guard onlyWhenCharging != enabled else { return }
        log.notice(.session, "User set Only When Charging to \(enabled ? "on" : "off")")
        onlyWhenCharging = enabled
        preferences.onlyWhenCharging = enabled
        if requested { needsUpdate = true; schedule() }
    }

    func selectTimer(_ preset: TimerPreset) {
        guard timerPreset != preset else { return }
        log.notice(.session, "User set Timer to \(preset.title)")
        timerPreset = preset
        preferences.timerPreset = preset
        if requested { needsUpdate = true; schedule() }
    }

    func setClosedLidMode(_ enabled: Bool) {
        guard closedLidMode != enabled else { return }
        log.notice(.session, "User set Closed Lid Mode to \(enabled ? "on" : "off")")
        closedLidMode = enabled
        preferences.closedLidMode = enabled
        if requested { needsUpdate = true; phase = .starting; schedule() }
    }

    func retry() {
        guard !quitting else { return }
        log.notice(.session, "User chose “\(actionTitle ?? "the card action")” in state \(phase.rawValue)")
        cancelReconnect(resetBudget: true)
        switch phase {
        case .serviceUpdateRequired:
            if serviceUpdateAvailable {
                needsServiceUpdate = true
                ready = false
                phase = .updatingService
                schedule()
            } else { refresh() }
        case .updatingService: break
        case .setupRequired: registerService()
        case .approvalRequired: requestApproval()
        case .cleanupRequired:
            needsStop = true
            phase = .stopping
            schedule()
        case .failed:
            if ready { setKeepAwake(true) }
            else { setup.retrySetup(); refresh() }
        case .externalOverride: setKeepAwake(true)
        default:
            setup.performLoginAction()
            copySetupStatus()
        }
    }

    private func registerService() {
        do { try setup.registerHelper(); refresh() }
        catch {
            phase = .failed; detail = error.localizedDescription; ready = false
            registeredService = SetupStep(state: .failed, actionTitle: "Try Again", note: error.localizedDescription)
            log.error(.session, "Setup failed: \(error.localizedDescription)")
        }
    }

    private func requestApproval() {
        // Approval may already have been given while the card was closed.
        guard setup.helperAwaitsApproval else { refresh(); return }
        setup.openSettings()
        cancelApprovalWatch(resetBudget: true)
        beginApprovalWatch()
    }

    var canSetUp: Bool { setup.canSetUp }

    /// An allowed service that cannot be used is not "all set". The card has the reason
    /// and the way out; the screen only points there.
    var serviceStep: SetupStep {
        registeredService.state == .allowed && serviceNeedsTheCard ? .attention : registeredService
    }

    private var serviceNeedsTheCard: Bool {
        switch phase {
        case .serviceUpdateRequired, .updatingService, .cleanupRequired: true
        // A lost connection, also while it is retried. A start that the service
        // itself refused is not a setup problem.
        case .failed: !ready
        default: false
        }
    }

    /// From the setup screen. It registers, asks for approval or reads status
    /// again. Unlike `retry()` it can never start Keep awake.
    func performServiceStep() {
        guard !quitting, phase != .updatingService else { return }
        log.notice(.setup, "User chose “\(serviceStep.actionTitle ?? "the background service")” on the setup screen")
        // A live session and unconfirmed restoration keep their own flow in the card.
        guard !requested, !mayNeedCleanup else { refresh(); return }
        switch setup.helperStep.state {
        case .allowed, .attention: refresh()
        case .needsApproval: requestApproval()
        case .off: registerService()
        case .failed: setup.retrySetup(); refresh()
        }
    }

    func performLoginStep() {
        guard !quitting else { return }
        log.notice(.setup, "User chose “\(loginStep.actionTitle ?? "launch at login")” on the setup screen")
        setup.refreshLoginStatus()
        // It may have been switched on in System Settings meanwhile.
        if setup.loginStep.state != .allowed { setup.performLoginAction() }
        copySetupStatus()
    }

    func setupGuideDidOpen() {
        setup.acknowledgeLoginExplanation()
        copySetupStatus()
    }

    func stopForQuit() async -> Bool {
        log.notice(.session, "Quit requested in state \(phase.rawValue)")
        quitting = true
        cancelReconnect()
        cancelApprovalWatch(resetBudget: true)
        if requested || mayNeedCleanup || generation != nil {
            setKeepAwake(false)
            needsStop = true
            schedule()
        }
        await worker?.value
        let canQuit = !requested && !mayNeedCleanup && generation == nil
        if canQuit { log.notice(.session, "Nothing is held; Quit can proceed") }
        else { log.error(.session, "Quit is blocked: restoring sleep settings is unconfirmed (\(phase.rawValue))") }
        if !canQuit { quitting = false }
        return canQuit
    }

    private func schedule() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcile()
            self.worker = nil
        }
    }

    private func reconcile() async {
        while true {
            do {
                if needsServiceUpdate {
                    needsServiceUpdate = false
                    try await updateService()
                    continue
                }
                if needsStop {
                    needsStop = false
                    // An invalidated connection can only inspect/retry orphaned recovery.
                    if !client.isConnected || !ownsConnectionGeneration {
                        let status = try await send(ServiceRequest(action: .status, revision: revision))
                        if !status.snapshot.requested && status.snapshot.phase == .off {
                            accept(status)
                            continue
                        }
                        if status.snapshot.requested {
                            ready = false
                            phase = mayNeedCleanup ? .cleanupRequired : .failed
                            if !mayNeedCleanup { generation = nil }
                            detail = "Another Caffeine connection owns the active session. Wait for it to finish before trying again."
                            log.error(.session, "Stop withheld: another connection owns the active session")
                            return // Never stop another connection's live session.
                        }
                        generation = nil
                    }
                    let reply = try await send(ServiceRequest(action: .stop, generation: generation, revision: nextRevision()))
                    accept(reply)
                    continue
                }
                if needsRefresh && !requested {
                    needsRefresh = false
                    try await refreshService()
                    continue
                }
                if let id = needsReconnectStatus {
                    needsReconnectStatus = nil
                    guard canReconnect(id) else { continue }
                    do { try await refreshService(reconnectID: id) }
                    catch {
                        // A cancelled probe cannot overwrite a newer explicit
                        // retry, service update, shutdown or Quit decision.
                        guard canReconnect(id) else { continue }
                        throw error
                    }
                    continue
                }
                if requested, needsStart, let generation {
                    needsStart = false
                    let charging = onlyWhenCharging
                    let duration = timerPreset.rawValue
                    mayNeedCleanup = true // Even a lost Start reply may follow a completed write.
                    ownsConnectionGeneration = true
                    let reply = try await send(ServiceRequest(action: .start, generation: generation,
                        revision: nextRevision(), onlyWhenCharging: charging, closedLidMode: closedLidMode, durationSeconds: duration))
                    accept(reply)
                    continue
                }
                if requested, needsUpdate, let generation {
                    needsUpdate = false
                    let reply = try await send(ServiceRequest(action: .update, generation: generation,
                        revision: nextRevision(), onlyWhenCharging: onlyWhenCharging, closedLidMode: closedLidMode, durationSeconds: timerPreset.rawValue))
                    accept(reply, action: .update)
                    continue
                }
                if requested, needsHeartbeat, let generation {
                    needsHeartbeat = false
                    let reply = try await send(ServiceRequest(action: .heartbeat, generation: generation, revision: nextRevision()))
                    accept(reply, action: .heartbeat)
                    continue
                }
                return
            } catch {
                log.error(.session, "Stopped after a failed request in state \(phase.rawValue)\(requested ? ", Keep awake was on" : "")"
                    + "\(mayNeedCleanup ? ", restoration is unconfirmed" : ""): \(error.localizedDescription)")
                requested = false
                ready = false
                needsStart = false; needsUpdate = false; needsHeartbeat = false; needsStop = false; needsRefresh = false
                needsServiceUpdate = false
                phase = mayNeedCleanup ? .cleanupRequired : .failed
                detail = error.localizedDescription
                serviceUpdateAvailable = false
                if let canUpdate = (error as? HelperClient.Failure)?.serviceUpdateEligibility, !mayNeedCleanup {
                    phase = .serviceUpdateRequired
                    serviceUpdateAvailable = canUpdate
                }
                if !mayNeedCleanup { generation = nil }
                clearCountdown()
                synchronizeActivity()
                if (error as? HelperClient.Failure)?.isTransientConnectionFailure == true {
                    ownsConnectionGeneration = false
                    beginReconnect()
                    explainUnreachableService()
                } else {
                    cancelReconnect()
                }
                return
            }
        }
    }

    private func updateService() async throws {
        guard !requested, !mayNeedCleanup, !quitting else { return }
        guard case .readyToConnect = setup.availability else {
            try await refreshService()
            return
        }
        // Recheck at the user's click: a cached idle snapshot is insufficient.
        // A current-version reply means another update already resolved the issue.
        do {
            let reply = try await send(ServiceRequest(action: .status, revision: revision))
            accept(reply)
            return
        } catch let error as HelperClient.Failure where error.serviceUpdateEligibility == true {
            guard !requested, !mayNeedCleanup, !quitting else { return }
        }
        log.notice(.session, "Updating the background service; it confirmed that it is idle and settled")
        client.invalidate()
        ownsConnectionGeneration = false
        serviceUpdateAvailable = false
        phase = .updatingService
        try await setup.updateHelper()
        try await refreshService()
    }

    /// Every exchange with the service. A renewal every few seconds stays out
    /// of the file unless it fails.
    private func send(_ request: ServiceRequest) async throws -> ServiceReply {
        let routine = request.action == .heartbeat
        let name = request.action.rawValue
        log.log(routine ? .debug : .info, .service,
                "Sending \(name), revision \(request.revision), session \(Self.short(request.generation))")
        do {
            let reply = try await client.request(request)
            log.log(routine && reply.failure == nil ? .debug : .info, .service, "Reply to \(name): \(Self.describe(reply))")
            return reply
        } catch {
            log.error(.service, "\(name) failed: \(error.localizedDescription)")
            throw error
        }
    }

    private static func short(_ identifier: UUID?) -> String {
        identifier.map { String($0.uuidString.prefix(8)) } ?? "none"
    }

    private static func describe(_ reply: ServiceReply) -> String {
        let snapshot = reply.snapshot
        return "phase \(snapshot.phase.rawValue), \(snapshot.requested ? "session \(short(snapshot.generation))" : "no session")"
            + ", ready \(snapshot.readyForSession ? "yes" : "no"), power \(snapshot.powerSource.rawValue)"
            + (snapshot.remainingSeconds.map { ", \($0) s left" } ?? "")
            + ", helper build \(reply.helperBuild.map(String.init) ?? "unknown")"
            + (reply.failure.map { ", failure \($0.code.rawValue) – \($0.message)" } ?? "")
            + (snapshot.message.map { ", message: \($0)" } ?? "")
    }

    private func refreshService(reconnectID: UUID? = nil) async throws {
        // A service update and a reconnect check arrive here without `refresh()`.
        copySetupStatus()
        switch setup.availability {
        case .setupRequired:
            cancelReconnect()
            cancelApprovalWatch(resetBudget: true)
            ready = false; phase = mayNeedCleanup ? .cleanupRequired : .setupRequired
        case .approvalRequired:
            cancelReconnect()
            ready = false; phase = mayNeedCleanup ? .cleanupRequired : .approvalRequired
            beginApprovalWatch()
        case .unavailable(let message):
            cancelReconnect()
            cancelApprovalWatch(resetBudget: true)
            ready = false; phase = mayNeedCleanup ? .cleanupRequired : .failed; detail = message
        case .readyToConnect:
            cancelApprovalWatch(resetBudget: true)
            let reply = try await send(ServiceRequest(action: .status, revision: revision))
            if let reconnectID, !canReconnect(reconnectID) { return }
            // A status reply may arrive after a fresh user toggle. A clean
            // pre-start snapshot must not cancel that newer request.
            if requested && needsStart && reply.snapshot.readyForSession && !reply.snapshot.requested {
                ready = true
                return
            }
            accept(reply)
        }
    }

    func waitUntilSettled() async { await worker?.value }

    private func accept(_ reply: ServiceReply, action: ServiceAction? = nil) {
        serviceUpdateAvailable = false
        let snapshot = reply.snapshot
        // A recovery snapshot can carry actionable guidance without a request
        // failure. Keep it visible, and discard it once a fresh snapshot settles.
        detail = snapshot.message
        let endedOwnedSession = (action == .update || action == .heartbeat)
            && reply.failure?.code == .notOwner && snapshot.phase == .off && !snapshot.requested
            && snapshot.generation == generation && ownsConnectionGeneration
        if snapshot.requested {
            guard snapshot.generation == generation && ownsConnectionGeneration else {
                // A reconnect is a different owner even when it observes our old UUID.
                // An explicit rejection for a different generation proves this Start was refused.
                if snapshot.generation != generation && (reply.failure?.code == .busy || reply.failure?.code == .notOwner) {
                    mayNeedCleanup = false
                    generation = nil
                }
                ready = false
                requested = false
                needsStart = false; needsUpdate = false; needsHeartbeat = false; needsStop = false
                phase = mayNeedCleanup ? .cleanupRequired : .failed
                detail = "Another Caffeine connection owns the active session. Wait for it to finish before trying again."
                log.error(.session, "The active session belongs to another connection; it was not adopted")
                clearCountdown()
                synchronizeActivity()
                return
            }
            mayNeedCleanup = true
            if requested {
                phase = presentationPhase(snapshot.phase)
                snapshotRemaining = snapshot.remainingSeconds.map { max(0, $0) }
                countdownOrigin = ContinuousClock().now
                remainingSeconds = snapshotRemaining
            } else {
                // A late activation reply must not turn the user's switch back on.
                phase = .stopping
                needsStop = true
            }
        } else {
            requested = false
            let unsettledSnapshot = !snapshot.isSettled
            mayNeedCleanup = snapshot.phase == .cleanupRequired || snapshot.phase == .stopping || snapshot.phase == .starting
                || (mayNeedCleanup && unsettledSnapshot)
            if !mayNeedCleanup { generation = nil; ownsConnectionGeneration = false }
            phase = mayNeedCleanup && unsettledSnapshot ? .cleanupRequired : presentationPhase(snapshot.phase)
            clearCountdown()
            needsStart = false; needsUpdate = false; needsHeartbeat = false
        }
        ready = snapshot.readyForSession
        if endedOwnedSession { log.notice(.session, "The service ended the session: \(reply.failure?.message ?? "expired")") }
        if let failure = reply.failure, !endedOwnedSession {
            log.error(.session, "The service reported \(failure.code.rawValue): \(failure.message)")
            detail = failure.message
            if !mayNeedCleanup && snapshot.phase == .off { phase = .failed }
            // A failed renewal/update never leaves stale intent armed.
            if requested {
                requested = false
                needsStop = true
                phase = .stopping
                clearCountdown()
            }
        }
        synchronizeActivity()
        if snapshot.isSettled && !mayNeedCleanup {
            if isReconnecting { log.notice(.session, "Reconnected; the service is settled and Keep awake stays off") }
            cancelReconnect(resetBudget: true)
        }
        playActivationSoundIfNeeded(for: reply)
    }

    private func playActivationSoundIfNeeded(for reply: ServiceReply) {
        let snapshot = reply.snapshot
        // Only acknowledge the first verified hold for this user request. Wait for
        // any newer preferences, and never announce a cancelled or failed operation.
        guard started, !quitting, requested, phase == .active, !hasPlayedActivationSound,
              !needsStart, !needsUpdate, !needsStop, reply.failure == nil,
              ownsConnectionGeneration, let generation, snapshot.generation == generation,
              snapshot.requested, snapshot.phase == .active,
              snapshot.closedLidMode == closedLidMode,
              snapshot.onlyWhenCharging == onlyWhenCharging,
              snapshot.durationSeconds == timerPreset.rawValue else { return }
        hasPlayedActivationSound = true
        log.notice(.session, "Keep awake is confirmed active for session \(Self.short(generation)); playing the activation sound")
        playActivationSound()
    }

    private func presentationPhase(_ phase: ServicePhase) -> Phase {
        switch phase {
        case .off: .off
        case .starting: .starting
        case .active: .active
        case .waitingForPower: .waitingForPower
        case .powerSourceUnavailable: .powerSourceUnavailable
        case .stopping: .stopping
        case .externalOverride: .externalOverride
        case .cleanupRequired: .cleanupRequired
        case .unavailable: .failed
        }
    }

    private func connectionLost(_ error: Error) {
        guard started else { return }
        log.error(.session, "Lost the background service in state \(phase.rawValue)\(requested ? " while Keep awake was on" : ""): \(error.localizedDescription)")
        ownsConnectionGeneration = false
        ready = false
        // The service update handles its own probe and removal errors, including
        // the disconnect that an incompatible reply causes. No session is owned here.
        if phase == .updatingService { return }
        requested = false
        needsStart = false; needsUpdate = false; needsHeartbeat = false
        // A manual retry/Quit may already be queued behind a cancelled probe.
        // Its disconnect still ends ownership, but must not erase those actions.
        phase = mayNeedCleanup ? .cleanupRequired : .failed
        detail = mayNeedCleanup
            ? "Caffeine lost contact with its background service. Restoration is unconfirmed. Try again before quitting."
            : "Caffeine couldn’t connect to its background service. Keep awake hasn’t started."
        if !mayNeedCleanup { generation = nil }
        clearCountdown()
        synchronizeActivity()
        if (error as? HelperClient.Failure)?.isTransientConnectionFailure == true {
            beginReconnect()
            explainUnreachableService()
        }
    }

    private func canReconnect(_ id: UUID) -> Bool {
        started && !quitting && !requested && isReconnecting && reconnectID == id
    }

    private func beginReconnect() {
        guard started, !quitting, !requested, reconnectAllowed, !isReconnecting else { return }
        // Each fault gets one finite budget. Repeated transport callbacks and
        // foreground/wake refreshes cannot silently start an endless retry loop.
        reconnectAllowed = false
        isReconnecting = true
        let id = UUID()
        reconnectID = id
        log.info(.session, "Reconnecting: up to \(Self.reconnectDelays.count) status checks; Keep awake stays off")
        reconnectTask = Task { @MainActor [weak self, waitToReconnect, log] in
            for (attempt, delay) in Self.reconnectDelays.enumerated() {
                log.info(.session, "Reconnect check \(attempt + 1) of \(Self.reconnectDelays.count) in \(delay.components.seconds) s")
                do { try await waitToReconnect(delay) }
                catch {
                    if let self, self.reconnectID == id { self.cancelReconnect() }
                    return
                }
                guard let self, !Task.isCancelled, self.canReconnect(id) else { return }
                self.needsReconnectStatus = id
                self.schedule()
                await self.worker?.value
                guard self.canReconnect(id) else { return }
            }
            guard let self, self.reconnectID == id else { return }
            log.error(.session, "Reconnecting failed after \(Self.reconnectDelays.count) checks")
            self.cancelReconnect()
            self.explainUnreachableService()
        }
    }

    /// A helper left over from a replaced app cannot be authenticated. Once the
    /// automatic probes are spent, later refreshes keep this way forward visible.
    private func explainUnreachableService() {
        guard !isReconnecting, !reconnectAllowed, phase == .failed, !mayNeedCleanup, !requested else { return }
        detail = "Caffeine couldn’t reach its background service. If you just updated Caffeine, restart your Mac to finish the update."
    }

    private func cancelReconnect(resetBudget: Bool = false) {
        reconnectID = UUID()
        needsReconnectStatus = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        if resetBudget { reconnectAllowed = true }
    }

    /// One finite sequence per approval request. Wake and foreground refreshes
    /// cannot replenish it, and no check registers or starts anything.
    private func beginApprovalWatch() {
        guard started, !quitting, approvalWatchAllowed, approvalWatch == nil else { return }
        approvalWatchAllowed = false
        let id = UUID()
        approvalWatchID = id
        log.info(.setup, "Waiting for approval: reading the registration status every \(Self.approvalPollInterval.components.seconds) s")
        approvalWatch = Task { @MainActor [weak self, waitForApproval, log] in
            for _ in 0..<Self.approvalPollLimit {
                do { try await waitForApproval(Self.approvalPollInterval) }
                catch { break }
                guard let self, !Task.isCancelled, self.approvalWatchID == id else { return }
                if !self.setup.helperAwaitsApproval {
                    log.notice(.setup, "Approval is no longer pending; reading the service status")
                    self.cancelApprovalWatch(resetBudget: true)
                    self.refresh()
                    return
                }
            }
            guard let self, self.approvalWatchID == id else { return }
            log.info(.setup, "Stopped waiting for approval; opening the card checks again")
            self.cancelApprovalWatch()
        }
    }

    private func cancelApprovalWatch(resetBudget: Bool = false) {
        approvalWatchID = UUID()
        approvalWatch?.cancel()
        approvalWatch = nil
        if resetBudget { approvalWatchAllowed = true }
    }

    private func nextRevision() -> UInt64 { revision += 1; return revision }

    private func synchronizeActivity() {
        if requested {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Supervising Caffeine’s active session")
            }
            if pulse == nil {
                pulse = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await SuspendingClock().sleep(for: .seconds(5)) } catch { return }
                        guard let self, self.requested, !Task.isCancelled else { return }
                        self.needsHeartbeat = true
                        self.schedule()
                    }
                }
            }
            if snapshotRemaining != nil && ticker == nil {
                ticker = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await ContinuousClock().sleep(for: .seconds(1)) } catch { return }
                        guard let self, self.requested, !Task.isCancelled else { return }
                        self.renderCountdown()
                    }
                }
            } else if snapshotRemaining == nil {
                ticker?.cancel(); ticker = nil
            }
        } else {
            pulse?.cancel(); pulse = nil
            ticker?.cancel(); ticker = nil
            endActivity()
        }
    }

    private func renderCountdown() {
        guard let snapshotRemaining, let countdownOrigin else { return }
        let components = countdownOrigin.duration(to: ContinuousClock().now).components
        let elapsed = Double(components.seconds) + Double(components.attoseconds) / 1e18
        remainingSeconds = max(0, Int(ceil(Double(snapshotRemaining) - elapsed)))
        if remainingSeconds == 0 {
            // Rendering cannot expire/extend the helper's session; request authoritative reconciliation.
            phase = .checking
            needsHeartbeat = true
            schedule()
        }
    }

    private func clearCountdown() { snapshotRemaining = nil; countdownOrigin = nil; remainingSeconds = nil }
    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    private func copySetupStatus() {
        loginMessage = setup.loginMessage; loginAction = setup.loginActionTitle
        // An unchanged step must not redraw the setup screen.
        let service = setup.helperStep, login = setup.loginStep
        if registeredService != service { registeredService = service }
        if loginStep != login { loginStep = login }
    }
}
