// Process-lifecycle rows for the vi package: the blocking child wait GOSH
// uses for both foreground children and background-job reapers. On the host
// every call degrades to -ENOSYS; host tests inject a fake kernel through
// the hook.
//
// Deliberately NOT sys_wait (ADR 0007 slot 8): that wait returns the status
// of the LAST task to leave the process, and every GOOS=virelai process
// outlives its main task by the Go runtime's per-P background tasks — the
// kernel force-kills them with the reserved status 137 at process death
// (kernel/src/scheduler.zig reserved_kill_status), so a slot-8 waiter
// observes 137 where the program's own exit was 0/7. The go-git waitPID
// pattern reads the registry instead: a process row's ExitStatus is the
// main task's recorded status (observed: go-sh run 01 produced rc=137
// through slot 8 where `procs` recorded 0). Poll with yields, bounded.
package vi

import "errors"

// ErrWaitGone reports that the polling budget ran out without the target
// ever reaching a readable state (a pid that was never waitable).
var ErrWaitGone = errors.New("wait: target not waitable")

// waitBudgetNs bounds one Wait: generous enough for any foreground child a
// shell runs (the go-git helper budget is the same 120 s), overridable in
// host tests.
var waitBudgetNs = int64(120) * int64(1e9)

// Probe states for one registry scan.
const (
	ProbeAbsent  = 0 // pid not in the registry
	ProbeRunning = 1 // pid present, not yet exited
	ProbeExited  = 2 // pid present and exited (status is the recorded one)
)

// Probe scans the registry once for pid and reports (status, state). It is
// the non-blocking read behind job tables: a shell's main loop can reap
// background children between prompt reads without a waiter task. A pid
// that was seen running and then vanishes is the caller's recycled-pid
// case — Probe reports Absent and the caller applies the seen-then-gone
// status-0 rule with its own memory.
//
// pid 0 is a REAL registry slot: create_as (kernel/src/process.zig) hands
// out the lowest free descriptor, and once the registry has recycled, slot 0
// goes to live children — a sys_exec can legitimately return pid 0 (observed
// in the M119d spawn matrix, live-exec run 03: `spawned pid=0`). Only a
// negative pid is not a pid.
func Probe(pid int64) (int64, int) {
	if pid < 0 {
		return -1, ProbeAbsent
	}
	var rows [16]ProcRow
	n, rc := Procs(rows[:])
	if rc < 0 {
		return -1, ProbeRunning // transient read failure: keep waiting
	}
	for i := 0; i < n; i++ {
		if int64(rows[i].PID) != pid {
			continue
		}
		if rows[i].State == ProcExited {
			return int64(rows[i].ExitStatus), ProbeExited
		}
		return -1, ProbeRunning
	}
	return -1, ProbeAbsent
}

// Wait blocks the caller until process pid exits and returns its exit
// status, polling the registry between scheduler sleeps (one tick per
// poll — a foreground child reaps within a tick of exiting without
// spinning the CPU). A pid that is seen and then leaves the registry
// counts as status 0 (reaped and recycled — the same contract go-git's
// waitPID pins). A pid that never appears at all burns the budget into
// ErrWaitGone rather than blocking forever.
func Wait(pid int64) (int64, error) { return WaitBudget(pid, waitBudgetNs) }

// WaitBudget is Wait with a caller-chosen ceiling (M70c-S2, issue #1544). The
// in-guest build-loop driver (tools/go/selfhost.go) waits on a linker that
// reads ~15 MiB of package archives out of the share at the 2048-byte EL0 read
// cap — a workload no shell's foreground child has — and needing a longer
// ceiling must not cost a second copy of the rule below: "seen running, then
// gone => status 0" is a contract that is easy to get wrong twice, and a fix
// here would silently not reach the copy. Same poll spacing, same
// reaped-and-recycled rule, same ErrWaitGone for a pid that never appears;
// only the deadline moves.
func WaitBudget(pid int64, budgetNs int64) (int64, error) {
	if pid < 0 {
		return -1, errno(ErrEINVAL)
	}
	deadline := Nanos() + budgetNs
	seen := false
	for Nanos() < deadline {
		st, state := Probe(pid)
		switch state {
		case ProbeExited:
			return st, nil
		case ProbeRunning:
			seen = true
		case ProbeAbsent:
			if seen {
				return 0, nil
			}
		}
		Sleep(1)
	}
	return -1, ErrWaitGone
}
