// The M142a app shell. Layout inside the window's canvas:
//
//	+----------------------------------------------------------+
//	| [A1]  [edit line — the focused cell's raw text]          |  y 20..44
//	| +------------------------------------------------------+ |
//	| | A  B  C ...        header (col letters)              | |
//	| | row-major cells, virtualized — the M137b table       | |  y 48..
//	| +------------------------------------------------------+ |
//	| status: focus, display, fill count                     |  bottom 20
//	+----------------------------------------------------------+
//
// Keys. Grid focused: arrows/Home/End/PgUp/PgDn move the cell cursor (the
// TableController's own vocabulary), typing any printable character seeds
// the edit line with it (replace semantics, the sheet convention), Enter
// or Tab opens the edit line on the cell's existing text, Delete and
// Backspace clear the cell. Edit line focused: the TextField edits,
// Enter/Tab commit and return to the grid, Escape cancels. Committing
// writes the cell, re-evaluates, and prints the markers the go-sheet gate
// reads: `gosheet: set|clear` for the edited cell, `gosheet: recalc` for
// every other cell whose display changed, and `gosheet: cycle` naming the
// cells on a discovered cycle.
package main

import (
	"virelai/appkit"
	"virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

const (
	appName  = "GOSHEET.ELF"
	appTitle = "Sheet"

	winX, winY = 64, 48
	natW, natH = 672, 420

	pad     = 8
	stripY  = 20 // below the kernel's 16px title band on the shim path
	nameW   = 56
	fieldH  = 24
	tableY  = 48
	statusH = 20

	colW     = 64
	rowH     = 20
	headerH  = 22
	fieldMax = 128

	markerOpen    = "gosheet: open id="
	markerDecl    = "gosheet: declare accepted"
	markerDeclNo  = "gosheet: declare refused"
	markerPresent = "gosheet: present"
	markerSet     = "gosheet: set "
	markerClear   = "gosheet: clear "
	markerRecalc  = "gosheet: recalc "
	markerCycle   = "gosheet: cycle "
	markerFull    = "gosheet: full"
	markerClose   = "gosheet: close"
	markerOK      = "gosheet OK"
)

// Keep the kernel's argv/envp tail out of the runtime's first sbrk page —
// the same headroom the appkit demo reserves.
var argvHeadroom [0x1000]byte

type app struct {
	ta        *tabapp.TabApp
	sheet     *Sheet
	field     appkit.TextField
	table     *widgets.Table
	ctl       *appkit.TableController
	editing   bool
	lastCycle string
}

func loadGuestTheme() {
	b, r := vi.ReadFileAll("/host/SETTINGS.TXT", 2048)
	if r < 0 || b == nil {
		return
	}
	_ = theme.ApplySettings(b)
}

func main() {
	loadGuestTheme()
	ta := tabapp.Init(tabapp.Config{Name: appName, Title: appTitle, X: winX, Y: winY, W: natW, H: natH})
	if ta == nil {
		vi.ConsoleLine("gosheet: error open")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDecl)
	} else {
		vi.ConsoleLine(markerDeclNo)
	}

	a := &app{ta: ta, sheet: newSheet()}
	a.field = appkit.NewTextField(widgets.Rect{}, fieldMax)
	cols := make([]widgets.TableColumn, NumCols)
	for i := range cols {
		cols[i] = widgets.TableColumn{Title: colName(i), W: colW}
	}
	a.table = &widgets.Table{
		Cols: cols, Rows: NumRows, RowH: rowH, HeaderH: headerH,
		Row: 0, Col: 0, Focused: true,
	}
	a.table.Cell = func(r, c int) string { return a.sheet.display(refAt(c, r)) }
	a.ctl = appkit.NewTableController(a.table)
	a.ctl.OnActivate = func(_, _ int) bool { a.beginEdit(); return true }

	loop := appkit.NewLoop(a.ta, a.draw, a.handle)
	if loop.SubscribeSetting("theme", func(value string) bool {
		return theme.Set(value)
	}) {
		vi.ConsoleLine("gosheet: settings subscribed key=theme")
	}
	loop.OnInitialPresent = func() { vi.ConsoleLine(markerPresent) }
	loop.OnExit = func(status int) {
		vi.ConsoleLine(markerClose)
		vi.ConsoleLine(markerOK)
		a.ta.CloseAndExit(status)
	}
	loop.Run()
}

// sel is the grid cursor as a cell address.
func (a *app) sel() cellRef { return refAt(a.table.Col, a.table.Row) }

// draw repaints the whole frame; the table only ever paints its visible
// window, so a full repaint is the cheap honest path.
func (a *app) draw() {
	w, h := int(a.ta.W), int(a.ta.H)
	c := a.ta.Canvas()
	th := theme.Current
	c.FillRect(widgets.Rect{W: w, H: h}, draw.Opaque(th.Bg))

	a.field.R = widgets.Rect{X: pad + nameW, Y: stripY - 2, W: w - 2*pad - nameW, H: fieldH + 4}
	a.table.R = widgets.Rect{X: pad, Y: tableY, W: w - 2*pad, H: h - tableY - statusH - pad}

	widgets.DrawText(c, widgets.Rect{X: pad, Y: stripY, W: nameW - pad, H: fieldH}, a.sel().String(), draw.Opaque(th.Accent))
	a.field.Draw(c)
	a.table.Draw(c)
	widgets.DrawText(c, widgets.Rect{X: pad, Y: h - statusH, W: w - 2*pad, H: statusH}, a.status(), draw.Opaque(th.Muted))
}

func (a *app) status() string {
	sel := a.sel()
	s := sel.String()
	if d := a.sheet.display(sel); d != "" {
		s += " -> " + d
	}
	s += "  cells " + vi.Itoa64(int64(a.sheet.filled())) + "/" + vi.Itoa64(MaxCells)
	if a.editing {
		s += "  [edit]"
	}
	return s
}

// syncBar keeps the edit line showing the focused cell's raw text while it
// is not being edited — the formula-bar contract.
func (a *app) syncBar() {
	if !a.editing {
		a.field.SetValue(a.sheet.raw(a.sel()))
	}
}

func (a *app) beginEdit() {
	a.editing = true
	a.field.Focused = true
	a.table.Focused = false
}

func (a *app) startEditWith(r rune) {
	a.field.SetValue(string(r))
	a.beginEdit()
}

func (a *app) cancelEdit() {
	a.editing = false
	a.field.Focused = false
	a.table.Focused = true
	a.syncBar()
}

// commit writes the edit line to the focused cell, re-evaluates, and
// prints the gate markers. The bar then returns to mirroring the cell.
func (a *app) commit() {
	sel := a.sel()
	raw := a.field.Value()
	changed, ok := a.sheet.set(sel, raw)
	a.editing = false
	a.field.Focused = false
	a.table.Focused = true
	if !ok {
		vi.ConsoleLine(markerFull)
		return
	}
	if raw == "" {
		vi.ConsoleLine(markerClear + sel.String())
	} else {
		vi.ConsoleLine(markerSet + sel.String() + " := '" + raw + "' -> " + a.sheet.display(sel))
	}
	a.report(changed, sel)
	a.syncBar()
}

// report prints one recalc marker per cell whose display changed (other
// than the edited cell itself), then the cycle marker when the cycle set
// moved.
func (a *app) report(changed []cellRef, sel cellRef) {
	for _, r := range changed {
		if r == sel {
			continue
		}
		vi.ConsoleLine(markerRecalc + r.String() + " -> " + a.sheet.display(r))
	}
	cyc := ""
	for _, r := range a.sheet.cycleRefs() {
		if cyc != "" {
			cyc += ","
		}
		cyc += r.String()
	}
	if cyc != a.lastCycle {
		a.lastCycle = cyc
		if cyc != "" {
			vi.ConsoleLine(markerCycle + cyc)
		}
	}
}

func (a *app) handle(ev vi.Event) bool {
	switch ev.Kind {
	case vi.EvKeyDown:
		k, ok := appkit.NormalizeKey(ev)
		if !ok {
			return false
		}
		return a.key(k)
	case vi.EvMouseDown:
		return a.click(int(ev.Arg0), int(ev.Arg1))
	}
	return false
}

func (a *app) key(k appkit.Key) bool {
	if a.editing {
		switch k.Named() {
		case appkit.NamedEnter, appkit.NamedTab:
			a.commit()
			return true
		case appkit.NamedEscape:
			a.cancelEdit()
			return true
		}
		return a.field.OnKey(k)
	}
	switch k.Named() {
	case appkit.NamedEnter, appkit.NamedTab:
		a.beginEdit()
		return true
	case appkit.NamedDelete, appkit.NamedBackspace:
		sel := a.sel()
		if a.sheet.raw(sel) == "" {
			return false
		}
		changed, _ := a.sheet.set(sel, "")
		vi.ConsoleLine(markerClear + sel.String())
		a.report(changed, sel)
		return true
	}
	if !k.Ctrl && !k.Alt && k.Rune != 0 {
		a.startEditWith(k.Rune)
		return true
	}
	if a.ctl.HandleKey(k) {
		a.syncBar()
		return true
	}
	return false
}

func (a *app) click(x, y int) bool {
	if a.field.HitTest(x, y) {
		if !a.editing {
			a.beginEdit()
		}
		return a.field.OnClick(x, y) || true
	}
	if a.table.HitTest(x, y) {
		if a.editing {
			a.commit()
		}
		if a.ctl.OnClick(x, y) {
			a.syncBar()
			return true
		}
	}
	return false
}
