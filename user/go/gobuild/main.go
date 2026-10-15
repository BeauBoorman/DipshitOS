package main

import (
	"strconv"
	"strings"

	"virelai/vi"
	"virelai/vsys"
)

// argvEnvpGuard keeps the writable segment's bss end far enough from the
// page boundary for the kernel's packed argv+envp (GOSH.ELF / FLINT.ELF
// carry the same guard).
var argvEnvpGuard [0x1000]byte

func init() {
	argvEnvpGuard[len(argvEnvpGuard)-1] = byte(len(argvEnvpGuard) & 0xff)
}

// GOBUILD.ELF <verb> — the surface the card asks for under gosh's bare-name
// resolution (`gobuild <dir>` / `exec GOBUILD.ELF <dir>`; a standalone ELF
// rather than a shlib builtin keeps the driver's blast radius out of the
// shell — the card's review-note recommendation).
//
//	gobuild [build] <dir> [-o OUT.ELF] [-importcfg CFG]... [-pkgdb TBL]...
//	                                                        compile + link
//	gobuild graph <dir> [-importcfg CFG]... [-pkgdb TBL]...  resolve + print
//	                                                        order
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
	return 2
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
