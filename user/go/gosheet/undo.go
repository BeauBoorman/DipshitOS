// M152a (#2915): the undo ring — 32 steps of cell-diff records, answered
// through the seat's ctrl+z route (tabapp's HandleUndo hook). Every
// mutating gesture — an edit-line commit, a delete, a paste, a fill, a
// column format, a CSV import — is ONE step: the prior raw of each cell
// it touched and the prior format of each column it reformatted. Undo
// replays the priors back through setQuiet and re-evaluates once, so
// dependents recompute exactly as they did on the way in.
//
// There is no redo: the seat exposes no redo chord and the card lists it
// out of scope.
package main

import "virelai/vi"

// undoDepth is the ring's bound — the card's 32 steps. The oldest step
// drops when a 33rd lands.
const undoDepth = 32

// cellDiff is one cell's pre-gesture raw ("" when the cell was empty).
// Replaying a step writes each raw back; an empty raw is the delete.
type cellDiff struct {
	r   cellRef
	raw string
}

// fmtDiff is one column's pre-gesture format.
type fmtDiff struct {
	col int
	fmt colFmt
}

// undoStep is one reversible gesture. Either half may be empty; a step
// with both empty is never pushed (a no-op gesture records nothing).
type undoStep struct {
	cells []cellDiff
	fmts  []fmtDiff
}

// undoRing is the bounded stack. steps is kept as a slice rather than a
// fixed array — the diff payloads already live on the heap, and the
// depth check is the only bound the card names.
type undoRing struct {
	steps []undoStep
}

func (u *undoRing) depth() int { return len(u.steps) }

func (u *undoRing) push(s undoStep) {
	if len(s.cells) == 0 && len(s.fmts) == 0 {
		return
	}
	if len(u.steps) == undoDepth {
		copy(u.steps, u.steps[1:])
		u.steps = u.steps[:undoDepth-1]
	}
	u.steps = append(u.steps, s)
}

func (u *undoRing) pop() (undoStep, bool) {
	n := len(u.steps)
	if n == 0 {
		return undoStep{}, false
	}
	s := u.steps[n-1]
	u.steps = u.steps[:n-1]
	return s, true
}

// commitUndo folds a just-applied gesture into the ring: before holds
// the pre-gesture raws of every touched cell, fbefore the pre-gesture
// formats of every touched column. Cells and columns the gesture left
// unchanged (a refused write, a same-format apply) drop out, and a fully
// unchanged gesture records no step.
func (a *app) commitUndo(before []cellDiff, fbefore []fmtDiff) {
	var cells []cellDiff
	for _, d := range before {
		if a.sheet.raw(d.r) != d.raw {
			cells = append(cells, d)
		}
	}
	var fmts []fmtDiff
	for _, d := range fbefore {
		if a.sheet.cfmt[d.col] != d.fmt {
			fmts = append(fmts, d)
		}
	}
	a.ring.push(undoStep{cells: cells, fmts: fmts})
}

// undo pops the newest step and replays it: empty raws first (a capped
// store must have the slot free before a restore needs it), then the
// non-empty raws, then the column formats, then one recalc. The marker
// names what came back; cells restored inside the step's own span are
// not re-announced as recalcs.
func (a *app) undo() bool {
	step, ok := a.ring.pop()
	if !ok {
		vi.ConsoleLine(markerUndo + "empty")
		return false
	}
	for _, d := range step.cells {
		if d.raw == "" {
			a.sheet.setQuiet(d.r, "")
		}
	}
	for _, d := range step.cells {
		if d.raw != "" {
			a.sheet.setQuiet(d.r, d.raw)
		}
	}
	for _, d := range step.fmts {
		a.sheet.cfmt[d.col] = d.fmt
	}
	changed := a.sheet.recalc()
	vi.ConsoleLine(markerUndo + "cells=" + itoaDec(len(step.cells)) +
		" fmts=" + itoaDec(len(step.fmts)))
	// The reverted cells announce like a batch edit (clear/set lines,
	// capped); dependents outside the step's span report as recalcs.
	lo, hi, span := cellRef{}, cellRef{}, false
	for _, d := range step.cells {
		if !span {
			lo, hi, span = d.r, d.r, true
			continue
		}
		lo.col, lo.row = min(lo.col, d.r.col), min(lo.row, d.r.row)
		hi.col, hi.row = max(hi.col, d.r.col), max(hi.row, d.r.row)
	}
	shown, extra := 0, 0
	for _, d := range step.cells {
		if shown >= recalcShow {
			extra++
			continue
		}
		if d.raw == "" {
			vi.ConsoleLine(markerClear + d.r.String())
		} else {
			vi.ConsoleLine(markerSet + d.r.String() + " := '" + d.raw +
				"' -> " + a.sheet.display(d.r))
		}
		shown++
	}
	if extra > 0 {
		vi.ConsoleLine(markerSet + "+" + itoaDec(extra) + " more")
	}
	if span {
		a.reportOutside(changed, lo, hi)
	}
	a.syncBar()
	return true
}
