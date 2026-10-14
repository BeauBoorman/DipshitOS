package main

import (
	"encoding/hex"
	"strings"

	"virelai/vi"
)

// UUIDGen mints RFC 9562 UUIDv7 identifiers with a 48-bit millisecond
// timestamp (`Now()*1000`), version 7, a 12-bit monotonic counter in rand_a
// (§6.2 method 1), variant `10`, and 62 random bits.
type UUIDGen struct {
	now    func() int64
	rand   func([]byte) error
	lastMs int64
	seq    uint16
}

func newUUIDGen(now func() int64, rand func([]byte) error) *UUIDGen {
	return &UUIDGen{
		now:    now,
		rand:   rand,
		lastMs: -1,
	}
}

func guestRandom(b []byte) error {
	_, err := vi.Random(b)
	return err
}

var defaultUUIDGen = newUUIDGen(vi.Now, guestRandom)

// NowMs returns the current Unix timestamp in milliseconds (`Now()*1000`),
// or refuses with `clock_unset` when `Now() < 0`.
func (g *UUIDGen) NowMs() (int64, error) {
	sec := g.now()
	if sec < 0 {
		return 0, refuse("clock_unset", "")
	}
	return sec * 1000, nil
}

// NewBytes mints a 16-byte RFC 9562 UUIDv7.
func (g *UUIDGen) NewBytes() ([16]byte, error) {
	var u [16]byte
	ms, err := g.NowMs()
	if err != nil {
		return u, err
	}
	if ms > g.lastMs {
		g.lastMs = ms
		g.seq = 0
	} else {
		g.seq++
		if g.seq > 0x0fff {
			g.seq = 0
			g.lastMs++
		}
	}
	var rnd [8]byte
	if err := g.rand(rnd[:]); err != nil {
		return u, err
	}
	ts := uint64(g.lastMs)
	u[0] = byte(ts >> 40)
	u[1] = byte(ts >> 32)
	u[2] = byte(ts >> 24)
	u[3] = byte(ts >> 16)
	u[4] = byte(ts >> 8)
	u[5] = byte(ts)
	u[6] = 0x70 | byte((g.seq>>8)&0x0f)
	u[7] = byte(g.seq & 0xff)
	copy(u[8:], rnd[:])
	u[8] = 0x80 | (u[8] & 0x3f)
	return u, nil
}

// New mints a canonical 36-character lowercase UUIDv7 string.
func (g *UUIDGen) New() (string, error) {
	u, err := g.NewBytes()
	if err != nil {
		return "", err
	}
	return FormatUUID(u), nil
}

// FormatUUID formats 16 bytes as canonical 8-4-4-4-12 lowercase hex.
func FormatUUID(u [16]byte) string {
	var buf [36]byte
	hex.Encode(buf[0:8], u[0:4])
	buf[8] = '-'
	hex.Encode(buf[9:13], u[4:6])
	buf[13] = '-'
	hex.Encode(buf[14:18], u[6:8])
	buf[18] = '-'
	hex.Encode(buf[19:23], u[8:10])
	buf[23] = '-'
	hex.Encode(buf[24:36], u[10:16])
	return string(buf[:])
}

// ParseUUID parses a canonical 36-character lowercase UUID string into 16 bytes.
func ParseUUID(s string) ([16]byte, bool) {
	var u [16]byte
	if len(s) != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-' {
		return u, false
	}
	if s != strings.ToLower(s) {
		return u, false
	}
	hexStr := s[0:8] + s[9:13] + s[14:18] + s[19:23] + s[24:36]
	b, err := hex.DecodeString(hexStr)
	if err != nil || len(b) != 16 {
		return u, false
	}
	copy(u[:], b)
	return u, true
}

// IsUUIDv7 reports whether s is a well-formed RFC 9562 UUIDv7 string
// (version nibble 7, variant bits 10).
func IsUUIDv7(s string) bool {
	u, ok := ParseUUID(s)
	if !ok {
		return false
	}
	return (u[6]>>4) == 7 && (u[8]>>6) == 2
}
