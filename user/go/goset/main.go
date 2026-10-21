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
	"strings"

	"virelai/chords"
	"virelai/draw"
	"virelai/settings"
	"virelai/svcmanifest"
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

// ensurePaletteRows (M73m #1662) grows the display table with the three
// custom-palette rows the moment `custom` is chosen — the colours the user is
// choosing become visible, selectable rows. Idempotent, and it never REMOVES
// a row (a palette written while custom stays visible and saved when the
// theme cycles back: the kernel ignores those keys for any preset, so keeping
// them costs nothing and keeps the user's colours around). While theme is a
// preset the table is untouched; keyboard_layout, idle_minutes, notify_dnd and
// timezone remain accepted-unseeded rows exposed on the default surface.
func (a *panel) ensurePaletteRows() {
	if theme, _ := settings.Get(a.disp, "theme"); theme != "custom" {
		return
	}
	for _, k := range settings.PaletteKeys {
		if _, ok := settings.Get(a.disp, k.Name); ok {
			continue
		}
		a.disp = append(a.disp, settings.Setting{Key: k.Name, Val: k.Default})
	}
}

// mode is the write verdict for the gate: rw only when a save would be honored.
func (a *panel) mode() string {
	if a.file.State == settings.StateCorrupt {
		return "ro"
	}
	return "rw"
}

// summary is the publishable state of the display table: how many rows it
// carries and the two values the card names (the seat is chosen by `wm`).
func (a *panel) summary() string {
	wm, _ := settings.Get(a.disp, "wm")
	t, _ := settings.Get(a.disp, "theme")
	return "keys=" + vi.Itoa64(int64(len(a.disp))) + " wm=" + wm + " theme=" + t
}

// set applies one edit to the display table and reports it. The value is
// written verbatim — the vocabulary is the panel's help, not a gate: the
// kernel's own reader is the authority on what it will ignore.
func (a *panel) set(key, val string) bool {
	if a.file.State == settings.StateCorrupt {
		vi.ConsoleLine(markerRefused + " " + key)
		return false
	}
	a.disp = settings.Set(a.disp, key, val)
	// Live preview for the one key a running process can act on: the seat
	// reads `theme` at boot, and theme.Set is the same table the panel draws
	// with. Unknown values are refused by theme.Set, so a typo cannot invent
	// a palette (it is still written, and still ignored at the next boot).
	// M73m: `amber`/`custom` are refused the same way — this window keeps its
	// current tokens while the STORE (and the kernel terminal) takes the
	// choice; the swatch band below shows the custom colours either way.
	if key == "theme" {
		_ = theme.Set(val)
	}
	// M73m: choosing `custom` reveals the colour rows it applies to.
	if key == "theme" {
		a.ensurePaletteRows()
	}
	// M165b (#2983): the access tab mirrors the three a11y rows — a write
	// through any surface (typed input, a row cycle) refreshes what the
	// tab shows, and a contrast write previews on this window's own
	// tokens the same live-apply `theme` gets above.
	if settings.IsA11yKey(key) {
		a.syncAccessRows()
	}
	if settings.IsA11yContrastKey(key) {
		high, _ := settings.A11yContrast(val)
		theme.SetContrast(high)
	}
	vi.ConsoleLine(markerSet + key + "=" + val)
	return true
}

// syncAccessRows refreshes the access tab's three rows from the display
// table: the file's value where the row exists, the compiled default
// otherwise — the a11y rows are accepted-but-unseeded, so an absent row is
// off/off/100 and nothing materializes until it is set.
func (a *panel) syncAccessRows() {
	a.accessRows = a.accessRows[:0]
	for _, k := range settings.A11yKeys {
		val := k.Default
		if v, ok := settings.Get(a.disp, k.Name); ok {
			val = v
		}
		a.accessRows = append(a.accessRows, settings.Setting{Key: k.Name, Val: val})
	}
}

// activeRows is the row set the list and its affordances operate on: the
// access tab's three rows while that view is up, the settings table
// otherwise.
func (a *panel) activeRows() []settings.Setting {
	if a.showAccess {
		return a.accessRows
	}
	return a.disp
}

// applyInput consumes the typed command line: `key=value` for a key the kernel
// table knows. Anything else is named and dropped, never written.
func (a *panel) applyInput() bool {
	line := a.input.Value()
	if line == "" {
		return false
	}
	a.input.Clear()
	key, val, hasEq := strings.Cut(line, "=")
	key = strings.TrimSpace(key)
	val = strings.TrimSpace(val)
	if !hasEq || key == "" {
		vi.ConsoleLine(markerDiscard + line)
		return true
	}
	// Known kernel-table key OR one of the custom-palette keys (M73m)...
	if !settings.Editable(key) {
		vi.ConsoleLine(markerDiscard + line)
		return true
	}
	// ...and a palette colour must be six hex digits: a malformed value is
	// named and dropped HERE, before it can reach the file (the kernel
	// refuses the same value again at apply — neither side paints it).
	if settings.IsPaletteKey(key) && !settings.ValidColour(val) {
		a.status = key + ": six hex digits (RRGGBB)"
		vi.ConsoleLine(markerDiscard + line)
		return true
	}
	if settings.IsKeyboardLayoutKey(key) && !settings.ValidKeyboardLayout(val) {
		a.status = "keyboard_layout: choose us or de"
		vi.ConsoleLine(markerDiscard + line)
		return true
	}
	if settings.IsIdleMinutesKey(key) {
		if _, ok := settings.IdleMinutes(val); !ok {
			a.status = "idle_minutes: whole minutes, 1..120"
			vi.ConsoleLine(markerDiscard + line)
			return true
		}
	}
	// M82d2 (#1785): the do-not-disturb row is on|off and nothing else. The
	// seat reads any other value as off, so a typo saved here would look
	// like a mode the seat is not in; refuse it before it reaches the file.
	if settings.IsNotifyDNDKey(key) {
		if _, ok := settings.NotifyDND(val); !ok {
			a.status = "notify_dnd: choose on or off"
			vi.ConsoleLine(markerDiscard + line)
			return true
		}
	}
	// M83c (#1776): the timezone row takes a fixed offset (UTC, or
	// UTC+HH:MM). A shape the shared formatter would fall back to UTC on is
	// refused HERE: a typo must not quietly relabel every clock UTC.
	if settings.IsTimezoneKey(key) && !settings.ValidTimezone(val) {
		a.status = "timezone: UTC or UTC+HH:MM"
		vi.ConsoleLine(markerDiscard + line)
		return true
	}
	// M100f (#2311): the data-root row is host|disk — anything else reads
	// as the host default at resolve time, which would silently lie about
	// what the boot will do; refuse it before it reaches the file.
	if settings.IsDataRootKey(key) && !settings.ValidDataRoot(val) {
		a.status = "data_root: host or disk"
		vi.ConsoleLine(markerDiscard + line)
		return true
	}
	// M165b (#2983): the a11y rows take only their declared vocabularies —
	// a value outside them reads as the compiled default at every consumer,
	// so a typo saved here would look like a mode nothing is in; refuse it
	// before it reaches the file.
	if settings.IsA11yKey(key) && !settings.ValidA11y(key, val) {
		vocab, _ := settings.Vocab(key)
		a.status = key + ": choose " + strings.Join(vocab, " or ")
		vi.ConsoleLine(markerDiscard + line)
		return true
	}
	a.set(key, val)
	return true
}

// save publishes the display table crash-safe. Corrupt is refused (one honest
// line, nothing written); any other negative return is the kernel code of the
// step that failed, and the temp is gone either way.
func (a *panel) save() {
	if a.showServices {
		a.saveServices()
		return
	}
	if a.showGrants {
		// Grant writes are per-gesture through the admin slot — there is
		// no table-shaped file for a bare Enter to publish.
		a.status = "grants land per gesture — grant|refuse <BIN> + Enter"
		return
	}
	if a.showChords {
		// The registry view is read-only: the compiled table has nothing
		// to publish, and the settings rows underneath must not be
		// written from a surface that does not show them.
		vi.ConsoleLine(markerRefused)
		a.status = "the shortcuts registry is compiled in — ctrl+shift+h returns to Settings to save"
		return
	}
	if a.showProfile {
		// M128d: the profile view is read-only — a bare Enter must not
		// write SETTINGS.TXT from a surface that shows no settings rows.
		consoleLine(markerRefused)
		a.status = profReadOnly
		return
	}
	if a.file.State == settings.StateCorrupt {
		vi.ConsoleLine(markerRefused)
		a.status = "corrupt file: read-only"
		return
	}
	f := settings.File{Rows: a.disp, State: settings.StateOK}
	changed := changedSettingKeys(a.file, f)
	rc := f.Save()
	if rc == settings.SaveRefused {
		vi.ConsoleLine(markerRefused)
		return
	}
	if rc == settings.SaveFull {
		vi.ConsoleLine(markerRefused)
		a.status = "settings full: remove a row before saving"
		return
	}
	if rc < 0 {
		vi.ConsoleLine(markerSaveFail + vi.Itoa64(rc))
		a.status = "save failed rc=" + vi.Itoa64(rc)
		return
	}
	// Keep the on-disk baseline separate from the editable table. Later edits
	// mutate a.disp in place, and must remain diffable against this save.
	a.file = settings.File{
		Rows:  append([]settings.Setting(nil), f.Rows...),
		State: f.State,
	}
	vi.ConsoleLine(markerSaved + a.summary())
	a.status = "saved " + settings.Path
	for _, key := range changed {
		if settings.PublishChange(key, uint32(a.ta.Win), a.ta.Name) {
			vi.ConsoleLine(markerNotified + key)
		}
	}
}

// changedSettingKeys compares effective values rather than file presence:
// materializing compiled defaults in the first save is not itself a change.
func changedSettingKeys(before, after settings.File) []string {
	var changed []string
	for i, row := range after.Rows {
		if !settings.Editable(row.Key) {
			continue
		}
		if _, later := settings.Get(after.Rows[i+1:], row.Key); later {
			continue
		}
		old, found := before.Effective(row.Key)
		if !found || old != row.Val {
			changed = append(changed, row.Key)
		}
	}
	return changed
}

// cycle moves the selected row to the next value in its vocabulary. A key with
// no vocabulary (hostname, prompt, scrollback, the palette colours) is left
// alone: the panel does not guess a value space the kernel never declared —
// type those as key=value, exactly like the kernel's own reader.
func (a *panel) cycle(dir int) bool {
	if a.showGrants {
		if a.sel >= 0 && a.sel < len(a.grants.entries) {
			e := a.grants.entries[a.sel]
			if dir > 0 {
				if err := a.grants.Grant(e.Name); err != nil {
					a.status = "grant refused: " + err.Error()
				} else {
					a.status = "grant written"
				}
			} else {
				a.grants.Decline(e.Name)
				a.status = "consent declined"
			}
		}
		return true
	}
	if a.showServices {
		if a.sel >= 0 && a.sel < len(a.services.manifest.Services) {
			s := a.services.manifest.Services[a.sel]
			if err := a.services.Set(s.Name, !s.Enabled); err != nil {
				a.status = "services refused: " + serviceReason(err)
			}
		}
		return true
	}
	if a.showProfile {
		// The summary rows are facts, not a vocabulary — Left/Right on a
		// profile row says so rather than cycling a lie.
		a.status = profReadOnly
		return true
	}
	if a.sel < 0 || a.sel >= len(a.activeRows()) {
		return false
	}
	key := a.activeRows()[a.sel].Key
	vocab, ok := settings.Vocab(key)
	if !ok || len(vocab) == 0 {
		if settings.IsPaletteKey(key) {
			a.status = key + ": six hex digits (RRGGBB) + Enter"
		} else if settings.IsKeyboardLayoutKey(key) {
			a.status = "keyboard_layout: choose us or de"
		} else {
			a.status = key + ": type a value (key=value)"
		}
		return true
	}
	cur := a.activeRows()[a.sel].Val
	if dir < 0 {
		return a.set(key, prevVocab(vocab, cur))
	}
	return a.set(key, settings.Next(vocab, cur))
}

// rowActivate is a left-click's row gesture (M122e #2574): select the row,
// then take the same step the keyboard's Right arrow takes — a two-value
// row toggles, a vocabulary row steps forward, a services row flips
// enabled, a grants row lands its consent gesture, and a free-form key
// names its typed path in the status line. The shortcuts registry is
// read-only: the click only selects and says so.
func (a *panel) rowActivate(i int) bool {
	a.sel, a.list.Sel = i, i
	if a.showChords {
		a.status = "the shortcuts registry is compiled in — no values to cycle"
		return true
	}
	if a.showProfile {
		a.status = profReadOnly
		return true
	}
	return a.cycle(1)
}

// prevVocab is the backward step through the same cycle; a value outside the
// vocabulary starts at the end, mirroring settings.Next's start-at-the-top.
func prevVocab(vocab []string, cur string) string {
	for i, v := range vocab {
		if v == cur {
			return vocab[(i+len(vocab)-1)%len(vocab)]
		}
	}
	return vocab[len(vocab)-1]
}

// handle applies one event. It returns whether the frame changed.
func (a *panel) handle(ev vi.Event) bool {
	switch ev.Kind {
	case vi.EvKeyDown:
		return a.key(ev)
	case vi.EvMouseDown:
		if ev.Flags&vi.BtnLeft == 0 {
			return false
		}
		x, y := int(ev.Arg0), int(ev.Arg1)
		// An open popover is modal: it eats the click (choosing an option
		// or just closing), so a click-away never reaches the rows under it.
		if a.dropdown.open {
			a.dropdownClick(x, y)
			return true
		}
		if a.rowControlClick(x, y) {
			return true
		}
		if a.focus.HandleClick(x, y) {
			if current, _ := a.focus.Current(); current == a.listCtl {
				a.sel = a.list.Sel
				// M122e (#2574): a click ON a row is the row's gesture —
				// select then cycle/toggle, the same step Right takes.
				if i := a.list.ItemAt(x, y); i >= 0 {
					return a.rowActivate(i)
				}
			}
			return true
		}
		if i := a.list.ItemAt(x, y); i >= 0 {
			a.sel = i
			a.list.Sel = i
			return true
		}
	case vi.EvMouseMove:
		if a.volDrag {
			if r, ok := a.volumeSliderRect(); ok {
				s := widgets.Slider{R: r, Min: 0, Max: 100}
				a.set(settings.AudioVolumeKey, decade(s.ValueAt(int(ev.Arg0))))
			}
			return true
		}
	case vi.EvMouseUp:
		if a.volDrag {
			a.volDrag = false
			return true
		}
	}
	return false
}

func (a *panel) key(ev vi.Event) bool {
	// M82c (#1770): ctrl+shift+s — the panel's own registered chord (a
	// GOSET.ELF row in the global shortcuts registry) — flips between the
	// settings table and the shortcuts registry view. Checked on the raw
	// event, before appkit normalizes it away, exactly like GOEDIT's own
	// chord checks.
	if isShortcutsChord(ev) {
		return a.toggleShortcuts()
	}
	// An open popover closes on any key — Left/Right cycling is the
	// keyboard path for the same vocabulary, so the popover is mouse-only.
	if a.dropdown.open {
		a.dropdown.open = false
		return true
	}
	k, ok := normalizeKey(ev)
	if !ok {
		return false
	}
	switch k.Named() {
	case keyEscape:
		// M122e (#2574): Esc backs out one level before quitting — a
		// sub-view pops to the Settings tab; already on Settings it quits.
		if a.activeTab() != tabSettings {
			return a.showTab(tabSettings)
		}
		a.exitRequested = true
		return true
	case keyEnter:
		switch strings.TrimSpace(a.input.Value()) {
		case "services":
			a.input.Clear()
			return a.showTab(tabServices)
		case "grants":
			a.input.Clear()
			return a.showTab(tabGrants)
		case "profile":
			a.input.Clear()
			return a.showTab(tabProfile)
		case "access":
			a.input.Clear()
			return a.showTab(tabAccess)
		}
		if a.showServices {
			a.serviceInput()
			return true
		}
		if a.showGrants {
			a.grantInput()
			return true
		}
		if a.showChords {
			// The registry view is read-only: nothing to apply, nothing
			// to save. Named in the status line, never a silent no-op.
			a.status = "the shortcuts registry is compiled in — ctrl+shift+h returns to Settings"
			return true
		}
		if a.showProfile {
			// M128d: the summary is read-only — a key=value typed while
			// it shows must not reach SETTINGS.TXT, and Enter doesn't
			// save. Named in the status line, never a silent no-op.
			a.input.Clear()
			a.status = profReadOnly
			return true
		}
		a.applyInput()
		a.save()
		return true
	case keyUp, keyDown, keyHome, keyEnd:
		changed := a.listCtl.HandleKey(k)
		a.sel = a.list.Sel
		return changed
	case keyLeft, keyRight:
		if current, _ := a.focus.Current(); current == &a.tabs {
			return a.tabs.OnKey(k)
		}
		if a.showChords {
			a.status = "the shortcuts registry is compiled in — no values to cycle"
			return true
		}
		if current, _ := a.focus.Current(); current == &a.input {
			return a.input.OnKey(k)
		}
		// Preserve GOSET's row vocabulary cycling when the list owns focus;
		// the text field gets the same normalized arrows for caret movement.
		if k.Named() == keyLeft {
			return a.cycle(-1)
		}
		return a.cycle(1)
	}
	return a.focus.HandleKey(k)
}

// isShortcutsChord reports whether ev is ctrl+shift+h, accepting either
// spelling of the derived byte (the isChord duality GOEDIT pins): the
// control code ('h' & 0x1f) or the shifted capital, or the raw HID usage
// in arg0. M82c rebase note: this was ctrl+shift+s until M81g (#1767)
// landed the seat's snapshot arm on that chord first — the registry's
// row and the gate's chord both moved to 'h'.
func isShortcutsChord(ev vi.Event) bool {
	if ev.Kind != vi.EvKeyDown {
		return false
	}
	if ev.Flags&vi.ModCtrl == 0 || ev.Flags&vi.ModShift == 0 {
		return false
	}
	return ev.Arg0 == uint32(chords.UsageH) || ev.Arg1 == 'H' || ev.Arg1 == 0x08
}

// activeTab is the strip cell the current view owns: the booleans stay the
// source of truth; the strip mirrors them at layout time.
func (a *panel) activeTab() int {
	switch {
	case a.showServices:
		return tabServices
	case a.showGrants:
		return tabGrants
	case a.showChords:
		return tabShortcuts
	case a.showProfile:
		return tabProfile
	case a.showAccess:
		return tabAccess
	default:
		return tabSettings
	}
}

// showTab is the ONE view switch — every caller (the strip's click, its
// Left/Right, the typed `services`/`grants` lines, the shortcuts chord, Esc
// popping a sub-view) lands the same `goset: tab <name>` marker and the same
// selection reset, so the gate greps one line for whichever path ran.
func (a *panel) showTab(i int) bool {
	a.sel, a.list.Sel, a.list.ScrollTop = 0, 0, 0
	switch i {
	case tabServices:
		a.showChords, a.showServices, a.showGrants, a.showProfile, a.showAccess = false, true, false, false, false
		a.services.Refresh()
		a.serviceStatus()
		consoleLine("goset: services n=" + vi.Itoa64(int64(len(a.services.manifest.Services))))
	case tabGrants:
		a.showChords, a.showServices, a.showGrants, a.showProfile, a.showAccess = false, false, true, false, false
		a.grants.Refresh()
		a.grantStatus()
		consoleLine("goset: grants n=" + vi.Itoa64(int64(len(a.grants.entries))))
		for _, e := range a.grants.entries {
			granted := "-"
			if e.ReadErr != 0 {
				granted = "?"
			} else if e.Row != nil {
				granted = e.Row.Words
			}
			consoleLine("goset: grant row name=" + e.Name +
				" declared=" + vi.GrantWordsCanonical(e.Declared) +
				" granted=" + granted + " state=" + e.state())
		}
	case tabShortcuts:
		a.showChords, a.showServices, a.showGrants, a.showProfile, a.showAccess = true, false, false, false, false
		vi.ConsoleLine(markerShortcuts + vi.Itoa64(int64(len(chords.Global))))
		a.status = "the global shortcuts registry — one owner per chord (read-only)"
	case tabProfile:
		// M128d (#2608): a fresh sample on every entry — the summary is
		// read-only, so the session cost buys honesty, never staleness.
		a.showChords, a.showServices, a.showGrants, a.showProfile, a.showAccess = false, false, false, true, false
		a.refreshProfile()
	case tabAccess:
		// M165b (#2983): the a11y surface — a toggle, a toggle and a
		// dropdown over the file's rows (compiled defaults where absent).
		// The rows edit through the same set/save path every other
		// settings row takes.
		a.showChords, a.showServices, a.showGrants, a.showProfile, a.showAccess = false, false, false, false, true
		a.syncAccessRows()
		a.status = "contrast and motion apply live; text scale is reserved"
	default:
		a.showChords, a.showServices, a.showGrants, a.showProfile, a.showAccess = false, false, false, false, false
		a.status = "type key=value + Enter to save"
	}
	consoleLine(markerTab + tabNames[i])
	return true
}

// toggleShortcuts flips the panel between the settings table and the
// shortcuts registry view. Opening the view prints its marker (after the
// table it renders is in hand), so a gate can grep the registry's size.
func (a *panel) toggleShortcuts() bool {
	if a.showChords {
		return a.showTab(tabSettings)
	}
	return a.showTab(tabShortcuts)
}

// --- paint ------------------------------------------------------------------

func (a *panel) layout() {
	ta := a.ta
	w := int(natW) - 16
	// M122e (#2574): the tab strip leads the pane — Settings / Services /
	// Grants / Shortcuts cells — with the view's own header line under it.
	a.tabs.R = scaleR(ta, widgets.Rect{X: 8, Y: 8, W: w, H: 20})
	a.tabs.Active = a.activeTab()
	a.headTxt = widgets.Text{
		R:     scaleR(ta, widgets.Rect{X: 8, Y: 32, W: w, H: 14}),
		Label: a.headLabel(),
		Fg:    theme.Current.Text,
		Bg:    theme.Current.Surface,
	}
	// 18px rows: ten visible at a time; the rest of the table scrolls.
	scrollTop, focused := a.list.ScrollTop, a.list.Focused
	a.list = widgets.List{
		R:         scaleR(ta, widgets.Rect{X: 8, Y: 50, W: w, H: 184}),
		Items:     a.labels(),
		RowH:      scaleH(ta, 18),
		Sel:       a.sel,
		ScrollTop: scrollTop,
		Focused:   focused,
		Fg:        theme.Current.Text,
		Bg:        theme.Current.Bg,
		SelBg:     theme.Current.Surface,
	}
	// M73m: the palette band — three swatches + their stored values, drawn
	// under the list so the colours being chosen are visible, not just typed.
	for i := range a.paletteSwat {
		a.paletteSwat[i] = scaleR(ta, widgets.Rect{X: 8 + i*20, Y: 240, W: 16, H: 16})
	}
	fg, bg, accent := a.paletteColours()
	a.paletteTxt = widgets.Text{
		R: scaleR(ta, widgets.Rect{X: 72, Y: 240, W: int(natW) - 80, H: 16}),
		Label: "custom fg=" + paletteHex(fg) + " bg=" + paletteHex(bg) +
			" accent=" + paletteHex(accent),
		Fg: 0xa8b0b8,
		Bg: 0x101418,
	}
	a.input.R = scaleR(ta, widgets.Rect{X: 8, Y: 258, W: w, H: 22})
	a.input.Fg = 0xe0e8f0
	a.input.Bg = 0x161c24
	a.input.Caret = theme.Current.Caret
	a.input.Focused = false
	if current, _ := a.focus.Current(); current == &a.input {
		a.input.Focused = true
	}
	a.statusT = widgets.Text{
		R:     scaleR(ta, widgets.Rect{X: 8, Y: 286, W: w, H: 18}),
		Label: a.status,
		Fg:    0xa8b0b8,
		Bg:    0x101418,
	}
	a.saveBtn = widgets.Button{
		R:     scaleR(ta, widgets.Rect{X: 8, Y: 312, W: 88, H: 28}),
		Label: "Save",
	}
	a.quitBtn = widgets.Button{
		R:     scaleR(ta, widgets.Rect{X: int(natW) - 96, Y: 312, W: 88, H: 28}),
		Label: "Close",
	}
}

// headLabel names the surface the list is showing: the settings file's
// table, or the M82c shortcuts registry.
func (a *panel) headLabel() string {
	if a.showGrants {
		return "Grants  declared vs granted"
	}
	if a.showServices {
		return "Services  " + svcmanifest.Path
	}
	if a.showChords {
		return "Shortcuts  n=" + vi.Itoa64(int64(len(chords.Global))) + "  (one owner per chord)"
	}
	if a.showProfile {
		return "Profile  " + a.prof.Name + "  (read-only)"
	}
	if a.showAccess {
		return "Access  a11y.* — contrast, motion, text scale"
	}
	return "Settings  " + settings.Path
}

// labels renders the display table: the value in force for every row, with the
// seat-choosing key first so the row that matters is never off-screen. The
// palette rows (M73m) are first-class — never marked "(kept)", which is the
// marker for a key the kernel table does NOT carry.
//
// M82c (#1770): in the shortcuts view the same list renders the global
// chord registry instead — chord, owner, description — one owner per chord
// per dispatch point.
func (a *panel) labels() []string {
	if a.showGrants {
		return a.grants.Labels()
	}
	if a.showServices {
		return a.services.Labels()
	}
	if a.showChords {
		return chordLabels()
	}
	if a.showProfile {
		return a.profileLabels()
	}
	if a.showAccess {
		return a.accessLabels()
	}
	out := make([]string, 0, len(a.disp))
	for _, s := range a.disp {
		line := s.Key + " = " + s.Val
		if !settings.Editable(s.Key) {
			line += "  (kept)"
		}
		out = append(out, line)
	}
	return out
}

// accessLabels renders the M165b access tab's three rows. The text-scale
// row is honest about its reach: reserved and named, honoured by no app
// yet — the card's words, on the row itself.
func (a *panel) accessLabels() []string {
	out := make([]string, 0, len(a.accessRows))
	for _, s := range a.accessRows {
		line := s.Key + " = " + s.Val
		if s.Key == settings.A11yTextScaleKey {
			line += "  (no app honours this yet)"
		}
		out = append(out, line)
	}
	return out
}

// profileLabels renders the M128d summary as list rows — the armed
// profile's name, its base image, whether the base's .prev survives (a
// rollback target), and the stored snapshot count. A refused session is
// still a row: the guest reads the refusal's code instead of a blank.
func (a *panel) profileLabels() []string {
	if a.profVerdict != "" {
		return []string{"profile-info refused " + a.profVerdict}
	}
	rb := "no"
	if a.prof.Rollback {
		rb = "yes"
	}
	return []string{
		"name = " + a.prof.Name,
		"base = " + a.prof.Base,
		"rollback = " + rb,
		"snapshots = " + vi.Itoa64(int64(a.prof.Snapshots)),
	}
}

// chordLabels renders the shortcuts registry for the list: one line per
// row, chord first (the sorted-by-nothing, historical table order).
func chordLabels() []string {
	out := make([]string, 0, len(chords.Global))
	for _, r := range chords.Global {
		out = append(out, r.Chord.String()+"  "+r.Owner+"  "+r.Label)
	}
	return out
}

// paletteColours is the custom palette IN FORCE as RGB: the display table's
// stored six-hex values, else the compiled default for that row (the same
// fallback the kernel applies — a malformed stored value never paints).
func (a *panel) paletteColours() (fg, bg, accent uint32) {
	conv := func(key string) uint32 {
		if v, ok := settings.Get(a.disp, key); ok {
			if c, ok := settings.Colour(v); ok {
				return c
			}
		}
		if k, ok := settings.PaletteKey(key); ok {
			if c, ok := settings.Colour(k.Default); ok {
				return c
			}
		}
		return 0
	}
	return conv("palette_fg"), conv("palette_bg"), conv("palette_accent")
}

// paletteHex formats a 24-bit colour as the six stored digits (lowercase).
func paletteHex(v uint32) string {
	const digits = "0123456789abcdef"
	var b [6]byte
	for i := 5; i >= 0; i-- {
		b[i] = digits[v&0xf]
		v >>= 4
	}
	return string(b[:])
}

// --- row controls -----------------------------------------------------------
//
// M104f (#2273): the M104d controls ride the settings list as per-row
// affordances. {on,off} vocab rows get a Toggle, the audio_volume row gets
// the Slider (the §5.2 secondary consumer — its writes still flow through
// a.set → settings.Set → the slot-44 apply hook), and every other
// multi-valued row gets a dropdown affordance whose popover picks the value.
// Non-editable "(kept)" rows get none. All of it is geometry over the same
// canvas; the kernel's vocabulary, not the control, stays authoritative.

// rowRect is row i's slice of the list viewport (i is the absolute index).
func (a *panel) rowRect(i int) (widgets.Rect, bool) {
	lr, top := a.list.R, a.list.ScrollTop
	if i < top || i >= top+a.list.VisibleRows() || i >= len(a.activeRows()) {
		return widgets.Rect{}, false
	}
	ry := lr.Y + (i-top)*a.list.RowH
	if ry+a.list.RowH > lr.Bottom() {
		return widgets.Rect{}, false
	}
	return widgets.Rect{X: lr.X, Y: ry, W: lr.W, H: a.list.RowH}, true
}

// controlFor returns the affordance kind a row carries at its right edge.
// A two-value vocabulary carrying `off` is a toggle — {on,off} and
// {off,on} rows have always been, and M165b's {off,high} contrast row is
// the same gesture; the non-"off" member is the on position.
func rowControl(row settings.Setting) int {
	if !settings.Editable(row.Key) {
		return ctlNone
	}
	vocab, ok := settings.Vocab(row.Key)
	if !ok || len(vocab) < 2 {
		return ctlNone
	}
	if row.Key == settings.AudioVolumeKey {
		return ctlSlider
	}
	if len(vocab) == 2 && (vocab[0] == "off" || vocab[1] == "off") {
		return ctlToggle
	}
	return ctlDropdown
}

// toggleOnValue is the vocabulary member a two-position row reads as ON:
// the non-"off" half of an {off,x} pair — "on" for the on|off rows,
// "high" for a11y.contrast.
func toggleOnValue(vocab []string) string {
	for _, v := range vocab {
		if v != "off" {
			return v
		}
	}
	return "on"
}

const (
	ctlNone = iota
	ctlToggle
	ctlSlider
	ctlDropdown
)

// toggleRect/sliderRect/dropdownRect carve the affordance out of the row's
// right edge. They must agree between draw and click — one geometry source
// per control, same pattern as the widget Bounds() methods.
func toggleRect(rr widgets.Rect) widgets.Rect {
	return widgets.Rect{X: rr.Right() - 38, Y: rr.Y + (rr.H-16)/2, W: 32, H: 16}
}

func sliderRect(rr widgets.Rect) widgets.Rect {
	return widgets.Rect{X: rr.Right() - 100, Y: rr.Y + (rr.H-widgets.SliderKnobD)/2,
		W: 92, H: widgets.SliderKnobD}
}

func dropdownRect(rr widgets.Rect) widgets.Rect {
	return widgets.Rect{X: rr.Right() - 22, Y: rr.Y + (rr.H-14)/2, W: 18, H: 14}
}

// volumeSliderRect is the live audio row's slider geometry for drag updates.
func (a *panel) volumeSliderRect() (widgets.Rect, bool) {
	for i, row := range a.activeRows() {
		if row.Key == settings.AudioVolumeKey {
			if rr, ok := a.rowRect(i); ok {
				return sliderRect(rr), true
			}
		}
	}
	return widgets.Rect{}, false
}

// decade snaps a slider position to the audio_volume vocabulary's step-10
// ladder (the row's stored string, not a raw gain number).
func decade(v int) string {
	v = (v + 5) / 10 * 10
	if v < 0 {
		v = 0
	}
	if v > 100 {
		v = 100
	}
	return vi.Itoa64(int64(v))
}

// drawRowControls paints each visible settings row's affordance after the
// list rows — Toggles, the volume Slider, and the dropdown buttons.
func (a *panel) drawRowControls(cv widgets.RectCanvas) {
	// The affordances name SETTINGS rows: in the services, grants or
	// shortcuts panes the list renders other tables — a settings control
	// over a foreign row would paint (and hit-test) a lie. (M122e fixup:
	// grants was missing here — a grants row could wear row 0's toggle;
	// M128d's profile rows are facts, not settings vocabulary.) M165b's
	// access tab is NOT foreign — its three a11y rows are settings rows
	// and the toggles/dropdown are the view's whole point.
	if a.showServices || a.showGrants || a.showChords || a.showProfile {
		return
	}
	for i, row := range a.activeRows() {
		rr, ok := a.rowRect(i)
		if !ok {
			continue
		}
		switch rowControl(row) {
		case ctlToggle:
			vocab, _ := settings.Vocab(row.Key)
			(&widgets.Toggle{R: toggleRect(rr), On: row.Val == toggleOnValue(vocab), Focused: a.sel == i}).Draw(cv)
		case ctlSlider:
			v, _ := settings.AudioVolume(row.Val)
			(&widgets.Slider{R: sliderRect(rr), Min: 0, Max: 100,
				Value: v, Pressed: a.volDrag}).Draw(cv)
		case ctlDropdown:
			br := dropdownRect(rr)
			cv.FillRect(br, draw.Opaque(theme.Current.BtnIdle))
			cv.FillRect(br.Inset(1), draw.Opaque(theme.Current.Surface))
			// The affordance glyph is a 3-row triangle — font.Glyph8 has no
			// chevron, and a hand-placed wedge reads identically at 8px.
			tx, ty := br.X+5, br.Y+5
			for w := 7; w > 0; w -= 2 {
				cv.FillRect(widgets.Rect{X: tx + (7-w)/2, Y: ty, W: w, H: 1},
					draw.Opaque(theme.Current.Text))
				ty++
			}
		}
	}
}

// rowControlClick gives a left-click inside the list first shot at a row
// affordance; a miss falls through to the existing focus/list handling.
func (a *panel) rowControlClick(x, y int) bool {
	if a.showServices || a.showGrants || a.showChords || a.showProfile {
		return false
	}
	for i, row := range a.activeRows() {
		rr, ok := a.rowRect(i)
		if !ok {
			continue
		}
		switch rowControl(row) {
		case ctlToggle:
			if !toggleRect(rr).Contains(x, y) {
				continue
			}
			a.sel, a.list.Sel = i, i
			vocab, _ := settings.Vocab(row.Key)
			v := vocab[0]
			if row.Val == vocab[0] {
				v = vocab[1]
			}
			return a.set(row.Key, v)
		case ctlSlider:
			sr := sliderRect(rr)
			if !sr.Contains(x, y) {
				continue
			}
			a.sel, a.list.Sel = i, i
			a.volDrag = true
			s := widgets.Slider{R: sr, Min: 0, Max: 100}
			return a.set(row.Key, decade(s.ValueAt(x)))
		case ctlDropdown:
			if !dropdownRect(rr).Contains(x, y) {
				continue
			}
			a.sel, a.list.Sel = i, i
			vocab, _ := settings.Vocab(row.Key)
			a.dropdown.openAt(row.Key, vocab, rr, int(a.ta.H))
			return true
		}
	}
	return false
}

// dropdownClick resolves a click while the popover is open: inside → choose
// (or just close on the padding), outside → close without choosing.
func (a *panel) dropdownClick(x, y int) {
	d := &a.dropdown
	if i := d.optionAt(x, y); i >= 0 {
		key, v := d.key, d.vocab[i]
		d.open = false
		a.set(key, v)
		return
	}
	d.open = false
}

func (a *panel) draw() {
	a.layout()
	cv := a.ta.Canvas()
	cv.FillRect(widgets.Rect{W: int(a.ta.W), H: int(a.ta.H)}, draw.Opaque(theme.Current.Bg))
	a.tabs.Draw(cv)
	a.headTxt.Draw(cv)
	a.list.Draw(cv)
	a.drawRowControls(cv)
	// M73m: swatch plates — border first, colour inset, so a near-black bg
	// or a near-white fg is still visible against the panel.
	fg, bg, accent := a.paletteColours()
	for i, c := range [3]uint32{fg, bg, accent} {
		r := a.paletteSwat[i]
		cv.FillRect(r, draw.Opaque(theme.Current.Border))
		cv.FillRect(r.Inset(1), draw.Opaque(c))
	}
	a.paletteTxt.Draw(cv)
	a.input.Draw(cv)
	a.statusT.Draw(cv)
	a.saveBtn.Draw(cv)
	a.quitBtn.Draw(cv)
	// The dropdown popover is last: it floats over the rows below it.
	if a.dropdown.open {
		cur, _ := settings.Get(a.activeRows(), a.dropdown.key)
		a.dropdown.Draw(cv, cur)
	}
}

func scaleR(ta *tabapp.TabApp, r widgets.Rect) widgets.Rect {
	s := ta.Layout(tabapp.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}, natW, natH)
	return widgets.Rect{X: s.X, Y: s.Y, W: s.W, H: s.H}
}

func scaleH(ta *tabapp.TabApp, h int) int {
	s := ta.Layout(tabapp.Rect{X: 0, Y: 0, W: 1, H: h}, natW, natH)
	if s.H < 1 {
		return 1
	}
	return s.H
}
