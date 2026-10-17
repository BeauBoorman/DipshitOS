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
	Stem    string   // workdir file stem (assigned by assignStems)
	Local   bool
}

// Graph is the resolved import closure of the program rooted at Dir.
// Order lists the LOCAL packages in dependency order (a package always
// follows the local packages it imports) — the compile sequence. Root is
// an optional second local tier (the fleet's source tree): an import that
// is not a program-local dir resolves under Root before the deny/archive
// tiers, which is how a staged `virelai/*` (or pinned module) tree turns
// into local packages without touching the archive policy.
type Graph struct {
	Dir      string
	Root     string
	Main     *Package
	Packages map[string]*Package
	Order    []*Package
	Diags    []Diag
}

// maxLocalPackages bounds the sequential compiles ONE build can spawn. Every
// local package is a GOCMDCOMPILE.ELF child (~2 s measured for the pinned
// hello) run spawn-and-wait, so the cap is about total work inside the class-B
// boot budget and about a pathological closure outrunning the idle reaper
// that frees task slots between children (max_tasks = 16; exec refuses
// ENOSPC when the pool is full) — not about concurrency, which never exceeds
// one child in flight. 64 is ~10x the largest proven in-guest build
// (live-gobuild's six local packages) and bounds the sortLocal recursion and
// the .BUILD sprawl at the same time; the driver's DFS depth stays trivial
// inside its heap-grown goroutine stacks regardless (task_stack_size 192 KiB
// is the kernel's per-task stack, untouched by EL0 code).
const maxLocalPackages = 64

// Resolution contract, pinned by the card: an import resolves against the
// program directory first (a local package to compile), then the package
// table's denylist (a policy refusal beats a stale archive — fail closed),
// then the staged archive manifest (a prebuilt .a to link). M107b ruled out
// a std-from-source tier, so a KNOWN package with no archive is refused as
// dep_unsupported and a path in no table at all is no_package.
func (g *Graph) resolve(imp Import, archives map[string]string, table map[string]pkgRow) {
	switch {
	case imp.Path == "unsafe":
		return // the compiler knows it intrinsically; never an archive
	case imp.Path == "C":
		g.Diags = append(g.Diags, Diag{Code: "import_cgo", File: imp.File,
			Line: imp.Line, Col: imp.Col,
			Msg: `import "C": cgo does not exist on GOOS=virelai`})
		return
	}
	if g.Packages[imp.Path] != nil {
		// Already resolved — the test build pre-registers its synthetic
		// packages (the test variant and the <pkg>_test external package,
		// which live in the same dir, not under <root>/<path>).
		return
	}
	if dir := joinPath(g.Dir, imp.Path); validRelPath(imp.Path) && dirHasGoFiles(dir) {
		if g.Packages[imp.Path] == nil {
			g.Packages[imp.Path] = &Package{Path: imp.Path, Dir: dir, Local: true}
		}
		return
	}
	// The fleet's second local tier (M112a): <root>/<import path>. A staged
	// source tree answers imports the program dir cannot — and never reaches
	// the archive tier, so virelai/vi and virelai/vsys stay archive-resolved
	// by simply not being staged (there is no in-guest assembler for their
	// .s gateways).
	if g.Root != "" {
		if dir := joinPath(g.Root, imp.Path); validRelPath(imp.Path) && dirHasGoFiles(dir) {
			if g.Packages[imp.Path] == nil {
				g.Packages[imp.Path] = &Package{Path: imp.Path, Dir: dir, Local: true}
			}
			return
		}
	}
	if row, ok := table[imp.Path]; ok && row.denied {
		// The refusal's name goes in the message: ERRORS.TXT renders
		// file:line:col: msg, so the named refusal must live in the text
		// for the console and the file to carry it identically.
		msg := "dep_unsupported: package " + strconv.Quote(imp.Path) +
			" is not supported on GOOS=virelai"
		if row.reason != "" {
			msg += ": " + row.reason
		}
		g.Diags = append(g.Diags, Diag{Code: "dep_unsupported", File: imp.File,
			Line: imp.Line, Col: imp.Col, Msg: msg})
		return
	}
	if a, ok := archives[imp.Path]; ok {
		g.Packages[imp.Path] = &Package{Path: imp.Path, Archive: a}
		return
	}
	if _, ok := table[imp.Path]; ok {
		// A real package — in the universe — that simply has no archive
		// staged for it. This is the refusal M107b names: the fix is an
		// `allow` line in pkg-table.txt, not overlay work.
		g.Diags = append(g.Diags, Diag{Code: "dep_unsupported", File: imp.File,
			Line: imp.Line, Col: imp.Col,
			Msg: "dep_unsupported: package " + strconv.Quote(imp.Path) +
				" is not supported on GOOS=virelai: no staged archive"})
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
// ERRORS.TXT writer see the same structured facts. The walk stops cold at
// maxLocalPackages local packages: the cap exists to refuse a pathological
// closure BEFORE it spends the boot budget on hundreds of sequential
// compile children.
func ImportGraph(dir string, archives map[string]string, table map[string]pkgRow) *Graph {
	return ImportGraphR(dir, "", archives, table)
}

// ImportGraphR is ImportGraph with the fleet's source root: imports that
// are not program-local resolve under root (a staged source tree) before
// the deny/archive tiers.
func ImportGraphR(dir, root string, archives map[string]string, table map[string]pkgRow) *Graph {
	g := &Graph{Dir: dir, Root: root, Packages: map[string]*Package{}}
	main := &Package{Path: "main", Dir: dir, Local: true}
	g.Packages["main"] = main
	g.load(main)
	g.Main = main
	if main.Name != "main" && len(main.Files) > 0 {
		g.Diags = append(g.Diags, Diag{Code: "no_main", File: main.Files[0],
			Msg: "build dir is package " + strconv.Quote(main.Name) + ", not package main"})
	}
	g.resolveQueue([]*Package{main}, archives, table)
	return g
}

// resolveQueue runs the shared resolution walk over a starting set of
// already-loaded local packages: a local import discovered while loading P
// enqueues P's resolution AFTER its files are parsed, which keeps
// diagnostics ordered by discovery. The caller pre-loads its root packages
// (a program dir for ImportGraphR; the test variant + external test package
// for the M112b test build) — new locals discovered by resolution load
// through the standard non-test listing.
func (g *Graph) resolveQueue(start []*Package, archives map[string]string, table map[string]pkgRow) {
	locals := 0
	for _, p := range g.Packages {
		if p.Local {
			locals++
		}
	}
	queue := append([]*Package{}, start...)
	for len(queue) > 0 {
		p := queue[0]
		queue = queue[1:]
		for _, imp := range p.Imports {
			before := len(g.Packages)
			g.resolve(imp, archives, table)
			if len(g.Packages) > before {
				if np := g.Packages[imp.Path]; np.Local {
					locals++
					if locals > maxLocalPackages {
						g.Diags = append(g.Diags, Diag{Code: "closure_too_large",
							File: imp.File, Line: imp.Line, Col: imp.Col,
							Msg: "closure_too_large: local package closure " +
								strconv.Itoa(locals) + " > cap " +
								strconv.Itoa(maxLocalPackages)})
						return // refuse before a single child is spawned
					}
					g.load(np)
					queue = append(queue, np)
				}
			}
		}
	}
	g.sortLocal()
	assignStems(g)
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
	g.loadFiles(p, files)
	// A package whose virelai-selected sources include .s needs cmd/asm,
	// which the in-guest toolchain does not ship (ADR 0035 D4: compile +
	// link only). Naming it here beats letting the linker find the missing
	// bodies — the refusal says WHICH package and WHICH files.
	if asm := buildableAsm(p.Dir); len(asm) > 0 {
		g.Diags = append(g.Diags, Diag{Code: "needs_asm", File: p.Dir,
			Msg: "needs_asm: package " + strconv.Quote(p.Path) +
				" requires an assembler for " + strings.Join(asm, ", ") +
				" (no cmd/asm on GOOS=virelai)"})
	}
}

// loadFiles is load's inner loop over an explicit file list — the test
// build's variant package adds its internal _test.go files to the same
// parse/import pass the non-test listing drives.
func (g *Graph) loadFiles(p *Package, files []string) {
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

// buildableAsm lists dir's .s files that this toolchain would assemble. A
// .s has no package clause, so constraints are read as leading comment
// lines directly; an unconstrained .s builds for every GOOS, and a file
// whose constraint excludes virelai (…_windows.s shape) is not an asm
// dependency of this build.
func buildableAsm(dir string) []string {
	ents, err := dirEntries(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		name := e.name
		if e.isDir || !strings.HasSuffix(name, ".s") {
			continue
		}
		if !fileNameTargetOK(name) {
			continue // x_linux.s: not this target's file
		}
		src, err := readFile(joinPath(dir, name))
		if err != nil {
			out = append(out, name)
			continue // unreadable .s is still an asm dependency
		}
		if asmFileBuildable(src) {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

// asmFileBuildable evaluates an .s file's leading //go:build / +build
// constraints against this toolchain's tag set.
func asmFileBuildable(src []byte) bool {
	for _, line := range strings.Split(string(src), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if !strings.HasPrefix(line, "//") {
			break // first non-comment line ends the constraint zone
		}
		expr, err := constraint.Parse(strings.TrimPrefix(line, "//"))
		if err != nil || expr == nil {
			continue
		}
		if constraint.IsGoBuild(line) || strings.HasPrefix(line, "// +build") {
			if !expr.Eval(isBuildTag) {
				return false
			}
		}
	}
	return true
}

// stemMaxBytes bounds a workdir file stem so "<stem>.diag~" (the longest
// derived name: the step capture's publish temp) stays inside the 31-byte
// share-name limit (kernel/src/file_table.zig).
const stemMaxBytes = 31 - len(".diag~")

// assignStems gives each local package a workdir-unique, share-legal file
// stem. The readable "P_"+manglePath wins when it fits and is unique; deep
// module paths (charm.land/bubbletea/v2, github.com/charmbracelet/x/ansi/…)
// exceed the name bound and take a P%03d index assigned in sorted order —
// deterministic, and the compile/link importcfgs keep the true path in text.
func assignStems(g *Graph) {
	var names []string
	for _, p := range g.Packages {
		if p.Local {
			names = append(names, p.Path)
		}
	}
	sort.Strings(names)
	seen := map[string]bool{}
	idx := 0
	for _, n := range names {
		stem := "P_" + manglePath(n)
		if len(stem) > stemMaxBytes || seen[stem] {
			for {
				stem = "P" + strconv.Itoa(idx)
				idx++
				if !seen[stem] {
					break
				}
			}
		}
		seen[stem] = true
		g.Packages[n].Stem = stem
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

// The GOOS/GOARCH name lists go/build uses for filename matching
// (internal/syslist): a final _<GOOS>/_<GOARCH> component selects that
// platform, x_<GOOS>_<GOARCH> selects the pair, and unrecognised tokens
// ("other", "unix", "posix") constrain nothing. The fleet's module trees
// lean on this — constants_linux.go must NOT compile for virelai.
var knownGOOSFile = map[string]bool{
	"aix": true, "android": true, "darwin": true, "dragonfly": true,
	"freebsd": true, "hurd": true, "illumos": true, "ios": true, "js": true,
	"linux": true, "nacl": true, "netbsd": true, "openbsd": true,
	"plan9": true, "solaris": true, "wasip1": true, "virelai": true,
	"windows": true, "zos": true,
}
var knownGOARCHFile = map[string]bool{
	"386": true, "amd64": true, "amd64p32": true, "arm": true,
	"armbe": true, "arm64": true, "arm64be": true, "loong64": true,
	"mips": true, "mipsle": true, "mips64": true, "mips64le": true,
	"mips64p32": true, "mips64p32le": true, "ppc": true, "ppc64": true,
	"ppc64le": true, "riscv": true, "riscv64": true, "s390x": true,
	"sparc": true, "sparc64": true, "wasm": true,
}

// fileNameTargetOK evaluates go/build's filename platform rule for the
// driver's fixed target (GOOS=virelai, GOARCH=arm64). path may carry
// directories; only the last component's _-suffixes matter.
func fileNameTargetOK(path string) bool {
	base := path
	if i := strings.LastIndexByte(base, '/'); i >= 0 {
		base = base[i+1:]
	}
	if i := strings.LastIndexByte(base, '.'); i >= 0 {
		base = base[:i]
	}
	base = strings.TrimSuffix(base, "_test")
	parts := strings.Split(base, "_")
	if len(parts) < 2 {
		return true
	}
	last := parts[len(parts)-1]
	second := ""
	if len(parts) >= 3 {
		second = parts[len(parts)-2]
	}
	if knownGOARCHFile[last] {
		if last != "arm64" {
			return false
		}
		return !knownGOOSFile[second] || second == "virelai"
	}
	if knownGOOSFile[last] {
		return last == "virelai"
	}
	return true
}

// buildable reports whether src's build constraints admit this toolchain
// (GOOS=virelai GOARCH=arm64, the gc compiler — the only toolchain the guest
// has). A malformed constraint line is a "syntax" diag, not a skip.
func buildable(path string, src []byte) (bool, *Diag) {
	if !fileNameTargetOK(path) {
		return false, nil // x_linux.go, x_386.s: not this target's file
	}
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
