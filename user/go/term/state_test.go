package main

import (
	"strings"
	"testing"

	"virelai/shlib"
	"virelai/vi"
)

// newTestState returns a termState bound to a real shell (nil host —
// env/PWD never reach the seam) so save() exercises the same Pairs/Pwd
// path the app uses.
func newTestState() *termState {
	ts := &termState{}
	ts.sh = shlib.NewShell(nil, nil)
	return ts
}

// The codec is the contract the seat's AS trailer carries byte-for-byte:
// round-trip pins every field, and the decoder refuses every malformed
// shape whole — the card's "never crashes on stale/short blobs" bar.
func TestStateCodecRoundTrip(t *testing.T) {
	ts := newTestState()
	ts.sh.Env().Set("PWD", "/STATE")
	ts.sh.Env().Set("OLDPWD", "/")
	ts.sh.Env().Set("GOTERM_STATE_X", "alive-7")
	ts.alt = true
	ts.capture([]byte("line one\nline two\n"))
	ts.capture([]byte("tail=SCROLL-PROOF-LINE\nprompt> "))

	blob := ts.save()
	d, ok := decodeTermState(blob)
	if !ok {
		t.Fatalf("decode refused a well-formed blob (%d bytes)", len(blob))
	}
	if d.cwd != "/STATE" {
		t.Errorf("cwd = %q want /STATE", d.cwd)
	}
	if !d.alt {
		t.Error("alt flag did not round-trip")
	}
	want := []string{"PWD=/STATE", "OLDPWD=/", "GOTERM_STATE_X=alive-7"}
	if len(d.pairs) != len(want) {
		t.Fatalf("pairs = %v want %v", d.pairs, want)
	}
	for i := range want {
		if d.pairs[i] != want[i] {
			t.Errorf("pair %d = %q want %q", i, d.pairs[i], want[i])
		}
	}
	if string(d.scroll) != "line one\nline two\ntail=SCROLL-PROOF-LINE\nprompt> " {
		t.Errorf("scroll = %q", d.scroll)
	}
}

// Card #2927: the blob carries the active profile's name — set by a
// successful apply, read back on restore.
func TestStateCodecCarriesProfile(t *testing.T) {
	ts := newTestState()
	ts.sh.Env().Set("PWD", "/")
	ts.capture([]byte("prompt> "))
	ts.profile = "dusk"

	d, ok := decodeTermState(ts.save())
	if !ok {
		t.Fatal("decode refused a v2 blob")
	}
	if d.profile != "dusk" {
		t.Fatalf("profile = %q want dusk", d.profile)
	}
	if ts.save()[0] != termStateVersion {
		t.Fatal("blob did not tag itself v2")
	}

	// An unset name serializes empty.
	d2, ok := decodeTermState(newTestState().save())
	if !ok || d2.profile != "" {
		t.Fatalf("empty profile = %q ok=%v", d2.profile, ok)
	}
}

// A v1 blob (no profile section) still decodes — the name lands empty and
// no profile re-applies.
func TestStateDecodeV1Blob(t *testing.T) {
	// v1 layout: fmt, flags, u16 cwd | u16 envN | u32 scLen | scroll.
	v1 := []byte{1, 0}
	v1 = appendU16(v1, 4)
	v1 = append(v1, "/old"...)
	v1 = appendU16(v1, 0)
	v1 = appendU32(v1, 5)
	v1 = append(v1, "tail\n"...)
	d, ok := decodeTermState(v1)
	if !ok {
		t.Fatal("v1 blob refused")
	}
	if d.cwd != "/old" || d.profile != "" || string(d.scroll) != "tail\n" {
		t.Fatalf("v1 decode = %+v", d)
	}
}

// The v2 profile section is length-checked like every other field.
func TestStateDecodeProfileBounds(t *testing.T) {
	good := newTestState().save() // empty profile: trailing u16 0
	// Truncated profLen (scroll tail intact, u16 cut) refuses.
	if _, ok := decodeTermState(good[:len(good)-1]); ok {
		t.Error("truncated profLen accepted")
	}
	// profLen over the name bound refuses.
	bad := append(append([]byte(nil), good[:len(good)-2]...), 0xff, 0xff)
	if _, ok := decodeTermState(bad); ok {
		t.Error("over-bound profile name accepted")
	}
	// Trailing garbage after a complete v2 blob refuses.
	if _, ok := decodeTermState(append(append([]byte(nil), good...), 0)); ok {
		t.Error("trailing garbage accepted")
	}
}

func TestStateDecodeRefusesMalformed(t *testing.T) {
	good := newTestState().save()
	cases := []struct {
		name string
		blob []byte
	}{
		{"empty", nil},
		{"short header", good[:4]},
		{"wrong format byte", append([]byte{9}, good[1:]...)},
		{"truncated cwd", good[:len(good)-5]},
		{"trailing garbage", append(append([]byte(nil), good...), 0)},
	}
	for _, c := range cases {
		if _, ok := decodeTermState(c.blob); ok {
			t.Errorf("%s: decode accepted a malformed blob", c.name)
		}
	}

	// Over-declared fields against the raw framing.
	for _, b := range [][]byte{
		{termStateVersion, 0, 0xff, 0xff, 'x'},                      // cwdLen > stateCwdMax
		{termStateVersion, 0, 0, 0, 0xff, 0xff},                     // envN > stateEnvMaxN
		{termStateVersion, 0, 0, 0, 1, 0, 0xff, 0xff},               // pair len > pairMax
		{termStateVersion, 0, 0, 0, 1, 0, 4, 0, 'n', '=', 'v', 'x'}, // pair ok, scLen field missing
	} {
		if _, ok := decodeTermState(b); ok {
			t.Errorf("decode accepted %v", b)
		}
	}

	// An env pair without '=' refuses the whole blob.
	bad := []byte{termStateVersion, 0, 0, 0, 1, 0, 3, 0, 'n', 'o', 'p',
		0, 0, 0, 0}
	if _, ok := decodeTermState(bad); ok {
		t.Error("env pair without '=' accepted")
	}
}

func TestStateSaveBounds(t *testing.T) {
	ts := newTestState()
	ts.capture(make([]byte, stateScrollMax*3)) // 3x the cap
	blob := ts.save()
	if len(blob) > vi.AppStateMax {
		t.Fatalf("blob %d exceeds the %d envelope", len(blob), vi.AppStateMax)
	}
	d, ok := decodeTermState(blob)
	if !ok {
		t.Fatal("saturated blob refused")
	}
	if len(d.scroll) > stateScrollMax {
		t.Fatalf("scroll %d exceeds cap %d", len(d.scroll), stateScrollMax)
	}
}

// When the kept tail was clipped mid-line, the saved stream must not
// open mid-line: the encoder starts it right after the first LF in the
// kept window. A stream that never clipped is serialized whole — an
// unclipped head starts clean by construction.
func TestStateSaveLFAlignsTrim(t *testing.T) {
	ts := newTestState()
	// Eviction lands inside the A-run: the ring head is mid-line with a
	// LF 151 bytes in — inside the alignment window.
	ts.capture([]byte(strings.Repeat("P", 20) + "\n" +
		strings.Repeat("A", 1000) + "\n" + strings.Repeat("B", 49000)))
	blob := ts.save()
	d, ok := decodeTermState(blob)
	if !ok {
		t.Fatal("decode refused")
	}
	if len(d.scroll) == 0 || d.scroll[0] != 'B' {
		t.Fatalf("scroll head = %q — clipped mid-line fragment kept", d.scroll[:8])
	}

	fresh := newTestState()
	fresh.capture([]byte("line one\nline two\n"))
	d, ok = decodeTermState(fresh.save())
	if !ok {
		t.Fatal("decode refused")
	}
	if string(d.scroll) != "line one\nline two\n" {
		t.Fatalf("unclipped stream was trimmed: %q", d.scroll)
	}
}

// The env section is bounded by count AND bytes: an over-budget tail of
// pairs is dropped, never truncating the blob's framing.
func TestStateSaveEnvBudget(t *testing.T) {
	ts := newTestState()
	big := strings.Repeat("v", stateEnvPairMax-3)
	for i := 0; i < stateEnvMaxN; i++ {
		ts.sh.Env().Set("V"+strings.Repeat("x", 4)+vi.Itoa64(int64(i)), big)
	}
	blob := ts.save()
	if len(blob) > vi.AppStateMax {
		t.Fatalf("blob %d exceeds the %d envelope", len(blob), vi.AppStateMax)
	}
	d, ok := decodeTermState(blob)
	if !ok {
		t.Fatal("decode refused")
	}
	envBytes := 0
	for _, p := range d.pairs {
		envBytes += 2 + len(p)
	}
	if len(d.pairs) > stateEnvMaxN || envBytes > stateEnvBytes {
		t.Fatalf("env section over budget: n=%d bytes=%d", len(d.pairs), envBytes)
	}
	if len(d.pairs) == 0 {
		t.Fatal("env section dropped entirely — PWD should survive")
	}
}

func TestAltScreenScan(t *testing.T) {
	cases := []struct {
		name string
		feed []string // chunks — the directive may split across writes
		want bool
	}{
		{"plain text", []string{"hello\n"}, false},
		{"1049 enter", []string{"\x1b[?1049h"}, true},
		{"1049 leave", []string{"\x1b[?1049h", "text", "\x1b[?1049l"}, false},
		{"47 enter", []string{"\x1b[?47h"}, true},
		{"split across chunks", []string{"\x1b", "[?", "10", "49h"}, true},
		{"extra params still apply p0", []string{"\x1b[?1049;1h"}, true},
		{"?25 is not the alt flag", []string{"\x1b[?25l"}, false},
		{"non-private CSI ignored", []string{"\x1b[2J"}, false},
		{"RIS clears", []string{"\x1b[?1049h", "frame", "\x1bc"}, false},
	}
	for _, c := range cases {
		ts := &termState{}
		for _, chunk := range c.feed {
			ts.capture([]byte(chunk))
		}
		if ts.alt != c.want {
			t.Errorf("%s: alt=%v want %v", c.name, ts.alt, c.want)
		}
	}
}

func TestScrollTail(t *testing.T) {
	if got := scrollTail([]byte("")); got != "" {
		t.Errorf("empty stream tail = %q", got)
	}
	if got := scrollTail([]byte("no newline")); got != "" {
		t.Errorf("unterminated stream tail = %q", got)
	}
	got := scrollTail([]byte("first\nSCROLL-PROOF-LINE\nprompt> "))
	if got != "SCROLL-PROOF-LINE" {
		t.Errorf("tail = %q", got)
	}
	// CR stripped, controls filtered, cap enforced.
	long := strings.Repeat("x", stateTailMax+20) + "\x07\n"
	if got := scrollTail([]byte(long)); len(got) != stateTailMax {
		t.Errorf("capped tail len = %d want %d", len(got), stateTailMax)
	}
}

// applyEnv prefers the blob's cwd field, validates it against the host,
// and folds a stale path back to "/" — never leaving PWD pointing at a
// directory that does not exist.
func TestApplyEnvPrefersBlobCwd(t *testing.T) {
	ts := newTestState()
	ts.pairs = []string{"PWD=/elsewhere", "X=1"}
	ts.cwd = "/elsewhere"

	fresh := shlib.NewShell(nil, nil)
	hst := &termHost{} // host seams degrade to refusal off-guest
	got := ts.applyEnv(fresh, hst)
	// Chdir on a host test cannot reach the kernel — the validation
	// refuses and the cwd folds to the root. The env table still applied.
	if got != "/" {
		t.Fatalf("applyEnv cwd = %q want / (Chdir must fail off-guest)", got)
	}
	if v, _ := fresh.Env().Get("X"); v != "1" {
		t.Errorf("env pair X did not restore")
	}
}
