// Package vaultlib — the GVLT/GVLX file codec, extracted from govault by
// M190e (#3240) so the seat's lock curtain verifies the same vault under the
// same frame. Pure of vi/vsys so the host tests can pin every refusal by name.
// (The codec itself is M148a issue #2804; the frame is M156c's.) M156c (#2933): the frame is
// versioned — v2 adds the per-Entry otpauth base32 field, v1 still reads —
// and the same frame carries the GVLX export bundle under a distinct magic.
//
// The file is one versioned frame:
//
//	offset  0   magic "GVLT"                 4   — "GVLX" for an export bundle
//	offset  4   version (u32 LE)             4   — 1 or 2
//	offset  8   iterations (u32 LE)          4   — recorded at create time
//	offset 12   salt_len (u16 LE) + salt     2+16
//	offset 30   nonce_len (u16 LE) + nonce   2+12 — 44-byte header total
//	offset 44   AES-256-GCM sealed body
//
// The key is PBKDF2-HMAC-SHA256(passphrase, salt, iterations) -> 32 bytes.
// The iteration count is measured at create time so one unlock takes about a
// second on the VM (see CalibrateIterations) and recorded in the header, so a
// vault opened on a different machine keeps its own cost, not the maker's.
//
// The body is a length-prefixed Entry list:
//
//	count (u32 LE)
//	per Entry: name_len (u16 LE) + name, secret_len (u16 LE) + secret,
//	           note_len (u16 LE) + note,
//	           version 2 adds: totp_len (u16 LE) + totp (the otpauth base32
//	           secret text, never a rendered code)
//
// A v1 body simply ends after the note field per Entry — its rows decode
// with an empty totp. New writes are always v2.
//
// Refusal vocabulary is deliberately two names wide (the named-refusal rule a
// secrets app lives under):
//
//	ErrBadFile  — the frame itself is not a vault: short, wrong magic, wrong
//	              version, a length field that overruns, an empty body. A
//	              structural lie is named before any passphrase is spent.
//	ErrUnlock   — the frame parses but GCM refuses to open it: wrong
//	              passphrase or tampered ciphertext/tag, and BY DESIGN those
//	              two are indistinguishable — an attacker learns nothing
//	              from the refusal that the tag did not already tell them.
//
// Entry name, secret and note live in []byte, never string, so lock() can
// zero them. Nothing in this file prints, and no caller may print these
// fields — secret material stays off serial.
package vaultlib

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/sha256"
	"errors"
)

const (
	FileMagic   = "GVLT"
	ExportMagic = "GVLX" // the export bundle: same frame, distinct magic
	FileVersion = 2
	MinVersion  = 1 // v1 frames still read (no totp field per Entry)

	SaltLen  = 16
	NonceLen = 12 // cipher.NewGCM's standard nonce size
	KeyLen   = 32 // AES-256
	GcmTag   = 16

	// HeaderLen is magic+version+iterations+salt_len+salt+nonce_len+nonce.
	HeaderLen = 4 + 4 + 4 + 2 + SaltLen + 2 + NonceLen

	// Bounds. A vault is a pocket file, not a database: the numbers are the
	// refusal lines a host test can pin, and every one is enforced on the
	// decode side so a hostile file cannot make the decoder allocate or
	// index beyond them.
	MaxFile    = 64 << 10
	MaxEntries = 64
	MaxName    = 48
	MaxSecret  = 256
	MaxNote    = 512
	MaxTotp    = 128 // a base32 seed is ~16–52 chars; the bound is generous

	// Iteration calibration. measureIterations is one measurement's cost;
	// the recorded count is scaled so the real derive lands near one second,
	// then clamped so a pathological counter never produces a trivial or an
	// unopenable vault.
	CalibrateIters = 100_000
	MinIters       = 100_000
	MaxIters       = 4_000_000
)

var (
	ErrBadFile = errors.New("vault: bad file")
	ErrUnlock  = errors.New("vault: unlock failed")
)

// DefaultPath is where GOVAULT keeps its vault on the share — the
// /host/<APP> dir the other file-cap apps use. It is deliberately NOT a
// secret-class path (ADR 0024 D8): the body is sealed, so WriteFileSafe's
// path~ temp window exposes ciphertext, never plaintext. The seat's lock
// curtain reads the same file — uid_user reads its own 0600.
const DefaultPath = "/host/GOVAULT/VAULT.BIN"

// Verify is the seat's screen-lock check (M190e, #3240): open the vault
// under the typed passphrase and throw the plaintext away — the caller
// wants the proof, never the entries. The refusals are exactly Open's.
func Verify(passphrase, file []byte) error {
	entries, key, _, _, err := Open(passphrase, file)
	if err != nil {
		return err
	}
	ZeroEntries(entries)
	Zero(key)
	return nil
}

// Entry is one stored row. name and note are user metadata; secret and totp
// are the material (totp holds the otpauth base32 seed — it is a shared
// secret, not the code it renders). All are []byte so a lock can zero them
// in place.
type Entry struct {
	Name   []byte
	Secret []byte
	Note   []byte
	Totp   []byte
}

// DeriveKey runs the recorded KDF. The passphrase crosses into the stdlib as
// a string (pbkdf2's signature demands it); the caller's []byte copy is the
// one that gets zeroed.
func DeriveKey(passphrase []byte, salt []byte, iters uint32) ([]byte, error) {
	return pbkdf2.Key(sha256.New, string(passphrase), salt, int(iters), KeyLen)
}

// SealWithKey produces the whole vault file: header + AES-256-GCM sealed
// body under an already-derived session key. magic selects the frame's
// audience — FileMagic for the vault itself, ExportMagic for a GVLX bundle —
// and ver the body layout written (always FileVersion today). The plaintext
// body is zeroed before return; the key stays the caller's to zero.
func SealWithKey(magic string, ver uint32, key, salt, nonce []byte, iters uint32, entries []Entry) ([]byte, error) {
	body := encodeBody(entries, ver)
	defer Zero(body)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	out := make([]byte, 0, HeaderLen+len(body)+GcmTag)
	out = append(out, magic...)
	out = appendU32(out, ver)
	out = appendU32(out, iters)
	out = appendU16(out, uint16(len(salt)))
	out = append(out, salt...)
	out = appendU16(out, uint16(len(nonce)))
	out = append(out, nonce...)
	return gcm.Seal(out, nonce, body, nil), nil
}

// open parses a GVLT frame; OpenExport parses a GVLX bundle. Same codec,
// different magic — a bundle is never a vault and a vault is never a
// bundle, so a file handed to the wrong door names ErrBadFile before a
// passphrase is spent.
func Open(passphrase, file []byte) (entries []Entry, key, salt []byte, iters uint32, err error) {
	return openFrame(FileMagic, passphrase, file)
}

func OpenExport(passphrase, file []byte) (entries []Entry, key, salt []byte, iters uint32, err error) {
	return openFrame(ExportMagic, passphrase, file)
}

// openFrame parses the frame, derives the key and unseals the body,
// returning the session material the unlocked app holds: the entries, the
// derived key (retained so a save re-seals without a second passphrase
// prompt), and the salt+iteration header the unlock proved. The three
// refusal outcomes are exactly ErrUnlock (wrong passphrase or tampered
// ciphertext — by design indistinguishable) and ErrBadFile. The recovered
// plaintext is zeroed before return; the caller owns key/salt zeroing on
// lock.
func openFrame(magic string, passphrase, file []byte) (entries []Entry, key, salt []byte, iters uint32, err error) {
	salt, nonce, body, ver, iters, err := ParseHeader(file, magic)
	if err != nil {
		return nil, nil, nil, 0, err
	}
	key, err = DeriveKey(passphrase, salt, iters)
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
		Zero(key)
		return nil, nil, nil, 0, ErrUnlock
	}
	defer Zero(plain)
	entries, err = decodeBody(plain, ver)
	if err != nil {
		Zero(key)
		return nil, nil, nil, 0, err
	}
	return entries, key, salt, iters, nil
}

// ParseHeader validates the frame and returns its fields — the version too,
// so the body decode knows which field set to expect. The body slice
// aliases the file — callers must not retain it past the GCM open.
func ParseHeader(file []byte, magic string) (salt, nonce, body []byte, ver, iters uint32, err error) {
	if len(file) < HeaderLen || len(file) > MaxFile {
		return nil, nil, nil, 0, 0, ErrBadFile
	}
	if string(file[:4]) != magic {
		return nil, nil, nil, 0, 0, ErrBadFile
	}
	ver = getU32(file, 4)
	if ver < MinVersion || ver > FileVersion {
		return nil, nil, nil, 0, 0, ErrBadFile
	}
	iters = getU32(file, 8)
	if iters == 0 {
		return nil, nil, nil, 0, 0, ErrBadFile
	}
	sl := int(getU16(file, 12))
	if sl < 8 || 14+sl > len(file) {
		return nil, nil, nil, 0, 0, ErrBadFile
	}
	salt = file[14 : 14+sl]
	nl := int(getU16(file, 14+sl))
	base := 14 + sl + 2
	if nl != NonceLen || base+nl > len(file) {
		return nil, nil, nil, 0, 0, ErrBadFile
	}
	nonce = file[base : base+nl]
	body = file[base+nl:]
	// A body shorter than the tag cannot authenticate; an empty one is a
	// truncated file. Both are structural, so they join the bad-file name
	// rather than spending a passphrase on them.
	if len(body) < GcmTag+1 {
		return nil, nil, nil, 0, 0, ErrBadFile
	}
	return salt, nonce, body, ver, iters, nil
}

// encodeBody serializes the Entry list at the given format version — v2
// appends the per-Entry totp field, v1 writes the original three-field row.
// Counts and lengths are bounded by the package constants; a caller that
// keeps entries inside them cannot fail.
func encodeBody(entries []Entry, ver uint32) []byte {
	n := 4
	for _, e := range entries {
		n += 6 + len(e.Name) + len(e.Secret) + len(e.Note)
		if ver >= 2 {
			n += 2 + len(e.Totp)
		}
	}
	out := make([]byte, 0, n)
	out = appendU32(out, uint32(len(entries)))
	for _, e := range entries {
		out = appendU16(out, uint16(len(e.Name)))
		out = append(out, e.Name...)
		out = appendU16(out, uint16(len(e.Secret)))
		out = append(out, e.Secret...)
		out = appendU16(out, uint16(len(e.Note)))
		out = append(out, e.Note...)
		if ver >= 2 {
			out = appendU16(out, uint16(len(e.Totp)))
			out = append(out, e.Totp...)
		}
	}
	return out
}

// decodeBody reverses encodeBody for the frame's version — a v1 body ends
// each row at the note field, a v2 body adds the bounded totp field. Bounds
// are checked at every step: a length field is read only after the bytes it
// claims are proven present, so a corrupt body names ErrBadFile instead of
// panicking or overrunning. Fields are COPIED out — the caller zeroes the
// plaintext buffer on return, and an aliased Entry would be a zeroed Entry.
func decodeBody(b []byte, ver uint32) ([]Entry, error) {
	if len(b) < 4 {
		return nil, ErrBadFile
	}
	count := getU32(b, 0)
	if count > MaxEntries {
		return nil, ErrBadFile
	}
	entries := make([]Entry, 0, count)
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
		var e Entry
		var ok bool
		if e.Name, ok = field(MaxName); !ok {
			return nil, ErrBadFile
		}
		if e.Secret, ok = field(MaxSecret); !ok {
			return nil, ErrBadFile
		}
		if e.Note, ok = field(MaxNote); !ok {
			return nil, ErrBadFile
		}
		if ver >= 2 {
			if e.Totp, ok = field(MaxTotp); !ok {
				return nil, ErrBadFile
			}
		}
		entries = append(entries, e)
	}
	if p != len(b) {
		// Trailing bytes are not padding — the frame claims a body it does
		// not hold, which is the same structural lie as a bad length.
		return nil, ErrBadFile
	}
	return entries, nil
}

// CalibrateIterations scales one measured derive to about a second of
// PBKDF2. ns is the Nanotime cost of CalibrateIters iterations; 0 or a
// negative reading (a counter that did not advance) falls back to the
// midpoint rather than trusting a number nobody measured.
func CalibrateIterations(ns int64) uint32 {
	if ns <= 0 {
		return 600_000
	}
	iters := int64(CalibrateIters) * 1_000_000_000 / ns
	if iters < MinIters {
		iters = MinIters
	}
	if iters > MaxIters {
		iters = MaxIters
	}
	return uint32(iters)
}

// zero overwrites a sensitive buffer. Best-effort by nature (the GC may have
// copied), but the buffer the caller still holds is honestly cleared.
func Zero(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

// ZeroEntries clears every field of every Entry — the lock path's wipe.
// The totp seed is a shared secret too: it is wiped with the rest.
func ZeroEntries(entries []Entry) {
	for i := range entries {
		Zero(entries[i].Name)
		Zero(entries[i].Secret)
		Zero(entries[i].Note)
		Zero(entries[i].Totp)
	}
}

// EqualBytes is a constant-time-free compare for the clipboard guard: the
// comparison is between two copies of the same secret, so early-exit leaks
// nothing the clipboard did not already publish.
func EqualBytes(a, b []byte) bool { return bytes.Equal(a, b) }

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
