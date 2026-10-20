// GOTABWM.ELF — M137a (#2771): host tests for the pane tree, the
// sidecar codec, the directional focus chords, and the kind-29
// admission check. The depth-1 invariants are the M62c/M79c tests in
// tabs_test.go and hid_test.go — these cover what the tree adds.
package main

import (
	"testing"

	"virelai/chords"
	"virelai/vi"
)

// openNTabs seeds n strip tabs (ids 4..3+n) with focus on the first —
// the same shape the split tests use.
func openNTabs(s *TabStrip, n int) {
	for i := 0; i < n; i++ {
		if !s.OpenTab(uint32(4+i), "T"+dec(uint32(i))) {
			panic("openNTabs refused")
		}
	}
}

func TestSplitPaneDepthOneMatchesSplitRects(t *testing.T) {
	var s TabStrip
	openNTabs(&s, 2)
	if !s.SplitPane(SplitVert, scanoutW, scanoutH) {
		t.Fatal("SplitPane v")
	}
	panes := s.PaneRectsAll(scanoutW, scanoutH)
	if len(panes) != 2 {
		t.Fatalf("panes = %d want 2", len(panes))
	}
	wantA, wantB, _ := SplitRects(SplitVert, scanoutW, scanoutH)
	if panes[0].rect != wantA || panes[1].rect != wantB {
		t.Fatalf("depth-1 rects %+v want %+v %+v", panes, wantA, wantB)
	}
	if panes[0].id != 4 || panes[1].id != 5 {
		t.Fatalf("leaves = %d,%d want 4,5", panes[0].id, panes[1].id)
	}
}

func TestSplitPaneThreeLeaves(t *testing.T) {
	var s TabStrip
	openNTabs(&s, 3)
	if !s.SplitPane(SplitVert, scanoutW, scanoutH) {
		t.Fatal("split 1")
	}
	// Split the focused pane again: three panes, depth 2.
	if !s.SplitPane(SplitHoriz, scanoutW, scanoutH) {
		t.Fatal("split 2")
	}
	panes := s.PaneRectsAll(scanoutW, scanoutH)
	if len(panes) != 3 {
		t.Fatalf("panes = %d want 3", len(panes))
	}
	// The focused leaf split horizontally inside the left half.
	if panes[0].rect != (Rect{0, 0, 640, 360}) ||
		panes[1].rect != (Rect{0, 360, 640, 360}) ||
		panes[2].rect != (Rect{640, 0, 640, 720}) {
		t.Fatalf("rects = %+v", panes)
	}
	// Leaf order is tree order: focused tab, its new sibling, then the
	// root's B child.
	if panes[0].id != 4 || panes[1].id != 6 || panes[2].id != 5 {
		t.Fatalf("leaves = %d,%d,%d", panes[0].id, panes[1].id, panes[2].id)
	}
}

func TestSplitPaneBounds(t *testing.T) {
	var s TabStrip
	openNTabs(&s, MaxPanes+2)
	if !s.SplitPane(SplitVert, scanoutW, scanoutH) {
		t.Fatal("split 1")
	}
	// Pane cap: split until 8 leaves.
	for s.leafCount() < MaxPanes {
		// Splitting the same leaf alternates its depth; pick the first
		// leaf at splittable depth each pass.
		done := true
		for i := 0; i < s.count; i++ {
			_ = s.FocusTab(s.tabs[i].ID)
			if li := s.leafOf(s.tabs[i].ID); li >= 0 &&
				s.treeDepth(li) <= MaxTreeDepth {
				if s.SplitPane(SplitVert, scanoutW, scanoutH) {
					done = false
					break
				}
			}
		}
		if done {
			break
		}
	}
	if s.leafCount() != MaxPanes {
		t.Fatalf("leaves = %d want %d", s.leafCount(), MaxPanes)
	}
	// The 9th pane must refuse.
	if s.SplitPane(SplitVert, scanoutW, scanoutH) {
		t.Fatal("9th pane split must refuse")
	}
	// Depth bound: walk until no leaf splits — every leaf at depth 4.
	deepest := 0
	for i := 0; i < s.treeN; i++ {
		if d := s.treeDepth(i); d > deepest {
			deepest = d
		}
	}
	if deepest > MaxTreeDepth+1 {
		t.Fatalf("depth = %d > %d", deepest, MaxTreeDepth+1)
	}
}

func TestPaneFocusMoveGeometry(t *testing.T) {
	var s TabStrip
	openNTabs(&s, 3)
	if !s.SplitPane(SplitVert, scanoutW, scanoutH) {
		t.Fatal("split v")
	}
	// Focus the right pane, split it horizontally: t1 over t2.
	_ = s.FocusTab(5)
	if !s.SplitPane(SplitHoriz, scanoutW, scanoutH) {
		t.Fatal("split h on right")
	}
	// Tree: [4 | (5 / 6)]. Focus 5 (top-right).
	if _, ok := s.paneFocusMove(1, 0, scanoutW, scanoutH); ok {
		t.Fatal("right of rightmost must refuse")
	}
	id, ok := s.paneFocusMove(-1, 0, scanW(scanoutW), scanH(scanoutH))
	if !ok || id != 4 {
		t.Fatalf("left = %v,%v want 4,true", id, ok)
	}
	if id, ok = s.paneFocusMove(0, 1, scanoutW, scanoutH); !ok || id != 6 {
		t.Fatalf("down = %v want 6", id)
	}
	// From 4 (left, full height): right must pick a RIGHT pane — the
	// overlap rule prefers 5 (top) or 6 (bottom); either is honest
	// (both share equal vertical overlap) — nearest wins: equal gap,
	// first-seed order. Pin the honest answer: 5.
	if id, ok = s.paneFocusMoveFrom(4, 1, 0); !ok || id != 5 {
		t.Fatalf("right from left = %v want 5", id)
	}
	// No tree: every direction refuses.
	var u TabStrip
	openNTabs(&u, 2)
	if _, ok := u.paneFocusMove(-1, 0, scanoutW, scanoutH); ok {
		t.Fatal("unsplit pane-focus must refuse")
	}
}

// paneFocusMoveFrom is paneFocusMove with an explicit focus — the pure
// geometry half of the chord, no focusByIndex seam needed.
func (s *TabStrip) paneFocusMoveFrom(tabID uint32, dx, dy int) (uint32, bool) {
	_ = s.FocusTab(tabID)
	return s.paneFocusMove(dx, dy, scanoutW, scanoutH)
}

func scanW(v int) uint32 { return uint32(v) }
func scanH(v int) uint32 { return uint32(v) }

func TestPaneSidecarRoundTrip(t *testing.T) {
	var s TabStrip
	openNTabs(&s, 3)
	if !s.SplitPane(SplitVert, scanoutW, scanoutH) {
		t.Fatal("split v")
	}
	_ = s.FocusTab(5)
	if !s.SplitPane(SplitHoriz, scanoutW, scanoutH) {
		t.Fatal("split h")
	}
	// Set a sash on the root so the blob carries it.
	if !s.SetSash(800, scanoutW, scanoutH) {
		t.Fatal("SetSash")
	}
	blob, ok := s.encodePanes()
	if !ok {
		t.Fatal("encodePanes")
	}
	var u TabStrip
	openNTabs(&u, 3)
	if !u.decodePanes(blob) {
		t.Fatal("decodePanes")
	}
	if u.leafCount() != 3 || u.tree[0].sash != 800 {
		t.Fatalf("decoded leaves=%d sash=%d", u.leafCount(), u.tree[0].sash)
	}
	p := u.PaneRectsAll(scanoutW, scanoutH)
	q := s.PaneRectsAll(scanoutW, scanoutH)
	if len(p) != len(q) {
		t.Fatalf("round-trip panes %d want %d", len(p), len(q))
	}
	for i := range p {
		if p[i].id != q[i].id || p[i].rect != q[i].rect {
			t.Fatalf("pane %d round-trip %+v want %+v", i, p[i], q[i])
		}
	}
}

func TestPaneSidecarBadBytesRefuse(t *testing.T) {
	var s TabStrip
	openNTabs(&s, 2)
	if s.decodePanes([]byte("garbage")) {
		t.Fatal("garbage must refuse")
	}
	if !s.SplitPane(SplitVert, scanoutW, scanoutH) {
		t.Fatal("split v")
	}
	okBlob, encOk := s.encodePanes()
	if !encOk {
		t.Fatal("encode")
	}
	// Truncation refuses.
	var u TabStrip
	openNTabs(&u, 2)
	if u.decodePanes(okBlob[:len(okBlob)-2]) {
		t.Fatal("truncated blob must refuse")
	}
	// A leaf index past the record count refuses.
	bad := append([]byte(nil), okBlob...)
	bad[len(bad)-1] = 9
	if u.decodePanes(bad) {
		t.Fatal("out-of-range leaf index must refuse")
	}
}

func TestPaneSidecarWriteDelete(t *testing.T) {
	defer saveSeatState()()
	openTwoTabs(t)
	calls, restore := rectRecorder()
	defer restore()
	_ = calls
	var written []string
	var deleted []string
	savedWrite, savedDel := writeHostFile, panesDelete
	t.Cleanup(func() { writeHostFile, panesDelete = savedWrite, savedDel })
	writeHostFile = func(path string, data []byte) bool {
		written = append(written, path)
		return true
	}
	panesDelete = func(path string) int64 {
		deleted = append(deleted, path)
		return 0
	}
	if !applySplit(SplitVert) {
		t.Fatal("applySplit")
	}
	found := false
	for _, p := range written {
		if p == panesPath {
			found = true
		}
	}
	if !found {
		t.Fatal("split must publish SESSION.PANES")
	}
	if !applyUnsplit() {
		t.Fatal("unsplit")
	}
	for _, p := range deleted {
		if p == panesPath {
			return
		}
	}
	t.Fatal("unsplit must delete the sidecar")
}

// TestAgentInputDeniedNotAgentd is the kind-29 sender check: a bound
// request from a pid whose proc name is not AGENTD.ELF is refused with
// the R2 marker and the denial rides the ack title.
func TestAgentInputDeniedNotAgentd(t *testing.T) {
	defer saveSeatState()()
	savedName := agentProcName
	t.Cleanup(func() { agentProcName = savedName })
	agentProcName = func(pid uint32) (string, bool) {
		return "GOEDIT.ELF", true
	}
	var sent [][]byte
	savedSend := agentIpcSend
	t.Cleanup(func() { agentIpcSend = savedSend })
	agentIpcSend = func(pid uint32, b []byte) int64 {
		sent = append(sent, append([]byte(nil), b...))
		return int64(len(b))
	}
	var req vi.WmRpc
	req.Kind = wmKindAgentInput
	req.ID = 7
	req.ReplyTo = 42
	req.Title[0] = agentEvKey
	req.Title[2] = 0x28 // enter
	serveAgentInput(req, 0)
	if len(sent) != 1 {
		t.Fatalf("acks = %d want 1", len(sent))
	}
	rep, ok := vi.DecodeWmRpc(sent[0])
	if !ok {
		t.Fatal("ack decode")
	}
	if rep.Applied != 0 {
		t.Fatal("denied request must not apply")
	}
	if rep.TitleString() != agentRefuseDenied {
		t.Fatalf("ack title = %q want %q", rep.TitleString(), agentRefuseDenied)
	}
}

// TestAgentInputNoFocus covers the other R2 refusal: a well-formed
// request from AGENTD with no live focused pane.
func TestAgentInputNoFocus(t *testing.T) {
	defer saveSeatState()()
	savedName := agentProcName
	t.Cleanup(func() { agentProcName = savedName })
	agentProcName = func(pid uint32) (string, bool) {
		return "AGENTD.ELF", true
	}
	savedSend := agentIpcSend
	t.Cleanup(func() { agentIpcSend = savedSend })
	var sent [][]byte
	agentIpcSend = func(pid uint32, b []byte) int64 {
		sent = append(sent, append([]byte(nil), b...))
		return int64(len(b))
	}
	// Empty strip: no focused pane at all.
	for tabs.Count() > 0 {
		_ = tabs.CloseTab(tabs.At(0).ID)
	}
	var req vi.WmRpc
	req.Kind = wmKindAgentInput
	req.ID = 9
	req.ReplyTo = 42
	req.Title[0] = agentEvPtr
	req.Title[2] = 100
	req.Title[4] = 100
	serveAgentInput(req, 0)
	if len(sent) != 1 {
		t.Fatalf("acks = %d want 1", len(sent))
	}
	rep, _ := vi.DecodeWmRpc(sent[0])
	if rep.Applied != 0 || rep.TitleString() != agentRefuseNoFocus {
		t.Fatalf("ack applied=%d title=%q want 0/%q",
			rep.Applied, rep.TitleString(), agentRefuseNoFocus)
	}
}

// TestAgentInputDeliversThroughSeatPath checks the admitted half: an
// AGENTD key lands on consumeSeatEvent's own dispatch — observable as a
// pane-focus chord actually moving focus.
func TestAgentInputDeliversChord(t *testing.T) {
	defer saveSeatState()()
	openTwoTabs(t)
	calls, restore := rectRecorder()
	defer restore()
	_ = calls
	if !applySplit(SplitVert) {
		t.Fatal("applySplit")
	}
	savedName := agentProcName
	t.Cleanup(func() { agentProcName = savedName })
	agentProcName = func(pid uint32) (string, bool) {
		return "AGENTD.ELF", true
	}
	savedSend := agentIpcSend
	t.Cleanup(func() { agentIpcSend = savedSend })
	agentIpcSend = func(pid uint32, b []byte) int64 { return int64(len(b)) }
	indices, restore := focusIndexRecorder()
	defer restore()
	// A ctrl+alt+left key: the pane-focus chord reaches the seat's own
	// dispatch path.
	var req vi.WmRpc
	req.Kind = wmKindAgentInput
	req.ID = 4
	req.ReplyTo = 42
	req.Title[0] = agentEvKey
	req.Title[1] = byte(vi.ModCtrl | vi.ModAlt)
	req.Title[2] = chords.UsageRight
	serveAgentInput(req, 0)
	if len(*indices) != 1 || (*indices)[0] != 1 {
		t.Fatalf("pane-focus landed on %v want [1]", *indices)
	}
}
