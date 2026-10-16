package main

import (
	"sort"
	"strings"
)

// STORE.TXT is the M101d (#2316) installed-app state file: one line per
// store-managed app recording the stream it came from, the installed
// stream head, and the one-step rollback target. A FLINT head is only
// hashes — "the previous version" is not recoverable from the log — so
// rollback needs the prior ELF BYTES, retained at /host/<BIN>.prev and
// authenticated by prev_sha256 (re-fetching is not acceptable). The file
// is written whole through WriteFileSafe AFTER the ELF + manifest row
// publish; a corrupt file refuses every command that loads it — STORE
// never writes on top of bytes it could not read.
//
// Line grammar (prev_row is the verbatim tail, so its interior spaces
// and '|' fields survive without an escape layer):
//
//	name=<BIN.ELF> stream=<s> head=<id> sha256=<64hex> \
//	    prev_head=<id|-> prev_sha256=<64hex|-> prev_row=<row|->
//
// The three prev_* fields are all-or-none: an app with no recorded
// rollback target carries three '-'.
const (
	statePath     = "/host/STORE.TXT"
	stateMaxBytes = 64 * 1024 // far past honest: ~1 KiB per app line
)

// storeEntry is one STORE.TXT line.
type storeEntry struct {
	Name     string // installed binary, e.g. GOHELLO.ELF
	Stream   string // release stream name the app installs/updates from
	Head     string // installed stream head (change id)
	SHA256   string // sha256 hex of the installed ELF at Head
	PrevHead string // prior installed head; "" when no rollback target
	PrevSHA  string // sha256 hex of <BIN>.prev; "" when PrevHead is ""
	PrevRow  string // prior manifest row, verbatim; "" when PrevHead is ""
}

func prevPath(bin string) string { return "/host/" + bin + ".prev" }

// isHex64 reports whether s is exactly 64 lowercase hex chars (the
// release.go ELFSHA256 grammar, reused for state fields).
func isHex64(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// parseStateLine parses one STORE.TXT data line. prev_row is split off
// FIRST (it is the verbatim tail), then the leading key=value fields are
// whitespace-tokenized.
func parseStateLine(line string) (*storeEntry, error) {
	e := &storeEntry{}
	rest := line
	e.PrevRow = "-"
	if i := strings.Index(line, " prev_row="); i >= 0 {
		e.PrevRow = line[i+len(" prev_row="):]
		rest = line[:i]
	}
	for _, f := range strings.Fields(rest) {
		k, v, ok := strings.Cut(f, "=")
		if !ok {
			return nil, refuse("state_malformed", line)
		}
		switch k {
		case "name":
			e.Name = v
		case "stream":
			e.Stream = v
		case "head":
			e.Head = v
		case "sha256":
			e.SHA256 = v
		case "prev_head":
			e.PrevHead = v
		case "prev_sha256":
			e.PrevSHA = v
		default:
			return nil, refuse("state_malformed", line)
		}
	}
	if e.Name == "" || e.Stream == "" || e.Head == "" || e.Head == "-" ||
		e.PrevHead == "" || e.PrevSHA == "" {
		return nil, refuse("state_malformed", line)
	}
	nb, nok := normalizeBin(strings.TrimSuffix(e.Name, ".ELF"))
	if !nok || nb != e.Name {
		return nil, refuse("state_malformed", line)
	}
	if !isHex64(e.SHA256) {
		return nil, refuse("state_malformed", line)
	}
	// prev_* are all-or-none.
	none := e.PrevHead == "-" && e.PrevSHA == "-" && e.PrevRow == "-"
	all := e.PrevHead != "-" && isHex64(e.PrevSHA) && e.PrevRow != "-" && e.PrevRow != ""
	if !none && !all {
		return nil, refuse("state_malformed", line)
	}
	if none {
		e.PrevHead, e.PrevSHA, e.PrevRow = "", "", ""
	}
	return e, nil
}

// loadState reads STORE.TXT into a name->entry map. An absent file is an
// empty store state; any malformed line refuses whole.
func loadState(fs FS) (map[string]*storeEntry, error) {
	out := map[string]*storeEntry{}
	if !fs.Exists(statePath) {
		return out, nil
	}
	b, err := fs.ReadFile(statePath, stateMaxBytes)
	if err != nil {
		return nil, refuse("state_malformed", "")
	}
	for _, line := range strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		e, err := parseStateLine(line)
		if err != nil {
			return nil, err
		}
		if _, dup := out[e.Name]; dup {
			return nil, refuse("state_malformed", e.Name)
		}
		out[e.Name] = e
	}
	return out, nil
}

// renderState serializes the map: a #v1 header plus one line per app in
// sorted-name order (deterministic bytes — a rewrite that changes
// nothing produces an identical file).
func renderState(state map[string]*storeEntry) []byte {
	names := make([]string, 0, len(state))
	for n := range state {
		names = append(names, n)
	}
	sort.Strings(names)
	var b strings.Builder
	b.WriteString("#v1\n")
	for _, n := range names {
		e := state[n]
		ph, ps, pr := e.PrevHead, e.PrevSHA, e.PrevRow
		if ph == "" {
			ph = "-"
		}
		if ps == "" {
			ps = "-"
		}
		if pr == "" {
			pr = "-"
		}
		b.WriteString("name=" + e.Name +
			" stream=" + e.Stream +
			" head=" + e.Head +
			" sha256=" + e.SHA256 +
			" prev_head=" + ph +
			" prev_sha256=" + ps +
			" prev_row=" + pr + "\n")
	}
	return []byte(b.String())
}
