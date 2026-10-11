package shlib

// M98f (issue #2132): Ctrl-C interrupts + the kill/jobs surface, driven by
// the fake host's scripted probe states, scripted tty bytes and kill log.

import (
	"strings"
	"testing"
)

func hasMarker(h *fakeHost, want string) bool {
	for _, m := range h.markers {
		if strings.Contains(m, want) {
			return true
		}
	}
	return false
}

// Foreground Ctrl-C: the kill is armed exactly once, the exit row's status
// (137, the reserved kill status) lands in the marker, the caller sees
// 130, and the wait never touched WaitExternal (no crash receipt path).
func TestForegroundCtrlCArmsKillOnce(t *testing.T) {
	h := newFakeHost()
	h.intr = true
	h.ttyIn = []byte{0x03}
	// Armed at the first poll; the exit row must land within
	// killConfirmTicks or the "still running" bound fires instead.
	h.probeAfter = 2
	h.released = 137
	run, _ := session(h)
	if st := run("SLOW.BIN"); st != 130 {
		t.Fatalf("status = %d, want 130", st)
	}
	if len(h.kills) != 1 || h.kills[0] != 7 {
		t.Fatalf("kills = %v, want [7]", h.kills)
	}
	if !hasMarker(h, "gosh: interrupt pid=7 exit=137") {
		t.Fatalf("interrupt marker missing: %v", h.markers)
	}
	if !strings.Contains(h.outString(), "^C") {
		t.Fatalf("no ^C echo: %q", h.outString())
	}
	if h.waitCalls != 0 {
		t.Fatalf("WaitExternal ran %d times; the interrupt path must not take it", h.waitCalls)
	}
	// The exit still notifies the host — but flagged killed, so a
	// shell-armed exit never becomes a crash receipt.
	if len(h.exitedPids) != 1 || h.exitedPids[0] != 7 || !h.exitedKilled[0] {
		t.Fatalf("exit notification = %v/%v, want pid 7 killed", h.exitedPids, h.exitedKilled)
	}
}

// Type-ahead: bytes before AND after 0x03 are kept in order; the interrupt
// byte itself is consumed.
func TestTTYPollTypeAheadPreservesOrder(t *testing.T) {
	var in = []byte{'a', 'b', 0x03, 'c', 'd'}
	p := &TTYPoll{Read: func(b []byte) int {
		if len(in) == 0 {
			return 0
		}
		n := copy(b, in)
		in = in[n:]
		return n
	}}
	if !p.Interrupted() {
		t.Fatal("0x03 not reported")
	}
	if got := string(p.TypeAhead()); got != "abcd" {
		t.Fatalf("type-ahead = %q, want abcd", got)
	}
	if got := p.TypeAhead(); got != nil {
		t.Fatalf("stash not drained: %q", got)
	}
	if p.Interrupted() {
		t.Fatal("interrupt re-reported with an empty stream")
	}
}

// No deadline: a child still running after what would be 200 s of ticks is
// still awaited — the 120 s WaitBudget ceiling does not apply on the
// interruptible path.
func TestForegroundWaitHasNoDeadline(t *testing.T) {
	h := newFakeHost()
	h.intr = true
	h.probeAfter = 25000 // ~250 s of 10 ms ticks before the exit row
	h.released = 9
	run, _ := session(h)
	if st := run("LONG.BIN"); st != 9 {
		t.Fatalf("status = %d, want 9", st)
	}
	if len(h.ticks) < 25000 {
		t.Fatalf("wait ended after %d ticks, want >= 25000", len(h.ticks))
	}
}

// The arm is not a promise: a child still running 2 s after the arm is
// reported and the shell moves on with 130.
func TestForegroundCtrlCKillConfirmBound(t *testing.T) {
	h := newFakeHost()
	h.intr = true
	h.ttyIn = []byte{0x03}
	// probeAfter -1: the exit row never appears.
	run, _ := session(h)
	if st := run("STUCK.BIN"); st != 130 {
		t.Fatalf("status = %d, want 130", st)
	}
	if !strings.Contains(h.outString(), "gosh: STUCK.BIN: kill armed, child still running") {
		t.Fatalf("bound message missing: %q", h.outString())
	}
	if len(h.kills) != 1 {
		t.Fatalf("kills = %v, want one arm", h.kills)
	}
}

// A foreground child that exits normally on the interruptible path just
// returns its status — no marker, no kill.
func TestForegroundNormalExitOnInterruptiblePath(t *testing.T) {
	h := newFakeHost()
	h.intr = true
	h.probeAfter = 2
	h.released = 0
	run, _ := session(h)
	if st := run("OK.BIN"); st != 0 {
		t.Fatalf("status = %d, want 0", st)
	}
	if len(h.kills) != 0 || len(h.markers) != 0 {
		t.Fatalf("clean exit produced noise: kills=%v markers=%v", h.kills, h.markers)
	}
	if h.waitCalls != 0 {
		t.Fatal("WaitExternal used on the interruptible path")
	}
	// Not-killed exits still reach the host's receipt path (killed=false).
	if len(h.exitedPids) != 1 || h.exitedKilled[0] {
		t.Fatalf("clean exit misflagged: %v/%v", h.exitedPids, h.exitedKilled)
	}
}

// Ctrl-C during fg kills the job the shell was waiting on: the job's own
// reap marker still fires, the table drops it, and the answer is 130.
func TestFgCtrlC(t *testing.T) {
	h := newFakeHost()
	h.intr = true
	h.probeAfter = 2 // inside the post-arm confirm window
	h.released = 137
	run, _ := session(h)
	run("SLOW.BIN &")
	h.ttyIn = []byte{0x03}
	if st := run("fg 1"); st != 130 {
		t.Fatalf("status = %d, want 130", st)
	}
	if len(h.kills) != 1 || h.kills[0] != 7 {
		t.Fatalf("kills = %v, want [7]", h.kills)
	}
	if !hasMarker(h, "gosh: job 1 done exit=137") {
		t.Fatalf("job reap marker missing: %v", h.markers)
	}
	if !strings.Contains(h.outString(), "[1] Interrupted: SLOW.BIN") {
		t.Fatalf("Interrupted line missing: %q", h.outString())
	}
	if st := run("jobs"); st != 0 || strings.Contains(h.outString(), "running: SLOW.BIN") {
		t.Fatal("interrupted job still in the table")
	}
}

// Ctrl-C during sleep ends it with 130 without ever calling the blocking
// SleepSeconds; a clean sleep on the interruptible path still ticks.
func TestSleepCtrlC(t *testing.T) {
	h := newFakeHost()
	h.intr = true
	h.ttyIn = []byte{0x03}
	run, _ := session(h)
	if st := run("sleep 30"); st != 130 {
		t.Fatalf("status = %d, want 130", st)
	}
	if len(h.sleeps) != 0 {
		t.Fatalf("SleepSeconds ran %v on the interruptible path", h.sleeps)
	}
	if !strings.Contains(h.outString(), "^C") {
		t.Fatalf("no ^C echo: %q", h.outString())
	}
	h.ttyIn = nil
	if st := run("sleep 1"); st != 0 {
		t.Fatalf("clean sleep status = %d, want 0", st)
	}
	if len(h.sleeps) != 0 {
		t.Fatal("interactive sleep used blocking SleepSeconds")
	}
}

// Ctrl-C during read leaves VAR unset; typed bytes (not 0x03) still form
// the line.
func TestReadCtrlCAndTypeAheadLine(t *testing.T) {
	h := newFakeHost()
	h.intr = true
	run, _ := session(h)
	h.ttyIn = []byte("typed-value\r")
	if st := run("read V"); st != 0 {
		t.Fatalf("read status = %d, want 0", st)
	}
	if st := run("printenv V"); st != 0 || !strings.Contains(h.outString(), "typed-value") {
		t.Fatalf("read did not set V: out=%q", h.outString())
	}
	h.ttyIn = []byte{0x03}
	if st := run("read W"); st != 130 {
		t.Fatalf("interrupted read status = %d, want 130", st)
	}
	if st := run("printenv W"); st == 0 {
		t.Fatal("interrupted read still set W")
	}
}

// A host with no interrupter (headless -c, or a fake that does not offer
// it) keeps the blocking WaitExternal path — and blocking sleep/read.
func TestNoInterrupterKeepsWaitExternal(t *testing.T) {
	h := newFakeHost()
	h.released = 5
	run, _ := session(h)
	if st := run("APP.BIN"); st != 5 {
		t.Fatalf("status = %d, want 5", st)
	}
	if h.waitCalls != 1 {
		t.Fatalf("WaitExternal calls = %d, want 1", h.waitCalls)
	}
	run("sleep 2")
	if len(h.sleeps) != 1 || h.sleeps[0] != 2 {
		t.Fatalf("headless sleep did not use SleepSeconds: %v", h.sleeps)
	}
}

// kill %N and kill PID arm silently; the table row's own reap line reports
// the exit when it lands.
func TestKillBuiltinArms(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	run("COUNTER.BIN &")
	before := len(h.out)
	if st := run("kill %1"); st != 0 {
		t.Fatalf("kill %%1 status = %d, want 0", st)
	}
	if st := run("kill 42"); st != 0 {
		t.Fatalf("kill 42 status = %d, want 0", st)
	}
	if len(h.kills) != 2 || h.kills[0] != 7 || h.kills[1] != 42 {
		t.Fatalf("kills = %v, want [7 42]", h.kills)
	}
	if len(h.out) != before {
		t.Fatalf("a successful kill printed: %q", string(h.out[before:]))
	}
}

func TestKillBuiltinRefusals(t *testing.T) {
	h := newFakeHost()
	h.killErr = map[int64]string{1: "EACCES", 999: "EINVAL"}
	run, _ := session(h)
	if st := run("kill %9"); st != 1 || !strings.Contains(h.outString(), "gosh: kill: %9: no such job") {
		t.Fatalf("kill %%9: st=%d out=%q", st, h.outString())
	}
	if st := run("kill 999"); st != 1 || !strings.Contains(h.outString(), "gosh: kill: 999: no such process") {
		t.Fatalf("kill 999: st=%d out=%q", st, h.outString())
	}
	if st := run("kill 1"); st != 1 || !strings.Contains(h.outString(), "gosh: kill: 1: EACCES") {
		t.Fatalf("kill 1: st=%d out=%q", st, h.outString())
	}
	if st := run("kill"); st != 2 {
		t.Fatalf("bare kill status = %d, want 2", st)
	}
	if st := run("kill abc"); st != 1 || !strings.Contains(h.outString(), "gosh: kill: abc: no such process") {
		t.Fatalf("kill abc: st=%d out=%q", st, h.outString())
	}
}

// jobs -l adds the pid; plain jobs stays on the pinned format.
func TestJobsLongListsPids(t *testing.T) {
	h := newFakeHost()
	h.probeAfter = -1 // jobs stay running
	run, _ := session(h)
	run("COUNTER.BIN &")
	h.out = nil
	if st := run("jobs -l"); st != 0 || !strings.Contains(h.outString(), "[1] 7 running: COUNTER.BIN") {
		t.Fatalf("jobs -l: st=%d out=%q", st, h.outString())
	}
	h.out = nil
	if st := run("jobs"); st != 0 || !strings.Contains(h.outString(), "[1] running: COUNTER.BIN") ||
		strings.Contains(h.outString(), "[1] 7 running") {
		t.Fatalf("plain jobs changed: st=%d out=%q", st, h.outString())
	}
	if st := run("jobs bogus"); st != 2 {
		t.Fatalf("jobs bogus status = %d, want 2", st)
	}
}
