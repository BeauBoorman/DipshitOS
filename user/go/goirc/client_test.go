package main

import (
	"errors"
	"strings"
	"testing"
)

// --- scripted fakes -------------------------------------------------------

var errFakeEOF = errors.New("fake: peer gone")
var errFakeTimeout = errors.New("ETIMEDOUT") // matches isTimeoutErr's vi string

type readItem struct {
	data string
	err  error
}

// fakeConn plays a scripted read sequence then returns rerr (errFakeEOF
// when unset). Writes are recorded verbatim.
type fakeConn struct {
	reads    []readItem
	rerr     error
	writes   []string
	closed   bool
	deadline int64
}

func (f *fakeConn) Read(p []byte) (int, error) {
	if f.closed {
		return 0, errFakeEOF
	}
	if len(f.reads) == 0 {
		if f.rerr != nil {
			return 0, f.rerr
		}
		return 0, errFakeEOF
	}
	it := f.reads[0]
	f.reads = f.reads[1:]
	if it.err != nil {
		return 0, it.err
	}
	return copy(p, it.data), nil
}

func (f *fakeConn) Write(p []byte) (int, error) {
	f.writes = append(f.writes, string(p))
	return len(p), nil
}

func (f *fakeConn) SetReadDeadline(at int64) { f.deadline = at }
func (f *fakeConn) Close() error             { f.closed = true; return nil }

func lines(s ...string) []readItem {
	out := make([]readItem, len(s))
	for i, l := range s {
		out[i].data = l + "\r\n"
	}
	return out
}

func allWrites(f *fakeConn) string { return strings.Join(f.writes, "") }

// harness wires a client to fake conns and collects events/sleeps.
type harness struct {
	conns   []*fakeConn
	dials   int
	dialErr error
	events  []Event
	sleeps  []int64
	nowv    int64
	onEvent func(*Client, Event)
}

func (h *harness) dial() (WireConn, error) {
	h.dials++
	if h.dialErr != nil {
		return nil, h.dialErr
	}
	if len(h.conns) == 0 {
		return nil, errFakeEOF
	}
	c := h.conns[0]
	h.conns = h.conns[1:]
	return c, nil
}

func (h *harness) client(cfg Config) *Client {
	var c *Client
	emit := func(e Event) {
		h.events = append(h.events, e)
		if h.onEvent != nil {
			h.onEvent(c, e)
		}
	}
	c = NewClient(cfg, h.dial, emit)
	c.sleep = func(ns int64) { h.sleeps = append(h.sleeps, ns) }
	c.now = func() int64 { return h.nowv }
	return c
}

func (h *harness) kinds() []EventKind {
	out := make([]EventKind, len(h.events))
	for i, e := range h.events {
		out[i] = e.Kind
	}
	return out
}

func (h *harness) hasKind(k EventKind) bool {
	for _, e := range h.events {
		if e.Kind == k {
			return true
		}
	}
	return false
}

func (h *harness) rejoinChans() []string {
	var out []string
	for _, e := range h.events {
		if e.Kind == EvRejoined {
			out = append(out, e.Channel)
		}
	}
	return out
}

func baseCfg() Config {
	return Config{
		Host: "10.0.0.2", Port: 6667,
		Nick: "gate", AllowPlain: true,
		Channels:  []string{"#goirc"},
		Reconnect: false,
	}
}

// --- tests ----------------------------------------------------------------

func TestRegisterJoinRecv(t *testing.T) {
	fc := &fakeConn{reads: lines(
		":srv 001 gate :Welcome",
		":srv 353 gate = #goirc :@alice gate",
		":srv 366 gate #goirc :End of NAMES",
		":gate!u@h JOIN #goirc",
		":alice!u@h PRIVMSG #goirc :hello world",
	)}
	h := &harness{conns: []*fakeConn{fc}}
	joinedSeen := false
	h.onEvent = func(c *Client, e Event) {
		if e.Kind == EvJoined {
			for _, ch := range c.Joined() {
				if ch == "#goirc" {
					joinedSeen = true
				}
			}
		}
	}
	c := h.client(baseCfg())

	err := c.Run()
	if !errors.Is(err, errFakeEOF) {
		t.Fatalf("Run err=%v", err)
	}
	got := allWrites(fc)
	for _, want := range []string{"NICK gate\r\n", "USER gate 0 * :gate\r\n", "JOIN #goirc\r\n"} {
		if !strings.Contains(got, want) {
			t.Fatalf("writes missing %q: %q", want, got)
		}
	}
	if !h.hasKind(EvRegistered) || !h.hasKind(EvJoined) || !h.hasKind(EvNames) {
		t.Fatalf("missing events: %v", h.kinds())
	}
	entries := c.Backlog("#goirc").Entries()
	found := false
	for _, e := range entries {
		if e.Kind == EntryMsg && e.From == "alice" && e.Text == "hello world" {
			found = true
		}
	}
	if !found {
		t.Fatalf("backlog missing message: %+v", entries)
	}
	if !joinedSeen {
		t.Fatal("EvJoined fired without #goirc in Joined()")
	}
	for _, e := range h.events {
		if e.Kind == EvNames && (len(e.Names) != 2 || e.Names[0] != "@alice") {
			t.Fatalf("names=%v", e.Names)
		}
	}
}

func TestPingPong(t *testing.T) {
	fc := &fakeConn{reads: lines(
		":srv 001 gate :Welcome",
		"PING :token-1",
	)}
	h := &harness{conns: []*fakeConn{fc}}
	c := h.client(baseCfg())
	_ = c.Run()
	if !strings.Contains(allWrites(fc), "PONG :token-1\r\n") {
		t.Fatalf("no PONG in %q", allWrites(fc))
	}
}

func TestReconnectRejoin(t *testing.T) {
	c1 := &fakeConn{reads: lines(
		":srv 001 gate :Welcome",
		":gate!u@h JOIN #goirc",
		":alice!u@h PRIVMSG #goirc :first",
	)}
	c2 := &fakeConn{reads: lines(
		":srv 001 gate :Welcome again",
		":gate!u@h JOIN #goirc",
		":alice!u@h PRIVMSG #goirc :after-rejoin",
	)}
	cfg := baseCfg()
	cfg.Reconnect = true
	cfg.MaxRetries = 1
	cfg.BackoffBase = 100
	cfg.BackoffMax = 400
	h := &harness{conns: []*fakeConn{c1, c2}}
	c := h.client(cfg)

	err := c.Run()
	if !errors.Is(err, errFakeEOF) {
		t.Fatalf("Run err=%v", err)
	}
	if h.dials != 2 {
		t.Fatalf("dials=%d", h.dials)
	}
	if len(h.sleeps) != 1 || h.sleeps[0] != 100 {
		t.Fatalf("sleeps=%v", h.sleeps)
	}
	if !strings.Contains(allWrites(c2), "JOIN #goirc\r\n") {
		t.Fatalf("rejoin JOIN missing in conn2 writes: %q", allWrites(c2))
	}
	rej := h.rejoinChans()
	if len(rej) != 1 || rej[0] != "#goirc" {
		t.Fatalf("EvRejoined=%v", rej)
	}
	var texts []string
	for _, e := range c.Backlog("#goirc").Entries() {
		texts = append(texts, e.Text)
	}
	if !contains(texts, "first") || !contains(texts, "after-rejoin") {
		t.Fatalf("backlog=%v", texts)
	}
	if !h.hasKind(EvDrop) || !h.hasKind(EvBackoff) {
		t.Fatalf("missing drop/backoff events: %v", h.kinds())
	}
}

func TestReconnectRespectsMaxRetries(t *testing.T) {
	cfg := baseCfg()
	cfg.Reconnect = true
	cfg.MaxRetries = 2
	cfg.BackoffBase = 100
	cfg.BackoffMax = 1000
	h := &harness{dialErr: errors.New("dial refused")}
	c := h.client(cfg)
	err := c.Run()
	if err == nil {
		t.Fatal("Run succeeded with a dead dialer")
	}
	// initial + 2 retries = 3 failed sessions, then fails(3) > MaxRetries(2)
	if h.dials != 3 {
		t.Fatalf("dials=%d want 3", h.dials)
	}
	if len(h.sleeps) != 2 || h.sleeps[0] != 100 || h.sleeps[1] != 200 {
		t.Fatalf("sleeps=%v", h.sleeps)
	}
}

func TestPlaintextRefusedWithoutConsent(t *testing.T) {
	cfg := baseCfg()
	cfg.AllowPlain = false
	cfg.Reconnect = true
	h := &harness{}
	var c *Client
	c = NewClient(cfg, dialGuest(cfg), func(e Event) {
		h.events = append(h.events, e)
		if h.onEvent != nil {
			h.onEvent(c, e)
		}
	})
	c.sleep = func(ns int64) { h.sleeps = append(h.sleeps, ns) }
	err := c.Run()
	if err == nil || !strings.Contains(err.Error(), "refuse plaintext") {
		t.Fatalf("err=%v", err)
	}
	if !isFatal(err) {
		t.Fatal("plaintext refusal must be fatal — no reconnect")
	}
	if len(h.sleeps) != 0 {
		t.Fatalf("slept after fatal: %v", h.sleeps)
	}
	// The event stream must carry the refusal for the UI/console marker.
	found := false
	for _, e := range h.events {
		if e.Kind == EvError && strings.Contains(errText(e.Err), "refuse plaintext") {
			found = true
		}
	}
	if !found {
		t.Fatalf("no refusal event: %v", h.kinds())
	}
}

func TestNickInUseRetries(t *testing.T) {
	fc := &fakeConn{reads: lines(
		":srv 433 * gate :in use",
		":srv 433 * gate_ :in use",
		":srv 001 gate__ :Welcome",
		":gate__!u@h JOIN #goirc",
	)}
	h := &harness{conns: []*fakeConn{fc}}
	c := h.client(baseCfg())
	_ = c.Run()
	got := allWrites(fc)
	for _, want := range []string{"NICK gate\r\n", "NICK gate_\r\n", "NICK gate__\r\n"} {
		if !strings.Contains(got, want) {
			t.Fatalf("writes missing %q: %q", want, got)
		}
	}
	if c.Nick() != "gate__" {
		t.Fatalf("nick=%q", c.Nick())
	}
}

func TestNickInUseFatalAfterRetries(t *testing.T) {
	fc := &fakeConn{reads: lines(
		":srv 433 * gate :in use",
		":srv 433 * gate_ :in use",
		":srv 433 * gate__ :in use",
		":srv 433 * gate___ :in use",
	)}
	cfg := baseCfg()
	cfg.Reconnect = true // fatal must not be retried anyway
	h := &harness{conns: []*fakeConn{fc}}
	c := h.client(cfg)
	err := c.Run()
	if err == nil || !isFatal(err) {
		t.Fatalf("err=%v", err)
	}
	if h.dials != 1 {
		t.Fatalf("dials=%d — fatal must not redial", h.dials)
	}
	if !h.hasKind(EvNickInUse) {
		t.Fatalf("no EvNickInUse: %v", h.kinds())
	}
}

func TestSASLPlainFlow(t *testing.T) {
	fc := &fakeConn{reads: lines(
		":srv CAP gate ACK :sasl",
		"AUTHENTICATE +",
		":srv 903 gate :SASL authentication successful",
		":srv 001 gate :Welcome",
		":gate!u@h JOIN #goirc",
	)}
	cfg := baseCfg()
	cfg.SASL = &SASLConfig{Account: "acct", Password: "pw"}
	h := &harness{conns: []*fakeConn{fc}}
	c := h.client(cfg)
	_ = c.Run()
	got := allWrites(fc)
	// Registration opens with CAP REQ, then NICK/USER.
	if !strings.HasPrefix(got, "CAP REQ :sasl\r\nNICK gate\r\n") {
		t.Fatalf("registration order: %q", got)
	}
	if !strings.Contains(got, "AUTHENTICATE PLAIN\r\n") {
		t.Fatalf("no AUTHENTICATE PLAIN: %q", got)
	}
	want := "AUTHENTICATE " + b64encode([]byte("acct\x00acct\x00pw")) + "\r\n"
	if !strings.Contains(got, want) {
		t.Fatalf("no credentials %q in %q", want, got)
	}
	if !strings.Contains(got, "CAP END\r\n") {
		t.Fatalf("no CAP END: %q", got)
	}
	ok := false
	for _, e := range h.events {
		if e.Kind == EvSASLResult && e.Text == "ok" {
			ok = true
		}
	}
	if !ok {
		t.Fatalf("no sasl-ok event: %v", h.kinds())
	}
}

func TestSASLFailsClosed(t *testing.T) {
	fc := &fakeConn{reads: lines(
		":srv CAP gate NAK :sasl",
		":srv 001 gate :Welcome",
	)}
	cfg := baseCfg()
	cfg.SASL = &SASLConfig{Account: "acct", Password: "pw"}
	h := &harness{conns: []*fakeConn{fc}}
	c := h.client(cfg)
	_ = c.Run()
	got := allWrites(fc)
	if strings.Contains(got, "AUTHENTICATE") {
		t.Fatalf("NAK'd SASL still authenticated: %q", got)
	}
	if !strings.Contains(got, "CAP END\r\n") {
		t.Fatalf("no CAP END after NAK: %q", got)
	}
	fail := false
	for _, e := range h.events {
		if e.Kind == EvSASLResult && e.Text == "fail" {
			fail = true
		}
	}
	if !fail {
		t.Fatal("no sasl-fail event")
	}
}

func TestIdleTimeoutSendsPingThenDrops(t *testing.T) {
	c1 := &fakeConn{reads: append(lines(":srv 001 gate :Welcome"),
		readItem{err: errFakeTimeout}, // idle → PING
		readItem{err: errFakeTimeout}, // no PONG → dead
	)}
	cfg := baseCfg()
	cfg.Reconnect = true
	cfg.MaxRetries = 1
	cfg.BackoffBase = 50
	h := &harness{conns: []*fakeConn{c1, {reads: nil, rerr: errFakeEOF}}}
	c := h.client(cfg)
	_ = c.Run()
	if !strings.Contains(allWrites(c1), "PING :goirc\r\n") {
		t.Fatalf("no liveness PING: %q", allWrites(c1))
	}
	if !h.hasKind(EvDrop) {
		t.Fatal("pong-timeout did not drop")
	}
}

func TestOverlongLineDroppedNotFatal(t *testing.T) {
	big := strings.Repeat("z", 600)
	fc := &fakeConn{reads: []readItem{
		{data: ":srv 001 gate :Welcome\r\n"},
		{data: big + "\r\n"},
		{data: ":a!u@h PRIVMSG #goirc :survived\r\n"},
	}}
	h := &harness{conns: []*fakeConn{fc}}
	c := h.client(baseCfg())
	_ = c.Run()
	var kinds []EntryKind
	var sawOverlong, sawMsg bool
	for _, e := range c.Backlog("").Entries() {
		kinds = append(kinds, e.Kind)
		if strings.Contains(e.Text, "overlong") {
			sawOverlong = true
		}
	}
	for _, e := range c.Backlog("#goirc").Entries() {
		if e.Text == "survived" {
			sawMsg = true
		}
	}
	if !sawOverlong || !sawMsg {
		t.Fatalf("overlong=%v msg=%v status=%v", sawOverlong, sawMsg, kinds)
	}
}

func TestQuitIsClean(t *testing.T) {
	fc := &fakeConn{reads: lines(":srv 001 gate :Welcome")}
	h := &harness{conns: []*fakeConn{fc}}
	cfg := baseCfg()
	cfg.Reconnect = true
	h.onEvent = func(c *Client, e Event) {
		if e.Kind == EvRegistered {
			_ = c.Quit("bye")
		}
	}
	c := h.client(cfg)
	if err := c.Run(); err != nil {
		t.Fatalf("Run after Quit err=%v", err)
	}
	if !strings.Contains(allWrites(fc), "QUIT :bye\r\n") {
		t.Fatalf("no QUIT: %q", allWrites(fc))
	}
	if h.dials != 1 {
		t.Fatalf("dials=%d — quit must not reconnect", h.dials)
	}
	if !h.hasKind(EvQuit) {
		t.Fatal("no EvQuit")
	}
}

func TestKickEndsRejoinIntent(t *testing.T) {
	c1 := &fakeConn{reads: lines(
		":srv 001 gate :Welcome",
		":gate!u@h JOIN #goirc",
		":op!u@h KICK #goirc gate :out",
	)} // then EOF → reconnect
	c2 := &fakeConn{reads: lines(":srv 001 gate :Welcome")}
	cfg := baseCfg()
	cfg.Reconnect = true
	cfg.MaxRetries = 1
	h := &harness{conns: []*fakeConn{c1, c2}}
	c := h.client(cfg)
	_ = c.Run()
	if strings.Contains(allWrites(c2), "JOIN #goirc") {
		t.Fatal("kicked channel was rejoined")
	}
	if len(h.rejoinChans()) != 0 {
		t.Fatalf("EvRejoined on kicked channel: %v", h.rejoinChans())
	}
}

func TestBackoffDelayShape(t *testing.T) {
	for attempt, want := range map[int]int64{1: 500, 2: 1000, 3: 2000, 4: 3000, 9: 3000} {
		if got := backoffDelay(500, 3000, attempt); got != want {
			t.Fatalf("backoffDelay(attempt=%d)=%d want %d", attempt, got, want)
		}
	}
}

func contains(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}
