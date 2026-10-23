package main

// M190c (#3238): the rail dock badge (per-tab unread center rows, cleared
// by focus) and the button-2 rail menu (focus / duplicate / pin / quit
// over the target cell, not the focused one).

import (
	"testing"

	"virelai/vi"
)

// railMenuFixture resets the package state the badge and menu read, opens
// two tabs, and returns a cleanup that puts every touched global back.
func railMenuFixture(t *testing.T, ids ...uint32) func() {
	t.Helper()
	savedTabs := tabs
	savedCenter := notifyCenter
	savedNext := notifyCenterNextID
	savedOpen := railMenuOpen
	savedSel := railMenuSel
	savedSink := railMenuSink
	savedTab := railMenuTab
	savedPrior := railMenuPrior
	savedBtn := prevPtrButtons
	savedHosted := hostedApp
	tabs = TabStrip{}
	notifyCenter = nil
	notifyCenterNextID = 0
	railMenuOpen = false
	railMenuSel = 0
	railMenuSink = 0
	railMenuTab = 0
	railMenuPrior = 0
	prevPtrButtons = 0
	hostedApp = 0
	for _, id := range ids {
		if !tabs.OpenTab(id, "App") {
			t.Fatalf("OpenTab %d", id)
		}
	}
	return func() {
		tabs = savedTabs
		notifyCenter = savedCenter
		notifyCenterNextID = savedNext
		railMenuOpen = savedOpen
		railMenuSel = savedSel
		railMenuSink = savedSink
		railMenuTab = savedTab
		railMenuPrior = savedPrior
		prevPtrButtons = savedBtn
		hostedApp = savedHosted
	}
}

func TestRailBadgeCountsAndClearsOnFocus(t *testing.T) {
	defer railMenuFixture(t, 3, 4)()
	if got := railBadgeCount(4); got != 0 {
		t.Fatalf("fresh tab badges %d want 0", got)
	}
	notifyCenterPush(4, "one")
	notifyCenterPush(4, "two")
	notifyCenterPush(3, "other")
	if got := railBadgeCount(4); got != 2 {
		t.Fatalf("badge = %d want 2 (two rows for tab 4)", got)
	}
	if got := railBadgeCount(3); got != 1 {
		t.Fatalf("badge = %d want 1", got)
	}
	// Rows that predate the tab are not its news: a window id reused by a
	// later tab starts at the current watermark.
	if !tabs.CloseTab(3) {
		t.Fatal("CloseTab")
	}
	if !tabs.OpenTab(3, "App") {
		t.Fatal("reopen")
	}
	if got := railBadgeCount(3); got != 0 {
		t.Fatalf("reused id inherited %d stale rows", got)
	}
	// Focus clears exactly the focused tab's badge.
	if !tabs.FocusTab(4) {
		t.Fatal("FocusTab")
	}
	if got := railBadgeCount(4); got != 0 {
		t.Fatalf("focus left badge %d want 0", got)
	}
	if got := railBadgeCount(3); got != 0 {
		t.Fatalf("focus on 4 changed 3's badge to %d", got)
	}
	// A dismissed row stops counting without a focus event.
	notifyCenterPush(4, "three")
	if got := railBadgeCount(4); got != 1 {
		t.Fatalf("badge after push = %d want 1", got)
	}
	for i := range notifyCenter {
		if notifyCenter[i].tabID == 4 && notifyCenter[i].text == "three" {
			dismissNotifyCenter(i)
		}
	}
	if got := railBadgeCount(4); got != 0 {
		t.Fatalf("dismissed row still badges: %d", got)
	}
	// A dead tab's badge is zero — its rows survive in the center but
	// count nothing.
	notifyCenterPush(4, "four")
	_ = tabs.CloseTab(4)
	if got := railBadgeCount(4); got != 0 {
		t.Fatalf("dead tab badges %d", got)
	}
}

func TestRailMenuOpenRightPressOnCell(t *testing.T) {
	defer railMenuFixture(t, 3, 4)()
	// Right press on cell 1 (id 4) opens the menu targeting it — not the
	// focused cell (id 3).
	if !tabs.FocusTab(3) {
		t.Fatal("FocusTab")
	}
	down := uint32(960) | uint32(10)<<16
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: down, Flags: uint16(hidBtnRight)})
	if !railMenuOpen || railMenuTab != 4 {
		t.Fatalf("right press: open=%v tab=%d want open on 4", railMenuOpen, railMenuTab)
	}
	// The release is consumed whole — no content forward, no drag arm.
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: down, Flags: 0})
	if railDragFrom != -1 {
		t.Fatalf("right press armed a drag: %d", railDragFrom)
	}
	// Retarget on the other cell reprints open with its id.
	down0 := uint32(320) | uint32(10)<<16
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: down0, Flags: uint16(hidBtnRight)})
	if railMenuTab != 3 {
		t.Fatalf("retarget left tab=%d want 3", railMenuTab)
	}
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: down0, Flags: 0})
	// A left press outside the menu dismisses it.
	outside := uint32(640) | uint32(vi.ScanoutHeight-40)<<16
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: outside, Flags: uint16(hidBtnLeft)})
	if railMenuOpen {
		t.Fatal("outside press must dismiss the menu")
	}
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: outside, Flags: 0})
}

func TestRailMenuQuitKillsTargetCell(t *testing.T) {
	defer railMenuFixture(t, 3, 4)()
	closed := []uint32{}
	prevClose, prevRaise := closeWin, focusRaise
	closeWin = func(id uint32) int64 {
		closed = append(closed, id)
		return 0
	}
	focusRaise = func(id uint32) int64 { return 0 }
	defer func() { closeWin, focusRaise = prevClose, prevRaise }()
	if !tabs.FocusTab(3) {
		t.Fatal("FocusTab")
	}
	openRailMenu(1) // cell 1 = id 4, the UNFOCUSED cell
	// Quit is the last row; its rect is the menu's bottom band.
	x, y, w, h := railMenuRect(vi.ScanoutWidth, vi.ScanoutHeight)
	if w == 0 {
		t.Fatal("open menu has no rect")
	}
	row := railMenuRowAt(uint32(x+10), uint32(y+h-railMenuPadY-1), vi.ScanoutWidth, vi.ScanoutHeight)
	if row != railActQuit {
		t.Fatalf("bottom row = %d want %d (Quit)", row, railActQuit)
	}
	applyRailMenuPick(row)
	if len(closed) != 1 || closed[0] != 4 {
		t.Fatalf("quit closed %v want [4]", closed)
	}
	if tabs.Count() != 1 || tabs.At(0).ID != 3 {
		t.Fatalf("strip after quit: n=%d id=%d want 1 tab id 3", tabs.Count(), tabs.At(0).ID)
	}
	if railMenuOpen {
		t.Fatal("pick must dismiss the menu")
	}
	if id, _ := tabs.Focused(); id != 3 {
		t.Fatalf("focus after quitting an unfocused tab = %d want 3", id)
	}
}

func TestRailMenuPinDuplicateFocusVerbs(t *testing.T) {
	defer railMenuFixture(t, 3, 4)()
	prevRaise := focusRaise
	focusRaise = func(id uint32) int64 { return 0 }
	execs, restoreExec := execRecorder()
	defer func() { focusRaise = prevRaise; restoreExec() }()
	if !tabs.FocusTab(3) {
		t.Fatal("FocusTab")
	}
	railMenuTab = 4 // the menu targets the unfocused cell
	// Pin row pins THE TARGET, not the focused tab — and flips to Unpin.
	railMenuPinToggle(4)
	if !tabs.At(0).Pinned || tabs.At(0).ID != 4 {
		t.Fatalf("pin did not jump the target left: %+v", tabs.At(0))
	}
	if railMenuLabel(railActPin) != "Unpin" {
		t.Fatalf("pin row label = %q want Unpin", railMenuLabel(railActPin))
	}
	railMenuPinToggle(4)
	if tabs.At(0).Pinned {
		t.Fatal("unpin must clear the bit")
	}
	// Duplicate re-execs the target's bin — "App" -> binToken "App".
	// Use a named title so the bin is a real executable name.
	tabs.CloseTab(4)
	tabs.OpenTab(5, "Edit")
	railMenuDuplicate(5)
	if len(*execs) != 1 || (*execs)[0] != "GOEDIT.ELF" {
		t.Fatalf("duplicate execs = %v want [GOEDIT.ELF]", *execs)
	}
	// Focus runs the seam even on the already-focused tab (the re-focus
	// is what clears its badge). The seam var records the ask; the stub
	// plays the kernel's half of the focus landing.
	prevRailFocus := railMenuFocus
	railMenuFocus = func(id uint32) bool { return tabs.FocusTab(id) }
	defer func() { railMenuFocus = prevRailFocus }()
	notifyCenterPush(3, "unread")
	if railBadgeCount(3) != 1 {
		t.Fatal("badge did not count the push")
	}
	railMenuFocusTab(3)
	if railBadgeCount(3) != 0 {
		t.Fatal("Focus row did not clear the focused tab's badge")
	}
}

func TestRailMenuKeyHandling(t *testing.T) {
	defer railMenuFixture(t, 3, 4)()
	prevRaise := focusRaise
	focusRaise = func(id uint32) int64 { return 0 }
	defer func() { focusRaise = prevRaise }()
	openRailMenu(0)
	if !handleRailMenuKey(vi.Event{Arg0: 0x51}) || railMenuSel != 1 {
		t.Fatalf("down moved sel to %d want 1", railMenuSel)
	}
	// Keys are consumed while open even when they change nothing.
	if !handleRailMenuKey(vi.Event{Arg0: 0x29}) || railMenuOpen {
		t.Fatal("Esc must consume and dismiss")
	}
	if handleRailMenuKey(vi.Event{Arg0: 0x28}) {
		t.Fatal("closed menu must not consume Enter")
	}
}

func TestRailMenuRectTracksItsTab(t *testing.T) {
	defer railMenuFixture(t, 3, 4)()
	railMenuTab = 4
	x0, y, w, h := railMenuRect(1280, 720)
	if x0 != 640 || w != railMenuW || y < RailHeight {
		t.Fatalf("rect = %d,%d %dx%d want x=640 w=%d", x0, y, w, h, railMenuW)
	}
	// A reorder moves the anchor with the tab, not the cell slot.
	if !tabs.Reorder(1, 0) {
		t.Fatal("Reorder")
	}
	x1, _, _, _ := railMenuRect(1280, 720)
	if x1 != chromeInset {
		t.Fatalf("menu did not track the reordered tab: x=%d want %d", x1, chromeInset)
	}
	// The target leaving the strip zeroes the rect.
	_ = tabs.CloseTab(4)
	if _, _, w2, _ := railMenuRect(1280, 720); w2 != 0 {
		t.Fatal("dead target still has a menu rect")
	}
}

func TestRailNotifPlateGeometry(t *testing.T) {
	// The badge sits inside the cell's left band, clear of the close
	// zone, and drops entirely on a cell too narrow for it.
	r, ok := railNotifPlate(0, 640, RailHeight)
	if !ok || r.X <= 4 || r.H != railNotifH || r.Y+r.H > RailHeight {
		t.Fatalf("plate = %+v ok=%v", r, ok)
	}
	if r.X+r.W > 640-railCloseW {
		t.Fatalf("plate intrudes into the close zone: right=%d", r.X+r.W)
	}
	if _, ok := railNotifPlate(0, 20, RailHeight); ok {
		t.Fatal("a 20px cell must not carry the badge")
	}
	if _, ok := railNotifPlate(0, 640, 10); ok {
		t.Fatal("a 10px strip must not carry the badge")
	}
}
