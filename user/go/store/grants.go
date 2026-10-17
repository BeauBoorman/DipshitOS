package store

import (
	"strings"

	"virelai/vi"
)

// M113d (#2420, ADR 0054 Part II D10): "the publisher declares, the user
// decides." STORE reads the signed ReleaseCaps out of a verified release
// and PROPOSES a `(name, sha256, words)` grant row — the manifest's
// signed release atom supplies the name binding and the digest. It never
// lands a fresh grant itself: nothing the publisher signs becomes power
// until a seat-held write puts it in GRANTS.TXT (GOSET's consent, or
// any CAP_PROC_ADMIN principal's `vi.GrantWriteLine`).
//
// The ONE write STORE performs is the non-widening keep: an update moves
// the measured sha256, and a grant row bound to the old image goes
// stale at exec (grant_stale refuses — a named row never falls open).
// When the new release's declared words are a subset of the words an
// existing row already carries, the user's earlier consent covers the
// ask by construction, so a STORE that can reach the admin slot re-pins
// the row's sha256 and keeps the exact consented words. A widening ask
// is left stale BY DESIGN — the unconsented image does not run until a
// consent gesture writes the new words — and the ask is re-proposed.
//
// Markers (printed AFTER the step they name succeeded):
//
//	store: grant propose <BIN> words=<csv>   — the surfaced ask
//	store: grant keep <BIN> words=<csv>      — row re-pinned, consent held
//	store: grant keep failed <BIN> rc=<n>    — admin write refused; the
//	                                           stale row stands honestly

// grantRowsFn and grantWriteFn are the slot-89 seams; tests substitute
// them. The kernel gates both ops: the registered WM seat or
// CAP_PROC_ADMIN, and never the caller's own image — an unprivileged
// STORE reads -EACCES and falls back to proposing.
var grantRowsFn = func() ([]vi.GrantRow, int64) { return vi.GrantRows() }
var grantWriteFn = func(line string) int64 { return vi.GrantWriteLine(line) }

// splitGrantWords decodes a row's words field — "-" or "" means the row
// narrows to nothing (the empty set, which declares nothing and is a
// subset of every set).
func splitGrantWords(s string) []string {
	if s == "" || s == "-" {
		return nil
	}
	return strings.Split(s, ",")
}

// grantPropose surfaces the signed ask: the proposed row text a consent
// gesture would land — name, the release's pinned digest, the declared
// words in canonical order.
func grantPropose(bin string, declared []string) {
	ConsoleFn("store: grant propose " + bin + " words=" + vi.GrantWordsCanonical(declared))
}

// grantSync runs the post-publish grant hook for bin at image hash sha
// whose release declared `declared` (nil = no ReleaseCaps). Call it after
// every successful install/update/rollback publish: the declared ask and
// the granted table are reconciled in exactly one place.
func grantSync(bin, sha string, declared []string) {
	rows, rc := grantRowsFn()
	if rc < 0 {
		// No seat/admin half: STORE can only name the ask. The grants
		// pane computes the same state against the table it can read.
		if len(declared) > 0 {
			grantPropose(bin, declared)
		}
		return
	}
	var row *vi.GrantRow
	for i := range rows {
		if rows[i].Name == bin {
			row = &rows[i]
		}
	}
	if row == nil {
		if len(declared) > 0 {
			grantPropose(bin, declared)
		}
		return
	}
	rowWords := splitGrantWords(row.Words)
	if !vi.GrantWordsSubset(declared, rowWords) {
		// The ask widens past the consented words: the row is left
		// bound to the pre-update image (stale at exec — a widening
		// publisher's bytes do not run under yesterday's consent), and
		// the ask is proposed again.
		grantPropose(bin, declared)
		return
	}
	// Non-widening: consent already covers this ask. Re-pin the row's
	// binding to the image just published, keeping the consented words
	// verbatim — a wildcard row needs no re-pin at all.
	if row.SHA == "*" || row.SHA == sha {
		return
	}
	line := bin + "\t" + sha + "\t" + vi.GrantWordsCanonical(rowWords)
	if rc := grantWriteFn(line); rc < 0 {
		ConsoleFn("store: grant keep failed " + bin + " rc=" + vi.Itoa64(rc))
		return
	}
	ConsoleFn("store: grant keep " + bin + " words=" + vi.GrantWordsCanonical(rowWords))
}
