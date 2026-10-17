package main

import (
	"sort"
	"strings"
)

// The -importcfg file format is the one cmd/compile and cmd/link share:
// `packagefile <import path>=<file>` per line, `#` comments. The staged
// archive manifest /host/GOIMPORT.CFG (tools/go/stage-selfhost.sh) is
// exactly that format, so parsing it here is what makes a staged std import
// resolvable: `packagefile fmt=/host/GPKG_FMT.a` says where fmt's export
// data lives.

// parseImportcfg reads a manifest into import path -> archive path. A
// missing manifest is not an error — the build just resolves std imports to
// nothing and refuses by name later; a MALFORMED one is, since it means the
// staging is half-written.
func parseImportcfg(text string) (map[string]string, Diag) {
	m := map[string]string{}
	for n, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		rest, ok := strings.CutPrefix(line, "packagefile ")
		if !ok {
			return nil, Diag{Code: "bad_importcfg", Line: n + 1,
				Msg: "importcfg: expected `packagefile path=file`, got " + line}
		}
		path, file, ok := strings.Cut(rest, "=")
		if !ok || path == "" || file == "" {
			return nil, Diag{Code: "bad_importcfg", Line: n + 1,
				Msg: "importcfg: bad packagefile line " + line}
		}
		m[path] = file
	}
	return m, Diag{}
}

// loadArchives merges the manifest list (later files win on a duplicate
// path, which is how a workspace-local override of /host/GOIMPORT.CFG could
// shadow a staged archive once M107b exists).
func loadArchives(paths []string) (map[string]string, []Diag) {
	merged := map[string]string{}
	var diags []Diag
	for _, p := range paths {
		b, err := readFile(p)
		if err != nil {
			continue // absent manifest = no staged archives under that name
		}
		m, d := parseImportcfg(string(b))
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

// compileImportcfg writes pkg's compile-time importcfg: one packagefile line
// per direct import, resolving local deps to the archives the build is
// producing (build order guarantees they exist) and staged deps to their
// manifest paths. g must already be clean (no Diags) — resolution failures
// mean this is never called.
func compileImportcfg(g *Graph, workdir string, pkg *Package) []byte {
	var b strings.Builder
	b.WriteString("# gobuild: importcfg for " + pkg.Path + "\n")
	for _, imp := range pkg.Imports {
		dep := g.Packages[imp.Path]
		if dep == nil {
			continue // "unsafe", or impossible (resolution ran clean)
		}
		file := dep.Archive
		if dep.Local {
			file = archivePath(workdir, dep.Stem)
		}
		b.WriteString("packagefile " + dep.Path + "=" + file + "\n")
	}
	return []byte(b.String())
}

// linkImportcfg writes the linker's whole-closure importcfg: every staged
// archive the manifest names PLUS every local package's built archive — the
// linker walks the transitive closure itself, so it needs a row for any
// package it may meet, not just the program's direct imports.
func linkImportcfg(g *Graph, workdir string, archives map[string]string) []byte {
	var b strings.Builder
	b.WriteString("# gobuild: link importcfg (whole closure)\n")
	var staged []string
	for p := range archives {
		staged = append(staged, p)
	}
	sort.Strings(staged)
	for _, p := range staged {
		b.WriteString("packagefile " + p + "=" + archives[p] + "\n")
	}
	var locals []string
	for p, pkg := range g.Packages {
		if pkg.Local {
			locals = append(locals, p)
		}
	}
	sort.Strings(locals)
	for _, p := range locals {
		if p == "main" {
			continue // main is the linker's positional object, not a packagefile
		}
		b.WriteString("packagefile " + p + "=" +
			archivePath(workdir, g.Packages[p].Stem) + "\n")
	}
	return []byte(b.String())
}

// archivePath names the archive the driver builds a local package into.
// The stem — not the import path — is the name, because share name
// components cap at 31 bytes (kernel/src/file_table.zig): long paths
// ("github.com/charmbracelet/x/ansi/parser") take an indexed stem
// (assignStems), never a truncated one.
func archivePath(workdir, stem string) string {
	return joinPath(workdir, stem+".a")
}

// manglePath flattens an import path into one share-name component.
// "x/y" -> "x_y". Two different paths CAN collide here ("a/b" vs "a_b") —
// assignStems detects that pair (and any over-length stem) and gives the
// later one an indexed name rather than letting one overwrite the other's
// archive mid-build.
func manglePath(path string) string {
	var b strings.Builder
	for _, c := range path {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
			b.WriteByte(byte(c))
		default:
			b.WriteByte('_')
		}
	}
	return b.String()
}
