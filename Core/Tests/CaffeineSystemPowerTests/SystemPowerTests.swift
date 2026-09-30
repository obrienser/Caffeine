import Foundation
import Testing
import Darwin
import CaffeineServiceProtocol
import CaffeineHelperCore
@testable import CaffeineSystemPower

private func fixture(_ value: String?) -> PMSetResult {
    PMSetResult(output: "System-wide power settings:\n \(value.map { "SleepDisabled \($0)" } ?? "DestroyFVKeyOnStandby 0")\nCurrently in use:\n standby 1\n")
}

@Suite struct PMSetParsingTests {
    @Test func parsesExplicitAndDefaultValues() {
        #expect(PMSetParser.parse(fixture("0")) == .disabled)
        #expect(PMSetParser.parse(fixture("1")) == .enabled)
        #expect(PMSetParser.parse(fixture(nil)) == .defaultDisabled)
    }

    @Test func refusesAmbiguousAndIncompleteOutput() {
        for text in ["Currently in use:\n sleep 0\n", "System-wide power settings:\n SleepDisabled 0\n",
                     "System-wide power settings:\n SleepDisabled 0\n SleepDisabled 1\nCurrently in use:\n",
                     "System-wide power settings:\n SleepDisabled true\nCurrently in use:\n",
                     "System-wide power settings:\n SleepDisabled 0 extra\nCurrently in use:\n",
                     "System-wide power settings:\n unknown-format\nCurrently in use:\n",
                     "System-wide power settings:\n SleepDisabled 0\nCurrently in use:",
                     "System-wide power settings:\nCurrently in use:\n SleepDisabled 1\n"] {
            #expect(PMSetParser.parse(PMSetResult(output: text)) == nil)
        }
        var failed = fixture("0"); failed.status = 1
        #expect(PMSetParser.parse(failed) == nil)
        failed = fixture("0"); failed.truncated = true
        #expect(PMSetParser.parse(failed) == nil)
        failed = fixture("0"); failed.timedOut = true
        #expect(PMSetParser.parse(failed) == nil)
    }

    @Test func onlyFixedArgumentsAreAvailable() {
        #expect(PMSetCommand.read.arguments == ["-g"])
        #expect(PMSetCommand.enable.arguments == ["-a", "disablesleep", "1"])
        #expect(PMSetCommand.disable.arguments == ["-a", "disablesleep", "0"])
    }
}

private final class MemoryJournal: RecoveryJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RecoveryRecord?
    private var failure = false
    var failWrites: Bool {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    func load() throws -> RecoveryRecord? { lock.withLock { stored } }
    func save(_ record: RecoveryRecord) throws {
        try lock.withLock {
            if failure { throw POSIXError(.ENOSPC) }
            stored = record
        }
    }
    func remove() throws { lock.withLock { stored = nil } }
}

private final class FakeAssertions: SleepAssertions, @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var releases = 0
    var enabled: Bool { lock.withLock { value } }
    var releaseCount: Int { lock.withLock { releases } }
    func acquire() throws { lock.withLock { value = true } }
    func release() throws { lock.withLock { value = false; releases += 1 } }
}

private actor FakeRunner: PMSetRunning {
    var commands: [PMSetCommand] = []
    var value: String?
    var failedEnable = false
    var failedDisable = false
    var invalidRead = false
    let journal: any RecoveryJournal

    init(value: String? = "0", journal: any RecoveryJournal) { self.value = value; self.journal = journal }
    func configure(failedEnable: Bool = false, failedDisable: Bool = false, invalidRead: Bool = false) {
        self.failedEnable = failedEnable; self.failedDisable = failedDisable; self.invalidRead = invalidRead
    }
    func run(_ command: PMSetCommand) async throws -> PMSetResult {
        commands.append(command)
        if command == .read { return invalidRead ? PMSetResult(output: "unexpected\n") : fixture(value) }
        #expect(try journal.load() != nil, "Recovery intent must exist before any global write")
        value = command == .enable ? "1" : "0"
        if command == .enable && failedEnable || command == .disable && failedDisable {
            return PMSetResult(output: "", status: 9, timedOut: true)
        }
        return PMSetResult(output: "")
    }
}

@Suite struct SleepTransactionTests {
    @Test func ordinaryHoldNeverReadsOrChangesExternalGlobalOverride() async throws {
        let journal = MemoryJournal(), assertions = FakeAssertions()
        let runner = FakeRunner(value: "1", journal: journal)
        let backend = SystemSleepBackend(runner: runner, journal: journal, assertions: assertions)
        try await backend.enable(closedLidMode: false)
        #expect(assertions.enabled)
        #expect(try journal.load() == nil)
        try await backend.disable()
        #expect(!assertions.enabled)
        #expect(await runner.commands.isEmpty)
        #expect(await runner.value == "1")
    }

    @Test func liveModeChangesKeepIdleAssertionsAndRestoreOwnedOverride() async throws {
        let journal = MemoryJournal(), assertions = FakeAssertions()
        let runner = FakeRunner(journal: journal)
        let backend = SystemSleepBackend(runner: runner, journal: journal, assertions: assertions)
        try await backend.enable(closedLidMode: false)
        try await backend.enable(closedLidMode: true)
        #expect(try journal.load()?.phase == .active)
        try await backend.enable(closedLidMode: false)
        #expect(assertions.enabled)
        #expect(assertions.releaseCount == 0)
        #expect(try journal.load() == nil)
        #expect(await runner.commands == [.read, .enable, .read, .read, .disable, .read])
        try await backend.enable(closedLidMode: false)
        try await backend.disable()
        #expect(!assertions.enabled)
        #expect(await runner.commands.count == 6)
    }

    @Test func failedModeDowngradeRetainsRecoveryInsteadOfReportingOrdinaryMode() async throws {
        let journal = MemoryJournal(), assertions = FakeAssertions()
        let runner = FakeRunner(journal: journal)
        let backend = SystemSleepBackend(runner: runner, journal: journal, assertions: assertions)
        try await backend.enable(closedLidMode: true)
        await runner.configure(invalidRead: true)
        await #expect(throws: ServiceFailure.self) { try await backend.enable(closedLidMode: false) }
        #expect(!assertions.enabled)
        #expect(try journal.load()?.phase == .releasing)
        await runner.configure()
        try await backend.disable()
        #expect(try journal.load() == nil)
    }

    @Test func ordinaryStartFirstRecoversOldClosedLidTransaction() async throws {
        let journal = MemoryJournal(), assertions = FakeAssertions()
        try journal.save(RecoveryRecord(operation: UUID(), boot: UUID().uuidString, baseline: .explicitZero, phase: .active))
        let runner = FakeRunner(value: "1", journal: journal)
        let backend = SystemSleepBackend(runner: runner, journal: journal, assertions: assertions)
        try await backend.enable(closedLidMode: false)
        #expect(await runner.commands == [.read, .disable, .read])
        #expect(try journal.load() == nil)
        #expect(assertions.enabled)
    }

    @Test func normalTransactionPersistsBeforeWriteAndRemovesAfterVerifiedZero() async throws {
        let journal = MemoryJournal(), assertions = FakeAssertions()
        let runner = FakeRunner(journal: journal)
        let backend = SystemSleepBackend(runner: runner, journal: journal, assertions: assertions)
        try await backend.recover()
        try await backend.enable()
        #expect(assertions.enabled)
        #expect(try journal.load()?.phase == .active)
        try await backend.disable()
        #expect(!assertions.enabled)
        #expect(try journal.load() == nil)
        #expect(await runner.commands == [.read, .enable, .read, .read, .disable, .read])
        try await backend.disable()
        #expect(await runner.commands == [.read, .enable, .read, .read, .disable, .read])
    }

    @Test func externalOverrideIsNeverAdoptedOrCleared() async throws {
        let journal = MemoryJournal(), assertions = FakeAssertions()
        let runner = FakeRunner(value: "1", journal: journal)
        let backend = SystemSleepBackend(runner: runner, journal: journal, assertions: assertions)
        do { try await backend.enable(); Issue.record("Expected external override") }
        catch let failure as ServiceFailure { #expect(failure.code == .externalOverride) }
        try await backend.disable()
        try await backend.recover()
        #expect(await runner.commands == [.read])
        #expect(!assertions.enabled)
    }

    @Test func diskFailurePreventsAllWritesAndAssertions() async throws {
        let journal = MemoryJournal(), assertions = FakeAssertions()
        journal.failWrites = true
        let runner = FakeRunner(journal: journal)
        let backend = SystemSleepBackend(runner: runner, journal: journal, assertions: assertions)
        await #expect(throws: ServiceFailure.self) { try await backend.enable() }
        #expect(await runner.commands == [.read])
        #expect(!assertions.enabled)
    }

    @Test func timedOutEnableRetainsRecordAndReconcilesBeforeOppositeWrite() async throws {
        let journal = MemoryJournal(), assertions = FakeAssertions()
        let runner = FakeRunner(journal: journal)
        await runner.configure(failedEnable: true)
        let backend = SystemSleepBackend(runner: runner, journal: journal, assertions: assertions)
        await #expect(throws: ServiceFailure.self) { try await backend.enable() }
        #expect(try journal.load() != nil)
        #expect(!assertions.enabled)
        await runner.configure(invalidRead: true)
        await #expect(throws: ServiceFailure.self) { try await backend.disable() }
        #expect(await runner.commands == [.read, .enable, .read])
        #expect(try journal.load()?.phase == .releasing)
        await runner.configure()
        try await backend.disable()
        #expect(await runner.commands == [.read, .enable, .read, .read, .disable, .read])
        #expect(try journal.load() == nil)
    }

    @Test func timedOutClearIsVerifiedOnRetryWithoutAnotherWrite() async throws {
        let journal = MemoryJournal(), assertions = FakeAssertions()
        let runner = FakeRunner(journal: journal)
        let backend = SystemSleepBackend(runner: runner, journal: journal, assertions: assertions)
        try await backend.enable()
        await runner.configure(failedDisable: true)
        await #expect(throws: ServiceFailure.self) { try await backend.disable() }
        #expect(try journal.load() != nil)
        try await backend.recover()
        #expect(try journal.load() == nil)
        #expect(await runner.commands.filter { $0 == .disable }.count == 1)
    }

    @Test func recoveryOfPriorBootStaysOff() async throws {
        let journal = MemoryJournal(), assertions = FakeAssertions()
        try journal.save(RecoveryRecord(operation: UUID(), boot: UUID().uuidString, baseline: .defaultFalse, phase: .active))
        let runner = FakeRunner(value: "1", journal: journal)
        let backend = SystemSleepBackend(runner: runner, journal: journal, assertions: assertions)
        try await backend.recover()
        #expect(await runner.commands == [.read, .disable, .read])
        #expect(try journal.load() == nil)
        #expect(!assertions.enabled)
    }
}

@Suite struct RecoveryJournalTests {
    private func directory() throws -> URL {
        // Use the physical path: Foundation canonicalizes /private/var back to
        // /var, a symbolic link that the no-symlink traversal correctly refuses.
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("caffeine-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test func roundTripAndPermissions() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let journal = FileRecoveryJournal(directory: url, owner: geteuid())
        #expect(try journal.load() == nil)
        let record = RecoveryRecord(operation: UUID(), boot: UUID().uuidString, baseline: .explicitZero, phase: .prepared)
        try journal.save(record)
        #expect(try journal.load() == record)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("sleep-recovery.json").path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        try journal.remove()
        #expect(try journal.load() == nil)
    }

    @Test func rejectsSymlinkAndUnsafeDirectory() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let journal = FileRecoveryJournal(directory: url, owner: geteuid())
        let file = url.appendingPathComponent("sleep-recovery.json")
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "/etc/passwd")
        #expect(throws: (any Error).self) { try journal.load() }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try journal.load() }
    }

    @Test func rejectsMalformedOrUnsupportedRecord() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let journal = FileRecoveryJournal(directory: url, owner: geteuid())
        let file = url.appendingPathComponent("sleep-recovery.json")
        try Data("not-json".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) { try journal.load() }
        try FileManager.default.removeItem(at: file)
        var record = RecoveryRecord(operation: UUID(), boot: UUID().uuidString, baseline: .explicitZero, phase: .prepared)
        record.schema = 999
        try JSONEncoder().encode(record).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) { try journal.load() }
    }

    @Test func rejectsExtendedAccessEvenWhenModeIsPrivate() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let journal = FileRecoveryJournal(directory: url, owner: geteuid())
        #expect(try journal.load() == nil)
        let result = try await BoundedProcess.run(executable: "/bin/chmod", arguments: ["+a", "everyone allow add_file", url.path])
        #expect(result.succeeded)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(throws: (any Error).self) { try journal.load() }
    }

    @Test func rejectsHardlinkedRecord() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let journal = FileRecoveryJournal(directory: url, owner: geteuid())
        try journal.save(RecoveryRecord(operation: UUID(), boot: UUID().uuidString, baseline: .explicitZero, phase: .prepared))
        try FileManager.default.linkItem(at: url.appendingPathComponent("sleep-recovery.json"), to: url.appendingPathComponent("second-link"))
        #expect(throws: (any Error).self) { try journal.load() }
    }
}

@Suite struct BoundedProcessTests {
    @Test func capturesSafeReadOnlyProcess() async throws {
        let result = try await BoundedProcess.run(executable: "/usr/bin/printf", arguments: ["hello\n"])
        #expect(result.succeeded)
        #expect(result.output == "hello\n")
    }

    @Test func timeoutReturnsOnlyAfterTerminationAndNextCommandWorks() async throws {
        let result = try await BoundedProcess.run(executable: "/bin/sleep", arguments: ["10"], timeout: .milliseconds(30))
        #expect(result.timedOut)
        #expect(!result.succeeded)
        let next = try await BoundedProcess.run(executable: "/usr/bin/printf", arguments: ["after"])
        #expect(next.output == "after")
    }

    @Test func overflowIsNeverAcceptedAsACompleteRead() async throws {
        let result = try await BoundedProcess.run(executable: "/usr/bin/printf", arguments: ["123456789"], outputLimit: 4)
        #expect(result.truncated)
        #expect(!result.succeeded)
        #expect(result.output.utf8.count == 4)
    }

    @Test func continuouslyFloodingChildCannotStarveTimeout() async throws {
        let result = try await BoundedProcess.run(executable: "/usr/bin/yes", arguments: [], timeout: .milliseconds(40), outputLimit: 128)
        #expect(result.timedOut)
        #expect(result.truncated)
        #expect(result.output.utf8.count == 128)
    }
}
