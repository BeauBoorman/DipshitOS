package main

import (
	"encoding/json"
	"strings"
	"testing"

	"virelai/webrender"
)

// memBookStore is the in-memory bookStoreIO the host tests drive — the
// flint memFS shape (files + dirs), no syscall layer.
type memBookStore struct {
	files    map[string][]byte
	dirs     map[string]bool
	writeErr bool
}

func newMemBookStore() *memBookStore {
	return &memBookStore{files: map[string][]byte{}, dirs: map[string]bool{"/host": true}}
}

func (m *memBookStore) read(p string, max int) ([]byte, bool) {
	b, ok := m.files[p]
	if !ok || len(b) > max {
		return nil, false
	}
	return append([]byte{}, b...), true
}

func (m *memBookStore) write(p string, b []byte) bool {
	if m.writeErr {
		return false
	}
	m.files[p] = append([]byte{}, b...)
	for i := len(p) - 1; i > 0; i-- {
		if p[i] == '/' {
			m.dirs[p[:i]] = true
		}
	}
	return true
}

func (m *memBookStore) mkdir(p string) bool { m.dirs[p] = true; return true }

func (m *memBookStore) exists(p string) bool {
	if _, ok := m.files[p]; ok {
		return true
	}
	return m.dirs[p]
}

// stageBookSeams swaps the store seams for a deterministic memFS + fixed
// clock/rand, restoring them on cleanup.
func stageBookSeams(t *testing.T) *memBookStore {
	t.Helper()
	m := newMemBookStore()
	prevIO, prevNow, prevRand := bookIO, bookNow, bookRand
	bookIO = m
	bookNow = func() int64 { return 1700000000 }
	bookRand = func(b []byte) error {
		for i := range b {
			b[i] = byte(i + 1)
		}
		return nil
	}
	t.Cleanup(func() { bookIO, bookNow, bookRand = prevIO, prevNow, prevRand })
	return m
}

// The store's file shape IS the card: a FLINT stream record, the workspace
// record, and one JSONL atom per bookmark — all under /host/FLINT.
func TestBookmarkStoreIsFlintShaped(t *testing.T) {
	m := stageBookSeams(t)
	a := &app{target: "/host/PAGE.HTML", title: "Page One"}
	ok, added := a.bookmarkToggle()
	if !ok || !added {
		t.Fatal("first toggle did not add")
	}
	for _, p := range []string{bookAtomsPath, bookWSPath} {
		if !m.exists(p) {
			t.Fatalf("store file missing: %s", p)
		}
	}
	if a.bookStream == "" {
		t.Fatal("no stream id bound to the workspace")
	}
	rec, ok := m.files[streamRecordPathFor(a.bookStream)]
	if !ok {
		t.Fatal("stream record missing")
	}
	var st flintStream
	if json.Unmarshal(rec, &st) != nil || st.Name != bookStreamName || st.Head != nil || st.ID != a.bookStream {
		t.Fatalf("stream record wrong: %s", rec)
	}
	var ws flintWorkspace
	if json.Unmarshal(m.files[bookWSPath], &ws) != nil ||
		ws.Name != bookWSName || ws.Src != bookSrcDir || ws.Stream != a.bookStream {
		t.Fatalf("workspace record wrong: %s", m.files[bookWSPath])
	}
	lines := strings.Split(strings.TrimRight(string(m.files[bookAtomsPath]), "\n"), "\n")
	if len(lines) != 1 {
		t.Fatalf("atom rows = %d want 1", len(lines))
	}
	var at flintAtom
	if json.Unmarshal([]byte(lines[0]), &at) != nil {
		t.Fatal("atom line does not parse")
	}
	if at.Kind != "bookmark" || at.Name != "Page One" ||
		at.Metadata["url"] != "/host/PAGE.HTML" || at.Metadata["added"] != "1700000000" {
		t.Fatalf("atom wrong: %+v", at)
	}
	if at.Hash == "" || at.SigHash == "" || at.ID == "" {
		t.Fatal("atom identity fields missing")
	}
	if !m.dirs[bookSrcDir] {
		t.Fatal("declared src root not created")
	}
}

// hash covers content with the name excluded; sig_hash covers the URL —
// re-saving after a title change must move neither.
func TestBookmarkAtomHashRules(t *testing.T) {
	b1 := atomForBookmark(bookmark{ID: "id1", URL: "/host/A", Title: "One", Added: 5})
	b2 := atomForBookmark(bookmark{ID: "id2", URL: "/host/A", Title: "Two", Added: 5})
	b3 := atomForBookmark(bookmark{ID: "id3", URL: "/host/B", Title: "One", Added: 5})
	if b1.Hash != b2.Hash || b1.SigHash != b2.SigHash {
		t.Fatal("a title (name) change moved the hashes")
	}
	if b1.Hash == b3.Hash || b1.SigHash == b3.SigHash {
		t.Fatal("a URL change did not move the hashes")
	}
	if b1.Hash == b1.SigHash {
		t.Fatal("content and signature hashes must differ")
	}
}

// Add, then the same target toggles off — and a reload proves the bytes on
// disk were the truth, not memory.
func TestBookmarkToggleAndReload(t *testing.T) {
	m := stageBookSeams(t)
	a := &app{target: "/host/A.HTML", title: "A"}
	if ok, added := a.bookmarkToggle(); !ok || !added {
		t.Fatal("add failed")
	}
	a.target, a.title = "/host/B.HTML", "B"
	if ok, added := a.bookmarkToggle(); !ok || !added {
		t.Fatal("second add failed")
	}
	b := &app{}
	b.loadBookmarks()
	if len(b.books) != 2 {
		t.Fatalf("reloaded %d bookmarks want 2", len(b.books))
	}
	if b.books[0].Title != "A" || b.books[1].Title != "B" {
		t.Fatalf("reload order = %q,%q (atom sort: name first)", b.books[0].Title, b.books[1].Title)
	}
	b.target = "/host/A.HTML"
	if ok, added := b.bookmarkToggle(); !ok || added {
		t.Fatal("toggle on a stored target should remove")
	}
	c := &app{}
	c.loadBookmarks()
	if len(c.books) != 1 || c.books[0].URL != "/host/B.HTML" {
		t.Fatalf("after remove: %d rows %v", len(c.books), c.books)
	}
	if len(strings.Split(strings.TrimRight(string(m.files[bookAtomsPath]), "\n"), "\n")) != 1 {
		t.Fatal("the atom table still lists the removed row")
	}
}

// A store file that does not end in '\n' or carries a line that will not
// parse refuses closed — never half a list.
func TestBookmarkLoadRefusesTornAndMalformed(t *testing.T) {
	for _, body := range []string{
		`{"id":"x","kind":"bookmark","name":"T","hash":"h","sig_hash":"s","span":{"file":"bookmarks","start":0,"end":0},"metadata":{"url":"/host/A"}}`,
		"not-json\n",
		`{"id":"x","kind":"bookmark","name":"T"}` + "\n",
	} {
		m := stageBookSeams(t)
		m.files[bookAtomsPath] = []byte(body)
		a := &app{}
		a.loadBookmarks()
		if a.booksErr == "" || len(a.books) != 0 {
			t.Fatalf("corrupt store %q loaded: err=%q books=%v", body, a.booksErr, a.books)
		}
	}
}

// The retired WEB-BOOKMARKS.TXT ledger folds into atoms once, on upgrade.
func TestBookmarkLegacyMigration(t *testing.T) {
	m := stageBookSeams(t)
	m.files[bookmarkPath] = []byte(bookmarkSchema + "\n" +
		"1700000001\t/host/OLD.HTML\tLegacy Page\n" +
		"bad-row-no-tabs\n" +
		"1700000002\t/host/OLDER.HTML\t\n")
	a := &app{}
	a.loadBookmarks()
	if len(a.books) != 2 || a.booksMigrated != 2 {
		t.Fatalf("migration = %d rows migrated=%d", len(a.books), a.booksMigrated)
	}
	if a.books[0].URL != "/host/OLD.HTML" && a.books[1].URL != "/host/OLD.HTML" {
		t.Fatalf("migrated rows: %+v", a.books)
	}
	if !m.exists(bookAtomsPath) {
		t.Fatal("migration did not publish the atom table")
	}
	// A second load reads the atoms, not the legacy file.
	b := &app{}
	b.loadBookmarks()
	if len(b.books) != 2 || b.booksMigrated != 0 {
		t.Fatalf("second load re-migrated: books=%d migrated=%d", len(b.books), b.booksMigrated)
	}
}

// The panel's geometry: it hangs under the URL row, its rows fit the
// window, and a point maps to (row, delete-zone).
func TestSidebarGeometry(t *testing.T) {
	a := &app{}
	for i := 0; i < 3; i++ {
		a.books = append(a.books, bookmark{ID: itoa(i), URL: "/host/B" + itoa(i)})
	}
	if got := a.sideRows(); got != (winH-statusH-histMenuY-sideHeadH)/sideRowH {
		t.Fatalf("visible rows = %d", got)
	}
	if histMenuY+sideHeadH+a.sideRows()*sideRowH > winH-statusH {
		t.Fatal("a full panel overlaps the status line")
	}
	if i, del, ok := a.sideHit(8, histMenuY+sideHeadH); !ok || i != 0 || del {
		t.Fatalf("first row hit = %d del=%v ok=%v", i, del, ok)
	}
	if i, del, ok := a.sideHit(8, histMenuY+sideHeadH+2*sideRowH+1); !ok || i != 2 || del {
		t.Fatalf("third row hit = %d del=%v", i, del)
	}
	if _, del, ok := a.sideHit(sideW-2, histMenuY+sideHeadH); !ok || !del {
		t.Fatal("the delete zone did not hit")
	}
	if _, _, ok := a.sideHit(sideW+1, histMenuY+sideHeadH); ok {
		t.Fatal("right of the panel hit a row")
	}
	if _, _, ok := a.sideHit(8, histMenuY+sideHeadH-1); ok {
		t.Fatal("the header hit a row")
	}
	if !a.sideCloseHit(sideW-2, histMenuY+2) || a.sideCloseHit(8, histMenuY+2) {
		t.Fatal("header close hit wrong")
	}
}

// Keys while the panel is open: arrows move, Enter picks, Delete removes,
// Escape closes, other keys pass through.
func TestSidebarKeys(t *testing.T) {
	m := stageBookSeams(t)
	a := &app{sideOpen: true}
	a.books = []bookmark{
		{ID: "a", URL: "/host/A.HTML", Title: "A"},
		{ID: "b", URL: "/host/B.HTML", Title: "B"},
	}
	if !a.sideKey(keyDown) || a.sideSel != 1 {
		t.Fatal("Down did not move the highlight")
	}
	if !a.sideKey(keyUp) || a.sideSel != 0 {
		t.Fatal("Up did not move the highlight back")
	}
	a.sideKey(0x4c) // delete row 0
	if len(a.books) != 1 || a.books[0].ID != "b" {
		t.Fatalf("delete left %+v", a.books)
	}
	if !m.exists(bookAtomsPath) {
		t.Fatal("delete did not publish")
	}
	if !a.sideKey(keyEscape) || a.sideOpen {
		t.Fatal("Escape did not close the panel")
	}
	a.sideOpen = true
	if a.sideKey(keyR) {
		t.Fatal("an unrelated key was swallowed")
	}
	if !a.sideOpen {
		t.Fatal("an unrelated key dismissed the docked panel")
	}
}

// A pick navigates: it is a fresh visit, and the panel stays docked.
func TestSidebarPickNavigates(t *testing.T) {
	a := &app{hist: newHistory(), text: webrender.Bitmap{}, sideOpen: true}
	a.books = []bookmark{{ID: "a", URL: "/host/A.HTML", Title: "A"}}
	a.pickBookmark(0)
	if a.target != "/host/A.HTML" {
		t.Fatalf("pick navigated to %q", a.target)
	}
	if !a.sideOpen {
		t.Fatal("a pick closed the docked panel")
	}
	cur, ok := a.hist.current()
	if !ok || cur.Target != "/host/A.HTML" {
		t.Fatal("the pick was not recorded as a visit")
	}
}

// The open panel paints a plate, a header, a rule-filled selected row, row
// ink, and the delete glyph — pinned on the host pixel path.
func TestSidebarPaintsRows(t *testing.T) {
	a := &app{sideOpen: true}
	a.books = []bookmark{
		{ID: "a", URL: "/host/A", Title: "Alpha"},
		{ID: "b", URL: "/host/B", Title: "Beta"},
	}
	a.target = "/host/B" // the current-page accent row
	pix := make([]uint32, winW*winH)
	vs := virender{pix: pix, w: winW, h: winH}
	a.paintSidebar(vs, webrender.Clip{W: winW, H: winH}, winW, winH)
	at := func(x, y int) uint32 { return pix[y*winW+x] & 0xffffff }
	if at(80, histMenuY+sideHeadH+2*sideRowH+8) != webrender.ColorSurface {
		t.Fatal("panel plate did not paint")
	}
	if at(80, histMenuY+sideHeadH+8) != webrender.ColorRule {
		t.Fatal("selected row fill missing")
	}
	if at(0, histMenuY+sideHeadH+sideRowH+8) != webrender.ColorAccent {
		t.Fatal("current-page accent bar missing")
	}
	if at(sideW-1, histMenuY+100) != webrender.ColorRule {
		t.Fatal("panel divider missing")
	}
	ink := 0
	for y := histMenuY + sideHeadH; y < histMenuY+sideHeadH+2*sideRowH; y++ {
		for x := 8; x < sideW-sideDelW; x++ {
			if at(x, y) == webrender.ColorChromeInk {
				ink++
			}
		}
	}
	if ink < 20 {
		t.Fatalf("no row text painted: %d", ink)
	}
}

// The serial markers are the live gate's grep targets: pin the exact bytes.
func TestBookmarkMarkerConstants(t *testing.T) {
	want := map[string]string{
		markerBookmark: "web: bookmark ",
		markerBmStore:  "web: bookmark-store ",
		markerBmOpen:   "web: bookmarks n=",
		markerBmRow:    "web: bookmarks ",
		markerBmPick:   "web: bookmark pick ",
		markerBmErr:    "web: bookmark error",
	}
	for got, expect := range want {
		if got != expect {
			t.Fatalf("marker %q != %q", got, expect)
		}
	}
}
