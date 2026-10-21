package main

import (
	"strings"
	"testing"
	"unsafe"

	"virelai/rss/keys"
	"virelai/vi"
)

// batchFakeFS serves the two slots a batch needs: SlotDirList (per-path
// row sets, rewritten as renames move entries) and SlotFileRename (one
// scripted failure point). Everything else refuses with ENOSYS — reads,
// writes, leases — so a copy step still fails honestly on the host and a
// stray op fails loudly instead of silently.
type batchFakeFS struct {
	dirs     map[string][]vi.DirEntry
	failMove string // exact "src->dst" pair that returns -ENOSYS
	renames  []string
}

func (f *batchFakeFS) serve(num uintptr, a0, a1, a2, a3 uintptr) int64 {
	switch num {
	case vi.SlotDirList:
		p := string(unsafe.Slice((*byte)(unsafe.Pointer(a0)), int(a1)))
		rows, ok := f.dirs[p]
		if !ok {
			return vi.ErrFileNotFound
		}
		out := unsafe.Slice((*vi.DirEntry)(unsafe.Pointer(a2)), int(a3))
		n := 0
		for _, r := range rows {
			if n >= len(out) {
				break
			}
			out[n] = r
			n++
		}
		return int64(n)
	case vi.SlotFileRename:
		src := string(unsafe.Slice((*byte)(unsafe.Pointer(a0)), int(a1)))
		dst := string(unsafe.Slice((*byte)(unsafe.Pointer(a2)), int(a3)))
		pair := src + "->" + dst
		f.renames = append(f.renames, pair)
		if pair == f.failMove {
			return -vi.ErrENOSYS
		}
		// The fake's move is real: the entry leaves its source listing
		// and lands in the destination's, so the batch's closing refresh
		// reads the world the batch actually made.
		name := baseName(src)
		srcDir := parentPath(src)
		dstDir := parentPath(dst)
		var moved *vi.DirEntry
		for i, e := range f.dirs[srcDir] {
			if e.NameString() == name {
				cp := e
				copy(cp.Name[:], name)
				f.dirs[srcDir] = append(f.dirs[srcDir][:i], f.dirs[srcDir][i+1:]...)
				moved = &cp
				break
			}
		}
		if moved == nil {
			return -vi.ErrENOENT
		}
		f.dirs[dstDir] = append(f.dirs[dstDir], *moved)
		return 0
	}
	return -vi.ErrENOSYS
}

func withBatchFS(t *testing.T, fs *batchFakeFS) {
	t.Helper()
	prev := vi.SetSyscallHookForTest(fs.serve)
	t.Cleanup(func() { vi.SetSyscallHookForTest(prev) })
}

// runBatch drains an armed batch the way main's loop does — one step per
// pass — so the host tests observe the same marker sequence the serial
// log carries on the guest.
func runBatch(m *model) {
	for m.batchOn {
		m.batchStep()
	}
}

func TestMarkToggleBoundAndClear(t *testing.T) {
	m := testModel(entry("SUB", true), entry("A.TXT", false), entry("B.TXT", false))

	// A directory row refuses the mark by name.
	m.handleKey(runeKey('m'))
	if got := pendingJoined(&m); !strings.Contains(got, markerMarkNo+"SUB (dir)") {
		t.Fatalf("dir mark refusal missing: %q", got)
	}
	if m.markCount() != 0 {
		t.Fatalf("a dir must not mark, count=%d", m.markCount())
	}

	// Two file marks count up; toggling one off counts back down.
	m.handleKey(runeKey('j'))
	m.handleKey(runeKey('m')) // A.TXT on
	m.handleKey(runeKey('j'))
	m.handleKey(runeKey('m')) // B.TXT on
	if m.markCount() != 2 {
		t.Fatalf("markCount = %d, want 2", m.markCount())
	}
	got := pendingJoined(&m)
	for _, want := range []string{
		markerMark + "A.TXT n=1",
		markerMark + "B.TXT n=2",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("batch %q missing %q", got, want)
		}
	}
	m.handleKey(runeKey('m')) // B.TXT off
	if m.markCount() != 1 {
		t.Fatalf("untoggle count = %d, want 1", m.markCount())
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerUnmark+"B.TXT n=1") {
		t.Fatalf("unmark marker missing: %q", got)
	}

	// The bound: with a seeded full set the next mark refuses by name.
	m.marks = make(map[string]struct{}, maxMarks)
	for i := 0; i < maxMarks; i++ {
		m.marks["SEED"+vi.Itoa64(int64(i))] = struct{}{}
	}
	m.handleKey(keys.Event{Key: keys.KeyUp}) // sel = A.TXT, unmarked
	m.handleKey(runeKey('m'))
	if got := pendingJoined(&m); !strings.Contains(got, markerMarkNo+"A.TXT bound=64") {
		t.Fatalf("bound refusal missing: %q", got)
	}
	if m.markCount() != maxMarks {
		t.Fatalf("a refused mark must not grow the set, count=%d", m.markCount())
	}

	// M clears the set and names the count it dropped.
	m.marks = nil
	m.marksDir = m.path
	m.handleKey(runeKey('m')) // A.TXT on again
	m.handleKey(runeKey('M'))
	if m.markCount() != 0 {
		t.Fatalf("M must clear, count=%d", m.markCount())
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerMarksClear+"n=1") {
		t.Fatalf("clear marker missing: %q", got)
	}
	m.handleKey(runeKey('M'))
	if m.status != "no marks" {
		t.Fatalf("clearing an empty set must still answer, status=%q", m.status)
	}
}

// The gutter glyph: a marked row carries '*', the selected row keeps '>'.
func TestMarkGutterAndStatusCount(t *testing.T) {
	m := testModel(entry("SUB", true), entry("A.TXT", false), entry("B.TXT", false))
	m.handleKey(runeKey('j'))
	m.handleKey(runeKey('m')) // mark + select A.TXT
	row := m.listRow(1, 28)
	if !strings.Contains(row, ">*A.TXT") {
		t.Fatalf("selected marked row = %q, want the >* gutter", row)
	}
	m.handleKey(runeKey('j')) // sel on B.TXT, A.TXT still marked
	row = m.listRow(1, 28)
	if !strings.Contains(row, " *A.TXT") {
		t.Fatalf("marked row = %q, want the  * gutter", row)
	}
	if !strings.Contains(m.statusLine(), "[1 marked]") {
		t.Fatalf("status line must count the set: %q", m.statusLine())
	}
}

// Marks belong to the listing they were made on: a cd hides the set, a
// cd back finds it again, and refresh prunes names that vanished.
func TestMarksBindToDirAndPrune(t *testing.T) {
	fs := &batchFakeFS{dirs: map[string][]vi.DirEntry{
		"/host/FM":     {entry("SUB", true), entry("A.TXT", false)},
		"/host/FM/SUB": {entry("INNER.TXT", false)},
	}}
	withBatchFS(t, fs)
	m := testModel(entry("SUB", true), entry("A.TXT", false))
	m.handleKey(runeKey('j'))
	m.handleKey(runeKey('m')) // mark A.TXT
	m.drain()

	m.handleKey(runeKey('k')) // SUB
	m.handleKey(runeKey('l')) // enter -> refresh over the fake
	if m.path != "/host/FM/SUB" {
		t.Fatalf("cd failed, path=%q", m.path)
	}
	if m.markCount() != 0 {
		t.Fatalf("a foreign dir must not show FM's marks, count=%d", m.markCount())
	}
	// Marking here moves the set: FM's mark is dropped.
	m.handleKey(runeKey('m')) // mark INNER.TXT
	if m.marksDir != "/host/FM/SUB" || !m.isMarked("INNER.TXT") {
		t.Fatalf("marking in SUB must rebind the set, dir=%q", m.marksDir)
	}
	m.handleKey(keys.Event{Key: keys.KeyBackspace}) // back to FM: the set moved, count 0
	if m.markCount() != 0 {
		t.Fatalf("the rebound set left FM, count=%d", m.markCount())
	}

	// Prune: a marked name the listing loses drops off the set.
	m.marks = map[string]struct{}{"A.TXT": {}, "GHOST.TXT": {}}
	m.marksDir = m.path
	m.refresh()
	if m.markCount() != 1 || !m.isMarked("A.TXT") {
		t.Fatalf("refresh must prune vanished names, marks=%v", m.marks)
	}
}

// The full gesture the card names: mark three, x, enter a folder, p —
// one item per step, progress 1/3..3/3, then `files: batch done n=3`.
func TestBatchMoveRunsOneItemPerStep(t *testing.T) {
	fs := &batchFakeFS{dirs: map[string][]vi.DirEntry{
		"/host/FM":     {entry("SUB", true), entry("A1.TXT", false), entry("A2.TXT", false), entry("A3.TXT", false)},
		"/host/FM/SUB": {},
	}}
	withBatchFS(t, fs)
	m := testModel(entry("SUB", true), entry("A1.TXT", false),
		entry("A2.TXT", false), entry("A3.TXT", false))

	// Mark A1..A3 (j/m three times), cut the set, enter SUB, paste.
	m.handleKey(runeKey('j'))
	for i := 0; i < 3; i++ {
		m.handleKey(runeKey('m'))
		if i < 2 {
			m.handleKey(runeKey('j'))
		}
	}
	m.handleKey(runeKey('x'))
	got := pendingJoined(&m)
	if !strings.Contains(got, markerClip+"cut set n=3") {
		t.Fatalf("set yank marker missing: %q", got)
	}
	if len(m.clipSet) != 3 {
		t.Fatalf("clipSet = %v, want 3 sources", m.clipSet)
	}
	m.handleKey(runeKey('k')) // SUB
	m.handleKey(runeKey('k'))
	m.handleKey(runeKey('k'))
	m.handleKey(keys.Event{Key: keys.KeyEnter}) // enter SUB
	if m.path != "/host/FM/SUB" {
		t.Fatalf("enter failed, path=%q", m.path)
	}
	m.handleKey(runeKey('p'))
	if !m.batchOn {
		t.Fatal("p over a set must arm the batch")
	}
	got = pendingJoined(&m)
	if !strings.Contains(got, markerBatchStart+"move n=3") {
		t.Fatalf("batch start marker missing: %q", got)
	}
	// No Go seat on the host: the first report is refused by name, once
	// per batch (the latch means it never repeats under the steps).
	if !strings.Contains(got, markerBatchProgNo) {
		t.Fatalf("seat-refusal marker missing: %q", got)
	}

	// Stepped: each pass commits exactly one item.
	m.batchStep()
	if m.batch.done != 1 || len(fs.renames) != 1 {
		t.Fatalf("one step = one item: done=%d renames=%v", m.batch.done, fs.renames)
	}
	if m.status != "move 1/3" {
		t.Fatalf("in-pane counter status = %q, want %q", m.status, "move 1/3")
	}
	if m.prog.Percent() != 33 {
		t.Fatalf("progress after 1/3 = %d%%, want 33", m.prog.Percent())
	}
	runBatch(&m)

	got = pendingJoined(&m)
	for _, want := range []string{
		markerBatch + "move 1/3 A1.TXT",
		markerBatch + "move 2/3 A2.TXT",
		markerBatch + "move 3/3 A3.TXT",
		"gofiles: pasted A1.TXT",
		markerBatchDone + "3",
		"gofiles: list /host/FM/SUB n=3",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("batch %q missing %q", got, want)
		}
	}
	if m.batchOn {
		t.Fatal("batch must disarm at done")
	}
	if len(m.clipSet) != 0 {
		t.Fatal("a completed move drops the clip — moved sources cannot paste twice")
	}
	if got := m.takeNotify(); got != "moved 3 files" {
		t.Fatalf("done toast = %q", got)
	}
	wantRenames := []string{
		"/host/FM/A1.TXT->/host/FM/SUB/A1.TXT",
		"/host/FM/A2.TXT->/host/FM/SUB/A2.TXT",
		"/host/FM/A3.TXT->/host/FM/SUB/A3.TXT",
	}
	if len(fs.renames) != len(wantRenames) {
		t.Fatalf("renames = %v", fs.renames)
	}
	for i := range wantRenames {
		if fs.renames[i] != wantRenames[i] {
			t.Fatalf("renames[%d] = %q, want %q", i, fs.renames[i], wantRenames[i])
		}
	}
}

// The first failure stops the run and the stop marker names the item,
// what finished and what remains — no rollback, nothing untried runs.
func TestBatchStopsOnFirstFailure(t *testing.T) {
	fs := &batchFakeFS{
		dirs: map[string][]vi.DirEntry{
			"/host/FM":     {entry("A1.TXT", false), entry("A2.TXT", false), entry("A3.TXT", false)},
			"/host/FM/SUB": {},
		},
		failMove: "/host/FM/A2.TXT->/host/FM/SUB/A2.TXT",
	}
	withBatchFS(t, fs)
	m := testModel(entry("A1.TXT", false), entry("A2.TXT", false), entry("A3.TXT", false))
	for i := 0; i < 3; i++ {
		m.handleKey(runeKey('m'))
		if i < 2 {
			m.handleKey(runeKey('j'))
		}
	}
	m.handleKey(runeKey('x'))
	m.path = "/host/FM/SUB"
	m.refresh()
	m.drain()
	m.handleKey(runeKey('p'))
	runBatch(&m)

	got := pendingJoined(&m)
	if !strings.Contains(got, markerBatchStop+"A2.TXT rc=-4 done=1 left=2") {
		t.Fatalf("stop marker must name item, done and remaining: %q", got)
	}
	if strings.Contains(got, markerBatchDone) {
		t.Fatalf("a stopped batch must not print done: %q", got)
	}
	if len(fs.renames) != 2 {
		t.Fatalf("the untried item must never run, renames=%v", fs.renames)
	}
	if m.batchOn {
		t.Fatal("a stopped batch must disarm")
	}
	if len(m.clipSet) != 3 {
		t.Fatal("a stopped move keeps the clip held — the report owns the story")
	}
}

// The planner refuses the whole gesture BEFORE the first item runs.
func TestBatchPlannerRefusals(t *testing.T) {
	m := testModel(entry("A1.TXT", false), entry("A2.TXT", false))
	// A destination name already present refuses the batch by name.
	m.clipSet = []string{"/host/OTHER/A1.TXT", "/host/OTHER/NEW.TXT"}
	m.handleKey(runeKey('p'))
	got := pendingJoined(&m)
	if !strings.Contains(got, markerBatchNo+"A1.TXT exists") {
		t.Fatalf("exists refusal missing: %q", got)
	}
	if m.batchOn {
		t.Fatal("a refused plan must not arm the batch")
	}

	// A move cannot cross volumes (the single-paste rule, per item).
	m.clipSet = []string{"/disk/D1.TXT", "/disk/D2.TXT"}
	m.clipCut = true
	m.handleKey(runeKey('p'))
	got = pendingJoined(&m)
	if !strings.Contains(got, markerBatchNo+"D1.TXT cross-volume") {
		t.Fatalf("cross-volume refusal missing: %q", got)
	}
}

// Delete over a set asks ONCE with the count; 'y' queues the batch (the
// host's TrashDelete is ENOSYS, so the run stops at item 1 with the named
// report — the failure shape, honestly, is what the host can pin).
func TestBatchDeleteAsksOnceWithCount(t *testing.T) {
	m := testModel(entry("B1.TXT", false), entry("B2.TXT", false))
	m.handleKey(runeKey('m'))
	m.handleKey(runeKey('j'))
	m.handleKey(runeKey('m'))
	m.handleKey(runeKey('d'))
	if m.mode != modeConfirmDelete {
		t.Fatalf("d over a set must still confirm, mode=%d", m.mode)
	}
	if m.status != "delete 2 marked? y/n" {
		t.Fatalf("the one ask must carry the count, status=%q", m.status)
	}
	got := pendingJoined(&m)
	if !strings.Contains(got, markerDeleteArm+"n=2") {
		t.Fatalf("batch arm marker missing: %q", got)
	}
	m.handleKey(runeKey('y'))
	if !m.batchOn || m.batch.verb != batchDelete {
		t.Fatalf("'y' must queue the delete batch, on=%v verb=%d", m.batchOn, m.batch.verb)
	}
	runBatch(&m)
	got = pendingJoined(&m)
	if !strings.Contains(got, markerBatchStart+"delete n=2") ||
		!strings.Contains(got, markerBatchStop+"B1.TXT rc=-4 done=0 left=2") {
		t.Fatalf("delete batch markers missing: %q", got)
	}

	// A shed prompt names the count too, and deletes nothing. The failed
	// batch's closing refresh re-listed over the host's ENOSYS stub, so
	// the leg needs a fresh listing.
	m = testModel(entry("B1.TXT", false), entry("B2.TXT", false))
	m.handleKey(runeKey('m'))
	m.handleKey(runeKey('j'))
	m.handleKey(runeKey('m'))
	m.handleKey(runeKey('d'))
	m.handleKey(runeKey('x'))
	got = pendingJoined(&m)
	if !strings.Contains(got, markerDeleteCancel+"n=2 key=x") {
		t.Fatalf("batch cancel marker missing: %q", got)
	}
	if m.batchOn {
		t.Fatal("a shed confirm must not queue a batch")
	}
}

// Marks stay OUT of the session blob (transient by contract): a mark on
// the live model must not change what encodeState writes.
func TestMarksNeverSerialize(t *testing.T) {
	m := testModel(entry("A.TXT", false))
	plain := m.encodeState()
	m.handleKey(runeKey('m'))
	m.handleKey(runeKey('x'))
	marked := m.encodeState()
	if string(plain) != string(marked) {
		t.Fatalf("marks/clip must not reach the blob: %x != %x", plain, marked)
	}
}
