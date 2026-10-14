package ttf

import (
	"crypto/sha256"
	"fmt"
	"os"
	"testing"

	"virelai/icons"
)

const chromePath = "../../../image/fonts/" + icons.FontFile

// The exact shipped binary is pinned, not just the Python drawing recipe.
// A regenerated font needs a new digest and a review of all thirty goldens.
const chromeSHA256 = "1c9f7aea8fbec2dbd76715fd4f89312089610abc24fb570fb5da9580634e937a"
const chromeLicenseSHA256 = "ea2392e36ae4638e52c695fef75a6012d784aa536667e787077ac5ca1a262ea9"

func chromeFace(t *testing.T) *Face {
	t.Helper()
	for _, asset := range []struct{ path, hash string }{
		{chromePath, chromeSHA256},
		{"../../../image/fonts/LICENSE-VirelaiChrome.txt", chromeLicenseSHA256},
	} {
		data, err := os.ReadFile(asset.path)
		if err != nil {
			t.Fatalf("required font asset %s: %v", asset.path, err)
		}
		if got := fmt.Sprintf("%x", sha256.Sum256(data)); got != asset.hash {
			t.Fatalf("%s SHA-256 = %s, want %s", asset.path, got, asset.hash)
		}
	}
	f := loadFace(t, chromePath)
	if f.UnitsPerEm() != 1000 || f.NumGlyphs() != len(icons.Inventory)+3 {
		t.Fatalf("chrome font has %d UPM, %d glyphs; want 1000, %d",
			f.UnitsPerEm(), f.NumGlyphs(), len(icons.Inventory)+3)
	}
	for i, glyph := range icons.Inventory {
		gid := f.GlyphIndex(glyph.Codepoint)
		if gid != uint16(i+3) {
			t.Fatalf("%s %U resolves to gid %d, want %d", glyph.Name, glyph.Codepoint, gid, i+3)
		}
		outline, err := f.GlyphData(gid)
		if err != nil || len(outline) == 0 {
			t.Fatalf("%s has no TrueType outline: %d bytes, %v", glyph.Name, len(outline), err)
		}
		for _, px := range []int{icons.SmallPx, icons.NominalPx, icons.LargePx} {
			if f.AdvancePx(glyph.Codepoint, px) != px {
				t.Fatalf("%s advance at %dpx = %d", glyph.Name, px, f.AdvancePx(glyph.Codepoint, px))
			}
		}
	}
	for cp := rune(0xE01E); cp <= 0xE0FF; cp++ {
		if f.GlyphIndex(cp) != 0 {
			t.Fatalf("off-contract PUA slot %U has a glyph", cp)
		}
	}
	return f
}

func paintChrome(t *testing.T, f *fb, face *Face, cp rune, px, x, baseline int) {
	t.Helper()
	m, _, err := face.Glyph(face.GlyphIndex(cp), px)
	if err != nil || m.Empty() {
		t.Fatalf("%U at %dpx has no raster: %v", cp, px, err)
	}
	Blend(f.px, f.w, f.w, f.h, x+m.BearingX, baseline-m.BearingY, m, goldenFG)
}

// Each golden carries 12px and nominal 16px. At 12px every shape must have
// visible coverage; the second size makes its construction easy to review.
func TestGoldenChromeGlyphs(t *testing.T) {
	face := chromeFace(t)
	for _, glyph := range icons.Inventory {
		t.Run(glyph.Name, func(t *testing.T) {
			f := newFB(48, 28, goldenBG)
			paintChrome(t, f, face, glyph.Codepoint, icons.SmallPx, 5, 19)
			if ink := f.count(func(v uint32) bool { return v != goldenBG }); ink < 5 {
				t.Fatalf("%s has too little ink at 12px: %d pixels", glyph.Name, ink)
			}
			paintChrome(t, f, face, glyph.Codepoint, icons.NominalPx, 26, 22)
			checkGolden(t, "virelai-chrome-"+glyph.Name, f)
		})
	}
}

// This single strip is ordered like §4, 12px on top and 16px below.
// It catches collisions, weight drift, and silhouettes which are ambiguous
// next to their neighbours even when an isolated raster passes.
func TestGoldenChromeStrip(t *testing.T) {
	face := chromeFace(t)
	const cell = 28
	f := newFB(cell*len(icons.Inventory), 45, goldenBG)
	for i, glyph := range icons.Inventory {
		x := i*cell + 8
		paintChrome(t, f, face, glyph.Codepoint, icons.SmallPx, x, 18)
		paintChrome(t, f, face, glyph.Codepoint, icons.NominalPx, x-2, 39)
	}
	checkGolden(t, "virelai-chrome-strip", f)
}
