// Copied into sshd from user/go/tls so GOSSHD.ELF does not link the TLS client.
// X25519 (RFC 7748) — the Montgomery ladder over GF(2^255-19), constant-time
// in the scalar. Field elements are 5 limbs of 51 bits with math/bits 64-bit
// carries; no table lookups touch secret data. Pinned to RFC 7748 §5.2's two
// published vectors and the RFC 8448 §3 shared secret, plus a host-stdlib
// crypto/ecdh cross-check over random keys.
//
// The ladder protects the private key; per ADR 0029's declared limits, other
// verification paths in this package operate on public data and are not
// constant-time.

package ed25519

import "math/bits"

type fe51 [5]uint64

const feMask51 = (1 << 51) - 1

// u128 is a 128-bit accumulator for the limb products.
type u128 struct {
	hi, lo uint64
}

func (a *u128) madd(x, y uint64) {
	h, l := bits.Mul64(x, y)
	lo, c := bits.Add64(a.lo, l, 0)
	a.hi += h
	if c != 0 {
		a.hi++
	}
	a.lo = lo
}

func (a *u128) add64(v uint64) {
	lo, c := bits.Add64(a.lo, v, 0)
	a.lo = lo
	if c != 0 {
		a.hi++
	}
}

// limb51 returns the low 51 bits of the accumulator and shifts it right by 51.
func (a *u128) limb51() uint64 {
	out := a.lo & feMask51
	a.lo = a.lo>>51 | a.hi<<13
	a.hi >>= 51
	return out
}

func feCarryOnce(z *fe51) {
	c := z[0] >> 51
	z[0] &= feMask51
	z[1] += c
}

// feCarry folds limb carries and the 2^255 ≡ 19 wrap.
func feCarry(z *fe51) {
	for i := 0; i < 4; i++ {
		c := z[i] >> 51
		z[i] &= feMask51
		z[i+1] += c
	}
	top := z[4] >> 51
	z[4] &= feMask51
	z[0] += top * 19
	feCarryOnce(z)
}

// feAdd sets z = x + y.
func feAdd(z, x, y *fe51) {
	var c uint64
	z[0], c = bits.Add64(x[0], y[0], 0)
	z[1], c = bits.Add64(x[1], y[1], c)
	z[2], c = bits.Add64(x[2], y[2], c)
	z[3], c = bits.Add64(x[3], y[3], c)
	z[4], _ = bits.Add64(x[4], y[4], c)
	feCarry(z)
}

// feSub sets z = x - y mod p via a 2p bias so no limb underflows (p = 2^255-19
// is {2^51-19, 2^51-1, 2^51-1, 2^51-1, 2^51-1} in radix 2^51).
func feSub(z, x, y *fe51) {
	t := [5]uint64{
		x[0] + 2*(0x7ffffffffffed),
		x[1] + 2*(0x7ffffffffffff),
		x[2] + 2*(0x7ffffffffffff),
		x[3] + 2*(0x7ffffffffffff),
		x[4] + 2*(0x7ffffffffffff),
	}
	var b uint64
	z[0], b = bits.Sub64(t[0], y[0], 0)
	z[1], b = bits.Sub64(t[1], y[1], b)
	z[2], b = bits.Sub64(t[2], y[2], b)
	z[3], b = bits.Sub64(t[3], y[3], b)
	z[4], _ = bits.Sub64(t[4], y[4], b)
	feCarry(z)
}

// feMul sets z = x*y mod p. Inputs must have limbs < 2^54; the output is
// carried to limbs < 2^52.
func feMul(z, x, y *fe51) {
	x0, x1, x2, x3, x4 := x[0], x[1], x[2], x[3], x[4]
	y0, y1, y2, y3, y4 := y[0], y[1], y[2], y[3], y[4]
	x1_19, x2_19 := x1*19, x2*19
	x3_19, x4_19 := x3*19, x4*19

	var t0, t1, t2, t3, t4 u128
	t0.madd(x0, y0)
	t0.madd(x1_19, y4)
	t0.madd(x2_19, y3)
	t0.madd(x3_19, y2)
	t0.madd(x4_19, y1)

	t1.madd(x0, y1)
	t1.madd(x1, y0)
	t1.madd(x2_19, y4)
	t1.madd(x3_19, y3)
	t1.madd(x4_19, y2)

	t2.madd(x0, y2)
	t2.madd(x1, y1)
	t2.madd(x2, y0)
	t2.madd(x3_19, y4)
	t2.madd(x4_19, y3)

	t3.madd(x0, y3)
	t3.madd(x1, y2)
	t3.madd(x2, y1)
	t3.madd(x3, y0)
	t3.madd(x4_19, y4)

	t4.madd(x0, y4)
	t4.madd(x1, y3)
	t4.madd(x2, y2)
	t4.madd(x3, y1)
	t4.madd(x4, y0)

	r0 := t0.limb51()
	t1.add64(t0.lo) // t0's remainder (< 2^77) folds into limb 1's accumulator
	r1 := t1.limb51()
	t2.add64(t1.lo)
	r2 := t2.limb51()
	t3.add64(t2.lo)
	r3 := t3.limb51()
	t4.add64(t3.lo)
	r4 := t4.limb51()

	// Everything above 2^255 folds back with the 2^255 ≡ 19 congruence:
	// V = t4 (u128, < 2^77); V·19 = A + B·2^51 + (V.hi·19)·2^64.
	var v19 u128
	v19.madd(t4.lo, 19)
	v19.hi += t4.hi * 19
	r0 += v19.lo & feMask51
	r1 += v19.lo>>51 | v19.hi<<13

	// Carry the now-64-bit limb sums down to 51 bits.
	c := r0 >> 51
	z0 := r0 & feMask51
	z1 := r1 + c
	c = z1 >> 51
	z1 &= feMask51
	z2 := r2 + c
	c = z2 >> 51
	z2 &= feMask51
	z3 := r3 + c
	c = z3 >> 51
	z3 &= feMask51
	z4 := r4 + c
	c = z4 >> 51
	z4 &= feMask51
	z0 += c * 19
	z[0], z[1], z[2], z[3], z[4] = z0, z1, z2, z3, z4
	feCarryOnce(z)
}

// feSqr sets z = x^2 mod p.
func feSqr(z, x *fe51) { feMul(z, x, x) }

// feMul121666 sets z = x * 121665 (the ladder's a24 constant).
func feMul121666(z, x *fe51) {
	var t0, t1, t2, t3, t4 u128
	t0.madd(x[0], 121665)
	t1.madd(x[1], 121665)
	t2.madd(x[2], 121665)
	t3.madd(x[3], 121665)
	t4.madd(x[4], 121665)

	r0 := t0.limb51()
	r1 := t1.limb51() + t0.lo
	r2 := t2.limb51() + t1.lo
	r3 := t3.limb51() + t2.lo
	r4 := t4.limb51() + t3.lo

	r0 += t4.lo * 19 // each accumulator is < 2^71, so the leftover is tiny

	c := r0 >> 51
	z0 := r0 & feMask51
	z1 := r1 + c
	c = z1 >> 51
	z1 &= feMask51
	z2 := r2 + c
	c = z2 >> 51
	z2 &= feMask51
	z3 := r3 + c
	c = z3 >> 51
	z3 &= feMask51
	z4 := r4 + c
	c = z4 >> 51
	z4 &= feMask51
	z0 += c * 19
	z[0], z[1], z[2], z[3], z[4] = z0, z1, z2, z3, z4
	feCarryOnce(z)
}

// feIsZero is a constant-time zero test.
func feIsZero(x *fe51) bool {
	v := x[0] | x[1] | x[2] | x[3] | x[4]
	return v == 0
}

// feCSwap exchanges x and y if swap is 1, in constant time.
func feCSwap(x, y *fe51, swap uint64) {
	m := ^swap + 1 // 0 when swap == 0, all-ones when swap == 1
	for i := 0; i < 5; i++ {
		t := m & (x[i] ^ y[i])
		x[i] ^= t
		y[i] ^= t
	}
}

// feFromBytes decodes 32 little-endian bytes (top bit masked) into limbs.
func feFromBytes(b *[32]byte) fe51 {
	var v [4]uint64
	for i := 0; i < 4; i++ {
		for j := 0; j < 8; j++ {
			v[i] |= uint64(b[8*i+j]) << (8 * j)
		}
	}
	v[3] &= (1 << 63) - 1
	var f fe51
	f[0] = v[0] & feMask51
	f[1] = (v[0]>>51 | v[1]<<13) & feMask51
	f[2] = (v[1]>>38 | v[2]<<26) & feMask51
	f[3] = (v[2]>>25 | v[3]<<39) & feMask51
	f[4] = (v[3] >> 12) & feMask51
	return f
}

// feCanonical reduces z fully: carries, then fixed conditional subtracts of
// p (constant-time; the count covers the worst-case unreduced magnitude).
func feCanonical(z *fe51) {
	feCarry(z)
	feCarry(z)
	// p = {2^51-19, 2^51-1, 2^51-1, 2^51-1, 2^51-1}
	var p fe51
	p[0] = 0x7ffffffffffed
	p[1], p[2], p[3], p[4] = feMask51, feMask51, feMask51, feMask51
	for i := 0; i < 3; i++ {
		var t fe51
		var b uint64
		t[0], b = bits.Sub64(z[0], p[0], 0)
		t[1], b = bits.Sub64(z[1], p[1], b)
		t[2], b = bits.Sub64(z[2], p[2], b)
		t[3], b = bits.Sub64(z[3], p[3], b)
		t[4], _ = bits.Sub64(z[4], p[4], b)
		m := b - 1 // all-ones when b == 0 (z >= p, subtract), zero when z < p
		for j := 0; j < 5; j++ {
			z[j] ^= m & (z[j] ^ t[j])
		}
	}
	feCarryOnce(z)
}

// feToBytes encodes limbs back to 32 little-endian bytes (fully reduced).
func feToBytes(f *fe51) [32]byte {
	z := *f
	feCanonical(&z)
	var v [4]uint64
	v[0] = z[0] | z[1]<<51
	v[1] = z[1]>>13 | z[2]<<38
	v[2] = z[2]>>26 | z[3]<<25
	v[3] = z[3]>>39 | z[4]<<12
	var out [32]byte
	for i := 0; i < 4; i++ {
		for j := 0; j < 8; j++ {
			out[8*i+j] = byte(v[i] >> (8 * j))
		}
	}
	return out
}

// pMinus2Bits is the exponent p-2 = 2^255-21 as a fixed 255-bit string, MSB
// first (250 ones, then 01011).
const pMinus2Bits = "111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111101011"

// feInvert sets z = x^(p-2) mod p by square-and-multiply over the fixed
// constant exponent (constant-time: the loop is data-independent).
func feInvert(z, x *fe51) {
	var acc fe51
	acc = [5]uint64{1, 0, 0, 0, 0}
	for i := 0; i < len(pMinus2Bits); i++ {
		feSqr(&acc, &acc)
		if pMinus2Bits[i] == '1' {
			feMul(&acc, &acc, x)
		}
	}
	*z = acc
}

// X25519 computes the RFC 7748 scalar multiplication of point by scalar.
// ok is false when the shared secret came out all-zero (a small-order peer
// point); callers must treat that as a failure.
func X25519(scalar, point [32]byte) ([32]byte, bool) {
	// Clamp the scalar (RFC 7748 §5).
	var e [32]byte
	copy(e[:], scalar[:])
	e[0] &= 248
	e[31] &= 127
	e[31] |= 64

	x1 := feFromBytes(&point)
	x2 := fe51{1, 0, 0, 0, 0}
	z2 := fe51{}
	x3 := x1
	z3 := fe51{1, 0, 0, 0, 0}

	swap := uint64(0)
	for t := 254; t >= 0; t-- {
		kt := uint64(e[t/8]>>(uint(t)%8)) & 1
		swap ^= kt
		feCSwap(&x2, &x3, swap)
		feCSwap(&z2, &z3, swap)
		swap = kt

		var a, aa, b, bb, e_, c, d, da, cb fe51
		feAdd(&a, &x2, &z2)
		feSqr(&aa, &a)
		feSub(&b, &x2, &z2)
		feSqr(&bb, &b)
		feSub(&e_, &aa, &bb)
		feAdd(&c, &x3, &z3)
		feSub(&d, &x3, &z3)
		feMul(&da, &d, &a)
		feMul(&cb, &c, &b)

		var t1, t2, t3 fe51
		feAdd(&t1, &da, &cb)
		feSqr(&x3, &t1)
		feSub(&t2, &da, &cb)
		feSqr(&t2, &t2)
		feMul(&z3, &x1, &t2)

		feMul(&x2, &aa, &bb)
		feMul121666(&t3, &e_)
		feAdd(&t3, &aa, &t3)
		feMul(&z2, &e_, &t3)
	}
	feCSwap(&x2, &x3, swap)
	feCSwap(&z2, &z3, swap)

	feInvert(&z2, &z2)
	var out fe51
	feMul(&out, &x2, &z2)
	res := feToBytes(&out)
	// The all-zero test runs on the CANONICAL bytes: an all-zero result can
	// be represented as p in the unreduced limbs.
	var zero [32]byte
	ok := res != zero
	// Wipe the intermediate state.
	for i := range x2 {
		x2[i], z2[i], x3[i], z3[i], out[i] = 0, 0, 0, 0, 0
	}
	return res, ok
}

// X25519Base computes the scalar multiplication with the base point 9.
func X25519Base(scalar [32]byte) ([32]byte, bool) {
	var base [32]byte
	base[0] = 9
	return X25519(scalar, base)
}
