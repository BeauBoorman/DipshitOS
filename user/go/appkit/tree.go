package appkit

// The M137b (#2772) outline controller: a node model with lazy children on
// top of the pure widgets.Tree. The controller owns flattening (expanded
// branches only), expand/collapse, arrow and type-ahead navigation, and
// scroll-into-view — the ListController split applied to an outline.

import "virelai/widgets"

// TreeNode is one outline item. Kids are the materialized children; a Lazy
// node defers them to Load, which runs once on first expand (a Load that
// returns nil turns the node into a leaf — the chevron vanishes on reflow).
// Expanded is model state the controller toggles and the widget reads.
type TreeNode struct {
	Label    string
	Kids     []*TreeNode
	Lazy     bool                        // children exist but Load has not run
	Load     func(*TreeNode) []*TreeNode // lazy child producer; nil → leaf
	Expanded bool

	loaded bool
	parent *TreeNode
}

// Branch reports whether the node can show a chevron: materialized kids, or
// a lazy node that has not been loaded yet.
func (n *TreeNode) Branch() bool {
	if n == nil {
		return false
	}
	if len(n.Kids) > 0 {
		return true
	}
	return n.Lazy && !n.loaded && n.Load != nil
}

// TreeController adds expand/collapse, keyboard navigation and type-ahead to
// a widgets.Tree. It implements Focusable, so it drops into a FocusRing next
// to lists and fields. OnActivate fires on Enter over a leaf (branches
// toggle instead); it returns whether the app state changed.
type TreeController struct {
	View       *widgets.Tree
	Roots      []*TreeNode
	OnActivate func(*TreeNode) bool

	rows   []*TreeNode // flattened; parallel to View.Rows
	prefix []rune      // type-ahead buffer
}

func NewTreeController(view *widgets.Tree, roots []*TreeNode) *TreeController {
	c := &TreeController{View: view, Roots: roots}
	c.Reflow()
	return c
}

func (c *TreeController) valid() bool {
	return c != nil && c.View != nil && len(c.rows) > 0
}

// Reflow rebuilds the widget's flattened Rows from the model's expanded
// branches and re-anchors Sel on the same node when it is still visible.
// Call it after mutating Labels or splicing Kids outside the controller.
func (c *TreeController) Reflow() {
	var sel *TreeNode
	if prev := c.Selected(); prev != nil {
		sel = prev
	}
	c.rows = c.rows[:0]
	c.View.Rows = c.View.Rows[:0]
	var walk func(ns []*TreeNode, parent *TreeNode, depth int)
	walk = func(ns []*TreeNode, parent *TreeNode, depth int) {
		for _, n := range ns {
			if n == nil {
				continue
			}
			n.parent = parent
			c.rows = append(c.rows, n)
			c.View.Rows = append(c.View.Rows, widgets.TreeRow{
				Label:    n.Label,
				Depth:    depth,
				HasKids:  n.Branch(),
				Expanded: n.Expanded,
			})
			if n.Expanded && len(n.Kids) > 0 {
				walk(n.Kids, n, depth+1)
			}
		}
	}
	walk(c.Roots, nil, 0)
	c.View.Sel = -1
	if sel != nil {
		for i, n := range c.rows {
			if n == sel {
				c.View.Sel = i
				break
			}
		}
	}
	if c.View.Sel < 0 && len(c.rows) > 0 && sel != nil {
		c.View.Sel = 0
	}
	c.ensureVisible()
}

// Selected is the row's node, or nil.
func (c *TreeController) Selected() *TreeNode {
	if c == nil || c.View == nil || c.View.Sel < 0 || c.View.Sel >= len(c.rows) {
		return nil
	}
	return c.rows[c.View.Sel]
}

// Expand opens a branch, running its lazy Load once if needed. A lazy node
// that loads to no children stops being a branch; the row reflows either
// way. Leaf calls return false.
func (c *TreeController) Expand(n *TreeNode) bool {
	if n == nil || !n.Branch() {
		return false
	}
	if n.Lazy && !n.loaded && n.Load != nil {
		n.Kids = n.Load(n)
		n.loaded = true
	}
	n.Expanded = len(n.Kids) > 0
	c.Reflow()
	return true
}

// Collapse shuts an expanded branch. Collapsed and leaf calls return false.
func (c *TreeController) Collapse(n *TreeNode) bool {
	if n == nil || !n.Expanded {
		return false
	}
	n.Expanded = false
	c.Reflow()
	return true
}

// Toggle is Expand or Collapse by current state.
func (c *TreeController) Toggle(n *TreeNode) bool {
	if n == nil || !n.Branch() {
		return false
	}
	if n.Expanded {
		return c.Collapse(n)
	}
	return c.Expand(n)
}

// ExpandAll opens every branch, running lazy loaders top-down. CollapseAll
// shuts them. Both reflow once and report whether the view changed.
func (c *TreeController) ExpandAll() bool {
	changed := false
	var walk func(ns []*TreeNode)
	walk = func(ns []*TreeNode) {
		for _, n := range ns {
			if n == nil {
				continue
			}
			if n.Lazy && !n.loaded && n.Load != nil {
				n.Kids = n.Load(n)
				n.loaded = true
			}
			if len(n.Kids) > 0 {
				if !n.Expanded {
					n.Expanded = true
					changed = true
				}
				walk(n.Kids)
			}
		}
	}
	walk(c.Roots)
	if changed {
		c.Reflow()
	}
	return changed
}

func (c *TreeController) CollapseAll() bool {
	changed := false
	var walk func(ns []*TreeNode)
	walk = func(ns []*TreeNode) {
		for _, n := range ns {
			if n == nil {
				continue
			}
			if n.Expanded {
				n.Expanded = false
				changed = true
			}
			walk(n.Kids)
		}
	}
	walk(c.Roots)
	if changed {
		c.Reflow()
	}
	return changed
}

// Move steps the selection over the flattened rows.
func (c *TreeController) Move(delta int) bool {
	if !c.valid() {
		return false
	}
	if c.View.Sel < 0 {
		c.View.Sel = 0
	}
	next := c.View.Sel + delta
	if next < 0 {
		next = 0
	}
	if next >= len(c.rows) {
		next = len(c.rows) - 1
	}
	changed := next != c.View.Sel
	c.View.Sel = next
	c.ensureVisible()
	return changed
}

func (c *TreeController) Home() bool {
	if !c.valid() {
		return false
	}
	changed := c.View.Sel != 0
	c.View.Sel = 0
	c.ensureVisible()
	return changed
}

func (c *TreeController) End() bool {
	if !c.valid() {
		return false
	}
	last := len(c.rows) - 1
	changed := c.View.Sel != last
	c.View.Sel = last
	c.ensureVisible()
	return changed
}

// rowOf finds the row index displaying node n, or -1.
func (c *TreeController) rowOf(n *TreeNode) int {
	for i, rn := range c.rows {
		if rn == n {
			return i
		}
	}
	return -1
}

// SelectRow moves Sel to row i and scrolls it into view.
func (c *TreeController) SelectRow(i int) bool {
	if i < 0 || i >= len(c.rows) {
		return false
	}
	changed := c.View.Sel != i
	c.View.Sel = i
	c.ensureVisible()
	return changed
}

// HandleKey is the keyboard contract: Up/Down/Home/End/PageUp/PageDown move,
// Right expands a collapsed branch or steps into it, Left collapses or jumps
// to the parent, Enter toggles a branch or activates a leaf, and printable
// runes are type-ahead over the visible rows.
func (c *TreeController) HandleKey(k Key) bool {
	if !c.valid() || c.View.Disabled {
		return false
	}
	handled := true
	switch k.Named() {
	case NamedUp:
		c.Move(-1)
	case NamedDown:
		c.Move(1)
	case NamedHome:
		c.Home()
	case NamedEnd:
		c.End()
	case NamedPageUp:
		c.Move(-c.View.VisibleRows())
	case NamedPageDown:
		c.Move(c.View.VisibleRows())
	case NamedRight:
		handled = c.right()
	case NamedLeft:
		handled = c.left()
	case NamedEnter:
		handled = c.enter()
	default:
		handled = false
	}
	if handled {
		c.prefix = c.prefix[:0]
		return true
	}
	if k.Rune != 0 && !k.Ctrl && !k.Alt {
		return c.typeAhead(k.Rune)
	}
	return false
}

func (c *TreeController) OnKey(k Key) bool { return c.HandleKey(k) }

// right implements the open-or-descend rule.
func (c *TreeController) right() bool {
	n := c.Selected()
	if n == nil || !n.Branch() {
		return false
	}
	if !n.Expanded {
		return c.Expand(n)
	}
	return c.Move(1) // the first child is the next row
}

// left implements the collapse-or-climb rule.
func (c *TreeController) left() bool {
	n := c.Selected()
	if n == nil {
		return false
	}
	if n.Branch() && n.Expanded {
		return c.Collapse(n)
	}
	if n.parent != nil {
		return c.SelectRow(c.rowOf(n.parent))
	}
	return false
}

func (c *TreeController) enter() bool {
	n := c.Selected()
	if n == nil {
		return false
	}
	if n.Branch() {
		return c.Toggle(n)
	}
	if c.OnActivate != nil {
		return c.OnActivate(n)
	}
	return false
}

// typeAhead jumps Sel to the next visible row whose label starts with the
// accumulated prefix. Repeating the same rune cycles through its matches —
// the classic single-letter hop. A miss on the extended prefix retries with
// just the new rune, so a stray key starts a fresh search.
func (c *TreeController) typeAhead(r rune) bool {
	r = foldASCII(r)
	same := len(c.prefix) > 0
	for _, p := range c.prefix {
		if p != r {
			same = false
			break
		}
	}
	from := c.View.Sel
	if same {
		// 'sss' hops to the next s-prefixed row.
		from = c.View.Sel + 1
	} else {
		c.prefix = append(c.prefix, r)
	}
	if i := c.matchRow(c.prefix, from); i >= 0 {
		c.SelectRow(i)
		return true
	}
	if len(c.prefix) > 1 {
		c.prefix = c.prefix[:0]
		c.prefix = append(c.prefix, r)
		if i := c.matchRow(c.prefix, c.View.Sel+1); i >= 0 {
			c.SelectRow(i)
		}
	}
	return len(c.prefix) > 0
}

// matchRow scans the flattened rows circularly from `from` for a label with
// the folded prefix, and returns its row or -1.
func (c *TreeController) matchRow(prefix []rune, from int) int {
	n := len(c.rows)
	if n == 0 || len(prefix) == 0 {
		return -1
	}
	for step := 0; step < n; step++ {
		i := (from + step) % n
		if i < 0 {
			i += n
		}
		if labelHasFoldedPrefix(c.rows[i].Label, prefix) {
			return i
		}
	}
	return -1
}

// foldASCII lowercases ASCII only — deterministic, locale-free, and enough
// for the outline's search.
func foldASCII(r rune) rune {
	if r >= 'A' && r <= 'Z' {
		return r + 'a' - 'A'
	}
	return r
}

func labelHasFoldedPrefix(label string, prefix []rune) bool {
	i := 0
	for _, r := range label {
		if i >= len(prefix) {
			return true
		}
		if foldASCII(r) != prefix[i] {
			return false
		}
		i++
	}
	return i == len(prefix)
}

// OnClick selects the hit row; a click inside a branch's chevron cell also
// toggles it.
func (c *TreeController) OnClick(x, y int) bool {
	if !c.valid() || c.View.Disabled || !c.View.HitTest(x, y) {
		return false
	}
	i := c.View.ItemAt(x, y)
	if i < 0 {
		return false
	}
	changed := c.SelectRow(i)
	if c.rows[i].Branch() && c.View.ChevronRect(i).Contains(x, y) {
		c.Toggle(c.rows[i])
		return true
	}
	return changed
}

func (c *TreeController) Bounds() widgets.Rect       { return c.View.Bounds() }
func (c *TreeController) HitTest(x, y int) bool      { return c.View.HitTest(x, y) }
func (c *TreeController) Draw(cv widgets.RectCanvas) { c.View.Draw(cv) }
func (c *TreeController) SetFocused(v bool)          { c.View.Focused = v }

func (c *TreeController) ensureVisible() {
	v := c.View
	if v == nil || v.R.H <= 0 {
		return
	}
	visible := v.VisibleRows()
	if visible < 1 {
		return
	}
	maxTop := len(c.rows) - visible
	if maxTop < 0 {
		maxTop = 0
	}
	if v.ScrollTop > maxTop {
		v.ScrollTop = maxTop
	}
	if v.Sel < v.ScrollTop {
		v.ScrollTop = v.Sel
	}
	if v.Sel >= v.ScrollTop+visible {
		v.ScrollTop = v.Sel - visible + 1
	}
	if v.ScrollTop < 0 {
		v.ScrollTop = 0
	}
}
