// Command calc is the Go calculator (Zig CALC.BIN successor): a
// fixed-point decimal + programmer-mode calc full-viewport inside Zig
// TABWM via user/go/tabapp. Zig CALC.BIN is gone (M62h / #1406); the
// M62h integer-only first pass grew its second pass under #2201 — the
// engine pins its representation in engine.go's first note.
//
// Pad: decimal mode is a 5×4 grid (digits, + - * /, ., %, ±, C, P);
// programmer mode is a 6×6 grid (bases HEX/DEC/OCT/BIN + STD, hex digits,
// AND/OR/XOR/NOT/<</>>, the four ops). The keyboard drives the SAME
// engine calls as the pad — digits, '.', '%', 'n' (±), 'p' (mode),
// a–f + '&' '|' '^' '~' '<' '>' in programmer mode, 't' copies the tape,
// Enter = equals, Escape = clear, Backspace edits the entry — there is
// no second input path. Above the entry, the history strip keeps the
// live line plus the previous tape row once one exists.
//
// M192c (#3248): the calc remembers. Each '=' appends its rendered line
// to a bounded tape (tapeMax entries, newest last); 't' publishes the
// tape on the M124c typed clipboard as text/plain (the kernel buffer is
// CAP_CLIPBOARD/seat-only, so a seat-launched calc records the refusal —
// the same posture GOFILES' clip-sys keeps); and an appver-1 envelope
// rides the seat's save/restore carrying mode + the tape.
//
// Every marker below is printed only AFTER its syscall returned, so the
// go-calc VZ gate's asserts can only pass if the app actually ran.
package main

import (
	"strings"

	"virelai/appkit"
	"virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/vsys"
	"virelai/webrender/font"
	"virelai/widgets"
)

const (
	appName  = "GOCALC.ELF"
	appTitle = "Calc"
	natW     = 512
	natH     = 384

	markerOpen              = "gocalc: open id="
	markerDeclare           = "gocalc: declare accepted"
	markerDogfood           = "dogfood: calc" // M69a (#1528): go-dogfood.spec's marker
	markerPresent           = "gocalc: present"
	markerSettingSubscribed = "gocalc: settings subscribed key=theme"
	markerSettingPresent    = "gocalc: settings repaint key="
	markerResult            = "gocalc: result "
	markerSaveErr           = "gocalc: save error "
	markerClose             = "gocalc: close"
	markerOK                = "gocalc OK"
	markerOpenErr           = "gocalc: error open "
	markerState             = "gocalc: state "
	markerTape              = "gocalc: tape "

	defaultPath = "/host/CALC/RESULT.TXT"

	keyEnter  = 0x28
	keyEscape = 0x29
	keyBacksp = 0x2a

	decRows  = 5
	decCols  = 4
	progRows = 6
	progCols = 6
	maxCells = progRows * progCols

	// stateFmtVer is the blob's own serialization tag (byte 0); stateAppVer
	// is the envelope version the seat stores and hands back verbatim — a
	// blob under a foreign appver is refused by name, never misread.
	stateFmtVer = 1
	stateAppVer = 1

	// tapeMax is the tape bound the card names: the newest tapeMax
	// rendered lines survive, the oldest drop off. tapeLineMax bounds one
	// entry — both bounds are also the blob's decode caps, so a blob
	// declaring more is foreign.
	tapeMax     = 16
	tapeLineMax = 64

	// histRowA/histRowB are the two bitmap-row tops inside the 20px
	// history plate when a second line rides it (single-line keeps the
	// widget's centred geometry — the golden's fixed point).
	histRowA = 2
	histRowB = 11
)

var decPad = [decRows][decCols]string{
	{"C", "±", "%", "/"},
	{"7", "8", "9", "*"},
	{"4", "5", "6", "-"},
	{"1", "2", "3", "+"},
	{"P", "0", ".", "="},
}

var progPad = [progRows][progCols]string{
	{"HEX", "DEC", "OCT", "BIN", "STD", "CLR"},
	{"A", "B", "C", "D", "E", "F"},
	{"AND", "OR", "XOR", "NOT", "<<", ">>"},
	{"7", "8", "9", "/", "*", "-"},
	{"4", "5", "6", "+", "±", "="},
	{"1", "2", "3", "0", "", ""},
}

// padAt returns the active pad's label at flat index i (row-major).
func padAt(prog bool, i int) string {
	if prog {
		return progPad[i/progCols][i%progCols]
	}
	return decPad[i/decCols][i%decCols]
}

func padDims(prog bool) (rows, cols int) {
	if prog {
		return progRows, progCols
	}
	return decRows, decCols
}

type app struct {
	ta         *tabapp.TabApp
	eng        Engine
	path       string
	expr       string
	lastLine   string
	justEvaled bool
	tape       []string
	pend       []byte
	disp       widgets.Text
	hist       widgets.Text
	keys       [maxCells]widgets.Button
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
	path := defaultPath
	if args := vi.Args(); len(args) > 1 && len(args[1]) > 0 {
		path = args[1]
	}

	// a exists before Init so the state hooks bind to it; the restore
	// lands inside Init (RequestStateRestore), so it parks in a.pend
	// until applyRestored runs after a.ta is set.
	a := &app{path: path}
	ta := tabapp.Init(tabapp.Config{
		Name: appName, Title: appTitle, X: 32, Y: 32, W: natW, H: natH,
		SaveState: a.saveState, RestoreState: a.noteState, StateVersion: stateAppVer,
	})
	if ta == nil {
		vi.ConsoleLine(markerOpenErr + "-1")
		vi.Exit(1)
	}
	a.ta = ta
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
		// M69a (#1528): printed only on the accepted-declare path -- the
		// calculator is HOSTED by a WM seat, not merely running.
		vi.ConsoleLine(markerDogfood)
	} else {
		vi.ConsoleLine("gocalc: declare refused")
	}
	a.applyRestored()

	loop := appkit.NewLoop(a.ta, a.draw, a.handle)
	if loop.SubscribeSetting("theme", func(value string) bool {
		return theme.Set(value)
	}) {
		vi.ConsoleLine(markerSettingSubscribed)
	}
	loop.OnSettingPresent = func(key, value string) {
		vi.ConsoleLine(markerSettingPresent + key + " value=" + value)
	}
	loop.OnInitialPresent = func() { vi.ConsoleLine(markerPresent) }
	loop.OnExit = func(status int) {
		vi.ConsoleLine(markerClose)
		vi.ConsoleLine(markerOK)
		a.ta.CloseAndExit(status)
	}
	// The seat's save ask is mailbox traffic, not an input event: answer
	// it once per pass before polling, the same discipline the other
	// hooked apps keep.
	loop.RunWith(func() (vi.Event, int64, bool) {
		a.ta.PollStateAsk()
		return vi.PollEventRaw()
	}, vi.Sleep)
}

func (a *app) handle(ev vi.Event) bool {
	switch ev.Kind {
	case vi.EvKeyDown:
		return a.key(ev)
	case vi.EvMouseMove, vi.EvMouseUp, vi.EvMouseDown:
		return a.pointer(ev)
	}
	return false
}

func (a *app) pointer(ev vi.Event) bool {
	x, y := int(ev.Arg0), int(ev.Arg1)
	down := ev.Kind == vi.EvMouseDown && ev.Flags&vi.BtnLeft != 0
	changed := false
	hit := -1
	rows, cols := padDims(a.eng.prog)
	for i := 0; i < rows*cols; i++ {
		h := a.keys[i].HitTest(x, y)
		if a.keys[i].Hovered != h {
			a.keys[i].Hovered = h
			changed = true
		}
		p := down && h
		if a.keys[i].Pressed != p {
			a.keys[i].Pressed = p
			changed = true
		}
		if h {
			hit = i
		}
	}
	if down && hit >= 0 {
		return a.press(padAt(a.eng.prog, hit)) || changed
	}
	return changed
}

func (a *app) key(ev vi.Event) bool {
	if ev.Kind != vi.EvKeyDown {
		return false
	}
	if ev.Flags&vi.ModCtrl != 0 {
		return false
	}
	switch ev.Arg0 {
	case keyEnter:
		return a.doEval()
	case keyEscape:
		return a.doClear()
	case keyBacksp:
		return a.doBackspace()
	}
	ch := ev.Arg1
	if ch >= '0' && ch <= '9' {
		return a.doDigit(uint8(ch-'0'), byte(ch))
	}
	if a.eng.prog {
		switch {
		case ch >= 'a' && ch <= 'f':
			return a.doDigit(uint8(ch-'a')+10, 'A'+byte(ch-'a'))
		case ch >= 'A' && ch <= 'F':
			return a.doDigit(uint8(ch-'A')+10, byte(ch))
		}
		switch ch {
		case '&', '|', '^', '<', '>':
			return a.doOp(byte(ch))
		case '~':
			return a.doNot()
		}
	}
	switch ch {
	case '+', '-', '*', '/':
		return a.doOp(byte(ch))
	case '.':
		return a.doPoint()
	case '%':
		return a.doPercent()
	case 'n', 'N':
		return a.doNegate()
	case 'p', 'P':
		return a.doMode(!a.eng.prog)
	case 't', 'T':
		return a.doCopyTape()
	case '=', '\r', '\n':
		return a.doEval()
	case 'c', 'C':
		return a.doClear()
	case 0x08:
		return a.doBackspace()
	}
	return false
}

func (a *app) press(label string) bool {
	switch label {
	case "":
		return false
	case "C":
		// 'C' is clear on the decimal pad, hex digit C on the prog pad.
		if a.eng.prog {
			return a.doDigit(12, 'C')
		}
		return a.doClear()
	case "CLR":
		return a.doClear()
	case "=":
		return a.doEval()
	case "±":
		return a.doNegate()
	case "%":
		return a.doPercent()
	case ".":
		return a.doPoint()
	case "P":
		return a.doMode(true)
	case "STD":
		return a.doMode(false)
	case "HEX":
		return a.doBase(16)
	case "DEC":
		return a.doBase(10)
	case "OCT":
		return a.doBase(8)
	case "BIN":
		return a.doBase(2)
	case "NOT":
		return a.doNot()
	case "AND":
		return a.doOp('&')
	case "OR":
		return a.doOp('|')
	case "XOR":
		return a.doOp('^')
	case "<<":
		return a.doOp('<')
	case ">>":
		return a.doOp('>')
	}
	if len(label) != 1 {
		return false
	}
	ch := label[0]
	if ch >= '0' && ch <= '9' {
		return a.doDigit(ch-'0', ch)
	}
	if ch >= 'A' && ch <= 'F' {
		return a.doDigit(ch-'A'+10, ch)
	}
	switch ch {
	case '+', '-', '*', '/':
		return a.doOp(ch)
	}
	return false
}

func (a *app) doDigit(d uint8, echo byte) bool {
	if a.justEvaled {
		a.expr = ""
		a.justEvaled = false
	}
	if a.eng.prog {
		if !a.eng.InputHexDigit(d) {
			return false
		}
	} else if !a.eng.InputDigit(d) {
		return false
	}
	a.expr += string(echo)
	return true
}

func (a *app) doPoint() bool {
	if a.justEvaled {
		a.expr = ""
		a.justEvaled = false
	}
	if !a.eng.InputPoint() {
		return false
	}
	if a.expr == "" || isOpChar(a.expr[len(a.expr)-1]) {
		a.expr += "0"
	}
	a.expr += "."
	return true
}

func (a *app) doPercent() bool {
	if !a.eng.Percent() {
		return false
	}
	a.expr += "%"
	return true
}

func (a *app) doNegate() bool {
	if !a.eng.Negate() {
		return false
	}
	a.rewriteToken()
	return true
}

func (a *app) doNot() bool {
	if !a.eng.Not() {
		return false
	}
	a.rewriteToken()
	return true
}

// rewriteToken replaces expr's trailing number with the live display, so
// a unary transform (±, NOT) shows the operand it produced.
func (a *app) rewriteToken() {
	for len(a.expr) > 0 && isTokenChar(a.expr[len(a.expr)-1]) {
		a.expr = a.expr[:len(a.expr)-1]
	}
	a.expr += a.eng.Display()
}

func (a *app) doOp(op byte) bool {
	if !a.eng.SetOp(op) {
		return false
	}
	a.justEvaled = false
	if a.eng.hasErr {
		a.expr = ""
		return true
	}
	a.expr += opEcho(op)
	return true
}

func (a *app) doEval() bool {
	a.eng.Evaluate()
	disp := a.eng.Display()
	a.lastLine = a.expr + "=" + disp
	a.tapePush(a.tapeRender(a.lastLine))
	a.justEvaled = true
	if !a.writeResult(a.lastLine) {
		vi.ConsoleLine(markerSaveErr + a.path)
	}
	vi.ConsoleLine(markerResult + a.lastLine)
	return true
}

func (a *app) doClear() bool {
	a.eng.Clear()
	a.expr = ""
	a.justEvaled = false
	return true
}

func (a *app) doMode(prog bool) bool {
	if !a.eng.SetProg(prog) {
		return false
	}
	a.expr = ""
	return true
}

func (a *app) doBase(b uint8) bool {
	if !a.eng.SetBase(b) {
		return false
	}
	a.expr = ""
	return true
}

func (a *app) doBackspace() bool {
	if !a.eng.Backspace() {
		return false
	}
	if len(a.expr) > 0 && isTokenChar(a.expr[len(a.expr)-1]) {
		a.expr = a.expr[:len(a.expr)-1]
		// A '-' exposed by the trim can only be a negated token's sign:
		// a binary '-' is set by doOp, which ends the entry and makes
		// the engine refuse this very backspace.
		if len(a.expr) > 0 && a.expr[len(a.expr)-1] == '-' {
			a.expr = a.expr[:len(a.expr)-1]
		}
	}
	return true
}

func isTokenChar(c byte) bool {
	return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || c == '.'
}

func isOpChar(c byte) bool {
	switch c {
	case '+', '-', '*', '/', '&', '|', '^', '<', '>', '%':
		return true
	}
	return false
}

func opEcho(op byte) string {
	switch op {
	case '<':
		return "<<"
	case '>':
		return ">>"
	}
	return string(op)
}

// writeResult publishes the result line crash-safe (M81e #1765): one
// temp+fsync+delete-then-rename publish, so the result file is either the
// old line or the new one — never the tail of a torn write.
func (a *app) writeResult(line string) bool {
	return vi.WriteFileSafe(a.path, []byte(line+"\n")) >= 0
}

// histText is the line above the entry: the last evaluated expression
// (expr=result) once '=' lands, the expression being typed while it
// grows, and the programmer base tag whenever prog is on.
func (a *app) histText() string {
	t := a.expr
	if a.justEvaled || t == "" {
		t = a.lastLine
	}
	if a.eng.prog {
		if t != "" {
			return baseName(a.eng.dispBase()) + " " + t
		}
		return baseName(a.eng.dispBase())
	}
	return t
}

// tapeRender is a line as the tape stores it: a programmer-mode entry
// carries its base tag so a tape that crosses a mode toggle still reads
// in the base it was evaluated under (histText re-derives the live
// line's tag from the CURRENT mode — the tape's are frozen).
func (a *app) tapeRender(line string) string {
	if a.eng.prog && line != "" {
		return baseName(a.eng.dispBase()) + " " + line
	}
	return line
}

// tapePush appends one rendered line (newest last), dropping the oldest
// over tapeMax — the bound the envelope serializes.
func (a *app) tapePush(line string) {
	if len(line) > tapeLineMax {
		line = line[:tapeLineMax]
	}
	a.tape = append(a.tape, line)
	if len(a.tape) > tapeMax {
		copy(a.tape, a.tape[1:])
		a.tape = a.tape[:tapeMax]
	}
}

// histLines lays out the history strip: bottom is the live line (the
// expression being typed, or the last evaluation), top is the tape entry
// just below it. The second row exists only once the tape holds an older
// entry, so a fresh calc paints the exact single-line strip it always
// has — the golden and the run-05 pixel leg keep their fixed point.
func (a *app) histLines() (top, bottom string) {
	bottom = a.histText()
	n := len(a.tape)
	switch {
	case a.expr != "" && !a.justEvaled:
		// typing over a tape: the newest entry is the row above
		if n > 0 {
			top = a.tape[n-1]
		}
	case a.lastLine != "" && n > 1:
		top = a.tape[n-2]
	case a.lastLine == "" && n > 0:
		top = a.tape[n-1]
	}
	return top, bottom
}

func baseName(base uint8) string {
	switch base {
	case 16:
		return "HEX"
	case 8:
		return "OCT"
	case 2:
		return "BIN"
	}
	return "DEC"
}

// --- the appver-1 state envelope (M192c) -------------------------------------
//
// Wire (little-endian, browser/state.go's appendU16 discipline):
//
//	u8  fmtVer (=stateFmtVer) | u8 flags (0)
//	u8  mode  — 0 decimal, 1 programmer
//	u8  base  — the programmer display base (2/8/10/16), 0 in decimal mode
//	u8  nTape — then nTape entries of u16 len | len entry bytes
//
// The app owns the format; the seat stores the bytes verbatim. Decode is
// total: every length is checked against what remains, counts are capped
// by the write-side bounds, entry bytes must be printable ASCII (the tape
// is rendered text), and a foreign fmtVer, an overrun or trailing garbage
// refuses the WHOLE blob — never half-applied, never a panic.

// calcState is a decoded envelope.
type calcState struct {
	prog bool
	base uint8
	tape []string
}

// saveState is Config.SaveState: the envelope the seat's ask collects.
// The bound is structural — tapeMax x tapeLineMax can never approach the
// 64 KiB envelope ceiling, so there is no oversize path to refuse.
func (a *app) saveState() []byte {
	prog, base := a.eng.Mode()
	var mode byte
	if prog {
		mode = 1
	}
	out := make([]byte, 0, 8+len(a.tape)*16)
	out = append(out, stateFmtVer, 0, mode, base, byte(len(a.tape)))
	for _, line := range a.tape {
		out = append(out, byte(len(line)), byte(len(line)>>8))
		out = append(out, line...)
	}
	vi.ConsoleLine(markerState + "saved n=" + vi.Itoa64(int64(len(out))))
	return out
}

// decodeState is saveState's strict inverse — nil means refuse whole.
func decodeState(b []byte) (*calcState, bool) {
	if len(b) < 5 || b[0] != stateFmtVer || b[1] != 0 {
		return nil, false
	}
	st := &calcState{}
	switch b[2] {
	case 0:
		if b[3] != 0 {
			return nil, false
		}
	case 1:
		switch b[3] {
		case 2, 8, 10, 16:
			st.prog, st.base = true, b[3]
		default:
			return nil, false
		}
	default:
		return nil, false
	}
	n := int(b[4])
	if n > tapeMax {
		return nil, false
	}
	o := 5
	for i := 0; i < n; i++ {
		if len(b)-o < 2 {
			return nil, false
		}
		ln := int(b[o]) | int(b[o+1])<<8
		o += 2
		if ln == 0 || ln > tapeLineMax || len(b)-o < ln {
			return nil, false
		}
		line := string(b[o : o+ln])
		o += ln
		for j := 0; j < len(line); j++ {
			if line[j] < 0x20 || line[j] > 0x7e {
				return nil, false
			}
		}
		st.tape = append(st.tape, line)
	}
	if o != len(b) {
		return nil, false // trailing garbage: not this codec's product
	}
	return st, true
}

// noteState is Config.RestoreState: the blob parks raw until applyRestored
// can read the appver off a.ta (the hook runs inside tabapp.Init, before
// a.ta exists — gosheet's pend discipline).
func (a *app) noteState(blob []byte) {
	a.pend = blob
}

// applyRestored seats a parked blob: the appver is refused by name before
// decode, the decode is total, and a good blob re-arms mode + tape and
// reports what came back. lastLine re-derives the newest entry's raw
// line, so the strip shows the tape's tail exactly as the live session
// left it (a programmer entry re-earns its tag through histText).
func (a *app) applyRestored() {
	if a.pend == nil {
		return
	}
	blob := a.pend
	a.pend = nil
	if a.ta.RestoredVersion != stateAppVer {
		vi.ConsoleLine(markerState + "refused ver=" + vi.Itoa64(int64(a.ta.RestoredVersion)))
		return
	}
	st, ok := decodeState(blob)
	if !ok {
		vi.ConsoleLine(markerState + "refused bad")
		return
	}
	a.eng.RestoreMode(st.prog, st.base)
	a.tape = st.tape
	last := "-"
	if n := len(st.tape); n > 0 {
		last = st.tape[n-1]
		a.lastLine = stripTag(last)
	}
	vi.ConsoleLine(markerState + "restored mode=" + modeName(st.prog) +
		" tape=" + vi.Itoa64(int64(len(st.tape))) + " last=" + last)
}

func modeName(prog bool) string {
	if prog {
		return "prog"
	}
	return "dec"
}

// stripTag peels a tape entry's frozen base tag back off — lastLine
// keeps the raw expr=result and histText re-adds the live mode's tag.
func stripTag(line string) string {
	if len(line) > 4 && line[3] == ' ' {
		switch line[:3] {
		case "HEX", "OCT", "BIN", "DEC":
			return line[4:]
		}
	}
	return line
}

// --- the copy verb ------------------------------------------------------------

// doCopyTape publishes the tape on the M124c typed clipboard declaring
// text/plain — the tape IS plain text. The kernel buffer admits
// CAP_CLIPBOARD and the registered seat only (M97g), so a seat-launched
// calc gets the refusal's raw rc named on the marker instead of claiming
// a copy that never landed — the same posture GOFILES' clip-sys keeps.
func (a *app) doCopyTape() bool {
	text := a.tapeText()
	if text == nil {
		vi.ConsoleLine(markerTape + "copy empty")
		return true
	}
	n, rc := vsys.ClipboardSetTyped(vsys.ClipText, text)
	if rc < 0 {
		vi.ConsoleLine(markerTape + "copy refused rc=" + vi.Itoa64(rc))
		return true
	}
	vi.ConsoleLine(markerTape + "copy n=" + vi.Itoa64(int64(n)))
	return true
}

// tapeText joins the tape for the clipboard — one rendered line per row,
// newest entries winning the kernel's 512 bound: the oldest drop until
// the text fits rather than truncating a line mid-glyph. nil on an
// empty tape.
func (a *app) tapeText() []byte {
	if len(a.tape) == 0 {
		return nil
	}
	start := 0
	for {
		n := -1 // the separators are one fewer than the lines
		for _, l := range a.tape[start:] {
			n += len(l) + 1
		}
		if n <= vsys.ClipKernelMax {
			break
		}
		start++
	}
	var b strings.Builder
	for i := start; i < len(a.tape); i++ {
		if i > start {
			b.WriteByte('\n')
		}
		b.WriteString(a.tape[i])
	}
	return []byte(b.String())
}

// --- painting -----------------------------------------------------------------

// drawHist paints the history plate. With no older tape entry the plate
// is exactly the single Text line the golden pins; a second row rides
// the same plate once the tape holds one — bitmap rows at histRowA and
// histRowB, the two offsets the one-line widget cannot express.
func (a *app) drawHist(cv widgets.Canvas) {
	top, bottom := a.histLines()
	if top == "" {
		a.hist.Draw(cv)
		return
	}
	r := a.hist.R
	tok := theme.Current
	cv.FillRoundedRect(r, 4 /* widgets' radiusControl */, draw.Opaque(tok.Surface))
	tapeRow(cv, r, top, r.Y+histRowA, tok.InkMuted)
	tapeRow(cv, r, bottom, r.Y+histRowB, tok.InkMuted)
}

// tapeRow paints one 8x8 bitmap line at a caller-chosen top inside the
// plate's inset inner — drawGlyphRun's exact run-fill geometry, split
// out so the strip can seat a second row (the widget draws one,
// centred).
func tapeRow(c widgets.Canvas, plate widgets.Rect, s string, y int, rgb uint32) {
	inner := plate.Inset(2)
	if inner.Empty() {
		return
	}
	cw := font.Advance(1)
	i := 0
	for _, ch := range s {
		x := inner.X + i*cw
		if x >= inner.Right() {
			break
		}
		g := font.Glyph8(ch)
		for row := 0; row < 8; row++ {
			py := y + row
			if py < inner.Y || py >= inner.Bottom() {
				continue
			}
			bits := g[row]
			col := 0
			for col < 8 {
				if bits&(1<<uint(col)) == 0 {
					col++
					continue
				}
				run := 1
				for col+run < 8 && bits&(1<<uint(col+run)) != 0 {
					run++
				}
				px, w := x+col, run
				if px < inner.X {
					w -= inner.X - px
					px = inner.X
				}
				if px+w > inner.Right() {
					w = inner.Right() - px
				}
				if w > 0 {
					c.FillRect(widgets.Rect{X: px, Y: py, W: w, H: 1}, rgb)
				}
				col += run
			}
		}
		i++
	}
}

func (a *app) layout() {
	ta := a.ta
	tok := theme.Current
	a.hist = widgets.Text{
		R:     scaleR(ta, widgets.Rect{X: tok.PadMD, Y: tok.PadMD, W: int(natW) - 2*tok.PadMD, H: 20}),
		Label: a.histText(),
		Fg:    tok.InkMuted,
		Bg:    tok.Surface,
	}
	a.disp = widgets.Text{
		R:     scaleR(ta, widgets.Rect{X: tok.PadMD, Y: 32, W: int(natW) - 2*tok.PadMD, H: 44}),
		Label: a.eng.Display(),
		Fg:    tok.Ink,
		Bg:    tok.Surface,
	}
	prog := a.eng.prog
	rows, cols := padDims(prog)
	gap := tok.PadMD
	y0 := 84
	availW := int(natW) - 2*tok.PadMD
	availH := int(natH) - y0 - tok.PadMD
	btnW := (availW - (cols-1)*gap) / cols
	btnH := (availH - (rows-1)*gap) / rows
	for i := range a.keys {
		if i >= rows*cols || padAt(prog, i) == "" {
			a.keys[i] = widgets.Button{}
			continue
		}
		r, c := i/cols, i%cols
		a.keys[i] = widgets.Button{
			R:       scaleR(ta, widgets.Rect{X: tok.PadMD + c*(btnW+gap), Y: y0 + r*(btnH+gap), W: btnW, H: btnH}),
			Label:   padAt(prog, i),
			Hovered: a.keys[i].Hovered,
			Pressed: a.keys[i].Pressed,
		}
	}
}

func (a *app) draw() {
	a.paintCanvas(a.ta.Canvas())
}

// paintCanvas renders the laid-out widgets onto cv — split from draw so the
// host-side composite golden (M104h #2275) can pin the full-canvas surface
// without a bound window surface: on the host Canvas() is the FillerCanvas
// degrade, which is not the chrome this app paints in the guest.
func (a *app) paintCanvas(cv widgets.Canvas) {
	if cv == nil {
		return
	}
	a.layout()
	cv.FillRect(widgets.Rect{W: int(a.ta.W), H: int(a.ta.H)}, draw.Opaque(tabapp.FillRGB()))
	a.drawHist(cv)
	a.disp.Draw(cv)
	for i := range a.keys {
		a.keys[i].Draw(cv)
	}
}

func scaleR(ta *tabapp.TabApp, r widgets.Rect) widgets.Rect {
	s := ta.Layout(tabapp.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}, natW, natH)
	return widgets.Rect{X: s.X, Y: s.Y, W: s.W, H: s.H}
}
