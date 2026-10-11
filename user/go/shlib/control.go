// GOSH's M19 scripting front-end: the pure parser half of the shell-scripting
// port (slice 4 of #1450). Every construct here is a faithful port of
// user/src/lib/script.zig, the library SH.BIN's M19 support was built on, so
// the retargeted gates assert the same semantics rather than a new dialect.
//
// Pure code: no syscalls, no Host. The evaluator lives in shell.go; this file
// only turns text into structures, exactly as script.zig did.
package shlib

import (
	"strings"

	"virelai/vsys"
)

// Bounds, mirroring script.zig / sh.zig. Every one of these is a refusal
// boundary rather than a silent truncation: past it the line reports and the
// status is non-zero.
const (
	chainMax       = 4   // script.zig chain_max (segments, so ops = max-1)
	funcMax        = 8   // script.zig func_max
	funcCmdsMax    = 8   // script.zig func_cmds_max
	funcArgMax     = 4   // script.zig func_arg_max
	funcNameMax    = 32  // script.zig func_name_max
	funcArgNameMax = 16  // script.zig func_arg_name_max
	caseArmMax     = 8   // script.zig case_arm_max
	bodyCmdsMax    = 16  // sh.zig runBody's [16] command buffer
	runDepthMax    = 8   // sh.zig runLine's depth guard
	sourceDepthMax = 4   // sh.zig runSource's depth guard
	whileIterMax   = 256 // sh.zig runWhile's iteration cap
	arithNestMax   = 32  // recursion guard for a pathological `((((...`
)

// isSpaceByte mirrors script.zig isSpace: horizontal whitespace only, so a
// line split at `;` and one split at a newline behave the same way.
func isSpaceByte(c byte) bool { return c == ' ' || c == '\t' }

func trimStart(s string) string {
	i := 0
	for i < len(s) && isSpaceByte(s[i]) {
		i++
	}
	return s[i:]
}

func trimEnd(s string) string {
	end := len(s)
	for end > 0 && isSpaceByte(s[end-1]) {
		end--
	}
	return s[:end]
}

func trimSpace(s string) string { return trimStart(trimEnd(s)) }

// trimSemi trims surrounding whitespace and any trailing `;` separators:
// construct bodies sit before `; fi` / `; done`, so the boundary keeps a
// stray `;` (script.zig trimSemi).
func trimSemi(s string) string {
	v := trimSpace(s)
	for len(v) > 0 && v[len(v)-1] == ';' {
		v = trimSpace(v[:len(v)-1])
	}
	return v
}

// ---------------------------------------------------------------------------
// Chains: `;`, `&&`, `||` (equal precedence, left to right).
// ---------------------------------------------------------------------------

type chainOp int

const (
	opSeq chainOp = iota // ;
	opAnd                // &&
	opOr                 // ||
)

// chainSplit splits a line into `;`/`&&`/`||`-separated segments. Operators
// inside quotes or escaped are literal, and the result is always at least one
// segment, so a caller can run segments[0] unconditionally.
//
// Deliberate divergence from script.zig, and a fix rather than a change of
// dialect: the reference toggled BOTH quote flags on any quote byte, so a
// single apostrophe inside a double-quoted word (`echo "it's here" && echo x`)
// left it believing a single-quote region had opened and stopped splitting
// chains for the rest of the line. This scanner tracks the two quote states
// properly. It is the same set of operators and the same precedence either
// way; only the quoted case differs, and there the reference was wrong.
func chainSplit(line string) (segs []string, ops []chainOp, tooMany bool) {
	var inDouble, inSingle, esc bool
	start := 0
	for i := 0; i < len(line); {
		c := line[i]
		if esc {
			esc = false
			i++
			continue
		}
		if c == '\\' && !inSingle {
			esc = true
			i++
			continue
		}
		if c == '\'' && !inDouble {
			inSingle = !inSingle
			i++
			continue
		}
		if c == '"' && !inSingle {
			inDouble = !inDouble
			i++
			continue
		}
		if inSingle || inDouble {
			i++
			continue
		}
		var op chainOp
		width := 1
		switch {
		case c == '&' && i+1 < len(line) && line[i+1] == '&':
			op, width = opAnd, 2
		case c == '|' && i+1 < len(line) && line[i+1] == '|':
			op, width = opOr, 2
		case c == ';':
			op = opSeq
		default:
			i++
			continue
		}
		if len(segs) >= chainMax-1 {
			return nil, nil, true
		}
		segs = append(segs, trimSpace(line[start:i]))
		ops = append(ops, op)
		start = i + width
		i += width
	}
	return append(segs, trimSpace(line[start:])), ops, false
}

// ---------------------------------------------------------------------------
// `$(( ))` arithmetic: recursive descent over + - * / % and parentheses.
// ---------------------------------------------------------------------------

type arithTok int

const (
	arNum arithTok = iota
	arPlus
	arMinus
	arStar
	arSlash
	arPercent
	arLParen
	arRParen
	arEOF
)

type arithLexer struct {
	src  string
	pos  int
	tok  arithTok
	val  int64
	nest int
}

func (l *arithLexer) advance() {
	for l.pos < len(l.src) && isSpaceByte(l.src[l.pos]) {
		l.pos++
	}
	if l.pos >= len(l.src) {
		l.tok = arEOF
		return
	}
	c := l.src[l.pos]
	switch {
	case c == '+':
		l.tok, l.pos = arPlus, l.pos+1
	case c == '-':
		l.tok, l.pos = arMinus, l.pos+1
	case c == '*':
		l.tok, l.pos = arStar, l.pos+1
	case c == '/':
		l.tok, l.pos = arSlash, l.pos+1
	case c == '%':
		l.tok, l.pos = arPercent, l.pos+1
	case c == '(':
		l.tok, l.pos = arLParen, l.pos+1
	case c == ')':
		l.tok, l.pos = arRParen, l.pos+1
	case c >= '0' && c <= '9':
		var v int64
		for l.pos < len(l.src) && l.src[l.pos] >= '0' && l.src[l.pos] <= '9' {
			v = v*10 + int64(l.src[l.pos]-'0')
			l.pos++
		}
		l.tok, l.val = arNum, v
	default:
		// Reference behaviour: anything unrecognised ends the expression.
		l.tok = arEOF
	}
}

func (l *arithLexer) next() arithTok {
	t := l.tok
	l.advance()
	return t
}

func arithExpr(l *arithLexer) int64 {
	left := arithTerm(l)
	for {
		switch l.tok {
		case arPlus:
			l.next()
			left += arithTerm(l)
		case arMinus:
			l.next()
			left -= arithTerm(l)
		default:
			return left
		}
	}
}

func arithTerm(l *arithLexer) int64 {
	left := arithFactor(l)
	for {
		switch l.tok {
		case arStar:
			l.next()
			left *= arithFactor(l)
		case arSlash:
			l.next()
			r := arithFactor(l)
			if r != 0 {
				left /= r
			} else {
				left = 0 // division by zero is 0, never a trap
			}
		case arPercent:
			l.next()
			r := arithFactor(l)
			if r != 0 {
				left %= r
			} else {
				left = 0
			}
		default:
			return left
		}
	}
}

func arithFactor(l *arithLexer) int64 {
	switch l.tok {
	case arMinus:
		l.next()
		return -arithFactor(l)
	case arPlus:
		l.next()
		return arithFactor(l)
	case arNum:
		v := l.val
		l.next()
		return v
	case arLParen:
		if l.nest >= arithNestMax {
			return 0
		}
		l.nest++
		l.next()
		v := arithExpr(l)
		l.next() // consume ')'
		l.nest--
		return v
	}
	return 0
}

// evalArith evaluates a bare arithmetic expression (no `$(( ))` wrapper).
func evalArith(expr string) int64 {
	l := &arithLexer{src: expr}
	l.advance()
	return arithExpr(l)
}

// arithExpand splices the FIRST `$((expr))` in line into its decimal result.
// The line is returned unchanged when there is no complete expansion — the
// reference's contract, including for `$((broken`.
func arithExpand(line string) string {
	at := strings.Index(line, "$((")
	if at < 0 {
		return line
	}
	exprStart := at + 3
	depth := 0
	i := exprStart
	for ; i+1 < len(line); i++ {
		if line[i] == '(' {
			depth++
		} else if line[i] == ')' {
			if depth == 0 && line[i+1] == ')' {
				break
			}
			if depth > 0 {
				depth--
			}
		}
	}
	if i+1 >= len(line) {
		return line
	}
	expr := line[exprStart:i]
	if len(expr) == 0 {
		return line
	}
	num := vsys.Itoa64(evalArith(expr))
	return line[:at] + num + line[i+2:]
}

// ---------------------------------------------------------------------------
// Command substitution: locate the first `$(...)` (non-nested).
// ---------------------------------------------------------------------------

type cmdSubst struct {
	prefix string
	inner  string
	suffix string
}

// locateCommandSubst finds the first `$(cmd)` in line. `$((...))` is
// arithmetic and skipped; a nested `$(`, an unclosed one, or an empty one
// reports ok=false (the reference refuses nested rather than guessing).
func locateCommandSubst(line string) (cmdSubst, bool) {
	search := 0
	at := 0
	for {
		rel := strings.Index(line[search:], "$(")
		if rel < 0 {
			return cmdSubst{}, false
		}
		at = search + rel
		if at+2 < len(line) && line[at+2] == '(' {
			// `$((` — arithmetic, not substitution.
			search = at + 3
			continue
		}
		break
	}
	start := at + 2
	depth := 1
	i := start
	for ; i < len(line) && depth > 0; i++ {
		if line[i] == '$' && i+1 < len(line) && line[i+1] == '(' {
			return cmdSubst{}, false // nested: refused
		}
		if line[i] == '(' {
			depth++
		} else if line[i] == ')' {
			depth--
		}
	}
	if depth != 0 {
		return cmdSubst{}, false
	}
	end := i - 1
	inner := trimSpace(line[start:end])
	if len(inner) == 0 {
		return cmdSubst{}, false
	}
	return cmdSubst{prefix: line[:at], inner: inner, suffix: line[end+1:]}, true
}

// ---------------------------------------------------------------------------
// Whole-word keyword search + construct parsing.
// ---------------------------------------------------------------------------

// findKeyword finds a whole-word keyword in text: boundaries are the string
// ends, whitespace, or `;` (script.zig findKeyword), so `fi` inside `fixture`
// is not the `fi` keyword.
func findKeyword(text, kw string) (int, bool) {
	for i := 0; i+len(kw) <= len(text); i++ {
		if text[i:i+len(kw)] != kw {
			continue
		}
		if i > 0 && !isSpaceByte(text[i-1]) && text[i-1] != ';' {
			continue
		}
		after := i + len(kw)
		if after < len(text) && !isSpaceByte(text[after]) && text[after] != ';' {
			continue
		}
		return i, true
	}
	return 0, false
}

// splitCommands splits a `;`-separated body into trimmed, non-empty commands,
// bounded to bodyCmdsMax (sh.zig runBody's buffer). Past the bound the
// reference ran the first 16 and silently dropped the rest; here `tooMany`
// reports it and the body does not run at all (the same loud shape the chain,
// while and source bounds use — see shell.go's refusal notes).
func splitCommands(body string) (cmds []string, tooMany bool) {
	start := 0
	for i := 0; i <= len(body); i++ {
		if i == len(body) || body[i] == ';' {
			if cmd := trimSpace(body[start:i]); cmd != "" {
				if len(cmds) >= bodyCmdsMax {
					return cmds, true
				}
				cmds = append(cmds, cmd)
			}
			start = i + 1
		}
	}
	return cmds, false
}

// stripPrefix removes a leading keyword and one following separator.
func stripPrefix(line, kw string) string {
	if len(line) <= len(kw) {
		return line[len(line):]
	}
	if !strings.HasPrefix(line, kw) {
		return line
	}
	if line[len(kw)] == ' ' || line[len(kw)] == '\t' {
		return line[len(kw)+1:]
	}
	return line[len(kw):]
}

// skipWordAndSpace advances past the keyword's trailing whitespace/`;` run.
func skipWordAndSpace(s string) int {
	i := 0
	for i < len(s) && s[i] != ' ' && s[i] != ';' {
		i++
	}
	for i < len(s) && (isSpaceByte(s[i]) || s[i] == ';') {
		i++
	}
	return i
}

// ifStmt is a parsed `if COND; then BODY; [else BODY;] fi`.
type ifStmt struct {
	cond     string
	thenBody string
	elseBody string
	hasElse  bool
}

func parseIf(line string) (ifStmt, bool) {
	if !strings.HasPrefix(line, "if") {
		return ifStmt{}, false
	}
	rest := stripPrefix(line, "if")
	thenPos, ok := findKeyword(rest, "then")
	if !ok {
		return ifStmt{}, false
	}
	condEnd := thenPos
	for condEnd > 0 && (isSpaceByte(rest[condEnd-1]) || rest[condEnd-1] == ';') {
		condEnd--
	}
	cond := trimSemi(rest[:condEnd])
	if cond == "" {
		return ifStmt{}, false
	}
	afterThen := rest[thenPos+4:]
	thenRest := afterThen[skipWordAndSpace(afterThen):]

	elsePos, hasElse := findKeyword(thenRest, "else")
	fiPos, hasFi := findKeyword(thenRest, "fi")
	if !hasFi {
		return ifStmt{}, false
	}
	if hasElse {
		if elsePos > fiPos {
			return ifStmt{}, false // malformed ordering
		}
		// elseStart is an index into thenRest, so the skip offset has to be
		// added back onto elsePos rather than applied to a re-sliced string.
		elseStart := elsePos + 4 + skipWordAndSpace(thenRest[elsePos+4:])
		return ifStmt{
			cond:     cond,
			thenBody: trimSemi(thenRest[:elsePos]),
			elseBody: trimSemi(thenRest[elseStart:fiPos]),
			hasElse:  true,
		}, true
	}
	return ifStmt{cond: cond, thenBody: trimSemi(thenRest[:fiPos])}, true
}

// forStmt is a parsed `for VAR in W1 W2 ...; do BODY; done`.
type forStmt struct {
	varName string
	words   []string
	body    string
}

// forWordMax mirrors For.words' [16] bound in script.zig.
const forWordMax = 16

// parseFor reports `tooMany` when the word list is longer than forWordMax:
// the reference filled its [16] array and dropped the tail silently, so a
// `for w in a b c …` past the bound ran a different loop than the one written.
func parseFor(line string) (forStmt, bool, bool) {
	if !strings.HasPrefix(line, "for") {
		return forStmt{}, false, false
	}
	rest := stripPrefix(line, "for")
	inPos, ok := findKeyword(rest, "in")
	if !ok {
		return forStmt{}, false, false
	}
	varName := trimSpace(rest[:inPos])
	if varName == "" {
		return forStmt{}, false, false
	}
	afterIn := rest[inPos+2:]
	doPos, ok := findKeyword(afterIn, "do")
	if !ok {
		return forStmt{}, false, false
	}
	wordsStr := afterIn[:doPos]
	afterDo := afterIn[doPos+2:]
	bodyAndDone := afterDo[skipWordAndSpace(afterDo):]
	donePos, ok := findKeyword(bodyAndDone, "done")
	if !ok {
		return forStmt{}, false, false
	}
	st := forStmt{varName: varName, body: trimSemi(bodyAndDone[:donePos])}
	ws := 0
	for ws < len(wordsStr) {
		for ws < len(wordsStr) && (isSpaceByte(wordsStr[ws]) || wordsStr[ws] == ';') {
			ws++
		}
		if ws >= len(wordsStr) {
			break
		}
		we := ws
		for we < len(wordsStr) && !isSpaceByte(wordsStr[we]) && wordsStr[we] != ';' {
			we++
		}
		if len(st.words) >= forWordMax {
			return forStmt{}, false, true
		}
		st.words = append(st.words, wordsStr[ws:we])
		ws = we
	}
	return st, true, false
}

// whileStmt is a parsed `while COND; do BODY; done`.
type whileStmt struct {
	cond string
	body string
}

func parseWhile(line string) (whileStmt, bool) {
	if !strings.HasPrefix(line, "while") {
		return whileStmt{}, false
	}
	rest := stripPrefix(line, "while")
	doPos, ok := findKeyword(rest, "do")
	if !ok {
		return whileStmt{}, false
	}
	cond := trimSemi(rest[:doPos])
	if cond == "" {
		return whileStmt{}, false
	}
	afterDo := rest[doPos+2:]
	bodyAndDone := afterDo[skipWordAndSpace(afterDo):]
	donePos, ok := findKeyword(bodyAndDone, "done")
	if !ok {
		return whileStmt{}, false
	}
	return whileStmt{cond: cond, body: trimSemi(bodyAndDone[:donePos])}, true
}

// ---------------------------------------------------------------------------
// Functions: `fn NAME(a, b) { cmd1; cmd2 }`.
// ---------------------------------------------------------------------------

// funcDef is a parsed definition; the shell turns it into a callable Func.
type funcDef struct {
	name     string
	argNames []string
	body     string
}

// parseFuncDef parses the text AFTER the `fn ` prefix (script.zig
// parseFuncDef): NAME, an optional parenthesised argument list, then a
// `{ ... }` body. It reports false for a missing name, a missing body, or an
// over-long name.
func parseFuncDef(text string) (funcDef, bool) {
	i := 0
	for i < len(text) && text[i] != ' ' && text[i] != '(' && text[i] != '{' {
		i++
	}
	name := text[:i]
	if name == "" || len(name) > funcNameMax {
		return funcDef{}, false
	}
	def := funcDef{name: name}
	if i < len(text) && text[i] == '(' {
		i++
		for i < len(text) && text[i] != ')' && len(def.argNames) < funcArgMax {
			for i < len(text) && (text[i] == ' ' || text[i] == ',') {
				i++
			}
			aStart := i
			for i < len(text) && text[i] != ' ' && text[i] != ',' && text[i] != ')' {
				i++
			}
			if aname := text[aStart:i]; aname != "" {
				if len(aname) > funcArgNameMax {
					aname = aname[:funcArgNameMax]
				}
				def.argNames = append(def.argNames, aname)
			}
		}
		if i < len(text) && text[i] == ')' {
			i++
		}
	}
	for i < len(text) && text[i] != '{' {
		i++
	}
	if i >= len(text) {
		return funcDef{}, false
	}
	start := i + 1
	for start < len(text) && isSpaceByte(text[start]) {
		start++
	}
	end := -1
	for j := len(text) - 1; j >= start; j-- {
		if text[j] == '}' {
			end = j
			break
		}
	}
	if end >= 0 {
		def.body = trimSpace(text[start:end])
	} else {
		def.body = trimSpace(text[start:])
	}
	if def.body == "" {
		return funcDef{}, false
	}
	return def, true
}

// isFuncDefLine reports whether a line is an `fn ...` definition
// (shell.zig Shell.isFuncDef). A bare `fn` is a definition attempt, so a
// user typing it gets `fn: bad definition` rather than a command-not-found.
func isFuncDefLine(line string) bool {
	if !strings.HasPrefix(line, "fn") {
		return false
	}
	if len(line) == 2 {
		return true
	}
	return line[2] == ' ' || line[2] == '\t' || line[2] == '('
}

// progFunc is a defined function: its name, declared argument names, and the
// body pre-split into commands (script.zig's Func). The body is fixed at
// definition time, exactly as the reference's FuncTable.define did.
type progFunc struct {
	name     string
	argNames []string
	body     []string
}

// funcTable is the bounded function registry (funcMax entries; redefinition
// always succeeds and replaces in place).
type funcTable struct {
	funcs []*progFunc
}

func (t *funcTable) find(name string) *progFunc {
	for _, f := range t.funcs {
		if f.name == name {
			return f
		}
	}
	return nil
}

// define installs def, replacing a same-named entry. It reports false for an
// empty body or a full table (matching script.zig FuncTable.define).
func (t *funcTable) define(def funcDef) bool {
	body, tooMany := splitCommands(def.body)
	// REFUSED, not truncated: the reference kept its first func_cmds_max
	// commands and dropped the rest, so a long function silently did part of
	// what it said. The caller reports `fn: bad definition`.
	if tooMany || len(body) == 0 || len(body) > funcCmdsMax {
		return false
	}
	f := t.find(def.name)
	if f == nil {
		if len(t.funcs) >= funcMax {
			return false
		}
		f = &progFunc{name: def.name}
		t.funcs = append(t.funcs, f)
	}
	f.argNames = def.argNames
	f.body = body
	return true
}

// ---------------------------------------------------------------------------
// M49 SD3 case: `case SUBJECT in PAT) BODY;; PAT2) BODY2;; esac`.
// ---------------------------------------------------------------------------

type caseArm struct {
	pattern string
	body    string
}

type caseStmt struct {
	subject string
	arms    []caseArm
}

// parseCase parses a bounded single-line `case`. Arms are split on `;;`; a
// pattern may hold `|` alternatives. It reports false for a malformed line or
// one with no arms (script.zig parseCase), and `tooMany` when the arm list is
// longer than caseArmMax: the reference stopped filling its [8] array and
// silently ignored every arm past it, so the `case` could not match what was
// written.
func parseCase(line string) (caseStmt, bool, bool) {
	if !strings.HasPrefix(line, "case") {
		return caseStmt{}, false, false
	}
	rest := stripPrefix(line, "case")
	inPos, ok := findKeyword(rest, "in")
	if !ok {
		return caseStmt{}, false, false
	}
	subject := trimSpace(rest[:inPos])
	if subject == "" {
		return caseStmt{}, false, false
	}
	afterIn := rest[inPos+2:]
	esacPos, ok := findKeyword(afterIn, "esac")
	if !ok {
		return caseStmt{}, false, false
	}
	armsText := trimSemi(afterIn[:esacPos])

	var c caseStmt
	c.subject = subject
	i := 0
	for i < len(armsText) {
		for i < len(armsText) && (armsText[i] == ';' || isSpaceByte(armsText[i])) {
			i++
		}
		if i >= len(armsText) {
			break
		}
		rel := strings.IndexByte(armsText[i:], ')')
		if rel < 0 {
			break
		}
		if len(c.arms) >= caseArmMax {
			return caseStmt{}, false, true
		}
		pattern := trimSpace(armsText[i : i+rel])
		bodyStart := i + rel + 1
		sep := strings.Index(armsText[bodyStart:], ";;")
		bodyEnd := len(armsText)
		if sep >= 0 {
			bodyEnd = bodyStart + sep
		}
		c.arms = append(c.arms, caseArm{
			pattern: pattern,
			body:    trimSemi(armsText[bodyStart:bodyEnd]),
		})
		if sep < 0 {
			break
		}
		i = bodyStart + sep + 2
	}
	if len(c.arms) == 0 {
		return caseStmt{}, false, false
	}
	return c, true, false
}

// caseMatch reports whether pattern matches subject: `|` separates
// alternatives and each alternative is fnmatch-style. The single pattern `*`
// matches everything (script.zig caseMatch via pipe.globMatch).
func caseMatch(pattern, subject string) bool {
	return caseMatchFlagged(pattern, nil, subject)
}

// caseMatchFlagged is caseMatch over a pattern whose bytes carry
// glob-active flags (M98a): a `|` or metacharacter that arrived marked
// literal — quoted, or spliced in by $(...) — is text, not an alternative
// separator or a wildcard.
func caseMatchFlagged(pattern string, act []bool, subject string) bool {
	for i := 0; i <= len(pattern); {
		j := i
		for j < len(pattern) && !(pattern[j] == '|' && active(act, j)) {
			j++
		}
		lo, hi := i, j
		for lo < hi && isSpaceByte(pattern[lo]) {
			lo++
		}
		for hi > lo && isSpaceByte(pattern[hi-1]) {
			hi--
		}
		var aflags []bool
		if act != nil {
			aflags = act[lo:hi]
		}
		if lo < hi && globMatchFlagged(pattern[lo:hi], aflags, subject) {
			return true
		}
		if j >= len(pattern) {
			break
		}
		i = j + 1
	}
	return false
}

// globMatch is the fnmatch-style matcher of pipe.zig globMatch: `*` matches
// any run (including empty), `?` exactly one byte, `[...]` a class with
// ranges and a leading `!`/`^` negation, and any other byte is literal.
// Iterative with a single backtrack point, so a pattern like `a*a*a*b`
// against a long subject stays linear rather than exponential.
func globMatch(pattern, subject string) bool {
	return globMatchFlagged(pattern, nil, subject)
}

// globMatchFlagged is globMatch over a pattern whose bytes carry
// glob-active flags (M98a): a byte with act[i]==false compares literally
// even when it spells `*`, `?` or `[` — quoting rules live in the flags,
// so the matcher's semantics stay identical for the all-active case.
func globMatchFlagged(pattern string, act []bool, subject string) bool {
	p, n := 0, 0
	starP, starN := -1, 0
	for n < len(subject) {
		consumed, classMiss := false, false
		if p < len(pattern) && active(act, p) {
			switch pattern[p] {
			case '*':
				starP, starN = p, n
				p++
				consumed = true
			case '?':
				p++
				n++
				consumed = true
			case '[':
				if np, ok := globClassFlagged(pattern, act, p, subject[n]); ok {
					p = np
					n++
					consumed = true
				} else {
					// A class that did not match is not a literal `[`
					// fallback — pipe.zig treats it as a miss and
					// backtracks only through `*`.
					classMiss = true
				}
			}
		}
		if consumed {
			continue
		}
		if !classMiss && p < len(pattern) && pattern[p] == subject[n] {
			p++
			n++
			continue
		}
		if starP >= 0 {
			p = starP + 1
			starN++
			n = starN
			continue
		}
		return false
	}
	for p < len(pattern) && pattern[p] == '*' && active(act, p) {
		p++
	}
	return p == len(pattern)
}

// globClassFlagged matches subject byte c against the `[...]` class at
// pattern[at] and returns the index past the class. ok=false means "no
// match": a class whose bytes do not contain c, and also a malformed one
// (`[` with no `]`). That second case is pipe.zig's behaviour and is NOT
// the same as treating `[` as a literal, so the pattern `[` matches
// nothing at all. Inactive bytes are literal class members: they cannot
// negate, close, or form a range.
func globClassFlagged(pattern string, act []bool, at int, c byte) (int, bool) {
	i := at + 1
	if i >= len(pattern) {
		return 0, false
	}
	negate := false
	if active(act, i) && (pattern[i] == '!' || pattern[i] == '^') {
		negate = true
		i++
	}
	matched := false
	first := true
	for i < len(pattern) {
		if pattern[i] == ']' && active(act, i) && !first {
			if matched != negate {
				return i + 1, true
			}
			return 0, false
		}
		first = false
		if i+2 < len(pattern) && pattern[i+1] == '-' && active(act, i+1) &&
			(pattern[i+2] != ']' || !active(act, i+2)) {
			if c >= pattern[i] && c <= pattern[i+2] {
				matched = true
			}
			i += 3
			continue
		}
		if pattern[i] == c {
			matched = true
		}
		i++
	}
	return 0, false
}
