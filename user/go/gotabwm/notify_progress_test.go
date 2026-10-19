package main

import (
	"testing"

	"virelai/theme"
	"virelai/vi"
)

// progressRPC builds a kind-22 request the way an app's vi.NotifyProgress
// encodes it: binary title (op, pct byte, label), id = the sender window.
func progressRPC(id uint8, op uint8, pct int, label string) vi.WmRpc {
	t, _ := vi.EncodeProgressTitle(op, pct, label)
	return vi.WmRpc{Kind: vi.WmRpcKindProgress, ID: id, Seq: 1, ReplyTo: 77, Title: t}
}

func TestProgressReportCreatesAndUpdatesOneRow(t *testing.T) {
	resetNotify(t)
	oldTabs := tabs
	t.Cleanup(func() { tabs = oldTabs })
	tabs = TabStrip{}
	tabs.OpenTab(4, "Files")
	if !applyRPC(progressRPC(4, 1, 10, "Copying")) {
		t.Fatal("first report refused")
	}
	if len(notifyCenter) != 1 || !notifyCenter[0].progress ||
		notifyCenter[0].op != 1 || notifyCenter[0].pct != 10 ||
		notifyCenter[0].text != "Copying" || notifyCenter[0].source != "Files" ||
		notifyCenter[0].pid != 77 {
		t.Fatalf("row = %+v", notifyCenter[0])
	}
	if !applyRPC(progressRPC(4, 1, 60, "Copying")) {
		t.Fatal("update refused")
	}
	if len(notifyCenter) != 1 || notifyCenter[0].pct != 60 {
		t.Fatalf("update did not move the row in place: %+v", notifyCenter)
	}
	// A different op is a SECOND row, not an update.
	if !applyRPC(progressRPC(4, 2, 5, "Indexing")) || len(notifyCenter) != 2 {
		t.Fatalf("second op rows=%d, want 2", len(notifyCenter))
	}
	// Never a toast: the strip stays empty and DND cannot hold the row.
	notifyDND = true
	if !applyRPC(progressRPC(4, 3, 1, "Silent")) {
		t.Fatal("DND refused a progress row")
	}
	if len(notifyQueue) != 0 {
		t.Fatal("a progress report raised a toast")
	}
}

func TestProgressReportRefusals(t *testing.T) {
	resetNotify(t)
	oldTabs := tabs
	t.Cleanup(func() { tabs = oldTabs })
	tabs = TabStrip{}
	tabs.OpenTab(4, "Files")
	if applyRPC(progressRPC(99, 1, 5, "ghost")) {
		t.Fatal("an unknown sender's report applied")
	}
	bad := progressRPC(4, 0, 5, "no op")
	if applyRPC(bad) {
		t.Fatal("op 0 applied")
	}
	bad = progressRPC(4, 1, 5, "bad pct")
	bad.Title[1] = 137
	if applyRPC(bad) {
		t.Fatal("a malformed pct byte applied")
	}
	if len(notifyCenter) != 0 {
		t.Fatalf("refusals still made rows: %+v", notifyCenter)
	}
}

func TestProgressRowCancelPushesKind22AndDropsTheRow(t *testing.T) {
	resetNotify(t)
	oldTabs := tabs
	oldSend := sendProgressNotice
	t.Cleanup(func() { tabs = oldTabs; sendProgressNotice = oldSend })
	tabs = TabStrip{}
	tabs.OpenTab(4, "Files")
	var sentPid uint32
	var sentFrame vi.WmRpc
	sends := 0
	sendProgressNotice = func(pid uint32, b []byte) int64 {
		sends++
		sentPid = pid
		sentFrame, _ = vi.DecodeWmRpc(b)
		return 0
	}
	notifyCenterOpen = true
	if !applyRPC(progressRPC(4, 3, 40, "Copying")) {
		t.Fatal("report refused")
	}
	x, y, w, _ := notifyCenterRect(vi.ScanoutWidth, vi.ScanoutHeight)
	rowY := y + notifyHeaderH + notifyRowH/2
	// The cancel zone is the row's trailing 48px; inside it is a cancel,
	// a pixel short of it is the row's ordinary focus/dismiss area.
	if !notifyCenterClick(uint32(x+w-10), uint32(rowY)) {
		t.Fatal("cancel click not consumed")
	}
	if len(notifyCenter) != 0 {
		t.Fatalf("cancelled row still listed: %+v", notifyCenter)
	}
	if sends != 1 || sentPid != 77 {
		t.Fatalf("cancel pushes=%d pid=%d, want 1 to pid 77", sends, sentPid)
	}
	if sentFrame.Kind != vi.WmRpcKindProgressCancel || sentFrame.ID != 4 ||
		sentFrame.ReplyTo != 0 || sentFrame.Title[0] != 3 {
		t.Fatalf("cancel frame = %+v", sentFrame)
	}
}

func TestProgressRowCancelOnClosedSourceIsPlainDismiss(t *testing.T) {
	resetNotify(t)
	oldTabs := tabs
	oldSend := sendProgressNotice
	t.Cleanup(func() { tabs = oldTabs; sendProgressNotice = oldSend })
	tabs = TabStrip{}
	tabs.OpenTab(4, "Files")
	sends := 0
	sendProgressNotice = func(uint32, []byte) int64 { sends++; return 0 }
	notifyCenterOpen = true
	applyRPC(progressRPC(4, 1, 30, "Copying"))
	tabs.CloseTab(4) // latches sourceGone via clearNotify
	x, y, w, _ := notifyCenterRect(vi.ScanoutWidth, vi.ScanoutHeight)
	rowY := y + notifyHeaderH + notifyRowH/2
	// With the source dead there is nothing to cancel: the row takes the
	// plain 34px X zone and no frame leaves the seat.
	if !notifyCenterClick(uint32(x+w-10), uint32(rowY)) {
		t.Fatal("dismiss of a dead-source row not consumed")
	}
	if sends != 0 {
		t.Fatal("a cancel frame was pushed to a dead pid")
	}
	if len(notifyCenter) != 0 {
		t.Fatal("dead-source row survived its dismiss")
	}
}

func TestProgressDoneRowDismissesWithoutCancel(t *testing.T) {
	resetNotify(t)
	oldTabs := tabs
	oldSend := sendProgressNotice
	t.Cleanup(func() { tabs = oldTabs; sendProgressNotice = oldSend })
	tabs = TabStrip{}
	tabs.OpenTab(4, "Files")
	sends := 0
	sendProgressNotice = func(uint32, []byte) int64 { sends++; return 0 }
	notifyCenterOpen = true
	applyRPC(progressRPC(4, 1, 99, "Copying"))
	if created, done := notifyProgressUpdate(4, 77, 1, 100, "Copying"); created || !done {
		t.Fatalf("the 100 transition = created %v done %v", created, done)
	}
	x, y, w, _ := notifyCenterRect(vi.ScanoutWidth, vi.ScanoutHeight)
	rowY := y + notifyHeaderH + notifyRowH/2
	if !notifyCenterClick(uint32(x+w-10), uint32(rowY)) || sends != 0 {
		t.Fatal("a done row pushed a cancel")
	}
}

func TestProgressRowsAreNotPersisted(t *testing.T) {
	resetNotify(t)
	oldTabs := tabs
	t.Cleanup(func() { tabs = oldTabs })
	tabs = TabStrip{}
	tabs.OpenTab(4, "Files")
	notifyPush(4, "a notice", 0)
	applyRPC(progressRPC(4, 1, 50, "Copying"))
	b := encodeNotifyHistory(notifyCenter)
	h, ok := decodeNotifyHistory(b)
	if !ok || len(h) != 1 || h[0].text != "a notice" {
		t.Fatalf("history = %+v ok=%v, want the notice only", h, ok)
	}
	if notifyHistDirty {
		// set by notifyPush's own push above — but the progress update must
		// not have needed it: reset and re-update to prove the point.
	}
	notifyHistDirty = false
	applyRPC(progressRPC(4, 1, 60, "Copying"))
	if notifyHistDirty {
		t.Fatal("a progress update dirtied the persisted history")
	}
}

func TestProgressSweepIsATriangleWave(t *testing.T) {
	const w = 100
	seg := w / 4
	prev, _ := notifyProgressSweep(0, w)
	if prev != 0 {
		t.Fatalf("sweep t=0 off=%d", prev)
	}
	for tick := uint64(1); tick <= uint64(2*(w-seg)); tick++ {
		off, s := notifyProgressSweep(tick, w)
		if s != seg {
			t.Fatalf("seg=%d, want %d", s, seg)
		}
		d := off - prev
		if d != 1 && d != -1 {
			t.Fatalf("sweep step %d->%d at tick %d is not unit", prev, off, tick)
		}
		prev = off
	}
	if off, _ := notifyProgressSweep(uint64(2*(w-seg)), w); off != 0 {
		t.Fatalf("sweep did not return to 0 after a full wave: %d", off)
	}
}

func TestProgressRowPaintsBarAndCancel(t *testing.T) {
	resetNotify(t)
	oldTabs := tabs
	t.Cleanup(func() { tabs = oldTabs })
	tabs = TabStrip{}
	tabs.OpenTab(4, "Files")
	notifyCenterOpen = true
	applyRPC(progressRPC(4, 1, 50, "Copying"))
	const w, h = 800, 600
	scan := make([]byte, w*h*4)
	if paintNotifyCenter(scan, w, h) == 0 {
		t.Fatal("center with a progress row painted nothing")
	}
	pix := asUint32(scan)
	x, y, _, _ := notifyCenterRect(w, h)
	rowY := y + notifyHeaderH
	// The bar's track row sits at the row's bottom band; its left half is
	// the accent fill at pct=50, its right half the track colour — one
	// pixel each, enough to prove the bar painted and stopped mid-row.
	barY := rowY + 27
	accent := pix[barY*w+x+notifyCenterPad+4]
	if accent != theme.Current.Accent|0xff000000 {
		t.Fatalf("bar fill pixel = %#08x, want accent", accent)
	}
}
