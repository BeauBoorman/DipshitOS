package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The published SHA-256 vectors (FIPS 180-4 / RFC 4634): the manifest's
// hashes are only evidence if the primitive is right.
func TestSHA256Vectors(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
		{"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
		{"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
			"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"},
	} {
		if got := sha256HexOf([]byte(tc.in)); got != tc.want {
			t.Fatalf("sha256(%q) = %s, want %s", tc.in, got, tc.want)
		}
	}
	// Multi-write crossing the 64-byte block boundary.
	st := sha256New()
	st.Write([]byte("abcdbcdecdefdefgefghfghighijhijk"))
	st.Write([]byte("ijkljklmklmnlmnomnopnopq"))
	if got := hexOfSum(st.Sum()); got !=
		"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" {
		t.Fatalf("two-write sha256 = %s", got)
	}
}

func TestParseFleet(t *testing.T) {
	rows, d := parseFleet("# comment\n\nGOCALC.ELF virelai/calc\nGOSTALGIA.ELF external:gostalgia\n")
	if d.Code != "" || len(rows) != 2 {
		t.Fatalf("parseFleet = %v, %+v", rows, d)
	}
	if rows[0].Name != "GOCALC.ELF" || rows[0].Src != "virelai/calc" {
		t.Fatalf("row0 = %+v", rows[0])
	}
	if _, d := parseFleet("nonsense\n"); d.Code != "bad_fleet" {
		t.Fatalf("malformed row must refuse by name: %+v", d)
	}
	// The committed list pins exactly the 15 apps.txt .ELF rows plus the
	// four non-row Go ELFs, in one parseable file.
	committed, err := os.ReadFile("fleet.txt")
	if err != nil {
		t.Fatal(err)
	}
	rows, d = parseFleet(string(committed))
	if d.Code != "" {
		t.Fatalf("committed fleet.txt must parse: %+v", d)
	}
	if len(rows) != 19 {
		t.Fatalf("fleet.txt rows = %d, want 19", len(rows))
	}
	names := map[string]bool{}
	for _, r := range rows {
		names[r.Name] = true
	}
	for _, want := range []string{"GOCALC.ELF", "NOTE.ELF", "GOEDIT.ELF",
		"GOFILES.ELF", "GOTERM.ELF", "WEB.ELF", "PULSE.ELF", "GOSH.ELF",
		"GOHELP.ELF", "GOTOP.ELF", "GOSET.ELF", "GODIFF.ELF", "GOVIEW.ELF",
		"GOSOUND.ELF", "GOSTALGIA.ELF", "FLINT.ELF", "STORE.ELF",
		"AGENTD.ELF", "GOBUILD.ELF"} {
		if !names[want] {
			t.Fatalf("fleet.txt missing %s", want)
		}
	}
}

// The fleet root tier: an import that is not under the program dir resolves
// under the staged root before the deny/archive tiers.
func TestRootTierResolves(t *testing.T) {
	root := t.TempDir()
	writeSrc(t, root, "app/main.go", `package main
import ("virelai/helper"; "fmt")
func main() { fmt.Println(helper.V) }
`)
	writeSrc(t, root, "virelai/helper/h.go", `package helper
import "strings"
var V = strings.ToUpper("v")
`)
	manifest := filepath.Join(t.TempDir(), "GOIMPORT.CFG")
	if err := os.WriteFile(manifest, []byte(
		"packagefile fmt=/host/GPKG_FMT.a\npackagefile strings=/host/GPKG_STRINGS.a\n"),
		0o644); err != nil {
		t.Fatal(err)
	}
	f := &fakeExec{}
	withFakeExec(t, f)
	dir := filepath.Join(root, "app")
	res := Build(Config{Dir: dir, Root: root, Importcfg: []string{manifest},
		Out: filepath.Join(t.TempDir(), "APP.ELF")})
	if res.ELF == "" {
		t.Fatalf("rooted build failed: %v", res.Diags)
	}
	if !contains(res.Order, "virelai/helper") {
		t.Fatalf("order = %v", res.Order)
	}
	// The compiled source set feeds the manifest's source hash.
	if len(res.SrcFiles) != 2 {
		t.Fatalf("SrcFiles = %v", res.SrcFiles)
	}
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// A fleet run end to end on host stubs: one buildable row, one external
// refusal; the manifest carries every card-required field.
func TestRunFleetEndToEnd(t *testing.T) {
	root := t.TempDir()
	writeSrc(t, root, "virelai/tiny/main.go", `package main
import "strconv"
func main() { println(strconv.Itoa(1)) }
`)
	list := filepath.Join(t.TempDir(), "FLEET.TXT")
	if err := os.WriteFile(list, []byte(
		"TINY.ELF virelai/tiny\nEXTAPP.ELF external:somewhere\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	manifest := filepath.Join(t.TempDir(), "GOIMPORT.CFG")
	if err := os.WriteFile(manifest, []byte(
		"packagefile strconv=/host/GPKG_STRCONV.a\npackagefile runtime=/host/GPKG_RUNTIME.a\n"),
		0o644); err != nil {
		t.Fatal(err)
	}
	outdir := t.TempDir()
	mf := filepath.Join(t.TempDir(), "FLEET.MF")
	f := &fakeExec{}
	withFakeExec(t, f)
	prev := execSmoke
	execSmoke = func(name string) string { return "exited=0" }
	t.Cleanup(func() { execSmoke = prev })

	rc := runFleet(fleetCfg{List: list, Root: root, OutDir: outdir,
		RefDir: filepath.Join(t.TempDir(), "NONE"), Manifest: mf,
		Importcfg: []string{manifest}, Smoke: true})
	if rc != 0 {
		t.Fatalf("runFleet rc = %d", rc)
	}
	mfb, err := os.ReadFile(mf)
	if err != nil {
		t.Fatal(err)
	}
	mftext := string(mfb)
	for _, want := range []string{
		"TINY.ELF\tbuilt\tsrc=", "\ttc=", "\tguest=", "\thost=-",
		"hash=host-missing", "smoke=exited=0",
		"EXTAPP.ELF\trefused",
	} {
		if !strings.Contains(mftext, want) {
			t.Fatalf("manifest missing %q:\n%s", want, mftext)
		}
	}
	if !strings.Contains(mftext, "EXTAPP.ELF\trefused\tsrc=-\ttc=") ||
		!strings.Contains(mftext, "code=external_tree") {
		t.Fatalf("external row must name its refusal:\n%s", mftext)
	}
}

// The hash verdict names each state: identical hashes match, a missing ref
// is host-missing, a small drift is paths-buildid, a large one size-delta.
func TestHashVerdict(t *testing.T) {
	if v, _ := hashVerdict("aa", "aa", 10, 10); v != "match" {
		t.Fatalf("match = %q", v)
	}
	if v, _ := hashVerdict("aa", "", 10, 0); v != "host-missing" {
		t.Fatalf("missing ref = %q", v)
	}
	if v, _ := hashVerdict("aa", "bb", 100, 102); v != "mismatch:paths-buildid" {
		t.Fatalf("small delta = %q", v)
	}
	if v, _ := hashVerdict("aa", "bb", 100, 200); v != "mismatch:size-delta" {
		t.Fatalf("large delta = %q", v)
	}
}
