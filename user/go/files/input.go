// input.go — the file manager's input half: one decoded key or SGR
// pointer report in, the model's verdict out. handleKey routes the modal
// surfaces first (banner, prompts, menus, the '?' hint overlay), then the
// grid's tile-step nav, then the list bindings; handleClick/releaseClick
// own the press-and-release gesture a drag can still steal. The listing
// state the events move lives in state.go; what the act verbs do lives
// in act.go.
package main

import (
	"strings"

	"virelai/appkit"
	"virelai/chords"
	"virelai/rss/keys"
	"virelai/vi"
)

// handleClick maps a kernel SGR mouse press (1-based cell coords over the
// client area) onto the list: first press selects, press on the already-
// selected row PENDS its open to the release edge — the M58a
// "click again opens" contract re-stated for M124a-2 (#2677): a held move
// off the press arms the seat-mediated drag, so "open" cannot fire until
// the gesture proved it was a click and not a drag.
func (m *model) handleClick(x, y int) {
	m.pressRow = -1
	m.pendOpen = false
	col, row := x-1, y-1
	// M123d (#2578): while the error banner stands, a press on its row
	// (the status line) dismisses it; presses elsewhere are swallowed —
	// the strip holds the prompt open until it is answered.
	if m.banner.Open {
		if row == m.rows-2 {
			m.banner.Dismiss()
			m.bannerResolve()
		}
		return
	}
	if m.mode == modeQuickLook {
		// M149a (#2806): a press anywhere dismisses the pane — it floats
		// over the list like macOS's, never selects underneath itself.
		m.closeQuickLook()
		return
	}
	if m.mode == modeProps {
		// M155a (#2929): same rule as the QuickLook pane — a press
		// dismisses the card, never acts on the list underneath it.
		m.closeProps()
		return
	}
	if m.mode == modeSearchHits {
		// M155c (#2931): same modal rule — a press dismisses the
		// results frame, never selects a row underneath it.
		m.closeSearch()
		return
	}
	if m.mode == modeSearchInput {
		// The prompt's press rule is the armed confirm's: the click was
		// acting on the list, not answering, so it sheds the prompt.
		m.mode = modeNormal
		m.input = ""
		m.status = "search cancelled"
		return
	}
	if m.mode == modeConfirmDelete {
		// #2894: a press while the confirm is armed is acting on the
		// list, not answering — shed the prompt. The press is swallowed
		// like every other overlay's dismiss, never a selection under it.
		m.cancelDelete("key=press")
		return
	}
	if col < 0 || col >= m.cols || row < 2 || row >= 2+m.bodyRows() {
		return
	}
	if col >= m.listCols() {
		return // preview pane: no click action in v1
	}
	// M167a: the hit is a row index in the list views, a tile index in
	// the grid — entryIdxAt maps both.
	idx := m.entryIdxAt(col, row)
	if idx < 0 || idx >= m.n {
		return
	}
	m.pressRow = idx
	if idx == m.sel {
		m.pendOpen = true
		return
	}
	m.sel = idx
	m.ensureSelVisible()
	m.loadPreview()
}

// releaseClick settles a press's open intent on the release edge: a press
// that deferred its open (pendOpen) and was never stolen by a drag now
// opens. Releases with nothing pending — a press on an unselected row, or
// chrome — are honest no-ops.
func (m *model) releaseClick() {
	m.pressRow = -1
	if m.pendOpen {
		m.pendOpen = false
		m.openSel()
	}
}

// handleKey is the whole keyboard contract, decoded from the bound tty by
// keys.Decode (runes verbatim, CSI arrows, Return/Backspace/Esc).
func (m *model) handleKey(ev keys.Event) {
	// M123d (#2578): the open error banner owns the keyboard first — it is
	// the status row while it stands, so no list binding may fire under it.
	if m.banner.Open {
		m.bannerKey(ev)
		return
	}
	if m.mode == modeRename {
		switch ev.Key {
		case keys.KeyEnter:
			m.commitRename()
		case keys.KeyEsc:
			m.mode = modeNormal
			m.status = "rename cancelled"
		case keys.KeyBackspace:
			if len(m.input) > 0 {
				m.input = m.input[:len(m.input)-1]
			}
		case keys.KeyRune:
			if len(m.input) < maxNameLen {
				m.input += string(ev.Rune)
			}
		case keys.KeyCtrlC:
			m.quit = true
		}
		return
	}
	if m.mode == modeOpenWith {
		switch ev.Key {
		case keys.KeyRune:
			if ev.Rune >= '1' && ev.Rune <= '9' {
				m.chooseOpen(int(ev.Rune - '0'))
				return
			}
		case keys.KeyEsc, keys.KeyBackspace:
			m.cancelOpenWith()
		case keys.KeyCtrlC:
			m.quit = true
		}
		return
	}
	if m.mode == modeContext {
		// The menu owns the keyboard: arrows walk the plate (and the open
		// submenu), Right/Enter descend, Left closes the submenu, Esc
		// dismisses — nothing leaks through to the list bindings.
		switch ev.Key {
		case keys.KeyUp:
			m.ctxMove(-1)
		case keys.KeyDown:
			m.ctxMove(1)
		case keys.KeyRight:
			if !m.ctx.sub {
				if m.ctx.sel == m.ctxOpenWithRow() {
					m.ctxOpenSub()
				}
			}
		case keys.KeyLeft:
			m.ctx.sub = false
		case keys.KeyEnter:
			m.ctxCommit()
		case keys.KeyEsc, keys.KeyBackspace:
			m.cancelCtx()
		case keys.KeyCtrlC:
			m.quit = true
		}
		return
	}
	if m.mode == modeHints {
		m.hintsKey(ev)
		return
	}
	if m.mode == modeQuickLook {
		m.qlKey(ev)
		return
	}
	if m.mode == modeProps {
		m.propsKey(ev)
		return
	}
	if m.mode == modeSearchInput {
		m.searchKey(ev)
		return
	}
	if m.mode == modeSearchHits {
		m.hitsKey(ev)
		return
	}
	if m.mode == modeConfirmDelete {
		// #2894: the prompt answers y/Y only — every other key sheds it
		// instead of being swallowed, so a stray 'd' cannot hold the
		// keyboard hostage until a much-later stray 'y' commits. The
		// shedding key is consumed (the same dismiss-and-swallow rule
		// the context menu's off-plate press uses): a key that was never
		// meant as an answer must not also act on the list.
		switch ev.Key {
		case keys.KeyRune:
			if ev.Rune == 'y' || ev.Rune == 'Y' {
				m.doDelete()
			} else {
				m.cancelDelete("key=" + keyLabel(ev))
			}
		case keys.KeyCtrlC:
			m.quit = true
		default:
			m.cancelDelete("key=" + keyLabel(ev))
		}
		return
	}

	// M190d: the menubar owns the keyboard once engaged — the grid and
	// list vocabularies below see nothing while it stands.
	if m.menuKey(ev) {
		return
	}

	// M167a (#2989): inside the grid the nav keys step by TILE — the
	// verticals by a tile row, the horizontals by a tile column. h/l take
	// the horizontal role here, so `h` is left (not up) and `l` is right
	// (not open) while the grid stands; Backspace still climbs, Enter
	// still opens.
	if m.view == viewGrid {
		switch ev.Key {
		case keys.KeyUp:
			m.gridMove(-1, 0)
		case keys.KeyDown:
			m.gridMove(1, 0)
		case keys.KeyLeft:
			m.gridMove(0, -1)
		case keys.KeyRight:
			m.gridMove(0, 1)
		case keys.KeyPageUp:
			m.gridMove(-m.gridRows(), 0)
		case keys.KeyPageDown:
			m.gridMove(m.gridRows(), 0)
		case keys.KeyRune:
			switch ev.Rune {
			case 'j':
				m.gridMove(1, 0)
			case 'k':
				m.gridMove(-1, 0)
			case 'h':
				m.gridMove(0, -1)
			case 'l':
				m.gridMove(0, 1)
			default:
				m.gridRune(ev.Rune)
			}
		case keys.KeyHome:
			m.moveTo(0)
		case keys.KeyEnd:
			m.moveTo(m.n - 1)
		case keys.KeyEnter:
			m.openSel()
		case keys.KeyBackspace, keys.KeyEsc:
			m.goUp()
		case keys.KeyCtrlC:
			m.quit = true
		case keys.KeyCtrlZ:
			m.restoreLatest()
		case keys.KeyTab:
			m.toggleView()
		}
		return
	}

	switch ev.Key {
	case keys.KeyUp:
		m.move(-1)
	case keys.KeyDown:
		m.move(1)
	case keys.KeyPageUp:
		m.move(-m.bodyRows())
	case keys.KeyPageDown:
		m.move(m.bodyRows())
	case keys.KeyHome:
		m.moveTo(0)
	case keys.KeyEnd:
		m.moveTo(m.n - 1)
	case keys.KeyEnter:
		m.openSel()
	case keys.KeyBackspace, keys.KeyEsc:
		m.goUp()
	case keys.KeyCtrlC:
		m.quit = true
	case keys.KeyCtrlZ:
		// M121e (#2568): the seat's ctrl+z chord reaches this tty-bound
		// tab as the 0x1a control byte; it is the `u` key's own path —
		// restore the newest trashed entry. Called on the model receiver
		// (Update's copy) so the marker/status survive the value write-back.
		m.restoreLatest()
	case keys.KeyTab:
		m.toggleView()
	case keys.KeyRune:
		switch ev.Rune {
		case 'j':
			m.move(1)
		case 'k':
			m.move(-1)
		case 'h':
			m.goUp()
		case 'l':
			m.openSel()
		case 'g':
			m.moveTo(0)
		case 'G':
			m.moveTo(m.n - 1)
		case 'q':
			m.quit = true
		case 'v':
			m.showVolumes()
		case 'f':
			// M167b (#2992): the favorites pseudo-listing.
			m.showFavs()
		case 'b':
			// M167b: pin the cursor's directory / unpin it.
			m.toggleFav()
		case 's':
			m.cycleSort()
		case 'r':
			m.startRename()
		case 'd':
			m.startDelete()
		case 'u':
			m.restoreLatest()
		case 'c':
			m.yankClip(false)
		case 'x':
			m.yankClip(true)
		case 'p':
			m.pasteClip()
		case ' ':
			m.openQuickLook()
		case 'i':
			m.openProps()
		case 'm':
			m.toggleMark()
		case 'M':
			m.clearMarks()
		case '/':
			m.startSearch()
		case 'o':
			m.startOpenWith()
		case 'e':
			m.exportSel()
		case 't':
			// M167a (#2989): the thumbnail grid toggle.
			m.toggleGrid()
		case '?':
			m.openHints()
		}
	}
}

// openHints raises the M121c (#2566) '?' overlay — the registry's rows for
// this app's scope plus the seat's globals and the kernel terminal chrome,
// all read off chords.Global so a hard-coded sheet can never drift. The
// row markers ride pending like every other model receipt, so they print
// after the frame that carries them.
func (m *model) openHints() {
	m.hints = appkit.NewChordHints(hintsBin, chords.ScopeKernelTerminal)
	m.hints.R.W = m.cols * 8 // the overlay plate's logical width only — Lines uses cells
	m.mode = modeHints
	m.emit(markerHints + "n=" + vi.Itoa64(int64(m.hints.ChordRows())))
	for _, l := range m.hints.RowLines() {
		m.emit(markerHintsRow + l)
	}
}

// hintsKey is the modeHints keyboard contract: Esc or a second '?' hands
// the frame back to the list, and the nav keys scroll a list taller than
// the window.
func (m *model) hintsKey(ev keys.Event) {
	vis := m.rows - 2 // the renderHints list window: title + footer off-grid
	if vis < 1 {
		vis = 1
	}
	switch ev.Key {
	case keys.KeyEsc:
		m.closeHints()
	case keys.KeyRune:
		if ev.Rune == '?' {
			m.closeHints()
		}
	case keys.KeyUp:
		m.hints.Move(-1)
	case keys.KeyDown:
		m.hints.Move(1)
	case keys.KeyPageUp:
		m.hints.Move(-vis)
	case keys.KeyPageDown:
		m.hints.Move(vis)
	case keys.KeyHome:
		m.hints.Scroll = 0
	case keys.KeyEnd:
		m.hints.Scroll = len(m.hints.Rows) - vis
		if m.hints.Scroll < 0 {
			m.hints.Scroll = 0
		}
	case keys.KeyCtrlC:
		m.quit = true
	}
}

func (m *model) closeHints() {
	m.mode = modeNormal
	m.emit(markerHints + "close")
}

// keyLabel names a decoded key for the `gofiles: key …` marker, using the
// same vocabulary the gate's chord tokens use (return/backspace/down/…).
func keyLabel(ev keys.Event) string {
	switch ev.Key {
	case keys.KeyRune:
		if ev.Rune == ' ' {
			return "space"
		}
		return string(ev.Rune)
	case keys.KeyEnter:
		return "return"
	case keys.KeyEsc:
		return "escape"
	case keys.KeyBackspace:
		return "backspace"
	case keys.KeyUp:
		return "up"
	case keys.KeyDown:
		return "down"
	case keys.KeyLeft:
		return "left"
	case keys.KeyRight:
		return "right"
	case keys.KeyHome:
		return "home"
	case keys.KeyEnd:
		return "end"
	case keys.KeyPageUp:
		return "pageup"
	case keys.KeyPageDown:
		return "pagedown"
	case keys.KeyTab:
		return "tab"
	case keys.KeyCtrlC:
		return "ctrl-c"
	case keys.KeyCtrlZ:
		return "ctrl-z"
	default:
		return "none"
	}
}

// --- M190d (#3239): the menubar -------------------------------------------
//
// The appkit menubar over the tty grid: its titles share row 0 with the
// path bar, F10 engages (the kernel's ESC[21~ decode), and an open menu
// plates over the frame like the M124d context menu — the resting frame's
// cell geometry never moves. Every row's Action calls the identical method
// its rune key calls in handleKey; syncMenu keeps the disabled flags
// honest against live state.

// GOFILES rows carry no Action closure: Update copies the model by value
// (the tea.Model contract) and writes it back afterwards, so a closure
// captured at buildMenus time would fire its verb into a detached copy —
// observed on the first gate run, where the open menu's Return landed
// silently. menuKey instead detects the open→closed Enter transition and
// calls menuVerb on THIS m — the copy whose mutations persist — and the
// dispatch table below calls the identical method the rune keys call.
func (m *model) buildMenus() {
	mi := func(label, chord string) appkit.MenuItem {
		return appkit.MenuItem{Label: label, Shortcut: chord}
	}
	m.bar.Menus = []appkit.Menu{
		{Title: "&File", Items: []appkit.MenuItem{
			mi("&Open", "enter"),
			mi("Open &With", "o"),
			mi("Quick &Look", "space"),
			mi("&Rename", "r"),
			mi("&Trash", "d"),
			mi("Propert&ies", "i"),
			mi("E&xport", "e"),
			mi("&Quit", "q"),
		}},
		{Title: "&Edit", Items: []appkit.MenuItem{
			mi("&Copy", "c"),
			mi("Cu&t", "x"),
			mi("&Paste", "p"),
			mi("Restore", "u"),
			mi("&Mark", "m"),
			mi("&Unmark all", "M"),
			mi("&Search", "/"),
		}},
		{Title: "&View", Items: []appkit.MenuItem{
			mi("&Up", "backspace"),
			mi("&Sort", "s"),
			mi("&Grid", "t"),
			mi("Pre&view", "tab"),
			mi("&Favorites", "f"),
			mi("Vol&umes", "v"),
			mi("&Pin folder", "b"),
			mi("Chord &hints", "?"),
		}},
	}
}

// menuVerb dispatches a fired (menu, item) pair on the Update-copy model —
// the identical methods the rune keys call in handleKey.
func (m *model) menuVerb(menu, item int) {
	switch menu {
	case 0: // File
		switch item {
		case 0:
			m.openSel()
		case 1:
			m.startOpenWith()
		case 2:
			m.openQuickLook()
		case 3:
			m.startRename()
		case 4:
			m.startDelete()
		case 5:
			m.openProps()
		case 6:
			m.exportSel()
		case 7:
			m.quit = true
		}
	case 1: // Edit
		switch item {
		case 0:
			m.yankClip(false)
		case 1:
			m.yankClip(true)
		case 2:
			m.pasteClip()
		case 3:
			m.restoreLatest()
		case 4:
			m.toggleMark()
		case 5:
			m.clearMarks()
		case 6:
			m.startSearch()
		}
	case 2: // View
		switch item {
		case 0:
			m.goUp()
		case 1:
			m.cycleSort()
		case 2:
			m.toggleGrid()
		case 3:
			m.toggleView()
		case 4:
			m.showFavs()
		case 5:
			m.showVolumes()
		case 6:
			m.toggleFav()
		case 7:
			m.openHints()
		}
	}
}

// syncMenu refreshes the rows' Disabled flags against live model state —
// a disabled row is a genuinely disabled verb (nothing selected, an empty
// clip queue, an empty marked set, a non-dir pin target), never decoration.
func (m *model) syncMenu() {
	if len(m.bar.Menus) == 0 {
		return
	}
	_, hasSel := m.selEntry()
	// File rows 0..6 all act on the selection; Quit does not.
	for j := 0; j < 7; j++ {
		m.bar.Menus[0].Items[j].Disabled = !hasSel
	}
	m.bar.Menus[1].Items[2].Disabled = len(m.clipSet) == 0 // Paste
	m.bar.Menus[1].Items[4].Disabled = m.n == 0            // Mark
	m.bar.Menus[1].Items[5].Disabled = m.markCount() == 0  // Unmark all
	selDir := false
	if e, ok := m.selEntry(); ok && e.Dir() {
		selDir = true
	}
	m.bar.Menus[2].Items[6].Disabled = !selDir // Pin folder
}

// menuKey drives the bar with the tty spelling of the appkit keys and
// reports whether the key was consumed. Inactive it answers F10 alone;
// active it owns the keyboard until it disengages.
func (m *model) menuKey(ev keys.Event) bool {
	k := appkit.KeyFromTTY(ev)
	if k.Usage == 0 && k.Rune == 0 {
		return false
	}
	m.syncMenu()
	wasOpen, wasBar, wasHover := m.bar.Open, m.bar.Bar, m.bar.Hover
	if !m.bar.OnKey(k) {
		return false
	}
	if m.bar.Open && !wasOpen && m.bar.Bar >= 0 && m.bar.Bar < len(m.bar.Menus) {
		t := strings.ReplaceAll(m.bar.Menus[m.bar.Bar].Title, "&", "")
		m.emit("gofiles: menubar open " + t)
	}
	// A fired row closes the menu on Enter: (wasBar, wasHover) is the row —
	// dispatch its verb on THIS model (see buildMenus for why no closures).
	if wasOpen && !m.bar.Open && ev.Key == keys.KeyEnter &&
		wasBar >= 0 && wasHover >= 0 &&
		wasBar < len(m.bar.Menus) && wasHover < len(m.bar.Menus[wasBar].Items) {
		label := m.bar.Menus[wasBar].Items[wasHover].Label
		m.emit("gofiles: menubar " + strings.ReplaceAll(label, "&", ""))
		m.menuVerb(wasBar, wasHover)
	}
	return true
}
