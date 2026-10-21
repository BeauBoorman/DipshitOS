package main

import (
	"errors"
	"strings"
	"testing"
)

// fakeLogHost captures the share writes a chanLog publishes.
type fakeLogHost struct {
	mkdirs []string
	writes map[string][]byte
	failMk error
	failWr error
}

func (f *fakeLogHost) MkdirShare(path string) error {
	if f.failMk != nil {
		return f.failMk
	}
	f.mkdirs = append(f.mkdirs, path)
	return nil
}

func (f *fakeLogHost) WriteShareFile(path string, b []byte) error {
	if f.failWr != nil {
		return f.failWr
	}
	if f.writes == nil {
		f.writes = map[string][]byte{}
	}
	f.writes[path] = append([]byte{}, b...)
	return nil
}

// --- file-name sanitizing -------------------------------------------------

func TestSanitizeFilePart(t *testing.T) {
	cases := []struct{ in, want string }{
		{"#goirc", "GOIRC"},
		{"10.0.0.2", "10-0-0-2"},
		{"irc.example.net", "IRC-EXAMPLE-NET"},
		{"#a&b+c!d", "A-B-C-D"},
		{"---", "X"},        // all punctuation → fallback
		{"", "X"},           // empty → fallback
		{"#-chan-", "CHAN"}, // edges stripped
		{"MixedCase", "MIXEDCASE"},
	}
	for _, c := range cases {
		if got := sanitizeFilePart(c.in, logChanMax); got != c.want {
			t.Errorf("sanitizeFilePart(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSanitizeFilePartBound(t *testing.T) {
	long := "#" + strings.Repeat("channelname", 8) // ~89 bytes → bound
	got := sanitizeFilePart(long, logChanMax)
	if len(got) > logChanMax {
		t.Fatalf("bound: %d > %d", len(got), logChanMax)
	}
	if got != strings.ToUpper(strings.Repeat("channelname", 8))[:logChanMax] {
		t.Fatalf("bound cut: %q", got)
	}
	// A cut that lands on a '-' strips it.
	got = sanitizeFilePart("abcdefg-hijk", 8)
	if got != "ABCDEFG" {
		t.Fatalf("dash-edge cut: %q", got)
	}
}

func TestLogPathFitsTempCap(t *testing.T) {
	// The kernel's file table caps a path at 64 bytes and WriteFileSafe
	// publishes through a one-byte '~' temp — the worst-case path must
	// stay under it.
	p := logPath(strings.Repeat("h", 300), "#"+strings.Repeat("c", 300))
	if len(p)+1 > 64 {
		t.Fatalf("path %q (%d) + temp overflows the 64-byte cap", p, len(p))
	}
	if p != logDir+"/"+strings.Repeat("H", logNetMax)+"-"+strings.Repeat("C", logChanMax)+".LOG" {
		t.Fatalf("path shape: %q", p)
	}
}

// --- the log ring bound ----------------------------------------------------

func TestChanLogCapDropsOldest(t *testing.T) {
	l := &chanLog{path: "/x"}
	// 1000-byte lines (under the per-line bound): the 65th crosses the
	// 64 KiB file cap, so the oldest drop and the truncated header is
	// owed.
	line := strings.Repeat("l", 1000)
	for i := 0; i < 70; i++ {
		l.add(line)
	}
	if len(l.body()) > logMaxBytes {
		t.Fatalf("body over cap: %d", len(l.body()))
	}
	if !l.truncated {
		t.Fatal("cap drop did not mark truncated")
	}
	if !strings.HasPrefix(string(l.body()), "# truncated\n") {
		t.Fatalf("body lacks the truncation header: %q", l.body()[:20])
	}
}

func TestChanLogNoTruncationUnderCap(t *testing.T) {
	l := &chanLog{path: "/x"}
	for i := 0; i < 40; i++ {
		l.add("short")
	}
	if l.truncated {
		t.Fatal("short lines must not truncate")
	}
	if strings.HasPrefix(string(l.body()), "# truncated") {
		t.Fatal("untruncated body carries the header")
	}
}

func TestChanLogLineBound(t *testing.T) {
	l := &chanLog{path: "/x"}
	l.add(strings.Repeat("z", logLineMax+500))
	if len(l.lines[0]) != logLineMax {
		t.Fatalf("line bound: %d", len(l.lines[0]))
	}
}

// --- flush cadence ---------------------------------------------------------

func TestChanLogFlushCadence(t *testing.T) {
	l := &chanLog{path: "/host/GOIRC/N-C.LOG"}
	h := &fakeLogHost{}
	// 31 lines: pending, no write.
	for i := 0; i < logFlushEvery-1; i++ {
		if l.add("line") {
			t.Fatal("flush fired early")
		}
	}
	if len(h.writes) != 0 {
		t.Fatal("write before the cadence")
	}
	// The 32nd line returns "flush due"; the caller flushes.
	if !l.add("line") {
		t.Fatal("cadence did not fire at 32")
	}
	if err := l.flush(h); err != nil {
		t.Fatalf("flush: %v", err)
	}
	if len(h.writes[l.path]) == 0 {
		t.Fatal("no file written at the cadence")
	}
	body := string(h.writes[l.path])
	if n := strings.Count(body, "\n"); n != logFlushEvery {
		t.Fatalf("file holds %d lines, want %d", n, logFlushEvery)
	}
	if l.pending != 0 {
		t.Fatalf("pending after flush: %d", l.pending)
	}
	// A no-op flush writes nothing new.
	h2 := &fakeLogHost{}
	if err := l.flush(h2); err != nil || len(h2.writes) != 0 {
		t.Fatal("empty flush must be free")
	}
}

func TestChanLogBodyAccumulates(t *testing.T) {
	l := &chanLog{path: "/p"}
	h := &fakeLogHost{}
	for i := 0; i < logFlushEvery+5; i++ {
		if l.add("line-"+string(rune('a'+i))) && i == logFlushEvery-1 {
			_ = l.flush(h)
		}
	}
	_ = l.flush(h) // the part/quit flush
	body := string(h.writes["/p"])
	// The rewrite carries the WHOLE retained set, not a delta — the
	// second publish holds every line, flushed or not.
	for i := 0; i < logFlushEvery+5; i++ {
		if !strings.Contains(body, "line-"+string(rune('a'+i))) {
			t.Fatalf("body missing line %d: %q", i, body[:80])
		}
	}
}

func TestChanLogFlushError(t *testing.T) {
	l := &chanLog{path: "/p"}
	l.add("x")
	h := &fakeLogHost{failWr: errors.New("publish -5")}
	if err := l.flush(h); err == nil {
		t.Fatal("write failure must surface")
	}
	if l.pending == 0 {
		t.Fatal("failed flush must not clear pending")
	}
}

// --- formatting + routing ---------------------------------------------------

func TestFormatLogLine(t *testing.T) {
	if got := formatLogLine(Entry{Kind: EntryMsg, From: "alice", Text: "hi"}); got != "<alice> hi" {
		t.Fatalf("msg: %q", got)
	}
	if got := formatLogLine(Entry{Kind: EntryJoin, Text: "bob joined"}); got != "* bob joined" {
		t.Fatalf("join: %q", got)
	}
	if got := formatLogLine(Entry{Kind: EntryError, Text: "boom"}); got != "! boom" {
		t.Fatalf("err: %q", got)
	}
}

func testLogUI() *uiApp {
	u := &uiApp{
		cfg:      Config{Host: "10.0.0.2", Nick: "gate"},
		bufs:     []string{"", "#goirc"},
		focus:    1,
		scroll:   map[string]int{},
		st:       &ircState{},
		logs:     map[string]*chanLog{},
		localLog: NewBacklog(64),
	}
	u.logH = &fakeLogHost{}
	u.cli = NewClient(Config{Nick: "gate"}, func() (WireConn, error) { return &fakeConn{}, nil }, nil)
	return u
}

func TestLogVerbOnOff(t *testing.T) {
	u := testLogUI()
	u.submit("/log on")
	if u.logs["#goirc"] == nil {
		t.Fatal("/log on did not arm #goirc")
	}
	if u.logs["#goirc"].path != "/host/GOIRC/10-0-0-2-GOIRC.LOG" {
		t.Fatalf("path: %q", u.logs["#goirc"].path)
	}
	u.submit("/log on")
	if s := lastStatus(u); s != "log: already on for #goirc" {
		t.Fatalf("repeat on: %q", s)
	}
	u.submit("/log")
	if s := lastStatus(u); s != "log: #goirc" {
		t.Fatalf("list: %q", s)
	}
	u.submit("/log off")
	if u.logs["#goirc"] != nil {
		t.Fatal("/log off did not disarm")
	}
	u.submit("/log")
	if s := lastStatus(u); s != "log: no channels logging" {
		t.Fatalf("empty list: %q", s)
	}
}

func TestLogVerbNamedChannel(t *testing.T) {
	u := testLogUI()
	u.submit("/log on #other")
	if u.logs["#other"] == nil {
		t.Fatal("/log on #other did not arm #other")
	}
	u.submit("/log on bogus")
	if s := lastStatus(u); s != "usage: /log [on|off] [#channel]" {
		t.Fatalf("non-channel: %q", s)
	}
}

func TestLogAddRoutesAndFlushes(t *testing.T) {
	u := testLogUI()
	u.submit("/log on")
	// Feed entries through the event path: unarmed channel logs nothing;
	// the armed one accumulates and the 32nd entry publishes.
	u.onEvent(Event{Kind: EvEntry, Entry: Entry{Kind: EntryMsg, Channel: "#nowhere", From: "a", Text: "x"}})
	if len(u.logs) != 1 {
		t.Fatal("unarmed channel logged")
	}
	for i := 0; i < logFlushEvery; i++ {
		u.onEvent(Event{Kind: EvEntry, Entry: Entry{
			Kind: EntryMsg, Channel: "#goirc", From: "alice",
			Text: "msg" + string(rune('0'+i%10)),
		}})
	}
	h := u.logH.(*fakeLogHost)
	body, ok := h.writes["/host/GOIRC/10-0-0-2-GOIRC.LOG"]
	if !ok {
		t.Fatal("no publish at the cadence")
	}
	if !strings.Contains(string(body), "<alice> msg") {
		t.Fatalf("body: %q", body[:60])
	}
	if n := strings.Count(string(body), "\n"); n != logFlushEvery {
		t.Fatalf("body lines %d want %d", n, logFlushEvery)
	}
}

func TestLogAddPartFlush(t *testing.T) {
	u := testLogUI()
	u.submit("/log on")
	u.onEvent(Event{Kind: EvEntry, Entry: Entry{Kind: EntryMsg, Channel: "#goirc", From: "alice", Text: "hi"}})
	// Own PART closes the log out under the 32-line cadence.
	u.onEvent(Event{Kind: EvEntry, Entry: Entry{Kind: EntryPart, Channel: "#goirc", From: "gate", Text: "gate left"}})
	h := u.logH.(*fakeLogHost)
	body, ok := h.writes["/host/GOIRC/10-0-0-2-GOIRC.LOG"]
	if !ok {
		t.Fatal("own part did not flush")
	}
	if !strings.Contains(string(body), "* gate left") {
		t.Fatalf("part line not in the file: %q", body)
	}
}

func TestLogFlushAllOnQuit(t *testing.T) {
	u := testLogUI()
	u.submit("/log on")
	u.onEvent(Event{Kind: EvEntry, Entry: Entry{Kind: EntryMsg, Channel: "#goirc", From: "alice", Text: "one"}})
	u.flushAllLogs()
	h := u.logH.(*fakeLogHost)
	if len(h.writes["/host/GOIRC/10-0-0-2-GOIRC.LOG"]) == 0 {
		t.Fatal("quit flush published nothing")
	}
}
