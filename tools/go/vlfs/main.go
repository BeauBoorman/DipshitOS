package main

import (
	"crypto/rand"
	"flag"
	"fmt"
	"os"
	"time"
)

const usage = `mkfs.vlfs — format or check a VLFS volume image (ADR 0050)

  mkfs.vlfs [-mib N | -bytes N] [-volume-id HEX] [-time UNIX] <image>
      Write a fresh empty volume to <image> (default 64 MiB).
      -volume-id and -time pin the only non-deterministic fields, so a
      fixed pair reproduces the image byte-for-byte (the golden fixtures
      under kernel/src/vlfs/testdata/ are made this way).

  mkfs.vlfs --check <image>
      Read-only structural validation. Prints one named refusal per
      finding and exits non-zero on any non-informational finding.

  mkfs.vlfs --emit-regions <image>
      Print the .regions dump (non-zero byte runs) of a formatted image;
      this is how the golden fixtures are produced.
`

func main() {
	var checkOnly, emitRegions bool
	var mib, bytesFlag uint64
	var volumeIDFlag, timeFlag uint64
	fs := flag.NewFlagSet("mkfs.vlfs", flag.ExitOnError)
	fs.BoolVar(&checkOnly, "check", false, "validate an existing image")
	fs.BoolVar(&emitRegions, "emit-regions", false, "print the .regions dump of the image")
	fs.Uint64Var(&mib, "mib", 64, "image size in MiB")
	fs.Uint64Var(&bytesFlag, "bytes", 0, "image size in bytes (overrides -mib)")
	fs.Uint64Var(&volumeIDFlag, "volume-id", 0, "volume id (default: random nonzero)")
	fs.Uint64Var(&timeFlag, "time", 0, "mkfs unix timestamp (default: now)")
	fs.Usage = func() { fmt.Fprint(os.Stderr, usage) }
	if err := fs.Parse(os.Args[1:]); err != nil {
		os.Exit(2)
	}
	if fs.NArg() != 1 {
		fs.Usage()
		os.Exit(2)
	}
	path := fs.Arg(0)

	if checkOnly {
		img, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintln(os.Stderr, "mkfs.vlfs:", err)
			os.Exit(2)
		}
		hard := false
		for _, f := range checkImage(img) {
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

	if err := formatImage(img, volumeID, mkfsTime); err != nil {
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
	fmt.Printf("mkfs.vlfs: %s: %d-byte VLFS volume (id %016x)\n", path, size, volumeID)
}
