import AppKit
import Foundation
import VSCtl
import VMAppKit
import VMDiskImage
import VMProfile
import Virtualization
#if canImport(DiskImageKit)
import DiskImageKit
#endif

// MARK: - VMSession — M139a (#2779, index #2741): one VM's whole host side
//
// Before this card the runner's machine was a flat set of file-scope
// globals — one bus, one window, one serial log, one HostInt session, one
// ctl endpoint — so a second VM could not exist. A VMSession owns one
// machine's runtime: its VZVirtualMachine+queue, its HostCommandBus (the
// `vm=<n>` receipt word), its window, its serial plumbing and tee, its
// HostInt lane endpoints, and its vsock-ctl listener. The process-wide
// singletons (the `hostClipboard`/`hostDrop`/`hostNotify`/`hostOutbox`/
// `hostIntSession` globals) are now computed aliases onto the PRIMARY
// session's fields — the state lives here; the old names keep working
// for the one-VM boot path's hundreds of call sites.
//
// The primary session (id 1) is adopted around the already-built
// runner/bus by `VMSessionRegistry.adoptPrimary`; every later session is
// booted whole from a `.virelaivm` bundle by `new-window` — menu leaf or
// `--host-cmd-after <marker>:new-window@<path>` — through
// `openSession(at:)`, which builds the VMProfile-shaped device set
// (vars, base+overlay stack, virtio-fs share, NAT, vsock) rather than
// the flag zoo the primary boot resolves.

final class VMSession {
    /// The `vm=<n>` receipt word — 1 is the adopted primary.
    let id: Int
    /// The bus this session's windows, menus and triggers dispatch on —
    /// its `sessionID` is what stamps `vm=<n>` on every receipt.
    let commandBus = HostCommandBus()
    /// The profile this session boots (nil for a flag-run primary).
    var profile: VMProfile?
    /// The bundle path dedup key — standardized at set time.
    var profileURL: URL? { profile?.url }

    var runner: Runner?
    var vmDelegate: VMRunnerDelegate?
    /// Session 1's front door when --host-session is up (nil elsewhere).
    var hostApp: HostApplication?
    var window: NSWindow?
    var view: VZVirtualMachineView?
    var windowDelegate: SessionWindowDelegate?

    // Serial plumbing — the primary's pipes/handles stay globals; a
    // secondary owns its own duplex pair + tee.
    var serialURL: URL?
    var serialLogHandle: FileHandle?
    var consoleInputPipe: Pipe?
    var consoleOutputPipe: Pipe?
    var teeRunning = false
    var teeStopRequested = false
    let teeGroup = DispatchGroup()

    // Host-integration endpoints — what the process-wide globals used to
    // be. The aliases in main.swift forward the primary's five.
    var hostInt: HostIntSession?
    var clipboard: HostClipboard?
    var drop: HostDrop?
    var notify: HostNotify?
    var outbox: HostOutbox?

    // vsock-ctl — the listener+delegate are per socket device, per VM.
    var vsockCtlListener: VZVirtioSocketListener?
    var vsockCtlDelegate: VSockCtlListenerDelegate?
    var suspendCtl: SuspendCtl?
    var snapshotCtl: SnapshotCtl?
    var saveUnsupported: String?

    /// This session's drawer model — send-serial receipts read it.
    let inspector = HostInspector()
    /// The armed --host-cmd-after list (each session keeps its own copy —
    /// a marker in THIS serial stream fires on THIS session's bus).
    var triggers: [HostCommandTrigger] = []
    /// M139e (#2783): a secondary's trigger copy arms on its FIRST
    /// sessionPoll, not inside boot() — a `new-window` dispatch reaches
    /// boot() while fireHostCmdTriggers still holds its inout modify
    /// access on the shared hostCmdTriggers list, so reading the global
    /// in that stack is a dynamic exclusivity violation (observed:
    /// live-host-ui run 09, rc=134). The first poll runs after the
    /// dispatch returns — ahead of any serial marker landing — and the
    /// copy still carries each trigger's already-fired state, so an
    /// unbound trigger spent on vm 1 stays spent here.
    var triggersArmed = false
    var lastText = ""
    var vmDidStart = false
    var suspendStopInFlight = false
    /// The last new-window dispatch's receipt tail (opened=/reason=).
    var newWindowDetail: String?
    /// M157a (#2934): the last close dispatch's receipt tail
    /// (target=/reason=) — the cmd=close receipt's detail leg.
    var closeDetail: String?
    /// M157a: the stats line's model — configured halves armed at boot,
    /// live halves self-reading. HostStatsBar keeps the toolbar alive.
    let stats = HostStatsModel()
    var statsBar: HostStatsBar?
    /// M157a: the close policy's suspend driver — a test injects the
    /// wire verdict directly; nil falls back to `suspendCtl.begin()`.
    var closeSuspendDriver: (() -> SuspendVerdict)?
    var shotCount = 0

    /// Terminal state — stopped means the VM object reported .stopped/
    /// .error and the teardown ran; `stopping` means a stop is in flight.
    private(set) var stopped = false
    var stopping = false

    init(id: Int) {
        self.id = id
        commandBus.sessionID = id
    }

    func markStopped() {
        stopped = true
        stopping = false
    }

    /// M157a (#2934): the stats line's state word — the session's own
    /// stopping/stopped flags outrank the VZ state (a stopping window
    /// reads "stopping" until teardown lands).
    var statsState: String {
        if stopped { return "stopped" }
        if stopping { return "stopping" }
        guard let vm = runner?.vm else { return "starting" }
        switch vm.state {
        case .stopped: return "stopped"
        case .error: return "error"
        case .starting: return "starting"
        case .running: return "running"
        case .pausing: return "pausing"
        case .paused: return "paused"
        case .resuming: return "resuming"
        case .saving: return "saving"
        case .restoring: return "restoring"
        case .stopping: return "stopping"
        @unknown default: return "starting"
        }
    }
}

// MARK: - SessionWindowDelegate — a secondary window's close → its session's stop

final class SessionWindowDelegate: NSObject, NSWindowDelegate {
    weak var session: VMSession?
    init(session: VMSession) { self.session = session }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // M157a (#2934): the close is the profile's policy, not always a
        // stop — closeAction=suspend runs the save path first.
        if let s = session { VMSessionRegistry.shared.requestClose(s, reason: "window-close") }
        return false // the stopping state stays visible until VZ completes
    }
}

// MARK: - HostCommandRouter — the one process-global menu bar, N session buses
//
// The menu bar is AppKit-global but the buses are per-session. Every leaf
// targets this router instead of a bus; dispatch and validation resolve
// the key window's session (falling back to the primary), so ⌘⇧6 records
// the machine you are looking at and "New Window for Profile" works from
// any window. The selectors mirror HostCommandBus's menu seam verbatim.

final class HostCommandRouter: NSObject, NSMenuDelegate {
    /// The bus a dispatch lands on when no session window is key — the
    /// primary's (set by the runner right after adoptPrimary).
    var fallback: HostCommandBus?

    private func resolve() -> HostCommandBus {
        let registry = VMSessionRegistry.shared
        if let key = NSApp.keyWindow, let s = registry.session(forWindow: key) {
            return s.commandBus
        }
        return fallback ?? registry.primary?.commandBus ?? HostCommandRouter.bare
    }
    /// Last-resort bus for a dispatch arriving before adoptPrimary —
    /// a bare bus receipts `unavailable`, which is honest.
    private static let bare = HostCommandBus()

    @objc func dispatchItem(_ item: NSMenuItem) { resolve().dispatchItem(item) }
    @objc func dispatchSwitchItem(_ item: NSMenuItem) { resolve().dispatchSwitchItem(item) }
    @objc func dispatchNewWindowItem(_ item: NSMenuItem) { resolve().dispatchNewWindowItem(item) }
    @objc func menuNeedsUpdate(_ menu: NSMenu) { resolve().menuNeedsUpdate(menu) }
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { resolve().validateMenuItem(item) }
}

// MARK: - VMSessionRegistry — every live session, the dedup, the fleet stop

final class VMSessionRegistry {
    static let shared = VMSessionRegistry()
    let router = HostCommandRouter()

    private(set) var sessions: [VMSession] = []
    private var nextID = 1
    var primary: VMSession? { sessions.first }

    /// The refusal vocabulary `new-window` reports — the named refusals
    /// a receipt/assert greps.
    enum OpenRefusal: String, Error {
        case profileInUse = "profile_in_use"
        case invalidProfile = "profile_invalid"
        case noTarget = "no_target"
        case unsupported = "unsupported"
        case configFailed = "config_failed"
    }

    @discardableResult
    func mint() -> VMSession {
        let s = VMSession(id: nextID)
        nextID += 1
        sessions.append(s)
        return s
    }

    /// The class-A seam — tests mint/register sessions without a VM.
    func resetForTesting() {
        sessions.removeAll()
        busBridge.removeAll()
        nextID = 1
    }

    /// Wrap the already-running boot as session 1 — bus, runner, serial
    /// and profile were all built by the straight-line path; the session
    /// adopts them so the registry's lookups and the `vm=1` receipts
    /// cover it too.
    @discardableResult
    func adoptPrimary(commandBus: HostCommandBus, runner: Runner,
                      delegate: VMRunnerDelegate, serialURL: URL,
                      profile: VMProfile?) -> VMSession {
        let s = mint()
        s.runner = runner
        s.vmDelegate = delegate
        s.serialURL = serialURL
        s.profile = profile
        // The primary's bus is the straight-line path's (HostApplication's
        // in --host-session), not the session-owned one.
        busBridge[ObjectIdentifier(s)] = commandBus
        commandBus.sessionID = s.id
        router.fallback = commandBus
        installNewWindowVerb(on: commandBus, session: s)
        installCloseVerb(on: commandBus, session: s)
        commandBus.emit("host-ui: window vm=\(s.id) title=\(Self.windowTitle(profile: profile, sessionID: s.id))")
        return s
    }

    /// Sessions that own a bus other than their own (only the primary).
    private var busBridge: [ObjectIdentifier: HostCommandBus] = [:]

    func bus(for session: VMSession) -> HostCommandBus {
        busBridge[ObjectIdentifier(session)] ?? session.commandBus
    }

    func session(id: Int) -> VMSession? { sessions.first { $0.id == id } }

    func session(profileURL url: URL) -> VMSession? {
        let want = url.standardizedFileURL
        return sessions.first {
            !$0.stopped && $0.profileURL?.standardizedFileURL == want
        }
    }

    /// The session that owns this window — the router's key-window lookup.
    func session(forWindow window: NSWindow) -> VMSession? {
        sessions.first { !$0.stopped && $0.window === window }
            ?? sessions.first { !$0.stopped && $0.hostApp?.window === window }
    }

    /// The session that owns this lane object — HostIntCommands' dispatch
    /// lookup (a lane's start() registers its verbs on its OWN bus).
    func session(owning lane: AnyObject) -> VMSession? {
        sessions.first {
            ($0.clipboard.map { $0 === lane } ?? false)
                || ($0.drop.map { $0 === lane } ?? false)
                || ($0.notify.map { $0 === lane } ?? false)
                || ($0.outbox.map { $0 === lane } ?? false)
        }
    }

    /// Live sessions (not yet fully stopped) — the fleet the exit paths
    /// drain.
    var live: [VMSession] { sessions.filter { !$0.stopped } }

    /// The named duplicate check — the isEnabled half of the refusal.
    func canOpen(_ url: URL) -> OpenRefusal? {
        session(profileURL: url) != nil ? .profileInUse : nil
    }

    // MARK: new-window — the verb, on every session bus.

    /// Register `new-window` on a session's bus. The target is the
    /// profiles model's `newWindowTarget` — the menu leaf's identifier or
    /// the trigger's `@` operand — so the same registration serves menus,
    /// triggers and tests.
    func installNewWindowVerb(on bus: HostCommandBus, session: VMSession) {
        bus.profiles.sessionOpenCheck = { [weak self] url in
            self?.session(profileURL: url) != nil
        }
        bus.register(.newWindow, HostCommandBus.Registration(
            isEnabled: { [weak self, weak bus] in
                guard let self, let bus else { return false }
                if let target = bus.profiles.newWindowTarget {
                    return self.canOpen(target) == nil
                }
                return bus.profiles.canOpenWindow
            },
            receiptDetail: { [weak session, weak bus] in
                guard let session, let bus else { return "none" }
                if let t = bus.profiles.newWindowTarget,
                   VMSessionRegistry.shared.session(profileURL: t) != nil {
                    return "reason=profile_in_use profile=\(t.deletingPathExtension().lastPathComponent)"
                }
                return session.newWindowDetail ?? "none"
            },
            action: { [weak self, weak session, weak bus] in
                guard let self, let session, let bus else { return .failed }
                guard let target = bus.profiles.newWindowTarget else {
                    session.newWindowDetail = "reason=no_target"
                    return .failed
                }
                bus.profiles.newWindowTarget = nil
                switch self.openSession(at: target) {
                case .success(let s):
                    session.newWindowDetail =
                        "opened=\(s.id) profile=\(s.profile?.name ?? target.deletingPathExtension().lastPathComponent)"
                    return .performed
                case .failure(let refusal):
                    session.newWindowDetail =
                        "reason=\(refusal.rawValue) profile=\(target.deletingPathExtension().lastPathComponent)"
                    return .disabled
                }
            }))
    }

    // MARK: close — the host-automation verb + the window-close policy.

    /// The window-identity title — the primary's carries its profile
    /// name ("VirelaiOS — <name>", "VirelaiOS — default" without one);
    /// a sibling adds its vm= id so two live windows never share a name.
    static func windowTitle(profile: VMProfile?, sessionID: Int) -> String {
        if sessionID == 1 { return "VirelaiOS — \(profile?.name ?? "default")" }
        return "VirelaiOS — \(profile?.name ?? "session") (vm \(sessionID))"
    }

    /// The `close@vm=<k>` operand — "vm=2" or a bare id; nil on a
    /// foreign word (the named no_target refusal, not a guess).
    static func parseVMTarget(_ arg: String) -> Int? {
        let digits = arg.hasPrefix("vm=") ? String(arg.dropFirst(3)) : arg
        guard let n = Int(digits), n >= 1 else { return nil }
        return n
    }

    /// The VZErrorDomain "Code=<n>" the device set's
    /// validateSaveRestoreSupport verdict carries — the custom-virtio
    /// Code=2 class — else the driver's own wire word.
    static func saveRefusalCode(_ unsupported: String?, wire: String) -> String {
        if let u = unsupported,
           let r = u.range(of: "Code=([0-9]+)", options: .regularExpression) {
            return String(u[r].dropFirst("Code=".count))
        }
        return wire
    }

    /// Register `close` on a session's bus — `close@vm=<k>` runs THAT
    /// session's close policy through the registry. Staged like
    /// newWindowTarget: the trigger fire parses the `@` operand into
    /// bus.closeTargetVM ahead of the dispatch; a bare `close` receipts
    /// the named no_target refusal, a dead target names no_such_vm.
    func installCloseVerb(on bus: HostCommandBus, session: VMSession) {
        bus.register(.close, HostCommandBus.Registration(
            isEnabled: { [weak self, weak bus] in
                guard let self, let bus, let t = bus.closeTargetVM else { return false }
                return self.session(id: t).map { !$0.stopped && !$0.stopping } ?? false
            },
            receiptDetail: { [weak session, weak bus] in
                guard let session, let bus else { return "none" }
                // Still staged ⇒ the dispatch receipted disabled — name why.
                if let t = bus.closeTargetVM { return "reason=no_such_vm target=\(t)" }
                return session.closeDetail ?? "reason=no_target"
            },
            action: { [weak self, weak session, weak bus] in
                guard let self, let session, let bus, let t = bus.closeTargetVM else {
                    session?.closeDetail = "reason=no_target"
                    return .failed
                }
                bus.closeTargetVM = nil
                guard let target = self.session(id: t), !target.stopped, !target.stopping else {
                    session.closeDetail = "reason=no_such_vm target=\(t)"
                    return .disabled
                }
                session.closeDetail =
                    "target=\(t) action=\((target.profile?.config.closeAction ?? .stop).rawValue)"
                requestClose(target, reason: "close-verb")
                return .performed
            }))
    }

    /// M157a (#2934): the close policy — the profile's `closeAction`
    /// (absent = stop). `suspend` drives the same SuspendCtl save path
    /// the ctl suspend verb and the Machine menu use; a save-incapable
    /// device set (the custom-virtio Code=2 class) is refused BY NAME,
    /// the window shows the named message, and the VM stops anyway.
    /// The continuation is `--resume <bundle>` — bounded at
    /// VZErrorDomain Code=12 (M119e's named bound).
    func requestClose(_ s: VMSession, reason: String) {
        guard !s.stopped, !s.stopping else { return }
        if let app = s.hostApp {
            // The session-mode primary: the policy + named message live
            // in HostApplication (its suspend driver is the Machine
            // model's), and it terminates through its own lifecycle
            // stop rather than this registry's VM-only teardown.
            s.stopping = true
            app.requestClose(reason: reason)
            return
        }
        let bus = bus(for: s)
        switch s.profile?.config.closeAction ?? .stop {
        case .suspend:
            // Driver order: a test's injected verdict, the session's
            // own SuspendCtl (every secondary), then the Machine
            // model's injected driver (the primary's — armed in
            // main.swift for scripted and session runs alike).
            let verdict: SuspendVerdict
            if let driver = s.closeSuspendDriver {
                verdict = driver()
            } else if let ctl = s.suspendCtl {
                verdict = ctl.begin()
            } else if let wire = bus.machine.suspendDriver {
                verdict = wire().map { SuspendVerdict.refuse($0) } ?? .accept
            } else {
                verdict = .refuse("no_state")
            }
            if verdict.accepted {
                bus.emit("host-ui: close vm=\(s.id) action=suspend result=saved")
                s.suspendStopInFlight = true
                s.window?.subtitle = HostMachineModel.closeSavedMessage
                requestStop(s, reason: "close-suspend")
            } else {
                let code: String
                if let u = s.saveUnsupported, u.contains("Code=") {
                    code = Self.saveRefusalCode(u, wire: verdict.code)
                } else {
                    code = bus.machine.closeRefusalCode(verdict.code)
                }
                bus.emit("host-ui: close vm=\(s.id) action=suspend result=refused code=\(code)")
                s.window?.subtitle = HostMachineModel.closeRefusalMessage(code: code)
                requestStop(s, reason: "close-refused-\(code)")
            }
        case .stop:
            bus.emit("host-ui: close vm=\(s.id) action=stop result=stopped")
            requestStop(s, reason: reason)
        }
    }

    // MARK: Opening a secondary session.

    /// `new-window`'s whole job: load the bundle, dedup it by name, boot
    /// it with the profile-shaped device set, and register the session.
    /// Runs on the main queue (the dispatch's queue) — the VZ start is
    /// async; the config build is the synchronous part.
    func openSession(at url: URL) -> Result<VMSession, OpenRefusal> {
        let std = url.standardizedFileURL
        if session(profileURL: std) != nil { return .failure(.profileInUse) }
        guard let profile = try? VMProfile.load(from: std) else {
            return .failure(.invalidProfile)
        }
        let s = mint()
        s.profile = profile
        // M157a (#2934): the stats line's configured half — state and
        // uptime arm themselves (stateProvider reads live, startedAt
        // lands at startVM).
        s.stats.vcpus = profile.config.cpus
        s.stats.memoryMiB = profile.config.memoryMiB
        s.stats.stateProvider = { [weak s] in s?.statsState ?? "stopped" }
        do {
            try boot(s)
        } catch {
            sessions.removeAll { $0 === s }
            print("vm=\(s.id): open refused — \(error)")
            return .failure(.configFailed)
        }
        print("vm=\(s.id): opened profile=\(profile.name) bundle=\(std.path)")
        return .success(s)
    }

    /// Build + arm + start the machine — throws before anything live
    /// exists so a failed open leaves no half-session.
    private func boot(_ s: VMSession) throws {
        guard let p = s.profile else { return }

        // Serial plumbing: the bundle's run/serial.log, duplex pipes so
        // send-serial and the trigger scan work like the primary's.
        let runDir = p.url.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let serialURL = runDir.appendingPathComponent("serial.log")
        FileManager.default.createFile(atPath: serialURL.path, contents: nil)
        s.serialURL = serialURL
        s.serialLogHandle = try FileHandle(forWritingTo: serialURL)
        s.consoleInputPipe = Pipe()
        s.consoleOutputPipe = Pipe()
        let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialConfig.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: s.consoleInputPipe!.fileHandleForReading,
            fileHandleForWriting: s.consoleOutputPipe!.fileHandleForWriting)

        let config = try Self.buildConfiguration(profile: p, serial: serialConfig)
        var unsupported: String? = nil
        do { try config.validateSaveRestoreSupport() } catch {
            unsupported = "\(error as NSError)"
        }
        s.saveUnsupported = unsupported
        let runner = Runner(configuration: config)
        let delegate = VMRunnerDelegate()
        runner.vm.delegate = delegate
        s.runner = runner
        s.vmDelegate = delegate

        s.suspendCtl = SuspendCtl(vm: runner.vm, queue: runner.queue,
                                savedStateDir: p.savedStateURL, unsupported: unsupported)
        s.suspendCtl?.onFinish = { [weak self, weak s] in
            guard let self, let s else { return }
            s.suspendStopInFlight = true
            self.requestStop(s, reason: "suspend")
        }
        s.snapshotCtl = SnapshotCtl(
            vm: runner.vm, queue: runner.queue,
            shareDir: p.config.devices.share ? p.shareURL : nil,
            unsupported: unsupported)
        installSessionBus(s)
        armHostInt(s)
        makeWindow(s)
        startTee(s)
        runner.queue.async { [weak self, weak s] in
            self?.armSocketDevices(s)
            s?.startVM()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak s] in
            guard let self, let s else { return }
            self.sessionPoll(s)
        }
    }

    /// The profile-shaped device set — the M115c boot's honest subset:
    /// vars, machine id, base+overlay stack, data disk, entropy,
    /// display/input, NAT, vsock, virtio-fs share. No SPIKE custom-virtio
    /// (the share attaches through the save-capable standard transport —
    /// the --cvc-file shape is what validateSaveRestoreSupport refuses,
    /// and a windowed session suspends).
    static func buildConfiguration(
        profile p: VMProfile,
        serial serialConfig: VZVirtioConsoleDeviceSerialPortConfiguration
    ) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        let varsURL = p.efiVarsURL
        let store: VZEFIVariableStore
        if FileManager.default.fileExists(atPath: varsURL.path) {
            store = VZEFIVariableStore(url: varsURL)
        } else {
            store = try VZEFIVariableStore(creatingVariableStoreAt: varsURL, options: .allowOverwrite)
        }
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = store
        config.bootLoader = bootLoader
        config.memorySize = UInt64(p.config.memoryMiB) * 1024 * 1024
        config.cpuCount = p.config.cpus
        let platform = VZGenericPlatformConfiguration()
        if let data = p.machineIdentifierData(),
           let id = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = id
        } else {
            try p.setMachineIdentifier(platform.machineIdentifier.dataRepresentation)
        }
        config.platform = platform

        // Storage: read-only base + the bundle's persistent overlay —
        // the same DiskImageKit stack the primary's --profile boot uses.
        #if canImport(DiskImageKit)
        guard #available(macOS 27.0, *) else {
            throw NSError(domain: "VMSession", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "session storage requires macOS 27+ DiskImageKit"])
        }
        let baseURL = URL(fileURLWithPath: p.config.baseImage)
        let diskBase = try DiskImage(opening: .open(url: baseURL, mode: .readOnly))
        let overlayURL = p.overlayURL
        let stacked: any StackedImage
        if FileManager.default.fileExists(atPath: overlayURL.path) {
            let overlay = try DiskImage(opening: .open(url: overlayURL, mode: .readWrite))
            stacked = try diskBase.appending(overlay)
        } else {
            let layer = ASIFCreationConfiguration.layer(
                url: overlayURL, type: .overlay(blockCount: Int(diskBase.blockCount)))
            stacked = try diskBase.appending(layer)
        }
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(
            attachment: try VZDiskImageStorageDeviceAttachment(diskImage: stacked))]
        #else
        throw NSError(domain: "VMSession", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "binary built without DiskImageKit — cannot attach the profile's base+overlay stack"])
        #endif
        if p.config.devices.dataDisk {
            let prepared = try DataDisk.prepare(path: p.vlfsURL.path)
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: prepared.url, readOnly: false,
                cachingMode: .automatic, synchronizationMode: .full)
            let dataDisk = VZVirtioBlockDeviceConfiguration(attachment: attachment)
            dataDisk.blockDeviceIdentifier = DataDisk.vlfsIdentifier
            config.storageDevices.append(dataDisk)
        }
        config.serialPorts = [serialConfig]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        // M183b (#3172): the balloon attach is a runner flag, not a
        // profile-device field (VMProfile.Devices is outside this card's
        // Touches) — a `--balloon` argv arms it for sessions exactly as
        // it does the flag-runner path; off by default either way.
        if CommandLine.arguments.contains("--balloon")
            || CommandLine.arguments.contains("--balloon-target-after") {
            config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        }
        // The verb IS the window — a session always gets a scanout and
        // the view to show it; the profile's device flags gate input and
        // the optional channels.
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)]
        config.graphicsDevices = [graphics]
        if p.config.devices.input {
            config.keyboards = [VZUSBKeyboardConfiguration()]
            config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
        if p.config.devices.netNat {
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            config.networkDevices = [net]
        }
        if p.config.devices.vsock {
            config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        }
        if p.config.devices.share {
            try? FileManager.default.createDirectory(at: p.shareURL, withIntermediateDirectories: true)
            let fileSystem = VZVirtioFileSystemDeviceConfiguration(tag: "virelaios")
            fileSystem.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: p.shareURL, readOnly: false))
            config.directorySharingDevices = [fileSystem]
        }
        try config.validate()
        return config
    }

    // MARK: Per-session bus bindings — the headless verb set, per session.

    private func installSessionBus(_ s: VMSession) {
        let bus = s.commandBus
        guard let p = s.profile, let runner = s.runner else { return }
        bus.settings.profileURL = p.url
        bus.profiles.profileURL = p.url
        bus.machine.profileURL = p.url
        bus.captures.profileURL = p.url
        bus.machine.saveCapable = { [weak s] in s?.saveUnsupported == nil }
        bus.machine.vmRunning = { [weak s] in s?.runner?.vm.state == .running }
        bus.machine.suspendDriver = { [weak s] in
            guard let ctl = s?.suspendCtl else { return "no_state" }
            let verdict = ctl.begin()
            guard verdict.accepted else { return verdict.code }
            ctl.finish()
            return nil
        }
        bus.machine.snapshotDriver = { [weak s] name in
            guard let ctl = s?.snapshotCtl else { return "no_state" }
            let verdict = ctl.save(name: name)
            ctl.resumeAfterReply()
            return verdict.accepted ? nil : verdict.code
        }
        bus.register(.stop, HostCommandBus.Registration(
            isEnabled: { [weak s] in s.map { !$0.stopped } ?? false }
        ) { [weak self, weak s] in
            guard let self, let s else { return .failed }
            requestStop(s, reason: "menu-stop")
            return .performed
        })
        bus.register(.quit, HostCommandBus.Registration(
            isEnabled: { [weak s] in s.map { !$0.stopped } ?? false }
        ) { [weak self, weak s] in
            guard let self, let s else { return .failed }
            requestStop(s, reason: "menu-quit")
            return .performed
        })
        bus.register(.fullscreen, HostCommandBus.Registration(
            isEnabled: { [weak s] in s?.window?.isVisible ?? false },
            itemState: { [weak s] in s?.window?.styleMask.contains(.fullScreen) ?? false }
        ) { [weak s] in
            guard let w = s?.window else { return .failed }
            w.toggleFullScreen(nil)
            return .performed
        })
        bus.register(.captureKeys, HostCommandBus.Registration(
            isEnabled: { [weak s] in s?.view != nil },
            itemState: { [weak s] in s?.view?.capturesSystemKeys ?? false },
            receiptDetail: { [weak s] in
                guard let v = s?.view else { return nil }
                return "capture=\(v.capturesSystemKeys ? "on" : "off")"
            }
        ) { [weak s] in
            guard let v = s?.view else { return .failed }
            v.capturesSystemKeys.toggle()
            return .performed
        })
        bus.register(.screenshot, HostCommandBus.Registration(
            isEnabled: { [weak s] in s?.view != nil },
            receiptDetail: { [weak bus] in bus?.captures.receiptDetail }
        ) { [weak s, weak bus] in
            guard let s, let bus, let view = s.view,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return .failed }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return .failed }
            s.shotCount += 1
            let name = "vm\(s.id)-shot-\(s.shotCount).png"
            let dir = bus.captures.resolvedDir()
                ?? s.profile.map { $0.shareURL.appendingPathComponent("CAPTURES", isDirectory: true) }
            guard let dir else { return .disabled }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent(name).path
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { return .failed }
            bus.captures.noteSaved(URL(fileURLWithPath: path))
            return .performed
        })
        s.inspector.serialSink = { [weak s] line in
            guard let pipe = s?.consoleInputPipe else { return false }
            do {
                try pipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
                return true
            } catch { return false }
        }
        bus.register(.sendSerial, HostCommandBus.Registration(
            isEnabled: { [weak s] in s?.inspector.serialSink != nil },
            receiptDetail: { [weak s] in "sent=\(s?.inspector.sentCount ?? 0)" }
        ) { [weak s] in
            (s?.inspector.inject() ?? false) ? .performed : .failed
        })
        bus.register(.inspector, HostCommandBus.Registration(
            itemState: { [weak s] in s?.inspector.isOpen ?? false },
            receiptDetail: { [weak s] in s?.inspector.receiptDetail }
        ) { [weak s] in
            s?.inspector.isOpen.toggle()
            return .performed
        })
        installNewWindowVerb(on: bus, session: s)
        installCloseVerb(on: bus, session: s)
    }

    // MARK: HostInt lanes — the run's lane flags, per-session endpoints.

    /// Mirrors the primary's arming block (main.swift): one HostIntSession
    /// on THIS session's share, the flagged lanes on THIS session's bus.
    private func armHostInt(_ s: VMSession) {
        guard let p = s.profile, p.config.devices.share else { return }
        guard hostClipboardFlag || hostDropFlag || hostNotifyFlag || hostOutboxFlag else { return }
        var mask: UInt8 = 0
        var requested: [String] = []
        if hostClipboardFlag { mask |= HostInt.laneClip; requested.append("clip") }
        var dropWanted = false
        if hostDropFlag {
            requested.append("drop")
            mask |= HostInt.laneDrop // a session always has a window — the drop target exists
            dropWanted = true
        }
        if hostNotifyFlag { mask |= HostInt.laneNotify; requested.append("notify") }
        if hostOutboxFlag { mask |= HostInt.laneOutbox; requested.append("outbox") }
        guard mask != 0 else { return }
        s.hostInt = HostIntSession.arm(shareDir: p.shareURL, mask: mask, requested: requested)
        guard let session = s.hostInt else { return }
        if hostClipboardFlag {
            s.clipboard = HostClipboard(session: session, pasteboardName: hostPasteboardName)
            s.clipboard?.start()
        }
        if dropWanted {
            s.drop = HostDrop(session: session)
            s.drop?.start()
        }
        if hostNotifyFlag {
            s.notify = HostNotify(session: session)
            s.notify?.start()
        }
        if hostOutboxFlag {
            let dest = hostOutboxDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            s.outbox = HostOutbox(session: session, destDir: dest)
            s.outbox?.start()
        }
        if s.clipboard != nil || s.notify != nil || s.outbox != nil {
            DispatchQueue.main.async { [weak self, weak s] in
                guard let self, let s else { return }
                self.hostIntTick(s)
            }
        }
    }

    /// The 250 ms consume drain, per session — the primary's hostIntTick
    /// shape on this session's lanes.
    private func hostIntTick(_ s: VMSession) {
        s.clipboard?.tick()
        s.notify?.tick()
        s.outbox?.tick()
        guard !s.stopped else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak s] in
            guard let self, let s else { return }
            self.hostIntTick(s)
        }
    }

    // MARK: The window — every session gets one; that is the verb's point.

    private func makeWindow(_ s: VMSession) {
        guard let runner = s.runner else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.isReleasedWhenClosed = false
        let view = TraceView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        view.virtualMachine = runner.vm
        window.contentView = view
        window.title = Self.windowTitle(profile: s.profile, sessionID: s.id)
        // M157a (#2934): the stats line — the sibling's whole toolbar is
        // the lone stats item (the menu bar stays process-global).
        let statsBar = HostStatsBar(model: s.stats)
        let toolbar = NSToolbar(identifier: "virelai-session-\(s.id)")
        toolbar.delegate = statsBar
        window.toolbar = toolbar
        s.statsBar = statsBar
        window.acceptsMouseMovedEvents = true
        let delegate = SessionWindowDelegate(session: s)
        window.delegate = delegate
        s.windowDelegate = delegate
        if s.drop != nil {
            view.registerForDraggedTypes([.fileURL])
            view.dropHandler = { [weak s] urls in s?.drop?.drop(urls: urls) }
        }
        window.center()
        window.orderFrontRegardless()
        s.window = window
        s.view = view
        // M157a (#2934): the window-identity line — every VM window says
        // its own title on the host-ui stream once.
        s.commandBus.emit("host-ui: window vm=\(s.id) title=\(window.title)")
        // The bus's self-registered recorder films THIS window — record
        // on vm 1 and vm 2 are independent takes on independent views.
        s.commandBus.recorder.captureView = view
    }

    // MARK: Serial tee + trigger poll — per session, the primary's shapes.

    private func startTee(_ s: VMSession) {
        guard let output = s.consoleOutputPipe else { return }
        s.teeRunning = true
        s.teeGroup.enter()
        let queue = DispatchQueue(label: "virelaios.tee.vm\(s.id)")
        queue.async { [weak s] in
            defer { s?.teeGroup.leave() }
            let fh = output.fileHandleForReading
            let fd = fh.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var buf = [UInt8](repeating: 0, count: 4096)
            func drainPipe() {
                while true {
                    var n: Int
                    repeat { n = read(fd, &buf, buf.count) } while n < 0 && errno == EINTR
                    if n > 0 {
                        try? s?.serialLogHandle?.write(contentsOf: Data(bytes: buf, count: n))
                        continue
                    }
                    break
                }
            }
            while true {
                if s?.teeStopRequested == true {
                    drainPipe()
                    break
                }
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let pr = poll(&pfd, 1, 200)
                if pr < 0, errno == EINTR { continue }
                if pr > 0 {
                    if (pfd.revents & Int16(POLLIN)) != 0 { drainPipe() }
                    if (pfd.revents & Int16(POLLHUP | POLLERR)) != 0 {
                        drainPipe()
                        break
                    }
                }
            }
            try? s?.serialLogHandle?.synchronize()
        }
    }

    /// The marker-scan + end-of-VM watch for one session — the scripted
    /// poll's per-window twin. Triggers fire on THIS session's bus (the
    /// `vm<k>:` binding picks the session; an unbound trigger fires on
    /// whichever serial shows the marker).
    private func sessionPoll(_ s: VMSession) {
        if let url = s.serialURL,
           let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            s.lastText = text
        }
        if !s.triggersArmed {
            s.triggers = hostCmdTriggers
            s.triggersArmed = true
        }
        fireHostCmdTriggers(&s.triggers, on: bus(for: s), session: s.id, text: s.lastText)
        s.stats.refreshItem()
        if let vm = s.runner?.vm, s.vmDidStart,
           vm.state == .stopped || vm.state == .error, !s.stopped, !s.stopping {
            // An unattended end — the suspend teardown marks
            // suspendStopInFlight first; anything else is the machine
            // dying on its own and is reported, not hidden.
            print("vm=\(s.id): VM ended state=\(vm.state.rawValue)\(s.vmDelegate?.verdict() ?? "")")
            s.markStopped()
            DispatchQueue.main.async { [weak self, weak s] in
                guard let self, let s else { return }
                self.sessionStopped(s)
            }
            return
        }
        guard !s.stopped else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak s] in
            guard let self, let s else { return }
            self.sessionPoll(s)
        }
    }

    /// Bookkeeping on a session's end — the window goes dark, the live
    /// set shrinks; the process exit waits on the last one.
    private func sessionStopped(_ s: VMSession) {
        s.window?.orderOut(nil)
    }

    // MARK: Lifecycle — stop one session; drain them all at process exit.

    /// Stop one session's VM on its own queue, then mark + drain. Other
    /// sessions keep running — the "each stops on its own" half of the
    /// card.
    func requestStop(_ s: VMSession, reason: String) {
        guard !s.stopped, !s.stopping else { return }
        s.stopping = true
        print("vm=\(s.id): stopping reason=\(reason)")
        guard let runner = s.runner else {
            s.markStopped()
            DispatchQueue.main.async { [weak self] in self?.sessionStopped(s) }
            return
        }
        runner.queue.async { [weak self, weak s] in
            guard let self, let s else { return }
            let deadline = Date().addingTimeInterval(15)
            @Sendable func complete() {
                s.teeStopRequested = true
                _ = s.teeGroup.wait(timeout: .now() + 3)
                s.markStopped()
                print("vm=\(s.id): stopped state=\(runner.vm.state.rawValue)\(s.vmDelegate?.verdict() ?? "")")
                DispatchQueue.main.async { self.sessionStopped(s) }
            }
            @Sendable func step() {
                let vm = runner.vm
                if vm.state == .stopped || vm.state == .error {
                    complete()
                } else if vm.canStop {
                    vm.stop { _ in complete() }
                } else if Date() < deadline {
                    runner.queue.asyncAfter(deadline: .now() + 0.05) { step() }
                } else {
                    FileHandle.standardError.write(Data("vm=\(s.id): VM stop timed out\n".utf8))
                    complete()
                }
            }
            step()
        }
    }

    /// The exit-path drain: every non-primary session is asked to stop
    /// and the caller waits (bounded) for the fleet to go quiet — a
    /// scripted run's SUCCESS cannot tear a sibling VM down mid-flight.
    /// Safe on any queue: completions run on the sessions' own queues.
    func shutdownAllAndWait(timeout: TimeInterval = 15) {
        let secondaries = sessions.filter { $0.id != 1 && !$0.stopped }
        guard !secondaries.isEmpty else { return }
        for s in secondaries { requestStop(s, reason: "process-exit") }
        let deadline = Date().addingTimeInterval(timeout)
        while secondaries.contains(where: { !$0.stopped }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for s in secondaries where !s.stopped {
            FileHandle.standardError.write(Data("WARNING: vm=\(s.id) did not stop within \(Int(timeout))s at process exit\n".utf8))
        }
    }

    // MARK: vsock-ctl — the per-VM control endpoint.

    /// Arm the ctl listener on THIS session's socket device — the
    /// primary's M115b block shape, sourced from the session's own share
    /// credential and suspend/snapshot drivers.
    private func armSocketDevices(_ s: VMSession?) {
        guard let s, let p = s.profile, p.config.devices.vsock,
              let runner = s.runner,
              let socketDevice = runner.vm.socketDevices.first as? VZVirtioSocketDevice
        else { return }
        let listener = VZVirtioSocketListener()
        let shareDirs = p.config.devices.share ? [p.shareURL] : []
        guard let key = shareDirs.lazy
            .compactMap({ VSCtl.loadKey(shareDir: $0) }).first else {
            print("vm=\(s.id): VSOCK-CTL: refuse no_credential (no vsock-ctl row in the share's SECRETS.TXT)")
            return
        }
        let delegate = VSockCtlListenerDelegate(
            key: key,
            context: VSockCtlListenerDelegate.Context(
                vm: runner.vm, queue: runner.queue,
                shareDirs: shareDirs,
                savedStateDir: p.savedStateURL,
                unsupported: s.saveUnsupported,
                overlayBasePath: p.config.baseImage,
                profile: p),
            suspendHandler: { [weak s] in
                s?.suspendCtl?.begin() ?? .refuse("no_state")
            },
            onSuspendAccepted: { [weak s] in s?.suspendCtl?.finish() })
        listener.delegate = delegate
        socketDevice.setSocketListener(listener, forPort: VSCtl.defaultPort)
        s.vsockCtlListener = listener
        s.vsockCtlDelegate = delegate
        print("vm=\(s.id): VSOCK-CTL: host listener armed port=\(VSCtl.defaultPort) suspend=\(s.saveUnsupported != nil ? "unsupported" : "armed")")
    }
}

extension VMSession {
    /// `runner.vm.start` completion handling — marks the session live or
    /// reports the refusal by name.
    func startVM() {
        runner?.vm.start { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                print("vm=\(self.id): VM failed to start: \(error)")
                FileHandle.standardError.write(Data("ERROR: vm=\(self.id) failed to start: \(error)\n".utf8))
                self.markStopped()
                return
            }
            self.vmDidStart = true
            self.stats.startedAt = Date()
            print("vm=\(self.id): running")
        }
    }
}

// MARK: - The shared trigger fire — one implementation for every session

/// The M114a mirror, per session: scan `text` (this session's serial) for
/// armed triggers bound to this session (or unbound), dispatch them on
/// this session's bus. A `new-window` trigger's `@` operand is staged as
/// the profiles model's newWindowTarget before dispatch — the menu
/// leaf's identifier is the AppKit twin.
func fireHostCmdTriggers(_ triggers: inout [HostCommandTrigger],
                         on bus: HostCommandBus, session id: Int, text: String) {
    for i in triggers.indices {
        let t = triggers[i]
        guard !t.fired, t.session == nil || t.session == id,
              text.contains(t.marker) else { continue }
        triggers[i].fired = true
        if t.command == .newWindow, let arg = t.argument {
            bus.profiles.newWindowTarget = URL(fileURLWithPath: arg, isDirectory: true)
        }
        // M157a (#2934): `close@vm=<k>` stages its target like
        // new-window's `@` operand before the dispatch runs.
        if t.command == .close, let arg = t.argument {
            bus.closeTargetVM = VMSessionRegistry.parseVMTarget(arg)
        }
        bus.dispatch(t.command)
    }
}
