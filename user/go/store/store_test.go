package store

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	"virelai/flint/parser"
	"virelai/sshlib"
	"virelai/vi"
)

// ---- fixture helpers -----------------------------------------------------

const testStreamID = "0199de2d-dc00-7000-8000-00000000c100"

var testELF = []byte("fake guest elf bytes for hashing")

// releaseGo renders the release.go a producer (flint release,
// flint-client#49) mints for (name, version, elf, row).
func releaseGo(name, version string, elf []byte, row string) []byte {
	sum := sshlib.SHA256Sum(elf)
	return []byte(fmt.Sprintf(`package release

const ReleaseName = %q
const ReleaseVersion = %q
const ReleaseELFSHA256 = %q
const ReleaseManifestRow = %q
`, name, version, sshlib.EncodeHex(sum[:]), row))
}

// releaseOps parses src into atoms (the real virelai/flint/parser, the
// same hashes a guest `flint add` computes) and folds them into the signed
// (kind,qname)->hash set.
func releaseOps(t *testing.T, src []byte) map[atomKey]string {
	t.Helper()
	p, ok := parser.ForPath("release.go")
	if !ok {
		t.Fatal("no parser for release.go")
	}
	atoms, err := p.Parse("release.go", src)
	if err != nil {
		t.Fatalf("parse release.go: %v", err)
	}
	out := map[atomKey]string{}
	for _, a := range atoms {
		out[atomKey{a.Kind, a.Name}] = hex.EncodeToString(a.Hash[:])
	}
	return out
}

// streamWithRelease writes a one-change stream (record + log) whose ops
// cover every release.go atom, into fs under DefaultStoreRoot.
func streamWithRelease(t *testing.T, fs *memFS, name string, src []byte) {
	t.Helper()
	streamWithReleaseAs(t, fs, name, testStreamID,
		"0199de2d-dc00-7000-8000-00000000c001", strings.Repeat("ab", 32), src)
}

// streamWithReleaseAs is streamWithRelease with the stream id, change id,
// and head-change author (the derived publisher fingerprint) as knobs —
// two-publisher catalog tests sign the second stream with a second key.
func streamWithReleaseAs(t *testing.T, fs *memFS, name, streamID, changeID, author string, src []byte) {
	t.Helper()
	p, _ := parser.ForPath("release.go")
	atoms, err := p.Parse("release.go", src)
	if err != nil {
		t.Fatalf("parse release.go: %v", err)
	}
	change := Change{
		ID:     changeID,
		Stream: streamID,
		TS:     1760000000000,
		Author: author,
		Ops:    []Op{},
		Sig:    strings.Repeat("cd", 64),
	}
	i := 0
	for _, a := range atoms {
		span := Span{File: a.File, Start: a.Start, End: a.End}
		change.Ops = append(change.Ops, Op{
			Type:    "add",
			AtomID:  fmt.Sprintf("0199de2d-dc00-7000-8000-00000000d%03d", i),
			Kind:    a.Kind,
			NewName: a.Name,
			NewSpan: &span,
			NewHash: hex.EncodeToString(a.Hash[:]),
		})
		i++
	}
	rec := Stream{ID: streamID, Name: name, Head: &change.ID, Created: 1}
	rb, _ := json.Marshal(rec)
	fs.files[streamRecordPath(DefaultStoreRoot, streamID)] = append(rb, '\n')
	lb, _ := json.Marshal(change)
	fs.files[streamLogPath(DefaultStoreRoot, streamID)] = append(lb, '\n')
	fs.dirs[DefaultStoreRoot] = true
	fs.dirs[DefaultStoreRoot+"/streams"] = true
}

// fakeExec scripts execFn: each step maps a substring of the argv join
// to the child's exit status.
type execStep struct {
	match  string
	status int64
}

type fakeExec struct {
	fs    *memFS
	steps []execStep
	log   []string
}

func (f *fakeExec) run(name string, args ...string) (int64, error) {
	cmd := name + " " + strings.Join(args, " ")
	f.log = append(f.log, cmd)
	for _, st := range f.steps {
		if strings.Contains(cmd, st.match) {
			return st.status, nil
		}
	}
	return 0, nil
}

// ---- execFn kill-on-timeout -----------------------------------------------

// stubExecInner swaps execFn's inner seams for fakes and restores them.
// The fake spawn returns pid 7; wait/probe/kill behavior is set per test.
func stubExecInner(t *testing.T, wait func(int64, int64) (int64, error), probe func(int64) (int64, int)) *[]uint64 {
	t.Helper()
	killed := &[]uint64{}
	prevSpawn, prevWait, prevKill, prevProbe, prevSleep :=
		execSpawnFn, waitBudgetFn, killFn, probeFn, sleepFn
	execSpawnFn = func(name string, args ...string) (int64, error) { return 7, nil }
	waitBudgetFn = wait
	killFn = func(pid uint64) int64 { *killed = append(*killed, pid); return 0 }
	probeFn = probe
	sleepFn = func(uint64) {}
	t.Cleanup(func() {
		execSpawnFn, waitBudgetFn, killFn, probeFn, sleepFn =
			prevSpawn, prevWait, prevKill, prevProbe, prevSleep
	})
	return killed
}

// TestExecSlowChildGetsRunBudget is the #2522 pin: a pid confirmed
// Running when the appear budget expires gets the work-scaled run
// budget, not a kill — the ~21 s fresh-share clone must not die at 15 s.
func TestExecSlowChildGetsRunBudget(t *testing.T) {
	var budgets []int64
	killed := stubExecInner(t,
		func(_ int64, budget int64) (int64, error) {
			budgets = append(budgets, budget)
			if len(budgets) == 1 {
				return -1, vi.ErrWaitGone
			}
			return 0, nil
		},
		func(int64) (int64, int) { return -1, vi.ProbeRunning })
	st, err := execFn("FLINT.ELF", "clone")
	if err != nil || st != 0 {
		t.Fatalf("execFn = (%d, %v), want (0, nil)", st, err)
	}
	if len(budgets) != 2 || budgets[0] != execAppearNs || budgets[1] != execRunNs {
		t.Fatalf("wait budgets = %v, want [%d %d]", budgets, execAppearNs, execRunNs)
	}
	if len(*killed) != 0 {
		t.Fatalf("kill called on a slow-but-running child: %v", *killed)
	}
}

func TestExecExpiredProbeExitedReturnsStatus(t *testing.T) {
	// A child that exits between WaitBudget's last poll and the
	// phase-check probe reports its recorded status, not ErrWaitGone.
	waits := 0
	killed := stubExecInner(t,
		func(int64, int64) (int64, error) { waits++; return -1, vi.ErrWaitGone },
		func(int64) (int64, int) { return 7, vi.ProbeExited })
	st, err := execFn("FLINT.ELF", "clone")
	if err != nil || st != 7 {
		t.Fatalf("execFn = (%d, %v), want (7, nil)", st, err)
	}
	if waits != 1 || len(*killed) != 0 {
		t.Fatalf("waits=%d killed=%v, want waits=1 killed=[]", waits, *killed)
	}
}

func TestExecKillOnWaitTimeout(t *testing.T) {
	// A child that outlives BOTH budgets is armed for kill and drained:
	// the orphan cannot leak a task-pool slot into the retry's spawn
	// (#2402's timed-out FLINT clone starving attempt 2 into newosproc).
	probes := 0
	killed := stubExecInner(t,
		func(int64, int64) (int64, error) { return -1, vi.ErrWaitGone },
		func(int64) (int64, int) {
			probes++
			if probes < 3 {
				return -1, vi.ProbeRunning
			}
			return 137, vi.ProbeExited
		})
	st, err := execFn("FLINT.ELF", "clone")
	if !errors.Is(err, vi.ErrWaitGone) || st != -1 {
		t.Fatalf("execFn = (%d, %v), want (-1, ErrWaitGone)", st, err)
	}
	if len(*killed) != 1 || (*killed)[0] != 7 {
		t.Fatalf("kill calls = %v, want [7]", *killed)
	}
	if probes != 3 {
		t.Fatalf("drain probes = %d, want 3", probes)
	}
}

func TestExecKillDrainsAbsentPid(t *testing.T) {
	// The never-registered pid burns the budget the same way; Kill on it
	// refuses EINVAL (ignored) and the drain exits on the first Absent.
	// The phase-check probe after the appear budget is the first of the
	// two observed probes; the drain's own first Absent is the second.
	probes := 0
	stubExecInner(t,
		func(int64, int64) (int64, error) { return -1, vi.ErrWaitGone },
		func(int64) (int64, int) {
			probes++
			return -1, vi.ProbeAbsent
		})
	if _, err := execFn("FLINT.ELF", "pull"); !errors.Is(err, vi.ErrWaitGone) {
		t.Fatalf("execFn err = %v, want ErrWaitGone", err)
	}
	if probes != 2 {
		t.Fatalf("probes = %d, want 2 (phase check + drain)", probes)
	}
}

func TestExecNoKillOnCleanWait(t *testing.T) {
	killed := stubExecInner(t,
		func(int64, int64) (int64, error) { return 0, nil },
		func(int64) (int64, int) { return -1, vi.ProbeExited })
	st, err := execFn("FLINT.ELF", "verify")
	if err != nil || st != 0 {
		t.Fatalf("execFn = (%d, %v), want (0, nil)", st, err)
	}
	if len(*killed) != 0 {
		t.Fatalf("kill called on clean wait: %v", *killed)
	}
}

func collectConsole() (*[]string, func()) {
	var lines []string
	prev := ConsoleFn
	ConsoleFn = func(s string) { lines = append(lines, s) }
	return &lines, func() { ConsoleFn = prev }
}

func refuseCode(t *testing.T, err error, want string) {
	t.Helper()
	re, ok := err.(*RefuseError)
	if !ok {
		t.Fatalf("expected RefuseError %q, got %v", want, err)
	}
	if re.Code != want {
		t.Fatalf("refuse code %q, want %q (err %v)", re.Code, want, err)
	}
}

// ---- foldReleaseOps -------------------------------------------------------

func TestFoldReleaseOps(t *testing.T) {
	src := releaseGo("GOHELLO", "1.0.0", testELF, "GOHELLO.ELF | Go Hello | g | dock=false")
	signed := releaseOps(t, src)
	if len(signed) != 4 {
		t.Fatalf("expected 4 release atoms, got %d", len(signed))
	}
	var adds []Op
	i := 0
	for key, hash := range signed {
		sp := Span{File: "release.go"}
		adds = append(adds, Op{Type: "add", AtomID: fmt.Sprintf("a%d", i), Kind: key.kind, NewName: key.name, NewSpan: &sp, NewHash: hash})
		i++
	}
	changes := []Change{{ID: "c1", Ops: adds}}
	got := foldReleaseOps(changes)
	if len(got) != len(signed) {
		t.Fatalf("folded %d atoms, want %d", len(got), len(signed))
	}
	for k, h := range signed {
		if got[k] != h {
			t.Fatalf("folded %v hash %q, want %q", k, got[k], h)
		}
	}

	// A modify op on one atom's id updates its signed hash; a delete of
	// another removes it.
	var modID, delID string
	for _, op := range adds {
		if strings.HasSuffix(op.NewName, ".ReleaseVersion") {
			modID = op.AtomID
		}
		if strings.HasSuffix(op.NewName, ".ReleaseManifestRow") {
			delID = op.AtomID
		}
	}
	c2 := Change{ID: "c2", Ops: []Op{
		{Type: "modify", AtomID: modID, Kind: "const", NewName: "release.ReleaseVersion", NewSpan: &Span{File: "release.go"}, NewHash: "ff" + strings.Repeat("0", 62)},
		{Type: "delete", AtomID: delID},
	}}
	got = foldReleaseOps([]Change{changes[0], c2})
	if len(got) != 3 {
		t.Fatalf("after delete folded %d atoms, want 3", len(got))
	}
	if got[atomKey{"const", "release.ReleaseVersion"}] != "ff"+strings.Repeat("0", 62) {
		t.Fatal("modify did not update signed hash")
	}

	// A stream that never touched release.go folds empty.
	got = foldReleaseOps([]Change{{ID: "c1", Ops: []Op{
		{Type: "add", AtomID: "x", Kind: "fn", NewName: "app.Main", NewSpan: &Span{File: "app.go"}, NewHash: "aa"},
	}}})
	if len(got) != 0 {
		t.Fatal("non-release stream should fold empty")
	}
}

// ---- verifyRelease --------------------------------------------------------

func TestVerifyRelease(t *testing.T) {
	src := releaseGo("GOHELLO", "1.0.0", testELF, "GOHELLO.ELF | Go Hello | g | dock=false")
	signed := releaseOps(t, src)
	if err := verifyRelease(src, signed); err != nil {
		t.Fatalf("verifyRelease happy: %v", err)
	}

	// Tampered value: hash no longer matches the signed atom.
	tampered := releaseGo("GOHELLO", "9.9.9", testELF, "GOHELLO.ELF | Go Hello | g | dock=false")
	err := verifyRelease(tampered, signed)
	refuseCode(t, err, "release_mismatch")

	// Extra unsigned atom in the fetched file: refused, not tolerated.
	extra := append([]byte{}, src...)
	extra = append(extra, []byte("\nconst Sneaky = 1\n")...)
	err = verifyRelease(extra, signed)
	refuseCode(t, err, "release_mismatch")

	// Signed atom missing from the fetched file.
	missing := signed
	delete(missing, atomKey{"const", "release.ReleaseVersion"})
	err = verifyRelease(src, missing)
	refuseCode(t, err, "release_mismatch")

	// No signed release ops at all.
	err = verifyRelease(src, map[atomKey]string{})
	refuseCode(t, err, "release_missing")

	// Not Go source.
	err = verifyRelease([]byte("this is not go"), signed)
	refuseCode(t, err, "release_malformed")
}

// ---- parseRelease ---------------------------------------------------------

func TestParseRelease(t *testing.T) {
	src := releaseGo("GOHELLO", "1.0.0", testELF, "GOHELLO.ELF | Go Hello | g | dock=false")
	rel, err := parseRelease(src)
	if err != nil {
		t.Fatalf("parseRelease: %v", err)
	}
	if rel.Name != "GOHELLO" || rel.Version != "1.0.0" {
		t.Fatalf("got %q %q", rel.Name, rel.Version)
	}
	sum := sshlib.SHA256Sum(testELF)
	if rel.ELFSHA256 != sshlib.EncodeHex(sum[:]) {
		t.Fatal("bad elf hash")
	}
	if rel.ManifestRow != "GOHELLO.ELF | Go Hello | g | dock=false" {
		t.Fatalf("row %q", rel.ManifestRow)
	}

	bad := []byte(`package release

const ReleaseName = "GOHELLO"
const ReleaseVersion = "1"
const ReleaseELFSHA256 = "zz"
const ReleaseManifestRow = "OTHER.ELF | X | x"
`)
	_, err = parseRelease(bad)
	refuseCode(t, err, "hash_invalid")

	badRow := releaseGo("GOHELLO", "1", testELF, "OTHER.ELF | X | x")
	_, err = parseRelease(badRow)
	refuseCode(t, err, "row_mismatch")

	badName := releaseGo("go hello", "1", testELF, "GOHELLO.ELF | X | x")
	_, err = parseRelease(badName)
	refuseCode(t, err, "name_invalid")
}

// ---- manifest -------------------------------------------------------------

func TestManifest(t *testing.T) {
	fs := newMemFS()
	fs.files[appsPath] = []byte("# header\nGOCALC.ELF | 64-bit Calc | c | dock=true\nGOSH.ELF | Shell | s | dock=false | v=2\n")
	lines, err := loadManifest(fs)
	if err != nil {
		t.Fatal(err)
	}
	if !manifestHasBin(lines, "GOCALC.ELF") || manifestHasBin(lines, "GOPING.ELF") {
		t.Fatal("hasBin wrong")
	}
	out, err := manifestWithRow(lines, "GOPING.ELF | Ping | p | dock=false")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(out), "GOPING.ELF | Ping | p | dock=false\n") {
		t.Fatalf("row missing: %q", out)
	}
	kept, found := manifestWithoutBin(lines, "GOSH.ELF")
	if !found {
		t.Fatal("remove missed")
	}
	if manifestHasBin(kept, "GOSH.ELF") || !manifestHasBin(kept, "GOCALC.ELF") {
		t.Fatal("remove kept wrong rows")
	}
	if _, ok := normalizeBin("gohello"); !ok {
		t.Fatal("normalizeBin refused valid stem")
	}
	if b, _ := normalizeBin("GOHELLO.ELF"); b != "GOHELLO.ELF" {
		t.Fatalf("normalizeBin got %q", b)
	}
	if _, ok := normalizeBin("../evil"); ok {
		t.Fatal("normalizeBin accepted escape")
	}
}

func TestManifestFull(t *testing.T) {
	fs := newMemFS()
	fs.files[appsPath] = []byte(strings.Repeat("X", appsMaxBytes-30) + "\n")
	lines, err := loadManifest(fs)
	if err != nil {
		t.Fatal(err)
	}
	_, err = manifestWithRow(lines, strings.Repeat("Y", 100))
	refuseCode(t, err, "manifest_full")
}

// ---- channel --------------------------------------------------------------

func TestDirChannel(t *testing.T) {
	fs := newMemFS()
	fs.files["/host/DROP/rel/release.go"] = []byte("package release\n")
	ch, err := openChannel(fs, "/host/DROP")
	if err != nil {
		t.Fatal(err)
	}
	b, err := ch.fetch("rel/release.go", 1024)
	if err != nil || len(b) == 0 {
		t.Fatalf("fetch: %v", err)
	}
	_, err = ch.fetch("rel/NOPE.ELF", 1024)
	refuseCode(t, err, "channel_missing")
	_, err = ch.fetch("../escape", 1024)
	refuseCode(t, err, "channel_malformed")
}

type fakeConn struct {
	in   []byte
	sent []byte
}

func (f *fakeConn) Send(p []byte) (int, error) { f.sent = append(f.sent, p...); return len(p), nil }
func (f *fakeConn) Recv(p []byte) (int, error) {
	if len(f.in) == 0 {
		return 0, nil
	}
	n := copy(p, f.in)
	f.in = f.in[n:]
	return n, nil
}
func (f *fakeConn) Close() error { return nil }

// fakeDeadlineConn records every SetRecvDeadline budget — the #2379
// deadline leg asserts the session bound is a RELATIVE 20 s budget, not
// an absolute timestamp (SetRecvDeadline adds Nanos() itself).
type fakeDeadlineConn struct {
	in        []byte
	sent      []byte
	deadlines []int64
}

func (f *fakeDeadlineConn) Send(p []byte) (int, error) {
	f.sent = append(f.sent, p...)
	return len(p), nil
}
func (f *fakeDeadlineConn) Recv(p []byte) (int, error) {
	if len(f.in) == 0 {
		return 0, errors.New("fake: drained")
	}
	n := copy(p, f.in)
	f.in = f.in[n:]
	return n, nil
}
func (f *fakeDeadlineConn) Close() error             { return nil }
func (f *fakeDeadlineConn) SetRecvDeadline(ns int64) { f.deadlines = append(f.deadlines, ns) }

// TestWireSessionDeadlineIsRelative: the 20 s session bound is a budget
// (relative), not uptime+20 s (absolute) — the first deadline call is
// the session bound remoteStreams sets before handshake.
func TestWireSessionDeadlineIsRelative(t *testing.T) {
	conn := &fakeDeadlineConn{
		in: []byte(`{"seq":1,"ok":true,"proto":"FLINT-SYNC/1"}` + "\n"),
	}
	_, restore := collectConsole()
	defer restore()
	prev := remoteDialFn
	defer func() { remoteDialFn = prev }()
	remoteDialFn = func(remote string) (wireConn, error) { return conn, nil }
	// The handshake outcome does not matter — the session bound is set
	// before it and is what the leg asserts.
	_, _ = remoteStreams("10.0.0.2:4749")
	if len(conn.deadlines) == 0 || conn.deadlines[0] != 20_000_000_000 {
		t.Fatalf("session deadline %v, want a relative 20s budget", conn.deadlines)
	}
}

func TestHTTPChannel(t *testing.T) {
	body := []byte("channel body bytes")
	conn := &fakeConn{in: []byte("HTTP/1.0 200 OK\r\nContent-Length: " +
		fmt.Sprint(len(body)) + "\r\n\r\n" + string(body))}
	prev := httpDialFn
	defer func() { httpDialFn = prev }()
	httpDialFn = func(host string, port uint16) (httpConn, error) { return conn, nil }

	ch, err := newHTTPChannel("http://10.0.0.2:8080/pub")
	if err != nil {
		t.Fatal(err)
	}
	got, err := ch.fetch("rel/release.go", 1024)
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if string(got) != string(body) {
		t.Fatalf("body %q", got)
	}
	if !strings.Contains(string(conn.sent), "GET /pub/rel/release.go HTTP/1.0\r\n") {
		t.Fatalf("request %q", conn.sent)
	}

	// Non-200 -> channel_missing; chunked -> channel_malformed.
	conn2 := &fakeConn{in: []byte("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n")}
	httpDialFn = func(host string, port uint16) (httpConn, error) { return conn2, nil }
	_, err = ch.fetch("rel/missing", 1024)
	refuseCode(t, err, "channel_missing")

	conn3 := &fakeConn{in: []byte("HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")}
	httpDialFn = func(host string, port uint16) (httpConn, error) { return conn3, nil }
	_, err = ch.fetch("rel/x", 1024)
	refuseCode(t, err, "channel_malformed")

	if _, err := newHTTPChannel("http://no port"); err == nil {
		t.Fatal("accepted malformed URL")
	}
}

// streamAdvanceRelease simulates what `flint pull` lands when the remote
// head moved: a second signed Change modifying every release.go atom to
// the NEW src's hashes (same atom ids — modify keeps the folded key),
// then the stream record's head rolled to it.
func streamAdvanceRelease(t *testing.T, fs *memFS, src []byte, parent, id string) {
	t.Helper()
	p, ok := parser.ForPath("release.go")
	if !ok {
		t.Fatal("no parser for release.go")
	}
	atoms, err := p.Parse("release.go", src)
	if err != nil {
		t.Fatalf("parse release.go: %v", err)
	}
	change := Change{
		ID:     id,
		Parent: &parent,
		Stream: testStreamID,
		TS:     1760000001000,
		Author: strings.Repeat("ab", 32),
		Ops:    []Op{},
		Sig:    strings.Repeat("cd", 64),
	}
	for i, a := range atoms {
		span := Span{File: a.File, Start: a.Start, End: a.End}
		change.Ops = append(change.Ops, Op{
			Type:    "modify",
			AtomID:  fmt.Sprintf("0199de2d-dc00-7000-8000-00000000d%03d", i),
			Kind:    a.Kind,
			NewName: a.Name,
			NewSpan: &span,
			NewHash: hex.EncodeToString(a.Hash[:]),
		})
	}
	lb, _ := json.Marshal(change)
	fs.files[streamLogPath(DefaultStoreRoot, testStreamID)] =
		append(fs.files[streamLogPath(DefaultStoreRoot, testStreamID)], append(lb, '\n')...)
	var rec Stream
	if err := json.Unmarshal(fs.files[streamRecordPath(DefaultStoreRoot, testStreamID)], &rec); err != nil {
		t.Fatalf("stream record: %v", err)
	}
	rec.Head = &id
	rb, _ := json.Marshal(rec)
	fs.files[streamRecordPath(DefaultStoreRoot, testStreamID)] = append(rb, '\n')
}

// ---- install / remove end to end ------------------------------------------

func seedConsumer(t *testing.T) (*memFS, *fakeExec, *[]string, func()) {
	t.Helper()
	fs := newMemFS()
	fx := &fakeExec{fs: fs}
	prevExec := execFn
	execFn = fx.run
	prevSleep := sleepFn
	sleepFn = func(uint64) {}
	lines, restore := collectConsole()

	src := releaseGo("GOHELLO", "1.0.0", testELF, "GOHELLO.ELF | Go Hello | g | dock=false")
	streamWithRelease(t, fs, "rel", src)
	fs.dirs["/host/DROP"] = true
	fs.dirs["/host/DROP/rel"] = true
	fs.files["/host/DROP/rel/release.go"] = src
	fs.files["/host/DROP/rel/GOHELLO.ELF"] = testELF
	fs.files[appsPath] = []byte("GOCALC.ELF | 64-bit Calc | c | dock=true\n")

	fx.steps = []execStep{
		{match: "verify"},
	}
	prevScan := remoteStreamsFn
	remoteHead := "0199de2d-dc00-7000-8000-00000000c001"
	remoteStreamsFn = func(remote string) ([]Stream, error) {
		return []Stream{{ID: testStreamID, Name: "rel", Head: &remoteHead}}, nil
	}
	return fs, fx, lines, func() {
		execFn = prevExec
		sleepFn = prevSleep
		remoteStreamsFn = prevScan
		restore()
	}
}

func TestInstallHappy(t *testing.T) {
	fs, fx, lines, restore := seedConsumer(t)
	defer restore()

	rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
	if rc != 0 {
		t.Fatalf("install rc=%d lines=%v", rc, *lines)
	}
	joined := strings.Join(*lines, "\n")
	if !strings.Contains(joined, "store: install ok GOHELLO.ELF version=1.0.0") {
		t.Fatalf("missing ok line: %v", *lines)
	}
	if got := string(fs.files["/host/GOHELLO.ELF"]); got != string(testELF) {
		t.Fatalf("elf not installed: %q", got)
	}
	man := string(fs.files[appsPath])
	if !strings.Contains(man, "GOHELLO.ELF | Go Hello | g | dock=false\n") {
		t.Fatalf("row missing: %q", man)
	}
	// The materialization gate runs the keyring (--trusted) bound to the
	// exact log bytes folded (--expect=<id>:<sha256>).
	logSHA := shaHex(fs.files[streamLogPath(DefaultStoreRoot, testStreamID)])
	if !strings.Contains(strings.Join(fx.log, "|"),
		"verify --all --trusted --expect="+testStreamID+":"+logSHA) {
		t.Fatalf("verify not trusted+bound: %v", fx.log)
	}
}

func TestInstallClonePath(t *testing.T) {
	fs, fx, lines, restore := seedConsumer(t)
	defer restore()
	// Consumer with an empty FLINT store: install must clone.
	fs.files = map[string][]byte{}
	fs.dirs = map[string]bool{"/host": true, "/host/DROP": true, "/host/DROP/rel": true}
	src := releaseGo("GOHELLO", "1.0.0", testELF, "GOHELLO.ELF | Go Hello | g | dock=false")
	fs.files["/host/DROP/rel/release.go"] = src
	fs.files["/host/DROP/rel/GOHELLO.ELF"] = testELF
	fs.files[appsPath] = []byte("")
	cloneSeen := false
	prevRun := fx.run
	_ = prevRun
	fx.steps = []execStep{
		{match: "clone"},
		{match: "verify"},
	}
	// The clone "lands" the stream: fake exec writes the stream files too.
	origExec := execFn
	execFn = func(name string, args ...string) (int64, error) {
		rc, err := fx.run(name, args...)
		if strings.Contains(strings.Join(args, " "), "clone") {
			streamWithRelease(t, fs, "rel", fs.files["/host/DROP/rel/release.go"])
			cloneSeen = true
		}
		return rc, err
	}
	defer func() { execFn = origExec }()

	rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
	if rc != 0 || !cloneSeen {
		t.Fatalf("rc=%d cloneSeen=%v lines=%v", rc, cloneSeen, *lines)
	}
}

func TestInstallRefusals(t *testing.T) {
	mk := func(t *testing.T, mutate func(fs *memFS, fx *fakeExec)) (*memFS, *[]string, func()) {
		fs, fx, lines, restore := seedConsumer(t)
		mutate(fs, fx)
		return fs, lines, restore
	}

	t.Run("sync refusal fails install closed", func(t *testing.T) {
		// The child's `flint: refuse key_unknown` prints to the console on
		// its own; STORE sees only the nonzero exit and maps it to
		// sync_failed — the named-refusal contract holds either way.
		fs, lines, restore := mk(t, func(fs *memFS, fx *fakeExec) {
			delete(fs.files, streamRecordPath(DefaultStoreRoot, testStreamID))
			fx.steps = []execStep{{match: "clone", status: 1}}
		})
		defer restore()
		if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
			t.Fatalf("rc=%d", rc)
		}
		joined := strings.Join(*lines, "\n")
		if !strings.Contains(joined, "store: refuse sync_failed") {
			t.Fatalf("refusal not mapped: %v", *lines)
		}
		if _, ok := fs.files["/host/GOHELLO.ELF"]; ok {
			t.Fatal("partial ELF landed on refusal")
		}
	})

	t.Run("elf_mismatch leaves zero state", func(t *testing.T) {
		fs, lines, restore := mk(t, func(fs *memFS, fx *fakeExec) {
			fs.files["/host/DROP/rel/GOHELLO.ELF"] = []byte("tampered elf")
		})
		defer restore()
		rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
		if rc != 1 || !strings.Contains(strings.Join(*lines, "\n"), "store: refuse elf_mismatch") {
			t.Fatalf("rc=%d %v", rc, *lines)
		}
		if _, ok := fs.files["/host/GOHELLO.ELF"]; ok {
			t.Fatal("tampered ELF installed")
		}
		if manifestHasBin(strings.Split(string(fs.files[appsPath]), "\n"), "GOHELLO.ELF") {
			t.Fatal("row written on elf_mismatch")
		}
	})

	t.Run("release_mismatch leaves zero state", func(t *testing.T) {
		fs, lines, restore := mk(t, func(fs *memFS, fx *fakeExec) {
			fs.files["/host/DROP/rel/release.go"] = releaseGo("GOHELLO", "2.0.0", testELF, "GOHELLO.ELF | Go Hello | g | dock=false")
		})
		defer restore()
		rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
		if rc != 1 || !strings.Contains(strings.Join(*lines, "\n"), "store: refuse release_mismatch") {
			t.Fatalf("rc=%d %v", rc, *lines)
		}
		if _, ok := fs.files["/host/GOHELLO.ELF"]; ok {
			t.Fatal("ELF installed on release_mismatch")
		}
	})

	t.Run("already_installed", func(t *testing.T) {
		fs, lines, restore := mk(t, func(fs *memFS, fx *fakeExec) {
			fs.files[appsPath] = []byte("GOHELLO.ELF | Go Hello | g | dock=false\n")
		})
		defer restore()
		rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
		if rc != 1 || !strings.Contains(strings.Join(*lines, "\n"), "store: refuse already_installed") {
			t.Fatalf("rc=%d %v", rc, *lines)
		}
	})

	t.Run("verify refusal fails install closed", func(t *testing.T) {
		// The child's `flint: refuse key_unknown`/`key_revoked` (the
		// --trusted gate) prints on its own; STORE maps the nonzero exit
		// to sync_failed and publishes nothing.
		fs, lines, restore := mk(t, func(fs *memFS, fx *fakeExec) {
			fx.steps = []execStep{{match: "verify", status: 1}}
		})
		defer restore()
		if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
			t.Fatalf("rc=%d", rc)
		}
		if !strings.Contains(strings.Join(*lines, "\n"), "store: refuse sync_failed") {
			t.Fatalf("refusal not mapped: %v", *lines)
		}
		if _, ok := fs.files["/host/GOHELLO.ELF"]; ok {
			t.Fatal("partial ELF landed on verify refusal")
		}
	})

	t.Run("channel_missing release.go", func(t *testing.T) {
		fs, lines, restore := mk(t, func(fs *memFS, fx *fakeExec) {
			delete(fs.files, "/host/DROP/rel/release.go")
		})
		defer restore()
		rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
		if rc != 1 || !strings.Contains(strings.Join(*lines, "\n"), "store: refuse channel_missing") {
			t.Fatalf("rc=%d %v", rc, *lines)
		}
	})

	t.Run("remote_missing", func(t *testing.T) {
		fs, lines, restore := mk(t, func(fs *memFS, fx *fakeExec) {})
		defer restore()
		rc := Install(fs, DefaultStoreRoot, "rel", "", "/host/DROP")
		if rc != 1 || !strings.Contains(strings.Join(*lines, "\n"), "store: refuse remote_missing") {
			t.Fatalf("rc=%d %v", rc, *lines)
		}
	})

	t.Run("manifest write failure reverts elf", func(t *testing.T) {
		fs, _, restore := mk(t, func(fs *memFS, fx *fakeExec) {
			fs.beforeWrite = func(op, path string) error {
				if path == appsPath {
					return newFSErr("write", path, -5)
				}
				return nil
			}
		})
		defer restore()
		rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
		if rc != 1 {
			t.Fatalf("rc=%d", rc)
		}
		if _, ok := fs.files["/host/GOHELLO.ELF"]; ok {
			t.Fatal("ELF not reverted on manifest failure")
		}
	})
}

func TestRemove(t *testing.T) {
	fs, _, _, restore := seedConsumer(t)
	defer restore()
	fs.files[appsPath] = []byte("GOCALC.ELF | Calc | c | dock=true\nGOHELLO.ELF | Go Hello | g | dock=false\n")
	fs.files["/host/GOHELLO.ELF"] = testELF

	if rc := Remove(fs, "gohello"); rc != 0 {
		t.Fatal("remove rc != 0")
	}
	if _, ok := fs.files["/host/GOHELLO.ELF"]; ok {
		t.Fatal("ELF survived remove")
	}
	if manifestHasBin(strings.Split(string(fs.files[appsPath]), "\n"), "GOHELLO.ELF") {
		t.Fatal("row survived remove")
	}
	if !strings.Contains(string(fs.files[appsPath]), "GOCALC.ELF") {
		t.Fatal("unrelated row lost")
	}

	if rc := Remove(fs, "GOHELLO"); rc != 1 {
		t.Fatal("remove of absent should refuse")
	}
	if rc := Remove(fs, "..bad"); rc != 1 {
		t.Fatal("bad name should refuse")
	}
}

// ---- store ls + wire client -----------------------------------------------

func TestLs(t *testing.T) {
	fs, _, lines, restore := seedConsumer(t)
	defer restore()

	// Remote `rel` head matches the seeded local record -> no pull;
	// remote `main` is absent locally -> clone lands a no-release record.
	head := "0199de2d-dc00-7000-8000-00000000c001"
	prev := remoteStreamsFn
	defer func() { remoteStreamsFn = prev }()
	remoteStreamsFn = func(remote string) ([]Stream, error) {
		if remote != "10.0.0.2:4749" {
			t.Fatalf("remote %q", remote)
		}
		return []Stream{
			{ID: "0199de2d-dc00-7000-8000-00000000ffff", Name: "main", Head: &head},
			{ID: testStreamID, Name: "rel", Head: &head},
		}, nil
	}
	execFn = func(name string, args ...string) (int64, error) {
		joined := strings.Join(args, " ")
		if !strings.Contains(joined, "clone") {
			t.Fatalf("unexpected exec args %v", args)
		}
		// The remote clone lands a stream with no release.go atoms.
		rec := Stream{ID: "0199de2d-dc00-7000-8000-00000000ffff", Name: "main", Head: &head, Created: 1}
		rb, _ := json.Marshal(rec)
		fs.files[streamRecordPath(DefaultStoreRoot, rec.ID)] = append(rb, '\n')
		change := Change{ID: head, Stream: rec.ID, Author: strings.Repeat("ab", 32),
			Ops: []Op{}, Sig: strings.Repeat("cd", 64)}
		lb, _ := json.Marshal(change)
		fs.files[streamLogPath(DefaultStoreRoot, rec.ID)] = append(lb, '\n')
		return 0, nil
	}

	rc := Ls(fs, DefaultStoreRoot, "10.0.0.2:4749", "/host/DROP", "", "")
	if rc != 0 {
		t.Fatalf("ls rc=%d lines=%v", rc, *lines)
	}
	joined := strings.Join(*lines, "\n")
	if !strings.Contains(joined, "store: stream rel release") ||
		!strings.Contains(joined, "store: stream main no-release") ||
		!strings.Contains(joined, "store: ls ok") {
		t.Fatalf("unexpected ls output: %v", *lines)
	}
}

// releaseGoCat renders a release.go carrying the ADR 0055 optional
// catalog consts alongside the required four ("" omits a const).
func releaseGoCat(name, version string, elf []byte, row, summary, desc, cat, icon string) []byte {
	src := string(releaseGo(name, version, elf, row))
	emit := func(cname, val string) {
		if val != "" {
			src += fmt.Sprintf("const %s = %q\n", cname, val)
		}
	}
	emit("ReleaseSummary", summary)
	emit("ReleaseDescription", desc)
	emit("ReleaseCategory", cat)
	emit("ReleaseIconSHA256", icon)
	return []byte(src)
}

// ---- ADR 0055 catalog fields ----------------------------------------------

func TestParseReleaseCatalog(t *testing.T) {
	icon := strings.Repeat("9f", 32)
	src := releaseGoCat("GOHELLO", "1.0.0", testELF,
		"GOHELLO.ELF | Go Hello | g | dock=false",
		"Greets the guest", "Line one.\nLine two.", "demo", icon)
	rel, err := parseRelease(src)
	if err != nil {
		t.Fatalf("parseRelease catalog: %v", err)
	}
	if rel.Summary != "Greets the guest" || rel.Description != "Line one.\nLine two." ||
		rel.Category != "demo" || rel.IconSHA256 != icon {
		t.Fatalf("catalog fields: %+v", rel)
	}

	// A legacy four-const release parses with empty catalog fields.
	rel, err = parseRelease(releaseGo("GOHELLO", "1.0.0", testELF, "GOHELLO.ELF | X | x"))
	if err != nil || rel.Summary != "" || rel.Category != "" || rel.IconSHA256 != "" || rel.Description != "" {
		t.Fatalf("legacy release: %+v err=%v", rel, err)
	}

	// Unknown signed consts are ignored (D4) — including identity-claiming
	// names, which must never render as publisher information (D5).
	unknown := append(releaseGo("GOHELLO", "1.0.0", testELF, "GOHELLO.ELF | X | x"),
		[]byte("const ReleasePublisher = \"mallory\"\nconst ReleaseFuture = \"x\"\n")...)
	rel, err = parseRelease(unknown)
	if err != nil || rel.Name != "GOHELLO" {
		t.Fatalf("unknown consts not ignored: %v %+v", err, rel)
	}

	for _, tc := range []struct {
		name string
		src  []byte
		want string
	}{
		{"summary empty", releaseGoCat("GOHELLO", "1", testELF, "GOHELLO.ELF | X | x", "", "", "", ""), ""}, // skipped below
		{"summary control", releaseGoCat("GOHELLO", "1", testELF, "GOHELLO.ELF | X | x", "a\tb", "", "", ""), "summary_invalid"},
		{"summary long", releaseGoCat("GOHELLO", "1", testELF, "GOHELLO.ELF | X | x", strings.Repeat("s", 129), "", "", ""), "summary_invalid"},
		{"summary bad utf8", releaseGoCat("GOHELLO", "1", testELF, "GOHELLO.ELF | X | x", "a\xffb", "", "", ""), "summary_invalid"},
		{"description tab", releaseGoCat("GOHELLO", "1", testELF, "GOHELLO.ELF | X | x", "", "a\tb", "", ""), "description_invalid"},
		{"description ok newline", releaseGoCat("GOHELLO", "1", testELF, "GOHELLO.ELF | X | x", "", "a\nb", "", ""), ""},
		{"category bad", releaseGoCat("GOHELLO", "1", testELF, "GOHELLO.ELF | X | x", "", "", "gaming", ""), "category_unknown"},
		{"category ok", releaseGoCat("GOHELLO", "1", testELF, "GOHELLO.ELF | X | x", "", "", "net", ""), ""},
		{"icon short", releaseGoCat("GOHELLO", "1", testELF, "GOHELLO.ELF | X | x", "", "", "", "abcd"), "hash_invalid"},
		{"icon upper", releaseGoCat("GOHELLO", "1", testELF, "GOHELLO.ELF | X | x", "", "", "", strings.Repeat("9F", 32)), "hash_invalid"},
	} {
		if tc.want == "" {
			if _, err := parseRelease(tc.src); err != nil {
				t.Fatalf("%s: unexpected refusal %v", tc.name, err)
			}
			continue
		}
		_, err := parseRelease(tc.src)
		refuseCode(t, err, tc.want)
	}
}

func TestKeyring(t *testing.T) {
	pub1, pub2, bad := strings.Repeat("ab", 32), strings.Repeat("e5", 32), strings.Repeat("0f", 32)
	body := "#v1\n" +
		"key=" + pub1 + " name=sync-seed\n" +
		"key=" + pub2 + " name=acme\n" +
		"revoked=" + bad + "\n"
	kr, err := parseKeyring([]byte(body))
	if err != nil {
		t.Fatalf("parseKeyring: %v", err)
	}
	if st, label := kr.publisherState(pub1); st != "trusted" || label != "sync-seed" {
		t.Fatalf("pub1: %s %q", st, label)
	}
	if st, _ := kr.publisherState(bad); st != "revoked" {
		t.Fatalf("bad: %s", st)
	}
	if st, _ := kr.publisherState(strings.Repeat("11", 32)); st != "unknown" {
		t.Fatalf("unknown: %s", st)
	}
	for _, corrupt := range []string{
		"", "#v2\nkey=" + pub1 + " name=x\n",
		"#v1\nkey=zz name=x\n",
		"#v1\nkey=" + pub1 + "\n",
		"#v1\nkey=" + pub1 + " name=a\nkey=" + pub1 + " name=b\n",
		"#v1\nbogus=1\n",
	} {
		if _, err := parseKeyring([]byte(corrupt)); err == nil {
			t.Fatalf("accepted corrupt keyring %q", corrupt)
		} else {
			refuseCode(t, err, "keyring_malformed")
		}
	}
	fs := newMemFS()
	if _, err := loadKeyring(fs, DefaultStoreRoot); err == nil {
		t.Fatal("absent keyring accepted")
	} else {
		refuseCode(t, err, "keyring_missing")
	}
}

// seedCatalog adds the second publisher's stream (rel2, author e5*32) plus
// TRUSTED.TXT to a seeded consumer and returns it.
func seedCatalog(t *testing.T, fs *memFS) {
	t.Helper()
	src2 := releaseGoCat("BOUNCE", "1.4.0", testELF,
		"BOUNCE.ELF | Bounce | g | dock=false",
		"A bouncing ball demo", "Renders a ball.\nSecond line.", "game",
		strings.Repeat("42", 32))
	streamWithReleaseAs(t, fs, "rel2", "0199de2d-dc00-7000-8000-00000000c200",
		"0199de2d-dc00-7000-8000-00000000c201", strings.Repeat("e5", 32), src2)
	fs.dirs["/host/DROP/rel2"] = true
	fs.files["/host/DROP/rel2/release.go"] = src2
	fs.files["/host/DROP/rel2/BOUNCE.ELF"] = testELF
	fs.files[keyringPath(DefaultStoreRoot)] = []byte(
		"#v1\nkey=" + strings.Repeat("ab", 32) + " name=sync-seed\n" +
			"key=" + strings.Repeat("e5", 32) + " name=acme\n")
}

func TestLsCatalog(t *testing.T) {
	fs, _, lines, restore := seedConsumer(t)
	defer restore()
	seedCatalog(t, fs)
	head := "0199de2d-dc00-7000-8000-00000000c001"
	head2 := "0199de2d-dc00-7000-8000-00000000c201"
	prev := remoteStreamsFn
	defer func() { remoteStreamsFn = prev }()
	remoteStreamsFn = func(remote string) ([]Stream, error) {
		return []Stream{
			{ID: testStreamID, Name: "rel", Head: &head},
			{ID: "0199de2d-dc00-7000-8000-00000000c200", Name: "rel2", Head: &head2},
		}, nil
	}
	execFn = func(name string, args ...string) (int64, error) {
		t.Fatalf("unexpected exec %v — replicas are current", args)
		return 1, nil
	}

	rc := Ls(fs, DefaultStoreRoot, "10.0.0.2:4749", "/host/DROP", "", "")
	if rc != 0 {
		t.Fatalf("ls rc=%d lines=%v", rc, *lines)
	}
	joined := strings.Join(*lines, "\n")
	for _, want := range []string{
		"store: stream rel release name=GOHELLO version=1.0.0 category=-",
		"store: stream rel2 release name=BOUNCE version=1.4.0 category=game",
		"publisher=" + strings.Repeat("ab", 32) + " publisher_name=sync-seed publisher_state=trusted",
		"publisher=" + strings.Repeat("e5", 32) + " publisher_name=acme publisher_state=trusted",
		"summary=A bouncing ball demo",
		"store: ls ok entries=2",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing %q in:\n%s", want, joined)
		}
	}

	// --category keeps only matching catalog entries.
	*lines = nil
	rc = Ls(fs, DefaultStoreRoot, "10.0.0.2:4749", "/host/DROP", "", "game")
	if rc != 0 {
		t.Fatalf("ls --category rc=%d", rc)
	}
	joined = strings.Join(*lines, "\n")
	if !strings.Contains(joined, "store: stream rel2 release") ||
		strings.Contains(joined, "store: stream rel release") ||
		!strings.Contains(joined, "store: ls ok entries=1") {
		t.Fatalf("category filter wrong:\n%s", joined)
	}

	// --search matches summary/name case-insensitively.
	*lines = nil
	rc = Ls(fs, DefaultStoreRoot, "10.0.0.2:4749", "/host/DROP", "BOUNCING", "")
	if rc != 0 {
		t.Fatalf("ls --search rc=%d", rc)
	}
	joined = strings.Join(*lines, "\n")
	if !strings.Contains(joined, "store: stream rel2 release") ||
		strings.Contains(joined, "store: stream rel release") {
		t.Fatalf("search filter wrong:\n%s", joined)
	}

	// A tampered channel release.go marks the stream release-invalid
	// (verified against the signed atoms) and does not fail the listing.
	fs.files["/host/DROP/rel/release.go"] = releaseGo("GOHELLO", "9.9.9", testELF, "GOHELLO.ELF | Go Hello | g | dock=false")
	*lines = nil
	rc = Ls(fs, DefaultStoreRoot, "10.0.0.2:4749", "/host/DROP", "", "")
	if rc != 0 {
		t.Fatalf("ls tampered rc=%d", rc)
	}
	joined = strings.Join(*lines, "\n")
	if !strings.Contains(joined, "store: stream rel catalog-invalid release_mismatch") ||
		!strings.Contains(joined, "store: stream rel2 release") ||
		!strings.Contains(joined, "store: ls ok entries=1") {
		t.Fatalf("tampered catalog wrong:\n%s", joined)
	}
}

func TestInfo(t *testing.T) {
	fs, _, lines, restore := seedConsumer(t)
	defer restore()
	seedCatalog(t, fs)
	head := "0199de2d-dc00-7000-8000-00000000c001"
	head2 := "0199de2d-dc00-7000-8000-00000000c201"
	prev := remoteStreamsFn
	defer func() { remoteStreamsFn = prev }()
	remoteStreamsFn = func(remote string) ([]Stream, error) {
		return []Stream{
			{ID: testStreamID, Name: "rel", Head: &head},
			{ID: "0199de2d-dc00-7000-8000-00000000c200", Name: "rel2", Head: &head2},
		}, nil
	}
	execFn = func(name string, args ...string) (int64, error) {
		t.Fatalf("unexpected exec %v", args)
		return 1, nil
	}

	// By stream name.
	rc := Info(fs, DefaultStoreRoot, "rel2", "10.0.0.2:4749", "/host/DROP")
	if rc != 0 {
		t.Fatalf("info rc=%d lines=%v", rc, *lines)
	}
	joined := strings.Join(*lines, "\n")
	for _, want := range []string{
		"store: name BOUNCE", "store: version 1.4.0", "store: category game",
		"store: summary A bouncing ball demo",
		"store: icon_sha256 " + strings.Repeat("42", 32),
		"store: publisher " + strings.Repeat("e5", 32) + " publisher_name=acme publisher_state=trusted",
		"store: head " + head2,
		"store: installed no",
		"store: row BOUNCE.ELF | Bounce | g | dock=false",
		"store:   Renders a ball.", "store:   Second line.",
		"store: info ok",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing %q in:\n%s", want, joined)
		}
	}

	// By ReleaseName (the fallback scan).
	*lines = nil
	rc = Info(fs, DefaultStoreRoot, "bounce", "10.0.0.2:4749", "/host/DROP")
	if rc != 0 || !strings.Contains(strings.Join(*lines, "\n"), "store: name BOUNCE") {
		t.Fatalf("info by ReleaseName rc=%d:\n%s", rc, strings.Join(*lines, "\n"))
	}

	// Unknown selector -> stream_missing.
	*lines = nil
	rc = Info(fs, DefaultStoreRoot, "nope", "10.0.0.2:4749", "/host/DROP")
	if rc != 1 || !strings.Contains(strings.Join(*lines, "\n"), "store: refuse stream_missing") {
		t.Fatalf("info unknown rc=%d:\n%s", rc, strings.Join(*lines, "\n"))
	}

	// A tampered channel manifest refuses by name.
	fs.files["/host/DROP/rel/release.go"] = releaseGoCat("GOHELLO", "1.0.0", testELF,
		"GOHELLO.ELF | Go Hello | g | dock=false", "tampered", "", "", "")
	*lines = nil
	rc = Info(fs, DefaultStoreRoot, "rel", "10.0.0.2:4749", "/host/DROP")
	if rc != 1 || !strings.Contains(strings.Join(*lines, "\n"), "store: refuse release_mismatch") {
		t.Fatalf("info tampered rc=%d:\n%s", rc, strings.Join(*lines, "\n"))
	}
}

// TestWireHandshake drives syncClient.handshake+list over the scripted
// fakeConn: ungated hello, a nonce round, then the list response.
func TestWireHandshake(t *testing.T) {
	streamList := `{"seq":4,"ok":true,"streams":[{"id":"i1","name":"rel","head":"h"}]}` + "\n"
	conn := &fakeConn{in: []byte(
		`{"seq":1,"ok":false,"refuse":"auth_required","nonce":"` + strings.Repeat("ab", 16) + `"}` + "\n" +
			`{"seq":2,"ok":true}` + "\n" +
			`{"seq":3,"ok":true,"proto":"FLINT-SYNC/1"}` + "\n" +
			streamList)}
	key := [32]byte{9}
	c := &syncClient{conn: conn}
	if err := c.handshake(&key); err != nil {
		t.Fatalf("handshake: %v", err)
	}
	streams, err := c.list()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(streams) != 1 || streams[0].Name != "rel" {
		t.Fatalf("streams %v", streams)
	}
	if !strings.Contains(string(conn.sent), `"op":"auth"`) ||
		!strings.Contains(string(conn.sent), `"nonce":"`+strings.Repeat("ab", 16)+`"`) {
		t.Fatalf("auth request missing: %s", conn.sent)
	}
}

// TestWireHandshakeRefusals: the daemon's named refusals surface as
// RefuseError codes unchanged.
func TestWireHandshakeRefusals(t *testing.T) {
	conn := &fakeConn{in: []byte(`{"seq":1,"ok":false,"refuse":"auth_failed"}` + "\n")}
	c := &syncClient{conn: conn}
	err := c.handshake(&[32]byte{})
	refuseCode(t, err, "auth_failed")

	conn2 := &fakeConn{in: []byte(`{"seq":1,"ok":true,"proto":"FLINT-SYNC/1"}` + "\n" +
		`{"seq":2,"ok":false,"refuse":"stream_missing","detail":"rel"}` + "\n")}
	c2 := &syncClient{conn: conn2}
	if err := c2.handshake(nil); err != nil {
		t.Fatalf("handshake: %v", err)
	}
	_, err = c2.list()
	refuseCode(t, err, "stream_missing")
}

// ---- M101d: state file, update, rollback -----------------------------------

const (
	testChangeV1 = "0199de2d-dc00-7000-8000-00000000c001"
	testChangeV2 = "0199de2d-dc00-7000-8000-00000000c002"
	testChangeV3 = "0199de2d-dc00-7000-8000-00000000c003"
)

var testELFv2 = []byte("fake guest elf bytes v2 payload, deliberately different")
var testELFv3 = []byte("fake guest elf bytes v3 payload, different again")

const (
	rowV1 = "GOHELLO.ELF | Go Hello | g | dock=false"
	rowV2 = "GOHELLO.ELF | Go Hello 2 | g | dock=true | v=2"
	rowV3 = "GOHELLO.ELF | Go Hello 3 | g | dock=true | v=3"
)

func shaHex(b []byte) string {
	s := sshlib.SHA256Sum(b)
	return sshlib.EncodeHex(s[:])
}

func stateEntry(t *testing.T, fs *memFS, bin string) *storeEntry {
	t.Helper()
	state, err := loadState(fs)
	if err != nil {
		t.Fatalf("loadState: %v", err)
	}
	e, ok := state[bin]
	if !ok {
		t.Fatalf("no STORE.TXT entry for %s: %q", bin, fs.files[statePath])
	}
	return e
}

// seedConsumerV2 is seedConsumer plus the staged v2: the local replica
// carries the second signed change (what a pull would land) and the drop
// dir serves the v2 release.go + ELF.
func seedConsumerV2(t *testing.T, fs *memFS) {
	t.Helper()
	srcV2 := releaseGo("GOHELLO", "2.0.0", testELFv2, rowV2)
	streamAdvanceRelease(t, fs, srcV2, testChangeV1, testChangeV2)
	fs.files["/host/DROP/rel/release.go"] = srcV2
	fs.files["/host/DROP/rel/GOHELLO.ELF"] = testELFv2
}

// TestStateFile covers the STORE.TXT grammar: round-trip, all-or-none
// prev_*, and refuse-whole on any corrupt line.
func TestStateFile(t *testing.T) {
	fs := newMemFS()
	if !fs.Exists(statePath) {
		state, err := loadState(fs)
		if err != nil || len(state) != 0 {
			t.Fatalf("absent state: %v %v", state, err)
		}
	}
	row := "GOHELLO.ELF | Go Hello | g | dock=false"
	want := map[string]*storeEntry{
		"GOHELLO.ELF": {Name: "GOHELLO.ELF", Stream: "rel", Head: "h1",
			SHA256:   shaHex(testELF),
			PrevHead: "h0", PrevSHA: shaHex(testELFv2), PrevRow: row},
		"GOCALC.ELF": {Name: "GOCALC.ELF", Stream: "calc", Head: "h9",
			SHA256: shaHex(testELFv2)},
	}
	if err := fs.WriteFileSafe(statePath, renderState(want)); err != nil {
		t.Fatal(err)
	}
	got, err := loadState(fs)
	if err != nil {
		t.Fatalf("loadState: %v", err)
	}
	if len(got) != 2 || got["GOHELLO.ELF"].PrevRow != row ||
		got["GOHELLO.ELF"].PrevHead != "h0" ||
		got["GOCALC.ELF"].PrevHead != "" || got["GOCALC.ELF"].PrevSHA != "" ||
		got["GOCALC.ELF"].PrevRow != "" {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
	// Render is deterministic: a no-change rewrite is byte-identical.
	before := string(fs.files[statePath])
	if err := fs.WriteFileSafe(statePath, renderState(got)); err != nil {
		t.Fatal(err)
	}
	if string(fs.files[statePath]) != before {
		t.Fatal("renderState not deterministic")
	}
	for _, bad := range []string{
		"name=GOHELLO.ELF stream=rel head=h1 sha256=" + shaHex(testELF) + " prev_head=- prev_sha256=- prev_row=- trailing_garbage\n",
		"name=GOHELLO.ELF stream=rel head=h1 sha256=" + shaHex(testELF) + " prev_head=h0 prev_sha256=- prev_row=-\n",
		"name=go hello.ELF stream=rel head=h1 sha256=" + shaHex(testELF) + " prev_head=- prev_sha256=- prev_row=-\n",
		"name=GOHELLO.ELF stream=rel head=h1 sha256=zz prev_head=- prev_sha256=- prev_row=-\n",
		"name=GOHELLO.ELF head=h1 sha256=" + shaHex(testELF) + " prev_head=- prev_sha256=- prev_row=-\n",
	} {
		fs.files[statePath] = []byte(bad)
		if _, err := loadState(fs); err == nil {
			t.Fatalf("accepted corrupt state: %q", bad)
		} else {
			re := err.(*RefuseError)
			if re.Code != "state_malformed" {
				t.Fatalf("wrong refusal %q for %q", re.Code, bad)
			}
		}
	}
}

// TestUpdateRollbackRoundTrip is the card's acceptance: install v1 ->
// update v2 -> rollback v1, asserted byte-for-byte on the ELF and the
// manifest row.
func TestUpdateRollbackRoundTrip(t *testing.T) {
	fs, fx, lines, restore := seedConsumer(t)
	defer restore()

	if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("install rc=%d lines=%v", rc, *lines)
	}
	manifestV1 := string(fs.files[appsPath])
	e := stateEntry(t, fs, "GOHELLO.ELF")
	if e.Head != testChangeV1 || e.SHA256 != shaHex(testELF) ||
		e.Stream != "rel" || e.PrevHead != "" {
		t.Fatalf("post-install state %+v", e)
	}

	seedConsumerV2(t, fs)
	if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("update rc=%d lines=%v", rc, *lines)
	}
	joined := strings.Join(*lines, "\n")
	if !strings.Contains(joined, "store: update ok GOHELLO.ELF version=2.0.0") {
		t.Fatalf("missing update ok: %v", *lines)
	}
	if got := fs.files["/host/GOHELLO.ELF"]; string(got) != string(testELFv2) {
		t.Fatal("update did not land v2 ELF bytes")
	}
	man := string(fs.files[appsPath])
	if !strings.Contains(man, rowV2+"\n") || strings.Contains(man, rowV1) {
		t.Fatalf("row not replaced in place: %q", man)
	}
	if got := fs.files[prevPath("GOHELLO.ELF")]; string(got) != string(testELF) {
		t.Fatal("prev ELF not retained")
	}
	e = stateEntry(t, fs, "GOHELLO.ELF")
	if e.Head != testChangeV2 || e.PrevHead != testChangeV1 ||
		e.PrevSHA != shaHex(testELF) || e.PrevRow != rowV1 {
		t.Fatalf("post-update state %+v", e)
	}
	if !strings.Contains(strings.Join(fx.log, "|"), "pull") ||
		!strings.Contains(strings.Join(fx.log, "|"), "verify --all --trusted") {
		t.Fatalf("update skipped pull/verify: %v", fx.log)
	}

	if rc := Rollback(fs, "gohello"); rc != 0 {
		t.Fatalf("rollback rc=%d lines=%v", rc, *lines)
	}
	if got := fs.files["/host/GOHELLO.ELF"]; string(got) != string(testELF) {
		t.Fatal("rollback ELF is not byte-for-byte v1")
	}
	if string(fs.files[appsPath]) != manifestV1 {
		t.Fatalf("manifest row not byte-for-byte restored: %q want %q",
			fs.files[appsPath], manifestV1)
	}
	e = stateEntry(t, fs, "GOHELLO.ELF")
	if e.Head != testChangeV1 || e.PrevHead != testChangeV2 ||
		e.PrevSHA != shaHex(testELFv2) || e.PrevRow != rowV2 {
		t.Fatalf("post-rollback state %+v", e)
	}
	if got := fs.files[prevPath("GOHELLO.ELF")]; string(got) != string(testELFv2) {
		t.Fatal(".prev did not rotate to the rolled-back-from ELF")
	}

	// The swapped pair toggles: a second rollback returns to v2.
	if rc := Rollback(fs, "GOHELLO"); rc != 0 {
		t.Fatalf("second rollback rc=%d", rc)
	}
	if got := fs.files["/host/GOHELLO.ELF"]; string(got) != string(testELFv2) {
		t.Fatal("second rollback did not restore v2")
	}
	if !strings.Contains(string(fs.files[appsPath]), rowV2+"\n") {
		t.Fatal("second rollback did not restore the v2 row")
	}
}

// TestUpdateVerifyRefusal: the materialization gate refusing inside the
// child (the --trusted keyring leg or the log bind) leaves the installed
// v1 byte-identical — nothing is re-fetched or republished.
func TestUpdateVerifyRefusal(t *testing.T) {
	fs, fx, lines, restore := seedConsumer(t)
	defer restore()
	if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("install rc=%d", rc)
	}
	seedConsumerV2(t, fs)
	fx.steps = []execStep{{match: "verify", status: 1}}
	elf, apps, state := string(fs.files["/host/GOHELLO.ELF"]),
		string(fs.files[appsPath]), string(fs.files[statePath])
	if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	if !strings.Contains(strings.Join(*lines, "\n"), "store: refuse sync_failed") {
		t.Fatalf("%v", *lines)
	}
	if string(fs.files["/host/GOHELLO.ELF"]) != elf ||
		string(fs.files[appsPath]) != apps ||
		string(fs.files[statePath]) != state {
		t.Fatal("verify refusal mutated installed state")
	}
}

// TestUpdateUpToDate: a pull that lands no head movement is a no-op
// success — nothing is re-verified or republished.
func TestUpdateUpToDate(t *testing.T) {
	fs, _, lines, restore := seedConsumer(t)
	defer restore()
	if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("install rc=%d", rc)
	}
	if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("update rc=%d lines=%v", rc, *lines)
	}
	if !strings.Contains(strings.Join(*lines, "\n"), "store: update GOHELLO.ELF up to date") {
		t.Fatalf("missing up-to-date line: %v", *lines)
	}
	if _, ok := fs.files[prevPath("GOHELLO.ELF")]; ok {
		t.Fatal("up-to-date update wrote .prev")
	}
}

// TestUpdateInterrupted is the card's second acceptance leg: a kill
// between staging and the state commit leaves the old install live —
// the ELF, APPS.TXT, and STORE.TXT stay byte-identical — and a kill
// after the commit can never destroy the rollback target.
func TestUpdateInterrupted(t *testing.T) {
	fs, _, _, restore := seedConsumer(t)
	defer restore()
	if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("install rc=%d", rc)
	}
	seedConsumerV2(t, fs)
	elfV1 := fs.files["/host/GOHELLO.ELF"]
	appsV1 := fs.files[appsPath]
	stateV1 := fs.files[statePath]

	failOn := func(path string) {
		fs.beforeWrite = func(op, p string) error {
			if p == path {
				return newFSErr("write", p, -5)
			}
			return nil
		}
	}

	// Kill at the staged .prev.new write (the first publish step):
	// nothing moved.
	failOn(prevStagePath("GOHELLO.ELF"))
	if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	if string(fs.files["/host/GOHELLO.ELF"]) != string(elfV1) ||
		string(fs.files[appsPath]) != string(appsV1) ||
		string(fs.files[statePath]) != string(stateV1) {
		t.Fatal("kill at stage write disturbed live state")
	}
	if fs.Exists(prevStagePath("GOHELLO.ELF")) {
		t.Fatal(".prev.new exists despite its write being refused")
	}

	// Kill at the ELF publish itself: .prev.new staged (a harmless
	// orphan the next update overwrites), but the old install is
	// byte-identical — and .prev was never touched.
	failOn("/host/GOHELLO.ELF")
	if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	if string(fs.files["/host/GOHELLO.ELF"]) != string(elfV1) ||
		string(fs.files[appsPath]) != string(appsV1) ||
		string(fs.files[statePath]) != string(stateV1) {
		t.Fatal("kill at ELF publish disturbed live state")
	}
	if got := fs.files[prevStagePath("GOHELLO.ELF")]; string(got) != string(elfV1) {
		t.Fatal("staged .prev.new missing the old ELF bytes")
	}
	if fs.Exists(prevPath("GOHELLO.ELF")) {
		t.Fatal(".prev written before the commit")
	}

	// Kill at the state write (the commit): ELF+row moved but the head
	// pair did not — the next command detects the torn publish via the
	// state sha256 instead of rolling forward on a lie.
	failOn(statePath)
	if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	e := stateEntry(t, fs, "GOHELLO.ELF")
	if e.Head != testChangeV1 || e.PrevHead != "" {
		t.Fatalf("torn publish still rolled state head: %+v", e)
	}
	fs.beforeWrite = nil
	if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
		t.Fatalf("torn publish should refuse state_mismatch, rc=%d", rc)
	}

	// And a clean update after the interrupted ones still converges.
	// Repair the torn publish fully (ELF AND row back to v1) so the
	// converging update records a truthful prev_row.
	fs.files["/host/GOHELLO.ELF"] = elfV1
	fs.files[appsPath] = appsV1
	if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("post-interrupt update rc=%d", rc)
	}
	if string(fs.files["/host/GOHELLO.ELF"]) != string(testELFv2) {
		t.Fatal("post-interrupt update did not land v2")
	}
	if got := fs.files[prevPath("GOHELLO.ELF")]; string(got) != string(elfV1) {
		t.Fatal(".prev did not rotate to the old ELF")
	}
	if fs.Exists(prevStagePath("GOHELLO.ELF")) {
		t.Fatal("staged .prev.new survived a completed publish")
	}
}

// TestUpdatePrevSurvivesKilledPublish is the #2372 acceptance: a publish
// killed after the STORE.TXT commit — before the .prev rotation — must
// not destroy the rollback target. The state file names sha(v2) while
// .prev still holds v1; the staged .prev.new carries the bytes PrevSHA
// points at, and rollback works.
func TestUpdatePrevSurvivesKilledPublish(t *testing.T) {
	fs, _, _, restore := seedConsumer(t)
	defer restore()
	if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("install rc=%d", rc)
	}
	seedConsumerV2(t, fs)
	if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("update v2 rc=%d", rc)
	}

	// A second update killed at the live-ELF write (the state commit
	// never happens): the recorded rollback target stays whole.
	srcV3 := releaseGo("GOHELLO", "3.0.0", testELFv3, rowV3)
	streamAdvanceRelease(t, fs, srcV3, testChangeV2, testChangeV3)
	fs.files["/host/DROP/rel/release.go"] = srcV3
	fs.files["/host/DROP/rel/GOHELLO.ELF"] = testELFv3
	fs.beforeWrite = func(op, p string) error {
		if p == "/host/GOHELLO.ELF" {
			return newFSErr("write", p, -5)
		}
		return nil
	}
	if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	fs.beforeWrite = nil
	if string(fs.files[prevPath("GOHELLO.ELF")]) != string(testELF) {
		t.Fatal("pre-commit kill touched .prev")
	}
	if rc := Rollback(fs, "gohello"); rc != 0 {
		t.Fatalf("rollback after pre-commit kill rc=%d", rc)
	}
	if string(fs.files["/host/GOHELLO.ELF"]) != string(testELF) {
		t.Fatal("rollback did not restore v1")
	}

	// Now the dangerous kill — the replica's head is still v3, so the
	// next update runs v1 -> v3: the STORE.TXT commit lands, then every
	// later write (the .prev rotation) dies.
	fs.beforeWrite = func(op, p string) error {
		if p == prevPath("GOHELLO.ELF") {
			return newFSErr("write", p, -5)
		}
		return nil
	}
	if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	fs.beforeWrite = nil

	// The commit landed — live is v3 and state names sha(v1) as the
	// rollback target — but .prev still holds the v2 bytes the phase-1
	// rollback rotated in.
	e := stateEntry(t, fs, "GOHELLO.ELF")
	if e.Head != testChangeV3 || e.PrevSHA != shaHex(testELF) {
		t.Fatalf("post-commit state %+v", e)
	}
	if string(fs.files[prevPath("GOHELLO.ELF")]) != string(testELFv2) {
		t.Fatal(".prev rotated despite the refused write")
	}

	// Rollback still works: .prev.new carries the bytes PrevSHA names.
	if rc := Rollback(fs, "gohello"); rc != 0 {
		t.Fatalf("rollback after post-commit kill rc=%d", rc)
	}
	if string(fs.files["/host/GOHELLO.ELF"]) != string(testELF) {
		t.Fatal("rollback did not restore v1 from the staged target")
	}
}

// TestUpdateRefusals: every named refusal leaves installed state
// byte-identical.
func TestUpdateRefusals(t *testing.T) {
	mk := func(t *testing.T, mutate func(fs *memFS)) (*memFS, *[]string, func()) {
		fs, _, lines, restore := seedConsumer(t)
		if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
			t.Fatalf("install rc=%d", rc)
		}
		mutate(fs)
		return fs, lines, restore
	}
	snapshot := func(fs *memFS) (elf, apps, state string) {
		return string(fs.files["/host/GOHELLO.ELF"]),
			string(fs.files[appsPath]), string(fs.files[statePath])
	}
	unchanged := func(t *testing.T, fs *memFS, elf, apps, state string) {
		t.Helper()
		e, a, s := snapshot(fs)
		if e != elf || a != apps || s != state {
			t.Fatal("refusal mutated installed state")
		}
	}

	t.Run("not_installed", func(t *testing.T) {
		fs, _, lines, restore := seedConsumer(t)
		defer restore()
		if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
			t.Fatalf("rc=%d", rc)
		}
		if !strings.Contains(strings.Join(*lines, "\n"), "store: refuse not_installed") {
			t.Fatalf("%v", *lines)
		}
	})

	t.Run("name_mismatch on a renamed release", func(t *testing.T) {
		fs, lines, restore := mk(t, func(fs *memFS) {
			src := releaseGo("GOTWO", "2.0.0", testELFv2, "GOTWO.ELF | Two | t | dock=false")
			streamAdvanceRelease(t, fs, src, testChangeV1, testChangeV2)
			fs.files["/host/DROP/rel/release.go"] = src
		})
		defer restore()
		elf, apps, state := snapshot(fs)
		if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
			t.Fatalf("rc=%d", rc)
		}
		if !strings.Contains(strings.Join(*lines, "\n"), "store: refuse name_mismatch") {
			t.Fatalf("%v", *lines)
		}
		unchanged(t, fs, elf, apps, state)
	})

	t.Run("state_mismatch on tampered live ELF", func(t *testing.T) {
		fs, lines, restore := mk(t, func(fs *memFS) {
			fs.files["/host/GOHELLO.ELF"] = []byte("replaced behind store's back")
		})
		defer restore()
		if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
			t.Fatalf("rc=%d", rc)
		}
		if !strings.Contains(strings.Join(*lines, "\n"), "store: refuse state_mismatch") {
			t.Fatalf("%v", *lines)
		}
	})

	t.Run("state_malformed refuses whole", func(t *testing.T) {
		fs, lines, restore := mk(t, func(fs *memFS) {
			fs.files[statePath] = []byte("not a state line\n")
		})
		defer restore()
		if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
			t.Fatalf("update rc=%d", rc)
		}
		if rc := Rollback(fs, "gohello"); rc != 1 {
			t.Fatalf("rollback rc=%d", rc)
		}
		joined := strings.Join(*lines, "\n")
		if strings.Count(joined, "store: refuse state_malformed") != 2 {
			t.Fatalf("%v", *lines)
		}
	})

	t.Run("elf_mismatch on tampered v2 drop", func(t *testing.T) {
		fs, lines, restore := mk(t, func(fs *memFS) {
			seedConsumerV2(t, fs)
			fs.files["/host/DROP/rel/GOHELLO.ELF"] = append(testELFv2, 0)
		})
		defer restore()
		elf, apps, state := snapshot(fs)
		if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
			t.Fatalf("rc=%d", rc)
		}
		if !strings.Contains(strings.Join(*lines, "\n"), "store: refuse elf_mismatch") {
			t.Fatalf("%v", *lines)
		}
		unchanged(t, fs, elf, apps, state)
	})
}

// TestRollbackRefusals: the three retained-bytes failure modes plus
// rollback-with-no-prev.
func TestRollbackRefusals(t *testing.T) {
	t.Run("no_rollback", func(t *testing.T) {
		fs, _, lines, restore := seedConsumer(t)
		defer restore()
		if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
			t.Fatalf("install rc=%d", rc)
		}
		if rc := Rollback(fs, "gohello"); rc != 1 {
			t.Fatalf("rc=%d", rc)
		}
		if !strings.Contains(strings.Join(*lines, "\n"), "store: refuse no_rollback") {
			t.Fatalf("%v", *lines)
		}
	})

	t.Run("prev_missing", func(t *testing.T) {
		fs, _, lines, restore := seedConsumer(t)
		defer restore()
		if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
			t.Fatalf("install rc=%d", rc)
		}
		seedConsumerV2(t, fs)
		if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
			t.Fatalf("update rc=%d", rc)
		}
		if err := fs.Remove(prevPath("GOHELLO.ELF")); err != nil {
			t.Fatal(err)
		}
		if rc := Rollback(fs, "gohello"); rc != 1 {
			t.Fatalf("rc=%d", rc)
		}
		if !strings.Contains(strings.Join(*lines, "\n"), "store: refuse prev_missing") {
			t.Fatalf("%v", *lines)
		}
		// The v2 install stays live.
		if string(fs.files["/host/GOHELLO.ELF"]) != string(testELFv2) {
			t.Fatal("prev_missing rollback disturbed the live ELF")
		}
	})

	t.Run("prev_mismatch", func(t *testing.T) {
		fs, _, lines, restore := seedConsumer(t)
		defer restore()
		if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
			t.Fatalf("install rc=%d", rc)
		}
		seedConsumerV2(t, fs)
		if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
			t.Fatalf("update rc=%d", rc)
		}
		fs.files[prevPath("GOHELLO.ELF")] = []byte("tampered retained bytes")
		if rc := Rollback(fs, "gohello"); rc != 1 {
			t.Fatalf("rc=%d", rc)
		}
		if !strings.Contains(strings.Join(*lines, "\n"), "store: refuse prev_mismatch") {
			t.Fatalf("%v", *lines)
		}
		if string(fs.files["/host/GOHELLO.ELF"]) != string(testELFv2) {
			t.Fatal("prev_mismatch rollback published tampered bytes")
		}
	})

	t.Run("not_installed", func(t *testing.T) {
		fs, _, lines, restore := seedConsumer(t)
		defer restore()
		if rc := Rollback(fs, "gohello"); rc != 1 {
			t.Fatalf("rc=%d", rc)
		}
		if !strings.Contains(strings.Join(*lines, "\n"), "store: refuse not_installed") {
			t.Fatalf("%v", *lines)
		}
	})
}

// ---- #2379 minor items -------------------------------------------------

// TestInstallAdoptsOrphanELF: a crash between the ELF publish and the
// APPS.TXT write leaves a byte-exact orphan — install adopts it (the
// signed hash proves the bytes) instead of refusing elf_exists forever;
// a foreign file at the name still refuses.
func TestInstallAdoptsOrphanELF(t *testing.T) {
	fs, _, lines, restore := seedConsumer(t)
	defer restore()
	fs.files["/host/GOHELLO.ELF"] = testELF // orphan with the signed bytes
	if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("adopt orphan rc=%d lines=%v", rc, *lines)
	}
	if got := fs.files["/host/GOHELLO.ELF"]; string(got) != string(testELF) {
		t.Fatal("orphan bytes replaced")
	}
	if !manifestHasBin(strings.Split(string(fs.files[appsPath]), "\n"), "GOHELLO.ELF") {
		t.Fatal("row missing after adoption")
	}
	e := stateEntry(t, fs, "GOHELLO.ELF")
	if e.Head != testChangeV1 || e.SHA256 != shaHex(testELF) {
		t.Fatalf("state %+v", e)
	}

	// A file whose bytes are NOT the signed ELF still blocks the name.
	fs, _, lines, restore = seedConsumer(t)
	defer restore()
	fs.files["/host/GOHELLO.ELF"] = []byte("foreign bytes")
	if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 1 ||
		!strings.Contains(strings.Join(*lines, "\n"), "store: refuse elf_exists") {
		t.Fatalf("foreign ELF: rc=%d %v", rc, *lines)
	}
}

// TestRemoveCleansOrphan: remove deletes an untracked ELF (and retained
// .prev/.prev.new residue) instead of refusing not_installed — the torn
// install's name is unblocked without manual deletion.
func TestRemoveCleansOrphan(t *testing.T) {
	fs, _, _, restore := seedConsumer(t)
	defer restore()
	// seedConsumer's manifest names only GOCALC; plant orphan artifacts.
	fs.files["/host/GOHELLO.ELF"] = testELF
	fs.files[prevPath("GOHELLO.ELF")] = testELFv2
	fs.files[prevStagePath("GOHELLO.ELF")] = testELFv3
	if rc := Remove(fs, "gohello"); rc != 0 {
		t.Fatalf("remove orphan rc=%d", rc)
	}
	if fs.Exists("/host/GOHELLO.ELF") || fs.Exists(prevPath("GOHELLO.ELF")) ||
		fs.Exists(prevStagePath("GOHELLO.ELF")) {
		t.Fatal("orphan artifacts survived remove")
	}
	// A name with no row and no files at all still refuses.
	if rc := Remove(fs, "goping"); rc != 1 {
		t.Fatalf("remove of absent app rc=%d", rc)
	}
}

// TestAlreadyInstalledWritesState: the idempotent re-install path
// converges to a tracked install — a crash between the APPS.TXT write
// and the state write left the app live but untracked, so the path now
// reconciles the row and writes the STORE.TXT entry.
func TestAlreadyInstalledWritesState(t *testing.T) {
	fs, _, lines, restore := seedConsumer(t)
	defer restore()
	// Live app + a stale row, no state entry: the torn-install shape.
	fs.files["/host/GOHELLO.ELF"] = testELF
	fs.files[appsPath] = []byte("GOHELLO.ELF | Stale Label | x | dock=true\n")
	if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("rc=%d lines=%v", rc, *lines)
	}
	if !strings.Contains(strings.Join(*lines, "\n"), "store: already installed GOHELLO.ELF") {
		t.Fatalf("missing already-installed line: %v", *lines)
	}
	man := string(fs.files[appsPath])
	if !strings.Contains(man, "GOHELLO.ELF | Go Hello | g | dock=false\n") ||
		strings.Contains(man, "Stale Label") {
		t.Fatalf("row not reconciled to the signed one: %q", man)
	}
	e := stateEntry(t, fs, "GOHELLO.ELF")
	if e.Head != testChangeV1 || e.SHA256 != shaHex(testELF) || e.Stream != "rel" {
		t.Fatalf("state %+v", e)
	}
}

// TestFoldToRecordHead: a pull torn between its log append and its
// record roll leaves the log ahead of the record — the fold stops at
// the head STORE records so the un-committed tail never materializes.
func TestFoldToRecordHead(t *testing.T) {
	fs := newMemFS()
	srcV1 := releaseGo("GOHELLO", "1.0.0", testELF, rowV1)
	streamWithRelease(t, fs, "rel", srcV1)
	srcV2 := releaseGo("GOHELLO", "2.0.0", testELFv2, rowV2)
	streamAdvanceRelease(t, fs, srcV2, testChangeV1, testChangeV2)

	// Rewind the record to v1: log is [c1,c2], head stays c1.
	var rec Stream
	if err := json.Unmarshal(fs.files[streamRecordPath(DefaultStoreRoot, testStreamID)], &rec); err != nil {
		t.Fatal(err)
	}
	head := testChangeV1
	rec.Head = &head
	rb, _ := json.Marshal(rec)
	fs.files[streamRecordPath(DefaultStoreRoot, testStreamID)] = append(rb, '\n')

	logBytes, err := streamLogBytes(fs, DefaultStoreRoot, testStreamID)
	if err != nil {
		t.Fatal(err)
	}
	signed, author, err := headReleaseOps(logBytes, rec.Head)
	if err != nil {
		t.Fatal(err)
	}
	if author != strings.Repeat("ab", 32) {
		t.Fatalf("head author %q, want the seeded publisher key", author)
	}
	if err := verifyRelease(srcV1, signed); err != nil {
		t.Fatalf("v1 should verify at head: %v", err)
	}
	if err := verifyRelease(srcV2, signed); err == nil {
		t.Fatal("fold reached past the record head")
	}

	// A head absent from the log is stream_malformed; a nil head folds
	// nothing (nothing is committed).
	bogus := "0199de2d-dc00-7000-8000-00000000dead"
	if _, _, err := headReleaseOps(logBytes, &bogus); err == nil {
		t.Fatal("head absent from log accepted")
	} else {
		re := err.(*RefuseError)
		if re.Code != "stream_malformed" {
			t.Fatalf("refusal %v", err)
		}
	}
	if signed, _, err := headReleaseOps(logBytes, nil); err != nil || len(signed) != 0 {
		t.Fatalf("nil head folded %d atoms, %v", len(signed), err)
	}
}

// TestManifestBlankLines: interior blank lines round-trip through a
// rewrite instead of being eaten by every APPS.TXT write.
func TestManifestBlankLines(t *testing.T) {
	fs := newMemFS()
	fs.files[appsPath] = []byte("# header\n\nGOCALC.ELF | Calc | c | dock=true\n\nGOSH.ELF | Shell | s\n")
	lines, err := loadManifest(fs)
	if err != nil {
		t.Fatal(err)
	}
	kept, found := manifestWithoutBin(lines, "GOSH.ELF")
	if !found {
		t.Fatal("remove missed")
	}
	if got := string(renderManifest(kept)); got != "# header\n\nGOCALC.ELF | Calc | c | dock=true\n\n" {
		t.Fatalf("blank lines dropped: %q", got)
	}
	// Appending a row lands after the last row, blank lines intact.
	out, err := manifestWithRow(lines, "GOPING.ELF | Ping | p | dock=false")
	if err != nil {
		t.Fatal(err)
	}
	want := "# header\n\nGOCALC.ELF | Calc | c | dock=true\n\nGOSH.ELF | Shell | s\nGOPING.ELF | Ping | p | dock=false\n"
	if string(out) != want {
		t.Fatalf("append wrong:\n got: %q\nwant: %q", out, want)
	}
}

// TestRemoveCleansState: remove drops the STORE.TXT row and the
// retained .prev alongside the ELF and manifest row.
func TestRemoveCleansState(t *testing.T) {
	fs, _, _, restore := seedConsumer(t)
	defer restore()
	if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("install rc=%d", rc)
	}
	seedConsumerV2(t, fs)
	if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("update rc=%d", rc)
	}
	if rc := Remove(fs, "gohello"); rc != 0 {
		t.Fatalf("remove rc=%d", rc)
	}
	if fs.Exists("/host/GOHELLO.ELF") || fs.Exists(prevPath("GOHELLO.ELF")) {
		t.Fatal("remove left ELF artifacts")
	}
	state, err := loadState(fs)
	if err != nil || len(state) != 0 {
		t.Fatalf("remove left state: %v %v", state, err)
	}
}
