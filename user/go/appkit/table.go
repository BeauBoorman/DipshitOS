package appkit

// The M137b (#2772) grid controller: keyboard cell focus and scroll-into-view
// over the pure widgets.Table — the ListController split applied to two
// dimensions. GOSHEET is the forcing consumer (128×64 cells): the widget
// virtualizes rows, the controller only ever moves Sel and the two scroll
// offsets, so a sheet-sized model costs nothing per keystroke.

import (
	"virelai/vi"
	"virelai/widgets"
)

// TableController drives a widgets.Table. Row/Col on the widget are the
// focused cell — the selection. OnActivate fires on Enter over a cell and
// reports whether app state changed (a repaint follows either way when the
// focus moved).
type TableController struct {
	Table      *widgets.Table
	OnActivate func(row, col int) bool
}

func NewTableController(t *widgets.Table) *TableController {
	return &TableController{Table: t}
}

func (c *TableController) valid() bool {
	return c != nil && c.Table != nil && c.Table.Rows > 0 && len(c.Table.Cols) > 0
}

// Move steps the focused cell, clamped to the model. The selection is the
// focus: there is no separate cursor.
func (c *TableController) Move(dr, dc int) bool {
	if !c.valid() {
		return false
	}
	t := c.Table
	row, col := t.Row, t.Col
	if row < 0 {
		row = 0
	}
	if col < 0 {
		col = 0
	}
	row += dr
	col += dc
	if row < 0 {
		row = 0
	}
	if row >= t.Rows {
		row = t.Rows - 1
	}
	if col < 0 {
		col = 0
	}
	if col >= len(t.Cols) {
		col = len(t.Cols) - 1
	}
	changed := row != t.Row || col != t.Col
	t.Row, t.Col = row, col
	c.ensureVisible()
	return changed
}

// Home/End jump to the first/last column of the row; with Ctrl they jump to
// the first/last cell of the model — the spreadsheet convention.
func (c *TableController) Home(ctrl bool) bool {
	if !c.valid() {
		return false
	}
	if ctrl {
		return c.jump(0, 0)
	}
	return c.jump(c.Table.Row, 0)
}

func (c *TableController) End(ctrl bool) bool {
	if !c.valid() {
		return false
	}
	if ctrl {
		return c.jump(c.Table.Rows-1, len(c.Table.Cols)-1)
	}
	return c.jump(c.Table.Row, len(c.Table.Cols)-1)
}

func (c *TableController) jump(row, col int) bool {
	if row < 0 {
		row = 0
	}
	changed := row != c.Table.Row || col != c.Table.Col
	c.Table.Row, c.Table.Col = row, col
	c.ensureVisible()
	return changed
}

// FocusCell parks the focus on (row, col), clamped, and scrolls it into view.
func (c *TableController) FocusCell(row, col int) bool {
	if !c.valid() {
		return false
	}
	if col < 0 {
		col = 0
	}
	if col >= len(c.Table.Cols) {
		col = len(c.Table.Cols) - 1
	}
	if row < 0 {
		row = 0
	}
	if row >= c.Table.Rows {
		row = c.Table.Rows - 1
	}
	return c.jump(row, col)
}

// HandleKey: arrows move the cell, Home/End are column ends (Ctrl: model
// corners), PageUp/PageDown page rows, Enter activates. Tab is left to the
// FocusRing.
func (c *TableController) HandleKey(k Key) bool {
	if !c.valid() || c.Table.Disabled {
		return false
	}
	switch k.Named() {
	case NamedUp:
		return c.Move(-1, 0)
	case NamedDown:
		return c.Move(1, 0)
	case NamedLeft:
		return c.Move(0, -1)
	case NamedRight:
		return c.Move(0, 1)
	case NamedHome:
		return c.Home(k.Ctrl)
	case NamedEnd:
		return c.End(k.Ctrl)
	case NamedPageUp:
		return c.Move(-c.Table.VisibleRows(), 0)
	case NamedPageDown:
		return c.Move(c.Table.VisibleRows(), 0)
	case NamedEnter:
		if c.Table.Row >= 0 && c.Table.Col >= 0 && c.OnActivate != nil {
			return c.OnActivate(c.Table.Row, c.Table.Col)
		}
	}
	return false
}

func (c *TableController) OnKey(k Key) bool { return c.HandleKey(k) }

// OnClick focuses the hit cell; a header click selects that column on the
// current row (row 0 when nothing is focused yet).
func (c *TableController) OnClick(x, y int) bool {
	if !c.valid() || c.Table.Disabled || !c.Table.HitTest(x, y) {
		return false
	}
	if r, col := c.Table.CellAt(x, y); r >= 0 && col >= 0 {
		c.Table.Row, c.Table.Col = r, col
		c.ensureVisible()
		return true
	}
	if col := c.Table.HeaderAt(x, y); col >= 0 {
		row := c.Table.Row
		if row < 0 {
			row = 0
		}
		c.FocusCell(row, col)
		return true
	}
	return false
}

// A11yTree reports the grid's outline (M177b #3143): the control node,
// one row node per column header, and one row node naming the focused
// cell's row — "row <i> of <n>" carries the index and the row count, the
// only data the outline is allowed to leak (D2: labels, never contents).
// The focused row is the focused item when the verdict lands here.
func (c *TableController) A11yTree(depth int, focused bool) []Node {
	self := Node{Depth: depth, Role: RoleTable, Name: "Table"}
	var t *widgets.Table
	if c != nil {
		t = c.Table
	}
	if t != nil && t.Disabled {
		self.State |= StateDisabled
	}
	hasCell := t != nil && t.Rows > 0 && t.Row >= 0 && t.Col >= 0
	if focused && !hasCell {
		self.State |= StateFocused
	}
	out := []Node{self}
	if t == nil {
		return out
	}
	for _, col := range t.Cols {
		out = append(out, Node{Depth: depth + 1, Role: RoleRow, Name: col.Title})
	}
	if hasCell {
		rn := Node{Depth: depth + 1, Role: RoleRow, State: StateSelected,
			Name: "row " + vi.Itoa64(int64(t.Row+1)) + " of " + vi.Itoa64(int64(t.Rows))}
		if focused {
			rn.State |= StateFocused
		}
		out = append(out, rn)
	}
	return out
}

func (c *TableController) Bounds() widgets.Rect       { return c.Table.Bounds() }
func (c *TableController) HitTest(x, y int) bool      { return c.Table.HitTest(x, y) }
func (c *TableController) Draw(cv widgets.RectCanvas) { c.Table.Draw(cv) }
func (c *TableController) SetFocused(v bool)          { c.Table.Focused = v }

// ensureVisible scrolls both axes until the focused cell is inside the
// visible window — ScrollTop in rows, ScrollX in pixels.
func (c *TableController) ensureVisible() {
	t := c.Table
	visible := t.VisibleRows()
	if visible > 0 {
		maxTop := t.Rows - visible
		if maxTop < 0 {
			maxTop = 0
		}
		if t.ScrollTop > maxTop {
			t.ScrollTop = maxTop
		}
		if t.Row >= 0 {
			if t.Row < t.ScrollTop {
				t.ScrollTop = t.Row
			}
			if t.Row >= t.ScrollTop+visible {
				t.ScrollTop = t.Row - visible + 1
			}
		}
		if t.ScrollTop < 0 {
			t.ScrollTop = 0
		}
	}
	if t.Col < 0 || len(t.Cols) == 0 {
		return
	}
	clip := t.ClipRect() // the widget's own paint bound — scrollbar deducted
	if clip.W <= 0 {
		return
	}
	x0 := t.ColX(t.Col) - t.ScrollX // cell x relative to body
	if x0 < 0 {
		t.ScrollX = t.ColX(t.Col)
	}
	if x0+t.ColW(t.Col) > clip.W {
		t.ScrollX = t.ColX(t.Col) + t.ColW(t.Col) - clip.W
	}
	t.ScrollX = t.ClampX()
}
