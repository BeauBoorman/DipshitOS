//go:build virelai

package main

import (
	"errors"
	"unsafe"

	"virelai/vi"
)

// The guest half of the execAndWait seam: spawn image with args and bind the
// child's fd-1 stream to a freshly-truncated capture file (B1,
// kernel/src/file_table.zig StreamRequest + syscall.zig's exec_stream_flag),
// then wait with the step ceiling.
//
// Why this and not vi.Exec: slot 28's plain form carries argv only. The
// stream request — bit 63 in argc plus a request pointer — is what lets the
// parent see a Go child's stderr: the os overlay folds fd 2 writes onto the
// fd-1 stream (overlay/syscall/fs_virelai.go), so binding that stream to a
// file captures the compiler's diagnostics AND its panic text in one place.
// No kernel change, no overlay change, no envp dependence — this answers
// the card's diagnostics question with machinery the kernel already has.
//
// The request's file source MOVES out of the parent's handle table on a
// successful spawn (file_table.commit_streams), so the handle is opened
// fresh per child and never closed by us afterward; on a refused spawn the
// plan is cancelled and the handle is still ours to close.

type streamRequest struct {
	version  uint32
	reserved uint32
	sources  [3]uint64 // stdin, stdout, stderr — values below
}

const (
	streamInherit = ^uint64(0)
	streamClosed  = streamInherit - 1
	streamConsole = streamInherit - 2

	slotExec        = 28               // ADR 0007 slot 28, mirrors vi.SlotExec
	execStreamFlag  = uintptr(1) << 63 // kernel/src/syscall.zig
	streamRequestSz = 32               // @sizeOf(kernel StreamRequest)
)

// execsvc6 is the raw six-argument SVC — bound to vi's own unexported
// gateway by linkname. M112a made the switch from a private .s copy: a
// local svc trampoline is the one thing the in-guest toolchain cannot
// rebuild (there is no cmd/asm on GOOS=virelai), and GOBUILD is itself a
// fleet member that must build in-guest. The linkname reference pulls
// virelai/vi.syscall6 out of the staged GPKG archive — same instruction
// sequence, no second gateway.
//
//go:linkname execsvc6 virelai/vi.syscall6
func execsvc6(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64

func strPtr(s string) uintptr {
	return uintptr(unsafe.Pointer(unsafe.StringData(s)))
}

// execAndWaitGuest is the seam's real implementation. capturePath is the
// step's diag stem: its `~` publish-temp is opened truncate-on-write before
// the spawn (the sacrificial name the publish guard recognises at the open
// site), and after the wait its bytes come back to the caller for diag
// parsing. The caller removes the temp after this returns.
func execAndWaitGuest(image string, args []string, capturePath string) (status int64, ms int64, captured []byte, err error) {
	if len(args) > maxExecArgs {
		return -1, 0, nil, errors.New("argv exceeds kernel 8-arg bound")
	}
	// Open the capture file first: the handle index is what the stream
	// request binds as the child's fd-1 source. MODE_WRITE is required —
	// prepare_streams refuses a source opened read-only.
	h, rc := vi.FileOpen(capturePath+"~", vi.ModeWrite|vi.ModeCreate)
	if rc < 0 {
		return -1, 0, nil, errors.New("capture open failed rc=" + itoa64(rc))
	}
	var block [maxExecArgs * (maxArgBytes + 1)]byte
	for i, a := range args {
		if len(a) > maxArgBytes {
			vi.FileClose(uint32(h))
			return -1, 0, nil, errors.New("arg exceeds 255-byte slot")
		}
		copy(block[i*(maxArgBytes+1):], a)
	}
	var argvPtr uintptr
	if len(args) > 0 {
		argvPtr = uintptr(unsafe.Pointer(&block[0]))
	}
	req := streamRequest{
		version: 1,
		sources: [3]uint64{streamInherit, uint64(h), streamInherit},
	}
	start := vi.Nanos()
	// The scheduler pool is small (max_tasks=16) and zombies are reclaimed
	// one per idle pass — a refused spawn (ENOSPC pool/registry full) is
	// often transient. Pace + retry bounded: sleep, rescan, try again for
	// up to ~30s of wall clock before reporting the refusal.
	var pid int64
	for attempt := 0; ; attempt++ {
		pid = execsvc6(slotExec, strPtr(image), uintptr(len(image)), argvPtr,
			uintptr(len(args))|execStreamFlag,
			uintptr(unsafe.Pointer(&req)), streamRequestSz)
		if pid >= 0 {
			break
		}
		if attempt >= 30 {
			vi.FileClose(uint32(h))
			return -1, 0, nil, errors.New("exec " + image + " rc=" + itoa64(pid))
		}
		vi.Sleep(1) // one tick (~1s) between retries, gives the idle reaper air
	}
	// h moved into the child's stream table — never close it here.
	status, werr := waitChild(pid, stepBudgetNs)
	ms = (vi.Nanos() - start) / 1000000
	captured, _ = readFile(capturePath + "~")
	if werr != nil {
		return -1, ms, captured, werr
	}
	return status, ms, captured, nil
}

// smokeBudgetNs bounds one fleet smoke exec: an app that self-exits returns
// its status; an event-loop app still running at the budget is killed
// (status 137 on its next ring selection) and counts "ran" — the loader +
// runtime-start proof the card calls the smoke marker, not a feature test.
const smokeBudgetNs = int64(8) * int64(1e9)

// execSmokeGuest execs the named product once from the share root and
// reports a one-token verdict: "exited=<status>", "ran:killed",
// "spawn=<err>", or "gone" (the pid vanished before it was ever seen — the
// kernel loaded it but the registry never showed it running).
func execSmokeGuest(name string) string {
	pid, err := vi.Exec(name, name)
	if err != nil {
		return "spawn=" + err.Error()
	}
	st, werr := waitChild(pid, smokeBudgetNs)
	if werr == nil {
		return "exited=" + itoa64(st)
	}
	if rc := vi.Kill(uint64(pid)); rc == 0 {
		_, _ = waitChild(pid, int64(2)*int64(1e9))
		return "ran:killed"
	}
	return "gone"
}

// waitChild waits on a spawned pid. pid 0 is a REAL registry slot
// (kernel/src/process.zig create_as recycles the lowest exited descriptor),
// but vi.Probe/vi.WaitBudget treat pid <= 0 as absent and EINVAL
// (user/go/vi/proc.go). The fleet driver cannot leave that to chance: once
// the 16-slot registry saturates, slot 0 is the recycled one and every
// spawn would read as a wait-EINVAL while its child still runs. So the wait
// polls the process table directly for pid 0 — identical semantics to
// WaitBudget: exited → status, vanished-after-seen → 0.
func waitChild(pid int64, budgetNs int64) (int64, error) {
	if pid > 0 {
		return vi.WaitBudget(pid, budgetNs)
	}
	deadline := vi.Nanos() + budgetNs
	seen := false
	var rows [16]vi.ProcRow
	for vi.Nanos() < deadline {
		n, rc := vi.Procs(rows[:])
		if rc >= 0 {
			live := false
			for i := 0; i < n; i++ {
				if int64(rows[i].PID) == 0 {
					if rows[i].State == vi.ProcExited {
						return int64(rows[i].ExitStatus), nil
					}
					live = true
					break
				}
			}
			if live {
				seen = true
			} else if seen {
				return 0, nil
			}
		}
		vi.Sleep(1)
	}
	return -1, vi.ErrWaitGone
}

func itoa64(v int64) string {
	if v < 0 {
		return "-" + itoa64(-v)
	}
	var buf [20]byte
	i := len(buf)
	for {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
		if v == 0 {
			return string(buf[i:])
		}
	}
}
