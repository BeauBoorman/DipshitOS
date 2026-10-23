package store

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"virelai/flint/parser"
	"virelai/sshlib"
)

// ---- publisher fixture -----------------------------------------------------

const (
	pubSrcDir   = "/host/SRC"
	pubElfDir   = "/host/BUILD"
	pubElfPath  = pubElfDir + "/GOHELLO.ELF"
	pubRelPath  = pubSrcDir + "/release/release.go"
	pubChangeID = "0199de2d-dc00-7000-8000-00000000c0ff"
)

// seedPublisher lays the producer-side fixture: a FLINT workspace src
// dir, a built ELF, and the `rel` stream record — headless so a first
// publish must commit.
func seedPublisher(t *testing.T, fs *memFS) {
	t.Helper()
	fs.dirs[pubSrcDir] = true
	fs.dirs[pubElfDir] = true
	fs.files[pubElfPath] = testELF
	rec := Stream{ID: testStreamID, Name: "rel", Created: 1}
	rb, _ := json.Marshal(rec)
	fs.files[streamRecordPath(DefaultStoreRoot, testStreamID)] = append(rb, '\n')
	fs.dirs[DefaultStoreRoot] = true
	fs.dirs[DefaultStoreRoot+"/streams"] = true
}

func pubArgs() PublishArgs {
	return PublishArgs{
		Name:    "GOHELLO",
		ElfPath: pubElfPath,
		Src:     pubSrcDir,
		Version: "1.0.0",
		Stream:  "rel",
	}
}

// seedExec stubs the exec+sleep seams the same way seedConsumer does.
func seedExec() (*fakeExec, *[]string, func()) {
	fs := newMemFS()
	fx := &fakeExec{fs: fs}
	prevExec := execFn
	execFn = fx.run
	prevSleep := sleepFn
	sleepFn = func(uint64) {}
	lines, restore := collectConsole()
	return fx, lines, func() {
		execFn = prevExec
		sleepFn = prevSleep
		restore()
	}
}

// mintSignedReleaseChange is the fake commit's payload: parse the
// workspace's release/release.go into atoms exactly as `flint add` would
// stage them, sign the Change with fixture_gen_test.go's pinned seed,
// append it to the stream log, and roll the record head — the byte
// effects a real FLINT.ELF commit has on the flat-file store.
func mintSignedReleaseChange(t *testing.T, fs *memFS, relPath, changeID string) {
	t.Helper()
	src, err := fs.ReadFile(relPath, MaxReleaseBytes)
	if err != nil {
		t.Fatalf("commit stub: read %s: %v", relPath, err)
	}
	seedB, err := os.ReadFile(genSeedFile)
	if err != nil {
		t.Fatalf("commit stub: read seed: %v", err)
	}
	raw, err := hex.DecodeString(strings.TrimSpace(string(seedB)))
	if err != nil || len(raw) != 32 {
		t.Fatalf("commit stub: seed hex")
	}
	var seed [32]byte
	copy(seed[:], raw)
	defer sshlib.Wipe(seed[:])

	p, ok := parser.ForPath("release/release.go")
	if !ok {
		t.Fatal("commit stub: no parser for release.go")
	}
	atoms, err := p.Parse("release/release.go", src)
	if err != nil {
		t.Fatalf("commit stub: parse %s: %v", relPath, err)
	}
	pub := sshlib.EdDerivePublic(seed)
	change := Change{
		ID:     changeID,
		Stream: testStreamID,
		TS:     1760000000000,
		Author: sshlib.EncodeHex(pub[:]),
		Ops:    []Op{},
	}
	for _, a := range atoms {
		span := Span{File: a.File, Start: a.Start, End: a.End}
		change.Ops = append(change.Ops, Op{
			Type:       "add",
			AtomID:     genAtomID(a.Name),
			Kind:       a.Kind,
			NewName:    a.Name,
			NewSpan:    &span,
			NewHash:    hex.EncodeToString(a.Hash[:]),
			NewSigHash: hex.EncodeToString(a.SigHash[:]),
		})
	}
	msg, err := genSigMsg(&change)
	if err != nil {
		t.Fatalf("commit stub: sigMsg: %v", err)
	}
	sig := sshlib.EdSign(msg, seed)
	change.Sig = sshlib.EncodeHex(sig[:])

	line, err := json.Marshal(change)
	if err != nil {
		t.Fatal(err)
	}
	logPath := streamLogPath(DefaultStoreRoot, testStreamID)
	fs.files[logPath] = append(fs.files[logPath], append(line, '\n')...)
	var rec Stream
	if err := json.Unmarshal(fs.files[streamRecordPath(DefaultStoreRoot, testStreamID)], &rec); err != nil {
		t.Fatalf("commit stub: stream record: %v", err)
	}
	rec.Head = &change.ID
	rb, _ := json.Marshal(rec)
	fs.files[streamRecordPath(DefaultStoreRoot, testStreamID)] = append(rb, '\n')
}

// ---- publish ---------------------------------------------------------------

func TestPublishHappy(t *testing.T) {
	fx, lines, restore := seedExec()
	defer restore()
	fs := fx.fs
	seedPublisher(t, fs)
	// The fake commit lands a real signed head — the pinned member's
	// directory name comes off the post-commit record head.
	prevExec := execFn
	execFn = func(name string, args ...string) (int64, error) {
		rc, err := fx.run(name, args...)
		if strings.Contains(strings.Join(args, " "), "commit") {
			mintSignedReleaseChange(t, fs, pubRelPath, pubChangeID)
		}
		return rc, err
	}
	defer func() { execFn = prevExec }()

	rc := Publish(fs, DefaultStoreRoot, pubArgs())
	if rc != 0 {
		t.Fatalf("rc=%d lines=%v", rc, *lines)
	}
	joined := strings.Join(*lines, "\n")
	sum := sshlib.SHA256Sum(testELF)
	want := "store: published GOHELLO 1.0.0 sha256=" +
		sshlib.EncodeHex(sum[:]) + " drop=/host/DROP/rel"
	if !strings.Contains(joined, want) {
		t.Fatalf("missing published line %q: %v", want, *lines)
	}
	// The FLINT exec seam: add the workspace, then commit with the
	// release message — in that order.
	log := strings.Join(fx.log, "|")
	addIdx := strings.Index(log, "FLINT.ELF add "+pubSrcDir)
	commitIdx := strings.Index(log, "FLINT.ELF commit -m release GOHELLO 1.0.0")
	if addIdx < 0 || commitIdx < 0 || commitIdx < addIdx {
		t.Fatalf("add/commit shape wrong: %v", fx.log)
	}
	// The committed manifest is byte-identical to the dropped one and
	// passes the same parseRelease install runs.
	committed, ok := fs.files[pubRelPath]
	if !ok {
		t.Fatal("workspace release/release.go missing")
	}
	dropped := fs.files["/host/DROP/rel/release.go"]
	if !bytes.Equal(committed, dropped) {
		t.Fatal("drop release.go differs from committed file")
	}
	rel, err := parseRelease(dropped)
	if err != nil {
		t.Fatalf("parseRelease dropped: %v", err)
	}
	if rel.Name != "GOHELLO" || rel.Version != "1.0.0" ||
		rel.ELFSHA256 != sshlib.EncodeHex(sum[:]) ||
		rel.ManifestRow != "GOHELLO.ELF | GOHELLO | g | dock=false" {
		t.Fatalf("manifest fields: %+v", rel)
	}
	wAtoms, _ := releaseAtomSet(committed)
	dAtoms, _ := releaseAtomSet(dropped)
	if len(wAtoms) != len(dAtoms) {
		t.Fatalf("atom sets differ: %d vs %d", len(wAtoms), len(dAtoms))
	}
	if !bytes.Equal(fs.files["/host/DROP/rel/GOHELLO.ELF"], testELF) {
		t.Fatal("ELF not dropped")
	}
	for _, d := range []string{"/host/DROP", "/host/DROP/rel", pubSrcDir + "/release"} {
		if !fs.dirs[d] {
			t.Fatalf("dir %s not created", d)
		}
	}
}

func TestPublishUnchanged(t *testing.T) {
	fx, lines, restore := seedExec()
	defer restore()
	fs := fx.fs
	seedPublisher(t, fs)
	// A stream head that already signs exactly the atoms publish would
	// render: the commit is skipped and the drop still lands.
	src := releaseGo("GOHELLO", "1.0.0", testELF, "GOHELLO.ELF | GOHELLO | g | dock=false")
	streamWithRelease(t, fs, "rel", src)

	rc := Publish(fs, DefaultStoreRoot, pubArgs())
	if rc != 0 {
		t.Fatalf("rc=%d lines=%v", rc, *lines)
	}
	if !strings.Contains(strings.Join(*lines, "\n"), " unchanged") {
		t.Fatalf("missing unchanged marker: %v", *lines)
	}
	if log := strings.Join(fx.log, "|"); strings.Contains(log, "add") || strings.Contains(log, "commit") {
		t.Fatalf("unchanged still execed: %v", fx.log)
	}
	if !bytes.Equal(fs.files["/host/DROP/rel/release.go"], src) {
		t.Fatal("unchanged publish did not refresh the drop")
	}
	if !bytes.Equal(fs.files["/host/DROP/rel/GOHELLO.ELF"], testELF) {
		t.Fatal("unchanged publish did not drop the ELF")
	}
}

func TestPublishRefusals(t *testing.T) {
	mk := func(t *testing.T, mut func(fs *memFS, fx *fakeExec, a *PublishArgs)) (*memFS, *[]string, func(), int) {
		fx, lines, restore := seedExec()
		seedPublisher(t, fx.fs)
		a := pubArgs()
		mut(fx.fs, fx, &a)
		rc := Publish(fx.fs, DefaultStoreRoot, a)
		return fx.fs, lines, restore, rc
	}
	noWrites := func(t *testing.T, fs *memFS) {
		t.Helper()
		if fs.Exists(pubRelPath) {
			t.Fatal("refusal left release/release.go behind")
		}
		for p := range fs.files {
			if strings.HasPrefix(p, "/host/DROP/") {
				t.Fatalf("refusal wrote drop file %s", p)
			}
		}
	}
	want := func(t *testing.T, lines *[]string, code string, rc int) {
		t.Helper()
		if rc != 1 || !strings.Contains(strings.Join(*lines, "\n"), "store: refuse "+code) {
			t.Fatalf("rc=%d lines=%v, want refuse %s", rc, *lines, code)
		}
	}

	t.Run("name_invalid", func(t *testing.T) {
		fs, lines, restore, rc := mk(t, func(_ *memFS, _ *fakeExec, a *PublishArgs) {
			a.Name = "bad name"
		})
		defer restore()
		want(t, lines, "name_invalid", rc)
		noWrites(t, fs)
	})
	t.Run("release_malformed version", func(t *testing.T) {
		fs, lines, restore, rc := mk(t, func(_ *memFS, _ *fakeExec, a *PublishArgs) {
			a.Version = "1 0"
		})
		defer restore()
		want(t, lines, "release_malformed", rc)
		noWrites(t, fs)
	})
	t.Run("row_mismatch", func(t *testing.T) {
		fs, lines, restore, rc := mk(t, func(_ *memFS, _ *fakeExec, a *PublishArgs) {
			a.Row = "OTHER.ELF | Other | g"
		})
		defer restore()
		want(t, lines, "row_mismatch", rc)
		noWrites(t, fs)
	})
	t.Run("summary_invalid", func(t *testing.T) {
		fs, lines, restore, rc := mk(t, func(_ *memFS, _ *fakeExec, a *PublishArgs) {
			a.Summary = "two\nlines"
		})
		defer restore()
		want(t, lines, "summary_invalid", rc)
		noWrites(t, fs)
	})
	t.Run("category_unknown", func(t *testing.T) {
		fs, lines, restore, rc := mk(t, func(_ *memFS, _ *fakeExec, a *PublishArgs) {
			a.Category = "zzz"
		})
		defer restore()
		want(t, lines, "category_unknown", rc)
		noWrites(t, fs)
	})
	t.Run("publish_elf_missing", func(t *testing.T) {
		fs, lines, restore, rc := mk(t, func(_ *memFS, _ *fakeExec, a *PublishArgs) {
			a.ElfPath = "/host/NOPE.ELF"
		})
		defer restore()
		want(t, lines, "publish_elf_missing", rc)
		noWrites(t, fs)
	})
	t.Run("channel_malformed", func(t *testing.T) {
		fs, lines, restore, rc := mk(t, func(_ *memFS, _ *fakeExec, a *PublishArgs) {
			a.Channel = "http://10.0.0.2:9/d"
		})
		defer restore()
		want(t, lines, "channel_malformed", rc)
		noWrites(t, fs)
	})
	t.Run("stream_missing", func(t *testing.T) {
		fs, lines, restore, rc := mk(t, func(_ *memFS, _ *fakeExec, a *PublishArgs) {
			a.Stream = "nope"
		})
		defer restore()
		want(t, lines, "stream_missing", rc)
		noWrites(t, fs)
	})
	t.Run("src_missing", func(t *testing.T) {
		fs, lines, restore, rc := mk(t, func(_ *memFS, _ *fakeExec, a *PublishArgs) {
			a.Src = "/host/NOSRC"
		})
		defer restore()
		want(t, lines, "src_missing", rc)
		noWrites(t, fs)
	})
	t.Run("sync_failed on add", func(t *testing.T) {
		fs, lines, restore, rc := mk(t, func(_ *memFS, fx *fakeExec, _ *PublishArgs) {
			fx.steps = []execStep{{match: "add", status: 1}}
		})
		defer restore()
		want(t, lines, "sync_failed", rc)
		noWrites(t, fs)
	})
}

func TestPublishCommitFailureRestores(t *testing.T) {
	// Prior manifest bytes come back; a fresh release/release.go is
	// removed. Either way no drop file lands.
	t.Run("restores previous bytes", func(t *testing.T) {
		fx, lines, restore := seedExec()
		defer restore()
		fs := fx.fs
		seedPublisher(t, fs)
		fs.dirs[pubSrcDir+"/release"] = true
		fs.files[pubRelPath] = []byte("old manifest")
		fx.steps = []execStep{{match: "commit", status: 1}}

		rc := Publish(fs, DefaultStoreRoot, pubArgs())
		if rc != 1 || !strings.Contains(strings.Join(*lines, "\n"), "store: refuse sync_failed") {
			t.Fatalf("rc=%d lines=%v", rc, *lines)
		}
		if string(fs.files[pubRelPath]) != "old manifest" {
			t.Fatalf("prior manifest not restored: %q", fs.files[pubRelPath])
		}
		for p := range fs.files {
			if strings.HasPrefix(p, "/host/DROP/") {
				t.Fatalf("failed commit wrote drop file %s", p)
			}
		}
	})
	t.Run("removes the new file", func(t *testing.T) {
		fx, lines, restore := seedExec()
		defer restore()
		fs := fx.fs
		seedPublisher(t, fs)
		fx.steps = []execStep{{match: "commit", status: 1}}

		rc := Publish(fs, DefaultStoreRoot, pubArgs())
		if rc != 1 || !strings.Contains(strings.Join(*lines, "\n"), "store: refuse sync_failed") {
			t.Fatalf("rc=%d lines=%v", rc, *lines)
		}
		if fs.Exists(pubRelPath) {
			t.Fatal("failed commit left release/release.go behind")
		}
	})
}

// TestPublishOutputInstalls is the end-to-end pin: the stub commit signs
// the workspace manifest with fixture_gen_test.go's pinned seed (the
// same key the gate's consumer keyring trusts), then a real Install
// folds the signed head, verifies the dropped manifest atom-for-atom,
// and lands the ELF — publish's output is exactly what install accepts.
func TestPublishOutputInstalls(t *testing.T) {
	fx, lines, restore := seedExec()
	defer restore()
	fs := fx.fs
	seedPublisher(t, fs)
	prevExec := execFn
	execFn = func(name string, args ...string) (int64, error) {
		cmd := name + " " + strings.Join(args, " ")
		fx.log = append(fx.log, cmd)
		if strings.Contains(cmd, "commit") {
			mintSignedReleaseChange(t, fs, pubRelPath, pubChangeID)
		}
		return 0, nil
	}
	defer func() { execFn = prevExec }()

	if rc := Publish(fs, DefaultStoreRoot, pubArgs()); rc != 0 {
		t.Fatalf("publish rc=%d lines=%v", rc, *lines)
	}
	rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP")
	if rc != 0 {
		t.Fatalf("install rc=%d lines=%v", rc, *lines)
	}
	if !strings.Contains(strings.Join(*lines, "\n"), "store: install ok GOHELLO.ELF version=1.0.0") {
		t.Fatalf("install did not land: %v", *lines)
	}
	if !bytes.Equal(fs.files["/host/GOHELLO.ELF"], testELF) {
		t.Fatal("installed ELF bytes differ")
	}
	if !manifestHasBin(strings.Split(string(fs.files[appsPath]), "\n"), "GOHELLO.ELF") {
		t.Fatalf("manifest row missing: %q", fs.files[appsPath])
	}
}
