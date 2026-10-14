package parser

import (
	"strings"

	"virelai/sshlib"
)

// Hash domains (ADR 0049 §3, byte-exact).
const (
	atomDomain = "FLINT-ATOM/1\x00"
	sigDomain  = "FLINT-SIG/1\x00"
)

// ctok is one canonical token: absolute byte offsets into the source and
// the token's canonical text (identifier/literal text, or the operator's
// own string for punctuation).
type ctok struct {
	start, end int
	text       string
}

// CanonMap parses (file, src) and returns each Atom's canonical token stream
// keyed by its qualified Name. It uses a parser-local map (no package-level
// mutable state) so concurrent callers cannot race.
func CanonMap(file string, src []byte) (map[string]string, error) {
	m := make(map[string]string)
	var p Parser
	switch {
	case strings.HasSuffix(file, ".go"):
		p = goParser{sink: m}
	case strings.HasSuffix(file, ".zig"):
		p = zigParser{sink: m}
	default:
		return nil, &ParseError{File: file, Offset: 0, Code: "parse_unsupported"}
	}
	if _, err := p.Parse(file, src); err != nil {
		return nil, err
	}
	return m, nil
}

// canonize builds the §3 canonical token stream for a declaration: every
// token in [toks], comments already dropped by the tokenizer, joined by a
// single space, with the token at blankPos replaced by "_". An implicit
// iota repeat appends " iota=<index>" (iota >= 0 only). Tokens whose
// start is < sigCut also form the signature stream. The two SHA-256 sums
// are returned as (hash, sig_hash).
func canonize(kind, qname string, toks []ctok, blankPos, sigCut, iota int, sink map[string]string) ([32]byte, [32]byte) {
	allStr, sigStr := canonText(toks, blankPos, sigCut, iota)
	if sink != nil {
		sink[qname] = allStr
	}
	var sh, ss [32]byte
	sh = sshlib.SHA256Sum(hashInput(atomDomain, kind, allStr))
	ss = sshlib.SHA256Sum(hashInput(sigDomain, kind, sigStr))
	return sh, ss
}

func canonText(toks []ctok, blankPos, sigCut, iota int) (string, string) {
	n := len(toks)
	if iota >= 0 {
		n++
	}
	var all, sig strings.Builder
	all.Grow(n * 12)
	sig.Grow(n * 12)
	first := true
	for _, t := range toks {
		text := t.text
		if t.start == blankPos {
			text = "_"
		}
		if !first {
			all.WriteByte(' ')
		}
		first = false
		all.WriteString(text)
		if t.start < sigCut {
			sig.WriteString(text)
			sig.WriteByte(' ')
		}
	}
	if iota >= 0 {
		all.WriteString(" iota=")
		all.WriteString(itoa(iota))
		sig.WriteString("iota=")
		sig.WriteString(itoa(iota))
		sig.WriteByte(' ')
	}
	return all.String(), strings.TrimSuffix(sig.String(), " ")
}

func hashInput(domain, kind, body string) []byte {
	b := make([]byte, 0, len(domain)+len(kind)+1+len(body))
	b = append(b, domain...)
	b = append(b, kind...)
	b = append(b, 0)
	b = append(b, body...)
	return b
}
