//go:build virelai

package fatimg

import (
	"fmt"

	"virelai/vi"
)

// viSink is the guest SeqSink. The image is written to the sacrificial
// <path>~ temp and PUBLISHED on Close (fsync, close, delete+rename) — the
// M81e/M66b contract the vi publish guard enforces: a crash mid-write
// leaves a partial temp, never a torn RELEASE.IMG a later boot would
// attach. The publish is the rename; until it happens the live path is
// either absent or the previous release.
//
// Writes stream through the open handle in FileWriteAll's 2048-byte chunks
// (the file channel's per-call cap) — the os.File route cannot be used: its
// write path stages everything in the 16 MiB virShadow and refuses past it,
// and the image is ~34 MiB.
//
// ZeroPad streams real zero writes. The tempting alternative — a
// truncate-extend so the host zero-fills — would call vi.FileTruncate on a
// path the guard correctly reads as a live-file hazard, and the kernel's
// only truncate is handle-addressed with no way to prove the handle's path
// is the sacrificial temp. Streaming the ~30 MiB of zero regions is the
// honest cost; it is a few minutes inside a fleet-scale run, not a design
// compromise.
type viSink struct {
	tmp   string
	final string
	h     uint32
	pos   uint64
}

func NewSeqSink(path string) (SeqSink, error) {
	// The temp is the sacrificial <path>~ sibling the publish guard
	// recognises: it may be truncated/rewritten freely, and a crash leaves
	// it orphaned, never torn at the live path (vi.WriteFileSafe's rule).
	// A stale temp from an earlier attempt is simply replaced.
	tmp := path + "~"
	_ = vi.FileDelete(tmp)
	h, rc := vi.FileOpen(path+"~", vi.ModeWrite|vi.ModeCreate)
	if rc < 0 {
		return nil, fmt.Errorf("open %s rc=%d", tmp, rc)
	}
	return &viSink{tmp: tmp, final: path, h: uint32(h)}, nil
}

func (s *viSink) Write(b []byte) (int, error) {
	n, rc := vi.FileWriteAll(s.h, b)
	s.pos += uint64(n)
	if rc < 0 {
		return n, fmt.Errorf("write %s rc=%d", s.tmp, rc)
	}
	return n, nil
}

func (s *viSink) ZeroPad(to uint64) error {
	if to < s.pos {
		return fmt.Errorf("zeropad %s: target %d behind position %d", s.tmp, to, s.pos)
	}
	var zero [4096]byte
	for s.pos < to {
		n := to - s.pos
		if n > uint64(len(zero)) {
			n = uint64(len(zero))
		}
		if _, err := s.Write(zero[:n]); err != nil {
			return err
		}
	}
	return nil
}

func (s *viSink) Close() error {
	// fsync BEFORE close so the published bytes are durable on the host,
	// then delete+rename — the host's rename refuses a live target, so the
	// publish deletes first (from there the honest failure mode is ABSENT,
	// never garbage — vi.WriteFileSafe's sequence verbatim).
	if rc := vi.FileSync(s.h); rc < 0 {
		vi.FileClose(s.h)
		_ = vi.FileDelete(s.tmp)
		return fmt.Errorf("fsync %s rc=%d", s.tmp, rc)
	}
	vi.FileClose(s.h)
	if rc := vi.FileDelete(s.final); rc < 0 && rc != vi.ErrFileNotFound {
		_ = vi.FileDelete(s.tmp)
		return fmt.Errorf("publish %s: delete rc=%d", s.final, rc)
	}
	if rc := vi.FileRename(s.tmp, s.final); rc < 0 {
		_ = vi.FileDelete(s.tmp)
		return fmt.Errorf("publish %s: rename rc=%d", s.final, rc)
	}
	return nil
}
