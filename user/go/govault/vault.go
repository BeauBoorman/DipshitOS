// vault.go — M148a (issue #2804): the GOVAULT file codec, pure of vi/vsys so
// the host tests can pin every refusal by name.
//
// The file is one versioned frame:
//
//	offset  0   magic "GVLT"                 4
//	offset  4   version (u32 LE)             4   — 1
//	offset  8   iterations (u32 LE)          4   — recorded at create time
//	offset 12   salt_len (u16 LE) + salt     2+16
//	offset 30   nonce_len (u16 LE) + nonce   2+12 — 44-byte header total
//	offset 44   AES-256-GCM sealed body
//
// The key is PBKDF2-HMAC-SHA256(passphrase, salt, iterations) -> 32 bytes.
// The iteration count is measured at create time so one unlock takes about a
// second on the VM (see calibrateIterations) and recorded in the header, so a
// vault opened on a different machine keeps its own cost, not the maker's.
//
// The body is a length-prefixed entry list:
//
//	count (u32 LE)
//	per entry: name_len (u16 LE) + name, secret_len (u16 LE) + secret,
//	           note_len (u16 LE) + note
//
// Refusal vocabulary is deliberately two names wide (the named-refusal rule a
// secrets app lives under):
//
//	errBadFile  — the frame itself is not a vault: short, wrong magic, wrong
//	              version, a length field that overruns, an empty body. A
//	              structural lie is named before any passphrase is spent.
//	errUnlock   — the frame parses but GCM refuses to open it: wrong
//	              passphrase or tampered ciphertext/tag, and BY DESIGN those
//	              two are indistinguishable — an attacker learns nothing
//	              from the refusal that the tag did not already tell them.
//
// Entry name, secret and note live in []byte, never string, so lock() can
// zero them. Nothing in this file prints, and no caller may print these
// fields — secret material stays off serial.
package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/sha256"
	"errors"
)

const (
	fileMagic   = "GVLT"
	fileVersion = 1

	saltLen  = 16
	nonceLen = 12 // cipher.NewGCM's standard nonce size
	keyLen   = 32 // AES-256
	gcmTag   = 16

	// headerLen is magic+version+iterations+salt_len+salt+nonce_len+nonce.
	headerLen = 4 + 4 + 4 + 2 + saltLen + 2 + nonceLen

	// Bounds. A vault is a pocket file, not a database: the numbers are the
	// refusal lines a host test can pin, and every one is enforced on the
	// decode side so a hostile file cannot make the decoder allocate or
	// index beyond them.
	maxFile    = 64 << 10
	maxEntries = 64
	maxName    = 48
	maxSecret  = 256
	maxNote    = 512

	// Iteration calibration. measureIterations is one measurement's cost;
	// the recorded count is scaled so the real derive lands near one second,
	// then clamped so a pathological counter never produces a trivial or an
	// unopenable vault.
	calibrateIters = 100_000
	minIters       = 100_000
	maxIters       = 4_000_000
)

var (
	errBadFile = errors.New("vault: bad file")
	errUnlock  = errors.New("vault: unlock failed")
)

// entry is one stored row. name and note are user metadata; secret is the
// material. All three are []byte so a lock can zero them in place.
type entry struct {
	name   []byte
	secret []byte
	note   []byte
}

// deriveKey runs the recorded KDF. The passphrase crosses into the stdlib as
// a string (pbkdf2's signature demands it); the caller's []byte copy is the
// one that gets zeroed.
func deriveKey(passphrase []byte, salt []byte, iters uint32) ([]byte, error) {
	return pbkdf2.Key(sha256.New, string(passphrase), salt, int(iters), keyLen)
}

// sealWithKey produces the whole vault file: header + AES-256-GCM sealed
// body under an already-derived session key. The plaintext body is zeroed
// before return; the key stays the caller's to zero.
func sealWithKey(key, salt, nonce []byte, iters uint32, entries []entry) ([]byte, error) {
	body := encodeBody(entries)
	defer zero(body)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	out := make([]byte, 0, headerLen+len(body)+gcmTag)
	out = append(out, fileMagic...)
	out = appendU32(out, fileVersion)
	out = appendU32(out, iters)
	out = appendU16(out, uint16(len(salt)))
	out = append(out, salt...)
	out = appendU16(out, uint16(len(nonce)))
	out = append(out, nonce...)
	return gcm.Seal(out, nonce, body, nil), nil
}

// open parses the frame, derives the key and unseals the body, returning the
// session material the unlocked app holds: the entries, the derived key
// (retained so a save re-seals without a second passphrase prompt), and the
// salt+iteration header the unlock proved. The three refusal outcomes are
// exactly errUnlock (wrong passphrase or tampered ciphertext — by design
// indistinguishable) and errBadFile. The recovered plaintext is zeroed
// before return; the caller owns key/salt zeroing on lock.
func open(passphrase, file []byte) (entries []entry, key, salt []byte, iters uint32, err error) {
	salt, nonce, body, iters, err := parseHeader(file)
	if err != nil {
		return nil, nil, nil, 0, err
	}
	key, err = deriveKey(passphrase, salt, iters)
	if err != nil {
		return nil, nil, nil, 0, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, nil, nil, 0, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, nil, nil, 0, err
	}
	plain, err := gcm.Open(nil, nonce, body, nil)
	if err != nil {
		zero(key)
		return nil, nil, nil, 0, errUnlock
	}
	defer zero(plain)
	entries, err = decodeBody(plain)
	if err != nil {
		zero(key)
		return nil, nil, nil, 0, err
	}
	return entries, key, salt, iters, nil
}

// parseHeader validates the frame and returns its fields. The body slice
// aliases the file — callers must not retain it past the GCM open.
func parseHeader(file []byte) (salt, nonce, body []byte, iters uint32, err error) {
	if len(file) < headerLen || len(file) > maxFile {
		return nil, nil, nil, 0, errBadFile
	}
	if string(file[:4]) != fileMagic {
		return nil, nil, nil, 0, errBadFile
	}
	if getU32(file, 4) != fileVersion {
		return nil, nil, nil, 0, errBadFile
	}
	iters = getU32(file, 8)
	if iters == 0 {
		return nil, nil, nil, 0, errBadFile
	}
	sl := int(getU16(file, 12))
	if sl < 8 || 14+sl > len(file) {
		return nil, nil, nil, 0, errBadFile
	}
	salt = file[14 : 14+sl]
	nl := int(getU16(file, 14+sl))
	base := 14 + sl + 2
	if nl != nonceLen || base+nl > len(file) {
		return nil, nil, nil, 0, errBadFile
	}
	nonce = file[base : base+nl]
	body = file[base+nl:]
	// A body shorter than the tag cannot authenticate; an empty one is a
	// truncated file. Both are structural, so they join the bad-file name
	// rather than spending a passphrase on them.
	if len(body) < gcmTag+1 {
		return nil, nil, nil, 0, errBadFile
	}
	return salt, nonce, body, iters, nil
}

// encodeBody serializes the entry list. Counts and lengths are bounded by the
// package constants; a caller that keeps entries inside them cannot fail.
func encodeBody(entries []entry) []byte {
	n := 4
	for _, e := range entries {
		n += 6 + len(e.name) + len(e.secret) + len(e.note)
	}
	out := make([]byte, 0, n)
	out = appendU32(out, uint32(len(entries)))
	for _, e := range entries {
		out = appendU16(out, uint16(len(e.name)))
		out = append(out, e.name...)
		out = appendU16(out, uint16(len(e.secret)))
		out = append(out, e.secret...)
		out = appendU16(out, uint16(len(e.note)))
		out = append(out, e.note...)
	}
	return out
}

// decodeBody reverses encodeBody with bounds checked at every step: a length
// field is read only after the bytes it claims are proven present, so a
// corrupt body names errBadFile instead of panicking or overrunning. Fields
// are COPIED out — the caller zeroes the plaintext buffer on return, and an
// aliased entry would be a zeroed entry.
func decodeBody(b []byte) ([]entry, error) {
	if len(b) < 4 {
		return nil, errBadFile
	}
	count := getU32(b, 0)
	if count > maxEntries {
		return nil, errBadFile
	}
	entries := make([]entry, 0, count)
	p := 4
	take := func(want int) ([]byte, bool) {
		if want < 0 || p+want > len(b) {
			return nil, false
		}
		s := append([]byte(nil), b[p:p+want]...)
		p += want
		return s, true
	}
	field := func(max int) ([]byte, bool) {
		lb, ok := take(2)
		if !ok {
			return nil, false
		}
		l := int(uint32(lb[0]) | uint32(lb[1])<<8)
		if l > max {
			return nil, false
		}
		return take(l)
	}
	for i := uint32(0); i < count; i++ {
		var e entry
		var ok bool
		if e.name, ok = field(maxName); !ok {
			return nil, errBadFile
		}
		if e.secret, ok = field(maxSecret); !ok {
			return nil, errBadFile
		}
		if e.note, ok = field(maxNote); !ok {
			return nil, errBadFile
		}
		entries = append(entries, e)
	}
	if p != len(b) {
		// Trailing bytes are not padding — the frame claims a body it does
		// not hold, which is the same structural lie as a bad length.
		return nil, errBadFile
	}
	return entries, nil
}

// calibrateIterations scales one measured derive to about a second of
// PBKDF2. ns is the Nanotime cost of calibrateIters iterations; 0 or a
// negative reading (a counter that did not advance) falls back to the
// midpoint rather than trusting a number nobody measured.
func calibrateIterations(ns int64) uint32 {
	if ns <= 0 {
		return 600_000
	}
	iters := int64(calibrateIters) * 1_000_000_000 / ns
	if iters < minIters {
		iters = minIters
	}
	if iters > maxIters {
		iters = maxIters
	}
	return uint32(iters)
}

// zero overwrites a sensitive buffer. Best-effort by nature (the GC may have
// copied), but the buffer the caller still holds is honestly cleared.
func zero(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

// zeroEntries clears every field of every entry — the lock path's wipe.
func zeroEntries(entries []entry) {
	for i := range entries {
		zero(entries[i].name)
		zero(entries[i].secret)
		zero(entries[i].note)
	}
}

// equalBytes is a constant-time-free compare for the clipboard guard: the
// comparison is between two copies of the same secret, so early-exit leaks
// nothing the clipboard did not already publish.
func equalBytes(a, b []byte) bool { return bytes.Equal(a, b) }

func appendU16(b []byte, v uint16) []byte {
	return append(b, byte(v), byte(v>>8))
}

func appendU32(b []byte, v uint32) []byte {
	return append(b, byte(v), byte(v>>8), byte(v>>16), byte(v>>24))
}

func getU16(b []byte, off int) uint16 {
	return uint16(b[off]) | uint16(b[off+1])<<8
}

func getU32(b []byte, off int) uint32 {
	return uint32(b[off]) | uint32(b[off+1])<<8 | uint32(b[off+2])<<16 | uint32(b[off+3])<<24
}
