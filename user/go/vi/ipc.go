package vi

// M56a (issue #1311): the IPC mailbox + process-table wire over ADR 0007
// slots 5/6 (`sys_ipc_send`/`sys_ipc_recv`) and slot 7 (`sys_procs`).
//
// The kernel is the single source of truth for every bound below
// (kernel/src/syscall.zig):
//   - mailbox.message_max = 64: a send longer than this is TRUNCATED to the
//     slot bound and a recv whose `max` exceeds it is CLAMPED. Both are
//     documented truncations, not errors.
//   - the ring holds max_messages = 8 slots per process; a full ring refuses
//     the send with ENOSPC BEFORE any bytes are copied, so a refusal never
//     touches user memory.
//   - a send to a target outside the registry, to a free slot, or to an
//     EXITED process is EINVAL (a mailbox is reachable only while live).
//   - a bad user pointer is EFAULT; on recv the message stays QUEUED.
//   - recv always reads the CALLER's own ring (the kernel resolves the pid
//     from the current task), so there is no self-pid argument on the wire.
//
// On the host every call degrades to -ENOSYS (vi_host.go) unless a test
// installs syscallHook — the same inject-a-fake-kernel seam the TCP path
// uses. That is what keeps these paths unit-testable off the guest.

import "unsafe"

const (
	// MailboxMessageMax is the per-message byte bound (mailbox.zig
	// `message_max`). Sends truncate to it; recvs clamp to it.
	MailboxMessageMax = 64
	// MailboxMaxMessages is the per-process ring depth (mailbox.zig
	// `max_messages`): the slot a full-ring ENOSPC guards.
	MailboxMaxMessages = 8
	// ProcRowSize is the fixed width of one `sys_procs` snapshot row
	// (process.zig `snapshot_row_bytes`).
	ProcRowSize = 40
	// ProcNameBytes is the NUL-padded name field width inside a row.
	ProcNameBytes = 16
	// ProcRowVersion2 is the wire row_version written by kernels that
	// implement ADR 0047's negotiated v2 snapshot.
	ProcRowVersion2 = 2
	// ProcRowBytesV2 is the stride of the version-2 wire row (ADR 0047).
	ProcRowBytesV2 = 80
)

// Process state codes as marshalled by the kernel snapshot (process.zig
// `State`): a `free` descriptor is never emitted.
const (
	ProcCreated uint64 = 1
	ProcRunning uint64 = 2
	ProcExited  uint64 = 3
)

// ProcRow is one decoded `sys_procs` row: u64 pid@0, u64 state@8, u64
// exit_status@16, name[16] NUL-padded@24 (all little-endian). The frozen
// wire shape ends at NameBuf; the fields after it are Go-side decode
// targets for the negotiated v2 row (procs.go, ADR 0047) — zero on a v1
// stream or over any truncated/unknown field range, never garbage.
type ProcRow struct {
	PID        uint64
	State      uint64
	ExitStatus uint64
	NameBuf    [ProcNameBytes]byte
	// RowVer is the wire row_version the snapshot carried (0/1 = v1).
	RowVer uint32
	// NCores is the online-core count at snapshot time (v2@72).
	NCores uint32
	// TotalPages is the allocator pool page count (v2@76); ×4096 = the
	// machine memory denominator in bytes.
	TotalPages uint64
	// CpuTicks is the cumulative scheduler ticks attributed to this pid
	// (v2@48). It is a counter, not a percentage — pair consecutive
	// snapshots' deltas against TotalTicks and NCores for a utilization.
	CpuTicks uint64
	// MemBytes is the owned resident footprint in bytes (v2@56): static
	// spans + dynamic pages + kernel stack.
	MemBytes uint64
	// TotalTicks is Σ per-core scheduler ticks (v2@64) — the CPU-share
	// denominator, identical on every row of one snapshot.
	TotalTicks uint64
}

// Name returns the row's process name with the NUL padding trimmed.
func (r ProcRow) Name() string {
	n := 0
	for n < len(r.NameBuf) && r.NameBuf[n] != 0 {
		n++
	}
	return string(r.NameBuf[:n])
}

// IpcSend copies up to MailboxMessageMax bytes of b into process `target`'s
// mailbox ring (slot 5). It returns the number of bytes sent (>0) or the raw
// negative kernel error: -EINVAL (target not a live process), -EFAULT (bad
// source pointer), -ENOSPC (ring full). A zero-length send is a no-op
// returning 0.
func IpcSend(target uint32, b []byte) int64 {
	if len(b) == 0 {
		return 0
	}
	if len(b) > MailboxMessageMax {
		b = b[:MailboxMessageMax]
	}
	return svc3(SlotIPCSend, uintptr(target), uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)))
}

// IpcRecv copies the caller's own oldest mailbox message into buf (slot 6),
// returning (n, raw). n == 0 with raw >= 0 means the queue was empty; a
// negative raw is a kernel error (-ENOSYS off-guest, -EFAULT when the
// destination pointer is bad — the kernel then leaves the message queued).
// len(buf) > MailboxMessageMax is clamped to the bound.
func IpcRecv(buf []byte) (int, int64) {
	if len(buf) == 0 {
		return 0, 0
	}
	if len(buf) > MailboxMessageMax {
		buf = buf[:MailboxMessageMax]
	}
	r := svc2(SlotIPCRecv, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if r < 0 {
		return 0, r
	}
	return int(r), r
}

// Procs reads up to len(dst) rows of the process table (slot 7). It returns
// the number of rows written and the raw result. `sys_procs` floors the
// request to whole rows and returns the ROW COUNT, not a byte count. Off the
// guest this is (0, -ENOSYS).
func Procs(dst []ProcRow) (int, int64) {
	if len(dst) == 0 {
		return 0, 0
	}
	buf := make([]byte, len(dst)*ProcRowSize)
	r := svc2(SlotProcs, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if r < 0 {
		return 0, r
	}
	rows := int(r)
	if rows > len(dst) {
		rows = len(dst)
	}
	for i := 0; i < rows; i++ {
		off := i * ProcRowSize
		dst[i] = ProcRow{
			PID:        getU64(buf[off:]),
			State:      getU64(buf[off+8:]),
			ExitStatus: getU64(buf[off+16:]),
		}
		copy(dst[i].NameBuf[:], buf[off+24:off+24+ProcNameBytes])
	}
	return rows, r
}

// SelfPid returns the caller's own process id from the kernel's task
// registry (slot 87, ADR 0048) — the only self-pid answer a same-named
// sibling cannot spoof. ok is false off-guest or on a kernel without the
// slot (-ENOSYS), where callers fall back to the sys_procs name scan.
func SelfPid() (uint32, bool) {
	r := svc0(SlotGetpid)
	if r <= 0 || r > 0xffffffff {
		return 0, false
	}
	return uint32(r), true
}

// WmSeat is a resolved WM seat: the registered WM process id and THIS
// process's own id, both found in one `sys_procs` scan (acks route by pid).
type WmSeat struct {
	WM   uint32
	Self uint32
	// Go is true when the resolved seat is the Go WM (GOTABWM.ELF): the seat
	// that speaks the M97g-F2 authenticated bind protocol, where requests
	// carry a session token and acks arrive Pad-marked. The Zig seats answer
	// bare applied acks and are served by the legacy path.
	Go bool
}

// wmGoSeatName is the seat process name that runs the authenticated WM_RPC
// protocol (M97g-F2 #2080).
const wmGoSeatName = "GOTABWM.ELF"

// WMProcNames are the historical seat names, kept for DISPLAY-side use
// (top marks which proc-table row is the WM). They are no longer the routing
// authority: since #2079 the seat id is the kernel's own register
// (WmctlSeatPid), which a forged process name cannot impersonate. The Go
// seat name is still matched — by PID on the seat row — to pick the
// authenticated protocol (M97g-F2 #2080).
var WMProcNames = [...]string{"WND.BIN", "TABWM.BIN", wmGoSeatName}

// wmPeersScanAttempts bounds the `sys_procs` re-reads (M56d #1315). It is
// kept at the historical 8, but only a persistently suspect scan can spend
// them now: an intact scan returns on the spot.
const wmPeersScanAttempts = 8

// WmPeers resolves the WM seat and this process's pid (the M56a
// `wm_peers` helper). A zero field means "not found".
//
// #2079 (M97g seat gate): the WM half is ONE unforgeable read — slot 65
// cmd 16 returns the kernel-registered pid, or -ENOENT when no seat is
// held. Before this, the seat was resolved by matching proc-table names
// (`WND.BIN`/`TABWM.BIN`/`GOTABWM.ELF`), so any rogue process that took a
// seat name captured every app's WM_RPC traffic; and on the guest a name
// match said nothing about which pid the kernel had actually armed.
//
// #2158 (ADR 0048): SELF is now also ONE unforgeable read — slot 87
// (sys_getpid) returns the caller's pid from the task registry. The name
// scan it replaces resolved the FIRST RUNNING row with the binary's name,
// so a second instance of any app (duplicate-tab chord, launcher re-exec)
// stamped the first instance's pid into reply_to and every ack — the Go
// seat's bind challenge included — misrouted to the first instance's
// mailbox. The name scan survives only where no kernel register answers
// (host tests, -ENOSYS): a RUNNING row whose name bytes read back zeroed
// may be this process's row, and a missing self keeps retrying exactly as
// before — that M56d flake discipline is unchanged.
//
// That distinction is not cosmetic. Between attempts the loop yields, and on
// VZ a yield parks the caller until the next scheduler tick, which is a full
// second (kernel/src/timer.zig `period_ns` = 1e9). The no-seat answer no
// longer depends on the scan at all (the kernel answers it), so the retry
// loop waits only while SELF is unresolved or a registered seat's row is
// still unreadable — its name picks the #2080 protocol, so a zeroed seat
// row counts as a suspect scan. On the host (every syscall
// -ENOSYS) the loop is a cheap no-op that still returns the zero seat.
func WmPeers(selfName string) WmSeat {
	var out WmSeat
	if selfName == "" {
		return out
	}
	// The seat id is the kernel's register, not a name scan.
	if seat := WmctlSeatPid(); seat > 0 {
		out.WM = uint32(seat)
	}
	// #2158: self-pid is the kernel's register too — a name match would
	// resolve the FIRST same-named row, sending this process's acks to a
	// sibling's mailbox. Where the register answers it is authoritative;
	// where it does not (host, -ENOSYS) the scan below is the fallback.
	if pid, ok := SelfPid(); ok {
		out.Self = pid
	}
	rows := make([]ProcRow, 64)
	for attempt := 0; attempt < wmPeersScanAttempts; attempt++ {
		// With no registered seat there is nothing to classify; with one,
		// the scan must read its row before the protocol answer stands.
		seatSeen := out.WM == 0
		if n, r := Procs(rows); r > 0 && n > 0 {
			for i := 0; i < n; i++ {
				if rows[i].State != ProcRunning {
					continue
				}
				name := rows[i].Name()
				if out.Self == 0 && name == selfName {
					out.Self = uint32(rows[i].PID)
				}
				// The seat row's name picks the protocol: GOTABWM.ELF
				// speaks authenticated WM_RPC (#2080), the Zig seats the
				// legacy bind. A seat row whose name reads back zeroed is
				// the M56d flake — this scan cannot classify the seat, so
				// seatSeen stays false and the loop retries.
				if out.WM != 0 && rows[i].PID == uint64(out.WM) && name != "" {
					out.Go = name == wmGoSeatName
					seatSeen = true
				}
			}
		}
		if out.Self != 0 && seatSeen {
			return out
		}
		if attempt == 0 {
			// The flake alternates per scan, so one immediate re-read lands
			// an intact scan far more often than a tick-long sleep would.
			continue
		}
		Yield()
	}
	return out
}

// --- wire helpers (shared with wmclient.go) --------------------------------

func getU16(b []byte) uint16 { return uint16(b[0]) | uint16(b[1])<<8 }

func putU16(b []byte, v uint16) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
}

func getU32(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}

func getU64(b []byte) uint64 {
	return uint64(b[0]) | uint64(b[1])<<8 | uint64(b[2])<<16 | uint64(b[3])<<24 |
		uint64(b[4])<<32 | uint64(b[5])<<40 | uint64(b[6])<<48 | uint64(b[7])<<56
}

func putU64(b []byte, v uint64) {
	for i := 0; i < 8; i++ {
		b[i] = byte(v >> (8 * i))
	}
}
