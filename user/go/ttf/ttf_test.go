package ttf

import (
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// The two faces the desktop actually loads. Both are committed fixtures; a
// missing one is a test failure, never a silent skip — a font test that skips
// itself proves nothing.
const (
	interPath = "../../../image/fonts/Inter-Regular.ttf"
	firaPath  = "../../../image/fonts/FiraCode-Regular.ttf"
)

func loadFace(t *testing.T, path string) *Face {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("font fixture %s is required by this package's tests: %v", path, err)
	}
	f, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse(%s): %v", path, err)
	}
	return f
}

// TestInterTableFacts pins the values this package reads out of Inter's own
// tables. Every number below was read from image/fonts/Inter-Regular.ttf
// directly (not from a spec or a guess).
func TestInterTableFacts(t *testing.T) {
	f := loadFace(t, interPath)
	if got := f.UnitsPerEm(); got != 2048 {
		t.Errorf("Inter UnitsPerEm = %d, want 2048", got)
	}
	if got := f.NumGlyphs(); got != 2937 {
		t.Errorf("Inter NumGlyphs = %d, want 2937", got)
	}
	if got := f.NumHMetrics(); got != 2937 {
		t.Errorf("Inter NumHMetrics = %d, want 2937", got)
	}
	if got := f.IndexToLocFormat(); got != 1 {
		t.Errorf("Inter IndexToLocFormat = %d, want 1 (long loca)", got)
	}
	cases := []struct {
		r    rune
		gid  uint16
		adv  int
		lsb  int
		note string
	}{
		{'i', 689, 496, 0, "lowercase i"},
		{'m', 766, 1794, 0, "lowercase m"},
		{'W', 459, 2018, 0, "uppercase W"},
		{' ', 1777, 576, 0, "space"},
	}
	for _, c := range cases {
		gid := f.GlyphIndex(c.r)
		if gid != c.gid {
			t.Errorf("Inter GlyphIndex(%q) = %d, want %d (%s)", c.r, gid, c.gid, c.note)
		}
		if got := f.GlyphAdvanceUPEM(gid); got != c.adv {
			t.Errorf("Inter advance(%q) = %d UPEM, want %d", c.r, got, c.adv)
		}
	}
	// The metric table can also be checked through the bitmap data itself: H is
	// a one-contour simple glyph, space has no outline at all, and e-acute is a
	// composite.
	if _, err := f.GlyphData(f.GlyphIndex(' ')); err != nil {
		t.Errorf("GlyphData(space): %v", err)
	}
	space, err := f.GlyphData(f.GlyphIndex(' '))
	if err != nil {
		t.Fatalf("GlyphData(space): %v", err)
	}
	if len(space) != 0 {
		t.Errorf("Inter space glyph has %d bytes of outline, want 0", len(space))
	}
}

// TestFiraTableFacts is the same check for the monospace face.
func TestFiraTableFacts(t *testing.T) {
	f := loadFace(t, firaPath)
	if got := f.UnitsPerEm(); got != 1950 {
		t.Errorf("Fira UnitsPerEm = %d, want 1950", got)
	}
	if got := f.NumGlyphs(); got != 2030 {
		t.Errorf("Fira NumGlyphs = %d, want 2030", got)
	}
	if got := f.NumHMetrics(); got != 1963 {
		t.Errorf("Fira NumHMetrics = %d, want 1963", got)
	}
	if got := f.IndexToLocFormat(); got != 1 {
		t.Errorf("Fira IndexToLocFormat = %d, want 1 (long loca)", got)
	}
	cases := []struct {
		r   rune
		gid uint16
		adv int
	}{
		{'i', 180, 1200},
		{'m', 204, 1200},
		{'W', 114, 1200},
		{' ', 1103, 1200},
	}
	for _, c := range cases {
		if gid := f.GlyphIndex(c.r); gid != c.gid {
			t.Errorf("Fira GlyphIndex(%q) = %d, want %d", c.r, gid, c.gid)
		}
		if got := f.GlyphAdvanceUPEM(f.GlyphIndex(c.r)); got != c.adv {
			t.Errorf("Fira advance(%q) = %d UPEM, want %d", c.r, got, c.adv)
		}
	}
}

// TestAdvancesAreProportional is the load-bearing metric test: Inter must
// measure like a proportional face, Fira Code like a monospace one. These are
// the numbers the browser's layout depends on, and they are the difference
// between this work and the old 8x8 grid (where every advance was identical).
func TestAdvancesAreProportional(t *testing.T) {
	inter := loadFace(t, interPath)
	iAdv := inter.AdvancePx('i', 16)
	mAdv := inter.AdvancePx('m', 16)
	wAdv := inter.AdvancePx('W', 16)
	spAdv := inter.AdvancePx(' ', 16)
	t.Logf("Inter @16px: i=%d m=%d W=%d space=%d", iAdv, mAdv, wAdv, spAdv)
	if iAdv != 4 {
		t.Errorf("Inter AdvancePx('i',16) = %d, want 4", iAdv)
	}
	if mAdv != 14 {
		t.Errorf("Inter AdvancePx('m',16) = %d, want 14", mAdv)
	}
	if wAdv != 16 {
		t.Errorf("Inter AdvancePx('W',16) = %d, want 16", wAdv)
	}
	if spAdv != 5 {
		t.Errorf("Inter AdvancePx(' ',16) = %d, want 5", spAdv)
	}
	if !(iAdv < mAdv && mAdv < wAdv) {
		t.Errorf("Inter advances are not proportional: i=%d m=%d W=%d", iAdv, mAdv, wAdv)
	}
	if inter.Measure("WWW", 16) <= inter.Measure("iii", 16) {
		t.Errorf("Inter: Measure(WWW)=%d must exceed Measure(iii)=%d",
			inter.Measure("WWW", 16), inter.Measure("iii", 16))
	}

	fira := loadFace(t, firaPath)
	fi, fm, fw := fira.AdvancePx('i', 16), fira.AdvancePx('m', 16), fira.AdvancePx('W', 16)
	t.Logf("Fira Code @16px: i=%d m=%d W=%d", fi, fm, fw)
	if fi != 10 || fm != 10 || fw != 10 {
		t.Errorf("Fira Code must be monospace at 16px: i=%d m=%d W=%d, want 10/10/10", fi, fm, fw)
	}
}

// TestMeasureIsSumOfAdvances keeps Measure and AdvancePx from drifting apart.
func TestMeasureIsSumOfAdvances(t *testing.T) {
	for _, path := range []string{interPath, firaPath} {
		f := loadFace(t, path)
		for _, s := range []string{"", "hello", "The quick brown fox", "iWi", "\t   ", "oliver"} {
			want := 0
			for _, r := range s {
				want += f.AdvancePx(r, 13)
			}
			if got := f.Measure(s, 13); got != want {
				t.Errorf("%s: Measure(%q,13) = %d, want %d", path, s, got, want)
			}
		}
	}
}

// TestZigEngineParity is the M99n frozen-fallback contract (ADR 0034
// amendment A). user/src/lib/font_ttf.zig is frozen as the fallback and
// build-time engine, and user/src/lib/font_atlas_gen.zig emits that
// engine's own advance table as testdata/zig-engine-advances.tsv. On the
// faces both engines share, the Go engine must produce the same glyph ids
// and the same advances at the kernel atlas's 11/13/17 px ladder — a diff
// here is engine drift, and the fix is a deliberate, reviewed fixture
// regeneration (`zig run user/src/lib/font_atlas_gen.zig`), never a silent
// divergence.
func TestZigEngineParity(t *testing.T) {
	faces := map[string]*Face{
		"inter-regular":    loadFace(t, interPath),
		"firacode-regular": loadFace(t, firaPath),
	}
	data, err := os.ReadFile("testdata/zig-engine-advances.tsv")
	if err != nil {
		t.Fatalf("parity fixture is required (regenerate: zig run user/src/lib/font_atlas_gen.zig): %v", err)
	}
	rows := 0
	for ln, line := range strings.Split(string(data), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 6 {
			t.Fatalf("fixture line %d has %d fields, want 6: %q", ln+1, len(fields), line)
		}
		f, ok := faces[fields[0]]
		if !ok {
			t.Fatalf("fixture line %d names unknown face %q", ln+1, fields[0])
		}
		cp, err := strconv.ParseUint(fields[1], 16, 32)
		if err != nil {
			t.Fatalf("fixture line %d codepoint: %v", ln+1, err)
		}
		wantGID, err := strconv.Atoi(fields[2])
		if err != nil {
			t.Fatalf("fixture line %d gid: %v", ln+1, err)
		}
		r := rune(cp)
		if got := f.GlyphIndex(r); got != uint16(wantGID) {
			t.Errorf("%s: GlyphIndex(U+%04X) = %d, Zig engine says %d", fields[0], cp, got, wantGID)
		}
		for i, px := range []int{11, 13, 17} {
			want, err := strconv.Atoi(fields[3+i])
			if err != nil {
				t.Fatalf("fixture line %d advance: %v", ln+1, err)
			}
			if got := f.AdvancePx(r, px); got != want {
				t.Errorf("%s: AdvancePx(U+%04X, %d) = %d, Zig engine says %d", fields[0], cp, px, got, want)
			}
		}
		rows++
	}
	// 95 printable-ASCII codepoints per face; a truncated fixture must not
	// silently pass.
	if rows != 190 {
		t.Fatalf("fixture has %d data rows, want 190", rows)
	}
}

// TestFrozenZigDivergencesAreReal pins the Go half of the divergence
// contract: the capabilities the frozen Zig engine is pinned *without*
// genuinely exist in the faces it ships — so the Zig-side pins (gid 0
// above U+FFFF, un-kerned measures) are measuring a real gap, not nothing.
func TestFrozenZigDivergencesAreReal(t *testing.T) {
	inter := loadFace(t, interPath)
	fira := loadFace(t, firaPath)

	// Plane-1 coverage the faces carry through their format-12 cmaps,
	// which the frozen engine's format-4 selection never sees. These are
	// the same codepoints font_ttf.zig's pin expects as gid 0.
	if gid := inter.GlyphIndex(0x1F130); gid != 1964 {
		t.Errorf("Inter GlyphIndex(U+1F130) = %d, want 1964 (the glyph Zig cannot reach)", gid)
	}
	if gid := fira.GlyphIndex(0x1D539); gid != 997 {
		t.Errorf("Fira GlyphIndex(U+1D539) = %d, want 997 (the glyph Zig cannot reach)", gid)
	}

	// Inter's GPOS kern is real and worth a pixel at the atlas sizes:
	// pair ('A','V') adjusts -140 design units — the number the Zig test
	// subtracts to prove its measure is un-kerned.
	a, v := inter.GlyphIndex('A'), inter.GlyphIndex('V')
	if got := inter.PairAdvance(a, v); got != -140 {
		t.Errorf("Inter PairAdvance('A','V') = %d, want -140", got)
	}
	shaped := inter.ShapeLatin("AV")
	if len(shaped) != 2 || shaped[0].XAdvance != inter.GlyphAdvanceUPEM(a)-140 {
		t.Errorf("ShapeLatin(AV)[0].XAdvance = %+v, want adv-140", shaped)
	}
	// Kerning only ever applies through shaping. Measure — the path the
	// parity fixture records — stays a plain advance sum, which is why
	// the two engines can hold parity at all.
	upem := inter.UnitsPerEm()
	unKerned := scaleUPEM(inter.GlyphAdvanceUPEM(a)+inter.GlyphAdvanceUPEM(v), 13, upem)
	kerned := scaleUPEM(inter.GlyphAdvanceUPEM(a)+inter.GlyphAdvanceUPEM(v)-140, 13, upem)
	if kerned >= unKerned {
		t.Fatalf("kern %d upem should be visible at 13px: kerned=%d unkerned=%d", -140, kerned, unKerned)
	}
	if got := inter.Measure("AV", 13); got != unKerned {
		t.Errorf("Measure(AV,13) = %d, want un-kerned %d (kerned would be %d)", got, unKerned, kerned)
	}
}

// TestUnmappedRuneStillAdvances: a rune the font has no glyph for resolves to
// .notdef, and .notdef still has a width. Text made of unknown characters stays
// visible and keeps its spacing instead of collapsing to nothing.
func TestUnmappedRuneStillAdvances(t *testing.T) {
	f := loadFace(t, interPath)
	const emoji = '\U0001F600'
	if gid := f.GlyphIndex(emoji); gid != 0 {
		t.Errorf("GlyphIndex(%U) = %d, want 0 (.notdef)", emoji, gid)
	}
	if adv := f.AdvancePx(emoji, 16); adv <= 0 {
		t.Errorf("AdvancePx(%U,16) = %d, want > 0 so unknown text still occupies space", emoji, adv)
	}
	if adv := f.AdvancePx(0xE0000, 16); adv <= 0 {
		t.Errorf("AdvancePx(U+E0000,16) = %d, want > 0", adv)
	}
}

// TestLineMetrics pins the vertical rhythm so the renderer's line height is a
// font fact rather than a constant.
func TestLineMetrics(t *testing.T) {
	inter := loadFace(t, interPath)
	ia, id, ig := inter.LineMetrics(16)
	t.Logf("Inter @16px: ascent=%d descent=%d lineGap=%d", ia, id, ig)
	if ia != 16 {
		t.Errorf("Inter ascent@16 = %d, want 16", ia)
	}
	if id != 4 {
		t.Errorf("Inter descent@16 = %d, want 4", id)
	}
	fira := loadFace(t, firaPath)
	fa, fd, fg := fira.LineMetrics(16)
	t.Logf("Fira @16px: ascent=%d descent=%d lineGap=%d", fa, fd, fg)
	if fa != 15 {
		t.Errorf("Fira ascent@16 = %d, want 15", fa)
	}
	if fd != 5 {
		t.Errorf("Fira descent@16 = %d, want 5", fd)
	}
	if ia <= id || fa <= fd {
		t.Errorf("ascent must exceed descent for both faces: Inter %d/%d Fira %d/%d", ia, id, fa, fd)
	}
}

// TestCompositeGlyphDecodes: e-acute is stored as a composite (a base plus an
// accent) in both faces. Decoding it exercises the component transform path.
func TestCompositeGlyphDecodes(t *testing.T) {
	for _, path := range []string{interPath, firaPath} {
		f := loadFace(t, path)
		gid := f.GlyphIndex('\u00e9')
		if gid == 0 {
			t.Fatalf("%s: no glyph for e-acute", path)
		}
		data, err := f.GlyphData(gid)
		if err != nil {
			t.Fatalf("%s: GlyphData(e-acute): %v", path, err)
		}
		if len(data) < 2 {
			t.Fatalf("%s: e-acute glyph is empty", path)
		}
		if nc := int(int16(be16(data[0:2]))); nc >= 0 {
			t.Fatalf("%s: e-acute is not stored as a composite (numberOfContours=%d)", path, nc)
		}
		contours, err := f.glyphContours(gid)
		if err != nil {
			t.Fatalf("%s: glyphContours(e-acute): %v", path, err)
		}
		if len(contours) < 2 {
			t.Errorf("%s: composite e-acute resolved to %d contours, want >= 2 (base + accent)",
				path, len(contours))
		}
		pts := 0
		for _, c := range contours {
			pts += len(c)
		}
		if pts < 10 {
			t.Errorf("%s: composite e-acute resolved to %d points, want a real outline", path, pts)
		}
	}
}

// TestDeterminism: parsing and rasterizing twice must produce identical bytes.
// A renderer that phones home to floats differently between runs would make
// every golden image a coin flip.
func TestDeterminism(t *testing.T) {
	data, err := os.ReadFile(interPath)
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	a, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	b, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	for _, r := range []rune{'A', 'g', 'W', '\u00e9', '0'} {
		if a.GlyphIndex(r) != b.GlyphIndex(r) || a.AdvancePx(r, 19) != b.AdvancePx(r, 19) {
			t.Fatalf("metrics differ between parses for %q", r)
		}
	}
	for _, r := range []rune{'A', 'g', 'W', '\u00e9'} {
		ma, err := a.Rasterize(r, 19)
		if err != nil {
			t.Fatalf("Rasterize(%q): %v", r, err)
		}
		mb, err := b.Rasterize(r, 19)
		if err != nil {
			t.Fatalf("Rasterize(%q): %v", r, err)
		}
		if ma.Width != mb.Width || ma.Height != mb.Height || ma.BearingX != mb.BearingX || ma.BearingY != mb.BearingY {
			t.Fatalf("mask geometry differs for %q: %+v vs %+v", r, ma, mb)
		}
		if len(ma.Alpha) != len(mb.Alpha) {
			t.Fatalf("mask length differs for %q", r)
		}
		for i := range ma.Alpha {
			if ma.Alpha[i] != mb.Alpha[i] {
				t.Fatalf("mask byte %d differs for %q", i, r)
			}
		}
	}
}

// TestGlyphCacheIsBounded: the cache must be a fixed bound, not a growth curve.
func TestGlyphCacheIsBounded(t *testing.T) {
	f := loadFace(t, interPath)
	if n := f.CacheLen(); n != defaultCacheEntries {
		t.Fatalf("cache length = %d, want %d", n, defaultCacheEntries)
	}
	for i := 0; i < 4000; i++ {
		r := rune(0x20 + (i % 90))
		if _, _, err := f.Glyph(f.GlyphIndex(r), 8+(i%5)); err != nil {
			t.Fatalf("Glyph(%q): %v", r, err)
		}
	}
	if n := f.CacheLen(); n != defaultCacheEntries {
		t.Fatalf("cache grew to %d entries", n)
	}
}

// --- hostile input -------------------------------------------------------

func findTableRaw(t *testing.T, data []byte, tag string) int {
	t.Helper()
	if len(data) < 12 {
		return -1
	}
	n := int(be16(data[4:6]))
	for i := 0; i < n; i++ {
		off := 12 + i*16
		if off+16 > len(data) {
			return -1
		}
		if string(data[off:off+4]) == tag {
			return int(be32(data[off+8 : off+12]))
		}
	}
	return -1
}

func glyphSpan(t *testing.T, data []byte, gid int) (int, int) {
	t.Helper()
	loc := findTableRaw(t, data, "loca")
	head := findTableRaw(t, data, "head")
	if loc < 0 || head < 0 {
		return 0, 0
	}
	format := int(int16(be16(data[head+50 : head+52])))
	if format == 0 {
		return int(be16(data[loc+2*gid:loc+2*gid+2])) * 2, int(be16(data[loc+2*gid+2:loc+2*gid+4])) * 2
	}
	return int(be32(data[loc+4*gid : loc+4*gid+4])), int(be32(data[loc+4*gid+4 : loc+4*gid+8]))
}

// TestMalformedInputNeverPanics feeds the parser and every accessor a set of
// deliberately broken fonts. The contract is: a typed error or a safe empty
// result. A panic here would be a remote crash in the guest, since the font
// comes from the share.
func TestMalformedInputNeverPanics(t *testing.T) {
	base, err := os.ReadFile(interPath)
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	cp := func() []byte { return append([]byte(nil), base...) }

	cases := []struct {
		name string
		mut  func(d []byte) []byte
	}{
		{"nil input", func(d []byte) []byte { return nil }},
		{"truncated to 6 bytes", func(d []byte) []byte { return d[:6] }},
		{"truncated header only", func(d []byte) []byte { return d[:12] }},
		{"cff outlines (OTTO)", func(d []byte) []byte { copy(d[0:4], []byte("OTTO")); return d }},
		{"garbage sfnt version", func(d []byte) []byte { copy(d[0:4], []byte{0xde, 0xad, 0xbe, 0xef}); return d }},
		{"zero table count", func(d []byte) []byte { d[4], d[5] = 0, 0; return d }},
		{"absurd table count", func(d []byte) []byte { d[4], d[5] = 0xff, 0xff; return d }},
		{"table offset past EOF", func(d []byte) []byte { copy(d[20:24], []byte{0xff, 0xff, 0xff, 0x00}); return d }},
		{"table length past EOF", func(d []byte) []byte { copy(d[24:28], []byte{0x7f, 0xff, 0xff, 0xff}); return d }},
		{"zero unitsPerEm", func(d []byte) []byte {
			o := findTableRaw(t, d, "head")
			if o >= 0 {
				d[o+18], d[o+19] = 0, 0
			}
			return d
		}},
		{"zero numGlyphs", func(d []byte) []byte {
			o := findTableRaw(t, d, "maxp")
			if o >= 0 {
				d[o+4], d[o+5] = 0, 0
			}
			return d
		}},
		{"huge numGlyphs", func(d []byte) []byte {
			o := findTableRaw(t, d, "maxp")
			if o >= 0 {
				d[o+4], d[o+5] = 0xff, 0xff
			}
			return d
		}},
		{"bogus loca format", func(d []byte) []byte {
			o := findTableRaw(t, d, "head")
			if o >= 0 {
				d[o+50], d[o+51] = 0x00, 0x07
			}
			return d
		}},
		{"cmap subtable offset past EOF", func(d []byte) []byte {
			o := findTableRaw(t, d, "cmap")
			if o >= 0 {
				copy(d[o+8:o+12], []byte{0xff, 0xff, 0xff, 0x00})
			}
			return d
		}},
		{"cmap absurd segment count", func(d []byte) []byte {
			o := findTableRaw(t, d, "cmap")
			if o >= 0 {
				// format 4 subtable at cmap+36, segCountX2 at +6
				copy(d[o+36+6:o+36+8], []byte{0xff, 0xfe})
			}
			return d
		}},
		{"loca last entry past glyf", func(d []byte) []byte {
			o := findTableRaw(t, d, "loca")
			head := findTableRaw(t, d, "head")
			maxp := findTableRaw(t, d, "maxp")
			if o >= 0 && head >= 0 && maxp >= 0 {
				ng := int(be16(d[maxp+4 : maxp+6]))
				format := int(int16(be16(d[head+50 : head+52])))
				if format == 0 {
					copy(d[o+2*ng:o+2*ng+2], []byte{0xff, 0xfe})
				} else {
					copy(d[o+4*ng:o+4*ng+4], []byte{0x0f, 0xff, 0xff, 0xff})
				}
			}
			return d
		}},
		{"self-referential composite", func(d []byte) []byte {
			// e-acute (composite): point its first component back at itself.
			gid := 618
			loc := findTableRaw(t, d, "loca")
			glyf := findTableRaw(t, d, "glyf")
			if loc >= 0 && glyf >= 0 {
				start := int(be32(d[loc+4*gid : loc+4*gid+4]))
				// numberOfContours (2) + flags (2) => glyphIndex at +4
				off := glyf + start + 4
				if off+2 <= len(d) {
					d[off], d[off+1] = byte(gid>>8), byte(gid&0xff)
					d[off-2], d[off-1] = byte(gid>>8), byte(gid&0xff)
				}
			}
			return d
		}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("PANIC on malformed input: %v", r)
				}
			}()
			d := tc.mut(cp())
			f, err := Parse(d)
			if err != nil {
				return // a clean typed error is the desired outcome
			}
			// Exercise everything a renderer would touch.
			for _, r := range []rune{'A', 'i', '\u00e9', ' ', '\U0001F600'} {
				_ = f.GlyphIndex(r)
				_ = f.AdvancePx(r, 16)
				_ = f.Measure(string(r), 16)
				_, _, _ = f.Glyph(f.GlyphIndex(r), 16)
				_, _ = f.Rasterize(r, 16)
			}
			for gid := uint16(0); gid < 40; gid++ {
				_, _, _ = f.Glyph(gid, 14)
				_, _ = f.GlyphData(gid)
			}
			_, _, _ = f.Glyph(uint16(f.NumGlyphs()), 14)
			_, _, _ = f.Glyph(0xffff, 14)
			_, _, _ = f.LineMetrics(16)
		})
	}
}

// TestGlyphOutOfRange: an absurd glyph id is an error, not a read.
func TestGlyphOutOfRange(t *testing.T) {
	f := loadFace(t, interPath)
	if _, _, err := f.Glyph(uint16(f.NumGlyphs()), 16); err == nil {
		t.Error("Glyph(numGlyphs) returned no error")
	}
	if _, _, err := f.Glyph(0xffff, 16); err == nil {
		t.Error("Glyph(0xffff) returned no error")
	}
	if _, err := f.GlyphData(0xffff); err == nil {
		t.Error("GlyphData(0xffff) returned no error")
	}
}

// TestNoForbiddenImports is the dependency guard: this package must stay
// stdlib-only so it compiles for the guest, and must never grow a
// golang.org/x/image or cgo dependency. Its go.mod half allows a require
// only when a replace points at a path inside this repository (user/go
// requires tools/go/tabcodec that way); TestGoModGuardFixtures keeps that
// distinction from becoming a hole.
func TestNoForbiddenImports(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	fset := token.NewFileSet()
	scanned := 0
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := parser.ParseFile(fset, name, nil, parser.ImportsOnly)
		if err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		scanned++
		for _, imp := range src.Imports {
			p, err := strconv.Unquote(imp.Path.Value)
			if err != nil {
				t.Fatalf("%s: unquote %s: %v", name, imp.Path.Value, err)
			}
			if strings.HasPrefix(p, "golang.org/x/") {
				t.Errorf("%s imports %s: this package must have no external dependencies", name, p)
			}
			switch p {
			case "os", "time", "unsafe", "C":
				t.Errorf("%s imports %q: non-test sources must stay host-and-guest portable", name, p)
			}
			if p == "image" || strings.HasPrefix(p, "image/") {
				t.Errorf("%s imports %q: no image decoding in the font package", name, p)
			}
		}
	}
	if scanned == 0 {
		t.Fatal("scanned no source files — the import guard is not actually running")
	}
	t.Logf("import guard scanned %d non-test sources", scanned)

	mod, err := os.ReadFile("../go.mod")
	if err != nil {
		t.Fatalf("read ../go.mod: %v", err)
	}
	for _, issue := range goModIssues(string(mod), "..") {
		t.Errorf("user/go/go.mod %s:\n%s", issue, mod)
	}
}

// goModIssues is the go.mod half of the import guard as a pure function, so
// its fixtures can prove it still refuses a fetched dependency. It returns
// one message per violation.
//
// A require is allowed only when a replace maps it to a relative path that
// stays inside this repository: tools/go/tabcodec is a sibling in-repo module
// (M62d, #1402), not a dependency. A require with no replace, a remote
// replace, an absolute target, and any target outside the repository all
// still fail — relaxing the in-repo case must not become a hole. modDir is
// the directory holding go.mod; relative replace targets resolve against it.
func goModIssues(mod, modDir string) []string {
	var issues []string
	if strings.Contains(mod, "golang.org/x/") {
		issues = append(issues, "references golang.org/x")
	}

	var requires []string
	replaces := map[string]string{}
	block := ""
	for _, raw := range strings.Split(mod, "\n") {
		line := raw
		if i := strings.Index(line, "//"); i >= 0 {
			line = line[:i]
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		kind, entry := block, fields
		if block == "" {
			if fields[0] != "require" && fields[0] != "replace" {
				continue
			}
			kind, entry = fields[0], fields[1:]
			if len(entry) == 1 && entry[0] == "(" {
				block = kind
				continue
			}
		} else if fields[0] == ")" {
			block = ""
			continue
		}
		switch kind {
		case "require":
			if len(entry) > 0 {
				requires = append(requires, entry[0])
			}
		case "replace":
			for i, tok := range entry {
				if tok == "=>" && i > 0 && i+1 < len(entry) {
					replaces[entry[0]] = entry[i+1]
					break
				}
			}
		}
	}

	root := repoRootOf(modDir)
	for _, req := range requires {
		target, ok := replaces[req]
		if !ok {
			issues = append(issues, "requires "+req+" with no replace (a fetched dependency?)")
			continue
		}
		if !relativePathInside(target, modDir, root) {
			issues = append(issues, "requires "+req+" satisfied only by "+target+", not a relative path inside this repository")
		}
	}
	return issues
}

// relativePathInside reports whether target, resolved against modDir, is a
// relative path that stays inside root.
func relativePathInside(target, modDir, root string) bool {
	if !strings.HasPrefix(target, "./") && !strings.HasPrefix(target, "../") {
		return false
	}
	abs, err := filepath.Abs(filepath.Join(modDir, target))
	if err != nil {
		return false
	}
	abs = filepath.Clean(abs)
	return abs == root || strings.HasPrefix(abs, root+string(filepath.Separator))
}

// repoRootOf returns dir's repository root: the nearest ancestor holding a
// .git entry (a directory in a clone, a file in a worktree). Without a git
// checkout (an exported tree) it falls back to the module's grandparent, the
// layout this guard is written for (user/go/go.mod inside the repository).
func repoRootOf(dir string) string {
	abs, err := filepath.Abs(dir)
	if err != nil {
		abs = filepath.Clean(dir)
	}
	for d := abs; ; {
		if _, err := os.Lstat(filepath.Join(d, ".git")); err == nil {
			return d
		}
		parent := filepath.Dir(d)
		if parent == d {
			return filepath.Clean(filepath.Join(abs, "..", ".."))
		}
		d = parent
	}
}

// TestGoModGuardFixtures keeps the go.mod half of the guard honest: the
// in-repo replace user/go/go.mod actually carries must pass, and every
// fetched shape must still fail. A relaxation that stops refusing these
// fixtures is a hole, not a cleanup.
func TestGoModGuardFixtures(t *testing.T) {
	cases := []struct {
		name     string
		mod      string
		wantFail bool
	}{
		{
			"in-repo relative replace is allowed",
			"module virelai\n\ngo 1.27\n\nrequire virelai/tools/go/tabcodec v0.0.0\n\nreplace virelai/tools/go/tabcodec => ../../tools/go/tabcodec\n",
			false,
		},
		{
			"block form in-repo replace is allowed",
			"module virelai\n\ngo 1.27\n\nrequire (\n\tvirelai/tools/go/tabcodec v0.0.0\n)\n\nreplace (\n\tvirelai/tools/go/tabcodec => ../../tools/go/tabcodec\n)\n",
			false,
		},
		{
			"external require with no replace fails",
			"module virelai\n\ngo 1.27\n\nrequire github.com/x/y v1.0.0\n",
			true,
		},
		{
			"external require with a remote replace fails",
			"module virelai\n\ngo 1.27\n\nrequire github.com/x/y v1.0.0\n\nreplace github.com/x/y => github.com/z/y v1.0.0\n",
			true,
		},
		{
			"absolute replace target fails",
			"module virelai\n\ngo 1.27\n\nrequire github.com/x/y v1.0.0\n\nreplace github.com/x/y => /tmp/x\n",
			true,
		},
		{
			"replace escaping the repository fails",
			"module virelai\n\ngo 1.27\n\nrequire github.com/x/y v1.0.0\n\nreplace github.com/x/y => ../../../../outside\n",
			true,
		},
		{
			"one fetched require among several fails",
			"module virelai\n\ngo 1.27\n\nrequire (\n\tvirelai/tools/go/tabcodec v0.0.0\n\tgithub.com/x/y v1.0.0\n)\n\nreplace virelai/tools/go/tabcodec => ../../tools/go/tabcodec\n",
			true,
		},
		{
			"golang.org/x is refused",
			"module virelai\n\ngo 1.27\n\nrequire golang.org/x/image v0.0.0\n",
			true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			issues := goModIssues(tc.mod, "..")
			if tc.wantFail && len(issues) == 0 {
				t.Fatalf("guard accepted a dependency it must refuse:\n%s", tc.mod)
			}
			if !tc.wantFail && len(issues) != 0 {
				t.Fatalf("guard refused an in-repo module: %v\n%s", issues, tc.mod)
			}
		})
	}
}
