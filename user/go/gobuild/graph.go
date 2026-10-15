package main

import (
	goparser "go/parser"
	"go/scanner"
	"go/token"
	"sort"
	"strconv"
	"strings"

	"go/build/constraint"
)

// Import is one `import "path"` clause with its position in the importing
// file, so an unresolvable or cyclic import reports file:line.
type Import struct {
	Path string
	File string
	Line int
	Col  int
}

// Package is one resolved package: a LOCAL one the driver compiles from
// Dir+Files, or an ARCHIVE one resolved to a staged .a the children only
// read (its own imports are the staging manifest's problem, never ours —
// cmd/link resolves them transitively through the archives).
type Package struct {
	Path    string   // the literal import path; "main" for the program
	Name    string   // package clause identifier
	Dir     string   // directory the sources live in (local pkgs)
	Files   []string // .go files to compile, in declared order
	Imports []Import // direct imports minus "unsafe"
	Archive string   // staged archive path for !Local packages
	Local   bool
}

// Graph is the resolved import closure of the program rooted at Dir.
// Order lists the LOCAL packages in dependency order (a package always
// follows the local packages it imports) — the compile sequence.
type Graph struct {
	Dir      string
	Main     *Package
	Packages map[string]*Package
	Order    []*Package
	Diags    []Diag
}

// Resolution contract, pinned by the card: an import resolves against the
// program directory first (a local package to compile), then the staged
// archive manifest (a prebuilt .a to link). The staged-std-source tier the
// card names between them is M107b's staging-layout decision; the resolver
// is ordered so that tier slots in here when it exists.
func (g *Graph) resolve(imp Import, archives map[string]string) {
	switch {
	case imp.Path == "unsafe":
		return // the compiler knows it intrinsically; never an archive
	case imp.Path == "C":
		g.Diags = append(g.Diags, Diag{Code: "import_cgo", File: imp.File,
			Line: imp.Line, Col: imp.Col,
			Msg: `import "C": cgo does not exist on GOOS=virelai`})
		return
	}
	if dir := joinPath(g.Dir, imp.Path); validRelPath(imp.Path) && dirHasGoFiles(dir) {
		if g.Packages[imp.Path] == nil {
			g.Packages[imp.Path] = &Package{Path: imp.Path, Dir: dir, Local: true}
		}
		return
	}
	if a, ok := archives[imp.Path]; ok {
		g.Packages[imp.Path] = &Package{Path: imp.Path, Archive: a}
		return
	}
	g.Diags = append(g.Diags, Diag{Code: "no_package", File: imp.File,
		Line: imp.Line, Col: imp.Col,
		Msg: "cannot find package " + strconv.Quote(imp.Path) +
			" (no local dir, no staged archive)"})
}

// ImportGraph scans dir's package (which must be `package main`), walks the
// import graph under it, and returns the closure in build order. Failures
// arrive as Diags — never as a thrown error — so `gobuild graph` and the
// ERRORS.TXT writer see the same structured facts.
func ImportGraph(dir string, archives map[string]string) *Graph {
	g := &Graph{Dir: dir, Packages: map[string]*Package{}}
	main := &Package{Path: "main", Dir: dir, Local: true}
	g.Packages["main"] = main
	g.load(main)
	g.Main = main
	if main.Name != "main" && len(main.Files) > 0 {
		g.Diags = append(g.Diags, Diag{Code: "no_main", File: main.Files[0],
			Msg: "build dir is package " + strconv.Quote(main.Name) + ", not package main"})
	}

	// Resolve + recurse breadth-first: a local import discovered while
	// loading P enqueues P's resolution AFTER its files are parsed, which
	// keeps diagnostics ordered by discovery.
	queue := []*Package{main}
	for len(queue) > 0 {
		p := queue[0]
		queue = queue[1:]
		for _, imp := range p.Imports {
			before := len(g.Packages)
			g.resolve(imp, archives)
			if len(g.Packages) > before {
				if np := g.Packages[imp.Path]; np.Local {
					g.load(np)
					queue = append(queue, np)
				}
			}
		}
	}
	g.sortLocal()
	return g
}

// load fills p's Name/Files/Imports by listing its directory and parsing
// every eligible .go file. Syntax failures land as "syntax" diags carrying
// the compiler-accurate position, the same shape ERRORS.TXT keeps.
func (g *Graph) load(p *Package) {
	files, err := listGoFiles(p.Dir)
	if err != nil {
		g.Diags = append(g.Diags, Diag{Code: "io", File: p.Dir, Msg: err.Error()})
		return
	}
	fset := token.NewFileSet()
	for _, f := range files {
		path := joinPath(p.Dir, f)
		src, err := readFile(path)
		if err != nil {
			g.Diags = append(g.Diags, Diag{Code: "io", File: path, Msg: err.Error()})
			continue
		}
		ok, d := buildable(path, src)
		if !ok {
			if d != nil {
				g.Diags = append(g.Diags, *d)
			}
			continue // excluded by //go:build — not an error
		}
		pf, err := goparser.ParseFile(fset, path, src, goparser.SkipObjectResolution)
		if err != nil {
			g.Diags = append(g.Diags, syntaxDiags(err)...)
			continue
		}
		if p.Name == "" {
			p.Name = pf.Name.Name
		} else if pf.Name.Name != p.Name {
			g.Diags = append(g.Diags, Diag{Code: "bad_package", File: path,
				Line: fset.Position(pf.Name.Pos()).Line,
				Col:  fset.Position(pf.Name.Pos()).Column,
				Msg:  "package " + pf.Name.Name + " in dir expecting " + p.Name})
			continue
		}
		p.Files = append(p.Files, path)
		for _, spec := range pf.Imports {
			ip, err := strconv.Unquote(spec.Path.Value)
			if err != nil {
				continue // go/parser already reported it as syntax
			}
			pos := fset.Position(spec.Path.Pos())
			p.Imports = append(p.Imports, Import{Path: ip, File: path,
				Line: pos.Line, Col: pos.Column})
		}
	}
	if p.Name == "" && len(p.Files) == 0 && len(g.Diags) == 0 {
		g.Diags = append(g.Diags, Diag{Code: "io", File: p.Dir,
			Msg: "no buildable .go files"})
	}
}

// sortLocal emits Order (locals only, dependencies first) and reports an
// import_cycle diagnostic — naming the cycle — when one exists. DFS with a
// per-path color: gray on the stack, black done.
func (g *Graph) sortLocal() {
	const (
		white = 0
		gray  = 1
		black = 2
	)
	color := map[string]int{}
	var stack []string
	var visit func(p *Package)
	visit = func(p *Package) {
		color[p.Path] = gray
		stack = append(stack, p.Path)
		for _, imp := range p.Imports {
			dep := g.Packages[imp.Path]
			if dep == nil || !dep.Local {
				continue
			}
			switch color[dep.Path] {
			case white:
				visit(dep)
			case gray:
				// dep is on the stack: the cycle is stack[i:] + dep.
				i := 0
				for stack[i] != dep.Path {
					i++
				}
				cyc := append(append([]string{}, stack[i:]...), dep.Path)
				g.Diags = append(g.Diags, Diag{Code: "import_cycle",
					File: imp.File, Line: imp.Line, Col: imp.Col,
					Msg: "import cycle: " + strings.Join(cyc, " -> ")})
			}
		}
		stack = stack[:len(stack)-1]
		color[p.Path] = black
		g.Order = append(g.Order, p)
	}
	// Iterate package names in sorted order so the compile sequence — and
	// the console evidence of it — is reproducible across runs.
	var names []string
	for _, p := range g.Packages {
		if p.Local {
			names = append(names, p.Path)
		}
	}
	sort.Strings(names)
	for _, n := range names {
		if color[n] == white {
			visit(g.Packages[n])
		}
	}
}

// syntaxDiags flattens a go/parser error into file:line:col diags.
func syntaxDiags(err error) []Diag {
	var out []Diag
	if list, ok := err.(scanner.ErrorList); ok {
		for _, e := range list {
			out = append(out, Diag{Code: "syntax", File: e.Pos.Filename,
				Line: e.Pos.Line, Col: e.Pos.Column, Msg: e.Msg})
		}
		return out
	}
	return []Diag{{Code: "syntax", Msg: err.Error()}}
}

// buildable reports whether src's build constraints admit this toolchain
// (GOOS=virelai GOARCH=arm64, the gc compiler — the only toolchain the guest
// has). A malformed constraint line is a "syntax" diag, not a skip.
func buildable(path string, src []byte) (bool, *Diag) {
	fset := token.NewFileSet()
	f, err := goparser.ParseFile(fset, path, src,
		goparser.PackageClauseOnly|goparser.SkipObjectResolution|goparser.ParseComments)
	if err != nil {
		// Not a constraint problem — the file's own syntax parse reports it.
		return true, nil
	}
	var goBuild, plusBuild []constraint.Expr
	for _, c := range f.Comments {
		if c.Pos() > f.Package {
			break // constraints precede the package clause
		}
		for _, line := range c.List {
			expr, err := constraint.Parse(line.Text)
			if err != nil || expr == nil {
				continue // not a build line
			}
			if constraint.IsGoBuild(line.Text) {
				goBuild = append(goBuild, expr)
			} else {
				plusBuild = append(plusBuild, expr)
			}
		}
	}
	// The toolchain's rule: when a //go:build line exists it is the whole
	// contract and +build lines are ignored.
	exprs := goBuild
	if len(exprs) == 0 {
		exprs = plusBuild
	}
	for _, e := range exprs {
		if !e.Eval(isBuildTag) {
			return false, nil
		}
	}
	return true, nil
}

func isBuildTag(tag string) bool {
	switch tag {
	case "virelai", "arm64", "gc":
		return true
	}
	return false
}

// validRelPath refuses import paths that would escape the program dir or
// name a component a share path cannot carry. "." and ".." segments are
// rejected outright — the mapping is literal.
func validRelPath(p string) bool {
	if p == "" || strings.HasPrefix(p, "/") || strings.HasPrefix(p, ".") {
		return false
	}
	for _, seg := range strings.Split(p, "/") {
		if seg == "" || seg == "." || seg == ".." {
			return false
		}
	}
	return true
}

// joinPath joins with '/', the separator the share channel and this
// package's tests both speak (the GOOS port uses '/' uniformly).
func joinPath(dir, name string) string {
	if strings.HasSuffix(dir, "/") {
		return dir + name
	}
	return dir + "/" + name
}
