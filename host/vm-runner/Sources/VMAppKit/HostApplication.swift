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
    private let status = NSTextField(wrappingLabelWithString: "")
    private let content = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    private var guestView: NSView?
    /// M114b (#2455): the attached machine view, when it is one — the
    /// `capture-keys` verb toggles its `capturesSystemKeys`.
    private weak var captureTarget: HostKeyCapturing?
    /// M114b: the toolbar pill (a bus surface like the menu item) and the
    /// in-window "keys captured" badge — the visible affordance while
    /// `capturesSystemKeys` is on.
    private weak var captureKeysPill: NSButton?
    private let captureBadge = NSView()
    private let serialLog: String

    /// The toolbar item identifier for the capture-keys pill — tests find
    /// the pill by it.
    public static let captureKeysToolbarItem = NSToolbarItem.Identifier("virelai.capture-keys")

    public init(serialLog: String, presentWindow: Bool = true) {
        self.serialLog = serialLog
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
        content.addSubview(captureBadge)
        NSLayoutConstraint.activate([
            badgeLabel.leadingAnchor.constraint(equalTo: captureBadge.leadingAnchor, constant: 10),
            badgeLabel.trailingAnchor.constraint(equalTo: captureBadge.trailingAnchor, constant: -10),
            badgeLabel.topAnchor.constraint(equalTo: captureBadge.topAnchor, constant: 3),
            badgeLabel.bottomAnchor.constraint(equalTo: captureBadge.bottomAnchor, constant: -3),
            captureBadge.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            captureBadge.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
        ])
        captureBadge.isHidden = true
        status.alignment = .center
        status.font = .systemFont(ofSize: 18)
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -80)
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
    }

    /// The badge + pill mirror the live `capturesSystemKeys` property —
    /// the visible "keys captured" affordance of the card. Read back by
    /// class-A tests.
    public var keysCaptureAffordanceVisible: Bool { !captureBadge.isHidden }

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
        refreshCaptureAffordance()
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view, positioned: .below, relativeTo: status)
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
