package vsys

// MaxFileIOBytes is the kernel's per-call file transfer bound —
// syscall.file_io_max, the file channel's 32 KiB reply cap
// (kernel/src/syscall.zig; user/go/vi chunks independently).
const MaxFileIOBytes = 32768

// File is an os.File-shaped handle over the file channel (slots 23-27). The
// kernel owns the handle table (8 per process); File carries the handle and
// the local open/closed state so misuse fails without a syscall.
type File struct {
	h    int64
	open bool
	path string
}

// ValidatePath applies the kernel's own path rules before any syscall, so a
// caller gets a precise local error instead of a bare EINVAL: empty paths and
// dot-traversal (".." components) are invalid, and the kernel's
// max_path_len (64 bytes) is the hard ceiling.
func ValidatePath(path string) error {
	if path == "" {
		return ErrInvalidPath
	}
	if len(path) > MaxPathLen {
		return ErrNameTooLong
	}
	// Reject a ".." COMPONENT, not the substring: "a..b" is a legal name.
	for i := 0; i <= len(path)-2; i++ {
		if path[i] == '.' && path[i+1] == '.' {
			before := i == 0 || path[i-1] == '/'
			after := i+2 == len(path) || path[i+2] == '/'
			if before && after {
				return ErrInvalidPath
			}
		}
	}
	return nil
}

// Open opens path with the given mode flags (vsys.ModeRead etc.). flags == 0
// is refused by the kernel, so ReadFile passes ModeRead explicitly. A handle
// returned by the kernel is >= 0.
func Open(path string, flags uint32) (*File, error) {
	if err := ValidatePath(path); err != nil {
		return nil, err
	}
	// The path is staged in a per-call stack buffer: the kernel's copy_in
	// validates the SOURCE against the caller's registered uaccess
	// regions, and the user stack is one (kernel/src/uaccess.zig — read
	// regions are user text, user stack, and the dynamic segments), while
	// a freshly allocated slice lives in the sbrk heap (unregistered), so
	// passing heap memory here fails. A stack local is ALSO the fix for
	// issue #2519: the old package-global virPathStaging let two Ms
	// interleave the stage-copy and the svc — the same splice #2518 fixed
	// in the cmd/compile overlay (cmd/compile's noder opens every source
	// file on its own goroutine), where a spliced path opened the wrong
	// file or ENOENT'd a name the share held.
	// (No second length check: ValidatePath above already enforces
	// MaxPathLen.)
	var staging [MaxPathLen]byte
	copy(staging[:], path)
	r, err := syscallResult(syscallFn(SlotFileOpen, strPtr(staging[:len(path)]), uintptr(len(path)), uintptr(flags), 0))
	if err != nil {
		return nil, err
	}
	return &File{h: r, open: true, path: path}, nil
}

// Read fills p with up to one kernel read (a single call moves at most
// MaxFileIOBytes). A zero return with a nil error is "no more bytes right now" —
// the kernel's read is level-triggered, not blocking.
func (f *File) Read(p []byte) (int, error) {
	if !f.open {
		return 0, Errno(ErrEBADF)
	}
	if len(p) == 0 {
		return 0, nil
	}
	// Symmetric with Write: one kernel call moves at most MaxFileIOBytes.
	// Reading fewer bytes is not an error (only writing can lose data), so
	// the buffer is clamped rather than refused.
	if len(p) > MaxFileIOBytes {
		p = p[:MaxFileIOBytes]
	}
	r, err := syscallResult(syscallFn(SlotFileRead, uintptr(f.h), slicePtr(p), uintptr(len(p)), 0))
	if err != nil {
		return 0, err
	}
	return int(r), nil
}

// Write writes p through one syscall (at most MaxFileIOBytes per call by
// kernel law; a longer buffer is refused so data cannot be silently lost).
func (f *File) Write(p []byte) (int, error) {
	if !f.open {
		return 0, Errno(ErrEBADF)
	}
	if len(p) == 0 {
		return 0, nil
	}
	if len(p) > MaxFileIOBytes {
		return 0, Errno(ErrENOSPC)
	}
	r, err := syscallResult(syscallFn(SlotFileWrite, uintptr(f.h), slicePtr(p), uintptr(len(p)), 0))
	if err != nil {
		return 0, err
	}
	return int(r), nil
}

// Close releases the kernel handle. Closing twice is a local no-op.
func (f *File) Close() error {
	if !f.open {
		return nil
	}
	f.open = false
	_, err := syscallResult(syscallFn(SlotFileClose, uintptr(f.h), 0, 0, 0))
	return err
}

// ReadFileMax is the ceiling ReadFile will accumulate.
const ReadFileMax = 64 * 1024

// ReadFile reads path to completion, accumulating chunked reads until the
// kernel reports 0. ReadFileMax bounds the result so a wrong path cannot
// grow the heap without limit.
func ReadFile(path string) ([]byte, error) {
	f, err := Open(path, ModeRead)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := make([]byte, 0, 512)
	chunk := make([]byte, 1024)
	for {
		n, err := f.Read(chunk)
		if err != nil {
			return out, err
		}
		if n == 0 {
			return out, nil
		}
		if len(out)+n >= ReadFileMax {
			return append(out, chunk[:n]...), nil
		}
		out = append(out, chunk[:n]...)
	}
}
