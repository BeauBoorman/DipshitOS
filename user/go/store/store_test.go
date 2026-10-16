package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"virelai/flint/parser"
	"virelai/sshlib"
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
	ops := map[string]string{}
	p, _ := parser.ForPath("release.go")
	atoms, err := p.Parse("release.go", src)
	if err != nil {
		t.Fatalf("parse release.go: %v", err)
	}
	change := Change{
		ID:     "0199de2d-dc00-7000-8000-00000000c001",
		Stream: testStreamID,
		TS:     1760000000000,
		Author: strings.Repeat("ab", 32),
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
		ops[a.Name] = "set"
	}
	_ = ops
	rec := Stream{ID: testStreamID, Name: name, Head: &change.ID, Created: 1}
	rb, _ := json.Marshal(rec)
	fs.files[streamRecordPath(DefaultStoreRoot, testStreamID)] = append(rb, '\n')
	lb, _ := json.Marshal(change)
	fs.files[streamLogPath(DefaultStoreRoot, testStreamID)] = append(lb, '\n')
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

func collectConsole() (*[]string, func()) {
	var lines []string
	prev := consoleFn
	consoleFn = func(s string) { lines = append(lines, s) }
	return &lines, func() { consoleFn = prev }
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

	rc := cmdInstall(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
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
	if !strings.Contains(strings.Join(fx.log, "|"), "verify --all") {
		t.Fatalf("no local verify: %v", fx.log)
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

	rc := cmdInstall(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
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
		if rc := cmdInstall(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 1 {
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
		rc := cmdInstall(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
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
		rc := cmdInstall(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
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
		rc := cmdInstall(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
		if rc != 1 || !strings.Contains(strings.Join(*lines, "\n"), "store: refuse already_installed") {
			t.Fatalf("rc=%d %v", rc, *lines)
		}
	})

	t.Run("channel_missing release.go", func(t *testing.T) {
		fs, lines, restore := mk(t, func(fs *memFS, fx *fakeExec) {
			delete(fs.files, "/host/DROP/rel/release.go")
		})
		defer restore()
		rc := cmdInstall(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
		if rc != 1 || !strings.Contains(strings.Join(*lines, "\n"), "store: refuse channel_missing") {
			t.Fatalf("rc=%d %v", rc, *lines)
		}
	})

	t.Run("remote_missing", func(t *testing.T) {
		fs, lines, restore := mk(t, func(fs *memFS, fx *fakeExec) {})
		defer restore()
		rc := cmdInstall(fs, DefaultStoreRoot, "rel", "", "/host/DROP")
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
		rc := cmdInstall(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
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

	if rc := cmdRemove(fs, "gohello"); rc != 0 {
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

	if rc := cmdRemove(fs, "GOHELLO"); rc != 1 {
		t.Fatal("remove of absent should refuse")
	}
	if rc := cmdRemove(fs, "..bad"); rc != 1 {
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

	rc := cmdLs(fs, DefaultStoreRoot, "10.0.0.2:4749")
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
