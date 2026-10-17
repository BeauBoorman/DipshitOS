package main

import (
	"os"
	"strconv"
	"strings"
)

// Step is one child the driver ran: the toolchain image, its exit status,
// and wall time. Status semantics are selfhost.go's: a pid that left the
// registry reads 0, so the gate's product checks — not this number — are
// the proof a step worked.
type Step struct {
	Label  string // "compile <path>" | "link"
	Image  string
	Status int64
	Ms     int64
}

// Result is what a build attempt produced. ELF is set only on success;
// Diags is the ERRORS.TXT payload; Steps is the per-child record (the
// card's tombstone rule — a dead child is reported, never retried).
// SrcFiles is the compiled source set (every local package's files, in
// build order) — the fleet manifest hashes exactly this set.
type Result struct {
	ELF      string
	Diags    []Diag
	Steps    []Step
	Order    []string // local package build order
	SrcFiles []string // compiled .go files across the local closure
}

// Config is one build's wiring. The zero images are the staged toolchain
// names; Importcfg nil means the stage-selfhost manifest path and PkgDB nil
// the staged package table beside it. Root is the fleet's second local
// tier (empty = the M107a program-dir-only resolution).
//
// The kernel's streamed-ELF exec path counts the image name against
// max_exec_args (exec.zig: `1 + args.len > max_exec_args`), so a build can
// pass at most SEVEN child args — "-importcfg CFG -tmpdir WD -o OUT OBJ"
// is exactly that bound; a further "-w" is an exec refusal, not a flag.
type Config struct {
	Dir          string   // program dir (share path, e.g. /host/WSP)
	Root         string   // fleet source root (e.g. /host/SRC); empty = off
	Out          string   // default: <Dir>/<basename>.ELF
	Importcfg    []string // staged-archive manifests; default {"/host/GOIMPORT.CFG"}
	PkgDB        []string // package tables; default {"/host/GOPKGS.TXT"}
	WorkDir      string   // default: <Dir>/.BUILD
	CompileImage string   // default GOCMDCOMPILE.ELF
	LinkImage    string   // default GOCMDLINK.ELF
}

const (
	compileImage = "GOCMDCOMPILE.ELF"
	linkImage    = "GOCMDLINK.ELF"

	// stepBudgetNs is one child's wait ceiling — a CEILING, not a
	// prediction (same shape and reason as selfhost.go's): the measured
	// link of the pinned hello was ~14 s, and a compile that wedges gets a
	// named failure rather than racing the gate's own timeout.
	stepBudgetNs = int64(600) * int64(1e9)

	// The kernel's argv block: 8 args x 255 usable bytes
	// (kernel/src/exec.zig max_exec_args, arg_slot_bytes-1). Package file
	// lists go through the @response file precisely so a package's source
	// count can never spend these slots — the budget then binds PATHS,
	// which the driver checks before a spawn.
	maxExecArgs = 8
	maxArgBytes = 255
)

// execAndWait is the spawn-and-wait seam. The guest implementation
// (spawn_guest.go) binds the child's fd-1 stream to capturePath — the B1
// exec stream request — so the compiler's stderr lands where the parent
// can read it back. Tests substitute a fake and never spawn.
var execAndWait = execAndWaitGuest

// defaultConfig fills the fields every caller needs but only Build owned:
// the toolchain images, workdir, output and the staged manifests. The test
// build's Config bypasses Build, so it defaults through this same path.
func defaultConfig(cfg *Config) {
	if cfg.CompileImage == "" {
		cfg.CompileImage = compileImage
	}
	if cfg.LinkImage == "" {
		cfg.LinkImage = linkImage
	}
	if cfg.WorkDir == "" {
		cfg.WorkDir = workDir(cfg.Dir)
	}
	if cfg.Out == "" {
		cfg.Out = joinPath(cfg.Dir, defaultOutName(cfg.Dir)+".ELF")
	}
	if len(cfg.Importcfg) == 0 {
		cfg.Importcfg = []string{"/host/GOIMPORT.CFG"}
	}
	if len(cfg.PkgDB) == 0 {
		cfg.PkgDB = []string{"/host/GOPKGS.TXT"}
	}
}

// Build compiles dir's package graph into an ELF. Every failure mode lands
// in Result.Diags — driver diagnostics and parsed child output alike — and
// in <dir>/.BUILD/ERRORS.TXT; the return value is complete even when the
// build failed (the console driver prints from it, tests assert on it).
func Build(cfg Config) Result {
	defaultConfig(&cfg)
	res := Result{}

	fail := func(d Diag) Result {
		res.Diags = append(res.Diags, d)
		writeErrors(cfg.WorkDir, res.Diags)
		return res
	}

	if err := mkdirAll(cfg.WorkDir); err != nil {
		return fail(Diag{Code: "io", File: cfg.WorkDir, Msg: err.Error()})
	}
	archives, mdiags := loadArchives(cfg.Importcfg)
	res.Diags = append(res.Diags, mdiags...)
	table, tdiags := loadPkgTable(cfg.PkgDB)
	res.Diags = append(res.Diags, tdiags...)

	g := ImportGraphR(cfg.Dir, cfg.Root, archives, table)
	res.Diags = append(res.Diags, g.Diags...)
	for _, p := range g.Order {
		res.Order = append(res.Order, p.Path)
		res.SrcFiles = append(res.SrcFiles, p.Files...)
	}
	if len(res.Diags) > 0 {
		writeErrors(cfg.WorkDir, res.Diags)
		return res
	}
	return driveBuild(cfg, g, archives, res)
}

// driveBuild runs the child-driving half of a build over a resolved graph:
// one compile child per local package in dependency order plus one link
// child. Build and the M112b test build share it — the test path differs
// only in HOW the graph is loaded (a test variant, an external test
// package and a generated testmain in place of the program dir).
func driveBuild(cfg Config, g *Graph, archives map[string]string, res Result) Result {
	fail := func(d Diag) Result {
		res.Diags = append(res.Diags, d)
		writeErrors(cfg.WorkDir, res.Diags)
		return res
	}

	// One compile child per local package, in dependency order. Each child
	// gets: its own importcfg (direct deps), its file list via a @response
	// file (argv stays inside the 8x255 budget regardless of file count),
	// and its fd-1 stream bound to a capture file.
	for _, pkg := range g.Order {
		if !pkg.Local {
			continue
		}
		obj := archivePath(cfg.WorkDir, pkg.Stem)
		rsp := joinPath(cfg.WorkDir, pkg.Stem+".rsp")
		icfg := joinPath(cfg.WorkDir, pkg.Stem+".cfg")
		diagFile := joinPath(cfg.WorkDir, pkg.Stem+".diag")
		if err := writeFile(rsp, []byte(strings.Join(pkg.Files, "\n")+"\n")); err != nil {
			return fail(Diag{Code: "io", File: rsp, Msg: err.Error()})
		}
		if err := writeFile(icfg, compileImportcfg(g, cfg.WorkDir, pkg)); err != nil {
			return fail(Diag{Code: "io", File: icfg, Msg: err.Error()})
		}
		args := []string{"-o", obj, "-p", pkg.Path, "-importcfg", icfg, "@" + rsp}
		if d, bad := checkArgv(cfg.CompileImage, args); bad {
			return fail(d)
		}
		st := runStep(cfg, "compile "+pkg.Path, cfg.CompileImage, args, diagFile)
		res.Steps = append(res.Steps, st.step)
		res.Diags = append(res.Diags, st.diags...)
		if st.failed() {
			writeErrors(cfg.WorkDir, res.Diags)
			return res
		}
	}

	// One link child: the main archive plus the whole-closure importcfg.
	lcfg := joinPath(cfg.WorkDir, "LINK.CFG")
	if err := writeFile(lcfg, linkImportcfg(g, cfg.WorkDir, archives)); err != nil {
		return fail(Diag{Code: "io", File: lcfg, Msg: err.Error()})
	}
	args := []string{"-importcfg", lcfg, "-tmpdir", cfg.WorkDir, "-o", cfg.Out,
		archivePath(cfg.WorkDir, g.Main.Stem)}
	if d, bad := checkArgv(cfg.LinkImage, args); bad {
		return fail(d)
	}
	st := runStep(cfg, "link", cfg.LinkImage, args,
		joinPath(cfg.WorkDir, "LINK.diag"))
	res.Steps = append(res.Steps, st.step)
	res.Diags = append(res.Diags, st.diags...)
	if st.failed() {
		writeErrors(cfg.WorkDir, res.Diags)
		return res
	}

	res.ELF = cfg.Out
	writeErrors(cfg.WorkDir, res.Diags)
	return res
}

// stepOut bundles a step's record with the diagnostics its capture carried.
type stepOut struct {
	step  Step
	diags []Diag
	err   error // spawn/wait-level failure (no status exists)
}

func (s stepOut) failed() bool { return s.err != nil || s.step.Status != 0 }

// runStep spawns one child, waits, and folds its captured output into
// diags. A nonzero status records the tombstone as a diag naming the child
// — the card's no-papering-over rule. A step whose child crashes on the
// EL0 slot-churn signature (the kernel reaps zombies one per idle pass;
// ~250-child drives transiently fill the registry — #2430's mechanism) is
// retried once: the reaper catches up within a tick, and the retry marker
// rides the step's own diag trail.
func runStep(cfg Config, label, image string, args []string, diagFile string) stepOut {
	out := runStepOnce(cfg, label, image, args, diagFile)
	if out.failed() && transientExec(out.diags, nil) {
		out = runStepOnce(cfg, label, image, args, diagFile)
		out.diags = append(out.diags, Diag{Code: "retried",
			Msg: label + ": retried once after transient slot-churn crash"})
	}
	return out
}

func runStepOnce(cfg Config, label, image string, args []string, diagFile string) stepOut {
	// The capture temp rides the `~` publish-temp convention beside the
	// diag stem and is removed once the step's bytes came back — .BUILD
	// must not accumulate one temp per step per build. The seam takes the
	// stem so the guest's truncate-open is the `~` name the publish guard
	// recognises.
	capture := diagFile + "~"
	status, ms, captured, err := execAndWait(image, args, diagFile)
	_ = os.Remove(capture)
	out := stepOut{step: Step{Label: label, Image: image, Status: status, Ms: ms}}
	if err != nil {
		out.err = err
		out.diags = append(out.diags, Diag{Code: "spawn",
			Msg: label + ": spawn " + image + ": " + err.Error()})
		return out
	}
	if len(captured) > 0 {
		code := "compile"
		if label == "link" {
			code = "link"
		}
		out.diags = append(out.diags, parseDiags(captured, code)...)
	}
	if status != 0 {
		out.diags = append(out.diags, Diag{Code: "child_status",
			Msg: label + ": " + image + " exited status " + strconv.FormatInt(status, 10)})
	}
	return out
}

// checkArgv applies the kernel's 8x255 argv block to the command line BEFORE
// a spawn spends a boot on it — an over-budget command is an argv_too_long
// diagnostic naming the offending arg, the refusal the card asks for.
func checkArgv(image string, args []string) (Diag, bool) {
	if len(args) > maxExecArgs {
		return Diag{Code: "argv_too_long", Msg: image + ": " +
			strconv.Itoa(len(args)) + " args > kernel max_exec_args 8"}, true
	}
	for _, a := range args {
		if len(a) > maxArgBytes {
			return Diag{Code: "argv_too_long", Msg: image + ": arg " +
				strconv.Itoa(len(a)) + " bytes > 255: " + a[:48] + "…"}, true
		}
	}
	return Diag{}, false
}

// defaultOutName derives PROG.ELF-style output from the dir basename.
func defaultOutName(dir string) string {
	dir = strings.TrimSuffix(dir, "/")
	base := dir
	if i := strings.LastIndexByte(dir, '/'); i >= 0 {
		base = dir[i+1:]
	}
	if base == "" {
		base = "OUT"
	}
	return strings.ToUpper(manglePath(base))
}
