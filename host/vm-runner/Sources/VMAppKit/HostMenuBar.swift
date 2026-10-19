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
        machine.addItem(.separator())
        // M120c (#2560): the persistence lifecycle. Suspend saves the
        // machine state into the profile's saved-state/ and stops the
        // run (--resume continues it); Snapshot parks a menu-<stamp>
        // .vzsave on the armed share for GOSNAP to restore; the update
        // pair runs the M115f verify+swap/rollback on the base image;
        // Reveal Share opens the armed share in Finder. Each item greys
        // live on the machine model's posture — the bus's enablement is
        // the menu's.
        machine.addItem(action("Suspend", .suspend))
        machine.addItem(action("Snapshot", .snapshot))
        machine.addItem(.separator())
        machine.addItem(action("Apply OS Update", .applyUpdate))
        machine.addItem(action("Roll Back OS Update", .rollbackUpdate))
        machine.addItem(.separator())
        machine.addItem(action("Reveal Share in Finder", .revealShare))
        machine.addItem(.separator())
        // M128b (#2606): the profile manager. New/clone mint sibling
        // bundles next to the armed one; reset-overlay re-mints the
        // armed bundle's overlay.asif on next boot; "Switch To" is a
        // submenu the bus's menuNeedsUpdate repopulates per open with
        // the sibling machines. All receipt `disabled` on a flag-run.
        machine.addItem(action("New Machine", .profileNew))
        machine.addItem(action("Clone This Machine", .profileClone))
        // "Switch To" is a submenu parent — it carries the verb (so
        // validateMenuItem greys it when no sibling exists) and the
        // standard dispatchItem seam like every other leaf; its submenu
        // leaves carry the per-sibling target in the item identifier.
        let switchItem = action("Switch To", .profileSwitch)
        let switchSub = NSMenu(title: "Switch To")
        switchSub.delegate = bus // menuNeedsUpdate lists the siblings
        switchItem.submenu = switchSub
        machine.addItem(switchItem)
        machine.addItem(action("Reset Boot Overlay…", .profileResetOverlay))

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
