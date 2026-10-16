// Issue #2349 — pins the `:relay` responder's upstream plumbing. Runs
// WITHOUT a VM (VMTcp is pure Swift/Foundation; the "upstream" is a real
// loopback socket and guest-bound frames are captured through the
// injected `onFrame` sink).
//
// The two bugs this locks out, both observed live and worked around by
// M101a (#2313) and M107d (#2321):
//   * inbound starvation past ~1460 B: a stale (retransmitted) guest ack
//     permanently retreated the pump's equality gate, and the pump ran
//     one ≤192 B chunk per ACK at multi-second guest RTTs;
//   * retransmitted guest segments re-written to the upstream socket —
//     flintd saw every request twice.
import XCTest
@testable import VMTcp

final class NetTcpRelayTests: XCTestCase {
    let hostMAC: [UInt8] = [0x02, 0, 0, 0, 0, 0x02]
    let guestMAC: [UInt8] = [0x02, 0, 0, 0, 0, 0x01]
    let hostIP: [UInt8] = [10, 0, 0, 2]
    let guestIP: [UInt8] = [10, 0, 0, 2] // direction is encoded in the frame; contents are opaque to the relay
    let hostPort: UInt16 = 4748
    let guestPort: UInt16 = 8000
    let serverIsn: UInt32 = 0x12345678
    let guestIsn: UInt32 = 0x54321098

    private var frames: [[UInt8]] = []
    private var framesLock = NSLock()
    private var relayLogs: [String] = []
    private var logsLock = NSLock()

    private func makeRelay() -> NetTcpRelay {
        frames = []
        relayLogs = []
        let relay = NetTcpRelay()
        relay.hostMAC = hostMAC
        relay.hostPort = hostPort
        relay.serverIsn = serverIsn
        relay.onFrame = { frame in
            self.framesLock.lock()
            self.frames.append(frame)
            self.framesLock.unlock()
        }
        relay.onLog = { line in
            self.logsLock.lock()
            self.relayLogs.append(line)
            self.logsLock.unlock()
        }
        return relay
    }

    private var frameCount: Int {
        framesLock.lock()
        defer { framesLock.unlock() }
        return frames.count
    }

    private func frame(at i: Int) -> [UInt8] {
        framesLock.lock()
        defer { framesLock.unlock() }
        return frames[i]
    }

    private func logged(matching needle: String) -> Bool {
        logsLock.lock()
        defer { logsLock.unlock() }
        return relayLogs.contains { $0.contains(needle) }
    }

    /// A guest SYN carrying an MSS option (data offset 6) — the shape the
    /// guest kernel originates (kernel/src/tcp.zig `mss_option`).
    private func syn(mss: UInt16? = 1460, wnd: UInt16 = 1460) -> [UInt8] {
        var f = [UInt8]()
        _ = buildTcpFrameExplicit(&f, hostMAC, guestMAC, guestIP, hostIP, guestPort, hostPort, guestIsn, 0, 0x02, [])
        guard let mss else { return f }
        // Room for the 4-byte MSS option; bump the data offset to 6.
        f[46] = 0x60
        f[48] = UInt8(wnd >> 8)
        f[49] = UInt8(wnd & 0xff)
        f += [2, 4, UInt8(mss >> 8), UInt8(mss & 0xff)]
        return f
    }

    /// A guest data/ack segment (doff 5, ACK flag always on).
    private func seg(seq: UInt32, ack: UInt32, wnd: UInt16 = 1460, flags: UInt8 = 0x10, payload: [UInt8] = []) -> [UInt8] {
        var f = [UInt8]()
        let n = buildTcpFrameExplicit(&f, hostMAC, guestMAC, guestIP, hostIP, guestPort, hostPort, seq, ack, flags, payload)
        f[48] = UInt8(wnd >> 8)
        f[49] = UInt8(wnd & 0xff)
        return Array(f[0..<n])
    }

    /// Payload of an emitted guest-bound frame (the relay never sends
    /// options — data offset is 5).
    private func payload(of frame: [UInt8]) -> [UInt8] {
        XCTAssertEqual(frame[46] >> 4, 5)
        return Array(frame[54...])
    }

    private func waitFor(_ seconds: Double = 5.0, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return cond()
    }

    /// A real loopback listener on an ephemeral port; starts the relay
    /// against it and returns the accepted upstream fd.
    private func upstream(_ relay: NetTcpRelay) throws -> Int32 {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listener, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(listener, 1), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var actual = sockaddr_in()
        withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = getsockname(listener, sa, &len)
            }
        }
        relay.start("127.0.0.1", UInt16(bigEndian: actual.sin_port))
        let up = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(up, 0)
        close(listener)
        return up
    }

    private func writeUpstream(_ fd: Int32, _ bytes: [UInt8]) {
        let n = bytes.withUnsafeBufferPointer { p in write(fd, p.baseAddress, p.count) }
        XCTAssertEqual(n, bytes.count)
    }

    /// Read exactly `count` bytes from a blocking fd (bounded spin — the
    /// relay writes guest data synchronously).
    private func readUpstream(_ fd: Int32, _ count: Int) -> [UInt8] {
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: max(1, count))
        let deadline = Date().addingTimeInterval(5)
        while out.count < count, Date() < deadline {
            let n = read(fd, &buf, buf.count)
            if n > 0 { out += buf[0..<n] } else { Thread.sleep(forTimeInterval: 0.005) }
        }
        return out
    }

    private func noUpstreamBytes(_ fd: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&pfd, 1, 50) == 0
    }

    // #2349 bug 1, part A — the inbound cliff. A 4000-byte upstream
    // response must reach the guest as MSS-bounded, window-paced,
    // in-order segments: nothing before the handshake ACK, ≤1460 per
    // segment, and never more than the advertised window in flight.
    func testLargeResponseFlowsMSSPacedAndWindowBounded() throws {
        let relay = makeRelay()
        relay.begin(synFrame: syn(mss: 1460, wnd: 1460), 58)
        let up = try upstream(relay)
        defer { close(up); relay.shutdown() }

        let response = (0..<4000).map { UInt8($0 % 251) }
        writeUpstream(up, response)
        // Nothing may go out before the guest ACKs the SYN-ACK — the
        // guest's syn_sent state would drop it unrecoverably.
        XCTAssertFalse(waitFor(0.3) { self.frameCount > 0 })

        // Window 0 first: even an acked SYN-ACK opens nothing.
        XCTAssertFalse(relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn + 1, wnd: 0), 54))
        _ = relay.pump()
        XCTAssertEqual(frameCount, 0)

        // The real window update opens 1460 bytes: one MSS segment goes.
        XCTAssertFalse(relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn + 1, wnd: 1460), 54))
        _ = relay.pump()
        XCTAssertTrue(waitFor { self.frameCount == 1 })
        XCTAssertEqual(payload(of: frame(at: 0)), Array(response[0..<1460]))
        XCTAssertEqual(tcpSeq(frame(at: 0)), serverIsn + 1)
        XCTAssertEqual(tcpAck(frame(at: 0)), guestIsn + 1)

        // Each ACK refills the window; the whole response lands verbatim.
        _ = relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn + 1 + 1460, wnd: 1460), 54)
        _ = relay.pump()
        XCTAssertTrue(waitFor { self.frameCount == 2 })
        XCTAssertEqual(payload(of: frame(at: 1)), Array(response[1460..<2920]))
        _ = relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn + 1 + 2920, wnd: 1460), 54)
        _ = relay.pump()
        XCTAssertTrue(waitFor { self.frameCount == 3 })
        XCTAssertEqual(payload(of: frame(at: 2)), Array(response[2920..<4000]))
    }

    // #2349 bug 1, part B — the observed deadlock: a retransmitted guest
    // segment's stale ack must not retreat the pump's ack state. This is
    // the sequence that starved flintd's >MTU read response.
    func testStaleRetransmittedAckCannotStallThePump() throws {
        let relay = makeRelay()
        relay.begin(synFrame: syn(), 58)
        let up = try upstream(relay)
        defer { close(up); relay.shutdown() }

        // The guest's request is delivered upstream once.
        let request = Array("{\"op\":\"read\"}".utf8)
        let req = seg(seq: guestIsn + 1, ack: serverIsn + 1, payload: request)
        XCTAssertEqual(relay.guestDataSegment(req, req.count), .forwarded(fresh: request.count))
        XCTAssertEqual(readUpstream(up, request.count), request)

        let response = (0..<3000).map { UInt8($0 % 253) }
        writeUpstream(up, response)
        _ = relay.guestAckSegment(seg(seq: guestIsn + 1 + UInt32(request.count), ack: serverIsn + 1, wnd: 1460), 54)
        _ = relay.pump()
        XCTAssertTrue(waitFor { self.frameCount == 1 }) // one window's worth

        // The guest's retransmitted request lands — its ack field is the
        // STALE value. Under the old code this overwrote the pump's
        // expected-ack forever and the guest never saw another byte; now
        // it is deduplicated AND moves no pump state.
        XCTAssertEqual(relay.guestDataSegment(req, req.count), .duplicate)
        _ = relay.pump()
        XCTAssertTrue(noUpstreamBytes(up))

        // The guest's next real ACK still releases the next window —
        // proof the stale pair was ignored.
        _ = relay.guestAckSegment(seg(seq: guestIsn + 1 + UInt32(request.count), ack: serverIsn + 1 + 1460, wnd: 1460), 54)
        _ = relay.pump()
        XCTAssertTrue(waitFor { self.frameCount == 2 })
        XCTAssertEqual(payload(of: frame(at: 1)), Array(response[1460..<2920]))
        _ = relay.guestAckSegment(seg(seq: guestIsn + 1 + UInt32(request.count), ack: serverIsn + 1 + 2920, wnd: 1460), 54)
        _ = relay.pump()
        XCTAssertTrue(waitFor { self.frameCount == 3 })
        XCTAssertEqual(payload(of: frame(at: 2)), Array(response[2920..<3000]))
    }

    // #2349 bug 2 — retransmit dedup on the guest->upstream direction.
    func testRetransmittedGuestSegmentWritesUpstreamOnce() throws {
        let relay = makeRelay()
        relay.begin(synFrame: syn(), 58)
        let up = try upstream(relay)
        defer { close(up); relay.shutdown() }
        _ = relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn + 1), 54)

        let request = Array("{\"op\":\"append\",\"changes\":[]}".utf8)
        let seg1 = seg(seq: guestIsn + 1, ack: serverIsn + 1, payload: request)
        XCTAssertEqual(relay.guestDataSegment(seg1, seg1.count), .forwarded(fresh: request.count))
        XCTAssertEqual(readUpstream(up, request.count), request)

        // The byte-identical retransmit must write nothing more.
        XCTAssertEqual(relay.guestDataSegment(seg1, seg1.count), .duplicate)
        XCTAssertTrue(noUpstreamBytes(up))
        XCTAssertEqual(relay.currentSeqAck().ack, guestIsn + 1 + UInt32(request.count))
        XCTAssertTrue(logged(matching: "deduplicated"))

        // Partial overlap: a retransmit covering 100 already-delivered
        // bytes + 50 fresh ones forwards only the fresh suffix.
        let covered = [UInt8](repeating: 0x58, count: 150)
        let coveredSeq = guestIsn + 1 + UInt32(request.count) - 100
        let coveredSeg = seg(seq: coveredSeq, ack: serverIsn + 1, payload: covered)
        XCTAssertEqual(relay.guestDataSegment(coveredSeg, coveredSeg.count), .forwarded(fresh: 50))
        XCTAssertEqual(readUpstream(up, 50), Array(covered[100..<150]))
    }

    // An ahead-of-bound segment is dropped named — the relay cannot
    // reorder the upstream byte stream, and the honest ack (the in-order
    // bound, not seq+len) is what makes the guest retransmit the gap.
    func testOutOfOrderGuestSegmentIsDroppedNotForwarded() throws {
        let relay = makeRelay()
        relay.begin(synFrame: syn(), 58)
        let up = try upstream(relay)
        defer { close(up); relay.shutdown() }
        _ = relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn + 1), 54)

        let ahead = seg(seq: guestIsn + 501, ack: serverIsn + 1, payload: [UInt8](repeating: 0x7a, count: 60))
        XCTAssertEqual(relay.guestDataSegment(ahead, ahead.count), .gap)
        XCTAssertTrue(noUpstreamBytes(up))
        XCTAssertEqual(relay.currentSeqAck().ack, guestIsn + 1) // did not overstate
        XCTAssertTrue(logged(matching: "ahead of the in-order bound"))
    }

    // #2366 — a segment whose seq sits exactly 2^31 from the in-order
    // bound computes rel == Int32.min either way; negating that used to
    // SIGTRAP the whole runner. Both directions are .gap, and the legs
    // one byte inside each edge keep their old meaning — ahead stays
    // .gap, behind stays a wholly-covered retransmit (.duplicate).
    func testSeqAtInt32MinOffsetIsAGapNotATrap() throws {
        let relay = makeRelay()
        relay.begin(synFrame: syn(), 58)
        let up = try upstream(relay)
        defer { close(up); relay.shutdown() }
        _ = relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn + 1), 54)
        let bound = guestIsn &+ 1 // rcvNxt after begin

        // Exactly 2^31 ahead of the bound: rel == Int32.min — the old trap.
        let ahead31 = seg(seq: bound &+ 0x8000_0000, ack: serverIsn + 1, payload: [UInt8](repeating: 0x61, count: 10))
        XCTAssertEqual(relay.guestDataSegment(ahead31, ahead31.count), .gap)

        // Exactly 2^31 behind is the same wrapped delta — also .gap.
        let behind31 = seg(seq: bound &- 0x8000_0000, ack: serverIsn + 1, payload: [UInt8](repeating: 0x61, count: 10))
        XCTAssertEqual(relay.guestDataSegment(behind31, behind31.count), .gap)

        // One byte inside each edge: 2^31-1 ahead is still a gap;
        // 2^31-1 behind is a retransmit the dedup path already covers.
        let aheadEdge = seg(seq: bound &+ 0x7FFF_FFFF, ack: serverIsn + 1, payload: [UInt8](repeating: 0x61, count: 10))
        XCTAssertEqual(relay.guestDataSegment(aheadEdge, aheadEdge.count), .gap)
        let behindEdge = seg(seq: bound &- 0x7FFF_FFFF, ack: serverIsn + 1, payload: [UInt8](repeating: 0x61, count: 10))
        XCTAssertEqual(relay.guestDataSegment(behindEdge, behindEdge.count), .duplicate)

        // None of it went upstream, and the in-order bound never moved.
        XCTAssertTrue(noUpstreamBytes(up))
        XCTAssertEqual(relay.currentSeqAck().ack, bound)
        XCTAssertTrue(logged(matching: "ahead of the in-order bound"))
    }

    // Upstream EOF propagates as FIN once the buffered bytes drain.
    func testUpstreamCloseDeliversBufferedBytesThenFin() throws {
        let relay = makeRelay()
        relay.begin(synFrame: syn(), 58)
        let up = try upstream(relay)
        let response = (0..<2000).map { UInt8($0 % 241) }
        writeUpstream(up, response)
        close(up) // upstream is done: EOF

        _ = relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn + 1, wnd: 4096), 54)
        _ = relay.pump()
        XCTAssertTrue(waitFor { self.frameCount == 3 }) // 1460 + 540 + FIN
        XCTAssertEqual(payload(of: frame(at: 0)), Array(response[0..<1460]))
        XCTAssertEqual(payload(of: frame(at: 1)), Array(response[1460..<2000]))
        XCTAssertEqual(tcpFlags(frame(at: 2)) & 0x11, 0x11) // FIN+ACK
        // The FIN is emitted once.
        _ = relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn + 1 + 2001, wnd: 4096), 54)
        _ = relay.pump()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(frameCount, 3)
    }

    // Named refusal: guest data for a relay whose upstream never
    // connected is an RST, not a silent sink.
    func testGuestDataWithNoUpstreamIsReset() {
        let relay = makeRelay()
        relay.begin(synFrame: syn(), 58)
        let data = seg(seq: guestIsn + 1, ack: serverIsn + 1, payload: [UInt8](repeating: 0x62, count: 10))
        XCTAssertEqual(relay.guestDataSegment(data, data.count), .dead)
        XCTAssertEqual(frameCount, 1)
        XCTAssertEqual(tcpFlags(frame(at: 0)) & 0x14, 0x14) // RST+ACK
        XCTAssertTrue(relay.isDead)
    }

    // The relay has no retransmission: when the guest keeps emitting
    // segments that acknowledge nothing new while bytes are in flight
    // (the dropped-segment signature), the stream is unrecoverable — the
    // relay says so with an RST at the stall bound instead of parking
    // the guest until ETIMEDOUT.
    func testUnacknowledgedInFlightBytesEventuallyReset() throws {
        let relay = makeRelay()
        relay.begin(synFrame: syn(), 58)
        let up = try upstream(relay)
        defer { close(up); relay.shutdown() }
        writeUpstream(up, [UInt8](repeating: 0x63, count: 100))
        _ = relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn + 1, wnd: 1460), 54)
        _ = relay.pump()
        XCTAssertTrue(waitFor { self.frameCount == 1 })

        // stallLimit unchanged-ack segments while 100 bytes are in flight.
        var killed = false
        for _ in 0..<NetTcpRelay.stallLimit {
            killed = relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn + 1, wnd: 0), 54)
        }
        XCTAssertTrue(killed)
        XCTAssertTrue(logged(matching: "cannot retransmit"))
        XCTAssertEqual(tcpFlags(frame(at: frameCount - 1)) & 0x14, 0x14)
    }

    // #2369 — death is a teardown, not a leak: the stall-RST path shuts
    // the upstream fd down in the same call, so the accepted server
    // side reads EOF instead of holding a live connection that only an
    // unrelated SYN purge would ever reap.
    func testDeadRelayClosesTheUpstream() throws {
        let relay = makeRelay()
        relay.begin(synFrame: syn(), 58)
        let up = try upstream(relay)
        defer { close(up); relay.shutdown() }
        writeUpstream(up, [UInt8](repeating: 0x63, count: 100))
        _ = relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn + 1, wnd: 1460), 54)
        _ = relay.pump()
        XCTAssertTrue(waitFor { self.frameCount == 1 })

        var killed = false
        for _ in 0..<NetTcpRelay.stallLimit {
            killed = relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn + 1, wnd: 0), 54)
        }
        XCTAssertTrue(killed)
        XCTAssertTrue(relay.isDead)

        // The fd was shut the moment the RST went out — the server side
        // (which the relay never wrote to, so POLLIN can only be the
        // close) reads EOF within the bound.
        XCTAssertTrue(waitFor {
            var pfd = pollfd(fd: up, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { return false }
            var one: [UInt8] = [0]
            return read(up, &one, 1) == 0
        })
    }

    // #2368 — the tx buffer is bounded: with the guest's window shut,
    // the reader parks at the high-water mark and the backpressure
    // lands on the upstream socket's own TCP window instead of host
    // RAM. Opening the guest's window drains below the low-water mark
    // and reads (and upstream writes) resume.
    func testTxHighWaterBackpressuresUpstream() throws {
        let relay = makeRelay()
        relay.begin(synFrame: syn(mss: 1460, wnd: 0), 58)
        let up = try upstream(relay)
        defer { close(up); relay.shutdown() }
        // Handshake ACK, window still shut: nothing may drain.
        _ = relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn + 1, wnd: 0), 54)
        _ = relay.pump()
        XCTAssertEqual(frameCount, 0)

        // Non-blocking upstream writes feed the staging buffer until
        // it sits at the cap. The buffer bound is asserted on
        // pendingUpstreamBytes itself — the kernel's send-buffer size
        // is autotuned and proves nothing on its own.
        let fl = fcntl(up, F_GETFL, 0)
        XCTAssertEqual(fcntl(up, F_SETFL, fl | O_NONBLOCK), 0)
        let chunk = [UInt8](repeating: 0x41, count: 8192)
        var total = 0
        XCTAssertTrue(waitFor(15) {
            let n = chunk.withUnsafeBufferPointer { Darwin.write(up, $0.baseAddress, $0.count) }
            if n > 0 { total += n }
            return relay.pendingUpstreamBytes >= NetTcpRelay.txHighWater
        })
        XCTAssertGreaterThanOrEqual(total, NetTcpRelay.txHighWater)
        // Bounded: the cap plus at most one in-flight read — never the
        // unbounded growth of #2368. The reader names it on the log.
        XCTAssertLessThan(relay.pendingUpstreamBytes, NetTcpRelay.txHighWater + 8192)
        XCTAssertTrue(waitFor { self.logged(matching: "high-water") })

        // And it stays there: nothing drains with the window shut, so
        // a parked reader takes no more bytes from the socket.
        let parked = relay.pendingUpstreamBytes
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(relay.pendingUpstreamBytes, parked)

        // The window opens: each ACK'd window drains a chunk of the
        // buffer; once pending drops below the low-water mark the
        // reader un-parks and upstream bytes flow again. The guest
        // ACKs exactly send-next each leg (currentSeqAck's seq).
        var resumed = false
        for _ in 0..<12 {
            _ = relay.guestAckSegment(seg(seq: guestIsn + 1, ack: relay.currentSeqAck().seq, wnd: 0xFFFF), 54)
            _ = relay.pump()
            if relay.pendingUpstreamBytes < NetTcpRelay.txLowWater {
                let drained = relay.pendingUpstreamBytes
                _ = chunk.withUnsafeBufferPointer { Darwin.write(up, $0.baseAddress, $0.count) }
                resumed = waitFor(2, { relay.pendingUpstreamBytes > drained })
                break
            }
        }
        XCTAssertTrue(resumed)
        XCTAssertGreaterThan(frameCount, 0)
    }

    // #2377 — an ACK for bytes never sent earns no credit: send credit
    // stays bounded by the advertised window, not the ack's altitude.
    // Unclamped, ~2^30 ahead would have released the whole buffered
    // response in one go.
    func testAckBeyondSendNextEarnsNoCredit() throws {
        let relay = makeRelay()
        relay.begin(synFrame: syn(), 58)
        let up = try upstream(relay)
        defer { close(up); relay.shutdown() }
        let response = (0..<4000).map { UInt8($0 % 251) }
        writeUpstream(up, response)

        // The handshake ACK claims ~2^30 bytes past send-next. Clamped,
        // the advertised window still bounds: one 1460-byte segment.
        _ = relay.guestAckSegment(seg(seq: guestIsn + 1, ack: serverIsn &+ 1 &+ 0x4000_0000, wnd: 1460), 54)
        _ = relay.pump()
        XCTAssertTrue(waitFor { self.frameCount == 1 })
        XCTAssertEqual(payload(of: frame(at: 0)), Array(response[0..<1460]))
        _ = relay.pump()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(frameCount, 1)
        XCTAssertTrue(logged(matching: "past send-next"))
    }

    // #2377 — connect failure is an immediate named RST, not a dead
    // relay the guest only discovers on its next data segment (and
    // server-speaks-first protocols would never get that far).
    func testConnectFailureEmitsReset() throws {
        let relay = makeRelay()
        relay.begin(synFrame: syn(), 58)
        defer { relay.shutdown() }
        // A port with nothing listening: bind, learn it, let it go.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listener, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var actual = sockaddr_in()
        withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = getsockname(listener, sa, &len)
            }
        }
        close(listener)

        relay.start("127.0.0.1", UInt16(bigEndian: actual.sin_port))
        // ECONNREFUSED lands on the reader thread → RST to the guest.
        XCTAssertTrue(waitFor { self.frameCount == 1 })
        XCTAssertEqual(tcpFlags(frame(at: 0)) & 0x14, 0x14)
        XCTAssertTrue(relay.isDead)
        XCTAssertTrue(logged(matching: "connect"))
    }

    // #2377 — start() must not run the blocking connect() on the
    // capture thread: it returns at once and the dial happens on the
    // reader. Guest payload mid-dial is dropped — never written to a
    // half-dialed socket and never RST.
    func testStartDoesNotDialOnTheCallingThread() throws {
        let relay = makeRelay()
        relay.begin(synFrame: syn(), 58)
        defer { relay.shutdown() }
        // A blackholed upstream — a blocking connect would park the
        // caller for the OS timeout (~75 s); async it returns at once.
        let t0 = Date()
        relay.start("10.255.255.1", 65000)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5.0)

        let data = seg(seq: guestIsn + 1, ack: serverIsn + 1, payload: [UInt8](repeating: 0x64, count: 8))
        let delivery = relay.guestDataSegment(data, data.count)
        // The dial is usually still in flight here (.dialing); on a
        // host with no route the connect may already have failed
        // (.dead). Both prove nothing was written to a half-dialed
        // socket.
        XCTAssertTrue(delivery == .dialing || delivery == .dead)
        if delivery == .dialing { XCTAssertEqual(frameCount, 0) }
    }
}
