// Package vi is the VirelaiOS guest OS layer for Go programs: the typed
// wrapper over the ADR 0007 `svc #0` syscall seam that a userland app needs
// (console, window fills, events, the file channel, TCP). It links no libc
// and no POSIX; on a host build every call degrades to -ENOSYS so the app's
// logic remains unit-testable.
package vi

//go:generate go test -run ^TestSyscallSlotsMirrorKernel$ -args -update-syscall-slots

import (
	"bytes"
	"encoding/hex"
	"strconv"
	"strings"
	"unsafe"

	"virelai/vsys"
)

// syscallHook, when non-nil, replaces the raw SVC gateway. It is nil in a
// guest build's steady state (every call goes straight to the assembly) and
// exists so HOST tests can inject a fake kernel for the TCP path, the same
// way vsys.syscallFn is injected. Never set it in guest code.
var syscallHook func(num uintptr, a0, a1, a2, a3 uintptr) int64

// SetSyscallHookForTest installs fn as the syscall gateway (nil restores the
// raw one) and returns the previous hook. Host-test seam only.
func SetSyscallHookForTest(fn func(num uintptr, a0, a1, a2, a3 uintptr) int64) func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
	prev := syscallHook
	syscallHook = fn
	return prev
}

// SyscallHookForTest returns the current hook (nil = raw gateway).
func SyscallHookForTest() func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
	return syscallHook
}

func svc2(num uintptr, a0, a1 uintptr) int64 {
	if syscallHook != nil {
		return syscallHook(num, a0, a1, 0, 0)
	}
	return syscall2(num, a0, a1)
}

func svc0(num uintptr) int64 {
	if syscallHook != nil {
		return syscallHook(num, 0, 0, 0, 0)
	}
	return syscall0(num)
}

// svc1/svc3/svc4 are the file-ABI rows' gateways (M66a/M66b): the file
// surface routes through the hook too, so a host test can inject a fake
// kernel for the whole ADR 0010 surface, not just TCP.
func svc1(num uintptr, a0 uintptr) int64 {
	if syscallHook != nil {
		return syscallHook(num, a0, 0, 0, 0)
	}
	return syscall1(num, a0)
}

func svc3(num uintptr, a0, a1, a2 uintptr) int64 {
	if syscallHook != nil {
		return syscallHook(num, a0, a1, a2, 0)
	}
	return syscall3(num, a0, a1, a2)
}

func svc4(num uintptr, a0, a1, a2, a3 uintptr) int64 {
	if syscallHook != nil {
		return syscallHook(num, a0, a1, a2, a3)
	}
	return syscall4(num, a0, a1, a2, a3)
}

// ADR 0007 slot numbers (kernel/src/syscall.zig, mirrored by
// user/src/lib/ui/abi.zig). Adding a row here must match that table.
const (
	SlotWrite        uintptr = 1
	SlotYield        uintptr = 2
	SlotExit         uintptr = 3
	SlotSleep        uintptr = 4
	SlotIPCSend      uintptr = 5
	SlotIPCRecv      uintptr = 6
	SlotProcs        uintptr = 7
	SlotUDPListen    uintptr = 9 // M67a (#1446): the N6 UDP seam — DNS transport
	SlotUDPSend      uintptr = 10
	SlotUDPRecv      uintptr = 11
	SlotWinOpen      uintptr = 12
	SlotWinFill      uintptr = 13
	SlotWinPresent   uintptr = 14
	SlotWinClose     uintptr = 15
	SlotWinRaise     uintptr = 17
	SlotWinQuery     uintptr = 19
	SlotPollEvent    uintptr = 21
	SlotWaitEvent    uintptr = 22
	SlotFileOpen     uintptr = 23
	SlotFileRead     uintptr = 24
	SlotFileWrite    uintptr = 25
	SlotFileClose    uintptr = 26
	SlotDirList      uintptr = 27
	SlotExec         uintptr = 28
	SlotKill         uintptr = 29 // M71g: sys_kill, the EL0 process-termination seam
	SlotTCPConnect   uintptr = 30
	SlotTCPSend      uintptr = 31
	SlotTCPRecv      uintptr = 32
	SlotTCPClose     uintptr = 33
	SlotFileDelete   uintptr = 34
	SlotFileRename   uintptr = 35
	SlotFileTruncate uintptr = 36
	// M73j (#1636): sys_win_resize — the owner-side window resize; the
	// kernel clamps, reflows the grid and pushes WIN_RESIZE (kind 10).
	SlotWinResize    uintptr = 47
	SlotAudioInfo    uintptr = 42
	SlotAudioPlay    uintptr = 43
	SlotAudioVolume  uintptr = 44
	SlotAudioMute    uintptr = 45
	SlotWinFillBatch uintptr = 46
	SlotPingSend     uintptr = 59 // M71n: sys_ping_send(ip) — one ICMP echo request
	SlotPingPoll     uintptr = 60 // M71n: sys_ping_poll() — drain RX, report the last reply seq
	SlotNetStats     uintptr = 62 // M71g: the sys_net_stats snapshot (netstats.go)
	SlotPipeRead     uintptr = 56 // M19 P1: the kernel pipe read (M68a wrapper)
	SlotPipeWrite    uintptr = 57 // M19 P1: the kernel pipe write (M68a wrapper)
	SlotMmap         uintptr = 63
	SlotGetRandom    uintptr = 72 // M51 (ADR 0025 D5): sys_getrandom
	SlotTime         uintptr = 66
	SlotTtyAttach    uintptr = 67
	SlotPrincipal    uintptr = 68 // M50 TS1: the read-only identity report (trust.go)
	SlotFileMode     uintptr = 69 // M50 TS2: owner-only chmod (trust.go)
	SlotSecretGet    uintptr = 70 // M50 TS5: the caller's secret entries (trust.go)
	SlotTtyNetAuth   uintptr = 71 // M50 TS4: delegated net-auth (GOSH handshake)
	SlotSockReady    uintptr = 76
	SlotFileSync     uintptr = 77 // M66a (#1443): the ADR 0007 durability row
)

// sys_tty_attach front-end selectors (ADR 0020 slot 67).
const (
	TtyDetach uint64 = 0
	TtySerial uint64 = 1
	TtyWindow uint64 = 2
	TtyNet    uint64 = 3
)

// sys_tty_attach selector-3 auth schemes (ADR 0024 D6, a2 of slot 67).
const (
	NetSchemeOpen    uint64 = 0
	NetSchemeHMAC    uint64 = 1
	NetSchemeEd25519 uint64 = 2
)

// sys_tty_net_auth ops (ADR 0007 slot 71).
const (
	NetAuthOpChallenge uint64 = 0
	NetAuthOpResponse  uint64 = 1
	NetAuthOpVerdict   uint64 = 2
	NetChallengeLen           = 32
	NetAuthLineMax            = 160
)

// Kernel error codes (ADR 0007 D3): the MAGNITUDES of the kernel's
// `ErrorCode` enum (kernel/src/syscall.zig). A syscall returns the negation,
// so a full mailbox ring hands back -ErrENOSPC from slot 5. Ordering is the
// kernel's, not alphabetical; TestErrnoTable pins it.
const (
	ErrEINVAL       int64 = 1
	ErrEBADF        int64 = 2
	ErrEFAULT       int64 = 3
	ErrENOSYS       int64 = 4
	ErrENOSPC       int64 = 5
	ErrENOENT       int64 = 6
	ErrEACCES       int64 = 7
	ErrENAMETOOLONG int64 = 8
	ErrENXIO        int64 = 9
	ErrENOMEM       int64 = 10
	ErrEAGAIN       int64 = 11
	ErrETIMEDOUT    int64 = 12
	// ErrEIO (13) is declared in gpucompute.go — the M111b seam that
	// introduced the kernel's -13 row.
)

// File channel flags (ADR 0010).
const (
	ModeRead   uint32 = 0x0001
	ModeWrite  uint32 = 0x0002
	ModeCreate uint32 = 0x0004
	ModeAppend uint32 = 0x0008
	ModeDir    uint32 = 0x0010
)

// File-domain error rows (M66a #1443): what an ADR 0010 file call returns
// for the HF statuses a /host path can hit, per the kernel's hf_open_errno
// (kernel/src/file_table.zig). The four rows are DISTINCT so a caller can
// branch on what actually happened: not-found → ENOENT, is-dir → EINVAL (a
// directory is not a writable file), exists → -9 (the file-domain EEXIST
// row the MODE_DIR mkdir path pinned since M25 — the errno table above
// names this magnitude ENXIO in the device domains), handle-full → ENOSPC
// (the caller's own 8-handle table full, or the host's).
const (
	ErrFileNotFound   int64 = -ErrENOENT // HF status 1
	ErrFileIsDir      int64 = -ErrEINVAL // HF status 2
	ErrFileExists     int64 = -9         // HF status 5 (file-domain EEXIST)
	ErrFileHandleFull int64 = -ErrENOSPC // HF status 6 / guest table full
)

// fileWriteChunk mirrors the kernel's sys_file_write stage cap
// (handle_file_write refuses count > 2048 with -ENOSPC): FileWriteAll
// chunks at this size, so a large write is a run of honest syscalls that
// each advance by the CONFIRMED count, never one refused call.
const fileWriteChunk = 2048

// Event kinds (ADR 0009).
const (
	EvKeyDown   uint16 = 1
	EvKeyUp     uint16 = 2
	EvMouseDown uint16 = 3
	EvMouseUp   uint16 = 4
	EvMouseMove uint16 = 5
	EvWinFocus  uint16 = 6
	EvWinBlur   uint16 = 7
	EvWinClose  uint16 = 8
	EvTimer     uint16 = 9
	EvWinResize uint16 = 10
)

// Event modifier and button bits.
const (
	ModShift  uint16 = 0x0001
	ModCtrl   uint16 = 0x0002
	ModAlt    uint16 = 0x0004
	ModCmd    uint16 = 0x0008
	BtnLeft   uint16 = 0x0100
	BtnRight  uint16 = 0x0200
	BtnMiddle uint16 = 0x0400
)

// writeChunk keeps every console write inside the kernel's 256-byte cap.
const writeChunk = 200

// Event is the 16-byte application event wire format (ADR 0009). The field
// order and widths are the kernel's: u16 kind, u16 flags, u32 seq, u32 arg0,
// u32 arg1.
type Event struct {
	Kind  uint16
	Flags uint16
	Seq   uint32
	Arg0  uint32
	Arg1  uint32
}

// Rect is one fill rectangle for the batcher (24 bytes on the wire).
type Rect struct {
	X, Y, W, H uint32
	RGB        uint32
}

// Console writes s to the kernel console (bounded chunks, never panics).
func Console(s string) {
	for len(s) > 0 {
		n := len(s)
		if n > writeChunk {
			n = writeChunk
		}
		if len(s) > 0 {
			_ = syscall3(SlotWrite, 1, strPtr(s[:n]), uintptr(n))
		}
		s = s[n:]
	}
}

// ConsoleLine writes s followed by a newline IN ONE sys_write when the line
// fits in a chunk. Two writes would let a concurrent task's console output be
// spliced into the middle of the line — measured on VZ under the TABWM seat:
// GOTOP's `top: kill pid=1` came back as
// `top: kill pid=1smp: secondary runs=25 task=GOTOP.ELF`, which breaks every
// exact-match assertion and, worse, misreports the process being killed. Lines
// longer than one chunk keep the chunked path (a long line is not atomic
// either way).
func ConsoleLine(s string) {
	if len(s) < writeChunk {
		Console(s + "\n")
		return
	}
	Console(s)
	Console("\n")
}

// Yield is a cooperative scheduler point.
func Yield() { _ = syscall0(SlotYield) }

// Sleep blocks the calling task for ticks scheduler ticks.
func Sleep(ticks uint64) { _ = syscall1(SlotSleep, uintptr(ticks)) }

// SleepNs blocks the calling task for at least ns nanoseconds (slot 94 —
// card #3036's deadline-overlay seam). A pre-card-#3036 kernel answers
// ENOSYS and the call falls back to slot 4, rounding up to whole ticks.
// The raw kernel result is returned for callers that want EINVAL.
func SleepNs(ns uint64) int64 {
	r := syscall1(SlotSleepNs, uintptr(ns))
	if r == -ErrENOSYS {
		return syscall1(SlotSleep, uintptr((ns+999_999_999)/1_000_000_000))
	}
	return r
}

// Exit terminates the process with the given status. It routes through the
// svc1 hook seam so a HOST test can observe the status without leaving the
// Go runtime; the guest path is unchanged.
func Exit(status int) {
	_ = svc1(SlotExit, uintptr(status))
	// The kernel never returns here; keep looping so a stray return cannot
	// fall through into other code.
	for {
		Yield()
	}
}

// Now returns wall-clock Unix seconds, or -ENOSYS when EFI supplied no epoch.
// Unlike Nanos, this is a calendar clock, not a deadline source. Slot 66 has
// supplied it since #1058; M83a makes the distinction explicit to apps.
func Now() int64 { return Time() }

// Time is the original slot-66 wrapper, retained for existing callers.
func Time() int64 { return svc0(SlotTime) }

// Random fills p from the kernel CSPRNG (slot 72 sys_getrandom, ADR 0025 D5).
// The kernel clamps each call to 256 bytes and returns the count actually
// written; Random loops for the rest. Entropy is read-only and
// capability-free — it can only advance the stream, never weaken it. Host
// builds return -ENOSYS through the errno.
func Random(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	r := svc2(SlotGetRandom, bytePtr(p), uintptr(len(p)))
	if r < 0 {
		return 0, errno(-r)
	}
	return int(r), nil
}

// TtyAttach attaches or detaches the caller's controlling terminal (opened
// as /dev/tty) to a front-end (ADR 0020 slot 67). frontEnd is TtyDetach (0),
// TtySerial (1), TtyWindow (2; prefer TtyAttachWindow), or TtyNet (3).
// Host builds return -ENOSYS.
func TtyAttach(frontEnd uint64) int64 {
	return syscall1(SlotTtyAttach, uintptr(frontEnd))
}

// TtyAttachWindow attaches the caller's own .user window as the controlling
// terminal's window front-end (selector 2). The kernel paints the tty grid
// into that window; the caller draws no pixels. Host builds return -ENOSYS.
func TtyAttachWindow(windowID int) int64 {
	return syscall2(SlotTtyAttach, uintptr(TtyWindow), uintptr(windowID))
}

// TtyAttachNet attaches the net front-end (selector 3): LISTEN on port
// through the kernel's single bounded TCP seam, with the chosen auth
// scheme (0 open, 1 hmac-sha256, 2 ed25519) and an optional source-IP
// allowlist (big-endian IPv4 u32; 0 = any). The credential is NEVER an
// argument — the process reads it from the TS5 store and votes through
// TtyNetAuth (slot 71). Host builds return -ENOSYS.
func TtyAttachNet(port uint16, scheme uint64, allowIP uint32) int64 {
	return syscall6(SlotTtyAttach, uintptr(TtyNet), uintptr(port), uintptr(scheme), 0, uintptr(allowIP), 0)
}

// TtyNetAuth is one slot-71 step of the delegated challenge-response
// handshake. op 0 copies the fresh 32-byte challenge OUT (returns 32, or 0
// before it is minted); op 1 copies the buffered client reply line OUT
// (hex length, 0 when none); op 2 reads the one-byte verdict IN (0 reject,
// 1 accept). Host builds return -ENOSYS.
func TtyNetAuth(op uint64, buf []byte) int64 {
	var p uintptr
	if len(buf) > 0 {
		p = uintptr(unsafe.Pointer(&buf[0]))
	}
	return syscall3(SlotTtyNetAuth, uintptr(op), p, uintptr(len(buf)))
}

// WinOpen opens a user window and returns (id, rawResult). The id can be
// one the kernel just recycled: any WM_RPC session token the table still
// holds for it belongs to the dead window (the seat drops its half of the
// binding on the release mirror), so a fresh id always starts unbound.
func WinOpen(x, y, w, h uint32) (int, int64) {
	r := svc4(SlotWinOpen, uintptr(x), uintptr(y), uintptr(w), uintptr(h))
	if r < 0 {
		return -1, r
	}
	id := int(r)
	if fitsWire8(uint32(id)) {
		setWmToken(uint8(id), 0)
	}
	return id, r
}

// WinFill is a single (unbatched) fill — prefer Filler.
func WinFill(id int, x, y, w, h uint32, rgb uint32) int64 {
	return syscall6(SlotWinFill, uintptr(id), uintptr(x), uintptr(y), uintptr(w), uintptr(h), uintptr(rgb))
}

// WinPresent flushes the window's pending fills to the compositor.
func WinPresent(id int) int64 { return syscall1(SlotWinPresent, uintptr(id)) }

// WinResize resizes the CALLER'S window (sys_win_resize, slot 47). The
// kernel clamps to the resize bounds and on-scanout rule, reflows the
// presentation grid, and pushes WIN_RESIZE (arg0=w, arg1=h, the clamped
// values) to this pid — the seam M73j turns into tea.WindowSizeMsg.
func WinResize(id int, w, h uint32) int64 {
	return syscall3(SlotWinResize, uintptr(id), uintptr(w), uintptr(h))
}

// WinClose closes the caller's window. A successful close releases the
// window — its WM_RPC binding dies with it (the seat drops the token on
// the release mirror), so the table forgets it here too rather than
// letting a later reused id inherit a token the seat already forgot.
func WinClose(id int) int64 {
	r := svc1(SlotWinClose, uintptr(id))
	if r == 0 && id >= 0 && fitsWire8(uint32(id)) {
		setWmToken(uint8(id), 0)
	}
	return r
}

// WinSetVisible hides or shows the caller's window (sys_win_set_visible,
// slot 20 — the slots_gen row). A hidden window is inert to the compositor:
// agentd's kind-16 bind window uses it so the WM_RPC plumbing never paints.
func WinSetVisible(id int, visible bool) int64 {
	var v uintptr
	if visible {
		v = 1
	}
	return syscall2(SlotWinSetVisible, uintptr(id), v)
}

// WinRaise raises the caller's window without changing keyboard focus.
func WinRaise(id int) int64 { return svc1(SlotWinRaise, uintptr(id)) }

// WinQuery reads the full window state (x, y, w, h, z, focused, visible,
// dirty) — 32 bytes out through uaccess.
func WinQuery(id int) ([8]uint32, int64) {
	var out [8]uint32
	r := syscall2(SlotWinQuery, uintptr(id), uintptr(unsafe.Pointer(&out[0])))
	return out, r
}

// PollEvent returns the next queued event and true, or false when the queue
// is empty.
func PollEvent() (Event, bool) {
	var ev Event
	r := syscall1(SlotPollEvent, uintptr(unsafe.Pointer(&ev)))
	if r <= 0 {
		return Event{}, false
	}
	return ev, true
}

// PollEventRaw returns the raw syscall result alongside the decoded event, so
// a caller can distinguish an empty queue (0) from a kernel refusal (< 0).
func PollEventRaw() (Event, int64, bool) {
	var ev Event
	r := syscall1(SlotPollEvent, uintptr(unsafe.Pointer(&ev)))
	if r <= 0 {
		return Event{}, r, false
	}
	return ev, r, true
}

// WaitEvent blocks until an event arrives. Prefer PollEvent + Sleep in the
// browser's loop: sleeping keeps the cooperative scheduler honest.
func WaitEvent() (Event, int64) {
	var ev Event
	r := syscall1(SlotWaitEvent, uintptr(unsafe.Pointer(&ev)))
	return ev, r
}

// Filler batches fill rectangles and flushes them through slot 46 (one SVC
// per up-to-32 rects, 24 bytes each). Ordering is preserved across window id
// changes because the batch is keyed by id.
type Filler struct {
	buf   [FillBatchMax * FillRectSize]byte
	len   int
	curID int
}

// FillRectSize and FillBatchMax mirror the kernel's handler
// (kernel/src/syscall.zig handle_win_fill_batch).
const (
	FillRectSize = 24
	FillBatchMax = 32
)

// Rect queues one fill rectangle for window id.
func (f *Filler) Rect(id int, x, y, w, h uint32, rgb uint32) {
	if w == 0 || h == 0 {
		return
	}
	if f.len > 0 && f.curID != id {
		f.Flush()
	}
	if f.len+FillRectSize > len(f.buf) {
		f.Flush()
	}
	f.curID = id
	off := f.len
	f.buf[off] = byte(id & 0xff)
	f.buf[off+1] = 0
	f.buf[off+2] = 0
	f.buf[off+3] = 0
	putU32(f.buf[off+4:], x)
	putU32(f.buf[off+8:], y)
	putU32(f.buf[off+12:], w)
	putU32(f.buf[off+16:], h)
	putU32(f.buf[off+20:], rgb)
	f.len += FillRectSize
}

// Fill is Rect's argument order for a whole Rect value.
func (f *Filler) Fill(id int, r Rect) { f.Rect(id, r.X, r.Y, r.W, r.H, r.RGB) }

// Flush sends the pending rects and resets the batch. Returns the number of
// rects the kernel reported processing.
func (f *Filler) Flush() int {
	if f.len == 0 {
		return 0
	}
	n := f.len / FillRectSize
	f.curID = 0
	r := syscall2(SlotWinFillBatch, uintptr(unsafe.Pointer(&f.buf[0])), uintptr(f.len))
	f.len = 0
	if r < 0 {
		return 0
	}
	if int(r) < n {
		return int(r)
	}
	return n
}

// Reset drops any pending fills without sending them.
func (f *Filler) Reset() { f.len = 0; f.curID = 0 }

// Pending reports how many rects are queued.
func (f *Filler) Pending() int { return f.len / FillRectSize }

// FileOpen opens path with the given mode flags. Returns (handle, result).
func FileOpen(path string, flags uint32) (int64, int64) {
	if path == "" {
		return -1, -ErrEINVAL
	}
	r := svc3(SlotFileOpen, strPtr(path), uintptr(len(path)), uintptr(flags))
	return r, r
}

// FileRead reads into buf, returning (n, result).
func FileRead(h uint32, buf []byte) (int, int64) {
	if len(buf) == 0 {
		return 0, 0
	}
	r := svc3(SlotFileRead, uintptr(h), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if r < 0 {
		return 0, r
	}
	return int(r), r
}

// FileWrite writes buf, returning (n, result).
func FileWrite(h uint32, b []byte) (int, int64) {
	if len(b) == 0 {
		return 0, 0
	}
	r := svc3(SlotFileWrite, uintptr(h), uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)))
	if r < 0 {
		return 0, r
	}
	return int(r), r
}

// FileClose closes a handle.
func FileClose(h uint32) { _ = svc1(SlotFileClose, uintptr(h)) }

// FileWriteAll writes b through an OPEN handle, chunked to the kernel's
// 2048-byte stage cap and advancing ONLY by the confirmed count each call
// reports — a partial write can never corrupt the stream, because the next
// chunk resumes exactly where the kernel confirmed (M66a). Returns
// (bytes accepted, result): n == len(b) with r >= 0 on success, a short n
// after a mid-stream failure (the confirmed prefix is durable), or
// (0, r < 0) when the first chunk failed.
func FileWriteAll(h uint32, b []byte) (int, int64) {
	written := 0
	for written < len(b) {
		take := len(b) - written
		if take > fileWriteChunk {
			take = fileWriteChunk
		}
		n, r := FileWrite(h, b[written:written+take])
		if r < 0 {
			return written, r
		}
		if n <= 0 {
			// A zero-count acceptance cannot advance the stream; refuse
			// instead of spinning (the kernel never reports one for a
			// non-empty chunk, so this is a defensive stop).
			return written, -ErrEINVAL
		}
		written += n
	}
	return written, 0
}

// MaxFileBytes caps any file the browser will load (a page, not a download).
const MaxFileBytes = 256 * 1024

// ReadFileAll reads a whole file up to max bytes. A file longer than max is
// truncated (and the caller is told by the returned length). Errors are
// returned as a negative int64; the slice is nil on failure.
func ReadFileAll(path string, max int) ([]byte, int64) {
	if max <= 0 || max > MaxFileBytes {
		max = MaxFileBytes
	}
	h, r := FileOpen(path, ModeRead)
	if r < 0 {
		return nil, r
	}
	defer FileClose(uint32(h))
	out := make([]byte, 0, 8192)
	buf := make([]byte, 4096)
	for len(out) < max {
		n, rr := FileRead(uint32(h), buf)
		if rr < 0 {
			return out, rr
		}
		if n == 0 {
			break
		}
		take := n
		if len(out)+take > max {
			take = max - len(out)
		}
		out = append(out, buf[:take]...)
		if take < n {
			break
		}
	}
	return out, int64(len(out))
}

// FileExists reports whether a path can be opened for reading.
func FileExists(path string) bool {
	h, r := FileOpen(path, ModeRead)
	if r < 0 {
		return false
	}
	FileClose(uint32(h))
	return true
}

// FileAppend creates-or-appends and writes b (M66a: chunked through
// FileWriteAll, so rows longer than the kernel's 2048-byte write stage land
// whole). Returns false on any error.
func FileAppend(path string, b []byte) bool {
	h, r := FileOpen(path, ModeWrite|ModeCreate|ModeAppend)
	if r < 0 {
		return false
	}
	defer FileClose(uint32(h))
	n, wr := FileWriteAll(uint32(h), b)
	return wr >= 0 && n == len(b)
}

// FileTruncate resizes an open handle to size bytes (slot 36) — the
// compaction half of the ledger rewrite path.
func FileTruncate(h uint32, size uint32) int64 {
	return svc2(SlotFileTruncate, uintptr(h), uintptr(size))
}

// FileSync pushes the handle's host-side state to durability (slot 77, the
// M66a ADR 0007 amendment): the HF FSYNC op calls synchronize() on the
// host's live fd, so the bytes are on the device before the caller trusts
// them. Returns 0 on success; a closed or bad fd is -EBADF; stateless
// read handles are honest no-ops.
func FileSync(h uint32) int64 {
	return svc1(SlotFileSync, uintptr(h))
}

// FileRename renames oldPath to newPath (slot 35). The host publishes with
// a moveItem and REFUSES a live target (the file-domain EEXIST, -9), so a
// rename-over never silently replaces — WriteFileSafe sequences delete then
// rename instead (M66b).
func FileRename(oldPath, newPath string) int64 {
	if oldPath == "" || newPath == "" {
		return -ErrEINVAL
	}
	return svc4(SlotFileRename, strPtr(oldPath), uintptr(len(oldPath)),
		strPtr(newPath), uintptr(len(newPath)))
}

// WriteFileSafe replaces path with b crash-safe (M66b #1444): the body is
// written to a sacrificial temp beside the target, fsync'd through slot 77
// BEFORE close, and published — the live path is never truncated in place,
// so no failure or crash can leave a PARTIAL file behind. The HF rename is
// no-overwrite, so the publish is delete-then-rename: from the delete on,
// the honest failure mode for the target is ABSENT, which every reader
// treats as defaults (corrupt-fails-closed) — never garbage. The temp is
// the one file that may be truncated in place (it is the sacrificial
// copy), and an orphan temp from a crash between its close and the
// publish is simply replaced by the next safe write — nothing removes it
// at boot. Returns 0, or the negative kernel code of the step that failed;
// every failure removes the temp.
//
// Secret-class invariant (M97d F6, #2091): the temp is a DIFFERENT path
// key, so it always carries the kernel's default class policy — never the
// target's. The secret class (ADR 0024 D8) keys on the exact normalized
// path, so a secret-class save through this primitive would expose the
// plaintext at path~ to every EL0 reader during the publish window and as
// crash residue. No secret-class file is saved here today (the kernel's
// own SECRETS.TXT write is write_whole, no temp); a caller that needs one
// must not publish through WriteFileSafe until the kernel grows a
// class-query or class-preserving temp seam. gsport/vfs enforces the
// mirror rule on its reads: "<name>~" answers only while its target does.
func WriteFileSafe(path string, b []byte) int64 {
	if path == "" {
		return -ErrEINVAL
	}
	// The temp is a ONE-byte sibling, not "path.tmp": the kernel's file
	// table refuses any path longer than max_path_len (64, file_table.zig),
	// so a four-byte suffix made the safe publish IMPOSSIBLE for deep
	// paths — git's loose objects are "/host/G/.git/objects/ab/" + 38 hex
	// = 61 bytes, and 61 + 4 is one over the cap. A one-byte suffix leaves
	// that publish at 62. A path already AT the cap still cannot be
	// published; the caller gets the kernel's honest EINVAL.
	tmp := path + "~"
	h, r := FileOpen(tmp, ModeWrite|ModeCreate)
	if r < 0 {
		return r
	}
	if _, wr := FileWriteAll(uint32(h), b); wr < 0 {
		FileClose(uint32(h))
		_ = FileDelete(tmp)
		return wr
	}
	if rc := FileSync(uint32(h)); rc < 0 {
		FileClose(uint32(h))
		_ = FileDelete(tmp)
		return rc
	}
	FileClose(uint32(h))
	if rc := FileDelete(path); rc < 0 && rc != ErrFileNotFound {
		_ = FileDelete(tmp)
		return rc
	}
	if rc := FileRename(tmp, path); rc < 0 {
		_ = FileDelete(tmp)
		return rc
	}
	return 0
}

// WriteFilePublish is WriteFileSafe for a writer that can also APPEND — the
// one seam the shell host hooks go through (M81e2 #1787). It is the whole
// "which of these two contracts applies" decision, in one place, so no
// caller has to re-derive it and the recursion guard
// (vi/publish_guard_test.go) has exactly one policy site to point at.
//
// The split, and the reason for it:
//
//   - REPLACE (appendMode false) is a REWRITE: the caller holds the whole
//     new body in memory and the old file's bytes are meant to be gone. That
//     is app state — settings, an editor buffer, a saved history ring, a
//     `> file` redirect — so it goes through WriteFileSafe. A crash leaves
//     the old file or none, never a half-written one.
//   - APPEND (appendMode true) is NOT a rewrite: an append never truncates
//     a file it is not rewriting, so there is no partial-file hazard to fix.
//     WriteFileSafe cannot express it (it publishes a replacement), and
//     routing an append through it would rewrite the whole file per line.
//     It stays an in-place append, and the guard exempts it by RULE rather
//     than by name: an open carrying ModeAppend is by definition
//     non-truncating.
//
// Returns 0, or the negative kernel code of the step that failed. The
// append branch inlines FileAppend's open+write rather than calling it, so
// the caller gets the kernel's OWN code (a refused open is -ErrEACCES, not a
// generic "false"); FileAppend's bool is for callers that genuinely do not
// care which. This function, plus WriteFileSafe's `~` temp, are the only
// shipped in-place opens left in the Go tree.
func WriteFilePublish(path string, b []byte, appendMode bool) int64 {
	if !appendMode {
		return WriteFileSafe(path, b)
	}
	h, r := FileOpen(path, ModeWrite|ModeCreate|ModeAppend)
	if r < 0 {
		return r
	}
	defer FileClose(uint32(h))
	// A short write on an append is NOT silently fine: the caller is told
	// so it can say the line did not land. The bytes already written stay
	// written, which is the append contract (nothing was truncated).
	if n, wr := FileWriteAll(uint32(h), b); wr < 0 {
		return wr
	} else if n != len(b) {
		return -ErrENOSPC
	}
	return 0
}

// FileDelete removes a file by path (slot 34).
func FileDelete(path string) int64 {
	if path == "" {
		return -ErrEINVAL
	}
	return svc2(SlotFileDelete, strPtr(path), uintptr(len(path)))
}

// Shared M81a locations on the host share. Keep the path contract here so
// every app using trash/recent agrees on the same storage.
const (
	TrashDir                    = "/host/TRASH"
	RecentDir                   = "/host/RECENT"
	RecentLogPath               = RecentDir + "/LOG.TXT"
	TrashRetentionSeconds int64 = 30 * 24 * 60 * 60
	maxRecentBytes              = 8192
	maxRecentRows               = 64
	trashHeader                 = "VTRASH1\n"
)

// TrashItemPath returns the item path for a generated trash id. IDs are
// 8-byte CSPRNG values rendered as lowercase hex.
func TrashItemPath(id string) string {
	if !validTrashID(id) {
		return ""
	}
	return TrashDir + "/" + id + ".item"
}

// TrashMetaPath returns the companion receipt path for a trash id.
func TrashMetaPath(id string) string {
	if !validTrashID(id) {
		return ""
	}
	return TrashDir + "/" + id + ".meta"
}

func validTrashID(id string) bool {
	if len(id) != 16 {
		return false
	}
	for i := range id {
		c := id[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

func ensureFileDir(path string) int64 {
	h, rc := FileOpen(path, ModeWrite|ModeCreate|ModeDir)
	if rc == ErrFileExists {
		return 0
	}
	if rc < 0 {
		return rc
	}
	FileClose(uint32(h))
	return 0
}

func validShareFilePath(path string) bool {
	if !strings.HasPrefix(path, "/host/") || len(path) > 64 {
		return false
	}
	for _, part := range strings.Split(path[len("/host/"):], "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	for i := range path {
		if path[i] < 0x20 || path[i] == 0x7f {
			return false
		}
	}
	return true
}

func reservedStoragePath(path string) bool {
	return strings.HasPrefix(path, TrashDir+"/") ||
		strings.HasPrefix(path, RecentDir+"/")
}

func trashRecord(timestamp int64, path string) []byte {
	var b strings.Builder
	b.WriteString(trashHeader)
	b.WriteString(strconv.FormatInt(timestamp, 10))
	b.WriteByte('\n')
	b.WriteString(hex.EncodeToString([]byte(path)))
	b.WriteString("\n\n")
	return []byte(b.String())
}

// TrashRead loads and validates a trash item, returning its original path,
// exact bytes and deletion time. Malformed receipts fail closed.
func TrashRead(id string) (path string, body []byte, timestamp int64, rc int64) {
	item, meta := TrashItemPath(id), TrashMetaPath(id)
	if item == "" || meta == "" {
		return "", nil, 0, -ErrEINVAL
	}
	record, rr := ReadFileAll(meta, 512)
	if rr < 0 {
		return "", nil, 0, rr
	}
	if len(record) >= 512 {
		return "", nil, 0, -ErrENOSPC
	}
	if !bytes.HasPrefix(record, []byte(trashHeader)) {
		return "", nil, 0, -ErrEINVAL
	}
	rest := record[len(trashHeader):]
	cut := bytes.Index(rest, []byte("\n\n"))
	if cut < 0 {
		return "", nil, 0, -ErrEINVAL
	}
	rows := strings.SplitN(string(rest[:cut]), "\n", 2)
	if len(rows) != 2 {
		return "", nil, 0, -ErrEINVAL
	}
	stamp, err := strconv.ParseInt(rows[0], 10, 64)
	if err != nil {
		return "", nil, 0, -ErrEINVAL
	}
	pathBytes, err := hex.DecodeString(rows[1])
	original := string(pathBytes)
	if err != nil || !validShareFilePath(original) || reservedStoragePath(original) {
		return "", nil, 0, -ErrEINVAL
	}
	body, br := ReadFileAll(item, MaxFileBytes)
	if br < 0 {
		return "", nil, 0, br
	}
	if len(body) >= MaxFileBytes {
		return "", nil, 0, -ErrENOSPC
	}
	return original, body, stamp, int64(len(body))
}

// appendRecent adds one deterministic action row and atomically compacts the
// log to its newest bounded tail before publishing with WriteFileSafe.
func appendRecent(action, id, path string, timestamp int64) int64 {
	if !validTrashID(id) || (action != "delete" && action != "restore") || !validShareFilePath(path) {
		return -ErrEINVAL
	}
	if rc := ensureFileDir(RecentDir); rc < 0 {
		return rc
	}
	old, rc := ReadFileAll(RecentLogPath, maxRecentBytes)
	if rc < 0 && rc != ErrFileNotFound {
		return rc
	}
	rows := strings.Split(strings.TrimRight(string(old), "\n"), "\n")
	if len(rows) == 1 && rows[0] == "" {
		rows = nil
	}
	row := strconv.FormatInt(timestamp, 10) + "|" + action + "|" + id + "|" +
		hex.EncodeToString([]byte(path))
	rows = append(rows, row)
	contents := []byte(strings.Join(rows, "\n") + "\n")
	for len(rows) > 1 && (len(rows) > maxRecentRows || len(contents) > maxRecentBytes) {
		if len(rows) > maxRecentRows {
			rows = rows[1:]
		} else if len(contents) > maxRecentBytes {
			rows = rows[1:]
		}
		contents = []byte(strings.Join(rows, "\n") + "\n")
	}
	return WriteFileSafe(RecentLogPath, contents)
}

// TrashDelete safely moves a regular share file into /host/TRASH. It copies
// and verifies the complete bytes before unlinking the source; oversized or
// unreadable files remain untouched. On success it returns the receipt id.
func TrashDelete(path string) (string, int64) {
	if !validShareFilePath(path) || reservedStoragePath(path) {
		return "", -ErrEINVAL
	}
	if rc := ensureFileDir(TrashDir); rc < 0 {
		return "", rc
	}
	var entries [MaxDirEntries]DirEntry
	n, rc := DirList(TrashDir, entries[:])
	if rc < 0 {
		return "", rc
	}
	// Each complete item consumes a data file and a receipt file.
	if n > MaxDirEntries-2 {
		return "", -ErrENOSPC
	}
	body, rc := ReadFileAll(path, MaxFileBytes)
	if rc < 0 {
		return "", rc
	}
	// ReadFileAll intentionally caps at MaxFileBytes and cannot distinguish a
	// larger file from a file exactly at the cap. Refuse that boundary rather
	// than ever trashing a silent prefix.
	if len(body) >= MaxFileBytes {
		return "", -ErrENOSPC
	}
	var entropy [8]byte
	if n, err := Random(entropy[:]); err != nil || n != len(entropy) {
		if err != nil {
			return "", -ErrENOSYS
		}
		return "", -ErrEAGAIN
	}
	id := hex.EncodeToString(entropy[:])
	item := TrashItemPath(id)
	meta := TrashMetaPath(id)
	if FileExists(item) || FileExists(meta) {
		return "", -ErrEAGAIN
	}
	timestamp := Time()
	if rc := WriteFileSafe(item, body); rc < 0 {
		return "", rc
	}
	if rc := WriteFileSafe(meta, trashRecord(timestamp, path)); rc < 0 {
		_ = FileDelete(item)
		return "", rc
	}
	original, copied, gotTime, rr := TrashRead(id)
	if rr < 0 || original != path || gotTime != timestamp || !bytes.Equal(copied, body) {
		_ = FileDelete(item)
		_ = FileDelete(meta)
		if rr < 0 {
			return "", rr
		}
		return "", -ErrEINVAL
	}
	if rc := FileDelete(path); rc < 0 {
		_ = FileDelete(item)
		_ = FileDelete(meta)
		return "", rc
	}
	if rc := appendRecent("delete", id, path, timestamp); rc < 0 {
		if rollback := WriteFileSafe(path, body); rollback >= 0 {
			_ = FileDelete(item)
			_ = FileDelete(meta)
			return "", rc
		}
		// Keep the verified receipt if rollback failed. The caller gets the id
		// so the retained bytes are not silently orphaned.
		return id, rc
	}
	return id, 0
}

// TrashRestore restores the named trash item to its original path — the
// per-entry half of the picker's trash rows (M124b #2581), which select by
// id rather than taking the newest. Existing targets are never overwritten.
func TrashRestore(id string) (path string, rc int64) {
	if !validTrashID(id) {
		return "", -ErrEINVAL
	}
	return trashRestore(id)
}

// trashRestore is the shared restore sequence: validate the receipt, rename
// the item back to its recorded path, verify the landed bytes, append the
// restore row, and drop the receipt. Any mid-sequence failure rolls the
// rename back so a half-restored file never stands.
func trashRestore(id string) (path string, rc int64) {
	item := TrashItemPath(id)
	target, b, _, tr := TrashRead(id)
	if tr < 0 {
		return "", tr
	}
	if wr := FileRename(item, target); wr < 0 {
		return "", wr
	}
	got, gr := ReadFileAll(target, MaxFileBytes)
	if gr < 0 || !bytes.Equal(got, b) {
		_ = FileRename(target, item)
		return "", -ErrEINVAL
	}
	if ar := appendRecent("restore", id, target, Time()); ar < 0 {
		_ = FileRename(target, item)
		return "", ar
	}
	if dr := FileDelete(TrashMetaPath(id)); dr < 0 {
		return "", dr
	}
	return target, 0
}

// TrashRestoreLatest restores the newest still-present delete receipt to its
// original path. Existing targets are never overwritten.
func TrashRestoreLatest() (path, id string, rc int64) {
	log, rr := ReadFileAll(RecentLogPath, maxRecentBytes)
	if rr < 0 {
		return "", "", rr
	}
	rows := strings.Split(strings.TrimRight(string(log), "\n"), "\n")
	for i := len(rows) - 1; i >= 0; i-- {
		fields := strings.Split(rows[i], "|")
		if len(fields) != 4 || fields[1] != "delete" || !validTrashID(fields[2]) {
			continue
		}
		target, tr := trashRestore(fields[2])
		if tr == ErrFileNotFound {
			continue
		}
		if tr < 0 {
			return "", "", tr
		}
		return target, fields[2], 0
	}
	return "", "", ErrFileNotFound
}

// TrashExpire removes items at least TrashRetentionSeconds old. The kernel's
// directory ABI returns at most 16 rows; TrashDelete enforces the same cap.
func TrashExpire(now int64) (int, int64) {
	if now < 0 {
		return 0, -ErrEINVAL
	}
	var entries [MaxDirEntries]DirEntry
	n, rc := DirList(TrashDir, entries[:])
	if rc == ErrFileNotFound {
		return 0, 0
	}
	if rc < 0 {
		return 0, rc
	}
	removed := 0
	for _, entry := range entries[:n] {
		name := entry.NameString()
		if entry.Dir() || !strings.HasSuffix(name, ".meta") {
			continue
		}
		id := strings.TrimSuffix(name, ".meta")
		_, _, timestamp, tr := TrashRead(id)
		if tr == ErrFileNotFound {
			if dr := FileDelete(TrashMetaPath(id)); dr < 0 {
				return removed, dr
			}
			removed++
			continue
		}
		if tr < 0 {
			return removed, tr
		}
		if timestamp < 0 || now < timestamp || now-timestamp < TrashRetentionSeconds {
			continue
		}
		if dr := FileDelete(TrashItemPath(id)); dr < 0 && dr != ErrFileNotFound {
			return removed, dr
		}
		if dr := FileDelete(TrashMetaPath(id)); dr < 0 {
			return removed, dr
		}
		removed++
	}
	return removed, 0
}

// ExecMaxArgs is the kernel's max_exec_args (kernel/src/exec.zig).
// ExecArgMax is the usable bytes of one slot (arg_slot_bytes - 1). A longer
// argument is refused; the kernel does not chop it.
const (
	ExecMaxArgs = 8
	ExecArgMax  = 255
	execSlot    = ExecArgMax + 1
)

// Exec loads name from the host share into a fresh process and returns its
// pid (ADR 0007 slot 28). args is the card-3e argv list (at most ExecMaxArgs
// strings, each at most ExecArgMax bytes); a missing list is argc=0.
func Exec(name string, args ...string) (int64, error) {
	if name == "" {
		return 0, errno(ErrEINVAL)
	}
	if len(args) > ExecMaxArgs {
		return 0, errno(ErrEINVAL)
	}
	var block [ExecMaxArgs * execSlot]byte
	for i, a := range args {
		if len(a) > ExecArgMax {
			return 0, errno(ErrEINVAL)
		}
		copy(block[i*execSlot:], a)
	}
	var argvPtr uintptr
	if len(args) > 0 {
		argvPtr = uintptr(unsafe.Pointer(&block[0]))
	}
	r := syscall4(SlotExec, strPtr(name), uintptr(len(name)), argvPtr, uintptr(len(args)))
	if r < 0 {
		return 0, errno(-r)
	}
	return r, nil
}

// MaxDirEntries is the kernel's sys_dir_list window (handle_dir_list clamps
// max_entries to 16). A longer caller buffer is truncated to this.
const MaxDirEntries = 16

// DirEntry is the 40-byte sys_dir_list row (file_table.DirEntry): name[32]
// NUL-padded, size u32, is_dir u8, reserved[3].
type DirEntry struct {
	Name     [32]byte
	Size     uint32
	IsDir    uint8
	Reserved [3]byte
}

// NameString returns the NUL-trimmed directory entry name.
func (e DirEntry) NameString() string {
	n := 0
	for n < len(e.Name) && e.Name[n] != 0 {
		n++
	}
	return string(e.Name[:n])
}

// Dir reports whether the entry is a directory.
func (e DirEntry) Dir() bool { return e.IsDir != 0 }

// DirList enumerates path into buf (slot 27). Returns (count, result).
// An empty path lists the host-share root. count is 0 when the call fails.
func DirList(path string, buf []DirEntry) (int, int64) {
	if len(buf) == 0 {
		return 0, 0
	}
	if len(buf) > MaxDirEntries {
		buf = buf[:MaxDirEntries]
	}
	r := svc4(SlotDirList, strPtr(path), uintptr(len(path)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if r < 0 {
		return 0, r
	}
	return int(r), r
}

// TCPConnect opens the single TCP socket (VirelaiOS has one per process).
func TCPConnect(ip [4]byte, port uint16) int64 {
	word := uint32(ip[0])<<24 | uint32(ip[1])<<16 | uint32(ip[2])<<8 | uint32(ip[3])
	return svc2(SlotTCPConnect, uintptr(word), uintptr(port))
}

// TCPSend writes b to the socket (at most the kernel's 1460-byte payload_max
// per call; a caller with more must loop — see the browser's sendAll).
func TCPSend(b []byte) (int, int64) {
	if len(b) == 0 {
		return 0, 0
	}
	r := svc2(SlotTCPSend, uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)))
	if r < 0 {
		return 0, r
	}
	return int(r), r
}

// TCPRecv reads into buf. Returns (0, 0) when nothing is available yet.
func TCPRecv(buf []byte) (int, int64) {
	if len(buf) == 0 {
		return 0, 0
	}
	r := svc2(SlotTCPRecv, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if r < 0 {
		return 0, r
	}
	return int(r), r
}

// TCPClose closes the socket.
func TCPClose() int64 { return svc0(SlotTCPClose) }

// TCPReady probes the socket's readiness mask (slot 76, op 0): bit 0 =
// readable, bit 1 = writable, 0 = nothing yet. It is level-triggered and is
// the only way to tell a peer FIN from "no segment yet" — the kernel's recv
// returns 0 for both, and this kernel reports a received FIN as readable.
// A readable socket whose recv then drains 0 bytes is at EOF: the caller
// must fail closed (finish the response) instead of polling on.
func TCPReady() (mask int64, rc int64) {
	r := svc2(SlotSockReady, 0, 1)
	if r < 0 {
		return 0, r
	}
	return r, 0
}

// Map flags / protections accepted by sys_mmap (slot 63).
const (
	ProtRead     uint64 = 1
	ProtWrite    uint64 = 2
	MapPrivate   uint64 = 0x02
	MapAnonymous uint64 = 0x20
	MapPopulate  uint64 = 0x8000
	PageSize            = 4096
)

// errno is a tiny error type so callers can branch on the kernel's own codes
// without an errno translation layer (which this OS deliberately has none of).
type errno int64

func (e errno) Error() string {
	switch int64(e) {
	case ErrEINVAL:
		return "EINVAL"
	case ErrEBADF:
		return "EBADF"
	case ErrEFAULT:
		return "EFAULT"
	case ErrENOSYS:
		return "ENOSYS"
	case ErrENOSPC:
		return "ENOSPC"
	case ErrENOENT:
		return "ENOENT"
	case ErrEACCES:
		return "EACCES"
	case ErrENAMETOOLONG:
		return "ENAMETOOLONG"
	case ErrENXIO:
		return "ENXIO"
	case ErrENOMEM:
		return "ENOMEM"
	case ErrEAGAIN:
		return "EAGAIN"
	case ErrETIMEDOUT:
		return "ETIMEDOUT"
	case ErrEIO:
		return "EIO"
	}
	return "EIO"
}

func strPtr(s string) uintptr {
	if len(s) == 0 {
		return 0
	}
	return uintptr(unsafe.Pointer(unsafe.StringData(s)))
}

func putU32(b []byte, v uint32) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
	b[2] = byte(v >> 16)
	b[3] = byte(v >> 24)
}

// Itoa64 is the shared decimal formatter for the guest side (the stdlib
// strconv is not ported to this GOOS).
func Itoa64(v int64) string {
	return vsys.Itoa64(v)
}
