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
	prevLane, prevAList, prevTime := lane, auditListFn, timeFn
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
		func() { scanoutFn = scanoutSave },
		func() { agentInputKeyFn = agentKeySave },
		func() { agentInputPtrFn = agentPtrSave },
		func() { agentWindow = -1 },
		func() { secretGetFn = secretSave },
		func() { principalFn = principalSave },
		func() { randomFn = randomSave },
		func() { argsFn = argsSave },
		func() { consoleFn = consoleSave },
		func() { sleepFn = sleepSave },
		func() { exitFn = exitSave },
		func() { lane = prevLane },
		func() { auditListFn = prevAList },
		func() { timeFn = prevTime },
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
	scanoutSave   = scanoutFn
	agentKeySave  = agentInputKeyFn
	agentPtrSave  = agentInputPtrFn
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
	procs     []vi.ProcRow
	files     map[string][]byte
	dirs      map[string][]vi.DirEntry
	fileErr   map[string]int64
	writeErr  int64
	spawnErr  error
	spawnPID  int64
	waitErr   error
	waitSt    int64
	seatPid   int64
	winID     int
	winErr    int64
	winW      uint32
	winH      uint32
	hidden    bool
	wmRows    []vi.WmWindowRow
	wmErr     error
	scanout   func(x, y, w, h uint32, buf []byte) int64
	scanoutRc int64
	outBody   []byte // what the spawned GOSH "wrote" to AGENTD.OUT
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
	scanoutFn = func(x, y, w, h uint32, buf []byte) int64 {
		if k.scanout != nil {
			return k.scanout(x, y, w, h, buf)
		}
		if k.scanoutRc != 0 {
			return k.scanoutRc
		}
		return int64(len(buf))
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

// capsOf builds a session cap set from words.
func capsOf(words ...string) map[string]bool {
	m := map[string]bool{}
	for _, w := range words {
		m[w] = true
	}
	return m
}

// testSess is the dispatch-level fixture session: caps as given, allowExec
// as asked, chunks emitted captured into chunks when non-nil.
func testSess(allowExec bool, chunks *[][]byte, caps ...string) *sessionCtx {
	s := &sessionCtx{caps: capsOf(caps...), allowExec: allowExec}
	if chunks != nil {
		s.emit = func(b []byte) {
			*chunks = append(*chunks, append([]byte(nil), b...))
		}
	}
	return s
}

var allCaps = []string{"file", "process", "window", "term", "input"}

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
	// Every path_rejected shape in the gate matrix — traversal,
	// separators outside the depth grammar, the reserved audit lane,
	// bad bytes, over-bound length and depth.
	for _, p := range []string{
		"../SECRETS.TXT", "/host/SECRETS.TXT", "SUB/../X", ".", "..", "",
		strings.Repeat("x", 49), "X~", "A\x00B", "AUDIT/R1", "audit/x",
		"SUB//X", "SUB/", "/SUB", "A/B/C/D/E", "X" + strings.Repeat("y", 31),
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
	// A legal depth-2 name that does not exist is not_found, and one that
	// does resolves through its parent directory.
	k.files["/host/AGENT/SUB/DEEP.TXT"] = []byte("deep")
	k.dirs["/host/AGENT/SUB"] = []vi.DirEntry{dirEnt("DEEP.TXT", false)}
	if _, code = verbFSRead(mustReq(t, `{"id":1,"verb":"fs.read","path":"SUB/NOPE.TXT"}`)); code != "not_found" {
		t.Fatalf("nested ENOENT code = %q", code)
	}
	res, code = verbFSRead(mustReq(t, `{"id":1,"verb":"fs.read","path":"SUB/DEEP.TXT"}`))
	if code != "" || res != `{"path":"SUB/DEEP.TXT","size":4,"data_b64":"ZGVlcA=="}` {
		t.Fatalf("nested read = %q code %q", res, code)
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
		`{"id":1,"verb":"gosh.run","cmd":"echo hi"}`), testSess(false, nil, "term")); code != "verb_disabled" {
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
		if _, code := dispatch(mustReq(t, tc.line), testSess(true, nil, allCaps...)); code != tc.code {
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

	var chunks [][]byte
	res, code := verbGoshRun(mustReq(t,
		`{"id":1,"verb":"gosh.run","cmd":"echo hello"}`), testSess(true, &chunks, "term"))
	if code != "" {
		t.Fatal(code)
	}
	want := `{"exit_status":0,"stdout_bytes":6,"truncated":false}`
	if res != want {
		t.Fatalf("gosh.run = %q want %q", res, want)
	}
	if len(chunks) != 1 || string(chunks[0]) != "hello\n" {
		t.Fatalf("stream chunks = %v", chunks)
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
		`{"id":1,"verb":"gosh.run","cmd":"echo hi"}`), testSess(true, nil, "term")); code != "spawn_failed" {
		t.Fatalf("spawn error code = %q", code)
	}
	k.spawnErr = nil

	// A budget that expires kills the child, confirms through Probe, and
	// answers timed_out — with the reap marker the gate asserts.
	logs = nil
	k.waitErr = vi.ErrWaitGone
	if _, code = verbGoshRun(mustReq(t,
		`{"id":1,"verb":"gosh.run","cmd":"sleep 5","timeout_ms":1000}`), testSess(true, nil, "term")); code != "timed_out" {
		t.Fatalf("timeout code = %q", code)
	}
	if k.killed != 42 {
		t.Fatalf("killed pid = %d want 42", k.killed)
	}
	if !hasLine(logs, "agentd: reap pid=42") {
		t.Fatalf("timed-out markers = %v", logs)
	}
	k.waitErr = nil

	// Truncated output: outMax+1 bytes in the capture → truncated flag and
	// exactly outMax bytes streamed, in order, in bounded chunks.
	k.outBody = make([]byte, outMax+1)
	for i := range k.outBody {
		k.outBody[i] = byte(i % 251)
	}
	chunks = nil
	res, code = verbGoshRun(mustReq(t,
		`{"id":1,"verb":"gosh.run","cmd":"echo hi"}`), testSess(true, &chunks, "term"))
	if code != "" || !strings.Contains(res, `"truncated":true`) ||
		!strings.Contains(res, `"stdout_bytes":16384`) {
		t.Fatalf("truncated = %q code %q", res, code)
	}
	var merged []byte
	for i, c := range chunks {
		if i < len(chunks)-1 && len(c) != streamChunk {
			t.Fatalf("chunk %d = %d bytes, want %d", i, len(c), streamChunk)
		}
		merged = append(merged, c...)
	}
	if len(merged) != outMax || merged[100] != k.outBody[100] || merged[outMax-1] != k.outBody[outMax-1] {
		t.Fatalf("streamed %d bytes, content drifted", len(merged))
	}

	// A nonzero child status is still ok:true — the command ran.
	k.outBody = nil
	k.waitSt = 3
	res, code = verbGoshRun(mustReq(t,
		`{"id":1,"verb":"gosh.run","cmd":"cat NOPE.TXT"}`), testSess(true, nil, "term"))
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
		`{"id":1,"verb":"gosh.run","cmd":"echo hi"}`), testSess(true, nil, "term")); code != "" {
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
		`{"id":1,"verb":"gosh.run","cmd":"echo hi"}`), testSess(true, nil, "term")); code != "spawn_failed" {
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

// --- ui.input ------------------------------------------------------------------

// inputSpy captures the events the verb pushes through the kind-29
// client seams and scripts each ack.
type inputSpy struct {
	keys []struct {
		win         uint32
		mods, usage uint8
	}
	ptrs []struct {
		win     uint32
		buttons uint8
		x, y    uint16
	}
	refuse string // ack title on applied=0
	bare   bool   // applied=0 with NO refusal name (legacy seat)
	silent bool   // never answer
}

func (s *inputSpy) install() {
	agentInputKeyFn = func(win uint32, mods, usage uint8, self string) (vi.WmRpc, bool) {
		s.keys = append(s.keys, struct {
			win         uint32
			mods, usage uint8
		}{win, mods, usage})
		if s.silent {
			return vi.WmRpc{}, false
		}
		var rep vi.WmRpc
		if s.refuse != "" {
			copy(rep.Title[:], s.refuse)
		} else if !s.bare {
			rep.Applied = 1
		}
		return rep, true
	}
	agentInputPtrFn = func(win uint32, buttons uint8, x, y uint16, self string) (vi.WmRpc, bool) {
		s.ptrs = append(s.ptrs, struct {
			win     uint32
			buttons uint8
			x, y    uint16
		}{win, buttons, x, y})
		if s.silent {
			return vi.WmRpc{}, false
		}
		var rep vi.WmRpc
		if s.refuse != "" {
			copy(rep.Title[:], s.refuse)
		} else if !s.bare {
			rep.Applied = 1
		}
		return rep, true
	}
}

func TestUIInput(t *testing.T) {
	seamScope(t)
	spy := &inputSpy{}
	k := &fakeKernel{
		seatPid: 3,
		wmRows: []vi.WmWindowRow{
			{Index: 0, ID: 100, Title: "Edit", Focused: true},
			{Index: 1, ID: 101, Title: "Notes"},
		},
	}
	k.install()
	spy.install()

	// The green path: a key press and a pointer sample ride their own
	// frames against the daemon's bound window.
	res, code := verbUIInput(mustReq(t,
		`{"id":1,"verb":"ui.input","win":0,"events":[`+
			`{"type":"key","usage":11,"mods":1},`+
			`{"type":"ptr","x":300,"y":200,"buttons":1}]}`))
	if code != "" || res != `{"sent":2}` {
		t.Fatalf("ui.input = %q code %q", res, code)
	}
	if len(spy.keys) != 1 || spy.keys[0].win != 7 ||
		spy.keys[0].usage != 11 || spy.keys[0].mods != 1 {
		t.Fatalf("key event = %+v", spy.keys)
	}
	if len(spy.ptrs) != 1 || spy.ptrs[0].win != 7 ||
		spy.ptrs[0].buttons != 1 || spy.ptrs[0].x != 300 || spy.ptrs[0].y != 200 {
		t.Fatalf("ptr event = %+v", spy.ptrs)
	}

	// win names the FOCUSED strip index — anything else is the seat's
	// own refusal name, by name.
	for _, line := range []string{
		`{"id":1,"verb":"ui.input","win":1,"events":[{"type":"key","usage":4}]}`,
		`{"id":1,"verb":"ui.input","win":9,"events":[{"type":"key","usage":4}]}`,
	} {
		if _, code = verbUIInput(mustReq(t, line)); code != vi.AgentInputNoFocus {
			t.Fatalf("%s: code = %q want %q", line, code, vi.AgentInputNoFocus)
		}
	}
	if len(spy.keys) != 1 {
		t.Fatal("a non-focused win still pushed events")
	}
	k.wmRows = []vi.WmWindowRow{{Index: 0, ID: 100, Title: "Edit"}}
	if _, code = verbUIInput(mustReq(t,
		`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"key","usage":4}]}`)); code != vi.AgentInputNoFocus {
		t.Fatalf("empty focus code = %q", code)
	}
	k.wmRows = []vi.WmWindowRow{
		{Index: 0, ID: 100, Title: "Edit", Focused: true},
		{Index: 1, ID: 101, Title: "Notes"},
	}

	// Refuse before touching: the bound and every malformed shape fail
	// BEFORE the first frame — the spy count never moves.
	spy.keys, spy.ptrs = nil, nil
	var over strings.Builder
	over.WriteString(`{"id":1,"verb":"ui.input","win":0,"events":[`)
	for i := 0; i <= inputEventsMax; i++ {
		if i > 0 {
			over.WriteByte(',')
		}
		over.WriteString(`{"type":"key","usage":4}`)
	}
	over.WriteString(`]}`)
	for _, tc := range []struct{ line, want string }{
		{over.String(), "too_large"},
		{`{"id":1,"verb":"ui.input","win":0}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","win":0,"events":"x"}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","win":0,"events":[4]}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","win":0,"events":[{}]}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"key"}]}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"key","usage":256}]}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"key","usage":4,"x":1}]}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"key","usage":4,"bogus":1}]}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"ptr","x":1}]}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"ptr","x":1,"y":2,"usage":4}]}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"ptr","x":65536,"y":0}]}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"wheel"}]}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"key","usage":4},{"bogus":1}]}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","win":"0","events":[]}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","events":[]}`, "bad_request"},
		{`{"id":1,"verb":"ui.input","win":0,"events":[],"extra":1}`, "bad_request"},
	} {
		if _, code = dispatch(mustReq(t, tc.line), testSess(true, nil, allCaps...)); code != tc.want {
			t.Fatalf("%s: code = %q want %q", tc.line, code, tc.want)
		}
		if len(spy.keys)+len(spy.ptrs) != 0 {
			t.Fatalf("%s pushed events before refusing", tc.line)
		}
	}

	// 64 events exactly is inside the bound — all sent, all applied.
	spy.keys, spy.ptrs = nil, nil
	var exact strings.Builder
	exact.WriteString(`{"id":1,"verb":"ui.input","win":0,"events":[`)
	for i := 0; i < inputEventsMax; i++ {
		if i > 0 {
			exact.WriteByte(',')
		}
		exact.WriteString(`{"type":"key","usage":4}`)
	}
	exact.WriteString(`]}`)
	res, code = verbUIInput(mustReq(t, exact.String()))
	if code != "" || res != `{"sent":64}` || len(spy.keys) != 64 {
		t.Fatalf("64-event batch = %q code %q sent %d", res, code, len(spy.keys))
	}

	// The seat's refusal names surface verbatim; a bare applied=0 with
	// no name is a legacy seat = seat_unsupported.
	for _, tc := range []struct{ refuse, want string }{
		{vi.AgentInputDenied, vi.AgentInputDenied},
		{vi.AgentInputNoFocus, vi.AgentInputNoFocus},
		{"unknown_name", "seat_unsupported"},
	} {
		spy.refuse = tc.refuse
		if _, code = verbUIInput(mustReq(t,
			`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"key","usage":4}]}`)); code != tc.want {
			t.Fatalf("refuse %q: code = %q want %q", tc.refuse, code, tc.want)
		}
	}
	spy.refuse = ""
	spy.bare = true // a bare applied=0 ack: the legacy seat's only answer
	if _, code = verbUIInput(mustReq(t,
		`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"key","usage":4}]}`)); code != "seat_unsupported" {
		t.Fatalf("bare refusal code = %q", code)
	}
	spy.bare = false

	// A silent seat is seat_timeout; no seat is seat_absent.
	spy.silent = true
	if _, code = verbUIInput(mustReq(t,
		`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"key","usage":4}]}`)); code != "seat_timeout" {
		t.Fatalf("silent code = %q", code)
	}
	spy.silent = false
	k.seatPid = 0
	spy.keys = nil
	if _, code = verbUIInput(mustReq(t,
		`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"key","usage":4}]}`)); code != "seat_absent" {
		t.Fatalf("no-seat code = %q", code)
	}
	if len(spy.keys) != 0 {
		t.Fatal("seat_absent pushed events")
	}
	k.seatPid = 3
	k.wmErr = vi.ErrSeatUnsupported
	if _, code = verbUIInput(mustReq(t,
		`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"key","usage":4}]}`)); code != "seat_unsupported" {
		t.Fatalf("zig-seat code = %q", code)
	}
	k.wmErr = vi.ErrSeatSilent
	if _, code = verbUIInput(mustReq(t,
		`{"id":1,"verb":"ui.input","win":0,"events":[{"type":"key","usage":4}]}`)); code != "seat_timeout" {
		t.Fatalf("silent-strip code = %q", code)
	}
	k.wmErr = nil
}

// The missing-scope refusal: cap_required:input, before the request
// touches a seam, and it is the INPUT cap — window alone is not enough.
func TestUIInputScope(t *testing.T) {
	seamScope(t)
	spy := &inputSpy{}
	k := &fakeKernel{seatPid: 3,
		wmRows: []vi.WmWindowRow{{Index: 0, ID: 100, Focused: true}}}
	k.install()
	spy.install()
	line := `{"id":1,"verb":"ui.input","win":0,"events":[{"type":"key","usage":4}]}`
	for _, caps := range [][]string{{}, {"window"}, {"file", "process", "term"}} {
		_, code := dispatch(mustReq(t, line), testSess(true, nil, caps...))
		if code != "cap_required:input" {
			t.Fatalf("caps %v: code = %q want cap_required:input", caps, code)
		}
	}
	if len(spy.keys)+len(spy.ptrs) != 0 {
		t.Fatal("cap_required pushed events")
	}
	// The event bytes never land in the receipt — win and the count do.
	req := mustReq(t, line)
	args := auditArgs(req, `{"sent":1}`, "")
	if !strings.Contains(args, `"win":0`) || !strings.Contains(args, `"events":1`) {
		t.Fatalf("audit args = %q", args)
	}
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
			res, code = dispatch(req, testSess(tc.exec, nil, allCaps...))
		}
		_ = res
		if code != tc.code {
			t.Fatalf("%s: code = %q want %q", tc.name, code, tc.code)
		}
	}
}

// --- path depth ------------------------------------------------------------

func TestValidPathTable(t *testing.T) {
	accept := []string{
		"SEED.TXT", "seed.txt", "SUB/DEEP.TXT", "A/B/C/D.TXT",
		"12345678901/12345678901/12345678901/1234567890",
	}
	for _, s := range accept {
		if !validPath(s) {
			t.Fatalf("validPath(%q) = false", s)
		}
	}
	refuse := []string{
		"", "A/B/C/D/E", strings.Repeat("x", 49), "AUDIT/X", "audit/f.txt",
		"SUB//X", "SUB/", "/SUB", "SUB/../X", "SUB/.", "SUB/..",
		"SUB/" + strings.Repeat("y", 32),
	}
	for _, s := range refuse {
		if validPath(s) {
			t.Fatalf("validPath(%q) = true", s)
		}
	}
	if p, l := parentOf("A/B/C.TXT"); p != "A/B" || l != "C.TXT" {
		t.Fatalf("parentOf = %q %q", p, l)
	}
	if p, l := parentOf("F.TXT"); p != "" || l != "F.TXT" {
		t.Fatalf("parentOf flat = %q %q", p, l)
	}
}

// --- the cap gate -------------------------------------------------------------

// Every verb is behind its declared cap (ADR 0052 D3): a missing cap is
// cap_required:<cap> before any argument check or syscall, and granting
// the cap lets the request through to its own validation.
func TestCapGate(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{
		procs:   []vi.ProcRow{proc(9, vi.ProcRunning, 0, "AGENTD.ELF")},
		files:   map[string][]byte{"/host/AGENT/F.TXT": []byte("x")},
		dirs:    map[string][]vi.DirEntry{sandboxDir: {dirEnt("F.TXT", false)}},
		seatPid: 3,
	}
	k.install()
	for _, tc := range []struct {
		line string
		cap  string
	}{
		{`{"id":1,"verb":"proc.list"}`, "process"},
		{`{"id":1,"verb":"proc.get","pid":9}`, "process"},
		{`{"id":1,"verb":"fs.read","path":"F.TXT"}`, "file"},
		{`{"id":1,"verb":"fs.write","path":"F.TXT","data_b64":"eA=="}`, "file"},
		{`{"id":1,"verb":"ui.windows"}`, "window"},
		{`{"id":1,"verb":"ui.screenshot"}`, "window"},
		{`{"id":1,"verb":"ui.input","win":0,"events":[]}`, "input"},
		{`{"id":1,"verb":"gosh.run","cmd":"echo hi"}`, "term"},
	} {
		// Missing cap refuses by name — even with well-formed args.
		sess := testSess(true, nil) // no caps at all
		_, code := dispatch(mustReq(t, tc.line), sess)
		if code != "cap_required:"+tc.cap {
			t.Fatalf("%s missing cap = %q want cap_required:%s", tc.line, code, tc.cap)
		}
		// Every OTHER cap held still refuses — the gate is the declared
		// cap, not any cap.
		var others []string
		for _, c := range allCaps {
			if c != tc.cap {
				others = append(others, c)
			}
		}
		_, code = dispatch(mustReq(t, tc.line), testSess(true, nil, others...))
		if code != "cap_required:"+tc.cap {
			t.Fatalf("%s other caps = %q want cap_required:%s", tc.line, code, tc.cap)
		}
		// Held cap: the request reaches its own path (not cap_required).
		_, code = dispatch(mustReq(t, tc.line), testSess(true, nil, allCaps...))
		if code == "cap_required:"+tc.cap {
			t.Fatalf("%s held cap still refused", tc.line)
		}
	}
	// An unknown verb is unknown_verb regardless of caps — the cap table
	// only names verbs that exist.
	_, code := dispatch(mustReq(t, `{"id":1,"verb":"nope"}`), testSess(true, nil))
	if code != "unknown_verb" {
		t.Fatalf("unknown verb with no caps = %q", code)
	}
}

// --- ui.screenshot -----------------------------------------------------------

func TestUIScreenshot(t *testing.T) {
	seamScope(t)
	k := &fakeKernel{seatPid: 0}
	k.install()
	sess := testSess(true, nil, "window")
	bare := mustReq(t, `{"id":1,"verb":"ui.screenshot"}`)

	// No seat is the card's named refusal, before any scanout call.
	if _, code := verbUIScreenshot(bare, sess); code != "seat_absent" {
		t.Fatalf("no-seat code = %q", code)
	}
	k.seatPid = 3
	// An unarmed framebuffer is the same verdict (nothing to see).
	k.scanoutRc = -vi.ErrENXIO
	if _, code := verbUIScreenshot(bare, sess); code != "seat_absent" {
		t.Fatalf("ENXIO code = %q", code)
	}
	k.scanoutRc = -vi.ErrENOSYS
	if _, code := verbUIScreenshot(bare, sess); code != "seat_unsupported" {
		t.Fatalf("ENOSYS code = %q", code)
	}
	k.scanoutRc = -vi.ErrENOMEM
	if _, code := verbUIScreenshot(bare, sess); code != "io_error:ENOMEM" {
		t.Fatalf("ENOMEM code = %q", code)
	}
	// A live seat: paint pixel (sx,sy) = (B,G,R) by source coords and
	// check the RGB565 conversion plus the chunk shape.
	k.scanout = func(x, y, w, h uint32, buf []byte) int64 {
		if x != 0 || w != uint32(vi.ScanoutWidth) || h != 1 {
			t.Fatalf("band = x%d y%d w%d h%d", x, y, w, h)
		}
		for px := uint32(0); px < w; px++ {
			buf[px*4] = byte(y % 256)    // B <- source row
			buf[px*4+1] = byte(px % 256) // G <- source col
			buf[px*4+2] = 0xf8           // R saturated -> r5 = 31
			buf[px*4+3] = 0
		}
		return int64(len(buf))
	}
	var chunks [][]byte
	sess.emit = func(b []byte) { chunks = append(chunks, append([]byte(nil), b...)) }
	res, code := verbUIScreenshot(bare, sess)
	want := `{"w":160,"h":90,"format":"rgb565le","bytes":28800}`
	if code != "" || res != want {
		t.Fatalf("ui.screenshot = %q code %q", res, code)
	}
	var merged []byte
	for _, c := range chunks {
		if len(c) > streamChunk {
			t.Fatalf("chunk %d bytes over bound", len(c))
		}
		merged = append(merged, c...)
	}
	if len(merged) != thumbW*thumbH*2 {
		t.Fatalf("streamed %d bytes want %d", len(merged), thumbW*thumbH*2)
	}
	// Output pixel (tx=1, ty=0) samples source (8, 0): B=0, G=8, R=0xf8.
	got := uint16(merged[2]) | uint16(merged[3])<<8
	want16 := uint16(0xf8>>3)<<11 | uint16(8>>2)<<5 | uint16(0>>3)
	if got != want16 {
		t.Fatalf("pixel (1,0) = %04x want %04x", got, want16)
	}
	// scale=8 names the same default thumbnail path.
	res, code = verbUIScreenshot(mustReq(t,
		`{"id":1,"verb":"ui.screenshot","scale":8}`), sess)
	if code != "" || res != want {
		t.Fatalf("scale=8 = %q code %q", res, code)
	}
}

// TestUIScreenshotFull covers card #2977's scale=1: the 12-row slot-88
// band plan, the shared RGB565 conversion, the scale refusals, and the
// per-session rate bound.
func TestUIScreenshotFull(t *testing.T) {
	seamScope(t)
	nanosSave := nanosFn
	t.Cleanup(func() { nanosFn = nanosSave })
	var clock int64 = 1e9
	nanosFn = func() int64 { return clock }
	k := &fakeKernel{seatPid: 3}
	k.install()
	var bands int
	var expectY uint32 // the next scale=1 band's y — wraps per capture
	k.scanout = func(x, y, w, h uint32, buf []byte) int64 {
		// Band planning: full-width reads under the slot's per-call
		// byte bound; scale=1 takes 12-row bands marching the frame in
		// order, the thumbnail path takes its single sampled rows.
		if x != 0 || w != uint32(vi.ScanoutWidth) || (h != 1 && h != fullShotRows) {
			t.Fatalf("band = x%d y%d w%d h%d", x, y, w, h)
		}
		if int64(len(buf)) > vi.ScanoutReadMax {
			t.Fatalf("band buf = %d over %d", len(buf), vi.ScanoutReadMax)
		}
		if h == fullShotRows {
			if y != expectY {
				t.Fatalf("band read y=%d want %d", y, expectY)
			}
			expectY = (y + fullShotRows) % uint32(vi.ScanoutHeight)
			bands++
		}
		for row := uint32(0); row < h; row++ {
			for col := uint32(0); col < w; col++ {
				i := (row*w + col) * 4
				buf[i] = byte((y + row) % 256)            // B <- source row
				buf[i+1] = byte(col % 256)                // G <- source col
				buf[i+2] = byte((col/256 + y + row) % 64) // R varies slowly
				buf[i+3] = 0
			}
		}
		return int64(len(buf))
	}
	var chunks [][]byte
	sess := testSess(true, &chunks, "window")
	full := mustReq(t, `{"id":1,"verb":"ui.screenshot","scale":1}`)

	res, code := verbUIScreenshot(full, sess)
	want := `{"w":1280,"h":720,"format":"rgb565le","bytes":1843200}`
	if code != "" || res != want {
		t.Fatalf("scale=1 = %q code %q", res, code)
	}
	if bands != vi.ScanoutHeight/fullShotRows {
		t.Fatalf("bands = %d want %d", bands, vi.ScanoutHeight/fullShotRows)
	}
	var merged []byte
	for _, c := range chunks {
		if len(c) > streamChunk {
			t.Fatalf("chunk %d bytes over bound", len(c))
		}
		merged = append(merged, c...)
	}
	if len(merged) != vi.ScanoutWidth*vi.ScanoutHeight*2 {
		t.Fatalf("streamed %d bytes want %d", len(merged), vi.ScanoutWidth*vi.ScanoutHeight*2)
	}
	// Source pixel (300, 17): B = 17, G = 44, R = (1+17)%64 = 18.
	off := (17*vi.ScanoutWidth + 300) * 2
	got := uint16(merged[off]) | uint16(merged[off+1])<<8
	want16 := uint16(18>>3)<<11 | uint16(44>>2)<<5 | uint16(17>>3)
	if got != want16 {
		t.Fatalf("pixel (300,17) = %04x want %04x", got, want16)
	}

	// The full frame downsamples to the thumbnail path's answer: output
	// (tx,ty) at scale 8 samples source (tx*8, ty*8) — the same pixel,
	// so the two RGB565 streams agree exactly.
	chunks = nil
	res, code = verbUIScreenshot(mustReq(t, `{"id":2,"verb":"ui.screenshot"}`), sess)
	if code != "" {
		t.Fatalf("thumbnail after scale=1 code = %q", code)
	}
	var thumb []byte
	for _, c := range chunks {
		thumb = append(thumb, c...)
	}
	stride := vi.ScanoutWidth / thumbW
	for ty := 0; ty < thumbH; ty++ {
		for tx := 0; tx < thumbW; tx++ {
			sx, sy := tx*stride, ty*(vi.ScanoutHeight/thumbH)
			fo := (sy*vi.ScanoutWidth + sx) * 2
			to := (ty*thumbW + tx) * 2
			if merged[fo] != thumb[to] || merged[fo+1] != thumb[to+1] {
				t.Fatalf("downsample drift at (%d,%d)", tx, ty)
			}
		}
	}

	// The rate bound: a second scale=1 inside 2 s refuses by name with
	// no scanout call; the bound lapses and the next capture runs.
	bands = 0
	if _, code = verbUIScreenshot(full, sess); code != "rate_limited" {
		t.Fatalf("inside-bound code = %q", code)
	}
	if bands != 0 {
		t.Fatal("rate_limited still read the scanout")
	}
	// A refused request consumed no further budget: the bound still
	// lapses on the original clock, and thumbnails are never bound.
	clock += fullShotMinNs - 1
	if _, code = verbUIScreenshot(full, sess); code != "rate_limited" {
		t.Fatalf("bound-edge-1 code = %q", code)
	}
	clock++
	res, code = verbUIScreenshot(full, sess)
	if code != "" || res != want {
		t.Fatalf("post-bound scale=1 = %q code %q", res, code)
	}

	// The scale refusals: other values are bad_request, before any
	// scanout call, and refuse without arming a fresh session's bound.
	for _, line := range []string{
		`{"id":3,"verb":"ui.screenshot","scale":0}`,
		`{"id":3,"verb":"ui.screenshot","scale":2}`,
		`{"id":3,"verb":"ui.screenshot","scale":4}`,
		`{"id":3,"verb":"ui.screenshot","scale":"1"}`,
		`{"id":3,"verb":"ui.screenshot","bogus":1}`,
	} {
		if _, code = dispatch(mustReq(t, line), sess); code != "bad_request" {
			t.Fatalf("%s: code = %q want bad_request", line, code)
		}
	}
	fresh := testSess(true, nil, "window")
	bands = 0
	for _, line := range []string{
		`{"id":4,"verb":"ui.screenshot","scale":4}`,
		`{"id":4,"verb":"ui.screenshot","scale":0}`,
	} {
		if _, code = dispatch(mustReq(t, line), fresh); code != "bad_request" {
			t.Fatalf("fresh %s: code = %q", line, code)
		}
	}
	if _, code = verbUIScreenshot(full, fresh); code != "" {
		t.Fatalf("scale=1 after refused scales code = %q", code)
	}
	if bands == 0 {
		t.Fatal("scale=1 never read the scanout")
	}

	// A no-seat refusal consumes no budget either: seat_absent on a
	// fresh session, then the first scale=1 succeeds right away.
	k.seatPid = 0
	fresh2 := testSess(true, nil, "window")
	if _, code = verbUIScreenshot(full, fresh2); code != "seat_absent" {
		t.Fatalf("no-seat scale=1 code = %q", code)
	}
	k.seatPid = 3
	if _, code = verbUIScreenshot(full, fresh2); code != "" {
		t.Fatalf("scale=1 after seat_absent code = %q", code)
	}
}
