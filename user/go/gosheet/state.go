// M142b (#2790): the save_state blob — sheet, cursor and scroll in one
// versioned envelope. The files/session.go contract: the app owns the
// format, the seat stores the bytes verbatim, the decode is total and
// refuses wholesale. Layout (little-endian):
//
//	u8  ver                       — stateFmtVer, also Config.StateVersion
//	u8  col | u8 row              — the grid cursor
//	u16 scrollTop | u16 scrollX   — the table's vertical row + horizontal px scroll
//	u16 ncells                    — then ncells runs of:
//	  u8 col | u8 row | u16 len | len raw bytes   (raw is the literal or
//	  '=formula' text; values are never serialized — recalc regenerates them)
//	u8  nfmts                     — v2 only: then nfmts runs of
//	  u8 col | u8 fmt             — the non-general column formats (M152a)
//
// M152a (#2915) bumps the envelope to v2: the format trailer appends to
// the v1 layout untouched, and the decoder still accepts v1 blobs — a
// session serialized before this card lands restores cells and view with
// every column general.
package main

import (
	"virelai/vi"
)

const (
	stateFmtVer = 2
	stateVer1   = 1 // the M142b envelope — still decodable
)

// sheetState is the decoded save payload: populated raws, the view, and
// the column formats (all-general when the blob predates v2).
type sheetState struct {
	raws map[cellRef]string
	cur  cellRef
	top  int
	sx   int
	fmts [NumCols]colFmt
}

// encodeState serializes the sheet + view. The seat's 64KiB bound is the
// ceiling: a sheet that would not fit refuses whole (SaveState answers
// "no state") rather than truncating a cell mid-raw.
func (a *app) encodeState() []byte {
	refs := a.sheet.sortedRefs()
	out := make([]byte, 0, 64+len(refs)*8)
	out = append(out, stateFmtVer, byte(a.table.Col), byte(a.table.Row))
	out = putU16(out, uint16(a.table.ScrollTop))
	out = putU16(out, uint16(a.table.ScrollX))
	out = putU16(out, uint16(len(refs)))
	for _, r := range refs {
		raw := a.sheet.raw(r)
		if len(out)+4+len(raw) > vi.AppStateMax {
			return nil
		}
		out = append(out, byte(r.col), byte(r.row))
		out = putU16(out, uint16(len(raw)))
		out = append(out, raw...)
	}
	// v2 trailer: the non-general column formats, column order.
	n := 0
	for _, f := range a.sheet.cfmt {
		if f != fmtGeneral {
			n++
		}
	}
	if len(out)+1+2*n > vi.AppStateMax {
		return nil
	}
	out = append(out, byte(n))
	for c, f := range a.sheet.cfmt {
		if f != fmtGeneral {
			out = append(out, byte(c), byte(f))
		}
	}
	return out
}

// decodeState refuses stale/short/trailing/duplicate or out-of-bounds
// state wholesale — a corrupt blob never half-loads a sheet. v1 blobs
// end after the cell runs; v2 adds the format trailer.
func decodeState(b []byte) (*sheetState, bool) {
	if len(b) < 9 || (b[0] != stateVer1 && b[0] != stateFmtVer) {
		return nil, false
	}
	ver := b[0]
	st := &sheetState{
		raws: map[cellRef]string{},
		cur:  refAt(int(b[1]), int(b[2])),
		top:  int(getU16(b[3:])),
		sx:   int(getU16(b[5:])),
	}
	n := int(getU16(b[7:]))
	o := 9
	for i := 0; i < n; i++ {
		if len(b)-o < 4 {
			return nil, false
		}
		r := refAt(int(b[o]), int(b[o+1]))
		ln := int(getU16(b[o+2:]))
		o += 4
		if !r.inBounds() || ln == 0 || len(b)-o < ln {
			return nil, false
		}
		if _, dup := st.raws[r]; dup {
			return nil, false
		}
		st.raws[r] = string(b[o : o+ln])
		o += ln
	}
	if ver == stateFmtVer {
		if len(b)-o < 1 {
			return nil, false
		}
		nf := int(b[o])
		o++
		var seen [NumCols]bool
		for i := 0; i < nf; i++ {
			if len(b)-o < 2 {
				return nil, false
			}
			c, f := int(b[o]), colFmt(b[o+1])
			o += 2
			if c >= NumCols || f > fmtPct || seen[c] {
				return nil, false
			}
			seen[c] = true
			st.fmts[c] = f
		}
	}
	if o != len(b) || len(st.raws) > MaxCells || !st.cur.inBounds() {
		return nil, false
	}
	return st, true
}

// noteState is Config.RestoreState: it decodes into a pending slot inside
// tabapp.Init so a bad blob is a marker, not a half-built grid; the sheet
// applies after the table exists.
func (a *app) noteState(b []byte) {
	st, ok := decodeState(b)
	if !ok {
		a.pendBad = true
		return
	}
	a.pend = st
}

// applyRestored applies a pending blob — raw cells via the quiet fill path,
// one recalc, then cursor + scroll restored (FocusCell clamps in bounds).
func (a *app) applyRestored() {
	if a.pendBad {
		vi.ConsoleLine(markerState + "stale")
		a.pendBad = false
		return
	}
	if a.pend == nil {
		return
	}
	st := a.pend
	a.pend = nil
	for r, raw := range st.raws {
		a.sheet.setQuiet(r, raw)
	}
	a.sheet.cfmt = st.fmts
	a.sheet.recalc()
	a.ctl.FocusCell(st.cur.row, st.cur.col)
	a.table.ScrollTop = st.top
	a.table.ScrollTop = a.table.ClampTop()
	a.table.ScrollX = st.sx
	a.table.ScrollX = a.table.ClampX()
	vi.ConsoleLine(markerState + "restored cells=" +
		vi.Itoa64(int64(a.sheet.filled())) + " sel=" + a.sel().String() +
		" top=" + vi.Itoa64(int64(a.table.ScrollTop)) +
		" sx=" + vi.Itoa64(int64(a.table.ScrollX)) +
		" fmts=" + vi.Itoa64(int64(a.sheet.fmtCount())))
	a.syncBar()
}

// saveState is Config.SaveState: it emits the marker the seat's ask lands
// on, and refuses oversize blobs whole.
func (a *app) saveState() []byte {
	b := a.encodeState()
	if b == nil {
		vi.ConsoleLine(markerState + "oversize")
		return nil
	}
	vi.ConsoleLine(markerState + "saved n=" + vi.Itoa64(int64(len(b))))
	return b
}

func putU16(b []byte, v uint16) []byte {
	return append(b, byte(v), byte(v>>8))
}

func getU16(b []byte) uint16 {
	return uint16(b[0]) | uint16(b[1])<<8
}
