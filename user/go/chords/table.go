// table.go — the shipped registry: every global chord this OS dispatches,
// with its owner and dispatch point, transcribed from the sources the rows
// name. The seat's rows are the chords gotabwm/hid.go dispatches FROM; the
// kernel's rows record the frozen chrome consumers in kernel/src/input.zig
// (the M49 SD5 terminal-window block, M73k #1637 search, M80k #1727
// hygiene); the app rows are each app's own focused KEY_DOWN chords,
// grep-verified in user/go (shlib/edit.go, edit/main.go, note/main.go,
// goset/main.go).
package chords

// Global is THE table. Row order is display order (kernel chrome, seat,
// apps) and, within a scope, the dispatch's own history; the checker and
// the seat's dispatch do not depend on it.
var Global = Table{
	// --- kernel chrome (frozen): consumed by kernel/src/input.zig while a
	// kernel terminal front-end is focused. Recorded, never re-homed.
	{Chord{ModCtrl | ModShift, UsageC}, "kernel", ScopeKernelTerminal, "",
		"copy the terminal selection to the clipboard", "#1132 (M49 SD5)", true},
	{Chord{ModCtrl | ModShift, UsageV}, "kernel", ScopeKernelTerminal, "",
		"paste the clipboard into the terminal", "#1132 (M49 SD5)", true},
	{Chord{ModCtrl | ModShift, UsageF}, "kernel", ScopeKernelTerminal, "",
		"search the terminal scrollback", "#1637 (M73k)", true},
	{Chord{ModCtrl | ModShift, UsageK}, "kernel", ScopeKernelTerminal, "",
		"clear the terminal scrollback and snap to tail", "#1727 (M80k)", true},
	{Chord{ModCtrl | ModShift, UsageR}, "kernel", ScopeKernelTerminal, "",
		"soft reset the terminal (styles and modes, grid intact)", "#1727 (M80k)", true},
	{Chord{ModCtrl | ModShift | ModAlt, UsageR}, "kernel", ScopeKernelTerminal, "",
		"full reset the terminal (RIS)", "#1727 (M80k)", true},
	{Chord{0, UsagePageUp}, "kernel", ScopeKernelTerminal, "",
		"scroll the terminal view up a page", "#1132 (M49 SD5)", true},
	{Chord{0, UsagePageDown}, "kernel", ScopeKernelTerminal, "",
		"scroll the terminal view down a page", "#1132 (M49 SD5)", true},
	{Chord{ModShift, UsageUp}, "kernel", ScopeKernelTerminal, "",
		"scroll the terminal view one row up", "#1132 (M49 SD5)", true},
	{Chord{ModShift, UsageDown}, "kernel", ScopeKernelTerminal, "",
		"scroll the terminal view one row down", "#1132 (M49 SD5)", true},
	{Chord{ModShift, UsageHome}, "kernel", ScopeKernelTerminal, "",
		"jump the terminal view to the oldest row", "#1132 (M49 SD5)", true},
	{Chord{ModShift, UsageEnd}, "kernel", ScopeKernelTerminal, "",
		"jump the terminal view to the tail", "#1132 (M49 SD5)", true},

	// --- seat: GOTABWM's own chords, dispatched FROM this table by
	// hid.go's handleWmKey.
	{Chord{ModCtrl, UsageSpace}, "seat", ScopeSeat, "launcher",
		"summon the launcher (the APPS.TXT catalogue); while it is open, re-opens it", "#1530 (M69c)", false},
	{Chord{0, UsageEnter}, "seat", ScopeSeat, "start-surface",
		"on an empty strip, open the start surface's launcher", "#1564 (M71e)", false},
	{Chord{ModAlt, UsageTab}, "seat", ScopeSeat, "cycle-focus",
		"focus the next tab, wrapping", "#1420 (M63b)", false},
	{Chord{ModAlt | ModShift, UsageTab}, "seat", ScopeSeat, "cycle-focus",
		"focus the previous tab, wrapping", "#1420 (M63b)", false},
	{Chord{ModCtrl, UsageTab}, "seat", ScopeSeat, "cycle-focus",
		"focus the next tab, wrapping (the ctrl spelling)", "#1717 (M79f)", false},
	{Chord{ModCtrl | ModShift, UsageTab}, "seat", ScopeSeat, "cycle-focus",
		"focus the previous tab, wrapping (the ctrl spelling)", "#1717 (M79f)", false},
	{Chord{ModCtrl, UsageDigit1}, "seat", ScopeSeat, "focus-index",
		"focus rail cell 1; out of range is a no-op", "#1717 (M79f)", false},
	{Chord{ModCtrl, UsageDigit1 + 1}, "seat", ScopeSeat, "focus-index",
		"focus rail cell 2; out of range is a no-op", "#1717 (M79f)", false},
	{Chord{ModCtrl, UsageDigit1 + 2}, "seat", ScopeSeat, "focus-index",
		"focus rail cell 3; out of range is a no-op", "#1717 (M79f)", false},
	{Chord{ModCtrl, UsageDigit1 + 3}, "seat", ScopeSeat, "focus-index",
		"focus rail cell 4; out of range is a no-op", "#1717 (M79f)", false},
	{Chord{ModCtrl, UsageDigit1 + 4}, "seat", ScopeSeat, "focus-index",
		"focus rail cell 5; out of range is a no-op", "#1717 (M79f)", false},
	{Chord{ModCtrl, UsageDigit1 + 5}, "seat", ScopeSeat, "focus-index",
		"focus rail cell 6; out of range is a no-op", "#1717 (M79f)", false},
	{Chord{ModCtrl, UsageDigit1 + 6}, "seat", ScopeSeat, "focus-index",
		"focus rail cell 7; out of range is a no-op", "#1717 (M79f)", false},
	{Chord{ModCtrl, UsageDigit1 + 7}, "seat", ScopeSeat, "focus-index",
		"focus rail cell 8; out of range is a no-op", "#1717 (M79f)", false},
	{Chord{ModCtrl, UsageDigit1 + 8}, "seat", ScopeSeat, "focus-index",
		"focus rail cell 9; out of range is a no-op", "#1717 (M79f)", false},
	{Chord{ModCtrl | ModShift, UsageN}, "seat", ScopeSeat, "pin",
		"pin the focused tab — re-homed off ctrl+shift+p, which the " +
			"command palette owns since M121a", "#1420 (M63b); chord #2564 (M121a)", false},
	{Chord{ModCtrl | ModShift, UsageT}, "seat", ScopeSeat, "reopen",
		"reopen the most recently closed tab", "#1563 (M71d)", false},
	{Chord{ModCtrl | ModShift, UsageD}, "seat", ScopeSeat, "duplicate",
		"duplicate the focused tab", "#1563 (M71d)", false},
	{Chord{ModCtrl | ModShift, UsageS}, "seat", ScopeSeat, "snapshot-bundle",
		"take a snapshot bundle (settings + SESSION.TABS + a docs selection) " +
			"to /host/SNAPSHOT.BUNDLE", "#1767 (M81g)", false},
	{Chord{ModCtrl | ModShift, UsageF}, "seat", ScopeSeat, "freeze-badge",
		"toggle the focused tab's frozen badge — coexists with the kernel's " +
			"terminal-search row above: two dispatch points, one chord",
		"#1564 (M71e)", false},
	{Chord{ModCtrl | ModShift, UsageV}, "seat", ScopeSeat, "split-cycle",
		"cycle the split none -> V -> H -> none — coexists with the kernel's " +
			"terminal-paste row above: two dispatch points, one chord",
		"#1706 (M79c)", false},
	{Chord{ModCtrl | ModShift, UsageLeftBracket}, "seat", ScopeSeat, "nav-back",
		"step the focused tab's history back", "#1708 (M79e)", false},
	{Chord{ModCtrl | ModShift, UsageRightBracket}, "seat", ScopeSeat, "nav-forward",
		"step the focused tab's history forward", "#1708 (M79e)", false},
	{Chord{ModCtrl | ModShift, UsageP}, "seat", ScopeSeat, "palette",
		"summon the command palette — tabs, recent files, settings, " +
			"help topics and this registry, subsequence-ranked", "#2564 (M121a)", false},
	// M124e (#2584): the primary-paste chord is shift+insert, NOT the
	// card's ctrl+shift+v — the seat row above already owns that chord for
	// split-cycle (M79c) and the kernel's terminal-window path owns it for
	// clipboard paste (M73e), so a third meaning would double-fire on the
	// same keystroke. Shift+Insert is the canonical X11 primary-paste
	// spelling and was free at every scope.
	{Chord{ModShift, UsageInsert}, "seat", ScopeSeat, "sel-paste",
		"paste the seat's primary selection into the focused cap'd tab " +
			"— ctrl+shift+v is split-cycle (seat) and tty clipboard paste " +
			"(kernel), so primary rides the canonical chord",
		"#2584 (M124e)", false},
	// M190a (#3236): the clipboard-history menu. v is doubly taken —
	// split-cycle at this scope (M79c) and tty clipboard paste at
	// kernel-terminal scope (M73e) — and the cv-input harness's chord
	// vocabulary has no ctrl+alt+<letter> spelling, so the summon rides
	// ctrl+shift+i: free at every scope, the insert-adjacent letter.
	{Chord{ModCtrl | ModShift, UsageI}, "seat", ScopeSeat, "clip-menu",
		"summon the clipboard-history paste menu — the seat's ring of " +
			"the last 16 typed clips; ctrl+shift+v is split-cycle (seat) " +
			"and tty clipboard paste (kernel), so history rides 'i'",
		"#3236 (M190a)", false},
	// M121b (#2565): the tab-manipulation chords. Close rides ctrl+shift+w
	// — the card's proposed ctrl+w is GOSH.ELF's kill-word (the app row
	// below, "the chord the seat must never bind"); a seat row on it would
	// eat the editor's key. The move pair rides the card's own
	// ctrl+shift+pageup/pagedown — the kernel's frozen scroll rows are the
	// unmodified spellings, one modifier block down.
	{Chord{ModCtrl | ModShift, UsageW}, "seat", ScopeSeat, "close",
		"close the focused tab — ctrl+w stays GOSH.ELF's kill-word",
		"#2565 (M121b)", false},
	{Chord{ModCtrl | ModShift, UsagePageUp}, "seat", ScopeSeat, "move-left",
		"move the focused tab one rail cell left", "#2565 (M121b)", false},
	{Chord{ModCtrl | ModShift, UsagePageDown}, "seat", ScopeSeat, "move-right",
		"move the focused tab one rail cell right", "#2565 (M121b)", false},
	// M121e (#2568): the undo chord. The seat row owns the chord's dispatch:
	// a focused tab answers it through its own app-scope binding (the raw
	// KEY_DOWN reaches it per ADR 0009 — the seat routes, never swallows),
	// and the strip-focused case is the seat's own undo (reopen the last
	// closed tab). A tty-bound front-end keeps the keystroke's own meaning
	// — GOSH's suspend convention is not an undo the seat may take.
	{Chord{ModCtrl, UsageZ}, "seat", ScopeSeat, "undo",
		"dispatch undo to the focused tab — with the strip focused, " +
			"reopen the last closed tab", "#2568 (M121e)", false},
	// M132a (#2752): the M132 wave's RESERVED seat chords — ADR 0007's
	// "M132 wave reservations" rows R4–R6, landed ahead of their handlers
	// so no other lane can bind the spellings. A row whose action has no
	// runSeatAction case is an honest no-op: the seat routes, never
	// swallows, and the focused app's KEY_DOWN is unaffected (ADR 0009 —
	// pinned by hid_test's TestReservedChordsForwardAsNoOps). The named
	// consumer lands the handler; the row is the claim.
	{Chord{ModCtrl | ModAlt, UsageLeft}, "seat", ScopeSeat, "pane-focus-left",
		"focus the pane left of the focused pane (reserved; M137a implements)",
		"#2752 (M132a)", false},
	{Chord{ModCtrl | ModAlt, UsageRight}, "seat", ScopeSeat, "pane-focus-right",
		"focus the pane right of the focused pane (reserved; M137a implements)",
		"#2752 (M132a)", false},
	{Chord{ModCtrl | ModAlt, UsageUp}, "seat", ScopeSeat, "pane-focus-up",
		"focus the pane above the focused pane (reserved; M137a implements)",
		"#2752 (M132a)", false},
	{Chord{ModCtrl | ModAlt, UsageDown}, "seat", ScopeSeat, "pane-focus-down",
		"focus the pane below the focused pane (reserved; M137a implements)",
		"#2752 (M132a)", false},
	{Chord{ModCtrl | ModAlt, UsagePageUp}, "seat", ScopeSeat, "space-prev",
		"switch to the previous space",
		"#2752 (M132a)", false},
	{Chord{ModCtrl | ModAlt, UsagePageDown}, "seat", ScopeSeat, "space-next",
		"switch to the next space (creates it at the end)",
		"#2752 (M132a)", false},
	{Chord{ModCtrl | ModShift, UsageE}, "seat", ScopeSeat, "summon-emoji",
		"summon the emoji picker — launch GOEMOJI.ELF by name " +
			"(M146a ships the target)",
		"#2752 (M132a)", false},

	// --- apps: each app's own chords, live while that app is focused
	// (ADR 0009 KEY_DOWN). GOSH's are the shlib line editor's
	// (user/go/shlib/edit.go); the editors' are their save/find/goto bars.
	{Chord{ModCtrl, UsageC}, "GOSH.ELF", AppScope("GOSH.ELF"), "",
		"abandon the input line", "#1450 (M68b)", false},
	{Chord{ModCtrl, UsageD}, "GOSH.ELF", AppScope("GOSH.ELF"), "",
		"end of input on an empty line", "#1450 (M68b)", false},
	{Chord{ModCtrl, UsageA}, "GOSH.ELF", AppScope("GOSH.ELF"), "",
		"move the caret to the line start", "#1450 (M68b)", false},
	{Chord{ModCtrl, UsageE}, "GOSH.ELF", AppScope("GOSH.ELF"), "",
		"move the caret to the line end", "#1450 (M68b)", false},
	{Chord{ModCtrl, UsageK}, "GOSH.ELF", AppScope("GOSH.ELF"), "",
		"kill the line after the caret", "#1450 (M68b)", false},
	{Chord{ModCtrl, UsageU}, "GOSH.ELF", AppScope("GOSH.ELF"), "",
		"kill the line before the caret", "#1450 (M68b)", false},
	{Chord{ModCtrl, UsageW}, "GOSH.ELF", AppScope("GOSH.ELF"), "",
		"kill the word before the caret — the chord the seat must never bind " +
			"(hid.go: it collides with the editor)", "#1450 (M68b)", false},
	{Chord{ModCtrl, UsageY}, "GOSH.ELF", AppScope("GOSH.ELF"), "",
		"yank the last kill back onto the line", "#1450 (M68b)", false},
	{Chord{ModCtrl, UsageT}, "GOSH.ELF", AppScope("GOSH.ELF"), "",
		"transpose the characters around the caret", "#1450 (M68b)", false},
	{Chord{ModCtrl, UsageL}, "GOSH.ELF", AppScope("GOSH.ELF"), "",
		"clear the screen and repaint", "#1450 (M68b)", false},
	{Chord{ModCtrl, UsageR}, "GOSH.ELF", AppScope("GOSH.ELF"), "",
		"reverse-i-search through command history", "#1450 (M68b)", false},
	{Chord{ModCtrl, UsageS}, "GOEDIT.ELF", AppScope("GOEDIT.ELF"), "",
		"publish the buffer (save)", "#1563-era (M58)", false},
	// M121e (#2568): the undo chord's app answers — the focused tab's own
	// binding is what the seat row routes to. GOEDIT undoes its newest
	// buffer op, GOFILES restores the newest trashed entry.
	{Chord{ModCtrl, UsageZ}, "GOEDIT.ELF", AppScope("GOEDIT.ELF"), "",
		"undo the newest buffer op", "#2568 (M121e)", false},
	{Chord{ModCtrl, UsageZ}, "GOFILES.ELF", AppScope("GOFILES.ELF"), "",
		"restore the newest trashed entry", "#2568 (M121e)", false},
	{Chord{ModCtrl, UsageF}, "GOEDIT.ELF", AppScope("GOEDIT.ELF"), "",
		"open the find bar", "#1485-era (M20 U3)", false},
	{Chord{ModCtrl, UsageG}, "GOEDIT.ELF", AppScope("GOEDIT.ELF"), "",
		"open the goto-line bar", "#1485-era (M20 U3)", false},
	{Chord{ModCtrl, UsageS}, "NOTE.ELF", AppScope("NOTE.ELF"), "",
		"save the note", "#1485 (M66c)", false},
	// M82c rebase note: this chord was ctrl+shift+s when #1770 was written;
	// M81g (#1767) landed the seat's snapshot arm on ctrl+shift-s first, so
	// the panel's view re-binds to ctrl+shift+h (free everywhere — verified
	// against this table, the kernel chrome and the app rows).
	{Chord{ModCtrl | ModShift, UsageH}, "GOSET.ELF", AppScope("GOSET.ELF"), "",
		"show the shortcuts registry (the panel's shortcuts view)", "#1770 (M82c)", false},
}
