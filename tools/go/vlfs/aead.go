package main

import (
	"encoding/binary"
	"math/big"
)

// ChaCha20-Poly1305 AEAD (RFC 8439 §2.8), M172c, ADR 0061 D9.
//
// Host-side port of kernel/src/aead.zig — which is itself the kernel-local
// port of user/src/lib/crypto/aead.zig — carried here because ChaCha20-
// Poly1305 is not in Go's standard library and the module must stay
// stdlib-only. The construction is identical: the Poly1305 one-time key is
// the first 32 bytes of the ChaCha20 block at counter 0; the ciphertext is
// ChaCha20 with counter 1; the tag authenticates AAD‖pad‖ciphertext‖pad‖
// len(AAD)‖len(ciphertext) (all little-endian, padded to 16). aeadOpen
// compares the tag with a no-early-exit scan and refuses before decrypting.
//
// The same three RFC 8439 vectors pin this port and both Zig copies
// (drift guard): §2.3.2 block function, §2.5.2 Poly1305, §2.8.2 AEAD.

const (
	aeadKeyLen   = 32
	aeadNonceLen = 12
	aeadTagLen   = 16
	chachaBlock  = 64
)

// RFC 8439 §2.3 constants: "expa" "nd 3" "2-by" "te k".
var chachaConstants = [4]uint32{0x61707865, 0x3320646e, 0x79622d32, 0x6b206574}

func rotl32(x uint32, n uint) uint32 { return x<<n | x>>(32-n) }

// RFC 8439 §2.1 quarter round over four state words addressed by index.
func quarterRound(state *[16]uint32, a, b, c, d int) {
	state[a] += state[b]
	state[d] = rotl32(state[d]^state[a], 16)
	state[c] += state[d]
	state[b] = rotl32(state[b]^state[c], 12)
	state[a] += state[b]
	state[d] = rotl32(state[d]^state[a], 8)
	state[c] += state[d]
	state[b] = rotl32(state[b]^state[c], 7)
}

// RFC 8439 §2.3.1/§2.3.2: one 64-byte ChaCha20 block. counter is the
// 32-bit block count (state word 12); nonce is 12 bytes (words 13–15).
func chacha20Block(key *[aeadKeyLen]byte, counter uint32, nonce *[aeadNonceLen]byte, out *[chachaBlock]byte) {
	var state [16]uint32
	copy(state[:4], chachaConstants[:])
	for i := 0; i < 8; i++ {
		state[4+i] = binary.LittleEndian.Uint32(key[i*4:])
	}
	state[12] = counter
	for j := 0; j < 3; j++ {
		state[13+j] = binary.LittleEndian.Uint32(nonce[j*4:])
	}
	working := state
	for r := 0; r < 10; r++ {
		quarterRound(&working, 0, 4, 8, 12)
		quarterRound(&working, 1, 5, 9, 13)
		quarterRound(&working, 2, 6, 10, 14)
		quarterRound(&working, 3, 7, 11, 15)
		quarterRound(&working, 0, 5, 10, 15)
		quarterRound(&working, 1, 6, 11, 12)
		quarterRound(&working, 2, 7, 8, 13)
		quarterRound(&working, 3, 4, 9, 14)
	}
	for k := 0; k < 16; k++ {
		binary.LittleEndian.PutUint32(out[k*4:], working[k]+state[k])
	}
}

// chacha20XOR XORs in with the ChaCha20 keystream starting at block
// counter. out and in may alias.
func chacha20XOR(out, in []byte, key *[aeadKeyLen]byte, counter uint32, nonce *[aeadNonceLen]byte) {
	var ks [chachaBlock]byte
	ctr := counter
	for off := 0; off < len(in); {
		chacha20Block(key, ctr, nonce, &ks)
		ctr++
		take := min(chachaBlock, len(in)-off)
		for i := 0; i < take; i++ {
			out[off+i] = in[off+i] ^ ks[i]
		}
		off += take
	}
}

// ---------------------------------------------------------------------------
// Poly1305 (RFC 8439 §2.5) — math/big stands in for the Zig port's u256/u512
// limb arithmetic; the reduction is the same fold-by-5 over p = 2^130 - 5.
// ---------------------------------------------------------------------------

var poly1305P = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 130), big.NewInt(5))

type poly1305 struct {
	r, s   *big.Int
	acc    *big.Int
	buf    [16]byte
	bufLen int
}

func poly1305Init(key *[32]byte) *poly1305 {
	var rb [16]byte
	copy(rb[:], key[:16])
	rb[3] &= 15
	rb[7] &= 15
	rb[11] &= 15
	rb[15] &= 15
	rb[4] &= 252
	rb[8] &= 252
	rb[12] &= 252
	r := new(big.Int).SetBytes(reverse(rb[:]))
	s := new(big.Int).SetBytes(reverse(key[16:32]))
	return &poly1305{r: r, s: s, acc: new(big.Int)}
}

// reverse converts a little-endian byte string to big-endian for big.Int.
func reverse(b []byte) []byte {
	out := make([]byte, len(b))
	for i, c := range b {
		out[len(b)-1-i] = c
	}
	return out
}

// absorb folds one block of nbytes (≤16) into the accumulator:
// acc = (acc + n·2^(8n) term) · r mod p, where the block's high bit is
// appended at position nbytes per RFC 8439 §2.5.1.
func (p *poly1305) absorb(blk []byte) {
	n := new(big.Int).SetBytes(reverse(blk))
	n.SetBit(n, 8*len(blk), 1)
	p.acc.Add(p.acc, n)
	p.acc.Mul(p.acc, p.r)
	p.acc.Mod(p.acc, poly1305P)
}

func (p *poly1305) update(b []byte) {
	i := 0
	if p.bufLen != 0 {
		take := min(16-p.bufLen, len(b))
		copy(p.buf[p.bufLen:], b[:take])
		p.bufLen += take
		i += take
		if p.bufLen == 16 {
			p.absorb(p.buf[:])
			p.bufLen = 0
		}
	}
	for i+16 <= len(b) {
		p.absorb(b[i : i+16])
		i += 16
	}
	if i < len(b) {
		p.bufLen = copy(p.buf[:], b[i:])
	}
}

func (p *poly1305) final(out *[16]byte) {
	if p.bufLen != 0 {
		p.absorb(p.buf[:p.bufLen])
		p.bufLen = 0
	}
	sum := new(big.Int).Add(p.acc, p.s)
	// Low 128 bits only (the tag) — the Zig port's @truncate(sum >> 8i).
	mask := new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 128), big.NewInt(1))
	be := sum.And(sum, mask).Bytes() // big-endian
	for i := 0; i < 16; i++ {
		out[i] = 0
	}
	for i, c := range be {
		out[15-i] = c // little-endian store
	}
}

// ---------------------------------------------------------------------------
// The AEAD (RFC 8439 §2.8)
// ---------------------------------------------------------------------------

func aeadPadLen(n int) int { return (16 - n&15) & 15 }

// aeadMAC tags AAD‖pad‖ciphertext‖pad‖len(AAD)‖len(ciphertext) — RFC §2.8.
func aeadMAC(tag *[aeadTagLen]byte, ciphertext, aad []byte, pkey *[32]byte) {
	p := poly1305Init(pkey)
	zeros := [16]byte{}
	p.update(aad)
	p.update(zeros[:aeadPadLen(len(aad))])
	p.update(ciphertext)
	p.update(zeros[:aeadPadLen(len(ciphertext))])
	var lens [16]byte
	binary.LittleEndian.PutUint64(lens[0:8], uint64(len(aad)))
	binary.LittleEndian.PutUint64(lens[8:16], uint64(len(ciphertext)))
	p.update(lens[:])
	p.final(tag)
}

// ctEq compares equal-length byte strings with no early exit. Lengths are
// public by contract (ADR 0023 D3 — same posture as the kernel port).
func ctEq(a, b []byte) bool {
	diff := byte(0)
	n := min(len(a), len(b))
	for i := 0; i < n; i++ {
		diff |= a[i] ^ b[i]
	}
	if len(a) != len(b) {
		diff = 1
	}
	return diff == 0
}

// aeadSeal encrypts pt into ciphertext (same length) and produces the
// 16-byte tag. RFC 8439 §2.8.
func aeadSeal(ciphertext []byte, tag *[aeadTagLen]byte, pt, aad []byte, nonce *[aeadNonceLen]byte, key *[aeadKeyLen]byte) {
	var first [chachaBlock]byte
	chacha20Block(key, 0, nonce, &first)
	var pkey [32]byte
	copy(pkey[:], first[:32])
	chacha20XOR(ciphertext, pt, key, 1, nonce)
	aeadMAC(tag, ciphertext, aad, &pkey)
}

// aeadOpen authenticates then decrypts. Returns false (and leaves pt
// untouched) when the tag does not match. Constant-time tag comparison.
func aeadOpen(pt, ciphertext []byte, tag *[aeadTagLen]byte, aad []byte, nonce *[aeadNonceLen]byte, key *[aeadKeyLen]byte) bool {
	var first [chachaBlock]byte
	chacha20Block(key, 0, nonce, &first)
	var pkey [32]byte
	copy(pkey[:], first[:32])
	var expected [aeadTagLen]byte
	aeadMAC(&expected, ciphertext, aad, &pkey)
	if !ctEq(expected[:], tag[:]) {
		return false
	}
	chacha20XOR(pt, ciphertext, key, 1, nonce)
	return true
}
