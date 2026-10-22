import Foundation
import VMTcp

// B6's hermetic Ethernet peers. No host listening socket or public exposure.
// The capture thread observes the real guest packets, not an injected core.
final class NativeSocketProbe {
    private let lock = NSLock()
    private let mode: String
    private var socket: FileHandle?
    private var sequence: [UInt16: UInt32] = [5001: 1001, 5002: 2001]
    private var acknowledgment: [UInt16: UInt32] = [:]
    private var replies: [UInt16: [UInt8]] = [:]
    private var thirdSent = false
    private var done: Set<UInt16> = []
    private let guestIP: [UInt8] = [10, 0, 0, 1]
    private let guestMAC: [UInt8] = [2, 0, 0, 0, 0, 1]

    init(mode: String) { self.mode = mode }

    private func send(_ port: UInt16, _ seq: UInt32, _ ack: UInt32, _ flags: UInt8, _ payload: [UInt8] = []) {
        var frame = [UInt8](repeating: 0, count: 1514)
        let last: UInt8 = port == 5003 ? 9 : 2
        let length = buildTcpFrameExplicit(&frame, guestMAC, [2, 0, 0, 0, 0, last],
            [10, 0, 0, last], guestIP, port, 8090, seq, ack, flags, payload)
        do { try socket?.write(contentsOf: Data(frame[..<length])) }
        catch { print("NATIVE-PROBE: FAIL transmit \(error)") }
    }

    func start(socket: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        self.socket = socket
        send(5001, 1000, 0, 2)
        send(5002, 2000, 0, 2)
        print("NATIVE-PROBE: two SYNs sent")
    }

    func receive(_ frame: [UInt8], _ count: Int) {
        guard count >= 54, frame[12] == 8, frame[13] == 0, frame[14] == 0x45,
              frame[23] == 6, frame[34] == 0x1f, frame[35] == 0x9a else { return }
        let port = UInt16(frame[36]) << 8 | UInt16(frame[37])
        guard (5001...5003).contains(port) else { return }
        lock.lock()
        defer { lock.unlock() }
        let flags = frame[47]
        let seq = UInt32(frame[38]) << 24 | UInt32(frame[39]) << 16 | UInt32(frame[40]) << 8 | UInt32(frame[41])
        let ack = UInt32(frame[42]) << 24 | UInt32(frame[43]) << 16 | UInt32(frame[44]) << 8 | UInt32(frame[45])
        let total = Int(frame[16]) << 8 | Int(frame[17])
        // Any TCP data offset ≥ 5 is well-formed — the guest's SYN-ACK
        // carries the 4-byte MSS option (offset 6) since M99h.
        let dataStart = 34 + Int(frame[46] >> 4) * 4
        guard total >= 40, frame[46] >= 0x50, dataStart <= 14 + total, total + 14 <= count else {
            print("NATIVE-PROBE: FAIL malformed TCP")
            return
        }
        if port == 5003 {
            if flags == 0x14, ack == 3001, Array(frame[30..<34]) == [10, 0, 0, 9] {
                print("NATIVE-PROBE: third client refused at its own IP")
            } else {
                print("NATIVE-PROBE: FAIL third client not refused")
            }
            return
        }
        if flags & 0x12 == 0x12 {
            guard ack == sequence[port] else { print("NATIVE-PROBE: FAIL SYN acknowledgment"); return }
            if acknowledgment[port] == nil {
                acknowledgment[port] = seq &+ 1
                let payload = Array((port == 5001 ? "GET /one\n" : "GET /two\n").utf8)
                send(port, sequence[port]!, seq &+ 1, 0x10, payload)
                sequence[port]! += UInt32(payload.count)
                if acknowledgment.count == 2, !thirdSent {
                    thirdSent = true
                    send(5003, 3000, 0, 2)
                }
            } else {
                send(port, sequence[port]!, acknowledgment[port]!, 0x10)
            }
            return
        }
        guard let current = acknowledgment[port], let outgoing = sequence[port] else { return }
        let payload = Array(frame[dataStart..<(14 + total)])
        if !payload.isEmpty {
            if seq != current { send(port, outgoing, current, 0x10); return }
            replies[port, default: []].append(contentsOf: payload)
            acknowledgment[port] = seq &+ UInt32(payload.count)
            let expected = Array((port == 5001 ? "preview-one\n" : "preview-two\n").utf8)
            guard replies[port] == expected else { print("NATIVE-PROBE: FAIL response bytes"); return }
            print("NATIVE-PROBE: exact preview response port=\(port)")
            if port == 5001 {
                send(port, outgoing, acknowledgment[port]!, 0x11)
                sequence[port]! += 1
                print("NATIVE-PROBE: first peer FIN")
            } else if mode == "reset" {
                send(port, outgoing, acknowledgment[port]!, 0x14)
                done.insert(port)
                print("NATIVE-PROBE: second peer reset")
            } else {
                send(port, outgoing, acknowledgment[port]!, 0x10)
                print("NATIVE-PROBE: second peer silent after ACK")
            }
        }
        if flags & 1 != 0 {
            send(port, sequence[port]!, seq &+ UInt32(payload.count) &+ 1, 0x10)
            done.insert(port)
        }
    }
}
