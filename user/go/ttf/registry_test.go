package ttf

import (
	"errors"
	"os"
	"strings"
	"testing"
)

// regFaces parses each shipped fixture once per test, so a *Face identity is
// stable inside the test and a chain's Piece can be compared by pointer.
func regFaces(t *testing.T) map[string]*Face {
	t.Helper()
	return map[string]*Face{
		"INTER.TTF":    loadFace(t, interPath),
		"INTERB.TTF":   loadFace(t, "../../../image/fonts/Inter-Bold.ttf"),
		"INTERI.TTF":   loadFace(t, "../../../image/fonts/Inter-Italic.ttf"),
		"INTERBI.TTF":  loadFace(t, "../../../image/fonts/Inter-BoldItalic.ttf"),
		"FIRACODE.TTF": loadFace(t, firaPath),
		"CHROME.TTF":   loadFace(t, chromePath),
		"NOTOSERF.TTF": loadFace(t, "../../../image/fonts/NotoSerif-Regular.ttf"),
		"NOTOHEB.TTF":  loadFace(t, "../../../image/fonts/NotoSansHebrew-Regular.ttf"),
	}
}

// fixtureLoader serves manifest share names out of faces and records every
// file it is asked for — the witness for the lazy-load rules.
func fixtureLoader(t *testing.T, faces map[string]*Face) (Loader, *[]string) {
	t.Helper()
	var reads []string
	return func(file string) (*Face, error) {
		reads = append(reads, file)
		f := faces[file]
		if f == nil {
			return nil, errors.New("no such staged face")
		}
		return f, nil
	}, &reads
}

func parseOK(t *testing.T, manifest string) []FaceSpec {
	t.Helper()
	specs, err := ParseManifest([]byte(manifest))
	if err != nil {
		t.Fatalf("manifest refused: %v\n%s", err, manifest)
	}
	return specs
}

func TestManifestParsesShippedShape(t *testing.T) {
	data, err := os.ReadFile("../../../image/fonts/fonts.txt")
	if err != nil {
		t.Fatalf("the shipped manifest is required: %v", err)
	}
	specs, err := ParseManifest(data)
	if err != nil {
		t.Fatalf("the shipped manifest must parse: %v", err)
	}
	// The four faces the hard-coded path reads must resolve to the same
	// selections the manifest assigns them, plus the M99m coverage faces and
	// the M99o bold-italic: NOTOSERF is both the serif role's primary and the
	// ui cascade's tail, NOTOCJK trails the symbol faces so every chain
	// reaches it last, and INTERBI is the one row carrying weight=700 AND
	// style=italic. M178a adds NOTOHEB as the ui cascade's Hebrew tail at
	// order=6, after the styled rows.
	want := []FaceSpec{
		{File: "INTER.TTF", Role: "ui", Order: 1, Weight: 400},
		{File: "INTERB.TTF", Role: "ui", Order: 2, Weight: 700},
		{File: "INTERI.TTF", Role: "ui", Order: 3, Weight: 400, Italic: true},
		{File: "NOTOSERF.TTF", Role: "ui", Order: 4, Weight: 400},
		{File: "INTERBI.TTF", Role: "ui", Order: 5, Weight: 700, Italic: true},
		{File: "NOTOHEB.TTF", Role: "ui", Order: 6, Weight: 400},
		{File: "FIRACODE.TTF", Role: "mono", Order: 1, Weight: 400},
		{File: "NOTOSERF.TTF", Role: "serif", Order: 1, Weight: 400},
		{File: "CHROME.TTF", Role: "symbol", Order: 1, Weight: 400},
		{File: "NOTOCJK.TTF", Role: "symbol", Order: 2, Weight: 400},
	}
	if len(specs) != len(want) {
		t.Fatalf("shipped manifest decoded %d rows, want %d", len(specs), len(want))
	}
	for i, s := range specs {
		if w := want[i]; s != w {
			t.Errorf("row %d decoded %+v, want %+v", i, s, w)
		}
	}
}

func TestManifestRefusals(t *testing.T) {
	for _, tc := range []struct {
		name     string
		manifest string
		want     string
	}{
		{"empty", "# only comments\n", "no face rows"},
		{"no fields", "INTER.TTF\n", "no role="},
		{"bad role", "INTER.TTF | role=side\n", `unknown role "side"`},
		{"bad order", "INTER.TTF | role=ui | order=x\n", "order is not a number"},
		{"bad weight", "INTER.TTF | role=ui | weight=heavy\n", "weight is not a positive number"},
		{"bad style", "INTER.TTF | role=ui | style=oblique\n", `unknown style "oblique"`},
		{"empty file", " | role=ui\n", "missing or invalid face file name"},
		{"path file", "../X.TTF | role=ui\n", "missing or invalid face file name"},
		{"spaced file", "A B.TTF | role=ui\n", "missing or invalid face file name"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := ParseManifest([]byte(tc.manifest))
			if err == nil {
				t.Fatalf("manifest accepted:\n%s", tc.manifest)
			}
			me, ok := err.(*ManifestError)
			if !ok {
				t.Fatalf("error type %T, want *ManifestError", err)
			}
			if !strings.Contains(err.Error(), "fonts.txt: line") || !strings.Contains(me.Why, strings.TrimSuffix(tc.want, `"`)) {
				// The refusal names the file and the problem.
				if !strings.Contains(err.Error(), "fonts.txt") {
					t.Fatalf("refusal does not name fonts.txt: %v", err)
				}
			}
			t.Logf("%s refused as: %v", tc.name, err)
		})
	}
	// Over the row cap refuses.
	big := strings.Repeat("X.TTF | role=ui\n", maxManifestFaces+1)
	if _, err := ParseManifest([]byte(big)); err == nil {
		t.Fatal("a manifest past the face cap was accepted")
	}
}

func TestManifestAdditiveKeysAndDefaults(t *testing.T) {
	specs := parseOK(t, "A.TTF | role=ui | hint=none | order=4\nB.TTF | role=ui | order=2\n")
	if specs[0].Order != 4 || specs[0].Weight != 400 || specs[0].Italic {
		t.Errorf("defaults wrong: %+v", specs[0])
	}
	if specs[1].Order != 2 {
		t.Errorf("order not decoded: %+v", specs[1])
	}
}

// coveredOnlyBy finds a rune cover covers that every face in exclude lacks —
// the card's "diff the cmaps" rule, so no codepoint is hard-coded.
func coveredOnlyBy(t *testing.T, cover *Face, exclude ...*Face) rune {
	t.Helper()
	for cp := rune(0x20); cp <= 0x2FFFF; cp++ {
		if cover.GlyphIndex(cp) == 0 {
			continue
		}
		uniq := true
		for _, f := range exclude {
			if f.GlyphIndex(cp) != 0 {
				uniq = false
				break
			}
		}
		if uniq {
			return cp
		}
	}
	t.Fatal("no rune exists that only the covering face maps")
	return 0
}

// uncoveredRune finds a codepoint no listed face maps — the rune that walks a
// whole cascade and lands on .notdef.
func uncoveredRune(t *testing.T, faces ...*Face) rune {
	t.Helper()
	for cp := rune(0x20); cp <= 0x2FFFF; cp++ {
		mapped := false
		for _, f := range faces {
			if f.GlyphIndex(cp) != 0 {
				mapped = true
				break
			}
		}
		if !mapped {
			return cp
		}
	}
	t.Fatal("every rune in the scan range is covered")
	return 0
}

func TestCascadeOrderIsPrimaryRoleThenSymbols(t *testing.T) {
	// Four faces over two roles: the ui cascade must be primary, the role's
	// other faces in order, then the symbols — and each face is read in that
	// order on a miss, never ahead of it. The mono face is another role and
	// must not be consulted at all.
	faces := regFaces(t)
	load, reads := fixtureLoader(t, faces)
	specs := parseOK(t,
		"FIRACODE.TTF | role=mono | order=1\n"+
			"INTER.TTF | role=ui | order=3\n"+
			"INTERB.TTF | role=ui | order=1\n"+
			"INTERI.TTF | role=ui | order=2\n"+
			"CHROME.TTF | role=symbol | order=1\n")
	reg := NewRegistry(specs, load)
	// No row declares weight=, so a bold query's strict match fails and the
	// chain's primary is the role's first normal face — INTERB at order 1.
	bold := reg.Chain(Query{Role: "ui", Bold: true})
	if got := bold.Primary(); got != faces["INTERB.TTF"] {
		t.Fatal("bold chain's primary is not the role's first normal face")
	}
	if len(*reads) != 1 || (*reads)[0] != "INTERB.TTF" {
		t.Fatalf("primary load read %v, want [INTERB.TTF]", *reads)
	}
	// A rune nothing covers walks the whole cascade in order.
	miss := uncoveredRune(t, faces["INTER.TTF"], faces["INTERB.TTF"],
		faces["INTERI.TTF"], faces["CHROME.TTF"])
	_ = bold.Split("A" + string(miss) + " B")
	want := []string{"INTERB.TTF", "INTERI.TTF", "INTER.TTF", "CHROME.TTF"}
	if len(*reads) != len(want) {
		t.Fatalf("cascade read %v, want %v", *reads, want)
	}
	for i := range want {
		if (*reads)[i] != want[i] {
			t.Fatalf("cascade read %v, want %v", *reads, want)
		}
	}
	if reg.Notdef() == 0 {
		t.Error("an uncovered rune was not counted")
	}
}

func TestCascadeStopsAtCoverage(t *testing.T) {
	faces := regFaces(t)
	load, reads := fixtureLoader(t, faces)
	specs := parseOK(t,
		"INTER.TTF | role=ui | order=1\n"+
			"INTERB.TTF | role=ui | order=2\n"+
			"CHROME.TTF | role=symbol | order=1\n")
	reg := NewRegistry(specs, load)
	ui := reg.Chain(Query{Role: "ui"})
	// A rune only the symbol face covers must reach it — and reading the
	// same-role row first is the order the cascade asserts.
	r := coveredOnlyBy(t, faces["CHROME.TTF"], faces["INTER.TTF"], faces["INTERB.TTF"])
	pieces := ui.Split("H" + string(r) + "H")
	if len(pieces) != 3 || pieces[0].Text != "H" || pieces[1].Text != string(r) || pieces[2].Text != "H" {
		t.Fatalf("split = %+v", pieces)
	}
	if pieces[0].Face != faces["INTER.TTF"] || pieces[1].Face != faces["CHROME.TTF"] ||
		pieces[2].Face != faces["INTER.TTF"] {
		t.Fatal("piece faces are not primary, symbol, primary")
	}
	want := []string{"INTER.TTF", "INTERB.TTF", "CHROME.TTF"}
	if len(*reads) != len(want) {
		t.Fatalf("reads %v, want %v", *reads, want)
	}
	for i := range want {
		if (*reads)[i] != want[i] {
			t.Fatalf("reads %v, want %v", *reads, want)
		}
	}
	if reg.Notdef() != 0 {
		t.Errorf("a covered fallback rune counted as notdef (%d)", reg.Notdef())
	}
}

func TestLazyFallbackFacesOnlyLoadOnMiss(t *testing.T) {
	faces := regFaces(t)
	load, reads := fixtureLoader(t, faces)
	specs := parseOK(t,
		"INTER.TTF | role=ui | order=1\n"+
			"INTERB.TTF | role=ui | order=2\n"+
			"CHROME.TTF | role=symbol | order=1\n")
	reg := NewRegistry(specs, load)
	ui := reg.Chain(Query{Role: "ui"})
	// A run with no misses — the "page with no misses reads only the primary
	// faces" rule — must not even try the other slots.
	ui.Split("plain ASCII prose, all covered")
	ui.Measure("plain ASCII prose, all covered", 13)
	if len(*reads) != 1 || (*reads)[0] != "INTER.TTF" {
		t.Fatalf("a no-miss run read %v, want just INTER.TTF", *reads)
	}
	if reg.Notdef() != 0 {
		t.Errorf("covered run counted misses: %d", reg.Notdef())
	}
}

func TestNotdefCountsAndPaintsThePrimary(t *testing.T) {
	faces := regFaces(t)
	load, _ := fixtureLoader(t, faces)
	specs := parseOK(t,
		"INTER.TTF | role=ui | order=1\n"+
			"FIRACODE.TTF | role=mono | order=1\n")
	reg := NewRegistry(specs, load)
	var reports []int
	reg.OnNotdef = func(n int) { reports = append(reports, n) }
	ui := reg.Chain(Query{Role: "ui"})
	// A codepoint chrome has but the chain's faces do not — mono is another
	// role and must never be consulted, so this still lands on notdef.
	miss := coveredOnlyBy(t, faces["CHROME.TTF"], faces["INTER.TTF"])
	pieces := ui.Split("x" + string(miss))
	if len(pieces) != 1 || pieces[0].Face != faces["INTER.TTF"] {
		t.Fatalf("a missed rune must stay on the primary face: %+v", pieces)
	}
	if reg.Notdef() != 1 || len(reports) != 1 || reports[0] != 1 {
		t.Fatalf("notdef=%d reports=%v, want one counted miss", reg.Notdef(), reports)
	}
}

func TestControlRunesNeverCascade(t *testing.T) {
	faces := regFaces(t)
	load, reads := fixtureLoader(t, faces)
	specs := parseOK(t,
		"INTER.TTF | role=ui | order=1\n"+
			"CHROME.TTF | role=symbol | order=1\n")
	reg := NewRegistry(specs, load)
	ui := reg.Chain(Query{Role: "ui"})
	pieces := ui.Split("a\tb\x07c")
	for _, p := range pieces {
		if p.Face != faces["INTER.TTF"] {
			t.Fatalf("control runes left the primary face: %+v", pieces)
		}
	}
	if reg.Notdef() != 0 {
		t.Error("a tab or bell must not count as a miss")
	}
	if len(*reads) != 1 {
		t.Fatalf("control runes loaded extra faces: %v", *reads)
	}
}

func TestChainSelectionAndPrimary(t *testing.T) {
	faces := regFaces(t)
	load, _ := fixtureLoader(t, faces)
	specs := parseOK(t,
		"INTER.TTF | role=ui | order=1\n"+
			"INTERB.TTF | role=ui | order=2 | weight=700\n"+
			"INTERI.TTF | role=ui | order=3 | style=italic\n"+
			"FIRACODE.TTF | role=mono | order=1\n")
	reg := NewRegistry(specs, load)
	if got := reg.Primary(Query{Role: "ui"}); got != faces["INTER.TTF"] {
		t.Error("default ui primary is not the normal face")
	}
	if got := reg.Primary(Query{Role: "ui", Bold: true}); got != faces["INTERB.TTF"] {
		t.Error("bold ui primary is not the weight=700 face")
	}
	if got := reg.Primary(Query{Role: "ui", Italic: true}); got != faces["INTERI.TTF"] {
		t.Error("italic ui primary is not the style=italic face")
	}
	if got := reg.Primary(Query{Role: "mono"}); got != faces["FIRACODE.TTF"] {
		t.Error("mono primary is not the mono face")
	}
	// An absent variant resolves nil, not a borrowed face.
	specs2 := parseOK(t, "INTER.TTF | role=ui | order=1\n")
	reg2 := NewRegistry(specs2, load)
	if got := reg2.Primary(Query{Role: "ui", Bold: true}); got != nil {
		t.Error("a manifest with no bold face must report none, not borrow regular")
	}
	// But the CHAIN for a bold run still paints — on the normal face.
	ch := reg2.Chain(Query{Role: "ui", Bold: true})
	if ch == nil || ch.Primary() != faces["INTER.TTF"] {
		t.Error("a bold run with no bold face must cascade onto the normal face")
	}
	if reg2.Chain(Query{Role: "serif"}) != nil {
		t.Error("a role the manifest does not list must yield no chain")
	}
}

// TestChainMeasureMatchesPaintWalk: the piece sum is the width the paint loop
// advances — the M93 discipline applied to a split run.
func TestChainMeasureMatchesPaintWalk(t *testing.T) {
	faces := regFaces(t)
	load, _ := fixtureLoader(t, faces)
	specs := parseOK(t,
		"INTER.TTF | role=ui | order=1\n"+
			"CHROME.TTF | role=symbol | order=1\n")
	reg := NewRegistry(specs, load)
	ui := reg.Chain(Query{Role: "ui"})
	r := coveredOnlyBy(t, faces["CHROME.TTF"], faces["INTER.TTF"])
	text := "Hi " + string(r) + " there"
	for _, px := range []int{13, 16, 21, 48} {
		pieces := ui.Split(text)
		walk := 0
		for _, p := range pieces {
			if p.Face == nil {
				continue
			}
			for _, rr := range p.Text {
				walk += p.Face.AdvancePx(rr, px)
			}
		}
		if got := ui.Measure(text, px); got != walk {
			t.Errorf("px=%d chain Measure=%d, per-rune walk=%d", px, got, walk)
		}
	}
}

// TestGoldenChainFallbackRune is the card's golden: a rune only the second
// face covers must paint that face's glyph, not the primary's .notdef. The
// rune is found by diffing the two cmaps, never hard-coded.
func TestGoldenChainFallbackRune(t *testing.T) {
	faces := regFaces(t)
	load, reads := fixtureLoader(t, faces)
	specs := parseOK(t,
		"INTER.TTF | role=ui | order=1\n"+
			"CHROME.TTF | role=symbol | order=1\n")
	reg := NewRegistry(specs, load)
	ui := reg.Chain(Query{Role: "ui"})
	inter := faces["INTER.TTF"]
	chrome := faces["CHROME.TTF"]
	r := coveredOnlyBy(t, chrome, inter)
	t.Logf("fallback rune U+%04X (Inter gid=%d, chrome gid=%d)", r,
		inter.GlyphIndex(r), chrome.GlyphIndex(r))
	text := "A" + string(r) + "B"
	pieces := ui.Split(text)
	if len(pieces) != 3 || pieces[1].Face != chrome {
		t.Fatalf("the PUA rune did not split onto the symbol face: %+v", pieces)
	}
	f := newFB(96, 40, goldenBG)
	pen := 6
	for _, p := range pieces {
		for _, rr := range p.Text {
			m, adv, err := p.Face.Glyph(p.Face.GlyphIndex(rr), 16)
			if err != nil {
				t.Fatalf("Glyph(%U): %v", rr, err)
			}
			Blend(f.px, f.w, f.w, f.h, pen+m.BearingX, 30-m.BearingY, m, goldenFG)
			pen += adv
		}
	}
	if ink := f.count(func(v uint32) bool { return v != goldenBG }); ink < 100 {
		t.Fatalf("fallback text painted almost nothing: %d px", ink)
	}
	checkGolden(t, "chain-ui-symbol-fallback", f)
	// The miss path is the symbol consult, not a notdef: two file reads, no
	// counted miss.
	if len(*reads) != 2 || (*reads)[0] != "INTER.TTF" || (*reads)[1] != "CHROME.TTF" {
		t.Fatalf("golden chain read %v, want [INTER.TTF CHROME.TTF]", *reads)
	}
	if reg.Notdef() != 0 {
		t.Error("a covered rune was counted as notdef")
	}
}

// TestChainBoldItalicResolvesTheDedicatedFace: a {bold,italic} query must
// pick the one row carrying weight=700 AND style=italic — and only that
// query may pick it, so the BI face never shadows a plain bold or italic.
func TestChainBoldItalicResolvesTheDedicatedFace(t *testing.T) {
	faces := regFaces(t)
	load, _ := fixtureLoader(t, faces)
	specs := parseOK(t,
		"INTER.TTF | role=ui | order=1\n"+
			"INTERB.TTF | role=ui | order=2 | weight=700\n"+
			"INTERI.TTF | role=ui | order=3 | style=italic\n"+
			"INTERBI.TTF | role=ui | order=4 | weight=700 | style=italic\n")
	reg := NewRegistry(specs, load)
	bi := Query{Role: "ui", Bold: true, Italic: true}
	if got := reg.Primary(bi); got != faces["INTERBI.TTF"] {
		t.Fatal("a bold-italic primary is not the weight=700+italic face")
	}
	if ch := reg.Chain(bi); ch == nil || ch.Primary() != faces["INTERBI.TTF"] {
		t.Fatal("the bold-italic chain did not resolve the dedicated face")
	}
	// The dedicated face must not leak into sibling queries.
	if got := reg.Primary(Query{Role: "ui", Bold: true}); got != faces["INTERB.TTF"] {
		t.Error("a bold query reached for the BI face")
	}
	if got := reg.Primary(Query{Role: "ui", Italic: true}); got != faces["INTERI.TTF"] {
		t.Error("an italic query reached for the BI face")
	}
	if got := reg.Primary(Query{Role: "ui"}); got != faces["INTER.TTF"] {
		t.Error("a plain query reached for a styled face")
	}
}

// TestChainBoldItalicDegradesThroughStyledFaces is the card's degrade rule:
// {B,I} falls back {B} then {I} then the role's normal face, so a manifest
// without a BI row still paints a styled face, never Regular first.
func TestChainBoldItalicDegradesThroughStyledFaces(t *testing.T) {
	faces := regFaces(t)
	load, _ := fixtureLoader(t, faces)
	cases := []struct {
		name     string
		manifest string
		want     string
	}{
		{"no BI row degrades to bold",
			"INTER.TTF | role=ui | order=1\n" +
				"INTERB.TTF | role=ui | order=2 | weight=700\n" +
				"INTERI.TTF | role=ui | order=3 | style=italic\n", "INTERB.TTF"},
		{"no bold-weight row degrades to italic",
			"INTER.TTF | role=ui | order=1\n" +
				"INTERI.TTF | role=ui | order=3 | style=italic\n", "INTERI.TTF"},
		{"no styled row degrades to normal",
			"INTER.TTF | role=ui | order=1\n", "INTER.TTF"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := NewRegistry(parseOK(t, tc.manifest), load)
			ch := reg.Chain(Query{Role: "ui", Bold: true, Italic: true})
			if ch == nil || ch.Primary() != faces[tc.want] {
				t.Fatalf("degraded primary = %v, want %s", ch.Primary(), tc.want)
			}
		})
	}
}

// TestSerifStyledQueriesRefuseByName is the card's declared serif policy:
// NOTOSERF has no styled rows, so serif bold, italic and bold-italic all
// degrade to the regular serif face — real coverage, no synthetic shear or
// embolden. The query must not borrow an Inter styled face either: styled
// rows in another role are not a serif answer.
func TestSerifStyledQueriesRefuseByName(t *testing.T) {
	faces := regFaces(t)
	load, _ := fixtureLoader(t, faces)
	specs := parseOK(t,
		"INTER.TTF | role=ui | order=1\n"+
			"INTERB.TTF | role=ui | order=2 | weight=700\n"+
			"INTERI.TTF | role=ui | order=3 | style=italic\n"+
			"INTERBI.TTF | role=ui | order=4 | weight=700 | style=italic\n"+
			"NOTOSERF.TTF | role=serif | order=1\n")
	reg := NewRegistry(specs, load)
	for _, q := range []Query{
		{Role: "serif", Bold: true},
		{Role: "serif", Italic: true},
		{Role: "serif", Bold: true, Italic: true},
	} {
		ch := reg.Chain(q)
		if ch == nil || ch.Primary() != faces["NOTOSERF.TTF"] {
			t.Fatalf("%+v resolved %v, want the regular serif face", q, ch.Primary())
		}
	}
}

// TestChainHebrewReachesTheCoverageFace is the M178a cascade fact: a Hebrew
// rune falls through every earlier ui face to NOTOHEB (real ink, no notdef),
// while the Latin around it stays on the primary.
func TestChainHebrewReachesTheCoverageFace(t *testing.T) {
	faces := regFaces(t)
	load, reads := fixtureLoader(t, faces)
	specs, err := ParseManifest([]byte(`# test
INTER.TTF    | role=ui | order=1
INTERB.TTF   | role=ui | order=2 | weight=700
NOTOHEB.TTF  | role=ui | order=6
CHROME.TTF   | role=symbol | order=1
`))
	if err != nil {
		t.Fatal(err)
	}
	reg := NewRegistry(specs, load)
	ui := reg.Chain(Query{Role: "ui"})
	pieces := ui.Split("abאבגde")
	if len(pieces) != 3 || pieces[1].Face != faces["NOTOHEB.TTF"] {
		t.Fatalf("Hebrew run did not split onto NOTOHEB: %+v", pieces)
	}
	if pieces[0].Face != faces["INTER.TTF"] || pieces[2].Face != faces["INTER.TTF"] {
		t.Fatalf("Latin did not stay on the primary: %+v", pieces)
	}
	if reg.Notdef() != 0 {
		t.Errorf("a covered Hebrew rune counted as notdef (%d)", reg.Notdef())
	}
	// The cascade walked role order on the miss: INTER, INTERB, NOTOHEB — and
	// the symbol face was never read for a covered rune.
	want := []string{"INTER.TTF", "INTERB.TTF", "NOTOHEB.TTF"}
	if len(*reads) != len(want) {
		t.Fatalf("reads %v, want %v", *reads, want)
	}
	for i := range want {
		if (*reads)[i] != want[i] {
			t.Fatalf("reads %v, want %v", *reads, want)
		}
	}
}
