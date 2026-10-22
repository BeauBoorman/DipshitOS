package main

// heat.go — M166c (#2991): the per-function heat gutter. `--prof=<path>`
// names a PROF .folded capture (WriteFolded's `frame;frame;leaf count`
// lines), read once at open. Self samples are the leaf frame's counts;
// `funcN` closure suffixes fold into the enclosing function; a `0x…`
// leaf is an unresolved PC — its samples count toward the total but map
// to no function. GOEDIT parses the file itself: importing virelai/prof
// would pull in debug/elf, and this app already budgets its imports
// against the 16-region sbrk wall (see format.go's probe note).
//
// A .go buffer maps profile names onto its own declarations — `pkg.f`
// for a plain function, `pkg.T.m` / `pkg.(*T).m` for a method, found in
// classifyGo's code bytes only — and every line of a matched function's
// span (the `func` line through the body brace's match line, the M166b
// scanner) carries a 4-px strip at the frame's left edge coloured by
// which of four heat buckets its share of the total samples lands in.
// Non-.go buffers and a missing flag paint nothing.
//
// The mapping is per-doc state (it parks with the buffer like folds do)
// and recomputes lazily after any splice — an edit that moves or adds a
// declaration repaints against the real offsets, never a stale map.

import (
	"strings"

	"virelai/vi"
)

// heatData is the parsed capture: self samples per resolved function
// (closure suffixes already folded), the grand total every share divides
// by — unmapped hex-leaf samples included — and the hottest function's
// name and count for the marker.
type heatData struct {
	fns     map[string]uint64
	samples uint64
	top     string
	topN    uint64
}

// heatSpan is one matched function's line range in buffer coordinates:
// lo and hi are the byte offsets where the decl line and the body
// close-brace's line begin, so a drawn line starting at s belongs to the
// function iff lo <= s <= hi.
type heatSpan struct {
	lo, hi int
	bucket int
}

// The gutter strip and its four buckets — constant accents like colCaret
// and colMatch, identical under either theme so the pixel probe pins the
// same triples the host tests do. The ramp runs dim-amber to red.
// heatX clears the kernel's left window chrome: the border plus the
// focus-accent pixel occlude local x 0..2 of the scanout (observed on
// run 13's capture), so the strip starts at x=3 — the frame's visible
// left edge — and its last column underlaps the text margin's first
// cell, painting under glyphs the way selection does.
const (
	heatW = 4
	heatX = 3
)

var colHeat = [4]uint32{0x7a5c1e, 0xc07a1e, 0xe04a1e, 0xe01e1e}

// heatRead is the profile-read seam: vi.ReadFileAll in the guest,
// substituted in host tests — the same shape bufRead takes for the buffer
// and errRead for the diagnostics file.
var heatRead = func(p string) ([]byte, int64) {
	return vi.ReadFileAll(p, vi.MaxFileBytes)
}

// --- the .folded parser ---------------------------------------------------

// parseFolded reads WriteFolded's output. Only the leaf frame counts —
// its count is that function's self samples. The parse is strict: one
// malformed line refuses the whole file and the second return names its
// 1-based line number (a torn capture is not half-trusted). Blank lines —
// the trailing newline's artifact — skip.
func parseFolded(b []byte) (*heatData, int) {
	h := &heatData{fns: make(map[string]uint64)}
	for ln, line := range strings.Split(string(b), "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		sp := strings.LastIndexByte(line, ' ')
		if sp <= 0 {
			return nil, ln + 1
		}
		var n uint64
		for i := sp + 1; i < len(line); i++ {
			c := line[i]
			if c < '0' || c > '9' {
				return nil, ln + 1
			}
			n = n*10 + uint64(c-'0')
		}
		h.samples += n
		stack := line[:sp]
		leaf := stack
		if i := strings.LastIndexByte(stack, ';'); i >= 0 {
			leaf = stack[i+1:]
		}
		if leaf == "" {
			return nil, ln + 1
		}
		if strings.HasPrefix(leaf, "0x") {
			continue // unresolved PC: unmapped samples, no function
		}
		fn := heatParent(leaf)
		h.fns[fn] += n
		if v := h.fns[fn]; v > h.topN || (v == h.topN && (h.top == "" || fn < h.top)) {
			h.top, h.topN = fn, v
		}
	}
	return h, 0
}

// heatParent folds a `funcN` closure suffix into its enclosing function:
// `pkg.f.func1` — and the `pkg.f.func1.2` spelling deeper nesting takes —
// answers to `pkg.f`. A bare `pkg.funcN` keeps its name: its would-be
// parent is the package, not a function. A `.func` run not followed by
// digits, or with a non-numeric tail, is an ordinary identifier.
func heatParent(name string) string {
	for i := 0; i+5 < len(name); i++ {
		if name[i] != '.' || !strings.HasPrefix(name[i:], ".func") {
			continue
		}
		j := i + 5
		if name[j] < '0' || name[j] > '9' {
			continue
		}
		for j < len(name) && name[j] >= '0' && name[j] <= '9' {
			j++
		}
		for j < len(name) && name[j] == '.' {
			k := j + 1
			for k < len(name) && name[k] >= '0' && name[k] <= '9' {
				k++
			}
			if k == j+1 {
				break
			}
			j = k
		}
		if j != len(name) {
			continue
		}
		if strings.IndexByte(name[:i], '.') >= 0 {
			return name[:i]
		}
		return name
	}
	return name
}

// --- the declaration scanner ----------------------------------------------

// isIdentByte is the ASCII identifier set — profile names and the decls
// they match are ASCII, so the scanner needn't decode.
func isIdentByte(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// wordAt reports whether buf[i:] begins with word w as a whole
// identifier, in code bytes only — a `func` inside a string, comment or
// longer identifier does not count.
func wordAt(buf, cls []byte, i int, w string) bool {
	if i < 0 || i+len(w) > len(buf) {
		return false
	}
	for k := 0; k < len(w); k++ {
		if cls[i+k] != clsCode || buf[i+k] != w[k] {
			return false
		}
	}
	if i > 0 && isIdentByte(buf[i-1]) {
		return false
	}
	if j := i + len(w); j < len(buf) && isIdentByte(buf[j]) {
		return false
	}
	return true
}

// skipGap walks forward over whitespace and comment bytes — the legal
// filler between two Go tokens.
func skipGap(buf, cls []byte, i int) int {
	for i < len(buf) {
		if cls[i] == clsCmt {
			i++
			continue
		}
		switch buf[i] {
		case ' ', '\t', '\n', '\r':
			i++
		default:
			return i
		}
	}
	return i
}

// readIdent takes the identifier at i, or "" when i is not on one.
func readIdent(buf, cls []byte, i int) string {
	j := i
	for j < len(buf) && cls[j] == clsCode && isIdentByte(buf[j]) {
		j++
	}
	return string(buf[i:j])
}

// prevWord is the identifier ending just before i, scanning back over
// the gap bytes — the token a `{` belongs to.
func prevWord(buf, cls []byte, i int) string {
	j := i - 1
	for j >= 0 && (cls[j] == clsCmt || buf[j] == ' ' || buf[j] == '\t' || buf[j] == '\n' || buf[j] == '\r') {
		j--
	}
	end := j + 1
	for j >= 0 && cls[j] == clsCode && isIdentByte(buf[j]) {
		j--
	}
	return string(buf[j+1 : end])
}

// goPackage is the buffer's package clause — the first `package` keyword
// in code bytes — or "" when the buffer does not parse that far.
func goPackage(buf, cls []byte) string {
	for i := 0; i < len(buf); i++ {
		if wordAt(buf, cls, i, "package") {
			return readIdent(buf, cls, skipGap(buf, cls, i+len("package")))
		}
	}
	return ""
}

// goDecl is one top-level `func` declaration named the way PROF's
// symbolizer names it. lo/hi carry the span for the gutter: the decl
// line's start and the body close-brace's line's start.
type goDecl struct {
	name   string
	lo, hi int
}

// declLine reports whether the `func` at i is the first token on its
// line (whitespace and comments aside) — a declaration site. A `func`
// mid-line is a literal or a type (`var f = func(…`), never a decl.
// Comment bytes never end the walk back to the line start: a `\n`
// inside a block comment is clsCmt, not a code byte.
func declLine(buf, cls []byte, i int) bool {
	s := i
	for s > 0 && !(buf[s-1] == '\n' && cls[s-1] == clsCode) {
		s--
	}
	for k := s; k < i; k++ {
		if cls[k] == clsCmt {
			continue
		}
		switch buf[k] {
		case ' ', '\t', '\r':
		default:
			return false
		}
	}
	return true
}

// recvType is the receiver's type text inside (lo,hi) — the last token
// before the close paren: `r *T` answers `*T`, `T` answers `T`.
func recvType(buf, cls []byte, lo, hi int) string {
	j := hi - 1
	for j >= lo && (cls[j] == clsCmt || buf[j] == ' ' || buf[j] == '\t' || buf[j] == '\n' || buf[j] == '\r') {
		j--
	}
	end := j + 1
	for j >= lo && cls[j] == clsCode &&
		(isIdentByte(buf[j]) || buf[j] == '*' || buf[j] == '[' || buf[j] == ']' || buf[j] == '.') {
		j--
	}
	return string(buf[j+1 : end])
}

// scanGoDecls walks a .go buffer's top level for `func` declarations —
// a keyword that opens its line and sits outside every brace pair; the
// `func` in a literal or a struct-field type fails one test or the
// other. The body's opening brace is the first `{` at paren depth 0
// whose token is not `struct`/`interface` (those literals jump to their
// own match); Go's semicolon rule means the signature's `{` precedes
// the next depth-0 newline, so a newline first means a bodiless decl —
// an assembly stub — which maps nothing.
func scanGoDecls(buf, cls []byte) []goDecl {
	pkg := goPackage(buf, cls)
	if pkg == "" {
		return nil
	}
	pairs := bracePairsCls(buf, cls)
	closeOf := make(map[int]int, len(pairs))
	for _, p := range pairs {
		closeOf[p.open] = p.close
	}
	enclosed := func(off int) bool {
		for _, p := range pairs {
			if off > p.open && off < p.close {
				return true
			}
		}
		return false
	}
	var out []goDecl
	for i := 0; i+4 <= len(buf); i++ {
		if buf[i] != 'f' || !wordAt(buf, cls, i, "func") || enclosed(i) || !declLine(buf, cls, i) {
			continue
		}
		j := skipGap(buf, cls, i+4)
		var name string
		if j < len(buf) && cls[j] == clsCode && buf[j] == '(' {
			depth := 0
			close := -1
			for k := j; k < len(buf); k++ {
				if cls[k] != clsCode {
					continue
				}
				if buf[k] == '(' {
					depth++
				} else if buf[k] == ')' {
					if depth--; depth == 0 {
						close = k
						break
					}
				}
			}
			if close < 0 {
				continue
			}
			rt := recvType(buf, cls, j+1, close)
			j = skipGap(buf, cls, close+1)
			name = readIdent(buf, cls, j)
			if name == "" || rt == "" {
				continue // `func(params) [results]` shape — not a decl
			}
			if rt[0] == '*' {
				rt = "(" + rt + ")"
			}
			name = pkg + "." + rt + "." + name
		} else {
			name = readIdent(buf, cls, j)
			if name == "" {
				continue
			}
			name = pkg + "." + name
		}
		// The body brace: first '{' at paren depth 0 before the next
		// depth-0 newline, skipping struct/interface literals by their
		// matched pair.
		depth := 0
		open := -1
	body:
		for k := j; k < len(buf); k++ {
			if cls[k] != clsCode {
				continue
			}
			switch buf[k] {
			case '\n':
				if depth == 0 {
					break body // signature ended — no body
				}
			case '(':
				depth++
			case ')':
				depth--
			case '{':
				if depth != 0 {
					continue
				}
				if w := prevWord(buf, cls, k); w == "struct" || w == "interface" {
					if m, ok := closeOf[k]; ok {
						k = m
						continue
					}
				}
				open = k
			}
			if open >= 0 {
				break
			}
		}
		if open < 0 {
			continue
		}
		clos, ok := closeOf[open]
		if !ok {
			continue // an unmatched body brace spans nothing
		}
		lo, _ := lineBounds(buf, i)
		hi, _ := lineBounds(buf, clos)
		out = append(out, goDecl{name: name, lo: lo, hi: hi})
	}
	return out
}

// --- mapping and paint ------------------------------------------------------

// heatBucket bins a function's share of the capture's total samples:
// half or more is the hottest strip, then a quarter, a twentieth, and
// anything smaller warmest.
func heatBucket(self, total uint64) int {
	if total == 0 {
		return 0
	}
	switch p := self * 100 / total; {
	case p >= 50:
		return 3
	case p >= 25:
		return 2
	case p >= 5:
		return 1
	}
	return 0
}

// mapHeat builds a buffer's gutter spans: every declaration whose
// profile name has self samples, bucketed by share of the total. mapped
// is the count of profile functions a decl answered — a buffer from
// another package (or a non-.go path) maps nothing.
func mapHeat(buf []byte, path string, h *heatData) (spans []heatSpan, mapped int) {
	if h == nil || len(buf) == 0 || !isGoPath(path) {
		return nil, 0
	}
	cls := classifyGo(buf)
	seen := make(map[string]bool)
	for _, d := range scanGoDecls(buf, cls) {
		self, ok := h.fns[d.name]
		if !ok || seen[d.name] {
			continue
		}
		seen[d.name] = true
		spans = append(spans, heatSpan{lo: d.lo, hi: d.hi, bucket: heatBucket(self, h.samples)})
	}
	return spans, len(seen)
}

// heatAt is the drawn-line lookup: the bucket of the span holding the
// line that starts at byte offset s, or -1.
func heatAt(spans []heatSpan, s int) int {
	for _, hs := range spans {
		if s >= hs.lo && s <= hs.hi {
			return hs.bucket
		}
	}
	return -1
}

// heatMarker is the mapping receipt's text — kept a pure function so the
// host tests pin the exact string the gate greps.
func heatMarker(h *heatData, mapped int) string {
	top := h.top
	if top == "" {
		top = "-"
	}
	var pct uint64
	if h.samples > 0 {
		pct = h.topN * 100 / h.samples
	}
	return markerHeat + "fns=" + vi.Itoa64(int64(len(h.fns))) +
		" mapped=" + vi.Itoa64(int64(mapped)) +
		" samples=" + vi.Itoa64(int64(h.samples)) +
		" top=" + top + " pct=" + vi.Itoa64(int64(pct))
}

// reportHeat prints the mapping receipt on its edges: recomputes after an
// edit produce the same text and are not re-announced.
func (e *editor) reportHeat(mapped int) {
	m := heatMarker(e.heat, mapped)
	if m == e.heatLast {
		return
	}
	e.heatLast = m
	vi.ConsoleLine(m)
}

// gutter is draw()'s entry: the active doc's spans, computed — and the
// marker reported — once per buffer state. load() and every splice clear
// heatDone so the next paint remaps against the real bytes.
func (e *editor) gutter() []heatSpan {
	if e.heatDone {
		return e.heatSpans
	}
	spans, mapped := mapHeat(e.buf, e.path, e.heat)
	e.heatSpans = spans
	e.heatDone = true
	if e.heat != nil {
		e.reportHeat(mapped)
	}
	return spans
}

// loadHeat is the --prof= open-time read. The refusals are named: `rc=`
// when the file does not read, `too-large` past vi.MaxFileBytes, `bad
// line=<n>` for a line that is not WriteFolded's shape. A refused file
// leaves e.heat nil — no gutter, no marker beyond the refusal.
func (e *editor) loadHeat(path string) {
	b, rc := heatRead(path)
	if rc < 0 {
		vi.ConsoleLine(markerHeat + "rc=" + vi.Itoa64(rc))
		return
	}
	if len(b) >= vi.MaxFileBytes {
		vi.ConsoleLine(markerHeat + "too-large")
		return
	}
	h, bad := parseFolded(b)
	if h == nil {
		vi.ConsoleLine(markerHeat + "bad line=" + vi.Itoa64(int64(bad)))
		return
	}
	e.heat = h
}
