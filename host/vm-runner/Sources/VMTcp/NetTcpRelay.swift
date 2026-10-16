// VMTcp — NetTcpRelay: the `:relay` responder's upstream plumbing, one
// instance per guest connection (M51 interop #1209, M99f #2184).
//
// Issue #2349 — the two relay bugs M101a (#2313) and M107d (#2321)
// worked around, fixed here for real:
//
//   1. Inbound starvation ("the ~1460-byte cliff"). The old pump gated
//      on `srvNxt == relayGuestAck`, and relayGuestAck was overwritten
//      unconditionally by every guest segment. A retransmitted guest
//      segment carries a STALE ack; once it landed, the equality gate
//      could never pass again — the runner had bytes buffered upstream,
//      the guest had acked everything it received, and neither side
//      spoke again: the response starved to ETIMEDOUT. Tracking now
//      follows TCP's rule: the peer's cumulative ack never retreats, and
//      the (ack, window) pair is adopted only from segments that do not
//      go backward. Pumping is window-driven instead of one-chunk-per-
//      ACK: segments are sized by the guest's advertised MSS (clamped to
//      the 1460-byte Ethernet bound) and as many fit inside the
//      advertised send window go out back-to-back.
//   2. No retransmit dedup. Every guest data segment's payload was
//      written to the upstream fd unconditionally, so a retransmitted
//      segment duplicated its bytes into the real server's stream
//      (flintd then saw the request line twice). Guest payload is now
//      delivered in-order exactly once: `rcvNxt` is the cumulative
//      in-order bound AND the upstream water mark — a wholly-covered
//      retransmit writes nothing, a partial-overlap writes only its
//      fresh suffix, and a segment ahead of the bound is dropped named
//      (the honest ACK of `rcvNxt` tells the guest to retransmit the
//      gap).
//
// Honesty boundaries the relay still cannot cross: it never retransmits
// guest-bound data. If the guest drops an in-order segment (an overrun
// past its advertised window should not happen now, but a dropped frame
// is still possible), the stream is unrecoverable — after `stallLimit`
// consecutive guest segments that acknowledge nothing new while bytes
// are in flight, the relay emits RST rather than let the guest park to
// a timeout. Likewise a dead upstream (connect failure, write error, a
// data segment for a closed relay) is an immediate named RST, not a
// silent sink. Upstream-initiated close propagates as FIN once the
// buffered bytes are sent.
//
// Threads: the capture thread calls begin/guestAckSegment/
// guestDataSegment/pump/shutdown; the upstream reader thread appends to
// `tx` and calls pump. Everything serializes on `lock`.
import Foundation

public final class NetTcpRelay {
    /// What one guest data segment did to the upstream stream.
    public enum Delivery: Equatable {
        case forwarded(fresh: Int)  // this many bytes newly written upstream
        case duplicate              // wholly retransmitted — nothing written
        case gap                    // ahead of the in-order bound — dropped
        case closed                 // upstream EOF'd — dropped; buffered bytes + FIN still deliver
        case dead                   // no usable upstream — RST was emitted
    }

    /// The Ethernet MTU's TCP payload bound — the largest single segment
    /// the guest's RX path can hold (kernel/src/tcp.zig payload_max).
    /// A peer that advertised no MSS option keeps this fleet contract
    /// rather than the RFC 793 536-byte default.
    public static let payloadBound = 1460
    /// Consecutive in-window guest segments that advance the cumulative
    /// ack by zero while bytes are in flight before the relay concludes
    /// the guest dropped a segment it can never signal for — the relay
    /// has no retransmission, so the stream is dead: RST, not a stall.
    public static let stallLimit = 8

    public var hostMAC: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x02]
    public var hostPort: UInt16 = 0
    public var serverIsn: UInt32 = 0
    /// Guest-bound frame sink — the runner wires this to the capture
    /// socket; the test harness collects frames.
    public var onFrame: (([UInt8]) -> Void)?
    public var onLog: (String) -> Void = { print($0) }

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var gen = 0
    private var upstreamClosed = false
    private var tx: [UInt8] = []
    private var txOffset = 0
    /// The most recent guest segment (starting with the SYN) — the frame
    /// every reply is templated from.
    private var template: [UInt8] = []
    /// Server send-next sequence.
    private var srvNxt: UInt32 = 0
    /// The cumulative in-order guest bound: the ACK value every outbound
    /// segment carries AND the upstream-delivery water mark.
    private var rcvNxt: UInt32 = 0
    /// The peer's cumulative ack — never retreats (a retransmitted
    /// segment's stale ack is ignored; issue #2349's pump deadlock).
    private var peerAck: UInt32 = 0
    /// The advertised window paired with `peerAck` — adopted only from a
    /// segment whose ack is not behind, so a stale window cannot widen
    /// the send allowance past what the guest's RX can hold.
    private var peerWnd: UInt16 = 0
    /// The guest's advertised MSS from its SYN (0 = none sent).
    private var peerMSS: UInt16 = 0
    private var finSent = false
    private var rstSent = false
    private var stallCount = 0
    private var dead = false
    /// False until `begin` ran (a lazy conn created by a stray segment
    /// answers RST — there is no handshake to continue).
    private var began = false
    /// The guest closed first (FIN/RST) — an upstream EOF after that must
    /// not emit a relay FIN on a connection the guest already ended.
    private var noFin = false

    public init() {}

    /// The sequence/ack pair a bare reply should carry — a single locked
    /// read so the capture thread never publishes a torn pair.
    public func currentSeqAck() -> (seq: UInt32, ack: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        return (srvNxt, rcvNxt)
    }

    /// Adopt the connection state the guest's SYN establishes: the SYN
    /// frame becomes the reply template, its seq+1 the in-order bound,
    /// its window the initial allowance, its MSS option the segment cap.
    public func begin(synFrame buf: [UInt8], _ n: Int) {
        lock.lock()
        defer { lock.unlock() }
        template = Array(buf[0..<n])
        if let mss = Self.mssOption(buf, n) { peerMSS = mss }
        if n >= 54 { peerWnd = tcpWindow(buf) }
        rcvNxt = tcpSeq(buf) &+ 1
        srvNxt = serverIsn &+ 1
        peerAck = 0
        finSent = false
        rstSent = false
        stallCount = 0
        dead = false
        noFin = false
        began = true
    }

    /// Dial the real upstream and spawn the reader that appends real
    /// bytes to the paced TX buffer. Only the reader closes its own fd
    /// (a generation counter retires a previous reader without an
    /// fd-reuse race).
    public func start(_ host: String, _ port: UInt16) {
        shutdown()
        let newFd = socket(AF_INET, SOCK_STREAM, 0)
        guard newFd >= 0 else {
            onLog("NET-TCP-RELAY: upstream socket() failed (errno \(errno)); the relay is dead for this connection")
            return
        }
        // A peer that vanishes between connect and write must be an
        // EPIPE, not a SIGPIPE to the runner.
        var noSigPipe: Int32 = 1
        _ = setsockopt(newFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        var a4 = in_addr()
        guard inet_pton(AF_INET, host, &a4) == 1 else {
            onLog("NET-TCP-RELAY: upstream '\(host)' is not a dotted-quad IPv4 address")
            close(newFd)
            return
        }
        addr.sin_addr = a4
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(newFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            onLog("NET-TCP-RELAY: upstream connect \(host):\(port) failed (errno \(errno)); the relay is dead for this connection")
            close(newFd)
            return
        }
        lock.lock()
        gen += 1
        let myGen = gen
        fd = newFd
        upstreamClosed = false
        tx = []
        txOffset = 0
        lock.unlock()
        onLog("NET-TCP-RELAY: upstream \(host):\(port) connected (real server; bytes proxied, no crypto here)")
        let reader = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(newFd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                guard let self else { close(newFd); return }
                if n <= 0 {
                    self.lock.lock()
                    if myGen == self.gen {
                        self.upstreamClosed = true
                        if self.fd == newFd { self.fd = -1 }
                    }
                    self.lock.unlock()
                    close(newFd)
                    self.onLog("NET-TCP-RELAY: upstream \(host):\(port) closed (\(n == 0 ? "EOF" : "errno \(errno)"))")
                    // The guest still waits on bytes/a FIN — pump what
                    // drained plus the close.
                    self.pump()
                    return
                }
                self.lock.lock()
                let current = myGen == self.gen
                if current { self.tx.append(contentsOf: buf[0..<n]) }
                self.lock.unlock()
                if !current {
                    close(newFd)
                    return
                }
                self.onLog("NET-TCP-RELAY: upstream -> guest \(n) bytes buffered")
                // Real-server bytes arriving with no guest segment to
                // trigger the next chunk are pumped right here — the
                // guest's bounded reads cannot wait for the next guest
                // ACK alone.
                self.pump()
            }
        }
        reader.name = "net-tcp-relay-upstream"
        reader.start()
    }

    /// Half-close the upstream fd; the reader observes EOF and closes it.
    /// `suppressFin` marks guest-initiated closes (the guest's own
    /// FIN/RST) — the upstream EOF that follows must not emit a relay
    /// FIN on a connection the guest already ended.
    public func shutdown(suppressFin: Bool = false) {
        lock.lock()
        let old = fd
        fd = -1
        if suppressFin { noFin = true }
        lock.unlock()
        if old >= 0 { Darwin.shutdown(old, SHUT_RDWR) }
    }

    /// A guest segment that carries no payload (the handshake ACK, a
    /// cumulative ack, a window update). Refreshes the reply template,
    /// the paired ack/window, and detects the unrecoverable stall.
    /// Returns true when the segment killed the connection (RST sent).
    @discardableResult
    public func guestAckSegment(_ buf: [UInt8], _ n: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let killed = observeLocked(buf, n, countStall: true)
        if !killed, !began {
            emitResetLocked()
            onLog("NET-TCP-RELAY: guest ACK for a connection that never handshook; sent RST")
            return true
        }
        return killed
    }

    /// A guest segment carrying payload: dedup against the in-order
    /// bound, write only the fresh suffix upstream, and apply the same
    /// observe rules. Retransmits cost nothing; a gap is dropped named
    /// (the guest's retransmit fills it); a dead upstream is an RST.
    @discardableResult
    public func guestDataSegment(_ buf: [UInt8], _ n: Int) -> Delivery {
        lock.lock()
        defer { lock.unlock() }
        // A fresh-payload segment is liveness, not stall evidence — stall
        // counting stays on the pure-ACK path (a guest that pipelines
        // requests carries the same ack legitimately).
        if observeLocked(buf, n, countStall: false) { return .dead }
        guard began else {
            emitResetLocked()
            onLog("NET-TCP-RELAY: guest data for a connection that never handshook; sent RST")
            return .dead
        }
        let dataOff = 34 + max(5, Int(buf[46] >> 4)) * 4
        let payloadLen = n > dataOff ? n - dataOff : 0
        let seq = tcpSeq(buf)
        let rel = Int32(bitPattern: seq &- rcvNxt)
        if rel > 0 {
            onLog("NET-TCP-RELAY: dropped a \(payloadLen)-byte guest segment ahead of the in-order bound (seq 0x\(hex32(seq)), expecting 0x\(hex32(rcvNxt))) — not forwarded upstream; the guest's retransmit fills the gap")
            return .gap
        }
        let skip = min(Int(-rel), payloadLen)
        let fresh = payloadLen - skip
        guard fresh > 0 else {
            onLog("NET-TCP-RELAY: deduplicated a retransmitted guest segment (seq 0x\(hex32(seq)), \(payloadLen) bytes already delivered upstream)")
            return .duplicate
        }
        guard fd >= 0, !dead else {
            if upstreamClosed {
                // A graceful EOF: the buffered reply + FIN still deliver,
                // but these guest bytes can never be answered — drop
                // them (rcvNxt does not advance, so the ACK reports the
                // honest bound) rather than RST the draining stream.
                onLog("NET-TCP-RELAY: dropped \(fresh) guest bytes — upstream is already closed; the buffered reply + FIN still deliver")
                return .closed
            }
            emitResetLocked()
            onLog("NET-TCP-RELAY: guest data arrived with no upstream (the relay is dead for this connection); sent RST")
            return .dead
        }
        var off = dataOff + skip
        var written = 0
        while written < fresh {
            let w = buf.withUnsafeBufferPointer { p in
                write(fd, p.baseAddress! + off, fresh - written)
            }
            if w < 0 {
                if errno == EINTR { continue }
                upstreamClosed = true
                emitResetLocked()
                onLog("NET-TCP-RELAY: upstream write failed (errno \(errno)); sent RST — the relay is dead for this connection")
                return .dead
            }
            off += w
            written += w
        }
        rcvNxt = rcvNxt &+ UInt32(fresh)
        onLog("NET-TCP-RELAY: guest -> upstream \(fresh) bytes\(skip > 0 ? " (\(skip) retransmitted bytes skipped)" : "")")
        return .forwarded(fresh: fresh)
    }

    /// Pump as many guest-bound segments as the advertised window
    /// allows, each capped by the guest's MSS (the fleet's 1460-byte
    /// bound when the SYN carried none). Nothing goes out before a guest
    /// segment acks the SYN-ACK — the guest drops anything that precedes
    /// it. An upstream close drains the buffer then emits one FIN.
    /// Returns true when at least one frame went out.
    @discardableResult
    public func pump() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard template.count >= 54, !dead else { return false }
        // Nothing before the handshake lands: the guest's SYN-ACK ack is
        // the first (ack, window) pair worth sending against.
        guard Int32(bitPattern: peerAck &- (serverIsn &+ 1)) >= 0 else { return false }
        var sent = false
        while txOffset < tx.count {
            let edge = peerAck &+ UInt32(peerWnd)
            let avail = Int32(bitPattern: edge &- srvNxt)
            guard avail > 0 else { break }
            let mss = peerMSS == 0 ? Self.payloadBound : min(Int(peerMSS), Self.payloadBound)
            let count = min(min(mss, Int(avail)), tx.count - txOffset)
            emitLocked(flags: 0x10, payload: Array(tx[txOffset..<txOffset + count]), seq: srvNxt, ack: rcvNxt)
            srvNxt = srvNxt &+ UInt32(count)
            txOffset += count
            if txOffset >= tx.count {
                tx.removeAll(keepingCapacity: true)
                txOffset = 0
            }
            sent = true
            onLog("NET-TCP-RELAY: sent \(count) bytes to the guest (seq 0x\(hex32(srvNxt &- UInt32(count))))")
        }
        if !finSent, !noFin, upstreamClosed, txOffset >= tx.count {
            emitLocked(flags: 0x11, payload: [], seq: srvNxt, ack: rcvNxt)
            srvNxt = srvNxt &+ 1
            finSent = true
            sent = true
            onLog("NET-TCP-RELAY: upstream drained and closed; sent FIN (seq 0x\(hex32(srvNxt &- 1)))")
        }
        return sent
    }

    /// Whether the connection was torn down (stall RST or dead-upstream
    /// RST); a bare ACK to a dead relay would only invite another.
    public var isDead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dead || rstSent
    }

    // Save the reply template and adopt the segment's (ack, window) pair
    // under TCP's rule that the cumulative ack never retreats: a pair
    // behind `peerAck` is a retransmission's stale snapshot and moves
    // nothing; a pair at the same ack is a legitimate window update.
    // `countStall` limits the counter to pure-ACK segments. Returns true
    // when the stall bound tripped and the RST went out.
    private func observeLocked(_ buf: [UInt8], _ n: Int, countStall: Bool) -> Bool {
        guard n >= 54 else { return dead }
        template = Array(buf[0..<n])
        guard !dead else { return true }
        if let mss = Self.mssOption(buf, n) { peerMSS = mss }
        guard (tcpFlags(buf) & 0x10) != 0 else { return false }
        let ack = tcpAck(buf)
        let wnd = tcpWindow(buf)
        let adv = Int32(bitPattern: ack &- peerAck)
        if adv > 0 {
            peerAck = ack
            peerWnd = wnd
            stallCount = 0
        } else if adv == 0 {
            peerWnd = wnd
            if countStall, Int32(bitPattern: srvNxt &- ack) > 0 {
                stallCount += 1
                if stallCount >= Self.stallLimit {
                    emitResetLocked()
                    onLog("NET-TCP-RELAY: guest ack 0x\(hex32(ack)) has not advanced in \(stallCount) segments while 0x\(hex32(srvNxt &- ack)) bytes are in flight — the guest dropped a segment the relay cannot retransmit; sent RST")
                    return true
                }
            } else {
                stallCount = 0
            }
        }
        return false
    }

    private func emitLocked(flags: UInt8, payload: [UInt8], seq: UInt32, ack: UInt32) {
        var reply: [UInt8] = []
        let len = buildTcpReply(&reply, template, template.count, hostMAC, hostPort, seq, ack, flags, payload)
        onFrame?(Array(reply[0..<len]))
    }

    private func emitResetLocked() {
        guard !rstSent, template.count >= 54 else { return }
        rstSent = true
        dead = true
        emitLocked(flags: 0x14, payload: [], seq: srvNxt, ack: rcvNxt)
    }

    /// The MSS option (kind 2, length 4) in a segment's option area —
    /// absent, or nil on a malformed option list.
    private static func mssOption(_ buf: [UInt8], _ n: Int) -> UInt16? {
        guard n >= 54 else { return nil }
        let doff = Int(buf[46] >> 4)
        guard doff > 5 else { return nil }
        let end = min(n, 34 + doff * 4)
        var i = 54
        while i < end {
            let kind = buf[i]
            if kind == 0 { return nil }                    // end of list
            if kind == 1 { i += 1; continue }              // NOP
            guard i + 1 < end else { return nil }
            let len = Int(buf[i + 1])
            if len < 2 || i + len > end { return nil }
            if kind == 2 && len == 4 {
                return (UInt16(buf[i + 2]) << 8) | UInt16(buf[i + 3])
            }
            i += len
        }
        return nil
    }
}
