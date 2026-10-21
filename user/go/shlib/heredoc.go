// Heredocs (M138a, issue #2775): `<<WORD` with the usual expansion,
// `<<'WORD'`/`<<"WORD"` literal, `<<-WORD` stripping leading tabs, several
// on one line read in declaration order, and named refusals for the forms
// this shell does not take — a here-string (`<<<`) and a body that never
// reaches its delimiter (`gosh: heredoc: unterminated <WORD>`).
//
// The shape mirrors the engine's split: scanHeredocs is the pure parser —
// a quote-aware walk of the raw line, because the tokenizer cannot see
// heredocs (`;`, `&&` and `||` are still text at this level, and `;` is
// not a word boundary for it). HeredocReader is the collector every line
// source drives — the front-end's continuation prompt, runSource's file
// lines, the startup contract. The engine then binds each collected body
// to its redirect by rewriting `<<WORD` to a marked `<` path before
// runLine sees the line: `<`+hdMark+seq is a body key, not a filename.
// The rewrite — not a body queue — is what makes a heredoc inside a
// for-body or `fn` definition find its body again on every re-run.
package shlib

import (
	"errors"
	"strings"

	"virelai/vsys"
)

// hdMark prefixes the body key the rewrite splices in as a `<` path.
// stripEscMarks removes it from any line that did not come through
// runLineBodies, so file text and typed input cannot forge a reference to
// a body that was never collected.
const hdMark = '\x02'

// hdBodyMax bounds the live body table per shell: bodies persist so a
// function or loop body re-run finds its heredoc again, and the bound is
// the refusal past a count no real session approaches.
const hdBodyMax = 64

// hdBody is one collected heredoc body bound to a marked redirect path.
type hdBody struct {
	text   string // collected lines, each newline-terminated
	expand bool   // unquoted delimiter: the body undergoes $ expansion
}

// heredocSpec is one `<<[-]WORD` site in a raw line. at..end is the byte
// range the rewrite replaces, covering `<<`, the optional `-`, and the
// delimiter word including its quotes.
type heredocSpec struct {
	delim     string
	expand    bool // the delimiter word carried no quoting
	stripTabs bool // `<<-`
	at, end   int
}

// scanHeredocs walks a raw line and reports each unquoted `<<`/`<<-`
// site, in order. Quoted `<<` is text (`echo '<<x'`), an unquoted `#` at a
// word boundary ends the scan as a comment, and `\x` hides x. Refusals:
// `<<<` names the here-string, `<<` with no word names the delimiter, and
// unbalanced quoting reports the same error the tokenizer would.
func scanHeredocs(line string) ([]heredocSpec, error) {
	var specs []heredocSpec
	var inSingle, inDouble, esc bool
	wordStart := true
	i := 0
	for i < len(line) {
		c := line[i]
		switch {
		case esc:
			esc = false
			i++
		case inSingle:
			if c == '\'' {
				inSingle = false
			}
			i++
		case inDouble:
			if c == '\\' && i+1 < len(line) &&
				(line[i+1] == '"' || line[i+1] == '\\' || line[i+1] == '$') {
				i += 2
				continue
			}
			if c == '"' {
				inDouble = false
			}
			i++
		case c == '\'' || c == '"':
			if c == '\'' {
				inSingle = true
			} else {
				inDouble = true
			}
			wordStart = false
			i++
		case c == '\\':
			if i+1 >= len(line) {
				return nil, errors.New("gosh: trailing backslash")
			}
			esc = true
			wordStart = false
			i++
		case c == '#' && wordStart:
			return specs, nil
		case c == '$' && i+2 < len(line) && line[i+1] == '(' && line[i+2] == '(':
			// `$((...))` is arithmetic, not substitution: skip its span so
			// a `<<` inside an expression is never read as a heredoc.
			j := i + 3
			nest := 0
			for ; j+1 < len(line); j++ {
				if line[j] == '(' {
					nest++
				} else if line[j] == ')' {
					if nest == 0 && line[j+1] == ')' {
						break
					}
					if nest > 0 {
						nest--
					}
				}
			}
			if j+1 < len(line) {
				i = j + 2
			} else {
				i = len(line)
			}
			wordStart = false
		case c == '<':
			wordStart = true
			if i+1 < len(line) && line[i+1] == '<' {
				if i+2 < len(line) && line[i+2] == '<' {
					return nil, errors.New("gosh: here-strings (<<<) are not supported")
				}
				j := i + 2
				strip := false
				if j < len(line) && line[j] == '-' {
					strip = true
					j++
				}
				for j < len(line) && isSpaceByte(line[j]) {
					j++
				}
				delim, quoted, end, err := scanHeredocDelim(line, j)
				if err != nil {
					return nil, err
				}
				if delim == "" {
					return nil, errors.New("gosh: << needs a delimiter word")
				}
				specs = append(specs, heredocSpec{
					delim: delim, expand: !quoted, stripTabs: strip,
					at: i, end: end,
				})
				i = end
				continue
			}
			i++
		case isSpaceByte(c) || c == ';' || c == '&' || c == '|' || c == '>':
			wordStart = true
			i++
		default:
			wordStart = false
			i++
		}
	}
	return specs, nil
}

// scanHeredocDelim reads the delimiter word starting at j: bare bytes, or
// quote segments (`'E'`, `"E"`) and `\x` escapes that mark the word quoted
// and contribute their literal bytes. `;`, `&`, `|`, `<`, `>`, `(` and `)`
// are boundaries because this walk runs before chain splitting, and a `#`
// at word start is a comment, not a delimiter.
func scanHeredocDelim(line string, j int) (delim string, quoted bool, end int, err error) {
	var b strings.Builder
	for j < len(line) {
		c := line[j]
		if isSpaceByte(c) || c == ';' || c == '&' || c == '|' || c == '<' ||
			c == '>' || c == '(' || c == ')' || (c == '#' && b.Len() == 0) {
			break
		}
		switch c {
		case '\'':
			quoted = true
			k := strings.IndexByte(line[j+1:], '\'')
			if k < 0 {
				return "", false, 0, errors.New("gosh: unterminated ' quote")
			}
			b.WriteString(line[j+1 : j+1+k])
			j += k + 2
		case '"':
			quoted = true
			j++
			closed := false
			for j < len(line) {
				d := line[j]
				if d == '"' {
					closed = true
					j++
					break
				}
				if d == '\\' && j+1 < len(line) &&
					(line[j+1] == '"' || line[j+1] == '\\' || line[j+1] == '$') {
					b.WriteByte(line[j+1])
					j += 2
					continue
				}
				b.WriteByte(d)
				j++
			}
			if !closed {
				return "", false, 0, errors.New("gosh: unterminated \" quote")
			}
		case '\\':
			if j+1 >= len(line) {
				return "", false, 0, errors.New("gosh: trailing backslash")
			}
			quoted = true
			b.WriteByte(line[j+1])
			j += 2
		default:
			b.WriteByte(c)
			j++
		}
	}
	return b.String(), quoted, j, nil
}

// ---------------------------------------------------------------------------
// Collection: one line's heredoc bodies, in declaration order.
// ---------------------------------------------------------------------------

// HeredocReader collects the body lines one declared line needs. A line
// source — the front-end's continuation prompt, runSource's file lines,
// the startup contract — feeds raw lines until Waiting reports false; the
// collected Bodies then ride RunLineBodies with the original line.
type HeredocReader struct {
	specs  []heredocSpec
	bodies [][]byte
	cur    []byte
}

// NewHeredocReader scans line for heredoc declarations; a refused form
// (`<<<`, a missing delimiter, unbalanced quoting) is the scan's error.
// A line carrying newlines is a submitted BLOCK, not one line (M154a
// #2926): it never arms — RunLineBodies runs it as a script whose own
// per-line readers collect any `<<` from the block's following lines,
// the runSource path, so the front-end's continuation prompt is never
// owed a delimiter the block already holds.
func NewHeredocReader(line string) (*HeredocReader, error) {
	if strings.IndexByte(line, '\n') >= 0 {
		return &HeredocReader{}, nil
	}
	specs, err := scanHeredocs(line)
	if err != nil {
		return nil, err
	}
	return &HeredocReader{specs: specs}, nil
}

// Waiting reports whether another body line is needed.
func (r *HeredocReader) Waiting() bool { return len(r.bodies) < len(r.specs) }

// Delim is the delimiter the current body must reach, for the caller's
// messages; "" when nothing is pending.
func (r *HeredocReader) Delim() string {
	if !r.Waiting() {
		return ""
	}
	return r.specs[len(r.bodies)].delim
}

// Feed consumes one input line: the delimiter line ends the current body,
// anything else joins it — with leading tabs stripped when the spec is
// `<<-`, which is also the only case where a tab-indented delimiter
// terminates.
func (r *HeredocReader) Feed(line string) {
	if !r.Waiting() {
		return
	}
	spec := r.specs[len(r.bodies)]
	text := line
	if spec.stripTabs {
		text = strings.TrimLeft(line, "\t")
	}
	if text == spec.delim {
		r.bodies = append(r.bodies, r.cur)
		r.cur = nil
		return
	}
	r.cur = append(r.cur, text...)
	r.cur = append(r.cur, '\n')
}

// Bodies is the collected bodies, one per declaration, in order — shorter
// than the spec count when the line source ran out mid-collection.
func (r *HeredocReader) Bodies() [][]byte { return r.bodies }

// ---------------------------------------------------------------------------
// Execution: bind collected bodies to marked redirects, expand on use.
// ---------------------------------------------------------------------------

// runLineBodies runs one logical line whose heredoc bodies were already
// collected in declaration order (HeredocReader or a direct [][]byte).
// Every `<<WORD` site is rewritten to `<`+hdMark+seq bound to its body,
// so text re-parsed later — a construct body, a function call, a loop's
// next iteration — resolves to the same collection. A declaration with no
// collected body is the named unterminated refusal.
func (s *Shell) runLineBodies(line string, bodies [][]byte, depth int) (int, Action) {
	specs, err := scanHeredocs(line)
	if err != nil {
		s.fail(err.Error())
		s.status = 1
		return 1, ActionContinue
	}
	if len(specs) == 0 {
		return s.runLine(line, depth)
	}
	for i := range specs {
		if i >= len(bodies) {
			s.fail("heredoc: unterminated <" + specs[i].delim + ">")
			s.status = 1
			return 1, ActionContinue
		}
	}
	var b strings.Builder
	b.Grow(len(line))
	pos := 0
	for i, spec := range specs {
		if len(s.hdBodies) >= hdBodyMax {
			s.fail("heredoc: too many bodies in one session (at most " +
				vsys.Itoa64(hdBodyMax) + ")")
			s.status = 1
			return 1, ActionContinue
		}
		key := string(hdMark) + "hd" + vsys.Itoa64(int64(s.hdSeq))
		s.hdSeq++
		if s.hdBodies == nil {
			s.hdBodies = map[string]hdBody{}
		}
		s.hdBodies[key] = hdBody{text: string(bodies[i]), expand: spec.expand}
		b.WriteString(line[pos:spec.at])
		b.WriteByte('<')
		b.WriteString(key)
		pos = spec.end
	}
	b.WriteString(line[pos:])
	return s.runLine(b.String(), depth)
}

// stdinFor resolves one input redirect: a marked heredoc body (collected
// by runLineBodies and bound through the rewrite) or a file read. A mark
// with no collected body is the unterminated refusal, not a filename.
func (s *Shell) stdinFor(in *redirection) ([]byte, bool) {
	if strings.HasPrefix(in.path, string(hdMark)+"hd") {
		hb, ok := s.hdBodies[in.path]
		if !ok {
			s.host.Out([]byte("gosh: heredoc: unterminated\n"))
			return nil, false
		}
		if !hb.expand {
			return []byte(hb.text), true
		}
		return []byte(s.expandHeredoc(hb.text)), true
	}
	return s.readInput(in.path)
}

// expandHeredoc applies the unquoted-heredoc expansion rules to a
// collected body at the moment the command consumes it: $NAME, ${NAME}
// and $? expand; $(cmd) runs and its captured output splices in;
// $((expr)) is arithmetic; \$, \\ and \` are escapes (any other backslash
// is literal). One left-to-right pass, so text a substitution produced is
// never re-expanded.
func (s *Shell) expandHeredoc(body string) string {
	if strings.IndexByte(body, '$') < 0 {
		return body
	}
	var b strings.Builder
	b.Grow(len(body))
	i := 0
	for i < len(body) {
		c := body[i]
		switch {
		case c == '\\' && i+1 < len(body) &&
			(body[i+1] == '$' || body[i+1] == '\\' || body[i+1] == '`'):
			b.WriteByte(body[i+1])
			i += 2
		case c == '$' && i+1 < len(body) && body[i+1] == '?':
			b.WriteString(vsys.Itoa64(int64(s.status)))
			i += 2
		case c == '$' && i+1 < len(body) && body[i+1] == '{':
			end := strings.IndexByte(body[i+2:], '}')
			if end < 0 {
				b.WriteByte(c)
				i++
				continue
			}
			if v, ok := s.env.Get(body[i+2 : i+2+end]); ok {
				b.WriteString(v)
			}
			i += 2 + end + 1
		case c == '$' && i+1 < len(body) && body[i+1] == '(':
			if i+2 < len(body) && body[i+2] == '(' {
				// `$((expr))` — the same close-scan arithExpand runs.
				j := i + 3
				nest := 0
				for ; j+1 < len(body); j++ {
					if body[j] == '(' {
						nest++
					} else if body[j] == ')' {
						if nest == 0 && body[j+1] == ')' {
							break
						}
						if nest > 0 {
							nest--
						}
					}
				}
				if j+1 < len(body) && j > i+3 {
					b.WriteString(vsys.Itoa64(evalArith(body[i+3 : j])))
					i = j + 2
					continue
				}
				b.WriteByte(c)
				i++
			} else {
				sub, ok := locateCommandSubst(body[i:])
				if !ok {
					b.WriteByte(c)
					i++
					continue
				}
				out, _ := s.captureLine(sub.inner, 0)
				b.WriteString(out)
				i = len(body) - len(sub.suffix)
			}
		case c == '$':
			j := i + 1
			for j < len(body) && isNameByte(body[j]) {
				j++
			}
			if j == i+1 {
				b.WriteByte(c)
				i++
				continue
			}
			if v, ok := s.env.Get(body[i+1 : j]); ok {
				b.WriteString(v)
			}
			i = j
		default:
			b.WriteByte(c)
			i++
		}
	}
	return b.String()
}
