//go:build virelai || pulse

// Command pulse is PULSE.ELF: the Go seat's Charm TUI system monitor.
//
// Like charmhello (M72c) it owns a real tea.Model but does not run Bubble
// Tea's host Program loop: the Virelai port has no POSIX tty or signals, so
// key bytes come from the kernel's bound /dev/tty queue and View's ANSI goes
// back into that bound tty. A 1 Hz app timer (slot 40) drives the snapshot
// refresh; the snapshot layer is the only guest-only part, everything above
// it is pure and host-tested.
package main

import (
	tea "charm.land/bubbletea/v2"
	"virelai/vi"
)

// Tabs of the monitor.
type tab int

const (
	tabOverview tab = iota
	tabProcs
	tabNet
	tabStorage
	tabCount
)

func (t tab) name() string {
	switch t {
	case tabOverview:
		return "Overview"
	case tabProcs:
		return "Processes"
	case tabNet:
		return "Network"
	case tabStorage:
		return "Storage"
	}
	return "?"
}

// procInfo, snapshot and sortCol live in types.go: they are untagged there
// because the host stub and the pure derive layer must see them without the
// pulse tag (see that file's header).

// --- Real utilization (issue #2198, ADR 0047) --------------------------------
//
// The versioned `sys_procs` row arrives through its own seam rather than the
// canned snapshot: snapshot.procs stays the v1 identity view every consumer
// already shares, while usage is the negotiated v2 read — on a v1 kernel or
// any read failure it reports ok=false and the view keeps its honest
// "not exposed" note instead of approximating from process counts.

// procUse is one process's decoded usage.
type procUse struct {
	cpuTicks uint64 // raw scheduler-tick counter (serial evidence)
	cpuX10   uint64 // share of one core, tenths of a percent
	memBytes uint64 // owned resident footprint
}

// procUsage is one poll of the versioned snapshot.
type procUsage struct {
	perProc  map[uint64]procUse // keyed by pid
	cpuX10   uint64             // machine busy share, tenths of a percent
	memUsed  uint64             // summed footprint bytes
	memTotal uint64             // allocator pool bytes (total_pages x 4096)
	ok       bool
}

// usagePoller keeps the previous poll's counters so shares are windowed;
// the first poll has no window and reports the share since boot.
type usagePoller struct {
	prev      map[uint64]uint64
	prevTotal uint64
}

func newUsagePoller() *usagePoller {
	return &usagePoller{prev: make(map[uint64]uint64)}
}

// poll reads the negotiated snapshot. A stream that is not version-2 — a
// pre-0047 kernel's frozen rows — is refused whole: per-process figures all
// or nothing, never a decoded guess.
func (u *usagePoller) poll() procUsage {
	var rows [16]vi.ProcRow
	n, rc := vi.ProcsV2(rows[:])
	if rc < 0 || n == 0 {
		return procUsage{}
	}
	var total, ncores, totalPages uint64
	var out procUsage
	out.perProc = make(map[uint64]procUse, n)
	for i := 0; i < n; i++ {
		r := rows[i]
		if r.RowVer < vi.ProcRowVersion2 {
			return procUsage{}
		}
		if i == 0 {
			total, ncores, totalPages = r.TotalTicks, uint64(r.NCores), r.TotalPages
		}
		out.perProc[r.PID] = procUse{cpuTicks: r.CpuTicks, memBytes: r.MemBytes}
	}
	var sumDelta uint64
	windowed := u.prevTotal > 0 && total > u.prevTotal
	for pid, pu := range out.perProc {
		prev, had := u.prev[pid]
		dCpu, dTot := pu.cpuTicks, total
		if had && windowed && pu.cpuTicks >= prev {
			dCpu, dTot = pu.cpuTicks-prev, total-u.prevTotal
		}
		sumDelta += dCpu
		if dTot > 0 && ncores > 0 {
			pu.cpuX10 = dCpu * 1000 * ncores / dTot
		}
		out.perProc[pid] = pu
		out.memUsed += pu.memBytes
		u.prev[pid] = pu.cpuTicks
	}
	// Machine share: Σ per-process deltas over the window's machine ticks
	// (or the counters' whole life on the first poll) — same denominator
	// family as the per-row figures.
	dTotMachine := total
	if windowed {
		dTotMachine = total - u.prevTotal
	}
	if dTotMachine > 0 {
		out.cpuX10 = sumDelta * 1000 / dTotMachine
	}
	out.memTotal = totalPages * 4096
	out.ok = true
	u.prevTotal = total
	return out
}

type model struct {
	tab       tab
	snap      snapshot
	ticks     uint64
	sel       int
	sortCol   sortCol
	filter    string
	filtering bool
	confirm   bool
	notice    string
	help      bool
	quit      bool
	killFn    func(pid uint64) int64
	snapFn    func() snapshot
	usage     procUsage
	usageFn   func() procUsage
}

func newModel(killFn func(uint64) int64, snapFn func() snapshot) model {
	m := model{killFn: killFn, snapFn: snapFn, usageFn: newUsagePoller().poll}
	m.refresh()
	return m
}

// refresh takes a fresh snapshot and re-clamps the selection.
func (m *model) refresh() {
	if m.snapFn == nil {
		return
	}
	m.snap = m.snapFn()
	if m.usageFn != nil {
		m.usage = m.usageFn()
	}
	m.ticks++
	m.clampSel()
}

func (m *model) clampSel() {
	n := len(visibleProcs(m.snap, m.sortCol, m.filter))
	if n == 0 {
		m.sel = 0
		return
	}
	if m.sel < 0 {
		m.sel = 0
	}
	if m.sel >= n {
		m.sel = n - 1
	}
}

// Init is intentionally command-free: Virelai feeds key bytes from main.
func (model) Init() tea.Cmd { return nil }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return m, nil
	}
	m.handleKey(key.Key().Text)
	return m, nil
}

func keyPress(b byte) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Text: string([]byte{b}), Code: rune(b)})
}
