package appkit

import (
	"testing"

	"virelai/widgets"
)

var _ Focusable = &TreeController{}

func testTree() (*TreeController, *widgets.Tree, *TreeNode) {
	lazy := &TreeNode{Label: "services", Lazy: true, Load: func(*TreeNode) []*TreeNode {
		return []*TreeNode{{Label: "net"}, {Label: "wm"}}
	}}
	roots := []*TreeNode{
		{Label: "system", Expanded: true, Kids: []*TreeNode{
			{Label: "kernel"}, lazy,
		}},
		{Label: "apps", Kids: []*TreeNode{
			{Label: "gosheet"}, {Label: "goreader"},
		}},
		{Label: "docs"},
	}
	v := &widgets.Tree{R: widgets.Rect{X: 0, Y: 0, W: 160, H: 96}, RowH: 24}
	c := NewTreeController(v, roots)
	return c, v, lazy
}

func TestTreeReflowFlattensExpandedOnly(t *testing.T) {
	c, v, _ := testTree()
	// system(expanded) + kernel + services(lazy branch, collapsed) + apps
	// (collapsed) + docs = 5 visible rows.
	if len(v.Rows) != 5 || len(c.rows) != 5 {
		t.Fatalf("rows = %d, want 5", len(v.Rows))
	}
	if v.Rows[1].Depth != 1 || v.Rows[1].Label != "kernel" {
		t.Fatalf("row 1 = %+v", v.Rows[1])
	}
	if !v.Rows[2].HasKids || v.Rows[2].Expanded {
		t.Fatalf("lazy branch row = %+v", v.Rows[2])
	}
	if !v.Rows[3].HasKids {
		t.Fatal("collapsed branch must keep its chevron")
	}
	if v.Rows[4].HasKids {
		t.Fatal("leaf must not carry a chevron")
	}
}

// Lazy children materialize once, on first expand; the chevron marks the
// unloaded branch before then.
func TestTreeLazyChildrenLoadOnce(t *testing.T) {
	c, v, lazy := testTree()
	loads := 0
	lazy.Load = func(*TreeNode) []*TreeNode {
		loads++
		return []*TreeNode{{Label: "net"}, {Label: "wm"}}
	}
	c.SelectRow(2)
	if !c.OnKey(Key{Usage: 0x4f}) { // Right expands
		t.Fatal("Right on a collapsed branch must expand")
	}
	if loads != 1 || len(v.Rows) != 7 {
		t.Fatalf("expand: loads=%d rows=%d", loads, len(v.Rows))
	}
	if !v.Rows[2].Expanded || v.Rows[3].Label != "net" || v.Rows[3].Depth != 2 {
		t.Fatalf("expanded rows = %+v", v.Rows[2:5])
	}
	// Collapse + re-expand: kids stay materialized — Load never re-runs.
	c.SelectRow(2)
	c.OnKey(Key{Usage: 0x50}) // Left collapses
	c.SelectRow(2)
	c.OnKey(Key{Usage: 0x4f})
	if loads != 1 {
		t.Fatalf("Load ran %d times, want 1", loads)
	}
}

// Right on an expanded branch descends to its first child; Left collapses
// or climbs to the parent — the tree keyboard contract.
func TestTreeLeftRightSemantics(t *testing.T) {
	c, v, _ := testTree()
	c.SelectRow(0) // system (expanded)
	if !c.OnKey(Key{Usage: 0x4f}) || v.Sel != 1 {
		t.Fatalf("Right on expanded branch: sel=%d", v.Sel)
	}
	c.SelectRow(2) // services, collapsed → Right expands
	if !c.OnKey(Key{Usage: 0x4f}) || !v.Rows[2].Expanded {
		t.Fatal("Right must expand the collapsed branch")
	}
	if v.Sel != 2 {
		t.Fatalf("expand must not move sel: %d", v.Sel)
	}
	// Descend into it, then Left climbs back to the parent.
	c.OnKey(Key{Usage: 0x51})
	if v.Sel != 3 {
		t.Fatalf("sel = %d", v.Sel)
	}
	if !c.OnKey(Key{Usage: 0x50}) || v.Sel != 2 {
		t.Fatalf("Left must climb to parent: sel=%d", v.Sel)
	}
	// Left on the expanded branch collapses it.
	if !c.OnKey(Key{Usage: 0x50}) || v.Rows[2].Expanded {
		t.Fatal("Left must collapse the expanded branch")
	}
	if len(v.Rows) != 5 {
		t.Fatalf("collapse rows = %d, want 5", len(v.Rows))
	}
	// Left on a root-level leaf with no parent is inert.
	c.SelectRow(4)
	if c.OnKey(Key{Usage: 0x50}) {
		t.Fatal("Left on a root leaf must be inert")
	}
}

// Enter toggles a branch, activates a leaf through OnActivate.
func TestTreeEnterToggleAndActivate(t *testing.T) {
	c, v, _ := testTree()
	var fired *TreeNode
	c.OnActivate = func(n *TreeNode) bool { fired = n; return true }
	c.SelectRow(3) // apps — a collapsed branch
	if !c.OnKey(Key{Usage: 0x28}) || !v.Rows[3].Expanded {
		t.Fatal("Enter must expand a collapsed branch")
	}
	c.SelectRow(1) // kernel — a leaf
	if !c.OnKey(Key{Usage: 0x28}) || fired == nil || fired.Label != "kernel" {
		t.Fatalf("leaf activate: %+v", fired)
	}
}

// Type-ahead: a prefix jumps to the next matching visible row; repeating one
// rune cycles through its matches; a miss retries the single rune.
func TestTreeTypeAhead(t *testing.T) {
	c, v, lazy := testTree()
	// Materialize services' kids without expanding it, and open apps:
	// rows are system, kernel, services, apps, gosheet, goreader, docs.
	lazy.loaded, lazy.Lazy = true, false
	lazy.Kids = []*TreeNode{{Label: "net"}, {Label: "wm"}}
	c.Roots[1].Expanded = true
	c.Reflow()
	c.SelectRow(0)
	if !c.OnKey(Key{Rune: 'g'}) || v.Sel != 4 {
		t.Fatalf("'g' type-ahead sel = %d, want 4 (gosheet)", v.Sel)
	}
	if !c.OnKey(Key{Rune: 'g'}) || v.Sel != 5 {
		t.Fatalf("'g' again sel = %d, want 5 (goreader)", v.Sel)
	}
	// Same letter again wraps.
	if !c.OnKey(Key{Rune: 'g'}) || v.Sel != 4 {
		t.Fatalf("'g' wrap sel = %d, want 4", v.Sel)
	}
	// A named key clears the buffer; the next rune starts a fresh search.
	c.OnKey(Key{Usage: 0x52}) // sel 4 -> 3 (apps)
	if !c.OnKey(Key{Rune: 's'}) || v.Sel != 0 || c.rows[v.Sel].Label != "system" {
		t.Fatalf("'s' search sel = %d (%s)", v.Sel, c.rows[v.Sel].Label)
	}
	// 'k' lands on kernel.
	c.OnKey(Key{Usage: 0x52}) // clears the buffer; sel 0 -> 0
	if !c.OnKey(Key{Rune: 'k'}) || c.rows[v.Sel].Label != "kernel" {
		t.Fatalf("'k' search sel = %d", v.Sel)
	}
}

// A click selects its row; a click in the chevron cell toggles the branch.
func TestTreeClickSelectsAndChevronToggles(t *testing.T) {
	c, v, _ := testTree()
	r3 := v.RowRect(3)
	if !c.OnClick(r3.X+40, r3.Y+4) || v.Sel != 3 {
		t.Fatalf("row click sel = %d", v.Sel)
	}
	// The chevron cell of the lazy branch expands it on click.
	chev := v.ChevronRect(2)
	if !c.OnClick(chev.X+2, chev.Y+2) {
		t.Fatal("chevron click must consume")
	}
	if !v.Rows[2].Expanded {
		t.Fatal("chevron click must expand")
	}
	if c.OnClick(500, 500) {
		t.Fatal("outside click must not be consumed")
	}
}

// Scroll keeps the selection inside the window.
func TestTreeScrollIntoView(t *testing.T) {
	c, v, _ := testTree()
	// Four-row window over five rows: moving to the last scrolls.
	for i := 0; i < 6; i++ {
		c.OnKey(Key{Usage: 0x51})
	}
	if v.Sel != 4 || v.ScrollTop != 1 {
		t.Fatalf("sel=%d top=%d, want 4/1", v.Sel, v.ScrollTop)
	}
	c.OnKey(Key{Usage: 0x4a}) // Home
	if v.Sel != 0 || v.ScrollTop != 0 {
		t.Fatalf("home sel=%d top=%d", v.Sel, v.ScrollTop)
	}
	c.OnKey(Key{Usage: 0x4d}) // End
	if v.Sel != 4 || v.ScrollTop != 1 {
		t.Fatalf("end sel=%d top=%d", v.Sel, v.ScrollTop)
	}
}
