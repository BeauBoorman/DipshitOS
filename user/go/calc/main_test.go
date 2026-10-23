package main

import (
	"strings"
	"testing"

	"virelai/vi"
)

func TestCalcMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{markerOpen, "gocalc: open id="},
		{markerDeclare, "gocalc: declare accepted"},
		{markerPresent, "gocalc: present"},
		{markerSettingSubscribed, "gocalc: settings subscribed key=theme"},
		{markerSettingPresent, "gocalc: settings repaint key="},
		{markerResult, "gocalc: result "},
		{markerSaveErr, "gocalc: save error "},
		{markerClose, "gocalc: close"},
		{markerOK, "gocalc OK"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

func downASCII(ch uint32) vi.Event {
	return vi.Event{Kind: vi.EvKeyDown, Arg1: ch}
}

func downHID(usage uint32, ascii uint32) vi.Event {
	return vi.Event{Kind: vi.EvKeyDown, Arg0: usage, Arg1: ascii}
}

func feedKeys(t *testing.T, a *app, keys string) {
	t.Helper()
	for i := 0; i < len(keys); i++ {
		if !a.key(downASCII(uint32(keys[i]))) {
			t.Fatalf("key %q of %q refused", keys[i:i+1], keys)
		}
	}
}

func feedPad(t *testing.T, a *app, labels ...string) {
	t.Helper()
	for _, l := range labels {
		if !a.press(l) {
			t.Fatalf("pad press %q refused", l)
		}
	}
}

func TestKeyPathGateExpression(t *testing.T) {
	a := &app{}
	seq := []vi.Event{
		downASCII('1'),
		downASCII('2'),
		downASCII('-'),
		downASCII('3'),
		downASCII('='),
	}
	for _, ev := range seq {
		if !a.key(ev) {
			t.Fatalf("key %+v must be handled", ev)
		}
	}
	if a.eng.Display() != "9" {
		t.Fatalf("display = %q want 9", a.eng.Display())
	}
	if a.lastLine != "12-3=9" {
		t.Fatalf("lastLine = %q want 12-3=9", a.lastLine)
	}
	if a.histText() != "12-3=9" {
		t.Fatalf("hist = %q want the evaluated expression 12-3=9", a.histText())
	}
}

func TestKeyPathAllFourOps(t *testing.T) {
	a := &app{}
	feedKeys(t, a, "6*7=")
	if a.eng.Display() != "42" {
		t.Fatalf("6*7 = %q want 42", a.eng.Display())
	}
	a.doClear()
	feedKeys(t, a, "8/2=")
	if a.eng.Display() != "4" {
		t.Fatalf("8/2 = %q want 4", a.eng.Display())
	}
	a.doClear()
	feedKeys(t, a, "12+34=")
	if a.eng.Display() != "46" {
		t.Fatalf("12+34 = %q want 46", a.eng.Display())
	}
}

func TestKeyPathDecimal(t *testing.T) {
	a := &app{}
	feedKeys(t, a, "1.5/4=")
	if a.eng.Display() != "0.375" {
		t.Fatalf("1.5/4 = %q want 0.375", a.eng.Display())
	}
	if a.lastLine != "1.5/4=0.375" {
		t.Fatalf("lastLine = %q want 1.5/4=0.375", a.lastLine)
	}
}

// The keyboard and the pad are required to drive the SAME engine calls:
// run the identical expression through both paths and pin identical
// display + history.
func TestKeyboardEqualsPad(t *testing.T) {
	byKey := &app{}
	feedKeys(t, byKey, "8/2=")
	byPad := &app{}
	feedPad(t, byPad, "8", "/", "2", "=")
	if byKey.eng.Display() != byPad.eng.Display() ||
		byKey.lastLine != byPad.lastLine {
		t.Fatalf("key %q/%q vs pad %q/%q",
			byKey.eng.Display(), byKey.lastLine,
			byPad.eng.Display(), byPad.lastLine)
	}

	byKey = &app{}
	feedKeys(t, byKey, "2.5*2n=") // '*' op, 'n' negate key on the operand
	byPad = &app{}
	feedPad(t, byPad, "2", ".", "5", "*", "2", "±", "=")
	if byKey.eng.Display() != "-5" || byPad.eng.Display() != "-5" ||
		byKey.eng.Display() != byPad.eng.Display() {
		t.Fatalf("2.5*-2: key=%q pad=%q want -5",
			byKey.eng.Display(), byPad.eng.Display())
	}
}

func TestEnterAndEscapeHID(t *testing.T) {
	a := &app{}
	a.key(downASCII('9'))
	a.key(downASCII('+'))
	a.key(downASCII('1'))
	if !a.key(downHID(keyEnter, '\n')) {
		t.Fatal("Enter HID usage must evaluate")
	}
	if a.eng.Display() != "10" {
		t.Fatalf("9+1 via Enter = %q want 10", a.eng.Display())
	}
	if !a.key(downHID(keyEscape, 0)) {
		t.Fatal("Escape HID usage must clear")
	}
	if a.eng.Display() != "0" || a.expr != "" {
		t.Fatal("Escape must clear")
	}
}

func TestClearKeyAndPad(t *testing.T) {
	a := &app{}
	a.key(downASCII('7'))
	a.key(downASCII('c'))
	if a.eng.Display() != "0" || a.expr != "" {
		t.Fatal("c must clear")
	}
	if !a.press("8") || !a.press("+") || !a.press("2") || !a.press("=") {
		t.Fatal("pad presses must be handled")
	}
	if a.eng.Display() != "10" {
		t.Fatalf("pad 8+2 = %q want 10", a.eng.Display())
	}
	if !a.press("C") {
		t.Fatal("pad C must clear")
	}
	if a.eng.Display() != "0" {
		t.Fatal("pad C must reset the display")
	}
	// C clears the entry, not the history: the last evaluated expression
	// stays visible above the entry until the next '=' replaces it.
	if a.histText() != "8+2=10" {
		t.Fatalf("hist after C = %q want 8+2=10", a.histText())
	}
}

func TestProgrammerKeyPath(t *testing.T) {
	a := &app{}
	feedKeys(t, a, "p") // mode toggle: 'p' is the pad 'P' key's keyboard twin
	if !a.eng.prog {
		t.Fatal("'p' must enter programmer mode")
	}
	feedKeys(t, a, "ff-1=")
	if a.eng.Display() != "FE" {
		t.Fatalf("FF-1 = %q want FE", a.eng.Display())
	}
	if a.lastLine != "FF-1=FE" {
		t.Fatalf("lastLine = %q want FF-1=FE", a.lastLine)
	}
	if a.histText() != "HEX FF-1=FE" {
		t.Fatalf("hist = %q want HEX-tagged history", a.histText())
	}

	// Bitwise via pad labels — the same engine calls as the '&' key.
	feedPad(t, a, "AND", "0", "F", "=")
	if a.eng.Display() != "E" || a.lastLine != "FF-1&0F=E" {
		t.Fatalf("FE&0F → disp=%q last=%q want E / FF-1&0F=E",
			a.eng.Display(), a.lastLine)
	}

	// '&' from the keyboard takes the same path as the AND button.
	a2 := &app{}
	feedKeys(t, a2, "p")
	feedKeys(t, a2, "fe&0f=")
	if a2.eng.Display() != "E" {
		t.Fatalf("keyboard FE&0F = %q want E", a2.eng.Display())
	}

	// 'c' is hex digit C in programmer mode — NOT clear.
	a.key(downASCII('c'))
	if !a.eng.entering {
		t.Fatal("'c' in prog mode must be hex digit C, not clear")
	}
}

func TestProgrammerBaseKeys(t *testing.T) {
	a := &app{}
	feedPad(t, a, "P", "F", "F")
	if a.eng.Display() != "FF" {
		t.Fatalf("FF entry = %q", a.eng.Display())
	}
	feedPad(t, a, "DEC")
	if a.eng.Display() != "255" {
		t.Fatalf("DEC display = %q want 255", a.eng.Display())
	}
	feedPad(t, a, "OCT")
	if a.eng.Display() != "377" {
		t.Fatalf("OCT display = %q want 377", a.eng.Display())
	}
	feedPad(t, a, "BIN")
	if a.eng.Display() != "11111111" {
		t.Fatalf("BIN display = %q want 11111111", a.eng.Display())
	}
	feedPad(t, a, "STD")
	if a.eng.prog || a.eng.Display() != "255" {
		t.Fatalf("STD must return to decimal, got prog=%v disp=%q",
			a.eng.prog, a.eng.Display())
	}
}

func TestCtrlIsIgnored(t *testing.T) {
	a := &app{}
	ev := vi.Event{Kind: vi.EvKeyDown, Flags: vi.ModCtrl, Arg1: '1'}
	if a.key(ev) {
		t.Fatal("ctrl chords must not type digits")
	}
}

// --- M192c (#3248): the bounded tape, the copy verb, the appver-1 envelope ---

func TestTapeBound(t *testing.T) {
	a := &app{}
	for i := 0; i < tapeMax+4; i++ {
		a.tapePush("line")
	}
	if len(a.tape) != tapeMax {
		t.Fatalf("tape len = %d want bound %d", len(a.tape), tapeMax)
	}
	// The oldest entries dropped: after 20 pushes of distinct lines the
	// tape keeps only the newest tapeMax.
	a.tape = nil
	for i := 0; i < tapeMax+2; i++ {
		a.tapePush(vi.Itoa64(int64(i)))
	}
	if a.tape[0] != "2" || a.tape[len(a.tape)-1] != "17" {
		t.Fatalf("tape kept %v..%v want 2..17", a.tape[0], a.tape[len(a.tape)-1])
	}
}

func TestTapeIsWrittenPerEval(t *testing.T) {
	a := &app{}
	feedKeys(t, a, "12-3=")
	if len(a.tape) != 1 || a.tape[0] != "12-3=9" {
		t.Fatalf("tape = %v want [12-3=9]", a.tape)
	}
	// A programmer entry stores its frozen base tag.
	feedKeys(t, a, "pff-1=")
	want := "HEX FF-1=FE"
	if a.tape[len(a.tape)-1] != want {
		t.Fatalf("prog tape entry = %q want %q", a.tape[len(a.tape)-1], want)
	}
}

func TestHistLines(t *testing.T) {
	a := &app{}
	// Fresh: one line, the golden's fixed point.
	if top, _ := a.histLines(); top != "" {
		t.Fatalf("empty tape top = %q want \"\"", top)
	}
	feedKeys(t, a, "12-3=")
	// One entry: still one line — the strip shows the live line only.
	if top, bottom := a.histLines(); top != "" || bottom != "12-3=9" {
		t.Fatalf("one-entry histLines = (%q,%q)", top, bottom)
	}
	feedKeys(t, a, "2+2=")
	// Two entries: the previous row rides above the newest.
	if top, bottom := a.histLines(); top != "12-3=9" || bottom != "2+2=4" {
		t.Fatalf("two-entry histLines = (%q,%q)", top, bottom)
	}
	// Typing a fresh expression: the newest entry stays on top.
	feedKeys(t, a, "5")
	if top, bottom := a.histLines(); top != "2+2=4" || bottom != "5" {
		t.Fatalf("typing histLines = (%q,%q)", top, bottom)
	}
}

func TestStateCodecRoundTrip(t *testing.T) {
	a := &app{}
	feedKeys(t, a, "12-3=")
	feedKeys(t, a, "pff-1=")
	b := a.saveState()
	st, ok := decodeState(b)
	if !ok {
		t.Fatalf("own blob refused: %x", b)
	}
	if !st.prog || st.base != 16 {
		t.Fatalf("mode = (prog=%v base=%d) want (true,16)", st.prog, st.base)
	}
	want := []string{"12-3=9", "HEX FF-1=FE"}
	if len(st.tape) != len(want) {
		t.Fatalf("tape = %v want %v", st.tape, want)
	}
	for i := range want {
		if st.tape[i] != want[i] {
			t.Fatalf("tape[%d] = %q want %q", i, st.tape[i], want[i])
		}
	}
	// The restore seats the same mode + tape — the envelope does not
	// carry the live value, so the display is a fresh '0' in the
	// restored base and the tape's tail is what the strip shows.
	b2 := &app{}
	b2.eng.RestoreMode(st.prog, st.base)
	b2.tape = st.tape
	b2.lastLine = stripTag(st.tape[len(st.tape)-1])
	if d := b2.eng.Display(); d != "0" {
		t.Fatalf("restored display = %q want fresh 0", d)
	}
	if !b2.eng.prog || b2.eng.dispBase() != 16 {
		t.Fatalf("restored mode = (prog=%v base=%d) want (true,16)",
			b2.eng.prog, b2.eng.dispBase())
	}
	if top, bt := b2.histLines(); top != "12-3=9" || bt != "HEX FF-1=FE" {
		t.Fatalf("restored histLines = (%q,%q) want (12-3=9,HEX FF-1=FE)", top, bt)
	}
}

func TestStateCodecRefuses(t *testing.T) {
	a := &app{}
	feedKeys(t, a, "12-3=")
	good := a.saveState()
	if _, ok := decodeState(good); !ok {
		t.Fatal("own blob refused")
	}
	cases := map[string][]byte{
		"empty":         {},
		"short":         good[:4],
		"bad fmtVer":    append([]byte{9}, good[1:]...),
		"bad flags":     append([]byte{good[0], 7}, good[2:]...),
		"bad mode":      append(good[:2:2], 9, 0, 1),
		"dec+base":      append(good[:3:3], 8, 1),
		"bad base":      append(good[:2:2], 1, 9, 0),
		"tape over max": append(good[:4:4], byte(tapeMax+1)),
		"trailing":      append(append([]byte{}, good...), 0),
	}
	for name, b := range cases {
		if _, ok := decodeState(b); ok {
			t.Fatalf("decode accepted %s: %x", name, b)
		}
	}
	// A truncated entry length refuses whole, not half-applied.
	trunc := good[:len(good)-1]
	if _, ok := decodeState(trunc); ok {
		t.Fatal("truncated blob accepted")
	}
	// A non-printable entry byte refuses whole.
	bad := append([]byte{}, good...)
	bad[len(bad)-1] = 0x01
	if _, ok := decodeState(bad); ok {
		t.Fatal("blob with control byte accepted")
	}
}

func TestTapeTextBound(t *testing.T) {
	a := &app{}
	if a.tapeText() != nil {
		t.Fatal("empty tape publishes nil, not an empty body")
	}
	line := strings.Repeat("9*9=81 x ", 8)[:tapeLineMax]
	for i := 0; i < tapeMax; i++ {
		a.tape = append(a.tape, vi.Itoa64(int64(i))+":"+line[:tapeLineMax-3])
	}
	text := a.tapeText()
	if len(text) > 512 {
		t.Fatalf("tapeText = %d bytes, over the kernel's 512", len(text))
	}
	// The newest entries survive: the tail is the last pushed line.
	last := a.tape[len(a.tape)-1]
	if !strings.HasSuffix(string(text), last) {
		t.Fatalf("tapeText tail = %q want suffix %q",
			string(text[len(text)-len(last):]), last)
	}
}

func TestCopyVerbKeyPath(t *testing.T) {
	a := &app{}
	// 't' drives the copy verb in both modes — on the host the typed
	// publish is refused (-ENOSYS) and the marker names it, never a
	// silent no-op.
	a.key(downASCII('t'))
	feedKeys(t, a, "1+1=")
	if !a.key(downASCII('t')) {
		t.Fatal("'t' with a tape must be handled")
	}
}
