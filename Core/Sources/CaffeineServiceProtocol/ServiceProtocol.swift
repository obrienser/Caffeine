import Foundation

public enum CaffeineServiceIdentity {
    // v8 adds the check for a fan recovery record of an older helper, after v7
    // removed fan control. A running v7 helper lacks it, so it must be replaced.
    public static let protocolVersion = 8
    // Monotonic implementation build, independent of the wire version. Bump for
    // every shipped helper change, together with both targets' CFBundleVersion.
    // Compiled into each executable: replacing the bundle cannot change the
    // identity reported by an already-running helper.
    public static let helperBuild = 3
    public static let appIdentifier = "com.serhiital.Caffeine"
    public static let helperIdentifier = "com.serhiital.Caffeine.Helper"
    public static let machService = "com.serhiital.Caffeine.Helper"
    public static let daemonPlist = "com.serhiital.Caffeine.Helper.plist"
    public static let teamIdentifier = "WQ33LA2JZ5"
    public static let allowedDurations = [0, 900, 1800, 3600, 7200, 14400, 28800]

    public static func signingRequirement(identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

@objc public protocol CaffeineHelperXPC {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public enum ServiceAction: String, Codable, Sendable {
    case status, start, update, heartbeat, stop
}

public struct ServiceRequest: Codable, Sendable {
    public var version: Int
    public var action: ServiceAction
    public var generation: UUID?
    public var revision: UInt64
    public var onlyWhenCharging: Bool?
    public var closedLidMode: Bool?
    public var durationSeconds: Int?

    public init(action: ServiceAction, generation: UUID? = nil, revision: UInt64 = 0,
                onlyWhenCharging: Bool? = nil, closedLidMode: Bool? = nil, durationSeconds: Int? = nil,
                version: Int = CaffeineServiceIdentity.protocolVersion) {
        self.version = version; self.action = action; self.generation = generation
        self.revision = revision; self.onlyWhenCharging = onlyWhenCharging
        self.closedLidMode = closedLidMode
        self.durationSeconds = durationSeconds
    }
}

public enum ServicePowerSource: String, Codable, Sendable { case external, battery, unknown }
public enum ServicePhase: String, Codable, Sendable {
    case off, starting, active, waitingForPower, powerSourceUnavailable, stopping
    case externalOverride, cleanupRequired, unavailable
}

public struct ServiceSnapshot: Codable, Sendable {
    public var phase: ServicePhase
    /// A settled activation error can coexist with readiness for a fresh request.
    /// Transport-level failures must leave this false: they cannot certify cleanup.
    public var readyForSession: Bool
    public var requested: Bool
    public var generation: UUID?
    public var revision: UInt64
    public var onlyWhenCharging: Bool
    public var closedLidMode: Bool
    public var durationSeconds: Int
    public var remainingSeconds: Int?
    public var powerSource: ServicePowerSource
    public var message: String?

    public var isSettled: Bool {
        readyForSession && !requested && [.off, .externalOverride, .unavailable].contains(phase)
    }

    public init(phase: ServicePhase = .off, readyForSession: Bool = false, requested: Bool = false, generation: UUID? = nil,
                revision: UInt64 = 0, onlyWhenCharging: Bool = false, closedLidMode: Bool = true, durationSeconds: Int = 0,
                remainingSeconds: Int? = nil, powerSource: ServicePowerSource = .unknown, message: String? = nil) {
        self.phase = phase; self.readyForSession = readyForSession
        self.requested = requested; self.generation = generation
        self.revision = revision; self.onlyWhenCharging = onlyWhenCharging
        self.closedLidMode = closedLidMode
        self.durationSeconds = durationSeconds; self.remainingSeconds = remainingSeconds
        self.powerSource = powerSource; self.message = message
    }
}

public enum ServiceFailureCode: String, Codable, Sendable {
    case invalidRequest, incompatibleVersion, notOwner, staleRevision, busy
    case externalOverride, unavailable, cleanupRequired
}

public struct ServiceFailure: Error, Codable, Sendable, LocalizedError {
    public let code: ServiceFailureCode
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: ServiceFailureCode, _ message: String) { self.code = code; self.message = message }
}

public struct ServiceReply: Codable, Sendable {
    public let version: Int
    /// Missing only in helpers released before build identification was added.
    public let helperBuild: Int?
    public let snapshot: ServiceSnapshot
    public let failure: ServiceFailure?
    public init(snapshot: ServiceSnapshot, failure: ServiceFailure? = nil, version: Int = CaffeineServiceIdentity.protocolVersion,
                helperBuild: Int? = CaffeineServiceIdentity.helperBuild) {
        self.version = version; self.helperBuild = helperBuild; self.snapshot = snapshot; self.failure = failure
    }
}
