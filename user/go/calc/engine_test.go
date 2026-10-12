package main

import "testing"

// feed types a decimal-mode expression into e one char at a time.
func feed(t *testing.T, e *Engine, keys string) {
	t.Helper()
	for i := 0; i < len(keys); i++ {
		ch := keys[i]
		var ok bool
		switch {
		case ch >= '0' && ch <= '9':
			ok = e.InputDigit(ch - '0')
		case ch == '.':
			ok = e.InputPoint()
		case ch == '%':
			ok = e.Percent()
		case ch == '~':
			ok = e.Negate()
		case ch == '=':
			e.Evaluate()
			ok = true
		default:
			ok = e.SetOp(ch)
		}
		if !ok {
			t.Fatalf("key %q of %q refused", string(ch), keys)
		}
	}
}

func disp(t *testing.T, e *Engine, want string) {
	t.Helper()
	if got := e.Display(); got != want {
		t.Fatalf("display = %q want %q", got, want)
	}
}

func TestIntegerArithmetic(t *testing.T) {
	var e Engine
	feed(t, &e, "12+34=")
	disp(t, &e, "46")
	feed(t, &e, "*2=")
	disp(t, &e, "92")
	feed(t, &e, "-100=")
	disp(t, &e, "-8")
	feed(t, &e, "/2=")
	disp(t, &e, "-4")
}

func TestGateExpression(t *testing.T) {
	var e Engine
	feed(t, &e, "12-3=")
	disp(t, &e, "9")
}

func TestDecimalDivide(t *testing.T) {
	var e Engine
	feed(t, &e, "1.5/4=")
	disp(t, &e, "0.375")

	e.Clear()
	feed(t, &e, "1/3=")
	disp(t, &e, "0.33333333") // guard digit 3 < 5: truncates at scale 8

	e.Clear()
	feed(t, &e, "2/3=")
	disp(t, &e, "0.66666667") // guard digit 6 ≥ 5: rounds half-up

	e.Clear()
	feed(t, &e, "0.1+0.2=")
	disp(t, &e, "0.3") // exact decimal, not 0.30000000000000004

	e.Clear()
	feed(t, &e, "8/3=")
	disp(t, &e, "2.66666667")
}

func TestDecimalPointEntry(t *testing.T) {
	var e Engine
	feed(t, &e, ".5")
	disp(t, &e, "0.5")

	e.Clear()
	feed(t, &e, "1.50")
	disp(t, &e, "1.50") // live entry keeps the typed trailing zero
	feed(t, &e, "+0=")
	disp(t, &e, "1.5") // results normalize

	e.Clear()
	feed(t, &e, "12.")
	disp(t, &e, "12.") // a dangling point is live until a digit or '='

	var f Engine
	f.InputPoint()
	f.InputPoint()
	disp(t, &f, "0.") // a second point is refused

	// The fraction bound is 8 digits; the 9th is refused, value kept.
	var g Engine
	feed(t, &g, "0.12345678")
	if g.InputDigit(9) {
		t.Fatal("9th fraction digit must be refused")
	}
	disp(t, &g, "0.12345678")
}

func TestPercent(t *testing.T) {
	var e Engine
	feed(t, &e, "25%")
	disp(t, &e, "0.25")

	e.Clear()
	feed(t, &e, "200*10%=")
	disp(t, &e, "20") // entry semantics: 10% = 0.1, then 200*0.1

	e.Clear()
	feed(t, &e, "5+25%=")
	disp(t, &e, "5.25")

	e.Clear()
	feed(t, &e, "50%+25%=")
	disp(t, &e, "0.75")
}

func TestNegate(t *testing.T) {
	var e Engine
	feed(t, &e, "5~")
	disp(t, &e, "-5")
	feed(t, &e, "6") // digits keep growing the negated entry
	disp(t, &e, "-56")

	e.Clear()
	feed(t, &e, "5+3~=")
	disp(t, &e, "2")

	e.Clear()
	feed(t, &e, "0.5~")
	disp(t, &e, "-0.5")

	// ± on minI64 → ERROR: -(-9223372036854775808) does not fit.
	e.Clear()
	e.cur = num{m: minI64}
	if !e.Negate() || !e.hasErr || e.Display() != "ERROR" {
		t.Fatalf("negate minI64 → %q err=%v want ERROR", e.Display(), e.hasErr)
	}
}

func TestDivideByZero(t *testing.T) {
	var e Engine
	feed(t, &e, "5/0=")
	if !e.hasErr || e.Display() != "ERROR" {
		t.Fatalf("5/0 → err=%v display=%q", e.hasErr, e.Display())
	}
	feed(t, &e, "0.5/0=")
	if !e.hasErr {
		t.Fatal("0.5/0 must stay ERROR")
	}
}

func TestBackspaceAndClear(t *testing.T) {
	var e Engine
	feed(t, &e, "123")
	e.Backspace()
	disp(t, &e, "12")
	e.Clear()
	if e.cur.m != 0 || e.entering || e.hasErr || e.pending != 0 {
		t.Fatal("clear must reset the calculation")
	}

	// Backspace unwinds fraction digit, then the point, then integers.
	var f Engine
	feed(t, &f, "1.25")
	f.Backspace()
	disp(t, &f, "1.2")
	f.Backspace()
	disp(t, &f, "1.") // the point drops before the integer part
	f.Backspace()
	disp(t, &f, "1")
	f.Backspace()
	disp(t, &f, "0")
	if f.entering {
		t.Fatal("entry should end when the last digit drops")
	}
}

func TestOverflowShowsError(t *testing.T) {
	var e Engine
	e.accum = num{m: maxI64}
	e.cur = num{m: 1}
	e.entering = true
	e.pending = '+'
	e.Evaluate()
	if !e.hasErr {
		t.Fatal("max+1 must ERROR")
	}

	e.Clear()
	e.accum = num{m: minI64}
	e.cur = num{m: 1}
	e.entering = true
	e.pending = '-'
	e.Evaluate()
	if !e.hasErr {
		t.Fatal("min-1 must ERROR")
	}

	e.Clear()
	e.accum = num{m: 4_000_000_000}
	e.cur = num{m: 4_000_000_000}
	e.entering = true
	e.pending = '*'
	e.Evaluate()
	if !e.hasErr {
		t.Fatal("4e9*4e9 must ERROR")
	}

	e.Clear()
	e.accum = num{m: minI64}
	e.cur = num{m: -1}
	e.entering = true
	e.pending = '/'
	e.Evaluate()
	if !e.hasErr {
		t.Fatal("min/-1 must ERROR")
	}

	// An add that overflows only through scale alignment must ERROR too:
	// maxI64 + 0.5 needs a mantissa of maxI64*10^8.
	e.Clear()
	e.accum = num{m: maxI64}
	e.cur = num{m: 5, s: 1}
	e.entering = true
	e.pending = '+'
	e.Evaluate()
	if !e.hasErr {
		t.Fatal("maxI64 + 0.5 must ERROR")
	}

	e.Clear()
	e.cur = num{m: maxI64}
	e.entering = true
	if e.InputDigit(9) {
		t.Fatal("the overflowing digit must be refused")
	}
	if e.cur.m != maxI64 || e.hasErr {
		t.Fatalf("refusing an overflowing digit must keep %d, not wrap", maxI64)
	}
}

func TestRepeatLastOp(t *testing.T) {
	var e Engine
	feed(t, &e, "5+3=")
	disp(t, &e, "8")
	e.Evaluate()
	disp(t, &e, "11")
	e.Evaluate()
	disp(t, &e, "14")
}

func TestDigitAfterEquals(t *testing.T) {
	var e Engine
	feed(t, &e, "5+3=")
	e.InputDigit(2)
	disp(t, &e, "2")
	e.Evaluate()
	disp(t, &e, "5") // repeats +3 on the new entry
}

// Arming an op over a fresh entry must NOT replay lastOp: after 1.5/4=,
// 2+3.5= is 5.5 — the '+' binds the new operand 2, it does not first
// evaluate the repeat 2/4. The live gate (run 02) caught this.
func TestOpAfterEqualsDoesNotRepeat(t *testing.T) {
	var e Engine
	feed(t, &e, "1.5/4=")
	disp(t, &e, "0.375")
	feed(t, &e, "2+3.5=")
	disp(t, &e, "5.5")
}

func TestLeftToRightChain(t *testing.T) {
	var e Engine
	feed(t, &e, "2*3+4=")
	disp(t, &e, "10")
}

func TestFormatMinInt(t *testing.T) {
	if got := formatI64(minI64); got != "-9223372036854775808" {
		t.Fatalf("minInt display = %q", got)
	}
	if got := formatI64(0); got != "0" {
		t.Fatalf("zero display = %q", got)
	}
}

// --- programmer mode ---------------------------------------------------

func progFeed(t *testing.T, e *Engine, keys string) {
	t.Helper()
	for i := 0; i < len(keys); i++ {
		ch := keys[i]
		var ok bool
		switch {
		case ch >= '0' && ch <= '9':
			ok = e.InputDigit(ch - '0')
		case ch >= 'a' && ch <= 'f':
			ok = e.InputHexDigit(ch - 'a' + 10)
		case ch >= 'A' && ch <= 'F':
			ok = e.InputHexDigit(ch - 'A' + 10)
		case ch == '~':
			ok = e.Not()
		case ch == '=':
			e.Evaluate()
			ok = true
		default:
			ok = e.SetOp(byte(ch))
		}
		if !ok {
			t.Fatalf("key %q of %q refused", string(ch), keys)
		}
	}
}

func TestProgHexEntryAndDisplay(t *testing.T) {
	var e Engine
	e.SetProg(true)
	if e.dispBase() != 16 {
		t.Fatalf("programmer default base = %d want 16", e.dispBase())
	}
	progFeed(t, &e, "ff+1=")
	disp(t, &e, "100") // 0xFF + 1 = 0x100 shown in hex

	e.SetBase(10)
	disp(t, &e, "256")
	e.SetBase(8)
	disp(t, &e, "400")
	e.SetBase(2)
	disp(t, &e, "100000000")
	e.SetBase(16)
	disp(t, &e, "100")

	e.Clear() // mode survives C
	if !e.prog {
		t.Fatal("C must not leave programmer mode")
	}
	disp(t, &e, "0")
}

func TestProgBitwiseAndShifts(t *testing.T) {
	var e Engine
	e.SetProg(true)
	progFeed(t, &e, "fe&0f=")
	disp(t, &e, "E") // FE & 0F = 0E

	e.Clear()
	progFeed(t, &e, "f0|f=")
	disp(t, &e, "FF")

	e.Clear()
	progFeed(t, &e, "ff^ff=")
	disp(t, &e, "0")

	e.Clear()
	progFeed(t, &e, "0~")
	disp(t, &e, "FFFFFFFFFFFFFFFF") // ~0 = -1, two's complement hex

	e.Clear()
	progFeed(t, &e, "1<4=")
	disp(t, &e, "10") // 1 << 4 = 0x10

	e.Clear()
	progFeed(t, &e, "80>4=")
	disp(t, &e, "8") // 0x80 >> 4 = 8

	e.Clear()
	e.SetBase(10)
	progFeed(t, &e, "8/3=")
	disp(t, &e, "2") // programmer division truncates

	e.Clear()
	e.SetBase(10)
	progFeed(t, &e, "5-9=")
	disp(t, &e, "-4")
	e.SetBase(16)
	disp(t, &e, "FFFFFFFFFFFFFFFC") // two's complement display
}

func TestProgBaseFiltering(t *testing.T) {
	var e Engine
	e.SetProg(true)
	e.SetBase(8)
	if e.InputDigit(9) || e.InputHexDigit(15) {
		t.Fatal("digits ≥ base must be refused in octal")
	}
	e.SetBase(10)
	if e.InputHexDigit(10) {
		t.Fatal("hex digit must be refused in decimal base")
	}
	e.SetBase(2)
	if e.InputDigit(2) {
		t.Fatal("2 must be refused in binary")
	}
	progFeed(t, &e, "101+1=")
	disp(t, &e, "110")
}

func TestProgOpRefusedInDecimal(t *testing.T) {
	var e Engine
	if e.SetOp('&') || e.SetOp('<') || e.Not() {
		t.Fatal("bitwise ops must refuse outside programmer mode")
	}
	if !e.Percent() {
		t.Fatal("sanity: percent exists in decimal mode")
	}
	e.SetProg(true)
	if e.InputPoint() || e.Percent() {
		t.Fatal("'.' and '%' must refuse in programmer mode")
	}
}

func TestProgShiftEdges(t *testing.T) {
	var e Engine
	e.SetProg(true)
	e.SetBase(10)
	progFeed(t, &e, "1<63=")
	disp(t, &e, "-9223372036854775808") // 1<<63 = minI64, representable

	e.Clear()
	progFeed(t, &e, "1<64=")
	disp(t, &e, "0") // Go semantics: count ≥ 64 shifts out entirely

	e.Clear()
	progFeed(t, &e, "0-1>64=")
	disp(t, &e, "-1") // arithmetic >>: sign-fill

	e.SetBase(16)
	e.Clear()
	e.accum = num{m: 8}
	e.cur = num{m: -1}
	e.entering = true
	e.pending = '<'
	e.Evaluate()
	if !e.hasErr {
		t.Fatal("negative shift count must ERROR")
	}
}

func TestModeToggleCarriesInteger(t *testing.T) {
	var e Engine
	feed(t, &e, "7.9+0=")
	e.SetProg(true)
	e.SetBase(10)
	disp(t, &e, "7") // truncates toward zero
	e.SetProg(false)
	feed(t, &e, "+0.1=")
	disp(t, &e, "7.1")
}
