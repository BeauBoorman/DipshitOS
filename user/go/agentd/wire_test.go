package main

// ADR 0044 D1 / AC2: the wire reader's differential corpus against
// encoding/json (the oracle), golden response encodings, and the line
// reader's bounds.

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"virelai/vi"
)

// fakeConn scripts a transport: recv serves the queued chunks in order
// (or the scripted error), send captures what was written.
type fakeConn struct {
	chunks   [][]byte
	recvErr  error
	sent     []byte
	deadline int64
}

func (c *fakeConn) Recv(p []byte) (int, error) {
	if len(c.chunks) > 0 {
		n := copy(p, c.chunks[0])
		c.chunks[0] = c.chunks[0][n:]
		if len(c.chunks[0]) == 0 {
			c.chunks = c.chunks[1:]
		}
		return n, nil
	}
	if c.recvErr != nil {
		return 0, c.recvErr
	}
	return 0, errTestNoData
}

var errTestNoData = errors.New("no data")

func (c *fakeConn) Send(p []byte) (int, error) {
	c.sent = append(c.sent, p...)
	return len(p), nil
}

func (c *fakeConn) SetRecvDeadline(ns int64) { c.deadline = ns }

func (c *fakeConn) sentLines() []string {
	s := strings.TrimRight(string(c.sent), "\n")
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

// --- differential corpus ------------------------------------------------------

// oracleClass is how encoding/json classifies the line: does it decode to
// exactly one JSON object, and what does the flat projection see?
func oracleClass(t *testing.T, line string) (obj bool, id float64, hasID bool, verb string, hasVerb bool) {
	t.Helper()
	if !json.Valid([]byte(line)) {
		return false, 0, false, "", false
	}
	var v any
	if err := json.Unmarshal([]byte(line), &v); err != nil {
		return false, 0, false, "", false
	}
	m, isObj := v.(map[string]any)
	if !isObj {
		return false, 0, false, "", false
	}
	if f, ok := m["id"].(float64); ok {
		id, hasID = f, true
	}
	if s, ok := m["verb"].(string); ok {
		verb, hasVerb = s, true
	}
	return true, id, hasID, verb, hasVerb
}

// The differential corpus: every line the wire must classify the same way
// the oracle does — accepted objects, every D1 refusal shape, and the
// escapes the flat grammar carries.
var diffCorpus = []string{
	// accepted requests
	`{"id":1,"verb":"proc.list"}`,
	`{"id":2147483647,"verb":"fs.read","path":"SEED.TXT"}`,
	`{"id":9,"verb":"gosh.run","cmd":"echo hi","timeout_ms":1000}`,
	`{"id":2,"verb":"fs.write","path":"X","data_b64":"QUJD"}`,
	`{"id":3,"verb":"ui.windows","x":true}`,
	" \t { \"id\" : 7 , \"verb\" : \"proc.get\" , \"pid\" : 5 } ",
	`{"id":4,"verb":"fs.read","path":"A.B-C_D"}`,
	`{"id":5,"verb":"gosh.run","cmd":"A\"B"}`,
	`{"id":6,"verb":"fs.read","path":"é"}`,
	// id / verb shapes that refuse
	`{"verb":"proc.list"}`,
	`{"id":1}`,
	`{"id":1,"verb":2}`,
	`{"id":"1","verb":"proc.list"}`,
	`{"id":0,"verb":"proc.list"}`,
	`{"id":-1,"verb":"proc.list"}`,
	`{"id":1.0,"verb":"proc.list"}`,
	`{"id":1e3,"verb":"proc.list"}`,
	`{"id":2147483648,"verb":"proc.list"}`,
	`{"id":1,"verb":"proc.list","id":2}`,
	`{"id":1,"verb":"proc.list","a":{"b":1}}`,
	`{"id":1,"verb":"proc.list","a":[1]}`,
	`{"id":1,"verb":"proc.list","a":null}`,
	`{"id":1,"verb":"proc.list","a":-2}`,
	`{"id":1,"verb":"proc.list","a":1.5}`,
	// not one object
	`{`,
	`}`,
	`[1,2]`,
	`"str"`,
	`42`,
	`true`,
	`null`,
	`garbage`,
	`{"id":1,"verb":"x"} {"id":2,"verb":"y"}`,
	`{"id":1,"verb":"x",}`,
	`{'id':1}`,
	`{"id":1,"verb":"x`,
	`{"id":1,"verb":"x"}}`,
	`{"id":+1,"verb":"x"}`,
	`{"id":01,"verb":"x"}`,
	`{"id":1,"verb":"\ud800"}`,
	`{"id":1,"verb":"\ud83d\ude00"}`,
	`{"id":1,"verb":"bad\udc00pair"}`,
	`{"id":1,"verb":"ok","s":"AC"}`,
	`{"id":1,"verb":"ok","s":"a\/b"}`,
	`{"id":1,"verb":"ok","s":""}`,
	`{"id":1,"verb":"ok","s":"\x41"}`,
	`{"id":1,"verb":"ok","s":"tab\there"}`,
	`{"id":1,"verb":"ok","s":"raw
newline"}`,
	`{"auth":"` + strings.Repeat("0", 64) + `"}`,
	`{"id":1,"verb":"fs.read","path":"\u0000"}`,
}

func TestWireDifferentialCorpus(t *testing.T) {
	for _, line := range diffCorpus {
		obj, oid, ohasID, overb, ohasVerb := oracleClass(t, line)
		v, code := parseLine([]byte(line))
		if !obj {
			if code == "" {
				t.Fatalf("%q: accepted where oracle refused", line)
			}
			// encoding/json decodes `null` to nil — a valid JSON value
			// that is not an object. D4 puts it under bad_request;
			// every other non-object is bad_json.
			if line == "null" {
				if code != "bad_request" {
					t.Fatalf("%q: code = %q want bad_request", line, code)
				}
			} else if code != "bad_json" {
				t.Fatalf("%q: code = %q want bad_json", line, code)
			}
			continue
		}
		if code != "" {
			t.Fatalf("%q: refused %q where oracle accepted", line, code)
		}
		req, code := validateRequest(v)
		idOK := ohasID && oid >= 1 && oid <= intMax && oid == float64(int64(oid))
		if code == "" {
			if !idOK || !ohasVerb {
				t.Fatalf("%q: validate accepted id=%v verb=%v", line, ohasID, overb)
			}
			if req.id != int64(oid) || req.verb != overb {
				t.Fatalf("%q: projection = id %d verb %q, oracle %v %q",
					line, req.id, req.verb, oid, overb)
			}
			continue
		}
		if code != "bad_request" {
			t.Fatalf("%q: code = %q want bad_request", line, code)
		}
	}
}

// The refusal matrix for fields: which line lands which code through the
// full parse+validate path.
func TestWireRefusalMatrix(t *testing.T) {
	for _, tc := range []struct {
		line string
		code string
	}{
		{`{`, "bad_json"},
		{`[1]`, "bad_json"},
		{`null`, "bad_request"},
		{`{"verb":"proc.list"}`, "bad_request"},
		{`{"id":1}`, "bad_request"},
		{`{"id":0,"verb":"proc.list"}`, "bad_request"},
		{`{"id":1,"verb":"proc.list","id":2}`, "bad_request"},
		{`{"id":1,"verb":"proc.list","a":{}}`, "bad_request"},
		{`{"id":1,"verb":"proc.list","a":null}`, "bad_request"},
	} {
		v, code := parseLine([]byte(tc.line))
		if code == "" {
			_, code = validateRequest(v)
		}
		if code != tc.code {
			t.Fatalf("%q: code = %q want %q", tc.line, code, tc.code)
		}
	}
}

// A size-bounded fuzz seed set: take corpus prefixes/suffixes and prove
// parseLine never panics and always lands on a D4 code or an accept.
func TestWireFuzzSeeds(t *testing.T) {
	seeds := diffCorpus
	for _, s := range diffCorpus {
		if len(s) > 4 {
			seeds = append(seeds, s[:len(s)/2], s[1:], s[:len(s)-1]+"\x00", s+s)
		}
	}
	for _, s := range seeds {
		v, code := parseLine([]byte(s))
		if code != "" {
			if code != "bad_json" && code != "bad_request" {
				t.Fatalf("%q: unexpected code %q", s, code)
			}
			continue
		}
		if _, code = validateRequest(v); code != "" && code != "bad_request" {
			t.Fatalf("%q: unexpected validate code %q", s, code)
		}
	}
}

// --- golden encodings -----------------------------------------------------------

func TestGoldenResponses(t *testing.T) {
	if got := respondOK(7, `{"procs":[]}`); got != `{"id":7,"ok":true,"result":{"procs":[]}}` {
		t.Fatalf("respondOK = %q", got)
	}
	if got := respondErr(-1, "bad_request", "request is missing, mistyped or out of range"); got !=
		`{"id":null,"ok":false,"error":{"code":"bad_request","message":"request is missing, mistyped or out of range"}}` {
		t.Fatalf("respondErr = %q", got)
	}
	if got := respondErr(3, "unknown_verb", errMessages["unknown_verb"]); got !=
		`{"id":3,"ok":false,"error":{"code":"unknown_verb","message":"verb is not supported"}}` {
		t.Fatalf("respondErr id = %q", got)
	}
}

func TestJWriteStrEscapes(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"\x00\x1f", `"\u0000\u001f"`},
		{"plain", `"plain"`},
		{"a\"b", `"a\"b"`},
		{"a\\b", `"a\\b"`},
		{"a\nb\tc", `"a\nb\tc"`},
		{"é漢字", `"é漢字"`},
		{"bad\xffutf", `"bad�utf"`},
	} {
		var sb strings.Builder
		jwriteStr(&sb, tc.in)
		if sb.String() != tc.want {
			t.Fatalf("jwriteStr(%q) = %q want %q", tc.in, sb.String(), tc.want)
		}
	}
}

// --- the line reader -----------------------------------------------------------

func TestReadLineBounds(t *testing.T) {
	// A line exactly at the limit (limit counts the LF) is fine; one byte
	// more is readTooLong and discards the bytes unparsed.
	body := strings.Repeat("a", 8191)
	c := &fakeConn{chunks: [][]byte{[]byte(body + "\n")}}
	r := newLineReader(c)
	line, out := r.readLine(8192)
	if out != readOK || len(line) != 8191 {
		t.Fatalf("exact-limit read = outcome %d len %d", out, len(line))
	}

	c = &fakeConn{chunks: [][]byte{[]byte(body + "x\n")}}
	r = newLineReader(c)
	if _, out = r.readLine(8192); out != readTooLong {
		t.Fatalf("over-limit read = %d want readTooLong", out)
	}

	// A bare CR before the LF is stripped; an interior CR stays.
	c = &fakeConn{chunks: [][]byte{[]byte("a\rb\r\n")}}
	r = newLineReader(c)
	line, out = r.readLine(8192)
	if out != readOK || string(line) != "a\rb" {
		t.Fatalf("CR read = %q outcome %d", line, out)
	}
}

// Pipelined lines are served in order before any further recv.
func TestReadLinePipelined(t *testing.T) {
	c := &fakeConn{chunks: [][]byte{
		[]byte(`{"id":1,"verb":"a"}` + "\n" + `{"id":2,"verb":"b"}` + "\n"),
	}}
	r := newLineReader(c)
	l1, o1 := r.readLine(8192)
	l2, o2 := r.readLine(8192)
	if o1 != readOK || o2 != readOK ||
		string(l1) != `{"id":1,"verb":"a"}` || string(l2) != `{"id":2,"verb":"b"}` {
		t.Fatalf("pipelined = %q/%d %q/%d", l1, o1, l2, o2)
	}
}

func TestReadLineOutcomes(t *testing.T) {
	c := &fakeConn{recvErr: errors.New("ETIMEDOUT")}
	if _, out := newLineReader(c).readLine(256); out != readTimeout {
		t.Fatalf("timeout outcome = %d", out)
	}
	c = &fakeConn{recvErr: vi.ErrPeerGone}
	if _, out := newLineReader(c).readLine(256); out != readPeerGone {
		t.Fatalf("peer-gone outcome = %d", out)
	}
	c = &fakeConn{recvErr: vi.ErrConnClosed}
	if _, out := newLineReader(c).readLine(256); out != readPeerGone {
		t.Fatalf("conn-closed outcome = %d", out)
	}
	c = &fakeConn{recvErr: errors.New("EAGAIN")}
	if _, out := newLineReader(c).readLine(256); out != readIOErr {
		t.Fatalf("io outcome = %d", out)
	}
	// A line split across recv boundaries is one line.
	c = &fakeConn{chunks: [][]byte{[]byte(`{"id":1,`), []byte(`"verb":"x"}` + "\n")}}
	line, out := newLineReader(c).readLine(8192)
	if out != readOK || string(line) != `{"id":1,"verb":"x"}` {
		t.Fatalf("split line = %q outcome %d", line, out)
	}
}

var errPeerGoneTest = vi.ErrPeerGone

// The 16 KiB pending bound: a flood without a terminator trips the bound
// even below the per-line limit's natural trip.
func TestReadLinePendingBound(t *testing.T) {
	c := &fakeConn{chunks: [][]byte{[]byte(strings.Repeat("x", 16*1024+1))}}
	if _, out := newLineReader(c).readLine(pendingMax + 4096); out != readTooLong {
		t.Fatalf("flood outcome = %d want readTooLong", out)
	}
}

// --- flat grammar helpers ---------------------------------------------------------

func TestFlatIntBounds(t *testing.T) {
	for _, tc := range []struct {
		s    string
		want int64
		ok   bool
	}{
		{"0", 0, true}, {"1", 1, true}, {"2147483647", 2147483647, true},
		{"2147483648", 0, false}, {"-1", 0, false}, {"1.0", 0, false},
		{"1e3", 0, false}, {"", 0, false}, {"01", 1, true}, {"abc", 0, false},
		{"99999999999", 0, false},
	} {
		n, ok := flatInt(tc.s)
		if n != tc.want || ok != tc.ok {
			t.Fatalf("flatInt(%q) = %d,%v want %d,%v", tc.s, n, ok, tc.want, tc.ok)
		}
	}
}

func TestB64RoundTrip(t *testing.T) {
	for _, n := range []int{0, 1, 2, 3, 4, 255, 256, 4096} {
		b := make([]byte, n)
		for i := range b {
			b[i] = byte(i*31 + 7)
		}
		enc := b64Encode(b)
		dec, ok := b64Decode(enc)
		if !ok || len(dec) != len(b) {
			t.Fatalf("round trip n=%d failed", n)
		}
		for i := range b {
			if dec[i] != b[i] {
				t.Fatalf("round trip n=%d byte %d", n, i)
			}
		}
	}
}

func TestB64Strict(t *testing.T) {
	for _, s := range []string{
		"@@", "A", "AB", "ABC", "ABCDE", "QUJD=", "QUJD===", "QUJ D",
		"QUJD\n", "====", "A===", "QUJD$", "quié", "AAAA====",
	} {
		if _, ok := b64Decode(s); ok {
			t.Fatalf("b64Decode(%q) accepted", s)
		}
	}
	for _, s := range []string{"", "QUJD", "QQ==", "QUI=", "QUJDRA=="} {
		if _, ok := b64Decode(s); !ok {
			t.Fatalf("b64Decode(%q) refused", s)
		}
	}
}
