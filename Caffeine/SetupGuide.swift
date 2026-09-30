import Foundation
import Observation

/// One of the two things macOS lets the user allow, as the setup screen shows it.
struct SetupStep: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// macOS runs it. Nothing is left to do.
        case allowed
        /// Registered; the user's approval in System Settings is missing.
        case needsApproval
        /// Not registered, or switched off in System Settings.
        case off
        /// Caffeine's own attempt was refused.
        case failed
        /// Allowed, but the service does not answer as it should. The card explains and recovers.
        case attention
    }

    var state: State
    /// What the user can do about it on the screen. Nil when the screen offers no action.
    var actionTitle: String?
    /// One sentence for a step that is not allowed: what to do, or what went wrong.
    var note: String?

    static let allowed = SetupStep(state: .allowed)
    static let approvalNote = "Turn on Caffeine in Login Items & Extensions."
    /// The screen sets up; recovery stays in one place, the card.
    static let attention = SetupStep(state: .attention,
                                     note: "Caffeine can’t use its background service yet. Open Caffeine in the menu bar.")
}

/// What the setup screen shows and can ask for. It reads status and completes
/// registration; nothing here starts Keep awake.
@MainActor
protocol SetupGuidePresenting: AnyObject {
    var serviceStep: SetupStep { get }
    var loginStep: SetupStep { get }
    /// False where nothing can be set up, as outside Applications.
    var canSetUp: Bool { get }
    var isPreview: Bool { get }
    func performServiceStep()
    func performLoginStep()
    /// The screen explains launch at login, so the card does not repeat it.
    func setupGuideDidOpen()
}

extension SetupGuidePresenting {
    /// How many of the two are not allowed yet.
    var stepsLeft: Int { [serviceStep, loginStep].filter { $0.state != .allowed }.count }
}

/// The window belongs to the app's views. The runtime decides when it opens.
@MainActor
protocol SetupGuideWindowing: AnyObject {
    var isOpen: Bool { get }
    /// Whether a window that became key is the setup screen.
    func owns(_ window: ObjectIdentifier) -> Bool
    func open(_ guide: any SetupGuidePresenting, onClose: @escaping () -> Void)
    func close()
}

/// For the UI preview: the steps change on the screen and nowhere else.
@Observable @MainActor
final class SimulatedSetupGuide: SetupGuidePresenting {
    private(set) var serviceStep = SetupStep(state: .needsApproval, actionTitle: "Open System Settings",
                                             note: SetupStep.approvalNote)
    private(set) var loginStep = SetupStep.allowed
    let canSetUp = true
    let isPreview = true

    @ObservationIgnored private let approvalDelay: Duration
    @ObservationIgnored private var approval: Task<Void, Never>?

    init(approvalDelay: Duration = .milliseconds(1_500)) { self.approvalDelay = approvalDelay }

    func performServiceStep() {
        guard serviceStep.state != .allowed, approval == nil else { return }
        approval = Task { @MainActor [weak self, approvalDelay] in
            try? await Task.sleep(for: approvalDelay)
            guard let self, !Task.isCancelled else { return }
            self.serviceStep = .allowed
            self.approval = nil
        }
    }

    func performLoginStep() {}
    func setupGuideDidOpen() {}
}
