import AppKit
import SwiftUI
import CaffeineCore

@MainActor
final class CaffeineAppDelegate: NSObject, NSApplicationDelegate {
    // The Xcode canvas builds the app's views; it must not open a window of its own
    // or register a key combination.
    let runtime = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        ? AppRuntime() : AppRuntime(setupWindow: SetupGuideWindow(), shortcuts: SystemGlobalShortcut())
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            let canQuit = await runtime.stopForQuit()
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stop()
    }
}

@main
struct CaffeineApp: App {
    @NSApplicationDelegateAdaptor(CaffeineAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView(session: appDelegate.runtime.session, lidActions: appDelegate.runtime.lidActions,
                        shortcut: appDelegate.runtime.shortcut, exportLog: appDelegate.runtime.exportLog)
                .onAppear { appDelegate.runtime.cardDidOpen() }
        } label: {
            menuBarImage
                .accessibilityLabel("Caffeine, \(appDelegate.runtime.session.statusTitle)\(appDelegate.runtime.lidActions.message.map { ", " + $0 } ?? "")")
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarImage: Image {
        let session = appDelegate.runtime.session
        if session.isCleanupUncertain || appDelegate.runtime.lidActions.message != nil {
            return Image(systemName: "exclamationmark.triangle")
        }

        let image = NSImage(resource: session.isActive ? .coffee : .coffeeOff)
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return Image(nsImage: image)
    }
}
