package main

// favs_test.go — M167b (#2992): the `b` pin toggle and its bound, the
// FILES.FAV store's parse and publish seam (a failed write raises the
// shared banner and keeps the list), the `f` pseudo-listing's missing
// row, and the argv contract — absolute-only start paths, `pick`, and
// the `--search <q>` hand-off's bound.

import (
	"strings"
	"testing"

	"virelai/vi"
)

// stubFavRead stages the store read: rc < 0 is the missing file.
func stubFavRead(t *testing.T, body []byte, rc int64) {
	t.Helper()
	saved := favRead
	favRead = func(path string, max int) ([]byte, int64) {
		if path != favStore {
			t.Fatalf("favRead(%q) — the store is %q", path, favStore)
		}
		return body, rc
	}
	t.Cleanup(func() { favRead = saved })
}

// stubFavWrite stages the publish seam and returns the written bodies.
func stubFavWrite(t *testing.T, rc int64) *[]string {
	t.Helper()
	var got []string
	saved := favWrite
	favWrite = func(path string, b []byte) int64 {
		if path != favStore {
			t.Fatalf("favWrite(%q) — the store is %q", path, favStore)
		}
		got = append(got, string(b))
		return rc
	}
	t.Cleanup(func() { favWrite = saved })
	return &got
}

// stubFavDirs makes the missing probe answer "lists" for exactly the
// paths in live.
func stubFavDirs(t *testing.T, live ...string) {
	t.Helper()
	set := map[string]bool{}
	for _, p := range live {
		set[p] = true
	}
	saved := favDirProbe
	favDirProbe = func(path string) int64 {
		if set[path] {
			return 0
		}
		return -vi.ErrENOENT
	}
	t.Cleanup(func() { favDirProbe = saved })
}

func stubArgs(t *testing.T, argv ...string) {
	t.Helper()
	saved := argsOf
	argsOf = func() []string { return argv }
	t.Cleanup(func() { argsOf = saved })
}

func TestFavTogglePinsDirRowAndCwd(t *testing.T) {
	wrote := stubFavWrite(t, 0)
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	// sel=0 is the dir row: `b` pins the row itself.
	m.handleKey(runeKey('b'))
	if len(m.favs) != 1 || m.favs[0] != "/host/FM/SUB" {
		t.Fatalf("favs = %#v, want [/host/FM/SUB]", m.favs)
	}
	if got := pendingJoined(&m); !strings.Contains(got, "gofiles: fav add /host/FM/SUB n=1") {
		t.Fatalf("add marker missing: %q", got)
	}
	// sel=1 is a file row: `b` pins the cwd.
	m.sel = 1
	m.toggleFav()
	if len(m.favs) != 2 || m.favs[1] != "/host/FM" {
		t.Fatalf("favs = %#v, want [.. /host/FM]", m.favs)
	}
	// The file row's cwd is now pinned: `b` again unpins it.
	m.toggleFav()
	if len(m.favs) != 1 || m.favs[0] != "/host/FM/SUB" {
		t.Fatalf("after unpin favs = %#v", m.favs)
	}
	if got := pendingJoined(&m); !strings.Contains(got, "gofiles: fav del /host/FM n=1") {
		t.Fatalf("del marker missing: %q", got)
	}
	if len(*wrote) != 3 || (*wrote)[2] != "/host/FM/SUB\n" {
		t.Fatalf("writes = %#v", *wrote)
	}
}

func TestFavBoundRefusesByName(t *testing.T) {
	wrote := stubFavWrite(t, 0)
	m := testModel(entry("SUB", true))
	for i := 0; i < favMax; i++ {
		m.favs = append(m.favs, "/host/P"+string(rune('A'+i)))
	}
	m.toggleFav()
	if len(m.favs) != favMax {
		t.Fatalf("a refused pin still landed: %#v", m.favs)
	}
	if got := pendingJoined(&m); !strings.Contains(got, "gofiles: fav refused /host/FM/SUB full") {
		t.Fatalf("bound refusal missing: %q", got)
	}
	if len(*wrote) != 0 {
		t.Fatalf("a refused pin published: %#v", *wrote)
	}
}

func TestFavStoreParseSkipsMalformedAndDupes(t *testing.T) {
	stubFavRead(t, []byte("relative/path\n/host/OK\n\n/host/OK\n/host/DUP/\n"+
		"/"+strings.Repeat("A", maxPath)+"\n/host/DISK\n"), 0)
	m := testModel()
	m.loadFavs()
	if len(m.favs) != 2 || m.favs[0] != "/host/OK" || m.favs[1] != "/host/DISK" {
		t.Fatalf("favs = %#v", m.favs)
	}
	if got := pendingJoined(&m); !strings.Contains(got, "gofiles: favs loaded n=2 bad=4") {
		t.Fatalf("load marker missing: %q", got)
	}
}

func TestFavStoreMissingMeansNoPins(t *testing.T) {
	stubFavRead(t, nil, -vi.ErrENOENT)
	m := testModel()
	m.loadFavs()
	if len(m.favs) != 0 {
		t.Fatalf("missing file yielded pins: %#v", m.favs)
	}
	if got := pendingJoined(&m); !strings.Contains(got, "gofiles: favs loaded n=0 absent") {
		t.Fatalf("absent marker missing: %q", got)
	}
}

func TestFavWriteFailureRaisesBannerAndKeepsList(t *testing.T) {
	stubFavWrite(t, -vi.ErrEAGAIN)
	m := testModel(entry("SUB", true))
	m.toggleFav()
	if len(m.favs) != 1 {
		t.Fatal("a failed publish must keep the in-memory pin")
	}
	if !m.banner.Open {
		t.Fatal("a failed publish must raise the shared error banner")
	}
	if got := pendingJoined(&m); !strings.Contains(got, "gofiles: banner favorites write failed rc=-11") {
		t.Fatalf("banner marker missing: %q", got)
	}
}

func TestFavsListingMissingPinOpensNothing(t *testing.T) {
	stubFavDirs(t, "/host/FM")
	m := testModel()
	m.favs = []string{"/host/FM", "/host/GONE"}
	m.showFavs()
	if m.path != favsView {
		t.Fatalf("f left path = %q", m.path)
	}
	got := pendingJoined(&m)
	for _, want := range []string{
		"gofiles: favs n=2 missing=1",
		"gofiles: entry FM dir",
		"gofiles: entry GONE missing",
		"gofiles: fav /host/FM\n",
		"gofiles: fav /host/GONE missing",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("favs listing missing %q in:\n%s", want, got)
		}
	}
	// The live pin opens its directory.
	m.sel = 0
	m.openSel()
	if m.path != "/host/FM" {
		t.Fatalf("enter live pin = %q", m.path)
	}
	// The gone pin opens nothing and says missing.
	m.path = favsView
	m.refreshFavs()
	m.sel = 1
	m.openSel()
	if m.path != favsView {
		t.Fatalf("a missing pin navigated to %q", m.path)
	}
	if got := pendingJoined(&m); !strings.Contains(got, "gofiles: fav refused /host/GONE missing") {
		t.Fatalf("missing refusal missing: %q", got)
	}
}

func TestFavBOnFavsRowUnpins(t *testing.T) {
	stubFavWrite(t, 0)
	stubFavDirs(t, "/host/FM", "/host/KEEP")
	m := testModel()
	m.favs = []string{"/host/FM", "/host/KEEP"}
	m.showFavs()
	m.sel = 1
	m.handleKey(runeKey('b'))
	if len(m.favs) != 1 || m.favs[0] != "/host/FM" {
		t.Fatalf("b on a favs row must unpin it: %#v", m.favs)
	}
	if got := pendingJoined(&m); !strings.Contains(got, "gofiles: fav del /host/KEEP n=1") {
		t.Fatalf("del marker missing: %q", got)
	}
	if m.n != 1 {
		t.Fatalf("listing did not re-list after unpin: n=%d", m.n)
	}
}

func TestFavRefusedOnVolumesRoot(t *testing.T) {
	stubMounts(t, false)
	m := testModel()
	m.showVolumes()
	m.handleKey(runeKey('b'))
	if len(m.favs) != 0 {
		t.Fatalf("a volumes row pinned: %#v", m.favs)
	}
	if got := pendingJoined(&m); !strings.Contains(got, "gofiles: fav refused / volumes") {
		t.Fatalf("volumes refusal missing: %q", got)
	}
}

func TestSearchRefusedOnFavsView(t *testing.T) {
	stubFavDirs(t, "/host/FM")
	m := testModel()
	m.favs = []string{"/host/FM"}
	m.showFavs()
	m.startSearch()
	if m.mode != modeNormal {
		t.Fatalf("search armed over the pins: mode=%d", m.mode)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerSearchNo+"favs") {
		t.Fatalf("favs refusal missing: %q", got)
	}
	// The argv path's own door: runSearch on the mount-table root
	// refuses by the same name the '/' prompt gives.
	m.path = volsPath
	m.runSearch("x")
	if got := pendingJoined(&m); !strings.Contains(got, markerSearchNo+"root") {
		t.Fatalf("root refusal missing: %q", got)
	}
}

func TestStartArgs(t *testing.T) {
	long := strings.Repeat("q", maxSearchArg+1)
	cases := []struct {
		name     string
		argv     []string
		dir      string
		search   bool
		query    string
		searchNo string
	}{
		{"bare", []string{"GOFILES.ELF"}, rootPath, false, "", ""},
		{"absolute dir", []string{"GOFILES.ELF", "/host/FM"}, "/host/FM", false, "", ""},
		{"relative is not a dir", []string{"GOFILES.ELF", "FM"}, rootPath, false, "", ""},
		{"pick verb + path", []string{"GOFILES.ELF", "pick", "/host/FM8"}, "/host/FM8", false, "", ""},
		{"search alone", []string{"GOFILES.ELF", "--search", "invoice"},
			rootPath, true, "invoice", ""},
		{"dir + search", []string{"GOFILES.ELF", "/host/FM", "--search", "invoice"},
			"/host/FM", true, "invoice", ""},
		{"--search=q form", []string{"GOFILES.ELF", "--search=invoice"},
			rootPath, true, "invoice", ""},
		{"query may start with /", []string{"GOFILES.ELF", "--search", "/host"},
			rootPath, true, "/host", ""},
		{"query over the bound", []string{"GOFILES.ELF", "--search", long},
			rootPath, true, "", "long"},
		{"--search= over the bound", []string{"GOFILES.ELF", "--search=" + long},
			rootPath, true, "", "long"},
		{"flag without a query", []string{"GOFILES.ELF", "--search"},
			rootPath, true, "", "empty"},
		{"--search= empty", []string{"GOFILES.ELF", "--search="},
			rootPath, true, "", "empty"},
		{"flag word is not a dir", []string{"GOFILES.ELF", "--pick"}, rootPath, false, "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			stubArgs(t, c.argv...)
			got := startArgs()
			if got.dir != c.dir || got.search != c.search ||
				got.query != c.query || got.searchNo != c.searchNo {
				t.Fatalf("startArgs(%v) = %+v", c.argv, got)
			}
			if startPath() != c.dir {
				t.Fatalf("startPath = %q, want %q", startPath(), c.dir)
			}
		})
	}
}
