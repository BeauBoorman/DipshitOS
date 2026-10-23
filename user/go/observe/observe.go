// Package observe is the M94g combined observer (#2007): one process that
// runs the M94b tracer, the M94c sampler and the M94d heap view against a
// single target at once, inside ADR 0043's D7 task budget (one combined
// OBSERVE, not three four-task viewers). It does no new analysis of its
// own: decode is strace.Render, symbols and reports are prof's, the heap
// join and leak rule are heap's. What it adds is one poll loop draining
// all three sessions plus a single end-of-session summary line.
//
// Session mode:  observe -p <pid|name> [-sym <elf>] [-watch <path>]
// Overhead mode: observe overhead
//
// Session mode attaches to an already-running target (-p), so the spec
// can keep GOEDIT's own boot markers (declare/present) ahead of the armed
// window. -sym names the symbol donor ELF when the target itself is
// stripped (build-observe.sh builds GOEDITSYM.ELF from the identical
// edit source with .symtab kept: -s/-w only changes stripping, not
// layout, so the twin's addresses resolve the stripped binary's PCs).
// -watch names the share path whose completed saves the session counts;
// a save is the WriteFileSafe rename publishing onto that path.
//
// Overhead mode is M94c's fixed-work fixture re-pointed at the combined
// load: the same xorshift kernel and interleaved off/on pairs, but "on"
// means the filtered tracer (empty slot mask — every call is a filtered
// check), the 100 Hz sampler and the heap memstat poll all armed on
// OBSERVE itself, instead of the profiler alone.
//
// Why I'm separate (the #3189 diagnostics census, docs/diagnostics.md):
// observe CREATES a bounded collection against one live target — the other
// diagnostics surfaces only read data the kernel already keeps: logview
// the app-log rings, crashview the receipt files, GOTOP the point-in-time
// snapshots.
package observe

import (
	"fmt"
	"os"
	"runtime"

	"virelai/heap"
	"virelai/prof"
	"virelai/strace"
	"virelai/vi"
)

// traceSlots limits the session's trace to the file syscalls a save
// exercises (open/read/write/close, delete, rename, fsync) plus exit:
// everything else stays a filtered-out call.
var traceSlots = []uint64{3, 23, 24, 25, 26, 34, 35, 77}

const (
	// sessionDeadline bounds the whole observation; a stuck session fails
	// the gate instead of burning the run's --timeout.
	sessionDeadline = int64(120) * 1e9
	// wantSaves and wantHeapSamples are the session's evidence floor: the
	// driver's five edit/save cycles and the card's post-GC join count.
	wantSaves       = 5
	wantHeapSamples = 5
	// pollTicks is the poll loop's scheduler-tick sleep (1 Hz), the
	// "pollers sleep, never busy-spin" rule from ADR 0043 D6.
	pollTicks = 1
)

func fail(err error) error { return fmt.Errorf("observe: %w", err) }

// Run parses argv (with argv[0]) and dispatches the two modes.
func Run(args []string) error {
	if len(args) >= 2 && args[1] == "overhead" {
		if len(args) != 2 {
			return fmt.Errorf("usage: observe overhead")
		}
		return overhead()
	}
	if len(args) < 3 || args[1] != "-p" || len(args)%2 != 1 {
		return fmt.Errorf("usage: observe -p <pid|name> [-sym <elf>] [-watch <path>] | observe overhead")
	}
	target, sym, watch := args[2], "", ""
	for i := 3; i+1 < len(args); i += 2 {
		switch args[i] {
		case "-sym":
			sym = args[i+1]
		case "-watch":
			watch = args[i+1]
		default:
			return fmt.Errorf("observe: unknown option %s", args[i])
		}
	}
	return session(target, sym, watch)
}

// isSave reports whether a decoded record is the rename that publishes a
// WriteFileSafe body onto watch (slot 35: arg0 old path, arg2 new path).
func isSave(r vi.TraceRecord, watch string) bool {
	if r.Number != 35 || r.Flags&(vi.TraceRedacted|vi.TraceNoReturn) != 0 {
		return false
	}
	if r.StringMask&(1<<2) == 0 || int(r.StringLengths[2]) > vi.TraceStringBytes {
		return false
	}
	return string(r.Strings[2][:r.StringLengths[2]]) == watch
}

func drainTrace(session *strace.Session, watch string) (saves int, dropped uint64, err error) {
	dropped, err = session.Drain(0, func(record vi.TraceRecord, _ string) bool {
		if isSave(record, watch) {
			saves++
		}
		return true
	})
	return saves, dropped, err
}

func drainProfile(token uint64, report *prof.Report, symbols *prof.Symbols) (dropped uint64, err error) {
	for {
		records, loss, e := vi.ProfileSamples(token)
		if e != nil {
			return dropped, e
		}
		dropped = loss
		for _, record := range records {
			if report != nil {
				report.Add(symbols, record)
			}
		}
		if len(records) < vi.ObserveMaxReadRecords {
			return dropped, nil
		}
	}
}

func running(pid uint64) bool {
	_, state := vi.Probe(int64(pid))
	return state == vi.ProbeRunning
}

// session arms the tracer and the sampler on one running target, polls
// the kernel memstat and the in-process heap series once a second, and
// writes the combined summary when the evidence floor is met, the target
// exits, or the deadline refuses it.
func session(target, sym, watch string) error {
	// The spec attaches OBSERVE as early as the target's first own marker;
	// a freshly exec'd process may need a tick before procs reports it
	// running, so retry rather than refuse the first sighting.
	var row vi.ProcRow
	var err error
	for attempt := 0; attempt < 10; attempt++ {
		row, err = prof.FindTarget(target)
		if err == nil {
			break
		}
		vi.Sleep(pollTicks)
	}
	if err != nil {
		return fail(err)
	}
	pid, app := row.PID, row.Name()
	if sym == "" {
		sym = app
	}
	symbols, err := prof.LoadSymbols(sym)
	if err != nil {
		return fail(err)
	}
	traceSess, err := strace.Arm([]uint64{pid}, traceSlots)
	if err != nil {
		return fail(err)
	}
	profToken, err := vi.ProfileStart([]uint64{pid})
	if err != nil {
		_ = traceSess.Disarm()
		return fail(err)
	}
	vi.ConsoleLine(fmt.Sprintf("observe: armed pid=%d app=%s trace=%d profile=%d",
		pid, app, traceSess.Token, profToken))

	// The heap leg keeps M94d's driver verbatim: its own loop joins the
	// in-process post-GC series with the kernel page view at 1/s and
	// reports done at the card's sample floor.
	heapDone := make(chan error, 1)
	go func() { heapDone <- heap.ViewUntil(app, heap.MaxPolls, wantHeapSamples) }()

	report := prof.NewReport()
	start := vi.Nanos()
	saves, traceDropped, profDropped := 0, uint64(0), uint64(0)
	heapFinished := false
	for {
		n, loss, e := drainTrace(traceSess, watch)
		if e != nil {
			return fail(e)
		}
		saves += n
		traceDropped = loss
		loss, e = drainProfile(profToken, report, symbols)
		if e != nil {
			return fail(e)
		}
		profDropped = loss
		var heapErr error
		select {
		case heapErr = <-heapDone:
			heapFinished = true
		default:
		}
		if heapErr != nil {
			return fail(heapErr)
		}
		if saves >= wantSaves && heapFinished {
			break
		}
		if !running(pid) {
			break
		}
		if vi.Nanos()-start > sessionDeadline {
			return fail(fmt.Errorf("deadline: saves=%d heap_done=%v", saves, heapFinished))
		}
		vi.Sleep(pollTicks)
	}
	if e := traceSess.Disarm(); e != nil {
		return fail(e)
	}
	// Disarm retains unread records; drain the tail before summarizing.
	n, loss, e := drainTrace(traceSess, watch)
	if e != nil {
		return fail(e)
	}
	saves += n
	traceDropped = loss
	if e := vi.ProfileStop(profToken); e != nil {
		return fail(e)
	}
	loss, e = drainProfile(profToken, report, symbols)
	if e != nil {
		return fail(e)
	}
	profDropped = loss
	if !heapFinished {
		if heapErr := <-heapDone; heapErr != nil {
			return fail(heapErr)
		}
	}
	report.Dropped = profDropped
	if err := prof.Save(app, report, os.Stdout); err != nil {
		return fail(err)
	}
	// The one summary line the spec's asserts read. The heap leg's own
	// kernel/sample lines (heap: ...) are already on the serial log; the
	// series tail is re-read for the last live byte count.
	live, heapSamples := uint64(0), 0
	if body, rc := vi.ReadFileAll(heap.Path(app), heap.MaxBytes+1); rc >= 0 {
		if rows, e := heap.ParseSeries(body); e == nil && len(rows) != 0 {
			heapSamples = len(rows)
			live = rows[len(rows)-1].LiveBytes
		}
	}
	vi.ConsoleLine(fmt.Sprintf("observe: summary app=%s saves=%d trace_dropped=%d "+
		"profile_samples=%d profile_dropped=%d symbolized_pct=%.2f "+
		"heap_samples=%d heap_live=%d",
		app, saves, traceDropped, report.Samples, profDropped, report.Percent(),
		heapSamples, live))
	vi.ConsoleLine("observe: done")
	return nil
}

// --- combined overhead (ADR 0043 D6 last row) ---------------------------

var sink uint64

//go:noinline
func fixedWork(seed uint64) uint64 {
	for i := uint64(0); i < 80_000_000; i++ {
		seed ^= seed << 13
		seed ^= seed >> 7
		seed ^= seed << 17
	}
	return seed
}

// heapPoll is one kernel-memstat poll — the same timed syscall the
// session leg drives at 1 Hz. In overhead mode it runs inline inside the
// measured window: under GOMAXPROCS=1 (which the fixture pins so the work
// stays single-core) a polling goroutine cannot interleave with a
// CPU-bound loop — the virelai runtime has no signal preemption — so the
// poll's own cost lands inside the on window instead, which is the
// conservative accounting: the full snapshot cost is charged to the
// measured run.
func heapPoll(pid uint64) error {
	kernel, elapsed, err := vi.HeapStatTimed(pid)
	if err != nil {
		return err
	}
	vi.ConsoleLine(fmt.Sprintf("heap: kernel app=OBSERVE.ELF pid=%d pages=%d peak_pages=%d regions=%d static_pages=%d total_pages=%d record_failures=%d cntpct=%d snapshot_ns=%d",
		kernel.PID, kernel.LivePages, kernel.PeakPages, kernel.LiveRegions,
		kernel.StaticPages, kernel.TotalPages, kernel.RecordFailures, kernel.CNTPCT, elapsed))
	return nil
}

// overhead measures M94c's fixed-work kernel with the combined load: 5
// pairs of off/on runs where "on" arms the filtered tracer (empty slot
// mask), the 100 Hz sampler and the heap memstat poll on OBSERVE itself.
func overhead() error {
	runtime.GOMAXPROCS(1)
	row, err := prof.FindTarget("OBSERVE.ELF")
	if err != nil {
		return fail(err)
	}
	pid := row.PID
	var polls uint64

	sink = fixedWork(1)
	const pairs = 5
	var off, on [pairs]int64
	var droppedSamples, droppedRecords uint64
	for i := 0; i < pairs; i++ {
		vi.Sleep(1)
		t0 := vi.Nanos()
		v := fixedWork(1)
		off[i] = vi.Nanos() - t0
		if v != sink || off[i] <= 0 {
			return fail(fmt.Errorf("invalid fixed-work result or clock"))
		}
		vi.ConsoleLine(fmt.Sprintf("observe: work mode=off run=%d ns=%d checksum=%x", i+1, off[i], v))

		traceSess, terr := strace.Arm([]uint64{pid}, []uint64{})
		if terr != nil {
			return fail(terr)
		}
		profToken, perr := vi.ProfileStart([]uint64{pid})
		if perr != nil {
			_ = traceSess.Disarm()
			return fail(perr)
		}
		t0 = vi.Nanos()
		// The heap leg inside the measured window: one memstat poll whose
		// syscalls are themselves filtered trace checks, then the work.
		if e := heapPoll(pid); e != nil {
			return fail(e)
		}
		polls++
		v = fixedWork(1)
		on[i] = vi.Nanos() - t0
		if v != sink || on[i] <= 0 {
			return fail(fmt.Errorf("invalid fixed-work result or clock"))
		}
		vi.ConsoleLine(fmt.Sprintf("observe: work mode=on run=%d ns=%d checksum=%x", i+1, on[i], v))
		if e := vi.ProfileStop(profToken); e != nil {
			return fail(e)
		}
		loss, e := drainProfile(profToken, nil, nil)
		if e != nil {
			return fail(e)
		}
		droppedSamples = loss
		if e := traceSess.Disarm(); e != nil {
			return fail(e)
		}
		// The empty slot mask captures nothing, but the session header's
		// drop counter still has to be drained and reported.
		_, tloss, e := drainTrace(traceSess, "")
		if e != nil {
			return fail(e)
		}
		droppedRecords = tloss
	}
	sortInts := func(v *[pairs]int64) int64 {
		s := append([]int64(nil), v[:]...)
		for i := 1; i < len(s); i++ {
			for j := i; j > 0 && s[j] < s[j-1]; j-- {
				s[j], s[j-1] = s[j-1], s[j]
			}
		}
		return s[len(s)/2]
	}
	ratios := make([]float64, pairs)
	for i := range ratios {
		ratios[i] = float64(on[i]-off[i]) / float64(off[i])
	}
	for i := 1; i < len(ratios); i++ {
		for j := i; j > 0 && ratios[j] < ratios[j-1]; j-- {
			ratios[j], ratios[j-1] = ratios[j-1], ratios[j]
		}
	}
	vi.ConsoleLine(fmt.Sprintf("observe: overhead pairs=%d off_median_ns=%d on_median_ns=%d overhead_pct=%.6f",
		pairs, sortInts(&off), sortInts(&on), 100*ratios[pairs/2]))
	vi.ConsoleLine(fmt.Sprintf("observe: drops sample_dropped=%d trace_dropped=%d heap_polls=%d",
		droppedSamples, droppedRecords, polls))
	vi.ConsoleLine("observe: overhead done")
	return nil
}
