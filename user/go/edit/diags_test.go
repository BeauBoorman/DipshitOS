package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// diags_test.go pins the M107c (#2320) build-error list: the ERRORS.TXT
// grammar, the path walk, the named refusals (none / stale / dirty /
// no-position / end / miss / rc=), and the next/prev stepping semantics.

// fakeDiagFiles substitutes the three diagnostics seams: contents is the
// ERRORS.TXT bytes (absent key = file missing), mtimes the per-path stamps
// the stat seam reports (absent key = stat failed).
func fakeDiagFiles(t *testing.T, exists map[string]bool, contents map[string][]byte, mtimes map[string]int64) {
	t.Helper()
	oldRead, oldExists, oldStat := errRead, errExists, errStat
	errRead = func(p string) ([]byte, int64) {
		b, ok := contents[p]
		if !ok {
			return nil, -9
		}
		return b, 0
	}
	errExists = func(p string) bool { return exists[p] }
	errStat = func(p string) (int64, bool) {
		m, ok := mtimes[p]
		return m, ok
	}
	t.Cleanup(func() { errRead, errExists, errStat = oldRead, oldExists, oldStat })
}

// fakeBufferFile substitutes the buffer-read seam so openFile can swap to a
// real body on the host.
func fakeBufferFile(t *testing.T, contents map[string][]byte) {
	t.Helper()
	old := bufRead
	bufRead = func(p string, max int) ([]byte, int64) {
		b, ok := contents[p]
		if !ok {
			return nil, -9
		}
		return b, 0
	}
	t.Cleanup(func() { bufRead = old })
}

func TestParseDiag(t *testing.T) {
	cases := []struct {
		line             string
		file             string
		lineno, col, okN int
		ok               bool
	}{
		{"/host/BAD/main.go:3:8: cannot find package \"missing\"", "/host/BAD/main.go", 3, 8, 0, true},
		{"/host/WSP/helper/h.go:2:15: expected ';', found '}'", "/host/WSP/helper/h.go", 2, 15, 0, true},
		// The message may hold colons — the walk is left-to-right.
		{"/host/BAD/m.go:1:12: undefined: x", "/host/BAD/m.go", 1, 12, 0, true},
		// The driver's positionless shape renders under "gobuild" at 0:0.
		{"gobuild:0:0: compile main: spawn GOCMDCOMPILE.ELF", "gobuild", 0, 0, 0, true},
		{"panic: index out of range", "", 0, 0, 0, false},
		{":3:8: no file", "", 0, 0, 0, false},
		// The writer's grammar terminates the column with ':' — a bare
		// `file:line:col` or junk right after the digits is not a position.
		{"a.go:1:2", "", 0, 0, 0, false},
		{"a.go:1:2xyz: trailing junk is not a column", "", 0, 0, 0, false},
	}
	for _, c := range cases {
		r, ok := parseDiag(c.line)
		if ok != c.ok || r.file != c.file || r.line != c.lineno || r.col != c.col {
			t.Fatalf("parseDiag(%q) = %+v,%v want file=%q line=%d col=%d ok=%v",
				c.line, r, ok, c.file, c.lineno, c.col, c.ok)
		}
		if r.raw != c.line {
			t.Fatalf("raw lost the line: %q", r.raw)
		}
	}
}

func TestErrorsPathWalksUp(t *testing.T) {
	fakeDiagFiles(t,
		map[string]bool{"/host/BAD/.BUILD/ERRORS.TXT": true},
		nil, nil)
	e := &editor{doc: doc{path: "/host/BAD/helper/bad.go"}}
	if got := e.errorsPath(); got != "/host/BAD/.BUILD/ERRORS.TXT" {
		t.Fatalf("errorsPath = %q, want the parent build dir", got)
	}
	e.diagsArg = "/host/OTHER/.BUILD/ERRORS.TXT"
	if got := e.errorsPath(); got != e.diagsArg {
		t.Fatalf("--diags= override lost: %q", got)
	}
}

func TestLoadErrorsNoneAndStale(t *testing.T) {
	// No .BUILD anywhere: the named refusal is `none`.
	fakeDiagFiles(t, map[string]bool{}, nil, nil)
	e := &editor{doc: doc{path: "/host/SEED.TXT", buf: []byte("x")}}
	e.loadErrors()
	if e.diags != nil {
		t.Fatal("none must leave the list empty")
	}
	// A build's own ERRORS.TXT that is OLDER than the edited file is
	// stale: the file was saved since the build ran.
	errs := "/host/BAD/.BUILD/ERRORS.TXT"
	fakeDiagFiles(t,
		map[string]bool{errs: true},
		map[string][]byte{errs: []byte("/host/BAD/main.go:3:8: boom\n")},
		map[string]int64{errs: 100, "/host/BAD/main.go": 200})
	e = &editor{doc: doc{path: "/host/BAD/main.go"}}
	e.loadErrors()
	if e.diags != nil {
		t.Fatal("a saved-since file must refuse the stale list")
	}
	// Fresh build (errors newer than the file): the list loads.
	fakeDiagFiles(t,
		map[string]bool{errs: true},
		map[string][]byte{errs: []byte("/host/BAD/main.go:3:8: boom\n")},
		map[string]int64{errs: 200, "/host/BAD/main.go": 100})
	e.loadErrors()
	if len(e.diags) != 1 {
		t.Fatalf("fresh list must load, got %d rows", len(e.diags))
	}
}

func TestJumpDiagSameFile(t *testing.T) {
	errs := "/host/BAD/.BUILD/ERRORS.TXT"
	fakeDiagFiles(t,
		map[string]bool{errs: true},
		map[string][]byte{errs: []byte("/host/BAD/main.go:3:2: boom\n")},
		map[string]int64{errs: 200, "/host/BAD/main.go": 100})
	e := usEditor("package main\nimport \"x\"\nfunc main() {}\n")
	e.path = "/host/BAD/main.go"
	e.loadErrors()
	e.jumpDiag(0)
	// Line 3 col 2 in "func main() {}" is offset of 'u'+1... compute:
	// lineOffset(3) + (col-1) = len("package main\nimport \"x\"\n") + 1.
	want := len("package main\nimport \"x\"\n") + 1
	if e.cur != want {
		t.Fatalf("caret = %d want %d", e.cur, want)
	}
	if e.diagsSel != 0 {
		t.Fatalf("diagsSel = %d want 0", e.diagsSel)
	}
}

func TestStepDiagBounds(t *testing.T) {
	errs := "/host/BAD/.BUILD/ERRORS.TXT"
	fakeDiagFiles(t,
		map[string]bool{errs: true},
		map[string][]byte{errs: []byte("/host/BAD/main.go:1:1: one\n/host/BAD/main.go:2:1: two\n")},
		map[string]int64{errs: 200, "/host/BAD/main.go": 100})
	e := usEditor("aa\nbb\ncc\n")
	e.path = "/host/BAD/main.go"
	// First step loads and lands on row 0.
	e.stepDiag(1)
	if e.diagsSel != 0 || e.cur != 0 {
		t.Fatalf("first step: sel=%d cur=%d", e.diagsSel, e.cur)
	}
	e.stepDiag(1)
	if e.diagsSel != 1 || e.cur != 3 {
		t.Fatalf("second step: sel=%d cur=%d", e.diagsSel, e.cur)
	}
	e.stepDiag(1) // off the end — the `end` refusal, sel does not move.
	if e.diagsSel != 1 {
		t.Fatalf("end refusal moved sel: %d", e.diagsSel)
	}
	e.stepDiag(-1)
	if e.diagsSel != 0 || e.cur != 0 {
		t.Fatalf("prev step: sel=%d cur=%d", e.diagsSel, e.cur)
	}
	e.stepDiag(-1) // off the front — same refusal.
	if e.diagsSel != 0 {
		t.Fatalf("end refusal moved sel: %d", e.diagsSel)
	}
}

func TestJumpDiagCrossFile(t *testing.T) {
	errs := "/host/BAD/.BUILD/ERRORS.TXT"
	fakeDiagFiles(t,
		map[string]bool{errs: true},
		map[string][]byte{errs: []byte("/host/BAD/helper/bad.go:2:1: boom\n")},
		map[string]int64{errs: 200, "/host/BAD/helper/bad.go": 100})
	fakeBufferFile(t, map[string][]byte{
		"/host/BAD/helper/bad.go": []byte("package helper\nfunc Broken() {}\n"),
	})
	e := usEditor("package main\nimport \"helper\"\n")
	e.path = "/host/BAD/main.go"
	e.loadErrors()
	e.jumpDiag(0)
	if e.path != "/host/BAD/helper/bad.go" {
		t.Fatalf("cross-file jump did not swap the buffer: %q", e.path)
	}
	if e.cur != len("package helper\n") {
		t.Fatalf("caret = %d want line 2 start", e.cur)
	}
	if e.dirty {
		t.Fatal("a swapped buffer is clean, not dirty")
	}
}

// M166a (#2979): the dirty refusal is gone — the ring holds the dirty
// buffer while the jump opens the diagnostic's file in a new one. `full`
// answers only when the ring has no room (ring_test pins that).
func TestJumpDiagCrossFileDirtyOpensABuffer(t *testing.T) {
	errs := "/host/BAD/.BUILD/ERRORS.TXT"
	fakeDiagFiles(t,
		map[string]bool{errs: true},
		map[string][]byte{errs: []byte("/host/BAD/helper/bad.go:2:1: boom\n")},
		map[string]int64{errs: 200, "/host/BAD/main.go": 100})
	fakeBufferFile(t, map[string][]byte{
		"/host/BAD/helper/bad.go": []byte("package helper\nfunc Broken() {}\n"),
	})
	e := usEditor("package main\n")
	e.path = "/host/BAD/main.go"
	e.dirty = true
	e.docs = []doc{e.doc}
	e.loadErrors()
	e.jumpDiag(0)
	if e.path != "/host/BAD/helper/bad.go" {
		t.Fatalf("dirty buffer must not block the jump: %q", e.path)
	}
	if len(e.docs) != 2 || e.docs[0].path != "/host/BAD/main.go" || !e.docs[0].dirty {
		t.Fatalf("the dirty buffer must stay parked: %+v", e.docs)
	}
}


func TestJumpDiagStaleTargetRefuses(t *testing.T) {
	errs := "/host/BAD/.BUILD/ERRORS.TXT"
	fakeDiagFiles(t,
		map[string]bool{errs: true},
		map[string][]byte{errs: []byte("/host/BAD/helper/bad.go:2:1: boom\n")},
		map[string]int64{errs: 200, "/host/BAD/main.go": 50, "/host/BAD/helper/bad.go": 300})
	e := usEditor("package main\n")
	e.path = "/host/BAD/main.go"
	e.loadErrors()
	if len(e.diags) != 1 {
		t.Fatal("list loaded")
	}
	cur := e.cur
	e.jumpDiag(0)
	if e.cur != cur || e.path != "/host/BAD/main.go" {
		t.Fatal("a saved-since target file must refuse the jump")
	}
}

func TestDiagsPanelKeys(t *testing.T) {
	errs := "/host/BAD/.BUILD/ERRORS.TXT"
	fakeDiagFiles(t,
		map[string]bool{errs: true},
		map[string][]byte{errs: []byte("/host/BAD/main.go:1:1: one\n/host/BAD/main.go:2:1: two\n/host/BAD/main.go:3:1: three\n")},
		map[string]int64{errs: 200, "/host/BAD/main.go": 100})
	e := usEditor("aa\nbb\ncc\n")
	e.path = "/host/BAD/main.go"
	e.openErrors()
	if e.mode != modeDiags {
		t.Fatalf("mode = %d want modeDiags", e.mode)
	}
	// Down moves the selection; Return jumps to it and closes the panel.
	e.diagsKey(usDown(usageDown, 0, 0))
	if e.diagsSel != 1 {
		t.Fatalf("sel = %d want 1", e.diagsSel)
	}
	e.diagsKey(usDown(usageDown, 0, 0))
	if e.diagsSel != 2 {
		t.Fatalf("sel = %d want 2", e.diagsSel)
	}
	e.diagsKey(usDown(0, 0, codeReturn))
	if e.mode != modeEdit {
		t.Fatal("Return must close the panel")
	}
	if e.cur != len("aa\nbb\n") {
		t.Fatalf("jump landed cur=%d, want line 3 start", e.cur)
	}
}

func TestFileMtimeHost(t *testing.T) {
	// The host seam is the real mtime, and the stale rule works against
	// real temp files end to end.
	dir := t.TempDir()
	errs := filepath.Join(dir, "ERRORS.TXT")
	src := filepath.Join(dir, "main.go")
	if err := os.WriteFile(errs, []byte("x:1:1: m\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(src, []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(errs, old, old); err != nil {
		t.Fatal(err)
	}
	eStat, ok1 := fileMtime(errs)
	fStat, ok2 := fileMtime(src)
	if !ok1 || !ok2 || fStat <= eStat {
		t.Fatal("host mtime seam must report real stamps")
	}
}

func TestErrMarkerShapes(t *testing.T) {
	if markerErrs != "goedit: errors " {
		t.Fatalf("markerErrs = %q", markerErrs)
	}
	// Every refusal shape the gate greps rides the one prefix. M166a: the
	// dirty refusal is gone — `full` names a ring with no room.
	for _, s := range []string{"none", "stale", "full", "no-position", "end"} {
		if strings.Contains(markerErrs, s) {
			t.Fatalf("refusal %q must not sit inside the prefix", s)
		}
	}
}
