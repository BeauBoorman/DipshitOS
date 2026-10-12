package sshlib

import (
	"bytes"
	"testing"
)

// RFC 4253 §6 / ADR 0025 D4: plaintext packets align (4 + packet_length) to
// the 8-byte block; the OpenSSH AEAD aligns packet_length itself (#1210).

func TestPaddingLenTable(t *testing.T) {
	cases := []struct {
		payloadLen int
		align      PktAlign
		want       int
	}{
		{0, AlignPlain, 11},  // 4+1 → pad 11 makes 4+1+11=16
		{1, AlignPlain, 10},  // NEWKEYS: total 16
		{65, AlignAEAD, 6},   // #1210: packet_length 72 % 8 == 0; the plain rule would reject it
		{65, AlignPlain, 10}, // 4+1+65=70 → pad 2 < min → 10 (total 80)
		{8, AlignAEAD, 7},    // 1+8+7 = 16
		{7, AlignPlain, 4},   // 4+1+7+4 = 16
	}
	for _, tc := range cases {
		if got := PaddingLen(tc.payloadLen, tc.align); got != tc.want {
			t.Fatalf("PaddingLen(%d,%d) = %d want %d", tc.payloadLen, tc.align, got, tc.want)
		}
	}
}

func TestPktAlignedTable(t *testing.T) {
	cases := []struct {
		packetLength uint32
		align        PktAlign
		want         bool
	}{
		{12, AlignPlain, true},  // NEWKEYS frame: 4+12=16
		{72, AlignAEAD, true},   // the #1210 OpenSSH frame
		{72, AlignPlain, false}, // 76 % 8 != 0 — the plaintext rule refuses it
		{16, AlignPlain, false}, // 4+16=20 % 8 != 0
		{16, AlignAEAD, true},
		{20, AlignPlain, true}, // 24 % 8 == 0
		{20, AlignAEAD, false},
	}
	for _, tc := range cases {
		if got := PktAligned(tc.packetLength, tc.align); got != tc.want {
			t.Fatalf("PktAligned(%d,%d) = %v want %v", tc.packetLength, tc.align, got, tc.want)
		}
	}
}

// Pinned minimal frame: payload {0x15} (NEWKEYS), pad 10 × 0x5a → the exact
// 16 bytes the client must emit.
func TestEncodePacketPinned(t *testing.T) {
	pad := bytes.Repeat([]byte{0x5a}, PaddingLen(1, AlignPlain))
	frame, ok := EncodePacket([]byte{MsgNewKeys}, pad, AlignPlain)
	if !ok {
		t.Fatal("encode NEWKEYS refused")
	}
	want := append([]byte{0x00, 0x00, 0x00, 0x0c, byte(len(pad)), MsgNewKeys}, pad...)
	if !bytes.Equal(frame, want) {
		t.Fatalf("frame = %x want %x", frame, want)
	}
	payload, ok := DecodePacket(frame, AlignPlain)
	if !ok || !bytes.Equal(payload, []byte{MsgNewKeys}) {
		t.Fatalf("decode = %x ok=%v", payload, ok)
	}
}

func TestEncodePacketNegatives(t *testing.T) {
	// Pad shorter than the required minimum is refused.
	if _, ok := EncodePacket([]byte{1}, nil, AlignPlain); ok {
		t.Fatal("short pad accepted")
	}
	// A pad that is not min + k*8 is refused.
	if _, ok := EncodePacket([]byte{1}, bytes.Repeat([]byte{0}, 11), AlignPlain); ok {
		t.Fatal("misaligned pad accepted")
	}
	// Pad may legally exceed the minimum by whole blocks.
	min := PaddingLen(1, AlignPlain)
	if _, ok := EncodePacket([]byte{1}, make([]byte, min+8), AlignPlain); !ok {
		t.Fatal("min+8 pad refused")
	}
	// Oversized total is refused: force packet_length over the cap with a
	// giant payload.
	if _, ok := EncodePacket(make([]byte, PktMaxTotal), make([]byte, 16), AlignAEAD); ok {
		t.Fatal("oversized packet accepted")
	}
	// An AEAD-aligned pad fails the plaintext rule and vice versa.
	if _, ok := EncodePacket([]byte{1}, make([]byte, min), AlignAEAD); ok {
		t.Fatal("plaintext pad reused under AEAD align accepted? check")
	}
}

func TestDecodePacketNegatives(t *testing.T) {
	good, ok := EncodePacket([]byte{MsgNewKeys}, bytes.Repeat([]byte{0x5a}, PaddingLen(1, AlignPlain)), AlignPlain)
	if !ok {
		t.Fatal("setup encode failed")
	}
	// frame builds a well-aligned 16-byte plaintext frame carrying `pad`
	// declared padding bytes — used to isolate the padding bound checks.
	frame := func(packetLen, pad byte) []byte {
		f := make([]byte, 16)
		f[3] = packetLen
		f[4] = pad
		return f
	}
	cases := []struct {
		name  string
		frame []byte
		align PktAlign
	}{
		{"empty", nil, AlignPlain},
		{"header only", []byte{0, 0, 0, 8}, AlignPlain},
		{"len too small", []byte{0, 0, 0, 4, 0, 0, 0, 0, 0}, AlignPlain}, // pl=4 < 1+minpad
		{"oversized", append([]byte{0xff, 0xff, 0xff, 0xff}, good[4:]...), AlignPlain},
		{"declared over cap", func() []byte {
			// packet_length = PktMaxTotal-3 > PktMaxTotal-4 → refused before
			// the frame-length check is even reached.
			f := make([]byte, 5)
			pl := uint32(PktMaxTotal - 3)
			f[0], f[1], f[2], f[3] = byte(pl>>24), byte(pl>>16), byte(pl>>8), byte(pl)
			return f
		}(), AlignPlain},
		{"pad below min", frame(12, 3), AlignPlain},    // padding=3 < 4
		{"pad exceeds len", frame(12, 12), AlignPlain}, // padding=12 > pl-1=11
		{"misaligned plain", func() []byte {
			// packet_length 16 is AEAD-aligned but not (4+16)%8 plaintext.
			f := make([]byte, 20)
			f[3] = 16
			f[4] = 11 // padding=11, payload=4
			return f
		}(), AlignPlain},
		{"misaligned aead", func() []byte {
			f := append([]byte(nil), good...)
			return f
		}(), AlignAEAD}, // packet_length 12 % 8 != 0
		{"truncated", good[:len(good)-1], AlignPlain},
		{"trailing byte", append(append([]byte(nil), good...), 0x00), AlignPlain},
	}
	for _, tc := range cases {
		if payload, ok := DecodePacket(tc.frame, tc.align); ok {
			t.Fatalf("%s: frame %x decoded to %x", tc.name, tc.frame, payload)
		}
	}
	// The same bytes that fail one rule pass the other — pin the #1210 split.
	aead, ok := EncodePacket(bytes.Repeat([]byte{0x41}, 65), bytes.Repeat([]byte{0x5a}, PaddingLen(65, AlignAEAD)), AlignAEAD)
	if !ok {
		t.Fatal("aead encode failed")
	}
	if _, ok := DecodePacket(aead, AlignAEAD); !ok {
		t.Fatal("aead frame refused under aead rule")
	}
	if _, ok := DecodePacket(aead, AlignPlain); ok {
		t.Fatal("aead-aligned frame accepted under plaintext rule")
	}
}

// --- cipher primitives: the same vectors Zig ssh_cipher.zig and Swift
// VSSHTests pin (ADR 0025 D4/D8 drift guard). ---

func TestChaChaBlockPinned(t *testing.T) {
	var key [32]byte
	var nonce [8]byte
	cases := []struct {
		counter uint64
		want    string
	}{
		{0, "76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7" +
			"da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586"},
		{1, "9f07e7be5551387a98ba977c732d080dcb0f29a048e3656912c6533e32ee7aed" +
			"29b721769ce64e43d57133b074d839d531ed1f28510afb45ace10a1f4b794d6f"},
		{2, "2d09a0e663266ce1ae7ed1081968a0758e718e997bd362c6b0c34634a9a0b35d" +
			"012737681f7b5d0f281e3afde458bc1e73d2d313c9cf94c05ff3716240a248f2"},
	}
	for _, tc := range cases {
		got := ChaChaBlock(key[:], tc.counter, nonce[:])
		if !bytes.Equal(got[:], mustHexB(t, tc.want)) {
			t.Fatalf("block(%d) = %x", tc.counter, got)
		}
	}
	// Negative: a different key must not produce the zero-key block.
	other := ChaChaBlock(bytes.Repeat([]byte{1}, 32), 0, nonce[:])
	if other == ChaChaBlock(key[:], 0, nonce[:]) {
		t.Fatal("different key produced zero-key block")
	}
}

func TestPoly1305RFC8439(t *testing.T) {
	key := mustHexB(t, "85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
	tag := Poly1305Tag([]byte("Cryptographic Forum Research Group"), key)
	want := mustHexB(t, "a8061dc1305136c6c22b8baf0c0127a9")
	if !bytes.Equal(tag[:], want) {
		t.Fatalf("tag = %x want %x", tag, want)
	}
	// Negative: one-bit message change must change the tag.
	bad := Poly1305Tag([]byte("Cryptographic Forum Research Grouq"), key)
	if bad == tag {
		t.Fatal("tampered message produced the same tag")
	}
}

// draft-ietf-sshm-chacha20-poly1305-04 appendix A / OpenSSH
// PROTOCOL.chacha20poly1305 — seq 7.
func TestCipherOpenSSHVector(t *testing.T) {
	key := mustHexB(t, "8bbff6855fc102338c373e73aac0c914"+
		"f076a905b2444a32eecaffeae22becc5"+
		"e9b7a7a5825a8249346ec1c28301cf39"+
		"4543fc7569887d76e168f37562ac0740")
	plain := mustHexB(t, "00000048065e00000000000000384c6f"+
		"72656d20697073756d20646f6c6f7220"+
		"73697420616d65742c20636f6e736563"+
		"7465747572206164697069736963696e"+
		"6720656c69744e43e804dc6c")
	wantCT := mustHexB(t, "2c3ecce4a5bc05895bf07a7ba956b6c6"+
		"8829ac7c83b780b7000ecde745afc705"+
		"bbc378ce03a280236b87b53bed583966"+
		"2302b164b6286a48cd1e097138e3cb90"+
		"9b8b2b829dd18d2a35ff82d9")
	wantTag := mustHexB(t, "95349e855bf02c298ef775f2d1a7e8b8")
	var c Cipher
	copy(c.Key[:], key)
	ct, tag := c.Seal(plain, 7)
	if !bytes.Equal(ct, wantCT) {
		t.Fatalf("ct =\n%x\nwant\n%x", ct, wantCT)
	}
	if !bytes.Equal(tag, wantTag) {
		t.Fatalf("tag = %x want %x", tag, wantTag)
	}
	if got := c.DecryptLength(ct[:4], 7); got != 0x48 {
		t.Fatalf("decryptLength = %d want 0x48", got)
	}
	if got := c.Open(ct, tag, 7); !bytes.Equal(got, plain) {
		t.Fatal("open round-trip mismatch")
	}
}

// Zero-key seq 0 pins the split-key construction: the Poly key derivation
// yields the RFC 8439 A.1 zero block.
func TestCipherZeroKeySplitConstruction(t *testing.T) {
	var c Cipher
	plain := mustHexB(t, "0000000401aabbcc")
	ct, tag := c.Seal(plain, 0)
	if !bytes.Equal(ct, mustHexB(t, "76b8e0a99ead5c72")) {
		t.Fatalf("ct = %x", ct)
	}
	if !bytes.Equal(tag, mustHexB(t, "eff46ab54f68eb25915e3dc319448e9c")) {
		t.Fatalf("tag = %x", tag)
	}
	if c.DecryptLength(ct[:4], 0) != 4 {
		t.Fatal("decryptLength != 4")
	}
}

// key = 00..3f pins the half boundary: K_2 = key[0:32] seals payload + Poly,
// K_1 = key[32:64] seals the length (OpenSSH order, NOT the inverted draft).
func TestCipherSplitKeyBoundary(t *testing.T) {
	var c Cipher
	for i := range c.Key {
		c.Key[i] = byte(i)
	}
	plain := mustHexB(t, "0000000401aabbcc")
	ct, tag := c.Seal(plain, 0)
	if !bytes.Equal(ct, mustHexB(t, "94450e5d1912f9fd")) {
		t.Fatalf("ct = %x", ct)
	}
	if !bytes.Equal(tag, mustHexB(t, "330dd5eb4e87ecfdf3d3d467034a83cb")) {
		t.Fatalf("tag = %x", tag)
	}
	// Swapping the halves must not authenticate.
	var swapped Cipher
	copy(swapped.Key[0:32], c.Key[32:64])
	copy(swapped.Key[32:64], c.Key[0:32])
	if swapped.Open(ct, tag, 0) != nil {
		t.Fatal("half-swapped key opened the packet")
	}
}

// Packet-codec negatives at the AEAD layer: each is a distinct refusal —
// tampered tag, tampered ciphertext, tampered encrypted length, wrong
// sequence (out-of-window), truncated input — never a plaintext return.
func TestCipherOpenNegatives(t *testing.T) {
	var c Cipher
	for i := range c.Key {
		c.Key[i] = byte(i * 3)
	}
	plain := mustHexB(t, "0000000c0b1500000000000000000000000000")
	ct, tag := c.Seal(plain, 3)
	cases := []struct {
		name string
		ct   []byte
		tag  []byte
		seq  uint64
	}{
		{"tag bit 0", ct, flip(tag, 0, 0x01), 3},
		{"tag last bit", ct, flip(tag, 15, 0x80), 3},
		{"ct payload bit", flip(ct, len(ct)-1, 0x01), tag, 3},
		{"ct length bit", flip(ct, 0, 0x01), tag, 3},
		{"wrong seq", ct, tag, 2},
		{"future seq", ct, tag, 7},
		{"short ct", ct[:3], tag, 3},
		{"short tag", ct, tag[:8], 3},
		{"empty", nil, tag, 3},
	}
	for _, tc := range cases {
		if got := c.Open(tc.ct, tc.tag, tc.seq); got != nil {
			t.Fatalf("%s: opened to %x", tc.name, got)
		}
	}
	// Sequence binding holds for the length half too.
	if c.DecryptLength(ct[:4], 4) == c.DecryptLength(ct[:4], 3) {
		t.Fatal("decryptLength ignored the sequence number")
	}
}

func flip(b []byte, i int, v byte) []byte {
	out := append([]byte(nil), b...)
	out[i] ^= v
	return out
}
