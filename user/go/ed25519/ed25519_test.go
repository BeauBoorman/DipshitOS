package ed25519

// The crypto known-answer tests moved with the leaf (M109b, ADR 0052):
// RFC 7748's Alice/Bob vectors, FIPS 180-4 SHA-384/512, and RFC 8032
// §7.1 TEST 1–3 — each still cross-checked against the host stdlib.

import (
	"bytes"
	"crypto/ecdh"
	stded "crypto/ed25519"
	"crypto/sha512"
	"encoding/hex"
	"testing"
)

// The published fixture identities (RFC 8032 §7.1 TEST 1, RFC 7748 §6.1).
const (
	rfc8032Test1SeedHex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
	rfc8032Test1PubHex  = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
	rfc7748AliceHex     = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
	rfc7748AlicePubHex  = "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
	rfc7748BobHex       = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"
	rfc7748BobPubHex    = "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"
	rfc7748SharedHex    = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
)

func mustHexB(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("bad hex %q", s)
	}
	return b
}

func mustHex32B(t *testing.T, s string) [32]byte {
	t.Helper()
	b := mustHexB(t, s)
	if len(b) != 32 {
		t.Fatalf("hex %q is %d bytes, want 32", s, len(b))
	}
	var out [32]byte
	copy(out[:], b)
	return out
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
	std := stded.NewKeyFromSeed(seed[:])
	if !stded.Verify(std.Public().(stded.PublicKey), nil, sig[:]) {
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
	std2 := stded.NewKeyFromSeed(seed2[:])
	if !stded.Verify(std2.Public().(stded.PublicKey), []byte{0x72}, sig2[:]) {
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
