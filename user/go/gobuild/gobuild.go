// GOBUILD.ELF — the M107a (#2318) in-guest build driver: walk a program's
// import graph with go/parser (the in-guest capability M103a proved), write
// each package a -importcfg naming the archives its imports resolve to, and
// drive the guest's own GOCMDCOMPILE.ELF once per package plus GOCMDLINK.ELF
// once, sequencing the children by spawn-and-wait exactly as the M70c-S2
// reference loop (tools/go/selfhost.go) does — compile is a subprocess, never
// an in-process library call (ADR 0035 amendment 6).
//
// Package resolution order is pinned by the card: the program's own directory
// first (import "x" -> <dir>/x/*.go), then the package table's denylist
// (a policy refusal beats a stale archive), then the staged package archives
// an importcfg manifest names (the /host/GOIMPORT.CFG + GPKG_*.a layout
// tools/go/stage-selfhost.sh establishes from tools/go/pkg-table.txt). There
// is no in-guest std-from-source tier — M107b (#2319) ruled it out. The named
// refusals are M107b's half of the surface: dep_unsupported for a known
// package with no staged archive (or a denied one), no_package for a path in
// no table, closure_too_large past the 64-local-package cap, import_cycle.
//
// Diagnostics are the card's other half. A child's stderr reaches the parent
// through the B1 exec stream request (kernel/src/file_table.zig
// StreamRequest + syscall.zig's exec_stream_flag): the child is spawned with
// its fd-1 stream bound to a host-share file the parent opened, and because
// the port's os overlay collapses fd 2 onto the fd-1 stream (tools/go/
// overlay/syscall/fs_virelai.go Write), a Go child's stderr lands in the
// capture file too. The aggregate lands at <dir>/.BUILD/ERRORS.TXT in the
// compiler's own `file:line:col: message` shape, one diagnostic per line —
// the fixed path and format M107c consumes so it never touches this package.
package main

import (
	"strconv"
	"strings"
)

// Diag is one structured diagnostic in the compiler's `file:line:col: msg`
// shape. Code is a machine-readable class: "syntax" (the file's grammar
// refused it), "no_package", "import_cycle", "import_cgo", "compile", "link",
// "argv_too_long", "io". Diagnostics parsed out of a child's captured output
// carry the step name as Code ("compile"/"link") and the position the child
// reported.
type Diag struct {
	Code string
	File string
	Line int
	Col  int
	Msg  string
}

// String renders the ERRORS.TXT line: `file:line:col: message`. A driver
// diagnostic with no position names the file it was raised against anyway
// (the importing file for import errors); genuinely positionless failures
// report under the pseudo-file "gobuild" at 0:0.
func (d Diag) String() string {
	f := d.File
	if f == "" {
		f = "gobuild"
	}
	return f + ":" + strconv.Itoa(d.Line) + ":" + strconv.Itoa(d.Col) + ": " + d.Msg
}

// parseDiags extracts `path:line:col: msg` lines from a child's captured
// output — the exact grammar cmd/compile and cmd/link print for file
// diagnostics. Lines that do not match (banner noise, panic text) are kept
// as positionless "output" diags so ERRORS.TXT is never silently empty when
// a child failed.
func parseDiags(captured []byte, code string) []Diag {
	var out []Diag
	for _, line := range strings.Split(string(captured), "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		if d, ok := parseDiagLine(line, code); ok {
			out = append(out, d)
		} else {
			out = append(out, Diag{Code: code, Msg: line})
		}
	}
	return out
}

// parseDiagLine splits `path:line:col: msg`. Share paths carry no ':', so
// the first colon ends the path and digits follow; the MESSAGE may contain
// colons ("undefined: x"), which is why this walks left-to-right rather
// than peeling from the tail. Anything else is not a diagnostic line.
func parseDiagLine(line, code string) (Diag, bool) {
	i := strings.IndexByte(line, ':')
	if i <= 0 {
		return Diag{}, false
	}
	file := line[:i]
	rest := line[i+1:]
	readNum := func(s string) (int, string, bool) {
		j := 0
		for j < len(s) && s[j] >= '0' && s[j] <= '9' {
			j++
		}
		if j == 0 {
			return 0, s, false
		}
		n, err := strconv.Atoi(s[:j])
		return n, s[j:], err == nil
	}
	lineno, rest, ok := readNum(rest)
	if !ok || !strings.HasPrefix(rest, ":") {
		return Diag{}, false
	}
	col, rest, ok := readNum(rest[1:])
	if !ok || !strings.HasPrefix(rest, ":") {
		return Diag{}, false
	}
	return Diag{Code: code, File: file, Line: lineno, Col: col,
		Msg: strings.TrimLeft(rest[1:], " ")}, true
}

// writeErrors publishes the aggregate diagnostics file — one `file:line:col:
// msg` per line — at the fixed path every consumer (gosh, M107c's editor)
// reads. It is written on every build attempt, empty when clean, so a stale
// report can never outlive the build that superseded it.
func writeErrors(workdir string, diags []Diag) {
	var b strings.Builder
	for _, d := range diags {
		b.WriteString(d.String())
		b.WriteByte('\n')
	}
	_ = writeFile(errorsPath(workdir), []byte(b.String()))
}
