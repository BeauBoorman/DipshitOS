//go:build virelai

package main

import (
	"fmt"
	"os"

	"virelai/fatimg"
	"virelai/vi"
)

// guestFS is the virelai upFS: vi's file slots over the host file
// channel. Writes publish through WriteFileSafe (M66b) and image streams
// through the fatimg vi sink; reads ride the os overlay, which is
// unbounded for reads (only its write shadow is capped at 16 MiB).
type guestFS struct{}

func newUpFS() upFS { return guestFS{} }

func (guestFS) ReadFile(path string) ([]byte, error) { return os.ReadFile(path) }

func (guestFS) WriteSafe(path string, b []byte) error {
	if rc := vi.WriteFileSafe(path, b); rc < 0 {
		return fmt.Errorf("WriteFileSafe %s rc=%d", path, rc)
	}
	return nil
}

func (guestFS) Mkdir(path string) error {
	h, rc := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if rc == vi.ErrFileExists {
		return nil
	}
	if rc < 0 {
		return fmt.Errorf("mkdir %s rc=%d", path, rc)
	}
	vi.FileClose(uint32(h))
	return nil
}

func (guestFS) NewImageSink(path string) (fatimg.SeqSink, error) {
	return fatimg.NewSeqSink(path)
}
