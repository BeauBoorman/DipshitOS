package sshlib

import (
	"bytes"

	"crypto/sha256"
	"testing"
	ved25519 "virelai/ed25519"
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
	if !ved25519.EdVerify(sig, h[:], mustHex32B(t, rfc8032Test1PubHex)) {
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
