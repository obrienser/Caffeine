import DeveloperToolsSupport
import SwiftUI

/// The dark tile that heads the card and the setup screen, with the menu bar's artwork.
struct CoffeeTile: View {
    /// Only a verified active session shows the steaming cup.
    let isActive: Bool

    var body: some View {
        Image(isActive ? .coffee : .coffeeOff)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.19, green: 0.16, blue: 0.25), Color(red: 0.09, green: 0.08, blue: 0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
            }
            .accessibilityHidden(true)
    }
}
