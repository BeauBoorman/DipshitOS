package main

import (
	"bytes"
	"testing"

	"virelai/tabapp"
	"virelai/vi"
	"virelai/webrender/font"
)

func keyDown(arg0, arg1 uint32) vi.Event {
	return vi.Event{Kind: vi.EvKeyDown, Arg0: arg0, Arg1: arg1}
}

// The two paths the save test distinguishes, and the lengths a faked syscall
// sees. A path argument reaches the hook as (pointer, length); the length alone
// separates the sacrificial temp from the live file (they differ by the
// one-byte "~" suffix, M81e #1765), so
// the test needs no uintptr-to-pointer conversion -- virelai/vi's own tests do
// that with unsafe, and duplicating the pattern here would add a second
// `possible misuse of unsafe.Pointer` to `go vet` for no extra coverage.
const (
	livePathLen = uintptr(len(defaultPath))
	tmpPathLen  = uintptr(len(defaultPath) + len("~"))
)

// The key path end to end, at the byte level: what arrives from the kernel
// (ADR 0009: HID usage in arg0, decoded symbol in arg1) and what the buffer
// holds afterwards. The arrows are the interesting half — they are read from
// arg0, and reading them from arg1 (where they are 0) is a silent no-op that
// only shows up on the VM.
func TestKeyPath(t *testing.T) {
	a := &app{buf: NewBuffer(), top: 1}
	a.buf.InsertText("ab\ncd")

	if !a.key(keyDown(0, 'x')) {
		t.Fatal("a printable symbol did not report a change")
	}
	if got := string(a.buf.Bytes()); got != "ab\ncdx" {
		t.Fatalf("after typing x: %q", got)
	}
	if !a.key(keyDown(0, codeReturn)) {
		t.Fatal("Return did not report a change")
	}
	if got := string(a.buf.Bytes()); got != "ab\ncdx\n" {
		t.Fatalf("after Return: %q", got)
	}

	// Arrows: arg0 carries the usage, arg1 is 0.
	a.buf.SetCursor(0)
	if !a.key(keyDown(hidRight, 0)) || a.buf.Cursor() != 1 {
		t.Fatalf("Right: cursor=%d want 1", a.buf.Cursor())
	}
	if !a.key(keyDown(hidDown, 0)) || a.buf.Line() != 2 {
		t.Fatalf("Down: line=%d want 2", a.buf.Line())
	}
	if !a.key(keyDown(hidUp, 0)) || a.buf.Line() != 1 {
		t.Fatalf("Up: line=%d want 1", a.buf.Line())
	}
	if !a.key(keyDown(hidLeft, 0)) || a.buf.Cursor() != 0 {
		t.Fatalf("Left: cursor=%d want 0", a.buf.Cursor())
	}
	if a.key(keyDown(hidLeft, 0)) {
		t.Fatal("Left at offset 0 reported a change")
	}

	// Delete takes the byte AT the caret; backspace takes the one before it.
	a.buf.SetCursor(1)
	if !a.key(keyDown(0, codeDelete)) {
		t.Fatal("Delete did not report a change")
	}
	if got := string(a.buf.Bytes()); got != "a\ncdx\n" {
		t.Fatalf("after Delete: %q", got)
	}
	if a.buf.Cursor() != 1 {
		t.Fatalf("Delete moved the caret to %d", a.buf.Cursor())
	}
	if !a.key(keyDown(0, codeBackspace)) {
		t.Fatal("Backspace did not report a change")
	}
	if got := string(a.buf.Bytes()); got != "\ncdx\n" {
		t.Fatalf("after Backspace: %q", got)
	}

	// A WM chord is not ours: it must change nothing and ask for no repaint.
	before := string(a.buf.Bytes())
	ev := vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: 'c'}
	if a.key(ev) {
		t.Fatal("a Ctrl chord reported a change")
	}
	if got := string(a.buf.Bytes()); got != before {
		t.Fatalf("a Ctrl chord edited the buffer: %q", got)
	}
	// A non-key event (a resize, say) is not an edit either.
	if a.key(vi.Event{Kind: vi.EvWinResize, Arg0: 800, Arg1: 600}) {
		t.Fatal("a resize reported an edit")
	}
}

func TestInsertionFor(t *testing.T) {
	cases := []struct {
		name string
		ev   vi.Event
		want rune
		ok   bool
	}{
		{"space", keyDown(0, 0x20), ' ', true},
		{"tilde", keyDown(0, 0x7e), '~', true},
		{"enter", keyDown(0x28, codeReturn), '\n', true},
		{"newline", keyDown(0, codeNewline), '\n', true},
		{"control code", keyDown(0, 0x01), 0, false},
		{"delete", keyDown(0, codeDelete), 0, false},
		{"control range", keyDown(0, 0x80), 0, false},
		{"umlaut", keyDown(0x33, 0x00f6), 'ö', true},
		{"arrow", keyDown(hidRight, 0), 0, false},
		{"chord", vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: 'a'}, 0, false},
		{"key up", vi.Event{Kind: vi.EvKeyUp, Arg1: 'a'}, 0, false},
	}
	for _, c := range cases {
		got, ok := insertionFor(c.ev)
		if got != c.want || ok != c.ok {
			t.Fatalf("%s: insertionFor = %q,%v want %q,%v", c.name, got, ok, c.want, c.ok)
		}
	}
}

func TestUnicodeKeyPath(t *testing.T) {
	a := &app{buf: NewBuffer(), top: 1}
	if !a.key(keyDown(0x33, 0x00f6)) || string(a.buf.Bytes()) != "ö" {
		t.Fatalf("Unicode key path saved %q, want ö", a.buf.Bytes())
	}
	if !a.key(keyDown(0, codeBackspace)) || len(a.buf.Bytes()) != 0 {
		t.Fatalf("backspace left partial UTF-8 bytes: %x", a.buf.Bytes())
	}
}

func TestIsSave(t *testing.T) {
	if !isSave(vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: keyCtrlS}) {
		t.Fatal("Ctrl-S (control code) was not recognised")
	}
	if !isSave(vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: keyS}) {
		t.Fatal("Ctrl-S (letter) was not recognised")
	}
	if isSave(keyDown(0, keyS)) {
		t.Fatal("a plain 's' was mistaken for the save chord")
	}
	if isSave(vi.Event{Kind: vi.EvKeyUp, Flags: modCtrl, Arg1: keyS}) {
		t.Fatal("a key-UP edge was mistaken for the save chord")
	}
}

func TestTabTitleForPath(t *testing.T) {
	for _, tc := range []struct {
		path, want string
	}{
		{defaultPath, "notes.txt"},
		{"notes.txt", "notes.txt"},
		{"/host/", ""},
		{"", ""},
	} {
		if got := tabTitleForPath(tc.path); got != tc.want {
			t.Fatalf("tabTitleForPath(%q) = %q want %q", tc.path, got, tc.want)
		}
	}
}

// The frame geometry: how many rows and columns a canvas holds, and the clamps
// that keep a tiny canvas drawable. A zero canvas falls back to the native size
// rather than dividing by it.
func TestGeometry(t *testing.T) {
	a := &app{buf: NewBuffer(), ta: &tabapp.TabApp{W: natW, H: natH}}
	wantRows := (natH - chromeH - statusH) / lineH
	if got := a.rowsIn(); got != wantRows {
		t.Fatalf("rowsIn = %d want %d", got, wantRows)
	}
	if got, want := a.colsIn(), (natW-2*textOrigin)/font.Advance(1); got != want {
		t.Fatalf("colsIn = %d want %d", got, want)
	}
	// A canvas smaller than a row still holds one row: the caret must not
	// disappear on a drag-resize.
	a.ta.H = 10
	a.ta.W = 4
	if got := a.rowsIn(); got != 1 {
		t.Fatalf("rowsIn on a tiny canvas = %d want 1", got)
	}
	if got := a.colsIn(); got != 1 {
		t.Fatalf("colsIn on a tiny canvas = %d want 1", got)
	}
	// No window at all: the geometry must still answer.
	empty := &app{buf: NewBuffer()}
	if empty.rowsIn() != 1 || empty.colsIn() < 1 {
		t.Fatal("geometry with no window must fall back, not divide by zero")
	}
}

// The load/save decision path, exercised on the host where every syscall is
// -ENOSYS. That is a real outcome to pin: the app must report a refusal rather
// than panic, and the marker has to name what happened.
func TestLoadSaveOutcomesOnHost(t *testing.T) {
	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	got := a.load()
	if len(got) < len(markerLoadErr) || got[:len(markerLoadErr)] != markerLoadErr {
		t.Fatalf("host load marker = %q want a %q prefix (the host file channel is -ENOSYS)", got, markerLoadErr)
	}
	if a.buf.Len() != 0 {
		t.Fatalf("a refused load left %d bytes in the buffer", a.buf.Len())
	}
	// The buffer is dirty first, because that is the state the close path acts
	// on: a refused save must NOT clear it, or a tab closed after a failed
	// Ctrl-S would behave as though the edit had been written.
	a.dirty = true
	got = a.save()
	if len(got) < len(markerSaveErr) || got[:len(markerSaveErr)] != markerSaveErr {
		t.Fatalf("host save marker = %q want a %q prefix", got, markerSaveErr)
	}
	if !a.dirty {
		t.Fatal("a failed save cleared the dirty bit: the close path would not retry it")
	}
}

// The success path of save(), pinned at the seam: the app must publish through
// vi.WriteFileSafe (temp -> fsync -> rename), not the open/write/truncate it
// shipped with, and it must report the bytes it published while clearing the
// dirty bit. M66b (#1444) pins that primitive's own wire in vi_test.go; what
// this pins is that the notepad is actually on it -- the swap was a choice, and
// a silent regression to in-place truncation would otherwise pass every test
// here (the host has no file channel, so the failure path is all this package
// could see before this test existed).
// fakeSaveGateway installs a syscall gateway on which vi.WriteFileSafe
// succeeds, recording every slot it saw, and returns the recording plus a
// restore func. It is the seam that makes the app's OUTGOING calls observable:
// the real host answers -ENOSYS to the file channel, so without a fake the only
// outcome any test here could see is a refusal.
func fakeSaveGateway(t *testing.T) (*[]uintptr, func()) {
	t.Helper()
	var seq []uintptr
	prev := vi.SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		seq = append(seq, num)
		switch num {
		case vi.SlotFileOpen:
			// The load-bearing one: opening the LIVE path means the app went
			// back to truncating in place.
			if a1 != tmpPathLen {
				t.Fatalf("open path length = %d, want %d (the temp); %d would be the live path",
					a1, tmpPathLen, livePathLen)
			}
			return 1
		case vi.SlotFileWrite:
			return int64(a2)
		case vi.SlotFileSync, vi.SlotFileClose, vi.SlotFileDelete:
			return 0
		case vi.SlotFileRename:
			if a1 != tmpPathLen {
				t.Fatalf("rename from length = %d, want %d (the temp)", a1, tmpPathLen)
			}
			if a3 != livePathLen {
				t.Fatalf("rename to length = %d, want %d (the live path)", a3, livePathLen)
			}
			return 0
		}
		t.Fatalf("unexpected slot %d", num)
		return 0
	})
	return &seq, func() { vi.SetSyscallHookForTest(prev) }
}

func TestSavePublishesThroughWriteFileSafe(t *testing.T) {
	seq, restore := fakeSaveGateway(t)
	defer restore()

	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	a.buf.InsertText("alpha\nbeta\n")
	a.dirty = true

	if got, want := a.save(), markerSaved+"11"; got != want {
		t.Fatalf("save marker = %q want %q", got, want)
	}
	if a.dirty {
		t.Fatal("a successful save must clear the dirty bit, or the close path saves again")
	}
	for _, s := range *seq {
		if s == vi.SlotFileTruncate {
			t.Fatal("save truncated the live path in place: the crash-safe writer never does")
		}
	}
	if len(*seq) == 0 || (*seq)[0] != vi.SlotFileOpen || (*seq)[len(*seq)-1] != vi.SlotFileRename {
		t.Fatalf("call sequence = %v, want open ... rename", *seq)
	}
}

// A save is a frame change but NOT an edit. The loop set dirty on any `true`
// from key(), so Ctrl-S re-dirtied the buffer it had just written: a `*` that
// never clears and a redundant second save on close. The other direction
// matters as much -- Ctrl-S on a clean buffer must not dirty it -- and so does
// the boundary in between: typing dirties, moving the caret does not.
func TestOnlyEditsDirty(t *testing.T) {
	_, restore := fakeSaveGateway(t)
	defer restore()

	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	a.buf.InsertText("ab") // the engine call, not a key: still clean
	save := vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: keyS}

	if !a.key(save) {
		t.Fatal("Ctrl-S did not report a frame change: the chrome keeps the '*'")
	}
	if a.dirty {
		t.Fatal("Ctrl-S on a CLEAN buffer dirtied it")
	}
	if !a.key(keyDown(0, 'x')) {
		t.Fatal("typing did not report a frame change")
	}
	if !a.dirty {
		t.Fatal("typing did not dirty the buffer")
	}
	if !a.key(save) {
		t.Fatal("Ctrl-S did not report a frame change")
	}
	if a.dirty {
		t.Fatal("the dirty bit survived a successful Ctrl-S: the '*' never clears")
	}
	if !a.key(keyDown(hidLeft, 0)) {
		t.Fatal("Left did not report a frame change")
	}
	if a.dirty {
		t.Fatal("moving the caret dirtied the buffer")
	}
}

// Every draw counts exactly one presented frame, and that count is what the live
// seat spec pairs against its own relayout count (presents must be relayouts+1).
//
// Why the counter and not the syscall: draw() presents through tabapp.Present ->
// vi.WinPresent, and vi's WINDOW rows still go to the raw gateway (syscall1)
// while the file and audio rows go through the hookable svc1..svc4. So a fake
// kernel in this package sees no present at all -- which is the same blind spot
// that let a draw without any present pass a whole green VZ run. Closing it means
// moving those rows onto the hookable gateway, and user/go/vi/ is an ACTIVE
// claim's file (#1446), so it is not this card's edit: until then the app reports
// the number it knows and the spec checks it against kernel-driven relayouts.
//
// The counter is still a real assertion. And, unlike the marker it feeds, it
// counts frames SUBMITTED for presentation (tabapp discards WinPresent's rc, the
// same as GOEDIT does), so what is pinned is that no draw path skips the tail.
func TestDrawCountsPresentedFrames(t *testing.T) {
	a := &app{
		buf:  NewBuffer(),
		path: defaultPath,
		top:  1,
		ta:   &tabapp.TabApp{Win: 1, W: natW, H: natH},
	}
	a.buf.InsertText("hello\n")

	a.draw()
	if a.presents != 1 {
		t.Fatalf("presents = %d after one draw, want 1; 0 is the unpresented-frame bug", a.presents)
	}
	// Once per frame, not once per program: a relayout presents again.
	a.draw()
	if a.presents != 2 {
		t.Fatalf("presents = %d after two draws, want 2", a.presents)
	}
	// No window at all (tabapp.Init refused): draw returns early and must not
	// count a frame it never built.
	bare := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	bare.draw()
	if bare.presents != 0 {
		t.Fatalf("a draw with no window counted %d frames", bare.presents)
	}
}

// The save-on-close decision, host-testable because it is a function: the close
// path itself exits the process, so a live run can only ever observe the clean
// case. A dirty buffer is saved on the way out; a clean one is not written at
// all, because an unnecessary write is a chance to lose a file for nothing.
func TestCloseSaveDecision(t *testing.T) {
	seq, restore := fakeSaveGateway(t)
	defer restore()

	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	a.buf.InsertText("typed")
	if got := a.closeSave(); got != "" {
		t.Fatalf("a clean close produced %q, want no save at all", got)
	}
	if len(*seq) != 0 {
		t.Fatalf("a clean close touched the file channel: %v", *seq)
	}
	a.dirty = true
	if got, want := a.closeSave(), markerSaved+"5"; got != want {
		t.Fatalf("dirty close marker = %q want %q", got, want)
	}
	if a.dirty {
		t.Fatal("the close save left the buffer dirty")
	}
}

// The absent-file case is the ordinary first run: it must be distinguishable
// from an error, because the seat specs assert the difference.
func TestLoadMissMarker(t *testing.T) {
	if markerMiss == markerLoadErr || markerMiss == markerLoaded {
		t.Fatal("the three load outcomes must be distinguishable markers")
	}
	a := &app{buf: NewBuffer(), path: defaultPath}
	a.buf.Load([]byte("hello"))
	// Exact, not a prefix compare: `got < markerCursor` passed on any string a
	// correct marker is a prefix of, which is every one of them.
	if got, want := a.cursorMarker(), markerCursor+"1 col=0 n=5"; got != want {
		t.Fatalf("cursor marker = %q want %q", got, want)
	}
}

// The absent-file branch is the ordinary first run, and nothing on the host
// reaches it: the host answers -ENOSYS, which is a different marker (the test
// above). Faking the gateway is the only way to pin the outcome a new user
// actually sees.
func TestLoadMissBranch(t *testing.T) {
	prev := vi.SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == vi.SlotFileOpen {
			return -int64(vi.ErrENOENT)
		}
		t.Fatalf("loading a missing file hit slot %d", num)
		return 0
	})
	defer vi.SetSyscallHookForTest(prev)

	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	if got, want := a.load(), markerMiss+defaultPath; got != want {
		t.Fatalf("load marker = %q want %q (a missing file is not an error)", got, want)
	}
	if a.buf.Len() != 0 {
		t.Fatalf("a missing file left %d bytes in the buffer", a.buf.Len())
	}
}

// All four load outcomes, driven through the decision function so that the two
// the host channel cannot produce are covered at last: the host answers -ENOSYS
// to every read, so the absent-file marker and the over-bound marker were
// unreachable while this decision was inlined in load(). The distinctions that
// matter: a negative rc is a refusal even when it carries bytes, exactly-at-the-
// bound is NOT truncation, and truncation needs the buffer full AND more data
// offered (readMax = MaxBytes+1 is what makes that observable).
func TestLoadOutcomeMarkers(t *testing.T) {
	full := bytes.Repeat([]byte("x"), MaxBytes)
	over := append(append([]byte{}, full...), 'x')
	enosys := markerLoadErr + vi.Itoa64(-vi.ErrENOSYS) + " " + defaultPath
	cases := []struct {
		name string
		data []byte
		rc   int64
		want string
	}{
		{"refused", nil, -vi.ErrENOSYS, enosys},
		{"absent", nil, -vi.ErrENOENT, markerMiss + defaultPath},
		{"read", []byte("alpha\nbeta\n"), 11, markerLoaded + "11"},
		{"a refusal carrying bytes is still a refusal", full, -vi.ErrENOSYS, enosys},
		{"exactly at the bound is not truncation", full, int64(len(full)),
			markerLoaded + vi.Itoa64(int64(MaxBytes))},
		{"one byte over the bound is", over, int64(len(over)),
			markerLoaded + vi.Itoa64(int64(MaxBytes)) + " truncated at " + vi.Itoa64(int64(MaxBytes))},
	}
	for _, c := range cases {
		a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
		if got := a.loadMarker(c.data, c.rc); got != c.want {
			t.Fatalf("%s: loadMarker = %q want %q", c.name, got, c.want)
		}
		if c.name == "one byte over the bound is" && a.buf.Len() != MaxBytes {
			t.Fatalf("a truncated load left %d bytes, want the %d-byte bound", a.buf.Len(), MaxBytes)
		}
	}
	// A refused or absent load must not leave bytes behind either.
	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	a.loadMarker(nil, -vi.ErrENOENT)
	if a.buf.Len() != 0 {
		t.Fatalf("an absent load left %d bytes in the buffer", a.buf.Len())
	}
}

// The M125a envelope (M192b #3247): path + caret + dirty round-trip on the
// wire format itself. A dirty snapshot carries the unsaved text — the blob
// bound is twice the buffer bound, so the document always fits — and the
// codec must consume the blob exactly: anything torn or foreign refuses
// whole rather than restoring halfway.
func TestStateEnvelopeRoundTrip(t *testing.T) {
	// Clean: path + caret only.
	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	a.buf.InsertText("hello")
	blob := a.saveState()
	s, ok := decodeState(blob)
	if !ok {
		t.Fatalf("clean blob refused: %x", blob)
	}
	if s.dirty || s.buf != nil || s.cur != 5 || s.path != defaultPath {
		t.Fatalf("clean decode = %+v", s)
	}
	// Dirty: the unsaved text rides the blob.
	a.dirty = true
	blob = a.saveState()
	s, ok = decodeState(blob)
	if !ok {
		t.Fatalf("dirty blob refused: %x", blob)
	}
	if !s.dirty || string(s.buf) != "hello" || s.cur != 5 || s.path != defaultPath {
		t.Fatalf("dirty decode = %+v", s)
	}
	// Re-encoding the decode is byte-identical — the format is stable.
	if got := s.encode(); !bytes.Equal(got, blob) {
		t.Fatalf("re-encode drifted: %x != %x", got, blob)
	}
}

// Every malformed shape refuses: a foreign fmtVer, unknown flag bits, a torn
// length, trailing junk, a dirty blob that ends before its bufLen. The seat
// stores bytes verbatim; the check is the codec's.
func TestStateDecodeRefusals(t *testing.T) {
	good := (&noteState{cur: 3, path: defaultPath}).encode()
	cases := []struct {
		name string
		blob []byte
	}{
		{"empty", nil},
		{"short", good[:4]},
		{"foreign ver", append([]byte{9}, good[1:]...)},
		{"unknown flag", append([]byte{good[0], 0x40}, good[2:]...)},
		{"path overruns", append(append([]byte{}, good[:7]...), 0xff, 0xff)},
		{"trailing junk", append(append([]byte{}, good...), 0)},
		{"dirty no bufLen", append([]byte{good[0], flagDirty}, good[2:]...)},
	}
	for _, c := range cases {
		if _, ok := decodeState(c.blob); ok {
			t.Fatalf("%s: decode accepted %x", c.name, c.blob)
		}
	}
	// A dirty blob whose declared bufLen overruns what remains refuses too —
	// bufLen sits at offset 9 in the {path:"p"} encoding below.
	dirty := (&noteState{cur: 0, path: "p", dirty: true, buf: []byte("ab")}).encode()
	dirty[9] = 0xff
	if _, ok := decodeState(dirty); ok {
		t.Fatalf("an overrun bufLen decoded: %x", dirty)
	}
}

// The app-level round trip. noteState lands the path before load (a re-exec
// gets no argv); applyRestored then decides against what load left in the
// buffer — the host cannot read /host, so the test loads the "file" itself.
func TestStateRestoreApplies(t *testing.T) {
	// Snapshot while dirty, before any save: the text the disk does not have
	// rides the blob and comes back dirty.
	src := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	src.buf.InsertText("ab\ncd")
	src.dirty = true
	src.buf.SetCursor(4)
	blob := src.saveState()

	dst := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	dst.noteState(blob)
	if dst.path != defaultPath {
		t.Fatalf("blob path not applied before load: %q", dst.path)
	}
	dst.buf.Load([]byte("ab")) // the file on disk is the pre-edit version
	marker := dst.applyRestored()
	if marker != markerState+"restored cur=4 path="+defaultPath+" dirty" {
		t.Fatalf("dirty restore marker = %q", marker)
	}
	if got := string(dst.buf.Bytes()); got != "ab\ncd" {
		t.Fatalf("restored buffer = %q want the blob's text", got)
	}
	if !dst.dirty || dst.buf.Cursor() != 4 {
		t.Fatalf("restore left dirty=%v cursor=%d", dst.dirty, dst.buf.Cursor())
	}

	// The close-time save case: the blob was taken dirty but the file on
	// disk already carries the same bytes (closeSave published them) — the
	// flag goes back clean.
	dst2 := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	dst2.noteState(blob)
	dst2.buf.Load([]byte("ab\ncd"))
	marker = dst2.applyRestored()
	if marker != markerState+"restored cur=4 path="+defaultPath {
		t.Fatalf("published-text restore marker = %q", marker)
	}
	if dst2.dirty {
		t.Fatal("a snapshot the file already has restored dirty")
	}
}

// The two stale paths: a blob that does not decode reports "stale bad", and
// one that decodes under a foreign appver reports "stale version" — the
// seat-visible tag is the app's own refusal, applied even when the bytes
// parsed.
func TestStateRestoreStale(t *testing.T) {
	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	a.noteState([]byte{0xde, 0xad})
	if got := a.applyRestored(); got != markerState+"stale bad" {
		t.Fatalf("torn blob marker = %q", got)
	}
	// A second stale report does not re-print: pendBad was consumed.
	if got := a.applyRestored(); got != "" {
		t.Fatalf("consumed stale blob re-reported %q", got)
	}

	a = &app{buf: NewBuffer(), path: defaultPath, top: 1, ta: &tabapp.TabApp{RestoredVersion: stateAppVer + 1}}
	a.noteState((&noteState{cur: 2, path: defaultPath}).encode())
	if got := a.applyRestored(); got != markerState+"stale version" {
		t.Fatalf("foreign appver marker = %q", got)
	}
	if a.buf.Cursor() != 0 {
		t.Fatalf("a refused restore still moved the caret to %d", a.buf.Cursor())
	}
}

// No blob at all is the ordinary first boot: applyRestored stays silent and
// the app is exactly what load() left.
func TestStateRestoreAbsent(t *testing.T) {
	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	if got := a.applyRestored(); got != "" {
		t.Fatalf("no-blob applyRestored = %q want silence", got)
	}
}

// The caret rides the blob as a byte offset; a stale one past the end (or a
// mid-rune offset a hand-made blob could carry) clamps through SetCursor
// instead of stranding the caret.
func TestStateRestoreClampsCaret(t *testing.T) {
	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	a.buf.Load([]byte("aöb"))
	a.noteState((&noteState{cur: 99, path: defaultPath}).encode())
	_ = a.applyRestored()
	if a.buf.Cursor() != 4 {
		t.Fatalf("past-end caret = %d want %d", a.buf.Cursor(), 4)
	}
	a.noteState((&noteState{cur: 2, path: defaultPath}).encode()) // inside ö
	_ = a.applyRestored()
	if a.buf.Cursor() != 1 {
		t.Fatalf("mid-rune caret = %d want rune boundary 1", a.buf.Cursor())
	}
}
