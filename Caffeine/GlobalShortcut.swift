import Foundation

/// A key combination that macOS delivers to Caffeine from every app.
struct GlobalShortcut: Equatable, Sendable {
    /// The values with which macOS registers a hot key.
    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: UInt32
        static let command = Modifiers(rawValue: 0x0100)
        static let shift = Modifiers(rawValue: 0x0200)
        static let option = Modifiers(rawValue: 0x0800)
        static let control = Modifiers(rawValue: 0x1000)
    }

    /// The key's place on the keyboard, the same in every keyboard layout.
    let keyCode: UInt32
    let modifiers: Modifiers
    /// As the card shows it, in the order of macOS menus.
    let title: String
    /// As VoiceOver reads it.
    let spokenTitle: String

    /// Turns Keep awake on and off. Three modifiers keep it clear of other apps'
    /// shortcuts, and no keyboard layout types a character with it.
    static let keepAwake = GlobalShortcut(keyCode: 0, modifiers: [.control, .option, .command],
                                          title: "⌃⌥⌘A", spokenTitle: "Control-Option-Command-A")
}

/// The registration with macOS belongs to the app's AppKit side, as the setup
/// window does. The Xcode canvas registers nothing.
@MainActor
protocol GlobalShortcutRegistering: AnyObject {
    /// Replaces an earlier registration. Throws when macOS refuses the key combination.
    func register(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) throws
    func unregister()
}

/// For the Xcode canvas: the card shows its hint and no key is registered.
@MainActor
final class InertGlobalShortcut: GlobalShortcutRegistering {
    func register(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) throws {}
    func unregister() {}
}
