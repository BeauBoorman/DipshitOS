// M152a (#2915): the fill engine behind Edit ▸ Fill down / Fill right /
// Fill series. Fill down copies each selected column's top cell into the
// rows beneath it inside the selection; fill right mirrors that across
// rows. Fill series picks the selection's dominant axis (taller, or
// square, means down) and continues an arithmetic progression per line
// when the line's first two cells are numbers — anything else degrades
// to the same copy the directional fills do.
//
// A formula cell fills through shiftRaw: relative references move with
// the copy, anchored axes hold, and a reference shifted off the grid
// becomes #REF. A literal (number, text, or empty — a fill from an empty
// seed clears) copies verbatim. The writes stay inside the selection,
// which is always inside the grid; the store cap counts clipped, never
// half-written past it.
package main

import "strconv"

// fillKind names the three menu items.
type fillKind int

const (
	fillDown fillKind = iota
	fillRight
	fillSeries
)

func (k fillKind) String() string {
	switch k {
	case fillDown:
		return "down"
	case fillRight:
		return "right"
	}
	return "series"
}

// numAt answers the cell's evaluated number when it has one — a literal
// number or a formula that evaluated numeric. Empty, text and error
// cells are not series seeds.
func (s *Sheet) numAt(r cellRef) (float64, bool) {
	c := s.cells[r]
	if c == nil || c.val.err != errNone || c.val.kind != vNum {
		return 0, false
	}
	return c.val.num, true
}

// fillRange applies the fill inside the closed selection lo..hi and
// reports the cells it wrote plus the writes the store cap clipped. The
// caller snapshots the selection's old raws first (the undo record) and
// re-evaluates once after (the batch-recalc discipline).
func fillRange(s *Sheet, lo, hi cellRef, kind fillKind) (written []cellRef, clipped int) {
	vertical := kind != fillRight
	if kind == fillSeries {
		// The dominant axis carries the series; a square block fills
		// down, matching the column habit the card's leg exercises.
		vertical = hi.row-lo.row >= hi.col-lo.col
	}
	if vertical {
		for c := lo.col; c <= hi.col; c++ {
			w, cl := fillLine(s, true, c, lo.row, hi.row, kind)
			written = append(written, w...)
			clipped += cl
		}
		return written, clipped
	}
	for r := lo.row; r <= hi.row; r++ {
		w, cl := fillLine(s, false, r, lo.col, hi.col, kind)
		written = append(written, w...)
		clipped += cl
	}
	return written, clipped
}

// fillLine fills one column (down) or row (right) of the selection.
// n0..n1 index the line inside the selection: cell (fixed, n0) is the
// seed. A series writes from n0+2 continuing the first two cells' step;
// a copy (and a series that found no numeric pair) writes from n0+1 with
// the seed's raw shifted per target.
func fillLine(s *Sheet, down bool, fixed, n0, n1 int, kind fillKind) ([]cellRef, int) {
	if n1-n0 < 1 {
		return nil, 0
	}
	at := func(n int) cellRef {
		if down {
			return refAt(fixed, n)
		}
		return refAt(n, fixed)
	}
	delta := func(n int) (dc, dr int) {
		if down {
			return 0, n - n0
		}
		return n - n0, 0
	}
	if kind == fillSeries {
		v0, ok0 := s.numAt(at(n0))
		v1, ok1 := s.numAt(at(n0 + 1))
		if ok0 && ok1 {
			step := v1 - v0
			var out []cellRef
			clipped := 0
			for n := n0 + 2; n <= n1; n++ {
				raw := strconv.FormatFloat(v0+step*float64(n-n0), 'g', -1, 64)
				if !s.setQuiet(at(n), raw) {
					clipped++
					continue
				}
				out = append(out, at(n))
			}
			return out, clipped
		}
		// No numeric pair: a series degrades to the copy.
	}
	base := s.raw(at(n0))
	var out []cellRef
	clipped := 0
	for n := n0 + 1; n <= n1; n++ {
		dc, dr := delta(n)
		if !s.setQuiet(at(n), shiftRaw(base, dc, dr)) {
			clipped++
			continue
		}
		out = append(out, at(n))
	}
	return out, clipped
}
