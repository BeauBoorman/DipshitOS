package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The full-loop host twin: execAndWait is faked with the REAL cmd/compile
// and cmd/link binaries (the darwin-arm64 tools of the same fork — flag
// surface is identical; the virelai objects the guest produces are the same
// shape the live gate asserts on). This is the class-A proof that the
// driver's importcfg/rsp/argv composition actually builds a program.
func TestBuildEndToEndWithRealTools(t *testing.T) {
	fork := filepath.Join("..", "..", "..", "..", "go-virelai")
	tools := filepath.Join(fork, "pkg", "tool", "darwin_arm64")
	compileBin := filepath.Join(tools, "compile")
	linkBin := filepath.Join(tools, "link")
	goBin := filepath.Join(fork, "bin", "go")
	for _, p := range []string{compileBin, linkBin, goBin} {
		if _, err := os.Stat(p); err != nil {
			t.Skip("fork toolchain not provisioned (tools/go/apply.sh): " + p)
		}
	}
	compileBin, _ = filepath.Abs(compileBin)
	linkBin, _ = filepath.Abs(linkBin)
	goBin, _ = filepath.Abs(goBin)

	dir := t.TempDir()
	writeSrc(t, dir, "main.go", `package main
import ("helper"; "strconv")
func main() { println(helper.Shout("ok"), strconv.Itoa(7)) }
`)
	writeSrc(t, dir, "helper/h.go", `package helper
import "strings"
func Shout(s string) string { return strings.ToUpper(s) }
`)

	// Stage the std archive manifest for darwin — same `go list -export
	// -deps` the live gate's setup runs for virelai.
	gopath := t.TempDir()
	mustWrite := func(rel, body string) {
		full := filepath.Join(gopath, "src", rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mainSrc, _ := os.ReadFile(filepath.Join(dir, "main.go"))
	helperSrc, _ := os.ReadFile(filepath.Join(dir, "helper", "h.go"))
	mustWrite("wsp/main.go", string(mainSrc))
	mustWrite("helper/h.go", string(helperSrc))

	cmd := exec.Command(goBin, "list", "-export", "-deps",
		"-f", "{{.ImportPath}}|{{.Export}}", "wsp")
	cmd.Env = append(os.Environ(),
		"GOROOT="+mustAbs(t, fork), "GOTOOLCHAIN=local", "GO111MODULE=off",
		"CGO_ENABLED=0", "GOPATH="+gopath, "GOFLAGS=")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("go list: %v", err)
	}
	manifest := filepath.Join(t.TempDir(), "GOIMPORT.CFG")
	var lines []string
	for _, l := range strings.Split(string(out), "\n") {
		path, export, _ := strings.Cut(l, "|")
		if path == "" || export == "" || path == "wsp" || path == "helper" {
			continue
		}
		lines = append(lines, "packagefile "+path+"="+export)
	}
	if err := os.WriteFile(manifest, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// The exec seam backed by the real tools: the driver's arg vector is
	// run verbatim; the child's combined output becomes the captured bytes.
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
		// Persist the capture like the guest's stream-bound file does.
		_ = os.WriteFile(capturePath, cap2, 0o644)
		return st, 0, cap2, nil
	}

	res := Build(Config{Dir: dir, Importcfg: []string{manifest},
		Out: filepath.Join(dir, "PROG")})
	if res.ELF == "" {
		t.Fatalf("build failed: %v", res.Diags)
	}
	if len(res.Steps) != 3 { // helper, main, link
		t.Fatalf("steps = %v", res.Steps)
	}
	// The product runs: the guest's loader checks are the gate's, but the
	// host twin still proves the archive composition is runnable. Darwin
	// arm64 needs an ad-hoc signature cmd/link does not apply — the `go`
	// driver does it post-link, so we do the same here.
	_ = exec.Command("codesign", "-s", "-", res.ELF).Run()
	if run, err := exec.Command(res.ELF).CombinedOutput(); err != nil {
		t.Fatalf("product did not run: %v\n%s", err, run)
	} else if !strings.Contains(string(run), "OK") {
		t.Fatalf("product output = %q", run)
	}
}

func mustAbs(t *testing.T, p string) string {
	t.Helper()
	a, err := filepath.Abs(p)
	if err != nil {
		t.Fatal(err)
	}
	return a
}
