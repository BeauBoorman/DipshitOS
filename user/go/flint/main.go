// FLINT.ELF — agent-native source control CLI for VirelaiOS (M103, ADR 0049).
// M103a (#2253) ships the skeleton and `parse-corpus <dir>`, proving that
// go/parser + FLINT's Zig declaration scanner run in-guest and produce the
// exact canonical Atom hashes.
package main

import (
	"strings"

	"virelai/vi"
)

// argvEnvpGuard keeps the writable segment's bss end far enough from the
// page boundary for the kernel's packed argv+envp (see GOSH.ELF / AGENTD.ELF).
var argvEnvpGuard [0x1000]byte

func init() {
	argvEnvpGuard[len(argvEnvpGuard)-1] = byte(len(argvEnvpGuard) & 0xff)
}

var consoleFn = vi.ConsoleLine

func main() {
	vi.Exit(run(cliArgs(vi.Args())))
}

func cliArgs(raw []string) []string {
	if len(raw) == 0 {
		return nil
	}
	first := strings.ToUpper(raw[0])
	if strings.HasSuffix(first, ".ELF") || strings.HasSuffix(first, ".BIN") || first == "FLINT" {
		return raw[1:]
	}
	return raw
}

func run(args []string) int {
	if len(args) == 0 {
		consoleFn("flint: usage")
		return 2
	}
	switch args[0] {
	case "parse-corpus":
		if len(args) != 2 || args[1] == "" {
			consoleFn("flint: usage")
			return 2
		}
		return parseCorpus(args[1])
	case "init":
		return runErr(cmdInit(activeFS, storeRoot, defaultUUIDGen, args[1:]))
	case "add":
		return runErr(cmdAdd(activeFS, storeRoot, defaultUUIDGen, args[1:]))
	case "status":
		return runErr(cmdStatus(activeFS, storeRoot, args[1:]))
	case "commit":
		return runErr(cmdCommit(activeFS, storeRoot, defaultUUIDGen, args[1:]))
	case "log":
		return runErr(cmdLog(activeFS, storeRoot, args[1:]))
	case "verify":
		return cmdVerify(activeFS, storeRoot, args[1:])
	default:
		consoleFn("flint: usage")
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
	consoleFn("flint: error " + err.Error())
	return 1
}
