package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/sha256"
	"testing"
)

// RFC 8032 §7.1 TEST 1 / TEST 2 and the OpenSSH PROTOCOL.chacha20poly1305
// vector the Zig/Swift sides pin (ADR 0025 D4 / D8).

const (
	rfc8032Test1Seed = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
	rfc8032Test1Pub  = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
)

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, ok := parseHex(s)
	if !ok {
		t.Fatalf("bad hex %q", s)
	}
	return b
}

func mustHex32(t *testing.T, s string) [32]byte {
	t.Helper()
	v, ok := parseHex32(s)
	if !ok {
		t.Fatalf("bad hex32 %q", s)
	}
	return v
}

func TestOpenSSHCipherPinnedVector(t *testing.T) {
	key := mustHex(t, "8bbff6855fc102338c373e73aac0c914"+
		"f076a905b2444a32eecaffeae22becc5"+
		"e9b7a7a5825a8249346ec1c28301cf39"+
		"4543fc7569887d76e168f37562ac0740")
	plain := mustHex(t, "00000048065e00000000000000384c6f"+
		"72656d20697073756d20646f6c6f7220"+
		"73697420616d65742c20636f6e736563"+
		"7465747572206164697069736963696e"+
		"6720656c69744e43e804dc6c")
	wantCT := mustHex(t, "2c3ecce4a5bc05895bf07a7ba956b6c6"+
		"8829ac7c83b780b7000ecde745afc705"+
		"bbc378ce03a280236b87b53bed583966"+
		"2302b164b6286a48cd1e097138e3cb90"+
		"9b8b2b829dd18d2a35ff82d9")
	wantTag := mustHex(t, "95349e855bf02c298ef775f2d1a7e8b8")
	var c sshCipher
	copy(c.Key[:], key)
	ct, tag := c.Seal(plain, 7)
	if !bytes.Equal(ct, wantCT) {
		t.Fatalf("ciphertext =\n%s\nwant\n%s", encodeHex(ct), encodeHex(wantCT))
	}
	if !bytes.Equal(tag, wantTag) {
		t.Fatalf("tag = %s want %s", encodeHex(tag), encodeHex(wantTag))
	}
	if c.DecryptLength(ct[:4], 7) != 0x48 {
		t.Fatalf("length = %d want 0x48", c.DecryptLength(ct[:4], 7))
	}
	got := c.Open(ct, tag, 7)
	if !bytes.Equal(got, plain) {
		t.Fatalf("open mismatch")
	}
	bad := append([]byte(nil), tag...)
	bad[0] ^= 1
	if c.Open(ct, bad, 7) != nil {
		t.Fatal("tampered tag opened")
	}
}

func TestChaCha20DjbZeroBlocks(t *testing.T) {
	var key [32]byte
	var nonce [8]byte
	b0 := chachaBlock(key[:], 0, nonce[:])
	want0 := mustHex(t, "76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7"+
		"da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586")
	if !bytes.Equal(b0[:], want0) {
		t.Fatalf("block0 =\n%s\nwant\n%s", encodeHex(b0[:]), encodeHex(want0))
	}
}

func TestPoly1305RFC8439(t *testing.T) {
	key := mustHex(t, "85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
	msg := []byte("Cryptographic Forum Research Group")
	tag := poly1305Tag(msg, key)
	want := mustHex(t, "a8061dc1305136c6c22b8baf0c0127a9")
	if !bytes.Equal(tag[:], want) {
		t.Fatalf("tag = %s want %s", encodeHex(tag[:]), encodeHex(want))
	}
}

func TestEd25519RFC8032Test1And2(t *testing.T) {
	seed := mustHex32(t, rfc8032Test1Seed)
	pub := edDerivePublic(seed)
	wantPub := mustHex32(t, rfc8032Test1Pub)
	if pub != wantPub {
		t.Fatalf("TEST 1 pub = %s want %s", encodeHex(pub[:]), rfc8032Test1Pub)
	}
	sig := edSign(nil, seed)
	if !edVerify(sig, nil, pub) {
		t.Fatal("TEST 1 self-verify failed")
	}
	std := ed25519.NewKeyFromSeed(seed[:])
	if !ed25519.Verify(std.Public().(ed25519.PublicKey), nil, sig[:]) {
		t.Fatal("TEST 1 signature rejected by crypto/ed25519")
	}

	seed2 := mustHex32(t, "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
	pub2 := edDerivePublic(seed2)
	want2 := mustHex32(t, "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
	if pub2 != want2 {
		t.Fatalf("TEST 2 pub = %s want %s", encodeHex(pub2[:]), encodeHex(want2[:]))
	}
	msg := []byte{0x72}
	sig2 := edSign(msg, seed2)
	if !edVerify(sig2, msg, pub2) {
		t.Fatal("TEST 2 self-verify failed")
	}
	std2 := ed25519.NewKeyFromSeed(seed2[:])
	if !ed25519.Verify(std2.Public().(ed25519.PublicKey), msg, sig2[:]) {
		t.Fatal("TEST 2 signature rejected by crypto/ed25519")
	}
}

func TestX25519RFC7748(t *testing.T) {
	alice := mustHex32(t, "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	bob := mustHex32(t, "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	qa, ok := x25519Base(alice)
	if !ok {
		t.Fatal("alice base failed")
	}
	wantA := mustHex(t, "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
	if !bytes.Equal(qa[:], wantA) {
		t.Fatalf("alice pub = %s", encodeHex(qa[:]))
	}
	qb, ok := x25519Base(bob)
	if !ok {
		t.Fatal("bob base failed")
	}
	k, ok := x25519(alice, qb)
	if !ok {
		t.Fatal("shared failed")
	}
	wantK := mustHex(t, "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
	if !bytes.Equal(k[:], wantK) {
		t.Fatalf("K = %s", encodeHex(k[:]))
	}
	curve := ecdh.X25519()
	ak, err := curve.NewPrivateKey(alice[:])
	if err != nil {
		t.Fatal(err)
	}
	bp, err := curve.NewPublicKey(qb[:])
	if err != nil {
		t.Fatal(err)
	}
	got, err := ak.ECDH(bp)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, k[:]) {
		t.Fatal("stdlib ECDH mismatch")
	}
}

func TestSHA256MatchesStdlib(t *testing.T) {
	msg := []byte("VirelaiOS SSH-2")
	sum := sha256Sum(msg)
	want := sha256.Sum256(msg)
	if sum != want {
		t.Fatalf("sha256 = %s want %s", encodeHex(sum[:]), encodeHex(want[:]))
	}
}

func TestParseAuthKeys(t *testing.T) {
	keys, ok := parseAuthKeys("#v1\nalice\tssh-ed25519\t" + rfc8032Test1Pub + "\n")
	if !ok || len(keys) != 1 || keys[0].User != "alice" {
		t.Fatalf("parse = %+v ok=%v", keys, ok)
	}
	if _, ok := parseAuthKeys("alice\tssh-ed25519\t" + rfc8032Test1Pub + "\n"); ok {
		t.Fatal("missing #v1 accepted")
	}
	if _, ok := parseAuthKeys("#v1\nalice\tssh-rsa\t" + rfc8032Test1Pub + "\n"); ok {
		t.Fatal("ssh-rsa accepted")
	}
}

func TestAuthIdentity(t *testing.T) {
	user, key := authIdentity("user=alice key=ssh-ed25519")
	if user != "alice" || key != "ssh-ed25519" {
		t.Fatalf("authIdentity = %q,%q", user, key)
	}
	user, key = authIdentity("")
	if user != "" || key != "" {
		t.Fatalf("empty desc = %q,%q", user, key)
	}
}

func TestServerKexAuthExec(t *testing.T) {
	hostSeed := mustHex32(t, rfc8032Test1Seed)
	userSeed := mustHex32(t, "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
	userPub := edDerivePublic(userSeed)
	alice := mustHex32(t, "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	bob := mustHex32(t, "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	cookie := mustHex(t, "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")

	var logs []string
	srv := newServer(serverConfig{
		HostSeed:  hostSeed,
		Keys:      []AuthKey{{User: "alice", Pub: userPub}},
		Cookie:    cookie,
		Ephemeral: bob[:],
		Run: func(cmd string) ([]byte, uint32, error) {
			if cmd != "echo VIRELAI-SSH-SERVER-OK" {
				t.Fatalf("exec cmd = %q", cmd)
			}
			return []byte("VIRELAI-SSH-SERVER-OK\n"), 0, nil
		},
		Log: func(s string) { logs = append(logs, s) },
	})

	cl := newScripted(t, alice, userSeed)
	out := srv.Feed(cl.hello())
	cl.takePlain(t, out)
	out = srv.Feed(cl.ecdhInit())
	cl.finishKex(t, out, srv.HostPub)

	var w sshWriter
	w.Byte(msgServiceRequest)
	w.StrS(svcUserauth)
	res := cl.feedEnc(t, srv.Feed(cl.packet(w.B)))
	if len(res) != 1 || res[0][0] != msgServiceAccept {
		t.Fatalf("service = %x", res)
	}

	auth := cl.publickey(t, "alice")
	res = cl.feedEnc(t, srv.Feed(auth))
	if len(res) != 1 || !bytes.Equal(res[0], []byte{msgUserauthOK}) {
		t.Fatalf("auth = %x logs=%v", res, logs)
	}

	w = sshWriter{}
	w.Byte(msgChannelOpen)
	w.StrS(chanSession)
	w.U32(0)
	w.U32(1 << 17)
	w.U32(32768)
	res = cl.feedEnc(t, srv.Feed(cl.packet(w.B)))
	if len(res) != 1 || res[0][0] != msgChannelConfirm {
		t.Fatalf("open = %x", res)
	}

	w = sshWriter{}
	w.Byte(msgChannelReq)
	w.U32(serverChanID)
	w.StrS(reqExec)
	w.BoolVal(true)
	w.StrS("echo VIRELAI-SSH-SERVER-OK")
	res = cl.feedEnc(t, srv.Feed(cl.packet(w.B)))
	if len(res) < 5 {
		t.Fatalf("exec responses = %d logs=%v", len(res), logs)
	}
	if res[0][0] != msgChannelOK {
		t.Fatalf("exec ok = %x", res[0])
	}
	r := sshReader{B: res[1]}
	if b, _ := r.Byte(); b != msgChannelData {
		t.Fatalf("data type %d", b)
	}
	_, _ = r.U32()
	body, ok := r.Str()
	if !ok || string(body) != "VIRELAI-SSH-SERVER-OK\n" {
		t.Fatalf("stdout = %q", body)
	}
	if !srv.Closed() {
		t.Fatal("server did not close after exec")
	}
}

func TestServerRejectsUnknownKey(t *testing.T) {
	hostSeed := mustHex32(t, rfc8032Test1Seed)
	goodPub := edDerivePublic(mustHex32(t, "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"))
	wrongSeed := mustHex32(t, "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7")
	alice := mustHex32(t, "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	bob := mustHex32(t, "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")

	srv := newServer(serverConfig{
		HostSeed:  hostSeed,
		Keys:      []AuthKey{{User: "alice", Pub: goodPub}},
		Cookie:    bytes.Repeat([]byte{0xf0}, 16),
		Ephemeral: bob[:],
		Run:       func(string) ([]byte, uint32, error) { return nil, 0, nil },
	})
	cl := newScripted(t, alice, wrongSeed)
	out := srv.Feed(cl.hello())
	cl.takePlain(t, out)
	out = srv.Feed(cl.ecdhInit())
	cl.finishKex(t, out, srv.HostPub)

	var w sshWriter
	w.Byte(msgServiceRequest)
	w.StrS(svcUserauth)
	_ = cl.feedEnc(t, srv.Feed(cl.packet(w.B)))
	res := cl.feedEnc(t, srv.Feed(cl.publickey(t, "alice")))
	if len(res) != 1 || res[0][0] != msgUserauthFail {
		t.Fatalf("wrong key = %x", res)
	}
}

func TestServerRejectsTamperedMAC(t *testing.T) {
	hostSeed := mustHex32(t, rfc8032Test1Seed)
	userSeed := mustHex32(t, "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
	userPub := edDerivePublic(userSeed)
	alice := mustHex32(t, "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	bob := mustHex32(t, "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	srv := newServer(serverConfig{
		HostSeed:  hostSeed,
		Keys:      []AuthKey{{User: "alice", Pub: userPub}},
		Cookie:    bytes.Repeat([]byte{0xf0}, 16),
		Ephemeral: bob[:],
		Run:       func(string) ([]byte, uint32, error) { return nil, 0, nil },
	})
	cl := newScripted(t, alice, userSeed)
	out := srv.Feed(cl.hello())
	cl.takePlain(t, out)
	out = srv.Feed(cl.ecdhInit())
	cl.finishKex(t, out, srv.HostPub)

	var w sshWriter
	w.Byte(msgServiceRequest)
	w.StrS(svcUserauth)
	pkt := cl.packet(w.B)
	pkt[len(pkt)-1] ^= 0x01
	_ = srv.Feed(pkt)
	if !srv.Failed() {
		t.Fatal("tampered MAC did not fail closed")
	}
}

type scripted struct {
	t        *testing.T
	eph      [32]byte
	userSeed [32]byte
	send     sshCipher
	recv     sshCipher
	sendSeq  uint64
	recvSeq  uint64
	session  []byte
	rx       []byte
	iC       []byte
	iS       []byte
}

func newScripted(t *testing.T, eph, userSeed [32]byte) *scripted {
	return &scripted{t: t, eph: eph, userSeed: userSeed}
}

func (c *scripted) hello() []byte {
	var w sshWriter
	w.Byte(msgKexInit)
	w.Raw(bytes.Repeat([]byte{0x01}, 16))
	w.NameList([]string{kexCurve, kexCurveAlias})
	w.NameList([]string{algoEd25519})
	w.NameList([]string{cipherOpenSSH})
	w.NameList([]string{cipherOpenSSH})
	w.NameList(nil)
	w.NameList(nil)
	w.NameList([]string{compNone})
	w.NameList([]string{compNone})
	w.NameList(nil)
	w.NameList(nil)
	w.BoolVal(false)
	w.U32(0)
	c.iC = append([]byte(nil), w.B...)
	pad := bytes.Repeat([]byte{0x21}, paddingLen(len(c.iC), alignPlain))
	frame, ok := encodePacket(c.iC, pad, alignPlain)
	if !ok {
		c.t.Fatal("encode kexinit")
	}
	out := append([]byte("SSH-2.0-VirelaiOS_1.0\r\n"), frame...)
	return out
}

func (c *scripted) takePlain(t *testing.T, out []byte) {
	t.Helper()
	nl := bytes.IndexByte(out, '\n')
	if nl < 0 {
		t.Fatal("no version")
	}
	rest := out[nl+1:]
	if len(rest) < 4 {
		t.Fatal("short after version")
	}
	pl := int(rest[0])<<24 | int(rest[1])<<16 | int(rest[2])<<8 | int(rest[3])
	frame := rest[:4+pl]
	payload, ok := decodePacket(frame, alignPlain)
	if !ok || payload[0] != msgKexInit {
		t.Fatalf("server kexinit = %x", payload)
	}
	c.iS = append([]byte(nil), payload...)
}

func (c *scripted) ecdhInit() []byte {
	qC, ok := x25519Base(c.eph)
	if !ok {
		c.t.Fatal("qC")
	}
	var w sshWriter
	w.Byte(msgKexECDHInit)
	w.Str(qC[:])
	pad := bytes.Repeat([]byte{0x22}, paddingLen(len(w.B), alignPlain))
	frame, ok := encodePacket(w.B, pad, alignPlain)
	if !ok {
		c.t.Fatal("encode ecdh")
	}
	return frame
}

func (c *scripted) finishKex(t *testing.T, out []byte, hostPub [32]byte) {
	t.Helper()
	off := 0
	var payloads [][]byte
	for off+4 <= len(out) {
		pl := int(out[off])<<24 | int(out[off+1])<<16 | int(out[off+2])<<8 | int(out[off+3])
		total := 4 + pl
		if off+total > len(out) {
			break
		}
		p, ok := decodePacket(out[off:off+total], alignPlain)
		if !ok {
			t.Fatal("decode kex frame")
		}
		payloads = append(payloads, p)
		off += total
	}
	if len(payloads) < 2 {
		t.Fatalf("kex frames = %d", len(payloads))
	}
	if len(c.iS) == 0 {
		t.Fatal("missing server KEXINIT")
	}
	r := sshReader{B: payloads[0]}
	if b, _ := r.Byte(); b != msgKexECDHReply {
		t.Fatal("not ecdh reply")
	}
	kS, _ := r.Str()
	qS, _ := r.Str()
	if payloads[1][0] != msgNewKeys {
		t.Fatal("missing newkeys")
	}
	var qSa [32]byte
	copy(qSa[:], qS)
	kRaw, ok := x25519(c.eph, qSa)
	if !ok {
		t.Fatal("shared")
	}
	kMpint := mpint(kRaw[:])
	qC, _ := x25519Base(c.eph)
	h := exchangeHash(
		[]byte("SSH-2.0-VirelaiOS_1.0"), []byte(identLine),
		c.iC, c.iS, kS, qC[:], qS, kMpint,
	)
	kr := sshReader{B: kS}
	_, _ = kr.StrUTF8()
	pub, _ := kr.Str()
	var host [32]byte
	copy(host[:], pub)
	if host != hostPub {
		t.Fatal("host pub mismatch")
	}
	c.session = h[:]
	keyC2S := deriveKey(sshCipherKey, kMpint, h[:], 'C', h[:])
	keyS2C := deriveKey(sshCipherKey, kMpint, h[:], 'D', h[:])
	copy(c.send.Key[:], keyC2S)
	copy(c.recv.Key[:], keyS2C)
	c.sendSeq = 3
	c.recvSeq = 3
	pad := bytes.Repeat([]byte{0x23}, paddingLen(1, alignPlain))
	frame, ok := encodePacket([]byte{msgNewKeys}, pad, alignPlain)
	if !ok {
		t.Fatal("encode newkeys")
	}
	// The server already installed the cipher on its NEWKEYS; feed ours.
	// newScripted's caller feeds this separately — return via leftover? The
	// test feeds NEWKEYS as the next Feed. Store it on the helper.
	c.rx = frame
}

func (c *scripted) packet(payload []byte) []byte {
	if len(c.rx) > 0 {
		// First encrypted send is preceded by the plaintext NEWKEYS still
		// sitting in rx from finishKex.
		nk := c.rx
		c.rx = nil
		pad := bytes.Repeat([]byte{0x44}, paddingLen(len(payload), alignAEAD))
		frame, ok := encodePacket(payload, pad, alignAEAD)
		if !ok {
			c.t.Fatal("encode enc")
		}
		ct, tag := c.send.Seal(frame, c.sendSeq)
		c.sendSeq++
		return append(nk, append(ct, tag...)...)
	}
	pad := bytes.Repeat([]byte{0x44}, paddingLen(len(payload), alignAEAD))
	frame, ok := encodePacket(payload, pad, alignAEAD)
	if !ok {
		c.t.Fatal("encode enc")
	}
	ct, tag := c.send.Seal(frame, c.sendSeq)
	c.sendSeq++
	return append(ct, tag...)
}

func (c *scripted) feedEnc(t *testing.T, b []byte) [][]byte {
	t.Helper()
	c.rx = append(c.rx, b...)
	var out [][]byte
	for len(c.rx) >= 4 {
		length := int(c.recv.DecryptLength(c.rx[:4], c.recvSeq))
		if length < 5 {
			break
		}
		ctLen := 4 + length
		wire := ctLen + polyTagLen
		if len(c.rx) < wire {
			break
		}
		plain := c.recv.Open(c.rx[:ctLen], c.rx[ctLen:wire], c.recvSeq)
		if plain == nil {
			t.Fatal("open failed")
		}
		c.rx = c.rx[wire:]
		c.recvSeq++
		p, ok := decodePacket(plain, alignAEAD)
		if !ok {
			t.Fatal("decode aead")
		}
		out = append(out, p)
	}
	return out
}

func (c *scripted) publickey(t *testing.T, user string) []byte {
	t.Helper()
	pub := edDerivePublic(c.userSeed)
	var kb sshWriter
	kb.StrS(algoEd25519)
	kb.Str(pub[:])
	var signed sshWriter
	signed.Str(c.session)
	signed.Byte(msgUserauthReq)
	signed.StrS(user)
	signed.StrS(svcConnection)
	signed.StrS(methodPubKey)
	signed.BoolVal(true)
	signed.StrS(algoEd25519)
	signed.Str(kb.B)
	sig := edSign(signed.B, c.userSeed)
	var sb sshWriter
	sb.StrS(algoEd25519)
	sb.Str(sig[:])
	var auth sshWriter
	auth.Byte(msgUserauthReq)
	auth.StrS(user)
	auth.StrS(svcConnection)
	auth.StrS(methodPubKey)
	auth.BoolVal(true)
	auth.StrS(algoEd25519)
	auth.Str(kb.B)
	auth.Str(sb.B)
	return c.packet(auth.B)
}
