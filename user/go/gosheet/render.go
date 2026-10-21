// M152a (#2915): the fill half of the formula layer — walking a parsed
// formula back out to canonical text with its references shifted. Fill
// copies a formula cell by re-emitting its AST (dc, dr) cells away:
// relative axes move with the copy, '$'-anchored axes hold, and a
// reference the shift pushes off the grid becomes the #REF literal — the
// same answer a deleted target would give.
//
// The emitter is canonical, not verbatim: 'sum[a1:a2]' fills as
// 'SUM(A1:A2)' and redundant parens come back only where precedence needs
// them — the shifted formula reparses to an equivalent AST, never to the
// original spelling.
package main

import (
	"strconv"
	"strings"
)

// shiftRaw rewrites one cell's raw text for a copy (dc, dr) cells away.
// Non-formula raws and formulas that do not parse copy verbatim — the
// fill is not a repair pass.
func shiftRaw(raw string, dc, dr int) string {
	if len(raw) == 0 || raw[0] != '=' {
		return raw
	}
	n, ok := parseFormula(raw[1:])
	if !ok {
		return raw
	}
	return "=" + renderFormula(shiftNode(n, dc, dr))
}

// shiftNode returns a copy of the tree with every unanchored axis moved
// by (dc, dr). The source AST is never mutated — the seed cell's own
// expr shares the input nodes.
func shiftNode(n *node, dc, dr int) *node {
	switch n.op {
	case opRef:
		m := *n
		r, ok := shiftRef(n.ref, n.abs, dc, dr)
		if !ok {
			return &node{op: opErr, err: errRef}
		}
		m.ref = r
		return &m
	case opRange:
		m := *n
		var ok bool
		if m.ref, ok = shiftRef(n.ref, n.abs, dc, dr); !ok {
			return &node{op: opErr, err: errRef}
		}
		if m.ref2, ok = shiftRef(n.ref2, n.abs2, dc, dr); !ok {
			return &node{op: opErr, err: errRef}
		}
		return &m
	case opFunc:
		m := *n
		m.args = make([]*node, len(n.args))
		for i, a := range n.args {
			m.args[i] = shiftNode(a, dc, dr)
		}
		return &m
	case opNeg, opAdd, opSub, opMul, opDiv:
		m := *n
		m.a = shiftNode(n.a, dc, dr)
		if n.b != nil {
			m.b = shiftNode(n.b, dc, dr)
		}
		return &m
	}
	return n // opNum, opErr — nothing to move
}

// shiftRef applies the delta to the ref's unanchored axes; ok=false when
// the result lands outside the grid (the caller substitutes #REF).
func shiftRef(r cellRef, abs byte, dc, dr int) (cellRef, bool) {
	c, row := r.col, r.row
	if abs&absCol == 0 {
		c += dc
	}
	if abs&absRow == 0 {
		row += dr
	}
	out := refAt(c, row)
	return out, out.inBounds()
}

// emitPrec ranks operators the way the grammar nests them: additive
// lowest, then multiplicative, then unary minus, then primaries. A child
// rendered under a higher-required precedence gets its parens back —
// '(a+b)*c' round-trips because opAdd's 1 is under opMul's factor-side 3.
func emitPrec(n *node) int {
	switch n.op {
	case opAdd, opSub:
		return 1
	case opMul, opDiv:
		return 2
	case opNeg:
		return 3
	}
	return 4
}

func renderFormula(n *node) string {
	var sb strings.Builder
	emitNode(&sb, n, 0)
	return sb.String()
}

// emitNode writes n at minimum precedence minPrec, parenthesizing the
// whole node when its own precedence is lower.
func emitNode(sb *strings.Builder, n *node, minPrec int) {
	if emitPrec(n) < minPrec {
		sb.WriteByte('(')
		emitOp(sb, n)
		sb.WriteByte(')')
		return
	}
	emitOp(sb, n)
}

func emitOp(sb *strings.Builder, n *node) {
	switch n.op {
	case opNum:
		sb.WriteString(strconv.FormatFloat(n.num, 'g', -1, 64))
	case opRef:
		emitRef(sb, n.ref, n.abs)
	case opRange:
		emitRef(sb, n.ref, n.abs)
		sb.WriteByte(':')
		emitRef(sb, n.ref2, n.abs2)
	case opErr:
		sb.WriteString(n.err.String())
	case opNeg:
		sb.WriteByte('-')
		emitNode(sb, n.a, 3)
	case opAdd, opSub, opMul, opDiv:
		// The left operand sits at the node's own precedence (the grammar
		// is left-associative, so an equal-precedence child never needed
		// parens); the right operand sits one level tighter, because a
		// same-level operator there did.
		right := 3
		if n.op == opAdd || n.op == opSub {
			right = 2
		}
		emitNode(sb, n.a, emitPrec(n))
		switch n.op {
		case opAdd:
			sb.WriteByte('+')
		case opSub:
			sb.WriteByte('-')
		case opMul:
			sb.WriteByte('*')
		default:
			sb.WriteByte('/')
		}
		emitNode(sb, n.b, right)
	case opFunc:
		sb.WriteString(fnName(n.fn))
		sb.WriteByte('(')
		for i, a := range n.args {
			if i > 0 {
				sb.WriteByte(',')
			}
			emitNode(sb, a, 0)
		}
		sb.WriteByte(')')
	}
}

// emitRef writes one A1 address with its '$' anchors back on.
func emitRef(sb *strings.Builder, r cellRef, abs byte) {
	if abs&absCol != 0 {
		sb.WriteByte('$')
	}
	sb.WriteString(colName(r.col))
	if abs&absRow != 0 {
		sb.WriteByte('$')
	}
	sb.WriteString(itoaDec(r.row + 1))
}

// fnName is fnNames' inverse for the emitter.
func fnName(f fnKind) string {
	switch f {
	case fnSum:
		return "SUM"
	case fnAvg:
		return "AVG"
	case fnMin:
		return "MIN"
	case fnMax:
		return "MAX"
	case fnCount:
		return "COUNT"
	case fnAbs:
		return "ABS"
	case fnRound:
		return "ROUND"
	}
	return "?"
}
