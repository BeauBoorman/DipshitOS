import AppKit

/// M114b (#2455): the minimal surface the `capture-keys` verb needs — the
/// attached machine view's `capturesSystemKeys` property. The runner's
/// TraceView (a VZVirtualMachineView) conforms retroactively in main.swift,
/// which already imports Virtualization; VMAppKit itself stays
/// Virtualization-free because loading that framework into the test runner
/// poisons NSEvent monitors (observed: NativeInputTests' posted
/// .applicationDefined event was never delivered once Virtualization's
/// private HID dependencies loaded).
public protocol HostKeyCapturing: AnyObject {
    var capturesSystemKeys: Bool { get set }
}

/// The session front door. Gate windows do not use this controller.
public final class HostApplication: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate {
    public let lifecycle = HostLifecycle()
    /// M114a (#2454): every menu action and the runner's `--host-cmd-after`
    /// mirror dispatch through this bus. The session registers the verbs it
    /// performs itself (below); the runner registers the rest on the same
    /// instance (screenshot, headless stop).
    public let commandBus = HostCommandBus()
    public let window: NSWindow
    public var onStop: (String, Int32) -> Void = { _, _ in }
    /// M114d (#2457): the drawer model — owned by the runner, injected
    /// here so the window's split pane, the bus verbs and the headless
    /// `--host-cmd-after` mirror all act on the ONE instance.
    public let inspector: HostInspector
    private let status = NSTextField(wrappingLabelWithString: "")
    private let content = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    /// M114d: the collapsible split — the guest pane on top, the
    /// inspector drawer below it, collapsed until the `inspector` verb
    /// (⌥⌘I) or a postmortem opens it.
    private let split = NSSplitView()
    private let guestArea = NSView()
    private lazy var drawer = HostInspectorView(model: inspector, bus: commandBus)
    private var guestView: NSView?
    /// M114b (#2455): the attached machine view, when it is one — the
    /// `capture-keys` verb toggles its `capturesSystemKeys`.
    private weak var captureTarget: HostKeyCapturing?
    /// M114b: the toolbar pill (a bus surface like the menu item) and the
    /// in-window "keys captured" badge — the visible affordance while
    /// `capturesSystemKeys` is on.
    private weak var captureKeysPill: NSButton?
    private let captureBadge = NSView()
    /// M114e (#2458): the counting-down recording badge — visible exactly
    /// while the bus's recorder is running, showing the cap seconds left
    /// ("● REC 42s"). The recorder's onChange drives it, so the headless
    /// bus and the menu chord light the same affordance.
    private let recordBadge = NSView()
    private let recordBadgeLabel = NSTextField(labelWithString: "")
    private let serialLog: String

    /// The toolbar item identifier for the capture-keys pill — tests find
    /// the pill by it.
    public static let captureKeysToolbarItem = NSToolbarItem.Identifier("virelai.capture-keys")

    public init(serialLog: String, inspector: HostInspector = HostInspector(), presentWindow: Bool = true) {
        self.serialLog = serialLog
        self.inspector = inspector
        // M114b (#2455): the window is resizable + fullscreen-capable now;
        // the content is aspect-locked to the 16:9 guest scanout so host
        // scaling never distorts the framebuffer (the guest resolution
        // itself is unchanged — this is host scaling, per the card).
        window = NSWindow(contentRect: content.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init()
        let app = NSApplication.shared
        registerCommands()
        if presentWindow {
            app.setActivationPolicy(.regular)
            app.delegate = self
            app.mainMenu = HostMenuBar.build(bus: commandBus)
            app.finishLaunching()
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = content
        window.acceptsMouseMovedEvents = true
        // M114d (#2457): the split — guestArea (top) + drawer (bottom,
        // collapsed). The drawer keeps its height across window resizes;
        // the guest pane flexes, and the VZ view inside it letterboxes.
        split.isVertical = false
        split.dividerStyle = .thin
        split.frame = content.bounds
        split.autoresizingMask = [.width, .height]
        split.addArrangedSubview(guestArea)
        split.addArrangedSubview(drawer)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        content.addSubview(split)
        drawer.isHidden = !inspector.isOpen
        inspector.onChange = { [weak self] in self?.syncInspector() }
        // M114b: the toolbar carries the capture-keys pill — a third
        // surface on the same verb (⌥⌘K / --host-capture-keys are the
        // other two); it dispatches through the bus like everything else.
        let toolbar = NSToolbar(identifier: "virelai-host")
        toolbar.delegate = self
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // M114b: the "keys captured" affordance — a floating badge at the
        // top of the viewport, visible exactly while capturesSystemKeys
        // is on.
        captureBadge.wantsLayer = true
        captureBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        captureBadge.layer?.cornerRadius = 11
        captureBadge.translatesAutoresizingMaskIntoConstraints = false
        let badgeLabel = NSTextField(labelWithString: "● Keys captured")
        badgeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        captureBadge.addSubview(badgeLabel)
        guestArea.addSubview(captureBadge)
        NSLayoutConstraint.activate([
            badgeLabel.leadingAnchor.constraint(equalTo: captureBadge.leadingAnchor, constant: 10),
            badgeLabel.trailingAnchor.constraint(equalTo: captureBadge.trailingAnchor, constant: -10),
            badgeLabel.topAnchor.constraint(equalTo: captureBadge.topAnchor, constant: 3),
            badgeLabel.bottomAnchor.constraint(equalTo: captureBadge.bottomAnchor, constant: -3),
            captureBadge.centerXAnchor.constraint(equalTo: guestArea.centerXAnchor),
            captureBadge.topAnchor.constraint(equalTo: guestArea.topAnchor, constant: 8),
        ])
        captureBadge.isHidden = true
        // M114e: the REC badge — the captureBadge pattern pinned to the
        // top-right so the two affordances never overlap.
        recordBadge.wantsLayer = true
        recordBadge.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.75).cgColor
        recordBadge.layer?.cornerRadius = 11
        recordBadge.translatesAutoresizingMaskIntoConstraints = false
        recordBadgeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        recordBadgeLabel.textColor = .white
        recordBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        recordBadge.addSubview(recordBadgeLabel)
        guestArea.addSubview(recordBadge)
        NSLayoutConstraint.activate([
            recordBadgeLabel.leadingAnchor.constraint(equalTo: recordBadge.leadingAnchor, constant: 10),
            recordBadgeLabel.trailingAnchor.constraint(equalTo: recordBadge.trailingAnchor, constant: -10),
            recordBadgeLabel.topAnchor.constraint(equalTo: recordBadge.topAnchor, constant: 3),
            recordBadgeLabel.bottomAnchor.constraint(equalTo: recordBadge.bottomAnchor, constant: -3),
            recordBadge.trailingAnchor.constraint(equalTo: guestArea.trailingAnchor, constant: -12),
            recordBadge.topAnchor.constraint(equalTo: guestArea.topAnchor, constant: 8),
        ])
        recordBadge.isHidden = true
        commandBus.recorder.onChange = { [weak self] in self?.refreshRecordAffordance() }
        status.alignment = .center
        status.font = .systemFont(ofSize: 18)
        status.translatesAutoresizingMaskIntoConstraints = false
        guestArea.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: guestArea.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: guestArea.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: guestArea.widthAnchor, constant: -80)
        ])
        renderState()
        if presentWindow {
            window.center()
            window.makeKeyAndOrderFront(nil)
            app.activate()
        }
    }

    /// The verbs the session window performs itself. `quit` keeps the old
    /// menu's exact path — NSApp.terminate → applicationShouldTerminate →
    /// stop("quit") — now routed through the bus so it receipts.
    private func registerCommands() {
        commandBus.register(.about, HostCommandBus.Registration {
            NSApp.orderFrontStandardAboutPanel(nil)
            return .performed
        })
        commandBus.register(.quit, HostCommandBus.Registration {
            NSApp.terminate(nil)
            return .performed
        })
        commandBus.register(.stop, HostCommandBus.Registration(isEnabled: { [weak self] in
            guard let self else { return false }
            return self.lifecycle.state != .stopping && self.lifecycle.state != .stopped
        }) { [weak self] in
            self?.stop("menu-stop")
            return .performed
        })
        // M114b (#2455): the viewport verbs. `fullscreen` toggles the
        // session window itself; `capture-keys` toggles the attached
        // VZVirtualMachineView's capturesSystemKeys and refreshes the
        // badge + pill. Scripted/headless runs register runner-side
        // variants of both on the same verb names (main.swift), so
        // --host-cmd-after drives the identical seam.
        commandBus.register(.fullscreen, HostCommandBus.Registration(
            // A hidden/ordered-out window cannot meaningfully enter
            // fullscreen — report disabled rather than firing a
            // transition into the void (and a disabled receipt is honest
            // evidence where a performed one would not be).
            isEnabled: { [weak self] in self?.window.isVisible ?? false },
            itemState: { [weak self] in self?.window.styleMask.contains(.fullScreen) ?? false }
        ) { [weak self] in
            guard let self else { return .failed }
            self.window.toggleFullScreen(nil)
            return .performed
        })
        commandBus.register(.captureKeys, HostCommandBus.Registration(
            isEnabled: { [weak self] in self?.captureTarget != nil },
            itemState: { [weak self] in self?.captureTarget?.capturesSystemKeys ?? false },
            receiptDetail: { [weak self] in
                guard let target = self?.captureTarget else { return nil }
                return "capture=\(target.capturesSystemKeys ? "on" : "off")"
            }
        ) { [weak self] in
            guard let self, let target = self.captureTarget else { return .failed }
            target.capturesSystemKeys.toggle()
            self.refreshCaptureAffordance()
            return .performed
        })
        // M114d (#2457): the inspector drawer toggle — the verb flips the
        // model's isOpen and the split pane follows through syncInspector
        // (a --host-cmd-after trigger lands the identical dispatch). The
        // receipt carries the model's live state — open, tail depth, and
        // whether the last injected line echoed back — the same detail
        // the headless registration prints.
        commandBus.register(.inspector, HostCommandBus.Registration(
            itemState: { [weak self] in self?.inspector.isOpen ?? false },
            receiptDetail: { [weak self] in self?.inspector.receiptDetail }
        ) { [weak self] in
            guard let self else { return .failed }
            self.inspector.isOpen.toggle()
            return .performed
        })
    }

    /// The visible affordance of the drawer — the class-A seam tests
    /// read instead of poking AppKit. `inspector.isOpen` is the model's
    /// truth; the split pane mirrors it through syncInspector.
    public var inspectorVisible: Bool { inspector.isOpen }

    /// Model → pane: the drawer's hidden flag mirrors `isOpen`, and an
    /// open gets a real share of the window (260pt, halved on a small
    /// one). Called on every model change — ingest batches included —
    /// so the tail, counters and postmortem card stay live.
    private func syncInspector() {
        let open = inspector.isOpen
        if drawer.isHidden == open {
            drawer.isHidden = !open
            if open {
                split.layoutSubtreeIfNeeded()
                let h = split.bounds.height
                split.setPosition(max(h - 260, h / 2), ofDividerAt: 0)
            }
        }
        drawer.reload()
    }

    /// The badge + pill mirror the live `capturesSystemKeys` property —
    /// the visible "keys captured" affordance of the card. Read back by
    /// class-A tests.
    public var keysCaptureAffordanceVisible: Bool { !captureBadge.isHidden }

    /// M114e: the badge's visibility + countdown text — class-A tests
    /// read these instead of poking AppKit.
    public var recordAffordanceVisible: Bool { !recordBadge.isHidden }
    public var recordAffordanceText: String { recordBadgeLabel.stringValue }

    private func refreshRecordAffordance() {
        let recorder = commandBus.recorder
        recordBadge.isHidden = !recorder.isRecording
        recordBadgeLabel.stringValue = "● REC \(recorder.remaining)s"
    }

    private func refreshCaptureAffordance() {
        let on = captureTarget?.capturesSystemKeys ?? false
        captureBadge.isHidden = !on
        captureKeysPill?.state = on ? .on : .off
    }

    /// The toolbar pill is a bus surface like the menu item — it
    /// dispatches the verb rather than touching the view itself.
    @objc private func captureKeysPillTapped(_ sender: NSButton) {
        commandBus.dispatch(.captureKeys)
    }

    // MARK: NSToolbarDelegate — the pill is the only item for now.

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, HostApplication.captureKeysToolbarItem]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar,
                        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == HostApplication.captureKeysToolbarItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let pill = NSButton(title: "Capture Keys", target: self,
                            action: #selector(captureKeysPillTapped(_:)))
        pill.bezelStyle = .rounded
        pill.setButtonType(.toggle)
        pill.state = (captureTarget?.capturesSystemKeys ?? false) ? .on : .off
        item.view = pill
        item.label = "Keys"
        item.paletteLabel = "Capture System Keys"
        item.toolTip = "Send system key chords to the VM (⌥⌘K)"
        captureKeysPill = pill
        return item
    }

    public func attach(_ view: NSView) {
        guestView = view
        captureTarget = view as? HostKeyCapturing
        // M114e: the session's record surface — the bus's recorder films
        // this view instead of discovering a window through NSApp.
        commandBus.recorder.captureView = view
        refreshCaptureAffordance()
        view.frame = guestArea.bounds
        view.autoresizingMask = [.width, .height]
        guestArea.addSubview(view, positioned: .below, relativeTo: status)
        renderState()
    }

    public func didStart() {
        lifecycle.didStart()
        renderState()
        focusGuest()
        reportFocus("started")
    }

    public func showFailure(_ message: String) {
        lifecycle.fail(message)
        renderState()
    }

    public func stop(_ reason: String, code: Int32 = 0) {
        guard lifecycle.requestStop(code: code) else { return }
        renderState()
        onStop(reason, lifecycle.exitCode)
    }

    private func renderState() {
        switch lifecycle.state {
        case .starting:
            window.title = "VirelaiOS — Starting VM"
            status.stringValue = "Starting VirelaiOS…\nSerial log: \(serialLog)"
        case .running:
            window.title = "VirelaiOS"
        case .failed(let message):
            window.title = "VirelaiOS — VM failed"
            status.stringValue = "VirelaiOS could not run the VM.\n\(message)\nSerial log: \(serialLog)\nClose this window or choose Quit, then rerun the session command."
        case .stopping:
            window.title = "VirelaiOS — Stopping VM"
            status.stringValue = "Stopping VirelaiOS…"
        case .stopped:
            status.stringValue = "VirelaiOS stopped."
        }
        status.isHidden = lifecycle.state == .running
        guestView?.isHidden = lifecycle.state != .running
        if lifecycle.state != .running { window.makeFirstResponder(nil) }
    }

    private func focusGuest() {
        guard lifecycle.state == .running, let guestView else { return }
        window.makeFirstResponder(guestView)
    }

    private func reportFocus(_ reason: String) {
        print("host-session: \(reason) pid=\(ProcessInfo.processInfo.processIdentifier) window=\(window.windowNumber) key=\(window.isKeyWindow) responder=\(guestView != nil && window.firstResponder === guestView) active=\(NSApp.isActive) visible=\(window.isVisible) onscreen=\(window.isOnActiveSpace) bundle=\(Bundle.main.bundleIdentifier ?? "none")")
        fflush(stdout)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        focusGuest()
        reportFocus("key-window")
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        focusGuest()
        reportFocus("active")
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        stop("window-close")
        return false // Keep the stopping state visible until VZ completes.
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stop("quit")
        return .terminateLater // The runner exits only after VM stop + drain.
    }

    public static func presentLaunchFailure(_ message: String) -> Never {
        // Use the same native event loop/window as a running session.
        // A modal alert before NSApplication.run can return without showing.
        let host = HostApplication(serialLog: "See the launching terminal.")
        host.showFailure(message)
        host.onStop = { _, code in exit(code) } // No VM was created.
        var sources: [DispatchSourceSignal] = []
        for sig: Int32 in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { host.stop("signal-\(sig)", code: 128 + sig) }
            source.resume()
            sources.append(source)
        }
        withExtendedLifetime((host, sources)) { NSApplication.shared.run() }
        exit(1)
    }
}
