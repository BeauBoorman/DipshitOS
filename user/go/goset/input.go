// input.go — GOSET's event dispatch: one normalized key/click in, the
// row vocabulary step, the view switch (showTab is the ONE path every
// caller lands) and the shortcuts-registry chord out. The bounded
// controls the events drive live in controls.go; what an edit writes
// lives in rows.go; where a click lands is layout.go's geometry.
package main

import (
	"strings"

	"virelai/chords"
	"virelai/settings"
	"virelai/vi"
	"virelai/widgets"
)

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
		// card #3034: present the applied edit before save()'s file IO — a
		// ~1 s stall between handler return and the loop-tail present (observed
		// live: the keystroke's latency sample rode to the next heartbeat)
		// leaves input→glyph latency at tick scale even though the redraw is
		// already computed. Guarded on ta: headless key() tests have no seat.
		if a.ta != nil {
			a.present()
		}
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
