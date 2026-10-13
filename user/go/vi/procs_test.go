package vi

import (
	"testing"
	"unsafe"
)

// procsV2Row is one staged v2 row for the fake kernel below.
type procsV2Row struct {
	pid, state, exit  uint64
	name              string
	cpu, mem, total   uint64
	ncores, totalPage uint32
}

// emitV2Row writes one 80-byte version-2 row (ADR 0047 layout).
func emitV2Row(buf []byte, i int, r procsV2Row) {
	off := i * ProcRowBytesV2
	// u32 row_version@0, u32 row_bytes@4.
	buf[off+0] = byte(ProcRowVersion2)
	buf[off+4] = byte(ProcRowBytesV2)
	putU64(buf[off+8:], r.pid)
	putU64(buf[off+16:], r.state)
	putU64(buf[off+24:], r.exit)
	copy(buf[off+32:off+48], r.name)
	putU64(buf[off+48:], r.cpu)
	putU64(buf[off+56:], r.mem)
	putU64(buf[off+64:], r.total)
	putU64(buf[off+72:], uint64(r.ncores)|uint64(r.totalPage)<<32)
}

// procsRequest mirrors what handle_procs extracts: version tag in the top
// byte of a1, byte limit in the lower 56 bits.
func procsRequest(a1 uintptr) (version uintptr, max uintptr) {
	return a1 >> procsMaxVersionBits, a1 & (uintptr(1)<<procsMaxVersionBits - 1)
}

// fakeProcsV2 is a v2 kernel: it honours the tag, writes 80-byte rows, and
// reports the negotiated version back via got for assertions.
func fakeProcsV2(t *testing.T, rows []procsV2Row, got *uintptr) func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
	return func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotProcs {
			t.Fatalf("unexpected slot %d", num)
		}
		ver, max := procsRequest(a1)
		*got = ver
		buf := unsafe.Slice((*byte)(unsafe.Pointer(a0)), max)
		n := 0
		for _, r := range rows {
			if (n+1)*ProcRowBytesV2 > len(buf) {
				break
			}
			emitV2Row(buf, n, r)
			n++
		}
		return int64(n)
	}
}

// TestProcsV2Negotiates pins the request shape: ProcsV2 must raise the
// version byte in `max`'s top byte and the kernel must see a byte limit
// that fits the caller's buffer.
func TestProcsV2Negotiates(t *testing.T) {
	var gotVer uintptr
	rows := []procsV2Row{{
		pid: 7, state: ProcRunning, name: "BUSY.BIN",
		cpu: 41, mem: 7 * 4096, total: 1000, ncores: 4, totalPage: 65536,
	}}
	installHook(t, fakeProcsV2(t, rows, &gotVer))

	dst := make([]ProcRow, 4)
	n, rc := ProcsV2(dst)
	if rc <= 0 || n != 1 {
		t.Fatalf("ProcsV2 = (%d, %d), want (1, >0)", n, rc)
	}
	if gotVer != ProcRowVersion2 {
		t.Fatalf("kernel saw version %d, want %d", gotVer, ProcRowVersion2)
	}
	r := dst[0]
	if r.RowVer != ProcRowVersion2 || r.PID != 7 || r.State != ProcRunning {
		t.Fatalf("identity = ver %d pid %d state %d", r.RowVer, r.PID, r.State)
	}
	if r.Name() != "BUSY.BIN" {
		t.Fatalf("name = %q", r.Name())
	}
	if r.CpuTicks != 41 || r.MemBytes != 7*4096 || r.TotalTicks != 1000 {
		t.Fatalf("usage = cpu %d mem %d total %d", r.CpuTicks, r.MemBytes, r.TotalTicks)
	}
	if r.NCores != 4 || r.TotalPages != 65536 {
		t.Fatalf("machine = ncores %d pages %d", r.NCores, r.TotalPages)
	}
}

// TestProcsV2OldKernel is the fail-before leg the other way round: a
// kernel that predates ADR 0047 ignores the top byte of `max`, floors the
// lower bits to 40-byte rows, and writes the frozen v1 stream. The reader
// must decode identity fields and leave every v2 field zero — never
// garbage.
func TestProcsV2OldKernel(t *testing.T) {
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotProcs {
			t.Fatalf("unexpected slot %d", num)
		}
		// Old kernel: a1 is a plain byte count — no version extraction.
		max := a1 & (uintptr(1)<<procsMaxVersionBits - 1)
		buf := unsafe.Slice((*byte)(unsafe.Pointer(a0)), max)
		if max < 2*ProcRowSize {
			return 0
		}
		emitProcRow(buf, 0, 3, ProcRunning, 0)
		copy(buf[24:40], "SHELL.BIN")
		emitProcRow(buf, 1, 4, ProcExited, 7)
		copy(buf[ProcRowSize+24:ProcRowSize+40], "DEAD.BIN")
		return 2
	})

	dst := make([]ProcRow, 4)
	n, rc := ProcsV2(dst)
	if rc <= 0 || n != 2 {
		t.Fatalf("ProcsV2 = (%d, %d), want (2, >0)", n, rc)
	}
	if dst[0].PID != 3 || dst[0].Name() != "SHELL.BIN" || dst[1].ExitStatus != 7 {
		t.Fatalf("v1 decode wrong: %+v %+v", dst[0], dst[1])
	}
	for i := 0; i < n; i++ {
		r := dst[i]
		if r.RowVer != 0 || r.CpuTicks != 0 || r.MemBytes != 0 ||
			r.TotalTicks != 0 || r.NCores != 0 || r.TotalPages != 0 {
			t.Fatalf("row %d leaked usage fields: %+v", i, r)
		}
	}
}

// TestDecodeProcRowsUnknownVersion: a row claiming version 3 or a bogus
// row_bytes is not our stream — decode must fall back to the frozen v1
// stride rather than trusting the header.
func TestDecodeProcRowsUnknownVersion(t *testing.T) {
	// A stream whose "header" is really v1 row data: pid@0 is small but
	// row_bytes@4 (state high bits) is 0 — not a plausible v2 header.
	buf := make([]byte, 2*ProcRowSize)
	emitProcRow(buf, 0, 5, ProcRunning, 0)
	emitProcRow(buf, 1, 6, ProcExited, 1)
	dst := make([]ProcRow, 2)
	decodeProcRows(dst, buf)
	if dst[0].PID != 5 || dst[1].PID != 6 {
		t.Fatalf("v1 fallback decode wrong: pids %d %d", dst[0].PID, dst[1].PID)
	}
	if dst[0].RowVer != 0 || dst[0].CpuTicks != 0 {
		t.Fatalf("v1 row leaked versioned fields: %+v", dst[0])
	}
}

// TestDecodeProcRowsNarrowed: a future kernel could emit a wider version
// with a narrower row_bytes. Fields past the advertised width must decode
// as zero.
func TestDecodeProcRowsNarrowed(t *testing.T) {
	const stride = 56 // version 3 row that stops after cpu_ticks@48..55
	buf := make([]byte, stride)
	buf[0] = 3
	buf[4] = stride
	putU64(buf[8:], 9)
	putU64(buf[48:], 1234) // cpu_ticks fits
	dst := make([]ProcRow, 1)
	decodeProcRows(dst, buf)
	if dst[0].RowVer != 3 || dst[0].PID != 9 || dst[0].CpuTicks != 1234 {
		t.Fatalf("narrow decode wrong: %+v", dst[0])
	}
	if dst[0].MemBytes != 0 || dst[0].TotalTicks != 0 || dst[0].NCores != 0 {
		t.Fatalf("field past row_bytes decoded garbage: %+v", dst[0])
	}
}
