// Calculator engine: decimal fixed-point + programmer-integer modes (#2201).
//
// REPRESENTATION (pinned): a decimal value is bounded fixed-point —
// num{m, s} = m × 10^-s, mantissa int64, scale 0..maxScale(8). NOT float64
// (a calculator's display math must be exact), NOT rationals (denominators
// grow unbounded under repeated division), NOT a bignum (the card's stop
// condition: bounded fixed-point only). |m| < 2^63 with s ≤ 8 gives a
// ±9.2e10 range with up to 8 fraction digits.
//
// Pinned semantics (class-A tests prove each):
//   - Chaining is left-to-right (2*3+4 = 10); bare '=' repeats the last
//     op, but arming an op folds only a PENDING op — typing an operator
//     over a fresh entry never replays lastOp (the run-02 gate: 1.5/4=
//     then 2+3.5= must be 5.5, not 2/4+3.5).
//   - add/sub align scales on int64 mantissas; overflow → ERROR.
//   - mul/div compute in 128-bit, then round half-away-from-zero on the
//     guard digit at scale 8 (2/3 = 0.66666667) and strip trailing zeros
//     (0.375 stays 0.375, never 0.37500000).
//   - '%' divides the current value by 100 exactly: 50% → 0.5, so
//     200*10% = 20 and 5+25% = 5.25 (entry semantics, not a+b% context).
//   - Divide by zero, int64 overflow anywhere, and ± on minI64 → ERROR;
//     error is sticky until Clear.
//   - Digit entry refuses what cannot be represented (the mantissa keeps
//     its value): a 20th digit or a 9th fraction digit is a no-op.
//
// Programmer mode (e.prog) is a separate checked-int64 domain: the same
// chaining engine, the four ops plus & | ^ ~ << >>. Division is truncating
// int64 (8/3 = 2). Shift counts < 0 → ERROR; ≥ 64 follow Go int64
// semantics (<< → 0, >> → sign-fill). Non-decimal bases display the
// 64-bit two's-complement pattern (-1 hex = FFFFFFFFFFFFFFFF), read digits
// only below the base, and a base switch ends the live entry. Toggling
// modes carries the truncated integer of the display and drops the
// pending op.
package main

import "math/bits"

const (
	maxI64 = int64(^uint64(0) >> 1)
	minI64 = -maxI64 - 1

	// maxScale is the fixed-point fraction bound in decimal digits.
	maxScale = 8
)

var pow10 = [2*maxScale + 1]uint64{
	1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000,
	1000000000, 10000000000, 100000000000, 1000000000000,
	10000000000000, 100000000000000, 1000000000000000, 10000000000000000,
}

// num is one fixed-point decimal value: m × 10^-s.
type num struct {
	m int64
	s uint8
}

// Engine is the calculator core. The zero value is a decimal-mode engine;
// programmer state (prog/base) survives Clear, which resets only the
// calculation.
type Engine struct {
	accum    num
	cur      num
	pending  byte // 0; '+','-','*','/'; prog adds '&','|','^','<','>'
	lastOp   byte
	lastArg  num
	entering bool
	hasErr   bool
	point    bool // a '.' was typed for the live entry (decimal mode)
	prog     bool // programmer mode
	base     uint8
}

func add64(a, b int64) (int64, bool) {
	c := a + b
	if (b > 0 && c < a) || (b < 0 && c > a) {
		return 0, false
	}
	return c, true
}

func sub64(a, b int64) (int64, bool) {
	c := a - b
	if (b > 0 && c > a) || (b < 0 && c < a) {
		return 0, false
	}
	return c, true
}

func mul64(a, b int64) (int64, bool) {
	if a == 0 || b == 0 {
		return 0, true
	}
	c := a * b
	if c/a != b {
		return 0, false
	}
	return c, true
}

func mag(v int64) uint64 {
	if v < 0 {
		return uint64(^v) + 1
	}
	return uint64(v)
}

// norm is the canonical form: no trailing fraction zeros.
func norm(n num) num {
	for n.s > 0 && n.m%10 == 0 {
		n.m /= 10
		n.s--
	}
	return n
}

func scaleTo(m int64, d uint8) (int64, bool) {
	if d == 0 {
		return m, true
	}
	return mul64(m, int64(pow10[d]))
}

func addN(a, b num) (num, bool) {
	s := a.s
	if b.s > s {
		s = b.s
	}
	am, ok := scaleTo(a.m, s-a.s)
	if !ok {
		return num{}, false
	}
	bm, ok := scaleTo(b.m, s-b.s)
	if !ok {
		return num{}, false
	}
	c, ok := add64(am, bm)
	if !ok {
		return num{}, false
	}
	return norm(num{c, s}), true
}

func subN(a, b num) (num, bool) {
	s := a.s
	if b.s > s {
		s = b.s
	}
	am, ok := scaleTo(a.m, s-a.s)
	if !ok {
		return num{}, false
	}
	bm, ok := scaleTo(b.m, s-b.s)
	if !ok {
		return num{}, false
	}
	c, ok := sub64(am, bm)
	if !ok {
		return num{}, false
	}
	return norm(num{c, s}), true
}

// divmod10 divides the 128-bit value hi:lo by 10.
func divmod10(hi, lo uint64) (qHi, qLo, rem uint64) {
	qHi = hi / 10
	qLo, rem = bits.Div64(hi%10, lo, 10)
	return qHi, qLo, rem
}

// signedFromMag bounds-checks a magnitude against int64 and applies neg.
func signedFromMag(u uint64, neg bool) (int64, bool) {
	if u > uint64(maxI64) && !(neg && u == uint64(maxI64)+1) {
		return 0, false
	}
	m := int64(u)
	if neg {
		m = -m
	}
	return m, true
}

func mulN(a, b num) (num, bool) {
	neg := (a.m < 0) != (b.m < 0)
	hi, lo := bits.Mul64(mag(a.m), mag(b.m))
	s := a.s + b.s // <= 2*maxScale
	for s > maxScale {
		var r uint64
		hi, lo, r = divmod10(hi, lo)
		if s == maxScale+1 && r >= 5 {
			var c uint64
			lo, c = bits.Add64(lo, 1, 0)
			hi += c
		}
		s--
	}
	if hi != 0 {
		return num{}, false
	}
	m, ok := signedFromMag(lo, neg)
	if !ok {
		return num{}, false
	}
	return norm(num{m, s}), true
}

func divN(a, b num) (num, bool) {
	if b.m == 0 {
		return num{}, false
	}
	neg := (a.m < 0) != (b.m < 0)
	exp := int(b.s) - int(a.s) + maxScale // 0..2*maxScale
	hi, lo := bits.Mul64(mag(a.m), pow10[exp])
	ub := mag(b.m)
	if hi >= ub {
		return num{}, false // quotient cannot fit a uint64
	}
	quo, rem := bits.Div64(hi, lo, ub)
	if rem*2 >= ub { // round half-up on magnitudes = half-away-from-zero
		quo++
	}
	m, ok := signedFromMag(quo, neg)
	if !ok {
		return num{}, false
	}
	return norm(num{m, maxScale}), true
}

func (e *Engine) fail() {
	prog, base := e.prog, e.base
	*e = Engine{prog: prog, base: base, hasErr: true}
}

// dispBase is the programmer-mode display base (default hex).
func (e *Engine) dispBase() uint8 {
	switch e.base {
	case 2, 8, 10, 16:
		return e.base
	}
	return 16
}

func (e *Engine) entryBase() int64 {
	if e.prog {
		return int64(e.dispBase())
	}
	return 10
}

// InputDigit appends a 0–9 digit onto the number being entered (in
// programmer mode the digit must be below the base). Refused digits —
// overflow, a 9th fraction digit, a digit ≥ base — leave the entry
// untouched and report false so the caller does not echo them.
func (e *Engine) InputDigit(d uint8) bool {
	if d > 9 {
		return false
	}
	return e.inputDigit(d)
}

// InputHexDigit appends a 0–15 digit (programmer mode only; the base
// filter still applies).
func (e *Engine) InputHexDigit(d uint8) bool {
	if !e.prog || d > 15 {
		return false
	}
	return e.inputDigit(d)
}

func (e *Engine) inputDigit(d uint8) bool {
	if d >= uint8(e.entryBase()) {
		return false
	}
	e.hasErr = false
	if !e.entering {
		e.cur = num{m: int64(d)}
		e.entering = true
		e.point = false
		return true
	}
	if e.point && e.cur.s >= maxScale {
		return false
	}
	grown, ok := mul64(e.cur.m, e.entryBase())
	if !ok {
		return false
	}
	var next int64
	if e.cur.m >= 0 {
		next, ok = add64(grown, int64(d))
	} else {
		next, ok = sub64(grown, int64(d))
	}
	if !ok {
		return false
	}
	e.cur.m = next
	if e.point {
		e.cur.s++
	}
	return true
}

// InputPoint starts the fraction of the live entry (decimal mode only).
func (e *Engine) InputPoint() bool {
	if e.prog || e.point {
		return false
	}
	e.hasErr = false
	if !e.entering {
		e.cur = num{}
		e.entering = true
	}
	e.point = true
	return true
}

// Backspace drops the last entered digit — a fraction digit, the point
// itself, or an integer digit in the entry base.
func (e *Engine) Backspace() bool {
	if !e.entering || e.hasErr {
		return false
	}
	if e.point {
		if e.cur.s == 0 {
			e.point = false
			return true
		}
		e.cur.m /= 10
		e.cur.s--
		return true
	}
	e.cur.m /= e.entryBase()
	if e.cur.m == 0 {
		e.entering = false
	}
	return true
}

// Percent divides the current value by 100 and ends the entry.
func (e *Engine) Percent() bool {
	if e.prog || e.hasErr {
		return false
	}
	c, ok := mulN(e.cur, num{m: 1, s: 2})
	if !ok {
		e.fail()
		return true
	}
	e.cur = c
	e.entering = false
	e.point = false
	return true
}

// Negate flips the sign of the current value; ± on minI64 → ERROR.
func (e *Engine) Negate() bool {
	if e.hasErr {
		return false
	}
	if e.cur.m == minI64 {
		e.fail()
		return true
	}
	e.cur.m = -e.cur.m
	return true
}

// Not is the programmer-mode bitwise complement of the current value.
func (e *Engine) Not() bool {
	if !e.prog || e.hasErr {
		return false
	}
	e.cur.m = ^e.cur.m
	e.entering = false
	return true
}

// SetOp commits the pending op if a value is being entered, then arms op.
// In programmer mode '&','|','^','<','>' are also valid ops. A refused op
// reports false; an op accepted over an evaluation that failed reports
// true and leaves the engine in ERROR.
func (e *Engine) SetOp(op byte) bool {
	if e.hasErr {
		return false
	}
	switch op {
	case '+', '-', '*', '/':
	case '&', '|', '^', '<', '>':
		if !e.prog {
			return false
		}
	default:
		return false
	}
	if e.entering && e.pending != 0 {
		e.Evaluate()
		if e.hasErr {
			return true
		}
	}
	e.accum = e.cur
	e.pending = op
	e.entering = false
	e.point = false
	return true
}

// SetBase switches the programmer display base; the live entry ends (new
// digits read in the new base) but the value is untouched.
func (e *Engine) SetBase(b uint8) bool {
	if !e.prog {
		return false
	}
	switch b {
	case 2, 8, 10, 16:
	default:
		return false
	}
	e.base = b
	e.entering = false
	e.point = false
	return true
}

// SetProg toggles modes. The truncated integer of the display carries
// over; pending ops, the live entry, and any error do not.
func (e *Engine) SetProg(on bool) bool {
	if e.prog == on {
		return false
	}
	e.prog = on
	if on && e.base == 0 {
		e.base = 16
	}
	cur := e.cur
	for i := uint8(0); i < cur.s; i++ {
		cur.m /= 10
	}
	e.cur = num{m: cur.m}
	e.accum = num{}
	e.pending = 0
	e.lastOp = 0
	e.lastArg = num{}
	e.entering = false
	e.point = false
	e.hasErr = false
	return true
}

// Evaluate applies the pending binary op, or repeats the last one on a
// bare '=' (`5 + 3 = =` → 8, then 11).
func (e *Engine) Evaluate() {
	if e.hasErr {
		return
	}
	if e.pending != 0 {
		e.evalBinary(e.pending, e.accum, e.cur)
		return
	}
	if e.lastOp != 0 {
		e.evalBinary(e.lastOp, e.cur, e.lastArg)
	}
}

func (e *Engine) evalBinary(op byte, a, b num) {
	var res num
	ok := true
	if e.prog {
		res, ok = evalProg(op, a.m, b.m)
	} else {
		switch op {
		case '+':
			res, ok = addN(a, b)
		case '-':
			res, ok = subN(a, b)
		case '*':
			res, ok = mulN(a, b)
		case '/':
			res, ok = divN(a, b)
		default:
			res = b
		}
	}
	if !ok {
		e.fail()
		return
	}
	e.cur = res
	e.accum = res
	if e.pending != 0 {
		e.lastOp = op
		e.lastArg = b
	}
	e.pending = 0
	e.entering = false
	e.point = false
}

// evalProg is the checked-int64 programmer surface. Shifts take Go int64
// semantics: a negative count → ERROR, a count ≥ 64 gives 0 for << and
// sign-fill for >>.
func evalProg(op byte, a, b int64) (num, bool) {
	var r int64
	ok := true
	switch op {
	case '+':
		r, ok = add64(a, b)
	case '-':
		r, ok = sub64(a, b)
	case '*':
		r, ok = mul64(a, b)
	case '/':
		if b == 0 || (a == minI64 && b == -1) {
			ok = false
		} else {
			r = a / b
		}
	case '&':
		r = a & b
	case '|':
		r = a | b
	case '^':
		r = a ^ b
	case '<':
		if b < 0 {
			return num{}, false
		}
		r = a << uint(b)
	case '>':
		if b < 0 {
			return num{}, false
		}
		r = a >> uint(b)
	default:
		r = b
	}
	return num{m: r}, ok
}

// Clear resets the calculation — values, pending ops, entry, ERROR — but
// not the mode: programmer/decimal and the base survive a 'C'.
func (e *Engine) Clear() {
	prog, base := e.prog, e.base
	*e = Engine{prog: prog, base: base}
}

// Mode is the state envelope's mode pair: prog and the live display base,
// or (false, 0) in decimal mode where the base field is meaningless.
func (e *Engine) Mode() (bool, uint8) {
	if !e.prog {
		return false, 0
	}
	return true, e.dispBase()
}

// RestoreMode re-seats prog+base from a decoded envelope — SetProg's
// carry-the-display contract is a user toggle's, and a restore arrives
// before any value exists. The decoder already proved base is one of the
// four spellings (or 0 on a decimal blob).
func (e *Engine) RestoreMode(prog bool, base uint8) {
	e.prog = prog
	e.base = base
}

// Display is the screen string: "ERROR", the base-format value in
// programmer mode, or the decimal text (live entries keep their typed
// point and trailing zeros).
func (e *Engine) Display() string {
	if e.hasErr {
		return "ERROR"
	}
	if e.prog {
		return formatBase(e.cur.m, e.dispBase())
	}
	return formatEntry(e.cur, e.entering && e.point)
}

// formatEntry renders m×10^-s with exactly s fraction digits.
func formatEntry(n num, point bool) string {
	digits := formatU64(mag(n.m))
	var s string
	if n.s == 0 {
		s = digits
		if point {
			s += "."
		}
	} else {
		for len(digits) <= int(n.s) {
			digits = "0" + digits
		}
		i := len(digits) - int(n.s)
		s = digits[:i] + "." + digits[i:]
	}
	if n.m < 0 {
		s = "-" + s
	}
	return s
}

// formatBase renders v in the programmer display base; non-decimal bases
// show the 64-bit two's-complement pattern.
func formatBase(v int64, base uint8) string {
	switch base {
	case 16:
		return formatRadix(uint64(v), 16, "0123456789ABCDEF")
	case 8:
		return formatRadix(uint64(v), 8, "01234567")
	case 2:
		return formatRadix(uint64(v), 2, "01")
	}
	return formatI64(v)
}

func formatRadix(u, base uint64, digits string) string {
	if u == 0 {
		return "0"
	}
	var buf [64]byte
	i := len(buf)
	for u > 0 {
		i--
		buf[i] = digits[u%base]
		u /= base
	}
	return string(buf[i:])
}

func formatU64(u uint64) string {
	if u == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for u > 0 {
		i--
		buf[i] = byte('0' + u%10)
		u /= 10
	}
	return string(buf[i:])
}

func formatI64(v int64) string {
	if v < 0 {
		return "-" + formatU64(mag(v))
	}
	return formatU64(uint64(v))
}
