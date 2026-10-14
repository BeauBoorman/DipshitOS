package parser

// Zig tokenizer for FLINT's declaration scanner (M103a, ADR 0049 §3).
// Handles // /// //! comments, "…" strings with escapes, \\ multiline
// strings, '…' char literals, @"…" identifiers and ()[]{} nesting.
// Comments never produce tokens — the canonical stream drops them.

type zkind byte

const (
	zIdent zkind = iota // identifiers, keywords and @builtins
	zStr                // "…" or one \\ multiline line
	zChar               // '…'
	zNum                // number literal
	zPunct              // single-byte punctuation
	zEOF
)

// zigTokens lexes the whole file. A malformed literal is a *ParseError
// with Code "syntax" at its offset — the scanner never guesses.
func zigTokens(file string, src []byte) ([]ctok, error) {
	var out []ctok
	i := 0
	for i < len(src) {
		c := src[i]
		switch {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n':
			i++
		case c == '/' && i+1 < len(src) && src[i+1] == '/':
			for i < len(src) && src[i] != '\n' {
				i++
			}
		case c == '\\' && i+1 < len(src) && src[i+1] == '\\':
			start := i
			for i < len(src) && src[i] != '\n' {
				i++
			}
			out = append(out, ctok{start: start, end: i, text: string(src[start:i])})
		case c == '"':
			start := i
			i++
			for i < len(src) && src[i] != '"' {
				if src[i] == '\\' {
					i++
					if i >= len(src) {
						break
					}
				}
				i++
			}
			if i >= len(src) {
				return nil, &ParseError{File: file, Offset: start, Code: "syntax"}
			}
			i++
			out = append(out, ctok{start: start, end: i, text: string(src[start:i])})
		case c == '\'':
			start := i
			i++
			if i < len(src) && src[i] == '\'' {
				return nil, &ParseError{File: file, Offset: start, Code: "syntax"}
			}
			for i < len(src) && src[i] != '\'' && src[i] != '\n' {
				if src[i] == '\\' {
					i++
					if i >= len(src) {
						break
					}
				}
				i++
			}
			if i >= len(src) || src[i] != '\'' {
				return nil, &ParseError{File: file, Offset: start, Code: "syntax"}
			}
			i++
			out = append(out, ctok{start: start, end: i, text: string(src[start:i])})
		case c == '@' && i+1 < len(src) && src[i+1] == '"':
			start := i
			i += 2
			for i < len(src) && src[i] != '"' && src[i] != '\n' {
				if src[i] == '\\' {
					i++
					if i >= len(src) {
						break
					}
				}
				i++
			}
			if i >= len(src) || src[i] != '"' {
				return nil, &ParseError{File: file, Offset: start, Code: "syntax"}
			}
			i++
			out = append(out, ctok{start: start, end: i, text: string(src[start:i])})
		case c == '@' && i+1 < len(src) && isZIdentStart(src[i+1]):
			start := i
			i += 2
			for i < len(src) && isZIdent(src[i]) {
				i++
			}
			out = append(out, ctok{start: start, end: i, text: string(src[start:i])})
		case isZIdentStart(c):
			start := i
			i++
			for i < len(src) && isZIdent(src[i]) {
				i++
			}
			out = append(out, ctok{start: start, end: i, text: string(src[start:i])})
		case isZDigit(c):
			start := i
			hexLit := c == '0' && i+1 < len(src) && (src[i+1] == 'x' || src[i+1] == 'X')
			i++
			for i < len(src) {
				d := src[i]
				if isZNum(d) {
					i++
					continue
				}
				if d == '.' && i+1 < len(src) && isZDigit(src[i+1]) {
					i++
					continue
				}
				if (d == '+' || d == '-') && i+1 < len(src) && isZDigit(src[i+1]) {
					prev := src[i-1]
					if (!hexLit && (prev == 'e' || prev == 'E')) || (hexLit && (prev == 'p' || prev == 'P')) {
						i++
						continue
					}
				}
				break
			}
			out = append(out, ctok{start: start, end: i, text: string(src[start:i])})
		default:
			out = append(out, ctok{start: i, end: i + 1, text: string(src[i : i+1])})
			i++
		}
	}
	out = append(out, ctok{start: len(src), end: len(src), text: ""})
	return out, nil
}

// zkindOf classifies a ctok for the scanner: builtins (@import) and
// @"…" quoted names read as zIdent, strings/chars/numbers by literal,
// anything else punctuation.
func zkindOf(t ctok) zkind {
	if t.start == t.end {
		return zEOF
	}
	c := t.text[0]
	switch {
	case c == '"' || c == '\\':
		return zStr
	case c == '\'':
		return zChar
	case isZDigit(c):
		return zNum
	case isZIdentStart(c) || c == '@':
		return zIdent
	}
	return zPunct
}

func isZIdentStart(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func isZIdent(c byte) bool { return isZIdentStart(c) || isZDigit(c) }

func isZDigit(c byte) bool { return c >= '0' && c <= '9' }

func isZNum(c byte) bool {
	return isZDigit(c) || c == '_' ||
		(c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}
