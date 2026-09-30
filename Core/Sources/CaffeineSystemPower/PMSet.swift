import Foundation
import Darwin

enum SleepDisabledValue: Equatable, Sendable {
    case enabled, disabled, defaultDisabled
}

enum PMSetCommand: Sendable, Equatable {
    case read, enable, disable
    var arguments: [String] {
        switch self {
        case .read: ["-g"]
        case .enable: ["-a", "disablesleep", "1"]
        case .disable: ["-a", "disablesleep", "0"]
        }
    }
}

struct PMSetResult: Sendable {
    var output: String
    var status: Int32 = 0
    var timedOut = false
    var truncated = false
    var validUTF8 = true
    var succeeded: Bool { status == 0 && !timedOut && !truncated && validUTF8 }
}

protocol PMSetRunning: Sendable {
    func run(_ command: PMSetCommand) async throws -> PMSetResult
}

enum PMSetParser {
    /// The entire output must have been captured successfully. An omitted key is
    /// Apple's default false only inside a complete, recognized system section.
    static func parse(_ result: PMSetResult) -> SleepDisabledValue? {
        guard result.succeeded, result.output.hasSuffix("\n") else { return nil }
        let lines = result.output.components(separatedBy: .newlines)
        guard lines.filter({ $0 == "System-wide power settings:" }).count == 1,
              lines.filter({ $0 == "Currently in use:" }).count == 1,
              let start = lines.firstIndex(of: "System-wide power settings:"),
              let end = lines.firstIndex(of: "Currently in use:"), start < end,
              lines[..<start].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        var found: SleepDisabledValue?
        for line in lines[(start + 1)..<end] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard line.first?.isWhitespace == true else { return nil }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { return nil }
            if fields[0] == "SleepDisabled" {
                guard found == nil else { return nil }
                switch fields[1] {
                case "0": found = .disabled
                case "1": found = .enabled
                default: return nil
                }
            }
        }
        // A SleepDisabled key outside the recognized section makes the output ambiguous.
        guard !lines[(end + 1)...].contains(where: { $0.split(whereSeparator: \.isWhitespace).first == "SleepDisabled" }) else { return nil }
        return found ?? .defaultDisabled
    }
}

/// Fixed executable and command vocabulary. No shell and no caller-supplied args.
struct SystemPMSetRunner: PMSetRunning {
    func run(_ command: PMSetCommand) async throws -> PMSetResult {
        try await BoundedProcess.run(executable: "/usr/bin/pmset", arguments: command.arguments)
    }
}

/// A detached task drains pipes without blocking the calling actor. Cancellation of
/// the caller cannot abandon a child: return only after Foundation has reaped it.
enum BoundedProcess {
    static func run(executable: String, arguments: [String], timeout: Duration = .seconds(5),
                    outputLimit: Int = 65_536) async throws -> PMSetResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let out = Pipe(), err = Pipe()
            let completion = ProcessCompletion()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { child in completion.finish(child.terminationStatus) }
            defer {
                try? out.fileHandleForReading.close(); try? out.fileHandleForWriting.close()
                try? err.fileHandleForReading.close(); try? err.fileHandleForWriting.close()
            }
            for descriptor in [out.fileHandleForReading.fileDescriptor, err.fileHandleForReading.fileDescriptor] {
                guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
            }
            try process.run()
            try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
            let clock = SuspendingClock()
            let deadline = clock.now.advanced(by: timeout)
            var killAt: SuspendingClock.Instant?
            var timedOut = false, truncated = false
            var readFailed = false
            var stdout = Data(), stderr = Data()
            var captured = 0
            var buffer = [UInt8](repeating: 0, count: 4096)
            func drain(_ fd: Int32, into bytes: inout Data) {
                // Bound work per turn even if a child continuously floods a pipe.
                for _ in 0..<16 {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        if errno != EAGAIN && errno != EWOULDBLOCK { readFailed = true }
                        break
                    }
                    let available = max(0, outputLimit - captured)
                    if count > available { truncated = true }
                    let accepted = min(count, available)
                    bytes.append(contentsOf: buffer.prefix(accepted))
                    captured += accepted
                }
            }
            while true {
                drain(out.fileHandleForReading.fileDescriptor, into: &stdout)
                drain(err.fileHandleForReading.fileDescriptor, into: &stderr)
                if let status = completion.status {
                    drain(out.fileHandleForReading.fileDescriptor, into: &stdout)
                    drain(err.fileHandleForReading.fileDescriptor, into: &stderr)
                    return PMSetResult(output: String(decoding: stdout, as: UTF8.self), status: status,
                                       timedOut: timedOut, truncated: truncated,
                                       validUTF8: !readFailed && String(data: stdout, encoding: .utf8) != nil)
                }
                if !timedOut && clock.now >= deadline {
                    timedOut = true
                    process.terminate()
                    killAt = clock.now.advanced(by: .milliseconds(100))
                }
                if let killAt, clock.now >= killAt {
                    // No PID reuse while this Process is still unreaped.
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                }
                try? await clock.sleep(for: .milliseconds(10))
            }
        }.value
    }
}

private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var status: Int32? { lock.withLock { value } }
    func finish(_ value: Int32) { lock.withLock { self.value = value } }
}
