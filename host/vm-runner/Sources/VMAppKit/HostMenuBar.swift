import AppKit

/// M114a (#2454, index #2447): the full menu bar, built as a projection
/// of the HostCommandBus. Every leaf item carries its verb in
/// `representedObject` and dispatches through `dispatchItem`; validation
/// asks the bus, so a verb with no registered handler renders disabled
/// until its card wires it (later cards add verbs, not menus).
///
/// M122d (#2573): `menus` below is now the declarative command table —
/// the bar is one projection of it and the ⌘/ cheat-sheet's chord rows
/// (`HostShortcutsModel.rows` via `chords`) are the other, so a chord
/// added to a menu appears in the sheet without a second list to keep
/// honest.
public enum HostMenuBar {
    /// One leaf of the command table: a title, its verb, and its chord
    /// (`key == ""` = no chord). `hasSubmenu` marks the one leaf whose
    /// submenu the bus repopulates per open ("Switch To" — the sibling
    /// machine list lives in the registration, not the table).
    public struct Item {
        public let title: String
        public let command: HostCommand
        public let key: String
        public let modifiers: NSEvent.ModifierFlags
        public let hasSubmenu: Bool

        public init(_ title: String, _ command: HostCommand,
                    key: String = "",
                    modifiers: NSEvent.ModifierFlags = .command,
                    hasSubmenu: Bool = false) {
            self.title = title
            self.command = command
            self.key = key
            self.modifiers = modifiers
            self.hasSubmenu = hasSubmenu
        }

        /// The glyphs the cheat sheet renders — ⌃⌥⇧⌘ order (Apple's
        /// canonical), the key uppercased like the menu shows it.
        public var chordDisplay: String {
            var s = ""
            if modifiers.contains(.control) { s += "⌃" }
            if modifiers.contains(.option) { s += "⌥" }
            if modifiers.contains(.shift) { s += "⇧" }
            if modifiers.contains(.command) { s += "⌘" }
            return s + key.uppercased()
        }
    }

    /// The command table: menu title → sections (each inner array is
    /// one run of leaves; sections join with separators). Order is the
    /// bar's order.
    public static let menus: [(title: String, sections: [[Item]])] = [
        ("VirelaiOS", [
            [Item("About VirelaiOS", .about)],
            // M128a (#2605): ⌘, — the machine settings panel. The verb
            // receipts `disabled` until a profile is armed, so the item
            // greys on a flag-run (the bus's enablement is the menu's).
            [Item("Machine Settings…", .settings, key: ",")],
            [Item("Quit VirelaiOS", .quit, key: "q")],
        ]),
        ("Machine", [
            [Item("Stop VM", .stop)],
            // M120c (#2560): the persistence lifecycle — each item greys
            // live on the machine model's posture.
            [Item("Suspend", .suspend), Item("Snapshot", .snapshot)],
            // M183c (#3173): the idle-pause preference toggle (checkmark
            // mirrors the host pref) and the "paused (idle)" line — the
            // card's menu-bar surface: while the policy holds a pause the
            // leaf reads enabled and its tap is the resume edge.
            [Item("Pause VM When Hidden", .idlePause),
             Item("Paused (idle) — Resume Now", .idleFocus)],
            [Item("Apply OS Update", .applyUpdate), Item("Roll Back OS Update", .rollbackUpdate)],
            [Item("Reveal Share in Finder", .revealShare)],
            // M128b (#2606): the profile manager. "Switch To" is a
            // submenu parent — it carries the verb (so validateMenuItem
            // greys it when no sibling exists) and the standard
            // dispatchItem seam like every other leaf; its submenu
            // leaves carry the per-sibling target in the item
            // identifier (the bus's menuNeedsUpdate fills it).
            [Item("New Machine", .profileNew), Item("Clone This Machine", .profileClone),
             Item("Switch To", .profileSwitch, hasSubmenu: true),
             Item("Reset Boot Overlay…", .profileResetOverlay)],
            // M139a (#2779): one process, N windows — the submenu lists
            // the sibling bundles a new session could boot (open ones
            // drop out; the registry's profile_in_use refusal is the
            // same seam headlessly).
            [Item("New Window for Profile", .newWindow, hasSubmenu: true)],
        ]),
        ("View", [
            [Item("Enter Full Screen", .fullscreen, key: "f", modifiers: [.control, .command])],
            [Item("Capture System Keys", .captureKeys, key: "k", modifiers: [.option, .command])],
        ]),
        ("Integration", [
            [Item("Clipboard", .laneClipboard), Item("File Drop", .laneDrop),
             Item("Notifications", .laneNotify), Item("Agent Channel", .laneAgent)],
            [Item("Send File to INBOX…", .sendFile)],
        ]),
        ("Debug", [
            [Item("Inspector", .inspector, key: "i", modifiers: [.option, .command])],
            [Item("Take Screenshot", .screenshot, key: "5", modifiers: [.shift, .command]),
             Item("Record Window", .record, key: "6", modifiers: [.shift, .command])],
        ]),
        ("Help", [
            // M122d (#2573): the ⌘/ cheat sheet — its rows are this
            // table's chorded leaves, so it can never list a chord the
            // menus do not know.
            [Item("Keyboard Shortcuts", .shortcuts, key: "/")],
        ]),
    ]

    /// The leaves that carry a chord, in menu order — the cheat sheet's
    /// row source.
    public static var chords: [Item] {
        menus.flatMap { $0.sections.flatMap { $0 } }.filter { !$0.key.isEmpty }
    }

    /// M139a (#2779): `target` may differ from `bus` — the multi-window
    /// runner passes a router that forwards every dispatch/validation to
    /// the key window's session bus, so one process-global menu bar acts
    /// on whichever machine is frontmost. nil = the bus itself (the
    /// single-window shape).
    public static func build(bus: HostCommandBus, target: NSObject? = nil) -> NSMenu {
        let resolved = target ?? bus
        let menuDelegate = (resolved as? NSMenuDelegate) ?? bus
        let bar = NSMenu()
        for (title, sections) in menus {
            let top = NSMenuItem()
            let sub = NSMenu(title: title)
            top.submenu = sub
            bar.addItem(top)
            for (i, section) in sections.enumerated() {
                if i > 0 { sub.addItem(.separator()) }
                for leaf in section {
                    let item = NSMenuItem(
                        title: leaf.title,
                        action: #selector(HostCommandBus.dispatchItem(_:)),
                        keyEquivalent: leaf.key)
                    item.target = resolved
                    item.representedObject = leaf.command
                    if !leaf.key.isEmpty { item.keyEquivalentModifierMask = leaf.modifiers }
                    if leaf.hasSubmenu {
                        let child = NSMenu(title: leaf.title)
                        child.delegate = menuDelegate // menuNeedsUpdate lists the siblings
                        // M139a: the verb's wire name tags the submenu so
                        // the bus's menuNeedsUpdate knows which sibling
                        // list to fill (Switch To vs New Window).
                        child.identifier = NSUserInterfaceItemIdentifier(leaf.command.rawValue)
                        item.submenu = child
                    }
                    sub.addItem(item)
                }
            }
        }
        return bar
    }
}
