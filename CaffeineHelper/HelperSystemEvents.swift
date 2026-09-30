import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import CaffeineHelperCore
import CaffeineSystemPower

final class HelperSystemEvents: @unchecked Sendable {
    let authority: HelperSessionAuthority
    private var powerSource: CFRunLoopSource?
    private var notificationPort: IONotificationPortRef?
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var clockTask: Task<Void, Never>?

    init(authority: HelperSessionAuthority) {
        self.authority = authority
    }

    /// Without sleep/wake notifications the authority cannot safely resume a waiting session.
    func start() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let events = Unmanaged<HelperSystemEvents>.fromOpaque(context).takeUnretainedValue()
            Task { await events.authority.powerSourceChanged(SystemPowerSource.current()) }
        }, context)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }

        rootPort = IORegisterForSystemPower(context, &notificationPort, { context, _, type, argument in
            guard let context else { return }
            let events = Unmanaged<HelperSystemEvents>.fromOpaque(context).takeUnretainedValue()
            switch type {
            case CaffeineCanSystemSleep:
                IOAllowPowerChange(events.rootPort, Int(bitPattern: argument))
            case CaffeineSystemWillSleep:
                // Before acknowledging sleep, release the hold and require a fresh owner after wake. Do not perform blocking I/O here.
                let token = Int(bitPattern: argument)
                Task {
                    await events.authority.systemWillSleep()
                    IOAllowPowerChange(events.rootPort, token)
                }
            case CaffeineSystemHasPoweredOn:
                Task {
                    await events.authority.systemDidWake()
                    await events.authority.powerSourceChanged(SystemPowerSource.current())
                }
            default: break
            }
        }, &notifier)
        guard rootPort != 0, let notificationPort,
              let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() else {
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        // This tick never prevents idle sleep. The authority separates awake lease time from session time.
        clockTask = Task { [authority] in
            while !Task.isCancelled {
                do { try await SuspendingClock().sleep(for: .seconds(1)) }
                catch { return }
                await authority.powerSourceChanged(SystemPowerSource.current())
                await authority.tick()
            }
        }
        return true
    }
}
