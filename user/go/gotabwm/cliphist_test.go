// M190a (#3236): the clipboard-history ring and the paste menu's host
// half. The ring is a bounded typed store with move-to-front dedupe and
// FIFO evict; the poll observes the kernel buffer through the lane's own
// slot-39 seam; the menu snapshots at open and delivers through the
// typed write + the content-key forward.
package main

import (
	"testing"

	"virelai/vi"
	"virelai/vsys"
)

// clipHistReset clears the ring and its poll baseline.
func clipHistReset(t *testing.T) {
	t.Helper()
	clipHist = [clipHistMax]clipEntry{}
	clipHistN = 0
	clipHistSeen, clipHistHash, clipHistLen = false, 0, 0
}

// stubClipGet swaps the lane's slot-39 seam for a scripted buffer —
// hostClipGet is the single read path both the lane and the ring share.
func stubClipGet(t *testing.T, contents *[]byte) {
	t.Helper()
	old := hostClipGet
	hostClipGet = func(buf []byte) (int, int64) {
		if buf == nil || len(buf) == 0 {
			return 0, 0
		}
		n := copy(buf, *contents)
		return n, 0
	}
	t.Cleanup(func() { hostClipGet = old })
}

func TestClipHistPushBoundAndOrder(t *testing.T) {
	defer saveSeatState()()
	clipHistReset(t)
	for i := 0; i < clipHistMax+3; i++ {
		cliphistPush([]byte{byte('a' + i%26), byte('0' + i)})
	}
	if clipHistN != clipHistMax {
		t.Fatalf("clipHistN = %d want %d", clipHistN, clipHistMax)
	}
	// Newest at head, the three oldest evicted — FIFO.
	if clipHist[0].blob[1] != byte('0'+18) || clipHist[clipHistMax-1].blob[1] != byte('0'+3) {
		t.Fatalf("head/tail = %q/%q want newest/oldest of the last %d",
			clipHist[0].blob, clipHist[clipHistMax-1].blob, clipHistMax)
	}
}

func TestClipHistPushMimeHonest(t *testing.T) {
	defer saveSeatState()()
	clipHistReset(t)
	cliphistPush([]byte("plain text"))
	cliphistPush([]byte("<html><body>x</body></html>"))
	if clipHist[0].mime != vsys.ClipHTML || clipHist[1].mime != vsys.ClipText {
		t.Fatalf("mimes = %q,%q want html,text", clipHist[0].mime, clipHist[1].mime)
	}
}

func TestClipHistDedupeMoveToFront(t *testing.T) {
	defer saveSeatState()()
	clipHistReset(t)
	cliphistPush([]byte("aaa"))
	cliphistPush([]byte("bbb"))
	cliphistPush([]byte("aaa"))
	if clipHistN != 2 {
		t.Fatalf("clipHistN = %d want 2 — re-copy refreshes, never forks", clipHistN)
	}
	if string(clipHist[0].blob) != "aaa" || string(clipHist[1].blob) != "bbb" {
		t.Fatalf("order = %q,%q want aaa,bbb", clipHist[0].blob, clipHist[1].blob)
	}
}

func TestClipHistPollObserves(t *testing.T) {
	defer saveSeatState()()
	clipHistReset(t)
	var buf []byte
	stubClipGet(t, &buf)
	// An empty buffer is a state, not a clip.
	cliphistPoll()
	if clipHistN != 0 {
		t.Fatal("empty buffer must not enter the ring")
	}
	buf = []byte("first")
	cliphistPoll()
	buf = []byte("second")
	cliphistPoll()
	if clipHistN != 2 || string(clipHist[0].blob) != "second" || string(clipHist[1].blob) != "first" {
		t.Fatalf("ring = %+v", clipHist[:clipHistN])
	}
	// An unchanged buffer is not re-observed.
	cliphistPoll()
	if clipHistN != 2 {
		t.Fatal("unchanged buffer re-pushed")
	}
	// A buffer change mid-history lands at the head.
	buf = []byte("first")
	cliphistPoll()
	if clipHistN != 2 || string(clipHist[0].blob) != "first" {
		t.Fatalf("re-copy did not move to head: %+v", clipHist[:clipHistN])
	}
}

func TestClipHistNoteIsEchoGuarded(t *testing.T) {
	defer saveSeatState()()
	clipHistReset(t)
	var buf []byte
	stubClipGet(t, &buf)
	// A CLIP_IN apply notes the write and syncs the baseline — the very
	// same bytes must not re-observe on the next poll.
	buf = []byte("host text")
	cliphistNote(buf)
	cliphistPoll()
	if clipHistN != 1 {
		t.Fatalf("echo guard failed: clipHistN = %d want 1", clipHistN)
	}
}

func TestClipHistNeverSeesPrimary(t *testing.T) {
	defer saveSeatState()()
	clipHistReset(t)
	// serveSelPublish writes primSel through seat memory + staging files
	// — never slots 38/39. Stub the staging seams and prove the ring
	// stays empty through a whole publish.
	oldRead, oldDel, oldLog := selFileRead, selFileDelete, selLog
	selFileRead = func(string, int) ([]byte, int64) {
		enc, _ := vi.EncodeSel([]byte("primary text"))
		return enc, 0
	}
	selFileDelete = func(string) int64 { return 0 }
	selLog = func(string) {}
	defer func() { selFileRead, selFileDelete, selLog = oldRead, oldDel, oldLog }()
	tabs = TabStrip{}
	if !tabs.OpenTab(9, "GOEDIT.ELF") {
		t.Fatal("OpenTab")
	}
	oldApps := readAppsFile
	readAppsFile = func(string, int) ([]byte, int64) {
		return []byte("GOEDIT.ELF | Code Editor | e | dock=true | v=2 | selection=primary\n"), 0
	}
	defer func() { readAppsFile = oldApps }()
	if !serveSelPublish(vi.WmRpc{ID: 9}) {
		t.Fatal("publish refused")
	}
	if !primSelSet {
		t.Fatal("primary buffer not set")
	}
	if clipHistN != 0 {
		t.Fatalf("primary publish entered the ring: %+v", clipHist[:clipHistN])
	}
}

// --- the paste menu ----------------------------------------------------

// clipMenuSave preserves menu + ring state across a test.
func clipMenuSave(t *testing.T) {
	t.Helper()
	savedMenu := [4]any{clipMenuOpen, clipMenuSel, clipMenuSink, clipMenuPrior}
	savedRows := clipMenuRows
	savedList := clipMenuList
	clipHistReset(t)
	t.Cleanup(func() {
		clipMenuOpen, clipMenuSel, clipMenuSink, clipMenuPrior =
			savedMenu[0].(bool), savedMenu[1].(int), savedMenu[2].(uint32), savedMenu[3].(uint32)
		clipMenuRows = savedRows
		clipMenuList = savedList
	})
}

// stubMenuWindows swaps the sink seams for inert recorders.
func stubMenuWindows(t *testing.T) {
	t.Helper()
	oldOpen, oldQuery, oldClose, oldRaise := openInputSink, queryWindow, closeWin, focusRaise
	openInputSink = func(uint32, uint32, uint32, uint32) (int, int64) { return 91, 0 }
	queryWindow = func(int) ([8]uint32, int64) { return [8]uint32{}, 0 }
	closeWin = func(uint32) int64 { return 0 }
	focusRaise = func(uint32) int64 { return 0 }
	t.Cleanup(func() {
		openInputSink, queryWindow, closeWin, focusRaise = oldOpen, oldQuery, oldClose, oldRaise
	})
}

func TestClipMenuOpenEmpty(t *testing.T) {
	defer saveSeatState()()
	clipMenuSave(t)
	stubMenuWindows(t)
	clipHistReset(t)
	var buf []byte
	stubClipGet(t, &buf)
	applyClipMenu()
	if clipMenuOpen {
		t.Fatal("empty ring opened a menu")
	}
}

func TestClipMenuKeysAndPick(t *testing.T) {
	defer saveSeatState()()
	clipMenuSave(t)
	stubMenuWindows(t)
	clipHistReset(t)
	var buf []byte
	stubClipGet(t, &buf)
	buf = []byte("alpha")
	cliphistPoll()
	buf = []byte("bravo")
	cliphistPoll()
	tabs = TabStrip{}
	if !tabs.OpenTab(9, "GOEDIT.ELF") {
		t.Fatal("OpenTab")
	}
	if !tabs.FocusTab(9) {
		t.Fatal("FocusTab")
	}
	var wroteMime string
	var wroteBlob []byte
	oldSet := clipMenuSetTyped
	clipMenuSetTyped = func(mime string, blob []byte) (int, int64) {
		wroteMime, wroteBlob = mime, append([]byte(nil), blob...)
		return len(blob), 0
	}
	defer func() { clipMenuSetTyped = oldSet }()
	var fwdUsage uint8
	var fwdFlags uint16
	oldFwd := forwardContentKey
	forwardContentKey = func(u uint8, f uint16) int64 {
		fwdUsage, fwdFlags = u, f
		return 0
	}
	defer func() { forwardContentKey = oldFwd }()
	var raised uint32
	oldRaise := focusRaise
	focusRaise = func(id uint32) int64 { raised = id; return 0 }
	defer func() { focusRaise = oldRaise }()

	applyClipMenu()
	if !clipMenuOpen || clipMenuRows != 2 {
		t.Fatalf("menu did not open with the ring: open=%v rows=%d", clipMenuOpen, clipMenuRows)
	}
	// Down selects the OLDER clip (ring order is newest-first).
	handleClipMenuKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x51})
	handleClipMenuKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x51}) // clamped
	if clipMenuSel != 1 {
		t.Fatalf("sel = %d want 1", clipMenuSel)
	}
	handleClipMenuKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x28}) // Enter
	if clipMenuOpen {
		t.Fatal("Enter left the menu open")
	}
	if wroteMime != vsys.ClipText || string(wroteBlob) != "alpha" {
		t.Fatalf("typed write = %q %q want text/plain alpha", wroteMime, wroteBlob)
	}
	if fwdUsage != hidUsageV || fwdFlags != vi.ModCtrl {
		t.Fatalf("forward = usage %#x flags %#x want ctrl+v", fwdUsage, fwdFlags)
	}
	if raised != 9 {
		t.Fatalf("focusRaise = %d want 9", raised)
	}
	// The pick rides forward as the head of history.
	if clipHistN == 0 || string(clipHist[0].blob) != "alpha" {
		t.Fatalf("pick not at head: %+v", clipHist[:clipHistN])
	}
}

func TestClipMenuEscDismisses(t *testing.T) {
	defer saveSeatState()()
	clipMenuSave(t)
	stubMenuWindows(t)
	clipHistReset(t)
	var buf []byte
	stubClipGet(t, &buf)
	buf = []byte("x")
	cliphistPoll()
	applyClipMenu()
	if !clipMenuOpen {
		t.Fatal("menu did not open")
	}
	if !handleClipMenuKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x29}) || clipMenuOpen {
		t.Fatal("Esc did not dismiss")
	}
}

func TestClipMenuKeyGate(t *testing.T) {
	defer saveSeatState()()
	clipMenuSave(t)
	clipMenuOpen = false
	if handleClipMenuKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x28}) {
		t.Fatal("closed menu swallowed a key")
	}
	// While open, every key — including seat chords — is the menu's.
	clipMenuOpen = true
	clipMenuRows = 1
	if !handleClipMenuKey(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl | vi.ModShift, Arg0: 0x13}) {
		t.Fatal("open menu let a chord fall through")
	}
}
