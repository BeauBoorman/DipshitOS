package vaultlib

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

func testEntries() []Entry {
	return []Entry{
		{Name: []byte("wifi"), Secret: []byte("s3cr3t"), Note: []byte("home")},
		{Name: []byte("bank"), Secret: []byte("hunter2")},
	}
}

// sealTest builds a file the way create() does, minus the syscalls.
func sealTest(t *testing.T, pass []byte, entries []Entry) []byte {
	t.Helper()
	key, err := DeriveKey(pass, testSalt, testIters)
	if err != nil {
		t.Fatalf("DeriveKey: %v", err)
	}
	defer Zero(key)
	file, err := SealWithKey(FileMagic, FileVersion, key, testSalt, testNonce, testIters, entries)
	if err != nil {
		t.Fatalf("SealWithKey: %v", err)
	}
	return file
}

// The round trip is the framing vector: a sealed file re-opens to the same
// entries, and the recorded iteration count survives the header.
func TestSealOpenRoundTrip(t *testing.T) {
	file := sealTest(t, testPass, testEntries())
	entries, key, salt, iters, err := Open(testPass, file)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer Zero(key)
	if iters != testIters {
		t.Fatalf("iters=%d, want %d", iters, testIters)
	}
	if !bytes.Equal(salt, testSalt) {
		t.Fatalf("salt changed across the frame")
	}
	if len(entries) != 2 {
		t.Fatalf("entries=%d, want 2", len(entries))
	}
	if string(entries[0].Name) != "wifi" || string(entries[0].Secret) != "s3cr3t" ||
		string(entries[0].Note) != "home" {
		t.Fatalf("Entry 0 = %q/%q/%q", entries[0].Name, entries[0].Secret, entries[0].Note)
	}
	if string(entries[1].Name) != "bank" || string(entries[1].Secret) != "hunter2" {
		t.Fatalf("Entry 1 = %q/%q", entries[1].Name, entries[1].Secret)
	}
	if len(entries[1].Note) != 0 {
		t.Fatalf("empty note = %q", entries[1].Note)
	}
}

// The header is pinned field-for-field: magic, version, the recorded
// iteration count, and the two length-prefixed blobs — the whole frame a
// reader has to honor before it spends a passphrase.
func TestFramingVector(t *testing.T) {
	file := sealTest(t, testPass, testEntries())
	if len(file) < HeaderLen+GcmTag {
		t.Fatalf("file=%d bytes, below header+tag", len(file))
	}
	if string(file[:4]) != FileMagic {
		t.Fatalf("magic=%q", file[:4])
	}
	if getU32(file, 4) != FileVersion {
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
	if _, _, _, _, err := Open([]byte("wrong"), file); !errors.Is(err, ErrUnlock) {
		t.Fatalf("wrong pass err=%v, want ErrUnlock", err)
	}
	// Flip one byte well inside the sealed body — the tag must refuse it.
	tampered := append([]byte(nil), file...)
	tampered[len(tampered)-3] ^= 0x01
	if _, _, _, _, err := Open(testPass, tampered); !errors.Is(err, ErrUnlock) {
		t.Fatalf("tampered ciphertext err=%v, want ErrUnlock", err)
	}
	// A tampered salt or iteration count fails the same way — the header is
	// plaintext, so the GCM tag is its integrity story too.
	for _, off := range []int{8, 14} {
		c := append([]byte(nil), file...)
		c[off] ^= 0x01
		if _, _, _, _, err := Open(testPass, c); !errors.Is(err, ErrUnlock) {
			t.Fatalf("header tamper at %d err=%v, want ErrUnlock", off, err)
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
		"no body":     file[:HeaderLen],
		"tag only":    file[:HeaderLen+GcmTag],
	}
	bv := append([]byte(nil), file...)
	bv[4] = 99 // version 99
	cases["bad version"] = bv
	for name, c := range cases {
		if _, _, _, _, err := Open(testPass, c); !errors.Is(err, ErrBadFile) {
			t.Fatalf("%s err=%v, want ErrBadFile", name, err)
		}
	}
	// Truncating inside the sealed region keeps a parseable header — the
	// refusal drops to the GCM name, which is the honest one for a body the
	// tag cannot verify.
	trunc := file[:HeaderLen+6]
	if _, _, _, _, err := Open(testPass, trunc); !errors.Is(err, ErrBadFile) {
		t.Fatalf("sub-tag truncate err=%v, want ErrBadFile", err)
	}
	mid := file[:HeaderLen+GcmTag+4]
	if _, _, _, _, err := Open(testPass, mid); !errors.Is(err, ErrUnlock) {
		t.Fatalf("mid-body truncate err=%v, want ErrUnlock", err)
	}
}

// The decode bounds are the refusal lines a hostile body hits.
func TestBodyBounds(t *testing.T) {
	if _, err := decodeBody(nil, FileVersion); !errors.Is(err, ErrBadFile) {
		t.Fatalf("empty body: %v", err)
	}
	over := appendU32(nil, MaxEntries+1)
	if _, err := decodeBody(over, FileVersion); !errors.Is(err, ErrBadFile) {
		t.Fatalf("over-count body: %v", err)
	}
	// count=1 then a name_len that overruns the buffer.
	lie := appendU32(nil, 1)
	lie = appendU16(lie, 40)
	lie = append(lie, 1, 2, 3)
	if _, err := decodeBody(lie, FileVersion); !errors.Is(err, ErrBadFile) {
		t.Fatalf("overrun name_len: %v", err)
	}
	// A valid body plus one trailing byte is still a lie.
	good := encodeBody(testEntries(), FileVersion)
	if _, err := decodeBody(append(good, 0), FileVersion); !errors.Is(err, ErrBadFile) {
		t.Fatalf("trailing byte: %v", err)
	}
}

// The calibration math: a measured cost scales to ~1 s and clamps.
func TestCalibrateIterations(t *testing.T) {
	// 100k iters took 50ms -> 2M lands the second.
	if got := CalibrateIterations(50_000_000); got != 2_000_000 {
		t.Fatalf("calibrate=%d, want 2000000", got)
	}
	if got := CalibrateIterations(0); got != 600_000 {
		t.Fatalf("zero reading=%d, want the 600k fallback", got)
	}
	if got := CalibrateIterations(1); got != MaxIters {
		t.Fatalf("absurdly fast=%d, want the %d clamp", got, MaxIters)
	}
	if got := CalibrateIterations(60_000_000_000); got != MinIters {
		t.Fatalf("absurdly slow=%d, want the %d floor", got, MinIters)
	}
}
