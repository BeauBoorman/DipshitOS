// host.go — GOASSIST's injected platform seam (the goinfer pattern):
// everything below the interface is a syscall or a file; tests fake the
// lot. Compute sessions come through OpenComp so host tests substitute
// the kernel-emulating fake device (infer.NewFakeDev) — the same Dev the
// engine drives on the guest.
package main

import (
	"errors"
	"io"
	"strconv"

	"virelai/gpu3d"
	"virelai/infer"
	"virelai/settings"
	"virelai/vi"
)

type host interface {
	ConsoleLine(s string)
	// MkdirShare creates a share directory (EEXIST is not an error).
	MkdirShare(path string) error
	// WriteShareFile publishes bytes crash-safe (vi.WriteFileSafe).
	WriteShareFile(path string, b []byte) error
	// FileExists reports whether path opens for reading.
	FileExists(path string) bool
	// OpenRead opens path as a sequential reader — the guest file ABI
	// has no seek, and the VIW layout is built for exactly this.
	OpenRead(path string) (io.ReadCloser, error)
	// ReadFileAll loads a bounded whole file (conversation codec input).
	ReadFileAll(path string, max int) ([]byte, error)
	// ListDir names a directory's entries (non-recursive; "." order is
	// the store's own sort upstream).
	ListDir(dir string) ([]string, error)
	// OpenComp takes the compute session (slot 90); ENXIO maps to
	// gpu3d.ErrComputeNoDevice.
	OpenComp() (infer.Dev, error)
	// DataRoot resolves the movable-data root: "/disk" on a mounted
	// opt-in, else "/host" (fellBack marks the set-but-absent shape).
	DataRoot() (root string, fellBack bool)
	// Nanos is the monotonic clock.
	Nanos() int64
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

func (guestHost) ReadFileAll(path string, max int) ([]byte, error) {
	b, rc := vi.ReadFileAll(path, max)
	if rc < 0 {
		return nil, errors.New("read " + strconv.FormatInt(rc, 10))
	}
	return b, nil
}

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

// ListDir names the entries of a canonical guest dir: the paged slot-79
// snapshot for /host paths, the legacy 16-row window for /disk (the
// metadata ABI is host-share only; a full window is an ErrTreeLimit
// refusal, matching ListDirAt's contract).
func (guestHost) ListDir(dir string) ([]string, error) {
	if len(dir) > 5 && dir[:5] == "/host" {
		canon := dir[5:]
		if canon == "" {
			canon = "/"
		}
		items, err := vi.ListDirAt(canon)
		if err != nil {
			return nil, err
		}
		names := make([]string, 0, len(items))
		for _, it := range items {
			if !it.IsDir {
				names = append(names, it.Name)
			}
		}
		return names, nil
	}
	var entries [vi.MaxDirEntries]vi.DirEntry
	n, rc := vi.DirList(dir, entries[:])
	if rc < 0 {
		return nil, errors.New("dirlist " + strconv.FormatInt(rc, 10))
	}
	if n >= vi.MaxDirEntries {
		return nil, errors.New("directory exceeds the listing bound")
	}
	names := make([]string, 0, n)
	for i := 0; i < n; i++ {
		if entries[i].Dir() {
			continue
		}
		names = append(names, entries[i].NameString())
	}
	return names, nil
}

func (guestHost) OpenComp() (infer.Dev, error) { return gpu3d.OpenCompute() }

func (guestHost) DataRoot() (string, bool) { return settings.Load().ResolveDataRoot() }

func (guestHost) Nanos() int64 { return vi.Nanos() }
