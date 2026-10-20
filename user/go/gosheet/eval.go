// The M142a evaluator: one memoized depth-first walk per commit. eval()
// answers a cell's value; formula cells recurse through their references,
// so the depth-first stack IS the dependency path. Hitting a cell already
// on the stack is a back edge — the span of the stack from that cell to
// the top is the cycle, every cell on it is marked, and the unwinding
// stamps #CYCLE on each member. Members never recurse: the second visit
// returns the code instead of descending again.
package main

import "math"

type evaluator struct {
	s     *Sheet
	memo  map[cellRef]value
	state map[cellRef]uint8 // 1 = on the DFS stack, 2 = settled
	stack []cellRef
	cycle map[cellRef]bool
}

func (e *evaluator) eval(r cellRef) value {
	if !r.inBounds() {
		return errVal(errRef)
	}
	c := e.s.cells[r]
	if c == nil {
		return emptyVal()
	}
	if v, ok := e.memo[r]; ok {
		return v
	}
	if e.state[r] == 1 {
		// Back edge: stack[i..top] is the discovered cycle. Each member is
		// still mid-compute; the cycle set forces #CYCLE as each unwinds.
		for i := len(e.stack) - 1; i >= 0; i-- {
			e.cycle[e.stack[i]] = true
			if e.stack[i] == r {
				break
			}
		}
		return errVal(errCycle)
	}
	e.state[r] = 1
	e.stack = append(e.stack, r)
	v := e.compute(c)
	if e.cycle[r] {
		v = errVal(errCycle)
	}
	e.stack = e.stack[:len(e.stack)-1]
	e.state[r] = 2
	e.memo[r] = v
	return v
}

func (e *evaluator) compute(c *cell) value {
	if c.expr == nil {
		return c.val // literal, or a stored #PARSE
	}
	v := e.expr(c.expr)
	if v.err == errNone && v.kind == vEmpty {
		// A lone ref to an empty cell displays 0, not a blank.
		v = numVal(0)
	}
	return v
}

func (e *evaluator) expr(n *node) value {
	switch n.op {
	case opNum:
		return numVal(n.num)
	case opRef:
		return e.eval(n.ref)
	case opNeg:
		f, err := e.numof(n.a)
		if err != errNone {
			return errVal(err)
		}
		return numVal(-f)
	case opAdd, opSub, opMul, opDiv:
		l, err := e.numof(n.a)
		if err != errNone {
			return errVal(err)
		}
		r, err := e.numof(n.b)
		if err != errNone {
			return errVal(err)
		}
		switch n.op {
		case opAdd:
			return numVal(l + r)
		case opSub:
			return numVal(l - r)
		case opMul:
			return numVal(l * r)
		default:
			if r == 0 {
				return errVal(errDiv0)
			}
			return numVal(l / r)
		}
	case opFunc:
		return e.call(n)
	}
	return errVal(errParse)
}

// numof evaluates a sub-expression and coerces its value to a number.
func (e *evaluator) numof(n *node) (float64, errCode) {
	v := e.expr(n)
	f, err := num(v)
	return f, err
}

// call dispatches a function node. ABS/ROUND read numeric args; the
// aggregate family collects the numerics of each arg (a range contributes
// its filled numeric cells — empty and text slots do not count).
func (e *evaluator) call(n *node) value {
	switch n.fn {
	case fnAbs:
		f, err := e.numof(n.args[0])
		if err != errNone {
			return errVal(err)
		}
		return numVal(math.Abs(f))
	case fnRound:
		f, err := e.numof(n.args[0])
		if err != errNone {
			return errVal(err)
		}
		d := 0.0
		if len(n.args) == 2 {
			d, err = e.numof(n.args[1])
			if err != errNone {
				return errVal(err)
			}
			// Keep the scale finite; a silly digit count clamps.
			if d > 9 {
				d = 9
			}
			if d < -9 {
				d = -9
			}
			d = math.Trunc(d)
		}
		p := math.Pow(10, d)
		return numVal(roundHalf(f*p) / p)
	}

	// Aggregates: SUM AVG MIN MAX COUNT.
	var nums []float64
	for _, a := range n.args {
		if err := e.collect(a, &nums); err != errNone {
			return errVal(err)
		}
	}
	switch n.fn {
	case fnSum:
		return numVal(sumOf(nums))
	case fnAvg:
		if len(nums) == 0 {
			return errVal(errDiv0)
		}
		return numVal(sumOf(nums) / float64(len(nums)))
	case fnMin:
		if len(nums) == 0 {
			return numVal(0)
		}
		m := nums[0]
		for _, f := range nums[1:] {
			if f < m {
				m = f
			}
		}
		return numVal(m)
	case fnMax:
		if len(nums) == 0 {
			return numVal(0)
		}
		m := nums[0]
		for _, f := range nums[1:] {
			if f > m {
				m = f
			}
		}
		return numVal(m)
	case fnCount:
		return numVal(float64(len(nums)))
	}
	return errVal(errParse)
}

// collect appends the numeric values an argument contributes. A range
// walks its filled cells row-major (either endpoint order); an expression
// contributes its own value when numeric. Errors propagate from either.
func (e *evaluator) collect(a *node, out *[]float64) errCode {
	if a.op == opRange {
		if !a.ref.inBounds() || !a.ref2.inBounds() {
			return errRef
		}
		r0, r1 := a.ref.row, a.ref2.row
		if r0 > r1 {
			r0, r1 = r1, r0
		}
		c0, c1 := a.ref.col, a.ref2.col
		if c0 > c1 {
			c0, c1 = c1, c0
		}
		for row := r0; row <= r1; row++ {
			for col := c0; col <= c1; col++ {
				v := e.eval(refAt(col, row))
				if v.err != errNone {
					return v.err
				}
				if v.kind == vNum {
					*out = append(*out, v.num)
				}
			}
		}
		return errNone
	}
	v := e.expr(a)
	if v.err != errNone {
		return v.err
	}
	if v.kind == vNum {
		*out = append(*out, v.num)
	}
	return errNone
}

func sumOf(nums []float64) float64 {
	t := 0.0
	for _, f := range nums {
		t += f
	}
	return t
}

// roundHalf rounds half away from zero — the ROUND convention.
func roundHalf(f float64) float64 {
	if f < 0 {
		return math.Ceil(f - 0.5)
	}
	return math.Floor(f + 0.5)
}
