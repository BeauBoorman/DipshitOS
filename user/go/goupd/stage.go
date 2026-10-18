package main

// The stage pipeline (M115f, issue #2465). Everything lands in <dst>/
// through the publish-safe seams, signature last:
//
//	inputs   — read <src>/KERNEL.BIN + <src>/BOOTAA64.EFI; check the
//	           magics the host image builder enforces (MZ, DSK1|KRN2)
//	image    — stream the GPT+FAT32 boot volume to <dst>/OS.IMG
//	members  — WriteFileSafe <dst>/KERNEL.BIN + <dst>/BOOTAA64.EFI
//	manifest — WriteFileSafe <dst>/UPDATE.MF (rows name every member's
//	           sha256+bytes plus the image row's version=)
//	sign     — UPDATE.SIG = Ed25519(UPDATE.MF bytes) under the slot-70
//	           `os-update` seed bound to GOUPD.ELF; WriteFileSafe last
//
// A run killed anywhere before the signature lands leaves either a
// missing UPDATE.SIG or one that no longer covers the manifest — both
// are the runner's named refusals, never a half-applied update.

import (
	"crypto/sha256"
	"fmt"
	"strconv"
	"strings"

	"virelai/ed25519"
	"virelai/fatimg"
	"virelai/shlib"
	"virelai/sshlib"
	"virelai/vi"
	"virelai/vsys"
)

// updCfg wires one stage run.
type updCfg struct {
	Src string
	Dst string
}

// upFS is the platform seam: the guest impl (io_virelai.go) rides vi's
// file slots; the host impl (io_other.go) backs the tests. WriteSafe is
// the vi.WriteFileSafe contract — temp sibling, fsync, delete+rename.
type upFS interface {
	ReadFile(path string) ([]byte, error)
	WriteSafe(path string, b []byte) error
	Mkdir(path string) error
	NewImageSink(path string) (fatimg.SeqSink, error)
}

// getSecret is the slot-70 lookup seam; tests substitute it without
// touching the kernel store.
var getSecret = shlib.StoreGet

// secretName is the SECRETS.TXT key the stage seed lives under — bound
// to GOUPD.ELF by the file's fourth field.
const secretName = "os-update"

func failPhase(phase string, err error) int {
	vsys.Println("update: FAIL " + phase + ": " + err.Error())
	return 1
}

func itoa(v int) string { return strconv.Itoa(v) }

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return fmt.Sprintf("%x", sum[:])
}

// loadSeed reads the 64-hex (32-byte) Ed25519 seed from the app-bound
// `os-update` secret entry, mirroring flint/sign.go's loadSeed. The raw
// buffer is wiped before returning; the seed is never logged.
func loadSeed() ([32]byte, error) {
	var seed [32]byte
	var raw [vi.SecretValMax]byte
	defer sshlib.Wipe(raw[:])

	n := getSecret(secretName, raw[:])
	if n < 0 {
		return seed, fmt.Errorf("secret_not_found: %s (is it bound to GOUPD.ELF in SECRETS.TXT?)", secretName)
	}
	if n != 64 {
		return seed, fmt.Errorf("secret_malformed: %s is %d bytes, want 64 hex chars", secretName, n)
	}
	for i := 0; i < 32; i++ {
		hi, ok1 := lowerNibble(raw[2*i])
		lo, ok2 := lowerNibble(raw[2*i+1])
		if !ok1 || !ok2 {
			sshlib.Wipe(seed[:])
			return [32]byte{}, fmt.Errorf("secret_malformed: %s is not lowercase hex", secretName)
		}
		seed[i] = (hi << 4) | lo
	}
	return seed, nil
}

func lowerNibble(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	default:
		return 0, false
	}
}

// updateManifest renders UPDATE.MF: one row per staged artifact. The
// signature covers these bytes verbatim, so the manifest IS the signed
// document — there is no detached envelope format to keep in sync.
func updateManifest(version, imgSum string, imgBytes uint64, kernSum string, kernBytes int, efiSum string, efiBytes int) string {
	return "#v1 os-update\n" +
		"OS.IMG\tkind=image\tsha256=" + imgSum + "\tbytes=" + strconv.FormatUint(imgBytes, 10) + "\tversion=" + version + "\n" +
		"KERNEL.BIN\tkind=member\tsha256=" + kernSum + "\tbytes=" + itoa(kernBytes) + "\tesp=KERNEL.BIN\n" +
		"BOOTAA64.EFI\tkind=member\tsha256=" + efiSum + "\tbytes=" + itoa(efiBytes) + "\tesp=EFI/BOOT/BOOTAA64.EFI\n"
}

// stage runs the publish pipeline. Returns the process exit code.
func stage(fs upFS, cfg updCfg) int {
	// --- inputs --------------------------------------------------------
	kernelBytes, err := fs.ReadFile(cfg.Src + "/KERNEL.BIN")
	if err != nil {
		return failPhase("inputs", fmt.Errorf("read %s/KERNEL.BIN: %w", cfg.Src, err))
	}
	efiBytes, err := fs.ReadFile(cfg.Src + "/BOOTAA64.EFI")
	if err != nil {
		return failPhase("inputs", fmt.Errorf("read %s/BOOTAA64.EFI: %w", cfg.Src, err))
	}
	if len(efiBytes) < 2 || string(efiBytes[:2]) != "MZ" {
		return failPhase("inputs", fmt.Errorf("BOOTAA64.EFI lacks the MZ magic"))
	}
	if len(kernelBytes) < 4 ||
		(string(kernelBytes[:4]) != "DSK1" && string(kernelBytes[:4]) != "KRN2") {
		return failPhase("inputs", fmt.Errorf("KERNEL.BIN lacks a known kernel magic"))
	}
	kernSum := sha256Hex(kernelBytes)
	efiSum := sha256Hex(efiBytes)
	vsys.Println("update: inputs KERNEL.BIN sha256=" + kernSum +
		" BOOTAA64.EFI sha256=" + efiSum)

	// The update's version label travels with the payload: VERSION.TXT's
	// first line (the stager records, never invents). Absent or blank is
	// the honest "-".
	version := "-"
	if vb, err := fs.ReadFile(cfg.Src + "/VERSION.TXT"); err == nil {
		v := strings.TrimSpace(strings.SplitN(string(vb), "\n", 2)[0])
		if v != "" {
			version = v
		}
	}

	// --- image: the GPT+FAT32 boot volume, streamed to the share -------
	if err := fs.Mkdir(cfg.Dst); err != nil {
		return failPhase("image", fmt.Errorf("mkdir %s: %w", cfg.Dst, err))
	}
	sink, err := fs.NewImageSink(cfg.Dst + "/OS.IMG")
	if err != nil {
		return failPhase("image", err)
	}
	hw := &fatimg.HashSink{Sink: sink, H: sha256.New()}
	imgBytes, err := fatimg.WriteImage(hw, efiBytes, kernelBytes, 0)
	if err != nil {
		sink.Close()
		return failPhase("image", err)
	}
	if err := sink.Close(); err != nil {
		return failPhase("image", fmt.Errorf("close OS.IMG: %w", err))
	}
	imgSum := fmt.Sprintf("%x", hw.H.Sum(nil))
	vsys.Println("update: image OS.IMG bytes=" + strconv.FormatUint(imgBytes, 10) +
		" sha256=" + imgSum)

	// --- members: the raw boot files ride beside the image so the host
	// can hash-check the payload pieces without mounting the image ------
	if err := fs.WriteSafe(cfg.Dst+"/KERNEL.BIN", kernelBytes); err != nil {
		return failPhase("members", fmt.Errorf("write KERNEL.BIN: %w", err))
	}
	if err := fs.WriteSafe(cfg.Dst+"/BOOTAA64.EFI", efiBytes); err != nil {
		return failPhase("members", fmt.Errorf("write BOOTAA64.EFI: %w", err))
	}

	// --- manifest + signature ------------------------------------------
	mf := updateManifest(version, imgSum, imgBytes, kernSum, len(kernelBytes), efiSum, len(efiBytes))
	if err := fs.WriteSafe(cfg.Dst+"/UPDATE.MF", []byte(mf)); err != nil {
		return failPhase("manifest", fmt.Errorf("write UPDATE.MF: %w", err))
	}
	seed, err := loadSeed()
	if err != nil {
		return failPhase("sign", err)
	}
	pub := ed25519.EdDerivePublic(seed)
	sig := ed25519.EdSign([]byte(mf), seed)
	sshlib.Wipe(seed[:])
	if err := fs.WriteSafe(cfg.Dst+"/UPDATE.SIG", sig[:]); err != nil {
		return failPhase("sign", fmt.Errorf("write UPDATE.SIG: %w", err))
	}
	vsys.Println("update: manifest UPDATE.MF version=" + version +
		" key=" + sshlib.EncodeHex(pub[:]))
	vsys.Println("update: staged ok version=" + version)
	return 0
}
