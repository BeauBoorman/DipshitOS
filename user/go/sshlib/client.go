// SSH-2 client state machine (M71j / #1569): the ADR 0025 D2 profile as
// an outbound guest. Feed is a pure byte-stream step — production wraps
// it over vi.Conn; host tests drive it against Server with no VM.
package sshlib

import "virelai/ed25519"

const (
	// Distinct local failure stages (user/src/ssh.zig). 0 is also a remote
	// exec success; 255 is OpenSSH-style "no exit-status".
	ExitOK        = 0
	ExitUsage     = 1
	ExitConnect   = 2
	ExitKex       = 3
	ExitPin       = 4
	ExitAuth      = 5
	ExitChannel   = 6
	ExitRequest   = 7
	ExitTransport = 8
	ExitBound     = 9
	ExitTty       = 10
	ExitNoStatus  = 255

	clientLocalID   uint32 = 0
	rekeyMaxBytes          = 1 << 30
	rekeyMaxPackets        = 1 << 20
)

// ClientConfig is the injected identity, pin, and entropy the client needs
// before it sends a packet. Production fills these from TS5 + KNOWN_HOSTS.
type ClientConfig struct {
	User      string
	Cmd       string // empty selects shell; GOSSH.ELF gates use exec
	HostPin   [32]byte
	HasPin    bool
	UserSeed  [32]byte
	HasSeed   bool
	Entropy   EntropyFunc
	Ident     string
	Cookie    []byte
	Ephemeral []byte
	Log       func(string)
}

// Client is one outbound SSH-2 session.
type Client struct {
	cfg               ClientConfig
	phase             phase
	input             []byte
	out               []byte
	banners           int
	serverVer         string
	iC, iS            []byte
	qC                []byte
	sessionID         []byte
	hostKey           [32]byte
	sendCipher        *Cipher
	recvCipher        *Cipher
	sendSeq           uint64
	recvSeq           uint64
	flushAfterNewkeys bool
	pendingService    bool
	encBytes          uint64
	encPackets        uint64
	authState         int // 0 service, 1 none, 2 pubkey, 3 done
	chanState         int // 0 idle, 1 opening, 2 open, 3 exec, 4 closing
	remoteID          uint32
	remoteSet         bool
	remoteWin         uint32
	remoteMax         uint32
	Stdout            []byte
	ExitStatus        *uint32
	gotEOF            bool
	ErrName           string
	Stage             string
	ExitCode          int
	RemoteChan        uint32
}

func NewClient(cfg ClientConfig) *Client {
	if cfg.Ident == "" {
		cfg.Ident = IdentLine
	}
	if cfg.Log == nil {
		cfg.Log = func(string) {}
	}
	if cfg.Entropy == nil {
		cfg.Entropy = func(b []byte) error {
			for i := range b {
				b[i] = 0x5a
			}
			return nil
		}
	}
	if cfg.User == "" {
		cfg.User = "virelai"
	}
	return &Client{
		cfg:      cfg,
		phase:    phaseVersion,
		ExitCode: ExitTransport,
		Stage:    "kex",
	}
}

func (c *Client) Closed() bool { return c.phase == phaseClosed || c.phase == phaseFailed }

func (c *Client) Failed() bool { return c.phase == phaseFailed }

// Start emits the identification line and our KEXINIT. Call once, then Feed.
func (c *Client) Start() []byte {
	c.out = append(c.out, []byte(c.cfg.Ident+"\r\n")...)
	c.sendKexInit()
	out := c.out
	c.out = nil
	return out
}

func (c *Client) Feed(data []byte) []byte {
	if c.Closed() {
		return nil
	}
	c.input = append(c.input, data...)
	c.process()
	out := c.out
	c.out = nil
	return out
}

func (c *Client) process() {
	if c.pendingService {
		c.pendingService = false
		c.sendServiceRequest()
		return
	}
	for !c.Closed() {
		switch c.phase {
		case phaseVersion:
			if !c.readVersion() {
				return
			}
		case phaseKex:
			payload, ok := c.nextPlain()
			if !ok {
				return
			}
			c.handleKex(payload)
			// NEWKEYS is plaintext; the first encrypted packet must not share
			// a TCP write with it. The runner's responder installs the AEAD
			// on NEWKEYS and then DecryptLength's any leftover in the same
			// feed — a combined NEWKEYS||SERVICE_REQUEST was observed as
			// "bad encrypted length" on VZ (live-ssh-nocred / negative 02).
			if c.flushAfterNewkeys {
				c.flushAfterNewkeys = false
				return
			}
		case phaseEncrypted:
			payload, ok := c.nextEncrypted()
			if !ok {
				return
			}
			c.handleEncrypted(payload)
		default:
			return
		}
	}
}

func (c *Client) readVersion() bool {
	for {
		nl := -1
		for i, b := range c.input {
			if b == 0x0a {
				nl = i
				break
			}
		}
		if nl < 0 {
			if len(c.input) > 255 {
				c.fail("kex", "BadVersion", ExitKex, "version too long")
			}
			return false
		}
		raw := c.input[:nl]
		c.input = c.input[nl+1:]
		if len(raw) > 0 && raw[len(raw)-1] == 0x0d {
			raw = raw[:len(raw)-1]
		}
		if len(raw) < 4 || string(raw[:4]) != "SSH-" {
			c.banners++
			if c.banners > 64 {
				c.fail("kex", "TooManyBannerLines", ExitKex, "too many banner lines")
				return false
			}
			continue
		}
		text := string(raw)
		if !(len(text) >= 8 && (text[:8] == "SSH-2.0-" || (len(text) >= 9 && text[:9] == "SSH-1.99-"))) {
			c.fail("kex", "BadVersion", ExitKex, "bad identification line")
			return false
		}
		c.serverVer = text
		c.cfg.Log("version received: " + text)
		c.phase = phaseKex
		return true
	}
}

func (c *Client) sendKexInit() {
	var w Writer
	w.Byte(MsgKexInit)
	cookie := c.cfg.Cookie
	if len(cookie) != 16 {
		var buf [16]byte
		_ = c.cfg.Entropy(buf[:])
		cookie = buf[:]
	}
	w.Raw(cookie)
	w.NameList([]string{KexCurve, KexCurveAlias})
	w.NameList([]string{AlgoEd25519})
	w.NameList([]string{CipherOpenSSH})
	w.NameList([]string{CipherOpenSSH})
	w.NameList(nil)
	w.NameList(nil)
	w.NameList([]string{CompNone})
	w.NameList([]string{CompNone})
	w.NameList(nil)
	w.NameList(nil)
	w.BoolVal(false)
	w.U32(0)
	c.iC = append([]byte(nil), w.B...)
	c.sendPacket(c.iC)
}

func (c *Client) nextPlain() ([]byte, bool) {
	if len(c.input) < 4 {
		return nil, false
	}
	packetLength := int(c.input[0])<<24 | int(c.input[1])<<16 | int(c.input[2])<<8 | int(c.input[3])
	if packetLength > PktMaxTotal-4 || packetLength < 5 {
		c.fail("protocol", "BadPacket", ExitTransport, "bad plaintext length")
		return nil, false
	}
	total := 4 + packetLength
	if len(c.input) < total {
		return nil, false
	}
	frame := c.input[:total]
	c.input = c.input[total:]
	payload, ok := DecodePacket(frame, AlignPlain)
	if !ok {
		c.fail("protocol", "BadPacket", ExitTransport, "malformed plaintext frame")
		return nil, false
	}
	c.recvSeq++
	return payload, true
}

func (c *Client) handleKex(payload []byte) {
	if len(payload) == 0 {
		c.fail("kex", "BadKexInit", ExitKex, "empty kex packet")
		return
	}
	switch payload[0] {
	case MsgKexInit:
		if !c.parseServerKexInit(payload) {
			return
		}
		c.cfg.Log("kexinit received (suite negotiated)")
		c.sendECDHInit()
	case MsgKexECDHReply:
		c.handleECDHReply(payload)
	case MsgNewKeys:
		if len(payload) != 1 {
			c.fail("kex", "BadKexReply", ExitKex, "malformed NEWKEYS")
			return
		}
		if c.sendCipher == nil {
			c.fail("kex", "UnexpectedMessage", ExitKex, "NEWKEYS before reply")
			return
		}
		c.cfg.Log("newkeys received; cipher installed")
		c.phase = phaseEncrypted
		if !c.checkPin() {
			return
		}
		// Do not emit SERVICE_REQUEST in this Feed. The runner's capture
		// thread concatenates guest segments that land in one virtio used
		// burst; NEWKEYS||ciphertext in a single feed DecryptLength's as
		// "bad encrypted length". The next Feed (nil) sends the request
		// after the caller has yielded.
		c.pendingService = true
		return
	case MsgDisconnect:
		c.fail("disconnect", "PeerDisconnect", ExitTransport, "peer disconnect during kex")
	case MsgIgnore, MsgDebug:
	default:
		c.fail("kex", "UnexpectedMessage", ExitKex, "unexpected kex message")
	}
}

func (c *Client) parseServerKexInit(payload []byte) bool {
	r := Reader{B: payload}
	if b, ok := r.Byte(); !ok || b != MsgKexInit {
		c.fail("kex", "BadKexInit", ExitKex, "malformed KEXINIT")
		return false
	}
	if r.Remaining() < 16 {
		c.fail("kex", "BadKexInit", ExitKex, "short KEXINIT")
		return false
	}
	r.Pos += 16
	kex, ok1 := r.NameList()
	host, ok2 := r.NameList()
	encC, ok3 := r.NameList()
	encS, ok4 := r.NameList()
	_, ok5 := r.NameList()
	_, ok6 := r.NameList()
	compC, ok7 := r.NameList()
	compS, ok8 := r.NameList()
	_, ok9 := r.NameList()
	_, ok10 := r.NameList()
	_, ok11 := r.BoolVal()
	reserved, ok12 := r.U32()
	if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 || !ok6 || !ok7 || !ok8 || !ok9 || !ok10 || !ok11 || !ok12 || r.Remaining() != 0 || reserved != 0 {
		c.fail("kex", "BadKexInit", ExitKex, "malformed KEXINIT")
		return false
	}
	kexOK := ContainsName(kex, KexCurve) || ContainsName(kex, KexCurveAlias)
	hostOK := ContainsName(host, AlgoEd25519)
	cipherOK := ContainsName(encC, CipherOpenSSH) && ContainsName(encS, CipherOpenSSH)
	compOK := ContainsName(compC, CompNone) && ContainsName(compS, CompNone)
	if !kexOK || !hostOK || !cipherOK || !compOK {
		c.fail("kex", "NoCommonKex", ExitKex, "no common algorithm")
		return false
	}
	c.iS = append([]byte(nil), payload...)
	return true
}

func (c *Client) sendECDHInit() {
	var eph [32]byte
	if len(c.cfg.Ephemeral) == 32 {
		copy(eph[:], c.cfg.Ephemeral)
	} else if err := c.cfg.Entropy(eph[:]); err != nil {
		c.fail("kex", "Entropy", ExitKex, "entropy")
		return
	}
	qC, ok := ed25519.X25519Base(eph)
	if !ok {
		c.fail("kex", "BadEphemeralKey", ExitKex, "bad ephemeral secret")
		return
	}
	c.qC = qC[:]
	// Stash the secret in Ephemeral so handleECDHReply can reuse it.
	c.cfg.Ephemeral = append([]byte(nil), eph[:]...)
	Wipe(eph[:])
	var w Writer
	w.Byte(MsgKexECDHInit)
	w.Str(c.qC)
	c.sendPacket(w.B)
}

func (c *Client) handleECDHReply(payload []byte) {
	r := Reader{B: payload}
	if b, ok := r.Byte(); !ok || b != MsgKexECDHReply {
		c.fail("kex", "BadKexReply", ExitKex, "malformed KEX_ECDH_REPLY")
		return
	}
	kS, ok1 := r.Str()
	qS, ok2 := r.Str()
	sigBlob, ok3 := r.Str()
	if !ok1 || !ok2 || !ok3 || r.Remaining() != 0 || len(qS) != 32 {
		c.fail("kex", "BadKexReply", ExitKex, "malformed KEX_ECDH_REPLY")
		return
	}
	host, ok := parseEd25519Blob(kS)
	if !ok {
		c.fail("kex", "BadHostKey", ExitKex, "bad host key blob")
		return
	}
	c.hostKey = host
	if len(c.cfg.Ephemeral) != 32 {
		c.fail("kex", "BadEphemeralKey", ExitKex, "missing ephemeral")
		return
	}
	var eph, qSa [32]byte
	copy(eph[:], c.cfg.Ephemeral)
	Wipe(c.cfg.Ephemeral)
	c.cfg.Ephemeral = nil
	copy(qSa[:], qS)
	kRaw, ok := ed25519.X25519(eph, qSa)
	Wipe(eph[:])
	if !ok {
		c.fail("kex", "WeakSharedSecret", ExitKex, "all-zero shared secret")
		return
	}
	kMpint := Mpint(kRaw[:])
	Wipe(kRaw[:])
	h := ExchangeHash(
		[]byte(c.cfg.Ident), []byte(c.serverVer),
		c.iC, c.iS, kS, c.qC, qS, kMpint,
	)
	if !verifyHostSig(sigBlob, h[:], host) {
		c.fail("kex", "BadSignature", ExitKex, "host-key signature")
		return
	}
	c.sessionID = h[:]
	keyC2S := DeriveKey(CipherKeyLen, kMpint, h[:], 'C', h[:])
	keyS2C := DeriveKey(CipherKeyLen, kMpint, h[:], 'D', h[:])
	c.sendPacket([]byte{MsgNewKeys})
	var send, recv Cipher
	copy(send.Key[:], keyC2S)
	copy(recv.Key[:], keyS2C)
	c.sendCipher = &send
	c.recvCipher = &recv
	Wipe(keyC2S)
	Wipe(keyS2C)
	c.cfg.Log("ecdh reply accepted; host key verified")
	c.flushAfterNewkeys = true
}

func verifyHostSig(sigBlob, h []byte, host [32]byte) bool {
	sr := Reader{B: sigBlob}
	alg, okS := sr.StrUTF8()
	sigBytes, okT := sr.Str()
	if !okS || !okT || sr.Remaining() != 0 || alg != AlgoEd25519 || len(sigBytes) != 64 {
		return false
	}
	var sig [64]byte
	copy(sig[:], sigBytes)
	return ed25519.EdVerify(sig, h, host)
}

func (c *Client) checkPin() bool {
	if !c.cfg.HasPin {
		c.fail("auth", "MissingHostPin", ExitPin, "missing host pin")
		return false
	}
	if c.cfg.HostPin != c.hostKey {
		c.fail("auth", "HostKeyMismatch", ExitPin, "host key pin mismatch")
		return false
	}
	c.cfg.Log("pin ok")
	return true
}

func (c *Client) sendServiceRequest() {
	var w Writer
	w.Byte(MsgServiceRequest)
	w.StrS(SvcUserauth)
	c.sendPacket(w.B)
	c.authState = 1
}

func (c *Client) nextEncrypted() ([]byte, bool) {
	if c.recvCipher == nil || len(c.input) < 4 {
		return nil, false
	}
	length := int(c.recvCipher.DecryptLength(c.input[:4], c.recvSeq))
	if length < 5 || length > PktMaxTotal-4 {
		c.fail("protocol", "BadPacket", ExitTransport, "bad encrypted length")
		return nil, false
	}
	ctLen := 4 + length
	wire := ctLen + PolyTagLen
	if len(c.input) < wire {
		return nil, false
	}
	ct := c.input[:ctLen]
	tag := c.input[ctLen:wire]
	plain := c.recvCipher.Open(ct, tag, c.recvSeq)
	if plain == nil {
		c.fail("protocol", "BadPacket", ExitTransport, "mac-failure")
		return nil, false
	}
	c.input = c.input[wire:]
	c.recvSeq++
	payload, ok := DecodePacket(plain, AlignAEAD)
	if !ok {
		c.fail("protocol", "BadPacket", ExitTransport, "malformed encrypted frame")
		return nil, false
	}
	return payload, true
}

func (c *Client) handleEncrypted(payload []byte) {
	if len(payload) == 0 {
		return
	}
	switch payload[0] {
	case MsgIgnore, MsgDebug, MsgUserauthBanner:
	case MsgDisconnect:
		c.fail("disconnect", "PeerDisconnect", ExitTransport, "peer disconnect")
	case MsgServiceAccept:
		c.handleServiceAccept(payload)
	case MsgUserauthFail:
		c.handleUserauthFail(payload)
	case MsgUserauthOK:
		c.cfg.Log("publickey accepted")
		c.authState = 3
		c.openChannel()
	case MsgGlobalRequest:
		c.handleGlobalRequest(payload)
	case MsgChannelConfirm:
		c.handleChannelConfirm(payload)
	case MsgChannelOpenFail:
		c.fail("channel", "OpenRejected", ExitChannel, "channel open refused")
	case MsgChannelData:
		c.handleChannelData(payload)
	case MsgExtendedData:
		c.handleExtendedData(payload)
	case MsgChannelWindow:
		r := Reader{B: payload}
		_, _ = r.Byte()
		_, _ = r.U32()
		if add, ok := r.U32(); ok {
			c.remoteWin += add
		}
	case MsgChannelReq:
		c.handleChannelReq(payload)
	case MsgChannelOK:
		if c.chanState == 3 {
			c.cfg.Log("exec accepted")
		}
	case MsgChannelFail:
		c.fail("request", "BadState", ExitRequest, "channel request refused")
	case MsgChannelEOF:
		c.gotEOF = true
		c.cfg.Log("eof")
	case MsgChannelClose:
		c.cfg.Log("channel close")
		if !c.gotEOF {
			c.gotEOF = true
		}
		c.phase = phaseClosed
	default:
		c.cfg.Log("unhandled message")
	}
}

func (c *Client) handleServiceAccept(payload []byte) {
	r := Reader{B: payload}
	_, _ = r.Byte()
	name, ok := r.StrUTF8()
	if !ok || name != SvcUserauth {
		c.fail("auth", "ServiceRejected", ExitAuth, "service rejected")
		return
	}
	c.cfg.Log("service-accept ssh-userauth")
	var w Writer
	w.Byte(MsgUserauthReq)
	w.StrS(c.cfg.User)
	w.StrS(SvcConnection)
	w.StrS(MethodNone)
	c.sendPacket(w.B)
}

func (c *Client) handleUserauthFail(payload []byte) {
	r := Reader{B: payload}
	_, _ = r.Byte()
	methods, ok := r.NameList()
	_, _ = r.BoolVal()
	if !ok {
		c.fail("auth", "BadMessage", ExitAuth, "malformed USERAUTH_FAILURE")
		return
	}
	if c.authState >= 2 {
		c.fail("auth", "AuthRejected", ExitAuth, "publickey rejected")
		return
	}
	if c.authState != 1 {
		c.fail("auth", "UnexpectedMessage", ExitAuth, "unexpected USERAUTH_FAILURE")
		return
	}
	if !ContainsName(methods, MethodPubKey) {
		c.fail("auth", "NoSupportedAuth", ExitAuth, "no publickey offer")
		return
	}
	if !c.cfg.HasSeed {
		c.fail("auth", "MissingCredential", ExitAuth, "missing ssh-user-ed25519")
		return
	}
	c.sendPublickey()
}

func (c *Client) sendPublickey() {
	pub := ed25519.EdDerivePublic(c.cfg.UserSeed)
	var kb Writer
	kb.StrS(AlgoEd25519)
	kb.Str(pub[:])
	var signed Writer
	signed.Str(c.sessionID)
	signed.Byte(MsgUserauthReq)
	signed.StrS(c.cfg.User)
	signed.StrS(SvcConnection)
	signed.StrS(MethodPubKey)
	signed.BoolVal(true)
	signed.StrS(AlgoEd25519)
	signed.Str(kb.B)
	sig := ed25519.EdSign(signed.B, c.cfg.UserSeed)
	var sb Writer
	sb.StrS(AlgoEd25519)
	sb.Str(sig[:])
	var auth Writer
	auth.Byte(MsgUserauthReq)
	auth.StrS(c.cfg.User)
	auth.StrS(SvcConnection)
	auth.StrS(MethodPubKey)
	auth.BoolVal(true)
	auth.StrS(AlgoEd25519)
	auth.Str(kb.B)
	auth.Str(sb.B)
	c.sendPacket(auth.B)
	c.authState = 2
	Wipe(sig[:])
}

func (c *Client) handleGlobalRequest(payload []byte) {
	r := Reader{B: payload}
	_, _ = r.Byte()
	_, _ = r.StrUTF8()
	want, ok := r.BoolVal()
	if !ok {
		return
	}
	if want {
		c.sendPacket([]byte{MsgRequestFailure})
	}
}

func (c *Client) openChannel() {
	var w Writer
	w.Byte(MsgChannelOpen)
	w.StrS(ChanSession)
	w.U32(clientLocalID)
	w.U32(LocalWindow)
	w.U32(LocalMaxPacket)
	c.sendPacket(w.B)
	c.chanState = 1
}

func (c *Client) handleChannelConfirm(payload []byte) {
	r := Reader{B: payload}
	_, _ = r.Byte()
	recip, ok1 := r.U32()
	sender, ok2 := r.U32()
	window, ok3 := r.U32()
	maxPkt, ok4 := r.U32()
	if !ok1 || !ok2 || !ok3 || !ok4 || recip != clientLocalID {
		c.fail("channel", "Protocol", ExitChannel, "malformed OPEN_CONFIRMATION")
		return
	}
	c.remoteID = sender
	c.RemoteChan = sender
	c.remoteSet = true
	c.remoteWin = window
	c.remoteMax = maxPkt
	c.chanState = 2
	c.cfg.Log("channel open")
	if c.cfg.Cmd == "" {
		c.fail("tty", "NoTty", ExitTty, "interactive shell needs a tty")
		return
	}
	var w Writer
	w.Byte(MsgChannelReq)
	w.U32(c.remoteID)
	w.StrS(ReqExec)
	w.BoolVal(true)
	w.StrS(c.cfg.Cmd)
	c.sendPacket(w.B)
	c.chanState = 3
}

func (c *Client) handleChannelData(payload []byte) {
	r := Reader{B: payload}
	_, _ = r.Byte()
	recip, ok1 := r.U32()
	body, ok2 := r.Str()
	if !ok1 || !ok2 || recip != clientLocalID {
		c.fail("channel", "Protocol", ExitChannel, "malformed CHANNEL_DATA")
		return
	}
	c.Stdout = append(c.Stdout, body...)
}

func (c *Client) handleExtendedData(payload []byte) {
	r := Reader{B: payload}
	_, _ = r.Byte()
	recip, ok1 := r.U32()
	_, ok2 := r.U32()
	body, ok3 := r.Str()
	if !ok1 || !ok2 || !ok3 || recip != clientLocalID {
		return
	}
	c.Stdout = append(c.Stdout, body...)
}

func (c *Client) handleChannelReq(payload []byte) {
	r := Reader{B: payload}
	_, _ = r.Byte()
	recip, ok1 := r.U32()
	req, ok2 := r.StrUTF8()
	want, ok3 := r.BoolVal()
	if !ok1 || !ok2 || !ok3 || recip != clientLocalID {
		return
	}
	switch req {
	case ReqExitStatus:
		st, ok := r.U32()
		if ok {
			v := st
			c.ExitStatus = &v
			c.cfg.Log("exit-status")
		}
	}
	if want {
		var w Writer
		w.Byte(MsgChannelFail)
		w.U32(c.remoteID)
		c.sendPacket(w.B)
	}
}

func (c *Client) sendPacket(payload []byte) {
	align := AlignPlain
	if c.sendCipher != nil {
		align = AlignAEAD
		c.encPackets++
		if c.encPackets > rekeyMaxPackets || c.encBytes > rekeyMaxBytes {
			c.fail("bound", "NoRekey", ExitBound, "no-rekey bound")
			return
		}
	}
	pad := make([]byte, PaddingLen(len(payload), align))
	_ = c.cfg.Entropy(pad)
	frame, ok := EncodePacket(payload, pad, align)
	if !ok {
		c.fail("protocol", "BadPacket", ExitTransport, "could not frame outbound packet")
		return
	}
	if c.sendCipher != nil {
		ct, tag := c.sendCipher.Seal(frame, c.sendSeq)
		c.out = append(c.out, ct...)
		c.out = append(c.out, tag...)
		c.encBytes += uint64(len(ct) + len(tag))
	} else {
		c.out = append(c.out, frame...)
	}
	c.sendSeq++
}

func (c *Client) fail(stage, name string, code int, reason string) {
	c.Stage = stage
	c.ErrName = name
	c.ExitCode = code
	c.cfg.Log("fail " + stage + " " + name + " " + reason)
	c.phase = phaseFailed
}

// ParseKnownHosts reads the ADR 0025 D3 #v1 pin file. ok is false on a
// malformed file; found is false when the host:port has no pin.
func ParseKnownHosts(body, host string, port uint16) (pin [32]byte, found, ok bool) {
	lines := splitLines(body)
	if len(lines) == 0 || lines[0] != "#v1" {
		return pin, false, false
	}
	wantPort := itoaPort(port)
	for _, line := range lines[1:] {
		if line == "" || line[0] == '#' {
			continue
		}
		h, p, algo, hexKey, okLine := split4(line)
		if !okLine || algo != AlgoEd25519 {
			return pin, false, false
		}
		if h != host || p != wantPort {
			continue
		}
		pub, okHex := ParseHex32(hexKey)
		if !okHex {
			return pin, false, false
		}
		if found && pub != pin {
			return pin, false, false
		}
		pin = pub
		found = true
	}
	return pin, found, true
}

func split4(line string) (a, b, c, d string, ok bool) {
	i := indexByteStr(line, '\t')
	if i < 0 {
		return "", "", "", "", false
	}
	j := indexByteStr(line[i+1:], '\t')
	if j < 0 {
		return "", "", "", "", false
	}
	j += i + 1
	k := indexByteStr(line[j+1:], '\t')
	if k < 0 {
		return "", "", "", "", false
	}
	k += j + 1
	return line[:i], line[i+1 : j], line[j+1 : k], line[k+1:], true
}

func itoaPort(p uint16) string {
	if p == 0 {
		return "0"
	}
	var buf [5]byte
	n := 5
	v := int(p)
	for v > 0 {
		n--
		buf[n] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[n:])
}

func splitLines(s string) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			line := s[start:i]
			if len(line) > 0 && line[len(line)-1] == '\r' {
				line = line[:len(line)-1]
			}
			out = append(out, line)
			start = i + 1
		}
	}
	if start < len(s) {
		line := s[start:]
		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}
		out = append(out, line)
	}
	return out
}

func indexByteStr(s string, c byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			return i
		}
	}
	return -1
}
