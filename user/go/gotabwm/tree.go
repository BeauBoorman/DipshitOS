// GOTABWM.ELF — M137a (#2771, ADR 0033 amendment): the split is a tree.
//
// M62c's two-pane model — one SplitKind plus one sash — is the depth-1
// case of this file's shape: the viewport divides recursively, each
// internal node is one horizontal or vertical split with its own
// divider, and each leaf hosts exactly one strip tab. Depth 3 is the
// ceiling (three nested splits) and 8 the pane cap; both bounds are
// enforced at mutation time so no shape the tree can take is ever
// untileable.
//
// A leaf names its tab by window id, not strip position: a reorder or
// pin never moves a pane, and the only two id-level events are a close
// (the leaf dies, its sibling subtree is spliced up into the dead
// node's slot) and a re-exec adoption (the placeholder id is swapped
// for the live window id). A tab with no leaf — one opened after the
// tree was laid, or one whose pane an unsplit dissolved — keeps the
// headless full-viewport rect it always had; it is still a strip tab,
// still a rail cell, still a session row.
//
// The fixed pool is treeMaxNodes slots: 8 leaves + 7 internal nodes.
// Mutations splice and then compact, so tree[0] is always the root and
// no dead slot survives between operations.
package main

// MaxPanes is the ADR 0033 amendment cap on leaf panes.
const MaxPanes = 8

// MaxTreeDepth is the nested-split ceiling: the root split is depth 1,
// so depth 3 permits a leaf three sashes deep.
const MaxTreeDepth = 3

// treeMaxNodes is the fixed node pool for the deepest legal tree.
const treeMaxNodes = 2*MaxPanes - 1

// paneNode is one tree slot. kind==SplitNone marks a leaf; tab names
// the hosted window id. Internal nodes index their children into the
// pool (a/b) and carry sash — the drag-set divider centre in scanout
// px, ABSOLUTE so it survives a relayout (the M79c invariant carried
// per node), 0 for the midpoint tiling.
type paneNode struct {
	kind SplitKind
	a, b int8
	tab  uint32
	sash int
}

// treeEmpty reports whether the strip has no pane tree — the M62c
// unsplit shape where every tab tiles full-viewport.
func (s *TabStrip) treeEmpty() bool { return s.treeN == 0 }

// leafOf returns the node index of the leaf hosting tabID, or -1 when
// the tab has no pane (unplaced) or the tree is empty.
func (s *TabStrip) leafOf(tabID uint32) int {
	for i := 0; i < s.treeN; i++ {
		if s.tree[i].kind == SplitNone && s.tree[i].tab == tabID {
			return i
		}
	}
	return -1
}

// leafCount is the live pane count.
func (s *TabStrip) leafCount() int {
	n := 0
	for i := 0; i < s.treeN; i++ {
		if s.tree[i].kind == SplitNone && s.tree[i].tab != 0 {
			n++
		}
	}
	return n
}

// treeDepth is node i's depth (root = 1); -1 for a bad index. Iterative
// over a pool this size is cheaper than tracking parent pointers.
func (s *TabStrip) treeDepth(i int) int {
	if i < 0 || i >= s.treeN {
		return -1
	}
	d := 0
	for cur := 0; cur >= 0; {
		d++
		if cur == i {
			return d
		}
		// Find cur's parent.
		p := -1
		for j := 0; j < s.treeN; j++ {
			if s.tree[j].kind != SplitNone && (int(s.tree[j].a) == cur || int(s.tree[j].b) == cur) {
				p = j
				break
			}
		}
		if p < 0 {
			break
		}
		cur = p
	}
	return -1
}

// nextUnplaced returns the next strip tab (starting at position after,
// wrapping) that holds no leaf. It is the tab a new pane hosts.
func (s *TabStrip) nextUnplaced(after int) (uint32, bool) {
	if s.count == 0 {
		return 0, false
	}
	for k := 1; k <= s.count; k++ {
		i := (after + k) % s.count
		if s.leafOf(s.tabs[i].ID) < 0 {
			return s.tabs[i].ID, true
		}
	}
	return 0, false
}

// allocNode takes a free pool slot, or -1 at the pool bound.
func (s *TabStrip) allocNode() int {
	if s.treeN >= treeMaxNodes {
		return -1
	}
	s.tree[s.treeN] = paneNode{a: -1, b: -1}
	s.treeN++
	return s.treeN - 1
}

// compactTree rewrites the pool so only nodes reachable from the root
// survive, re-keying child indexes. Root lands at slot 0.
func (s *TabStrip) compactTree() {
	if s.treeN == 0 {
		return
	}
	var fresh [treeMaxNodes]paneNode
	mapping := [treeMaxNodes]int8{}
	for i := range mapping {
		mapping[i] = -1
	}
	var order [treeMaxNodes]int
	nout := 0
	order[0] = 0
	nin := 1
	for h := 0; h < nin; h++ {
		old := order[h]
		mapping[old] = int8(nout)
		fresh[nout] = s.tree[old]
		nout++
		n := &fresh[nout-1]
		if n.kind != SplitNone {
			order[nin] = int(n.a)
			nin++
			order[nin] = int(n.b)
			nin++
		}
	}
	for i := 0; i < nout; i++ {
		if fresh[i].kind != SplitNone {
			fresh[i].a = mapping[fresh[i].a]
			fresh[i].b = mapping[fresh[i].b]
		}
	}
	s.tree = fresh
	s.treeN = nout
}

// splitLeaf replaces leaf i with an internal node of kind: the leaf's
// tab keeps child A, child B hosts newTab. Assumes bounds already
// checked by the caller.
func (s *TabStrip) splitLeaf(i int, kind SplitKind, newTab uint32) bool {
	ta, tb := s.allocNode(), s.allocNode()
	if ta < 0 || tb < 0 {
		return false
	}
	s.tree[ta] = paneNode{kind: SplitNone, a: -1, b: -1, tab: s.tree[i].tab}
	s.tree[tb] = paneNode{kind: SplitNone, a: -1, b: -1, tab: newTab}
	s.tree[i] = paneNode{kind: kind, a: int8(ta), b: int8(tb)}
	return true
}

// collapseAt dissolves internal node i into the leaf holding keepTab —
// the other subtree's leaves die and their tabs go back to the
// full-viewport stack (the M62c unsplit rule generalized). Compaction
// rewrites indexes afterwards.
func (s *TabStrip) collapseAt(i int, keepTab uint32) {
	s.tree[i] = paneNode{kind: SplitNone, a: -1, b: -1, tab: keepTab}
	// Orphan the dissolved subtree, then compact it away. Children of
	// i now index pool slots that are no longer referenced by i; mark
	// them dead by clearing every slot not reachable from the root —
	// compactTree does exactly that.
	s.compactTree()
}

// parentOf returns the node whose child is i, or -1 at the root.
func (s *TabStrip) parentOf(i int) int {
	for j := 0; j < s.treeN; j++ {
		if s.tree[j].kind != SplitNone && (int(s.tree[j].a) == i || int(s.tree[j].b) == i) {
			return j
		}
	}
	return -1
}

// removeLeaf splices leaf i out: its parent's other subtree rises into
// the parent's slot, or the tree empties when i is the root. Returns
// false when i is not a leaf. A leaf death is a tree mutation — any
// standing zoom clears (M151a; the seat's close path restores first).
func (s *TabStrip) removeLeaf(i int) bool {
	if i < 0 || i >= s.treeN || s.tree[i].kind != SplitNone {
		return false
	}
	s.zoomTab = 0 // M151a
	p := s.parentOf(i)
	if p < 0 {
		s.treeN = 0
		return true
	}
	sib := int(s.tree[p].a)
	if sib == i {
		sib = int(s.tree[p].b)
	}
	// The sibling subtree takes the parent's slot wholesale.
	s.tree[p] = s.tree[sib]
	s.tree[sib] = paneNode{a: -1, b: -1}
	s.compactTree()
	return true
}

// retreeID swaps a leaf's hosted id (the re-exec adoption seam: the
// placeholder id dies and the live window id lands). The MRU ring and a
// standing zoom name ids too — they remap along (M151a).
func (s *TabStrip) retreeID(old, new uint32) {
	if i := s.leafOf(old); i >= 0 {
		s.tree[i].tab = new
	}
	if s.zoomTab == old {
		s.zoomTab = new
	}
	s.mruRemap(old, new)
}

// relinkLeaves re-binds leaves to strip POSITIONS in tree order — the
// M79c contract that a reorder moves panes with the tabs rather than
// leaving the geometry standing: the i-th leaf (preorder) hosts the
// i-th strip tab; tabs past the leaf count stay unplaced. Called after
// every position mutation (reorder, pin partition).
func (s *TabStrip) relinkLeaves() {
	if s.treeN == 0 {
		return
	}
	s.zoomTab = 0 // M151a: re-binding panes restores a standing zoom
	i := 0
	var walk func(ni int)
	walk = func(ni int) {
		if s.tree[ni].kind == SplitNone {
			if s.tree[ni].tab != 0 && i < s.count {
				s.tree[ni].tab = s.tabs[i].ID
				i++
			}
			return
		}
		walk(int(s.tree[ni].a))
		walk(int(s.tree[ni].b))
	}
	walk(0)
}

// paneRect pairs one leaf's hosted tab with its computed rect.
type paneRect struct {
	id   uint32
	rect Rect
}

// splitRectIn divides rect r by kind at divider centre c (absolute
// scanout px; <=0 means the midpoint, gutterless — SplitRects's shape).
// The centre is clamped inside r so both children keep the pane floor
// and the SashWidth gutter. Refused when r cannot hold the split.
func splitRectIn(kind SplitKind, r Rect, c int) (Rect, Rect, bool) {
	half := SashWidth / 2
	if kind == SplitVert {
		if r.W < 2*PaneMinW || r.H < PaneMinH {
			return Rect{}, Rect{}, false
		}
		if c <= 0 {
			lw := r.W / 2
			return Rect{r.X, r.Y, lw, r.H}, Rect{r.X + lw, r.Y, r.W - lw, r.H}, true
		}
		lo := int(r.X) + int(PaneMinW) + half
		hi := int(r.X) + int(r.W) - int(PaneMinW) - half
		if hi < lo {
			return Rect{}, Rect{}, false
		}
		if c < lo {
			c = lo
		}
		if c > hi {
			c = hi
		}
		lw := c - half - int(r.X)
		rx := c + half
		rw := int(r.X) + int(r.W) - rx
		if lw < int(PaneMinW) || rw < int(PaneMinW) {
			return Rect{}, Rect{}, false
		}
		return Rect{r.X, r.Y, uint32(lw), r.H},
			Rect{uint32(rx), r.Y, uint32(rw), r.H}, true
	}
	if kind == SplitHoriz {
		if r.W < PaneMinW || r.H < 2*PaneMinH {
			return Rect{}, Rect{}, false
		}
		if c <= 0 {
			th := r.H / 2
			return Rect{r.X, r.Y, r.W, th}, Rect{r.X, r.Y + th, r.W, r.H - th}, true
		}
		lo := int(r.Y) + int(PaneMinH) + half
		hi := int(r.Y) + int(r.H) - int(PaneMinH) - half
		if hi < lo {
			return Rect{}, Rect{}, false
		}
		if c < lo {
			c = lo
		}
		if c > hi {
			c = hi
		}
		th := c - half - int(r.Y)
		by := c + half
		bh := int(r.Y) + int(r.H) - by
		if th < int(PaneMinH) || bh < int(PaneMinH) {
			return Rect{}, Rect{}, false
		}
		return Rect{r.X, r.Y, r.W, uint32(th)},
			Rect{r.X, uint32(by), r.W, uint32(bh)}, true
	}
	return Rect{}, Rect{}, false
}

// treeRects walks the tree from rect r (the root's is the full scanout)
// and writes each leaf's rect into out (at most MaxPanes). The count is
// bounded so the caller never over-reads. Refused when a node's split
// cannot honour the pane floor — the caller treats that as "do not
// apply" rather than a partial layout.
func (s *TabStrip) treeRects(r Rect, out *[MaxPanes]paneRect) int {
	if s.treeN == 0 {
		return 0
	}
	n := 0
	var walk func(i int, rr Rect) bool
	walk = func(i int, rr Rect) bool {
		node := s.tree[i]
		if node.kind == SplitNone {
			if n >= MaxPanes || node.tab == 0 {
				return false
			}
			out[n] = paneRect{id: node.tab, rect: rr}
			n++
			return true
		}
		ra, rb, ok := splitRectIn(node.kind, rr, node.sash)
		if !ok {
			return false
		}
		return walk(int(node.a), ra) && walk(int(node.b), rb)
	}
	if !walk(0, r) {
		return 0
	}
	return n
}

// PaneRectsAll returns every placed pane's (tab, rect) pair for the
// scanout, in tree order. nil when no tree stands.
func (s *TabStrip) PaneRectsAll(scanW, scanH uint32) []paneRect {
	var out [MaxPanes]paneRect
	n := s.treeRects(FullRect(scanW, scanH), &out)
	if n == 0 {
		return nil
	}
	return out[:n]
}

// sashHitAt is the M137a divider hit test: sashZoneAt generalized to
// every internal node. Returns the node index and its effective centre
// for the gutter under (px,py), or false off every gutter. The
// chrome-clear rules are sashZoneAt's: y under the rail and the bottom
// 22 px are never sash territory, and the band itself lives inside the
// node's own rect so a nested divider can never shadow the root's.
func (s *TabStrip) sashHitAt(px, py uint32, scanW, scanH uint32) (int, int, bool) {
	if s.treeN == 0 {
		return 0, 0, false
	}
	if py < uint32(RailHeight) || int(py)+22 > int(scanH) || int(px) >= int(scanW) {
		return 0, 0, false
	}
	half := SashWidth / 2
	for i := 0; i < s.treeN; i++ {
		node := s.tree[i]
		if node.kind == SplitNone {
			continue
		}
		r := s.nodeRect(i, scanW, scanH)
		c := s.nodeSashCenter(i, scanW, scanH)
		if c < 0 {
			continue
		}
		if node.kind == SplitVert {
			d := int(px) - c
			if d >= -half && d <= half &&
				int(py) >= int(r.Y) && int(py) < int(r.Y)+int(r.H) {
				return i, c, true
			}
		} else {
			d := int(py) - c
			if d >= -half && d <= half &&
				int(px) >= int(r.X) && int(px) < int(r.X)+int(r.W) {
				return i, c, true
			}
		}
	}
	return 0, 0, false
}

// rectOf returns the rect a tab occupies: its leaf's, or the headless
// full-viewport fallback every unplaced tab keeps.
func (s *TabStrip) rectOf(tabID uint32, scanW, scanH uint32) (Rect, bool) {
	var out [MaxPanes]paneRect
	n := s.treeRects(FullRect(scanW, scanH), &out)
	for i := 0; i < n; i++ {
		if out[i].id == tabID {
			return out[i].rect, true
		}
	}
	return FullRect(scanW, scanH), false
}

// paneParentKind is the split kind immediately over a tab's leaf —
// the LAYOUT.txt split= field. Unplaced tabs report none.
func (s *TabStrip) paneParentKind(tabID uint32) SplitKind {
	i := s.leafOf(tabID)
	if i < 0 {
		return SplitNone
	}
	if p := s.parentOf(i); p >= 0 {
		return s.tree[p].kind
	}
	return SplitNone
}

// SplitPane divides the focused tab's pane along kind. On an empty
// tree this is the M62c split: the focused tab takes child A and the
// next unplaced tab takes B, a depth-1 tree through the same
// SplitRectsSash math. On a standing tree the focused LEAF is the
// pane that divides — the card's "cycle on the focused pane". Refused
// when the focused tab has no pane to split (an unplaced tab under a
// standing tree), when the depth/pane bounds would break, when no
// unplaced tab exists to host, or when the leaf's rect cannot hold
// two panes at the floor.
func (s *TabStrip) SplitPane(kind SplitKind, scanW, scanH uint32) bool {
	if kind == SplitNone || s.count < 2 {
		return false
	}
	fid, ok := s.Focused()
	if !ok {
		return false
	}
	focusIdx := s.index(fid)
	if s.treeN == 0 {
		b, ok := s.nextUnplaced(focusIdx)
		if !ok {
			return false
		}
		if _, _, ok := splitRectIn(kind, FullRect(scanW, scanH), 0); !ok {
			return false
		}
		s.zoomTab = 0 // M151a
		root := s.allocNode()
		ta, tb := s.allocNode(), s.allocNode()
		if root < 0 || ta < 0 || tb < 0 {
			return false
		}
		s.tree[root] = paneNode{kind: kind, a: int8(ta), b: int8(tb)}
		s.tree[ta] = paneNode{kind: SplitNone, a: -1, b: -1, tab: fid}
		s.tree[tb] = paneNode{kind: SplitNone, a: -1, b: -1, tab: b}
		return true
	}
	leaf := s.leafOf(fid)
	if leaf < 0 {
		return false
	}
	// Depth counts nodes from the root (root = 1): a leaf at depth 3
	// may still split once — its children land at depth 4, the third
	// nested split. A leaf at 4 is the bound.
	if s.treeDepth(leaf) > MaxTreeDepth || s.leafCount() >= MaxPanes {
		return false
	}
	b, ok := s.nextUnplaced(focusIdx)
	if !ok {
		return false
	}
	// Geometry first: the leaf's current rect must hold two panes at
	// the floor before the tree mutates.
	r, placed := s.rectOf(fid, scanW, scanH)
	if !placed {
		return false
	}
	if _, _, ok := splitRectIn(kind, r, 0); !ok {
		return false
	}
	s.zoomTab = 0 // M151a: any tree mutation restores a standing zoom
	return s.splitLeaf(leaf, kind, b)
}

// ensurePaneSplit is the M62c compat surface for SplitV/SplitH: the
// focused pane's split BECOMES kind — a same-kind press is a true
// no-op (true), a different kind rotates the parent, an unsplit pane
// nests. The chord cycle does not ride this: it needs the pure nest.
func (s *TabStrip) ensurePaneSplit(kind SplitKind, scanW, scanH uint32) bool {
	fid, ok := s.Focused()
	if !ok {
		return false
	}
	if leaf := s.leafOf(fid); leaf >= 0 {
		if p := s.parentOf(leaf); p >= 0 {
			if s.tree[p].kind == kind {
				return true
			}
			return s.RotatePane(scanW, scanH)
		}
	}
	return s.SplitPane(kind, scanW, scanH)
}

// RotatePane flips the split axis of the focused leaf's parent — the
// cycle's V->H step. Refused when the focused tab has no parent to
// rotate.
func (s *TabStrip) RotatePane(scanW, scanH uint32) bool {
	fid, ok := s.Focused()
	if !ok {
		return false
	}
	leaf := s.leafOf(fid)
	if leaf < 0 {
		return false
	}
	p := s.parentOf(leaf)
	if p < 0 {
		return false
	}
	next := SplitHoriz
	if s.tree[p].kind == SplitHoriz {
		next = SplitVert
	}
	// The rotation must still tile at the pane floor; a too-shallow
	// rect refuses rather than producing a broken layout.
	if _, _, ok := splitRectIn(next, s.nodeRect(p, scanW, scanH), 0); !ok {
		return false
	}
	s.zoomTab = 0 // M151a: a rotated layout restores a standing zoom
	s.tree[p].kind = next
	// The divider centre lives on the split axis; a rotated node starts
	// back at the midpoint rather than re-clamping a stale x into a y.
	s.tree[p].sash = 0
	return true
}

// UnsplitPane collapses the focused leaf's parent — the cycle's H->none
// step. The focused tab keeps the merged pane; the sibling subtree
// dissolves back to the full-viewport stack. Refused when the focused
// tab is not under a split.
func (s *TabStrip) UnsplitPane() bool {
	fid, ok := s.Focused()
	if !ok {
		return false
	}
	leaf := s.leafOf(fid)
	if leaf < 0 {
		return false
	}
	p := s.parentOf(leaf)
	if p < 0 {
		return false
	}
	if s.tree[p].kind == SplitHoriz || s.tree[p].kind == SplitVert {
		s.zoomTab = 0 // M151a
		s.collapseAt(p, fid)
		return true
	}
	return false
}

// nodeRect computes node i's rect by walking down from the root —
// needed before a mutation so bounds checks see the real geometry.
func (s *TabStrip) nodeRect(i int, scanW, scanH uint32) Rect {
	r := FullRect(scanW, scanH)
	if i == 0 || s.treeN == 0 {
		return r
	}
	cur := i
	chain := [MaxTreeDepth]int{}
	d := 0
	for {
		p := s.parentOf(cur)
		if p < 0 || d >= MaxTreeDepth {
			break
		}
		chain[d] = cur // remember which child we were
		d++
		cur = p
	}
	// Walk back down applying each split.
	for k := d - 1; k >= 0; k-- {
		p := s.parentOf(chain[k])
		node := s.tree[p]
		ra, rb, ok := splitRectIn(node.kind, r, node.sash)
		if !ok {
			return Rect{}
		}
		if int(node.a) == chain[k] {
			r = ra
		} else {
			r = rb
		}
	}
	return r
}

// FocusedPaneKind is the split-cycle state for the focused pane: the
// parent node's kind (v/h) or none — the M62c cycle's `Split()` view
// generalized to the focused leaf.
func (s *TabStrip) FocusedPaneKind() SplitKind {
	fid, ok := s.Focused()
	if !ok {
		return SplitNone
	}
	i := s.leafOf(fid)
	if i < 0 {
		return SplitNone
	}
	if p := s.parentOf(i); p >= 0 {
		return s.tree[p].kind
	}
	return SplitNone
}

// leafHitAt is the M151a drop hit-test: the leaf NODE INDEX whose client
// rect holds (px,py), or false off every pane. The chrome guards are
// sashHitAt's — the rail owns y < RailHeight and the bottom 22 px are
// never pane territory; the sash gutter lands in no rect, so a divider
// release is not a drop.
func (s *TabStrip) leafHitAt(px, py uint32, scanW, scanH uint32) (int, bool) {
	if s.treeN == 0 {
		return 0, false
	}
	if py < uint32(RailHeight) || int(py)+22 > int(scanH) || int(px) >= int(scanW) {
		return 0, false
	}
	hit := -1
	var walk func(i int, r Rect) bool
	walk = func(i int, r Rect) bool {
		n := s.tree[i]
		if n.kind == SplitNone {
			if n.tab != 0 && int(px) >= int(r.X) && int(px) < int(r.X+r.W) &&
				int(py) >= int(r.Y) && int(py) < int(r.Y+r.H) {
				hit = i
				return true
			}
			return false
		}
		ra, rb, ok := splitRectIn(n.kind, r, n.sash)
		if !ok {
			return false
		}
		return walk(int(n.a), ra) || walk(int(n.b), rb)
	}
	walk(0, FullRect(scanW, scanH))
	if hit < 0 {
		return 0, false
	}
	return hit, true
}

// paneDrop seats tab id on leaf li (M151a): an id that already holds a
// leaf swaps with the target's host; an unplaced id takes the leaf and
// the displaced host goes back to the unplaced stack. False on a bad
// index, a non-leaf, a same-leaf release, or a tab not on the strip.
func (s *TabStrip) paneDrop(id uint32, li int) bool {
	if li < 0 || li >= s.treeN || s.tree[li].kind != SplitNone {
		return false
	}
	if s.index(id) < 0 {
		return false
	}
	if src := s.leafOf(id); src >= 0 {
		if src == li {
			return false
		}
		s.tree[src].tab, s.tree[li].tab = s.tree[li].tab, id
		s.zoomTab = 0 // M151a: a drop mutates the tree; zoom restores
		return true
	}
	s.tree[li].tab = id
	s.zoomTab = 0 // M151a
	return true
}

// ZoomFocused marks the focused leaf zoomed — it renders the full
// viewport while its sibling leaves park hidden (M151a). Refused when
// nothing is focused, the focused tab holds no leaf, fewer than two
// panes stand (nothing to park), or a zoom is already up.
func (s *TabStrip) ZoomFocused() bool {
	fid, ok := s.Focused()
	if !ok || s.zoomTab != 0 {
		return false
	}
	if s.leafOf(fid) < 0 || s.leafCount() < 2 {
		return false
	}
	s.zoomTab = fid
	return true
}

// paneFocusMove moves focus to the nearest pane in direction dx/dy
// (one of ±1, the other 0) by pane-rect geometry: candidates are leaves
// whose centre is strictly in that direction with perpendicular-axis
// overlap; the winner is the deepest overlap, then the nearest centre.
// False when nothing lies that way or no tree stands.
func (s *TabStrip) paneFocusMove(dx, dy int, scanW, scanH uint32) (uint32, bool) {
	fid, ok := s.Focused()
	if !ok || s.treeN == 0 {
		return 0, false
	}
	var out [MaxPanes]paneRect
	n := s.treeRects(FullRect(scanW, scanH), &out)
	if n < 2 {
		return 0, false
	}
	cur := -1
	for i := 0; i < n; i++ {
		if out[i].id == fid {
			cur = i
			break
		}
	}
	if cur < 0 {
		return 0, false
	}
	cr := out[cur].rect
	ccx := int64(cr.X) + int64(cr.W)/2
	ccy := int64(cr.Y) + int64(cr.H)/2
	best := -1
	var bestScore int64
	for i := 0; i < n; i++ {
		if i == cur {
			continue
		}
		r := out[i].rect
		cx := int64(r.X) + int64(r.W)/2
		cy := int64(r.Y) + int64(r.H)/2
		// Direction: the candidate's centre must sit strictly on the
		// asked side.
		var dist int64
		if dx < 0 {
			if cx >= ccx {
				continue
			}
			dist = ccx - cx
		} else if dx > 0 {
			if cx <= ccx {
				continue
			}
			dist = cx - ccx
		} else if dy < 0 {
			if cy >= ccy {
				continue
			}
			dist = ccy - cy
		} else {
			if cy <= ccy {
				continue
			}
			dist = cy - ccy
		}
		// Perpendicular overlap: the shared extent on the other axis.
		var lo1, hi1, lo2, hi2 int64
		if dx != 0 {
			lo1, hi1 = int64(cr.Y), int64(cr.Y)+int64(cr.H)
			lo2, hi2 = int64(r.Y), int64(r.Y)+int64(r.H)
		} else {
			lo1, hi1 = int64(cr.X), int64(cr.X)+int64(cr.W)
			lo2, hi2 = int64(r.X), int64(r.X)+int64(r.W)
		}
		ov := hi1
		if hi2 < hi1 {
			ov = hi2
		}
		ov -= lo1
		if lo2 > lo1 {
			ov -= lo2 - lo1
		}
		if ov < 0 {
			ov = 0
		}
		score := ov*65536 - dist
		if best < 0 || score > bestScore {
			best, bestScore = i, score
		}
	}
	if best < 0 {
		return 0, false
	}
	return out[best].id, true
}
