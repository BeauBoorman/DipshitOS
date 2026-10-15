package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeExec records each spawn (image, args, capture path) and plays a canned
// status + captured text per call index. It stands in for the guest's
// stream-bound exec — the graph/importcfg/argv/diagnostic logic under test
// never depends on a real child.
type fakeExec struct {
	calls    []fakeCall
	statuses []int64
	captures []string
	spawnErr error
}

type fakeCall struct {
	image   string
	args    []string
	capture string
}

func (f *fakeExec) run(image string, args []string, capturePath string) (int64, int64, []byte, error) {
	if f.spawnErr != nil {
		return -1, 0, nil, f.spawnErr
	}
	i := len(f.calls)
	f.calls = append(f.calls, fakeCall{image, append([]string{}, args...), capturePath})
	st := int64(0)
	if i < len(f.statuses) {
		st = f.statuses[i]
	}
	var cap []byte
	if i < len(f.captures) {
		cap = []byte(f.captures[i])
	}
	return st, 42, cap, nil
}

// withFakeExec installs f for the test.
func withFakeExec(t *testing.T, f *fakeExec) {
	t.Helper()
	prev := execAndWait
	execAndWait = f.run
	t.Cleanup(func() { execAndWait = prev })
}

// stageFixture writes the card's multi-package fixture: main + one local
// package + std imports, and returns the manifest covering the std side.
func stageFixture(t *testing.T) (dir string, manifest string) {
	t.Helper()
	dir = t.TempDir()
	writeSrc(t, dir, "main.go", `package main
import ("helper"; "fmt")
func main() { fmt.Println(helper.V) }
`)
	writeSrc(t, dir, "helper/h.go", `package helper
import "strings"
var V = strings.ToUpper("v")
`)
	manifest = filepath.Join(t.TempDir(), "GOIMPORT.CFG")
	body := "packagefile fmt=/host/GPKG_FMT.a\n" +
		"packagefile strings=/host/GPKG_STRINGS.a\n" +
		"packagefile runtime=/host/GPKG_RUNTIME.a\n"
	if err := os.WriteFile(manifest, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir, manifest
}

func TestBuildDrivesCompilePerPackageThenLink(t *testing.T) {
	dir, manifest := stageFixture(t)
	f := &fakeExec{}
	withFakeExec(t, f)
	res := Build(Config{Dir: dir, Importcfg: []string{manifest}})
	if res.ELF == "" {
		t.Fatalf("build failed: %v", res.Diags)
	}
	// helper then main, then one link — three children.
	if len(f.calls) != 3 {
		t.Fatalf("calls = %v", f.calls)
	}
	if f.calls[0].image != compileImage || f.calls[1].image != compileImage ||
		f.calls[2].image != linkImage {
		t.Fatalf("images = %v", []string{f.calls[0].image, f.calls[1].image, f.calls[2].image})
	}
	// Compile argv shape: -o obj -p path -importcfg cfg @rsp, ≤ 8 args.
	compile := f.calls[0].args
	if compile[0] != "-o" || compile[2] != "-p" || compile[3] != "helper" ||
		compile[4] != "-importcfg" || !strings.HasPrefix(compile[6], "@") {
		t.Fatalf("compile argv = %v", compile)
	}
	// The helper compile's importcfg names strings' staged archive.
	cfgBytes, err := os.ReadFile(compile[5])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(cfgBytes), "packagefile strings=/host/GPKG_STRINGS.a") {
		t.Fatalf("helper importcfg = %s", cfgBytes)
	}
	// The main compile's importcfg names the built helper archive.
	mainCfg, _ := os.ReadFile(f.calls[1].args[5])
	if !strings.Contains(string(mainCfg), "packagefile helper=") {
		t.Fatalf("main importcfg = %s", mainCfg)
	}
	// The link's importcfg covers the closure: staged std + local helper.
	linkCfg, _ := os.ReadFile(f.calls[2].args[1])
	for _, want := range []string{"packagefile fmt=", "packagefile runtime=",
		"packagefile helper="} {
		if !strings.Contains(string(linkCfg), want) {
			t.Fatalf("link importcfg missing %q:\n%s", want, linkCfg)
		}
	}
	if strings.Contains(string(linkCfg), "packagefile main=") {
		t.Fatal("main is the positional object, not a packagefile")
	}
	// ERRORS.TXT exists and is empty on a clean build.
	eb, err := os.ReadFile(filepath.Join(dir, ".BUILD", "ERRORS.TXT"))
	if err != nil || len(eb) != 0 {
		t.Fatalf("ERRORS.TXT = %q, err=%v", eb, err)
	}
}

func TestBuildSurfacesCompilerDiags(t *testing.T) {
	dir, manifest := stageFixture(t)
	f := &fakeExec{
		statuses: []int64{1},
		captures: []string{"/host/WSP/helper/h.go:2:8: could not import strings (no export data)\n"},
	}
	withFakeExec(t, f)
	res := Build(Config{Dir: dir, Importcfg: []string{manifest}})
	if res.ELF != "" {
		t.Fatal("failed compile must not produce an ELF")
	}
	// One compile child ran; the link was never attempted.
	if len(f.calls) != 1 {
		t.Fatalf("calls = %d", len(f.calls))
	}
	var found *Diag
	for i := range res.Diags {
		if res.Diags[i].Line == 2 && strings.Contains(res.Diags[i].File, "h.go") {
			found = &res.Diags[i]
		}
	}
	if found == nil {
		t.Fatalf("compiler diag must carry file:line: %v", res.Diags)
	}
	if !hasCode(res.Diags, "child_status") {
		t.Fatalf("tombstone diag missing: %v", res.Diags)
	}
	// ERRORS.TXT carries the parsed line for M107c.
	eb, _ := os.ReadFile(filepath.Join(dir, ".BUILD", "ERRORS.TXT"))
	if !strings.Contains(string(eb), "h.go:2:8:") {
		t.Fatalf("ERRORS.TXT = %q", eb)
	}
}

func TestBuildNoPackageStopsBeforeSpawn(t *testing.T) {
	dir := t.TempDir()
	writeSrc(t, dir, "main.go", "package main\nimport \"missing\"\nfunc main() {}\n")
	f := &fakeExec{}
	withFakeExec(t, f)
	res := Build(Config{Dir: dir})
	if res.ELF != "" || !hasCode(res.Diags, "no_package") {
		t.Fatalf("res = %+v", res)
	}
	if len(f.calls) != 0 {
		t.Fatal("unresolvable graph must not spawn")
	}
}

func TestArgvBudgetRefusedByName(t *testing.T) {
	long := "/" + strings.Repeat("x", 300)
	d, bad := checkArgv("IMG", []string{"-o", long})
	if !bad || d.Code != "argv_too_long" {
		t.Fatalf("want argv_too_long, got %+v", d)
	}
	d, bad = checkArgv("IMG", make([]string, 9))
	if !bad || d.Code != "argv_too_long" {
		t.Fatalf("want argv_too_long on count, got %+v", d)
	}
	if _, bad := checkArgv("IMG", []string{"-o", "/host/x.a"}); bad {
		t.Fatal("a normal argv is inside the budget")
	}
}

func TestParseDiagsKeepsCompilerPositions(t *testing.T) {
	text := "helper/h.go:2:8: could not import strings\n" +
		"helper/h.go:10:2: declared and not used: x\n" +
		"panic: something else\n"
	ds := parseDiags([]byte(text), "compile")
	if len(ds) != 3 {
		t.Fatalf("diags = %v", ds)
	}
	if ds[0].File != "helper/h.go" || ds[0].Line != 2 || ds[0].Col != 8 {
		t.Fatalf("d0 = %+v", ds[0])
	}
	// A colon inside the message must not break the file:line:col parse.
	if ds[1].File != "helper/h.go" || ds[1].Line != 10 || ds[1].Col != 2 ||
		ds[1].Msg != "declared and not used: x" {
		t.Fatalf("d1 = %+v", ds[1])
	}
	if ds[2].Line != 0 || ds[2].Code != "compile" {
		t.Fatalf("non-diagnostic line kept as positionless diag: %+v", ds[2])
	}
}

func TestImportcfgParse(t *testing.T) {
	m, d := parseImportcfg("# comment\npackagefile fmt=/host/GPKG_FMT.a\n\npackagefile strings=/host/GPKG_STRINGS.a\n")
	if d.Code != "" || m["fmt"] != "/host/GPKG_FMT.a" || m["strings"] != "/host/GPKG_STRINGS.a" {
		t.Fatalf("parse = %v, %v", m, d)
	}
	_, d = parseImportcfg("garbage line\n")
	if d.Code != "bad_importcfg" || d.Line != 1 {
		t.Fatalf("malformed manifest must refuse by name: %+v", d)
	}
}

func TestSpawnErrorIsNotAStatus(t *testing.T) {
	dir, manifest := stageFixture(t)
	f := &fakeExec{spawnErr: errors.New("exec refused")}
	withFakeExec(t, f)
	res := Build(Config{Dir: dir, Importcfg: []string{manifest}})
	if res.ELF != "" || !hasCode(res.Diags, "spawn") {
		t.Fatalf("res = %+v", res)
	}
}

func TestNameMangleCollisionRefused(t *testing.T) {
	dir := t.TempDir()
	writeSrc(t, dir, "main.go", "package main\nimport (\"a/b\"; \"a_b\")\nfunc main() {}\n")
	writeSrc(t, dir, "a/b/x.go", "package b\n")
	writeSrc(t, dir, "a_b/x.go", "package a_b\n")
	g := ImportGraph(dir, nil, nil)
	diags := checkMangles(g)
	if !hasCode(diags, "name_collision") {
		t.Fatalf("want name_collision, got %v", diags)
	}
}
