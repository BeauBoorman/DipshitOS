// goshHost is GOSH's shlib.Host seam over vi (M194c, issue #3283): it was
// the bottom half of main.go, split out so the host-test harness (a fake
// kernel behind vi's syscall hooks) can reach it without the front-end
// dispatch. What lives here is the translation layer — kernel errno to
// shlib error, raw handle to line emitter, pid to children row — everything
// the go-sh serial gates used to see only end-to-end.
package main

import (
	"strings"

	"virelai/shlib"
	"virelai/vi"
)

// goshHost is the Host seam over vi. When tty is set, Out writes the
// attached /dev/tty (serial, window, or net — the kernel pumps the right
// front-end). Headless, Out buffers console lines. fd 0 is a valid kernel
// file handle (the first open), so it cannot mean "no tty".
type goshHost struct {
	fd       uint32
	tty      bool
	lines    lineEmitter
	children map[int64]string
	poll     *shlib.TTYPoll
}

// newGoshHost returns the seam with its headless line sink aimed at the
// serial console — the only place a buffered line can go.
func newGoshHost(fd uint32, tty bool) *goshHost {
	return &goshHost{fd: fd, tty: tty, lines: lineEmitter{emit: vi.ConsoleLine}}
}

// lineEmitter turns a byte stream into whole lines for emit. Headless Out
// receives arbitrary chunks; the serial console and the gate's asserts are
// line-oriented, so a line is emitted only once it is complete, and a
// trailing partial line flushes at exit rather than mid-write.
type lineEmitter struct {
	emit func(string)
	buf  []byte
}

func (l *lineEmitter) write(b []byte) {
	l.buf = append(l.buf, b...)
	for {
		i := indexByte(l.buf, '\n')
		if i < 0 {
			return
		}
		l.emit(string(l.buf[:i]))
		l.buf = l.buf[i+1:]
	}
}

// flush drains a trailing partial line at headless exit.
func (l *lineEmitter) flush() {
	if len(l.buf) > 0 {
		l.emit(string(l.buf))
		l.buf = nil
	}
}

func indexByte(b []byte, c byte) int {
	for i, x := range b {
		if x == c {
			return i
		}
	}
	return -1
}

func (g *goshHost) Marker(line string) { vi.ConsoleLine(line) }

func (g *goshHost) Out(b []byte) {
	if g.tty {
		writeTTY(g.fd, b)
		return
	}
	g.lines.write(b)
}

// flushOut drains a trailing partial line at headless exit.
func (g *goshHost) flushOut() {
	if !g.tty {
		g.lines.flush()
	}
}

// candidateNames expands name the way SH.BIN's resolver did: bare, .ELF
// and .BIN suffixes, uppercase variants, in that order.
func candidateNames(name string) []string {
	up := strings.ToUpper(name)
	var out []string
	add := func(n string) {
		for _, e := range out {
			if e == n {
				return
			}
		}
		out = append(out, n)
	}
	for _, base := range []string{name, up} {
		add(base)
		add(base + ".ELF")
		add(base + ".BIN")
	}
	return out
}

func (g *goshHost) RunExternal(name string, args []string) (int64, error) {
	for _, cand := range candidateNames(name) {
		if pid, err := vi.Exec(cand, args...); err == nil {
			if g.children == nil {
				g.children = make(map[int64]string)
			}
			g.children[pid] = cand
			return pid, nil
		}
	}
	return 0, shlib.ErrNotFound
}

func (g *goshHost) WaitExternal(pid int64) (int64, error) {
	status, err := vi.Wait(pid)
	if err == nil && status != 0 {
		g.RecordCrash(g.children[pid], status)
	}
	delete(g.children, pid)
	return status, err
}

func (g *goshHost) ProbeExternal(pid int64) (int64, int) {
	st, state := vi.Probe(pid)
	return st, state
}

// ExternalExited keeps the interruptible wait's bookkeeping level with
// WaitExternal's: the children row always retires, and a nonzero exit
// still earns its crash receipt — except a kill the shell armed itself,
// which the card declares is not a crash.
func (g *goshHost) ExternalExited(pid int64, status int64, killed bool) {
	name := g.children[pid]
	delete(g.children, pid)
	if !killed && status != 0 {
		g.RecordCrash(name, status)
	}
}

func (g *goshHost) SleepTick() { vi.Sleep(1) }

// TTYInterrupter is the M98f Ctrl-C seam: the same fd the session loop
// reads, handed to the engine as a non-blocking byte source while it
// waits. Headless (-c) hosts have no fd and answer nil, keeping the
// blocking WaitExternal path. The instance persists on the host — its
// type-ahead stash must survive between the engine's waits.
func (g *goshHost) TTYInterrupter() *shlib.TTYPoll {
	if !g.tty {
		return nil
	}
	if g.poll == nil {
		g.poll = &shlib.TTYPoll{Read: func(b []byte) int {
			n, _ := vi.FileRead(g.fd, b)
			return n
		}}
	}
	return g.poll
}

// Kill arms sys_kill (slot 29) for `kill`/Ctrl-C, carrying the kernel's
// errno name so the engine can report EACCES vs EINVAL honestly.
func (g *goshHost) Kill(pid int64) error {
	if r := vi.Kill(uint64(pid)); r < 0 {
		if name := vi.ErrnoName(r); name != "" {
			return shlib.NewOpenError(vi.Itoa64(pid), name)
		}
		return shlib.ErrNotFound
	}
	return nil
}

func (g *goshHost) PipeWrite(b []byte) error {
	_, err := vi.PipeWrite(b)
	return err
}

func (g *goshHost) PipeReadAll() ([]byte, error) {
	var all []byte
	buf := make([]byte, 512)
	for len(all) < shlib.MaxPipeBytes {
		n, err := vi.PipeRead(buf)
		if err != nil {
			return all, err
		}
		if n == 0 {
			return all, nil
		}
		all = append(all, buf[:n]...)
	}
	return all, nil
}

func (g *goshHost) ReadFile(path string, max int) ([]byte, error) {
	b, r := vi.ReadFileAll(path, max)
	if r < 0 {
		// Carry the kernel's own errno name: an ownership denial (EACCES)
		// and an absent file (ENOENT) are different facts, and the M50
		// trust gates assert which one the shell reported.
		if name := vi.ErrnoName(r); name != "" {
			return nil, shlib.NewOpenError(path, name)
		}
		return nil, shlib.ErrNotFound
	}
	return b, nil
}

// Principal is the caller's identity (slot 68) for `whoami`/`id`.
func (g *goshHost) Principal() (uint32, uint32, bool) { return vi.Principal() }

// Chmod is the owner-only mode change (slot 69).
func (g *goshHost) Chmod(path string, mode uint16) error {
	r := vi.FileMode(path, mode)
	if r < 0 {
		if name := vi.ErrnoName(r); name != "" {
			return shlib.NewOpenError(path, name)
		}
		return shlib.ErrNotFound
	}
	return nil
}

// SecretNames reads the caller's store entry NAMES (slot 70). The values are
// deliberately not carried through this seam.
func (g *goshHost) SecretNames() ([]string, bool) {
	var recs [vi.SecretEntriesMax]vi.SecretRecord
	n, r := vi.SecretList(recs[:])
	if r < 0 {
		return nil, false
	}
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, recs[i].KeyString())
	}
	return out, true
}

// Suspend is the guest-initiated power request (M115d, slot 93): the
// kernel runs the whole authenticated ctl session under its uid_system
// `vsock-ctl` credential — no key bytes cross the seam. The ok return
// may land on the far side of a host save/restore.
func (g *goshHost) Suspend() (bool, string) {
	var code [40]byte
	r := vi.VsockCtl("suspend", "", code[:])
	if r == 0 {
		return true, ""
	}
	if r > 0 {
		if r > int64(len(code)) {
			r = int64(len(code))
		}
		return false, string(code[:r])
	}
	return false, vi.ErrnoName(r)
}

func (g *goshHost) AppLogNames() []string {
	names, rc := vi.AppLogNames()
	if rc < 0 {
		return nil
	}
	return names
}

func (g *goshHost) ReadAppLog(app string) ([]byte, error) {
	b, rc := vi.ReadLog(app)
	if rc < 0 {
		return nil, shlib.ErrNotFound
	}
	return b, nil
}

func (g *goshHost) RecordCrash(app string, status int64) {
	outcome := "exit=" + vi.Itoa64(status)
	_ = vi.Log(app, outcome)
	_ = vi.WriteCrashReceipt(app, outcome)
}

// WriteFile is the shell's whole write hook, and it used to be the last
// in-place writer in the Go tree (M81e2 #1787): open(ModeWrite|ModeCreate
// [|ModeAppend]) then FileWriteAll, no truncate barrier, no rename. Two
// callers with DIFFERENT semantics share this one seam, so the policy
// decision lives in vi.WriteFilePublish rather than here:
//
//   - REPLACE (appendMode false) is the history ring save (shlib.SaveHistory
//     trimming the ring back to historyMax) and shell redirection `> file`.
//     Both hold the complete new body in memory, and both mean "these bytes
//     replace what was there" — app state, so it publishes crash-safe.
//   - APPEND (appendMode true) is the history one-line append and `>>`. It
//     is not a rewrite, so it stays an append; vi.WriteFilePublish owns that
//     reason.
//
// Redirection `> file` is therefore NOT exempt from the safe publish. The
// objection is real but does not survive contact with this shell: the
// redirect buffer is capped (shlib maxRedirectBytes) and fully materialized
// before this call, so there is no streaming case where a reader must watch
// the file grow; and the observable contract is unchanged — an empty body
// still yields an empty file, a missing path is still created, and a write
// that fails now leaves the PREVIOUS contents rather than destroying them.
// The one cost, stated plainly: a path within one byte of the kernel's
// 64-byte cap cannot be published at all (vi.WriteFileSafe's `~` sibling
// would exceed it) and now fails honestly instead of writing. go-sh pins
// both halves.
func (g *goshHost) WriteFile(path string, b []byte, appendMode bool) error {
	if r := vi.WriteFilePublish(path, b, appendMode); r < 0 {
		// A refused OPEN is a path problem (gone, denied, too long); a
		// refused WRITE is the disk's. Folding both into ErrNotFound is
		// what made this hook lie, so keep them apart.
		if r == -vi.ErrEACCES || r == -vi.ErrENOENT || r == -vi.ErrENAMETOOLONG {
			return shlib.ErrNotFound
		}
		return shlib.ErrWriteFailed
	}
	return nil
}

// DeleteFile removes path — an absent file is not an error, matching
// WriteFilePublish's absent-fails-closed readers.
func (g *goshHost) DeleteFile(path string) error {
	if r := vi.FileDelete(path); r < 0 && r != -vi.ErrENOENT {
		return shlib.ErrWriteFailed
	}
	return nil
}

func (g *goshHost) Chdir(path string) error {
	var entries [1]vi.DirEntry
	if _, r := vi.DirList(path, entries[:]); r < 0 {
		// Carry the kernel's errno for the same reason ReadFile does: a
		// missing directory, a path that is a file, and an ownership denial
		// on the share's list gate are three different facts, and folding
		// them into one "not a directory" message hides two of them.
		if name := vi.ErrnoName(r); name != "" {
			return shlib.NewOpenError(path, name)
		}
		return shlib.ErrNotFound
	}
	return nil
}

// ListPath is the M98a glob seam: a path-aware listing of a canonical
// directory. The shared vi wrapper owns the /host conversion, the
// slot-79 paging and the USB fallback — the front-end adds no logic.
func (g *goshHost) ListPath(dir string) ([]vi.DirItem, error) {
	return vi.ListDirAt(dir)
}

func (g *goshHost) ReadTTYLine() (string, bool) {
	if !g.tty {
		return "", false
	}
	var acc []byte
	buf := make([]byte, 32)
	for len(acc) < 256 {
		n, _ := vi.FileRead(g.fd, buf)
		if n == 0 {
			vi.Sleep(1)
			continue
		}
		for i := 0; i < n; i++ {
			if buf[i] == '\r' || buf[i] == '\n' {
				return string(acc), true
			}
			acc = append(acc, buf[i])
		}
	}
	return string(acc), true
}

// SleepSeconds parks n sys_sleep ticks — the kernel timer is 1 Hz
// (kernel/src/timer.zig period_ns), so one tick IS one second.
func (g *goshHost) SleepSeconds(n int) {
	vi.Sleep(uint64(n))
}
