package main

// A small SHA-256 (FIPS 180-4) for the fleet manifest — crypto/sha256 is
// not in the staged-archive allowlist (tools/go/pkg-table.txt), so the
// driver cannot import it; the manifest's contract names sha256, so the
// primitive lives here. Verified against the published test vectors in
// fleet_test.go.

var sha256K = [64]uint32{
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

type sha256State struct {
	h   [8]uint32
	buf [64]byte
	n   int    // bytes buffered
	len uint64 // total message bytes
}

func sha256New() *sha256State {
	return &sha256State{h: [8]uint32{
		0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
		0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
	}}
}

func rotr(x uint32, n uint) uint32 { return x>>n | x<<(32-n) }

func (s *sha256State) block(p []byte) {
	var w [64]uint32
	for i := 0; i < 16; i++ {
		w[i] = uint32(p[4*i])<<24 | uint32(p[4*i+1])<<16 |
			uint32(p[4*i+2])<<8 | uint32(p[4*i+3])
	}
	for i := 16; i < 64; i++ {
		s0 := rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)
		s1 := rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)
		w[i] = w[i-16] + s0 + w[i-7] + s1
	}
	a, b, c, d, e, f, g, h := s.h[0], s.h[1], s.h[2], s.h[3], s.h[4], s.h[5], s.h[6], s.h[7]
	for i := 0; i < 64; i++ {
		S1 := rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
		ch := (e & f) ^ (^e & g)
		t1 := h + S1 + ch + sha256K[i] + w[i]
		S0 := rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
		maj := (a & b) ^ (a & c) ^ (b & c)
		t2 := S0 + maj
		h, g, f, e, d, c, b, a = g, f, e, d+t1, c, b, a, t1+t2
	}
	s.h[0] += a
	s.h[1] += b
	s.h[2] += c
	s.h[3] += d
	s.h[4] += e
	s.h[5] += f
	s.h[6] += g
	s.h[7] += h
}

func (s *sha256State) Write(p []byte) {
	s.len += uint64(len(p))
	for len(p) > 0 {
		n := 64 - s.n
		if n > len(p) {
			n = len(p)
		}
		copy(s.buf[s.n:], p[:n])
		s.n += n
		p = p[n:]
		if s.n == 64 {
			s.block(s.buf[:])
			s.n = 0
		}
	}
}

func (s *sha256State) Sum() [32]byte {
	// Pad: 0x80, zeros to 56 mod 64, then the 64-bit big-endian bit length.
	bitlen := s.len * 8
	s.Write([]byte{0x80})
	for s.n != 56 {
		s.Write([]byte{0})
	}
	var lb [8]byte
	for i := 0; i < 8; i++ {
		lb[7-i] = byte(bitlen >> (8 * i))
	}
	s.Write(lb[:])
	var out [32]byte
	for i, v := range s.h {
		out[4*i] = byte(v >> 24)
		out[4*i+1] = byte(v >> 16)
		out[4*i+2] = byte(v >> 8)
		out[4*i+3] = byte(v)
	}
	return out
}

var sha256Hex = "0123456789abcdef"

func sha256HexOf(b []byte) string {
	var st = sha256New()
	st.Write(b)
	sum := st.Sum()
	out := make([]byte, 64)
	for i, v := range sum {
		out[2*i] = sha256Hex[v>>4]
		out[2*i+1] = sha256Hex[v&15]
	}
	return string(out)
}

// sha256File hashes a share file; ok=false when it cannot be read.
func sha256File(path string) (string, bool) {
	b, err := readFile(path)
	if err != nil {
		return "", false
	}
	return sha256HexOf(b), true
}
