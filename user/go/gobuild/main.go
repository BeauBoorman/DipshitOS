package main

import (
	"strconv"
	"strings"

	"virelai/vi"
	"virelai/vsys"
)

var consoleFn = vi.ConsoleLine

// GOBUILD.ELF <verb> — the surface the card asks for under gosh's bare-name
// resolution (`gobuild <dir>` / `exec GOBUILD.ELF <dir>`; a standalone ELF
// rather than a shlib builtin keeps the driver's blast radius out of the
// shell — the card's review-note recommendation).
//
//	gobuild [build] <dir> [-o OUT.ELF] [-importcfg CFG]... [-pkgdb TBL]...
//	                                                        compile + link
//	gobuild graph <dir> [-importcfg CFG]... [-pkgdb TBL]...  resolve + print
//	                                                        order
//	gobuild fleet [-list FLEET.TXT] [-root SRC] [-outdir DIR] [-refs DIR]
//	              [-manifest MF] [-nosmoke]                    M112a: the
//	                                                        pinned fleet +
//	                                                        FLEET.MF manifest
//	gobuild test [-list TESTPKGS.TXT] [-root SRC] [-outdir DIR]
//	              [-receipts DIR] [-manifest MF]              M112b: the
//	                                                        pinned package
//	                                                        tests + receipts
func main() {
	rc := run(vi.Args())
	// Yield a tick before exiting so a parent shell polling vi.Wait blocks
	// while the idle reaper frees this child's task slots (FLINT's pattern).
	vi.Sleep(1)
	vi.Exit(rc)
}

func run(argv []string) int {
	var args []string
	if len(argv) > 0 {
		args = argv[1:] // argv[0] is this program's name
	}
	if len(args) > 0 && args[0] == "fleet" {
		return runFleetArgs(args[1:])
	}
	if len(args) > 0 && args[0] == "test" {
		return runTestArgs(args[1:])
	}
	verb := "build"
	if len(args) > 0 && (args[0] == "build" || args[0] == "graph") {
		verb = args[0]
		args = args[1:]
	}
	var cfg Config
	var positional []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-o":
			if i+1 >= len(args) {
				return usage("-o needs a path")
			}
			i++
			cfg.Out = args[i]
		case "-importcfg":
			if i+1 >= len(args) {
				return usage("-importcfg needs a path")
			}
			i++
			cfg.Importcfg = append(cfg.Importcfg, args[i])
		case "-pkgdb":
			if i+1 >= len(args) {
				return usage("-pkgdb needs a path")
			}
			i++
			cfg.PkgDB = append(cfg.PkgDB, args[i])
		default:
			if strings.HasPrefix(args[i], "-") {
				return usage("unknown flag " + args[i])
			}
			positional = append(positional, args[i])
		}
	}
	if len(positional) != 1 {
		return usage("exactly one build dir")
	}
	cfg.Dir = strings.TrimSuffix(positional[0], "/")
	if len(cfg.Importcfg) == 0 {
		cfg.Importcfg = []string{"/host/GOIMPORT.CFG"}
	}
	if len(cfg.PkgDB) == 0 {
		cfg.PkgDB = []string{"/host/GOPKGS.TXT"}
	}

	if verb == "graph" {
		return runGraph(cfg)
	}
	return runBuild(cfg)
}

func usage(why string) int {
	vsys.Println("gobuild: " + why)
	vsys.Println("gobuild: usage: gobuild [build] <dir> [-o OUT.ELF] [-importcfg CFG] [-pkgdb TBL]")
	vsys.Println("gobuild:        gobuild graph <dir> [-importcfg CFG] [-pkgdb TBL]")
	vsys.Println("gobuild:        gobuild fleet [-list FLEET.TXT] [-root SRC] [-outdir DIR] [-refs DIR] [-manifest MF] [-nosmoke]")
	vsys.Println("gobuild:        gobuild test [-list TESTPKGS.TXT] [-root SRC] [-outdir DIR] [-receipts DIR] [-manifest MF]")
	return 2
}

// runTestArgs parses the test verb's flag set (no positional args — the
// pinned list is the input).
func runTestArgs(args []string) int {
	tc := testCfg{}
	for i := 0; i < len(args); i++ {
		val := func() (string, bool) {
			if i+1 >= len(args) {
				return "", false
			}
			i++
			return args[i], true
		}
		switch args[i] {
		case "-list":
			if v, ok := val(); !ok {
				return usage("-list needs a path")
			} else {
				tc.List = v
			}
		case "-root":
			if v, ok := val(); !ok {
				return usage("-root needs a path")
			} else {
				tc.Root = v
			}
		case "-outdir":
			if v, ok := val(); !ok {
				return usage("-outdir needs a path")
			} else {
				tc.OutDir = v
			}
		case "-receipts":
			if v, ok := val(); !ok {
				return usage("-receipts needs a path")
			} else {
				tc.ReceiptDir = v
			}
		case "-manifest":
			if v, ok := val(); !ok {
				return usage("-manifest needs a path")
			} else {
				tc.Manifest = v
			}
		case "-importcfg":
			if v, ok := val(); !ok {
				return usage("-importcfg needs a path")
			} else {
				tc.Importcfg = append(tc.Importcfg, v)
			}
		case "-pkgdb":
			if v, ok := val(); !ok {
				return usage("-pkgdb needs a path")
			} else {
				tc.PkgDB = append(tc.PkgDB, v)
			}
		default:
			return usage("test: unknown flag " + args[i])
		}
	}
	if tc.List == "" {
		tc.List = "/host/TESTPKGS.TXT"
	}
	if tc.Root == "" {
		tc.Root = "/host/SRC"
	}
	if tc.OutDir == "" {
		tc.OutDir = "/host"
	}
	if tc.ReceiptDir == "" {
		tc.ReceiptDir = "/host/TESTOUT"
	}
	if tc.Manifest == "" {
		tc.Manifest = "/host/TESTS.MF"
	}
	if len(tc.Importcfg) == 0 {
		tc.Importcfg = []string{"/host/GOIMPORT.CFG"}
	}
	if len(tc.PkgDB) == 0 {
		tc.PkgDB = []string{"/host/GOPKGS.TXT"}
	}
	return runTest(tc)
}

// runFleetArgs parses the fleet verb's own flag set (no positional args —
// the pinned list is the input, not an operand).
func runFleetArgs(args []string) int {
	fc := fleetCfg{Smoke: true}
	for i := 0; i < len(args); i++ {
		val := func() (string, bool) {
			if i+1 >= len(args) {
				return "", false
			}
			i++
			return args[i], true
		}
		switch args[i] {
		case "-list":
			if v, ok := val(); !ok {
				return usage("-list needs a path")
			} else {
				fc.List = v
			}
		case "-root":
			if v, ok := val(); !ok {
				return usage("-root needs a path")
			} else {
				fc.Root = v
			}
		case "-outdir":
			if v, ok := val(); !ok {
				return usage("-outdir needs a path")
			} else {
				fc.OutDir = v
			}
		case "-refs":
			if v, ok := val(); !ok {
				return usage("-refs needs a path")
			} else {
				fc.RefDir = v
			}
		case "-manifest":
			if v, ok := val(); !ok {
				return usage("-manifest needs a path")
			} else {
				fc.Manifest = v
			}
		case "-importcfg":
			if v, ok := val(); !ok {
				return usage("-importcfg needs a path")
			} else {
				fc.Importcfg = append(fc.Importcfg, v)
			}
		case "-pkgdb":
			if v, ok := val(); !ok {
				return usage("-pkgdb needs a path")
			} else {
				fc.PkgDB = append(fc.PkgDB, v)
			}
		case "-nosmoke":
			fc.Smoke = false
		default:
			return usage("fleet: unknown flag " + args[i])
		}
	}
	if fc.List == "" {
		fc.List = "/host/FLEET.TXT"
	}
	if fc.Root == "" {
		fc.Root = "/host/SRC"
	}
	if fc.OutDir == "" {
		fc.OutDir = "/host"
	}
	if fc.RefDir == "" {
		fc.RefDir = "/host/REF"
	}
	if fc.Manifest == "" {
		fc.Manifest = "/host/FLEET.MF"
	}
	return runFleet(fc)
}

// runGraph is the resolution readout: the graph, the order, the diagnostics.
// No toolchain children — it is the cheap half of the driver's story.
func runGraph(cfg Config) int {
	archives, diags := loadArchives(cfg.Importcfg)
	table, tdiags := loadPkgTable(cfg.PkgDB)
	diags = append(diags, tdiags...)
	g := ImportGraph(cfg.Dir, archives, table)
	diags = append(diags, g.Diags...)
	for _, p := range g.Order {
		vsys.Println("gobuild: order " + p.Path + " (" + pkgKind(p) +
			", " + strconv.Itoa(len(p.Files)) + " files)")
	}
	for _, d := range diags {
		vsys.Println("gobuild: " + d.String())
	}
	if len(diags) > 0 {
		return 1
	}
	vsys.Println("gobuild: graph OK")
	return 0
}

func pkgKind(p *Package) string {
	if p.Local {
		return "local"
	}
	return "archive " + p.Archive
}

func runBuild(cfg Config) int {
	res := Build(cfg)
	for _, p := range res.Order {
		vsys.Println("gobuild: order " + p)
	}
	for _, st := range res.Steps {
		vsys.Println("gobuild: " + st.Label + " " + st.Image +
			" status=" + strconv.FormatInt(st.Status, 10) +
			" ms=" + strconv.FormatInt(st.Ms, 10))
	}
	for _, d := range res.Diags {
		vsys.Println("gobuild: diag " + d.String())
	}
	if res.ELF == "" {
		vsys.Println("gobuild: FAIL (" + strconv.Itoa(len(res.Diags)) + " diagnostics)")
		return 1
	}
	vsys.Println("gobuild: build OK -> " + res.ELF)
	return 0
}
