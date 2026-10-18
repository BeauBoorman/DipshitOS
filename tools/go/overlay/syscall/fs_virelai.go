// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

// The GOOS=virelai file surface (issue #1525, M70c-S1P): the calls `os` and
// `internal/poll` make, mapped onto ADR 0007's file slots.
//
// The shape of the mapping, and why it is not a POSIX emulation:
//
//   - **Handles are the kernel's** (8 per process, slots 23-26/34-36/77).
//     A handle carries a cursor and nothing else: no seek, no pread, no
//     pwrite. Seeking is therefore answered from a per-handle shadow this
//     port keeps (see "positional I/O" below) — the toolchain's archive
//     reader and object writer both need it, and the kernel has no slot that
//     could provide it (issue #1543).
//   - **Directories are not handles.** sys_dir_list takes a PATH plus a row
//     buffer, so `Open` on a directory returns a synthetic fd from
//     `dirFdBase` and ReadDirent resolves it back to the path. A caller
//     therefore cannot `Write` a directory fd (EISDIR) or rely on its
//     number being small — internal/poll only ever passes it back.
//   - **A handle's size is not reportable.** The kernel knows it (the host
//     STAT fills h.size at open) but exposes no query, so Stat/Fstat answer
//     from a `sys_dir_list` row on the entry's parent, using the path the
//     port remembers for each handle. That is why Open records paths.
//   - **The listing window is 16 rows, with no offset** (handle_dir_list
//     clamps max_entries and always starts at the first entry). A directory
//     with more than 16 entries is therefore NOT enumerable at EL0 through
//     any seam that exists today; this port delivers the window and then
//     says so (ENOSPC) rather than returning a plausible partial list.
//     Closing that is a kernel change (a listing cursor on slot 27), not a
//     port change — filed against #1525.
package syscall

import "unsafe"

// dirFdBase is where synthetic directory fds start. It is above any real
// handle (the kernel's table is 8 entries) and above 0/1/2, so no caller can
// confuse the two, and `internal/poll` never interprets the value.
const dirFdBase = 1 << 20

type dirHandle struct {
	path string // the share path this fd lists
	live bool
	rows int  // rows already delivered
	sat  bool // the last window filled completely (there may be more)
}

var virDirs [8]dirHandle

// virFdPaths remembers what each real handle was opened with, because the
// kernel reports neither a handle's path nor its size. Index = the kernel's
// fd (its table is 8 entries per process).
var virFdPaths [8]string

// virFdFlags remembers the POSIX flag word of each handle. Nothing in the
// kernel can be asked for it: there is no fcntl slot, and os/file_unix.go's
// NewFile wants an answer to F_GETFL all the same (append mode, blocking).
// Recording it at Open is what makes that answer a derivation instead of a
// guess — see OpenFlags and internal/syscall/unix's Fcntl.
var virFdFlags [8]int

func rememberFd(fd int, path string, flags int) {
	if fd >= 0 && fd < len(virFdPaths) {
		virFdPaths[fd] = path
		virFdFlags[fd] = flags
	}
}

// OpenFlags returns the POSIX flag word a handle was opened with, or 0 for a
// handle this layer did not open (the console, a synthetic directory fd).
func OpenFlags(fd int) int {
	if fd >= 0 && fd < len(virFdFlags) {
		return virFdFlags[fd]
	}
	return 0
}

// ----- positional I/O over a cursor-only handle (M70c-S1T, issue #1543) -----
//
// The kernel's handle is a cursor and nothing else: slots 23-27, 34-36 and 77
// have no seek, no pread and no pwrite. An appends-only or streams-only
// caller never notices, which is how this port stayed honest while reporting
// Seek as ENOSYS. The Go toolchain notices. Observed on VZ while compiling
// tools/go/hello.go in the guest (M70c-S1T):
//
//	compile: seeking in output [0, 1]: seek /host/GPKG_runtime.a:
//	function not implemented
//
// That is cmd/internal/bio's Offset() asking a package archive where it is,
// after which cmd/internal/archive seeks to member offsets; the object writer
// seeks too (cmd/compile/internal/gc/obj.go patches the archive header after
// writing the members). So the port keeps a shadow of what each real handle
// has moved, plus the caller's logical position:
//
//	virShadow[fd] — the bytes moved through the handle, from offset 0. The
//	                kernel cursor is virCursor[fd], so the shadow covers
//	                everything the device can no longer rewind to.
//	virCursor[fd] — bytes the kernel has delivered or accepted.
//	virPos[fd]    — the position Read/Write/Seek move, which the kernel's
//	                cursor stops tracking the moment a seek happens.
//
// The shadow is bounded by virShadowMax. Past that bound the port stops
// retaining and keeps streaming a purely sequential reader — the common case,
// and the one the #1504 transfer measurement exercises — while REFUSING a
// positional request it can no longer answer rather than serving bytes from
// the wrong offset.
//
// Writes are staged in the shadow and pushed to the handle at Fsync/Close,
// because a patch (seek back, write, seek forward) cannot be applied to a
// cursor-only device. That cost is named rather than hidden: a writer's file
// lives in memory until it closes, and a process that dies without closing
// loses it. cmd/compile closes its object; cmd/link closes its output.
const virShadowMax = 16 << 20

var (
	virShadow  [8][]byte
	virCursor  [8]int64
	virPos     [8]int64
	virWrite   [8]bool // opened for writing: its bytes are staged
	virFlushed [8]bool // the staged bytes are already on the handle
)

// shadowed reports whether fd is a real file handle this port opened. The
// console and inherited handles are not: they have no position to keep, and
// Read/Write keep their unchanged sequential path for them.
func shadowed(fd int) bool {
	return fd >= 0 && fd < len(virFdPaths) && virFdPaths[fd] != ""
}

func virReset(fd int) {
	if fd < 0 || fd >= len(virShadow) {
		return
	}
	virShadow[fd] = nil
	virCursor[fd] = 0
	virPos[fd] = 0
	virWrite[fd] = false
	virFlushed[fd] = false
}

// virKeep appends to the shadow while it has room. Dropping the tail past
// the cap is what makes the bound a bound; virRetained reports how far the
// shadow can still be trusted.
func virKeep(fd int, b []byte) {
	room := virShadowMax - len(virShadow[fd])
	if room <= 0 {
		return
	}
	if len(b) > room {
		b = b[:room]
	}
	virShadow[fd] = append(virShadow[fd], b...)
}

// virRetained is how much of [0, cursor) the shadow can still serve.
func virRetained(fd int) int64 {
	n := int64(len(virShadow[fd]))
	if n > virCursor[fd] {
		n = virCursor[fd]
	}
	return n
}

// virPull advances the kernel cursor to `target`, retaining what it reads
// while the shadow has room. A result short of target means the handle ended
// first (EOF at the caller).
func virPull(fd int, target int64, scratch []byte) (int64, error) {
	for virCursor[fd] < target {
		want := target - virCursor[fd]
		if want > int64(len(scratch)) {
			want = int64(len(scratch))
		}
		r := svc3(virSysRead, uintptr(fd), uintptr(unsafe.Pointer(&scratch[0])), uintptr(want))
		if r < 0 {
			return virCursor[fd], errnoErr(errOf(r))
		}
		if r == 0 {
			break
		}
		n := int64(r)
		virKeep(fd, scratch[:n])
		virCursor[fd] += n
	}
	return virCursor[fd], nil
}

// virSize is the handle's size for SEEK_END: what a writer has staged, or the
// share's own row for a reader (there is no size query on a handle, so this is
// the same parent-row route Stat takes).
func virSize(fd int) (int64, error) {
	if virWrite[fd] {
		return int64(len(virShadow[fd])), nil
	}
	p, ok := fdPath(fd)
	if !ok {
		return 0, EBADF
	}
	st, err := statPath(p)
	if err != nil {
		return 0, err
	}
	return st.Size, nil
}

// virFlush pushes a staged write onto the handle in order. It is the only
// route a staged byte has to the device, and it runs once: after it the
// handle cannot be rewound, so only appends are answerable.
func virFlush(fd int) error {
	if !virWrite[fd] || virFlushed[fd] || len(virShadow[fd]) == 0 {
		return nil
	}
	buf := virShadow[fd]
	for off := 0; off < len(buf); {
		chunk := buf[off:]
		if len(chunk) > virIOChunkMax {
			chunk = chunk[:virIOChunkMax]
		}
		r := svc3(virSysWrite, uintptr(fd), uintptr(unsafe.Pointer(&chunk[0])), uintptr(len(chunk)))
		if r < 0 {
			return errnoErr(errOf(r))
		}
		if r == 0 {
			return EIO
		}
		off += int(r)
	}
	virCursor[fd] = int64(len(buf))
	virFlushed[fd] = true
	return nil
}

// virWriteTo stages a write at the handle's logical position. It cannot go
// straight to the device, because the caller may seek back and patch it —
// which is exactly what the object writer does.
func virWriteTo(fd int, p []byte) (int, error) {
	if !virWrite[fd] {
		// A read-open handle: the kernel owns that refusal (EBADF).
		if len(p) > virIOChunkMax {
			p = p[:virIOChunkMax]
		}
		r := svc3(virSysWrite, uintptr(fd), uintptr(unsafe.Pointer(&p[0])), uintptr(len(p)))
		if r < 0 {
			return 0, errnoErr(errOf(r))
		}
		return int(r), nil
	}
	if virFlushed[fd] {
		if virPos[fd] != virCursor[fd] {
			return 0, ENOSYS
		}
		if len(p) > virIOChunkMax {
			p = p[:virIOChunkMax]
		}
		r := svc3(virSysWrite, uintptr(fd), uintptr(unsafe.Pointer(&p[0])), uintptr(len(p)))
		if r < 0 {
			return 0, errnoErr(errOf(r))
		}
		virCursor[fd] += int64(r)
		virPos[fd] = virCursor[fd]
		return int(r), nil
	}
	pos := virPos[fd]
	end := pos + int64(len(p))
	if end > virShadowMax {
		return 0, ENOSYS
	}
	buf := virShadow[fd]
	if int64(len(buf)) < end {
		// Growing past what was written creates a hole, which reads as
		// zeros — the same thing the file will contain.
		buf = append(buf, make([]byte, end-int64(len(buf)))...)
	}
	copy(buf[pos:], p)
	virShadow[fd] = buf
	virPos[fd] = end
	return len(p), nil
}

// Pread reads at an offset without moving the logical position, out of the
// same shadow the sequential path builds. It never rewinds the kernel cursor;
// it moves it forward only to reach bytes it has not pulled yet.
func Pread(fd int, p []byte, offset int64) (n int, err error) {
	if _, ok := dirFdFor(fd); ok {
		return 0, EISDIR
	}
	if !shadowed(fd) || offset < 0 {
		return 0, ENOSYS
	}
	if len(p) == 0 {
		return 0, nil
	}
	scratch := make([]byte, virIOChunkMax)
	if want := offset + int64(len(p)); want > virCursor[fd] {
		if _, err := virPull(fd, want, scratch); err != nil {
			return 0, err
		}
	}
	if offset >= virRetained(fd) {
		return 0, nil // the handle ended before that offset
	}
	return copy(p, virShadow[fd][offset:]), nil
}

func fdPath(fd int) (string, bool) {
	if fd >= 0 && fd < len(virFdPaths) {
		if p := virFdPaths[fd]; p != "" {
			return p, true
		}
	}
	return "", false
}

// dirFdFor returns the entry for a synthetic fd, or ok=false.
func dirFdFor(fd int) (int, bool) {
	i := fd - dirFdBase
	if i < 0 || i >= len(virDirs) || !virDirs[i].live {
		return 0, false
	}
	return i, true
}

// ----- the dirent record ---------------------------------------------------

// Dirent is the kernel's own sys_dir_list row (file_table.DirEntry),
// exposed verbatim as this GOOS's directory record: name[32] NUL-padded,
// size, an is-dir byte, three reserved bytes. Reusing the row means
// ReadDirent is a copy, not a translation, and the parse side (dirent.go's
// direntReclen/direntIno/direntNamlen, below) reads the same numbers the
// kernel wrote.
type Dirent struct {
	Name     [32]byte
	Size     uint32
	IsDir    uint8
	Reserved [3]byte
}

const direntSize = int(unsafe.Sizeof(Dirent{})) // 40

func direntReclen(buf []byte) (uint64, bool) { return uint64(direntSize), len(buf) >= direntSize }

// direntIno has no kernel source: the share has no inode numbers. Reporting
// 0 (rather than a hash that looks like an identity) keeps a caller from
// caching on a value that means nothing.
func direntIno(buf []byte) (uint64, bool) { return 0, len(buf) >= direntSize }

func direntNamlen(buf []byte) (uint64, bool) {
	if len(buf) < direntSize {
		return 0, false
	}
	d := (*Dirent)(unsafe.Pointer(&buf[0]))
	for i := 0; i < len(d.Name); i++ {
		if d.Name[i] == 0 {
			return uint64(i), true
		}
	}
	return uint64(len(d.Name)), true
}

func direntType(buf []byte) (uint8, bool) {
	if len(buf) < direntSize {
		return 0, false
	}
	d := (*Dirent)(unsafe.Pointer(&buf[0]))
	if d.IsDir != 0 {
		return 4, true // DT_DIR
	}
	return 8, true // DT_REG
}

// ----- the file calls ------------------------------------------------------

// Open opens path (the kernel word is built by kernelOpenFlags above; it is
// NOT the POSIX block). A read-only open of a directory yields a
// synthetic fd that ReadDirent can list; every other open is the kernel's.
// The KERNEL's own open flag word (kernel/src/file_table.zig MODE_*). It is
// NOT the POSIX block above: MODE_READ is 0x1, there is no zero-valued
// "read" (the kernel refuses flags == 0 outright), the create/append/dir
// bits are small and packed, and any bit outside the five is refused with
// EINVAL. Getting this wrong is the one translation error the port cannot
// paper over, so the two words live apart and the names never collide.
const (
	kmodeRead   = 0x1
	kmodeWrite  = 0x2
	kmodeCreate = 0x4
	kmodeAppend = 0x8
	kmodeDir    = 0x10
)

// kernelOpenFlags translates the POSIX word Open is handed into the kernel's
// MODE_* bits, and reports the two flags the kernel's open slot cannot carry:
// truncation (its own slot) and O_EXCL (checked by the caller).
//
// Unmappable bits are dropped rather than refused: O_CLOEXEC has no meaning
// at EL0 (no exec inheritance), O_NONBLOCK is already the kernel's only read
// mode, and O_NOFOLLOW/O_DIRECTORY are unobservable because no symlinks
// exist here. O_EXCL is the one that would be dishonest to drop.
func kernelOpenFlags(mode int) (kernel uint32, trunc, excl bool) {
	switch mode & (O_WRONLY | O_RDWR) {
	case O_WRONLY:
		kernel = kmodeWrite
	case O_RDWR:
		kernel = kmodeRead | kmodeWrite
	default:
		// POSIX O_RDONLY is 0: a zero word is the read-only open, and the
		// kernel's MODE_READ is what it has to become. Passing the POSIX 0
		// through is the mistake this function exists to prevent.
		kernel = kmodeRead
	}
	if mode&O_CREAT != 0 {
		kernel |= kmodeCreate
	}
	if mode&O_APPEND != 0 {
		kernel |= kmodeAppend
	}
	if mode&O_DIRECTORY != 0 {
		kernel |= kmodeDir
	}
	return kernel, mode&O_TRUNC != 0, mode&O_EXCL != 0
}

func Open(path string, mode int, perm uint32) (fd int, err error) {
	flags, trunc, excl := kernelOpenFlags(mode)
	if excl && flags&kmodeCreate != 0 {
		// Not atomic: the open slot has no exclusive-create mode, so the
		// refusal is a probe followed by the create. Named as a gap in the
		// port's header rather than left silent.
		if virPathExists(path) {
			return -1, EEXIST
		}
	}

	// Directory probe. Read-only opens only: a write/create open of a
	// directory is the kernel's business (MODE_DIR creation). The probe
	// cannot produce a wrong answer — any failure falls through to the real
	// open — and it is one syscall, which is cheaper than the ambiguity of
	// a dir handle that reads as empty. `flags` here is already the kernel
	// word, so the comparison is against MODE_READ/MODE_DIR, not O_RDONLY.
	if flags == kmodeRead || flags == (kmodeRead|kmodeDir) {
		if isDir(path) {
			return newDirFd(path)
		}
	}

	var staging [virPathMax + 1]byte
	n := stagedAbs(path, &staging)
	if n < 0 {
		if len(path) > virPathMax {
			return -1, ENAMETOOLONG
		}
		return -1, EINVAL
	}
	r := svc3(virSysFileOpen, uintptr(unsafe.Pointer(&staging[0])), uintptr(n), uintptr(flags))
	if r < 0 {
		return -1, errnoErr(errOf(r))
	}
	fd = int(r)
	rememberFd(fd, path, mode)
	// This handle is now one the port can position (see "positional I/O"):
	// a write-open is stageable. The kernel truncated the file on a fresh
	// write-open WITHOUT MODE_APPEND, so the shadow starts where it does.
	virReset(fd)
	virWrite[fd] = flags&(kmodeWrite|kmodeAppend) != 0
	// O_TRUNC needs no second call: the kernel's write-open WITHOUT
	// MODE_APPEND already has replace semantics (file_table.open: "a fresh
	// write-open truncates"), so the open itself emptied the file. Calling the
	// port's by-path Truncate here is what made every os.WriteFile fail with
	// ENOSYS — that function is an honest refusal (slot 36 is
	// handle-addressed), and this route never needed it.
	_ = trunc
	return fd, nil
}

// Openat ignores dirfd: this kernel has no relative resolution (every path
// is absolute on the share), so treating a relative path as absolute would
// be a lie. Callers that pass a real dirfd get ENOSYS.
func Openat(dirfd int, path string, mode int, perm uint32) (fd int, err error) {
	if _, ok := dirFdFor(dirfd); ok {
		return -1, ENOSYS
	}
	if dirfd != AT_FDCWD {
		return -1, ENOSYS
	}
	return Open(path, mode, perm)
}

const (
	AT_FDCWD            = -0x64
	AT_SYMLINK_NOFOLLOW = 0x100 // accepted and ignored: no symlinks exist
)

func newDirFd(path string) (int, error) {
	for i := range virDirs {
		if !virDirs[i].live {
			virDirs[i] = dirHandle{path: path, live: true}
			return dirFdBase + i, nil
		}
	}
	return -1, EMFILE
}

// Fchdir sets the working directory from an open handle. The kernel has no
// fchdir slot — the working directory is per-process kernel state set by
// PATH (sys_chdir) — so the port answers from the path it remembered for the
// handle at open, and, for a synthetic directory fd, from the path that fd
// was created to list. A handle this layer did not open has no path to give
// and is reported as EBADF, which is what a caller can act on.
func Fchdir(fd int) error {
	if i, ok := dirFdFor(fd); ok {
		return Chdir(virDirs[i].path)
	}
	if p, ok := fdPath(fd); ok {
		return Chdir(p)
	}
	return EBADF
}

// virPathExists reports whether a share entry with this name exists, through
// the same route Stat takes: there is no stat-by-name slot, so existence is
// learned from a directory row on the entry's parent.
func virPathExists(path string) bool {
	_, err := statPath(path)
	return err == nil
}

// isDir reports whether path is a directory by trying to list it. Any
// failure means "not a directory as far as this kernel can tell".
func isDir(path string) bool {
	var staging [virPathMax + 1]byte
	n := stagedAbs(path, &staging)
	if n < 0 {
		return false
	}
	var row [direntSize]byte
	r := svc4(virSysDirList, uintptr(unsafe.Pointer(&staging[0])), uintptr(n),
		uintptr(unsafe.Pointer(&row[0])), 1)
	return r >= 0
}

// Read moves up to one kernel read into p. The kernel clamps a call to
// 2048 bytes, so a short read is normal and is not an error (only writing
// can lose data). A zero return means EOF: the kernel's read is
// level-triggered at the handle's cursor and reports 0 at the end.
//
// When the handle's logical position is behind what the port has already
// moved, the bytes come from the shadow and the kernel is not touched (see
// "positional I/O" below).
func Read(fd int, p []byte) (n int, err error) {
	if _, ok := dirFdFor(fd); ok {
		return 0, EISDIR
	}
	if len(p) == 0 {
		return 0, nil
	}
	if !shadowed(fd) {
		if len(p) > virIOChunkMax {
			p = p[:virIOChunkMax]
		}
		r := svc3(virSysRead, uintptr(fd), uintptr(unsafe.Pointer(&p[0])), uintptr(len(p)))
		if r < 0 {
			return 0, errnoErr(errOf(r))
		}
		return int(r), nil
	}

	var scratch [virIOChunkMax]byte
	pos := virPos[fd]
	// The position is inside what the kernel has already delivered but
	// outside what the shadow retained (it is capped). Those bytes are gone
	// from the port's view: refusing is the only honest answer.
	if pos < virCursor[fd] && pos >= virRetained(fd) {
		return 0, ENOSYS
	}
	if pos > virCursor[fd] {
		// A forward skip: the bytes go through the kernel and only the ones
		// inside the retained window are kept.
		if _, err := virPull(fd, pos, scratch[:]); err != nil {
			return 0, err
		}
	}
	if pos < virRetained(fd) {
		avail := virRetained(fd) - pos
		if int64(len(p)) > avail {
			p = p[:int(avail)]
		}
		n = copy(p, virShadow[fd][pos:])
		virPos[fd] = pos + int64(n)
		return n, nil
	}
	if len(p) > virIOChunkMax {
		p = p[:virIOChunkMax]
	}
	r := svc3(virSysRead, uintptr(fd), uintptr(unsafe.Pointer(&p[0])), uintptr(len(p)))
	if r < 0 {
		return 0, errnoErr(errOf(r))
	}
	if r > 0 {
		n = int(r)
		virKeep(fd, p[:n])
		virCursor[fd] += int64(n)
		virPos[fd] = pos + int64(n)
	}
	return n, nil
}

// Write moves up to one kernel write and reports the short write, which is
// what the raw contract (and internal/poll's completion loop) expects.
//
// fd 1 and fd 2 are the CONSOLE, not the file channel. The kernel's
// sys_write (slot 1) writes straight to the monitor console, accepts only
// fd 1, and is capped at write_cap (256). std's os.Stdout/os.Stderr live on
// exactly those numbers and there is no /dev/stdout to open instead, so a
// console write is what they have to resolve to. fd 2 is mapped onto the
// console's single stream rather than refused: a guest writing to stderr
// should be seen, and the kernel has one stream to be seen on.
//
// Every other fd is a file-channel handle (slot 25, capped at 2048).
func Write(fd int, p []byte) (n int, err error) {
	if _, ok := dirFdFor(fd); ok {
		return 0, EISDIR
	}
	if len(p) == 0 {
		return 0, nil
	}
	if fd == 1 || fd == 2 {
		if len(p) > virConsoleWriteMax {
			p = p[:virConsoleWriteMax]
		}
		r := svc3(virSysConsoleWrite, uintptr(1), uintptr(unsafe.Pointer(&p[0])), uintptr(len(p)))
		if r < 0 {
			return 0, errnoErr(errOf(r))
		}
		return int(r), nil
	}
	if shadowed(fd) {
		return virWriteTo(fd, p)
	}
	if len(p) > virIOChunkMax {
		p = p[:virIOChunkMax]
	}
	r := svc3(virSysWrite, uintptr(fd), uintptr(unsafe.Pointer(&p[0])), uintptr(len(p)))
	if r < 0 {
		return 0, errnoErr(errOf(r))
	}
	return int(r), nil
}

func Close(fd int) error {
	if i, ok := dirFdFor(fd); ok {
		virDirs[i] = dirHandle{}
		return nil
	}
	// A staged write reaches the device here: the handle cannot be rewound,
	// so this is its only entry point (documented at virFlush).
	if err := virFlush(fd); err != nil {
		return err
	}
	r := svc1(virSysClose, uintptr(fd))
	if fd >= 0 && fd < len(virFdPaths) {
		virFdPaths[fd] = ""
		virFdFlags[fd] = 0
	}
	virReset(fd)
	if r < 0 {
		return errnoErr(errOf(r))
	}
	return nil
}

// Fsync pushes the handle's bytes to the host device (slot 77). A stateless
// read handle is an honest no-op in the kernel.
func Fsync(fd int) error {
	if _, ok := dirFdFor(fd); ok {
		return nil
	}
	// An fsync of a staged write means "get it on the device now" — which is
	// exactly the flush, so it happens before the kernel is asked to sync.
	if err := virFlush(fd); err != nil {
		return err
	}
	r := svc1(virSysFileSync, uintptr(fd))
	if r < 0 {
		return errnoErr(errOf(r))
	}
	return nil
}

// Ftruncate resizes an OPEN handle (slot 36). The kernel requires a write
// handle for it.
func Ftruncate(fd int, length int64) error {
	if _, ok := dirFdFor(fd); ok {
		return EISDIR
	}
	if length < 0 || length > 0xffffffff {
		return EINVAL
	}
	// A staged write is truncated where the caller sees it: the device will
	// only be told at the flush, so truncating the device underneath the
	// shadow would hand the next read the untruncated bytes.
	if shadowed(fd) && virWrite[fd] && !virFlushed[fd] {
		if int64(len(virShadow[fd])) > length {
			virShadow[fd] = virShadow[fd][:length]
		}
		if virPos[fd] > length {
			virPos[fd] = length
		}
		return nil
	}
	r := svc2(virSysTruncate, uintptr(fd), uintptr(length))
	if r < 0 {
		return errnoErr(errOf(r))
	}
	return nil
}

// Truncate is not available by path: slot 36 is handle-addressed, so this
// opens, truncates and closes — which changes the semantics for a path
// that is not writable and is therefore reported rather than hidden.
func Truncate(path string, length int64) error {
	return ENOSYS
}

// Seek moves the handle's LOGICAL position (see "positional I/O" above).
// The kernel's cursor is not moved by it, so seeking is free until bytes are
// actually read, and a backwards seek over bytes the shadow retained costs no
// syscall at all.
func Seek(fd int, offset int64, whence int) (int64, error) {
	if _, ok := dirFdFor(fd); ok {
		return 0, EISDIR
	}
	if !shadowed(fd) {
		// A handle this port did not open (the console) has no position to
		// keep: an offset means nothing there, and the sequential path is
		// already the right one.
		return 0, ENOSYS
	}
	var base int64
	switch whence {
	case 0: // io.SeekStart
		base = 0
	case 1: // io.SeekCurrent
		base = virPos[fd]
	case 2: // io.SeekEnd
		sz, err := virSize(fd)
		if err != nil {
			return 0, err
		}
		base = sz
	default:
		return 0, EINVAL
	}
	target := base + offset
	if target < 0 {
		return 0, EINVAL
	}
	virPos[fd] = target
	return target, nil
}

func Dup(fd int) (int, error)                           { return -1, ENOSYS }
func Dup3(oldfd, newfd, flags int) error                { return ENOSYS }
func Fcntl(fd int, cmd int, arg int) (int, error)       { return -1, ENOSYS }
func FcntlFlock(fd uintptr, cmd int, lk *Flock_t) error { return ENOSYS }
func SetNonblock(fd int, nonblocking bool) error        { return nil }

// Flock_t exists for os/exec's shape; locking is not a kernel capability.
type Flock_t struct {
	Type   int16
	Whence int16
	Start  int64
	Len    int64
	Pid    int32
	Pad    [4]byte
}

// Pipe is ENOSYS. The kernel has pipe slots (56/57) but they are a SHARED
// per-process pipe, not a pipe pair with two fds, so os.Pipe's contract
// (two independent handles, EOF on the read end when the write end closes)
// cannot be met without inventing state the kernel does not have.
func Pipe(p []int) error { return ENOSYS }

// ----- path-mutating calls -------------------------------------------------

// Mkdir creates a directory: the kernel's directory creation rides the
// mutating open flags, so this is Open(MODE_WRITE|MODE_CREATE|MODE_DIR)
// plus an immediate close. The permission argument is accepted and ignored
// — there is no mode model at EL0 (ADR 0024 D1; slot 69 sets the M50
// ownership table, which is a different thing).
func Mkdir(path string, perm uint32) error {
	var staging [virPathMax + 1]byte
	n := stagedAbs(path, &staging)
	if n < 0 {
		if len(path) > virPathMax {
			return ENAMETOOLONG
		}
		return EINVAL
	}
	r := svc3(virSysFileOpen, uintptr(unsafe.Pointer(&staging[0])), uintptr(n),
		uintptr(kmodeWrite|kmodeCreate|kmodeDir))
	if r < 0 {
		return errnoErr(errOf(r))
	}
	svc1(virSysClose, uintptr(int(r)))
	return nil
}

// Rmdir is not the same call as Unlink: the kernel's sys_file_delete
// removes a file, and a directory is only removable through it if the host
// allows it. The distinction is kept because callers depend on it.
func Rmdir(path string) error { return deletePath(path) }

func Unlink(path string) error { return deletePath(path) }

func deletePath(path string) error {
	var staging [virPathMax + 1]byte
	n := stagedAbs(path, &staging)
	if n < 0 {
		if len(path) > virPathMax {
			return ENAMETOOLONG
		}
		return EINVAL
	}
	r := svc2(virSysDelete, uintptr(unsafe.Pointer(&staging[0])), uintptr(n))
	if r < 0 {
		return errnoErr(errOf(r))
	}
	return nil
}

// Rename publishes oldPath as newPath (slot 35). The host REFUSES a live
// target (the file-domain EEXIST), so this is not a POSIX rename-over.
func Rename(from, to string) error {
	var old, cur [virPathMax + 1]byte
	nf := stagedAbs(from, &old)
	if nf < 0 {
		return EINVAL
	}
	nt := stagedAbs(to, &cur)
	if nt < 0 {
		return EINVAL
	}
	r := svc4(virSysRename, uintptr(unsafe.Pointer(&old[0])), uintptr(nf),
		uintptr(unsafe.Pointer(&cur[0])), uintptr(nt))
	if r < 0 {
		return errnoErr(errOf(r))
	}
	return nil
}

func Link(oldpath, newpath string) error                  { return ENOSYS }
func Symlink(oldpath, newpath string) error               { return ENOSYS }
func Readlink(path string, buf []byte) (n int, err error) { return 0, EINVAL }
func Chmod(path string, mode uint32) error                { return ENOSYS }
func Chown(path string, uid, gid int) error               { return ENOSYS }
func Lchown(path string, uid, gid int) error              { return ENOSYS }
func Fchmod(fd int, mode uint32) error                    { return ENOSYS }
func Fchown(fd int, uid, gid int) error                   { return ENOSYS }

// ----- stat --------------------------------------------------------------

// listRows lists dir into a local row array. max is clamped by the kernel to
// 16 (virDirRowsMax), and the listing ALWAYS starts at the first entry —
// there is no cursor in the ABI, which is what makes a >16-entry directory
// unenumerable (see ReadDirent).
// An EMPTY dir means the share root: the kernel reads path_len == 0 as
// "list the root" (handle_dir_list copies the path in only when there is
// one), which is also how the guest SDK lists it. Passed through instead of
// resolved because resolvePath("") is an error by contract — and a
// root-level entry (splitParent leaves "" for "<root>/NAME") is exactly the
// case this exists for.
func listRows(dir string, max int) ([]Dirent, error) {
	if max <= 0 || max > virDirRowsMax {
		max = virDirRowsMax
	}
	var staging [virPathMax + 1]byte
	n := 0
	if dir != "" {
		n = stagedAbs(dir, &staging)
		if n < 0 {
			return nil, EINVAL
		}
	}
	rows := make([]Dirent, max)
	r := svc4(virSysDirList, uintptr(unsafe.Pointer(&staging[0])), uintptr(n),
		uintptr(unsafe.Pointer(&rows[0])), uintptr(max))
	if r < 0 {
		return nil, errnoErr(errOf(r))
	}
	if int(r) > len(rows) {
		return nil, EFAULT // the kernel wrote more rows than this buffer holds
	}
	return rows[:int(r)], nil
}

// splitParent returns the parent path and the leaf name. dir is "" when the
// path is a share-root child's parent (the share root itself).
func splitParent(path string) (dir, name string) {
	i := len(path) - 1
	for i >= 0 && path[i] != '/' {
		i--
	}
	if i < 0 {
		return "", path
	}
	return path[:i], path[i+1:]
}

func (d *Dirent) name() string {
	n := 0
	for n < len(d.Name) && d.Name[n] != 0 {
		n++
	}
	return string(d.Name[:n])
}

func (d *Dirent) dir() bool { return d.IsDir != 0 }

// statPath answers from a sys_dir_list row on the entry's PARENT. There is
// no stat-by-path slot, and a listing row carries exactly the two facts
// this kernel can report (size, directory bit), so Stat is a parent lookup
// rather than a fabrication. The share root is the one path with no parent.
//
// The parent route has a hard limit, and the port has to name it: the
// listing has NO cursor and the kernel clamps one call to 16 rows, so a
// parent with more than 16 entries cannot describe every child — the gate
// share has ~30, which is why the first std fixture to call Stat on
// /host/GOBIG.ELF read ENOENT for a file that was right there. The fallback
// below is the ABI's other half: ask the PATH itself whether it lists (that
// is a directory), and otherwise read the file to EOF and count. The row
// route is tried first because it is one syscall; the reading route costs
// O(size) and only ever runs where the row cannot exist.
func statPath(path string) (Stat_t, error) {
	var st Stat_t
	abs, err := resolvePath(path)
	if err != nil {
		return st, err
	}
	if abs == "/" || abs == "/host" {
		st.Mode = virModeDir
		return st, nil
	}
	dir, name := splitParent(abs)
	rows, lerr := listRows(dir, virDirRowsMax)
	if lerr != nil {
		return st, lerr
	}
	for i := range rows {
		if rows[i].name() == name {
			st.Size = int64(rows[i].Size)
			if rows[i].dir() {
				st.Mode = virModeDir
			} else {
				st.Mode = virModeFile
			}
			st.ModeSetBy = 1
			return st, nil
		}
	}
	if _, derr := listRows(abs, 1); derr == nil {
		// It lists, so it is a directory; this kernel reports no size for
		// one, and inventing a number would be worse than zero.
		st.Mode = virModeDir
		st.ModeSetBy = 1
		return st, nil
	}
	return statByReading(abs)
}

// statByReading derives a file's size the only other way this ABI allows:
// open it read-only, read to EOF, count the bytes. Used when the parent's
// first 16 rows do not contain the entry (see statPath). The handle is the
// kernel's own open — not Open(), which would probe for a directory and
// remember a handle the caller never sees — and it is closed before
// returning, whatever happens.
func statByReading(abs string) (Stat_t, error) {
	var st Stat_t
	var staging [virPathMax + 1]byte
	n := stagedPath(abs, &staging)
	if n < 0 {
		if len(abs) > virPathMax {
			return st, ENAMETOOLONG
		}
		return st, EINVAL
	}
	r := svc3(virSysFileOpen, uintptr(unsafe.Pointer(&staging[0])), uintptr(n), uintptr(kmodeRead))
	if r < 0 {
		return st, errnoErr(errOf(r))
	}
	fd := int(r)
	var buf [virIOChunkMax]byte
	var total int64
	for {
		k := svc3(virSysRead, uintptr(fd), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
		if k < 0 {
			_ = svc1(virSysClose, uintptr(fd))
			return st, errnoErr(errOf(k))
		}
		if k == 0 {
			break
		}
		total += k
	}
	_ = svc1(virSysClose, uintptr(fd))
	st.Size = total
	st.Mode = virModeFile
	st.ModeSetBy = 1
	return st, nil
}

func Stat(path string, st *Stat_t) error {
	if st == nil {
		return EFAULT
	}
	s, err := statPath(path)
	if err != nil {
		return err
	}
	*st = s
	return nil
}

// Lstat is Stat: the share has no symbolic links, so there is nothing to
// not follow.
func Lstat(path string, st *Stat_t) error { return Stat(path, st) }

// Fstat resolves a handle back to the path Open remembered for it (the
// kernel reports neither a handle's path nor its size) and stats that.
func Fstat(fd int, st *Stat_t) error {
	if st == nil {
		return EFAULT
	}
	if _, ok := dirFdFor(fd); ok {
		st.Mode = virModeDir
		st.ModeSetBy = 2
		return nil
	}
	p, ok := fdPath(fd)
	if !ok {
		return EBADF
	}
	s, err := statPath(p)
	if err != nil {
		return err
	}
	*st = s
	return nil
}

func Fstatat(dirfd int, path string, st *Stat_t, flags int) error {
	return Stat(path, st)
}

// UtimesNano is ENOSYS: no seam in this kernel takes a timestamp.
func UtimesNano(path string, ts []Timespec) error { return ENOSYS }
func Utimes(path string, tv []Timeval) error      { return ENOSYS }

// ----- directory reads -----------------------------------------------------

// ReadDirent packs up to len(buf)/40 kernel rows into buf, continuing from
// the port's own per-fd cursor. The kernel lists a path from the FIRST entry
// every time and clamps to 16 rows, so the cursor is the only thing that
// makes successive calls make progress at all.
//
// The ABI's missing offset is a real limit, not a detail: a directory with
// more than 16 entries cannot be enumerated, and the kernel gives no signal
// that it truncated. This port therefore REFUSES after a full window instead
// of returning a partial listing that looks complete — a caller that gets
// ENOSPC knows its view was incomplete, where a caller that gets EOF would
// quietly act on 16 of N entries. The cost of that choice: a directory with
// exactly 16 entries is indistinguishable from a truncated one and trips the
// same refusal. Closing that needs a listing cursor on slot 27 (a kernel
// change, filed against #1525).
func ReadDirent(fd int, buf []byte) (n int, err error) {
	i, ok := dirFdFor(fd)
	if !ok {
		return 0, EBADF
	}
	if len(buf) < direntSize {
		return 0, EINVAL
	}
	d := &virDirs[i]
	if d.sat {
		return 0, ENOSPC
	}
	rows, lerr := listRows(d.path, virDirRowsMax)
	if lerr != nil {
		return 0, lerr
	}
	if len(rows) == virDirRowsMax {
		d.sat = true // the window filled: more entries may exist, unknowably
	}
	if d.rows > len(rows) {
		d.rows = len(rows)
	}
	limit := len(buf) / direntSize
	written := 0
	for k := d.rows; k < len(rows) && written < limit; k++ {
		copy(buf[written*direntSize:], unsafe.Slice((*byte)(unsafe.Pointer(&rows[k])), direntSize))
		written++
	}
	d.rows += written
	return written * direntSize, nil
}

// ----- working directory ---------------------------------------------------
//
// There is no chdir slot: the guest's own shell keeps PWD as userland state
// and verifies each path with a directory listing (user/go/sh). This port
// does the same — a package-level cwd that every path-taking call resolves
// through — because "os.Getwd" being answerable is worth more than a
// refusal, and the resolution is the only part the kernel does not do.

// The initial cwd is the host share, which is where a guest program's files
// live (the monitor resolves a bare `exec NAME.ELF` from the same place).
var virCwd = "/host"

func Chdir(path string) error {
	abs, err := resolvePath(path)
	if err != nil {
		return err
	}
	if !isDir(abs) {
		return ENOENT
	}
	virCwd = abs
	return nil
}

func Getwd() (string, error) { return virCwd, nil }

func Getcwd(buf []byte) (n int, err error) {
	c := virCwd
	if len(buf) < len(c)+1 {
		return 0, ERANGE
	}
	copy(buf, c)
	buf[len(c)] = 0
	return len(c), nil
}

// stagedAbs resolves path against the port's cwd, stages the ABSOLUTE form
// in the caller's staging buffer, and returns its length (or -1). Every
// path-taking call goes through this: the kernel resolves nothing, so a
// relative path that reached it would be looked up at the share root and
// silently succeed against the wrong file. The buffer is a caller-local
// stack frame, not a shared global — two Ms staging concurrent calls must
// never splice each other's bytes (issue #2495).
func stagedAbs(path string, staging *[virPathMax + 1]byte) int {
	abs, err := resolvePath(path)
	if err != nil {
		return -1
	}
	return stagedPath(abs, staging)
}

// resolvePath makes path absolute against the port's cwd. ".." is resolved
// lexically, which is what the guest's own shell does and is the only thing
// available without a way to walk upward in the kernel.
func resolvePath(path string) (string, error) {
	if len(path) == 0 {
		return "", ENOENT
	}
	if path[0] != '/' {
		base := virCwd
		if base == "/" {
			path = "/" + path
		} else {
			path = base + "/" + path
		}
	}
	out := make([]byte, 0, len(path))
	for i := 0; i < len(path); i++ {
		if path[i] != '/' {
			out = append(out, path[i])
			continue
		}
		if len(out) == 0 || out[len(out)-1] != '/' {
			out = append(out, '/')
		}
	}
	if len(out) > 1 && out[len(out)-1] == '/' {
		out = out[:len(out)-1]
	}
	return string(out), nil
}
