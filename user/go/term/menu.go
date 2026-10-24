package main

// The M190d (#3239) menubar for a tty-bound front-end: F10 (the kernel's
// ESC[21~ spelling) engages the appkit menubar on the alternate screen —
// the same overlay idiom the M121c hints face uses. Menu rows return the
// action the caller performs through the SAME code paths the chords take:
// the byte verbs feed the line editor (identical to the typed control
// codes), the hints row calls hintsSession, close takes the window path.

import (
	"virelai/appkit"
	"virelai/rss/keys"
	"virelai/shlib"
	"virelai/tabapp"
	"virelai/vi"
	"virelai/vsys"
)

// menuAct is the verb a fired row asks runSession to perform after the
// menu disengages — the session owns side effects so a row's Action stays
// the same "decide, don't act" discipline the file manager's model holds.
type menuAct int

const (
	actNone menuAct = iota
	actHints
	actEOF
	actInterrupt
	actPaste
	actEditLine
	actClose
)

var menuF10 = []byte("\x1b[21~")

// buildTermBar lays the menubar out: every row names the chord whose code
// path it fires. File owns the session verbs (edit-line is the shell's
// ctrl-x ctrl-e path, EOF the line editor's ctrl-d), Edit the line verbs
// (interrupt is ctrl-c, paste the terminal's ctrl-shift-v), View the '?'
// overlay itself.
func buildTermBar(act *menuAct) appkit.MenuBar {
	var bar appkit.MenuBar
	bar.Menus = []appkit.Menu{
		{Title: "&File", Items: []appkit.MenuItem{
			{Label: "&Edit line in GOEDIT", Shortcut: "ctrl+x ctrl+e",
				Action: func() bool { *act = actEditLine; return true }},
			{Label: "Send E&OF", Shortcut: "ctrl+d",
				Action: func() bool { *act = actEOF; return true }},
			{Label: "&Close window", Shortcut: "exit",
				Action: func() bool { *act = actClose; return true }},
		}},
		{Title: "&Edit", Items: []appkit.MenuItem{
			{Label: "&Interrupt line", Shortcut: "ctrl+c",
				Action: func() bool { *act = actInterrupt; return true }},
			{Label: "&Paste", Shortcut: "ctrl+shift+v",
				Action: func() bool { *act = actPaste; return true }},
		}},
		{Title: "&View", Items: []appkit.MenuItem{
			{Label: "Chord &hints", Shortcut: "?",
				Action: func() bool { *act = actHints; return true }},
		}},
	}
	return bar
}

// menuSession owns the tty while the menubar stands: paints the bar and
// the open menu on the alternate screen, drives the appkit state machine
// with the decoded byte stream, and returns the row's verb when one fires.
// in0 is the read chunk's tail after the F10 sequence — the rest of the
// gesture must not be dropped. Esc/F10 disengage with actNone; a window
// close still shuts down inside the loop like the hints face.
func menuSession(ta *tabapp.TabApp, ts *termState, fd uint32, in0 []byte) menuAct {
	var act menuAct
	bar := buildTermBar(&act)
	bar.Activate(0)
	cw, chh := vi.TerminalCell()
	cols, rows := tabapp.CellGrid(ta.W, ta.H, cw, chh)

	paint := func() {
		var b []byte
		b = append(b, "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H"...)
		// Bar row: titles left-to-right; the engaged/open title inverts.
		pos := 0
		for i, t := range bar.CellTitles() {
			for pos < t.X {
				b = append(b, ' ')
				pos++
			}
			if bar.Active && i == bar.Bar {
				b = append(b, "\x1b[7m"...)
			}
			b = append(b, ' ')
			b = append(b, t.Text...)
			b = append(b, ' ')
			if bar.Active && i == bar.Bar {
				b = append(b, "\x1b[0m"...)
			}
			pos = t.X + t.W
		}
		// The open menu plates below its title, dim rows for disabled
		// verbs, the hover row inverted.
		if x, w, mrows, ok := bar.CellMenu(cols); ok {
			for i, r := range mrows {
				b = append(b, "\x1b["...)
				b = append(b, vi.Itoa64(int64(2+i))...)
				b = append(b, ';')
				b = append(b, vi.Itoa64(int64(x+1))...)
				b = append(b, 'H')
				pad := w - len(r.Text)
				if pad < 0 {
					pad = 0
				}
				switch {
				case r.Hover && !r.Disabled:
					b = append(b, "\x1b[7m"...)
				case r.Disabled:
					b = append(b, "\x1b[2m"...)
				}
				b = append(b, r.Text...)
				for j := 0; j < pad; j++ {
					b = append(b, ' ')
				}
				b = append(b, "\x1b[0m"...)
			}
		}
		// Footer on the last grid row.
		b = append(b, "\x1b["...)
		b = append(b, vi.Itoa64(int64(rows))...)
		b = append(b, ";1H"...)
		b = append(b, "f10/esc close · arrows move · enter fires"...)
		writeTTY(ts, fd, b)
	}

	paint()
	vi.ConsoleLine("goterm: menubar open")

	var in [64]byte
	n := copy(in[:], in0)
	for act == actNone {
		ta.PollStateAsk()
		if n == 0 {
			n, _ = vi.FileRead(fd, in[:])
		}
		if n > 0 {
			for n > 0 && act == actNone {
				ev, used := keys.Decode(in[:n])
				if used <= 0 {
					break
				}
				copy(in[:], in[used:n])
				n -= used
				k := appkit.KeyFromTTY(ev)
				if k.Usage == 0 && k.Rune == 0 {
					continue
				}
				bar.OnKey(k)
			}
			if act == actNone {
				paint()
			}
			continue
		}
		if ev, r, ok := vi.PollEventRaw(); ok {
			if ta.Dispatch(ev) == tabapp.ActionClosed {
				shutdown(ta, fd, 0)
			}
		} else if r < 0 {
			shutdown(ta, fd, 1)
		} else if n <= 0 {
			vi.Sleep(1)
		}
	}

	// Pop the alternate screen; the caller's repaint (or the fired verb's
	// own output) restores the session frame.
	writeTTY(ts, fd, []byte("\x1b[?1049l"))
	return act
}

// menuPerform runs the fired row's verb through the identical code path
// its chord takes: the byte verbs feed the line editor (the typed
// control-code's own path — EditLine on ^X^E, EOF on ^D, cancel on ^C),
// paste feeds the clipboard's bytes like the kernel's ctrl-shift-v push
// would, hints re-enters the '?' session, close takes the window path.
func menuPerform(act menuAct, ta *tabapp.TabApp, ts *termState, fd uint32, editor *shlib.Editor, handle func([]byte, shlib.EditEvent)) {
	switch act {
	case actHints:
		hintsSession(ta, ts, fd, editor)
	case actEditLine:
		handle(editor.Feed([]byte{0x18, 0x05}))
	case actEOF:
		handle(editor.Feed([]byte{0x04}))
	case actInterrupt:
		handle(editor.Feed([]byte{0x03}))
	case actPaste:
		var cb [2048]byte
		if n, rc := vsys.ClipboardGetInto(cb[:]); rc >= 0 && n > 0 {
			handle(editor.Feed(cb[:n]))
		} else {
			vi.ConsoleLine("goterm: menubar paste refused")
		}
	case actClose:
		shutdown(ta, fd, 0)
	}
}
