import AppKit

/// M114a (#2454, index #2447): the verbs of the HostCommand action bus —
/// the one seam every host-UI action dispatches through. Menu items and
/// the runner's `--host-cmd-after <marker>:<verb>` flag share the
/// dispatcher below, so every UI feature is exercisable headlessly and
/// AppKit is never driven by synthesized clicks (index thesis 1 — the
/// macOS activation walls of claims #151/#4769 refuse that from
/// background processes).
///
/// The raw value IS the wire verb: it is what `--host-cmd-after` parses
/// and what the `host-ui: cmd=<verb>` receipt prints, so it never
/// changes once published. Cases are declared for the menus the M114
/// index lays out; a verb with no registered handler reports
/// `unavailable` until its card wires it (later cards add verbs, not
/// menus).
public enum HostCommand: String, CaseIterable, Sendable {
    // VirelaiOS menu.
    case about
    case quit
    // Machine menu.
    case stop
    // View menu — M114b registers the handlers.
    case fullscreen
    case captureKeys = "capture-keys"
    // Integration menu — M114c registers the handlers.
    case laneClipboard = "lane-clipboard"
    case laneDrop = "lane-drop"
    case laneNotify = "lane-notify"
    case sendFile = "send-file"
    // Debug menu — M114d/e register the remaining handlers.
    case inspector
    case screenshot
    case record
}

/// One armed `--host-cmd-after <marker>:<verb>` instance. The verb is the
/// suffix after the LAST colon, so serial markers may carry colons of
/// their own (the `--host-write-after` precedent: guest markers do).
public struct HostCommandTrigger {
    public let marker: String
    public let command: HostCommand
    public var fired = false

    public init?(_ spec: String) {
        guard let colon = spec.lastIndex(of: ":"),
              let command = HostCommand(rawValue: String(spec[spec.index(after: colon)...]))
        else { return nil }
        let marker = String(spec[spec.startIndex..<colon])
        guard !marker.isEmpty else { return nil }
        self.marker = marker
        self.command = command
    }
}

/// The dispatcher. Every call arrives on the main queue (menu validation,
/// menu actions, and the runner's scripted/session polls all run there),
/// so the bus takes no lock.
///
/// One receipt per dispatch, always — even a verb that could not run, so
/// a gate asserting the receipt reads `disabled`/`unavailable` instead
/// of silence:
///
///     host-ui: cmd=<verb> state=<outcome>
public final class HostCommandBus: NSObject {
    /// The `state=<...>` word of a `host-ui:` receipt.
    public enum Outcome: String, Sendable {
        /// The action ran.
        case performed
        /// A handler is registered but refused at dispatch time (e.g.
        /// "Stop VM" while the session is already stopping).
        case disabled
        /// No handler is registered for the verb in this session — the
        /// menu item renders disabled for the same reason.
        case unavailable
        /// The action ran and reported failure.
        case failed
    }

    public struct Registration {
        /// Menu validation and dispatch both ask this live — a disabled
        /// verb stays on the menu, greyed, rather than disappearing.
        public var isEnabled: () -> Bool
        /// Toggle items (the M114c lane switches) read their checkmark
        /// state here during menu validation.
        public var itemState: () -> Bool
        public var action: () -> Outcome

        public init(isEnabled: @escaping () -> Bool = { true },
                    itemState: @escaping () -> Bool = { false },
                    action: @escaping () -> Outcome) {
            self.isEnabled = isEnabled
            self.itemState = itemState
            self.action = action
        }
    }

    /// The receipt sink. The runner leaves the default — unbuffered
    /// stdout, the `host-clip:`/`host-drop:` line precedent — and tests
    /// capture it.
    public var emit: (String) -> Void

    private var registrations: [HostCommand: Registration] = [:]

    public init(emit: ((String) -> Void)? = nil) {
        self.emit = emit ?? {
            FileHandle.standardOutput.write(Data(($0 + "\n").utf8))
        }
    }

    public func register(_ command: HostCommand, _ registration: Registration) {
        registrations[command] = registration
    }

    public func isRegistered(_ command: HostCommand) -> Bool {
        registrations[command] != nil
    }

    public func isEnabled(_ command: HostCommand) -> Bool {
        registrations[command]?.isEnabled() ?? false
    }

    @discardableResult
    public func dispatch(_ command: HostCommand) -> Outcome {
        let outcome: Outcome
        if let registration = registrations[command] {
            outcome = registration.isEnabled() ? registration.action() : .disabled
        } else {
            outcome = .unavailable
        }
        emit("host-ui: cmd=\(command.rawValue) state=\(outcome.rawValue)")
        return outcome
    }

    // MARK: Menu seam — the menu is a projection of the bus.

    @objc public func dispatchItem(_ item: NSMenuItem) {
        guard let command = item.representedObject as? HostCommand else { return }
        dispatch(command)
    }

    @objc public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = item.representedObject as? HostCommand else { return true }
        item.state = registrations[command]?.itemState() == true ? .on : .off
        return isEnabled(command)
    }
}
