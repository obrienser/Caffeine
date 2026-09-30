import Foundation
import IOKit.pwr_mgt
import IOKit.ps
import CaffeineHelperCore
import CaffeineLogging
import CaffeineServiceProtocol

protocol SleepAssertions: Sendable {
    func acquire() throws
    func release() throws
}

/// This actor is the sole writer of Caffeine's global sleep setting. Its async
/// mutex also prevents actor reentrancy from overlapping child processes.
public actor SystemSleepBackend: RuntimeSleepBackend {
    private let runner: any PMSetRunning
    private let journal: any RecoveryJournal
    private let assertions: any SleepAssertions
    private let bootIdentifier: @Sendable () -> String?
    private let log: EventLog
    private var activeClosedLidMode: Bool?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(log: EventLog = .disabled) {
        runner = SystemPMSetRunner()
        journal = FileRecoveryJournal()
        assertions = IOKitSleepAssertions()
        bootIdentifier = currentBootIdentifier
        self.log = log
    }

    init(runner: any PMSetRunning, journal: any RecoveryJournal,
         assertions: any SleepAssertions, bootIdentifier: @escaping @Sendable () -> String? = { UUID().uuidString },
         log: EventLog = .disabled) {
        self.runner = runner; self.journal = journal; self.assertions = assertions
        self.bootIdentifier = bootIdentifier
        self.log = log
    }

    public func recover() async throws {
        await enter(); defer { leave() }
        try await restore()
    }

    public func enable(closedLidMode: Bool = true) async throws {
        await enter(); defer { leave() }
        do {
            if activeClosedLidMode == closedLidMode { return }
            // Remove an owned override before ordinary mode, retaining the idle
            // assertions during a live transition. Failed restoration stays fatal.
            if try journal.load() != nil {
                try await restore(releaseAssertions: activeClosedLidMode == nil)
            }
            if !closedLidMode {
                try assertions.acquire()
                activeClosedLidMode = false
                log.info(.power, "Idle system and display assertions are held; the sleep setting is untouched")
                return
            }
            let before = try await readSetting()
            guard before != .enabled else {
                log.error(.power, "Sleep was already disabled outside Caffeine; nothing was changed")
                throw ServiceFailure(.externalOverride, "Sleep is already disabled by another setting. Caffeine has not changed it.")
            }
            guard let boot = bootIdentifier() else {
                throw ServiceFailure(.unavailable, "The current system boot could not be identified.")
            }
            var record = RecoveryRecord(operation: UUID(), boot: boot,
                                        baseline: before == .disabled ? .explicitZero : .defaultFalse, phase: .prepared)
            try journal.save(record)
            log.info(.recovery, "Recovery record saved before changing the sleep setting")
            try assertions.acquire()
            let result = try await run(.enable)
            guard result.succeeded, try await readSetting() == .enabled else {
                log.error(.power, "Disabling sleep could not be verified; the recovery record is kept")
                throw ServiceFailure(.cleanupRequired, "Keep awake could not be verified. The recovery record has been preserved.")
            }
            record.phase = .active
            try journal.save(record)
            activeClosedLidMode = true
        } catch {
            if !(error is ServiceFailure) { log.error(.power, "Activation stopped: \(error.localizedDescription)") }
            activeClosedLidMode = nil
            // HelperSessionAuthority must follow every failed activation with disable.
            // Release ordinary assertions even if disk or pmset cleanup is pending.
            try? assertions.release()
            if let failure = error as? ServiceFailure { throw failure }
            throw ServiceFailure(.cleanupRequired, "Keep awake could not start safely. The sleep recovery state needs attention.")
        }
    }

    public func disable() async throws {
        await enter(); defer { leave() }
        try await restore()
    }

    private func run(_ command: PMSetCommand) async throws -> PMSetResult {
        let result = try await runner.run(command)
        let outcome = "exit \(result.status)" + (result.timedOut ? ", timed out" : "") + (result.truncated ? ", output truncated" : "")
        log.log(result.succeeded ? .info : .error, .power, "pmset \(command.arguments.joined(separator: " ")): \(outcome)")
        return result
    }

    private func restore(releaseAssertions: Bool = true) async throws {
        activeClosedLidMode = nil
        do {
            guard var record = try journal.load() else {
                // No record means no owned global write, including an external 1.
                if releaseAssertions { try assertions.release() }
                return
            }
            log.info(.recovery, "Restoring the sleep setting from a recovery record in phase \(record.phase.rawValue)")
            record.phase = .releasing
            try journal.save(record)
            let value = try await readSetting()
            if value != .disabled {
                // A timeout never directly triggers the opposite write: the read
                // above first establishes an unambiguous persisted setting.
                let result = try await run(.disable)
                guard result.succeeded else {
                    throw ServiceFailure(.cleanupRequired, "Stopping Keep awake could not be verified. Recovery will be retried.")
                }
            }
            if releaseAssertions { try assertions.release() }
            // Clearing the global setting can sleep a closed-lid Mac immediately.
            // Until this explicit read-back completes, the journal stays on disk.
            guard try await readSetting() == .disabled else {
                throw ServiceFailure(.cleanupRequired, "The system has not confirmed that Caffeine's sleep override was removed.")
            }
            try journal.remove()
            log.info(.recovery, "The sleep setting is restored and read back; the recovery record is removed")
        } catch {
            log.error(.recovery, "Restoring the sleep setting failed; the recovery record is kept: \(error.localizedDescription)")
            try? assertions.release()
            throw ServiceFailure(.cleanupRequired, "Couldn’t stop Keep awake. The recovery record has been preserved for another attempt.")
        }
    }

    private func readSetting() async throws -> SleepDisabledValue {
        let result = try await run(.read)
        guard let value = PMSetParser.parse(result) else {
            log.error(.power, "The sleep setting could not be read reliably")
            throw ServiceFailure(.unavailable, "The system sleep setting could not be read reliably.")
        }
        log.info(.power, "SleepDisabled reads \(value == .enabled ? "1" : value == .disabled ? "0" : "absent (default 0)")")
        return value
    }

    private func enter() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }
    private func leave() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}

private final class IOKitSleepAssertions: SleepAssertions, @unchecked Sendable {
    // Access is serialized by SystemSleepBackend's async mutex.
    private var system: IOPMAssertionID = 0
    private var display: IOPMAssertionID = 0

    func acquire() throws {
        if system != 0 && display != 0 { return }
        try release()
        let name = "Caffeine Keep awake" as CFString
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                         IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &system) == kIOReturnSuccess else {
            throw ServiceFailure(.unavailable, "The system sleep assertion could not be created.")
        }
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                         IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &display) == kIOReturnSuccess else {
            try? release()
            throw ServiceFailure(.unavailable, "The display sleep assertion could not be created.")
        }
    }

    func release() throws {
        var failed = false
        if display != 0 {
            if IOPMAssertionRelease(display) == kIOReturnSuccess { display = 0 } else { failed = true }
        }
        if system != 0 {
            if IOPMAssertionRelease(system) == kIOReturnSuccess { system = 0 } else { failed = true }
        }
        if failed { throw ServiceFailure(.cleanupRequired, "A sleep assertion could not be released.") }
    }
}

public enum SystemPowerSource {
    /// AC remains eligible when the battery is full and no current is charging it.
    public static func current() -> ServicePowerSource {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? else { return .unknown }
        switch source {
        case kIOPMACPowerKey: return .external
        case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: return .battery
        default: return .unknown
        }
    }
}
