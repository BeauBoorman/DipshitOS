package main

// The find-in-page bar (M126c #2595): Ctrl+F opens a field that runs the
// shared matcher (package virelai/find — the same non-overlapping scan
// GOEDIT's find bar has always run, extracted so the two bars can never
// drift) over the laid-out page text, highlights every match, and steps
// with Enter / Shift+Enter. Escape closes.
//
// The searchable text is webrender.FindIndex: the page's ItemText runs in
// paint order, styled runs on one line joined and a line break a '\n' the
// bar can never carry — so a match can span styled runs but never two
// lines. Highlights are webrender.PaintFindPieces on the native surface:
// an amber fill under every match, an orange one under the current match,
// then the run's glyphs re-inked over the fill in their original
// positions.
//
// The bar is chrome, not content: it paints in window coordinates docked
// above the status line, and it owns the keyboard while open — the same
// rule GOEDIT's bars and this app's own menus keep. It survives a
// navigation (the new page re-searches silently, like a real browser);
// it never outlives its layout.

import (
	"unicode/utf8"

	"virelai/find"
	"virelai/vi"
	"virelai/webrender"
)

const (
	// findBarH is the docked strip's height; findPatMax bounds the pattern
	// (GOEDIT's barMax is 32 for a file buffer — a page scan keeps the same
	// order of bound but allows a full sentence).
	findBarH   = 16
	findPatMax = 96
	// The highlight inks are deliberately OFF the theme palette so a pixel
	// probe can count them without confusing them with page or chrome
	// colors: amber for every match, solarized orange for the current one
	// (the same match/current pairing browsers draw).
	colorFindMatch   = 0xb58900
	colorFindCurrent = 0xcb4b16
)

// findBarY docks the strip directly above the status line.
func findBarY(h int) int { return h - statusH - findBarH }

// openFindBar focuses the bar — the Ctrl+F chord, owned from any mode (the
// same rule GOEDIT's bar chords keep). The other chrome inputs are
// mutually exclusive: opening here dismisses the URL edit and the history
// dropdown. The field starts empty with no search — a reopened bar asks
// for a pattern rather than resurrecting a stale one. The strip is on the
// wire before the marker says so (the announceNavigation rule).
func (a *app) openFindBar() {
	a.findOpen = true
	a.urlEditing = false
	a.histOpen = false
	a.findEdit.reset("", findPatMax)
	a.findMatches, a.findCur, a.findIdx = nil, -1, nil
	a.render()
	vi.ConsoleLine(markerFind + "open")
	a.dirty = false
}

// findDismiss closes the bar without a marker — the quiet half of
// findClose for when something else (URL focus, a navigation error)
// retires it rather than the user's Escape.
func (a *app) findDismiss() {
	a.findOpen = false
	a.findMatches, a.findCur, a.findIdx = nil, -1, nil
}

// findClose is Escape in the bar: the strip and its highlights leave the
// frame BEFORE the marker says they did (the announceNavigation rule — a
// gate snapshot on the marker must see the clean page).
func (a *app) findClose() {
	a.findDismiss()
	a.render()
	vi.ConsoleLine(markerFind + "close")
	a.dirty = false
}

// findRecompute rebuilds the index over the CURRENT layout and re-runs the
// shared matcher for the field's pattern. mark selects the noisy form: on
// a bar keystroke the result is painted first, then announced, so the
// `web: find` lines always trail the frame that shows them; on a
// navigation the recompute is silent (the bar stays open, the new page's
// matches are not a new search the gate can assert ordering on).
//
// Every call rebuilds from a.lay rather than caching: updateControlPaint
// mutates item text as form controls change, and a stale index maps
// matches to the wrong geometry. The rebuild is one concatenation over
// the items — bounded, and only on a bar event, never per frame.
func (a *app) findRecompute(mark bool) {
	pat := a.findEdit.text
	a.findMatches, a.findCur, a.findIdx = nil, -1, nil
	if a.lay == nil || pat == "" {
		return
	}
	a.findIdx = webrender.NewFindIndex(a.lay)
	a.findMatches = find.All([]byte(a.findIdx.Text), []byte(pat))
	if len(a.findMatches) > 0 {
		a.findCur = 0
	}
	if !mark {
		return
	}
	a.scrollToFind()
	a.render()
	vi.ConsoleLine(markerFind + "'" + pat + "' n=" + itoa(len(a.findMatches)))
	if a.findCur >= 0 {
		vi.ConsoleLine(markerFindHit + itoa(a.findCur+1) + "/" + itoa(len(a.findMatches)))
	}
	a.dirty = false
}

// findStep moves the current match forward (Enter) or back (Shift+Enter),
// wrapping at both ends — the repeat-Return rule the shared matcher's
// wrap-around scan encodes, kept so a lone match re-reports 1/1 forever.
func (a *app) findStep(d int) {
	n := len(a.findMatches)
	if n == 0 {
		return
	}
	// The bar owns the keyboard, but a pointer can still reach a form
	// control between steps; a rebuild keeps the ordinal honest against
	// whatever text the page is showing now.
	a.findIdx = webrender.NewFindIndex(a.lay)
	a.findMatches = find.All([]byte(a.findIdx.Text), []byte(a.findEdit.text))
	if n = len(a.findMatches); n == 0 {
		a.findCur = -1
		return
	}
	a.findCur = ((a.findCur+d)%n + n) % n
	a.scrollToFind()
	a.render()
	vi.ConsoleLine(markerFindHit + itoa(a.findCur+1) + "/" + itoa(n))
	a.dirty = false
}

// scrollToFind puts the current match's first piece a quarter-viewport
// down — enough context to read around it, never a jump to the very edge.
func (a *app) scrollToFind() {
	if a.lay == nil || a.findIdx == nil || a.findCur < 0 || a.findCur >= len(a.findMatches) {
		return
	}
	off := a.findMatches[a.findCur]
	pieces := a.findIdx.Pieces(a.lay, off, off+len(a.findEdit.text))
	if len(pieces) == 0 {
		return
	}
	a.scroll = max(0, min(pieces[0].Rect.Y-contentH/4, webrenderScrollMax(a)))
}

// findBarKey services one key while the bar owns the keyboard. Return
// steps (Shift+Return steps back), Escape closes, and everything else is
// the field's editor — a change recomputes the search immediately, the
// incremental-find rule.
func (a *app) findBarKey(ev vi.Event) {
	switch ev.Arg0 {
	case keyEscape:
		a.findClose()
	case keyReturn:
		if ev.Flags&vi.ModShift != 0 {
			a.findStep(-1)
		} else {
			a.findStep(1)
		}
	default:
		if a.findEdit.key(ev.Arg0, ev.Arg1, ev.Flags) {
			a.findRecompute(true)
		}
	}
}

// paintFindHighlights draws every match's pieces on the native surface —
// amber for the set, orange for the current — after the page paint and
// before the frame samples out to the window.
func (a *app) paintFindHighlights(native virender) {
	if a.lay == nil || a.findIdx == nil || len(a.findMatches) == 0 {
		return
	}
	clip := webrender.Clip{X: 0, Y: 0, W: contentW, H: contentH}
	plen := len(a.findEdit.text)
	for i, off := range a.findMatches {
		rgb := uint32(colorFindMatch)
		if i == a.findCur {
			rgb = colorFindCurrent
		}
		webrender.PaintFindPieces(a.lay, native, a.scroll, a.findIdx.Pieces(a.lay, off, off+plen), rgb, clip)
	}
}

// paintFindBar draws the docked strip in window coordinates: a surface
// plate with a rule top edge, the field, its cursor, and the match count.
func (a *app) paintFindBar(vs virender, clip webrender.Clip, w, h int) {
	y := findBarY(h)
	vs.Fill(0, y, w, findBarH, webrender.ColorSurface)
	vs.Fill(0, y, w, 1, webrender.ColorRule)
	webrender.DrawText(vs, 6, y+4, "Find:", 1, false, webrender.ColorMuted, clip)
	fx, fw := 44, w-44-64
	vs.Fill(fx, y+2, fw, findBarH-4, webrender.ColorPageBg)
	pat := a.findEdit.text
	if pat == "" {
		webrender.DrawText(vs, fx+4, y+4, "type to find", 1, false, webrender.ColorMuted, clip)
	} else {
		webrender.DrawText(vs, fx+4, y+4, fit(pat, (fw-8)/8), 1, false, webrender.ColorChromeInk, clip)
	}
	// The caret bar: a one-pixel accent edge after the text up to the
	// field cursor — the same vocabulary the URL row's focus underline
	// uses.
	cx := fx + 4 + 8*utf8.RuneCountInString(a.findEdit.text[:a.findEdit.cursor])
	if cx > fx+fw-2 {
		cx = fx + fw - 2
	}
	vs.Fill(cx, y+3, 1, findBarH-6, webrender.ColorAccent)
	count := ""
	if pat != "" {
		count = "0/" + itoa(len(a.findMatches))
		if a.findCur >= 0 {
			count = itoa(a.findCur+1) + "/" + itoa(len(a.findMatches))
		}
	}
	webrender.DrawText(vs, w-8*len(count)-8, y+4, count, 1, false, webrender.ColorMuted, clip)
}
