package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type testHarness struct {
	fs   *memFS
	uuid *UUIDGen
	root string
	now  int64
	logs []string
}

func newTestHarness(t *testing.T) *testHarness {
	t.Helper()
	h := &testHarness{
		fs:   newMemFS(),
		root: DefaultStoreRoot,
		now:  1760000000,
	}
	var seed byte = 1
	h.uuid = newUUIDGen(
		func() int64 { return h.now },
		func(b []byte) error {
			for i := range b {
				b[i] = seed
				seed = seed*31 + 17
			}
			return nil
		},
	)
	return h
}

func (h *testHarness) runCmd(args ...string) (int, []string) {
	prevFS := activeFS
	prevRoot := storeRoot
	prevUUID := defaultUUIDGen
	prevLog := consoleFn
	defer func() {
		activeFS = prevFS
		storeRoot = prevRoot
		defaultUUIDGen = prevUUID
		consoleFn = prevLog
	}()

	h.logs = nil
	activeFS = h.fs
	storeRoot = h.root
	defaultUUIDGen = h.uuid
	consoleFn = func(s string) {
		h.logs = append(h.logs, s)
	}
	rc := run(args)
	return rc, append([]string(nil), h.logs...)
}

func readCorpusFile(t *testing.T, rel string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "corpus", filepath.FromSlash(rel)))
	if err != nil {
		t.Fatalf("read corpus %s: %v", rel, err)
	}
	return b
}

func TestInitLayoutAndRefusals(t *testing.T) {
	h := newTestHarness(t)
	if err := h.fs.Mkdir("/host/src"); err != nil {
		t.Fatal(err)
	}

	rc, logs := h.runCmd("init", "--name=w", "--src=/host/src")
	if rc != 0 {
		t.Fatalf("init rc=%d logs=%v", rc, logs)
	}
	if len(logs) != 1 || logs[0] != "flint: init ok ws=w stream=main" {
		t.Fatalf("unexpected init logs: %v", logs)
	}

	// Verify exact layout: streams/<id>.json, ws/w/WORKSPACE.json, ws/w/ATOMS.jsonl.
	wsBytes, err := h.fs.ReadFile("/host/FLINT/ws/w/WORKSPACE.json", MaxFileReadBytes)
	if err != nil {
		t.Fatalf("read WORKSPACE.json: %v", err)
	}
	var ws Workspace
	if err := json.Unmarshal(wsBytes, &ws); err != nil {
		t.Fatalf("unmarshal WORKSPACE.json: %v", err)
	}
	if ws.Name != "w" || ws.Src != "/host/src" || !IsUUIDv7(ws.Stream) || ws.Created != h.now*1000 {
		t.Fatalf("unexpected workspace record: %+v", ws)
	}

	atomsBytes, err := h.fs.ReadFile("/host/FLINT/ws/w/ATOMS.jsonl", MaxFileReadBytes)
	if err != nil {
		t.Fatalf("read ATOMS.jsonl: %v", err)
	}
	if len(atomsBytes) != 0 {
		t.Fatalf("expected empty ATOMS.jsonl on init, got %d bytes", len(atomsBytes))
	}

	streamBytes, err := h.fs.ReadFile("/host/FLINT/streams/"+ws.Stream+".json", MaxFileReadBytes)
	if err != nil {
		t.Fatalf("read stream record: %v", err)
	}
	var st Stream
	if err := json.Unmarshal(streamBytes, &st); err != nil {
		t.Fatalf("unmarshal stream record: %v", err)
	}
	if st.ID != ws.Stream || st.Name != "main" || st.Head != nil || st.ForkedFrom != nil {
		t.Fatalf("unexpected stream record: %+v", st)
	}

	// Re-init same workspace -> ws_exists.
	rc, logs = h.runCmd("init", "--name=w", "--src=/host/src")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse ws_exists" {
		t.Fatalf("expected ws_exists refusal, got rc=%d logs=%v", rc, logs)
	}

	// Init a different workspace while stream main already exists -> stream_exists main.
	rc, logs = h.runCmd("init", "--name=w2", "--src=/host/src")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse stream_exists main" {
		t.Fatalf("expected stream_exists main refusal, got rc=%d logs=%v", rc, logs)
	}

	// Missing src -> src_missing.
	h2 := newTestHarness(t)
	rc, logs = h2.runCmd("init", "--name=w", "--src=/host/nope")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse src_missing" {
		t.Fatalf("expected src_missing refusal, got rc=%d logs=%v", rc, logs)
	}
}

func TestUUIDv7MonotonicAndClockUnset(t *testing.T) {
	h := newTestHarness(t)
	var prevBytes [16]byte
	var prevStr string
	for i := 0; i < 1000; i++ {
		id, err := h.uuid.New()
		if err != nil {
			t.Fatalf("uuid %d: %v", i, err)
		}
		if !IsUUIDv7(id) {
			t.Fatalf("uuid %d (%s) is not valid UUIDv7", i, id)
		}
		b, ok := ParseUUID(id)
		if !ok {
			t.Fatalf("ParseUUID(%s) failed", id)
		}
		if i > 0 {
			if bytes.Compare(prevBytes[:], b[:]) >= 0 || prevStr >= id {
				t.Fatalf("uuid %d not strictly increasing: %s >= %s", i, prevStr, id)
			}
		}
		prevBytes = b
		prevStr = id
	}

	// Clock unset refusal (`Now() < 0`).
	h.now = -4 // -ENOSYS
	if err := h.fs.Mkdir("/host/src"); err != nil {
		t.Fatal(err)
	}
	rc, logs := h.runCmd("init", "--name=w", "--src=/host/src")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse clock_unset" {
		t.Fatalf("expected clock_unset refusal, got rc=%d logs=%v", rc, logs)
	}
}

func TestAddIdempotentAndEdits(t *testing.T) {
	h := newTestHarness(t)
	sampleGo := readCorpusFile(t, "go/sample.go")
	sampleZig := readCorpusFile(t, "zig/sample.zig")
	if err := h.fs.WriteFileSafe("/host/src/go/sample.go", sampleGo); err != nil {
		t.Fatal(err)
	}
	if err := h.fs.WriteFileSafe("/host/src/zig/sample.zig", sampleZig); err != nil {
		t.Fatal(err)
	}

	if rc, logs := h.runCmd("init", "--name=w", "--src=/host/src"); rc != 0 {
		t.Fatalf("init failed: %v", logs)
	}

	// Adding sample.go stages 4 adds with well-formed v7 ids.
	rc, logs := h.runCmd("add", "/host/src/go/sample.go")
	if rc != 0 || len(logs) != 1 || logs[0] != "flint: add files=1 new=4 modified=0 deleted=0 unchanged=0" {
		t.Fatalf("unexpected first add: rc=%d logs=%v", rc, logs)
	}

	atoms1, err := LoadWorkspaceAtoms(h.fs, h.root, "w")
	if err != nil || len(atoms1) != 4 {
		t.Fatalf("expected 4 atoms, got %d (err=%v)", len(atoms1), err)
	}
	ids1 := map[string]StoredAtom{}
	for _, a := range atoms1 {
		if !IsUUIDv7(a.ID) {
			t.Fatalf("atom %s has invalid v7 id %s", a.Name, a.ID)
		}
		ids1[a.Name] = a
	}
	stageBytes1, err := h.fs.ReadFile("/host/FLINT/ws/w/STAGE.jsonl", MaxFileReadBytes)
	if err != nil {
		t.Fatal(err)
	}

	// Re-add is idempotent: no new ids and byte-identical STAGE.jsonl.
	h.now += 10
	rc, logs = h.runCmd("add", "/host/src/go/sample.go")
	if rc != 0 || len(logs) != 1 || logs[0] != "flint: add files=1 new=0 modified=0 deleted=0 unchanged=4" {
		t.Fatalf("unexpected second add: rc=%d logs=%v", rc, logs)
	}
	atoms2, err := LoadWorkspaceAtoms(h.fs, h.root, "w")
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range atoms2 {
		if ids1[a.Name].ID != a.ID {
			t.Fatalf("atom %s id changed on re-add: %s -> %s", a.Name, ids1[a.Name].ID, a.ID)
		}
	}
	stageBytes2, err := h.fs.ReadFile("/host/FLINT/ws/w/STAGE.jsonl", MaxFileReadBytes)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(stageBytes1, stageBytes2) {
		t.Fatalf("STAGE.jsonl changed on idempotent re-add:\n%s\nvs\n%s", stageBytes1, stageBytes2)
	}

	// Add zig/sample.zig as well (6 atoms).
	rc, logs = h.runCmd("add", "/host/src/zig/sample.zig")
	if rc != 0 || len(logs) != 1 || logs[0] != "flint: add files=1 new=6 modified=0 deleted=0 unchanged=0" {
		t.Fatalf("unexpected zig add: rc=%d logs=%v", rc, logs)
	}

	// Simulate a committed state by clearing STAGE.jsonl so we can directly
	// inspect `modify` and `delete` Ops produced against ATOMS.jsonl, while
	// also testing fold rules separately below.
	if err := h.fs.Remove("/host/FLINT/ws/w/STAGE.jsonl"); err != nil {
		t.Fatal(err)
	}

	// Edit sample.go: modify Add body (sig_hash unchanged) and remove const Answer.
	editedGo := []byte(`package sample

type Point struct {
	X, Y int
}

func Add(a, b int) int {
	return a + b + 1
}

func Mul(a, b int) int {
	return a * b
}
`)
	// Edit sample.zig: whitespace and comments only -> unchanged.
	editedZig := []byte(`// top comment
const limit = 100;

pub const Point = struct {
    x: i32,
    y: i32,
};

pub fn add(a: i32, b: i32) i32 {
    // comment inside body
    return a + b;
}

fn helper(x: i32) i32 {
    return x * 2;
}

export fn entry() void {}

test "add works" {
    const r = add(1, 2);
    _ = r;
}
`)
	if err := h.fs.WriteFileSafe("/host/src/go/sample.go", editedGo); err != nil {
		t.Fatal(err)
	}
	if err := h.fs.WriteFileSafe("/host/src/zig/sample.zig", editedZig); err != nil {
		t.Fatal(err)
	}

	rc, logs = h.runCmd("add", "/host/src")
	if rc != 0 || len(logs) != 1 || logs[0] != "flint: add files=2 new=0 modified=1 deleted=1 unchanged=8" {
		t.Fatalf("unexpected edit add: rc=%d logs=%v", rc, logs)
	}

	stageOps, err := LoadWorkspaceStage(h.fs, h.root, "w")
	if err != nil || len(stageOps) != 2 {
		t.Fatalf("expected 2 staged ops, got %v (err=%v)", stageOps, err)
	}
	var modOp, delOp *Op
	for i := range stageOps {
		switch stageOps[i].Type {
		case "modify":
			modOp = &stageOps[i]
		case "delete":
			delOp = &stageOps[i]
		}
	}
	if modOp == nil || delOp == nil {
		t.Fatalf("expected one modify and one delete op, got %+v", stageOps)
	}
	origAdd := ids1["sample.Add"]
	if modOp.AtomID != origAdd.ID {
		t.Fatalf("modify AtomID=%s want %s", modOp.AtomID, origAdd.ID)
	}
	if modOp.OldHash != origAdd.Hash || modOp.NewHash == origAdd.Hash {
		t.Fatalf("modify hashes invalid: old=%s new=%s orig=%s", modOp.OldHash, modOp.NewHash, origAdd.Hash)
	}
	if modOp.NewSigHash != origAdd.SigHash {
		t.Fatalf("body edit changed sig_hash: got %s want %s", modOp.NewSigHash, origAdd.SigHash)
	}
	origAnswer := ids1["sample.Answer"]
	if delOp.AtomID != origAnswer.ID || delOp.OldHash != origAnswer.Hash {
		t.Fatalf("delete op invalid: %+v want id=%s hash=%s", *delOp, origAnswer.ID, origAnswer.Hash)
	}
}

func TestStageFoldRulesAndStatus(t *testing.T) {
	h := newTestHarness(t)
	sampleGo := readCorpusFile(t, "go/sample.go")
	if err := h.fs.WriteFileSafe("/host/src/go/sample.go", sampleGo); err != nil {
		t.Fatal(err)
	}
	if rc, _ := h.runCmd("init", "--name=w", "--src=/host/src"); rc != 0 {
		t.Fatal("init failed")
	}
	// First add stages 4 `add` ops.
	if rc, _ := h.runCmd("add", "/host/src"); rc != 0 {
		t.Fatal("first add failed")
	}
	atomsBefore, _ := LoadWorkspaceAtoms(h.fs, h.root, "w")
	var addBefore StoredAtom
	for _, a := range atomsBefore {
		if a.Name == "sample.Add" {
			addBefore = a
		}
	}

	// Second add modifies sample.Add and deletes sample.Answer while both are still staged as `add`:
	// - add + modify -> add (with updated hash)
	// - add + delete -> nothing (vanishes from stage)
	editedGo := []byte(`package sample

type Point struct {
	X, Y int
}

func Add(a, b int) int {
	return a + b + 99
}

func Mul(a, b int) int {
	return a * b
}
`)
	if err := h.fs.WriteFileSafe("/host/src/go/sample.go", editedGo); err != nil {
		t.Fatal(err)
	}
	rc, logs := h.runCmd("add", "/host/src")
	if rc != 0 || len(logs) != 1 || logs[0] != "flint: add files=1 new=0 modified=1 deleted=1 unchanged=2" {
		t.Fatalf("unexpected fold add: rc=%d logs=%v", rc, logs)
	}

	stage, err := LoadWorkspaceStage(h.fs, h.root, "w")
	if err != nil || len(stage) != 3 {
		t.Fatalf("expected 3 staged ops after add+delete fold, got %d (%v)", len(stage), stage)
	}
	for _, op := range stage {
		if op.Type != "add" {
			t.Fatalf("expected all remaining staged ops to be add, got %+v", op)
		}
		if op.NewName == "sample.Answer" {
			t.Fatalf("add+delete failed to vanish sample.Answer: %+v", op)
		}
		if op.NewName == "sample.Add" {
			if op.AtomID != addBefore.ID || op.NewHash == addBefore.Hash || op.NewSigHash != addBefore.SigHash {
				t.Fatalf("add+modify fold wrong on sample.Add: %+v (before=%+v)", op, addBefore)
			}
		}
	}

	// Also verify modify+modify and modify+delete directly via FoldStageOps.
	m1 := []Op{
		{Type: "modify", AtomID: addBefore.ID, OldHash: "1111", NewHash: "2222", NewSigHash: "aaaa"},
	}
	m2 := FoldStageOps(m1, []Op{
		{Type: "modify", AtomID: addBefore.ID, OldHash: "2222", NewHash: "3333", NewSigHash: "bbbb"},
	}, nil)
	if len(m2) != 1 || m2[0].Type != "modify" || m2[0].OldHash != "1111" || m2[0].NewHash != "3333" || m2[0].NewSigHash != "bbbb" {
		t.Fatalf("modify+modify fold wrong: %+v", m2)
	}
	m3 := FoldStageOps(m2, []Op{
		{Type: "delete", AtomID: addBefore.ID, OldHash: "3333"},
	}, nil)
	if len(m3) != 1 || m3[0].Type != "delete" || m3[0].OldHash != "1111" {
		t.Fatalf("modify+delete fold wrong: %+v", m3)
	}

	// Check `flint status`.
	rc, logs = h.runCmd("status")
	if rc != 0 || len(logs) != 4 {
		t.Fatalf("unexpected status output: rc=%d logs=%v", rc, logs)
	}
	if logs[0] != "flint: status ws=w stream=main atoms=3 staged=3 add=3 modify=0 delete=0 duplicates=0" {
		t.Fatalf("unexpected status header: %s", logs[0])
	}

	// Disappeared file from an added directory deletes its Atoms.
	if err := h.fs.WriteFileSafe("/host/src/zig/sample.zig", readCorpusFile(t, "zig/sample.zig")); err != nil {
		t.Fatal(err)
	}
	if rc, _ := h.runCmd("add", "/host/src"); rc != 0 {
		t.Fatal("add zig failed")
	}
	if err := h.fs.Remove("/host/FLINT/ws/w/STAGE.jsonl"); err != nil {
		t.Fatal(err)
	}
	if err := h.fs.Remove("/host/src/zig/sample.zig"); err != nil {
		t.Fatal(err)
	}
	rc, logs = h.runCmd("add", "/host/src")
	if rc != 0 || len(logs) != 1 || logs[0] != "flint: add files=1 new=0 modified=0 deleted=6 unchanged=3" {
		t.Fatalf("expected 6 deleted atoms when file disappears from dir, got rc=%d logs=%v", rc, logs)
	}
}

func TestParseErrorAndDuplicateDeclAllOrNothing(t *testing.T) {
	h := newTestHarness(t)
	if err := h.fs.WriteFileSafe("/host/src/go/a.go", readCorpusFile(t, "go/sample.go")); err != nil {
		t.Fatal(err)
	}
	if err := h.fs.WriteFileSafe("/host/src/go/b.go", readCorpusFile(t, "refuse/bad.go")); err != nil {
		t.Fatal(err)
	}
	if err := h.fs.WriteFileSafe("/host/src/zig/c.zig", readCorpusFile(t, "zig/sample.zig")); err != nil {
		t.Fatal(err)
	}
	if rc, _ := h.runCmd("init", "--name=w", "--src=/host/src"); rc != 0 {
		t.Fatal("init failed")
	}

	// 1 of 3 files has a syntax error -> exits 1, names file and code, stages nothing.
	rc, logs := h.runCmd("add", "/host/src/go/a.go", "/host/src/go/b.go", "/host/src/zig/c.zig")
	if rc != 1 || len(logs) != 1 || !strings.Contains(logs[0], "syntax") || !strings.Contains(logs[0], "go/b.go") {
		t.Fatalf("expected syntax refusal on go/b.go, got rc=%d logs=%v", rc, logs)
	}
	if h.fs.Exists("/host/FLINT/ws/w/STAGE.jsonl") {
		t.Fatal("STAGE.jsonl must not exist after failed add")
	}
	atoms, err := LoadWorkspaceAtoms(h.fs, h.root, "w")
	if err != nil || len(atoms) != 0 {
		t.Fatalf("ATOMS.jsonl must remain empty after failed add, got %d", len(atoms))
	}

	// Duplicate declaration in a file -> refuses duplicate_decl, stages nothing.
	dupZig := []byte("pub fn dup() void {}\npub fn dup() void {}\n")
	if err := h.fs.Remove("/host/src/go/b.go"); err != nil {
		t.Fatal(err)
	}
	if err := h.fs.WriteFileSafe("/host/src/zig/dup.zig", dupZig); err != nil {
		t.Fatal(err)
	}
	rc, logs = h.runCmd("add", "/host/src")
	if rc != 1 || len(logs) != 1 || !strings.Contains(logs[0], "duplicate_decl") || !strings.Contains(logs[0], "zig/dup.zig") {
		t.Fatalf("expected duplicate_decl refusal, got rc=%d logs=%v", rc, logs)
	}
	if h.fs.Exists("/host/FLINT/ws/w/STAGE.jsonl") {
		t.Fatal("STAGE.jsonl must not exist after duplicate_decl")
	}
}

func TestTornLineAndStoreBounds(t *testing.T) {
	h := newTestHarness(t)
	if err := h.fs.Mkdir("/host/src"); err != nil {
		t.Fatal(err)
	}
	if rc, _ := h.runCmd("init", "--name=w", "--src=/host/src"); rc != 0 {
		t.Fatal("init failed")
	}

	// 1. Torn final line in ATOMS.jsonl -> stream_torn.
	if err := h.fs.WriteFileSafe("/host/FLINT/ws/w/ATOMS.jsonl", []byte(`{"id":"01928374-0000-7000-8000-000000000001","kind":"fn","name":"p.F"}`)); err != nil {
		t.Fatal(err)
	}
	rc, logs := h.runCmd("status")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse stream_torn" {
		t.Fatalf("expected stream_torn refusal, got rc=%d logs=%v", rc, logs)
	}
	if err := h.fs.WriteFileSafe("/host/FLINT/ws/w/ATOMS.jsonl", []byte{}); err != nil {
		t.Fatal(err)
	}

	// 2. File size bound (> 4 MiB) -> store_too_large file.
	big := bytes.Repeat([]byte{'a'}, MaxFileReadBytes+1)
	if err := h.fs.WriteFileSafe("/host/src/big.go", big); err != nil {
		t.Fatal(err)
	}
	rc, logs = h.runCmd("add", "/host/src/big.go")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse store_too_large file" {
		t.Fatalf("expected store_too_large file refusal, got rc=%d logs=%v", rc, logs)
	}
	if err := h.fs.Remove("/host/src/big.go"); err != nil {
		t.Fatal(err)
	}

	// 3. Atoms bound (> 4096 Atoms) -> store_too_large atoms.
	var atomsBuf bytes.Buffer
	line := `{"id":"01928374-0000-7000-8000-000000000001","kind":"fn","name":"p.F","hash":"00","sig_hash":"00","span":{"file":"a.go","start":0,"end":1}}` + "\n"
	for i := 0; i <= MaxAtoms; i++ {
		atomsBuf.WriteString(line)
	}
	if err := h.fs.WriteFileSafe("/host/FLINT/ws/w/ATOMS.jsonl", atomsBuf.Bytes()); err != nil {
		t.Fatal(err)
	}
	rc, logs = h.runCmd("status")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse store_too_large atoms" {
		t.Fatalf("expected store_too_large atoms refusal, got rc=%d logs=%v", rc, logs)
	}
	if err := h.fs.WriteFileSafe("/host/FLINT/ws/w/ATOMS.jsonl", []byte{}); err != nil {
		t.Fatal(err)
	}

	// 4. Changes bound (> 4096 Changes) -> store_too_large changes.
	var changesBuf bytes.Buffer
	for i := 0; i <= MaxChanges; i++ {
		changesBuf.WriteString("{}\n")
	}
	if err := h.fs.WriteFileSafe("/host/FLINT/streams/01928374-0000-7000-8000-000000000099.jsonl", changesBuf.Bytes()); err != nil {
		t.Fatal(err)
	}
	rc, logs = h.runCmd("status")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse store_too_large changes" {
		t.Fatalf("expected store_too_large changes refusal, got rc=%d logs=%v", rc, logs)
	}
}
