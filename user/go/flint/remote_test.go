package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Golden transcript replay: testdata/sync/*.ndjson is pinned verbatim from
// drawmeanelephant/flint-server @ 3e18fc0c13be9fbcc46f3561b12d254760bcaced
// (VirelaiOS proprietary source-available license — not GPL-family). Lines
// starting `> ` are requests a conforming client emits; `< ` are responses.
// The tests below drive the real client ops and compare every emitted
// request line byte-for-byte.
// ---------------------------------------------------------------------------

type wireStep struct {
	op   string // parsed from the want line, for diagnostics
	want string // exact request line the client must emit ("" = shape-only)
	give string // response line the transport feeds back
}

func loadTranscript(t *testing.T, name string) []wireStep {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "sync", name))
	if err != nil {
		t.Fatalf("read transcript %s: %v", name, err)
	}
	var steps []wireStep
	var pending *wireStep
	for _, line := range strings.Split(string(raw), "\n") {
		switch {
		case strings.HasPrefix(line, "> "):
			steps = append(steps, wireStep{want: strings.TrimPrefix(line, "> ")})
			pending = &steps[len(steps)-1]
			var req map[string]json.RawMessage
			if json.Unmarshal([]byte(pending.want), &req) == nil {
				var op string
				if json.Unmarshal(req["op"], &op) == nil {
					pending.op = op
				}
			}
		case strings.HasPrefix(line, "< "):
			if pending == nil || pending.give != "" {
				t.Fatalf("transcript %s: response without request: %q", name, line)
			}
			pending.give = strings.TrimPrefix(line, "< ")
		}
	}
	return steps
}

// scriptConn replays a transcript: each Send must carry the want line
// byte-for-byte (marked shape-only steps compare structure instead) and the
// next Recv feeds the give line back in small chunks.
type scriptConn struct {
	t     *testing.T
	steps []wireStep
	out   []byte
}

func (c *scriptConn) Send(p []byte) (int, error) {
	if len(c.steps) == 0 {
		c.t.Fatalf("client sent unexpected request: %q", p)
	}
	step := c.steps[0]
	c.steps = c.steps[1:]
	got := strings.TrimRight(string(p), "\n")
	if step.want != "" && got != step.want {
		c.t.Fatalf("request %s bytes mismatch:\n got: %s\nwant: %s", step.op, got, step.want)
	}
	c.out = []byte(step.give + "\n")
	return len(p), nil
}

func (c *scriptConn) Recv(p []byte) (int, error) {
	if len(c.out) == 0 {
		return 0, errors.New("script: response drained")
	}
	const chunk = 37 // deliberately awkward: forces partial-line accumulation
	if len(p) > chunk {
		p = p[:chunk]
	}
	n := copy(p, c.out)
	c.out = c.out[n:]
	return n, nil
}

func (c *scriptConn) Close() error { return nil }

// transcriptField extracts one JSON field from a transcript request line.
func transcriptField(t *testing.T, want, name string) json.RawMessage {
	t.Helper()
	var req map[string]json.RawMessage
	if err := json.Unmarshal([]byte(want), &req); err != nil {
		t.Fatalf("transcript request not JSON: %v", err)
	}
	v, ok := req[name]
	if !ok {
		t.Fatalf("transcript request missing field %q: %s", name, want)
	}
	return v
}

func transcriptStr(t *testing.T, want, name string) string {
	t.Helper()
	var s string
	if err := json.Unmarshal(transcriptField(t, want, name), &s); err != nil {
		t.Fatalf("field %s: %v", name, err)
	}
	return s
}

func TestGoldenHelloList(t *testing.T) {
	steps := loadTranscript(t, "hello_list.ndjson")
	c := &syncClient{conn: &scriptConn{t: t, steps: steps}}
	if err := c.handshake(nil); err != nil {
		t.Fatalf("handshake: %v", err)
	}
	streams, err := c.list()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(streams) != 0 {
		t.Fatalf("expected empty stream list, got %v", streams)
	}
	heads, err := c.heads()
	if err != nil {
		t.Fatalf("heads: %v", err)
	}
	if len(heads) != 0 {
		t.Fatalf("expected empty heads map, got %v", heads)
	}
	if len(c.conn.(*scriptConn).steps) != 0 {
		t.Fatalf("%d transcript steps unconsumed", len(c.conn.(*scriptConn).steps))
	}
}

func TestGoldenPushPull(t *testing.T) {
	steps := loadTranscript(t, "push_pull.ndjson")
	c := &syncClient{conn: &scriptConn{t: t, steps: steps}}
	if err := c.handshake(nil); err != nil {
		t.Fatalf("handshake: %v", err)
	}

	// create: args come from the golden request itself so byte-fidelity is
	// self-extracting.
	var rec Stream
	createWant := steps[1].want
	if err := json.Unmarshal(transcriptField(t, createWant, "record"), &rec); err != nil {
		t.Fatalf("record: %v", err)
	}
	if err := c.create(&rec); err != nil {
		t.Fatalf("create: %v", err)
	}

	appendWant := steps[2].want
	var changes [][]byte
	var rawChanges []string
	if err := json.Unmarshal(transcriptField(t, appendWant, "changes"), &rawChanges); err != nil {
		t.Fatalf("changes: %v", err)
	}
	for _, s := range rawChanges {
		changes = append(changes, []byte(s))
	}
	head, err := c.append(transcriptStr(t, appendWant, "stream"), nil, changes)
	if err != nil {
		t.Fatalf("append: %v", err)
	}
	if head != "0199de2d-dc00-7000-8000-000000000101" {
		t.Fatalf("append head=%q", head)
	}

	st, err := c.open("main")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if st.ID != rec.ID || st.Head == nil || *st.Head != head {
		t.Fatalf("open record=%+v", st)
	}

	heads, err := c.heads()
	if err != nil {
		t.Fatalf("heads: %v", err)
	}
	if heads[rec.ID] == nil || *heads[rec.ID] != head {
		t.Fatalf("heads=%v", heads)
	}

	readWant := steps[5].want
	after := transcriptStr(t, readWant, "after")
	page, err := c.read(transcriptStr(t, readWant, "stream"), &after, 256)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if page.more || len(page.changes) != 1 {
		t.Fatalf("read page: %+v", page)
	}
	if !bytes.Equal(page.changes[0], changes[1]) {
		t.Fatalf("read change bytes mismatch:\n got: %s\nwant: %s", page.changes[0], changes[1])
	}

	// The final golden leg: stale expected_head + empty batch → stale_head.
	var expHead string
	if err := json.Unmarshal(transcriptField(t, steps[6].want, "expected_head"), &expHead); err != nil {
		t.Fatalf("expected_head: %v", err)
	}
	if _, err := c.append(transcriptStr(t, steps[6].want, "stream"), &expHead, nil); err == nil {
		t.Fatal("expected refusal")
	} else if re, ok := err.(*RefuseError); !ok || re.Code != "stale_head" {
		t.Fatalf("expected stale_head, got %v", err)
	}
	if len(c.conn.(*scriptConn).steps) != 0 {
		t.Fatalf("%d transcript steps unconsumed", len(c.conn.(*scriptConn).steps))
	}
}

func TestGoldenAuthRefuse(t *testing.T) {
	steps := loadTranscript(t, "auth_refuse.ndjson")
	// The auth request's hmac is key-dependent; the pinned zeros key is
	// unknown, so that step compares shape, not bytes.
	for i := range steps {
		if steps[i].op == "auth" {
			steps[i].want = ""
		}
	}
	conn := &scriptConn{t: t, steps: steps}
	c := &syncClient{conn: conn}

	// hello returns ok + nonce; with no configured key the client must
	// refuse auth_required (it never answers a challenge it cannot compute).
	err := c.handshake(nil)
	if err == nil {
		t.Fatal("handshake without key: expected refusal")
	}
	if re, ok := err.(*RefuseError); !ok || re.Code != "auth_required" {
		t.Fatalf("handshake: expected auth_required, got %v", err)
	}

	if _, err := c.list(); err == nil {
		t.Fatal("list before auth: expected refusal")
	} else if re, ok := err.(*RefuseError); !ok || re.Code != "auth_required" {
		t.Fatalf("list: expected auth_required, got %v", err)
	}

	var k [32]byte // any wrong key: the fixture refuses auth_failed regardless
	if err := c.sendAuth(&k, "000102030405060708090a0b0c0d0e0f"); err == nil {
		t.Fatal("sendAuth: expected refusal")
	} else if re, ok := err.(*RefuseError); !ok || re.Code != "auth_failed" {
		t.Fatalf("sendAuth: expected auth_failed, got %v", err)
	}
	if len(conn.steps) != 0 {
		t.Fatalf("%d transcript steps unconsumed", len(conn.steps))
	}
}

// TestComputeAuthHMAC checks the challenge answer against the host stdlib's
// independent HMAC-SHA256 (test-only import; the guest build bans crypto/*).
func TestComputeAuthHMAC(t *testing.T) {
	var key [32]byte
	for i := range key {
		key[i] = byte(i * 3)
	}
	nonceHex := "000102030405060708090a0b0c0d0e0f"
	got, err := computeAuthHMAC(&key, nonceHex)
	if err != nil {
		t.Fatalf("computeAuthHMAC: %v", err)
	}
	nonce, _ := hex.DecodeString(nonceHex)
	msg := append([]byte("FLINT-SYNC-AUTH/1\x00"), nonce...)
	mac := hmac.New(sha256.New, key[:])
	mac.Write(msg)
	want := hex.EncodeToString(mac.Sum(nil))
	if got != want {
		t.Fatalf("hmac mismatch:\n got: %s\nwant: %s", got, want)
	}
	if _, err := computeAuthHMAC(&key, "not-hex"); err == nil {
		t.Fatal("expected refusal on bad nonce")
	} else if re, ok := err.(*RefuseError); !ok || re.Code != "auth_failed" {
		t.Fatalf("expected auth_failed, got %v", err)
	}
}

func TestParseRemoteURL(t *testing.T) {
	cases := []struct {
		in, host string
		port     uint16
		ok       bool
	}{
		{"tcp://10.0.0.2:4748", "10.0.0.2", 4748, true},
		{"10.0.0.2:4748", "10.0.0.2", 4748, true},
		{"tcp://host.name:1", "host.name", 1, true},
		{"tcp://:4748", "", 0, false},
		{"tcp://10.0.0.2", "", 0, false},
		{"tcp://10.0.0.2:0", "", 0, false},
		{"tcp://10.0.0.2:70000", "", 0, false},
		{"http://10.0.0.2:4748", "", 0, false},
		{"tcp://a/b:4748", "", 0, false},
		{"", "", 0, false},
	}
	for _, tc := range cases {
		host, port, err := parseRemoteURL(tc.in)
		if !tc.ok {
			if err == nil {
				t.Fatalf("parseRemoteURL(%q) = %s:%d, want refusal", tc.in, host, port)
			}
			if re, ok := err.(*RefuseError); !ok || re.Code != "remote_malformed" {
				t.Fatalf("parseRemoteURL(%q): expected remote_malformed, got %v", tc.in, err)
			}
			continue
		}
		if err != nil || host != tc.host || port != tc.port {
			t.Fatalf("parseRemoteURL(%q) = %s:%d %v", tc.in, host, port, err)
		}
	}
	if u, err := normalizeRemote("10.0.0.2:4748"); err != nil || u != "tcp://10.0.0.2:4748" {
		t.Fatalf("normalizeRemote: %q %v", u, err)
	}
}

// ---------------------------------------------------------------------------
// In-process fake flintd: speaks FLINT-SYNC/1 server-side per
// docs/flint-server-spec.md §2 so the verbs run end to end — verbatim raw
// bytes, refusal names, head bookkeeping.
// ---------------------------------------------------------------------------

type fakeStream struct {
	rec   *Stream
	lines [][]byte
}

type fakeServer struct {
	streams  map[string]*fakeStream
	authKey  *[32]byte
	authed   bool
	nonce    string
	nonceSeq uint64
}

func newFakeServer() *fakeServer {
	return &fakeServer{
		streams: map[string]*fakeStream{},
		nonce:   "000102030405060708090a0b0c0d0e0f",
	}
}

func (s *fakeServer) addStream(st *Stream, lines [][]byte) {
	s.streams[st.ID] = &fakeStream{rec: st, lines: lines}
}

func (s *fakeServer) streamByNameOrID(arg string) *fakeStream {
	if fs, ok := s.streams[arg]; ok {
		return fs
	}
	for _, fs := range s.streams {
		if fs.rec.Name == arg {
			return fs
		}
	}
	return nil
}

func (s *fakeServer) handle(reqLine []byte) []byte {
	var req map[string]json.RawMessage
	resp := func(seq uint64, m map[string]any) []byte {
		m["seq"] = seq
		b, _ := json.Marshal(m)
		return b
	}
	refuseResp := func(seq uint64, name, detail string) []byte {
		b, _ := json.Marshal(map[string]any{"seq": seq, "ok": false, "refuse": name, "detail": detail})
		return b
	}
	if err := json.Unmarshal(reqLine, &req); err != nil {
		return refuseResp(0, "usage", "")
	}
	seq := uint64(0)
	if raw, ok := req["seq"]; ok {
		_ = json.Unmarshal(raw, &seq)
	}
	op, _ := jsonFieldStr(req, "op")
	if s.authKey != nil && !s.authed && op != "hello" && op != "auth" {
		return refuseResp(seq, "auth_required", "authentication required")
	}
	switch op {
	case "hello":
		proto, _ := jsonFieldStr(req, "proto")
		if proto != protoVersion {
			return refuseResp(seq, "proto_version", "")
		}
		m := map[string]any{"ok": true, "proto": protoVersion, "server": "flintd"}
		if s.authKey != nil {
			// Like real flintd: every hello regenerates the session nonce
			// (and un-auths the session).
			s.authed = false
			s.nonceSeq++
			s.nonce = fmt.Sprintf("%032x", s.nonceSeq)
			m["nonce"] = s.nonce
		}
		return resp(seq, m)
	case "auth":
		nonce, _ := jsonFieldStr(req, "nonce")
		got, _ := jsonFieldStr(req, "hmac")
		want, err := computeAuthHMAC(s.authKey, nonce)
		if nonce != s.nonce || err != nil || got != want {
			return refuseResp(seq, "auth_failed", "hmac mismatch")
		}
		s.authed = true
		return resp(seq, map[string]any{"ok": true})
	case "list":
		ids := make([]string, 0, len(s.streams))
		for id := range s.streams {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		recs := make([]*Stream, 0, len(ids))
		for _, id := range ids {
			recs = append(recs, s.streams[id].rec)
		}
		return resp(seq, map[string]any{"ok": true, "streams": recs})
	case "heads":
		ids := make([]string, 0, len(s.streams))
		for id := range s.streams {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		heads := map[string]*string{}
		for _, id := range ids {
			heads[id] = s.streams[id].rec.Head
		}
		return resp(seq, map[string]any{"ok": true, "heads": heads})
	case "open":
		arg, _ := jsonFieldStr(req, "stream")
		fs := s.streamByNameOrID(arg)
		if fs == nil {
			return refuseResp(seq, "stream_missing", arg)
		}
		return resp(seq, map[string]any{"ok": true, "record": fs.rec})
	case "read":
		arg, _ := jsonFieldStr(req, "stream")
		fs := s.streamByNameOrID(arg)
		if fs == nil {
			return refuseResp(seq, "stream_missing", arg)
		}
		limit := defaultReadLimit
		if raw, ok := req["limit"]; ok {
			var l int
			if json.Unmarshal(raw, &l) == nil && l > 0 {
				if l > 1024 {
					l = 1024
				}
				limit = l
			}
		}
		start := 0
		var after *string
		if raw, ok := req["after"]; ok {
			_ = json.Unmarshal(raw, &after)
		}
		if after != nil {
			found := -1
			for i, line := range fs.lines {
				c, err := ParseChange(line)
				if err == nil && c.ID == *after {
					found = i
					break
				}
			}
			if found < 0 {
				return refuseResp(seq, "change_missing", *after)
			}
			start = found + 1
		}
		end := start + limit
		more := false
		if end < len(fs.lines) {
			more = true
		} else {
			end = len(fs.lines)
		}
		page := make([]string, 0, end-start)
		for _, l := range fs.lines[start:end] {
			page = append(page, string(l))
		}
		return resp(seq, map[string]any{
			"ok": true, "record": fs.rec, "head": fs.rec.Head,
			"changes": page, "more": more,
		})
	case "create":
		raw, ok := req["record"]
		if !ok {
			return refuseResp(seq, "stream_malformed", "")
		}
		var st Stream
		if err := json.Unmarshal(raw, &st); err != nil || st.ID == "" || st.Name == "" || st.Created == 0 {
			return refuseResp(seq, "stream_malformed", "")
		}
		if s.streamByNameOrID(st.ID) != nil || s.streamByNameOrID(st.Name) != nil {
			return refuseResp(seq, "stream_exists", st.Name)
		}
		if st.ForkedFrom != nil {
			if s.streams[st.ForkedFrom.Stream] == nil {
				return refuseResp(seq, "stream_missing", st.ForkedFrom.Stream)
			}
		}
		rec := st
		s.addStream(&rec, nil)
		return resp(seq, map[string]any{"ok": true})
	case "append":
		arg, _ := jsonFieldStr(req, "stream")
		fs := s.streamByNameOrID(arg)
		if fs == nil {
			return refuseResp(seq, "stream_missing", arg)
		}
		var expected *string
		if raw, ok := req["expected_head"]; ok {
			_ = json.Unmarshal(raw, &expected)
		}
		if !ptrEqual(fs.rec.Head, expected) {
			return refuseResp(seq, "stale_head", "expected_head mismatch")
		}
		var rawLines []string
		if raw, ok := req["changes"]; ok {
			_ = json.Unmarshal(raw, &rawLines)
		}
		if len(rawLines) == 0 {
			return refuseResp(seq, "change_malformed", "empty batch")
		}
		prev := expected
		var parsed []Change
		for _, rl := range rawLines {
			c, err := ParseChange([]byte(rl))
			if err != nil {
				return refuseResp(seq, "change_malformed", "")
			}
			if c.Stream != fs.rec.ID {
				return refuseResp(seq, "change_malformed", "stream mismatch")
			}
			if err := validateCommitMessage(c.Message); err != nil {
				return refuseResp(seq, "message_invalid", "")
			}
			if prev == nil {
				if c.Parent != nil {
					return refuseResp(seq, "change_malformed", "non-null root parent")
				}
			} else if c.Parent == nil || *c.Parent != *prev {
				return refuseResp(seq, "change_malformed", "parent mismatch")
			}
			ok, err := VerifyChange(&c)
			if err != nil || !ok {
				return refuseResp(seq, "sig_invalid", "")
			}
			prev = &c.ID
			parsed = append(parsed, c)
		}
		for _, rl := range rawLines {
			fs.lines = append(fs.lines, []byte(rl))
		}
		fs.rec.Head = &parsed[len(parsed)-1].ID
		return resp(seq, map[string]any{"ok": true, "head": *fs.rec.Head})
	default:
		return refuseResp(seq, "usage", "")
	}
}

// loopConn wires the client to a fakeServer request/response loop.
type loopConn struct {
	srv *fakeServer
	in  bytes.Buffer
	out bytes.Buffer
}

func (c *loopConn) Send(p []byte) (int, error) {
	c.in.Write(p)
	for {
		i := bytes.IndexByte(c.in.Bytes(), '\n')
		if i < 0 {
			break
		}
		req := append([]byte(nil), c.in.Bytes()[:i]...)
		c.in.Next(i + 1)
		resp := c.srv.handle(req)
		c.out.Write(resp)
		c.out.WriteByte('\n')
	}
	return len(p), nil
}

func (c *loopConn) Recv(p []byte) (int, error) {
	if c.out.Len() == 0 {
		return 0, errors.New("loop: no response pending")
	}
	return c.out.Read(p)
}

func (c *loopConn) Close() error { return nil }

// dupConn simulates the runner relay's non-dedup re-delivery: every request
// line reaches the server twice and every response line reaches the client
// twice — the exact duplication pattern captured on the wire in the
// go-flint run-11 gate. The client must keep the LAST hello response (a
// re-processed hello regenerates the nonce) and discard the stale copies
// of every later response by seq.
type dupConn struct {
	srv *fakeServer
	in  bytes.Buffer
	out bytes.Buffer
}

func (c *dupConn) Send(p []byte) (int, error) {
	c.in.Write(p)
	for {
		i := bytes.IndexByte(c.in.Bytes(), '\n')
		if i < 0 {
			break
		}
		req := append([]byte(nil), c.in.Bytes()[:i]...)
		c.in.Next(i + 1)
		// Two deliveries of the same request → two processed requests →
		// two identical responses back.
		resp1 := c.srv.handle(req)
		resp2 := c.srv.handle(req)
		c.out.Write(resp1)
		c.out.WriteByte('\n')
		c.out.Write(resp2)
		c.out.WriteByte('\n')
	}
	return len(p), nil
}

func (c *dupConn) Recv(p []byte) (int, error) {
	if c.out.Len() == 0 {
		return 0, errors.New("dup: no response pending")
	}
	return c.out.Read(p)
}

func (c *dupConn) Close() error { return nil }

// SetRecvDeadline enables the handshake drain path in tests.
func (c *dupConn) SetRecvDeadline(int64) {}

// ---------------------------------------------------------------------------
// remoteHarness: a testHarness plus the remote seams — remoteDialFn feeds a
// loopConn to a fakeServer, and storeGetFn serves both `agent-sign` and the
// `flint-remote` shared secret.
// ---------------------------------------------------------------------------

type remoteHarness struct {
	*testHarness
	srv          *fakeServer
	remoteHex    string
	hasRemoteKey bool
	dialed       []string
	connFn       func() wireConn // nil → loopConn
}

func newRemoteHarness(t *testing.T, srv *fakeServer) *remoteHarness {
	h := &remoteHarness{
		testHarness:  newTestHarness(t),
		srv:          srv,
		remoteHex:    strings.Repeat("ab", 32),
		hasRemoteKey: false,
	}
	return h
}

func (h *remoteHarness) runCmd(args ...string) (int, []string) {
	prevFS := activeFS
	prevRoot := storeRoot
	prevUUID := defaultUUIDGen
	prevLog := consoleFn
	prevStoreGet := storeGetFn
	prevDial := remoteDialFn
	defer func() {
		activeFS = prevFS
		storeRoot = prevRoot
		defaultUUIDGen = prevUUID
		consoleFn = prevLog
		storeGetFn = prevStoreGet
		remoteDialFn = prevDial
	}()

	h.logs = nil
	activeFS = h.fs
	storeRoot = h.root
	defaultUUIDGen = h.uuid
	storeGetFn = func(name string, out []byte) int {
		switch name {
		case secretAgentSign:
			if !h.hasSecret {
				return -1
			}
			n := len(h.secretHex)
			if n > len(out) {
				n = len(out)
			}
			copy(out, h.secretHex[:n])
			return n
		case secretRemoteKey:
			if !h.hasRemoteKey {
				return -1
			}
			n := len(h.remoteHex)
			if n > len(out) {
				n = len(out)
			}
			copy(out, h.remoteHex[:n])
			return n
		}
		return -1
	}
	consoleFn = func(s string) {
		h.logs = append(h.logs, s)
	}
	remoteDialFn = func(remote string) (wireConn, error) {
		if _, _, err := parseRemoteURL(remote); err != nil {
			return nil, err
		}
		h.dialed = append(h.dialed, remote)
		if h.connFn != nil {
			return h.connFn(), nil
		}
		return &loopConn{srv: h.srv}, nil
	}
	rc := run(args)
	return rc, append([]string(nil), h.logs...)
}

// signServerChange signs c with the pinned RFC 8032 test seed (the same key
// the sig vectors use) so fakeServer's signature gate passes.
func signServerChange(t *testing.T, c *Change) {
	t.Helper()
	seed, err := hex.DecodeString(testRFC8032SeedHex)
	if err != nil {
		t.Fatal(err)
	}
	if err := signChangeWithSeed(c, seed); err != nil {
		t.Fatalf("signChangeWithSeed: %v", err)
	}
}

// mkSignedStream builds a stream record + n signed Changes (ops can be
// empty) chained parent→child, returns the record and the raw lines.
func mkSignedStream(t *testing.T, h *remoteHarness, name string, n int) (*Stream, [][]byte) {
	t.Helper()
	sid, err := h.uuid.New()
	if err != nil {
		t.Fatal(err)
	}
	st := &Stream{ID: sid, Name: name, Head: nil, Created: 1760000000000, ForkedFrom: nil}
	var lines [][]byte
	var parent *string
	for i := 0; i < n; i++ {
		cid, err := h.uuid.New()
		if err != nil {
			t.Fatal(err)
		}
		c := Change{
			ID: cid, Parent: parent, Stream: sid,
			TS: 1760000000000 + int64(i+1)*1000, Message: "srv change",
			Ops: []Op{}, Merged: nil,
		}
		signServerChange(t, &c)
		line, err := MarshalChangeLine(c)
		if err != nil {
			t.Fatal(err)
		}
		lines = append(lines, bytes.TrimRight(line, "\n"))
		parent = &c.ID
	}
	st.Head = parent
	return st, lines
}

func mustOneLog(t *testing.T, logs []string, prefix string) string {
	t.Helper()
	if len(logs) != 1 || !strings.HasPrefix(logs[0], prefix) {
		t.Fatalf("logs=%v, want single %q line", logs, prefix)
	}
	return logs[0]
}

func TestRemoteClonePullVerify(t *testing.T) {
	srv := newFakeServer()
	h := newRemoteHarness(t, srv)
	st, lines := mkSignedStream(t, h, "main", 2)
	srv.addStream(st, lines)

	rc, logs := h.runCmd("clone", "10.0.0.2:4748", "main")
	if rc != 0 {
		t.Fatalf("clone rc=%d logs=%v", rc, logs)
	}
	mustOneLog(t, logs, "flint: clone ok stream=main changes=2")
	if len(h.dialed) != 1 || h.dialed[0] != "tcp://10.0.0.2:4748" {
		t.Fatalf("dialed=%v", h.dialed)
	}

	// Raw bytes landed verbatim in streams/<id>.jsonl.
	got, err := h.fs.ReadFile("/host/FLINT/streams/"+st.ID+".jsonl", MaxFileReadBytes)
	if err != nil {
		t.Fatalf("read local log: %v", err)
	}
	want := bytes.Join(lines, []byte("\n"))
	want = append(want, '\n')
	if !bytes.Equal(got, want) {
		t.Fatalf("local log not verbatim:\n got: %s\nwant: %s", got, want)
	}
	recBytes, err := h.fs.ReadFile("/host/FLINT/streams/"+st.ID+".json", MaxFileReadBytes)
	if err != nil {
		t.Fatal(err)
	}
	var rec Stream
	if err := json.Unmarshal(recBytes, &rec); err != nil {
		t.Fatal(err)
	}
	if rec.Head == nil || *rec.Head != *st.Head {
		t.Fatalf("local head=%v want %v", rec.Head, st.Head)
	}

	// REMOTE.json binds the remote + stream for bare pull/push.
	rcfg, err := loadRemoteConfig(h.fs, h.root)
	if err != nil || rcfg == nil {
		t.Fatalf("REMOTE.json: %v", err)
	}
	if rcfg.Remote != "tcp://10.0.0.2:4748" || rcfg.Stream != st.ID {
		t.Fatalf("REMOTE.json=%+v", rcfg)
	}

	// Cloned history verifies.
	rc, logs = h.runCmd("verify", "--all")
	if rc != 0 || len(logs) != 2 {
		t.Fatalf("verify --all rc=%d logs=%v", rc, logs)
	}
	for _, l := range logs {
		if !strings.HasSuffix(l, "sig: verified") {
			t.Fatalf("verify line: %q", l)
		}
	}

	// Bare pull resolves remote+stream from REMOTE.json: up to date.
	rc, logs = h.runCmd("pull")
	if rc != 0 {
		t.Fatalf("pull rc=%d logs=%v", rc, logs)
	}
	mustOneLog(t, logs, "flint: pull up to date")

	// Remote-side append: pull lands the new Change verbatim.
	extra, err := h.uuid.New()
	if err != nil {
		t.Fatal(err)
	}
	c3 := Change{
		ID: extra, Parent: st.Head, Stream: st.ID,
		TS: 1760000003000, Message: "srv third",
		Ops: []Op{}, Merged: nil,
	}
	signServerChange(t, &c3)
	l3, err := MarshalChangeLine(c3)
	if err != nil {
		t.Fatal(err)
	}
	srv.streams[st.ID].lines = append(srv.streams[st.ID].lines, bytes.TrimRight(l3, "\n"))
	srv.streams[st.ID].rec.Head = &c3.ID

	rc, logs = h.runCmd("pull")
	if rc != 0 {
		t.Fatalf("pull2 rc=%d logs=%v", rc, logs)
	}
	mustOneLog(t, logs, "flint: pull ok stream=main changes=1")
	got, _ = h.fs.ReadFile("/host/FLINT/streams/"+st.ID+".jsonl", MaxFileReadBytes)
	gl, err := ReadJSONLLines(got)
	if err != nil || len(gl) != 3 {
		t.Fatalf("local log lines=%d err=%v", len(gl), err)
	}
	if !bytes.Equal(gl[2], bytes.TrimRight(l3, "\n")) {
		t.Fatal("pulled line not verbatim")
	}
}

func TestRemotePushAndLsRemote(t *testing.T) {
	srv := newFakeServer()
	h := newRemoteHarness(t, srv)
	if err := h.fs.WriteFileSafe("/host/src/go/sample.go", readCorpusFile(t, "go/sample.go")); err != nil {
		t.Fatal(err)
	}
	if rc, logs := h.runCmd("init", "--name=w", "--src=/host/src"); rc != 0 {
		t.Fatalf("init: %v", logs)
	}
	if rc, logs := h.runCmd("add", "/host/src"); rc != 0 {
		t.Fatalf("add: %v", logs)
	}
	if rc, logs := h.runCmd("commit", "-m", "first"); rc != 0 {
		t.Fatalf("commit: %v", logs)
	}

	// ls-remote before the stream exists remotely: empty list, exit 0.
	rc, logs := h.runCmd("ls-remote", "10.0.0.2:4748")
	if rc != 0 || len(logs) != 0 {
		t.Fatalf("ls-remote empty: rc=%d logs=%v", rc, logs)
	}

	rc, logs = h.runCmd("push", "--remote=10.0.0.2:4748", "--stream=main")
	if rc != 0 {
		t.Fatalf("push rc=%d logs=%v", rc, logs)
	}
	mustOneLog(t, logs, "flint: push ok stream=main changes=1")

	// The server holds the stream and the exact local Change bytes.
	if len(srv.streams) != 1 {
		t.Fatalf("server streams=%d", len(srv.streams))
	}
	var srvSt *fakeStream
	for _, fs := range srv.streams {
		srvSt = fs
	}
	if srvSt.rec.Name != "main" || len(srvSt.lines) != 1 {
		t.Fatalf("server stream=%+v lines=%d", srvSt.rec, len(srvSt.lines))
	}
	local, err := h.fs.ReadFile("/host/FLINT/streams/"+srvSt.rec.ID+".jsonl", MaxFileReadBytes)
	if err != nil {
		t.Fatal(err)
	}
	ll, err := ReadJSONLLines(local)
	if err != nil || len(ll) != 1 {
		t.Fatalf("local lines=%d", len(ll))
	}
	if !bytes.Equal(ll[0], srvSt.lines[0]) {
		t.Fatal("pushed bytes not verbatim")
	}

	// Second push: heads equal → up to date.
	rc, logs = h.runCmd("push", "--remote=10.0.0.2:4748", "--stream=main")
	if rc != 0 {
		t.Fatalf("push2 rc=%d logs=%v", rc, logs)
	}
	mustOneLog(t, logs, "flint: push up to date")

	// ls-remote now lists it.
	rc, logs = h.runCmd("ls-remote", "10.0.0.2:4748")
	if rc != 0 || len(logs) != 1 {
		t.Fatalf("ls-remote: rc=%d logs=%v", rc, logs)
	}
	want := "flint: stream main id=" + srvSt.rec.ID + " head=" + *srvSt.rec.Head
	if logs[0] != want {
		t.Fatalf("ls-remote line=%q want %q", logs[0], want)
	}
}

func TestRemotePushStaleHead(t *testing.T) {
	srv := newFakeServer()
	h := newRemoteHarness(t, srv)
	if err := h.fs.WriteFileSafe("/host/src/go/sample.go", readCorpusFile(t, "go/sample.go")); err != nil {
		t.Fatal(err)
	}
	for _, step := range [][]string{
		{"init", "--name=w", "--src=/host/src"},
		{"add", "/host/src"},
		{"commit", "-m", "first"},
	} {
		if rc, logs := h.runCmd(step...); rc != 0 {
			t.Fatalf("%v: %v", step, logs)
		}
	}
	if rc, logs := h.runCmd("push", "--remote=10.0.0.2:4748", "--stream=main"); rc != 0 {
		t.Fatalf("push: %v", logs)
	}

	// A second client appends a diverging Change on the server.
	var srvSt *fakeStream
	for _, fs := range srv.streams {
		srvSt = fs
	}
	div, err := h.uuid.New()
	if err != nil {
		t.Fatal(err)
	}
	dc := Change{
		ID: div, Parent: srvSt.rec.Head, Stream: srvSt.rec.ID,
		TS: 1760000009000, Message: "other client",
		Ops: []Op{}, Merged: nil,
	}
	signServerChange(t, &dc)
	dl, err := MarshalChangeLine(dc)
	if err != nil {
		t.Fatal(err)
	}
	srvSt.lines = append(srvSt.lines, bytes.TrimRight(dl, "\n"))
	srvSt.rec.Head = &dc.ID

	// Local commits on top of the old head, then pushes: remote head is not
	// in local history → the server's stale_head surfaces by name.
	if err := h.fs.WriteFileSafe("/host/src/go/sample.go", bytes.ReplaceAll(
		readCorpusFile(t, "go/sample.go"), []byte("return a + b"), []byte("return a + b + 1"))); err != nil {
		t.Fatal(err)
	}
	for _, step := range [][]string{
		{"add", "/host/src"},
		{"commit", "-m", "second"},
	} {
		if rc, logs := h.runCmd(step...); rc != 0 {
			t.Fatalf("%v: %v", step, logs)
		}
	}
	rc, logs := h.runCmd("push", "--remote=10.0.0.2:4748", "--stream=main")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse stale_head" {
		t.Fatalf("push stale_head: rc=%d logs=%v", rc, logs)
	}
}

func TestRemotePullForkNeeded(t *testing.T) {
	srv := newFakeServer()
	h := newRemoteHarness(t, srv)
	st, lines := mkSignedStream(t, h, "main", 2)
	srv.addStream(st, lines)

	if rc, logs := h.runCmd("clone", "10.0.0.2:4748", "main"); rc != 0 {
		t.Fatalf("clone: %v", logs)
	}

	// Diverge: the server rewinds to a sibling head the local log lacks.
	st2, lines2 := mkSignedStream(t, h, "main", 1)
	srvSt := srv.streams[st.ID]
	srvSt.lines = lines2
	srvSt.rec.Head = st2.Head

	rc, logs := h.runCmd("pull")
	if rc != 1 || len(logs) != 1 || !strings.HasPrefix(logs[0], "flint: refuse fork_needed") {
		t.Fatalf("pull fork_needed: rc=%d logs=%v", rc, logs)
	}
}

func TestRemoteCloneStreamMissingHint(t *testing.T) {
	srv := newFakeServer()
	h := newRemoteHarness(t, srv)
	st, lines := mkSignedStream(t, h, "main", 1)
	srv.addStream(st, lines)

	rc, logs := h.runCmd("clone", "10.0.0.2:4748", "nope")
	if rc != 1 || len(logs) != 1 {
		t.Fatalf("rc=%d logs=%v", rc, logs)
	}
	if !strings.HasPrefix(logs[0], "flint: refuse stream_missing") ||
		!strings.Contains(logs[0], "(available streams: main)") {
		t.Fatalf("hint line: %q", logs[0])
	}
}

func TestRemoteCloneSigInvalidWritesNothing(t *testing.T) {
	srv := newFakeServer()
	h := newRemoteHarness(t, srv)
	st, lines := mkSignedStream(t, h, "main", 2)
	// Tamper with the second line's sig (flip one nibble).
	bad := append([]byte(nil), lines[1]...)
	i := bytes.LastIndex(bad, []byte(`"sig":"`)) + len(`"sig":"`)
	if bad[i] == 'a' {
		bad[i] = 'b'
	} else {
		bad[i] = 'a'
	}
	lines[1] = bad
	srv.addStream(st, lines)

	rc, logs := h.runCmd("clone", "10.0.0.2:4748", "main")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse sig_invalid" {
		t.Fatalf("rc=%d logs=%v", rc, logs)
	}
	if h.fs.Exists("/host/FLINT/streams/"+st.ID+".jsonl") ||
		h.fs.Exists("/host/FLINT/streams/"+st.ID+".json") ||
		h.fs.Exists("/host/FLINT/REMOTE.json") {
		t.Fatal("sig_invalid clone wrote store files")
	}
}

func TestRemoteAuthSession(t *testing.T) {
	keyBytes, err := hex.DecodeString(strings.Repeat("ab", 32))
	if err != nil {
		t.Fatal(err)
	}
	var key [32]byte
	copy(key[:], keyBytes)

	srv := newFakeServer()
	srv.authKey = &key
	h := newRemoteHarness(t, srv)
	st, lines := mkSignedStream(t, h, "main", 1)
	srv.addStream(st, lines)

	// No flint-remote secret → hello's nonce can't be answered.
	rc, logs := h.runCmd("ls-remote", "10.0.0.2:4748")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse auth_required" {
		t.Fatalf("auth_required: rc=%d logs=%v", rc, logs)
	}

	// Wrong secret → auth_failed by name.
	h.hasRemoteKey = true
	h.remoteHex = strings.Repeat("cd", 32)
	rc, logs = h.runCmd("ls-remote", "10.0.0.2:4748")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse auth_failed" {
		t.Fatalf("auth_failed: rc=%d logs=%v", rc, logs)
	}

	// Right secret → session opens.
	h.remoteHex = strings.Repeat("ab", 32)
	rc, logs = h.runCmd("ls-remote", "10.0.0.2:4748")
	if rc != 0 || len(logs) != 1 || !strings.HasPrefix(logs[0], "flint: stream main id=") {
		t.Fatalf("authed ls-remote: rc=%d logs=%v", rc, logs)
	}

	// Malformed secret (not 64 lowercase hex) → secret_malformed.
	h.remoteHex = "zz" + strings.Repeat("ab", 31)
	rc, logs = h.runCmd("ls-remote", "10.0.0.2:4748")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse secret_malformed" {
		t.Fatalf("secret_malformed: rc=%d logs=%v", rc, logs)
	}
}

// TestRemoteDupDelivery replays the run-11 wire pattern: the runner relay
// forwards a retransmitted guest segment to flintd without dedup, so each
// request is processed twice and each response arrives twice. The client
// must (a) use the LAST hello nonce — a re-processed hello regenerates it —
// and (b) keep the request/response pairing by seq, or every later verb
// consumes a stale copy.
func TestRemoteDupDelivery(t *testing.T) {
	keyBytes, err := hex.DecodeString(strings.Repeat("ab", 32))
	if err != nil {
		t.Fatal(err)
	}
	var key [32]byte
	copy(key[:], keyBytes)

	srv := newFakeServer()
	srv.authKey = &key
	h := newRemoteHarness(t, srv)
	h.hasRemoteKey = true
	h.connFn = func() wireConn { return &dupConn{srv: srv} }
	st, lines := mkSignedStream(t, h, "main", 2)
	srv.addStream(st, lines)

	rc, logs := h.runCmd("clone", "10.0.0.2:4748", "main")
	if rc != 0 {
		t.Fatalf("clone under dup delivery: rc=%d logs=%v", rc, logs)
	}
	mustOneLog(t, logs, "flint: clone ok stream=main changes=2")

	got, err := h.fs.ReadFile("/host/FLINT/streams/"+st.ID+".jsonl", MaxFileReadBytes)
	if err != nil {
		t.Fatal(err)
	}
	want := append(bytes.Join(lines, []byte("\n")), '\n')
	if !bytes.Equal(got, want) {
		t.Fatal("cloned log not verbatim under dup delivery")
	}
}

func TestRemoteMissingAndMalformed(t *testing.T) {
	srv := newFakeServer()
	h := newRemoteHarness(t, srv)

	rc, logs := h.runCmd("pull")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse stream_missing" {
		t.Fatalf("pull no store: rc=%d logs=%v", rc, logs)
	}
	rc, logs = h.runCmd("push", "--remote=10.0.0.2:4748")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse stream_missing" {
		t.Fatalf("push no stream: rc=%d logs=%v", rc, logs)
	}

	// A resolvable local stream with no remote binding → remote_missing.
	sid, err := h.uuid.New()
	if err != nil {
		t.Fatal(err)
	}
	if err := h.fs.WriteFileSafe("/host/FLINT/streams/"+sid+".json",
		[]byte(`{"id":"`+sid+`","name":"main","head":null,"created":1,"forked_from":null}`+"\n")); err != nil {
		t.Fatal(err)
	}
	rc, logs = h.runCmd("pull", "--stream=main")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse remote_missing" {
		t.Fatalf("remote_missing: rc=%d logs=%v", rc, logs)
	}
	rc, logs = h.runCmd("ls-remote", "http://x:1")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse remote_malformed" {
		t.Fatalf("remote_malformed: rc=%d logs=%v", rc, logs)
	}
	rc, logs = h.runCmd("clone")
	if rc != 2 || len(logs) != 1 || logs[0] != "flint: refuse usage" {
		t.Fatalf("clone usage: rc=%d logs=%v", rc, logs)
	}
}
