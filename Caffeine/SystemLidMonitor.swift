import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

/// IOKit callbacks are delivered on the main run loop; teardown uses that same actor.
@MainActor
final class SystemLidMonitor: LidMonitoring {
    private var service: io_service_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?
    private var source: CFRunLoopSource?
    private var observations: [NSObjectProtocol] = []
    private var handler: (@MainActor (LidEvent) -> Void)?

    var currentState: Bool? {
        guard service != 0,
              let value = IORegistryEntryCreateCFProperty(service, kAppleClamshellStateKey as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue(),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return (value as? Bool)
    }

    func start(_ handler: @escaping @MainActor (LidEvent) -> Void) throws {
        stop()
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { throw LidActionError("The system lid service is unavailable.") }
        // Desktops have no clamshell property; leave the preferences available but idle.
        guard currentState != nil else { return }
        self.handler = handler
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            stop(); throw LidActionError("The lid notification port is unavailable.")
        }
        self.port = port
        let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { context, _, _, _ in
            guard let context else { return }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<SystemLidMonitor>.fromOpaque(context).takeUnretainedValue()
                // General-interest also reports policy changes; the model deduplicates state.
                monitor.handler?(.changed(monitor.currentState))
            }
        }, Unmanaged.passUnretained(self).toOpaque(), &notifier)
        guard result == kIOReturnSuccess,
              let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            stop(); throw LidActionError("Lid notifications could not be registered.")
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session[kCGSessionOnConsoleKey as String] as? Bool == false {
            handler(.suspend(.inactiveUser))
        }
        let center = NSWorkspace.shared.notificationCenter
        for (name, reason) in [(NSWorkspace.willSleepNotification, LidSuspensionReason.systemSleep),
                               (NSWorkspace.sessionDidResignActiveNotification, .inactiveUser)] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handler?(.suspend(reason)) }
            })
        }
        for (name, reason) in [(NSWorkspace.didWakeNotification, LidSuspensionReason.systemSleep),
                               (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveUser)] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handler?(.resume(reason)) }
            })
        }
    }

    func stop() {
        handler = nil
        for token in observations { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observations.removeAll()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        if notifier != 0 { IOObjectRelease(notifier); notifier = 0 }
        if let port { IONotificationPortDestroy(port) }
        port = nil
        if service != 0 { IOObjectRelease(service); service = 0 }
    }
}
