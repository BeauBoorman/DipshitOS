// GOTABWM.ELF — M63b–e (issues #1420–#1423): chords, rail click/drag, type-in.
//
// M82c (#1770): the seat's chords are DEFINED by the global shortcuts
// registry (virelai/chords) and dispatched FROM it — the list below is now
// descriptive; `user/go/chords/table.go` is the normative table, one owner
// per chord per dispatch point. The registry's kernel rows record the
// frozen chrome consumers (kernel/src/input.zig). The seat rows are:
//
//	ctrl-space    -> openLauncher (the APPS.TXT catalogue; M69c)
//	enter         -> openLauncher on an EMPTY strip (start surface, M71e)
//	alt-tab       -> FocusTab + WmctlTaskbarClick (cmd 12), wrapping
//	ctrl-tab      -> the same wrapping cycle; shift reverses it (M79f)
//	ctrl-1..9     -> focus the Nth rail cell; out-of-range is a no-op (M79f)
//	ctrl-shift-p  -> the M121a command palette (palette.go; was Pin until
//	                 #2564 took the chord)
//	ctrl-shift-n  -> Pin() the focused tab (M121a: re-homed off
//	                 ctrl+shift+p)
//	ctrl-shift-t  -> reopen the most recently closed tab (re-exec its bin)
//	ctrl-shift-d  -> duplicate the focused tab (re-exec its bin)
//	ctrl-shift-w  -> close the focused tab (M121b; ctrl+w stays the
//	                 editor's kill-word)
//	ctrl-shift-pgup/pgdn -> move the focused tab one rail cell (M121b)
//	ctrl-shift-f  -> toggle the focused tab's frozen BADGE (M71e / #1564)
//	ctrl-shift-v  -> split cycle none -> V -> H -> none (M79c: live mode has
//	                 no other split entry; the choreography is demo-only)
//	ctrl-shift-s  -> take a SNAPSHOT BUNDLE (M81g: settings + SESSION.TABS +
//	                 a docs selection, published crash-safe to
//	                 /host/SNAPSHOT.BUNDLE; snapshot.go)
//	ctrl-shift-[  -> nav back for the FOCUSED tab (M79e)
//	ctrl-shift-]  -> nav forward (M79e)
//	ctrl-z        -> undo dispatch (M121e): a focused tab answers through
//	                 its own app-scope binding — the KEY_DOWN still reaches
//	                 it per ADR 0009, the seat routes and never swallows —
//	                 and the strip-focused press is the seat's own undo,
//	                 the reopen LIFO. A tty front-end keeps the keystroke's
//	                 own meaning (GOSH's suspend convention): the seat only
//	                 ever names where the chord was routed.
//	rail click    -> top strip, equal-width cells, same TASKBAR+FocusTab
//	rail drag     -> press/release over different cells → existing Reorder()
//	rail close-x  -> the cell's rightmost railCloseW px: close that tab (M79b)
//	rail hover    -> the cell under the pointer tints; entry marker (M79b)
//	sash drag     -> press-drag-release on the split divider re-proportions
//	                 the panes through applySashDrag (M79c); motion while
//	                 armed is chrome, never content
//	ordinary keys -> ignored here (ADR 0009: KEY_DOWN still reaches the app)
//
// Markers print only after the mutation/syscall that made them true.
// Ctrl+W is not bound (it collides with the editor — a GOSH.ELF row in the
// registry says so); M121b's close chord rides ctrl+shift+w.
// M79b (#1705): the rail's close-x and hover highlight live here. Hover-
// preview stays a later card. Client-area is ignored.
//
// M79c (#1706): the sash drag and the split-cycle chord live here too. No
// keyboard equivalent for the drag itself: a divider is a pointer target,
// and the cycle chord is the keyboard story, stated here rather than
// discovered later.
//
// M71d pick: Ctrl+Shift+T / Ctrl+Shift+D are Zig TABWM's own BT1 bindings
// (user/src/tabwm.zig:151/:427). They are free on GOTABWM — the only
// ctrl-shift chord bound here then was ctrl-shift-p, and Ctrl+T (Zig's "+
// New tab") is not bound at all on this seat, whose launcher is Ctrl+Space.
// M121a (#2564) then gave ctrl-shift-p to the command palette and re-homed
// pin on ctrl-shift-n.
//
// M71e pick: Ctrl+Shift+F is Zig TABWM's own freeze binding (user/src/
// tabwm.zig:1448). It is a BADGE there too — Zig checks `frozen` in no close
// path — so the port keeps that shape rather than inventing a lock.
package main

import (
	"virelai/chords"
	"virelai/vi"
)

const (
	MarkerAltTab    = "gotabwm: alt-tab id="
	MarkerRailClick = "gotabwm: rail-click id="
	// M79b (#1705): hover entry on a rail cell (transitions only, markRail's
	// discipline), naming the cell's tab id like rail-click does.
	MarkerRailHover = "gotabwm: rail-hover id="
	// M71d (#1563): the BT1 chord outcomes. <bin> is the re-exec'd executable,
	// matching Zig's `tabwm: reopen <bin>` / `tabwm: duplicate <bin>`.
	MarkerReopen           = "gotabwm: reopen "
	MarkerDuplicate        = "gotabwm: duplicate "
	MarkerReopenMissing    = "gotabwm: reopen missing "
	MarkerDuplicateMissing = "gotabwm: duplicate missing "

	// M121e (#2568): the undo dispatch's route line — `id=<n>` when the
	// chord routed to a live focused tab, `seat` when the strip owned it
	// and the seat's own undo (the reopen LIFO) answered.
	MarkerUndo = "gotabwm: undo "

	// M82c (#1770): the registry's guest-side markers. The summary line
	// follows `registered`; the refusal names the checker's error sentence;
	// `fixture accepted` is the loud failure (the checker passing a table
	// it must refuse) and every gate asserts it absent.
	MarkerChords             = "gotabwm: chords n="
	MarkerChordsRefused      = "gotabwm: chords refused "
	MarkerChordsFixtureOK    = "gotabwm: chords fixture accepted "
	MarkerChord              = "gotabwm: chord "
	chordsFixtureTriggerPath = "/host/GOTABWM.CHORDCONFLICT"

	// USB HID keyboard usages (the kernel's WM_KEY arg0). The registry
	// (virelai/chords) is the chord definitions' single source; hid_test.go
	// pins these locals against it so the two cannot drift.
	hidUsageD uint8 = 0x07 // 'd'
	hidUsageF uint8 = 0x09 // 'f'; M71e (#1564) freeze-badge toggle
	hidUsageN uint8 = 0x11 // 'n'; M121a (#2564) pin, re-homed off ctrl-shift-p
	hidUsageP uint8 = 0x13
	hidUsageS uint8 = 0x16 // 's'; M81g (#1767) snapshot bundle
	hidUsageT uint8 = 0x17 // 't'
	hidUsageV uint8 = 0x19 // 'v'; M79c (#1706) split cycle
	// M79e (#1708): M48/BT5's per-tab history chords, the SAME two Zig
	// binds in the same ctrl+shift block (Zig tabwm's usage_left_bracket /
	// usage_right_bracket). Additive: nothing existing is rebound.
	hidUsageLeftBracket  uint8 = 0x2F // '['
	hidUsageRightBracket uint8 = 0x30 // ']'
	hidUsageTab          uint8 = 0x2B
	// M121b (#2565): close rides ctrl+shift+w (plain ctrl+w is GOSH's
	// kill-word); the move pair rides the editing cluster's page keys.
	hidUsageW        uint8 = 0x1A // 'w'
	hidUsagePageUp   uint8 = 0x4B
	hidUsagePageDown uint8 = 0x4E
	// M121e (#2568): the undo chord — plain ctrl, the bare-keystroke
	// spelling every surface's own binding already answers.
	hidUsageZ uint8 = 0x1D // 'z'
	// M124e (#2584): the primary-paste chord is shift+insert — the card
	// asked for ctrl+shift+v, but split-cycle owns it at this scope (M79c)
	// and the kernel's tty path owns it at kernel-terminal scope (M73e).
	hidUsageInsert uint8 = 0x70
	hidBtnLeft     uint8 = 0x01
	hidBtnMiddle   uint8 = 0x04
)

// execApp is the exec seam for the BT1 chords. It is vi.Exec in the guest;
// the indirection exists because vi.Exec calls the raw syscall4 gateway and so
// bypasses vi's host-test syscall hook, which would leave the chord -> re-exec
// path unobservable off the guest.
var execApp = vi.Exec

// forwardContentPointer is the content-path syscall. The indirection lets
// host tests assert which pointer samples reach an app without a guest kernel.
var forwardContentPointer = vi.WmctlContentPtr

// hidChordHold is how many composite ticks the two-tab choreography waits
// after first seeing n>=2, so a rail click (3×2.5 s), a press/release drag
// (pointerDragHold), `--input-string` into GOEDIT, and `--input-chords`
// land before auto reorder/pin. The type-in and drag boots are separate.
// M73z (#1638): raised 20 -> 32 so go-dogfood boot 04's acceptance
// chain (6-step pointer phase incl. the refocus rail click, chords,
// script2 tail, expect) finishes before the choreography's first
// close (n==2 + hold + 7 steps ~ tick 68).
// Claim 1747: raised 32 -> 64 after the pump fix. The seat drains WM_KEY
// ONE event per composite tick and Sleep(1)s after each while the
// launcher is closed, so a virtio chord burst drained inside one outer
// iteration costs N extra scheduler ticks of wall time. Observed on
// go-dogfood boot 04: the demo seat's first auto-close beat script2's
// `dui lower 4`, so the run's expect marker never arrived. The wider
// hold keeps the acceptance tail bounded but unable to lose that step.
const hidChordHold = 64

// pointerDragHold is one `--pointer-virtio 'x,y,d;x,y,u'` (4 messages × 2.5 s).
const pointerDragHold = 12

// prevPtrButtons is the last kind-19 flags low byte; rail click is a left
// down edge and drag-reorder commits on the matching up edge, matching
// Zig TABWM begin_tab_drag / end_tab_drag.
var (
	prevPtrButtons uint8
	railDragFrom   = -1 // source cell, or -1 when no drag is armed
	// contentDown tracks a pointer-down that went to the kernel as content
	// (#1688): the matching release is content too, wherever it lands.
	// Chrome downs (start surface, rail) never set it.
	contentDown bool
	// railHover is the M79b (#1705) hovered rail cell (index), or -1 while
	// the pointer rests off the rail. Paint state; updateRailHover owns it
	// and the entry marker.
	railHover = -1
	// railCloseHover is the rail cell whose close zone holds the pointer,
	// or -1 — the §2.4 Danger tint paintRail gives the close glyph under
	// it. updateRailHover tracks it on the same samples as railHover.
	railCloseHover = -1
	// godButtonHover rides the same samples for the god-menu button's
	// §2.3 hover face.
	godButtonHover bool
	// sashDragging is the M79c (#1706) sash latch: a pointer-down on the
	// split divider arms it, the matching release commits the drag at the
	// release x/y, and motion while armed is swallowed (chrome, never
	// content — same discipline as contentDown/rail, inverted). It is
	// disjoint from railDragFrom: a sash down returns before
	// beginRailDrag, so endRailDrag can never also reorder.
	sashDragging bool
	menuGesture  bool // survives dismissal/exec until every button is up
)

// seatChords is the registry's seat-scope dispatch, resolved once at init:
// every seat row maps its chord to the action hid.go implements. A chord
// not in the table is not the seat's — handleWmKey ignores it, and ADR 0009
// still routes KEY_DOWN to the focused app. Built from chords.Global so a
// table edit IS the dispatch edit; the host tests pin the action set.
var seatChords = func() map[chords.Chord]string {
	m := make(map[chords.Chord]string, len(chords.Global))
	for _, r := range chords.Global.SeatRows() {
		m[r.Chord] = r.Action
	}
	return m
}()

// chordEvent reduces one kind-21 WM_KEY to the registry's chord identity
// (the ADR 0009 modifier flags narrowed to the three the table names).
func chordEvent(e vi.Event) chords.Chord {
	var m chords.Mods
	if e.Flags&vi.ModCtrl != 0 {
		m |= chords.ModCtrl
	}
	if e.Flags&vi.ModShift != 0 {
		m |= chords.ModShift
	}
	if e.Flags&vi.ModAlt != 0 {
		m |= chords.ModAlt
	}
	return chords.Chord{Mods: m, Usage: uint8(e.Arg0)}
}

// runSeatAction is WHAT each registry action does; the registry owns WHICH
// chords fire. The seams (execApp, focusByIndex) are read at call time so
// tests can swap them exactly as before. No marker here: every apply*
// below prints its own, after the syscall that made it true.
func runSeatAction(action string, c chords.Chord) {
	switch action {
	case "launcher":
		openLauncher()
	case "start-surface":
		// M71e (#1564): Enter on an empty strip is the start surface's
		// keyboard affordance; a populated strip ignores plain Enter.
		if tabs.Count() == 0 {
			openLauncher()
		}
	case "cycle-focus":
		_ = applyAltTab(c.Mods&chords.ModShift != 0)
	case "focus-index":
		if i, ok := ctrlIndex(c.Usage); ok {
			_ = applyCtrlIndex(i)
		}
	case "pin":
		_ = applyHidPin()
	case "palette":
		// M121a (#2564): the summon chord's dispatch half. The modal half
		// (an already-open palette eats every key, including this chord as
		// a toggle) is handleLauncherKey's.
		openPalette()
	case "reopen":
		_ = applyReopen()
	case "duplicate":
		_ = applyDuplicate()
	case "close":
		_ = applyHidClose()
	case "move-left":
		_ = applyHidMove(-1)
	case "move-right":
		_ = applyHidMove(1)
	case "freeze-badge":
		_ = applyFreezeToggle()
	case "split-cycle":
		_ = applySplitCycle()
	case "snapshot-bundle":
		// M81g (#1767): the snapshot arm. It is a chord rather than a
		// timer on purpose — the card rules out scheduled snapshots, and
		// a bundle taken because time passed is a bundle nobody chose.
		// The chord's DEFINITION moved into the registry (a seat row);
		// this is what the row does.
		_ = saveSnapshot()
	case "nav-back":
		_ = applyNavStep(true)
	case "nav-forward":
		_ = applyNavStep(false)
	case "sel-paste":
		// M124e (#2584): shift+insert — the primary-paste chord.
		applySelPasteChord()
	case "undo":
		_ = applyUndo()
	}
}

func handleWmKey(e vi.Event) {
	// Escape dismisses the seat-owned notification center without stealing
	// ordinary app keystrokes when the overlay is closed.
	if notifyCenterOpen && e.Arg0 == 0x29 && e.Flags&(vi.ModCtrl|vi.ModShift|vi.ModAlt) == 0 {
		notifyCenterOpen = false
		notifyCenterPainted = false
		vi.ConsoleLine(MarkerNotifyCenterClose)
		return
	}
	// M115d (#2463): the open power menu's keys are the seat's alone —
	// the sink window holds focus, so a hosted app sees nothing anyway.
	if handlePowerKey(e) {
		return
	}
	if handleLauncherKey(e) {
		return
	}
	// M82c (#1770): dispatch IS the registry walk — one exact (mods, usage)
	// match, so there is no branch precedence to reason about (the old
	// scattered `if`s folded ctrl+shift+tab into the ctrl branch; the table
	// carries the reverse cycle as its own row). A matched row is consumed
	// even when its action honestly no-ops, exactly as before; an
	// unmatched chord falls through to nothing.
	c := chordEvent(e)
	if action, ok := seatChords[c]; ok {
		runSeatAction(action, c)
	}
}

// chordRegistryPrologue is M82c's guest-side evidence, run once at seat
// startup right after registration (seat.go):
//
//   - the shipped table must pass the checker — fail-closed, Exit(1), if
//     it ever does not. A registry that lies about ownership must stop
//     the seat, not print a warning;
//   - when the harness seeds /host/GOTABWM.CHORDCONFLICT, the checker is
//     fed the deliberately conflicting fixture and its refusal is printed
//     with the full named error — the in-guest half of the fixture test
//     (go-wm-hid run 08). The shipped table is untouched either way; the
//     fixture boot also dumps the whole table so the gate can pin rows;
//   - the summary line names the counts per owner class.
func chordRegistryPrologue() {
	if err := chords.Global.Validate(); err != nil {
		vi.ConsoleLine(MarkerChordsRefused + err.Error())
		vi.Exit(1)
	}
	attempted, fixtureErr := chordFixtureAttempt()
	if attempted {
		if fixtureErr != nil {
			vi.ConsoleLine(MarkerChordsRefused + fixtureErr.Error())
		} else {
			vi.ConsoleLine(MarkerChordsFixtureOK + "checker accepted " + chords.FixtureOwner() + "'s ctrl+shift+p claim")
		}
	}
	var kernel, seat, app int
	for _, r := range chords.Global {
		switch {
		case r.Scope == chords.ScopeKernelTerminal:
			kernel++
		case r.Scope == chords.ScopeSeat:
			seat++
		default:
			app++
		}
	}
	vi.ConsoleLine(chordSummary(len(chords.Global), seat, kernel, app))
	if attempted {
		dumpChordTable()
	}
}

// chordSummary renders the prologue's one summary line: the registry size
// and the counts per owner class.
func chordSummary(n, seat, kernel, app int) string {
	return MarkerChords +
		vi.Itoa64(int64(n)) +
		" seat=" + vi.Itoa64(int64(seat)) +
		" kernel=" + vi.Itoa64(int64(kernel)) +
		" app=" + vi.Itoa64(int64(app))
}

// chordFixtureAttempt feeds the checker the deliberately conflicting
// fixture when the harness seeded the trigger file. It reports whether the
// fixture was attempted and the checker's verdict — nil error when
// attempted means the checker ACCEPTED a table it must refuse (the loud
// failure the gates assert absent). No printing: the prologue owns the
// markers, the host tests own the verdict.
func chordFixtureAttempt() (attempted bool, err error) {
	h, r := openFile(chordsFixtureTriggerPath, vi.ModeRead)
	if r < 0 {
		return false, nil
	}
	vi.FileClose(uint32(h))
	bad := append(chords.Global[:0:0], chords.Global...)
	bad = append(bad, chords.FixtureRow())
	return true, bad.Validate()
}

// dumpChordTable prints every row, one line each, as the fixture boot's
// registry record:
//
//	gotabwm: chord <chord> owner=<owner> scope=<scope> <label>
func dumpChordTable() {
	for _, r := range chords.Global {
		vi.ConsoleLine(MarkerChord + r.Chord.String() +
			" owner=" + r.Owner +
			" scope=" + string(r.Scope) +
			" " + r.Label)
	}
}

// applyNavStep is Zig TABWM nav_back_active / nav_forward_active: step the
// FOCUSED tab's history one entry and queue the target so the app picks it up
// on its next nav-poll. `back` selects the direction. False when nothing is
// focused, or the cursor is already at that end — an honest no-op that
// leaves the queued slot alone, so a refused step cannot swallow the target
// an earlier accepted step is still waiting to deliver.
func applyNavStep(back bool) bool {
	id, ok := tabs.Focused()
	if !ok {
		return false
	}
	var (
		path  string
		moved bool
	)
	if back {
		path, moved = tabs.NavBack(id)
	} else {
		path, moved = tabs.NavForward(id)
	}
	if !moved {
		return false
	}
	setPendingNav(id, path)
	// The user just acted on the hosted tab: the demo close countdown
	// restarts, or the close can land between the queued target and the
	// client's next poll (go-wm-tabs run 08).
	hostTicksLeft = hostTicks
	marker := MarkerNavForward
	if back {
		marker = MarkerNavBack
	}
	vi.ConsoleLine(marker + vi.Itoa64(int64(id)) + " path=" + path)
	return true
}

// applyFreezeToggle is Zig TABWM freeze_toggle: flip the frozen badge on the
// focused tab and report which way it went. M71e (#1564) is deliberate about
// the shape — this is a BADGE, not a lock: Zig checks `frozen` nowhere in its
// close path, and neither does GOTABWM, so a frozen tab still closes.
func applyFreezeToggle() bool {
	id, ok := tabs.Focused()
	if !ok {
		return false
	}
	if tabs.Freeze(id) {
		vi.ConsoleLine(MarkerFreeze + vi.Itoa64(int64(id)) + " on")
		dumpOrder()
		// M79g (#1718): the badge is part of the session, so both
		// directions persist — a freeze the file does not carry was
		// never saved, only displayed.
		noteSessionMutation()
		return true
	}
	if tabs.Thaw(id) {
		vi.ConsoleLine(MarkerThaw + vi.Itoa64(int64(id)))
		dumpOrder()
		noteSessionMutation()
		return true
	}
	return false
}

// applyReopen is Zig TABWM reopen_last_closed(): pop the bounded LIFO, skip
// entries with no recorded bin, and re-exec the executable as a new hosted
// tab. A tab the seat never spawned has no bin and is an honest no-op.
func applyReopen() bool {
	c, ok := tabs.ReopenLastClosed()
	if !ok {
		return false
	}
	pid, err := execApp(c.Bin)
	if err != nil {
		vi.ConsoleLine(MarkerReopenMissing + c.Bin)
		seatRefusalErr(err, "exec "+c.Bin, c.Bin)
		return false
	}
	// M125a (#2586): a reopen redelivers the close-time blob — staged by
	// the exec'd pid so the app's own declare attaches it to the new row,
	// and its restore_state request hands it back.
	stagePendingState(pid, c.StateVer, c.State)
	vi.ConsoleLine(MarkerReopen + c.Bin)
	return true
}

// applyDuplicate is Zig TABWM duplicate_active_tab(): re-exec the focused
// tab's executable so it joins as a new tab. Honest no-op when nothing is
// focused or the focused tab has no recorded bin.
func applyDuplicate() bool {
	bin, ok := tabs.DuplicateFocused()
	if !ok {
		return false
	}
	if _, err := execApp(bin); err != nil {
		vi.ConsoleLine(MarkerDuplicateMissing + bin)
		seatRefusalErr(err, "exec "+bin, bin)
		return false
	}
	vi.ConsoleLine(MarkerDuplicate + bin)
	return true
}

// applyUndo is the M121e (#2568) undo dispatch: the seat owns ctrl+z at
// seat scope and routes it — a focused LIVE tab's own app-scope binding
// answers the KEY_DOWN the kernel already delivered (GOEDIT's buffer
// undo, GOFILES's trash restore, a shell's own ctrl+z meaning), and the
// marker names the route, never the revert — the revert is the app's own
// marker or silence. With no tab focused the strip owns undo: the seat's
// own answer is the reopen LIFO (applyReopen prints its own marker, and
// an empty LIFO stays the honest silent no-op). A session placeholder
// row is not a live client — nothing routes and nothing reopens.
func applyUndo() bool {
	id, ok := tabs.Focused()
	if !ok {
		vi.ConsoleLine(MarkerUndo + "seat")
		return applyReopen()
	}
	if id >= sessionIDBase {
		return false
	}
	vi.ConsoleLine(MarkerUndo + "id=" + vi.Itoa64(int64(id)))
	return true
}

// applyHidClose is the M121b (#2565) close chord: close the FOCUSED tab
// through the same closeTabByID seam the close-x and the choreography use,
// so `host close id=` / `tab close id=` carry exactly one shape and the
// close lands on the reopen LIFO for ctrl+shift+t. The focused close moves
// focus to the neighbour (M62b) and prints the focus markers itself.
func applyHidClose() bool {
	id, ok := tabs.Focused()
	if !ok {
		return false
	}
	return closeTabByID(id)
}

// applyHidMove is the M121b (#2565) move chord: shift the focused tab one
// rail cell in dir through the same Reorder path the rail drag commits on
// (applyRailReorder), so `reorder from->to`, the order dump, the session
// write and the split re-layout are exactly one shape. An edge cell is an
// honest no-op — no wrap, matching Zig's move_tab.
func applyHidMove(dir int) bool {
	id, ok := tabs.Focused()
	if !ok {
		return false
	}
	from := tabs.index(id)
	to := from + dir
	if to < 0 || to >= tabs.Count() {
		return false
	}
	return applyRailReorder(from, to)
}

// ctrlIndex maps the USB HID number-row usages for 1..9 to rail indexes.
// Ctrl+0 is not a rail shortcut.
func ctrlIndex(usage uint8) (int, bool) {
	if usage < 0x1e || usage > 0x26 {
		return 0, false
	}
	return int(usage - 0x1d), true
}

// altTabNext is Zig TABWM's alt_tab_next: the tab after `focus`, wrapping.
// Fewer than two tabs is a no-op. shift inverts. focus out of range starts at 0.
func altTabNext(count, focus int, shift bool) (int, bool) {
	if count < 2 {
		return 0, false
	}
	cur := focus
	if cur < 0 || cur >= count {
		cur = 0
	}
	if shift {
		if cur == 0 {
			return count - 1, true
		}
		return cur - 1, true
	}
	return (cur + 1) % count, true
}

func applyHidPin() bool {
	id, ok := tabs.Focused()
	if !ok {
		return false
	}
	if !tabs.Pin(id) {
		return false
	}
	vi.ConsoleLine(MarkerPin + "id=" + vi.Itoa64(int64(id)) + " on")
	dumpOrder()
	// M79g (#1718): Pin() re-partitions the strip (pinned left), so the
	// file has to be rewritten — an already-pinned tab returns false above
	// and costs nothing.
	noteSessionMutation()
	return true
}

// focusByIndex is the shared success path for Alt+Tab, Ctrl+Tab, and
// Ctrl+1..9. Tests replace it to pin dispatch without the guest-only
// slot-65 syscall.
var focusByIndex = func(i int) bool {
	if i < 0 || i >= tabs.Count() {
		return false
	}
	id := tabs.At(i).ID
	if !focusHosted(id) {
		return false
	}
	vi.ConsoleLine(MarkerAltTab + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(id)))
	dumpOrder()
	return true
}

func applyAltTab(shift bool) bool {
	i, ok := altTabNext(tabs.Count(), tabs.focus, shift)
	if !ok {
		return false
	}
	return focusByIndex(i)
}

func applyCtrlIndex(index int) bool {
	return index >= 1 && index <= tabs.Count() && focusByIndex(index-1)
}

func focusHosted(id uint32) bool {
	if id == 0 {
		return false
	}
	if vi.WmctlTaskbarClick(id) != 0 {
		return false
	}
	if !tabs.FocusTab(id) {
		return false
	}
	hostedApp = id
	return true
}

func handleWmPointer(e vi.Event) {
	px := e.Arg0 & 0xffff
	py := e.Arg0 >> 16
	btn := uint8(e.Flags & 0xff)
	down := pointerDownEdge(btn, prevPtrButtons)
	up := pointerUpEdge(btn, prevPtrButtons)
	// M124e (#2584): the middle-button's own down edge — the primary-paste
	// gesture. It never starts a chrome path (those all key on the left
	// edge), so it reaches the content tail where the delivery happens.
	midDown := btn&hidBtnMiddle != 0 && prevPtrButtons&hidBtnMiddle == 0
	prevPtrButtons = btn
	// M124a (#2580): an armed guest drag owns every pointer sample —
	// motion feeds the ghost's hit-test, the release edge settles the
	// drop, and no chrome (toast, rail, sash, launcher) can see a click
	// mid-drag while nothing forwards to content. The press that armed
	// it already went through the normal content path before the
	// drag_begin RPC landed; serveDragBegin clears its latches.
	if drag.armed {
		if up {
			contentDown, railDragFrom, sashDragging = false, -1, false
		}
		handleDragPointer(px, py, up)
		return
	}
	if menuGesture {
		if btn == 0 {
			menuGesture = false
		}
		return
	}
	// M79k (#1720): the notify strip is chrome, so a press on a toast is
	// consumed HERE — it dismisses the toast and focuses its SENDER, and
	// it never reaches the content forward below (a stray content drag
	// inside a hosted pane would outlive the toast). The HIT decides
	// consumption, not whether the focus leg then succeeded: a press is
	// either on the toast or it is not.
	//
	// It comes FIRST, ahead of the launcher's own block below, because the
	// strip is painted LAST (compositeTick) and the pointer path has to
	// agree with the paint order: what is on top has to be what the click
	// finds. The launcher's block returns early for every button, so a
	// press on a toast that fired while the launcher was open used to be
	// swallowed there — it neither clicked the toast nor reached content,
	// it just closed the launcher under a toast the user could see. With
	// the #2054 left-edge strip the two rects DO overlap (the strip is
	// x<launchW, the toast column x<216), which makes the order load-
	// bearing rather than a coincidence: the toast is painted last, so
	// the press finds it first. TestToastHitPrecedesTheLauncher pins it.
	if down {
		if notifyCenterClick(px, py) {
			return
		}
	}
	// The center is painted over the content, so every pointer sample inside
	// its panel belongs to it, not to the app underneath. Down edges are
	// handled above; this also consumes motion and release samples.
	if notifyCenterHit(px, py, vi.ScanoutWidth, vi.ScanoutHeight) {
		return
	}
	if down {
		if _, onToast := notifyHit(px, py, vi.ScanoutWidth, vi.ScanoutHeight); onToast {
			notifyClicked(px, py)
			if launch.open {
				menuGesture = true
				_ = ensureLauncherFocus()
			}
			return
		}
	}
	// M115d (#2463): the open power menu is chrome-modal the same way
	// the launcher is — a press on its row runs the verb, a press
	// anywhere else dismisses it, and nothing reaches content either
	// way.
	if powerMenuOpen {
		if down {
			dismissPowerMenu()
			if r := powerMenuRowAt(px, py, vi.ScanoutWidth, vi.ScanoutHeight); r >= 0 {
				powerSel = r
				runPowerRow(r)
			}
		}
		return
	}
	if launch.open {
		if btn != 0 {
			menuGesture = true
			railDragFrom, contentDown, sashDragging = -1, false, false
		}
		if down {
			i, ok := launchRowAt(px, py)
			if !ok {
				x, y := int(px), int(py)
				if x < launchX || x >= launchX+launchW || y < launchY || y >= launchY+launch.panelH() {
					dismissLauncher()
				}
				return
			}
			launch.sel = i
			execSelected()
		}
		return
	}
	if down {
		if powerBtnHit(px, py, vi.ScanoutWidth, vi.ScanoutHeight) {
			menuGesture = true
			railDragFrom, contentDown, sashDragging = -1, false, false
			openPowerMenu()
			return
		}
		if godMenuHit(px, py, vi.ScanoutWidth, vi.ScanoutHeight) {
			menuGesture = true
			railDragFrom, contentDown, sashDragging = -1, false, false
			openLauncher()
			return
		}
		// M71e (#1564): on an empty strip the start surface is the click
		// target. Checked before the rail so it cannot be shadowed by a
		// rail cell that happens to span the point (the rail has no cells
		// when the strip is empty, so this is belt-and-braces).
		if tabs.Count() == 0 && startSurfaceHit(px, py) {
			menuGesture = true
			openLauncher()
			return
		}
		// M79b (#1705): the close-x zone is its own hit target — it closes
		// the cell's tab and never focuses, never starts a drag, and never
		// reaches content (hit-test honesty). The rest of the cell keeps
		// the click/drag behaviour below, byte for byte.
		updateRailHover(px, py, false)
		if i, ok := railCloseZoneAt(px, py, vi.ScanoutWidth, tabs.Count(), RailHeight); ok {
			railDragFrom = -1
			applyRailClose(i)
			return
		}
		// M79c (#1706): the sash is chrome between the rail and the
		// content forward. A down on the divider arms the drag and
		// consumes the press: no rail drag, no click/focus change, no
		// content forward (a stray selection drag inside a pane would
		// otherwise shadow the resize). The rail (y < RailHeight) and
		// the divider zone are disjoint by construction (sashZoneAt),
		// so the order against beginRailDrag below cannot matter — but
		// the armed latch must be set before any of those run.
		if sashZoneAt(px, py, tabs.Split(),
			tabs.sashCenter(uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight)),
			vi.ScanoutWidth, vi.ScanoutHeight) {
			railDragFrom = -1
			sashDragging = true
			return
		}
		beginRailDrag(px, py)
		_, onRail := railCellAt(px, py, vi.ScanoutWidth, tabs.Count(), RailHeight)
		_ = applyRailClick(px, py)
		if !onRail {
			// #1688: not chrome — content for the kernel's local path
			// (terminal text selection, mouse-tracking reports). The
			// kernel derives press/release edges from this serialized
			// stream itself; consumed chrome is never forwarded.
			contentDown = true
			forwardContentPointer(px, py, btn)
		}
		return
	}
	if up {
		updateRailHover(px, py, false)
		// M79c (#1706): the sash release edge. The divider position is
		// the release point (an x for a vertical split, a y for a
		// horizontal one); applySashDrag clamps it into the pane minima
		// and refuses a release on the armed position. A sash press
		// never armed the rail drag and never set contentDown, so
		// neither fires here — return with the drag consumed.
		if sashDragging {
			sashDragging = false
			pos := int(px)
			if tabs.Split() == SplitHoriz {
				pos = int(py)
			}
			_ = applySashDrag(pos)
			return
		}
		_ = endRailDrag(px, py)
		if contentDown {
			forwardContentPointer(px, py, btn)
			contentDown = false
		}
		return
	}
	// #1688: motion is content too, unless it rides the rail chrome —
	// the only pointer consumer here besides the launcher above.
	// M79b (#1705): motion over the rail is hover — the tint follows the
	// pointer and the entry marker prints on cell transitions only.
	updateRailHover(px, py, true)
	// M79c (#1706): motion with a sash armed is an in-progress resize, not
	// content. Swallow it: forwarding held-button motion to the kernel's
	// local path would start a selection drag inside the pane under the
	// pointer. No live preview either (the seat paints no content-area
	// chrome); the rects move once, on the release edge above.
	if sashDragging {
		return
	}
	if godMenuHit(px, py, vi.ScanoutWidth, vi.ScanoutHeight) {
		return
	}
	if _, onToast := notifyHit(px, py, vi.ScanoutWidth, vi.ScanoutHeight); onToast {
		// Chrome under the pointer, like the rail: not content. A drag
		// that starts on a toast is the toast's, not a content forward.
		return
	}
	if _, onRail := railCellAt(px, py, vi.ScanoutWidth, tabs.Count(), RailHeight); !onRail {
		if midDown {
			// M124e (#2584): a middle press inside a hosted pane pastes
			// the seat's primary selection into that window. The sample
			// still forwards as content — the click is real, the paste
			// is the seat's.
			applySelPasteAt(px, py)
		}
		forwardContentPointer(px, py, btn)
	}
}

func pointerDownEdge(btn, prev uint8) bool {
	return btn&hidBtnLeft != 0 && prev&hidBtnLeft == 0
}

func pointerUpEdge(btn, prev uint8) bool {
	return btn&hidBtnLeft == 0 && prev&hidBtnLeft != 0
}

// railCloseZoneAt is the M79b (#1705) close-x hit test: the cell's rightmost
// railCloseW px (tabs.go's railClose geometry), full strip height. It
// resolves the cell exactly like railCellAt and the width exactly like
// paintRail, so the hit zone can never disagree with the painted glyph.
// False everywhere the close-x is not a target.
func railCloseZoneAt(px, py uint32, width, n, stripH int) (int, bool) {
	i, ok := railCellAt(px, py, width, n, stripH)
	if !ok {
		return 0, false
	}
	cellW := width / n
	if cellW < 48 {
		cellW = 48
	}
	x := i * cellW
	w := cellW
	if x+w > width {
		w = width - x
	}
	// The zone is the PAINTED cell's rightmost railCloseW px. The upper
	// bound matters for railCellAt's remainder rule: pixels past n*cellW
	// resolve to the last cell but sit outside its paint, so they stay
	// click/drag territory and are never a close-x target.
	if w < railCloseW || int(px) < x+w-railCloseW || int(px) >= x+w {
		return 0, false
	}
	return i, true
}

// updateRailHover tracks M79b (#1705) hover state: railHover is the rail
// cell under the pointer (paintRail tints it), -1 anywhere else. The marker
// is motion-only and prints on ENTRY (a transition, markRail's discipline) —
// a press or release also rests the pointer on a cell, so state follows, but
// `rail-hover` names a hover, never a click.
func updateRailHover(px, py uint32, motion bool) {
	prev := railHover
	// The button's §2.3 hover face and the rail close glyph's §2.4 Danger
	// tint ride the same pointer samples the cell hover already takes.
	godButtonHover = godMenuHit(px, py, vi.ScanoutWidth, vi.ScanoutHeight)
	if j, ok := railCloseZoneAt(px, py, vi.ScanoutWidth, tabs.Count(), RailHeight); ok {
		railCloseHover = j
	} else {
		railCloseHover = -1
	}
	i, ok := railCellAt(px, py, vi.ScanoutWidth, tabs.Count(), RailHeight)
	if !ok {
		railHover = -1
		return
	}
	railHover = i
	if motion && i != prev {
		vi.ConsoleLine(MarkerRailHover + vi.Itoa64(int64(tabs.At(i).ID)))
	}
}

// applyRailClose is the M79b (#1705) close-x action: close the cell's tab by
// id through the same closeTabByID seam every other close uses, so the
// `host close id=` / `tab close id=` pair is exactly one shape. No focus
// change first — the click targets a button, not a cell.
func applyRailClose(i int) bool {
	if i < 0 || i >= tabs.Count() {
		return false
	}
	return closeTabByID(tabs.At(i).ID)
}

// railCellAt is the top-strip hit-test (M63c). Equal-width cells matching
// paintRail (`cellW = width/n`, min 48). py must be in the rail; the rail
// wins over any pane whose rect includes y=0. Close-x is not a target —
// the cell body is the click/drag target (railCloseZoneAt takes the zone).
func railCellAt(px, py uint32, width, n, stripH int) (int, bool) {
	if n <= 0 || width <= 0 || stripH <= 0 || py >= uint32(stripH) {
		return 0, false
	}
	cellW := width / n
	if cellW < 48 {
		cellW = 48
	}
	i := int(px) / cellW
	if i < 0 {
		return 0, false
	}
	if i >= n {
		i = n - 1
	}
	return i, true
}

func applyRailClick(px, py uint32) bool {
	n := tabs.Count()
	i, ok := railCellAt(px, py, vi.ScanoutWidth, n, RailHeight)
	if !ok {
		return false
	}
	id := tabs.At(i).ID
	if id == 0 {
		return false
	}
	if fid, focused := tabs.Focused(); focused && fid == id {
		return false
	}
	if !focusHosted(id) {
		return false
	}
	vi.ConsoleLine(MarkerRailClick + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(id)))
	dumpOrder()
	return true
}

func beginRailDrag(px, py uint32) {
	railDragFrom = -1
	i, ok := railCellAt(px, py, vi.ScanoutWidth, tabs.Count(), RailHeight)
	if ok {
		railDragFrom = i
	}
}

func endRailDrag(px, py uint32) bool {
	from := railDragFrom
	railDragFrom = -1
	if from < 0 {
		return false
	}
	to, ok := railCellAt(px, py, vi.ScanoutWidth, tabs.Count(), RailHeight)
	if !ok {
		return false
	}
	return applyRailReorder(from, to)
}

// applyRailReorder is Zig TABWM reorder_tab: Reorder() then the existing
// `gotabwm: reorder from->to` marker. Same-cell release is a click no-op.
// M79g (#1718): a drag that moved a tab persists SESSION.TABS right here,
// so the new order is what the next boot restores.
//
// M79c (#1706): a reorder while split re-proposes both pane rects. The
// rects are positional (index 0 = first pane), so without this the panes
// would silently swap which app is on the left — worse than the relayout.
// The dumps are the record; no extra marker.
func applyRailReorder(from, to int) bool {
	if !tabs.Reorder(from, to) {
		return false
	}
	vi.ConsoleLine(MarkerReorder + vi.Itoa64(int64(from)) + "->" + vi.Itoa64(int64(to)))
	dumpOrder()
	noteSessionMutation()
	if tabs.Split() == SplitNone || tabs.Count() != 2 {
		return true
	}
	ra, rb, ok := tabs.PaneRects(uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
	if !ok {
		return false
	}
	a, b := tabs.At(0), tabs.At(1)
	if !applyRect(a.ID, ra) || !applyRect(b.ID, rb) {
		return false
	}
	kind := tabs.Split()
	dumpTab(a, ra, kind)
	dumpTab(b, rb, kind)
	_ = writeLayoutFile()
	return true
}
