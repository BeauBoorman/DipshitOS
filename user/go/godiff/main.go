// GODIFF.ELF -- unified context diff CLI (M107e #2322 capstone).
// Usage: GODIFF.ELF [-u<n>] <a> <b>. Exits 0 same / 1 differ / 2 usage /
// 3 io / 4 too_large. Prints ---/+++ headers then each @@ hunk, then a
// summary line so a gate can assert the outcome without parsing output.
package main

import (
	"strconv"
	"strings"

	"virelai/vi"
)

const defCtx = 3

// cliArgs drops argv[0] when the loader passes the program name.
func cliArgs(raw []string) []string {
	if len(raw) == 0 {
		return nil
	}
	first := strings.ToUpper(raw[0])
	if strings.HasSuffix(first, ".ELF") || first == "GODIFF" {
		return raw[1:]
	}
	return raw
}

func run(args []string) int {
	ctx := defCtx
	var paths []string
	for _, a := range args {
		if strings.HasPrefix(a, "-u") {
			n, err := strconv.Atoi(a[2:])
			if err != nil || n < 0 || n > 99 {
				vi.ConsoleLine("godiff: usage: GODIFF.ELF [-u<n>] <a> <b>")
				return 2
			}
			ctx = n
			continue
		}
		paths = append(paths, a)
	}
	if len(paths) != 2 {
		vi.ConsoleLine("godiff: usage: GODIFF.ELF [-u<n>] <a> <b>")
		return 2
	}
	a, ra := vi.ReadFileAll(paths[0], vi.MaxFileBytes)
	if ra < 0 {
		vi.ConsoleLine("godiff: cannot read " + paths[0])
		return 3
	}
	b, rb := vi.ReadFileAll(paths[1], vi.MaxFileBytes)
	if rb < 0 {
		vi.ConsoleLine("godiff: cannot read " + paths[1])
		return 3
	}
	text, differ, tooBig := Diff(string(a), string(b), ctx)
	if tooBig {
		vi.ConsoleLine("godiff: too large")
		return 4
	}
	if !differ {
		vi.ConsoleLine("godiff: files identical")
		return 0
	}
	vi.ConsoleLine("--- " + paths[0])
	vi.ConsoleLine("+++ " + paths[1])
	lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	for _, ln := range lines {
		vi.ConsoleLine(ln)
	}
	vi.ConsoleLine("godiff: files differ hunks=" + strconv.Itoa(strings.Count(text, "@@ -")))
	return 1
}

func main() {
	vi.Yield()
	vi.Exit(run(cliArgs(vi.Args())))
}
