package main

// M112b (#2414): the `gobuild test` verb. It runs the pinned package list
// (testpkgs.txt, staged as /host/TESTPKGS.TXT) through the testmain
// generator: each row builds a test ELF — package test variant + external
// test package + generated main — execs it under "-test.v" with its fd-1
// stream bound to a capture file, and reduces the run to a named verdict.
//
// Receipts mirror GOSELF's discipline (user/go/selftest): every leg leaves
// a per-package receipt file under the receipt dir (/host/TESTOUT/<TAG>.ok
// or .fail) plus the aggregate TESTS.MF manifest and summary.txt on the
// share — the gate reads files, not serial text. Excluded rows from the
// pinned list are recorded verbatim in the manifest with their reason; a
// row is never silently skipped.

import (
	goparser "go/parser"
	"go/token"
	"os"
	"strconv"
	"strings"

	"virelai/vsys"
)

// testRow is one pinned list entry: a run row carries just the source dir
// ("virelai/clockfmt"); an excluded row is `excluded <pkg> <reason>`.
type testRow struct {
	pkg      string
	excluded bool
	reason   string
	code     string
}

// parseTestList reads testpkgs.txt. Run rows are a bare source path;
// `excluded <pkg> <reason>` rows are pinned non-participants whose reason
// lands verbatim in the manifest.
func parseTestList(text string) ([]testRow, Diag) {
	var rows []testRow
	for n, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Fields(line)
		if f[0] == "excluded" {
			if len(f) < 3 {
				return nil, Diag{Code: "bad_testlist", Line: n + 1,
					Msg: "test list: expected `excluded <pkg> <reason>`, got " + line}
			}
			reason := strings.Join(f[2:], " ")
			code, _, _ := strings.Cut(reason, ":")
			rows = append(rows, testRow{pkg: f[1], excluded: true,
				reason: reason, code: code})
			continue
		}
		if len(f) != 1 || !strings.HasPrefix(f[0], "virelai/") {
			return nil, Diag{Code: "bad_testlist", Line: n + 1,
				Msg: "test list: expected `<virelai/pkg>` or `excluded <pkg> <reason>`, got " + line}
		}
		rows = append(rows, testRow{pkg: f[0]})
	}
	return rows, Diag{}
}

// testCfg wires one `gobuild test` run.
type testCfg struct {
	List       string // default /host/TESTPKGS.TXT
	Root       string // default /host/SRC
	OutDir     string // default /host — test ELFs land beside the fleet's
	ReceiptDir string // default /host/TESTOUT — GOSELF-style per-leg receipts
	Manifest   string // default /host/TESTS.MF
	Importcfg  []string
	PkgDB      []string
}

// testOutcome is one manifest row before rendering.
type testOutcome struct {
	pkg       string
	tag       string
	state     string // passed | failed | refused | excluded
	code      string
	note      string
	srcSHA    string
	elfSHA    string
	tests     int
	failed    int
	ms        int64
	transient bool // the failure matched the slot-churn signature — retryable
}

// testElfName derives the product name: T_<SRCDIR-MANGLED>.ELF inside the
// share-name bound. Receipts append ".ok"/".fail", so the ELF name itself
// must leave five bytes of headroom inside the kernel's 31-byte name cap
// (kernel/src/file_table.zig); longer paths take a deterministic index.
func testElfName(pkg string, idx int) string {
	name := "T_" + strings.ToUpper(manglePath(pkg)) + ".ELF"
	if len(name) <= 26 {
		return name
	}
	return "TT" + pad2(idx) + ".ELF"
}

func pad2(v int) string {
	s := strconv.Itoa(v)
	if len(s) < 2 {
		return "0" + s
	}
	return s
}

// listTestSources splits dir's *.go listing into the non-test and test
// files this driver considers (the _test.go half that listGoFiles
// deliberately drops).
func listTestSources(dir string) (normal, test []string, err error) {
	ents, err := dirEntries(dir)
	if err != nil {
		return nil, nil, err
	}
	for _, e := range ents {
		name := e.name
		if e.isDir || !strings.HasSuffix(name, ".go") ||
			strings.HasPrefix(name, ".") || strings.HasPrefix(name, "_") {
			continue
		}
		if strings.HasSuffix(name, "_test.go") {
			test = append(test, name)
		} else {
			normal = append(normal, name)
		}
	}
	return normal, test, nil
}

// pkgBaseName discovers the package clause the internal test files must
// declare: the first buildable non-test source's package name, else "main"
// for a test-only dir.
func pkgBaseName(dir string, normal []string) string {
	fset := token.NewFileSet()
	for _, f := range normal {
		path := joinPath(dir, f)
		src, err := readFile(path)
		if err != nil {
			continue
		}
		if ok, _ := buildable(path, src); !ok {
			continue
		}
		pf, err := goparser.ParseFile(fset, path, src,
			goparser.PackageClauseOnly|goparser.SkipObjectResolution)
		if err == nil {
			return pf.Name.Name
		}
	}
	return "main"
}

// testGraph builds the compile graph for one pinned package: the test
// variant (package + internal test files), the external test package when
// present, and the generated testmain as the link root.
func testGraph(dir, workdir, pkgPath, mainFile string, ts testSet,
	root string, archives map[string]string, table map[string]pkgRow) *Graph {
	g := &Graph{Dir: workdir, Root: root, Packages: map[string]*Package{}}

	normal, _, _ := listTestSources(dir)
	variant := &Package{Path: pkgPath, Dir: dir, Local: true}
	g.Packages[pkgPath] = variant
	variantFiles := append(append([]string{}, normal...), ts.internal...)
	g.loadFiles(variant, variantFiles)
	if asm := buildableAsm(dir); len(asm) > 0 {
		g.Diags = append(g.Diags, Diag{Code: "needs_asm", File: dir,
			Msg: "needs_asm: package " + strconv.Quote(pkgPath) +
				" requires an assembler for " + strings.Join(asm, ", ") +
				" (no cmd/asm on GOOS=virelai)"})
	}
	start := []*Package{variant}

	if len(ts.external) > 0 {
		xt := &Package{Path: pkgPath + "_test", Dir: dir, Local: true}
		g.Packages[xt.Path] = xt
		g.loadFiles(xt, ts.external)
		start = append(start, xt)
	}

	mp := &Package{Path: "main", Dir: workdir, Local: true}
	g.Packages["main"] = mp
	g.Main = mp
	g.loadFiles(mp, []string{mainFile})
	start = append(start, mp)

	g.resolveQueue(start, archives, table)
	return g
}

// parseTestOutput reduces a captured "-test.v" stream to pass/fail counts
// and the terminal FAIL marker. It reads testing's own lines, not exit
// status — a run with no output at all is reported separately.
func parseTestOutput(captured []byte) (passed, failed, skipped int, sawFAIL, sawPanic bool) {
	for _, line := range strings.Split(string(captured), "\n") {
		// Subtest verdicts print one indent level deeper than the parent —
		// trim left so a nested --- FAIL still counts.
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "--- FAIL:"):
			failed++
		case strings.HasPrefix(line, "--- PASS:"):
			passed++
		case strings.HasPrefix(line, "--- SKIP:"):
			skipped++
		case line == "FAIL" || strings.HasPrefix(line, "FAIL\t"):
			sawFAIL = true
		case strings.HasPrefix(line, "panic:"):
			sawPanic = true
		}
	}
	return
}

// transientExecPatterns are the runtime-crash signatures of EL0 task-slot
// exhaustion: the kernel reaps exited children one per idle pass, so a
// ~300-child run can transiently fill the registry mid-build (the same
// churn #2430 tracked). A leg that crashes on one is retried once — the
// reaper catches up within a second — and the retry is recorded in the
// outcome's note so the manifest never hides the flake.
var transientExecPatterns = []string{
	"newosproc", "sys_thread create failed",
	"cannot allocate memory", "thread exhaustion", "out of memory",
}

// transientExec reports whether a failed leg's evidence matches the
// churn-exhaustion signature: a diag message or captured child output.
func transientExec(diags []Diag, captured []byte) bool {
	for _, d := range diags {
		for _, p := range transientExecPatterns {
			if strings.Contains(d.Msg, p) {
				return true
			}
		}
	}
	for _, p := range transientExecPatterns {
		if strings.Contains(string(captured), p) {
			return true
		}
	}
	return false
}

// runTestLeg builds and runs one pinned package's test binary. A leg whose
// build or test child dies on transient slot exhaustion is retried once —
// recorded in the note, so the gate sees both the pass and the flake.
func runTestLeg(fc testCfg, pkg string, idx int,
	archives map[string]string, table map[string]pkgRow) testOutcome {
	oc := runTestLegOnce(fc, pkg, idx, archives, table)
	if oc.state == "failed" && oc.transient {
		vsys.Println("test: " + pkg + " retrying after transient " + oc.code)
		oc2 := runTestLegOnce(fc, pkg, idx, archives, table)
		if oc2.note != "" {
			oc2.note += " "
		}
		oc2.note += "retried=1"
		return oc2
	}
	return oc
}

// runTestLegOnce is one attempt of runTestLeg.
func runTestLegOnce(fc testCfg, pkg string, idx int,
	archives map[string]string, table map[string]pkgRow) testOutcome {
	oc := testOutcome{pkg: pkg, tag: testElfName(pkg, idx)}
	dir := joinPath(fc.Root, pkg)
	workdir := joinPath(dir, ".TBUILD")

	normal, _, lerr := listTestSources(dir)
	if lerr != nil || len(normal) == 0 {
		oc.state, oc.code = "refused", "source_missing"
		oc.note = dir + " is not on the share"
		if lerr != nil {
			oc.note += " (list: " + lerr.Error() + ")"
		}
		vsys.Println("test: " + pkg + " refused source_missing: " + oc.note)
		return oc
	}
	ts := scanTestFiles(dir, pkgBaseName(dir, normal))
	if len(ts.diags) > 0 {
		oc.state, oc.code = "refused", ts.diags[0].Code
		oc.note = ts.diags[0].String()
		vsys.Println("test: " + pkg + " refused " + oc.code + ": " + oc.note)
		return oc
	}
	if len(ts.tests) == 0 && ts.testMain == nil {
		oc.state, oc.code = "refused", "no_tests"
		oc.note = "no Test* functions collected under GOOS=virelai"
		vsys.Println("test: " + pkg + " refused no_tests")
		return oc
	}
	if asm := buildableAsm(dir); len(asm) > 0 {
		oc.state, oc.code = "refused", "needs_asm"
		oc.note = "requires an assembler for " + strings.Join(asm, ", ")
		vsys.Println("test: " + pkg + " refused needs_asm: " + oc.note)
		return oc
	}

	if err := mkdirAll(workdir); err != nil {
		oc.state, oc.code, oc.note = "failed", "io", err.Error()
		vsys.Println("test: " + pkg + " failed io: " + oc.note)
		return oc
	}
	mainFile := "TESTMAIN.GO"
	if err := writeFile(joinPath(workdir, mainFile), genTestmain(pkg, dir, ts)); err != nil {
		oc.state, oc.code, oc.note = "failed", "io", err.Error()
		vsys.Println("test: " + pkg + " failed io: " + oc.note)
		return oc
	}

	out := joinPath(fc.OutDir, oc.tag)
	cfg := Config{Dir: dir, Root: fc.Root, Out: out, WorkDir: workdir,
		Importcfg: fc.Importcfg, PkgDB: fc.PkgDB}
	defaultConfig(&cfg)
	g := testGraph(dir, workdir, pkg, mainFile, ts, fc.Root, archives, table)
	res := Result{}
	res.Diags = append(res.Diags, g.Diags...)
	for _, p := range g.Order {
		res.Order = append(res.Order, p.Path)
		res.SrcFiles = append(res.SrcFiles, p.Files...)
	}
	if len(res.Diags) == 0 {
		res = driveBuild(cfg, g, archives, res)
	} else {
		writeErrors(workdir, res.Diags)
	}
	for _, st := range res.Steps {
		oc.ms += st.Ms
	}
	oc.srcSHA = srcTreeHash(fc.Root, res.SrcFiles)
	if res.ELF == "" {
		code := "graph"
		if len(res.Diags) > 0 {
			code = res.Diags[0].Code
		}
		if len(res.Steps) == 0 {
			oc.state, oc.code = "refused", code
		} else {
			oc.state, oc.code = "failed", code
			oc.transient = transientExec(res.Diags, nil)
		}
		if len(res.Diags) > 0 {
			oc.note = res.Diags[0].Msg
		}
		vsys.Println("test: " + pkg + " " + oc.state + " " + oc.code + ": " + oc.note)
		if oc.state == "failed" && len(res.Diags) > 1 {
			hi := len(res.Diags)
			if hi > 8 {
				hi = 8
			}
			for _, d := range res.Diags[:hi] {
				m := d.Msg
				if len(m) > 160 {
					m = m[:160]
				}
				vsys.Println("test: " + pkg + " diag: " + m)
			}
		}
		return oc
	}

	if s, ok := sha256File(out); ok {
		oc.elfSHA = s
	}
	vsys.Println("test: " + pkg + " built " + oc.tag + " sha256=" + oc.elfSHA +
		" ms=" + strconv.FormatInt(oc.ms, 10))

	capture := joinPath(workdir, "RUN.diag")
	status, rms, captured, err := execAndWait(oc.tag, []string{"-test.v"}, capture)
	_ = os.Remove(capture + "~")
	oc.ms += rms
	if err != nil {
		oc.state, oc.code, oc.note = "failed", "spawn", err.Error()
		vsys.Println("test: " + pkg + " failed spawn: " + oc.note)
		return oc
	}
	passed, failedN, skipped, sawFAIL, sawPanic := parseTestOutput(captured)
	oc.tests = passed
	oc.failed = failedN
	switch {
	case status != 0:
		oc.state, oc.code = "failed", "test_exit"
		oc.note = "test binary exited status " + strconv.FormatInt(status, 10)
		oc.transient = transientExec(nil, captured)
	case sawPanic:
		oc.state, oc.code = "failed", "test_panic"
		oc.note = "panic in test binary"
		oc.transient = transientExec(nil, captured)
	case failedN > 0 || sawFAIL:
		oc.state, oc.code = "failed", "test_failed"
		oc.note = strconv.Itoa(failedN) + " test(s) failed"
	case passed+skipped == 0:
		oc.state, oc.code = "failed", "no_tests_ran"
		oc.note = "test binary produced no test verdicts"
		oc.transient = transientExec(nil, captured)
	default:
		oc.state = "passed"
	}
	if oc.state == "passed" {
		vsys.Println("test: " + pkg + " pass n=" + strconv.Itoa(passed) +
			" skip=" + strconv.Itoa(skipped) + " ms=" + strconv.FormatInt(oc.ms, 10))
	} else {
		vsys.Println("test: " + pkg + " " + oc.state + " " + oc.code + ": " + oc.note)
		// On failure the child's own stream is the evidence: the FAIL/panic
		// lines first (a long verbose capture would cut them out of a plain
		// tail), then the tail itself for the exit context.
		var hits, tail []string
		for _, line := range strings.Split(string(captured), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			tail = append(tail, line)
			if strings.Contains(line, "FAIL:") || strings.Contains(line, "panic:") ||
				strings.HasPrefix(strings.TrimSpace(line), "panic ") ||
				(strings.HasPrefix(line, "    ") && strings.Contains(line, "_test.go:")) {
				hits = append(hits, line)
			}
		}
		printed := 0
		for _, line := range hits {
			if printed >= 10 {
				break
			}
			if len(line) > 160 {
				line = line[:160]
			}
			vsys.Println("test: " + pkg + " diag: " + line)
			printed++
		}
		hi := len(tail)
		lo := hi - 6
		if lo < 0 {
			lo = 0
		}
		for _, line := range tail[lo:hi] {
			if len(line) > 160 {
				line = line[:160]
			}
			vsys.Println("test: " + pkg + " diag: " + line)
		}
	}
	return oc
}

// runTest iterates the pinned list: every run row becomes a build+exec leg,
// every excluded row a named manifest entry; receipts land per leg.
func runTest(fc testCfg) int {
	body, err := readFile(fc.List)
	if err != nil {
		vsys.Println("gobuild: test: cannot read " + fc.List)
		return 1
	}
	rows, d := parseTestList(string(body))
	if d.Code != "" {
		vsys.Println("gobuild: test: " + d.String())
		return 1
	}
	archives, mdiags := loadArchives(fc.Importcfg)
	table, tdiags := loadPkgTable(fc.PkgDB)
	for _, d := range append(mdiags, tdiags...) {
		vsys.Println("test: diag " + d.String())
	}
	tc := toolchainStamp()
	if err := mkdirAll(fc.ReceiptDir); err != nil {
		vsys.Println("test: cannot create " + fc.ReceiptDir + ": " + err.Error())
		return 1
	}

	var outcomes []testOutcome
	passed, failed, refused, excluded := 0, 0, 0, 0
	idx := 0
	for _, row := range rows {
		if row.excluded {
			oc := testOutcome{pkg: row.pkg, tag: testElfName(row.pkg, idx),
				state: "excluded", code: row.code, note: row.reason}
			vsys.Println("test: " + row.pkg + " excluded " + row.code +
				": " + row.reason)
			excluded++
			outcomes = append(outcomes, oc)
			continue
		}
		oc := runTestLeg(fc, row.pkg, idx, archives, table)
		switch oc.state {
		case "passed":
			passed++
		case "refused":
			refused++
		default:
			failed++
		}
		writeTestReceipt(fc.ReceiptDir, oc)
		outcomes = append(outcomes, oc)
		idx++
	}

	if err := writeFile(fc.Manifest, []byte(renderTestManifest(tc, outcomes))); err != nil {
		vsys.Println("test: manifest write failed: " + err.Error())
		failed++
	} else {
		vsys.Println("test: manifest -> " + fc.Manifest)
	}
	writeTestSummary(fc.ReceiptDir, outcomes)
	vsys.Println("test: receipts -> " + fc.ReceiptDir)

	if failed > 0 {
		vsys.Println("test: tests INCOMPLETE passed=" + strconv.Itoa(passed) +
			" refused=" + strconv.Itoa(refused) + " excluded=" + strconv.Itoa(excluded) +
			" failed=" + strconv.Itoa(failed))
		return 1
	}
	vsys.Println("test: tests OK passed=" + strconv.Itoa(passed) +
		" refused=" + strconv.Itoa(refused) + " excluded=" + strconv.Itoa(excluded))
	return 0
}

// writeTestReceipt drops one GOSELF-style receipt per leg: .ok on pass,
// .fail on anything else, so the host reads verdicts from files.
func writeTestReceipt(dir string, oc testOutcome) {
	line := oc.state + " pkg=" + oc.pkg + " tests=" + strconv.Itoa(oc.tests) +
		" failed=" + strconv.Itoa(oc.failed) + " ms=" + strconv.FormatInt(oc.ms, 10)
	if oc.elfSHA != "" {
		line += " elf=" + oc.elfSHA
	}
	if oc.code != "" {
		line += " code=" + oc.code
	}
	if oc.note != "" {
		line += " note=" + oc.note
	}
	ext := ".ok"
	if oc.state != "passed" {
		ext = ".fail"
	}
	_ = writeFile(joinPath(dir, oc.tag+ext), []byte(line+"\n"))
}

// writeTestSummary mirrors GOSELF's OUT/summary.txt: the counts are the
// machine-checkable claim; nothing passes by printing to serial alone.
func writeTestSummary(dir string, outcomes []testOutcome) {
	var passed, failed, refused, excluded, ntests int
	for _, oc := range outcomes {
		switch oc.state {
		case "passed":
			passed++
		case "failed":
			failed++
		case "refused":
			refused++
		case "excluded":
			excluded++
		}
		ntests += oc.tests
	}
	body := "packages=" + strconv.Itoa(len(outcomes)) +
		" passed=" + strconv.Itoa(passed) +
		" failed=" + strconv.Itoa(failed) +
		" refused=" + strconv.Itoa(refused) +
		" excluded=" + strconv.Itoa(excluded) +
		" tests=" + strconv.Itoa(ntests) + "\n"
	_ = writeFile(joinPath(dir, "summary.txt"), []byte(body))
}

// renderTestManifest writes the #v1 test manifest: per package the source
// hash (variant + testmain inputs), the toolchain stamp, the test ELF's
// sha256, the test verdict counters and any named refusal.
func renderTestManifest(tc string, outcomes []testOutcome) string {
	var b strings.Builder
	b.WriteString("#v1 test manifest — M112b (#2414): the pinned package tests run in-guest\n")
	b.WriteString("# row: <pkg>\\t<passed|failed|refused|excluded>\\ttag=<ELF>" +
		"\\tsrc=<sha256|->\\ttc=<sha256>\\telf=<sha256|->\\ttests=<n>\\tfailed=<n>" +
		"\\tms=<n>[\\tcode=<name>][\\tnote=<text>]\n")
	for _, oc := range outcomes {
		or := func(s string) string {
			if s == "" {
				return "-"
			}
			return s
		}
		b.WriteString(oc.pkg + "\t" + oc.state +
			"\ttag=" + oc.tag +
			"\tsrc=" + or(oc.srcSHA) +
			"\ttc=" + tc +
			"\telf=" + or(oc.elfSHA) +
			"\ttests=" + strconv.Itoa(oc.tests) +
			"\tfailed=" + strconv.Itoa(oc.failed) +
			"\tms=" + strconv.FormatInt(oc.ms, 10))
		if oc.code != "" {
			b.WriteString("\tcode=" + oc.code)
		}
		if oc.note != "" {
			b.WriteString("\tnote=" + oc.note)
		}
		b.WriteString("\n")
	}
	return b.String()
}
