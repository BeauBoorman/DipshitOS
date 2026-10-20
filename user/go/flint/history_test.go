package main

import (
	"strings"
	"testing"
)

// seedCalcHistory drives the shared M138c fixture: ws a on `main` and ws b
// on `feature` over identical calc.go sources — base commit, fork, feat
// commit (X:=10 on feature), main commit (Y:=20), merge feature -> main.
// Returns the change ids in DAG order (base, feat, main, merge).
func seedCalcHistory(t *testing.T, h *testHarness) (base, feat, main, merge string) {
	t.Helper()
	baseSrc := []byte("package calc\n\nfunc X() int {\n\treturn 1\n}\n\nfunc Y() int {\n\treturn 2\n}\n")
	for _, dir := range []string{"/host/SRCA", "/host/SRCB"} {
		if err := h.fs.WriteFileSafe(dir+"/calc.go", baseSrc); err != nil {
			t.Fatal(err)
		}
	}
	if rc, logs := h.runCmd("init", "--name=a", "--src=/host/SRCA"); rc != 0 {
		t.Fatalf("init a: %v", logs)
	}
	if rc, logs := h.runCmd("add", "/host/SRCA"); rc != 0 {
		t.Fatalf("add a: %v", logs)
	}
	if rc, logs := h.runCmd("commit", "-m", "base"); rc != 0 {
		t.Fatalf("commit base: %v", logs)
	}
	if rc, logs := h.runCmd("fork", "main", "feature"); rc != 0 {
		t.Fatalf("fork: %v", logs)
	}
	h.now += 5
	if rc, logs := h.runCmd("init", "--name=b", "--src=/host/SRCB", "--stream=feature"); rc != 0 {
		t.Fatalf("init b: %v", logs)
	}
	featSrc := []byte("package calc\n\nfunc X() int {\n\treturn 10\n}\n\nfunc Y() int {\n\treturn 2\n}\n")
	if err := h.fs.WriteFileSafe("/host/SRCB/calc.go", featSrc); err != nil {
		t.Fatal(err)
	}
	h.now += 5
	if rc, logs := h.runCmd("add", "/host/SRCB"); rc != 0 {
		t.Fatalf("add b: %v", logs)
	}
	if rc, logs := h.runCmd("commit", "--ws=b", "-m", "feat"); rc != 0 {
		t.Fatalf("commit feat: %v", logs)
	}
	mainSrc := []byte("package calc\n\nfunc X() int {\n\treturn 1\n}\n\nfunc Y() int {\n\treturn 20\n}\n")
	if err := h.fs.WriteFileSafe("/host/SRCA/calc.go", mainSrc); err != nil {
		t.Fatal(err)
	}
	h.now += 5
	if rc, logs := h.runCmd("add", "/host/SRCA"); rc != 0 {
		t.Fatalf("add a2: %v", logs)
	}
	if rc, logs := h.runCmd("commit", "-m", "main"); rc != 0 {
		t.Fatalf("commit main: %v", logs)
	}
	h.now += 5
	if rc, logs := h.runCmd("merge", "feature"); rc != 0 {
		t.Fatalf("merge: %v", logs)
	}

	idx, err := LoadStoreIndex(h.fs, h.root)
	if err != nil {
		t.Fatal(err)
	}
	_, mainCh, err := LoadStream(h.fs, h.root, idx.StreamsByName["main"].ID)
	if err != nil || len(mainCh) != 3 {
		t.Fatalf("main stream: %v len=%d", err, len(mainCh))
	}
	_, featCh, err := LoadStream(h.fs, h.root, idx.StreamsByName["feature"].ID)
	if err != nil || len(featCh) != 1 {
		t.Fatalf("feature stream: %v len=%d", err, len(featCh))
	}
	return mainCh[0].ID, featCh[0].ID, mainCh[1].ID, mainCh[2].ID
}

func TestBlameAttributesLines(t *testing.T) {
	h := newTestHarness(t)
	base, _, mainID, merge := seedCalcHistory(t, h)

	rc, logs := h.runCmd("blame", "--ws=a", "/host/SRCA/calc.go")
	if rc != 0 {
		t.Fatalf("blame: rc=%d logs=%v", rc, logs)
	}
	pub := testRFC8032PubHex[:8]
	// SRCA on disk holds main's content. In main's history the merge op
	// last touched atom X and the "main" commit touched atom Y; lines
	// outside both spans (package clause, blank lines) print -.
	want := []string{
		"flint: blame - - package calc",
		"flint: blame - - ",
		"flint: blame " + merge + " " + pub + " func X() int {",
		"flint: blame " + merge + " " + pub + " \treturn 1",
		"flint: blame " + merge + " " + pub + " }",
		"flint: blame - - ",
		"flint: blame " + mainID + " " + pub + " func Y() int {",
		"flint: blame " + mainID + " " + pub + " \treturn 20",
		"flint: blame " + mainID + " " + pub + " }",
	}
	_ = base
	if len(logs) != len(want) {
		t.Fatalf("blame rows=%d want %d: %v", len(logs), len(want), logs)
	}
	for i, w := range want {
		if logs[i] != w && !strings.HasPrefix(logs[i]+" ", w) {
			t.Fatalf("row %d = %q want %q", i, logs[i], w)
		}
	}
	// Every attributed line carries the author prefix.
	for _, l := range logs {
		if strings.HasPrefix(l, "flint: blame - - ") {
			continue
		}
		if !strings.Contains(l, pub) {
			t.Fatalf("missing author prefix in %q", l)
		}
	}

	// Refusals: missing file, file outside src, unsupported extension.
	rc, logs = h.runCmd("blame", "--ws=a", "/host/SRCA/nope.go")
	if rc != 1 || logs[0] != "flint: refuse src_missing nope.go" {
		t.Fatalf("src_missing: rc=%d logs=%v", rc, logs)
	}
	rc, logs = h.runCmd("blame", "--ws=a", "/host/other/calc.go")
	if rc != 1 || logs[0] != "flint: refuse src_missing /host/other/calc.go" {
		t.Fatalf("outside-src: rc=%d logs=%v", rc, logs)
	}
	if err := h.fs.WriteFileSafe("/host/SRCA/notes.txt", []byte("hi\n")); err != nil {
		t.Fatal(err)
	}
	rc, logs = h.runCmd("blame", "--ws=a", "/host/SRCA/notes.txt")
	if rc != 1 || logs[0] != "flint: refuse parse_unsupported notes.txt" {
		t.Fatalf("parse_unsupported: rc=%d logs=%v", rc, logs)
	}
}

func TestLogGraphForkMerge(t *testing.T) {
	h := newTestHarness(t)
	base, feat, mainID, merge := seedCalcHistory(t, h)

	rc, logs := h.runCmd("log", "--graph", "--stream=main")
	if rc != 0 {
		t.Fatalf("log --graph: rc=%d logs=%v", rc, logs)
	}
	cells := make([]string, len(logs))
	for i, l := range logs {
		if !strings.HasPrefix(l, "flint: graph ") {
			t.Fatalf("bad graph line: %q", l)
		}
		cells[i] = strings.TrimPrefix(l, "flint: graph ")
	}
	// Golden lane shape: merge opens the feature lane, it folds at base.
	// Node order is ts desc: merge, main, feat, base.
	wantCells := []string{
		"* " + merge[:8],
		"|\\",
		"*|" + " " + mainID[:8],
		"|*" + " " + feat[:8],
		"|/",
		"* " + base[:8],
	}
	if len(cells) != len(wantCells) {
		t.Fatalf("graph rows=%d want %d: %v", len(cells), len(wantCells), cells)
	}
	for i, wc := range wantCells {
		if !strings.HasPrefix(cells[i], wc) {
			t.Fatalf("row %d = %q want prefix %q", i, cells[i], wc)
		}
	}
	if !strings.Contains(logs[0], "merge feature") || !strings.Contains(logs[2], "main") ||
		!strings.Contains(logs[3], "feat") || !strings.Contains(logs[5], "base") {
		t.Fatalf("missing message text: %v", logs)
	}
	if !strings.Contains(logs[0], testRFC8032PubHex[:8]) {
		t.Fatalf("missing author prefix: %v", logs[0])
	}
}

func TestTagRoundTripAndRefusals(t *testing.T) {
	h := newTestHarness(t)
	base, _, mainID, merge := seedCalcHistory(t, h)

	// tag NAME defaults to the resolved stream head (ws a -> main merge).
	rc, logs := h.runCmd("tag", "--ws=a", "v1")
	if rc != 0 || len(logs) != 1 || logs[0] != "flint: tag ok v1 "+merge {
		t.Fatalf("tag v1: rc=%d logs=%v", rc, logs)
	}
	// tag NAME CHANGE names an explicit change on another stream.
	rc, logs = h.runCmd("tag", "base", base)
	if rc != 0 || logs[0] != "flint: tag ok base "+base {
		t.Fatalf("tag base: rc=%d logs=%v", rc, logs)
	}
	// Duplicate refuses tag_exists; bad target refuses change_missing.
	rc, logs = h.runCmd("tag", "v1", mainID)
	if rc != 1 || logs[0] != "flint: refuse tag_exists v1" {
		t.Fatalf("tag_exists: rc=%d logs=%v", rc, logs)
	}
	rc, logs = h.runCmd("tag", "nope", "0199de2d-dc00-7000-8000-000000000999")
	if rc != 1 || logs[0] != "flint: refuse change_missing 0199de2d-dc00-7000-8000-000000000999" {
		t.Fatalf("change_missing: rc=%d logs=%v", rc, logs)
	}

	// List: name-sorted, resolves stream names.
	rc, logs = h.runCmd("tag", "-l")
	if rc != 0 || len(logs) != 3 ||
		logs[0] != "flint: tag base "+base+" main" ||
		logs[1] != "flint: tag v1 "+merge+" main" ||
		logs[2] != "flint: tags 2" {
		t.Fatalf("tag -l: rc=%d logs=%v", rc, logs)
	}

	// The graph annotates tagged nodes.
	rc, logs = h.runCmd("log", "--graph", "--stream=main")
	if rc != 0 {
		t.Fatalf("graph: %v", logs)
	}
	if !strings.Contains(logs[0], "(tag: v1)") || !strings.Contains(logs[5], "(tag: base)") {
		t.Fatalf("graph missing tag annotations: %v", logs)
	}

	// Round-trip through the on-disk record (reboot persistence).
	tags, err := LoadTags(h.fs, h.root)
	if err != nil || len(tags) != 2 {
		t.Fatalf("LoadTags: %v len=%d", err, len(tags))
	}
	if tags[0].Name != "base" || tags[0].Change != base || tags[1].Name != "v1" || tags[1].Change != merge {
		t.Fatalf("stored tags: %+v", tags)
	}
	for _, tg := range tags {
		if tg.Kind != "tag" || !IsUUIDv7(tg.ID) || tg.TS <= 0 {
			t.Fatalf("malformed tag record: %+v", tg)
		}
	}

	// Delete: tag_missing, then rm, then the surviving row.
	rc, logs = h.runCmd("tag", "-d", "ghost")
	if rc != 1 || logs[0] != "flint: refuse tag_missing ghost" {
		t.Fatalf("tag_missing: rc=%d logs=%v", rc, logs)
	}
	rc, logs = h.runCmd("tag", "-d", "base")
	if rc != 0 || logs[0] != "flint: tag rm base" {
		t.Fatalf("tag -d: rc=%d logs=%v", rc, logs)
	}
	rc, logs = h.runCmd("tag", "-l")
	if rc != 0 || len(logs) != 2 || logs[0] != "flint: tag v1 "+merge+" main" || logs[1] != "flint: tags 1" {
		t.Fatalf("tag -l after rm: rc=%d logs=%v", rc, logs)
	}
}
