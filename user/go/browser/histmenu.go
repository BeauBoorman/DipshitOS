package main

// The history dropdown (M126a #2593): the "v" chip at the right end of the
// URL row (or the H key) opens a bounded menu listing the navigation stack
// newest-first. Picking a row is a fresh visit — it pushes onto the stack,
// it does not move the cursor (the usual browser rule).
//
// The menu is chrome, not content: it paints in window coordinates with the
// same rect + DrawText vocabulary the rest of the URL row uses, entirely
// below the kernel title band and above the status line.

import (
	"virelai/vi"
	"virelai/webrender"
)

const (
	// histMenuMax is the card's bound: the dropdown lists the last 20
	// targets. histMenuY puts the plate directly under the URL row, so at
	// the native 512x384 canvas all 20 rows land above the status line
	// (48 + 20*16 = 368 = winH-statusH).
	histMenuMax = 20
	histRowH    = 16
	histMenuY   = urlRowY + urlRowH // 48
	histMenuX   = 6
)

// actX is the right-edge action chip's x origin for canvas width w. The
// chip is ">" (go, submits the field) while the URL edits and "v" (history
// dropdown) otherwise.
func actX(w int) int { return w - chipW - 8 }

// histMenuRows caps the listed rows at what fits above the status line —
// the menu can only show what it can paint.
func (a *app) histMenuRows() int {
	_, h := a.canvasSize()
	return min(histMenuMax, max(0, (h-statusH-histMenuY)/histRowH))
}

// histMenuHit maps a window-local point to a menu row.
func (a *app) histMenuHit(x, y int) (int, bool) {
	rows := a.hist.recent(a.histMenuRows())
	if len(rows) == 0 {
		return 0, false
	}
	w, _ := a.canvasSize()
	if !inRect(x, y, histMenuX, histMenuY, w-histMenuX-8, len(rows)*histRowH) {
		return 0, false
	}
	i := (y - histMenuY) / histRowH
	if i >= len(rows) {
		return 0, false
	}
	return i, true
}

// toggleHistoryMenu opens/closes the dropdown. Opening lists the rows on
// serial AFTER the frame is published, so `web: history n=` is a gate
// marker that means "the list is on screen" (the same ordering rule as
// announceNavigation: the marker never outruns the paint).
func (a *app) toggleHistoryMenu() {
	if a.histOpen {
		a.histOpen, a.dirty = false, true
		return
	}
	a.urlEditing = false
	a.histOpen, a.histSel = true, 0
	a.render()
	vi.SleepNs(frameSettleNs)
	a.render()
	a.dirty = false
	rows := a.hist.recent(a.histMenuRows())
	vi.ConsoleLine(markerHistOpen + itoa(len(rows)))
	for i, e := range rows {
		vi.ConsoleLine(markerHistRow + itoa(i) + " " + e.Target)
	}
}

// pickHistory navigates to menu row i as a fresh visit.
func (a *app) pickHistory(i int) {
	rows := a.hist.recent(a.histMenuRows())
	if i < 0 || i >= len(rows) {
		return
	}
	a.histOpen = false
	vi.ConsoleLine(markerHistPick + rows[i].Target)
	from := a.target
	if from == "" {
		from = "history-menu"
	}
	a.navigate(rows[i].Target, from)
}

// histMenuKey services one key while the dropdown is open: arrows move the
// highlight, Enter picks, Escape/H close. Any other key dismisses the menu
// and reports unhandled, so it still reaches its normal binding.
func (a *app) histMenuKey(usage uint32) bool {
	if !a.histOpen {
		return false
	}
	switch usage {
	case keyUp:
		if a.histSel > 0 {
			a.histSel--
		}
		a.dirty = true
	case keyDown:
		if a.histSel < len(a.hist.recent(a.histMenuRows()))-1 {
			a.histSel++
		}
		a.dirty = true
	case keyReturn:
		a.pickHistory(a.histSel)
	case keyEscape, keyH:
		a.histOpen, a.dirty = false, true
	default:
		a.histOpen, a.dirty = false, true
		return false
	}
	return true
}

// paintHistoryMenu draws the open dropdown over the content area: a plate
// with a rule border, an accent bar on the cursor's row, and the selected
// row highlighted.
func (a *app) paintHistoryMenu(vs virender, clip webrender.Clip, w int) {
	rows := a.hist.recent(a.histMenuRows())
	if len(rows) == 0 {
		return
	}
	pw := w - histMenuX - 8
	ph := len(rows) * histRowH
	vs.Fill(histMenuX+2, histMenuY+2, pw, ph, 0x000000)
	vs.Fill(histMenuX, histMenuY, pw, ph, webrender.ColorSurface)
	vs.Fill(histMenuX, histMenuY, pw, 1, webrender.ColorRule)
	vs.Fill(histMenuX, histMenuY+ph-1, pw, 1, webrender.ColorRule)
	cur := a.hist.cursorRow()
	for i, e := range rows {
		y := histMenuY + i*histRowH
		if i == a.histSel {
			vs.Fill(histMenuX+1, y, pw-2, histRowH, webrender.ColorRule)
		}
		if i == cur {
			vs.Fill(histMenuX, y, 2, histRowH, webrender.ColorAccent)
		}
		label := e.Target
		if e.Title != "" {
			label = e.Title + " - " + e.Target
		}
		webrender.DrawText(vs, histMenuX+6, y+4, fit(label, (pw-12)/8), 1, false, webrender.ColorChromeInk, clip)
	}
}
