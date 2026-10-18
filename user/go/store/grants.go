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

// ---------------------------------------------------------------------------
// M116c (#2469, ADR 0054 D10): install-time consent. The signed ReleaseCaps
// an install proposes is ANSWERED by the same gesture GOSET's pane lands:
// `store consent <name>` writes the recorded (name, installed sha256,
// declared words) row through slot 89 — the write still needs the seat or
// CAP_PROC_ADMIN, so nothing the publisher signs becomes power off a
// script. `store decline <name>` is the refusal gesture: no write, the app
// keeps the ambient floor. Both verbs answer only a REAL pending ask —
// consent on an app with no recorded declaration is `no_ask`, on a bin the
// store never tracked is `not_installed`.
//
// Markers (printed AFTER the step they name):
//
//	store: consent <BIN>                       — the gesture, echoed first
//	store: grant written name=<BIN> words=<w>  — the row landed
//	store: consent declined name=<BIN>         — refused; ambient stands
//	store: refuse <code> <detail>              — the named refusal
// ---------------------------------------------------------------------------

// ConsentLine returns the GRANTS.TXT line a consent gesture for bin lands
// — name, the installed image's recorded sha256, the release's declared
// words — so every consent surface (this verb, GOSTORE's prompt) writes
// the same bytes. Errors: not_installed (no STORE.TXT entry), no_ask (the
// installed release declared nothing), or the state-file refusal.
func ConsentLine(fs FS, bin string) (string, error) {
	state, err := loadState(fs)
	if err != nil {
		return "", err
	}
	e, ok := state[bin]
	if !ok {
		return "", refuse("not_installed", bin)
	}
	if e.Caps == "" {
		return "", refuse("no_ask", bin)
	}
	return vi.GrantLine(vi.GrantRow{
		Name:  e.Name,
		SHA:   e.SHA256,
		Words: vi.GrantWordsCanonical(splitGrantWords(e.Caps)),
	}), nil
}

// grantWriteErr maps a slot-89 write errno to its named refusal.
func grantWriteErr(rc int64) error {
	switch -rc {
	case vi.ErrEACCES:
		return refuse("eacces", "")
	case vi.ErrEINVAL:
		return refuse("einval", "")
	case vi.ErrENOSPC:
		return refuse("enospc", "")
	case vi.ErrENXIO:
		return refuse("enxio", "")
	case vi.ErrEIO:
		return refuse("eio", "")
	}
	return refuse("grant_refused", vi.Itoa64(-rc))
}

// Consent implements `store consent <name>` — the scriptable install-time
// consent gesture: land the pending ask's row through the admin slot.
func Consent(fs FS, arg string) int {
	bin, ok := normalizeBin(arg)
	if !ok {
		return runErr(refuse("name_invalid", arg))
	}
	ConsoleFn("store: consent " + bin)
	line, err := ConsentLine(fs, bin)
	if err != nil {
		return runErr(err)
	}
	if rc := grantWriteFn(line); rc < 0 {
		return runErr(grantWriteErr(rc))
	}
	if _, words, ok := grantLineWords(line); ok {
		ConsoleFn("store: grant written name=" + bin + " words=" + words)
	}
	return 0
}

// Decline implements `store decline <name>` — the refusal gesture for the
// pending ask: no write, the app keeps the ambient floor. It still names a
// REAL ask (not_installed/no_ask refuse the same way consent does) — a
// decline for nothing is silence a gate cannot tell from a typo.
func Decline(fs FS, arg string) int {
	bin, ok := normalizeBin(arg)
	if !ok {
		return runErr(refuse("name_invalid", arg))
	}
	ConsoleFn("store: decline " + bin)
	if _, err := ConsentLine(fs, bin); err != nil {
		return runErr(err)
	}
	ConsoleFn("store: consent declined name=" + bin)
	return 0
}

// grantLineWords splits a `name<TAB>sha|*<TAB>words` line back into its
// words field — the line ConsentLine just built, so the parse cannot
// fail in practice; the bool only guards against a substituted seam.
func grantLineWords(line string) (string, string, bool) {
	f0 := strings.IndexByte(line, '\t')
	if f0 <= 0 {
		return "", "", false
	}
	rest := line[f0+1:]
	f1 := strings.IndexByte(rest, '\t')
	if f1 < 0 {
		return "", "", false
	}
	return line[:f0], rest[f1+1:], true
}
