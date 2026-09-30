import Foundation
import CaffeineHelperCore
import CaffeineLogging
import CaffeineServiceProtocol

final class HelperServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let authority: HelperSessionAuthority
    private let log: EventLog
    private let listener: NSXPCListener
    private enum Lifecycle { case inactive, active, stopped }
    private let lifecycleLock = NSLock()
    private var lifecycle = Lifecycle.inactive

    init(authority: HelperSessionAuthority, log: EventLog) {
        self.authority = authority
        self.log = log
        listener = NSXPCListener(machServiceName: CaffeineServiceIdentity.machService)
        super.init()
        listener.setConnectionCodeSigningRequirement(
            CaffeineServiceIdentity.signingRequirement(identifier: CaffeineServiceIdentity.appIdentifier)
        )
        listener.delegate = self
    }

    func activate() {
        lifecycleLock.withLock {
            guard lifecycle == .inactive else { return }
            lifecycle = .active
            listener.activate()
        }
    }

    func invalidate() {
        lifecycleLock.withLock {
            guard lifecycle != .stopped else { return }
            let wasInactive = lifecycle == .inactive
            lifecycle = .stopped
            // Balance initial inactivity before invalidation, while rejecting new peers.
            if wasInactive { listener.activate() }
            listener.invalidate()
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard lifecycleLock.withLock({ lifecycle == .active }) else {
            log.info(.connection, "Refused a connection from process \(connection.processIdentifier): the service is not accepting clients")
            return false
        }
        let connectionID = UUID()
        // The system has already verified the client's exact signing requirement.
        log.info(.connection, "Connection \(connectionID.uuidString.prefix(8)) opened by process \(connection.processIdentifier)")
        let endpoint = HelperEndpoint(authority: authority, connectionID: connectionID, log: log)
        connection.exportedInterface = NSXPCInterface(with: CaffeineHelperXPC.self)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { [authority] in
            endpoint.invalidate()
            Task {
                await authority.connectionInvalidated(connectionID)
            }
        }
        connection.interruptionHandler = { [authority] in
            endpoint.invalidate()
            Task {
                await authority.connectionInvalidated(connectionID)
            }
        }
        connection.resume()
        return true
    }
}

/// The exported endpoint has a bounded in-flight queue and a permanent invalidation bit.
/// This prevents a delayed task from reviving an already-disconnected owner.
private final class HelperEndpoint: NSObject, CaffeineHelperXPC, @unchecked Sendable {
    private let authority: HelperSessionAuthority
    private let connectionID: UUID
    private let log: EventLog
    private let lock = NSLock()
    private var invalidated = false
    private var pending = 0

    init(authority: HelperSessionAuthority, connectionID: UUID, log: EventLog) {
        self.authority = authority; self.connectionID = connectionID; self.log = log
    }

    func invalidate() { lock.withLock { invalidated = true } }

    func perform(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        let accepted = lock.withLock {
            guard !invalidated, pending < 16 else { return false }
            pending += 1
            return true
        }
        guard accepted else {
            log.error(.connection, "Connection \(connectionID.uuidString.prefix(8)): request refused, the connection is closed or has too many pending requests")
            reply(Self.encode(ServiceReply(snapshot: .init(phase: .unavailable),
                failure: .init(.unavailable, "The service connection is no longer available."))))
            return
        }
        guard data.count <= 8_192, let request = try? JSONDecoder().decode(ServiceRequest.self, from: data) else {
            log.error(.connection, "Connection \(connectionID.uuidString.prefix(8)): invalid request of \(data.count) bytes rejected")
            lock.withLock { pending -= 1 }
            reply(Self.encode(ServiceReply(snapshot: .init(phase: .unavailable),
                failure: .init(.invalidRequest, "The service request is invalid."))))
            return
        }
        let completion = ReplyBox(reply)
        Task { [self] in
            let response: ServiceReply
            if lock.withLock({ invalidated }) {
                response = ServiceReply(snapshot: .init(phase: .unavailable),
                    failure: .init(.unavailable, "The service connection was closed."))
            } else {
                response = await authority.handle(request, connectionID: connectionID)
            }
            lock.withLock { pending -= 1 }
            completion.send(Self.encode(response))
        }
    }

    private static func encode(_ reply: ServiceReply) -> Data {
        // No floating-point fields, so encoding cannot fail; an empty reply is a transport failure.
        (try? JSONEncoder().encode(reply)) ?? Data()
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let reply: (Data) -> Void
    init(_ reply: @escaping (Data) -> Void) { self.reply = reply }
    func send(_ data: Data) { reply(data) }
}
