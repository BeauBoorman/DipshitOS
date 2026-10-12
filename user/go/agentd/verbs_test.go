package main

// ADR 0044 D3/D4 / AC2: the NAME table, every D4 code exercised through
// dispatch, and each verb's green/red behavior against fake kernel seams.

import (
	"errors"
	"strings"
	"testing"

	"virelai/vi"
)

// mustReq parses a request line or fails the test — the helper every
// dispatch-level test uses.
func mustReq(t *testing.T, line string) *request {
	t.Helper()
	v, code := parseLine([]byte(line))
	if code != "" {
		t.Fatalf("parseLine(%q) = %q", line, code)
	}
	req, code := validateRequest(v)
	if code != "" {
		t.Fatalf("validateRequest(%q) = %q", line, code)
	}
	return req
}

// seamScope saves and restores every substitutable seam a test touches.
func seamScope(t *testing.T) {
	t.Helper()
	saved := []func(){
		func() { procsFn = procsSave },
		func() { readFileFn = readSave },
		func() { writeFileFn = writeSave },
		func() { deleteFileFn = deleteSave },
		func() { dirListFn = dirSave },
		func() { execFn = execSave },
		func() { waitFn = waitSave },
		func() { killFn = killSave },
		func() { probeFn = probeSave },
		func() { seatPidFn = seatSave },
		func() { winOpenFn = winSave },
		func() { winHideFn = winHideSave },
		func() { wmWindowsFn = wmSave },
		func() { agentWindow = -1 },
		func() { secretGetFn = secretSave },
		func() { principalFn = principalSave },
		func() { randomFn = randomSave },
		func() { argsFn = argsSave },
		func() { consoleFn = consoleSave },
		func() { sleepFn = sleepSave },
		func() { exitFn = exitSave },
	}
	t.Cleanup(func() {
		for _, restore := range saved {
			restore()
		}
	})
}

var (
	procsSave     = procsFn
	readSave      = readFileFn
	writeSave     = writeFileFn
	deleteSave    = deleteFileFn
	dirSave       = dirListFn
	execSave      = execFn
	waitSave      = waitFn
	killSave      = killFn
	probeSave     = probeFn
	seatSave      = seatPidFn
	winSave       = winOpenFn
	winHideSave   = winHideFn
	wmSave        = wmWindowsFn
	secretSave    = secretGetFn
	principalSave = principalFn
	randomSave    = randomFn
	argsSave      = argsFn
	consoleSave   = consoleFn
	sleepSave     = sleepFn
	exitSave      = exitFn
)

// fakeKernel is a scriptable kernel for the verb tests: a proc table, a
// map of file contents, dir entries, and spawn/wait outcomes.
type fakeKernel struct {
	procs    []vi.ProcRow
	files    map[string][]byte
	dirs     map[string][]vi.DirEntry
	fileErr  map[string]int64
	writeErr int64
	spawnErr error
	spawnPID int64
	waitErr  error
	waitSt   int64
	seatPid  int64
	winID    int
	winErr   int64
	winW     uint32
	winH     uint32
	hidden   bool
	wmRows   []vi.WmWindowRow
	wmErr    error
	outBody  []byte // what the spawned GOSH "wrote" to AGENTD.OUT
	// captured
	wrotePath string
	wroteBody []byte
	execArgv  []string
	killed    uint64
	deleted   []string
}

func (k *fakeKernel) install() {
	procsFn = func(dst []vi.ProcRow) (int, int64) {
		n := copy(dst, k.procs)
		return n, int64(n)
	}
	readFileFn = func(path string, max int) ([]byte, int64) {
		if path == outPath && k.outBody != nil {
			b := k.outBody
			if len(b) > max {
				b = b[:max]
			}
			return append([]byte(nil), b...), int64(len(b))
		}
		if e, bad := k.fileErr[path]; bad {
			return nil, e
		}
		b, ok := k.files[path]
		if !ok {
			return nil, -vi.ErrENOENT
		}
		if len(b) > max {
			b = b[:max]
		}
		out := make([]byte, len(b))
		copy(out, b)
		return out, int64(len(out))
	}
	writeFileFn = func(path string, b []byte) int64 {
		if k.writeErr != 0 {
			return k.writeErr
		}
		k.wrotePath = path
		k.wroteBody = append([]byte(nil), b...)
		if k.files == nil {
			k.files = map[string][]byte{}
		}
		k.files[path] = append([]byte(nil), b...)
		return 0
	}
	deleteFileFn = func(path string) int64 {
		k.deleted = append(k.deleted, path)
		delete(k.files, path)
		return 0
	}
	dirListFn = func(path string, buf []vi.DirEntry) (int, int64) {
		ents, ok := k.dirs[path]
		if !ok {
			return 0, -vi.ErrENOENT
		}
		n := copy(buf, ents)
		return n, int64(n)
	}
	execFn = func(name string, args ...string) (int64, error) {
		k.execArgv = append([]string{name}, args...)
		if k.spawnErr != nil {
			return 0, k.spawnErr
		}
		if k.spawnPID == 0 {
			k.spawnPID = 42
		}
		return k.spawnPID, nil
	}
	waitFn = func(pid int64, budgetNs int64) (int64, error) {
		if k.waitErr != nil {
			return -1, k.waitErr
		}
		return k.waitSt, nil
	}
	killFn = func(pid uint64) int64 {
		k.killed = pid
		return 0
	}
	probeFn = func(pid int64) (int64, int) {
		return 0, vi.ProbeAbsent
	}
	seatPidFn = func() int64 { return k.seatPid }
	winOpenFn = func(x, y, w, h uint32) (int, int64) {
		if k.winErr != 0 {
			return -1, k.winErr
		}
		k.winW, k.winH = w, h
		if k.winID == 0 {
			k.winID = 7
		}
		return k.winID, int64(k.winID)
	}
	winHideFn = func(id int, visible bool) int64 {
		if id == k.winID && !visible {
			k.hidden = true
		}
		return 0
	}
	wmWindowsFn = func(winID uint32, self string) ([]vi.WmWindowRow, error) {
		if self != appName || int(winID) != k.winID {
			return nil, vi.ErrSeatSilent
		}
		return k.wmRows, k.wmErr
	}
}

func dirEnt(name string, isDir bool) vi.DirEntry {
	var e vi.DirEntry
	copy(e.Name[:], name)
	if isDir {
		e.IsDir = 1
	}
	return e
}

func proc(pid uint64, state uint64, st uint64, name string) vi.ProcRow {
	r := vi.ProcRow{PID: pid, State: state, ExitStatus: st}
	copy(r.NameBuf[:], name)
	return r
}

// --- NAME validator -------------------------------------------------------------

func TestValidNameTable(t *testing.T) {
	accept := []string{
		"SEED.TXT", "seed.txt", "A", "9", "A.B-C_D", "X" + strings.Repeat("y", 30),
	}
	for _, s := range accept {
		if !validName(s) {
			t.Fatalf("validName(%q) = false", s)
		}
	}
	refuse := []string{
		"", "..", ".", ".HIDDEN", "../SECRETS.TXT", "/host/SECRETS.TXT",
		"SUB/X", "A B", "A\x00B", "X~", "x;y", "a|b", "a&b", "a<b", "a>b",
		"a#b", "-X", "_X", "é", "A" + strings.Repeat("y", 31),
		strings.Repeat("x", 32),
	}
	for _, s := range refuse {
		if validName(s) {
			t.Fatalf("validName(%q) = true", s)
		}
	}
}

// --- proc verbs ----------------------------------------------------------------

func TestProcListAndGet(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{procs: []vi.ProcRow{
		proc(9, vi.ProcRunning, 0, "AGENTD.ELF"),
		proc(3, vi.ProcExited, 7, "GOSH.ELF"),
	}}
	k.install()
	res, code := verbProcList()
	if code != "" {
		t.Fatal(code)
	}
	want := `{"procs":[{"pid":9,"name":"AGENTD.ELF","state":"running","exit_status":null},` +
		`{"pid":3,"name":"GOSH.ELF","state":"exited","exit_status":7}]}`
	if res != want {
		t.Fatalf("proc.list = %q want %q", res, want)
	}

	res, code = verbProcGet(mustReq(t, `{"id":1,"verb":"proc.get","pid":9}`))
	if code != "" || res != `{"pid":9,"name":"AGENTD.ELF","state":"running","exit_status":null}` {
		t.Fatalf("proc.get = %q code %q", res, code)
	}
	if _, code = verbProcGet(mustReq(t, `{"id":1,"verb":"proc.get","pid":4000}`)); code != "not_found" {
		t.Fatalf("absent pid code = %q", code)
	}
	// pid must be an integer in range: 0 is out of range, "1" is a
	// string — flat-valid, but not this verb's type, so the refusal lands
	// at dispatch as bad_request.
	if _, code = verbProcGet(mustReq(t, `{"id":1,"verb":"proc.get","pid":0}`)); code != "bad_request" {
		t.Fatalf("pid 0 = %q", code)
	}
	if _, code = verbProcGet(mustReq(t, `{"id":1,"verb":"proc.get","pid":"1"}`)); code != "bad_request" {
		t.Fatalf("pid \"1\" code = %q", code)
	}
}

// --- fs verbs -------------------------------------------------------------------

func TestFSReadGreenAndRed(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{
		files: map[string][]byte{
			"/host/AGENT/SEED.TXT": []byte("seed-bytes"),
			"/host/AGENT/BIG.BIN":  make([]byte, 4097),
		},
		dirs: map[string][]vi.DirEntry{
			sandboxDir: {dirEnt("SEED.TXT", false), dirEnt("SUB", true)},
		},
		fileErr: map[string]int64{"/host/AGENT/SUB": -vi.ErrEINVAL},
	}
	k.install()

	res, code := verbFSRead(mustReq(t, `{"id":1,"verb":"fs.read","path":"SEED.TXT"}`))
	if code != "" || res != `{"path":"SEED.TXT","size":10,"data_b64":"c2VlZC1ieXRlcw=="}` {
		t.Fatalf("fs.read = %q code %q", res, code)
	}
	if _, code = verbFSRead(mustReq(t, `{"id":1,"verb":"fs.read","path":"NOPE.TXT"}`)); code != "not_found" {
		t.Fatalf("ENOENT code = %q", code)
	}
	if _, code = verbFSRead(mustReq(t, `{"id":1,"verb":"fs.read","path":"BIG.BIN"}`)); code != "too_large" {
		t.Fatalf("4097-byte read code = %q", code)
	}
	if _, code = verbFSRead(mustReq(t, `{"id":1,"verb":"fs.read","path":"SUB"}`)); code != "not_a_file" {
		t.Fatalf("dir read code = %q", code)
	}
	// Every path_rejected shape in the gate matrix.
	for _, p := range []string{
		"../SECRETS.TXT", "/host/SECRETS.TXT", "SUB/X", ".", "..", "",
		strings.Repeat("x", 32), "X~", "A\x00B",
	} {
		line := `{"id":1,"verb":"fs.read","path":` + quoteJSON(p) + `}`
		v, _ := parseLine([]byte(line))
		req, vc := validateRequest(v)
		if vc != "" {
			t.Fatalf("path %q: validate = %q", p, vc)
		}
		if _, code = verbFSRead(req); code != "path_rejected" {
			t.Fatalf("path %q code = %q want path_rejected", p, code)
		}
	}
	// Case-insensitive NAME match: seed.txt resolves to SEED.TXT's row —
	// the kernel does the folding; the validator just accepts the name.
	res, code = verbFSRead(mustReq(t, `{"id":1,"verb":"fs.read","path":"seed.txt"}`))
	if code == "path_rejected" {
		t.Fatal("lowercase NAME rejected")
	}
}

func TestFSWrite(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{
		dirs: map[string][]vi.DirEntry{sandboxDir: {}},
	}
	k.install()
	res, code := verbFSWrite(mustReq(t,
		`{"id":1,"verb":"fs.write","path":"HELLO.TXT","data_b64":"aGVsbG8="}`))
	if code != "" || res != `{"path":"HELLO.TXT","size":5}` {
		t.Fatalf("fs.write = %q code %q", res, code)
	}
	if k.wrotePath != "/host/AGENT/HELLO.TXT" || string(k.wroteBody) != "hello" {
		t.Fatalf("write went to %q", k.wrotePath)
	}
	// 4097 decoded bytes is too_large BEFORE the file call.
	body := b64Encode(make([]byte, 4097))
	k.wrotePath = ""
	if _, code = verbFSWrite(mustReq(t,
		`{"id":1,"verb":"fs.write","path":"BIG.BIN","data_b64":"`+body+`"}`)); code != "too_large" {
		t.Fatalf("4097-body code = %q", code)
	}
	if k.wrotePath != "" {
		t.Fatal("too_large write touched the file ABI")
	}
	// Bad base64 is bad_request before any file call.
	if _, code = verbFSWrite(mustReq(t,
		`{"id":1,"verb":"fs.write","path":"X","data_b64":"@@"}`)); code != "bad_request" {
		t.Fatalf("bad b64 code = %q", code)
	}
	if _, code = verbFSWrite(mustReq(t,
		`{"id":1,"verb":"fs.write","path":"../X","data_b64":"QQ=="}`)); code != "path_rejected" {
		t.Fatalf("traversal write code = %q", code)
	}
	// A kernel EACCES is access_denied.
	k.writeErr = -vi.ErrEACCES
	if _, code = verbFSWrite(mustReq(t,
		`{"id":1,"verb":"fs.write","path":"X","data_b64":"QQ=="}`)); code != "access_denied" {
		t.Fatalf("EACCES code = %q", code)
	}
	k.writeErr = 0
	// A directory target is not_a_file before the write.
	k.dirs[sandboxDir] = []vi.DirEntry{dirEnt("SUB", true)}
	if _, code = verbFSWrite(mustReq(t,
		`{"id":1,"verb":"fs.write","path":"SUB","data_b64":"QQ=="}`)); code != "not_a_file" {
		t.Fatalf("dir write code = %q", code)
	}
}

// quoteJSON renders s as a JSON string for request construction.
func quoteJSON(s string) string {
	var sb strings.Builder
	sb.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			sb.WriteByte('\\')
			sb.WriteByte(c)
		case c < 0x20:
			sb.WriteString(`\u00`)
			sb.WriteByte(hexDigits[c>>4])
			sb.WriteByte(hexDigits[c&0xf])
		default:
			sb.WriteByte(c)
		}
	}
	sb.WriteByte('"')
	return sb.String()
}

// --- ui.windows -------------------------------------------------------------------

func TestUIWindows(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{seatPid: 0}
	k.install()
	res, code := verbUIWindows()
	if code != "" || res != `{"seat":"none","focused":null,"windows":[]}` {
		t.Fatalf("no-seat = %q code %q", res, code)
	}

	k.seatPid = 3
	k.winErr = -vi.ErrENOSPC
	if _, code = verbUIWindows(); code != "seat_unsupported" {
		t.Fatalf("winopen fail code = %q", code)
	}
	k.winErr = 0
	k.wmErr = vi.ErrSeatUnsupported
	if _, code = verbUIWindows(); code != "seat_unsupported" {
		t.Fatalf("zig seat code = %q", code)
	}
	k.wmErr = vi.ErrSeatSilent
	if _, code = verbUIWindows(); code != "seat_timeout" {
		t.Fatalf("silent seat code = %q", code)
	}
	k.wmErr = nil
	k.wmRows = []vi.WmWindowRow{
		{Index: 0, ID: 100, Title: "Calc", Focused: true},
		{Index: 1, ID: 101, Title: "Notes", Pinned: true},
	}
	res, code = verbUIWindows()
	if code != "" {
		t.Fatal(code)
	}
	// The bind window opens at the kernel's resize floor and hides at
	// once (D5: never on the strip it reads, never painted).
	if k.winW != 128 || k.winH != 64 || !k.hidden {
		t.Fatalf("bind window = %dx%d hidden=%v", k.winW, k.winH, k.hidden)
	}
	want := `{"seat":"gotabwm","focused":0,"windows":[` +
		`{"index":0,"id":100,"title":"Calc","focused":true,"pinned":false,"frozen":false},` +
		`{"index":1,"id":101,"title":"Notes","focused":false,"pinned":true,"frozen":false}]}`
	if res != want {
		t.Fatalf("ui.windows = %q want %q", res, want)
	}
}

// --- gosh.run ----------------------------------------------------------------------

func TestGoshRunValidation(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{dirs: map[string][]vi.DirEntry{sandboxDir: {}}}
	k.install()

	// Disabled daemon: verb_disabled before anything runs.
	if _, code := verbGoshRun(mustReq(t,
		`{"id":1,"verb":"gosh.run","cmd":"echo hi"}`), false); code != "verb_disabled" {
		t.Fatalf("noexec code = %q", code)
	}
	if len(k.execArgv) != 0 {
		t.Fatal("disabled gosh.run spawned")
	}

	for _, tc := range []struct{ line, code string }{
		{`{"id":1,"verb":"gosh.run"}`, "bad_request"},
		{`{"id":1,"verb":"gosh.run","cmd":""}`, "too_large"},
		{`{"id":1,"verb":"gosh.run","cmd":"` + strings.Repeat("x", 193) + `"}`, "too_large"},
		{`{"id":1,"verb":"gosh.run","cmd":"echo a > X"}`, "cmd_rejected"},
		{`{"id":1,"verb":"gosh.run","cmd":"echo a #c"}`, "cmd_rejected"},
		{`{"id":1,"verb":"gosh.run","cmd":"echo a &"}`, "cmd_rejected"},
		{`{"id":1,"verb":"gosh.run","cmd":"echo 'a"}`, "cmd_rejected"},
		{`{"id":1,"verb":"gosh.run","cmd":"echo a\nls"}`, "cmd_rejected"},
		{`{"id":1,"verb":"gosh.run","cmd":"echo hi","timeout_ms":0}`, "bad_request"},
		{`{"id":1,"verb":"gosh.run","cmd":"echo hi","timeout_ms":30001}`, "bad_request"},
		{`{"id":1,"verb":"gosh.run","cmd":"echo hi","timeout_ms":"5"}`, "bad_request"},
	} {
		if _, code := dispatch(mustReq(t, tc.line), true); code != tc.code {
			t.Fatalf("%s: code = %q want %q", tc.line, code, tc.code)
		}
		if len(k.execArgv) != 0 {
			t.Fatalf("%s spawned", tc.line)
		}
	}
}

func TestGoshRunLifecycle(t *testing.T) {
	seamScope(t)
	var logs []string
	consoleFn = func(s string) { logs = append(logs, s) }
	k := &fakeKernel{
		dirs:     map[string][]vi.DirEntry{sandboxDir: {}},
		outBody:  []byte("hello\n"),
		spawnPID: 42,
	}
	k.install()

	res, code := verbGoshRun(mustReq(t,
		`{"id":1,"verb":"gosh.run","cmd":"echo hello"}`), true)
	if code != "" {
		t.Fatal(code)
	}
	want := `{"exit_status":0,"stdout_b64":"aGVsbG8K","truncated":false}`
	if res != want {
		t.Fatalf("gosh.run = %q want %q", res, want)
	}
	if len(k.execArgv) != 3 || k.execArgv[0] != "GOSH.ELF" ||
		k.execArgv[1] != "-c" || k.execArgv[2] != "echo hello > /host/AGENTD.OUT" {
		t.Fatalf("exec argv = %v", k.execArgv)
	}
	if !hasLine(logs, "agentd: spawn pid=42") || !hasLine(logs, "agentd: reap pid=42 status=0") {
		t.Fatalf("markers = %v", logs)
	}
	deleted := 0
	for _, p := range k.deleted {
		if p == outPath {
			deleted++
		}
	}
	if deleted == 0 {
		t.Fatal("AGENTD.OUT was not reaped")
	}

	// A spawn refusal is spawn_failed.
	k.spawnErr = errors.New("ENOENT")
	k.execArgv = nil
	if _, code = verbGoshRun(mustReq(t,
		`{"id":1,"verb":"gosh.run","cmd":"echo hi"}`), true); code != "spawn_failed" {
		t.Fatalf("spawn error code = %q", code)
	}
	k.spawnErr = nil

	// A budget that expires kills the child, confirms through Probe, and
	// answers timed_out — with the reap marker the gate asserts.
	logs = nil
	k.waitErr = vi.ErrWaitGone
	if _, code = verbGoshRun(mustReq(t,
		`{"id":1,"verb":"gosh.run","cmd":"sleep 5","timeout_ms":1000}`), true); code != "timed_out" {
		t.Fatalf("timeout code = %q", code)
	}
	if k.killed != 42 {
		t.Fatalf("killed pid = %d want 42", k.killed)
	}
	if !hasLine(logs, "agentd: reap pid=42") {
		t.Fatalf("timed-out markers = %v", logs)
	}
	k.waitErr = nil

	// Truncated output: 4097 bytes in the capture → truncated flag, 4096
	// bytes of payload.
	k.outBody = make([]byte, 4097)
	res, code = verbGoshRun(mustReq(t,
		`{"id":1,"verb":"gosh.run","cmd":"echo hi"}`), true)
	if code != "" || !strings.Contains(res, `"truncated":true`) {
		t.Fatalf("truncated = %q code %q", res, code)
	}

	// A nonzero child status is still ok:true — the command ran.
	k.outBody = nil
	k.waitSt = 3
	res, code = verbGoshRun(mustReq(t,
		`{"id":1,"verb":"gosh.run","cmd":"cat NOPE.TXT"}`), true)
	if code != "" || !strings.Contains(res, `"exit_status":3`) {
		t.Fatalf("nonzero status = %q code %q", res, code)
	}
}

func TestGoshRunENOSPCRetry(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{spawnPID: 42}
	k.install()
	nanosSave, yieldSave := nanosFn, yieldFn
	t.Cleanup(func() { nanosFn, yieldFn = nanosSave, yieldSave })
	var clock int64
	var yields int
	nanosFn = func() int64 { return clock }
	yieldFn = func() { yields++; clock += 1e6 } // 1 ms per yield

	// Transient ENOSPC (zombie pressure) rides the retry to a spawn.
	calls := 0
	execFn = func(name string, args ...string) (int64, error) {
		calls++
		if calls <= 2 {
			return 0, errors.New("ENOSPC")
		}
		return 42, nil
	}
	if _, code := verbGoshRun(mustReq(t,
		`{"id":1,"verb":"gosh.run","cmd":"echo hi"}`), true); code != "" {
		t.Fatalf("transient ENOSPC code = %q", code)
	}
	if calls != 3 {
		t.Fatalf("exec calls = %d want 3", calls)
	}

	// Persistent ENOSPC past the bound is spawn_failed.
	calls = 0
	execFn = func(name string, args ...string) (int64, error) {
		calls++
		return 0, errors.New("ENOSPC")
	}
	if _, code := verbGoshRun(mustReq(t,
		`{"id":1,"verb":"gosh.run","cmd":"echo hi"}`), true); code != "spawn_failed" {
		t.Fatalf("persistent ENOSPC code = %q", code)
	}
	if yields == 0 {
		t.Fatal("the retry never yielded")
	}
	_ = calls
}

func hasLine(logs []string, prefix string) bool {
	for _, l := range logs {
		if strings.HasPrefix(l, prefix) {
			return true
		}
	}
	return false
}

// --- dispatch coverage ------------------------------------------------------------

// Every D4 code lands at least once through dispatch — AC2's table.
func TestD4Coverage(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{
		procs: []vi.ProcRow{proc(9, vi.ProcRunning, 0, "AGENTD.ELF")},
		files: map[string][]byte{"/host/AGENT/BIG.BIN": make([]byte, 4097)},
		dirs:  map[string][]vi.DirEntry{sandboxDir: {}},
	}
	k.install()
	for _, tc := range []struct {
		name string
		line string
		exec bool
		code string
	}{
		{"extra key", `{"id":1,"verb":"proc.list","x":1}`, true, "bad_request"},
		{"unknown verb", `{"id":1,"verb":"nope"}`, true, "unknown_verb"},
		{"bad path", `{"id":1,"verb":"fs.read","path":".."}`, true, "path_rejected"},
		{"absent file", `{"id":1,"verb":"fs.read","path":"NOPE"}`, true, "not_found"},
		{"absent pid", `{"id":1,"verb":"proc.get","pid":4000}`, true, "not_found"},
		{"big read", `{"id":1,"verb":"fs.read","path":"BIG.BIN"}`, true, "too_large"},
		{"bad cmd", `{"id":1,"verb":"gosh.run","cmd":"a > X"}`, true, "cmd_rejected"},
		{"disabled", `{"id":1,"verb":"gosh.run","cmd":"ls"}`, false, "verb_disabled"},
	} {
		v, _ := parseLine([]byte(tc.line))
		req, vc := validateRequest(v)
		var res, code string
		if vc != "" {
			code = vc
		} else {
			res, code = dispatch(req, tc.exec)
		}
		_ = res
		if code != tc.code {
			t.Fatalf("%s: code = %q want %q", tc.name, code, tc.code)
		}
	}
}
