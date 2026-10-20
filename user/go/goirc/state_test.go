package main

import (
	"testing"

	"virelai/tabapp"
	"virelai/vi"
)

// viEvent builds a bare window event of the given kind.
func viEvent(kind uint16) vi.Event { return vi.Event{Kind: kind} }

// fakeTabApp is a canvas-less TabApp shell for geometry-only tests.
func fakeTabApp(w, h uint32) *tabapp.TabApp {
	return &tabapp.TabApp{W: w, H: h}
}

// --- save_state codec -----------------------------------------------------

func testUI() *uiApp {
	return &uiApp{
		cfg: Config{
			Host: "irc.example.net", Port: 6697, TLS: true,
			ServerName: "leaf.example.com",
			Nick:       "gate", Channels: []string{"#goirc", "#other"},
		},
		bufs:   []string{"", "#goirc", "#other"},
		focus:  2,
		scroll: map[string]int{"#other": 7},
		st:     &ircState{},
	}
}

func TestStateRoundTrip(t *testing.T) {
	u := testUI()
	st := &ircState{}
	if !st.decode(st.encode(u)) {
		t.Fatal("encode→decode refused its own blob")
	}
	if st.host != "irc.example.net" || st.port != 6697 || !st.tls {
		t.Fatalf("server fields: %+v", st)
	}
	if st.sni != "leaf.example.com" {
		t.Fatalf("sni: %q", st.sni)
	}
	if st.nick != "gate" || st.focus != "#other" {
		t.Fatalf("nick/focus: %+v", st)
	}
	if len(st.chans) != 3 || st.chans[0].name != "" ||
		st.chans[1].name != "#goirc" || st.chans[2].name != "#other" {
		t.Fatalf("chans: %+v", st.chans)
	}
	if st.chans[2].scroll != 7 {
		t.Fatalf("scroll: got %d want 7", st.chans[2].scroll)
	}
}

func TestStateConsentBit(t *testing.T) {
	u := testUI()
	u.cfg.TLS = false
	u.cfg.AllowPlain = true
	st := &ircState{}
	if !st.decode(st.encode(u)) {
		t.Fatal("refused")
	}
	if !st.consent || st.tls {
		t.Fatalf("flags: consent=%v tls=%v", st.consent, st.tls)
	}
}

func TestStateRefusesGarbage(t *testing.T) {
	u := testUI()
	good := (&ircState{}).encode(u)
	cases := map[string][]byte{
		"empty":       {},
		"short":       good[:6],
		"bad-version": append([]byte{9}, good[1:]...),
		"trailing":    append(append([]byte{}, good...), 0xff),
		"truncated":   good[:len(good)-2],
	}
	for name, b := range cases {
		st := &ircState{}
		if st.decode(b) {
			t.Fatalf("%s: decoded a bad blob", name)
		}
		if st.restored {
			t.Fatalf("%s: refusal still marked restored", name)
		}
	}
	// A declared length that overruns the buffer.
	bad := append([]byte{}, good[:4]...)
	bad[2], bad[3] = 0xff, 0x00
	st := &ircState{}
	if st.decode(bad) {
		t.Fatal("over-declared host length decoded")
	}
}

func TestStateRefusesNonChannel(t *testing.T) {
	// A blob carrying a non-channel buffer name (other than the "" server
	// slot) is refused whole — it would smuggle junk into the rejoin set.
	u := testUI()
	b := (&ircState{}).encode(u)
	st := &ircState{}
	if !st.decode(b) {
		t.Fatal("baseline refused")
	}
	// Rewrite the "#goirc" buffer entry to "xgoirc" — same length, not a
	// channel. The channel records live AFTER the focus field, so match
	// the name bytes themselves.
	idx := -1
	for i := 0; i+6 <= len(b); i++ {
		if string(b[i:i+6]) == "#goirc" {
			idx = i
			break
		}
	}
	if idx < 0 {
		t.Fatal("fixture lacks #goirc")
	}
	b[idx] = 'x'
	if st.decode(b) {
		t.Fatal("non-channel buffer name decoded")
	}
}

func TestStateRefusesUnknownFocus(t *testing.T) {
	u := testUI()
	b := (&ircState{}).encode(u)
	// Rewrite focus "#other" -> "#nosuch" (same length).
	idx := -1
	for i := 0; i+6 <= len(b); i++ {
		if string(b[i:i+6]) == "#other" {
			idx = i
			break
		}
	}
	if idx < 0 {
		t.Fatal("fixture lacks #other")
	}
	copy(b[idx:], "#nosuc")
	st := &ircState{}
	if st.decode(b) {
		t.Fatal("a focus naming no buffer decoded")
	}
}

func TestApplyRestored(t *testing.T) {
	u := testUI()
	st := &ircState{}
	if !st.decode(st.encode(u)) {
		t.Fatal("refused")
	}
	fresh := &uiApp{
		cfg:    Config{},
		scroll: map[string]int{},
		st:     st,
	}
	fresh.applyRestored()
	if fresh.cfg.Host != "irc.example.net" || fresh.cfg.Port != 6697 || !fresh.cfg.TLS {
		t.Fatalf("cfg: %+v", fresh.cfg)
	}
	if fresh.cfg.ServerName != "leaf.example.com" {
		t.Fatalf("restored sni: %q", fresh.cfg.ServerName)
	}
	if len(fresh.cfg.Channels) != 2 || fresh.cfg.Channels[0] != "#goirc" {
		t.Fatalf("channels: %v", fresh.cfg.Channels)
	}
	if fresh.focusedBuf() != "#other" {
		t.Fatalf("focus: %v", fresh.focusedBuf())
	}
	if fresh.scroll["#other"] != 7 {
		t.Fatalf("scroll: %v", fresh.scroll)
	}
}

func TestApplyRestoredConsentSkipsAsk(t *testing.T) {
	u := testUI()
	u.cfg.TLS = false
	u.cfg.AllowPlain = true
	st := &ircState{}
	if !st.decode(st.encode(u)) {
		t.Fatal("refused")
	}
	fresh := &uiApp{cfg: Config{}, scroll: map[string]int{}, st: st}
	fresh.applyRestored()
	if !fresh.cfg.AllowPlain || fresh.needConsent() {
		t.Fatal("stored consent should satisfy the ask")
	}
}

func TestNeedConsent(t *testing.T) {
	u := &uiApp{cfg: Config{TLS: true}}
	if u.needConsent() {
		t.Fatal("TLS needs no consent")
	}
	u.cfg.TLS = false
	if !u.needConsent() {
		t.Fatal("unconsented plaintext must ask")
	}
	u.cfg.AllowPlain = true
	if u.needConsent() {
		t.Fatal("--plain is the consent bit")
	}
}

// --- mention matching -------------------------------------------------------

func TestMentionMatch(t *testing.T) {
	cases := []struct {
		text, nick string
		want       bool
	}{
		{"hey gate you there", "gate", true},
		{"ping gate, ping", "gate", true},
		{"GATE: hi", "gate", true},   // ASCII case-fold
		{"gatecrash", "gate", false}, // prefix inside a word
		{"agate", "gate", false},     // suffix inside a word
		{"hey xgate", "gate", false}, // nick-char boundary
		{"hey gate_", "gate", false}, // trailing nick char
		{"no mention", "gate", false},
		{"", "gate", false},
		{"gate", "gate", true},      // whole line
		{"hi gate1", "gate", false}, // digit is a nick byte
	}
	for _, c := range cases {
		if got := mentionMatch(c.text, c.nick); got != c.want {
			t.Errorf("mentionMatch(%q, %q) = %v, want %v", c.text, c.nick, got, c.want)
		}
	}
}

func TestMentionEventArmsPending(t *testing.T) {
	u := &uiApp{cfg: Config{Nick: "gate"}, evs: make(chan Event, 8),
		scroll: map[string]int{}, st: &ircState{}, localLog: NewBacklog(8)}
	u.cli = NewClient(Config{Nick: "gate"}, func() (WireConn, error) { return &fakeConn{}, nil }, nil)
	u.onEvent(Event{Kind: EvEntry, Entry: Entry{
		Kind: EntryMsg, Channel: "#other", From: "alice", Text: "ping gate",
	}})
	if u.pendMention != "#other" {
		t.Fatalf("pendMention = %q", u.pendMention)
	}
	// A non-mention and an own echo never arm it.
	u.pendMention = ""
	u.onEvent(Event{Kind: EvEntry, Entry: Entry{
		Kind: EntryMsg, Channel: "#other", From: "alice", Text: "hi all",
	}})
	u.onEvent(Event{Kind: EvEntry, Entry: Entry{
		Kind: EntryMsg, Channel: "#other", From: "gate", Text: "gate talking",
	}})
	if u.pendMention != "" {
		t.Fatalf("non-mention armed %q", u.pendMention)
	}
}

func TestFocusClickThrough(t *testing.T) {
	u := &uiApp{cfg: Config{Nick: "gate"}, evs: make(chan Event, 8),
		scroll: map[string]int{}, st: &ircState{}, localLog: NewBacklog(8)}
	u.cli = NewClient(Config{Nick: "gate"}, func() (WireConn, error) { return &fakeConn{}, nil }, nil)
	u.bufs = []string{"", "#goirc", "#other"}
	u.focus = 1
	u.pendMention = "#other"
	u.handleEvent(viEvent(vi.EvWinFocus))
	if u.focusedBuf() != "#other" {
		t.Fatalf("click-through focused %q, want #other", u.focusedBuf())
	}
	if u.pendMention != "" {
		t.Fatal("pending mention not consumed")
	}
	// A focus event with nothing pending changes nothing.
	u.focusName("#goirc")
	u.handleEvent(viEvent(vi.EvWinFocus))
	if u.focusedBuf() != "#goirc" {
		t.Fatalf("plain focus moved to %q", u.focusedBuf())
	}
}

// --- input verbs ------------------------------------------------------------

func lastStatus(u *uiApp) string {
	log := u.localLog
	if u.cli != nil {
		log = u.cli.Backlog("")
	}
	n := log.Len()
	if n == 0 {
		return ""
	}
	return log.At(n - 1).Text
}

func TestSubmitVerbs(t *testing.T) {
	u := &uiApp{cfg: Config{Nick: "gate"}, evs: make(chan Event, 8),
		scroll: map[string]int{}, st: &ircState{}, localLog: NewBacklog(32)}
	u.bufs = []string{""}
	fc := &fakeConn{}
	u.cli = NewClient(Config{Nick: "gate"}, func() (WireConn, error) { return fc, nil }, nil)
	// Not registered: verbs still work — Join records intent, Privmsg
	// errors honestly.
	u.submit("/join #new")
	if u.focusedBuf() != "#new" {
		t.Fatalf("/join focus: %q", u.focusedBuf())
	}
	u.submit("/part")
	u.submit("/msg alice hello there")
	u.submit("/nick gate2")
	if w := allWrites(fc); w != "" {
		t.Fatalf("offline verbs wrote to the wire: %q", w)
	}
	u.submit("/bogus")
	if s := lastStatus(u); s != "unknown command /bogus" {
		t.Fatalf("unknown verb status: %q", s)
	}
	u.submit("")
	u.focusName("")
	u.submit("hello")
	if s := lastStatus(u); s != "no channel focused — /join one first" {
		t.Fatalf("server-buffer submit status: %q", s)
	}
	u.submit("/quit")
	if !u.quit {
		t.Fatal("/quit did not set quit")
	}
}

func TestRailHit(t *testing.T) {
	u := &uiApp{bufs: []string{"", "#a", "#b"}, scroll: map[string]int{}}
	cases := []struct {
		x, y, want int
	}{
		{10, headH + 1, 0},
		{10, headH + rowH + 1, 1},
		{10, headH + 2*rowH + 1, 2},
		{10, headH + 3*rowH + 1, -1}, // past the list
		{railW + 5, headH + 1, -1},   // in the scrollback pane
		{10, 2, -1},                  // header strip
	}
	for _, c := range cases {
		if got := u.railHit(c.x, c.y); got != c.want {
			t.Errorf("railHit(%d,%d) = %d, want %d", c.x, c.y, got, c.want)
		}
	}
}

func TestScrollClamp(t *testing.T) {
	u := &uiApp{scroll: map[string]int{}, evs: make(chan Event, 8),
		st: &ircState{}, localLog: NewBacklog(8)}
	u.cli = NewClient(Config{Nick: "gate"}, func() (WireConn, error) { return &fakeConn{}, nil }, nil)
	for i := 0; i < 30; i++ {
		u.cli.Backlog("#a").Add(Entry{Kind: EntryMsg, Text: "line"})
	}
	u.bufs = []string{"", "#a"}
	u.focus = 1
	u.ta = nil
	// scrollRows needs ta — exercise the clamp bound instead: more scroll
	// than entries clamps at 0 rows visible? Without a canvas H, set ta
	// to a zero-size shell so scrollRows returns a negative→0 bound.
	u.ta = fakeTabApp(0, 0)
	u.scroll["#a"] = 999
	u.scrollClamp("#a")
	if u.scroll["#a"] != 30 {
		t.Fatalf("clamp: %d, want 30 (rows=0)", u.scroll["#a"])
	}
	u.scroll["#a"] = -5
	u.scrollBy(0)
	if u.scroll["#a"] != 0 {
		t.Fatalf("negative scroll not repaired: %d", u.scroll["#a"])
	}
}
