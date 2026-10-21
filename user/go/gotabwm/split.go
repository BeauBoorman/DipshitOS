// GOTABWM.ELF — M62c (issue #1401): apply SplitH / SplitV / Unsplit through
// the kernel's SET_WINDOW seam so each pane is a real WIN_RESIZE the client
// receives, not a paint-only fake. M137a (#2771) generalizes the two-pane
// apply to the pane tree: every placed leaf's rect goes through applyRect
// and every unplaced tab keeps its full-viewport stack.
//
// wm_apply_rect moves FIRST using the window's OLD size as the clamp, so a
// full-viewport window cannot be placed at x>0 or y>0 in one call (max_x
// is 0). applyRect shrinks at the origin first, then moves.
package main

import "virelai/vi"

// wmctlSetRect is the rect-proposal seam for the split/sash paths. It is
// vi.WmctlSetWindowRect in the guest; the indirection exists because that
// call goes out over syscall6, which bypasses vi's host-test syscall hook,
// and would otherwise leave the sash-drag -> relayout path unobservable off
// the guest. Same shape as hid.go's execApp.
var wmctlSetRect = vi.WmctlSetWindowRect

// applyTreeRects pushes every placed pane's computed rect through the
// kernel seam and returns whether they all landed. An unplaced tab's
// window is never touched — it keeps whatever rect it already holds
// (the full-viewport stack, or a leftover pane until a relayout covers
// it; collapseTab's applyRect(full) call is the only path that returns
// a dissolved pane to full).
func applyTreeRects() bool {
	panes := tabs.PaneRectsAll(uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
	for _, p := range panes {
		if !applyRect(p.id, p.rect) {
			return false
		}
	}
	return true
}

// dumpPanes prints the layout+pane marker pair for every tab: placed
// tabs carry their pane rect and their parent split kind, unplaced
// tabs the full-viewport stack rect with split=none — one rect per
// pane, plus the honest fallback for tabs the tree does not hold.
func dumpPanes() {
	scanW, scanH := uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight)
	full := FullRect(scanW, scanH)
	for i := 0; i < tabs.Count(); i++ {
		t := tabs.At(i)
		r, placed := tabs.rectOf(t.ID, scanW, scanH)
		kind := tabs.paneParentKind(t.ID)
		if t.ID == tabs.zoomTab {
			// M151a: the dump names the applied rect — under a zoom
			// the zoomed leaf's window IS the full viewport while the
			// tree still records its pane.
			r = full
		} else if !placed {
			r, kind = full, SplitNone
		}
		dumpTab(t, r, kind)
	}
}

func applySplit(kind SplitKind) bool {
	restorePaneZoom() // M151a: a split re-lays the tree; zoom restores first
	if !tabs.SplitPane(kind, uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight)) {
		return false
	}
	if !applyTreeRects() {
		return false
	}
	vi.ConsoleLine(MarkerSplit + kind.String())
	dumpPanes()
	_ = writeLayoutFile()
	// M137a: the tree is part of the session, persisted through the
	// same write-through hook every strip mutation calls.
	noteSessionMutation()
	return true
}

func applyUnsplit() bool {
	restorePaneZoom() // M151a
	_ = tabs.Unsplit()
	full := FullRect(uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
	n := tabs.Count()
	for i := 0; i < n; i++ {
		t := tabs.At(i)
		if !applyRect(t.ID, full) {
			return false
		}
		dumpTab(t, full, SplitNone)
	}
	vi.ConsoleLine(MarkerUnsplit)
	_ = writeLayoutFile()
	// M151a: a dissolve re-anchors focus on the most recent surviving
	// tab — the ring's pick, not wherever the collapse left it.
	_ = focusRecent("unsplit")
	noteSessionMutation()
	return true
}

// applyPaneUnsplit is the focused-pane collapse: the cycle's none step
// lands here rather than applyUnsplit so a nested split dissolves
// without clearing the rest of the tree. The dissolved sibling's tab
// returns to full-viewport with a real WIN_RESIZE.
func applyPaneUnsplit() bool {
	restorePaneZoom() // M151a
	// Capture the sibling leaves before the collapse: their tabs get
	// the full-viewport rect re-applied.
	scanW, scanH := uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight)
	fid, ok := tabs.Focused()
	if !ok {
		return false
	}
	leaf := tabs.leafOf(fid)
	if leaf < 0 {
		return false
	}
	p := tabs.parentOf(leaf)
	if p < 0 {
		return false
	}
	var dissolved [MaxPanes]uint32
	nd := 0
	var collect func(i int)
	collect = func(i int) {
		n := tabs.tree[i]
		if n.kind == SplitNone {
			if n.tab != fid && nd < MaxPanes {
				dissolved[nd] = n.tab
				nd++
			}
			return
		}
		collect(int(n.a))
		collect(int(n.b))
	}
	collect(p)
	if !tabs.UnsplitPane() {
		return false
	}
	full := FullRect(scanW, scanH)
	if !applyTreeRects() {
		return false
	}
	for i := 0; i < nd; i++ {
		if !applyRect(dissolved[i], full) {
			return false
		}
	}
	vi.ConsoleLine(MarkerUnsplit)
	dumpPanes()
	_ = writeLayoutFile()
	// M151a: a dissolve re-anchors focus on the most recent surviving
	// tab — the ring's pick, not wherever the collapse left it.
	_ = focusRecent("unsplit")
	noteSessionMutation()
	return true
}

// applyPaneRotate is the cycle's v->h step on the focused pane's
// parent. The marker is the split marker for the NEW kind — the pane
// pair is split h now, not rotated in place.
func applyPaneRotate() bool {
	restorePaneZoom() // M151a
	old := tabs.FocusedPaneKind()
	if old == SplitNone {
		return false
	}
	if !tabs.RotatePane(uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight)) {
		return false
	}
	if !applyTreeRects() {
		return false
	}
	vi.ConsoleLine(MarkerSplit + tabs.FocusedPaneKind().String())
	dumpPanes()
	_ = writeLayoutFile()
	noteSessionMutation()
	return true
}

// applyRect proposes r through slot 65. A non-origin position is a two-step
// call so the kernel's move clamp sees the NEW size (see file comment).
func applyRect(id uint32, r Rect) bool {
	if r.X != 0 || r.Y != 0 {
		if wmctlSetRect(id, 0, 0, r.W, r.H) != 0 {
			return false
		}
	}
	return wmctlSetRect(id, r.X, r.Y, r.W, r.H) == 0
}

// applySashDrag commits a sash press-drag-release on internal node ni at
// divider position pos (an x for SplitVert, a y for SplitHoriz). The
// motion is NOT applied live: the seat paints no content-area chrome, so
// there is nothing truthful to preview with, and one relayout on the
// release edge keeps the feedback loop to a single WIN_RESIZE per pane.
// A release on the clamped position it already holds is an honest no-op
// (no syscalls, no markers). On a true change every leaf rect goes
// through applyRect first — the kernel clamp stays authoritative — and
// the sash is stored, marked, dumped, and persisted only after the calls
// returned.
func applySashDrag(ni, pos int) bool {
	restorePaneZoom() // M151a: a sash move re-lays the tree; zoom restores
	if ni < 0 || ni >= tabs.treeN || tabs.tree[ni].kind == SplitNone {
		return false
	}
	kind := tabs.tree[ni].kind
	scanW, scanH := uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight)
	from := tabs.nodeSashCenter(ni, scanW, scanH)
	if from < 0 || !tabs.SetSashNode(ni, pos, scanW, scanH) {
		return false
	}
	to := tabs.tree[ni].sash
	if !applyTreeRects() {
		return false
	}
	vi.ConsoleLine(MarkerSash + kind.String() +
		" from=" + vi.Itoa64(int64(from)) +
		" to=" + vi.Itoa64(int64(to)))
	dumpPanes()
	_ = writeLayoutFile()
	noteSessionMutation()
	return true
}

// applySplitCycle is the M79c (#1706) keyboard entry to a split, now on
// the FOCUSED pane (M137a): none -> V -> H -> none, where the state is
// the kind of the focused leaf's parent node. On an empty strip-level
// tree the first press is the depth-1 M62c split; under a standing tree
// the focused pane divides. Live mode has no other way to split — the
// choreography is demo-only — so without this the sash drag is
// unreachable outside a gate. Each step reuses the apply* path it lands
// on, so the markers and dumps are the same shapes the choreography
// already prints; a step the strip refuses (one tab, a pane at the
// depth/pane/floor bound, no unplaced tab to host) is silent, like every
// other chord no-op.
func applySplitCycle() bool {
	switch tabs.FocusedPaneKind() {
	case SplitVert:
		// State V presses H — on the focused pane: a nested split when
		// another pane can host (that is how two presses reach three
		// panes), else the M62c retarget rotate for the depth-1 case.
		if fid, ok := tabs.Focused(); ok {
			if leaf := tabs.leafOf(fid); leaf >= 0 &&
				tabs.treeDepth(leaf) <= MaxTreeDepth &&
				tabs.leafCount() < MaxPanes {
				if _, unplaced := tabs.nextUnplaced(tabs.index(fid)); unplaced {
					r, _ := tabs.rectOf(fid,
						uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
					if _, _, ok := splitRectIn(SplitHoriz, r, 0); ok {
						return applySplit(SplitHoriz)
					}
				}
			}
		}
		return applyPaneRotate()
	case SplitHoriz:
		return applyPaneUnsplit()
	default:
		return applySplit(SplitVert)
	}
}

// applyPaneFocus is the M137a directional chord: ctrl+alt+arrows move
// focus to the geometric neighbour pane. The target rides the same
// focusByIndex path a rail click or alt-tab takes, so the focus/raise
// markers and the kernel focus event keep exactly one shape.
func applyPaneFocus(dx, dy int) bool {
	restorePaneZoom() // M151a: a pane-focus move restores the tree first
	id, ok := tabs.paneFocusMove(dx, dy, uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
	if !ok {
		return false
	}
	i := tabs.index(id)
	if i < 0 {
		return false
	}
	return focusByIndex(i)
}

func dumpTab(t Tab, applied Rect, kind SplitKind) {
	focus := false
	if id, ok := tabs.Focused(); ok && id == t.ID {
		focus = true
	}
	vi.ConsoleLine(MarkerLayout + layoutLine(t.ID, layoutBin(t), applied, focus, kind))
	// Slot 19 WinQuery is owner-restricted (CALLER's window only). The
	// seat cannot read a hosted client's rect back. The pane line is the
	// rect SET_WINDOW just accepted; a kernel refusal skips dumpTab.
	vi.ConsoleLine(MarkerPane + paneLine(t.ID, applied))
}
