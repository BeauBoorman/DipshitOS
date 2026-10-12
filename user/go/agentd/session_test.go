package main

// ADR 0044 D2 / AC2: the pinned HMAC vector, the handshake's accept and
// three refusal shapes, the startup posture order, and the never-logged
// contract on the auth path.

import (
	"errors"
	"strings"
	"testing"

	"virelai/vi"
)

// pinnedKey is the ADR's class-A vector key: ASCII "a5" x 32 (64 bytes).
func pinnedKey() []byte {
	k := make([]byte, 0, 64)
	for i := 0; i < 32; i++ {
		k = append(k, 'a', '5')
	}
	return k
}

// pinnedChallenge is the ADR's vector challenge: bytes 00..1f.
func pinnedChallenge() [32]byte {
	var c [32]byte
	for i := 0; i < 32; i++ {
		c[i] = byte(i)
	}
	return c
}

const pinnedMAC = "e907b2015a16de6504cc2bc61da0d60156c3abe2b035601372840acb58feff04"

func TestAgentMACPinnedVector(t *testing.T) {
	c := pinnedChallenge()
	mac := agentMAC(pinnedKey(), &c)
	if got := hexString(mac[:]); got != pinnedMAC {
		t.Fatalf("agentMAC = %q want %q", got, pinnedMAC)
	}
}

// stubSeam restores the seams a session test swaps.
func sessionSeams(t *testing.T, key []byte) *[]string {
	t.Helper()
	logs := &[]string{}
	prevConsole, prevSecret, prevRandom := consoleFn, secretGetFn, randomFn
	consoleFn = func(s string) { *logs = append(*logs, s) }
	secretGetFn = func(name string, out []byte) int {
		if name != secretName || key == nil {
			return -1
		}
		return copy(out, key)
	}
	randomFn = func(p []byte) (int, error) {
		c := pinnedChallenge()
		copy(p, c[:])
		return len(p), nil
	}
	t.Cleanup(func() {
		consoleFn, secretGetFn, randomFn = prevConsole, prevSecret, prevRandom
	})
	return logs
}

// sessionScript runs session() against a scripted conn and returns the
// response lines, the marker log, and the auth-failed verdict.
func sessionScript(t *testing.T, c *fakeConn, allowExec bool) ([]string, []string, bool) {
	t.Helper()
	logs := sessionSeams(t, pinnedKey())
	failed := session(c, allowExec)
	return c.sentLines(), *logs, failed
}

func greetingChallenge(t *testing.T, lines []string) string {
	t.Helper()
	if len(lines) == 0 {
		t.Fatal("no greeting")
	}
	v, code := parseLine([]byte(lines[0]))
	if code != "" {
		t.Fatalf("greeting parse = %q", code)
	}
	for _, m := range v.membs {
		if m.key == "challenge" && m.val.kind == jStr {
			return m.val.str
		}
	}
	t.Fatalf("greeting had no challenge: %q", lines[0])
	return ""
}

func TestSessionGreetingShape(t *testing.T) {
	c := &fakeConn{recvErr: errPeerGoneTest}
	lines, _, _ := sessionScript(t, c, true)
	ch := pinnedChallenge()
	want := `{"proto":"virelai-agent/1","auth":"hmac-sha256","challenge":"` +
		hexString(ch[:]) + `"}`
	if lines[0] != want {
		t.Fatalf("greeting = %q want %q", lines[0], want)
	}
}

// The happy path: MAC in, ready out, one proc.list answered, peer close ends it.
func TestSessionHappyPath(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{procs: []vi.ProcRow{proc(9, vi.ProcRunning, 0, "AGENTD.ELF")}}
	k.install()
	auth := `{"auth":"` + pinnedMAC + `"}`
	c := &fakeConn{chunks: [][]byte{
		[]byte(auth + "\n"),
		[]byte(`{"id":1,"verb":"proc.list"}` + "\n"),
	}, recvErr: errPeerGoneTest}
	lines, logs, failed := sessionScript(t, c, true)
	if failed {
		t.Fatal("good auth reported authFailed")
	}
	if len(lines) != 3 {
		t.Fatalf("lines = %v", lines)
	}
	if !strings.HasPrefix(lines[1], `{"ok":true,"session":"ready","verbs":[`) ||
		!strings.Contains(lines[1], `"gosh.run"`) {
		t.Fatalf("ready = %q", lines[1])
	}
	if !strings.Contains(lines[2], `"ok":true`) || !strings.Contains(lines[2], `"AGENTD.ELF"`) {
		t.Fatalf("response = %q", lines[2])
	}
	if !hasLine(logs, "agentd: auth ok") || !hasLine(logs, "agentd: req id=1 verb=proc.list ok") ||
		!hasLine(logs, "agentd: session end reason=client_close") {
		t.Fatalf("markers = %v", logs)
	}
	// The ready line omits gosh.run without --allow-exec.
	c = &fakeConn{chunks: [][]byte{[]byte(auth + "\n")}, recvErr: errPeerGoneTest}
	lines, _, _ = sessionScript(t, c, false)
	if strings.Contains(lines[1], `"gosh.run"`) {
		t.Fatalf("noexec ready advertised gosh.run: %q", lines[1])
	}
}

// badmac: one auth_failed line, auth fail reason=mac, damping verdict true.
func TestSessionBadMAC(t *testing.T) {
	bad := strings.Repeat("0", 64)
	c := &fakeConn{chunks: [][]byte{[]byte(`{"auth":"` + bad + `"}` + "\n")}}
	lines, logs, failed := sessionScript(t, c, true)
	if !failed {
		t.Fatal("bad MAC not reported as auth failure")
	}
	if len(lines) != 2 || !strings.Contains(lines[1], `"auth_failed"`) {
		t.Fatalf("lines = %v", lines)
	}
	if !hasLine(logs, "agentd: auth fail reason=mac") {
		t.Fatalf("markers = %v", logs)
	}
	if hasLine(logs, "agentd: auth ok") || hasLine(logs, "agentd: req") {
		t.Fatalf("bad MAC ran a verb: %v", logs)
	}
}

// preauth: a verb-bearing first line is auth_required, reason=preauth.
func TestSessionPreauth(t *testing.T) {
	c := &fakeConn{chunks: [][]byte{
		[]byte(`{"id":1,"verb":"proc.list"}` + "\n"),
	}}
	lines, logs, failed := sessionScript(t, c, true)
	if !failed {
		t.Fatal("preauth not reported as auth failure")
	}
	if len(lines) != 2 || !strings.Contains(lines[1], `"auth_required"`) {
		t.Fatalf("lines = %v", lines)
	}
	if !hasLine(logs, "agentd: auth fail reason=preauth") {
		t.Fatalf("markers = %v", logs)
	}
}

// A first line that is not exactly {"auth":"..."} is auth_failed,
// reason=malformed — including a second key beside auth.
func TestSessionMalformedAuth(t *testing.T) {
	for _, first := range []string{
		`{"auth":"` + pinnedMAC + `","x":1}`,
		`{"auth":42}`,
		`{"auth":"` + pinnedMAC + `","auth":"` + pinnedMAC + `"}`,
		`garbage`,
		`{"x":1}`,
	} {
		c := &fakeConn{chunks: [][]byte{[]byte(first + "\n")}}
		lines, logs, failed := sessionScript(t, c, true)
		if !failed {
			t.Fatalf("%q not reported as auth failure", first)
		}
		if !strings.Contains(lines[len(lines)-1], `"auth_failed"`) {
			t.Fatalf("%q: lines = %v", first, lines)
		}
		if !hasLine(logs, "agentd: auth fail reason=malformed") {
			t.Fatalf("%q: markers = %v", first, logs)
		}
	}
}

// mute: no complete line inside the budget is auth_timeout, reason=timeout.
func TestSessionAuthTimeout(t *testing.T) {
	c := &fakeConn{recvErr: errors.New("ETIMEDOUT")}
	lines, logs, failed := sessionScript(t, c, true)
	if !failed {
		t.Fatal("mute not reported as auth failure")
	}
	if len(lines) != 2 || !strings.Contains(lines[1], `"auth_timeout"`) {
		t.Fatalf("lines = %v", lines)
	}
	if !hasLine(logs, "agentd: auth fail reason=timeout") {
		t.Fatalf("markers = %v", logs)
	}
}

// The pre-auth line over 256 bytes is line_too_long — fatal.
func TestSessionPreauthTooLong(t *testing.T) {
	c := &fakeConn{chunks: [][]byte{[]byte(strings.Repeat("x", 300) + "\n")}}
	lines, _, _ := sessionScript(t, c, true)
	if len(lines) != 2 || !strings.Contains(lines[1], `"line_too_long"`) {
		t.Fatalf("lines = %v", lines)
	}
}

// Post-auth, an over-limit line sends line_too_long and ends the session.
func TestSessionLineTooLong(t *testing.T) {
	auth := `{"auth":"` + pinnedMAC + `"}`
	c := &fakeConn{chunks: [][]byte{
		[]byte(auth + "\n" + strings.Repeat("x", 8193) + "\n"),
	}}
	lines, logs, _ := sessionScript(t, c, true)
	if !strings.Contains(lines[len(lines)-1], `"line_too_long"`) {
		t.Fatalf("lines = %v", lines)
	}
	if !hasLine(logs, "agentd: session end reason=line_too_long") {
		t.Fatalf("markers = %v", logs)
	}
}

// A bad request mid-session refuses non-fatally and the session goes on.
func TestSessionRefusalKeepsSession(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{procs: []vi.ProcRow{proc(9, vi.ProcRunning, 0, "AGENTD.ELF")}}
	k.install()
	auth := `{"auth":"` + pinnedMAC + `"}`
	c := &fakeConn{chunks: [][]byte{
		[]byte(auth + "\n" +
			`{"id":1,"verb":"nope"}` + "\n" +
			`{"id":2,"verb":"proc.list","x":1}` + "\n" +
			`{"id":3,"verb":"proc.list"}` + "\n"),
	}, recvErr: errPeerGoneTest}
	lines, logs, _ := sessionScript(t, c, true)
	if len(lines) != 5 {
		t.Fatalf("lines = %v", lines)
	}
	if !strings.Contains(lines[2], `"unknown_verb"`) {
		t.Fatalf("resp 1 = %q", lines[2])
	}
	if !strings.Contains(lines[3], `"bad_request"`) || !strings.Contains(lines[3], `"id":2`) {
		t.Fatalf("resp 2 = %q", lines[3])
	}
	if !strings.Contains(lines[4], `"ok":true`) {
		t.Fatalf("resp 3 = %q", lines[4])
	}
	if !hasLine(logs, "agentd: refuse id=1 verb=nope code=unknown_verb") {
		t.Fatalf("markers = %v", logs)
	}
}

// The never-logged contract on the auth path: the challenge, the MAC, and
// the key text never reach a serial line.
func TestSessionNeverLogsSecrets(t *testing.T) {
	auth := `{"auth":"` + pinnedMAC + `"}`
	c := &fakeConn{chunks: [][]byte{[]byte(auth + "\n")}, recvErr: errPeerGoneTest}
	_, logs, _ := sessionScript(t, c, true)
	blob := strings.Join(logs, "\n")
	ch := pinnedChallenge()
	for _, secret := range []string{
		pinnedMAC,
		hexString(ch[:]),
		string(pinnedKey()[:16]),
	} {
		if strings.Contains(blob, secret) {
			t.Fatalf("serial leaked %q in %v", secret[:16], logs)
		}
	}
}

// --- startup posture -------------------------------------------------------------

// exitPanic is the test stand-in for vi.Exit: it records the status and
// unwinds main() the way a real exit does.
type exitPanic struct{ status int }

func posture(t *testing.T, args []string, uid, caps uint32, principalOK, cred, root bool) (logs []string, status int) {
	t.Helper()
	l := &[]string{}
	oldConsole, oldArgs, oldPrincipal, oldSecret, oldDir, oldListen, oldExit :=
		consoleFn, argsFn, principalFn, secretGetFn, dirListFn, listenFn, exitFn
	t.Cleanup(func() {
		consoleFn, argsFn, principalFn, secretGetFn, dirListFn, listenFn, exitFn =
			oldConsole, oldArgs, oldPrincipal, oldSecret, oldDir, oldListen, oldExit
	})
	consoleFn = func(s string) { *l = append(*l, s) }
	argsFn = func() []string { return args }
	principalFn = func() (uint32, uint32, bool) { return uid, caps, principalOK }
	secretGetFn = func(name string, out []byte) int {
		if !cred {
			return -1
		}
		return copy(out, "k")
	}
	dirListFn = func(path string, buf []vi.DirEntry) (int, int64) {
		if !root {
			return 0, -vi.ErrENOENT
		}
		return 0, 0
	}
	listenFn = func(port uint16) (*vi.Conn, error) {
		return nil, errors.New("test: listen must not be reached")
	}
	exitFn = func(s int) { status = s; panic(exitPanic{s}) }
	defer func() {
		logs = *l
		if r := recover(); r != nil {
			if e, ok := r.(exitPanic); ok {
				status = e.status
			} else {
				panic(r)
			}
		}
	}()
	main()
	return *l, status
}

// The posture checks run in D2 order and each refusal is one marker plus
// exit 1 before any listen.
func TestPostureOrder(t *testing.T) {
	// argv is checked before any posture probe.
	logs, status := posture(t, []string{"--bogus"}, 1000, 0, true, true, true)
	if status != 1 || len(logs) != 1 || logs[0] != "agentd: refuse argv" {
		t.Fatalf("argv refusal = %v status %d", logs, status)
	}
	logs, status = posture(t, nil, 0, 0, true, true, true)
	if status != 1 || len(logs) != 1 || logs[0] != "agentd: refuse privileged" {
		t.Fatalf("uid 0 = %v status %d", logs, status)
	}
	logs, status = posture(t, nil, 1000, 1, true, true, true)
	if status != 1 || logs[0] != "agentd: refuse privileged" {
		t.Fatalf("caps = %v status %d", logs, status)
	}
	logs, status = posture(t, nil, 1000, 0, false, true, true)
	if status != 1 || logs[0] != "agentd: refuse privileged" {
		t.Fatalf("no principal = %v status %d", logs, status)
	}
	logs, status = posture(t, nil, 1000, 0, true, false, true)
	if status != 1 || len(logs) != 1 || logs[0] != "agentd: refuse no-credential" {
		t.Fatalf("no cred = %v status %d", logs, status)
	}
	logs, status = posture(t, nil, 1000, 0, true, true, false)
	if status != 1 || len(logs) != 1 || logs[0] != "agentd: refuse no-root" {
		t.Fatalf("no root = %v status %d", logs, status)
	}
	// A good posture prints the start marker and reaches listen — the
	// fake refuses it, and the daemon reports the errno and exits.
	logs, status = posture(t, []string{"--allow-exec"}, 1000, 0, true, true, true)
	if status != 1 || len(logs) != 2 ||
		logs[0] != "agentd: start exec=on" ||
		!strings.HasPrefix(logs[1], "agentd: refuse listen errno=") {
		t.Fatalf("good posture = %v status %d", logs, status)
	}
}
