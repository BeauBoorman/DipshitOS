// GOSH's pure line front-end: the tokenizer, the variable expander, and the
// line-plan parser. This file (and shell.go, toolbox.go, edit.go) holds no
// syscall knowledge — the M68a scripting subset is host-testable here, and
// main.go wires the single Host seam to the vi calls.
package shlib

import (
	"errors"
	"strings"
)

// escMark prefixes a character the tokenizer made literal (backslash
// escapes and single-quoted content): the expander copies it through
// verbatim instead of treating a following `$` as a variable reference. The
// engine strips this control byte from file-sourced lines, and the editor
// never inserts control bytes, so the sentinel cannot collide with input.
const escMark = '\x01'

// tokKind classifies one scanned token. Operators are only operators when
// they appear UNQUOTED — a quoted "|" is a word character like any other.
type tokKind int

const (
	tokWord tokKind = iota
	tokPipe
	tokOut
	tokAppend
	tokIn
	tokAmp
	tokHeredoc
)

type token struct {
	kind      tokKind
	text      string
	stripTabs bool // tokHeredoc: `<<-` strips leading tabs
}

// tokenize splits a raw line into words and operator tokens. Quoting follows
// the M19 subset: '…' is fully literal, "…" allows $ expansion, \x outside
// quotes makes x literal (escMark-marked for the expander), and adjacent
// segments concatenate into one word (`abc"def"g` is one word). An unquoted
// # at a word boundary starts a comment and ends the line.
func tokenize(line string) ([]token, error) {
	var toks []token
	i := 0
	for i < len(line) {
		c := line[i]
		switch {
		case c == ' ' || c == '\t':
			i++
		case c == '#':
			return toks, nil // comment: drop the rest of the line
		case c == '|':
			toks = append(toks, token{kind: tokPipe})
			i++
		case c == '>':
			if i+1 < len(line) && line[i+1] == '>' {
				toks = append(toks, token{kind: tokAppend})
				i += 2
			} else {
				toks = append(toks, token{kind: tokOut})
				i++
			}
		case c == '<':
			if i+1 < len(line) && line[i+1] == '<' {
				// runLineBodies rewrites a declared heredoc to a marked
				// `<` before this stage, so a `<<` surviving to the
				// tokenizer is one whose body was never collected (an
				// alias splice, a $(...) inner line) — parsePlan refuses
				// it by name rather than mis-parse it as two redirects.
				if i+2 < len(line) && line[i+2] == '<' {
					return nil, errors.New("gosh: here-strings (<<<) are not supported")
				}
				t := token{kind: tokHeredoc}
				if i+2 < len(line) && line[i+2] == '-' {
					t.stripTabs = true
					i++
				}
				toks = append(toks, t)
				i += 2
			} else {
				toks = append(toks, token{kind: tokIn})
				i++
			}
		case c == '&':
			toks = append(toks, token{kind: tokAmp})
			i++
		default:
			text, next, err := scanWord(line, i)
			if err != nil {
				return nil, err
			}
			toks = append(toks, token{kind: tokWord, text: text})
			i = next
		}
	}
	return toks, nil
}

// scanWord reads one word starting at a non-space, non-operator character.
// It consumes bare characters and quote segments until a word boundary
// (whitespace or an operator character).
func scanWord(line string, start int) (string, int, error) {
	var b strings.Builder
	i := start
	for i < len(line) {
		c := line[i]
		switch c {
		case ' ', '\t', '|', '<', '>', '&':
			return b.String(), i, nil
		case '\'':
			j := strings.IndexByte(line[i+1:], '\'')
			if j < 0 {
				return "", 0, errors.New("gosh: unterminated ' quote")
			}
			// Fully literal: protect every byte from the expander.
			for _, q := range []byte(line[i+1 : i+1+j]) {
				b.WriteByte(escMark)
				b.WriteByte(q)
			}
			i += j + 2
		case '"':
			next, err := scanDouble(line, i, &b)
			if err != nil {
				return "", 0, err
			}
			i = next
		case '\\':
			if i+1 >= len(line) {
				return "", 0, errors.New("gosh: trailing backslash")
			}
			b.WriteByte(escMark)
			b.WriteByte(line[i+1])
			i += 2
		default:
			b.WriteByte(c)
			i++
		}
	}
	return b.String(), i, nil
}

// scanDouble appends a double-quoted segment starting at line[start]=='"'
// to b. Inside double quotes only \" \\ \$ are escapes; $ still expands.
// Every quoted byte is escMark-literal — quoted `*`/`?`/`[` never glob —
// except the bytes of a $ expansion itself ($?, ${NAME}, $NAME), which
// stay bare so the expander can consume them; the value it emits is
// already flagged literal.
func scanDouble(line string, start int, b *strings.Builder) (int, error) {
	i := start + 1
	for i < len(line) {
		c := line[i]
		switch c {
		case '"':
			return i + 1, nil
		case '\\':
			if i+1 < len(line) {
				switch line[i+1] {
				case '"', '\\', '$':
					b.WriteByte(escMark)
					b.WriteByte(line[i+1])
					i += 2
					continue
				}
			}
			b.WriteByte(escMark)
			b.WriteByte(c)
			i++
		case '$':
			b.WriteByte(c)
			i++
			if i >= len(line) {
				break
			}
			switch {
			case line[i] == '?':
				b.WriteByte('?')
				i++
			case line[i] == '{':
				end := strings.IndexByte(line[i:], '}')
				if end < 0 {
					b.WriteByte('{')
					i++
				} else {
					for k := i; k <= i+end; k++ {
						b.WriteByte(line[k])
					}
					i += end + 1
				}
			default:
				for i < len(line) && isNameByte(line[i]) {
					b.WriteByte(line[i])
					i++
				}
			}
		default:
			b.WriteByte(escMark)
			b.WriteByte(c)
			i++
		}
	}
	return 0, errors.New("gosh: unterminated \" quote")
}

// expand runs $ expansion over one word token: $NAME, ${NAME} and $?
// (the last status). escMark-marked bytes pass through as literals.
// Expansion never re-splits words — a variable's value stays one word.
// The walk itself lives in glob.go's expandMarked, which additionally
// reports which bytes are glob-active; expand is the flags-free form.
func expand(t token, env *Env, status int) string {
	w, _ := expandMarked(t, env, status)
	return w
}

func isNameByte(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// redirection is one `>`, `>>` or `<` target.
type redirection struct {
	append bool
	path   string
}

// plan is one executable line: `left`, optionally piped into `right`, with
// at most one input and one output redirection and an optional trailing `&`.
type plan struct {
	left       []string
	right      []string // non-empty => one pipe stage
	out        *redirection
	in         *redirection
	background bool
}

// parsePlan assembles the operator tokens into a plan. The M68a subset
// refuses, with honest messages, everything it does not implement: chained
// pipes, duplicate redirects, `&` anywhere but the end, and `&` combined
// with pipes or redirects.
//
// globFn (M98a) expands one word into zero-or-more argv words; nil keeps
// every word literal. It applies to argument positions only — never the
// command word itself, never redirect targets, and never the NAME=VALUE
// words of set/export/alias.
func parsePlan(toks []token, env *Env, status int, globFn globFunc) (*plan, error) {
	var p plan
	var left, right []string
	cur := &left
	flush := func() error {
		if len(*cur) == 0 {
			return errors.New("gosh: empty command")
		}
		return nil
	}
	i := 0
	for i < len(toks) {
		t := toks[i]
		switch t.kind {
		case tokWord:
			w, act := expandMarked(t, env, status)
			if globFn != nil && len(*cur) > 0 && !globExemptHead((*cur)[0], w) {
				words, err := globFn(w, act)
				if err != nil {
					return nil, err
				}
				*cur = append(*cur, words...)
			} else {
				*cur = append(*cur, w)
			}
			i++
		case tokPipe:
			if err := flush(); err != nil {
				return nil, err
			}
			if len(right) > 0 {
				return nil, errors.New("gosh: pipes: only one pipe per line (no chaining)")
			}
			if p.out != nil || p.in != nil {
				return nil, errors.New("gosh: redirects must come after the pipe")
			}
			right = nil
			cur = &right
			i++
		case tokOut, tokAppend:
			if err := flush(); err != nil {
				return nil, err
			}
			if p.out != nil {
				return nil, errors.New("gosh: one output redirect per line")
			}
			if i+1 >= len(toks) || toks[i+1].kind != tokWord {
				return nil, errors.New("gosh: > needs a file path")
			}
			p.out = &redirection{append: t.kind == tokAppend, path: expand(toks[i+1], env, status)}
			i += 2
		case tokIn:
			if err := flush(); err != nil {
				return nil, err
			}
			if p.in != nil {
				return nil, errors.New("gosh: one input redirect per line")
			}
			if i+1 >= len(toks) || toks[i+1].kind != tokWord {
				return nil, errors.New("gosh: < needs a file path")
			}
			p.in = &redirection{path: expand(toks[i+1], env, status)}
			i += 2
		case tokHeredoc:
			if err := flush(); err != nil {
				return nil, err
			}
			if i+1 >= len(toks) || toks[i+1].kind != tokWord {
				return nil, errors.New("gosh: << needs a delimiter word")
			}
			// Only reachable for a `<<` that arrived after the collect
			// step — an alias splice or a substitution's inner line. The
			// body it declares can never be read here, so name the refusal
			// rather than treat it as a file redirect.
			return nil, errors.New("gosh: heredoc: unterminated <" +
				stripEscMarks(toks[i+1].text) + ">")
		case tokAmp:
			if i != len(toks)-1 {
				return nil, errors.New("gosh: & must end the line")
			}
			if len(right) > 0 || p.out != nil || p.in != nil {
				return nil, errors.New("gosh: & runs one external app, with no pipe or redirect")
			}
			p.background = true
			i++
		}
	}
	if err := flush(); err != nil {
		return nil, err
	}
	p.left = left
	p.right = right
	return &p, nil
}
