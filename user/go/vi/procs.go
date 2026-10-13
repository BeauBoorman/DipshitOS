// procs.go — negotiated `sys_procs` reading (ADR 0047, #2198).
//
// The v1 wire row is frozen at 40 bytes; `Procs` (ipc.go) keeps passing an
// untagged byte count so old readers, test hooks, and the syscall's legacy
// contract are untouched. `ProcsV2` asks for the extended row by setting
// the top byte of `max` to ProcRowVersion2. A kernel that predates the tag
// sees a small byte limit it floors to 40-byte rows — the response is
// still a well-formed v1 stream — so the read is safe on either kernel.
//
// The returned rows are self-describing: row0 carries u32 version@0 and
// u32 row_bytes@4. decodeProcRows picks the stride from that header —
// version>=2 with a sane row_bytes walks the extended stride, anything
// else is treated as the frozen 40-byte stream. Fields past a row's
// advertised width decode as zero, never garbage.

package vi

import "unsafe"

// procsMaxVersionBits is the negotiation shift: the requested row version
// rides the top byte of `sys_procs`'s `max` argument; the lower 56 bits
// stay the byte limit. Every legacy caller passes a real buffer length
// below 2^56, so untagged requests always decode as version 0.
const procsMaxVersionBits = 56

// ProcsV2 reads the process table asking for the versioned row (ADR 0047).
// On a v2 kernel every row reports CpuTicks, MemBytes, TotalTicks, NCores
// and TotalPages; on a v1 kernel those fields are zero and RowVer is 0/1.
// Returns (rows, raw) with the same contract as Procs.
func ProcsV2(dst []ProcRow) (int, int64) {
	if len(dst) == 0 {
		return 0, 0
	}
	// The buffer must also satisfy an old kernel: it ignores the version
	// tag and could write `max` bytes of 40-byte rows, so `max` must never
	// exceed the real allocation.
	buf := make([]byte, len(dst)*ProcRowBytesV2)
	r := svc2(SlotProcs, uintptr(unsafe.Pointer(&buf[0])),
		uintptr(len(buf))|uintptr(ProcRowVersion2)<<procsMaxVersionBits)
	if r < 0 {
		return 0, r
	}
	rows := int(r)
	if rows > len(dst) {
		rows = len(dst)
	}
	decodeProcRows(dst[:rows], buf)
	return rows, r
}

// decodeProcRows fills dst from a raw snapshot, choosing the stride from
// the stream's own header. A v1 stream's first u64 is a small pid, so
// version>=2 with a plausible row_bytes is unambiguous; anything else —
// old kernel, unknown version, or a stride too narrow to hold the
// identity fields — falls back to the frozen 40-byte decode.
func decodeProcRows(dst []ProcRow, buf []byte) {
	stride := ProcRowSize
	version := uint32(0)
	if len(buf) >= 8 {
		ver := getU32(buf[0:])
		rb := int(getU32(buf[4:]))
		if ver >= ProcRowVersion2 && rb >= 48 && rb <= len(buf) {
			stride = rb
			version = ver
		}
	}
	for i := range dst {
		off := i * stride
		// dst may be a caller's reused scratch slice: start every row from
		// zero so a v1 stream retracts previously decoded v2 fields rather
		// than leaving them stale.
		dst[i] = ProcRow{}
		if version >= ProcRowVersion2 {
			// v2 layout (ADR 0047): u32 row_version@0, u32 row_bytes@4,
			// then the v1 identity fields shifted +8 — pid@8, state@16,
			// exit_status@24, name[16]@32 — and the usage tail after them.
			// Each field decodes only when its end offset fits the
			// advertised width: a narrowed future row leaves the tail
			// zeroed instead of leaking bytes from the next field.
			if off+48 > len(buf) {
				return
			}
			row := buf[off:]
			dst[i].RowVer = version
			dst[i].PID = getU64(row[8:])
			dst[i].State = getU64(row[16:])
			dst[i].ExitStatus = getU64(row[24:])
			copy(dst[i].NameBuf[:], row[32:48])
			if stride >= 56 {
				dst[i].CpuTicks = getU64(row[48:])
			}
			if stride >= 64 {
				dst[i].MemBytes = getU64(row[56:])
			}
			if stride >= 72 {
				dst[i].TotalTicks = getU64(row[64:])
			}
			if stride >= 76 {
				dst[i].NCores = getU32(row[72:])
			}
			if stride >= 80 {
				dst[i].TotalPages = uint64(getU32(row[76:]))
			}
			continue
		}
		if off+ProcRowSize > len(buf) {
			return
		}
		row := buf[off:]
		dst[i].PID = getU64(row[0:])
		dst[i].State = getU64(row[8:])
		dst[i].ExitStatus = getU64(row[16:])
		copy(dst[i].NameBuf[:], row[24:24+ProcNameBytes])
	}
}
