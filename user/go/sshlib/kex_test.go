package sshlib

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/sha512"
	"testing"
)

// The published fixture identities (ADR 0025 D8 / VSSHTests.swift): host key
// is RFC 8032 §7.1 TEST 1, user key TEST 2, KEX ephemerals RFC 7748 §6.1.
const (
	rfc8032Test1SeedHex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
	rfc8032Test1PubHex  = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
	rfc7748AliceHex     = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
	rfc7748AlicePubHex  = "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
	rfc7748BobHex       = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"
	rfc7748BobPubHex    = "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"
	rfc7748SharedHex    = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
	rfc7748MpintHex     = "000000204a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
)

// The deterministic client KEXINIT: MsgKexInit, the 0x01×16 test cookie,
// then the ADR 0025 D2 algorithm lists — pinned byte-for-byte (the same
// shape VSSHTests pins with the 0001..0f cookie).
const pinnedClientKexInitHex = "14" +
	"01010101010101010101010101010101" +
	"0000002e637572766532353531392d7368613235362c637572766532353531392d736861323536406c69627373682e6f7267" +
	"0000000b7373682d65643235353139" +
	"0000001d63686163686132302d706f6c7931333035406f70656e7373682e636f6d" +
	"0000001d63686163686132302d706f6c7931333035406f70656e7373682e636f6d" +
	"00000000" + "00000000" +
	"000000046e6f6e65" + "000000046e6f6e65" +
	"00000000" + "00000000" +
	"00" + "00000000"

// The deterministic server KEXINIT (cookie f0..ff), same lists.
const pinnedServerKexInitHex = "14" +
	"f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff" +
	"0000002e637572766532353531392d7368613235362c637572766532353531392d736861323536406c69627373682e6f7267" +
	"0000000b7373682d65643235353139" +
	"0000001d63686163686132302d706f6c7931333035406f70656e7373682e636f6d" +
	"0000001d63686163686132302d706f6c7931333035406f70656e7373682e636f6d" +
	"00000000" + "00000000" +
	"000000046e6f6e65" + "000000046e6f6e65" +
	"00000000" + "00000000" +
	"00" + "00000000"

// The transcript pinned across all three implementations (Zig kex.zig →
// Swift SSHKDF → this package): I_C carries the 0001..0f cookie, I_S the
// f0..ff cookie and the legacy hmac name-lists the responder once offered.
const (
	pinnedICHex = "14" +
		"000102030405060708090a0b0c0d0e0f" +
		"0000002e637572766532353531392d7368613235362c637572766532353531392d736861323536406c69627373682e6f7267" +
		"0000000b7373682d65643235353139" +
		"0000001d63686163686132302d706f6c7931333035406f70656e7373682e636f6d" +
		"0000001d63686163686132302d706f6c7931333035406f70656e7373682e636f6d" +
		"00000000" + "00000000" +
		"000000046e6f6e65" + "000000046e6f6e65" +
		"00000000" + "00000000" +
		"00" + "00000000"
	pinnedISHex = "14" +
		"f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff" +
		"0000002e637572766532353531392d7368613235362c637572766532353531392d736861323536406c69627373682e6f7267" +
		"0000000b7373682d65643235353139" +
		"0000001d63686163686132302d706f6c7931333035406f70656e7373682e636f6d" +
		"0000001d63686163686132302d706f6c7931333035406f70656e7373682e636f6d" +
		"00000017686d61632d736861322d3235362c686d61632d73686131" +
		"00000017686d61632d736861322d3235362c686d61632d73686131" +
		"000000046e6f6e65" + "000000046e6f6e65" +
		"00000000" + "00000000" +
		"00" + "00000000"
	pinnedHHex   = "15c9cacbd36588f06a5189f221597e1e4d13f2f8c1fe9951f62b85afb957136d"
	pinnedKeyC2S = "205c0be510c7725ad0588a426feab9a7a35f56ef9377fb131b97f146f65ee8ea" +
		"4ce1f50dd2da22701781fe559f36f83216d87a049c88d00dbeb1ed81a1579a12"
	pinnedKeyS2C = "dea53158377f125f836602073e10929e33f1efb1112b4947f8b57c3e4c43c099" +
		"b3591a8bd466ddbffafe013263081f35813b9ba4277d52c72105cce6bb452a4f"
	pinnedHostSig = "c1b0702fd849722c5c05b28966e64bfc7ee94a2b2639f8f1cf1baab0ce47340" +
		"19e88a52a430d12a8ec94363a340e1dd6fbaa7fdb3bc61b104aba877ba5deca0d"
)

// firstPacket splits a server ident line + plaintext frame stream into the
// version line and the first decoded payload.
func firstPacket(t *testing.T, out []byte) (string, []byte) {
	t.Helper()
	nl := bytes.IndexByte(out, '\n')
	if nl < 0 {
		t.Fatalf("no ident line in %x", out)
	}
	ver := string(out[:nl])
	if len(ver) > 0 && ver[len(ver)-1] == '\r' {
		ver = ver[:len(ver)-1]
	}
	rest := out[nl+1:]
	if len(rest) < 4 {
		t.Fatal("short stream after ident")
	}
	pl := int(rest[0])<<24 | int(rest[1])<<16 | int(rest[2])<<8 | int(rest[3])
	if len(rest) < 4+pl {
		t.Fatalf("declared %d, have %d", pl, len(rest)-4)
	}
	payload, ok := DecodePacket(rest[:4+pl], AlignPlain)
	if !ok {
		t.Fatalf("frame %x did not decode", rest[:4+pl])
	}
	return ver, payload
}

// Pinned wire vector: the client's first write is the ident line plus a
// KEXINIT whose payload must be exactly the deterministic bytes.
func TestClientKexInitPinnedBytes(t *testing.T) {
	cl := NewClient(ClientConfig{
		Cookie: bytes.Repeat([]byte{0x01}, 16),
	})
	out := cl.Start()
	ver, payload := firstPacket(t, out)
	if ver != IdentLine {
		t.Fatalf("ident = %q want %q", ver, IdentLine)
	}
	if !bytes.Equal(payload, mustHexB(t, pinnedClientKexInitHex)) {
		t.Fatalf("I_C =\n%x\nwant\n%s", payload, pinnedClientKexInitHex)
	}
}

// Pinned wire vector: the server's first write (after the client ident) is
// its ident line plus the byte-exact KEXINIT.
func TestServerKexInitPinnedBytes(t *testing.T) {
	srv := NewServer(ServerConfig{
		HostSeed: mustHex32B(t, rfc8032Test1SeedHex),
		Cookie:   mustHexB(t, "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"),
	})
	out := srv.Feed([]byte("SSH-2.0-VirelaiOS_1.0\r\n"))
	ver, payload := firstPacket(t, out)
	if ver != IdentLine {
		t.Fatalf("ident = %q want %q", ver, IdentLine)
	}
	if !bytes.Equal(payload, mustHexB(t, pinnedServerKexInitHex)) {
		t.Fatalf("I_S =\n%x\nwant\n%s", payload, pinnedServerKexInitHex)
	}
}

// RFC 7748 §6.1: both directions of the Alice/Bob exchange land on the same
// shared secret, and stdlib crypto/ecdh agrees (independent implementation).
func TestX25519KnownAnswers(t *testing.T) {
	alice := mustHex32B(t, rfc7748AliceHex)
	bob := mustHex32B(t, rfc7748BobHex)
	qa, ok := X25519Base(alice)
	if !ok || !bytes.Equal(qa[:], mustHexB(t, rfc7748AlicePubHex)) {
		t.Fatalf("alice pub = %x ok=%v", qa, ok)
	}
	qb, ok := X25519Base(bob)
	if !ok || !bytes.Equal(qb[:], mustHexB(t, rfc7748BobPubHex)) {
		t.Fatalf("bob pub = %x ok=%v", qb, ok)
	}
	kAB, ok := X25519(alice, qb)
	if !ok || !bytes.Equal(kAB[:], mustHexB(t, rfc7748SharedHex)) {
		t.Fatalf("K(alice,bob) = %x ok=%v", kAB, ok)
	}
	kBA, ok := X25519(bob, qa)
	if !ok || kBA != kAB {
		t.Fatal("K(bob,alice) != K(alice,bob)")
	}
	curve := ecdh.X25519()
	sk, err := curve.NewPrivateKey(alice[:])
	if err != nil {
		t.Fatal(err)
	}
	pk, err := curve.NewPublicKey(qb[:])
	if err != nil {
		t.Fatal(err)
	}
	std, err := sk.ECDH(pk)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(std, kAB[:]) {
		t.Fatal("stdlib ECDH mismatch")
	}
}

func TestX25519Negatives(t *testing.T) {
	alice := mustHex32B(t, rfc7748AliceHex)
	// An all-zero peer point is a small-order input: the shared secret comes
	// out all-zero and MUST be refused (RFC 7748 §6 check).
	var zero [32]byte
	if _, ok := X25519(alice, zero); ok {
		t.Fatal("all-zero point accepted")
	}
	// Point 0x01 (the low-order point that maps to the identity) must also
	// fail closed.
	one := [32]byte{1}
	if _, ok := X25519(alice, one); ok {
		t.Fatal("order-1 point accepted")
	}
	// A different scalar must not collide with the pinned public key.
	other := mustHex32B(t, rfc7748BobHex)
	q, _ := X25519Base(other)
	if bytes.Equal(q[:], mustHexB(t, rfc7748AlicePubHex)) {
		t.Fatal("distinct scalars produced the same public key")
	}
}

func TestMpintTable(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"rfc7748 shared", rfc7748SharedHex, rfc7748MpintHex},
		{"zero", "0000000000000000000000000000000000000000000000000000000000000000", "00000000"},
		{"high bit", "8000000000000000000000000000000000000000000000000000000000000001",
			"0000002100" + "8000000000000000000000000000000000000000000000000000000000000001"},
		{"leading zeros", "000000001234000000000000000000000000000000000000000000000000abcd",
			"0000001c" + "1234000000000000000000000000000000000000000000000000abcd"},
	}
	for _, tc := range cases {
		got := Mpint(mustHexB(t, tc.in))
		if !bytes.Equal(got, mustHexB(t, tc.want)) {
			t.Fatalf("%s: mpint = %x want %s", tc.name, got, tc.want)
		}
	}
}

// ExchangeHash + DeriveKey over the pinned transcript must reproduce the
// Zig/Swift-pinned H and session keys — a known-answer table, not a
// round-trip (the answers come from the VSSH/Zig pin set).
func TestExchangeHashAndDeriveKeyPinned(t *testing.T) {
	kS := mustHexB(t, "0000000b7373682d6564323535313900000020"+rfc8032Test1PubHex)
	h := ExchangeHash(
		[]byte("SSH-2.0-VirelaiOS_1.0"), []byte("SSH-2.0-OpenSSH_9.6"),
		mustHexB(t, pinnedICHex), mustHexB(t, pinnedISHex),
		kS,
		mustHexB(t, rfc7748AlicePubHex), mustHexB(t, rfc7748BobPubHex),
		mustHexB(t, rfc7748MpintHex),
	)
	if !bytes.Equal(h[:], mustHexB(t, pinnedHHex)) {
		t.Fatalf("H = %x want %s", h, pinnedHHex)
	}
	// The host-key signature the Zig kex test pinned (OpenSSL-signed over
	// this exact H) must verify under our Ed25519.
	var sig [64]byte
	copy(sig[:], mustHexB(t, pinnedHostSig))
	if !EdVerify(sig, h[:], mustHex32B(t, rfc8032Test1PubHex)) {
		t.Fatal("pinned host signature rejected")
	}
	kMpint := mustHexB(t, rfc7748MpintHex)
	c2s := DeriveKey(64, kMpint, h[:], 'C', h[:])
	if !bytes.Equal(c2s, mustHexB(t, pinnedKeyC2S)) {
		t.Fatalf("keyC2S = %x", c2s)
	}
	s2c := DeriveKey(64, kMpint, h[:], 'D', h[:])
	if !bytes.Equal(s2c, mustHexB(t, pinnedKeyS2C)) {
		t.Fatalf("keyS2C = %x", s2c)
	}
	// Negatives: any mutated transcript input must not reproduce H or the
	// keys (fail-closed binding, not coincidence).
	badH := ExchangeHash(
		[]byte("SSH-2.0-VirelaiOS_1.0"), []byte("SSH-2.0-OpenSSH_9.7"),
		mustHexB(t, pinnedICHex), mustHexB(t, pinnedISHex),
		kS, mustHexB(t, rfc7748AlicePubHex), mustHexB(t, rfc7748BobPubHex),
		kMpint,
	)
	if badH == h {
		t.Fatal("mutated server version produced the same H")
	}
	if bytes.Equal(DeriveKey(64, kMpint, h[:], 'E', h[:]), c2s) {
		t.Fatal("letter 'E' reproduced the 'C' key")
	}
	if bytes.Equal(DeriveKey(64, kMpint, h[:], 'C', badH[:]), c2s) {
		t.Fatal("different session_id reproduced the 'C' key")
	}
	// Length contract: 16 bytes truncates the first K1 block; 64 bytes used
	// the K1||K2 expansion (already pinned above).
	if got := DeriveKey(16, kMpint, h[:], 'C', h[:]); !bytes.Equal(got, c2s[:16]) {
		t.Fatal("deriveKey(16) is not the 64-byte prefix")
	}
}

func TestSHA256FIPSAndStdlib(t *testing.T) {
	// FIPS 180-4 example vectors.
	if got := SHA256Sum(nil); !bytes.Equal(got[:], mustHexB(t,
		"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")) {
		t.Fatalf("sha256(\"\") = %x", got)
	}
	abc := SHA256Sum([]byte("abc"))
	if !bytes.Equal(abc[:], mustHexB(t,
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")) {
		t.Fatalf("sha256(abc) = %x", abc)
	}
	// Streaming write must equal the one-shot sum for a >64-byte message.
	msg := bytes.Repeat([]byte("VirelaiOS"), 40)
	d := SHA256Init()
	d.write(msg[:100])
	d.write(msg[100:])
	if d.sum() != SHA256Sum(msg) {
		t.Fatal("streaming sum != one-shot")
	}
	if SHA256Sum(msg) != sha256.Sum256(msg) {
		t.Fatal("in-tree sha256 != stdlib")
	}
	// Negative: one-bit change flips the digest.
	if SHA256Sum([]byte("abd")) == abc {
		t.Fatal("distinct messages collided")
	}
}

func TestSHA512FIPSAndStdlib(t *testing.T) {
	if got := sha512Sum([]byte("abc")); !bytes.Equal(got[:], mustHexB(t,
		"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"+
			"2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")) {
		t.Fatalf("sha512(abc) = %x", got)
	}
	if got := sha384Sum([]byte("abc")); !bytes.Equal(got[:], mustHexB(t,
		"cb00753f45a35e8bb5a03d699ac65007272c32ab0eded163"+
			"1a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7")) {
		t.Fatalf("sha384(abc) = %x", got)
	}
	msg := bytes.Repeat([]byte{0x61}, 300)
	if sha512Sum(msg) != sha512.Sum512(msg) {
		t.Fatal("in-tree sha512 != stdlib")
	}
	if sha384Sum(msg) != sha512.Sum384(msg) {
		t.Fatal("in-tree sha384 != stdlib")
	}
	if sha512Sum([]byte("abd")) == sha512Sum([]byte("abc")) {
		t.Fatal("distinct messages collided")
	}
}

// RFC 8032 §7.1 TEST 1/2/3 pinned, cross-checked by crypto/ed25519.
func TestEd25519KnownAnswers(t *testing.T) {
	seed := mustHex32B(t, rfc8032Test1SeedHex)
	pub := EdDerivePublic(seed)
	if !bytes.Equal(pub[:], mustHexB(t, rfc8032Test1PubHex)) {
		t.Fatalf("TEST 1 pub = %x", pub)
	}
	sig := EdSign(nil, seed)
	// TEST 1 signs the empty message to the RFC's signature.
	wantSig := mustHexB(t, "e5564300c360ac729086e2cc806e828a"+
		"84877f1eb8e5d974d873e06522490155"+
		"5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
	if !bytes.Equal(sig[:], wantSig) {
		t.Fatalf("TEST 1 sig = %x", sig)
	}
	if !EdVerify(sig, nil, pub) {
		t.Fatal("TEST 1 self-verify failed")
	}
	std := ed25519.NewKeyFromSeed(seed[:])
	if !ed25519.Verify(std.Public().(ed25519.PublicKey), nil, sig[:]) {
		t.Fatal("stdlib rejected our TEST 1 signature")
	}

	seed2 := mustHex32B(t, "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
	pub2 := EdDerivePublic(seed2)
	if !bytes.Equal(pub2[:], mustHexB(t,
		"3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")) {
		t.Fatalf("TEST 2 pub = %x", pub2)
	}
	sig2 := EdSign([]byte{0x72}, seed2)
	wantSig2 := mustHexB(t, "92a009a9f0d4cab8720e820b5f642540"+
		"a2b27b5416503f8fb3762223ebdb69da"+
		"085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")
	if !bytes.Equal(sig2[:], wantSig2) {
		t.Fatalf("TEST 2 sig = %x", sig2)
	}
	std2 := ed25519.NewKeyFromSeed(seed2[:])
	if !ed25519.Verify(std2.Public().(ed25519.PublicKey), []byte{0x72}, sig2[:]) {
		t.Fatal("stdlib rejected our TEST 2 signature")
	}

	// TEST 3 (1-byte seed) verifies against the RFC's signature.
	seed3 := mustHex32B(t, "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7")
	pub3 := EdDerivePublic(seed3)
	if !bytes.Equal(pub3[:], mustHexB(t,
		"fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025")) {
		t.Fatalf("TEST 3 pub = %x", pub3)
	}
}

func TestEd25519VerifyNegatives(t *testing.T) {
	seed := mustHex32B(t, rfc8032Test1SeedHex)
	pub := EdDerivePublic(seed)
	msg := []byte("host transcript")
	sig := EdSign(msg, seed)

	cases := []struct {
		name string
		sig  [64]byte
		msg  []byte
		pk   [32]byte
	}{
		{"wrong message", sig, []byte("other"), pub},
		{"flipped r byte", flipSig(sig, 0), msg, pub},
		{"flipped s byte", flipSig(sig, 63), msg, pub},
		{"wrong pubkey", sig, msg, mustHex32B(t,
			"3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")},
		{"noncanonical pk", sig, msg, func() [32]byte {
			// y = 2^255-19 (p itself) is non-canonical → decompress refuses.
			var b [32]byte
			for i := range b {
				b[i] = 0xff
			}
			return b
		}()},
	}
	for _, tc := range cases {
		if EdVerify(tc.sig, tc.msg, tc.pk) {
			t.Fatalf("%s verified", tc.name)
		}
	}
	// s >= L is refused: a signature whose second half is 0xff… fails the
	// scalar bound even before the point check.
	var sBig [64]byte
	copy(sBig[:32], sig[:32])
	for i := 32; i < 64; i++ {
		sBig[i] = 0xff
	}
	if EdVerify(sBig, msg, pub) {
		t.Fatal("s >= L verified")
	}
}

func flipSig(sig [64]byte, i int) [64]byte {
	sig[i] ^= 0x01
	return sig
}

func TestHexAndWipe(t *testing.T) {
	b, ok := ParseHex("00ff10")
	if !ok || !bytes.Equal(b, []byte{0, 0xff, 0x10}) {
		t.Fatalf("parse = %x ok=%v", b, ok)
	}
	if EncodeHex([]byte{0, 0xff, 0x10}) != "00ff10" {
		t.Fatal("encodeHex mismatch")
	}
	// Uppercase decodes; encoding is lowercase.
	if b, ok := ParseHex("AABB"); !ok || !bytes.Equal(b, []byte{0xaa, 0xbb}) {
		t.Fatal("uppercase refused")
	}
	for _, bad := range []string{"0", "0g", "zz", "0x"} {
		if _, ok := ParseHex(bad); ok {
			t.Fatalf("ParseHex(%q) accepted", bad)
		}
	}
	if _, ok := ParseHex32("00ff10"); ok {
		t.Fatal("short hex accepted as 32")
	}
	if _, ok := ParseHex32(rfc7748AliceHex + "00"); ok {
		t.Fatal("33-byte hex accepted as 32")
	}
	buf := []byte{1, 2, 3, 4}
	Wipe(buf)
	if !bytes.Equal(buf, []byte{0, 0, 0, 0}) {
		t.Fatalf("wipe left %x", buf)
	}
}
