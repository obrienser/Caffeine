import Foundation

public enum TimerPreset: Int, CaseIterable, Identifiable, Sendable {
    case noLimit = 0
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200
    case fourHours = 14400
    case eightHours = 28800

    public var id: Int { rawValue }
    public var duration: TimeInterval? { self == .noLimit ? nil : TimeInterval(rawValue) }

    public var title: String {
        switch self {
        case .noLimit: "No Limit"
        case .fifteenMinutes: "15 min"
        case .thirtyMinutes: "30 min"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .fourHours: "4 hours"
        case .eightHours: "8 hours"
        }
    }
}

public enum PowerSource: Sendable {
    case external
    case battery
    case unknown
}

public enum SessionState: Equatable, Sendable {
    case off
    case starting
    case active
    case waitingForPower
    case powerSourceUnavailable
    case stopping
    case setupRequired
    case failed(String)
    case cleanupRequired(String)
}

@MainActor
public protocol ElapsedTimeSource {
    var now: TimeInterval { get }
}

/// Advances through system sleep and is unaffected by wall-clock adjustments.
@MainActor
public final class ContinuousElapsedTimeSource: ElapsedTimeSource {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() { origin = clock.now }

    public var now: TimeInterval {
        let elapsed = origin.duration(to: clock.now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}

@MainActor
public protocol SessionPreferences: AnyObject {
    var onlyWhenCharging: Bool { get set }
    var closedLidMode: Bool { get set }
    var timerPreset: TimerPreset { get set }
}

@MainActor
public final class InMemorySessionPreferences: SessionPreferences {
    public var onlyWhenCharging: Bool
    public var closedLidMode: Bool
    public var timerPreset: TimerPreset

    public init(onlyWhenCharging: Bool = false, closedLidMode: Bool = true, timerPreset: TimerPreset = .noLimit) {
        self.onlyWhenCharging = onlyWhenCharging
        self.closedLidMode = closedLidMode
        self.timerPreset = timerPreset
    }
}

/// Deliberately has no key for an active session or its deadline.
@MainActor
public final class UserDefaultsSessionPreferences: SessionPreferences {
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "caffeine.") {
        self.defaults = defaults
        prefix = keyPrefix
    }

    public var onlyWhenCharging: Bool {
        get { defaults.bool(forKey: prefix + "onlyWhenCharging") }
        set { defaults.set(newValue, forKey: prefix + "onlyWhenCharging") }
    }

    public var closedLidMode: Bool {
        // Without a saved preference, Closed Lid Mode is on, as in earlier versions.
        get { defaults.object(forKey: prefix + "closedLidMode") as? Bool ?? true }
        set { defaults.set(newValue, forKey: prefix + "closedLidMode") }
    }

    public var timerPreset: TimerPreset {
        get { TimerPreset(rawValue: defaults.integer(forKey: prefix + "timerPreset")) ?? .noLimit }
        set { defaults.set(newValue.rawValue, forKey: prefix + "timerPreset") }
    }
}
