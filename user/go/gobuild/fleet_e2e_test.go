//go:build !virelai

package main

// A host rehearsal of the in-guest fleet build: the REAL fleet closure
// (every virelai/* program dir's import tree plus the pinned Charm module
// copies) staged as a GOPATH-style source root, driven through Build() with
// the fork's darwin-arm64 cmd/compile + cmd/link binaries. Same driver code
// path, same resolution rules; only the codegen target and the exec seam
// differ from the class-B gate. It exists to catch resolution, stem, argv
// and closure surprises on the host — the VM run is the evidence, this is
// the cheap screen. It is opt-in (GOBUILD_FLEET_E2E=1): the closure is
// ~250 real compiles and the run costs minutes.

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	goparser "go/parser"
	"go/token"
)

// fleetModVer mirrors the spec's pinned module set: module path -> version.
var fleetModVer = map[string]string{
	"charm.land/bubbletea/v2":               "v2.0.9",
	"github.com/aymanbagabas/go-osc52/v2":   "v2.0.1",
	"github.com/charmbracelet/colorprofile": "v0.4.3",
	"github.com/charmbracelet/lipgloss":     "v1.1.0",
	"github.com/charmbracelet/ultraviolet":  "v0.0.0-20260703014108-f5a850f9c2b7",
	"github.com/charmbracelet/x/ansi":       "v0.11.7",
	"github.com/charmbracelet/x/cellbuf":    "v0.0.15",
	"github.com/charmbracelet/x/term":       "v0.2.2",
	"github.com/charmbracelet/x/windows":    "v0.2.2",
	"github.com/clipperhouse/displaywidth":  "v0.11.0",
	"github.com/clipperhouse/uax29/v2":      "v2.7.0",
	"github.com/lucasb-eyer/go-colorful":    "v1.4.0",
	"github.com/mattn/go-isatty":            "v0.0.20",
	"github.com/mattn/go-runewidth":         "v0.0.23",
	"github.com/muesli/cancelreader":        "v0.2.2",
	"github.com/muesli/termenv":             "v0.16.0",
	"github.com/rivo/uniseg":                "v0.4.7",
	"github.com/xo/terminfo":                "v0.0.0-20220910002029-abceb7e1c41e",
	"golang.org/x/sync":                     "v0.21.0",
}

// The archive tier: packages resolved from staged GPKG_*.a, never staged as
// source (their .s gateways need an assembler the guest does not ship).
var fleetArchiveTier = map[string]bool{"virelai/vi": true, "virelai/vsys": true}

func TestFleetRealTreeEndToEnd(t *testing.T) {
	if os.Getenv("GOBUILD_FLEET_E2E") != "1" {
		t.Skip("opt-in host rehearsal: GOBUILD_FLEET_E2E=1 go test ./gobuild")
	}
	repo, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	fork := filepath.Join(repo, "..", "go-virelai")
	tools := filepath.Join(fork, "pkg", "tool", "darwin_arm64")
	compileBin := filepath.Join(tools, "compile")
	linkBin := filepath.Join(tools, "link")
	goBin := filepath.Join(fork, "bin", "go")
	for _, p := range []string{compileBin, linkBin, goBin} {
		if _, err := os.Stat(p); err != nil {
			t.Skip("fork toolchain not provisioned: " + p)
		}
	}
	compileBin, _ = filepath.Abs(compileBin)
	linkBin, _ = filepath.Abs(linkBin)
	goBin, _ = filepath.Abs(goBin)

	modcache, err := exec.Command(goBin, "env", "GOMODCACHE").Output()
	if err != nil {
		t.Skip("go env GOMODCACHE: " + err.Error())
	}
	mc := strings.TrimSpace(string(modcache))

	// --- stage the source root exactly as the spec does --------------------
	// The tree doubles as a GOPATH: <root>/virelai/x is both the driver's
	// local resolution and the go command's GOPATH lookup, so one staged
	// tree serves both halves of the rehearsal.
	gopath := t.TempDir()
	src := filepath.Join(gopath, "src")
	root := t.TempDir()
	listPath := filepath.Join(root, "FLEET.TXT")
	rows, d := parseFleet(mustRead(t, "fleet.txt"))
	if d.Code != "" {
		t.Fatalf("fleet.txt: %+v", d)
	}
	if err := os.WriteFile(listPath, []byte(mustRead(t, "fleet.txt")), 0o644); err != nil {
		t.Fatal(err)
	}
	staged := map[string]bool{}
	var queue [][2]string
	for _, r := range rows {
		if strings.HasPrefix(r.Src, "external:") {
			continue
		}
		queue = append(queue, [2]string{
			filepath.Join(repo, "user", "go", strings.TrimPrefix(r.Src, "virelai/")),
			r.Src})
	}
	var missing []string
	for len(queue) > 0 {
		item := queue[0]
		queue = queue[1:]
		srcDir, rel := item[0], item[1]
		if staged[rel] {
			continue
		}
		ents, err := os.ReadDir(srcDir)
		if err != nil {
			missing = append(missing, rel)
			continue
		}
		dst := filepath.Join(src, rel)
		n := 0
		for _, e := range ents {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") ||
				strings.HasSuffix(e.Name(), "_test.go") {
				continue
			}
			if err := os.MkdirAll(dst, 0o755); err != nil {
				t.Fatal(err)
			}
			b, err := os.ReadFile(filepath.Join(srcDir, e.Name()))
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dst, e.Name()), b, 0o644); err != nil {
				t.Fatal(err)
			}
			n++
		}
		if n == 0 {
			missing = append(missing, rel)
			continue
		}
		staged[rel] = true
		for _, e := range ents {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") ||
				strings.HasSuffix(e.Name(), "_test.go") {
				continue
			}
			full := filepath.Join(srcDir, e.Name())
			b, _ := os.ReadFile(full)
			// Only virelai-selected files contribute imports to the walk —
			// the same rule the driver's buildable() applies in-guest.
			if ok, _ := buildable(full, b); !ok {
				continue
			}
			for _, imp := range goImportsOf(t, full) {
				switch {
				case strings.HasPrefix(imp, "virelai/"):
					if fleetArchiveTier[imp] {
						continue
					}
					queue = append(queue, [2]string{
						filepath.Join(repo, "user", "go",
							strings.TrimPrefix(imp, "virelai/")), imp})
				case strings.Contains(strings.Split(imp, "/")[0], "."):
					md := modDir(mc, imp)
					if md == "" {
						missing = append(missing, imp+" (no pinned module)")
						continue
					}
					queue = append(queue, [2]string{md, imp})
				}
			}
		}
	}
	if len(missing) > 0 {
		t.Fatalf("unstageable fleet sources: %v", missing)
	}
	t.Logf("staged %d package dirs", len(staged))

	// --- archives: every non-local package to a REAL export archive --------
	// go list needs the archive-tier packages (virelai/vi, virelai/vsys)
	// visible to resolve their exports, but the driver must NOT see them as
	// source — so a second GOPATH root gets symlinks: every staged top-level
	// entry, then the two archive-tier dirs beside them.
	gp2 := filepath.Join(root, "gp2", "src")
	for _, ent := range mustReadDir(t, src) {
		if ent.Name() == "virelai" {
			dst := filepath.Join(gp2, "virelai")
			if err := os.MkdirAll(dst, 0o755); err != nil {
				t.Fatal(err)
			}
			for _, sub := range mustReadDir(t, filepath.Join(src, "virelai")) {
				if err := os.Symlink(filepath.Join(src, "virelai", sub.Name()),
					filepath.Join(dst, sub.Name())); err != nil {
					t.Fatal(err)
				}
			}
			for _, extra := range []string{"vi", "vsys"} {
				if err := os.Symlink(filepath.Join(repo, "user", "go", extra),
					filepath.Join(dst, extra)); err != nil {
					t.Fatal(err)
				}
			}
			continue
		}
		if err := os.MkdirAll(gp2, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(filepath.Join(src, ent.Name()),
			filepath.Join(gp2, ent.Name())); err != nil {
			t.Fatal(err)
		}
	}
	// go list -export over all fleet mains by import path, darwin target:
	// the archives must be consumable by the darwin tool binaries.
	var mains []string
	for _, r := range rows {
		if strings.HasPrefix(r.Src, "external:") {
			continue
		}
		mains = append(mains, r.Src)
	}
	listArgs := append([]string{"list", "-export", "-deps", "-e",
		"-f", "{{.ImportPath}}|{{.Export}}"}, mains...)
	cmd := exec.Command(goBin, listArgs...)
	cmd.Env = append(os.Environ(), "GOROOT="+fork, "GOTOOLCHAIN=local",
		"GO111MODULE=off", "CGO_ENABLED=0", "GOFLAGS=",
		"GOPATH="+filepath.Join(root, "gp2"))
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go list: %v\n%s", err, out)
	}
	exports := map[string]string{}
	for _, l := range strings.Split(string(out), "\n") {
		p, x, _ := strings.Cut(l, "|")
		if p != "" && x != "" {
			exports[p] = x
		}
	}
	manifest := filepath.Join(t.TempDir(), "GOIMPORT.CFG")
	var lines []string
	for p, x := range exports {
		lines = append(lines, "packagefile "+p+"="+x)
	}
	sort.Strings(lines)
	if err := os.WriteFile(manifest, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// --- drive the real builds ----------------------------------------------
	prev := execAndWait
	t.Cleanup(func() { execAndWait = prev })
	execAndWait = func(image string, args []string, capturePath string) (int64, int64, []byte, error) {
		bin := compileBin
		if image == linkImage {
			bin = linkBin
		}
		cmd := exec.Command(bin, args...)
		cap2, _ := cmd.CombinedOutput()
		st := int64(0)
		if cmd.ProcessState != nil {
			st = int64(cmd.ProcessState.ExitCode())
		}
		_ = os.WriteFile(capturePath+"~", cap2, 0o644)
		return st, 0, cap2, nil
	}
	prevS := execSmoke
	execSmoke = func(string) string { return "skipped" }
	t.Cleanup(func() { execSmoke = prevS })

	outdir := t.TempDir()
	mf := filepath.Join(t.TempDir(), "FLEET.MF")
	// The REAL policy table when staged — the refusal names then match the
	// in-guest run exactly (dep_unsupported, not the rehearsal's no_package).
	pkgdb := filepath.Join(repo, ".build", "go", "selfhost", "GOPKGS.TXT")
	if _, err := os.Stat(pkgdb); err != nil {
		t.Skip("staged package surface missing — bash tools/go/stage-selfhost.sh")
	}
	pkgdbs := []string{pkgdb}
	rc := runFleet(fleetCfg{List: listPath, Root: src,
		OutDir: outdir, RefDir: filepath.Join(t.TempDir(), "NOREF"),
		Manifest: mf, Importcfg: []string{manifest}, PkgDB: pkgdbs,
		Smoke: false})
	mfb, _ := os.ReadFile(mf)
	t.Logf("manifest:\n%s", mfb)
	if rc != 0 {
		t.Fatalf("fleet rehearsal rc=%d\nmanifest:\n%s", rc, mfb)
	}
	// The card's bar on the host twin: 15 build end to end; GOSTALGIA
	// refuses external_tree (host-pinned sources), and the three Charm apps
	// refuse on out-of-allowlist deps — image/color is deliberately
	// unstaged in tools/go/pkg-table.txt and the card's "never silently
	// widen" makes the named refusal the answer, not a wider allowlist.
	var builtN int
	refused := map[string]string{}
	for _, l := range strings.Split(string(mfb), "\n") {
		f := strings.Split(l, "\t")
		if len(f) < 2 {
			continue
		}
		switch f[1] {
		case "built":
			builtN++
		case "refused", "failed":
			code := ""
			for _, kv := range f {
				if strings.HasPrefix(kv, "code=") {
					code = strings.TrimPrefix(kv, "code=")
				}
			}
			refused[f[0]] = code
		}
	}
	if builtN != 15 {
		t.Fatalf("rehearsal built=%d, want 15\n%s", builtN, mfb)
	}
	wantRefused := map[string]string{
		"GOSTALGIA.ELF": "external_tree",
		"GOFILES.ELF":   "dep_unsupported", // image/color: unstaged, by policy
		"PULSE.ELF":     "dep_unsupported",
		"GOHELP.ELF":    "dep_unsupported",
	}
	if len(refused) != len(wantRefused) {
		t.Fatalf("refusals = %v, want %v\n%s", refused, wantRefused, mfb)
	}
	for name, code := range wantRefused {
		if refused[name] != code {
			t.Fatalf("%s refused %s, want %s\n%s", name, refused[name], code, mfb)
		}
	}
}

// modDir maps an import path to its module-cache dir under the pin map.
func modDir(modcache, imp string) string {
	best := ""
	for m := range fleetModVer {
		if imp == m || strings.HasPrefix(imp, m+"/") {
			if len(m) > len(best) {
				best = m
			}
		}
	}
	if best == "" {
		return ""
	}
	return filepath.Join(modcache, best+"@"+fleetModVer[best],
		strings.TrimPrefix(imp, best))
}

// goImportsOf parses one file's import decls (driver-faithful).
func goImportsOf(t *testing.T, path string) []string {
	t.Helper()
	fset := token.NewFileSet()
	f, err := goparser.ParseFile(fset, path, nil, goparser.ImportsOnly)
	if err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	var out []string
	for _, spec := range f.Imports {
		out = append(out, strings.Trim(spec.Path.Value, `"`))
	}
	return out
}

func mustReadDir(t *testing.T, p string) []os.DirEntry {
	t.Helper()
	ents, err := os.ReadDir(p)
	if err != nil {
		t.Fatal(err)
	}
	return ents
}

func mustRead(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
