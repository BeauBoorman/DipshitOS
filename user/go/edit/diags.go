package main

import (
	"strings"

	"virelai/vi"
)

// M107c (#2320): the build-error list. GOEDIT does not run builds (the
// review notes' task arithmetic — seat + terminal + editor + a compiler
// child overruns the EL0 slots); GOTERM/GOSH runs GOBUILD.ELF, which writes
// the M107a aggregate at <dir>/.BUILD/ERRORS.TXT, one `file:line:col: msg`
// per line. The editor READS that file on a chord:
//
//   - Ctrl-E loads it and opens the list panel (up/down move, Return jumps
//     to the selected row, Escape closes). Pressing it again re-reads the
//     file, so a fresh build's list replaces the old one.
//   - Ctrl-N / Ctrl-P are next/prev: the list loads on first use and each
//     step jumps straight to the row after/before the last landing. The
//     same chords move the selection while the panel is open. A step off
//     either end is the `end` refusal — named, never a wrap.
//
// A jump lands the caret on the diagnostic's line:col. M166a (#2979): a
// row naming a different file switches to that file's buffer or opens one
// — the dirty single-buffer refusal is gone, `full` answers only when the
// ring has no room. Rows with no position — the driver's positionless
// "gobuild:0:0" shape — are shown but refuse to jump as `no-position`.
//
// The named refusals are the card's contract: `none` when no diagnostics
// exist (the file is absent, or a successful build left it empty — that is
// what "the list clears on a clean rebuild" looks like here), `stale` when
// the open file was saved after the build wrote this list, and `rc=` when
// the read itself failed. A stale list is dropped entirely: it never shows
// for a file saved since.

// diagRow is one ERRORS.TXT line. Line/Col are the compiler's 1-based
// position; a row that parsed no position keeps line=0 and shows its text
// raw — it is information, just not a jump target.
type diagRow struct {
	file string
	line int
	col  int
	raw  string
}

// The diagnostics seams. errRead/errExists ride vi's file channel;
// errStat is the slot-79 metadata stat (meta_guest.go, or os.Stat in host
// builds). Tests substitute all three — the same seam shape clipWrite/
// clipRead already use.
var (
	errRead   = func(p string) ([]byte, int64) { return vi.ReadFileAll(p, maxBuffer) }
	errExists = vi.FileExists
	errStat   = fileMtime
)

// parseDiag splits `path:line:col: msg` — the grammar cmd/compile prints
// and M107a's writer keeps (gobuild's parseDiagLine requires the same
// terminating ':' this does). Share paths carry no ':', so the first colon
// ends the path and digits follow; the message may hold colons, which is
// why this walks left-to-right. A line without the shape is not a
// diagnostic position (false) — the caller still displays it raw.
func parseDiag(line string) (diagRow, bool) {
	i := strings.IndexByte(line, ':')
	if i <= 0 {
		return diagRow{raw: line}, false
	}
	r := diagRow{file: line[:i], raw: line}
	rest := line[i+1:]
	num := func(s string) (int, string, bool) {
		j := 0
		for j < len(s) && s[j] >= '0' && s[j] <= '9' {
			j++
		}
		if j == 0 {
			return 0, s, false
		}
		n := 0
		for _, c := range s[:j] {
			n = n*10 + int(c-'0')
		}
		return n, s[j:], true
	}
	var ok bool
	if r.line, rest, ok = num(rest); !ok || !strings.HasPrefix(rest, ":") {
		return diagRow{raw: line}, false
	}
	if r.col, rest, ok = num(rest[1:]); !ok || !strings.HasPrefix(rest, ":") {
		return diagRow{raw: line}, false
	}
	return r, true
}

// dirOf is the parent of a share path, or "" at the root.
func dirOf(p string) string {
	i := strings.LastIndexByte(p, '/')
	if i <= 0 {
		return ""
	}
	return p[:i]
}

// errorsPath resolves which ERRORS.TXT this session reads: a --diags= argv
// wins outright; else the nearest .BUILD/ERRORS.TXT walking up from the
// edited file's directory (the M107a fixed path — a file in a package dir
// finds the program dir's build), bounded at the share root.
func (e *editor) errorsPath() string {
	if e.diagsArg != "" {
		return e.diagsArg
	}
	for dir := dirOf(e.path); dir != ""; dir = dirOf(dir) {
		cand := dir + "/.BUILD/ERRORS.TXT"
		if errExists(cand) {
			return cand
		}
		if dir == "/host" {
			break
		}
	}
	return ""
}

// loadErrors reads the diagnostics file and replaces the list. The named
// refusals drop the list entirely: `none` (no file, or the empty file a
// clean build leaves), `stale` (the open file's mtime is newer than the
// list's — the bytes this list describes are not the bytes on the share),
// `rc=` (the read failed). diagsMtime keeps the file's stamp so jump-time
// staleness checks have the same baseline.
func (e *editor) loadErrors() {
	clear := func(mark string) {
		e.diags = nil
		e.diagsPath = ""
		e.diagsMtime = 0
		if e.mode == modeDiags {
			e.mode = modeEdit
		}
		vi.ConsoleLine(mark)
	}
	p := e.errorsPath()
	if p == "" {
		clear(markerErrs + "none")
		return
	}
	b, rc := errRead(p)
	if rc < 0 {
		clear(markerErrs + "rc=" + vi.Itoa64(rc))
		return
	}
	var rows []diagRow
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		r, _ := parseDiag(line)
		rows = append(rows, r)
	}
	if len(rows) == 0 {
		clear(markerErrs + "none")
		return
	}
	emt, _ := errStat(p)
	if ft, ok := errStat(e.path); ok && emt > 0 && ft > emt {
		clear(markerErrs + "stale")
		return
	}
	e.diags, e.diagsPath, e.diagsMtime = rows, p, emt
	e.diagsSel = -1
	vi.ConsoleLine(markerErrs + "n=" + vi.Itoa64(int64(len(rows))))
}

// openErrors is the Ctrl-E chord: load the diagnostics file, and when it
// carries rows open the panel on the first one. A refusal leaves the mode
// alone — the marker is the answer.
func (e *editor) openErrors() bool {
	e.hist.breakRun()
	e.loadErrors()
	if len(e.diags) > 0 {
		e.mode = modeDiags
		e.diagsSel = 0
		e.bar = e.bar[:0]
		e.bar2 = e.bar2[:0]
		e.bar2At = false
	}
	return true
}

// diagsKey owns the keyboard while the panel is open: up/down (and the
// same ctrl-n/ctrl-p the document steps with) move the selection, Return
// jumps to it and closes, Escape closes without jumping. Plain keys are
// eaten — the panel is a list, not a text bar.
func (e *editor) diagsKey(ev vi.Event) bool {
	if chord(ev, 'n', false) {
		return e.selDiag(1)
	}
	if chord(ev, 'p', false) {
		return e.selDiag(-1)
	}
	if ev.Flags&modCtrl != 0 {
		return true
	}
	if ev.Arg1 == codeEscape || ev.Arg0 == usageEsc {
		e.mode = modeEdit
		return true
	}
	if ev.Arg1 == codeReturn || ev.Arg1 == codeNewline {
		i := e.diagsSel
		e.mode = modeEdit
		e.jumpDiag(i)
		return true
	}
	switch ev.Arg0 {
	case usageUp:
		return e.selDiag(-1)
	case usageDown:
		return e.selDiag(1)
	}
	return true
}

// selDiag moves the panel selection by d, clamped to the list, and reports
// each landing so the seat can read where the selection sits.
func (e *editor) selDiag(d int) bool {
	n := e.diagsSel + d
	if n < 0 {
		n = 0
	}
	if n >= len(e.diags) {
		n = len(e.diags) - 1
	}
	if n != e.diagsSel {
		e.diagsSel = n
		vi.ConsoleLine(markerErrs + "sel=" + vi.Itoa64(int64(n+1)) +
			"/" + vi.Itoa64(int64(len(e.diags))))
	}
	return true
}

// stepDiag is the document-level next/prev: the list loads on first use,
// then each step jumps to the row d away from the last landing. Walking
// off an end is the `end` refusal.
func (e *editor) stepDiag(d int) bool {
	if len(e.diags) == 0 {
		e.loadErrors()
		if len(e.diags) == 0 {
			return true
		}
	}
	n := e.diagsSel + d
	if n < 0 || n >= len(e.diags) {
		vi.ConsoleLine(markerErrs + "end")
		return true
	}
	e.jumpDiag(n)
	return true
}

// jumpDiag lands the caret on row i's position. Refusals are named:
// `no-position` (a positionless row), `stale` (the target file was saved
// after this list was built — one stat against the load-time stamp),
// `full` (the row names another file and the buffer ring has no room —
// M166a replaces the old single-buffer `dirty` refusal: a dirty buffer no
// longer blocks the jump, the ring holds it), `miss lines=` (the line is
// past the buffer's end).
func (e *editor) jumpDiag(i int) {
	if i < 0 || i >= len(e.diags) {
		return
	}
	r := e.diags[i]
	if r.line <= 0 {
		vi.ConsoleLine(markerErrs + "no-position")
		return
	}
	if mt, ok := errStat(r.file); ok && e.diagsMtime > 0 && mt > e.diagsMtime {
		vi.ConsoleLine(markerErrs + "stale")
		return
	}
	if r.file != "" && r.file != e.path {
		e.docs = e.docList()
		if j := e.docIndex(r.file); j >= 0 {
			e.switchDoc(j)
		} else if len(e.docs) >= bufMax {
			vi.ConsoleLine(markerErrs + "full")
			return
		} else {
			e.openBuf(r.file)
		}
	}
	off := lineOffset(e.buf, r.line)
	if off < 0 {
		vi.ConsoleLine(markerErrs + "miss lines=" +
			vi.Itoa64(int64(countLines(e.buf))))
		return
	}
	end := off
	for end < len(e.buf) && e.buf[end] != '\n' {
		end++
	}
	// The compiler's column is 1-based in bytes; clamp it inside the line.
	col := r.col - 1
	if col < 0 || off+col > end {
		col = end - off
	}
	e.diagsSel = i
	e.hist.breakRun()
	e.selSet, e.markOn = false, false
	e.cur = off + col
	vi.ConsoleLine(markerErrs + "jump line=" + vi.Itoa64(int64(r.line)) +
		" col=" + vi.Itoa64(int64(r.col)))
	e.unfoldAt(e.cur, "diags")
}
