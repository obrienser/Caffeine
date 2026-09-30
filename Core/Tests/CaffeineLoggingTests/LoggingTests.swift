import Darwin
import Foundation
import Testing
@testable import CaffeineLogging

private let fixedDate = Date(timeIntervalSince1970: 1_790_694_333.125)
private let zone = TimeZone(secondsFromGMT: 2 * 3_600)!

private final class Workspace {
    let root: URL
    init() throws {
        // The temporary directory is reached through a symbolic link on macOS.
        root = URL(fileURLWithPath: LogFileLocation.canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("CaffeineLogging." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func location(_ folder: String = "Caffeine", directoryMode: mode_t = 0o700, fileMode: mode_t = 0o600,
                  owner: uid_t = geteuid()) -> LogFileLocation {
        LogFileLocation(directory: root.appendingPathComponent(folder).path, name: "Caffeine.log", owner: owner,
                        directoryMode: directoryMode, fileMode: fileMode)
    }
    func sink(_ location: LogFileLocation, maximumFileBytes: Int = 1_048_576, rotatedFiles: Int = 4,
              minimumLevel: LogLevel = .info) -> RotatingFileSink {
        RotatingFileSink(location: location, subsystem: "com.serhiital.Caffeine.tests", maximumFileBytes: maximumFileBytes,
                         rotatedFiles: rotatedFiles, minimumLevel: minimumLevel, timeZone: { zone })
    }
    func text(_ location: LogFileLocation, rotatedFiles: Int = 4) throws -> String {
        String(decoding: try LogFileReader.read(location, rotatedFiles: rotatedFiles), as: UTF8.self)
    }
    func mode(_ path: String) -> mode_t {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
    }
}

private func entry(_ message: String, level: LogLevel = .notice, category: LogCategory = .session) -> LogEntry {
    LogEntry(date: fixedDate, level: level, category: category, message: message)
}

@Suite struct LogFormatTests {
    @Test func oneEntryIsOneTimestampedLine() {
        let line = LogFormatter.line(for: entry("Keep awake turned on", level: .notice), timeZone: zone)
        #expect(line == "2026-09-29T17:05:33.125+02:00 NOTICE [session] Keep awake turned on\n")
        #expect(LogFormatter.line(for: entry("x", level: .error, category: .setup), timeZone: zone)
            == "2026-09-29T17:05:33.125+02:00 ERROR  [setup] x\n")
        #expect(LogFormatter.line(for: entry("x"), timeZone: TimeZone(secondsFromGMT: 0)!).hasPrefix("2026-09-29T15:05:33.125Z "))
    }

    @Test func textCannotStartAnotherEntry() {
        let forged = "failed\n2026-09-29T17:05:33.125+02:00 NOTICE [session] Keep awake is off\r\u{2028}\u{0007}end\ttab"
        let line = LogFormatter.line(for: entry(forged), timeZone: zone)
        #expect(line.filter { $0 == "\n" }.count == 1 && line.hasSuffix("\n"))
        #expect(line.contains("failed\\n2026") && line.contains("off\\r ?end tab"))
        let category = LogFormatter.line(for: entry("x", category: LogCategory(rawValue: "a\nb")), timeZone: zone)
        #expect(category.contains("[a\\nb]"))
    }

    @Test func oversizedMessagesAreBounded() {
        let line = LogFormatter.line(for: entry(String(repeating: "é", count: 50_000)), timeZone: zone)
        #expect(line.unicodeScalars.count < LogFormatter.maximumMessageLength + 100)
        #expect(line.contains("(truncated)") && line.hasSuffix("\n"))
    }

    @Test func levelsAreOrderedAndNamed() {
        #expect(LogLevel.allCases.sorted() == [.debug, .info, .notice, .error, .fault])
        #expect(LogLevel.allCases.map(\.label) == ["DEBUG", "INFO", "NOTICE", "ERROR", "FAULT"])
    }
}

@Suite struct EventLogTests {
    @Test func disabledLogNeverEvaluatesAMessage() {
        var evaluated = 0
        func message() -> String { evaluated += 1; return "costly" }
        EventLog.disabled.notice(.app, message())
        EventLog.disabled.error(.app, message())
        #expect(evaluated == 0 && !EventLog.disabled.isEnabled)
    }

    @Test func everySinkReceivesEntriesInOrder() {
        let first = MemoryLogSink(), second = MemoryLogSink()
        let log = EventLog(sinks: [first, second], now: { fixedDate })
        log.debug(.lid, "a"); log.info(.setup, "b"); log.notice(.session, "c"); log.error(.service, "d"); log.fault(.app, "e")
        let expected = [entry("a", level: .debug, category: .lid), entry("b", level: .info, category: .setup),
                        entry("c", level: .notice, category: .session), entry("d", level: .error, category: .service),
                        entry("e", level: .fault, category: .app)]
        #expect(first.entries == expected && second.entries == expected)
        log.flush()
        #expect(first.flushes == 1 && second.flushes == 1)
    }
}

@Suite struct RotatingFileSinkTests {
    @Test func createsAPrivateLogAndAppends() throws {
        let space = try Workspace(), location = space.location()
        let sink = space.sink(location)
        sink.write(entry("first")); sink.write(entry("second", level: .error))
        sink.flush()
        #expect(try space.text(location) == """
        2026-09-29T17:05:33.125+02:00 NOTICE [session] first
        2026-09-29T17:05:33.125+02:00 ERROR  [session] second

        """)
        #expect(space.mode(location.directory) == 0o700)
        #expect(space.mode(location.directory + "/Caffeine.log") == 0o600)
        #expect(sink.lastFailure == nil)
    }

    @Test func readableLogForTheServiceIgnoresTheProcessMask() throws {
        let space = try Workspace(), location = space.location(directoryMode: 0o755, fileMode: 0o644)
        let previous = umask(0o077)
        defer { umask(previous) }
        space.sink(location).write(entry("service"))
        #expect(space.mode(location.directory) == 0o755)
        #expect(space.mode(location.directory + "/Caffeine.log") == 0o644)
    }

    @Test func repetitiveDetailStaysOutOfTheFile() throws {
        let space = try Workspace(), location = space.location()
        let sink = space.sink(location)
        sink.write(entry("heartbeat", level: .debug))
        #expect(throws: LogFileError(reason: .missing, code: ENOENT)) { try LogFileReader.read(location) }
        sink.write(entry("kept", level: .info))
        #expect(try space.text(location).contains("INFO   [session] kept"))
        #expect(try !space.text(location).contains("heartbeat"))
    }

    @Test func rotationKeepsTheNewestEntriesInOrderWithinItsBudget() throws {
        let space = try Workspace(), location = space.location()
        let sink = space.sink(location, maximumFileBytes: 1_024, rotatedFiles: 2)
        for index in 0..<200 { sink.write(entry("entry \(String(format: "%03d", index))")) }
        let names = try FileManager.default.contentsOfDirectory(atPath: location.directory).sorted()
        #expect(names == ["Caffeine.log", "Caffeine.log.1", "Caffeine.log.2"])
        for name in names {
            let size = try FileManager.default.attributesOfItem(atPath: location.directory + "/" + name)[.size] as? Int ?? 0
            #expect(size > 0 && size <= 1_024)
            #expect(space.mode(location.directory + "/" + name) == 0o600)
        }
        let lines = try space.text(location, rotatedFiles: 2).split(separator: "\n").map(String.init)
        let numbers = lines.compactMap { Int($0.suffix(3)) }
        #expect(numbers.count == lines.count && numbers.last == 199)
        // Oldest first, without gaps, and the oldest generations are gone.
        #expect(numbers == Array((numbers.first ?? 0)...199) && (numbers.first ?? 0) > 0)
        #expect(sink.lastFailure == nil)
    }

    @Test func aNewProcessContinuesTheSameFile() throws {
        let space = try Workspace(), location = space.location()
        space.sink(location, maximumFileBytes: 1_024, rotatedFiles: 2).write(entry(String(repeating: "a", count: 800)))
        let next = space.sink(location, maximumFileBytes: 1_024, rotatedFiles: 2)
        next.write(entry(String(repeating: "b", count: 800)))
        let names = try FileManager.default.contentsOfDirectory(atPath: location.directory).sorted()
        #expect(names == ["Caffeine.log", "Caffeine.log.1"])
        let text = try space.text(location, rotatedFiles: 2)
        #expect(text.range(of: "aaa")!.lowerBound < text.range(of: "bbb")!.lowerBound)
    }

    @Test func concurrentWritersNeverInterleaveWithinALine() async throws {
        let space = try Workspace(), location = space.location()
        let sink = space.sink(location, maximumFileBytes: 4_096, rotatedFiles: 60)
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<8 {
                group.addTask {
                    for index in 0..<100 { sink.write(entry("writer \(writer) entry \(index) " + String(repeating: "x", count: 40))) }
                }
            }
        }
        let lines = try space.text(location, rotatedFiles: 60).split(separator: "\n").map(String.init)
        #expect(lines.count == 800)
        #expect(lines.allSatisfy { $0.hasPrefix("2026-09-29T17:05:33.125+02:00 NOTICE [session] writer ") && $0.hasSuffix(String(repeating: "x", count: 40)) })
        #expect(Set(lines).count == 800)
    }

    @Test func deletedOrReplacedLogIsStartedAgain() throws {
        let space = try Workspace(), location = space.location()
        let sink = space.sink(location)
        sink.write(entry("before"))
        try FileManager.default.removeItem(atPath: location.directory + "/Caffeine.log")
        sink.write(entry("after file removal"))
        #expect(try space.text(location) == "2026-09-29T17:05:33.125+02:00 NOTICE [session] after file removal\n")
        try FileManager.default.removeItem(atPath: location.directory)
        sink.write(entry("after folder removal"))
        #expect(try space.text(location) == "2026-09-29T17:05:33.125+02:00 NOTICE [session] after folder removal\n")
        #expect(sink.lastFailure == nil)
    }

    @Test func linksAndUnexpectedOwnersAreRefused() throws {
        let space = try Workspace()
        let outside = space.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("victim.txt")
        try Data("untouched".utf8).write(to: victim)

        // A symbolic link in place of the log folder.
        let linkedFolder = space.location("LinkedFolder")
        try FileManager.default.createSymbolicLink(atPath: linkedFolder.directory, withDestinationPath: outside.path)
        let first = space.sink(linkedFolder)
        first.write(entry("must not be written"))
        #expect(first.lastFailure != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["victim.txt"])

        // A symbolic link and a hard link in place of the log file.
        for hard in [false, true] {
            let location = space.location(hard ? "Hard" : "Soft")
            try FileManager.default.createDirectory(atPath: location.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let path = location.directory + "/Caffeine.log"
            if hard { try FileManager.default.linkItem(atPath: victim.path, toPath: path) }
            else { try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: victim.path) }
            let sink = space.sink(location)
            sink.write(entry("must not be written"))
            #expect(sink.lastFailure != nil)
            #expect(throws: LogFileError.self) { try LogFileReader.read(location) }
        }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "untouched")

        // A folder that others can write, or that someone else owns.
        let shared = space.location("Shared")
        try FileManager.default.createDirectory(atPath: shared.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o777])
        let open = space.sink(shared)
        open.write(entry("must not be written"))
        #expect(open.lastFailure != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: shared.directory).isEmpty)
        let foreign = space.sink(space.location("Foreign", owner: geteuid() + 1))
        foreign.write(entry("must not be written"))
        #expect(foreign.lastFailure != nil)
        // The folder is judged by itself, before any file in it is opened.
        #expect(throws: LogFileError(reason: .unsafe, code: EPERM)) {
            _ = try LogDirectory(location: space.location("Foreign", owner: geteuid() + 1)).open(creating: false)
        }
        let descriptor = try LogDirectory(location: space.location("Foreign")).open(creating: false)
        #expect(descriptor >= 0)
        close(descriptor)
    }

    @Test func unusablePathsAreRejectedWithoutTouchingTheDisk() throws {
        for (directory, name) in [("relative/Caffeine", "Caffeine.log"), ("/tmp/../etc", "Caffeine.log"),
                                  ("/", "Caffeine.log"), ("/private/tmp/CaffeineLoggingUnused", "../escape.log"),
                                  ("/private/tmp/CaffeineLoggingUnused", "")] {
            let location = LogFileLocation(directory: directory, name: name, owner: geteuid(), directoryMode: 0o700, fileMode: 0o600)
            let sink = RotatingFileSink(location: location, subsystem: "com.serhiital.Caffeine.tests")
            sink.write(entry("must not be written"))
            #expect(sink.lastFailure != nil)
        }
        #expect(!FileManager.default.fileExists(atPath: "/private/tmp/CaffeineLoggingUnused"))
    }

    @Test func aFailedLocationIsNotRetriedForEveryEntry() throws {
        let space = try Workspace(), location = space.location("Later")
        try FileManager.default.createSymbolicLink(atPath: location.directory, withDestinationPath: space.root.path)
        let sink = space.sink(location)
        sink.write(entry("refused"))
        try FileManager.default.removeItem(atPath: location.directory)
        sink.write(entry("still waiting"))
        #expect(!FileManager.default.fileExists(atPath: location.directory))
        #expect(sink.lastFailure != nil)
    }

    @Test func productionLocationsAreFixed() {
        #expect(LogFileLocation.helper == LogFileLocation(directory: "/Library/Logs/Caffeine", name: "CaffeineHelper.log",
                                                          owner: 0, directoryMode: 0o755, fileMode: 0o644))
        let app = LogFileLocation.application(logsDirectory: URL(fileURLWithPath: "/Users/example/Library/Logs"), owner: 501)
        #expect(app == LogFileLocation(directory: "/Users/example/Library/Logs/Caffeine", name: "Caffeine.log",
                                       owner: 501, directoryMode: 0o700, fileMode: 0o600))
    }
}
