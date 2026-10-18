// STORE.ELF — the M101c (#2315) install seam for VirelaiOS. A pulled
// release stream becomes a running app: verify the stream head against
// the publisher keyring (through FLINT.ELF's M101b gate), parse and
// re-authenticate the signed release.go manifest, fetch the ELF over an
// untrusted channel, check its SHA-256, and only then publish the ELF and
// the schema-v2 APPS.TXT row through WriteFileSafe. The launcher re-reads
// APPS.TXT at each summon, so an install is live on the next call.
//
// Verbs: `store ls` (the ADR 0055 signed catalog, with --search and
// --category filters), `store info <name>`, `store install <stream>`,
// `store update <name>`, `store rollback <name>`, `store remove <name>`
// (M101d #2316 adds the last two plus the STORE.TXT prev-head state
// file; M110b #2404 adds the catalog ls/info).
// Every failure is a named refusal — `store: refuse <code>` — and a
// failed install leaves zero partial state: no ELF, no row, no
// half-copied file.
//
// M110c (#2405): this file is only the CLI shell. The verbs live in
// package store (user/go/store) so GOSTORE.ELF can link them in-process
// instead of nesting a STORE.ELF exec — see user/go/store/errors.go.
package main

import (
	"strings"

	"virelai/store"
	"virelai/vi"
)

// argvEnvpGuard keeps the writable segment's bss end far enough from the
// page boundary for the kernel's packed argv+envp (see FLINT.ELF).
var argvEnvpGuard [0x1000]byte

func init() {
	argvEnvpGuard[len(argvEnvpGuard)-1] = byte(len(argvEnvpGuard) & 0xff)
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

const usageLine = "store: usage: store ls [--remote=<r>] [--channel=<dir|http://ip:port/base>] [--search=<s>] [--category=<c>] | store info <name> [--remote=<r>] [--channel=<dir|http://ip:port/base>] | store install <stream> [--remote=<r>] [--channel=<dir|http://ip:port/base>] | store update <name> [--remote=<r>] [--channel=<dir|http://ip:port/base>] | store rollback <name> | store remove <name> | store consent <name> | store decline <name>"

func run(args []string) int {
	if len(args) == 0 {
		store.ConsoleFn(usageLine)
		return 2
	}
	var positional []string
	var remoteFlag, channelArg, searchFlag, categoryFlag string
	for _, a := range args[1:] {
		switch {
		case strings.HasPrefix(a, "--remote="):
			remoteFlag = a[len("--remote="):]
		case strings.HasPrefix(a, "--channel="):
			channelArg = a[len("--channel="):]
		case strings.HasPrefix(a, "--search="):
			searchFlag = a[len("--search="):]
		case strings.HasPrefix(a, "--category="):
			categoryFlag = a[len("--category="):]
		case strings.HasPrefix(a, "-"):
			store.ConsoleFn(usageLine)
			return 2
		default:
			positional = append(positional, a)
		}
	}
	filterArgs := searchFlag != "" || categoryFlag != ""
	switch args[0] {
	case "ls":
		if len(positional) != 0 {
			store.ConsoleFn(usageLine)
			return 2
		}
		return store.Ls(store.GuestFS{}, store.DefaultStoreRoot, remoteFlag, channelArg, searchFlag, categoryFlag)
	case "info":
		if len(positional) != 1 || filterArgs {
			store.ConsoleFn(usageLine)
			return 2
		}
		return store.Info(store.GuestFS{}, store.DefaultStoreRoot, positional[0], remoteFlag, channelArg)
	case "install":
		if len(positional) != 1 || filterArgs {
			store.ConsoleFn(usageLine)
			return 2
		}
		return store.Install(store.GuestFS{}, store.DefaultStoreRoot, positional[0], remoteFlag, channelArg)
	case "update":
		if len(positional) != 1 || filterArgs {
			store.ConsoleFn(usageLine)
			return 2
		}
		return store.Update(store.GuestFS{}, store.DefaultStoreRoot, positional[0], remoteFlag, channelArg)
	case "rollback":
		if len(positional) != 1 || remoteFlag != "" || channelArg != "" || filterArgs {
			store.ConsoleFn(usageLine)
			return 2
		}
		return store.Rollback(store.GuestFS{}, positional[0])
	case "remove":
		if len(positional) != 1 || remoteFlag != "" || channelArg != "" || filterArgs {
			store.ConsoleFn(usageLine)
			return 2
		}
		return store.Remove(store.GuestFS{}, positional[0])
	case "consent":
		if len(positional) != 1 || remoteFlag != "" || channelArg != "" || filterArgs {
			store.ConsoleFn(usageLine)
			return 2
		}
		return store.Consent(store.GuestFS{}, positional[0])
	case "decline":
		if len(positional) != 1 || remoteFlag != "" || channelArg != "" || filterArgs {
			store.ConsoleFn(usageLine)
			return 2
		}
		return store.Decline(store.GuestFS{}, positional[0])
	default:
		store.ConsoleFn(usageLine)
		return 2
	}
}
