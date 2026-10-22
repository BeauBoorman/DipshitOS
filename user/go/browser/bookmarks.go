// The bookmark store + sidebar (M126b #2594).
//
// Bookmarks are data in the FLINT store shape on the persistent share, not
// a bespoke browser ledger (the index's "bookmarks are data, not UI" bet).
// A signed Change stream needs the agent-sign key, which an app never
// holds, so the store is the UNSIGNED half of the ADR 0049 layout — the
// workspace atom table, the same bytes `flint init` + `flint add` leave
// before a commit:
//
//	/host/FLINT/streams/<uuid>.json          stream record (name
//	                                         "web-bookmarks", head null)
//	/host/FLINT/ws/bookmarks/WORKSPACE.json  {name, src, stream, created}
//	/host/FLINT/ws/bookmarks/src/            the declared (empty) source root
//	/host/FLINT/ws/bookmarks/ATOMS.jsonl     one atom line per bookmark
//
// A bookmark is an atom of kind "bookmark": name = the page title, and the
// FLINT hash rule is kept — hash covers the content with the name excluded
// (url + added), sig_hash covers the signature (the URL, which is also the
// dedupe identity). metadata.url and metadata.added carry the row. The
// atom table is rewritten whole through WriteFileSafe on every mutation —
// never appended to — and read whole at boot under the ADR 0049 torn-
// append rule: a body that does not end in '\n' or a line that will not
// parse refuses the load closed, so a half-written store can never
// resurrect as a half-list.
//
// The UI is a docked panel over the left edge of the content area: rows of
// 16 px, a header that counts the store, a per-row "x" delete zone, the
// current page's row accent-marked. Ctrl+Shift+B toggles it (the card's
// chord); Ctrl+D toggles the current page's atom. Picking a row is a
// fresh visit on the navigation stack — it pushes, it does not move a
// cursor, matching the history dropdown's rule.

package main

import (
	"encoding/hex"
	"encoding/json"
	"sort"
	"strings"

	"virelai/sshlib"
	"virelai/vi"
	"virelai/webrender"
)

const (
	flintRoot      = "/host/FLINT"
	flintStreamDir = "/host/FLINT/streams"
	flintWSDir     = "/host/FLINT/ws"

	bookStreamName = "web-bookmarks"
	bookWSName     = "bookmarks"
	bookWSDir      = "/host/FLINT/ws/bookmarks"
	bookWSPath     = "/host/FLINT/ws/bookmarks/WORKSPACE.json"
	bookSrcDir     = "/host/FLINT/ws/bookmarks/src"
	bookAtomsPath  = "/host/FLINT/ws/bookmarks/ATOMS.jsonl"
	bookSpanFile   = "bookmarks" // the atoms' virtual source file

	// bookMaxFile mirrors flint's MaxFileReadBytes; bookMaxAtoms its
	// 4096-Atom store bound.
	bookMaxFile  = 4 * 1024 * 1024
	bookMaxAtoms = 4096
)

// The guest file seam: one implementation over vi, one in-memory for the
// host tests (the flint fsys / rss FileIO pattern — a main package cannot
// share theirs).
type bookStoreIO interface {
	read(path string, max int) ([]byte, bool)
	write(path string, b []byte) bool // crash-safe replace (WriteFileSafe)
	mkdir(path string) bool
	exists(path string) bool // files AND directories
}

type guestBookStore struct{}

func (guestBookStore) read(path string, max int) ([]byte, bool) {
	b, rc := vi.ReadFileAll(path, max)
	if rc < 0 {
		return nil, false
	}
	return b, true
}

func (guestBookStore) write(path string, b []byte) bool {
	return vi.WriteFileSafe(path, b) >= 0
}

func (guestBookStore) mkdir(path string) bool {
	h, rc := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if rc == vi.ErrFileExists {
		return true
	}
	if rc < 0 {
		return false
	}
	vi.FileClose(uint32(h))
	return true
}

func (guestBookStore) exists(path string) bool {
	h, rc := vi.FileOpen(path, vi.ModeRead)
	if rc >= 0 {
		vi.FileClose(uint32(h))
		return true
	}
	if rc == vi.ErrFileIsDir {
		return true
	}
	var entries [1]vi.DirEntry
	_, drc := vi.DirList(path, entries[:])
	return drc >= 0
}

// Test seams (the trustview pattern): host tests substitute a memory store
// and a deterministic clock/rand; guest code never sets these.
var (
	bookIO   bookStoreIO = guestBookStore{}
	bookNow              = vi.Now
	bookRand             = func(b []byte) error { _, err := vi.Random(b); return err }
)

// --- the FLINT records (mirrored, not shared: flint is a main package) ---

type flintSpan struct {
	File  string `json:"file"`
	Start uint32 `json:"start"`
	End   uint32 `json:"end"`
}

type flintAtom struct {
	ID       string            `json:"id"`
	Kind     string            `json:"kind"`
	Name     string            `json:"name"`
	Hash     string            `json:"hash"`
	SigHash  string            `json:"sig_hash"`
	Span     flintSpan         `json:"span"`
	Metadata map[string]string `json:"metadata,omitempty"`
	Origin   string            `json:"origin,omitempty"`
}

type flintFork struct {
	Stream string `json:"stream"`
	Change string `json:"change"`
}

type flintStream struct {
	ID         string      `json:"id"`
	Name       string      `json:"name"`
	Head       *string     `json:"head"`
	Created    int64       `json:"created"`
	ForkedFrom *flintFork `json:"forked_from"`
}

type flintWorkspace struct {
	Name    string `json:"name"`
	Src     string `json:"src"`
	Stream  string `json:"stream"`
	Created int64  `json:"created"`
}

type bookmark struct {
	ID    string
	URL   string
	Title string
	Added int64
}

// bookUUIDGen mints canonical UUIDv7 identifiers — the same layout flint's
// UUIDGen produces (ms timestamp, v7, variant 10, 12-bit monotonic seq).
type bookUUIDGen struct {
	lastMs int64
	seq    uint16
}

var bookUUID = &bookUUIDGen{}

func (g *bookUUIDGen) new() (string, bool) {
	sec := bookNow()
	if sec < 0 {
		return "", false
	}
	ms := sec * 1000
	if ms > g.lastMs {
		g.lastMs, g.seq = ms, 0
	} else {
		g.seq++
		if g.seq > 0x0fff {
			g.seq, g.lastMs = 0, g.lastMs+1
		}
	}
	var u, rnd [16]byte
	if err := bookRand(rnd[:8]); err != nil {
		return "", false
	}
	u[0] = byte(uint64(g.lastMs) >> 40)
	u[1] = byte(uint64(g.lastMs) >> 32)
	u[2] = byte(uint64(g.lastMs) >> 24)
	u[3] = byte(uint64(g.lastMs) >> 16)
	u[4] = byte(uint64(g.lastMs) >> 8)
	u[5] = byte(uint64(g.lastMs))
	u[6] = 0x70 | byte((g.seq>>8)&0x0f)
	u[7] = byte(g.seq & 0xff)
	copy(u[8:], rnd[:8])
	u[8] = 0x80 | (u[8] & 0x3f)
	var buf [36]byte
	hex.Encode(buf[0:8], u[0:4])
	buf[8] = '-'
	hex.Encode(buf[9:13], u[4:6])
	buf[13] = '-'
	hex.Encode(buf[14:18], u[6:8])
	buf[18] = '-'
	hex.Encode(buf[19:23], u[8:10])
	buf[23] = '-'
	hex.Encode(buf[24:36], u[10:16])
	return string(buf[:]), true
}

func bookSHA(domain, s string) string {
	sum := sshlib.SHA256Sum(append([]byte(domain), s...))
	return hex.EncodeToString(sum[:])
}

// atomForBookmark renders one bookmark as its stored atom. hash covers the
// content with the name excluded (the FLINT rule): the URL and the added
// stamp. sig_hash covers the signature: the URL alone, which is also the
// store's dedupe identity.
func atomForBookmark(b bookmark) flintAtom {
	return flintAtom{
		ID:      b.ID,
		Kind:    "bookmark",
		Name:    b.Title,
		Hash:    bookSHA("FLINT-BOOKMARK/1\x00", b.URL+"\x00"+itoa64(b.Added)),
		SigHash: bookSHA("FLINT-BOOKMARK-SIG/1\x00", b.URL),
		Span:    flintSpan{File: bookSpanFile},
		Metadata: map[string]string{
			"url":   b.URL,
			"added": itoa64(b.Added),
		},
	}
}

// sortBookAtoms is flint's WriteWorkspaceAtoms order: (span.file, start,
// kind, name, id) — deterministic bytes for a deterministic file.
func sortBookAtoms(atoms []flintAtom) {
	sort.Slice(atoms, func(i, j int) bool {
		if atoms[i].Span.File != atoms[j].Span.File {
			return atoms[i].Span.File < atoms[j].Span.File
		}
		if atoms[i].Span.Start != atoms[j].Span.Start {
			return atoms[i].Span.Start < atoms[j].Span.Start
		}
		if atoms[i].Kind != atoms[j].Kind {
			return atoms[i].Kind < atoms[j].Kind
		}
		if atoms[i].Name != atoms[j].Name {
			return atoms[i].Name < atoms[j].Name
		}
		return atoms[i].ID < atoms[j].ID
	})
}

func atomList(books []bookmark) []flintAtom {
	atoms := make([]flintAtom, len(books))
	for i, b := range books {
		atoms[i] = atomForBookmark(b)
	}
	sortBookAtoms(atoms)
	return atoms
}

// streamRecordPathFor is the <root>/streams/<id>.json path — under the
// kernel's 64-byte path cap only because the uuid is canonical 36.
func streamRecordPathFor(id string) string { return flintStreamDir + "/" + id + ".json" }

// loadBookmarks reads the store at boot: the workspace's stream id off the
// record, then every bookmark atom off ATOMS.jsonl. Missing store = empty
// store (with a one-time fold of the legacy WEB-BOOKMARKS.TXT ledger into
// atoms so an existing share does not silently lose its rows); a torn or
// malformed store refuses closed and says so on the marker line.
func (a *app) loadBookmarks() {
	fs := bookIO
	a.books, a.bookStream, a.booksErr, a.booksMigrated = nil, "", "", 0
	if b, ok := fs.read(bookWSPath, 4096); ok {
		var ws flintWorkspace
		if json.Unmarshal(b, &ws) == nil && ws.Name == bookWSName {
			a.bookStream = ws.Stream
		}
	}
	if !fs.exists(bookAtomsPath) {
		a.migrateLegacyBookmarks(fs)
		return
	}
	b, ok := fs.read(bookAtomsPath, bookMaxFile)
	if !ok {
		a.booksErr = "read"
		return
	}
	if len(b) == 0 {
		return
	}
	if b[len(b)-1] != '\n' {
		a.booksErr = "torn"
		return
	}
	for _, line := range strings.Split(string(b[:len(b)-1]), "\n") {
		var at flintAtom
		if json.Unmarshal([]byte(line), &at) != nil || at.ID == "" || at.Kind == "" || at.Name == "" {
			a.books, a.booksErr = nil, "malformed"
			return
		}
		if at.Kind != "bookmark" {
			continue // a foreign atom is not this app's row, and not corruption either
		}
		url := at.Metadata["url"]
		if url == "" || !ledgerFieldOK(url) {
			a.books, a.booksErr = nil, "malformed"
			return
		}
		var added int64
		if s := at.Metadata["added"]; s != "" {
			for i := 0; i < len(s); i++ {
				if s[i] < '0' || s[i] > '9' {
					added = -1
					break
				}
				added = added*10 + int64(s[i]-'0')
			}
			if added < 0 {
				a.books, a.booksErr = nil, "malformed"
				return
			}
		}
		a.books = append(a.books, bookmark{ID: at.ID, URL: url, Title: at.Name, Added: added})
	}
	if len(a.books) > bookMaxAtoms {
		a.books, a.booksErr = nil, "too-large"
		return
	}
}

// bookLedgerRows is ledgerRows over the store seam — schema/comment and
// blank lines dropped — so the legacy migration is host-testable like every
// other store read.
func bookLedgerRows(fs bookStoreIO, path string) []string {
	b, ok := fs.read(path, ledgerMax)
	if !ok || len(b) == 0 {
		return nil
	}
	var out []string
	for _, ln := range strings.Split(string(b), "\n") {
		ln = strings.TrimRight(ln, "\r")
		if ln == "" || strings.HasPrefix(ln, "#") {
			continue
		}
		out = append(out, ln)
	}
	return out
}

// migrateLegacyBookmarks folds the retired WEB-BOOKMARKS.TXT ledger's rows
// into atoms once, so an upgrade does not drop the user's list. Rows that
// fail the field check are dropped, never carried into the store.
func (a *app) migrateLegacyBookmarks(fs bookStoreIO) {
	rows := bookLedgerRows(fs, bookmarkPath)
	if len(rows) == 0 {
		return
	}
	for _, r := range rows {
		f := strings.SplitN(r, "\t", 3)
		if len(f) < 2 || !ledgerFieldOK(f[1]) {
			continue
		}
		title := ""
		if len(f) > 2 {
			title = f[2]
		}
		if !ledgerFieldOK(title) {
			title = ""
		}
		if title == "" {
			title = f[1] // an atom's name is required — the URL is the fallback
		}
		var added int64
		for i := 0; i < len(f[0]); i++ {
			if f[0][i] < '0' || f[0][i] > '9' {
				added = 0
				break
			}
			added = added*10 + int64(f[0][i]-'0')
		}
		id, ok := bookUUID.new()
		if !ok {
			continue
		}
		a.books = append(a.books, bookmark{ID: id, URL: f[1], Title: title, Added: added})
	}
	if len(a.books) == 0 {
		return
	}
	if a.saveBookmarks() {
		a.booksMigrated = len(a.books)
	}
}

// ensureBookStore materializes the FLINT directory shape and its two
// records on first write — mkdir is idempotent and the records are only
// written when absent, so this is cheap on every save after the first.
func (a *app) ensureBookStore() bool {
	fs := bookIO
	for _, d := range []string{flintRoot, flintStreamDir, flintWSDir, bookWSDir, bookSrcDir} {
		if !fs.mkdir(d) {
			return false
		}
	}
	if a.bookStream == "" {
		id, ok := bookUUID.new()
		if !ok {
			return false
		}
		a.bookStream = id
	}
	if !fs.exists(streamRecordPathFor(a.bookStream)) {
		b, err := json.Marshal(flintStream{ID: a.bookStream, Name: bookStreamName, Created: bookNow() * 1000})
		if err != nil || !fs.write(streamRecordPathFor(a.bookStream), append(b, '\n')) {
			return false
		}
	}
	if !fs.exists(bookWSPath) {
		b, err := json.Marshal(flintWorkspace{Name: bookWSName, Src: bookSrcDir, Stream: a.bookStream, Created: bookNow() * 1000})
		if err != nil || !fs.write(bookWSPath, append(b, '\n')) {
			return false
		}
	}
	return true
}

// saveBookmarks rewrites the atom table whole, crash-safe. The in-memory
// list is only ever mutated after this returns true — a failed publish
// never reports a bookmark it did not store.
func (a *app) saveBookmarks() bool {
	if len(a.books) > bookMaxAtoms || !a.ensureBookStore() {
		return false
	}
	var b strings.Builder
	for _, at := range atomList(a.books) {
		line, err := json.Marshal(at)
		if err != nil {
			return false
		}
		b.Write(line)
		b.WriteByte('\n')
	}
	return bookIO.write(bookAtomsPath, []byte(b.String()))
}

func bmErrText(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// bookmarkToggle is Ctrl+D (and the legacy bare-B binding): add the current
// page's atom, or drop it when the URL is already stored. (ok, added)
func (a *app) bookmarkToggle() (bool, bool) {
	if a.target == "" || !ledgerFieldOK(a.target) || !ledgerFieldOK(a.title) {
		return false, false
	}
	kept := a.books[:0]
	found := false
	for _, b := range a.books {
		if b.URL == a.target {
			found = true
			continue
		}
		kept = append(kept, b)
	}
	if found {
		old := a.books
		a.books = kept
		if !a.saveBookmarks() {
			a.books = old
			return false, false
		}
		return true, false
	}
	id, ok := bookUUID.new()
	if !ok {
		return false, false
	}
	title := a.title
	if title == "" {
		title = a.target
	}
	old := a.books
	a.books = append(append([]bookmark{}, a.books...),
		bookmark{ID: id, URL: a.target, Title: title, Added: bookNow()})
	if !a.saveBookmarks() {
		a.books = old
		return false, false
	}
	return true, true
}

// bookmarkToggleUI is the shared Ctrl+D / bare-B path: mutate, report on
// serial, repaint.
func (a *app) bookmarkToggleUI() {
	if ok, added := a.bookmarkToggle(); ok {
		if added {
			vi.ConsoleLine(markerBookmark + "added")
		} else {
			vi.ConsoleLine(markerBookmark + "removed")
		}
		a.status = "bookmark"
	} else {
		vi.ConsoleLine(markerBmErr)
		a.status = "bookmark failed"
	}
	a.dirty = true
}

// --- the sidebar -----------------------------------------------------------

const (
	sideW     = 172 // panel width, window px
	sideHeadH = 18  // "BOOKMARKS n" + close glyph
	sideRowH  = 16
	sideDelW  = 14 // per-row "x" delete zone
)

// sideRows is how many atom rows the panel can paint: like the history
// menu, it can only show what it can paint.
func (a *app) sideRows() int {
	_, h := a.canvasSize()
	return max(0, (h-histMenuY-statusH-sideHeadH)/sideRowH)
}

// sideVisible is the listed prefix of the store — the store can hold more
// than fits, and the header says the real count either way.
func (a *app) sideVisible() []bookmark {
	n := min(len(a.books), a.sideRows())
	return a.books[:n]
}

// sideHit maps a window-local point inside the row area to (row, on the
// row's delete glyph).
func (a *app) sideHit(x, y int) (int, bool, bool) {
	rows := a.sideVisible()
	if len(rows) == 0 || !inRect(x, y, 0, histMenuY+sideHeadH, sideW, len(rows)*sideRowH) {
		return 0, false, false
	}
	i := (y - histMenuY - sideHeadH) / sideRowH
	if i >= len(rows) {
		return 0, false, false
	}
	return i, x >= sideW-sideDelW, true
}

// sideCloseHit is the header's "x" zone.
func (a *app) sideCloseHit(x, y int) bool {
	return inRect(x, y, sideW-sideDelW, histMenuY, sideDelW, sideHeadH)
}

// toggleSidebar opens/closes the panel. Opening lists the store on serial
// AFTER the frame is published, so `web: bookmarks n=` means "the list is
// on screen" (the marker-never-outruns-paint rule, same as the history
// menu).
func (a *app) toggleSidebar() {
	if a.sideOpen {
		a.sideOpen, a.dirty = false, true
		return
	}
	a.urlEditing = false
	a.histOpen = false
	a.sideOpen, a.sideSel = true, 0
	// Arc4 #238: under shim compositing the kernel lowers the focused
	// window on Ctrl+Shift+B — the card's sidebar chord — at input decode,
	// which races ahead of the app's queued key event. A hidden panel is
	// not a sidebar, so opening always re-raises the window: the app is
	// the last mover and wins the stack back.
	vi.WinRaise(a.win)
	a.render()
	vi.SleepNs(frameSettleNs)
	a.render()
	a.dirty = false
	rows := a.sideVisible()
	vi.ConsoleLine(markerBmOpen + itoa(len(rows)))
	for i, b := range rows {
		vi.ConsoleLine(markerBmRow + itoa(i) + " " + b.URL)
	}
}

// pickBookmark navigates to row i — a fresh visit, like the history pick.
// The panel stays open: it is docked, not modal.
func (a *app) pickBookmark(i int) {
	rows := a.sideVisible()
	if i < 0 || i >= len(rows) {
		return
	}
	vi.ConsoleLine(markerBmPick + rows[i].URL)
	from := a.target
	if from == "" {
		from = "bookmarks"
	}
	a.navigate(rows[i].URL, from)
}

// delBookmark removes row i's atom from the store — the entry-level delete
// the card calls for.
func (a *app) delBookmark(i int) {
	rows := a.sideVisible()
	if i < 0 || i >= len(rows) {
		return
	}
	id := rows[i].ID
	old := a.books
	kept := a.books[:0]
	for _, b := range a.books {
		if b.ID != id {
			kept = append(kept, b)
		}
	}
	a.books = kept
	if !a.saveBookmarks() {
		a.books = old
		vi.ConsoleLine(markerBmErr)
	} else {
		vi.ConsoleLine(markerBookmark + "removed")
		a.status = "bookmark removed"
	}
	if a.sideSel >= len(a.books) {
		a.sideSel = max(0, len(a.books)-1)
	}
	a.dirty = true
}

// sideKey services one key while the panel is open: arrows move the
// highlight, Enter picks, Delete removes, Escape closes. Any other key is
// reported unhandled so its normal binding still works — the panel is
// docked, not modal.
func (a *app) sideKey(usage uint32) bool {
	if !a.sideOpen {
		return false
	}
	switch usage {
	case keyUp:
		if a.sideSel > 0 {
			a.sideSel--
		}
		a.dirty = true
	case keyDown:
		if a.sideSel < len(a.sideVisible())-1 {
			a.sideSel++
		}
		a.dirty = true
	case keyReturn:
		a.pickBookmark(a.sideSel)
	case 0x4c: // forward-delete removes the highlighted entry
		a.delBookmark(a.sideSel)
	case keyEscape:
		a.sideOpen, a.dirty = false, true
	default:
		return false
	}
	return true
}

// paintSidebar draws the docked panel: a surface plate below the URL row, a
// rule divider on its right edge, a header with the store count and close
// glyph, then one row per atom — selected row rule-filled, the current
// page's row accent-marked, each row's "x" in the delete zone.
func (a *app) paintSidebar(vs virender, clip webrender.Clip, w, h int) {
	ph := h - histMenuY - statusH
	if ph <= 0 {
		return
	}
	vs.Fill(0, histMenuY, sideW, ph, webrender.ColorSurface)
	vs.Fill(sideW-1, histMenuY, 1, ph, webrender.ColorRule)
	webrender.DrawText(vs, 6, histMenuY+4,
		fit("BOOKMARKS "+itoa(len(a.books)), (sideW-24)/8), 1, false, webrender.ColorMuted, clip)
	webrender.DrawText(vs, sideW-sideDelW+3, histMenuY+4, "x", 1, false, webrender.ColorMuted, clip)
	vs.Fill(0, histMenuY+sideHeadH-1, sideW, 1, webrender.ColorRule)
	rows := a.sideVisible()
	if len(rows) == 0 {
		webrender.DrawText(vs, 6, histMenuY+sideHeadH+6,
			"none - Ctrl+D saves", 1, false, webrender.ColorMuted, clip)
		return
	}
	cur := -1
	for i, b := range a.books {
		if b.URL == a.target {
			cur = i
		}
	}
	for i, b := range rows {
		y := histMenuY + sideHeadH + i*sideRowH
		if i == a.sideSel {
			vs.Fill(1, y, sideW-2, sideRowH, webrender.ColorRule)
		}
		if i == cur {
			vs.Fill(0, y, 2, sideRowH, webrender.ColorAccent)
		}
		label := b.Title
		if label == "" {
			label = b.URL
		}
		webrender.DrawText(vs, 8, y+4, fit(label, (sideW-8-sideDelW)/8), 1, false, webrender.ColorChromeInk, clip)
		webrender.DrawText(vs, sideW-sideDelW+3, y+4, "x", 1, false, webrender.ColorMuted, clip)
	}
}
