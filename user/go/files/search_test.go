// Host pins for the M155c (#2931) bounded content search: the ASCII-fold
// matcher, every bound the walk can hit (depth, files, read, hits), the
// Sniff-driven binary skip and its named refusal, the mount-root rule,
// and the results mode's move/open/close contract. The walk reads
// directories and file bodies only through the searchDirList/readHead
// seams, so an in-memory tree pins the whole thing without a guest.
package main

import (
	"strings"
	"testing"

	"virelai/rss/keys"
	"virelai/vi"
)

// szEntry is entry() with an honest size field — the walk's read-trunc
// check compares bytes read against the wire size, so a fake file must
// carry the size its fake body claims.
func szEntry(name string, isDir bool, size int) vi.DirEntry {
	e := entry(name, isDir)
	e.Size = uint32(size)
	return e
}

// fakeTree wires the walk's two seams to an in-memory tree: dirs maps a
// directory path to its wire entries (already the full 16-row window),
// files maps a file path to its body. An unlisted dir reads as a failed
// list (contributes nothing), an unlisted file as an unreadable one.
func fakeTree(t *testing.T, dirs map[string][]vi.DirEntry, files map[string][]byte) {
	t.Helper()
	savedList, savedHead := searchDirList, readHead
	searchDirList = func(path string, buf []vi.DirEntry) (int, int64) {
		ents, ok := dirs[path]
		if !ok {
			return 0, -2
		}
		return copy(buf, ents), 0
	}
	readHead = func(path string, _ int) ([]byte, int64) {
		body, ok := files[path]
		if !ok {
			return nil, -2
		}
		return body, int64(len(body))
	}
	t.Cleanup(func() { searchDirList, readHead = savedList, savedHead })
}

// typeNeedle feeds '/' then the needle's runes then Enter — the whole
// prompt gesture — leaving the model wherever runSearch landed it.
func typeNeedle(m *model, pat string) {
	m.handleKey(runeKey('/'))
	for _, r := range pat {
		m.handleKey(runeKey(r))
	}
	m.handleKey(keys.Event{Key: keys.KeyEnter})
}

func TestFoldMatcher(t *testing.T) {
	pat := []byte("INVOICE")
	if !containsFold([]byte("the invoice is due"), pat) {
		t.Fatal("folded match missed a lower-case hit")
	}
	if !containsFold([]byte("INVOICE"), pat) {
		t.Fatal("folded match missed an exact hit")
	}
	if containsFold([]byte("invoice"), []byte("invoicee")) {
		t.Fatal("a pattern longer than the line matched")
	}
	if containsFold([]byte("invoiced"), pat) == false {
		t.Fatal("substring inside a longer word should match")
	}
	if containsFold([]byte("unrelated"), pat) {
		t.Fatal("non-matching line reported a hit")
	}
	// ASCII-only folding: a non-ASCII byte is itself, no Unicode fold.
	if containsFold([]byte("\xe9nvoice"), pat) {
		t.Fatal("non-ASCII byte folded into the needle")
	}
}

func TestSearchPromptLifecycle(t *testing.T) {
	fakeTree(t, map[string][]vi.DirEntry{"/host/FM": {}}, nil)
	m := testModel(entry("A.TXT", false))
	m.handleKey(runeKey('/'))
	if m.mode != modeSearchInput {
		t.Fatalf("/ did not open the prompt: mode=%d", m.mode)
	}
	m.handleKey(runeKey('a'))
	m.handleKey(keys.Event{Key: keys.KeyBackspace})
	if m.input != "" {
		t.Fatalf("backspace left input=%q", m.input)
	}
	m.handleKey(keys.Event{Key: keys.KeyEsc})
	if m.mode != modeNormal || m.status != "search cancelled" {
		t.Fatalf("esc did not cancel: mode=%d status=%q", m.mode, m.status)
	}
	// An empty needle commits to a cancel, never a match-everything walk.
	m.handleKey(runeKey('/'))
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	if m.mode != modeNormal || m.status != "search cancelled" {
		t.Fatalf("empty needle did not cancel: mode=%d status=%q", m.mode, m.status)
	}
}

func TestSearchWalkHitsAndCounts(t *testing.T) {
	note := "plain\ninvoice for march\nend\n"
	nest := "nested\nsecond invoice line\n"
	dirs := map[string][]vi.DirEntry{
		"/host/FM": {
			szEntry("BINALL", true, 0),
			szEntry("DEEP", true, 0),
			szEntry("NOTE.TXT", false, len(note)),
		},
		"/host/FM/BINALL": {
			szEntry("APP.ELF", false, 64),
			szEntry("PIC.QOI", false, 64),
		},
		"/host/FM/DEEP": {
			szEntry("INVOICE.TXT", false, len(nest)),
		},
	}
	files := map[string][]byte{
		"/host/FM/NOTE.TXT":         []byte(note),
		"/host/FM/DEEP/INVOICE.TXT": []byte(nest),
		"/host/FM/BINALL/APP.ELF":   []byte("\x7fELF\x02\x01\x01\x00" + strings.Repeat("\x00", 56)),
		"/host/FM/BINALL/PIC.QOI":   []byte("qoif\x00\x00\x00\x04\x00\x00\x00\x04\x04\x00"),
	}
	fakeTree(t, dirs, files)

	m := testModel()
	typeNeedle(&m, "invoice")
	if m.mode != modeSearchHits {
		t.Fatalf("search did not land on the results frame: mode=%d", m.mode)
	}
	got := pendingJoined(&m)
	if !strings.Contains(got, "files: search hits=2 scanned=2 skipped=2") {
		t.Fatalf("counts marker missing or wrong: %q", got)
	}
	if !strings.Contains(got, "files: search hit /host/FM/NOTE.TXT:2") {
		t.Fatalf("NOTE.TXT hit marker missing: %q", got)
	}
	if !strings.Contains(got, "files: search hit /host/FM/DEEP/INVOICE.TXT:2") {
		t.Fatalf("nested hit marker missing: %q", got)
	}
	// The result rows carry rel:line: snippet.
	if len(m.search.hits) != 2 {
		t.Fatalf("hits=%d want 2", len(m.search.hits))
	}
	if m.search.hits[0].rel != "NOTE.TXT" || m.search.hits[0].line != 2 ||
		m.search.hits[0].snippet != "invoice for march" {
		t.Fatalf("hit[0] = %+v", m.search.hits[0])
	}
	if m.search.hits[1].rel != "DEEP/INVOICE.TXT" {
		t.Fatalf("hit[1] rel = %q", m.search.hits[1].rel)
	}
}

func TestSearchRefusesAnAllBinaryFolder(t *testing.T) {
	dirs := map[string][]vi.DirEntry{
		"/host/FM": {
			szEntry("APP.ELF", false, 64),
			szEntry("SONG.OGG", false, 64),
		},
	}
	files := map[string][]byte{
		"/host/FM/APP.ELF": []byte("\x7fELF\x02\x01\x01\x00" + strings.Repeat("\x00", 56)),
		"/host/FM/SONG.OGG": []byte("OggS\x00\x02" + strings.Repeat("\x00", 58)),
	}
	fakeTree(t, dirs, files)
	m := testModel()
	typeNeedle(&m, "invoice")
	got := pendingJoined(&m)
	if !strings.Contains(got, "files: search refused binary") {
		t.Fatalf("binary refusal missing: %q", got)
	}
	if m.mode == modeSearchHits {
		t.Fatal("a refused search must not open the results frame")
	}
}

func TestSearchDepthBound(t *testing.T) {
	deep := "hit at depth four\n"
	dirs := map[string][]vi.DirEntry{
		"/host/FM":              {szEntry("D1", true, 0)},
		"/host/FM/D1":           {szEntry("D2", true, 0)},
		"/host/FM/D1/D2":        {szEntry("D3", true, 0)},
		"/host/FM/D1/D2/D3":     {szEntry("D4", true, 0)},
		"/host/FM/D1/D2/D3/D4": {
			szEntry("D5", true, 0),
			szEntry("DEEP.TXT", false, len(deep)),
		},
		"/host/FM/D1/D2/D3/D4/D5": {szEntry("LOST.TXT", false, 8)},
	}
	files := map[string][]byte{
		"/host/FM/D1/D2/D3/D4/DEEP.TXT":    []byte(deep),
		"/host/FM/D1/D2/D3/D4/D5/LOST.TXT": []byte("lost hit\n"),
	}
	fakeTree(t, dirs, files)
	m := testModel()
	typeNeedle(&m, "hit")
	got := pendingJoined(&m)
	// The depth-4 file was scanned before the bound stopped the walk;
	// the depth-5 file is beyond it.
	if !strings.Contains(got, "files: search hits=1 scanned=1 skipped=0 truncated=depth") {
		t.Fatalf("depth bound marker wrong: %q", got)
	}
	if !strings.Contains(got, "files: search hit /host/FM/D1/D2/D3/D4/DEEP.TXT:1") {
		t.Fatalf("depth-4 hit missing: %q", got)
	}
	if strings.Contains(got, "LOST.TXT") {
		t.Fatalf("depth-5 file leaked into the results: %q", got)
	}
}

func TestSearchFilesBound(t *testing.T) {
	dirs := map[string][]vi.DirEntry{"/host/FM": {szEntry("A", true, 0)}}
	files := map[string][]byte{}
	// 16 subdirs x 16 files = 256 files inside A alone, plus one more
	// file at the top level the walk reaches last: the 257th file trips
	// the bound. Top-level files scan first (F0.TXT), then each subdir.
	root := []vi.DirEntry{szEntry("A", true, 0)}
	for i := 0; i < 15; i++ {
		name := "F" + string(rune('A'+i)) + ".TXT"
		root = append(root, szEntry(name, false, 4))
		files["/host/FM/"+name] = []byte("none\n")
	}
	dirs["/host/FM"] = root
	sub := []vi.DirEntry{}
	for d := 0; d < 16; d++ {
		dname := "S" + string(rune('A'+d))
		sub = append(sub, szEntry(dname, true, 0))
		kids := []vi.DirEntry{}
		for f := 0; f < 16; f++ {
			fname := "K" + string(rune('a'+f)) + ".TXT"
			kids = append(kids, szEntry(fname, false, 4))
			files["/host/FM/A/"+dname+"/"+fname] = []byte("none\n")
		}
		dirs["/host/FM/A/"+dname] = kids
	}
	dirs["/host/FM/A"] = sub
	fakeTree(t, dirs, files)
	m := testModel()
	typeNeedle(&m, "needle")
	got := pendingJoined(&m)
	if !strings.Contains(got, "files: search hits=0 scanned=256 skipped=0 truncated=files") {
		t.Fatalf("files bound marker wrong: %q", got)
	}
}

func TestSearchHitsBound(t *testing.T) {
	var body strings.Builder
	for i := 0; i < 70; i++ {
		body.WriteString("needle line\n")
	}
	big := body.String()
	dirs := map[string][]vi.DirEntry{
		"/host/FM": {szEntry("MANY.TXT", false, len(big))},
	}
	fakeTree(t, dirs, map[string][]byte{"/host/FM/MANY.TXT": []byte(big)})
	m := testModel()
	typeNeedle(&m, "needle")
	got := pendingJoined(&m)
	if !strings.Contains(got, "files: search hits=64 scanned=1 skipped=0 truncated=hits") {
		t.Fatalf("hits bound marker wrong: %q", got)
	}
	if len(m.search.hits) != 64 {
		t.Fatalf("hits=%d want the 64 cap", len(m.search.hits))
	}
	if strings.Contains(got, ":65") {
		t.Fatalf("a 65th hit leaked past the cap: %q", got)
	}
}

func TestSearchReadBound(t *testing.T) {
	dirs := map[string][]vi.DirEntry{
		"/host/FM": {szEntry("BIG.TXT", false, 300000)},
	}
	// The read seam hands back fewer bytes than the wire size claims —
	// the cap's honest shape. A second file behind it is never reached.
	fakeTree(t, dirs, map[string][]byte{
		"/host/FM/BIG.TXT": []byte("needle\n" + strings.Repeat("x", 100)),
	})
	m := testModel()
	typeNeedle(&m, "needle")
	got := pendingJoined(&m)
	if !strings.Contains(got, "files: search hits=1 scanned=1 skipped=0 truncated=read") {
		t.Fatalf("read bound marker wrong: %q", got)
	}
}

func TestSearchRootRefusedWhenBoundsFail(t *testing.T) {
	// A mount-root walk that truncates is refused by name: a partial
	// answer to "the whole share" is a lie, not a result set.
	dirs := map[string][]vi.DirEntry{
		"/host":    {szEntry("D1", true, 0)},
		"/host/D1": {szEntry("D2", true, 0)},
		"/host/D1/D2": {szEntry("D3", true, 0)},
		"/host/D1/D2/D3": {szEntry("D4", true, 0)},
		"/host/D1/D2/D3/D4": {szEntry("D5", true, 0)},
	}
	fakeTree(t, dirs, nil)
	m := testModel()
	m.path = "/host"
	typeNeedle(&m, "needle")
	got := pendingJoined(&m)
	if !strings.Contains(got, "files: search refused root") {
		t.Fatalf("root refusal missing: %q", got)
	}
	if m.mode == modeSearchHits {
		t.Fatal("a refused root search must not open the results frame")
	}
}

func TestSearchRootAllowedWhenBoundsHold(t *testing.T) {
	body := "invoice\n"
	dirs := map[string][]vi.DirEntry{
		"/host": {szEntry("ONLY.TXT", false, len(body))},
	}
	fakeTree(t, dirs, map[string][]byte{"/host/ONLY.TXT": []byte(body)})
	m := testModel()
	m.path = "/host"
	typeNeedle(&m, "invoice")
	got := pendingJoined(&m)
	if !strings.Contains(got, "files: search hits=1 scanned=1 skipped=0") {
		t.Fatalf("bounded root search refused: %q", got)
	}
	if strings.Contains(got, "refused") {
		t.Fatalf("bounded root search emitted a refusal: %q", got)
	}
}

func TestSearchRefusedAtVolumesRoot(t *testing.T) {
	m := testModel()
	m.path = volsPath
	m.handleKey(runeKey('/'))
	got := pendingJoined(&m)
	if !strings.Contains(got, "files: search refused root") {
		t.Fatalf("volumes refusal missing: %q", got)
	}
	if m.mode != modeNormal {
		t.Fatalf("volumes search opened a mode: %d", m.mode)
	}
}

func TestSearchHitNavigationAndOpen(t *testing.T) {
	a := "invoice a\n"
	b := "invoice b\n"
	dirs := map[string][]vi.DirEntry{
		"/host/FM": {
			szEntry("A.TXT", false, len(a)),
			szEntry("B.TXT", false, len(b)),
		},
	}
	files := map[string][]byte{
		"/host/FM/A.TXT": []byte(a),
		"/host/FM/B.TXT": []byte(b),
	}
	fakeTree(t, dirs, files)
	m := testModel()
	typeNeedle(&m, "invoice")
	m.drain() // consume the search markers; the open pair is what matters now

	// n walks forward and wraps; N walks back and wraps.
	m.hitsKey(runeKey('n'))
	if m.search.sel != 1 {
		t.Fatalf("n moved to %d, want 1", m.search.sel)
	}
	m.hitsKey(runeKey('n'))
	if m.search.sel != 0 {
		t.Fatalf("n did not wrap to 0: sel=%d", m.search.sel)
	}
	m.hitsKey(runeKey('N'))
	if m.search.sel != 1 {
		t.Fatalf("N did not wrap to the last hit: sel=%d", m.search.sel)
	}

	// Enter dispatches the hit's file through the existing open path.
	m.hitsKey(keys.Event{Key: keys.KeyEnter})
	got := pendingJoined(&m)
	if !strings.Contains(got, "gofiles: open file B.TXT type=text handler=GOEDIT.ELF") {
		t.Fatalf("open dispatch marker wrong: %q", got)
	}
	r, ok := m.takeLaunch()
	if !ok || r.bin != "GOEDIT.ELF" || r.path != "/host/FM/B.TXT" {
		t.Fatalf("launch = %+v ok=%v", r, ok)
	}

	// Esc closes the frame and names it.
	m.hitsKey(keys.Event{Key: keys.KeyEsc})
	if m.mode != modeNormal {
		t.Fatalf("esc did not close: mode=%d", m.mode)
	}
	got = pendingJoined(&m)
	if !strings.Contains(got, "files: search close") {
		t.Fatalf("close marker missing: %q", got)
	}
}

func TestSearchRenderTruncatedRow(t *testing.T) {
	m := testModel()
	m.search = search{
		pat:  "needle",
		root: "/host/FM",
		trunc: "files",
		hits: []searchHit{
			{path: "/host/FM/A.TXT", rel: "A.TXT", line: 2, snippet: "a needle"},
		},
		scanned: 256,
	}
	m.mode = modeSearchHits
	frame := m.renderSearch()
	if !strings.Contains(frame, "A.TXT:2: a needle") {
		t.Fatalf("hit row missing from the frame: %q", frame)
	}
	if !strings.Contains(frame, "truncated at files") {
		t.Fatalf("truncated row missing from the frame: %q", frame)
	}
}
