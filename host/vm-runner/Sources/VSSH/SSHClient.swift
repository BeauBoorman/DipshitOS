// M70g G1 (#1491, ADR 0025 D2): the minimal SSH-2 **client** the runner hosts
// behind `--net-tcp-connect <guest-ip>:<port>:ssh`.
//
// This is the deterministic peer for the class-B `live-ssh-server` gate, not
// a general ssh. It implements exactly the ADR 0025 D2 profile as a client:
// version exchange, curve25519-sha256 KEX, ssh-ed25519 host-key pin,
// chacha20-poly1305@openssh.com, publickey userauth, one session exec.
// M168f (#2962): a pty session — `pty-req` (TERM=xterm-256color) + `shell`
// instead of `exec`, then a `SSHKeyScript` line script drives the decrypted
// channel stream (`after`/`send`/`resize`), CHANNEL_WINDOW_ADJUST returns
// the window credit the client consumes.
//
// The client is a pure byte-stream state machine: `start()` emits the
// identification line + KEXINIT, `feed(_:)` appends inbound TCP bytes and
// returns outbound bytes. VMRunner paces TX one ≤192-byte segment per guest
// ACK (the guest kernel RX is a single 192-byte slot with no reassembly).
//
// No Virtualization imports, no I/O, no force unwraps on network data.

import CryptoKit
import Foundation

public final class SSHClient {
    public struct Config {
        /// The client's `ssh-ed25519` seed (32 bytes).
        public var userKeySeed: [UInt8]
        /// Pinned server `ssh-ed25519` public key (32 bytes).
        public var hostPublicKey: [UInt8]
        public var user: String
        public var execCommand: String
        /// M168f (#2962): when set the channel request is `pty-req`
        /// (TERM=xterm-256color) + `shell` instead of `exec`.
        public var pty: (cols: UInt32, rows: UInt32)?
        /// The parsed `--net-tcp-connect-ssh-keys` script, evaluated against
        /// the decrypted channel stream once the shell is live.
        public var keyScript: SSHKeyScript?
        public var cookieOverride: [UInt8]?
        public var ephemeralOverride: [UInt8]?
        public var versionLine: String

        public init(
            userKeySeed: [UInt8],
            hostPublicKey: [UInt8],
            user: String = "alice",
            execCommand: String = "echo VIRELAI-SSH-SERVER-OK-ARGV2",
            pty: (cols: UInt32, rows: UInt32)? = nil,
            keyScript: SSHKeyScript? = nil,
            cookieOverride: [UInt8]? = nil,
            ephemeralOverride: [UInt8]? = nil,
            versionLine: String = "SSH-2.0-VirelaiOS_1.0"
        ) {
            self.userKeySeed = userKeySeed
            self.hostPublicKey = hostPublicKey
            self.user = user
            self.execCommand = execCommand
            self.pty = pty
            self.keyScript = keyScript
            self.cookieOverride = cookieOverride
            self.ephemeralOverride = ephemeralOverride
            self.versionLine = versionLine
        }
    }

    public enum Phase: Equatable {
        case version
        case kex
        case encrypted
        case failed
        case closed
    }

    private let config: Config
    private let userKey: Curve25519.Signing.PrivateKey

    public private(set) var phase: Phase = .version
    public private(set) var events: [String] = []
    public var logSink: ((String) -> Void)?
    public private(set) var stdout: [UInt8] = []
    public private(set) var exitStatus: UInt32?

    private var input: [UInt8] = []
    private var out: [UInt8] = []
    private var started = false
    private var bannerLines = 0
    private var serverVersion = ""
    private var iC: [UInt8] = []
    private var iS: [UInt8] = []
    private var qC: [UInt8] = []
    private var ephSecret: [UInt8] = []
    private var sessionId: [UInt8] = []
    private var pendingSendKey: [UInt8] = []
    private var pendingRecvKey: [UInt8] = []
    private var sendCipher: SSHOpenSSHCipher?
    private var recvCipher: SSHOpenSSHCipher?
    private var sendSeq: UInt64 = 0
    private var recvSeq: UInt64 = 0
    private var serverChannel: UInt32 = 0
    private var localChannel: UInt32 = 0
    private var authed = false
    private var channelOpen = false
    private var execSent = false
    // M168f (#2962): the interactive-session state — the channel request
    // currently outstanding (pty-req, then shell), the peer's window +
    // max-packet from OPEN_CONFIRMATION, the credit we owe back via
    // CHANNEL_WINDOW_ADJUST, CHANNEL_DATA queued while the peer's window
    // is shut, and the key-script cursor.
    private enum OutstandingRequest { case none, ptyReq, shell }
    private var outstandingRequest: OutstandingRequest = .none
    private var sessionLive = false
    private var remoteWindow: UInt32 = 0
    private var remoteMaxPacket: UInt32 = 0
    private var localWindowLeft: UInt32 = SSHServer.localWindow
    private var windowConsumed: UInt32 = 0
    private var pendingData: [UInt8] = []
    private var keyScript: SSHKeyScript?
    private var scriptCursor = 0
    private var scriptDoneLogged = false
    private var ptyBytesLogged = false

    public init(config: Config) {
        self.config = config
        userKey = try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(config.userKeySeed)
        )
        keyScript = config.keyScript
    }

    public var isClosed: Bool { phase == .closed || phase == .failed }
    public var failed: Bool { phase == .failed }

    /// Emit the identification line + KEXINIT. Call once, on TCP establish.
    public func start() -> [UInt8] {
        guard !started else { return [] }
        started = true
        var greeting = Array(config.versionLine.utf8)
        greeting.append(contentsOf: [0x0d, 0x0a])
        out.append(contentsOf: greeting)
        sendKexInit()
        log("version sent: \(config.versionLine)")
        let result = out
        out.removeAll(keepingCapacity: true)
        return result
    }

    public func feed(_ data: [UInt8]) -> [UInt8] {
        guard phase != .failed, phase != .closed else { return [] }
        input.append(contentsOf: data)
        process()
        let result = out
        out.removeAll(keepingCapacity: true)
        return result
    }

    private func log(_ line: String) {
        events.append(line)
        logSink?(line)
    }

    private func process() {
        while !isClosed {
            switch phase {
            case .version:
                guard readVersionLine() else { return }
            case .kex:
                guard let payload = nextPlainPacket() else { return }
                handleKexPacket(payload)
            case .encrypted:
                guard let payload = nextEncryptedPacket() else { return }
                handleEncrypted(payload)
            case .failed, .closed:
                return
            }
        }
    }

    private func readVersionLine() -> Bool {
        while true {
            guard let nl = input.firstIndex(of: 0x0a) else { return false }
            let raw = Array(input[0 ..< nl])
            input.removeFirst(nl + 1)
            var line = raw
            if line.last == 0x0d { line.removeLast() }
            if line.count < 4 || Array(line[0 ..< 4]) != Array("SSH-".utf8) {
                bannerLines += 1
                if bannerLines > 64 {
                    fail("too many banner lines")
                    return false
                }
                continue
            }
            guard let text = String(bytes: line, encoding: .utf8),
                  text.hasPrefix("SSH-2.0-") || text.hasPrefix("SSH-1.99-")
            else {
                fail("bad identification line")
                return false
            }
            serverVersion = text
            log("version received: \(text)")
            phase = .kex
            return true
        }
    }

    private func sendKexInit() {
        var w = SSHWriter()
        w.byte(SSHServer.msgKexInit)
        let cookie = config.cookieOverride ?? randomBytes(16)
        w.raw(cookie)
        w.nameList(["curve25519-sha256", "curve25519-sha256@libssh.org"])
        w.nameList(["ssh-ed25519"])
        w.nameList(["chacha20-poly1305@openssh.com"])
        w.nameList(["chacha20-poly1305@openssh.com"])
        w.nameList([])
        w.nameList([])
        w.nameList(["none"])
        w.nameList(["none"])
        w.nameList([])
        w.nameList([])
        w.bool(false)
        w.uint32(0)
        iC = w.bytes
        sendPacket(iC)
        log("kexinit sent")
    }

    private func handleKexPacket(_ payload: [UInt8]) {
        guard let kind = payload.first else { return }
        switch kind {
        case SSHServer.msgKexInit:
            guard parseServerKexInit(payload) else { return }
            log("kexinit received (suite negotiated)")
            sendECDHInit()
        case SSHServer.msgKexEcdhReply:
            handleECDHReply(payload)
        case SSHServer.msgNewKeys:
            guard payload == [SSHServer.msgNewKeys] else {
                fail("malformed NEWKEYS")
                return
            }
            recvCipher = SSHOpenSSHCipher(key: pendingRecvKey)
            sendPacket([SSHServer.msgNewKeys])
            sendCipher = SSHOpenSSHCipher(key: pendingSendKey)
            pendingRecvKey = []
            pendingSendKey = []
            phase = .encrypted
            log("newkeys received; cipher installed")
            sendServiceAndAuth()
        case SSHServer.msgDisconnect:
            log("server disconnect during kex")
            phase = .closed
        case SSHServer.msgIgnore, SSHServer.msgDebug:
            break
        default:
            fail("unexpected kex message \(kind)")
        }
    }

    private func parseServerKexInit(_ payload: [UInt8]) -> Bool {
        var r = SSHReader(payload)
        guard (try? r.byte()) == SSHServer.msgKexInit else { return false }
        guard r.remaining >= 16 else { fail("short KEXINIT"); return false }
        r.pos += 16
        guard let kex = try? r.nameList(),
              let hostKeyList = try? r.nameList(),
              let encC2S = try? r.nameList(),
              let encS2C = try? r.nameList(),
              let _ = try? r.nameList(),
              let _ = try? r.nameList(),
              let compC2S = try? r.nameList(),
              let compS2C = try? r.nameList(),
              let _ = try? r.nameList(),
              let _ = try? r.nameList(),
              let _ = try? r.bool(),
              let reserved = try? r.uint32(),
              r.remaining == 0, reserved == 0
        else {
            fail("malformed KEXINIT")
            return false
        }
        let kexOK = kex.contains("curve25519-sha256") || kex.contains("curve25519-sha256@libssh.org")
        let hostOK = hostKeyList.contains("ssh-ed25519")
        let cipherOK = encC2S.contains("chacha20-poly1305@openssh.com")
            && encS2C.contains("chacha20-poly1305@openssh.com")
        let compOK = compC2S.contains("none") && compS2C.contains("none")
        guard kexOK, hostOK, cipherOK, compOK else {
            fail("no common algorithm")
            return false
        }
        iS = payload
        return true
    }

    private func sendECDHInit() {
        let ephemeral = config.ephemeralOverride ?? randomBytes(32)
        guard let eph = try? Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(ephemeral)
        ) else {
            fail("bad ephemeral secret")
            return
        }
        ephSecret = ephemeral
        qC = Array(eph.publicKey.rawRepresentation)
        var w = SSHWriter()
        w.byte(SSHServer.msgKexEcdhInit)
        w.string(qC)
        sendPacket(w.bytes)
        log("ecdh init sent")
    }

    private func handleECDHReply(_ payload: [UInt8]) {
        var r = SSHReader(payload)
        guard (try? r.byte()) == SSHServer.msgKexEcdhReply else {
            fail("malformed KEX_ECDH_REPLY")
            return
        }
        guard let kS = try? r.string(),
              let qS = try? r.string(),
              let sigBlob = try? r.string(),
              r.remaining == 0,
              qS.count == 32
        else {
            fail("malformed KEX_ECDH_REPLY")
            return
        }
        var kr = SSHReader(kS)
        guard (try? kr.stringUTF8()) == SSHServer.algorithmEd25519,
              let hostPub = try? kr.string(),
              kr.remaining == 0,
              hostPub.count == 32
        else {
            fail("malformed host key blob")
            return
        }
        guard hostPub == config.hostPublicKey else {
            fail("host key does not match pin")
            return
        }
        guard let eph = try? Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(ephSecret)
        ),
              let qsKey = try? Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: Data(qS)
              ),
              let shared = try? eph.sharedSecretFromKeyAgreement(with: qsKey)
        else {
            fail("ECDH failed")
            return
        }
        let kRaw = shared.withUnsafeBytes { Array($0) }
        if kRaw.allSatisfy({ $0 == 0 }) {
            fail("all-zero shared secret")
            return
        }
        let kMpint = SSHKDF.mpint(kRaw)
        let h = SSHKDF.exchangeHash(
            vc: Array(config.versionLine.utf8), vs: Array(serverVersion.utf8),
            ic: iC, isI: iS, ks: kS, qc: qC, qs: qS, kMpint: kMpint
        )
        var sr = SSHReader(sigBlob)
        guard (try? sr.stringUTF8()) == SSHServer.algorithmEd25519,
              let signature = try? sr.string(),
              sr.remaining == 0
        else {
            fail("malformed host-key signature")
            return
        }
        guard let host = try? Curve25519.Signing.PublicKey(
            rawRepresentation: Data(hostPub)
        ), host.isValidSignature(Data(signature), for: Data(h)) else {
            fail("host-key signature does not verify")
            return
        }
        sessionId = h
        pendingSendKey = SSHKDF.deriveKey(
            length: SSHOpenSSHCipher.keyLength, kMpint: kMpint, h: h,
            letter: Character("C").asciiValue!, sessionId: h
        )
        pendingRecvKey = SSHKDF.deriveKey(
            length: SSHOpenSSHCipher.keyLength, kMpint: kMpint, h: h,
            letter: Character("D").asciiValue!, sessionId: h
        )
        log("ecdh reply accepted; host key pinned")
    }

    private func sendServiceAndAuth() {
        var svc = SSHWriter()
        svc.byte(SSHServer.msgServiceRequest)
        svc.string(SSHServer.serviceUsereauth)
        sendPacket(svc.bytes)
        log("service-request ssh-userauth")
    }

    private func sendPublickey() {
        let pub = Array(userKey.publicKey.rawRepresentation)
        var keyBlob = SSHWriter()
        keyBlob.string(SSHServer.algorithmEd25519)
        keyBlob.string(pub)
        var signed = SSHWriter()
        signed.string(sessionId)
        signed.byte(SSHServer.msgUserauthRequest)
        signed.string(config.user)
        signed.string(SSHServer.serviceConnection)
        signed.string(SSHServer.methodPublickey)
        signed.bool(true)
        signed.string(SSHServer.algorithmEd25519)
        signed.string(keyBlob.bytes)
        guard let signature = try? userKey.signature(for: Data(signed.bytes)) else {
            fail("userauth signature failed")
            return
        }
        var sigBlob = SSHWriter()
        sigBlob.string(SSHServer.algorithmEd25519)
        sigBlob.string(Array(signature))
        var auth = SSHWriter()
        auth.byte(SSHServer.msgUserauthRequest)
        auth.string(config.user)
        auth.string(SSHServer.serviceConnection)
        auth.string(SSHServer.methodPublickey)
        auth.bool(true)
        auth.string(SSHServer.algorithmEd25519)
        auth.string(keyBlob.bytes)
        auth.string(sigBlob.bytes)
        sendPacket(auth.bytes)
        log("publickey request user=\(config.user)")
    }

    private func sendChannelOpen() {
        var open = SSHWriter()
        open.byte(SSHServer.msgChannelOpen)
        open.string(SSHServer.sessionType)
        open.uint32(localChannel)
        open.uint32(SSHServer.localWindow)
        open.uint32(SSHServer.localMaxPacket)
        sendPacket(open.bytes)
        log("channel-open session")
    }

    private func sendExec() {
        var exec = SSHWriter()
        exec.byte(SSHServer.msgChannelRequest)
        exec.uint32(serverChannel)
        exec.string(SSHServer.requestExec)
        exec.bool(true)
        exec.string(config.execCommand)
        sendPacket(exec.bytes)
        execSent = true
        log("exec \(config.execCommand)")
    }

    // MARK: - M168f (#2962): the scripted pty session

    private static let requestPty = "pty-req"
    private static let requestShell = "shell"
    private static let requestWindowChange = "window-change"
    private static let ptyTerm = "xterm-256color"

    /// RFC 4254 §6.2: TERM, character/rows, pixel geometry, encoded modes.
    static func ptyRequestPayload(recipient: UInt32, cols: UInt32, rows: UInt32) -> [UInt8] {
        var w = SSHWriter()
        w.byte(SSHServer.msgChannelRequest)
        w.uint32(recipient)
        w.string(requestPty)
        w.bool(true)
        w.string(ptyTerm)
        w.uint32(cols)
        w.uint32(rows)
        w.uint32(0)
        w.uint32(0)
        w.string("")
        return w.bytes
    }

    /// RFC 4254 §6.5: `shell` carries no request-specific fields.
    static func shellRequestPayload(recipient: UInt32) -> [UInt8] {
        var w = SSHWriter()
        w.byte(SSHServer.msgChannelRequest)
        w.uint32(recipient)
        w.string(requestShell)
        w.bool(true)
        return w.bytes
    }

    /// RFC 4254 §6.7: a notification — want_reply is false by the RFC.
    static func windowChangePayload(recipient: UInt32, cols: UInt32, rows: UInt32) -> [UInt8] {
        var w = SSHWriter()
        w.byte(SSHServer.msgChannelRequest)
        w.uint32(recipient)
        w.string(requestWindowChange)
        w.bool(false)
        w.uint32(cols)
        w.uint32(rows)
        w.uint32(0)
        w.uint32(0)
        return w.bytes
    }

    static func channelDataPayload(recipient: UInt32, data: [UInt8]) -> [UInt8] {
        var w = SSHWriter()
        w.byte(SSHServer.msgChannelData)
        w.uint32(recipient)
        w.string(data)
        return w.bytes
    }

    static func windowAdjustPayload(recipient: UInt32, amount: UInt32) -> [UInt8] {
        var w = SSHWriter()
        w.byte(SSHServer.msgChannelWindowAdjust)
        w.uint32(recipient)
        w.uint32(amount)
        return w.bytes
    }

    private func sendPtyRequest(cols: UInt32, rows: UInt32) {
        sendPacket(Self.ptyRequestPayload(recipient: serverChannel, cols: cols, rows: rows))
        outstandingRequest = .ptyReq
        log("pty-req \(cols)x\(rows) term=\(Self.ptyTerm)")
    }

    // CHANNEL_DATA the script's `send` ops produce is bounded by the peer's
    // advertised window and max-packet; a remainder waits for the peer's
    // WINDOW_ADJUST, same contract as sshlib's flushChannel.
    private func queueChannelData(_ data: [UInt8]) {
        pendingData.append(contentsOf: data)
        flushPendingData()
    }

    private func flushPendingData() {
        let maxPacket = remoteMaxPacket == 0 ? UInt32.max : remoteMaxPacket
        while !pendingData.isEmpty && remoteWindow > 0 {
            let n = min(Int(remoteWindow), Int(maxPacket), pendingData.count)
            sendPacket(Self.channelDataPayload(
                recipient: serverChannel, data: Array(pendingData[0 ..< n])
            ))
            pendingData.removeFirst(n)
            remoteWindow -= UInt32(n)
        }
    }

    // The channel-stream match for `after <text>`: the cursor never moves
    // back, so a later `after` waits for a fresh occurrence.
    private func findNeedle(_ needle: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, start < stdout.count else { return nil }
        var i = start
        while i + needle.count <= stdout.count {
            var j = 0
            while j < needle.count && stdout[i + j] == needle[j] { j += 1 }
            if j == needle.count { return i + needle.count }
            i += 1
        }
        return nil
    }

    // Walk the parsed key script against the decrypted channel stream: each
    // `after` blocks until its bytes appear; `send` and `resize` emit
    // immediately. Runs once per inbound packet while the session is live.
    private func runScript() {
        guard sessionLive, var script = keyScript else { return }
        while let op = script.current {
            switch op {
            case .after(let needle):
                guard let end = findNeedle(needle, from: scriptCursor) else {
                    keyScript = script
                    return
                }
                scriptCursor = end
                script.advance()
                log("keys: after matched at stream offset \(end)")
            case .send(let bytes):
                queueChannelData(bytes)
                script.advance()
                log("keys: sent \(bytes.count) byte(s)")
            case .resize(let cols, let rows):
                sendPacket(Self.windowChangePayload(
                    recipient: serverChannel, cols: cols, rows: rows
                ))
                script.advance()
                log("keys: resize \(cols)x\(rows)")
            }
        }
        keyScript = script
        if !scriptDoneLogged {
            scriptDoneLogged = true
            log("keys: script done")
        }
    }

    private func handleEncrypted(_ payload: [UInt8]) {
        guard let kind = payload.first else { return }
        switch kind {
        case SSHServer.msgIgnore, SSHServer.msgDebug:
            break
        case SSHServer.msgDisconnect:
            log("server disconnect")
            phase = .closed
        case SSHServer.msgServiceAccept:
            log("service-accept")
            sendPublickey()
        case SSHServer.msgUserauthFailure:
            fail("publickey rejected")
        case SSHServer.msgUserauthSuccess:
            authed = true
            log("publickey accepted user=\(config.user) key=ssh-ed25519")
            sendChannelOpen()
        case SSHServer.msgChannelOpenConfirmation:
            var r = SSHReader(payload)
            _ = try? r.byte()
            guard let recip = try? r.uint32(),
                  let sender = try? r.uint32(),
                  recip == localChannel
            else {
                fail("malformed channel confirm")
                return
            }
            guard let win = try? r.uint32(), let maxPacket = try? r.uint32() else {
                fail("malformed channel confirm")
                return
            }
            remoteWindow = win
            remoteMaxPacket = maxPacket
            serverChannel = sender
            channelOpen = true
            log("channel confirmed remote=\(sender)")
            if let pty = config.pty {
                sendPtyRequest(cols: pty.cols, rows: pty.rows)
            } else {
                sendExec()
            }
        case SSHServer.msgChannelSuccess:
            switch outstandingRequest {
            case .ptyReq:
                outstandingRequest = .shell
                sendPacket(Self.shellRequestPayload(recipient: serverChannel))
                log("pty-req granted; shell sent")
            case .shell:
                outstandingRequest = .none
                sessionLive = true
                log("shell granted; pty session live")
                runScript()
            case .none:
                log("channel success")
            }
        case SSHServer.msgChannelFailure:
            fail("channel request failed")
        case SSHServer.msgChannelWindowAdjust:
            var r = SSHReader(payload)
            _ = try? r.byte()
            _ = try? r.uint32()
            if let add = try? r.uint32() {
                remoteWindow = add > UInt32.max - remoteWindow
                    ? UInt32.max : remoteWindow + add
                flushPendingData()
            }
        case SSHServer.msgChannelData:
            var r = SSHReader(payload)
            _ = try? r.byte()
            _ = try? r.uint32()
            if let data = try? r.string() {
                guard data.count <= localWindowLeft else {
                    fail("channel data past advertised window")
                    return
                }
                stdout.append(contentsOf: data)
                localWindowLeft -= UInt32(data.count)
                windowConsumed += UInt32(data.count)
                // Return credit as the stream is consumed — sshlib's Drain
                // uses the same half-window threshold.
                if windowConsumed >= SSHServer.localWindow / 2 {
                    sendPacket(Self.windowAdjustPayload(
                        recipient: serverChannel, amount: windowConsumed
                    ))
                    localWindowLeft += windowConsumed
                    windowConsumed = 0
                }
                runScript()
            }
        case SSHServer.msgChannelRequest:
            var r = SSHReader(payload)
            _ = try? r.byte()
            _ = try? r.uint32()
            guard let name = try? r.stringUTF8() else { return }
            _ = try? r.bool()
            if name == SSHServer.requestExitStatus, let st = try? r.uint32() {
                exitStatus = st
                if config.pty != nil {
                    // The session stream is binary frames — summarize it
                    // instead of the exec path's text dump.
                    log("pty bytes=\(stdout.count)")
                    ptyBytesLogged = true
                } else {
                    let text = String(decoding: stdout, as: UTF8.self)
                        .trimmingCharacters(in: .newlines)
                    log("stdout \(text)")
                }
                log("exit-status=\(st)")
            }
        case SSHServer.msgChannelEof:
            log("channel eof")
        case SSHServer.msgChannelClose:
            if config.pty != nil && !ptyBytesLogged {
                log("pty bytes=\(stdout.count)")
                ptyBytesLogged = true
            }
            log("channel close")
            phase = .closed
        default:
            log("unhandled message \(kind)")
        }
    }

    private func nextPlainPacket() -> [UInt8]? {
        guard input.count >= 4 else { return nil }
        let packetLength = (Int(input[0]) << 24) | (Int(input[1]) << 16)
            | (Int(input[2]) << 8) | Int(input[3])
        guard packetLength <= SSHPacket.maxTotal - 4, packetLength >= 5 else {
            fail("bad plaintext length")
            return nil
        }
        let total = 4 + packetLength
        guard input.count >= total else { return nil }
        let frame = Array(input[0 ..< total])
        input.removeFirst(total)
        do {
            let payload = try SSHPacket.decode(frame, alignment: .plaintext)
            recvSeq += 1
            return payload
        } catch {
            fail("malformed plaintext frame")
            return nil
        }
    }

    private func nextEncryptedPacket() -> [UInt8]? {
        guard let cipher = recvCipher else { return nil }
        guard input.count >= 4 else { return nil }
        let length = Int(cipher.decryptLength(Array(input[0 ..< 4]), seq: recvSeq))
        guard length >= 5, length <= SSHPacket.maxTotal - 4 else {
            fail("bad encrypted length")
            return nil
        }
        let ctLength = 4 + length
        let wire = ctLength + SSHOpenSSHCipher.tagLength
        guard input.count >= wire else { return nil }
        let ct = Array(input[0 ..< ctLength])
        let tag = Array(input[ctLength ..< wire])
        guard let plain = cipher.open(ciphertext: ct, tag: tag, seq: recvSeq) else {
            log("mac-failure — disconnecting")
            phase = .failed
            return nil
        }
        input.removeFirst(wire)
        recvSeq += 1
        do {
            return try SSHPacket.decode(plain, alignment: .aead)
        } catch {
            fail("malformed encrypted frame")
            return nil
        }
    }

    private func sendPacket(_ payload: [UInt8]) {
        let alignment: SSHPacketAlignment = sendCipher == nil ? .plaintext : .aead
        let n = SSHPacket.paddingLen(payload.count, alignment: alignment)
        let pad = (0 ..< n).map { UInt8(0x5a ^ (($0 * 7) & 0xff)) }
        guard let frame = try? SSHPacket.encode(
            payload: payload, pad: pad, alignment: alignment
        ) else {
            fail("could not frame outbound packet")
            return
        }
        if let cipher = sendCipher {
            let (ciphertext, tag) = cipher.seal(frame, seq: sendSeq)
            out.append(contentsOf: ciphertext)
            out.append(contentsOf: tag)
        } else {
            out.append(contentsOf: frame)
        }
        sendSeq += 1
    }

    private func randomBytes(_ n: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0 ..< n).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
    }

    private func fail(_ reason: String) {
        log("protocol failure: \(reason)")
        phase = .failed
    }
}

// M168f (#2962): the `--net-tcp-connect-ssh-keys` line script. One op per
// line, evaluated in order against the decrypted channel stream once the
// pty session is live:
//
//   after <text>             wait until the stream carries these bytes
//   send <escaped bytes>     emit CHANNEL_DATA (escapes: \\ \n \r \t \0 \e \xNN)
//   resize <cols>x<rows>     emit a `window-change` channel request
//
// Blank lines and `#` comments are ignored. The argument is the rest of
// the line after the verb's single separating space — `after`/`send`
// arguments are backslash-unescaped, `resize` takes literal `<cols>x<rows>`.
public struct SSHKeyScript: Equatable {
    public enum Op: Equatable {
        case after([UInt8])
        case send([UInt8])
        case resize(cols: UInt32, rows: UInt32)
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let line: Int
        public let reason: String
        public var description: String { "line \(line): \(reason)" }
    }

    public let ops: [Op]
    public private(set) var index = 0

    public var current: Op? { index < ops.count ? ops[index] : nil }
    public var isDone: Bool { index >= ops.count }

    public mutating func advance() { index += 1 }

    public init(text: String) throws {
        var parsed: [Op] = []
        var lineNo = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNo += 1
            var line = raw.drop(while: { $0 == " " || $0 == "\t" })
            if line.last == "\r" { line = line.dropLast() }
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let sp = line.firstIndex(of: " ") else {
                throw ParseError(line: lineNo, reason: "expected 'after|send|resize <arg>'")
            }
            let verb = line[..<sp]
            let arg = line[line.index(after: sp)...]
            switch verb {
            case "after":
                parsed.append(.after(try Self.unescape(arg, line: lineNo, allowEmpty: false)))
            case "send":
                parsed.append(.send(try Self.unescape(arg, line: lineNo, allowEmpty: false)))
            case "resize":
                parsed.append(try Self.resizeOp(arg, line: lineNo))
            default:
                throw ParseError(line: lineNo, reason: "unknown verb '\(verb)'")
            }
        }
        ops = parsed
    }

    private static func unescape(
        _ s: Substring, line: Int, allowEmpty: Bool
    ) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "\\" else {
                bytes.append(contentsOf: String(c).utf8)
                i = s.index(after: i)
                continue
            }
            let e = s.index(after: i)
            guard e < s.endIndex else {
                throw ParseError(line: line, reason: "trailing backslash")
            }
            switch s[e] {
            case "n": bytes.append(0x0a)
            case "r": bytes.append(0x0d)
            case "t": bytes.append(0x09)
            case "0": bytes.append(0x00)
            case "e": bytes.append(0x1b)
            case "\\": bytes.append(0x5c)
            case "x":
                let h1 = s.index(after: e)
                guard h1 < s.endIndex, let h2 = s.index(h1, offsetBy: 1, limitedBy: s.endIndex),
                      h2 < s.endIndex,
                      let v = UInt8(s[h1 ... h2], radix: 16)
                else {
                    throw ParseError(line: line, reason: "bad \\xNN escape")
                }
                bytes.append(v)
                i = s.index(after: h2)
                continue
            default:
                throw ParseError(line: line, reason: "unknown escape '\\\(s[e])'")
            }
            i = s.index(after: e)
        }
        guard allowEmpty || !bytes.isEmpty else {
            throw ParseError(line: line, reason: "empty argument")
        }
        return bytes
    }

    private static func resizeOp(_ s: Substring, line: Int) throws -> Op {
        let halves = s.split(separator: "x", omittingEmptySubsequences: false)
        guard halves.count == 2,
              let cols = UInt32(halves[0]), let rows = UInt32(halves[1]),
              cols > 0, rows > 0, cols <= 65535, rows <= 65535
        else {
            throw ParseError(line: line, reason: "resize expects <cols>x<rows>")
        }
        return .resize(cols: cols, rows: rows)
    }
}
