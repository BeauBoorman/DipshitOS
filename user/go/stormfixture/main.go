//go:build virelai

// GOSTORM.ELF — the M129b (#2611) spawn-storm fixture, retuned under
// M133c (#2757). At the 512 MiB default the scheduler task pool is the
// sole concurrency bound; the go-stress spec boots a boot then execs a
// dozen of these, each seating K real kernel tasks via slot-73
// sys_thread op 0 — the same seam Go's runtime uses for newosproc —
// until the pool saturates. The gate then asserts
// `resources: tasks=64/64` and the named pool-full refusal on one more
// exec.
//
// M133c (#2757) retune — measured on this tree's run of the leg:
// the compiled GOMAXPROCS=2 runtime seats ~4 kernel tasks per program,
// so the twelve programs hold ~48 of the 61 user slots before a single
// child spawns; children then take every remaining seat (~13, all
// claimed by the earliest programs out of settle — later programs
// report spawned=0) and the pool still saturates at tasks=64/64 with
// the named exec refusal. (GOMAXPROCS(1) was tried for the retune and
// dropped: it changed nothing — the ~4-task footprint is Ms + sysmon,
// not Ps.)
//
// The retune has two halves, both keyed on what run 07 observed —
// twelve execs, twelve live procs, ELEVEN reports, no `fatal error:`
// and no `virtio-console: tx-dropped` notice: one program never made
// it to its report.
//
// 1. Waits ride the kernel tick, not the runtime timer heap. A
//    `virelaiSleep` (timeSleep) wake depends on the caller's own
//    runtime — checktimers on sysmon plus an idle-M futex wake — while
//    every storm runtime keeps its sysmon M spinning the busy-yield
//    `usleep` loop: twelve hot hogs on two cores, and under the
//    pre-M133b scheduler (no aging) a program whose goroutine woke —
//    or whose first task had barely run — could simply never win a
//    pick again. `vi.Sleep` is a raw `sys_sleep`: a committed block
//    that recovers priority at wake (M133b `note_blocked`) and is
//    re-readied by `wake_expired` without touching the runtime's M
//    economy at all. Tick granularity is ~1 s, so the stagger moved
//    from 500 ms to one tick per program — a cleaner spread.
// 2. Report integrity and identity: the bare `println` emits a write
//    per argument piece, and a cross-core `smp: steal runs=` line was
//    observed spliced between `spawned= ` and its digits (the same
//    splice class vi.ConsoleLine documents from GOTOP). The gate's
//    tuple regex needs the record on one line, so the report goes out
//    as a single ConsoleLine write — and it now carries `idx`, so a
//    future missing report names its program instead of leaving the
//    leg to guess.
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
// storm start by one scheduler tick (~1 s) so the serial `gostorm: up`
// reports print one at a time instead of interleaving. Over-cap
// requests refuse EAGAIN by name; the fixture retries within a 3 s
// wall window so a transient dip (a peer runtime still starting)
// re-fills — after the window it reports and parks forever, keeping
// the pool occupancy stable for the gate's read.
package main

import (
	"unsafe"

	"virelai/vi"
)

//go:linkname goargs runtime.VirelaiArgs
func goargs() []string

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
	// ticks plus a per-program stagger lets every exec'd peer's runtime
	// finish seating first, so ONLY children absorb the overshoot and
	// every storm program survives. The sleep itself is `sys_sleep`:
	// a committed kernel block whose wake needs nothing from this
	// runtime's own M economy (see the header).
	vi.Sleep(10 + uint64(idx))
	// A phase marker, not an assertion target: if a program ever goes
	// missing again, `settled` vs `up` says whether it died waiting or
	// died storming.
	vi.ConsoleLine("gostorm: settled idx= " + vi.Itoa64(int64(idx)))
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
			vi.Sleep(1) // one tick — let a still-starting peer drain
			continue
		}
		spawned++
		kept = append(kept, buf)
	}
	// One write for the whole report — a split line is unparseable.
	vi.ConsoleLine("gostorm: up spawned= " + vi.Itoa64(int64(spawned)) +
		"  refused= " + vi.Itoa64(int64(refused)) +
		" idx= " + vi.Itoa64(int64(idx)))
	// Park forever: the spawned tasks hold their pool slots while this
	// program stays alive, so the gate's `resources`/`tasks` read sees a
	// stable occupancy — the point of the leg is saturation, not churn.
	for {
		vi.Sleep(3600)
	}
}
