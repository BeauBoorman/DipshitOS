package main

import (
	"errors"
	"strings"
	"testing"

	"virelai/chords"
	"virelai/vi"
)

func TestHidUsagesMatchRunner(t *testing.T) {
	if hidUsageP != 0x13 {
		t.Fatalf("hidUsageP = %#x want 0x13 (USB HID 'p')", hidUsageP)
	}
	if hidUsageN != 0x11 {
		t.Fatalf("hidUsageN = %#x want 0x11 (USB HID 'n')", hidUsageN)
	}
	if hidUsageT != 0x17 {
		t.Fatalf("hidUsageT = %#x want 0x17 (USB HID 't')", hidUsageT)
	}
	if hidUsageD != 0x07 {
		t.Fatalf("hidUsageD = %#x want 0x07 (USB HID 'd')", hidUsageD)
	}
	if hidUsageF != 0x09 {
		t.Fatalf("hidUsageF = %#x want 0x09 (USB HID 'f')", hidUsageF)
	}
	if hidUsageTab != 0x2B {
		t.Fatalf("hidUsageTab = %#x want 0x2B (USB HID Tab)", hidUsageTab)
	}
	if hidUsageW != 0x1A {
		t.Fatalf("hidUsageW = %#x want 0x1A (USB HID 'w')", hidUsageW)
	}
	if hidUsagePageUp != 0x4B || hidUsagePageDown != 0x4E {
		t.Fatalf("page usages = %#x/%#x want 0x4B/0x4E", hidUsagePageUp, hidUsagePageDown)
	}
	if hidUsageSpace != 0x2C {
		t.Fatalf("hidUsageSpace = %#x want 0x2C (USB HID Space)", hidUsageSpace)
	}
	if hidUsageEnter != 0x28 || hidUsageEscape != 0x29 || hidUsageBksp != 0x2A {
		t.Fatal("enter/esc/bksp HID usages drifted")
	}
}

// M71e (#1564): ctrl-shift-f flips the frozen badge on the focused tab, and
// only on the focused tab. It is a badge — the tab stays closable, which the
// second half pins so nobody quietly turns this into a lock.
func TestHandleWmKeyFreezeToggle(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "Calc") || !tabs.OpenTab(4, "Edit") {
		t.Fatal("OpenTab")
	}
	if !tabs.FocusTab(4) {
		t.Fatal("FocusTab")
	}
	chord := func() {
		handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: uint32(hidUsageF)})
	}
	chord()
	if !tabs.At(1).Frozen || tabs.At(0).Frozen {
		t.Fatalf("first ctrl-shift-f froze the wrong tab: %+v %+v", tabs.At(0), tabs.At(1))
	}
	if n := tabs.FrozenCount(); n != 1 {
		t.Fatalf("FrozenCount = %d want 1", n)
	}
	chord()
	if tabs.At(1).Frozen {
		t.Fatal("second ctrl-shift-f must thaw the focused tab")
	}
	if n := tabs.FrozenCount(); n != 0 {
		t.Fatalf("FrozenCount = %d want 0 after thaw", n)
	}
	// The badge is not a lock: a frozen tab still closes (Zig has no frozen
	// check in its close path, and neither may this seat).
	chord()
	if !tabs.At(1).Frozen {
		t.Fatal("third chord should freeze again")
	}
	if !tabs.CloseTab(4) {
		t.Fatal("a frozen tab must still close — freeze is a badge, not a lock")
	}
	if tabs.Count() != 1 {
		t.Fatalf("count = %d want 1", tabs.Count())
	}
}

// execRecorder swaps the chord exec seam for one that records every exec's
// full command line and acks it, so the chord -> re-exec path (and the
// manifest's `argv=`) is observable off the guest. A no-argument exec records
// the bare binary, which is what the chord tests compare.
func execRecorder() (*[]string, func()) {
	execs := &[]string{}
	prev := execApp
	execApp = func(name string, args ...string) (int64, error) {
		*execs = append(*execs, strings.TrimSpace(name+" "+joinSpace(args)))
		return 42, nil
	}
	return execs, func() { execApp = prev }
}

func TestHandleWmKeyReopenChordReexecsLastClosed(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "Calc") || !tabs.OpenTab(4, "Edit") {
		t.Fatal("OpenTab")
	}
	if !tabs.CloseTab(3) {
		t.Fatal("CloseTab Calc")
	}
	execs, restore := execRecorder()
	defer restore()

	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: uint32(hidUsageT)})
	if len(*execs) != 1 || (*execs)[0] != "GOCALC.ELF" {
		t.Fatalf("ctrl-shift-t execs = %v want [GOCALC.ELF]", *execs)
	}
	// The LIFO is drained by the reopen: a second press is an honest no-op,
	// not a second exec.
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: uint32(hidUsageT)})
	if len(*execs) != 1 {
		t.Fatalf("second ctrl-shift-t must not exec again: %v", *execs)
	}
	// Ctrl+Shift+T must not have re-opened the tab on the strip by itself:
	// the reopened app declares and joins as a fresh tab (D1, a re-exec).
	if _, ok := tabs.Focused(); !ok {
		t.Fatal("Edit should still be focused")
	}
}

func TestHandleWmKeyDuplicateChordReexecsFocused(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	// Focus a tab with a recorded bin, then a tab with none: duplicate must
	// follow the focus, and an honest no-op is a no-op with no exec at all.
	if !tabs.OpenTab(4, "Edit") {
		t.Fatal("OpenTab Edit")
	}
	execs, restore := execRecorder()
	defer restore()

	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: uint32(hidUsageD)})
	if len(*execs) != 1 || (*execs)[0] != "GOEDIT.ELF" {
		t.Fatalf("ctrl-shift-d execs = %v want [GOEDIT.ELF]", *execs)
	}
	// Duplicate does not add a tab itself (the new window declares over RPC).
	if tabs.Count() != 1 {
		t.Fatalf("count = %d want 1", tabs.Count())
	}
}

func TestHandleWmKeyIgnoresUnboundCtrlShiftKeys(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	if !tabs.OpenTab(4, "Edit") {
		t.Fatal("OpenTab")
	}
	execs, restore := execRecorder()
	defer restore()
	// ctrl-shift-x is not a GOTABWM chord and must not reach the ring or the
	// duplicate path.
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: 0x1B})
	if len(*execs) != 0 {
		t.Fatalf("ctrl-shift-x exec'd: %v", *execs)
	}
}

func TestCtrlIndexMapsHIDNumberRow(t *testing.T) {
	for usage, want := range map[uint8]int{0x1e: 1, 0x1f: 2, 0x26: 9} {
		got, ok := ctrlIndex(usage)
		if !ok || got != want {
			t.Fatalf("ctrlIndex(%#x) = %d ok=%v want %d", usage, got, ok, want)
		}
	}
	for _, usage := range []uint8{0x04, 0x27, 0x2b} { // a, 0, Tab
		if got, ok := ctrlIndex(usage); ok {
			t.Fatalf("ctrlIndex(%#x) = %d ok=true want false", usage, got)
		}
	}
}

func TestAltTabNextPolicy(t *testing.T) {
	if _, ok := altTabNext(0, 0, false); ok {
		t.Fatal("zero tabs must no-op")
	}
	if _, ok := altTabNext(1, 0, false); ok {
		t.Fatal("one tab must no-op")
	}
	if i, ok := altTabNext(3, 0, false); !ok || i != 1 {
		t.Fatalf("forward 0 -> %d ok=%v want 1", i, ok)
	}
	if i, ok := altTabNext(3, 1, false); !ok || i != 2 {
		t.Fatalf("forward 1 -> %d ok=%v want 2", i, ok)
	}
	if i, ok := altTabNext(3, 2, false); !ok || i != 0 {
		t.Fatalf("forward wrap 2 -> %d ok=%v want 0", i, ok)
	}
	if i, ok := altTabNext(3, 0, true); !ok || i != 2 {
		t.Fatalf("shift wrap 0 -> %d ok=%v want 2", i, ok)
	}
	if i, ok := altTabNext(3, 2, true); !ok || i != 1 {
		t.Fatalf("shift 2 -> %d ok=%v want 1", i, ok)
	}
	if i, ok := altTabNext(3, -1, false); !ok || i != 1 {
		t.Fatalf("out-of-range focus starts at 0: got %d ok=%v", i, ok)
	}
}

func TestHandleWmKeyPinFocused(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "Calc") || !tabs.OpenTab(4, "Edit") {
		t.Fatal("OpenTab")
	}
	if !tabs.FocusTab(4) {
		t.Fatal("FocusTab")
	}
	// M121a: pin is ctrl-shift-n; ctrl-shift-p is the palette's chord now.
	handleWmKey(vi.Event{
		Kind:  vi.EvWmKey,
		Flags: vi.ModCtrl | vi.ModShift,
		Arg0:  uint32(hidUsageN),
	})
	if !tabs.At(0).Pinned || tabs.At(0).ID != 4 {
		t.Fatalf("pin did not jump left: %+v pinned=%v", tabs.At(0), tabs.At(0).Pinned)
	}
	id, ok := tabs.Focused()
	if !ok || id != 4 {
		t.Fatalf("focus after pin = %d ok=%v want 4", id, ok)
	}
	// Already pinned: Pin() is false, no second mutation.
	handleWmKey(vi.Event{
		Kind:  vi.EvWmKey,
		Flags: vi.ModCtrl | vi.ModShift,
		Arg0:  uint32(hidUsageN),
	})
	if tabs.At(1).Pinned {
		t.Fatal("second ctrl-shift-n must not pin the other tab")
	}
}

// M121b (#2565): the move pair shifts the focused tab one rail cell through
// the drag's Reorder path (focus follows by id, edges are honest no-ops),
// and ctrl+shift+w closes the focused tab through closeTabByID — the same
// `host close` / `tab close` / focus-handoff shape as every other close.
// Plain ctrl+w stays the editor's (unbound here — no close, no move).
func TestHandleWmKeyMoveAndCloseChords(t *testing.T) {
	saved := tabs
	savedHosted := hostedApp
	closed := []uint32{}
	raises := []uint32{}
	prevClose, prevRaise := closeWin, focusRaise
	closeWin = func(id uint32) int64 {
		closed = append(closed, id)
		return 0
	}
	focusRaise = func(id uint32) int64 {
		raises = append(raises, id)
		return 0
	}
	defer func() {
		tabs = saved
		hostedApp = savedHosted
		closeWin, focusRaise = prevClose, prevRaise
	}()
	tabs = TabStrip{}
	hostedApp = 0
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") || !tabs.OpenTab(5, "C") {
		t.Fatal("OpenTab")
	}
	if !tabs.FocusTab(5) {
		t.Fatal("FocusTab")
	}
	key := func(usage uint8) {
		handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: uint32(usage)})
	}
	key(hidUsagePageUp) // 2 -> 1
	if tabs.At(1).ID != 5 || tabs.At(2).ID != 4 {
		t.Fatalf("move-left left ids=%d,%d,%d want 3,5,4",
			tabs.At(0).ID, tabs.At(1).ID, tabs.At(2).ID)
	}
	if id, _ := tabs.Focused(); id != 5 {
		t.Fatalf("focus did not follow the move: %d", id)
	}
	key(hidUsagePageDown) // 1 -> 2
	if tabs.At(2).ID != 5 || tabs.At(1).ID != 4 {
		t.Fatalf("move-right left ids=%d,%d,%d want 3,4,5",
			tabs.At(0).ID, tabs.At(1).ID, tabs.At(2).ID)
	}
	if len(closed) != 0 {
		t.Fatalf("the move pair closed %v", closed)
	}
	// The left edge is an honest no-op: focus tab 3 at index 0, move-left
	// must change nothing.
	if !tabs.FocusTab(3) {
		t.Fatal("FocusTab 3")
	}
	key(hidUsagePageUp)
	if tabs.At(0).ID != 3 || tabs.Count() != 3 {
		t.Fatalf("move-left at the left edge mutated the strip: %+v", tabs.At(0))
	}
	// Plain ctrl+w is GOSH.ELF's kill-word — the seat must not close on it.
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: uint32(hidUsageW)})
	if len(closed) != 0 {
		t.Fatalf("plain ctrl+w closed %v — it is the editor's chord", closed)
	}
	// ctrl+shift+w closes the focused tab: the WM close fires once with id 3,
	// the strip drops to two tabs, and focus hands off to the neighbour that
	// took its slot (M62b), so exactly one raise runs.
	key(hidUsageW)
	if len(closed) != 1 || closed[0] != 3 {
		t.Fatalf("close chord closed %v want [3]", closed)
	}
	if tabs.Count() != 2 || tabs.At(0).ID != 4 || tabs.At(1).ID != 5 {
		t.Fatalf("strip after close: ids=%d,%d want 4,5", tabs.At(0).ID, tabs.At(1).ID)
	}
	if id, _ := tabs.Focused(); id != 4 {
		t.Fatalf("focus after the focused close = %d want 4", id)
	}
	if len(raises) != 1 || raises[0] != 4 {
		t.Fatalf("focused close raised %v want [4]", raises)
	}
	// The closed tab landed on the reopen LIFO — ctrl+shift+t's source.
	if c, ok := tabs.RecentlyClosed(0); !ok || c.Bin != "A" {
		t.Fatalf("reopen stack top = %+v ok=%v want Bin A", c, ok)
	}
}

// focusIndexRecorder replaces the guest-only focus seam so dispatch tests can
// observe the selected rail index without slot 65 or marker output.
func focusIndexRecorder() (*[]int, func()) {
	indices := &[]int{}
	prev := focusByIndex
	focusByIndex = func(i int) bool {
		*indices = append(*indices, i)
		return true
	}
	return indices, func() { focusByIndex = prev }
}

func TestHandleWmKeyCtrlTabAndDigitDispatch(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	for i, id := range []uint32{3, 4, 5} {
		if !tabs.OpenTab(id, string(rune('A'+i))) {
			t.Fatal("OpenTab")
		}
	}
	if !tabs.FocusTab(5) {
		t.Fatal("FocusTab")
	}
	indices, restore := focusIndexRecorder()
	defer restore()
	key := func(flags uint16, usage uint8) {
		handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: flags, Arg0: uint32(usage)})
	}

	key(vi.ModCtrl, hidUsageTab)             // wrap 2 -> 0
	key(vi.ModCtrl|vi.ModShift, hidUsageTab) // reverse 2 -> 1
	key(vi.ModCtrl, 0x1f)                    // Ctrl+2 -> index 1
	key(vi.ModCtrl, 0x23)                    // Ctrl+4 is past a 3-tab strip
	key(vi.ModCtrl, 0x1a)                    // Ctrl+W remains app-owned
	key(vi.ModCtrl|vi.ModAlt, hidUsageTab)   // Ctrl+Alt+Tab remains unbound
	want := []int{0, 1, 1}
	if len(*indices) != len(want) {
		t.Fatalf("focus indexes = %v want %v", *indices, want)
	}
	for i := range want {
		if (*indices)[i] != want[i] {
			t.Fatalf("focus indexes = %v want %v", *indices, want)
		}
	}
}

func TestHandleWmKeyLauncherPrecedesCtrlChords(t *testing.T) {
	stubLauncherWindows(t)
	savedTabs := tabs
	savedLaunch := launch
	defer func() {
		tabs = savedTabs
		launch = savedLaunch
	}()
	tabs = TabStrip{}
	tabs.OpenTab(3, "A")
	tabs.OpenTab(4, "B")
	launch = launcherState{open: true, sink: 9}
	indices, restore := focusIndexRecorder()
	defer restore()

	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: uint32(hidUsageTab)})
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: 0x1f})
	if len(*indices) != 0 {
		t.Fatalf("launcher-open ctrl chords focused rail indexes %v", *indices)
	}
	if launch.filter != "2" {
		t.Fatalf("launcher filter = %q want %q", launch.filter, "2")
	}
}

func TestHandleWmKeyLeavesPlainKeysToApp(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	tabs.OpenTab(3, "A")
	tabs.OpenTab(4, "B")
	indices, restore := focusIndexRecorder()
	defer restore()

	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x1B}) // HID 'x'
	if len(*indices) != 0 {
		t.Fatalf("plain x focused rail indexes %v", *indices)
	}
}

func TestHandleWmKeyAltTabNeedsKernel(t *testing.T) {
	saved := tabs
	savedHosted := hostedApp
	defer func() {
		tabs = saved
		hostedApp = savedHosted
	}()
	tabs = TabStrip{}
	hostedApp = 0
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(3)
	// Host WmctlTaskbarClick is ENOSYS: the strip must not change, so a
	// live miss is a guest-only failure rather than a silent host pass.
	if applyAltTab(false) {
		t.Fatal("host applyAltTab must fail closed (no slot 65)")
	}
	id, _ := tabs.Focused()
	if id != 3 {
		t.Fatalf("failed alt-tab mutated focus to %d", id)
	}
}

func TestPointerDownEdge(t *testing.T) {
	if pointerDownEdge(0, 0) || pointerDownEdge(0, hidBtnLeft) {
		t.Fatal("hover/up must not be a down edge")
	}
	if !pointerDownEdge(hidBtnLeft, 0) {
		t.Fatal("press must be a down edge")
	}
	if pointerDownEdge(hidBtnLeft, hidBtnLeft) {
		t.Fatal("held must not re-fire")
	}
}

func TestPointerUpEdge(t *testing.T) {
	if pointerUpEdge(0, 0) || pointerUpEdge(hidBtnLeft, 0) {
		t.Fatal("hover/press must not be an up edge")
	}
	if !pointerUpEdge(0, hidBtnLeft) {
		t.Fatal("release must be an up edge")
	}
	if pointerUpEdge(hidBtnLeft, hidBtnLeft) {
		t.Fatal("held must not look like an up")
	}
}

func TestRailCellAtTwoTabs(t *testing.T) {
	const w, n, h = 1280, 2, 22
	if i, ok := railCellAt(320, 10, w, n, h); !ok || i != 0 {
		t.Fatalf("tab 0 center (320,10) = %d ok=%v want 0", i, ok)
	}
	if i, ok := railCellAt(960, 10, w, n, h); !ok || i != 1 {
		t.Fatalf("tab 1 center (960,10) = %d ok=%v want 1", i, ok)
	}
	if i, ok := railCellAt(639, 0, w, n, h); !ok || i != 0 {
		t.Fatalf("left cell edge = %d ok=%v want 0", i, ok)
	}
	if i, ok := railCellAt(640, 21, w, n, h); !ok || i != 1 {
		t.Fatalf("right cell start = %d ok=%v want 1", i, ok)
	}
	if _, ok := railCellAt(320, 22, w, n, h); ok {
		t.Fatal("py == RailHeight is the pane, not the rail")
	}
	if _, ok := railCellAt(640, 360, w, n, h); ok {
		t.Fatal("client-area click must miss the rail")
	}
	if _, ok := railCellAt(320, 10, w, 0, h); ok {
		t.Fatal("empty strip has no cell")
	}
	// Remainder pixels past n*cellW still hit the last cell.
	if i, ok := railCellAt(1279, 10, 1280, 3, h); !ok || i != 2 {
		t.Fatalf("right remainder = %d ok=%v want 2", i, ok)
	}
}

func TestApplyRailClickMissesAndHostFailsClosed(t *testing.T) {
	saved := tabs
	savedHosted := hostedApp
	savedBtn := prevPtrButtons
	defer func() {
		tabs = saved
		hostedApp = savedHosted
		prevPtrButtons = savedBtn
	}()
	tabs = TabStrip{}
	hostedApp = 0
	prevPtrButtons = 0
	if applyRailClick(320, 10) {
		t.Fatal("empty strip must miss")
	}
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(4)
	if applyRailClick(640, 360) {
		t.Fatal("client-area must not focus")
	}
	id, _ := tabs.Focused()
	if id != 4 {
		t.Fatalf("client-area mutated focus to %d", id)
	}
	if applyRailClick(960, 10) {
		t.Fatal("already-focused cell must not re-fire")
	}
	if applyRailClick(320, 10) {
		t.Fatal("host rail click must fail closed (no slot 65)")
	}
	id, _ = tabs.Focused()
	if id != 4 {
		t.Fatalf("failed rail click mutated focus to %d", id)
	}
}

func TestHandleWmPointerDownEdgeOnly(t *testing.T) {
	saved := tabs
	savedHosted := hostedApp
	savedBtn := prevPtrButtons
	savedDrag := railDragFrom
	defer func() {
		tabs = saved
		hostedApp = savedHosted
		prevPtrButtons = savedBtn
		railDragFrom = savedDrag
	}()
	tabs = TabStrip{}
	hostedApp = 0
	prevPtrButtons = 0
	railDragFrom = -1
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(4)
	arg := uint32(320) | uint32(10)<<16
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: arg, Flags: 0})
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: arg, Flags: uint16(hidBtnLeft)})
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: arg, Flags: 0})
	id, _ := tabs.Focused()
	if id != 4 {
		t.Fatalf("host pointer sequence mutated focus to %d", id)
	}
	if prevPtrButtons != 0 {
		t.Fatalf("up must clear prevPtrButtons, got %#x", prevPtrButtons)
	}
	if railDragFrom != -1 {
		t.Fatalf("same-cell release must clear railDragFrom, got %d", railDragFrom)
	}
	if tabs.At(0).ID != 3 || tabs.At(1).ID != 4 {
		t.Fatal("same-cell click must not reorder")
	}
}

func TestRailDragReordersTwoTabs(t *testing.T) {
	saved := tabs
	savedHosted := hostedApp
	savedBtn := prevPtrButtons
	savedDrag := railDragFrom
	defer func() {
		tabs = saved
		hostedApp = savedHosted
		prevPtrButtons = savedBtn
		railDragFrom = savedDrag
	}()
	tabs = TabStrip{}
	hostedApp = 0
	prevPtrButtons = 0
	railDragFrom = -1
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(4)
	down := uint32(320) | uint32(10)<<16
	up := uint32(960) | uint32(10)<<16
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: down, Flags: uint16(hidBtnLeft)})
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: up, Flags: uint16(hidBtnLeft)})
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: up, Flags: 0})
	if tabs.At(0).ID != 4 || tabs.At(1).ID != 3 {
		t.Fatalf("drag 0→1 left ids=%d,%d want 4,3", tabs.At(0).ID, tabs.At(1).ID)
	}
	id, _ := tabs.Focused()
	if id != 4 {
		t.Fatalf("focus follows by id: got %d want 4", id)
	}
	if railDragFrom != -1 {
		t.Fatalf("release must clear railDragFrom, got %d", railDragFrom)
	}
}

func TestRailDragMissesClientAreaAndSameCell(t *testing.T) {
	saved := tabs
	savedHosted := hostedApp
	savedDrag := railDragFrom
	defer func() {
		tabs = saved
		hostedApp = savedHosted
		railDragFrom = savedDrag
	}()
	tabs = TabStrip{}
	hostedApp = 0
	railDragFrom = -1
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(4)
	beginRailDrag(640, 360)
	if railDragFrom != -1 {
		t.Fatal("client-area press must not arm a drag")
	}
	if endRailDrag(960, 10) {
		t.Fatal("unarmed release must not reorder")
	}
	beginRailDrag(320, 10)
	if railDragFrom != 0 {
		t.Fatalf("rail press armed %d want 0", railDragFrom)
	}
	if endRailDrag(320, 10) {
		t.Fatal("same-cell release must not reorder")
	}
	if tabs.At(0).ID != 3 || tabs.At(1).ID != 4 {
		t.Fatal("same-cell mutated order")
	}
	beginRailDrag(320, 10)
	if endRailDrag(640, 360) {
		t.Fatal("release off the rail must not reorder")
	}
	if tabs.At(0).ID != 3 {
		t.Fatal("off-rail release mutated order")
	}
}

// M79b (#1705): the close-x hit zone is the cell's rightmost railCloseW px —
// pinned geometry including the min-48px cell (the zone is exactly a third of
// the cell) and the honest non-targets: cell body, rail edge rows, the last
// cell's remainder pixels, an empty strip.
func TestRailCloseZoneAtGeometry(t *testing.T) {
	if MarkerRailHover != "gotabwm: rail-hover id=" {
		t.Fatalf("MarkerRailHover = %q (gate grep target)", MarkerRailHover)
	}
	const w, h = 1280, 22
	// Two tabs: cellW = 640; zones are [624,640) and [1264,1280).
	if i, ok := railCloseZoneAt(632, 10, w, 2, h); !ok || i != 0 {
		t.Fatalf("cell 0 close-x = %d ok=%v want 0", i, ok)
	}
	if _, ok := railCloseZoneAt(623, 10, w, 2, h); ok {
		t.Fatal("the cell body (x=623) must not be a close-x target")
	}
	if _, ok := railCloseZoneAt(320, 10, w, 2, h); ok {
		t.Fatal("the cell centre must not be a close-x target")
	}
	if i, ok := railCloseZoneAt(1272, 10, w, 2, h); !ok || i != 1 {
		t.Fatalf("cell 1 close-x = %d ok=%v want 1", i, ok)
	}
	if _, ok := railCloseZoneAt(1263, 10, w, 2, h); ok {
		t.Fatal("x=1263 is cell 1 body, not its close-x")
	}
	if _, ok := railCloseZoneAt(632, 22, w, 2, h); ok {
		t.Fatal("py == RailHeight is the pane, not the close-x")
	}
	if _, ok := railCloseZoneAt(632, 360, w, 2, h); ok {
		t.Fatal("client area is never a close-x target")
	}
	if _, ok := railCloseZoneAt(632, 10, w, 0, h); ok {
		t.Fatal("empty strip has no close-x")
	}
	// Min-48px cells (n*48 > width clamps cellW to 48): the zone is the
	// rightmost third — [32,48) of cell 0, [80,96) of cell 1.
	if i, ok := railCloseZoneAt(40, 10, w, 30, h); !ok || i != 0 {
		t.Fatalf("min-cell close-x = %d ok=%v want 0", i, ok)
	}
	if _, ok := railCloseZoneAt(31, 10, w, 30, h); ok {
		t.Fatal("x=31 is min-cell body")
	}
	if i, ok := railCloseZoneAt(88, 10, w, 30, h); !ok || i != 1 {
		t.Fatalf("min-cell 1 close-x = %d ok=%v want 1", i, ok)
	}
	// The last cell's remainder pixels past n*cellW resolve to the last
	// cell (railCellAt's rule) but sit outside its paint, so they stay
	// click/drag territory and are never a close-x target.
	if i, ok := railCloseZoneAt(1277, 10, w, 3, h); !ok || i != 2 {
		t.Fatalf("cell 2 close-x = %d ok=%v want 2", i, ok)
	}
	if _, ok := railCloseZoneAt(1278, 10, w, 3, h); ok {
		t.Fatal("the remainder pixel (x=1278) must not be a close-x target")
	}
	if _, ok := railCloseZoneAt(1279, 10, w, 3, h); ok {
		t.Fatal("the remainder pixel (x=1279) must not be a close-x target")
	}
}

// M79b (#1705): hover tracks the rail cell under the pointer and clears off
// the rail. State only — the entry marker is motion-only (updateRailHover).
func TestRailHoverTracksCells(t *testing.T) {
	saved := tabs
	savedHover := railHover
	defer func() {
		tabs = saved
		railHover = savedHover
	}()
	tabs = TabStrip{}
	railHover = -1
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(4)
	motion := func(px uint32) {
		handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: px | uint32(10)<<16, Flags: 0})
	}
	motion(320) // cell 0
	if railHover != 0 {
		t.Fatalf("hover over cell 0 tracked %d", railHover)
	}
	motion(321) // same cell: state holds
	if railHover != 0 {
		t.Fatalf("same-cell motion lost hover: %d", railHover)
	}
	motion(960) // cell 1
	if railHover != 1 {
		t.Fatalf("hover over cell 1 tracked %d", railHover)
	}
	// Below the rail: hover clears.
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: 320 | uint32(360)<<16, Flags: 0})
	if railHover != -1 {
		t.Fatalf("client-area motion must clear hover, got %d", railHover)
	}
}

// M79b (#1705): the close-x click closes the CELL's tab through the WM seam
// and nothing else — no focus change (the close tail never raises), no drag
// armed. A press on the cell body keeps today's click/drag behaviour byte for
// byte. The stubs are interop.go's closeWin / focusRaise seams (vi.Wmctl*
// bypasses the host syscall hook — the raw gateway is hardwired -ENOSYS).
func TestHandleWmPointerCloseXClosesWithoutFocusOrDrag(t *testing.T) {
	saved := tabs
	savedHosted := hostedApp
	savedBtn := prevPtrButtons
	savedDrag := railDragFrom
	savedHover := railHover
	closed := []uint32{}
	raises := 0
	prevClose, prevRaise := closeWin, focusRaise
	closeWin = func(id uint32) int64 {
		closed = append(closed, id)
		return 0
	}
	focusRaise = func(id uint32) int64 {
		raises++
		return 0
	}
	defer func() {
		tabs = saved
		hostedApp = savedHosted
		prevPtrButtons = savedBtn
		railDragFrom = savedDrag
		railHover = savedHover
		closeWin, focusRaise = prevClose, prevRaise
	}()
	tabs = TabStrip{}
	hostedApp = 0
	prevPtrButtons = 0
	railDragFrom = -1
	railHover = -1
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	_ = tabs.FocusTab(4)
	body := uint32(320) | uint32(10)<<16
	zone := uint32(632) | uint32(10)<<16
	// Cell body: the press still arms the drag (today's behaviour) and
	// still tries the click — the close-x is not a target there.
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: body, Flags: uint16(hidBtnLeft)})
	if railDragFrom != 0 {
		t.Fatalf("body press armed drag %d want 0", railDragFrom)
	}
	if len(closed) != 0 {
		t.Fatalf("a body press closed %v", closed)
	}
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: body, Flags: 0})
	if railDragFrom != -1 || tabs.At(0).ID != 3 || tabs.At(1).ID != 4 {
		t.Fatal("same-cell release must not reorder")
	}
	// The close-x: press + release closes cell 0's tab and NOTHING else.
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: zone, Flags: uint16(hidBtnLeft)})
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: zone, Flags: 0})
	if len(closed) != 1 || closed[0] != 3 {
		t.Fatalf("close-x closed %v want [3]", closed)
	}
	if raises != 0 {
		t.Fatalf("close-x must not focus: the close tail raised %d time(s)", raises)
	}
	if tabs.Count() != 1 || tabs.At(0).ID != 4 {
		t.Fatalf("strip after close-x holds %+v, want only id 4", tabs.At(0))
	}
	if id, _ := tabs.Focused(); id != 4 {
		t.Fatalf("focus moved to %d; close-x must not change focus", id)
	}
	if railDragFrom != -1 {
		t.Fatalf("close-x armed a drag: %d", railDragFrom)
	}
}

func TestHidUsageCharLetters(t *testing.T) {
	if c, ok := hidUsageChar(0x06); !ok || c != 'c' {
		t.Fatalf("HID c = %q ok=%v", c, ok)
	}
	if c, ok := hidUsageChar(0x04); !ok || c != 'a' {
		t.Fatalf("HID a = %q ok=%v", c, ok)
	}
	if c, ok := hidUsageChar(0x0f); !ok || c != 'l' {
		t.Fatalf("HID l = %q ok=%v", c, ok)
	}
	if _, ok := hidUsageChar(hidUsageEnter); ok {
		t.Fatal("enter is not a filter char")
	}
}

func TestLauncherCtrlSpaceToggleAndFilter(t *testing.T) {
	stubLauncherWindows(t)
	saved := launch
	defer func() { launch = saved }()
	launch = launcherState{}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: uint32(hidUsageSpace)})
	if !launch.open {
		t.Fatal("ctrl-space must open the launcher")
	}
	launch.catalog = []AppEntry{
		{Bin: "GOCALC.ELF", Label: "64-bit Calc"},
		{Bin: "NOTE.ELF", Label: "Text Editor"},
	}
	launch.refresh()
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x06}) // c
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x04}) // a
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x0f}) // l
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x06}) // c
	if launch.filter != "calc" {
		t.Fatalf("filter = %q want calc", launch.filter)
	}
	if len(launch.filtered) != 1 || launch.catalog[launch.filtered[0]].Bin != "GOCALC.ELF" {
		t.Fatalf("filtered = %v", launch.filtered)
	}
	// #2054 AC-C4: Esc is two-step — clear the typed query, then dismiss.
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: uint32(hidUsageEscape)})
	if !launch.open || launch.filter != "" {
		t.Fatal("the first escape must clear the filter, not dismiss")
	}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: uint32(hidUsageEscape)})
	if launch.open {
		t.Fatal("escape must dismiss")
	}
}

func TestLauncherFilterIgnoresStickyCtrl(t *testing.T) {
	stubLauncherWindows(t)
	saved := launch
	defer func() { launch = saved }()
	launch = launcherState{
		open:     true,
		sink:     9,
		catalog:  []AppEntry{{Bin: "GOCALC.ELF", Label: "64-bit Calc"}},
		filtered: []int{0},
	}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: 0x06}) // c, ctrl still down
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x04})                    // a
	if launch.filter != "ca" {
		t.Fatalf("sticky-ctrl filter = %q want ca", launch.filter)
	}
}

func TestLaunchRowAtHitsFirstRow(t *testing.T) {
	saved := launch
	defer func() { launch = saved }()
	launch = launcherState{
		open:     true,
		catalog:  []AppEntry{{Bin: "GOCALC.ELF", Label: "64-bit Calc"}},
		filtered: []int{0},
	}
	cx := uint32(launchX + 20)
	cy := uint32(launchY + launchHdr + 2)
	paintLauncher(launcherScan(), vi.ScanoutWidth, vi.ScanoutHeight)
	i, ok := launchRowAt(cx, cy)
	if !ok || i != 0 {
		t.Fatalf("row at (%d,%d) = %d ok=%v", cx, cy, i, ok)
	}
	if _, ok := launchRowAt(10, 10); ok {
		t.Fatal("outside panel must miss")
	}
}

// M82a (#1768): the row the manifest describes is the row that launches. A
// row with `argv=` carries those arguments into the exec; a row without one
// launches exactly as it did before the field existed.
func TestLauncherExecCarriesTheManifestArgv(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	saved := launch
	defer func() { launch = saved }()
	launch = launcherState{}
	execs, restore := execRecorder()
	defer restore()

	catalog := parseAppsTXT("PLAIN.ELF | Plain | p | dock=true\n" +
		"WITHARG.ELF | With Arg | w | dock=true | v=2 | argv=--mode fast\n")
	openLauncher()
	launch.catalog, launch.sel = catalog, 1
	launch.refresh()
	if launch.catalog[launch.filtered[1]].Bin != "WITHARG.ELF" {
		t.Fatalf("catalog order changed: %+v", launch.filtered)
	}
	execSelected()
	if len(*execs) != 1 || (*execs)[0] != "WITHARG.ELF --mode fast" {
		t.Fatalf("argv row exec = %v", *execs)
	}

	// The same path with a v1 row: the binary alone, no empty argument and
	// no marker change. This is the half of the additive claim the user sees.
	openLauncher()
	launch.catalog, launch.sel = catalog, 0
	launch.refresh()
	execSelected()
	if len(*execs) != 2 || (*execs)[1] != "PLAIN.ELF" {
		t.Fatalf("v1 row exec = %v", *execs)
	}
}

// M79c (#1706): the split-cycle chord is USB HID 'v' (0x19), like every
// other ctrl-shift chord in the frozen table.
func TestHidUsageVMatchesRunner(t *testing.T) {
	if hidUsageV != 0x19 {
		t.Fatalf("hidUsageV = %#x want 0x19 (USB HID 'v')", hidUsageV)
	}
}

// rectCall is one wmctlSetRect proposal the seat made.
type rectCall struct {
	id, x, y, w, h uint32
}

// rectRecorder swaps the slot-65 rect seam for a recorder (success), so the
// split/sash -> relayout path is observable off the guest. Same shape as
// hid_test.go's execRecorder.
func rectRecorder() (*[]rectCall, func()) {
	calls := &[]rectCall{}
	prev := wmctlSetRect
	wmctlSetRect = func(id, x, y, w, h uint32) int64 {
		*calls = append(*calls, rectCall{id, x, y, w, h})
		return 0
	}
	return calls, func() { wmctlSetRect = prev }
}

// saveSeatState snapshots the globals a pointer/chord test can disturb.
// tabs rides by value (fixed arrays); launch rides whole-struct, the
// existing hid_test.go pattern.
func saveSeatState() func() {
	ts, pl := tabs, launch
	pb, cd, rd, rh, sd := prevPtrButtons, contentDown, railDragFrom, railHover, sashDragging
	rc, gh := railCloseHover, godButtonHover
	mg := menuGesture
	bp, mp := buttonPixels, menuPixels
	pp := powerPixels
	pm, ps, ph := powerMenuOpen, powerSink, powerBtnHover
	sf := seatFonts
	return func() {
		tabs, launch = ts, pl
		prevPtrButtons, contentDown, railDragFrom, railHover, sashDragging = pb, cd, rd, rh, sd
		railCloseHover, godButtonHover = rc, gh
		menuGesture = mg
		buttonPixels, menuPixels = bp, mp
		powerPixels = pp
		powerMenuOpen, powerSink, powerBtnHover = pm, ps, ph
		seatFonts = sf
	}
}

func ptrEvent(x, y uint32, buttons uint8) vi.Event {
	return vi.Event{Kind: vi.EvWmPointer, Arg0: x | y<<16, Flags: uint16(buttons)}
}

func openTwoTabs(t *testing.T) {
	t.Helper()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "Calc") || !tabs.OpenTab(4, "Edit") {
		t.Fatal("OpenTab")
	}
}

// M79c (#1706): ctrl-shift-v cycles none -> V -> H -> none through the same
// apply* paths the choreography uses, so the markers and dumps are shapes
// the gates already pin. Fewer than two tabs is a silent no-op.
func TestSplitCycleChord(t *testing.T) {
	defer saveSeatState()()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "Calc") {
		t.Fatal("OpenTab")
	}
	calls, restore := rectRecorder()
	defer restore()
	chord := func() {
		handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: uint32(hidUsageV)})
	}
	launch.open = false
	chord()
	if tabs.Split() != SplitNone || len(*calls) != 0 {
		t.Fatalf("one tab: split=%s rects=%d (must be a silent no-op)", tabs.Split(), len(*calls))
	}
	if !tabs.OpenTab(4, "Edit") {
		t.Fatal("OpenTab")
	}
	chord()
	if tabs.Split() != SplitVert {
		t.Fatalf("first chord: split=%s want v", tabs.Split())
	}
	// The right pane moves off-origin, so applyRect's two-step
	// (shrink-at-origin, then move) proposes 3 rects, not 2.
	if len(*calls) != 3 {
		t.Fatalf("split v must propose 3 rects, got %d: %+v", len(*calls), *calls)
	}
	if (*calls)[0] != (rectCall{3, 0, 0, 640, 720}) ||
		(*calls)[1] != (rectCall{4, 0, 0, 640, 720}) ||
		(*calls)[2] != (rectCall{4, 640, 0, 640, 720}) {
		t.Fatalf("split v rects = %+v", *calls)
	}
	chord()
	if tabs.Split() != SplitHoriz {
		t.Fatalf("second chord: split=%s want h", tabs.Split())
	}
	if len(*calls) != 6 {
		t.Fatalf("split h must propose 3 more rects, got %d: %+v", len(*calls), *calls)
	}
	if (*calls)[3] != (rectCall{3, 0, 0, 1280, 360}) ||
		(*calls)[4] != (rectCall{4, 0, 0, 1280, 360}) ||
		(*calls)[5] != (rectCall{4, 0, 360, 1280, 360}) {
		t.Fatalf("split h rects = %+v", *calls)
	}
	chord()
	if tabs.Split() != SplitNone {
		t.Fatalf("third chord: split=%s want none", tabs.Split())
	}
}

// M79c (#1706): the pointer path end to end on the host — a down on the
// divider arms the sash (no rail drag, no focus change, no content), motion
// while armed stays swallowed, and the release commits the clamped divider
// through the rect seam.
func TestSashDragPointerPath(t *testing.T) {
	defer saveSeatState()()
	openTwoTabs(t)
	launch.open = false
	prevPtrButtons = 0
	calls, restore := rectRecorder()
	defer restore()
	if !applySplit(SplitVert) {
		t.Fatal("applySplit v")
	}
	*calls = (*calls)[:0]
	// Down on the divider (midpoint x=640, y=100: below the rail, clear of
	// the bottom chrome) arms the sash and consumes the press.
	handleWmPointer(ptrEvent(640, 100, hidBtnLeft))
	if !sashDragging {
		t.Fatal("divider down must arm sashDragging")
	}
	if contentDown {
		t.Fatal("sash down must not forward content")
	}
	if railDragFrom != -1 {
		t.Fatal("sash down must not arm a rail drag")
	}
	// Held-button motion is an in-progress resize, not content: swallowed,
	// and the divider does not move before the release edge.
	handleWmPointer(ptrEvent(700, 100, hidBtnLeft))
	if !sashDragging || contentDown {
		t.Fatal("armed motion must stay armed and content-free")
	}
	if tabs.sash != 0 {
		t.Fatal("motion must not move the divider (release-edge commit only)")
	}
	// Release at x=800 commits: the gutter pair goes out and the sash sticks.
	handleWmPointer(ptrEvent(800, 100, 0))
	if sashDragging {
		t.Fatal("release must disarm")
	}
	if tabs.sash != 800 {
		t.Fatalf("sash = %d want 800", tabs.sash)
	}
	// Left pane at the origin: 1 call. Right pane off-origin: the
	// two-step shrink-then-move, 2 calls.
	if len(*calls) != 3 {
		t.Fatalf("sash commit must propose 3 rects, got %d: %+v", len(*calls), *calls)
	}
	if (*calls)[0] != (rectCall{3, 0, 0, 797, 720}) ||
		(*calls)[1] != (rectCall{4, 0, 0, 477, 720}) ||
		(*calls)[2] != (rectCall{4, 803, 0, 477, 720}) {
		t.Fatalf("sash rects = %+v", *calls)
	}
	if contentDown {
		t.Fatal("sash release must not leave a content latch")
	}
}

// M79c (#1706): a release on the armed position is the press-on-the-divider
// release — an honest no-op: no syscalls, no state change.
func TestSashReleaseOnArmedPositionIsNoop(t *testing.T) {
	defer saveSeatState()()
	openTwoTabs(t)
	launch.open = false
	prevPtrButtons = 0
	calls, restore := rectRecorder()
	defer restore()
	if !applySplit(SplitVert) {
		t.Fatal("applySplit v")
	}
	*calls = (*calls)[:0]
	handleWmPointer(ptrEvent(640, 100, hidBtnLeft))
	if !sashDragging {
		t.Fatal("divider down must arm")
	}
	handleWmPointer(ptrEvent(640, 100, 0))
	if sashDragging || tabs.sash != 0 {
		t.Fatal("same-position release must disarm without storing")
	}
	if len(*calls) != 0 {
		t.Fatalf("no-op release proposed %d rects", len(*calls))
	}
}

// M79c (#1706): a reorder while split re-proposes both pane rects, so the
// panes follow the tabs instead of silently swapping which app is left.
// Unsplit reorders propose nothing.
func TestRailReorderReappliesWhileSplit(t *testing.T) {
	defer saveSeatState()()
	openTwoTabs(t)
	calls, restore := rectRecorder()
	defer restore()
	if !applySplit(SplitVert) {
		t.Fatal("applySplit v")
	}
	*calls = (*calls)[:0]
	if !applyRailReorder(0, 1) {
		t.Fatal("applyRailReorder")
	}
	if tabs.At(0).ID != 4 || tabs.At(1).ID != 3 {
		t.Fatalf("order = %d,%d want 4,3", tabs.At(0).ID, tabs.At(1).ID)
	}
	// Reordered panes follow the tabs (4 left, 3 right); the right pane's
	// off-origin move is the two-step, so 3 proposals.
	if len(*calls) != 3 {
		t.Fatalf("split reorder must re-propose 3 rects, got %d: %+v", len(*calls), *calls)
	}
	if (*calls)[0] != (rectCall{4, 0, 0, 640, 720}) ||
		(*calls)[1] != (rectCall{3, 0, 0, 640, 720}) ||
		(*calls)[2] != (rectCall{3, 640, 0, 640, 720}) {
		t.Fatalf("reordered pane rects = %+v", *calls)
	}
	if !tabs.Unsplit() {
		t.Fatal("Unsplit")
	}
	*calls = (*calls)[:0]
	if !applyRailReorder(0, 1) {
		t.Fatal("applyRailReorder unsplit")
	}
	if len(*calls) != 0 {
		t.Fatalf("unsplit reorder proposed %d rects", len(*calls))
	}
}

// M79k (#1720): a press on a toast is CHROME. It dismisses the toast and
// focuses its sender, and it is consumed there — no rail drag armed, no
// start-surface summon, and no content forward on the press or the release
// (a stray content drag inside a hosted pane would outlive the toast).
//
// The focus leg needs the kernel's taskbar seam, which is hardwired -ENOSYS
// on the host, so the two halves are asserted separately and honestly: the
// DISMISS is unconditional and observable here, and the focus leg is the
// focusHosted helper every other focus path (alt-tab, rail click) already
// runs. The class-B gate proves the focus lands on the guest.
func TestHandleWmPointerPressOnToastIsChrome(t *testing.T) {
	defer saveSeatState()()
	resetNotify(t)
	saved := tabs
	savedHosted := hostedApp
	savedBtn := prevPtrButtons
	savedDrag := railDragFrom
	savedHover := railHover
	savedSash := sashDragging
	savedContent := contentDown
	savedLaunch := launch
	defer func() {
		tabs = saved
		hostedApp = savedHosted
		prevPtrButtons = savedBtn
		railDragFrom = savedDrag
		railHover = savedHover
		sashDragging = savedSash
		contentDown = savedContent
		launch = savedLaunch
	}()
	tabs = TabStrip{}
	hostedApp = 0
	prevPtrButtons = 0
	railDragFrom = -1
	railHover = -1
	sashDragging = false
	contentDown = false
	launch = launcherState{}
	if !tabs.OpenTab(4, "files") {
		t.Fatal("OpenTab")
	}
	if _, ok, _ := notifyPush(4, "copied KNOWN.TXT", 0); !ok {
		t.Fatal("push refused")
	}

	x, y, pw, ph := notifyRect(vi.ScanoutWidth, vi.ScanoutHeight, 0, 1)
	at := uint32(x+pw/2) | uint32(y+ph/2)<<16
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: at, Flags: uint16(hidBtnLeft)})
	if notifyCount() != 0 {
		t.Fatalf("a press on a toast left %d in the strip", notifyCount())
	}
	if railDragFrom != -1 {
		t.Fatalf("a toast press armed the rail drag (from=%d)", railDragFrom)
	}
	if contentDown {
		t.Fatal("a toast press set contentDown: the release would forward to the kernel as terminal content")
	}
	if launch.open {
		t.Fatal("a toast press opened the launcher")
	}
	if sashDragging {
		t.Fatal("a toast press armed the sash")
	}
	// The matching release forwards nothing: the press never set
	// contentDown, so the release is a no-op.
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: at, Flags: 0})
	if contentDown {
		t.Fatal("the release after a toast press set contentDown")
	}
	if prevPtrButtons != 0 {
		t.Fatalf("up must clear prevPtrButtons, got %#x", prevPtrButtons)
	}

	// A press ONE PIXEL outside the toast is not chrome: it falls through
	// to the content path, which is what the boundary test in
	// notify_test.go pins from the other side.
	notifyPush(4, "copied KNOWN.TXT", 0)
	_, y, _, _ = notifyRect(vi.ScanoutWidth, vi.ScanoutHeight, 0, 1)
	below := uint32(x+pw/2) | uint32(y+ph+2)<<16
	contentDown = false
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: below, Flags: uint16(hidBtnLeft)})
	if !contentDown {
		t.Fatal("a press just below the toast was swallowed as chrome")
	}
	if notifyCount() != 1 {
		t.Fatal("a press below the toast dismissed it")
	}
	contentDown = false
}

// TestToastHitPrecedesTheLauncher is the paint-order/hit-order agreement: the
// strip is painted LAST, so a press on a toast has to be found FIRST. The
// launcher's own block returns early for every button, which meant a press on
// a toast that fired while the launcher was open never reached the toast at
// all — it closed the launcher under a toast the user could plainly see. With
// the #2054 left-edge strip the rects genuinely overlap (toast x<216 is inside
// the strip's x<launchW), so the press below is not just order-pinned, it is a
// real overlapping rect the order decides.
func TestToastHitPrecedesTheLauncher(t *testing.T) {
	defer saveSeatState()()
	resetNotify(t)
	saved := tabs
	savedLaunch := launch
	savedBtn := prevPtrButtons
	defer func() {
		tabs = saved
		launch = savedLaunch
		prevPtrButtons = savedBtn
	}()
	tabs = TabStrip{}
	prevPtrButtons = 0
	launch = launcherState{}
	launch.open = true
	launch.filtered = []int{0, 1}
	if !tabs.OpenTab(4, "files") {
		t.Fatal("OpenTab")
	}
	if _, ok, _ := notifyPush(4, "copied KNOWN.TXT", 0); !ok {
		t.Fatal("push refused")
	}

	x, y, pw, ph := notifyRect(vi.ScanoutWidth, vi.ScanoutHeight, 0, 1)
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer,
		Arg0:  uint32(x+pw/2) | uint32(y+ph/2)<<16,
		Flags: uint16(hidBtnLeft)})
	if notifyCount() != 0 {
		t.Fatalf("a press on a toast left %d in the strip while the launcher was open", notifyCount())
	}
	if !launch.open {
		t.Fatal("a press on a toast closed the launcher: the launcher's early return shadowed the strip")
	}

	// A press that is NOT on a toast still belongs to the launcher, exactly
	// as before: on the empty desktop past the strip's right edge it
	// dismisses it. The point is past launchW — inside the strip it would
	// be panel chrome, not an outside click.
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: uint32(x+pw/2) | uint32(y+ph/2)<<16, Flags: 0})
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer,
		Arg0:  uint32(launchW+136) | uint32(y+ph+2)<<16,
		Flags: uint16(hidBtnLeft)})
	if launch.open {
		t.Fatal("a press on the desktop past the strip no longer reaches the launcher")
	}
}

// M82c (#1770): the local usage constants and the registry cannot drift.
// Every named chord's row must carry the number the runner and the kernel
// assume, and the launcher's modal keys must match the registry's usages.
func TestHidUsagesMatchRegistry(t *testing.T) {
	rowUsage := func(action string) uint8 {
		for _, r := range chords.Global.SeatRows() {
			if r.Action == action {
				return r.Chord.Usage
			}
		}
		t.Fatalf("no seat row for action %q", action)
		return 0
	}
	for action, usage := range map[string]uint8{
		"pin": hidUsageN, "palette": hidUsageP,
		"reopen": hidUsageT, "duplicate": hidUsageD,
		"snapshot-bundle": hidUsageS,
		"freeze-badge":    hidUsageF, "split-cycle": hidUsageV,
		"nav-back": hidUsageLeftBracket, "nav-forward": hidUsageRightBracket,
		"undo": hidUsageZ,
	} {
		if rowUsage(action) != usage {
			t.Errorf("registry action %q usage drifted from the local constant %#x", action, usage)
		}
	}
	if chords.UsageSpace != hidUsageSpace || chords.UsageEnter != hidUsageEnter ||
		chords.UsageEscape != hidUsageEscape || chords.UsageBksp != hidUsageBksp {
		t.Fatal("launcher modal usages drifted from the registry")
	}
}

// M82c (#1770): the dispatch IS the registry walk, so a chord the table
// carries must reach its action through handleWmKey — ctrl-space (closed
// launcher) opens the launcher from the table's "launcher" row.
func TestLauncherSummonDispatchesFromRegistry(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	savedLaunch := launch
	defer func() { launch = savedLaunch }()
	launch = launcherState{}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: uint32(hidUsageSpace)})
	if !launch.open {
		t.Fatal("ctrl-space (registry row 'launcher') did not open the launcher")
	}
	// Plain Enter on a POPULATED strip is not the start surface row's
	// business: the row matches, the action honestly no-ops.
	launch = launcherState{}
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}
	if !tabs.OpenTab(7, "Calc") {
		t.Fatal("OpenTab")
	}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: 0, Arg0: uint32(hidUsageEnter)})
	if launch.open {
		t.Fatal("enter with a populated strip must not open the launcher")
	}
	// ...and on an EMPTY strip it is the start surface.
	tabs = TabStrip{}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: 0, Arg0: uint32(hidUsageEnter)})
	if !launch.open {
		t.Fatal("enter on an empty strip (registry row 'start-surface') did not open the launcher")
	}
}

// M82c (#1770): the fixture attempt's verdict. With the trigger file
// present, the checker is fed the deliberately conflicting fixture and
// refuses it with the full named error; without the trigger, nothing is
// attempted. The prologue's printed lines are run 08's serial asserts —
// the host test owns the verdict, the gate owns the guest evidence.
func TestChordFixtureAttempt(t *testing.T) {
	if err := chords.Global.Validate(); err != nil {
		t.Fatalf("shipped table must validate (the prologue is fail-closed): %v", err)
	}
	savedOpen := openFile
	defer func() { openFile = savedOpen }()

	// No trigger file: nothing attempted, nothing refused.
	openFile = func(path string, flags uint32) (int64, int64) { return -1, -1 }
	attempted, err := chordFixtureAttempt()
	if attempted || err != nil {
		t.Fatalf("without the trigger nothing must be attempted, got (%v, %v)", attempted, err)
	}

	// Trigger present: the refusal is the checker's named sentence.
	openFile = func(path string, flags uint32) (int64, int64) { return 4, 4 }
	attempted, err = chordFixtureAttempt()
	if !attempted {
		t.Fatal("the trigger file must arm the fixture attempt")
	}
	if !errors.Is(err, chords.ErrChordConflict) {
		t.Fatalf("fixture must be refused with ErrChordConflict, got: %v", err)
	}
	want := "chord conflict: ctrl+shift+p at seat owned by seat and FIXTURE.ELF"
	if err == nil || err.Error() != want {
		t.Fatalf("refusal:\n got: %v\nwant: %s", err, want)
	}
}

// M82c (#1770): the summary line's counts are internally consistent —
// every row lands in exactly one owner class and the seat class matches
// the dispatch surface the tests pin.
func TestChordSummaryCounts(t *testing.T) {
	var kernel, seat, app int
	for _, r := range chords.Global {
		switch {
		case r.Scope == chords.ScopeKernelTerminal:
			kernel++
		case r.Scope == chords.ScopeSeat:
			seat++
		default:
			app++
		}
	}
	got := chordSummary(len(chords.Global), seat, kernel, app)
	want := "gotabwm: chords n=59 seat=29 kernel=12 app=18"
	if got != want {
		t.Fatalf("chordSummary = %q want %q", got, want)
	}
}

func TestGodMenuGestureNeverForwardsContent(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	resetNotify(t)
	oldPtr, oldExec := forwardContentPointer, execApp
	defer func() { forwardContentPointer, execApp = oldPtr, oldExec }()
	forwards := 0
	forwardContentPointer = func(uint32, uint32, uint8) int64 {
		forwards++
		return 0
	}
	execApp = func(string, ...string) (int64, error) { return 42, nil }
	tabs = TabStrip{}
	tabs.OpenTab(3, "Edit")
	tabs.OpenTab(4, "Terminal")
	for _, action := range []string{"launch", "dismiss", "header"} {
		launch = launcherState{}
		prevPtrButtons, menuGesture = 0, false
		railDragFrom, contentDown, sashDragging = -1, false, false
		x, y, w, h := godMenuRect(vi.ScanoutWidth, vi.ScanoutHeight)
		handleWmPointer(ptrEvent(uint32(x+w/2), uint32(y+h/2), hidBtnLeft))
		handleWmPointer(ptrEvent(800, 400, hidBtnLeft))
		handleWmPointer(ptrEvent(800, 400, 0))
		if !launch.open {
			t.Fatal("button must open with tabs")
		}
		paintLauncher(launcherScan(), vi.ScanoutWidth, vi.ScanoutHeight)
		px, py := uint32(launchX+20), uint32(launchY+launchHdr+2)
		switch action {
		case "dismiss":
			px, py = 800, 650
		case "header":
			py = launchY + launchHdr - 1
		}
		handleWmPointer(ptrEvent(px, py, hidBtnLeft))
		handleWmPointer(ptrEvent(960, 10, hidBtnLeft)) // not a rail drag
		handleWmPointer(ptrEvent(800, 400, hidBtnLeft))
		handleWmPointer(ptrEvent(800, 400, 0))
		if forwards != 0 || contentDown || railDragFrom != -1 || menuGesture {
			t.Fatalf("%s gesture escaped: forwards=%d content=%v drag=%d latch=%v",
				action, forwards, contentDown, railDragFrom, menuGesture)
		}
		if tabs.At(0).ID != 3 || tabs.At(1).ID != 4 {
			t.Fatal("menu gesture reordered the rail")
		}
		if (action == "header") != launch.open {
			t.Fatalf("%s open=%v", action, launch.open)
		}
	}
}

// M121e (#2568): the undo chord's seat-side routing — a strip-focused
// press is the seat's own undo (the reopen LIFO, one exec), a focused
// live tab's press ROUTES to the tab's own binding (no exec, no pop —
// the revert is the app's business), and a session placeholder is an
// honest no-op. The route marker is gate-pinned; the host test owns the
// state consequences.
func TestHandleWmKeyUndoChordDispatches(t *testing.T) {
	defer saveSeatState()()
	saved := tabs
	defer func() { tabs = saved }()

	// Strip focus: the seat's own undo pops the reopen LIFO.
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "Calc") || !tabs.CloseTab(3) {
		t.Fatal("seed the reopen ring")
	}
	execs, restore := execRecorder()
	defer restore()
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: uint32(hidUsageZ)})
	if len(*execs) != 1 || (*execs)[0] != "GOCALC.ELF" {
		t.Fatalf("strip-focused ctrl-z must reopen the last closed tab, got %v", *execs)
	}
	// Drained ring: an honest no-op, not a second exec.
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: uint32(hidUsageZ)})
	if len(*execs) != 1 {
		t.Fatalf("empty ring must not exec again: %v", *execs)
	}

	// Focused live tab: the chord routes — nothing execs, nothing pops.
	tabs = TabStrip{}
	if !tabs.OpenTab(4, "Edit") || !tabs.FocusTab(4) {
		t.Fatal("OpenTab/FocusTab")
	}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: uint32(hidUsageZ)})
	if len(*execs) != 1 {
		t.Fatalf("a focused tab's ctrl-z must not exec: %v", *execs)
	}

	// A focused session placeholder is not a live client: silent no-op.
	tabs = TabStrip{}
	if !tabs.OpenTab(sessionIDBase+1, "Ghost") || !tabs.FocusTab(sessionIDBase+1) {
		t.Fatal("placeholder OpenTab/FocusTab")
	}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: uint32(hidUsageZ)})
	if len(*execs) != 1 {
		t.Fatalf("a placeholder's ctrl-z must not exec: %v", *execs)
	}
}

// #2703: the demo-mode cycle-focus chord parks on decode and applies only
// after the focused app goes quiet on both legs the seat can measure —
// the input window (lastInputTick) and the app's scheduler work
// (cpu_ticks flat). Live mode and a sub-two-tab strip never park.
func TestFocusCycleParkAndRelease(t *testing.T) {
	savedTabs, savedDemo := tabs, demoMode
	savedInput, savedSeat := lastInputTick, seatTick
	savedPending := cyclePending
	defer func() {
		tabs, demoMode = savedTabs, savedDemo
		lastInputTick, seatTick = savedInput, savedSeat
		cyclePending = savedPending
	}()
	indices, restore := focusIndexRecorder()
	defer restore()
	cpu := uint64(100)
	var haveProbe bool
	savedProbe := focusedCpuTicks
	focusedCpuTicks = func(uint32) (uint64, bool) { return cpu, haveProbe }
	defer func() { focusedCpuTicks = savedProbe }()

	open2 := func() {
		tabs = TabStrip{}
		if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") || !tabs.FocusTab(3) {
			t.Fatal("two-tab strip")
		}
	}

	// Live mode: the chord applies on decode, never parks.
	demoMode, cyclePending = false, false
	open2()
	if armFocusCycle(false) || cyclePending {
		t.Fatal("live mode must not park the cycle")
	}

	// Demo mode under two tabs: the chord is a no-op press, not a park.
	demoMode = true
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "A") {
		t.Fatal("OpenTab")
	}
	if armFocusCycle(false) || cyclePending {
		t.Fatal("a single-tab strip must not park the cycle")
	}

	// Demo mode with a real cycle: parked, not applied, until BOTH quiet
	// legs hold for the window.
	seatTick = 10
	open2()
	if !armFocusCycle(false) || !cyclePending {
		t.Fatal("demo mode must park the cycle")
	}
	if len(*indices) != 0 {
		t.Fatalf("parked cycle applied early: %v", *indices)
	}
	// Input still churning (a sibling chord landed this tick): no release
	// even though the app probe is flat.
	haveProbe = true
	lastInputTick = 10
	releaseFocusCycle(11)
	if len(*indices) != 0 {
		t.Fatalf("cycle released inside the input window: %v", *indices)
	}
	// Input quiet but the app is still accruing ticks — each advance
	// restarts the flat streak.
	lastInputTick = 0
	for i, c := range []uint64{101, 102, 103} {
		cpu = c
		releaseFocusCycle(uint64(20 + i))
		if len(*indices) != 0 {
			t.Fatalf("cycle released while the app was busy: %v", *indices)
		}
	}
	// Flat streak + quiet input: the window counts flat samples, so the
	// release lands on the Kth flat read.
	for i := 0; i < focusCycleQuietTicks; i++ {
		releaseFocusCycle(uint64(30 + i))
	}
	if len(*indices) != 1 {
		t.Fatalf("quiet legs held for the window but no cycle applied: %v", *indices)
	}
	if cyclePending {
		t.Fatal("applied cycle must clear the park")
	}

	// A kernel with no v2 probe leaves the input window as the only leg.
	cyclePending, cycleCpuInit, cycleCpuQuiet = false, false, 0
	haveProbe = false
	open2()
	if !armFocusCycle(true) || !cyclePending {
		t.Fatal("demo mode must park the reverse cycle")
	}
	lastInputTick = 0
	for i := 0; i < focusCycleQuietTicks; i++ {
		releaseFocusCycle(uint64(40 + i))
	}
	if len(*indices) != 2 {
		t.Fatalf("no probe must degrade to the input window alone: %v", *indices)
	}

	// A persistently busy app cannot wedge the chord: the hold bound
	// applies the cycle anyway.
	cyclePending, cycleCpuInit, cycleCpuQuiet = false, false, 0
	haveProbe = true
	open2()
	seatTick = 50
	if !armFocusCycle(false) {
		t.Fatal("park for the bound")
	}
	lastInputTick = seatTick // input never quiets either
	for i := uint64(0); i < focusCycleHoldMax; i++ {
		cpu += 9
		releaseFocusCycle(seatTick + 1 + i)
	}
	if len(*indices) != 3 {
		t.Fatalf("the hold bound must still apply the cycle: %v", *indices)
	}
}
