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

// dirEnt is one directory entry the driver needs: name + is-dir.
type dirEnt struct {
	name  string
	isDir bool
}

// dirEntries is the driver's directory listing — the implementations live
// in fs_list_virelai.go / fs_list_host.go. NEVER os.ReadDir on the guest:
// the virelai runtime's readdir is the legacy 16-row sys_dir_list window
// and a directory past 16 entries refuses ENOSPC
// (go-virelai/src/syscall/fs_virelai.go ReadDirent); the fleet's package
// dirs routinely exceed that.
func listGoFiles(dir string) ([]string, error) {
	ents, err := dirEntries(dir)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range ents {
		name := e.name
		if e.isDir || !strings.HasSuffix(name, ".go") ||
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
