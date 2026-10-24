// rows.go — the display table's state: the rows in force (disp, and the
// access tab's mirrored a11y rows), the edits that land on them (set,
// the typed key=value line's validation in applyInput), the palette
// rows `custom` reveals, and the crash-safe publish (save). The panel
// shell is main.go; event dispatch is input.go; geometry is layout.go.
package main

import (
	"strings"

	"virelai/settings"
	"virelai/theme"
	"virelai/vi"
)

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
		a.status = "settings full: the kernel cannot load this table whole"
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
