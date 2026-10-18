package vi

import (
	"errors"
	"testing"
	"time"
	"unsafe"
)

// installHook swaps in fn for the duration of the test and restores the
// previous gateway on cleanup (the ipc_test.go pattern).
func installHook(t *testing.T, fn func(num uintptr, a0, a1, a2, a3 uintptr) int64) {
	t.Helper()
	prev := SetSyscallHookForTest(fn)
	t.Cleanup(func() { SetSyscallHookForTest(prev) })
}

// shrinkBudget bounds Wait's polling for the duration of one test.
func shrinkBudget(t *testing.T, ns int64) {
	t.Helper()
	prev := waitBudgetNs
	waitBudgetNs = ns
	t.Cleanup(func() { waitBudgetNs = prev })
}

// emitProcRow writes one 40-byte sys_procs row (u64 pid, u64 state, u64
// exit_status, 16-byte name) into the caller's buffer at row i, using the
// little-endian putU64 helper from ipc.go.
func emitProcRow(buf []byte, i int, pid, state, exit uint64) {
	off := i * ProcRowSize
	putU64(buf[off:], pid)
	putU64(buf[off+8:], state)
	putU64(buf[off+16:], exit)
}

// fakeProcs builds a slot-7 hook over a mutable row table.
func fakeProcs(t *testing.T, rows *[]ProcRow) func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
	return func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotProcs {
			t.Fatalf("unexpected slot %d", num)
		}
		buf := unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1)
		n := 0
		for _, r := range *rows {
			emitProcRow(buf, n, r.PID, r.State, r.ExitStatus)
			n++
		}
		return int64(n)
	}
}

// TestWaitExitedStatus pins the primary path: the registry row reports
// ProcExited and its recorded (main-task) status comes back.
func TestWaitExitedStatus(t *testing.T) {
	rows := []ProcRow{{PID: 9, State: ProcRunning}, {PID: 42, State: ProcExited, ExitStatus: 43}}
	installHook(t, fakeProcs(t, &rows))
	st, err := Wait(42)
	if err != nil || st != 43 {
		t.Fatalf("Wait(42) = (%d, %v), want (43, nil)", st, err)
	}
}

// TestWaitRunningThenGone pins the go-git contract: a pid that was seen
// running and then leaves the registry counts as status 0.
func TestWaitRunningThenGone(t *testing.T) {
	shrinkBudget(t, int64(2)*int64(1e9))
	rowsp := []ProcRow{{PID: 7, State: ProcRunning}}
	calls := 0
	hook := fakeProcs(t, &rowsp)
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotYield {
			return 0
		}
		calls++
		if calls > 3 {
			rowsp = nil // reaped and recycled
		}
		return hook(num, a0, a1, a2, a3)
	})
	st, err := Wait(7)
	if err != nil || st != 0 {
		t.Fatalf("Wait(7) = (%d, %v), want (0, nil)", st, err)
	}
}

// TestWaitNeverSeen pins the bounded budget: a pid that never appears is
// ErrWaitGone, not an unbounded block.
func TestWaitNeverSeen(t *testing.T) {
	shrinkBudget(t, int64(5)*int64(1e6))
	rowsp := []ProcRow{}
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotYield {
			return 0
		}
		return fakeProcs(t, &rowsp)(num, a0, a1, a2, a3)
	})
	if _, err := Wait(3); !errors.Is(err, ErrWaitGone) {
		t.Fatalf("Wait(3) err = %v, want ErrWaitGone", err)
	}
}

// M70c-S2 (#1544): the in-guest build-loop driver needs a longer ceiling than
// a shell's foreground child, and that must not become a second copy of the
// wait rule. This pins that WaitBudget honours ITS argument while Wait keeps
// reading the package budget -- if the parameter were ignored (or read the
// global), both waits below would burn the same deadline and the second one
// would come back with a status instead of ErrWaitGone.
func TestWaitBudgetUsesItsArgument(t *testing.T) {
	shrinkBudget(t, int64(2)*int64(1e9)) // package budget: generous
	rowsp := []ProcRow{{PID: 5, State: ProcExited, ExitStatus: 9}}
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotYield {
			return 0
		}
		return fakeProcs(t, &rowsp)(num, a0, a1, a2, a3)
	})
	// The explicit ceiling is what decides: a never-seen pid with a 5 ms budget
	// fails while the package budget still stands at 2 s.
	if _, err := WaitBudget(3, int64(5)*int64(1e6)); !errors.Is(err, ErrWaitGone) {
		t.Fatalf("WaitBudget(3, 5ms) err = %v, want ErrWaitGone", err)
	}
	// ...and the same call with the package's own budget still sees the row, so
	// the 5 ms above was the argument and not a broken probe hook.
	st, err := WaitBudget(5, int64(2)*int64(1e9))
	if err != nil || st != 9 {
		t.Fatalf("WaitBudget(5, 2s) = (%d, %v), want (9, nil)", st, err)
	}
	if waitBudgetNs != int64(2)*int64(1e9) {
		t.Fatalf("WaitBudget wrote the package budget: %d", waitBudgetNs)
	}
}

// TestWaitKernelErrorKeepsPolling pins that a transient kernel error from
// the registry read does not end the wait.
func TestWaitKernelErrorKeepsPolling(t *testing.T) {
	shrinkBudget(t, int64(2)*int64(1e9))
	rowsp := []ProcRow{{PID: 5, State: ProcExited, ExitStatus: 9}}
	calls := 0
	hook := fakeProcs(t, &rowsp)
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotYield {
			return 0
		}
		calls++
		if calls <= 2 {
			return -ErrENOSYS // degrade like a host build, then recover
		}
		return hook(num, a0, a1, a2, a3)
	})
	st, err := Wait(5)
	if err != nil || st != 9 {
		t.Fatalf("Wait(5) = (%d, %v), want (9, nil)", st, err)
	}
}

// TestWaitArgumentGuard pins the pid guard and the budget constant's
// sanity (the deadline must cover the M49-bar foreground waits).
//
// M119d (#2488): pid 0 is a VALID pid — the process registry recycles its
// lowest free descriptor (kernel/src/process.zig pins "COUNTER reuses pid
// 0"), so Wait(0) is a real wait that goes ErrWaitGone on an empty table,
// not EINVAL. Only a negative pid is refused.
func TestWaitArgumentGuard(t *testing.T) {
	if waitBudgetNs < int64(60)*int64(1e9) {
		t.Fatalf("wait budget %d ns is too tight for shell waits", waitBudgetNs)
	}
	shrinkBudget(t, int64(30)*int64(1e6))
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return 0 })
	if _, err := Wait(0); !errors.Is(err, ErrWaitGone) {
		t.Fatalf("Wait(0) err = %v, want ErrWaitGone (pid 0 is a real slot)", err)
	}
	if _, err := Wait(-1); !errors.Is(err, errno(ErrEINVAL)) {
		t.Fatalf("Wait(-1) err = %v, want EINVAL", err)
	}
}

// TestWaitDeadlineIsWallClock pins that the budget rides Nanos (the guest
// monotonic clock), not an attempt count that a fast yield loop would burn.
func TestWaitDeadlineIsWallClock(t *testing.T) {
	shrinkBudget(t, int64(30)*int64(1e6)) // 30 ms
	rowsp := []ProcRow{}
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotYield {
			time.Sleep(time.Millisecond) // a yield costs real time on a host
			return 0
		}
		return fakeProcs(t, &rowsp)(num, a0, a1, a2, a3)
	})
	start := time.Now()
	if _, err := Wait(3); !errors.Is(err, ErrWaitGone) {
		t.Fatalf("Wait(3) err = %v, want ErrWaitGone", err)
	}
	if elapsed := time.Since(start); elapsed < 25*time.Millisecond {
		t.Fatalf("Wait returned after %v; the budget is not wall-clock", elapsed)
	}
}
