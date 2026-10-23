package main

// parse.go — the RFC 3501 "S-expression" reader for IMAP response
// payloads: atoms, quoted strings, {n}\r\n literals, and parenthesized
// lists, producing a form tree (nil | string | []form) that imap.go
// walks for LIST names, ENVELOPE headers, and BODYSTRUCTURE. Bounds are
// hard: a record is at most recordMax bytes, a literal literalMax, and a
// malformed form fails the whole response — a structural lie never
// produces a partial parse.

import "errors"

type form = interface{}

var errBadForm = errors.New("gomail: malformed imap form")

const (
	recordMax  = 512 * 1024 // one logical response line, literals included
	literalMax = 256 * 1024 // one {n} literal
)

// parser walks a raw record. Literal bytes are embedded inline: the
// record reader leaves '{n}\r\n<payload>' sequences in place and this
// parser decodes them as string tokens.
type parser struct {
	b []byte
	i int
}

// parseValue parses one form at p.i: '(' list | '"' quoted | '{n}'
// literal | atom (NIL → nil).
func (p *parser) parseValue() (form, error) {
	if p.i >= len(p.b) {
		return nil, errBadForm
	}
	switch c := p.b[p.i]; {
	case c == '(':
		return p.parseList()
	case c == '"':
		return p.parseQuoted()
	case c == '{':
		return p.parseLiteral()
	default:
		return p.parseAtom()
	}
}

func (p *parser) parseList() ([]form, error) {
	p.i++ // '('
	out := []form{}
	for {
		for p.i < len(p.b) && p.b[p.i] == ' ' {
			p.i++
		}
		if p.i >= len(p.b) {
			return nil, errBadForm
		}
		if p.b[p.i] == ')' {
			p.i++
			return out, nil
		}
		v, err := p.parseValue()
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
}

func (p *parser) parseQuoted() (form, error) {
	p.i++ // '"'
	var out []byte
	for p.i < len(p.b) {
		c := p.b[p.i]
		p.i++
		switch c {
		case '"':
			return string(out), nil
		case '\\':
			if p.i >= len(p.b) {
				return nil, errBadForm
			}
			out = append(out, p.b[p.i])
			p.i++
		default:
			out = append(out, c)
		}
	}
	return nil, errBadForm
}

func (p *parser) parseLiteral() (form, error) {
	p.i++ // '{'
	n := 0
	digits := 0
	for p.i < len(p.b) && p.b[p.i] >= '0' && p.b[p.i] <= '9' {
		n = n*10 + int(p.b[p.i]-'0')
		if n > literalMax {
			return nil, errBadForm
		}
		p.i++
		digits++
	}
	if digits == 0 || p.i+3 > len(p.b) || p.b[p.i] != '}' ||
		p.b[p.i+1] != '\r' || p.b[p.i+2] != '\n' {
		return nil, errBadForm
	}
	p.i += 3
	if len(p.b)-p.i < n {
		return nil, errBadForm
	}
	v := string(p.b[p.i : p.i+n])
	p.i += n
	return v, nil
}

// parseAtom reads an atom: any run without SP, parens, quote, brace or
// CTL. "NIL" decodes to nil; everything else stays a string (flags,
// numbers, names, FETCH keys like BODY[TEXT]).
func (p *parser) parseAtom() (form, error) {
	start := p.i
	for p.i < len(p.b) {
		c := p.b[p.i]
		if c <= ' ' || c == '(' || c == ')' || c == '"' || c == '{' || c == '}' || c == 0x7f {
			break
		}
		p.i++
	}
	if p.i == start {
		return nil, errBadForm
	}
	s := string(p.b[start:p.i])
	if s == "NIL" {
		return nil, nil
	}
	return s, nil
}

// parseRecord decodes a whole logical response line into its top-level
// token stream (e.g. "*", "1", "FETCH", (items...)). All bytes must be
// consumed — trailing garbage fails the record.
func parseRecord(b []byte) ([]form, error) {
	if len(b) == 0 || len(b) > recordMax {
		return nil, errBadForm
	}
	p := &parser{b: b}
	var out []form
	for {
		for p.i < len(p.b) && p.b[p.i] == ' ' {
			p.i++
		}
		if p.i >= len(p.b) {
			return out, nil
		}
		v, err := p.parseValue()
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
}

// --- form accessors: the walk helpers imap.go/mime.go share -----------

func formStr(f form) (string, bool) {
	s, ok := f.(string)
	return s, ok
}

func formList(f form) ([]form, bool) {
	l, ok := f.([]form)
	return l, ok
}

// formStrOr returns f as a string, or def for NIL/non-string.
func formStrOr(f form, def string) string {
	if s, ok := f.(string); ok {
		return s
	}
	return def
}

// formPairs decodes a ("NAME" "val" "NAME2" "val2") parameter list into
// a lookup. Non-conforming shapes yield an empty map, not an error.
func formPairs(f form) map[string]string {
	out := map[string]string{}
	l, ok := formList(f)
	if !ok {
		return out
	}
	for i := 0; i+1 < len(l); i += 2 {
		k, ok1 := formStr(l[i])
		v, ok2 := formStr(l[i+1])
		if !ok1 || !ok2 {
			continue
		}
		out[lowerASCII(k)] = v
	}
	return out
}

func lowerASCII(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}
