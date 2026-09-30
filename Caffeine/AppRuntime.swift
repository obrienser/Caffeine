import AppKit
import CaffeineCore
import CaffeineLogging
import Observation

@MainActor
final class AppRuntime {
    /// Set once the setup screen has opened, so that it opens one time only.
    static let setupGuideKey = "caffeine.setupGuidePresented"

    let session: any CaffeineSessionPresenting
    let lidActions: LidActionsModel
    /// Lives as long as the app, so that it works while the card is closed.
    let shortcut: KeepAwakeShortcut
    let log: EventLog
    private let setup: (any SystemServiceManaging)?
    private let setupGuide: (any SetupGuidePresenting)?
    private let setupWindow: (any SetupGuideWindowing)?
    private let defaults: UserDefaults
    private lazy var exporter = LogExporter(log: log)
    private var ticker: Task<Void, Never>?
    private var started = false
    private var observations: [NSObjectProtocol] = []
    private var lastCardRefresh: ContinuousClock.Instant?

    /// With the card closed, the alert sound is the only sign that a press of the
    /// shortcut changed nothing.
    init(preview: Bool? = nil, setupWindow: (any SetupGuideWindowing)? = nil,
         shortcuts: (any GlobalShortcutRegistering)? = nil, refuseShortcut: @escaping () -> Void = { NSSound.beep() },
         defaults: UserDefaults = .standard) {
        let preview = preview ?? Self.isPreviewRun
        self.setupWindow = setupWindow
        self.defaults = defaults
        if preview {
            // A simulated session records nothing and writes no file.
            log = .disabled
            setup = nil
            setupGuide = SimulatedSetupGuide()
            let model = SessionController(backend: SimulatedSessionBackend(), preferences: InMemorySessionPreferences(), initialPowerSource: Self.previewPowerSource)
            session = model
            lidActions = LidActionsModel(preview: true, keepAwakeIsActive: { [weak model] in model?.requested == true && model?.isActive == true })
        } else {
            let log = AppLog.production()
            self.log = log
            let activationSound = ActivationSoundPlayer(log: log)
            let setup = SystemServiceSetup(log: log)
            self.setup = setup
            let model = CaffeineSessionModel(client: HelperClient(log: log), setup: setup,
                                             playActivationSound: { activationSound.play() }, log: log)
            session = model
            setupGuide = model
            lidActions = LidActionsModel(actions: SystemLidActions(displays: NativeLidDisplayHardware(log: log)),
                                         keepAwakeIsActive: { [weak model] in model?.requested == true && model?.isActive == true },
                                         log: log)
        }
        shortcut = KeepAwakeShortcut(session: session, registrar: shortcuts, refuse: refuseShortcut, log: log)
    }

    init(session: any CaffeineSessionPresenting, lidActions: LidActionsModel? = nil, log: EventLog = .disabled,
         setupGuide: (any SetupGuidePresenting)? = nil, setupWindow: (any SetupGuideWindowing)? = nil,
         shortcuts: (any GlobalShortcutRegistering)? = nil, refuseShortcut: @escaping () -> Void = {},
         defaults: UserDefaults = .standard) {
        self.session = session
        self.log = log
        setup = nil
        self.setupGuide = setupGuide
        self.setupWindow = setupWindow
        self.defaults = defaults
        self.lidActions = lidActions ?? LidActionsModel(preview: true, keepAwakeIsActive: { [weak session] in session?.requested == true && session?.isActive == true })
        shortcut = KeepAwakeShortcut(session: session, registrar: shortcuts, refuse: refuseShortcut, log: log)
    }

    func start() {
        guard !started else { return }
        started = true
        log.notice(.app, "\(AppLog.version) launched as process \(ProcessInfo.processInfo.processIdentifier) from "
            + "\(AppLog.abbreviatingHome(Bundle.main.bundlePath)) on \(AppLog.system)")
        lidActions.start()
        observeLidSession()
        if let real = session as? CaffeineSessionModel {
            real.start()
            observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak real, log] _ in
                Task { @MainActor in
                    log.info(.app, "The Mac woke; reading the service status")
                    real?.refresh()
                }
            })
            observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak real, log] _ in
                Task { @MainActor in
                    log.debug(.app, "Caffeine became active; reading the service status")
                    real?.refresh()
                }
            })
            // Opening the card does not activate a menu bar app, so observe its window.
            observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
                let window = (notification.object as AnyObject?).map { ObjectIdentifier($0) }
                Task { @MainActor in self?.cardDidOpen(window: window) }
            })
        } else {
            observeSession()
        }
        shortcut.start()
        openSetupGuideAtFirstLaunch()
    }

    /// Reads fresh status only. The card still owns no session, timer or registration.
    /// The setup screen coming to the front reads status in the same way.
    func cardDidOpen(window: ObjectIdentifier? = nil) {
        guard started else { return }
        // The key-window notification and the card's appearance arrive together.
        let now = ContinuousClock().now
        if let lastCardRefresh, lastCardRefresh.duration(to: now) < .seconds(1) { return }
        lastCardRefresh = now
        let opened = window.map { setupWindow?.owns($0) == true } == true ? "The setup screen came to the front" : "The card opened"
        log.info(.app, "\(opened); reading the service status")
        (session as? CaffeineSessionModel)?.refresh()
    }

    /// One time, at the first launch that can set anything up. The screen
    /// explains and completes what launch already registered; it registers nothing
    /// by itself and never turns on Keep awake.
    private func openSetupGuideAtFirstLaunch() {
        guard let setupGuide, let setupWindow else { return }
        if !setupGuide.isPreview {
            guard !defaults.bool(forKey: Self.setupGuideKey) else { return }
            // Outside Applications nothing can be set up. Keep the screen for the launch that can.
            guard setupGuide.canSetUp else {
                log.info(.setup, "The setup screen waits for a launch of the signed app in Applications")
                return
            }
            defaults.set(true, forKey: Self.setupGuideKey)
        }
        setupGuide.setupGuideDidOpen()
        log.notice(.setup, "The setup screen opened at the first launch: \(Self.describe(setupGuide))")
        setupWindow.open(setupGuide) { [weak self, weak setupGuide, log] in
            guard self?.started == true, let setupGuide else { return }
            log.notice(.setup, "The setup screen closed: \(Self.describe(setupGuide))")
        }
    }

    private static func describe(_ guide: any SetupGuidePresenting) -> String {
        func name(_ step: SetupStep) -> String {
            switch step.state {
            case .allowed: "allowed"
            case .needsApproval: "waiting for approval"
            case .off: "off"
            case .failed: "failed"
            case .attention: "allowed but not answering"
            }
        }
        return "background service \(name(guide.serviceStep)), launch at login \(name(guide.loginStep))"
    }

    /// Both logs with the versions and the state the card shows, saved where the user chooses.
    func exportLog() {
        exporter.export { [self] in report().data() }
    }

    func report(generated: Date = Date()) -> LogReport {
        var choices = lidActions.preferenceSummary
        if let real = session as? CaffeineSessionModel { choices = real.preferenceSummary + ", " + choices }
        return LogReport(generated: generated, summary: [
            ("App", AppLog.version),
            ("System", AppLog.system),
            ("Location", AppLog.abbreviatingHome(Bundle.main.bundlePath)),
            ("Mode", session.isPreview ? "UI preview with a simulated session" : ""),
            ("Status", session.statusTitle),
            ("Message", session.statusMessage ?? ""),
            ("Lid actions", lidActions.message ?? ""),
            ("Choices", choices),
            ("Shortcut", shortcut.summary),
            ("Services", setup?.registrationSummary ?? ""),
            ("Crash reports", AppLog.recentCrashReports().joined(separator: ", "))
        ], sections: [
            .init(title: "Application log", path: AppLog.abbreviatingHome(AppLog.location.directory + "/" + AppLog.location.name),
                  content: LogReport.read(AppLog.location)),
            .init(title: "Background service log", path: LogFileLocation.helper.directory + "/" + LogFileLocation.helper.name,
                  content: LogReport.read(.helper))
        ])
    }

    func stopForQuit() async -> Bool {
        guard lidActions.prepareForQuit() else {
            log.error(.app, "Quit is blocked: the built-in display has not been restored")
            lidActions.cancelQuit()
            return false
        }
        let sleepSettled = await session.stopForQuit()
        if !sleepSettled { lidActions.cancelQuit() }
        return sleepSettled
    }

    func stop() {
        if started { log.notice(.app, "Caffeine process \(ProcessInfo.processInfo.processIdentifier) exits") }
        defer { log.flush() }
        shortcut.stop()
        lidActions.stop()
        started = false
        setupWindow?.close()
        ticker?.cancel()
        ticker = nil
        for token in observations {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        observations.removeAll()
        (session as? CaffeineSessionModel)?.shutdown()
    }

    private func observeLidSession() {
        guard started else { return }
        withObservationTracking {
            _ = session.requested
            _ = session.isActive
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.observeLidSession()
            }
        }
        lidActions.sessionChanged()
    }

    private func observeSession() {
        guard started else { return }
        withObservationTracking {
            _ = session.requested
            _ = session.timerPreset
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateTicker()
                self?.observeSession()
            }
        }
        updateTicker()
    }

    private func updateTicker() {
        guard started, session.requested, session.timerPreset != .noLimit else {
            ticker?.cancel()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await ContinuousClock().sleep(for: .seconds(1)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                (self.session as? SessionController)?.tick()
            }
        }
    }

    private static var isPreviewRun: Bool {
        #if DEBUG
        #if CAFFEINE_UI_PREVIEW
        return true
        #else
        return ProcessInfo.processInfo.arguments.contains("--ui-preview")
            || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        #endif
        #else
        return false
        #endif
    }

    private static var previewPowerSource: PowerSource {
        ProcessInfo.processInfo.arguments.contains("--preview-on-battery") ? .battery : .external
    }
}
