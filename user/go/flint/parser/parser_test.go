package parser

import (
	"encoding/hex"
	"encoding/json"
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	"virelai/sshlib"
)

var updateManifest = flag.Bool("update-manifest", false, "regenerate MANIFEST.json and testdata/canon/*.txt")

type manifestDoc struct {
	Version int            `json:"version"`
	Files   int            `json:"files"`
	Atoms   []manifestAtom `json:"atoms"`
}

type manifestAtom struct {
	File    string `json:"file"`
	Kind    string `json:"kind"`
	Name    string `json:"name"`
	Start   uint32 `json:"start"`
	End     uint32 `json:"end"`
	Hash    string `json:"hash"`
	SigHash string `json:"sig_hash"`
}

type canonCase struct {
	fixture  string
	relFile  string
	atomName string
	kind     string
}

var canonCases = []canonCase{
	{fixture: "go_sample_Add.txt", relFile: "go/sample.go", atomName: "sample.Add", kind: "fn"},
	{fixture: "go_methods_Scale.txt", relFile: "go/methods.go", atomName: "shapes.Rect.Scale", kind: "method"},
	{fixture: "go_iota_Green.txt", relFile: "go/iota.go", atomName: "flags.Green", kind: "const"},
	{fixture: "zig_sample_add.txt", relFile: "zig/sample.zig", atomName: "sample.add", kind: "fn"},
	{fixture: "zig_containers_Packed.txt", relFile: "zig/containers.zig", atomName: "containers.Packed", kind: "struct"},
	{fixture: "zig_sample_test.txt", relFile: "zig/sample.zig", atomName: "sample.test:add works", kind: "test"},
}

func parseCorpusDir(t *testing.T, root string) ([]Atom, int, int) {
	t.Helper()
	var all []Atom
	var goFiles, zigFiles int
	for _, sub := range []string{"go", "zig"} {
		dir := filepath.Join(root, sub)
		entries, err := os.ReadDir(dir)
		if err != nil {
			t.Fatalf("readdir %s: %v", dir, err)
		}
		var names []string
		for _, e := range entries {
			if !e.IsDir() {
				names = append(names, e.Name())
			}
		}
		sort.Strings(names)
		for _, name := range names {
			rel := sub + "/" + name
			p, ok := ForPath(rel)
			if !ok {
				t.Fatalf("no parser for %s", rel)
			}
			src, err := os.ReadFile(filepath.Join(dir, name))
			if err != nil {
				t.Fatalf("read %s: %v", rel, err)
			}
			atoms, err := p.Parse(rel, src)
			if err != nil {
				t.Fatalf("parse %s: %v", rel, err)
			}
			all = append(all, atoms...)
			if sub == "go" {
				goFiles++
			} else {
				zigFiles++
			}
		}
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].File != all[j].File {
			return all[i].File < all[j].File
		}
		return all[i].Start < all[j].Start
	})
	return all, goFiles, zigFiles
}

func TestCorpus(t *testing.T) {
	corpusRoot := filepath.Join("..", "testdata", "corpus")
	atoms, goFiles, zigFiles := parseCorpusDir(t, corpusRoot)
	if goFiles != 50 || zigFiles != 50 {
		t.Fatalf("corpus file counts: go=%d zig=%d, want 50 and 50", goFiles, zigFiles)
	}

	manifestPath := filepath.Join(corpusRoot, "MANIFEST.json")
	if *updateManifest {
		doc := manifestDoc{
			Version: 1,
			Files:   goFiles + zigFiles,
			Atoms:   make([]manifestAtom, len(atoms)),
		}
		for i, a := range atoms {
			doc.Atoms[i] = manifestAtom{
				File:    a.File,
				Kind:    a.Kind,
				Name:    a.Name,
				Start:   a.Start,
				End:     a.End,
				Hash:    hex.EncodeToString(a.Hash[:]),
				SigHash: hex.EncodeToString(a.SigHash[:]),
			}
		}
		b, err := json.MarshalIndent(doc, "", "  ")
		if err != nil {
			t.Fatalf("marshal manifest: %v", err)
		}
		b = append(b, '\n')
		if err := os.WriteFile(manifestPath, b, 0o644); err != nil {
			t.Fatalf("write manifest: %v", err)
		}
		canonDir := filepath.Join("..", "testdata", "canon")
		if err := os.MkdirAll(canonDir, 0o755); err != nil {
			t.Fatalf("mkdir canon: %v", err)
		}
		for _, cc := range canonCases {
			src, err := os.ReadFile(filepath.Join(corpusRoot, filepath.FromSlash(cc.relFile)))
			if err != nil {
				t.Fatalf("read %s: %v", cc.relFile, err)
			}
			m, err := CanonMap(cc.relFile, src)
			if err != nil {
				t.Fatalf("CanonMap %s: %v", cc.relFile, err)
			}
			txt, ok := m[cc.atomName]
			if !ok {
				t.Fatalf("missing atom %s in %s", cc.atomName, cc.relFile)
			}
			if err := os.WriteFile(filepath.Join(canonDir, cc.fixture), []byte(txt+"\n"), 0o644); err != nil {
				t.Fatalf("write canon %s: %v", cc.fixture, err)
			}
		}
	}

	raw, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatalf("read MANIFEST.json: %v", err)
	}
	var want manifestDoc
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatalf("unmarshal MANIFEST.json: %v", err)
	}
	if want.Version != 1 || want.Files != 100 {
		t.Fatalf("manifest header: version=%d files=%d, want 1 and 100", want.Version, want.Files)
	}
	if len(atoms) != len(want.Atoms) {
		t.Fatalf("atom count: got %d, manifest has %d", len(atoms), len(want.Atoms))
	}
	for i, a := range atoms {
		m := want.Atoms[i]
		gotHash := hex.EncodeToString(a.Hash[:])
		gotSig := hex.EncodeToString(a.SigHash[:])
		if a.File != m.File || a.Kind != m.Kind || a.Name != m.Name ||
			a.Start != m.Start || a.End != m.End || gotHash != m.Hash || gotSig != m.SigHash {
			t.Fatalf("atom[%d] mismatch:\n got: %s %s %s [%d..%d] %s %s\nwant: %s %s %s [%d..%d] %s %s",
				i, a.File, a.Kind, a.Name, a.Start, a.End, gotHash, gotSig,
				m.File, m.Kind, m.Name, m.Start, m.End, m.Hash, m.SigHash)
		}
	}

	// Verify sample.go (4 atoms: 2 fn, 1 struct, 1 const) and sample.zig (6 atoms: 3 fn, 1 struct, 1 const, 1 test).
	goSampleKinds := map[string]int{}
	zigSampleKinds := map[string]int{}
	goKinds := map[string]int{}
	zigKinds := map[string]int{}
	hasReceiverMeta := 0
	for _, a := range atoms {
		if strings.HasPrefix(a.File, "go/") {
			goKinds[a.Kind]++
			if a.File == "go/sample.go" {
				goSampleKinds[a.Kind]++
			}
			if a.Kind == "method" {
				if a.Meta["receiver"] == "" {
					t.Fatalf("method %s missing Meta[receiver]", a.Name)
				}
				if strings.Contains(a.Name, "*") {
					t.Fatalf("method %s retained pointer in qualified name", a.Name)
				}
				hasReceiverMeta++
			}
		} else {
			zigKinds[a.Kind]++
			if a.File == "zig/sample.zig" {
				zigSampleKinds[a.Kind]++
			}
		}
	}
	if goSampleKinds["fn"] != 2 || goSampleKinds["struct"] != 1 || goSampleKinds["const"] != 1 || len(goSampleKinds) != 3 {
		t.Fatalf("go/sample.go kinds = %v, want 2 fn, 1 struct, 1 const", goSampleKinds)
	}
	if zigSampleKinds["fn"] != 3 || zigSampleKinds["struct"] != 1 || zigSampleKinds["const"] != 1 || zigSampleKinds["test"] != 1 || len(zigSampleKinds) != 4 {
		t.Fatalf("zig/sample.zig kinds = %v, want 3 fn, 1 struct, 1 const, 1 test", zigSampleKinds)
	}
	for _, k := range []string{"fn", "method", "test", "struct", "interface", "type", "type_alias", "const", "var"} {
		if goKinds[k] < 3 {
			t.Fatalf("go kind %q count = %d, want >= 3", k, goKinds[k])
		}
	}
	for _, k := range []string{"fn", "test", "struct", "enum", "union", "const", "var"} {
		if zigKinds[k] < 3 {
			t.Fatalf("zig kind %q count = %d, want >= 3", k, zigKinds[k])
		}
	}
	if hasReceiverMeta < 3 {
		t.Fatalf("methods with receiver metadata = %d, want >= 3", hasReceiverMeta)
	}
}

func parseSingleAtom(t *testing.T, relFile string) Atom {
	t.Helper()
	path := filepath.Join("..", "testdata", "corpus", filepath.FromSlash(relFile))
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", relFile, err)
	}
	p, ok := ForPath(relFile)
	if !ok {
		t.Fatalf("no parser for %s", relFile)
	}
	atoms, err := p.Parse(relFile, src)
	if err != nil {
		t.Fatalf("parse %s: %v", relFile, err)
	}
	if len(atoms) != 1 {
		t.Fatalf("%s: got %d atoms, want 1", relFile, len(atoms))
	}
	return atoms[0]
}

func TestPairs(t *testing.T) {
	for _, lang := range []struct {
		dir, ext string
	}{
		{dir: "go", ext: ".go"},
		{dir: "zig", ext: ".zig"},
	} {
		// 1. Rename only (fn_a / fn_a_renamed): both hashes equal.
		renA := parseSingleAtom(t, lang.dir+"/pair_rename_a"+lang.ext)
		renB := parseSingleAtom(t, lang.dir+"/pair_rename_b"+lang.ext)
		if !strings.HasSuffix(renA.Name, ".fn_a") || !strings.HasSuffix(renB.Name, ".fn_a_renamed") {
			t.Fatalf("%s rename names = (%s, %s), want *.fn_a and *.fn_a_renamed", lang.dir, renA.Name, renB.Name)
		}
		if renA.Hash != renB.Hash || renA.SigHash != renB.SigHash {
			t.Fatalf("%s rename: hashes differed", lang.dir)
		}

		// 2. Body edit: hash differs, sig_hash equal.
		bodyA := parseSingleAtom(t, lang.dir+"/pair_body_a"+lang.ext)
		bodyB := parseSingleAtom(t, lang.dir+"/pair_body_b"+lang.ext)
		if bodyA.Hash == bodyB.Hash {
			t.Fatalf("%s body edit: hash did not change", lang.dir)
		}
		if bodyA.SigHash != bodyB.SigHash {
			t.Fatalf("%s body edit: sig_hash changed", lang.dir)
		}

		// 3. Whitespace/comment-only: both equal.
		wsA := parseSingleAtom(t, lang.dir+"/pair_ws_a"+lang.ext)
		wsB := parseSingleAtom(t, lang.dir+"/pair_ws_b"+lang.ext)
		if wsA.Hash != wsB.Hash || wsA.SigHash != wsB.SigHash {
			t.Fatalf("%s whitespace/comment edit: hashes differed", lang.dir)
		}

		// 4. Parameter edit: both differ.
		paramA := parseSingleAtom(t, lang.dir+"/pair_param_a"+lang.ext)
		paramB := parseSingleAtom(t, lang.dir+"/pair_param_b"+lang.ext)
		if paramA.Hash == paramB.Hash || paramA.SigHash == paramB.SigHash {
			t.Fatalf("%s param edit: expected both hash and sig_hash to differ", lang.dir)
		}

		// 5. Field reorder: hash differs.
		fieldA := parseSingleAtom(t, lang.dir+"/pair_field_a"+lang.ext)
		fieldB := parseSingleAtom(t, lang.dir+"/pair_field_b"+lang.ext)
		if fieldA.Hash == fieldB.Hash {
			t.Fatalf("%s field reorder: hash did not differ", lang.dir)
		}
	}
}

func TestRefusals(t *testing.T) {
	cases := []struct {
		file string
		code string
		off  int
	}{
		{file: "anon_ret.zig", code: "parse_unsupported", off: 14},
		{file: "bad.go", code: "syntax", off: 29},
	}
	for _, tc := range cases {
		path := filepath.Join("..", "testdata", "corpus", "refuse", tc.file)
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", tc.file, err)
		}
		p, ok := ForPath(tc.file)
		if !ok {
			t.Fatalf("no parser for %s", tc.file)
		}
		_, err = p.Parse(tc.file, src)
		if err == nil {
			t.Fatalf("%s: expected ParseError, got nil", tc.file)
		}
		pe, ok := err.(*ParseError)
		if !ok {
			t.Fatalf("%s: error %T (%v) is not *ParseError", tc.file, err, err)
		}
		if pe.Code != tc.code || pe.Offset != tc.off {
			t.Fatalf("%s: got code=%q offset=%d, want code=%q offset=%d",
				tc.file, pe.Code, pe.Offset, tc.code, tc.off)
		}
	}

	// Verify usingnamespace is ignored by the Zig scanner without error.
	zp, _ := ForPath("legacy.zig")
	atoms, err := zp.Parse("legacy.zig", []byte("pub usingnamespace @import(\"other.zig\");\npub fn kept() void {}\n"))
	if err != nil {
		t.Fatalf("usingnamespace parse failed: %v", err)
	}
	if len(atoms) != 1 || atoms[0].Name != "legacy.kept" {
		t.Fatalf("usingnamespace atoms = %+v, want [legacy.kept]", atoms)
	}
}

func TestCanon(t *testing.T) {
	corpusRoot := filepath.Join("..", "testdata", "corpus")
	canonDir := filepath.Join("..", "testdata", "canon")
	for _, cc := range canonCases {
		wantBytes, err := os.ReadFile(filepath.Join(canonDir, cc.fixture))
		if err != nil {
			t.Fatalf("read canon fixture %s: %v", cc.fixture, err)
		}
		want := strings.TrimRight(string(wantBytes), "\r\n")

		srcPath := filepath.Join(corpusRoot, filepath.FromSlash(cc.relFile))
		src, err := os.ReadFile(srcPath)
		if err != nil {
			t.Fatalf("read %s: %v", cc.relFile, err)
		}
		m, err := CanonMap(cc.relFile, src)
		if err != nil {
			t.Fatalf("CanonMap %s: %v", cc.relFile, err)
		}
		got, ok := m[cc.atomName]
		if !ok {
			t.Fatalf("atom %s not found in %s", cc.atomName, cc.relFile)
		}
		if got != want {
			t.Fatalf("canon %s (%s):\n got: %q\nwant: %q", cc.fixture, cc.atomName, got, want)
		}

		// Cross-check that hashing "FLINT-ATOM/1\x00" || kind || "\x00" || want equals Atom.Hash.
		p, _ := ForPath(cc.relFile)
		atoms, err := p.Parse(cc.relFile, src)
		if err != nil {
			t.Fatalf("parse %s: %v", cc.relFile, err)
		}
		var found *Atom
		for i := range atoms {
			if atoms[i].Name == cc.atomName {
				found = &atoms[i]
				break
			}
		}
		if found == nil {
			t.Fatalf("atom %s missing from Parse(%s)", cc.atomName, cc.relFile)
		}
		expectHash := sshlib.SHA256Sum(append([]byte("FLINT-ATOM/1\x00"+cc.kind+"\x00"), want...))
		if found.Hash != expectHash {
			t.Fatalf("canon %s hash mismatch: atom=%x recomputed=%x", cc.fixture, found.Hash, expectHash)
		}
	}

	// Verify Zig scientific notation literals stay a single token in CanonMap.
	m, err := CanonMap("sci.zig", []byte("const eps: f64 = 1e-5;\nconst hexp: f64 = 0x1p-4;\n"))
	if err != nil {
		t.Fatalf("CanonMap sci.zig: %v", err)
	}
	if m["sci.eps"] != "const _ : f64 = 1e-5 ;" || m["sci.hexp"] != "const _ : f64 = 0x1p-4 ;" {
		t.Fatalf("scientific notation canon = %v", m)
	}
}

func TestZigOracle(t *testing.T) {
	zigBin, err := exec.LookPath("zig")
	if err != nil {
		t.Fatalf("required toolchain binary 'zig' not found on PATH: %v", err)
	}
	zigDir := filepath.Join("..", "testdata", "corpus", "zig")
	entries, err := os.ReadDir(zigDir)
	if err != nil {
		t.Fatalf("readdir %s: %v", zigDir, err)
	}
	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".zig") {
			files = append(files, filepath.Join(zigDir, e.Name()))
		}
	}
	sort.Strings(files)
	if len(files) != 50 {
		t.Fatalf("zig corpus count = %d, want 50", len(files))
	}

	oraclePath := filepath.Join("..", "..", "..", "..", "tools", "flint", "zigdecls.zig")
	args := append([]string{"run", oraclePath, "--"}, files...)
	cmd := exec.Command(zigBin, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("zig run zigdecls.zig failed: %v\n%s", err, string(out))
	}

	var wantLines []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		wantLines = append(wantLines, line)
	}

	var gotLines []string
	zp, _ := ForPath("sample.zig")
	for _, f := range files {
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("read %s: %v", f, err)
		}
		atoms, err := zp.Parse(f, src)
		if err != nil {
			t.Fatalf("scanner parse %s: %v", f, err)
		}
		for _, a := range atoms {
			row := strings.Join([]string{
				a.File,
				a.Kind,
				a.Name,
				strconv.Itoa(int(a.Start)),
				strconv.Itoa(int(a.End)),
			}, "\t")
			gotLines = append(gotLines, row)
		}
	}

	if len(gotLines) != len(wantLines) {
		t.Fatalf("oracle decl count mismatch: scanner=%d zigdecls=%d\nscanner:\n%s\nzigdecls:\n%s",
			len(gotLines), len(wantLines),
			strings.Join(gotLines, "\n"),
			strings.Join(wantLines, "\n"))
	}
	for i := range gotLines {
		if gotLines[i] != wantLines[i] {
			t.Fatalf("oracle row %d mismatch:\n scanner: %s\nzigdecls: %s", i, gotLines[i], wantLines[i])
		}
	}
}
