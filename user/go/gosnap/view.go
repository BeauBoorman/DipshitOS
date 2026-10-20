// view.go — M120d (issue #2561): the windowed face of GOSNAP.ELF.
//
// A bare `GOSNAP.ELF` (no argv verb) opens this tabapp window: the stored
// snapshots as a list, a name field + Save for the ctl `snapshot` verb,
// and Restore/Delete actions on the selected row. Every verb drives the
// SAME cmd* path the argv face runs, so the serial markers a gate greps
// (`gosnap: save X ok`, `gosnap: restore X staged`, `gosnap: rm X ok`)
// are one vocabulary for both faces.
//
// The two-step confirm IS the argv `confirm` token's seat-shaped twin:
// Restore and Delete are arm buttons — the first gesture marks the
// button Confirm? and prints `gosnap: consent <verb> <name>` (the same
// ask line the argv path prints); the second gesture on the armed
// button runs the verb. Esc, a click on any other control, a moved
// selection, or a changed listing disarms — no destructive verb can
// land on a single press.
//
// The window re-lists on a ~1 Hz poll, so a snapshot minted out of band
// — the host Machine menu's menu-<stamp>.vzsave (M120c), the seat's
// CRASH<n> slots (M125f) — appears while the window is open. The `ls`
// markers print only when the listing actually changed.
package main

import (
	"virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

const (
	appName  = "GOSNAP.ELF"
	appTitle = "Snapshots"
	natW     = 480
	natH     = 300
)

// The HID usage codes the window understands — the per-app copy every
// tabapp keeps (goset controls.go, widgets' own table); no appkit pull.
const (
	keyEnter  = 0x28
	keyEscape = 0x29
	keyTab    = 0x2b
	keyHome   = 0x4a
	keyEnd    = 0x4d
	keyRight  = 0x4f
	keyLeft   = 0x50
	keyDown   = 0x51
	keyUp     = 0x52
)

// The focus ring's slots, Tab order: list -> name field -> Save ->
// Restore -> Delete. The field leads because naming is the window's
// most common gesture.
const (
	fList = iota
	fField
	fSave
	fRest
	fDel
	fCount
)

// pollNanos is the listing's re-read cadence — one listDir a second.
const pollNanos = 1_000_000_000

type snapView struct {
	ta *tabapp.TabApp

	rows []snapRow
	sel  int // -1 while the listing is empty

	// The two-step state: armed is the pending verb ("restore"/"rm"),
	// armedName the row it named. An empty armed is disarmed. The name —
	// not an index — is bound so a re-ordered listing can never point
	// the second gesture at a different snapshot.
	armed     string
	armedName string

	focus  int
	status string
	quit   bool
	pollAt int64

	headTxt   widgets.Text
	list      widgets.List
	field     widgets.TextInput
	saveBtn   widgets.Button
	restBtn   widgets.Button
	delBtn    widgets.Button
	statusTxt widgets.Text
}

func newSnapView(ta *tabapp.TabApp) *snapView {
	v := &snapView{ta: ta, sel: -1, focus: fField}
	v.headTxt = widgets.Text{Label: "Snapshots", Fg: theme.Current.Text, Bg: theme.Current.Surface}
	v.list = widgets.List{
		RowH:  18,
		Sel:   -1,
		Fg:    theme.Current.Text,
		Bg:    theme.Current.Bg,
		SelBg: theme.Current.Surface,
	}
	v.field = widgets.TextInput{Max: nameMax}
	v.field.OnSubmit = func(string) { v.save() }
	v.field.Focused = true
	v.saveBtn = widgets.Button{Label: "Save"}
	v.restBtn = widgets.Button{Label: "Restore"}
	v.delBtn = widgets.Button{Label: "Delete"}
	v.statusTxt = widgets.Text{Fg: theme.Current.Muted, Bg: theme.Current.Bg}
	v.status = "type a name + Enter to save; Restore/Delete ask twice"
	return v
}

// selName is the selected row's name, or ("",false) with no live selection.
func (v *snapView) selName() (string, bool) {
	if v.sel < 0 || v.sel >= len(v.rows) {
		return "", false
	}
	return v.rows[v.sel].name, true
}

// refresh re-lists the share and rebuilds the row labels. The argv `ls`
// marker vocabulary prints exactly as the verb would print it, so a gate
// cannot tell the faces apart by their lines. The selection is clamped
// to the new listing (a deleted row leaves the next row selected).
func (v *snapView) refresh() {
	rows, err := snapRows()
	if err != nil {
		if err.Error() == "ENOENT" {
			rows = nil
		} else {
			logLine(markerPrefix + "ls refused " + err.Error())
			v.status = "list refused " + err.Error()
			return
		}
	}
	v.rows = rows
	if v.sel >= len(rows) {
		v.sel = len(rows) - 1
	}
	v.list.Items = make([]string, len(rows))
	for i, r := range rows {
		v.list.Items[i] = r.name + "  " + vi.Itoa64(int64(r.bytes)) + " B"
	}
	v.list.Sel = v.sel
	v.ensureVisible()
	logSnapRows(rows)
	v.syncWidgets()
}

// poll is the 1 Hz re-list: cheap (one bounded dir read) and only a
// listing that CHANGED repaints — the marker lines stay event-shaped.
// A changed listing also disarms: a confirm armed against a listing
// that has since moved under it must be re-armed by the person.
func (v *snapView) poll(now int64) bool {
	if now-v.pollAt < pollNanos {
		return false
	}
	v.pollAt = now
	rows, err := snapRows()
	if err != nil || sameRows(rows, v.rows) {
		return false
	}
	v.disarm()
	v.refresh()
	v.status = "snapshot list changed"
	return true
}

// sameRows compares two listings name+size — the poll's change check.
func sameRows(a, b []snapRow) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// setFocus moves the focus ring and mirrors it onto the widgets.
func (v *snapView) setFocus(i int) {
	for i < 0 {
		i += fCount
	}
	v.focus = i % fCount
	v.list.Focused = v.focus == fList
	v.field.Focused = v.focus == fField
	v.saveBtn.Focused = v.focus == fSave
	v.restBtn.Focused = v.focus == fRest
	v.delBtn.Focused = v.focus == fDel
}

// arm is a destructive verb's first gesture: print the consent ask and
// mark the button. Nothing runs until the same verb is activated again
// against the same name.
func (v *snapView) arm(verb, name string) {
	v.armed, v.armedName = verb, name
	logLine(markerPrefix + "consent " + verb + " " + name)
	v.status = verb + " " + name + " — click again to confirm; Esc cancels"
	v.syncWidgets()
}

func (v *snapView) disarm() {
	if v.armed == "" {
		return
	}
	v.armed, v.armedName = "", ""
	v.syncWidgets()
}

// activate is the two-step itself: the first call for a (verb, name)
// pair arms, the second runs the verb — the windowed spelling of the
// argv `confirm` token. The verb's own cmd* path prints the verdict
// marker; a success re-lists so the row set stays honest.
func (v *snapView) activate(verb string) {
	name, ok := v.selName()
	if !ok {
		v.status = "select a snapshot first"
		return
	}
	if v.armed != verb || v.armedName != name {
		v.arm(verb, name)
		return
	}
	v.disarm()
	var rc int
	if verb == "restore" {
		rc = cmdRestore(name, []string{confirmToken})
	} else {
		rc = cmdRm(name, []string{confirmToken})
	}
	if rc == exitOK {
		if verb == "restore" {
			v.status = name + " staged — the next --resume boots it"
		} else {
			v.status = name + " deleted"
		}
		v.refresh()
	} else {
		v.status = verb + " " + name + " refused — see serial"
	}
}

// save is the name field's submit and the Save button's activation: the
// ctl `snapshot` verb through cmdSave, then a re-list on success. An
// empty field is a status hint, never a verb.
func (v *snapView) save() {
	v.disarm()
	name := v.field.Value()
	if name == "" {
		v.status = "type a snapshot name first"
		v.syncWidgets()
		return
	}
	if cmdSave(name) == exitOK {
		v.field.Clear()
		v.status = name + " saved"
		v.refresh()
	} else {
		v.status = "save " + name + " refused — see serial"
		v.syncWidgets()
	}
}

// handle applies one input event, reporting whether the frame changed.
func (v *snapView) handle(ev vi.Event) bool {
	switch ev.Kind {
	case vi.EvKeyDown:
		return v.key(ev)
	case vi.EvMouseDown:
		if ev.Flags&vi.BtnLeft == 0 {
			return false
		}
		return v.click(int(ev.Arg0), int(ev.Arg1))
	}
	return false
}

// key is the keyboard path. Esc is global: it cancels a pending confirm
// before it can quit the window. Tab walks the focus ring; Up/Down
// always move the list (the field has no use for them); every other key
// goes to the focused control.
func (v *snapView) key(ev vi.Event) bool {
	usage, ch := ev.Arg0, byte(ev.Arg1)
	if usage == keyEscape || (usage == 0 && ch == 0x1b) {
		if v.armed != "" {
			v.disarm()
			v.status = "confirm cancelled"
			v.syncWidgets()
			return true
		}
		v.quit = true
		return true
	}
	if usage == keyTab || (usage == 0 && ch == '\t') {
		d := 1
		if ev.Flags&vi.ModShift != 0 {
			d = -1
		}
		v.setFocus(v.focus + d)
		return true
	}
	if usage == keyUp || usage == keyDown {
		return v.moveSel(usage)
	}
	switch v.focus {
	case fList:
		switch usage {
		case keyHome:
			return v.selTo(0)
		case keyEnd:
			return v.selTo(len(v.rows) - 1)
		case keyEnter, keyRight, keyLeft:
			// A row's Enter is its first verb gesture? No — Enter on a
			// list row does nothing: Restore/Delete are the buttons, so
			// a stray key can never arm a destructive verb.
		}
	case fField:
		return v.field.HandleKey(usage, ch)
	case fSave:
		if usage == keyEnter || (usage == 0 && (ch == '\r' || ch == '\n')) {
			v.save()
			return true
		}
	case fRest:
		if usage == keyEnter || (usage == 0 && (ch == '\r' || ch == '\n')) {
			v.activate("restore")
			return true
		}
	case fDel:
		if usage == keyEnter || (usage == 0 && (ch == '\r' || ch == '\n')) {
			v.activate("rm")
			return true
		}
	}
	return false
}

// moveSel is the Up/Down list step — reachable from every focus slot so
// the list answers the arrows even while a name is being typed.
func (v *snapView) moveSel(usage uint32) bool {
	if len(v.rows) == 0 {
		return false
	}
	d := 1
	if usage == keyUp {
		d = -1
	}
	return v.selTo(v.sel + d)
}

func (v *snapView) selTo(i int) bool {
	if i < 0 {
		i = 0
	}
	if i >= len(v.rows) {
		i = len(v.rows) - 1
	}
	if i == v.sel || i < 0 {
		return false
	}
	v.sel, v.list.Sel = i, i
	v.disarm()
	v.ensureVisible()
	return true
}

func (v *snapView) ensureVisible() {
	vis := v.list.VisibleRows()
	if vis < 1 {
		return
	}
	top := v.list.ScrollTop
	if top > len(v.list.Items)-vis {
		top = len(v.list.Items) - vis
	}
	if v.sel >= 0 && v.sel < top {
		top = v.sel
	}
	if v.sel >= top+vis {
		top = v.sel - vis + 1
	}
	if top < 0 {
		top = 0
	}
	v.list.ScrollTop = top
}

// click is the pointer path. Every control hit disarms a pending
// confirm for another verb — the second gesture must land on the SAME
// armed button.
func (v *snapView) click(x, y int) bool {
	if i := v.list.ItemAt(x, y); i >= 0 {
		v.sel, v.list.Sel = i, i
		v.disarm()
		v.setFocus(fList)
		return true
	}
	if v.field.HitTest(x, y) {
		v.disarm()
		v.setFocus(fField)
		return true
	}
	if v.saveBtn.HitTest(x, y) {
		v.setFocus(fSave)
		v.save()
		return true
	}
	if v.restBtn.HitTest(x, y) {
		v.setFocus(fRest)
		v.activate("restore")
		return true
	}
	if v.delBtn.HitTest(x, y) {
		v.setFocus(fDel)
		v.activate("rm")
		return true
	}
	v.disarm()
	return false
}

// syncWidgets mirrors model state onto the controls: disabled flags,
// the armed button's Confirm? face, and the status line. draw() calls
// it, so it must also run wherever the state moved without a repaint
// yet — the verb paths all end through it.
func (v *snapView) syncWidgets() {
	_, ok := v.selName()
	v.restBtn.Disabled = !ok
	v.delBtn.Disabled = !ok
	v.restBtn.Label = "Restore"
	if v.armed == "restore" && ok {
		v.restBtn.Label = "Confirm?"
	}
	v.delBtn.Label = "Delete"
	if v.armed == "rm" && ok {
		v.delBtn.Label = "Confirm?"
	}
	v.list.Sel = v.sel
	v.statusTxt.Label = v.status
}

// layout maps the native 480x300 design onto the live canvas — the
// same ta.Layout rescale every migrated app runs on WIN_RESIZE.
func (v *snapView) layout() {
	sc := func(r widgets.Rect) widgets.Rect {
		s := v.ta.Layout(tabapp.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}, natW, natH)
		return widgets.Rect{X: s.X, Y: s.Y, W: s.W, H: s.H}
	}
	v.headTxt.R = sc(widgets.Rect{X: 12, Y: 10, W: 456, H: 18})
	v.list.R = sc(widgets.Rect{X: 12, Y: 34, W: 456, H: 152})
	v.list.RowH = sc(widgets.Rect{X: 0, Y: 0, W: 1, H: 18}).H
	v.field.R = sc(widgets.Rect{X: 12, Y: 196, W: 336, H: 22})
	v.saveBtn.R = sc(widgets.Rect{X: 356, Y: 196, W: 112, H: 22})
	v.restBtn.R = sc(widgets.Rect{X: 12, Y: 228, W: 150, H: 22})
	v.delBtn.R = sc(widgets.Rect{X: 170, Y: 228, W: 150, H: 22})
	v.statusTxt.R = sc(widgets.Rect{X: 12, Y: 260, W: 456, H: 30})
}

func (v *snapView) draw() {
	v.syncWidgets()
	v.layout()
	cv := v.ta.Canvas()
	cv.FillRect(widgets.Rect{W: int(v.ta.W), H: int(v.ta.H)}, draw.Opaque(theme.Current.Bg))
	v.headTxt.Draw(cv)
	v.list.Draw(cv)
	v.field.Draw(cv)
	v.saveBtn.Draw(cv)
	v.restBtn.Draw(cv)
	v.delBtn.Draw(cv)
	v.statusTxt.Draw(cv)
}

func (v *snapView) present() { v.draw(); v.ta.Present() }

// runWindowed is the bare-argv entry: open the tab window, host the
// event loop until the window closes. A refused open falls back to the
// usage text — a serial-only caller still learns the verbs, and the
// exit stays nonzero (a window that could not open is not a success).
func runWindowed() int {
	ta := tabapp.Init(tabapp.Config{
		Name: appName, Title: appTitle, X: 64, Y: 64, W: natW, H: natH,
	})
	if ta == nil {
		logLine("gosnap: error open -1")
		usage()
		return exitRefused
	}
	logLine("gosnap: open id=" + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		logLine("gosnap: declare accepted")
	} else {
		logLine("gosnap: declare refused")
	}

	v := newSnapView(ta)
	v.refresh()
	v.present()
	logLine("gosnap: present")
	logLine("gosnap: ready n=" + vi.Itoa64(int64(len(v.rows))))
	for {
		dirty := false
		if v.poll(vi.Nanos()) {
			dirty = true
		}
		ev, rc, ok := vi.PollEventRaw()
		if ok {
			switch ta.Dispatch(ev) {
			case tabapp.ActionClosed:
				v.quit = true
			case tabapp.ActionResized:
				dirty = true
			case tabapp.ActionNone:
				dirty = v.handle(ev) || dirty
			}
		} else if rc < 0 {
			return 0
		}
		if v.quit {
			logLine("gosnap: close")
			logLine("gosnap OK")
			ta.CloseAndExit(0)
			return exitOK
		}
		if dirty {
			v.present()
		}
		if !ok {
			vi.Sleep(1)
		}
	}
}
