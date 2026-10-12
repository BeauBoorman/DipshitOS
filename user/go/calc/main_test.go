package main

import (
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
