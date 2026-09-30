import DeveloperToolsSupport
import SwiftUI

/// The setup screen of the first launch, in the card's compact style. It names
/// the two things macOS lets the user allow and says in plain words what each is for.
struct SetupGuideView: View {
    let guide: any SetupGuidePresenting
    var close: () -> Void = {}
    /// A step was allowed, usually while System Settings was in front.
    var stepAllowed: () -> Void = {}

    @Environment(\.colorSchemeContrast) private var contrast

    private enum Step {
        case service, login

        var title: String { self == .service ? "Background service" : "Launch at login" }
        var icon: ImageResource { self == .service ? .eye : .power }
        /// One line each at the screen's width.
        var explanation: String {
            self == .service ? "Keeps your Mac awake, lid open or closed."
                             : "Starts when you log in, with Keep awake off."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 10)

            sectionDivider

            VStack(spacing: 0) {
                row(.service, guide.serviceStep)
                row(.login, guide.loginStep)
            }
            .padding(.vertical, 4)

            if guide.isPreview {
                Label("UI preview — nothing is registered", systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }

            sectionDivider
            footer.padding(.top, 4)
        }
        .padding(8)
        .frame(width: 300)
        .font(.system(size: 12))
        .controlSize(.small)
        .background(.regularMaterial)
        .background { closeShortcuts }
        .onChange(of: guide.stepsLeft) { old, new in
            if new < old { stepAllowed() }
        }
    }

    private var sectionDivider: some View {
        Divider().padding(.horizontal, 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            CoffeeTile(isActive: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Caffeine")
                    .font(.system(size: 14, weight: .semibold))
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var summary: String {
        if [guide.serviceStep, guide.loginStep].contains(where: { $0.state == .failed || $0.state == .attention }) {
            return "Setup needs your attention"
        }
        switch guide.stepsLeft {
        case 0: return "You’re all set"
        case 1: return "One step left"
        default: return "Two steps left"
        }
    }

    /// The step whose action leads on: the first one that is not allowed yet.
    private var next: Step? {
        if guide.serviceStep.state != .allowed, guide.serviceStep.actionTitle != nil { return .service }
        if guide.loginStep.state != .allowed, guide.loginStep.actionTitle != nil { return .login }
        return nil
    }

    private func row(_ kind: Step, _ step: SetupStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(kind.icon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    // The mark stands beside the name only, so that the text below has the full width.
                    HStack(spacing: 6) {
                        Text(kind.title)
                        Spacer(minLength: 6)
                        mark(step.state)
                    }
                    Text(kind.explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = step.note {
                        Text(note)
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
            // One element per step: its name and purpose, with the state as its value.
            .accessibilityElement(children: .combine)
            .accessibilityValue(status(kind, step.state))

            if let title = step.actionTitle {
                action(title, leads: next == kind) {
                    if kind == .service { guide.performServiceStep() } else { guide.performLoginStep() }
                }
                .padding(.leading, 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    @ViewBuilder
    private func action(_ title: String, leads: Bool, perform: @escaping () -> Void) -> some View {
        if leads {
            Button(title, action: perform)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else {
            Button(title, action: perform)
                .buttonStyle(.bordered)
        }
    }

    /// The state is shown by the symbol's shape as well as by its color.
    private func mark(_ state: SetupStep.State) -> some View {
        Group {
            switch state {
            case .allowed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .needsApproval, .off:
                Image(systemName: "circle")
                    .foregroundStyle(contrast == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            case .failed, .attention:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.system(size: 14))
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private func status(_ kind: Step, _ state: SetupStep.State) -> String {
        switch state {
        case .allowed: kind == .service ? "Allowed" : "On"
        case .needsApproval: "Approval required"
        case .off: kind == .service ? "Setup required" : "Off"
        case .failed: "Setup failed"
        case .attention: "Needs attention"
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(.coffeeOff)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Caffeine lives in the menu bar.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if guide.stepsLeft == 0 {
                Button("Done", action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Not Now", action: close)
                    .buttonStyle(.bordered)
            }
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 8)
    }

    /// The window has no close button of its own: Escape and Command-W close it.
    private var closeShortcuts: some View {
        Group {
            Button("Close", action: close).keyboardShortcut(.cancelAction)
            Button("Close", action: close).keyboardShortcut("w", modifiers: .command)
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

#Preview("Setup screen") {
    SetupGuideView(guide: SimulatedSetupGuide())
}
