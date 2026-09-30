import Foundation

/// Severity follows the unified log. `debug` is for repetitive detail and is
/// never written to Caffeine's own files.
public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug, info, notice, error, fault

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .error: "ERROR"
        case .fault: "FAULT"
        }
    }
}

/// A fixed vocabulary keeps exported logs searchable.
public struct LogCategory: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let app = Self(rawValue: "app")
    public static let session = Self(rawValue: "session")
    public static let setup = Self(rawValue: "setup")
    public static let service = Self(rawValue: "service")
    public static let lid = Self(rawValue: "lid")
    public static let audio = Self(rawValue: "audio")
    public static let export = Self(rawValue: "export")
    public static let helper = Self(rawValue: "helper")
    public static let connection = Self(rawValue: "connection")
    public static let power = Self(rawValue: "power")
    public static let recovery = Self(rawValue: "recovery")
    public static let logging = Self(rawValue: "logging")
}

public struct LogEntry: Sendable, Equatable {
    public let date: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String

    public init(date: Date, level: LogLevel, category: LogCategory, message: String) {
        self.date = date; self.level = level; self.category = category; self.message = message
    }
}

public protocol LogSink: Sendable {
    func write(_ entry: LogEntry)
    func flush()
}

/// Callable from any thread or actor. Messages describe actions and errors;
/// callers never pass passwords, tokens or file contents.
public final class EventLog: Sendable {
    /// Tests and previews record nothing and never evaluate a message.
    public static let disabled = EventLog(sinks: [])

    private let sinks: [any LogSink]
    private let now: @Sendable () -> Date

    public init(sinks: [any LogSink], now: @escaping @Sendable () -> Date = { Date() }) {
        self.sinks = sinks
        self.now = now
    }

    public var isEnabled: Bool { !sinks.isEmpty }

    public func log(_ level: LogLevel, _ category: LogCategory, _ message: @autoclosure () -> String) {
        guard !sinks.isEmpty else { return }
        let entry = LogEntry(date: now(), level: level, category: category, message: message())
        for sink in sinks { sink.write(entry) }
    }

    public func debug(_ category: LogCategory, _ message: @autoclosure () -> String) { log(.debug, category, message()) }
    public func info(_ category: LogCategory, _ message: @autoclosure () -> String) { log(.info, category, message()) }
    public func notice(_ category: LogCategory, _ message: @autoclosure () -> String) { log(.notice, category, message()) }
    public func error(_ category: LogCategory, _ message: @autoclosure () -> String) { log(.error, category, message()) }
    public func fault(_ category: LogCategory, _ message: @autoclosure () -> String) { log(.fault, category, message()) }

    /// Before an orderly exit. Entries are already written; this asks for durability.
    public func flush() { for sink in sinks { sink.flush() } }
}

/// Retains entries for tests. It performs no input or output.
public final class MemoryLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LogEntry] = []
    private var flushCount = 0

    public init() {}

    public var entries: [LogEntry] { lock.withLock { stored } }
    public var flushes: Int { lock.withLock { flushCount } }
    public func removeAll() { lock.withLock { stored.removeAll() } }
    public func write(_ entry: LogEntry) { lock.withLock { stored.append(entry) } }
    public func flush() { lock.withLock { flushCount += 1 } }
}
