package main

// Per-tab zoom + the font_size setting (M126d #2596).
//
// Zoom is a uniform multiplier on the page's resolved CSS pixel lengths,
// applied to the computed styles inside layoutPage (css.Styles.Scale) and
// followed by a full re-layout: text re-measures and re-wraps at the scaled
// metrics and every declared margin/border/dimension scales with it — a
// reflow, never a bitmap stretch of the finished frame. The zoom is this
// tab's own state: nothing persists, nothing is remembered per site, and a
// navigation lays the next page out at the same zoom (the usual browser
// rule).
//
// font_size is the GOSET row the kernel owns (settings.zig's two ladders,
// M80i #1725): its rasterized text rungs are 11/13/17 px, so the web's
// default text size maps small/medium/there-large onto 11/13/17. The file
// is read once at startup; when a WM seat is live the app subscribes for
// kind-15 notices and re-applies on every change the seat delivers.

import (
	"virelai/settings"
	"virelai/vi"
	"virelai/webstyle"
)

// zoomLevels is the fixed per-tab ladder — the same progression other
// browsers keep (the +/- keys step between rungs, Ctrl+0 returns to 100).
var zoomLevels = [...]int{50, 67, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300, 400}

// fontSizeBase maps a stored font_size value to the web's default text px —
// the kernel's rasterized text ladder (small 7x13, medium 8x16, large
// 10x21 cells carry 11/13/17 px glyphs). ok=false is exactly the set the
// kernel's apply_font_size maps to nothing (it keeps the rung in force), so
// a runtime notice for a garbage value changes nothing — the sticky
// contract vi.TerminalCellForSettings already documents.
func fontSizeBase(val string) (px int, ok bool) {
	switch val {
	case "small", "0", "8x8":
		return 11, true
	case "medium", "1", "16x16":
		return 13, true
	case "large", "2", "24x24":
		return 17, true
	}
	return 0, false
}

// fontSizeRead is the startup read of /host/SETTINGS.TXT: the stored or
// effective row, and the resolved base px. An absent/corrupt file or an
// unrecognized row leaves base at 0, which CascadeBase maps to the
// contract's own InitialFontSize — the boot look, like the kernel's.
func fontSizeRead() (value string, base int) {
	value, _ = settings.Load().Effective("font_size")
	px, _ := fontSizeBase(value)
	return value, px
}

// textScaleRead is the startup read of the a11y.text_scale row (M177a
// #3142): the stored or effective percent. An absent/corrupt file or an
// unrecognized row reads 100 — the unscaled contract.
func textScaleRead() int {
	value, _ := settings.Load().Effective(settings.A11yTextScaleKey)
	pct, _ := settings.A11yTextScale(value)
	return pct
}

// scaledFontBase resolves the cascade's base text px: the font_size rung
// multiplied by a11y.text_scale/100, rounded to the nearest whole pixel
// (M177a #3142). An unresolved rung stands in for the contract's own
// InitialFontSize — the same fallback CascadeBase applies — so the scale
// multiplies what the page would have used anyway; a non-positive scale
// reads as the unscaled 100.
func scaledFontBase(rung, scale int) int {
	if rung <= 0 {
		rung = int(webstyle.InitialFontSize)
	}
	if scale <= 0 {
		scale = 100
	}
	return (rung*scale + 50) / 100
}

// relayout re-runs the cascade and layout on the retained document at the
// CURRENT zoom/font base — the reflow half of a zoom or font_size change.
// Scroll is clamped against the new bounds, controls re-bind to the new
// item geometry, and an open find bar re-searches silently (the bar never
// outlives its layout). The marker reprints `web: layout` so a gate can
// read the new shape off serial.
func (a *app) relayout() {
	if a.doc == nil || a.lay == nil {
		return
	}
	// Re-decoding this page's own images/CSS does not spend fresh page
	// budget: the layout replaces, not accumulates. loadBody resets the
	// per-layout ledger fields before its layoutPage call; a relayout is
	// the same page laid out again, so they reset identically — otherwise
	// imageBytes would double-charge a page's own images and refuse them.
	budget := a.memoryRemaining
	nDiags := len(a.diagnostics)
	a.imageBytes = 0
	a.resourceWait = 0
	a.layoutPage()
	a.memoryRemaining = budget
	// The cascade/box-tree diagnostics re-derive identically; drop the
	// duplicates layoutPage appended so the list stays the page's truth.
	a.diagnostics = a.diagnostics[:nDiags]
	if a.pageCancelled || a.quit || a.lay == nil {
		return
	}
	a.initForms()
	if max := webrenderScrollMax(a); a.scroll > max {
		a.scroll = max
	}
	if a.findOpen {
		a.findRecompute(false)
	}
	vi.ConsoleLine(markerLayout + itoa(a.lay.Blocks) + " lines=" + itoa(a.lay.Lines) + " h=" + itoa(a.lay.Height))
}

// zoomSet applies a zoom rung: set, reflow, paint the new frame, THEN print
// the marker — the announceNavigation rule (a gate snapshot on the marker
// must see the zoomed frame, so the frame lands first). A re-laid-out page
// repaints through the normal path; with nothing laid out the rung still
// lands on the tab for the next load.
func (a *app) zoomSet(pct int) {
	if pct == a.zoomPct {
		return
	}
	a.zoomPct = pct
	a.relayout()
	a.render()
	vi.ConsoleLine(markerZoom + itoa(pct))
	a.dirty = false
}

// zoomStep walks the ladder one rung in dir; at the ends nothing moves.
func (a *app) zoomStep(dir int) {
	if dir > 0 {
		for _, l := range zoomLevels {
			if l > a.zoomPct {
				a.zoomSet(l)
				return
			}
		}
		return
	}
	for i := len(zoomLevels) - 1; i >= 0; i-- {
		if zoomLevels[i] < a.zoomPct {
			a.zoomSet(zoomLevels[i])
			return
		}
	}
}

// zoomReset is Ctrl+0 — straight back to the contract's 100%.
func (a *app) zoomReset() {
	a.zoomSet(100)
}

// fontSizeApply is the settings-change half: a delivered font_size row
// re-resolves the base text size and reflows the page when the rung
// actually moved. Frame first, marker second — the zoomSet rule. The base
// the marker names is the APPLIED one — the new rung under the text_scale
// in force — identical to the rung while text_scale sits at 100.
func (a *app) fontSizeApply(value string) {
	px, ok := fontSizeBase(value)
	if !ok {
		return
	}
	a.fontRung = px
	base := scaledFontBase(px, a.textScale)
	if base == a.fontBase {
		return
	}
	a.fontBase = base
	a.relayout()
	a.render()
	vi.ConsoleLine(markerFontSize + value + " base=" + itoa(base))
	a.dirty = false
}

// textScaleApply is the a11y.text_scale half (M177a #3142): a delivered row
// re-scales the CURRENT font_size rung and reflows when the rounded base
// actually moved. The marker prints on every accepted change, base moved
// or not — the row the user set is the evidence.
func (a *app) textScaleApply(value string) {
	pct, ok := settings.A11yTextScale(value)
	if !ok || pct == a.textScale {
		return
	}
	a.textScale = pct
	base := scaledFontBase(a.fontRung, pct)
	if base != a.fontBase {
		a.fontBase = base
		a.relayout()
		a.render()
	}
	vi.ConsoleLine(markerTextScale + itoa(pct) + " base=" + itoa(a.fontBase))
	a.dirty = false
}

// pollFontSize drains one delivered settings notice per loop turn — the
// same shape appkit's loop keeps. font_size and a11y.text_scale are the
// subscribed keys (M177a #3142); a refusal or a foreign key just returns.
func (a *app) pollFontSize() {
	if !a.settingsWatch {
		return
	}
	key, value, ok := settings.PollChange(uint32(a.win))
	if !ok {
		return
	}
	switch key {
	case "font_size":
		a.fontSizeApply(value)
	case settings.A11yTextScaleKey:
		a.textScaleApply(value)
	}
}
