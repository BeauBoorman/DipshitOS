// SSH-2 server state machine (M70g G1, #1491): the ADR 0025 D2 profile with
// the roles reversed. Feed is a pure byte-stream step — production wraps it
// over vi.Conn; host tests drive a scripted client against it with no VM.

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

	AlgoEd25519   = "ssh-ed25519"
	KexCurve      = "curve25519-sha256"
	KexCurveAlias = "curve25519-sha256@libssh.org"
	CipherOpenSSH = "chacha20-poly1305@openssh.com"
	CompNone      = "none"
	SvcUserauth   = "ssh-userauth"
	SvcConnection = "ssh-connection"
	MethodNone    = "none"
	MethodPubKey  = "publickey"
	ChanSession   = "session"
	ReqExec       = "exec"
	ReqExitStatus = "exit-status"

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
	cfg        ServerConfig
	HostPub    [32]byte
	phase      phase
	input      []byte
	out        []byte
	banners    int
	clientVer  string
	iC, iS     []byte
	qC, qS     []byte
	sessionID  []byte
	sendCipher *Cipher
	recvCipher *Cipher
	sendSeq    uint64
	recvSeq    uint64
	clientChan uint32
	remoteWin  uint32
	remoteMax  uint32
	execRan    bool
	closed     bool
	failed     bool
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
	case MsgChannelWindow:
		r := Reader{B: payload}
		_, _ = r.Byte()
		_, _ = r.U32()
		if add, ok := r.U32(); ok {
			s.remoteWin += add
		}
	case MsgChannelEOF, MsgChannelClose:
		s.cfg.Log("channel eof/close from client")
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
	if req == ReqExec {
		cmd, ok := r.StrUTF8()
		if !ok || r.Remaining() != 0 {
			s.fail("malformed exec request")
			return
		}
		if s.execRan {
			s.fail("second exec request")
			return
		}
		s.execRan = true
		if want {
			var w Writer
			w.Byte(MsgChannelOK)
			w.U32(s.clientChan)
			s.sendPacket(w.B)
		}
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
		s.cfg.Log("exec done")
		s.phase = phaseClosed
		return
	}
	if want {
		var w Writer
		w.Byte(MsgChannelFail)
		w.U32(s.clientChan)
		s.sendPacket(w.B)
	}
	s.cfg.Log("channel request refused")
}

func (s *Server) channelHeader(kind byte) []byte {
	var w Writer
	w.Byte(kind)
	w.U32(s.clientChan)
	return w.B
}

func (s *Server) sendChannelData(data []byte) {
	off := 0
	for off < len(data) {
		room := int(s.remoteWin)
		if int(s.remoteMax) < room {
			room = int(s.remoteMax)
		}
		if room > 32768 {
			room = 32768
		}
		if room > len(data)-off {
			room = len(data) - off
		}
		if room <= 0 {
			break
		}
		var w Writer
		w.Byte(MsgChannelData)
		w.U32(s.clientChan)
		w.Str(data[off : off+room])
		s.sendPacket(w.B)
		s.remoteWin -= uint32(room)
		off += room
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
