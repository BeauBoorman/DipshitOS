package main

// M125a (#2586): the per-app state protocol's seat half. The file seams
// stand in for the staged share file, the notice seam for the mailbox
// post, and the drain seam for the app's answer — the same indirection
// pattern as sessionWriteLog/fakeShare.

import (
	"bytes"
	"strings"
	"testing"

	"virelai/vi"
)

// stateFixture swaps the protocol's seams for a fake /host filesystem and
// a recorded-notice outbox, restoring every touched global on cleanup.
type stateFixture struct {
	files   map[string][]byte
	deleted []string
	notices []vi.WmRpc
	logs    []string
	drains  int
	drainFn func() int
	yields  int
}

func (f *stateFixture) install(t *testing.T) {
	t.Helper()
	f.files = map[string][]byte{}
	oldRead, oldWrite, oldDel := stateFileRead, stateFileWrite, stateFileDelete
	oldPost, oldDrain, oldYield := stateNoticePost, stateServiceDrain, stateYield
	oldTabs, oldLog := tabs, stateLog
	oldBind := rpcBindings
	oldPend := stateAskPend
	oldPA, oldPAN := pendingAppStates, pendingAppStateN
	oldClose := closeWin
	t.Cleanup(func() {
		stateFileRead, stateFileWrite, stateFileDelete = oldRead, oldWrite, oldDel
		stateNoticePost, stateServiceDrain, stateYield = oldPost, oldDrain, oldYield
		tabs, stateLog = oldTabs, oldLog
		rpcBindings = oldBind
		stateAskPend = oldPend
		pendingAppStates, pendingAppStateN = oldPA, oldPAN
		closeWin = oldClose
	})
	stateFileRead = func(path string, max int) ([]byte, int64) {
		b, ok := f.files[path]
		if !ok {
			return nil, -2 // -ENOENT
		}
		if len(b) > max {
			return append([]byte(nil), b[:max]...), int64(max)
		}
		return append([]byte(nil), b...), int64(len(b))
	}
	stateFileWrite = func(path string, data []byte) int64 {
		f.files[path] = append([]byte(nil), data...)
		return 0
	}
	stateFileDelete = func(path string) int64 {
		if _, ok := f.files[path]; ok {
			delete(f.files, path)
			f.deleted = append(f.deleted, path)
			return 0
		}
		return -2
	}
	stateNoticePost = func(target uint32, b []byte) int64 {
		if m, ok := vi.DecodeWmRpc(b); ok {
			f.notices = append(f.notices, m)
		}
		return 0
	}
	stateServiceDrain = func() int {
		f.drains++
		if f.drainFn != nil {
			return f.drainFn()
		}
		return 0
	}
	stateYield = func() { f.yields++ }
	closeWin = func(uint32) int64 { return 0 }
	stateLog = func(s string) { f.logs = append(f.logs, s) }
	tabs = TabStrip{}
	rpcBindings = [256]rpcBinding{}
	stateAskPend = [256]bool{}
	pendingAppStates = [MaxTabs]pendingAppState{}
	pendingAppStateN = 0
}

func (f *stateFixture) hasLog(sub string) bool {
	for _, l := range f.logs {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

// stage writes a valid envelope at id's rendezvous path — the bytes an app
// publishes before it posts kind 20.
func (f *stateFixture) stage(id uint32, ver uint8, blob []byte) {
	enc, ok := vi.EncodeAppState(ver, blob)
	if !ok {
		panic("stage: oversize blob")
	}
	f.files[vi.AppStatePath(id)] = enc
}

func saveReq(id uint32) vi.WmRpc {
	var r vi.WmRpc
	r.Kind = vi.WmRpcKindSaveState
	r.ID = uint8(id)
	return r
}

func TestServeStateSaveStoresAndRepublishes(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	l := &sessionWriteLog{}
	l.install(t)

	if !tabs.OpenTab(9, "GoTabApp") {
		t.Fatal("OpenTab")
	}
	blob := []byte("gotabapp state v1: hello strip")
	f.stage(9, 7, blob)

	if !serveStateSave(saveReq(9)) {
		t.Fatal("serveStateSave refused a well-formed blob")
	}
	if !bytes.Equal(tabs.At(0).State, blob) || tabs.At(0).StateVer != 7 {
		t.Fatalf("stored state = %x ver %d", tabs.At(0).State, tabs.At(0).StateVer)
	}
	if len(f.files) != 0 {
		t.Fatal("staging file was not consumed")
	}
	if !f.hasLog(MarkerStateSave + "9 len=30 ver=7") {
		t.Fatalf("no save marker: %v", f.logs)
	}
	// The mutation republished SESSION.TABS with the blob in the trailer.
	if len(l.writes) != 1 {
		t.Fatalf("session writes = %d want 1", len(l.writes))
	}
	_, recs, _, _, _, ok := decodeTabsV2(l.writes[0])
	if !ok || !bytes.Equal(recs[0].State, blob) || recs[0].StateVer != 7 {
		t.Fatalf("session trailer state = %x ver %d ok=%v", recs[0].State, recs[0].StateVer, ok)
	}
}

func TestServeStateSaveRefusalsAreNamed(t *testing.T) {
	cases := []struct {
		name    string
		setup   func(f *stateFixture, id uint32)
		wantSub string
	}{
		{"missing", func(f *stateFixture, id uint32) {}, " missing"},
		{"oversize", func(f *stateFixture, id uint32) {
			big := make([]byte, stateMaxBytes+1)
			enc := append([]byte{1, 0x01, 0x00, 0x01, 0x00}, big...) // declared len = 65537
			f.files[vi.AppStatePath(id)] = enc
		}, " oversize"},
		{"malformed", func(f *stateFixture, id uint32) {
			f.files[vi.AppStatePath(id)] = []byte{1, 3, 0, 0, 0, 'x', 'y'} // len says 3, file has 2
		}, " bad"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := &stateFixture{}
			f.install(t)
			l := &sessionWriteLog{}
			l.install(t)
			if !tabs.OpenTab(9, "GoTabApp") {
				t.Fatal("OpenTab")
			}
			tc.setup(f, 9)
			if serveStateSave(saveReq(9)) {
				t.Fatal("refused staging was stored")
			}
			if tabs.At(0).State != nil {
				t.Fatal("refused blob landed on the record")
			}
			if !f.hasLog(MarkerStateDrop + "GoTabApp" + tc.wantSub) {
				t.Fatalf("drop marker missing (%q): %v", tc.wantSub, f.logs)
			}
			if len(l.writes) != 0 {
				t.Fatal("a refused save republished the session")
			}
		})
	}
}

func TestServeStateRestoreHandsBackConsumeOnce(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	l := &sessionWriteLog{}
	l.install(t)

	if !tabs.OpenTab(9, "GoTabApp") {
		t.Fatal("OpenTab")
	}
	blob := []byte("shelf position 3")
	if !tabs.SetState(9, 4, blob) {
		t.Fatal("SetState")
	}

	var r vi.WmRpc
	r.Kind = vi.WmRpcKindRestoreState
	r.ID = 9
	if !serveStateRestore(r) {
		t.Fatal("restore with stored state was refused")
	}
	// The envelope is staged at the app's rendezvous path and the seat's
	// copy is consumed — a second request is the honest empty answer.
	enc, ok := f.files[vi.AppStatePath(9)]
	if !ok {
		t.Fatal("no staged envelope")
	}
	ver, got, ok := vi.DecodeAppState(enc)
	if !ok || ver != 4 || !bytes.Equal(got, blob) {
		t.Fatalf("staged envelope ver=%d blob=%x", ver, got)
	}
	if tabs.At(0).State != nil {
		t.Fatal("seat kept its copy after staging")
	}
	if serveStateRestore(r) {
		t.Fatal("a second restore re-served a consumed blob")
	}
	if !f.hasLog(MarkerStateRestore + "9 len=16 ver=4") {
		t.Fatalf("no restore marker: %v", f.logs)
	}
}

func TestAskCollectLifecycle(t *testing.T) {
	f := &stateFixture{}
	f.install(t)

	if !tabs.OpenTab(9, "GoTabApp") {
		t.Fatal("OpenTab")
	}
	// Unbound id: no notice, no latch.
	if askStateSave(9, "close") {
		t.Fatal("asked an unbound tab")
	}
	rpcBindings[9] = rpcBinding{pid: 21, token: 0xBEEF}
	if !askStateSave(9, "close") {
		t.Fatal("ask not posted for a bound tab")
	}
	if !stateAskPend[9] {
		t.Fatal("ask latch not set")
	}
	if len(f.notices) != 1 {
		t.Fatalf("notices = %d want 1", len(f.notices))
	}
	n := f.notices[0]
	if n.Kind != vi.WmRpcKindSaveState || n.ID != 9 ||
		n.Pad != vi.WmRpcPadBound || vi.WmAuth(n) != 0xBEEF || n.ReplyTo != 0 {
		t.Fatalf("notice = %+v", n)
	}
	if !f.hasLog(MarkerStateAsk + "9 close") {
		t.Fatalf("no ask marker: %v", f.logs)
	}

	// A silent app costs the full round budget, then the latch is dropped.
	collectStateAsks()
	if f.drains != stateAskRounds {
		t.Fatalf("drains = %d want %d", f.drains, stateAskRounds)
	}
	if f.yields != stateAskRounds {
		t.Fatalf("yields = %d want %d", f.yields, stateAskRounds)
	}
	if !stateAskPend[9] {
		t.Fatal("collect cleared an unanswered ask latch")
	}

	// An app that answers mid-collect ends the loop early: the drain stub
	// stages the envelope and services the request itself.
	f.drains, f.yields = 0, 0
	f.stage(9, 1, []byte("x"))
	f.drainFn = func() int {
		serveStateSave(saveReq(9))
		return 1
	}
	stateAskPend[9] = true
	collectStateAsks()
	if f.drains != 1 {
		t.Fatalf("answered collect drained %d rounds want 1", f.drains)
	}
	if tabs.At(0).State == nil {
		t.Fatal("collected answer was not stored")
	}
}

func TestCloseCapturesStateIntoLIFO(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	l := &sessionWriteLog{}
	l.install(t)

	if !tabs.OpenTab(9, "GoTabApp") {
		t.Fatal("OpenTab")
	}
	rpcBindings[9] = rpcBinding{pid: 21, token: 1}
	// The stubbed drain plays the app: stage + service on the first pass.
	f.drainFn = func() int {
		f.stage(9, 3, []byte("closing bytes"))
		serveStateSave(saveReq(9))
		return 1
	}
	if !closeTabByID(9) {
		t.Fatal("closeTabByID")
	}
	c, ok := tabs.ReopenLastClosed()
	if !ok {
		t.Fatal("no closed entry recorded")
	}
	if !bytes.Equal(c.State, []byte("closing bytes")) || c.StateVer != 3 {
		t.Fatalf("closed entry state = %x ver %d", c.State, c.StateVer)
	}
}

func TestReopenStagesPendingState(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	l := &sessionWriteLog{}
	l.install(t)

	// A closed entry carrying a blob: reopen execs the bin and the staged
	// pending record rides the pid until the app declares.
	if !tabs.OpenTab(9, "GoTabApp") {
		t.Fatal("OpenTab")
	}
	_ = tabs.SetState(9, 2, []byte("reopen me"))
	tabs.CloseTab(9)

	oldExec := execApp
	t.Cleanup(func() { execApp = oldExec })
	execApp = func(bin string, args ...string) (int64, error) { return 77, nil }
	oldAlive := procsAlive
	t.Cleanup(func() { procsAlive = oldAlive })
	procsAlive = func(uint8) bool { return true }

	if !applyReopen() {
		t.Fatal("applyReopen")
	}
	if pendingAppStateN != 1 || pendingAppStates[0].pid != 77 {
		t.Fatalf("pending states = %+v n=%d", pendingAppStates, pendingAppStateN)
	}
	// The declaring pid's row inherits the blob.
	if !tabs.OpenTab(42, "GoTabApp") {
		t.Fatal("OpenTab for the reopened pid")
	}
	adoptPendingState(77, 42)
	if pendingAppStateN != 0 {
		t.Fatal("pending state not consumed")
	}
	if !bytes.Equal(tabs.At(0).State, []byte("reopen me")) || tabs.At(0).StateVer != 2 {
		t.Fatalf("reopened row state = %x ver %d", tabs.At(0).State, tabs.At(0).StateVer)
	}
	// A dead pid's staged blob is evicted instead of lingering.
	stagePendingState(88, 1, []byte("dead"))
	procsAlive = func(pid uint8) bool { return pid != 88 }
	stagePendingState(89, 1, []byte("alive"))
	if pendingAppStateN != 1 || pendingAppStates[0].pid != 89 {
		t.Fatalf("dead pending not evicted: %+v", pendingAppStates[:pendingAppStateN])
	}
}

func TestClearAppStateDiesWithBinding(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	stateAskPend[9] = true
	f.files[vi.AppStatePath(9)] = []byte("orphan")
	clearAppState(9)
	if stateAskPend[9] {
		t.Fatal("ask latch survived teardown")
	}
	if _, ok := f.files[vi.AppStatePath(9)]; ok {
		t.Fatal("orphan staging survived teardown")
	}
}

func TestSessionStateRoundTripDrops(t *testing.T) {
	f := &stateFixture{}
	f.install(t)

	var s TabStrip
	if !s.OpenTab(1, "A") || !s.OpenTab(2, "B") || !s.OpenTab(3, "C") {
		t.Fatal("OpenTab")
	}
	_ = s.SetState(1, 5, []byte("blob-a"))
	_ = s.SetState(3, 9, []byte("blob-c"))
	raw, dropped, ok := s.encodeTabsV2(1)
	if !ok || len(dropped) != 0 {
		t.Fatalf("encode ok=%v dropped=%v", ok, dropped)
	}
	_, recs, _, _, drops, ok := decodeTabsV2(raw)
	if !ok || len(drops) != 0 {
		t.Fatalf("decode ok=%v drops=%v", ok, drops)
	}
	if !bytes.Equal(recs[0].State, []byte("blob-a")) || recs[0].StateVer != 5 ||
		recs[1].State != nil || !bytes.Equal(recs[2].State, []byte("blob-c")) || recs[2].StateVer != 9 {
		t.Fatalf("round-trip = %+v", recs)
	}

	// An oversized trailer blob is dropped BY NAME; its record and its
	// siblings survive.
	raw2, _, _ := s.encodeTabsV2(1)
	// Locate C's entry: entries are emitted in order, A then C.
	off := tabsV2HeaderBytes + 3*tabsV2RecordBytes + tabsV2AppStateHdr
	off += tabsV2AppStateEntry + 6 // A's entry + blob
	raw2[off+4], raw2[off+5] = 0x01, 0x00
	raw2[off+6], raw2[off+7] = 0x01, 0x00 // len = 0x00010001 = 65537
	_, recs2, _, _, drops2, ok := decodeTabsV2(raw2)
	if !ok {
		t.Fatal("oversize trailer blob corrupted the decode")
	}
	if len(drops2) != 1 || drops2[0] != "C oversize" {
		t.Fatalf("drops = %v want [C oversize]", drops2)
	}
	if recs2[2].State != nil {
		t.Fatal("oversize blob was stored")
	}
	if !bytes.Equal(recs2[0].State, []byte("blob-a")) {
		t.Fatal("a sibling's blob was eaten by the oversized one")
	}

	// An orphaned index drops by index name; a truncated entry drops too.
	raw3, _, _ := s.encodeTabsV2(1)
	hdr := tabsV2HeaderBytes + 3*tabsV2RecordBytes
	raw3[hdr+tabsV2AppStateHdr] = 99 // A's index -> 99
	_, recs3, _, _, drops3, ok := decodeTabsV2(raw3)
	if !ok || len(drops3) != 1 || drops3[0] != "#99 orphan" {
		t.Fatalf("orphan drops = %v ok=%v", drops3, ok)
	}
	// The orphan's declared body is stepped over — C's entry still parses.
	if !bytes.Equal(recs3[2].State, []byte("blob-c")) || recs3[2].StateVer != 9 {
		t.Fatal("orphan entry ate its sibling's blob")
	}
	// Foreign magic/version: the whole section is ignored, records decode.
	raw4, _, _ := s.encodeTabsV2(1)
	raw4[hdr] = 'X'
	_, recs4, _, _, drops4, ok := decodeTabsV2(raw4)
	if !ok || drops4 != nil || recs4[0].State != nil {
		t.Fatalf("foreign section: drops=%v state=%x", drops4, recs4[0].State)
	}
}
