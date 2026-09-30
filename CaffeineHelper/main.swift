import Foundation
import Darwin
import CaffeineHelperCore
import CaffeineLogging
import CaffeineServiceProtocol
import CaffeineSystemPower

let systemLog = UnifiedLogSink(subsystem: CaffeineServiceIdentity.helperIdentifier)
guard geteuid() == 0 else {
    EventLog(sinks: [systemLog]).fault(.helper, "CaffeineHelper must be launched by its approved system service; exiting")
    exit(EXIT_FAILURE)
}

// Record the launch file before recovery, while it is still the running code.
let replacement = HelperExecutableFile.currentProcess().map { HelperReplacementMonitor(executable: $0) }
let log = EventLog(sinks: [systemLog, RotatingFileSink(location: .helper, subsystem: CaffeineServiceIdentity.helperIdentifier)])
log.notice(.helper, "CaffeineHelper build \(CaffeineServiceIdentity.helperBuild), protocol \(CaffeineServiceIdentity.protocolVersion), "
    + "started as process \(getpid()) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
let authority = HelperSessionAuthority(backend: SystemSleepBackend(log: log), log: log)
let server = HelperServer(authority: authority, log: log)
let events = HelperSystemEvents(authority: authority)
let shutdown = HelperShutdown(server: server, authority: authority, log: log)
shutdown.start()
let eventsReady = events.start()

// Recovery is completed before accepting a client. No session survives a helper restart.
Task {
    await authority.prepare()
    guard eventsReady else {
        await authority.shutdown()
        log.fault(.helper, "System sleep and wake cannot be observed; exiting without accepting clients")
        log.flush()
        exit(EXIT_FAILURE)
    }
    await authority.powerSourceChanged(SystemPowerSource.current())
    server.activate()
    log.notice(.connection, "Accepting connections from the signed Caffeine app")
    if let replacement {
        HelperRetirement.watch(replacement, authority: authority, shutdown: shutdown, log: log)
    } else {
        log.error(.helper, "The executable could not be identified; replacement monitoring is off")
    }
}
withExtendedLifetime((server, events, shutdown)) { RunLoop.main.run() }

final class HelperShutdown: @unchecked Sendable {
    private let server: HelperServer
    private let authority: HelperSessionAuthority
    private let log: EventLog
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    private var terminating = false

    init(server: HelperServer, authority: HelperSessionAuthority, log: EventLog) {
        self.server = server; self.authority = authority; self.log = log
    }

    func start() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            source.setEventHandler { [self] in
                log.notice(.helper, "Received signal \(number)")
                terminate()
            }
            source.resume()
            sources.append(source)
        }
    }

    /// Orderly exit for a signal or an accepted retirement. launchd restarts the service.
    func terminate() {
        let first = lock.withLock {
            guard !terminating else { return false }
            terminating = true
            return true
        }
        guard first else { return }
        server.invalidate()
        Task {
            await authority.shutdown()
            log.notice(.helper, "CaffeineHelper process \(getpid()) exits")
            log.flush()
            exit(EXIT_SUCCESS)
        }
    }
}

/// After the app bundle is replaced, clients can no longer authenticate this
/// process. Exit only when settled, so launchd starts the installed helper.
enum HelperRetirement {
    static let checkInterval: Duration = .seconds(5)

    static func watch(_ replacement: HelperReplacementMonitor, authority: HelperSessionAuthority,
                      shutdown: HelperShutdown, log: EventLog) {
        Task {
            var monitor = replacement
            var announced = false
            while !Task.isCancelled {
                // Awake time only: never a reason to wake or keep the Mac awake.
                do { try await SuspendingClock().sleep(for: checkInterval) }
                catch { return }
                guard monitor.replacementIsReady() else { announced = false; continue }
                if !announced {
                    announced = true
                    log.notice(.helper, "A correctly signed replacement of this executable is installed")
                }
                guard await authority.retireIfSettled() else { continue }
                log.notice(.helper, "Restarting as the installed helper")
                shutdown.terminate()
                return
            }
        }
    }
}
