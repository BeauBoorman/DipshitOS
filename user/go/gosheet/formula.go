// The M142a formula grammar, the text after the leading '=':
//
//	expr    := term (('+' | '-') term)*
//	term    := factor (('*' | '/') factor)*
//	factor  := '-' factor | '+' factor | primary
//	primary := number | ref | errlit | func '(' args ')' | '(' expr ')'
//	args    := arg (',' arg)*
//	arg     := ref ':' ref | expr
//	func    := SUM | AVG | MIN | MAX | COUNT | ABS | ROUND   (case-insensitive)
//	ref     := '$'? col '$'? row                        (M152a: $ anchors an axis)
//	errlit  := '#PARSE' | '#REF' | '#DIV/0' | '#CYCLE'  (M152a: fill's OOB answer)
//
// Ranges exist only as function arguments: a bare '=A1:B2' is #PARSE, and
// ABS/ROUND take expressions only (a range there is #PARSE too). '[' and
// ']' lex as '(' and ')' — the same grammar — because the gate's
// injected-chord vocabulary (and the input path's own history, cf.
// go-calc.spec's HID table) cannot spell '(' or ')'. SUM[A1:A2] is the
// canonical gate spelling of SUM(A1:A2).
//
// M152a (#2915): '$' anchors a reference axis for the fill engine — $A1
// holds the column, A$1 the row, $A$1 both. Anchoring is fill metadata:
// the evaluator resolves an anchored ref exactly like a bare one. The
// error literals exist so a fill that shifts a reference off the grid can
// spell the result ('=A1+#REF' propagates #REF the way a dead ref would);
// nobody can type them into an interesting expression that was not already
// broken.
package main

import "strconv"

type opKind uint8

const (
	opNum opKind = iota
	opRef
	opNeg
	opAdd
	opSub
	opMul
	opDiv
	opFunc
	opRange // only legal as a function argument
	opErr   // an error literal — fill's answer to a shifted-off-grid ref
)

// absCol/absRow mark a reference's anchored axes (the '$' halves); a ref
// node's abs carries both bits, a range node's abs/abs2 one per endpoint.
const (
	absCol byte = 1
	absRow byte = 2
)

type fnKind uint8

const (
	fnSum fnKind = iota
	fnAvg
	fnMin
	fnMax
	fnCount
	fnAbs
	fnRound
)

// node is one AST node: an operand, an operator with a/b children, a
// function call with args, or a range arg (ref:ref2).
type node struct {
	op   opKind
	num  float64
	ref  cellRef
	ref2 cellRef
	fn   fnKind
	a, b *node
	args []*node
	abs  byte    // opRef: anchored axes; opRange: ref's axes
	abs2 byte    // opRange: ref2's axes
	err  errCode // opErr: the literal's code
}

// Token kinds for the lexer.
const (
	tEnd byte = iota
	tBad
	tNum
	tRef
	tIdent
	tLP
	tRP
	tColon
	tComma
	tPlus
	tMinus
	tStar
	tSlash
	tErr
)

type tok struct {
	kind byte
	num  float64
	ref  cellRef
	txt  string  // identifier text (uppercased) for tIdent
	abs  byte    // anchored axes for tRef
	err  errCode // the code for tErr
}

// lex splits the formula body into tokens. '[' and ']' spell '(' and ')'.
func lex(s string) []tok {
	var out []tok
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == ' ' || c == '\t':
			i++
		case isDigit(c) || c == '.' && i+1 < len(s) && isDigit(s[i+1]):
			j := i
			for j < len(s) && (isDigit(s[j]) || s[j] == '.') {
				j++
			}
			f, err := strconv.ParseFloat(s[i:j], 64)
			if err != nil {
				return append(out, tok{kind: tBad})
			}
			out = append(out, tok{kind: tNum, num: f})
			i = j
		case isAlpha(c) || c == '$':
			j := i
			var abs byte
			if s[j] == '$' {
				abs = absCol
				j++
			}
			w0 := j
			for j < len(s) && isAlpha(s[j]) {
				j++
			}
			word := s[w0:j]
			if j < len(s) && s[j] == '$' {
				abs |= absRow
				j++
			}
			d0 := j
			for j < len(s) && isDigit(s[j]) {
				j++
			}
			if j > d0 && len(word) > 0 {
				r, _ := parseRef(word + s[d0:j])
				out = append(out, tok{kind: tRef, ref: r, abs: abs})
			} else if len(word) > 0 && abs == 0 {
				up := []byte(word)
				for p := range up {
					up[p] = upper(up[p])
				}
				out = append(out, tok{kind: tIdent, txt: string(up)})
			} else {
				// A '$' that never completed a ref ($A, A$, $1) —
				// there is no ident spelling with an anchor.
				return append(out, tok{kind: tBad})
			}
			i = j
		case c == '#':
			j := i + 1
			for j < len(s) && (isAlpha(s[j]) || isDigit(s[j]) || s[j] == '/') {
				j++
			}
			if e, ok := errByName(s[i:j]); ok {
				out = append(out, tok{kind: tErr, err: e})
				i = j
				continue
			}
			return append(out, tok{kind: tBad})
		default:
			i++
			var k byte
			switch c {
			case '(', '[':
				k = tLP
			case ')', ']':
				k = tRP
			case ':':
				k = tColon
			case ',':
				k = tComma
			case '+':
				k = tPlus
			case '-':
				k = tMinus
			case '*':
				k = tStar
			case '/':
				k = tSlash
			default:
				k = tBad
			}
			out = append(out, tok{kind: k})
		}
	}
	return append(out, tok{kind: tEnd})
}

// errByName resolves an error literal's text, case-folded like every
// other formula spelling. The names are the errCode display strings.
func errByName(s string) (errCode, bool) {
	for _, e := range []errCode{errParse, errRef, errDiv0, errCycle} {
		name := e.String()
		if len(s) == len(name) {
			ok := true
			for i := 0; i < len(s); i++ {
				if upper(s[i]) != name[i] {
					ok = false
					break
				}
			}
			if ok {
				return e, true
			}
		}
	}
	return errNone, false
}

var fnNames = map[string]fnKind{
	"SUM":   fnSum,
	"AVG":   fnAvg,
	"MIN":   fnMin,
	"MAX":   fnMax,
	"COUNT": fnCount,
	"ABS":   fnAbs,
	"ROUND": fnRound,
}

type parser struct {
	toks []tok
	i    int
	fail bool
}

func (p *parser) peek() byte { return p.toks[p.i].kind }
func (p *parser) next() tok  { t := p.toks[p.i]; p.i++; return t }
func (p *parser) take(k byte) bool {
	if p.peek() == k {
		p.i++
		return true
	}
	return false
}

// parseFormula parses the text after '=' into an AST. false means #PARSE.
func parseFormula(s string) (*node, bool) {
	p := &parser{toks: lex(s)}
	n := p.expr()
	if p.fail || p.peek() != tEnd || n == nil {
		return nil, false
	}
	return n, true
}

func (p *parser) expr() *node {
	a := p.term()
	for p.peek() == tPlus || p.peek() == tMinus {
		op := opAdd
		if p.next().kind == tMinus {
			op = opSub
		}
		b := p.term()
		a = &node{op: op, a: a, b: b}
	}
	return a
}

func (p *parser) term() *node {
	a := p.factor()
	for p.peek() == tStar || p.peek() == tSlash {
		op := opMul
		if p.next().kind == tSlash {
			op = opDiv
		}
		b := p.factor()
		a = &node{op: op, a: a, b: b}
	}
	return a
}

func (p *parser) factor() *node {
	switch p.peek() {
	case tMinus:
		p.i++
		return &node{op: opNeg, a: p.factor()}
	case tPlus:
		p.i++
		return p.factor()
	}
	return p.primary()
}

func (p *parser) primary() *node {
	switch p.peek() {
	case tNum:
		return &node{op: opNum, num: p.next().num}
	case tRef:
		t := p.next()
		return &node{op: opRef, ref: t.ref, abs: t.abs}
	case tErr:
		return &node{op: opErr, err: p.next().err}
	case tLP:
		p.i++
		n := p.expr()
		if !p.take(tRP) {
			p.fail = true
			return nil
		}
		return n
	case tIdent:
		name := p.next().txt
		fn, known := fnNames[name]
		if !known || !p.take(tLP) {
			p.fail = true
			return nil
		}
		return p.call(fn)
	}
	p.fail = true
	return nil
}

// call parses the argument list after the opening paren. Each argument is
// a ref:ref range or an expression; arity is checked per function here, so
// a malformed call is #PARSE rather than an eval-time surprise.
func (p *parser) call(fn fnKind) *node {
	n := &node{op: opFunc, fn: fn}
	for {
		if p.peek() == tRef && p.toks[p.i+1].kind == tColon && p.toks[p.i+2].kind == tRef {
			from := p.next()
			p.i++ // ':'
			to := p.next()
			if fn == fnAbs || fn == fnRound {
				p.fail = true
				return nil
			}
			n.args = append(n.args, &node{op: opRange, ref: from.ref, abs: from.abs, ref2: to.ref, abs2: to.abs})
		} else {
			a := p.expr()
			if a == nil {
				return nil
			}
			n.args = append(n.args, a)
		}
		if p.take(tComma) {
			continue
		}
		if !p.take(tRP) {
			p.fail = true
			return nil
		}
		break
	}
	switch fn {
	case fnAbs:
		if len(n.args) != 1 {
			p.fail = true
			return nil
		}
	case fnRound:
		if len(n.args) < 1 || len(n.args) > 2 {
			p.fail = true
			return nil
		}
	}
	return n
}
