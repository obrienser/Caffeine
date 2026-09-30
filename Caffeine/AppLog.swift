import AppKit
import CaffeineLogging
import CaffeineServiceProtocol
import Darwin
import Foundation
import UniformTypeIdentifiers

/// The running app writes to the system log and to its own rotating file.
/// Previews use `EventLog.disabled` and touch no file.
@MainActor
enum AppLog {
    static var location: LogFileLocation {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return .application(logsDirectory: library.appendingPathComponent("Logs"))
    }

    static func production() -> EventLog {
        EventLog(sinks: [UnifiedLogSink(subsystem: CaffeineServiceIdentity.appIdentifier),
                         RotatingFileSink(location: location, subsystem: CaffeineServiceIdentity.appIdentifier)])
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "Caffeine \(version) (\(build)), protocol \(CaffeineServiceIdentity.protocolVersion), "
            + "expects service build \(CaffeineServiceIdentity.helperBuild)"
    }

    static var system: String {
        var size = 0
        var model = "unknown model"
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1, size < 128 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 {
                model = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(model), \(architecture)"
    }

    /// Names only. The reports themselves stay where macOS keeps them.
    static func recentCrashReports(limit: Int = 5) -> [String] {
        let folders = [NSHomeDirectory() + "/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"]
        let names = folders.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
        return Array(names.filter { $0.hasPrefix("Caffeine") && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash")) }
            .sorted(by: >).prefix(limit))
    }

    static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// One text file with what support needs: versions, the visible state, and both logs.
struct LogReport {
    struct Section {
        let title: String
        let path: String
        let content: Result<Data, LogFileError>
    }

    var generated: Date
    var timeZone: TimeZone = .current
    /// Label and value, in display order. Empty values are omitted.
    var summary: [(String, String)]
    var sections: [Section]

    func data() -> Data {
        var text = "Caffeine log\n"
        let rows = [("Generated", LogFormatter.timestamp(generated, timeZone: timeZone))] + summary
        let width = (rows.map { $0.0.count }.max() ?? 0) + 2
        for (label, value) in rows where !value.isEmpty {
            text += (label + ":").padding(toLength: width, withPad: " ", startingAt: 0) + LogFormatter.sanitized(value) + "\n"
        }
        text += "\nThis file stays on your Mac until you share it. It lists Caffeine’s actions and errors. "
            + "It contains no passwords, documents or screen contents.\n"
        var result = Data(text.utf8)
        for section in sections {
            result.append(Data("\n==== \(section.title) (\(section.path), oldest first) ====\n".utf8))
            switch section.content {
            case .success(let log): result.append(log.isEmpty ? Data("(The log is empty.)\n".utf8) : log)
            case .failure(let error): result.append(Data("(\(error.description))\n".utf8))
            }
            if result.last != UInt8(ascii: "\n") { result.append(UInt8(ascii: "\n")) }
        }
        return result
    }

    static func read(_ location: LogFileLocation) -> Result<Data, LogFileError> {
        do { return .success(try LogFileReader.read(location)) }
        catch let error as LogFileError { return .failure(error) }
        catch { return .failure(LogFileError(reason: .unreadable, code: EIO)) }
    }
}

/// The standard save panel: the user chooses the place, so macOS asks for no folder access.
@MainActor
final class LogExporter {
    private let log: EventLog
    private var panel: NSSavePanel?

    init(log: EventLog) { self.log = log }

    static func suggestedName(_ date: Date, timeZone: TimeZone = .current) -> String {
        var style = Date.VerbatimFormatStyle(format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
                                             timeZone: timeZone, calendar: Calendar(identifier: .gregorian))
        style.locale = Locale(identifier: "en_US_POSIX")
        return "Caffeine Log \(date.formatted(style)).txt"
    }

    func export(_ report: @escaping () -> Data) {
        if let panel {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        log.notice(.export, "User chose Export Log")
        log.flush()
        let data = report()
        let panel = NSSavePanel()
        panel.title = "Export Caffeine Log"
        panel.message = "The log lists Caffeine’s actions and errors. It stays on your Mac until you share it."
        panel.nameFieldStringValue = Self.suggestedName(Date())
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        self.panel = panel
        // A menu bar app is not active, so its panel would open behind other windows.
        NSApp.activate()
        panel.begin { [weak self] response in
            guard let self else { return }
            self.panel = nil
            guard response == .OK, let url = panel.url else {
                self.log.info(.export, "The export was cancelled")
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                self.log.notice(.export, "Exported \(data.count) bytes to \(AppLog.abbreviatingHome(url.path))")
            } catch {
                self.log.error(.export, "The log could not be saved: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Caffeine couldn’t save the log."
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}
