// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

// The GOOS=virelai `syscall` layer (issue #1525, M70c-S1P).
//
// VirelaiOS is not POSIX and this port does not pretend otherwise. What it
// does provide is the *shape* `os` and `internal/poll` expect — an Errno,
// the file calls, a dirent record, seek-less handles — mapped onto the ADR
// 0007 slots a guest already has (kernel/src/syscall.zig, the file domain
// slots 23-27/34-36/77 plus 63/66/72 for mmap/time/entropy), reached
// through one generic `svc #0` entry (syscall_virelai_arm64.s).
//
// Three facts about the kernel shape drive everything below.
//
//  1. **The kernel's errno space is its own**, not Linux's: -1..-12, an
//     enum in kernel/src/syscall.zig. The file domain additionally reuses
//     two of those slots for host-file-channel statuses (an existing file is
//     the -9 slot, a directory written as a file is the -1 slot), which the
//     guest SDK already documents. This file names both senses and says
//     which is which; the POSIX names that share a number are aliases, not
//     lies about what the kernel returns.
//  2. **There is no whole-file or by-offset call**: handles carry a cursor
//     (file_table.read/write advance it), so this is a sequential port.
//     Seek reports ENOSYS rather than faking a seek the kernel will not do.
//  3. **Directories are listed by PATH, not by handle** (sys_dir_list takes
//     path, path_len, row buffer, row count), so `Open` on a directory
//     returns a synthetic fd — see dirFixtureFd — and ReadDirent resolves it
//     back to the path. Without that, `os.Open(dir)` plus ReadDir cannot
//     exist at all.
//
// Paths are staged in a package-level array before every call. That is not
// a style choice: the kernel validates the SOURCE of a copy_in against the
// caller's registered regions (kernel/src/uaccess.zig), and every existing
// guest stages paths for exactly this reason (user/go/vi, user/go/vsys).
// Read and write BUFFERS go straight through — the stack and the sbrk heap
// are registered regions and every guest fixture already passes heap
// slices.
package syscall

import (
	"internal/oserror"
	"internal/strconv"
	"unsafe"
)

// ADR 0007 slots this port uses (kernel/src/syscall.zig).
const (
	virSysExit         = 3
	virSysConsoleWrite = 1
	virSysFileOpen     = 23
	virSysRead         = 24
	virSysWrite        = 25
	virSysClose        = 26
	virSysDirList      = 27
	virSysDelete       = 34
	virSysRename       = 35
	virSysTruncate     = 36
	virSysMmap         = 63
	virSysTime         = 66
	virSysFileMode     = 69
	virSysRandom       = 72
	virSysThread       = 73
	virSysFutex        = 74
	virSysExNotify     = 75
	virSysFileSync     = 77
)

// Open flags, in their POSIX (linux/arm64) numbering, because that is the
// contract every std caller already speaks: `os.O_*` are aliases of these
// and `internal/poll` ORs O_CLOEXEC in. The kernel's own bits are different
// (file_table.zig MODE_*), so Open translates below — a port that published
// the kernel's numbering here would make `os.OpenFile` pass 0 for a
// read-only open and the kernel answer EINVAL.
// Untyped on purpose: `os` passes these through as its own `int` flags
// (OpenFile does flag|O_CLOEXEC), while Open's kernel word is uint32.
const (
	O_RDONLY    = 0x0
	O_WRONLY    = 0x1
	O_RDWR      = 0x2
	O_CREAT     = 0x40
	O_EXCL      = 0x80
	O_NOCTTY    = 0x100
	O_TRUNC     = 0x200
	O_APPEND    = 0x400
	O_NONBLOCK  = 0x800
	O_DIRECTORY = 0x10000
	O_NOFOLLOW  = 0x20000
	O_CLOEXEC   = 0x80000
	// Aliases: the names the guest SDK and older callers spell.
	O_CREATE = O_CREAT
	O_DIR    = O_DIRECTORY
	O_SYNC   = 0x101000
)

// fcntl(2) command numbers. Only F_GETFL is answerable here (see
// internal/syscall/unix's Fcntl); the rest exist so std files that merely
// name them compile.
const (
	F_DUPFD         = 0x0
	F_GETFD         = 0x1
	F_SETFD         = 0x2
	F_GETFL         = 0x3
	F_SETFL         = 0x4
	F_DUPFD_CLOEXEC = 0x406
	F_SETPIPE_SZ    = 0x407
	F_FULLFSYNC     = 0x33 // darwin-only number; named by internal/poll there
)

// S_IFMT and friends, as POSIX numbers. This kernel's directory rows carry
// the same shape (mode 040000|0755 for a directory, 0100000|0644 for a
// file), which is what makes os's fileInfo mapping a straight copy.
const (
	S_IFMT     = 0o170000
	S_IFSOCK   = 0o140000
	S_IFLNK    = 0o120000
	S_IFREG    = 0o100000
	S_IFBLK    = 0o060000
	S_IFDIR    = 0o040000
	S_IFCHR    = 0o020000
	S_IFIFO    = 0o010000
	S_ISUID    = 0o4000
	S_ISGID    = 0o2000
	S_ISVTX    = 0o1000
	DT_UNKNOWN = 0
	DT_FIFO    = 1
	DT_CHR     = 2
	DT_DIR     = 4
	DT_BLK     = 6
	DT_REG     = 8
	DT_LNK     = 10
	DT_SOCK    = 12
	SEEK_SET   = 0
	SEEK_CUR   = 1
	SEEK_END   = 2
)

const (
	virPathMax         = 255 // file_table.max_path_len
	virDirRowBytes     = 40  // the sys_dir_list row (file_table.DirEntry)
	virDirRowsMax      = 16  // handle_dir_list clamps the caller's row count
	virIOChunkMax      = 2048
	virConsoleWriteMax = 256 // syscall.zig write_cap
)

// An Errno is the kernel's negative error code as a positive number.
type Errno uintptr

// The kernel's ErrorCode enum (kernel/src/syscall.zig), with the file
// domain's two aliases spelled out. Aliasing is a property of the kernel,
// not an accident here: EISDIR and EEXIST share numbers with EINVAL and
// ENXIO because the host-file-channel statuses are reported in the same
// space. `Is` below therefore maps oserror's sentinels onto the file-domain
// sense of each number, which is what an `os` caller is asking about.
const (
	EINVAL       Errno = 1  // kernel einval
	EBADF        Errno = 2  // kernel ebadf
	EFAULT       Errno = 3  // kernel efault
	ENOSYS       Errno = 4  // kernel enosys
	ENOSPC       Errno = 5  // kernel enospc; the file domain also uses it for a full handle table
	ENOENT       Errno = 6  // kernel enoent
	EACCES       Errno = 7  // kernel eacces (the M50 ownership gate's refusal)
	ENAMETOOLONG Errno = 8  // kernel enametoolong
	ENXIO        Errno = 9  // kernel enxio
	EEXIST       Errno = 9  // file domain: the host refuses a live target (HF status 5)
	ENOMEM       Errno = 10 // kernel enomem
	EAGAIN       Errno = 11 // kernel eagain
	ETIMEDOUT    Errno = 12 // kernel etimedout

	EISDIR Errno = 1 // file domain: the path is a directory (HF status 2)

	// Defined because os, path/filepath and internal/poll compare against
	// them; this kernel has no seam that produces them (no permissions
	// model beyond the M50 ownership gate, no symlinks, no pipe ENOTEMPTY).
	EPERM     Errno = 13
	ENOTEMPTY Errno = 14
	EINTR     Errno = 15
	EIO       Errno = 16
	EPIPE     Errno = 17
	EROFS     Errno = 18
	ELOOP     Errno = 19
	ENOTDIR   Errno = 20
	ESPIPE    Errno = 21
	ERANGE    Errno = 22
	ENFILE    Errno = 23
	EMFILE    Errno = 24
	EXDEV     Errno = 25

	// EMLINK is named by os/eloop_other.go's ELOOP classification (some
	// kernels report EMLINK for a refused O_NOFOLLOW open). This kernel
	// reports ELOOP, so the comparison is present and never true.
	EMLINK Errno = 41
)

// errorstr names the codes this kernel can actually return. Index = the
// numeric value; "" means "this port has no message", and Error falls back
// to the number so a wrong code is visible rather than plausible.
var errorstr = [...]string{
	0:  "no error",
	1:  "invalid argument", // EINVAL / file domain EISDIR
	2:  "bad file descriptor",
	3:  "bad address",
	4:  "function not implemented",
	5:  "no space left",
	6:  "no such file or directory",
	7:  "permission denied",
	8:  "file name too long",
	9:  "no such device", // ENXIO / file domain EEXIST
	10: "out of memory",
	11: "resource temporarily unavailable",
	12: "timed out",
	13: "operation not permitted",
	14: "directory not empty",
	15: "interrupted",
	16: "i/o error",
	17: "broken pipe",
	18: "read-only file system",
	19: "too many levels of symbolic links",
	20: "not a directory",
	21: "illegal seek",
	22: "numerical result out of range",
	23: "too many open files",
	24: "too many open files in the system",
	25: "cross-device link",
}

func (e Errno) Error() string {
	if 0 <= int(e) && int(e) < len(errorstr) {
		if s := errorstr[e]; s != "" {
			return s
		}
	}
	return "errno " + strconv.Itoa(int(e))
}

func (e Errno) Is(target error) bool {
	switch target {
	case oserror.ErrPermission:
		return e == EACCES || e == EPERM
	case oserror.ErrExist:
		return e == EEXIST || e == ENOTEMPTY
	case oserror.ErrNotExist:
		return e == ENOENT
	}
	return false
}

func (e Errno) Temporary() bool { return e == EAGAIN || e == EINTR }
func (e Errno) Timeout() bool   { return e == ETIMEDOUT }

// errnoErr returns nil for the zero Errno, so a success path never carries a
// non-nil error interface holding 0 (the classic `err == nil` trap).
func errnoErr(e Errno) error {
	if e == 0 {
		return nil
	}
	return e
}

// ----- the svc entry -------------------------------------------------------

// virginSvc is the trampoline (syscall_virelai_arm64.s).
//
//go:noescape
func virginSvc(n, a1, a2, a3, a4, a5 uintptr) (r0, r1 int64)

// svcN issues one ADR 0007 call and returns the raw result (negative = the
// kernel's errno).
func svc6(n, a1, a2, a3, a4, a5 uintptr) int64 {
	r, _ := virginSvc(n, a1, a2, a3, a4, a5)
	return r
}
func svc0(n uintptr) int64                 { return svc6(n, 0, 0, 0, 0, 0) }
func svc1(n, a1 uintptr) int64             { return svc6(n, a1, 0, 0, 0, 0) }
func svc2(n, a1, a2 uintptr) int64         { return svc6(n, a1, a2, 0, 0, 0) }
func svc3(n, a1, a2, a3 uintptr) int64     { return svc6(n, a1, a2, a3, 0, 0) }
func svc4(n, a1, a2, a3, a4 uintptr) int64 { return svc6(n, a1, a2, a3, a4, 0) }
func errOf(r int64) Errno {
	if r < 0 {
		return Errno(-r)
	}
	return 0
}

// ----- path staging --------------------------------------------------------

// stagedPath copies path into staging and returns its length, or -1 for a
// path that cannot be passed: empty, longer than the kernel's bound, or
// containing a NUL (which would truncate on the wire). The buffer is the
// CALLER's — a stack local at every call site — because issue #2495 proved
// the alternative: the old package-global virPathStaging let two Ms
// interleave a copy and an svc3 (cmd/compile's noder opens every source
// file on its own goroutine under GOMAXPROCS=2), and the kernel then
// validated a spliced path — opens returned ENOENT/EINVAL for names the
// share held, or the WRONG existing file's bytes under the right name.
func stagedPath(path string, staging *[virPathMax + 1]byte) int {
	if len(path) == 0 || len(path) > virPathMax {
		return -1
	}
	for i := 0; i < len(path); i++ {
		if path[i] == 0 {
			return -1
		}
		staging[i] = path[i]
	}
	staging[len(path)] = 0
	return len(path)
}

// ----- types ---------------------------------------------------------------

// Signal exists so `os` and the runtime's signal plumbing compile; this
// kernel delivers faults synchronously (slot 75, ADR 0007 amendment) and has
// no asynchronous signal delivery, so no Signal value is ever produced.
type Signal int

func (s Signal) Signal() {}

func (s Signal) String() string {
	if 1 <= s && int(s) <= len(signals) {
		if str := signals[s-1]; str != "" {
			return str
		}
	}
	return "signal " + strconv.Itoa(int(s))
}

var signals = [...]string{
	"hangup", "interrupt", "quit", "illegal instruction", "trace/breakpoint trap",
	"aborted", "bus error", "floating point exception", "killed", "user defined signal 1",
	"segmentation fault", "user defined signal 2", "broken pipe", "alarm clock", "terminated",
}

// WaitStatus is the POSIX shape. Nothing in this kernel is a waitable
// process status at EL0 (sys_wait reports the registry's own rows), so the
// methods are the wasip1-shaped honest defaults rather than invented ones.
type WaitStatus uint32

func (w WaitStatus) Exited() bool       { return false }
func (w WaitStatus) ExitStatus() int    { return 0 }
func (w WaitStatus) Signaled() bool     { return false }
func (w WaitStatus) Signal() Signal     { return 0 }
func (w WaitStatus) CoreDump() bool     { return false }
func (w WaitStatus) Stopped() bool      { return false }
func (w WaitStatus) Continued() bool    { return false }
func (w WaitStatus) StopSignal() Signal { return 0 }
func (w WaitStatus) TrapCause() int     { return 0 }

// Timespec / Timeval carry the kernel's own time (slot 66 = unix seconds
// from the firmware epoch; CNTPCT_EL0 gives sub-second resolution to EL0).

type Timespec struct {
	Sec  int64
	Nsec int64
}

type Timeval struct {
	Sec  int64
	Usec int64
}

// setTimespec / setTimeval are the GOOS constructors syscall/timestruct.go
// uses; the arm64 shape is the direct one.
func setTimespec(sec, nsec int64) Timespec { return Timespec{Sec: sec, Nsec: nsec} }
func setTimeval(sec, usec int64) Timeval   { return Timeval{Sec: sec, Usec: usec} }

type Rusage struct {
	Utime Timeval
	Stime Timeval
}

// Utsname is the POSIX uname shape; the kernel has no uname seam, so any
// caller gets the zero value rather than a fabricated string.
type Utsname struct {
	Sysname    [65]byte
	Nodename   [65]byte
	Release    [65]byte
	Version    [65]byte
	Machine    [65]byte
	Domainname [65]byte
}

// Stat_t is what this kernel can honestly report at EL0: a size and a
// directory bit, both from a sys_dir_list row on the entry's PARENT (there
// is no stat-by-path slot, and sys_file_mode is a setter for the M50
// ownership table, not a query). Everything a POSIX stat carries and this
// kernel does not — mtime, owner, inode, blocks — is the zero value, so
// `os.Stat(...).ModTime()` returns the zero Time rather than a plausible
// lie. Mode is synthesized from the directory bit: 0755 for a directory,
// 0644 for a file, neither of which the kernel consults.
type Stat_t struct {
	Dev       uint64
	Ino       uint64
	Nlink     uint64
	Size      int64
	Mode      uint32
	Uid       uint32
	Gid       uint32
	Rdev      uint64
	Blksize   int64
	Blocks    int64
	Atim      Timespec
	Mtim      Timespec
	Ctim      Timespec
	ModeSetBy uint32 // 0: unknown, 1: synthesized from a dir row, 2: a directory handle
}

const (
	virModeDir  = 0o040000 | 0o755
	virModeFile = 0o100000 | 0o644
)

// ----- identity ------------------------------------------------------------
//
// There is no getpid slot: a process learns its own pid from the kernel's
// process registry (sys_procs) or from argv. os.Getpid exists for callers
// that want a unique tag, and the honest answer here is the task id the
// kernel reports for the CALLER through slot 7 — which this layer does not
// parse. Until it does, these return the PD (principal) identity the kernel
// actually assigns: uid_user, gid 1000 (ADR 0024 D1), and pid 0 means
// "this process did not ask".

func Getpid() int  { return 0 }
func Getppid() int { return 0 }
func Getuid() int  { return 1000 } // uid_user (ADR 0024 D1)
func Geteuid() int { return 1000 }
func Getgid() int  { return 1000 }
func Getegid() int { return 1000 }
func Umask(mask int) int {
	return 0 // no mode model at EL0; a caller's mask changes nothing
}
func Getgroups() ([]int, error) { return []int{1000}, nil }

// Rlimit is required by os/exec's shape; nothing enforces limits at EL0 and
// the fields are the POSIX struct so a caller reading them gets zeros.
type Rlimit struct {
	Cur uint64
	Max uint64
}

const (
	RLIMIT_AS         = 0
	RLIMIT_CORE       = 1
	RLIMIT_CPU        = 2
	RLIMIT_DATA       = 3
	RLIMIT_FSIZE      = 4
	RLIMIT_NOFILE     = 5
	RLIMIT_STACK      = 6
	RLIMIT_NPROC      = 7
	RLIMIT_RSS        = 8
	RLIMIT_MEMLOCK    = 9
	RLIMIT_LOCKS      = 10
	RLIMIT_SIGPENDING = 11
	RLIMIT_MSGQUEUE   = 12
	RLIMIT_NICE       = 13
	RLIMIT_RTPRIO     = 14
	RLIMIT_RTTIME     = 15
	RLIM_INFINITY     = ^uint64(0)
)

func Getrlimit(which int, lim *Rlimit) error { return ENOSYS }
func Setrlimit(which int, lim *Rlimit) error { return ENOSYS }

// ----- exit ----------------------------------------------------------------

// ProcExit terminates the process through slot 3 (ADR 0007). It does not
// return.
func ProcExit(code int32) {
	svc1(virSysExit, uintptr(code))
	for {
		svc0(2) // sys_yield, if the kernel were ever to return here
	}
}

// ----- time ----------------------------------------------------------------

// Time returns unix seconds from the kernel's firmware epoch (slot 66).
func Time(t *int64) int64 {
	r := svc0(virSysTime)
	if t != nil {
		*t = r
	}
	return r
}

// Gettimeofday fills tv with the kernel's second-resolution clock. The
// sub-second field stays zero: the guest can read CNTPCT_EL0 for its own
// monotonic base, but that is not the wall clock and mixing them would make
// timestamps look precise when they are not.
func Gettimeofday(tv *Timeval) error {
	if tv == nil {
		return EFAULT
	}
	tv.Sec = svc0(virSysTime)
	tv.Usec = 0
	return nil
}

// ----- entropy -------------------------------------------------------------

// RandomGet fills b from the kernel CSPRNG (slot 72), which clamps each call
// to 256 bytes; the loop is the honest way to fill a larger buffer.
func RandomGet(b []byte) error {
	_, err := Getrandom(b)
	return err
}

func Getrandom(b []byte) (int, error) {
	if len(b) == 0 {
		return 0, nil
	}
	off := 0
	for off < len(b) {
		chunk := len(b) - off
		if chunk > 256 {
			chunk = 256
		}
		r := svc2(virSysRandom, uintptr(unsafe.Pointer(&b[off])), uintptr(chunk))
		if r < 0 {
			if off > 0 {
				return off, errnoErr(errOf(r))
			}
			return 0, errnoErr(errOf(r))
		}
		if r == 0 {
			break
		}
		off += int(r)
	}
	return off, nil
}
