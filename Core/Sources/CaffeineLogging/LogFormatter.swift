import Foundation

/// One entry is always one line, so copied or forged text cannot look like another entry.
public enum LogFormatter {
    public static let maximumMessageLength = 2_000

    public static func line(for entry: LogEntry, timeZone: TimeZone = .current) -> String {
        "\(timestamp(entry.date, timeZone: timeZone)) \(entry.level.label.padding(toLength: 6, withPad: " ", startingAt: 0)) "
            + "[\(sanitized(entry.category.rawValue))] \(sanitized(entry.message))\n"
    }

    /// ISO 8601 with milliseconds and the local time zone's offset, or Z for UTC.
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .standard, timeSeparator: .colon,
                                               timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: timeZone))
    }

    public static func sanitized(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(min(text.utf8.count, maximumMessageLength))
        var length = 0
        for scalar in text.unicodeScalars {
            guard length < maximumMessageLength else {
                result += "… (truncated)"
                break
            }
            switch scalar {
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += " "
            // Line and paragraph separators would also start a new line in a viewer.
            case "\u{2028}", "\u{2029}", "\u{85}": result += " "
            default:
                if scalar.properties.generalCategory == .control { result += "?" }
                else { result.unicodeScalars.append(scalar) }
            }
            length += 1
        }
        return result
    }
}
