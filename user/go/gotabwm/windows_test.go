package main

import (
	"testing"
	"unsafe"

	"virelai/vi"
)

func TestLiveWindowPhaseSuppliesOwnBlur(t *testing.T) {
	oldDemo, oldOpen := demoMode, openBlurProbe
	defer func() { demoMode, openBlurProbe = oldDemo, oldOpen }()
	calls := 0
	openBlurProbe = func(x, y, w, h uint32) (int, int64) {
		calls++
		if x != 0 || y != 0 || w != 1 || h != 1 {
			t.Fatal("blur probe must be minimal and owned")
		}
		return 7, 0
	}
	demoMode = false
	if id, ok := beginProbeBlur(); !ok || id != 7 || calls != 1 {
		t.Fatal("normal boot still depends on external focus")
	}
	demoMode = true
	if id, ok := beginProbeBlur(); !ok || id != -1 || calls != 1 {
		t.Fatal("demo no longer tests the harness-driven blur")
	}
	demoMode = false
	openBlurProbe = func(uint32, uint32, uint32, uint32) (int, int64) {
		return -1, -vi.ErrENOMEM
	}
	if _, ok := beginProbeBlur(); ok {
		t.Fatal("failed blur window must not claim success")
	}
}

func TestSeatChromeBackBufferMatchesPaintAndCaches(t *testing.T) {
	scan := launcherScan()
	paintGodMenuButton(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	x, y, w, h := godMenuRect(vi.ScanoutWidth, vi.ScanoutHeight)
	got := make([]uint32, w*h)
	p := windowPixels{id: 7}
	calls := 0
	fill := func(id int, x, y, w, h, color uint32) {
		calls++
		if id != 7 || h != 1 {
			t.Fatal("wrong back-buffer destination")
		}
		for col := x; col < x+w; col++ {
			got[int(y)*p.w+int(col)] = color
		}
	}
	p.upload(scan, vi.ScanoutWidth, x, y, w, h, fill)
	src := unsafe.Slice((*uint32)(unsafe.Pointer(&scan[0])), len(scan)/4)
	for row := 0; row < h; row++ {
		for col := 0; col < w; col++ {
			want := src[(y+row)*vi.ScanoutWidth+x+col] & 0xffffff
			if got[row*w+col] != want {
				t.Fatalf("pixel %d,%d did not reach the window buffer", col, row)
			}
		}
	}
	before := calls
	p.upload(scan, vi.ScanoutWidth, x, y, w, h, fill)
	if calls != before {
		t.Fatal("unchanged paint should not issue fills")
	}
	src[y*vi.ScanoutWidth+x] ^= 0xff
	p.upload(scan, vi.ScanoutWidth, x, y, w, h, fill)
	if calls == before || got[0] != src[y*vi.ScanoutWidth+x]&0xffffff {
		t.Fatal("changed pixel did not update")
	}
}

// The gate greps these exact strings; a drift is a host-test failure rather
// than a live run that silently asserts nothing.
func TestWindowMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{MarkerWinOpen, "gotabwm: win open id="},
		{MarkerWinChrome, "gotabwm: win chrome"},
		{MarkerWinRect, "gotabwm: win rect "},
		{MarkerWinFocus, "gotabwm: win focus"},
		{MarkerWinBlur, "gotabwm: win blur"},
		{MarkerWinClose, "gotabwm: win close"},
		{MarkerWinGone, "gotabwm: win gone"},
		{MarkerWinLeak, "gotabwm: win leak id="},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

// The proposed POSITION must be off-scanout, or the kernel's clamp is not
// observable and the "clamped rect" assert would pass on an unclamped value.
// The size is carried through unchanged so the kernel's move-only reflow path
// applies (no back-buffer growth to be refused).
func TestProposedPositionIsOffScanout(t *testing.T) {
	if propX < vi.ScanoutWidth && propY < vi.ScanoutHeight {
		t.Fatalf("proposal at %d,%d is inside the %dx%d scanout — nothing to clamp",
			propX, propY, vi.ScanoutWidth, vi.ScanoutHeight)
	}
	if propX == 0 || propX > 0xffff || propY == 0 || propY > 0xffff {
		t.Fatalf("proposal %d,%d does not fit the a1 = x|(y<<16) encoding", propX, propY)
	}
	if propW != winW || propH != winH {
		t.Fatalf("proposal changes the size (%dx%d -> %dx%d); the move-only path is what the kernel can apply without growing the pool",
			winW, winH, propW, propH)
	}
}

// The window the seat opens must itself fit the scanout at its origin, or
// user_open refuses it outright (driving_award.user_open validates).
func TestOpenedRectFitsScanout(t *testing.T) {
	if winX+winW > vi.ScanoutWidth || winY+winH > vi.ScanoutHeight {
		t.Fatalf("opened rect %dx%d at %d,%d does not fit the scanout",
			winW, winH, winX, winY)
	}
	if winW == 0 || winH == 0 {
		t.Fatalf("opened rect must be non-empty")
	}
}

// The client-death probe must be a DIFFERENT window from the managed one, so
// its reaping proves the exit seam rather than re-proving the explicit close.
func TestLeakProbeIsDistinct(t *testing.T) {
	if leakW == winW && leakH == winH && leakX == winX && leakY == winY {
		t.Fatalf("leak probe duplicates the managed window's rect")
	}
	if leakX+leakW > vi.ScanoutWidth || leakY+leakH > vi.ScanoutHeight {
		t.Fatalf("leak probe %dx%d at %d,%d does not fit the scanout", leakW, leakH, leakX, leakY)
	}
}

// The chrome-descriptor page must be page-aligned and must not collide with
// the scanout tag the M57a path uses.
func TestScratchVAIsPageAlignedAndClear(t *testing.T) {
	if scratchVA%vi.PageSize != 0 {
		t.Fatalf("scratchVA %#x is not page-aligned", uint64(scratchVA))
	}
	if uint64(scratchVA) == uint64(vi.M33ScanoutTag) {
		t.Fatalf("scratchVA collides with the scanout tag")
	}
}

// The descriptor builder must produce a descriptor the kernel's own rule
// accepts: nonzero kind within chrome_kind_all (0x7f), flags in
// chrome_flags_all (0x01), rest_alpha <= 256 (0 here = the v1 zero-extension).
func TestFillBorderChromeIsValid(t *testing.T) {
	desc := make([]byte, vi.ChromeDescBytes)
	fillBorderChrome(desc)
	if len(desc) != 40 {
		t.Fatalf("descriptor length = %d want 40", len(desc))
	}
	kind := getU32LE(desc[0:])
	flags := getU32LE(desc[4:])
	if kind == 0 || kind&^uint32(0x7f) != 0 {
		t.Fatalf("kind %#x is not a valid chrome kind", kind)
	}
	if flags&^uint32(0x01) != 0 {
		t.Fatalf("flags %#x sets reserved bits", flags)
	}
}

// #2870: a released mirror carries an 8-bit id and no generation, so a
// mirror minted for a dead window must not close a live row on the
// reissued id — nor drop the successor's binding or zero its mirrored
// geometry. The row's bound owner pid plus the seat's cross-owner name
// read are the liveness proof.
func TestStaleDeathMirrorKeepsReusedRow(t *testing.T) {
	savedTabs, savedHosted := tabs, hostedApp
	savedLaunch, savedButton := launch, buttonPixels
	savedBinds, savedChalls := rpcBindings, rpcChallenges
	savedRects, savedXY := gpu3dRects, surfaceXY
	prevName, prevAlive, prevExit := readWindowName, procsAlive, procsExitStatus
	defer func() {
		tabs, hostedApp = savedTabs, savedHosted
		launch, buttonPixels = savedLaunch, savedButton
		rpcBindings, rpcChallenges = savedBinds, savedChalls
		gpu3dRects, surfaceXY = savedRects, savedXY
		readWindowName, procsAlive, procsExitStatus = prevName, prevAlive, prevExit
	}()
	tabs = TabStrip{}
	launch = launcherState{}
	buttonPixels = windowPixels{}
	if !tabs.OpenTab(6, "Settings") {
		t.Fatal("OpenTab")
	}
	rpcBindings[6] = rpcBinding{pid: 44, token: 0xbeef}
	gpu3dRects[6] = 560 | 360<<16
	surfaceXY[6] = 48 | 48<<16
	procsAlive = func(pid uint8) bool { return pid == 44 }
	procsExitStatus = func(uint8) (uint64, bool) { return 0, false }
	mirror := vi.Event{Kind: vi.EvWmWindow, Flags: 6 | 1<<13}

	// The successor's window answers at id 6 and its bound owner runs:
	// the mirror is stale, so the row, the binding, the reopen LIFO, and
	// the mirrored geometry all survive untouched.
	readWindowName = func(uint8) (string, bool) { return "Settings", true }
	launcherWindowEvent(mirror)
	if tabs.index(6) < 0 {
		t.Fatal("stale mirror closed the live row")
	}
	if rpcBindings[6].token != 0xbeef {
		t.Fatal("stale mirror dropped the successor's binding")
	}
	if c, ok := tabs.ReopenLastClosed(); ok {
		t.Fatalf("stale mirror pushed a reopen record %+v", c)
	}
	gpu3dNoteMirror(mirror)
	surfaceNoteMirror(mirror)
	if gpu3dRects[6] == 0 || surfaceXY[6] == 0 {
		t.Fatal("stale mirror zeroed the successor's mirrored geometry")
	}

	// A live window whose bound owner is DEAD is the successor-not-yet-
	// bound shape: the row's own window really is gone, so the mirror
	// closes it — and the recorded bin is GOSET.ELF, not "Settings".
	rpcBindings[6] = rpcBinding{pid: 99, token: 0xdead}
	procsAlive = func(uint8) bool { return false }
	launcherWindowEvent(mirror)
	if tabs.index(6) >= 0 {
		t.Fatal("dead-owner row survived its real mirror")
	}
	if rpcBindings[6].token != 0 {
		t.Fatal("dead owner's binding was not dropped")
	}
	c, ok := tabs.ReopenLastClosed()
	if !ok || c.Bin != "GOSET.ELF" {
		t.Fatalf("reopen record = %+v ok=%v want GOSET.ELF", c, ok)
	}

	// Nothing answering at id is the ordinary death: the row closes even
	// when its bound owner is still running (it closed the window first).
	if !tabs.OpenTab(6, "Settings") {
		t.Fatal("OpenTab arm 3")
	}
	rpcBindings[6] = rpcBinding{pid: 44, token: 0xf00d}
	procsAlive = func(pid uint8) bool { return pid == 44 }
	readWindowName = func(uint8) (string, bool) { return "", false }
	launcherWindowEvent(mirror)
	if tabs.index(6) >= 0 {
		t.Fatal("a real death mirror left the row open")
	}
	if rpcBindings[6].token != 0 {
		t.Fatal("a real death mirror kept the dead binding")
	}
}

func TestHostedWindowGetsZeroChromeAndSeatKeepsBorder(t *testing.T) {
	savedScratch, savedWrite := chromeScratch, writeWindowChrome
	defer func() { chromeScratch, writeWindowChrome = savedScratch, savedWrite }()
	chromeScratch = make([]byte, vi.PageSize)
	hosted := true
	writeWindowChrome = func(id uint32, desc []byte) int64 {
		if id != 7 || len(desc) != vi.ChromeDescBytes {
			t.Fatal("wrong descriptor destination or length")
		}
		if hosted {
			for _, b := range desc {
				if b != 0 {
					t.Fatal("hosted descriptor is not explicit no-chrome")
				}
			}
		} else if getU32LE(desc) != 1 {
			t.Fatal("seat-owned window lost its border descriptor")
		}
		return 0
	}
	if !setHostedWindowChrome(7) {
		t.Fatal("hosted chrome failed")
	}
	hosted = false
	if !setSeatWindowChrome(7) {
		t.Fatal("seat chrome failed")
	}
	writeWindowChrome = func(uint32, []byte) int64 { return -vi.ErrEINVAL }
	if setHostedWindowChrome(7) {
		t.Fatal("refused descriptor claimed success")
	}
}

// putU32LE must be little-endian and must not disturb neighbouring bytes.
func TestPutU32LE(t *testing.T) {
	b := make([]byte, 8)
	putU32LE(b[0:], 0x11223344)
	if b[0] != 0x44 || b[1] != 0x33 || b[2] != 0x22 || b[3] != 0x11 {
		t.Fatalf("putU32LE wrote % x want 44 33 22 11", b[:4])
	}
	if b[4] != 0 || b[5] != 0 || b[6] != 0 || b[7] != 0 {
		t.Fatalf("putU32LE spilled past its 4 bytes: % x", b)
	}
}

func getU32LE(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}
