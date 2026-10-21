package main

import (
	"strings"
	"testing"
)

// --- the /hl verbs ----------------------------------------------------------

func TestHlVerbs(t *testing.T) {
	u := &uiApp{cfg: Config{Nick: "gate"}, evs: make(chan Event, 8),
		scroll: map[string]int{}, st: &ircState{}, localLog: NewBacklog(64)}

	u.submit("/hl")
	if s := lastStatus(u); s != "hl: no highlight words" {
		t.Fatalf("empty list: %q", s)
	}
	u.submit("/hl add virelai")
	if len(u.hl) != 1 || u.hl[0] != "virelai" {
		t.Fatalf("add: %v", u.hl)
	}
	u.submit("/hl add VIRELAI") // case-folded dedup
	if len(u.hl) != 1 {
		t.Fatalf("dup slipped in: %v", u.hl)
	}
	if s := lastStatus(u); s != "hl: already have VIRELAI" {
		t.Fatalf("dup status: %q", s)
	}
	u.submit("/hl add foo")
	u.submit("/hl")
	if s := lastStatus(u); s != "hl: virelai foo" {
		t.Fatalf("list: %q", s)
	}
	u.submit("/hl del FOO") // case-folded del
	if len(u.hl) != 1 || u.hl[0] != "virelai" {
		t.Fatalf("del: %v", u.hl)
	}
	u.submit("/hl del nosuch")
	if s := lastStatus(u); s != "hl: no such word nosuch" {
		t.Fatalf("missing del status: %q", s)
	}
	u.submit("/hl bogus x")
	if s := lastStatus(u); s != "usage: /hl [add|del] <word>" {
		t.Fatalf("usage: %q", s)
	}
}

func TestHlBound(t *testing.T) {
	u := &uiApp{cfg: Config{Nick: "gate"}, evs: make(chan Event, 8),
		scroll: map[string]int{}, st: &ircState{}, localLog: NewBacklog(64)}
	for i := 0; i < hlMax; i++ {
		u.hl = append(u.hl, "w"+string(rune('a'+i)))
	}
	u.submit("/hl add overflow")
	if len(u.hl) != hlMax {
		t.Fatalf("17th rule slipped in: %v", u.hl)
	}
	if s := lastStatus(u); s != "hl: full (16 words)" {
		t.Fatalf("full status: %q", s)
	}
	u.submit("/hl add " + strings.Repeat("x", hlWordMax+1))
	if s := lastStatus(u); s != "hl word too long (max 32)" {
		t.Fatalf("long-word status: %q", s)
	}
}

// --- the matcher + the toast path -------------------------------------------

func TestHlHit(t *testing.T) {
	u := &uiApp{hl: []string{"virelai", "stand-down"}}
	cases := []struct {
		text string
		want bool
	}{
		{"release virelai today", true},
		{"VIRELAI is out", true}, // case-fold
		{"virelai, again", true}, // punctuation boundary
		{"virelais", false},      // prefix inside a word
		{"unvirelai", false},     // suffix inside a word
		{"stand-down now", true},
		{"stand--down", false}, // '-' is a nick byte — still one word
		{"nothing here", false},
	}
	for _, c := range cases {
		if got := u.hlHit(c.text); got != c.want {
			t.Errorf("hlHit(%q) = %v, want %v", c.text, got, c.want)
		}
	}
}

func TestHlRuleArmsPendingMention(t *testing.T) {
	u := &uiApp{cfg: Config{Nick: "gate"}, evs: make(chan Event, 8),
		scroll: map[string]int{}, st: &ircState{}, localLog: NewBacklog(8)}
	u.cli = NewClient(Config{Nick: "gate"}, func() (WireConn, error) { return &fakeConn{}, nil }, nil)
	u.hl = []string{"virelai"}
	// A rule hit without the nick still arms the pending mention — the
	// toast path is the mention path.
	u.onEvent(Event{Kind: EvEntry, Entry: Entry{
		Kind: EntryMsg, Channel: "#goirc", From: "alice", Text: "release virelai today",
	}})
	if u.pendMention != "#goirc" {
		t.Fatalf("rule hit did not arm: %q", u.pendMention)
	}
	// Own echo never arms, even on a rule word.
	u.pendMention = ""
	u.onEvent(Event{Kind: EvEntry, Entry: Entry{
		Kind: EntryMsg, Channel: "#goirc", From: "gate", Text: "virelai from me",
	}})
	if u.pendMention != "" {
		t.Fatalf("own echo armed %q", u.pendMention)
	}
}

// --- blob v3 ---------------------------------------------------------------

func TestStateRoundTripRules(t *testing.T) {
	u := testUI()
	u.hl = []string{"virelai", "stand-down"}
	st := &ircState{}
	if !st.decode(st.encode(u)) {
		t.Fatal("encode→decode refused its own v3 blob")
	}
	if len(st.rules) != 2 || st.rules[0] != "virelai" || st.rules[1] != "stand-down" {
		t.Fatalf("rules: %v", st.rules)
	}
	// And the restore lands them on the app.
	fresh := &uiApp{cfg: Config{}, scroll: map[string]int{}, st: st}
	fresh.applyRestored()
	if len(fresh.hl) != 2 || fresh.hl[0] != "virelai" {
		t.Fatalf("restored hl: %v", fresh.hl)
	}
}

func TestStateV2BlobDecodes(t *testing.T) {
	// A v2 blob (what the M147b app wrote) carries no rules section —
	// decode accepts it with an empty rule set.
	u := testUI()
	b := (&ircState{}).encode(u)
	b[0] = 2
	// Strip the v3 tail: u16 nRules + the rule records. The v2 layout
	// ends after the chan records — find the tail by re-encoding a
	// no-rules app and measuring the delta.
	nr := (&ircState{}).encode(testUI())
	v2 := b[:len(nr)-2] // drop 'u16 0'
	v2[0] = 2
	st := &ircState{}
	if !st.decode(v2) {
		t.Fatal("v2 blob refused")
	}
	if len(st.rules) != 0 {
		t.Fatalf("v2 decoded rules: %v", st.rules)
	}
	if st.host != "irc.example.net" || st.nick != "gate" {
		t.Fatalf("v2 fields: %+v", st)
	}
}

func TestStateRefusesBadRules(t *testing.T) {
	u := testUI()
	good := (&ircState{}).encode(u)
	// Over-count: 17 rules declared.
	bad := append([]byte{}, good...)
	bad[len(bad)-2], bad[len(bad)-1] = byte(hlMax+1), 0
	st := &ircState{}
	if st.decode(bad) {
		t.Fatal("over-count rules decoded")
	}
	// Truncated rules section (count says 1, no record follows).
	trunc := append([]byte{}, good...)
	trunc = trunc[:len(trunc)-2]
	trunc = append(trunc, 1, 0)
	if st.decode(trunc) {
		t.Fatal("truncated rules decoded")
	}
}
