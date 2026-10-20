package main

import (
	"strings"
	"testing"

	"virelai/rss/keys"
	"virelai/vi"
)

// stateModel pins one model's session fields without touching vi — the
// same shape testModel uses (listings are placed directly).
func stateModel(path string, sel, top int, view viewMode, sort sortMode) model {
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false),
		entry("A.TXT", false))
	m.path = path
	m.sel, m.top = sel, top
	m.view, m.sort = view, sort
	return m
}

func TestStateEncodeDecodeRoundTrip(t *testing.T) {
	m := stateModel("/host/FM7/SUB7", 1, 0, viewSplit, sortDirs)
	st, ok := decodeState(m.encodeState())
	if !ok {
		t.Fatal("a freshly encoded blob must decode")
	}
	if st.path != m.path || st.sel != m.sel || st.top != m.top ||
		st.view != m.view || st.sort != m.sort {
		t.Fatalf("round trip mismatch: %#v vs %#v", st, m)
	}
}

func TestStateEncodeNonDefaults(t *testing.T) {
	m := stateModel("/host", 12, 9, viewList, sortSize)
	st, ok := decodeState(m.encodeState())
	if !ok {
		t.Fatal("decode failed on a non-default blob")
	}
	if st.view != viewList || st.sort != sortSize || st.sel != 12 || st.top != 9 {
		t.Fatalf("fields lost: %#v", st)
	}
}

// The blob stays bounded even at the kernel's path cap — the seat's
// 64 KiB envelope is never approached.
func TestStateEncodeIsBounded(t *testing.T) {
	m := stateModel("/"+strings.Repeat("d", maxPath-1), vi.MaxDirEntries-1,
		vi.MaxDirEntries-1, viewList, sortSize)
	if b := m.encodeState(); len(b) > 3+maxPath+stateTail {
		t.Fatalf("blob %d bytes exceeds the framed maximum %d", len(b), 3+maxPath+stateTail)
	} else if len(b) > vi.AppStateMax {
		t.Fatalf("blob %d bytes exceeds the seat cap", len(b))
	}
}

func TestStateDecodeRefusesMalformed(t *testing.T) {
	good := stateModel("/host/FM", 0, 0, viewSplit, sortDirs).encodeState()
	cases := map[string][]byte{
		"empty":          {},
		"short":          {stateFmtVer, 0},
		"bad version":    append([]byte{stateFmtVer + 1}, good[1:]...),
		"plen zero":      {stateFmtVer, 0, 0, 0, 0, 0, 0, 0, 0},
		"plen over cap":  {stateFmtVer, 0, byte(maxPath + 1), '/', 'h'},
		"truncated path": good[:6],
		"trailing junk":  append(append([]byte{}, good...), 0x55),
		"missing tail":   good[:len(good)-2],
		"relative path": func() []byte {
			b := append([]byte{}, good...)
			b[3] = 'x' // overwrite the leading slash
			return b
		}(),
	}
	for name, b := range cases {
		if _, ok := decodeState(b); ok {
			t.Errorf("%s: malformed blob decoded ok", name)
		}
	}
}

// Field values are bounded, not fatal: a cursor or scroll outside the
// listing window clamps to the nearest row, and unknown enum bytes fall
// back to the defaults — a stale-but-well-formed blob degrades cleanly.
func TestStateDecodeClampsFields(t *testing.T) {
	b := stateModel("/host/FM", 0xffff, 0xffff, viewMode(9), sortMode(9)).encodeState()
	st, ok := decodeState(b)
	if !ok {
		t.Fatal("out-of-range fields must clamp, not refuse")
	}
	if st.sel != vi.MaxDirEntries-1 || st.top != vi.MaxDirEntries-1 {
		t.Fatalf("sel/top not clamped: %#v", st)
	}
	if st.view != viewSplit || st.sort != sortDirs {
		t.Fatalf("unknown enums not defaulted: %#v", st)
	}
}

// The saved cwd is probed directory-by-directory: the nearest existing
// parent wins, a mount root stops at the synthetic volumes list, and the
// volumes root is the floor when nothing lists.
func TestResolveStatePathFallsBackToParent(t *testing.T) {
	old := stateDirProbe
	defer func() { stateDirProbe = old }()
	live := map[string]bool{"/host": true, "/host/FM7": true}
	stateDirProbe = func(p string) int64 {
		if live[p] {
			return 0
		}
		return -2 // ENOENT
	}
	got, fell := resolveStatePath("/host/FM7/GONE")
	if got != "/host/FM7" || !fell {
		t.Fatalf("resolve = %q fell=%v, want /host/FM7 true", got, fell)
	}
	got, fell = resolveStatePath("/host/FM7")
	if got != "/host/FM7" || fell {
		t.Fatalf("existing path must not report fallback: %q %v", got, fell)
	}
	// /host itself lists, so a deeper dead path resolves to it, not the
	// volumes floor.
	got, fell = resolveStatePath("/host/GONE/GONE")
	if got != "/host" || !fell {
		t.Fatalf("dead branch must resolve to /host, got %q", got)
	}
	// Nothing lists at all: the volumes root is the floor.
	live = map[string]bool{}
	got, fell = resolveStatePath("/host/GONE/GONE")
	if got != volsPath || !fell {
		t.Fatalf("bottoming out must land on %q, got %q", volsPath, got)
	}
	// A saved usb path with no device lands on the same floor — the mount
	// root stops the walk, never falls through to "/host".
	got, fell = resolveStatePath("/usb1/DOCS")
	if got != volsPath || !fell {
		t.Fatalf("absent usb1 must land on %q, got %q", volsPath, got)
	}
	// The volumes root itself never probes.
	got, fell = resolveStatePath(volsPath)
	if got != volsPath || fell {
		t.Fatalf("volumes root must pass through: %q %v", got, fell)
	}
}

func TestApplyStateClampsToListing(t *testing.T) {
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false)) // n=2
	m.applyState(filesState{path: m.path, sel: 9, top: 9, view: viewList, sort: sortName})
	if m.sel != 1 {
		t.Fatalf("sel clamped to %d, want last row 1", m.sel)
	}
	if m.top != 0 {
		t.Fatalf("top must re-tighten on a short listing, got %d", m.top)
	}
	if m.view != viewList || m.sort != sortName {
		t.Fatalf("view/sort not applied: %d %d", m.view, m.sort)
	}
}

// The volumes root's fixed order is the mount table's — applyState must
// not re-sort it (host stays first, disk second).
func TestApplyStateKeepsVolumesOrder(t *testing.T) {
	m := testModel()
	m.path = volsPath
	m.entries[0] = volEntry(volHost)
	m.entries[1] = volEntry(volDisk)
	m.n = 2
	m.applyState(filesState{path: volsPath, sel: 1, sort: sortName})
	if m.entries[0].NameString() != volHost {
		t.Fatalf("volumes re-sorted: %s first, want %s",
			m.entries[0].NameString(), volHost)
	}
	if m.sel != 1 {
		t.Fatalf("sel=%d want 1", m.sel)
	}
}

// The scroll window keeps the cursor on screen: descending past the
// frame pushes top, ascending back pulls it, and a shrink re-tightens.
func TestEnsureSelVisibleTracksCursor(t *testing.T) {
	var entries []vi.DirEntry
	for i := 0; i < vi.MaxDirEntries; i++ {
		e := entry("F"+string(rune('A'+i%26))+string(rune('0'+i%10)), false)
		entries = append(entries, e)
	}
	m := testModel(entries...)
	m.setSize(16, 8) // bodyRows = 4
	m.moveTo(12)
	if m.top != 9 {
		t.Fatalf("sel=12 at body=4 must scroll top to 9, got %d", m.top)
	}
	m.moveTo(0)
	if m.top != 0 {
		t.Fatalf("sel=0 must pull top back to 0, got %d", m.top)
	}
	// A grown window relaxes the window back over the cursor.
	m.setSize(64, 23)
	if m.top != 0 {
		t.Fatalf("top=%d after the whole listing fits", m.top)
	}
}

func TestSortModesOrderListings(t *testing.T) {
	big := entry("BIG.TXT", false)
	big.Size = 900
	small := entry("AAA.TXT", false)
	small.Size = 1
	m := testModel(big, small, entry("SUB", true))

	// Default: dirs first — this is the gate-pinned order.
	if labelsOf(m.entries[:], m.n)[0] != "SUB/" {
		t.Fatal("sortDirs must put SUB/ first")
	}
	m.sort = sortName
	m.cycleSort() // cycles to sortSize, re-sorts flat by size desc
	if m.sort != sortSize || m.entries[0].NameString() != "BIG.TXT" {
		t.Fatalf("sortSize order wrong: mode=%d first=%s", m.sort, m.entries[0].NameString())
	}
	m.sort = sortSize
	m.cycleSort()
	if m.sort != sortDirs {
		t.Fatalf("cycle from size must land back on dirs, got %d", m.sort)
	}
	// sortName itself: flat order — AAA.TXT before BIG.TXT before SUB/.
	m.sort = sortName
	sortEntries(m.entries[:], m.n, m.sort)
	if labelsOf(m.entries[:], m.n)[0] != "AAA.TXT" {
		t.Fatalf("sortName must interleave dirs by name: %v", labelsOf(m.entries[:], m.n))
	}
}

func TestToggleViewSwapsPanes(t *testing.T) {
	m := testModel(entry("SUB", true))
	m.handleKey(keys.Event{Key: keys.KeyTab})
	if m.view != viewList || m.listCols() != m.cols {
		t.Fatalf("tab must switch to full-width list: view=%d lw=%d", m.view, m.listCols())
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerViewMode+"list") {
		t.Fatalf("viewmode marker missing: %q", got)
	}
	m.handleKey(keys.Event{Key: keys.KeyTab})
	if m.view != viewSplit {
		t.Fatalf("second tab must return to split, got %d", m.view)
	}
}

// viewList renders a full-width frame: exactly rows lines, no pane
// separator, and the preview's accent colour never appears.
func TestRenderViewList(t *testing.T) {
	m := renderModel()
	m.view = viewList
	frame := m.render()
	if strings.Contains(frame, "│") || strings.Contains(frame, testPreviewAccent) {
		t.Fatal("viewList must drop the preview pane entirely")
	}
	lines := visibleLines(frame)
	if len(lines) != m.rows {
		t.Fatalf("viewList frame has %d lines, want %d", len(lines), m.rows)
	}
	for i, ln := range lines {
		if len([]rune(ln)) > m.cols {
			t.Fatalf("line %d overflows the grid: %q", i, ln)
		}
	}
}

// A scrolled frame shows the cursor's window, not the listing head.
func TestRenderScrolledWindow(t *testing.T) {
	var entries []vi.DirEntry
	for i := 0; i < vi.MaxDirEntries; i++ {
		e := entry("ROW"+string(rune('A'+i)), false)
		entries = append(entries, e)
	}
	m := testModel(entries...)
	m.setSize(16, 8) // bodyRows = 4
	m.moveTo(12)     // sel=ROW M -> top=9
	frame := m.render()
	if !strings.Contains(frame, "ROWM") { // entries[12]
		t.Fatal("the scrolled frame must show the cursor's row")
	}
	if strings.Contains(frame, "ROWA") {
		t.Fatal("row 0 must be scrolled out of a top=9 frame")
	}
}
