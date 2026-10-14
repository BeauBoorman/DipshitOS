package main

import (
	"sort"
	"strings"

	"virelai/flint/parser"
	"virelai/vi"
)

// parseCorpus walks <dir>/go and <dir>/zig, parses every source file into
// Atoms, writes <dir>.OUT = parser.Render(atoms) via vi.WriteFileSafe, and
// prints `flint: parse files=<n> atoms=<m> parse_errors=<e>`. Returns 0 only
// when e == 0 and the output was published cleanly.
func parseCorpus(dir string) int {
	dir = strings.TrimSuffix(dir, "/")
	var atoms []parser.Atom
	files := 0
	parseErrors := 0

	for _, sub := range []string{"go", "zig"} {
		subDir := dir + "/" + sub
		names, ok := listSourceFiles(subDir)
		if !ok {
			parseErrors++
			continue
		}
		for _, name := range names {
			rel := sub + "/" + name
			p, ok := parser.ForPath(rel)
			if !ok {
				continue
			}
			files++
			src, rc := vi.ReadFileAll(subDir+"/"+name, vi.MaxFileBytes)
			if rc < 0 {
				parseErrors++
				continue
			}
			fileAtoms, err := p.Parse(rel, src)
			if err != nil {
				parseErrors++
				continue
			}
			atoms = append(atoms, fileAtoms...)
		}
	}

	out := parser.Render(atoms)
	writeRC := vi.WriteFileSafe(dir+".OUT", out)

	consoleFn("flint: parse files=" + vi.Itoa64(int64(files)) +
		" atoms=" + vi.Itoa64(int64(len(atoms))) +
		" parse_errors=" + vi.Itoa64(int64(parseErrors)))

	if parseErrors != 0 || writeRC < 0 {
		return 1
	}
	return 0
}

// listSourceFiles enumerates non-directory entries in dir. It prefers
// vi.ListDirAt (the slot-79 paged directory snapshot ABI, up to 256 entries,
// needed for the 50-file corpus subdirectories) and falls back to the
// 16-entry vi.DirList window when slot 79 is unavailable (e.g. a minimal
// host test hook).
func listSourceFiles(dir string) ([]string, bool) {
	if items, err := vi.ListDirAt(canonShareDir(dir)); err == nil {
		names := make([]string, 0, len(items))
		for _, it := range items {
			if !it.IsDir {
				names = append(names, it.Name)
			}
		}
		sort.Strings(names)
		return names, true
	}
	var entries [vi.MaxDirEntries]vi.DirEntry
	n, rc := vi.DirList(dir, entries[:])
	if rc < 0 || n >= vi.MaxDirEntries {
		return nil, false
	}
	names := make([]string, 0, n)
	for _, e := range entries[:n] {
		if !e.Dir() {
			names = append(names, e.NameString())
		}
	}
	sort.Strings(names)
	return names, true
}

func canonShareDir(dir string) string {
	switch {
	case dir == "" || dir == "/host" || dir == "/host/":
		return "/"
	case strings.HasPrefix(dir, "/host/"):
		return dir[len("/host"):]
	case strings.HasPrefix(dir, "/"):
		return dir
	default:
		return "/" + dir
	}
}
