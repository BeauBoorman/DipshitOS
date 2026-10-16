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

// execsvc6 is the raw six-argument SVC — the same idiom vi's own gateway
// uses (user/go/vi/vi_arm64.s); a copy lives here because the vi package's
// is unexported and vi is outside this card's Touches.
func execsvc6(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64

func strPtr(s string) uintptr {
	return uintptr(unsafe.Pointer(unsafe.StringData(s)))
}

// execAndWaitGuest is the seam's real implementation. capturePath is opened
// truncate-on-write before the spawn; after the wait its bytes come back to
// the caller for diag parsing. The caller owns the name (the `~`
// publish-temp beside the diag stem) and removes it after this returns.
func execAndWaitGuest(image string, args []string, capturePath string) (status int64, ms int64, captured []byte, err error) {
	if len(args) > maxExecArgs {
		return -1, 0, nil, errors.New("argv exceeds kernel 8-arg bound")
	}
	// Open the capture file first: the handle index is what the stream
	// request binds as the child's fd-1 source. MODE_WRITE is required —
	// prepare_streams refuses a source opened read-only.
	h, rc := vi.FileOpen(capturePath, vi.ModeWrite|vi.ModeCreate)
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
	pid := execsvc6(slotExec, strPtr(image), uintptr(len(image)), argvPtr,
		uintptr(len(args))|execStreamFlag,
		uintptr(unsafe.Pointer(&req)), streamRequestSz)
	if pid < 0 {
		// Spawn refused: the stream plan was cancelled, h is still ours.
		vi.FileClose(uint32(h))
		return -1, 0, nil, errors.New("exec " + image + " rc=" + itoa64(pid))
	}
	// h moved into the child's stream table — never close it here.
	status, werr := vi.WaitBudget(pid, stepBudgetNs)
	ms = (vi.Nanos() - start) / 1000000
	captured, _ = readFile(capturePath)
	if werr != nil {
		return -1, ms, captured, werr
	}
	return status, ms, captured, nil
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
