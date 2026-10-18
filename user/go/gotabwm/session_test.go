package main

import (
	"testing"

	"virelai/vi"
)

func TestRestoreSessionBranchesAndFirstBootWorkspace(t *testing.T) {
	seed := TabStrip{}
	if !seed.OpenTab(0x41, "Sh") {
		t.Fatal("OpenTab")
	}
	raw, ok := seed.encodeTabsV2(7)
	if !ok {
		t.Fatal("encodeTabsV2")
	}

	t.Run("missing", func(t *testing.T) {
		var strip TabStrip
		_, state := restoreSessionBytes(&strip, nil, -1)
		if state != sessionMissing || strip.Count() != 0 {
			t.Fatalf("missing state=%d count=%d", state, strip.Count())
		}
		if !firstBootWorkspace(state, "gotabwm") {
			t.Fatal("missing session on the default seat must open the starter workspace")
		}
		if firstBootWorkspace(state, "none") || firstBootWorkspace(state, "tabwm") {
			t.Fatal("a non-default seat setting must not start a GOTABWM workspace")
		}
	})

	t.Run("corrupt", func(t *testing.T) {
		var strip TabStrip
		_, state := restoreSessionBytes(&strip, []byte("truncated"), 9)
		if state != sessionCorrupt || strip.Count() != 0 {
			t.Fatalf("corrupt state=%d count=%d", state, strip.Count())
		}
		if firstBootWorkspace(state, "gotabwm") {
			t.Fatal("corrupt session must not fabricate a starter tab")
		}
	})

	t.Run("present", func(t *testing.T) {
		var strip TabStrip
		seq, state := restoreSessionBytes(&strip, raw, int64(len(raw)))
		if state != sessionRestored || seq != 7 || strip.Count() != 1 {
			t.Fatalf("present state=%d seq=%d count=%d", state, seq, strip.Count())
		}
		if strip.At(0).Title != "Sh" || strip.At(0).ID != sessionIDBase {
			t.Fatalf("restored tab = %+v", strip.At(0))
		}
		if firstBootWorkspace(state, "gotabwm") {
			t.Fatal("present session must restore without adding a starter tab")
		}
	})
}

// --- M79g (#1718): the write-through half ----------------------------------
//
// The card's claim is that SESSION.TABS records what the USER did, so the
// test has to run the real mutation entry points (a rail drag, the pin and
// freeze chords, a kind-11 retitle, a close) and read the bytes the seat
// would have published. vi.WriteFileSafe degrades to -ENOSYS off the guest,
// so the file seam is swapped for a recorder — the same indirection hid.go
// and interop.go use for execApp / closeWin.

type sessionWriteLog struct {
	writes [][]byte
	fail   bool
}

// install swaps the write seam and the close/focus WM seams, and restores
// every global it touched (tabs, the seq counter, the dirty latch) on
// cleanup: these tests share package state with the rest of the package.
func (l *sessionWriteLog) install(t *testing.T) {
	t.Helper()
	savedWrite, savedTabs := writeHostFile, tabs
	savedSeq, savedDirty := sessionSeq, sessionDirty
	savedClose, savedRaise := closeWin, focusRaise
	savedHosted := hostedApp
	t.Cleanup(func() {
		writeHostFile, tabs, sessionSeq, sessionDirty = savedWrite, savedTabs, savedSeq, savedDirty
		closeWin, focusRaise = savedClose, savedRaise
		hostedApp = savedHosted
	})
	writeHostFile = func(path string, data []byte) bool {
		if l.fail {
			return false
		}
		if path != sessionPath {
			t.Fatalf("session write path = %q want %q", path, sessionPath)
		}
		l.writes = append(l.writes, append([]byte(nil), data...))
		return true
	}
	closeWin = func(uint32) int64 { return 0 }
	focusRaise = func(uint32) int64 { return 0 }
}

// last decodes the most recent publish.
func (l *sessionWriteLog) last(t *testing.T) (uint16, []tabsV2Record, int, bool) {
	t.Helper()
	if len(l.writes) == 0 {
		t.Fatal("SESSION.TABS was never written")
	}
	seq, recs, active, has, ok := decodeTabsV2(l.writes[len(l.writes)-1])
	if !ok {
		t.Fatalf("last publish does not decode: %x", l.writes[len(l.writes)-1])
	}
	return seq, recs, active, has
}

func twoTabStrip(t *testing.T) {
	t.Helper()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "Calc") || !tabs.OpenTab(4, "Notepad") {
		t.Fatal("OpenTab")
	}
	if !tabs.FocusTab(4) {
		t.Fatal("FocusTab")
	}
}

// TestSessionWriteThroughMutationChain is the card's acceptance test: every
// mutation the user can make publishes the strip it produced, and the LAST
// mutation is the one on disk.
func TestSessionWriteThroughMutationChain(t *testing.T) {
	var log sessionWriteLog
	log.install(t)
	twoTabStrip(t)

	// 1. A rail drag that moved a tab: the new order is what persists.
	if !applyRailReorder(0, 1) {
		t.Fatal("applyRailReorder")
	}
	if len(log.writes) != 1 {
		t.Fatalf("reorder wrote %d files want 1", len(log.writes))
	}
	_, recs, _, _ := log.last(t)
	if len(recs) != 2 || recs[0].Title != "Notepad" || recs[1].Title != "Calc" {
		t.Fatalf("after reorder: %+v", recs)
	}

	// 2. ctrl-shift-n (pin's chord since M121a): the pin bit, and the
	//    re-partition Pin() performs.
	if !applyHidPin() {
		t.Fatal("applyHidPin")
	}
	if len(log.writes) != 2 {
		t.Fatalf("pin wrote %d files want 2", len(log.writes))
	}
	_, recs, _, _ = log.last(t)
	if !recs[0].Pinned || recs[1].Pinned {
		t.Fatalf("after pin: %+v", recs)
	}

	// 3. ctrl-shift-f: the frozen badge, on the focused tab only.
	if !applyFreezeToggle() {
		t.Fatal("applyFreezeToggle")
	}
	_, recs, _, _ = log.last(t)
	if !recs[0].Frozen || recs[1].Frozen {
		t.Fatalf("after freeze: %+v", recs)
	}

	// 4. A kind-11 retitle (M79d): the new title persists, the BIN does
	//    not move — reopen identity is the declaration's, not the label's.
	req := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4}
	copy(req.Title[:], "notes.txt")
	if !applyRPC(req) {
		t.Fatal("applyRPC set_title")
	}
	_, recs, _, _ = log.last(t)
	if recs[0].Title != "notes.txt" || recs[0].Bin != "NOTE.ELF" {
		t.Fatalf("after retitle: %+v", recs)
	}

	// 5. A close: the closed tab is gone from the file.
	if !closeTabByID(3) {
		t.Fatal("closeTabByID")
	}
	_, recs, _, _ = log.last(t)
	if len(recs) != 1 || recs[0].Title != "notes.txt" || !recs[0].Pinned || !recs[0].Frozen {
		t.Fatalf("after close: %+v", recs)
	}
	want := len(log.writes)

	// 6. Closing the LAST tab empties the strip: an empty session is never
	//    published, so the file keeps the strip it had and the latch stays
	//    set (there IS an unpersisted change; publishing it would be a lie).
	if !closeTabByID(4) {
		t.Fatal("closeTabByID last")
	}
	if len(log.writes) != want {
		t.Fatalf("closing the last tab published %d more files", len(log.writes)-want)
	}
	if !sessionDirty {
		t.Fatal("sessionDirty cleared after an empty-strip refusal")
	}
}

// TestSessionNoOpMutationWritesNothing is the other half of "keeps the write
// count bounded": the guard is on CHANGE, so a drag that lands on its own
// cell and a pin of an already-pinned tab cost no file write.
func TestSessionNoOpMutationWritesNothing(t *testing.T) {
	var log sessionWriteLog
	log.install(t)
	twoTabStrip(t)
	if !applyHidPin() {
		t.Fatal("applyHidPin")
	}
	want := len(log.writes)
	if want == 0 {
		t.Fatal("the first pin must persist")
	}
	if applyRailReorder(1, 1) {
		t.Fatal("a same-cell reorder must be a no-op")
	}
	if applyHidPin() {
		t.Fatal("pinning an already-pinned tab must be a no-op")
	}
	if len(log.writes) != want {
		t.Fatalf("no-op mutations wrote %d extra files", len(log.writes)-want)
	}
}

// TestSessionWriteSkipsRestoredPlaceholders: a restored row is a placeholder,
// never a re-exec'd app, so it is not written back. Without this the file
// grows a ghost row per boot (restore two, open one, reboot -> three).
func TestSessionWriteSkipsRestoredPlaceholders(t *testing.T) {
	var log sessionWriteLog
	log.install(t)

	seed := TabStrip{}
	if !seed.OpenTab(3, "Calc") || !seed.OpenTab(4, "Notepad") {
		t.Fatal("OpenTab")
	}
	raw, ok := seed.encodeTabsV2(1)
	if !ok {
		t.Fatal("encodeTabsV2")
	}
	tabs = TabStrip{}
	if _, ok := tabs.applyTabsV2(raw); !ok {
		t.Fatal("applyTabsV2")
	}
	if tabs.Count() != 2 || tabs.At(0).ID != sessionIDBase {
		t.Fatalf("restored strip = %+v", tabs)
	}
	// A placeholder-only strip publishes nothing: nothing is running.
	if writeSession() {
		t.Fatal("writeSession published a strip with no live tab")
	}
	if len(log.writes) != 0 {
		t.Fatalf("placeholder-only strip wrote %d files", len(log.writes))
	}

	// One real client joins: the file is that client alone, and a focus
	// still parked on a placeholder records no active tab.
	if !tabs.OpenTab(9, "Term") {
		t.Fatal("OpenTab Term")
	}
	if !writeSession() {
		t.Fatal("writeSession")
	}
	_, recs, active, has := log.last(t)
	if len(recs) != 1 || recs[0].Title != "Term" {
		t.Fatalf("published %+v want only the live tab", recs)
	}
	if has {
		t.Fatalf("active=%d recorded for a focus that sat on a placeholder", active)
	}
	if !tabs.FocusTab(9) || !writeSession() {
		t.Fatal("FocusTab/writeSession")
	}
	_, recs, active, has = log.last(t)
	if !has || active != 0 {
		t.Fatalf("active = %d has=%v want 0 (the live tab)", active, has)
	}
	if len(recs) != 1 {
		t.Fatalf("published %d records, want 1", len(recs))
	}
}

// TestSessionWriteFailureStaysDirty: a failed publish must not be recorded
// as an up-to-date file — the next mutation retries.
func TestSessionWriteFailureStaysDirty(t *testing.T) {
	var log sessionWriteLog
	log.install(t)
	twoTabStrip(t)
	log.fail = true
	if noteSessionMutation() {
		t.Fatal("noteSessionMutation succeeded with a failing file seam")
	}
	if !sessionDirty {
		t.Fatal("a failed write must leave the strip dirty")
	}
	log.fail = false
	if !noteSessionMutation() {
		t.Fatal("noteSessionMutation after recovery")
	}
	if sessionDirty {
		t.Fatal("sessionDirty not cleared by the successful retry")
	}
}

// TestMutatedStripRoundTrips is the card's encode/decode test: mutate a
// strip, publish it, decode it, and compare every field the v2 record can
// carry. The truncated-record case is the fail-closed half.
func TestMutatedStripRoundTrips(t *testing.T) {
	var s TabStrip
	if !s.OpenTab(3, "Calc") || !s.OpenTab(4, "Notepad") {
		t.Fatal("OpenTab")
	}
	if !s.Reorder(0, 1) || !s.Pin(4) || !s.Freeze(4) {
		t.Fatal("mutate strip")
	}
	if !s.SetTitle(4, "notes.txt") {
		t.Fatal("SetTitle")
	}
	if !s.FocusTab(3) {
		t.Fatal("FocusTab")
	}
	raw, ok := s.encodeTabsV2(11)
	if !ok {
		t.Fatal("encodeTabsV2")
	}
	seq, recs, active, has, ok := decodeTabsV2(raw)
	if !ok || seq != 11 {
		t.Fatalf("decode seq=%d ok=%v want 11", seq, ok)
	}
	if !has || active != 1 {
		t.Fatalf("active = %d has=%v want 1 (Calc)", active, has)
	}
	want := []tabsV2Record{
		{Title: "notes.txt", Bin: "NOTE.ELF", Pinned: true, Frozen: true},
		{Title: "Calc", Bin: "GOCALC.ELF"},
	}
	if len(recs) != len(want) {
		t.Fatalf("decoded %d records want %d", len(recs), len(want))
	}
	for i := range want {
		if recs[i] != want[i] {
			t.Fatalf("record %d = %+v want %+v", i, recs[i], want[i])
		}
	}
	// Fail closed: a record chopped short is not a session.
	if _, _, _, _, ok := decodeTabsV2(raw[:tabsV2HeaderBytes+tabsV2RecordBytes+10]); ok {
		t.Fatal("a truncated record decoded")
	}
	var restored TabStrip
	if _, ok := restored.applyTabsV2(raw[:tabsV2HeaderBytes+tabsV2RecordBytes+10]); ok {
		t.Fatal("applyTabsV2 accepted a truncated record")
	}
	if restored.Count() != 0 {
		t.Fatalf("fail-closed left count = %d", restored.Count())
	}
}

// TestSessionTitleKeepsBin: a retitled tab keeps the executable it was
// declared with, so reopen and duplicate still name the real app (the M79d
// interaction the card calls out).
func TestSessionTitleKeepsBin(t *testing.T) {
	var s TabStrip
	if !s.OpenTab(4, "Notepad") {
		t.Fatal("OpenTab")
	}
	if !s.SetTitle(4, "notes.txt") {
		t.Fatal("SetTitle")
	}
	if s.At(0).Bin != "NOTE.ELF" {
		t.Fatalf("bin = %q want NOTE.ELF (a rename must not re-guess)", s.At(0).Bin)
	}
	if bin, ok := s.DuplicateFocused(); !ok || bin != "NOTE.ELF" {
		t.Fatalf("DuplicateFocused = %q ok=%v want NOTE.ELF", bin, ok)
	}
	if !s.CloseTab(4) {
		t.Fatal("CloseTab")
	}
	c, ok := s.ReopenLastClosed()
	if !ok || c.Bin != "NOTE.ELF" {
		t.Fatalf("ReopenLastClosed = %+v ok=%v want bin NOTE.ELF", c, ok)
	}
}

func TestHasLiveGuestELF(t *testing.T) {
	row := func(state uint64, name string) vi.ProcRow {
		r := vi.ProcRow{State: state}
		copy(r.NameBuf[:], name)
		return r
	}
	for _, tc := range []struct {
		name string
		rows []vi.ProcRow
		want bool
	}{
		{name: "no other program", rows: []vi.ProcRow{row(vi.ProcRunning, "GOTABWM.ELF")}},
		{name: "init owns boot", rows: []vi.ProcRow{row(vi.ProcRunning, "INIT.ELF")}},
		{name: "init with existing shell", rows: []vi.ProcRow{
			row(vi.ProcRunning, "INIT.ELF"), row(vi.ProcRunning, "GOSH.ELF")}, want: true},
		{name: "running client", rows: []vi.ProcRow{row(vi.ProcRunning, "GOSH.ELF")}, want: true},
		{name: "created client", rows: []vi.ProcRow{row(vi.ProcCreated, "GOCALC.ELF")}, want: true},
		{name: "exited client", rows: []vi.ProcRow{row(vi.ProcExited, "GOSH.ELF")}},
		{name: "non ELF", rows: []vi.ProcRow{row(vi.ProcRunning, "monitor")}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := hasLiveGuestELF(tc.rows); got != tc.want {
				t.Fatalf("hasLiveGuestELF = %v want %v", got, tc.want)
			}
		})
	}
}
