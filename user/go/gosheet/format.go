// M152a (#2915): per-column display formats. A format changes how a
// column's numeric cells RENDER — never the stored raw, the evaluated
// value, or the exported bytes (CSV keeps writing raw values, so a round
// trip loses no precision). Text, empty and error cells render the same
// under every format. The state blob v2 serializes the non-general
// columns.
package main

import "strconv"

// colFmt is a column's display format; the values double as the state
// blob's on-disk codes, so the order is ABI — never renumber.
type colFmt byte

const (
	fmtGeneral colFmt = iota // the 'g' rendering every sheet always had
	fmtInt                   // rounded integer
	fmtFixed2                // two decimals
	fmtPct                   // value x100 with a '%' suffix
)

// fmtName is the marker/menu spelling of a format.
func fmtName(f colFmt) string {
	switch f {
	case fmtInt:
		return "integer"
	case fmtFixed2:
		return "fixed2"
	case fmtPct:
		return "percent"
	}
	return "general"
}

// displayFmt renders one evaluated value under a column format.
// Non-numeric cells (text, empty) and errors ignore the format.
func displayFmt(v value, f colFmt) string {
	if v.err != errNone {
		return v.err.String()
	}
	if v.kind != vNum {
		return display(v)
	}
	switch f {
	case fmtInt:
		return strconv.FormatFloat(v.num, 'f', 0, 64)
	case fmtFixed2:
		return strconv.FormatFloat(v.num, 'f', 2, 64)
	case fmtPct:
		return strconv.FormatFloat(v.num*100, 'g', -1, 64) + "%"
	}
	return display(v)
}

// show is display() through the cell's column format — what the grid and
// the status line paint. The raw display() stays the export/recalc
// vocabulary: the format never reaches either.
func (s *Sheet) show(r cellRef) string {
	c := s.cells[r]
	if c == nil {
		return ""
	}
	return displayFmt(c.val, s.cfmt[r.col])
}

// fmtCount reports how many columns carry a non-general format — the
// state marker's fmts= field.
func (s *Sheet) fmtCount() int {
	n := 0
	for _, f := range s.cfmt {
		if f != fmtGeneral {
			n++
		}
	}
	return n
}
