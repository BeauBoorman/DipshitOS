package main

// Host tests for the release driver: the manifest parsers and the assemble
// pipeline over a tempdir. The image writer's own tests moved with it to
// user/go/fatimg (M115f #2465 — goupd shares the writer).

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"virelai/fatimg"
)

func TestParsePins(t *testing.T) {
	rows, err := parsePins("#v1\nBOOTAA64.EFI\tsha256=abc\tbytes=12\nKERNEL.BIN\tsha256=def\tbytes=34\n")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0].Name != "BOOTAA64.EFI" || rows[0].SHA256 != "abc" || rows[0].Bytes != 12 {
		t.Fatalf("bad pin rows: %+v", rows)
	}
	if _, err := parsePins("BOOTAA64.EFI\tsha256=abc\n"); err == nil {
		t.Fatal("short pin row accepted")
	}
}

func TestParseFleetManifest(t *testing.T) {
	mf := "#v1 fleet manifest\n" +
		"GOCALC.ELF\tbuilt\tsrc=s1\ttc=t\tguest=g1\thost=h1\thash=match\tsmoke=exited=0\tms=5\n" +
		"GOFILES.ELF\trefused\tsrc=-\ttc=t\tguest=-\thost=-\thash=-\tsmoke=-\tms=0\tcode=dep_unsupported\n"
	rows, err := parseFleetManifest(mf)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0].State != "built" || rows[0].Guest != "g1" {
		t.Fatalf("bad fleet rows: %+v", rows)
	}
	if rows[1].State != "refused" || rows[1].Code != "dep_unsupported" {
		t.Fatalf("refused row parsed wrong: %+v", rows[1])
	}
}

func TestReleaseManifestRoundtrip(t *testing.T) {
	in := []relRow{
		{Path: "RELEASE.IMG", Kind: "image", SHA256: "aa", Bytes: 100},
		{Path: "GOCALC.ELF", Kind: "fleet", SHA256: "bb", Bytes: 200},
	}
	rows, err := parseReleaseManifest(renderReleaseManifest(in))
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0] != in[0] || rows[1] != in[1] {
		t.Fatalf("roundtrip mismatch: %+v", rows)
	}
}

// TestAssembleEndToEnd stages a fake release root and runs the assemble
// verb: pins verify, the built fleet row lands in the manifest, the image
// parses, and the bundle is self-describing.
func TestAssembleEndToEnd(t *testing.T) {
	root := t.TempDir()
	bundle := filepath.Join(root, "BUNDLE")
	efi := []byte("MZ" + strings.Repeat("e", 1024))
	kernel := []byte("DSK1" + strings.Repeat("k", 2048))
	gocalc := []byte("fake-elf-gocalc")

	put := func(rel string, b []byte) {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	put("BOOTAA64.EFI", efi)
	put("KERNEL.BIN", kernel)
	put("APPS.TXT", []byte("GOCALC.ELF | Calc | c | dock=true\n"))
	put("GORELEASE.ELF", []byte("fake-driver"))
	put("BUNDLE/GOCALC.ELF", gocalc)

	sha := func(b []byte) string { return fmt.Sprintf("%x", sha256.Sum256(b)) }
	put("BOOTIN.MF", []byte(
		"#v1\nBOOTAA64.EFI\tsha256="+sha(efi)+"\tbytes="+fmt.Sprint(len(efi))+"\n"+
			"KERNEL.BIN\tsha256="+sha(kernel)+"\tbytes="+fmt.Sprint(len(kernel))+"\n"))
	put("FLEET.MF", []byte(
		"#v1\nGOCALC.ELF\tbuilt\tsrc=s\ttc=t\tguest="+sha(gocalc)+"\thost=h\thash=mismatch:paths-buildid\tsmoke=-\tms=1\n"+
			"GOSTALGIA.ELF\trefused\tsrc=-\ttc=t\tguest=-\thost=-\thash=-\tsmoke=-\tms=0\tcode=external_tree\n"))

	cfg := relCfg{Root: root}
	cfg.defaults()
	if rc := runAssemble(cfg); rc != 0 {
		t.Fatalf("assemble rc=%d", rc)
	}

	// The image parses and carries the pinned inputs.
	img, err := os.ReadFile(cfg.Image)
	if err != nil {
		t.Fatal(err)
	}
	kb, err := fatimg.ReadFile(img, "KERNEL.BIN")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(kb, kernel) {
		t.Fatal("image KERNEL.BIN mismatch")
	}

	// The manifest describes the bundle.
	mf, err := os.ReadFile(filepath.Join(bundle, "RELEASE.MF"))
	if err != nil {
		t.Fatal(err)
	}
	rows, err := parseReleaseManifest(string(mf))
	if err != nil {
		t.Fatal(err)
	}
	byPath := map[string]relRow{}
	for _, r := range rows {
		byPath[r.Path] = r
	}
	if byPath["GOCALC.ELF"].SHA256 != sha(gocalc) {
		t.Fatal("fleet row sha mismatch")
	}
	if byPath["APPS.TXT"].Kind != "asset" || byPath["SETTINGS.TXT"].Kind != "config" ||
		byPath["GORELEASE.ELF"].Kind != "driver" || byPath["RELEASE.IMG"].Kind != "image" {
		t.Fatalf("manifest kinds wrong: %+v", byPath)
	}
	got, err := os.ReadFile(filepath.Join(bundle, "SETTINGS.TXT"))
	if err != nil || string(got) != bundleSettings {
		t.Fatalf("bundle settings wrong: %q %v", got, err)
	}
}

// TestWriteImageByteParity is the contract this whole card hinges on: the
// Go writer's output must be byte-identical to image/mkfat32.py's for the
// same inputs (the reference builder is deterministic by design). The
// live-release spec runs the same compare in-guest on real inputs; here we
// pin it for synthetic ones. Skipped when python3 or the reference is
// absent rather than failing on an environment problem.

func TestAssemblePinMismatchRefuses(t *testing.T) {
	root := t.TempDir()
	put := func(rel string, b []byte) {
		p := filepath.Join(root, rel)
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, b, 0o644)
	}
	put("BOOTAA64.EFI", []byte("MZ"))
	put("KERNEL.BIN", []byte("DSK1"))
	put("BOOTIN.MF", []byte("BOOTAA64.EFI\tsha256=deadbeef\tbytes=2\nKERNEL.BIN\tsha256=x\tbytes=4\n"))
	put("FLEET.MF", []byte("GOCALC.ELF\tbuilt\tguest=g\n"))
	cfg := relCfg{Root: root}
	cfg.defaults()
	if rc := runAssemble(cfg); rc == 0 {
		t.Fatal("a pin mismatch assembled successfully")
	}
}
