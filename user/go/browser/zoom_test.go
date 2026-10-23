package main

// M126d (#2596): per-tab zoom (Ctrl+= / Ctrl+- / Ctrl+0) reflows layout —
// a uniform scale on resolved CSS px inside the cascade — and the GOSET
// font_size row sets the default web text size at boot and on change.

import (
	"testing"

	"virelai/css"
	"virelai/vi"
	"virelai/webrender"
	"virelai/webstyle"
)

func zoomApp(t *testing.T, html string) *app {
	t.Helper()
	a := &app{hist: newHistory(), text: webrender.Bitmap{}, zoomPct: 100}
	a.loadBody([]byte(html), "/host/T.HTML")
	if a.lay == nil {
		t.Fatal("fixture did not lay out")
	}
	return a
}

func keyZoom(a *app, usage uint32, flags uint16) {
	a.keyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: usage, Flags: flags})
}

func TestZoomLadderSteps(t *testing.T) {
	a := zoomApp(t, `<p>zoom</p>`)
	if a.zoomPct != 100 {
		t.Fatalf("default zoom=%d want 100", a.zoomPct)
	}
	keyZoom(a, 0x2e, vi.ModCtrl) // Ctrl+=
	if a.zoomPct != 110 {
		t.Fatalf("zoom after Ctrl+===%d want 110", a.zoomPct)
	}
	keyZoom(a, 0x2e, vi.ModCtrl|vi.ModShift) // Ctrl++ (shift+'=' is the same usage)
	if a.zoomPct != 125 {
		t.Fatalf("zoom after Ctrl++=%d want 125", a.zoomPct)
	}
	keyZoom(a, 0x2d, vi.ModCtrl) // Ctrl+-
	if a.zoomPct != 110 {
		t.Fatalf("zoom after Ctrl+-=%d want 110", a.zoomPct)
	}
	keyZoom(a, 0x27, vi.ModCtrl) // Ctrl+0
	if a.zoomPct != 100 {
		t.Fatalf("zoom after Ctrl+0=%d want 100", a.zoomPct)
	}
	// Both ends clamp on the ladder; nothing moves past them.
	for i := 0; i < 20; i++ {
		keyZoom(a, 0x2d, vi.ModCtrl)
	}
	if a.zoomPct != zoomLevels[0] {
		t.Fatalf("zoom floor=%d want %d", a.zoomPct, zoomLevels[0])
	}
	for i := 0; i < 30; i++ {
		keyZoom(a, 0x2e, vi.ModCtrl)
	}
	if a.zoomPct != zoomLevels[len(zoomLevels)-1] {
		t.Fatalf("zoom cap=%d want %d", a.zoomPct, zoomLevels[len(zoomLevels)-1])
	}
}

// Zoom is a reflow: the same document laid out at a bigger rung wraps its
// text differently — different line count, different height — and every
// text item carries the scaled used size. That is the marker the live gate
// diffs between rungs.
func TestZoomReflowsLayout(t *testing.T) {
	body := `<p>This paragraph is long enough that the greedy word wrapper has to break it into at least two lines inside the browser content box.</p>` +
		`<p>Another paragraph with enough words to wrap at a wider glyph metric as the rung rises through the ladder.</p>`
	a := zoomApp(t, body)
	lines, h, px0 := a.lay.Lines, a.lay.Height, 0
	for _, it := range a.lay.Items {
		if it.Kind == webrender.ItemText {
			px0 = it.FontPx
			break
		}
	}
	if px0 != 13 {
		t.Fatalf("base text FontPx=%d want 13", px0)
	}
	a.zoomSet(200)
	if a.lay == nil || a.lay.Lines == lines || a.lay.Height == h {
		t.Fatalf("zoom 200 did not reflow: lines %d->%d h %d->%d", lines, a.lay.Lines, h, a.lay.Height)
	}
	for _, it := range a.lay.Items {
		if it.Kind == webrender.ItemText {
			if it.FontPx != 26 {
				t.Fatalf("zoomed text FontPx=%d want 26", it.FontPx)
			}
			break
		}
	}
	// Back to 100 restores the original shape exactly — the same page,
	// re-laid at the same rung, is deterministic.
	a.zoomSet(100)
	if a.lay.Lines != lines || a.lay.Height != h {
		t.Fatalf("reset reflow differs: lines %d->%d h %d->%d", lines, a.lay.Lines, h, a.lay.Height)
	}
}

// A relayout replaces this page's layout rather than stacking a second one:
// the image ledger resets the way loadBody resets it, so the page's own
// decoded pixels do not double-charge and refuse themselves on a re-pass.
func TestZoomRelayoutKeepsImageLedger(t *testing.T) {
	qoi, _ := swatchSources()
	a := &app{hist: newHistory(), text: webrender.Bitmap{}, zoomPct: 100}
	a.resourceForTest = func(string, int) ([]byte, string) { return qoi, "" }
	a.loadBody([]byte(`<p><img src="SWATCH.QOI" alt="swatch"></p>`), "/host/I.HTML")
	if a.lay == nil {
		t.Fatal("fixture did not lay out")
	}
	before := a.imageBytes
	if before <= 0 {
		t.Fatal("precondition: the image charged the ledger")
	}
	a.zoomSet(150)
	if a.imageBytes != before {
		t.Fatalf("relayout double-charged imageBytes: %d -> %d", before, a.imageBytes)
	}
}

// Zooming past the content height clamps scroll against the NEW bounds —
// a reflowed page keeps a valid scroll offset.
func TestZoomClampsScroll(t *testing.T) {
	a := zoomApp(t, `<p style="height:800px">top</p><p>bottom</p>`)
	a.scroll = webrenderScrollMax(a)
	if a.scroll <= 0 {
		t.Fatal("precondition: page taller than the viewport")
	}
	a.zoomSet(50)
	if want := webrenderScrollMax(a); a.scroll > want {
		t.Fatalf("scroll=%d over new max=%d", a.scroll, want)
	}
}

// An open find bar re-searches the reflowed layout — its index and match
// pieces point at the new geometry, not the stale one.
func TestZoomRecomputesFind(t *testing.T) {
	a := zoomApp(t, `<p>find the needle in the page body</p>`)
	a.openFindBar()
	for _, r := range "needle" {
		a.keyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: uint32(r-'a') + 0x04, Arg1: uint32(r)})
	}
	if len(a.findMatches) != 1 {
		t.Fatalf("matches=%d want 1", len(a.findMatches))
	}
	before := a.findIdx.Pieces(a.lay, a.findMatches[0], a.findMatches[0]+6)
	a.zoomSet(150)
	if !a.findOpen || len(a.findMatches) != 1 {
		t.Fatalf("zoom lost the open bar: open=%v matches=%v", a.findOpen, a.findMatches)
	}
	after := a.findIdx.Pieces(a.lay, a.findMatches[0], a.findMatches[0]+6)
	if len(before) != 1 || len(after) != 1 {
		t.Fatalf("pieces %d -> %d", len(before), len(after))
	}
	if after[0].Rect.W <= before[0].Rect.W {
		t.Fatalf("match geometry did not scale with the reflow: w %d -> %d", before[0].Rect.W, after[0].Rect.W)
	}
}

// Ctrl+= stays usable while the find bar or URL field owns the keyboard —
// the chord is app-level, the same rule Ctrl+F keeps.
func TestZoomOwnedFromAnyMode(t *testing.T) {
	a := zoomApp(t, `<p>zoom anywhere</p>`)
	a.openFindBar()
	keyZoom(a, 0x2e, vi.ModCtrl)
	if !a.findOpen || a.zoomPct != 110 {
		t.Fatalf("zoom while find open: open=%v zoom=%d", a.findOpen, a.zoomPct)
	}
	a.findDismiss()
	a.focusURL()
	keyZoom(a, 0x2d, vi.ModCtrl)
	if !a.urlEditing || a.zoomPct != 100 {
		t.Fatalf("zoom while URL editing: editing=%v zoom=%d", a.urlEditing, a.zoomPct)
	}
	if a.urlEdit.text != a.target {
		t.Fatalf("zoom clobbered the URL field: %q", a.urlEdit.text)
	}
}

// Zoom survives a navigation: the new page lays out at the tab's rung.
func TestZoomPersistsAcrossNavigation(t *testing.T) {
	a := zoomApp(t, `<p>first page</p>`)
	a.zoomSet(150)
	a.loadBody([]byte(`<p>second page</p>`), "/host/U.HTML")
	for _, it := range a.lay.Items {
		if it.Kind == webrender.ItemText {
			if it.FontPx != 20 { // 13*150/100 rounds to 20
				t.Fatalf("post-nav FontPx=%d want 20", it.FontPx)
			}
			break
		}
	}
}

// The font_size rung is the cascade's base text size: an unstyled node
// resolves to the rung, while explicit author px stays the author's.
func TestFontBaseSetsDefaultTextSize(t *testing.T) {
	doc := webrender.ParseHTML([]byte(`<div id="auto">auto</div><div id="fixed" style="font-size:10px">fixed</div>`))
	styles, _ := css.CascadeBase(doc, nil, 17)
	var auto, fixed *webrender.Node
	var walk func(*webrender.Node)
	walk = func(n *webrender.Node) {
		if n.Attr("id") == "auto" {
			auto = n
		}
		if n.Attr("id") == "fixed" {
			fixed = n
		}
		for _, c := range n.Children {
			walk(c)
		}
	}
	walk(doc.Root)
	if got := styles.ForNode(auto).FontSize.Value; got != 17 {
		t.Fatalf("auto FontSize=%d want 17", got)
	}
	if got := styles.ForNode(fixed).FontSize.Value; got != 10 {
		t.Fatalf("author FontSize=%d want 10", got)
	}
	// And the missing-node fallback carries the same base.
	if got := styles.ForNode(nil).FontSize.Value; got != 17 {
		t.Fatalf("ForNode(nil) base=%d want 17", got)
	}
}

// The rung table mirrors the kernel's apply_font_size vocabulary — the
// rasterized text ladder (11/13/17 px) — with the numeric/size aliases
// intact. An unknown value reports !ok so a runtime notice applies nothing.
func TestFontSizeBaseVocabulary(t *testing.T) {
	for val, want := range map[string]int{
		"small": 11, "0": 11, "8x8": 11,
		"medium": 13, "1": 13, "16x16": 13,
		"large": 17, "2": 17, "24x24": 17,
	} {
		px, ok := fontSizeBase(val)
		if !ok || px != want {
			t.Fatalf("fontSizeBase(%q) = %d,%v want %d,true", val, px, ok, want)
		}
	}
	for _, val := range []string{"", "huge", "13px", "smallish"} {
		if _, ok := fontSizeBase(val); ok {
			t.Fatalf("fontSizeBase(%q) unexpectedly ok", val)
		}
	}
}

// A change notice re-resolves the base and reflows; a same-rung or
// unrecognizable notice changes nothing (the sticky contract).
func TestFontSizeApply(t *testing.T) {
	a := zoomApp(t, `<p>base</p>`)
	a.fontSizeApply("large")
	if a.fontBase != 17 {
		t.Fatalf("fontBase=%d want 17", a.fontBase)
	}
	for _, it := range a.lay.Items {
		if it.Kind == webrender.ItemText {
			if it.FontPx != 17 {
				t.Fatalf("post-apply FontPx=%d want 17", it.FontPx)
			}
			break
		}
	}
	lay := a.lay
	a.fontSizeApply("large") // same rung — no re-layout
	if a.lay != lay {
		t.Fatal("a same-rung notice re-laid the page")
	}
	a.fontSizeApply("bogus") // unknown — applies nothing, sticky
	if a.fontBase != 17 || a.lay != lay {
		t.Fatal("an unknown notice moved the base or the layout")
	}
}

// Styles.Scale is a uniform multiply on resolved px — declared dimensions,
// margins, and font sizes move together; percent and un-resolved kinds are
// untouched.
func TestStylesScaleUniform(t *testing.T) {
	doc := webrender.ParseHTML([]byte(`<div id="b" style="width:200px; margin-left:10px; font-size:20px">x</div>`))
	styles, _ := css.Cascade(doc, nil)
	var box *webrender.Node
	var walk func(*webrender.Node)
	walk = func(n *webrender.Node) {
		if n.Attr("id") == "b" {
			box = n
		}
		for _, c := range n.Children {
			walk(c)
		}
	}
	walk(doc.Root)
	styles.Scale(150)
	st := styles.ForNode(box)
	if st.Width.Value != 300 || st.Margin.Left.Value != 15 || st.FontSize.Value != 30 {
		t.Fatalf("scaled style w=%d ml=%d fs=%d want 300/15/30", st.Width.Value, st.Margin.Left.Value, st.FontSize.Value)
	}
	// LineHeight resolves from the scaled font through the cascade's own
	// normal rule? No — it resolved at 20px before Scale; the uniform rule
	// scales it too.
	if st.LineHeight.Value <= 0 {
		t.Fatalf("scaled line-height %d", st.LineHeight.Value)
	}
	// 100 is a no-op; nil receivers are safe.
	styles.Scale(100)
	if styles.ForNode(box).Width.Value != 300 {
		t.Fatal("Scale(100) moved a length")
	}
	var none *css.Styles
	none.Scale(200)
	if got := styles.ForNode(nil).FontSize.Value; got != webstyle.InitialFontSize {
		t.Fatalf("ForNode(nil)=%d want %d", got, webstyle.InitialFontSize)
	}
}

// M177a (#3142): the a11y.text_scale row multiplies the font_size rung to
// make the cascade's base — nearest-whole-px rounding, the contract's own
// 13px standing in when no rung resolved.
func TestScaledFontBase(t *testing.T) {
	for _, c := range []struct {
		rung, scale, want int
	}{
		{11, 100, 11}, {13, 100, 13}, {17, 100, 17}, // unscaled = today
		{11, 150, 17}, {13, 150, 20}, {17, 150, 26}, // half-up rounding
		{13, 125, 16}, {17, 125, 21},
		{0, 150, 20}, // no rung: the contract's 13px scales too
		{13, 0, 13},  // a zero scale reads as the unscaled 100
		{13, -50, 13},
	} {
		if got := scaledFontBase(c.rung, c.scale); got != c.want {
			t.Errorf("scaledFontBase(%d,%d) = %d want %d", c.rung, c.scale, got, c.want)
		}
	}
}

// text_scale re-resolves the applied base off the CURRENT font_size rung
// and reflows — including the card's font_size=large × 150 case (17 -> 26).
func TestTextScaleApply(t *testing.T) {
	a := zoomApp(t, `<p>base</p>`)
	a.fontSizeApply("large")
	if a.fontBase != 17 || a.fontRung != 17 {
		t.Fatalf("fontBase=%d rung=%d want 17/17", a.fontBase, a.fontRung)
	}
	a.textScaleApply("150")
	if a.textScale != 150 || a.fontBase != 26 {
		t.Fatalf("large x 150: scale=%d base=%d want 150/26", a.textScale, a.fontBase)
	}
	for _, it := range a.lay.Items {
		if it.Kind == webrender.ItemText {
			if it.FontPx != 26 {
				t.Fatalf("post-scale FontPx=%d want 26", it.FontPx)
			}
			break
		}
	}
	// A font_size change under an armed scale lands scaled.
	a.fontSizeApply("small")
	if a.fontRung != 11 || a.fontBase != 17 { // 11*1.5 = 16.5 -> 17
		t.Fatalf("small x 150: rung=%d base=%d want 11/17", a.fontRung, a.fontBase)
	}
	// A same-value notice changes nothing; a bogus one is refused whole.
	lay := a.lay
	a.textScaleApply("150")
	if a.lay != lay {
		t.Fatal("a same-scale notice re-laid the page")
	}
	a.textScaleApply("bogus")
	if a.textScale != 150 || a.lay != lay {
		t.Fatal("an unknown scale moved the base or the layout")
	}
	// Back to 100 returns the rung.
	a.textScaleApply("100")
	if a.fontBase != 11 {
		t.Fatalf("scale 100: base=%d want the bare rung 11", a.fontBase)
	}
}
