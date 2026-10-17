package main

// GORELEASE.ELF — the M112c (#2415) release driver. A release is a guest
// command: the guest assembles what the host boots.
//
//	gorelease [release] [-root DIR] [-size-mb N]   fleet build + assemble +
//	                                             image + manifest (the gate's
//	                                             run-1 shape)
//	gorelease assemble [-root DIR] [-size-mb N]    assemble only — fleet
//	                                             products already in place
//	gorelease smoke [-root DIR]                    exec every fleet ELF the
//	                                             manifest names (run 2)
//
// The default root is /host — the armed share. Paths a run overrides are
// the ones the spec stages; everything else derives from -root.

import (
	"os"
	"runtime"
	"strconv"
	"strings"

	"virelai/vi"
	"virelai/vsys"
)

// argvEnvpGuard keeps the writable segment's bss end far enough from the
// page boundary for the kernel's packed argv+envp (GOBUILD.ELF / FLINT.ELF
// carry the same guard).
var argvEnvpGuard [0x1000]byte

func init() {
	argvEnvpGuard[len(argvEnvpGuard)-1] = byte(len(argvEnvpGuard) & 0xff)
}

func main() {
	argv := vi.Args()
	if len(argv) == 0 && runtime.GOOS != "virelai" {
		argv = os.Args // host dev runs / tests through main()
	}
	rc := run(argv)
	// The run-end sentinel: the gate's --script-expect waits on this one
	// line, which prints on EVERY path (success, named failure, usage), so
	// a failing run ends promptly instead of riding the run timeout. The
	// verdict itself is the preceding `release: <verb> OK|FAIL` marker.
	vsys.Println("release: exit rc=" + itoa(rc))
	// Yield a tick before exiting so a parent polling vi.Wait sees the
	// reaped state (the same tail GOBUILD carries).
	vi.Sleep(1)
	vi.Exit(rc)
}

func run(argv []string) int {
	var args []string
	if len(argv) > 0 {
		args = argv[1:]
	}
	verb := "release"
	if len(args) > 0 &&
		(args[0] == "release" || args[0] == "assemble" || args[0] == "smoke") {
		verb = args[0]
		args = args[1:]
	}
	cfg := relCfg{Root: "/host"}
	for i := 0; i < len(args); i++ {
		val := func() (string, bool) {
			if i+1 >= len(args) {
				return "", false
			}
			i++
			return args[i], true
		}
		switch args[i] {
		case "-root":
			v, ok := val()
			if !ok {
				return usage("-root needs a path")
			}
			cfg.Root = strings.TrimSuffix(v, "/")
		case "-bundle":
			if v, ok := val(); !ok {
				return usage("-bundle needs a path")
			} else {
				cfg.Bundle = v
			}
		case "-fleetmf":
			if v, ok := val(); !ok {
				return usage("-fleetmf needs a path")
			} else {
				cfg.FleetMF = v
			}
		case "-manifest":
			if v, ok := val(); !ok {
				return usage("-manifest needs a path")
			} else {
				cfg.Manifest = v
			}
		case "-image":
			if v, ok := val(); !ok {
				return usage("-image needs a path")
			} else {
				cfg.Image = v
			}
		case "-pin":
			if v, ok := val(); !ok {
				return usage("-pin needs a path")
			} else {
				cfg.PinFile = v
			}
		case "-size-mb":
			v, ok := val()
			if !ok {
				return usage("-size-mb needs a number")
			}
			n, err := strconv.ParseUint(v, 10, 32)
			if err != nil {
				return usage("-size-mb: " + err.Error())
			}
			cfg.SizeMB = n
		default:
			return usage("unknown flag " + args[i])
		}
	}
	cfg.defaults()

	switch verb {
	case "assemble":
		return runAssemble(cfg)
	case "smoke":
		return runSmoke(cfg)
	}
	return runRelease(cfg)
}

func usage(why string) int {
	vsys.Println("gorelease: " + why)
	vsys.Println("gorelease: usage: gorelease [release] [-root DIR] [-size-mb N]")
	vsys.Println("gorelease:        gorelease assemble [-root DIR] [-size-mb N]")
	vsys.Println("gorelease:        gorelease smoke [-root DIR]")
	return 2
}
