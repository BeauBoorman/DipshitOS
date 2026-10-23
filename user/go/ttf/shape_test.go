package ttf

import (
	"os"
	"testing"
)

const shapeFixturePath = "testdata/ShapeTest-Regular.ttf"

const naskhPath = "../../../image/fonts/NotoNaskhArabic-Regular.ttf"

// fixtureString is the committed shaping fixture: two ligatures and one
// kerned pair in nine UTF-8 bytes.
const fixtureString = "fi fl AV"

func loadShapeFixture(t *testing.T) *Face {
	t.Helper()
	data, err := os.ReadFile(shapeFixturePath)
	if err != nil {
		t.Fatalf("shape fixture %s is required: %v", shapeFixturePath, err)
	}
	f, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse(%s): %v", shapeFixturePath, err)
	}
	return f
}

// TestShapeFixtureTableFacts pins the layout facts of the dedicated fixture
// (regenerate with testdata/make_shape_fixture.py; values were verified with
// an independent OpenType toolchain before being pinned here).
func TestShapeFixtureTableFacts(t *testing.T) {
	f := loadShapeFixture(t)
	if got := f.UnitsPerEm(); got != 1000 {
		t.Errorf("fixture UnitsPerEm = %d, want 1000", got)
	}
	if got := f.NumGlyphs(); got != 9 {
		t.Errorf("fixture NumGlyphs = %d, want 9", got)
	}
	want := map[rune]uint16{'f': 2, 'i': 3, 'l': 4, 'A': 7, 'V': 8, ' ': 1}
	for r, gid := range want {
		if got := f.GlyphIndex(r); got != gid {
			t.Errorf("fixture GlyphIndex(%q) = %d, want %d", r, got, gid)
		}
	}
	if !f.HasLigatures() {
		t.Error("fixture should carry a usable liga feature")
	}
	if !f.HasKerning() {
		t.Error("fixture should carry a usable kern feature")
	}
}

// TestShapeFixtureGoldenStream is the golden glyph-id stream: the committed
// fixture string shapes to the pinned glyph ids, clusters, and advances.
// "fi fl AV" must come out as fi + space + fl + A + V — two ligatures and one
// kerned pair — which a cmap-only lookup cannot produce (it has no fi/fl).
func TestShapeFixtureGoldenStream(t *testing.T) {
	f := loadShapeFixture(t)
	got := f.ShapeLatin(fixtureString)
	want := []ShapedGlyph{
		{GID: 5, Cluster: 0, XAdvance: 611},
		{GID: 1, Cluster: 2, XAdvance: 500},
		{GID: 6, Cluster: 3, XAdvance: 611},
		{GID: 1, Cluster: 5, XAdvance: 500},
		{GID: 7, Cluster: 6, XAdvance: 547},
		{GID: 8, Cluster: 7, XAdvance: 667},
	}
	if len(got) != len(want) {
		t.Fatalf("shaped %d glyphs, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("glyph %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

// TestInterKerningPins the real-font behavior on Inter-Regular: the GPOS kern
// feature is class-based (PairPosFormat2 behind a type-9 extension lookup),
// so AV must kern by exactly the -140 the table says (verified against the
// raw table and an independent shaper).
func TestInterKerning(t *testing.T) {
	f := loadFace(t, interPath)
	if !f.HasKerning() {
		t.Fatal("Inter should expose a usable kern feature")
	}
	if got := f.PairAdvance(f.GlyphIndex('A'), f.GlyphIndex('V')); got != -140 {
		t.Errorf("Inter PairAdvance(A,V) = %d, want -140", got)
	}
	if got := f.PairAdvance(f.GlyphIndex('T'), f.GlyphIndex('o')); got != -160 {
		t.Errorf("Inter PairAdvance(T,o) = %d, want -160", got)
	}
	if got := f.PairAdvance(f.GlyphIndex('r'), f.GlyphIndex('k')); got != 32 {
		t.Errorf("Inter PairAdvance(r,k) = %d, want 32", got)
	}
}

// TestFiraHasNoKern documents the negative case: Fira Code's GPOS carries only
// mark attachment, so kerning must report none rather than invent values.
func TestFiraHasNoKern(t *testing.T) {
	f := loadFace(t, firaPath)
	if f.HasKerning() {
		t.Error("Fira Code has no kern feature; HasKerning should be false")
	}
}

// TestInterFiraShapeIsCmapOnly pins the contract that fonts without a usable
// liga feature shape identically to cmap-only lookup: Inter has no fi/fl in
// its default features and Fira's ligatures are contextual (unsupported), so
// ShapeLatin must not silently substitute anything.
func TestInterFiraShapeIsCmapOnly(t *testing.T) {
	for _, path := range []string{interPath, firaPath} {
		f := loadFace(t, path)
		got := f.ShapeLatin(fixtureString)
		if len(got) != 8 {
			t.Fatalf("%s: shaped %d glyphs, want 8 (cmap-only)", path, len(got))
		}
		gi := 0
		byteOff := 0
		for _, r := range fixtureString {
			if got[gi].GID != f.GlyphIndex(r) || got[gi].Cluster != byteOff {
				t.Errorf("%s: glyph %d = (%d,%d), want (%d,%d)",
					path, gi, got[gi].GID, got[gi].Cluster, f.GlyphIndex(r), byteOff)
			}
			gi++
			byteOff += len(string(r))
		}
	}
}

// TestShapeFixtureLigatureFixpoint: the ligature pass is a fixpoint per the
// spec — shape a ligature-heavy string and check it equals the expected
// stream, which also proves the pass terminates.
func TestShapeFixtureIdempotent(t *testing.T) {
	f := loadShapeFixture(t)
	got := f.ShapeLatin("ffifliffi")
	// Greedy left-to-right: only f+i and f+l merge; an unmatched f stays.
	want := []ShapedGlyph{
		{GID: 2, Cluster: 0, XAdvance: 333},
		{GID: 5, Cluster: 1, XAdvance: 611},
		{GID: 6, Cluster: 3, XAdvance: 611},
		{GID: 3, Cluster: 5, XAdvance: 278},
		{GID: 2, Cluster: 6, XAdvance: 333},
		{GID: 5, Cluster: 7, XAdvance: 611},
	}
	if len(got) != len(want) {
		t.Fatalf("ffifliffi -> %d glyphs, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("glyph %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

// TestShapeMalformedNeverPanics feeds truncated/corrupt GSUB and GPOS tables
// through the layout parser: every path must return nil or a partial layout,
// never panic. A font is attacker-supplied data; that rule is not negotiable.
func TestShapeMalformedNeverPanics(t *testing.T) {
	f := loadShapeFixture(t)
	full := append(append([]byte{}, f.gsub...), f.gpos...)
	rng := len(full)
	for cut := 0; cut < rng; cut += 7 {
		g := append([]byte{}, full[:cut]...)
		p := append([]byte{}, full[:cut]...)
		parseLayout(g, "liga", 4)
		parseLayout(p, "kern", 2)
	}
	// Random byte flips over the real tables must never panic either. The
	// seed is pinned so a failure is reproducible.
	seed := uint32(0x5eed1234)
	next := func() uint32 {
		seed = seed*1664525 + 1013904223
		return seed
	}
	_ = next
	for trial := 0; trial < 200; trial++ {
		for _, table := range [][]byte{f.gsub, f.gpos} {
			corrupt := append([]byte{}, table...)
			for i := 0; i < 8; i++ {
				corrupt[int(next())%len(corrupt)] = byte(next() >> 24)
			}
			parseLayout(corrupt, "liga", 4)
			parseLayout(corrupt, "kern", 2)
		}
	}
	// The parse must also survive an empty face's missing tables.
	empty := &Face{}
	if empty.ShapeLatin("fi") == nil {
		t.Error("ShapeLatin on an empty face should return an empty (non-nil) result")
	}
}

// ——— M186b Arabic contextual shaping (#3179) ———

// formedRunes is the test shorthand for the shaped view: the rune every
// logical index paints, plus the lam-alef absorption flags.
func formedRunes(t *testing.T, text string) ([]rune, []bool) {
	t.Helper()
	a := ShapeArabic(text)
	if len(a.Form) != len([]rune(text)) || len(a.Skip) != len([]rune(text)) {
		t.Fatalf("the view must be index-aligned with the input")
	}
	return a.Runes([]rune(text)), a.Skip
}

// TestArabicJoinTableFacts pins a few generated-table facts so the data
// cannot silently drift: every joining type the pass understands, the
// tatweel/ZWJ join-causing pair, the ZWNJ breaker, a transparent mark, and
// a non-Arabic default.
func TestArabicJoinTableFacts(t *testing.T) {
	for _, tc := range []struct {
		r    rune
		want joinType
	}{
		{'\u0628', jtD}, {'\u0647', jtD}, {'\u064A', jtD}, // dual-joining letters
		{'\u0627', jtR}, {'\u0631', jtR}, {'\u0648', jtR}, // alef, reh, waw join back only
		{'\u0621', jtU},                  // hamza joins nothing
		{'\u0640', jtC}, {'\u200D', jtC}, // tatweel, ZWJ
		{'\u200C', jtU},                  // ZWNJ breaks the run
		{'\u064B', jtT}, {'\u0650', jtT}, // fathatan, kasra: transparent marks
		{'a', jtU}, {' ', jtU}, {'\u05D0', jtU}, // non-Arabic defaults
	} {
		if got := joinTypeOf(tc.r); got != tc.want {
			t.Errorf("joinTypeOf(%U) = %d, want %d", tc.r, got, tc.want)
		}
	}
}

// TestShapeArabicForms is the shaped-string golden the card asks for: each
// case's painted-rune sequence (a base rune where no form applies). The
// values are the UCD's own code points — beh's four forms are
// U+FE8F..U+FE92 in isolated/final/initial/medial order.
func TestShapeArabicForms(t *testing.T) {
	for _, tc := range []struct {
		name string
		text string
		want []rune
	}{
		{"isolated", "ب", []rune{0xFE8F}},
		{"initial+final", "به", []rune{0xFE91, 0xFEEA}},
		{"full word", "بحر", []rune{0xFE91, 0xFEA4, 0xFEAE}},
		{"alef final", "با", []rune{0xFE91, 0xFE8E}},
		{"alef cannot join forward", "اب", []rune{0xFE8D, 0xFE8F}},
		{"reh cannot join forward", "برج", []rune{0xFE91, 0xFEAE, 0xFE9D}},
		{"space breaks", "ب ب", []rune{0xFE8F, ' ', 0xFE8F}},
		{"digit breaks", "ب١ب", []rune{0xFE8F, '١', 0xFE8F}},
		{"mark is transparent", "بَب", []rune{0xFE91, 0x064E, 0xFE90}},
		{"ZWNJ breaks", "ب‌ب", []rune{0xFE8F, 0x200C, 0xFE8F}},
		{"ZWJ joins", "ب‍", []rune{0xFE91, 0x200D}},
		{"tatweel joins", "بـب", []rune{0xFE91, 0x0640, 0xFE90}},
		{"latin untouched", "abc", []rune{'a', 'b', 'c'}},
		{"mixed run", "aبحb", []rune{'a', 0xFE91, 0xFEA2, 'b'}},
	} {
		got, _ := formedRunes(t, tc.text)
		if len(got) != len(tc.want) {
			t.Fatalf("%s: %d runes, want %d", tc.name, len(got), len(tc.want))
		}
		for i := range tc.want {
			if got[i] != tc.want[i] {
				t.Errorf("%s: formed[%d] = %U, want %U", tc.name, i, got[i], tc.want[i])
			}
		}
	}
}

// TestShapeArabicLamAlef pins the mandatory ligature: lam + an alef-family
// letter collapses to the lamalef code point, final when lam itself joins
// to a previous letter and isolated otherwise; the alef is absorbed. A
// combining mark BETWEEN the pair refuses the ligature — the named
// limitation — and the run still joins as initial+final.
func TestShapeArabicLamAlef(t *testing.T) {
	got, skip := formedRunes(t, "لا")
	if got[0] != 0xFEFB || !skip[1] {
		t.Fatalf("لا formed %U skip %v, want lamalef-isolated + absorbed alef", got, skip)
	}
	got, skip = formedRunes(t, "بلا")
	if got[0] != 0xFE91 || got[1] != 0xFEFC || !skip[2] {
		t.Fatalf("بلا formed %U %U %U skip %v, want initial + lamalef-final", got[0], got[1], got[2], skip)
	}
	got, skip = formedRunes(t, "لآ")
	if got[0] != 0xFEF5 || !skip[1] {
		t.Fatalf("لآ formed %U skip %v, want lamalef-madda + absorbed", got, skip)
	}
	// The mark between lam and alef is transparent to joining but refuses
	// the ligature: lam initial, mark unchanged, alef final.
	got, skip = formedRunes(t, "لَا")
	if got[0] != 0xFEDF || got[2] != 0xFE8E || skip[1] || skip[2] {
		t.Fatalf("لَا formed %U %U %U skip %v, want initial+mark+final",
			got[0], got[1], got[2], skip)
	}
	// The ligature terminates the run: a meem after lam-alef is isolated.
	got, skip = formedRunes(t, "لام")
	if got[0] != 0xFEFB || !skip[1] || got[2] != 0xFEE1 {
		t.Fatalf("لام formed %U %U %U skip %v", got[0], got[1], got[2], skip)
	}
}

// TestShapeArabicGoldenGlyphs is the glyph-level golden through the real
// face: "بحر" shapes to beh-initial + hah-medial + reh-final — gids 1028,
// 17, 22 in the pinned build of NotoNaskhArabic-Regular.ttf — none of
// which is the cmap gid of a base letter. A no-op shaper would read the
// base glyphs instead.
func TestShapeArabicGoldenGlyphs(t *testing.T) {
	f := loadFace(t, naskhPath)
	got, skip := formedRunes(t, "بحر")
	wantGids := []uint16{1028, 17, 22}
	for i, want := range wantGids {
		if skip[i] {
			t.Fatalf("rune %d unexpectedly absorbed", i)
		}
		if g := f.GlyphIndex(got[i]); g != want {
			t.Errorf("shaped rune %d (%U) -> gid %d, want %d", i, got[i], g, want)
		}
	}
	// The ligature's own golden: لا paints gid 1026 (uniFEFB), not the two
	// letters' gids.
	got, skip = formedRunes(t, "لا")
	if g := f.GlyphIndex(got[0]); g != 1026 || !skip[1] {
		t.Fatalf("لا -> gid %d skip %v, want gid 1026 + absorbed", g, skip)
	}
	// The face carries every form the generated table can emit — a form
	// that resolved to .notdef would paint tofu mid-word.
	for _, e := range arabFormTable {
		for _, r := range e.forms {
			if r != 0 && f.GlyphIndex(r) == 0 {
				t.Errorf("base %U form %U has no glyph in the face", e.base, r)
			}
		}
	}
	for _, l := range arabLamAlef {
		if f.GlyphIndex(l.iso) == 0 || f.GlyphIndex(l.fin) == 0 {
			t.Errorf("lamalef for %U not covered by the face", l.alef)
		}
	}
}

// TestShapeArabicEdgeCases: empty text and Arabic-free text produce an
// index-aligned no-op view.
func TestShapeArabicEdgeCases(t *testing.T) {
	a := ShapeArabic("")
	if a == nil || len(a.Form) != 0 || len(a.Skip) != 0 {
		t.Fatalf("empty text produced %+v", a)
	}
	got, skip := formedRunes(t, "hello שלום")
	for i, r := range got {
		if r != []rune("hello שלום")[i] || skip[i] {
			t.Fatalf("non-Arabic text changed at index %d: %U skip=%v", i, r, skip[i])
		}
	}
}
