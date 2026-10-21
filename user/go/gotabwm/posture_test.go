// GOTABWM.ELF — M151a (#2912): host tests for pane posture — the zoom
// posture and its auto-restore on every tree mutation, the rail-drag
// drop hit-test and swap/displace rules, and the MRU focus ring's order
// and bound.
package main

import "testing"

// --- Zoom -----------------------------------------------------------------

func TestZoomFocusedRefusals(t *testing.T) {
	var s TabStrip
	openNTabs(&s, 2)
	// No tree: the focused tab holds no leaf.
	if s.ZoomFocused() {
		t.Fatal("zoom on an unsplit strip must refuse")
	}
	if !s.SplitPane(SplitVert, scanoutW, scanoutH) {
		t.Fatal("split")
	}
	if !s.ZoomFocused() {
		t.Fatal("zoom on a two-pane tree")
	}
	if s.zoomTab != 4 {
		t.Fatalf("zoomTab = %d want 4 (focused)", s.zoomTab)
	}
	// A standing zoom refuses a second zoom.
	if s.ZoomFocused() {
		t.Fatal("double zoom must refuse")
	}
	// Focused but unplaced: a strip where the focus has no leaf.
	var u TabStrip
	openNTabs(&u, 3)
	if !u.SplitPane(SplitVert, scanoutW, scanoutH) {
		t.Fatal("split")
	}
	if !u.FocusTab(6) { // tab 6 was never placed
		t.Fatal("focus unplaced")
	}
	if u.ZoomFocused() {
		t.Fatal("zoom of an unplaced focused tab must refuse")
	}
}

func TestZoomAutoRestoreOnMutations(t *testing.T) {
	// Every tree mutation restores the zoom — the zoomed flag clears on
	// the state machine itself so a parked pane is never re-laid under.
	cases := []struct {
		name  string
		setup func(s *TabStrip) // must leave 4,5 placed in a v split
		mut   func(s *TabStrip) bool
	}{
		{"split", nil, func(s *TabStrip) bool {
			// A second split needs a third unplaced tab — provided by
			// the setup below that opens 3.
			return s.SplitPane(SplitHoriz, scanoutW, scanoutH)
		}},
		{"unsplit", nil, func(s *TabStrip) bool { return s.Unsplit() }},
		{"unsplit-pane", nil, func(s *TabStrip) bool { return s.UnsplitPane() }},
		{"rotate", nil, func(s *TabStrip) bool { return s.RotatePane(scanoutW, scanoutH) }},
		{"sash", nil, func(s *TabStrip) bool { return s.SetSash(400, scanoutW, scanoutH) }},
		{"reorder", nil, func(s *TabStrip) bool { return s.Reorder(0, 1) }},
		{"drop", nil, func(s *TabStrip) bool {
			// 6 is the unplaced tab openNTabs left; it takes 5's leaf.
			return s.paneDrop(6, s.leafOf(5))
		}},
		{"close", nil, func(s *TabStrip) bool { return s.CloseTab(5) }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var s TabStrip
			openNTabs(&s, 3)
			if !s.SplitPane(SplitVert, scanoutW, scanoutH) {
				t.Fatal("split")
			}
			if c.setup != nil {
				c.setup(&s)
			}
			if !s.ZoomFocused() {
				t.Fatal("zoom")
			}
			if !c.mut(&s) {
				t.Fatalf("%s mutation refused", c.name)
			}
			if s.zoomTab != 0 {
				t.Fatalf("%s left zoomTab=%d — the zoom must restore", c.name, s.zoomTab)
			}
		})
	}
}

// --- Drag into a pane -----------------------------------------------------

func TestLeafHitAt(t *testing.T) {
	var s TabStrip
	openNTabs(&s, 2)
	// No tree: nothing is a drop target.
	if _, ok := s.leafHitAt(320, 400, scanoutW, scanoutH); ok {
		t.Fatal("no tree must refuse")
	}
	if !s.SplitPane(SplitVert, scanoutW, scanoutH) {
		t.Fatal("split")
	}
	// Left pane is leaf for tab 4 at x<640; right is 5.
	li, ok := s.leafHitAt(320, 400, scanoutW, scanoutH)
	if !ok || s.tree[li].tab != 4 {
		t.Fatalf("left hit = %d,%v want leaf of 4", li, ok)
	}
	if li, ok = s.leafHitAt(960, 400, scanoutW, scanoutH); !ok || s.tree[li].tab != 5 {
		t.Fatalf("right hit = %d,%v want leaf of 5", li, ok)
	}
	// Chrome guards: the rail band and the bottom 22 px are never panes.
	if _, ok := s.leafHitAt(320, 8, scanoutW, scanoutH); ok {
		t.Fatal("rail band must refuse")
	}
	if _, ok := s.leafHitAt(320, 710, scanoutW, scanoutH); ok {
		t.Fatal("bottom chrome must refuse")
	}
	// A dragged sash leaves a real gutter — a release inside it is not
	// a drop.
	if !s.SetSash(400, scanoutW, scanoutH) {
		t.Fatal("set sash")
	}
	if _, ok := s.leafHitAt(400, 400, scanoutW, scanoutH); ok {
		t.Fatal("sash gutter must refuse")
	}
}

func TestPaneDropSwapAndDisplace(t *testing.T) {
	var s TabStrip
	openNTabs(&s, 3)
	if !s.SplitPane(SplitVert, scanoutW, scanoutH) {
		t.Fatal("split")
	}
	la, lb := s.leafOf(4), s.leafOf(5)
	// Same-leaf release is a no-op.
	if s.paneDrop(4, la) {
		t.Fatal("same-leaf drop must refuse")
	}
	// Swap: tab 4 takes 5's leaf, 5 takes 4's.
	if !s.paneDrop(4, lb) {
		t.Fatal("swap drop")
	}
	if s.tree[lb].tab != 4 || s.tree[la].tab != 5 {
		t.Fatalf("swap: leafA=%d leafB=%d want 5,4", s.tree[la].tab, s.tree[lb].tab)
	}
	// Displace: unplaced 6 takes 4's (new) leaf; 4 returns unplaced.
	if !s.paneDrop(6, lb) {
		t.Fatal("displace drop")
	}
	if s.tree[lb].tab != 6 || s.leafOf(4) >= 0 {
		t.Fatalf("displace: leafB=%d leafOf(4)=%d want 6,-1", s.tree[lb].tab, s.leafOf(4))
	}
	// Bad targets refuse.
	if s.paneDrop(6, 0) {
		t.Fatal("drop on the internal node must refuse")
	}
	if s.paneDrop(99, lb) {
		t.Fatal("drop of a tab off the strip must refuse")
	}
}

// --- MRU focus ring -------------------------------------------------------

func TestMRURingOrderAndBound(t *testing.T) {
	var s TabStrip
	openNTabs(&s, 9) // ids 4..12 — one more than mruMax
	// Focus 5..12 in order: the ring holds the eight most recent.
	for id := uint32(5); id <= 12; id++ {
		if !s.FocusTab(id) {
			t.Fatalf("FocusTab %d", id)
		}
	}
	if s.mruN != mruMax {
		t.Fatalf("ring size = %d want %d (bounded)", s.mruN, mruMax)
	}
	if s.mru[0] != 12 || s.mru[mruMax-1] != 5 {
		t.Fatalf("ring = %v want 12..5 front-to-back", s.mru[:s.mruN])
	}
	// A re-focus moves to the front without duplicating.
	if !s.FocusTab(5) {
		t.Fatal("re-focus 5")
	}
	if s.mruN != mruMax || s.mru[0] != 5 || s.mru[1] != 12 {
		t.Fatalf("after re-focus: %v", s.mru[:s.mruN])
	}
	// mruTop skips ids that left the strip.
	if !s.CloseTab(5) { // focused close; fixup lands on 12
		t.Fatal("close 5")
	}
	if id, ok := s.mruTop(); !ok || id != 12 {
		t.Fatalf("mruTop = %d,%v want 12", id, ok)
	}
}

func TestFocusRestoreOnCloseMRU(t *testing.T) {
	var s TabStrip
	openNTabs(&s, 3) // 4,5,6; focus starts on 4 (ring: [4])
	if !s.FocusTab(5) || !s.FocusTab(6) || !s.FocusTab(4) {
		t.Fatal("focus order 5,6,4 — ring [4,6,5]")
	}
	// Close the focused tab 4 (slot 0). The rail-index neighbour rule
	// would hand focus to 5 (the tab shifting into slot 0); the ring
	// names 6 — the most recent survivor.
	if !s.CloseTab(4) {
		t.Fatal("close focused")
	}
	if id, ok := s.Focused(); !ok || id != 6 {
		t.Fatalf("focus after close = %d,%v want 6 (MRU), not rail neighbour 5", id, ok)
	}
	if id, ok := s.takeFocusRestore(); !ok || id != 6 {
		t.Fatalf("focus restore = %d,%v want 6", id, ok)
	}
	// The seam reads once.
	if _, ok := s.takeFocusRestore(); ok {
		t.Fatal("takeFocusRestore must drain")
	}
}

func TestFocusRestoreFallback(t *testing.T) {
	// An empty ring (strip seeded without focus events on the
	// survivors) falls back to the rail-index neighbour.
	var s TabStrip
	openNTabs(&s, 3)
	s.mruN = 0 // pretend the ring was never fed
	s.focus = 0
	if !s.CloseTab(4) {
		t.Fatal("close focused")
	}
	if id, _ := s.Focused(); id != 5 {
		t.Fatalf("empty-ring fallback focus = %d want 5 (neighbour)", id)
	}
	if _, ok := s.takeFocusRestore(); ok {
		t.Fatal("the fallback is not a ring pick")
	}
}

func TestFocusRecentOnUnsplit(t *testing.T) {
	var s TabStrip
	openNTabs(&s, 2)
	if !s.FocusTab(5) {
		t.Fatal("focus 5 — ring [5,4]")
	}
	if !s.SplitPane(SplitVert, scanoutW, scanoutH) {
		t.Fatal("split")
	}
	// Focus sits on the left leaf's tab... move it to a leaf that is
	// not the ring top is impossible through FocusTab (it would push),
	// so pin the inverse contract: an unsplit keeps focus on the most
	// recent survivor — 5 — and focusRecent agrees it is already there.
	if !s.UnsplitPane() {
		t.Fatal("unsplit pane")
	}
	if id, _ := s.Focused(); id != 5 {
		t.Fatalf("focus after unsplit = %d want 5", id)
	}
	// And the ring's answer after the dissolve is still 5.
	if id, ok := s.mruTop(); !ok || id != 5 {
		t.Fatalf("mruTop after unsplit = %d,%v want 5", id, ok)
	}
}
