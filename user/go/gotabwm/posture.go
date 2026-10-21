// GOTABWM.ELF — M151a (#2912): pane posture — zoom, a rail drag dropped
// into a pane, and MRU focus restore.
//
// Zoom is a seat posture OVER the pane tree, not a tree shape: the
// focused leaf's window takes the full viewport through a real
// WIN_RESIZE and its sibling leaves park hidden (wmctl_set_state's
// visibility bit, the same seam spaces ride), while the tree itself is
// untouched. Every path that re-lays the tree — split, unsplit, rotate,
// sash, reorder/pin, pane-focus move, pane drop, close, space switch or
// move — restores the tree first (restorePaneZoom), so a parked pane
// can never be re-laid out from under the user. The posture never
// reaches SESSION.PANES: it is transient, and persisting it would need
// an ADR 0033 amendment.
//
// The MRU ring (tabs.go) feeds the second half: a close of the focused
// tab and the unsplit paths re-anchor focus on the most recent
// SURVIVING tab — "the tab you were using", not the rail-index
// neighbour.
package main

import "virelai/vi"

// applyPaneZoom is the palette's "Zoom pane" row. The focused leaf takes
// the full viewport (a real WIN_RESIZE) and its sibling leaves park
// hidden — hidden, not closed. Refused when nothing is focused, the
// focused tab holds no leaf, fewer than two panes stand (nothing to
// park), or a zoom is already up: "Restore panes" is the way back.
func applyPaneZoom() bool {
	fid, ok := tabs.Focused()
	if !ok {
		return false
	}
	if !tabs.ZoomFocused() {
		return false
	}
	scanW, scanH := uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight)
	if !applyRect(fid, FullRect(scanW, scanH)) {
		// A refused resize parks nothing: roll the flag back and
		// re-assert the leaf's own rect (the move half may have landed).
		tabs.zoomTab = 0
		_ = applyTreeRects()
		return false
	}
	for _, p := range tabs.PaneRectsAll(scanW, scanH) {
		if p.id != fid && p.id < sessionIDBase {
			wmctlSetVisible(p.id, false)
		}
	}
	vi.ConsoleLine(MarkerZoomOn + vi.Itoa64(int64(fid)))
	dumpPanes()
	_ = writeLayoutFile()
	return true
}

// restorePaneZoom undoes a standing zoom: the parked leaves show again
// and every pane's tree rect is re-proposed through the kernel seam.
// Every tree-mutating apply calls it first; the palette's "Restore
// panes" row rides it too (applyPaneUnzoom). The tree never zoomed, so
// there is nothing to unpersist — no session write here.
func restorePaneZoom() bool {
	zid := tabs.zoomTab
	if zid == 0 {
		return false
	}
	tabs.zoomTab = 0
	scanW, scanH := uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight)
	for _, p := range tabs.PaneRectsAll(scanW, scanH) {
		if p.id != zid && p.id < sessionIDBase {
			wmctlSetVisible(p.id, true)
		}
	}
	_ = applyTreeRects()
	vi.ConsoleLine(MarkerZoomOff)
	return true
}

// applyPaneUnzoom is the palette's "Restore panes" row — the standalone
// restore (the mutation paths call restorePaneZoom before their own
// apply, which then dumps on its own).
func applyPaneUnzoom() bool {
	if !restorePaneZoom() {
		return false
	}
	dumpPanes()
	_ = writeLayoutFile()
	return true
}

// applyPaneDrop is the rail-drag drop: a release over leaf li's client
// rect seats the dragged tab there. A dragged tab that already holds a
// leaf swaps with the target's host; an unplaced one takes the leaf and
// the displaced host returns to the full-viewport stack with a real
// WIN_RESIZE. The change persists through the ordinary write-through
// hook.
func applyPaneDrop(id uint32, li int) bool {
	if li < 0 || li >= tabs.treeN || tabs.tree[li].kind != SplitNone {
		return false
	}
	srcLeaf := tabs.leafOf(id)
	if srcLeaf == li {
		return false
	}
	displaced := tabs.tree[li].tab
	// A drop mutates the tree: a standing zoom restores first.
	restorePaneZoom()
	if !tabs.paneDrop(id, li) {
		return false
	}
	if !applyTreeRects() {
		return false
	}
	if srcLeaf < 0 && displaced != 0 {
		full := FullRect(uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
		if !applyRect(displaced, full) {
			return false
		}
	}
	vi.ConsoleLine(MarkerPaneDrop + "id=" + vi.Itoa64(int64(id)) +
		" leaf=" + vi.Itoa64(int64(li)))
	dumpPanes()
	_ = writeLayoutFile()
	noteSessionMutation()
	return true
}

// focusRecent is the unsplit half of the focus restore: after a pane
// dissolve the seat re-anchors focus on the most recent surviving tab —
// the ring's answer — instead of wherever the collapse left it. Honest
// no-op when the ring has no survivor or it is already focused; the
// marker names the tab and which op asked.
func focusRecent(why string) bool {
	id, ok := tabs.mruTop()
	if !ok {
		return false
	}
	if fid, ok := tabs.Focused(); ok && fid == id {
		return false
	}
	i := tabs.index(id)
	if i < 0 || !focusByIndex(i) {
		return false
	}
	vi.ConsoleLine(MarkerFocusRestore + "id=" + vi.Itoa64(int64(id)) +
		" why=" + why)
	return true
}
