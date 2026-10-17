package main

// The release pipeline (M112c, issue #2415). `gorelease release` runs the
// whole thing in one guest process:
//
//   fleet    — spawn the M112a fleet build as a child (GOBUILD.ELF fleet),
//              its products landing directly in the bundle dir. Card input:
//              "the fleet ELFs ... from M112a's manifest" — the manifest it
//              writes is the provenance the bundle is verified against.
//   inputs   — read the sha-pinned host inputs (BOOTIN.MF vs the staged
//              BOOTAA64.EFI / KERNEL.BIN bytes + their MZ / DSK1|KRN2
//              magics, the same checks make-image.sh runs).
//   bundle   — verify every `built` FLEET.MF row is on the bundle with the
//              recorded guest= sha256, then add APPS.TXT, SETTINGS.TXT, the
//              driver itself, and the share assets that are present.
//   image    — stream the GPT+FAT32 boot volume to the share through the
//              seqSink (image.go; kernel FAT stays read-only by design).
//   manifest — write RELEASE.MF (share root and inside the bundle).
//
// `gorelease assemble` skips the fleet phase (the fleet products are
// expected to already be in the bundle — the dev loop's shape).

import (
	"crypto/sha256"
	"fmt"
	"hash"
	"os"
	"path"
	"strconv"

	"virelai/vsys"
)

// relCfg wires one release run. Root is the share mount — /host in the
// gate, a temp dir under host tests; every default derives from it.
type relCfg struct {
	Root     string
	Bundle   string
	FleetMF  string
	Manifest string
	Image    string
	PinFile  string
	Apps     string
	SelfELF  string
	BootEFI  string
	Kernel   string
	SizeMB   uint64
}

func (c *relCfg) defaults() {
	j := func(name string) string { return c.Root + "/" + name }
	if c.Bundle == "" {
		c.Bundle = j("BUNDLE")
	}
	if c.FleetMF == "" {
		c.FleetMF = j("FLEET.MF")
	}
	if c.Manifest == "" {
		c.Manifest = j("RELEASE.MF")
	}
	if c.Image == "" {
		c.Image = j("RELEASE.IMG")
	}
	if c.PinFile == "" {
		c.PinFile = j("BOOTIN.MF")
	}
	if c.Apps == "" {
		c.Apps = j("APPS.TXT")
	}
	if c.SelfELF == "" {
		c.SelfELF = j("GORELEASE.ELF")
	}
	if c.BootEFI == "" {
		c.BootEFI = j("BOOTAA64.EFI")
	}
	if c.Kernel == "" {
		c.Kernel = j("KERNEL.BIN")
	}
}

// fleetBudgetNs bounds the fleet child: the M112a fleet lane runs inside a
// 5400 s gate timeout, so the wait gets the same horizon plus the assemble
// tail's slack.
const fleetBudgetNs = int64(2) * 3600 * int64(1e9)

// bundleAssets are the optional share files copied into the bundle when the
// host staged them — the same names gate_seed_share_contents produces.
var bundleAssets = []string{
	"WALLPAPER.QOI", "SEXIBURGER.QOI",
	"INTER.TTF", "INTERB.TTF", "INTERI.TTF", "INTERBI.TTF",
	"FIRACODE.TTF",
}

// bundleSettings is the wm=none seat config written into the bundle: the
// smoke boot keeps every EL0 task slot free for spawned children, the same
// reason the M112a fleet run stages it.
const bundleSettings = "#v2\nwm=none\n"

func failPhase(phase string, err error) int {
	vsys.Println("release: FAIL " + phase + ": " + err.Error())
	return 1
}

// sha256File hashes a file; ok=false when it cannot be read.
func sha256File(p string) (string, bool) {
	b, err := os.ReadFile(p)
	if err != nil {
		return "", false
	}
	return fmt.Sprintf("%x", sha256.Sum256(b)), true
}

// fileBytes reads a whole file — the guest's os overlay reads of any length
// are fine (only the write shadow is bounded at 16 MiB).
func fileBytes(p string) ([]byte, error) { return os.ReadFile(p) }

func copyInto(dstDir, src, name string) (relRow, error) {
	b, err := fileBytes(src)
	if err != nil {
		return relRow{}, err
	}
	dst := dstDir + "/" + name
	if err := os.WriteFile(dst, b, 0o644); err != nil {
		return relRow{}, fmt.Errorf("write %s: %w", dst, err)
	}
	return relRow{Path: name, Kind: "asset",
		SHA256: fmt.Sprintf("%x", sha256.Sum256(b)), Bytes: int64(len(b))}, nil
}

// runRelease is the default verb: fleet child, then assemble.
func runRelease(cfg relCfg) int {
	cfg.defaults()
	if err := os.MkdirAll(cfg.Bundle, 0o755); err != nil {
		return failPhase("bundle", fmt.Errorf("mkdir %s: %w", cfg.Bundle, err))
	}
	// The kernel's ELF path prepends the image name as argv[0]
	// (exec.zig argv_list[0] = name), so the args list starts at the verb.
	fleetArgs := []string{"fleet", "-nosmoke",
		"-outdir", cfg.Bundle, "-manifest", cfg.FleetMF}
	vsys.Println("release: fleet child GOBUILD.ELF fleet -nosmoke")
	status, err := spawnAndWait("GOBUILD.ELF", fleetArgs, fleetBudgetNs)
	if err != nil {
		return failPhase("fleet", fmt.Errorf("spawn/wait GOBUILD.ELF: %w", err))
	}
	// One retry, loudly: a single toolchain child can still hit the
	// transient task-slot starvation family (#2430/#2437 — 'newosproc:
	// sys_thread create failed'), and one crash must not sink the whole
	// assembly. A deterministic failure retries once and still fails by
	// name — the marker names the retry so the serial proves it.
	if status != 0 {
		vsys.Println("release: fleet child status=" + itoa(int(status)) +
			" — retrying once")
		status, err = spawnAndWait("GOBUILD.ELF", fleetArgs, fleetBudgetNs)
		if err != nil {
			return failPhase("fleet", fmt.Errorf("spawn/wait retry: %w", err))
		}
	}
	if status != 0 {
		return failPhase("fleet", fmt.Errorf("gobuild fleet status=%d", status))
	}
	vsys.Println("release: fleet child status=0")
	return runAssemble(cfg)
}

// runAssemble is the assemble verb: inputs -> bundle -> image -> manifest.
func runAssemble(cfg relCfg) int {
	cfg.defaults()

	// --- inputs: verify the sha-pinned host boot payload -----------------
	pinText, err := fileBytes(cfg.PinFile)
	if err != nil {
		return failPhase("inputs", fmt.Errorf("read %s: %w", cfg.PinFile, err))
	}
	pins, err := parsePins(string(pinText))
	if err != nil {
		return failPhase("inputs", err)
	}
	staged := map[string][]byte{}
	var efiBytes, kernelBytes []byte
	for _, pin := range pins {
		b, err := fileBytes(cfg.Root + "/" + pin.Name)
		if err != nil {
			return failPhase("inputs", fmt.Errorf("read staged %s: %w", pin.Name, err))
		}
		sum := fmt.Sprintf("%x", sha256.Sum256(b))
		if sum != pin.SHA256 {
			return failPhase("inputs", fmt.Errorf("%s sha256 mismatch: staged %s pinned %s",
				pin.Name, sum, pin.SHA256))
		}
		if pin.Bytes != 0 && int64(len(b)) != pin.Bytes {
			return failPhase("inputs", fmt.Errorf("%s size mismatch: staged %d pinned %d",
				pin.Name, len(b), pin.Bytes))
		}
		staged[pin.Name] = b
		vsys.Println("release: inputs " + pin.Name + " sha256=" + sum + " pinned")
	}
	efiBytes = staged["BOOTAA64.EFI"]
	kernelBytes = staged["KERNEL.BIN"]
	if len(efiBytes) == 0 {
		return failPhase("inputs", fmt.Errorf("BOOTIN.MF has no BOOTAA64.EFI pin"))
	}
	if len(kernelBytes) == 0 {
		return failPhase("inputs", fmt.Errorf("BOOTIN.MF has no KERNEL.BIN pin"))
	}
	if len(efiBytes) < 2 || string(efiBytes[:2]) != "MZ" {
		return failPhase("inputs", fmt.Errorf("BOOTAA64.EFI lacks the MZ magic"))
	}
	if len(kernelBytes) < 4 ||
		(string(kernelBytes[:4]) != "DSK1" && string(kernelBytes[:4]) != "KRN2") {
		return failPhase("inputs", fmt.Errorf("KERNEL.BIN lacks a known kernel magic"))
	}

	// --- fleet: verify every built row is in the bundle at its guest sha --
	fleetText, err := fileBytes(cfg.FleetMF)
	if err != nil {
		return failPhase("fleet", fmt.Errorf("read %s: %w", cfg.FleetMF, err))
	}
	frows, err := parseFleetManifest(string(fleetText))
	if err != nil {
		return failPhase("fleet", err)
	}
	var rows []relRow
	built, refused, failed := 0, 0, 0
	for _, fr := range frows {
		switch fr.State {
		case "built":
			built++
			if fr.Guest == "" || fr.Guest == "-" {
				return failPhase("fleet", fmt.Errorf("%s built without a guest sha256", fr.Name))
			}
			b, err := fileBytes(cfg.Bundle + "/" + fr.Name)
			if err != nil {
				return failPhase("fleet", fmt.Errorf("%s built but missing from bundle: %w", fr.Name, err))
			}
			sum := fmt.Sprintf("%x", sha256.Sum256(b))
			if sum != fr.Guest {
				return failPhase("fleet", fmt.Errorf("%s bundle sha256 %s != fleet guest= %s",
					fr.Name, sum, fr.Guest))
			}
			rows = append(rows, relRow{Path: fr.Name, Kind: "fleet",
				SHA256: sum, Bytes: int64(len(b))})
			vsys.Println("release: fleet " + fr.Name + " sha256=" + sum)
		case "refused":
			refused++
			vsys.Println("release: fleet " + fr.Name + " refused " + fr.Code + " (not bundled)")
		case "failed":
			failed++
			vsys.Println("release: fleet " + fr.Name + " failed " + fr.Code + " (not bundled)")
		}
	}
	if built == 0 {
		return failPhase("fleet", fmt.Errorf("%s has no built rows", cfg.FleetMF))
	}
	if failed > 0 {
		return failPhase("fleet", fmt.Errorf("%d fleet rows failed", failed))
	}
	vsys.Println("release: fleet built=" + itoa(built) +
		" refused=" + itoa(refused) + " failed=" + itoa(failed))

	// --- bundle extras: the manifest a seat reads, the seat setting, the
	// smoke driver itself, and whatever share assets were staged -----------
	if err := os.MkdirAll(cfg.Bundle, 0o755); err != nil {
		return failPhase("bundle", fmt.Errorf("mkdir %s: %w", cfg.Bundle, err))
	}
	ar, err := copyInto(cfg.Bundle, cfg.Apps, "APPS.TXT")
	if err != nil {
		return failPhase("bundle", fmt.Errorf("APPS.TXT: %w", err))
	}
	ar.Kind = "asset"
	rows = append(rows, ar)

	if err := os.WriteFile(cfg.Bundle+"/SETTINGS.TXT", []byte(bundleSettings), 0o644); err != nil {
		return failPhase("bundle", fmt.Errorf("SETTINGS.TXT: %w", err))
	}
	rows = append(rows, relRow{Path: "SETTINGS.TXT", Kind: "config",
		SHA256: fmt.Sprintf("%x", sha256.Sum256([]byte(bundleSettings))),
		Bytes:  int64(len(bundleSettings))})

	dr, err := copyInto(cfg.Bundle, cfg.SelfELF, "GORELEASE.ELF")
	if err != nil {
		return failPhase("bundle", fmt.Errorf("GORELEASE.ELF: %w", err))
	}
	dr.Kind = "driver"
	rows = append(rows, dr)

	assets := 0
	for _, name := range bundleAssets {
		p := cfg.Root + "/" + name
		if _, err := os.Stat(p); err != nil {
			continue // unstaged assets are absent, not wrong
		}
		ar, err := copyInto(cfg.Bundle, p, name)
		if err != nil {
			return failPhase("bundle", fmt.Errorf("%s: %w", name, err))
		}
		rows = append(rows, ar)
		assets++
	}
	vsys.Println("release: bundle " + itoa(len(rows)) + " files (" +
		itoa(built) + " fleet, " + itoa(assets) + " assets)")

	// --- image: the GPT+FAT32 boot volume, streamed to the share ----------
	sink, err := newSeqSink(cfg.Image)
	if err != nil {
		return failPhase("image", err)
	}
	hw := &hashSink{s: sink, h: sha256.New()}
	imgBytes, err := writeImage(hw, efiBytes, kernelBytes, cfg.SizeMB)
	if err != nil {
		sink.Close()
		return failPhase("image", err)
	}
	if err := sink.Close(); err != nil {
		return failPhase("image", fmt.Errorf("close %s: %w", cfg.Image, err))
	}
	imgSum := fmt.Sprintf("%x", hw.h.Sum(nil))
	vsys.Println("release: image " + path.Base(cfg.Image) +
		" bytes=" + strconv.FormatUint(imgBytes, 10) + " sha256=" + imgSum)

	// --- manifest ---------------------------------------------------------
	mrows := []relRow{
		{Path: path.Base(cfg.Image), Kind: "image", SHA256: imgSum, Bytes: int64(imgBytes)},
		{Path: "EFI/BOOT/BOOTAA64.EFI", Kind: "member",
			SHA256: fmt.Sprintf("%x", sha256.Sum256(efiBytes)), Bytes: int64(len(efiBytes))},
		{Path: "KERNEL.BIN", Kind: "member",
			SHA256: fmt.Sprintf("%x", sha256.Sum256(kernelBytes)), Bytes: int64(len(kernelBytes))},
	}
	mrows = append(mrows, rows...)
	mtext := renderReleaseManifest(mrows)
	if err := os.WriteFile(cfg.Manifest, []byte(mtext), 0o644); err != nil {
		return failPhase("manifest", fmt.Errorf("write %s: %w", cfg.Manifest, err))
	}
	// The bundle carries its own copy so the run-2 share (the bundle dir
	// armed as /host) is self-describing.
	if err := os.WriteFile(cfg.Bundle+"/RELEASE.MF", []byte(mtext), 0o644); err != nil {
		return failPhase("manifest", fmt.Errorf("write bundle RELEASE.MF: %w", err))
	}
	vsys.Println("release: manifest " + path.Base(cfg.Manifest) + " rows=" + itoa(len(mrows)))
	vsys.Println("release: release OK image=" + strconv.FormatUint(imgBytes, 10) +
		" bundle=" + itoa(len(rows)) + " files")
	return 0
}

// hashSink tees the image stream through sha256 — the manifest records the
// digest of exactly what was written, zeros included.
type hashSink struct {
	s   seqSink
	h   hash.Hash
	pos uint64
}

func (w *hashSink) Write(b []byte) (int, error) {
	n, err := w.s.Write(b)
	if n > 0 {
		w.h.Write(b[:n])
		w.pos += uint64(n)
	}
	return n, err
}

func (w *hashSink) Close() error { return w.s.Close() }

func (w *hashSink) ZeroPad(to uint64) error {
	if to < w.pos {
		return fmt.Errorf("zeropad %d behind position %d", to, w.pos)
	}
	var zero [8192]byte
	for w.pos < to {
		n := uint64(len(zero))
		if to-w.pos < n {
			n = to - w.pos
		}
		w.h.Write(zero[:n])
		w.pos += n
	}
	return w.s.ZeroPad(to)
}

func itoa(v int) string { return strconv.Itoa(v) }
