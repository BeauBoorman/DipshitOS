package main

// buffer.go — the pure edit-buffer layer for GOEDIT's second pass (#2199):
// splices, the bounded op history with the merged-typing model, the caret's
// movement rules, and the replace-all transform. Nothing here knows about
// events, the window or the console: every function takes the document and
// returns what the edit makes of it, so the class-A tests pin the same rules
// the live gate drives.

import (
	"unicode/utf8"

	"virelai/find"
)

// splice is one atomic text replacement: at pos, the bytes `old` became the
// bytes `ins`. Positions in an op are in the coordinates of the buffer the
// op was built against — applySplices walks them forward, undo applies the
// same walk with old/ins swapped.
type splice struct {
	pos int
	old []byte
	ins []byte
}

// opKind distinguishes a mergeable RUN (typing, deleting) from one composite
// edit (paste, cut, replace). Only run ops merge, and only while open.
type opKind uint8

const (
	opInsRun opKind = iota // a merged forward-typing run
	opDelRun               // a merged delete run (either direction)
	opEdit                 // one non-mergeable composite edit
)

// editOp is one undoable operation: an ordered list of non-overlapping
// splices in original-buffer coordinates. A run op carries exactly one
// splice that keeps growing while the run is open; a composite op carries
// one splice per site (paste-over-selection is one, replace-all is N).
type editOp struct {
	kind opKind
	sp   []splice
}

// histCap bounds the undo ring in OPS. A bounded history that forgets the
// oldest op beats an unbounded one (the card's cap-the-ring rule); a run op
// already amortizes a whole typing burst into one slot.
const histCap = 128

// history is the bounded undo/redo record. open marks the top undo op as a
// live run: any caret move, clipboard op, mode change or undo/redo closes it
// (breakRun), so merging only ever joins truly consecutive keystrokes.
// M125b (#2587): dropped counts ops a full ring evicted — the serialized
// ring no longer reaches back to the buffer's base, which is exactly the
// boundary "unsaved-buffer recovery beyond the undo ring" names.
type history struct {
	undo    []editOp // oldest first; the top is undo[len-1]
	redo    []editOp // undo-most-recent last; popRedo takes the tail
	open    bool
	dropped int
}

// hasNL reports whether b contains a newline. Typed runs break at newline
// boundaries so Return commits a line instead of merging into it.
func hasNL(b []byte) bool {
	for _, c := range b {
		if c == '\n' {
			return true
		}
	}
	return false
}

// push records an edit, merging it into the open run when the merge rule
// holds, and clears the redo side — a new edit forfeits redone futures.
// A full ring drops the oldest op.
func (h *history) push(o editOp) {
	h.redo = h.redo[:0]
	if h.open && len(h.undo) > 0 && mergeOp(&h.undo[len(h.undo)-1], o) {
		return
	}
	if len(h.undo) == histCap {
		copy(h.undo, h.undo[1:])
		h.undo = h.undo[:histCap-1]
		h.dropped++
	}
	h.undo = append(h.undo, o)
	h.open = o.kind == opInsRun || o.kind == opDelRun
}

// breakRun closes the open run: the next mergeable op starts a new one.
func (h *history) breakRun() { h.open = false }

// popUndo moves the newest undo op onto the redo stack and returns it.
func (h *history) popUndo() (editOp, bool) {
	if len(h.undo) == 0 {
		return editOp{}, false
	}
	o := h.undo[len(h.undo)-1]
	h.undo = h.undo[:len(h.undo)-1]
	h.redo = append(h.redo, o)
	h.open = false
	return o, true
}

// popRedo moves the newest redo op back onto the undo stack.
func (h *history) popRedo() (editOp, bool) {
	if len(h.redo) == 0 {
		return editOp{}, false
	}
	o := h.redo[len(h.redo)-1]
	h.redo = h.redo[:len(h.redo)-1]
	h.undo = append(h.undo, o)
	h.open = false
	return o, true
}

// mergeOp folds o into the top op when both are single-splice runs of the
// same kind and the new splice is contiguous with the run. Insert runs grow
// forward (the next typed byte lands at the run's end); delete runs grow in
// whichever direction the keystrokes went — a backspace extends the region
// backward (new splice ends where the run begins), a forward-delete extends
// it from the same position. A mixed-direction run still describes one
// contiguous deleted region, so it merges too.
func mergeOp(top *editOp, o editOp) bool {
	if o.kind != top.kind || len(top.sp) != 1 || len(o.sp) != 1 {
		return false
	}
	s, n := &top.sp[0], o.sp[0]
	switch o.kind {
	case opInsRun:
		if s.pos+len(s.ins) != n.pos || hasNL(s.ins) || hasNL(n.ins) {
			return false
		}
		s.ins = append(s.ins, n.ins...)
		return true
	case opDelRun:
		if n.pos+len(n.old) == s.pos {
			s.old = append(n.old, s.old...)
			s.pos = n.pos
			return true
		}
		if n.pos == s.pos {
			s.old = append(s.old, n.old...)
			return true
		}
	}
	return false
}

// applySplices returns the buffer with the op's splices applied — or, with
// undo set, reverted (old/ins swapped). Forward walks the splices in their
// ORIGINAL coordinates; a revert walks the applied buffer, where each ins
// region sits at pos + the accumulated length delta of the splices before
// it. Sorted non-overlapping splices stay sorted under that shift, which is
// why one walk serves both directions.
func applySplices(buf []byte, sp []splice, undo bool) []byte {
	var out []byte
	pos := 0
	if !undo {
		for _, s := range sp {
			if s.pos < pos || s.pos > len(buf) {
				continue
			}
			out = append(out, buf[pos:s.pos]...)
			out = append(out, s.ins...)
			pos = s.pos + len(s.old)
		}
		return append(out, buf[pos:]...)
	}
	shift := 0
	for _, s := range sp {
		npos := s.pos + shift
		if npos < pos || npos > len(buf) {
			continue
		}
		out = append(out, buf[pos:npos]...)
		out = append(out, s.old...)
		pos = npos + len(s.ins)
		shift += len(s.ins) - len(s.old)
	}
	return append(out, buf[pos:]...)
}

// splicedLen is what applySplices produces without materializing it — the
// maxBuffer check needs the length first so an oversized edit is refused
// before the buffer moves.
func splicedLen(bufLen int, sp []splice, undo bool) int {
	n := bufLen
	for _, s := range sp {
		if undo {
			n += len(s.old) - len(s.ins)
		} else {
			n += len(s.ins) - len(s.old)
		}
	}
	return n
}

// replaceAllSplices returns one splice per non-overlapping match of pat —
// the shared matcher's scan (package virelai/find, M126c #2595), so
// len(result) IS the total find would report. Positions are
// original-buffer coordinates, which is also what keeps a replacement that
// CONTAINS the pattern terminating: no splice ever sees inserted text.
func replaceAllSplices(buf, pat, repl []byte) []splice {
	var sp []splice
	for _, pos := range find.All(buf, pat) {
		sp = append(sp, splice{
			pos: pos,
			old: append([]byte{}, buf[pos:pos+len(pat)]...),
			ins: append([]byte{}, repl...),
		})
	}
	return sp
}

// --- caret movement ------------------------------------------------------
// These are the pure rules the nav keys drive. All take the buffer and the
// byte caret and return the byte caret the key should leave.

// moveLeft steps the caret one Unicode scalar back.
func moveLeft(buf []byte, cur int) int {
	if cur <= 0 {
		return 0
	}
	if cur > len(buf) {
		cur = len(buf)
	}
	_, size := utf8.DecodeLastRune(buf[:cur])
	return cur - size
}

// moveRight steps the caret one Unicode scalar forward.
func moveRight(buf []byte, cur int) int {
	if cur >= len(buf) {
		return len(buf)
	}
	_, size := utf8.DecodeRune(buf[cur:])
	return cur + size
}

// lineBounds returns [start,end) of the line holding off: start is the byte
// after the previous newline (or 0), end the newline itself (or len).
func lineBounds(buf []byte, off int) (int, int) {
	if off < 0 {
		off = 0
	}
	if off > len(buf) {
		off = len(buf)
	}
	start := off
	for start > 0 && buf[start-1] != '\n' {
		start--
	}
	end := off
	for end < len(buf) && buf[end] != '\n' {
		end++
	}
	return start, end
}

// moveHome/moveEnd jump to the bounds of the caret's line.
func moveHome(buf []byte, cur int) int {
	start, _ := lineBounds(buf, cur)
	return start
}

func moveEnd(buf []byte, cur int) int {
	_, end := lineBounds(buf, cur)
	return end
}

// moveLine moves the caret n lines (n<0 up, n>0 down), keeping the rune
// column when the target line has one; a shorter target clamps to its end.
func moveLine(buf []byte, cur, n int) int {
	start, end := lineBounds(buf, cur)
	col := utf8.RuneCount(buf[start:cur])
	for i := 0; i < -n && start > 0; i++ {
		start, end = lineBounds(buf, start-1)
	}
	for i := 0; i < n && end < len(buf); i++ {
		start, end = lineBounds(buf, end+1)
	}
	// start..end is now the target line's bounds.
	ns := start
	for c := 0; c < col && ns < end; c++ {
		_, size := utf8.DecodeRune(buf[ns:end])
		ns += size
	}
	return ns
}

// caretLineCol reports the caret's 1-based line and rune column, the pair
// the status line prints as `line=L/T col=C`.
func caretLineCol(buf []byte, cur int) (line, col int) {
	if cur > len(buf) {
		cur = len(buf)
	}
	if cur < 0 {
		cur = 0
	}
	line, lastNL := 1, -1
	for i := 0; i < cur; i++ {
		if buf[i] == '\n' {
			line++
			lastNL = i
		}
	}
	return line, utf8.RuneCount(buf[lastNL+1:cur]) + 1
}
