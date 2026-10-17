package main

// Host-side tests for the M109e agent watch: the fixture wires the real
// seat code to an in-memory AUDIT lane and a captured log, so the whole
// policy — credential gate, catch-up replay, MAC verification, milestone
// toasts, the byte-silence contract — runs off the guest.

import (
	"errors"
	"strings"
	"testing"

	"virelai/shlib"
	"virelai/theme"
	"virelai/vi"
)

// agentFixture is the in-memory AUDIT lane plus the captured marker
// lines. rcpts maps name -> file body (receipt line + MAC line); the
// fixture's MAC is computed over the same pinned key the secret seam
// serves (or not — the flags-off legs).
type agentFixture struct {
	t      *testing.T
	files  map[string][]byte
	logs   []string
	key    []byte // nil = the row is not served to the seat
	listRC int    // nonzero simulates a listing failure
	toasts []string
}

const agentTestKey = "a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5"

func newAgentFixture(t *testing.T, key string) *agentFixture {
	f := &agentFixture{t: t, files: map[string][]byte{}, key: []byte(key)}
	if key == "" {
		f.key = nil
	}

	prevSecret := agentSecretGet
	prevList := agentListFn
	prevRead := agentReadFn
	prevLog := agentLogFn
	prevToast := agentToastFn
	prevKey := agentKey
	prevSeen := agentSeen
	prevActive := agentActive
	prevCaught := agentCaughtUp
	prevDND := notifyDND
	prevQueue := notifyQueue
	prevCenter := notifyCenter
	t.Cleanup(func() {
		agentSecretGet = prevSecret
		agentListFn = prevList
		agentReadFn = prevRead
		agentLogFn = prevLog
		agentToastFn = prevToast
		agentKey = prevKey
		agentSeen = prevSeen
		agentActive = prevActive
		agentCaughtUp = prevCaught
		notifyDND = prevDND
		notifyQueue = prevQueue
		notifyCenter = prevCenter
	})

	agentSecretGet = func(name string, out []byte) int {
		if name != agentSecretName || f.key == nil {
			return -1
		}
		return copy(out, f.key)
	}
	agentListFn = func(dir string) ([]vi.DirItem, error) {
		if dir != agentAuditCanon {
			return nil, errors.New("wrong dir")
		}
		if f.listRC != 0 {
			return nil, errors.New("EIO")
		}
		items := make([]vi.DirItem, 0, len(f.files))
		for name := range f.files {
			items = append(items, vi.DirItem{Name: name})
		}
		return items, nil
	}
	agentReadFn = func(path string, max int) ([]byte, int64) {
		if !strings.HasPrefix(path, agentAuditDir) {
			return nil, -vi.ErrENOENT
		}
		b, ok := f.files[strings.TrimPrefix(path, agentAuditDir)]
		if !ok {
			return nil, -vi.ErrENOENT
		}
		if len(b) > max {
			return b[:max], int64(len(b))
		}
		return b, int64(len(b))
	}
	agentLogFn = func(s string) { f.logs = append(f.logs, s) }
	agentToastFn = func(tabID uint32, text string, ticks uint64) (string, bool, bool) {
		f.toasts = append(f.toasts, text)
		return text, true, false
	}
	agentKey, agentSeen, agentActive, agentCaughtUp = nil, nil, false, false
	return f
}

// rcpt builds one signed receipt file body (line + 64-hex MAC) exactly
// the shape the lane's own emit writes.
func (f *agentFixture) rcpt(agent, verb, args, result string) []byte {
	line := `{"seq":1,"epoch":"b0000001","agent":` + jq(agent) +
		`,"verb":` + jq(verb) + `,"args":` + args +
		`,"ts":100,"mono":200,"result":` + jq(result) + `}`
	mac := shlib.HMACSHA256(f.key, []byte(line))
	return []byte(line + "\n" + hexLower(mac[:]) + "\n")
}

// stage drops a signed receipt into the lane (agentd's publish).
func (f *agentFixture) stage(name, agent, verb, args, result string) {
	f.files[name] = f.rcpt(agent, verb, args, result)
}

// jq renders s as a JSON string with the escapes the lane writer uses.
func jq(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, c := range s {
		switch c {
		case '"', '\\':
			b.WriteByte('\\')
			b.WriteRune(c)
		default:
			b.WriteRune(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func hexLower(b []byte) string {
	const d = "0123456789abcdef"
	out := make([]byte, len(b)*2)
	for i, c := range b {
		out[2*i] = d[c>>4]
		out[2*i+1] = d[c&0xf]
	}
	return string(out)
}

func (f *agentFixture) has(sub string) bool {
	for _, l := range f.logs {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

func (f *agentFixture) count(sub string) int {
	n := 0
	for _, l := range f.logs {
		if strings.Contains(l, sub) {
			n++
		}
	}
	return n
}

// --- flags-off: the whole card's byte-silence contract --------------------

// No agent-hmac row served to the seat: nothing inits, nothing polls,
// nothing ever reaches the log — receipts may even exist; they are not
// the seat's to read.
func TestAgentWatchFlagsOffByteSilent(t *testing.T) {
	f := newAgentFixture(t, "")
	f.stage("RCPT-b0000001-00000001", "devin", "session", `{"event":"open"}`, "ok")
	agentSeatInit()
	for i := 0; i < 4; i++ {
		agentSeatTick()
	}
	if len(f.logs) != 0 {
		t.Fatalf("flags-off boot printed %d line(s): %v", len(f.logs), f.logs)
	}
	if agentKey != nil {
		t.Fatal("the watch armed itself without the row")
	}
	if _, _, ok := agentBadge(); ok {
		t.Fatal("badge on with the flag off")
	}
	if len(f.toasts) != 0 {
		t.Fatal("flags-off boot toasted")
	}
}

// --- the watch ------------------------------------------------------------

// Armed with an empty lane: the armed marker, then the catch-up summary
// on the first poll — the "the lane loop actually ran" anchor.
func TestAgentWatchArmedEmptyLane(t *testing.T) {
	f := newAgentFixture(t, agentTestKey)
	agentSeatInit()
	if !f.has("gotabwm: agent watch") {
		t.Fatalf("no armed marker: %v", f.logs)
	}
	agentSeatTick()
	if !f.has("gotabwm: agent caught n=0 bad=0") {
		t.Fatalf("no catch-up line: %v", f.logs)
	}
	if len(f.logs) != 2 {
		t.Fatalf("empty lane must print exactly watch+caught, saw %v", f.logs)
	}
	// A second poll is silent: no repeated catch-up.
	agentSeatTick()
	if len(f.logs) != 2 {
		t.Fatalf("idle lane printed again: %v", f.logs)
	}
}

// A live session open lights the badge; the close takes it back off.
func TestAgentWatchSessionIndicator(t *testing.T) {
	f := newAgentFixture(t, agentTestKey)
	agentSeatInit()
	agentSeatTick() // catch-up on an empty lane
	f.stage("RCPT-b0000001-00000001", "devin", "session", `{"event":"open"}`, "ok")
	agentSeatTick()
	if !f.has("gotabwm: agent session open agent=devin") {
		t.Fatalf("no open marker: %v", f.logs)
	}
	tag, rgb, ok := agentBadge()
	if !ok || tag != "AGENT" {
		t.Fatalf("session open but badge is %q ok=%v", tag, ok)
	}
	if rgb != themeAccentForTest() {
		t.Fatalf("badge tint %#06x, want the Accent token", rgb)
	}
	// A verb receipt on the open session names itself.
	f.stage("RCPT-b0000001-00000002", "devin", "fs.read", `{"path":"APP/main.go","size":4,"sha256_8":"deadbeef"}`, "ok")
	agentSeatTick()
	if !f.has("gotabwm: agent verb fs.read") {
		t.Fatalf("no verb marker: %v", f.logs)
	}
	f.stage("RCPT-b0000001-00000003", "devin", "session", `{"event":"close"}`, "client_close")
	agentSeatTick()
	if !f.has("gotabwm: agent session close agent=devin") {
		t.Fatalf("no close marker: %v", f.logs)
	}
	if _, _, ok := agentBadge(); ok {
		t.Fatal("badge still lit after the close")
	}
}

// The three card milestones toast only on verified ok+exit0 receipts.
func TestAgentWatchMilestones(t *testing.T) {
	f := newAgentFixture(t, agentTestKey)
	agentSeatInit()
	agentSeatTick()
	f.stage("RCPT-b0000001-00000001", "devin", "session", `{"event":"open"}`, "ok")
	f.stage("RCPT-b0000001-00000002", "devin", "gosh.run",
		`{"cmd":"FLINT.ELF commit -m \"x\"","timeout_ms":10000,"exit_status":0}`, "ok")
	f.stage("RCPT-b0000001-00000003", "devin", "gosh.run",
		`{"cmd":"FLINT.ELF push --remote=10.0.0.2:4750 --stream=main","timeout_ms":30000,"exit_status":0}`, "ok")
	f.stage("RCPT-b0000001-00000004", "devin", "gosh.run",
		`{"cmd":"STORE.ELF install main --remote=10.0.0.2:4750","timeout_ms":30000,"exit_status":0}`, "ok")
	agentSeatTick()
	for _, m := range []string{"commit", "push", "install"} {
		if !f.has("gotabwm: agent milestone " + m) {
			t.Fatalf("no %s milestone marker: %v", m, f.logs)
		}
		if !f.has("gotabwm: notify id=0 agent: " + m + " ok") {
			t.Fatalf("no %s toast queue line: %v", m, f.logs)
		}
	}
	want := []string{"agent: commit ok", "agent: push ok", "agent: install ok"}
	if len(f.toasts) != len(want) {
		t.Fatalf("toasts %v, want %v", f.toasts, want)
	}
	for i, w := range want {
		if f.toasts[i] != w {
			t.Fatalf("toast %d is %q, want %q", i, f.toasts[i], w)
		}
	}
}

// A milestone-shaped command that FAILED or never finished is not a
// milestone: nonzero exit, refused result, and the intent receipt (no
// exit_status at all) all stay off the strip.
func TestAgentWatchNoMilestoneOnFailure(t *testing.T) {
	f := newAgentFixture(t, agentTestKey)
	agentSeatInit()
	agentSeatTick()
	// The intent receipt: identical cmd, no exit_status.
	f.stage("RCPT-b0000001-00000001", "devin", "gosh.run",
		`{"cmd":"FLINT.ELF commit -m \"x\"","timeout_ms":10000}`, "ok")
	// The failed run: exit_status says the child lost.
	f.stage("RCPT-b0000001-00000002", "devin", "gosh.run",
		`{"cmd":"FLINT.ELF commit -m \"x\"","timeout_ms":10000,"exit_status":1}`, "ok")
	// A refused dispatch: no args at all.
	f.stage("RCPT-b0000001-00000003", "devin", "gosh.run", `{}`, "cap_required:term")
	agentSeatTick()
	if f.has("gotabwm: agent milestone") {
		t.Fatalf("a failure toasted as a milestone: %v", f.logs)
	}
	if len(f.toasts) != 0 {
		t.Fatalf("failure-path toasts: %v", f.toasts)
	}
	if f.count("gotabwm: agent verb gosh.run") != 3 {
		t.Fatalf("verb markers should still print per receipt: %v", f.logs)
	}
}

// The catch-up: a lane that already holds receipts replays them for
// state — an open still standing lights the badge — but never toasts,
// and the summary names the verified/bad split.
func TestAgentWatchCatchUpNoToasts(t *testing.T) {
	f := newAgentFixture(t, agentTestKey)
	f.stage("RCPT-b0000001-00000001", "devin", "session", `{"event":"open"}`, "ok")
	f.stage("RCPT-b0000001-00000002", "devin", "gosh.run",
		`{"cmd":"FLINT.ELF commit -m \"x\"","timeout_ms":10000,"exit_status":0}`, "ok")
	// A forged file beside the real ones.
	f.files["RCPT-b0000001-00000003"] = []byte(`{"seq":1,"verb":"session"}` + "\n" + strings.Repeat("0", 64) + "\n")
	agentSeatInit()
	agentSeatTick()
	if !f.has("gotabwm: agent session open agent=devin") {
		t.Fatalf("the backlog open never marked: %v", f.logs)
	}
	if !f.has("gotabwm: agent milestone commit") {
		t.Fatalf("the backlog milestone never marked: %v", f.logs)
	}
	if !f.has("gotabwm: agent caught n=2 bad=1") {
		t.Fatalf("wrong catch-up summary: %v", f.logs)
	}
	if _, _, ok := agentBadge(); !ok {
		t.Fatal("badge off after a backlog open")
	}
	if len(f.toasts) != 0 {
		t.Fatalf("a stale receipt toasted: %v", f.toasts)
	}
	if f.has("gotabwm: agent rcpt bad") {
		t.Fatalf("catch-up names bads in the summary, not per-file: %v", f.logs)
	}
	// A file arriving now is live.
	f.stage("RCPT-b0000001-00000004", "devin", "session", `{"event":"close"}`, "client_close")
	agentSeatTick()
	if !f.has("gotabwm: agent session close agent=devin") {
		t.Fatalf("live close never marked: %v", f.logs)
	}
	if _, _, ok := agentBadge(); ok {
		t.Fatal("badge lit after the close")
	}
}

// A forged live receipt is named once and moves nothing — the MAC is
// the gate, so a planted "session close" cannot hide a live session.
func TestAgentWatchForgedReceiptRefused(t *testing.T) {
	f := newAgentFixture(t, agentTestKey)
	agentSeatInit()
	agentSeatTick()
	f.stage("RCPT-b0000001-00000001", "devin", "session", `{"event":"open"}`, "ok")
	agentSeatTick()
	// A forged close: real shape, wrong MAC.
	forged := f.rcpt("devin", "session", `{"event":"close"}`, "client_close")
	f.files["RCPT-b0000001-00000002"] = append([]byte(nil), forged...)
	f.files["RCPT-b0000001-00000002"][0] = 'X'
	agentSeatTick()
	if !f.has("gotabwm: agent rcpt bad RCPT-b0000001-00000002") {
		t.Fatalf("forged receipt not named: %v", f.logs)
	}
	if _, _, ok := agentBadge(); !ok {
		t.Fatal("a forged close took the indicator down")
	}
	if f.has("gotabwm: agent session close") {
		t.Fatalf("a forged close printed the close marker: %v", f.logs)
	}
	// Once named, it is named once — no per-tick repeat.
	agentSeatTick()
	if f.count("gotabwm: agent rcpt bad") != 1 {
		t.Fatalf("the forged file re-logged: %v", f.logs)
	}
}

// A transient listing error keeps the catch-up open and stays silent —
// the lane announces itself once it actually lists.
func TestAgentWatchListErrorSilent(t *testing.T) {
	f := newAgentFixture(t, agentTestKey)
	f.listRC = -1
	agentSeatInit()
	agentSeatTick()
	if f.has("gotabwm: agent caught") {
		t.Fatalf("caught printed on a failed listing: %v", f.logs)
	}
	f.listRC = 0
	agentSeatTick()
	if !f.has("gotabwm: agent caught n=0 bad=0") {
		t.Fatalf("no catch-up once the lane answers: %v", f.logs)
	}
}

// --- the small units --------------------------------------------------------

func TestAgentRcptName(t *testing.T) {
	good := "RCPT-b0000001-00000002"
	if !agentRcptName(good) {
		t.Fatalf("%q refused", good)
	}
	for _, bad := range []string{
		"RCPT-b0000001-0000000",   // short
		"RCPT-b0000001-000000023", // long
		"RCPT-b0000001-00000002~", // publish temp
		"RCPT-b0000001-0000000g",  // non-hex
		"RCPT-b0000001_00000002",  // wrong separator
		"SOURCE.TXT",
		"",
	} {
		if agentRcptName(bad) {
			t.Fatalf("%q accepted", bad)
		}
	}
}

func TestAgentMilestoneVocabulary(t *testing.T) {
	args := func(cmd string, st int) string {
		s := `{"cmd":` + jq(cmd) + `,"timeout_ms":10000`
		if st >= 0 {
			s += `,"exit_status":` + vi.Itoa64(int64(st))
		}
		return s + `}`
	}
	cases := []struct {
		verb, args, result, want string
	}{
		{"gosh.run", args("FLINT.ELF commit -m \"x\"", 0), "ok", "commit"},
		{"gosh.run", args("FLINT.ELF push --remote=r --stream=main", 0), "ok", "push"},
		{"gosh.run", args("STORE.ELF install main --remote=r", 0), "ok", "install"},
		// Boundary matches: a pipe stage still names the milestone.
		{"gosh.run", args("wc -l /host/X | FLINT.ELF push --remote=r", 0), "ok", "push"},
		// A suffix is not the command head.
		{"gosh.run", args("echo FLINT.ELF commit", 0), "ok", ""},
		{"gosh.run", args("FLINT.ELF committee", 0), "ok", ""},
		{"gosh.run", args("FLINT.ELF commit -m \"x\"", 1), "ok", ""},
		{"gosh.run", args("FLINT.ELF commit -m \"x\"", -1), "ok", ""},
		{"gosh.run", args("FLINT.ELF commit -m \"x\"", 0), "timed_out", ""},
		{"fs.write", args("FLINT.ELF commit -m \"x\"", 0), "ok", ""},
	}
	for _, c := range cases {
		got := agentMilestone(c.verb, []byte(c.args), c.result)
		if got != c.want {
			t.Fatalf("agentMilestone(%q, %s, %q) = %q, want %q",
				c.verb, c.args, c.result, got, c.want)
		}
	}
}

func TestAgentValueScanner(t *testing.T) {
	line := []byte(`{"seq":1,"epoch":"b0000001","agent":"devin","verb":"gosh.run","args":{"cmd":"FLINT.ELF commit -m \"x\"","exit_status":0},"ts":1,"mono":2,"result":"ok"}`)
	if v, ok := agentField(line, "verb"); !ok || v != "gosh.run" {
		t.Fatalf("verb = %q ok=%v", v, ok)
	}
	if v, ok := agentField(line, "agent"); !ok || v != "devin" {
		t.Fatalf("agent = %q ok=%v", v, ok)
	}
	args, ok := agentObject(line, "args")
	if !ok {
		t.Fatal("no args object")
	}
	if v, ok := agentField([]byte(args), "cmd"); !ok || v != `FLINT.ELF commit -m "x"` {
		t.Fatalf("cmd unescape = %q ok=%v", v, ok)
	}
	if v, ok := agentNumber([]byte(args), "exit_status"); !ok || v != 0 {
		t.Fatalf("exit_status = %d ok=%v", v, ok)
	}
	if v, ok := agentField(line, "result"); !ok || v != "ok" {
		t.Fatalf("result = %q ok=%v", v, ok)
	}
	// A nested key never answers a top-level lookup.
	if _, ok := agentField(line, "cmd"); ok {
		t.Fatal("nested cmd answered the top-level scan")
	}
	// Malformed input refuses rather than half-reading.
	for _, bad := range []string{"", "{}", `{"verb":`, `{"verb":x`, `nope`, `[]`} {
		if _, ok := agentField([]byte(bad), "verb"); ok {
			t.Fatalf("agentValue accepted %q", bad)
		}
	}
}

// themeAccentForTest keeps the test out of theme internals; the badge's
// contract is "the Accent token", whatever it resolves to this build.
func themeAccentForTest() uint32 {
	return theme.Current.Accent
}
