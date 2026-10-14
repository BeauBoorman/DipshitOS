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
// a–f + '&' '|' '^' '~' '<' '>' in programmer mode, Enter = equals,
// Escape = clear, Backspace edits the entry — there is no second input
// path. Above the entry, the history line keeps the last evaluated
// expression (expr→result) until a new one starts.
//
// Every marker below is printed only AFTER its syscall returned, so the
// go-calc VZ gate's asserts can only pass if the app actually ran.
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

	defaultPath = "/host/CALC/RESULT.TXT"

	keyEnter  = 0x28
	keyEscape = 0x29
	keyBacksp = 0x2a

	decRows  = 5
	decCols  = 4
	progRows = 6
	progCols = 6
	maxCells = progRows * progCols
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

	ta := tabapp.Init(tabapp.Config{Name: appName, Title: appTitle, X: 32, Y: 32, W: natW, H: natH})
	if ta == nil {
		vi.ConsoleLine(markerOpenErr + "-1")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
		// M69a (#1528): printed only on the accepted-declare path -- the
		// calculator is HOSTED by a WM seat, not merely running.
		vi.ConsoleLine(markerDogfood)
	} else {
		vi.ConsoleLine("gocalc: declare refused")
	}

	a := &app{ta: ta, path: path}
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
	loop.Run()
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
	a.layout()
	cv := a.ta.Canvas()
	cv.FillRect(widgets.Rect{W: int(a.ta.W), H: int(a.ta.H)}, draw.Opaque(tabapp.FillRGB()))
	a.hist.Draw(cv)
	a.disp.Draw(cv)
	for i := range a.keys {
		a.keys[i].Draw(cv)
	}
}

func scaleR(ta *tabapp.TabApp, r widgets.Rect) widgets.Rect {
	s := ta.Layout(tabapp.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}, natW, natH)
	return widgets.Rect{X: s.X, Y: s.Y, W: s.W, H: s.H}
}
