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

	// M134b (#2760): the volumes root is the kernel's mount table now —
	// sys_dir_list("/") enumerates one row per mount (host, disk, usb,
	// usb1..usb4) and the model lists those kernel rows, never a fabricated
	// pair. `/disk` stays opt-in: its row names `not_mounted` when the boot
	// attached no named data disk (ADR 0050 D6).
	volsPath = "/"
	diskRoot = "/disk"
	volHost  = "host"
	volDisk  = "disk"
)

// mountRows is the kernel mount-table listing (M134b #2760): vi.Mounts on
// the guest, a stub in host tests. On a host build the syscall is -ENOSYS,
// which refreshVolumes reports as a plain list error.
var mountRows = vi.Mounts

// volEntry fabricates one volumes-root row (a directory — used by tests to
// seed the model without a kernel).
func volEntry(name string) vi.DirEntry {
	var e vi.DirEntry
	copy(e.Name[:], name)
	e.IsDir = 1
	return e
}

// isMountName names a kernel mount-table row: the share, the data volume,
// the raw block device, and the MBR FAT32 slots usb1..usb9 (the kernel
// itself accepts only 1..4 — the wider set keeps a stale row honest).
func isMountName(name string) bool {
	switch name {
	case volHost, volDisk, "usb":
		return true
	}
	return len(name) == 4 && name[0:3] == "usb" && name[3] >= '1' && name[3] <= '9'
}

// isMountRoot reports whether path IS a mount row itself ("/disk",
// "/usb1") — one component under "/" naming a volume.
func isMountRoot(path string) bool {
	return len(path) > 1 && path[0] == '/' &&
		strings.IndexByte(path[1:], '/') < 0 && isMountName(path[1:])
}

// volumeOf names the volume a path lives under ("" when none — never the
// case for a path this app navigates to).
func volumeOf(path string) string {
	if len(path) > 1 && path[0] == '/' {
		rest := path[1:]
		slash := strings.IndexByte(rest, '/')
		if slash < 0 {
			if isMountName(rest) {
				return rest
			}
			return ""
		}
		if isMountName(rest[:slash]) {
			return rest[:slash]
		}
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

// sortMode is the listing order — M125c (#2588) made it session state, so
// the restored tab re-sorts into the order the user left rather than
// always landing back on the default.
type sortMode uint8

const (
	// sortDirs puts directories first, then files, each group by name —
	// the order the class-B gate pins (SUB before KNOWN.TXT) and the order
	// that makes "the first row is the directory to navigate into"
	// deterministic regardless of the share's on-disk order.
	sortDirs sortMode = iota
	// sortName is one flat name-ascending order, dirs interleaved.
	sortName
	// sortSize is largest-first, name ascending to break ties.
	sortSize
	sortModeCount
)

// sortNameOf names a sortMode for the status line and the `gofiles: sort`
// marker — stable vocabulary the gate can assert.
func sortNameOf(mode sortMode) string {
	switch mode {
	case sortName:
		return "name"
	case sortSize:
		return "size"
	default:
		return "dirs"
	}
}

// sortEntries orders the first n entries under mode. Insertion sort:
// n <= 16, stability irrelevant, no allocation.
func sortEntries(entries []vi.DirEntry, n int, mode sortMode) {
	if n > len(entries) {
		n = len(entries)
	}
	for i := 1; i < n; i++ {
		v := entries[i]
		j := i - 1
		for j >= 0 && entryLess(v, entries[j], mode) {
			entries[j+1] = entries[j]
			j--
		}
		entries[j+1] = v
	}
}

// entryLess is the mode's order: sortDirs is dirs-first/name-ascending,
// sortName is flat by name, sortSize is largest-first by name.
func entryLess(a, b vi.DirEntry, mode sortMode) bool {
	switch mode {
	case sortName:
		return a.NameString() < b.NameString()
	case sortSize:
		if a.Size != b.Size {
			return a.Size > b.Size
		}
		return a.NameString() < b.NameString()
	default:
		if a.Dir() != b.Dir() {
			return a.Dir()
		}
		return a.NameString() < b.NameString()
	}
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
