package main

// Host tests for the update stager: stage() over a tempdir pair with the
// pinned RFC 8032 test seed. The guest path differences live behind upFS;
// what these tests pin is the manifest grammar, the signature covering it
// byte-for-byte, and the named refusals.

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"virelai/ed25519"
	"virelai/fatimg"
	"virelai/sshlib"
)

// RFC 8032 §7.1 TEST 1 — the fleet's pinned test seed (the same one
// go-flint.spec stages as `agent-sign`; here it is the `os-update` seed).
const testSeedHex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"

func seedBytes(t *testing.T) [32]byte {
	t.Helper()
	seed, ok := sshlib.ParseHex32(testSeedHex)
	if !ok {
		t.Fatal("test seed decode failed")
	}
	return seed
}

// stubSeed installs getSecret answering `os-update` with the test seed.
func stubSeed(t *testing.T) {
	t.Helper()
	old := getSecret
	getSecret = func(name string, out []byte) int {
		if name != secretName {
			return -1
		}
		return copy(out, testSeedHex)
	}
	t.Cleanup(func() { getSecret = old })
}

// put stages one input file under dir.
func put(t *testing.T, dir, name string, b []byte) {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestStagePublishesSignedSet(t *testing.T) {
	stubSeed(t)
	src := filepath.Join(t.TempDir(), "NEXT")
	dst := filepath.Join(t.TempDir(), "UPDATE")
	efi := []byte("MZ" + strings.Repeat("e", 4096))
	kernel := []byte("DSK1" + strings.Repeat("k", 8192))
	put(t, src, "BOOTAA64.EFI", efi)
	put(t, src, "KERNEL.BIN", kernel)
	put(t, src, "VERSION.TXT", []byte("test-v2\n"))

	if rc := stage(hostFS{}, updCfg{Src: src, Dst: dst}); rc != 0 {
		t.Fatalf("stage rc=%d", rc)
	}

	// The payload files.
	for _, name := range []string{"OS.IMG", "KERNEL.BIN", "BOOTAA64.EFI", "UPDATE.MF", "UPDATE.SIG"} {
		if _, err := os.Stat(filepath.Join(dst, name)); err != nil {
			t.Fatalf("staged set missing %s: %v", name, err)
		}
	}

	// The image carries both members at their ESP paths.
	img, err := os.ReadFile(filepath.Join(dst, "OS.IMG"))
	if err != nil {
		t.Fatal(err)
	}
	if got, err := fatimg.ReadFile(img, "KERNEL.BIN"); err != nil || !bytes.Equal(got, kernel) {
		t.Fatalf("image KERNEL.BIN: %v", err)
	}
	if got, err := fatimg.ReadFile(img, "EFI/BOOT/BOOTAA64.EFI"); err != nil || !bytes.Equal(got, efi) {
		t.Fatalf("image BOOTAA64.EFI: %v", err)
	}

	// The signature verifies over the manifest's exact bytes.
	mf, err := os.ReadFile(filepath.Join(dst, "UPDATE.MF"))
	if err != nil {
		t.Fatal(err)
	}
	sigB, err := os.ReadFile(filepath.Join(dst, "UPDATE.SIG"))
	if err != nil {
		t.Fatal(err)
	}
	if len(sigB) != 64 {
		t.Fatalf("UPDATE.SIG is %d bytes, want 64", len(sigB))
	}
	var sig [64]byte
	copy(sig[:], sigB)
	pub := ed25519.EdDerivePublic(seedBytes(t))
	if !ed25519.EdVerify(sig, mf, pub) {
		t.Fatal("UPDATE.SIG does not verify over UPDATE.MF")
	}

	// The manifest records version and both member digests.
	text := string(mf)
	for _, want := range []string{
		"kind=image", "version=test-v2", "kind=member",
		"sha256=" + sha256Hex(kernel), "sha256=" + sha256Hex(efi),
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("UPDATE.MF lacks %q:\n%s", want, text)
		}
	}
}

func TestStageRefusesBadInputs(t *testing.T) {
	stubSeed(t)
	src := filepath.Join(t.TempDir(), "NEXT")
	dst := filepath.Join(t.TempDir(), "UPDATE")
	put(t, src, "BOOTAA64.EFI", []byte("not-a-pe"))
	put(t, src, "KERNEL.BIN", []byte("DSK1"))

	if rc := stage(hostFS{}, updCfg{Src: src, Dst: dst}); rc == 0 {
		t.Fatal("stage accepted a non-MZ BOOTAA64.EFI")
	}
	// Nothing may be published for a refused stage.
	if _, err := os.Stat(filepath.Join(dst, "OS.IMG")); !os.IsNotExist(err) {
		t.Fatal("refused stage left an OS.IMG")
	}
}

func TestStageRefusesMissingSecret(t *testing.T) {
	old := getSecret
	getSecret = func(name string, out []byte) int { return -1 }
	t.Cleanup(func() { getSecret = old })
	src := filepath.Join(t.TempDir(), "NEXT")
	dst := filepath.Join(t.TempDir(), "UPDATE")
	put(t, src, "BOOTAA64.EFI", []byte("MZ"+strings.Repeat("e", 128)))
	put(t, src, "KERNEL.BIN", []byte("DSK1"))

	if rc := stage(hostFS{}, updCfg{Src: src, Dst: dst}); rc == 0 {
		t.Fatal("stage signed without a seed")
	}
	if _, err := os.Stat(filepath.Join(dst, "UPDATE.SIG")); !os.IsNotExist(err) {
		t.Fatal("secretless stage wrote UPDATE.SIG")
	}
}
