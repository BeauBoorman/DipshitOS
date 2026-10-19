package main

import (
	"strings"
	"testing"

	"virelai/webrender"
)

func TestHistoryBackForward(t *testing.T) {
	h := newHistory()
	h.push(entry{Target: "/host/A.HTML"})
	h.push(entry{Target: "/host/B.HTML"})
	if !h.canBack() || h.canForward() {
		t.Fatal("expected back only")
	}
	e, ok := h.back()
	if !ok || e.Target != "/host/A.HTML" {
		t.Fatalf("back = %v %v", e, ok)
	}
	if h.canBack() {
		t.Fatal("no further back expected")
	}
	if !h.canForward() {
		t.Fatal("forward expected")
	}
	e, ok = h.forward()
	if !ok || e.Target != "/host/B.HTML" {
		t.Fatalf("forward = %v %v", e, ok)
	}
}

func TestHistoryTruncatesForwardTail(t *testing.T) {
	h := newHistory()
	h.push(entry{Target: "A"})
	h.push(entry{Target: "B"})
	h.push(entry{Target: "C"})
	h.back()
	h.back()
	if !h.canForward() {
		t.Fatal("forward expected after two backs")
	}
	h.push(entry{Target: "D"})
	if h.canForward() {
		t.Fatal("forward tail should be gone")
	}
	if h.len() != 2 {
		t.Fatalf("entries = %d want 2", h.len())
	}
	cur, _ := h.current()
	if cur.Target != "D" {
		t.Fatalf("current = %q", cur.Target)
	}
}

func TestHistoryDedupesConsecutiveSameTarget(t *testing.T) {
	h := newHistory()
	h.push(entry{Target: "A"})
	h.push(entry{Target: "A"})
	if h.len() != 1 {
		t.Fatalf("entries = %d want 1", h.len())
	}
	h.push(entry{Target: "A", Title: "Title"})
	cur, _ := h.current()
	if cur.Title != "Title" {
		t.Fatalf("title update lost: %+v", cur)
	}
}

func TestHistoryEmptyIsSafe(t *testing.T) {
	h := newHistory()
	if _, ok := h.back(); ok {
		t.Fatal("back on empty")
	}
	if _, ok := h.forward(); ok {
		t.Fatal("forward on empty")
	}
	if _, ok := h.current(); ok {
		t.Fatal("current on empty")
	}
	h.replace(entry{Target: "X"})
	if cur, ok := h.current(); !ok || cur.Target != "X" {
		t.Fatalf("replace on empty should push: %v %v", cur, ok)
	}
}

// The dropdown lists the newest-first tail, capped at the card's 20.
func TestHistoryRecentNewestFirstCapped(t *testing.T) {
	h := newHistory()
	for i := 0; i < 25; i++ {
		h.push(entry{Target: "/host/P" + itoa(i) + ".HTML"})
	}
	rows := h.recent(histMenuMax)
	if len(rows) != 20 || rows[0].Target != "/host/P24.HTML" || rows[19].Target != "/host/P5.HTML" {
		t.Fatalf("recent rows wrong: %d first=%v last=%v", len(rows), rows[0], rows[19])
	}
	if h.cursorRow() != 0 {
		t.Fatalf("cursor row = %d want 0", h.cursorRow())
	}
	if _, ok := h.back(); !ok {
		t.Fatal("back on full stack")
	}
	if h.cursorRow() != 1 {
		t.Fatalf("cursor row after back = %d want 1", h.cursorRow())
	}
}

// The dropdown geometry: the plate hangs under the URL row and at the
// native canvas all 20 rows land above the status line.
func TestHistoryMenuGeometry(t *testing.T) {
	a := &app{hist: newHistory()}
	if got := a.histMenuRows(); got != histMenuMax {
		t.Fatalf("visible rows = %d want %d", got, histMenuMax)
	}
	if histMenuY+histRowH*histMenuMax > winH-statusH {
		t.Fatal("a full menu overlaps the status line")
	}
	if histMenuY != urlRowY+urlRowH {
		t.Fatal("menu must hang directly under the URL row")
	}
	if actX(winW) <= urlX || actX(winW)+chipW > winW-6 {
		t.Fatal("action chip collides with the URL field or escapes the window")
	}
	for i := 0; i < 3; i++ {
		a.hist.push(entry{Target: "/host/P" + itoa(i) + ".HTML"})
	}
	if i, ok := a.histMenuHit(100, histMenuY); !ok || i != 0 {
		t.Fatalf("first row hit = %d %v", i, ok)
	}
	if i, ok := a.histMenuHit(100, histMenuY+2*histRowH+1); !ok || i != 2 {
		t.Fatalf("third row hit = %d %v", i, ok)
	}
	if _, ok := a.histMenuHit(100, histMenuY-1); ok {
		t.Fatal("URL row hit the menu")
	}
	if _, ok := a.histMenuHit(histMenuX-1, histMenuY); ok {
		t.Fatal("left of the plate hit the menu")
	}
	if _, ok := a.histMenuHit(100, histMenuY+4*histRowH); ok {
		t.Fatal("past the last row hit the menu")
	}
}

// Picking a row is a fresh visit: it pushes, truncating the forward tail.
func TestHistoryMenuPickIsAFreshVisit(t *testing.T) {
	a := &app{hist: newHistory(), text: webrender.Bitmap{}}
	a.hist.push(entry{Target: "/host/A.HTML"})
	a.hist.push(entry{Target: "/host/B.HTML"})
	a.hist.back() // cursor on A, B is the forward tail
	a.histOpen = true
	a.pickHistory(0) // row 0 = B (newest-first: [B, A])
	if a.histOpen {
		t.Fatal("menu stayed open after a pick")
	}
	if a.target != "/host/B.HTML" {
		t.Fatalf("pick navigated to %q", a.target)
	}
	if a.hist.canForward() {
		t.Fatal("a pick must truncate the forward tail")
	}
	cur, _ := a.hist.current()
	if a.hist.len() != 2 || cur.Target != "/host/B.HTML" {
		t.Fatalf("stack = %d entries, current %v", a.hist.len(), cur)
	}
}

// The right-edge chip submits while editing and toggles the menu otherwise.
func TestActionChipSubmitOrMenu(t *testing.T) {
	a := &app{hist: newHistory(), text: webrender.Bitmap{}}
	a.hist.push(entry{Target: "/host/A.HTML"})
	a.click(actX(winW)+3, backY+3)
	if !a.histOpen {
		t.Fatal("the action chip did not open the history menu")
	}
	a.click(actX(winW)+3, backY+3)
	if a.histOpen {
		t.Fatal("the action chip did not close the menu")
	}
	a.urlEditing = true
	a.urlEdit.reset("/host/C.HTML", maxURLBytes)
	a.click(actX(winW)+3, backY+3)
	if a.urlEditing || a.target != "/host/C.HTML" {
		t.Fatalf("the go chip did not submit: editing=%v target=%q", a.urlEditing, a.target)
	}
}

// The open menu paints a plate, a rule-filled selected row, the accent
// cursor bar, and row ink — pinned on the host pixel path so the gate's
// scanout probe has something it can actually see.
func TestHistoryMenuPaintsRows(t *testing.T) {
	a := &app{hist: newHistory()}
	a.hist.push(entry{Target: "/host/A.HTML", Title: "Alpha"})
	a.hist.push(entry{Target: "/host/B.HTML", Title: "Beta"})
	a.histOpen, a.histSel = true, 0
	pix := make([]uint32, winW*winH)
	vs := virender{pix: pix, w: winW, h: winH}
	a.paintHistoryMenu(vs, webrender.Clip{W: winW, H: winH}, winW)
	at := func(x, y int) uint32 { return pix[y*winW+x] & 0xffffff }
	if at(300, histMenuY+histRowH+8) != webrender.ColorSurface {
		t.Fatal("menu plate did not paint")
	}
	if at(300, histMenuY+8) != webrender.ColorRule {
		t.Fatal("selected row fill missing")
	}
	if at(histMenuX, histMenuY+8) != webrender.ColorAccent {
		t.Fatal("cursor accent bar missing")
	}
	ink := 0
	for y := histMenuY; y < histMenuY+2*histRowH; y++ {
		for x := histMenuX + 6; x < 400; x++ {
			if at(x, y) == webrender.ColorChromeInk {
				ink++
			}
		}
	}
	if ink < 20 {
		t.Fatalf("no row text painted: %d", ink)
	}
}

// While the menu is open arrows move the highlight, Escape closes, and an
// unrelated key dismisses the menu but still reaches its own binding.
func TestHistoryMenuKeys(t *testing.T) {
	a := &app{hist: newHistory(), text: webrender.Bitmap{}}
	a.hist.push(entry{Target: "A"})
	a.hist.push(entry{Target: "B"})
	a.histOpen = true
	if !a.histMenuKey(keyDown) || a.histSel != 1 {
		t.Fatal("Down did not move the highlight")
	}
	if !a.histMenuKey(keyUp) || a.histSel != 0 {
		t.Fatal("Up did not move the highlight back")
	}
	if !a.histMenuKey(keyEscape) || a.histOpen {
		t.Fatal("Escape did not close the menu")
	}
	a.histOpen = true
	if a.histMenuKey(keyR) {
		t.Fatal("an unrelated key was swallowed")
	}
	if a.histOpen {
		t.Fatal("an unrelated key did not dismiss the menu")
	}
}

// The serial markers are the live gate's grep targets: pin the exact bytes
// here so a rename cannot silently disarm the gate.
func TestMarkerConstants(t *testing.T) {
	want := map[string]string{
		markerOpen:     "web: open id=",
		markerParse:    "web: parse nodes=",
		markerLayout:   "web: layout blocks=",
		markerURL:      "web: url ",
		markerNav:      "web: nav ",
		markerError:    "web: error ",
		markerPaint:    "web: paint items=",
		markerPollErr:  "web: poll err=",
		markerLoop:     "web: poll n=",
		markerEvent:    "web: ev ",
		markerRepaint:  "web: repaint items=",
		markerReady:    "web: ready",
		markerNavReady: "web: nav-ready",
		markerFetch:    "web: fetch ",
		markerRedirect: "web: redirect n=",
		markerSettled:  "web: settled",
		markerEmpty:    "web: empty ",
		markerHistOpen: "web: history n=",
		markerHistRow:  "web: history ",
		markerHistPick: "web: history pick ",
		markerFind:     "web: find ",
		markerFindHit:  "web: find hit=",
		markerReload:   "web: reload",
	}
	for got, expect := range want {
		if got != expect {
			t.Fatalf("marker %q != %q", got, expect)
		}
	}
}

func TestResolveInput(t *testing.T) {
	cases := []struct{ in, want, kind string }{
		{"/host/PAGE.HTML", "/host/PAGE.HTML", "file"},
		{"NEXT.HTML", "/host/NEXT.HTML", "file"},
		{"http://10.0.0.2/x", "http://10.0.0.2/x", "http"},
		{"HTTP://10.0.0.2/", "HTTP://10.0.0.2/", "http"},
		{"https://example.com/", "https://example.com/", "http"}, // scheme-shaped; classifyTarget refuses it
		{"ftp://x/y", "ftp://x/y", "unsupported"},
		{"", "", "empty"},
	}
	for _, c := range cases {
		got, kind := resolveInput(c.in)
		if got != c.want || kind != c.kind {
			t.Fatalf("resolveInput(%q) = %q,%q want %q,%q", c.in, got, kind, c.want, c.kind)
		}
	}
}

func TestArgvTargetJoinsSlotsAndReadsHandoff(t *testing.T) {
	got, file := argvTarget([]string{"WEB.ELF", "http://10.0.0.2/"})
	if file || got != "http://10.0.0.2/" {
		t.Fatalf("single arg = %q file=%v", got, file)
	}
	// Slots at the kernel's 255-byte cap reassemble with no separator.
	long := "https://example.com/" + strings.Repeat("x", 540)
	var slots []string
	slots = append(slots, "WEB.ELF")
	for i := 0; i < len(long); i += 255 {
		j := i + 255
		if j > len(long) {
			j = len(long)
		}
		slots = append(slots, long[i:j])
	}
	got, file = argvTarget(slots)
	if file || got != long {
		t.Fatalf("joined = %q file=%v slots=%d", got, file, len(slots)-1)
	}
	path, file := argvTarget([]string{"WEB.ELF", "@/host/RSS.LINK"})
	if !file || path != "/host/RSS.LINK" {
		t.Fatalf("@path = %q file=%v", path, file)
	}
	if urlFromHandoff([]byte(long+"\n")) != long {
		t.Fatal("handoff file must yield the first line")
	}
}
