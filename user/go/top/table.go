// Package main — GOTOP's process table (the pure, host-testable half).
//
// This is the Go port of the model in user/src/top.zig (which the M71g card
// retires): one `sys_procs` snapshot, a stable sort over the active column,
// selection preserved by pid across refreshes, and TOP's auto-select rule
// (the first RUNNING row) so `k` targets a live process by default rather than
// whatever happens to sit first. Zig's own host tests pin the same behaviours;
// table_test.go pins them here.
package main

import "virelai/vi"

// maxProcs bounds one snapshot. It is Zig TOP's max_display_procs (16 rows,
// 640 bytes of scratch) — the kernel floors a larger request to whole rows,
// so a bigger buffer would only be ignored.
const maxProcs = 16

// Column is a sort axis (TOP's C8 columns).
type Column int

const (
	ColPID Column = iota
	ColName
	ColState
	ColExit
	ColCPU
	ColMem
)

// Label is the column's header text.
func (c Column) Label() string {
	switch c {
	case ColName:
		return "Name"
	case ColState:
		return "State"
	case ColExit:
		return "Exit"
	case ColCPU:
		return "CPU%"
	case ColMem:
		return "MEM"
	}
	return "PID"
}

// StateName renders a process state code the way TOP did.
func StateName(state uint64) string {
	switch state {
	case vi.ProcCreated:
		return "created"
	case vi.ProcRunning:
		return "running"
	case vi.ProcExited:
		return "exited"
	}
	return "unknown"
}

// Proc is one decoded snapshot row. CpuTicks/MemBytes/HasUsage are the ADR
// 0047 v2 fields; CpuX10 is the derived share of one core in tenths of a
// percent (windowed against the previous snapshot, else the share since
// boot — both come straight from kernel tick accounting).
type Proc struct {
	PID      uint64
	State    uint64
	Exit     uint64
	Name     string
	CpuTicks uint64
	CpuX10   uint64
	MemBytes uint64
	HasUsage bool
}

// Table is the live process view.
type Table struct {
	raw   []vi.ProcRow // snapshot scratch (never reallocated)
	rows  []Proc       // decoded, in snapshot (id) order
	order []int        // display order: indices into rows, filtered + sorted
	sel   int          // index into order; -1 = nothing selected
	col   Column
	asc   bool

	// filter is the live name substring (TOP.BIN's C8 filter, restored by
	// issue #2197). "" shows every row.
	filter string

	// Usage state (ADR 0047): set when the snapshot carried v2 rows. cpuX10
	// is the machine-wide busy share in tenths of a percent, memUsed the
	// summed footprint, memTotal the pool size in bytes.
	usage     bool
	cpuX10    uint64
	memUsed   uint64
	memTotal  uint64
	ncores    uint64
	prevCpu   map[uint64]uint64
	prevTotal uint64

	// self and seats are what the DEFAULT aim skips — see defaultAim.
	self  string
	seats []string
}

// NewTable builds an empty table with TOP's defaults (sort by pid ascending)
// and this app's own name as the self row the default aim avoids.
func NewTable() *Table {
	return &Table{
		raw:     make([]vi.ProcRow, maxProcs),
		rows:    make([]Proc, 0, maxProcs),
		order:   make([]int, 0, maxProcs),
		sel:     -1,
		col:     ColPID,
		asc:     true,
		self:    appName,
		seats:   vi.WMProcNames[:],
		prevCpu: make(map[uint64]uint64),
	}
}

// Refresh takes one snapshot (slot 7) and rebuilds the view. rc < 0 means the
// kernel refused (EINVAL/EFAULT, or -ENOSYS off the guest) and the previous
// view is kept — the caller prints the error instead of inventing a table.
//
// The read negotiates the versioned row (ADR 0047): on a v2 kernel every row
// reports real tick and footprint figures; on a v1 kernel (or any stream the
// decoder cannot trust) the usage fields stay zero and the table renders
// exactly the frozen four-column view it always did.
func (t *Table) Refresh() (int, int64) {
	n, rc := vi.ProcsV2(t.raw)
	if rc < 0 {
		return 0, rc
	}
	// Capture the aim BEFORE the rows are replaced: SelPID reads the display
	// order, which is only valid against the snapshot it was built from.
	prevPID, hadPrev := t.SelPID()
	if n > len(t.raw) {
		n = len(t.raw)
	}
	t.rows = t.rows[:0]
	t.usage = false
	for i := 0; i < n; i++ {
		r := t.raw[i]
		p := Proc{PID: r.PID, State: r.State, Exit: r.ExitStatus, Name: r.Name()}
		if r.RowVer >= vi.ProcRowVersion2 {
			p.CpuTicks, p.MemBytes, p.HasUsage = r.CpuTicks, r.MemBytes, true
			t.usage = true
			t.ncores = uint64(r.NCores)
			t.memTotal = r.TotalPages * 4096
		}
		t.rows = append(t.rows, p)
	}
	t.deriveUsage(n)
	t.rebuildWith(prevPID, hadPrev)
	return n, rc
}

// deriveUsage turns the raw tick counters into shares. Per-row CpuX10 is
// tenths of a percent of ONE core: delta_ticks * ncores * 1000 / delta_total
// over the window between snapshots; on the first usable snapshot there is
// no window, so the share is the same formula over the counters' whole life
// (cpu_ticks / total_ticks since boot). Both are pure scheduler accounting —
// never wall-clock inference. cpuX10 is the machine-wide busy share: sum of
// all process deltas over the same window, i.e. ΣΔcpu * 1000 / Δtotal.
func (t *Table) deriveUsage(n int) {
	if !t.usage {
		t.cpuX10, t.memUsed = 0, 0
		return
	}
	t.memUsed = 0
	var total uint64
	// TotalTicks is identical on every v2 row; grab it from the first.
	for i := 0; i < n && i < len(t.raw); i++ {
		if t.raw[i].RowVer >= vi.ProcRowVersion2 {
			total = t.raw[i].TotalTicks
			break
		}
	}
	var sumDelta uint64
	windowed := t.prevTotal > 0 && total > t.prevTotal
	for i := range t.rows {
		p := &t.rows[i]
		t.memUsed += p.MemBytes
		prev, had := t.prevCpu[p.PID]
		dCpu := p.CpuTicks
		dTot := total
		if had && windowed && p.CpuTicks >= prev {
			dCpu = p.CpuTicks - prev
			dTot = total - t.prevTotal
		}
		sumDelta += dCpu
		if dTot > 0 && t.ncores > 0 {
			p.CpuX10 = dCpu * 1000 * t.ncores / dTot
		} else {
			p.CpuX10 = 0
		}
		t.prevCpu[p.PID] = p.CpuTicks
	}
	// The machine share uses the same denominator family as the rows: the
	// window's total when a window exists, else the counters' whole life.
	dTotMachine := total
	if windowed {
		dTotMachine = total - t.prevTotal
	}
	if dTotMachine > 0 {
		t.cpuX10 = sumDelta * 1000 / dTotMachine
	} else {
		t.cpuX10 = 0
	}
	t.prevTotal = total
}

// Rebuild re-sorts the display order and restores the selection. Callers that
// changed rows must use Refresh; Rebuild assumes rows and order agree.
func (t *Table) Rebuild() {
	prevPID, hadPrev := t.SelPID()
	t.rebuildWith(prevPID, hadPrev)
}

// rebuildWith sorts the display order and restores the selection.
//
// The sort is TOP's: a stable insertion sort, so two rows with equal keys keep
// their snapshot (id) order. The selection is preserved by PID — the row the
// user aimed at stays aimed at even if its position moved — and when nothing
// is selected yet, or the selected process vanished, TOP's fallback picks the
// first RUNNING row in display order.
func (t *Table) rebuildWith(prevPID uint64, hadPrev bool) {
	t.order = t.order[:0]
	for i := range t.rows {
		if !nameContains(t.rows[i].Name, t.filter) {
			continue
		}
		t.order = append(t.order, i)
	}
	for j := 1; j < len(t.order); j++ {
		key := t.order[j]
		k := j
		for k > 0 && t.shouldShift(t.order[k-1], key) {
			t.order[k] = t.order[k-1]
			k--
		}
		t.order[k] = key
	}
	t.sel = -1
	if hadPrev {
		for i, idx := range t.order {
			if t.rows[idx].PID == prevPID {
				t.sel = i
				break
			}
		}
	}
	if t.sel < 0 {
		t.sel = t.defaultAim()
	}
}

// shouldShift reports whether prev must move after cur under the active sort.
func (t *Table) shouldShift(prev, cur int) bool {
	c := compareProcs(t.rows[prev], t.rows[cur], t.col)
	if t.asc {
		return c > 0
	}
	return c < 0
}

// defaultAim is the auto-select fallback: the first RUNNING row that is not a
// window-manager seat and not this app itself.
//
// TOP.BIN's rule was literally "first running", which was correct in every boot
// TOP ever ran in: its specs start no seat, so pid 1 was the process under
// test. On the Go seat that rule aims at the seat — MEASURED under
// `tabwm start` (go-top.spec's first run): the table read
// pid 0 user-el0 exited / pid 1 TABWM.BIN running / pid 2 COUNTER.BIN running /
// pid 3 GOTOP.ELF running, and `k` armed pid 1, killing the window manager
// (`procs TABWM.BIN exited status=137`). A task manager's DEFAULT aim is
// therefore a plain running process: never the seat hosting its window, never
// itself (self-kill is legal at the ABI, and being pre-armed on yourself is a
// footgun). Both remain selectable by hand.
//
// With no seat and no self row this is exactly TOP's rule, which is why the
// seatless specs (live-sys-kill, live-trust-caps) keep their old target.
func (t *Table) defaultAim() int {
	for i, idx := range t.order {
		p := t.rows[idx]
		if p.State != vi.ProcRunning {
			continue
		}
		if p.Name == t.self || t.isSeat(p.Name) {
			continue
		}
		return i
	}
	return -1
}

// isSeat reports whether a process name is a window-manager seat.
func (t *Table) isSeat(name string) bool {
	for _, s := range t.seats {
		if name == s {
			return true
		}
	}
	return false
}

// compareProcs is TOP's stable comparator (-1 a<b, 1 a>b, 0 equal).
func compareProcs(a, b Proc, col Column) int {
	switch col {
	case ColName:
		return compareNameIgnoreCase(a.Name, b.Name)
	case ColState:
		return compareU64(a.State, b.State)
	case ColExit:
		return compareU64(a.Exit, b.Exit)
	case ColCPU:
		return compareU64(a.CpuX10, b.CpuX10)
	case ColMem:
		return compareU64(a.MemBytes, b.MemBytes)
	}
	return compareU64(a.PID, b.PID)
}

func compareU64(a, b uint64) int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

func asciiLower(c byte) byte {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

// compareNameIgnoreCase is top.zig's name_cmp_ignore_case: case-insensitive,
// shorter-prefix-first.
func compareNameIgnoreCase(a, b string) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	for i := 0; i < n; i++ {
		la, lb := asciiLower(a[i]), asciiLower(b[i])
		if la < lb {
			return -1
		}
		if la > lb {
			return 1
		}
	}
	if len(a) < len(b) {
		return -1
	}
	if len(a) > len(b) {
		return 1
	}
	return 0
}

// Len is the number of decoded rows.
func (t *Table) Len() int { return len(t.order) }

// Row returns the display row at index i.
func (t *Table) Row(i int) (Proc, bool) {
	if i < 0 || i >= len(t.order) {
		return Proc{}, false
	}
	idx := t.order[i]
	if idx < 0 || idx >= len(t.rows) {
		return Proc{}, false
	}
	return t.rows[idx], true
}

// Selected is the highlighted row.
func (t *Table) Selected() (Proc, bool) { return t.Row(t.sel) }

// SelIndex is the highlighted display index (-1 = none).
func (t *Table) SelIndex() int { return t.sel }

// SelPID is the highlighted pid, for selection preservation across refreshes.
func (t *Table) SelPID() (uint64, bool) {
	if p, ok := t.Selected(); ok {
		return p.PID, true
	}
	return 0, false
}

// SelectRow highlights display row i (a row click). It reports whether the
// selection actually moved, so the caller can skip a needless repaint.
func (t *Table) SelectRow(i int) bool {
	if i < 0 || i >= len(t.order) || i == t.sel {
		return false
	}
	t.sel = i
	return true
}

// MoveBy walks the selection by delta rows (the arrow keys / wheel).
func (t *Table) MoveBy(delta int) bool {
	if len(t.order) == 0 {
		return false
	}
	next := t.sel + delta
	if t.sel < 0 {
		next = 0
	}
	if next < 0 {
		next = 0
	}
	if next >= len(t.order) {
		next = len(t.order) - 1
	}
	if next == t.sel {
		return false
	}
	t.sel = next
	return true
}

// SetFilter is TOP's C8 text filter restored (issue #2197): the display view
// narrows to rows whose name contains the text, case-insensitively, and an
// empty string shows the whole table again. It applies live — the same
// rebuild a sort uses — so the selection keeps its pid while the row still
// matches and falls back to the usual default aim when it does not.
func (t *Table) SetFilter(s string) {
	if s == t.filter {
		return
	}
	t.filter = s
	t.Rebuild()
}

// Filter is the active substring ("" = unfiltered).
func (t *Table) Filter() string { return t.filter }

// nameContains is top.zig's name_contains: a case-insensitive substring test
// where the empty needle matches everything.
func nameContains(haystack, needle string) bool {
	if needle == "" {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		ok := true
		for j := 0; j < len(needle); j++ {
			if asciiLower(haystack[i+j]) != asciiLower(needle[j]) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// SortBy activates a column: the same column flips direction, a new one starts
// ascending (TOP's click_column).
func (t *Table) SortBy(col Column) {
	if t.col == col {
		t.asc = !t.asc
	} else {
		t.col = col
		t.asc = true
	}
	t.Rebuild()
}

// SortColumn/SortAscending describe the active sort for the header.
func (t *Table) SortColumn() Column  { return t.col }
func (t *Table) SortAscending() bool { return t.asc }

// Counts is (running, exited, total) over the snapshot.
func (t *Table) Counts() (int, int, int) {
	running, exited := 0, 0
	for _, r := range t.rows {
		switch r.State {
		case vi.ProcRunning:
			running++
		case vi.ProcExited:
			exited++
		}
	}
	return running, exited, len(t.rows)
}

// Labels renders the visible rows for the list widget (display order).
func (t *Table) Labels() []string {
	out := make([]string, len(t.order))
	for i, idx := range t.order {
		out[i] = rowLabel(t.rows[idx])
	}
	return out
}

// Usage reports the snapshot's machine totals: aggregate busy share in
// tenths of a percent, summed footprint bytes, the memory pool bytes, and
// whether the last snapshot carried v2 figures at all (false on a v1
// kernel — the summary must say nothing it cannot prove).
func (t *Table) Usage() (cpuX10, memUsed, memTotal uint64, ok bool) {
	return t.cpuX10, t.memUsed, t.memTotal, t.usage
}

// rowLabel is one process row: "  1  COUNTER.BIN    running  -", extended
// with "  CPU%   MEM" columns only when the row carries v2 figures — a v1
// snapshot renders byte-identically to before ADR 0047.
func rowLabel(p Proc) string {
	name := p.Name
	if len(name) > 14 {
		name = name[:14]
	}
	exit := "-"
	if p.State == vi.ProcExited {
		exit = vi.Itoa64(int64(p.Exit))
	}
	base := padLeft(vi.Itoa64(int64(p.PID)), 3) + "  " + padRight(name, 14) +
		" " + padRight(StateName(p.State), 7) + " " + exit
	if !p.HasUsage {
		return base
	}
	return base + spaces(4-len(exit)) + "  " + padRight(pctX10Text(p.CpuX10), 5) +
		" " + memText(p.MemBytes)
}

// pctX10Text renders tenths of a percent ("250" -> "25.0", guest-safe).
func pctX10Text(x10 uint64) string {
	if x10 > 9999 {
		x10 = 9999
	}
	return vi.Itoa64(int64(x10/10)) + "." + vi.Itoa64(int64(x10%10))
}

// memText renders a byte footprint in binary units, integer-only.
func memText(b uint64) string {
	if b < 1024 {
		return vi.Itoa64(int64(b)) + "B"
	}
	if b < 10*1024*1024 {
		return vi.Itoa64(int64(b/1024)) + "K"
	}
	return vi.Itoa64(int64(b/(1024*1024))) + "M"
}

// Header is the column header line, with the active sort marked.
func (t *Table) Header() string {
	mark := "^"
	if !t.asc {
		mark = "v"
	}
	h := padLeft("PID", 3) + "  " + padRight("Name", 14) + " " + padRight("State", 7) + " " + padRight("Exit", 4)
	if t.usage {
		h += "  " + padRight("CPU%", 5) + " " + padRight("MEM", 8)
	}
	tag := "exit"
	switch t.col {
	case ColPID:
		tag = "pid"
	case ColName:
		tag = "name"
	case ColState:
		tag = "state"
	case ColCPU:
		tag = "cpu"
	case ColMem:
		tag = "mem"
	}
	return h + " " + mark + tag
}

// padRight pads s to width w with spaces (never truncates).
func padRight(s string, w int) string {
	if len(s) >= w {
		return s
	}
	return s + spaces(w-len(s))
}

// padLeft left-pads s to width w with spaces (never truncates).
func padLeft(s string, w int) string {
	if len(s) >= w {
		return s
	}
	return spaces(w-len(s)) + s
}

// spaces is a bounded run of spaces (guest-safe: no fmt, no repeated concat).
func spaces(n int) string {
	const pad = "                                " // 32
	if n <= 0 {
		return ""
	}
	if n > len(pad) {
		n = len(pad)
	}
	return pad[:n]
}

// joinSpaced concatenates parts with a single space (guest-safe).
func joinSpaced(parts ...string) string {
	out := ""
	for i, p := range parts {
		if i > 0 {
			out += " "
		}
		out += p
	}
	return out
}
