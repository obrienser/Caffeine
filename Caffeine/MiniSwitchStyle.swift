import SwiftUI

/// A card row that is one switch. The label leads, a mini switch a little
/// larger than the text trails, and a click anywhere in the row changes the value.
/// It stays a `Toggle`, so the binding, the disabled state and what VoiceOver reads
/// are those of the native switch. A disabled row dims the switch with its label.
struct MiniSwitchStyle: ToggleStyle {
    /// As tall as the row's icon, one point more than the line of its 12 pt label.
    static let track = CGSize(width: 28, height: 16)

    /// The keys that change this switch, shown before it like `⌘Q` in the Quit row.
    var shortcut: String?

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(MiniSwitchRowStyle(isOn: configuration.isOn, shortcut: shortcut))
    }
}

/// A button supplies the press, keyboard focus and Space for the whole row.
private struct MiniSwitchRowStyle: ButtonStyle {
    let isOn: Bool
    let shortcut: String?

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.label
            Spacer(minLength: 6)
            if let shortcut {
                // The row's hint names the keys for VoiceOver; the glyphs are not read.
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            MiniSwitch(isOn: isOn, isPressed: configuration.isPressed)
        }
        .modifier(CardRowStyle(isPressed: configuration.isPressed))
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 8))
    }
}

private struct MiniSwitch: View {
    let isOn: Bool
    let isPressed: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let track = MiniSwitchStyle.track
    private let inset: CGFloat = 2

    var body: some View {
        // The thumb widens towards the other side while the pointer holds the row.
        let thumb = CGSize(width: track.height - 2 * inset + (isPressed ? 3 : 0), height: track.height - 2 * inset)
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.3 : 0.17))
            Capsule().fill(Color.accentColor).opacity(isOn ? 1 : 0)
            Capsule().strokeBorder(Color.primary.opacity(contrast == .increased ? 0.6 : 0.08),
                                   lineWidth: contrast == .increased ? 1 : 0.5)
            Capsule()
                .fill(.white.shadow(.drop(color: .black.opacity(0.3), radius: 1, y: 0.5)))
                .frame(width: thumb.width, height: thumb.height)
                .offset(x: isOn ? track.width - inset - thumb.width : inset)
        }
        .frame(width: track.width, height: track.height)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isOn)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isPressed)
    }
}
