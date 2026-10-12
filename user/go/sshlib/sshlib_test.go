package sshlib

import (
	"bytes"
	"testing"
)

// A fully scripted server peer for the client state machine: every byte the
// client sees is built by hand (the ADR 0025 D2 transcript is computed
// in-test from the pinned constants), so each injected message exercises one
// transition in isolation — no kernel, no network, no real Server.
type scriptedServer struct {
	t        *testing.T
	cl       *Client
	hostSeed [32]byte
	eph      [32]byte // server ephemeral secret (RFC 7748 bob)
	iS       []byte
	sendSeq  uint64 // client→server (recv by server); == client's sendSeq
	recvSeq  uint64 // server→client; == client's recvSeq
	send     Cipher // seals server→client (key 'D')
	recv     Cipher // opens client→server (key 'C')
}

func plainFrame(payload []byte) []byte {
	pad := bytes.Repeat([]byte{0x33}, PaddingLen(len(payload), AlignPlain))
	f, ok := EncodePacket(payload, pad, AlignPlain)
	if !ok {
		panic("plainFrame")
	}
	return f
}

// scriptedClientCfg builds the deterministic client config (pinned cookie +
// RFC 7748 alice ephemeral). cmd="" selects the shell path — which the
// client refuses with NoTty after CHANNEL_CONFIRM.
func scriptedClientCfg(t *testing.T, cmd string) ClientConfig {
	alice := mustHex32B(t, rfc7748AliceHex)
	hostPub := mustHex32B(t, rfc8032Test1PubHex)
	return ClientConfig{
		User:      "alice",
		Cmd:       cmd,
		HostPin:   hostPub,
		HasPin:    true,
		UserSeed:  mustHex32B(t, "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"),
		HasSeed:   true,
		Cookie:    bytes.Repeat([]byte{0x01}, 16),
		Ephemeral: alice[:],
	}
}

// driveKex runs the client through version + KEXINIT + ECDH + NEWKEYS
// against this scripted peer and installs both cipher directions.
func newScriptedServer(t *testing.T, cl *Client) *scriptedServer {
	t.Helper()
	ss := &scriptedServer{
		t:        t,
		cl:       cl,
		hostSeed: mustHex32B(t, rfc8032Test1SeedHex),
		eph:      mustHex32B(t, rfc7748BobHex),
		iS:       mustHexB(t, pinnedServerKexInitHex),
	}
	out := cl.Start()
	// KEXINIT.
	out = cl.Feed(append([]byte("SSH-2.0-VirelaiOS_1.0\r\n"), plainFrame(ss.iS)...))
	if cl.Failed() {
		t.Fatalf("kexinit: %s %s", cl.Stage, cl.ErrName)
	}
	if len(out) == 0 {
		t.Fatal("no ECDH_INIT after server KEXINIT")
	}
	// Build a valid ECDH_REPLY over the real transcript.
	qS, ok := X25519Base(ss.eph)
	if !ok {
		t.Fatal("qS")
	}
	var kSBlob Writer
	kSBlob.StrS(AlgoEd25519)
	hostPub := EdDerivePublic(ss.hostSeed)
	kSBlob.Str(hostPub[:])
	kRaw, ok := X25519(ss.eph, mustHex32B(t, rfc7748AlicePubHex))
	if !ok {
		t.Fatal("shared")
	}
	kMpint := Mpint(kRaw[:])
	h := ExchangeHash(
		[]byte(IdentLine), []byte(IdentLine),
		cl.iC, ss.iS, kSBlob.B, cl.qC, qS[:], kMpint,
	)
	sig := EdSign(h[:], ss.hostSeed)
	var sigBlob Writer
	sigBlob.StrS(AlgoEd25519)
	sigBlob.Str(sig[:])
	var reply Writer
	reply.Byte(MsgKexECDHReply)
	reply.Str(kSBlob.B)
	reply.Str(qS[:])
	reply.Str(sigBlob.B)
	out = cl.Feed(append(plainFrame(reply.B), plainFrame([]byte{MsgNewKeys})...))
	if cl.Failed() {
		t.Fatalf("ecdh reply: %s %s", cl.Stage, cl.ErrName)
	}
	// The ECDH reply flushes first (NEWKEYS must not share a TCP write with
	// ciphertext); the buffered NEWKEYS frame is consumed on the next Feed.
	_ = out
	cl.Feed(nil)
	if cl.Failed() {
		return ss // expected-failure paths (e.g. pin) stop here
	}
	if cl.phase != phaseEncrypted {
		t.Fatalf("phase = %d want encrypted", cl.phase)
	}
	c2s := DeriveKey(CipherKeyLen, kMpint, h[:], 'C', h[:])
	s2c := DeriveKey(CipherKeyLen, kMpint, h[:], 'D', h[:])
	copy(ss.recv.Key[:], c2s)
	copy(ss.send.Key[:], s2c)
	ss.sendSeq = cl.recvSeq // 3: kexinit, reply, newkeys
	ss.recvSeq = cl.sendSeq // 3: kexinit, ecdhinit, newkeys
	return ss
}

// inject seals one server→client packet and feeds it.
func (ss *scriptedServer) inject(payload []byte) []byte {
	pad := bytes.Repeat([]byte{0x77}, PaddingLen(len(payload), AlignAEAD))
	frame, ok := EncodePacket(payload, pad, AlignAEAD)
	if !ok {
		ss.t.Fatal("inject encode")
	}
	ct, tag := ss.send.Seal(frame, ss.sendSeq)
	ss.sendSeq++
	return ss.cl.Feed(append(ct, tag...))
}

// drain decrypts everything the client emitted since the last drain.
func (ss *scriptedServer) drain(out []byte) [][]byte {
	var payloads [][]byte
	for len(out) >= 4 {
		l := int(ss.recv.DecryptLength(out[:4], ss.recvSeq))
		wire := 4 + l + PolyTagLen
		if len(out) < wire {
			ss.t.Fatalf("partial client packet: %d < %d", len(out), wire)
		}
		plain := ss.recv.Open(out[:4+l], out[4+l:wire], ss.recvSeq)
		if plain == nil {
			ss.t.Fatal("client packet tag failed")
		}
		payload, ok := DecodePacket(plain, AlignAEAD)
		if !ok {
			ss.t.Fatal("client packet frame malformed")
		}
		payloads = append(payloads, payload)
		out = out[wire:]
		ss.recvSeq++
	}
	return payloads
}

// emit drains pending client output. After NEWKEYS the client needs one
// Feed to consume the buffered NEWKEYS frame, then another to emit the
// SERVICE_REQUEST it was holding (the runner's capture thread merges them
// otherwise — see handleKex).
func (ss *scriptedServer) emit() [][]byte {
	var pkts [][]byte
	for i := 0; i < 3; i++ {
		out := ss.cl.Feed(nil)
		pkts = append(pkts, ss.drain(out)...)
		if len(out) > 0 {
			break
		}
	}
	return pkts
}

// reach drives a fresh scripted session to the named state:
// "svc" authState=1, "auth2" publickey sent, "opening" chanState=1,
// "exec" chanState=3.
func reach(t *testing.T, at string, cmd string) *scriptedServer {
	t.Helper()
	cl := NewClient(scriptedClientCfg(t, cmd))
	ss := newScriptedServer(t, cl)
	ss.emit() // SERVICE_REQUEST → authState 1
	if cl.authState != 1 {
		t.Fatalf("authState = %d want 1", cl.authState)
	}
	if at == "svc" {
		return ss
	}
	var w Writer
	w.Byte(MsgServiceAccept)
	w.StrS(SvcUserauth)
	ss.drain(ss.inject(w.B)) // → USERAUTH none
	w = Writer{}
	w.Byte(MsgUserauthFail)
	w.NameList([]string{MethodPubKey})
	w.BoolVal(false)
	ss.drain(ss.inject(w.B)) // → publickey
	if cl.authState != 2 {
		t.Fatalf("authState = %d want 2", cl.authState)
	}
	if at == "auth2" {
		return ss
	}
	ss.drain(ss.inject([]byte{MsgUserauthOK})) // → CHANNEL_OPEN
	if cl.chanState != 1 {
		t.Fatalf("chanState = %d want 1", cl.chanState)
	}
	if at == "opening" {
		return ss
	}
	w = Writer{}
	w.Byte(MsgChannelConfirm)
	w.U32(clientLocalID)
	w.U32(ServerChanID)
	w.U32(LocalWindow)
	w.U32(LocalMaxPacket)
	ss.drain(ss.inject(w.B)) // → exec request
	if cl.chanState != 3 {
		t.Fatalf("chanState = %d want 3", cl.chanState)
	}
	return ss
}

func chanReq(recip uint32, req string, wantReply bool, rest func(w *Writer)) []byte {
	var w Writer
	w.Byte(MsgChannelReq)
	w.U32(recip)
	w.StrS(req)
	w.BoolVal(wantReply)
	if rest != nil {
		rest(&w)
	}
	return w.B
}

func chanData(recip uint32, body string) []byte {
	var w Writer
	w.Byte(MsgChannelData)
	w.U32(recip)
	w.StrS(body)
	return w.B
}

func chanConfirm(recip, sender uint32) []byte {
	var w Writer
	w.Byte(MsgChannelConfirm)
	w.U32(recip)
	w.U32(sender)
	w.U32(LocalWindow)
	w.U32(LocalMaxPacket)
	return w.B
}

func svcAccept(name string) []byte {
	var w Writer
	w.Byte(MsgServiceAccept)
	w.StrS(name)
	return w.B
}

func userauthFail(methods []string) []byte {
	var w Writer
	w.Byte(MsgUserauthFail)
	w.NameList(methods)
	w.BoolVal(false)
	return w.B
}

// --- version phase -------------------------------------------------------

func TestClientVersionTable(t *testing.T) {
	cases := []struct {
		name    string
		line    string
		wantErr string
	}{
		{"ssh-2.0", "SSH-2.0-OpenSSH_9.6\r\n", ""},
		{"ssh-1.99", "SSH-1.99-Cisco_1.25\r\n", ""},
		{"ssh-1.5", "SSH-1.5-Old\r\n", "BadVersion"},
		{"ssh-3.0", "SSH-3.0-Future\r\n", "BadVersion"},
		{"bare ssh-", "SSH-\r\n", "BadVersion"}, // "SSH-" alone is a bad ident, not a banner
		{"banner then 2.0", "motd of the day\r\nSSH-2.0-OpenSSH_9.6\r\n", ""},
	}
	for _, tc := range cases {
		cl := NewClient(scriptedClientCfg(t, "x"))
		cl.Start()
		cl.Feed([]byte(tc.line))
		if tc.wantErr == "" {
			if cl.Failed() {
				t.Fatalf("%s: failed %s", tc.name, cl.ErrName)
			}
			continue
		}
		if !cl.Failed() || cl.ErrName != tc.wantErr || cl.ExitCode != ExitKex {
			t.Fatalf("%s: err=%s code=%d", tc.name, cl.ErrName, cl.ExitCode)
		}
	}
	// A >255-byte line without LF is a refusal, not a banner.
	cl := NewClient(scriptedClientCfg(t, "x"))
	cl.Start()
	cl.Feed(bytes.Repeat([]byte{'A'}, 300))
	if cl.ErrName != "BadVersion" {
		t.Fatalf("long line: err=%s", cl.ErrName)
	}
	// 65 non-SSH banner lines are refused.
	cl = NewClient(scriptedClientCfg(t, "x"))
	cl.Start()
	for i := 0; i < 65; i++ {
		cl.Feed([]byte("not-ssh banner\r\n"))
	}
	if cl.ErrName != "TooManyBannerLines" {
		t.Fatalf("banners: err=%s", cl.ErrName)
	}
}

// --- packet codec negatives through the wire -----------------------------

// Every malformed plaintext packet is a distinct named refusal — never a
// panic and never a silent accept. A truncated stream is not an error: the
// client waits for the rest of the frame.
func TestClientPlainPacketNegatives(t *testing.T) {
	newCl := func() *Client {
		cl := NewClient(scriptedClientCfg(t, "x"))
		cl.Start()
		cl.Feed([]byte("SSH-2.0-VirelaiOS_1.0\r\n"))
		return cl
	}
	// packet_length over the cap: the length check fires on the header
	// alone.
	cl := newCl()
	cl.Feed([]byte{0xff, 0xff, 0xff, 0xff})
	if cl.ErrName != "BadPacket" || cl.Stage != "protocol" || cl.ExitCode != ExitTransport {
		t.Fatalf("oversized: %s %s %d", cl.Stage, cl.ErrName, cl.ExitCode)
	}
	// packet_length too small to hold a packet.
	cl = newCl()
	cl.Feed([]byte{0, 0, 0, 4, 0, 0, 0, 0})
	if cl.ErrName != "BadPacket" {
		t.Fatalf("tiny length: %s", cl.ErrName)
	}
	// A complete frame that fails DecodePacket (padding=2 < 4).
	cl = newCl()
	cl.Feed([]byte{0, 0, 0, 12, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0})
	if cl.ErrName != "BadPacket" {
		t.Fatalf("malformed frame: %s", cl.ErrName)
	}
	// A frame that decodes but carries an empty payload → BadKexInit.
	cl = newCl()
	empty := func() []byte {
		pad := bytes.Repeat([]byte{0x33}, 11)
		f, ok := EncodePacket(nil, pad, AlignPlain)
		if !ok {
			t.Fatal("encode empty")
		}
		return f
	}()
	cl.Feed(empty)
	if cl.ErrName != "BadKexInit" {
		t.Fatalf("empty payload: %s", cl.ErrName)
	}
	// A truncated frame is buffered, not an error: declared 100 bytes,
	// delivered 8 — no failure, no output, still waiting.
	cl = newCl()
	out := cl.Feed([]byte{0, 0, 0, 100, 1, 2, 3, 4})
	if cl.Failed() || len(out) != 0 {
		t.Fatalf("truncated: failed=%v out=%d", cl.Failed(), len(out))
	}
}

// --- kex-phase state machine ----------------------------------------------

func TestClientKexPhaseIllegalMessages(t *testing.T) {
	setup := func() *Client {
		cl := NewClient(scriptedClientCfg(t, "x"))
		cl.Start()
		cl.Feed([]byte("SSH-2.0-VirelaiOS_1.0\r\n"))
		return cl
	}
	cases := []struct {
		name    string
		payload []byte
		wantErr string
	}{
		{"newkeys before kex", []byte{MsgNewKeys}, "UnexpectedMessage"},
		{"newkeys trailing", []byte{MsgNewKeys, 0x00}, "BadKexReply"},
		{"unknown msg 99", []byte{99}, "UnexpectedMessage"},
		{"channel data in kex", chanData(0, "x"), "UnexpectedMessage"},
		{"service req in kex", func() []byte {
			var w Writer
			w.Byte(MsgServiceRequest)
			w.StrS(SvcUserauth)
			return w.B
		}(), "UnexpectedMessage"},
		{"disconnect", []byte{MsgDisconnect}, "PeerDisconnect"},
	}
	for _, tc := range cases {
		cl := setup()
		cl.Feed(plainFrame(tc.payload))
		if !cl.Failed() || cl.ErrName != tc.wantErr {
			t.Fatalf("%s: err=%s (failed=%v)", tc.name, cl.ErrName, cl.Failed())
		}
	}
	// IGNORE and DEBUG are legal during KEX: absorbed, not a failure.
	cl := setup()
	cl.Feed(plainFrame([]byte{MsgIgnore, 0, 0, 0}))
	cl.Feed(plainFrame([]byte{MsgDebug, 0, 0, 0, 0}))
	if cl.Failed() {
		t.Fatalf("ignore/debug: %s", cl.ErrName)
	}
}

func TestClientKexInitNegatives(t *testing.T) {
	setup := func() *Client {
		cl := NewClient(scriptedClientCfg(t, "x"))
		cl.Start()
		cl.Feed([]byte("SSH-2.0-VirelaiOS_1.0\r\n"))
		return cl
	}
	kexinit := func(edit func(w *Writer, lists *[][]string)) []byte {
		lists := [][]string{
			{KexCurve, KexCurveAlias}, {AlgoEd25519},
			{CipherOpenSSH}, {CipherOpenSSH}, nil, nil,
			{CompNone}, {CompNone}, nil, nil,
		}
		var w Writer
		w.Byte(MsgKexInit)
		w.Raw(bytes.Repeat([]byte{0xf0}, 16))
		if edit != nil {
			edit(&w, &lists)
			return w.B
		}
		for _, l := range lists {
			w.NameList(l)
		}
		w.BoolVal(false)
		w.U32(0)
		return w.B
	}
	bad := []struct {
		name    string
		payload []byte
		wantErr string
	}{
		{"truncated", mustHexB(t, pinnedServerKexInitHex)[:40], "BadKexInit"},
		{"no kex match", kexinit(func(w *Writer, lists *[][]string) {
			(*lists)[0] = []string{"diffie-hellman-group14-sha256"}
			for _, l := range *lists {
				w.NameList(l)
			}
			w.BoolVal(false)
			w.U32(0)
		}), "NoCommonKex"},
		{"no hostkey match", kexinit(func(w *Writer, lists *[][]string) {
			(*lists)[1] = []string{"ssh-rsa"}
			for _, l := range *lists {
				w.NameList(l)
			}
			w.BoolVal(false)
			w.U32(0)
		}), "NoCommonKex"},
		{"no cipher match", kexinit(func(w *Writer, lists *[][]string) {
			(*lists)[2] = []string{"aes256-gcm@openssh.com"}
			for _, l := range *lists {
				w.NameList(l)
			}
			w.BoolVal(false)
			w.U32(0)
		}), "NoCommonKex"},
		{"no comp match", kexinit(func(w *Writer, lists *[][]string) {
			(*lists)[6] = []string{"zlib"}
			for _, l := range *lists {
				w.NameList(l)
			}
			w.BoolVal(false)
			w.U32(0)
		}), "NoCommonKex"},
		{"reserved nonzero", kexinit(func(w *Writer, lists *[][]string) {
			for _, l := range *lists {
				w.NameList(l)
			}
			w.BoolVal(false)
			w.U32(1)
		}), "BadKexInit"},
		{"trailing garbage", append(mustHexB(t, pinnedServerKexInitHex), 0x00), "BadKexInit"},
		{"short cookie", func() []byte {
			var w Writer
			w.Byte(MsgKexInit)
			w.Raw([]byte{1, 2, 3})
			return w.B
		}(), "BadKexInit"},
	}
	for _, tc := range bad {
		cl := setup()
		cl.Feed(plainFrame(tc.payload))
		if !cl.Failed() || cl.ErrName != tc.wantErr {
			t.Fatalf("%s: err=%s", tc.name, cl.ErrName)
		}
	}
	// An ECDH_REPLY before any KEXINIT: parses, but the transcript hash is
	// wrong so the signature can never verify → BadSignature (observed).
	cl := setup()
	var kSBlob Writer
	kSBlob.StrS(AlgoEd25519)
	hostPub := EdDerivePublic(mustHex32B(t, rfc8032Test1SeedHex))
	kSBlob.Str(hostPub[:])
	var sigBlob Writer
	sigBlob.StrS(AlgoEd25519)
	sigBlob.Str(make([]byte, 64))
	var reply Writer
	reply.Byte(MsgKexECDHReply)
	reply.Str(kSBlob.B)
	qS, _ := X25519Base(mustHex32B(t, rfc7748BobHex))
	reply.Str(qS[:])
	reply.Str(sigBlob.B)
	cl.Feed(plainFrame(reply.B))
	if !cl.Failed() || cl.ErrName != "BadSignature" {
		t.Fatalf("early reply: err=%s", cl.ErrName)
	}
}

func TestClientECDHReplyNegatives(t *testing.T) {
	setup := func() (*Client, *scriptedServer) {
		cl := NewClient(scriptedClientCfg(t, "x"))
		ss := &scriptedServer{
			t:        t,
			cl:       cl,
			hostSeed: mustHex32B(t, rfc8032Test1SeedHex),
			eph:      mustHex32B(t, rfc7748BobHex),
			iS:       mustHexB(t, pinnedServerKexInitHex),
		}
		cl.Start()
		cl.Feed(append([]byte("SSH-2.0-VirelaiOS_1.0\r\n"), plainFrame(ss.iS)...))
		if cl.Failed() || len(cl.qC) != 32 {
			t.Fatalf("setup: %s", cl.ErrName)
		}
		return cl, ss
	}
	hostPub := EdDerivePublic(mustHex32B(t, rfc8032Test1SeedHex))
	var kSBlob Writer
	kSBlob.StrS(AlgoEd25519)
	kSBlob.Str(hostPub[:])
	qS, _ := X25519Base(mustHex32B(t, rfc7748BobHex))
	reply := func(edit func(w *Writer)) []byte {
		var w Writer
		w.Byte(MsgKexECDHReply)
		if edit != nil {
			edit(&w)
			return w.B
		}
		return w.B
	}
	validSig := func(cl *Client, ss *scriptedServer) []byte {
		kRaw, ok := X25519(ss.eph, mustHex32B(t, rfc7748AlicePubHex))
		if !ok {
			t.Fatal("k")
		}
		kMpint := Mpint(kRaw[:])
		h := ExchangeHash([]byte(IdentLine), []byte(IdentLine),
			cl.iC, ss.iS, kSBlob.B, cl.qC, qS[:], kMpint)
		sig := EdSign(h[:], ss.hostSeed)
		var sb Writer
		sb.StrS(AlgoEd25519)
		sb.Str(sig[:])
		return sb.B
	}
	cases := []struct {
		name    string
		payload func(cl *Client, ss *scriptedServer) []byte
		wantErr string
	}{
		{"empty reply", func(cl *Client, ss *scriptedServer) []byte {
			return []byte{MsgKexECDHReply}
		}, "BadKexReply"},
		{"qS missing", func(cl *Client, ss *scriptedServer) []byte {
			return reply(func(w *Writer) { w.Str(kSBlob.B) })
		}, "BadKexReply"},
		{"qS short", func(cl *Client, ss *scriptedServer) []byte {
			return reply(func(w *Writer) {
				w.Str(kSBlob.B)
				w.Str([]byte{1, 2, 3})
				w.Str(validSig(cl, ss))
			})
		}, "BadKexReply"},
		{"trailing", func(cl *Client, ss *scriptedServer) []byte {
			return reply(func(w *Writer) {
				w.Str(kSBlob.B)
				w.Str(qS[:])
				w.Str(validSig(cl, ss))
				w.Byte(0)
			})
		}, "BadKexReply"},
		{"bad host blob", func(cl *Client, ss *scriptedServer) []byte {
			return reply(func(w *Writer) {
				w.Str([]byte("not-a-key-blob"))
				w.Str(qS[:])
				w.Str(validSig(cl, ss))
			})
		}, "BadHostKey"},
		{"all-zero qS", func(cl *Client, ss *scriptedServer) []byte {
			return reply(func(w *Writer) {
				w.Str(kSBlob.B)
				w.Str(make([]byte, 32))
				w.Str(validSig(cl, ss))
			})
		}, "WeakSharedSecret"},
		{"bad signature", func(cl *Client, ss *scriptedServer) []byte {
			return reply(func(w *Writer) {
				w.Str(kSBlob.B)
				w.Str(qS[:])
				w.Str(sigBlobOf("ssh-ed25519", make([]byte, 64)))
			})
		}, "BadSignature"},
		{"sig wrong algo", func(cl *Client, ss *scriptedServer) []byte {
			return reply(func(w *Writer) {
				w.Str(kSBlob.B)
				w.Str(qS[:])
				w.Str(sigBlobOf("ssh-rsa", make([]byte, 64)))
			})
		}, "BadSignature"},
		{"sig short", func(cl *Client, ss *scriptedServer) []byte {
			return reply(func(w *Writer) {
				w.Str(kSBlob.B)
				w.Str(qS[:])
				w.Str(sigBlobOf("ssh-ed25519", make([]byte, 63)))
			})
		}, "BadSignature"},
	}
	for _, tc := range cases {
		cl, ss := setup()
		cl.Feed(plainFrame(tc.payload(cl, ss)))
		if !cl.Failed() || cl.ErrName != tc.wantErr {
			t.Fatalf("%s: err=%s (failed=%v)", tc.name, cl.ErrName, cl.Failed())
		}
	}
}

func sigBlobOf(alg string, sig []byte) []byte {
	var w Writer
	w.StrS(alg)
	w.Str(sig)
	return w.B
}

// --- encrypted-phase illegal-transition table ----------------------------

// Every (state × message) cell of the client's channel/service dispatch is
// pinned: each refusal names its error, and each accepted cell names the
// state it leaves. Rows marked "observed" pin behavior the implementation
// currently has rather than RFC-ideal refusal — see the issue comment.
func TestClientChannelIllegalTransitions(t *testing.T) {
	cases := []struct {
		name    string
		at      string // reach() state
		payload []byte
		wantErr string // "" = accepted
		check   func(t *testing.T, ss *scriptedServer, out []byte)
	}{
		// Disconnects close the transport from any state.
		{"svc/disconnect", "svc", []byte{MsgDisconnect}, "PeerDisconnect", nil},
		{"exec/disconnect", "exec", []byte{MsgDisconnect}, "PeerDisconnect", nil},

		// SERVICE_ACCEPT in the service state.
		{"svc/service-accept ok", "svc", svcAccept(SvcUserauth), "", func(t *testing.T, ss *scriptedServer, out []byte) {
			pkts := ss.drain(out)
			if len(pkts) != 1 || pkts[0][0] != MsgUserauthReq {
				t.Fatalf("expected USERAUTH none, got %x", pkts)
			}
		}},
		{"svc/service-accept wrong name", "svc", svcAccept(SvcConnection), "ServiceRejected", nil},
		{"svc/service-accept malformed", "svc", []byte{MsgServiceAccept}, "ServiceRejected", nil},

		// USERAUTH_FAILURE at each auth state.
		{"svc/userauth-fail malformed", "svc", []byte{MsgUserauthFail}, "BadMessage", nil},
		{"svc/userauth-fail no pubkey", "svc", userauthFail([]string{"password"}), "NoSupportedAuth", nil},
		{"svc/userauth-fail offers pubkey", "svc", userauthFail([]string{MethodPubKey}), "", func(t *testing.T, ss *scriptedServer, out []byte) {
			if ss.cl.authState != 2 {
				t.Fatalf("authState = %d", ss.cl.authState)
			}
		}},
		{"auth2/userauth-fail → rejected", "auth2", userauthFail([]string{MethodPubKey}), "AuthRejected", nil},
		{"exec/userauth-fail late", "exec", userauthFail([]string{MethodPubKey}), "AuthRejected", nil},

		// USERAUTH_OK short-circuits the none→publickey dance — the client
		// takes it at authState 1 (observed) and opens the channel.
		{"svc/userauth-ok early", "svc", []byte{MsgUserauthOK}, "", func(t *testing.T, ss *scriptedServer, out []byte) {
			if ss.cl.authState != 3 || ss.cl.chanState != 1 {
				t.Fatalf("auth=%d chan=%d", ss.cl.authState, ss.cl.chanState)
			}
		}},

		// Channel open handshake.
		{"opening/confirm wrong recip", "opening", chanConfirm(7, ServerChanID), "Protocol", nil},
		{"opening/confirm malformed", "opening", []byte{MsgChannelConfirm, 0, 0, 0}, "Protocol", nil},
		{"opening/confirm ok → exec", "opening", chanConfirm(clientLocalID, ServerChanID), "", func(t *testing.T, ss *scriptedServer, out []byte) {
			if ss.cl.chanState != 3 {
				t.Fatalf("chanState = %d", ss.cl.chanState)
			}
			pkts := ss.drain(out)
			if len(pkts) != 1 || pkts[0][0] != MsgChannelReq {
				t.Fatalf("expected exec request, got %x", pkts)
			}
		}},
		{"opening/open-fail", "opening", func() []byte {
			var w Writer
			w.Byte(MsgChannelOpenFail)
			w.U32(clientLocalID)
			w.U32(1)
			w.StrS("refused")
			w.StrS("")
			return w.B
		}(), "OpenRejected", nil},
		{"svc/confirm before open (observed)", "svc", chanConfirm(clientLocalID, ServerChanID), "", func(t *testing.T, ss *scriptedServer, out []byte) {
			// Observed: an unsolicited OPEN_CONFIRMATION is taken at face
			// value — remoteID is set and the exec request goes out.
			if ss.cl.chanState != 3 {
				t.Fatalf("chanState = %d", ss.cl.chanState)
			}
		}},

		// Channel data ordering.
		{"exec/data ok", "exec", chanData(clientLocalID, "hello"), "", func(t *testing.T, ss *scriptedServer, out []byte) {
			if string(ss.cl.Stdout) != "hello" {
				t.Fatalf("stdout = %q", ss.cl.Stdout)
			}
		}},
		{"exec/data wrong recip", "exec", chanData(9, "x"), "Protocol", nil},
		{"exec/data malformed", "exec", []byte{MsgChannelData, 0, 0, 0, 0}, "Protocol", nil},
		{"svc/data before open (observed)", "svc", chanData(clientLocalID, "early"), "", func(t *testing.T, ss *scriptedServer, out []byte) {
			// Observed: CHANNEL_DATA to local id 0 is accepted before any
			// channel exists — appended to Stdout.
			if string(ss.cl.Stdout) != "early" {
				t.Fatalf("stdout = %q", ss.cl.Stdout)
			}
		}},
		{"exec/extended-data ok", "exec", func() []byte {
			var w Writer
			w.Byte(MsgExtendedData)
			w.U32(clientLocalID)
			w.U32(1)
			w.StrS("stderr")
			return w.B
		}(), "", func(t *testing.T, ss *scriptedServer, out []byte) {
			if string(ss.cl.Stdout) != "stderr" {
				t.Fatalf("stdout = %q", ss.cl.Stdout)
			}
		}},
		{"exec/extended-data wrong recip ignored", "exec", func() []byte {
			var w Writer
			w.Byte(MsgExtendedData)
			w.U32(9)
			w.U32(1)
			w.StrS("stderr")
			return w.B
		}(), "", func(t *testing.T, ss *scriptedServer, out []byte) {
			if len(ss.cl.Stdout) != 0 {
				t.Fatalf("stdout = %q", ss.cl.Stdout)
			}
		}},

		// CHANNEL_SUCCESS / CHANNEL_FAILURE.
		{"exec/channel-ok", "exec", func() []byte {
			var w Writer
			w.Byte(MsgChannelOK)
			w.U32(clientLocalID)
			return w.B
		}(), "", nil},
		{"exec/channel-fail", "exec", func() []byte {
			var w Writer
			w.Byte(MsgChannelFail)
			w.U32(clientLocalID)
			return w.B
		}(), "BadState", nil},
		{"opening/channel-fail", "opening", func() []byte {
			var w Writer
			w.Byte(MsgChannelFail)
			w.U32(clientLocalID)
			return w.B
		}(), "BadState", nil},

		// CHANNEL_REQUEST from the server.
		{"exec/exit-status", "exec", chanReq(clientLocalID, ReqExitStatus, false, func(w *Writer) { w.U32(17) }), "", func(t *testing.T, ss *scriptedServer, out []byte) {
			if ss.cl.ExitStatus == nil || *ss.cl.ExitStatus != 17 {
				t.Fatalf("exit status = %v", ss.cl.ExitStatus)
			}
		}},
		{"exec/exit-status want-reply", "exec", chanReq(clientLocalID, ReqExitStatus, true, func(w *Writer) { w.U32(0) }), "", func(t *testing.T, ss *scriptedServer, out []byte) {
			pkts := ss.drain(out)
			if len(pkts) != 1 || pkts[0][0] != MsgChannelFail {
				t.Fatalf("expected CHANNEL_FAILURE, got %x", pkts)
			}
		}},
		{"exec/req wrong recip ignored", "exec", chanReq(9, ReqExitStatus, false, func(w *Writer) { w.U32(1) }), "", func(t *testing.T, ss *scriptedServer, out []byte) {
			if ss.cl.ExitStatus != nil {
				t.Fatal("exit-status to wrong recip consumed")
			}
		}},
		{"exec/req malformed ignored", "exec", []byte{MsgChannelReq, 0, 0, 0}, "", nil},

		// EOF / CLOSE ordering.
		{"exec/eof", "exec", func() []byte {
			var w Writer
			w.Byte(MsgChannelEOF)
			w.U32(clientLocalID)
			return w.B
		}(), "", nil},
		{"exec/close → closed", "exec", func() []byte {
			var w Writer
			w.Byte(MsgChannelClose)
			w.U32(clientLocalID)
			return w.B
		}(), "", func(t *testing.T, ss *scriptedServer, out []byte) {
			if !ss.cl.Closed() {
				t.Fatal("client not closed after CHANNEL_CLOSE")
			}
		}},

		// Window adjust + global requests.
		{"exec/window adjust", "exec", func() []byte {
			var w Writer
			w.Byte(MsgChannelWindow)
			w.U32(clientLocalID)
			w.U32(4096)
			return w.B
		}(), "", func(t *testing.T, ss *scriptedServer, out []byte) {
			if ss.cl.remoteWin != LocalWindow+4096 {
				t.Fatalf("remoteWin = %d", ss.cl.remoteWin)
			}
		}},
		{"exec/global want-reply → failure", "exec", func() []byte {
			var w Writer
			w.Byte(MsgGlobalRequest)
			w.StrS("tcpip-forward")
			w.BoolVal(true)
			return w.B
		}(), "", func(t *testing.T, ss *scriptedServer, out []byte) {
			pkts := ss.drain(out)
			if len(pkts) != 1 || pkts[0][0] != MsgRequestFailure {
				t.Fatalf("expected REQUEST_FAILURE, got %x", pkts)
			}
		}},

		// Ignored message classes — pinned, not refused: IGNORE/DEBUG/
		// USERAUTH_BANNER, and any unassigned number the dispatch does not
		// know (RFC 4253: the peer should UNIMPLEMENTED; the implementation
		// logs and drops — observed).
		{"exec/ignore", "exec", []byte{MsgIgnore, 1, 2}, "", nil},
		{"exec/debug", "exec", []byte{MsgDebug, 1, 2}, "", nil},
		{"exec/banner", "exec", func() []byte {
			var w Writer
			w.Byte(MsgUserauthBanner)
			w.StrS("banner")
			w.StrS("en")
			return w.B
		}(), "", nil},
		{"exec/unknown msg 200", "exec", []byte{200}, "", nil},
		{"exec/newkeys mid-session (observed)", "exec", []byte{MsgNewKeys}, "", nil},
		{"exec/empty payload ignored", "exec", nil, "", nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ss := reach(t, tc.at, "run-cmd")
			out := ss.inject(tc.payload)
			if tc.wantErr == "" {
				if ss.cl.Failed() {
					t.Fatalf("failed: %s %s", ss.cl.Stage, ss.cl.ErrName)
				}
				if tc.check != nil {
					tc.check(t, ss, out)
				}
				return
			}
			if !ss.cl.Failed() || ss.cl.ErrName != tc.wantErr {
				t.Fatalf("err=%s want %s", ss.cl.ErrName, tc.wantErr)
			}
		})
	}
}

// The one refusal the channel FSM has no packet for: an exec-capable client
// told to run a shell (Cmd == "") refuses the open channel with NoTty.
func TestClientShellModeNeedsTty(t *testing.T) {
	ss := reach(t, "opening", "")
	ss.inject(chanConfirm(clientLocalID, ServerChanID))
	if !ss.cl.Failed() || ss.cl.ErrName != "NoTty" || ss.cl.ExitCode != ExitTty || ss.cl.Stage != "tty" {
		t.Fatalf("err=%s code=%d stage=%s", ss.cl.ErrName, ss.cl.ExitCode, ss.cl.Stage)
	}
}

// Missing credentials and pin failures at the exact stage they fire.
func TestClientNoPinFailsAtNewkeys(t *testing.T) {
	cfg := scriptedClientCfg(t, "x")
	cfg.HasPin = false
	cl := NewClient(cfg)
	ss := newScriptedServer(t, cl)
	_ = ss
	if !cl.Failed() || cl.ErrName != "MissingHostPin" || cl.ExitCode != ExitPin {
		t.Fatalf("err=%s code=%d", cl.ErrName, cl.ExitCode)
	}
}

func TestClientMissingSeedFailsAtAuth(t *testing.T) {
	cfg := scriptedClientCfg(t, "x")
	cfg.HasSeed = false
	cl := NewClient(cfg)
	ss := newScriptedServer(t, cl)
	ss.emit()
	out := ss.inject(svcAccept(SvcUserauth))
	ss.drain(out)
	out = ss.inject(userauthFail([]string{MethodPubKey}))
	ss.drain(out)
	if !cl.Failed() || cl.ErrName != "MissingCredential" || cl.ExitCode != ExitAuth {
		t.Fatalf("err=%s code=%d", cl.ErrName, cl.ExitCode)
	}
}

// --- encrypted transport negatives ----------------------------------------

func TestClientEncryptedPacketNegatives(t *testing.T) {
	// A sealed packet replayed at a stale sequence number fails the MAC —
	// the sequence is part of the nonce.
	ss := reach(t, "exec", "run-cmd")
	payload := chanData(clientLocalID, "x")
	pad := bytes.Repeat([]byte{0x77}, PaddingLen(len(payload), AlignAEAD))
	frame, _ := EncodePacket(payload, pad, AlignAEAD)
	ct, tag := ss.send.Seal(frame, ss.sendSeq+5) // out-of-window sequence
	ss.cl.Feed(append(ct, tag...))
	if !ss.cl.Failed() || ss.cl.ErrName != "BadPacket" || ss.cl.ExitCode != ExitTransport {
		t.Fatalf("seq skip: err=%s", ss.cl.ErrName)
	}
	// Truncated encrypted stream: a partial first packet waits, no failure.
	ss = reach(t, "exec", "run-cmd")
	partial := ss.inject(payload) // valid packet, consumed
	_ = partial
	ct, tag = ss.send.Seal(frame, ss.sendSeq)
	out := ss.cl.Feed(append(ct, tag...)[:4])
	if ss.cl.Failed() || len(out) != 0 {
		t.Fatal("partial encrypted length failed")
	}
	// A valid tag but a payload that fails DecodePacket inside the AEAD:
	// seal a frame whose declared padding is below the minimum.
	ss = reach(t, "exec", "run-cmd")
	bad := make([]byte, 20)
	bad[3] = 16 // packet_length 16 (AEAD-aligned)
	bad[4] = 3  // padding 3 < 4 → malformed once authenticated
	ct, tag = ss.send.Seal(bad, ss.sendSeq)
	ss.cl.Feed(append(ct, tag...))
	if !ss.cl.Failed() || ss.cl.ErrName != "BadPacket" {
		t.Fatalf("inner malformed: err=%s", ss.cl.ErrName)
	}
}

// --- server state machine --------------------------------------------------

// The scripted client below drives raw bytes at Server — version, plaintext
// KEX frames, then sealed packets keyed off the real derived session keys.

type scriptedClient struct {
	t       *testing.T
	eph     [32]byte
	iC      []byte
	iS      []byte
	qC      []byte
	send    Cipher // client→server (key 'C')
	recv    Cipher // server→client (key 'D')
	sendSeq uint64
	recvSeq uint64
	session []byte
}

func (c *scriptedClient) hello() []byte {
	var w Writer
	w.Byte(MsgKexInit)
	w.Raw(bytes.Repeat([]byte{0x01}, 16))
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
	out := append([]byte("SSH-2.0-VirelaiOS_1.0\r\n"), plainFrame(c.iC)...)
	return out
}

func (c *scriptedClient) takeKexInit(out []byte) {
	c.t.Helper()
	_, payload := firstPacket(c.t, out)
	if payload[0] != MsgKexInit {
		c.t.Fatalf("server first packet = %d", payload[0])
	}
	c.iS = append([]byte(nil), payload...)
}

func (c *scriptedClient) ecdhInit() []byte {
	q, ok := X25519Base(c.eph)
	if !ok {
		c.t.Fatal("qC")
	}
	c.qC = q[:]
	var w Writer
	w.Byte(MsgKexECDHInit)
	w.Str(q[:])
	return plainFrame(w.B)
}

// finishKex parses KEX_ECDH_REPLY + NEWKEYS from server output, verifies the
// signature over the locally-computed H, derives the session ciphers, and
// returns the client's NEWKEYS frame to feed back.
func (c *scriptedClient) finishKex(out []byte, hostPub [32]byte) []byte {
	c.t.Helper()
	// Skip ident if present (server sends it in the first write).
	if i := bytes.IndexByte(out, '\n'); i >= 0 && bytes.HasPrefix(out, []byte("SSH-")) {
		out = out[i+1:]
	}
	var reply, newkeys []byte
	for len(out) >= 4 {
		pl := int(out[0])<<24 | int(out[1])<<16 | int(out[2])<<8 | int(out[3])
		payload, ok := DecodePacket(out[:4+pl], AlignPlain)
		if !ok {
			c.t.Fatal("server plaintext frame malformed")
		}
		switch payload[0] {
		case MsgKexECDHReply:
			reply = payload
		case MsgNewKeys:
			newkeys = payload
		}
		out = out[4+pl:]
	}
	if reply == nil || newkeys == nil {
		c.t.Fatalf("missing reply/newkeys")
	}
	r := Reader{B: reply}
	_, _ = r.Byte()
	kS, _ := r.Str()
	qS, _ := r.Str()
	sigBlob, _ := r.Str()
	kRaw, ok := X25519(c.eph, [32]byte(qS))
	if !ok {
		c.t.Fatal("shared")
	}
	kMpint := Mpint(kRaw[:])
	h := ExchangeHash(
		[]byte("SSH-2.0-VirelaiOS_1.0"), []byte(IdentLine),
		c.iC, c.iS, kS, c.qC, qS, kMpint,
	)
	sr := Reader{B: sigBlob}
	alg, _ := sr.StrUTF8()
	sig, _ := sr.Str()
	if alg != AlgoEd25519 || len(sig) != 64 || !EdVerify([64]byte(sig), h[:], hostPub) {
		c.t.Fatal("host signature did not verify over recomputed H")
	}
	c.session = h[:]
	c2s := DeriveKey(CipherKeyLen, kMpint, h[:], 'C', h[:])
	s2c := DeriveKey(CipherKeyLen, kMpint, h[:], 'D', h[:])
	copy(c.send.Key[:], c2s)
	copy(c.recv.Key[:], s2c)
	c.sendSeq = 3
	c.recvSeq = 3
	return plainFrame([]byte{MsgNewKeys})
}

func (c *scriptedClient) packet(payload []byte) []byte {
	pad := bytes.Repeat([]byte{0x44}, PaddingLen(len(payload), AlignAEAD))
	frame, ok := EncodePacket(payload, pad, AlignAEAD)
	if !ok {
		c.t.Fatal("encode")
	}
	ct, tag := c.send.Seal(frame, c.sendSeq)
	c.sendSeq++
	return append(ct, tag...)
}

// feedEnc decrypts the server's encrypted stream into payloads.
func (c *scriptedClient) feedEnc(out []byte) [][]byte {
	var payloads [][]byte
	for len(out) >= 4 {
		l := int(c.recv.DecryptLength(out[:4], c.recvSeq))
		wire := 4 + l + PolyTagLen
		if len(out) < wire {
			break
		}
		plain := c.recv.Open(out[:4+l], out[4+l:wire], c.recvSeq)
		if plain == nil {
			c.t.Fatalf("server packet %d tag failed", c.recvSeq)
		}
		payload, ok := DecodePacket(plain, AlignAEAD)
		if !ok {
			c.t.Fatal("server frame malformed")
		}
		payloads = append(payloads, payload)
		out = out[wire:]
		c.recvSeq++
	}
	return payloads
}

func serverCfg(t *testing.T) ServerConfig {
	userPub := EdDerivePublic(mustHex32B(t, "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"))
	return ServerConfig{
		HostSeed:  mustHex32B(t, rfc8032Test1SeedHex),
		Keys:      []AuthKey{{User: "alice", Pub: userPub}},
		Cookie:    mustHexB(t, "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"),
		Ephemeral: mustHexB(t, rfc7748BobHex)[:],
		Run: func(cmd string) ([]byte, uint32, error) {
			return []byte("VIRELAI-SSH5-OK\n"), 0, nil
		},
	}
}

func kexedClient(t *testing.T, srv *Server) *scriptedClient {
	c := &scriptedClient{t: t, eph: mustHex32B(t, rfc7748AliceHex)}
	out := srv.Feed(c.hello())
	c.takeKexInit(out)
	out = srv.Feed(c.ecdhInit())
	srv.Feed(c.finishKex(out, srv.HostPub))
	return c
}

func TestServerVersionAndPlainNegatives(t *testing.T) {
	for _, tc := range []struct {
		name  string
		input []byte
	}{
		{"ssh-1.5", []byte("SSH-1.5-x\r\n")},
		{"ssh-3.0", []byte("SSH-3.0-x\r\n")},
		{"long line", bytes.Repeat([]byte{'A'}, 300)},
		{"65 banners", bytes.Repeat([]byte("banner\r\n"), 65)},
	} {
		srv := NewServer(serverCfg(t))
		srv.Feed(tc.input)
		if !srv.Failed() {
			t.Fatalf("%s: accepted", tc.name)
		}
	}
	// Plaintext packet negatives at the server wire.
	for _, tc := range []struct {
		name  string
		input []byte
	}{
		{"oversized", append([]byte("SSH-2.0-x\r\n"), 0xff, 0xff, 0xff, 0xff)},
		{"tiny", append([]byte("SSH-2.0-x\r\n"), 0, 0, 0, 4, 0, 0, 0, 0)},
		{"bad padding", append([]byte("SSH-2.0-x\r\n"),
			0, 0, 0, 12, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)},
	} {
		srv := NewServer(serverCfg(t))
		srv.Feed(tc.input)
		if !srv.Failed() {
			t.Fatalf("%s: accepted", tc.name)
		}
	}
	// Truncated waits; disconnect during KEX closes without failure.
	srv := NewServer(serverCfg(t))
	out := srv.Feed(append([]byte("SSH-2.0-x\r\n"), 0, 0, 0, 100, 1, 2))
	if srv.Failed() || srv.Closed() {
		t.Fatal("truncated plaintext closed")
	}
	_ = out
	srv = NewServer(serverCfg(t))
	srv.Feed(append([]byte("SSH-2.0-x\r\n"), plainFrame([]byte{MsgDisconnect})...))
	if !srv.Closed() || srv.Failed() {
		t.Fatal("disconnect during kex: failed or still open")
	}
}

func TestServerKexIllegalMessages(t *testing.T) {
	setup := func() *Server {
		srv := NewServer(serverCfg(t))
		srv.Feed([]byte("SSH-2.0-VirelaiOS_1.0\r\n"))
		return srv
	}
	cases := []struct {
		name    string
		payload []byte
	}{
		{"empty", nil},
		{"unknown 99", []byte{99}},
		{"channel data", chanData(0, "x")},
		{"newkeys early trailing", []byte{MsgNewKeys, 0}},
		{"kexinit truncated", mustHexB(t, pinnedClientKexInitHex)[:40]},
		{"kexinit no common", func() []byte {
			var w Writer
			w.Byte(MsgKexInit)
			w.Raw(bytes.Repeat([]byte{1}, 16))
			w.NameList([]string{"diffie-hellman-group14-sha256"})
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
			return w.B
		}()},
		{"ecdh init q short", func() []byte {
			var w Writer
			w.Byte(MsgKexECDHInit)
			w.Str([]byte{1, 2, 3})
			return w.B
		}()},
		{"ecdh init trailing", func() []byte {
			var w Writer
			w.Byte(MsgKexECDHInit)
			q, _ := X25519Base(mustHex32B(t, rfc7748AliceHex))
			w.Str(q[:])
			w.Byte(0)
			return w.B
		}()},
		{"ecdh init all-zero point", func() []byte {
			var w Writer
			w.Byte(MsgKexECDHInit)
			w.Str(make([]byte, 32))
			return w.B
		}()},
	}
	for _, tc := range cases {
		srv := setup()
		srv.Feed(plainFrame(tc.payload))
		if !srv.Failed() {
			t.Fatalf("%s: accepted", tc.name)
		}
	}
	// Observed quirk: a lone NEWKEYS before ECDH_INIT moves the server to
	// phaseEncrypted with nil ciphers — subsequent bytes are silently
	// dropped (nextEncrypted returns immediately), never a failure.
	srv := setup()
	out := srv.Feed(plainFrame([]byte{MsgNewKeys}))
	if srv.Failed() || srv.Closed() || len(out) != 0 {
		t.Fatalf("early newkeys: closed=%v failed=%v out=%d", srv.Closed(), srv.Failed(), len(out))
	}
	out = srv.Feed(plainFrame(chanData(0, "x")))
	if srv.Failed() || len(out) != 0 {
		t.Fatalf("post-newkeys input: failed=%v out=%d", srv.Failed(), len(out))
	}
}

// Encrypted-phase server table: each (ordering × message) cell, including
// the observed pre-auth acceptances.
func TestServerEncryptedIllegalTransitions(t *testing.T) {
	serviceReq := func(name string) []byte {
		var w Writer
		w.Byte(MsgServiceRequest)
		w.StrS(name)
		return w.B
	}
	userauth := func(user, service, method string, rest func(w *Writer)) []byte {
		var w Writer
		w.Byte(MsgUserauthReq)
		w.StrS(user)
		w.StrS(service)
		w.StrS(method)
		if rest != nil {
			rest(&w)
		}
		return w.B
	}
	pubkeyFields := func(w *Writer) {
		w.BoolVal(true)
		w.StrS(AlgoEd25519)
		userPub := EdDerivePublic(mustHex32B(t, "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"))
		var kb Writer
		kb.StrS(AlgoEd25519)
		kb.Str(userPub[:])
		w.Str(kb.B)
	}
	open := func(typ string, maxPkt uint32) []byte {
		var w Writer
		w.Byte(MsgChannelOpen)
		w.StrS(typ)
		w.U32(0)
		w.U32(LocalWindow)
		w.U32(maxPkt)
		return w.B
	}
	cases := []struct {
		name     string
		payloads [][]byte
		wantFail bool
		check    func(t *testing.T, c *scriptedClient, out [][]byte)
	}{
		{"service wrong name", [][]byte{serviceReq("ssh-connection")}, true, nil},
		{"service malformed", [][]byte{{MsgServiceRequest}}, true, nil},
		{"service ok", [][]byte{serviceReq(SvcUserauth)}, false, func(t *testing.T, c *scriptedClient, out [][]byte) {
			if len(out) != 1 || out[0][0] != MsgServiceAccept {
				t.Fatalf("out = %x", out)
			}
		}},
		{"userauth malformed", [][]byte{{MsgUserauthReq}}, true, nil},
		{"userauth password method", [][]byte{
			userauth("alice", SvcConnection, "password", nil)}, true, nil},
		{"userauth none first", [][]byte{
			userauth("alice", SvcConnection, MethodNone, nil)}, false, func(t *testing.T, c *scriptedClient, out [][]byte) {
			if len(out) != 1 || out[0][0] != MsgUserauthFail {
				t.Fatalf("out = %x", out)
			}
		}},
		{"pubkey no signature", [][]byte{
			userauth("alice", SvcConnection, MethodPubKey, func(w *Writer) {
				w.BoolVal(false)
				w.StrS(AlgoEd25519)
				var kb Writer
				kb.StrS(AlgoEd25519)
				p := EdDerivePublic(mustHex32B(t, "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"))
				kb.Str(p[:])
				w.Str(kb.B)
			})}, false, func(t *testing.T, c *scriptedClient, out [][]byte) {
			if len(out) != 1 || out[0][0] != MsgUserauthFail {
				t.Fatalf("out = %x", out)
			}
		}},
		{"pubkey malformed sig field", [][]byte{
			userauth("alice", SvcConnection, MethodPubKey, func(w *Writer) {
				pubkeyFields(w)
				// signature string missing entirely
			})}, true, nil},
		{"channel open non-session", [][]byte{open("direct-tcpip", 32768)}, true, nil},
		{"channel open maxpkt 0", [][]byte{open(ChanSession, 0)}, true, nil},
		{"channel open malformed", [][]byte{{MsgChannelOpen, 0, 0}}, true, nil},
		{"channel open before auth (observed)", [][]byte{open(ChanSession, 32768)}, false, func(t *testing.T, c *scriptedClient, out [][]byte) {
			// Observed: the server confirms a session channel with no
			// userauth first — it is a test fixture, not an auth gate.
			if len(out) != 1 || out[0][0] != MsgChannelConfirm {
				t.Fatalf("out = %x", out)
			}
		}},
		{"channel req wrong recip", [][]byte{
			chanReq(7, ReqExec, true, func(w *Writer) { w.StrS("x") })}, true, nil},
		{"channel req unknown want-reply", [][]byte{
			open(ChanSession, 32768),
			chanReq(ServerChanID, "pty-req", true, nil)}, false, func(t *testing.T, c *scriptedClient, out [][]byte) {
			if len(out) != 1 || out[0][0] != MsgChannelFail {
				t.Fatalf("out = %x", out)
			}
		}},
		{"exec trailing garbage", [][]byte{
			open(ChanSession, 32768),
			chanReq(ServerChanID, ReqExec, true, func(w *Writer) { w.StrS("x"); w.Byte(0) })}, true, nil},
		{"channel data unhandled (observed)", [][]byte{
			open(ChanSession, 32768),
			chanData(ServerChanID, "stdin")}, false, func(t *testing.T, c *scriptedClient, out [][]byte) {
			// Observed: client→server CHANNEL_DATA has no dispatch case —
			// logged "unhandled message", no response, no failure.
			if len(out) != 0 {
				t.Fatalf("out = %x", out)
			}
		}},
		{"unknown msg 200 unhandled", [][]byte{{200}}, false, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := NewServer(serverCfg(t))
			c := kexedClient(t, srv)
			var last [][]byte
			for _, p := range tc.payloads {
				last = c.feedEnc(srv.Feed(c.packet(p)))
			}
			if tc.wantFail {
				if !srv.Failed() {
					t.Fatalf("accepted: %x", last)
				}
				return
			}
			if srv.Failed() {
				t.Fatalf("failed")
			}
			if tc.check != nil {
				tc.check(t, c, last)
			}
		})
	}
	// EOF and CLOSE from the client close the transport (observed: not a
	// failure). After a completed exec the server itself closes, so the
	// `execRan` second-exec refusal is defensive — unreachable over the wire.
	for _, msg := range []byte{MsgChannelEOF, MsgChannelClose} {
		srv := NewServer(serverCfg(t))
		c := kexedClient(t, srv)
		var w Writer
		w.Byte(msg)
		w.U32(ServerChanID)
		srv.Feed(c.packet(w.B))
		if !srv.Closed() || srv.Failed() {
			t.Fatalf("msg %d: closed=%v failed=%v", msg, srv.Closed(), srv.Failed())
		}
	}
	// One exec end-to-end through the scripted client: request → SUCCESS,
	// data, exit-status, EOF, CLOSE, then the server is closed.
	srv := NewServer(serverCfg(t))
	c := kexedClient(t, srv)
	var w Writer
	w.Byte(MsgChannelOpen)
	w.StrS(ChanSession)
	w.U32(0)
	w.U32(LocalWindow)
	w.U32(LocalMaxPacket)
	_ = c.feedEnc(srv.Feed(c.packet(w.B)))
	out := c.feedEnc(srv.Feed(c.packet(chanReq(ServerChanID, ReqExec, true, func(w *Writer) { w.StrS("echo one") }))))
	if len(out) < 5 || out[0][0] != MsgChannelOK {
		t.Fatalf("exec responses = %x", out)
	}
	if !srv.Closed() {
		t.Fatal("server did not close after exec")
	}
}
