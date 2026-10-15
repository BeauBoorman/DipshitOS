package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writePkgTable drops a GOPKGS.TXT-shaped table for the test.
func writePkgTable(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "GOPKGS.TXT")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestParsePkgTable(t *testing.T) {
	m, d := parsePkgTable("# comment\nstaged fmt\ndenied crypto/x509 no cert roots\nunstaged flag\n")
	if d.Code != "" {
		t.Fatalf("parse diag: %+v", d)
	}
	if !m["crypto/x509"].denied || m["crypto/x509"].reason != "no cert roots" {
		t.Fatalf("denied row: %+v", m["crypto/x509"])
	}
	if !m["fmt"].known || m["fmt"].denied || !m["flag"].known {
		t.Fatalf("staged/unstaged rows: %+v %+v", m["fmt"], m["flag"])
	}
	_, d = parsePkgTable("frozbnitzed x\n")
	if d.Code != "bad_pkgdb" || d.Line != 1 {
		t.Fatalf("malformed table must refuse by name: %+v", d)
	}
}

// A denied package refuses by name — dep_unsupported carrying the table's
// reason — and never reaches a toolchain child.
func TestDeniedPackageRefusedByName(t *testing.T) {
	dir := t.TempDir()
	writeSrc(t, dir, "main.go", `package main
import "crypto/x509"
var _ = x509.ErrUnsupportedAlgorithm
func main() {}
`)
	tbl := writePkgTable(t, "denied crypto/x509 no system cert-root store on GOOS=virelai\n")
	f := &fakeExec{}
	withFakeExec(t, f)
	res := Build(Config{Dir: dir, PkgDB: []string{tbl}})
	if res.ELF != "" || !hasCode(res.Diags, "dep_unsupported") {
		t.Fatalf("res = %+v", res)
	}
	for _, d := range res.Diags {
		if d.Code == "dep_unsupported" &&
			(!strings.Contains(d.Msg, "crypto/x509") ||
				!strings.Contains(d.Msg, "cert-root")) {
			t.Fatalf("refusal must name the package and the reason: %q", d.Msg)
		}
	}
	if len(f.calls) != 0 {
		t.Fatal("a refused import must not spawn a toolchain child")
	}
	// The refusal lands in ERRORS.TXT too — that is the file M107c reads.
	eb, _ := os.ReadFile(filepath.Join(dir, ".BUILD", "ERRORS.TXT"))
	if !strings.Contains(string(eb), "crypto/x509") {
		t.Fatalf("ERRORS.TXT = %q", eb)
	}
}

// A package the universe knows but nobody staged refuses dep_unsupported;
// a path in no table at all keeps the M107a no_package refusal. The two are
// different findings: "exists, no archive" vs "not a package anywhere".
func TestUnstagedVsUnknown(t *testing.T) {
	dir := t.TempDir()
	writeSrc(t, dir, "main.go", `package main
import ("flag"; "hepler")
var _ = flag.Bool
var _ = hepler.V
func main() {}
`)
	tbl := writePkgTable(t, "staged fmt\nunstaged flag\n")
	g := ImportGraph(dir, nil, mustTable(t, tbl))
	if !hasCode(g.Diags, "dep_unsupported") || !hasCode(g.Diags, "no_package") {
		t.Fatalf("want dep_unsupported + no_package, got %v", codes(g.Diags))
	}
	for _, d := range g.Diags {
		if d.Code == "dep_unsupported" &&
			!(strings.Contains(d.Msg, `"flag"`) && strings.Contains(d.Msg, "no staged archive")) {
			t.Fatalf("unstaged refusal = %q", d.Msg)
		}
		if d.Code == "no_package" && !strings.Contains(d.Msg, `"hepler"`) {
			t.Fatalf("no_package must name the unknown path: %q", d.Msg)
		}
	}
}

// The denylist beats a staged archive: a table that denies a package the
// manifest ships still refuses — the policy is the source of truth, not the
// artifact (fail closed on a staging/policy skew).
func TestDenyBeatsStagedArchive(t *testing.T) {
	dir := t.TempDir()
	writeSrc(t, dir, "main.go", `package main
import "fmt"
func main() { fmt.Println() }
`)
	manifest := filepath.Join(t.TempDir(), "GOIMPORT.CFG")
	if err := os.WriteFile(manifest,
		[]byte("packagefile fmt=/host/GPKG_FMT.a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	tbl := writePkgTable(t, "denied fmt policy refusal for test\n")
	archives, _ := loadArchives([]string{manifest})
	g := ImportGraph(dir, archives, mustTable(t, tbl))
	if !hasCode(g.Diags, "dep_unsupported") {
		t.Fatalf("denied must beat staged, got %v", g.Diags)
	}
	if g.Packages["fmt"] != nil && g.Packages["fmt"].Archive != "" {
		t.Fatal("a denied package must not resolve to an archive")
	}
}

// A workspace-local -pkgdb restates a row: loadPkgTable merges with
// later-wins, the override the seam exists for.
func TestPkgdbLaterFileWins(t *testing.T) {
	base := writePkgTable(t, "denied net no socket slots\nstaged fmt\n")
	over := writePkgTable(t, "unstaged net\n")
	m, diags := loadPkgTable([]string{base, over})
	if len(diags) != 0 {
		t.Fatalf("diags: %v", diags)
	}
	if m["net"].denied {
		t.Fatal("later table must restate net as unstaged")
	}
	if !m["fmt"].known {
		t.Fatal("base table rows survive the merge")
	}
	// An absent table is not an error — the build just has no oracle.
	m, diags = loadPkgTable([]string{filepath.Join(t.TempDir(), "NONE.TXT")})
	if len(diags) != 0 || len(m) != 0 {
		t.Fatalf("absent table: %v %v", diags, m)
	}
}

// The cap boundary, pinned both sides: maxLocalPackages local packages build
// (N compiles + link under the fake exec), the (N+1)th refuses
// closure_too_large before any child is spawned.
func TestClosureCapBoundary(t *testing.T) {
	mkClosure := func(nDeps int) string {
		dir := t.TempDir()
		var imports strings.Builder
		imports.WriteString("package main\nimport (\n")
		for i := 0; i < nDeps; i++ {
			fmt.Fprintf(&imports, "_ \"p%02d\"\n", i)
			writeSrc(t, dir, fmt.Sprintf("p%02d/p.go", i),
				fmt.Sprintf("package p%02d\nvar V int\n", i))
		}
		imports.WriteString(")\nfunc main() {}\n")
		writeSrc(t, dir, "main.go", imports.String())
		return dir
	}

	// N allowed: main + 63 deps = 64 local packages, the cap exactly.
	f := &fakeExec{}
	withFakeExec(t, f)
	res := Build(Config{Dir: mkClosure(maxLocalPackages - 1)})
	if res.ELF == "" {
		t.Fatalf("boundary build must succeed: %v", res.Diags)
	}
	if len(f.calls) != maxLocalPackages+1 { // 64 compiles + 1 link
		t.Fatalf("children = %d, want %d", len(f.calls), maxLocalPackages+1)
	}

	// N+1 refused: the 65th local package is one too many.
	f2 := &fakeExec{}
	withFakeExec(t, f2)
	res = Build(Config{Dir: mkClosure(maxLocalPackages)})
	if res.ELF != "" || !hasCode(res.Diags, "closure_too_large") {
		t.Fatalf("res = %+v", res)
	}
	for _, d := range res.Diags {
		if d.Code == "closure_too_large" && !strings.Contains(d.Msg, "65 > cap 64") {
			t.Fatalf("cap refusal must carry n>N: %q", d.Msg)
		}
	}
	if len(f2.calls) != 0 {
		t.Fatal("an over-cap closure must not spawn a toolchain child")
	}
}

func mustTable(t *testing.T, path string) map[string]pkgRow {
	t.Helper()
	m, diags := loadPkgTable([]string{path})
	if len(diags) != 0 {
		t.Fatalf("table: %v", diags)
	}
	return m
}
