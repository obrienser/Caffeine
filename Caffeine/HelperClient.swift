import Foundation
import CaffeineLogging
import CaffeineServiceProtocol

@MainActor
protocol HelperRequesting: AnyObject {
    var onDisconnect: ((Error) -> Void)? { get set }
    var isConnected: Bool { get }
    func request(_ request: ServiceRequest) async throws -> ServiceReply
    func invalidate()
}

/// The connection authenticates the exact helper before sending any session request.
/// All callbacks are delivered on the main actor.
@MainActor
final class HelperClient: HelperRequesting {
    enum Failure: Error, LocalizedError {
        case disconnected, timedOut, invalidReply
        case incompatibleVersion(serviceVersion: Int, canUpdate: Bool)
        case incompatibleBuild(serviceBuild: Int?, canUpdate: Bool)

        var isTransientConnectionFailure: Bool {
            switch self {
            case .disconnected, .timedOut: true
            default: false
            }
        }

        var serviceUpdateEligibility: Bool? {
            switch self {
            case .incompatibleVersion(_, let canUpdate), .incompatibleBuild(_, let canUpdate): canUpdate
            default: nil
            }
        }
        var errorDescription: String? {
            switch self {
            case .disconnected: "Caffeine couldn’t connect to its background service."
            case .timedOut: "Caffeine’s background service didn’t respond in time."
            case .invalidReply: "Caffeine received an invalid response from its background service."
            case .incompatibleBuild(let build, let canUpdate):
                if let build, build > CaffeineServiceIdentity.helperBuild {
                    "The background service is from a newer build of Caffeine. Install the latest complete app to reconnect."
                } else if canUpdate {
                    "Caffeine was updated, but an older background service build is still running. Update the service to reconnect."
                } else {
                    "The background service build needs an update, but its session and cleanup have not been confirmed complete. Check again after recovery finishes."
                }
            case .incompatibleVersion(let version, let canUpdate):
                if version > CaffeineServiceIdentity.protocolVersion {
                    "The background service is newer than this app. Install the latest complete Caffeine app to reconnect."
                } else if canUpdate {
                    "Caffeine was updated, but its background service is still using an older version. Update the service to reconnect."
                } else {
                    "The background service needs an update, but Caffeine couldn’t confirm that it has finished its session and cleanup. Stop any existing Caffeine session, then check again."
                }
            }
        }
    }

    var onDisconnect: ((Error) -> Void)?
    private let log: EventLog
    private let makeConnection: () -> NSXPCConnection
    private var connection: NSXPCConnection?
    private var connectionID = UUID()
    private struct Pending {
        let continuation: CheckedContinuation<ServiceReply, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [UUID: Pending] = [:]
    var isConnected: Bool { connection != nil }

    init(makeConnection: @escaping () -> NSXPCConnection = {
        NSXPCConnection(machServiceName: CaffeineServiceIdentity.machService, options: .privileged)
    }, log: EventLog = .disabled) {
        self.makeConnection = makeConnection
        self.log = log
    }

    func request(_ request: ServiceRequest) async throws -> ServiceReply {
        try await performRequest(JSONEncoder().encode(request))
    }

    private func performRequest(_ payload: Data) async throws -> ServiceReply {
        let connection = connect()
        let connectionID = self.connectionID
        let requestID = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { @MainActor [weak self] in
                do { try await SuspendingClock().sleep(for: .seconds(15)) }
                catch { return }
                self?.disconnect(connectionID: connectionID, error: Failure.timedOut, cause: "no reply within 15 s")
            }
            pending[requestID] = Pending(continuation: continuation, timeout: timeout)
            // XPC invokes these blocks on its own queue. Mark the entry points
            // Sendable so Swift does not assert MainActor isolation before the hop.
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
                // The system's reason, for example a rejected code signature.
                let cause = Self.describe(error)
                Task { @MainActor in
                    self?.disconnect(connectionID: connectionID, error: Failure.disconnected, cause: cause)
                }
            }
            guard let helper = proxy as? CaffeineHelperXPC else {
                disconnect(connectionID: connectionID, error: Failure.disconnected, cause: "the service interface is unavailable")
                return
            }
            helper.perform(payload) { @Sendable [weak self] data in
                Task { @MainActor in
                    guard let self, self.connectionID == connectionID else { return }
                    let reply: ServiceReply
                    do { reply = try Self.decodeReply(data) }
                    catch {
                        self.disconnect(connectionID: connectionID, error: error, cause: "a reply of \(data.count) bytes was not accepted")
                        return
                    }
                    guard let pending = self.pending.removeValue(forKey: requestID) else { return }
                    pending.timeout.cancel()
                    pending.continuation.resume(returning: reply)
                }
            }
        }
    }

    func invalidate() {
        disconnect(connectionID: connectionID, error: Failure.disconnected, cause: nil, notify: false)
    }

    nonisolated private static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code) – \(error.localizedDescription)"
    }

    static func decodeReply(_ data: Data) throws -> ServiceReply {
        // Check the envelope before decoding this version's required snapshot fields.
        // An older helper must produce a version diagnostic, not a malformed-data error.
        struct Envelope: Decodable { let version: Int }
        guard data.count <= 65_536,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw Failure.invalidReply
        }
        guard envelope.version == CaffeineServiceIdentity.protocolVersion else {
            // Only an older helper that reports no session and no pending cleanup may
            // be replaced. A snapshot this app can't read never allows it.
            struct OlderReply: Decodable {
                struct Snapshot: Decodable {
                    let phase: ServicePhase
                    let readyForSession: Bool
                    let requested: Bool
                }
                let snapshot: Snapshot
            }
            let snapshot = envelope.version < CaffeineServiceIdentity.protocolVersion
                ? (try? JSONDecoder().decode(OlderReply.self, from: data))?.snapshot : nil
            let settledPhases: Set<ServicePhase> = [.off, .externalOverride, .unavailable]
            let canUpdate = snapshot.map {
                $0.readyForSession && !$0.requested && settledPhases.contains($0.phase)
            } ?? false
            throw Failure.incompatibleVersion(serviceVersion: envelope.version, canUpdate: canUpdate)
        }
        guard let reply = try? JSONDecoder().decode(ServiceReply.self, from: data) else {
            throw Failure.invalidReply
        }
        if let build = reply.helperBuild, build <= 0 { throw Failure.invalidReply }
        guard reply.helperBuild == CaffeineServiceIdentity.helperBuild else {
            let older = reply.helperBuild.map { $0 < CaffeineServiceIdentity.helperBuild } ?? true
            throw Failure.incompatibleBuild(serviceBuild: reply.helperBuild,
                                            canUpdate: older && reply.snapshot.isSettled)
        }
        return reply
    }

    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let connection = makeConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: CaffeineHelperXPC.self)
        connection.setCodeSigningRequirement(CaffeineServiceIdentity.signingRequirement(identifier: CaffeineServiceIdentity.helperIdentifier))
        let id = UUID()
        connectionID = id
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.disconnect(connectionID: id, error: Failure.disconnected, cause: "the connection was invalidated") }
        }
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.disconnect(connectionID: id, error: Failure.disconnected, cause: "the service stopped or restarted") }
        }
        self.connection = connection
        log.info(.service, "Connecting to the background service; its exact signature is required")
        connection.resume()
        return connection
    }

    /// `cause` is nil when the app itself closes the connection.
    private func disconnect(connectionID id: UUID, error: Error, cause: String?, notify: Bool = true) {
        guard connectionID == id else { return }
        connectionID = UUID()
        let oldConnection = connection
        connection = nil
        let abandoned = pending.values
        pending.removeAll()
        if let cause {
            log.error(.service, "Connection closed: \(cause); \(abandoned.count) request(s) abandoned; reported as: \(error.localizedDescription)")
        } else if oldConnection != nil {
            log.info(.service, "Connection closed by Caffeine")
        }
        oldConnection?.invalidate()
        for item in abandoned {
            item.timeout.cancel()
            item.continuation.resume(throwing: error)
        }
        if notify { onDisconnect?(error) }
    }
}
