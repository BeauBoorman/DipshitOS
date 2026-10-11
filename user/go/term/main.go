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
	"strings"

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
	ticksPerSecond  = 100  // the scheduler tick is ~10 ms (kernel timer @ ~100 Hz)
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
	markerOK      = "goterm OK"
	markerMonitor = "goterm: monitor"
	markerMonErr  = "goterm: monitor failed"
	markerOpenErr = "goterm: error open "
	markerTtyErr  = "goterm: no /dev/tty"
	markerAttErr  = "goterm: attach failed"
)

func main() {
	ta := tabapp.Init(tabapp.Config{
		Name:  appName,
		Title: appTitle,
		X:     64,
		Y:     48,
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
	runSession(ta, fd)
}

// runSession is the startup block + editor loop over the attached tty.
// The card's order, through the tty: banner (startup contract lines run
// by the engine, output painted by the kernel — they print no marker,
// because go-wm-hid asserts `goterm: line ` is ABSENT when nobody typed),
// prompt load, history load, ready, first prompt.
func runSession(ta *tabapp.TabApp, fd uint32) {
	hst := &termHost{fd: fd}
	hist := &shlib.History{}
	sink := &shlib.HistorySink{}
	sh := shlib.NewShell(hst, hist)
	policy := loadRestartPolicy()

	// M98h: the tab title follows the cwd — one tracker for the window's
	// whole life (a shell restart keeps the seat, and the title it last
	// sent). Sync after each startup contract and after every submitted
	// line; the tracker sends only on change.
	titles := &shlib.TitleSync{}
	sendTitle := func(s string) bool {
		return ta != nil && ta.TabAware && ta.SetTabTitle(s)
	}

	// A terminal owns the window; a shell is one guest in that window. Keep
	// the same fd, host, and history across restarts so the new shell has
	// the same terminal contract and recall, but none of the old shell's
	// jobs or environment.
	for session := 0; ; session++ {
		if session > 0 {
			sh = shlib.NewShell(hst, hist)
		}
		for _, ln := range startupLines() {
			_, act := sh.RunLine(ln)
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
		_, _ = vi.FileWrite(fd, editor.Repaint())
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
		submit := func(line string) {
			eofPending = false
			vi.ConsoleLine(markerLine + line)
			shlib.SaveHistory(hst, hist, line, sink)
			if closeRequested(line) {
				vi.ConsoleLine(markerDone + "0")
				shutdown(ta, fd, 0)
				return
			}
			st, act := sh.RunLine(line)
			// Only AFTER the engine answered: the gate sequences on this,
			// so it can never claim an execution that did not happen.
			vi.ConsoleLine(markerDone + vi.Itoa64(int64(st)))
			if act == shlib.ActionExit && policy == restartStay {
				writeTTY(fd, []byte(restartMessage(st)))
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
				writeTTY(fd, editor.PromptBytes())
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
				writeTTY(fd, out)
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
					writeTTY(fd, []byte("gosh: edit: "+err.Error()+"; line not run\r\n"))
					editor.SetValue(ev.Line)
					writeTTY(fd, editor.Repaint())
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
				writeTTY(fd, []byte("\r\ngoterm: press Ctrl-D again to close\r\n"))
				writeTTY(fd, editor.Repaint())
			case shlib.EvCancel:
				eofPending = false
				// The editor already painted ^C and the fresh prompt.
			}
		}

		var readBuf [64]byte
		for !restart {
			n, _ := vi.FileRead(fd, readBuf[:])
			if n > 0 {
				handle(editor.Feed(readBuf[:n]))
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
// silent when missing) and returns their non-empty lines in order.
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
// CRLF and CR are folded to LF, blank lines dropped, order kept.
func startupLinesFrom(body string) []string {
	var out []string
	body = strings.ReplaceAll(body, "\r\n", "\n")
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) != "" {
			out = append(out, line)
		}
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
	poll *shlib.TTYPoll
}

func (g *termHost) Marker(line string) { vi.ConsoleLine(line) }

// Out writes command output to the attached tty; the kernel paints it
// into the window (ADR 0020 A4).
func (g *termHost) Out(b []byte) { writeTTY(g.fd, b) }

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

func (g *termHost) SleepSeconds(n int) {
	vi.Sleep(uint64(n) * ticksPerSecond)
}
