package main

// M137c (#2773): spaces — named tab groups. Host tests pin the switch
// semantics (create-on-next, clamp, cap), the palette move, the summon
// chord's focus-vs-exec split, and the session/sidecar round-trips that
// make a snapshot restore bring back every space.

import (
	"testing"

	"virelai/vi"
)

// visRecorder stubs the wmctl_set_state seam so host tests see the
// hide/show calls a space switch issues.
func visRecorder() (*[][2]uint32, func()) {
	calls := &[][2]uint32{}
	prev := wmctlSetVisible
	wmctlSetVisible = func(id uint32, visible bool) int64 {
		*calls = append(*calls, [2]uint32{id, boolUint(visible)})
		return 0
	}
	return calls, func() { wmctlSetVisible = prev }
}

func boolUint(b bool) uint32 {
	if b {
		return 1
	}
	return 0
}

func TestSpaceSwitchCreatesAndParks(t *testing.T) {
	defer saveSeatState()()
	resetSpaces()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") || !tabs.FocusTab(4) {
		t.Fatal("seed")
	}
	vis, restore := visRecorder()
	defer restore()

	// PageUp at space "1" clamps — no switch, no create.
	if applySpaceSwitch(-1) {
		t.Fatal("space-prev must clamp at the first space")
	}
	if spaceN != 1 || spaceCur != 0 {
		t.Fatalf("clamp mutated: n=%d cur=%d", spaceN, spaceCur)
	}

	// PageDown creates space "2" and lands on its empty strip.
	if !applySpaceSwitch(1) {
		t.Fatal("space-next must create space 2")
	}
	if spaceN != 2 || spaceCur != 1 || spaces[1].Name != "2" {
		t.Fatalf("create: n=%d cur=%d", spaceN, spaceCur)
	}
	if tabs.Count() != 0 {
		t.Fatal("new space must be an empty strip")
	}
	if spaces[0].Strip.Count() != 2 || spaces[0].Strip.focus != 1 {
		t.Fatalf("parked strip lost state: n=%d focus=%d",
			spaces[0].Strip.Count(), spaces[0].Strip.focus)
	}
	// The outgoing windows hide; the new space has none to show.
	if len(*vis) != 2 || (*vis)[0][1] != 0 || (*vis)[1][1] != 0 {
		t.Fatalf("hide calls: %v", *vis)
	}

	// PageUp restores the parked strip verbatim.
	if !applySpaceSwitch(-1) || spaceCur != 0 || tabs.Count() != 2 {
		t.Fatal("space-prev must restore the parked strip")
	}
	if id, ok := tabs.Focused(); !ok || id != 4 {
		t.Fatalf("restored focus: %v", id)
	}
	// Back: 2 shows + focus raise? focusRaise is the real seam here —
	// off-guest it returns -ENOSYS so hostedApp stays 0; only the
	// visibility calls are pinned.
	if len(*vis) != 4 || (*vis)[2][1] != 1 || (*vis)[3][1] != 1 {
		t.Fatalf("show calls: %v", *vis)
	}
}

func TestSpaceCapIsFour(t *testing.T) {
	defer saveSeatState()()
	resetSpaces()
	tabs = TabStrip{}
	_, restore := visRecorder()
	defer restore()
	for i := 0; i < 3; i++ {
		if !applySpaceSwitch(1) {
			t.Fatalf("create space %d", i+2)
		}
	}
	if spaceN != MaxSpaces {
		t.Fatalf("spaceN=%d want %d", spaceN, MaxSpaces)
	}
	if applySpaceSwitch(1) {
		t.Fatal("a fifth space must refuse")
	}
	if spaceN != MaxSpaces || spaceCur != MaxSpaces-1 {
		t.Fatalf("cap: n=%d cur=%d", spaceN, spaceCur)
	}
}

func TestSpaceMoveCarriesTab(t *testing.T) {
	defer saveSeatState()()
	resetSpaces()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "Calc") || !tabs.OpenTab(4, "Edit") || !tabs.FocusTab(4) {
		t.Fatal("seed")
	}
	tabs.tabs[1].Pinned = true
	tabs.tabs[1].Bin = "GOEDIT.ELF"
	vis, restore := visRecorder()
	defer restore()

	// Move to the not-yet-created "2" — the palette's own create path.
	if !applySpaceMove(4, "2") {
		t.Fatal("move must create + carry")
	}
	if spaceN != 2 || spaceCur != 0 {
		t.Fatalf("move created: n=%d cur=%d", spaceN, spaceCur)
	}
	if tabs.Count() != 1 || tabs.At(0).ID != 3 {
		t.Fatalf("source strip: %d tabs", tabs.Count())
	}
	dst := &spaces[1].Strip
	if dst.Count() != 1 || dst.tabs[0].Bin != "GOEDIT.ELF" || !dst.tabs[0].Pinned {
		t.Fatalf("carried tab: %+v", dst.tabs[0])
	}
	if dst.focus != 0 {
		t.Fatal("moved tab takes the destination focus")
	}
	if len(*vis) != 1 || (*vis)[0] != [2]uint32{4, 0} {
		t.Fatalf("moved window must hide: %v", *vis)
	}
	// Moving to the current space refuses; unknown tab refuses.
	if applySpaceMove(3, "1") {
		t.Fatal("same-space move must refuse")
	}
	if applySpaceMove(99, "2") {
		t.Fatal("unknown id must refuse")
	}
	// From space "2", moving to dormant "1" hides the window and lands
	// the tab — round-trip through the destination side.
	if !spaceSwitchTo(1) {
		t.Fatal("switch to 2")
	}
	*vis = nil
	if !applySpaceMove(4, "1") {
		t.Fatal("move to dormant space must land")
	}
	if spaces[0].Strip.Count() != 2 || tabs.Count() != 0 {
		t.Fatalf("round-trip: space1=%d space2=%d",
			spaces[0].Strip.Count(), tabs.Count())
	}
	if len(*vis) != 1 || (*vis)[0] != [2]uint32{4, 0} {
		t.Fatalf("moved window must hide: %v", *vis)
	}
}

func TestSummonEmojiFocusesThenExecs(t *testing.T) {
	defer saveSeatState()()
	resetSpaces()
	tabs = TabStrip{}
	_, restoreVis := visRecorder()
	defer restoreVis()
	execs, restoreExec := execRecorder()
	defer restoreExec()

	// Absent: the named exec path (off-guest the recorder accepts — the
	// refusal marker is a guest-side gate target).
	if !applySummonEmoji() || len(*execs) != 1 || (*execs)[0] != "GOEMOJI.ELF" {
		t.Fatalf("absent summon must exec by name: %v", *execs)
	}

	// Present on a dormant space: the summon jumps spaces and focuses.
	spaceEnsure("2")
	spaces[1].Strip = TabStrip{}
	spaces[1].Strip.OpenTab(7, "Emoji")
	spaces[1].Strip.tabs[0].Bin = "GOEMOJI.ELF"
	focused := uint32(0)
	prev := summonFocus
	summonFocus = func(id uint32) bool { focused = id; return true }
	defer func() { summonFocus = prev }()
	if !applySummonEmoji() {
		t.Fatal("dormant summon must switch + focus")
	}
	if spaceCur != 1 {
		t.Fatalf("summon must land on the hosting space: cur=%d", spaceCur)
	}
	if focused != 7 {
		t.Fatalf("summon must focus the emoji tab: %d", focused)
	}
	if len(*execs) != 1 {
		t.Fatalf("a hosted GOEMOJI must not re-exec: %v", *execs)
	}
}

func TestSpacesSessionRoundTrip(t *testing.T) {
	defer saveSeatState()()
	resetSpaces()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "Calc") || !tabs.OpenTab(4, "Note") || !tabs.FocusTab(3) {
		t.Fatal("seed space 1")
	}
	spaceEnsure("2")
	spaces[1].Strip = TabStrip{}
	if !spaces[1].Strip.OpenTab(9, "Edit") {
		t.Fatal("seed space 2")
	}
	spaces[1].Strip.tabs[0].Bin = "GOEDIT.ELF"
	spaces[1].Strip.tabs[0].Pinned = true

	recs, active, ok := sessionRecordsV2()
	if !ok || len(recs) != 3 {
		t.Fatalf("records: n=%d ok=%v", len(recs), ok)
	}
	if recs[0].Group != "1" || recs[2].Group != "2" {
		t.Fatalf("groups: %q %q %q", recs[0].Group, recs[1].Group, recs[2].Group)
	}
	// Active names the live space's focused record — Calc at index 0.
	if active != 0 {
		t.Fatalf("active=%d want 0 (focused record's global index)", active)
	}
	raw, dropped, ok := encodeRecordsV2(7, recs, active)
	if !ok || len(dropped) != 0 {
		t.Fatalf("encode: ok=%v dropped=%v", ok, dropped)
	}

	// Decode into a fresh table: two spaces, live = "1" (the active
	// record's group), titles/pins/bins intact, placeholder ids global.
	saved := tabs
	seq, ok := applySpacesV2(raw)
	if !ok {
		t.Fatal("applySpacesV2")
	}
	if seq != 7 {
		t.Fatalf("seq=%d", seq)
	}
	if spaceN != 2 || spaceCur != 0 || spaces[0].Name != "1" || spaces[1].Name != "2" {
		t.Fatalf("table: n=%d cur=%d names=%q,%q", spaceN, spaceCur,
			spaces[0].Name, spaces[1].Name)
	}
	if tabs.Count() != 2 || tabs.At(0).Title != "Calc" {
		t.Fatalf("live strip: %+v", tabs.tabs[:tabs.count])
	}
	d2 := spaces[1].Strip
	if d2.Count() != 1 || d2.tabs[0].ID != sessionIDBase+2 ||
		!d2.tabs[0].Pinned || d2.tabs[0].Bin != "GOEDIT.ELF" {
		t.Fatalf("dormant strip: %+v", d2.tabs[0])
	}
	// A hand-filed fifth group name refuses whole — fail closed.
	recs[0].Group = "a"
	bad, _, _ := encodeRecordsV2(1, append(recs,
		tabsV2Record{Title: "X", Group: "b"},
		tabsV2Record{Title: "Y", Group: "c"},
		tabsV2Record{Title: "Z", Group: "5"}), 0)
	if _, ok := applySpacesV2(bad); ok {
		t.Fatal("a fifth space must refuse")
	}
	if spaceN != 1 || tabs.Count() != 0 {
		t.Fatal("refused decode must leave a clean table")
	}
	_ = saved
}

func TestPanesSpacesRoundTrip(t *testing.T) {
	defer saveSeatState()()
	resetSpaces()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("seed")
	}
	// Give space "1" a real tree: split the focused pane vertically.
	if !tabs.SplitPane(SplitVert, scanoutW, scanoutH) {
		t.Fatal("split")
	}
	spaceEnsure("2")
	spaces[1].Strip = TabStrip{}
	if !spaces[1].Strip.OpenTab(9, "C") {
		t.Fatal("seed 2")
	}
	// And an empty space "3" — the sidecar must carry its name even
	// though no record names it.
	spaceEnsure("3")

	blob := encodePanesSpaces()
	if blob[0] != panesMagic0 || blob[1] != panesMagic1 ||
		blob[2] != panesVerSpaces || blob[3] != 3 || blob[4] != 1 {
		t.Fatalf("v2 header: %v", blob[:5])
	}

	// Fresh decode path: applySpacesV2 first (records carry groups for
	// populated spaces only), then the sidecar fills names/trees/current.
	recs, active, ok := sessionRecordsV2()
	if !ok {
		t.Fatal("records")
	}
	raw, _, _ := encodeRecordsV2(1, recs, active)
	resetSpaces()
	tabs = TabStrip{}
	if _, ok := applySpacesV2(raw); !ok {
		t.Fatal("applySpacesV2")
	}
	if spaceN != 2 {
		t.Fatalf("records alone restore %d spaces (empty one waits for the sidecar)", spaceN)
	}
	if !decodePanesSpaces(blob) {
		t.Fatal("decodePanesSpaces")
	}
	if spaceN != 3 || spaces[2].Name != "3" {
		t.Fatalf("sidecar must restore the empty space: n=%d", spaceN)
	}
	if tabs.treeN == 0 || tabs.leafCount() != 2 {
		t.Fatalf("space 1's tree: nodes=%d leaves=%d", tabs.treeN, tabs.leafCount())
	}
	if spaces[1].Strip.treeN != 0 {
		t.Fatal("space 2 keeps the unsplit shape")
	}
	// cur=0 → still live on space "1".
	if spaceCur != 0 {
		t.Fatalf("cur=%d", spaceCur)
	}
	// Corrupt tail refuses whole.
	if decodePanesSpaces(append(append([]byte{}, blob...), 0xAA)) {
		t.Fatal("trailing garbage must refuse")
	}
}

func TestV1PanesSidecarStillReads(t *testing.T) {
	defer saveSeatState()()
	resetSpaces()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("seed")
	}
	if !tabs.SplitPane(SplitHoriz, scanoutW, scanoutH) {
		t.Fatal("split")
	}
	b, ok := tabs.encodePanes()
	if !ok || b[2] != panesVer {
		t.Fatal("v1 encode")
	}
	// Fresh strip, same record positions.
	tabs2 := TabStrip{}
	tabs2.OpenTab(sessionIDBase+0, "A")
	tabs2.OpenTab(sessionIDBase+1, "B")
	if !tabs2.decodePanes(b) || tabs2.leafCount() != 2 {
		t.Fatal("v1 decode must still work")
	}
}

func TestRailMarkerCarriesSpaceName(t *testing.T) {
	defer saveSeatState()()
	resetSpaces()
	_, restore := visRecorder()
	defer restore()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "A") {
		t.Fatal("seed")
	}
	spaceEnsure("2")
	spaces[1].Strip = TabStrip{}
	if !spaces[1].Strip.OpenTab(9, "B") {
		t.Fatal("seed 2")
	}
	// The marker's space field is the serial-observable half of "the rail
	// draws the current space's name" — the pixel half is paintRail's
	// right-edge chip (drawn only when spaceN > 1).
	markRail()
	// Switching back and forth must re-emit even when n/focus repeat.
	if !spaceSwitchTo(1) {
		t.Fatal("switch")
	}
	markRail()
	if lastRailSpace != 1 {
		t.Fatalf("markRail space dedup: %d", lastRailSpace)
	}
}

// M151b (#2913): the pill strip's hit test mirrors the paint — both share
// spacePillRects, so the pinned geometry IS the contract: pills right-
// aligned in live-space order, per-pill containment with the gaps,
// below-band and left-of-strip misses, and the two refusal shapes (a
// single-space desktop paints no pills; an empty strip paints no rail).
func TestSpacePillAtMirrorsPaint(t *testing.T) {
	defer saveSeatState()()
	resetSpaces()
	tabs = TabStrip{}
	if !tabs.OpenTab(3, "A") || !tabs.OpenTab(4, "B") {
		t.Fatal("OpenTab")
	}
	if _, ok := spacePillAt(1279, 11, 1280, 22); ok {
		t.Fatal("a single-space rail has no pill targets")
	}
	spaceEnsure("2")
	spaceEnsure("3")
	pills, n := spacePillRects(1280, 22)
	if n != 3 {
		t.Fatalf("pills=%d want 3", n)
	}
	// Live-space order left to right, all inside the rail's right edge.
	if !(pills[0].X < pills[1].X && pills[1].X < pills[2].X) {
		t.Fatalf("pill order drifts: %v", pills)
	}
	if pills[2].X+pills[2].W > 1280 || pills[0].X < 0 {
		t.Fatalf("pills escape the rail: %v", pills)
	}
	for si := 0; si < n; si++ {
		r := pills[si]
		if got, ok := spacePillAt(uint32(r.X+r.W/2), uint32(r.Y+r.H/2), 1280, 22); !ok || got != si {
			t.Fatalf("pill %d centre hit got=%d ok=%v", si, got, ok)
		}
	}
	// The inter-pill gap, the rows outside the pill band, and the
	// trough left of the strip are all non-targets.
	if _, ok := spacePillAt(uint32(pills[0].X+pills[0].W+1), 11, 1280, 22); ok {
		t.Fatal("the inter-pill gap must miss")
	}
	if _, ok := spacePillAt(uint32(pills[1].X+2), uint32(pills[1].Y-1), 1280, 22); ok {
		t.Fatal("above the pill band must miss")
	}
	if _, ok := spacePillAt(uint32(pills[0].X-1), 11, 1280, 22); ok {
		t.Fatal("left of the pill strip must miss")
	}
	// An empty live strip paints no rail (paintRail's early return), so
	// the pill zone is not a target either — honesty with the scanout.
	tabs = TabStrip{}
	if _, ok := spacePillAt(uint32(pills[1].X+2), 11, 1280, 22); ok {
		t.Fatal("an empty strip has no pills to hit")
	}
}

// M151b (#2913): a pointer press on a dormant space's pill runs the same
// switch the chord runs — the parked strip, the visibility flips, the
// landed focus — and wins over the close zone it overlaps. A press on the
// LIVE space's pill is the consumed no-op: the pick marker prints (the
// gesture happened), the switch refuses. No rail drag arms either way.
func TestHandleWmPointerSpacePillSwitches(t *testing.T) {
	defer saveSeatState()()
	resetSpaces()
	tabs = TabStrip{}
	prevPtrButtons = 0
	railDragFrom = -1
	hostedApp = 0
	if !tabs.OpenTab(3, "Calc") || !tabs.OpenTab(4, "Edit") || !tabs.FocusTab(4) {
		t.Fatal("seed")
	}
	spaceEnsure("2")
	spaces[1].Strip = TabStrip{}
	if !spaces[1].Strip.OpenTab(9, "Term") {
		t.Fatal("seed space 2")
	}
	vis, restoreVis := visRecorder()
	defer restoreVis()
	closed := []uint32{}
	prevClose := closeWin
	closeWin = func(id uint32) int64 { closed = append(closed, id); return 0 }
	defer func() { closeWin = prevClose }()

	pills, n := spacePillRects(vi.ScanoutWidth, RailHeight)
	if n != 2 {
		t.Fatalf("pills=%d want 2", n)
	}
	// Pill 2's centre sits inside the last cell's close zone at this
	// geometry (the pill ends 4 px short of the edge) — the overlap is
	// the point: the pill wins because it is painted on top.
	cx := uint32(pills[1].X + pills[1].W/2)
	cy := uint32(pills[1].Y + pills[1].H/2)
	handleWmPointer(ptrEvent(cx, cy, hidBtnLeft))
	if railDragFrom != -1 {
		t.Fatalf("a pill press armed a rail drag: %d", railDragFrom)
	}
	handleWmPointer(ptrEvent(cx, cy, 0))
	if spaceCur != 1 || tabs.Count() != 1 || tabs.At(0).ID != 9 {
		t.Fatalf("pill click: cur=%d live n=%d", spaceCur, tabs.Count())
	}
	if spaces[0].Strip.Count() != 2 {
		t.Fatal("the outgoing strip did not park")
	}
	if len(*vis) != 3 || (*vis)[0] != [2]uint32{3, 0} || (*vis)[1] != [2]uint32{4, 0} ||
		(*vis)[2] != [2]uint32{9, 1} {
		t.Fatalf("switch visibility calls: %v", *vis)
	}
	if len(closed) != 0 {
		t.Fatalf("the pill's close-zone overlap closed %v", closed)
	}
	if id, _ := tabs.Focused(); id != 9 {
		t.Fatalf("landed focus %d want the space's recorded focus 9", id)
	}
	// The live space's own pill: the press is still consumed (no drag,
	// no close, no content forward) and the switch refuses — cur holds.
	handleWmPointer(ptrEvent(cx, cy, hidBtnLeft))
	handleWmPointer(ptrEvent(cx, cy, 0))
	if spaceCur != 1 {
		t.Fatalf("live-pill click switched to %d", spaceCur)
	}
	if railDragFrom != -1 || len(closed) != 0 {
		t.Fatalf("live-pill click leaked: drag=%d closed=%v", railDragFrom, closed)
	}
}
