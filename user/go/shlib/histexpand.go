// histexpand.go — M98c (issue #2129): interactive history expansion.
//
// expandHistory is a pure function over the line about to be submitted and
// the history ring (oldest first, the numbering `history` prints). It runs
// inside the Editor's Enter arm, so only typed lines expand — startup
// lines, `source` and `-c` never see it, and both front-ends inherit it.
//
// Supported forms (bash muscle memory, nothing more):
//
//	!!        the last line
//	!N        entry N, absolute, counted 1..n over the ring
//	!-N       the entry N back from the end
//	!PREFIX   the newest line that starts with PREFIX (up to the next
//	          space or end of line)
//	^OLD^NEW  replaces the first OLD in the last line; only at the start
//	          of the line, the trailing ^ is optional
//
// A `!` stays literal inside quotes, after a backslash (consumed), when
// followed by space/tab/`=`/`(`/end-of-line, and as a lone `!` word —
// keeping `[ ! -e X ]`, `test a != b`, `echo hi!` working unchanged.
//
// The error string is the whole `gosh: …` message the front-end prints;
// callers emit no submit and no push on error (bash's histreedit shape).
package shlib

import "strings"

// expandHistory expands the !/^ forms in line against the ring. changed is
// true when any expansion ran (the caller echoes the expanded line); err is
// non-nil when a form named nothing, in which case nothing was typed back.
func expandHistory(line string, entries []string) (out string, changed bool, err error) {
	if line == "" {
		return line, false, nil
	}
	if line[0] == '^' {
		if o, c, e := expandCaret(line, entries); e != nil || c {
			return o, c, e
		}
		// A lone ^ or ^x with no second caret is a literal line — fall
		// through to the ! scan (a `!` later in it still expands).
	}
	return expandBang(line, entries)
}

// expandCaret handles a leading `^OLD^NEW[^]`: OLD is up to the next caret,
// NEW to the optional trailing caret or whitespace, and the rest of the
// line appends (bash's `^x^y tail` runs the substituted line + ` tail`).
// It reports the literal fall-through only when there is no second caret,
// so `^x` alone stays a literal line.
func expandCaret(line string, entries []string) (string, bool, error) {
	j := strings.IndexByte(line[1:], '^')
	if j < 0 {
		return line, false, nil
	}
	old := line[1 : 1+j]
	rest := line[1+j+1:]
	k := strings.IndexAny(rest, "^ \t")
	var newv string
	var consumed int
	switch {
	case k < 0:
		newv, consumed = rest, len(line)
	case rest[k] == '^':
		newv, consumed = rest[:k], 1+j+1+k+1
	default: // space/tab ends NEW; the rest appends to the line
		newv, consumed = rest[:k], 1+j+1+k
	}
	fail := func() (string, bool, error) {
		return "", false, errHist("gosh: " + line[:consumed] + ": substitution failed")
	}
	if len(entries) == 0 || old == "" {
		return fail()
	}
	last := entries[len(entries)-1]
	at := strings.Index(last, old)
	if at < 0 {
		return fail()
	}
	out := last[:at] + newv + last[at+len(old):] + line[consumed:]
	if len(out) > maxLineBytes {
		return "", false, errHist("gosh: history expansion exceeds 2048 bytes")
	}
	return out, true, nil
}

// expandBang scans the line once, tracking quotes and backslashes, and
// expands each `!` event designator that is not in a literal position.
func expandBang(line string, entries []string) (string, bool, error) {
	var b strings.Builder
	b.Grow(len(line))
	changed := false
	inS, inD := false, false
	for i := 0; i < len(line); {
		switch ch := line[i]; {
		case inS:
			b.WriteByte(ch)
			inS = ch != '\''
			i++
		case inD:
			b.WriteByte(ch)
			inD = ch != '"'
			i++
		case ch == '\'':
			inS = true
			b.WriteByte(ch)
			i++
		case ch == '"':
			inD = true
			b.WriteByte(ch)
			i++
		case ch == '\\':
			// `\!` is a literal `!` with the backslash consumed; every
			// other escaped byte passes through untouched so `\n` keeps
			// meaning backslash-n to the parser.
			if i+1 < len(line) && line[i+1] == '!' {
				b.WriteByte('!')
			} else {
				b.WriteByte(ch)
				if i+1 < len(line) {
					b.WriteByte(line[i+1])
				}
			}
			i += 2
		case ch == '!':
			tok, n := bangToken(line[i+1:])
			if n == 0 {
				b.WriteByte('!') // literal: space/tab/=/(/EOL after it
				i++
				continue
			}
			hit, err := bangLookup(tok, entries)
			if err != nil {
				return "", false, errHist("gosh: !" + tok + ": event not found")
			}
			b.WriteString(hit)
			changed = true
			i += 1 + n
		default:
			b.WriteByte(ch)
			i++
		}
	}
	out := b.String()
	if changed && len(out) > maxLineBytes {
		return "", false, errHist("gosh: history expansion exceeds 2048 bytes")
	}
	return out, changed, nil
}

// bangToken reads the event designator after `!` and answers how many bytes
// it occupies: `!`, digits, `-`digits, or a prefix run to the next space or
// end of line. n=0 means the `!` is literal (space, tab, `=`, `(`, or
// end-of-line next).
func bangToken(rest string) (tok string, n int) {
	if rest == "" {
		return "", 0
	}
	switch rest[0] {
	case ' ', '\t', '=', '(':
		return "", 0
	case '!':
		return "!", 1
	case '-':
		n = 1
		for n < len(rest) && rest[n] >= '0' && rest[n] <= '9' {
			n++
		}
		if n > 1 {
			return rest[:n], n // !-N
		}
		// `!-x`: the dash joins the prefix run below.
	}
	n = 0
	for n < len(rest) && rest[n] != ' ' {
		n++
	}
	return rest[:n], n
}

// bangLookup resolves a designator to a ring entry: `!` is the last line,
// digits an absolute 1-based entry, `-`+digits relative from the end, and
// anything else the newest line with that prefix.
func bangLookup(tok string, entries []string) (string, error) {
	last := func() (string, error) {
		if len(entries) == 0 {
			return "", errHist("empty")
		}
		return entries[len(entries)-1], nil
	}
	if tok == "!" {
		return last()
	}
	if tok[0] == '-' && len(tok) > 1 && allDigits(tok[1:]) {
		n, ok := parseInt(tok[1:])
		if ok && n >= 1 && n <= len(entries) {
			return entries[len(entries)-n], nil
		}
		return "", errHist("range")
	}
	if allDigits(tok) {
		n, ok := parseInt(tok)
		if ok && n >= 1 && n <= len(entries) {
			return entries[n-1], nil
		}
		return "", errHist("range")
	}
	for i := len(entries) - 1; i >= 0; i-- {
		if strings.HasPrefix(entries[i], tok) {
			return entries[i], nil
		}
	}
	return "", errHist("nomatch")
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// errHist is the error form expandHistory returns — the whole user-facing
// message, so the editor can print it verbatim.
type histErr string

func (e histErr) Error() string { return string(e) }
func errHist(s string) error    { return histErr(s) }
