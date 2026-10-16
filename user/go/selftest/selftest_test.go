package main

import (
	"bytes"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"

	"virelai/snapshot"
	"virelai/vi"
)

// fakeFS is an in-memory share for the case logic: it implements the syscalls
// struct over maps, so `go test ./selftest` exercises real case behavior with
// no guest (the host `vi` stubs return -ENOSYS by design). Fault switches let
// a test drive the failure paths an adapter can actually hit.
type fakeFS struct {
	files   map[string][]byte
	dirs    map[string]bool
	handles map[int64]string
	hflags  map[int64]uint32 // the flags each handle was opened with (truncate's gate)
	cursors map[int64]int
	next    int64
	clock   int64
	epoch   int64
	trash   map[string]fakeTrash
	trashID uint64
	recent  []string

	// M83b (#1775): the setter's fake. The honest shape mirrors the kernel:
	// EINVAL outside [clockSetMin, clockSetMax], otherwise the epoch is the
	// new reading. The knobs are deliberately WRONG shapes the case must catch.
	setCalls   []int64
	setLies    bool // reports success and leaves the clock alone
	setNoRange bool // accepts any epoch, including out-of-range ones
	setDeny    int64

	frozenClock bool   // sleep does not advance the clock
	shortWrite  bool   // every write accepts one byte (the loop path)
	corruptRead bool   // reads return the wrong bytes
	denyWrite   bool   // every write-op fails
	denyPath    string // write-opens of this path fail (the intake copy is unaffected)
	zeroRead    bool   // reads return the right length of zeros (issue #1391)
	refuseRead  bool   // reads fail outright (M81b: the mime case must notice)

	denyTruncate bool // truncate fails with EACCES
	lieDelete    bool // delete reports success and leaves the file
	listStale    bool // deleted paths: removed from the table, still listed
	ghosts       []string

	failSync bool     // fsync reports the residual host error (M66a)
	syncs    []string // M100f (#2311): the paths fsync landed on, in order

	// M81e2 (#1787): override the publish seam with a DELIBERATELY WRONG
	// implementation, so a test can prove the file-write-publish case
	// catches it. Left nil, syscalls() binds the honest fakePublish.
	publishOverride func(path string, b []byte, appendMode bool) int64

	// M81d (#1764): the lease rows are a SCRIPTED honest shape — the vi
	// semantics are pinned in vi's own suite; these tests pin the case's
	// sequence and its failure naming. Each script is popped per call and
	// sticks on its last value; an empty script means "always succeed".
	// leaseDenyAcquire forces every acquire to refuse (the failure test).
	leaseAcqScript   []int64
	leaseChkScript   []int64
	leaseRelScript   []int64
	leaseAcqCalls    int
	leaseChkCalls    int
	leaseRelCalls    int
	leaseDenyAcquire bool

	winID         int       // the id the shell would have bound (-1 = open failed)
	winGeometry   [8]uint32 // the record sys_win_query answers with
	winQueryErr   bool      // query fails
	winFillErr    bool      // fill fails
	winPresentErr bool      // present fails
}

// popLease pops the next scripted value, sticking on the script's last
// entry once the calls run past it (0 = success).
func (f *fakeFS) popLease(script []int64, calls *int) int64 {
	if len(script) == 0 {
		return 0
	}
	i := *calls - 1
	if i >= len(script) {
		i = len(script) - 1
	}
	return script[i]
}

type fakeTrash struct {
	path string
	body []byte
	time int64
}

// The window the real run hands GOSELF. It is opened at 32,32 as 640x400 (the
// app's own request) and TABWM then re-proposes the tab-aware content
// viewport, so the geometry sys_win_query answers with is NOT what the app
// asked for at open. The fake models that difference on purpose: it is the
// distinction the window case exists to expose (it reports the kernel's
// answer, not the request).
const (
	winReqW = 640
	winReqH = 400
	winGotX = 180
	winGotY = 0
	winGotW = 1100
	winGotH = 720
)

func newFakeFS() *fakeFS {
	return &fakeFS{
		files:   map[string][]byte{},
		dirs:    map[string]bool{},
		handles: map[int64]string{},
		hflags:  map[int64]uint32{},
		cursors: map[int64]int{},
		trash:   map[string]fakeTrash{},
		clock:   1000,
		epoch:   1_789_043_696,
		winID:   2,
		winGeometry: [8]uint32{winGotX, winGotY, winGotW, winGotH,
			0 /*z*/, 1 /*focused*/, 1 /*visible*/, 0 /*dirty*/},
		// The lease drill's honest default: the case's exact call order —
		// acquire ok / foreign refused / two takeovers ok, target refused
		// then free then free, release refused then released. Tests that
		// need a different shape override or deny.
		leaseAcqScript: []int64{0, -vi.ErrEAGAIN, 0, 0},
		leaseChkScript: []int64{-vi.ErrEAGAIN, 0, 0},
		leaseRelScript: []int64{-vi.ErrEAGAIN, 0},
	}
}

func (f *fakeFS) setEpoch(epoch int64) int64 {
	f.setCalls = append(f.setCalls, epoch)
	if f.setDeny != 0 {
		return f.setDeny
	}
	if !f.setNoRange && (epoch < clockSetMin || epoch > clockSetMax) {
		return -vi.ErrEINVAL
	}
	if !f.setLies {
		f.epoch = epoch
	}
	return 0
}

func (f *fakeFS) syscalls() *syscalls {
	return &syscalls{
		now: func() int64 { return f.clock },
		epoch: func() int64 {
			return f.epoch
		},
		setEpoch: f.setEpoch,
		sleep: func(ticks uint64) {
			if !f.frozenClock {
				f.clock += int64(ticks)
			}
		},
		mkdir: func(path string) int64 {
			if f.dirs[path] {
				return -9 // EEXIST, the kernel's MODE_DIR value
			}
			f.dirs[path] = true
			return 0
		},
		open:     f.open,
		read:     f.read,
		write:    f.writeGuarded,
		truncate: f.truncate,
		sync:     f.syncHandle,
		remove:   f.remove,
		list:     f.list,
		close: func(h uint32) {
			delete(f.handles, int64(h))
			delete(f.hflags, int64(h))
		},
		writeSafe: f.writeSafe,
		readAll: func(path string, max int) ([]byte, int64) {
			body, ok := f.files[path]
			if !ok {
				return nil, vi.ErrFileNotFound
			}
			if len(body) > max {
				body = body[:max]
			}
			return append([]byte(nil), body...), int64(min(len(body), max))
		},
		logWrite: func(app, line string) int64 {
			path := vi.AppLogPath(app)
			if path == "" {
				return -vi.ErrEINVAL
			}
			line = strings.ReplaceAll(strings.ReplaceAll(line, "\r", " "), "\n", " ")
			if len(line) > vi.AppLogMaxLine {
				line = line[:vi.AppLogMaxLine]
			}
			rows := strings.Split(strings.TrimSuffix(string(f.files[path]), "\n"), "\n")
			if len(rows) == 1 && rows[0] == "" {
				rows = nil
			}
			rows = append(rows, line)
			if len(rows) > vi.AppLogMaxLines {
				rows = rows[len(rows)-vi.AppLogMaxLines:]
			}
			f.files[path] = []byte(strings.Join(rows, "\n") + "\n")
			return 0
		},
		logRead: func(app string) ([]byte, int64) {
			path := vi.AppLogPath(app)
			body, ok := f.files[path]
			if path == "" {
				return nil, -vi.ErrEINVAL
			}
			if !ok {
				return nil, vi.ErrFileNotFound
			}
			return append([]byte(nil), body...), int64(len(body))
		},
		crashReceipt: func(app, outcome string) int64 {
			path := vi.CrashReceiptPath(app)
			if path == "" {
				return -vi.ErrEINVAL
			}
			outcome = strings.ReplaceAll(strings.ReplaceAll(outcome, "\r", " "), "\n", " ")
			log := f.files[vi.AppLogPath(app)]
			rows := strings.Split(strings.TrimSuffix(string(log), "\n"), "\n")
			if len(rows) == 1 && rows[0] == "" {
				rows = nil
			}
			if len(rows) > 8 {
				rows = rows[len(rows)-8:]
			}
			receipt := "app=" + app + "\noutcome=" + outcome + "\nlast-log:\n"
			if len(rows) > 0 {
				receipt += strings.Join(rows, "\n") + "\n"
			}
			f.files[path] = []byte(receipt)
			return 0
		},
		leaseAcquire: func(path, selfName string) (*vi.FileLease, int64) {
			f.leaseAcqCalls++
			if f.leaseDenyAcquire {
				return nil, -vi.ErrEAGAIN
			}
			if rc := f.popLease(f.leaseAcqScript, &f.leaseAcqCalls); rc < 0 {
				return nil, rc
			}
			return &vi.FileLease{Target: path, LeasePath: vi.LeasePathFor(path),
				Token: [8]byte{byte(f.leaseAcqCalls)}}, 0
		},
		leaseCheck: func(path string) int64 {
			f.leaseChkCalls++
			return f.popLease(f.leaseChkScript, &f.leaseChkCalls)
		},
		leaseRelease: func(l *vi.FileLease) int64 {
			f.leaseRelCalls++
			return f.popLease(f.leaseRelScript, &f.leaseRelCalls)
		},
		trashDelete: func(path string) (string, int64) {
			body, ok := f.files[path]
			if !ok {
				return "", vi.ErrFileNotFound
			}
			f.trashID++
			id := fmt.Sprintf("%016x", f.trashID)
			f.trash[id] = fakeTrash{path: path, body: append([]byte(nil), body...), time: f.clock}
			delete(f.files, path)
			f.dirs[vi.TrashDir] = true
			f.recent = append(f.recent, fmt.Sprintf("%d|delete|%s|%s", f.clock, id, path))
			f.files[vi.RecentLogPath] = []byte(strings.Join(f.recent, "\n") + "\n")
			return id, 0
		},
		trashRead: func(id string) (string, []byte, int64, int64) {
			item, ok := f.trash[id]
			if !ok {
				return "", nil, 0, vi.ErrFileNotFound
			}
			return item.path, append([]byte(nil), item.body...), item.time, int64(len(item.body))
		},
		trashRestore: func() (string, string, int64) {
			for i := len(f.recent) - 1; i >= 0; i-- {
				fields := strings.Split(f.recent[i], "|")
				if len(fields) != 4 || fields[1] != "delete" {
					continue
				}
				id := fields[2]
				item, ok := f.trash[id]
				if !ok {
					continue
				}
				if _, exists := f.files[item.path]; exists {
					return "", "", vi.ErrFileExists
				}
				f.files[item.path] = append([]byte(nil), item.body...)
				delete(f.trash, id)
				f.recent = append(f.recent, fmt.Sprintf("%d|restore|%s|%s", f.clock, id, item.path))
				f.files[vi.RecentLogPath] = []byte(strings.Join(f.recent, "\n") + "\n")
				return item.path, id, 0
			}
			return "", "", vi.ErrFileNotFound
		},
		trashExpire: func(now int64) (int, int64) {
			removed := 0
			for id, item := range f.trash {
				if now >= item.time && now-item.time >= vi.TrashRetentionSeconds {
					delete(f.trash, id)
					removed++
				}
			}
			return removed, 0
		},
		publish: f.publishFn(),
		win:     f.windowSeam(),
	}
}

// windowSeam models the tabapp surface: the id the shell binds, the geometry
// the app asked for at open, and the three ADR 0007 window rows the case
// drives. query answers with the fake's kernel-side record, so a test can make
// the kernel's view differ from the app's request in either direction.
func (f *fakeFS) windowSeam() windowSeam {
	return windowSeam{
		id:   f.winID,
		reqW: winReqW,
		reqH: winReqH,
		query: func(id int) ([8]uint32, int64) {
			// sys_win_query is owner-restricted: a foreign id is EINVAL.
			if id != f.winID || f.winQueryErr {
				return [8]uint32{}, -1
			}
			return f.winGeometry, 0
		},
		fill: func(id int, x, y, w, h uint32, rgb uint32) int64 {
			if id != f.winID || f.winFillErr {
				return -1
			}
			return 0
		},
		present: func(id int) int64 {
			if id != f.winID || f.winPresentErr {
				return -1
			}
			return 0
		},
	}
}

// writeGuarded applies the fake's write fault switches, then the plain write.
func (f *fakeFS) writeGuarded(h uint32, b []byte) (int, int64) {
	if f.denyWrite {
		return 0, -2
	}
	if f.shortWrite && len(b) > 1 {
		b = b[:1]
	}
	return f.write(h, b)
}

// truncate mirrors file_table.truncate: EBADF for a dead handle, EACCES
// without MODE_WRITE, shrink keeps the prefix, growth zero-fills, and the
// cursor is clamped to the new size.
func (f *fakeFS) truncate(h uint32, size uint32) int64 {
	p, ok := f.handles[int64(h)]
	if !ok {
		return -2 // EBADF
	}
	if f.denyTruncate || f.hflags[int64(h)]&flagModeWrite == 0 {
		return -7 // EACCES
	}
	body := f.files[p]
	var next []byte
	if int(size) <= len(body) {
		next = append([]byte(nil), body[:size]...)
	} else {
		next = make([]byte, size)
		copy(next, body)
	}
	f.files[p] = next
	if f.cursors[int64(h)] > int(size) {
		f.cursors[int64(h)] = int(size)
	}
	return 0
}

// remove mirrors file_table.delete: ENOENT for a path that is not a file,
// EINVAL for a directory.
func (f *fakeFS) remove(path string) int64 {
	if _, ok := f.files[path]; !ok {
		return -6 // ENOENT
	}
	if f.dirs[path] {
		return -1 // EINVAL: a directory is not a file
	}
	if f.lieDelete {
		return 0 // reports success, leaves the bytes: the case must catch it
	}
	delete(f.files, path)
	if f.listStale {
		f.ghosts = append(f.ghosts, path)
	}
	return 0
}

// list mirrors sys_dir_list over the share: the direct children of an
// existing directory, sorted, as 40-byte rows. A missing directory is ENOENT
// (the host's LIST has no entries to return).
func (f *fakeFS) list(path string, buf []vi.DirEntry) (int, int64) {
	if !f.dirs[path] {
		return 0, -6 // ENOENT
	}
	prefix := path + "/"
	type row struct {
		name string
		dir  bool
	}
	var rows []row
	add := func(p string, dir bool) {
		rest, ok := strings.CutPrefix(p, prefix)
		if !ok || rest == "" || strings.Contains(rest, "/") {
			return // not a direct child
		}
		rows = append(rows, row{name: rest, dir: dir})
	}
	for p := range f.files {
		add(p, false)
	}
	for d := range f.dirs {
		add(d, true)
	}
	for _, g := range f.ghosts {
		add(g, false) // a stale listing still reports a deleted name
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].name < rows[j].name })
	n := 0
	for _, r := range rows {
		if n >= len(buf) {
			break
		}
		var e vi.DirEntry
		copy(e.Name[:], r.name)
		if r.dir {
			e.IsDir = 1
		} else {
			e.Size = uint32(len(f.files[prefix+r.name]))
		}
		buf[n] = e
		n++
	}
	return n, int64(n)
}

const (
	flagModeRead   = 0x0001
	flagModeWrite  = 0x0002
	flagModeCreate = 0x0004
	flagModeAppend = 0x0008
	flagModeDir    = 0x0010
)

// syncHandle mirrors file_table.sync: EBADF for a dead handle, the residual
// host error under the fault switch, an honest 0 for a live handle (M66a).
func (f *fakeFS) syncHandle(h uint32) int64 {
	if _, ok := f.handles[int64(h)]; !ok {
		return -2 // EBADF
	}
	if f.failSync {
		return -1
	}
	f.syncs = append(f.syncs, f.handles[int64(h)])
	return 0
}

func (f *fakeFS) open(path string, flags uint32) (int64, int64) {
	// The kernel's 8-slot handle table (max_handles_per_process): the 9th
	// concurrent open is ENOSPC before any path work (M66a).
	if len(f.handles) >= 8 {
		return 0, -5
	}
	switch {
	case flags&flagModeDir != 0:
		// The kernel's open validates MODE_DIR against
		// MODE_WRITE|MODE_CREATE — a bare MODE_DIR is EINVAL, which is what
		// the guest's mkdir helper used to pass (and therefore always
		// failed silently).
		if flags&(flagModeWrite|flagModeCreate) != flagModeWrite|flagModeCreate {
			return 0, -1
		}
		if f.dirs[path] {
			return 0, -9
		}
		f.dirs[path] = true
		return 0, 0
	case flags&flagModeWrite != 0:
		if f.denyWrite || (f.denyPath != "" && f.denyPath == path) {
			return 0, -2
		}
		if f.dirs[path] {
			return 0, -1 // is-dir: a directory is not a writable file (M66a)
		}
		if flags&flagModeAppend == 0 {
			f.files[path] = nil // ADR 0010 replace semantics
		} // an append handle keeps the body: writes land at EOF
		f.next++
		f.handles[f.next] = path
		f.hflags[f.next] = flags
		f.cursors[f.next] = 0
		return f.next, f.next
	case flags&flagModeRead != 0:
		if _, ok := f.files[path]; !ok {
			return 0, -6 // ENOENT
		}
		f.next++
		f.handles[f.next] = path
		f.hflags[f.next] = flags
		f.cursors[f.next] = 0
		return f.next, f.next
	}
	return 0, -1 // EINVAL
}

func (f *fakeFS) read(h uint32, buf []byte) (int, int64) {
	p, ok := f.handles[int64(h)]
	if !ok {
		return 0, -2
	}
	if f.refuseRead {
		return 0, -5 // EIO: the share cannot hand this file over
	}
	cur := f.cursors[int64(h)]
	body := f.files[p]
	if cur >= len(body) {
		return 0, 0
	}
	n := copy(buf, body[cur:])
	f.cursors[int64(h)] = cur + n
	if f.corruptRead {
		buf[0] ^= 0xff
	}
	if f.zeroRead {
		for i := 0; i < n; i++ {
			buf[i] = 0
		}
	}
	return n, int64(n)
}

func (f *fakeFS) write(h uint32, b []byte) (int, int64) {
	p, ok := f.handles[int64(h)]
	if !ok {
		return 0, -2
	}
	if len(b) > fileWriteMax {
		return 0, -5 // the kernel's sys_file_write stage cap (M66a)
	}
	f.files[p] = append(f.files[p], b...)
	return len(b), int64(len(b))
}

// resultFor returns the verdict for one case by id. The window tests used to
// hardcode a list index, which every added case shifts — M81b, M81e2 and M81g
// each had to renumber them. Asking by id is what the test means.
func resultFor(t *testing.T, rs []result, id string) result {
	t.Helper()
	for _, r := range rs {
		if r.id == id {
			return r
		}
	}
	t.Fatalf("no case %q in this run", id)
	return result{}
}

// wantReport is the byte-exact report with the M82e app-log case and the
// M81d file-lease case: the M61f `share-equals` fixture shape, and the
// report the go-selftest spec requires on the share. Adding a case updates
// this and the spec together.
const wantReport = "case intake pass\ncase intake-altered pass\n" +
	"case clock-monotonic pass\ncase file-write pass\n" +
	"case file-roundtrip pass\ncase file-truncate pass\n" +
	"case file-delete pass\ncase file-list pass\n" +
	"case file-append pass\ncase file-bigwrite pass\ncase file-clamp pass\n" +
	"case file-fsync pass\ncase file-errors pass\n" +
	"case file-write-safe pass\ncase trash pass\ncase file-write-publish pass\n" +
	"case mime pass\ncase file-snapshot pass\ncase app-logs pass\n" +
	"case file-lease pass\ncase window pass\ncase disk pass\n" +
	"case clock-epoch pass\ncase clock-set pass\nsummary cases=24 failed=0\n"

// seedFixtures is the host's half of the intake contract: IN/fixture.txt holds
// the canonical body, IN/altered.txt the altered one (ADR 0031 D2), and the
// M81g (#1767) snapshot case's four inputs live there too — the guest READS
// them, so a bundle built from constants rather than from the share would not
// match what the host seeded.
func seedFixtures(fs *fakeFS) {
	fs.files[intakePath] = []byte(intakeFixture)
	fs.files[alteredPath] = []byte(intakeAltered)
	fs.files[snapshotInSettings] = []byte(snapshotSettingsBody)
	fs.files[snapshotInSession] = []byte(snapshotSessionBody)
	fs.files[snapshotInNote] = []byte(snapshotNoteBody)
	fs.files[snapshotInSecond] = []byte(snapshotSecondBody)
}

func TestRunCasesAllPassAndReportBytes(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())

	if len(rs) != 24 {
		t.Fatalf("cases = %d, want 24", len(rs))
	}
	for _, r := range rs {
		if !r.ok {
			t.Fatalf("case %s failed: %s", r.id, r.detail)
		}
	}
	if got := string(renderReport(rs)); got != wantReport {
		t.Fatalf("report bytes:\n got %q\nwant %q", got, wantReport)
	}
	if got := string(renderSummary(rs)); got != "summary cases=24 failed=0\n" {
		t.Fatalf("summary = %q", got)
	}
	if got := fs.files[helloPath]; !bytes.Equal(got, []byte(helloPayload)) {
		t.Fatalf("hello.txt = %q, want %q", got, helloPayload)
	}
	trashWant := []byte("M81a trash fixture\n")
	if got := fs.files[trashCopyPath]; !bytes.Equal(got, trashWant) {
		t.Fatalf("trash.copy = %q, want %q", got, trashWant)
	}
	if got := fs.files[trashSourcePath]; !bytes.Equal(got, trashWant) {
		t.Fatalf("restored source = %q, want %q", got, trashWant)
	}
	if got := string(fs.files[trashReceiptPath]); got !=
		"case trash path=OUT/trash-source.txt bytes=19 match=yes restored=yes expiry=1 recent=delete,restore,delete\n" {
		t.Fatalf("trash receipt = %q", got)
	}
	if got := string(fs.files[vi.RecentLogPath]); !strings.Contains(got, "|restore|") ||
		strings.Count(got, "|delete|") != 2 {
		t.Fatalf("recent log missing expected actions: %q", got)
	}
	if !fs.dirs[outDir] {
		t.Fatal("the file-write case did not ensure OUT/ exists")
	}
	if got := string(fs.files[epochReceipt]); got !=
		"case clock-epoch epoch=1789043696 source=firmware\n" {
		t.Fatalf("epoch receipt = %q", got)
	}
}

// The intake case copies the bytes it READ into OUT/, and its receipt is the
// byte-exact line the spec requires. The copy is what the host compares, so a
// case that copied its own expectation instead of the read bytes fails here.
func TestIntakeCopiesTheBytesItRead(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())

	if !rs[0].ok || rs[0].id != "intake" {
		t.Fatalf("intake should have passed, got %+v", rs[0])
	}
	if got := fs.files[intakeCopy]; !bytes.Equal(got, []byte(intakeFixture)) {
		t.Fatalf("OUT/fixture.copy = %q, want %q", got, intakeFixture)
	}
	wantLine := "case intake path=IN/fixture.txt bytes=25 match=yes\n"
	if got := string(fs.files[intakeReceipt]); got != wantLine {
		t.Fatalf("intake receipt = %q, want %q", got, wantLine)
	}
	wantAltered := "case intake-altered path=IN/altered.txt bytes=25 differs=yes\n"
	if got := string(fs.files[alteredReceipt]); got != wantAltered {
		t.Fatalf("altered receipt = %q, want %q", got, wantAltered)
	}
	if got := fs.files[alteredCopy]; !bytes.Equal(got, []byte(intakeAltered)) {
		t.Fatalf("OUT/altered.copy = %q, want %q", got, intakeAltered)
	}
}

// A mutated seed must FAIL the intake case (ADR 0031 D2) — that is the whole
// point of reading the share instead of carrying a constant. The copy still
// holds what was read, so the host can see the mutation that failed it.
func TestIntakeFailsOnAMutatedSeed(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	// Swap the two intake fixtures: the canonical path now holds the
	// altered body and vice versa, which is the mutation the M61c
	// end-to-end rehearsal recorded on issue #1383. The M81g fixtures stay
	// as seeded so the snapshot case is not a third failure here.
	fs.files[intakePath] = []byte(intakeAltered)
	fs.files[alteredPath] = []byte(intakeFixture)
	rs := runCases(fs.syscalls())

	if rs[0].ok {
		t.Fatal("intake passed on a mutated seed")
	}
	if !strings.Contains(rs[0].detail, "fixture mismatch: got=25 want=25") {
		t.Fatalf("detail = %q", rs[0].detail)
	}
	// The altered case now sees the canonical bytes: an embedded constant
	// would report success here, the share read reports the truth.
	if rs[1].ok {
		t.Fatal("intake-altered passed while the share held the canonical bytes")
	}
	report := string(renderReport(rs))
	if !strings.Contains(report, "case intake fail fixture mismatch") {
		t.Fatalf("report lacks the intake failure: %q", report)
	}
	if !strings.Contains(report, "summary cases=24 failed=2") {
		t.Fatalf("report summary wrong: %q", report)
	}
	if got := fs.files[intakeCopy]; !bytes.Equal(got, []byte(intakeAltered)) {
		t.Fatalf("the copy is %q, want the mutated bytes", got)
	}
	wantLine := "case intake path=IN/fixture.txt bytes=25 match=no\n"
	if got := string(fs.files[intakeReceipt]); got != wantLine {
		t.Fatalf("intake receipt = %q, want %q", got, wantLine)
	}
}

// A missing fixture is a failed case with the open error as its detail, never
// a crash and never a skipped report (issue #1383 acceptance).
func TestIntakeFailsWhenTheFixtureIsMissing(t *testing.T) {
	fs := newFakeFS()
	// The M81g snapshot fixtures ARE seeded: this test is about the two
	// intake cases finding nothing, and the snapshot case reads IN/ too, so
	// leaving them out would fail a third case for an unrelated reason.
	seedFixtures(fs)
	delete(fs.files, intakePath)
	delete(fs.files, alteredPath)
	rs := runCases(fs.syscalls())

	if rs[0].ok || rs[0].id != "intake" {
		t.Fatalf("intake should have failed, got %+v", rs[0])
	}
	if !strings.Contains(rs[0].detail, "open rc=-6") {
		t.Fatalf("detail = %q", rs[0].detail)
	}
	if got := string(fs.files[alteredReceipt]); !strings.Contains(got, "bytes=0 err=open rc=-6") {
		t.Fatalf("altered receipt = %q", got)
	}
	// The report is still complete: 24 cases, the 2 intake ones failed (the
	// clock, file and window cases do not read IN/).
	report := string(renderReport(rs))
	if !strings.Contains(report, "summary cases=24 failed=2") {
		t.Fatalf("report summary wrong: %q", report)
	}
	if lines := strings.Count(report, "\n"); lines != len(rs)+1 {
		t.Fatalf("report has %d lines, want %d", lines, len(rs)+1)
	}
}

// ---------------------------------------------------------------------------
// M61e (#1385): the window receipt
// ---------------------------------------------------------------------------
// Cases are looked up by id (resultFor), not by index — the index map this
// comment used to carry was renumbered by every case M66a, M81b, M81e2 and
// M81g added.

// The receipt carries the KERNEL's geometry from the query, which is NOT what
// the app asked for at open: if the case restated its request, the w/h here
// would be the 640x400 the app opened with. The default fake's record is the
// real one — TABWM re-proposes the tab-aware content viewport at 180,0
// 1100x720 (tabwm's compute_tab_viewport), so the read-back must report that.
func TestWindowReceiptCarriesTheKernelsGeometry(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !resultFor(t, rs, "window").ok {
		t.Fatalf("window should have passed, got %+v", resultFor(t, rs, "window"))
	}
	wantLine := "case window win=2 w=1100 h=720 present=ok\n"
	if got := string(fs.files[windowReceipt]); got != wantLine {
		t.Fatalf("window receipt = %q, want %q", got, wantLine)
	}
	if winGotW == winReqW || winGotH == winReqH {
		t.Fatal("the fake's geometry equals the app's request — " +
			"the read-back distinction is not being exercised")
	}
}

// The case reports whatever the kernel says, for any geometry: this is a
// read-back, not a hardcoded expectation. A window the WM has not resized yet
// must still produce a receipt with its own numbers.
func TestWindowReceiptFollowsTheQueryWhereverItPoints(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.winGeometry = [8]uint32{32, 32, winReqW, winReqH, 0, 1, 1, 0}
	rs := runCases(fs.syscalls())
	if !resultFor(t, rs, "window").ok {
		t.Fatalf("window should have passed, got %+v", resultFor(t, rs, "window"))
	}
	wantLine := "case window win=2 w=640 h=400 present=ok\n"
	if got := string(fs.files[windowReceipt]); got != wantLine {
		t.Fatalf("window receipt = %q, want %q", got, wantLine)
	}
}

// A window that could not be opened is a FAILED case that names why — never a
// query of window 0, which the kernel would refuse as somebody else's.
func TestWindowFailsWithoutAWindow(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.winID = -1
	rs := runCases(fs.syscalls())
	if resultFor(t, rs, "window").ok {
		t.Fatalf("window passed with no window, got %+v", resultFor(t, rs, "window"))
	}
	if !strings.Contains(resultFor(t, rs, "window").detail, "no window") {
		t.Fatalf("detail = %q", resultFor(t, rs, "window").detail)
	}
	if _, ok := fs.files[windowReceipt]; ok {
		t.Fatal("a window-less run still wrote a receipt")
	}
}

// Every window row's refusal is named, so a failure says which call refused.
func TestWindowNamesEachRefusal(t *testing.T) {
	for _, tc := range []struct {
		name   string
		break_ func(*fakeFS)
		want   string
	}{
		{"fill", func(f *fakeFS) { f.winFillErr = true }, "fill rc=-1"},
		{"present", func(f *fakeFS) { f.winPresentErr = true }, "present rc=-1"},
		{"query", func(f *fakeFS) { f.winQueryErr = true }, "query rc=-1"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fs := newFakeFS()
			seedFixtures(fs)
			tc.break_(fs)
			rs := runCases(fs.syscalls())
			if resultFor(t, rs, "window").ok {
				t.Fatalf("window passed with %s refused, got %+v", tc.name, resultFor(t, rs, "window"))
			}
			if !strings.Contains(resultFor(t, rs, "window").detail, tc.want) {
				t.Fatalf("detail = %q, want %q", resultFor(t, rs, "window").detail, tc.want)
			}
		})
	}
}

// A zero-geometry window is caught by the READ-BACK even though the fill and
// the present both returned success: that is the read-back earning its keep.
func TestWindowCatchesAnEmptyWindow(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.winGeometry = [8]uint32{0, 0, 0, 0, 0, 1, 1, 0}
	rs := runCases(fs.syscalls())
	if resultFor(t, rs, "window").ok {
		t.Fatalf("window passed on an empty window, got %+v", resultFor(t, rs, "window"))
	}
	if !strings.Contains(resultFor(t, rs, "window").detail, "query reports an empty window: 0x0") {
		t.Fatalf("detail = %q", resultFor(t, rs, "window").detail)
	}
	// The receipt still holds what was measured, so the host sees the zeros.
	if got := string(fs.files[windowReceipt]); got != "case window win=2 w=0 h=0 present=ok\n" {
		t.Fatalf("window receipt = %q", got)
	}
}

// The #1391 shape — the right length of zeros — is named in the case detail
// rather than reported as a bare mismatch, so a future flake says what it was.
func TestIntakeNamesZerosReads(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.zeroRead = true
	rs := runCases(fs.syscalls())

	if rs[0].ok {
		t.Fatalf("intake passed on a zeros read, got %+v", rs[0])
	}
	if !strings.Contains(rs[0].detail, "25B of zeros (issue #1391)") {
		t.Fatalf("detail = %q", rs[0].detail)
	}
}

// A zeros read must fail the NEGATIVE case too: while issue #1391 was live,
// `intake-altered` PASSED on 25 bytes of zeros because zeros do differ from
// the canonical body. That is a wrong answer reported as a verdict, so the
// negative check requires a body (right length, not all zeros) as well.
func TestAlteredCaseFailsOnAZerosRead(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.zeroRead = true
	rs := runCases(fs.syscalls())

	if rs[1].ok {
		t.Fatalf("intake-altered passed on a zeros read, got %+v", rs[1])
	}
	if !strings.Contains(rs[1].detail, "not a body: 25B of zeros") {
		t.Fatalf("detail = %q", rs[1].detail)
	}
}

// readFile is the intake/read-back substrate for M61c/M61d; M61b's cases do
// not read yet, so it is exercised directly here (including the failure path
// the guest must not paper over — see issue #1391).
func TestReadFileReturnsTheWholeFile(t *testing.T) {
	fs := newFakeFS()
	s := fs.syscalls()
	if _, err := writeFile(s, helloPath, []byte(helloPayload)); err != nil {
		t.Fatalf("writeFile: %v", err)
	}
	got, err := readFile(s, helloPath, 4096)
	if err != nil {
		t.Fatalf("readFile: %v", err)
	}
	if string(got) != helloPayload {
		t.Fatalf("readFile = %q, want %q", got, helloPayload)
	}
}

func TestReadFileSurfacesACorruptReadback(t *testing.T) {
	fs := newFakeFS()
	s := fs.syscalls()
	if _, err := writeFile(s, helloPath, []byte(helloPayload)); err != nil {
		t.Fatalf("writeFile: %v", err)
	}
	fs.corruptRead = true
	got, err := readFile(s, helloPath, 4096)
	if err != nil {
		t.Fatalf("readFile: %v", err)
	}
	if string(got) == helloPayload {
		t.Fatal("corrupt readback compared equal — the fake did not corrupt")
	}
}

func TestFileWriteCaseFailsWhenTheWriteIsRefused(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.denyPath = helloPath
	rs := runCases(fs.syscalls())

	if rs[3].id != "file-write" || rs[3].ok {
		t.Fatalf("file-write should have failed, got %+v", rs[3])
	}
	report := string(renderReport(rs))
	if !strings.Contains(report, "case file-write fail ") {
		t.Fatalf("report lacks the fail detail: %q", report)
	}
	if !strings.Contains(report, "summary cases=24 failed=1") {
		t.Fatalf("report summary wrong: %q", report)
	}
}

func TestClockCaseFailsWhenTheClockStandsStill(t *testing.T) {
	fs := newFakeFS()
	fs.frozenClock = true
	rs := runCases(fs.syscalls())

	if rs[2].id != "clock-monotonic" || rs[2].ok {
		t.Fatalf("clock-monotonic should have failed, got %+v", rs[2])
	}
	if !strings.Contains(rs[2].detail, "clock did not advance") {
		t.Fatalf("detail = %q", rs[2].detail)
	}
}

func TestEpochCaseNamesMissingFirmwareTime(t *testing.T) {
	fs := newFakeFS()
	fs.epoch = -vi.ErrENOSYS
	rs := runCases(fs.syscalls())
	if got := resultFor(t, rs, "clock-epoch"); !got.ok {
		t.Fatalf("missing firmware clock should be an honest fallback: %+v", got)
	}
	if got := string(fs.files[epochReceipt]); got != "case clock-epoch unavailable fallback=monotonic\n" {
		t.Fatalf("no-epoch receipt = %q", got)
	}
}

func TestEpochCaseRejectsOtherKernelErrors(t *testing.T) {
	fs := newFakeFS()
	fs.epoch = -vi.ErrEFAULT
	rs := runCases(fs.syscalls())
	got := resultFor(t, rs, "clock-epoch")
	if got.ok || got.detail != "epoch rc=-3" {
		t.Fatalf("clock error must fail the case: %+v", got)
	}
}

// M83b (#1775): the clock-set case — four refusals, one real step, one exact
// restore, and a receipt that says so. The boot clock is what the rest of the
// run (and the host's bound on clock-epoch) still sees afterward.
func TestClockSetCaseRefusesStepsAndRestores(t *testing.T) {
	fs := newFakeFS()
	boot := fs.epoch
	rs := runCases(fs.syscalls())
	if got := resultFor(t, rs, "clock-set"); !got.ok {
		t.Fatalf("clock-set failed: %s", got.detail)
	}
	if got := string(fs.files[clockSetReceipt]); got != "case clock-set refused=4 stepped=+100 restored=yes\n" {
		t.Fatalf("clock-set receipt = %q", got)
	}
	want := []int64{0, -1, clockSetMin - 1, clockSetMax + 1, boot + 100, boot}
	if len(fs.setCalls) != len(want) {
		t.Fatalf("set calls = %v, want %v", fs.setCalls, want)
	}
	for i := range want {
		if fs.setCalls[i] != want[i] {
			t.Fatalf("set call %d = %d, want %d (all: %v)", i, fs.setCalls[i], want[i], fs.setCalls)
		}
	}
	if fs.epoch != boot {
		t.Fatalf("clock left at %d, boot reading was %d", fs.epoch, boot)
	}
	// clock-epoch ran first, so its receipt is the untouched boot value.
	if got := string(fs.files[epochReceipt]); got != "case clock-epoch epoch=1789043696 source=firmware\n" {
		t.Fatalf("epoch receipt = %q", got)
	}
}

func TestClockSetCaseCatchesAKernelThatAcceptsAnyEpoch(t *testing.T) {
	fs := newFakeFS()
	fs.setNoRange = true
	got := resultFor(t, runCases(fs.syscalls()), "clock-set")
	if got.ok || !strings.Contains(got.detail, "set 0 rc=0") {
		t.Fatalf("an out-of-range set that succeeds must fail the case: %+v", got)
	}
}

func TestClockSetCaseCatchesASetThatDoesNothing(t *testing.T) {
	fs := newFakeFS()
	boot := fs.epoch
	fs.setLies = true
	got := resultFor(t, runCases(fs.syscalls()), "clock-set")
	if got.ok || !strings.Contains(got.detail, "read-back after set") {
		t.Fatalf("a set that reports success and changes nothing must fail: %+v", got)
	}
	if fs.epoch != boot {
		t.Fatalf("the failing case moved the clock to %d", fs.epoch)
	}
}

func TestClockSetCaseRestoresTheClockEvenWhenReadBackIsWrong(t *testing.T) {
	fs := newFakeFS()
	boot := fs.epoch
	// A kernel that steps to the wrong value: the case must fail AND hand the
	// run its boot clock back, not leave it a minute off.
	calls := 0
	sc := fs.syscalls()
	sc.setEpoch = func(e int64) int64 {
		calls++
		if e == boot+clockSetStep {
			fs.epoch = e + 60
			return 0
		}
		return fs.setEpoch(e)
	}
	got := resultFor(t, runCases(sc), "clock-set")
	if got.ok || !strings.Contains(got.detail, "read-back after set") {
		t.Fatalf("a wrong read-back must fail the case: %+v", got)
	}
	if fs.epoch != boot {
		t.Fatalf("clock left at %d, want the boot reading %d", fs.epoch, boot)
	}
}

func TestClockSetCaseNamesAKernelThatRefusesTheStep(t *testing.T) {
	fs := newFakeFS()
	sc := fs.syscalls()
	sc.setEpoch = func(e int64) int64 {
		if e >= clockSetMin && e <= clockSetMax {
			return -vi.ErrEACCES
		}
		return -vi.ErrEINVAL
	}
	got := resultFor(t, runCases(sc), "clock-set")
	if got.ok || !strings.Contains(got.detail, "rc=-") {
		t.Fatalf("a refused step must fail the case: %+v", got)
	}
}

func TestClockSetCaseOnANoEpochBootOnlyChecksRefusals(t *testing.T) {
	fs := newFakeFS()
	fs.epoch = -vi.ErrENOSYS
	rs := runCases(fs.syscalls())
	if got := resultFor(t, rs, "clock-set"); !got.ok {
		t.Fatalf("a no-epoch boot should pass on the refusals alone: %+v", got)
	}
	if got := string(fs.files[clockSetReceipt]); got != "case clock-set refused=4 step=skipped reason=no-epoch\n" {
		t.Fatalf("no-epoch receipt = %q", got)
	}
	if len(fs.setCalls) != 4 {
		t.Fatalf("set calls = %v, want only the four refusals", fs.setCalls)
	}
	if fs.epoch != -vi.ErrENOSYS {
		t.Fatalf("the case gave a no-epoch boot a clock: %d", fs.epoch)
	}
}

// M81d (#1764): the lease drill runs its full sequence against the scripted
// rows — acquire, the foreign refusal, both takeovers, the release rules.
// The scripts mirror the drill's exact call order; the vi rules behind each
// verdict are pinned in vi's own suite and proven live by the gate.
func TestFileLeaseCaseRunsTheDrill(t *testing.T) {
	fs := newFakeFS()
	rs := runCases(fs.syscalls())

	r := resultFor(t, rs, "file-lease")
	if !r.ok {
		t.Fatalf("file-lease failed: %s", r.detail)
	}
	if fs.leaseAcqCalls != 4 || fs.leaseChkCalls != 3 || fs.leaseRelCalls != 2 {
		t.Fatalf("call counts acq=%d chk=%d rel=%d, want 4/3/2",
			fs.leaseAcqCalls, fs.leaseChkCalls, fs.leaseRelCalls)
	}
	receipt := string(fs.files[leaseOk])
	if !strings.Contains(receipt, "case file-lease dir=LEASES clock=yes") ||
		!strings.Contains(receipt, "stale-takeover=ok dead-holder=ok") {
		t.Fatalf("receipt = %q", receipt)
	}
	if got := fs.files[leaseCopy]; !strings.Contains(string(got), "token="+leaseForeignToken) {
		t.Fatalf("stale copy = %q", got)
	}
}

// A refused first acquire is the case's failure, named by its detail.
func TestFileLeaseCaseFailsWhenAcquireIsRefused(t *testing.T) {
	fs := newFakeFS()
	fs.leaseDenyAcquire = true
	rs := runCases(fs.syscalls())

	r := resultFor(t, rs, "file-lease")
	if r.ok {
		t.Fatal("file-lease should have failed under a denied acquire")
	}
	if !strings.Contains(r.detail, "acquire rc=-11") {
		t.Fatalf("detail = %q", r.detail)
	}
}

func TestFileWriteCaseDetailNamesTheOpenFailure(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.denyPath = helloPath
	rs := runCases(fs.syscalls())

	if rs[3].ok {
		t.Fatalf("file-write should have failed, got %+v", rs[3])
	}
	if !strings.Contains(rs[3].detail, "open rc=-2") {
		t.Fatalf("detail = %q", rs[3].detail)
	}
}

func TestWriteFileLoopsUntilEveryByteLands(t *testing.T) {
	fs := newFakeFS()
	fs.shortWrite = true
	payload := []byte("goself smoke\n")
	n, err := writeFile(fs.syscalls(), helloPath, payload)
	if err != nil {
		t.Fatalf("writeFile: %v", err)
	}
	if n != len(payload) {
		t.Fatalf("wrote %d bytes, want %d", n, len(payload))
	}
	if got := fs.files[helloPath]; !bytes.Equal(got, payload) {
		t.Fatalf("hello.txt = %q, want %q", got, payload)
	}
}

// The report is deterministic (ADR 0031): two runs at different clock values
// render byte-identical bytes, which is what lets the host byte-compare it.
func TestReportIsDeterministicAcrossRuns(t *testing.T) {
	a, b := newFakeFS(), newFakeFS()
	seedFixtures(a)
	seedFixtures(b)
	b.clock = 999999
	ra, rb := runCases(a.syscalls()), runCases(b.syscalls())
	if !bytes.Equal(renderReport(ra), renderReport(rb)) {
		t.Fatalf("report changed between runs:\n%q\n%q", renderReport(ra), renderReport(rb))
	}
}

func TestCaseIDsAreUniqueAndContractShaped(t *testing.T) {
	shape := regexp.MustCompile(`^[a-z0-9-]+$`)
	seen := map[string]bool{}
	for _, c := range cases() {
		if !shape.MatchString(c.id) {
			t.Fatalf("case id %q is not [a-z0-9-]+", c.id)
		}
		if seen[c.id] {
			t.Fatalf("duplicate case id %q", c.id)
		}
		seen[c.id] = true
	}
}

// The serial contract is one FAIL line plus OK only on a clean run, and the
// count it carries is the report's failed count.
func TestSerialSummaryCarriesTheReportCount(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if got := failed(rs); got != 0 {
		t.Fatalf("failed = %d", got)
	}
	if got := strings.TrimSpace(string(renderSummary(rs))); got != summaryLine(rs) {
		t.Fatalf("summary file %q disagrees with summaryLine %q", got, summaryLine(rs))
	}
	lines := serialSummary(0)
	if len(lines) != 2 || lines[0] != "selftest: FAIL n=0" || lines[1] != "selftest OK" {
		t.Fatalf("serialSummary(0) = %q", lines)
	}
	// The report's last line is the same count line (the two files agree).
	report := string(renderReport(rs))
	if !strings.HasSuffix(report, summaryLine(rs)+"\n") {
		t.Fatalf("report does not end on the summary line: %q", report)
	}
	failing := serialSummary(1)
	if len(failing) != 1 || failing[0] != "selftest: FAIL n=1" {
		t.Fatalf("serialSummary(1) = %q", failing)
	}
}

func TestOneLineBoundsAndFlattensDetails(t *testing.T) {
	if got := oneLine("read\nback\rfailed\there"); got != "read back failed here" {
		t.Fatalf("oneLine = %q", got)
	}
	long := strings.Repeat("x", 200)
	if got := oneLine(long); len(got) != 48 {
		t.Fatalf("oneLine length = %d, want 48", len(got))
	}
	// A detail can never add a line to the report.
	fs := newFakeFS()
	seedFixtures(fs)
	fs.denyPath = helloPath
	rs := runCases(fs.syscalls())
	report := string(renderReport(rs))
	if got := strings.Count(report, "\n"); got != len(rs)+1 {
		t.Fatalf("report has %d lines, want %d", got, len(rs)+1)
	}
	for _, line := range strings.Split(strings.TrimSuffix(report, "\n"), "\n") {
		if !strings.HasPrefix(line, "case ") && !strings.HasPrefix(line, "summary ") {
			t.Fatalf("report line %q is outside the grammar", line)
		}
	}
}

// ---------------------------------------------------------------------------
// M61d (#1384): the file-ABI pack
// ---------------------------------------------------------------------------
//
// Index map after M61d: 0 intake · 1 intake-altered · 2 clock-monotonic ·
// (the window cases below now use resultFor by id, not an index)
// 3 file-write · 4 file-roundtrip · 5 file-truncate · 6 file-delete ·
// 7 file-list.

func TestFileRoundtripCopiesTheBytesItRead(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !rs[4].ok || rs[4].id != "file-roundtrip" {
		t.Fatalf("file-roundtrip should have passed, got %+v", rs[4])
	}
	want := roundtripPayload()
	if len(want) != 525 {
		t.Fatalf("roundtrip payload = %d B, want 525 (25 units)", len(want))
	}
	if got := fs.files[roundtripPath]; !bytes.Equal(got, want) {
		t.Fatalf("roundtrip.txt = %q, want %q", got, want)
	}
	// The copy holds what was READ, not what was written: a write that
	// reported success without landing, or a read that invented bytes, cannot
	// pass the host's byte comparison.
	if got := fs.files[roundtripCopy]; !bytes.Equal(got, want) {
		t.Fatalf("roundtrip.copy = %q, want %q", got, want)
	}
	wantLine := "case file-roundtrip path=OUT/roundtrip.txt bytes=525 match=yes\n"
	if got := string(fs.files[roundtripOk]); got != wantLine {
		t.Fatalf("roundtrip receipt = %q, want %q", got, wantLine)
	}
}

// The #1391 shape is named by the round-trip case too: the right length of
// zeros is a lost kernel->user copy, not a byte mismatch — and the copy still
// holds the zeros, so the host sees what the app saw.
func TestFileRoundtripNamesAZerosRead(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.zeroRead = true
	rs := runCases(fs.syscalls())
	if rs[4].ok {
		t.Fatalf("file-roundtrip passed on a zeros read, got %+v", rs[4])
	}
	if !strings.Contains(rs[4].detail, "525B of zeros (issue #1391)") {
		t.Fatalf("detail = %q", rs[4].detail)
	}
	if got := fs.files[roundtripCopy]; len(got) != 525 || !isAllZero(got) {
		t.Fatalf("roundtrip.copy = %d B (all zero: %v), want 525 zero bytes", len(got), isAllZero(got))
	}
}

func TestFileTruncateKeepsThePrefix(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !rs[5].ok || rs[5].id != "file-truncate" {
		t.Fatalf("file-truncate should have passed, got %+v", rs[5])
	}
	kept := truncateKept()
	if len(kept) != 105 {
		t.Fatalf("kept prefix = %d B, want 105 (5 units)", len(kept))
	}
	if got := fs.files[truncatedCopy]; !bytes.Equal(got, kept) {
		t.Fatalf("truncated.copy = %q, want %q", got, kept)
	}
	if got := fs.files[truncatePath]; !bytes.Equal(got, kept) {
		t.Fatalf("truncate.txt = %q, want the kept prefix", got)
	}
	wantLine := "case file-truncate path=OUT/truncate.txt wrote=840 kept=105 bytes=105 match=yes\n"
	if got := string(fs.files[truncateOk]); got != wantLine {
		t.Fatalf("truncate receipt = %q, want %q", got, wantLine)
	}
}

// A refused truncate fails the case and names the code: the case keeps ONE
// write handle, so a refusal is the ABI rejecting a legitimate shrink, not the
// replace-on-open semantics the case deliberately avoids.
func TestFileTruncateFailsWhenTheAbiRefuses(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.denyTruncate = true
	rs := runCases(fs.syscalls())
	if rs[5].ok {
		t.Fatalf("file-truncate passed with a refused truncate, got %+v", rs[5])
	}
	if !strings.Contains(rs[5].detail, "truncate rc=-7") {
		t.Fatalf("detail = %q", rs[5].detail)
	}
}

func TestFileDeleteProvesThePathIsGone(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !rs[6].ok || rs[6].id != "file-delete" {
		t.Fatalf("file-delete should have passed, got %+v", rs[6])
	}
	if _, exists := fs.files[deletePath]; exists {
		t.Fatal("deleted.txt survived the case")
	}
	wantLine := "case file-delete path=OUT/deleted.txt delete=0 reopen=-6\n"
	if got := string(fs.files[deleteOk]); got != wantLine {
		t.Fatalf("delete receipt = %q, want %q", got, wantLine)
	}
}

// A delete that reports success without removing the file must FAIL: the
// reopen failing is the only evidence the case accepts.
func TestFileDeleteCatchesALyingDelete(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.lieDelete = true
	rs := runCases(fs.syscalls())
	if rs[6].ok {
		t.Fatalf("file-delete passed while the file survived, got %+v", rs[6])
	}
	if !strings.Contains(rs[6].detail, "open after delete succeeded") {
		t.Fatalf("detail = %q", rs[6].detail)
	}
}

func TestFileListSeesThenDoesNotSee(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !rs[7].ok || rs[7].id != "file-list" {
		t.Fatalf("file-list should have passed, got %+v", rs[7])
	}
	if _, exists := fs.files[listedPath]; exists {
		t.Fatal("listed.txt survived the case")
	}
	wantLine := "case file-list dir=OUT/LIST file=listed.txt first=seen second=absent\n"
	if got := string(fs.files[listOk]); got != wantLine {
		t.Fatalf("list receipt = %q, want %q", got, wantLine)
	}
}

// A listing that keeps reporting a deleted name is a wrong answer: the case
// fails, and the detail names what it saw.
func TestFileListCatchesAStaleListing(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.listStale = true
	rs := runCases(fs.syscalls())
	if rs[7].ok {
		t.Fatalf("file-list passed on a stale listing, got %+v", rs[7])
	}
	if !strings.Contains(rs[7].detail, "listing still shows listed.txt") {
		t.Fatalf("detail = %q", rs[7].detail)
	}
}

// Every M61d case leaves a receipt: the host reads one file per case instead
// of grepping a transcript, and the receipt is exactly one `case …` line.
func TestEveryM61dCaseWritesAReceipt(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	runCases(fs.syscalls())
	for _, path := range []string{writeOk, roundtripOk, truncateOk, deleteOk, listOk} {
		got, ok := fs.files[path]
		if !ok {
			t.Fatalf("receipt %s missing", path)
		}
		line := string(got)
		if !strings.HasPrefix(line, "case ") || strings.Count(line, "\n") != 1 || !strings.HasSuffix(line, "\n") {
			t.Fatalf("receipt %s = %q, want one 'case …' line", path, line)
		}
	}
}

// The MODE_DIR row needs MODE_WRITE|MODE_CREATE together (file_table.open
// validates them as a triple): a bare MODE_DIR is EINVAL, which is what the
// guest's mkdir helper used to send — so the app never actually created a
// directory and only the spec's host-side makedirs made OUT/ exist. The fake
// enforces the kernel's rule, so a regression here fails off-guest.
func TestMkdirRowNeedsCreateAndWrite(t *testing.T) {
	fs := newFakeFS()
	if _, rc := fs.open(listDir, flagModeDir); rc != -1 {
		t.Fatalf("bare MODE_DIR rc = %d, want -1 (EINVAL)", rc)
	}
	if _, rc := fs.open(listDir, flagModeWrite|flagModeCreate|flagModeDir); rc != 0 {
		t.Fatalf("MODE_WRITE|MODE_CREATE|MODE_DIR rc = %d, want 0", rc)
	}
	if !fs.dirs[listDir] {
		t.Fatal("the triple did not create the directory")
	}
	if _, rc := fs.open(listDir, flagModeWrite|flagModeCreate|flagModeDir); rc != -9 {
		t.Fatalf("second create rc = %d, want -9 (EEXIST)", rc)
	}
}

// ---------------------------------------------------------------------------
// M66a (#1443): the file-semantics hardening pack
// ---------------------------------------------------------------------------
//
// Cases are looked up by id (resultFor), not by index — the index map this
// comment used to carry was renumbered by every case M66a, M81b, M81e2 and
// M81g added.

// Append-at-EOF: the reopened append write lands AFTER the base body. If the
// append flag were dropped anywhere below the ABI, the open would replace
// the file and the read-back would be the delta alone — which this catches.
func TestFileAppendLandsAfterTheBase(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !rs[8].ok || rs[8].id != "file-append" {
		t.Fatalf("file-append should have passed, got %+v", rs[8])
	}
	want := append(append([]byte{}, appendBasePayload()...), appendMorePayload()...)
	if len(want) != 105 {
		t.Fatalf("append body = %d B, want 105 (3+2 units)", len(want))
	}
	if got := fs.files[appendPath]; !bytes.Equal(got, want) {
		t.Fatalf("append.txt = %d B, want base+more", len(got))
	}
	if got := fs.files[appendCopy]; !bytes.Equal(got, want) {
		t.Fatalf("append.copy diverges from the read-back")
	}
	wantLine := "case file-append path=OUT/append.txt base=63 more=42 bytes=105 match=yes\n"
	if got := string(fs.files[appendOk]); got != wantLine {
		t.Fatalf("append receipt = %q, want %q", got, wantLine)
	}
}

// An append-open must NOT apply the replace semantics: the body written
// before the append-open has to survive byte-for-byte.
func TestFileAppendOpenKeepsTheBody(t *testing.T) {
	fs := newFakeFS()
	base := []byte("base body\n")
	if _, err := writeFile(fs.syscalls(), appendPath, base); err != nil {
		t.Fatalf("writeFile: %v", err)
	}
	h, rc := fs.open(appendPath, flagModeWrite|flagModeAppend)
	if rc < 0 {
		t.Fatalf("append open rc = %d", rc)
	}
	if got := fs.files[appendPath]; !bytes.Equal(got, base) {
		t.Fatalf("append-open replaced the body: %q", got)
	}
	n, rc2 := fs.write(uint32(h), []byte("more\n"))
	if rc2 < 0 || n != 5 {
		t.Fatalf("append write = %d, %d", n, rc2)
	}
	fs.syscalls().close(uint32(h))
	want := append(append([]byte{}, base...), []byte("more\n")...)
	if got := fs.files[appendPath]; !bytes.Equal(got, want) {
		t.Fatalf("append.txt = %q, want %q", got, want)
	}
}

// The big write is far beyond one sys_file_write call: it only lands through
// the confirmed-count chunk loop, and the read-back must be byte-exact.
func TestFileBigwriteChunksThroughTheStageCap(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !rs[9].ok || rs[9].id != "file-bigwrite" {
		t.Fatalf("file-bigwrite should have passed, got %+v", rs[9])
	}
	want := bigwritePayload()
	if len(want) != 73500 {
		t.Fatalf("bigwrite payload = %d B, want 73500 (3500 units)", len(want))
	}
	if got := fs.files[bigwritePath]; !bytes.Equal(got, want) {
		t.Fatalf("bigwrite.txt = %d B, want the payload", len(got))
	}
	if got := fs.files[bigwriteCopy]; !bytes.Equal(got, want) {
		t.Fatalf("bigwrite.copy diverges from the read-back")
	}
	wantLine := "case file-bigwrite path=OUT/bigwrite.txt bytes=73500 calls=36 match=yes\n"
	if got := string(fs.files[bigwriteOk]); got != wantLine {
		t.Fatalf("bigwrite receipt = %q, want %q", got, wantLine)
	}
}

// The fake enforces the kernel's 2048-byte stage cap, so a writeAll that
// stopped chunking would fail every case with a payload over the cap — and
// a raw writeAll call with a 3000-byte body must surface the refusal.
func TestWriteAllRespectsTheStageCap(t *testing.T) {
	fs := newFakeFS()
	err := writeAll(fs.syscalls(), 1, make([]byte, 3000))
	if err == nil || !strings.Contains(err.Error(), "write rc=-2") {
		// handle 1 is not open: the loop's first call hits EBADF before the
		// cap matters — the point is that a refusal surfaces, not a spin.
		t.Fatalf("writeAll on a dead handle = %v, want a write rc error", err)
	}
	s := fs.syscalls()
	h, rc := s.open("cap.txt", flagModeWrite|flagModeCreate)
	if rc < 0 {
		t.Fatalf("open rc = %d", rc)
	}
	if err := writeAll(s, uint32(h), make([]byte, 3000)); err != nil {
		t.Fatalf("writeAll: %v", err)
	}
	s.close(uint32(h))
	if got := fs.files["cap.txt"]; len(got) != 3000 {
		t.Fatalf("cap.txt = %d B, want 3000", len(got))
	}
}

// The clamp: write, shrink the SAME handle, write more — the extra lands at
// the clamp point, so the file is kept+extra and nothing else.
func TestFileClampWriteLandsAtTheClampPoint(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !rs[10].ok || rs[10].id != "file-clamp" {
		t.Fatalf("file-clamp should have passed, got %+v", rs[10])
	}
	want := append(append([]byte{}, clampKept()...), clampExtra()...)
	if len(want) != 168 {
		t.Fatalf("clamped body = %d B, want 168 (5+3 units)", len(want))
	}
	if got := fs.files[clampPath]; !bytes.Equal(got, want) {
		t.Fatalf("clamp.txt = %d B, want kept+extra", len(got))
	}
	if got := fs.files[clampCopy]; !bytes.Equal(got, want) {
		t.Fatalf("clamp.copy diverges from the read-back")
	}
	wantLine := "case file-clamp path=OUT/clamp.txt wrote=840 kept=105 extra=63 bytes=168 match=yes\n"
	if got := string(fs.files[clampOk]); got != wantLine {
		t.Fatalf("clamp receipt = %q, want %q", got, wantLine)
	}
}

// A refused truncate fails the clamp case too — the extra write must not
// happen after a shrink that never landed.
func TestFileClampFailsWhenTheShrinkIsRefused(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.denyTruncate = true
	rs := runCases(fs.syscalls())
	if rs[10].ok {
		t.Fatalf("file-clamp passed with a refused shrink, got %+v", rs[10])
	}
	if !strings.Contains(rs[10].detail, "truncate rc=-7") {
		t.Fatalf("detail = %q", rs[10].detail)
	}
}

// The durability verb: fsync on the open handle is 0, on the closed fd is
// the honest EBADF, and a host refusal fails the case by its code.
func TestFileFsyncRefusesAClosedFd(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !rs[11].ok || rs[11].id != "file-fsync" {
		t.Fatalf("file-fsync should have passed, got %+v", rs[11])
	}
	if got := fs.files[fsyncPath]; !bytes.Equal(got, fsyncPayload()) {
		t.Fatalf("fsync.txt = %d B, want the payload", len(got))
	}
	wantLine := "case file-fsync path=OUT/fsync.txt bytes=147 fsync=0 closed=-2\n"
	if got := string(fs.files[fsyncOk]); got != wantLine {
		t.Fatalf("fsync receipt = %q, want %q", got, wantLine)
	}

	fs2 := newFakeFS()
	seedFixtures(fs2)
	fs2.failSync = true
	rs2 := runCases(fs2.syscalls())
	if rs2[11].ok {
		t.Fatal("file-fsync passed while the host refused the sync")
	}
	if !strings.Contains(rs2[11].detail, "fsync rc=-1") {
		t.Fatalf("detail = %q", rs2[11].detail)
	}
}

// The honest error rows, each observed through the fake's kernel-shaped ABI.
func TestFileErrorsRowsAreHonest(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !rs[12].ok || rs[12].id != "file-errors" {
		t.Fatalf("file-errors should have passed, got %+v", rs[12])
	}
	wantLine := "case file-errors missing=-6 exists=-9 isdir=-1 ninth=-5\n"
	if got := string(fs.files[errOk]); got != wantLine {
		t.Fatalf("errors receipt = %q, want %q", got, wantLine)
	}
	// The probe handles and files are cleaned up: only the receipt remains.
	for _, p := range fs.handles {
		t.Fatalf("handle still open on %s", p)
	}
	for name := range fs.files {
		if strings.HasPrefix(name, errDir+"/h") {
			t.Fatalf("probe file %s survived", name)
		}
	}
}

// Every M66a case leaves a receipt, one `case …` line each.
func TestEveryM66aCaseWritesAReceipt(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	runCases(fs.syscalls())
	for _, path := range []string{appendOk, bigwriteOk, clampOk, fsyncOk, errOk} {
		got, ok := fs.files[path]
		if !ok {
			t.Fatalf("receipt %s missing", path)
		}
		line := string(got)
		if !strings.HasPrefix(line, "case ") || strings.Count(line, "\n") != 1 || !strings.HasSuffix(line, "\n") {
			t.Fatalf("receipt %s = %q, want one 'case …' line", path, line)
		}
	}
}

// fakeWriteSafe models vi.WriteFileSafe's ORDER — temp, fsync, delete target,
// rename — so a case that depends on the sequence is testable without the
// kernel. The knobs fail the same way the real publish does: a refused write
// or a refused fsync leaves the target as it was (vi.WriteFileSafe removes the
// temp on every failure and never touches the live file before the rename).
func (f *fakeFS) writeSafe(path string, b []byte) int64 {
	tmp := path + "~"
	if f.denyWrite || (f.denyPath != "" && (f.denyPath == path || f.denyPath == tmp)) {
		return -2
	}
	f.files[tmp] = append([]byte(nil), b...)
	if f.failSync {
		delete(f.files, tmp)
		return -1
	}
	f.files[path] = f.files[tmp]
	delete(f.files, tmp)
	return 0
}

// fakePublish models vi.WriteFilePublish's TWO contracts over the fake
// filesystem: a replace takes the writeSafe order (temp, fsync, rename), and
// an append adds to the live file in place. Modelling them separately is the
// point — a fake that implemented both as "writeSafe" would let a case that
// rewrote the whole file per append pass, which is exactly the regression
// M81e2's append half exists to catch.
func (f *fakeFS) publish(path string, b []byte, appendMode bool) int64 {
	if appendMode {
		if f.denyWrite || (f.denyPath != "" && f.denyPath == path) {
			return -13
		}
		f.files[path] = append(append([]byte(nil), f.files[path]...), b...)
		return 0
	}
	return f.writeSafe(path, b)
}

// publishFn is the seam syscalls() binds: the honest fake unless a test has
// installed an override.
func (f *fakeFS) publishFn() func(string, []byte, bool) int64 {
	if f.publishOverride != nil {
		return f.publishOverride
	}
	return f.publish
}

// M81e (#1765): a shorter publish leaves no tail, the temp does not survive,
// and the bytes the host compares are the bytes the case published.
func TestFileWriteSafeReplacesWholeAndLeavesNoTemp(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	var r result
	idx := -1
	for i, c := range rs {
		if c.id == "file-write-safe" {
			r, idx = c, i
		}
	}
	if idx < 0 || !r.ok {
		t.Fatalf("file-write-safe should have passed, got %+v", r)
	}
	if idx != 13 {
		t.Fatalf("file-write-safe is case %d, want 13 (before window)", idx)
	}
	short := writeSafeShort()
	if got := fs.files[writeSafeCopy]; !bytes.Equal(got, short) {
		t.Fatalf("write-safe.copy = %d B, want the %d B short body", len(got), len(short))
	}
	if got := fs.files[writeSafePath]; !bytes.Equal(got, short) {
		t.Fatalf("write-safe.txt = %d B, want the %d B short body (no tail)", len(got), len(short))
	}
	if _, ok := fs.files[writeSafeTmp]; ok {
		t.Fatalf("the sacrificial temp %s survived the publish", writeSafeTmp)
	}
	want := "case file-write-safe path=OUT/write-safe.txt long=840 short=105 bytes=105 tail=none orphan=none match=yes\n"
	if got := string(fs.files[writeSafeOk]); got != want {
		t.Fatalf("write-safe receipt = %q, want %q", got, want)
	}
}

// A refused publish is loud and leaves the PREVIOUS file alone: that is the
// property an in-place writer cannot offer — its live file is already
// truncated by the time anything can fail.
func TestFileWriteSafeFailureKeepsTheOldBody(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.failSync = true
	rs := runCases(fs.syscalls())
	for _, c := range rs {
		if c.id == "file-write-safe" {
			if c.ok {
				t.Fatalf("file-write-safe passed with a refused fsync, got %+v", c)
			}
			if !strings.Contains(c.detail, "publish rc=-1") {
				t.Fatalf("detail = %q, want the refused publish named", c.detail)
			}
			if _, ok := fs.files[writeSafePath]; ok {
				t.Fatalf("a refused publish left %s behind", writeSafePath)
			}
			if _, ok := fs.files[writeSafeTmp]; ok {
				t.Fatalf("a refused publish left the temp %s behind", writeSafeTmp)
			}
			return
		}
	}
	t.Fatal("file-write-safe did not run")
}

// M81e2 (#1787): the publish case's own two contracts, each proven to bite.
// A case that passes because the fake agrees with it is not evidence, so
// each half is broken on purpose and must be CAUGHT.
func TestFileWritePublishPinsBothContracts(t *testing.T) {
	// The happy path first: the receipt must carry the host-comparable
	// facts, or the class-B gate compares nothing.
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	var ok bool
	for _, c := range rs {
		if c.id == "file-write-publish" {
			ok = c.ok
		}
	}
	if !ok {
		t.Fatal("file-write-publish should have passed on the default fake")
	}
	short := writeSafeShort()
	line1, line2 := []byte("gosh-history-one\n"), []byte("gosh-history-two\n")
	want := append(append([]byte{}, short...), append(line1, line2...)...)
	if got := fs.files[publishCopy]; !bytes.Equal(got, want) {
		t.Fatalf("the .copy the host compares = %d bytes, want the %d-byte "+
			"replace-plus-two-appends body", len(got), len(want))
	}
	if _, leaked := fs.files[publishTmp]; leaked {
		t.Fatalf("the sacrificial temp %s survived", publishTmp)
	}
	rec := string(fs.files[publishOk])
	for _, want := range []string{
		"tail=none", "orphan=none", "replaced=yes", "appended=yes",
		"base=" + strconv.Itoa(len(short)),
		"after=" + strconv.Itoa(len(want)),
	} {
		if !strings.Contains(rec, want) {
			t.Fatalf("receipt %q lacks %q", rec, want)
		}
	}

	// Now the append half, broken: a fake that rewrote the whole file per
	// append (the shape M81e2 rules out) must be CAUGHT, because the bytes
	// would still contain the new line while the contract is wrong. The
	// case therefore compares the whole file, not "contains the line".
	fs2 := newFakeFS()
	seedFixtures(fs2)
	fs2.publishOverride = func(path string, b []byte, appendMode bool) int64 {
		return fs2.writeSafe(path, b) // append that truncates = the bug
	}
	for _, c := range runCases(fs2.syscalls()) {
		if c.id == "file-write-publish" {
			if c.ok {
				t.Fatal("file-write-publish passed against a publish that " +
					"truncates on append — the append contract is not pinned")
			}
			if !strings.Contains(c.detail, "after two appends the file read") {
				t.Fatalf("detail = %q, want the append contract named", c.detail)
			}
			return
		}
	}
	t.Fatal("file-write-publish did not run")
}

// The replace half, broken: a publish that APPENDS instead of replacing
// leaves the old body in front of the new one. "The new bytes are present"
// would pass; the whole-file compare must not.
func TestFileWritePublishCatchesAnAppendingReplace(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.publishOverride = func(path string, b []byte, appendMode bool) int64 {
		if !appendMode {
			fs.files[path] = append(append([]byte(nil), fs.files[path]...), b...)
			return 0
		}
		fs.files[path] = append(append([]byte(nil), fs.files[path]...), b...)
		return 0
	}
	for _, c := range runCases(fs.syscalls()) {
		if c.id == "file-write-publish" {
			if c.ok {
				t.Fatal("file-write-publish passed against a replace that " +
					"appends — the ring-trim save would never shrink")
			}
			if !strings.Contains(c.detail, "after the replace the file read") {
				t.Fatalf("detail = %q, want the tail named", c.detail)
			}
			return
		}
	}
	t.Fatal("file-write-publish did not run")
}

// M81b (#1762): the `mime` case. The receipt is the proof — one line per
// fixture, in table order, byte-comparable by the class-B gate.
func TestMimeCaseSniffsTheBytesItReadBack(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	if !resultFor(t, rs, "mime").ok {
		t.Fatalf("mime should have passed, got %+v", resultFor(t, rs, "mime"))
	}
	want := "sniff README.TXT image bytes=16\n" +
		"sniff PIC.QOI image bytes=16\n" +
		"sniff NOTES.TXT text bytes=16\n" +
		"sniff SONG.OGG audio bytes=12\n" +
		"sniff BUNDLE.ZIP archive bytes=10\n" +
		"sniff GUEST.ELF binary bytes=12\n" +
		"sniff MYSTERY.PS unknown bytes=6\n"
	if got := string(fs.files[mimeReceipt]); got != want {
		t.Fatalf("mime receipt =\n%q\nwant\n%q", got, want)
	}
	// The PNG-bytes-named-.TXT row is the claim: magic decides, and the
	// receipt says image for a .TXT name.
	if !strings.Contains(string(fs.files[mimeReceipt]), "sniff README.TXT image") {
		t.Fatal("magic did not beat the extension in the receipt")
	}
	if got := string(fs.files[mimeOk]); !strings.Contains(got, "default-image=GOVIEW.ELF") ||
		!strings.Contains(got, "default-text=GOEDIT.ELF") {
		t.Fatalf("mime.ok receipt = %q", got)
	}
}

// A share that cannot hand a fixture back must FAIL the case, not sniff an
// empty buffer and call it unknown.
func TestMimeCaseFailsWhenTheShareLies(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	fs.refuseRead = true
	rs := runCases(fs.syscalls())
	if resultFor(t, rs, "mime").ok {
		t.Fatalf("mime passed with unreadable fixtures, got %+v", resultFor(t, rs, "mime"))
	}
	if !strings.Contains(resultFor(t, rs, "mime").detail, "read ") {
		t.Fatalf("detail = %q, want the refused read named", resultFor(t, rs, "mime").detail)
	}
}

// ---------------------------------------------------------------------------
// M81g (#1767): the snapshot bundle drill
// ---------------------------------------------------------------------------

// The drill, on the fake share: the four seeded bodies go into one bundle, the
// bundle is published crash-safe and read back, every entry is rehydrated
// byte-exact, and a one-byte-short bundle is refused whole.
//
// The rehydration assertions are the point. RESTORED/ is compared against the
// INPUTS, so what is under test is a round trip THROUGH the container — a case
// that wrote the bundles' own constants straight back out would pass a weaker
// check, and the BINARY session body is what makes "through the container"
// mean something (a text-only container could not carry it at all).
func TestSnapshotCaseCarriesRehydratesAndRefuses(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	rs := runCases(fs.syscalls())
	r := resultFor(t, rs, "file-snapshot")
	if !r.ok {
		t.Fatalf("the snapshot case failed: %s", r.detail)
	}

	// Every entry came back byte-exact, against the SEEDED bodies.
	for _, c := range []struct {
		got, want []byte
		what      string
	}{
		{fs.files[restoredSettings], []byte(snapshotSettingsBody), "settings"},
		{fs.files[restoredSession], []byte(snapshotSessionBody), "session"},
		{fs.files[restoredNote], []byte(snapshotNoteBody), "NOTE.TXT"},
		{fs.files[restoredSecond], []byte(snapshotSecondBody), "SECOND.TXT"},
	} {
		if !bytes.Equal(c.got, c.want) {
			t.Fatalf("rehydrated %s = %q, want %q", c.what, c.got, c.want)
		}
	}
	// The binary session body is specifically what a text container would
	// have mangled, so pin that it really is binary.
	if bytes.IndexByte(fs.files[restoredSession], 0) < 0 {
		t.Fatal("the session fixture is not binary — this case is not testing what it claims")
	}

	// The bundle itself is on the share, and the .copy is the bytes that came
	// BACK off it (never the bytes the case intended to write).
	bundle := fs.files[snapshotBundle]
	if !bytes.Equal(bundle, fs.files[snapshotBundleCopy]) {
		t.Fatal("the bundle copy is not the bundle that was read back")
	}
	if len(bundle) == 0 {
		t.Fatal("no bundle was published")
	}
	// The container really is the one the seat parses, and it holds all four
	// entries — which is the property the seat's restore depends on.
	parsed, ok, reason := snapshot.Parse(bundle)
	if !ok {
		t.Fatalf("the published bundle does not parse: %s", reason)
	}
	if len(parsed.Entries) != 4 || parsed.DocsCount() != snapshotEntryDocs {
		t.Fatalf("bundle carried %d entries / %d docs, want 4 / %d",
			len(parsed.Entries), parsed.DocsCount(), snapshotEntryDocs)
	}
	// The sacrificial temp is gone: the publish is whole-file.
	if _, ok := fs.files[snapshotBundleTmp]; ok {
		t.Fatal("the bundle's sacrificial temp survived the publish")
	}

	// The receipt names the two verdicts the host cannot see: that the
	// read-back matched, and that a truncated bundle was refused.
	want := "case file-snapshot path=OUT/snapshot.bundle entries=4 docs=" +
		strconv.Itoa(snapshotEntryDocs) + " bytes=" + strconv.Itoa(len(bundle)) +
		" settings=" + strconv.Itoa(len(snapshotSettingsBody)) +
		" session=" + strconv.Itoa(len(snapshotSessionBody)) +
		" match=yes orphan=none corrupt=refused\n"
	if got := string(fs.files[snapshotOk]); got != want {
		t.Fatalf("receipt = %q\nwant %q", got, want)
	}
}

// The refusal half, as a property over EVERY prefix. The receipt claims
// `corrupt=refused` for a one-byte-short bundle; this is the stronger version
// of the same claim — no prefix of a real bundle may ever parse as a real
// bundle, at any length. It is the property a restore actually depends on: a
// container that tolerated a short read would put back a session strip that
// was never whole, which is exactly what M62e and M66b refuse to allow.
func TestNoTruncatedPrefixOfABundleParses(t *testing.T) {
	fs := newFakeFS()
	seedFixtures(fs)
	runCases(fs.syscalls())
	full := fs.files[snapshotBundle]
	if _, ok, reason := snapshot.Parse(full); !ok {
		t.Fatalf("the whole bundle does not parse: %s", reason)
	}
	for n := 0; n < len(full); n++ {
		if _, ok, _ := snapshot.Parse(full[:n]); ok {
			t.Fatalf("a bundle truncated to %d of %d bytes parsed clean", n, len(full))
		}
	}
	// And one byte PAST the end is a refusal too, not a silent accept.
	if _, ok, _ := snapshot.Parse(append(append([]byte(nil), full...), 'x')); ok {
		t.Fatal("a bundle with a trailing byte parsed clean")
	}
}

// ---------------------------------------------------------------------------
// M100f (#2311): the VLFS disk leg — write, fsync, readback on /disk with
// the receipts on /host.
// ---------------------------------------------------------------------------

// The absent leg is the default boot's shape: the mount probe answers
// not_mounted (-6), the case records mounted=no on the share and passes —
// a data disk is an enhancement, never a boot requirement (ADR 0050 D6).
func TestDiskCaseSkipsCleanlyWithoutADataDisk(t *testing.T) {
	fs := newFakeFS()
	if err := caseDisk(fs.syscalls()); err != nil {
		t.Fatalf("absent-disk leg failed: %v", err)
	}
	if got := string(fs.files[diskOk]); got != "case disk mounted=no skipped\n" {
		t.Fatalf("absent receipt = %q", got)
	}
	if _, ok := fs.files[diskPath]; ok {
		t.Fatal("the absent leg touched /disk")
	}
}

// The mounted leg: /disk exists, the payload is written, fsynced and read
// back, the copy of the bytes READ BACK lands on the share, and the receipt
// carries the deterministic numbers.
func TestDiskCaseMountedDrill(t *testing.T) {
	fs := newFakeFS()
	fs.dirs["/disk"] = true
	if err := caseDisk(fs.syscalls()); err != nil {
		t.Fatalf("mounted leg failed: %v", err)
	}
	want := diskPayload()
	if got := fs.files[diskPath]; !bytes.Equal(got, want) {
		t.Fatalf("disk body = %d bytes, want the %d-byte payload", len(got), len(want))
	}
	if got := fs.files[diskCopy]; !bytes.Equal(got, want) {
		t.Fatalf("disk.copy is not the read-back body (len %d, want %d)", len(got), len(want))
	}
	wantReceipt := "case disk mounted=yes path=SELFTEST/DISK.TXT wrote=" +
		strconv.Itoa(len(want)) + " fsync=0 read=" + strconv.Itoa(len(want)) + " match=yes\n"
	if got := string(fs.files[diskOk]); got != wantReceipt {
		t.Fatalf("mounted receipt = %q want %q", got, wantReceipt)
	}
	if !fs.dirs[diskDir] {
		t.Fatal("the case did not create /disk/SELFTEST")
	}
	// The fsync must have landed on the payload's handle — the fake records
	// the path each sync closed over.
	if len(fs.syncs) != 1 || fs.syncs[0] != diskPath {
		t.Fatalf("syncs = %v, want exactly [%s]", fs.syncs, diskPath)
	}
}

// A lying volume fails the case, not the receipt pipeline: the read-back
// mismatch is the verdict.
func TestDiskCaseFailsOnAReadbackMismatch(t *testing.T) {
	fs := newFakeFS()
	fs.dirs["/disk"] = true
	fs.corruptRead = true
	if err := caseDisk(fs.syscalls()); err == nil {
		t.Fatal("a corrupted read-back passed")
	}
	if got := string(fs.files[diskOk]); !strings.Contains(got, "match=no") {
		t.Fatalf("receipt = %q, want the honest mismatch", got)
	}
}
