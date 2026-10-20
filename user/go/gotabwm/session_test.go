package main

import (
	"errors"
	"strings"
	"testing"

	"virelai/vi"
)

func TestRestoreSessionBranchesAndFirstBootWorkspace(t *testing.T) {
	seed := TabStrip{}
	if !seed.OpenTab(0x41, "Sh") {
		t.Fatal("OpenTab")
	}
	raw, _, ok := seed.encodeTabsV2(7)
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
	writes [][]byte // SESSION.TABS publishes
	layout [][]byte // LAYOUT.txt publishes (finishReexec / split dumps)
	fail   bool
}

// install swaps the write seam and the close/focus WM seams, and restores
// every global it touched (tabs, the seq counter, the dirty latch, the
// M120b re-exec state) on cleanup: these tests share package state with the
// rest of the package.
func (l *sessionWriteLog) install(t *testing.T) {
	t.Helper()
	savedWrite, savedTabs := writeHostFile, tabs
	savedSeq, savedDirty := sessionSeq, sessionDirty
	savedClose, savedRaise := closeWin, focusRaise
	savedHosted := hostedApp
	savedPending, savedN, savedHold := reexecPending, reexecN, reexecHold
	savedArmed, savedEcho := reexecSettleArmed, sessionEcho
	savedRead := readSessionFile
	t.Cleanup(func() {
		writeHostFile, tabs, sessionSeq, sessionDirty = savedWrite, savedTabs, savedSeq, savedDirty
		closeWin, focusRaise = savedClose, savedRaise
		hostedApp = savedHosted
		reexecPending, reexecN, reexecHold = savedPending, savedN, savedHold
		reexecSettleArmed, sessionEcho = savedArmed, savedEcho
		readSessionFile = savedRead
	})
	writeHostFile = func(path string, data []byte) bool {
		if l.fail {
			return false
		}
		// finishReexec republishes LAYOUT.txt through the same seam; the
		// tests count SESSION.TABS writes, so the layout stream is kept
		// separate and only the session one decodes.
		switch path {
		case sessionPath:
			l.writes = append(l.writes, append([]byte(nil), data...))
		case layoutPath:
			l.layout = append(l.layout, append([]byte(nil), data...))
		default:
			t.Fatalf("session write path = %q want %q or %q", path, sessionPath, layoutPath)
		}
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
	seq, recs, active, has, _, ok := decodeTabsV2(l.writes[len(l.writes)-1])
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
	raw, _, ok := seed.encodeTabsV2(1)
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
	raw, _, ok := s.encodeTabsV2(11)
	if !ok {
		t.Fatal("encodeTabsV2")
	}
	seq, recs, active, has, _, ok := decodeTabsV2(raw)
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
		if recs[i].Title != want[i].Title || recs[i].Bin != want[i].Bin ||
			recs[i].Pinned != want[i].Pinned || recs[i].Frozen != want[i].Frozen {
			t.Fatalf("record %d = %+v want %+v", i, recs[i], want[i])
		}
	}
	// Fail closed: a record chopped short is not a session.
	if _, _, _, _, _, ok := decodeTabsV2(raw[:tabsV2HeaderBytes+tabsV2RecordBytes+10]); ok {
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

// --- M120b (#2559): SESSION.TABS live tab re-exec --------------------------
//
// Boot 2's restore is live tabs, never corpses: each backed row's bin is
// exec'd, and the pid's kind-8/5 declare adopts the row in place so order,
// pin, frozen and focus ride it. Rows nothing can run are dropped; a
// restore that yields no live row falls back to the first-boot workspace.

// seedSessionFile builds the `.tabs` v2 bytes for a strip that is exactly
// the rows given: OpenTab would re-guess the bin, so the Bin fields are set
// directly — a restored record's bin field is what the file says, not what
// the title maps to.
func seedSessionFile(t *testing.T, focusID uint32, rows ...Tab) []byte {
	t.Helper()
	var seed TabStrip
	for i, r := range rows {
		if !seed.OpenTab(uint32(i+1), r.Title) {
			t.Fatal("OpenTab seed")
		}
		seed.tabs[i].Bin = r.Bin
		seed.tabs[i].Pinned = r.Pinned
		seed.tabs[i].Frozen = r.Frozen
	}
	if focusID != 0 {
		if !seed.FocusTab(seed.tabs[int(focusID-1)].ID) {
			t.Fatal("FocusTab seed")
		}
	}
	raw, _, ok := seed.encodeTabsV2(9)
	if !ok {
		t.Fatal("encodeTabsV2")
	}
	return raw
}

// reexecEnv arms the seams a restore drives: the file read, the exec fan
// out (returning sequential pids), the chrome decision, and pid liveness.
// Returns the exec log and the pid each exec was assigned.
func reexecEnv(t *testing.T, raw []byte, execErr map[string]bool) (*[]string, map[string]int64) {
	t.Helper()
	savedRead, savedExec := readSessionFile, execApp
	savedChrome, savedProcs := configureHostedChrome, procsAlive
	t.Cleanup(func() {
		readSessionFile, execApp = savedRead, savedExec
		configureHostedChrome, procsAlive = savedChrome, savedProcs
	})
	readSessionFile = func(path string, max int) ([]byte, int64) {
		if path == panesPath {
			return nil, -1 // no sidecar seeded: the unsplit shape
		}
		if path != sessionPath {
			t.Fatalf("session read path = %q want %q", path, sessionPath)
		}
		return raw, int64(len(raw))
	}
	execed := []string{}
	pids := map[string]int64{}
	nextpid := int64(50)
	execApp = func(name string, args ...string) (int64, error) {
		if execErr[name] {
			return 0, errors.New("exec refused")
		}
		execed = append(execed, name)
		nextpid++
		pids[name] = nextpid
		return nextpid, nil
	}
	configureHostedChrome = func(uint32) bool { return true }
	procsAlive = func(uint8) bool { return true }
	return &execed, pids
}

// reexecDeclare feeds one kind-8 declare into applyRPC the way the
// re-exec'd app would send it: the window id is fresh, ReplyTo is the
// exec'd pid.
func reexecDeclare(t *testing.T, pid uint8, winID uint32, title string) bool {
	t.Helper()
	req := vi.WmRpc{Kind: vi.WmRpcKindDeclareFullscreen, ID: uint8(winID), ReplyTo: pid}
	req.SetTitle(title)
	return applyRPC(req)
}

// TestSessionReexecAdoptsBackedRows is the card's spine: two backed rows
// re-exec, the declares arrive in REVERSE order (the execs are unordered —
// SPEC.md), and the rows are adopted in place so order, pin, frozen and the
// recorded focus all survive.
func TestSessionReexecAdoptsBackedRows(t *testing.T) {
	var log sessionWriteLog
	log.install(t)
	raw := seedSessionFile(t, 2,
		Tab{Title: "Notepad", Bin: "NOTE.ELF"},
		Tab{Title: "Calc", Bin: "GOCALC.ELF", Pinned: true, Frozen: true})
	execed, pids := reexecEnv(t, raw, nil)
	raised := []uint32{}
	focusRaise = func(id uint32) int64 { raised = append(raised, id); return 0 }

	if state := loadSession(); state != sessionRestored {
		t.Fatalf("loadSession = %d want sessionRestored", state)
	}
	if reexecN != 2 {
		t.Fatalf("pending = %d want 2", reexecN)
	}
	if got := *execed; len(got) != 2 || got[0] != "NOTE.ELF" || got[1] != "GOCALC.ELF" {
		t.Fatalf("execed = %v want NOTE.ELF then GOCALC.ELF (file order)", got)
	}
	// Until their declares arrive the rows sit at placeholder ids.
	if tabs.At(0).ID != sessionIDBase || tabs.At(1).ID != sessionIDBase+1 {
		t.Fatalf("pre-adopt ids = %x,%x", tabs.At(0).ID, tabs.At(1).ID)
	}

	// The FOCUSED row declares second (pid order reversed): its adoption
	// must not steal focus mid-flight — the settle pass owns it.
	if !reexecDeclare(t, uint8(pids["GOCALC.ELF"]), 7, "Calc") {
		t.Fatal("declare from pending pid refused")
	}
	if tabs.At(1).ID != 7 || !tabs.At(1).Pinned || !tabs.At(1).Frozen {
		t.Fatalf("adopted row = %+v", tabs.At(1))
	}
	if fid, _ := tabs.Focused(); fid != 7 {
		t.Fatalf("focus = %d want 7 (the recorded focused row)", fid)
	}
	if reexecN != 1 {
		t.Fatalf("pending = %d want 1", reexecN)
	}
	if !reexecDeclare(t, uint8(pids["NOTE.ELF"]), 9, "Notepad") {
		t.Fatal("second declare from pending pid refused")
	}
	if reexecN != 0 {
		t.Fatalf("pending = %d want 0", reexecN)
	}
	// Order kept by construction: row 0 is the note, row 1 the calc.
	if tabs.At(0).ID != 9 || tabs.At(0).Title != "Notepad" ||
		tabs.At(1).ID != 7 || tabs.At(1).Title != "Calc" {
		t.Fatalf("strip after adopt = %+v", tabs)
	}
	if fid, ok := tabs.Focused(); !ok || fid != 7 {
		t.Fatalf("settled focus = %d ok=%v want 7", fid, ok)
	}
	if hostedApp != 7 {
		t.Fatalf("hostedApp = %d want 7", hostedApp)
	}
	if len(raised) != 1 || raised[0] != 7 {
		t.Fatalf("settle raises = %v want [7]", raised)
	}
	// Every adoption published the strip it produced; the last file carries
	// only live rows (pending placeholders are never persisted) with the
	// recorded flags intact.
	if len(log.writes) < 2 {
		t.Fatalf("session writes = %d want >= 2", len(log.writes))
	}
	_, recs, active, has := log.last(t)
	if len(recs) != 2 || recs[0].Bin != "NOTE.ELF" || recs[1].Bin != "GOCALC.ELF" {
		t.Fatalf("republished records = %+v", recs)
	}
	if !recs[1].Pinned || !recs[1].Frozen || recs[0].Pinned {
		t.Fatalf("republished flags = %+v", recs)
	}
	if !has || active != 1 {
		t.Fatalf("republished active = %d has=%v want 1", active, has)
	}
	// The settle republished LAYOUT.txt with the live window ids.
	if len(log.layout) < 2 {
		t.Fatalf("layout writes = %d want the load dump + the settle dump", len(log.layout))
	}
}

// TestSessionReexecMixedUnbacked: a row with no recorded bin cannot be
// re-exec'd — it is dropped by name while the backed row waits for its
// declare.
func TestSessionReexecMixedUnbacked(t *testing.T) {
	var log sessionWriteLog
	log.install(t)
	raw := seedSessionFile(t, 1,
		Tab{Title: "Ghost", Bin: ""},
		Tab{Title: "Calc", Bin: "GOCALC.ELF"})
	execed, _ := reexecEnv(t, raw, nil)

	if state := loadSession(); state != sessionRestored {
		t.Fatalf("loadSession = %d want sessionRestored", state)
	}
	if got := *execed; len(got) != 1 || got[0] != "GOCALC.ELF" {
		t.Fatalf("execed = %v want only GOCALC.ELF", got)
	}
	if tabs.Count() != 1 || tabs.At(0).Title != "Calc" {
		t.Fatalf("strip = %+v want only the backed row", tabs)
	}
	if reexecN != 1 {
		t.Fatalf("pending = %d want 1", reexecN)
	}
	// The dropped unbacked row is not reopenable — a row the seat never
	// spawned has no bin to re-exec (ReopenLastClosed's own rule).
	if _, ok := tabs.ReopenLastClosed(); ok {
		t.Fatal("an unbacked drop must not enter the reopen LIFO")
	}
}

// TestSessionReexecExecFailureDropsRow: a backed row whose exec the kernel
// refuses (pool full, or a bin that is not a file) is dropped by name; the
// rows that did exec still wait for their declares.
func TestSessionReexecExecFailureDropsRow(t *testing.T) {
	var log sessionWriteLog
	log.install(t)
	raw := seedSessionFile(t, 1,
		Tab{Title: "Calc", Bin: "GOCALC.ELF"},
		Tab{Title: "Settings", Bin: "GOSET.ELF"})
	execed, _ := reexecEnv(t, raw, map[string]bool{"GOSET.ELF": true})

	if state := loadSession(); state != sessionRestored {
		t.Fatalf("loadSession = %d want sessionRestored", state)
	}
	if got := *execed; len(got) != 1 || got[0] != "GOCALC.ELF" {
		t.Fatalf("execed = %v want only GOCALC.ELF", got)
	}
	if tabs.Count() != 1 || tabs.At(0).Title != "Calc" {
		t.Fatalf("strip = %+v want only the exec'd row", tabs)
	}
	// The refused bin IS reopenable — the record named a real executable,
	// so ctrl-shift-t can retry it once the pool has room.
	c, ok := tabs.ReopenLastClosed()
	if !ok || c.Bin != "GOSET.ELF" {
		t.Fatalf("reopen = %+v ok=%v want GOSET.ELF", c, ok)
	}
}

// TestSessionReexecAllUnbackedFallsBack: when every row is unbacked the
// restore leaves no live row, and the starter shell is NOT suppressed —
// the state reads sessionEmpty and firstBootWorkspace fires.
func TestSessionReexecAllUnbackedFallsBack(t *testing.T) {
	var log sessionWriteLog
	log.install(t)
	raw := seedSessionFile(t, 0,
		Tab{Title: "Ghost", Bin: ""},
		Tab{Title: "Shell", Bin: ""})
	execed, _ := reexecEnv(t, raw, nil)

	if state := loadSession(); state != sessionEmpty {
		t.Fatalf("loadSession = %d want sessionEmpty", state)
	}
	if tabs.Count() != 0 || reexecN != 0 || len(*execed) != 0 {
		t.Fatalf("count=%d pending=%d execed=%v", tabs.Count(), reexecN, *execed)
	}
	if !firstBootWorkspace(sessionEmpty, "gotabwm") {
		t.Fatal("an all-dropped restore must reach the starter workspace")
	}
	if firstBootWorkspace(sessionEmpty, "none") || firstBootWorkspace(sessionRestored, "gotabwm") {
		t.Fatal("fallback is only the default seat's empty restore")
	}
}

// TestSessionReexecLateDeclareWindow: a pid still pending when the hold
// expires drops its row; a declare that arrives afterwards joins as an
// ordinary new tab, never resurrecting the placeholder.
func TestSessionReexecLateDeclareWindow(t *testing.T) {
	var log sessionWriteLog
	log.install(t)
	raw := seedSessionFile(t, 0,
		Tab{Title: "Calc", Bin: "GOCALC.ELF"},
		Tab{Title: "Notepad", Bin: "NOTE.ELF"})
	execed, pids := reexecEnv(t, raw, nil)
	focusRaise = func(id uint32) int64 { return 0 }

	if state := loadSession(); state != sessionRestored {
		t.Fatalf("loadSession = %d want sessionRestored", state)
	}
	// One row's app makes it; the other never declares before the hold.
	if !reexecDeclare(t, uint8(pids["GOCALC.ELF"]), 7, "Calc") {
		t.Fatal("declare from pending pid refused")
	}
	reexecHold = 1
	reapSessionReexec()
	if reexecN != 0 || tabs.Count() != 1 || tabs.At(0).ID != 7 {
		t.Fatalf("after the hold: pending=%d strip=%+v", reexecN, tabs)
	}
	if len(log.layout) < 2 {
		t.Fatal("the settle did not republish LAYOUT.txt with the live id")
	}
	if len(*execed) != 2 {
		t.Fatalf("execed = %v want both bins attempted", *execed)
	}
	// The dropped row's bin is reopenable — it named a real file.
	if c, ok := tabs.ReopenLastClosed(); !ok || c.Bin == "" {
		t.Fatal("a late drop still feeds the reopen LIFO")
	}
	// A declare from the (now dropped) pid is a normal open, not a ghost.
	if !reexecDeclare(t, uint8(pids["NOTE.ELF"]), 8, "Notepad") {
		t.Fatal("late declare refused")
	}
	if tabs.Count() != 2 || tabs.At(1).ID != 8 {
		t.Fatalf("late declare joined as %+v", tabs)
	}
}

// TestSessionReexecDeadPidReaped: a pid that exited before its declare is
// reaped on the next composite tick — the row is dropped rather than
// waiting out the hold.
func TestSessionReexecDeadPidReaped(t *testing.T) {
	var log sessionWriteLog
	log.install(t)
	raw := seedSessionFile(t, 1,
		Tab{Title: "Calc", Bin: "GOCALC.ELF"},
		Tab{Title: "Notepad", Bin: "NOTE.ELF"})
	_, pids := reexecEnv(t, raw, nil)
	focusRaise = func(id uint32) int64 { return 0 }
	procsAlive = func(pid uint8) bool { return pid != uint8(pids["GOCALC.ELF"]) }

	if state := loadSession(); state != sessionRestored {
		t.Fatalf("loadSession = %d want sessionRestored", state)
	}
	reapSessionReexec()
	if reexecN != 1 || tabs.Count() != 1 || tabs.At(0).Title != "Notepad" {
		t.Fatalf("after reap: pending=%d strip=%+v", reexecN, tabs)
	}
	// The surviving row's pid is still live; the hold has not run down.
	if !reexecDeclare(t, uint8(pids["NOTE.ELF"]), 8, "Notepad") {
		t.Fatal("surviving row's declare refused")
	}
	if tabs.At(0).ID != 8 || reexecN != 0 {
		t.Fatalf("adopted = %+v pending=%d", tabs.At(0), reexecN)
	}
	if fid, _ := tabs.Focused(); fid != 8 {
		t.Fatalf("focus = %d want 8 (row 0 was the recorded focus)", fid)
	}
}

// TestSessionReexecUnknownPidOpensNewTab: a declare from a pid the restore
// never exec'd is an ordinary tab — it appends, takes focus, and leaves the
// pending rows alone.
func TestSessionReexecUnknownPidOpensNewTab(t *testing.T) {
	var log sessionWriteLog
	log.install(t)
	raw := seedSessionFile(t, 0, Tab{Title: "Calc", Bin: "GOCALC.ELF"})
	reexecEnv(t, raw, nil)

	if state := loadSession(); state != sessionRestored {
		t.Fatalf("loadSession = %d want sessionRestored", state)
	}
	if !reexecDeclare(t, 99, 7, "Edit") {
		t.Fatal("unrelated declare refused")
	}
	if tabs.Count() != 2 || tabs.At(1).ID != 7 || tabs.At(1).Title != "Edit" {
		t.Fatalf("unrelated declare joined as %+v", tabs)
	}
	if hostedApp != 7 {
		t.Fatalf("hostedApp = %d want 7 (a fresh declare takes focus)", hostedApp)
	}
	if reexecN != 1 {
		t.Fatalf("pending = %d want 1 (the restore row still waits)", reexecN)
	}
}

// TestSessionEchoPinsTheFile: the witness line reports what the FILE held
// even after the re-exec fan-out mutated the strip — and an absent file
// echoes the empty strip exactly as before.
func TestSessionEchoPinsTheFile(t *testing.T) {
	var log sessionWriteLog
	log.install(t)
	raw := seedSessionFile(t, 1,
		Tab{Title: "Calc", Bin: "GOCALC.ELF"},
		Tab{Title: "Notepad", Bin: "NOTE.ELF", Pinned: true})
	reexecEnv(t, raw, nil)

	if state := loadSession(); state != sessionRestored {
		t.Fatalf("loadSession = %d", state)
	}
	if sessionEcho != "Calc,Notepad pin=0,1 active=0" {
		t.Fatalf("sessionEcho = %q", sessionEcho)
	}
	// Mutate the strip post-load: the echo is the file's, not the strip's.
	tabs = TabStrip{}
	if got := restoreWitnessLine(); !strings.Contains(got, sessionEcho) {
		t.Fatalf("witness line %q lost the file echo %q", got, sessionEcho)
	}
}
