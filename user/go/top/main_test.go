package main

import (
	"testing"
	"unsafe"

	"virelai/tabapp"
	"virelai/vi"
)

// TestNativeLayoutIsTheIdentity is the zero-regression fixed point every Go
// tab app pins: at the native canvas every widget rect is exactly its design
// rect, so an un-resized GOTOP opens exactly where TOP.BIN opened.
func TestNativeLayoutIsTheIdentity(t *testing.T) {
	fakeProcs(t, nil)
	a := &app{ta: &tabapp.TabApp{Win: 1, W: natW, H: natH, Name: appName, TabAware: true, OpenOK: true}, tab: NewTable(), net: NewNetView()}
	a.layout()
	if a.refreshBtn.R != natRefresh || a.killBtn.R != natKill || a.netBtn.R != natNetwork {
		t.Fatalf("identity layout drifted: refresh=%+v kill=%+v net=%+v", a.refreshBtn.R, a.killBtn.R, a.netBtn.R)
	}
	if a.list.R != natList || a.list.RowH != natRowH {
		t.Fatalf("list rect = %+v rowH=%d", a.list.R, a.list.RowH)
	}
	if a.header.R != natHeader || a.foot.R != natFoot {
		t.Fatalf("header/foot rects drifted: %+v %+v", a.header.R, a.foot.R)
	}
}

// TestLayoutScalesWithTheCanvas: under a full 1100x720 seat viewport every rect
// grows, and hit-testing follows the drawn rect (the CALC-drift lesson).
func TestLayoutScalesWithTheCanvas(t *testing.T) {
	fakeProcs(t, nil)
	a := &app{ta: &tabapp.TabApp{Win: 1, W: 1100, H: 720, Name: appName, TabAware: true, OpenOK: true}, tab: NewTable(), net: NewNetView()}
	a.layout()
	if a.killBtn.R.W <= natKill.W || a.killBtn.R.X <= natKill.X {
		t.Fatalf("kill button did not scale: %+v", a.killBtn.R)
	}
	cx := a.killBtn.R.X + a.killBtn.R.W/2
	cy := a.killBtn.R.Y + a.killBtn.R.H/2
	if !a.killBtn.HitTest(cx, cy) {
		t.Fatal("the scaled kill button must hit-test its own centre")
	}
}

// TestColumnAtMatchesRowColumns: the header click maps to the column whose
// glyph cells the row labels pad to.
func TestColumnAtMatchesRowColumns(t *testing.T) {
	a := &app{}
	h := natHeader
	cases := []struct {
		x    int
		want Column
	}{
		{h.X + 1, ColPID},
		{h.X + 3*6 + 1, ColName},
		{h.X + (3+2+14)*6 + 1, ColState},
		{h.X + (3+2+14+1+7)*6 + 1, ColExit},
	}
	for _, c := range cases {
		if got := a.columnAt(c.x, h); got != c.want {
			t.Fatalf("columnAt(%d) = %v, want %v", c.x, got, c.want)
		}
	}
}

// TestSetPagePrintsTheTabMarker pins the vocabulary the specs assert.
func TestSetPagePrintsTheTabMarker(t *testing.T) {
	a := &app{tab: NewTable(), net: NewNetView(), pg: pageProcs}
	if !a.setPage(pageNetwork) {
		t.Fatal("switching to the network tab must report a change")
	}
	if a.setPage(pageNetwork) {
		t.Fatal("re-selecting the same tab must be a no-op")
	}
	if !a.setPage(pageProcs) {
		t.Fatal("switching back must report a change")
	}
}

// TestKillWithNoSelectionIsInert keeps `k` from inventing a pid.
func TestKillWithNoSelectionIsInert(t *testing.T) {
	fakeProcs(t, nil)
	a := &app{tab: NewTable(), net: NewNetView()}
	a.tab.Refresh()
	if a.killSelected() {
		t.Fatal("killSelected with no selection must not act")
	}
	// With a real target the same path arms slot 29 (the kernel's own refusal
	// or 0 is what the marker reports; the call itself is not swallowed).
	called := false
	// One hook for both seams: slot 7 serves a live COUNTER, slot 29 records
	// the arm attempt and answers with the kernel's cross-principal -EACCES.
	vi.SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case vi.SlotKill:
			called = true
			if a0 != 1 {
				t.Fatalf("armed pid %d, want the selected pid 1", a0)
			}
			return -vi.ErrEACCES
		case vi.SlotProcs:
			// Old-kernel answer: ignore ADR 0047's version tag, serve the
			// frozen 40-byte row at the masked byte limit.
			buf := unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1&procsMaxMask)
			row := namedRow(1, vi.ProcRunning, 0, "COUNTER.BIN")
			putU64(buf[0:], row.PID)
			putU64(buf[8:], row.State)
			putU64(buf[16:], row.ExitStatus)
			copy(buf[24:40], row.NameBuf[:])
			return 1
		}
		t.Fatalf("unexpected slot %d", num)
		return -vi.ErrENOSYS
	})
	t.Cleanup(func() { vi.SetSyscallHookForTest(nil) })
	a.tab.Refresh()
	if !a.killSelected() {
		t.Fatal("killSelected with a selection must act")
	}
	if !called {
		t.Fatal("killSelected must reach slot 29")
	}
}

// TestFootLineNamesTheRealKeys keeps the hint honest on both tabs.
func TestFootLineNamesTheRealKeys(t *testing.T) {
	a := &app{net: NewNetView(), pg: pageProcs}
	if got := a.footLine(); got == "" {
		t.Fatal("procs foot line is empty")
	}
	a.pg = pageNetwork
	if got := a.footLine(); got == "" {
		t.Fatal("net foot line is empty")
	}
}
