import Darwin
import Foundation
import os

/// Where one process keeps its log, and who must own it.
public struct LogFileLocation: Sendable, Equatable {
    /// Absolute, without symbolic links or `..`.
    public let directory: String
    public let name: String
    public let owner: uid_t
    public let directoryMode: mode_t
    public let fileMode: mode_t

    public init(directory: String, name: String, owner: uid_t, directoryMode: mode_t, fileMode: mode_t) {
        self.directory = directory; self.name = name; self.owner = owner
        self.directoryMode = directoryMode; self.fileMode = fileMode
    }

    /// The root service's log. Users may read it; only root can write or replace it.
    public static let helper = LogFileLocation(directory: "/Library/Logs/Caffeine", name: "CaffeineHelper.log",
                                               owner: 0, directoryMode: 0o755, fileMode: 0o644)

    /// The app's log, private to the user who runs it.
    public static func application(logsDirectory: URL, owner: uid_t = geteuid()) -> LogFileLocation {
        LogFileLocation(directory: canonicalPath(logsDirectory.path) + "/Caffeine",
                        name: "Caffeine.log", owner: owner, directoryMode: 0o700, fileMode: 0o600)
    }

    /// A home folder can be reached through links. Foundation's own resolution
    /// keeps some of them, so ask the system; an unknown path is returned as given.
    public static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

public struct LogFileError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Reason: Sendable, Equatable { case missing, unsafe, unreadable }
    public let reason: Reason
    public let code: Int32

    public init(reason: Reason, code: Int32) {
        self.reason = reason; self.code = code
    }

    public var description: String {
        switch reason {
        case .missing: "The log has not been written yet."
        case .unsafe: "The log location has unexpected ownership, permissions or links."
        case .unreadable: "The log could not be read (error \(code))."
        }
    }
}

/// Descriptor-relative access. A substituted directory, symbolic link or hard
/// link is refused instead of followed, which matters for the root service.
struct LogDirectory {
    let location: LogFileLocation

    func open(creating: Bool) throws -> Int32 {
        let components = location.directory.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard location.directory.hasPrefix("/"), !components.isEmpty,
              !components.contains(".."), !components.contains("."),
              !location.name.isEmpty, !location.name.contains("/") else { throw LogFileError(reason: .unsafe, code: EINVAL) }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LogFileError(reason: .unreadable, code: errno) }
        do {
            for (index, component) in components.enumerated() {
                let last = index == components.count - 1
                var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && last && creating {
                    guard mkdirat(descriptor, component, location.directoryMode) == 0 || errno == EEXIST else {
                        throw LogFileError(reason: .unreadable, code: errno)
                    }
                    next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    // The process mask must not decide who can read the log.
                    if next >= 0 { _ = fchmod(next, location.directoryMode) }
                }
                guard next >= 0 else {
                    let code = errno
                    throw LogFileError(reason: code == ENOENT ? .missing : (code == ELOOP || code == ENOTDIR ? .unsafe : .unreadable),
                                       code: code)
                }
                close(descriptor); descriptor = next
                var info = stat()
                guard fstat(descriptor, &info) == 0 else { throw LogFileError(reason: .unreadable, code: errno) }
                if last {
                    guard info.st_uid == location.owner, info.st_mode & 0o022 == 0 else {
                        throw LogFileError(reason: .unsafe, code: EPERM)
                    }
                } else if location.owner == 0 {
                    // Nobody but root may be able to replace a parent of the root log.
                    guard info.st_uid == 0, info.st_mode & 0o022 == 0 else { throw LogFileError(reason: .unsafe, code: EPERM) }
                }
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    func validated(_ file: Int32) throws {
        var info = stat()
        guard fstat(file, &info) == 0 else { throw LogFileError(reason: .unreadable, code: errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == location.owner,
              info.st_nlink == 1, info.st_mode & 0o022 == 0 else { throw LogFileError(reason: .unsafe, code: EPERM) }
    }
}

/// Appends each entry before returning, so a crash loses nothing already logged.
/// The newest file is `name`; older ones are `name.1` to `name.N`.
public final class RotatingFileSink: LogSink, @unchecked Sendable {
    public static let defaultMaximumFileBytes = 1_048_576
    public static let defaultRotatedFiles = 4
    /// A location that could not be opened is tried again no sooner than this.
    static let retryInterval: Duration = .seconds(60)

    public let location: LogFileLocation
    private let subsystem: String
    private let maximumFileBytes: Int
    private let rotatedFiles: Int
    private let minimumLevel: LogLevel
    private let timeZone: @Sendable () -> TimeZone
    private let lock = NSLock()
    private var directory: Int32 = -1
    private var file: Int32 = -1
    private var size = 0
    private var retryAfter: ContinuousClock.Instant?
    private var failure: String?

    /// `subsystem` names the system log that records why the file is unavailable.
    public init(location: LogFileLocation, subsystem: String,
                maximumFileBytes: Int = RotatingFileSink.defaultMaximumFileBytes,
                rotatedFiles: Int = RotatingFileSink.defaultRotatedFiles, minimumLevel: LogLevel = .info,
                timeZone: @escaping @Sendable () -> TimeZone = { .current }) {
        self.location = location
        self.subsystem = subsystem
        self.maximumFileBytes = max(1_024, maximumFileBytes)
        self.rotatedFiles = max(1, rotatedFiles)
        self.minimumLevel = minimumLevel
        self.timeZone = timeZone
    }

    deinit { closeFiles() }

    /// Nil while the file accepts entries.
    public var lastFailure: String? { lock.withLock { failure } }

    public func write(_ entry: LogEntry) {
        guard entry.level >= minimumLevel else { return }
        let bytes = Array(LogFormatter.line(for: entry, timeZone: timeZone()).utf8)
        lock.withLock {
            // A log deleted or replaced while open would otherwise be written unseen.
            if file >= 0 && !fileIsInPlace() { closeFiles() }
            guard ready() else { return }
            if size > 0 && size + bytes.count > maximumFileBytes { rotate() }
            guard file >= 0 else { return }
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { Darwin.write(file, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else {
                    fail("Writing the log failed (error \(errno)).")
                    return
                }
                offset += written
            }
            size += bytes.count
        }
    }

    public func flush() {
        lock.withLock { if file >= 0 { _ = fsync(file) } }
    }

    private func fileIsInPlace() -> Bool {
        var open = stat(), named = stat()
        guard fstat(file, &open) == 0, fstatat(directory, location.name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return open.st_ino == named.st_ino && open.st_dev == named.st_dev
    }

    private func ready() -> Bool {
        if file >= 0 { return true }
        if let retryAfter, ContinuousClock().now < retryAfter { return false }
        do {
            let access = LogDirectory(location: location)
            directory = try access.open(creating: true)
            try openCurrentFile(access)
            retryAfter = nil
            failure = nil
            return true
        } catch {
            fail("\(error)")
            return false
        }
    }

    private func openCurrentFile(_ access: LogDirectory) throws {
        let descriptor = openat(directory, location.name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, location.fileMode)
        guard descriptor >= 0 else { throw LogFileError(reason: errno == ELOOP ? .unsafe : .unreadable, code: errno) }
        do {
            try access.validated(descriptor)
            guard fchmod(descriptor, location.fileMode) == 0 else { throw LogFileError(reason: .unreadable, code: errno) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw LogFileError(reason: .unreadable, code: errno) }
            file = descriptor
            size = Int(info.st_size)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func rotate() {
        close(file); file = -1
        _ = unlinkat(directory, "\(location.name).\(rotatedFiles)", 0)
        for generation in stride(from: rotatedFiles - 1, through: 1, by: -1) {
            _ = renameat(directory, "\(location.name).\(generation)", directory, "\(location.name).\(generation + 1)")
        }
        guard renameat(directory, location.name, directory, "\(location.name).1") == 0 else {
            fail("Rotating the log failed (error \(errno)).")
            return
        }
        do { try openCurrentFile(LogDirectory(location: location)) }
        catch { fail("\(error)") }
    }

    private func fail(_ message: String) {
        closeFiles()
        retryAfter = ContinuousClock().now.advanced(by: Self.retryInterval)
        guard failure != message else { return }
        failure = message
        // The file is unavailable, so only the system log can record why.
        Logger(subsystem: subsystem, category: LogCategory.logging.rawValue)
            .fault("Caffeine's log file is unavailable: \(message, privacy: .public)")
    }

    private func closeFiles() {
        if file >= 0 { close(file); file = -1 }
        if directory >= 0 { close(directory); directory = -1 }
        size = 0
    }
}

/// Read-only access for export, oldest entries first.
public enum LogFileReader {
    /// Rotation can overshoot a file by one entry.
    static let slack = 8_192

    public static func read(_ location: LogFileLocation, rotatedFiles: Int = RotatingFileSink.defaultRotatedFiles,
                            maximumFileBytes: Int = RotatingFileSink.defaultMaximumFileBytes) throws -> Data {
        let access = LogDirectory(location: location)
        let directory = try access.open(creating: false)
        defer { close(directory) }
        var result = Data()
        var found = false
        let names = (1...max(1, rotatedFiles)).reversed().map { "\(location.name).\($0)" } + [location.name]
        for name in names {
            let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0 && errno == ENOENT { continue }
            guard descriptor >= 0 else { throw LogFileError(reason: errno == ELOOP ? .unsafe : .unreadable, code: errno) }
            defer { close(descriptor) }
            try access.validated(descriptor)
            found = true
            var remaining = maximumFileBytes + slack
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while remaining > 0 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, min($0.count, remaining)) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw LogFileError(reason: .unreadable, code: errno) }
                if count == 0 { break }
                result.append(contentsOf: buffer.prefix(count))
                remaining -= count
            }
            if let last = result.last, last != UInt8(ascii: "\n") { result.append(UInt8(ascii: "\n")) }
        }
        guard found else { throw LogFileError(reason: .missing, code: ENOENT) }
        return result
    }
}
