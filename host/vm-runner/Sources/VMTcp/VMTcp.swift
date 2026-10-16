// VMTcp — the runner's TCP wire helpers and the real-upstream relay
// (issue #2349). Pure Swift/Foundation, zero Virtualization imports, so
// `swift test` exercises the relay — including the two bugs M101a
// (#2313) and M107d (#2321) worked around — without booting a VM.
//
// The frame helpers were lifted verbatim from VMRunner's main.swift so
// the executable and the testable module share one wire definition.
import Foundation

// Card N4 (claim 0148): RFC 1071 one's-complement checksum over
// `bytes[start..<end]` (big-endian 16-bit words, folded; the checksummed
// field must be zero by the caller).
@Sendable public func ipChecksum(_ bytes: [UInt8], _ start: Int, _ end: Int) -> UInt16 {
    var sum: UInt32 = 0
    var i = start
    while i + 1 < end {
        sum += (UInt32(bytes[i]) << 8) | UInt32(bytes[i + 1])
        i += 2
    }
    if i < end { sum += UInt32(bytes[i]) << 8 } // trailing odd byte
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return UInt16(~sum & 0xffff)
}

// Card N10 (claim 7026): is the captured frame a TCP segment for our
// ip:port from the guest's bounded client (Ethernet II ethertype 0x0800,
// version 4 / IHL 5, NOT a fragment, protocol TCP, dst IP = the host IP,
// dst port = the host port)? The guest's segments are raw Ethernet —
// header at 14..34, the TCP header at 34.
public func isTcpSegment(_ buf: [UInt8], _ n: Int, _ hostIP: [UInt8], _ hostPort: UInt16) -> Bool {
    guard n >= 54 else { return false }
    guard buf[12] == 0x08 && buf[13] == 0x00 else { return false } // ethertype IPv4
    guard buf[14] == 0x45 else { return false } // version 4, IHL 5
    guard (buf[20] & 0x1f) == 0 && buf[21] == 0 else { return false } // NOT a fragment
    guard buf[23] == 6 else { return false } // protocol TCP
    guard buf[30] == hostIP[0] && buf[31] == hostIP[1] && buf[32] == hostIP[2] && buf[33] == hostIP[3] else { return false }
    let dstPort = (UInt16(buf[36]) << 8) | UInt16(buf[37])
    return dstPort == hostPort
}

// Card N10: the TCP flags byte (frame offset 34 + 13 = 47).
public func tcpFlags(_ buf: [UInt8]) -> UInt8 {
    return buf[47]
}

// Card N10: the TCP sequence number (big-endian u32 at frame 38..42).
public func tcpSeq(_ buf: [UInt8]) -> UInt32 {
    return (UInt32(buf[38]) << 24) | (UInt32(buf[39]) << 16) | (UInt32(buf[40]) << 8) | UInt32(buf[41])
}

// Card N10: the TCP acknowledgment number (big-endian u32 at frame
// 42..46).
public func tcpAck(_ buf: [UInt8]) -> UInt32 {
    return (UInt32(buf[42]) << 24) | (UInt32(buf[43]) << 16) | (UInt32(buf[44]) << 8) | UInt32(buf[45])
}

// M99f (#2184): the advertised receive window (big-endian u16 at frame
// 48..50). The guest reports 0 while its single RX slot is occupied —
// a data chunk sent into a zero window is dropped as rx_full and, with
// no retransmit here, starves the session.
public func tcpWindow(_ buf: [UInt8]) -> UInt16 {
    return (UInt16(buf[48]) << 8) | UInt16(buf[49])
}

// Card N10: a 32-bit value as zero-padded 8-hex-digit text, built by
// hand (Swift's String(format:) vararg bridge mismatches %x with UInt32
// — the same reason the N5/N8 responders print values as arithmetic).
public func hex32(_ v: UInt32) -> String {
    let hexT = Array("0123456789abcdef")
    var out = ""
    var shift: UInt32 = 28
    while true {
        let nib = Int((v >> shift) & 0xf)
        out.append(hexT[nib])
        if shift == 0 { break }
        shift &-= 4
    }
    return out
}

// Card N10: the TCP checksum over the IPv4 pseudo-header (src IP, dst
// IP, zero, protocol 6, TCP length) + the segment (RFC 793 §3.1 — the
// checksum field must be zeroed by the caller during the computation).
@Sendable public func tcpChecksum(_ src: [UInt8], _ dst: [UInt8], _ segment: [UInt8], _ tcpLen: UInt16) -> UInt16 {
    var sum: UInt32 = 0
    sum += (UInt32(src[0]) << 8) | UInt32(src[1])
    sum += (UInt32(src[2]) << 8) | UInt32(src[3])
    sum += (UInt32(dst[0]) << 8) | UInt32(dst[1])
    sum += (UInt32(dst[2]) << 8) | UInt32(dst[3])
    sum += 6 // protocol TCP
    sum += UInt32(tcpLen)
    var i = 0
    while i + 1 < segment.count {
        sum += (UInt32(segment[i]) << 8) | UInt32(segment[i + 1])
        i += 2
    }
    if i < segment.count { sum += UInt32(segment[i]) << 8 } // trailing odd byte
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return UInt16((~sum) & 0xffff)
}

// Card N10 (claim 7026): synthesize a TCP reply to the guest's segment
// in `req` into `reply`: Ethernet dst/src swapped, ethertype 0x0800,
// IPv4 src/dst swapped, protocol 6, the TCP header (src = the host port,
// dst = the guest's src port, seq = the given server seq, ack = the
// given ack, the given flags, the FIXED window 4096, no options — the
// guest's honest bound), the echoed payload when present; both checksums
// recomputed (RFC 1071). Returns the frame length (54 + the payload).
public func buildTcpReply(_ reply: inout [UInt8], _ req: [UInt8], _ n: Int, _ hostMAC: [UInt8], _ hostPort: UInt16, _ srvSeq: UInt32, _ ack: UInt32, _ flags: UInt8, _ payload: [UInt8], options: [UInt8] = []) -> Int {
    _ = n
    // M99h (#2186): `options` is the pre-padded option area (0..40 bytes,
    // a multiple of 4) — the `:options` mode's pinned lists; every other
    // caller passes nothing and gets the byte-identical legacy frame.
    let optsPad = (options.count + 3) & ~3
    let hdrBytes = 20 + optsPad
    let frameLen = 54 + optsPad + payload.count
    reply = [UInt8](repeating: 0, count: frameLen)
    // Ethernet: dst = the guest's MAC, src = the host MAC.
    reply[0...5] = req[6...11]
    reply[6...11] = hostMAC[0...5]
    reply[12] = 0x08
    reply[13] = 0x00 // ethertype IPv4
    // IPv4: src = the guest's dst IP, dst = the guest's src IP, proto 6.
    reply[14] = 0x45 // version 4, IHL 5
    reply[16] = UInt8((20 + hdrBytes + payload.count) >> 8)
    reply[17] = UInt8((20 + hdrBytes + payload.count) & 0xff) // total length
    reply[22] = 64 // TTL
    reply[23] = 6 // protocol TCP
    reply[26...29] = req[30...33] // src
    reply[30...33] = req[26...29] // dst
    let hdrChk = ipChecksum(reply, 14, 34)
    reply[24] = UInt8(hdrChk >> 8)
    reply[25] = UInt8(hdrChk & 0xff)
    // TCP: src = the host port, dst = the guest's src port, seq/ack,
    // the data offset covering the option area, the flags, window 4096,
    // urgent 0.
    reply[34] = UInt8(hostPort >> 8)
    reply[35] = UInt8(hostPort & 0xff)
    reply[36] = req[34]
    reply[37] = req[35]
    reply[38] = UInt8(srvSeq >> 24)
    reply[39] = UInt8((srvSeq >> 16) & 0xff)
    reply[40] = UInt8((srvSeq >> 8) & 0xff)
    reply[41] = UInt8(srvSeq & 0xff)
    reply[42] = UInt8(ack >> 24)
    reply[43] = UInt8((ack >> 16) & 0xff)
    reply[44] = UInt8((ack >> 8) & 0xff)
    reply[45] = UInt8(ack & 0xff)
    reply[46] = UInt8((5 + optsPad / 4) << 4) // data offset (5 = no options)
    reply[47] = flags
    reply[48] = 0x10 // window 4096
    reply[49] = 0x00
    // Checksum field at 50..52 (zeroed by the memset), urgent 52..54 (0).
    if !options.isEmpty {
        reply[54...54 + options.count - 1] = options[0...options.count - 1]
    }
    if !payload.isEmpty {
        reply[54 + optsPad...54 + optsPad + payload.count - 1] = payload[0...payload.count - 1]
    }
    // The TCP checksum over the pseudo-header (the guest's src IP -> the
    // guest's dst IP), the checksum field zeroed during the computation.
    let srcIP = [UInt8](req[26...29])
    let dstIP = [UInt8](req[30...33])
    var seg = [UInt8](reply[34..<frameLen])
    seg[16] = 0
    seg[17] = 0
    let tcpChk = tcpChecksum(srcIP, dstIP, seg, UInt16(hdrBytes + payload.count))
    reply[50] = UInt8(tcpChk >> 8)
    reply[51] = UInt8(tcpChk & 0xff)
    return frameLen
}

// SH7 (#1083, ADR 0020 Amendment B): match a guest-originated TCP segment
// in the HOST-CLIENT direction — src IP/port = the guest listener, dst port
// = the host client's fixed source port (the reverse of `isTcpSegment`).
public func isTcpSegmentFromGuest(_ buf: [UInt8], _ n: Int, _ guestIP: [UInt8], _ guestPort: UInt16, _ clientPort: UInt16) -> Bool {
    guard n >= 54 else { return false }
    guard buf[12] == 0x08 && buf[13] == 0x00 else { return false } // ethertype IPv4
    guard buf[14] == 0x45 else { return false } // version 4, IHL 5
    guard (buf[20] & 0x1f) == 0 && buf[21] == 0 else { return false } // NOT a fragment
    guard buf[23] == 6 else { return false } // protocol TCP
    guard buf[26] == guestIP[0] && buf[27] == guestIP[1] && buf[28] == guestIP[2] && buf[29] == guestIP[3] else { return false }
    let srcPort = (UInt16(buf[34]) << 8) | UInt16(buf[35])
    let dstPort = (UInt16(buf[36]) << 8) | UInt16(buf[37])
    return srcPort == guestPort && dstPort == clientPort
}

// SH7: synthesize a frame from EXPLICIT Ethernet/IPv4/TCP fields (the N10
// `buildTcpReply` copies those from a request frame; a host-initiated
// client has no request to copy from). Both checksums are recomputed.
public func buildTcpFrameExplicit(_ frame: inout [UInt8], _ dstMAC: [UInt8], _ srcMAC: [UInt8], _ srcIP: [UInt8], _ dstIP: [UInt8], _ srcPort: UInt16, _ dstPort: UInt16, _ seq: UInt32, _ ack: UInt32, _ flags: UInt8, _ payload: [UInt8]) -> Int {
    let frameLen = 54 + payload.count
    frame = [UInt8](repeating: 0, count: frameLen)
    frame[0...5] = dstMAC[0...5]
    frame[6...11] = srcMAC[0...5]
    frame[12] = 0x08
    frame[13] = 0x00 // ethertype IPv4
    frame[14] = 0x45 // version 4, IHL 5
    frame[16] = UInt8((20 + 20 + payload.count) >> 8)
    frame[17] = UInt8((20 + 20 + payload.count) & 0xff) // total length
    frame[22] = 64 // TTL
    frame[23] = 6 // protocol TCP
    frame[26...29] = srcIP[0...3]
    frame[30...33] = dstIP[0...3]
    let hdrChk = ipChecksum(frame, 14, 34)
    frame[24] = UInt8(hdrChk >> 8)
    frame[25] = UInt8(hdrChk & 0xff)
    frame[34] = UInt8(srcPort >> 8)
    frame[35] = UInt8(srcPort & 0xff)
    frame[36] = UInt8(dstPort >> 8)
    frame[37] = UInt8(dstPort & 0xff)
    frame[38] = UInt8(seq >> 24)
    frame[39] = UInt8((seq >> 16) & 0xff)
    frame[40] = UInt8((seq >> 8) & 0xff)
    frame[41] = UInt8(seq & 0xff)
    frame[42] = UInt8(ack >> 24)
    frame[43] = UInt8((ack >> 16) & 0xff)
    frame[44] = UInt8((ack >> 8) & 0xff)
    frame[45] = UInt8(ack & 0xff)
    frame[46] = 0x50 // data offset 5 (no options)
    frame[47] = flags
    frame[48] = 0x10 // window 4096
    frame[49] = 0x00
    if !payload.isEmpty {
        frame[54...54 + payload.count - 1] = payload[0...payload.count - 1]
    }
    var seg = [UInt8](frame[34..<frameLen])
    seg[16] = 0
    seg[17] = 0
    let tcpChk = tcpChecksum(srcIP, dstIP, seg, UInt16(20 + payload.count))
    frame[50] = UInt8(tcpChk >> 8)
    frame[51] = UInt8(tcpChk & 0xff)
    return frameLen
}
