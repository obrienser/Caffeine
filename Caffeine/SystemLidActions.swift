import CaffeineLogging
import CoreGraphics
import Darwin
import Foundation

struct LidActionError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct LidDisplay: Equatable {
    let id: CGDirectDisplayID
    let builtIn: Bool
    let asleep: Bool
}

@MainActor
protocol LidDisplayHardware: AnyObject {
    func onlineDisplays() throws -> [LidDisplay]
    func setEnabled(_ enabled: Bool, display: CGDirectDisplayID) throws
    func sleepSoleBuiltInDisplay() throws
}

/// Only the built-in display is ever disabled, and only until Caffeine restores it or exits.
@MainActor
final class SystemLidActions: LidActionPerforming {
    private let displays: any LidDisplayHardware
    private var disabledDisplay: CGDirectDisplayID?
    private var loginFramework: UnsafeMutableRawPointer?
    var needsDisplayRestoration: Bool { disabledDisplay != nil }

    init(displays: any LidDisplayHardware = NativeLidDisplayHardware()) { self.displays = displays }

    func turnOffBuiltInDisplay() throws {
        guard disabledDisplay == nil else { return }
        let online = try displays.onlineDisplays()
        // If macOS already removed/slept the built-in panel, there is nothing to own.
        guard let builtIn = online.first(where: { $0.builtIn }), !builtIn.asleep else { return }
        if online.contains(where: { !$0.builtIn }) {
            // Record before committing: a failed commit can have an ambiguous result.
            disabledDisplay = builtIn.id
            try displays.setEnabled(false, display: builtIn.id)
            guard !(try displays.onlineDisplays()).contains(where: { $0.id == builtIn.id && !$0.asleep }) else {
                throw LidActionError("macOS hasn’t confirmed that the built-in display turned off. External displays were not targeted.")
            }
        } else {
            // A display configuration cannot disconnect the last online display.
            // The native operation rechecks topology immediately before requesting display sleep.
            try displays.sleepSoleBuiltInDisplay()
        }
    }

    func restoreBuiltInDisplay() throws {
        guard let display = disabledDisplay else { return }
        // Re-enable only our panel; never restore the user's entire display layout.
        try displays.setEnabled(true, display: display)
        // An online but sleeping panel is restored too: never wake a locked screen
        // merely to prove illumination. If macOS still hides it (including while
        // physically closed), retain the target for retry after opening the lid.
        guard (try displays.onlineDisplays()).contains(where: { $0.id == display }) else {
            throw LidActionError("The built-in display has not reconnected. Open the lid and try restoring it again.")
        }
        disabledDisplay = nil
    }

    func builtInDisplayIsOff() -> Bool? {
        guard let online = try? displays.onlineDisplays() else { return nil }
        return !online.contains { $0.builtIn && !$0.asleep }
    }

    func lockScreen() throws {
        typealias Lock = @convention(c) () -> Void
        if loginFramework == nil {
            loginFramework = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY | RTLD_LOCAL)
        }
        guard let loginFramework, let symbol = dlsym(loginFramework, "SACLockScreenImmediate") else {
            throw LidActionError("Screen locking is unavailable on this version of macOS.")
        }
        // This private entry point does not expose a dependable success result.
        unsafeBitCast(symbol, to: Lock.self)()
    }

    func screenIsLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return session["CGSSessionScreenIsLocked"] as? Bool
    }
}

@MainActor
final class NativeLidDisplayHardware: LidDisplayHardware {
    /// Apple's own one-shot request. It changes no power, sleep or password setting.
    static let displaySleepCommand = (executable: "/usr/bin/pmset", arguments: ["displaysleepnow"])

    private let log: EventLog
    private var skyLight: UnsafeMutableRawPointer?
    private var displaySleepRequest: Process?

    init(log: EventLog = .disabled) { self.log = log }

    func onlineDisplays() throws -> [LidDisplay] {
        // Leave spare capacity for a monitor arriving between the count and list reads.
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { throw unavailable() }
        let capacity = max(count + 8, 16)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
        guard CGGetOnlineDisplayList(capacity, &ids, &count) == .success, count < capacity else { throw unavailable() }
        return ids.prefix(Int(count)).map {
            LidDisplay(id: $0, builtIn: CGDisplayIsBuiltin($0) != 0, asleep: CGDisplayIsAsleep($0) != 0)
        }
    }

    func setEnabled(_ enabled: Bool, display: CGDirectDisplayID) throws {
        typealias Configure = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> Int32
        let configure = unsafeBitCast(try symbol("SLSConfigureDisplayEnabled"), to: Configure.self)
        var config: CGDisplayConfigRef?
        let change = "\(enabled ? "connecting" : "disconnecting") built-in display \(display) for this app's lifetime"
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            log.error(.lid, "A display configuration could not be started for \(change)")
            throw unavailable()
        }
        let result = configure(config, display, enabled)
        guard result == CGError.success.rawValue else {
            CGCancelDisplayConfiguration(config)
            log.error(.lid, "macOS refused \(change) with error \(result)")
            throw unavailable()
        }
        // Never persist a disabled panel. CoreGraphics reverts app-only configurations
        // when this process exits, including a crash. Callers still confirm the change.
        let completed = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard completed == .success else {
            log.error(.lid, "The display configuration for \(change) failed with error \(completed.rawValue)")
            throw unavailable()
        }
        log.info(.lid, "Completed \(change)")
    }

    func sleepSoleBuiltInDisplay() throws {
        let online = try onlineDisplays()
        guard online.count == 1, online[0].builtIn else {
            throw LidActionError("The display connection changed. Caffeine skipped display sleep to preserve external screens.")
        }
        // SkyLight's display-idle call had no effect from this app, and pmset
        // carries Apple's private display-control entitlement. Ask through pmset.
        let request = Process()
        request.executableURL = URL(fileURLWithPath: Self.displaySleepCommand.executable)
        request.arguments = Self.displaySleepCommand.arguments
        request.standardInput = FileHandle.nullDevice
        request.standardOutput = FileHandle.nullDevice
        request.standardError = FileHandle.nullDevice
        let command = ([Self.displaySleepCommand.executable] + Self.displaySleepCommand.arguments).joined(separator: " ")
        do { try request.run() } catch {
            log.error(.lid, "\(command) could not be started: \(error.localizedDescription)")
            throw unavailable()
        }
        log.info(.lid, "Started \(command) as process \(request.processIdentifier)")
        displaySleepRequest = request
        Task { @MainActor [weak self, log] in
            try? await SuspendingClock().sleep(for: .seconds(5))
            guard let self, self.displaySleepRequest === request else { return }
            // The model reads the panel back; a stuck request must not linger.
            if request.isRunning {
                request.terminate()
                log.error(.lid, "\(command) did not finish within 5 s and was ended")
            } else {
                log.log(request.terminationStatus == 0 ? .info : .error, .lid, "\(command) exited with status \(request.terminationStatus)")
            }
            self.displaySleepRequest = nil
        }
    }

    private func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
        if skyLight == nil {
            skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        }
        guard let skyLight, let symbol = dlsym(skyLight, name) else { throw unavailable() }
        return symbol
    }

    private func unavailable() -> LidActionError {
        LidActionError("Caffeine couldn’t control the built-in display on this Mac. External displays were not targeted.")
    }
}
