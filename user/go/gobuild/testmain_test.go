package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The generated testmain's full import surface — every packagefile it may
// name, matching the driver's archive resolution.
const testManifestBody = `packagefile testing=/host/GPKG_TESTING.a
packagefile regexp=/host/GPKG_REGEXP.a
packagefile os=/host/GPKG_OS.a
packagefile io=/host/GPKG_IO.a
packagefile errors=/host/GPKG_ERRORS.a
packagefile reflect=/host/GPKG_REFLECT.a
packagefile time=/host/GPKG_TIME.a
packagefile runtime=/host/GPKG_RUNTIME.a
`

func writeTestSrc(t *testing.T, dir, rel, body string) {
	t.Helper()
	full := filepath.Join(dir, rel)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// The scanner splits internal and external test files, collects Test* and
// TestMain, and ignores build-tagged-out files — the exact surface the
// generator renders.
func TestScanTestFiles(t *testing.T) {
	dir := t.TempDir()
	writeTestSrc(t, dir, "p.go", "package p\n")
	writeTestSrc(t, dir, "p_test.go", `package p
import "testing"
func TestA(t *testing.T) {}
func TestB(t *testing.T) {}
func helper() {}
func TestMain(m *testing.M) {}
`)
	writeTestSrc(t, dir, "x_test.go", `package p_test
import "testing"
func TestExt(t *testing.T) {}
`)
	writeTestSrc(t, dir, "skipped_linux_test.go", `//go:build linux
package p
import "testing"
func TestNever(t *testing.T) {}
`)
	ts := scanTestFiles(dir, "p")
	if len(ts.diags) != 0 {
		t.Fatalf("diags = %v", ts.diags)
	}
	if len(ts.internal) != 1 || ts.internal[0] != "p_test.go" {
		t.Fatalf("internal = %v", ts.internal)
	}
	if len(ts.external) != 1 || ts.external[0] != "x_test.go" {
		t.Fatalf("external = %v", ts.external)
	}
	var names []string
	for _, tf := range ts.tests {
		names = append(names, tf.pkg+"/"+tf.name)
	}
	want := []string{"test/TestA", "test/TestB", "xtest/TestExt"}
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("tests = %v, want %v", names, want)
	}
	if ts.testMain == nil || ts.testMain.pkg != "test" || ts.testMain.name != "TestMain" {
		t.Fatalf("testMain = %+v", ts.testMain)
	}
}

// A foreign package clause is a named diagnostic, not a silent misroute.
func TestScanTestFilesBadPackage(t *testing.T) {
	dir := t.TempDir()
	writeTestSrc(t, dir, "p.go", "package p\n")
	writeTestSrc(t, dir, "odd_test.go", `package other
import "testing"
func TestX(t *testing.T) {}
`)
	ts := scanTestFiles(dir, "p")
	if len(ts.diags) != 1 || ts.diags[0].Code != "bad_package" {
		t.Fatalf("diags = %v", ts.diags)
	}
}

// The generated main must carry everything MainStart needs: the deps impl
// (no testing/internal/testdeps import — that package is denied in-guest),
// per-package test references, and the TestMain + reflect exit path.
func TestGenTestmain(t *testing.T) {
	src := string(genTestmain("virelai/clockfmt", "/host/SRC/virelai/clockfmt", testSet{
		internal: []string{"clockfmt_test.go"},
		external: []string{"x_test.go"},
		tests: []testFunc{{pkg: "test", name: "TestRender"},
			{pkg: "xtest", name: "TestExt"}},
		testMain: &testFunc{pkg: "xtest", name: "TestMain"},
	}))
	for _, want := range []string{
		"package main",
		`test "virelai/clockfmt"`,
		`xtest "virelai/clockfmt_test"`,
		`{"TestRender", test.TestRender}`,
		`{"TestExt", xtest.TestExt}`,
		"testing.MainStart(testDeps{}, tests, nil, nil, nil)",
		"xtest.TestMain(m)",
		"FieldByName(\"exitCode\")",
		"regexp.MatchString",
		"corpusEntry",
		"func (testDeps) CoordinateFuzzing",
		"func (testDeps) InitRuntimeCoverage",
		`os.Chdir("/host/SRC/virelai/clockfmt")`,
		`os.Setenv("TMPDIR", "/host/TESTTMP")`,
	} {
		if !strings.Contains(src, want) {
			t.Fatalf("generated main missing %q:\n%s", want, src)
		}
	}
	if strings.Contains(src, "internal/testdeps") {
		t.Fatalf("generated main must not import testing/internal/testdeps:\n%s", src)
	}
	// Without TestMain the exit is m.Run() directly, and no reflect path.
	src = string(genTestmain("virelai/clockfmt", "/host/SRC/virelai/clockfmt", testSet{
		internal: []string{"a_test.go"},
		tests:    []testFunc{{pkg: "test", name: "TestRender"}},
	}))
	if !strings.Contains(src, "os.Exit(m.Run())") ||
		strings.Contains(src, "FieldByName") || strings.Contains(src, "xtest") {
		t.Fatalf("no-TestMain generation wrong:\n%s", src)
	}
}

// The generated source must parse under go/parser — the in-guest driver
// feeds it through the same pipeline the fleet compiles with.
func TestGenTestmainParses(t *testing.T) {
	dir := t.TempDir()
	writeTestSrc(t, dir, "TESTMAIN.GO", string(genTestmain("virelai/p", "/host/SRC/virelai/p", testSet{
		internal: []string{"a_test.go"},
		tests:    []testFunc{{pkg: "test", name: "TestA"}},
	})))
	g := &Graph{Dir: dir, Packages: map[string]*Package{}}
	mp := &Package{Path: "main", Dir: dir, Local: true}
	g.loadFiles(mp, []string{"TESTMAIN.GO"})
	if len(g.Diags) != 0 {
		t.Fatalf("generated source diags = %v", g.Diags)
	}
	if mp.Name != "main" {
		t.Fatalf("generated package name = %q", mp.Name)
	}
	var imports []string
	for _, imp := range mp.Imports {
		imports = append(imports, imp.Path)
	}
	for _, want := range []string{"testing", "regexp", "os", "virelai/p"} {
		if !contains(imports, want) {
			t.Fatalf("generated imports = %v, missing %s", imports, want)
		}
	}
}

func TestParseTestList(t *testing.T) {
	rows, d := parseTestList("# comment\n\nvirelai/clockfmt\nvirelai/css\n" +
		"excluded virelai/pdf dep_unsupported: needs compress/zlib\n")
	if d.Code != "" || len(rows) != 3 {
		t.Fatalf("rows = %v, %+v", rows, d)
	}
	if rows[0].pkg != "virelai/clockfmt" || rows[0].excluded {
		t.Fatalf("row0 = %+v", rows[0])
	}
	if !rows[2].excluded || rows[2].pkg != "virelai/pdf" ||
		rows[2].code != "dep_unsupported" ||
		!strings.Contains(rows[2].reason, "compress/zlib") {
		t.Fatalf("excluded row = %+v", rows[2])
	}
	if _, d := parseTestList("bogus row here\n"); d.Code != "bad_testlist" {
		t.Fatalf("malformed row must refuse by name: %+v", d)
	}
	// The committed pin must parse and hold at least one run row.
	committed, err := os.ReadFile("testpkgs.txt")
	if err != nil {
		t.Fatal(err)
	}
	rows, d = parseTestList(string(committed))
	if d.Code != "" {
		t.Fatalf("committed testpkgs.txt must parse: %+v", d)
	}
	var run, ex int
	for _, r := range rows {
		if r.excluded {
			ex++
		} else {
			run++
		}
	}
	if run == 0 || ex == 0 {
		t.Fatalf("testpkgs.txt run=%d excluded=%d — both must be non-empty", run, ex)
	}
}

func TestParseTestOutput(t *testing.T) {
	p, f, s, sawF, sawP := parseTestOutput([]byte(
		"=== RUN   TestA\n--- PASS: TestA (0.00s)\n" +
			"--- SKIP: TestB (0.00s)\nPASS\nok  \tvirelai/p\t0.001s\n"))
	if p != 1 || f != 0 || s != 1 || sawF || sawP {
		t.Fatalf("pass parse = %d %d %d %v %v", p, f, s, sawF, sawP)
	}
	p, f, _, sawF, _ = parseTestOutput([]byte(
		"--- PASS: TestA (0.00s)\n--- FAIL: TestB (0.00s)\nFAIL\n"))
	if p != 1 || f != 1 || !sawF {
		t.Fatalf("fail parse = %d %d %v", p, f, sawF)
	}
	_, _, _, _, sawP = parseTestOutput([]byte("panic: boom\n"))
	if !sawP {
		t.Fatal("panic line must be noticed")
	}
}

func TestTestElfNameBound(t *testing.T) {
	if got := testElfName("virelai/clockfmt", 0); got != "T_VIRELAI_CLOCKFMT.ELF" {
		t.Fatalf("name = %q", got)
	}
	// Receipt suffixes must fit the 31-byte share-name cap.
	long := testElfName("virelai/averyverylongpackagename/and/deeper", 7)
	if len(long)+5 > 31 {
		t.Fatalf("name %q leaves no room for .fail", long)
	}
}

// One leg end to end on host stubs: a package with internal + external
// tests builds a testmain-driven graph, and a passing fake run yields the
// passed verdict plus manifest-shaped fields.
func TestRunTestLegEndToEnd(t *testing.T) {
	root := t.TempDir()
	writeTestSrc(t, root, "virelai/p/p.go", `package p
func V() int { return 1 }
`)
	writeTestSrc(t, root, "virelai/p/p_test.go", `package p
import "testing"
func TestV(t *testing.T) { if V() != 1 { t.Fatal("bad") } }
`)
	writeTestSrc(t, root, "virelai/p/x_test.go", `package p_test
import "testing"
func TestX(t *testing.T) {}
`)
	manifest := filepath.Join(t.TempDir(), "GOIMPORT.CFG")
	if err := os.WriteFile(manifest, []byte(testManifestBody), 0o644); err != nil {
		t.Fatal(err)
	}
	f := &fakeExec{}
	withFakeExec(t, f)
	f.captures = []string{"", "", "", "", // 3 compiles + link
		"=== RUN   TestV\n--- PASS: TestV (0.00s)\n=== RUN   TestX\n--- PASS: TestX (0.00s)\nPASS\nok  \tvirelai/p\t0.001s\n"}
	outdir := t.TempDir()
	rcpt := t.TempDir()
	fc := testCfg{Root: root, OutDir: outdir, ReceiptDir: rcpt,
		Manifest:  filepath.Join(t.TempDir(), "TESTS.MF"),
		Importcfg: []string{manifest}}
	archives, _ := loadArchives(fc.Importcfg)
	table, _ := loadPkgTable(fc.PkgDB)
	oc := runTestLeg(fc, "virelai/p", 0, archives, table)
	if oc.state != "passed" || oc.tests != 2 {
		t.Fatalf("outcome = %+v, diags of last build were the captures", oc)
	}
	// 4 build children (variant, xtest, testmain, link) + 1 test exec.
	if len(f.calls) != 5 {
		t.Fatalf("calls = %v", f.calls)
	}
	// The toolchain children must carry their image names — the test build's
	// Config defaults through the same path Build uses (regression: an empty
	// image made every spawn a guest-side refusal).
	for i, want := range []string{compileImage, compileImage, compileImage, linkImage} {
		if f.calls[i].image != want {
			t.Fatalf("call %d image = %q, want %q", i, f.calls[i].image, want)
		}
	}
	last := f.calls[len(f.calls)-1]
	if last.image != oc.tag || len(last.args) != 1 || last.args[0] != "-test.v" {
		t.Fatalf("test exec call = %+v", last)
	}
	// The generated main must sit in the workdir and parse as package main.
	if _, err := os.Stat(filepath.Join(root, "virelai/p", ".TBUILD", "TESTMAIN.GO")); err != nil {
		t.Fatalf("generated testmain missing: %v", err)
	}
}

// A failed leg names its verdict and leaves the failure evidence on the
// outcome — the manifest asserts consume it.
func TestRunTestLegFailure(t *testing.T) {
	root := t.TempDir()
	writeTestSrc(t, root, "virelai/p/p.go", "package p\n")
	writeTestSrc(t, root, "virelai/p/p_test.go", `package p
import "testing"
func TestV(t *testing.T) { t.Fatal("bad") }
`)
	manifest := filepath.Join(t.TempDir(), "GOIMPORT.CFG")
	if err := os.WriteFile(manifest, []byte(testManifestBody), 0o644); err != nil {
		t.Fatal(err)
	}
	f := &fakeExec{}
	withFakeExec(t, f)
	f.captures = []string{"", "", "",
		"--- FAIL: TestV (0.00s)\nFAIL\nFAIL\tvirelai/p\t0.001s\n"}
	fc := testCfg{Root: root, OutDir: t.TempDir(), ReceiptDir: t.TempDir(),
		Manifest:  filepath.Join(t.TempDir(), "TESTS.MF"),
		Importcfg: []string{manifest}}
	archives, _ := loadArchives(fc.Importcfg)
	table, _ := loadPkgTable(fc.PkgDB)
	oc := runTestLeg(fc, "virelai/p", 0, archives, table)
	if oc.state != "failed" || oc.code != "test_failed" || oc.failed != 1 {
		t.Fatalf("outcome = %+v", oc)
	}
}

// A package whose only buildable test file carries a refusal-worthy surface
// (e.g. no Test funcs at all) is refused by name, never silently skipped.
func TestRunTestLegNoTests(t *testing.T) {
	root := t.TempDir()
	writeTestSrc(t, root, "virelai/p/p.go", "package p\n")
	writeTestSrc(t, root, "virelai/p/p_test.go", `package p
func helper() {}
`)
	fc := testCfg{Root: root, OutDir: t.TempDir(), ReceiptDir: t.TempDir()}
	oc := runTestLeg(fc, "virelai/p", 0, nil, nil)
	if oc.state != "refused" || oc.code != "no_tests" {
		t.Fatalf("outcome = %+v", oc)
	}
}
