//go:build !virelai

package main

import (
	"os"

	"virelai/fatimg"
)

// hostFS backs `go test` and dev runs: plain files, with WriteSafe a plain
// os.WriteFile — the crash-safe publish contract is a guest-path property
// the class-B gate exercises; the seam's shape is what tests pin.
type hostFS struct{}

func newUpFS() upFS { return hostFS{} }

func (hostFS) ReadFile(path string) ([]byte, error) { return os.ReadFile(path) }

func (hostFS) WriteSafe(path string, b []byte) error { return os.WriteFile(path, b, 0o644) }

func (hostFS) Mkdir(path string) error { return os.MkdirAll(path, 0o755) }

func (hostFS) NewImageSink(path string) (fatimg.SeqSink, error) {
	return fatimg.NewSeqSink(path)
}
