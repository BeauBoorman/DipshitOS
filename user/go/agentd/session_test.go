package main

// ADR 0052 D2 / AC2: the Ed25519 handshake's accept and refusal shapes
// (bad signature, unknown id, revoked key, pre-auth verb, mute), the
// startup posture order, and the never-logged contract on the auth path.

import (
	"errors"
	"strings"
	"testing"

	"virelai/ed25519"
	"virelai/vi"
)

// pinnedSeed/pinnedPub are RFC 8032 §7.1 TEST 1 — the fixture identity for
// agent "devin" in the staged keyring.
const (
	pinnedSeedHex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
	pinnedPubHex  = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
	pinnedAgent   = "devin"
)

// pinnedSeed is the private half — host-side only by the model; the test
// plays the client.
func pinnedSeed() [32]byte {
	b, ok := hexDecode(pinnedSeedHex)
	if !ok || len(b) != 32 {
		panic("bad fixture seed")
	}
	var out [32]byte
	copy(out[:], b)
	return out
}

// pinnedChallenge is the fixture challenge: bytes 00..1f.
func pinnedChallenge() [challengeBytes]byte {
	var c [challengeBytes]byte
	for i := 0; i < challengeBytes; i++ {
		c[i] = byte(i)
	}
	return c
}

// keyringBody is the staged AGENTS.TXT: devin with the full cap set.
func keyringBody() string {
	return "#v1\n" +
		"agent=" + pinnedAgent + " key=" + pinnedPubHex + " caps=file,process,window,term\n"
}

// signAuth is the client half of D2: Ed25519 over the domain message.
func signAuth(t *testing.T, agentID string) string {
	t.Helper()
	ch := pinnedChallenge()
	sig := ed25519.EdSign(agentSignMsg(&ch, agentID), pinnedSeed())
	return hexString(sig[:])
}

// authLine renders the client reply for agentID signed by pinnedSeed.
func authLine(t *testing.T, agentID string) string {
	t.Helper()
	return `{"agent":"` + agentID + `","auth":"` + signAuth(t, agentID) + `"}`
}

// sessionSeams installs the seams a session test needs: the marker log,
// the agent-hmac probe, the fixed challenge, a readFileFn that serves
// only the keyring (body parameterizable), and the M109c audit fakes —
// receipts publish into sessShare under a pinned key/epoch so a test can
// read them back and verify their MACs.
func sessionSeams(t *testing.T, keyring string) *[]string {
	t.Helper()
	logs := &[]string{}
	prevConsole, prevSecret, prevRandom, prevRead :=
		consoleFn, secretGetFn, randomFn, readFileFn
	prevWrite, prevDel, prevAList, prevTime, prevLane :=
		writeFileFn, deleteFileFn, auditListFn, timeFn, lane
	consoleFn = func(s string) { *logs = append(*logs, s) }
	secretGetFn = func(name string, out []byte) int {
		if name != secretName {
			return -1
		}
		return copy(out, "k")
	}
	randomFn = func(p []byte) (int, error) {
		c := pinnedChallenge()
		copy(p, c[:])
		return len(p), nil
	}
	readFileFn = func(path string, max int) ([]byte, int64) {
		if path == keyringPath {
			if keyring != "" {
				return []byte(keyring), int64(len(keyring))
			}
			return nil, -vi.ErrENOENT
		}
		return prevRead(path, max)
	}
	writeFileFn = func(path string, b []byte) int64 {
		sessShare[path] = append([]byte(nil), b...)
		return 0
	}
	deleteFileFn = func(path string) int64 {
		delete(sessShare, path)
		return 0
	}
	auditListFn = func() []string { return shareReceiptNames(sessShare) }
	timeFn = func() int64 { return 1761234567 }
	lane = auditLane{key: []byte("receipt-key"), epoch: 0x01020304}
	t.Cleanup(func() {
		consoleFn, secretGetFn, randomFn, readFileFn =
			prevConsole, prevSecret, prevRandom, prevRead
		writeFileFn, deleteFileFn, auditListFn, timeFn, lane =
			prevWrite, prevDel, prevAList, prevTime, prevLane
	})
	return logs
}

// sessionScript runs session() against a scripted conn and returns the
// response lines, the marker log, and the auth-failed verdict.
func sessionScript(t *testing.T, c *fakeConn, allowExec bool) ([]string, []string, bool) {
	t.Helper()
	logs := sessionSeams(t, keyringBody())
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
	want := `{"proto":"virelai-agent/2","auth":"ed25519","challenge":"` +
		hexString(ch[:]) + `"}`
	if lines[0] != want {
		t.Fatalf("greeting = %q want %q", lines[0], want)
	}
}

// The happy path: a valid signature in, a ready line naming the agent and
// its resolved caps/verbs out, one proc.list answered, peer close ends it.
func TestSessionHappyPath(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{procs: []vi.ProcRow{proc(9, vi.ProcRunning, 0, "AGENTD.ELF")}}
	k.install()
	auth := authLine(t, pinnedAgent)
	c := &fakeConn{chunks: [][]byte{
		[]byte(auth + "\n"),
		[]byte(`{"id":1,"verb":"proc.list"}` + "\n"),
	}, recvErr: errPeerGoneTest}
	logs := sessionSeams(t, keyringBody())
	failed := session(c, true)
	lines := c.sentLines()
	if failed {
		t.Fatal("good auth reported authFailed")
	}
	if len(lines) != 3 {
		t.Fatalf("lines = %v", lines)
	}
	for _, want := range []string{
		`{"ok":true,"session":"ready","agent":"devin"`,
		`"caps":["file","process","window","term"]`,
		`"gosh.run"`, `"ui.screenshot"`,
	} {
		if !strings.Contains(lines[1], want) {
			t.Fatalf("ready missing %s: %q", want, lines[1])
		}
	}
	if !strings.Contains(lines[2], `"ok":true`) || !strings.Contains(lines[2], `"AGENTD.ELF"`) {
		t.Fatalf("response = %q", lines[2])
	}
	if !hasLine(*logs, "agentd: auth ok agent=devin") || !hasLine(*logs, "agentd: req id=1 verb=proc.list ok") ||
		!hasLine(*logs, "agentd: session end reason=client_close") {
		t.Fatalf("markers = %v", *logs)
	}
	// Without --allow-exec the ready line omits gosh.run even though the
	// agent holds term — the flag is the operator's kill switch (D3).
	c = &fakeConn{chunks: [][]byte{[]byte(authLine(t, pinnedAgent) + "\n")}, recvErr: errPeerGoneTest}
	session(c, false)
	if strings.Contains(c.sentLines()[1], `"gosh.run"`) {
		t.Fatalf("noexec ready advertised gosh.run: %q", c.sentLines()[1])
	}
}

// badsig: a well-formed reply whose signature does not verify —
// auth_failed, reason=sig, damping verdict true.
func TestSessionBadSig(t *testing.T) {
	bad := strings.Repeat("0", 128)
	c := &fakeConn{chunks: [][]byte{
		[]byte(`{"agent":"` + pinnedAgent + `","auth":"` + bad + `"}` + "\n")}}
	lines, logs, failed := sessionScript(t, c, true)
	if !failed {
		t.Fatal("bad signature not reported as auth failure")
	}
	if len(lines) != 2 || !strings.Contains(lines[1], `"auth_failed"`) {
		t.Fatalf("lines = %v", lines)
	}
	if !hasLine(logs, "agentd: auth fail reason=sig") {
		t.Fatalf("markers = %v", logs)
	}
	if hasLine(logs, "agentd: auth ok") || hasLine(logs, "agentd: req") {
		t.Fatalf("bad sig ran a verb: %v", logs)
	}
}

// unknown: a valid signature under a key no row lists is agent_unknown —
// the id is refused by name (D2).
func TestSessionAgentUnknown(t *testing.T) {
	c := &fakeConn{chunks: [][]byte{
		[]byte(authLine(t, "mallory") + "\n")}}
	lines, logs, failed := sessionScript(t, c, true)
	if !failed {
		t.Fatal("unknown agent not reported as auth failure")
	}
	if len(lines) != 2 || !strings.Contains(lines[1], `"agent_unknown"`) {
		t.Fatalf("lines = %v", lines)
	}
	if !hasLine(logs, "agentd: auth fail reason=agent_unknown") ||
		!hasLine(logs, "agentd: session end reason=agent_unknown") {
		t.Fatalf("markers = %v", logs)
	}
}

// revoked: the row is listed and the signature is good, but a revoked=
// row names the key — refused agent_revoked before the verify path.
func TestSessionAgentRevoked(t *testing.T) {
	kr := "#v1\n" +
		"agent=" + pinnedAgent + " key=" + pinnedPubHex + " caps=file\n" +
		"revoked=" + pinnedPubHex + "\n"
	c := &fakeConn{chunks: [][]byte{
		[]byte(authLine(t, pinnedAgent) + "\n")}}
	logs := sessionSeams(t, kr)
	failed := session(c, true)
	lines := c.sentLines()
	if !failed {
		t.Fatal("revoked credential not reported as auth failure")
	}
	if len(lines) != 2 || !strings.Contains(lines[1], `"agent_revoked"`) {
		t.Fatalf("lines = %v", lines)
	}
	if !hasLine(*logs, "agentd: auth fail reason=agent_revoked") {
		t.Fatalf("markers = %v", *logs)
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

// A first line that is not exactly {"agent":..,"auth":..} is auth_failed,
// reason=malformed — including extra keys, mistyped values and duplicates.
func TestSessionMalformedAuth(t *testing.T) {
	for _, first := range []string{
		`{"agent":"` + pinnedAgent + `","auth":"00","x":"1"}`,
		`{"auth":42,"agent":"` + pinnedAgent + `"}`,
		`{"agent":"` + pinnedAgent + `","auth":"00","auth":"00"}`,
		`{"agent":"` + pinnedAgent + `"}`,
		`{"auth":"00"}`,
		`garbage`,
		`{"x":"1"}`,
		`{"agent":"` + pinnedAgent + `","verb":"proc.list","auth":"00"}`,
	} {
		c := &fakeConn{chunks: [][]byte{[]byte(first + "\n")}}
		lines, logs, failed := sessionScript(t, c, true)
		if !failed {
			t.Fatalf("%q not reported as auth failure", first)
		}
		wantCode := "auth_failed"
		wantReason := "malformed"
		if strings.Contains(first, `"verb"`) {
			wantCode = "auth_required"
			wantReason = "preauth"
		}
		if !strings.Contains(lines[len(lines)-1], `"`+wantCode+`"`) {
			t.Fatalf("%q: lines = %v", first, lines)
		}
		if !hasLine(logs, "agentd: auth fail reason="+wantReason) {
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
	c := &fakeConn{chunks: [][]byte{
		[]byte(authLine(t, pinnedAgent) + "\n" + strings.Repeat("x", 8193) + "\n"),
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
	logs := sessionSeams(t, keyringBody())
	c := &fakeConn{chunks: [][]byte{
		[]byte(authLine(t, pinnedAgent) + "\n" +
			`{"id":1,"verb":"nope"}` + "\n" +
			`{"id":2,"verb":"proc.list","x":1}` + "\n" +
			`{"id":3,"verb":"proc.list"}` + "\n"),
	}, recvErr: errPeerGoneTest}
	session(c, true)
	lines := c.sentLines()
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
	if !hasLine(*logs, "agentd: refuse id=1 verb=nope code=unknown_verb") {
		t.Fatalf("markers = %v", *logs)
	}
}

// The never-logged contract on the auth path: the challenge, the
// signature, and the seed never reach a serial line.
func TestSessionNeverLogsSecrets(t *testing.T) {
	c := &fakeConn{chunks: [][]byte{[]byte(authLine(t, pinnedAgent) + "\n")}, recvErr: errPeerGoneTest}
	logs := sessionSeams(t, keyringBody())
	session(c, true)
	blob := strings.Join(*logs, "\n")
	ch := pinnedChallenge()
	for _, secret := range []string{
		signAuth(t, pinnedAgent),
		pinnedSeedHex,
		hexString(ch[:]),
	} {
		if strings.Contains(blob, secret) {
			t.Fatalf("serial leaked %q in %v", secret[:16], *logs)
		}
	}
}

// --- startup posture -------------------------------------------------------------

// exitPanic is the test stand-in for vi.Exit: it records the status and
// unwinds main() the way a real exit does.
type exitPanic struct{ status int }

// postureState carries one posture scenario: whether the credential row
// probes, the keyring's state ("" missing, "ok", anything else is the
// malformed body), and whether the sandbox root and audit dir list.
type postureState struct {
	cred    bool
	keyring string // "" = absent, "ok" = the fixture body, else body
	root    bool
	audit   bool
}

func posture(t *testing.T, args []string, uid, caps uint32, principalOK bool, st postureState) (logs []string, status int) {
	t.Helper()
	l := &[]string{}
	oldConsole, oldArgs, oldPrincipal, oldSecret, oldDir, oldRead, oldListen, oldExit :=
		consoleFn, argsFn, principalFn, secretGetFn, dirListFn, readFileFn, listenFn, exitFn
	oldRandom, oldAList, oldTime, prevLane := randomFn, auditListFn, timeFn, lane
	t.Cleanup(func() {
		consoleFn, argsFn, principalFn, secretGetFn, dirListFn, readFileFn, listenFn, exitFn =
			oldConsole, oldArgs, oldPrincipal, oldSecret, oldDir, oldRead, oldListen, oldExit
		randomFn, auditListFn, timeFn, lane = oldRandom, oldAList, oldTime, prevLane
	})
	consoleFn = func(s string) { *l = append(*l, s) }
	argsFn = func() []string { return args }
	principalFn = func() (uint32, uint32, bool) { return uid, caps, principalOK }
	secretGetFn = func(name string, out []byte) int {
		if !st.cred {
			return -1
		}
		return copy(out, "k")
	}
	readFileFn = func(path string, max int) ([]byte, int64) {
		if path != keyringPath || st.keyring == "" {
			return nil, -vi.ErrENOENT
		}
		body := st.keyring
		if body == "ok" {
			body = keyringBody()
		}
		return []byte(body), int64(len(body))
	}
	dirListFn = func(path string, buf []vi.DirEntry) (int, int64) {
		switch path {
		case sandboxDir:
			if !st.root {
				return 0, -vi.ErrENOENT
			}
		case auditDir:
			if !st.audit {
				return 0, -vi.ErrENOENT
			}
		default:
			return 0, -vi.ErrENOENT
		}
		return 0, 0
	}
	// auditInit's deps: the epoch draw, a quiet clock, and an empty lane.
	randomFn = func(p []byte) (int, error) {
		for i := range p {
			p[i] = byte(i)
		}
		return len(p), nil
	}
	auditListFn = func() []string { return nil }
	timeFn = func() int64 { return 0 }
	lane = auditLane{}
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

// The posture checks run in ADR 0052 D1 order — principal, credential,
// keyring, sandbox root, audit lane — and each refusal is one marker plus
// exit 1 before any listen.
func TestPostureOrder(t *testing.T) {
	good := postureState{cred: true, keyring: "ok", root: true, audit: true}
	// argv is checked before any posture probe.
	logs, status := posture(t, []string{"--bogus"}, 2000, 0, true, good)
	if status != 1 || len(logs) != 1 || logs[0] != "agentd: refuse argv" {
		t.Fatalf("argv refusal = %v status %d", logs, status)
	}
	logs, status = posture(t, nil, 0, 0, true, good)
	if status != 1 || len(logs) != 1 || logs[0] != "agentd: refuse privileged" {
		t.Fatalf("uid 0 = %v status %d", logs, status)
	}
	// M173d: uid_user is refused too — only the agent principal serves.
	logs, status = posture(t, nil, 1000, 0, true, good)
	if status != 1 || logs[0] != "agentd: refuse privileged" {
		t.Fatalf("uid_user = %v status %d", logs, status)
	}
	logs, status = posture(t, nil, 2000, 1, true, good)
	if status != 1 || logs[0] != "agentd: refuse privileged" {
		t.Fatalf("caps = %v status %d", logs, status)
	}
	logs, status = posture(t, nil, 2000, 0, false, good)
	if status != 1 || logs[0] != "agentd: refuse privileged" {
		t.Fatalf("no principal = %v status %d", logs, status)
	}
	logs, status = posture(t, nil, 2000, 0, true, postureState{keyring: "ok", root: true, audit: true})
	if status != 1 || len(logs) != 1 || logs[0] != "agentd: refuse no-credential" {
		t.Fatalf("no cred = %v status %d", logs, status)
	}
	logs, status = posture(t, nil, 2000, 0, true, postureState{cred: true, root: true, audit: true})
	if status != 1 || len(logs) != 1 || logs[0] != "agentd: refuse no-keyring" {
		t.Fatalf("no keyring = %v status %d", logs, status)
	}
	logs, status = posture(t, nil, 2000, 0, true,
		postureState{cred: true, keyring: "not a keyring", root: true, audit: true})
	if status != 1 || len(logs) != 1 || logs[0] != "agentd: refuse keyring-malformed" {
		t.Fatalf("malformed keyring = %v status %d", logs, status)
	}
	logs, status = posture(t, nil, 2000, 0, true, postureState{cred: true, keyring: "ok", audit: true})
	if status != 1 || len(logs) != 1 || logs[0] != "agentd: refuse no-root" {
		t.Fatalf("no root = %v status %d", logs, status)
	}
	logs, status = posture(t, nil, 2000, 0, true, postureState{cred: true, keyring: "ok", root: true})
	if status != 1 || len(logs) != 1 || logs[0] != "agentd: refuse no-audit" {
		t.Fatalf("no audit = %v status %d", logs, status)
	}
	// A good posture prints the start marker and reaches listen — the
	// fake refuses it, and the daemon reports the errno and exits.
	logs, status = posture(t, []string{"--allow-exec"}, 2000, 0, true, good)
	if status != 1 || len(logs) != 2 ||
		logs[0] != "agentd: start exec=on" ||
		!strings.HasPrefix(logs[1], "agentd: refuse listen errno=") {
		t.Fatalf("good posture = %v status %d", logs, status)
	}
}
