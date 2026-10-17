package main

// M112b (#2414): the testmain generator. `go test` is cmd/go synthesizing a
// main package; the in-guest toolchain has no cmd/go, so the driver does the
// synthesis itself: scan the package dir's *_test.go files, split them into
// the internal test package (package p) and the external test package
// (package p_test), collect Test* functions and TestMain, and emit a
// testmain source that drives them through testing.MainStart.
//
// The generated program carries its own testDeps implementation instead of
// importing testing/internal/testdeps: that package is std-internal (the
// M107b table denies every internal/* path to guest code) and its closure
// drags in os/exec, os/signal and internal/fuzz — none of which belong in
// a guest test run. testing.testDeps is an unexported interface, but its
// methods are exported and corpusEntry is an alias to an anonymous struct,
// so an identical structural spelling satisfies it. The corpus-entry
// spelling is copied verbatim from src/testing/fuzz.go; if upstream changes
// the shape the generated program fails to compile — loudly, not silently.
//
// Flag plumbing is the stock one: testing.MainStart -> Init registers the
// -test.* flags and M.Run parses os.Args, so the driver passes "-test.v"
// like a normal go test invocation.

import (
	"go/ast"
	goparser "go/parser"
	"go/token"
	"sort"
	"strconv"
	"strings"
)

// testSet is one package dir's collected test surface.
type testSet struct {
	internal []string   // *_test.go files declaring `package p`
	external []string   // *_test.go files declaring `package p_test`
	tests    []testFunc // Test* functions, in file order
	testMain *testFunc  // func TestMain(m *testing.M), at most one
	diags    []Diag
}

// testFunc names one collected function and which package clause it came
// from — "test" for the internal package, "xtest" for the external one
// (the same aliases the generated main binds).
type testFunc struct {
	pkg  string // "test" | "xtest"
	name string
}

// scanTestFiles parses dir's buildable *_test.go files and collects the
// test surface. Package-clause mismatches against the under-test package
// name land as named diags rather than silently mis-routing a function.
func scanTestFiles(dir, pkgName string) testSet {
	ents, err := dirEntries(dir)
	if err != nil {
		return testSet{diags: []Diag{{Code: "io", File: dir, Msg: err.Error()}}}
	}
	var files []string
	for _, e := range ents {
		if !e.isDir && strings.HasSuffix(e.name, "_test.go") &&
			!strings.HasPrefix(e.name, ".") && !strings.HasPrefix(e.name, "_") {
			files = append(files, e.name)
		}
	}
	sort.Strings(files)
	out := testSet{}
	fset := token.NewFileSet()
	for _, f := range files {
		path := joinPath(dir, f)
		src, err := readFile(path)
		if err != nil {
			out.diags = append(out.diags, Diag{Code: "io", File: path, Msg: err.Error()})
			continue
		}
		ok, d := buildable(path, src)
		if !ok {
			if d != nil {
				out.diags = append(out.diags, *d)
			}
			continue // excluded by //go:build on this target — not an error
		}
		pf, err := goparser.ParseFile(fset, path, src, goparser.SkipObjectResolution)
		if err != nil {
			out.diags = append(out.diags, syntaxDiags(err)...)
			continue
		}
		kind := ""
		switch pf.Name.Name {
		case pkgName:
			kind = "test"
			out.internal = append(out.internal, f)
		case pkgName + "_test":
			kind = "xtest"
			out.external = append(out.external, f)
		default:
			out.diags = append(out.diags, Diag{Code: "bad_package", File: path,
				Line: fset.Position(pf.Name.Pos()).Line,
				Col:  fset.Position(pf.Name.Pos()).Column,
				Msg: "test file declares package " + strconv.Quote(pf.Name.Name) +
					", want " + pkgName + " or " + pkgName + "_test"})
			continue
		}
		for _, decl := range pf.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Recv != nil {
				continue
			}
			name := fn.Name.Name
			switch {
			case name == "TestMain":
				if !isTestFunc(fn, "M") {
					continue // some other TestMain shape — not the harness entry
				}
				if out.testMain != nil {
					out.diags = append(out.diags, Diag{Code: "dup_testmain", File: path,
						Msg: "multiple definitions of TestMain"})
					continue
				}
				tf := testFunc{pkg: kind, name: name}
				out.testMain = &tf
			case isTestName(name, "Test") && isTestFunc(fn, "T"):
				out.tests = append(out.tests, testFunc{pkg: kind, name: name})
			}
		}
	}
	return out
}

// isTestName mirrors go's rule: a Test* name is a test when the rune after
// the prefix is not lower-case ("TestFoo" yes, "Testify" no).
func isTestName(name, prefix string) bool {
	if !strings.HasPrefix(name, prefix) {
		return false
	}
	if len(name) == len(prefix) {
		return true
	}
	r := rune(name[len(prefix)])
	return !(r >= 'a' && r <= 'z')
}

// isTestFunc checks the one-argument *testing.X signature shape — the same
// structural check cmd/go applies (the import alias is unknown, so the
// parameter type is *M / *pkg.M).
func isTestFunc(fn *ast.FuncDecl, arg string) bool {
	if fn.Type.Results != nil && len(fn.Type.Results.List) > 0 ||
		fn.Type.Params == nil || len(fn.Type.Params.List) != 1 ||
		len(fn.Type.Params.List[0].Names) > 1 {
		return false
	}
	ptr, ok := fn.Type.Params.List[0].Type.(*ast.StarExpr)
	if !ok {
		return false
	}
	if id, ok := ptr.X.(*ast.Ident); ok && id.Name == arg {
		return true
	}
	if sel, ok := ptr.X.(*ast.SelectorExpr); ok && sel.Sel.Name == arg {
		return true
	}
	return false
}

// genTestmain renders the main package for one test build. pkgPath is the
// import path the test variant archive is compiled under; pkgDir is the
// share directory the binary chdirs into (testdata-relative reads resolve
// against the port's userspace cwd exactly like `go test` running in the
// package dir).
func genTestmain(pkgPath, pkgDir string, ts testSet) []byte {
	var b strings.Builder
	b.WriteString(`// Code generated by GOBUILD test. DO NOT EDIT.

package main

import (
	"errors"
	"io"
	"os"
	"reflect"
	"regexp"
	"testing"
	"time"
`)
	internalRefs := false
	externalRefs := false
	for _, tf := range ts.tests {
		if tf.pkg == "test" {
			internalRefs = true
		} else {
			externalRefs = true
		}
	}
	if ts.testMain != nil {
		if ts.testMain.pkg == "test" {
			internalRefs = true
		} else {
			externalRefs = true
		}
	}
	if internalRefs {
		b.WriteString("\n\ttest " + strconv.Quote(pkgPath))
	}
	if externalRefs {
		b.WriteString("\n\txtest " + strconv.Quote(pkgPath+"_test"))
	}
	b.WriteString("\n)\n")

	// corpusEntry is an alias to the anonymous struct testing.corpusEntry
	// aliases — the only spelling an external package can give the
	// interface's fuzz methods. The field list is verbatim from
	// src/testing/fuzz.go.
	b.WriteString(`
type corpusEntry = struct {
	Parent     string
	Path       string
	Data       []byte
	Values     []any
	Generation int
	IsSeed     bool
}

var errUnsup = errors.New("unsupported by the in-guest test driver")

// testDeps implements testing.testDeps with the subset a guest run needs:
// real pattern matching (regexp is staged), honest "unsupported" answers
// for the OS-coupled surfaces (profiles, testlog, fuzz coordination,
// coverage) that no pinned package exercises.
type testDeps struct{}

func (testDeps) ImportPath() string                         { return "` + pkgPath + `" }
func (testDeps) ModulePath() string                         { return "" }
func (testDeps) MatchString(pat, str string) (bool, error)  { return regexp.MatchString(pat, str) }
func (testDeps) SetPanicOnExit0(bool)                       {}
func (testDeps) StartCPUProfile(io.Writer) error            { return errUnsup }
func (testDeps) StopCPUProfile()                            {}
func (testDeps) StartTestLog(io.Writer)                     {}
func (testDeps) StopTestLog() error                         { return errUnsup }
func (testDeps) WriteProfileTo(string, io.Writer, int) error { return errUnsup }
func (testDeps) CoordinateFuzzing(time.Duration, int64, time.Duration, int64, int,
	[]corpusEntry, []reflect.Type, string, string) error {
	return errUnsup
}
func (testDeps) RunFuzzWorker(func(corpusEntry) error) error { return errUnsup }
func (testDeps) ReadCorpus(string, []reflect.Type) ([]corpusEntry, error) {
	return nil, errUnsup
}
func (testDeps) CheckCorpus([]any, []reflect.Type) error { return errUnsup }
func (testDeps) ResetCoverage()                            {}
func (testDeps) SnapshotCoverage()                         {}
func (testDeps) InitRuntimeCoverage() (string, func(string, string) (string, error), func() float64) {
	return "", nil, nil
}

var tests = []testing.InternalTest{
`)
	for _, tf := range ts.tests {
		b.WriteString("\t{" + strconv.Quote(tf.name) + ", " + tf.pkg + "." + tf.name + "},\n")
	}
	b.WriteString(`}

func main() {
	// testdata/ and t.TempDir() resolve like a host go-test run: cwd is
	// the package dir and TMPDIR points at a writable share dir.
	_ = os.Setenv("TMPDIR", "/host/TESTTMP")
	_ = os.MkdirAll("/host/TESTTMP", 0o755)
	_ = os.Chdir("` + pkgDir + `")
	m := testing.MainStart(testDeps{}, tests, nil, nil, nil)
`)
	if ts.testMain != nil {
		b.WriteString("\t" + ts.testMain.pkg + "." + ts.testMain.name + "(m)\n")
		b.WriteString("\tos.Exit(int(reflect.ValueOf(m).Elem().FieldByName(\"exitCode\").Int()))\n")
	} else {
		b.WriteString("\tos.Exit(m.Run())\n")
	}
	b.WriteString("}\n")
	return []byte(b.String())
}
