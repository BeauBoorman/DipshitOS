import AppKit
import Foundation
import VMAppKit

// MARK: - HostIntCommands — M114c (#2456, index #2447): the M108 lanes'
// verbs on the HostCommand action bus.
//
// The bus and the verbs are M114a's — this file is where M114c registers
// the handlers the Integration menu projects. Each lane's start() calls
// its registerLane once armed, wiring the verb onto `commandBus` — the
// same bus --host-cmd-after and the AppKit menus dispatch on, so a
// class-B run exercises the real seam. The lane objects and the session
// are main.swift globals read lazily AT DISPATCH, so registration order
// against the other lanes does not matter.
//
// lane-clipboard / lane-drop / lane-notify are the Integration menu's
// toggles: dispatching flips the lane's published ARMED bit — the
// session republishes ARMED (next seq, same epoch) with the bit
// cleared/set; the seat's seq-gated adoption re-reads the mask and its
// emit path then refuses the lane `lane_disabled` (the engine's
// re-ARMED revocation). The checkmark is the lane's live state — the
// mask bit is the posture, not a UI-only flag.
//
// send-file is "Send File to INBOX…": the drop lane's gesture through
// the bus — the same drop(urls:) the NSView's performDragOperation and
// --host-drop-file's marker path call. The headless source is the
// --host-drop-file list itself (a gate stages paths without arming
// --host-drop-after's marker); a bundled session with no staged list
// opens an NSOpenPanel instead.
enum HostIntCommands {

    /// M139a (#2779): the session that owns a lane — resolved by identity
    /// through the registry so a secondary session's lanes register on
    /// its own bus and toggle its own HostInt mask. A lane no session
    /// owns (a bare test lane) keeps the global posture, unchanged.
    private static func owner(_ lane: AnyObject) -> VMSession? {
        VMSessionRegistry.shared.session(owning: lane)
    }
    private static func bus(of session: VMSession?) -> HostCommandBus {
        session.map { VMSessionRegistry.shared.bus(for: $0) } ?? commandBus
    }
    private static func hostInt(of session: VMSession?) -> HostIntSession? {
        session?.hostInt ?? hostIntSession
    }
    private static func dropLane(of session: VMSession?) -> HostDrop? {
        session?.drop ?? hostDrop
    }

    /// The bus a lane's verbs belong on — its owning session's bus, the
    /// global for a bare test lane. Lanes that register extra verbs of
    /// their own (HostNotify's notify-click) resolve through here so a
    /// secondary session's verb never lands on the primary's menu.
    static func bus(owning lane: AnyObject) -> HostCommandBus {
        bus(of: owner(lane))
    }

    static func registerLane(_ lane: HostClipboard) {
        let s = owner(lane)
        let int = hostInt(of: s)
        bus(of: s).register(.laneClipboard, HostCommandBus.Registration(
            itemState: { int?.isSuspended(HostInt.laneClip) == false },
            action: { toggle(HostInt.laneClip, in: s) }))
    }

    static func registerLane(_ lane: HostDrop) {
        let s = owner(lane)
        let int = hostInt(of: s)
        bus(of: s).register(.laneDrop, HostCommandBus.Registration(
            itemState: { int?.isSuspended(HostInt.laneDrop) == false },
            action: { toggle(HostInt.laneDrop, in: s) }))
        // A suspended drop lane greys the menu item AND refuses the
        // dispatch — `state=disabled` is the receipt; the lane_disabled
        // vocabulary line comes from drop()'s own suspended check on the
        // paths that DO reach it (drag, the --host-drop-after marker).
        bus(of: s).register(.sendFile, HostCommandBus.Registration(
            isEnabled: { dropLane(of: s) != nil && int?.isSuspended(HostInt.laneDrop) == false },
            action: { sendFile(in: s) }))
    }

    static func registerLane(_ lane: HostNotify) {
        let s = owner(lane)
        let int = hostInt(of: s)
        bus(of: s).register(.laneNotify, HostCommandBus.Registration(
            itemState: { int?.isSuspended(HostInt.laneNotify) == false },
            action: { toggle(HostInt.laneNotify, in: s) }))
    }

    /// M127d's pair: lane-outbox toggles the ARMED bit like the other
    /// lane toggles; reveal-export reveals the registered lane's most
    /// recent landing in Finder — the verb the export banner's click
    /// mirrors. Both resolve through the owning session so a secondary
    /// session's lane toggles ITS mask, not the primary's.
    static func registerLane(_ lane: HostOutbox) {
        let s = owner(lane)
        let int = hostInt(of: s)
        bus(of: s).register(.laneOutbox, HostCommandBus.Registration(
            itemState: { int?.isSuspended(HostInt.laneOutbox) == false },
            action: { toggle(HostInt.laneOutbox, in: s) }))
        bus(of: s).register(.revealExport, HostCommandBus.Registration(
            isEnabled: { [weak lane] in lane?.lastLanding != nil },
            action: { [weak lane] in lane?.revealLast() ?? .unavailable }))
    }

    /// The toggle: republish ARMED with the bit cleared (suspend) or set
    /// (resume) under the same epoch. The republish is the whole action —
    /// the seat's next poll adopts the new mask and its emit/consume
    /// postures follow it.
    private static func toggle(_ bit: UInt8, in s: VMSession? = nil) -> HostCommandBus.Outcome {
        guard let session = hostInt(of: s) else { return .unavailable }
        return session.setSuspended(bit, !session.isSuspended(bit)) ? .performed : .failed
    }

    /// "Send File to INBOX…": drive the drop lane's gesture through the
    /// bus. Headless runs ride the staged --host-drop-file list (with no
    /// --host-drop-after marker fired, the list is otherwise inert — this
    /// is what a --host-cmd-after leg sends); a bundled session picks
    /// through an NSOpenPanel.
    private static func sendFile(in s: VMSession? = nil) -> HostCommandBus.Outcome {
        guard let drop = dropLane(of: s) else { return .unavailable }
        if !hostDropFiles.isEmpty {
            let urls = hostDropFiles.map { URL(fileURLWithPath: $0) }
            FileHandle.standardOutput.write(Data("host-drop: send files=\(urls.count)\n".utf8))
            drop.drop(urls: urls)
            return .performed
        }
        // No staged list and no app bundle — a bare runner cannot raise
        // the picker (NSOpenPanel needs NSApplication), so refuse rather
        // than hang.
        guard Bundle.main.bundleIdentifier != nil else {
            FileHandle.standardOutput.write(Data("host-drop: send refused — no --host-drop-file list and no app bundle for a picker\n".utf8))
            return .disabled
        }
        let panel = NSOpenPanel()
        panel.message = "Send files to the guest's INBOX"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return .disabled }
        FileHandle.standardOutput.write(Data("host-drop: send files=\(panel.urls.count)\n".utf8))
        drop.drop(urls: panel.urls)
        return .performed
    }
}
