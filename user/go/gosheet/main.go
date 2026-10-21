// The M142a app shell, extended by M142b (#2790) with the CSV + session
// state half and by M152a (#2915) with the menu bar, fills, undo and
// column formats. Layout inside the window's canvas:
//
//	+----------------------------------------------------------+
//	| Edit  Format                  the M137b menu bar         |  y 20..44
//	| [A1]  [edit line — the focused cell's raw text]          |  y 48..72
//	| +------------------------------------------------------+ |
//	| | A  B  C ...        header (col letters)              | |
//	| | row-major cells, virtualized — the M137b table       | |  y 76..
//	| +------------------------------------------------------+ |
//	| status: focus, selection, display, fill count          |  bottom 20
//	+----------------------------------------------------------+
//
// Keys. Grid focused: arrows/Home/End/PgUp/PgDn move the cell cursor (the
// TableController's own vocabulary); a shifted move anchors the selection
// mark at the cell it left, ctrl-shift-m toggles a latched mark, ctrl-a
// selects the sheet's used bounding box, Escape drops the mark. Typing any
// printable character seeds the edit line with it (replace semantics, the
// sheet convention), Enter or Tab opens the edit line on the cell's
// existing text, Delete and Backspace clear the cell. F10 or Alt engages
// the menu bar, which owns the keyboard until it disengages.
//
// The M142b chords: ctrl-c serializes the marked range (or the cursor
// cell) as RFC 4180 CSV of the displayed values onto the text/csv
// clipboard lane — a body over the kernel's 512-byte bound refuses with
// `clip-too-large`; ctrl-v pastes clipboard text through the same codec,
// filling cells from the cursor; ctrl-o / ctrl-s raise the shared
// FilePicker for CSV import/export (export writes the used box's display
// values, never the raw formulas).
//
// The M152a surface: Edit ▸ Fill down/right/series fills the selection
// (numbers continue as a series, anything else copies; formulas shift
// their relative references); Format ▸ General/Integer/Fixed 2/Percent
// sets the display format of every column the selection spans — display
// only, so CSV export still writes raw values. Every mutating gesture
// pushes one record onto the 32-step undo ring; the seat's ctrl+z (the
// M121e route) pops it — the appkit Loop consumes ActionUndo itself, so
// the poll wrapper answers the chord ahead of it.
//
// Edit line focused: the TextField edits, Enter/Tab commit and return to
// the grid, Escape cancels. Committing writes the cell, re-evaluates, and
// prints the markers the go-sheet gate reads: `gosheet: set|clear` for the
// edited cell, `gosheet: recalc` for every other cell whose display
// changed, and `gosheet: cycle` naming the cells on a discovered cycle.
// Batch fills (import, paste, fill, undo, restore) print their own
// summary marker plus capped set/clear/recalc lines for the touched
// cells and the dependents outside the written region.
package main

import (
	"virelai/appkit"
	"virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/vsys"
	"virelai/widgets"
)

const (
	appName      = "GOSHEET.ELF"
	declareTitle = "GOSHEET.ELF" // the seat records the bin from this
	appTitle     = "Sheet"       // rail label after declare

	winX, winY = 64, 48
	natW, natH = 672, 420

	pad     = 8
	menuY   = 20 // below the kernel's 16px title band on the shim path
	menuH   = 24
	stripY  = 48
	nameW   = 56
	fieldH  = 24
	tableY  = 76
	statusH = 20

	colW     = 64
	rowH     = 20
	headerH  = 22
	fieldMax = 128

	// HID usage IDs for the ctrl chords (letters' usages are sequential).
	usageA = 0x04
	usageC = 0x06
	usageM = 0x10
	usageO = 0x12
	usageS = 0x16
	usageV = 0x19
	// usageZ is the M121e seat undo chord — tabapp pins the same 0x1D in
	// its Dispatch classifier; the poll wrapper matches it here because
	// the appkit Loop consumes ActionUndo without surfacing it.
	usageZ = 0x1D

	// recalcShow bounds the per-op recalc markers so a batch fill cannot
	// flood serial; the tail counts what was not printed.
	recalcShow = 16

	markerOpen    = "gosheet: open id="
	markerDecl    = "gosheet: declare accepted"
	markerDeclNo  = "gosheet: declare refused"
	markerPresent = "gosheet: present"
	markerSet     = "gosheet: set "
	markerClear   = "gosheet: clear "
	markerRecalc  = "gosheet: recalc "
	markerCycle   = "gosheet: cycle "
	markerFull    = "gosheet: full"
	markerMark    = "gosheet: mark "
	markerSel     = "gosheet: sel "
	markerCopy    = "gosheet: copy "
	markerPaste   = "gosheet: paste "
	markerPick    = "gosheet: pick "
	markerImport  = "gosheet: import "
	markerExport  = "gosheet: export "
	markerState   = "gosheet: state "
	markerFill    = "gosheet: fill "
	markerFmt     = "gosheet: fmt "
	markerUndo    = "gosheet: undo "
	markerClose   = "gosheet: close"
	markerOK      = "gosheet OK"
)

// Keep the kernel's argv/envp tail out of the runtime's first sbrk page —
// the same headroom the appkit demo reserves.
var argvHeadroom [0x1000]byte

// clipBuf is the paste staging buffer at the kernel's clipboard bound.
var clipBuf [vsys.ClipKernelMax]byte

type app struct {
	ta        *tabapp.TabApp
	sheet     *Sheet
	field     appkit.TextField
	table     *widgets.Table
	ctl       *appkit.TableController
	bar       appkit.MenuBar
	pick      appkit.FilePicker
	editing   bool
	lastCycle string
	// ring is the M152a undo history: 32 steps of pre-gesture diffs.
	ring undoRing
	// mark+markOn is the M142b selection: when latched, the marked range is
	// mark..cursor — what ctrl-c copies and the status line names.
	mark   cellRef
	markOn bool
	// pend/pendBad hold a restore blob between RestoreState (inside
	// tabapp.Init, before the table exists) and applyRestored.
	pend    *sheetState
	pendBad bool
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
	a := &app{sheet: newSheet()}
	ta := tabapp.Init(tabapp.Config{
		Name:         appName,
		Title:        declareTitle,
		X:            winX,
		Y:            winY,
		W:            natW,
		H:            natH,
		StateVersion: stateFmtVer,
		SaveState:    a.saveState,
		RestoreState: a.noteState,
		// M152a: the seat's ctrl+z routes to this tab through the M121e
		// hook — Dispatch classifies it ActionUndo, and the poll wrapper
		// calls Undo() ahead of the kit loop's own Dispatch.
		HandleUndo: a.undo,
	})
	if ta == nil {
		vi.ConsoleLine("gosheet: error open")
		vi.Exit(1)
	}
	a.ta = ta
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDecl)
		// The rail label is the friendly name; the recorded bin stays the
		// executable the declare carried (so ctrl-shift-t re-execs it).
		if !ta.SetTabTitle(appTitle) {
			_ = vi.WinSetTitle(ta.Win, appTitle)
		}
	} else {
		vi.ConsoleLine(markerDeclNo)
	}

	a.field = appkit.NewTextField(widgets.Rect{}, fieldMax)
	cols := make([]widgets.TableColumn, NumCols)
	for i := range cols {
		cols[i] = widgets.TableColumn{Title: colName(i), W: colW}
	}
	a.table = &widgets.Table{
		Cols: cols, Rows: NumRows, RowH: rowH, HeaderH: headerH,
		Row: 0, Col: 0, Focused: true,
	}
	a.table.Cell = func(r, c int) string { return a.sheet.show(refAt(c, r)) }
	a.ctl = appkit.NewTableController(a.table)
	a.ctl.OnActivate = func(_, _ int) bool { a.beginEdit(); return true }

	// M152a: the menu bar. Every item's Action mutates through the same
	// paths the chords use, so the undo ring sees menu gestures as one
	// step each; the bar's rect is laid out per frame in draw().
	a.bar.Menus = []appkit.Menu{
		{Title: "&Edit", Items: []appkit.MenuItem{
			{Label: "Fill &down", Action: func() bool { a.fill(fillDown); return true }},
			{Label: "Fill &right", Action: func() bool { a.fill(fillRight); return true }},
			{Label: "Fill &series", Action: func() bool { a.fill(fillSeries); return true }},
		}},
		{Title: "&Format", Items: []appkit.MenuItem{
			{Label: "&General", Action: func() bool { a.formatCols(fmtGeneral); return true }},
			{Label: "&Integer", Action: func() bool { a.formatCols(fmtInt); return true }},
			{Label: "&Fixed 2", Action: func() bool { a.formatCols(fmtFixed2); return true }},
			{Label: "&Percent", Action: func() bool { a.formatCols(fmtPct); return true }},
		}},
	}

	a.applyRestored()
	// A restored blob wins the session's argv — the re-exec runs the bare
	// bin, so the file lives only in the blob (the gopaint contract).
	if a.pend == nil && !a.pendBad {
		if args := vi.Args(); len(args) > 1 {
			a.importPath(args[1])
		}
	}

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
	// The save_state ask is mailbox traffic, not an input event (the gomine
	// idiom) — but it must answer after every delivered key: answering while
	// key-downs still sit in the queue would snapshot the pre-navigation
	// cursor (the seat posts its ask on ctrl-shift-w while the close-time
	// input burst is still draining). Answer only on an empty queue.
	//
	// The undo chord gets the same early service: the kit loop's Dispatch
	// consumes ActionUndo without a Handle call, so the seat's ctrl+z is
	// answered here — the hook repaints itself when a step reverts.
	loop.RunWith(func() (vi.Event, int64, bool) {
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			a.ta.PollStateAsk()
			return ev, r, ok
		}
		if isUndoChord(ev) && a.ta.Undo() {
			a.draw()
			a.ta.Present()
		}
		return ev, r, ok
	}, vi.Sleep)
}

// sel is the grid cursor as a cell address.
func (a *app) sel() cellRef { return refAt(a.table.Col, a.table.Row) }

// selSpan is the closed selection rect: the latched mark normalized
// against the cursor, or the cursor alone when no mark is live.
func (a *app) selSpan() (lo, hi cellRef) {
	cur := a.sel()
	if !a.markOn {
		return cur, cur
	}
	return cellRef{
		col: min(a.mark.col, cur.col),
		row: min(a.mark.row, cur.row),
	}, cellRef{
		col: max(a.mark.col, cur.col),
		row: max(a.mark.row, cur.row),
	}
}

// toggleMark is ctrl-shift-m: latch the mark at the cursor, or drop it.
func (a *app) toggleMark() {
	if a.markOn {
		a.markOn = false
		vi.ConsoleLine(markerMark + "off")
		return
	}
	a.mark = a.sel()
	a.markOn = true
	vi.ConsoleLine(markerMark + a.mark.String())
}

// selectUsed is ctrl-a: the used bounding box — mark at its top-left,
// cursor at its bottom-right. An empty sheet selects the cursor cell.
func (a *app) selectUsed() {
	lo, hi, ok := a.sheet.usedBBox()
	if !ok {
		a.markOn = false
		vi.ConsoleLine(markerSel + a.sel().String())
		return
	}
	a.mark, a.markOn = lo, true
	a.ctl.FocusCell(hi.row, hi.col)
	vi.ConsoleLine(markerSel + lo.String() + ":" + hi.String())
	a.syncBar()
}

// copySel writes the selected range to the text/csv lane. Over the 512-byte
// kernel bound the copy refuses whole with the card's named reason.
func (a *app) copySel() {
	lo, hi := a.selSpan()
	body := writeCSV(a.sheet.csvRows(lo, hi))
	if len(body) > vsys.ClipKernelMax {
		vi.ConsoleLine(markerCopy + "clip-too-large")
		return
	}
	n, rc := vsys.ClipboardSetTyped(vsys.ClipCSV, body)
	if rc < 0 {
		vi.ConsoleLine(markerCopy + "rc=" + vi.Itoa64(rc))
		return
	}
	vi.ConsoleLine(markerCopy + lo.String() + ":" + hi.String() +
		" n=" + vi.Itoa64(int64(n)))
}

// pasteClip reads the clipboard as text — the classification never lies
// about the bytes: CSV, plain text, URI lists and markup all parse through
// the same RFC 4180 lane; images and octets refuse by name. Fields fill
// from the cursor; a field that lands outside the grid or on a full store
// counts clipped, never half-written.
func (a *app) pasteClip() {
	mime, n, rc := vsys.ClipboardGetTyped(clipBuf[:])
	if rc < 0 {
		vi.ConsoleLine(markerPaste + "rc=" + vi.Itoa64(rc))
		return
	}
	if n == 0 {
		vi.ConsoleLine(markerPaste + "empty")
		return
	}
	switch mime {
	case vsys.ClipText, vsys.ClipCSV, vsys.ClipURIList, vsys.ClipHTML:
	default:
		vi.ConsoleLine(markerPaste + mime)
		return
	}
	rows := parseCSV(clipBuf[:n])
	at := a.sel()
	// The undo record: every target's pre-paste raw (refused writes drop
	// out of the recorded step because their raw never moved).
	var before []cellDiff
	for r, row := range rows {
		for c := range row {
			ref := refAt(at.col+c, at.row+r)
			before = append(before, cellDiff{r: ref, raw: a.sheet.raw(ref)})
		}
	}
	set, clipped, w := 0, 0, 0
	for r, row := range rows {
		if len(row) > w {
			w = len(row)
		}
		for c, f := range row {
			if !a.sheet.setQuiet(refAt(at.col+c, at.row+r), f) {
				clipped++
				continue
			}
			set++
		}
	}
	changed := a.sheet.recalc()
	a.commitUndo(before, nil)
	line := markerPaste + "n=" + vi.Itoa64(int64(set))
	if clipped > 0 {
		line += " clipped=" + vi.Itoa64(int64(clipped))
	}
	vi.ConsoleLine(line)
	// The pasted region becomes the selection — a follow-up ctrl-c copies
	// exactly what landed.
	a.mark, a.markOn = at, true
	a.ctl.FocusCell(at.row+len(rows)-1, at.col+w-1)
	vi.ConsoleLine(markerSel + at.String() + ":" + a.sel().String())
	a.reportOutside(changed, at, a.sel())
	a.syncBar()
}

// isUndoChord is the seat's ctrl+z as tabapp.Dispatch classifies it:
// plain Ctrl+Z, no shift or alt. The appkit Loop never surfaces
// ActionUndo, so the poll wrapper recognizes the chord itself.
func isUndoChord(ev vi.Event) bool {
	return ev.Kind == vi.EvKeyDown &&
		ev.Flags&vi.ModCtrl != 0 &&
		ev.Flags&(vi.ModShift|vi.ModAlt) == 0 &&
		uint8(ev.Arg0) == usageZ
}

// fill is the Edit ▸ Fill * action: snapshot the selection's raws for
// the undo record, write the fill through the quiet path, re-evaluate
// once, then announce the batch — the summary marker the gate reads,
// per-cell set/clear lines capped like every batch, and recalc lines
// for dependents outside the filled span.
func (a *app) fill(kind fillKind) {
	lo, hi := a.selSpan()
	var before []cellDiff
	for r := lo.row; r <= hi.row; r++ {
		for c := lo.col; c <= hi.col; c++ {
			ref := refAt(c, r)
			before = append(before, cellDiff{r: ref, raw: a.sheet.raw(ref)})
		}
	}
	written, clipped := fillRange(a.sheet, lo, hi, kind)
	changed := a.sheet.recalc()
	a.commitUndo(before, nil)
	line := markerFill + kind.String() + " " + lo.String() + ":" + hi.String() +
		" n=" + itoaDec(len(written))
	if clipped > 0 {
		line += " clipped=" + itoaDec(clipped)
	}
	vi.ConsoleLine(line)
	a.announce(before)
	a.reportOutside(changed, lo, hi)
	a.syncBar()
}

// announce prints set/clear lines for every cell whose raw the gesture
// changed, capped at recalcShow — the batch marker's per-cell detail.
func (a *app) announce(before []cellDiff) {
	shown, extra := 0, 0
	for _, d := range before {
		now := a.sheet.raw(d.r)
		if now == d.raw {
			continue
		}
		if shown >= recalcShow {
			extra++
			continue
		}
		if now == "" {
			vi.ConsoleLine(markerClear + d.r.String())
		} else {
			vi.ConsoleLine(markerSet + d.r.String() + " := '" + now +
				"' -> " + a.sheet.display(d.r))
		}
		shown++
	}
	if extra > 0 {
		vi.ConsoleLine(markerSet + "+" + itoaDec(extra) + " more")
	}
}

// formatCols is the Format ▸ * action: one display-format apply over
// every column the selection spans, recorded as a single undo step.
// Display-only — no recalc, nothing repaints but the affected cells.
func (a *app) formatCols(f colFmt) {
	lo, hi := a.selSpan()
	var before []fmtDiff
	for c := lo.col; c <= hi.col; c++ {
		before = append(before, fmtDiff{col: c, fmt: a.sheet.cfmt[c]})
	}
	for _, d := range before {
		a.sheet.cfmt[d.col] = f
	}
	a.commitUndo(nil, before)
	line := markerFmt + fmtName(f) + " cols=" + colName(lo.col)
	if hi.col != lo.col {
		line += ":" + colName(hi.col)
	}
	vi.ConsoleLine(line)
}

// openPick raises the shared FilePicker for CSV open/save.
func (a *app) openPick(kind appkit.PickerKind) {
	a.pick = appkit.NewFilePicker(kind, "/host")
	if kind == appkit.PickOpen {
		vi.ConsoleLine(markerPick + "open")
	} else {
		vi.ConsoleLine(markerPick + "save")
	}
}

// pickDone consumes the picker's Result once it closes.
func (a *app) pickDone() {
	res, kind := a.pick.Result, a.pick.Kind
	if res == "cancel" {
		vi.ConsoleLine(markerPick + "cancel")
		return
	}
	if kind == appkit.PickSave {
		vi.ConsoleLine(markerPick + "save " + res)
		a.exportPath(res)
		return
	}
	vi.ConsoleLine(markerPick + "open " + res)
	a.importPath(res)
}

// importPath replaces the sheet with a parsed CSV body. The whole file is
// refused before a single cell lands when it cannot fit the grid or the
// store bound — a partial import is never a sheet.
func (a *app) importPath(path string) bool {
	b, rc := vi.ReadFileAll(path, vi.MaxFileBytes)
	if rc < 0 {
		vi.ConsoleLine(markerImport + "refused read")
		return false
	}
	rows := parseCSV(b)
	w, n := 0, 0
	for _, row := range rows {
		if len(row) > w {
			w = len(row)
		}
		for _, f := range row {
			if f != "" {
				n++
			}
		}
	}
	if len(rows) > NumRows || w > NumCols || n > MaxCells {
		vi.ConsoleLine(markerImport + "refused too-large")
		return false
	}
	ns := newSheet()
	for r, row := range rows {
		for c, f := range row {
			ns.setQuiet(refAt(c, r), f)
		}
	}
	ns.recalc()
	// The undo record for a wholesale replace: every address either
	// sheet fills (the union) restores the old raw, and the column
	// formats roll back — a fresh sheet is all-general.
	var before []cellDiff
	for r := range a.sheet.cells {
		before = append(before, cellDiff{r: r, raw: a.sheet.cells[r].raw})
	}
	for r := range ns.cells {
		if _, was := a.sheet.cells[r]; !was {
			before = append(before, cellDiff{r: r})
		}
	}
	var fbefore []fmtDiff
	for c, f := range a.sheet.cfmt {
		if f != fmtGeneral {
			fbefore = append(fbefore, fmtDiff{col: c, fmt: f})
		}
	}
	a.sheet = ns
	a.commitUndo(before, fbefore)
	a.markOn = false
	a.lastCycle = ""
	vi.ConsoleLine(markerImport + path + " cells=" +
		vi.Itoa64(int64(ns.filled())) + " rows=" + vi.Itoa64(int64(len(rows))))
	a.syncBar()
	return true
}

// exportPath writes the used box's display values through the codec.
func (a *app) exportPath(path string) bool {
	var body []byte
	if lo, hi, ok := a.sheet.usedBBox(); ok {
		body = writeCSV(a.sheet.csvRows(lo, hi))
	}
	if rc := vi.WriteFileSafe(path, body); rc != 0 {
		vi.ConsoleLine(markerExport + "refused rc=" + vi.Itoa64(rc))
		return false
	}
	vi.ConsoleLine(markerExport + path + " n=" + vi.Itoa64(int64(len(body))))
	return true
}

// draw repaints the whole frame; the table only ever paints its visible
// window, so a full repaint is the cheap honest path.
func (a *app) draw() {
	w, h := int(a.ta.W), int(a.ta.H)
	c := a.ta.Canvas()
	th := theme.Current
	c.FillRect(widgets.Rect{W: w, H: h}, draw.Opaque(th.Bg))

	a.bar.R = widgets.Rect{X: 0, Y: menuY, W: w, H: menuH}
	a.field.R = widgets.Rect{X: pad + nameW, Y: stripY - 2, W: w - 2*pad - nameW, H: fieldH + 4}
	a.table.R = widgets.Rect{X: pad, Y: tableY, W: w - 2*pad, H: h - tableY - statusH - pad}

	widgets.DrawText(c, widgets.Rect{X: pad, Y: stripY, W: nameW - pad, H: fieldH}, a.sel().String(), draw.Opaque(th.Accent))
	a.field.Draw(c)
	a.table.Draw(c)
	widgets.DrawText(c, widgets.Rect{X: pad, Y: h - statusH, W: w - 2*pad, H: statusH}, a.status(), draw.Opaque(th.Muted))
	// The bar paints above the sheet but under the modal picker — an open
	// popover reads over the grid, and a modal owns the whole frame.
	a.bar.Draw(c)
	if a.pick.Open {
		a.pick.Draw(c)
	}
}

func (a *app) status() string {
	sel := a.sel()
	s := sel.String()
	if a.markOn {
		lo, hi := a.selSpan()
		s += "  sel " + lo.String() + ":" + hi.String()
	}
	if d := a.sheet.show(sel); d != "" {
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
	before := a.sheet.raw(sel)
	changed, ok := a.sheet.set(sel, raw)
	a.editing = false
	a.field.Focused = false
	a.table.Focused = true
	if !ok {
		vi.ConsoleLine(markerFull)
		return
	}
	a.commitUndo([]cellDiff{{r: sel, raw: before}}, nil)
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
	a.reportOutside(changed, sel, sel)
}

// reportOutside is report for a batch fill: cells inside the written region
// are announced by the batch marker itself, and the dependents' list is
// capped so a full-sheet import cannot flood serial.
func (a *app) reportOutside(changed []cellRef, lo, hi cellRef) {
	shown, extra := 0, 0
	for _, r := range changed {
		if r.col >= lo.col && r.col <= hi.col && r.row >= lo.row && r.row <= hi.row {
			continue
		}
		if shown >= recalcShow {
			extra++
			continue
		}
		vi.ConsoleLine(markerRecalc + r.String() + " -> " + a.sheet.display(r))
		shown++
	}
	if extra > 0 {
		vi.ConsoleLine(markerRecalc + "+" + vi.Itoa64(int64(extra)) + " more")
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
	if a.pick.Open {
		switch ev.Kind {
		case vi.EvKeyDown:
			if _, done := a.pick.HandleKey(ev); done {
				a.pickDone()
			}
			return true
		case vi.EvMouseDown:
			if _, done := a.pick.HandleMouse(int(ev.Arg0), int(ev.Arg1), true); done {
				a.pickDone()
			}
			return true
		}
		return true
	}
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

// navKey reports whether k is one of the cursor-move keys shift can extend
// a selection over.
func navKey(k appkit.Key) bool {
	switch k.Named() {
	case appkit.NamedLeft, appkit.NamedRight, appkit.NamedUp, appkit.NamedDown,
		appkit.NamedHome, appkit.NamedEnd, appkit.NamedPageUp, appkit.NamedPageDown:
		return true
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
	// The menu bar: inactive it answers F10/Alt/Alt-mnemonic and passes
	// everything else through; active it owns the keyboard outright.
	if a.bar.OnKey(k) {
		return true
	}
	if k.Ctrl && !navKey(k) {
		switch k.Usage {
		case usageA:
			if !k.Shift {
				a.selectUsed()
				return true
			}
		case usageC:
			if !k.Shift {
				a.copySel()
				return true
			}
		case usageV:
			if !k.Shift {
				a.pasteClip()
				return true
			}
		case usageO:
			if !k.Shift {
				a.openPick(appkit.PickOpen)
				return true
			}
		case usageS:
			if !k.Shift {
				a.openPick(appkit.PickSave)
				return true
			}
		case usageM:
			if k.Shift {
				a.toggleMark()
				return true
			}
		}
		return false
	}
	switch k.Named() {
	case appkit.NamedEnter, appkit.NamedTab:
		a.beginEdit()
		return true
	case appkit.NamedEscape:
		if a.markOn {
			a.toggleMark()
			return true
		}
		return false
	case appkit.NamedDelete, appkit.NamedBackspace:
		sel := a.sel()
		before := a.sheet.raw(sel)
		if before == "" {
			return false
		}
		changed, _ := a.sheet.set(sel, "")
		a.commitUndo([]cellDiff{{r: sel, raw: before}}, nil)
		vi.ConsoleLine(markerClear + sel.String())
		a.report(changed, sel)
		return true
	}
	// A shifted move anchors the mark at the cell it left — the keyboard's
	// own selection-extend gesture.
	if k.Shift && !a.markOn && navKey(k) {
		a.mark, a.markOn = a.sel(), true
		vi.ConsoleLine(markerMark + a.mark.String())
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
	// The bar and its open popover come first; a click anywhere while a
	// menu is up just disengages it (the kit's own convention).
	if a.bar.HitTest(x, y) || a.bar.Active {
		if a.editing {
			a.commit()
		}
		a.bar.OnClick(x, y)
		return true
	}
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
			// A fresh click re-anchors selection to the hit cell.
			a.markOn = false
			a.syncBar()
			return true
		}
	}
	return false
}
