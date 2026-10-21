// Command gopaint is GOPAINT.ELF — the M141a paint app: a draw-v2 document
// canvas (the doc in doc.go, never the window surface) with a brush, line,
// rectangle, flood fill and eraser over a fixed 16-color palette at two
// brush sizes; QOI save/open through the shared FilePicker plus 'x' PNG
// export (issue #2976); a drop replaces
// the canvas behind a confirm dialog; and ctrl+z reverts through the undo
// ring.
//
// Seat notes, in one place:
//   - The declared title is the BINARY NAME, not "Paint": the seat derives a
//     tab's recorded bin from the declare title (gotabwm's guessBin default
//     arm), and both the M124a drop admission (opens= lookup by bin) and the
//     M125a reopen re-exec resolve through it. SetTabTitle repaints the rail
//     label "Paint" after the declare — the recorded bin stays GOPAINT.ELF.
//   - Pointer input only reaches a canvas window under the bare shim (the
//     seat's content forward is terminal-only), so the draw/save/undo legs
//     of the go-paint gate run shim-mode like go-calc's pad leg; the drop
//     and session legs run under GOTABWM where those paths live.
//
// Every marker prints only AFTER the syscall it reports returned, so the
// gate's asserts can only pass if the app actually ran.
package main

import (
	"errors"
	"strconv"
	"strings"

	"virelai/appkit"
	"virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/webrender"
	"virelai/webrender/qoi"
	"virelai/widgets"
)

const (
	appName = "GOPAINT.ELF"

	// declareTitle is what guessBin must record: the executable's own name
	// (its default arm is the title verbatim — there is no alias row for
	// this app and the seat files are out of scope).
	declareTitle = "GOPAINT.ELF"
	tabTitle     = "Paint"

	// Native window under the shim; the seat overrides via WIN_RESIZE.
	winX = 24
	winY = 24
	natW = 832
	natH = 600

	// Chrome geometry, window-local px. bandH clears the kernel's 16px
	// shim title band, so nothing interactive ever sits under it.
	bandH   = 24
	statusH = 16
	toolW   = 56 // left toolbar column width
	docOrgX = 64 // the document's window-local origin
	docOrgY = 32

	exitQuit = 45 // this app's own status (GOVIEW kept 43)

	// fileMax bounds a single image read — sized for the worst legal QOI
	// (header + 5 B/px over the max canvas + trailer ≈ 3.9 MiB).
	fileMax = 4 << 20
)

// The marker lines the class-B gate greps; class-A pins their literals.
const (
	markerOpen     = "gopaint: open id="
	markerAware    = "gopaint: tab-aware"
	markerNotAware = "gopaint: not-tab-aware"
	markerCanvas   = "gopaint: canvas "
	markerReady    = "gopaint: ready"
	markerPresent  = "gopaint: present"
	markerTool     = "gopaint: tool "
	markerSize     = "gopaint: size "
	markerColor    = "gopaint: color "
	markerCommit   = "gopaint: commit " // "<tool> n=<touched> sum=<fnv>"
	markerUndo     = "gopaint: undo "   // "depth=N sum=<fnv> probe=<px>" / "empty"
	markerPick     = "gopaint: pick "   // "open|save|export" at raise, "<verb> <path>" / "cancel" at result
	markerSaved    = "gopaint: saved "  // "<path> n=<bytes> sum=<fnv>"
	markerSaveErr  = "gopaint: save refused "
	markerExported = "gopaint: exported " // "<path> fmt=png n=<bytes> sum=<fnv>"
	markerXportErr = "gopaint: export refused "
	markerLoaded   = "gopaint: loaded " // "<path> WxH sum=<fnv>"
	markerOpenErr  = "gopaint: open refused "
	markerDrop     = "gopaint: drop " // "<mime> WxH sum=<fnv>"
	markerDropAsk  = "gopaint: drop-confirm"
	markerDropNo   = "gopaint: drop cancel"
	markerDropErr  = "gopaint: drop refused "
	markerState    = "gopaint: state " // "restored file= tool=" / "stale"
	markerResize   = "gopaint: resize "
	markerQuit     = "gopaint: quit"
	markerWinClose = "gopaint: win_close"
	markerOK       = "gopaint OK"
)

// fnv16 renders a digest as fixed-width hex for markers.
func fnv16(v uint64) string {
	const hex = "0123456789abcdef"
	var b [16]byte
	for i := 0; i < 16; i++ {
		b[15-i] = hex[v&15]
		v >>= 4
	}
	return string(b[:])
}

// px8 renders one 0xAARRGGBB word for probe markers.
func px8(v uint32) string {
	const hex = "0123456789abcdef"
	var b [8]byte
	for i := 0; i < 8; i++ {
		b[7-i] = hex[v&15]
		v >>= 4
	}
	return "0x" + string(b[:])
}

// The vi seams — real bindings in the guest, substitutable in host tests
// (the picker/console precedent in appkit/edit).
var (
	conLine   = vi.ConsoleLine
	openFile  = vi.FileOpen
	readFile  = vi.FileRead
	closeFile = vi.FileClose
	writeSafe = vi.WriteFileSafe
)

type app struct {
	ta *tabapp.TabApp
	d  *doc

	tool  toolID
	size  int // index into brushSizes
	color int // palette index

	// Live gesture state: anchor is the press point for line/rect and the
	// last stamped point for brush/erase; cur is the pointer's current doc
	// position (the rubber-band's free end); txn is the gesture's open
	// undo record.
	down        bool
	anchor, cur pt
	txn         *txn

	pick appkit.FilePicker
	// pickExport marks a PickSave picker raised by Export PNG — its result
	// routes to exportPNG, not save.
	pickExport bool
	dlg        appkit.Dialog
	// dialogAsk is what the open dialog answers: "drop" replaces the
	// canvas with the staged decode, "open" precedes the file picker.
	dialogAsk  string
	dropMime   string
	dropW      int
	dropH      int
	dropPixels []uint32

	mode modeID

	pend    *paintState // decoded restore blob, applied after first load
	pendBad bool
}

type modeID uint8

const (
	modePaint modeID = iota
	modePicker
	modeDialog
)

func main() {
	args := vi.Args()
	path := ""
	if len(args) > 1 {
		path = args[1]
	}

	a := &app{tool: toolBrush, color: 8, d: newDoc(docDefW, docDefH)}
	ta := tabapp.Init(tabapp.Config{
		Name:         appName,
		Title:        declareTitle,
		X:            winX,
		Y:            winY,
		W:            natW,
		H:            natH,
		StateVersion: stateAppVer,
		SaveState:    a.saveState,
		RestoreState: a.noteState,
		DropTarget: func(offer tabapp.DragOffer) {
			a.dropOffer(offer)
			a.draw()
			a.ta.Present()
		},
		HandleUndo: func() bool {
			if !a.d.hist.undo(a.d) {
				conLine(markerUndo + "empty")
				return false
			}
			conLine(markerUndo + "depth=" + strconv.Itoa(a.d.hist.depth()) +
				" sum=" + fnv16(a.d.sum()) + " probe=" + probeText(a.d))
			return true
		},
	})
	if ta == nil {
		conLine("gopaint: failed to open window")
		vi.Exit(1)
	}
	a.ta = ta
	conLine(markerOpen + strconv.Itoa(ta.Win) + " " + strconv.Itoa(int(ta.W)) + "x" + strconv.Itoa(int(ta.H)))
	if ta.TabAware {
		conLine(markerAware)
		// The rail label is the friendly name; the recorded bin stays the
		// executable the declare carried.
		if !ta.SetTabTitle(tabTitle) {
			_ = vi.WinSetTitle(ta.Win, tabTitle)
		}
	} else {
		conLine(markerNotAware)
	}
	if path != "" {
		a.load(path)
	}
	// A restored blob wins the session's argv — the re-exec runs the bare
	// bin, so the file lives only in the blob.
	a.applyRestored()
	conLine(markerCanvas + strconv.Itoa(a.d.w) + "x" + strconv.Itoa(a.d.h))
	a.draw()
	ta.Present()
	conLine(markerPresent)
	conLine(markerReady)
	a.eventLoop()
}

func (a *app) eventLoop() {
	for {
		a.ta.PollStateAsk()
		a.ta.PollDrag()
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				conLine(markerWinClose)
				conLine(markerOK)
				a.ta.CloseAndExit(exitQuit)
			}
			vi.Sleep(1)
			continue
		}
		switch a.ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			conLine(markerWinClose)
			conLine(markerOK)
			a.ta.CloseAndExit(exitQuit)
		case tabapp.ActionResized:
			conLine(markerResize + strconv.Itoa(int(a.ta.W)) + "x" + strconv.Itoa(int(a.ta.H)))
			a.draw()
			a.ta.Present()
		case tabapp.ActionUndo:
			if a.ta.Undo() {
				a.draw()
				a.ta.Present()
			}
		case tabapp.ActionNone:
			if a.handle(ev) {
				a.draw()
				a.ta.Present()
			}
		}
	}
}

// ---------------------------------------------------------------------------
// State protocol (M125a): the blob carries file + tool + selection.
// ---------------------------------------------------------------------------

func (a *app) saveState() []byte {
	return paintState{
		path:  a.d.path,
		tool:  a.tool,
		size:  a.size,
		color: a.color,
		dirty: a.d.dirty,
	}.encode()
}

func (a *app) noteState(b []byte) {
	s, ok := decodeState(b)
	if !ok {
		a.pendBad = true
		return
	}
	a.pend = &s
}

// applyRestored applies the decoded blob: the path re-loads through the
// same path as argv open, tool/size/color land on the selectors. A blob
// that failed to decode, or whose file no longer loads, degrades to the
// argv state — the marker names which happened.
func (a *app) applyRestored() {
	if a.pendBad {
		conLine(markerState + "stale")
		return
	}
	if a.pend == nil {
		return
	}
	s := *a.pend
	a.tool, a.size, a.color = s.tool, s.size, s.color
	if s.path != "" {
		a.load(s.path)
	}
	conLine(markerState + "restored file=" + s.path + " tool=" + toolName(a.tool))
}

// ---------------------------------------------------------------------------
// File IO: open/save through the shared picker, the image decode owned here.
// ---------------------------------------------------------------------------

// decodeImage turns file bytes into a document raster. webrender.DecodeImage
// owns the format sniff (QOI/PNG/SVG); a QOI past the web caps (a full-size
// canvas is 786432 px, over webrender's 262144-pixel image bound) retries
// through the shared leaf under THIS app's canvas cap — the decode is the
// same code either way.
func decodeImage(data []byte) (w, h int, pix []uint32, err error) {
	im, err := webrender.DecodeImage(data)
	if err == nil {
		return im.Width, im.Height, im.Pix, nil
	}
	if len(data) >= 4 && string(data[:4]) == "qoif" {
		return qoi.Decode(data, docMaxW, docMaxPx)
	}
	return 0, 0, nil, err
}

// readAll reads a whole file with the app's own bound (vi.ReadFileAll would
// silently clamp at 256 KiB, truncating a legal big QOI into a decode error).
func readAll(path string) ([]byte, int64) {
	h, r := openFile(path, vi.ModeRead)
	if r < 0 {
		return nil, r
	}
	defer closeFile(uint32(h))
	out := make([]byte, 0, 4096)
	buf := make([]byte, 4096)
	for len(out) < fileMax {
		n, rr := readFile(uint32(h), buf)
		if rr < 0 {
			return out, rr
		}
		if n == 0 {
			break
		}
		take := n
		if len(out)+take > fileMax {
			take = fileMax - len(out)
		}
		out = append(out, buf[:take]...)
		if take < n {
			break
		}
	}
	if len(out) == fileMax {
		if n, rr := readFile(uint32(h), buf[:1]); rr >= 0 && n > 0 {
			return out, -vi.ErrENOSPC
		}
	}
	return out, 0
}

// load reads+decodes path into the document. The refusal name the marker
// carries is the step that failed — the same vocabulary GOVIEW kept.
func (a *app) load(path string) bool {
	data, r := readAll(path)
	if r < 0 {
		why := "open"
		switch {
		case r == -vi.ErrENOSPC:
			why = "too-large"
		case len(data) > 0:
			why = "read"
		}
		conLine(markerOpenErr + why)
		return false
	}
	w, h, pix, err := decodeImage(data)
	if err != nil {
		if errors.Is(err, webrender.ErrImageUnsupported) {
			conLine(markerOpenErr + "unsupported")
		} else {
			conLine(markerOpenErr + "decode")
		}
		return false
	}
	if w > docMaxW || h > docMaxH || w*h > docMaxPx {
		conLine(markerOpenErr + "too-large")
		return false
	}
	a.d = docFrom(w, h, pix)
	a.d.path = path
	a.d.dirty = false
	a.d.hist.clear()
	conLine(markerLoaded + path + " " + strconv.Itoa(w) + "x" + strconv.Itoa(h) +
		" sum=" + fnv16(a.d.sum()))
	return true
}

// save encodes the document as QOI and publishes it through the safe-write
// temp+rename path.
func (a *app) save(path string) bool {
	enc := qoi.Encode(a.d.pix, a.d.w, a.d.h)
	if rc := writeSafe(path, enc); rc != 0 {
		conLine(markerSaveErr + "rc=" + strconv.FormatInt(rc, 10))
		return false
	}
	a.d.path = path
	a.d.dirty = false
	conLine(markerSaved + path + " n=" + strconv.Itoa(len(enc)) + " sum=" + fnv16(a.d.sum()))
	return true
}

// export is the 'x' key: the PNG copy of the canvas. A document with a
// file association exports next to it — the same stem with the extension
// swapped to .png (.PNG when the old extension was uppercase); a document
// that has never been saved or loaded raises the save picker instead, so
// export never depends on a prior QOI save.
func (a *app) export() bool {
	if a.d.path == "" {
		a.openPick(appkit.PickSave)
		a.pick.Title = "Export PNG"
		a.pickExport = true
		conLine(markerPick + "export")
		return true
	}
	return a.exportPNG(exportPath(a.d.path))
}

// exportPNG encodes the document as PNG and publishes it through the same
// safe-write temp+rename path save uses. The export is a copy: the
// document keeps its QOI association and dirty state.
func (a *app) exportPNG(path string) bool {
	enc := webrender.EncodePNG(a.d.pix, a.d.w, a.d.h)
	if enc == nil {
		conLine(markerXportErr + "encode")
		return false
	}
	if rc := writeSafe(path, enc); rc != 0 {
		conLine(markerXportErr + "rc=" + strconv.FormatInt(rc, 10))
		return false
	}
	conLine(markerExported + path + " fmt=png n=" + strconv.Itoa(len(enc)) +
		" sum=" + fnv16(a.d.sum()))
	return true
}

// exportPath derives the PNG twin of a document path: the stem keeps its
// directory and the extension swaps case-sensitively — PAINT1.QOI exports
// as PAINT1.PNG, seed.qoi as seed.png.
func exportPath(path string) string {
	i := strings.LastIndexByte(path, '/')
	dir, base := "", path
	if i >= 0 {
		dir, base = path[:i+1], path[i+1:]
	}
	ext := ".png"
	if j := strings.LastIndexByte(base, '.'); j >= 0 {
		if j+1 < len(base) {
			upper := true
			for k := j + 1; k < len(base); k++ {
				if c := base[k]; c < 'A' || c > 'Z' {
					upper = false
					break
				}
			}
			if upper {
				ext = ".PNG"
			}
		}
		base = base[:j]
	}
	return dir + base + ext
}

// ---------------------------------------------------------------------------
// Drop target (M124a): decode the offer, confirm, then replace the canvas.
// ---------------------------------------------------------------------------

func (a *app) dropOffer(offer tabapp.DragOffer) {
	if offer.Blob == nil {
		conLine(markerDropErr + "no-payload")
		return
	}
	w, h, pix, err := decodeImage(offer.Blob)
	if err != nil {
		if errors.Is(err, webrender.ErrImageUnsupported) {
			conLine(markerDropErr + "unsupported")
		} else {
			conLine(markerDropErr + "decode")
		}
		return
	}
	if w > docMaxW || h > docMaxH || w*h > docMaxPx {
		conLine(markerDropErr + "too-large")
		return
	}
	a.dropMime, a.dropW, a.dropH, a.dropPixels = offer.Mime, w, h, pix
	a.dlg = appkit.NewConfirm("Replace canvas", "Drop replaces the current canvas. Continue?")
	a.dialogAsk = "drop"
	a.mode = modeDialog
	conLine(markerDropAsk)
}

// applyDrop commits a confirmed drop: the document becomes the payload's
// raster, its file association clears (the bytes are not the old path's),
// and the undo ring starts over — a replaced canvas is a new document.
func (a *app) applyDrop() {
	a.d = docFrom(a.dropW, a.dropH, a.dropPixels)
	a.dropPixels = nil
	conLine(markerDrop + a.dropMime + " " + strconv.Itoa(a.d.w) + "x" + strconv.Itoa(a.d.h) +
		" sum=" + fnv16(a.d.sum()))
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

const (
	keyCtrlO = 0x0f
	keyCtrlS = 0x13
	codeEsc  = 0x1b
)

// handle consumes one event in the app's current mode; true repaints.
func (a *app) handle(ev vi.Event) bool {
	switch a.mode {
	case modePicker:
		return a.pickerKey(ev)
	case modeDialog:
		return a.dialogKey(ev)
	}
	switch ev.Kind {
	case vi.EvKeyDown:
		return a.canvasKey(ev)
	case vi.EvMouseDown:
		return a.mouseDown(int(ev.Arg0), int(ev.Arg1))
	case vi.EvMouseMove:
		if a.down {
			return a.mouseMove(int(ev.Arg0), int(ev.Arg1))
		}
	case vi.EvMouseUp:
		if a.down {
			return a.mouseUp(int(ev.Arg0), int(ev.Arg1))
		}
	}
	return false
}

// canvasKey is the paint mode's keyboard surface: tool letters, palette and
// size steps, and the picker chords. ctrl+z never arrives here — Dispatch
// already classified it ActionUndo.
func (a *app) canvasKey(ev vi.Event) bool {
	if ev.Flags&vi.ModCtrl != 0 {
		switch ev.Arg1 {
		case keyCtrlO:
			a.startOpen()
			return true
		case keyCtrlS:
			a.openPick(appkit.PickSave)
			conLine(markerPick + "save")
			return true
		}
		return false
	}
	switch ev.Arg1 {
	case 'q', codeEsc:
		conLine(markerQuit)
		a.ta.CloseAndExit(exitQuit)
	case 'x':
		return a.export()
	case 'b':
		return a.setTool(toolBrush)
	case 'l':
		return a.setTool(toolLine)
	case 'r':
		return a.setTool(toolRect)
	case 'f':
		return a.setTool(toolFill)
	case 'e':
		return a.setTool(toolErase)
	case '[':
		return a.setColor(a.color - 1)
	case ']':
		return a.setColor(a.color + 1)
	case '-':
		return a.setSize(a.size - 1)
	case '=':
		return a.setSize(a.size + 1)
	case '1', '2', '3', '4', '5', '6', '7', '8':
		return a.setColor(int(ev.Arg1 - '1'))
	}
	return false
}

func (a *app) setTool(t toolID) bool {
	if a.tool == t {
		return false
	}
	a.tool = t
	conLine(markerTool + toolName(t))
	return true
}

func (a *app) setSize(i int) bool {
	i = clampi(i, 0, len(brushSizes)-1)
	if i == a.size {
		return false
	}
	a.size = i
	conLine(markerSize + strconv.Itoa(brushSizes[i]))
	return true
}

func (a *app) setColor(i int) bool {
	i = clampi(i, 0, len(palette)-1)
	if i == a.color {
		return false
	}
	a.color = i
	conLine(markerColor + strconv.Itoa(i))
	return true
}

// --- pointer (the shim delivers window-local coords; a seat never forwards) --

func (a *app) docAt(x, y int) (int, int, bool) {
	dx, dy := x-docOrgX, y-docOrgY
	return dx, dy, dx >= 0 && dy >= 0 && dx < a.d.w && dy < a.d.h
}

func (a *app) mouseDown(x, y int) bool {
	if t, ok := toolHit(x, y); ok {
		return a.setTool(t)
	}
	if s, ok := sizeHit(x, y); ok {
		return a.setSize(s)
	}
	if c, ok := paletteHit(x, y); ok {
		return a.setColor(c)
	}
	dx, dy, ok := a.docAt(x, y)
	if !ok {
		return false
	}
	p := pt{dx, dy}
	switch a.tool {
	case toolFill:
		// The fill gesture is the press itself — no drag exists to preview.
		t := a.d.begin()
		n := t.fill(p.x, p.y, palette[a.color])
		a.d.commit(t)
		conLine(markerCommit + "fill n=" + strconv.Itoa(n) + " sum=" + fnv16(a.d.sum()) +
			" probe=" + probeText(a.d))
		return true
	}
	a.down = true
	a.anchor, a.cur = p, p
	a.txn = a.d.begin()
	if a.tool == toolBrush || a.tool == toolErase {
		a.txn.segment(p, p, brushSizes[a.size]/2, a.paintColor())
	}
	return true
}

func (a *app) mouseMove(x, y int) bool {
	p := pt{x - docOrgX, y - docOrgY}
	switch a.tool {
	case toolBrush, toolErase:
		a.txn.segment(a.anchor, p, brushSizes[a.size]/2, a.paintColor())
		a.anchor = p
	case toolLine, toolRect:
		a.cur = p
	}
	return true
}

func (a *app) mouseUp(x, y int) bool {
	a.down = false
	t := a.txn
	a.txn = nil
	if t == nil {
		return true
	}
	p := pt{x - docOrgX, y - docOrgY}
	switch a.tool {
	case toolLine:
		t.segment(a.anchor, p, brushSizes[a.size]/2, palette[a.color])
	case toolRect:
		t.rectOutline(rectFrom(a.anchor, p), max(1, brushSizes[a.size]/4), palette[a.color])
	case toolBrush, toolErase:
		// Segments stamped through the drag; the release point closes the run.
		t.segment(a.anchor, p, brushSizes[a.size]/2, a.paintColor())
	}
	a.d.commit(t)
	conLine(markerCommit + toolName(a.tool) + " n=" + strconv.Itoa(t.touches()) +
		" sum=" + fnv16(a.d.sum()) + " probe=" + probeText(a.d))
	return true
}

func (a *app) paintColor() uint32 {
	if a.tool == toolErase {
		return palette[paperIdx]
	}
	return palette[a.color]
}

// --- picker + dialog ---------------------------------------------------------

func (a *app) openPick(kind appkit.PickerKind) {
	dir := "/host"
	if i := strings.LastIndexByte(a.d.path, '/'); i > 0 {
		dir = a.d.path[:i]
	}
	a.pick = appkit.NewFilePicker(kind, dir)
	if kind == appkit.PickSave {
		a.pick.Input = basename(a.d.path)
	}
	a.pickExport = false
	a.mode = modePicker
}

// startOpen guards an open behind the discard-confirm on a dirty canvas —
// the picker is the only open path and it is the one that can destroy bytes.
func (a *app) startOpen() {
	if a.d.dirty {
		a.dlg = appkit.NewConfirm("Unsaved canvas", "Open a file and discard the unsaved canvas?")
		a.dialogAsk = "open"
		a.mode = modeDialog
		return
	}
	a.openPick(appkit.PickOpen)
	conLine(markerPick + "open")
}

func (a *app) pickerKey(ev vi.Event) bool {
	_, done := a.pick.HandleKey(ev)
	if !done {
		return true
	}
	save := a.pick.Kind == appkit.PickSave
	res := a.pick.Result
	a.mode = modePaint
	if res == "cancel" {
		conLine(markerPick + "cancel")
		return true
	}
	if a.pickExport {
		a.pickExport = false
		conLine(markerPick + "export " + res)
		a.exportPNG(res)
		return true
	}
	if save {
		conLine(markerPick + "save " + res)
		a.save(res)
		return true
	}
	conLine(markerPick + "open " + res)
	a.load(res)
	return true
}

// dialogKey routes the confirm's answer. Yes runs the stashed ask (drop
// replace, or continue into the open picker); anything else is a refusal
// with its own receipt.
func (a *app) dialogKey(ev vi.Event) bool {
	_, done := a.dlg.HandleKey(ev)
	if !done {
		return true
	}
	a.mode = modePaint
	if a.dlg.Result != "Yes" {
		if a.dialogAsk == "drop" {
			a.dropPixels = nil
			conLine(markerDropNo)
		}
		return true
	}
	if a.dialogAsk == "drop" {
		a.applyDrop()
	} else {
		a.openPick(appkit.PickOpen)
		conLine(markerPick + "open")
	}
	return true
}

// --- painting ----------------------------------------------------------------

// probeText is the fixed-point canvas probe the undo leg asserts: the pixel
// at the document's quarter point — a coordinate every leg can reason about.
func probeText(d *doc) string {
	return px8(d.probe(d.w/4, d.h/4))
}

// Layout constants for the toolbar column. Hit tests read the same rects
// the paint path does (the widgets rule).
var toolRects = [toolCount]widgets.Rect{
	{X: 10, Y: 28, W: 36, H: 22},  // brush
	{X: 10, Y: 54, W: 36, H: 22},  // line
	{X: 10, Y: 80, W: 36, H: 22},  // rect
	{X: 10, Y: 106, W: 36, H: 22}, // fill
	{X: 10, Y: 132, W: 36, H: 22}, // erase
}

var toolGlyphs = [toolCount]string{"B", "L", "R", "F", "E"}

var sizeRects = [2]widgets.Rect{
	{X: 10, Y: 160, W: 36, H: 14},
	{X: 10, Y: 178, W: 36, H: 14},
}

const (
	paletteOrgX = 8
	paletteOrgY = 200
	paletteCell = 11
	paletteStep = 13
	paletteCols = 4
)

func toolHit(x, y int) (toolID, bool) {
	for i, r := range toolRects {
		if r.Contains(x, y) {
			return toolID(i), true
		}
	}
	return 0, false
}

func sizeHit(x, y int) (int, bool) {
	for i, r := range sizeRects {
		if r.Contains(x, y) {
			return i, true
		}
	}
	return 0, false
}

func paletteHit(x, y int) (int, bool) {
	cx := (x - paletteOrgX) / paletteStep
	cy := (y - paletteOrgY) / paletteStep
	if x < paletteOrgX || y < paletteOrgY || cx >= paletteCols || cy >= len(palette)/paletteCols {
		return 0, false
	}
	if (x-paletteOrgX)%paletteStep >= paletteCell || (y-paletteOrgY)%paletteStep >= paletteCell {
		return 0, false
	}
	return cy*paletteCols + cx, true
}

func (a *app) draw() {
	cv := a.ta.Canvas()
	tok := theme.Current
	W, H := int(a.ta.W), int(a.ta.H)
	cv.FillRect(widgets.Rect{W: W, H: H}, draw.Opaque(tok.Bg))

	// Title band: app + file + dirty mark, then the toolbar column.
	cv.FillRect(widgets.Rect{W: W, H: bandH}, draw.Opaque(tok.Surface))
	cv.FillRect(widgets.Rect{Y: bandH, W: W, H: 1}, draw.Opaque(tok.Border))
	title := "GOPAINT"
	if a.d.path != "" {
		title = basename(a.d.path)
	}
	if a.d.dirty {
		title += " *"
	}
	widgets.DrawText(cv, widgets.Rect{X: 4, Y: 4, W: W - 8, H: 16}, title, draw.Opaque(tok.Text))

	cv.FillRect(widgets.Rect{X: toolW - 1, Y: bandH + 1, W: 1, H: H - bandH - statusH}, draw.Opaque(tok.Border))
	for i := range toolRects {
		r := toolRects[i]
		face := tok.BtnIdle
		if toolID(i) == a.tool {
			face = tok.Accent
		}
		cv.FillRect(r, draw.Opaque(face))
		cv.StrokeRoundedRect(r, 2, tok.BorderW, draw.Opaque(tok.Border))
		widgets.DrawText(cv, r.Inset(4), toolGlyphs[i], draw.Opaque(tok.Text))
	}
	for i, r := range sizeRects {
		face := tok.BtnIdle
		if i == a.size {
			face = tok.Accent
		}
		cv.FillRect(r, draw.Opaque(face))
		cv.StrokeRoundedRect(r, 2, tok.BorderW, draw.Opaque(tok.Border))
		// The glyph IS the size: a centered square of the brush's span.
		s := brushSizes[i]
		cv.FillRect(widgets.Rect{X: r.X + (r.W-s)/2, Y: r.Y + (r.H-s)/2, W: s, H: s}, draw.Opaque(tok.Text))
	}
	for i, c := range palette {
		r := widgets.Rect{
			X: paletteOrgX + (i%paletteCols)*paletteStep,
			Y: paletteOrgY + (i/paletteCols)*paletteStep,
			W: paletteCell, H: paletteCell,
		}
		cv.FillRect(r, c)
		if i == a.color {
			cv.StrokeRoundedRect(r.Inset(-1), 1, tok.BorderW, draw.Opaque(tok.Accent))
		}
	}

	a.drawDoc(cv)

	// Status bar: the current tool/size/color and the dirty flag.
	barY := H - statusH
	cv.FillRect(widgets.Rect{Y: barY, W: W, H: statusH}, draw.Opaque(tok.Surface))
	status := toolName(a.tool) + "  size=" + strconv.Itoa(brushSizes[a.size]) +
		"  color=" + strconv.Itoa(a.color)
	if a.d.dirty {
		status += "  unsaved"
	}
	widgets.DrawText(cv, widgets.Rect{X: 4, Y: barY + 2, W: W - 8, H: statusH - 2}, status, draw.Opaque(tok.Muted))

	// Modals ride on top, both appkit-owned plates.
	if a.mode == modePicker {
		a.pick.Draw(cv)
	} else if a.mode == modeDialog {
		a.dlg.Draw(cv)
	}
}

// drawDoc blits the document 1:1 at the viewport origin over a checkerboard
// (alpha shows through), clipped to the window, with the live line/rect
// rubber-band painted over it — the preview touches only the display
// surface, which is why the undo ring sees committed ops alone.
func (a *app) drawDoc(cv widgets.Canvas) {
	vp := widgets.Rect{X: docOrgX, Y: docOrgY, W: int(a.ta.W) - docOrgX - 8, H: int(a.ta.H) - docOrgY - statusH - 4}
	if vp.W <= 0 || vp.H <= 0 {
		return
	}
	w := min(a.d.w, vp.W)
	h := min(a.d.h, vp.H)
	// Checkerboard behind the document's extent (visible through alpha and
	// around an undersized doc).
	const cell = 8
	for y := vp.Y; y < min(vp.Bottom(), docOrgY+h); y += cell {
		for x := vp.X; x < min(vp.Right(), docOrgX+w); x += cell {
			rgb := uint32(0x2a2a2a)
			if (x/cell+y/cell)%2 != 0 {
				rgb = 0x3a3a3a
			}
			cv.FillRect(widgets.Rect{X: x, Y: y, W: min(cell, vp.Right()-x), H: min(cell, vp.Bottom()-y)}, draw.Opaque(rgb))
		}
	}
	if bc, ok := cv.(*draw.BufferCanvas); ok {
		bc.PushClip(vp)
		for y := 0; y < h; y++ {
			dst := bc.Pix[(docOrgY+y)*bc.W+docOrgX : (docOrgY+y)*bc.W+docOrgX+w]
			copy(dst, a.d.pix[y*a.d.w:y*a.d.w+w])
		}
		// Rubber-band preview for the committed-on-release tools.
		if a.down && (a.tool == toolLine || a.tool == toolRect) {
			col := palette[a.color]
			put := func(x, y int) {
				if x >= 0 && y >= 0 && x < a.d.w && y < a.d.h {
					bc.Pix[(docOrgY+y)*bc.W+docOrgX+x] = col
				}
			}
			if a.tool == toolLine {
				segPts(a.anchor, a.cur, put)
			} else {
				r := rectFrom(a.anchor, a.cur)
				for x := r.x; x < r.x+r.w; x++ {
					put(x, r.y)
					put(x, r.y+r.h-1)
				}
				for y := r.y; y < r.y+r.h; y++ {
					put(r.x, y)
					put(r.x+r.w-1, y)
				}
			}
		}
		bc.PopClip()
	} else {
		// FillerCanvas degrade: opaque spans per row.
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				if px := a.d.pix[y*a.d.w+x]; px>>24 != 0 {
					cv.FillRect(widgets.Rect{X: docOrgX + x, Y: docOrgY + y, W: 1, H: 1}, px)
				}
			}
		}
	}
	cv.StrokeRoundedRect(widgets.Rect{X: docOrgX - 1, Y: docOrgY - 1, W: w + 2, H: h + 2}, 0, 1, draw.Opaque(theme.Current.Border))
}

// segPts walks the pixel-accurate segment a→b (the same stepping
// txn.segment stamps), calling f per point — the line tool's preview path.
func segPts(a, b pt, f func(x, y int)) {
	dx, dy := b.x-a.x, b.y-a.y
	n := abs(dx)
	if abs(dy) > n {
		n = abs(dy)
	}
	if n == 0 {
		f(a.x, a.y)
		return
	}
	for k := 0; k <= n; k++ {
		f(a.x+dx*k/n, a.y+dy*k/n)
	}
}

func basename(path string) string {
	if i := strings.LastIndexByte(path, '/'); i >= 0 {
		return path[i+1:]
	}
	return path
}

func clampi(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
