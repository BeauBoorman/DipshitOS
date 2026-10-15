package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeSrc drops a source file into the test workspace.
func writeSrc(t *testing.T, dir, name, body string) {
	t.Helper()
	full := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func codes(diags []Diag) []string {
	var out []string
	for _, d := range diags {
		out = append(out, d.Code)
	}
	return out
}

func hasCode(diags []Diag, code string) bool {
	for _, d := range diags {
		if d.Code == code {
			return true
		}
	}
	return false
}

// The card's fixture shape: package main + a local package + std imports
// resolved from the staged-archive manifest.
func TestImportGraphResolvesLocalThenArchive(t *testing.T) {
	dir := t.TempDir()
	writeSrc(t, dir, "main.go", `package main
import ("helper"; "fmt")
func main() { fmt.Println(helper.V) }
`)
	writeSrc(t, dir, "helper/h.go", `package helper
import "strings"
var V = strings.ToUpper("v")
`)
	archives := map[string]string{"fmt": "/host/GPKG_FMT.a", "strings": "/host/GPKG_STRINGS.a"}
	g := ImportGraph(dir, archives, nil)
	if len(g.Diags) != 0 {
		t.Fatalf("unexpected diags: %v", g.Diags)
	}
	if g.Main == nil || g.Main.Name != "main" {
		t.Fatalf("main pkg: %+v", g.Main)
	}
	if g.Packages["helper"] == nil || !g.Packages["helper"].Local {
		t.Fatal("helper must resolve local")
	}
	if g.Packages["fmt"] == nil || g.Packages["fmt"].Local {
		t.Fatal("fmt must resolve to a staged archive")
	}
	if g.Packages["fmt"].Archive != "/host/GPKG_FMT.a" {
		t.Fatalf("fmt archive = %q", g.Packages["fmt"].Archive)
	}
	// helper precedes main in build order; archives are never in Order.
	var order []string
	for _, p := range g.Order {
		order = append(order, p.Path)
	}
	if strings.Join(order, ",") != "helper,main" {
		t.Fatalf("order = %v", order)
	}
}

// local dir shadows the staged archive (resolution order, card-pinned).
func TestLocalShadowsArchive(t *testing.T) {
	dir := t.TempDir()
	writeSrc(t, dir, "main.go", `package main
import "helper"
var _ = helper.V
func main() {}
`)
	writeSrc(t, dir, "helper/h.go", `package helper
var V = 1
`)
	g := ImportGraph(dir, map[string]string{"helper": "/host/GPKG_HELPER.a"}, nil)
	if len(g.Diags) != 0 {
		t.Fatalf("unexpected diags: %v", g.Diags)
	}
	if !g.Packages["helper"].Local {
		t.Fatal("local dir must win over the staged archive")
	}
}

func TestNoPackageRefusedByName(t *testing.T) {
	dir := t.TempDir()
	writeSrc(t, dir, "main.go", `package main
import "missing"
func main() {}
`)
	g := ImportGraph(dir, nil, nil)
	if !hasCode(g.Diags, "no_package") {
		t.Fatalf("want no_package, got %v", g.Diags)
	}
	d := g.Diags[0]
	if d.Line != 2 || d.Msg == "" || !strings.Contains(d.Msg, "missing") {
		t.Fatalf("diag must carry the import position and name: %+v", d)
	}
	if !strings.HasSuffix(d.File, "main.go") {
		t.Fatalf("diag file = %q", d.File)
	}
}

func TestImportCycleNamed(t *testing.T) {
	dir := t.TempDir()
	writeSrc(t, dir, "main.go", `package main
import "a"
func main() { a.F() }
`)
	writeSrc(t, dir, "a/a.go", `package a
import "b"
func F() { b.G() }
`)
	writeSrc(t, dir, "b/b.go", `package b
import "a"
func G() {}
`)
	g := ImportGraph(dir, nil, nil)
	if !hasCode(g.Diags, "import_cycle") {
		t.Fatalf("want import_cycle, got %v", g.Diags)
	}
	for _, d := range g.Diags {
		if d.Code == "import_cycle" &&
			!(strings.Contains(d.Msg, "a -> b -> a") || strings.Contains(d.Msg, "b -> a -> b")) {
			t.Fatalf("cycle must name its members: %q", d.Msg)
		}
	}
}

func TestUnsafeNeedsNoArchive(t *testing.T) {
	dir := t.TempDir()
	writeSrc(t, dir, "main.go", `package main
import "unsafe"
var _ = unsafe.Sizeof(0)
func main() {}
`)
	g := ImportGraph(dir, nil, nil)
	if len(g.Diags) != 0 {
		t.Fatalf("unsafe is intrinsic, got %v", g.Diags)
	}
	if _, ok := g.Packages["unsafe"]; ok {
		t.Fatal("unsafe must not become a resolved package")
	}
}

func TestCgoRefused(t *testing.T) {
	dir := t.TempDir()
	writeSrc(t, dir, "main.go", `package main
import "C"
func main() {}
`)
	g := ImportGraph(dir, nil, nil)
	if !hasCode(g.Diags, "import_cgo") {
		t.Fatalf("want import_cgo, got %v", g.Diags)
	}
}

func TestNonMainDirRefused(t *testing.T) {
	dir := t.TempDir()
	writeSrc(t, dir, "lib.go", `package lib
func F() {}
`)
	g := ImportGraph(dir, nil, nil)
	if !hasCode(g.Diags, "no_main") {
		t.Fatalf("want no_main, got %v", g.Diags)
	}
}

// _test.go files and //go:build-excluded files are not build inputs.
func TestFileSelection(t *testing.T) {
	dir := t.TempDir()
	writeSrc(t, dir, "main.go", "package main\nfunc main() {}\n")
	writeSrc(t, dir, "main_test.go", "package main\nimport \"testing\"\n")
	writeSrc(t, dir, "other.go", "//go:build linux\npackage main\n")
	writeSrc(t, dir, "guest.go", "//go:build virelai\npackage main\nvar guestOnly = 1\n")
	g := ImportGraph(dir, nil, nil)
	if len(g.Diags) != 0 {
		t.Fatalf("unexpected diags: %v", g.Diags)
	}
	got := map[string]bool{}
	for _, f := range g.Main.Files {
		got[filepath.Base(f)] = true
	}
	if !got["main.go"] || !got["guest.go"] || got["main_test.go"] || got["other.go"] {
		t.Fatalf("files = %v", got)
	}
}

func TestSyntaxErrorCarriesPosition(t *testing.T) {
	dir := t.TempDir()
	writeSrc(t, dir, "main.go", "package main\nfunc main( {}\n")
	g := ImportGraph(dir, nil, nil)
	if !hasCode(g.Diags, "syntax") {
		t.Fatalf("want syntax, got %v", g.Diags)
	}
	for _, d := range g.Diags {
		if d.Code == "syntax" && (d.Line != 2 || d.File == "") {
			t.Fatalf("syntax diag must carry file:line: %+v", d)
		}
	}
}
