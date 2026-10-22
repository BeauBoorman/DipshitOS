package main

// brackets.go — M138b (#2776): bracket matching for ()[]{}. The caret's
// bracket highlights its match and Ctrl-B jumps to it; on a .go buffer the
// scan skips string, rune-literal and comment spans, so a bracket inside
// `"{("` never counts. Everything here is a pure function over the buffer
// — the host tests pin the tables the live gate drives, same as buffer.go.

import "virelai/vi"

// The classifyGo per-byte classes.
const (
	clsCode = byte(0)
	clsStr  = byte(1)
	clsCmt  = byte(2)
)

// classifyGo marks each byte of a Go source buffer: code, string/rune
// literal, or comment. One pass over Go's quoted spans: "…" and '…' with
// \ escapes, `…` raw (no escapes), //… to the newline, and /*…*/ — Go
// block comments do not nest. Unterminated spans stop at the newline (or
// EOF) so a stray quote cannot swallow the rest of the buffer: the bytes
// after it classify as code again, which is the refusal-shaped answer for
// a file the parser would reject anyway.
func classifyGo(buf []byte) []byte {
	cls := make([]byte, len(buf))
	i := 0
	mark := func(to int, c byte) {
		for ; i < to; i++ {
			cls[i] = c
		}
	}
	for i < len(buf) {
		switch buf[i] {
		case '/':
			if i+1 < len(buf) && buf[i+1] == '/' {
				end := i + 2
				for end < len(buf) && buf[end] != '\n' {
					end++
				}
				mark(end, clsCmt)
				continue
			}
			if i+1 < len(buf) && buf[i+1] == '*' {
				end := i + 2
				for end+1 < len(buf) && !(buf[end] == '*' && buf[end+1] == '/') {
					end++
				}
				if end+1 < len(buf) {
					end += 2 // the closing */
				} else {
					end = len(buf)
				}
				mark(end, clsCmt)
				continue
			}
			i++
		case '"', '\'':
			q := buf[i]
			end := i + 1
			for end < len(buf) && buf[end] != q && buf[end] != '\n' {
				if buf[end] == '\\' {
					end++
				}
				end++
			}
			if end < len(buf) && buf[end] == q {
				end++
			}
			mark(end, clsStr)
		case '`':
			end := i + 1
			for end < len(buf) && buf[end] != '`' {
				end++
			}
			if end < len(buf) {
				end++
			}
			mark(end, clsStr)
		default:
			i++
		}
	}
	return cls
}

// bracketPair resolves one bracket byte to its (open, close) pair and the
// direction of the match scan: an opener scans forward, a closer backward.
// A non-bracket reports close == 0.
func bracketPair(c byte) (open, close byte, fwd bool) {
	switch c {
	case '(':
		return '(', ')', true
	case '[':
		return '[', ']', true
	case '{':
		return '{', '}', true
	case ')':
		return '(', ')', false
	case ']':
		return '[', ']', false
	case '}':
		return '{', '}', false
	}
	return 0, 0, false
}

// isBracket reports whether c is one of the six bracket bytes.
func isBracket(c byte) bool {
	_, cl, _ := bracketPair(c)
	return cl != 0
}

// matchBracket finds buf[cur]'s bracket match. Same-kind pairs count the
// nesting depth (the Emacs/vim % rule — a different kind neither opens nor
// closes this scan, so `([)]`-shaped noise still answers the way those
// editors answer it). With goFile set, string, rune-literal and comment
// spans are skipped and a caret bracket inside one is not a bracket at
// all. Returns the match's byte offset.
func matchBracket(buf []byte, cur int, goFile bool) (int, bool) {
	if cur < 0 || cur >= len(buf) {
		return 0, false
	}
	open, close, fwd := bracketPair(buf[cur])
	if close == 0 {
		return 0, false
	}
	var cls []byte
	if goFile {
		cls = classifyGo(buf)
		if cls[cur] != clsCode {
			return 0, false
		}
	}
	code := func(i int) bool { return cls == nil || cls[i] == clsCode }
	if fwd {
		depth := 1
		for i := cur + 1; i < len(buf); i++ {
			if !code(i) {
				continue
			}
			switch buf[i] {
			case open:
				depth++
			case close:
				if depth--; depth == 0 {
					return i, true
				}
			}
		}
		return 0, false
	}
	depth := 1
	for i := cur - 1; i >= 0; i-- {
		if !code(i) {
			continue
		}
		switch buf[i] {
		case close:
			depth++
		case open:
			if depth--; depth == 0 {
				return i, true
			}
		}
	}
	return 0, false
}

// matchCell is draw()'s half of the feature: the buffer offset to paint
// under, or no match when the caret is not on a bracket. It exists apart
// from jumpMatch so the highlight costs one scan per paint and only while
// the caret sits on a bracket byte.
func (e *editor) matchCell() (int, bool) {
	if e.mode != modeEdit {
		return 0, false
	}
	e.clampCaret()
	if e.cur >= len(e.buf) || !isBracket(e.buf[e.cur]) {
		return 0, false
	}
	return matchBracket(e.buf, e.cur, isGoPath(e.path))
}

// jumpMatch is Ctrl-B: land the caret on the match of the bracket under
// it. A caret not on a bracket — or on one with no match — is the `none`
// refusal, named like the diagnostics list's.
func (e *editor) jumpMatch() bool {
	e.clampCaret()
	m, ok := matchBracket(e.buf, e.cur, isGoPath(e.path))
	if !ok {
		vi.ConsoleLine(markerMatch + "none")
		return true
	}
	e.moveCaret(m, false, "match")
	vi.ConsoleLine(markerMatch + "jump off=" + vi.Itoa64(int64(m)))
	return true
}
