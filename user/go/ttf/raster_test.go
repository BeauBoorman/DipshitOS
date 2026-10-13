package ttf

import (
	"os"
	"strings"
	"testing"
)

// TestAntiAliasingProducesIntermediateCoverage is the anti-aliasing contract:
// a curved or oblique glyph must produce pixels that are PARTLY covered. A
// rasterizer that only ever emits 0 or 255 is a bitmap font wearing a TTF
// parser, and this test is what tells the two apart.
func TestAntiAliasingProducesIntermediateCoverage(t *testing.T) {
	face := loadFace(t, interPath)
	cases := []struct {
		r  rune
		px int
	}{
		{'W', 16}, // diagonals
		{'o', 20}, // curves
		{'A', 32}, // diagonals at a large size
		{'e', 18}, // curve plus a counter
		{'\u00e9', 24},
	}
	for _, c := range cases {
		m, err := face.Rasterize(c.r, c.px)
		if err != nil {
			t.Fatalf("Rasterize(%q,%d): %v", c.r, c.px, err)
		}
		if m.Empty() {
			t.Fatalf("Rasterize(%q,%d) produced an empty mask", c.r, c.px)
		}
		var zero, partial, opaque int
		for _, a := range m.Alpha {
			switch {
			case a == 0:
				zero++
			case a == 255:
				opaque++
			default:
				partial++
			}
		}
		t.Logf("%q @%dpx: %dx%d mask, zero=%d partial=%d opaque=%d",
			c.r, c.px, m.Width, m.Height, zero, partial, opaque)
		if partial < 12 {
			t.Errorf("%q @%dpx has only %d partially-covered pixels; the edge is not anti-aliased",
				c.r, c.px, partial)
		}
		if opaque < 5 {
			t.Errorf("%q @%dpx has only %d fully-covered pixels; the fill is broken", c.r, c.px, opaque)
		}
	}
}

// TestCounterIsHollow checks the non-zero winding fill rule: 'o' must have a
// hole. If the rasterizer used even-odd on overlapping contours, or ignored
// direction, the counter would fill in.
func TestCounterIsHollow(t *testing.T) {
	face := loadFace(t, interPath)
	m, err := face.Rasterize('o', 40)
	if err != nil {
		t.Fatalf("Rasterize(o,40): %v", err)
	}
	if m.Empty() {
		t.Fatal("o at 40px is empty")
	}
	mid := m.Height / 2
	row := m.Alpha[mid*m.Width : (mid+1)*m.Width]
	solid, hollow := 0, 0
	for _, a := range row {
		if a == 255 {
			solid++
		}
		if a <= 24 {
			hollow++
		}
	}
	t.Logf("o@40px middle row: solid=%d hollow=%d width=%d", solid, hollow, m.Width)
	if solid < 4 {
		t.Errorf("o@40px middle row has only %d solid px; the two stems are missing", solid)
	}
	if hollow < 3 {
		t.Errorf("o@40px middle row has only %d hollow px; the counter filled in", hollow)
	}
}

// TestStemIsSolidThroughTheMiddle: a straight vertical stroke must retain a
// fully opaque core, otherwise small text greys out into mush.
func TestStemIsSolidThroughTheMiddle(t *testing.T) {
	face := loadFace(t, interPath)
	m, err := face.Rasterize('l', 32)
	if err != nil {
		t.Fatalf("Rasterize(l,32): %v", err)
	}
	if m.Empty() {
		t.Fatal("l at 32px is empty")
	}
	best := 0
	for y := m.Height / 4; y < m.Height*3/4; y++ {
		run := 0
		for x := 0; x < m.Width; x++ {
			if m.Alpha[y*m.Width+x] == 255 {
				run++
			} else {
				run = 0
			}
			if run > best {
				best = run
			}
		}
	}
	t.Logf("l@32px widest opaque run in the middle half: %d px", best)
	if best < 2 {
		t.Errorf("l@32px has no solid stem core (widest opaque run %d)", best)
	}
}

// TestEmptyGlyphRasterizesToEmptyMask: space has no outline. That is a valid
// glyph, not an error, and it must produce a mask that draws nothing.
func TestEmptyGlyphRasterizesToEmptyMask(t *testing.T) {
	for _, path := range []string{interPath, firaPath} {
		face := loadFace(t, path)
		m, err := face.Rasterize(' ', 16)
		if err != nil {
			t.Fatalf("%s: Rasterize(space,16): %v", path, err)
		}
		if !m.Empty() {
			t.Errorf("%s: space produced a %dx%d mask, want empty", path, m.Width, m.Height)
		}
		blend := newFB(8, 8, goldenBG)
		Blend(blend.px, 8, 8, 8, 0, 0, m, goldenFG)
		if got := blend.count(func(v uint32) bool { return v != goldenBG }); got != 0 {
			t.Errorf("%s: blending an empty mask painted %d px", path, got)
		}
	}
}

// TestBlendClipsAndNeverPanics: the pen position comes from layout arithmetic
// on attacker-influenced text, so it can be far outside the surface.
func TestBlendClipsAndNeverPanics(t *testing.T) {
	face := loadFace(t, interPath)
	m, err := face.Rasterize('A', 24)
	if err != nil {
		t.Fatalf("Rasterize: %v", err)
	}
	placements := [][2]int{
		{-1000, -1000}, {-5, -5}, {0, 0}, {60, 40}, {63, 43}, {1000, 1000},
		{-m.Width, 0}, {0, -m.Height}, {64, -m.Height - 3},
	}
	for _, p := range placements {
		f := newFB(64, 48, goldenBG)
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("Blend at %v panicked: %v", p, r)
				}
			}()
			Blend(f.px, 64, 64, 48, p[0], p[1], m, goldenFG)
		}()
	}
	// Malformed surface descriptions are no-ops, not crashes.
	m2, _ := face.Rasterize('B', 24)
	Blend(nil, 64, 64, 48, 0, 0, m2, goldenFG)
	Blend(make([]uint32, 4), 64, 64, 48, 0, 0, m2, goldenFG)
	Blend(make([]uint32, 64*48), 0, 64, 48, 0, 0, m2, goldenFG)
	Blend(make([]uint32, 64*48), 64, 0, 0, 0, 0, m2, goldenFG)
}

// TestBlendWritesOnlyCoveredPixels: the blend must not smear the background.
func TestBlendWritesOnlyCoveredPixels(t *testing.T) {
	face := loadFace(t, interPath)
	m, err := face.Rasterize('H', 32)
	if err != nil {
		t.Fatalf("Rasterize: %v", err)
	}
	f := newFB(64, 48, goldenBG)
	const x, y = 5, 5
	Blend(f.px, 64, 64, 48, x, y, m, goldenFG)
	touched, exact := 0, 0
	for yy := 0; yy < 48; yy++ {
		for xx := 0; xx < 64; xx++ {
			inMask := xx >= x && xx < x+m.Width && yy >= y && yy < y+m.Height
			v := f.at(xx, yy)
			if v != goldenBG {
				touched++
				if !inMask {
					t.Fatalf("pixel %d,%d outside the mask was painted (%#08x)", xx, yy, v)
				}
				// A fully covered pixel is the ink colour. Blend writes an
				// opaque 0xAARRGGBB word, so compare the RGB payload.
				if v&0x00ffffff == goldenFG {
					exact++
				}
			} else if inMask {
				idx := (yy-y)*m.Width + (xx - x)
				if m.Alpha[idx] != 0 {
					t.Fatalf("mask alpha %d at %d,%d but the pixel was left untouched",
						m.Alpha[idx], xx, yy)
				}
			}
		}
	}
	t.Logf("H@32px: %d px painted, %d fully ink", touched, exact)
	if touched == 0 || exact == 0 {
		t.Fatalf("blend painted %d px (%d fully ink); expected real ink", touched, exact)
	}
}

// --- coverage blending (M99o #2192) ----------------------------------------
//
// Glyph coverage is a fraction of a pixel. Weighting the sRGB-encoded
// channels by it puts the perceptual midpoint at ~25% linear light — text on
// dark chrome looks thinner and text on a light page looks fatter. The shared
// helper weights the LINEAR-light channels instead, and every Go glyph-mask
// blend site routes through it so the whole tree renders one thing.

// TestCoverageBlendIsLinearLight pins the helper's space: half coverage must
// produce the linear-light midpoint (~0xBB), not the sRGB-space midpoint
// 0x80. The ~23% difference in the middle of the curve is the entire card.
func TestCoverageBlendIsLinearLight(t *testing.T) {
	const black, white = 0xff000000, 0xffffff
	if got := CoverageBlend(black, white, 0); got != black {
		t.Fatalf("a=0 wrote %#08x, want the destination untouched", got)
	}
	if got := CoverageBlend(black, white, 255); got&0xffffff != white {
		t.Fatalf("a=255 wrote %#08x, want exact ink", got)
	}
	half := CoverageBlend(black, white, 128) & 0xffffff
	const srgbMid = uint32(0x808080)
	t.Logf("white@128 over black -> %#06x (an sRGB-space blend writes %#06x)", half, srgbMid)
	if half <= srgbMid {
		t.Fatalf("half coverage produced %#06x, not brighter than the sRGB midpoint %#06x: the blend is not in linear light", half, srgbMid)
	}
	// The blend is symmetric: half-covered black ink over white lands at the
	// same ~0xBC (half of linear light), NOT the sRGB midpoint 0x80 that the
	// old formula produced on the light page too.
	inv := CoverageBlend(0xffffffff, 0x000000, 128) & 0xffffff
	t.Logf("black@128 over white -> %#06x", inv)
	if inv <= srgbMid {
		t.Fatalf("half coverage produced %#06x, not brighter than the sRGB midpoint", inv)
	}
	// Complementary coverage is the same blend run backwards: a coverage of
	// white over black and 255-a of black over white sum to the white page.
	for _, a := range []uint8{1, 63, 128, 191, 254} {
		l := CoverageBlend(black, white, a) & 0xffffff
		d := CoverageBlend(white, black, 255-a) & 0xffffff
		if l != d {
			t.Errorf("a=%d: white-over-black %#06x != complement %#06x", a, l, d)
		}
	}
	// Endpoints are exact for every channel value — no LUT quantization
	// error at a=0 or a=255.
	for _, v := range []uint32{0x00, 0x01, 0x7f, 0x80, 0xfe, 0xff} {
		px := v<<16 | v<<8 | v
		if got := CoverageBlend(black, px, 255) & 0xffffff; got != px {
			t.Errorf("a=255 with channel %#02x wrote %#06x", v, got)
		}
		if got := CoverageBlend(px, black, 0); got != px {
			t.Errorf("a=0 on destination %#06x wrote %#08x", px, got)
		}
	}
	// The result is always an opaque word — glyph ink never punches
	// transparency into the surface.
	if got := CoverageBlend(0x00000000, white, 100); got>>24 != 0xff {
		t.Errorf("blend wrote a translucent word %#08x", got)
	}
}

// TestEveryCoverageBlendSiteUsesTheHelper is the grep pin the card asks for:
// every file that composites a glyph mask must route through the shared
// helper (directly or via Blend), and none may keep a hand-rolled sRGB
// coverage lerp. Add a site here when the tree gains one.
func TestEveryCoverageBlendSiteUsesTheHelper(t *testing.T) {
	sites := []struct {
		path string // relative to this package dir (user/go/ttf)
		want string // substring that proves the site routes through the helper
	}{
		{"raster.go", "CoverageBlend("},                  // Blend's partial-coverage branch
		{"../draw/text.go", "ttf.CoverageBlend("},        // BufferCanvas mask fast path
		{"../browser/presentation.go", "ttf.Blend("},     // virender MaskSink
		{"../webrender/text_test.go", "ttf.Blend("},      // maskFB test sink
		{"../webrender/image_test.go", "ttf.Blend("},     // m93 reference comparator sink
	}
	for _, s := range sites {
		data, err := os.ReadFile(s.path)
		if err != nil {
			t.Fatalf("read %s: %v", s.path, err)
		}
		src := string(data)
		if !strings.Contains(src, s.want) {
			t.Errorf("%s does not call %s — the site bypasses the shared coverage blend", s.path, s.want)
		}
		// The retired formula multiplied each sRGB channel by `a` and the
		// complement by (255-a); both fragments mark a hand-rolled lerp.
		if strings.Contains(src, "*(255-a)") || strings.Contains(src, "(255-a)*") {
			t.Errorf("%s still carries an inline sRGB coverage lerp", s.path)
		}
	}
}

// TestRasterizeRejectsAbsurdCoordinates: a corrupt font can declare outline
// coordinates in the millions. The rasterizer must refuse the bitmap instead
// of allocating it.
func TestRasterizeRejectsAbsurdCoordinates(t *testing.T) {
	huge := [][]pointF{{
		{x: -1e9, y: -1e9}, {x: 1e9, y: -1e9}, {x: 0, y: 1e9},
	}}
	if m := rasterize(huge); !m.Empty() {
		t.Errorf("a 1e9-unit triangle produced a %dx%d mask", m.Width, m.Height)
	}
	nan := [][]pointF{{
		{x: 0, y: 0}, {x: 1, y: 1}, {x: 2, y: 2},
	}}
	// A degenerate three-collinear-point contour still must not panic.
	func() {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("degenerate contour panicked: %v", r)
			}
		}()
		_ = rasterize(nan)
	}()
	if m := rasterize(nil); !m.Empty() {
		t.Error("nil contours produced a non-empty mask")
	}
	if m := rasterize([][]pointF{{{x: 0, y: 0}, {x: 1, y: 1}}}); !m.Empty() {
		t.Error("a two-point contour produced a mask")
	}
}

// TestMaskGeometryMatchesMetrics: the mask's bearings must place the glyph
// where the metrics say it goes, so a renderer can lay out with AdvancePx and
// paint with BearingX/BearingY without a second source of truth.
func TestMaskGeometryMatchesMetrics(t *testing.T) {
	face := loadFace(t, interPath)
	for _, c := range []struct {
		r  rune
		px int
	}{{'H', 16}, {'i', 16}, {'W', 24}, {'g', 20}} {
		m, err := face.Rasterize(c.r, c.px)
		if err != nil {
			t.Fatalf("Rasterize(%q,%d): %v", c.r, c.px, err)
		}
		if m.Empty() {
			t.Fatalf("%q@%d empty", c.r, c.px)
		}
		adv := face.AdvancePx(c.r, c.px)
		t.Logf("%q@%d: %dx%d bearing=(%d,%d) advance=%d", c.r, c.px, m.Width, m.Height, m.BearingX, m.BearingY, adv)
		if m.BearingY <= 0 {
			t.Errorf("%q@%d: BearingY = %d, want the glyph to sit above the baseline", c.r, c.px, m.BearingY)
		}
		// The advance must be able to contain the glyph horizontally: a glyph
		// wider than double its advance means a broken metric, not a wide glyph.
		if m.Width > 2*adv+8 {
			t.Errorf("%q@%d: mask width %d is implausible against advance %d", c.r, c.px, m.Width, adv)
		}
	}
}

// TestCompositeRasterizesRealInk: the composite path must actually draw.
func TestCompositeRasterizesRealInk(t *testing.T) {
	for _, path := range []string{interPath, firaPath} {
		face := loadFace(t, path)
		base, err := face.Rasterize('e', 24)
		if err != nil {
			t.Fatalf("%s: Rasterize(e): %v", path, err)
		}
		acute, err := face.Rasterize('\u00e9', 24)
		if err != nil {
			t.Fatalf("%s: Rasterize(e-acute): %v", path, err)
		}
		baseInk, acuteInk := inkCount(base), inkCount(acute)
		t.Logf("%s: ink e=%d e-acute=%d (delta=%d)", path, baseInk, acuteInk, acuteInk-baseInk)
		if acuteInk == 0 {
			t.Fatalf("%s: e-acute rendered no ink at all", path)
		}
		if acuteInk <= baseInk {
			t.Errorf("%s: e-acute (%d ink) must carry more ink than e (%d) — the accent is missing",
				path, acuteInk, baseInk)
		}
	}
}

func inkCount(m *Mask) int {
	if m.Empty() {
		return 0
	}
	n := 0
	for _, a := range m.Alpha {
		if a > 24 {
			n++
		}
	}
	return n
}

// --- orientation and mirroring -------------------------------------------
//
// The font's design space is Y-UP and the surface is Y-DOWN, and the outline
// reader works on raw delta-encoded coordinates. Both are places a rasterizer
// silently produces a mirrored or upside-down glyph while every "there is ink"
// assertion still passes. These tests pin the orientation with letterform
// facts rather than with a pixel count.

// rowSpan returns the first and last inked column of a mask row, and whether
// the row has any ink at all.
func rowSpan(m *Mask, y int) (int, int, bool) {
	first, last := -1, -1
	for x := 0; x < m.Width; x++ {
		if m.Alpha[y*m.Width+x] > 24 {
			if first < 0 {
				first = x
			}
			last = x
		}
	}
	return first, last, first >= 0
}

// maskArt renders a mask as ASCII for a human reading the test log.
func maskArt(m *Mask) []string {
	out := make([]string, 0, m.Height)
	for y := 0; y < m.Height; y++ {
		line := make([]byte, 0, m.Width)
		for x := 0; x < m.Width; x++ {
			a := m.Alpha[y*m.Width+x]
			switch {
			case a >= 200:
				line = append(line, '#')
			case a >= 100:
				line = append(line, '+')
			case a > 24:
				line = append(line, '.')
			default:
				line = append(line, ' ')
			}
		}
		out = append(out, string(line))
	}
	return out
}

// TestUppercaseAIsNotFlipped: 'A' has a narrow apex at the TOP and a wide base
// at the BOTTOM. If the mask were vertically mirrored the widths would run the
// other way, so measure them.
func TestUppercaseAIsNotFlipped(t *testing.T) {
	face := loadFace(t, interPath)
	m, err := face.Rasterize('A', 48)
	if err != nil {
		t.Fatalf("Rasterize(A,48): %v", err)
	}
	if m.Empty() {
		t.Fatal("A at 48px is empty")
	}
	var rows []int // row index -> ink width
	for y := 0; y < m.Height; y++ {
		first, last, ok := rowSpan(m, y)
		if !ok {
			rows = append(rows, -1)
			continue
		}
		rows = append(rows, last-first+1)
	}
	firstInked, lastInked := -1, -1
	for y, w := range rows {
		if w > 0 {
			if firstInked < 0 {
				firstInked = y
			}
			lastInked = y
		}
	}
	if firstInked < 0 {
		t.Fatal("A has no ink rows")
	}
	topW := rows[firstInked]
	baseY := firstInked + (lastInked-firstInked)*4/5
	baseW := rows[baseY]
	t.Logf("A@48px: %dx%d, top row y=%d width=%d, y=%d (80%% down) width=%d",
		m.Width, m.Height, firstInked, topW, baseY, baseW)
	for _, line := range maskArt(m) {
		t.Logf("|%s|", line)
	}
	if baseW <= topW {
		t.Errorf("A is wider at the top (%d) than near the base (%d): the glyph is vertically flipped", topW, baseW)
	}
	// The widest row must be in the lower half — an apex-up A widens downward.
	maxW, maxY := 0, 0
	for y, w := range rows {
		if w > maxW {
			maxW, maxY = w, y
		}
	}
	if maxY < m.Height/2 {
		t.Errorf("A's widest row is at y=%d of %d, i.e. in the upper half: the glyph is flipped", maxY, m.Height)
	}
}

// TestUppercaseFStemIsOnTheLeft: 'F' is a heavy vertical stem on the LEFT with
// two arms reaching right. The densest column must therefore be near the left
// edge; a horizontally mirrored rasterizer would put it on the right.
func TestUppercaseFStemIsOnTheLeft(t *testing.T) {
	face := loadFace(t, interPath)
	m, err := face.Rasterize('F', 48)
	if err != nil {
		t.Fatalf("Rasterize(F,48): %v", err)
	}
	if m.Empty() {
		t.Fatal("F at 48px is empty")
	}
	col := make([]int, m.Width)
	for y := 0; y < m.Height; y++ {
		for x := 0; x < m.Width; x++ {
			if m.Alpha[y*m.Width+x] > 24 {
				col[x]++
			}
		}
	}
	bestX, best := 0, 0
	for x, n := range col {
		if n > best {
			best, bestX = n, x
		}
	}
	t.Logf("F@48px: %dx%d, densest column x=%d (%d ink px) of %d", m.Width, m.Height, bestX, best, m.Width)
	for _, line := range maskArt(m) {
		t.Logf("|%s|", line)
	}
	if bestX >= m.Width/2 {
		t.Errorf("F's densest column is at x=%d of %d, in the right half: the glyph is horizontally mirrored",
			bestX, m.Width)
	}
}

// TestCompositeAccentSitsAboveTheBody: e-acute is a composite of the base 'e'
// and an acute accent placed ABOVE the x-height. Comparing it against the bare
// 'e' at the same size isolates the accent: the composite must be strictly
// taller, the extra rows must be at the TOP, and nothing may be added below
// the baseline.
func TestCompositeAccentSitsAboveTheBody(t *testing.T) {
	face := loadFace(t, interPath)
	base, err := face.Rasterize('e', 40)
	if err != nil {
		t.Fatalf("Rasterize(e,40): %v", err)
	}
	acute, err := face.Rasterize('\u00e9', 40)
	if err != nil {
		t.Fatalf("Rasterize(e-acute,40): %v", err)
	}
	if base.Empty() || acute.Empty() {
		t.Fatal("e or e-acute rasterized to nothing")
	}
	t.Logf("e@40: %dx%d BearingY=%d below=%d", base.Width, base.Height, base.BearingY, base.Height-base.BearingY)
	t.Logf("e-acute@40: %dx%d BearingY=%d below=%d", acute.Width, acute.Height, acute.BearingY, acute.Height-acute.BearingY)
	if acute.Height <= base.Height+3 {
		t.Errorf("e-acute is %d rows tall vs e's %d: the accent was not composed onto the base",
			acute.Height, base.Height)
	}
	if acute.BearingY <= base.BearingY {
		t.Errorf("e-acute BearingY %d must exceed e's %d: the accent rises above the x-height",
			acute.BearingY, base.BearingY)
	}
	band := acute.Height - base.Height
	inkAbove := 0
	for y := 0; y < band; y++ {
		for x := 0; x < acute.Width; x++ {
			if acute.Alpha[y*acute.Width+x] > 24 {
				inkAbove++
			}
		}
	}
	t.Logf("e-acute@40: %d rows above the base letter carry %d ink px", band, inkAbove)
	if inkAbove == 0 {
		t.Errorf("the %d rows above the base letter are empty: the accent is missing", band)
	}
	if acute.Height-acute.BearingY > base.Height-base.BearingY+1 {
		t.Errorf("e-acute descends %d px below the baseline vs e's %d: the accent landed underneath",
			acute.Height-acute.BearingY, base.Height-base.BearingY)
	}
}

// TestDescenderGoesBelowTheBaseline: 'g' has a descender, so its mask must
// extend below the baseline (BearingY < Height) while 'x' — which has none —
// must not.
func TestDescenderGoesBelowTheBaseline(t *testing.T) {
	face := loadFace(t, interPath)
	g, err := face.Rasterize('g', 32)
	if err != nil {
		t.Fatalf("Rasterize(g,32): %v", err)
	}
	x, err := face.Rasterize('x', 32)
	if err != nil {
		t.Fatalf("Rasterize(x,32): %v", err)
	}
	gBelow := g.Height - g.BearingY
	xBelow := x.Height - x.BearingY
	t.Logf("g@32px: height=%d BearingY=%d belowBaseline=%d", g.Height, g.BearingY, gBelow)
	t.Logf("x@32px: height=%d BearingY=%d belowBaseline=%d", x.Height, x.BearingY, xBelow)
	if gBelow <= 0 {
		t.Errorf("g has no descender below the baseline (height %d, BearingY %d)", g.Height, g.BearingY)
	}
	if gBelow <= xBelow+2 {
		t.Errorf("g descends %d px but x descends %d px: the baseline anchoring is wrong", gBelow, xBelow)
	}
}
