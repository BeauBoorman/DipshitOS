package main

import (
	"strings"
	"testing"
)

func TestParseBasicVerbs(t *testing.T) {
	cases := []struct {
		line        string
		prefix      string
		command     string
		params      []string
		trailing    string
		hasTrailing bool
	}{
		{"NICK gate", "", "NICK", []string{"gate"}, "", false},
		{"USER gate 0 * :Gate User", "", "USER", []string{"gate", "0", "*"}, "Gate User", true},
		{":irc.example.com 001 gate :Welcome to the test net", "irc.example.com", "001", []string{"gate"}, "Welcome to the test net", true},
		{":alice!u@h JOIN #goirc", "alice!u@h", "JOIN", []string{"#goirc"}, "", false},
		{":alice!u@h JOIN :#goirc", "alice!u@h", "JOIN", nil, "#goirc", true},
		{"PING :srv.example.com", "", "PING", nil, "srv.example.com", true},
		{"PING srv.example.com", "", "PING", []string{"srv.example.com"}, "", false},
		{":srv 353 gate = #goirc :@alice +bob gate", "srv", "353", []string{"gate", "=", "#goirc"}, "@alice +bob gate", true},
		{":srv 366 gate #goirc :End of NAMES", "srv", "366", []string{"gate", "#goirc"}, "End of NAMES", true},
		{":srv 433 * gate :Nickname is already in use", "srv", "433", []string{"*", "gate"}, "Nickname is already in use", true},
		{":alice!u@h PRIVMSG #goirc :hello there", "alice!u@h", "PRIVMSG", []string{"#goirc"}, "hello there", true},
		{":alice!u@h NOTICE gate :hi", "alice!u@h", "NOTICE", []string{"gate"}, "hi", true},
		{":alice!u@h PART #goirc :gone", "alice!u@h", "PART", []string{"#goirc"}, "gone", true},
		{":srv CAP gate ACK :sasl", "srv", "CAP", []string{"gate", "ACK"}, "sasl", true},
		{"AUTHENTICATE +", "", "AUTHENTICATE", []string{"+"}, "", false},
		{"QUIT", "", "QUIT", nil, "", false},
		{":alice!u@h QUIT :bye", "alice!u@h", "QUIT", nil, "bye", true},
		{"privmsg #a :lower verb", "", "PRIVMSG", []string{"#a"}, "lower verb", true},
	}
	for _, tc := range cases {
		m, err := ParseLine(tc.line)
		if err != nil {
			t.Fatalf("ParseLine(%q): %v", tc.line, err)
		}
		if m.Prefix != tc.prefix || m.Command != tc.command {
			t.Fatalf("ParseLine(%q) = %q %q, want %q %q", tc.line, m.Prefix, m.Command, tc.prefix, tc.command)
		}
		if len(m.Params) != len(tc.params) {
			t.Fatalf("ParseLine(%q) params=%v want %v", tc.line, m.Params, tc.params)
		}
		for i, p := range tc.params {
			if m.Params[i] != p {
				t.Fatalf("ParseLine(%q) param[%d]=%q want %q", tc.line, i, m.Params[i], p)
			}
		}
		if m.Trailing != tc.trailing || m.HasTrailing != tc.hasTrailing {
			t.Fatalf("ParseLine(%q) trailing=%q,%v want %q,%v", tc.line, m.Trailing, m.HasTrailing, tc.trailing, tc.hasTrailing)
		}
	}
}

func TestParseNumerics(t *testing.T) {
	m, _ := ParseLine(":srv 001 me :hi")
	if m.Numeric() != 1 {
		t.Fatalf("numeric=%d", m.Numeric())
	}
	m, _ = ParseLine("PING x")
	if m.Numeric() != -1 {
		t.Fatalf("verb numeric=%d", m.Numeric())
	}
	m, _ = ParseLine(":srv 999 x")
	if m.Numeric() != 999 {
		t.Fatalf("numeric=%d", m.Numeric())
	}
}

func TestParseRejects(t *testing.T) {
	for _, line := range []string{
		"",
		"   ",
		":onlyprefix",
		": ",
		" cmd",
	} {
		if _, err := ParseLine(line); err == nil {
			t.Fatalf("ParseLine(%q) should refuse", line)
		}
	}
}

func TestParseLineCap(t *testing.T) {
	// 510 payload bytes parse; 511 refuse.
	ok := strings.Repeat("a", 510)
	ok = "PRIVMSG " + ok[8:]
	if _, err := ParseLine(ok); err != nil {
		t.Fatalf("510 B line refused: %v", err)
	}
	over := ok + "x"
	if _, err := ParseLine(over); err == nil || err.Error() != errLineOverlong {
		t.Fatalf("511 B line: err=%v", err)
	}
}

func TestEncodeRoundTrip(t *testing.T) {
	for _, m := range []Message{
		{Command: "NICK", Params: []string{"gate"}},
		{Command: "USER", Params: []string{"gate", "0", "*"}, Trailing: "Gate User", HasTrailing: true},
		{Command: "PONG", Trailing: "srv", HasTrailing: true},
		{Command: "JOIN", Params: []string{"#goirc"}},
		{Command: "QUIT"},
		{Prefix: "me", Command: "PRIVMSG", Params: []string{"#c"}, Trailing: "hi :there", HasTrailing: true},
	} {
		b, err := m.Encode()
		if err != nil {
			t.Fatalf("Encode(%+v): %v", m, err)
		}
		if len(b) > MaxLineBytes || b[len(b)-2] != '\r' || b[len(b)-1] != '\n' {
			t.Fatalf("Encode(%+v) = %q", m, b)
		}
		back, err := ParseLine(string(b[:len(b)-2]))
		if err != nil {
			t.Fatalf("reparse %q: %v", b, err)
		}
		if back.Command != m.Command || len(back.Params) != len(m.Params) ||
			back.Trailing != m.Trailing || back.HasTrailing != m.HasTrailing {
			t.Fatalf("round trip %+v -> %q -> %+v", m, b, back)
		}
	}
}

func TestEncodeRefuses(t *testing.T) {
	over := Message{Command: "PRIVMSG", Params: []string{"#c"}, Trailing: strings.Repeat("x", 510), HasTrailing: true}
	if _, err := over.Encode(); err == nil {
		t.Fatal("overlong encode accepted")
	}
	if _, err := (Message{Command: "PRIVMSG", Params: []string{"#c"}, Trailing: "a\nb", HasTrailing: true}).Encode(); err == nil {
		t.Fatal("trailing with LF accepted")
	}
	if _, err := (Message{Command: "PRIVMSG", Params: []string{":#c"}, Trailing: "t", HasTrailing: true}).Encode(); err == nil {
		t.Fatal("middle param with leading colon accepted")
	}
}

func TestNickFromPrefix(t *testing.T) {
	for in, want := range map[string]string{
		"alice!u@h":      "alice",
		"irc.server.net": "irc.server.net",
		"alice":          "alice",
		"alice@host":     "alice",
	} {
		m := Message{Prefix: in}
		if got := m.NickFromPrefix(); got != want {
			t.Fatalf("NickFromPrefix(%q)=%q want %q", in, got, want)
		}
	}
}

func TestSplitterFraming(t *testing.T) {
	var sp splitter
	lines, _ := sp.feed([]byte("PING one\r\nNICK"))
	if len(lines) != 1 || lines[0] != "PING one" {
		t.Fatalf("partial feed lines=%v", lines)
	}
	lines, _ = sp.feed([]byte(" two\r\nJOIN #a\nPING x\r\n"))
	if len(lines) != 3 || lines[0] != "NICK two" || lines[1] != "JOIN #a" || lines[2] != "PING x" {
		t.Fatalf("resumed lines=%v", lines)
	}
}

func TestSplitterOverlongResync(t *testing.T) {
	var sp splitter
	// A >510 B run then a good line.
	big := strings.Repeat("z", 600)
	lines, over := sp.feed([]byte(big + "\r\nPING ok\r\n"))
	if !over {
		t.Fatal("overlong run not reported")
	}
	if len(lines) != 1 || lines[0] != "PING ok" {
		t.Fatalf("resync failed: %v", lines)
	}
	// Split the overlong run across feeds.
	var sp2 splitter
	if _, over := sp2.feed([]byte(big[:300])); over {
		t.Fatal("early overlong report")
	}
	lines, over = sp2.feed([]byte(big[300:] + "\nOK\r\n"))
	if !over || len(lines) != 1 || lines[0] != "OK" {
		t.Fatalf("split overlong: over=%v lines=%v", over, lines)
	}
}

func TestB64(t *testing.T) {
	for in, want := range map[string]string{
		"":             "",
		"f":            "Zg==",
		"fo":           "Zm8=",
		"foo":          "Zm9v",
		"foob":         "Zm9vYg==",
		"fooba":        "Zm9vYmE=",
		"foobar":       "Zm9vYmFy",
		"a\x00a\x00pw": "YQBhAHB3",
	} {
		if got := b64encode([]byte(in)); got != want {
			t.Fatalf("b64(%q)=%q want %q", in, got, want)
		}
	}
}
