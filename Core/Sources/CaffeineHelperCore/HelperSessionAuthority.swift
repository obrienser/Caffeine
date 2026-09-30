import Foundation
import CaffeineLogging
import CaffeineServiceProtocol

/// The sole serialized owner of system/display holds and optional closed-lid support.
/// Errors may represent a partially completed enable; disable must be idempotent.
public protocol RuntimeSleepBackend: Sendable {
    func recover() async throws
    func enable(closedLidMode: Bool) async throws
    func disable() async throws
}

public struct HelperTimeSource: Sendable {
    public let continuousSeconds: @Sendable () -> TimeInterval
    public let awakeSeconds: @Sendable () -> TimeInterval

    public init(continuousSeconds: @escaping @Sendable () -> TimeInterval,
                awakeSeconds: @escaping @Sendable () -> TimeInterval) {
        self.continuousSeconds = continuousSeconds
        self.awakeSeconds = awakeSeconds
    }

    public static var system: Self {
        let continuous = ContinuousClock(), awake = SuspendingClock()
        let continuousOrigin = continuous.now, awakeOrigin = awake.now
        return Self(continuousSeconds: {
            seconds(continuousOrigin.duration(to: continuous.now))
        }, awakeSeconds: {
            seconds(awakeOrigin.duration(to: awake.now))
        })
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}

/// No caller may invoke the backend directly. The actor accepts newer intentions
/// while I/O is suspended, but one reconciliation loop executes every backend call.
public actor HelperSessionAuthority {
    private struct Session {
        let connection: UUID
        let generation: UUID
        var revision: UInt64
        var onlyWhenCharging: Bool
        var closedLidMode: Bool
        var duration: Int
        var deadline: TimeInterval?
        var lastHeartbeat: TimeInterval
    }

    private enum Operation { case recovery, enable, disable }
    private enum EndReason: String {
        case stopRequested = "stop requested", deadline = "timer expired", lease = "supervision lease expired"
        case disconnected = "owner disconnected", activationFailed = "activation failed", shutdown = "service stopping"
    }
    private let backend: any RuntimeSleepBackend
    private let log: EventLog
    private let time: HelperTimeSource
    private let leaseDuration: TimeInterval
    private var session: Session?
    private var lastSession: Session?
    private var highWater: [UUID: UInt64] = [:]
    private var lastStops: [UUID: (generation: UUID?, revision: UInt64)] = [:]
    private var retiredGenerations: Set<UUID> = []
    private var invalidatedConnections: Set<UUID> = []
    private var power: ServicePowerSource = .unknown
    private var isSleeping = false
    private var freshOwnerRequired = false
    private var shuttingDown = false
    private var recoveryPending = true
    private var ready = false
    private var possiblyHeld = false
    private var held = false
    private var heldClosedLidMode: Bool?
    private var cleanupBlocked = false
    private var failure: ServiceFailure?
    private var operation: Operation?
    private var reconciling = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(backend: any RuntimeSleepBackend, timeSource: HelperTimeSource = .system,
                leaseDuration: TimeInterval = 20, log: EventLog = .disabled) {
        self.backend = backend
        self.log = log
        self.time = timeSource
        self.leaseDuration = leaseDuration
    }

    /// Call before accepting clients. A subsequent call retries failed startup
    /// recovery only when no live session exists; it never restores a session.
    public func prepare() async {
        if session == nil && !ready {
            recoveryPending = true
            cleanupBlocked = false
        }
        await reconcile()
    }

    public func handle(_ request: ServiceRequest, connectionID: UUID) async -> ServiceReply {
        let origin = "\(request.action.rawValue) from connection \(Self.short(connectionID))"
        guard request.version == CaffeineServiceIdentity.protocolVersion else {
            log.error(.helper, "Rejected \(origin): protocol \(request.version), this service uses \(CaffeineServiceIdentity.protocolVersion)")
            return reply(.init(.incompatibleVersion, "This version of Caffeine cannot use the installed service."))
        }
        guard !invalidatedConnections.contains(connectionID) else {
            log.info(.helper, "Rejected \(origin): the connection has ended")
            return reply(.init(.notOwner, "This connection has ended."))
        }
        if request.action == .status {
            await reconcile()
            let result = reply()
            log.debug(.helper, "Answered \(origin): \(Self.describe(result))")
            return result
        }
        expireIfNecessary()
        // A renewal arrives every few seconds; only its problems are worth keeping.
        let routine = request.action == .heartbeat
        if let error = apply(request, connection: connectionID) {
            log.log(routine ? .info : .error, .helper,
                    "Rejected \(origin), revision \(request.revision): \(error.code.rawValue) – \(error.message)")
            // Even a rejected request must not delay cleanup of an expired owner.
            await reconcile()
            return reply(error)
        }
        log.log(routine ? .debug : .notice, .helper, "Accepted \(origin), revision \(request.revision), "
            + "session \(Self.short(request.generation))\(Self.describe(request))")
        await reconcile()
        let result = reply()
        log.log(routine ? .debug : .notice, .helper, "Answered \(origin): \(Self.describe(result))")
        return result
    }

    public func connectionInvalidated(_ connectionID: UUID) async {
        invalidatedConnections.insert(connectionID)
        log.info(.connection, "Connection \(Self.short(connectionID)) ended")
        if session?.connection == connectionID { retireSession(.disconnected) }
        await reconcile()
    }

    public func powerSourceChanged(_ source: ServicePowerSource) async {
        if power != source { log.info(.power, "Power source: \(power.rawValue) → \(source.rawValue)") }
        power = source
        await reconcile()
    }

    public func tick() async { await reconcile() }

    public func systemWillSleep() async {
        log.info(.power, "The system is going to sleep; \(session == nil ? "no session" : "the session waits for a fresh owner")")
        isSleeping = true
        freshOwnerRequired = session != nil
        await reconcile()
    }

    public func systemDidWake() async {
        log.info(.power, "The system woke")
        isSleeping = false
        freshOwnerRequired = session != nil
        // The charger may have changed while asleep. A fresh owner heartbeat
        // must not make a cached pre-sleep AC observation eligible again.
        power = .unknown
        await reconcile()
    }

    public func shutdown() async {
        if !shuttingDown { log.notice(.helper, "The service is stopping; any hold is released first") }
        shuttingDown = true
        retireSession(.shutdown)
        cleanupBlocked = false
        await reconcile()
        log.flush()
    }

    /// Ends service so launchd can start a replaced helper. Refused unless every
    /// session, hold and cleanup is settled; once accepted, no session can start.
    public func retireIfSettled() async -> Bool {
        // An expired owner is cleaned up first; the decision below cannot be interleaved.
        await reconcile()
        guard !shuttingDown, makeSnapshot().isSettled else {
            log.debug(.helper, "Retirement deferred: \(Self.describe(makeSnapshot()))")
            return false
        }
        shuttingDown = true
        log.notice(.helper, "Retiring: the executable was replaced and the service is settled")
        return true
    }

    public func snapshot() -> ServiceSnapshot { makeSnapshot() }

    private func apply(_ request: ServiceRequest, connection: UUID) -> ServiceFailure? {
        if request.action == .stop {
            return applyStop(request, connection: connection)
        }
        guard !shuttingDown else { return .init(.unavailable, "Caffeine's service is stopping.") }
        guard ready && !cleanupBlocked && !recoveryPending else {
            return failure ?? .init(.unavailable, "Caffeine's service is not ready.")
        }
        guard let generation = request.generation else {
            return .init(.invalidRequest, "The session identifier is missing.")
        }
        guard request.revision > (highWater[connection] ?? 0) else {
            return .init(.staleRevision, "This session request has already been superseded.")
        }
        if request.action == .start {
            guard !retiredGenerations.contains(generation) else {
                return .init(.staleRevision, "This session has already ended.")
            }
            guard session == nil && !possiblyHeld && operation == nil else {
                return .init(.busy, "Another session is already being handled.")
            }
            guard let duration = request.durationSeconds,
                  CaffeineServiceIdentity.allowedDurations.contains(duration),
                  let onlyWhenCharging = request.onlyWhenCharging,
                  let closedLidMode = request.closedLidMode else {
                return .init(.invalidRequest, "Choose one of Caffeine's supported timer intervals.")
            }
            highWater[connection] = request.revision
            failure = nil
            freshOwnerRequired = false
            session = Session(connection: connection, generation: generation, revision: request.revision,
                              onlyWhenCharging: onlyWhenCharging, closedLidMode: closedLidMode, duration: duration,
                              deadline: duration == 0 ? nil : time.continuousSeconds() + Double(duration),
                              lastHeartbeat: time.awakeSeconds())
            return nil
        }
        guard var current = session, current.connection == connection, current.generation == generation else {
            return .init(.notOwner, "This connection does not own the requested session.")
        }
        if request.action == .update {
            guard let duration = request.durationSeconds,
                  CaffeineServiceIdentity.allowedDurations.contains(duration),
                  let onlyWhenCharging = request.onlyWhenCharging,
                  let closedLidMode = request.closedLidMode else {
                return .init(.invalidRequest, "Choose one of Caffeine's supported timer intervals.")
            }
            if duration != current.duration {
                current.duration = duration
                current.deadline = duration == 0 ? nil : time.continuousSeconds() + Double(duration)
            }
            current.onlyWhenCharging = onlyWhenCharging
            current.closedLidMode = closedLidMode
        }
        highWater[connection] = request.revision
        current.revision = request.revision
        current.lastHeartbeat = time.awakeSeconds()
        session = current
        freshOwnerRequired = false
        return nil
    }

    private func applyStop(_ request: ServiceRequest, connection: UUID) -> ServiceFailure? {
        if let current = session {
            guard current.connection == connection, request.generation == current.generation else {
                return .init(.notOwner, "This connection cannot stop another session.")
            }
        } else if possiblyHeld || cleanupBlocked {
            if let owner = lastSession, owner.connection != connection,
               !invalidatedConnections.contains(owner.connection) {
                return .init(.notOwner, "Another connection is still responsible for this operation.")
            }
        }
        let previous = highWater[connection] ?? 0
        if request.revision <= previous {
            // A retried Stop is safe after its generation has been retired. It
            // still retries failed cleanup but cannot stop a newer session.
            guard session == nil, let stop = lastStops[connection],
                  stop.generation == request.generation, stop.revision == request.revision,
                  stop.revision == previous else {
                return .init(.staleRevision, "This stop request has already been superseded.")
            }
        } else {
            highWater[connection] = request.revision
        }
        lastStops[connection] = (request.generation, request.revision)
        if let generation = request.generation { retiredGenerations.insert(generation) }
        if var current = session {
            current.revision = request.revision
            session = current
            retireSession(.stopRequested)
        }
        failure = nil
        cleanupBlocked = false
        if !ready { recoveryPending = true }
        return nil
    }

    private func retireSession(_ reason: EndReason) {
        if let session {
            retiredGenerations.insert(session.generation)
            lastSession = session
            log.notice(.helper, "Session \(Self.short(session.generation)) ended: \(reason.rawValue)")
        }
        session = nil
        freshOwnerRequired = false
    }

    private func expireIfNecessary() {
        guard let current = session else { return }
        if let deadline = current.deadline, time.continuousSeconds() >= deadline {
            retireSession(.deadline)
        } else if time.awakeSeconds() - current.lastHeartbeat >= leaseDuration {
            retireSession(.lease)
        }
    }

    private var shouldHold: Bool {
        guard let session, !isSleeping, !freshOwnerRequired else { return false }
        return !session.onlyWhenCharging || power == .external
    }

    private func reconcile() async {
        if reconciling {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        reconciling = true
        defer {
            reconciling = false
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
        while true {
            expireIfNecessary()
            if cleanupBlocked { return }
            if recoveryPending {
                recoveryPending = false
                operation = .recovery
                log.info(.recovery, "Recovery started")
                do {
                    try await backend.recover()
                    ready = true
                    possiblyHeld = false
                    held = false
                    failure = nil
                    log.notice(.recovery, "Recovery finished; the service is ready and holds nothing")
                } catch {
                    ready = false
                    cleanupBlocked = true
                    failure = classified(error, fallback: .cleanupRequired)
                    log.error(.recovery, "Recovery failed; sessions are blocked: \(Self.describe(failure))")
                }
                operation = nil
                continue
            }
            guard ready else { return }
            if !shouldHold && possiblyHeld {
                operation = .disable
                log.info(.power, "Releasing the hold")
                do {
                    try await backend.disable()
                    held = false
                    possiblyHeld = false
                    log.notice(.power, "The hold is released and verified")
                    // Enable can report an ambiguous partial write. Once its
                    // cleanup is verified, retain the activation diagnostic
                    // without claiming that restoration is still unresolved.
                    if let failure, failure.code == .cleanupRequired {
                        self.failure = .init(.unavailable, failure.message)
                    }
                } catch {
                    held = false
                    cleanupBlocked = true
                    failure = .init(.cleanupRequired, error.localizedDescription)
                    log.error(.power, "Releasing the hold failed; cleanup is unresolved: \(error.localizedDescription)")
                }
                operation = nil
                continue
            }
            if shouldHold, let closedLidMode = session?.closedLidMode,
               !held || heldClosedLidMode != closedLidMode {
                let generation = session?.generation
                possiblyHeld = true
                operation = .enable
                log.info(.power, "Applying the hold for session \(Self.short(generation)), Closed Lid Mode \(closedLidMode ? "on" : "off")")
                do {
                    try await backend.enable(closedLidMode: closedLidMode)
                    held = true
                    heldClosedLidMode = closedLidMode
                    log.notice(.power, "The hold is active and verified, Closed Lid Mode \(closedLidMode ? "on" : "off")")
                } catch {
                    log.error(.power, "Applying the hold failed: \(Self.describe(classified(error, fallback: .unavailable)))")
                    expireIfNecessary()
                    // A cancelled/expired start still requires cleanup, but its
                    // late error is not reported as a failure.
                    if session?.generation == generation, session != nil {
                        failure = classified(error, fallback: .unavailable)
                        retireSession(.activationFailed)
                    }
                    held = false
                }
                operation = nil
                continue
            }
            return
        }
    }

    private func classified(_ error: Error, fallback: ServiceFailureCode) -> ServiceFailure {
        (error as? ServiceFailure) ?? .init(fallback, error.localizedDescription)
    }

    private func makeSnapshot() -> ServiceSnapshot {
        let current = session ?? lastSession
        let phase: ServicePhase
        if cleanupBlocked || failure?.code == .cleanupRequired { phase = .cleanupRequired }
        else if operation == .disable { phase = .stopping }
        else if operation == .recovery { phase = .stopping }
        else if operation == .enable { phase = .starting }
        else if let failure {
            phase = failure.code == .externalOverride ? .externalOverride : .unavailable
        } else if let session {
            if held { phase = .active }
            else if session.onlyWhenCharging && power == .unknown { phase = .powerSourceUnavailable }
            else { phase = .waitingForPower }
        } else if possiblyHeld { phase = .stopping }
        else { phase = ready ? .off : .unavailable }
        let remaining = session?.deadline.map { max(0, Int(ceil($0 - time.continuousSeconds()))) }
        let message: String?
        if freshOwnerRequired && session != nil { message = "Waiting for Caffeine to reconnect after wake." }
        else { message = failure?.message }
        let readyForSession = ready && !shuttingDown && session == nil && !possiblyHeld
            && !cleanupBlocked && !recoveryPending && operation == nil
        return ServiceSnapshot(phase: phase, readyForSession: readyForSession, requested: session != nil,
                               generation: current?.generation, revision: current?.revision ?? 0,
                               onlyWhenCharging: current?.onlyWhenCharging ?? false,
                               closedLidMode: current?.closedLidMode ?? true,
                               durationSeconds: current?.duration ?? 0, remainingSeconds: remaining,
                               powerSource: power, message: message)
    }

    private func reply(_ requestFailure: ServiceFailure? = nil) -> ServiceReply {
        ServiceReply(snapshot: makeSnapshot(), failure: requestFailure ?? failure)
    }

    private static func short(_ identifier: UUID?) -> String {
        identifier.map { String($0.uuidString.prefix(8)) } ?? "none"
    }

    private static func describe(_ request: ServiceRequest) -> String {
        guard request.action == .start || request.action == .update else { return "" }
        return ", timer \(request.durationSeconds.map { $0 == 0 ? "none" : "\($0) s" } ?? "missing")"
            + ", only when charging \(request.onlyWhenCharging.map { $0 ? "on" : "off" } ?? "missing")"
            + ", Closed Lid Mode \(request.closedLidMode.map { $0 ? "on" : "off" } ?? "missing")"
    }

    private static func describe(_ failure: ServiceFailure?) -> String {
        failure.map { "\($0.code.rawValue) – \($0.message)" } ?? "no failure"
    }

    private static func describe(_ snapshot: ServiceSnapshot) -> String {
        "phase \(snapshot.phase.rawValue), \(snapshot.requested ? "session \(short(snapshot.generation))" : "no session")"
            + ", ready \(snapshot.readyForSession ? "yes" : "no"), power \(snapshot.powerSource.rawValue)"
            + (snapshot.remainingSeconds.map { ", \($0) s left" } ?? "")
    }

    private static func describe(_ reply: ServiceReply) -> String {
        describe(reply.snapshot) + (reply.failure.map { ", failure \(describe($0))" } ?? "")
    }
}
