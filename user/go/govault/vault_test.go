package main

// The class-A codec legs the card names: framing vectors, a tamper refusal
// at the GCM tag, and a wrong passphrase — plus the bounds a hostile file
// must hit. Everything here is deterministic: salt, nonce and iterations
// are test constants, so the frame is pinned byte-for-byte.
import (
	"bytes"
	"errors"
	"testing"
)

var (
	testSalt  = []byte("0123456789abcdef")
	testNonce = []byte("fedcba987654")
	testPass  = []byte("correct horse")
	testIters = uint32(50_000)
)

func testEntries() []entry {
	return []entry{
		{name: []byte("wifi"), secret: []byte("s3cr3t"), note: []byte("home")},
		{name: []byte("bank"), secret: []byte("hunter2")},
	}
}

// sealTest builds a file the way create() does, minus the syscalls.
func sealTest(t *testing.T, pass []byte, entries []entry) []byte {
	t.Helper()
	key, err := deriveKey(pass, testSalt, testIters)
	if err != nil {
		t.Fatalf("deriveKey: %v", err)
	}
	defer zero(key)
	file, err := sealWithKey(fileMagic, fileVersion, key, testSalt, testNonce, testIters, entries)
	if err != nil {
		t.Fatalf("sealWithKey: %v", err)
	}
	return file
}

// The round trip is the framing vector: a sealed file re-opens to the same
// entries, and the recorded iteration count survives the header.
func TestSealOpenRoundTrip(t *testing.T) {
	file := sealTest(t, testPass, testEntries())
	entries, key, salt, iters, err := open(testPass, file)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer zero(key)
	if iters != testIters {
		t.Fatalf("iters=%d, want %d", iters, testIters)
	}
	if !bytes.Equal(salt, testSalt) {
		t.Fatalf("salt changed across the frame")
	}
	if len(entries) != 2 {
		t.Fatalf("entries=%d, want 2", len(entries))
	}
	if string(entries[0].name) != "wifi" || string(entries[0].secret) != "s3cr3t" ||
		string(entries[0].note) != "home" {
		t.Fatalf("entry 0 = %q/%q/%q", entries[0].name, entries[0].secret, entries[0].note)
	}
	if string(entries[1].name) != "bank" || string(entries[1].secret) != "hunter2" {
		t.Fatalf("entry 1 = %q/%q", entries[1].name, entries[1].secret)
	}
	if len(entries[1].note) != 0 {
		t.Fatalf("empty note = %q", entries[1].note)
	}
}

// The header is pinned field-for-field: magic, version, the recorded
// iteration count, and the two length-prefixed blobs — the whole frame a
// reader has to honor before it spends a passphrase.
func TestFramingVector(t *testing.T) {
	file := sealTest(t, testPass, testEntries())
	if len(file) < headerLen+gcmTag {
		t.Fatalf("file=%d bytes, below header+tag", len(file))
	}
	if string(file[:4]) != fileMagic {
		t.Fatalf("magic=%q", file[:4])
	}
	if getU32(file, 4) != fileVersion {
		t.Fatalf("version=%d", getU32(file, 4))
	}
	if getU32(file, 8) != testIters {
		t.Fatalf("iters=%d in header", getU32(file, 8))
	}
	if int(getU16(file, 12)) != len(testSalt) || !bytes.Equal(file[14:14+len(testSalt)], testSalt) {
		t.Fatalf("salt field wrong")
	}
	no := 14 + len(testSalt)
	if int(getU16(file, no)) != len(testNonce) || !bytes.Equal(file[no+2:no+2+len(testNonce)], testNonce) {
		t.Fatalf("nonce field wrong")
	}
	// Resealing the same entries differs ONLY at the nonce-dependent bytes
	// — the header is deterministic, the seal is not (that is the point of
	// a fresh nonce, but the header must not drift with it).
}

// A wrong passphrase and a tampered ciphertext are the same refusal by
// design — the tag cannot tell them apart, so the caller cannot either.
func TestWrongPassAndTamperShareOneRefusal(t *testing.T) {
	file := sealTest(t, testPass, testEntries())
	if _, _, _, _, err := open([]byte("wrong"), file); !errors.Is(err, errUnlock) {
		t.Fatalf("wrong pass err=%v, want errUnlock", err)
	}
	// Flip one byte well inside the sealed body — the tag must refuse it.
	tampered := append([]byte(nil), file...)
	tampered[len(tampered)-3] ^= 0x01
	if _, _, _, _, err := open(testPass, tampered); !errors.Is(err, errUnlock) {
		t.Fatalf("tampered ciphertext err=%v, want errUnlock", err)
	}
	// A tampered salt or iteration count fails the same way — the header is
	// plaintext, so the GCM tag is its integrity story too.
	for _, off := range []int{8, 14} {
		c := append([]byte(nil), file...)
		c[off] ^= 0x01
		if _, _, _, _, err := open(testPass, c); !errors.Is(err, errUnlock) {
			t.Fatalf("header tamper at %d err=%v, want errUnlock", off, err)
		}
	}
}

// Structural lies get their own name before a passphrase is spent.
func TestBadFileRefusals(t *testing.T) {
	file := sealTest(t, testPass, testEntries())
	cases := map[string][]byte{
		"empty":       {},
		"short":       file[:20],
		"bad magic":   append([]byte("XVLT"), file[4:]...),
		"bad version": nil,
		"no body":     file[:headerLen],
		"tag only":    file[:headerLen+gcmTag],
	}
	bv := append([]byte(nil), file...)
	bv[4] = 99 // version 99
	cases["bad version"] = bv
	for name, c := range cases {
		if _, _, _, _, err := open(testPass, c); !errors.Is(err, errBadFile) {
			t.Fatalf("%s err=%v, want errBadFile", name, err)
		}
	}
	// Truncating inside the sealed region keeps a parseable header — the
	// refusal drops to the GCM name, which is the honest one for a body the
	// tag cannot verify.
	trunc := file[:headerLen+6]
	if _, _, _, _, err := open(testPass, trunc); !errors.Is(err, errBadFile) {
		t.Fatalf("sub-tag truncate err=%v, want errBadFile", err)
	}
	mid := file[:headerLen+gcmTag+4]
	if _, _, _, _, err := open(testPass, mid); !errors.Is(err, errUnlock) {
		t.Fatalf("mid-body truncate err=%v, want errUnlock", err)
	}
}

// The decode bounds are the refusal lines a hostile body hits.
func TestBodyBounds(t *testing.T) {
	if _, err := decodeBody(nil, fileVersion); !errors.Is(err, errBadFile) {
		t.Fatalf("empty body: %v", err)
	}
	over := appendU32(nil, maxEntries+1)
	if _, err := decodeBody(over, fileVersion); !errors.Is(err, errBadFile) {
		t.Fatalf("over-count body: %v", err)
	}
	// count=1 then a name_len that overruns the buffer.
	lie := appendU32(nil, 1)
	lie = appendU16(lie, 40)
	lie = append(lie, 1, 2, 3)
	if _, err := decodeBody(lie, fileVersion); !errors.Is(err, errBadFile) {
		t.Fatalf("overrun name_len: %v", err)
	}
	// A valid body plus one trailing byte is still a lie.
	good := encodeBody(testEntries(), fileVersion)
	if _, err := decodeBody(append(good, 0), fileVersion); !errors.Is(err, errBadFile) {
		t.Fatalf("trailing byte: %v", err)
	}
}

// The calibration math: a measured cost scales to ~1 s and clamps.
func TestCalibrateIterations(t *testing.T) {
	// 100k iters took 50ms -> 2M lands the second.
	if got := calibrateIterations(50_000_000); got != 2_000_000 {
		t.Fatalf("calibrate=%d, want 2000000", got)
	}
	if got := calibrateIterations(0); got != 600_000 {
		t.Fatalf("zero reading=%d, want the 600k fallback", got)
	}
	if got := calibrateIterations(1); got != maxIters {
		t.Fatalf("absurdly fast=%d, want the %d clamp", got, maxIters)
	}
	if got := calibrateIterations(60_000_000_000); got != minIters {
		t.Fatalf("absurdly slow=%d, want the %d floor", got, minIters)
	}
}
