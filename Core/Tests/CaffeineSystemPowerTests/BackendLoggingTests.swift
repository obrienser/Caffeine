import Foundation
import Testing
import CaffeineHelperCore
import CaffeineLogging
import CaffeineServiceProtocol
@testable import CaffeineSystemPower

private final class LoggedJournal: RecoveryJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RecoveryRecord?
    func load() throws -> RecoveryRecord? { lock.withLock { stored } }
    func save(_ record: RecoveryRecord) throws { lock.withLock { stored = record } }
    func remove() throws { lock.withLock { stored = nil } }
}

private final class LoggedAssertions: SleepAssertions, @unchecked Sendable {
    func acquire() throws {}
    func release() throws {}
}

private actor LoggedRunner: PMSetRunning {
    var value: String?
    var failWrites = false
    var unreadable = false
    init(value: String? = "0") { self.value = value }
    func configure(failWrites: Bool = false, unreadable: Bool = false) { self.failWrites = failWrites; self.unreadable = unreadable }
    func run(_ command: PMSetCommand) async throws -> PMSetResult {
        if command == .read {
            if unreadable { return PMSetResult(output: "unexpected\n") }
            let line = value.map { "SleepDisabled \($0)" } ?? "DestroyFVKeyOnStandby 0"
            return PMSetResult(output: "System-wide power settings:\n \(line)\nCurrently in use:\n standby 1\n")
        }
        if failWrites { return PMSetResult(output: "", status: 9, timedOut: true) }
        value = command == .enable ? "1" : "0"
        return PMSetResult(output: "")
    }
}

@Suite struct BackendLoggingTests {
    private func backend(_ runner: LoggedRunner, _ journal: LoggedJournal, _ sink: MemoryLogSink) -> SystemSleepBackend {
        SystemSleepBackend(runner: runner, journal: journal, assertions: LoggedAssertions(), log: EventLog(sinks: [sink]))
    }
    private func messages(_ sink: MemoryLogSink, _ level: LogLevel) -> [String] {
        sink.entries.filter { $0.level == level }.map(\.message)
    }

    @Test func closedLidTransactionRecordsEveryCommandAndReadBack() async throws {
        let sink = MemoryLogSink(), runner = LoggedRunner(value: nil), journal = LoggedJournal()
        let backend = backend(runner, journal, sink)
        try await backend.enable(closedLidMode: true)
        #expect(messages(sink, .info) == [
            "pmset -g: exit 0", "SleepDisabled reads absent (default 0)",
            "Recovery record saved before changing the sleep setting",
            "pmset -a disablesleep 1: exit 0", "pmset -g: exit 0", "SleepDisabled reads 1"])
        sink.removeAll()
        try await backend.disable()
        #expect(messages(sink, .info) == [
            "Restoring the sleep setting from a recovery record in phase active",
            "pmset -g: exit 0", "SleepDisabled reads 1", "pmset -a disablesleep 0: exit 0",
            "pmset -g: exit 0", "SleepDisabled reads 0",
            "The sleep setting is restored and read back; the recovery record is removed"])
        #expect(!sink.entries.contains { $0.level >= .error })
    }

    @Test func ordinaryModeRecordsThatTheSettingIsUntouched() async throws {
        let sink = MemoryLogSink()
        let backend = backend(LoggedRunner(value: "1"), LoggedJournal(), sink)
        try await backend.enable(closedLidMode: false)
        #expect(sink.entries.map(\.message) == ["Idle system and display assertions are held; the sleep setting is untouched"])
    }

    @Test func failuresNameTheCommandAndKeepTheRecord() async throws {
        let sink = MemoryLogSink(), runner = LoggedRunner(), journal = LoggedJournal()
        let backend = backend(runner, journal, sink)
        await runner.configure(failWrites: true)
        await #expect(throws: ServiceFailure.self) { try await backend.enable(closedLidMode: true) }
        #expect(messages(sink, .error).contains("pmset -a disablesleep 1: exit 9, timed out"))
        #expect(messages(sink, .error).contains("Disabling sleep could not be verified; the recovery record is kept"))

        let external = MemoryLogSink()
        await #expect(throws: ServiceFailure.self) {
            try await self.backend(LoggedRunner(value: "1"), LoggedJournal(), external).enable(closedLidMode: true)
        }
        #expect(messages(external, .error) == ["Sleep was already disabled outside Caffeine; nothing was changed"])

        let unreadable = MemoryLogSink(), silent = LoggedRunner()
        await silent.configure(unreadable: true)
        await #expect(throws: ServiceFailure.self) {
            try await self.backend(silent, LoggedJournal(), unreadable).enable(closedLidMode: true)
        }
        #expect(messages(unreadable, .error).contains("The sleep setting could not be read reliably"))
    }
}
