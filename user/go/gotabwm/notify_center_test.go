package main

import (
	"testing"

	"virelai/theme"
	"virelai/vi"
)

func TestNotifyCenterKeepsHistoryAfterToastExpires(t *testing.T) {
	resetNotify(t)
	notifyPush(7, "saved report", 10)
	notifyTick(10 + NotifyTicks)
	if notifyCount() != 0 {
		t.Fatalf("toast queue depth=%d after expiry, want 0", notifyCount())
	}
	if len(notifyCenter) != 1 || notifyCenter[0].text != "saved report" {
		t.Fatalf("center history=%+v, want the expired notification retained", notifyCenter)
	}
}

func TestNotifyCenterMarksDeadSourcesAndDoesNotRelinkReusedIDs(t *testing.T) {
	resetNotify(t)
	oldTabs := tabs
	t.Cleanup(func() { tabs = oldTabs })
	tabs = TabStrip{}
	tabs.OpenTab(7, "Files")
	notifyPush(7, "copied item", 0)
	if got := notifyCenter[0].source; got != "Files" {
		t.Fatalf("captured source=%q, want Files", got)
	}
	tabs.CloseTab(7)
	if !notifyCenter[0].sourceGone {
		t.Fatal("closed source was not latched as gone")
	}
	tabs.OpenTab(7, "Unrelated app")
	if !notifyCenter[0].sourceGone {
		t.Fatal("a reused window id relinked a historical notification")
	}
}

func TestNotifyCenterDismissAndClearRemoveMatchingToasts(t *testing.T) {
	resetNotify(t)
	notifyPush(4, "first", 0)
	notifyPush(5, "second", 0)
	if !dismissNotifyCenterEntry(0) {
		t.Fatal("dismiss of first history item failed")
	}
	if len(notifyCenter) != 1 || notifyCenter[0].text != "second" {
		t.Fatalf("history after dismiss=%+v, want second item only", notifyCenter)
	}
	if len(notifyQueue) != 1 || notifyQueue[0].text != "second" {
		t.Fatalf("toast queue after dismiss=%+v, want second toast only", notifyQueue)
	}
	if got := clearNotifyCenter(); got != 1 {
		t.Fatalf("clear all removed %d history entries, want 1", got)
	}
	if len(notifyCenter) != 0 || len(notifyQueue) != 0 {
		t.Fatalf("clear all left history=%d toasts=%d", len(notifyCenter), len(notifyQueue))
	}
}

func TestNotifyCenterBoundKeepsNewestHistory(t *testing.T) {
	resetNotify(t)
	for i := 0; i < NotifyCenterMax+2; i++ {
		notifyPush(uint32(i+1), "item", uint64(i))
	}
	if len(notifyCenter) != NotifyCenterMax {
		t.Fatalf("history depth=%d, want %d", len(notifyCenter), NotifyCenterMax)
	}
	if got := notifyCenter[0].tabID; got != 3 {
		t.Fatalf("oldest retained sender=%d, want 3", got)
	}
	if got := notifyCenter[NotifyCenterMax-1].tabID; got != NotifyCenterMax+2 {
		t.Fatalf("newest sender=%d, want %d", got, NotifyCenterMax+2)
	}
}

func TestNotifyCenterPaintIsBoundedAndPaintMarkerFollowsPresentation(t *testing.T) {
	resetNotify(t)
	notifyPush(4, "center test", 0)
	notifyCenterOpen = true
	const w, h = 800, 600
	scan := make([]byte, w*h*4)
	for i := 0; i < len(scan)/4; i++ {
		asUint32(scan)[i] = theme.Light.Success
	}
	if paintNotifyCenter(scan, w, h) == 0 {
		t.Fatal("open center painted no pixels")
	}
	pix := asUint32(scan)
	x, y, rw, rh := notifyCenterRect(w, h)
	for py := 0; py < h; py++ {
		for px := 0; px < w; px++ {
			in := px >= x && px < x+rw && py >= y && py < y+rh
			// The §2.5 drop shadow darkens a falloff band around the
			// panel (blur 16, dy 4) — bound it, then hold the rest of the
			// scanout to the sentinel.
			inShadow := px >= x-16 && px < x+rw+16 && py >= y-16 && py < y+rh+20
			if !in && !inShadow && pix[py*w+px] != theme.Light.Success {
				t.Fatalf("center painted outside its panel and shadow at (%d,%d)", px, py)
			}
		}
	}
	if line, ok := notifyCenterPaintMarker(true, false); ok || line != "" {
		t.Fatalf("unpresented center emitted marker %q,%v", line, ok)
	}
	if line, ok := notifyCenterPaintMarker(true, true); !ok || line != MarkerNotifyCenterPaint {
		t.Fatalf("presented center marker=%q,%v", line, ok)
	}
	if _, ok := notifyCenterPaintMarker(true, true); ok {
		t.Fatal("center paint marker repeated")
	}
}

func TestNotifyCenterClockClickOpensAndOutsideClickCloses(t *testing.T) {
	resetNotify(t)
	x, y, w, h := chromeRect(vi.ScanoutWidth, vi.ScanoutHeight)
	if !notifyCenterClick(uint32(x+w/2), uint32(y+h/2)) || !notifyCenterOpen {
		t.Fatal("clock-panel click did not open the center")
	}
	if !notifyCenterClick(0, 0) || notifyCenterOpen {
		t.Fatal("outside click did not close the center")
	}
}

func TestNotifyCenterMotionDoesNotReachContent(t *testing.T) {
	resetNotify(t)
	savedTabs := tabs
	savedForward := forwardContentPointer
	savedButtons := prevPtrButtons
	savedDrag := railDragFrom
	savedHover := railHover
	savedSash := sashDragging
	savedContent := contentDown
	savedLaunch := launch
	t.Cleanup(func() {
		tabs = savedTabs
		forwardContentPointer = savedForward
		prevPtrButtons = savedButtons
		railDragFrom = savedDrag
		railHover = savedHover
		sashDragging = savedSash
		contentDown = savedContent
		launch = savedLaunch
	})
	tabs = TabStrip{}
	notifyCenterOpen = true
	prevPtrButtons = 0
	railDragFrom = -1
	railHover = -1
	sashDragging = false
	contentDown = false
	launch = launcherState{}
	forwarded := 0
	forwardContentPointer = func(uint32, uint32, uint8, uint8) int64 {
		forwarded++
		return 0
	}

	x, y, w, h := notifyCenterRect(vi.ScanoutWidth, vi.ScanoutHeight)
	center := uint32(x+w/2) | uint32(y+h/2)<<16
	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: center})
	if forwarded != 0 {
		t.Fatalf("motion over the open center forwarded %d content samples", forwarded)
	}
	if !notifyCenterOpen {
		t.Fatal("pointer motion closed the notification center")
	}

	handleWmPointer(vi.Event{Kind: vi.EvWmPointer, Arg0: 0})
	if forwarded != 1 {
		t.Fatalf("motion outside the center forwarded %d content samples, want 1", forwarded)
	}
}

func TestNotifyCenterRowDismissAndClearAllControls(t *testing.T) {
	resetNotify(t)
	notifyPush(4, "first", 0)
	notifyPush(5, "second", 0)
	notifyCenterOpen = true
	x, y, w, _ := notifyCenterRect(vi.ScanoutWidth, vi.ScanoutHeight)
	// Row one's X is the trailing 34px of the row, distinct from its focus
	// area. Dismissing it removes the corresponding toast and no other item.
	if !notifyCenterClick(uint32(x+w-10), uint32(y+notifyHeaderH+notifyRowH/2)) {
		t.Fatal("row dismiss click was not consumed")
	}
	if len(notifyCenter) != 1 || notifyCenter[0].text != "second" ||
		len(notifyQueue) != 1 || notifyQueue[0].text != "second" {
		t.Fatalf("row dismiss left history=%+v queue=%+v", notifyCenter, notifyQueue)
	}
	// Footer's left-side action clears every remaining history item and toast.
	if !notifyCenterClick(uint32(x+notifyCenterPad+4),
		uint32(y+notifyCenterH-notifyFooterH+notifyFooterH/2)) {
		t.Fatal("clear-all click was not consumed")
	}
	if len(notifyCenter) != 0 || len(notifyQueue) != 0 {
		t.Fatalf("clear all left history=%d queue=%d", len(notifyCenter), len(notifyQueue))
	}
}

func TestNotifyCenterFocusFailureLatchesClosedSource(t *testing.T) {
	resetNotify(t)
	oldTabs := tabs
	t.Cleanup(func() { tabs = oldTabs })
	tabs = TabStrip{}
	tabs.OpenTab(9, "Report")
	notifyPush(9, "finished", 0)
	notifyCenterOpen = true
	calls := 0
	focusNotifySource = func(uint32) bool {
		calls++
		return false
	}
	x, y, _, _ := notifyCenterRect(vi.ScanoutWidth, vi.ScanoutHeight)
	rowX := x + notifyCenterPad + 8
	rowY := y + notifyHeaderH + notifyRowH/2
	notifyCenterClick(uint32(rowX), uint32(rowY))
	if !notifyCenter[0].sourceGone || calls != 1 {
		t.Fatalf("failed focus did not latch closed state: gone=%v calls=%d",
			notifyCenter[0].sourceGone, calls)
	}
	notifyCenterClick(uint32(rowX), uint32(rowY))
	if calls != 1 {
		t.Fatalf("center retried a dead source focus %d times", calls)
	}
}
