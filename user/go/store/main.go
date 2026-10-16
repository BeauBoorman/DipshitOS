// STORE.ELF — the M101c (#2315) install seam for VirelaiOS. A pulled
// release stream becomes a running app: verify the stream head against
// the publisher keyring (through FLINT.ELF's M101b gate), parse and
// re-authenticate the signed release.go manifest, fetch the ELF over an
// untrusted channel, check its SHA-256, and only then publish the ELF and
// the schema-v2 APPS.TXT row through WriteFileSafe. The launcher re-reads
// APPS.TXT at each summon, so an install is live on the next call.
//
// Verbs: `store ls`, `store install <stream>`, `store update <name>`,
// `store rollback <name>`, `store remove <name>` (M101d #2316 adds the
// last two plus the STORE.TXT prev-head state file).
// Every failure is a named refusal — `store: refuse <code>` — and a
// failed install leaves zero partial state: no ELF, no row, no
// half-copied file.
package main

import (
	"strings"

	"virelai/vi"
)

// argvEnvpGuard keeps the writable segment's bss end far enough from the
// page boundary for the kernel's packed argv+envp (see FLINT.ELF).
var argvEnvpGuard [0x1000]byte

func init() {
	argvEnvpGuard[len(argvEnvpGuard)-1] = byte(len(argvEnvpGuard) & 0xff)
}

var consoleFn = vi.ConsoleLine

// RefuseError is a named STORE refusal (`store: refuse <code> ...`).
type RefuseError struct {
	Code   string
	Detail string
}

func (e *RefuseError) Error() string {
	if e.Detail == "" {
		return "store: refuse " + e.Code
	}
	return "store: refuse " + e.Code + " " + e.Detail
}

func refuse(code, detail string) error {
	return &RefuseError{Code: code, Detail: detail}
}

func main() {
	rc := run(cliArgs(vi.Args()))
	// Settle before exiting so a parent polling vi.Wait blocks alongside
	// us, letting the core-0 idle reaper free the prior child's task
	// slots before the next sequential exec (the M103 sequential-exec
	// race). Ticks are 1 Hz: 2 s is cheap and covers the observed
	// post-install spawn loss of the follow-on exec line.
	vi.Sleep(2)
	vi.Exit(rc)
}

func cliArgs(raw []string) []string {
	if len(raw) == 0 {
		return nil
	}
	first := strings.ToUpper(raw[0])
	if strings.HasSuffix(first, ".ELF") || strings.HasSuffix(first, ".BIN") || first == "STORE" {
		return raw[1:]
	}
	return raw
}

const usageLine = "store: usage: store ls [--remote=<r>] | store install <stream> [--remote=<r>] [--channel=<dir|http://ip:port/base>] | store update <name> [--remote=<r>] [--channel=<dir|http://ip:port/base>] | store rollback <name> | store remove <name>"

func run(args []string) int {
	if len(args) == 0 {
		consoleFn(usageLine)
		return 2
	}
	var positional []string
	var remoteFlag, channelArg string
	for _, a := range args[1:] {
		switch {
		case strings.HasPrefix(a, "--remote="):
			remoteFlag = a[len("--remote="):]
		case strings.HasPrefix(a, "--channel="):
			channelArg = a[len("--channel="):]
		case strings.HasPrefix(a, "-"):
			consoleFn(usageLine)
			return 2
		default:
			positional = append(positional, a)
		}
	}
	switch args[0] {
	case "ls":
		if len(positional) != 0 || channelArg != "" {
			consoleFn(usageLine)
			return 2
		}
		return cmdLs(activeFS, DefaultStoreRoot, remoteFlag)
	case "install":
		if len(positional) != 1 {
			consoleFn(usageLine)
			return 2
		}
		return cmdInstall(activeFS, DefaultStoreRoot, positional[0], remoteFlag, channelArg)
	case "update":
		if len(positional) != 1 {
			consoleFn(usageLine)
			return 2
		}
		return cmdUpdate(activeFS, DefaultStoreRoot, positional[0], remoteFlag, channelArg)
	case "rollback":
		if len(positional) != 1 || remoteFlag != "" || channelArg != "" {
			consoleFn(usageLine)
			return 2
		}
		return cmdRollback(activeFS, positional[0])
	case "remove":
		if len(positional) != 1 || remoteFlag != "" || channelArg != "" {
			consoleFn(usageLine)
			return 2
		}
		return cmdRemove(activeFS, positional[0])
	default:
		consoleFn(usageLine)
		return 2
	}
}

func runErr(err error) int {
	if err == nil {
		return 0
	}
	if re, ok := err.(*RefuseError); ok {
		consoleFn(re.Error())
		if re.Code == "usage" {
			return 2
		}
		return 1
	}
	consoleFn("store: error " + err.Error())
	return 1
}
