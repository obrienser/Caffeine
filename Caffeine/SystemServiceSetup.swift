import Foundation
import Security
import ServiceManagement
import CaffeineLogging
import CaffeineServiceProtocol

@MainActor
protocol AppServiceRegistering {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: AppServiceRegistering {}

@MainActor
protocol SystemServiceManaging: AnyObject {
    var availability: SystemServiceSetup.Availability { get }
    var loginMessage: String? { get }
    var loginActionTitle: String? { get }
    /// Status only. It never registers a service or validates the installation.
    var helperAwaitsApproval: Bool { get }
    /// Status only, for the exported log.
    var registrationSummary: String { get }
    /// Status only, for the setup screen. Neither validates the installation.
    var helperStep: SetupStep { get }
    var loginStep: SetupStep { get }
    /// Whether this installation can register anything at all.
    var canSetUp: Bool { get }
    /// The setup screen explained launch at login; the card need not repeat it.
    func acknowledgeLoginExplanation()
    func registerHelper() throws
    func updateHelper() async throws
    func openSettings()
    func prepareServices()
    func retrySetup()
    func refreshLoginStatus()
    func performLoginAction()
}

@MainActor
final class SystemServiceSetup: SystemServiceManaging {
    enum Availability { case readyToConnect, setupRequired, approvalRequired, unavailable(String) }
    private let defaults: UserDefaults
    private let daemon: any AppServiceRegistering
    private let loginItem: any AppServiceRegistering
    private let installationCheck: (() -> String?)?
    private let waitToRegisterAgain: (Duration) async throws -> Void
    private let openLoginItems: () -> Void
    private let log: EventLog
    private var loggedAvailability: String?
    private var loggedLoginStatus: String?
    // Earlier versions persisted an attempt before they actually registered.
    // These receipts record only accepted registration, so a skipped one is tried at launch.
    private let enrollmentKey = "caffeine.loginRegistrationAccepted"
    private let helperEnrollmentKey = "caffeine.helperRegistrationAccepted"
    // Set while this app's own service update has removed the registration.
    private let replacementKey = "caffeine.helperReplacementPending"
    private let explanationKey = "caffeine.loginExplanationAcknowledged"
    /// macOS can refuse a registration that immediately follows removal.
    static let registrationRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(3)]
    private var prepared = false
    private var helperRegistrationError: String?
    private var loginRegistrationFailed = false
    private(set) var loginMessage: String?
    private(set) var loginActionTitle: String?

    init(defaults: UserDefaults = .standard,
         daemon: any AppServiceRegistering = SMAppService.daemon(plistName: CaffeineServiceIdentity.daemonPlist),
         loginItem: any AppServiceRegistering = SMAppService.mainApp,
         installationCheck: (() -> String?)? = nil,
         waitToRegisterAgain: @escaping (Duration) async throws -> Void = { try await SuspendingClock().sleep(for: $0) },
         openLoginItems: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() },
         log: EventLog = .disabled) {
        self.defaults = defaults
        self.daemon = daemon
        self.loginItem = loginItem
        self.installationCheck = installationCheck
        self.waitToRegisterAgain = waitToRegisterAgain
        self.openLoginItems = openLoginItems
        self.log = log
    }

    var helperAwaitsApproval: Bool { daemon.status == .requiresApproval }

    var registrationSummary: String {
        "background service \(Self.name(daemon.status)), launch at login \(Self.name(loginItem.status))"
    }

    var canSetUp: Bool { installationProblem == nil }

    var helperStep: SetupStep {
        switch daemon.status {
        case .enabled: return .allowed
        case .requiresApproval:
            return SetupStep(state: .needsApproval, actionTitle: "Open System Settings", note: SetupStep.approvalNote)
        case .notRegistered, .notFound:
            if let helperRegistrationError {
                return SetupStep(state: .failed, actionTitle: "Try Again", note: helperRegistrationError)
            }
            return SetupStep(state: .off, actionTitle: "Set Up…")
        @unknown default:
            return SetupStep(state: .failed, note: "Caffeine couldn’t read the background service status.")
        }
    }

    /// The same cases and actions as the card's login message.
    var loginStep: SetupStep {
        if loginRegistrationFailed && (loginItem.status == .notRegistered || loginItem.status == .notFound) {
            return SetupStep(state: .failed, actionTitle: "Try Again", note: "Caffeine couldn’t enable launch at login.")
        }
        switch loginItem.status {
        case .enabled: return .allowed
        case .requiresApproval:
            return SetupStep(state: .needsApproval, actionTitle: "Open System Settings", note: SetupStep.approvalNote)
        case .notRegistered:
            return SetupStep(state: .off, actionTitle: "Open System Settings", note: "Launch at login is off.")
        case .notFound:
            return SetupStep(state: .off, actionTitle: "Set Up Login…")
        @unknown default:
            return SetupStep(state: .failed, actionTitle: "Open System Settings", note: "Caffeine couldn’t read its login status.")
        }
    }

    func acknowledgeLoginExplanation() {
        guard !defaults.bool(forKey: explanationKey) else { return }
        defaults.set(true, forKey: explanationKey)
        refreshLoginStatus()
    }

    var availability: Availability {
        let result = currentAvailability
        // Read on every refresh; only a change is worth a line.
        let summary: String = switch result {
        case .readyToConnect: "registered and enabled"
        case .approvalRequired: "registered, waiting for approval in System Settings"
        case .setupRequired: "not registered (\(Self.name(daemon.status)))"
        case .unavailable(let message): "unavailable – \(message)"
        }
        if summary != loggedAvailability {
            loggedAvailability = summary
            if case .unavailable = result { log.error(.setup, "Background service: \(summary)") }
            else { log.notice(.setup, "Background service: \(summary)") }
        }
        return result
    }

    private var currentAvailability: Availability {
        if let problem = installationProblem { return .unavailable(problem) }
        switch daemon.status {
        case .enabled:
            recordAcceptedHelperRegistration()
            return .readyToConnect
        case .requiresApproval:
            recordAcceptedHelperRegistration()
            return .approvalRequired
        // macOS can return notFound for a missing registration record even when
        // the signed helper and plist are present. Validate the bundle separately.
        case .notRegistered, .notFound:
            if let helperRegistrationError { return .unavailable(helperRegistrationError) }
            return .setupRequired
        @unknown default: return .unavailable("Caffeine couldn’t read the background service status.")
        }
    }

    private static func name(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "requires approval"
        case .notFound: "not found"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }

    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code) – \(error.localizedDescription)"
    }

    /// Registration alone is not readiness; the app must still authenticate and query the helper.
    func registerHelper() throws {
        if let problem = installationProblem {
            log.error(.setup, "Registration skipped: \(problem)")
            throw SetupError(problem)
        }
        log.notice(.setup, "Registering the background service (status \(Self.name(daemon.status)))")
        do { try daemon.register() }
        catch {
            // macOS reports a daemon awaiting administrator approval as an error,
            // although it has recorded the registration.
            switch daemon.status {
            case .enabled, .requiresApproval:
                log.notice(.setup, "macOS recorded the registration and reported \(Self.describe(error)); status \(Self.name(daemon.status))")
            default:
                log.error(.setup, "Registration failed: \(Self.describe(error)); status \(Self.name(daemon.status))")
                throw error
            }
        }
        log.notice(.setup, "Registration accepted; status \(Self.name(daemon.status))")
        recordAcceptedHelperRegistration()
    }

    private func recordAcceptedHelperRegistration() {
        defaults.set(true, forKey: helperEnrollmentKey)
        defaults.removeObject(forKey: replacementKey)
        helperRegistrationError = nil
    }

    /// The caller must freshly verify the old helper is idle before replacing it.
    /// Await the asynchronous unregister completion; the synchronous overload
    /// returns before the old process has exited and is unsafe for re-registration.
    func updateHelper() async throws {
        if let problem = installationProblem {
            log.error(.setup, "Service update skipped: \(problem)")
            throw SetupError(problem)
        }
        guard daemon.status == .enabled else {
            log.error(.setup, "Service update skipped: status is \(Self.name(daemon.status))")
            throw SetupError("The background service status changed. Check its setup before updating it.")
        }
        do {
            // Survives a relaunch: a registration this app removed is not a user's choice.
            defaults.set(true, forKey: replacementKey)
            log.notice(.setup, "Service update: removing the registration of the older service")
            do { try await daemon.unregister() }
            catch {
                defaults.removeObject(forKey: replacementKey)
                log.error(.setup, "Service update: removal failed: \(Self.describe(error))")
                throw error
            }
            log.notice(.setup, "Service update: the older registration is removed")
            try await registerReplacement()
        } catch {
            let message = "Caffeine couldn’t update its background service. \(error.localizedDescription)"
            helperRegistrationError = message
            throw SetupError(message)
        }
    }

    private func registerReplacement() async throws {
        var delays = Self.registrationRetryDelays[...]
        while true {
            do {
                // Recheck the signed installation after the asynchronous removal.
                return try registerHelper()
            } catch {
                guard installationProblem == nil, let delay = delays.popFirst() else { throw error }
                log.info(.setup, "Service update: registering again in \(delay.components.seconds) s")
                try await waitToRegisterAgain(delay)
            }
        }
    }

    func openSettings() {
        log.notice(.setup, "Opening System Settings, Login Items & Extensions")
        openLoginItems()
    }

    /// One automatic attempt per eligible process launch, independent of card lifetime.
    func prepareServices() {
        guard !prepared else { return }
        if let problem = installationProblem {
            log.error(.setup, "Setup is unavailable: \(problem)")
            return
        }
        prepared = true
        log.info(.setup, "At launch: \(registrationSummary); accepted before: service \(defaults.bool(forKey: helperEnrollmentKey) ? "yes" : "no")"
            + ", login \(defaults.bool(forKey: enrollmentKey) ? "yes" : "no")"
            + (defaults.bool(forKey: replacementKey) ? "; an interrupted service update is pending" : ""))
        enrollLoginIfEligible()
        switch daemon.status {
        case .enabled, .requiresApproval:
            recordAcceptedHelperRegistration()
        case .notFound:
            // macOS discards the record with a removed bundle. A missing record holds no
            // user choice, so an earlier receipt must not block a reinstalled app.
            attemptHelperRegistration()
        case .notRegistered:
            if !defaults.bool(forKey: helperEnrollmentKey) || defaults.bool(forKey: replacementKey) {
                attemptHelperRegistration()
            }
        @unknown default: break
        }
    }

    /// Explicit retry after a failed registration; refresh/wake never retries it.
    func retrySetup() {
        guard installationProblem == nil else { return }
        if helperRegistrationError != nil { attemptHelperRegistration() }
        if loginRegistrationFailed { registerLogin() }
    }

    private func attemptHelperRegistration() {
        do {
            switch daemon.status {
            case .notRegistered, .notFound: try registerHelper()
            default: helperRegistrationError = nil
            }
        } catch {
            helperRegistrationError = "Caffeine couldn’t register its background service. \(error.localizedDescription)"
        }
    }

    private func enrollLoginIfEligible() {
        switch loginItem.status {
        case .enabled, .requiresApproval:
            defaults.set(true, forKey: enrollmentKey)
        case .notRegistered, .notFound:
            if !defaults.bool(forKey: enrollmentKey) { registerLogin() }
        @unknown default: break
        }
        refreshLoginStatus()
    }

    private func registerLogin() {
        do {
            if loginItem.status == .notRegistered || loginItem.status == .notFound {
                log.notice(.setup, "Registering launch at login (status \(Self.name(loginItem.status)))")
                try loginItem.register()
            }
            defaults.set(true, forKey: enrollmentKey)
            loginRegistrationFailed = false
        } catch {
            loginRegistrationFailed = true
            log.error(.setup, "Launch at login could not be registered: \(Self.describe(error))")
        }
        refreshLoginStatus()
    }

    func refreshLoginStatus() {
        guard prepared else { return }
        let status = Self.name(loginItem.status)
        if status != loggedLoginStatus {
            loggedLoginStatus = status
            log.notice(.setup, "Launch at login: \(status)")
        }
        if loginRegistrationFailed && (loginItem.status == .notRegistered || loginItem.status == .notFound) {
            loginMessage = "Caffeine couldn’t enable launch at login. Try again."
            loginActionTitle = "Try Again"
            return
        }
        switch loginItem.status {
        case .enabled:
            defaults.set(true, forKey: enrollmentKey)
            loginRegistrationFailed = false
            loginMessage = defaults.bool(forKey: explanationKey) ? nil : "Caffeine will launch in the menu bar when you log in, with Keep awake off. Manage this in System Settings."
            loginActionTitle = loginMessage == nil ? nil : "Got It"
        case .requiresApproval:
            defaults.set(true, forKey: enrollmentKey)
            loginRegistrationFailed = false
            loginMessage = "Launch at login needs your approval in System Settings."
            loginActionTitle = "Open System Settings"
        case .notRegistered:
            loginMessage = "Launch at login is off. You can enable it in System Settings."
            loginActionTitle = "Open System Settings"
        case .notFound:
            loginMessage = "Launch at login hasn’t been set up."
            loginActionTitle = "Set Up Login…"
        @unknown default:
            loginMessage = "Caffeine couldn’t read its login status."
            loginActionTitle = "Open System Settings"
        }
    }

    func performLoginAction() {
        if loginActionTitle == "Got It" {
            defaults.set(true, forKey: explanationKey)
            refreshLoginStatus()
        } else if loginActionTitle == "Set Up Login…" || loginRegistrationFailed {
            guard installationProblem == nil else { return }
            registerLogin()
        } else { openSettings() }
    }

    private var installationProblem: String? {
        if let installationCheck { return installationCheck() }
        let expected = URL(fileURLWithPath: "/Applications/Caffeine.app", isDirectory: true)
        guard Bundle.main.bundleURL.resolvingSymlinksInPath() == expected else {
            return "Install the signed Caffeine app in Applications to enable its background service and launch at login."
        }
        guard Bundle.main.bundleIdentifier == CaffeineServiceIdentity.appIdentifier,
              hasExpectedSignature(at: Bundle.main.bundleURL, identifier: CaffeineServiceIdentity.appIdentifier) else {
            return "This build isn’t signed for Caffeine’s background service. Install a signed release to continue."
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/CaffeineHelper")
        if let problem = Self.bundledServiceProblem(at: Bundle.main.bundleURL) { return problem }
        guard hasExpectedSignature(at: helper, identifier: CaffeineServiceIdentity.helperIdentifier) else {
            return "Caffeine’s background service has an invalid signature. Reinstall the complete signed app."
        }
        return nil
    }

    static func bundledServiceProblem(at bundleURL: URL) -> String? {
        let helper = bundleURL.appendingPathComponent("Contents/MacOS/CaffeineHelper")
        let plist = bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(CaffeineServiceIdentity.daemonPlist)")
        guard FileManager.default.isExecutableFile(atPath: helper.path),
              let data = try? Data(contentsOf: plist),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let daemon = value as? [String: Any],
              daemon["Label"] as? String == CaffeineServiceIdentity.helperIdentifier,
              daemon["BundleProgram"] as? String == "Contents/MacOS/CaffeineHelper",
              let services = daemon["MachServices"] as? [String: Bool],
              services[CaffeineServiceIdentity.helperIdentifier] == true else {
            return "Caffeine’s background service is missing or damaged. Reinstall the complete signed app in Applications."
        }
        return nil
    }

    private func hasExpectedSignature(at url: URL, identifier: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(CaffeineServiceIdentity.signingRequirement(identifier: identifier) as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    private struct SetupError: Error, LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
