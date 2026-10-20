package main

// format.go — M138b (#2776): format-on-save for .go buffers, and the
// card's probe result recorded in the code it shaped.
//
// The probe (2026-10-20, this worktree): go/format LINKS cleanly under
// GOOS=virelai, but GOEDIT with it linked measures 2,556,064 bytes —
// 458,912 over kernel/src/exec.zig's exec_program_max (2,097,152). The
// kernel loader refuses an image that size, so "guest-safe" fails on
// size, not on linking. The go/format import therefore lives behind the
// opt-in `editfmt` build tag (format_gofmt.go): the shipped binary is
// the format_nofmt.go side, formatSource stays nil, and every .go save
// prints the named refusal. `-tags editfmt` rebuilds the real seam for
// whoever next raises the cap or shrinks the import closure.
//
// A format error never blocks the publish either: the buffer is left
// alone, the error strip shows the diagnostic by name, and the save
// writes the unformatted bytes.

import (
	"bytes"
	"strings"

	"virelai/vi"
)

// formatUnavailable is the card's named refusal, printed verbatim on a
// .go save when the binary was built without go/format — which is every
// shipped build until the image fits exec_program_max again.
const formatUnavailable = "edit: format unavailable (go/format not guest-safe)"

// isGoPath reports whether p names a Go source file. The suffix check is
// case-insensitive — the share carries both cases.
func isGoPath(p string) bool {
	return strings.HasSuffix(strings.ToLower(p), ".go")
}

// formatGo formats the buffer in place when the path names a .go file; it
// is save()'s first step, so a lease refusal still leaves the buffer
// formatted. An applied format is ONE composite undoable op covering the
// whole buffer — Ctrl-Z restores the pre-format bytes. The receipts:
// `format n=` on apply (the formatted length, also the already-clean
// no-op's receipt), `format error <diag>` when the parser refused, and the
// card's named refusal when the build carries no formatter.
func (e *editor) formatGo() {
	if !isGoPath(e.path) {
		return
	}
	if formatSource == nil {
		vi.ConsoleLine(formatUnavailable)
		return
	}
	out, err := formatSource(e.buf)
	if err != nil {
		vi.ConsoleLine(markerFormat + "error " + err.Error())
		e.raiseBanner("format " + e.path + " failed: " + err.Error())
		return
	}
	vi.ConsoleLine(markerFormat + "n=" + vi.Itoa64(int64(len(out))))
	if bytes.Equal(out, e.buf) {
		return
	}
	old := append([]byte{}, e.buf...)
	cur := e.cur
	if cur > len(out) {
		cur = len(out)
	}
	e.applyOp(editOp{kind: opEdit, sp: []splice{{pos: 0, old: old, ins: out}}}, cur)
}
