// power_test.go — M115d (#2463): host tests for the seat's power menu.
// Everything here is pure — geometry, paint/hit agreement, and the
// requestSuspend verdict markers ride the injected vsockCtlRequest seam,
// so the test pins the exact marker lines the class-B gate greps without
// a guest.
package main

import (
	"testing"

	"virelai/vi"
)

func TestPowerButtonPaintAndHitAgree(t *testing.T) {
	defer saveSeatState()()
	for _, n := range []int{0, 1, 4} {
		tabs = TabStrip{}
		for i := 0; i < n; i++ {
			tabs.OpenTab(uint32(i+3), "App")
		}
		scan := launcherScan()
		if paintPowerButton(scan, vi.ScanoutWidth, vi.ScanoutHeight) == 0 {
			t.Fatalf("%d tabs: power button disappeared", n)
		}
		x, y, w, h := powerBtnRect(vi.ScanoutWidth, vi.ScanoutHeight)
		if w <= 0 {
			t.Fatalf("%d tabs: zero power rect", n)
		}
		for py := y - 1; py <= y+h; py++ {
			for px := x - 1; px <= x+w; px++ {
				want := px >= x && px < x+w && py >= y && py < y+h
				if powerBtnHit(uint32(px), uint32(py), vi.ScanoutWidth, vi.ScanoutHeight) != want {
					t.Fatalf("%d tabs: paint/hit mismatch %d,%d", n, px, py)
				}
			}
		}
		// The button is right of Apps, on the chrome band, and never on
		// the rail or inside the clock panel.
		gx, gy, gw, _ := godMenuRect(vi.ScanoutWidth, vi.ScanoutHeight)
		if x != gx+gw+powerBtnGap || y != gy {
			t.Fatalf("%d tabs: button not anchored to Apps", n)
		}
		cx, cy, cw, ch := chromeRect(vi.ScanoutWidth, vi.ScanoutHeight)
		if x < cx+cw && x+w > cx && y < cy+ch && y+h > cy {
			t.Fatalf("%d tabs: power overlaps clock", n)
		}
		if y < RailHeight {
			t.Fatalf("%d tabs: power on the rail", n)
		}
	}
}

func TestPowerMenuRectAndRow(t *testing.T) {
	defer saveSeatState()()
	x, y, w, h := powerMenuRect(vi.ScanoutWidth, vi.ScanoutHeight)
	if w != powerMenuW || h != powerMenuH {
		t.Fatalf("menu rect %dx%d", w, h)
	}
	bx, by, bw, _ := powerBtnRect(vi.ScanoutWidth, vi.ScanoutHeight)
	if x+w != bx+bw || by-y-h != powerMenuGap {
		t.Fatal("menu not anchored above the button")
	}
	if y < RailHeight || x < chromeInset {
		t.Fatal("menu out of bounds")
	}
	// M120d: two rows — Suspend on top, Snapshot under it, same
	// geometry the paint loop and the pointer path share.
	if r := powerMenuRowAt(uint32(x+1), uint32(y+4), vi.ScanoutWidth, vi.ScanoutHeight); r != 0 {
		t.Fatalf("row 0 miss: %d", r)
	}
	if r := powerMenuRowAt(uint32(x+w-1), uint32(y+3+powerRowH), vi.ScanoutWidth, vi.ScanoutHeight); r != 1 {
		t.Fatalf("row 1 miss: %d", r)
	}
	if powerMenuRowAt(uint32(x-1), uint32(y), vi.ScanoutWidth, vi.ScanoutHeight) >= 0 ||
		powerMenuRowAt(uint32(x), uint32(y+h), vi.ScanoutWidth, vi.ScanoutHeight) >= 0 ||
		powerMenuRowAt(uint32(x+1), uint32(y+2), vi.ScanoutWidth, vi.ScanoutHeight) >= 0 ||
		powerMenuRowAt(uint32(x+1), uint32(y+3+2*powerRowH+2), vi.ScanoutWidth, vi.ScanoutHeight) >= 0 {
		t.Fatal("row hit outside")
	}
}

func TestPowerMenuPointerFlow(t *testing.T) {
	defer saveSeatState()()
	prev := openInputSink
	openInputSink = func(x, y, w, h uint32) (int, int64) { return 91, 0 }
	defer func() { openInputSink = prev }()
	prevQ := queryWindow
	queryWindow = func(id int) ([8]uint32, int64) { return [8]uint32{0, 0, 0, 0, 0, 1}, 0 }
	defer func() { queryWindow = prevQ }()
	prevC := closeWin
	closeWin = func(id uint32) int64 { return 0 }
	defer func() { closeWin = prevC }()
	prevV := vsockCtlRequest
	defer func() { vsockCtlRequest = prevV }()
	var verbs []string
	vsockCtlRequest = func(verb, name string, code []byte) int64 {
		verbs = append(verbs, verb+"/"+name)
		copy(code, "unimplemented")
		return 13
	}

	// The button press opens the menu; the row press runs the request.
	openPowerMenu()
	if !powerMenuOpen {
		t.Fatal("menu did not open")
	}
	x, y, w, _ := powerMenuRect(vi.ScanoutWidth, vi.ScanoutHeight)
	e := ptrEvent(uint32(x+w/2), uint32(y+3+powerRowH/2), 1)
	prevPtrButtons = 0
	handleWmPointer(e)
	if powerMenuOpen {
		t.Fatal("row click left menu open")
	}
	if len(verbs) != 1 || verbs[0] != "suspend/" {
		t.Fatalf("requests = %v", verbs)
	}
	// A click outside an open menu just dismisses it — no request.
	openPowerMenu()
	e = ptrEvent(2, 2, 1)
	prevPtrButtons = 0
	handleWmPointer(e)
	if powerMenuOpen || len(verbs) != 1 {
		t.Fatalf("outside click: open=%v requests=%v", powerMenuOpen, verbs)
	}
	// The power button itself opens the menu through the same path.
	bx, by, bw, bh := powerBtnRect(vi.ScanoutWidth, vi.ScanoutHeight)
	e = ptrEvent(uint32(bx+bw/2), uint32(by+bh/2), 1)
	prevPtrButtons = 0
	handleWmPointer(e)
	if !powerMenuOpen {
		t.Fatal("button click did not open")
	}
	// And keys while open are the menu's: Escape dismisses, Enter runs.
	if !handlePowerKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x29}) || powerMenuOpen {
		t.Fatal("Esc did not dismiss")
	}
}

// M120d (#2561): the Snapshot row. With no Snapshots tab on the strip
// the row execs GOSNAP.ELF; with one already open it focuses it — the
// manager's verbs are process-wide, so a second window is never the
// honest answer. Both halves ride the execApp/powerFocus seams.
func TestPowerSnapshotExecsWithoutATab(t *testing.T) {
	defer saveSeatState()()
	prevE := execApp
	var bins []string
	execApp = func(name string, args ...string) (int64, error) {
		bins = append(bins, name)
		return 42, nil
	}
	defer func() { execApp = prevE }()
	tabs = TabStrip{}
	requestSnapshot()
	if len(bins) != 1 || bins[0] != gosnapBin {
		t.Fatalf("execs = %v", bins)
	}
}

func TestPowerSnapshotFocusesAnOpenTab(t *testing.T) {
	defer saveSeatState()()
	prevE := execApp
	execApp = func(name string, args ...string) (int64, error) {
		t.Fatalf("an open Snapshots tab must not re-exec: %s", name)
		return 0, nil
	}
	defer func() { execApp = prevE }()
	prevF := powerFocus
	var focused []uint32
	powerFocus = func(id uint32) bool {
		focused = append(focused, id)
		return true
	}
	defer func() { powerFocus = prevF }()
	tabs = TabStrip{}
	tabs.OpenTab(7, "Snapshots") // guessBin records GOSNAP.ELF
	requestSnapshot()
	if len(focused) != 1 || focused[0] != 7 {
		t.Fatalf("focused = %v", focused)
	}
}

// A refused focus still closes the gesture honestly — the marker names
// it and no exec follows (the running window keeps its verbs).
func TestPowerSnapshotFocusRefused(t *testing.T) {
	defer saveSeatState()()
	prevE := execApp
	execApp = func(name string, args ...string) (int64, error) {
		t.Fatalf("focus refusal must not fall back to exec: %s", name)
		return 0, nil
	}
	defer func() { execApp = prevE }()
	prevF := powerFocus
	powerFocus = func(id uint32) bool { return false }
	defer func() { powerFocus = prevF }()
	tabs = TabStrip{}
	tabs.OpenTab(7, "Snapshots")
	requestSnapshot() // must not panic; the marker carries the refusal
}

// The keyboard path: Down moves the highlight to Snapshot, Enter runs
// the highlighted row — pointer and keys reach the same dispatch.
func TestPowerKeysSelectSnapshot(t *testing.T) {
	defer saveSeatState()()
	prev := openInputSink
	openInputSink = func(x, y, w, h uint32) (int, int64) { return 91, 0 }
	defer func() { openInputSink = prev }()
	prevQ := queryWindow
	queryWindow = func(id int) ([8]uint32, int64) { return [8]uint32{0, 0, 0, 0, 0, 1}, 0 }
	defer func() { queryWindow = prevQ }()
	prevC := closeWin
	closeWin = func(id uint32) int64 { return 0 }
	defer func() { closeWin = prevC }()
	prevE := execApp
	var bins []string
	execApp = func(name string, args ...string) (int64, error) {
		bins = append(bins, name)
		return 42, nil
	}
	defer func() { execApp = prevE }()
	tabs = TabStrip{}

	openPowerMenu()
	if powerSel != 0 {
		t.Fatalf("open sel=%d", powerSel)
	}
	handlePowerKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x51}) // Down
	if powerSel != 1 {
		t.Fatalf("sel=%d after Down", powerSel)
	}
	handlePowerKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x51}) // Down clamps
	if powerSel != 1 {
		t.Fatalf("sel=%d past the end", powerSel)
	}
	handlePowerKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x52}) // Up
	if powerSel != 0 {
		t.Fatalf("sel=%d after Up", powerSel)
	}
	handlePowerKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x51})
	handlePowerKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x28}) // Enter
	if powerMenuOpen {
		t.Fatal("Enter left the menu open")
	}
	if len(bins) != 1 || bins[0] != gosnapBin {
		t.Fatalf("execs = %v", bins)
	}
}

// suspendVerdict names its outcome exactly — `ok` on the accept, the
// refusal's ADR 0056 code otherwise; the verdict string is the suffix of
// MarkerSuspendVerdict the gate greps.
func TestRequestSuspendVerdicts(t *testing.T) {
	defer saveSeatState()()
	prev := vsockCtlRequest
	defer func() { vsockCtlRequest = prev }()
	for _, tc := range []struct {
		r    int64
		code string
		want string
	}{
		{0, "", "ok"},
		{13, "unimplemented", "unimplemented"},
		{8, "io_error", "io_error"},
		{-vi.ErrENOSYS, "", "ENOSYS"},
	} {
		vsockCtlRequest = func(verb, name string, code []byte) int64 {
			if verb != "suspend" || name != "" {
				t.Fatalf("request = %q %q", verb, name)
			}
			copy(code, tc.code)
			return tc.r
		}
		if got := suspendVerdict(); got != tc.want {
			t.Fatalf("r=%d: verdict %q, want %q", tc.r, got, tc.want)
		}
	}
}
