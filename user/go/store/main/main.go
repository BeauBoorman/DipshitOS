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
// file; M110b #2404 adds the catalog ls/info), and `store publish`
// (M181a: the producer half — writes the signed manifest into a FLINT
// workspace, commits it under agent-sign, and drops the layout install
// reads).
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

const usageLine = "store: usage: store ls [--remote=<r>] [--channel=<dir|http://ip:port/base>] [--search=<s>] [--category=<c>] | store info <name> [--remote=<r>] [--channel=<dir|http://ip:port/base>] | store install <stream> [--remote=<r>] [--channel=<dir|http://ip:port/base>] | store update <name> [--remote=<r>] [--channel=<dir|http://ip:port/base>] | store rollback <name> | store remove <name> | store consent <name> | store decline <name> | store publish <NAME> <elf> --src=<dir> --version=<v> --stream=<s> [--channel=<dir>] [--row=<row>] [--summary=<s>] [--category=<c>]"

// publishUsage is the one verb whose flag vocabulary the shared loop
// below would reject as unknown, so publish parses its own args.
const publishUsage = "store: usage: store publish <NAME> <elf> --src=<dir> --version=<v> --stream=<s> [--channel=<dir>] [--row=<row>] [--summary=<s>] [--category=<c>]"

func runPublish(args []string) int {
	var a store.PublishArgs
	var positional []string
	for _, f := range args {
		switch {
		case strings.HasPrefix(f, "--src="):
			a.Src = f[len("--src="):]
		case strings.HasPrefix(f, "--version="):
			a.Version = f[len("--version="):]
		case strings.HasPrefix(f, "--stream="):
			a.Stream = f[len("--stream="):]
		case strings.HasPrefix(f, "--channel="):
			a.Channel = f[len("--channel="):]
		case strings.HasPrefix(f, "--row="):
			a.Row = f[len("--row="):]
		case strings.HasPrefix(f, "--summary="):
			a.Summary = f[len("--summary="):]
		case strings.HasPrefix(f, "--category="):
			a.Category = f[len("--category="):]
		case strings.HasPrefix(f, "-"):
			store.ConsoleFn(publishUsage)
			return 2
		default:
			positional = append(positional, f)
		}
	}
	if len(positional) != 2 || a.Src == "" || a.Version == "" || a.Stream == "" {
		store.ConsoleFn(publishUsage)
		return 2
	}
	a.Name, a.ElfPath = positional[0], positional[1]
	return store.Publish(store.GuestFS{}, store.DefaultStoreRoot, a)
}

func run(args []string) int {
	if len(args) == 0 {
		store.ConsoleFn(usageLine)
		return 2
	}
	if args[0] == "publish" {
		return runPublish(args[1:])
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
