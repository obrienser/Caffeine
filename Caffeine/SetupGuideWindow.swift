import AppKit
import SwiftUI

/// The window of the setup screen. The runtime decides when it opens; the
/// window owns no registration, session or timer.
@MainActor
final class SetupGuideWindow: NSObject, SetupGuideWindowing, NSWindowDelegate {
    /// Hidden on the screen; read by VoiceOver and listed by Mission Control.
    static let title = "Caffeine Setup"

    private let makeWindow: (NSViewController) -> NSWindow
    private let place: (NSWindow) -> Void
    private let activate: () -> Void
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    /// Injectable, so that the window can stay off every display without activating the app.
    init(makeWindow: @escaping (NSViewController) -> NSWindow = { NSWindow(contentViewController: $0) },
         place: @escaping (NSWindow) -> Void = { $0.center() },
         activate: @escaping () -> Void = { NSApp.activate() }) {
        self.makeWindow = makeWindow
        self.place = place
        self.activate = activate
    }

    var isOpen: Bool { window != nil }

    func owns(_ window: ObjectIdentifier) -> Bool {
        self.window.map { ObjectIdentifier($0) == window } ?? false
    }

    func open(_ guide: any SetupGuidePresenting, onClose: @escaping () -> Void) {
        if let window {
            show(window)
            return
        }
        let screen = SetupGuideView(guide: guide,
                                    close: { [weak self] in self?.close() },
                                    stepAllowed: { [weak self] in self?.window?.orderFrontRegardless() })
            .background(WindowMaterial())
        let host = NSHostingController(rootView: screen)
        // The window follows the screen's height when a step's action comes or goes.
        host.sizingOptions = [.preferredContentSize]
        // The card has no title bar; the screen starts at the window's upper edge.
        host.safeAreaRegions = []
        let window = makeWindow(host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = Self.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.delegate = self
        self.window = window
        self.onClose = onClose
        // The hosting controller sizes its window only later; set the final size before placing it.
        window.setContentSize(host.view.fittingSize)
        place(window)
        show(window)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        window = nil
        closed.delegate = nil
        let onClose = self.onClose
        self.onClose = nil
        onClose?()
    }

    private func show(_ window: NSWindow) {
        // A menu bar app is not active, so its window would open behind the others.
        activate()
        window.makeKeyAndOrderFront(nil)
        // macOS can decline the activation. The screen must be seen all the same.
        window.orderFrontRegardless()
    }
}

/// The material of a menu bar card, under the screen's own as in the card.
private struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        // The screen often waits behind System Settings and keeps its look there.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
