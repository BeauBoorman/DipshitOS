import AppKit
import AVFoundation
import CoreVideo

/// M114e (#2458, index #2447): bounded (≤60 s) MP4 recording of the guest
/// viewport into `<share>/CAPTURES/` — the `record`/`record-start`/
/// `record-stop` verbs' handler. One instance per bus: HostCommandBus
/// self-registers the verbs onto this recorder in init, so the bare
/// `HostCommandBus()` a scripted `--host-cmd-after` run builds and the
/// session window's bus dispatch the identical seam (index thesis 1) —
/// the M114c registration-side-effect pattern for a card whose Touches
/// exclude main.swift.
///
/// Two things the recorder needs it finds without runner globals:
///
///   - The capture surface: HostApplication.attach hands over the session
///     guest view; a headless run's evidence window is the only window
///     `NSApp` owns, so the view is discovered lazily at dispatch.
///   - The output directory: `<share>/CAPTURES` resolves from the
///     runner's own argv (`--cvc-file <dir>` or `--virtio-fs <dir>`) —
///     the same flags the gate/session already pass, so no new runner
///     flag exists to wire.
///
/// Frames come from `view.cacheDisplay` — the same offscreen render the
/// screenshot verb's fallback uses — NOT ScreenCaptureKit: SCStream
/// needs the TCC Screen Recording grant a class-B host does not carry
/// (the screenshot path's SCK-first/cacheDisplay-fallback split exists
/// precisely because the grant is absent there), and cacheDisplay gives
/// the view's own pixels deterministically rather than whatever the
/// compositor happened to show. A `Timer` on the dispatch queue's run
/// loop (always main — the bus contract) captures at `fps`; a second
/// one-shot timer enforces the hard cap, so a recording can never run
/// unbounded even if its stop verb never fires.
///
/// All access is main-queue (the polls and the bus both are), so the
/// recorder takes no lock — the HostCommandBus precedent.
public final class HostRecorder {

    /// The card's bound: a recording can never exceed this many seconds.
    /// Injectable for tests; production dispatches always see the default.
    public var hardCap: TimeInterval = 60
    /// Capture cadence.
    public var fps: Double = 15
    /// Encoder back-pressure queue depth. A produced frame the input
    /// isn't ready for waits here instead of dropping (#2616: the
    /// observed flake was a produced frame lost to encoder warm-up,
    /// not a stale flag); only a stall sustained past this many
    /// frames drops the oldest. Injectable for tests.
    public var maxQueuedFrames = 8

    /// The session's guest view, set by HostApplication.attach. Weak —
    /// the view lives in the window hierarchy; a nil view simply means
    /// recording is disabled.
    public weak var captureView: NSView?
    /// Test seam: a synthetic frame producer. When set, the recorder
    /// never touches AppKit views or argv — the harness owns both.
    public var frameSource: (() -> CGImage?)?
    /// Test seam: the CAPTURES dir override. nil means "resolve from
    /// argv" (the production path).
    public var outDir: URL?
    /// M120e (#2562): the bus wires this to the captures model so a take
    /// lands where ⌘⇧5 does — `<share>/CAPTURES`, profile share included
    /// (bare argv resolution misses a profile-armed share; a --profile
    /// session's share never appears as a flag). A bare HostRecorder
    /// keeps the argv-only resolution.
    public var capturesSource: (() -> URL?)?
    /// M120e (#2562): fired once per finished take with the on-disk URL —
    /// the bus's captures model turns it into the saved badge + counter,
    /// so a recording is a "capture saved" like a screenshot.
    public var onSaved: ((URL) -> Void)?
    /// Test seam: the wall clock. Timers pace real time; frame PTSs and
    /// the cap check read this so a test can run a whole 60 s recording
    /// synchronously.
    public var now: () -> Date = { Date() }
    /// Model → window: fired on start/stop and each time the whole-second
    /// countdown changes, so the badge stays live without polling.
    public var onChange: (() -> Void)?

    public private(set) var isRecording = false
    /// Frames actually appended to the current/last recording.
    public private(set) var frames = 0
    /// Frames skipped (producer empty or input not ready).
    public private(set) var droppedFrames = 0
    /// The last finished MP4 + its size on disk — the stop receipt's
    /// `frames=`/`bytes=`/`file=` detail comes from these, not from a
    /// guess about what the writer did.
    public private(set) var lastFile: URL?
    public private(set) var lastBytes = 0

    private var startedAt: Date?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outURL: URL?
    private var frameTimer: Timer?
    private var capTimer: Timer?
    /// Produced frames the encoder has not accepted yet — drained by
    /// flushPending() on each append and, bounded, by stop() before the
    /// writer seals, so the receipt's frames= counts what the take
    /// produced, not what the input happened to accept by the tick the
    /// stop dispatch landed on.
    private var pendingFrames: [(buffer: CVPixelBuffer, pts: CMTime)] = []
    private var lastRemainingSecond = -1
    private var sequence = 0

    public init() {}

    // MARK: Discovery — the capture surface and the share.

    /// The view a recording would capture right now: the session's
    /// attached guest view first, then a headless run's sole evidence
    /// window (its contentView IS the machine view). `NSApp` reads as nil
    /// when no NSApplication exists — a bare `swift test` or a pre-window
    /// dispatch simply finds nothing.
    public func resolveView() -> NSView? {
        if let captureView { return captureView }
        return NSApp?.windows.first(where: { $0.contentView != nil })?.contentView
    }

    /// `<share>/CAPTURES` for the runner's armed share. `--cvc-file` is
    /// the custom-virtio file channel; `--virtio-fs` the standard one —
    /// both are "the share" the card names. nil when the run armed
    /// neither — the verb then receipts `disabled`, honestly, rather
    /// than writing somewhere the card never promised.
    public static func capturesDir(arguments: [String] = CommandLine.arguments) -> URL? {
        for flag in ["--cvc-file", "--virtio-fs"] {
            if let i = arguments.firstIndex(of: flag), i + 1 < arguments.count {
                return URL(fileURLWithPath: arguments[i + 1])
                    .appendingPathComponent("CAPTURES", isDirectory: true)
            }
        }
        return nil
    }

    /// The CAPTURES dir a start would write into, honoring the test
    /// override, then the bus's captures model (the profile-share-aware
    /// resolver), then argv.
    public func resolvedOutDir() -> URL? {
        outDir ?? capturesSource?() ?? HostRecorder.capturesDir()
    }

    /// What `isEnabled` reports: a recording already running stays
    /// startable/stoppable even if the view or share went away mid-take;
    /// an idle recorder needs both a surface and a share.
    public var canStart: Bool {
        isRecording || (resolveView() != nil || frameSource != nil) && resolvedOutDir() != nil
    }

    /// Seconds of cap left, for the badge and the `recording=on` receipt.
    public var remaining: Int {
        guard isRecording, let startedAt else { return 0 }
        return max(0, Int((hardCap - now().timeIntervalSince(startedAt)).rounded(.up)))
    }

    /// The `host-ui:` receipt detail — the post-action truth the gate
    /// reads: `recording=on remaining=N` mid-take; `recording=off
    /// frames=F bytes=B file=<name>` after a stop (actuals, not intent).
    public var receiptDetail: String? {
        if isRecording {
            return "recording=on remaining=\(remaining)s"
        }
        if let lastFile {
            return "recording=off frames=\(frames) bytes=\(lastBytes) file=\(lastFile.lastPathComponent)"
        }
        return "recording=off"
    }

    // MARK: The verbs.

    /// `record` — the ⌘⇧6 chord's toggle.
    @discardableResult
    public func toggle() -> HostCommandBus.Outcome {
        isRecording ? stop() : start()
    }

    /// `record-start` — idempotent: starting a running take is a
    /// performed no-op, not an error.
    @discardableResult
    public func start() -> HostCommandBus.Outcome {
        guard !isRecording else { return .performed }
        guard canStart, let dir = resolvedOutDir() else { return .disabled }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardOutput.write(Data("host-rec: cannot create \(dir.path): \(error)\n".utf8))
            return .failed
        }
        // Frame 0 configures the writer — the MP4's dimensions are the
        // capture's real pixel size (retina hosts render 2×), not a
        // guessed 1280×720. No first frame = nothing to record = failed,
        // not an empty MP4.
        guard let first = produceFrame() else {
            FileHandle.standardOutput.write(Data("host-rec: no frame produced — capture surface is not rendering\n".utf8))
            return .failed
        }
        sequence += 1
        let url = dir.appendingPathComponent(String(format: "capture-%@-%02d.mp4", timestamp(), sequence))
        do {
            try beginWriter(to: url, width: first.width, height: first.height)
        } catch {
            FileHandle.standardOutput.write(Data("host-rec: writer failed to start: \(error)\n".utf8))
            return .failed
        }
        startedAt = now()
        frames = 0
        droppedFrames = 0
        pendingFrames.removeAll()
        outURL = url
        isRecording = true
        append(first, at: .zero)
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            self?.captureFrame()
        }
        // The hard cap is its own timer — a stop verb that never fires
        // still leaves a bounded take, never an unbounded file.
        capTimer = Timer.scheduledTimer(withTimeInterval: hardCap, repeats: false) { [weak self] _ in
            self?.stop()
        }
        lastRemainingSecond = remaining
        changed()
        return .performed
    }

    /// `record-stop` — the cap timer lands here too. markAsFinished +
    /// finishWriting are awaited (bounded) so the receipt's bytes= is the
    /// real on-disk size of a COMPLETE mp4 — the gate's ftyp read never
    /// races the moov write.
    @discardableResult
    public func stop() -> HostCommandBus.Outcome {
        guard isRecording else { return .disabled }
        isRecording = false
        frameTimer?.invalidate()
        capTimer?.invalidate()
        frameTimer = nil
        capTimer = nil
        // Drain produced frames the input hasn't accepted yet so the
        // receipt's frames= is the take's real count — the encoder
        // drains on its own threads, so bounded polling catches the
        // warm-up lag; leftovers past the bound count as dropped,
        // honestly.
        var drained = 0.0
        while !pendingFrames.isEmpty, drained < 5 {
            flushPending()
            if !pendingFrames.isEmpty {
                Thread.sleep(forTimeInterval: 0.01)
                drained += 0.01
            }
        }
        droppedFrames += pendingFrames.count
        pendingFrames.removeAll()
        writerInput?.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer?.finishWriting { done.signal() }
        _ = done.wait(timeout: .now() + 5)
        if let outURL {
            lastFile = outURL
            lastBytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
            onSaved?(outURL)
        }
        writer = nil
        writerInput = nil
        adaptor = nil
        changed()
        return .performed
    }

    /// The frame timer's body — public so tests drive frames
    /// synchronously instead of sleeping on a run loop.
    public func captureFrame() {
        guard isRecording else { return }
        if let startedAt, now().timeIntervalSince(startedAt) >= hardCap {
            stop()
            return
        }
        guard let cg = produceFrame() else {
            flushPending()
            droppedFrames += 1
            return
        }
        guard let startedAt else { return }
        append(cg, at: CMTime(seconds: now().timeIntervalSince(startedAt), preferredTimescale: 600))
        let r = remaining
        if r != lastRemainingSecond {
            lastRemainingSecond = r
            changed()
        }
    }

    // MARK: Internals.

    private func changed() { onChange?() }

    private func produceFrame() -> CGImage? {
        if let frameSource { return frameSource() }
        guard let view = resolveView(),
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: now())
    }

    private func beginWriter(to url: URL, width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        // Real-time pacing: produced frames queue briefly while the
        // encoder drains, and only a stall sustained past
        // maxQueuedFrames drops the oldest — never unbounded queueing.
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ])
        guard writer.canAdd(input) else {
            throw NSError(domain: "HostRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter refused the video input"])
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "HostRecorder", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter.startWriting failed"])
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.writerInput = input
        self.adaptor = adaptor
    }

    private func append(_ image: CGImage, at pts: CMTime) {
        guard let adaptor, let writerInput else { return }
        guard let pb = pixelBuffer(from: image, pool: adaptor.pixelBufferPool) else {
            droppedFrames += 1
            return
        }
        pendingFrames.append((pb, pts))
        while pendingFrames.count > maxQueuedFrames {
            pendingFrames.removeFirst()
            droppedFrames += 1
        }
        flushPending()
    }

    /// Hand queued frames to the writer while it will take them. The
    /// input is real-time paced (`expectsMediaDataInRealTime`), so
    /// readiness lags a burst of produced frames — the queue absorbs
    /// that lag instead of losing frames the take actually produced.
    private func flushPending() {
        guard let adaptor, let writerInput else { return }
        while writerInput.isReadyForMoreMediaData, let next = pendingFrames.first {
            pendingFrames.removeFirst()
            if adaptor.append(next.buffer, withPresentationTime: next.pts) {
                frames += 1
            } else {
                droppedFrames += 1
            }
        }
    }

    /// CGImage → 32BGRA CVPixelBuffer, drawn into the pool's buffer when
    /// one is available (IOSurface-backed — what the encoder wants) and a
    /// plain one otherwise.
    private func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        let w = image.width, h = image.height
        var pb: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        }
        if pb == nil {
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        }
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue:
                                      CGImageAlphaInfo.premultipliedFirst.rawValue |
                                      CGBitmapInfo.byteOrder32Little.rawValue).rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pb
    }
}
