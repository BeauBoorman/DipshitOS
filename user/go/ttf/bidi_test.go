package ttf

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

// TestBidiCharacterTestSubset runs the pinned BidiCharacterTest-17.0.0
// vectors whose code points all resolve through the covered class table and
// use no explicit formatting characters (testdata/bidi_subset.txt; the file
// header pins source, SHA-256 and the filter). Each vector is checked on all
// three outputs the card promises: paragraph level, resolved levels and the
// visual order. A missing or empty subset is a failure, never a skip — like
// the font fixtures.
func TestBidiCharacterTestSubset(t *testing.T) {
	data, err := os.ReadFile("testdata/bidi_subset.txt")
	if err != nil {
		t.Fatalf("the pinned vector subset is required: %v", err)
	}
	ran := 0
	for ln, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || line[0] == '#' {
			continue
		}
		f := strings.Split(line, ";")
		if len(f) != 5 {
			t.Fatalf("line %d: want 5 fields: %q", ln+1, line)
		}
		var cps []rune
		for _, h := range strings.Fields(f[0]) {
			n, err := strconv.ParseUint(h, 16, 21)
			if err != nil {
				t.Fatalf("line %d: bad code point %q", ln+1, h)
			}
			cps = append(cps, rune(n))
		}
		dir, _ := strconv.Atoi(strings.TrimSpace(f[1]))
		paraWant, _ := strconv.Atoi(strings.TrimSpace(f[2]))
		wantLevels := strings.Fields(f[3])
		var wantOrder []int
		for _, s := range strings.Fields(f[4]) {
			n, _ := strconv.Atoi(s)
			wantOrder = append(wantOrder, n)
		}
		v := Bidi(string(cps), dir)
		ran++
		if got := boolLevel(v.RTL); got != paraWant {
			t.Fatalf("line %d (%s): para level = %d, want %d", ln+1, line, got, paraWant)
		}
		if len(v.Levels) != len(wantLevels) {
			t.Fatalf("line %d (%s): %d levels, want %d", ln+1, line, len(v.Levels), len(wantLevels))
		}
		for i, w := range wantLevels {
			if w == "x" {
				if v.Levels[i] != 0xFF {
					t.Fatalf("line %d (%s): level[%d] = %d, want removed", ln+1, line, i, v.Levels[i])
				}
				continue
			}
			wl, _ := strconv.Atoi(w)
			if int(v.Levels[i]) != wl {
				t.Fatalf("line %d (%s): level[%d] = %d, want %d (all %v)",
					ln+1, line, i, v.Levels[i], wl, v.Levels)
			}
		}
		if len(v.Order) != len(wantOrder) {
			t.Fatalf("line %d (%s): order %v, want %v", ln+1, line, v.Order, wantOrder)
		}
		for i, w := range wantOrder {
			if v.Order[i] != w {
				t.Fatalf("line %d (%s): order %v, want %v", ln+1, line, v.Order, wantOrder)
			}
		}
	}
	if ran < 9000 {
		t.Fatalf("only %d vectors ran — the pinned subset must cover thousands", ran)
	}
	t.Logf("bidi: %d pinned BidiCharacterTest vectors passed", ran)
}

func boolLevel(rtl bool) int {
	if rtl {
		return 1
	}
	return 0
}

// visualString renders the visual form of text the way the painter does:
// walk Order, substitute mirrored brackets.
func visualString(text string, dir int) string {
	runes := []rune(text)
	v := Bidi(text, dir)
	var b strings.Builder
	for _, i := range v.Order {
		r := runes[i]
		if v.Mirror[i] != 0 {
			r = v.Mirror[i]
		}
		b.WriteRune(r)
	}
	return b.String()
}

// TestBidiMixedLine is the card's acceptance case: a mixed Latin/Hebrew line
// in an LTR paragraph reverses the Hebrew run, keeps the digits inside the
// brackets in LTR order, and mirrors the brackets so they still read as
// "opening" around the number in the RTL context.
func TestBidiMixedLine(t *testing.T) {
	text := "abc אבג (1) def"
	v := Bidi(text, BidiAuto)
	wantOrder := []int{0, 1, 2, 3, 10, 9, 8, 7, 6, 5, 4, 11, 12, 13, 14}
	if v.RTL {
		t.Error("an LTR-first line resolved RTL")
	}
	if len(v.Order) != len(wantOrder) {
		t.Fatalf("order %v, want %v", v.Order, wantOrder)
	}
	for i := range wantOrder {
		if v.Order[i] != wantOrder[i] {
			t.Fatalf("order %v, want %v", v.Order, wantOrder)
		}
	}
	// In the RTL run the parens mirror, so the painted string reads the way a
	// Hebrew reader expects: "abc (1) גבא def".
	if got, want := visualString(text, BidiAuto), "abc (1) גבא def"; got != want {
		t.Fatalf("visual %q, want %q", got, want)
	}
}

// TestBidiHebrewParagraph pins the RTL-paragraph behavior the class-B run
// probes: the first logical letter of a Hebrew run paints at the right edge
// of the line.
func TestBidiHebrewParagraph(t *testing.T) {
	v := Bidi("אבגדה", BidiAuto)
	if !v.RTL {
		t.Fatal("a Hebrew-first line must resolve to an RTL paragraph")
	}
	want := []int{4, 3, 2, 1, 0}
	for i := range want {
		if i >= len(v.Order) || v.Order[i] != want[i] {
			t.Fatalf("order %v, want %v", v.Order, want)
		}
	}
	if got, want := visualString("אבגדה", BidiAuto), "הדגבא"; got != want {
		t.Fatalf("visual %q, want %q", got, want)
	}
}

// TestBidiExplicitCodesRefused: U+202A–U+202E / U+2066–U+2069 classify as
// boundary-neutral — dropped from the visual order, marked removed in the
// levels, and carrying no directional effect. Wrap the word in an override
// and the line must resolve exactly as if it were absent.
func TestBidiExplicitCodesRefused(t *testing.T) {
	plain := Bidi("abc אבג", BidiAuto)
	wrapped := Bidi("abc \u202Eאבג\u202C", BidiAuto)
	if len(plain.Order) != len(wrapped.Order) {
		t.Fatalf("wrapped order %v differs from plain %v", wrapped.Order, plain.Order)
	}
	if len(wrapped.Order) != 7 {
		t.Fatalf("wrapped order %v — the explicit codes must not paint", wrapped.Order)
	}
	if wrapped.Levels[4] != 0xFF || wrapped.Levels[8] != 0xFF {
		t.Fatalf("explicit codes must be marked removed: %v", wrapped.Levels)
	}
	// And the explicit codes must not have set a level: the Hebrew run is
	// still level 1 in an LTR paragraph, not the level a real RLO would set.
	if wrapped.Levels[5] != 1 || wrapped.Levels[6] != 1 || wrapped.Levels[7] != 1 {
		t.Fatalf("explicit override leaked a level: %v", wrapped.Levels)
	}
}

// TestBidiNiqqudKeepsLetterLevel: a Hebrew combining mark (niqqud) takes the
// preceding letter's class under W1 and reverses with its run — it paints at
// its default advance, which the card names as the mark-positioning
// limitation.
func TestBidiNiqqudKeepsLetterLevel(t *testing.T) {
	v := Bidi("אָב", BidiAuto) // alef + hiriq + bet
	if !v.RTL || len(v.Order) != 3 {
		t.Fatalf("niqqud fragment resolved %v order %v", v.Levels, v.Order)
	}
	for i, want := range []uint8{1, 1, 1} {
		if v.Levels[i] != want {
			t.Fatalf("niqqud levels %v, want all-1", v.Levels)
		}
	}
	for i, want := range []int{2, 1, 0} {
		if v.Order[i] != want {
			t.Fatalf("niqqud order %v, want [2 1 0]", v.Order)
		}
	}
}

// TestBidiClassTable pins a few table facts so the generated data cannot
// silently drift: the coverage the card names, and the refusals it names.
func TestBidiClassTable(t *testing.T) {
	for _, tc := range []struct {
		r    rune
		want bidiClass
	}{
		{'a', bcL}, {'Z', bcL}, {'0', bcEN}, {' ', bcWS},
		{')', bcON}, {'-', bcES}, {',', bcCS}, {'$', bcET},
		{'\u05D0', bcR}, {'\uFB2A', bcR}, {'\u05B0', bcNSM}, // Hebrew + niqqud
		{'\u0627', bcAL}, {'\u0661', bcAN}, {'\u06F1', bcEN}, // Arabic + digits
		{'\u202B', bcBN}, {'\u2067', bcBN}, // refused explicit codes
		{'\u4E2D', bcL}, // outside the covered table: the L default
		{'\U0001F600', bcL},
	} {
		if got := bidiClassOf(tc.r); got != tc.want {
			t.Errorf("bidiClassOf(%U) = %d, want %d", tc.r, got, tc.want)
		}
	}
	if n := len(bidiPairOpen); n != 52 {
		t.Errorf("bidiPairOpen holds %d pairs, want the 52 covered pairs", n)
	}
}
