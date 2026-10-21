// SSH-2 server state machine (M70g G1, #1491): the ADR 0025 D2 profile with
// the roles reversed. Feed is a pure byte-stream step — production wraps it
// over vi.Conn; host tests drive a scripted client against it with no VM.
// The channel layer also serves one interactive session (#2960): pty-req +
// shell enter session mode, inbound CHANNEL_DATA is queued for the app
// behind Drain, and Write/CloseSession give the app a windowed outbound.

package sshlib

import "virelai/ed25519"

const (
	MsgDisconnect      byte = 1
	MsgIgnore          byte = 2
	MsgDebug           byte = 4
	MsgServiceRequest  byte = 5
	MsgServiceAccept   byte = 6
	MsgKexInit         byte = 20
	MsgNewKeys         byte = 21
	MsgKexECDHInit     byte = 30
	MsgKexECDHReply    byte = 31
	MsgUserauthReq     byte = 50
	MsgUserauthFail    byte = 51
	MsgUserauthOK      byte = 52
	MsgUserauthBanner  byte = 53
	MsgGlobalRequest   byte = 80
	MsgRequestSuccess  byte = 81
	MsgRequestFailure  byte = 82
	MsgChannelOpen     byte = 90
	MsgChannelConfirm  byte = 91
	MsgChannelOpenFail byte = 92
	MsgChannelWindow   byte = 93
	MsgChannelData     byte = 94
	MsgExtendedData    byte = 95
	MsgChannelEOF      byte = 96
	MsgChannelClose    byte = 97
	MsgChannelReq      byte = 98
	MsgChannelOK       byte = 99
	MsgChannelFail     byte = 100

	AlgoEd25519     = "ssh-ed25519"
	KexCurve        = "curve25519-sha256"
	KexCurveAlias   = "curve25519-sha256@libssh.org"
	CipherOpenSSH   = "chacha20-poly1305@openssh.com"
	CompNone        = "none"
	SvcUserauth     = "ssh-userauth"
	SvcConnection   = "ssh-connection"
	MethodNone      = "none"
	MethodPubKey    = "publickey"
	ChanSession     = "session"
	ReqExec         = "exec"
	ReqPty          = "pty-req"
	ReqShell        = "shell"
	ReqWindowChange = "window-change"
	ReqExitStatus   = "exit-status"

	IdentLine = "SSH-2.0-VirelaiOS_1.0"

	LocalWindow    uint32 = 1 << 17
	LocalMaxPacket uint32 = 32768
	ServerChanID   uint32 = 42
)

type phase int

const (
	phaseVersion phase = iota
	phaseKex
	phaseEncrypted
	phaseFailed
	phaseClosed
)

// AuthKey is one SSH/AUTHORIZED_KEYS row: a user name and a 32-byte
// ssh-ed25519 public key.
type AuthKey struct {
	User string
	Pub  [32]byte
}

// ExecFunc runs one remote command and returns its captured stdout and
// exit status. Production hands the line to GOSH.ELF -c; tests inject a
// fixed marker.
type ExecFunc func(cmd string) (stdout []byte, status uint32, err error)

// Pty is the terminal a pty-req granted (RFC 4254 §6.2): TERM, character
// and pixel geometry, and the raw RFC 4250 §4.5 encoded modes stream.
type Pty struct {
	Term       string
	Cols, Rows uint32
	PxW, PxH   uint32
	Modes      []byte
}

// InKind names the Drain event kinds an interactive session queues.
type InKind byte

const (
	InData   InKind = iota + 1 // CHANNEL_DATA bytes (InEvent.Data)
	InResize                   // window-change (InEvent.Cols/Rows/PxW/PxH)
	InEOF                      // client CHANNEL_EOF — half-close of stdin
)

// InEvent is one client→app event on the session channel, in wire order.
type InEvent struct {
	Kind       InKind
	Data       []byte
	Cols, Rows uint32
	PxW, PxH   uint32
}

// EntropyFunc fills b with random bytes.
type EntropyFunc func(b []byte) error

type ServerConfig struct {
	HostSeed  [32]byte
	Keys      []AuthKey
	Run       ExecFunc
	Log       func(string)
	Entropy   EntropyFunc
	Ident     string
	Cookie    []byte // optional deterministic KEXINIT cookie
	Ephemeral []byte // optional deterministic X25519 secret
}

type Server struct {
	cfg         ServerConfig
	HostPub     [32]byte
	phase       phase
	input       []byte
	out         []byte
	banners     int
	clientVer   string
	iC, iS      []byte
	qC, qS      []byte
	sessionID   []byte
	sendCipher  *Cipher
	recvCipher  *Cipher
	sendSeq     uint64
	recvSeq     uint64
	clientChan  uint32
	remoteWin   uint32
	remoteMax   uint32
	localWin    uint32
	winConsumed uint32
	execRan     bool
	chanOpen    bool
	pty         Pty
	ptyGranted  bool
	session     bool
	inQ         []InEvent
	outQ        []byte
	clientEOF   bool
	closeSent   bool
	closed      bool
	failed      bool
}

func NewServer(cfg ServerConfig) *Server {
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
	return &Server{
		cfg:     cfg,
		HostPub: ed25519.EdDerivePublic(cfg.HostSeed),
		phase:   phaseVersion,
	}
}

func (s *Server) Closed() bool { return s.phase == phaseClosed || s.phase == phaseFailed }

func (s *Server) Failed() bool { return s.phase == phaseFailed }

func (s *Server) Feed(data []byte) []byte {
	if s.Closed() {
		return nil
	}
	s.input = append(s.input, data...)
	s.process()
	out := s.out
	s.out = nil
	return out
}

func (s *Server) process() {
	for !s.Closed() {
		switch s.phase {
		case phaseVersion:
			if !s.readVersion() {
				return
			}
		case phaseKex:
			payload, ok := s.nextPlain()
			if !ok {
				return
			}
			s.handleKex(payload)
		case phaseEncrypted:
			payload, ok := s.nextEncrypted()
			if !ok {
				return
			}
			s.handleEncrypted(payload)
		default:
			return
		}
	}
}

func (s *Server) readVersion() bool {
	for {
		nl := -1
		for i, b := range s.input {
			if b == 0x0a {
				nl = i
				break
			}
		}
		if nl < 0 {
			if len(s.input) > 255 {
				s.fail("version too long")
			}
			return false
		}
		raw := s.input[:nl]
		s.input = s.input[nl+1:]
		if len(raw) > 0 && raw[len(raw)-1] == 0x0d {
			raw = raw[:len(raw)-1]
		}
		if len(raw) < 4 || string(raw[:4]) != "SSH-" {
			s.banners++
			if s.banners > 64 {
				s.fail("too many banner lines")
				return false
			}
			continue
		}
		text := string(raw)
		if !(len(text) >= 8 && (text[:8] == "SSH-2.0-" || (len(text) >= 9 && text[:9] == "SSH-1.99-"))) {
			s.fail("bad identification line")
			return false
		}
		s.clientVer = text
		s.cfg.Log("version received: " + text)
		s.out = append(s.out, []byte(s.cfg.Ident+"\r\n")...)
		s.sendKexInit()
		s.phase = phaseKex
		return true
	}
}

func (s *Server) sendKexInit() {
	var w Writer
	w.Byte(MsgKexInit)
	cookie := s.cfg.Cookie
	if len(cookie) != 16 {
		var c [16]byte
		_ = s.cfg.Entropy(c[:])
		cookie = c[:]
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
	s.iS = append([]byte(nil), w.B...)
	s.sendPacket(s.iS)
	s.cfg.Log("kexinit sent")
}

func (s *Server) nextPlain() ([]byte, bool) {
	if len(s.input) < 4 {
		return nil, false
	}
	packetLength := int(s.input[0])<<24 | int(s.input[1])<<16 | int(s.input[2])<<8 | int(s.input[3])
	if packetLength > PktMaxTotal-4 || packetLength < 5 {
		s.fail("bad plaintext length")
		return nil, false
	}
	total := 4 + packetLength
	if len(s.input) < total {
		return nil, false
	}
	frame := s.input[:total]
	s.input = s.input[total:]
	payload, ok := DecodePacket(frame, AlignPlain)
	if !ok {
		s.fail("malformed plaintext frame")
		return nil, false
	}
	s.recvSeq++
	return payload, true
}

func (s *Server) handleKex(payload []byte) {
	if len(payload) == 0 {
		s.fail("empty kex packet")
		return
	}
	switch payload[0] {
	case MsgKexInit:
		if !s.parseClientKexInit(payload) {
			return
		}
		s.cfg.Log("kexinit received (suite negotiated)")
	case MsgKexECDHInit:
		r := Reader{B: payload}
		if b, ok := r.Byte(); !ok || b != MsgKexECDHInit {
			s.fail("malformed KEX_ECDH_INIT")
			return
		}
		q, ok := r.Str()
		if !ok || len(q) != 32 || r.Remaining() != 0 {
			s.fail("malformed KEX_ECDH_INIT")
			return
		}
		s.qC = append([]byte(nil), q...)
		s.performKex()
	case MsgNewKeys:
		if len(payload) != 1 {
			s.fail("malformed NEWKEYS")
			return
		}
		s.cfg.Log("newkeys received; cipher installed")
		s.phase = phaseEncrypted
	case MsgDisconnect:
		s.cfg.Log("client disconnect during kex")
		s.phase = phaseClosed
	case MsgIgnore, MsgDebug:
	default:
		s.fail("unexpected kex message")
	}
}

func (s *Server) parseClientKexInit(payload []byte) bool {
	r := Reader{B: payload}
	if b, ok := r.Byte(); !ok || b != MsgKexInit {
		return false
	}
	if r.Remaining() < 16 {
		s.fail("short KEXINIT")
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
		s.fail("malformed KEXINIT")
		return false
	}
	kexOK := ContainsName(kex, KexCurve) || ContainsName(kex, KexCurveAlias)
	hostOK := ContainsName(host, AlgoEd25519)
	cipherOK := ContainsName(encC, CipherOpenSSH) && ContainsName(encS, CipherOpenSSH)
	compOK := ContainsName(compC, CompNone) && ContainsName(compS, CompNone)
	if !kexOK || !hostOK || !cipherOK || !compOK {
		s.fail("no common algorithm")
		return false
	}
	s.iC = append([]byte(nil), payload...)
	return true
}

func (s *Server) performKex() {
	var eph [32]byte
	if len(s.cfg.Ephemeral) == 32 {
		copy(eph[:], s.cfg.Ephemeral)
	} else if err := s.cfg.Entropy(eph[:]); err != nil {
		s.fail("entropy")
		return
	}
	qS, ok := ed25519.X25519Base(eph)
	if !ok {
		s.fail("bad ephemeral secret")
		return
	}
	s.qS = qS[:]
	var qC [32]byte
	copy(qC[:], s.qC)
	kRaw, ok := ed25519.X25519(eph, qC)
	Wipe(eph[:])
	if !ok {
		s.fail("all-zero shared secret")
		return
	}
	kMpint := Mpint(kRaw[:])
	Wipe(kRaw[:])

	var ks Writer
	ks.StrS(AlgoEd25519)
	ks.Str(s.HostPub[:])
	kS := ks.B

	h := ExchangeHash(
		[]byte(s.clientVer), []byte(s.cfg.Ident),
		s.iC, s.iS, kS, s.qC, s.qS, kMpint,
	)
	sig := ed25519.EdSign(h[:], s.cfg.HostSeed)
	var sigBlob Writer
	sigBlob.StrS(AlgoEd25519)
	sigBlob.Str(sig[:])

	var reply Writer
	reply.Byte(MsgKexECDHReply)
	reply.Str(kS)
	reply.Str(s.qS)
	reply.Str(sigBlob.B)
	s.sendPacket(reply.B)
	s.sendPacket([]byte{MsgNewKeys})

	s.sessionID = h[:]
	keyC2S := DeriveKey(CipherKeyLen, kMpint, h[:], 'C', h[:])
	keyS2C := DeriveKey(CipherKeyLen, kMpint, h[:], 'D', h[:])
	var recv, send Cipher
	copy(recv.Key[:], keyC2S)
	copy(send.Key[:], keyS2C)
	s.recvCipher = &recv
	s.sendCipher = &send
	Wipe(keyC2S)
	Wipe(keyS2C)
	s.cfg.Log("ecdh reply sent; newkeys sent")
}

func (s *Server) nextEncrypted() ([]byte, bool) {
	if s.recvCipher == nil || len(s.input) < 4 {
		return nil, false
	}
	length := int(s.recvCipher.DecryptLength(s.input[:4], s.recvSeq))
	if length < 5 || length > PktMaxTotal-4 {
		s.fail("bad encrypted length")
		return nil, false
	}
	ctLen := 4 + length
	wire := ctLen + PolyTagLen
	if len(s.input) < wire {
		return nil, false
	}
	ct := s.input[:ctLen]
	tag := s.input[ctLen:wire]
	plain := s.recvCipher.Open(ct, tag, s.recvSeq)
	if plain == nil {
		s.cfg.Log("mac-failure — disconnecting")
		s.phase = phaseFailed
		return nil, false
	}
	s.input = s.input[wire:]
	s.recvSeq++
	payload, ok := DecodePacket(plain, AlignAEAD)
	if !ok {
		s.fail("malformed encrypted frame")
		return nil, false
	}
	return payload, true
}

func (s *Server) handleEncrypted(payload []byte) {
	if len(payload) == 0 {
		return
	}
	switch payload[0] {
	case MsgIgnore, MsgDebug:
	case MsgDisconnect:
		s.cfg.Log("client disconnect")
		s.phase = phaseClosed
	case MsgServiceRequest:
		s.handleService(payload)
	case MsgUserauthReq:
		s.handleUserauth(payload)
	case MsgChannelOpen:
		s.handleChannelOpen(payload)
	case MsgChannelReq:
		s.handleChannelReq(payload)
	case MsgChannelData:
		s.handleChannelData(payload)
	case MsgChannelWindow:
		r := Reader{B: payload}
		_, _ = r.Byte()
		_, _ = r.U32()
		if add, ok := r.U32(); ok {
			if s.remoteWin+add < s.remoteWin {
				s.remoteWin = ^uint32(0)
			} else {
				s.remoteWin += add
			}
			s.flushChannel()
		}
	case MsgChannelEOF:
		s.handleChannelEOF(payload)
	case MsgChannelClose:
		s.cfg.Log("channel close from client")
		if s.chanOpen && !s.closeSent {
			s.sendPacket(s.channelHeader(MsgChannelClose))
			s.closeSent = true
		}
		s.phase = phaseClosed
	default:
		s.cfg.Log("unhandled message")
	}
}

func (s *Server) handleService(payload []byte) {
	r := Reader{B: payload}
	_, _ = r.Byte()
	name, ok := r.StrUTF8()
	if !ok || r.Remaining() != 0 {
		s.fail("malformed service request")
		return
	}
	if name != SvcUserauth {
		s.fail("unsupported service")
		return
	}
	var w Writer
	w.Byte(MsgServiceAccept)
	w.StrS(SvcUserauth)
	s.sendPacket(w.B)
	s.cfg.Log("service-accept ssh-userauth")
}

func (s *Server) handleUserauth(payload []byte) {
	r := Reader{B: payload}
	_, _ = r.Byte()
	user, ok1 := r.StrUTF8()
	service, ok2 := r.StrUTF8()
	method, ok3 := r.StrUTF8()
	if !ok1 || !ok2 || !ok3 {
		s.fail("malformed userauth request")
		return
	}
	if method == MethodNone {
		s.cfg.Log("userauth none requested; offering publickey")
		s.sendUserauthFail()
		return
	}
	if method != MethodPubKey || service != SvcConnection {
		s.fail("unsupported userauth method")
		return
	}
	hasSig, ok := r.BoolVal()
	algo, okA := r.StrUTF8()
	keyBlob, okB := r.Str()
	if !ok || !okA || !okB {
		s.fail("malformed publickey request")
		return
	}
	sigOffset := r.Pos
	pub, okPub := parseEd25519Blob(keyBlob)
	if !okPub || algo != AlgoEd25519 || !s.keyAllowed(user, pub) {
		s.cfg.Log("publickey rejected: key does not match AUTHORIZED_KEYS")
		s.sendUserauthFail()
		return
	}
	if !hasSig {
		s.cfg.Log("publickey rejected: no signature")
		s.sendUserauthFail()
		return
	}
	sigBlob, ok := r.Str()
	if !ok || r.Remaining() != 0 {
		s.fail("malformed publickey signature")
		return
	}
	sr := Reader{B: sigBlob}
	sigAlg, okS := sr.StrUTF8()
	sigBytes, okT := sr.Str()
	if !okS || !okT || sr.Remaining() != 0 || sigAlg != AlgoEd25519 || len(sigBytes) != 64 {
		s.cfg.Log("publickey rejected: malformed signature blob")
		s.sendUserauthFail()
		return
	}
	var signed Writer
	signed.Str(s.sessionID)
	signed.Raw(payload[:sigOffset])
	var sig [64]byte
	copy(sig[:], sigBytes)
	if !ed25519.EdVerify(sig, signed.B, pub) {
		s.cfg.Log("publickey rejected: signature does not verify")
		s.sendUserauthFail()
		return
	}
	s.sendPacket([]byte{MsgUserauthOK})
	s.cfg.Log("publickey accepted user=" + user + " key=ssh-ed25519")
}

func parseEd25519Blob(blob []byte) ([32]byte, bool) {
	var zero [32]byte
	r := Reader{B: blob}
	name, ok := r.StrUTF8()
	key, ok2 := r.Str()
	if !ok || !ok2 || r.Remaining() != 0 || name != AlgoEd25519 || len(key) != 32 {
		return zero, false
	}
	var pub [32]byte
	copy(pub[:], key)
	return pub, true
}

func (s *Server) keyAllowed(user string, pub [32]byte) bool {
	for _, k := range s.cfg.Keys {
		if k.Pub != pub {
			continue
		}
		if k.User == "" || k.User == user {
			return true
		}
	}
	return false
}

func (s *Server) sendUserauthFail() {
	var w Writer
	w.Byte(MsgUserauthFail)
	w.NameList([]string{MethodPubKey})
	w.BoolVal(false)
	s.sendPacket(w.B)
}

func (s *Server) handleChannelOpen(payload []byte) {
	r := Reader{B: payload}
	_, _ = r.Byte()
	typ, ok1 := r.StrUTF8()
	sender, ok2 := r.U32()
	window, ok3 := r.U32()
	maxPkt, ok4 := r.U32()
	if !ok1 || !ok2 || !ok3 || !ok4 || r.Remaining() != 0 {
		s.fail("malformed channel open")
		return
	}
	if typ != ChanSession || maxPkt == 0 {
		s.fail("unsupported channel type")
		return
	}
	s.clientChan = sender
	s.remoteWin = window
	s.remoteMax = maxPkt
	s.localWin = LocalWindow
	s.winConsumed = 0
	s.chanOpen = true
	var w Writer
	w.Byte(MsgChannelConfirm)
	w.U32(sender)
	w.U32(ServerChanID)
	w.U32(LocalWindow)
	w.U32(LocalMaxPacket)
	s.sendPacket(w.B)
	s.cfg.Log("channel open session confirmed")
}

func (s *Server) handleChannelReq(payload []byte) {
	r := Reader{B: payload}
	_, _ = r.Byte()
	recip, ok1 := r.U32()
	req, ok2 := r.StrUTF8()
	want, ok3 := r.BoolVal()
	if !ok1 || !ok2 || !ok3 || recip != ServerChanID {
		s.fail("malformed channel request")
		return
	}
	switch req {
	case ReqExec:
		s.handleExecReq(&r, want)
	case ReqPty:
		s.handlePtyReq(&r, want)
	case ReqShell:
		s.handleShellReq(&r, want)
	case ReqWindowChange:
		s.handleWindowChange(&r, want)
	default:
		s.refuseReq(want)
		s.cfg.Log("channel request refused")
	}
}

func (s *Server) handleExecReq(r *Reader, want bool) {
	cmd, ok := r.StrUTF8()
	if !ok || r.Remaining() != 0 {
		s.fail("malformed exec request")
		return
	}
	if s.session {
		s.refuseReq(want)
		s.cfg.Log("exec refused: session owns the channel")
		return
	}
	if s.execRan {
		s.fail("second exec request")
		return
	}
	s.execRan = true
	s.acceptReq(want)
	s.cfg.Log("exec " + cmd)
	stdout := []byte(nil)
	status := uint32(1)
	if s.cfg.Run != nil {
		out, st, err := s.cfg.Run(cmd)
		if err == nil {
			stdout = out
			status = st
		}
	}
	s.sendChannelData(stdout)
	s.sendExitStatus(status)
	s.sendPacket(s.channelHeader(MsgChannelEOF))
	s.sendPacket(s.channelHeader(MsgChannelClose))
	s.closeSent = true
	s.cfg.Log("exec done")
	s.phase = phaseClosed
}

// handlePtyReq parses RFC 4254 §6.2: TERM, cols, rows, pixel geometry and
// the raw terminal-modes stream. Granted once, before shell.
func (s *Server) handlePtyReq(r *Reader, want bool) {
	term, ok := r.StrUTF8()
	cols, ok1 := r.U32()
	rows, ok2 := r.U32()
	pxw, ok3 := r.U32()
	pxh, ok4 := r.U32()
	modes, ok5 := r.Str()
	if !ok || !ok1 || !ok2 || !ok3 || !ok4 || !ok5 || r.Remaining() != 0 {
		s.fail("malformed pty-req")
		return
	}
	if s.ptyGranted || s.session || s.execRan {
		s.refuseReq(want)
		s.cfg.Log("pty-req refused: already granted or session started")
		return
	}
	s.pty = Pty{
		Term: term, Cols: cols, Rows: rows, PxW: pxw, PxH: pxh,
		Modes: append([]byte(nil), modes...),
	}
	s.ptyGranted = true
	s.acceptReq(want)
	s.cfg.Log("pty-req granted")
}

// handleShellReq grants the interactive session only on top of a pty —
// there is no shell channel without one (§6.5 carries no extra fields).
func (s *Server) handleShellReq(r *Reader, want bool) {
	if r.Remaining() != 0 {
		s.fail("malformed shell request")
		return
	}
	if s.session || !s.ptyGranted {
		s.refuseReq(want)
		s.cfg.Log("shell refused: no pty or session already live")
		return
	}
	s.session = true
	s.acceptReq(want)
	s.cfg.Log("shell granted; session live")
}

// handleWindowChange parses RFC 4254 §6.7 into an InResize event. It is a
// notification — the wire answer is silence even when want_reply is set.
func (s *Server) handleWindowChange(r *Reader, want bool) {
	cols, ok1 := r.U32()
	rows, ok2 := r.U32()
	pxw, ok3 := r.U32()
	pxh, ok4 := r.U32()
	if !ok1 || !ok2 || !ok3 || !ok4 || r.Remaining() != 0 {
		s.fail("malformed window-change")
		return
	}
	if !s.ptyGranted {
		s.refuseReq(want)
		s.cfg.Log("window-change refused: no pty")
		return
	}
	s.inQ = append(s.inQ, InEvent{Kind: InResize, Cols: cols, Rows: rows, PxW: pxw, PxH: pxh})
}

// handleChannelData queues client→app bytes (§5.2): the advertised local
// window is a hard bound on the input queue — a peer that overruns it
// fails the transport. Window credit is returned by Drain: the app says
// it consumed the bytes, so the queue stays bounded by LocalWindow.
func (s *Server) handleChannelData(payload []byte) {
	r := Reader{B: payload}
	_, _ = r.Byte()
	recip, ok1 := r.U32()
	data, ok2 := r.Str()
	if !ok1 || !ok2 || r.Remaining() != 0 || recip != ServerChanID || !s.chanOpen {
		s.fail("malformed channel data")
		return
	}
	if uint32(len(data)) > s.localWin {
		s.fail("channel data past advertised window")
		return
	}
	s.localWin -= uint32(len(data))
	s.winConsumed += uint32(len(data))
	if len(data) > 0 {
		s.inQ = append(s.inQ, InEvent{Kind: InData, Data: append([]byte(nil), data...)})
	}
}

// handleChannelEOF surfaces the client's half-close to the app. Before any
// channel exists the legacy close-the-transport behavior stands.
func (s *Server) handleChannelEOF(payload []byte) {
	r := Reader{B: payload}
	_, _ = r.Byte()
	recip, _ := r.U32()
	s.cfg.Log("channel eof from client")
	if !s.chanOpen || recip != ServerChanID {
		s.phase = phaseClosed
		return
	}
	if !s.clientEOF {
		s.clientEOF = true
		s.inQ = append(s.inQ, InEvent{Kind: InEOF})
	}
}

func (s *Server) acceptReq(want bool) {
	if !want {
		return
	}
	var w Writer
	w.Byte(MsgChannelOK)
	w.U32(s.clientChan)
	s.sendPacket(w.B)
}

func (s *Server) refuseReq(want bool) {
	if !want {
		return
	}
	var w Writer
	w.Byte(MsgChannelFail)
	w.U32(s.clientChan)
	s.sendPacket(w.B)
}

func (s *Server) channelHeader(kind byte) []byte {
	var w Writer
	w.Byte(kind)
	w.U32(s.clientChan)
	return w.B
}

// Session reports whether a shell request entered session mode.
func (s *Server) Session() bool { return s.session }

// PtyGranted returns the terminal the client's pty-req negotiated, if one
// ran — the app's geometry and TERM for the session (#2960).
func (s *Server) PtyGranted() (Pty, bool) { return s.pty, s.ptyGranted }

// Drain pops every queued client→app event — CHANNEL_DATA bytes,
// window-change resizes, the client's EOF — in wire order. The next Drain
// returns only what arrived since. Draining is also what returns window
// credit: once half the advertised window has been consumed a
// WINDOW_ADJUST is emitted into the pending output (Take / the next Feed
// return carries it to the wire).
func (s *Server) Drain() []InEvent {
	ev := s.inQ
	s.inQ = nil
	if s.winConsumed >= LocalWindow/2 {
		var w Writer
		w.Byte(MsgChannelWindow)
		w.U32(s.clientChan)
		w.U32(s.winConsumed)
		s.sendPacket(w.B)
		s.localWin += s.winConsumed
		s.winConsumed = 0
	}
	return ev
}

// Write queues p as CHANNEL_DATA for the session and seals what the remote
// window and the peer's max packet allow right now, returning the fresh
// wire bytes (plus anything else already pending). The rest stays queued —
// the Feed that takes the WINDOW_ADJUST covering it emits it; nothing is
// dropped while the channel lives.
func (s *Server) Write(p []byte) []byte {
	if s.Closed() || !s.chanOpen {
		return nil
	}
	s.outQ = append(s.outQ, p...)
	s.flushChannel()
	return s.Take()
}

// CloseSession emits exit-status, EOF and CLOSE exactly once and closes
// the transport — the connection serves one channel. Queued output that
// the remote window has not yet admitted is flushed as far as it goes;
// a tail the window still refuses is logged, never silently counted.
func (s *Server) CloseSession(status uint32) []byte {
	if s.closeSent || !s.chanOpen {
		return nil
	}
	s.closeSent = true
	s.flushChannel()
	if len(s.outQ) > 0 {
		s.cfg.Log("close: window-blocked tail dropped")
		s.outQ = nil
	}
	s.sendExitStatus(status)
	s.sendPacket(s.channelHeader(MsgChannelEOF))
	s.sendPacket(s.channelHeader(MsgChannelClose))
	s.cfg.Log("session closed")
	s.phase = phaseClosed
	return s.Take()
}

// Take returns and clears sealed wire bytes the app produced outside Feed
// — a WINDOW_ADJUST earned by Drain, for example.
func (s *Server) Take() []byte {
	out := s.out
	s.out = nil
	return out
}

// sendChannelData is the exec path's pre-Write outbound: it queues through
// the same window accounting so CHANNEL_DATA never exceeds remoteWin.
func (s *Server) sendChannelData(data []byte) {
	s.outQ = append(s.outQ, data...)
	s.flushChannel()
	s.outQ = nil // exec closes anyway; a blocked tail is the pre-#2960 drop
}

// flushChannel seals queued CHANNEL_DATA up to what the remote window and
// the peer's max packet allow; the remainder waits for WINDOW_ADJUST.
func (s *Server) flushChannel() {
	for len(s.outQ) > 0 {
		room := int(s.remoteWin)
		if int(s.remoteMax) < room {
			room = int(s.remoteMax)
		}
		if room > 32768 {
			room = 32768
		}
		if room > len(s.outQ) {
			room = len(s.outQ)
		}
		if room <= 0 {
			return
		}
		var w Writer
		w.Byte(MsgChannelData)
		w.U32(s.clientChan)
		w.Str(s.outQ[:room])
		s.sendPacket(w.B)
		s.remoteWin -= uint32(room)
		s.outQ = s.outQ[room:]
	}
}

func (s *Server) sendExitStatus(status uint32) {
	var w Writer
	w.Byte(MsgChannelReq)
	w.U32(s.clientChan)
	w.StrS(ReqExitStatus)
	w.BoolVal(false)
	w.U32(status)
	s.sendPacket(w.B)
}

func (s *Server) sendPacket(payload []byte) {
	align := AlignPlain
	if s.sendCipher != nil {
		align = AlignAEAD
	}
	pad := make([]byte, PaddingLen(len(payload), align))
	_ = s.cfg.Entropy(pad)
	frame, ok := EncodePacket(payload, pad, align)
	if !ok {
		s.fail("could not frame outbound packet")
		return
	}
	if s.sendCipher != nil {
		ct, tag := s.sendCipher.Seal(frame, s.sendSeq)
		s.out = append(s.out, ct...)
		s.out = append(s.out, tag...)
	} else {
		s.out = append(s.out, frame...)
	}
	s.sendSeq++
}

func (s *Server) fail(reason string) {
	s.cfg.Log("protocol failure: " + reason)
	s.phase = phaseFailed
}
