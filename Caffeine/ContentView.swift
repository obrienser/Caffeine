import AppKit
import CaffeineCore
import DeveloperToolsSupport
import SwiftUI

struct ContentView: View {
    let session: any CaffeineSessionPresenting
    let lidActions: LidActionsModel
    /// The card shows the hint of a shortcut that the runtime has registered.
    var shortcut: KeepAwakeShortcut?
    var exportLog: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 10)

            sectionDivider

            VStack(spacing: 0) {
                toggleRow("Keep Awake", icon: .eye,
                          selection: Binding(get: { session.requested }, set: session.setKeepAwake),
                          enabled: session.canToggleKeepAwake,
                          hint: session.isPending ? session.statusTitle : keepAwakeHint,
                          shortcut: shortcut?.registered?.title)

                Group {
                    toggleRow("Closed Lid Mode", icon: .laptop,
                              selection: Binding(get: { session.closedLidMode }, set: session.setClosedLidMode),
                              hint: "Keeps your Mac awake with the lid closed while Keep awake is on.")

                    toggleRow("Turn Off Screen on Close", icon: .sun,
                              selection: Binding(get: { lidActions.turnOffDisplayOnLidClose }, set: lidActions.setTurnOffDisplayOnLidClose),
                              hint: "Turns off only the built-in display when the lid closes while Keep awake is active. External displays stay on.")

                    toggleRow("Lock Screen on Close", icon: .lock,
                              selection: Binding(get: { lidActions.lockScreenOnLidClose }, set: lidActions.setLockScreenOnLidClose),
                              hint: "Locks your Mac when the lid closes while Keep awake is active.")

                    toggleRow("Only When Charging", icon: .bolt,
                              selection: Binding(get: { session.onlyWhenCharging }, set: session.setOnlyWhenCharging),
                              hint: "Only keeps your Mac awake while connected to external power.")

                    timerRow
                }
                // While Keep awake waits for power, Only When Charging must stay changeable.
                .disabled(!session.requested)
            }
            .controlSize(.small)
            .padding(.vertical, 4)

            if let message = session.statusMessage {
                messageView(message)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
            }
            if let message = lidActions.message {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if lidActions.restorationRequired || lidActions.monitoringMessage != nil {
                        Button(lidActions.restorationRequired ? "Restore Built-in Display" : "Try Again") { lidActions.retry() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .padding(.bottom, 4)
            }
            if session.isPreview {
                Label("UI preview — sleep settings are unchanged", systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }

            sectionDivider
            quitButton.padding(.top, 4)
            exportLogButton
        }
        .padding(8)
        .frame(width: 300)
        .font(.system(size: 12))
        .background(.regularMaterial)
    }

    private var sectionDivider: some View {
        Divider().padding(.horizontal, 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            CoffeeTile(isActive: session.isActive)
            VStack(alignment: .leading, spacing: 2) {
                Text("Caffeine")
                    .font(.system(size: 14, weight: .semibold))
                Text(session.statusTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if session.isPending {
                ProgressView().controlSize(.small).accessibilityLabel(session.statusTitle)
            } else if session.isCleanupUncertain {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Sleep restoration is unconfirmed")
            }
        }
    }

    private var timerRow: some View {
        Menu {
            ForEach(TimerPreset.allCases) { preset in
                Button {
                    session.selectTimer(preset)
                } label: {
                    if session.timerPreset == preset {
                        Label(preset.title, systemImage: "checkmark")
                    } else {
                        Text(preset.title)
                    }
                }
                .accessibilityAddTraits(session.timerPreset == preset ? .isSelected : [])
                if preset == .noLimit { Divider() }
            }
            if session.requested {
                Divider()
                Text("Changes restart the timer")
            }
        } label: {
            HStack(spacing: 6) {
                rowLabel("Timer", icon: .hourglass)
                Spacer(minLength: 6)
                Text(session.timerDisplayValue)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            }
            .foregroundStyle(.primary)
            .modifier(CardRowStyle())
            .accessibilityElement(children: .combine)
        }
        .menuStyle(.button)
        .buttonStyle(MenuRowButtonStyle())
        .menuIndicator(.hidden)
        .accessibilityLabel("Timer")
        .accessibilityValue(session.timerDisplayValue)
        .accessibilityHint("Selected duration: \(session.timerPreset.title)")
    }

    private func toggleRow(_ title: String, icon: ImageResource, selection: Binding<Bool>,
                           enabled: Bool = true, hint: String, shortcut: String? = nil) -> some View {
        // The style lays out the row, so that all of it is the switch.
        Toggle(isOn: selection) { rowLabel(title, icon: icon) }
            .toggleStyle(MiniSwitchStyle(shortcut: shortcut))
            .accessibilityHint(hint)
            .disabled(!enabled)
    }

    /// The keys are part of what VoiceOver reads, in words; the glyphs in the row are not read.
    private var keepAwakeHint: String {
        let purpose = "Prevents idle system and display sleep. Closed Lid Mode also keeps your Mac awake with the lid closed."
        guard let keys = shortcut?.registered?.spokenTitle else { return purpose }
        return "\(purpose) \(keys) switches it from any app."
    }

    private func rowLabel(_ title: String, icon: ImageResource) -> some View {
        HStack(spacing: 8) {
            Image(icon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            HStack {
                rowLabel("Quit Caffeine", icon: .power)
                Spacer()
                Text("⌘Q")
                    .font(.system(size: 11))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .modifier(CardRowStyle(height: 32))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q", modifiers: .command)
    }

    /// Deliberately the quietest element of the card: support, not a feature.
    private var exportLogButton: some View {
        Button("Export Log…", action: exportLog)
            .buttonStyle(.plain)
            .font(.system(size: 9))
            .modifier(FooterLinkStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .accessibilityHint("Saves Caffeine’s activity and error log as a text file.")
    }

    private func messageView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: session.isCleanupUncertain ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(session.isCleanupUncertain ? Color.orange : Color.secondary)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = session.actionTitle {
                    Button(action) { session.retry() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Draws the Timer row's label unchanged, so that `CardRowStyle` alone dims the disabled row,
/// as it does the switch rows. The plain button style would dim it a second time.
private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct FooterLinkStyle: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isHovered || contrast == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

#Preview("Classic") {
    CardPreviewHost()
}

private struct CardPreviewHost: View {
    @State private var runtime = AppRuntime(preview: true, shortcuts: InertGlobalShortcut())

    var body: some View {
        ContentView(session: runtime.session, lidActions: runtime.lidActions, shortcut: runtime.shortcut)
            .onAppear { runtime.start() }
            .onDisappear { runtime.stop() }
    }
}
