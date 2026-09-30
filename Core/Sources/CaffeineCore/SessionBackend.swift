import Foundation

public enum SessionBackendError: Error, LocalizedError, Sendable {
    case setupRequired
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .setupRequired:
            "Closed-lid support is not available in this build. Keep awake hasn’t started."
        case .unavailable(let message): message
        }
    }
}

/// Seam for the UI preview and tests, not the helper's wire protocol.
/// Calls are serialized by SessionController. prepare must not acquire a hold.
/// A failed hold change is treated as uncertain until a release succeeds.
@MainActor
public protocol SessionBackend: AnyObject {
    var isSimulated: Bool { get }
    func prepare() async throws
    func setHoldEnabled(_ enabled: Bool, closedLidMode: Bool) async throws
}

@MainActor
public final class UnavailableSessionBackend: SessionBackend {
    public let isSimulated = false
    public init() {}
    public func prepare() async throws { throw SessionBackendError.setupRequired }
    public func setHoldEnabled(_ enabled: Bool, closedLidMode: Bool) async throws {
        if enabled { throw SessionBackendError.setupRequired }
    }
}

/// Explicit UI-preview backend. This never invokes a system power API or process.
@MainActor
public final class SimulatedSessionBackend: SessionBackend {
    public let isSimulated = true
    public private(set) var holdEnabled = false
    public private(set) var closedLidMode = true
    private let latency: Duration

    public init(latency: Duration = .milliseconds(250)) { self.latency = latency }
    public func prepare() async throws {}
    public func setHoldEnabled(_ enabled: Bool, closedLidMode: Bool) async throws {
        try await Task.sleep(for: latency)
        holdEnabled = enabled
        self.closedLidMode = closedLidMode
    }
}
