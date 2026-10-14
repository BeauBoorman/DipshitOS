package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"virelai/sshlib"
)

const testRFC8032SeedHex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
const testRFC8032PubHex = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"

type testHarness struct {
	fs        *memFS
	uuid      *UUIDGen
	root      string
	now       int64
	secretHex string
	hasSecret bool
	logs      []string
}

func newTestHarness(t *testing.T) *testHarness {
	t.Helper()
	h := &testHarness{
		fs:        newMemFS(),
		root:      DefaultStoreRoot,
		now:       1760000000,
		secretHex: testRFC8032SeedHex,
		hasSecret: true,
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
	prevStoreGet := storeGetFn
	defer func() {
		activeFS = prevFS
		storeRoot = prevRoot
		defaultUUIDGen = prevUUID
		consoleFn = prevLog
		storeGetFn = prevStoreGet
	}()

	h.logs = nil
	activeFS = h.fs
	storeRoot = h.root
	defaultUUIDGen = h.uuid
	storeGetFn = func(name string, out []byte) int {
		if name != secretAgentSign || !h.hasSecret {
			return -1
		}
		n := len(h.secretHex)
		if n > len(out) {
			n = len(out)
		}
		copy(out, h.secretHex[:n])
		return n
	}
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

func readSigVector(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "sig", name))
	if err != nil {
		t.Fatalf("read testdata/sig/%s: %v", name, err)
	}
	return b
}

func TestPinnedSigVectorsAndStdlibOracle(t *testing.T) {
	seedHex := strings.TrimSpace(string(readSigVector(t, "seed.hex")))
	preimageHex := strings.TrimSpace(string(readSigVector(t, "preimage.hex")))
	goodRaw := readSigVector(t, "good.jsonl")
	badRaw := readSigVector(t, "bad.jsonl")

	wantPreimage, err := hex.DecodeString(preimageHex)
	if err != nil {
		t.Fatalf("decode preimage.hex: %v", err)
	}
	seedSlice, err := hex.DecodeString(seedHex)
	if err != nil || len(seedSlice) != 32 {
		t.Fatalf("decode seed.hex: %v (len=%d)", err, len(seedSlice))
	}
	var seed [32]byte
	copy(seed[:], seedSlice)

	goodLines, err := ReadJSONLLines(goodRaw)
	if err != nil || len(goodLines) != 1 {
		t.Fatalf("ReadJSONLLines(good.jsonl): len=%d err=%v", len(goodLines), err)
	}
	good, err := ParseChange(goodLines[0])
	if err != nil {
		t.Fatalf("ParseChange(good): %v", err)
	}

	// 1. sigMsg(good) equals preimage.hex byte for byte.
	gotMsg, err := sigMsg(&good)
	if err != nil {
		t.Fatalf("sigMsg(good): %v", err)
	}
	if !bytes.Equal(gotMsg, wantPreimage) {
		t.Fatalf("sigMsg(good) mismatch:\ngot:  %x\nwant: %x", gotMsg, wantPreimage)
	}

	// 2. EdDerivePublic(seed) equals good.Author, and EdSign(seed, msg) equals stored sig.
	derivedPub := sshlib.EdDerivePublic(seed)
	if sshlib.EncodeHex(derivedPub[:]) != good.Author || good.Author != testRFC8032PubHex {
		t.Fatalf("derived pub=%x want %s", derivedPub, good.Author)
	}
	gotSig := sshlib.EdSign(gotMsg, seed)
	if sshlib.EncodeHex(gotSig[:]) != good.Sig {
		t.Fatalf("EdSign mismatch:\ngot:  %x\nwant: %s", gotSig, good.Sig)
	}
	if ok, err := VerifyChange(&good); err != nil || !ok {
		t.Fatalf("VerifyChange(good) = %v, %v", ok, err)
	}

	// 3. Independent oracle: verify good with stdlib crypto/ed25519.
	stdPriv := ed25519.NewKeyFromSeed(seedSlice)
	stdPub := stdPriv.Public().(ed25519.PublicKey)
	if hex.EncodeToString(stdPub) != good.Author {
		t.Fatalf("stdlib pub=%x want %s", stdPub, good.Author)
	}
	sigBytes, err := hex.DecodeString(good.Sig)
	if err != nil {
		t.Fatal(err)
	}
	if !ed25519.Verify(stdPub, gotMsg, sigBytes) {
		t.Fatal("stdlib crypto/ed25519 failed to verify good.jsonl")
	}

	// 4. bad.jsonl fails verification.
	badLines, err := ReadJSONLLines(badRaw)
	if err != nil || len(badLines) != 1 {
		t.Fatalf("ReadJSONLLines(bad.jsonl): len=%d err=%v", len(badLines), err)
	}
	bad, err := ParseChange(badLines[0])
	if err != nil {
		t.Fatalf("ParseChange(bad): %v", err)
	}
	if ok, err := VerifyChange(&bad); err != nil || ok {
		t.Fatalf("VerifyChange(bad) = %v, %v (expected false, nil)", ok, err)
	}

	// Also verify --file via CLI on good.jsonl and bad.jsonl.
	h := newTestHarness(t)
	if err := h.fs.WriteFileSafe("/host/FLINTV/good.jsonl", goodRaw); err != nil {
		t.Fatal(err)
	}
	if err := h.fs.WriteFileSafe("/host/FLINTV/bad.jsonl", badRaw); err != nil {
		t.Fatal(err)
	}
	rc, logs := h.runCmd("verify", "--file=/host/FLINTV/good.jsonl")
	if rc != 0 || len(logs) != 1 || logs[0] != "flint: verify "+good.ID+" sig: verified" {
		t.Fatalf("verify good.jsonl: rc=%d logs=%v", rc, logs)
	}
	rc, logs = h.runCmd("verify", "--file=/host/FLINTV/bad.jsonl")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: verify "+bad.ID+" sig_invalid" {
		t.Fatalf("verify bad.jsonl: rc=%d logs=%v", rc, logs)
	}
}

func cloneChange(c Change) Change {
	out := c
	out.Parent = copyStrPtr(c.Parent)
	out.Merged = copyStrPtr(c.Merged)
	out.Ops = make([]Op, len(c.Ops))
	copy(out.Ops, c.Ops)
	for i := range out.Ops {
		if c.Ops[i].NewSpan != nil {
			sp := *c.Ops[i].NewSpan
			out.Ops[i].NewSpan = &sp
		}
	}
	return out
}

func TestFlipAnySingleFieldFailsVerify(t *testing.T) {
	goodLines, err := ReadJSONLLines(readSigVector(t, "good.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	base, err := ParseChange(goodLines[0])
	if err != nil {
		t.Fatal(err)
	}
	otherUUID := "0199de2d-dc00-7000-8000-000000000999"
	otherHash := "ff" + strings.Repeat("11", 31)
	// RFC 8032 §7.1 TEST 2 public key (valid compressed Edwards point).
	otherAuthor := "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"

	cases := []struct {
		name   string
		mutate func(c *Change)
	}{
		{"id", func(c *Change) { c.ID = otherUUID }},
		{"parent", func(c *Change) { u := otherUUID; c.Parent = &u }},
		{"stream", func(c *Change) { c.Stream = otherUUID }},
		{"ts", func(c *Change) { c.TS++ }},
		{"author", func(c *Change) { c.Author = otherAuthor }},
		{"message", func(c *Change) { c.Message = "pinned vector changX" }},
		{"merged", func(c *Change) { u := otherUUID; c.Merged = &u }},
		{"op0.type", func(c *Change) { c.Ops[0].Type = "modify" }},
		{"op0.atom_id", func(c *Change) { c.Ops[0].AtomID = otherUUID }},
		{"op0.kind", func(c *Change) { c.Ops[0].Kind = "const" }},
		{"op0.new_name", func(c *Change) { c.Ops[0].NewName = "sample.Sub" }},
		{"op0.new_span.file", func(c *Change) { c.Ops[0].NewSpan.File = "go/other.go" }},
		{"op0.new_span.start", func(c *Change) { c.Ops[0].NewSpan.Start++ }},
		{"op0.new_span.end", func(c *Change) { c.Ops[0].NewSpan.End++ }},
		{"op0.new_hash", func(c *Change) { c.Ops[0].NewHash = otherHash }},
		{"op0.new_sig_hash", func(c *Change) { c.Ops[0].NewSigHash = otherHash }},
		{"op1.old_hash", func(c *Change) { c.Ops[1].OldHash = otherHash }},
		{"op2.old_hash", func(c *Change) { c.Ops[2].OldHash = otherHash }},
	}

	h := newTestHarness(t)
	for _, tc := range cases {
		m := cloneChange(base)
		tc.mutate(&m)
		line, err := MarshalChangeLine(m)
		if err != nil {
			t.Fatalf("%s: MarshalChangeLine: %v", tc.name, err)
		}
		if err := h.fs.WriteFileSafe("/host/FLINTV/mut.jsonl", line); err != nil {
			t.Fatal(err)
		}
		rc, logs := h.runCmd("verify", "--file=/host/FLINTV/mut.jsonl")
		if rc != 1 || len(logs) != 1 || logs[0] != "flint: verify "+m.ID+" sig_invalid" {
			t.Fatalf("%s: expected sig_invalid, got rc=%d logs=%v", tc.name, rc, logs)
		}
	}
}

func TestJSONKeyOrderAndWhitespaceInvariance(t *testing.T) {
	goodLines, err := ReadJSONLLines(readSigVector(t, "good.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	c, err := ParseChange(goodLines[0])
	if err != nil {
		t.Fatal(err)
	}

	// Re-encode with reversed op order, reordered object keys, and extra whitespace inside the line.
	reordered := `{  "sig" : "` + c.Sig + `" , "merged" : null , "message" : "` + c.Message + `" , ` +
		`"author" : "` + c.Author + `" , "ts" : 1760000000000 , "stream" : "` + c.Stream + `" , ` +
		`"parent" : null , "id" : "` + c.ID + `" , "ops" : [ ` +
		`{ "old_hash" : "` + c.Ops[2].OldHash + `" , "atom_id" : "` + c.Ops[2].AtomID + `" , "type" : "delete" } , ` +
		`{ "old_hash" : "` + c.Ops[1].OldHash + `" , "new_sig_hash" : "` + c.Ops[1].NewSigHash + `" , "new_hash" : "` + c.Ops[1].NewHash + `" , "atom_id" : "` + c.Ops[1].AtomID + `" , "type" : "modify" } , ` +
		`{ "new_sig_hash" : "` + c.Ops[0].NewSigHash + `" , "new_hash" : "` + c.Ops[0].NewHash + `" , "new_span" : { "end" : 85 , "start" : 40 , "file" : "go/sample.go" } , "new_name" : "sample.Add" , "kind" : "fn" , "atom_id" : "` + c.Ops[0].AtomID + `" , "type" : "add" } ` +
		`] }` + "\n"

	h := newTestHarness(t)
	if err := h.fs.WriteFileSafe("/host/FLINTV/reordered.jsonl", []byte(reordered)); err != nil {
		t.Fatal(err)
	}
	rc, logs := h.runCmd("verify", "--file=/host/FLINTV/reordered.jsonl")
	if rc != 0 || len(logs) != 1 || logs[0] != "flint: verify "+c.ID+" sig: verified" {
		t.Fatalf("expected reordered JSON to verify, got rc=%d logs=%v", rc, logs)
	}
}

func TestCommitLogVerifyAndRollForward(t *testing.T) {
	h := newTestHarness(t)
	sampleGo := readCorpusFile(t, "go/sample.go")
	if err := h.fs.WriteFileSafe("/host/src/go/sample.go", sampleGo); err != nil {
		t.Fatal(err)
	}
	if rc, logs := h.runCmd("init", "--name=w", "--src=/host/src"); rc != 0 {
		t.Fatalf("init: %v", logs)
	}
	if rc, logs := h.runCmd("add", "/host/src"); rc != 0 {
		t.Fatalf("add: %v", logs)
	}

	// Inject a fault AFTER the append to streams/<id>.jsonl and BEFORE rewriting streams/<id>.json.
	wsBytes, err := h.fs.ReadFile("/host/FLINT/ws/w/WORKSPACE.json", MaxFileReadBytes)
	if err != nil {
		t.Fatal(err)
	}
	var ws Workspace
	if err := json.Unmarshal(wsBytes, &ws); err != nil {
		t.Fatal(err)
	}
	recPath := streamRecordPath(h.root, ws.Stream)
	logPath := streamLogPath(h.root, ws.Stream)

	h.fs.beforeWrite = func(op, path string) error {
		if op == "write" && path == recPath {
			return errors.New("simulated crash before record rewrite")
		}
		return nil
	}
	rc, logs := h.runCmd("commit", "-m", "first commit\nextra detail")
	h.fs.beforeWrite = nil
	if rc != 1 {
		t.Fatalf("expected faulted commit to return 1, got rc=%d logs=%v", rc, logs)
	}

	// Verify the log was written, while the record still has head == null.
	if !h.fs.Exists(logPath) {
		t.Fatal("expected stream log to exist after append")
	}
	rawRec, err := h.fs.ReadFile(recPath, MaxFileReadBytes)
	if err != nil {
		t.Fatal(err)
	}
	var staleSt Stream
	if err := json.Unmarshal(rawRec, &staleSt); err != nil {
		t.Fatal(err)
	}
	if staleSt.Head != nil {
		t.Fatalf("expected stale record head to be nil before roll-forward, got %v", *staleSt.Head)
	}

	// Next load rolls the stale record forward!
	rc, logs = h.runCmd("log")
	if rc != 0 || len(logs) != 1 {
		t.Fatalf("expected log to roll forward and print 1 change, got rc=%d logs=%v", rc, logs)
	}
	healedSt, changes, err := LoadStream(h.fs, h.root, ws.Stream)
	if err != nil || len(changes) != 1 || healedSt.Head == nil || *healedSt.Head != changes[0].ID {
		t.Fatalf("expected healed stream head == %v, got st=%+v changes=%d err=%v", changes, healedSt, len(changes), err)
	}
	firstID := changes[0].ID
	wantLog0 := "flint: change " + firstID + " parent=none ops=4 author=" + testRFC8032PubHex[:8] + " msg=first commit"
	if logs[0] != wantLog0 {
		t.Fatalf("log[0] = %q want %q", logs[0], wantLog0)
	}

	// Clean up STAGE.jsonl left from the simulated crash and perform a second linear commit.
	_ = h.fs.Remove(workspaceStagePath(h.root, "w"))
	editedGo := []byte("package sample\n\ntype Point struct { X, Y int }\nfunc Add(a, b int) int { return a - b }\nfunc Mul(a, b int) int { return a * b }\n")
	if err := h.fs.WriteFileSafe("/host/src/go/sample.go", editedGo); err != nil {
		t.Fatal(err)
	}
	h.now += 5
	if rc, logs := h.runCmd("add", "/host/src"); rc != 0 {
		t.Fatalf("second add: %v", logs)
	}
	rc, logs = h.runCmd("commit", "-m", "second commit")
	if rc != 0 || len(logs) != 1 {
		t.Fatalf("second commit: rc=%d logs=%v", rc, logs)
	}
	if !strings.HasPrefix(logs[0], "flint: commit ok id=") || !strings.HasSuffix(logs[0], " ops=2 parent="+firstID) {
		t.Fatalf("unexpected second commit output: %s", logs[0])
	}
	if h.fs.Exists(workspaceStagePath(h.root, "w")) {
		t.Fatal("STAGE.jsonl must be removed after commit")
	}

	// `flint log --stream=main` prints newest first (2 lines).
	rc, logs = h.runCmd("log", "--stream=main")
	if rc != 0 || len(logs) != 2 {
		t.Fatalf("log --stream=main: rc=%d logs=%v", rc, logs)
	}
	_, changes, err = LoadStream(h.fs, h.root, ws.Stream)
	if err != nil || len(changes) != 2 {
		t.Fatalf("expected 2 changes, got %d err=%v", len(changes), err)
	}
	secondID := changes[1].ID
	if !strings.HasPrefix(logs[0], "flint: change "+secondID+" parent="+firstID+" ops=2 ") {
		t.Fatalf("unexpected newest log line: %s", logs[0])
	}
	if logs[1] != wantLog0 {
		t.Fatalf("unexpected oldest log line: %s", logs[1])
	}

	// `flint verify --all` and `flint verify <id>` both verify.
	rc, logs = h.runCmd("verify", "--all")
	if rc != 0 || len(logs) != 2 ||
		logs[0] != "flint: verify "+firstID+" sig: verified" ||
		logs[1] != "flint: verify "+secondID+" sig: verified" {
		t.Fatalf("verify --all: rc=%d logs=%v", rc, logs)
	}
	rc, logs = h.runCmd("verify", secondID)
	if rc != 0 || len(logs) != 1 || logs[0] != "flint: verify "+secondID+" sig: verified" {
		t.Fatalf("verify <id>: rc=%d logs=%v", rc, logs)
	}
}

func TestCommitAndVerifyRefusals(t *testing.T) {
	h := newTestHarness(t)
	if err := h.fs.WriteFileSafe("/host/src/go/sample.go", readCorpusFile(t, "go/sample.go")); err != nil {
		t.Fatal(err)
	}
	if rc, _ := h.runCmd("init", "--name=w", "--src=/host/src"); rc != 0 {
		t.Fatal("init failed")
	}

	// 1. nothing_to_commit when stage is empty.
	rc, logs := h.runCmd("commit", "-m", "empty")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse nothing_to_commit" {
		t.Fatalf("expected nothing_to_commit, got rc=%d logs=%v", rc, logs)
	}

	if rc, _ := h.runCmd("add", "/host/src"); rc != 0 {
		t.Fatal("add failed")
	}

	// 2. message_invalid: empty, > 512 bytes, invalid UTF-8.
	for _, badMsg := range []string{
		"",
		strings.Repeat("x", 513),
		string([]byte{0xff, 0xfe, 0xfd}),
	} {
		rc, logs = h.runCmd("commit", "-m", badMsg)
		if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse message_invalid" {
			t.Fatalf("expected message_invalid for len=%d, got rc=%d logs=%v", len(badMsg), rc, logs)
		}
	}

	// 3. secret_not_found: no file written!
	wsBytes, _ := h.fs.ReadFile("/host/FLINT/ws/w/WORKSPACE.json", MaxFileReadBytes)
	var ws Workspace
	_ = json.Unmarshal(wsBytes, &ws)
	logPath := streamLogPath(h.root, ws.Stream)
	stageBefore, _ := h.fs.ReadFile("/host/FLINT/ws/w/STAGE.jsonl", MaxFileReadBytes)

	h.hasSecret = false
	wroteAny := false
	h.fs.beforeWrite = func(op, path string) error {
		wroteAny = true
		return nil
	}
	rc, logs = h.runCmd("commit", "-m", "no secret")
	h.fs.beforeWrite = nil
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse secret_not_found" {
		t.Fatalf("expected secret_not_found, got rc=%d logs=%v", rc, logs)
	}
	if wroteAny || h.fs.Exists(logPath) || !h.fs.Exists("/host/FLINT/ws/w/STAGE.jsonl") {
		t.Fatalf("secret_not_found must not write or remove any file (wroteAny=%v)", wroteAny)
	}
	stageAfter, _ := h.fs.ReadFile("/host/FLINT/ws/w/STAGE.jsonl", MaxFileReadBytes)
	if !bytes.Equal(stageBefore, stageAfter) {
		t.Fatal("STAGE.jsonl changed after secret_not_found")
	}

	// 4. secret_malformed: short, uppercase hex, non-hex. Also ensure seed never leaks to logs.
	h.hasSecret = true
	for _, badHex := range []string{
		"deadbeef",
		strings.ToUpper(testRFC8032SeedHex),
		strings.Repeat("g", 64),
	} {
		h.secretHex = badHex
		rc, logs = h.runCmd("commit", "-m", "bad secret")
		if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse secret_malformed" {
			t.Fatalf("expected secret_malformed for %q, got rc=%d logs=%v", badHex, rc, logs)
		}
		for _, l := range logs {
			if strings.Contains(l, badHex[:8]) {
				t.Fatalf("secret prefix leaked in log: %s", l)
			}
		}
	}
	h.secretHex = testRFC8032SeedHex

	// 5. stale_head: concurrent head move before AppendStreamChange.
	beforeCommitAppend = func() {
		moved := "0199de2d-dc00-7000-8000-000000000777"
		st := Stream{
			ID:      ws.Stream,
			Name:    "main",
			Head:    &moved,
			Created: h.now * 1000,
		}
		_ = WriteStreamRecord(h.fs, h.root, &st)
	}
	rc, logs = h.runCmd("commit", "-m", "concurrent move")
	beforeCommitAppend = nil
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse stale_head" {
		t.Fatalf("expected stale_head, got rc=%d logs=%v", rc, logs)
	}
	if h.fs.Exists(logPath) {
		t.Fatal("stale_head must not append to stream log")
	}

	// Restore stream record head to nil and test stream_torn + change_malformed.
	stReset := Stream{ID: ws.Stream, Name: "main", Head: nil, Created: h.now * 1000}
	if err := WriteStreamRecord(h.fs, h.root, &stReset); err != nil {
		t.Fatal(err)
	}

	// 6. stream_torn on streams/<id>.jsonl.
	if err := h.fs.WriteFileSafe(logPath, []byte(`{"id":"0199de2d-dc00-7000-8000-000000000100"}`)); err != nil {
		t.Fatal(err)
	}
	rc, logs = h.runCmd("log")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse stream_torn" {
		t.Fatalf("expected stream_torn on log, got rc=%d logs=%v", rc, logs)
	}

	// 7. change_malformed on verify --file.
	if err := h.fs.WriteFileSafe("/host/FLINTV/malformed.jsonl", []byte("{\"id\":\"not-a-uuid\"}\n")); err != nil {
		t.Fatal(err)
	}
	rc, logs = h.runCmd("verify", "--file=/host/FLINTV/malformed.jsonl")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse change_malformed" {
		t.Fatalf("expected change_malformed on verify --file, got rc=%d logs=%v", rc, logs)
	}
}
