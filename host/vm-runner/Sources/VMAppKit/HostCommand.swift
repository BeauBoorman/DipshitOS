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
    // M128a (#2605): ⌘, toggles the machine settings panel — the bus's
    // `settings` companion (HostSettingsModel) edits the running
    // profile's VMProfile.Config. Self-registers in init like the
    // recorder/agent (argv resolution), so a profile-less run receipts
    // `disabled` from the action's enablement.
    case settings
    case quit
    // Machine menu.
    case stop
    // M120c (#2560): the persistence lifecycle verbs — suspend/snapshot
    // ride the M115d/e drivers the runner injects into `machine`;
    // apply-update/rollback-update run the M115f base-image swap;
    // reveal-share opens the armed share in Finder. The model
    // self-registers like the other companions, so a bare bus receipts
    // `disabled` from the verbs' own posture (save-capable? staged?
    // .prev? share?) and an unwired driver keeps the same answer.
    case suspend
    case snapshot
    case applyUpdate = "apply-update"
    case rollbackUpdate = "rollback-update"
    case revealShare = "reveal-share"
    // M128b (#2606): the profile manager's four verbs — the model
    // (HostProfilesModel) self-registers in init like the recorder/
    // agent/settings companions, so a profile-less run receipts
    // `disabled`/`unavailable` from the action's own enablement.
    case profileNew = "profile-new"
    case profileClone = "profile-clone"
    case profileResetOverlay = "profile-reset-overlay"
    case profileSwitch = "profile-switch"
    // View menu — M114b registers the handlers.
    case fullscreen
    case captureKeys = "capture-keys"
    // Integration menu — M114c registers the handlers.
    case laneClipboard = "lane-clipboard"
    case laneDrop = "lane-drop"
    case laneNotify = "lane-notify"
    // M127e (#2603, ADR 0051 v2): the agent-lane choke — pause/resume
    // the runner's --net-tcp-connect-stream endpoint. The bus's `agent`
    // companion registers it in init (the recorder precedent), so an
    // unarmed run receipts `unavailable` from the action itself.
    case laneAgent = "lane-agent"
    case sendFile = "send-file"
    // V2 lane verbs (ADR 0051 V2-D6) — declared once here; each lane's
    // own file registers its handler (a case with none reports
    // `unavailable`). M127d wires reveal-export + lane-outbox; M127c
    // wires notify-click; M127e wires lane-agent.
    case notifyClick = "notify-click"
    case revealExport = "reveal-export"
    case laneOutbox = "lane-outbox"
    // Debug menu — M114d/e register the remaining handlers.
    case inspector
    // M114d (#2457): the drawer injector's verb — no menu item of its
    // own; the drawer's Send button and `--host-cmd-after …:send-serial`
    // dispatch it, writing `HostInspector.inputLine` to the console pipe.
    case sendSerial = "send-serial"
    case screenshot
    // M114e (#2458): the ⌘⇧6 chord toggles `record`; `record-start`/
    // `record-stop` are the card's explicit leg verbs — same recorder,
    // idempotent edges, so a gate names the transition it wants rather
    // than counting dispatches.
    case record
    case recordStart = "record-start"
    case recordStop = "record-stop"
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
public final class HostCommandBus: NSObject, NSMenuDelegate {
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
        /// M114b (#2455): toggle verbs append their post-action state to
        /// the receipt (`state=performed capture=on`) so a gate asserting
        /// the receipt reads the real property, not just that the action
        /// ran. Read after every dispatch that found a registration —
        /// including `disabled`/`failed`, where the live state is still
        /// honest evidence. nil registration → nil detail → no suffix.
        public var receiptDetail: () -> String?
        public var action: () -> Outcome

        public init(isEnabled: @escaping () -> Bool = { true },
                    itemState: @escaping () -> Bool = { false },
                    receiptDetail: @escaping () -> String? = { nil },
                    action: @escaping () -> Outcome) {
            self.isEnabled = isEnabled
            self.itemState = itemState
            self.receiptDetail = receiptDetail
            self.action = action
        }
    }

    /// The receipt sink. The runner leaves the default — unbuffered
    /// stdout, the `host-clip:`/`host-drop:` line precedent — and tests
    /// capture it.
    public var emit: (String) -> Void

    /// M114e (#2458): the bounded MP4 recorder every bus carries — the
    /// one verb family whose handler needs nothing the runner owns: the
    /// capture surface is any AppKit view (the session attaches its guest
    /// view; a headless run's single evidence window is discovered
    /// through NSApp) and the output dir resolves from the runner's own
    /// `--cvc-file`/`--virtio-fs` argv. Self-registering on the bus is
    /// the M114c registration-side-effect pattern for a card whose
    /// Touches exclude main.swift: the bare `HostCommandBus()` a scripted
    /// `--host-cmd-after` run builds and the session window's bus
    /// dispatch the identical seam.
    public let recorder = HostRecorder()

    /// M120e (#2562): the capture destination + saved-badge model —
    /// where ⌘⇧5 and recordings land (`<share>/CAPTURES`, profile-share
    /// aware) and the transient "Saved <name>" truth the session window
    /// mirrors. Carried like the other companions so a scripted
    /// `--host-cmd-after` run resolves the identical seam; the runner's
    /// screenshot registration reads it for its destination and its
    /// `saved=/file=` receipt tail.
    public let captures = HostCaptures()

    /// M127e (#2603): the AGENTD companion — audit-lane reader + the
    /// `lane-agent` choke's model, self-registering on the bus like the
    /// recorder. Injectable so a test owns its argv/share/endpoint
    /// seams instead of the process's.
    public let agent: HostAgentCompanion

    /// M128a (#2605): the machine settings model — the `settings` verb's
    /// ⌘, panel state and the VMProfile.Config edit/save path, self-
    /// registering on the bus like the recorder/agent so a bare
    /// `HostCommandBus()` in a scripted `--host-cmd-after` run dispatches
    /// the identical seam. Injectable so a test owns its profile seam.
    public let settings: HostSettingsModel

    /// M128b (#2606): the profile manager model — the four `profile-*`
    /// verbs' mint/clone/reset/switch state, self-registering on the bus
    /// like the recorder/agent/settings so a bare `HostCommandBus()` in
    /// a scripted `--host-cmd-after` run dispatches the identical seam.
    /// Injectable so a test owns its profile/dir/confirm seams.
    public let profiles: HostProfilesModel

    /// M120c (#2560): the machine lifecycle model — the five persistence
    /// verbs' posture and actions, self-registering on the bus like the
    /// other companions. The runner injects its VZ drivers + posture
    /// reads (saveCapable/vmRunning/suspendDriver/snapshotDriver); the
    /// model resolves profile/share/base/key from argv itself, so a bare
    /// `HostCommandBus()` in a `--host-cmd-after` run dispatches the
    /// identical seam and a posture-less run receipts `disabled`.
    /// Injectable so a test owns its seams.
    public let machine: HostMachineModel

    private var registrations: [HostCommand: Registration] = [:]

    public init(emit: ((String) -> Void)? = nil, agent: HostAgentCompanion? = nil,
                settings: HostSettingsModel? = nil, profiles: HostProfilesModel? = nil,
                machine: HostMachineModel? = nil) {
        self.emit = emit ?? {
            FileHandle.standardOutput.write(Data(($0 + "\n").utf8))
        }
        self.agent = agent ?? HostAgentCompanion()
        self.agent.emit = self.emit
        self.settings = settings ?? HostSettingsModel()
        self.settings.emit = self.emit
        self.profiles = profiles ?? HostProfilesModel()
        self.profiles.emit = self.emit
        self.machine = machine ?? HostMachineModel()
        self.machine.emit = self.emit
        self.captures.emit = self.emit
        super.init()
        let recorder = self.recorder
        let captures = self.captures
        // M120e (#2562): the recorder shares the captures model's
        // destination (a profile-armed share resolves too) and reports
        // each finished take as a saved capture — the badge's other half.
        recorder.capturesSource = { captures.resolvedDir() }
        recorder.onSaved = { captures.noteSaved($0) }
        register(.record, Registration(
            isEnabled: { recorder.canStart },
            itemState: { recorder.isRecording },
            receiptDetail: { recorder.receiptDetail },
            action: { recorder.toggle() }))
        register(.recordStart, Registration(
            isEnabled: { recorder.canStart },
            itemState: { recorder.isRecording },
            receiptDetail: { recorder.receiptDetail },
            action: { recorder.start() }))
        register(.recordStop, Registration(
            isEnabled: { recorder.isRecording },
            itemState: { recorder.isRecording },
            receiptDetail: { recorder.receiptDetail },
            action: { recorder.stop() }))
        let agent = self.agent
        register(.laneAgent, Registration(
            itemState: { agent.laneFlowing },
            receiptDetail: { agent.receiptDetail },
            action: { agent.togglePause() }))
        // M128a (#2605): ⌘, — enabled only when a profile is armed
        // (`--profile`/`--resume` in argv or an injected profileURL); a
        // settings edit is a profile write, so a flag-run has nothing
        // for it and receipts `disabled`.
        let settings = self.settings
        register(.settings, Registration(
            isEnabled: { settings.armed },
            itemState: { settings.isOpen },
            receiptDetail: { settings.receiptDetail },
            action: { settings.toggle() }))
        // M128b (#2606): the profile manager verbs — the model's own
        // enablement gates each (armed for clone/reset/switch, a
        // resolvable profiles dir for new), and its receipt tail carries
        // the post-action truth.
        let profiles = self.profiles
        register(.profileNew, Registration(
            isEnabled: { profiles.canCreate },
            receiptDetail: { profiles.receiptDetail },
            action: { profiles.newProfile() }))
        register(.profileClone, Registration(
            isEnabled: { profiles.armed },
            receiptDetail: { profiles.receiptDetail },
            action: { profiles.cloneProfile() }))
        register(.profileResetOverlay, Registration(
            isEnabled: { profiles.armed },
            receiptDetail: { profiles.receiptDetail },
            action: { profiles.resetOverlay() }))
        register(.profileSwitch, Registration(
            isEnabled: { profiles.canSwitch },
            receiptDetail: { profiles.receiptDetail },
            action: { profiles.switchProfile() }))
        // M120c (#2560): the persistence lifecycle verbs — the model's
        // live posture gates each (save-capable + a destination for
        // suspend/snapshot, a staged set + pin for apply, a .prev for
        // rollback, a share for reveal), and its receipt tail carries
        // the post-action truth.
        let machine = self.machine
        register(.suspend, Registration(
            isEnabled: { machine.canSuspend },
            receiptDetail: { machine.suspendDetail },
            action: { machine.suspend() }))
        register(.snapshot, Registration(
            isEnabled: { machine.canSnapshot },
            receiptDetail: { machine.snapshotDetail },
            action: { machine.snapshot() }))
        register(.applyUpdate, Registration(
            isEnabled: { machine.canApplyUpdate },
            receiptDetail: { machine.applyUpdateDetail },
            action: { machine.applyUpdate() }))
        register(.rollbackUpdate, Registration(
            isEnabled: { machine.canRollbackUpdate },
            receiptDetail: { machine.rollbackUpdateDetail },
            action: { machine.rollbackUpdate() }))
        register(.revealShare, Registration(
            isEnabled: { machine.canRevealShare },
            receiptDetail: { machine.revealShareDetail },
            action: { machine.revealShare() }))
        // The companion's audit poll self-arms only when a share is
        // resolvable — a shareless run never schedules it (the flags-
        // off posture, host side).
        agent.startPolling()
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
        var detail: String?
        if let registration = registrations[command] {
            outcome = registration.isEnabled() ? registration.action() : .disabled
            detail = registration.receiptDetail()
        } else {
            outcome = .unavailable
        }
        emit("host-ui: cmd=\(command.rawValue) state=\(outcome.rawValue)\(detail.map { " \($0)" } ?? "")")
        return outcome
    }

    // MARK: Menu seam — the menu is a projection of the bus.

    @objc public func dispatchItem(_ item: NSMenuItem) {
        guard let command = item.representedObject as? HostCommand else { return }
        dispatch(command)
    }

    /// M128b (#2606): a "Switch To" submenu leaf carries the sibling
    /// bundle's path in its `identifier` — dispatch sets the model's
    /// target first so `profile-switch` acts on the item the user chose.
    @objc public func dispatchSwitchItem(_ item: NSMenuItem) {
        if let path = item.identifier?.rawValue {
            profiles.switchTarget = URL(fileURLWithPath: path, isDirectory: true)
        }
        dispatch(.profileSwitch)
    }

    /// M128b (#2606): the "Switch To" submenu rebuilds at every open —
    /// one leaf per sibling `.virelaivm` bundle, each dispatching
    /// `profile-switch` with its own path (the sibling set changes as
    /// new/clone mint and as the armed bundle trades places).
    @objc public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for target in profiles.switchTargets {
            let item = NSMenuItem(
                title: target.deletingPathExtension().lastPathComponent,
                action: #selector(dispatchSwitchItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = HostCommand.profileSwitch
            item.identifier = NSUserInterfaceItemIdentifier(target.path)
            menu.addItem(item)
        }
    }

    @objc public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = item.representedObject as? HostCommand else { return true }
        item.state = registrations[command]?.itemState() == true ? .on : .off
        return isEnabled(command)
    }
}
