// M70c (#1455) fixture: the guest reads a MULTI-MEGABYTE file from the host
// share end to end and reports what it cost.
//
// Why this exists. S1/S2 (compile + link in-guest) have to move a Go
// toolchain's inputs across the host file channel, and ADR 0035 named
// in-guest transfer throughput as unmeasured — the card's own first
// instruction is "measure the honest transfer and mmap story first and record
// it". The mmap half landed with M70c-K (#1504); this is the transfer half.
// Two facts in the tree make the useful question specific:
//
//   - the EL0 read surface clamps ONE sys_file_read to the channel's reply
//     cap (kernel/src/syscall.zig file_io_max = virtio_file.reply_cap, 32 KiB —
//     M171b raised it from the old 2048-byte stack stage), so a 27 MB payload
//     is ~845 syscalls, not ~13,200;
//   - each of those syscalls is one (at most two: the reply header eats 3
//     bytes of the cap) virtio round trips (file_table.read loops
//     virtio_file.read_chunk at the handle's cursor — "the host share is
//     stateless").
//
// So the number that matters is CALLS PER SECOND at the cap, not bytes per
// second at some buffer size the kernel will not honour. The fixture reads the
// whole file with the cap-sized buffer the guest SDK itself uses
// (vsys.MaxFileIOBytes), counts calls, and hashes every byte as it arrives —
// the hash is what makes the read unforgeable: a short read, a dropped chunk,
// a wrong offset or a page of zeros is a different number, and the gate
// recomputes it on macOS from the file it staged.
//
// The call count is an OBSERVATION of the clamp, not an assumption:
// ceil(bytes / MaxFileIOBytes) is only reachable if the kernel really does
// move that many bytes per call, so the gate asserts it exactly. If the cap
// ever moves, that assert fails by name — which is the point, because
// ADR 0035's transfer arithmetic would have to be re-derived rather than
// inherited.
//
// Imports: `vsys` only, deliberately. It carries both the clock (Nanotime,
// CNTPCT_EL0) and the os.File-shaped share API, and it costs ~0.6 KB of the
// GOOS=virelai link recipe's 576 KiB rodata window; `vi` (which the other
// fixtures use) costs ~5.4 KB, and the window is not big enough for both.
package main

import (
	_ "runtime" // the linkname target below (see tools/go/goargs.go)
	_ "unsafe"

	"virelai/vsys"
)

//go:linkname args runtime.VirelaiArgs
func args() []string

// chunkCap is the per-call bound the kernel and the SDK agree on
// (kernel/src/syscall.zig `take_count`, vsys.MaxFileIOBytes).
const chunkCap = vsys.MaxFileIOBytes

// FNV-1a 64, hand-rolled: strconv and friends are not reachable from a
// GOOS=virelai build at all (there is no syscall/os port yet — ADR 0035), and
// every byte of code costs room in a 448 KiB text / 576 KiB rodata recipe.
const (
	fnvOffset = uint64(0xcbf29ce484222325)
	fnvPrime  = uint64(0x100000001b3)
)

func main() {
	a := args()
	if len(a) < 2 {
		fail("usage: exec GOREAD.ELF /host/<file>")
	}
	path := a[1]

	f, err := vsys.Open(path, vsys.ModeRead)
	if err != nil {
		fail("open " + err.Error())
	}
	buf := make([]byte, chunkCap)

	var bytes, calls int64
	max := 0
	hash := fnvOffset
	t0 := vsys.Nanotime()
	for {
		n, rerr := f.Read(buf)
		if rerr != nil {
			f.Close()
			fail("read " + rerr.Error() + " after " + vsys.Itoa64(bytes))
		}
		if n == 0 {
			break // EOF
		}
		calls++
		bytes += int64(n)
		if n > max {
			max = n
		}
		for i := 0; i < n; i++ {
			hash ^= uint64(buf[i])
			hash *= fnvPrime
		}
	}
	nanos := vsys.Nanotime() - t0
	f.Close()

	if bytes == 0 {
		fail("read 0 bytes from " + path)
	}

	// The bytes the channel served, the calls it took, and the largest single
	// call. Deterministic given the file and the ABI — this is the line the
	// gate asserts exactly.
	println("goread: file", path, "bytes", bytes, "calls", calls, "max", max)

	// The hash of the bytes READ (never of a constant), for the host to
	// recompute over the file it staged.
	println("goread: fnv 0x" + hex64(hash))

	// The measurement itself. A rate is a machine observation, not a verdict,
	// so the gate never asserts these numbers — they are recorded in ADR 0035.
	// The keystroke cost of the fold above is ~0.3 ns/byte, i.e. under 3 ms of
	// the run, which is why it stays inside the timed loop instead of needing a
	// second pass.
	kib := bytes * 1_000_000_000 / 1024 / nanos
	perCall := nanos / calls
	println("goread: rate us", nanos/1000, "kib_s", kib, "ns_call", perCall)

	vsys.Println("goread: GOREAD OK")
}

// fail prints one honest reason and exits non-zero, so a broken measurement is
// a failed run rather than a green one with no numbers.
func fail(reason string) {
	vsys.Println("goread: FAIL " + reason)
	vsys.Exit(1)
}

// hex64 formats v as 16 lowercase hex digits (the hash's wire form).
func hex64(v uint64) string {
	const digits = "0123456789abcdef"
	var buf [16]byte
	for i := 15; i >= 0; i-- {
		buf[i] = digits[v&0xf]
		v >>= 4
	}
	return string(buf[:])
}
