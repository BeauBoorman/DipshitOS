// Listing helpers for the M74a file manager (issue #1644, evolved from the
// M58a app).
//
// Path join/parent/base, the dirs-first listing order, the start-directory
// rule and the preview sanitizer are plain functions so the host `go test`
// run can pin them without a guest syscall. The 16-entry dir_list window and
// 64-byte path cap are the kernel's (file_table.max_path_len /
// handle_dir_list).
package main

import (
	"strings"

	"virelai/vi"
)

const (
	maxPath   = 64
	rootPath  = "/host"
	knownName = "KNOWN.TXT"

	// M100f (#2311, ADR 0050 D6): the synthetic volumes root sits above the
	// two mount names — the kernel never sees "/" as a path here because the
	// model lists the volume rows itself. `/disk` exists on a boot only when
	// a named data disk attached and its superblock validated.
	volsPath = "/"
	diskRoot = "/disk"
	volHost  = "host"
	volDisk  = "disk"
)

// diskMounted is the /disk mount probe: one dirlist of the VLFS root answers
// the kernel's not_mounted ENOENT when the boot attached no named data disk
// (ADR 0050 D6). A var so host tests pin both legs; on a host build the
// syscall is -ENOSYS, which reads as unmounted — the honest default.
var diskMounted = func() bool {
	var scratch [1]vi.DirEntry
	_, rc := vi.DirList(diskRoot, scratch[:])
	return rc >= 0
}

// volEntry fabricates one volumes-root row (both volumes are directories).
func volEntry(name string) vi.DirEntry {
	var e vi.DirEntry
	copy(e.Name[:], name)
	e.IsDir = 1
	return e
}

// volumeOf names the volume a path lives under ("" when neither — never the
// case for a path this app navigates to).
func volumeOf(path string) string {
	switch {
	case path == diskRoot || strings.HasPrefix(path, diskRoot+"/"):
		return volDisk
	case path == rootPath || strings.HasPrefix(path, rootPath+"/"):
		return volHost
	}
	return ""
}

// joinPath appends name under dir. It refuses ".." and a result longer
// than the kernel path cap, so a hostile name cannot walk off the share
// or trip ENAMETOOLONG on the next dir_list.
func joinPath(dir, name string) (string, bool) {
	if name == "" || name == "." || name == ".." {
		return "", false
	}
	for i := 0; i < len(name); i++ {
		if name[i] == '/' {
			return "", false
		}
	}
	if dir == "" {
		dir = rootPath
	}
	if len(dir) > 0 && dir[len(dir)-1] == '/' {
		dir = dir[:len(dir)-1]
	}
	out := dir + "/" + name
	if len(out) > maxPath {
		return "", false
	}
	return out, true
}

// parentPath walks one directory up, stopping at the host-share root.
func parentPath(path string) string {
	if path == "" || path == rootPath || path == "/" {
		return rootPath
	}
	if len(path) > 0 && path[len(path)-1] == '/' {
		path = path[:len(path)-1]
	}
	slash := -1
	for i := 0; i < len(path); i++ {
		if path[i] == '/' {
			slash = i
		}
	}
	if slash <= 0 {
		return rootPath
	}
	out := path[:slash]
	if out == "" || out == "/host" {
		return rootPath
	}
	return out
}

// baseName is the last path component ("" at the root).
func baseName(path string) string {
	if len(path) > 0 && path[len(path)-1] == '/' {
		path = path[:len(path)-1]
	}
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' {
			return path[i+1:]
		}
	}
	return path
}

// entryLabel is what the list shows: directories get a trailing slash.
func entryLabel(e vi.DirEntry) string {
	n := e.NameString()
	if n == "" {
		return n
	}
	if e.Dir() {
		return n + "/"
	}
	return n
}

// containsName reports whether the first n entries include name.
func containsName(entries []vi.DirEntry, n int, name string) bool {
	if n > len(entries) {
		n = len(entries)
	}
	for i := 0; i < n; i++ {
		if entries[i].NameString() == name {
			return true
		}
	}
	return false
}

// labelsOf builds the list item slice for the first n entries.
func labelsOf(entries []vi.DirEntry, n int) []string {
	if n > len(entries) {
		n = len(entries)
	}
	if n <= 0 {
		return nil
	}
	out := make([]string, n)
	for i := 0; i < n; i++ {
		out[i] = entryLabel(entries[i])
	}
	return out
}

// sortEntries puts directories first, then files, each group by name — the
// order the class-B gate pins (SUB before KNOWN.TXT) and the order that
// makes "the first row is the directory to navigate into" deterministic
// regardless of the share's on-disk order.
func sortEntries(entries []vi.DirEntry, n int) {
	if n > len(entries) {
		n = len(entries)
	}
	// Insertion sort: n <= 16, stability irrelevant, no allocation.
	for i := 1; i < n; i++ {
		v := entries[i]
		j := i - 1
		for j >= 0 && entryLess(v, entries[j]) {
			entries[j+1] = entries[j]
			j--
		}
		entries[j+1] = v
	}
}

// entryLess is the dirs-first, name-ascending order.
func entryLess(a, b vi.DirEntry) bool {
	if a.Dir() != b.Dir() {
		return a.Dir()
	}
	return a.NameString() < b.NameString()
}

// startPath is the directory the manager opens at: argv[1] when the
// launcher passed one (the gate execs `GOFILES.ELF /host/FM`), else the
// host-share root. vi.Args() is empty on the host, so this pins to
// rootPath there.
func startPath() string {
	args := vi.Args()
	if len(args) > 1 && len(args[1]) > 0 && len(args[1]) <= maxPath {
		return args[1]
	}
	return rootPath
}

// sanitizePreview turns raw file bytes into display text for the preview
// pane: newlines are kept, tabs become spaces, and every other
// non-printable byte becomes '·' so a binary file cannot smuggle escape
// sequences into the frame (byte-wise by design — v1 previews text).
func sanitizePreview(b []byte) string {
	out := make([]byte, 0, len(b))
	for _, c := range b {
		switch {
		case c == '\n':
			out = append(out, '\n')
		case c == '\t':
			out = append(out, ' ')
		case c >= 0x20 && c < 0x7f:
			out = append(out, c)
		default:
			out = append(out, 0xc2, 0xb7) // '·' as UTF-8
		}
	}
	return string(out)
}
