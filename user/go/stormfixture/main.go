//go:build virelai

// GOSTORM.ELF — the M129b (#2611) spawn-storm fixture. At the 512 MiB
// default the scheduler task pool is the sole concurrency bound; the
// go-stress spec boots a boot then execs a dozen of these, each seating
// K real kernel tasks via slot-73 sys_thread op 0 — the same seam Go's
// runtime uses for newosproc — until the pool saturates. The gate then
// asserts `resources: tasks=64/64` and the named pool-full refusal on
// one more exec.
//
// Each child is a pure-asm leaf (storm_arm64.s): a `sys_sleep` +
// `sys_yield` loop on its own EL0 stack — a 48-page kernel kstack and a
// pool slot, no futex seat, no Go machinery (no g — R28 is unused).
// Children are bound to this process per ADR 0027 D3 (≤ process
// max_threads), so the storm reaches the pool bound across ~10 programs,
// never inside one.
//
// argv: `exec GOSTORM.ELF K IDX` — K children this instance tries to
// seat (default 4), IDX a small ordinal that staggers each program's
// storm start by ~500 ms so the serial `gostorm: up` reports print one
// at a time instead of interleaving. Over-cap requests refuse EAGAIN by
// name; the fixture retries within a 3 s wall window so a transient dip
// (a peer runtime still starting) re-fills — after the window it
// reports and parks forever, keeping the pool occupancy stable for the
// gate's read.
package main

import "unsafe"

//go:linkname goargs runtime.VirelaiArgs
func goargs() []string

//go:linkname virelaiSleep runtime.VirelaiSleep
func virelaiSleep(ns int64)

//go:linkname virelaiNanotime runtime.VirelaiNanotime
func virelaiNanotime() int64

// threadCreate issues slot-73 sys_thread op 0 with this fixture's own
// stormChild as the entry — the runtime's virThreadCreate is not
// pullable (no push-linkname; cmd/link's checklinkname refuses runtime
// pulls that were not exported), so the seam is repeated in asm.
func threadCreate(stackHi, arg uintptr) int32

// A child only ever sleeps — 64 KiB of heap stack is far past what the
// asm loop touches (it never calls out, so ~0 bytes live). Keeping the
// buffers reachable retains the VAs the children park on.
const childStack = 64 << 10

func atoi(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return -1
		}
		n = n*10 + int(c-'0')
	}
	return n
}

func main() {
	want, idx := 4, 0
	if a := goargs(); len(a) > 1 {
		if n := atoi(a[1]); n > 0 {
			want = n
		}
		if len(a) > 2 {
			if n := atoi(a[2]); n > 0 {
				idx = n
			}
		}
	}
	// Settle window: the gate execs a dozen of these back-to-back, and
	// each program's runtime seats its own sysmon/P Ms through the same
	// slot-73 seam. If children filled the pool before a peer's runtime
	// finished seating, that peer's newosproc would refuse EAGAIN into a
	// fatal throw — the M120b crash shape, observed live on the first
	// run of this leg (a 2 s settle was not enough: two peers' runtimes
	// were still seating when the first children grabbed slots). Ten
	// seconds plus a per-program stagger lets every exec'd peer's
	// runtime finish seating first, so ONLY children absorb the
	// overshoot and every storm program survives.
	virelaiSleep(10_000_000_000 + int64(idx)*500_000_000)
	var kept [][]byte
	spawned, refused := 0, 0
	deadline := virelaiNanotime() + 3_000_000_000
	for spawned < want {
		buf := make([]byte, childStack)
		hi := (uintptr(unsafe.Pointer(&buf[0])) + childStack) &^ 15
		if threadCreate(hi, 0) < 0 {
			refused++
			if virelaiNanotime() > deadline {
				break
			}
			virelaiSleep(20_000_000) // 20 ms — let a still-starting peer drain
			continue
		}
		spawned++
		kept = append(kept, buf)
	}
	println("gostorm: up spawned=", spawned, " refused=", refused)
	// Park forever: the spawned tasks hold their pool slots while this
	// program stays alive, so the gate's `resources`/`tasks` read sees a
	// stable occupancy — the point of the leg is saturation, not churn.
	for {
		virelaiSleep(3600_000_000_000)
	}
}
