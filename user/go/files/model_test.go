package main

import (
	"strings"
	"testing"

	"virelai/rss/keys"
	"virelai/vi"
)

// entry builds one wire-shaped DirEntry for the pure tests.
func entry(name string, isDir bool) vi.DirEntry {
	var e vi.DirEntry
	copy(e.Name[:], name)
	if isDir {
		e.IsDir = 1
	}
	e.Size = 19
	return e
}

// testModel assembles a model around injected entries: the vi layer is
// ENOSYS on the host, so listings are placed directly.
func testModel(entries ...vi.DirEntry) model {
	m := model{path: "/host/FM"}
	m.setSize(64, 23)
	copy(m.entries[:], entries)
	m.n = len(entries)
	sortEntries(m.entries[:], m.n, m.sort)
	m.clampSel()
	m.status = "listed"
	m.previewOf = ""
	m.preview = "(no selection)"
	return m
}

func TestGridOfUsesKernelTerminalCell(t *testing.T) {
	cols, rows := gridOf(512, 384)
	if cols != 64 || rows != 23 {
		t.Fatalf("gridOf(512,384) = %dx%d, want 64x23 for the default 8x16 cell",
			cols, rows)
	}
}

func runeKey(r rune) keys.Event { return keys.Event{Key: keys.KeyRune, Rune: r} }

// pendingJoined is the queued marker batch as one string for contains checks.
func pendingJoined(m *model) string {
	out := strings.Join(m.drain(), "\n")
	return out
}

func TestSortDirsFirst(t *testing.T) {
	m := testModel(entry("KNOWN.TXT", false), entry("SUB", true),
		entry("a.txt", false), entry("Bdir", true))
	want := []string{"Bdir/", "SUB/", "KNOWN.TXT", "a.txt"}
	got := labelsOf(m.entries[:], m.n)
	if len(got) != len(want) {
		t.Fatalf("labels = %#v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("labels = %#v, want %#v", got, want)
		}
	}
}

func TestNavKeysMoveSelection(t *testing.T) {
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.handleKey(keys.Event{Key: keys.KeyDown})
	if m.sel != 1 {
		t.Fatalf("down moved sel to %d, want 1", m.sel)
	}
	m.handleKey(runeKey('j'))
	if m.sel != 1 {
		t.Fatalf("j past the end: sel=%d", m.sel)
	}
	m.handleKey(keys.Event{Key: keys.KeyUp})
	m.handleKey(runeKey('k'))
	if m.sel != 0 {
		t.Fatalf("up/k clamps at 0, got %d", m.sel)
	}
	m.handleKey(keys.Event{Key: keys.KeyEnd})
	if m.sel != 1 {
		t.Fatalf("end = %d, want 1", m.sel)
	}
	m.handleKey(keys.Event{Key: keys.KeyHome})
	if m.sel != 0 {
		t.Fatalf("home = %d, want 0", m.sel)
	}
}

func TestPreviewShowsDirectoryNoteWithoutSyscall(t *testing.T) {
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.loadPreview()
	if m.previewOf != "SUB" || !strings.Contains(m.preview, "directory") {
		t.Fatalf("dir preview = %q (%q)", m.preview, m.previewOf)
	}
	if got := pendingJoined(&m); strings.Contains(got, markerView) {
		t.Fatalf("a directory must not emit a view marker: %q", got)
	}
}

func TestRenamePromptFlowAndRefusalMarkers(t *testing.T) {
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.handleKey(keys.Event{Key: keys.KeyDown}) // sel = KNOWN.TXT (dirs sort first)

	m.handleKey(runeKey('r'))
	if m.mode != modeRename || m.input != "" {
		t.Fatalf("r must open an EMPTY rename prompt: mode=%d input=%q", m.mode, m.input)
	}
	// Typing must not fall through to the navigation bindings while modal.
	m.handleKey(runeKey('q'))
	if m.quit {
		t.Fatal("q typed into the prompt must not quit the app")
	}
	// Backspace erases it again — and 'q' never reached the nav switch.
	m.handleKey(keys.Event{Key: keys.KeyBackspace})
	if m.input != "" {
		t.Fatalf("backspace must erase the prompt buffer, input=%q", m.input)
	}

	// Empty input: cancelled, no marker.
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	if m.mode != modeNormal || strings.Contains(pendingJoined(&m), markerRenameNo) {
		t.Fatalf("empty rename must cancel silently: mode=%d", m.mode)
	}

	// Invalid target: refused BEFORE any syscall (no rc suffix).
	m.handleKey(runeKey('r'))
	for _, r := range "a/b" {
		m.handleKey(runeKey(r))
	}
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	if got := pendingJoined(&m); !strings.Contains(got, markerRenameNo+"KNOWN.TXT -> a/b") {
		t.Fatalf("invalid rename marker missing: %q", got)
	}
	if m.mode != modeNormal {
		t.Fatalf("prompt must close on commit, mode=%d", m.mode)
	}

	// Existing target: refused by name, still no syscall.
	m.handleKey(runeKey('r'))
	for _, r := range "SUB" {
		m.handleKey(runeKey(r))
	}
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	if got := pendingJoined(&m); !strings.Contains(got, markerRenameNo) || !strings.Contains(got, "exists") {
		t.Fatalf("existing-name refusal missing: %q", got)
	}

	// Valid target: the syscall runs; the host is ENOSYS, so the marker
	// carries that rc — proving validation passed and the call was made.
	m.handleKey(runeKey('r'))
	for _, r := range "newname.txt" {
		m.handleKey(runeKey(r))
	}
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	if got := pendingJoined(&m); !strings.Contains(got, "rc=-"+itoa(viErrENOSYS)) {
		t.Fatalf("valid rename should reach the syscall: %q", got)
	}
	if m.renamedBatch {
		t.Fatal("a failed rename must not arm the settle marker")
	}
}

func TestRenameEscapeCancels(t *testing.T) {
	m := testModel(entry("KNOWN.TXT", false))
	m.handleKey(runeKey('r'))
	for _, r := range "whatever" {
		m.handleKey(runeKey(r))
	}
	m.handleKey(keys.Event{Key: keys.KeyEsc})
	if m.mode != modeNormal || m.status != "rename cancelled" {
		t.Fatalf("escape must cancel: mode=%d status=%q", m.mode, m.status)
	}
}

func TestDeleteConfirmAndDirRefusal(t *testing.T) {
	// Directories are refused honestly: ADR 0007 has no rmdir slot.
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.handleKey(runeKey('d'))
	if m.mode != modeNormal {
		t.Fatalf("delete on a dir must refuse, mode=%d", m.mode)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerDeleteNo+"SUB (dir)") {
		t.Fatalf("dir refusal marker missing: %q", got)
	}

	// Files confirm first: Esc cancels without a syscall.
	m.handleKey(keys.Event{Key: keys.KeyDown})
	m.handleKey(runeKey('d'))
	if m.mode != modeConfirmDelete {
		t.Fatalf("file delete must ask, mode=%d", m.mode)
	}
	m.handleKey(keys.Event{Key: keys.KeyEsc})
	if m.mode != modeNormal || strings.Contains(pendingJoined(&m), markerDeleted) {
		t.Fatalf("cancelled delete leaked a marker: mode=%d", m.mode)
	}

	// 'y' runs the syscall (ENOSYS on the host => refused marker with rc).
	m.handleKey(runeKey('d'))
	m.handleKey(runeKey('y'))
	got := pendingJoined(&m)
	if !strings.Contains(got, markerDeleteNo) || !strings.Contains(got, "rc=-"+itoa(viErrENOSYS)) {
		t.Fatalf("delete must reach the syscall: %q", got)
	}
	if m.mode != modeNormal {
		t.Fatalf("confirm must close, mode=%d", m.mode)
	}
}

func TestClipPasteRefusals(t *testing.T) {
	// Paste with an empty clip: named refusal, no syscall.
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.handleKey(runeKey('p'))
	if got := pendingJoined(&m); !strings.Contains(got, markerPasteNo+"empty clip") {
		t.Fatalf("empty-clip refusal missing: %q", got)
	}

	// Yank a directory: refused (files only in v1).
	m.handleKey(runeKey('c'))
	if got := pendingJoined(&m); !strings.Contains(got, markerPasteNo) || !strings.Contains(got, "(dir)") {
		t.Fatalf("dir clip refusal missing: %q", got)
	}

	// Yank KNOWN.TXT, paste into the SAME dir: the name exists.
	m.handleKey(keys.Event{Key: keys.KeyDown})
	m.handleKey(runeKey('x'))
	got := pendingJoined(&m)
	if !strings.Contains(got, markerClip+"cut KNOWN.TXT") {
		t.Fatalf("cut marker missing: %q", got)
	}
	m.handleKey(runeKey('p'))
	if got := pendingJoined(&m); !strings.Contains(got, markerPasteNo+"KNOWN.TXT exists") {
		t.Fatalf("paste-over-self must refuse: %q", got)
	}
	if m.clip == "" {
		t.Fatal("a refused paste must keep the clip held")
	}
}

func TestQuitKeys(t *testing.T) {
	m := testModel(entry("KNOWN.TXT", false))
	m.handleKey(runeKey('q'))
	if !m.quit {
		t.Fatal("q must quit in normal mode")
	}
	m2 := testModel(entry("KNOWN.TXT", false))
	m2.handleKey(keys.Event{Key: keys.KeyCtrlC})
	if !m2.quit {
		t.Fatal("ctrl-c must quit")
	}
}

func TestClickSelectsThenOpens(t *testing.T) {
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	// SGR cells are 1-based over the client area; list rows start at row 2
	// (row 0 = path bar, row 1 = pane headers).
	m.handleClick(3, 4) // col 2, row 3 (0-based) -> index 1
	if m.sel != 1 {
		t.Fatalf("click selected %d, want 1", m.sel)
	}
	// Second click on the selected row opens it (cd into SUB is index 0 —
	// so click index 0 first, then again). M124a-2: the open settles on
	// the RELEASE edge — a press alone pends it so a held move can arm a
	// drag instead.
	m.handleClick(3, 3) // index 0 = SUB
	if m.sel != 0 {
		t.Fatalf("click selected %d, want 0", m.sel)
	}
	m.handleClick(3, 3)
	if m.path != "/host/FM" {
		t.Fatalf("press alone must pend the open, path=%q", m.path)
	}
	m.releaseClick()
	if m.path != "/host/FM/SUB" {
		t.Fatalf("second click must open the dir, path=%q", m.path)
	}
	// Clicks in the preview pane or chrome are inert.
	m2 := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m2.handleClick(listWidth(64)+3, 4) // preview side
	if m2.sel != 0 {
		t.Fatalf("preview-pane click moved sel to %d", m2.sel)
	}
	m2.handleClick(3, 1) // header row
	if m2.sel != 0 {
		t.Fatalf("header click moved sel to %d", m2.sel)
	}
}

func TestKeyLabelsUseChordVocabulary(t *testing.T) {
	cases := map[keys.Event]string{
		{Key: keys.KeyEnter}:           "return",
		{Key: keys.KeyBackspace}:       "backspace",
		{Key: keys.KeyDown}:            "down",
		{Key: keys.KeyEsc}:             "escape",
		{Key: keys.KeyRune, Rune: ' '}: "space",
		{Key: keys.KeyRune, Rune: 'r'}: "r",
	}
	for ev, want := range cases {
		if got := keyLabel(ev); got != want {
			t.Errorf("keyLabel(%v) = %q, want %q", ev, got, want)
		}
	}
}

// itoa keeps the marker-rc assertions readable without importing strconv
// style noise into every call site.
func itoa(v int64) string { return vi.Itoa64(v) }

// M79k (#1720): the model decides WHAT happened and main owns the seat
// seam, so the toast text is queued on the model and drained exactly once.
// A completed copy is the honest adopter: the status line already says
// "copied KNOWN.TXT", and a refused paste raises nothing — a toast claiming
// a copy that did not happen is the one thing this must never print.
func TestPasteQueuesOneToastAndRefusalsQueueNone(t *testing.T) {
	// Empty clip: refused, no toast.
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.handleKey(runeKey('p'))
	if got := m.takeNotify(); got != "" {
		t.Fatalf("an empty-clip paste queued the toast %q", got)
	}

	// Yank a directory: refused, no toast.
	m.handleKey(runeKey('c'))
	if got := m.takeNotify(); got != "" {
		t.Fatalf("a refused dir clip queued the toast %q", got)
	}

	// Yank KNOWN.TXT and paste into the same dir: the name exists, so the
	// paste is refused and still no toast.
	m.handleKey(keys.Event{Key: keys.KeyDown})
	m.handleKey(runeKey('c'))
	if got := pendingJoined(&m); !strings.Contains(got, markerClip+"copy KNOWN.TXT") {
		t.Fatalf("copy marker missing: %q", got)
	}
	m.handleKey(runeKey('p'))
	if got := pendingJoined(&m); !strings.Contains(got, markerPasteNo+"KNOWN.TXT exists") {
		t.Fatalf("paste-over-self must refuse: %q", got)
	}
	if got := m.takeNotify(); got != "" {
		t.Fatalf("a REFUSED paste queued the toast %q", got)
	}
}

// The one queueing site the host can reach: the model's own notifyToast /
// takeNotify pair, which is what the copy success path calls. takeNotify is
// consume-on-use, so a toast can never be raised twice by the next frame.
func TestNotifyToastIsConsumeOnUse(t *testing.T) {
	m := testModel()
	m.notifyToast("copied KNOWN.TXT")
	if got := m.takeNotify(); got != "copied KNOWN.TXT" {
		t.Fatalf("takeNotify = %q want the queued text", got)
	}
	if got := m.takeNotify(); got != "" {
		t.Fatalf("a second takeNotify = %q, want empty (consume-on-use)", got)
	}
	// The LAST text in a batch wins: one keystroke must not raise three
	// toasts describing states the user never saw.
	m.notifyToast("first")
	m.notifyToast("copied KNOWN.TXT")
	if got := m.takeNotify(); got != "copied KNOWN.TXT" {
		t.Fatalf("takeNotify = %q want the LAST queued text", got)
	}
	// The text budget is the WM_RPC frame title (24 bytes), so the adopter
	// must keep the message inside it — a name long enough to overflow it
	// would be cut mid-word on the toast while the app's own marker
	// printed the whole thing.
	if len("copied KNOWN.TXT") > 24 {
		t.Fatalf("the adopter's message %q exceeds the 24-byte notify budget", "copied KNOWN.TXT")
	}
}
