package parser

import "strings"

// zigParser is FLINT's Go-native Zig top-level declaration scanner
// (M103a, ADR 0049 §3). The qualified prefix is the file stem
// (`alloc.zig` -> `alloc.`). It recognizes top-level fn, const/var
// (including const T = [extern|packed[(…)]] struct/enum/union {…}),
// and `test "label" {}`; it skips @import consts, anonymous test {},
// comptime {} and usingnamespace, and refuses anything it cannot place
// as parse_unsupported — it never guesses.
type zigParser struct {
	sink map[string]string
}

func (zigParser) Language() string { return "zig" }

func (zp zigParser) Parse(file string, src []byte) ([]Atom, error) {
	toks, err := zigTokens(file, src)
	if err != nil {
		return nil, err
	}
	s := &zscan{file: file, src: src, toks: toks, stem: zigStem(file), sink: zp.sink}
	return s.decls()
}

func zigStem(file string) string {
	base := file
	if i := strings.LastIndexByte(base, '/'); i >= 0 {
		base = base[i+1:]
	}
	return strings.TrimSuffix(base, ".zig")
}

type zscan struct {
	file string
	src  []byte
	toks []ctok
	stem string
	sink map[string]string
	i    int
}

var zQuals = map[string]bool{
	"pub": true, "export": true, "extern": true,
	"inline": true, "noinline": true, "threadlocal": true,
	"comptime": true,
}

// Container keywords whose `{` in a signature position means an
// anonymous type the scanner must refuse, never the body.
var zAnonBrace = map[string]bool{
	"struct": true, "enum": true, "union": true,
	"opaque": true, "error": true, "packed": true,
}

func (s *zscan) at(i int) ctok {
	if i < len(s.toks) {
		return s.toks[i]
	}
	return s.toks[len(s.toks)-1] // the EOF marker
}

func (s *zscan) is(i int, text string) bool {
	t := s.at(i)
	return zkindOf(t) == zIdent && t.text == text
}

func (s *zscan) punct(i int, text string) bool {
	t := s.at(i)
	return zkindOf(t) == zPunct && t.text == text
}

func (s *zscan) unsupported(off int) error {
	return &ParseError{File: s.file, Offset: off, Code: "parse_unsupported"}
}

func (s *zscan) syntaxErr(off int) error {
	return &ParseError{File: s.file, Offset: off, Code: "syntax"}
}

// skipBalanced returns the index of the token matching the opener at i
// (() [] {} only), or an error for an unterminated run.
func (s *zscan) skipBalanced(i int) (int, error) {
	open := s.toks[i].text
	var close string
	switch open {
	case "(":
		close = ")"
	case "[":
		close = "]"
	case "{":
		close = "}"
	default:
		return i, s.syntaxErr(s.toks[i].start)
	}
	depth := 1
	for i++; i < len(s.toks); i++ {
		t := s.toks[i]
		if zkindOf(t) != zPunct {
			continue
		}
		switch t.text {
		case open:
			depth++
		case close:
			depth--
			if depth == 0 {
				return i, nil
			}
		}
	}
	return i, s.syntaxErr(s.at(i - 1).end)
}

// skipSemi advances past the next ';' at depth 0 (for ignored decls),
// returning the index of the terminator.
func (s *zscan) skipSemi(i int) (int, error) {
	depth := 0
	for ; i < len(s.toks); i++ {
		t := s.toks[i]
		if zkindOf(t) != zPunct {
			continue
		}
		switch t.text {
		case "(", "[", "{":
			depth++
		case ")", "]", "}":
			depth--
		case ";":
			if depth == 0 {
				return i, nil
			}
		}
	}
	return i, s.syntaxErr(len(s.src))
}

func (s *zscan) decls() ([]Atom, error) {
	var atoms []Atom
	for s.i < len(s.toks)-1 {
		t := s.toks[s.i]
		// comptime {…} top-level block: ignored outright.
		if s.is(s.i, "comptime") && s.punct(s.i+1, "{") {
			close, err := s.skipBalanced(s.i + 1)
			if err != nil {
				return nil, err
			}
			s.i = close + 1
			continue
		}
		start := t.start
		// Qualifiers: pub/export/extern/inline/noinline/threadlocal/
		// comptime (a decl qualifier here — `comptime var`).
		for s.i < len(s.toks)-1 && zkindOf(s.toks[s.i]) == zIdent && zQuals[s.toks[s.i].text] {
			if s.is(s.i, "extern") && zkindOf(s.at(s.i+1)) == zStr {
				s.i++ // extern "lib"
			}
			s.i++
		}
		if s.i >= len(s.toks)-1 {
			return nil, s.syntaxErr(start)
		}
		kw := s.toks[s.i]
		if zkindOf(kw) != zIdent {
			return nil, s.unsupported(kw.start)
		}
		switch kw.text {
		case "fn":
			a, err := s.fn(start)
			if err != nil {
				return nil, err
			}
			atoms = append(atoms, a)
		case "const", "var":
			a, skip, err := s.varConst(start, kw.text)
			if err != nil {
				return nil, err
			}
			if !skip {
				atoms = append(atoms, a)
			}
		case "test":
			a, skip, err := s.test(start)
			if err != nil {
				return nil, err
			}
			if !skip {
				atoms = append(atoms, a)
			}
		case "usingnamespace":
			semi, err := s.skipSemi(s.i + 1)
			if err != nil {
				return nil, err
			}
			s.i = semi + 1
		default:
			return nil, s.unsupported(kw.start)
		}
	}
	return atoms, nil
}

// zname unwraps an identifier token: @"quoted name" -> quoted name.
func zname(t ctok) string {
	if strings.HasPrefix(t.text, "@\"") {
		return t.text[2 : len(t.text)-1]
	}
	return t.text
}

// emit hashes one declaration: toks[start..end) range, the declared-name
// token at namePos, sig cut at sigCut, iota unused for Zig (-1).
func (s *zscan) emit(kind, name string, start, end, namePos, sigCut int) Atom {
	var in []ctok
	for _, t := range s.toks {
		if t.text != "" && t.start >= start && t.start < end {
			in = append(in, t)
		}
	}
	sh, ss := canonize(kind, name, in, blankPos(namePos), sigCut, -1, s.sink)
	return Atom{
		Kind: kind, Name: name, File: s.file,
		Start: uint32(start), End: uint32(end),
		Hash: sh, SigHash: ss,
	}
}

// blankPos marks the declared-name token for the canonical stream.
// Test labels are string literals — the declared name is still the
// token itself, so blanking uses the same offset rule.
func blankPos(pos int) int { return pos }

// fn scans `fn name(…) …` — proto (`;`) or body (`{…}`) — from s.i at
// `fn`, with `start` the first qualifier offset.
func (s *zscan) fn(start int) (Atom, error) {
	i := s.i + 1
	nameTok := s.at(i)
	if zkindOf(nameTok) != zIdent {
		return Atom{}, s.unsupported(nameTok.start)
	}
	name := zname(nameTok)
	i++
	if !s.punct(i, "(") {
		return Atom{}, s.unsupported(s.at(i).start)
	}
	close, err := s.skipBalanced(i)
	if err != nil {
		return Atom{}, err
	}
	i = close + 1
	// Signature region: nested parens/brackets skipped; the first `{`
	// at depth 0 opens the body unless it trails a container keyword —
	// that is the anonymous-container return type we refuse.
	depth := 0
	for ; i < len(s.toks); i++ {
		t := s.toks[i]
		if zkindOf(t) != zPunct {
			continue
		}
		switch t.text {
		case "(", "[":
			depth++
		case ")", "]":
			depth--
		case "{":
			if depth != 0 {
				continue
			}
			prev := s.at(i - 1)
			if zkindOf(prev) == zIdent && zAnonBrace[prev.text] {
				return Atom{}, s.unsupported(prev.start)
			}
			bodyClose, err := s.skipBalanced(i)
			if err != nil {
				return Atom{}, err
			}
			end := s.toks[bodyClose].end
			s.i = bodyClose + 1
			return s.emit("fn", s.stem+"."+name, start, end, nameTok.start, t.start), nil
		case ";":
			if depth != 0 {
				continue
			}
			end := t.end
			s.i = i + 1
			return s.emit("fn", s.stem+"."+name, start, end, nameTok.start, 1<<60), nil
		}
	}
	return Atom{}, s.syntaxErr(start)
}

// varConst scans `const|var name [: type] = … ;`. Containers in value
// position re-map the kind; @import values are ignored; a value the
// scanner cannot place is refused.
func (s *zscan) varConst(start int, kw string) (Atom, bool, error) {
	i := s.i + 1
	nameTok := s.at(i)
	if zkindOf(nameTok) != zIdent {
		return Atom{}, false, s.unsupported(nameTok.start)
	}
	name := zname(nameTok)
	i++
	if name == "_" {
		semi, err := s.skipSemi(i)
		if err != nil {
			return Atom{}, false, err
		}
		s.i = semi + 1
		return Atom{}, true, nil
	}
	// Find the top-level '=' or ';' that ends the pre-value region.
	depth := 0
	for ; i < len(s.toks); i++ {
		t := s.toks[i]
		if zkindOf(t) != zPunct {
			continue
		}
		switch t.text {
		case "(", "[", "{":
			depth++
		case ")", "]", "}":
			depth--
		case "=":
			if depth == 0 {
				goto value
			}
		case ";":
			if depth == 0 {
				// `var x: T;` — declaration without a value.
				s.i = i + 1
				sigCut := 1 << 60
				if kw == "var" {
					sigCut = t.start
				}
				return s.emit(kw, s.stem+"."+name, start, t.end, nameTok.start, sigCut), false, nil
			}
		}
	}
	return Atom{}, false, s.syntaxErr(start)

value:
	i++
	// Value-side layout qualifiers: [extern] [packed[(expr)]] then a
	// container keyword re-kinds the Atom.
	v := s.at(i)
	for zkindOf(v) == zIdent && (v.text == "extern" || v.text == "packed") {
		i++
		if s.at(i-1).text == "packed" && s.punct(i, "(") {
			close, err := s.skipBalanced(i)
			if err != nil {
				return Atom{}, false, err
			}
			i = close + 1
		}
		v = s.at(i)
	}
	if zkindOf(v) == zIdent && v.text == "@import" {
		semi, err := s.skipSemi(i)
		if err != nil {
			return Atom{}, false, err
		}
		s.i = semi + 1
		return Atom{}, true, nil
	}
	if zkindOf(v) == zIdent && v.text == "opaque" {
		return Atom{}, false, s.unsupported(v.start)
	}
	if zkindOf(v) == zIdent &&
		(v.text == "struct" || v.text == "enum" || v.text == "union") {
		kind := v.text
		i++
		if s.punct(i, "(") { // union(enum), enum(u8), struct(...)
			close, err := s.skipBalanced(i)
			if err != nil {
				return Atom{}, false, err
			}
			i = close + 1
		}
		if !s.punct(i, "{") {
			return Atom{}, false, s.unsupported(s.at(i).start)
		}
		close, err := s.skipBalanced(i)
		if err != nil {
			return Atom{}, false, err
		}
		i = close + 1
		end := s.toks[close].end
		if s.punct(i, ";") {
			end = s.toks[i].end
			i++
		}
		s.i = i
		return s.emit(kind, s.stem+"."+name, start, end, nameTok.start, 1<<60), false, nil
	}
	// Plain const/var: scan to the terminating ';' at depth 0. The sig
	// stream for var is qualifiers + type (everything before the '=');
	// for const it is the whole declaration.
	sigCut := 1 << 60
	if kw == "var" {
		sigCut = s.toks[i-1].start // i-1 is the '='
	}
	semi, err := s.skipSemi(i)
	if err != nil {
		return Atom{}, false, err
	}
	s.i = semi + 1
	return s.emit(kw, s.stem+"."+name, start, s.toks[semi].end, nameTok.start, sigCut), false, nil
}

// test scans `test "label" {…}` (atom) or skips anonymous `test {…}`.
func (s *zscan) test(start int) (Atom, bool, error) {
	i := s.i + 1
	t := s.at(i)
	if zkindOf(t) == zPunct && t.text == "{" {
		close, err := s.skipBalanced(i)
		if err != nil {
			return Atom{}, false, err
		}
		s.i = close + 1
		return Atom{}, true, nil
	}
	if zkindOf(t) != zStr {
		return Atom{}, false, s.unsupported(t.start)
	}
	label := t.text[1 : len(t.text)-1]
	i++
	if !s.punct(i, "{") {
		return Atom{}, false, s.unsupported(s.at(i).start)
	}
	close, err := s.skipBalanced(i)
	if err != nil {
		return Atom{}, false, err
	}
	s.i = close + 1
	return s.emit("test", s.stem+".test:"+label, start, s.toks[close].end, t.start, s.toks[i].start), false, nil
}
