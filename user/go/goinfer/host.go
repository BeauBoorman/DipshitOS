package main

// The injected platform seam (the gputriangle pattern): everything below
// this interface is a syscall or a file; tests fake the lot. Compute
// sessions come through OpenComp so host tests can substitute the
// kernel-emulating fake device without touching gpu3d.

import (
	"errors"
	"io"
	"strconv"

	"virelai/gpu3d"
	"virelai/infer"
	"virelai/vi"
)

type host interface {
	ConsoleLine(s string)
	// MkdirShare creates a /host directory (EEXIST is not an error).
	MkdirShare(path string) error
	// WriteShareFile publishes bytes through the ordinary file seam.
	WriteShareFile(path string, b []byte) error
	// FileExists reports whether path opens for reading.
	FileExists(path string) bool
	// OpenRead opens path as a sequential reader — the guest file ABI
	// has no seek, and the VIW layout is built for exactly this.
	OpenRead(path string) (io.ReadCloser, error)
	// OpenComp takes the compute session (slot 90); ENXIO maps to
	// gpu3d.ErrComputeNoDevice, which journeys answer "unsupported".
	OpenComp() (infer.Dev, error)
	// Nanos is the monotonic clock for tok/s evidence.
	Nanos() int64
	// SelfMemBytes is this process's owned resident footprint (the proc
	// table's v2 MemBytes); 0 when the row cannot be found.
	SelfMemBytes() uint64
}

// --- guest platform -----------------------------------------------------------

type guestHost struct{}

func (guestHost) ConsoleLine(s string) { vi.ConsoleLine(s) }

func (guestHost) MkdirShare(path string) error {
	h, rc := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if rc == 0 {
		vi.FileClose(uint32(h))
		return nil
	}
	if rc == -9 { // EEXIST
		return nil
	}
	return errors.New("mkdir " + strconv.FormatInt(rc, 10))
}

func (guestHost) WriteShareFile(path string, b []byte) error {
	if rc := vi.WriteFileSafe(path, b); rc < 0 {
		return errors.New("publish " + strconv.FormatInt(rc, 10))
	}
	return nil
}

func (guestHost) FileExists(path string) bool { return vi.FileExists(path) }

// guestFile adapts a vi file handle to io.ReadCloser (sequential reads).
type guestFile struct{ h uint32 }

func (f *guestFile) Read(b []byte) (int, error) {
	n, rc := vi.FileRead(f.h, b)
	if rc < 0 {
		return 0, errors.New("read " + strconv.FormatInt(rc, 10))
	}
	if n == 0 {
		return 0, io.EOF
	}
	return n, nil
}

func (f *guestFile) Close() error { vi.FileClose(f.h); return nil }

func (guestHost) OpenRead(path string) (io.ReadCloser, error) {
	h, rc := vi.FileOpen(path, vi.ModeRead)
	if rc < 0 {
		return nil, errors.New("open " + strconv.FormatInt(rc, 10))
	}
	return &guestFile{h: uint32(h)}, nil
}

func (guestHost) OpenComp() (infer.Dev, error) { return gpu3d.OpenCompute() }

func (guestHost) Nanos() int64 { return vi.Nanos() }

// SelfMemBytes finds this process in the v2 proc table by name — there is
// no self-pid syscall, so the scan is the seam's own convention (an
// ambiguous name reports 0 rather than guessing, same as lease.go).
func (guestHost) SelfMemBytes() uint64 {
	var rows [64]vi.ProcRow
	n, rc := vi.ProcsV2(rows[:])
	if rc < 0 || n <= 0 {
		return 0
	}
	found := false
	var mem uint64
	for i := 0; i < n; i++ {
		if rows[i].State != vi.ProcRunning || rows[i].Name() != appName {
			continue
		}
		if found {
			return 0
		}
		found, mem = true, rows[i].MemBytes
	}
	return mem
}
