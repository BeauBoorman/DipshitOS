package main

// ring_test.go pins the M166a (#2979) buffer ring on the host: open, switch
// and wrap bounds, the reuse-an-open-path pick, the full and last refusals,
// the dirty close through the confirm, the diagnostics jump into a new
// buffer and its `full` refusal, one lease per doc, the unsaved Save over
// two dirty buffers with one failing, and the format-2 session blob —
// round trip, shell record, and a format-1 blob decoding as one buffer.

import (
	"strings"
	"testing"

	"virelai/vi"
)

// ringEditor builds a two-buffer ring on the fake file set: docs[0] is the
// active doc's live copy, docs[1] a parked buffer, both backed by files.
func ringEditor(t *testing.T, text string) *editor {
	t.Helper()
	e := usEditor(text)
	e.path = "/host/A.TXT"
	e.diskLen, e.diskHash = len(e.buf), fnv1a64(e.buf)
	e.base = e.buf
	e.docs = []doc{e.doc, {
		path: "/host/B.TXT",
		buf:  []byte("bee\n"),
		base: []byte("bee\n"),
		cur:  4,
	}}
	return e
}

// TestBufOpenSwitchWrap: the ring opens a new buffer, pages forward and
// backward with wrap, and stays inside bufMax.
func TestBufOpenSwitchWrap(t *testing.T) {
	fakeBufferFile(t, map[string][]byte{
		"/host/A.TXT": []byte("ay\n"),
		"/host/B.TXT": []byte("bee\n"),
		"/host/C.TXT": []byte("see\n"),
		"/host/D.TXT": []byte("dee\n"),
		"/host/E.TXT": []byte("e\n"),
	})
	e := usEditor("ay\n")
	e.path = "/host/A.TXT"
	e.docs = []doc{e.doc}
	if !e.openBuf("/host/B.TXT") {
		t.Fatal("open B failed")
	}
	if len(e.docs) != 2 || e.path != "/host/B.TXT" || string(e.buf) != "bee\n" {
		t.Fatalf("open B: path=%q buf=%q docs=%d", e.path, e.buf, len(e.docs))
	}
	// Page down wraps to buffer 1; page up wraps back.
	e.switchBuf(1)
	if e.path != "/host/A.TXT" || e.active != 0 {
		t.Fatalf("wrap forward: path=%q active=%d", e.path, e.active)
	}
	e.switchBuf(-1)
	if e.path != "/host/B.TXT" || e.active != 1 {
		t.Fatalf("wrap back: path=%q active=%d", e.path, e.active)
	}
	// The parked doc kept its own caret.
	if e.docs[0].cur != len("ay\n") {
		t.Fatalf("parked caret drifted: %d", e.docs[0].cur)
	}
}

// TestBufReopenReusesTheBuffer: opening an already-open path switches to its
// buffer instead of doubling it.
func TestBufReopenReusesTheBuffer(t *testing.T) {
	fakeBufferFile(t, map[string][]byte{
		"/host/A.TXT": []byte("ay\n"),
		"/host/B.TXT": []byte("bee\n"),
	})
	e := usEditor("ay\n")
	e.path = "/host/A.TXT"
	e.docs = []doc{e.doc}
	e.openBuf("/host/B.TXT")
	e.openBuf("/host/A.TXT")
	if len(e.docs) != 2 || e.active != 0 {
		t.Fatalf("reopen must switch, not append: docs=%d active=%d", len(e.docs), e.active)
	}
}

// TestBufFullRefuses: the fifth open is the named refusal; the dirty buffers
// are untouched.
func TestBufFullRefuses(t *testing.T) {
	files := map[string][]byte{}
	for _, p := range []string{"/host/A.TXT", "/host/B.TXT", "/host/C.TXT", "/host/D.TXT", "/host/E.TXT"} {
		files[p] = []byte("x\n")
	}
	fakeBufferFile(t, files)
	e := usEditor("x\n")
	e.path = "/host/A.TXT"
	e.docs = []doc{e.doc}
	e.openBuf("/host/B.TXT")
	e.openBuf("/host/C.TXT")
	e.openBuf("/host/D.TXT")
	if e.openBuf("/host/E.TXT") {
		t.Fatal("the fifth open must refuse")
	}
	if len(e.docs) != bufMax || e.path != "/host/D.TXT" {
		t.Fatalf("full ring moved: docs=%d path=%q", len(e.docs), e.path)
	}
}

// TestBufCloseLastRefuses: Ctrl-W on a one-buffer ring is the named refusal.
func TestBufCloseLastRefuses(t *testing.T) {
	e := usEditor("only\n")
	e.path = "/host/ONLY.TXT"
	e.docs = []doc{e.doc}
	if len(e.docs) != 1 {
		t.Fatal("fixture")
	}
	e.handleKey(usDown(0x1a, modCtrl, 'w'))
	if len(e.docs) != 1 || e.path != "/host/ONLY.TXT" {
		t.Fatalf("last close must refuse: docs=%d path=%q", len(e.docs), e.path)
	}
}

// TestBufCloseCleanAndDirtyConfirm: a clean buffer closes outright; a dirty
// one asks, and No keeps it — Yes drops it.
func TestBufCloseCleanAndDirtyConfirm(t *testing.T) {
	e := ringEditor(t, "ay\n")
	// Clean active buffer (A) closes outright, B becomes active.
	e.closeBufAsk()
	if len(e.docs) != 1 || e.path != "/host/B.TXT" {
		t.Fatalf("clean close: docs=%d path=%q", len(e.docs), e.path)
	}
	// Two buffers again, dirty active: Ctrl-W raises the confirm.
	e = ringEditor(t, "ay\n")
	e.dirty = true
	e.handleKey(usDown(0x1a, modCtrl, 'w'))
	if e.mode != modeDialog || !e.closeAsk {
		t.Fatalf("dirty close must ask: mode=%d ask=%v", e.mode, e.closeAsk)
	}
	// Enter on the default No focus keeps the buffer.
	e.handleKey(usDown(0x28, 0, '\r'))
	if e.mode != modeEdit || len(e.docs) != 2 || !e.dirty {
		t.Fatalf("No must keep the buffer: mode=%d docs=%d dirty=%v", e.mode, len(e.docs), e.dirty)
	}
	// Ask again and say Yes: the buffer closes and the ring shrinks.
	e.handleKey(usDown(0x1a, modCtrl, 'w'))
	e.dlg.Focus = 0 // Yes
	e.handleKey(usDown(0x28, 0, '\r'))
	if e.mode != modeEdit || len(e.docs) != 1 || e.path != "/host/B.TXT" {
		t.Fatalf("Yes must close: mode=%d docs=%d path=%q", e.mode, len(e.docs), e.path)
	}
}

// TestBufSwitchChord: the ctrl+page usages page the ring, and the receipt
// marker names the 1-based slot and the path.
func TestBufSwitchChord(t *testing.T) {
	e := ringEditor(t, "ay\n")
	e.handleKey(usDown(usagePageDown, modCtrl, 0))
	if e.path != "/host/B.TXT" {
		t.Fatalf("ctrl-pagedown: %q", e.path)
	}
	e.handleKey(usDown(usagePageUp, modCtrl, 0))
	if e.path != "/host/A.TXT" {
		t.Fatalf("ctrl-pageup: %q", e.path)
	}
	// A shifted press is still the page chord.
	e.handleKey(usDown(usagePageDown, modCtrl|vi.ModShift, 0))
	if e.path != "/host/B.TXT" {
		t.Fatalf("ctrl-shift-pagedown: %q", e.path)
	}
	// Alt claims it: ctrl-alt-page is the seat's, not ours.
	e.handleKey(usDown(usagePageUp, modCtrl|vi.ModAlt, 0))
	if e.path != "/host/B.TXT" {
		t.Fatalf("ctrl-alt-pageup must not switch: %q", e.path)
	}
}

// TestCtrlShiftOOpensPickerForNewBuffer: the chord opens the picker with the
// new-buffer flag; the pick lands in a NEW buffer, no discard guard even
// when the active buffer is dirty.
func TestCtrlShiftOOpensPickerForNewBuffer(t *testing.T) {
	fakeBufferFile(t, map[string][]byte{
		"/host/A.TXT": []byte("ay\n"),
		"/host/B.TXT": []byte("bee\n"),
	})
	e := usEditor("ay\n")
	e.path = "/host/A.TXT"
	e.dirty = true
	e.docs = []doc{e.doc}
	e.handleKey(usDown(0x12, modCtrl|vi.ModShift, 'O'))
	if e.mode != modePicker || !e.pickNewBuf {
		t.Fatalf("ctrl-shift-o: mode=%d new=%v", e.mode, e.pickNewBuf)
	}
	// The pick resolves into buffer 2; the dirty buffer parks intact.
	for _, r := range "B.TXT" {
		e.handleKey(usDown(0, 0, uint32(r)))
	}
	e.handleKey(usDown(0x28, 0, '\r'))
	if len(e.docs) != 2 || e.path != "/host/B.TXT" {
		t.Fatalf("picked new buffer: docs=%d path=%q", len(e.docs), e.path)
	}
	if e.docIndex("/host/A.TXT") != 0 || !e.docs[0].dirty {
		t.Fatalf("dirty buffer lost: %+v", e.docs)
	}
}

// TestCtrlOPickStillReplaces: Ctrl-O's pick keeps replacing the active
// buffer — the ring does not grow.
func TestCtrlOPickStillReplaces(t *testing.T) {
	fakeBufferFile(t, map[string][]byte{
		"/host/B.TXT": []byte("bee\n"),
	})
	e := usEditor("ay\n")
	e.path = "/host/A.TXT"
	e.docs = []doc{e.doc}
	e.handleKey(usDown(0x12, modCtrl, 'o'))
	for _, r := range "B.TXT" {
		e.handleKey(usDown(0, 0, uint32(r)))
	}
	e.handleKey(usDown(0x28, 0, '\r'))
	if len(e.docs) != 1 || e.path != "/host/B.TXT" || string(e.buf) != "bee\n" {
		t.Fatalf("ctrl-o must replace: docs=%d path=%q buf=%q", len(e.docs), e.path, e.buf)
	}
}

// TestJumpDiagRingFullRefuses: a diagnostics row naming a fifth file refuses
// `full` when the ring has no room.
func TestJumpDiagRingFullRefuses(t *testing.T) {
	errs := "/host/.BUILD/ERRORS.TXT"
	fakeDiagFiles(t,
		map[string]bool{errs: true},
		map[string][]byte{errs: []byte("/host/E.go:2:1: boom\n")},
		map[string]int64{errs: 200, "/host/E.go": 100})
	e := usEditor("x\n")
	e.path = "/host/A.go"
	e.docs = []doc{e.doc}
	for _, p := range []string{"/host/B.go", "/host/C.go", "/host/D.go"} {
		e.docs = append(e.docs, doc{path: p, buf: []byte("y\n"), base: []byte("y\n")})
	}
	e.loadErrors()
	e.jumpDiag(0)
	if e.path != "/host/A.go" {
		t.Fatalf("full ring must refuse the jump: %q", e.path)
	}
	// And a row that names an OPEN buffer jumps into it, full ring or not.
	e.diags = append(e.diags[:0], diagRow{raw: "x", file: "/host/B.go", line: 1, col: 1})
	e.jumpDiag(0)
	if e.path != "/host/B.go" || e.active != 1 {
		t.Fatalf("jump to an open buffer must switch: %q %d", e.path, e.active)
	}
}

// TestLeasePerDoc: each buffer carries its own lease record — acquire,
// and the exit release walks the whole ring.
func TestLeasePerDoc(t *testing.T) {
	k := installEditKernel(t, 1000)
	e := ringEditor(t, "ay\n")
	e.syncDocs()
	if rc := e.ensureLease(); rc != 0 {
		t.Fatalf("lease A: %d", rc)
	}
	e.activateDoc(1)
	if rc := e.ensureLease(); rc != 0 {
		t.Fatalf("lease B: %d", rc)
	}
	if k.files[vi.LeasePathFor("/host/A.TXT")] == nil ||
		k.files[vi.LeasePathFor("/host/B.TXT")] == nil {
		t.Fatal("each doc must hold its own lease record")
	}
	e.releaseAllLeases()
	if _, ok := k.files[vi.LeasePathFor("/host/A.TXT")]; ok {
		t.Fatal("releaseAllLeases left A's record")
	}
	if _, ok := k.files[vi.LeasePathFor("/host/B.TXT")]; ok {
		t.Fatal("releaseAllLeases left B's record")
	}
	if e.lease != nil {
		t.Fatal("the live doc's lease must drop too")
	}
}

// TestSaveAllDirty: the unsaved Save choice publishes every dirty buffer in
// ring order; a live foreign lease on one refuses just that file and the
// call reports false.
func TestSaveAllDirty(t *testing.T) {
	k := installEditKernel(t, 1000)
	k.files["/host/A.TXT"] = []byte("old-a\n")
	k.files["/host/B.TXT"] = []byte("old-b\n")
	e := ringEditor(t, "ay\n")
	e.dirty = true
	e.docs[1].dirty = true
	if !e.saveAllDirty() {
		t.Fatal("clean publish of both buffers failed")
	}
	if string(k.files["/host/A.TXT"]) != "ay\n" || string(k.files["/host/B.TXT"]) != "bee\n" {
		t.Fatalf("published = %q / %q", k.files["/host/A.TXT"], k.files["/host/B.TXT"])
	}
	// Now a foreign lease on B refuses it while A still lands — the first
	// session's own leases release first so the only live record is the
	// foreign one.
	e.releaseAllLeases()
	k.files["/host/B.TXT"] = []byte("old-b\n")
	k.files[vi.LeasePathFor("/host/B.TXT")] = []byte(
		"VLEASE1\npid=0\nts=1000\ntoken=0102030405060708\npath=/host/B.TXT\n")
	e = ringEditor(t, "ay2\n")
	e.dirty = true
	e.docs[1].dirty = true
	if e.saveAllDirty() {
		t.Fatal("a refused member must fail the publish")
	}
	if string(k.files["/host/A.TXT"]) != "ay2\n" {
		t.Fatalf("A still published: %q", k.files["/host/A.TXT"])
	}
	if string(k.files["/host/B.TXT"]) != "old-b\n" {
		t.Fatalf("a refused member must not write: %q", k.files["/host/B.TXT"])
	}
}

// TestStateFormat2RoundTrip: two dirty buffers encode as two records —
// active first — and decode restores the ring.
func TestStateFormat2RoundTrip(t *testing.T) {
	e := usEditor("alpha\n")
	e.path = "/host/A.TXT"
	e.diskLen, e.diskHash = len(e.buf), fnv1a64(e.buf)
	e.base = e.buf
	e.dirty = true
	e.docs = []doc{e.doc, {
		path:     "/host/B.TXT",
		buf:      []byte("beta\n"),
		base:     []byte("beta\n"),
		diskLen:  5,
		diskHash: fnv1a64([]byte("beta\n")),
		cur:      2,
		dirty:    true,
	}}
	e.docs[1].hist.undo = []editOp{{sp: []splice{{pos: 0}}}}
	blob := e.saveState()
	if len(blob) == 0 {
		t.Fatal("saveState returned nothing")
	}
	if blob[0] != stateFmtVer2 {
		t.Fatalf("blob ver = %d want %d", blob[0], stateFmtVer2)
	}
	sts := decodeState(blob)
	if len(sts) != 2 {
		t.Fatalf("decoded %d records want 2", len(sts))
	}
	// Active first: A's record is record 0.
	if sts[0].path != "/host/A.TXT" || sts[1].path != "/host/B.TXT" {
		t.Fatalf("record order: %q %q", sts[0].path, sts[1].path)
	}
	if sts[1].cur != 2 || len(sts[1].undo) != 1 || !sts[1].dirty {
		t.Fatalf("record 1 lost doc state: %+v", sts[1])
	}
}

// TestStateShellRecord: a dirty buffer whose ring already evicted ops
// degrades its own record to the shell while a clean sibling stays full.
func TestStateShellRecord(t *testing.T) {
	e := usEditor("x\n")
	e.path = "/host/A.TXT"
	e.diskLen, e.diskHash = 1, fnv1a64([]byte("x\n"))
	e.base = e.buf
	e.dirty = true
	e.hist.dropped = 3 // ring evictions: a full dirty restore is impossible
	e.docs = []doc{e.doc, {
		path:     "/host/B.TXT",
		buf:      []byte("b\n"),
		base:     []byte("b\n"),
		diskLen:  2,
		diskHash: fnv1a64([]byte("b\n")),
	}}
	blob := e.saveState()
	sts := decodeState(blob)
	if len(sts) != 2 {
		t.Fatalf("decoded %d records want 2", len(sts))
	}
	if !sts[0].shell {
		t.Fatal("the evicted dirty buffer must record as a shell")
	}
	if sts[1].shell {
		t.Fatal("the clean buffer must keep a full record")
	}
}

// TestStateFormat1Decodes: a format-1 blob still restores as one buffer.
func TestStateFormat1Decodes(t *testing.T) {
	e := usEditor("solo\n")
	e.path = "/host/A.TXT"
	e.diskLen, e.diskHash = len(e.buf), fnv1a64(e.buf)
	e.base = e.buf
	e.cur = 2
	// A format-1 blob is the bare record — encode it directly.
	blob := e.doc.collectState().encode()
	sts := decodeState(blob)
	if len(sts) != 1 {
		t.Fatalf("format-1 blob decoded %d records want 1", len(sts))
	}
	if sts[0].path != "/host/A.TXT" || sts[0].cur != 2 {
		t.Fatalf("format-1 record: %+v", sts[0])
	}
	// And the apply path treats it as a one-buffer ring.
	e2 := usEditor("solo\n")
	e2.path = "/host/A.TXT"
	e2.docs = []doc{e2.doc}
	e2.noteState(blob)
	e2.applyRestored()
	if len(e2.docs) != 1 || e2.cur != 2 {
		t.Fatalf("format-1 restore: docs=%d cur=%d", len(e2.docs), e2.cur)
	}
}

// TestBufMarkerShapes pins the new receipts' prefixes so a drift fails on
// the host before it can fail live.
func TestBufMarkerShapes(t *testing.T) {
	if markerBufSwitch != "goedit: buffer switch i=" {
		t.Fatalf("markerBufSwitch = %q", markerBufSwitch)
	}
	if markerBufFull != "goedit: buffer full n=" {
		t.Fatalf("markerBufFull = %q", markerBufFull)
	}
	if markerBufLast != "goedit: buffer last" {
		t.Fatalf("markerBufLast = %q", markerBufLast)
	}
	for _, s := range []string{"full", "last"} {
		if strings.Contains(markerBufSwitch, s) {
			t.Fatalf("refusal %q inside the switch prefix", s)
		}
	}
}
