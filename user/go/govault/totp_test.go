package main

// The class-A legs M156c (#2933) names: the GVLX round trip, wrong-passphrase
// refusal, the merge rules, the RFC 6238 Appendix B vectors, and v1->v2
// decode — plus the seed intake and the state-blob codec. All pure.
import (
	"bytes"
	"errors"
	"testing"
)

// RFC 6238 Appendix B: the SHA-1 column, T0=0, 30 s step, 8 digits, and the
// ASCII seed "12345678901234567890". totpAt returning these numbers is the
// crypto/hmac + crypto/sha1 probe leg the card gates the feature behind.
func TestRFC6238Vectors(t *testing.T) {
	key := []byte("12345678901234567890")
	cases := []struct {
		epoch int64
		want  uint32
	}{
		{59, 94287082},
		{1111111109, 7081804}, // RFC prints it 07081804
		{1111111111, 14050471},
		{1234567890, 89005924},
		{2000000000, 69279037},
		{20000000000, 65353130},
	}
	for _, c := range cases {
		got, ok := totpAt(key, c.epoch, 8)
		if !ok || got != c.want {
			t.Fatalf("totp(%d) = %08d ok=%v, want %08d", c.epoch, got, ok, c.want)
		}
	}
	// The row shows six digits — the same value mod 1e6.
	if got, _ := totpAt(key, 59, 6); got != 287082 {
		t.Fatalf("totp6(59) = %06d, want 287082", got)
	}
	if _, ok := totpAt(key, -1, 6); ok {
		t.Fatal("a pre-T0 clock must refuse, not compute")
	}
}

// The countdown reads seconds-left-in-step straight off the epoch.
func TestTotpLeft(t *testing.T) {
	if got := totpLeft(59); got != 1 {
		t.Fatalf("left(59) = %d, want 1", got)
	}
	if got := totpLeft(60); got != 30 {
		t.Fatalf("left(60) = %d, want 30", got)
	}
}

// Seed intake: bare base32, padded or lowercase spellings, and the
// otpauth:// URI form all land on the same canonical text; a non-seed
// refuses by name.
func TestParseOTPSecret(t *testing.T) {
	// base32("12345678901234567890") — the RFC 6238 seed's canonical text.
	want := "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
	for _, in := range []string{
		want,
		"gezdgnbvgy3tqojqgezdgnbvgy3tqojq",
		"GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ====",
		"otpauth://totp/a@b?secret=" + want + "&issuer=x",
		"otpauth://totp/a?issuer=x&secret=" + want,
	} {
		got, ok := parseOTPSecret([]byte(in))
		if !ok || string(got) != want {
			t.Fatalf("parse(%q) = %q ok=%v, want %q", in, got, ok, want)
		}
	}
	// The parsed seed must decode back to the RFC key bytes.
	key, ok := decodeSeed(mustSeed(t, want))
	if !ok || !bytes.Equal(key, []byte("12345678901234567890")) {
		t.Fatalf("decodeSeed = %x ok=%v", key, ok)
	}
	for _, bad := range []string{"", "not base32!!!", "otpauth://totp/x?issuer=y", "G", "GEZDGNBV!"} {
		if got, ok := parseOTPSecret([]byte(bad)); ok {
			t.Fatalf("parse(%q) = %q, want refusal", bad, got)
		}
	}
}

func mustSeed(t *testing.T, s string) []byte {
	t.Helper()
	b, ok := parseOTPSecret([]byte(s))
	if !ok {
		t.Fatalf("seed %q did not parse", s)
	}
	return b
}

// The GVLX round trip: export under its own passphrase, open through the
// bundle door, and the entries — totp field included — come back whole.
func TestGVLXRoundTrip(t *testing.T) {
	entries := []entry{
		{name: []byte("mail"), secret: []byte("letmein"), note: []byte("work"),
			totp: []byte("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")},
	}
	key, err := deriveKey(testPass, testSalt, testIters)
	if err != nil {
		t.Fatalf("deriveKey: %v", err)
	}
	defer zero(key)
	bundle, err := sealWithKey(exportMagic, fileVersion, key, testSalt, testNonce, testIters, entries)
	if err != nil {
		t.Fatalf("sealWithKey(GVLX): %v", err)
	}
	if string(bundle[:4]) != exportMagic {
		t.Fatalf("bundle magic = %q, want GVLX", bundle[:4])
	}
	got, ikey, _, _, err := openExport(testPass, bundle)
	if err != nil {
		t.Fatalf("openExport: %v", err)
	}
	defer zero(ikey)
	if len(got) != 1 || string(got[0].totp) != "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" {
		t.Fatalf("entries = %+v", got)
	}
	// The doors do not cross: a bundle under the vault magic (and vice
	// versa) is a bad file, named before a passphrase is spent.
	if _, _, _, _, err := open(testPass, bundle); !errors.Is(err, errBadFile) {
		t.Fatalf("GVLX under the GVLT door: %v, want errBadFile", err)
	}
	vault, err := sealWithKey(fileMagic, fileVersion, key, testSalt, testNonce, testIters, entries)
	if err != nil {
		t.Fatalf("sealWithKey(GVLT): %v", err)
	}
	if _, _, _, _, err := openExport(testPass, vault); !errors.Is(err, errBadFile) {
		t.Fatalf("GVLT under the GVLX door: %v, want errBadFile", err)
	}
	// And the bundle's own wrong passphrase is the same shared refusal.
	if _, _, _, _, err := openExport([]byte("wrong"), bundle); !errors.Is(err, errUnlock) {
		t.Fatalf("wrong bundle pass: %v, want errUnlock", err)
	}
}

// v1 still reads: a body sealed at the old field set decodes with an empty
// totp, so vaults written before the card open under v2.
func TestV1DecodeStillReads(t *testing.T) {
	body := encodeBody(testEntries(), 1)
	entries, err := decodeBody(body, 1)
	if err != nil {
		t.Fatalf("v1 decodeBody: %v", err)
	}
	if len(entries) != 2 || len(entries[0].totp) != 0 {
		t.Fatalf("v1 entries = %+v", entries)
	}
	// A v1 frame end to end: header version 1 parses, the body opens.
	key, err := deriveKey(testPass, testSalt, testIters)
	if err != nil {
		t.Fatalf("deriveKey: %v", err)
	}
	defer zero(key)
	file, err := sealWithKey(fileMagic, 1, key, testSalt, testNonce, testIters, testEntries())
	if err != nil {
		t.Fatalf("sealWithKey v1: %v", err)
	}
	got, k2, _, iters, err := open(testPass, file)
	if err != nil {
		t.Fatalf("open v1 file: %v", err)
	}
	defer zero(k2)
	if iters != testIters || len(got) != 2 || string(got[0].name) != "wifi" {
		t.Fatalf("v1 open: iters=%d entries=%+v", iters, got)
	}
	// A v1 body handed to the v2 decoder is a structural lie — the count
	// and its fields are proven before a passphrase is spent either way.
	if _, err := decodeBody(body, 2); !errors.Is(err, errBadFile) {
		t.Fatalf("v1 body as v2: %v, want errBadFile", err)
	}
}

// The merge rule: new names append, a held name keeps the vault's copy and
// counts skipped — nothing is silently overwritten.
func TestMergeRules(t *testing.T) {
	m := &model{}
	m.unlocked(testEntries(), make([]byte, 32), make([]byte, 16), testIters, 0)
	imported := []entry{
		{name: []byte("wifi"), secret: []byte("attacker")}, // held name: skip
		{name: []byte("mail"), secret: []byte("letmein"), totp: []byte("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")},
		{name: []byte(""), secret: []byte("x")}, // nameless: skip
	}
	added, skipped := m.mergeEntries(imported)
	if added != 1 || skipped != 2 {
		t.Fatalf("merge = added %d skipped %d, want 1/2", added, skipped)
	}
	if len(m.entries) != 3 {
		t.Fatalf("entries = %d, want 3", len(m.entries))
	}
	if string(m.entries[0].secret) != "s3cr3t" {
		t.Fatal("the held 'wifi' entry was overwritten — the merge must keep it")
	}
	if string(m.entries[2].name) != "mail" || len(m.entries[2].totp) == 0 {
		t.Fatalf("imported entry = %+v", m.entries[2])
	}
	// The merge is name-keyed, not order-keyed: re-adding the imported name
	// now collides and skips.
	again := []entry{{name: []byte("mail"), secret: []byte("x")}}
	if a, s := m.mergeEntries(again); a != 0 || s != 1 {
		t.Fatalf("re-merge = %d/%d, want 0/1", a, s)
	}
}

// The save_state blob is the path and only the path: encode/decode round
// trip, hostile shapes refused, and nothing secret can ride it.
func TestStateBlob(t *testing.T) {
	blob := encodeState(vaultPath)
	path, ok := decodeState(blob)
	if !ok || path != vaultPath {
		t.Fatalf("round trip = %q ok=%v", path, ok)
	}
	for _, bad := range [][]byte{
		nil, []byte(""), []byte("/tmp/x"), []byte("/host/../etc"),
		[]byte("/host//double"), []byte("/host/a\nb"), []byte("gvlt"),
	} {
		if p, ok := decodeState(bad); ok {
			t.Fatalf("decodeState(%q) = %q, want refusal", bad, p)
		}
	}
	// encodeState("") is the honest empty answer.
	if encodeState("") != nil {
		t.Fatal("empty path must encode nil")
	}
}
