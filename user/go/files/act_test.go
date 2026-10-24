package main

import (
	"errors"
	"strings"
	"testing"

	"virelai/rss/keys"
)

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

	// Existing target: refused by name, still no syscall — and the M123d
	// conflict banner stands until it is answered.
	m.handleKey(runeKey('r'))
	for _, r := range "SUB" {
		m.handleKey(runeKey(r))
	}
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	if got := pendingJoined(&m); !strings.Contains(got, markerRenameNo) || !strings.Contains(got, "exists") {
		t.Fatalf("existing-name refusal missing: %q", got)
	}
	if !m.banner.Open {
		t.Fatal("a name-exists refusal must raise the Replace/Cancel banner")
	}
	// While the banner stands the list's bindings stay dead — 'r' must not
	// reopen the prompt under it.
	m.handleKey(runeKey('r'))
	if m.mode == modeRename {
		t.Fatal("a key under the open banner must not reach the list bindings")
	}
	m.handleKey(keys.Event{Key: keys.KeyEsc})
	if m.banner.Open || m.status != "rename cancelled" {
		t.Fatalf("esc must dismiss the banner: open=%v status=%q", m.banner.Open, m.status)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerBannerAct+"dismiss") {
		t.Fatalf("banner dismissal marker missing: %q", got)
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

func TestRenameConflictBannerArms(t *testing.T) {
	// Cancel (digit 2, or Enter on the safe-last default) leaves both
	// entries untouched.
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.handleKey(keys.Event{Key: keys.KeyDown})
	m.handleKey(runeKey('r'))
	for _, r := range "SUB" {
		m.handleKey(runeKey(r))
	}
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	if !m.banner.Open {
		t.Fatal("conflict did not raise the banner")
	}
	if line := m.statusLine(); !strings.Contains(line, "[1] Replace") ||
		!strings.Contains(line, "[2] Cancel") || !strings.Contains(line, "SUB exists") {
		t.Fatalf("status row must carry the conflict chord menu: %q", line)
	}
	m.handleKey(runeKey('2'))
	if m.banner.Open {
		t.Fatal("cancel left the banner open")
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerBannerAct+"cancel") {
		t.Fatalf("cancel act marker missing: %q", got)
	}
	if m.status != "rename cancelled" {
		t.Fatalf("cancel status = %q", m.status)
	}

	// Copy Error (c) publishes the text and names it on the act marker.
	m.handleKey(runeKey('r'))
	for _, r := range "SUB" {
		m.handleKey(runeKey(r))
	}
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	m.handleKey(runeKey('c'))
	if m.banner.Open {
		t.Fatal("copy left the banner open")
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerBannerAct+"copy") {
		t.Fatalf("copy act marker missing: %q", got)
	}

	// Replace onto a DIRECTORY refuses before the op path — trashing a
	// whole tree is not what Replace means.
	m.handleKey(runeKey('r'))
	for _, r := range "SUB" {
		m.handleKey(runeKey(r))
	}
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	m.handleKey(runeKey('1'))
	if m.banner.Open {
		t.Fatal("replace left the banner open")
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerBannerAct+"replace refused dir") {
		t.Fatalf("dir replace must refuse: %q", got)
	}
}

func TestRenameConflictReplaceFile(t *testing.T) {
	// Replace (digit 1) onto a file runs delete-the-incumbent then the held
	// rename — on the host the delete is ENOSYS, so the refusal marker
	// proves the arm reached the op path instead of silently succeeding.
	m := testModel(entry("KNOWN.TXT", false), entry("OTHER.TXT", false))
	m.handleKey(keys.Event{Key: keys.KeyDown}) // sel = OTHER.TXT
	m.handleKey(runeKey('r'))
	for _, r := range "KNOWN.TXT" {
		m.handleKey(runeKey(r))
	}
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	if !m.banner.Open {
		t.Fatal("file-name conflict did not raise the banner")
	}
	m.handleKey(runeKey('1'))
	if m.banner.Open {
		t.Fatal("replace left the banner open")
	}
	got := pendingJoined(&m)
	if !strings.Contains(got, markerBannerAct+"replace refused rc=-4") {
		t.Fatalf("replace arm should reach the syscall (host ENOSYS): %q", got)
	}
	if !strings.Contains(m.status, "refused") {
		t.Fatalf("replace-refused status = %q", m.status)
	}
}

func TestExecRefusalRaisesBanner(t *testing.T) {
	// The drainLaunch arm (raiseExecRefusal is model-pure; main.go's own
	// seam is guest-tagged): a refused vi.Exec raises the banner with no
	// actions — Copy Error and dismiss are the only answers.
	m := testModel(entry("KNOWN.TXT", false))
	m.raiseExecRefusal("MISSING.ELF", errors.New("ENOENT"))
	if !m.banner.Open {
		t.Fatal("an exec refusal must raise the banner")
	}
	if !m.bannerFresh {
		t.Fatal("a post-paint raise must ask main for the strip's frame")
	}
	if !strings.Contains(m.banner.Text, "MISSING.ELF") || !strings.Contains(m.banner.Text, "ENOENT") {
		t.Fatalf("banner text = %q", m.banner.Text)
	}
	if len(m.banner.Actions) != 0 {
		t.Fatal("an exec refusal carries no contextual actions")
	}
	m.bannerKey(runeKey('c'))
	if got := pendingJoined(&m); !strings.Contains(got, markerBannerAct+"copy") {
		t.Fatalf("copy resolution missing: %q", got)
	}
	if m.status != "error copied" {
		t.Fatalf("copied status = %q", m.status)
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

func TestDeleteModalShedsUnrelatedKeys(t *testing.T) {
	// #2894: the armed prompt used to swallow every later key with no
	// serial trace — a stray 'd' plus a much-later stray 'y' deleted
	// silently. The arm and the shed both mark now, and the first key
	// that is not an answer disarms the prompt without dispatching
	// underneath it.
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.handleKey(keys.Event{Key: keys.KeyDown})
	m.handleKey(runeKey('d'))
	if m.mode != modeConfirmDelete {
		t.Fatalf("'d' must arm the confirm, mode=%d", m.mode)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerDeleteArm+"KNOWN.TXT") {
		t.Fatalf("arm marker missing: %q", got)
	}

	// A key that is not an answer sheds the modal and is swallowed: the
	// selection must not move on the key that cancelled.
	m.handleKey(runeKey('j'))
	if m.mode != modeNormal || m.sel != 1 {
		t.Fatalf("stray 'j' must shed without dispatch: mode=%d sel=%d", m.mode, m.sel)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerDeleteCancel+"KNOWN.TXT key=j") {
		t.Fatalf("shed marker missing: %q", got)
	}

	// The keyboard is live again — and the #2894 silent-delete shape
	// (a stray 'd', unrelated runes, then a stray 'y') deletes nothing.
	m.handleKey(runeKey('d'))
	m.handleKey(runeKey('7'))
	m.handleKey(runeKey('7'))
	m.handleKey(runeKey('y'))
	if m.mode != modeNormal {
		t.Fatalf("unrelated keys must leave the modal disarmed, mode=%d", m.mode)
	}
	if got := pendingJoined(&m); strings.Contains(got, markerDeleted) ||
		strings.Contains(got, markerDeleteNo) {
		t.Fatalf("a shed confirm must not delete on a later 'y': %q", got)
	}

	// A left press sheds it too — and never selects underneath the prompt.
	m.handleKey(runeKey('d'))
	m.handleClick(1, 3) // row 0's cell — would move sel to 0 if dispatched
	if m.mode != modeNormal || m.sel != 1 {
		t.Fatalf("press must shed without selecting: mode=%d sel=%d", m.mode, m.sel)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerDeleteCancel+"KNOWN.TXT key=press") {
		t.Fatalf("press shed marker missing: %q", got)
	}

	// A right press sheds rather than arming the context menu over a
	// pending delete.
	m.handleKey(runeKey('d'))
	m.handleRightClick(1, 3)
	if m.mode != modeNormal {
		t.Fatalf("right press must shed, mode=%d", m.mode)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerDeleteCancel+"KNOWN.TXT key=rpress") {
		t.Fatalf("rpress shed marker missing: %q", got)
	}

	// The scripted leg still stands: 'd','y' answers and reaches the
	// syscall (ENOSYS on the host => refused marker).
	m.handleKey(runeKey('d'))
	m.handleKey(runeKey('y'))
	if got := pendingJoined(&m); !strings.Contains(got, markerDeleteNo) {
		t.Fatalf("'d','y' must still reach the delete: %q", got)
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
	if len(m.clipSet) == 0 {
		t.Fatal("a refused paste must keep the clip held")
	}
}

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

// M121e (#2568): in the listing the seat's ctrl+z chord arrives as the
// 0x1a control byte and lands on the same trash restore as the `u` key.
// On the host the restore is honestly refused (no trash log), but the
// refusal marker proves the chord ran the undo path rather than no-op'ing.
func TestCtrlZRunsTrashRestore(t *testing.T) {
	var m model
	m.handleKey(keys.Event{Key: keys.KeyCtrlZ})
	if m.status != "restore refused" {
		t.Fatalf("ctrl+z status = %q, want the trash restore's honest refusal", m.status)
	}
	found := false
	for _, l := range m.drain() {
		if strings.HasPrefix(l, markerRestoreNo) {
			found = true
		}
	}
	if !found {
		t.Fatalf("ctrl+z emitted no %q marker", markerRestoreNo)
	}
}
