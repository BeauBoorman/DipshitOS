package vi

import (
	"testing"
	"unsafe"
)

// M56a: the IPC slot numbers are the kernel's (ADR 0007); pin them so a drift
// fails the host suite instead of the VM gate.
func TestIpcSlotNumbers(t *testing.T) {
	if SlotIPCSend != 5 || SlotIPCRecv != 6 || SlotProcs != 7 {
		t.Fatalf("ipc slots = %d/%d/%d want 5/6/7", SlotIPCSend, SlotIPCRecv, SlotProcs)
	}
}

func TestMailboxBounds(t *testing.T) {
	if MailboxMessageMax != 64 {
		t.Fatalf("MailboxMessageMax = %d want 64", MailboxMessageMax)
	}
	if MailboxMaxMessages != 8 {
		t.Fatalf("MailboxMaxMessages = %d want 8", MailboxMaxMessages)
	}
	if ProcRowSize != 40 || ProcNameBytes != 16 {
		t.Fatalf("proc row geometry = %d/%d want 40/16", ProcRowSize, ProcNameBytes)
	}
}

// A zero-length send is a no-op that returns 0 without a syscall.
func TestIpcSendZeroLength(t *testing.T) {
	if got := IpcSend(3, nil); got != 0 {
		t.Fatalf("nil send = %d want 0", got)
	}
	if got := IpcSend(3, []byte{}); got != 0 {
		t.Fatalf("empty send = %d want 0", got)
	}
}

// A long send is truncated to the slot bound before the syscall. Off-guest
// the syscall is -ENOSYS, so this proves the bound was applied (no panic, a
// well-formed call) rather than host I/O.
func TestIpcSendTruncatesToSlotBound(t *testing.T) {
	long := make([]byte, MailboxMessageMax*3)
	if got := IpcSend(3, long); got != -ErrENOSYS {
		t.Fatalf("host send = %d want %d", got, -ErrENOSYS)
	}
}

func TestIpcRecvHostDegrades(t *testing.T) {
	var buf [8]byte
	n, r := IpcRecv(buf[:])
	if n != 0 || r != -ErrENOSYS {
		t.Fatalf("host recv = (%d,%d) want (0,%d)", n, r, -ErrENOSYS)
	}
	if n, r := IpcRecv(nil); n != 0 || r != 0 {
		t.Fatalf("empty recv = (%d,%d) want (0,0)", n, r)
	}
}

func TestProcsHostDegrades(t *testing.T) {
	rows := make([]ProcRow, 4)
	n, r := Procs(rows)
	if n != 0 || r != -ErrENOSYS {
		t.Fatalf("host procs = (%d,%d) want (0,%d)", n, r, -ErrENOSYS)
	}
	if n, r := Procs(nil); n != 0 || r != 0 {
		t.Fatalf("empty procs = (%d,%d) want (0,0)", n, r)
	}
}

// ProcRow decodes the kernel's fixed little-endian layout: pid@0, state@8,
// exit@16, name@24. A synthetic row goes through the same helpers the reader
// uses so the offsets are pinned together.
func TestProcRowLayout(t *testing.T) {
	if ProcRowSize != 40 {
		t.Fatalf("row size %d want 40", ProcRowSize)
	}
	if off := unsafe.Offsetof(ProcRow{}.NameBuf); off != 24 {
		t.Fatalf("NameBuf offset %d want 24", off)
	}
	raw := make([]byte, ProcRowSize)
	putU64(raw[0:], 7)
	putU64(raw[8:], ProcRunning)
	putU64(raw[16:], 0)
	copy(raw[24:], "TABWM.BIN")
	if getU64(raw[0:]) != 7 || getU64(raw[8:]) != ProcRunning {
		t.Fatal("row helpers wrong")
	}
	row := ProcRow{PID: getU64(raw[0:]), State: getU64(raw[8:])}
	copy(row.NameBuf[:], raw[24:24+ProcNameBytes])
	if row.Name() != "TABWM.BIN" {
		t.Fatalf("name = %q", row.Name())
	}
	// NUL padding is trimmed.
	short := ProcRow{}
	copy(short.NameBuf[:], "WND.BIN")
	if short.Name() != "WND.BIN" {
		t.Fatalf("padded name = %q", short.Name())
	}
}

func TestWmPeersHostEmpty(t *testing.T) {
	if p := WmPeers("DEMOAPP.ELF"); p.WM != 0 || p.Self != 0 {
		t.Fatalf("host WmPeers = %+v want zero", p)
	}
	if p := WmPeers(""); p.WM != 0 || p.Self != 0 {
		t.Fatalf("empty-name WmPeers = %+v want zero", p)
	}
}

// M56d (#1315) + #1586: the scan is retried ONLY while it is suspect, and the
// number of SCANS is what a boot pays, because every retry is preceded by a
// yield and on VZ a yield parks the caller until the next scheduler tick -- a
// full second (kernel/src/timer.zig period_ns). So the five tests below pin
// both directions of that policy by counting scans: a no-seat boot answers on
// the first one, and the zeroed-name flake still gets its re-read.
//
// (Scans are counted rather than yields because Yield goes through syscall0
// while the host-test hook intercepts the svc* family -- the proc_test.go
// hooks' SlotYield branch is unreachable for the same reason.)

// namedRow is a RUNNING row with readable name bytes.
func namedRow(pid uint64, name string) ProcRow {
	r := ProcRow{PID: pid, State: ProcRunning}
	copy(r.NameBuf[:], name)
	return r
}

// emitNamed writes rows into a sys_procs buffer WITH their names. The
// proc_test.go fakeProcs helper deliberately leaves names zeroed (that is the
// flake shape), so the intact cases need their own emitter.
func emitNamed(a0, a1 uintptr, rows []ProcRow) int {
	buf := unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1)
	n := 0
	for _, r := range rows {
		off := n * ProcRowSize
		if off+ProcRowSize > len(buf) {
			break
		}
		putU64(buf[off:], r.PID)
		putU64(buf[off+8:], r.State)
		putU64(buf[off+16:], r.ExitStatus)
		copy(buf[off+24:off+24+ProcNameBytes], r.NameBuf[:])
		n++
	}
	return n
}

// scanHook serves one proc table per SlotProcs call (the last table repeats)
// and counts those calls: the scan count IS the cost, since every retry beyond
// the first is preceded by a tick-costing yield. `seat` is the answer to the
// slot-65 SEAT_PID query (#2079) — the kernel's registered WM pid, or a
// negative errno (-ENOENT) when no seat is held. The proc-table rows may
// carry any names at all: the seat answer is the kernel's, not the name's.
func scanHook(t *testing.T, seat int64, tables ...[]ProcRow) *int {
	t.Helper()
	if len(tables) == 0 {
		t.Fatal("scanHook needs at least one table")
	}
	scans := new(int)
	call := 0
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case SlotProcs:
			tbl := tables[len(tables)-1]
			if call < len(tables) {
				tbl = tables[call]
			}
			call++
			*scans++
			return int64(emitNamed(a0, a1, tbl))
		case SlotWmctl:
			if a0 == uintptr(WmctlSeatPidCmd) {
				return seat
			}
			return -ErrENOSYS
		}
		return -ErrENOSYS
	})
	return scans
}

// scanHookGetpid is scanHook plus a kernel self-pid register (slot 87,
// ADR 0048): `selfpid <= 0` models a kernel without the slot (-ENOSYS),
// which is exactly what the legacy callers of scanHook see.
func scanHookGetpid(t *testing.T, selfpid int64, seat int64, tables ...[]ProcRow) *int {
	t.Helper()
	if len(tables) == 0 {
		t.Fatal("scanHookGetpid needs at least one table")
	}
	scans := new(int)
	call := 0
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case SlotGetpid:
			if selfpid > 0 {
				return selfpid
			}
			return -ErrENOSYS
		case SlotProcs:
			tbl := tables[len(tables)-1]
			if call < len(tables) {
				tbl = tables[call]
			}
			call++
			*scans++
			return int64(emitNamed(a0, a1, tbl))
		case SlotWmctl:
			if a0 == uintptr(WmctlSeatPidCmd) {
				return seat
			}
			return -ErrENOSYS
		}
		return -ErrENOSYS
	})
	return scans
}

// TestWmPeersSelfPidIsTheKernelRegister is the #2158 fix: the proc table
// carries TWO RUNNING rows named NOTE.ELF — the first name match (pid 4)
// is the OTHER instance; the caller is the second (pid 8, the duplicate-
// tab chord's spawn). The sys_getpid register must win over the scan or
// every WM_RPC this instance sends stamps reply_to=4 and its acks —
// including the Go seat's bind challenge — misroute to the sibling's
// mailbox.
func TestWmPeersSelfPidIsTheKernelRegister(t *testing.T) {
	scans := scanHookGetpid(t, 8, 5, []ProcRow{
		namedRow(1, "GOSH.ELF"),
		namedRow(4, "NOTE.ELF"),
		namedRow(5, "GOTABWM.ELF"),
		namedRow(8, "NOTE.ELF"),
	})
	p := WmPeers("NOTE.ELF")
	if p.Self != 8 || p.WM != 5 || !p.Go {
		t.Fatalf("WmPeers = %+v want self=8 (kernel register) wm=5 go", p)
	}
	// The register answers self before the scan, so one scan still
	// suffices for the seat's protocol row — no retry discipline changes.
	if *scans != 1 {
		t.Fatalf("scan read the table %d time(s), want 1", *scans)
	}
}

// TestWmPeersSelfPidScanFallsBackWithoutRegister keeps the scan as the
// fallback where no kernel answers (host, -ENOSYS): the name match still
// resolves self exactly as before.
func TestWmPeersSelfPidScanFallsBackWithoutRegister(t *testing.T) {
	scanHookGetpid(t, 0, 5, []ProcRow{
		namedRow(1, "WEB.ELF"),
		namedRow(5, "GOTABWM.ELF"),
	})
	p := WmPeers("WEB.ELF")
	if p.Self != 1 || p.WM != 5 || !p.Go {
		t.Fatalf("WmPeers = %+v want self=1 (scan fallback) wm=5 go", p)
	}
}

// TestWmPeersNoSeatAnswersImmediately is the #1586 fix. The shim boot's table
// was measured live: this app plus one other task, no WM-named row, readable on
// every attempt. The honest answer "no seat" is available on the first scan, so
// it must not cost a single yield.
func TestWmPeersNoSeatAnswersImmediately(t *testing.T) {
	scans := scanHook(t, -ErrENOENT, []ProcRow{namedRow(1, "WEB.ELF"), namedRow(2, "GOSH.ELF")})
	p := WmPeers("WEB.ELF")
	if p.Self != 1 || p.WM != 0 {
		t.Fatalf("WmPeers = %+v want self=1 wm=0", p)
	}
	if *scans != 1 {
		t.Fatalf("no-seat scan read the table %d time(s), want 1 (each retry is a 1 s VZ tick)", *scans)
	}
}

// TestWmPeersSeatResolvesOnFirstScan is the seat-present path every tab gate
// rides: intact table, both peers found, no tick spent.
func TestWmPeersSeatResolvesOnFirstScan(t *testing.T) {
	scans := scanHook(t, 5, []ProcRow{namedRow(1, "WEB.ELF"), namedRow(5, "GOTABWM.ELF")})
	p := WmPeers("WEB.ELF")
	if p.Self != 1 || p.WM != 5 {
		t.Fatalf("WmPeers = %+v want self=1 wm=5", p)
	}
	if *scans != 1 {
		t.Fatalf("seat scan read the table %d time(s), want 1", *scans)
	}
}

// TestWmPeersForgedNameCannotStealSeat is the #2079 regression: a rogue
// process exec'ing a file it named GOTABWM.ELF shows up in the table at
// pid 9, but the seat answer is the kernel's register (pid 5), so the
// forged row cannot redirect this app's WM_RPC traffic.
func TestWmPeersForgedNameCannotStealSeat(t *testing.T) {
	scanHook(t, 5, []ProcRow{namedRow(1, "WEB.ELF"), namedRow(5, "TABWM.BIN"), namedRow(9, "GOTABWM.ELF")})
	p := WmPeers("WEB.ELF")
	if p.Self != 1 || p.WM != 5 {
		t.Fatalf("WmPeers = %+v want self=1 wm=5 (forged row must not win)", p)
	}
}

// TestWmPeersZeroedScanRetriesWithoutTick keeps M56d's protection: the scan
// whose name bytes read back zeroed still retries, and because the flake
// alternates per scan the re-read is immediate -- no tick.
func TestWmPeersZeroedScanRetriesWithoutTick(t *testing.T) {
	zeroed := []ProcRow{{PID: 1, State: ProcRunning}, {PID: 3, State: ProcRunning}}
	intact := []ProcRow{namedRow(1, "WEB.ELF"), namedRow(3, "TABWM.BIN")}
	scans := scanHook(t, 3, zeroed, intact)
	p := WmPeers("WEB.ELF")
	if p.Self != 1 || p.WM != 3 {
		t.Fatalf("WmPeers = %+v want self=1 wm=3", p)
	}
	// Two scans, no tick: the flake alternates per scan, so the re-read is
	// immediate (the old loop would have slept a tick before scanning again).
	if *scans != 2 {
		t.Fatalf("alternating flake read the table %d time(s), want 2", *scans)
	}
}

// TestWmPeersSuspectScanWithBothPeersAnswers: a zeroed THIRD row does not
// invalidate the two peers already read, so the answer still lands at once.
func TestWmPeersSuspectScanWithBothPeersAnswers(t *testing.T) {
	rows := []ProcRow{namedRow(1, "WEB.ELF"), namedRow(5, "WND.BIN"), {PID: 9, State: ProcRunning}}
	scans := scanHook(t, 5, rows)
	p := WmPeers("WEB.ELF")
	if p.Self != 1 || p.WM != 5 {
		t.Fatalf("WmPeers = %+v want self=1 wm=5", p)
	}
	if *scans != 1 {
		t.Fatalf("resolved peers still re-read the table %d time(s), want 1", *scans)
	}
}

// TestWmPeersPersistentlySuspectIsBounded: a scan that never reads back stays
// bounded (the M56d ceiling) instead of spinning forever.
func TestWmPeersPersistentlySuspectIsBounded(t *testing.T) {
	scans := scanHook(t, -ErrENOENT, []ProcRow{{PID: 1, State: ProcRunning}})
	p := WmPeers("WEB.ELF")
	if p.Self != 0 || p.WM != 0 {
		t.Fatalf("WmPeers = %+v want zero seat", p)
	}
	if *scans != wmPeersScanAttempts {
		t.Fatalf("persistently suspect scan read the table %d time(s), want %d",
			*scans, wmPeersScanAttempts)
	}
}

// The errno table mirrors the kernel ErrorCode magnitudes
// (kernel/src/syscall.zig) — this is the M56a defect fix (ENOENT/ENOSPC were
// swapped and EEXIST aliased ENXIO before it).
func TestErrnoTable(t *testing.T) {
	pairs := []struct {
		got, want int64
	}{
		{ErrEINVAL, 1}, {ErrEBADF, 2}, {ErrEFAULT, 3}, {ErrENOSYS, 4},
		{ErrENOSPC, 5}, {ErrENOENT, 6}, {ErrEACCES, 7}, {ErrENAMETOOLONG, 8},
		{ErrENXIO, 9}, {ErrENOMEM, 10}, {ErrEAGAIN, 11}, {ErrETIMEDOUT, 12},
	}
	for _, p := range pairs {
		if p.got != p.want {
			t.Fatalf("errno constant = %d want %d", p.got, p.want)
		}
	}
	if -ErrENOSPC != -5 || -ErrENOENT != -6 {
		t.Fatalf("negation wrong: %d %d", -ErrENOSPC, -ErrENOENT)
	}
	if errno(ErrENOSPC).Error() != "ENOSPC" || errno(ErrENOENT).Error() != "ENOENT" {
		t.Fatalf("errno strings wrong: %s %s", errno(ErrENOSPC).Error(), errno(ErrENOENT).Error())
	}
}
