// M124b (#2581): save-as through the shared appkit.FilePicker. Ctrl+Shift+S
// opens the modal — the same model GOEDIT and GOFILES drive, drawn on the
// kernel fill batcher through draw.FillerCanvas (the §3.2 degrade: bitmap
// face, flat corners, identical pixels the §3.4 policy keeps). The fixed
// /host/WEB-DL-* download stays on bare-S; the picker's result feeds the
// same saveDownloadTo/ledger path so both verbs record alike.
package main

import (
	"virelai/appkit"
	"virelai/draw"
	"virelai/vi"
	"virelai/widgets"
)

const (
	markerPickSave   = "web: save "
	markerPickCancel = "web: save cancel"
)

// savePick is the app's pick state — a wrapper so the modal's open flag and
// the picker model travel together and main.go's diff stays a field plus
// three routing lines.
type savePick struct {
	open bool
	p    appkit.FilePicker
}

// openSavePicker raises the save-as modal: centered on the canvas, seeded
// with the name the fixed download would have used, so the user picks a
// place, not a name from scratch.
func (a *app) openSavePicker() {
	a.pick.p = appkit.NewFilePicker(appkit.PickSave, "/host")
	if a.target != "" {
		a.pick.p.Input = downloadName(a.target)
	}
	a.pick.open = true
	a.dirty = true
}

// pickKey routes one event into the open modal; on done the result runs the
// same write+ledger leg the fixed download uses.
func (a *app) pickKey(ev vi.Event) {
	_, done := a.pick.p.HandleKey(ev)
	a.dirty = true
	if done {
		a.finishPick()
	}
}

// pickClick feeds the modal's hit test — rows select, rows activate, the
// buttons commit or cancel. Nothing outside the plate may eat the click.
func (a *app) pickClick(x, y int) {
	_, done := a.pick.p.HandleMouse(x, y, true)
	a.dirty = true
	if done {
		a.finishPick()
	}
}

// finishPick consumes the modal's result: a path writes + records + marks;
// empty or "cancel" marks the drop.
func (a *app) finishPick() {
	res := a.pick.p.Result
	a.pick.open = false
	if res == "" || res == "cancel" {
		vi.ConsoleLine(markerPickCancel)
		return
	}
	if a.saveDownloadTo(res) {
		vi.ConsoleLine(markerPickSave + res)
		a.status = "saved to " + res
		return
	}
	a.status = "save refused"
}

// paintPick draws the modal over the chrome — last thing before the fill
// batch flushes, so the plate covers page, bars, and menus alike. The rect
// re-centers every frame: a mid-modal resize can't orphan it.
func (a *app) paintPick() {
	w, h := a.canvasSize()
	pw, ph := 520, 360
	if pw > w-16 {
		pw = w - 16
	}
	if ph > h-16 {
		ph = h - 16
	}
	a.pick.p.R = widgets.Rect{X: (w - pw) / 2, Y: (h - ph) / 2, W: pw, H: ph}
	fc := draw.FillerCanvas{Filler: &a.filler, WindowID: a.win}
	a.pick.p.Draw(&fc)
}
