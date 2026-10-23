package main

import (
	"errors"
	"os"
	"testing"

	"virelai/theme"
	"virelai/vi"
	"virelai/webrender/qoi"
)

// Ordinary window/focus/close seams, not a mocked "key consumed" claim.
func stubLauncherWindows(t *testing.T) (*[]uint32, *[]uint32, map[int]bool) {
	t.Helper()
	oldOpen, oldQuery, oldClose, oldFocus := openInputSink, queryWindow, closeWin, focusRaise
	oldRead, oldFile := readAppsFile, openFile
	raises, closes := []uint32{}, []uint32{}
	live := map[int]bool{3: true, 4: true, 9: true}
	openInputSink = func(x, y, w, h uint32) (int, int64) {
		if x != launchX || y != launchY || w != launchW || h != uint32(launch.panelH()) {
			t.Fatal("sink must be a separate bounded seat window")
		}
		live[9] = true
		return 9, 0
	}
	queryWindow = func(id int) ([8]uint32, int64) {
		// Match the real ABI: the seat cannot WinQuery a hosted client.
		if id != 9 {
			t.Fatalf("cross-client WinQuery(%d) is not an available seam", id)
		}
		if !live[id] {
			return [8]uint32{}, -vi.ErrEINVAL
		}
		return [8]uint32{}, 0
	}
	closeWin = func(id uint32) int64 {
		closes = append(closes, id)
		delete(live, int(id))
		return 0
	}
	focusRaise = func(id uint32) int64 {
		if !live[int(id)] {
			return -vi.ErrEINVAL
		}
		raises = append(raises, id)
		return 0
	}
	readAppsFile = func(string, int) ([]byte, int64) {
		return []byte("GOCALC.ELF | Calculator | c\nGOTERM.ELF | Terminal | t\nTABWM.BIN | Tabbed Desktop | m\n"), 0
	}
	openFile = func(string, uint32) (int64, int64) { return 7, 0 }
	t.Cleanup(func() {
		openInputSink, queryWindow, closeWin, focusRaise = oldOpen, oldQuery, oldClose, oldFocus
		readAppsFile, openFile = oldRead, oldFile
	})
	return &raises, &closes, live
}

func launcherScan() []byte {
	return make([]byte, vi.ScanoutWidth*vi.ScanoutHeight*4)
}

func countLaunchInk(scan []byte, x, y, w, h int, rgb uint32) int {
	n := 0
	for py := y; py < y+h; py++ {
		for px := x; px < x+w; px++ {
			i := (py*vi.ScanoutWidth + px) * 4
			if uint32(scan[i])|uint32(scan[i+1])<<8|uint32(scan[i+2])<<16 == rgb {
				n++
			}
		}
	}
	return n
}

func TestLauncherPaintsLabelsQueryAndUnavailableState(t *testing.T) {
	defer saveSeatState()()
	launch = launcherState{
		open: true, filter: "term", sel: 0,
		catalog:  []AppEntry{{Bin: "GOTERM.ELF", Label: "Terminal"}},
		filtered: []int{0}, reasons: []string{"Binary not staged"},
		err: "Launch failed: GOTERM.ELF",
	}
	scan := launcherScan()
	if paintLauncher(scan, vi.ScanoutWidth, vi.ScanoutHeight) == 0 {
		t.Fatal("no panel paint")
	}
	// #2054: a left-edge strip, not the centred panel. Header top-down is
	// emblem, prompt, filter field, error line, then the ranked column.
	for _, r := range []struct {
		name       string
		x, y, w, h int
		ink        uint32
	}{
		{"strip", 0, 0, 8, 8, theme.Current.Surface},
		{"emblem fallback", 99, 16, 64, 1, theme.Current.Border},
		{"prompt", 8, 88, 32, 8, theme.Current.Ink},
		// M104e: the field's ring is the §2.3.5 focus ring — Accent while
		// the strip owns the focus, not the old Border.
		{"field", 8, 104, 246, 1, theme.Current.Accent},
		{"query", 14, 110, 32, 8, theme.Current.Ink},
		{"error", 8, 128, 200, 8, theme.Current.Danger},
	} {
		if countLaunchInk(scan, r.x, r.y, r.w, r.h, r.ink) < 10 {
			t.Fatalf("%s has no glyph pixels", r.name)
		}
	}
	if countLaunchInk(scan, 262, 0, 2, 400, theme.Current.Accent) != 800 {
		t.Fatal("the strip's right-edge accent rule is missing")
	}
	for py := 100; py < 110; py++ {
		for px := 264; px < vi.ScanoutWidth; px++ {
			i := (py*vi.ScanoutWidth + px) * 4
			if scan[i] != 0 || scan[i+1] != 0 || scan[i+2] != 0 || scan[i+3] != 0 {
				t.Fatalf("launcher pixels leaked past the strip into the desktop at (%d,%d)", px, py)
			}
		}
	}
	x, y, _, _, ok := launch.rowRect(0, vi.ScanoutWidth, vi.ScanoutHeight)
	if !ok || x != 8 || y != 140 {
		t.Fatal("the ranked column does not start under the header")
	}
	// §2.3.6: the selected row is a Selection fill with a 3px Accent
	// marker at its left edge — probe inside both, clear of the rounded
	// corner falloff.
	if countLaunchInk(scan, x+8, y+6, 24, 8, theme.Current.Selection) == 0 {
		t.Fatal("selected row not painted")
	}
	if countLaunchInk(scan, x, y+6, 3, 8, theme.Current.Accent) != 24 {
		t.Fatal("selected row's accent marker missing")
	}
	if countLaunchInk(scan, x+6, y+3, 32, 8, theme.Current.InkMuted) < 10 {
		t.Fatal("dimmed label ink missing")
	}
	if countLaunchInk(scan, x+6, y+13, 32, 8, theme.Current.Muted) < 10 {
		t.Fatal("unavailable reason missing")
	}
	launch.filtered, launch.err = nil, ""
	paintLauncher(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	// M123b (#2576): the zero-match strip paints the shared empty-state
	// plate — a Border ring around the results region with centred
	// icon/headline/hint rows inside it.
	if countLaunchInk(scan, 8, 140, 246, 560, theme.Current.Border) < 20 {
		t.Fatal("empty-state border ring missing")
	}
	if countLaunchInk(scan, 8, 140, 246, 560, theme.Current.Muted) < 10 {
		t.Fatal("empty-state hint glyphs missing")
	}
}

// TestLauncherStripIsDockedToTheLeftEdge is the AC-B2 geometry contract: the
// strip owns the scanout's left edge for its full height. The centred panel
// it replaces (x=240, content-height) fails every clause.
func TestLauncherStripIsDockedToTheLeftEdge(t *testing.T) {
	defer saveSeatState()()
	if launchX != 0 || launchY != 0 {
		t.Fatal("the strip must dock the scanout's top-left corner")
	}
	launch = launcherState{open: true}
	if launch.panelH() != vi.ScanoutHeight {
		t.Fatal("a docked edge strip is full height, not content-sized")
	}
}

// TestLauncherHeaderCarriesTheEmblemRaster stages the repo's mascot fixture
// at the emblem's share path through the same read seam APPS.TXT uses, then
// checks the strip's emblem slot pixel-for-pixel: opaque source pixels
// composite exactly, transparent corners leave the Surface showing — the
// real raster, not a rect-drawn stand-in (AC-B1).
func TestLauncherHeaderCarriesTheEmblemRaster(t *testing.T) {
	defer saveSeatState()()
	// Other suites paint the chrome first and may have already spent the
	// one-shot decode on the real (absent) share; the fresh launcherState
	// below carries a zeroed emblem, so the decode tries again against the
	// fixture.
	body, err := os.ReadFile("../../src/lib/fixtures/qoi/mascot_64x64.qoi")
	if err != nil {
		t.Fatalf("mascot fixture: %v", err)
	}
	old := readAppsFile
	readAppsFile = func(path string, max int) ([]byte, int64) {
		if path == "/host/SEXIBURGER.QOI" {
			return body, int64(len(body))
		}
		return []byte("GOCALC.ELF | Calculator | c\n"), 0
	}
	defer func() { readAppsFile = old }()
	w, h, src, derr := qoi.Decode(body, 256, 256*256)
	if derr != nil {
		t.Fatalf("fixture does not decode: %v", derr)
	}
	launch = launcherState{
		open:     true,
		catalog:  []AppEntry{{Bin: "GOCALC.ELF", Label: "Calculator"}},
		filtered: []int{0},
	}
	scan := launcherScan()
	paintLauncher(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	x0, y0 := launchX+(264-2-w)/2, 16
	opaque, transparent := 0, 0
	for r := 0; r < h; r++ {
		for c := 0; c < w; c++ {
			s := src[r*w+c]
			i := ((y0+r)*vi.ScanoutWidth + x0 + c) * 4
			got := uint32(scan[i]) | uint32(scan[i+1])<<8 | uint32(scan[i+2])<<16
			switch s >> 24 {
			case 255:
				opaque++
				if got != s&0xffffff {
					t.Fatalf("emblem pixel (%d,%d) painted %06x, want %06x", c, r, got, s&0xffffff)
				}
			case 0:
				transparent++
				if got != theme.Current.Surface {
					t.Fatalf("transparent emblem pixel (%d,%d) painted %06x over the Surface", c, r, got)
				}
			}
		}
	}
	if opaque < 1000 || transparent == 0 {
		t.Fatalf("emblem slot does not hold the real raster: opaque=%d transparent=%d", opaque, transparent)
	}
}

// TestLauncherRanksPrefixSubstringThenFuzzy is AC-C1/C2: a prefix hit
// outranks a substring hit, a substring outranks a fuzzy reach, and the same
// (catalog, query) refreshes to the identical order every time. The old
// manifest-order filter leaves row 0 first — this fails on it.
func TestLauncherRanksPrefixSubstringThenFuzzy(t *testing.T) {
	defer saveSeatState()()
	launch = launcherState{open: true}
	launch.catalog = parseAppsTXT(
		"EDITCAL.ELF | Editor Calc | e\n" + // substring only
			"GOCALC.ELF | Calc | c\n" + // prefix — manifest row 1, must rank first
			"CARNIVAL.ELF | Carnival Clock | k\n" + // fuzzy: c-a-l-c subsequence
			"RUNNER.ELF | Runner | r | dock=false | argv=--calc-mode\n" + // fuzzy via argv=
			"GOFILES.ELF | Files | f\n")
	launch.filter = "calc"
	want := []int{1, 0, 2, 3, paletteSearchIdx} // M191b: the hand-off row rides last
	for i := 0; i < 100; i++ {
		launch.refresh()
		if len(launch.filtered) != len(want) {
			t.Fatalf("refresh %d ranked %v, want %v", i, launch.filtered, want)
		}
		for j, v := range want {
			if launch.filtered[j] != v {
				t.Fatalf("refresh %d ranked %v, want %v", i, launch.filtered, want)
			}
		}
	}
}

// TestLauncherEscapeClearsTheFilterFirst is AC-C4: with a non-empty filter
// Esc edits the query, not the panel. Only an already-clear Esc dismisses.
func TestLauncherEscapeClearsTheFilterFirst(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	tabs = TabStrip{}
	tabs.OpenTab(3, "Edit")
	launch = launcherState{}
	openLauncher()
	for _, usage := range []uint32{0x06, 0x04} {
		handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: usage})
	}
	if launch.filter != "ca" {
		t.Fatalf("filter = %q", launch.filter)
	}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: uint32(hidUsageEscape)})
	if !launch.open || launch.filter != "" {
		t.Fatal("the first Esc must clear the filter and keep the strip open")
	}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: uint32(hidUsageEscape)})
	if launch.open {
		t.Fatal("the second Esc must dismiss")
	}
}

// TestLauncherChordDismissesAnOpenStrip is AC-A2: the same chord that
// summons the strip dismisses it — one front door, both directions.
func TestLauncherChordDismissesAnOpenStrip(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	tabs = TabStrip{}
	tabs.OpenTab(3, "Edit")
	launch = launcherState{}
	openLauncher()
	if !launch.open {
		t.Fatal("summon failed")
	}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: uint32(hidUsageSpace), Flags: vi.ModCtrl})
	if launch.open {
		t.Fatal("Ctrl+Space while open must dismiss")
	}
}

func TestLauncherHitRejectsHeaderPaddingAndUnpaintedRows(t *testing.T) {
	defer saveSeatState()()
	launch = launcherState{open: true}
	for i := 0; i < appsMax; i++ {
		launch.catalog = append(launch.catalog, AppEntry{Bin: "APP.ELF", Label: "App"})
	}
	launch.refresh()
	x := launchX + theme.Current.PadMD
	y := launchY + launchHdr
	if _, ok := launchRowAt(uint32(x), uint32(y)); ok {
		t.Fatal("a never-painted row is not clickable")
	}
	scan := launcherScan()
	paintLauncher(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	for _, p := range [][2]int{
		{x, launchY}, {x, y - 1}, {launchX, y}, {x - 1, y},
		{launchX + launchW - theme.Current.PadMD, y},
		{x, y + launch.rowH() - theme.Current.PadXS},
		{x, launchY + launch.panelH() - 1}, {x, launchY + launch.panelH()},
		{x, y + launch.visibleRows()*launch.rowH()}, {0, 0},
	} {
		if _, ok := launchRowAt(uint32(p[0]), uint32(p[1])); ok {
			t.Fatalf("header/padding/unpainted point %v hit", p)
		}
	}
	if i, ok := launchRowAt(uint32(x), uint32(y)); !ok || i != 0 {
		t.Fatal("first row start must hit row 0")
	}
	paintLauncher(scan, vi.ScanoutWidth, y+launch.rowH()-1)
	if _, ok := launchRowAt(uint32(x), uint32(y)); ok {
		t.Fatal("clipped row must not hit")
	}
	launch.filter = "no such app"
	launch.refresh()
	paintLauncher(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	// M191b: a no-match filter still offers the M165f hand-off row —
	// row 0 IS a real target; the empty region below it is not.
	if i, ok := launchRowAt(uint32(x), uint32(y)); !ok || i != 0 {
		t.Fatal("the hand-off row must be a real target")
	}
	if _, ok := launchRowAt(uint32(x), uint32(y+launch.rowH())); ok {
		t.Fatal("the row under the lone hand-off must not hit")
	}
}

func TestGodMenuFocusRestoresOrLaunches(t *testing.T) {
	defer saveSeatState()()
	raises, closes, live := stubLauncherWindows(t)
	tabs = TabStrip{}
	tabs.OpenTab(3, "Edit")
	launch = launcherState{}
	openLauncher()
	if len(*raises) != 1 || (*raises)[0] != 9 || launch.sink != 9 {
		t.Fatal("real sink focus must precede filter input")
	}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: 0x06})
	if launch.filter != "c" {
		t.Fatal("filter did not reach the focused menu")
	}
	// The sink's app-side key copy drains without becoming a second filter.
	consumeSeatEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: 'c'})
	if launch.filter != "c" {
		t.Fatal("sink events were interpreted twice")
	}
	dismissLauncher()
	if launch.open || launch.sink != 0 || (*raises)[len(*raises)-1] != 3 || len(*closes) != 1 {
		t.Fatalf("dismiss did not restore/close: raises=%v closes=%v", *raises, *closes)
	}

	openLauncher()
	delete(live, 3) // death before its release mirror
	dismissLauncher()
	if tabs.index(3) >= 0 || launch.sink != 0 {
		t.Fatal("dead former tab restored or sink leaked")
	}
	for _, id := range (*raises)[len(*raises)-1:] {
		if id != 9 {
			t.Fatal("dismiss raised a dead tab")
		}
	}

	tabs.OpenTab(4, "Edit")
	openLauncher()
	oldExec := execApp
	execApp = func(string, ...string) (int64, error) { return 42, nil }
	defer func() { execApp = oldExec }()
	before := len(*raises)
	execSelected()
	if launch.open || launch.sink != 0 {
		t.Fatal("successful launch leaked sink")
	}
	for _, id := range (*raises)[before:] {
		if id == 4 {
			t.Fatal("successful launch must let the new app declare/focus, not restore old app")
		}
	}
	// Kernel seat/client death closes ordinary owned windows. Also handle
	// the existing released mirror if the sink is closed while the seat lives.
	openLauncher()
	menuPixels = windowPixels{id: 9, w: 1, h: 1, pixels: []uint32{0xffffff}}
	delete(live, 9)
	consumeSeatEvent(vi.Event{Kind: vi.EvWmWindow, Flags: 9 | 1<<13})
	if launch.open || launch.sink != 0 || menuPixels.id != 0 {
		t.Fatal("dead sink left menu focused on a dead target")
	}
}

func TestLauncherPointerExecOnce(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	launch = launcherState{}
	tabs = TabStrip{}
	prevPtrButtons, menuGesture = 0, false
	openLauncher()
	launch.catalog = parseAppsTXT("GOCALC.ELF | Calculator | c | dock=true\n")
	launch.reasons = nil
	launch.refresh()
	paintLauncher(launcherScan(), vi.ScanoutWidth, vi.ScanoutHeight)
	calls := 0
	oldExec := execApp
	defer func() { execApp = oldExec }()
	execApp = func(bin string, args ...string) (int64, error) {
		calls++
		if bin != "GOCALC.ELF" || len(args) != 0 {
			t.Fatalf("wrong manifest ELF/argc=0: %q %v", bin, args)
		}
		return 42, nil
	}
	x, y := uint32(launchX+20), uint32(launchY+launchHdr+2)
	handleWmPointer(ptrEvent(x, y, hidBtnLeft))
	handleWmPointer(ptrEvent(x+20, y+20, hidBtnLeft))
	handleWmPointer(ptrEvent(x, y, 0))
	if calls != 1 || launch.open {
		t.Fatalf("one gesture: execs=%d open=%v", calls, launch.open)
	}
	openLauncher()
	execApp = func(string, ...string) (int64, error) {
		calls++
		return 0, errors.New("load refused")
	}
	paintLauncher(launcherScan(), vi.ScanoutWidth, vi.ScanoutHeight)
	handleWmPointer(ptrEvent(x, y, hidBtnLeft))
	handleWmPointer(ptrEvent(x, y, hidBtnLeft))
	handleWmPointer(ptrEvent(x, y, 0))
	if calls != 2 || !launch.open || launch.err == "" || launch.sink == 0 {
		t.Fatal("failure must remain visible, focused, and execute once")
	}
	scan := launcherScan()
	paintLauncher(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	if countLaunchInk(scan, 8, 128, 200, 8, theme.Current.Danger) < 10 {
		t.Fatal("failure has no visible glyphs")
	}
}

func TestLauncherSelectionBoundedAndScrolls(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	launch = launcherState{open: true, sink: 9}
	for i := 0; i < appsMax; i++ {
		launch.catalog = append(launch.catalog, AppEntry{Bin: "APP.ELF", Label: "App"})
	}
	launch.refresh()
	for i := 0; i < appsMax+5; i++ {
		handleLauncherKey(vi.Event{Arg0: uint32(hidUsageDown)})
	}
	if launch.sel != appsMax-1 || launch.first == 0 {
		t.Fatal("down must clamp and reveal the last row")
	}
	paintLauncher(launcherScan(), vi.ScanoutWidth, vi.ScanoutHeight)
	x, y, _, _, ok := launch.rowRect(launch.sel, vi.ScanoutWidth, vi.ScanoutHeight)
	if !ok {
		t.Fatal("selected row not visible")
	}
	if i, hit := launchRowAt(uint32(x), uint32(y)); !hit || i != launch.sel {
		t.Fatal("scrolled paint and hit disagree")
	}
	for i := 0; i < appsMax+5; i++ {
		handleLauncherKey(vi.Event{Arg0: uint32(hidUsageUp)})
	}
	if launch.sel != 0 || launch.first != 0 {
		t.Fatal("up must clamp at the first row")
	}
}

func TestLauncherUnavailableAndSeatEntriesNeverExec(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	openFile = func(string, uint32) (int64, int64) { return -1, -vi.ErrENOENT }
	launch = launcherState{}
	openLauncher()
	oldExec := execApp
	execApp = func(string, ...string) (int64, error) { t.Fatal("disabled row exec"); return 0, nil }
	defer func() { execApp = oldExec }()
	execSelected()
	if launch.err != "Binary not staged" || !launch.open {
		t.Fatal("missing binary not visibly refused")
	}
	launch.sel = 2
	execSelected()
	if launch.err != "Seat: use settings wm" {
		t.Fatal("fallback seat falsely offered as a hosted app")
	}
	launch.reasons = nil
	execSelected() // still refused if the availability probe was skipped
}

func TestLauncherFocusFailureNeverClaimsModalOwnership(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	launch = launcherState{}
	openInputSink = func(uint32, uint32, uint32, uint32) (int, int64) {
		return -1, -vi.ErrEINVAL
	}
	openLauncher()
	if launch.open || launch.sink != 0 || launch.err == "" {
		t.Fatal("failed sink must not pretend to own modal input")
	}
	scan := launcherScan()
	paintGodMenuButton(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	x, y, _, _ := godMenuRect(vi.ScanoutWidth, vi.ScanoutHeight)
	if countLaunchInk(scan, x+chromePad, y+chromePad, 80, 8, theme.Current.Danger) < 10 {
		t.Fatal("failed open not visible on the button")
	}
}

func TestLauncherLaunchCloseRetryNeverExecutesTwice(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	tabs = TabStrip{}
	tabs.OpenTab(3, "Edit")
	launch = launcherState{}
	openLauncher()
	oldExec := execApp
	defer func() { execApp = oldExec }()
	calls := 0
	execApp = func(string, ...string) (int64, error) { calls++; return 42, nil }
	closeWin = func(uint32) int64 { return -vi.ErrEINVAL }
	execSelected()
	if calls != 1 || !launch.open || !launch.launching || launch.sink == 0 {
		t.Fatal("failed sink close must retain ownership after the successful exec")
	}
	execSelected()
	handleLauncherKey(vi.Event{Arg0: uint32(hidUsageEnter)})
	if calls != 1 {
		t.Fatal("retry launched a second app")
	}
	closeWin = func(uint32) int64 { return 0 }
	execSelected()
	if launch.open || launch.sink != 0 || calls != 1 {
		t.Fatal("close retry leaked the sink or exec'd again")
	}
}

func TestLauncherEscapeRestoresFocusWithoutInterpretingSinkCopies(t *testing.T) {
	defer saveSeatState()()
	raises, closes, _ := stubLauncherWindows(t)
	tabs = TabStrip{}
	tabs.OpenTab(3, "Edit")
	launch = launcherState{}
	openLauncher()
	for _, usage := range []uint32{0x06, 0x04, 0x0f, 0x06} {
		handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: usage})
		consumeSeatEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: usage, Arg1: 'x'})
	}
	if launch.filter != "calc" {
		t.Fatal("modal filter interpreted the app-side copy")
	}
	// #2054 AC-C4: the first Esc clears "calc", the second dismisses and
	// restores focus to the tab that owned it before the summon.
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: uint32(hidUsageEscape)})
	if !launch.open || launch.filter != "" {
		t.Fatal("the first Escape must clear the filter, not dismiss")
	}
	handleWmKey(vi.Event{Kind: vi.EvWmKey, Arg0: uint32(hidUsageEscape)})
	if launch.open || launch.sink != 0 || len(*closes) != 1 || (*raises)[len(*raises)-1] != 3 {
		t.Fatal("Escape did not release the sink and restore the old app")
	}
}

// --- M191b (#3243): filename hits + verb rows ---------------------------

func dirEnt(name string, dir bool) vi.DirEntry {
	var e vi.DirEntry
	copy(e.Name[:], name)
	if dir {
		e.IsDir = 1
	}
	return e
}

// stubLaunchTree stubs the walk's directory seam with a path -> entries
// table (searchDirList/mountRows pattern), plus readAppsFile for the
// manifest and the mime heads.
func stubLaunchTree(t *testing.T, tree map[string][]vi.DirEntry, files map[string]string) {
	t.Helper()
	oldDir, oldRead := launchDirList, readAppsFile
	launchDirList = func(path string, buf []vi.DirEntry) (int, int64) {
		ents, ok := tree[path]
		if !ok {
			return 0, -vi.ErrENOENT
		}
		n := len(ents)
		if n > len(buf) {
			n = len(buf)
		}
		copy(buf, ents[:n])
		return n, 0
	}
	readAppsFile = func(path string, max int) ([]byte, int64) {
		if path == appsPath {
			return []byte("GOCALC.ELF | Calculator | c\nGOEDIT.ELF | Code Editor | e | dock=true | v=2 | opens=text,binary\nNOTE.ELF | Text Editor | n | dock=true | v=2 | opens=text\n"), 0
		}
		if s, ok := files[path]; ok {
			b := []byte(s)
			if len(b) > max {
				b = b[:max]
			}
			return b, 0
		}
		return nil, -vi.ErrENOENT
	}
	t.Cleanup(func() { launchDirList, readAppsFile = oldDir, oldRead })
}

func TestLauncherFilenameHitsJoinTheResults(t *testing.T) {
	defer saveSeatState()()
	stubLaunchTree(t, map[string][]vi.DirEntry{
		"/host":    {dirEnt("LV", true), dirEnt("GOCALC.ELF", false)},
		"/host/LV": {dirEnt("VERB.TXT", false), dirEnt("OTHER.TXT", false)},
	}, nil)
	launch = launcherState{open: true}
	loadLauncherCatalog()
	launch.filter = "verb"
	launch.refresh()
	// The app rank holds the floor: file hits append after manifest rows
	// and the hand-off sentinel rides last.
	want := []int{launchFileIdx0, paletteSearchIdx}
	if len(launch.filtered) != len(want) {
		t.Fatalf("filtered = %v want %v", launch.filtered, want)
	}
	for i, v := range want {
		if launch.filtered[i] != v {
			t.Fatalf("filtered = %v want %v", launch.filtered, want)
		}
	}
	h := launch.hits[0]
	if h.path != "/host/LV/VERB.TXT" || h.name != "VERB.TXT" || h.dir != "/host/LV" {
		t.Fatalf("hit = %+v", h)
	}
}

func TestLauncherWalkNamesItsBounds(t *testing.T) {
	defer saveSeatState()()
	// The hits bound: more matching files than the entry cap, spread
	// over two dirs — the kernel's own 16-row dir_list window bounds
	// any single listing too.
	var a, b []vi.DirEntry
	for i := 0; i < 12; i++ {
		a = append(a, dirEnt("VERBA"+string(rune('A'+i))+".TXT", false))
		b = append(b, dirEnt("VERBB"+string(rune('A'+i))+".TXT", false))
	}
	a = append(a, dirEnt("D", true))
	stubLaunchTree(t, map[string][]vi.DirEntry{"/host": a, "/host/D": b}, nil)
	launch = launcherState{open: true}
	launch.walkFiles("verb")
	if launch.hitsTrunc != "hits" || len(launch.hits) != launchFileMaxHits {
		t.Fatalf("trunc=%q n=%d want hits/%d", launch.hitsTrunc, len(launch.hits), launchFileMaxHits)
	}
	// The depth bound: a chain deeper than 4 holds its target unreachable.
	launch = launcherState{open: true}
	stubLaunchTree(t, map[string][]vi.DirEntry{
		"/host":           {dirEnt("A", true)},
		"/host/A":         {dirEnt("B", true)},
		"/host/A/B":       {dirEnt("C", true)},
		"/host/A/B/C":     {dirEnt("D", true)},
		"/host/A/B/C/D":   {dirEnt("E", true)},
		"/host/A/B/C/D/E": {dirEnt("VERB.TXT", false)},
	}, nil)
	launch.walkFiles("verb")
	if launch.hitsTrunc != "depth" || len(launch.hits) != 0 {
		t.Fatalf("trunc=%q n=%d want depth/0", launch.hitsTrunc, len(launch.hits))
	}
	// The visited bound: the traversal cap stops the walk even when the
	// entry cap is nowhere near — 16 dirs of 16 entries each is 272
	// visited rows inside the kernel's own 16-per-listing window.
	launch = launcherState{open: true}
	tree := map[string][]vi.DirEntry{"/host": {}}
	for i := 0; i < 16; i++ {
		d := "V" + string(rune('A'+i))
		tree["/host"] = append(tree["/host"], dirEnt(d, true))
		for j := 0; j < 16; j++ {
			tree["/host/"+d] = append(tree["/host/"+d], dirEnt("Z"+string(rune('a'+j))+".TXT", false))
		}
	}
	stubLaunchTree(t, tree, nil)
	launch.walkFiles("verb")
	if launch.hitsTrunc != "visited" {
		t.Fatalf("trunc=%q want visited", launch.hitsTrunc)
	}
}

func TestLauncherVerbsCycleAndDispatch(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	stubLaunchTree(t, map[string][]vi.DirEntry{
		"/host":    {dirEnt("LV", true)},
		"/host/LV": {dirEnt("VERB.TXT", false)},
	}, map[string]string{"/host/LV/VERB.TXT": "hello\n"})
	launch = launcherState{}
	openLauncher()
	launch.filter = "verb"
	launch.refresh()
	if len(launch.filtered) != 2 {
		t.Fatalf("filtered = %v want [hit hand-off]", launch.filtered)
	}
	// sel 0 is the file hit: verbs are open (mime dispatch -> GOEDIT),
	// reveal (GOFILES at the parent), then the opens= candidates.
	vs := launch.verbsFor(launch.filtered[0])
	if len(vs) != 4 || vs[0].name != "open" || vs[0].bin != "GOEDIT.ELF" ||
		vs[1].name != "reveal" || vs[1].bin != "GOFILES.ELF" ||
		vs[2].bin != "GOEDIT.ELF" || vs[3].bin != "NOTE.ELF" {
		t.Fatalf("verbs = %+v", vs)
	}
	calls := []string{}
	oldExec := execApp
	defer func() { execApp = oldExec }()
	execApp = func(bin string, args ...string) (int64, error) {
		calls = append(calls, bin+" "+joinSpace(args))
		return 42, nil
	}
	// Tab arms reveal; Enter runs GOFILES at the containing folder.
	launch.stepVerb(1)
	if launch.verb != 1 {
		t.Fatalf("verb = %d want 1 (reveal)", launch.verb)
	}
	execSelected()
	if len(calls) != 1 || calls[0] != "GOFILES.ELF /host/LV" {
		t.Fatalf("exec = %v want GOFILES.ELF /host/LV", calls)
	}
}

func TestLauncherFileOpenFallsBackToReveal(t *testing.T) {
	defer saveSeatState()()
	// An unreadable head (or a type with no handler) opens GOFILES at
	// the containing folder — the drop-open precedent, not a dead verb.
	stubLaunchTree(t, map[string][]vi.DirEntry{
		"/host":    {dirEnt("LV", true)},
		"/host/LV": {dirEnt("BLOB.DAT", false)},
	}, nil)
	launch = launcherState{open: true}
	launch.filter = "blob"
	launch.refresh()
	if len(launch.hits) != 1 {
		t.Fatalf("hits = %v", launch.hits)
	}
	vs := launch.verbsFor(launch.filtered[0])
	if vs[0].name != "open" || vs[0].bin != "GOFILES.ELF" || vs[0].argv[0] != "/host/LV" {
		t.Fatalf("open fallback = %+v want GOFILES /host/LV", vs[0])
	}
}

func TestLauncherHandOffRowExecsGofilesSearch(t *testing.T) {
	defer saveSeatState()()
	stubLauncherWindows(t)
	stubLaunchTree(t, map[string][]vi.DirEntry{"/host": {}}, nil)
	launch = launcherState{}
	openLauncher()
	launch.filter = "zzzqq"
	launch.refresh()
	// Nothing matches: the M165f hand-off row is the only offer, and
	// Enter on it execs GOFILES --search with the query.
	if len(launch.filtered) != 1 || launch.filtered[0] != paletteSearchIdx {
		t.Fatalf("filtered = %v want [search]", launch.filtered)
	}
	calls := []string{}
	oldExec := execApp
	defer func() { execApp = oldExec }()
	execApp = func(bin string, args ...string) (int64, error) {
		calls = append(calls, bin+" "+joinSpace(args))
		return 42, nil
	}
	execSelected()
	if len(calls) != 1 || calls[0] != "GOFILES.ELF --search zzzqq" {
		t.Fatalf("exec = %v want GOFILES.ELF --search zzzqq", calls)
	}
}

func TestLauncherVerbDisarmsOnSelectionMove(t *testing.T) {
	defer saveSeatState()()
	stubLaunchTree(t, map[string][]vi.DirEntry{
		"/host":    {dirEnt("LV", true)},
		"/host/LV": {dirEnt("VERB.TXT", false), dirEnt("VERY.TXT", false)},
	}, map[string]string{
		"/host/LV/VERB.TXT": "a\n", "/host/LV/VERY.TXT": "b\n",
	})
	launch = launcherState{open: true}
	loadLauncherCatalog()
	launch.filter = "ver"
	launch.refresh()
	launch.stepVerb(1)
	if !launch.verbArmed() {
		t.Fatal("verb did not arm")
	}
	launch.sel = 1
	if launch.verbArmed() {
		t.Fatal("a selection move must disarm the verb")
	}
	if launch.effVerb() != 0 {
		t.Fatal("disarmed verb must not commit")
	}
}
