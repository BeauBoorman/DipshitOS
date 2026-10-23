package main

import (
	"strings"
	"testing"
	"unsafe"

	"virelai/shlib"
	"virelai/vi"
)

// fakeKernel is the in-memory kernel the host tests run goshHost (and the
// shlib engine stacked on it) against. It answers the svc/svc6 gateway
// slots the seam's vi calls marshal to — a path-keyed file table, a pipe
// buffer, a process registry — so a host test can watch what GOSH SENDS
// and returns, not just stub the Go boundary. It is intentionally not a
// file model of the kernel: only the ops the shell seam issues.
type fakeKernel struct {
	files   map[string][]byte
	dirs    map[string]bool
	handles map[uint32]*fakeHandle
	nextH   uint32

	ttyH        uint32 // the reserved /dev/tty handle
	ttyIn       []byte // bytes the next tty FileRead returns
	out         []byte // bytes FileWrite delivered to the tty
	ttySizes    []int  // per-call tty write sizes
	ttyErrAfter int    // fail the Nth tty write (-EIO); 0 = never
	ttyWrites   int

	pipe    []byte
	procs   []vi.ProcRow
	secrets []vi.SecretRecord

	openErr  map[string]int64 // per-path FileOpen refusal
	dirErr   map[string]int64 // per-path DirList refusal
	writeErr int64            // FileWrite refusal for non-tty handles
	delErr   int64            // FileDelete refusal
	killRc   int64
	modeRc   int64
	secretRc int64
	vsock    func(verb, name string, code []byte) int64
	exited   int64       // last SlotExit status
	onExit   func(int64) // SlotExit observer; may panic to escape vi.Exit's park
}

type fakeHandle struct {
	path   string
	pos    int
	append bool
	tty    bool
}

func newFakeKernel(t *testing.T) *fakeKernel {
	t.Helper()
	k := &fakeKernel{
		files:   map[string][]byte{},
		dirs:    map[string]bool{"/host": true, vi.AppLogDir: true, vi.CrashReceiptDir: true},
		handles: map[uint32]*fakeHandle{},
		nextH:   1,
		openErr: map[string]int64{},
		dirErr:  map[string]int64{},
		pipe:    make([]byte, 0, shlib.MaxPipeBytes*2),
	}
	stackStretch(4096)
	k.ttyH = k.addHandle(&fakeHandle{tty: true})
	prev4 := vi.SetSyscallHookForTest(k.svc)
	prev6 := vi.SetSyscallHook6ForTest(k.svc6)
	t.Cleanup(func() {
		vi.SetSyscallHookForTest(prev4)
		vi.SetSyscallHook6ForTest(prev6)
	})
	return k
}

func (k *fakeKernel) addHandle(h *fakeHandle) uint32 {
	k.nextH++
	k.handles[k.nextH] = h
	return k.nextH
}

func hostBytes(ptr, n uintptr) []byte {
	if n == 0 {
		return nil
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(ptr)), int(n))
}

func hostString(ptr, n uintptr) string { return string(hostBytes(ptr, n)) }

func le64(b []byte, v uint64) {
	for i := 0; i < 8; i++ {
		b[i] = byte(v >> (8 * i))
	}
}

func le32put(b []byte, v uint32) {
	for i := 0; i < 4; i++ {
		b[i] = byte(v >> (8 * i))
	}
}

func (k *fakeKernel) svc(num, a0, a1, a2, a3 uintptr) int64 {
	switch num {
	case vi.SlotFileOpen:
		return k.open(hostString(a0, a1), uint32(a2))
	case vi.SlotFileRead:
		return k.read(uint32(a0), a1, a2)
	case vi.SlotFileWrite:
		return k.write(uint32(a0), a1, a2)
	case vi.SlotFileClose:
		delete(k.handles, uint32(a0))
		return 0
	case vi.SlotFileDelete:
		if k.delErr != 0 {
			return k.delErr
		}
		if _, ok := k.files[hostString(a0, a1)]; !ok {
			return -vi.ErrENOENT
		}
		delete(k.files, hostString(a0, a1))
		return 0
	case vi.SlotFileRename:
		old, nw := hostString(a0, a1), hostString(a2, a3)
		if _, ok := k.files[old]; !ok {
			return -vi.ErrENOENT
		}
		if _, ok := k.files[nw]; ok {
			return vi.ErrFileExists // the HF rename is no-overwrite
		}
		k.files[nw] = k.files[old]
		delete(k.files, old)
		return 0
	case vi.SlotFileSync:
		return 0
	case vi.SlotDirList:
		return k.dirList(hostString(a0, a1), a2, a3)
	case vi.SlotProcs:
		return k.procRows(a0, a1)
	case vi.SlotPipeWrite:
		b := hostBytes(a0, a1)
		k.pipe = append(k.pipe, b...)
		return int64(len(b))
	case vi.SlotPipeRead:
		n := copy(hostBytes(a0, a1), k.pipe)
		k.pipe = k.pipe[n:]
		return int64(n)
	case vi.SlotKill:
		return k.killRc
	case vi.SlotFileMode:
		return k.modeRc
	case vi.SlotSecretGet:
		return k.secretRows(a0, a1)
	case vi.SlotPrincipal:
		b := hostBytes(a0, vi.PrincipalBytes)
		le32put(b, 501)
		le32put(b[4:], 0xff)
		return vi.PrincipalBytes
	case vi.SlotExit:
		k.exited = int64(a0)
		if k.onExit != nil {
			k.onExit(k.exited)
		}
		return 0
	}
	return -vi.ErrENOSYS
}

func (k *fakeKernel) svc6(num, a0, a1, a2, a3, a4, a5 uintptr) int64 {
	if num == vi.SlotVsockCtl && k.vsock != nil {
		return k.vsock(hostString(a0, a1), hostString(a2, a3), hostBytes(a4, a5))
	}
	return -vi.ErrENOSYS
}

func (k *fakeKernel) open(path string, flags uint32) int64 {
	if rc, ok := k.openErr[path]; ok {
		return rc
	}
	if flags&vi.ModeDir != 0 {
		if k.dirs[path] {
			return vi.ErrFileExists
		}
		k.dirs[path] = true
		return int64(k.addHandle(&fakeHandle{path: path}))
	}
	body, ok := k.files[path]
	if flags&vi.ModeWrite != 0 {
		if !ok && flags&vi.ModeCreate == 0 {
			return -vi.ErrENOENT
		}
		h := &fakeHandle{path: path}
		if flags&vi.ModeAppend != 0 {
			h.pos, h.append = len(body), true
		} else {
			k.files[path] = nil
		}
		return int64(k.addHandle(h))
	}
	if !ok {
		return -vi.ErrENOENT
	}
	return int64(k.addHandle(&fakeHandle{path: path}))
}

func (k *fakeKernel) read(h uint32, bufPtr, bufLen uintptr) int64 {
	fh, ok := k.handles[h]
	if !ok {
		return -vi.ErrEBADF
	}
	if fh.tty {
		n := copy(hostBytes(bufPtr, bufLen), k.ttyIn)
		k.ttyIn = k.ttyIn[n:]
		return int64(n)
	}
	body := k.files[fh.path]
	if fh.pos >= len(body) {
		return 0
	}
	n := copy(hostBytes(bufPtr, bufLen), body[fh.pos:])
	fh.pos += n
	return int64(n)
}

func (k *fakeKernel) write(h uint32, ptr, n uintptr) int64 {
	fh, ok := k.handles[h]
	if !ok {
		return -vi.ErrEBADF
	}
	b := append([]byte(nil), hostBytes(ptr, n)...)
	if fh.tty {
		k.ttyWrites++
		if k.ttyErrAfter != 0 && k.ttyWrites > k.ttyErrAfter {
			return -vi.ErrEIO
		}
		k.ttySizes = append(k.ttySizes, len(b))
		k.out = append(k.out, b...)
		return int64(len(b))
	}
	if k.writeErr != 0 {
		return k.writeErr
	}
	body := k.files[fh.path]
	if fh.append {
		fh.pos = len(body)
	}
	end := fh.pos + len(b)
	if end > len(body) {
		grown := make([]byte, end)
		copy(grown, body)
		body = grown
	}
	copy(body[fh.pos:], b)
	k.files[fh.path] = body
	fh.pos = end
	return int64(len(b))
}

func (k *fakeKernel) dirList(path string, bufPtr, maxEnt uintptr) int64 {
	if rc, ok := k.dirErr[path]; ok {
		return rc
	}
	if !k.dirs[path] {
		return -vi.ErrENOENT
	}
	dst := unsafe.Slice((*vi.DirEntry)(unsafe.Pointer(bufPtr)), int(maxEnt))
	seen := map[string]bool{}
	n := 0
	put := func(name string, size uint32, isDir bool) {
		if name == "" || seen[name] || n >= len(dst) {
			return
		}
		seen[name] = true
		e := &dst[n]
		copy(e.Name[:], name)
		e.Size = size
		if isDir {
			e.IsDir = 1
		}
		n++
	}
	prefix := path + "/"
	child := func(p string) string {
		if !strings.HasPrefix(p, prefix) {
			return ""
		}
		rest := p[len(prefix):]
		if i := strings.IndexByte(rest, '/'); i >= 0 {
			return rest[:i]
		}
		return rest
	}
	for p, body := range k.files {
		if c := child(p); c != "" {
			put(c, uint32(len(body)), strings.Contains(p[len(prefix):], "/"))
		}
	}
	for d := range k.dirs {
		if c := child(d); c != "" {
			put(c, 0, true)
		}
	}
	return int64(n)
}

func (k *fakeKernel) procRows(bufPtr, bufLen uintptr) int64 {
	dst := hostBytes(bufPtr, bufLen)
	n := 0
	for _, r := range k.procs {
		off := n * vi.ProcRowSize
		if off+vi.ProcRowSize > len(dst) {
			break
		}
		le64(dst[off:], r.PID)
		le64(dst[off+8:], r.State)
		le64(dst[off+16:], r.ExitStatus)
		copy(dst[off+24:off+24+vi.ProcNameBytes], r.NameBuf[:])
		n++
	}
	return int64(n)
}

func (k *fakeKernel) secretRows(bufPtr, bufLen uintptr) int64 {
	if k.secretRc != 0 {
		return k.secretRc
	}
	dst := hostBytes(bufPtr, bufLen)
	n := 0
	for _, r := range k.secrets {
		off := n * vi.SecretEntryBytes
		if off+vi.SecretEntryBytes > len(dst) {
			break
		}
		le32put(dst[off:], r.UID)
		le32put(dst[off+4:], r.KeyLen)
		le32put(dst[off+8:], r.ValLen)
		copy(dst[off+12:], r.Key[:])
		copy(dst[off+12+vi.SecretKeyMax:], r.Val[:])
		n++
	}
	return int64(n * vi.SecretEntryBytes)
}

// ---------------------------------------------------------------------------
// The seam itself: errno folding, tty chunking, the pipe, the registry.
// ---------------------------------------------------------------------------

// TestWriteTTYChunksUnderTheKernelCap: the kernel's file-write stage cap is
// 2048 and writeTTY holds its chunks under ttyWriteMax — a burst of editor
// output or command text must never hand the kernel an over-long write.
func TestWriteTTYChunksUnderTheKernelCap(t *testing.T) {
	k := newFakeKernel(t)
	body := make([]byte, ttyWriteMax*2+17)
	for i := range body {
		body[i] = 'a' + byte(i%26)
	}
	writeTTY(k.ttyH, body)
	if len(k.ttySizes) != 3 || k.ttySizes[0] != ttyWriteMax || k.ttySizes[1] != ttyWriteMax || k.ttySizes[2] != 17 {
		t.Fatalf("tty write sizes = %v", k.ttySizes)
	}
	if string(k.out) != string(body) {
		t.Fatal("tty body did not arrive whole")
	}
}

// TestWriteTTYStopsOnRefusal: a refused write ends the pump — looping on a
// dead tty would spin forever between prompt repaints.
func TestWriteTTYStopsOnRefusal(t *testing.T) {
	k := newFakeKernel(t)
	k.ttyErrAfter = 1
	writeTTY(k.ttyH, make([]byte, ttyWriteMax+10))
	if k.ttyWrites != 2 || len(k.out) != ttyWriteMax {
		t.Fatalf("writes=%d out=%d", k.ttyWrites, len(k.out))
	}
}

// TestGoshHostOutPicksTheTransport: tty hosts write the attached fd;
// headless hosts buffer whole lines for the console sink.
func TestGoshHostOutPicksTheTransport(t *testing.T) {
	k := newFakeKernel(t)
	tty := newGoshHost(k.ttyH, true)
	tty.Out([]byte("via-tty\n"))
	if string(k.out) != "via-tty\n" {
		t.Fatalf("tty out = %q", k.out)
	}

	headless := newGoshHost(0, false)
	var lines []string
	headless.lines.emit = func(s string) { lines = append(lines, s) }
	headless.Out([]byte("a\nb"))
	headless.flushOut()
	if len(lines) != 2 || lines[0] != "a" || lines[1] != "b" {
		t.Fatalf("headless lines = %v", lines)
	}
}

// TestReadFileCarriesTheErrnoName is the M50 contract the trust gates
// assert: EACCES and ENOENT reach the engine by name, not folded into a
// generic "not found".
func TestReadFileCarriesTheErrnoName(t *testing.T) {
	k := newFakeKernel(t)
	k.files["/host/A.TXT"] = []byte("payload")
	h := newGoshHost(k.ttyH, true)

	b, err := h.ReadFile("/host/A.TXT", 64)
	if err != nil || string(b) != "payload" {
		t.Fatalf("ReadFile = %q, %v", b, err)
	}
	if _, err := h.ReadFile("/host/GONE.TXT", 64); err == nil || err.Error() != "ENOENT" {
		t.Fatalf("missing file err = %v", err)
	}
	k.openErr["/host/DENIED.TXT"] = -vi.ErrEACCES
	if _, err := h.ReadFile("/host/DENIED.TXT", 64); err == nil || err.Error() != "EACCES" {
		t.Fatalf("denied file err = %v", err)
	}
}

// TestWriteFileFoldSplit pins the M81e2 seam split: a refused OPEN (path
// problem) is ErrNotFound, a refused WRITE (the disk's problem) is
// ErrWriteFailed — and a replace publishes crash-safe through the `~`
// sibling, so a failure leaves the previous contents, never a torn file.
func TestWriteFileFoldSplit(t *testing.T) {
	k := newFakeKernel(t)
	h := newGoshHost(k.ttyH, true)

	if err := h.WriteFile("/host/N.TXT", []byte("one\n"), false); err != nil {
		t.Fatalf("replace: %v", err)
	}
	if got := string(k.files["/host/N.TXT"]); got != "one\n" {
		t.Fatalf("replace body = %q", got)
	}
	if _, ok := k.files["/host/N.TXT~"]; ok {
		t.Fatal("publish left its ~ temp behind")
	}
	if err := h.WriteFile("/host/N.TXT", []byte("two\n"), true); err != nil {
		t.Fatalf("append: %v", err)
	}
	if got := string(k.files["/host/N.TXT"]); got != "one\ntwo\n" {
		t.Fatalf("append body = %q", got)
	}

	k.openErr["/host/DENIED.TXT~"] = -vi.ErrEACCES // the publish opens the temp first
	if err := h.WriteFile("/host/DENIED.TXT", []byte("x"), false); err != shlib.ErrNotFound {
		t.Fatalf("denied open err = %v", err)
	}
	k.writeErr = -vi.ErrENOSPC
	if err := h.WriteFile("/host/FULL.TXT", []byte("x"), false); err != shlib.ErrWriteFailed {
		t.Fatalf("failed write err = %v", err)
	}
}

// TestDeleteFileAbsentIsNotAnError matches WriteFilePublish's
// absent-fails-closed readers: ENOENT is a success, anything else is the
// write-class refusal.
func TestDeleteFileAbsentIsNotAnError(t *testing.T) {
	k := newFakeKernel(t)
	k.files["/host/D.TXT"] = []byte("x")
	h := newGoshHost(k.ttyH, true)

	if err := h.DeleteFile("/host/D.TXT"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if err := h.DeleteFile("/host/D.TXT"); err != nil {
		t.Fatalf("delete of an absent file = %v", err)
	}
	k.delErr = -vi.ErrEBADF
	if err := h.DeleteFile("/host/D.TXT"); err != shlib.ErrWriteFailed {
		t.Fatalf("refused delete = %v", err)
	}
}

// TestChdirCarriesErrno: the list gate's refusals stay named — a missing
// dir, a file-as-dir, and an ownership denial are different facts.
func TestChdirCarriesErrno(t *testing.T) {
	k := newFakeKernel(t)
	h := newGoshHost(k.ttyH, true)

	if err := h.Chdir("/host"); err != nil {
		t.Fatalf("chdir /host: %v", err)
	}
	if err := h.Chdir("/host/NOPE"); err == nil || err.Error() != "ENOENT" {
		t.Fatalf("missing dir err = %v", err)
	}
	k.dirErr["/host/PRIV"] = -vi.ErrEACCES
	if err := h.Chdir("/host/PRIV"); err == nil || err.Error() != "EACCES" {
		t.Fatalf("denied dir err = %v", err)
	}
}

// TestKillCarriesTheErrnoName: arming succeeds quietly, and a refusal
// reaches the engine with the kernel's name (EACCES vs EINVAL is the
// difference between "may not" and "no such").
func TestKillCarriesTheErrnoName(t *testing.T) {
	k := newFakeKernel(t)
	h := newGoshHost(k.ttyH, true)
	if err := h.Kill(9); err != nil {
		t.Fatalf("arm: %v", err)
	}
	k.killRc = -vi.ErrEACCES
	if err := h.Kill(9); err == nil || err.Error() != "EACCES" {
		t.Fatalf("denied kill = %v", err)
	}
}

// TestPipeRoundTrip: PipeReadAll drains what PipeWrite staged, across reads
// — the plumbing `a | b` rides.
func TestPipeRoundTrip(t *testing.T) {
	k := newFakeKernel(t)
	h := newGoshHost(k.ttyH, true)
	if err := h.PipeWrite([]byte("piped bytes")); err != nil {
		t.Fatalf("PipeWrite: %v", err)
	}
	got, err := h.PipeReadAll()
	if err != nil || string(got) != "piped bytes" {
		t.Fatalf("PipeReadAll = %q, %v", got, err)
	}
	if len(k.pipe) != 0 {
		t.Fatal("pipe not drained")
	}
}

// TestSuspendReportsTheVerdict: ok, a named refusal code, and a negative
// errno are the three honest answers the suspend verb can get.
func TestSuspendReportsTheVerdict(t *testing.T) {
	k := newFakeKernel(t)
	h := newGoshHost(k.ttyH, true)

	k.vsock = func(verb, name string, code []byte) int64 { return 0 }
	if ok, c := h.Suspend(); !ok || c != "" {
		t.Fatalf("suspend ok = %v,%q", ok, c)
	}
	k.vsock = func(verb, name string, code []byte) int64 {
		return int64(copy(code, "no_credential"))
	}
	if ok, c := h.Suspend(); ok || c != "no_credential" {
		t.Fatalf("suspend refused = %v,%q", ok, c)
	}
	k.vsock = func(verb, name string, code []byte) int64 { return -vi.ErrENOSYS }
	if ok, c := h.Suspend(); ok || c != "ENOSYS" {
		t.Fatalf("suspend errno = %v,%q", ok, c)
	}
}

// TestSecretNamesListsKeysOnly: names cross the seam, values deliberately
// do not (ADR 0024 D8) — and a refused list reports !ok, not an empty list.
func TestSecretNamesListsKeysOnly(t *testing.T) {
	k := newFakeKernel(t)
	k.secrets = []vi.SecretRecord{{KeyLen: 6}, {KeyLen: 3}}
	copy(k.secrets[0].Key[:], "NETKEY")
	copy(k.secrets[1].Key[:], "TLS")
	h := newGoshHost(k.ttyH, true)

	names, ok := h.SecretNames()
	if !ok || len(names) != 2 || names[0] != "NETKEY" || names[1] != "TLS" {
		t.Fatalf("SecretNames = %v,%v", names, ok)
	}
	k.secretRc = -vi.ErrEACCES
	if names, ok := h.SecretNames(); ok || names != nil {
		t.Fatalf("refused SecretNames = %v,%v", names, ok)
	}
}

// TestReadTTYLine: `read VAR` collects bytes until CR or LF, and the 256
// bound ends an unterminated line rather than growing forever.
func TestReadTTYLine(t *testing.T) {
	k := newFakeKernel(t)
	h := newGoshHost(k.ttyH, true)

	k.ttyIn = []byte("hello world\r")
	if s, ok := h.ReadTTYLine(); !ok || s != "hello world" {
		t.Fatalf("ReadTTYLine = %q,%v", s, ok)
	}
	k.ttyIn = []byte("x\n")
	if s, ok := h.ReadTTYLine(); !ok || s != "x" {
		t.Fatalf("ReadTTYLine LF = %q,%v", s, ok)
	}
	k.ttyIn = []byte(strings.Repeat("z", 300))
	if s, ok := h.ReadTTYLine(); !ok || len(s) != 256 {
		t.Fatalf("unterminated ReadTTYLine len = %d,%v", len(s), ok)
	}
	if s, ok := newGoshHost(0, false).ReadTTYLine(); ok || s != "" {
		t.Fatal("headless ReadTTYLine answered true")
	}
}

// TestTTYInterrupter: headless has no fd and no poller; tty hosts get one
// persistent poller (its type-ahead stash must survive between waits).
func TestTTYInterrupter(t *testing.T) {
	k := newFakeKernel(t)
	if p := newGoshHost(0, false).TTYInterrupter(); p != nil {
		t.Fatal("headless host answered a poller")
	}
	h := newGoshHost(k.ttyH, true)
	if p := h.TTYInterrupter(); p == nil || p != h.TTYInterrupter() {
		t.Fatal("tty host did not return one persistent poller")
	}
}

// TestWaitExternalRetiresChildren pins the job-table bookkeeping: the
// children row always retires, and a nonzero exit earns the child's crash
// receipt (the gate's "gosh: job N done exit=" path writes one too).
func TestWaitExternalRetiresChildren(t *testing.T) {
	k := newFakeKernel(t)
	k.procs = []vi.ProcRow{{PID: 9, State: vi.ProcExited, ExitStatus: 7}}
	h := newGoshHost(k.ttyH, true)
	h.children = map[int64]string{9: "FOO.ELF"}

	st, err := h.WaitExternal(9)
	if err != nil || st != 7 {
		t.Fatalf("WaitExternal = %d,%v", st, err)
	}
	if len(h.children) != 0 {
		t.Fatal("children row not retired")
	}
	receipt, ok := k.files[vi.CrashReceiptPath("FOO.ELF")]
	if !ok || !strings.Contains(string(receipt), "outcome=exit=7") {
		t.Fatalf("receipt = %q", receipt)
	}
}

// TestExternalExitedHonoursTheKillExemption: a kill the shell armed itself
// is not a crash; any other nonzero exit still earns the receipt, and the
// row retires either way.
func TestExternalExitedHonoursTheKillExemption(t *testing.T) {
	k := newFakeKernel(t)
	h := newGoshHost(k.ttyH, true)
	h.children = map[int64]string{5: "KILLED.ELF", 6: "DIED.ELF"}

	h.ExternalExited(5, 137, true)
	if _, ok := k.files[vi.CrashReceiptPath("KILLED.ELF")]; ok {
		t.Fatal("self-armed kill earned a crash receipt")
	}
	h.ExternalExited(6, 3, false)
	if _, ok := k.files[vi.CrashReceiptPath("DIED.ELF")]; !ok {
		t.Fatal("nonzero exit earned no crash receipt")
	}
	if len(h.children) != 0 {
		t.Fatal("children rows not retired")
	}
}

// ---------------------------------------------------------------------------
// End-to-end through the real seam: the engine stacked on goshHost over the
// fake kernel. These are the parse/eval paths go-sh.spec's serial asserts
// previously covered only from a booted VM.
// ---------------------------------------------------------------------------

func newTestShell(k *fakeKernel) *shlib.Shell {
	return shlib.NewShell(newGoshHost(k.ttyH, true), &shlib.History{})
}

// TestEvalThroughTheRealSeam runs the go-sh spec's startup-script subjects
// (env, $?, one pipe, > and >>, a heredoc, a read-back) through the REAL
// host seam — parse, expand, dispatch, builtin, and the kernel ABI all in
// play, minus the VM.
func TestEvalThroughTheRealSeam(t *testing.T) {
	k := newFakeKernel(t)
	sh := newTestShell(k)

	run := func(line string) int {
		t.Helper()
		st, act := sh.RunLine(line)
		if act != shlib.ActionContinue {
			t.Fatalf("%q -> action %v", line, act)
		}
		return st
	}
	out := func() string {
		s := string(k.out)
		k.out = nil
		return s
	}

	if run("echo hello world") != 0 || out() != "hello world\n" {
		t.Fatalf("echo: out=%q", k.out)
	}
	run("set GREET=hello-vars")
	if run("echo V=$GREET") != 0 || out() != "V=hello-vars\n" {
		t.Fatalf("var expand: out=%q", k.out)
	}
	if run("false") != 1 || run("echo rc=$?") != 0 || out() != "rc=1\n" {
		t.Fatalf("$?: out=%q", k.out)
	}
	if run("echo alpha-beta | grep alpha") != 0 || out() != "alpha-beta\n" {
		t.Fatalf("pipe: out=%q", k.out)
	}

	// The redirect publishes crash-safe: a long pre-existing body is
	// replaced whole, then >> appends — the two spec asserts, byte-equal.
	k.files["/host/GOOSHSHRINK.TXT"] = []byte(strings.Repeat("PREEXISTING-LONG-BODY\n", 40))
	run("echo shrunk-body > /host/GOOSHSHRINK.TXT")
	if got := string(k.files["/host/GOOSHSHRINK.TXT"]); got != "shrunk-body\n" {
		t.Fatalf("shrink body = %q", got)
	}
	if _, ok := k.files["/host/GOOSHSHRINK.TXT~"]; ok {
		t.Fatal("redirect left its ~ temp behind")
	}
	run("echo first-appended >> /host/GOOSHSHRINK.TXT")
	if got := string(k.files["/host/GOOSHSHRINK.TXT"]); got != "shrunk-body\nfirst-appended\n" {
		t.Fatalf("appended body = %q", got)
	}

	// Heredoc bodies run through RunLineBodies: the bare delimiter expands
	// on use, the quoted one stays literal — the spec's GOSHHDOC.TXT pair.
	st, act := sh.RunLineBodies("cat <<HD > /host/GOSHHDOC.TXT", [][]byte{[]byte("expanded $GREET\n")})
	if act != shlib.ActionContinue || st != 0 {
		t.Fatalf("heredoc st=%d act=%v", st, act)
	}
	st, act = sh.RunLineBodies("cat <<'QT' >> /host/GOSHHDOC.TXT", [][]byte{[]byte("literal $GREET\n")})
	if act != shlib.ActionContinue || st != 0 {
		t.Fatalf("quoted heredoc st=%d act=%v", st, act)
	}
	if got := string(k.files["/host/GOSHHDOC.TXT"]); got != "expanded hello-vars\nliteral $GREET\n" {
		t.Fatalf("heredoc file = %q", got)
	}

	// And a read-back through the same seam, closing the loop.
	run("cat /host/GOSHHDOC.TXT")
	if got := out(); got != "expanded hello-vars\nliteral $GREET\n" {
		t.Fatalf("cat = %q", got)
	}
}

// exitPanic lets a host test leave vi.Exit: after the SlotExit hook observes
// the status, Exit parks in a Yield loop forever ("the kernel never returns
// here"), so the only way back is a panic the test itself recovers.
type exitPanic struct{ status int64 }

// TestRunHeadlessExitsWithTheLineStatus: `GOSH.ELF -c LINE` writes a crash
// receipt only for a nonzero exit, then leaves by SlotExit — observable
// here through the same hook the kernel would answer.
func TestRunHeadlessExitsWithTheLineStatus(t *testing.T) {
	k := newFakeKernel(t)
	k.onExit = func(st int64) { panic(exitPanic{st}) }
	run := func(line string) (status int64) {
		defer func() {
			if ep, ok := recover().(exitPanic); ok {
				status = ep.status
			} else {
				status = -1
			}
		}()
		runHeadless(line)
		return -1
	}

	if got := run("exit 7"); got != 7 {
		t.Fatalf("exit 7 -> %d", got)
	}
	receipt, ok := k.files[vi.CrashReceiptPath("GOSH.ELF")]
	if !ok || !strings.Contains(string(receipt), "outcome=exit=7") {
		t.Fatalf("headless receipt = %q", receipt)
	}
	if got := run("true"); got != 0 {
		t.Fatalf("true -> %d", got)
	}
}

// TestStartupLinesContract: STARTUP.SH then PROFILE.SH, silent when
// missing, CRLF folded — the file half of the startup contract.
func TestStartupLinesContract(t *testing.T) {
	k := newFakeKernel(t)
	if got := startupLines(); got != nil {
		t.Fatalf("no scripts -> %v", got)
	}
	k.files["/host/STARTUP.SH"] = []byte("echo one\r\necho two\n")
	k.files["/host/PROFILE.SH"] = []byte("echo profile\n")
	got := startupLines()
	// Trailing newlines split to empty strings, and blank lines ride along —
	// scriptSteps skips them outside heredoc bodies.
	want := []string{"echo one", "echo two", "", "echo profile", ""}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("startupLines = %v", got)
	}
}

// TestLoadPromptAdoptsSettings: the SETTINGS.TXT `prompt` key is the
// template (escapes expand at paint), and a missing file keeps the default.
func TestLoadPromptAdoptsSettings(t *testing.T) {
	k := newFakeKernel(t)
	if got := loadPrompt(); got != defaultPrompt {
		t.Fatalf("default prompt = %q", got)
	}
	// The loader owns the trailing space (shlib.PromptFromSettings).
	k.files["/host/SETTINGS.TXT"] = []byte("prompt=\\w\n")
	if got := loadPrompt(); got != "\\w " {
		t.Fatalf("settings prompt = %q", got)
	}
}

// stackStretch pre-grows the test goroutine's stack. The svc hook seam
// hands guest buffers across as uintptr; if a morestack inside the hook
// chain copied the caller's stack, those uintptrs would dangle into the
// abandoned copy — a host-build hazard the guest's leaf-assembly SVC never
// has. Deep headroom makes the copy impossible.
func stackStretch(n int) int {
	var pad [64]byte
	pad[0] = byte(n)
	if n <= 0 {
		return int(pad[0])
	}
	return int(pad[0]) + stackStretch(n-1)
}
