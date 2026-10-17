// Ed25519 (RFC 8032): signing and verification shared by the SSH stack and
// AGENTD's v2 agent handshake (ADR 0052 D2).
//
// GOOS=virelai cannot import crypto/ed25519 (the stdlib crypto tree pulls
// syscall/os) and cannot import math/big (it pulls the host syscall graph).
// Field arithmetic reuses the Curve25519 fe51 limbs in x25519.go. Pinned to
// RFC 8032 §7.1 TEST 1–3.
//
// This package is the leaf ADR 0052 extracts from sshlib (M109b): the
// signature scheme plus the field arithmetic it stands on, without the SSH
// wire/stack an ELF-bounded daemon cannot afford.
package ed25519

import "math/bits"

// Edwards d = -121665/121666 mod p, little-endian.
var (
	edD      fe51
	edTwoD   fe51
	edSqrtM1 fe51
	edL      = [4]uint64{
		0x5812631a5cf5d3ed,
		0x14def9dea2f79cd6,
		0x0000000000000000,
		0x1000000000000000,
	}
)

func init() {
	edD = feFromLEHex("a3785913ca4deb75abd841414d0a700098e879777940c78c73fe6f2bee6c0352")
	edSqrtM1 = feFromLEHex("b0a00e4a271beec478e42fad0618432fa7d7fb3d99004d2b0bdfc14f8024832b")
	feAdd(&edTwoD, &edD, &edD)
}

func feFromLEHex(s string) fe51 {
	b, ok := parseHex(s)
	if !ok || len(b) != 32 {
		panic("ed25519: bad field constant")
	}
	var arr [32]byte
	copy(arr[:], b)
	return feFromBytes(&arr)
}

type edPoint struct {
	X, Y, Z, T fe51
}

func edIdentity() edPoint {
	return edPoint{
		Y: fe51{1, 0, 0, 0, 0},
		Z: fe51{1, 0, 0, 0, 0},
	}
}

func feNeg(z, x *fe51) {
	var zero fe51
	feSub(z, &zero, x)
}

func feIsNegative(x fe51) bool {
	b := feToBytes(&x)
	return b[0]&1 == 1
}

func feEq(a, b fe51) bool {
	ba := feToBytes(&a)
	bb := feToBytes(&b)
	return ba == bb
}

// (p-5)/8 = 2^252 - 3, MSB first (250 ones, then 01).
const pMinus5Over8Bits = "111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111101"

func fePowPMinus5Over8(z, x *fe51) {
	var acc fe51
	acc = fe51{1, 0, 0, 0, 0}
	for i := 0; i < len(pMinus5Over8Bits); i++ {
		feSqr(&acc, &acc)
		if pMinus5Over8Bits[i] == '1' {
			feMul(&acc, &acc, x)
		}
	}
	*z = acc
}

func edAdd(p, q edPoint) edPoint {
	var a, b, c, dd, e, f, g, h, t1, t2, t3, t4, t5, t6 fe51
	feSub(&t1, &p.Y, &p.X)
	feSub(&t2, &q.Y, &q.X)
	feMul(&a, &t1, &t2)
	feAdd(&t3, &p.Y, &p.X)
	feAdd(&t4, &q.Y, &q.X)
	feMul(&b, &t3, &t4)
	feMul(&t5, &p.T, &edTwoD)
	feMul(&c, &t5, &q.T)
	feMul(&t6, &p.Z, &q.Z)
	two := fe51{2, 0, 0, 0, 0}
	feMul(&dd, &t6, &two)
	feSub(&e, &b, &a)
	feSub(&f, &dd, &c)
	feAdd(&g, &dd, &c)
	feAdd(&h, &b, &a)
	var out edPoint
	feMul(&out.X, &e, &f)
	feMul(&out.Y, &g, &h)
	feMul(&out.T, &e, &h)
	feMul(&out.Z, &f, &g)
	return out
}

func edDouble(p edPoint) edPoint {
	var a, b, c, e, f, g, h, t1, t2, t3 fe51
	feSqr(&a, &p.X)
	feSqr(&b, &p.Y)
	feSqr(&t1, &p.Z)
	feAdd(&c, &t1, &t1)
	feAdd(&t2, &a, &b)
	feNeg(&h, &t2)
	feAdd(&t3, &p.X, &p.Y)
	feSqr(&t1, &t3)
	feSub(&t2, &t1, &a)
	feSub(&e, &t2, &b)
	feSub(&g, &b, &a)
	feSub(&f, &g, &c)
	var out edPoint
	feMul(&out.X, &e, &f)
	feMul(&out.Y, &g, &h)
	feMul(&out.T, &e, &h)
	feMul(&out.Z, &f, &g)
	return out
}

func edScalarMult(p edPoint, scalar []byte) edPoint {
	r := edIdentity()
	for i := 255; i >= 0; i-- {
		r = edDouble(r)
		if (scalar[i/8]>>(uint(i)&7))&1 == 1 {
			r = edAdd(r, p)
		}
	}
	return r
}

func edEncode(p edPoint) [32]byte {
	var zinv, x, y fe51
	feInvert(&zinv, &p.Z)
	feMul(&x, &p.X, &zinv)
	feMul(&y, &p.Y, &zinv)
	out := feToBytes(&y)
	if feIsNegative(x) {
		out[31] |= 0x80
	}
	return out
}

func edDecompress(b [32]byte) (edPoint, bool) {
	sign := (b[31] >> 7) & 1
	var yb [32]byte
	copy(yb[:], b[:])
	yb[31] &= 0x7f
	y := feFromBytes(&yb)
	if feToBytes(&y) != yb {
		return edPoint{}, false
	}
	var y2, u, v, v3, v7, uv7, x, vx2, one, negU fe51
	one = fe51{1, 0, 0, 0, 0}
	feSqr(&y2, &y)
	feSub(&u, &y2, &one)
	var dy2 fe51
	feMul(&dy2, &edD, &y2)
	feAdd(&v, &dy2, &one)
	feSqr(&v3, &v)
	feMul(&v3, &v3, &v)
	feSqr(&v7, &v3)
	feMul(&v7, &v7, &v)
	feMul(&uv7, &u, &v7)
	fePowPMinus5Over8(&x, &uv7)
	var uv3 fe51
	feMul(&uv3, &u, &v3)
	feMul(&x, &uv3, &x)
	feSqr(&vx2, &x)
	feMul(&vx2, &v, &vx2)
	if !feEq(vx2, u) {
		feNeg(&negU, &u)
		if !feEq(vx2, negU) {
			return edPoint{}, false
		}
		feMul(&x, &x, &edSqrtM1)
	}
	if feIsZero(&x) && sign == 1 {
		return edPoint{}, false
	}
	if feIsNegative(x) != (sign == 1) {
		feNeg(&x, &x)
	}
	var t fe51
	feMul(&t, &x, &y)
	return edPoint{X: x, Y: y, Z: one, T: t}, true
}

func edBasePoint() edPoint {
	var enc [32]byte
	enc[0] = 0x58
	for i := 1; i < 32; i++ {
		enc[i] = 0x66
	}
	p, ok := edDecompress(enc)
	if !ok {
		panic("ed25519: base point decompress failed")
	}
	return p
}

func clampScalar(h []byte) [32]byte {
	var a [32]byte
	copy(a[:], h[:32])
	a[0] &= 248
	a[31] &= 63
	a[31] |= 64
	return a
}

func u256Gte(a, b [4]uint64) bool {
	for i := 3; i >= 0; i-- {
		if a[i] > b[i] {
			return true
		}
		if a[i] < b[i] {
			return false
		}
	}
	return true
}

func u256Sub(a, b [4]uint64) [4]uint64 {
	var out [4]uint64
	var borrow uint64
	for i := 0; i < 4; i++ {
		out[i], borrow = bits.Sub64(a[i], b[i], borrow)
	}
	return out
}

func bytesToU256(b []byte) [4]uint64 {
	var w [4]uint64
	for i := 0; i < 4; i++ {
		off := i * 8
		w[i] = uint64(b[off]) | uint64(b[off+1])<<8 | uint64(b[off+2])<<16 | uint64(b[off+3])<<24 |
			uint64(b[off+4])<<32 | uint64(b[off+5])<<40 | uint64(b[off+6])<<48 | uint64(b[off+7])<<56
	}
	return w
}

func u256ToBytes(w [4]uint64) [32]byte {
	var out [32]byte
	for i := 0; i < 4; i++ {
		v := w[i]
		off := i * 8
		for j := 0; j < 8; j++ {
			out[off+j] = byte(v >> (8 * j))
		}
	}
	return out
}

func bit512(x [8]uint64, i int) uint64 {
	return (x[i/64] >> (uint(i) % 64)) & 1
}

func modL512(x [8]uint64) [4]uint64 {
	var rem [4]uint64
	for i := 511; i >= 0; i-- {
		c := bit512(x, i)
		for j := 0; j < 4; j++ {
			n := rem[j]<<1 | c
			c = rem[j] >> 63
			rem[j] = n
		}
		if u256Gte(rem, edL) {
			rem = u256Sub(rem, edL)
		}
	}
	return rem
}

func modL(b []byte) [32]byte {
	var x [8]uint64
	n := len(b)
	if n > 64 {
		n = 64
	}
	for i := 0; i < n; i++ {
		x[i/8] |= uint64(b[i]) << (8 * (i % 8))
	}
	return u256ToBytes(modL512(x))
}

func mul256(a, b [4]uint64) [8]uint64 {
	var r [8]uint64
	for i := 0; i < 4; i++ {
		var carry uint64
		for j := 0; j < 4; j++ {
			hi, lo := bits.Mul64(a[i], b[j])
			s, c1 := bits.Add64(r[i+j], lo, 0)
			s, c2 := bits.Add64(s, carry, 0)
			r[i+j] = s
			carry = hi + c1 + c2
		}
		k := i + 4
		for carry != 0 && k < 8 {
			s, c := bits.Add64(r[k], carry, 0)
			r[k] = s
			carry = c
			k++
		}
	}
	return r
}

func add256to512(x [8]uint64, y [4]uint64) [8]uint64 {
	var c uint64
	for i := 0; i < 4; i++ {
		x[i], c = bits.Add64(x[i], y[i], c)
	}
	for i := 4; c != 0 && i < 8; i++ {
		x[i], c = bits.Add64(x[i], 0, c)
	}
	return x
}

func EdDerivePublic(seed [32]byte) [32]byte {
	h := sha512Sum(seed[:])
	a := clampScalar(h[:])
	return edEncode(edScalarMult(edBasePoint(), a[:]))
}

func EdSign(msg []byte, seed [32]byte) [64]byte {
	h := sha512Sum(seed[:])
	a := clampScalar(h[:])
	bp := edBasePoint()
	pk := edEncode(edScalarMult(bp, a[:]))

	nonceH := sha512Init()
	nonceH.write(h[32:64])
	nonceH.write(msg)
	nh := nonceH.sum64()
	rBytes := modL(nh[:])
	rEnc := edEncode(edScalarMult(bp, rBytes[:]))

	kH := sha512Init()
	kH.write(rEnc[:])
	kH.write(pk[:])
	kH.write(msg)
	kh := kH.sum64()
	kBytes := modL(kh[:])

	prod := mul256(bytesToU256(kBytes[:]), bytesToU256(a[:]))
	prod = add256to512(prod, bytesToU256(rBytes[:]))
	sBytes := u256ToBytes(modL512(prod))

	var sig [64]byte
	copy(sig[:32], rEnc[:])
	copy(sig[32:], sBytes[:])
	wipe(h[:])
	wipe(a[:])
	wipe(rBytes[:])
	wipe(kBytes[:])
	return sig
}

func EdVerify(sig [64]byte, msg []byte, pk [32]byte) bool {
	aPoint, ok := edDecompress(pk)
	if !ok {
		return false
	}
	var rBytes [32]byte
	copy(rBytes[:], sig[:32])
	rPoint, ok := edDecompress(rBytes)
	if !ok {
		return false
	}
	var sBytes [32]byte
	copy(sBytes[:], sig[32:])
	s := bytesToU256(sBytes[:])
	if u256Gte(s, edL) {
		return false
	}
	kH := sha512Init()
	kH.write(rBytes[:])
	kH.write(pk[:])
	kH.write(msg)
	kh := kH.sum64()
	kBytes := modL(kh[:])
	sb := edScalarMult(edBasePoint(), sBytes[:])
	ka := edScalarMult(aPoint, kBytes[:])
	rhs := edAdd(rPoint, ka)
	return edEncode(sb) == edEncode(rhs)
}
