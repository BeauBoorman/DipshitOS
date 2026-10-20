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
	h := &goshHost{}
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
	hst := &goshHost{fd: fd, tty: true}
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
	lines := startupLines()
	for i := 0; i < len(lines); i++ {
		ln := lines[i]
		if strings.TrimSpace(ln) == "" {
			continue
		}
		vi.ConsoleLine(markerLine + ln)
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
	// here while each subsequent submitted line joins the body, with a `> `
	// continuation prompt, until the delimiter line arrives.
	var hdR *shlib.HeredocReader
	var hdLine string
	submit := func(line string) {
		var bodies [][]byte
		if hdR != nil {
			hdR.Feed(line)
			if hdR.Waiting() {
				writeTTY(fd, []byte("> "))
				return
			}
			line, bodies = hdLine, hdR.Bodies()
			hdR = nil
		} else {
			vi.ConsoleLine(markerLine + line)
			shlib.SaveHistory(hst, hist, line, sink)
			if r, err := shlib.NewHeredocReader(line); err == nil && r.Waiting() {
				hdR, hdLine = r, line
				writeTTY(fd, []byte("> "))
				return
			}
		}
		_, act := sh.RunLineBodies(line, bodies)
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
			hdR = nil
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

// goshHost is the Host seam over vi. When tty is set, Out writes the
// attached /dev/tty (serial, window, or net — the kernel pumps the right
// front-end). Headless, Out buffers console lines. fd 0 is a valid kernel
// file handle (the first open), so it cannot mean "no tty".
type goshHost struct {
	fd       uint32
	tty      bool
	lineBuf  []byte
	children map[int64]string
	poll     *shlib.TTYPoll
}

func (g *goshHost) Marker(line string) { vi.ConsoleLine(line) }

func (g *goshHost) Out(b []byte) {
	if g.tty {
		writeTTY(g.fd, b)
		return
	}
	g.lineBuf = append(g.lineBuf, b...)
	for {
		i := indexByte(g.lineBuf, '\n')
		if i < 0 {
			return
		}
		vi.ConsoleLine(string(g.lineBuf[:i]))
		g.lineBuf = g.lineBuf[i+1:]
	}
}

// flushOut drains a trailing partial line at headless exit.
func (g *goshHost) flushOut() {
	if !g.tty && len(g.lineBuf) > 0 {
		vi.ConsoleLine(string(g.lineBuf))
		g.lineBuf = nil
	}
}

func indexByte(b []byte, c byte) int {
	for i, x := range b {
		if x == c {
			return i
		}
	}
	return -1
}

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

func (g *goshHost) RunExternal(name string, args []string) (int64, error) {
	for _, cand := range candidateNames(name) {
		if pid, err := vi.Exec(cand, args...); err == nil {
			if g.children == nil {
				g.children = make(map[int64]string)
			}
			g.children[pid] = cand
			return pid, nil
		}
	}
	return 0, shlib.ErrNotFound
}

func (g *goshHost) WaitExternal(pid int64) (int64, error) {
	status, err := vi.Wait(pid)
	if err == nil && status != 0 {
		g.RecordCrash(g.children[pid], status)
	}
	delete(g.children, pid)
	return status, err
}

func (g *goshHost) ProbeExternal(pid int64) (int64, int) {
	st, state := vi.Probe(pid)
	return st, state
}

// ExternalExited keeps the interruptible wait's bookkeeping level with
// WaitExternal's: the children row always retires, and a nonzero exit
// still earns its crash receipt — except a kill the shell armed itself,
// which the card declares is not a crash.
func (g *goshHost) ExternalExited(pid int64, status int64, killed bool) {
	name := g.children[pid]
	delete(g.children, pid)
	if !killed && status != 0 {
		g.RecordCrash(name, status)
	}
}

func (g *goshHost) SleepTick() { vi.Sleep(1) }

// TTYInterrupter is the M98f Ctrl-C seam: the same fd the session loop
// reads, handed to the engine as a non-blocking byte source while it
// waits. Headless (-c) hosts have no fd and answer nil, keeping the
// blocking WaitExternal path. The instance persists on the host — its
// type-ahead stash must survive between the engine's waits.
func (g *goshHost) TTYInterrupter() *shlib.TTYPoll {
	if !g.tty {
		return nil
	}
	if g.poll == nil {
		g.poll = &shlib.TTYPoll{Read: func(b []byte) int {
			n, _ := vi.FileRead(g.fd, b)
			return n
		}}
	}
	return g.poll
}

// Kill arms sys_kill (slot 29) for `kill`/Ctrl-C, carrying the kernel's
// errno name so the engine can report EACCES vs EINVAL honestly.
func (g *goshHost) Kill(pid int64) error {
	if r := vi.Kill(uint64(pid)); r < 0 {
		if name := vi.ErrnoName(r); name != "" {
			return shlib.NewOpenError(vi.Itoa64(pid), name)
		}
		return shlib.ErrNotFound
	}
	return nil
}

func (g *goshHost) PipeWrite(b []byte) error {
	_, err := vi.PipeWrite(b)
	return err
}

func (g *goshHost) PipeReadAll() ([]byte, error) {
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

func (g *goshHost) ReadFile(path string, max int) ([]byte, error) {
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
func (g *goshHost) Principal() (uint32, uint32, bool) { return vi.Principal() }

// Chmod is the owner-only mode change (slot 69).
func (g *goshHost) Chmod(path string, mode uint16) error {
	r := vi.FileMode(path, mode)
	if r < 0 {
		if name := vi.ErrnoName(r); name != "" {
			return shlib.NewOpenError(path, name)
		}
		return shlib.ErrNotFound
	}
	return nil
}

// SecretNames reads the caller's store entry NAMES (slot 70). The values are
// deliberately not carried through this seam.
func (g *goshHost) SecretNames() ([]string, bool) {
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

// Suspend is the guest-initiated power request (M115d, slot 93): the
// kernel runs the whole authenticated ctl session under its uid_system
// `vsock-ctl` credential — no key bytes cross the seam. The ok return
// may land on the far side of a host save/restore.
func (g *goshHost) Suspend() (bool, string) {
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

func (g *goshHost) AppLogNames() []string {
	names, rc := vi.AppLogNames()
	if rc < 0 {
		return nil
	}
	return names
}

func (g *goshHost) ReadAppLog(app string) ([]byte, error) {
	b, rc := vi.ReadLog(app)
	if rc < 0 {
		return nil, shlib.ErrNotFound
	}
	return b, nil
}

func (g *goshHost) RecordCrash(app string, status int64) {
	outcome := "exit=" + vi.Itoa64(status)
	_ = vi.Log(app, outcome)
	_ = vi.WriteCrashReceipt(app, outcome)
}

// WriteFile is the shell's whole write hook, and it used to be the last
// in-place writer in the Go tree (M81e2 #1787): open(ModeWrite|ModeCreate
// [|ModeAppend]) then FileWriteAll, no truncate barrier, no rename. Two
// callers with DIFFERENT semantics share this one seam, so the policy
// decision lives in vi.WriteFilePublish rather than here:
//
//   - REPLACE (appendMode false) is the history ring save (shlib.SaveHistory
//     trimming the ring back to historyMax) and shell redirection `> file`.
//     Both hold the complete new body in memory, and both mean "these bytes
//     replace what was there" — app state, so it publishes crash-safe.
//   - APPEND (appendMode true) is the history one-line append and `>>`. It
//     is not a rewrite, so it stays an append; vi.WriteFilePublish owns that
//     reason.
//
// Redirection `> file` is therefore NOT exempt from the safe publish. The
// objection is real but does not survive contact with this shell: the
// redirect buffer is capped (shlib maxRedirectBytes) and fully materialized
// before this call, so there is no streaming case where a reader must watch
// the file grow; and the observable contract is unchanged — an empty body
// still yields an empty file, a missing path is still created, and a write
// that fails now leaves the PREVIOUS contents rather than destroying them.
// The one cost, stated plainly: a path within one byte of the kernel's
// 64-byte cap cannot be published at all (vi.WriteFileSafe's `~` sibling
// would exceed it) and now fails honestly instead of writing. go-sh pins
// both halves.
func (g *goshHost) WriteFile(path string, b []byte, appendMode bool) error {
	if r := vi.WriteFilePublish(path, b, appendMode); r < 0 {
		// A refused OPEN is a path problem (gone, denied, too long); a
		// refused WRITE is the disk's. Folding both into ErrNotFound is
		// what made this hook lie, so keep them apart.
		if r == -vi.ErrEACCES || r == -vi.ErrENOENT || r == -vi.ErrENAMETOOLONG {
			return shlib.ErrNotFound
		}
		return shlib.ErrWriteFailed
	}
	return nil
}

// DeleteFile removes path — an absent file is not an error, matching
// WriteFilePublish's absent-fails-closed readers.
func (g *goshHost) DeleteFile(path string) error {
	if r := vi.FileDelete(path); r < 0 && r != -vi.ErrENOENT {
		return shlib.ErrWriteFailed
	}
	return nil
}

func (g *goshHost) Chdir(path string) error {
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
func (g *goshHost) ListPath(dir string) ([]vi.DirItem, error) {
	return vi.ListDirAt(dir)
}

func (g *goshHost) ReadTTYLine() (string, bool) {
	if !g.tty {
		return "", false
	}
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
func (g *goshHost) SleepSeconds(n int) {
	vi.Sleep(uint64(n))
}
