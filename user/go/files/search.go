// M155c (issue #2931): bounded content search — "find the file that
// mentions invoice without opening each one." The `/` chord raises a
// substring prompt on the status row (the rename prompt's shape); Enter
// runs the walk and the results frame takes over the grid: one
// `rel:line: snippet` row per hit, `n`/`N` walk the set, Enter opens the
// hit's file through the existing mime dispatch, Esc hands the frame
// back.
//
// The walk is honest about being bounded: it covers the current folder's
// subtree to depth 4, at most 256 files, reads at most 1 MiB of any
// file, and collects at most 64 hits. mime.Sniff decides which files are
// even candidates — only text (and the table's can't-tell Unknown) is
// scanned; images, audio, archives, documents and binaries count as
// skipped, and a folder where every file is a skip answers `files:
// search refused binary` instead of an empty result set. Hitting any
// bound stops the walk: the result row and the marker name the bound
// (`truncated=<bound>`), and the hits collected before the stop are
// real, never discarded — except at a mount root, where a partial
// answer would read as "searched everything": a root search that cannot
// hold its bounds is refused by name.
//
// The model stays pure: the walk reads directories and file bodies only
// through the searchDirList/readHead seams, so the host tests pin the
// matcher, each bound, the binary skip and the truncation shapes without
// a guest.
package main

import (
	"bytes"
	"strings"

	"virelai/mime"
	"virelai/rss/keys"
	"virelai/vi"
)

const (
	// searchMaxDepth bounds the descent: the search root's own entries
	// are depth 0, a subdir's entries depth 1, and so on — a directory
	// whose entries would be depth 5 is never entered.
	searchMaxDepth = 4
	// searchMaxFiles bounds the files the walk looks at — scanned and
	// skipped both count; directories are the walk's structure, not
	// files.
	searchMaxFiles = 256
	// searchMaxRead caps the bytes read of any one file — the card's
	// 1 MiB; the read seam's own 256 KiB clamp (vi.MaxFileBytes) is the
	// tighter bound that actually applies. A scanned file larger than
	// what was read stops the walk: pretending the tail was searched
	// would be a lie.
	searchMaxRead = 1 << 20 // 1 MiB
	// searchMaxHits bounds the result set.
	searchMaxHits = 64
	// maxSearchPat bounds the typed needle, like the rename prompt's
	// name bound.
	maxSearchPat = 48
)

// searchDirList is the walk's directory seam — vi.DirList on the guest,
// swapped by the host tests (the mountRows pattern).
var searchDirList = vi.DirList

// searchHit is one matching line: the file's absolute path, the path
// relative to the searched directory for the row, the 1-based line
// number, and the sanitized line text the row shows.
type searchHit struct {
	path    string
	rel     string
	line    int
	snippet string
}

// search is the open search's whole state: the needle, the walk's
// accounting, the result set, and the cursor into it.
type search struct {
	pat     string
	root    string
	hits    []searchHit
	sel     int
	top     int
	scanned int
	skipped int
	trunc   string // "", or the bound that stopped the walk
}

// foldByte is the ASCII case fold the card scopes: a-z fold onto A-Z,
// every other byte is itself (no Unicode case folding — plain bytes).
func foldByte(c byte) byte {
	if c >= 'a' && c <= 'z' {
		return c - ('a' - 'A')
	}
	return c
}

// containsFold reports whether line carries pat, byte-for-byte under the
// ASCII fold — the same left-to-right scan shape find.at runs, with the
// needle pre-folded once by the caller.
func containsFold(line, pat []byte) bool {
	if len(pat) == 0 || len(pat) > len(line) {
		return false
	}
	for i := 0; i+len(pat) <= len(line); i++ {
		ok := true
		for j := 0; j < len(pat); j++ {
			if foldByte(line[i+j]) != pat[j] {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// startSearch is the `/` chord: the status-row prompt owns the keyboard
// until Enter runs the walk or Esc sheds it. The volumes root is the
// mount table, not a tree — the refusal names it rather than listing
// rows as files.
func (m *model) startSearch() {
	if m.path == volsPath {
		m.emit(markerSearchNo + "root")
		m.status = "search: volumes are browse-only"
		return
	}
	if m.path == favsView {
		// M167b: the pins are a pseudo-listing, not a tree — the walk
		// has nothing to descend into.
		m.emit(markerSearchNo + "favs")
		m.status = "search: pins are browse-only"
		return
	}
	m.mode = modeSearchInput
	m.input = ""
	m.status = "search"
}

// searchKey is the modeSearchInput contract: runes and Backspace edit
// the needle, Enter commits, Esc cancels — the rename prompt's shape.
func (m *model) searchKey(ev keys.Event) {
	switch ev.Key {
	case keys.KeyEnter:
		pat := m.input
		m.input = ""
		m.mode = modeNormal
		if pat == "" {
			m.status = "search cancelled"
			return
		}
		m.runSearch(pat)
	case keys.KeyEsc, keys.KeyBackspace:
		if ev.Key == keys.KeyBackspace && len(m.input) > 0 {
			m.input = m.input[:len(m.input)-1]
			return
		}
		m.mode = modeNormal
		m.input = ""
		m.status = "search cancelled"
	case keys.KeyCtrlC:
		m.quit = true
	case keys.KeyRune:
		if len(m.input) < maxSearchPat {
			m.input += string(ev.Rune)
		}
	}
}

// runSearch executes the bounded walk for pat and lands the model on the
// outcome: the results frame, or one of the named refusals. The markers
// ride pending like every other model receipt.
func (m *model) runSearch(pat string) {
	// The '/' prompt refuses the mount-table root before it is reached;
	// the M167b `--search` argv path lands here directly, so the same
	// named refusal lives at the walk's own door too.
	if m.path == volsPath || m.path == favsView {
		m.emit(markerSearchNo + "root")
		m.status = "search: volumes are browse-only"
		return
	}
	s := &m.search
	*s = search{pat: pat, root: m.path}
	needle := make([]byte, len(pat))
	for i := 0; i < len(pat); i++ {
		needle[i] = foldByte(pat[i])
	}
	m.searchDir(m.path, 0, needle)

	// A walk over a mount root that could not hold its bounds answered
	// only part of "everything" — refuse it by name rather than show a
	// bounded slice as if it were the share's whole answer.
	if s.trunc != "" && isMountRoot(m.path) {
		m.emit(markerSearchNo + "root")
		m.status = "search: share root too large"
		return
	}
	// Every file a skip and nothing scanned: the honest answer is the
	// named refusal, not an empty result set that reads as "no match".
	if s.scanned == 0 && s.skipped > 0 {
		m.emit(markerSearchNo + "binary")
		m.status = "search: all files binary"
		return
	}
	m.emit(markerSearch + "hits=" + vi.Itoa64(int64(len(s.hits))) +
		" scanned=" + vi.Itoa64(int64(s.scanned)) +
		" skipped=" + vi.Itoa64(int64(s.skipped)) + s.truncWord())
	for _, h := range s.hits {
		m.emit(markerSearchHit + h.path + ":" + vi.Itoa64(int64(h.line)))
	}
	m.mode = modeSearchHits
	m.status = "search: " + vi.Itoa64(int64(len(s.hits))) + " hits"
}

// truncWord is the marker's optional fourth field — empty when the walk
// completed inside every bound, ` truncated=<bound>` when one stopped it.
func (s search) truncWord() string {
	if s.trunc == "" {
		return ""
	}
	return " truncated=" + s.trunc
}

// searchDir lists one directory of the subtree, scans its files, then
// descends into its subdirectories — files first, so a too-deep subdir
// cannot cut off same-depth files the bound still covers. Any bound the
// walk hits sets s.trunc and stops everything: the hits already
// collected are real, the set is honestly partial.
func (m *model) searchDir(dir string, depth int, needle []byte) {
	s := &m.search
	var ents [vi.MaxDirEntries]vi.DirEntry
	n, rc := searchDirList(dir, ents[:])
	if rc < 0 {
		return // an unreadable dir contributes nothing — its parent still counts
	}
	// Files before subdirs: the listing's own order would put the dirs
	// first and let one too-deep directory truncate its siblings' files.
	for i := 0; i < n; i++ {
		if s.trunc != "" {
			return
		}
		if ents[i].Dir() {
			continue
		}
		if s.scanned+s.skipped >= searchMaxFiles {
			s.trunc = "files"
			return
		}
		child, ok := joinPath(dir, ents[i].NameString())
		if !ok {
			s.skipped++
			continue
		}
		m.searchFile(child, ents[i].NameString(), ents[i].Size, needle)
	}
	for i := 0; i < n; i++ {
		if s.trunc != "" {
			return
		}
		if !ents[i].Dir() {
			continue
		}
		if depth+1 > searchMaxDepth {
			s.trunc = "depth"
			return
		}
		child, ok := joinPath(dir, ents[i].NameString())
		if !ok {
			continue
		}
		m.searchDir(child, depth+1, needle)
	}
}

// searchFile reads up to the per-file cap and scans the lines. Sniff
// decides candidacy first: only Text and the can't-tell Unknown are
// searched — a skip still counts against the files bound, so the counts
// always add up to what the walk looked at.
func (m *model) searchFile(path, name string, size uint32, needle []byte) {
	s := &m.search
	data, rc := readHead(path, searchMaxRead)
	if rc < 0 {
		s.skipped++
		return
	}
	switch mime.Sniff(name, data) {
	case mime.Text, mime.Unknown:
	default:
		s.skipped++
		return
	}
	s.scanned++
	for off, line := 0, 1; off < len(data); line++ {
		end := bytes.IndexByte(data[off:], '\n')
		var row []byte
		if end < 0 {
			row = data[off:]
			off = len(data)
		} else {
			row = data[off : off+end]
			off += end + 1
		}
		if containsFold(row, needle) {
			if len(s.hits) >= searchMaxHits {
				s.trunc = "hits"
				return
			}
			s.hits = append(s.hits, searchHit{
				path:    path,
				rel:     strings.TrimPrefix(path, s.root+"/"),
				line:    line,
				snippet: sanitizePreview(row),
			})
		}
	}
	// The read cap is a bound like the others: a scanned file whose tail
	// the cap kept unread stops the walk — the hits already collected
	// stay, but "searched this folder" can only claim the cap.
	if uint64(len(data)) < uint64(size) {
		s.trunc = "read"
	}
}

// hitsKey is the modeSearchHits keyboard contract: the cursor walks the
// hit rows (j/k/arrows move, n/N wrap like the find bar's again-from-top
// rule), Enter dispatches the hit's file through the same mime open path
// a listed file takes, and Esc/Backspace/`/` hand the frame back.
func (m *model) hitsKey(ev keys.Event) {
	switch ev.Key {
	case keys.KeyEsc, keys.KeyBackspace:
		m.closeSearch()
	case keys.KeyUp:
		m.searchMove(-1)
	case keys.KeyDown:
		m.searchMove(1)
	case keys.KeyPageUp:
		m.searchMove(-m.bodyRows())
	case keys.KeyPageDown:
		m.searchMove(m.bodyRows())
	case keys.KeyEnter:
		m.openHit()
	case keys.KeyCtrlC:
		m.quit = true
	case keys.KeyRune:
		switch ev.Rune {
		case 'j':
			m.searchMove(1)
		case 'k':
			m.searchMove(-1)
		case 'n':
			m.searchMoveWrap(1)
		case 'N':
			m.searchMoveWrap(-1)
		case '/':
			m.closeSearch()
		}
	}
}

// searchMove shifts the hit cursor, clamped at the ends like the list.
func (m *model) searchMove(delta int) {
	s := &m.search
	if len(s.hits) == 0 {
		return
	}
	s.sel += delta
	if s.sel < 0 {
		s.sel = 0
	}
	if s.sel >= len(s.hits) {
		s.sel = len(s.hits) - 1
	}
	m.searchVisible()
}

// searchMoveWrap is n/N: the cursor wraps at the ends, the same
// again-from-the-top rule find.From's ordinal reports.
func (m *model) searchMoveWrap(delta int) {
	s := &m.search
	if len(s.hits) == 0 {
		return
	}
	s.sel = (s.sel + delta + len(s.hits)) % len(s.hits)
	m.searchVisible()
}

// searchVisible keeps the hit cursor inside the results window — the
// list's ensureSelVisible invariant on the results' own scroll offset.
func (m *model) searchVisible() {
	s := &m.search
	body := m.bodyRows()
	if s.sel < s.top {
		s.top = s.sel
	} else if s.sel >= s.top+body {
		s.top = s.sel - body + 1
	}
	if s.top < 0 {
		s.top = 0
	}
}

// openHit dispatches the hit under the cursor to its type's default
// handler — the same resolveFile/launch path Enter on a listed file
// takes, aimed at the hit's absolute path.
func (m *model) openHit() {
	s := &m.search
	if s.sel < 0 || s.sel >= len(s.hits) {
		return
	}
	h := s.hits[s.sel]
	req, openErr := resolveFile(h.path)
	if openErr != nil {
		m.refuseOpen(baseName(h.path), openErr)
		return
	}
	m.emit(markerOpenFile + baseName(h.path) + " type=" + req.Type.String() +
		" handler=" + req.Handler.Bin)
	m.launch = launchReq{bin: req.Handler.Bin, path: req.Target}
	m.status = "opening " + baseName(req.Handler.Bin)
}

// closeSearch dismisses the results frame — Esc, Backspace, a second
// `/`, or a pointer press — restoring the listing underneath.
func (m *model) closeSearch() {
	if m.mode != modeSearchHits {
		return
	}
	m.mode = modeNormal
	m.emit(markerSearchClose)
	m.status = "listed"
}
