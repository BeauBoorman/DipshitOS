// totp.go — M156c (#2933): the TOTP half of GOVAULT v2, pure of vi/vsys so
// the host tests can pin the RFC vectors by name. The card gates the feature
// behind a probe: crypto/hmac + crypto/sha1 must compile for the guest and
// match RFC 6238 Appendix B (totp_test.go is that leg), and the guest wall
// clock must sit within ±30 s of the host clock (the `govault: clock epoch=`
// marker is that leg — a TOTP a minute out of step is a code nobody accepts).
//
// Two pieces live here:
//
//	hotp/totp — RFC 4226 dynamic truncation over HMAC-SHA1, RFC 6238's
//	            30-second step; the row shows six digits and the seconds
//	            left in the current step.
//	otp secret intake — a base32 seed, bare or inside an otpauth:// URI's
//	            secret= parameter; stored CANONICAL (uppercase, unpadded)
//	            so the file format and the display see one spelling.
//
// The seed is a shared secret, not a code: it lives in vaultlib.Entry.totp as []byte
// and is zeroed on lock with the rest.
package main

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base32"
	"strings"
	"virelai/vaultlib"
)

// totpStep is RFC 6238's default 30-second step.
const totpStep = int64(30)

// b32 is the unpadded RFC 4648 alphabet — the spelling otpauth secrets use.
var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

// hotp is RFC 4226: HMAC-SHA1(key, counter big-endian) through dynamic
// truncation, returned as the full 31-bit value. The caller mods for digits.
func hotp(key []byte, counter uint64) uint32 {
	mac := hmac.New(sha1.New, key)
	var cb [8]byte
	for i := 7; i >= 0; i-- {
		cb[i] = byte(counter)
		counter >>= 8
	}
	mac.Write(cb[:])
	sum := mac.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	v := uint32(sum[off]&0x7f)<<24 | uint32(sum[off+1])<<16 |
		uint32(sum[off+2])<<8 | uint32(sum[off+3])
	vaultlib.Zero(sum)
	return v
}

// pow10 is the digit modulus; digits is 6 on the row (8 in the RFC vectors).
func pow10(d uint) uint32 {
	p := uint32(1)
	for i := uint(0); i < d; i++ {
		p *= 10
	}
	return p
}

// totpAt is RFC 6238: the counter is epoch/step, the code the low `digits`
// decimal digits. ok=false on a clock that precedes T0 — a wall clock that
// has never been set renders no plausible code and the row says so instead
// of computing against a nonsense epoch.
func totpAt(key []byte, epoch int64, digits uint) (uint32, bool) {
	if epoch < 0 || len(key) == 0 {
		return 0, false
	}
	return hotp(key, uint64(epoch)/uint64(totpStep)) % pow10(digits), true
}

// totpLeft is the seconds remaining in epoch's step — the countdown the row
// paints beside the code.
func totpLeft(epoch int64) int {
	if epoch < 0 {
		return 0
	}
	return int(totpStep - epoch%totpStep)
}

// decodeSeed turns the canonical base32 text an vaultlib.Entry stores into the key
// bytes hotp wants. The copy is the caller's to zero.
func decodeSeed(b32text []byte) ([]byte, bool) {
	key, err := b32.DecodeString(string(b32text))
	if err != nil {
		return nil, false
	}
	return key, true
}

// parseOTPSecret accepts the two spellings a user actually holds: a bare
// base32 seed ("GEZD..."), or an otpauth:// URI whose secret= parameter
// carries it ("otpauth://totp/a?secret=GEZD...&issuer=x"). Whitespace and
// case are normalized; padding is tolerated and dropped. The return is the
// canonical base32 text — what vaultlib.Entry.totp stores — or ok=false when the
// text does not decode.
func parseOTPSecret(in []byte) ([]byte, bool) {
	s := strings.TrimSpace(string(in))
	if i := strings.Index(strings.ToLower(s), "otpauth://"); i >= 0 {
		s = s[i:]
		q := strings.IndexByte(s, '?')
		if q < 0 {
			return nil, false
		}
		var found string
		for _, kv := range strings.Split(s[q+1:], "&") {
			k, v, ok := strings.Cut(kv, "=")
			if ok && strings.EqualFold(k, "secret") {
				found = v
				break
			}
		}
		if found == "" {
			return nil, false
		}
		s = found
	}
	// Normalize: no interior whitespace, uppercase, '=' padding stripped
	// then re-padded to the decode boundary — a seed copied with partial
	// padding still reads.
	var b strings.Builder
	for _, c := range s {
		if c == ' ' || c == '\t' {
			continue
		}
		if c == '=' {
			continue // canonical form is unpadded; pad only for the decode
		}
		if c >= 'a' && c <= 'z' {
			c -= 'a' - 'A'
		}
		b.WriteByte(byte(c))
	}
	t := b.String()
	if t == "" || len(t) > vaultlib.MaxTotp {
		return nil, false
	}
	key, err := b32.DecodeString(t)
	// The round-trip check is the real validation: a seed whose decode is
	// empty or whose canonical re-encode differs is not a seed a peer's
	// authenticator would agree on — refuse it at intake, not at render.
	if err != nil || len(key) == 0 || b32.EncodeToString(key) != t {
		vaultlib.Zero(key)
		return nil, false
	}
	vaultlib.Zero(key)
	return []byte(t), true
}
