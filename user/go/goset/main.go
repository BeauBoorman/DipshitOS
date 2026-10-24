// Command settings is GOSET.ELF — M71f (#1565): the Go settings panel.
//
// The Zig panel (user/src/settings_panel.zig, SETTINGS.BIN) is gone. On the
// DEFAULT seat the panel you launch is this one: a Go app, in the Go catalogue,
// writing the same schema-v2 /host/SETTINGS.TXT the seat and the kernel already
// read. That is the whole point of the card — before this, `wm` could not be
// changed from a Go UI on the default seat.
//
// What it edits is exactly what is IN FORCE (card D1, no new schema): the rows
// the file carries, plus the kernel-table keys it omits (settings.KnownKeys,
// pinned against kernel/src/settings.zig), and visible accepted-but-unseeded
// rows such as idle_minutes and notify_dnd. Unknown keys a file carries are preserved
// byte-for-byte through a save but are not offered for editing.
//
// Two ways to edit, both reading the SAME display table:
//
//	Up/Down      select a row
//	Left/Right   cycle the selected row through its vocabulary (wm, theme, ...)
//	key=value ⏎  apply and save (the typed line the gate drives)
//	⏎ alone      save the table as shown
//	Esc          quit without saving
//	services ⏎   open Services; name=on|off ⏎ safely publishes its config
//	access ⏎     open Access (M165b #2983): the a11y.* toggles + text scale
//	settings ⏎   return from Services without writing SETTINGS.TXT
//
// M73m (#1662) adds the PALETTE surface: `theme` cycles the three built-in
// presets plus `custom`, and choosing `custom` reveals the three colour rows
// (palette_fg/palette_bg/palette_accent, six hex digits each) plus a live
// swatch band — the colours are visible before they are saved. The kernel
// resolves them at paint time (settings.zig's apply chain), so the terminal
// repaints on the next frame after the store is written; the panel's own
// chrome follows only presets (theme.Set knows dark|light and refuses the
// rest, so an amber/custom choice leaves this window on its current tokens —
// never a typo-invented palette).
//
// A save goes through the codec's crash-safe publish (vi.WriteFileSafe: temp +
// fsync + delete/rename), never an in-place truncate. A CORRUPT file is
// refused whole, exactly as the kernel and the seat refuse it: the panel names
// it, shows the compiled defaults that are therefore in force, and refuses
// every write — a panel must never launder a file the kernel rejected.
//
// Every marker below is printed only AFTER the step that made it true returned,
// so a gate that greps one cannot pass on a panel that did not do the work.
package main

import (
	"virelai/settings"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

const (
	appName  = "GOSET.ELF"
	appTitle = "Settings"
	natW     = 560
	natH     = 360

	markerOpen     = "goset: open id="
	markerDeclare  = "goset: declare accepted"
	markerBad      = "goset: settings bad"
	markerReady    = "goset: ready "
	markerSet      = "goset: set "
	markerDiscard  = "goset: discard "
	markerSaved    = "goset: saved "
	markerNotified = "goset: settings notified key="
	markerRefused  = "goset: save refused"
	markerSaveFail = "goset: save failed rc="
	markerPresent  = "goset: present"
	markerClose    = "goset: close"
	markerOK       = "goset OK"
	// M82c (#1770): the shortcuts registry view, opened with the panel's
	// own registered chord (ctrl+shift+s, owner GOSET.ELF in the table).
	markerShortcuts = "goset: shortcuts n="
	// M122e (#2574): every view switch lands the same marker, whichever
	// surface asked for it — a tab-strip click, the strip's Left/Right,
	// the typed `services`/`grants`/`profile`/`access` lines, or Esc
	// popping a sub-view.
	markerTab = "goset: tab "
	// M128d (#2608): the machine-identity view — one ctl `profile-info`
	// session through slot 93 answers which .virelaivm this run is, the
	// base image's name, rollback availability, and the snapshot count.
	// The marker lands only after the session answers; a refusal names
	// its code in the same place.
	markerProfile = "goset: profile "
	// The read-only verdict the profile view names on every write path —
	// one shared literal (the ELF ceiling counts bytes).
	profReadOnly = "profile view is read-only"

	inputMax = settings.MaxKey + settings.MaxVal + 2
)

type panel struct {
	ta   *tabapp.TabApp
	file settings.File
	disp []settings.Setting
	sel  int
	// The bounded field avoids linking the shell builtin table into GOSET.
	input         textField
	status        string
	exitRequested bool
	// showChords is the M82c (#1770) shortcuts registry view: the same
	// list surface rendering the global chord table instead of the
	// settings rows. Toggled by the panel's registered chord.
	showChords   bool
	showServices bool
	services     servicesView
	servicePoll  int64
	showGrants   bool
	grants       grantsView
	// M128d: the profile summary view — read-only rows sampled fresh on
	// every entry through ctl profile-info (the kernel holds the secret;
	// this app only ever names the verdict).
	showProfile bool
	prof        vi.ProfileInfo
	// M165b (#2983): the access view — the three a11y.* rows with their
	// effective values (file row, else compiled default), edited through
	// the same row affordances the settings list carries. Edits land in
	// a.disp like every other row; accessRows only mirrors what the tab
	// shows.
	showAccess  bool
	accessRows  []settings.Setting
	profVerdict string

	listCtl     *listController
	focus       *focusRing
	saveCtl     *actionButton
	quitCtl     *actionButton
	rowsTxt     widgets.Text
	headTxt     widgets.Text
	statusT     widgets.Text
	paletteTxt  widgets.Text
	list        widgets.List
	saveBtn     widgets.Button
	quitBtn     widgets.Button
	paletteSwat [3]widgets.Rect
	// M122e (#2574): the clickable view picker — Settings / Services /
	// Grants / Shortcuts cells above the pane, a focus-ring member so Tab
	// reaches it and Left/Right steps the view when it owns focus.
	tabs tabStrip
	// M104f: the dropdown popover over a vocabulary row, and the audio
	// slider's drag state. Both ride the shared canvas; neither is a
	// focus-ring member (Tab order is unchanged — they are row affordances).
	dropdown dropdownCtl
	volDrag  bool
}

func main() {
	ta := tabapp.Init(tabapp.Config{Name: appName, Title: appTitle, X: 48, Y: 48, W: natW, H: natH})
	if ta == nil {
		vi.ConsoleLine("goset: error open -1")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine("goset: declare refused")
	}

	a := newPanel(ta)
	a.present()
	vi.ConsoleLine(markerPresent)
	for {
		dirty := false
		now := vi.Nanos()
		if a.showServices && now-a.servicePoll >= 1e9 {
			a.servicePoll = now
			if a.services.Refresh() {
				a.serviceStatus()
				dirty = true
			}
		}
		ev, rc, ok := vi.PollEventRaw()
		if !ok && rc >= 0 && !a.showServices {
			// card #3034 (ADR 0007 X4): an idle poll slept a whole scheduler
			// tick, so a keystroke sat in the queue up to ~1 s before its
			// echo ever posted damage — the seat's damage tick can only run
			// as fast as the app feeds it. Block on the event queue instead:
			// a pushed KEY_DOWN wakes the panel on arrival. The services
			// view keeps the 1 s poll because its refresh is time-driven.
			var r int64
			ev, r = vi.WaitEvent()
			if r > 0 {
				ok = true
			} else if r < 0 {
				rc = r
			}
		}
		if ok {
			switch a.ta.Dispatch(ev) {
			case tabapp.ActionClosed:
				a.exitRequested = true
			case tabapp.ActionResized:
				dirty = true
			case tabapp.ActionNone:
				dirty = a.handle(ev) || dirty
			}
		} else if rc < 0 {
			return
		}
		if a.exitRequested {
			vi.ConsoleLine(markerClose)
			vi.ConsoleLine(markerOK)
			a.ta.CloseAndExit(0)
			return
		}
		if dirty {
			a.present()
		}
		if !ok {
			vi.Sleep(1)
		}
	}
}

func (a *panel) present() { a.draw(); a.ta.Present() }

// ctlProfile is the slot-93 seam — vi.VsockCtl on the guest, a fake in
// host tests (the same discipline every other vi.* caller keeps).
var ctlProfile = vi.VsockCtl

// refreshProfile samples the host's profile-info answer and names the
// verdict. The profile view re-samples on every entry: a snapshot taken
// mid-session is visible on the next visit, which is all a read-only
// summary owes.
func (a *panel) refreshProfile() {
	a.prof, a.profVerdict = vi.FetchProfileInfo(ctlProfile)
	if a.profVerdict != "" {
		consoleLine(markerProfile + "refused " + a.profVerdict)
		a.status = "profile: refused " + a.profVerdict
		return
	}
	rb := "no"
	if a.prof.Rollback {
		rb = "yes"
	}
	consoleLine(markerProfile + "name=" + a.prof.Name +
		" base=" + a.prof.Base + " rollback=" + rb +
		" snaps=" + vi.Itoa64(int64(a.prof.Snapshots)))
	a.status = "armed .virelaivm — read-only"
}

// newPanel decodes the file, names its verdict, and builds the display table.
// A corrupt file is read-only: the compiled defaults are in force (that is what
// the kernel's refusal means) and every write is refused.
func newPanel(ta *tabapp.TabApp) *panel {
	a := &panel{ta: ta}
	a.services.store = serviceStore{read: vi.ReadFileAll, stage: stageFile, publish: publishFile}
	a.input = textField{Max: inputMax}
	a.input.Prefix = "> "
	a.input.Placeholder = "<key=value>"
	a.input.Fg = 0xe0e8f0
	a.input.Bg = 0x161c24
	a.input.Caret = theme.Current.Caret
	a.listCtl = &listController{List: &a.list}
	a.tabs.Current = func() int { return a.activeTab() }
	a.tabs.OnActivate = func(i int) bool { return a.showTab(i) }
	a.saveCtl = &actionButton{Button: &a.saveBtn, OnActivate: func() bool { a.save(); return true }}
	a.quitCtl = &actionButton{Button: &a.quitBtn, OnActivate: func() bool { a.exitRequested = true; return true }}
	a.focus = &focusRing{items: []control{&a.tabs, a.listCtl, &a.input, a.saveCtl, a.quitCtl}, index: -1}
	a.focus.Focus(2)
	a.file = settings.Load()
	switch a.file.State {
	case settings.StateCorrupt:
		vi.ConsoleLine(markerBad)
		// Show what is in force, not what the file said: the kernel refused
		// the file whole, so the compiled defaults are the live table.
		a.disp = settings.File{State: settings.StateMissing}.Display()
		a.status = "corrupt file: read-only — ctrl+shift+h for shortcuts"
	default:
		a.disp = a.file.Display()
		a.status = "click a row or a tab; key=value + Enter; services opens Services — idle curtain is visual"
	}
	vi.ConsoleLine(markerReady + a.summary() + " mode=" + a.mode())
	// M73m: a file that already chose `custom` shows its colours as rows.
	a.ensurePaletteRows()
	return a
}
