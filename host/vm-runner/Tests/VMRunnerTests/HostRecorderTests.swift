import AppKit
import XCTest
import VMAppKit

/// M114e (#2458): the recorder's state machine, receipts, argv share
/// resolution and the real AVAssetWriter pipeline — class-A (no VM), with
/// frameSource/outDir/now injected so a whole bounded take runs
/// synchronously and the MP4 it lands is checked for a real ftyp header.
final class HostRecorderTests: XCTestCase {
    private final class Sink {
        var lines: [String] = []
    }

    /// The hand-advanced wall clock a test injects into `recorder.now`.
    private final class Clock {
        var now = Date()
        func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
    }

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
            .appendingPathComponent("hostrec-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeFrame(width: Int = 64, height: Int = 36) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// A bus whose recorder has every outside seam injected: synthetic
    /// frames, a temp CAPTURES dir, and the clock the test advances.
    private func makeBus(_ sink: Sink, clock: Clock) -> HostCommandBus {
        let bus = HostCommandBus { sink.lines.append($0) }
        let frame = makeFrame()
        bus.recorder.frameSource = { frame }
        bus.recorder.outDir = makeTempDir()
        bus.recorder.now = { clock.now }
        return bus
    }

    func testCapturesDirResolvesTheShareFlags() {
        XCTAssertEqual(
            HostRecorder.capturesDir(arguments: ["vmrunner", "--cvc-file", "/tmp/share"])?.path,
            "/tmp/share/CAPTURES")
        XCTAssertEqual(
            HostRecorder.capturesDir(arguments: ["vmrunner", "--virtio-fs", "/tmp/vfs"])?.path,
            "/tmp/vfs/CAPTURES")
        // --cvc-file wins when both are armed.
        XCTAssertEqual(
            HostRecorder.capturesDir(arguments: ["vmrunner", "--virtio-fs", "/v", "--cvc-file", "/c"])?.path,
            "/c/CAPTURES")
        XCTAssertNil(HostRecorder.capturesDir(arguments: ["vmrunner", "--screen", "/tmp/s"]))
        XCTAssertNil(HostRecorder.capturesDir(arguments: ["vmrunner", "--cvc-file"]))
    }

    func testBusSelfRegistersTheRecordVerbs() {
        let bus = HostCommandBus { _ in }
        for verb in [HostCommand.record, .recordStart, .recordStop] {
            XCTAssertTrue(bus.isRegistered(verb), "\(verb.rawValue) must be a bus verb")
        }
    }

    func testRecordIsDisabledWithoutAShare() {
        let sink = Sink()
        let bus = HostCommandBus { sink.lines.append($0) }
        // No --cvc-file in the test runner's argv, no view — the verb
        // refuses honestly rather than writing somewhere the card never
        // promised.
        XCTAssertEqual(bus.dispatch(.record), .disabled)
        XCTAssertEqual(bus.dispatch(.recordStart), .disabled)
        XCTAssertEqual(sink.lines, [
            "host-ui: cmd=record state=disabled recording=off",
            "host-ui: cmd=record-start state=disabled recording=off",
        ])
    }

    func testRecordStopWhileIdleIsDisabled() {
        let sink = Sink()
        let bus = HostCommandBus { sink.lines.append($0) }
        XCTAssertEqual(bus.dispatch(.recordStop), .disabled)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=record-stop state=disabled recording=off"])
    }

    func testToggleWritesARealMp4() throws {
        let clock = Clock()
        let sink = Sink()
        let bus = makeBus(sink, clock: clock)

        XCTAssertEqual(bus.dispatch(.record), .performed)
        XCTAssertEqual(sink.lines.last, "host-ui: cmd=record state=performed recording=on remaining=60s")
        // Four more frames worth of wall time at the 15 fps cadence.
        for _ in 0..<4 { clock.advance(1.0 / 15); bus.recorder.captureFrame() }
        XCTAssertEqual(bus.dispatch(.record), .performed)  // toggle stops
        guard let line = sink.lines.last else { return XCTFail("no receipt") }
        XCTAssertTrue(line.hasPrefix("host-ui: cmd=record state=performed recording=off frames=5 bytes="), line)
        XCTAssertTrue(line.contains(" file=capture-"), line)
        XCTAssertTrue(line.hasSuffix(".mp4"), line)
        // Produced frames queue through encoder back-pressure — none is
        // lost to the input's momentary not-ready during warm-up (#2616).
        XCTAssertEqual(bus.recorder.droppedFrames, 0)
        let file = try XCTUnwrap(bus.recorder.lastFile)
        XCTAssertGreaterThan(bus.recorder.lastBytes, 0)
        let head = try Data(contentsOf: file).prefix(12)
        XCTAssertEqual(head[4..<8], Data("ftyp".utf8), "the MP4 must start with an ftyp box")
        // A second take gets a distinct filename.
        XCTAssertEqual(bus.dispatch(.recordStart), .performed)
        XCTAssertEqual(bus.dispatch(.recordStop), .performed)
        XCTAssertNotEqual(bus.recorder.lastFile, file)
    }

    func testRecordStartIsIdempotentWhileRecording() {
        let clock = Clock()
        let sink = Sink()
        let bus = makeBus(sink, clock: clock)
        XCTAssertEqual(bus.dispatch(.recordStart), .performed)
        // A second record-start is a performed no-op, not a second writer.
        XCTAssertEqual(bus.dispatch(.recordStart), .performed)
        XCTAssertTrue(bus.recorder.isRecording)
        XCTAssertEqual(bus.dispatch(.recordStop), .performed)
        XCTAssertFalse(bus.recorder.isRecording)
    }

    func testHardCapStopsTheTakeItself() {
        let clock = Clock()
        let sink = Sink()
        let bus = makeBus(sink, clock: clock)
        bus.recorder.hardCap = 2
        XCTAssertEqual(bus.recorder.start(), .performed)
        // Tick past the cap: the frame path itself enforces the bound —
        // even if the cap timer never fired (a run loop that stopped
        // pumping), the take cannot run unbounded.
        clock.advance(3)
        bus.recorder.captureFrame()
        XCTAssertFalse(bus.recorder.isRecording)
        XCTAssertEqual(bus.recorder.frames, 1)  // only the t=0 frame made it
        XCTAssertGreaterThan(bus.recorder.lastBytes, 0)
    }

    func testCountdownReportsWholeSecondsLeft() {
        let clock = Clock()
        let sink = Sink()
        let bus = makeBus(sink, clock: clock)
        XCTAssertEqual(bus.recorder.start(), .performed)
        XCTAssertEqual(bus.recorder.remaining, 60)
        clock.advance(20)
        bus.recorder.captureFrame()
        XCTAssertEqual(bus.recorder.remaining, 40)
        XCTAssertEqual(bus.recorder.receiptDetail, "recording=on remaining=40s")
        bus.recorder.stop()
    }

    func testDroppedFramesAreCounted() {
        let clock = Clock()
        let sink = Sink()
        let bus = makeBus(sink, clock: clock)
        var produce = true
        let frame = makeFrame()
        bus.recorder.frameSource = { produce ? frame : nil }
        _ = bus.recorder.start()
        produce = false
        bus.recorder.captureFrame()
        XCTAssertEqual(bus.recorder.droppedFrames, 1)
        XCTAssertEqual(bus.recorder.stop(), .performed)
    }

    func testRecordingBadgeFollowsTheRecorder() {
        let host = HostApplication(serialLog: "/fixture/serial.log", presentWindow: false)
        let recorder = host.commandBus.recorder
        let frame = makeFrame()
        recorder.frameSource = { frame }
        recorder.outDir = makeTempDir()
        XCTAssertFalse(host.recordAffordanceVisible)
        XCTAssertEqual(host.commandBus.dispatch(.record), .performed)
        XCTAssertTrue(host.recordAffordanceVisible)
        XCTAssertEqual(host.recordAffordanceText, "● REC 60s")
        XCTAssertEqual(host.commandBus.dispatch(.recordStop), .performed)
        XCTAssertFalse(host.recordAffordanceVisible)
    }
}
