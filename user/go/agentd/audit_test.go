package main

// ADR 0052 D4 / M109c: the receipt lane — file shape, MAC, bounded
// rotation, the session open/auth_fail/close bracket, and the per-verb
// result records including the gosh.run pre-exec intent.

import (
	"strings"
	"testing"

	"virelai/shlib"
	"virelai/vi"
)

// sessShare is the in-memory host share the session seams publish receipts
// into (sessionSeams installs the write/delete/list fakes below).
var sessShare = map[string][]byte{}

// shareReceiptNames lists the fake share's committed RCPT-* names sorted —
// the auditListFn fake's answer.
func shareReceiptNames(files map[string][]byte) []string {
	var names []string
	prefix := auditDir + "/"
	for p := range files {
		if strings.HasPrefix(p, prefix) && validReceiptName(p[len(prefix):]) {
			names = insertName(names, p[len(prefix):])
		}
	}
	return names
}

// auditTestSeams resets the lane to a pinned key/epoch and points its file
// ops at files. Callers still need seamScope/sessionSeams for the shared
// seams; this owns only the audit-specific ones.
func auditTestSeams(t *testing.T, files map[string][]byte, key, epochHex string) {
	t.Helper()
	prevLane := lane
	prevWrite, prevDel := writeFileFn, deleteFileFn
	prevList, prevTime := auditListFn, timeFn
	lane = auditLane{key: []byte(key)}
	e, ok := hexDecode(epochHex)
	if !ok || len(e) != 4 {
		t.Fatalf("bad epochHex %q", epochHex)
	}
	lane.epoch = uint32(e[0])<<24 | uint32(e[1])<<16 | uint32(e[2])<<8 | uint32(e[3])
	writeFileFn = func(path string, b []byte) int64 {
		files[path] = append([]byte(nil), b...)
		return 0
	}
	deleteFileFn = func(path string) int64 {
		delete(files, path)
		return 0
	}
	auditListFn = func() []string { return shareReceiptNames(files) }
	timeFn = func() int64 { return 1761234567 }
	t.Cleanup(func() {
		lane = prevLane
		writeFileFn, deleteFileFn = prevWrite, prevDel
		auditListFn, timeFn = prevList, prevTime
	})
}

// receiptField extracts a top-level string/number field from a receipt's
// JSON line using the in-package reader.
func receiptField(t *testing.T, line, key string) jval {
	t.Helper()
	v, rest, ok := parseValue([]byte(line))
	if !ok || len(skipWS(rest)) != 0 || v.kind != jObj {
		t.Fatalf("receipt line is not a flat object: %q", line)
	}
	for _, m := range v.membs {
		if m.key == key {
			return m.val
		}
	}
	t.Fatalf("receipt has no %s: %q", key, line)
	return jval{}
}

// readReceipt decodes one receipt file: the JSON line, its fields, and the
// MAC verdict under key.
func readReceipt(t *testing.T, files map[string][]byte, name, key string) (jval, bool) {
	t.Helper()
	line := receiptLine1(t, files, name)
	v, rest, ok := parseValue([]byte(line))
	if !ok || len(skipWS(rest)) != 0 || v.kind != jObj {
		t.Fatalf("receipt line does not parse: %q", line)
	}
	want := shlib.HMACSHA256([]byte(key), []byte(line))
	parts := strings.Split(string(files[auditDir+"/"+name]), "\n")
	return v, parts[1] == hexString(want[:])
}

// receiptLine1 returns the receipt file's JSON line (line 2 is the MAC).
func receiptLine1(t *testing.T, files map[string][]byte, name string) string {
	t.Helper()
	body, ok := files[auditDir+"/"+name]
	if !ok {
		t.Fatalf("no receipt %s; have %v", name, files)
	}
	parts := strings.Split(string(body), "\n")
	if len(parts) != 3 || parts[2] != "" {
		t.Fatalf("receipt %s is not two lines: %q", name, body)
	}
	return parts[0]
}

// receiptNames returns the share's RCPT-* names in lexical (seq) order.
func receiptNames(files map[string][]byte) []string {
	return shareReceiptNames(files)
}

func TestAuditInitArmsLane(t *testing.T) {
	seamScope(t)
	prev := lane
	defer func() { lane = prev }()
	lane = auditLane{}
	secretGetFn = func(name string, out []byte) int {
		if name != secretName {
			return -1
		}
		return copy(out, "receipt-key")
	}
	randomFn = func(p []byte) (int, error) {
		for i := range p {
			p[i] = 0xab
		}
		return len(p), nil
	}
	auditListFn = func() []string { return []string{"RCPT-00000001-00000009"} }
	if code := auditInit(); code != "" {
		t.Fatalf("auditInit = %q", code)
	}
	if string(lane.key) != "receipt-key" || lane.epoch != 0xabababab || lane.seq != 0 {
		t.Fatalf("lane = %+v", lane)
	}
	if len(lane.names) != 1 || lane.names[0] != "RCPT-00000001-00000009" {
		t.Fatalf("lane.names = %v", lane.names)
	}
}

func TestAuditInitRefusals(t *testing.T) {
	seamScope(t)
	prev := lane
	defer func() { lane = prev }()
	lane = auditLane{}
	secretGetFn = func(string, []byte) int { return -1 }
	randomFn = func(p []byte) (int, error) { return len(p), nil }
	auditListFn = func() []string { return nil }
	if code := auditInit(); code != "no-credential" {
		t.Fatalf("missing key auditInit = %q", code)
	}
	secretGetFn = func(name string, out []byte) int { return copy(out, "k") }
	randomFn = func(p []byte) (int, error) { return 0, vi.ErrPeerGone }
	if code := auditInit(); code != "no-entropy" {
		t.Fatalf("dead entropy auditInit = %q", code)
	}
}

func TestReceiptFileShape(t *testing.T) {
	seamScope(t)
	files := map[string][]byte{}
	auditTestSeams(t, files, "receipt-key", "a1b2c3d4")
	lane.emit("devin", "fs.write", `{"path":"HELLO.TXT","size":27,"sha256_8":"01234567"}`, "ok")
	names := receiptNames(files)
	if len(names) != 1 || names[0] != "RCPT-a1b2c3d4-00000001" {
		t.Fatalf("names = %v", names)
	}
	v, macOK := readReceipt(t, files, names[0], "receipt-key")
	if !macOK {
		t.Fatal("receipt MAC does not verify")
	}
	line := receiptLine1(t, files, names[0])
	for key, want := range map[string]string{
		"seq": "1", "epoch": "a1b2c3d4", "agent": "devin",
		"verb": "fs.write", "result": "ok", "ts": "1761234567",
	} {
		if got := receiptField(t, line, key).str; got != want {
			t.Fatalf("receipt %s = %q want %q (v=%v)", key, got, want, v)
		}
	}
}

func TestReceiptRotation(t *testing.T) {
	seamScope(t)
	files := map[string][]byte{}
	auditTestSeams(t, files, "k", "0000000a")
	logs := &[]string{}
	prevConsole := consoleFn
	consoleFn = func(s string) { *logs = append(*logs, s) }
	t.Cleanup(func() { consoleFn = prevConsole })
	// Preload the bound: 64 foreign-epoch names already on the lane.
	for i := 1; i <= auditFileMax; i++ {
		name := "RCPT-00000001-" + hex8u(uint32(i))
		files[auditDir+"/"+name] = []byte("x\ny\n")
		lane.names = insertName(lane.names, name)
	}
	lane.emit("a", "session", `{"event":"open"}`, "ok")
	rcpts := receiptNames(files)
	if len(rcpts) != auditFileMax {
		t.Fatalf("lane holds %d receipts want %d", len(rcpts), auditFileMax)
	}
	if _, ok := files[auditDir+"/RCPT-00000001-00000001"]; ok {
		t.Fatal("the oldest receipt was not dropped")
	}
	if !hasLine(*logs, "agentd: audit drop RCPT-00000001-00000001") {
		t.Fatalf("markers = %v", *logs)
	}
	if _, ok := files[auditDir+"/RCPT-0000000a-00000001"]; !ok {
		t.Fatal("the new receipt is missing")
	}
}

// A share that outlives boots holds earlier epochs whose names sort
// anywhere. When the fresh epoch sorts BEFORE the stale set, lexical
// rotation would eat the boot's own receipts on write (observed: a
// run-10 session's open/fail/close dropped immediately). The bound
// drops the smallest EARLIER-epoch name instead — a boot's evidence is
// always its newest.
func TestReceiptRotationCrossEpoch(t *testing.T) {
	seamScope(t)
	files := map[string][]byte{}
	logs := &[]string{}
	prevCon := consoleFn
	consoleFn = func(s string) { *logs = append(*logs, s) }
	t.Cleanup(func() { consoleFn = prevCon })
	auditTestSeams(t, files, "receipt-key", "01020304")
	// Sixty-four receipts from an earlier boot whose epoch sorts AFTER
	// the fresh one — every one of them lexically beats RCPT-01020304-*.
	for i := 1; i <= auditFileMax; i++ {
		name := "RCPT-ff000000-" + hex8u(uint32(i))
		files[auditDir+"/"+name] = []byte("x\ny\n")
		lane.names = insertName(lane.names, name)
	}
	lane.emit("a", "session", `{"event":"open"}`, "ok")
	if _, ok := files[auditDir+"/RCPT-01020304-00000001"]; !ok {
		t.Fatal("the fresh epoch's own receipt was rotated out")
	}
	if _, ok := files[auditDir+"/RCPT-ff000000-00000001"]; ok {
		t.Fatal("the smallest earlier-epoch receipt should have been dropped")
	}
	if !hasLine(*logs, "agentd: audit drop RCPT-ff000000-00000001") {
		t.Fatalf("markers = %v", *logs)
	}
	if len(lane.names) != auditFileMax {
		t.Fatalf("lane.names = %d", len(lane.names))
	}
}

func TestAuditNamesFilter(t *testing.T) {
	// "~" publish temps and foreign names never join the lane set.
	for _, bad := range []string{
		"RCPT-00000001-00000001~", "OTHER.TXT", "RCPT-", "RCPT-zzzzzzzz-00000001",
		"RCPT-00000001_00000001", "RCPT-00000001-0000000g",
	} {
		if validReceiptName(bad) {
			t.Fatalf("validReceiptName(%q) = true", bad)
		}
	}
	if !validReceiptName("RCPT-00000001-00000001") || !validReceiptName("RCPT-ABCDEF01-abcdef01") {
		t.Fatal("a real receipt name failed validation")
	}
}

// The authenticated session's audit bracket: open under "-", one receipt
// per dispatch in order, close under the agent id — refusals included.
func TestSessionReceipts(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{procs: []vi.ProcRow{proc(9, vi.ProcRunning, 0, "AGENTD.ELF")}}
	k.install()
	sessShare = map[string][]byte{}
	files := sessShare
	sessionSeams(t, keyringBody())
	c := &fakeConn{chunks: [][]byte{[]byte(
		authLine(t, pinnedAgent) + "\n" +
			`{"id":1,"verb":"proc.list"}` + "\n" +
			`{"id":2,"verb":"fs.read","path":"AUDIT/X"}` + "\n" +
			`{"id":3,"verb":"nope"}` + "\n"),
	}, recvErr: errPeerGoneTest}
	failed := session(c, true)
	if failed {
		t.Fatal("good session reported authFailed")
	}
	names := receiptNames(files)
	// open + 3 dispatches + close = 5 receipts.
	if len(names) != 5 {
		t.Fatalf("receipts = %v (files %v)", names, files)
	}
	type want struct {
		agent, verb, result string
	}
	wants := []want{
		{"-", "session", "ok"},
		{"devin", "proc.list", "ok"},
		{"devin", "fs.read", "path_rejected"},
		{"devin", "nope", "unknown_verb"},
		{"devin", "session", "client_close"},
	}
	for i, w := range wants {
		v, macOK := readReceipt(t, files, names[i], "receipt-key")
		if !macOK {
			t.Fatalf("receipt %d MAC fails", i)
		}
		line := receiptLine1(t, files, names[i])
		for key, want := range map[string]string{
			"agent": w.agent, "verb": w.verb, "result": w.result,
		} {
			if got := receiptField(t, line, key).str; got != want {
				t.Fatalf("receipt %d %s = %q want %q (v=%v)", i, key, got, want, v)
			}
		}
		seq := receiptField(t, line, "seq").str
		if seq != vi.Itoa64(int64(i+1)) {
			t.Fatalf("receipt %d seq = %q", i, seq)
		}
	}
}

// A failed auth receipts its claimed id — a refused credential is named.
func TestAuthFailReceipt(t *testing.T) {
	seamScope(t)
	sessShare = map[string][]byte{}
	files := sessShare
	sessionSeams(t, keyringBody())
	bad := strings.Repeat("0", 128)
	c := &fakeConn{chunks: [][]byte{[]byte(
		`{"agent":"` + pinnedAgent + `","auth":"` + bad + `"}` + "\n")}}
	if failed := session(c, true); !failed {
		t.Fatal("bad sig not reported as auth failure")
	}
	names := receiptNames(files)
	if len(names) != 3 {
		t.Fatalf("receipts = %v", names)
	}
	line := receiptLine1(t, files, names[1])
	if got := receiptField(t, line, "agent").str; got != pinnedAgent {
		t.Fatalf("auth_fail agent = %q", got)
	}
	if got := receiptField(t, line, "result").str; got != "auth_failed" {
		t.Fatalf("auth_fail result = %q", got)
	}
	if got := receiptField(t, line, "verb").str; got != "session" {
		t.Fatalf("auth_fail verb = %q", got)
	}
	// The close receipt names the refused session's end and stays "-": the
	// claimed id never authenticated.
	line = receiptLine1(t, files, names[2])
	if got := receiptField(t, line, "result").str; got != "auth_failed" {
		t.Fatalf("close result = %q", got)
	}
	if got := receiptField(t, line, "agent").str; got != "-" {
		t.Fatalf("close agent = %q", got)
	}
}

// gosh.run writes the pre-exec intent receipt and the post-dispatch
// outcome receipt — the pair is the D4 residual (a) record.
func TestGoshRunReceiptPair(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{waitSt: 0, outBody: []byte("hi\n")}
	k.install()
	sessShare = map[string][]byte{}
	files := sessShare
	sessionSeams(t, keyringBody())
	c := &fakeConn{chunks: [][]byte{[]byte(
		authLine(t, pinnedAgent) + "\n" +
			`{"id":1,"verb":"gosh.run","cmd":"echo hi"}` + "\n"),
	}, recvErr: errPeerGoneTest}
	session(c, true)
	names := receiptNames(files)
	// open + intent + outcome + close.
	if len(names) != 4 {
		t.Fatalf("receipts = %v", names)
	}
	intent := receiptLine1(t, files, names[1])
	outcome := receiptLine1(t, files, names[2])
	for _, line := range []string{intent, outcome} {
		if got := receiptField(t, line, "verb").str; got != "gosh.run" {
			t.Fatalf("receipt verb = %q", got)
		}
	}
	if got := receiptField(t, outcome, "result").str; got != "ok" {
		t.Fatalf("outcome result = %q", got)
	}
	// The outcome carries the exit status; the intent predates it.
	if got := receiptField(t, outcome, "args").membs; !jvalHas(got, "exit_status") {
		t.Fatalf("outcome args = %v", got)
	}
	if got := receiptField(t, intent, "args").membs; jvalHas(got, "exit_status") {
		t.Fatalf("intent args carried an exit status: %v", got)
	}
	for _, line := range []string{intent, outcome} {
		args := receiptField(t, line, "args")
		cmd := ""
		for _, m := range args.membs {
			if m.key == "cmd" {
				cmd = m.val.str
			}
		}
		if cmd != "echo hi" {
			t.Fatalf("args cmd = %q", cmd)
		}
	}
}

func jvalHas(membs []jmember, key string) bool {
	for _, m := range membs {
		if m.key == key {
			return true
		}
	}
	return false
}

// A timed-out child is still receipted by name — refusal verbs included.
func TestGoshTimeoutReceipt(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{waitErr: errTimeout, outBody: nil}
	k.install()
	sessShare = map[string][]byte{}
	files := sessShare
	sessionSeams(t, keyringBody())
	c := &fakeConn{chunks: [][]byte{[]byte(
		authLine(t, pinnedAgent) + "\n" +
			`{"id":1,"verb":"gosh.run","cmd":"sleep 9","timeout_ms":100}` + "\n"),
	}, recvErr: errPeerGoneTest}
	session(c, true)
	names := receiptNames(files)
	if len(names) != 4 {
		t.Fatalf("receipts = %v", names)
	}
	outcome := receiptLine1(t, files, names[2])
	if got := receiptField(t, outcome, "result").str; got != "timed_out" {
		t.Fatalf("outcome result = %q", got)
	}
}

// fs.write's payload reduces to size + sha256_8; the bytes never appear.
func TestFSWriteReceiptDigest(t *testing.T) {
	seamScope(t)
	sessShare = map[string][]byte{}
	files := sessShare
	sessionSeams(t, keyringBody())
	payload := "audit-body"
	c := &fakeConn{chunks: [][]byte{[]byte(
		authLine(t, pinnedAgent) + "\n" +
			`{"id":1,"verb":"fs.write","path":"W.TXT","data_b64":"` +
			b64Encode([]byte(payload)) + `"}` + "\n"),
	}, recvErr: errPeerGoneTest}
	session(c, true)
	names := receiptNames(files)
	line := receiptLine1(t, files, names[1])
	args := receiptField(t, line, "args")
	got := map[string]string{}
	for _, m := range args.membs {
		got[m.key] = m.val.str
	}
	if got["path"] != "W.TXT" || got["size"] != "10" {
		t.Fatalf("args = %v", got)
	}
	d := shlib.SHA256Sum([]byte(payload))
	if got["sha256_8"] != hexString(d[:4]) {
		t.Fatalf("sha256_8 = %q", got["sha256_8"])
	}
	if strings.Contains(line, payload) {
		t.Fatalf("payload bytes reached the receipt: %q", line)
	}
}
