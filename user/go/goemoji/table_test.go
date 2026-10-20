package main

// The cmap coverage test (M146a): the picker's static table must cover
// exactly the codepoints kernel/src/font_emoji.zig ships — the font's
// cmap. A kernel-side append or removal fails here until the table
// follows, the same drift contract the compose pairs carry against
// input.zig.

import (
	"os"
	"regexp"
	"strconv"
	"testing"
)

// kernelEmojiCPs parses the `.cp = 0xXXXX` entries out of font_emoji.zig's
// emojis table, in file order. Only table rows carry `.cp =`; the file's
// test code uses lookup() calls instead, so the pattern cannot match a
// test literal.
func kernelEmojiCPs(t *testing.T) []rune {
	t.Helper()
	src, err := os.ReadFile("../../../kernel/src/font_emoji.zig")
	if err != nil {
		t.Fatalf("read kernel/src/font_emoji.zig: %v (this test only runs in-tree)", err)
	}
	re := regexp.MustCompile(`\.\{ \.cp = 0x([0-9A-Fa-f]+), \.rows =`)
	var cps []rune
	for _, m := range re.FindAllSubmatch(src, -1) {
		v, err := strconv.ParseUint(string(m[1]), 16, 21)
		if err != nil {
			t.Fatalf("font_emoji.zig cp %q: %v", m[1], err)
		}
		cps = append(cps, rune(v))
	}
	if len(cps) == 0 {
		t.Fatal("font_emoji.zig: no .cp table rows found — the parse pattern went stale")
	}
	return cps
}

func TestCmapCoverage(t *testing.T) {
	cps := kernelEmojiCPs(t)
	if len(cps) != len(glyphs) {
		t.Fatalf("kernel font covers %d codepoints, picker table carries %d", len(cps), len(glyphs))
	}
	for i, cp := range cps {
		if glyphs[i].CP != cp {
			t.Fatalf("table[%d] = U+%04X, kernel table[%d] = U+%04X (order must match)", i, glyphs[i].CP, i, cp)
		}
		if glyphs[i].Name == "" {
			t.Errorf("U+%04X has no name — it cannot be searched or tagged", cp)
		}
	}
	// No extras: every table entry resolves back to a kernel codepoint.
	kset := map[rune]bool{}
	for _, cp := range cps {
		kset[cp] = true
	}
	for _, g := range glyphs {
		if !kset[g.CP] {
			t.Errorf("picker carries U+%04X the kernel font does not cover", g.CP)
		}
	}
}

// Every glyph must paint at least one pixel — an all-zero row set is an
// empty cell masquerading as art (the kernel's own test pins the same).
func TestGlyphInk(t *testing.T) {
	for _, g := range glyphs {
		any := false
		for _, r := range g.Rows {
			if r != 0 {
				any = true
			}
		}
		if !any {
			t.Errorf("U+%04X %q paints no ink", g.CP, g.Name)
		}
	}
}

// The thumbs-down art is the kernel's vertical flip of thumbs-up — the
// sharpest structural check the kernel's own test pins.
func TestThumbsParity(t *testing.T) {
	up := glyphs[lookup(0x1F44D)]
	down := glyphs[lookup(0x1F44E)]
	for y := 0; y < 16; y++ {
		if down.Rows[y] != up.Rows[15-y] {
			t.Fatalf("row %d: thumbsdown %04x is not flipped thumbsup %04x", y, down.Rows[y], up.Rows[15-y])
		}
	}
}

// The smile is a filled disc with carved eyes — the two eye boxes the
// kernel carves stay background in the table's own art.
func TestSmileCarved(t *testing.T) {
	rows := glyphs[lookup(0x1F600)].Rows
	if rows[4]>>7&1 == 0 {
		t.Fatal("smile row 4 centre is not ink — the disc is not filled")
	}
	if rows[5]>>4&1 != 0 || rows[5]>>10&1 != 0 {
		t.Fatal("smile eyes are not carved")
	}
}

func TestLookup(t *testing.T) {
	if lookup(0x1F600) != 0 {
		t.Fatal("lookup(smiling) != 0")
	}
	if lookup(0x1F984) != -1 {
		t.Fatal("lookup found a codepoint the font does not ship")
	}
}
