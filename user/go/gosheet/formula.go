// The M142a formula grammar, the text after the leading '=':
//
//	expr    := term (('+' | '-') term)*
//	term    := factor (('*' | '/') factor)*
//	factor  := '-' factor | '+' factor | primary
//	primary := number | ref | func '(' args ')' | '(' expr ')'
//	args    := arg (',' arg)*
//	arg     := ref ':' ref | expr
//	func    := SUM | AVG | MIN | MAX | COUNT | ABS | ROUND   (case-insensitive)
//
// Ranges exist only as function arguments: a bare '=A1:B2' is #PARSE, and
// ABS/ROUND take expressions only (a range there is #PARSE too). '[' and
// ']' lex as '(' and ')' — the same grammar — because the gate's
// injected-chord vocabulary (and the input path's own history, cf.
// go-calc.spec's HID table) cannot spell '(' or ')'. SUM[A1:A2] is the
// canonical gate spelling of SUM(A1:A2).
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
)

type tok struct {
	kind byte
	num  float64
	ref  cellRef
	txt  string // identifier text (uppercased) for tIdent
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
		case isAlpha(c):
			j := i
			for j < len(s) && isAlpha(s[j]) {
				j++
			}
			word := s[i:j]
			k := j
			for k < len(s) && isDigit(s[k]) {
				k++
			}
			if k > j {
				r, _ := parseRef(s[i:k])
				out = append(out, tok{kind: tRef, ref: r})
				i = k
			} else {
				up := []byte(word)
				for p := range up {
					up[p] = upper(up[p])
				}
				out = append(out, tok{kind: tIdent, txt: string(up)})
				i = j
			}
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
		return &node{op: opRef, ref: p.next().ref}
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
			from := p.next().ref
			p.i++ // ':'
			to := p.next().ref
			if fn == fnAbs || fn == fnRound {
				p.fail = true
				return nil
			}
			n.args = append(n.args, &node{op: opRange, ref: from, ref2: to})
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
