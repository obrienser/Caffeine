import CaffeineLogging
import Foundation
import Observation

/// The shortcut that turns Keep awake on and off from every app. It does what a
/// click on the Keep awake row does and nothing more. The runtime owns it, because
/// the card is closed most of the time; the card only shows its hint.
@Observable @MainActor
final class KeepAwakeShortcut {
    /// The shortcut while macOS delivers it. The card shows no hint for one that does not work.
    private(set) var registered: GlobalShortcut?

    @ObservationIgnored private let shortcut = GlobalShortcut.keepAwake
    @ObservationIgnored private let session: any CaffeineSessionPresenting
    @ObservationIgnored private let registrar: (any GlobalShortcutRegistering)?
    @ObservationIgnored private let refuse: () -> Void
    @ObservationIgnored private let log: EventLog

    /// `refuse` tells the user that a press changed nothing. The card may be closed then.
    init(session: any CaffeineSessionPresenting, registrar: (any GlobalShortcutRegistering)?,
         refuse: @escaping () -> Void = {}, log: EventLog = .disabled) {
        self.session = session
        self.registrar = registrar
        self.refuse = refuse
        self.log = log
    }

    /// Registers the key combination. It never turns on Keep awake by itself.
    func start() {
        guard let registrar, registered == nil else { return }
        do {
            try registrar.register(shortcut) { [weak self] in self?.pressed() }
            registered = shortcut
            log.notice(.app, "The shortcut \(shortcut.title) for Keep awake is registered")
        } catch {
            log.error(.app, "The shortcut \(shortcut.title) for Keep awake is unavailable: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard registered != nil else { return }
        registered = nil
        registrar?.unregister()
        log.info(.app, "The shortcut \(shortcut.title) is released")
    }

    /// For the exported log. Empty where no key can be registered.
    var summary: String {
        guard registrar != nil else { return "" }
        return registered == nil ? "\(shortcut.title) is not registered" : "\(shortcut.title) turns Keep awake on and off"
    }

    func pressed() {
        // A press that macOS delivers after Quit began to release the key changes nothing.
        guard let registered else { return }
        let turnOn = !session.requested
        let status = session.statusTitle
        guard session.canToggleKeepAwake else {
            log.notice(.app, "User pressed \(registered.title), but Keep awake can’t change while the card shows “\(status)”")
            refuse()
            return
        }
        log.notice(.app, "User pressed \(registered.title) to turn Keep awake \(turnOn ? "on" : "off")")
        session.setKeepAwake(turnOn)
        // As with a click, a service that is not ready reads its status and starts nothing.
        guard session.requested != turnOn else { return }
        log.notice(.app, "The shortcut changed nothing: the card shows “\(status)”")
        refuse()
    }
}
