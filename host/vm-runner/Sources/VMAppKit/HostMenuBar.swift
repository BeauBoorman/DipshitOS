import AppKit

/// M114a (#2454, index #2447): the full menu bar, built as a projection
/// of the HostCommandBus. Every leaf item carries its verb in
/// `representedObject` and dispatches through `dispatchItem`; validation
/// asks the bus, so a verb with no registered handler renders disabled
/// until its card wires it (later cards add verbs, not menus).
public enum HostMenuBar {
    public static func build(bus: HostCommandBus) -> NSMenu {
        let bar = NSMenu()

        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let sub = NSMenu(title: title)
            item.submenu = sub
            bar.addItem(item)
            return sub
        }
        func action(_ title: String, _ command: HostCommand,
                    key: String = "",
                    modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title,
                                  action: #selector(HostCommandBus.dispatchItem(_:)),
                                  keyEquivalent: key)
            item.target = bus
            item.representedObject = command
            if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
            return item
        }

        let app = menu("VirelaiOS")
        app.addItem(action("About VirelaiOS", .about))
        app.addItem(.separator())
        // M128a (#2605): ⌘, — the machine settings panel. The verb
        // receipts `disabled` until a profile is armed, so the item
        // greys on a flag-run (the bus's enablement is the menu's).
        app.addItem(action("Machine Settings…", .settings, key: ","))
        app.addItem(.separator())
        app.addItem(action("Quit VirelaiOS", .quit, key: "q"))

        let machine = menu("Machine")
        machine.addItem(action("Stop VM", .stop))

        let view = menu("View")
        view.addItem(action("Enter Full Screen", .fullscreen,
                          key: "f", modifiers: [.control, .command]))
        view.addItem(.separator())
        view.addItem(action("Capture System Keys", .captureKeys,
                          key: "k", modifiers: [.option, .command]))

        let integration = menu("Integration")
        integration.addItem(action("Clipboard", .laneClipboard))
        integration.addItem(action("File Drop", .laneDrop))
        integration.addItem(action("Notifications", .laneNotify))
        integration.addItem(action("Agent Channel", .laneAgent))
        integration.addItem(.separator())
        integration.addItem(action("Send File to INBOX…", .sendFile))

        let debug = menu("Debug")
        debug.addItem(action("Inspector", .inspector,
                             key: "i", modifiers: [.option, .command]))
        debug.addItem(.separator())
        debug.addItem(action("Take Screenshot", .screenshot,
                             key: "5", modifiers: [.shift, .command]))
        debug.addItem(action("Record Window", .record,
                             key: "6", modifiers: [.shift, .command]))

        return bar
    }
}
