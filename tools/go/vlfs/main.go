package main

import (
	"bytes"
	"crypto/rand"
	"flag"
	"fmt"
	"io"
	"os"
	"time"
)

const usage = `mkfs.vlfs — format or check a VLFS volume image (ADR 0050 / ADR 0061)

  mkfs.vlfs [-mib N | -bytes N] [-volume-id HEX] [-time UNIX] <image>
      Write a fresh empty v1 volume to <image> (default 64 MiB).
      -volume-id and -time pin the only non-deterministic fields, so a
      fixed pair reproduces the image byte-for-byte (the golden fixtures
      under kernel/src/vlfs/testdata/ are made this way).

  mkfs.vlfs --seal --passphrase-file F [-mib N | -bytes N] [-kdf-iters N] <image>
      Write a fresh sealed v2 volume (ADR 0061): every block in the
      sealed span is ChaCha20-Poly1305 ciphertext under a minted DEK,
      wrapped into the superblock by a passphrase-derived KEK. The
      passphrase comes only from file F ('-' = stdin), never from argv.
      -kdf-iters pins PBKDF2-HMAC-SHA256; the default calibrates it to
      ~1 s on this host at seal time.

  mkfs.vlfs --check [--passphrase-file F] <image>
      Read-only structural validation. Prints one named refusal per
      finding and exits non-zero on any non-informational finding.
      On a sealed volume the passphrase additionally unwraps the DEK
      and authenticates every sealed block's tag (bad_block_auth
      reports the block number; a journal-region failure is the
      informational journal_torn — a kill's torn tail, not a home
      verdict); without it only the plaintext structure is verified.

  mkfs.vlfs --emit-regions <image>
      Print the .regions dump (non-zero byte runs) of a formatted image;
      this is how the golden fixtures are produced.
`

func main() {
	var checkOnly, emitRegions, seal bool
	var mib, bytesFlag uint64
	var volumeIDFlag, timeFlag uint64
	var passFile string
	var kdfIters uint
	fs := flag.NewFlagSet("mkfs.vlfs", flag.ExitOnError)
	fs.BoolVar(&checkOnly, "check", false, "validate an existing image")
	fs.BoolVar(&emitRegions, "emit-regions", false, "print the .regions dump of the image")
	fs.BoolVar(&seal, "seal", false, "format a sealed v2 volume (requires --passphrase-file)")
	fs.StringVar(&passFile, "passphrase-file", "", "read the seal passphrase from file ('-' = stdin); never an argv value")
	fs.Uint64Var(&mib, "mib", 64, "image size in MiB")
	fs.Uint64Var(&bytesFlag, "bytes", 0, "image size in bytes (overrides -mib)")
	fs.Uint64Var(&volumeIDFlag, "volume-id", 0, "volume id (default: random nonzero)")
	fs.Uint64Var(&timeFlag, "time", 0, "mkfs unix timestamp (default: now)")
	fs.UintVar(&kdfIters, "kdf-iters", 0, "PBKDF2 iterations for --seal (default: calibrate to ~1s)")
	fs.Usage = func() { fmt.Fprint(os.Stderr, usage) }
	if err := fs.Parse(os.Args[1:]); err != nil {
		os.Exit(2)
	}
	if fs.NArg() != 1 {
		fs.Usage()
		os.Exit(2)
	}
	path := fs.Arg(0)

	pass, err := readPassphrase(passFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, "mkfs.vlfs:", err)
		os.Exit(2)
	}

	if checkOnly {
		img, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintln(os.Stderr, "mkfs.vlfs:", err)
			os.Exit(2)
		}
		hard := false
		for _, f := range checkImage(img, pass) {
			prefix := ""
			if f.info {
				prefix = "info: "
			} else {
				hard = true
			}
			fmt.Println(prefix + f.String())
		}
		if !hard {
			fmt.Println("check: clean")
		}
		if hard {
			os.Exit(1)
		}
		return
	}

	if passFile == "" && seal {
		fmt.Fprintln(os.Stderr, "mkfs.vlfs: --seal requires --passphrase-file F ('-' reads stdin)")
		os.Exit(2)
	}
	if passFile != "" && !seal {
		fmt.Fprintln(os.Stderr, "mkfs.vlfs: --passphrase-file is meaningful only with --seal or --check")
		os.Exit(2)
	}

	size := mib << 20
	if bytesFlag != 0 {
		size = bytesFlag
	}
	img := make([]byte, size)

	volumeID := volumeIDFlag
	for volumeID == 0 {
		var b [8]byte
		if _, err := rand.Read(b[:]); err != nil {
			fmt.Fprintln(os.Stderr, "mkfs.vlfs:", err)
			os.Exit(2)
		}
		volumeID = uint64(b[0]) | uint64(b[1])<<8 | uint64(b[2])<<16 | uint64(b[3])<<24 |
			uint64(b[4])<<32 | uint64(b[5])<<40 | uint64(b[6])<<48 | uint64(b[7])<<56
	}
	mkfsTime := timeFlag
	if mkfsTime == 0 {
		mkfsTime = uint64(time.Now().Unix())
	}

	var sealNote string
	if seal {
		iters := uint32(kdfIters)
		if iters == 0 {
			iters = calibrateKdfIters(pass, time.Second)
		}
		params, err := newSealParams(iters)
		if err != nil {
			fmt.Fprintln(os.Stderr, "mkfs.vlfs:", err)
			os.Exit(2)
		}
		err = formatSealedImage(img, volumeID, mkfsTime, pass, params)
		sealNote = fmt.Sprintf(" sealed v2 (kdf_iters %d)", iters)
	} else {
		err = formatImage(img, volumeID, mkfsTime)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "mkfs.vlfs:", err)
		os.Exit(1)
	}

	if emitRegions {
		fmt.Print(regionsEncode(img))
		return
	}

	if err := os.WriteFile(path, img, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "mkfs.vlfs:", err)
		os.Exit(2)
	}
	fmt.Printf("mkfs.vlfs: %s: %d-byte VLFS volume (id %016x)%s\n", path, size, volumeID, sealNote)
}

// readPassphrase loads the passphrase from the named file — "-" means
// stdin — and returns nil when no file was given. The passphrase is
// never an argv value (a flag would leak it to ps and shell history).
// One trailing CR/LF is stripped so `echo passphrase > f` works.
func readPassphrase(file string) ([]byte, error) {
	if file == "" {
		return nil, nil
	}
	var raw []byte
	var err error
	if file == "-" {
		raw, err = io.ReadAll(os.Stdin)
	} else {
		raw, err = os.ReadFile(file)
	}
	if err != nil {
		return nil, err
	}
	return bytes.TrimRight(raw, "\r\n"), nil
}

// calibrateKdfIters measures PBKDF2-HMAC-SHA256 on this host and returns
// the iteration count that costs ~target. ADR 0061 D9 stores the count in
// the superblock, so the seal-time calibration is what every later unseal
// pays — offline guessing is bounded by it alone.
func calibrateKdfIters(pass []byte, target time.Duration) uint32 {
	// Double the probe until a single measurement clears 100 ms so the
	// scale is computed on real time, not timer granularity.
	var salt [SealSaltBytes]byte
	iters := uint64(10000)
	for {
		start := time.Now()
		if _, err := pbkdf2Key(pass, salt[:], uint32(iters)); err != nil {
			return 1
		}
		el := time.Since(start)
		if el >= 100*time.Millisecond || iters >= 1<<28 {
			scaled := iters * uint64(target) / uint64(el)
			if scaled < 1 {
				scaled = 1
			}
			if scaled > 1<<32-1 {
				scaled = 1<<32 - 1
			}
			return uint32(scaled)
		}
		iters *= 4
	}
}
