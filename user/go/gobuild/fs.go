package main

import (
	"os"
	"sort"
	"strings"
)

// The share-path file helpers. They go through package os so the same code
// runs on the host (unit tests, temp dirs) and in the guest (the syscall
// overlay serves ReadDir/ReadFile/WriteFile over the file channel — the same
// surface GOCMDCOMPILE.ELF already uses to read sources and write archives).

// readFile / writeFile are one-level wrappers so the seam is named where the
// guest's channel differs (write-open truncates unless append —
// kernel/src/file_table.zig's FAT-replace semantics).
func readFile(path string) ([]byte, error)  { return os.ReadFile(path) }
func writeFile(path string, b []byte) error { return os.WriteFile(path, b, 0o644) }

// listGoFiles returns dir's buildable-candidate .go files, sorted, skipping
// the exclusions the go tool applies: _test.go, dot/underscore-prefixed
// names.
func listGoFiles(dir string) ([]string, error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range ents {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") ||
			strings.HasSuffix(name, "_test.go") ||
			strings.HasPrefix(name, ".") || strings.HasPrefix(name, "_") {
			continue
		}
		out = append(out, name)
	}
	sort.Strings(out)
	return out, nil
}

func mkdirAll(dir string) error { return os.MkdirAll(dir, 0o755) }

func dirHasGoFiles(dir string) bool {
	files, err := listGoFiles(dir)
	return err == nil && len(files) > 0
}

// errorsPath is the fixed diagnostics path M107c consumes (see the package
// doc): the compiler-shaped aggregate for the last build attempt of a dir.
func errorsPath(workdir string) string { return joinPath(workdir, "ERRORS.TXT") }

// workDir is the driver's scratch + artifact directory under the program dir.
func workDir(dir string) string { return joinPath(dir, ".BUILD") }
