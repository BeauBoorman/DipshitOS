// Command sh is GOSH — the M68a (issue #1449) Go shell: the M49 daily-use
// bar (exec, line editing, history, jobs/fg, and the pipes / redirection /
// env / variables scripting subset) running as a full-viewport tabapp on
// the /dev/tty seam, the same presentation TERM.BIN used for the Zig shell
// core ("a different front-end owner over the same core").
//
// Shape, matching GOTERM's attach path:
//  1. tabapp.Init (win_open + kind-8 declare_fullscreen)
//  2. sys_file_open("/dev/tty")
//  3. sys_tty_attach(2, window_id)
//  4. the startup contract: /host/STARTUP.SH then /host/PROFILE.SH,
//     silent when missing, then the first prompt
//  5. typed bytes go through the editor; submitted lines run through the
//     shell engine; children exec on the M64b-fixed slot-28 seam
//  6. WIN_CLOSE / `monitor` / Ctrl-D -> detach, close
//
// `GOSH.ELF serial` takes the SERIAL front-end instead (step 3 becomes
// `sys_tty_attach(1)`, no window and no tabapp — the console the kernel
// monitor hands over). `GOSH.ELF net [port] [open]` takes the NET front-end
// (selector 3) with the delegated HMAC challenge-response handshake, the
// last SH.BIN surface M68b (#1450) ports. The engine, editor and startup
// contract are identical; only the front-end owner changes.
//
// Every marker is printed in a single console write (SMP-heartbeat safe)
// and only AFTER its syscall returned, so the class-B gate's asserts can
// only pass if the shell actually ran. `GOSH.ELF -c LINE` runs one line
// headless (no window, no tty, no startup) and exits with its status —
// the composable child form the gate and scripts use.
//
// This file is the FRONT-END only (M73b, issue #1626): argv dispatch, the
// three tty owners, the startup contract and the vi host seam. The engine,
// editor, parser, builtins, toolbox, history persistence and net-auth core
// live in virelai/shlib, importable by any front-end.
package main

import (
	"strings"

	"virelai/shlib"
	"virelai/tabapp"
	"virelai/vi"
)

const (
	appName  = "GOSH.ELF"
	appTitle = "Sh"
	natW     = 512
	natH     = 384

	ttyPath         = "/dev/tty"
	defaultPrompt   = "gosh> "
	settingsPath    = "/host/SETTINGS.TXT"
	startupPath     = "/host/STARTUP.SH"
	profilePath     = "/host/PROFILE.SH"
	maxStartupBytes = 2048 // the startup contract's per-file cap
	ttyWriteMax     = 1024 // under the kernel's 2048-byte file-write stage cap

	markerReady    = "gosh: ready"
	markerOpen     = "gosh: open id="
	markerDeclare  = "gosh: declare accepted"
	markerDogfood  = "dogfood: gosh" // M69a (#1528): go-dogfood.spec's marker
	markerTty      = "gosh: tty"
	markerAttach   = "gosh: attached"
	markerPrompt   = "gosh: prompt"
	markerLine     = "gosh: line "
	markerMonitor  = "gosh: monitor"
	markerMonErr   = "gosh: monitor failed"
	markerClose    = "gosh: close"
	markerOK       = "gosh OK"
	markerOpenErr  = "gosh: error open "
	markerTtyErr   = "gosh: no /dev/tty"
	markerAttachEr = "gosh: attach failed"
	markerRemote   = "gosh: remote on "
	markerAuthOpen = "gosh: remote auth=open"
	markerAuthHMAC = "gosh: remote auth=hmac-sha256"
	markerAuthEd   = "gosh: remote auth=ed25519"
	markerNetRefus = "gosh: net refused: no credential (pass 'open' for the insecure mode)"
	markerNetFail  = "gosh: remote attach failed"
	markerNetBad   = "gosh: net refused: "
)

func main() {
	defer func() {
		if recovered := recover(); recovered != nil {
			outcome := "panic"
			switch value := recovered.(type) {
			case string:
				outcome += ": " + value
			case error:
				outcome += ": " + value.Error()
			}
			_ = vi.Log(appName, outcome)
			_ = vi.WriteCrashReceipt(appName, outcome)
			vi.ConsoleLine("gosh: crash receipt written")
			vi.Exit(2)
		}
	}()
	_ = vi.Log(appName, "started")
	args := vi.Args()
	if line, headless := headlessLine(args); headless {
		runHeadless(line)
		return
	}
	if na, ok, err := shlib.ParseNetArgs(args); ok {
		runNet(na)
		return
	} else if err != "" {
		vi.ConsoleLine(markerNetBad + err)
		vi.Exit(2)
	}
	if hasArg(args, "serial") {
		runSerial()
		return
	}
	runTab()
}

// hasArg reports whether the argv carries word. The exec seam may supply
// argv[0] at either position (see headlessLine), so both are searched.
func hasArg(args []string, word string) bool {
	for _, a := range args {
		if a == word {
			return true
		}
	}
	return false
}

// headlessLine recognizes the `-c LINE` child form. argv[0] is the program
// name when the spawner supplied one, so check both positions.
func headlessLine(args []string) (string, bool) {
	if len(args) >= 2 && args[0] == "-c" {
		return args[1], true
	}
	if len(args) >= 3 && args[1] == "-c" {
		return args[2], true
	}
	return "", false
}

// runHeadless executes one line with console output and exits with its
// status. No window, no tty attach, no startup scripts.
func runHeadless(line string) {
	h := newGoshHost(0, false)
	sh := shlib.NewShell(h, &shlib.History{})
	st, _ := sh.RunLine(line)
	h.flushOut()
	if st != 0 {
		_ = vi.WriteCrashReceipt(appName, "exit="+vi.Itoa64(int64(st)))
	}
	vi.Exit(st)
}

// runTab is the window presentation: tabapp + /dev/tty + editor loop.
func runTab() {
	vi.ConsoleLine(markerReady)
	ta := tabapp.Init(tabapp.Config{
		Name:  appName,
		Title: appTitle,
		X:     32,
		Y:     32,
		W:     natW,
		H:     natH,
	})
	if ta == nil {
		vi.ConsoleLine(markerOpenErr + "-1")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
		// M69a (#1528): the dogfood beat's ordered marker, printed only on the
		// accepted-declare path, so it means "a WM seat hosts this shell" and
		// never fires on the shim/refused path.
		vi.ConsoleLine(markerDogfood)
	} else {
		vi.ConsoleLine("gosh: declare refused")
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
		vi.ConsoleLine(markerAttachEr)
		ta.CloseAndExit(2)
	}
	vi.ConsoleLine(markerAttach)
	runSession(fd, ta, nil)
}

// runSerial attaches the SERIAL front-end (ADR 0020 selector 1) instead of a
// window: the same session over the console the kernel monitor hands over,
// which is the presentation SH.BIN had and what the M68b shell gates assert
// against. No tabapp, no declare, no /host share for a window.
func runSerial() {
	vi.ConsoleLine(markerReady)

	h, rc := vi.FileOpen(ttyPath, vi.ModeRead|vi.ModeWrite)
	if rc < 0 {
		vi.ConsoleLine(markerTtyErr)
		vi.Exit(1)
	}
	fd := uint32(h)
	vi.ConsoleLine(markerTty)

	if r := vi.TtyAttach(vi.TtySerial); r != 0 {
		vi.FileClose(fd)
		vi.ConsoleLine(markerAttachEr)
		vi.Exit(2)
	}
	vi.ConsoleLine(markerAttach)
	runSession(fd, nil, nil)
}

// runNet attaches the NET front-end (ADR 0020 selector 3): LISTEN on the
// asked port, with the delegated challenge-response handshake unless `open`
// was explicit. The engine, editor and startup contract are the serial
// path's; only the front-end owner changes. Fail closed: no credential and
// no `open` refuses to listen.
func runNet(na shlib.NetArgs) {
	vi.ConsoleLine(markerReady)

	h, rc := vi.FileOpen(ttyPath, vi.ModeRead|vi.ModeWrite)
	if rc < 0 {
		vi.ConsoleLine(markerTtyErr)
		vi.Exit(1)
	}
	fd := uint32(h)
	vi.ConsoleLine(markerTty)

	scheme := vi.NetSchemeOpen
	var auth *shlib.NetAuth
	if !na.Open {
		sch, ok := shlib.SelectScheme(shlib.StoreGet)
		if !ok {
			vi.FileClose(fd)
			vi.ConsoleLine(markerNetRefus)
			vi.Exit(2)
		}
		scheme = sch
	}
	if r := vi.TtyAttachNet(na.Port, scheme, 0); r != 0 {
		vi.FileClose(fd)
		vi.ConsoleLine(markerNetFail)
		vi.Exit(2)
	}
	if scheme != vi.NetSchemeOpen {
		auth = shlib.SysNetAuth(scheme)
	}
	vi.ConsoleLine(markerRemote + vi.Itoa64(int64(na.Port)))
	switch scheme {
	case vi.NetSchemeOpen:
		vi.ConsoleLine(markerAuthOpen)
	case vi.NetSchemeHMAC:
		vi.ConsoleLine(markerAuthHMAC)
	default:
		vi.ConsoleLine(markerAuthEd)
	}
	runSession(fd, nil, auth)
}

// runSession is the shared startup contract + editor loop. ta is nil on the
// serial and net front-ends: there is no window, so no window events are
// polled — the console's own input path (serial) or the kernel's net pump
// (selector 3) delivers the bytes FileRead returns. auth is the delegated
// handshake, live only in net mode and only when a credential is in force;
// one step per loop turn, including idle, because the challenge is not a
// tty byte.
func runSession(fd uint32, ta *tabapp.TabApp, auth *shlib.NetAuth) {
	hst := newGoshHost(fd, true)
	hist := &shlib.History{}
	sh := shlib.NewShell(hst, hist)
	editor := shlib.NewEditor(loadPrompt(), hist)
	editor.Complete = shlib.NewCompleter(sh, hst)
	// M80n (#1730): the prompt escapes ask the shell where it is, at paint
	// time. The provider is built once and read once per line, so `\w`
	// follows a `cd` without SETTINGS.TXT or the directory being walked on
	// every keystroke.
	editor.SetPromptFacts(shlib.PromptFactsFor(sh, hst.Principal, shlib.PromptHost(settingsBody())))

	// M98h: the tab title follows the cwd. Sync after the startup contract
	// (a PROFILE.SH `cd` retitles) and after every submitted line.
	titles := &shlib.TitleSync{}
	sendTitle := func(s string) bool {
		return ta != nil && ta.TabAware && ta.SetTabTitle(s)
	}

	// The startup contract (M49 SD2): STARTUP.SH, then PROFILE.SH, silent
	// when either is missing, every line through the same engine. A `<<`
	// line pulls the file's own following lines as its heredoc body
	// (M138a) — the same collection runSource does for `source`.
	for _, st := range scriptSteps(startupLines()) {
		vi.ConsoleLine(markerLine + st.line)
		_, act := sh.RunLineBodies(st.line, st.bodies)
		if act != shlib.ActionContinue {
			leave(ta, fd, sh, act)
		}
	}
	titles.Sync(shlib.TitleFor("Sh", sh.Pwd()), sendTitle)

	// M69f1 (#1537): seed recall from the share AFTER the startup contract
	// and BEFORE the first prompt, so the startup lines never enter recall
	// and the first Up arrow lands on the last line the user really typed.
	sink := &shlib.HistorySink{}
	shlib.LoadHistory(hst, hist, sink)

	_, _ = vi.FileWrite(fd, editor.Repaint())
	vi.ConsoleLine(markerPrompt)

	// handle applies one editor outcome. Feed returns at most one event per
	// call and holds the remainder of its chunk, so the loop below keeps
	// feeding until the editor has nothing left: the serial front-end can
	// deliver several whole lines in a single read, and a burst that stops
	// after its first line would leave the rest typed but never run. The
	// var declaration lets the EvSubmit branch recurse for type-ahead.
	var handle func([]byte, shlib.EditEvent)
	// M138a heredoc collection: a submitted line declaring `<<WORD` parks
	// in hd while each subsequent submitted line joins the body, with a
	// `> ` continuation prompt, until the delimiter line arrives.
	var hd heredocCollector
	submit := func(line string) {
		if !hd.collecting() {
			vi.ConsoleLine(markerLine + line)
			shlib.SaveHistory(hst, hist, line, sink)
		}
		run, bodies, waiting := hd.accept(line)
		if waiting {
			writeTTY(fd, []byte("> "))
			return
		}
		_, act := sh.RunLineBodies(run, bodies)
		if act != shlib.ActionContinue {
			leave(ta, fd, sh, act)
		}
		// M73d (#1628): the editor's submit echo is a bare \r\n now;
		// the front-end paints the fresh prompt AFTER the command's
		// output — the reference shell loop's order (SH.BIN/TERM.BIN),
		// and what keeps a screen-clearing command from erasing the
		// prompt with nothing to repaint it. At the cursor, no CR: a
		// CR repaint would overwrite output that ended mid-row.
		// The template is re-read (a mid-session goset change still
		// lands) and re-expanded against the facts NOW — the command may
		// have been `cd` — and the editor's own bytes are written, so
		// this prompt is the one the next in-line repaint uses.
		editor.SetPrompt(loadPrompt())
		_, _ = vi.FileWrite(fd, editor.PromptBytes())
		// M98h: the tab title follows the cwd — send only when it changed.
		titles.Sync(shlib.TitleFor("Sh", sh.Pwd()), sendTitle)
		// M98f: bytes typed while a foreground child ran sit in the
		// interrupter's stash — feed them now, before the next
		// FileRead, so a pre-typed line is not lost.
		if p := hst.TTYInterrupter(); p != nil {
			if ahead := p.TypeAhead(); len(ahead) > 0 {
				handle(editor.Feed(ahead))
			}
		}
	}
	handle = func(out []byte, ev shlib.EditEvent) {
		if len(out) > 0 {
			writeTTY(fd, out)
		}
		switch ev.Kind {
		case shlib.EvSubmit:
			submit(ev.Line)
		case shlib.EvEdit:
			// M98h: Ctrl-X Ctrl-E hands the line to GOEDIT. Each returned
			// line goes through the same submit path; a failed round trip
			// says so and puts the original line back.
			lines, err := sh.EditLine(ev.Line)
			if err != nil {
				writeTTY(fd, []byte("gosh: edit: "+err.Error()+"; line not run\r\n"))
				editor.SetValue(ev.Line)
				writeTTY(fd, editor.Repaint())
				break
			}
			for _, ln := range lines {
				submit(ln)
			}
		case shlib.EvEOF:
			shutdown(ta, fd, 0)
		case shlib.EvCancel:
			// The editor already painted ^C and the fresh prompt; a
			// pending heredoc collection is abandoned with the line.
			hd.reset()
		}
	}

	var readBuf [64]byte
	// The serial front-end reads ONE byte per FileRead: a chunk read parks
	// the bytes after a submit in the editor's pending hold, and a `monitor`
	// exit would take that type-ahead down with the dying session instead of
	// handing it to the kernel monitor that owns the console next. The
	// kernel-side half of the handover (the detach's input pushback) only
	// sees bytes still in the terminal, so the tail must never be pulled
	// into userspace ahead of its submit.
	var serialByte [1]byte
	serial := ta == nil && auth == nil
	for {
		auth.Step()
		var n int
		if serial {
			n, _ = vi.FileRead(fd, serialByte[:])
		} else {
			n, _ = vi.FileRead(fd, readBuf[:])
		}
		if n > 0 {
			if serial {
				handle(editor.Feed(serialByte[:n]))
			} else {
				handle(editor.Feed(readBuf[:n]))
			}
		}
		for editor.Pending() {
			handle(editor.Feed(nil))
		}

		sh.ReapJobs()

		if ta == nil {
			if n <= 0 {
				vi.Sleep(1)
			}
			continue
		}

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

// leave ends the session for the line that asked to leave. The monitor
// handover is reported only AFTER the detach syscall returned, so the console
// log says why the shell gave the console back rather than only that it
// closed, and a marker can never claim a handover that did not happen — the
// gate sequences its `version` type on `gosh: monitor`, so a failed detach
// would otherwise type into a shell still holding the console. SH.BIN printed
// the same marker; live-sh-monitor sequences on it.
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

func shutdown(ta *tabapp.TabApp, fd uint32, status int) {
	// Detach again when leave already did it for the monitor handover: the
	// kernel's selector 0 is idempotent (it just clears the front-end), so
	// the second call only keeps this the single exit path.
	_ = vi.TtyAttach(vi.TtyDetach)
	vi.FileClose(fd)
	if status != 0 {
		_ = vi.WriteCrashReceipt(appName, "exit="+vi.Itoa64(int64(status)))
	}
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	if ta == nil {
		// Serial: the detach handed the console back to the kernel monitor,
		// and there is no window to close — exiting IS the handover.
		vi.Exit(status)
	}
	ta.CloseAndExit(status)
}

func writeTTY(fd uint32, b []byte) {
	for len(b) > 0 {
		n := len(b)
		if n > ttyWriteMax {
			n = ttyWriteMax
		}
		if _, r := vi.FileWrite(fd, b[:n]); r < 0 {
			return
		}
		b = b[n:]
	}
}

// settingsBody is the raw SETTINGS.TXT, or "" when it cannot be read. The
// prompt template and the hostname both come from here.
func settingsBody() string {
	b, r := vi.ReadFileAll(settingsPath, maxStartupBytes)
	if r < 0 || len(b) == 0 {
		return ""
	}
	return string(b)
}

// loadPrompt adopts the SETTINGS.TXT `prompt` key (SH.BIN's SH8 behavior).
// The value is the TEMPLATE: escapes are expanded at paint (M80n #1730), so
// `prompt=\w` needs no rewriting when the directory moves.
func loadPrompt() string {
	return shlib.PromptFromSettings(settingsBody(), defaultPrompt)
}

// startupLines reads the startup contract files (CRLF-aware, bounded,
// silent when missing) and returns their lines in order. Blank lines ride
// along — a heredoc body may legitimately hold one (M138a) — and the
// caller skips the ones that are not collected as bodies.
func startupLines() []string {
	var out []string
	for _, path := range []string{startupPath, profilePath} {
		b, r := vi.ReadFileAll(path, maxStartupBytes)
		if r < 0 || len(b) == 0 {
			continue
		}
		body := strings.ReplaceAll(string(b), "\r\n", "\n")
		for _, line := range strings.Split(body, "\n") {
			out = append(out, strings.TrimRight(line, "\r"))
		}
	}
	return out
}

// Tab completion is shlib.NewCompleter (M98g) — the front-ends used to
// carry identical copies of a flat word lister; the shared completer is
// context-aware and this file adds no logic.

// scriptStep is one runnable startup-contract line plus the heredoc bodies
// its own following lines supplied (nil when the line declares no `<<`).
type scriptStep struct {
	line   string
	bodies [][]byte
}

// scriptSteps folds raw script lines into runnable steps. Blank lines
// between steps are skipped; a blank consumed while a HeredocReader is
// waiting is a body line and rides along (M138a). A `<<` line pulls the
// file's own following lines until its delimiter arrives or the script
// runs out — the unterminated case still runs, with what was collected.
func scriptSteps(lines []string) []scriptStep {
	var out []scriptStep
	for i := 0; i < len(lines); i++ {
		ln := lines[i]
		if strings.TrimSpace(ln) == "" {
			continue
		}
		st := scriptStep{line: ln}
		if r, err := shlib.NewHeredocReader(ln); err == nil && r.Waiting() {
			for r.Waiting() && i+1 < len(lines) {
				i++
				r.Feed(lines[i])
			}
			st.bodies = r.Bodies()
		}
		out = append(out, st)
	}
	return out
}

// heredocCollector is the interactive half of M138a: a submitted line that
// leaves its HeredocReader waiting parks here, and each next submitted line
// joins the body until the delimiter arrives — then the ORIGINAL line runs
// with the collected bodies. The marker and history write stay with the
// caller: only a fresh (non-collecting) line earns them, so a body line
// never enters recall and the completed line is not marked twice.
type heredocCollector struct {
	r    *shlib.HeredocReader
	line string
}

// collecting reports whether a `<<` collection is in flight.
func (h *heredocCollector) collecting() bool { return h.r != nil }

// reset abandons a pending collection (the editor's EvCancel).
func (h *heredocCollector) reset() { *h = heredocCollector{} }

// accept consumes one submitted line. While a collection is in flight the
// line feeds the reader — waiting stays true until the delimiter arrives,
// when the declaring line and its bodies come back runnable. A fresh line
// that declares `<<` starts a collection; anything else passes straight
// through runnable.
func (h *heredocCollector) accept(line string) (run string, bodies [][]byte, waiting bool) {
	if h.r != nil {
		h.r.Feed(line)
		if h.r.Waiting() {
			return "", nil, true
		}
		run, bodies = h.line, h.r.Bodies()
		h.reset()
		return run, bodies, false
	}
	if r, err := shlib.NewHeredocReader(line); err == nil && r.Waiting() {
		h.r, h.line = r, line
		return "", nil, true
	}
	return line, nil, false
}
