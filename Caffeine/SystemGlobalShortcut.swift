import Carbon.HIToolbox
import Foundation

/// One hot key, registered with the window server. macOS delivers this key
/// combination and no other key press, so Caffeine needs no permission for it and
/// cannot read what the user types.
@MainActor
final class SystemGlobalShortcut: GlobalShortcutRegistering {
    struct Failure: LocalizedError, Equatable {
        let status: OSStatus
        var errorDescription: String? {
            status == OSStatus(eventHotKeyExistsErr)
                ? "Another app already uses this key combination (status \(status))."
                : "macOS refused the key combination (status \(status))."
        }
    }

    typealias Register = (_ keyCode: UInt32, _ modifiers: UInt32, _ identifier: EventHotKeyID,
                          _ reference: inout EventHotKeyRef?) -> OSStatus
    typealias Unregister = (EventHotKeyRef) -> OSStatus

    /// "CAFF". With the number it tells Caffeine's hot key from any other in this process.
    static let identifier = EventHotKeyID(signature: 0x4341_4646, id: 1)
    /// A press without a release is forgotten after this time, so that a lost
    /// release cannot switch the shortcut off for good.
    static let longestHold: EventTime = 3

    private let registerHotKey: Register
    private let unregisterHotKey: Unregister
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var action: (@MainActor () -> Void)?
    private var heldSince: EventTime?

    /// The two calls to the window server can be replaced, so that no key is registered.
    init(register: @escaping Register = { RegisterEventHotKey($0, $1, $2, GetEventDispatcherTarget(), 0, &$3) },
         unregister: @escaping Unregister = { UnregisterEventHotKey($0) }) {
        registerHotKey = register
        unregisterHotKey = unregister
    }

    isolated deinit { unregister() }

    func register(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) throws {
        unregister()
        let kinds = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        var status = InstallEventHandler(GetEventDispatcherTarget(), receiveHotKeyEvent, kinds.count, kinds,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            handler = nil
            throw Failure(status: status)
        }
        self.action = action
        status = registerHotKey(shortcut.keyCode, shortcut.modifiers.rawValue, Self.identifier, &hotKey)
        guard status == noErr else {
            hotKey = nil
            unregister()
            throw Failure(status: status)
        }
    }

    func unregister() {
        if let hotKey { _ = unregisterHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        action = nil
        heldSince = nil
    }

    /// False for a hot key that is not Caffeine's, which is left to other handlers.
    fileprivate func receive(kind: UInt32, identifier: EventHotKeyID, time: EventTime) -> Bool {
        guard identifier.signature == Self.identifier.signature, identifier.id == Self.identifier.id,
              let action else { return false }
        if kind == UInt32(kEventHotKeyReleased) {
            heldSince = nil
            return true
        }
        guard kind == UInt32(kEventHotKeyPressed) else { return false }
        // One press is one change, however long the keys are held.
        if let heldSince, time >= heldSince, time - heldSince < Self.longestHold {
            self.heldSince = time
            return true
        }
        heldSince = time
        action()
        return true
    }
}

/// Carbon calls this on the main thread, where the hot key was registered.
private nonisolated func receiveHotKeyEvent(_ call: EventHandlerCallRef?, _ event: EventRef?,
                                            _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context, Thread.isMainThread else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let kind = GetEventKind(event), time = GetEventTime(event)
    // The address crosses into the main actor; the object it names never leaves it.
    let address = UInt(bitPattern: context)
    let handled = MainActor.assumeIsolated {
        guard let owner = UnsafeRawPointer(bitPattern: address) else { return false }
        return Unmanaged<SystemGlobalShortcut>.fromOpaque(owner).takeUnretainedValue()
            .receive(kind: kind, identifier: identifier, time: time)
    }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
