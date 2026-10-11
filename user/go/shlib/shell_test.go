package shlib

import (
	"bytes"
	"fmt"
	"sort"
	"strings"
	"testing"

	"virelai/clockfmt"
)

// fakeHost is the engine's test kernel: externals resolve to canned exit
// statuses, files live in a map, the pipe is a byte buffer, and a released
// channel lets tests drive background-job reaping deterministically.
type fakeHost struct {
	markers    []string
	out        []byte
	status     map[string]int64 // external name -> exit status (pid is fixed)
	missing    map[string]bool  // names that must fail to load
	files      map[string][]byte
	pipe       []byte
	sleeps     []int
	ticks      []int
	released   int64 // the status WaitExternal returns
	probeRuns  int   // ProbeExternal call counter
	probeAfter int   // probes before the job reports exited

	// M50 trust surface (ADR 0024). The zero value is "the kernel answered":
	// uid_user with no caps, a readable store, and no ownership denials.
	uid            uint32
	caps           uint32
	noPrincipal    bool              // slot 68 refuses (a host build's shape)
	secNames       []string          // the caller's store entry names
	secUnavailable bool              // slot 70 refuses
	denied         map[string]string // path -> errno name for an open refusal
	chmoded        map[string]uint16 // path -> the mode the shell forwarded
	chmodErr       map[string]string // path -> errno name for a denied chmod
	chdirErr       map[string]string // path -> errno name for a denied cd
	chdirPlain     bool              // Chdir fails with a plain (no-errno) error
	writeErr       bool              // every WriteFile refuses (M69f1 #1537 D3)
	writeErrPaths  map[string]bool   // M98e: WriteFile refuses only these paths
	externArgs     [][]string        // M98e: argv of every RunExternal call
	appLogs        map[string][]byte

	// M98f job-control seams. The interrupter is opt-in: default nil keeps
	// the blocking WaitExternal path (headless shape), so a test that says
	// nothing about Ctrl-C exercises the code it always exercised.
	intr      bool             // offer TTYInterrupter (interactive shape)
	poll      *TTYPoll         // the shared interrupter instance
	ttyIn     []byte           // scripted tty bytes the interrupter reads
	kills     []int64          // armed kills, in order
	killErr   map[int64]string // pid -> errno name the kill arm refuses with
	waitCalls int              // WaitExternal call counter

	exitedPids   []int64 // ExternalExited pids, in order
	exitedKilled []bool  // the killed flag each carried
}

func newFakeHost() *fakeHost {
	return &fakeHost{
		status: map[string]int64{}, missing: map[string]bool{},
		files: map[string][]byte{}, released: 43, probeAfter: -1,
		uid: 1000,
	}
}

func (f *fakeHost) Principal() (uint32, uint32, bool) {
	if f.noPrincipal {
		return 0, 0, false
	}
	return f.uid, f.caps, true
}

func (f *fakeHost) Chmod(path string, mode uint16) error {
	if name, ok := f.chmodErr[path]; ok {
		return &OpenError{path: path, name: name}
	}
	if f.chmoded == nil {
		f.chmoded = map[string]uint16{}
	}
	f.chmoded[path] = mode
	return nil
}

func (f *fakeHost) SecretNames() ([]string, bool) {
	if f.secUnavailable {
		return nil, false
	}
	return f.secNames, true
}
func (f *fakeHost) AppLogNames() []string {
	names := make([]string, 0, len(f.appLogs))
	for name := range f.appLogs {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}
func (f *fakeHost) ReadAppLog(app string) ([]byte, error) {
	if body, ok := f.appLogs[app]; ok {
		return body, nil
	}
	return nil, ErrNotFound
}

func (f *fakeHost) Marker(line string)           { f.markers = append(f.markers, line) }
func (f *fakeHost) Out(b []byte)                 { f.out = append(f.out, b...) }
func (f *fakeHost) PipeWrite(b []byte) error     { f.pipe = append(f.pipe[:0], b...); return nil }
func (f *fakeHost) PipeReadAll() ([]byte, error) { return f.pipe, nil }
func (f *fakeHost) Chdir(path string) error {
	if name, ok := f.chdirErr[path]; ok {
		return &OpenError{path: path, name: name}
	}
	if f.chdirPlain {
		return ErrNotFound
	}
	return nil
}

func (f *fakeHost) DeleteFile(path string) error {
	delete(f.files, path)
	return nil
}
func (f *fakeHost) SleepSeconds(n int) { f.sleeps = append(f.sleeps, n) }

func (f *fakeHost) RunExternal(name string, args []string) (int64, error) {
	if f.missing[name] {
		return 0, ErrNotFound
	}
	f.externArgs = append(f.externArgs, append([]string{name}, args...))
	return 7, nil // the pid is irrelevant to the engine contract
}

func (f *fakeHost) WaitExternal(pid int64) (int64, error) {
	f.waitCalls++
	return f.released, nil
}

// TTYInterrupter is the M98f Ctrl-C seam, opt-in via f.intr (the default
// nil is the headless host's answer). readTTY drains the scripted ttyIn.
func (f *fakeHost) TTYInterrupter() *TTYPoll {
	if !f.intr {
		return nil
	}
	if f.poll == nil {
		f.poll = &TTYPoll{Read: f.readTTY}
	}
	return f.poll
}

func (f *fakeHost) readTTY(b []byte) int {
	if len(f.ttyIn) == 0 {
		return 0
	}
	n := copy(b, f.ttyIn)
	f.ttyIn = f.ttyIn[n:]
	return n
}

func (f *fakeHost) Kill(pid int64) error {
	f.kills = append(f.kills, pid)
	if name, ok := f.killErr[pid]; ok {
		return &OpenError{name: name}
	}
	return nil
}

// ExternalExited records the interruptible wait's exit notification:
// exitsKilled[i] is the killed flag for exitedPids[i].
func (f *fakeHost) ExternalExited(pid int64, status int64, killed bool) {
	f.exitedPids = append(f.exitedPids, pid)
	f.exitedKilled = append(f.exitedKilled, killed)
}

func (f *fakeHost) ProbeExternal(pid int64) (int64, int) {
	f.probeRuns++
	if f.probeAfter >= 0 && f.probeRuns > f.probeAfter {
		return f.released, probeExited
	}
	return -1, probeRunning
}

func (f *fakeHost) SleepTick() { f.ticks = append(f.ticks, 1) }

func (f *fakeHost) ReadFile(path string, max int) ([]byte, error) {
	if name, ok := f.denied[path]; ok {
		return nil, &OpenError{path: path, name: name}
	}
	if b, ok := f.files[path]; ok {
		if len(b) > max {
			return b[:max], nil
		}
		return b, nil
	}
	return nil, ErrNotFound
}

func (f *fakeHost) WriteFile(path string, b []byte, appendMode bool) error {
	if f.writeErr || f.writeErrPaths[path] {
		return ErrWriteFailed
	}
	if appendMode {
		f.files[path] = append(f.files[path], b...)
	} else {
		f.files[path] = append([]byte{}, b...)
	}
	return nil
}

func (f *fakeHost) ReadTTYLine() (string, bool) { return "typed", true }

func (f *fakeHost) outString() string { return string(f.out) }

// session starts one Shell and runs every line of a scenario through it,
// the way a real session keeps its env and job table across lines.
func session(h *fakeHost) (func(string) int, *Shell) {
	sh := NewShell(h, &History{})
	return func(line string) int {
		st, _ := sh.RunLine(line)
		return st
	}, sh
}

func TestDateBuiltinUsesEpochAndNamesMissingFirmwareClock(t *testing.T) {
	prevNow, prevMono := dateNow, dateMonotonic
	t.Cleanup(func() { dateNow, dateMonotonic = prevNow, prevMono })
	h := newFakeHost()
	run, _ := session(h)
	dateNow = func() int64 { return 1_789_043_696 }
	if status := run("date"); status != 0 {
		t.Fatalf("date status = %d, want 0", status)
	}
	if got := h.outString(); got != "2026-09-10 12:34:56 UTC (epoch=1789043696)\n" {
		t.Fatalf("date output = %q", got)
	}
	h.out = nil
	dateNow = func() int64 { return -4 } // slot 66: ENOSYS, no EFI epoch
	dateMonotonic = func() int64 { return 12_500_000_000 }
	if status := run("date"); status != 1 {
		t.Fatalf("date without epoch status = %d, want 1", status)
	}
	if got := h.outString(); got != "date: no firmware epoch; monotonic=12s\n" {
		t.Fatalf("no-epoch date output = %q", got)
	}
	h.out = nil
	dateNow = func() int64 { t.Fatal("date args must not read clock"); return 0 }
	if status := run("date --utc"); status != 2 {
		t.Fatalf("date args status = %d, want 2", status)
	}
	if got := h.outString(); got != "gosh: date: usage: date\n" {
		t.Fatalf("date args output = %q", got)
	}
}

// TestDateBuiltinFormatsInTheConfiguredZone (M83c #1776): the same epoch
// under the `timezone` row's fixed offset, and an invalid row falling back
// to UTC rather than shifting every clock silently.
func TestDateBuiltinFormatsInTheConfiguredZone(t *testing.T) {
	prevNow, prevZone := dateNow, dateZone
	t.Cleanup(func() { dateNow, dateZone = prevNow, prevZone })
	h := newFakeHost()
	run, _ := session(h)
	dateNow = func() int64 { return 1_789_043_696 }
	dateZone = func() clockfmt.Zone { return 5*3600 + 30*60 }
	if status := run("date"); status != 0 {
		t.Fatalf("date status = %d, want 0", status)
	}
	if got := h.outString(); got != "2026-09-10 18:04:56 UTC+05:30 (epoch=1789043696)\n" {
		t.Fatalf("zoned date output = %q", got)
	}
	h.out = nil
	dateZone = func() clockfmt.Zone { return -8 * 3600 }
	if status := run("date"); status != 0 {
		t.Fatalf("date status = %d, want 0", status)
	}
	if got := h.outString(); got != "2026-09-10 04:34:56 UTC-08:00 (epoch=1789043696)\n" {
		t.Fatalf("west-zoned date output = %q", got)
	}
}

// TestEngineVarsAndStatus pins the env/variables subset end to end.
func TestEngineVarsAndStatus(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	if st := run("set GREET=hello-vars"); st != 0 {
		t.Fatalf("set status = %d", st)
	}
	if st := run("echo V=$GREET"); st != 0 {
		t.Fatalf("echo status = %d", st)
	}
	if got := h.outString(); !strings.Contains(got, "V=hello-vars\n") {
		t.Fatalf("output = %q, want V=hello-vars", got)
	}
	h.out = nil
	run("echo BRACED=${GREET} DIRECT=$UNSET_EMPTY")
	if got := h.outString(); got != "BRACED=hello-vars DIRECT=\n" {
		t.Fatalf("braced/unset expansion = %q", got)
	}
	// $? reports the previous line's status.
	run("printenv NOPE")
	h.out = nil
	run("echo RC=$?")
	if got := h.outString(); got != "RC=1\n" {
		t.Fatalf("$? after failed printenv = %q, want RC=1", got)
	}
	// Single quotes protect the variable reference.
	h.out = nil
	run("echo 'NO $GREET'")
	if got := h.outString(); got != "NO $GREET\n" {
		t.Fatalf("single-quoted protection = %q", got)
	}
}

// TestEnginePipeline pins the sequential hand-off: left capture goes
// through the kernel pipe and arrives as the right side's stdin.
func TestEnginePipeline(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	if st := run("echo alpha-beta | grep alpha"); st != 0 {
		t.Fatalf("pipeline status = %d", st)
	}
	if got := h.outString(); got != "alpha-beta\n" {
		t.Fatalf("pipeline output = %q, want alpha-beta", got)
	}
	if string(h.pipe) != "alpha-beta\n" {
		t.Fatalf("pipe hand-off = %q, want the left capture", h.pipe)
	}
	h.out = nil
	run("printf 'a\\nb\\nc' | sort")
	if got := h.outString(); got != "a\nb\nc\n" {
		t.Fatalf("sort over pipe = %q", got)
	}
}

// TestEnginePipelineRefusals pins the honest refusals around externals in
// a pipeline (the EL0 console can not be captured).
func TestEnginePipelineRefusals(t *testing.T) {
	h := newFakeHost()
	h.missing["NOTHING.ELF"] = true
	run, _ := session(h)
	if st := run("echo x | NOTHING"); st != 1 {
		t.Fatalf("external right side status = %d, want 1", st)
	}
	if !strings.Contains(h.outString(), "would not read the pipe") {
		t.Fatalf("right-side refusal = %q", h.outString())
	}
	h = newFakeHost()
	h.missing["NOTHING.ELF"] = true
	run, _ = session(h)
	if st := run("NOTHING | grep x"); st != 1 {
		t.Fatalf("external left side status = %d, want 1", st)
	}
	if !strings.Contains(h.outString(), "cannot capture an external app") {
		t.Fatalf("left-side refusal = %q", h.outString())
	}
}

// TestEngineRedirect pins >, >> and < through the file seam, including the
// pipe-plus-redirect combination the gate reads back on the host.
func TestEngineRedirect(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	run("echo redirect-payload > /host/OUT.TXT")
	if got := string(h.files["/host/OUT.TXT"]); got != "redirect-payload\n" {
		t.Fatalf("> write = %q", got)
	}
	run("echo more >> /host/OUT.TXT")
	if got := string(h.files["/host/OUT.TXT"]); got != "redirect-payload\nmore\n" {
		t.Fatalf(">> append = %q", got)
	}
	h.out = nil
	run("cat < /host/OUT.TXT")
	if got := h.outString(); got != "redirect-payload\nmore\n" {
		t.Fatalf("< read = %q", got)
	}
	// A missing input file is an honest status 1 with a message.
	h.out = nil
	if st := run("cat < /host/NOPE.TXT"); st != 1 {
		t.Fatalf("missing < status = %d", st)
	}
	if !strings.Contains(h.outString(), "not found") {
		t.Fatalf("missing < message = %q", h.outString())
	}
	// A redirect combined with a pipe writes the right side's capture.
	run("echo alpha-beta | wc -c > /host/WC.TXT")
	if got := string(h.files["/host/WC.TXT"]); got != "11\n" {
		t.Fatalf("pipe + > = %q, want 11", got)
	}
}

// TestEngineExternals pins the exec/wait seam: the not-found 127 and the
// status propagation into $?.
func TestEngineExternals(t *testing.T) {
	h := newFakeHost()
	h.missing["GHOST"] = true
	run, _ := session(h)
	if st := run("GHOST"); st != 127 {
		t.Fatalf("not-found status = %d, want 127", st)
	}
	if !strings.Contains(h.outString(), "GHOST: not found") {
		t.Fatalf("not-found message = %q", h.outString())
	}
	if st := run("GOHELLO"); st != 43 {
		t.Fatalf("external status = %d, want the fake's 43", st)
	}
	h.out = nil
	run("echo RC=$?")
	if got := h.outString(); got != "RC=43\n" {
		t.Fatalf("$? after external = %q", got)
	}
}

// TestEngineJobs pins the background cycle: `exec X &` records a job with
// a marker, jobs shows it running, fg blocks by polling between ticks
// until the child reports exited, reports exactly once, and propagates
// the status into $?.
func TestEngineJobs(t *testing.T) {
	h := newFakeHost()
	h.probeAfter = 2 // two running probes, then exited
	_, sh := session(h)
	_, _ = sh.RunLine("GOSH.ELF -c sleep 2 &")
	if len(h.markers) != 1 || !strings.HasPrefix(h.markers[0], "gosh: job 1 pid=") {
		t.Fatalf("bg marker = %v", h.markers)
	}
	if len(sh.jobs) != 1 {
		t.Fatalf("job table = %d, want 1", len(sh.jobs))
	}
	st, _ := sh.RunLine("jobs")
	if st != 0 || !strings.Contains(h.outString(), "[1] running: GOSH.ELF -c sleep 2") {
		t.Fatalf("jobs output = %q (status %d)", h.outString(), st)
	}
	h.out = nil
	st, act := sh.RunLine("fg 1")
	if act != ActionContinue || st != 43 {
		t.Fatalf("fg = (%d, %v), want (43, continue)", st, act)
	}
	if len(h.ticks) == 0 {
		t.Fatalf("fg did not poll between ticks")
	}
	if !strings.Contains(h.outString(), "[1] Done: GOSH.ELF -c sleep 2 (exit=43)") {
		t.Fatalf("fg report = %q", h.outString())
	}
	if len(sh.jobs) != 0 {
		t.Fatalf("job not reaped: %d left", len(sh.jobs))
	}
	h.out = nil
	st, _ = sh.RunLine("echo RC=$?")
	if st != 0 || !strings.Contains(h.outString(), "RC=43\n") {
		t.Fatalf("$? after fg = %q (status %d)", h.outString(), st)
	}
	h.out = nil
	if st, _ = sh.RunLine("fg 9"); st != 1 {
		t.Fatalf("fg 9 status = %d, want 1", st)
	}
	if !strings.Contains(h.outString(), "fg: no such job") {
		t.Fatalf("fg 9 message = %q", h.outString())
	}
}

// TestEngineReapMarker pins the exactly-once done marker from the main
// loop's reaper (the gate's serial evidence for the jobs/fg cycle), and
// that jobs drops the finished entry after reporting it.
func TestEngineReapMarker(t *testing.T) {
	h := newFakeHost()
	h.probeAfter = 1
	_, sh := session(h)
	_, _ = sh.RunLine("GOSH.ELF -c echo nested &")
	sh.ReapJobs() // still running: no done marker yet
	if len(h.markers) != 1 {
		t.Fatalf("markers = %v, want only the pid marker", h.markers)
	}
	sh.ReapJobs() // the child reports exited
	if len(h.markers) != 2 {
		t.Fatalf("markers = %v, want pid + done", h.markers)
	}
	if h.markers[1] != "gosh: job 1 done exit=43" {
		t.Fatalf("done marker = %q", h.markers[1])
	}
	st, _ := sh.RunLine("jobs")
	if st != 0 || !strings.Contains(h.outString(), "[1] Done:") {
		t.Fatalf("jobs output = %q (status %d)", h.outString(), st)
	}
	if len(sh.jobs) != 0 {
		t.Fatalf("jobs did not drop the finished entry")
	}
}

// TestEngineBuiltinAmp pins the honest builtin-background refusal.
func TestEngineBuiltinAmp(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	st := run("echo hi &")
	if st != 0 {
		t.Fatalf("builtin & status = %d", st)
	}
	if !strings.Contains(h.outString(), "is a builtin; & runs external apps only") {
		t.Fatalf("builtin & message = %q", h.outString())
	}
	if !strings.Contains(h.outString(), "hi\n") {
		t.Fatalf("builtin & did not run in the foreground: %q", h.outString())
	}
}

// TestEngineExitAndMonitor pins the two shell-lifecycle actions.
func TestEngineExitAndMonitor(t *testing.T) {
	h := newFakeHost()
	_, sh := session(h)
	st, act := sh.RunLine("exit 7")
	if act != ActionExit || st != 7 {
		t.Fatalf("exit 7 = (%d, %v), want (7, exit)", st, act)
	}
	st, act = sh.RunLine("monitor")
	if act != ActionMonitor || st != 0 {
		t.Fatalf("monitor = (%d, %v), want (0, monitor)", st, act)
	}
}

// TestEngineReadPinsStdin pins `read VAR` over bound and unbound stdin.
func TestEngineReadPinsStdin(t *testing.T) {
	h := newFakeHost()
	h.files["/host/WORDS.TXT"] = []byte("beta\n")
	run, _ := session(h)
	run("read RV < /host/WORDS.TXT")
	h.out = nil
	run("echo READ=$RV")
	if got := h.outString(); got != "READ=beta\n" {
		t.Fatalf("read over redirect = %q", got)
	}
	h.out = nil
	run("read UNBOUND")
	run("echo U=$UNBOUND")
	if got := h.outString(); !strings.Contains(got, "U=typed\n") {
		t.Fatalf("read from tty = %q", got)
	}
}

// TestEngineParseRefusals pins the grammar's honest refusals.
func TestEngineParseRefusals(t *testing.T) {
	cases := []struct{ line, want string }{
		{"echo a | wc | wc", "only one pipe per line"},
		{"echo a > /x > /y", "one output redirect per line"},
		{"echo a > ", "> needs a file path"},
		{"echo a & noise", "& must end the line"},
		{"echo a > /x &", "& runs one external app"},
		{"| wc", "empty command"},
	}
	for _, tc := range cases {
		h := newFakeHost()
		run, _ := session(h)
		st := run(tc.line)
		if st != 1 {
			t.Fatalf("%q status = %d, want 1", tc.line, st)
		}
		if !strings.Contains(h.outString(), tc.want) {
			t.Fatalf("%q message = %q, want %q", tc.line, h.outString(), tc.want)
		}
	}
}

// TestEngineBlankLineIsANoOp pins the documented contract: a blank or
// comment-only line leaves $? alone and prints nothing. parsePlan calls zero
// tokens an empty command, so the guard has to run before it — otherwise a
// bare Return clobbers $? and prints an error.
func TestEngineBlankLineIsANoOp(t *testing.T) {
	h := newFakeHost()
	run, sh := session(h)
	if st := run("echo marker"); st != 0 {
		t.Fatalf("setup status = %d, want 0", st)
	}
	h.out = nil
	for _, line := range []string{"", "   ", "\t", "# just a comment", "   # indented comment"} {
		if st := run(line); st != 0 {
			t.Fatalf("%q status = %d, want 0 ($? unchanged)", line, st)
		}
	}
	if got := h.outString(); got != "" {
		t.Fatalf("blank lines printed %q", got)
	}
	if sh.Status() != 0 {
		t.Fatalf("$? = %d, want 0", sh.Status())
	}
}

// TestEngineOversizeInputFailsLoud pins the refusal that replaced silent
// truncation: an input past the 4 KiB buffer fails the line instead of
// handing the command short input that still exits 0.
func TestEngineOversizeInputFailsLoud(t *testing.T) {
	h := newFakeHost()
	h.files["BIG.TXT"] = bytes.Repeat([]byte("x"), MaxPipeBytes+1)
	run, _ := session(h)
	if st := run("wc -l < BIG.TXT"); st != 1 {
		t.Fatalf("oversize redirect status = %d, want 1", st)
	}
	if got := h.outString(); !strings.Contains(got, "input exceeds the 4096-byte buffer") {
		t.Fatalf("oversize redirect output = %q", got)
	}
	h.out = nil
	if st := run("cat BIG.TXT"); st != 1 {
		t.Fatalf("oversize cat status = %d, want 1", st)
	}
	if got := h.outString(); !strings.Contains(got, "input exceeds the 4096-byte buffer") {
		t.Fatalf("oversize cat output = %q", got)
	}
	// A file exactly at the bound is still accepted.
	h.files["OK.TXT"] = bytes.Repeat([]byte("y"), MaxPipeBytes)
	h.out = nil
	out, st := toolOut(t, h, "wc -c OK.TXT")
	if st != 0 || strings.TrimSpace(out) != "4096 OK.TXT" {
		t.Fatalf("at-bound read = (%q, %d)", out, st)
	}
}

// TestEnginePipeStageOverflow pins the second loud refusal: a left stage
// that outgrows the kernel's 4 KiB pipe fails the line before the pipe is
// touched, so the right stage never computes on a clipped hand-off.
func TestEnginePipeStageOverflow(t *testing.T) {
	h := newFakeHost()
	h.files["A.TXT"] = bytes.Repeat([]byte("a"), 3000)
	h.files["B.TXT"] = bytes.Repeat([]byte("b"), 3000)
	run, _ := session(h)
	if st := run("cat A.TXT B.TXT | wc -c"); st != 1 {
		t.Fatalf("overflowing pipeline status = %d, want 1", st)
	}
	if got := h.outString(); !strings.Contains(got, "pipe stage output exceeds") {
		t.Fatalf("overflowing pipeline output = %q", got)
	}
}

// TestBoundedCapture pins the mechanism both refusals ride on: it stops at
// the limit, records the overflow once, and stops appending.
func TestBoundedCapture(t *testing.T) {
	var c boundedCapture
	c.lim = 8
	c.write([]byte("1234"))
	c.write([]byte("5678")) // exactly at the limit: still accepted
	if c.over || string(c.buf) != "12345678" {
		t.Fatalf("at-limit capture = (%q, over=%v)", c.buf, c.over)
	}
	c.write([]byte("9"))
	if !c.over {
		t.Fatal("overflow not recorded")
	}
	c.write([]byte("more"))
	if string(c.buf) != "12345678" {
		t.Fatalf("overflow grew the buffer: %q", c.buf)
	}
}

// TestEngineExecPrefix pins the monitor-vocabulary exec: `exec NAME args`
// runs NAME (and backgrounds with &), without replacing the shell.
func TestEngineExecPrefix(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	if st := run("exec GOHELLO"); st != 43 {
		t.Fatalf("exec status = %d, want 43", st)
	}
	if got := h.outString(); got != "" {
		t.Fatalf("unexpected output: %q", got)
	}
	// Background through the prefix takes the job path.
	_, sh := session(h)
	_, _ = sh.RunLine(`exec GOSH.ELF -c "sleep 2" &`)
	if len(sh.jobs) != 1 {
		t.Fatalf("exec & job table = %d, want 1", len(sh.jobs))
	}
	if len(h.markers) != 1 || !strings.HasPrefix(h.markers[0], "gosh: job 1 pid=") {
		t.Fatalf("exec & markers = %v", h.markers)
	}
}

// --- M50 trust surface (ADR 0024), retargeted into GOSH by M68b (#1450) ------

// TestTrustPrincipal pins whoami/id against the seam: the same text the Zig
// shell printed, because the M50 gate asserts it verbatim.
func TestTrustPrincipal(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	if st := run("whoami"); st != 0 {
		t.Fatalf("whoami status = %d", st)
	}
	if got := h.outString(); got != "uid=1000 user\n" {
		t.Fatalf("whoami = %q want uid=1000 user", got)
	}
	h.out = nil
	if st := run("id"); st != 0 {
		t.Fatalf("id status = %d", st)
	}
	if got := h.outString(); got != "uid=1000 user caps=0\n" {
		t.Fatalf("id = %q want uid=1000 user caps=0", got)
	}
}

// The system principal renders as `system`, and a seam that cannot answer is
// an honest status 1 — never a fabricated uid 0 with no identity behind it.
func TestTrustPrincipalSystemAndRefusal(t *testing.T) {
	h := newFakeHost()
	h.uid = 0
	run, _ := session(h)
	run("whoami")
	if got := h.outString(); got != "uid=0 system\n" {
		t.Fatalf("system whoami = %q", got)
	}
	h.out = nil
	h.noPrincipal = true
	if st := run("whoami"); st != 1 {
		t.Fatalf("no-principal whoami status = %d want 1", st)
	}
	if got := h.outString(); got != "whoami: no principal\n" {
		t.Fatalf("no-principal whoami = %q", got)
	}
	h.out = nil
	if st := run("id"); st != 1 {
		t.Fatalf("no-principal id status = %d want 1", st)
	}
	if got := h.outString(); got != "id: no principal\n" {
		t.Fatalf("no-principal id = %q", got)
	}
}

// TestTrustChmod pins the forwarding: the octal mode reaches the kernel, the
// refusal carries the kernel's errno name, and bad input never reaches it.
func TestTrustChmod(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	if st := run("chmod 600 PLAIN.TXT"); st != 0 {
		t.Fatalf("chmod status = %d", st)
	}
	if got := h.chmoded["PLAIN.TXT"]; got != 0o600 {
		t.Fatalf("forwarded mode = %o want 600", got)
	}
	if got := h.outString(); got != "chmod: ok\n" {
		t.Fatalf("chmod = %q", got)
	}

	h.out = nil
	h.chmodErr = map[string]string{"TARGET.TXT": "EACCES"}
	if st := run("chmod 600 TARGET.TXT"); st != 1 {
		t.Fatalf("denied chmod status = %d want 1", st)
	}
	if got := h.outString(); got != "chmod: TARGET.TXT: EACCES\n" {
		t.Fatalf("denied chmod = %q", got)
	}

	h.out = nil
	if st := run("chmod 600"); st != 1 {
		t.Fatalf("chmod usage status = %d want 1", st)
	}
	if got := h.outString(); got != "chmod: usage: chmod MODE FILE\n" {
		t.Fatalf("chmod usage = %q", got)
	}

	h.out = nil
	if st := run("chmod 9x9 PLAIN.TXT"); st != 1 {
		t.Fatalf("bad-mode chmod status = %d want 1", st)
	}
	if got := h.outString(); got != "chmod: invalid mode (use octal, e.g. 600)\n" {
		t.Fatalf("bad-mode chmod = %q", got)
	}
}

// TestTrustSecrets pins the name-only listing: two-space indent per name,
// `(none)` for an empty store, and a refusal when the slot will not answer.
// A value must never appear here — this seam does not carry one.
func TestTrustSecrets(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	h.secNames = []string{"netkey", "other"}
	if st := run("secrets"); st != 0 {
		t.Fatalf("secrets status = %d", st)
	}
	if got := h.outString(); got != "  netkey\n  other\n" {
		t.Fatalf("secrets = %q", got)
	}

	h.out = nil
	h.secNames = nil
	run("secrets")
	if got := h.outString(); got != "secrets: (none)\n" {
		t.Fatalf("empty secrets = %q", got)
	}

	h.out = nil
	h.secUnavailable = true
	if st := run("secrets"); st != 1 {
		t.Fatalf("unavailable secrets status = %d want 1", st)
	}
	if got := h.outString(); got != "secrets: unavailable\n" {
		t.Fatalf("unavailable secrets = %q", got)
	}
}

// TestTrustOpenDenialNamesTheErrno pins the M50 gate's load-bearing message:
// a denied open prints the KERNEL's errno, not a generic "not found", both
// for `cat FILE` and for a `< FILE` redirect.
func TestTrustOpenDenialNamesTheErrno(t *testing.T) {
	h := newFakeHost()
	h.denied = map[string]string{"TARGET.TXT": "EACCES", "SECRETS.TXT": "EACCES"}
	run, _ := session(h)
	if st := run("cat TARGET.TXT"); st != 1 {
		t.Fatalf("denied cat status = %d want 1", st)
	}
	if got := h.outString(); got != "gosh: cannot open TARGET.TXT: EACCES\n" {
		t.Fatalf("denied cat = %q", got)
	}
	h.out = nil
	if st := run("cat < SECRETS.TXT"); st != 1 {
		t.Fatalf("denied redirect status = %d want 1", st)
	}
	if got := h.outString(); got != "gosh: cannot open SECRETS.TXT: EACCES\n" {
		t.Fatalf("denied redirect = %q", got)
	}
	// A genuinely absent file keeps the plain message.
	h.out = nil
	if st := run("cat < NOPE.TXT"); st != 1 {
		t.Fatalf("absent redirect status = %d want 1", st)
	}
	if got := h.outString(); got != "gosh: NOPE.TXT: not found\n" {
		t.Fatalf("absent redirect = %q", got)
	}
}

// parseOctMode is the shell's half of the chmod contract: 1..4 octal digits
// within the permission bits; the kernel re-validates and owns the group
// triplet.
func TestParseOctMode(t *testing.T) {
	good := map[string]uint16{"600": 0o600, "0600": 0o600, "644": 0o644, "777": 0o777, "0": 0}
	for in, want := range good {
		got, ok := parseOctMode(in)
		if !ok || got != want {
			t.Fatalf("parseOctMode(%q) = %o/%v want %o", in, got, ok, want)
		}
	}
	for _, bad := range []string{"", "8", "9x9", "10000", "800", "06000"} {
		if got, ok := parseOctMode(bad); ok {
			t.Fatalf("parseOctMode(%q) = %o accepted", bad, got)
		}
	}
}

// cd must not fold three different failures into one message: the reviewer of
// PR #1496 caught that a missing directory, a path that is a file, and an
// ownership denial on the share's list gate all printed "not a directory".
// The kernel's errno now travels, and the plain fallback is the fake-only shape.
func TestCdNamesTheErrno(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	if st := run("cd /data"); st != 0 {
		t.Fatalf("cd /data status = %d want 0", st)
	}

	h.out = nil
	h.chdirErr = map[string]string{"/secret": "EACCES", "/gone": "ENOENT"}
	if st := run("cd /secret"); st != 1 {
		t.Fatalf("denied cd status = %d want 1", st)
	}
	if got := h.outString(); got != "gosh: cd: /secret: EACCES\n" {
		t.Fatalf("denied cd = %q want the kernel's errno", got)
	}

	h.out = nil
	if st := run("cd /gone"); st != 1 {
		t.Fatalf("missing cd status = %d want 1", st)
	}
	if got := h.outString(); got != "gosh: cd: /gone: ENOENT\n" {
		t.Fatalf("missing cd = %q", got)
	}

	// The generic message survives only for a seam with no errno to report.
	h.out = nil
	h.chdirErr = nil
	h.chdirPlain = true
	if st := run("cd anything"); st != 1 {
		t.Fatalf("plain cd status = %d want 1", st)
	}
	if got := h.outString(); got != "gosh: cd: anything: not a directory\n" {
		t.Fatalf("plain cd = %q", got)
	}
}

// --- M69f2 (#1538): the ADR 0008 D1 grouped help catalog ------------------

// helpContains is a tiny membership test (no slices package in this GOOS).
func helpContains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// TestHelpCatalogMatchesVerbTables is the drift guard: the catalog is data
// beside the builtin and toolbox tables, so it must describe exactly the
// verbs that exist -- one row per builtin, one per tool, one for `exec` --
// and no row may name a verb this shell cannot run.
func TestHelpCatalogMatchesVerbTables(t *testing.T) {
	for name := range builtins {
		if _, ok := helpCatalog[name]; !ok {
			t.Errorf("builtin %q has no help catalog row", name)
		}
	}
	for name := range tools {
		if _, ok := helpCatalog[name]; !ok {
			t.Errorf("tool %q has no help catalog row", name)
		}
	}
	if _, ok := helpCatalog[helpExternal]; !ok {
		t.Errorf("external %q has no help catalog row", helpExternal)
	}
	for name, e := range helpCatalog {
		_, isBuiltin := builtins[name]
		_, isTool := tools[name]
		// The externals group is the exception: it carries `exec` plus the
		// app names it launches (M71n/M78a), which are images the engine runs
		// rather than entries in builtins/tools.
		if !isBuiltin && !isTool && name != helpExternal && e.group != "externals" {
			t.Errorf("help catalog row %q names no verb this shell can run", name)
		}
		if !helpContains(helpGroups, e.group) && e.group != "tools" && e.group != "externals" {
			t.Errorf("help catalog row %q has unknown group %q", name, e.group)
		}
		if e.usage == "" || e.blurb == "" {
			t.Errorf("help catalog row %q is missing usage/blurb", name)
		}
	}
}

// TestHelpCatalogIsGrouped pins the no-argument page: `builtins:` stays the
// FIRST line (live-sh-complete / live-sh4 sequence their typed `help` on it),
// there is more than one group section, and every runnable name appears.
func TestHelpCatalogIsGrouped(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	if st := run("help"); st != 0 {
		t.Fatalf("help status = %d want 0", st)
	}
	got := h.outString()
	lines := strings.Split(strings.TrimSuffix(got, "\n"), "\n")
	if len(lines) == 0 || lines[0] != "builtins:" {
		t.Fatalf("help first line = %q, want %q", lines[0], "builtins:")
	}
	sections := 0
	for _, g := range helpGroups {
		if strings.Contains(got, "\n  "+g+": ") {
			sections++
		}
	}
	if sections < 2 {
		t.Fatalf("help printed %d group sections, want >= 2:\n%s", sections, got)
	}
	if err := helpMustBeUnique(got); err != "" {
		t.Fatalf("%s\n%s", err, got)
	}
	for name := range builtins {
		if !strings.Contains(got, name) {
			t.Errorf("help catalog omits builtin %q", name)
		}
	}
	for name := range tools {
		if !strings.Contains(got, name) {
			t.Errorf("help catalog omits tool %q", name)
		}
	}
}

// helpMustBeUnique fails when a name is listed twice inside the builtin
// group block -- the "exactly once" half of the card's deliverable 1.
func helpMustBeUnique(catalog string) string {
	seen := map[string]int{}
	for _, ln := range strings.Split(catalog, "\n") {
		if !strings.HasPrefix(ln, "  ") || !strings.Contains(ln, ": ") {
			continue
		}
		body := ln[strings.Index(ln, ": ")+2:]
		for _, name := range strings.Fields(body) {
			seen[name]++
		}
	}
	for name, n := range seen {
		if n > 1 {
			return "help catalog lists " + name + " " + itoaSmall(n) + " times"
		}
	}
	return ""
}

func itoaSmall(n int) string {
	if n < 10 {
		return string(rune('0' + n))
	}
	return "n"
}

// TestHelpVerbPage pins one builtin page byte-for-byte and one tool page, so
// a rewrite of the catalog cannot silently drop the usage line ADR 0008 D1
// requires.
func TestHelpVerbPage(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	if st := run("help echo"); st != 0 {
		t.Fatalf("help echo status = %d want 0", st)
	}
	want := "echo \u2014 write ARG... separated by single spaces and a newline\n" +
		"usage: echo [ARG...]\n" +
		"The engine expands $VAR, ${VAR} and $? before echo runs.\n"
	if got := h.outString(); got != want {
		t.Fatalf("help echo =\n%q\nwant\n%q", got, want)
	}

	h.out = nil
	if st := run("help grep"); st != 0 {
		t.Fatalf("help grep status = %d want 0", st)
	}
	if got := h.outString(); !strings.Contains(got, "usage: grep [-i] PATTERN [FILE...]\n") {
		t.Fatalf("help grep = %q, missing the tool usage line", got)
	}
}

func TestLogBuiltinReadsOneAndAllAppRings(t *testing.T) {
	h := newFakeHost()
	h.appLogs = map[string][]byte{
		"APPB.ELF": []byte("second app\n"),
		"APPA.ELF": []byte("first app\n"),
	}
	run, _ := session(h)
	if st := run("log APPA.ELF"); st != 0 || h.outString() != "first app\n" {
		t.Fatalf("log one status=%d output=%q", st, h.outString())
	}
	h.out = nil
	if st := run("log"); st != 0 {
		t.Fatalf("log all status=%d", st)
	}
	if got, want := h.outString(), "APPA.ELF:\nfirst app\nAPPB.ELF:\nsecond app\n"; got != want {
		t.Fatalf("log all = %q, want %q", got, want)
	}
}

// TestHelpGroupPageAndUnknownVerb pins `help identity` (group) and ADR 0008
// D3's unknown-verb shape, which must not be a dump of everything.
func TestHelpGroupPageAndUnknownVerb(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	if st := run("help identity"); st != 0 {
		t.Fatalf("help identity status = %d want 0", st)
	}
	if got, want := h.outString(), "identity: chmod id secrets whoami\n"; got != want {
		t.Fatalf("help identity = %q want %q", got, want)
	}

	h.out = nil
	if st := run("help nosuchverb"); st != 1 {
		t.Fatalf("help nosuchverb status = %d want 1", st)
	}
	if got, want := h.outString(), "unknown command 'nosuchverb' \u2014 try 'help'\n"; got != want {
		t.Fatalf("help nosuchverb = %q want %q", got, want)
	}

	h.out = nil
	if st := run("help one two"); st != 2 {
		t.Fatalf("help misuse status = %d want 2", st)
	}
	if got := h.outString(); !strings.Contains(got, "usage: help [CMD|GROUP]\n") {
		t.Fatalf("help misuse = %q, missing the D3 usage line", got)
	}
}

// TestHelpNamesTheNetCLIs pins discoverability for Go network CLIs in the
// grouped catalog; each lives in externals, not the builtin/tool tables.
func TestHelpNamesTheNetCLIs(t *testing.T) {
	for _, name := range []string{"GOFETCH.ELF", "GOPING.ELF", "GONETSTAT.ELF", "GODNS.ELF", "GOTRACEROUTE.ELF", "GOTGIT.ELF"} {
		e, ok := helpCatalog[name]
		if !ok {
			t.Errorf("net CLI %q has no help catalog row", name)
			continue
		}
		if e.group != "externals" {
			t.Errorf("net CLI %q is in group %q, want externals", name, e.group)
		}
	}
	catalog := helpCatalogText()
	for _, name := range []string{"GOFETCH.ELF", "GOPING.ELF", "GONETSTAT.ELF", "GODNS.ELF", "GOTRACEROUTE.ELF", "GOTGIT.ELF"} {
		if !strings.Contains(catalog, name) {
			t.Errorf("the grouped catalog does not list %q", name)
		}
	}
	// The command line a daily user types is on the verb's own page too.
	if !strings.Contains(catalog, "exec NAME [args...]") &&
		!strings.Contains(strings.Join(helpGroupNames("externals"), " "), "exec") {
		t.Error("the externals group does not mention the exec verb")
	}
	// M78b (#1683): GOFETCH also owns the cleartext fetch and --download
	// rows now, so the help page must name both forms.
	gofetch := helpCatalog["GOFETCH.ELF"]
	for _, want := range []string{"http://", "--download"} {
		if !strings.Contains(gofetch.usage, want) {
			t.Errorf("GOFETCH.ELF help usage does not name %q: %q", want, gofetch.usage)
		}
	}
}

// TestHelpNamesNoDeletedBinaries is #1538 D2 inverted: a help page must never
// advertise a binary M60 deleted (the NOTEPAD.BIN chord lesson).
func TestHelpNamesNoDeletedBinaries(t *testing.T) {
	dead := []string{"NOTEPAD.BIN", "EDIT.BIN", "CALC.BIN", "SH.BIN", "TABWM.BIN", "FETCH.BIN", "DOWNLOAD.BIN"}
	texts := map[string]string{"catalog": helpCatalogText()}
	for name, e := range helpCatalog {
		texts[name] = name + " | " + e.usage + " | " + e.blurb + " | " + e.notes
	}
	for _, d := range dead {
		for name, text := range texts {
			if strings.Contains(text, d) {
				t.Errorf("help page %q names deleted binary %q", name, d)
			}
		}
	}
}

// --- M69f1 (#1537): persistence at the host seam -------------------------
//
// SaveHistory is called with the engine's ring AFTER the editor pushed the
// submitted line (edit.go's EvSubmit); these tests drive the same order.

// TestHistoryPersistsAcrossSessions is the save/load story: session 2's ring
// is seeded from the file session 1 wrote, and the file carries the ring's
// own shape (one line per entry, oldest first, dup-collapsed).
func TestHistoryPersistsAcrossSessions(t *testing.T) {
	h := newFakeHost()

	// Session 1: nothing on the share yet.
	first := &History{}
	s1 := &HistorySink{}
	LoadHistory(h, first, s1)
	if got := first.Entries(); len(got) != 0 {
		t.Fatalf("first session started with %q; want empty", got)
	}
	for _, ln := range []string{"echo one", "echo two", "echo two", "help echo"} {
		first.Push(ln)
		SaveHistory(h, first, ln, s1)
	}
	if got, want := string(h.files[histPath]), "echo one\necho two\nhelp echo\n"; got != want {
		t.Fatalf("history file = %q want %q", got, want)
	}

	// Session 2: a fresh process (fresh ring, fresh sink) recalls it.
	second := &History{}
	s2 := &HistorySink{}
	LoadHistory(h, second, s2)
	if got, want := strings.Join(second.Entries(), ","), "echo one,echo two,help echo"; got != want {
		t.Fatalf("second session ring = %q want %q", got, want)
	}
	// The newest line is last, so one Up arrow recalls it (the M18 T4 shape).
	ents := second.Entries()
	if ents[len(ents)-1] != "help echo" {
		t.Fatalf("newest recall entry = %q want %q", ents[len(ents)-1], "help echo")
	}
	// And a re-submit of that same line is not written twice.
	SaveHistory(h, second, "help echo", s2)
	if got, want := string(h.files[histPath]), "echo one\necho two\nhelp echo\n"; got != want {
		t.Fatalf("re-submit rewrote the file: %q", got)
	}
}

// TestHistoryFileStaysBounded: past the ring bound the file is rewritten from
// the ring instead of growing an unbounded append log.
func TestHistoryFileStaysBounded(t *testing.T) {
	h := newFakeHost()
	hist := &History{}
	sink := &HistorySink{}
	for i := 0; i < historyMax*4; i++ {
		ln := fmt.Sprintf("cmd-%03d", i)
		hist.Push(ln)
		SaveHistory(h, hist, ln, sink)
	}
	lines := strings.Count(string(h.files[histPath]), "\n")
	if lines > historyMax {
		t.Fatalf("history file holds %d lines; the ring bound is %d", lines, historyMax)
	}
	if lines == 0 {
		t.Fatal("history file is empty after 4x the bound in submits")
	}
}

// TestHistoryLoadToleratesMissingFile pins D1/D3: a missing or unreadable
// share file is an empty ring, never an error and never a session end.
func TestHistoryLoadToleratesMissingFile(t *testing.T) {
	h := newFakeHost()
	hist := &History{}
	sink := &HistorySink{}
	h.denied = map[string]string{histPath: "EACCES"}
	LoadHistory(h, hist, sink)
	if got := hist.Entries(); len(got) != 0 {
		t.Fatalf("denied load = %q want empty", got)
	}
	// A share that refuses the write reports once and keeps the session: the
	// ring still holds the line, so recall works even without the file.
	h2 := newFakeHost()
	h2.writeErr = true
	hist2 := &History{}
	sink2 := &HistorySink{}
	hist2.Push("echo x")
	SaveHistory(h2, hist2, "echo x", sink2)
	if !sink2.warned {
		t.Fatal("a refused write did not latch the one-line report")
	}
	if got, want := strings.Join(hist2.Entries(), ","), "echo x"; got != want {
		t.Fatalf("in-session recall after a refused write = %q want %q", got, want)
	}
}

// TestHistoryWarnIsPrintedOnce: D3's one-line report, not one per keystroke.
func TestHistoryWarnIsPrintedOnce(t *testing.T) {
	s := &HistorySink{}
	s.warn()
	s.warn()
	if !s.warned {
		t.Fatal("warn did not latch")
	}
}

// TestHistoryDoesNotTouchTheMonitorFile pins D1: the shell's file is its own,
// and the monitor's HISTORY.TXT is never written.
func TestHistoryDoesNotTouchTheMonitorFile(t *testing.T) {
	h := newFakeHost()
	hist := &History{}
	sink := &HistorySink{}
	for _, ln := range []string{"echo a", "echo b"} {
		hist.Push(ln)
		SaveHistory(h, hist, ln, sink)
	}
	if _, ok := h.files["/host/HISTORY.TXT"]; ok {
		t.Fatal("SaveHistory wrote the monitor's HISTORY.TXT")
	}
	if _, ok := h.files[histPath]; !ok {
		t.Fatal("SaveHistory did not write " + histPath)
	}
}
