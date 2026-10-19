import AppKit
import XCTest
import VMAppKit
import VMProfile

/// M120e (#2562): the capture destination + saved-badge model — where
/// ⌘⇧5/recordings resolve `<share>/CAPTURES` (flag share first, then the
/// active profile's share/), the saved counter + receipt, the badge TTL,
/// the recorder→captures wiring on the bus, and the session window's
/// saved badge — class-A, no VM (the HostRecorderTests precedent).
final class HostCapturesTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostcap-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    // MARK: - destination resolution

    /// `--cvc-file`/`--virtio-fs` resolve the share the same way the
    /// recorder's argv lookup does; neither flag means no destination.
    func testShareFlagsResolveTheCapturesDir() {
        let model = HostCaptures()
        model.arguments = ["vmrunner", "--virtio-fs", "/tmp/vfs"]
        XCTAssertEqual(model.resolvedDir()?.path, "/tmp/vfs/CAPTURES")
        model.arguments = ["vmrunner", "--cvc-file", "/tmp/cvc"]
        XCTAssertEqual(model.resolvedDir()?.path, "/tmp/cvc/CAPTURES")
        // --cvc-file wins when both are armed (the runner's precedence).
        model.arguments = ["vmrunner", "--virtio-fs", "/v", "--cvc-file", "/c"]
        XCTAssertEqual(model.resolvedDir()?.path, "/c/CAPTURES")
        model.arguments = ["vmrunner", "--screen", "/tmp/s"]
        XCTAssertNil(model.resolvedDir())
    }

    /// The card's "of the active profile" half: a `--profile` run arms no
    /// share flag, yet captures route into the bundle's share/CAPTURES.
    func testActiveProfileShareResolvesWhenNoFlagIsArmed() throws {
        let bundle = makeTempDir().appendingPathComponent("m.virelaivm")
        _ = try VMProfile.create(at: bundle)
        let model = HostCaptures()
        model.arguments = ["vmrunner", "--profile", bundle.path]
        XCTAssertEqual(model.resolvedDir()?.path,
                       bundle.appendingPathComponent("share/CAPTURES").path)
        // A --resume boot resolves the same way.
        model.arguments = ["vmrunner", "--resume", bundle.path]
        XCTAssertEqual(model.resolvedDir()?.path,
                       bundle.appendingPathComponent("share/CAPTURES").path)
        // And the direct profileURL seam (the document-launch arm).
        model.arguments = ["vmrunner"]
        model.profileURL = bundle
        XCTAssertEqual(model.resolvedDir()?.path,
                       bundle.appendingPathComponent("share/CAPTURES").path)
    }

    /// A share flag still outranks the armed profile (the runner's own
    /// precedence), and an unloadable profile path resolves nothing.
    func testFlagBeatsProfileAndABadProfileIsNoDestination() throws {
        let bundle = makeTempDir().appendingPathComponent("m.virelaivm")
        _ = try VMProfile.create(at: bundle)
        let model = HostCaptures()
        model.arguments = ["vmrunner", "--profile", bundle.path,
                           "--virtio-fs", "/tmp/flagged"]
        XCTAssertEqual(model.resolvedDir()?.path, "/tmp/flagged/CAPTURES")
        model.arguments = ["vmrunner", "--profile", "/nonexistent/x.virelaivm"]
        XCTAssertNil(model.resolvedDir())
    }

    /// The injected share + full-dir overrides win in order — the
    /// runner's document-launch arm and the test seam.
    func testInjectedSeamsBeatArgv() {
        let share = makeTempDir()
        let model = HostCaptures()
        model.arguments = ["vmrunner", "--virtio-fs", "/elsewhere"]
        model.shareDir = share
        XCTAssertEqual(model.resolvedDir()?.path,
                       share.appendingPathComponent("CAPTURES").path)
        let out = makeTempDir()
        model.outDir = out
        XCTAssertEqual(model.resolvedDir(), out)
    }

    // MARK: - the saved record + badge

    func testNoteSavedCountsArmsBadgeAndEmits() {
        var t = Date()
        let model = HostCaptures()
        var lines: [String] = []
        model.emit = { lines.append($0) }
        model.now = { t }
        let file = URL(fileURLWithPath: "/tmp/share/CAPTURES/screen8-hostui-1.png")
        XCTAssertFalse(model.savedBadgeVisible)
        XCTAssertEqual(model.receiptDetail, "saved=0 file=none")
        model.noteSaved(file)
        XCTAssertEqual(model.savedCount, 1)
        XCTAssertEqual(model.lastSaved, file)
        XCTAssertTrue(model.savedBadgeVisible)
        XCTAssertEqual(model.savedBadgeText, "✓ Saved screen8-hostui-1.png")
        XCTAssertEqual(lines, ["host-cap: saved \(file.path)"])
        XCTAssertEqual(model.receiptDetail, "saved=1 file=screen8-hostui-1.png")
        // The badge is transient — past the TTL it hides, but the saved
        // record and receipt keep the truth.
        t = t.addingTimeInterval(model.badgeTTL + 0.1)
        XCTAssertFalse(model.savedBadgeVisible)
        XCTAssertEqual(model.badgeRemaining, 0)
        XCTAssertEqual(model.receiptDetail, "saved=1 file=screen8-hostui-1.png")
    }

    /// A second capture refreshes the badge's clock, not a second badge.
    func testASecondSaveReArmsTheBadge() {
        var t = Date()
        let model = HostCaptures()
        model.emit = { _ in }
        model.now = { t }
        model.noteSaved(URL(fileURLWithPath: "/tmp/CAPTURES/a.png"))
        t = t.addingTimeInterval(3)
        model.noteSaved(URL(fileURLWithPath: "/tmp/CAPTURES/b.png"))
        XCTAssertEqual(model.savedCount, 2)
        XCTAssertEqual(model.savedBadgeText, "✓ Saved b.png")
        XCTAssertGreaterThan(model.badgeRemaining, 3)
    }

    // MARK: - the bus wiring

    /// record-stop's landed file flows into the same saved record — the
    /// card's "(and recordings)" half, wired in the bus's init. The
    /// recorder runs on injected seams; the MP4's real writer path is
    /// pinned in HostRecorderTests.
    func testRecordingStopLandsASavedCapture() {
        var lines: [String] = []
        let bus = HostCommandBus { lines.append($0) }
        let share = makeTempDir()
        bus.captures.shareDir = share
        // A 64x36 synthetic frame is enough to start a real writer.
        let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8,
                            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let frame = ctx.makeImage()!
        bus.recorder.frameSource = { frame }
        XCTAssertEqual(bus.recorder.resolvedOutDir()?.path,
                       share.appendingPathComponent("CAPTURES").path)
        XCTAssertEqual(bus.dispatch(.recordStart), .performed)
        XCTAssertEqual(bus.dispatch(.recordStop), .performed)
        XCTAssertEqual(bus.captures.savedCount, 1)
        XCTAssertEqual(bus.captures.lastSaved, bus.recorder.lastFile)
        XCTAssertTrue(lines.contains { $0.hasPrefix("host-cap: saved ") },
                      "a finished take prints the host-cap: line")
    }

    /// The session window's badge mirrors the model — the class-A read
    /// of the visible affordance, TTL expiry driven on the model clock.
    func testSavedBadgeShowsThenExpiresOnTheModelClock() {
        var t = Date()
        let host = HostApplication(serialLog: "/fixture/serial.log", presentWindow: false)
        host.commandBus.captures.now = { t }
        host.commandBus.captures.emit = { _ in }
        XCTAssertFalse(host.savedAffordanceVisible)
        host.commandBus.captures.noteSaved(
            URL(fileURLWithPath: "/tmp/share/CAPTURES/screen8-hostui-1.png"))
        XCTAssertTrue(host.savedAffordanceVisible)
        XCTAssertEqual(host.savedAffordanceText, "✓ Saved screen8-hostui-1.png")
        t = t.addingTimeInterval(10)
        host.syncSavedBadge()
        XCTAssertFalse(host.savedAffordanceVisible)
    }
}
