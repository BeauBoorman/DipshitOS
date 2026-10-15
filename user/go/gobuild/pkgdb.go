package main

import (
	"strconv"
	"strings"
)

// The package table (/host/GOPKGS.TXT) is the M107b oracle for imports that
// resolve under neither the local-dir rule nor an archive manifest: it tells
// a package that exists but has no staged archive (dep_unsupported) from a
// path that is not a package at all (no_package). stage-selfhost.sh
// generates it from tools/go/pkg-table.txt — one row per import path:
//
//	staged   <path>            a GPKG_*.a archive is on /host for it
//	denied   <path> <reason>   refused by name (dep_unsupported <path>: reason)
//	unstaged <path>            a real package with no archive shipped
//
// "Denied" carries two shapes the generator cannot tell apart textually but
// the driver does not need to: policy refusals (std-internal trees, command
// packages, overlay drop dirs) and measured build failures (crypto/x509 and
// everything that needs it, marked "needs <dep>").
type pkgRow struct {
	denied bool   // refused with dep_unsupported; reason says why
	reason string // human-readable refusal text (denied rows)
	known  bool   // path is in the universe at all (vs no_package)
}

// parsePkgTable reads the generated GOPKGS.TXT format. A missing table is not
// an error at the load layer — the build then just has no refusal oracle —
// but a MALFORMED one is: like a malformed importcfg it means the staging is
// half-written.
func parsePkgTable(text string) (map[string]pkgRow, Diag) {
	m := map[string]pkgRow{}
	for n, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		state, rest, ok := strings.Cut(line, " ")
		if !ok {
			return nil, Diag{Code: "bad_pkgdb", Line: n + 1,
				Msg: "pkg table: expected `<state> <path>`, got " + line}
		}
		fields := strings.SplitN(rest, " ", 2)
		path := fields[0]
		reason := ""
		if len(fields) == 2 {
			reason = strings.TrimSpace(fields[1])
		}
		if path == "" {
			return nil, Diag{Code: "bad_pkgdb", Line: n + 1,
				Msg: "pkg table: empty path: " + line}
		}
		switch state {
		case "staged", "unstaged":
			m[path] = pkgRow{known: true}
		case "denied":
			m[path] = pkgRow{denied: true, known: true, reason: reason}
		default:
			return nil, Diag{Code: "bad_pkgdb", Line: n + 1,
				Msg: "pkg table: unknown state " + strconv.Quote(state)}
		}
	}
	return m, Diag{}
}

// loadPkgTable merges the table list like loadArchives merges manifests —
// later files win on a duplicate path, so a workspace-local -pkgdb can
// restate a disposition (e.g. deny a package for a test) without touching
// the staged table.
func loadPkgTable(paths []string) (map[string]pkgRow, []Diag) {
	merged := map[string]pkgRow{}
	var diags []Diag
	for _, p := range paths {
		b, err := readFile(p)
		if err != nil {
			continue // absent table = no refusal oracle under that name
		}
		m, d := parsePkgTable(string(b))
		if d.Code != "" {
			d.File = p
			diags = append(diags, d)
			continue
		}
		for k, v := range m {
			merged[k] = v
		}
	}
	return merged, diags
}
