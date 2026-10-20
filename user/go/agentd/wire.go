// The JSON-Lines wire (ADR 0044 D1): an owned flat-object reader and
// writer. encoding/json is deliberately NOT imported — the reflect-based
// decoder alone pushes a guest ELF past the 2,097,152-byte ceiling
// (ADR 0042 §1). Host tests use encoding/json as the differential oracle.
package main

import (
	"strings"
	"unicode/utf8"

	"virelai/vi"
)

// Framing limits (D1): the line bound includes the LF itself; the pending
// buffer is the pipelined-input bound.
const (
	lineMaxPreAuth = 256
	lineMaxSession = 8192
	pendingMax     = 16 * 1024
)

// connIO is the socket seam a session reads and writes. *vi.Conn satisfies
// it on the guest; host tests substitute a scripted transport.
type connIO interface {
	Recv(p []byte) (int, error)
	Send(p []byte) (int, error)
	SetRecvDeadline(ns int64)
}

// Read outcomes for readLine: the caller maps them onto session results.
const (
	readOK       = iota
	readPeerGone // FIN/RST consumed
	readTimeout  // the recv deadline expired
	readTooLong  // a line exceeded its byte limit (fatal)
	readIOErr    // any other transport error
)

// lineReader owns the pipelined-input buffer. Lines are answered strictly
// in order; a complete line already buffered is returned before any recv.
type lineReader struct {
	c   connIO
	buf []byte
}

func newLineReader(c connIO) *lineReader {
	return &lineReader{c: c}
}

// readLine returns one line without its terminator (a CR before the LF is
// stripped), or a read* outcome. limit counts the LF: a line whose LF sits
// past limit, or a pending buffer that already cannot fit its terminator
// inside limit, is readTooLong and the bytes are discarded unparsed.
func (r *lineReader) readLine(limit int) ([]byte, int) {
	for {
		if i := indexByte(r.buf, '\n'); i >= 0 {
			if i+1 > limit {
				r.buf = r.buf[:0]
				return nil, readTooLong
			}
			line := r.buf[:i]
			if i > 0 && r.buf[i-1] == '\r' {
				line = r.buf[:i-1]
			}
			out := make([]byte, len(line))
			copy(out, line)
			r.buf = append(r.buf[:0], r.buf[i+1:]...)
			return out, readOK
		}
		if len(r.buf) >= limit {
			// The line is already too long: even if the next byte were LF
			// it could not fit inside the limit.
			r.buf = r.buf[:0]
			return nil, readTooLong
		}
		var chunk [vi.TCPPayloadMax]byte
		n, err := r.c.Recv(chunk[:])
		if err != nil {
			r.buf = r.buf[:0]
			switch {
			case err == vi.ErrPeerGone || err == vi.ErrConnClosed:
				return nil, readPeerGone
			case err.Error() == "ETIMEDOUT":
				return nil, readTimeout
			default:
				return nil, readIOErr
			}
		}
		if n > 0 {
			r.buf = append(r.buf, chunk[:n]...)
			if len(r.buf) > pendingMax {
				r.buf = r.buf[:0]
				return nil, readTooLong
			}
		}
	}
}

// sendLine writes one response line in full. The Conn.Send contract
// already chunks at the kernel's segment bound and reports confirmed
// counts, so a partial write surfaces as an error, never a truncation.
func sendLine(c connIO, line string) error {
	_, err := c.Send(append([]byte(line), '\n'))
	return err
}

func indexByte(b []byte, c byte) int {
	for i, x := range b {
		if x == c {
			return i
		}
	}
	return -1
}

// --- the flat-grammar reader ------------------------------------------------

// Field kinds under the flat grammar (D1): a value may only be a string,
// an unsigned integer no larger than 2^31-1, or a boolean. M139b adds
// fArr for ui.input's events — the only verb that admits an array; the
// elements still must be flat objects and are validated per-verb.
const (
	fStr = iota
	fInt
	fBool
	fArr
)

const (
	jObj = iota
	jArr
	jStr
	jNum
	jTrue
	jFalse
	jNull
)

type jmember struct {
	key string
	val jval
}

type jval struct {
	kind  int
	str   string    // jStr: decoded; jNum/jTrue/jFalse/jNull: literal text
	membs []jmember // jObj only
	items []jval    // jArr only
}

// intMax is the flat grammar's integer bound (2^31 - 1).
const intMax = 2147483647

// jsonDepth bounds nesting so a hostile body cannot recurse the parser.
const jsonDepth = 32

// parseValue is a strict RFC 8259 parser. It returns (value, rest, ok):
// ok=false means the input is not well-formed JSON.
func parseValue(b []byte) (jval, []byte, bool) {
	return parseValueDepth(b, jsonDepth)
}

func parseValueDepth(b []byte, depth int) (jval, []byte, bool) {
	b = skipWS(b)
	if len(b) == 0 || depth <= 0 {
		return jval{}, b, false
	}
	switch b[0] {
	case '{':
		return parseObject(b[1:], depth-1)
	case '[':
		return parseArray(b[1:], depth-1)
	case '"':
		s, rest, ok := parseString(b)
		if !ok {
			return jval{}, b, false
		}
		return jval{kind: jStr, str: s}, rest, true
	case 't':
		if hasLit(b, "true") {
			return jval{kind: jTrue, str: "true"}, b[4:], true
		}
	case 'f':
		if hasLit(b, "false") {
			return jval{kind: jFalse, str: "false"}, b[5:], true
		}
	case 'n':
		if hasLit(b, "null") {
			return jval{kind: jNull, str: "null"}, b[4:], true
		}
	default:
		if b[0] == '-' || (b[0] >= '0' && b[0] <= '9') {
			return parseNumber(b)
		}
	}
	return jval{}, b, false
}

func hasLit(b []byte, lit string) bool {
	return len(b) >= len(lit) && string(b[:len(lit)]) == lit
}

func skipWS(b []byte) []byte {
	for len(b) > 0 && (b[0] == ' ' || b[0] == '\t' || b[0] == '\r' || b[0] == '\n') {
		b = b[1:]
	}
	return b
}

func parseObject(b []byte, depth int) (jval, []byte, bool) {
	var v jval
	v.kind = jObj
	b = skipWS(b)
	if len(b) > 0 && b[0] == '}' {
		return v, b[1:], true
	}
	for {
		b = skipWS(b)
		if len(b) == 0 || b[0] != '"' {
			return jval{}, b, false
		}
		key, rest, ok := parseString(b)
		if !ok {
			return jval{}, b, false
		}
		b = skipWS(rest)
		if len(b) == 0 || b[0] != ':' {
			return jval{}, b, false
		}
		val, rest, ok := parseValueDepth(b[1:], depth)
		if !ok {
			return jval{}, b, false
		}
		v.membs = append(v.membs, jmember{key: key, val: val})
		b = skipWS(rest)
		if len(b) == 0 {
			return jval{}, b, false
		}
		if b[0] == '}' {
			return v, b[1:], true
		}
		if b[0] != ',' {
			return jval{}, b, false
		}
		b = b[1:]
	}
}

func parseArray(b []byte, depth int) (jval, []byte, bool) {
	v := jval{kind: jArr}
	b = skipWS(b)
	if len(b) > 0 && b[0] == ']' {
		return v, b[1:], true
	}
	for {
		item, rest, ok := parseValueDepth(b, depth)
		if !ok {
			return jval{}, b, false
		}
		v.items = append(v.items, item)
		b = skipWS(rest)
		if len(b) == 0 {
			return jval{}, b, false
		}
		if b[0] == ']' {
			return v, b[1:], true
		}
		if b[0] != ',' {
			return jval{}, b, false
		}
		b = skipWS(b[1:])
	}
}

// parseString decodes one RFC 8259 string: the seven two-byte escapes,
// \uXXXX with surrogate pairs, and no unescaped control bytes. A lone
// surrogate decodes to U+FFFD — the same answer encoding/json gives.
func parseString(b []byte) (string, []byte, bool) {
	if len(b) == 0 || b[0] != '"' {
		return "", b, false
	}
	var sb strings.Builder
	i := 1
	for i < len(b) {
		c := b[i]
		switch {
		case c == '"':
			return sb.String(), b[i+1:], true
		case c == '\\':
			if i+1 >= len(b) {
				return "", b, false
			}
			switch e := b[i+1]; e {
			case '"', '\\', '/':
				sb.WriteByte(e)
				i += 2
			case 'b':
				sb.WriteByte('\b')
				i += 2
			case 'f':
				sb.WriteByte('\f')
				i += 2
			case 'n':
				sb.WriteByte('\n')
				i += 2
			case 'r':
				sb.WriteByte('\r')
				i += 2
			case 't':
				sb.WriteByte('\t')
				i += 2
			case 'u':
				r, n, ok := parseUnicode(b[i:])
				if !ok {
					return "", b, false
				}
				sb.WriteRune(r)
				i += n
			default:
				return "", b, false
			}
		case c < 0x20:
			return "", b, false
		case c < 0x80:
			sb.WriteByte(c)
			i++
		default:
			r, n := utf8.DecodeRune(b[i:])
			if r == utf8.RuneError && n <= 1 {
				return "", b, false // invalid UTF-8 is not a JSON string
			}
			sb.WriteRune(r)
			i += n
		}
	}
	return "", b, false
}

func hexVal(c byte) (int, bool) {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0'), true
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10, true
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10, true
	}
	return 0, false
}

// parseUnicode decodes \uXXXX (and a following \uXXXX low surrogate when
// the first is high). Returns the rune and bytes consumed from b (which
// starts at the backslash).
func parseUnicode(b []byte) (rune, int, bool) {
	if len(b) < 6 {
		return 0, 0, false
	}
	var u int
	for i := 2; i < 6; i++ {
		v, ok := hexVal(b[i])
		if !ok {
			return 0, 0, false
		}
		u = u<<4 | v
	}
	if u >= 0xd800 && u <= 0xdbff {
		// High surrogate: a \uDC00-\uDFFF must follow.
		if len(b) >= 12 && b[6] == '\\' && b[7] == 'u' {
			var lo int
			bad := false
			for i := 8; i < 12; i++ {
				v, ok := hexVal(b[i])
				if !ok {
					bad = true
					break
				}
				lo = lo<<4 | v
			}
			if !bad && lo >= 0xdc00 && lo <= 0xdfff {
				return rune(0x10000 + ((u - 0xd800) << 10) + (lo - 0xdc00)), 12, true
			}
		}
		return utf8.RuneError, 6, true // lone surrogate: U+FFFD
	}
	if u >= 0xdc00 && u <= 0xdfff {
		return utf8.RuneError, 6, true
	}
	return rune(u), 6, true
}

func parseNumber(b []byte) (jval, []byte, bool) {
	i := 0
	if i < len(b) && b[i] == '-' {
		i++
	}
	if i >= len(b) {
		return jval{}, b, false
	}
	if b[i] == '0' {
		i++
	} else if b[i] >= '1' && b[i] <= '9' {
		for i < len(b) && b[i] >= '0' && b[i] <= '9' {
			i++
		}
	} else {
		return jval{}, b, false
	}
	if i < len(b) && b[i] == '.' {
		i++
		if i >= len(b) || b[i] < '0' || b[i] > '9' {
			return jval{}, b, false
		}
		for i < len(b) && b[i] >= '0' && b[i] <= '9' {
			i++
		}
	}
	if i < len(b) && (b[i] == 'e' || b[i] == 'E') {
		i++
		if i < len(b) && (b[i] == '+' || b[i] == '-') {
			i++
		}
		if i >= len(b) || b[i] < '0' || b[i] > '9' {
			return jval{}, b, false
		}
		for i < len(b) && b[i] >= '0' && b[i] <= '9' {
			i++
		}
	}
	return jval{kind: jNum, str: string(b[:i])}, b[i:], true
}

// parseLine parses one request line end to end. It returns the top-level
// value, or ("", code): "bad_json" when the line is not valid UTF-8 or not
// well-formed JSON (D4), "bad_request" when it is a bare `null` (D4 names
// null under bad_request; every other non-object line is not "one JSON
// object" and stays bad_json).
func parseLine(line []byte) (jval, string) {
	if !utf8.Valid(line) {
		return jval{}, "bad_json"
	}
	v, rest, ok := parseValue(line)
	if !ok || len(skipWS(rest)) != 0 {
		return jval{}, "bad_json"
	}
	if v.kind == jNull {
		return jval{}, "bad_request"
	}
	if v.kind != jObj {
		return jval{}, "bad_json"
	}
	return v, ""
}

// --- request validation ------------------------------------------------------

// fieldView is the flat-field projection of one request object.
type fieldView struct {
	kind int    // fStr / fInt / fBool / fArr
	str  string // fStr
	num  int64  // fInt
	arr  []jval // fArr
}

// request is a validated flat request: the parsed fields plus the id and
// verb projections the dispatcher needs.
type request struct {
	id      int64
	hasID   bool
	verb    string
	hasVerb bool
	fields  map[string]fieldView
}

// fieldKind classifies a parsed value into the flat grammar, or -1 when it
// is outside it (nested object, null, or a number that is not a
// plain unsigned integer within the bound — a mistyped value, which is
// bad_request either way). An array projects as fArr so ui.input can
// carry its events; every other verb's arg getter refuses it as mistyped.
func fieldKind(v jval) int {
	switch v.kind {
	case jStr:
		return fStr
	case jTrue, jFalse:
		return fBool
	case jArr:
		return fArr
	case jNum:
		if n, ok := flatInt(v.str); ok {
			_ = n
			return fInt
		}
	}
	return -1
}

// flatInt reports whether text is an unsigned decimal integer within the
// 2^31-1 bound — no sign, no fraction, no exponent.
func flatInt(s string) (int64, bool) {
	if len(s) == 0 || len(s) > 10 {
		return 0, false
	}
	var n int64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int64(c-'0')
		if n > intMax {
			return 0, false
		}
	}
	return n, true
}

// validateRequest projects a parsed object into a request: duplicate keys,
// mistyped or out-of-grammar values, and the required id/verb fields are
// all checked here (D4: refuse before touching anything). unknown verbs
// are reported by the caller against this projection.
func validateRequest(v jval) (*request, string) {
	req := &request{fields: make(map[string]fieldView, len(v.membs))}
	for _, m := range v.membs {
		if _, dup := req.fields[m.key]; dup {
			return req, "bad_request"
		}
		switch k := fieldKind(m.val); k {
		case fStr:
			req.fields[m.key] = fieldView{kind: fStr, str: m.val.str}
		case fInt:
			n, _ := flatInt(m.val.str)
			req.fields[m.key] = fieldView{kind: fInt, num: n}
		case fBool:
			req.fields[m.key] = fieldView{kind: fBool}
		case fArr:
			req.fields[m.key] = fieldView{kind: fArr, arr: m.val.items}
		default:
			return req, "bad_request"
		}
	}
	f, ok := req.fields["id"]
	if ok && f.kind == fInt {
		req.id = f.num
		if req.id >= 1 {
			req.hasID = true
		}
	}
	f, ok = req.fields["verb"]
	if ok && f.kind == fStr {
		req.verb = f.str
		req.hasVerb = true
	}
	if !req.hasID || !req.hasVerb {
		return req, "bad_request"
	}
	return req, ""
}

// hasArgs reports whether every key outside {id, verb} is in the verb's
// allowed argument set — an unknown key is bad_request (D1).
func (r *request) hasArgs(names ...string) bool {
	for k := range r.fields {
		if k == "id" || k == "verb" {
			continue
		}
		ok := false
		for _, n := range names {
			if k == n {
				ok = true
				break
			}
		}
		if !ok {
			return false
		}
	}
	return true
}

// argInt returns an integer argument validated against [lo, hi]. present is
// false when the key is absent; ok is false when the value is mistyped or
// out of range — the caller maps that to bad_request.
func (r *request) argInt(name string, lo, hi int64) (v int64, present, ok bool) {
	f, ok := r.fields[name]
	if !ok {
		return 0, false, true
	}
	if f.kind != fInt || f.num < lo || f.num > hi {
		return 0, true, false
	}
	return f.num, true, true
}

// argStr returns a string argument. present/ok mirror argInt.
func (r *request) argStr(name string) (v string, present, ok bool) {
	f, ok := r.fields[name]
	if !ok {
		return "", false, true
	}
	if f.kind != fStr {
		return "", true, false
	}
	return f.str, true, true
}

// argArray returns an array argument's raw elements. present/ok mirror
// argInt; ok is false when the value is not an array. Element shape is
// the verb's own check — the grammar only guarantees the parse tree.
func (r *request) argArray(name string) (v []jval, present, ok bool) {
	f, ok := r.fields[name]
	if !ok {
		return nil, false, true
	}
	if f.kind != fArr {
		return nil, true, false
	}
	return f.arr, true, true
}

// --- the writer --------------------------------------------------------------

// hexDigits is the lowercase hex alphabet shared by the greeting, the MAC
// compare, and the error-free response paths.
const hexDigits = "0123456789abcdef"

// jwriteStr appends a JSON string literal: '"', '\\' and control bytes are
// escaped, and invalid UTF-8 becomes U+FFFD (D1's text-field rule).
func jwriteStr(sb *strings.Builder, s string) {
	sb.WriteByte('"')
	for len(s) > 0 {
		c := s[0]
		switch {
		case c == '"' || c == '\\':
			sb.WriteByte('\\')
			sb.WriteByte(c)
			s = s[1:]
		case c == '\n':
			sb.WriteString(`\n`)
			s = s[1:]
		case c == '\r':
			sb.WriteString(`\r`)
			s = s[1:]
		case c == '\t':
			sb.WriteString(`\t`)
			s = s[1:]
		case c == '\b':
			sb.WriteString(`\b`)
			s = s[1:]
		case c == '\f':
			sb.WriteString(`\f`)
			s = s[1:]
		case c < 0x20:
			sb.WriteString("\\u00")
			sb.WriteByte(hexDigits[c>>4])
			sb.WriteByte(hexDigits[c&0xf])
			s = s[1:]
		case c < 0x80:
			sb.WriteByte(c)
			s = s[1:]
		default:
			r, n := utf8.DecodeRuneInString(s)
			if r == utf8.RuneError && n <= 1 {
				sb.WriteString("�")
				s = s[1:]
				continue
			}
			sb.WriteString(s[:n])
			s = s[n:]
		}
	}
	sb.WriteByte('"')
}

// respond builds one complete response object line (no LF — sendLine adds
// it). id < 0 emits null: the request id could not be read (D1).
func respondOK(id int64, result string) string {
	var sb strings.Builder
	sb.WriteString(`{"id":`)
	writeID(&sb, id)
	sb.WriteString(`,"ok":true,"result":`)
	sb.WriteString(result)
	sb.WriteByte('}')
	return sb.String()
}

func respondErr(id int64, code, message string) string {
	var sb strings.Builder
	sb.WriteString(`{"id":`)
	writeID(&sb, id)
	sb.WriteString(`,"ok":false,"error":{"code":`)
	jwriteStr(&sb, code)
	sb.WriteString(`,"message":`)
	jwriteStr(&sb, message)
	sb.WriteString(`}}`)
	return sb.String()
}

func writeID(sb *strings.Builder, id int64) {
	if id < 0 {
		sb.WriteString("null")
		return
	}
	sb.WriteString(vi.Itoa64(id))
}
