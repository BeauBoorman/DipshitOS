// Command gosheet is the M142a (#2789) spreadsheet: a 128-column x 64-row
// grid (A1..DX64) over a sparse cell store, an A1-formula evaluator with a
// topological recalculation, and the M137b (#2772) virtualized table for the
// grid plus an edit line. Cells hold a literal (number or text) or a
// formula; every commit re-evaluates the sheet and dependent cells repaint
// with their new values. A formula that reaches itself is refused by name:
// every cell on the cycle displays #CYCLE and the walk never recurses.
//
// The evaluator's error vocabulary is the card's four codes: #PARSE (the
// formula text would not parse), #REF (an address outside the grid),
// #DIV/0 (a division by zero or an average with nothing to average), and
// #CYCLE. Errors are values: a reference to an error cell yields that
// error, which is why dependents of a cycle show #CYCLE too.
//
// model.go holds the grid vocabulary and the sparse store; formula.go is
// the grammar; eval.go the evaluator; main.go the app shell.
package main

import (
	"strconv"
	"strings"
)

const (
	// NumCols x NumRows is the sheet bound from the card: 128 columns
	// (A..DX) by 64 rows. MaxCells bounds the sparse store.
	NumCols  = 128
	NumRows  = 64
	MaxCells = 2048
)

// cellRef is a 0-based grid address.
type cellRef struct{ col, row int }

func refAt(col, row int) cellRef { return cellRef{col: col, row: row} }

func (r cellRef) inBounds() bool {
	return r.col >= 0 && r.col < NumCols && r.row >= 0 && r.row < NumRows
}

func (r cellRef) String() string { return colName(r.col) + itoaDec(r.row+1) }

// colName renders a 0-based column index as A..Z, AA..DX.
func colName(col int) string {
	var buf [8]byte
	i := len(buf)
	for n := col + 1; n > 0; {
		n--
		i--
		buf[i] = byte('A' + n%26)
		n /= 26
	}
	return string(buf[i:])
}

func itoaDec(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [12]byte
	i := len(buf)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

// parseRef reads an A1-style address, case-insensitive. ok=false means the
// text is not letters-then-digits; an in-alphabet address outside the grid
// (A0, DY1) still parses — the evaluator answers #REF for it.
func parseRef(s string) (cellRef, bool) {
	i, col := 0, 0
	for i < len(s) && isAlpha(s[i]) {
		col = col*26 + int(upper(s[i])-'A') + 1
		i++
	}
	if i == 0 || i == len(s) {
		return cellRef{}, false
	}
	row := 0
	for i < len(s) && isDigit(s[i]) {
		row = row*10 + int(s[i]-'0')
		i++
	}
	if i != len(s) {
		return cellRef{}, false
	}
	return cellRef{col: col - 1, row: row - 1}, true
}

func isAlpha(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }
func isDigit(c byte) bool { return c >= '0' && c <= '9' }
func upper(c byte) byte {
	if c >= 'a' && c <= 'z' {
		return c - 'a' + 'A'
	}
	return c
}

// errCode is the evaluator's four-code error vocabulary.
type errCode uint8

const (
	errNone errCode = iota
	errParse
	errRef
	errDiv0
	errCycle
)

func (e errCode) String() string {
	switch e {
	case errParse:
		return "#PARSE"
	case errRef:
		return "#REF"
	case errDiv0:
		return "#DIV/0"
	case errCycle:
		return "#CYCLE"
	}
	return "?"
}

// Value kinds: empty (a never-filled address), numeric, or text. An errCode
// other than errNone makes the value an error regardless of kind.
const (
	vEmpty byte = iota
	vNum
	vText
)

type value struct {
	num  float64
	str  string
	err  errCode
	kind byte
}

func numVal(f float64) value { return value{kind: vNum, num: f} }
func textVal(s string) value { return value{kind: vText, str: s} }
func errVal(e errCode) value { return value{err: e} }
func emptyVal() value        { return value{kind: vEmpty} }

// display renders a value the way a cell shows it.
func display(v value) string {
	if v.err != errNone {
		return v.err.String()
	}
	switch v.kind {
	case vNum:
		return strconv.FormatFloat(v.num, 'g', -1, 64)
	case vText:
		return v.str
	}
	return ""
}

// num coerces a value for arithmetic: errors propagate, empty and text
// cells count as 0.
func num(v value) (float64, errCode) {
	if v.err != errNone {
		return 0, v.err
	}
	if v.kind == vNum {
		return v.num, errNone
	}
	return 0, errNone
}

// cell is one filled slot: the raw text as typed, the parsed formula when
// the raw text began with '=', and the cached evaluated value. A formula
// that failed to parse keeps expr=nil and carries errParse in val, so it
// displays #PARSE and propagates like any other error.
type cell struct {
	raw  string
	expr *node
	val  value
}

// Sheet is the sparse store. Filled cells live in a map keyed by address;
// the grid itself never materializes. cyc is the last recalc's discovered
// cycle membership — cells ON a cycle, a subset of those displaying
// #CYCLE (dependents merely propagate the error).
type Sheet struct {
	cells map[cellRef]*cell
	cyc   map[cellRef]bool
}

func newSheet() *Sheet { return &Sheet{cells: map[cellRef]*cell{}} }

func (s *Sheet) filled() int { return len(s.cells) }

func (s *Sheet) raw(r cellRef) string {
	if c := s.cells[r]; c != nil {
		return c.raw
	}
	return ""
}

func (s *Sheet) display(r cellRef) string {
	if c := s.cells[r]; c != nil {
		return display(c.val)
	}
	return ""
}

// set replaces cell r's content with raw ("" clears). ok=false refuses:
// the address is outside the grid, or the store holds MaxCells cells and r
// is not one of them — the cap keeps the sheet inside the card's bound
// instead of growing without limit. On success the sheet re-evaluates and
// the returned refs are every address whose display changed, sorted
// row-major.
func (s *Sheet) set(r cellRef, raw string) (changed []cellRef, ok bool) {
	prev := s.display(r) // the pre-edit display, for honest change reporting
	if !s.setQuiet(r, raw) {
		return nil, false
	}
	return s.recalcEdited(r, prev), true
}

// setQuiet is set without the recalc — the batch paths (CSV import, paste,
// state restore) fill a region first, then re-evaluate the sheet once.
// The same refusals apply: out-of-bounds or a capped store.
func (s *Sheet) setQuiet(r cellRef, raw string) bool {
	if !r.inBounds() {
		return false
	}
	raw = strings.TrimSpace(raw)
	if raw == "" {
		delete(s.cells, r)
		return true
	}
	if _, exists := s.cells[r]; !exists && len(s.cells) >= MaxCells {
		return false
	}
	c := &cell{raw: raw}
	if raw[0] == '=' {
		if n, good := parseFormula(raw[1:]); good {
			c.expr = n
		} else {
			c.val = errVal(errParse)
		}
	} else {
		c.val = literalVal(raw)
	}
	s.cells[r] = c
	return true
}

// sortedRefs lists the filled addresses row-major — the state blob's
// deterministic cell order.
func (s *Sheet) sortedRefs() []cellRef {
	var out []cellRef
	for r := range s.cells {
		out = append(out, r)
	}
	sortRefs(out)
	return out
}

// literalVal classifies non-formula text: a number when the whole trimmed
// string parses as one, text otherwise.
func literalVal(raw string) value {
	if f, err := strconv.ParseFloat(raw, 64); err == nil {
		return numVal(f)
	}
	return textVal(raw)
}

// recalc re-evaluates every cell with one memoized depth-first walk and
// reports the addresses whose display string changed. Recompute-all is the
// honest bound: at most MaxCells formulas, each evaluated once per commit.
func (s *Sheet) recalc() []cellRef { return s.recalcEdited(cellRef{col: -1}, "") }

// recalcEdited is recalc after the cell at `edited` was replaced: prev is
// that cell's pre-edit display, so a same-display commit reports nothing.
func (s *Sheet) recalcEdited(edited cellRef, prev string) []cellRef {
	old := make(map[cellRef]string, len(s.cells))
	for r, c := range s.cells {
		old[r] = display(c.val)
	}
	old[edited] = prev
	e := &evaluator{
		s:     s,
		memo:  make(map[cellRef]value, len(s.cells)),
		state: make(map[cellRef]uint8, len(s.cells)),
		cycle: map[cellRef]bool{},
	}
	for r, c := range s.cells {
		c.val = e.eval(r)
	}
	s.cyc = e.cycle
	var changed []cellRef
	for r, c := range s.cells {
		if display(c.val) != old[r] {
			changed = append(changed, r)
		}
	}
	sortRefs(changed)
	return changed
}

// sortRefs orders addresses row-major (row, then column).
func sortRefs(rs []cellRef) {
	for i := 1; i < len(rs); i++ {
		for j := i; j > 0 && less(rs[j], rs[j-1]); j-- {
			rs[j], rs[j-1] = rs[j-1], rs[j]
		}
	}
}

func less(a, b cellRef) bool {
	return a.row < b.row || a.row == b.row && a.col < b.col
}

// cycleRefs lists the cells ON a discovered cycle, row-major — the app's
// `gosheet: cycle` marker names this set verbatim. Dependents that only
// propagate #CYCLE are not members.
func (s *Sheet) cycleRefs() []cellRef {
	var out []cellRef
	for r := range s.cyc {
		out = append(out, r)
	}
	sortRefs(out)
	return out
}
