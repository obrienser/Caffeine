import SwiftUI

/// Only presentation state belongs to a row; session work stays in the runtime.
struct CardRowStyle: ViewModifier {
    var height: CGFloat = 36
    /// A row that is one control marks the press under the pointer.
    var isPressed = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.horizontal, 8)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background {
                RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(isEnabled ? highlight : 0))
            }
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovered = $0 }
    }

    private var highlight: Double {
        if isPressed { return contrast == .increased ? 0.18 : 0.09 }
        return isHovered ? (contrast == .increased ? 0.12 : 0.055) : 0
    }
}
