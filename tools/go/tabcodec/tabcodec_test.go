package tabcodec

import (
	"bytes"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func ip(i int) *int { return &i }

// goldenA is the exact state the Zig test TWM/ST1 builds in
// user/src/tabwm.zig: tabs "Calc" (pinned, bin GOCALC.ELF) and "Files"
// (frozen, group tools), active index 0, seq 7.
func goldenA() State {
	return State{
		Active: ip(0),
		Seq:    7,
		Tabs: []Tab{
			{Title: "Calc", Flags: FlagPinned, Bin: "GOCALC.ELF"},
			{Title: "Files", Flags: FlagFrozen, Group: "tools"},
		},
	}
}

// goldenAHex is Golden A's expected byte vector, derived by hand from the
// frozen layout in user/src/tabwm.zig (NOT emitted by this package):
//
//	header     02 01 02 07 00 00     version=2 | active+1=1 | count=2 | seq=7 LE | prefs=0
//	record 0   "Calc" + 28x00 | 01 | 12x00 | "GOCALC.ELF" + 14x00
//	record 1   "Files" + 27x00 | 02 | "tools" + 7x00 | 24x00
//	           (6 + 69 + 69 = 144 bytes)
const goldenAHex = "02010207000043616c630000000000000000000000000000000000000000000000000000000001000000000000000000" +
	"000000474f43414c432e454c46000000000000000000000000000046696c657300000000000000000000000000000000" +
	"000000000000000000000002746f6f6c7300000000000000000000000000000000000000000000000000000000000000"

func goldenABytes(t *testing.T) []byte {
	t.Helper()
	b, err := hex.DecodeString(goldenAHex)
	if err != nil {
		t.Fatalf("golden hex is not valid hex: %v", err)
	}
	if len(b) != 144 {
		t.Fatalf("golden vector is %d bytes, want 144", len(b))
	}
	return b
}

// TestGoldenAEncodeParity is the byte-parity proof for the vector the Zig
// test TWM/ST1 pins: Encode(goldenA) must equal the hand-derived bytes.
func TestGoldenAEncodeParity(t *testing.T) {
	want := goldenABytes(t)
	got, err := Encode(goldenA())
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	if len(got) != HeaderBytes+2*RecordBytes {
		t.Fatalf("Encode produced %d bytes, want %d", len(got), HeaderBytes+2*RecordBytes)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("byte parity FAIL\n got %s\nwant %s", hex.EncodeToString(got), hex.EncodeToString(want))
	}

	// Field offsets, so a reader can check the layout against the Zig source.
	if got[0] != Version || got[1] != 1 || got[2] != 2 || got[3] != 7 || got[4] != 0 || got[5] != 0 {
		t.Fatalf("header bytes wrong: % x", got[:HeaderBytes])
	}
	if string(got[6:10]) != "Calc" {
		t.Fatalf("record 0 title at offset 6: %q", got[6:10])
	}
	if got[6+TitleMax] != FlagPinned {
		t.Fatalf("record 0 flags at offset %d = %#x, want %#x", 6+TitleMax, got[6+TitleMax], FlagPinned)
	}
	if string(got[6+TitleMax+1+GroupMax:6+TitleMax+1+GroupMax+10]) != "GOCALC.ELF" {
		t.Fatalf("record 0 bin misplaced")
	}
	if string(got[75:80]) != "Files" { // record 1 starts at 6+69 = 75
		t.Fatalf("record 1 must start at offset 75 with %q, got %q", "Files", got[75:80])
	}
}

// TestGoldenAFileParity checks the checked-in fixture against both the pinned
// vector and Encode's output.
func TestGoldenAFileParity(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "golden-a.tabs"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	want := goldenABytes(t)
	if !bytes.Equal(raw, want) {
		t.Fatalf("testdata/golden-a.tabs drifted from the pinned vector")
	}
	got, err := Encode(goldenA())
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	if !bytes.Equal(raw, got) {
		t.Fatalf("fixture != Encode(goldenA)")
	}
}

func maximalState() State {
	tabs := make([]Tab, MaxTabs)
	for i := range tabs {
		tabs[i] = Tab{
			Title: strings.Repeat("T", TitleMax),
			Flags: FlagPinned | FlagFrozen | FlagDock,
			Group: strings.Repeat("g", GroupMax),
			Bin:   strings.Repeat("b", BinMax),
		}
	}
	return State{Active: ip(MaxTabs - 1), Seq: 0xFFFF, Tabs: tabs}
}

func TestRoundTrip(t *testing.T) {
	cases := []struct {
		name string
		st   State
	}{
		{"goldenA", goldenA()},
		{"empty", State{Tabs: []Tab{}}},
		{"maximal", maximalState()},
		{"prefs passthrough", State{Prefs: 3, Active: ip(0), Tabs: []Tab{{Title: "X"}}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			b, err := Encode(tc.st)
			if err != nil {
				t.Fatalf("Encode: %v", err)
			}
			if len(b) > MaxBytes {
				t.Fatalf("%d bytes exceeds MaxBytes (%d)", len(b), MaxBytes)
			}
			got, err := Decode(b)
			if err != nil {
				t.Fatalf("Decode: %v", err)
			}
			if !reflect.DeepEqual(got, tc.st) {
				t.Fatalf("round trip mismatch\n got %+v\nwant %+v", got, tc.st)
			}
		})
	}
}

func TestEmptyStateIsSixBytes(t *testing.T) {
	b, err := Encode(State{})
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	if len(b) != HeaderBytes {
		t.Fatalf("empty state encoded to %d bytes, want %d", len(b), HeaderBytes)
	}
	st, err := Decode(b)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if st.Count() != 0 {
		t.Fatalf("count = %d, want 0", st.Count())
	}
	if _, ok := st.ActiveIndex(); ok {
		t.Fatalf("active must be unset for byte 1 == 0")
	}
}

// TestDecodeRejectsV1 mirrors Zig TWM/ST3: a v1 file (3-byte header
// [version=1, active+1, count] + 32-byte title records) still parses with the
// Zig v1 reader, and the v2 parser classifies it as a version mismatch. This
// package is v2-only by design, so Decode must refuse it.
func TestDecodeRejectsV1(t *testing.T) {
	const titleMax = 32
	v1 := make([]byte, 3+titleMax)
	v1[0], v1[1], v1[2] = 1, 1, 1
	copy(v1[3:], "Legacy")
	if _, err := Decode(v1); err == nil {
		t.Fatalf("a v1 buffer must be refused")
	} else if !errors.Is(err, ErrBadVersion) {
		t.Fatalf("v1 refusal error = %v, want ErrBadVersion", err)
	}
	// A v2 file must also not be mistaken for anything else by the version byte.
	v2 := goldenABytes(t)
	if v2[0] != 2 {
		t.Fatalf("Golden A version byte = %d", v2[0])
	}
}

// TestDecodeRejectionTable mirrors Zig TWM/ST4 plus the short-buffer cases.
func TestDecodeRejectionTable(t *testing.T) {
	base := goldenABytes(t)
	mut := func(f func(b []byte)) []byte {
		b := append([]byte(nil), base...)
		f(b)
		return b
	}
	cases := []struct {
		name string
		in   []byte
		want error
	}{
		{"nil buffer", nil, ErrShortHeader},
		{"empty buffer", []byte{}, ErrShortHeader},
		{"four bytes", base[:4], ErrShortHeader},
		{"short header", mut(func(b []byte) {}), ErrShortHeader},
		{"header only, count 1", []byte{2, 1, 1, 0, 0, 0}, ErrShortBody},
		{"truncated final record", base[:len(base)-1], ErrShortBody},
		{"count over max", mut(func(b []byte) { b[2] = MaxTabs + 1 }), ErrCountTooLarge},
		{"active out of range", mut(func(b []byte) { b[1] = 9 }), ErrActiveOutOfRange},
		{"active with zero tabs", []byte{2, 1, 0, 0, 0, 0}, ErrActiveOutOfRange},
		{"wrong version", mut(func(b []byte) { b[0] = 9 }), ErrBadVersion},
		{"v1 version byte", mut(func(b []byte) { b[0] = 1 }), ErrBadVersion},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var in []byte
			if tc.name == "short header" {
				in = base[:HeaderBytes-1]
			} else {
				in = tc.in
			}
			_, err := Decode(in)
			if err == nil {
				t.Fatalf("Decode accepted a malformed buffer")
			}
			if !errors.Is(err, tc.want) {
				t.Fatalf("err = %v, want %v", err, tc.want)
			}
			if !errors.Is(err, ErrCorrupt) {
				t.Fatalf("every rejection must wrap ErrCorrupt, got %v", err)
			}
		})
	}
}

// TestDecodeAcceptsTrailingBytes: the Zig parser only enforces the minimum
// length, so bytes after the last record are ignored.
func TestDecodeAcceptsTrailingBytes(t *testing.T) {
	base := goldenABytes(t)
	padded := append(append([]byte(nil), base...), 0xde, 0xad, 0xbe, 0xef, 0x00, 0x11, 0x22)
	st, err := Decode(padded)
	if err != nil {
		t.Fatalf("Decode with trailing bytes: %v", err)
	}
	if !reflect.DeepEqual(st, goldenA()) {
		t.Fatalf("trailing bytes changed the decoded state: %+v", st)
	}
}

func TestFixedFieldBoundaries(t *testing.T) {
	// A field exactly at max width has no NUL and must decode in full.
	full := State{Active: ip(0), Tabs: []Tab{{Title: strings.Repeat("t", TitleMax), Group: strings.Repeat("g", GroupMax), Bin: strings.Repeat("b", BinMax)}}}
	b, err := Encode(full)
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	got, err := Decode(b)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if got.Tabs[0].Title != strings.Repeat("t", TitleMax) || got.Tabs[0].Group != strings.Repeat("g", GroupMax) || got.Tabs[0].Bin != strings.Repeat("b", BinMax) {
		t.Fatalf("max-width fields did not survive: %+v", got.Tabs[0])
	}

	// An embedded NUL truncates the field (readFixed stops at the first NUL).
	custom := make([]byte, HeaderBytes+RecordBytes)
	custom[0], custom[1], custom[2] = Version, 1, 1
	copy(custom[HeaderBytes:HeaderBytes+TitleMax], "AB\x00CD")
	st, err := Decode(custom)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if st.Tabs[0].Title != "AB" {
		t.Fatalf("embedded NUL: title = %q, want %q", st.Tabs[0].Title, "AB")
	}

	// Over-wide input is truncated silently, exactly like the Zig writer.
	over, err := Encode(State{Tabs: []Tab{{Title: strings.Repeat("x", TitleMax+5)}}})
	if err != nil {
		t.Fatalf("Encode over-wide: %v", err)
	}
	back, err := Decode(over)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if len(back.Tabs[0].Title) != TitleMax {
		t.Fatalf("over-wide title = %d bytes, want %d", len(back.Tabs[0].Title), TitleMax)
	}
}

func TestEncodeRejectsUnrepresentable(t *testing.T) {
	many := State{Tabs: make([]Tab, MaxTabs+1)}
	if _, err := Encode(many); !errors.Is(err, ErrTooManyTabs) {
		t.Fatalf("17 tabs: err = %v, want ErrTooManyTabs", err)
	}
	if _, err := Encode(State{Active: ip(5), Tabs: make([]Tab, 2)}); !errors.Is(err, ErrActiveOutOfRange) {
		t.Fatalf("active 5 of 2: err = %v, want ErrActiveOutOfRange", err)
	}
	if _, err := Encode(State{Active: ip(-1), Tabs: make([]Tab, 2)}); !errors.Is(err, ErrActiveOutOfRange) {
		t.Fatalf("active -1: err = %v, want ErrActiveOutOfRange", err)
	}
}

// TestDecodeIsTotal sweeps every truncation and every single-byte mutation of
// the golden vector: Decode must return (State, error) and never panic.
func TestDecodeIsTotal(t *testing.T) {
	base := goldenABytes(t)
	for i := 0; i <= len(base); i++ {
		if _, err := Decode(base[:i]); err != nil && !errors.Is(err, ErrCorrupt) {
			t.Fatalf("truncation %d: unexpected error class %v", i, err)
		}
	}
	for v := 0; v < 256; v++ {
		for i := 0; i < len(base); i++ {
			b := append([]byte(nil), base...)
			b[i] = byte(v)
			if _, err := Decode(b); err != nil && !errors.Is(err, ErrCorrupt) {
				t.Fatalf("mutation %d=%d: unexpected error class %v", i, v, err)
			}
		}
	}
	if _, err := Decode(nil); !errors.Is(err, ErrShortHeader) {
		t.Fatalf("nil: %v", err)
	}
}

// M125a (#2586): the app_state trailer — byte identity with the guest
// codec and per-entry corruption refusal.
func TestEncodeDecodeAppStates(t *testing.T) {
	s := State{
		Seq: 1,
		Tabs: []Tab{
			{Title: "A", Bin: "A.ELF", AppState: []byte("blob-a"), AppStateVer: 5},
			{Title: "B", Bin: "B.ELF"},
			{Title: "C", Bin: "C.ELF", AppState: []byte("blob-c"), AppStateVer: 9},
		},
	}
	raw, err := Encode(s)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	if string(got.Tabs[0].AppState) != "blob-a" || got.Tabs[0].AppStateVer != 5 ||
		got.Tabs[1].AppState != nil ||
		string(got.Tabs[2].AppState) != "blob-c" || got.Tabs[2].AppStateVer != 9 {
		t.Fatalf("trailer round-trip = %+v", got.Tabs)
	}
	// A blob over AppStateMax is an Encode error, never a written file.
	if _, err := Encode(State{Tabs: []Tab{{Title: "X", AppState: make([]byte, AppStateMax+1)}}}); err == nil {
		t.Fatal("Encode wrote an over-cap blob")
	}
	// Exactly AppStateMax still fits the file cap.
	if _, err := Encode(State{Tabs: []Tab{{Title: "X", AppState: make([]byte, AppStateMax)}}}); err != nil {
		t.Fatalf("Encode refused exactly AppStateMax: %v", err)
	}
	// Corrupt the trailer's declared count: an entry pointing outside the
	// records fails the decode as corrupt, not as a partial read.
	hdr := HeaderBytes + 3*RecordBytes
	raw[hdr+AppStateHdr] = 99
	if _, err := Decode(raw); err == nil {
		t.Fatal("orphaned app_state index decoded")
	}
	// Foreign magic: ignored wholesale, records still decode.
	raw2, _ := Encode(s)
	raw2[hdr] = 'X'
	got2, err := Decode(raw2)
	if err != nil || got2.Tabs[0].AppState != nil {
		t.Fatalf("foreign section err=%v state=%x", err, got2.Tabs[0].AppState)
	}
}
