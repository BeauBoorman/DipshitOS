import AppKit

/// The session front door. Gate windows do not use this controller.
public final class HostApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
    private let serialLog: String

    public init(serialLog: String, presentWindow: Bool = true) {
        self.serialLog = serialLog
        window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
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
    }

    public func attach(_ view: NSView) {
        guestView = view
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
