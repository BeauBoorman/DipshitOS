package main

// GOUPD.ELF — the M115f (#2465) OS self-update stager. The OS upgrades
// itself: the guest assembles the signed payload the runner's
// --apply-update consumes on the next boot.
//
//	goupd stage [-src DIR] [-dst DIR]   build + sign + publish the update
//
// Stage reads the staged next-boot inputs (<src>/KERNEL.BIN,
// <src>/BOOTAA64.EFI, optional <src>/VERSION.TXT), streams a GPT+FAT32
// boot image to <dst>/OS.IMG through the fatimg sink, copies the two
// members through WriteFileSafe, then writes UPDATE.MF and its Ed25519
// signature (UPDATE.SIG — 64 raw bytes over the manifest bytes, the
// `os-update` slot-70 seed bound to GOUPD.ELF). The signature is the
// last thing published, so a torn stage is always an unsigned or
// hash-stale one — the runner refuses both by name.
//
// Defaults are the card's fixed lane: src=/host/NEXT, dst=/host/UPDATE.

import (
	"os"
	"runtime"
	"strings"

	"virelai/vi"
	"virelai/vsys"
)

func main() {
	argv := vi.Args()
	if len(argv) == 0 && runtime.GOOS != "virelai" {
		argv = os.Args // host dev runs / tests through main()
	}
	rc := run(argv)
	// The run-end sentinel: printed on EVERY path so the gate's
	// --script-expect ends promptly instead of riding the run timeout.
	vsys.Println("update: exit rc=" + itoa(rc))
	vi.Sleep(1)
	vi.Exit(rc)
}

func run(argv []string) int {
	var args []string
	if len(argv) > 0 {
		args = argv[1:]
	}
	verb := "stage"
	if len(args) > 0 && args[0] == "stage" {
		args = args[1:]
	}
	if verb != "stage" {
		return usage("verbs: stage")
	}
	cfg := updCfg{Src: "/host/NEXT", Dst: "/host/UPDATE"}
	for i := 0; i < len(args); i++ {
		val := func() (string, bool) {
			if i+1 >= len(args) {
				return "", false
			}
			i++
			return args[i], true
		}
		switch args[i] {
		case "-src":
			v, ok := val()
			if !ok {
				return usage("-src needs a path")
			}
			cfg.Src = strings.TrimSuffix(v, "/")
		case "-dst":
			v, ok := val()
			if !ok {
				return usage("-dst needs a path")
			}
			cfg.Dst = strings.TrimSuffix(v, "/")
		default:
			return usage("unknown flag " + args[i])
		}
	}
	return stage(newUpFS(), cfg)
}

func usage(msg string) int {
	vsys.Println("update: usage: goupd stage [-src DIR] [-dst DIR] (" + msg + ")")
	return 2
}
