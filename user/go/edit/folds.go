package main

// folds.go — M166b (#2987): brace folding. A fold is the byte offset of an
// opening `{` whose matching `}` sits on a later line; the lines strictly
// between them are hidden and the opening line paints a `{...}` tail in
// InkMuted (the 8x8 face is ASCII, so the ellipsis spells as three dots).
// `.go` buffers find their braces through classifyGo — a brace inside a
// string, rune literal or comment never folds — and other buffers use the
// raw matchBracket rule. Folds live on the doc, so they park and restore
// with the buffer the way the M166a ring already carries caret and undo.

import (
	"unicode/utf8"

	"virelai/vi"
)

// fold is one collapsed block: open is the byte offset of the `{`, close
// of its match. Both stay in buffer coordinates; shiftFolds walks them
// across every splice.
type fold struct {
	open  int
	close int
}

// bracePairs enumerates every matched {} pair in buf, ordered by open
// offset. The pairing is matchBracket's own rule — same-kind depth —
// expressed as a stack walk, and the classifyGo span filter applies exactly
// where matchBracket applies it: non-code bytes are skipped outright.
func bracePairs(buf []byte, goFile bool) []fold {
	var cls []byte
	if goFile {
		cls = classifyGo(buf)
	}
	var stack []int
	var out []fold
	for i := 0; i < len(buf); i++ {
		if cls != nil && cls[i] != clsCode {
			continue
		}
		switch buf[i] {
		case '{':
			stack = append(stack, i)
		case '}':
			if len(stack) > 0 {
				o := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				out = append(out, fold{open: o, close: i})
			}
		}
	}
	// Pairs leave the stack in close order; open order is what every walk
	// here wants, and a nested open always precedes its parent's anyway.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].open < out[j-1].open; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

// foldSpan returns a fold's hidden span [hs, he): the bytes of the lines
// strictly between the open line and the close line — from the first byte
// after the open line's newline to the close line's start. A close on the
// very next line leaves an empty span (a legal fold hiding nothing).
func (d *doc) foldSpan(f fold) (hs, he int) {
	_, oe := lineBounds(d.buf, f.open)
	cs, _ := lineBounds(d.buf, f.close)
	return oe + 1, cs
}

// foldHiding returns the index of a fold whose hidden span contains off,
// or -1. A landing on the open or close line itself is not hidden — those
// lines stay on the page.
func (d *doc) foldHiding(off int) int {
	for i, f := range d.folds {
		hs, he := d.foldSpan(f)
		if off >= hs && off < he {
			return i
		}
	}
	return -1
}

// lineHidden reports whether the line starting at off is folded away.
func (d *doc) lineHidden(off int) bool { return d.foldHiding(off) >= 0 }

// foldOnLine returns the fold whose opening brace sits inside [start, end)
// — the line bounds — or -1. draw() asks it per row for the `{...}` tail.
func (d *doc) foldOnLine(start, end int) int {
	for i, f := range d.folds {
		if f.open >= start && f.open < end {
			return i
		}
	}
	return -1
}

// foldHiddenLines counts the lines a fold hides — the newline-terminated
// lines inside its hidden span.
func (d *doc) foldHiddenLines(f fold) int {
	hs, he := d.foldSpan(f)
	n := 0
	for i := hs; i < he; i++ {
		if d.buf[i] == '\n' {
			n++
		}
	}
	return n
}

// foldTarget is Ctrl-K's target: the innermost multi-line {} block that
// encloses the caret or opens on the caret's line. Innermost is the
// largest open offset — a nested block's `{` always sits inside its
// parent's span, so the deepest candidate wins outright.
func (d *doc) foldTarget(cur int) (fold, bool) {
	pairs := bracePairs(d.buf, isGoPath(d.path))
	var best fold
	found := false
	for _, p := range pairs {
		os, oe := lineBounds(d.buf, p.open)
		cs, _ := lineBounds(d.buf, p.close)
		if cs <= oe {
			continue // same line: nothing to hide
		}
		if !(cur >= os && cur <= oe) && !(cur > p.open && cur <= p.close) {
			continue // neither opens on the caret's line nor encloses it
		}
		if !found || p.open > best.open {
			best, found = p, true
		}
	}
	return best, found
}

// toggleFold is Ctrl-K: fold the target block — or, when the target is
// already the open offset of a live fold, unfold it. Folding a block whose
// hidden span holds the caret moves the caret to the `{` itself, the one
// spot that can never fold away. `fold none` is the no-block refusal.
func (e *editor) toggleFold() bool {
	e.clampCaret()
	e.hist.breakRun()
	t, ok := e.foldTarget(e.cur)
	if !ok {
		vi.ConsoleLine(markerFold + "none")
		return true
	}
	for i, f := range e.folds {
		if f.open == t.open && f.close == t.close {
			e.folds = append(e.folds[:i], e.folds[i+1:]...)
			l, _ := caretLineCol(e.buf, t.open)
			vi.ConsoleLine(markerFold + "off line=" + vi.Itoa64(int64(l)))
			return true
		}
	}
	ins := len(e.folds)
	for ins > 0 && e.folds[ins-1].open > t.open {
		ins--
	}
	e.folds = append(e.folds, fold{})
	copy(e.folds[ins+1:], e.folds[ins:])
	e.folds[ins] = t
	l, _ := caretLineCol(e.buf, t.open)
	vi.ConsoleLine(markerFold + "on line=" + vi.Itoa64(int64(l)) +
		" hidden=" + vi.Itoa64(int64(e.foldHiddenLines(t))))
	if e.foldHiding(e.cur) >= 0 {
		e.cur = t.open
		e.selSet, e.markOn = false, false
	}
	return true
}

// clearFolds is Ctrl-U: unfold everything. The receipt always prints —
// `n=0` is a real answer, not a refusal.
func (e *editor) clearFolds() bool {
	n := len(e.folds)
	e.folds = e.folds[:0]
	vi.ConsoleLine(markerFold + "clear n=" + vi.Itoa64(int64(n)))
	return true
}

// unfoldAt drops every fold whose hidden span contains off — the
// caret-never-hidden rule for the landing paths (goto, find, replace,
// bracket and diagnostics jumps, minimap, undo/redo, plain moves). One
// `fold off` line per dropped fold, reason naming the landing that did it.
func (d *doc) unfoldAt(off int, reason string) {
	keep := d.folds[:0]
	for _, f := range d.folds {
		hs, he := d.foldSpan(f)
		if off >= hs && off < he {
			l, _ := caretLineCol(d.buf, f.open)
			vi.ConsoleLine(markerFold + "off line=" + vi.Itoa64(int64(l)) +
				" reason=" + reason)
			continue
		}
		keep = append(keep, f)
	}
	d.folds = keep
}

// shiftFolds retargets fold offsets across one op's splices — the same
// coordinate walk applySplices does — then re-validates each fold against
// the buffer the splices produced: a fold whose opening brace or match is
// gone, or that no longer spans two lines, is dropped.
func (d *doc) shiftFolds(sp []splice, undo bool) {
	if len(d.folds) == 0 {
		return
	}
	for k := range d.folds {
		f := &d.folds[k]
		shift := 0
		for _, s := range sp {
			pos := s.pos + shift
			shift += len(s.ins) - len(s.old)
			cut, ins := len(s.old), len(s.ins)
			if undo {
				cut, ins = len(s.ins), len(s.old)
			}
			delta := ins - cut
			if f.open >= pos+cut {
				f.open += delta
			}
			if f.close >= pos+cut {
				f.close += delta
			}
		}
	}
	keep := d.folds[:0]
	gof := isGoPath(d.path)
	for _, f := range d.folds {
		if f.open >= len(d.buf) || f.close >= len(d.buf) ||
			d.buf[f.open] != '{' || d.buf[f.close] != '}' {
			continue
		}
		if m, ok := matchBracket(d.buf, f.open, gof); !ok || m != f.close {
			continue
		}
		_, oe := lineBounds(d.buf, f.open)
		cs, _ := lineBounds(d.buf, f.close)
		if cs <= oe {
			continue
		}
		keep = append(keep, f)
	}
	d.folds = keep
}

// moveLineVis is moveLine over visible lines: a folded block steps as one
// line, so Up/Down crossing it lands on the close line (down) or the open
// line (up) — the caret never enters hidden text.
func (d *doc) moveLineVis(cur, n int) int {
	if len(d.folds) == 0 {
		return moveLine(d.buf, cur, n)
	}
	buf := d.buf
	start, end := lineBounds(buf, cur)
	col := utf8.RuneCount(buf[start:cur])
	for n < 0 && start > 0 {
		ps, pe := lineBounds(buf, start-1)
		for {
			if i := d.foldHiding(ps); i >= 0 {
				hs, _ := d.foldSpan(d.folds[i])
				ps, pe = lineBounds(buf, hs-1)
				continue
			}
			break
		}
		start, end, n = ps, pe, n+1
	}
	for n > 0 && end < len(buf) {
		ns, ne := lineBounds(buf, end+1)
		for {
			if i := d.foldHiding(ns); i >= 0 {
				_, he := d.foldSpan(d.folds[i])
				ns, ne = lineBounds(buf, he)
				continue
			}
			break
		}
		start, end, n = ns, ne, n-1
	}
	t := start
	for c := 0; c < col && t < end; c++ {
		_, size := utf8.DecodeRune(buf[t:end])
		t += size
	}
	return t
}
