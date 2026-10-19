package shlib

import "virelai/linebuf"

// LineBuffer is the pure, bounded single-line editing core shared by the
// tty editor and GUI text fields. The implementation moved to the leaf
// package virelai/linebuf (M124b #2581): appkit's TextField links it
// directly, so GUI binaries no longer carry the whole shell for a line
// buffer. This alias keeps the shlib.LineBuffer spelling source-stable.
type LineBuffer = linebuf.LineBuffer

// NewLineBuffer returns an empty buffer bounded to max bytes. A non-positive
// max is unbounded, which is useful for small pure callers and tests.
func NewLineBuffer(max int) LineBuffer { return linebuf.NewLineBuffer(max) }
