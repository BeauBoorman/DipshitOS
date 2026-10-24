// Command term is the M58c (issue #1307) Go terminal front-end: a full-
// viewport tabapp window bound to the existing /dev/tty seam (ADR 0020
// selector 2). Zig TERM.BIN / SH.BIN stay in place. The kernel paints the
// tty grid into the bound window (A4) and feeds focused-window keys into
// the terminal input queue (A5) — this binary draws no pixels and does
// not port lib/tty.zig or lib/shell.zig.
//
// M73c (issue #1627): the stub's hand-rolled prompt/echo/lineBuf is gone.
// The window now hosts a REAL gosh session: virelai/shlib's editor and
// engine own the prompt, editing, line execution and history, exactly as
// GOSH does over selector 1/2/3. Sequence, matching the card:
//
//  1. tabapp.Init (win_open + kind-8 declare_fullscreen)
//  2. sys_file_open("/dev/tty")
//  3. sys_tty_attach(2, window_id)
//  4. startup block through the tty: the startup contract banner
//     (STARTUP.SH, PROFILE.SH — silent, no marker: nobody typed them),
//     the SETTINGS-driven prompt load, the history load, `goterm: ready`,
//     and the first prompt paint
//  5. key loop: editor.Feed / EvSubmit -> marker -> Shell.RunLine
//  6. shell exit -> restart the session by default, or detach/close when
//     term_restart=exit; `exit --close` and a second Ctrl-D always close
//     the window, and WIN_CLOSE/monitor still use the close path
//
// The prompt comes from the shell's own loader (SETTINGS.TXT `prompt`,
// falling back to the gosh default), not a hand-written constant: this is
// the same shell GOSH runs, in a window.
//
// Every marker below is printed only AFTER its syscall returned, so the
// go-term VZ gate's asserts can only pass if the app actually ran.
package main

import (
	"bytes"
	"strings"

	"virelai/appkit"
	"virelai/chords"
	"virelai/shlib"
	"virelai/tabapp"
	"virelai/vi"
)

const (
	appName  = "GOTERM.ELF"
	appTitle = "Term"
	// M73d (#1628): the classic terminal rect — 640x400 at 64,48 is
	// 80 grid columns, exactly the kernel grid's default, so
	// syncWindowCols never reflows (Screen.reflow early-outs when
	// cols is unchanged). A narrower window (512) forced an 80->64
	// reflow of live history; observed 2026-09-22: the window kept
	// showing pre-clear rows after a typed line while the grid itself
	// had the fresh content — repaint gap that retired TERM.BIN
	// (always 640) never hit and every 512px tabapp client did.
	natW = 640
	natH = 400

	ttyPath = "/dev/tty"

	// The shell's own startup contract (same files, same caps as GOSH).
	defaultPrompt   = "gosh> "
	settingsPath    = "/host/SETTINGS.TXT"
	startupPath     = "/host/STARTUP.SH"
	profilePath     = "/host/PROFILE.SH"
	maxStartupBytes = 2048 // the startup contract's per-file cap
	ttyWriteMax     = 1024 // under the kernel's 2048-byte file-write stage cap

	markerOpen    = "goterm: open id="
	markerDeclare = "goterm: declare accepted"
	markerReady   = "goterm: ready"
	markerTty     = "goterm: tty"
	markerAttach  = "goterm: attached"
	markerPrompt  = "goterm: prompt"
	markerLine    = "goterm: line "
	// markerDone is printed AFTER Shell.RunLine returned, carrying the
	// engine's own status: it is go-term.spec's execution proof. In a
	// window the tty grid's bytes never reach serial (ADR 0020 selector 2
	// paints the window; only ConsoleLine lines are serial-observable), so
	// output text cannot vouch for execution -- but a status only the real
	// engine computes can: `cd /data` returns 0 only after host.Chdir
	// verified the directory, `cd /nosuchdir` returns nonzero.
	markerDone    = "goterm: done status="
	markerClose   = "goterm: close"
	markerRestart = "goterm: restart"
	// M125e (#2590): restore markers. `state restored` prints only after
	// the replay write and env application returned; `state refused` is
	// the decode's whole-blob rejection (stale/short/over-declared), so
	// a gate asserting restored can never confuse a refused blob for one.
	markerStateRestored = "goterm: state restored"
	markerStateRefused  = "goterm: state refused"
	markerOK            = "goterm OK"
	markerMonitor       = "goterm: monitor"
	markerMonErr        = "goterm: monitor failed"
	markerOpenErr       = "goterm: error open "
	markerTtyErr        = "goterm: no /dev/tty"
	markerAttErr        = "goterm: attach failed"
	// M124e (#2584): a seat primary-selection delivery landing in the line
	// editor — n= is the staged byte count it fed.
	markerSelPaste = "goterm: sel-paste "
	// M121c (#2566): the '?' overlay's receipts. `hints n=` is the registry
	// row count written to the alternate screen; each `hints row` line is
	// the serial-readable copy of one row the grid shows; `hints close`
	// follows the editor repaint that restores the prompt.
	markerHints    = "goterm: hints "
	markerHintsRow = "goterm: hints row "
	// M192f (#3251): notify-on-finish. `notify sent` follows an accepted
	// seat ack, `notify refused` an absent seat or a refused request —
	// gofiles' two-sided contract (its markers.go): a gate always tells
	// earned silence apart from a toast that died on the wire.
	markerNotify   = "goterm: notify sent "
	markerNotifyNo = "goterm: notify refused "
)

func main() {
	// M125e (#2590): the session-state owner. RestoreState runs inside
	// Init — before the tty is open — so it decodes into ts and
	// runSession replays/applies once the tty exists. SaveState reads
	// the LIVE session's shell through ts.sh (rebound per restart).
	ts := &termState{}
	ta := tabapp.Init(tabapp.Config{
		Name:         appName,
		Title:        appTitle,
		X:            64,
		Y:            48,
		W:            natW,
		H:            natH,
		StateVersion: termStateVersion,
		SaveState:    ts.save,
		RestoreState: ts.restore,
	})
	if ta == nil {
		vi.ConsoleLine(markerOpenErr + "-1")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine("goterm: declare refused")
	}

	h, rc := vi.FileOpen(ttyPath, vi.ModeRead|vi.ModeWrite)
	if rc < 0 {
		vi.ConsoleLine(markerTtyErr)
		ta.CloseAndExit(1)
	}
	fd := uint32(h)
	vi.ConsoleLine(markerTty)

	if r := vi.TtyAttachWindow(ta.Win); r != 0 {
		vi.FileClose(fd)
		vi.ConsoleLine(markerAttErr)
		ta.CloseAndExit(2)
	}
	vi.ConsoleLine(markerAttach)
	runSession(ta, fd, ts)
}

// runSession is the startup block + editor loop over the attached tty.
// The card's order, through the tty: banner (startup contract lines run
// by the engine, output painted by the kernel — they print no marker,
// because go-wm-hid asserts `goterm: line ` is ABSENT when nobody typed),
// prompt load, history load, ready, first prompt.
func runSession(ta *tabapp.TabApp, fd uint32, ts *termState) {
	hst := &termHost{fd: fd, st: ts}
	hist := &shlib.History{}
	sink := &shlib.HistorySink{}
	sh := shlib.NewShell(hst, hist)
	policy := loadRestartPolicy()

	// M149b (#2807): arm the OSC-8 machinery — the link tracker on the
	// write path, the report filter on the read path, and xterm mouse
	// reporting through the kernel emulator (M73i): press/release edges
	// over the bound window arrive as SGR reports on this tty's input.
	ts.lt = newLinkTracker()
	ts.mi = newMouseFilter()
	writeTTY(ts, fd, []byte(mouseEnable))

	// M98h: the tab title follows the cwd — one tracker for the window's
	// whole life (a shell restart keeps the seat, and the title it last
	// sent). Sync after each startup contract and after every submitted
	// line; the tracker sends only on change.
	titles := &shlib.TitleSync{}
	sendTitle := func(s string) bool {
		return ta != nil && ta.TabAware && ta.SetTabTitle(s)
	}

	// M125e (#2590): a restored blob replays its captured stream tail
	// read-only — the same emulator re-derives the grid and its scroll
	// ring — before the first session's startup contract runs.
	if ts.restored {
		ts.applyReplay(fd)
	}

	// A terminal owns the window; a shell is one guest in that window. Keep
	// the same fd, host, and history across restarts so the new shell has
	// the same terminal contract and recall, but none of the old shell's
	// jobs or environment.
	for session := 0; ; session++ {
		if session > 0 {
			sh = shlib.NewShell(hst, hist)
		}
		ts.sh = sh
		if ts.restored && session == 0 {
			vi.ConsoleLine(ts.restoredMarker(ts.applyEnv(sh, hst)))
		}
		// A `<<` line pulls the file's own following lines as its heredoc
		// body (M138a) — the same collection runSource does for `source`.
		lines := startupLines()
		for i := 0; i < len(lines); i++ {
			ln := lines[i]
			if strings.TrimSpace(ln) == "" {
				continue
			}
			var bodies [][]byte
			if r, err := shlib.NewHeredocReader(ln); err == nil && r.Waiting() {
				for r.Waiting() && i+1 < len(lines) {
					i++
					r.Feed(lines[i])
				}
				bodies = r.Bodies()
			}
			_, act := sh.RunLineBodies(ln, bodies)
			if act != shlib.ActionContinue {
				leave(ta, fd, sh, act)
			}
		}
		titles.Sync(shlib.TitleFor("Term", sh.Pwd()), sendTitle)

		editor := shlib.NewEditor(loadPrompt(), hist)
		editor.Complete = shlib.NewCompleter(sh, hst)
		// M80n (#1730): the prompt escapes ask the shell where it is, at paint
		// time. The provider is built once and read once per line, so `\w`
		// follows a `cd` without SETTINGS.TXT or the directory being walked on
		// every keystroke.
		editor.SetPromptFacts(shlib.PromptFactsFor(sh, hst.Principal, shlib.PromptHost(settingsBody())))

		// M69f1 (#1537): seed recall from the share AFTER the startup banner
		// and BEFORE the first prompt, so the startup lines never enter recall.
		// The ring and sink survive a restart; only the interpreter is fresh.
		if session == 0 {
			shlib.LoadHistory(hst, hist, sink)
		}

		vi.ConsoleLine(markerReady)
		writeTTY(ts, fd, editor.Repaint())
		vi.ConsoleLine(markerPrompt)
		if session > 0 {
			// This marker is deliberately after the prompt write returned.
			vi.ConsoleLine(markerRestart)
		}

		restart := false
		eofPending := false
		// handle applies one editor outcome. Feed returns at most one event per
		// call and holds the remainder of its chunk, so the loop below keeps
		// feeding until the editor has nothing left: the kernel's input queue
		// can deliver several whole lines in a single read.
		var handle func([]byte, shlib.EditEvent)
		// M138a heredoc collection: a submitted line declaring `<<WORD`
		// parks here while each subsequent submitted line joins the body,
		// with a `> ` continuation prompt, until the delimiter line.
		var hdR *shlib.HeredocReader
		var hdLine string
		submit := func(line string) {
			eofPending = false
			var bodies [][]byte
			if hdR != nil {
				hdR.Feed(line)
				if hdR.Waiting() {
					writeTTY(ts, fd, []byte("> "))
					return
				}
				line, bodies = hdLine, hdR.Bodies()
				hdR = nil
			} else {
				vi.ConsoleLine(markerLine + line)
				shlib.SaveHistory(hst, hist, line, sink)
				if closeRequested(line) {
					vi.ConsoleLine(markerDone + "0")
					shutdown(ta, fd, 0)
					return
				}
				// M149b: `term-profile` is a front-end line command like
				// `exit --close` — answered here, never handed to the engine.
				if pname, plist, ok := profileCmd(line); ok {
					handleProfileCmd(ts, ta, fd, editor, pname, plist)
					vi.ConsoleLine(markerDone + "0")
					return
				}
				if r, err := shlib.NewHeredocReader(line); err == nil && r.Waiting() {
					hdR, hdLine = r, line
					writeTTY(ts, fd, []byte("> "))
					return
				}
			}
			startNs := vi.Nanos()
			st, act := sh.RunLineBodies(line, bodies)
			// Only AFTER the engine answered: the gate sequences on this,
			// so it can never claim an execution that did not happen.
			vi.ConsoleLine(markerDone + vi.Itoa64(int64(st)))
			notifyOnFinish(ta, line, st, startNs)
			if act == shlib.ActionExit && policy == restartStay {
				writeTTY(ts, fd, []byte(restartMessage(st)))
				restart = true
			} else if act != shlib.ActionContinue {
				leave(ta, fd, sh, act)
			}
			if !restart {
				// At the cursor, no CR — a CR repaint would overwrite the
				// truecolour row's cells (the M73h assert scans x64..79 of
				// grid row 2), where the shell loop's bare prompt lands at
				// x>=80 as the original gate observed. The template is
				// re-read (a mid-session goset change still lands) and
				// re-expanded against the facts NOW — the command may have
				// been `cd` — and the editor's own bytes are written, so
				// this prompt is the one the next in-line repaint uses.
				editor.SetPrompt(loadPrompt())
				writeTTY(ts, fd, editor.PromptBytes())
				// M98h: the tab title follows the cwd.
				titles.Sync(shlib.TitleFor("Term", sh.Pwd()), sendTitle)
				// M98f: bytes typed while a foreground child ran sit
				// in the interrupter's stash — feed them before the
				// next FileRead.
				if p := hst.TTYInterrupter(); p != nil {
					if ahead := p.TypeAhead(); len(ahead) > 0 {
						handle(editor.Feed(ahead))
					}
				}
			}
		}
		handle = func(out []byte, ev shlib.EditEvent) {
			if len(out) > 0 {
				writeTTY(ts, fd, out)
			}
			switch ev.Kind {
			case shlib.EvSubmit:
				submit(ev.Line)
			case shlib.EvEdit:
				eofPending = false
				// M98h: Ctrl-X Ctrl-E hands the line to GOEDIT. Each returned
				// line goes through the same submit path; a failed round trip
				// says so and puts the original line back.
				lines, err := sh.EditLine(ev.Line)
				if err != nil {
					writeTTY(ts, fd, []byte("gosh: edit: "+err.Error()+"; line not run\r\n"))
					editor.SetValue(ev.Line)
					writeTTY(ts, fd, editor.Repaint())
					break
				}
				for _, ln := range lines {
					submit(ln)
					if restart {
						return
					}
				}
			case shlib.EvEOF:
				if eofPending {
					shutdown(ta, fd, 0)
					return
				}
				eofPending = true
				writeTTY(ts, fd, []byte("\r\ngoterm: press Ctrl-D again to close\r\n"))
				writeTTY(ts, fd, editor.Repaint())
			case shlib.EvCancel:
				eofPending = false
				// The editor already painted ^C and the fresh prompt; a
				// pending heredoc collection is abandoned with the line.
				hdR = nil
			}
		}
		// M124e (#2584): the seat's primary-selection delivery pastes into
		// the line editor exactly like typed bytes — Feed through the same
		// handler so a selection containing newlines submits the same way
		// real input would. Bound inside the session so a restart rewires
		// it to the fresh editor; the seat refuses the delivery when this
		// app's manifest row lacks selection=primary.
		ta.SelPaste = func(text []byte) {
			vi.ConsoleLine(markerSelPaste + "n=" + vi.Itoa64(int64(len(text))))
			if len(text) > 0 {
				handle(editor.Feed(text))
			}
		}

		// feedBytes runs one tty chunk's normal path: SGR mouse reports are
		// not editor input — strip them; a press+release on one link cell
		// opens it (M149b). The rest feeds the line editor.
		feedBytes := func(b []byte) {
			clean, reps := ts.mi.extract(b)
			for _, r := range reps {
				if cx, cy, ok := ts.mi.clickCell(r); ok {
					if uri, found := ts.lt.linkAt(cx, cy, rowsVisible(ta.H)); found {
						openLink(ts, ta, fd, editor, hst, uri)
					} else {
						vi.ConsoleLine("goterm: link miss cell=" +
							vi.Itoa64(int64(cx)) + "," +
							vi.Itoa64(int64(cy)))
					}
				}
			}
			if len(clean) > 0 {
				handle(editor.Feed(clean))
			}
		}

		var readBuf [64]byte
		for !restart {
			// M125e (#2590): the seat's save notice is a mailbox message,
			// not an input event — answer it each pass so a snapshot or
			// tab-close ask is serviced before the window dies.
			ta.PollStateAsk()
			// M124e (#2584): a seat primary-selection delivery is mailbox
			// traffic too — the notice lands here, the staged payload is
			// consumed by SelTake, and the bytes ride editor.Feed.
			ta.PollSelPaste()
			n, _ := vi.FileRead(fd, readBuf[:])
			if n > 0 {
				// M190d (#3239): F10 (the kernel's ESC[21~) engages the
				// menubar. Bytes ahead of the chord feed normally; the
				// chunk's tail rides into the menu session as its first
				// input — the rest of the gesture is its navigation.
				if i := bytes.Index(readBuf[:n], menuF10); i >= 0 {
					if i > 0 {
						feedBytes(readBuf[:i])
					}
					if !restart {
						menuPerform(menuSession(ta, ts, fd, readBuf[i+len(menuF10):n]),
							ta, ts, fd, editor, handle)
					}
				} else if n == 1 && readBuf[0] == '?' {
					// M121c (#2566): a bare '?' keystroke at the prompt opens
					// the chord-hint overlay on the tty's alternate screen. A
					// '?' arriving inside a larger chunk (a paste, a typed
					// burst) stays editor input; a '?' typed while a child
					// owns the terminal never reaches this loop at all — the
					// wait's tty read is the child's byte stream, the
					// pass-through the card names.
					hintsSession(ta, ts, fd, editor)
				} else {
					feedBytes(readBuf[:n])
				}
			}
			for editor.Pending() {
				handle(editor.Feed(nil))
			}

			sh.ReapJobs()

			ev, r, ok := vi.PollEventRaw()
			if !ok {
				if r < 0 {
					shutdown(ta, fd, 1)
				}
				if n <= 0 {
					vi.Sleep(1)
				}
				continue
			}
			switch ta.Dispatch(ev) {
			case tabapp.ActionClosed:
				shutdown(ta, fd, 0)
			}
		}
	}
}

// leave ends the session for the line that asked to leave. The monitor
// handover is reported only AFTER the detach syscall returned, same
// contract as GOSH's `gosh: monitor` (live-sh-monitor sequences on GOSH's;
// no gate sequences on these, but the fact must still not be claimed
// before it happened).
func leave(ta *tabapp.TabApp, fd uint32, sh *shlib.Shell, act shlib.Action) {
	if act == shlib.ActionMonitor {
		if r := vi.TtyAttach(vi.TtyDetach); r == 0 {
			vi.ConsoleLine(markerMonitor)
		} else {
			vi.ConsoleLine(markerMonErr)
		}
	}
	shutdown(ta, fd, sh.Status())
}

// hintsSession is the M121c (#2566) '?' overlay for a tty-bound window:
// the kernel paints this terminal's grid, so the registry's rows go into
// the alternate screen — title, the app + global + kernel-chrome sections,
// footer — until a lone Esc (or a second '?') pops it and the editor
// repaints the prompt. The overlay is one appkit.ChordHints: the same
// model the canvas apps draw, rendered through Lines like GOFILES's ANSI
// face. Markers print after the bytes that produce them.
func hintsSession(ta *tabapp.TabApp, ts *termState, fd uint32, editor *shlib.Editor) {
	h := appkit.NewChordHints(appName, chords.ScopeKernelTerminal)
	cw, chh := vi.TerminalCell()
	cols, rows := tabapp.CellGrid(ta.W, ta.H, cw, chh)

	paint := func() {
		lines := h.Lines(cols)
		var b []byte
		b = append(b, "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H"...)
		for i := 0; i < rows; i++ {
			var line string
			switch {
			case i == 0:
				line = lines[0]
			case i == rows-1:
				line = lines[len(lines)-1]
			default:
				// h.Scroll indexes h.Rows; lines carries a 2-line
				// preamble (title + blank), so the row window starts
				// two lines in and ends before blank + footer.
				idx := h.Scroll + i - 1 + 2
				if idx < len(lines)-2 {
					line = lines[idx]
				}
			}
			b = append(b, line...)
			if i < rows-1 {
				b = append(b, '\r', '\n')
			}
		}
		writeTTY(ts, fd, b)
	}

	paint()
	vi.ConsoleLine(markerHints + "n=" + vi.Itoa64(int64(h.ChordRows())))
	for _, l := range h.RowLines() {
		vi.ConsoleLine(markerHintsRow + l)
	}

	var in [64]byte
	for {
		ta.PollStateAsk()
		n, _ := vi.FileRead(fd, in[:])
		if n > 0 {
			for i := 0; i < n; i++ {
				c := in[i]
				switch {
				case c == 0x1b && i+2 < n && in[i+1] == '[':
					// A CSI sequence: scroll on arrows/Home/End/PgUp/PgDn.
					act, used := hintsCSI(in[i:])
					if used == 0 {
						used = 3 // an unrecognized CSI is still skipped whole
					}
					i += used - 1 // the loop's i++ covers the last byte
					switch act {
					case hintsUp:
						h.Move(-1)
					case hintsDown:
						h.Move(1)
					case hintsTop:
						h.Scroll = 0
					case hintsBottom:
						h.Scroll = len(h.Rows) - 1
					case hintsPageUp:
						h.Move(-(rows - 2))
					case hintsPageDown:
						h.Move(rows - 2)
					}
				case c == 0x1b || c == '?':
					goto hintsDone
				}
			}
			paint()
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
hintsDone:
	// Pop the alternate screen; the editor's repaint restores the prompt
	// and the in-flight line exactly as the overlay found them.
	writeTTY(ts, fd, []byte("\x1b[?1049l"))
	writeTTY(ts, fd, editor.Repaint())
	vi.ConsoleLine(markerHints + "close")
}

// The hints overlay's scroll actions, decoded by hintsCSI.
const (
	hintsNone = iota
	hintsUp
	hintsDown
	hintsTop
	hintsBottom
	hintsPageUp
	hintsPageDown
)

// hintsCSI maps the CSI sequence starting at in[0] (ESC [ …) onto a
// scroll action and returns the sequence's byte length — 0 when the
// bytes are not a sequence the overlay knows. The sequence's final byte
// ENDS it: ESC [ 5 ~ puts the parameter '5' at in[2] and '~' at in[3]
// (REVIEW-LOW L8 — the first version matched the parameter byte as the
// final, which made PgUp/PgDn dead keys).
func hintsCSI(in []byte) (act int, used int) {
	if len(in) < 3 || in[0] != 0x1b || in[1] != '[' {
		return hintsNone, 0
	}
	switch in[2] {
	case 'A':
		return hintsUp, 3
	case 'B':
		return hintsDown, 3
	case 'H':
		return hintsTop, 3
	case 'F':
		return hintsBottom, 3
	case '5', '6':
		if len(in) >= 4 && in[3] == '~' {
			if in[2] == '5' {
				return hintsPageUp, 4
			}
			return hintsPageDown, 4
		}
	}
	return hintsNone, 0
}

func shutdown(ta *tabapp.TabApp, fd uint32, status int) {
	// Detach again when leave already did it for the monitor handover: the
	// kernel's selector 0 is idempotent (it just clears the front-end), so
	// the second call only keeps this the single exit path.
	_ = vi.TtyAttach(vi.TtyDetach)
	vi.FileClose(fd)
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	ta.CloseAndExit(status)
}

func writeTTY(ts *termState, fd uint32, b []byte) {
	// M149b (#2807): the OSC-8 filter injects the underline rendition
	// around link spans and mirrors the kernel's link cells; the capture
	// ring records what was actually written (the transformed stream).
	if ts != nil && ts.lt != nil {
		b = ts.lt.filter(b)
	}
	for len(b) > 0 {
		n := len(b)
		if n > ttyWriteMax {
			n = ttyWriteMax
		}
		if _, r := vi.FileWrite(fd, b[:n]); r < 0 {
			return
		}
		// M125e (#2590): the scrollback ring captures what was actually
		// written — a refused chunk leaves no phantom bytes behind.
		if ts != nil {
			ts.capture(b[:n])
		}
		b = b[n:]
	}
}

// restartStay is the default: a shell exit leaves the terminal window alive.
// restartExit is the explicit compatibility mode for close-on-exit.
const (
	restartStay = "stay"
	restartExit = "exit"
)

// loadRestartPolicy reads term_restart from SETTINGS.TXT. A missing or
// unknown value uses the documented default; only the exact value "exit"
// selects close-on-exit.
func loadRestartPolicy() string {
	b, r := vi.ReadFileAll(settingsPath, maxStartupBytes)
	if r < 0 {
		return restartStay
	}
	return restartPolicyFromSettings(string(b))
}

func restartPolicyFromSettings(body string) string {
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		eq := strings.IndexByte(line, '=')
		if eq < 0 || strings.TrimSpace(line[:eq]) != "term_restart" {
			continue
		}
		if strings.TrimSpace(line[eq+1:]) == restartExit {
			return restartExit
		}
		return restartStay
	}
	return restartStay
}

func restartMessage(status int) string {
	return "\r\nshell exited status=" + vi.Itoa64(int64(status)) + "\r\n"
}

func closeRequested(line string) bool {
	return strings.TrimSpace(line) == "exit --close"
}

// notifyOnFinish is the M192f tap on the shoulder: called after every
// engine answer; only a foreground command that ran past the
// term_notify_seconds threshold while this tab was unfocused posts. Each
// GOTERM window is its own tab and process, so the tracked start is
// per-tab by construction. The toast text is the marker's text verbatim —
// already built inside the seat's 24-byte title budget.
func notifyOnFinish(ta *tabapp.TabApp, line string, status int, startNs int64) {
	threshold := notifyThresholdNs(settingsBody())
	if threshold < 0 {
		return
	}
	elapsed := vi.Nanos() - startNs
	if elapsed <= threshold || windowFocused(ta.Win) {
		return
	}
	text := notifyText(notifyName(line), status, elapsed)
	if ta.Notify(text) {
		vi.ConsoleLine(markerNotify + text)
	} else {
		vi.ConsoleLine(markerNotifyNo + text)
	}
}

// windowFocused reads the kernel's window state for this tab (slot 19 —
// owner-only, and this process owns ta.Win). out[5] is the focused flag.
// A refused query reports true: the toast's rule is "unfocused only",
// and an unreadable state cannot prove unfocused.
func windowFocused(win int) bool {
	st, r := vi.WinQuery(win)
	if r < 0 {
		return true
	}
	return st[5] != 0
}

// settingsBody is the raw SETTINGS.TXT, or "" when it cannot be read. The
// prompt template and the hostname both come from here.
func settingsBody() string {
	b, r := vi.ReadFileAll(settingsPath, maxStartupBytes)
	if r < 0 {
		return ""
	}
	return string(b)
}

// loadPrompt adopts the SETTINGS.TXT `prompt` key (SH.BIN's SH8 behavior,
// the same loader GOSH uses — the prompt is the shell's, not this
// front-end's). The value is the TEMPLATE: escapes are expanded at paint
// (M80n #1730), so `prompt=\w` needs no rewriting when the directory moves.
func loadPrompt() string {
	return shlib.PromptFromSettings(settingsBody(), defaultPrompt)
}

// startupLines reads the startup contract files (CRLF-aware, bounded,
// silent when missing) and returns their lines in order.
func startupLines() []string {
	var out []string
	for _, path := range []string{startupPath, profilePath} {
		b, r := vi.ReadFileAll(path, maxStartupBytes)
		if r < 0 || len(b) == 0 {
			continue
		}
		out = append(out, startupLinesFrom(string(b))...)
	}
	return out
}

// startupLinesFrom is startupLines' pure parsing half (host-testable):
// CRLF and CR are folded to LF, order kept. Blank lines ride along — a
// heredoc body may legitimately hold one (M138a) — and the caller skips
// the ones that are not collected as bodies.
func startupLinesFrom(body string) []string {
	var out []string
	body = strings.ReplaceAll(body, "\r\n", "\n")
	for _, line := range strings.Split(body, "\n") {
		out = append(out, strings.TrimRight(line, "\r"))
	}
	return out
}

// Tab completion is shlib.NewCompleter (M98g) — the front-ends used to
// carry identical copies of a flat word lister; the shared completer is
// context-aware and this file adds no logic.

// termHost is the Host seam for this windowed front-end: the same vi
// syscall surface as GOSH's goshHost, always bound to the attached tty
// (term has no headless and no serial presentation). It lives here, not
// in shlib, because shlib stays host-agnostic; a later card can share one
// seam between the two front-ends when the Touches allow touching both.
type termHost struct {
	fd   uint32
	st   *termState // M125e (#2590): the scrollback tee + alt tracker
	poll *shlib.TTYPoll
}

func (g *termHost) Marker(line string) { vi.ConsoleLine(line) }

// Out writes command output to the attached tty; the kernel paints it
// into the window (ADR 0020 A4).
func (g *termHost) Out(b []byte) { writeTTY(g.st, g.fd, b) }

// candidateNames expands name the way SH.BIN's resolver did: bare, .ELF
// and .BIN suffixes, uppercase variants, in that order.
func candidateNames(name string) []string {
	up := strings.ToUpper(name)
	var out []string
	add := func(n string) {
		for _, e := range out {
			if e == n {
				return
			}
		}
		out = append(out, n)
	}
	for _, base := range []string{name, up} {
		add(base)
		add(base + ".ELF")
		add(base + ".BIN")
	}
	return out
}

func (g *termHost) RunExternal(name string, args []string) (int64, error) {
	for _, cand := range candidateNames(name) {
		if pid, err := vi.Exec(cand, args...); err == nil {
			return pid, nil
		}
	}
	return 0, shlib.ErrNotFound
}

func (g *termHost) WaitExternal(pid int64) (int64, error) { return vi.Wait(pid) }

func (g *termHost) ProbeExternal(pid int64) (int64, int) {
	st, state := vi.Probe(pid)
	return st, state
}

func (g *termHost) SleepTick() { vi.Sleep(1) }

// TTYInterrupter is the M98f Ctrl-C seam — the same engine hook GOSH
// exposes, over the attached tty fd. The instance persists on the host:
// its type-ahead stash must survive between the engine's waits.
func (g *termHost) TTYInterrupter() *shlib.TTYPoll {
	if g.poll == nil {
		g.poll = &shlib.TTYPoll{Read: func(b []byte) int {
			n, _ := vi.FileRead(g.fd, b)
			return n
		}}
	}
	return g.poll
}

// Kill arms sys_kill (slot 29), carrying the kernel's errno name.
func (g *termHost) Kill(pid int64) error {
	if r := vi.Kill(uint64(pid)); r < 0 {
		if name := vi.ErrnoName(r); name != "" {
			return shlib.NewOpenError(vi.Itoa64(pid), name)
		}
		return shlib.ErrNotFound
	}
	return nil
}

func (g *termHost) PipeWrite(b []byte) error {
	_, err := vi.PipeWrite(b)
	return err
}

func (g *termHost) PipeReadAll() ([]byte, error) {
	var all []byte
	buf := make([]byte, 512)
	for len(all) < shlib.MaxPipeBytes {
		n, err := vi.PipeRead(buf)
		if err != nil {
			return all, err
		}
		if n == 0 {
			return all, nil
		}
		all = append(all, buf[:n]...)
	}
	return all, nil
}

func (g *termHost) ReadFile(path string, max int) ([]byte, error) {
	b, r := vi.ReadFileAll(path, max)
	if r < 0 {
		// Carry the kernel's own errno name: an ownership denial (EACCES)
		// and an absent file (ENOENT) are different facts, and the M50
		// trust gates assert which one the shell reported.
		if name := vi.ErrnoName(r); name != "" {
			return nil, shlib.NewOpenError(path, name)
		}
		return nil, shlib.ErrNotFound
	}
	return b, nil
}

// Principal is the caller's identity (slot 68) for `whoami`/`id`.
func (g *termHost) Principal() (uint32, uint32, bool) { return vi.Principal() }

// Chmod is the owner-only mode change (slot 69).
func (g *termHost) Chmod(path string, mode uint16) error {
	r := vi.FileMode(path, mode)
	if r < 0 {
		if name := vi.ErrnoName(r); name != "" {
			return shlib.NewOpenError(path, name)
		}
		return shlib.ErrNotFound
	}
	return nil
}

// Suspend is the guest-initiated power request (M115d, slot 93): the
// kernel runs the whole authenticated ctl session under its uid_system
// `vsock-ctl` credential — no key bytes cross the seam. The ok return
// may land on the far side of a host save/restore.
func (g *termHost) Suspend() (bool, string) {
	var code [40]byte
	r := vi.VsockCtl("suspend", "", code[:])
	if r == 0 {
		return true, ""
	}
	if r > 0 {
		if r > int64(len(code)) {
			r = int64(len(code))
		}
		return false, string(code[:r])
	}
	return false, vi.ErrnoName(r)
}

// SecretNames reads the caller's store entry NAMES (slot 70). The values are
// deliberately not carried through this seam.
func (g *termHost) SecretNames() ([]string, bool) {
	var recs [vi.SecretEntriesMax]vi.SecretRecord
	n, r := vi.SecretList(recs[:])
	if r < 0 {
		return nil, false
	}
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, recs[i].KeyString())
	}
	return out, true
}

// WriteFile is GOTERM's twin of goshHost.WriteFile (M81e2 #1787) — same
// shlib seam, same two callers (the history ring save and `> file`
// redirection), and it was a SECOND in-place writer the M81e audit missed.
// It now defers to the same vi.WriteFilePublish policy, and carries the same
// reasoning: replace is app state and publishes crash-safe; an append is not
// a rewrite and stays an append. See user/go/sh/main.go for the full
// argument, and user/go/vi/publish_guard_test.go for the rule that keeps
// this hook from decaying back into an in-place writer.
func (g *termHost) WriteFile(path string, b []byte, appendMode bool) error {
	if r := vi.WriteFilePublish(path, b, appendMode); r < 0 {
		if r == -vi.ErrEACCES || r == -vi.ErrENOENT || r == -vi.ErrENAMETOOLONG {
			return shlib.ErrNotFound
		}
		return shlib.ErrWriteFailed
	}
	return nil
}

// DeleteFile removes path (slot delete) — an absent file is not an error,
// matching WriteFilePublish's absent-fails-closed readers.
func (g *termHost) DeleteFile(path string) error {
	if r := vi.FileDelete(path); r < 0 && r != -vi.ErrENOENT {
		return shlib.ErrWriteFailed
	}
	return nil
}

func (g *termHost) Chdir(path string) error {
	var entries [1]vi.DirEntry
	if _, r := vi.DirList(path, entries[:]); r < 0 {
		// Carry the kernel's errno for the same reason ReadFile does: a
		// missing directory, a path that is a file, and an ownership denial
		// on the share's list gate are three different facts, and folding
		// them into one "not a directory" message hides two of them.
		if name := vi.ErrnoName(r); name != "" {
			return shlib.NewOpenError(path, name)
		}
		return shlib.ErrNotFound
	}
	return nil
}

// ListPath is the M98a glob seam: a path-aware listing of a canonical
// directory. The shared vi wrapper owns the /host conversion, the
// slot-79 paging and the USB fallback — the front-end adds no logic.
func (g *termHost) ListPath(dir string) ([]vi.DirItem, error) {
	return vi.ListDirAt(dir)
}

func (g *termHost) ReadTTYLine() (string, bool) {
	var acc []byte
	buf := make([]byte, 32)
	for len(acc) < 256 {
		n, _ := vi.FileRead(g.fd, buf)
		if n == 0 {
			vi.Sleep(1)
			continue
		}
		for i := 0; i < n; i++ {
			if buf[i] == '\r' || buf[i] == '\n' {
				return string(acc), true
			}
			acc = append(acc, buf[i])
		}
	}
	return string(acc), true
}

// SleepSeconds parks n sys_sleep ticks — the kernel timer is 1 Hz
// (kernel/src/timer.zig period_ns), so one tick IS one second.
func (g *termHost) SleepSeconds(n int) {
	vi.Sleep(uint64(n))
}
