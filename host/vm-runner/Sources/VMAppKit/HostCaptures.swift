import Foundation
import VMProfile

/// M120e (#2562, index #2548): where captures land and the "saved" badge
/// — the model `swift test` pins. The ⌘⇧5 screenshot verb and the
/// M114e recorder share one destination: `<share>/CAPTURES/` of the
/// armed share, where "the share" is the flag channel first
/// (`--cvc-file`/`--virtio-fs` — the runner's own precedence) and then
/// the ACTIVE PROFILE's share/ member, so a `--host-session`/`--profile`
/// run with no explicit share flag still routes its captures into the
/// machine bundle the operator launched.
///
/// One instance per bus: HostCommandBus carries it like the recorder/
/// agent/settings companions, so the bare `HostCommandBus()` a scripted
/// `--host-cmd-after` run builds resolves the identical seam the session
/// window's menu does. The bus also wires the recorder's `onSaved` here,
/// so a finished take counts the same as a ⌘⇧5 capture.
///
/// The transient badge is honest model state: `noteSaved` stamps the
/// wall clock, `savedBadgeVisible` reads it back against `now()` — the
/// session window mirrors it with a one-shot hide timer, and a headless
/// run's `saved=`/ `file=` receipt detail is the same truth a gate can
/// read. All access is main-queue (the bus, the polls and the window all
/// are), so the model takes no lock — the HostCommandBus precedent.
public final class HostCaptures {
    /// The share subdirectory every capture lands in — the name
    /// HostRecorder's argv resolution and this card agree on.
    public static let capturesDirName = "CAPTURES"

    // MARK: Seams — every external input is injectable.

    /// argv override: nil reads CommandLine.arguments (production).
    public var arguments: [String]?
    /// Direct share override; else `--cvc-file`/`--virtio-fs` argv, else
    /// the armed profile's share/ (the HostMachineModel precedence).
    public var shareDir: URL?
    /// Direct profile override; else `--profile`/`--resume` argv (the
    /// document-launch arm sets this — a Finder launch carries no flag).
    public var profileURL: URL?
    /// Full-destination override — the test seam; nil resolves a share.
    public var outDir: URL?
    /// How long the saved badge stays up.
    public var badgeTTL: TimeInterval = 4
    /// The wall clock — injectable so a test runs a badge's whole life
    /// synchronously (the recorder's `now` precedent).
    public var now: () -> Date = { Date() }
    /// The marker sink — the bus wires it to its own emit so `host-cap:`
    /// and `host-ui:` lines share one stream a gate greps.
    public var emit: (String) -> Void = {
        FileHandle.standardOutput.write(Data(($0 + "\n").utf8))
    }
    /// Model → view notification (main queue, the HostInspector rule) —
    /// the session window's saved badge refreshes on it.
    public var onChange: (() -> Void)?

    // MARK: State — what the receipts read.

    /// Captures landed this run — the `saved=` receipt detail.
    public private(set) var savedCount = 0
    /// The most recent capture's on-disk URL — the badge's filename.
    public private(set) var lastSaved: URL?
    private var savedAt: Date?

    public init() {}

    // MARK: Resolution — the armed share, then the profile's.

    /// The armed host share — the flag channel first (`--cvc-file` or
    /// `--virtio-fs`, the runner's own precedence), else the armed
    /// profile's share/. nil when nothing is armed — a shareless run's
    /// captures are not promised anywhere (the verb falls back to its
    /// legacy --screen path, honestly).
    public func resolvedShareDir() -> URL? {
        if let shareDir { return shareDir }
        let args = arguments ?? CommandLine.arguments
        for flag in ["--cvc-file", "--virtio-fs"] {
            if let i = args.firstIndex(of: flag), i + 1 < args.count {
                return URL(fileURLWithPath: args[i + 1], isDirectory: true)
            }
        }
        guard let url = profileURL ?? HostSettingsModel.profileURL(arguments: args),
              let profile = try? VMProfile.load(from: url) else { return nil }
        return profile.shareURL
    }

    /// `<share>/CAPTURES` — the capture destination when a share
    /// resolves; nil otherwise.
    public func resolvedDir() -> URL? {
        outDir ?? resolvedShareDir()?.appendingPathComponent(Self.capturesDirName, isDirectory: true)
    }

    // MARK: Saved state + the badge.

    /// Record a capture that reached disk — bumps the counter, arms the
    /// badge TTL and prints the `host-cap:` evidence line. Called by the
    /// screenshot verb and the recorder's onSaved, so both surfaces of
    /// the card's "captures" land the same affordance.
    public func noteSaved(_ url: URL) {
        lastSaved = url
        savedAt = now()
        savedCount += 1
        emit("host-cap: saved \(url.path)")
        changed()
    }

    /// Badge truth: visible for `badgeTTL` seconds after the last save.
    public var savedBadgeVisible: Bool {
        guard let savedAt else { return false }
        return now().timeIntervalSince(savedAt) < badgeTTL
    }

    /// The badge's text — the capture's own filename, not a path dump.
    public var savedBadgeText: String {
        lastSaved.map { "✓ Saved \($0.lastPathComponent)" } ?? ""
    }

    /// Seconds of badge life left — the window schedules its one-shot
    /// hide on it instead of polling.
    public var badgeRemaining: TimeInterval {
        guard let savedAt else { return 0 }
        return max(0, badgeTTL - now().timeIntervalSince(savedAt))
    }

    /// The `saved=N file=<name>` receipt tail a dispatch appends —
    /// actuals, not intent (the recorder's receiptDetail precedent).
    public var receiptDetail: String {
        "saved=\(savedCount) file=\(lastSaved?.lastPathComponent ?? "none")"
    }

    private func changed() { onChange?() }
}
