// Package parser turns Go and Zig source into FLINT Atoms (M103a, #2253,
// ADR 0049 §3): one Atom per top-level declaration, each carrying a
// canonical-content hash and a signature hash. Go goes through go/parser;
// Zig goes through this package's own tokenizer + top-level declaration
// scanner (the guest has no Zig toolchain and `zig ast` does not exist).
package parser

import (
	"strings"
)

// Atom is one top-level declaration, named and hashed per ADR 0049 §3.
// Start/End are byte offsets into the source (End exclusive). Meta is nil
// unless a kind needs it (methods carry receiver).
type Atom struct {
	Kind, Name, File string
	Start, End       uint32
	Hash, SigHash    [32]byte
	Meta             map[string]string
}

// Parser turns one source file into Atoms.
type Parser interface {
	Language() string
	Parse(file string, src []byte) ([]Atom, error)
}

// ForPath picks the parser for a file name's extension.
func ForPath(file string) (Parser, bool) {
	switch {
	case strings.HasSuffix(file, ".go"):
		return goParser{}, true
	case strings.HasSuffix(file, ".zig"):
		return zigParser{}, true
	}
	return nil, false
}

// ParseError codes: "syntax" for a file the language's own grammar
// refuses, "parse_unsupported" for a construct this scanner will not
// guess at (ADR 0049 §3 — it never guesses).
type ParseError struct {
	File   string
	Offset int
	Code   string
}

func (e *ParseError) Error() string {
	return "flint: " + e.Code + " " + e.File + ":" + itoa(e.Offset)
}

func itoa(v int) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}
