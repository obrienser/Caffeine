import Foundation
import os

/// The system log, readable in Console and with the `log` tool.
public final class UnifiedLogSink: LogSink, @unchecked Sendable {
    private let subsystem: String
    private let lock = NSLock()
    private var loggers: [LogCategory: Logger] = [:]

    public init(subsystem: String) { self.subsystem = subsystem }

    public func write(_ entry: LogEntry) {
        let logger = lock.withLock {
            if let logger = loggers[entry.category] { return logger }
            let logger = Logger(subsystem: subsystem, category: entry.category.rawValue)
            loggers[entry.category] = logger
            return logger
        }
        let type: OSLogType = switch entry.level {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .error: .error
        case .fault: .fault
        }
        // Messages are written for support and contain no secrets.
        logger.log(level: type, "\(LogFormatter.sanitized(entry.message), privacy: .public)")
    }

    public func flush() {}
}
