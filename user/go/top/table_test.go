package main

import (
	"testing"
	"unsafe"

	"virelai/vi"
)

// fakeProcs installs a slot-7 hook serving rows, and returns a pointer to the
// served table so a test can mutate it between refreshes.
func fakeProcs(t *testing.T, rows []vi.ProcRow) *[]vi.ProcRow {
	t.Helper()
	table := &rows
	prev := vi.SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != vi.SlotProcs {
			t.Fatalf("unexpected slot %d", num)
		}
		buf := unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1)
		n := 0
		for _, r := range *table {
			off := n * vi.ProcRowSize
			putU64(buf[off:], r.PID)
			putU64(buf[off+8:], r.State)
			putU64(buf[off+16:], r.ExitStatus)
			copy(buf[off+24:off+40], r.NameBuf[:])
			n++
		}
		return int64(n)
	})
	t.Cleanup(func() { vi.SetSyscallHookForTest(prev) })
	return table
}

func putU64(b []byte, v uint64) {
	for i := 0; i < 8; i++ {
		b[i] = byte(v >> (8 * i))
	}
}

func namedRow(pid, state, exit uint64, name string) vi.ProcRow {
	r := vi.ProcRow{PID: pid, State: state, ExitStatus: exit}
	copy(r.NameBuf[:], name)
	return r
}

// TestDefaultSortIsPIDAndAutoSelectsAimableRunningRow pins the two defaults
// that make `k` target a process without any click: TOP's pid-ascending sort
// and the default-aim fallback, which skips the seat and this app itself.
func TestDefaultSortIsPIDAndAutoSelectsAimableRunningRow(t *testing.T) {
	fakeProcs(t, []vi.ProcRow{
		namedRow(0, vi.ProcExited, 7, "user-el0"),
		namedRow(1, vi.ProcRunning, 0, "TABWM.BIN"),
		namedRow(2, vi.ProcRunning, 0, "COUNTER.BIN"),
		namedRow(3, vi.ProcRunning, 0, "GOTOP.ELF"),
	})
	tab := NewTable()
	if n, rc := tab.Refresh(); rc < 0 || n != 4 {
		t.Fatalf("refresh n=%d rc=%d", n, rc)
	}
	if tab.SortColumn() != ColPID || !tab.SortAscending() {
		t.Fatalf("default sort = col %v asc=%v, want PID ascending", tab.SortColumn(), tab.SortAscending())
	}
	// Rows are pid-ascending: 0 (exited), 1 TABWM.BIN, 2 COUNTER.BIN,
	// 3 GOTOP.ELF. The first running row is the SEAT; the aim must skip it and
	// this app, landing on COUNTER.BIN — the measured go-top failure this rule
	// exists for.
	p, ok := tab.Selected()
	if !ok || p.PID != 2 {
		t.Fatalf("auto-select = %+v ok=%v, want pid 2 (COUNTER.BIN)", p, ok)
	}
	if p, _ := tab.Selected(); p.Name == "GOTOP.ELF" {
		t.Fatal("the default aim must not be this app itself")
	}
}

// TestDefaultAimMatchesTOPRuleWithoutASeat is the seatless parity case:
// with no seat row and no self row, the first running row wins — TOP.BIN's
// literal rule, which live-sys-kill and live-trust-caps depend on.
func TestDefaultAimMatchesTOPRuleWithoutASeat(t *testing.T) {
	fakeProcs(t, []vi.ProcRow{
		namedRow(1, vi.ProcRunning, 0, "COUNTER.BIN"),
	})
	tab := NewTable()
	tab.Refresh()
	if p, ok := tab.Selected(); !ok || p.PID != 1 {
		t.Fatalf("seatless aim = %+v ok=%v, want pid 1", p, ok)
	}
}

// TestDefaultAimRefusesWhenOnlySeatsAndSelfRemain: nothing aimable means no
// selection, so `k` is inert rather than aimed at the window manager.
func TestDefaultAimRefusesWhenOnlySeatsAndSelfRemain(t *testing.T) {
	fakeProcs(t, []vi.ProcRow{
		namedRow(1, vi.ProcRunning, 0, "TABWM.BIN"),
		namedRow(2, vi.ProcRunning, 0, "GOTOP.ELF"),
	})
	tab := NewTable()
	tab.Refresh()
	if _, ok := tab.Selected(); ok {
		t.Fatal("a seat-only table must leave the default aim unset")
	}
	// The seat is still reachable by hand (an explicit click/arrow aims at it)
	// and survives the next refresh: the skip is a default, not a lock.
	if !tab.SelectRow(0) {
		t.Fatal("explicit selection of the seat row must be allowed")
	}
	if p, _ := tab.Selected(); p.Name != "TABWM.BIN" {
		t.Fatalf("explicit aim = %+v", p)
	}
	tab.Refresh()
	if p, _ := tab.Selected(); p.Name != "TABWM.BIN" {
		t.Fatalf("refresh stole the explicit aim: %+v", p)
	}
}

// TestSelectionSurvivesRefreshByPID pins that a re-snapshot does not move the
// user's aim: the selected pid keeps the selection wherever it sorted to.
func TestSelectionSurvivesRefreshByPID(t *testing.T) {
	rows := fakeProcs(t, []vi.ProcRow{
		namedRow(1, vi.ProcRunning, 0, "COUNTER.BIN"),
		namedRow(2, vi.ProcRunning, 0, "GOTOP.ELF"),
	})
	tab := NewTable()
	tab.Refresh()
	tab.SelectRow(1) // aim at pid 2
	if p, _ := tab.Selected(); p.PID != 2 {
		t.Fatalf("aim = pid %d, want 2", p.PID)
	}
	(*rows)[0] = namedRow(1, vi.ProcExited, 137, "COUNTER.BIN")
	tab.Refresh()
	if p, _ := tab.Selected(); p.PID != 2 {
		t.Fatalf("selection drifted to pid %d across a refresh", p.PID)
	}
}

// TestVanishedSelectionFallsBackToFirstRunning: when the selected process is
// gone, the fallback re-arms on a running row rather than leaving the kill
// button pointed at nothing.
func TestVanishedSelectionFallsBackToFirstRunning(t *testing.T) {
	rows := fakeProcs(t, []vi.ProcRow{
		namedRow(1, vi.ProcRunning, 0, "COUNTER.BIN"),
		namedRow(2, vi.ProcRunning, 0, "GOTOP.ELF"),
	})
	tab := NewTable()
	tab.Refresh()
	tab.SelectRow(1)
	*rows = []vi.ProcRow{namedRow(3, vi.ProcRunning, 0, "LATE.BIN")}
	tab.Refresh()
	p, ok := tab.Selected()
	if !ok || p.PID != 3 {
		t.Fatalf("fallback = %+v ok=%v, want the surviving pid 3", p, ok)
	}
}

// TestSortByTogglesAndIsStable pins the sort: a new column starts ascending, a
// repeat flips it, and equal keys keep their snapshot (id) order — Zig's stable
// insertion sort, which is what keeps the list from dancing between refreshes.
func TestSortByTogglesAndIsStable(t *testing.T) {
	fakeProcs(t, []vi.ProcRow{
		namedRow(1, vi.ProcRunning, 0, "zeta.bin"),
		namedRow(2, vi.ProcRunning, 0, "alpha.bin"),
		namedRow(3, vi.ProcRunning, 0, "alpha.bin"), // equal key, later id
	})
	tab := NewTable()
	tab.Refresh()
	tab.SortBy(ColName)
	if got := orderNames(tab); got != "alpha.bin,alpha.bin,zeta.bin" {
		t.Fatalf("name asc = %s", got)
	}
	if tab.SortColumn() != ColName || !tab.SortAscending() {
		t.Fatal("SortBy must start ascending on a new column")
	}
	tab.SortBy(ColName)
	if tab.SortAscending() {
		t.Fatal("SortBy on the active column must flip direction")
	}
	if got := orderNames(tab); got != "zeta.bin,alpha.bin,alpha.bin" {
		t.Fatalf("name desc = %s", got)
	}
	// Stability: ascending again puts the two alpha rows back in id order.
	tab.SortBy(ColName)
	if got := orderPIDs(tab); got != "2,3,1" {
		t.Fatalf("stable order = %s, want 2,3,1", got)
	}
}

func orderNames(t *Table) string {
	out := ""
	for i := 0; i < t.Len(); i++ {
		p, _ := t.Row(i)
		if i > 0 {
			out += ","
		}
		out += p.Name
	}
	return out
}

func orderPIDs(t *Table) string {
	out := ""
	for i := 0; i < t.Len(); i++ {
		p, _ := t.Row(i)
		if i > 0 {
			out += ","
		}
		out += vi.Itoa64(int64(p.PID))
	}
	return out
}

// TestMoveByClampsAtBothEnds pins arrow-key behaviour: no wrap, no panic.
func TestMoveByClampsAtBothEnds(t *testing.T) {
	fakeProcs(t, []vi.ProcRow{
		namedRow(1, vi.ProcRunning, 0, "A.BIN"),
		namedRow(2, vi.ProcRunning, 0, "B.BIN"),
	})
	tab := NewTable()
	tab.Refresh()
	tab.SelectRow(0)
	if tab.MoveBy(-1) {
		t.Fatal("MoveBy(-1) at the top must report no change")
	}
	if !tab.MoveBy(1) {
		t.Fatal("MoveBy(1) must move")
	}
	if p, _ := tab.Selected(); p.PID != 2 {
		t.Fatalf("after MoveBy(1) = pid %d, want 2", p.PID)
	}
	if tab.MoveBy(1) {
		t.Fatal("MoveBy(1) at the bottom must report no change")
	}
	tab.MoveBy(-9)
	if p, _ := tab.Selected(); p.PID != 1 {
		t.Fatalf("clamped = pid %d, want 1", p.PID)
	}
}

// TestEmptyTableHasNoSelection keeps the kill path honest on an empty (or
// refused) snapshot.
func TestEmptyTableHasNoSelection(t *testing.T) {
	fakeProcs(t, nil)
	tab := NewTable()
	if n, rc := tab.Refresh(); n != 0 || rc < 0 {
		t.Fatalf("empty refresh n=%d rc=%d", n, rc)
	}
	if _, ok := tab.Selected(); ok {
		t.Fatal("an empty table must report no selection")
	}
	if tab.MoveBy(1) {
		t.Fatal("MoveBy on an empty table must not move")
	}
}

// TestRefusedSnapshotKeepsThePreviousView: a kernel refusal (or a host build)
// must not blank the list.
func TestRefusedSnapshotKeepsThePreviousView(t *testing.T) {
	vi.SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return -vi.ErrEINVAL })
	t.Cleanup(func() { vi.SetSyscallHookForTest(nil) })
	tab := NewTable()
	if _, rc := tab.Refresh(); rc >= 0 {
		t.Fatalf("refusal rc=%d, want negative", rc)
	}
	if tab.Len() != 0 {
		t.Fatalf("refused refresh produced %d rows", tab.Len())
	}
}

// TestRowLabelAndHeaderPin the rendered columns, so the header the user clicks
// and the rows beneath it describe the same grid.
func TestRowLabelAndHeaderPin(t *testing.T) {
	cases := []struct {
		in   Proc
		want string
	}{
		{Proc{PID: 1, State: vi.ProcRunning, Name: "COUNTER.BIN"}, "  1  COUNTER.BIN    running -"},
		{Proc{PID: 12, State: vi.ProcExited, Exit: 137, Name: "GOTOP.ELF"}, " 12  GOTOP.ELF      exited  137"},
		{Proc{PID: 3, State: vi.ProcCreated, Name: "A_VERY_LONG_NAME.BIN"}, "  3  A_VERY_LONG_NA created -"},
	}
	for _, c := range cases {
		if got := rowLabel(c.in); got != c.want {
			t.Fatalf("rowLabel(%+v) = %q, want %q", c.in, got, c.want)
		}
	}
	tab := NewTable()
	if got := tab.Header(); got != "PID  Name           State   Exit ^pid" {
		t.Fatalf("header = %q", got)
	}
	tab.SortBy(ColExit)
	tab.SortBy(ColExit)
	if got := tab.Header(); got != "PID  Name           State   Exit vexit" {
		t.Fatalf("header after exit-desc = %q", got)
	}
}

// TestComparatorIgnoresNameCase mirrors top.zig's name_cmp_ignore_case.
func TestComparatorIgnoresNameCase(t *testing.T) {
	a := Proc{Name: "zeta.bin"}
	b := Proc{Name: "Alpha.bin"}
	if compareProcs(a, b, ColName) <= 0 {
		t.Fatal("zeta must sort after Alpha")
	}
	if compareProcs(b, a, ColName) >= 0 {
		t.Fatal("Alpha must sort before zeta")
	}
	if compareProcs(b, b, ColName) != 0 {
		t.Fatal("equal names must compare equal")
	}
	if compareProcs(Proc{PID: 2}, Proc{PID: 1}, ColPID) <= 0 {
		t.Fatal("pid 2 must sort after pid 1")
	}
}

// --- The filter (issue #2197) --------------------------------------------------

// TestNameContainsTable mirrors top.zig's name_contains host test verbatim:
// case-insensitive substring, empty needle matches all, needle longer than
// the name never matches.
func TestNameContainsTable(t *testing.T) {
	cases := []struct {
		haystack, needle string
		want             bool
	}{
		{"HELLO.BIN", "", true},
		{"HELLO.BIN", "hello", true},
		{"HELLO.BIN", "llo", true},
		{"HELLO.BIN", "world", false},
		{"Calc.BIN", "calc", true},
		{"A", "AB", false},
	}
	for _, c := range cases {
		if got := nameContains(c.haystack, c.needle); got != c.want {
			t.Fatalf("nameContains(%q, %q) = %v, want %v", c.haystack, c.needle, got, c.want)
		}
	}
}

// TestSetFilterNarrowsDisplayByNameSubstring is the Go port of Zig's "AppState
// text filter and sort+filter" test: the display view narrows live to the
// matching names, and an empty needle restores the whole table.
func TestSetFilterNarrowsDisplayByNameSubstring(t *testing.T) {
	fakeProcs(t, []vi.ProcRow{
		namedRow(0, vi.ProcRunning, 0, "VIEW.BIN"),
		namedRow(1, vi.ProcRunning, 0, "NOTEPAD.BIN"),
		namedRow(2, vi.ProcRunning, 0, "TOP.BIN"),
		namedRow(3, vi.ProcRunning, 0, "FILE.BIN"),
	})
	tab := NewTable()
	tab.Refresh()
	tab.SetFilter("top")
	if tab.Len() != 1 {
		t.Fatalf("filter 'top' left %d rows, want 1", tab.Len())
	}
	if p, _ := tab.Row(0); p.Name != "TOP.BIN" {
		t.Fatalf("filtered row = %+v, want TOP.BIN", p)
	}
	// Sort composes with the filter (TOP.BIN's C8 pair).
	tab.SetFilter("bin")
	tab.SortBy(ColName)
	if got := orderPIDs(tab); got != "3,1,2,0" {
		t.Fatalf("filtered name-sort order = %s, want 3,1,2,0", got)
	}
	// Clearing the filter restores the full list.
	tab.SetFilter("")
	if tab.Len() != 4 {
		t.Fatalf("cleared filter left %d rows, want 4", tab.Len())
	}
}

// TestFilterPreservesSelectionByPID: a row that still matches keeps the aim.
func TestFilterPreservesSelectionByPID(t *testing.T) {
	fakeProcs(t, []vi.ProcRow{
		namedRow(1, vi.ProcRunning, 0, "ALPHA.BIN"),
		namedRow(2, vi.ProcRunning, 0, "BETA.BIN"),
		namedRow(3, vi.ProcRunning, 0, "GAMMA.BIN"),
	})
	tab := NewTable()
	tab.Refresh()
	tab.SelectRow(1) // aim at BETA.BIN
	tab.SetFilter("ta.bin")
	if p, ok := tab.Selected(); !ok || p.PID != 2 {
		t.Fatalf("filtered aim = %+v ok=%v, want pid 2 (BETA.BIN)", p, ok)
	}
}

// TestFilteredOutSelectionFallsBackToDefaultAim: when the aimed row no longer
// matches, the fallback picks the first running aimable row in the NARROWED
// view — not a hidden row, not nothing.
func TestFilteredOutSelectionFallsBackToDefaultAim(t *testing.T) {
	fakeProcs(t, []vi.ProcRow{
		namedRow(1, vi.ProcRunning, 0, "ALPHA.BIN"),
		namedRow(2, vi.ProcRunning, 0, "BETA.BIN"),
		namedRow(3, vi.ProcRunning, 0, "GAMMA.BIN"),
	})
	tab := NewTable()
	tab.Refresh()
	tab.SelectRow(0) // aim at ALPHA.BIN
	tab.SetFilter("gamma")
	p, ok := tab.Selected()
	if !ok || p.PID != 3 {
		t.Fatalf("fallback = %+v ok=%v, want the surviving pid 3", p, ok)
	}
}

// TestFilterSurvivesRefresh: the needle is a view property — a new snapshot
// re-applies it, exactly like Zig's rebuild_display on timer refresh.
func TestFilterSurvivesRefresh(t *testing.T) {
	rows := fakeProcs(t, []vi.ProcRow{
		namedRow(1, vi.ProcRunning, 0, "ALPHA.BIN"),
		namedRow(2, vi.ProcRunning, 0, "BETA.BIN"),
	})
	tab := NewTable()
	tab.Refresh()
	tab.SetFilter("alpha")
	*rows = append(*rows, namedRow(3, vi.ProcRunning, 0, "ALPHA2.BIN"),
		namedRow(4, vi.ProcRunning, 0, "DELTA.BIN"))
	tab.Refresh()
	if tab.Len() != 2 {
		t.Fatalf("post-refresh filtered view = %d rows, want 2", tab.Len())
	}
	if got := orderNames(tab); got != "ALPHA.BIN,ALPHA2.BIN" {
		t.Fatalf("filtered rows = %s", got)
	}
	if tab.Filter() != "alpha" {
		t.Fatalf("filter = %q", tab.Filter())
	}
}

// TestFilterMatchesNothingYieldsEmptyView: a needle no row matches empties
// the list and disarms selection — it does not panic and does not lie.
func TestFilterMatchesNothingYieldsEmptyView(t *testing.T) {
	fakeProcs(t, []vi.ProcRow{
		namedRow(1, vi.ProcRunning, 0, "ALPHA.BIN"),
	})
	tab := NewTable()
	tab.Refresh()
	tab.SetFilter("zzz")
	if tab.Len() != 0 {
		t.Fatalf("unmatched filter left %d rows", tab.Len())
	}
	if _, ok := tab.Selected(); ok {
		t.Fatal("an empty filtered view must report no selection")
	}
	if tab.MoveBy(1) {
		t.Fatal("MoveBy on an empty filtered view must not move")
	}
}

// TestFilterRouteThroughHandleKey pins the app's wiring end to end at the key
// boundary: `/` opens, typed chars narrow, Enter commits (filter stays),
// Escape clears (full list back) — and while the field is focused the app
// chords (`k`, digits) are inert text, not commands.
func TestFilterRouteThroughHandleKey(t *testing.T) {
	fakeProcs(t, []vi.ProcRow{
		namedRow(0, vi.ProcExited, 7, "user-el0"),
		namedRow(1, vi.ProcRunning, 0, "TABWM.BIN"),
		namedRow(2, vi.ProcRunning, 0, "COUNTER.BIN"),
		namedRow(3, vi.ProcRunning, 0, "GOTOP.ELF"),
	})
	a := &app{tab: NewTable(), net: NewNetView(), pg: pageProcs}
	a.bindFilter()
	a.tab.Refresh()
	a.rebuildItems()

	key := func(arg0 uint32, arg1 byte) bool {
		return a.handleKey(vi.Event{Kind: vi.EvKeyDown, Arg0: arg0, Arg1: uint32(arg1)})
	}
	if !key(0, '/') || !a.filter.Focused {
		t.Fatal("/ must open the filter field")
	}
	for _, ch := range "counter" {
		key(0, byte(ch))
	}
	if a.filter.Value() != "counter" || a.tab.Len() != 1 {
		t.Fatalf("filter=%q rows=%d, want counter/1", a.filter.Value(), a.tab.Len())
	}
	if len(a.items) != 1 {
		t.Fatalf("list shows %d items, want the one matching row", len(a.items))
	}
	// Enter commits: the filter stays applied, focus leaves the field.
	if !key(0x28, 0) || a.filter.Focused {
		t.Fatal("Enter must commit and unfocus")
	}
	if a.tab.Len() != 1 || a.tab.Filter() != "counter" {
		t.Fatal("commit must keep the filter applied")
	}
	// Reopen: the committed text survives; Escape clears field and filter.
	key(0, '/')
	if a.filter.Value() != "counter" {
		t.Fatalf("reopened field = %q, want the committed text", a.filter.Value())
	}
	if !key(0x29, 0) || a.filter.Focused {
		t.Fatal("Escape must close the field")
	}
	if a.tab.Len() != 4 || a.tab.Filter() != "" || a.filter.Value() != "" {
		t.Fatalf("clear: rows=%d filter=%q value=%q", a.tab.Len(), a.tab.Filter(), a.filter.Value())
	}
	// While focused, `k` is a typed character, not a kill.
	key(0, '/')
	key(0, 'k')
	if a.filter.Value() != "k" {
		t.Fatalf("focused field ate 'k' as text? value=%q", a.filter.Value())
	}
	key(0x29, 0)
}

// TestCounts pins the summary line's inputs.
func TestCounts(t *testing.T) {
	fakeProcs(t, []vi.ProcRow{
		namedRow(1, vi.ProcRunning, 0, "A.BIN"),
		namedRow(2, vi.ProcCreated, 0, "B.BIN"),
		namedRow(3, vi.ProcExited, 7, "C.BIN"),
	})
	tab := NewTable()
	tab.Refresh()
	running, exited, total := tab.Counts()
	if running != 1 || exited != 1 || total != 3 {
		t.Fatalf("counts = %d/%d/%d", running, exited, total)
	}
	if len(tab.Labels()) != 3 {
		t.Fatalf("labels = %d, want 3", len(tab.Labels()))
	}
}
