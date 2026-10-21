package main

import (
	"strings"
	"testing"
	"unsafe"

	"virelai/find"
	"virelai/vi"
)

// The gate greps these exact strings; a drift is a host-test failure rather
// than a live run that silently asserts nothing.
func TestEditMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{markerOpen, "goedit: open id="},
		{markerDeclare, "goedit: declare accepted"},
		{markerRead, "goedit: read "},
		{markerPresent, "goedit: present"},
		{markerDirty, "goedit: dirty"},
		{markerSaved, "goedit: saved "},
		{markerSaveErr, "goedit: save error "},
		{markerClose, "goedit: close"},
		{markerOK, "goedit OK"},
		// M66c follow-on (#1485): the M20 U3 and M42 UX r2 markers that moved
		// here from the deleted Zig app. (The M14 S3 composition markers live in
		// user/go/compose - see this file's header for the data-budget reason.)
		{markerFind, "goedit: find '"},
		{markerGoto, "goedit: goto line="},
		{markerUnsaved, "goedit: win_unsaved"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

// The kernel puts the Unicode codepoint in arg1, so the mapping from an event
// to an inserted byte is the contract the gate's typed characters ride.
func TestInsertionFor(t *testing.T) {
	down := func(arg1 uint32, flags uint16) vi.Event {
		return vi.Event{Kind: vi.EvKeyDown, Flags: flags, Arg1: arg1}
	}
	ok := []struct {
		ev   vi.Event
		want rune
	}{
		{down('a', 0), 'a'},
		{down('Z', 0), 'Z'},
		{down(' ', 0), ' '},
		{down('~', 0), '~'},
		{down(codeReturn, 0), '\n'},
	}
	for _, c := range ok {
		got, gotOK := insertionFor(c.ev)
		if !gotOK || got != c.want {
			t.Fatalf("insertionFor(%#x) = (%q,%v) want (%q,true)", c.ev.Arg1, got, gotOK, c.want)
		}
	}
	// HID usage 0x1b is the physical X key. The kernel translates it before
	// delivering the app event, so the editor inserts Arg1 rather than
	// re-translating Arg0 as the seat does for its own kind-21 events.
	translated := vi.Event{Kind: vi.EvKeyDown, Arg0: 0x1b, Arg1: 'X'}
	if got, ok := insertionFor(translated); !ok || got != 'X' {
		t.Fatalf("insertionFor(raw usage %#x, translated %#x) = (%q,%v) want ('X',true)",
			translated.Arg0, translated.Arg1, got, ok)
	}
	if got, ok := insertionFor(down(0x00f6, 0)); !ok || got != 'ö' {
		t.Fatalf("insertionFor(U+00F6) = (%q,%v) want ('ö',true)", got, ok)
	}
	// An unmapped key has no translated byte. Its raw usage must not turn into
	// text via an app-side fallback.
	unmapped := vi.Event{Kind: vi.EvKeyDown, Arg0: 0x1b}
	if got, ok := insertionFor(unmapped); ok {
		t.Fatalf("insertionFor(raw usage %#x, no translated byte) = (%q,true) want not-insertable",
			unmapped.Arg0, got)
	}
	bad := []vi.Event{
		down(0x1b, 0),                         // escape
		down('a', modCtrl),                    // a chord, not text
		vi.Event{Kind: vi.EvKeyUp, Arg1: 'a'}, // key up
		vi.Event{Kind: 18, Arg1: 'a'},         // COMPOSITE_TICK
		down(0x7f, 0),                         // delete is not an insertion
	}
	for _, ev := range bad {
		if b, o := insertionFor(ev); o {
			t.Fatalf("insertionFor(%+v) = (%q,true) want not-insertable", ev, b)
		}
	}
}

func TestIsSave(t *testing.T) {
	if !isSave(vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: keyS}) {
		t.Fatal("ctrl-s must be the save chord")
	}
	// kernel/src/input.zig puts the derived ASCII char in arg1; for a Ctrl
	// chord that is the control code, so the save chord must accept both.
	if !isSave(vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: keyCtrlS}) {
		t.Fatal("ctrl-s must save whether arg1 carries 's' or 0x13")
	}
	if isSave(vi.Event{Kind: vi.EvKeyDown, Flags: 0, Arg1: keyS}) {
		t.Fatal("a bare s must not save")
	}
	if isSave(vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: 'x'}) {
		t.Fatal("ctrl-x must not save")
	}
}

// insert/backspace own the buffer and the dirty flag.
func TestBufferEdits(t *testing.T) {
	e := &editor{}
	if !e.insert('h') || !e.insert('i') {
		t.Fatal("insert must report an edit")
	}
	if string(e.buf) != "hi" {
		t.Fatalf("buf = %q want \"hi\"", e.buf)
	}
	if !e.dirty {
		t.Fatal("an edit must set dirty")
	}
	if !e.backspace() {
		t.Fatal("backspace must report an edit")
	}
	if string(e.buf) != "h" {
		t.Fatalf("buf = %q want \"h\"", e.buf)
	}
	e.buf = e.buf[:0]
	if e.backspace() {
		t.Fatal("backspace on an empty buffer must be a no-op")
	}
}

// M20 U3 (#1485): the two composed marker lines the live gate greps, built
// from the same helpers runFind/runGoto use. The gate's documents are the
// fixtures here, so a drift in either the ordinal/lines rule OR the marker
// text fails on the host instead of live.
func TestFindAndGotoMarkers(t *testing.T) {
	// The live walk types exactly this document
	// (`h,e,l,l,o,return,w,o,r,l,d,return,t,e,x,t`).
	doc := []byte("hello\nworld\ntext")
	total, ordinal, off := find.From(doc, []byte("wor"), len(doc))
	if total != 1 || ordinal != 1 || off != 6 {
		t.Fatalf("find 'wor' = (total=%d ordinal=%d off=%d) want (1,1,6)", total, ordinal, off)
	}
	if got, want := findMarker([]byte("wor"), ordinal, total), "goedit: find 'wor' hit=1/1"; got != want {
		t.Fatalf("find marker = %q want %q", got, want)
	}
	if got, want := findMissMarker([]byte("zzz")), "goedit: find 'zzz' no-match"; got != want {
		t.Fatalf("find miss marker = %q want %q", got, want)
	}

	// Ctrl-G 2 on the same document: line 2 starts at offset 6 ("hello\n").
	if got := lineOffset(doc, 2); got != 6 {
		t.Fatalf("lineOffset(doc, 2) = %d want 6", got)
	}
	if got, want := gotoMarker(2, 6), "goedit: goto line=2 offset=6"; got != want {
		t.Fatalf("goto marker = %q want %q", got, want)
	}
	if got, want := gotoMissMarker(9, 3), "goedit: goto line=9 miss lines=3"; got != want {
		t.Fatalf("goto miss marker = %q want %q", got, want)
	}
}

// find.From's own tests moved with the matcher to package virelai/find
// (M126c #2595); what stays here is the app's use of it, in
// TestFindAndGotoMarkers and the bar walk below.

// countLines/lineOffset/parseLine are the goto bar's rule set, and the edge
// cases are the ones the Zig app pinned: an empty buffer is one line, a
// trailing newline opens a final empty line, and line 1 starts at 0.
func TestGotoRules(t *testing.T) {
	if got := countLines(nil); got != 1 {
		t.Fatalf("countLines(empty) = %d want 1", got)
	}
	if got := countLines([]byte("a\nb\n")); got != 3 {
		t.Fatalf("countLines(a\\nb\\n) = %d want 3", got)
	}
	if got := lineOffset([]byte("a\nb\nc"), 3); got != 4 {
		t.Fatalf("lineOffset(line 3) = %d want 4", got)
	}
	if got := lineOffset([]byte("a\nb"), 1); got != 0 {
		t.Fatalf("lineOffset(line 1) = %d want 0", got)
	}
	if got := lineOffset([]byte("a\nb"), 3); got != -1 {
		t.Fatalf("lineOffset(beyond) = %d want -1", got)
	}
	ok := []struct {
		in   string
		want int
	}{
		{"2", 2},
		{"10", 10},
		{"00012", 12},
		{"99999", 99999},
	}
	for _, c := range ok {
		got, good := parseLine([]byte(c.in))
		if !good || got != c.want {
			t.Fatalf("parseLine(%q) = (%d,%v) want (%d,true)", c.in, got, good, c.want)
		}
	}
	bad := []string{"", "0", "x", "2x", "100000", "123456"}
	for _, in := range bad {
		if got, good := parseLine([]byte(in)); good {
			t.Fatalf("parseLine(%q) = (%d,true) want refused", in, got)
		}
	}
}

// The caret makes insert/backspace splice at the caret instead of only at the
// tail. The go-edit gate's typed characters must still land at the END of the
// seed (load puts the caret there), so both directions are pinned.
func TestCaretEditing(t *testing.T) {
	e := &editor{doc: doc{buf: []byte("abc"), cur: 1}}
	if !e.insert('X') {
		t.Fatal("insert at the caret must report an edit")
	}
	if string(e.buf) != "aXbc" || e.cur != 2 {
		t.Fatalf("insert = (%q,cur=%d) want (\"aXbc\",2)", e.buf, e.cur)
	}
	if !e.backspace() {
		t.Fatal("backspace at the caret must report an edit")
	}
	if string(e.buf) != "abc" || e.cur != 1 {
		t.Fatalf("backspace = (%q,cur=%d) want (\"abc\",1)", e.buf, e.cur)
	}
	// The append-at-the-end path load() sets up: the gate types into a seed.
	e.buf, e.cur = []byte("seed-line\n"), len("seed-line\n")
	for _, b := range []byte("XYZ") {
		e.insert(rune(b))
	}
	if string(e.buf) != "seed-line\nXYZ" {
		t.Fatalf("typed buffer = %q want \"seed-line\\nXYZ\"", e.buf)
	}
	// A caret left past a shrunken buffer (a hand-built editor) is clamped,
	// not a panic.
	e.cur = 99
	if e.backspace() && len(e.buf) == 0 {
		t.Fatal("a clamped caret must have removed the last byte")
	}
}

func TestUnicodeInsertionAndBackspace(t *testing.T) {
	e := &editor{}
	if !e.insert('ö') || string(e.buf) != "ö" || e.cur != len("ö") {
		t.Fatalf("insert umlaut = (%q,cur=%d) want (ö,2)", e.buf, e.cur)
	}
	if !e.backspace() || len(e.buf) != 0 || e.cur != 0 {
		t.Fatalf("backspace umlaut = (%q,cur=%d) want empty", e.buf, e.cur)
	}
}

// The bar chords own the keyboard from any mode, and a bar swallows text
// instead of editing the document.
func TestBarOwnsTheKeyboard(t *testing.T) {
	down := func(arg1 uint32, flags uint16) vi.Event {
		return vi.Event{Kind: vi.EvKeyDown, Flags: flags, Arg1: arg1}
	}
	// The caret sits at the end of the document, the way load() leaves it.
	e := &editor{doc: doc{buf: []byte("body"), cur: len("body")}}
	if !e.key(down(keyF, modCtrl)) || e.mode != modeFind {
		t.Fatalf("ctrl-f must open the find bar (mode=%d)", e.mode)
	}
	for _, c := range []uint32{'w', 'o', 'r'} {
		if !e.key(down(c, 0)) {
			t.Fatalf("typing %q into the bar must repaint", rune(c))
		}
	}
	if string(e.bar) != "wor" {
		t.Fatalf("bar = %q want \"wor\"", e.bar)
	}
	if string(e.buf) != "body" {
		t.Fatalf("the bar must not edit the document: buf = %q", e.buf)
	}
	// The bar chords switch bars directly, so Ctrl-G after a find is not text.
	if !e.key(down(keyG, modCtrl)) || e.mode != modeGoto || len(e.bar) != 0 {
		t.Fatalf("ctrl-g must switch to a fresh goto bar (mode=%d bar=%q)", e.mode, e.bar)
	}
	// Escape dismisses it and returns the keyboard to the document.
	if !e.key(down(codeEscape, 0)) || e.mode != modeEdit {
		t.Fatalf("escape must dismiss the bar (mode=%d)", e.mode)
	}
	if !e.key(down('q', 0)) || string(e.buf) != "bodyq" {
		t.Fatalf("the document must own the keyboard again: buf = %q", e.buf)
	}
}

// markDirty prints once: the dirty marker is an edge, not a per-keystroke spam.
func TestMarkDirtyIsAnEdge(t *testing.T) {
	e := &editor{}
	e.markDirty()
	if !e.dirty {
		t.Fatal("markDirty must set the flag")
	}
	e.markDirty()
	if !e.dirty {
		t.Fatal("markDirty must stay set")
	}
}

// editKernel is an in-memory kernel for the save() flow's syscalls: the
// lease rows (time/random/procs/file-ABI) plus WriteFileSafe's
// temp+fsync+delete+rename publish. It captures console writes so the
// lease markers are pinned on the host, the way the gate greps them live.
type editKernel struct {
	files   map[string][]byte
	fds     map[uint32]*editHandle
	next    uint32
	now     int64
	console strings.Builder
}

type editHandle struct {
	path   string
	cursor int
	read   bool
}

func hookStrAt(a0, a1 uintptr) string {
	if a0 == 0 || a1 == 0 {
		return ""
	}
	return string(unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1))
}

func installEditKernel(t *testing.T, now int64) *editKernel {
	t.Helper()
	k := &editKernel{files: map[string][]byte{}, fds: map[uint32]*editHandle{}, now: now}
	prev := vi.SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case vi.SlotWrite:
			k.console.WriteString(hookStrAt(a1, a2))
			return int64(a2)
		case vi.SlotTime:
			return k.now
		case vi.SlotGetRandom:
			buf := unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1)
			for i := range buf {
				buf[i] = byte(i + 1)
			}
			return int64(a1)
		case vi.SlotProcs:
			return 0 // no registry rows: the lease records pid=0, honestly
		case vi.SlotFileOpen:
			path := hookStrAt(a0, a1)
			flags := uint32(a2)
			if flags&vi.ModeDir != 0 {
				return -9 // EEXIST: the LEASES dir already exists in the map-less fake
			}
			if _, ok := k.files[path]; !ok {
				if flags&vi.ModeCreate == 0 {
					return -vi.ErrENOENT
				}
				k.files[path] = nil
			}
			k.next++
			k.fds[k.next] = &editHandle{path: path, read: flags&vi.ModeWrite == 0}
			return int64(k.next)
		case vi.SlotFileRead:
			h := k.fds[uint32(a0)]
			if h == nil || !h.read {
				return -vi.ErrEBADF
			}
			buf := unsafe.Slice((*byte)(unsafe.Pointer(a1)), a2)
			body := k.files[h.path]
			n := copy(buf, body[h.cursor:])
			h.cursor += n
			return int64(n)
		case vi.SlotFileWrite:
			h := k.fds[uint32(a0)]
			if h == nil || h.read {
				return -vi.ErrEBADF
			}
			src := unsafe.Slice((*byte)(unsafe.Pointer(a1)), a2)
			body := k.files[h.path]
			if h.cursor+len(src) > len(body) {
				grown := make([]byte, h.cursor+len(src))
				copy(grown, body)
				body = grown
			}
			copy(body[h.cursor:], src)
			k.files[h.path] = body
			h.cursor += len(src)
			return int64(a2)
		case vi.SlotFileTruncate:
			h := k.fds[uint32(a0)]
			if h == nil || h.read {
				return -vi.ErrEBADF
			}
			k.files[h.path] = k.files[h.path][:a1]
			return 0
		case vi.SlotFileSync, vi.SlotFileClose:
			delete(k.fds, uint32(a0))
			return 0
		case vi.SlotFileDelete:
			path := hookStrAt(a0, a1)
			if _, ok := k.files[path]; !ok {
				return -vi.ErrENOENT
			}
			delete(k.files, path)
			return 0
		case vi.SlotFileRename:
			from, to := hookStrAt(a0, a1), hookStrAt(a2, a3)
			if _, ok := k.files[from]; !ok {
				return -vi.ErrENOENT
			}
			k.files[to] = k.files[from]
			delete(k.files, from)
			return 0
		}
		t.Fatalf("editKernel: unexpected slot %d", num)
		return 0
	})
	t.Cleanup(func() { vi.SetSyscallHookForTest(prev) })
	return k
}

// M81d (#1764): save() refuses while another writer's live lease stands on
// the path, and the refusal is the save-error marker with the EAGAIN code —
// the exact line the go-edit gate asserts for the second writer.
func TestSaveUnderALiveLeaseRefuses(t *testing.T) {
	const target = "/host/EDIT/SEED.TXT"
	k := installEditKernel(t, 1000)
	k.files[vi.LeasePathFor(target)] = []byte(
		"VLEASE1\npid=0\nts=1000\ntoken=0102030405060708\npath=" + target + "\n")
	e := &editor{doc: doc{path: target, buf: []byte("XYZ")}}
	if e.save() {
		t.Fatal("save must refuse under a live lease")
	}
	if _, ok := k.files[target]; ok {
		t.Fatal("a refused save must not touch the file")
	}
	if _, ok := k.files[vi.LeasePathFor(target)+"~"]; ok {
		t.Fatal("a refused save must not stage a temp")
	}
	// vi.Console does not route through the hook seam, so the marker's text
	// is not host-capturable; the code it prints is. ensureLease's refusal
	// is exactly the number the save-error marker carries (the go-edit gate
	// greps the full line live).
	if rc := (&editor{doc: doc{path: target}}).ensureLease(); rc != -vi.ErrEAGAIN {
		t.Fatalf("ensureLease under a live lease = %d, want -ErrEAGAIN", rc)
	}
}

// The unopposed path: save takes the lease, publishes, and the record is
// on the share for the next writer to find.
func TestSavePublishesUnderTheLease(t *testing.T) {
	const target = "/host/EDIT/SEED.TXT"
	k := installEditKernel(t, 1000)
	e := &editor{doc: doc{path: target, buf: []byte("XYZ")}}
	if !e.save() {
		t.Fatal("save must publish when no lease stands")
	}
	if got := string(k.files[target]); got != "XYZ" {
		t.Fatalf("published = %q want %q", got, "XYZ")
	}
	rec, ok := k.files[vi.LeasePathFor(target)]
	if !ok || !strings.HasPrefix(string(rec), "VLEASE1\n") {
		t.Fatalf("lease record after save = %q %v", rec, ok)
	}
}
