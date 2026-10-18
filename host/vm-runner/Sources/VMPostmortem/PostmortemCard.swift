import Foundation

/// M114d (#2457, index #2447): the content model of the in-window
/// stop/crash card the inspector drawer renders. Kept here — with the
/// StopReasonRecorder it quotes — so the card's vocabulary ("stopped"
/// versus "crashed", which fields a row carries) is pinned by `swift
/// test` on a machine that never boots a VM, the same discipline claim
/// #1278 set for the recorder itself.
///
/// The runner builds one when the VM leaves the running state:
/// `.stopped` for a clean VZ shutdown the delegate narrated (or failed
/// to narrate), `.crashed` for `state = .error` or a start failure.
public struct PostmortemCard: Equatable, Sendable {
    public enum Ending: String, Equatable, Sendable {
        /// The VM reached `.stopped` — guest power-off or a host stop.
        case stopped
        /// The VM reached `.error`, or `vm.start` itself failed.
        case crashed
    }

    public let ending: Ending
    /// The VZ state token at capture (the rawValue the verdict lines
    /// print) or a short phase name when no state applies ("start").
    public let state: String
    /// The StopReasonRecorder line — `guest-powered-off`, the
    /// `domain=… code=… desc=…` error form, or `<none reported by VZ>`.
    public let reason: String
    /// How deep the inspector's serial tail was when the VM ended — the
    /// card's pointer at the evidence a human would scroll for.
    public let serialLines: Int

    public init(ending: Ending, state: String, reason: String, serialLines: Int) {
        self.ending = ending
        self.state = state
        self.reason = reason
        self.serialLines = serialLines
    }

    /// The card's headline.
    public var title: String {
        ending == .crashed ? "VM crashed" : "VM stopped"
    }

    /// The card's body rows — one fact per line, stable order (state,
    /// then why, then where the evidence is).
    public var rows: [String] {
        ["state=\(state)", "reason=\(reason)", "serial tail: \(serialLines) line(s)"]
    }
}
