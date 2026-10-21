package main

import (
	"testing"

	"virelai/tabapp"
	"virelai/vi"
)

// state_test.go pins the M125b (#2587) codec and the restore rules the live
// go-wm-tabs leg drives: round-trip field identity, dirty ring replay onto
// the base, stale-blob degrades that never crash, and the 64 KiB cap's
// oldest-first truncation.

// stateEditor builds an editor as load() leaves it for a file of `text`:
// buffer and base aliased, disk fingerprint recorded, caret at the end.
func stateEditor(text string) *editor {
	b := []byte(text)
	e := &editor{doc: doc{path: "/host/EDIT/X.TXT", buf: b, base: b, cur: len(b)}}
	e.diskLen = len(b)
	e.diskHash = fnv1a64(b)
	return e
}

// fileState is the "next boot" half: a fresh editor whose bufRead seam
// serves `file` (or fails it), then load() + the blob apply. It exercises
// the same path main() runs rather than hand-setting fields.
func fileState(t *testing.T, file []byte, ok bool, blob []byte) *editor {
	t.Helper()
	old := bufRead
	defer func() { bufRead = old }()
	bufRead = func(string, int) ([]byte, int64) {
		if !ok {
			return nil, -2
		}
		return file, 0
	}
	e := &editor{doc: doc{path: "/host/EDIT/X.TXT"}}
	e.noteState(blob)
	e.load()
	e.applyRestored()
	return e
}

// saveEdit applies a one-splice op and marks the editor dirty, the same
// shape applyOp records for real edits.
func saveEdit(e *editor, pos int, old, ins string) {
	e.hist.breakRun()
	e.applyOp(editOp{kind: opEdit, sp: []splice{{
		pos: pos, old: []byte(old), ins: []byte(ins),
	}}}, pos+len(ins))
}

func decodeOK(t *testing.T, b []byte) *editState {
	t.Helper()
	sts := decodeState(b)
	if sts == nil || len(sts) == 0 {
		t.Fatal("decodeState refused a freshly encoded blob")
	}
	return sts[0]
}

func TestStateRoundTrip(t *testing.T) {
	e := stateEditor("alpha\nbeta\ngamma\n")
	saveEdit(e, 13, "mma", "X") // "gaX"
	saveEdit(e, 0, "al", "AL")
	e.cur, e.sel, e.selSet = 12, 14, true
	e.findHist = [][]byte{[]byte("mma"), []byte("beta")}
	e.gotoHist = []int{2, 3}

	st := decodeOK(t, e.saveState())
	if !st.dirty || !st.selSet || st.shell || st.hasBase {
		t.Fatalf("flags dirty=%v sel=%v shell=%v base=%v", st.dirty, st.selSet, st.shell, st.hasBase)
	}
	if st.cur != 12 || st.sel != 14 || st.path != e.path {
		t.Fatalf("cur=%d sel=%d path=%q", st.cur, st.sel, st.path)
	}
	if st.bufHash != fnv1a64(e.buf) || st.diskHash != fnv1a64(e.base) {
		t.Fatal("fingerprints drifted")
	}
	if len(st.undo) != 2 || len(st.redo) != 0 || st.dropped != 0 {
		t.Fatalf("rings undo=%d redo=%d dropped=%d", len(st.undo), len(st.redo), st.dropped)
	}
	o := st.undo[0]
	if o.kind != opEdit || len(o.sp) != 1 || string(o.sp[0].old) != "mma" || string(o.sp[0].ins) != "X" || o.sp[0].pos != 13 {
		t.Fatalf("op0 = %+v", o)
	}
	if len(st.finds) != 2 || string(st.finds[1]) != "beta" || len(st.gotos) != 2 || st.gotos[0] != 2 {
		t.Fatalf("histories finds=%q gotos=%v", st.finds, st.gotos)
	}
}

// The clean restore: B is the file verbatim, the ring comes back whole and
// a pop reverts exactly the op it was saved with.
func TestStateRestoreClean(t *testing.T) {
	src := stateEditor("alpha\nbeta\ngamma\n")
	saveEdit(src, 13, "mma", "X") // "alpha\nbeta\ngaX\n"
	src.dirty = false
	src.diskLen, src.diskHash = len(src.buf), fnv1a64(src.buf) // saved
	src.cur, src.sel, src.selSet = 12, 14, true

	// The "next boot" editor loads the SAME file (the save landed).
	dst := fileState(t, []byte("alpha\nbeta\ngaX\n"), true, src.saveState())

	if string(dst.buf) != "alpha\nbeta\ngaX\n" {
		t.Fatalf("buf %q", dst.buf)
	}
	if dst.cur != 12 || !dst.selSet || dst.sel != 14 {
		t.Fatalf("cur=%d sel=%d set=%v", dst.cur, dst.sel, dst.selSet)
	}
	if len(dst.hist.undo) != 1 || dst.hist.open {
		t.Fatalf("undo=%d open=%v", len(dst.hist.undo), dst.hist.open)
	}
	// The restored ring must function, not just parse.
	o, ok := dst.hist.popUndo()
	if !ok || string(o.sp[0].ins) != "X" {
		t.Fatal("restored undo op is not the saved one")
	}
	if got := string(applySplices(dst.buf, o.sp, true)); got != "alpha\nbeta\ngamma\n" {
		t.Fatalf("revert produced %q", got)
	}
}

// The dirty restore with no intervening save: the file IS the base, and
// replaying the ring rebuilds the unsaved buffer.
func TestStateRestoreDirtyReplay(t *testing.T) {
	src := stateEditor("one\ntwo\n")
	saveEdit(src, 0, "one", "ONE")
	saveEdit(src, 7, "", "!") // "ONE\ntwo!\n"
	src.cur = 8
	src.findHist = [][]byte{[]byte("two")}

	dst := fileState(t, []byte("one\ntwo\n"), true, src.saveState())

	if string(dst.buf) != "ONE\ntwo!\n" {
		t.Fatalf("replayed buf %q", dst.buf)
	}
	if !dst.dirty || dst.cur != 8 {
		t.Fatalf("dirty=%v cur=%d", dst.dirty, dst.cur)
	}
	if len(dst.findHist) != 1 || string(dst.findHist[0]) != "two" {
		t.Fatal("find history lost")
	}
}

// The dirty restore AFTER a save: the file is no longer the ring's anchor,
// so the base bytes ride the blob and replay rebuilds from them.
func TestStateRestoreDirtySaved(t *testing.T) {
	src := stateEditor("aa\n")
	saveEdit(src, 3, "", "bb") // "aa\nbb"
	src.dirty = false
	src.diskLen, src.diskHash = 5, fnv1a64([]byte("aa\nbb")) // saved mid-session
	saveEdit(src, 5, "", "cc")                               // dirty: "aa\nbbcc"
	src.cur = 7

	st := decodeOK(t, src.saveState())
	if !st.hasBase || string(st.base) != "aa\n" {
		t.Fatalf("hasBase=%v base=%q", st.hasBase, st.base)
	}

	dst := fileState(t, []byte("aa\nbb"), true, src.saveState())

	if string(dst.buf) != "aa\nbbcc" || !dst.dirty || dst.cur != 7 {
		t.Fatalf("buf=%q dirty=%v cur=%d", dst.buf, dst.dirty, dst.cur)
	}
}

// Every stale shape degrades to the plain open — the card's rule — and none
// of them may panic.
func TestStateStaleDegrades(t *testing.T) {
	// File changed under the blob.
	src := stateEditor("orig\n")
	saveEdit(src, 5, "", "X")
	dst := fileState(t, []byte("CHANGED\n"), true, src.saveState())
	if string(dst.buf) != "CHANGED\n" || dst.dirty || dst.cur != len(dst.buf) {
		t.Fatalf("stale file restore touched state: buf=%q dirty=%v cur=%d",
			dst.buf, dst.dirty, dst.cur)
	}

	// File missing under the blob.
	dst = fileState(t, nil, false, src.saveState())
	if len(dst.buf) != 0 || dst.cur != 0 {
		t.Fatalf("missing-file restore kept blob state: len=%d cur=%d",
			len(dst.buf), dst.cur)
	}

	// A full ring already evicted ops — replay would lie, so shell out.
	src = stateEditor("r\n")
	saveEdit(src, 2, "", "Y")
	src.hist.dropped = 3
	dst = fileState(t, []byte("r\n"), true, src.saveState())
	if dst.dirty || len(dst.hist.undo) != 0 {
		t.Fatal("a dropped ring must not restore as live history")
	}
	// … but the path still carried.
	if dst.path != "/host/EDIT/X.TXT" {
		t.Fatalf("shell blob lost path: %q", dst.path)
	}
}

// The envelope's appver is the app's refusal check: a blob that decodes
// fine but was stored under a foreign version must not apply — the seat
// carried it verbatim and owns no opinion about the format.
func TestStateStaleVersion(t *testing.T) {
	src := stateEditor("a\n")
	saveEdit(src, 2, "", "!")
	e := stateEditor("a\n")
	e.ta = &tabapp.TabApp{RestoredVersion: stateAppVer + 1}
	e.noteState(src.saveState())
	e.applyRestored()
	if e.dirty || e.cur != len(e.buf) || len(e.hist.undo) != 0 {
		t.Fatal("a foreign appver applied anyway")
	}
}

// The shell blob still delivers path + histories — the file reopens right
// even when the rings could not ride.
func TestStateShellKeepsPath(t *testing.T) {
	src := stateEditor("z\n")
	saveEdit(src, 2, "", "w")
	src.findHist = [][]byte{[]byte("w")}
	src.hist.dropped = 1
	b := src.saveState()
	st := decodeOK(t, b)
	if !st.shell || st.path != src.path || len(st.finds) != 1 {
		t.Fatalf("shell=%v path=%q finds=%d", st.shell, st.path, len(st.finds))
	}
	if len(st.undo) != 0 {
		t.Fatal("shell carried a ring")
	}
}

// Torn blobs must never crash and never partially apply.
func TestStateDecodeTorn(t *testing.T) {
	src := stateEditor("alpha\n")
	saveEdit(src, 5, "", "!")
	full := src.saveState()
	for i := 0; i < len(full); i++ {
		_ = decodeState(full[:i]) // nil or decoded — just no panic
	}
	for i := 0; i < len(full); i++ {
		mut := append([]byte{}, full...)
		mut[i] ^= 0xff
		_ = decodeState(mut)
	}
	// And one that decodes but hashes wrong must degrade at apply.
	src2 := stateEditor("alpha\n")
	saveEdit(src2, 5, "", "!")
	b := src2.saveState()
	st := decodeOK(t, b)
	st.bufHash ^= 1
	e := stateEditor("alpha\n")
	e.pend = []*editState{st}
	e.applyRestored()
	if e.dirty || string(e.buf) != "alpha\n" {
		t.Fatal("a mismatched buffer hash applied anyway")
	}
}

// The 64 KiB bound: a clean blob truncates its rings oldest-first until it
// fits; a dirty blob that cannot fit intact becomes a shell.
func TestStateCapBound(t *testing.T) {
	e := stateEditor("")
	// A single op carrying ~70 KiB of inserted text cannot fit.
	big := make([]byte, 70*1024)
	for i := range big {
		big[i] = 'a'
	}
	saveEdit(e, 0, "", string(big))
	e.dirty = false // clean: truncation may shorten undo
	e.diskLen, e.diskHash = len(e.buf), fnv1a64(e.buf)
	b := e.saveState()
	if len(b) > stateCapBytes {
		t.Fatalf("clean blob %d bytes over %d cap", len(b), stateCapBytes)
	}

	e2 := stateEditor("")
	saveEdit(e2, 0, "", string(big))
	b2 := e2.saveState()
	if len(b2) > stateCapBytes {
		t.Fatalf("dirty blob %d bytes over %d cap", len(b2), stateCapBytes)
	}
	st := decodeOK(t, b2)
	if !st.shell {
		t.Fatal("an unfittable dirty blob must degrade to shell")
	}
}

// Envelope discipline: the blob the seat stores is exactly encode()'s
// product, and vi's framing takes it whole.
func TestStateEnvelope(t *testing.T) {
	e := stateEditor("x\n")
	b := e.saveState()
	enc, ok := vi.EncodeAppState(stateAppVer, b)
	if !ok {
		t.Fatal("blob refused by the envelope")
	}
	v, blob, ok := vi.DecodeAppState(enc)
	if !ok || v != stateAppVer || string(blob) != string(b) {
		t.Fatal("envelope round-trip drifted")
	}
}

// History recording: bounded, newest last, a copy of the bar's storage.
func TestFindGotoHist(t *testing.T) {
	e := stateEditor("x")
	for i := 0; i < findHistCap+3; i++ {
		e.pushFind([]byte{byte('a' + i)})
	}
	if len(e.findHist) != findHistCap || string(e.findHist[0]) != "d" {
		t.Fatalf("findHist=%q — oldest-first drop expected", e.findHist)
	}
	for i := 0; i < gotoHistCap+2; i++ {
		e.pushGoto(i)
	}
	if len(e.gotoHist) != gotoHistCap || e.gotoHist[0] != 2 {
		t.Fatalf("gotoHist=%v", e.gotoHist)
	}
	// The recorded pattern must survive the bar being reused.
	e.bar = []byte("zz")
	e.pushFind(e.bar)
	e.bar[0] = 'Q'
	if string(e.findHist[len(e.findHist)-1]) != "zz" {
		t.Fatal("history aliased the bar")
	}
}
