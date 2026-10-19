// Host pins for the M124d (#2583) context menu: the right-press gesture,
// the submenu's opens= membership, the default mark, and the exec the
// model queues. What is under test is the DECISION — the manifest read
// and the file head ride the same seams the other open tests stub, so the
// menu's contents are pinned without a guest.
package main

import (
	"strings"
	"testing"

	"virelai/rss/keys"
	"virelai/vi"
)

// withApps makes readAppsFile answer `text` (rc = len, the vi.ReadFileAll
// success shape) and restores it afterwards.
func withApps(t *testing.T, text string) {
	t.Helper()
	saved := readAppsFile
	readAppsFile = func(string, int) ([]byte, int64) { return []byte(text), int64(len(text)) }
	t.Cleanup(func() { readAppsFile = saved })
}

// menuAppsTxt is the manifest slice the menu legs exercise: two text
// handlers (GOEDIT is the registry's default for text), an image handler,
// and a subtype-spelling row that only takes its own mime.
const menuAppsTxt = `# test manifest — the image/apps.txt wire shape
NOTE.ELF | Text Editor | n | dock=true | v=2 | opens=text
GOEDIT.ELF | Code Editor | e | dock=true | v=2 | opens=text,binary
GOVIEW.ELF | Image Viewer | v | dock=false | v=2 | opens=image
GOSTALGIA.ELF | Gostalgia | o | dock=false | v=2 | argv=shell --root /host/GS | opens=archive
MDVIEW.ELF | MD Viewer | m | dock=false | v=2 | opens=text/markdown
`

// openMenuAt is the right-press helper: (col,row) are the same 1-based
// SGR cell coords the kernel reports.
func openMenuAt(m *model, x, y int) { m.handleRightClick(x, y) }

func TestRightClickArmsTheMenu(t *testing.T) {
	withApps(t, menuAppsTxt)
	withHead(t, []byte("some plain prose\n"))
	m := testModel(entry("NOTES.TXT", false))
	openMenuAt(&m, 5, 3) // row 0
	if m.mode != modeContext {
		t.Fatalf("right-press must arm the menu, mode=%d", m.mode)
	}
	if m.sel != 0 || m.ctx.name != "NOTES.TXT" {
		t.Fatalf("menu acts on the pressed row: sel=%d name=%q", m.sel, m.ctx.name)
	}
	got := pendingJoined(&m)
	if !strings.Contains(got, markerMenu+"NOTES.TXT mime=text/plain apps=2") {
		t.Fatalf("menu marker = %q", got)
	}
}

func TestOpenWithSubmenuListsManifestHandlers(t *testing.T) {
	withApps(t, menuAppsTxt)
	withHead(t, []byte("some plain prose\n"))
	m := testModel(entry("NOTES.TXT", false))
	openMenuAt(&m, 5, 3)
	m.ctxOpenSub()
	subs := m.ctxSubLabels()
	want := []string{"Text Editor", "Code Editor (default)"}
	if len(subs) != len(want) {
		t.Fatalf("submenu = %v, want %v", subs, want)
	}
	for i := range want {
		if subs[i] != want[i] {
			t.Fatalf("submenu = %v, want %v", subs, want)
		}
	}
	got := pendingJoined(&m)
	if !strings.Contains(got, markerMenuSub+"NOTES.TXT mime=text/plain candidates=2") {
		t.Fatalf("submenu marker = %q", got)
	}
	// The subtype-spelling row must NOT list for a text/plain file.
	for _, l := range subs {
		if strings.Contains(l, "MD Viewer") {
			t.Fatalf("opens=text/markdown must not take text/plain: %v", subs)
		}
	}
}

// A full mouse leg: right-press the row, left-press Open With…, left-press
// the GOEDIT row — the same gestures the class-B gate injects.
func TestMenuMouseLegLaunchesTheChosenApp(t *testing.T) {
	withApps(t, menuAppsTxt)
	withHead(t, []byte("some plain prose\n"))
	m := testModel(entry("NOTES.TXT", false))
	openMenuAt(&m, 5, 3)
	tx, ty, tw, _ := m.ctxTopRect()
	// Press the Open With… row (top index 1), anywhere inside the plate.
	m.handleMenuClick(tx+2+1, ty+1+1)
	if !m.ctx.sub {
		t.Fatalf("Open With… must descend, sub=%v", m.ctx.sub)
	}
	sx, sy, sw, _ := m.ctxSubRect()
	if sw < 1 || sx != tx+tw {
		t.Fatalf("submenu rect hangs off the plate's right edge: %v",
			[4]int{sx, sy, sw, 0})
	}
	// GOEDIT is submenu row 1 — the (default) row.
	m.handleMenuClick(sx+2+1, sy+1+1)
	if m.mode != modeNormal {
		t.Fatalf("choosing must leave the menu, mode=%d", m.mode)
	}
	got := pendingJoined(&m)
	if !strings.Contains(got, markerOpenChose+"NOTES.TXT type=text handler=GOEDIT.ELF") {
		t.Fatalf("chose marker = %q", got)
	}
	r, ok := m.takeLaunch()
	if !ok || r.bin != "GOEDIT.ELF" || r.path != "/host/FM/NOTES.TXT" {
		t.Fatalf("launch = %+v ok=%v; want GOEDIT.ELF on the file", r, ok)
	}
}

// The keyboard leg reaches the same exec: down to Open With…, right
// descends, down picks the second row, enter commits.
func TestMenuKeyboardLegLaunches(t *testing.T) {
	withApps(t, menuAppsTxt)
	withHead(t, []byte("some plain prose\n"))
	m := testModel(entry("NOTES.TXT", false))
	openMenuAt(&m, 5, 3)
	m.handleKey(keys.Event{Key: keys.KeyDown})
	m.handleKey(keys.Event{Key: keys.KeyRight})
	if !m.ctx.sub {
		t.Fatal("Right on Open With… must descend")
	}
	m.handleKey(keys.Event{Key: keys.KeyDown})
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	r, ok := m.takeLaunch()
	if !ok || r.bin != "GOEDIT.ELF" {
		t.Fatalf("keyboard leg launch = %+v ok=%v", r, ok)
	}
}

// The manifest's argv= tail rides ahead of the file on the exec line.
func TestMenuLaunchCarriesArgvTail(t *testing.T) {
	withApps(t, menuAppsTxt)
	withHead(t, []byte("PK\x03\x04zip-body"))
	m := testModel(entry("PACK.ZIP", false))
	openMenuAt(&m, 5, 3)
	m.ctxOpenSub()
	m.ctxChooseSub(0)
	r, ok := m.takeLaunch()
	if !ok || r.bin != "GOSTALGIA.ELF" || r.path != "/host/FM/PACK.ZIP" {
		t.Fatalf("launch = %+v ok=%v", r, ok)
	}
	if len(r.args) != 3 || r.args[0] != "shell" || r.args[1] != "--root" || r.args[2] != "/host/GS" {
		t.Fatalf("argv tail = %v; want the manifest row's argv=", r.args)
	}
}

// A press off the plate dismisses without acting — the click must not
// also open the row it landed on.
func TestMenuDismissedByOutsideClick(t *testing.T) {
	withApps(t, menuAppsTxt)
	withHead(t, []byte("some plain prose\n"))
	m := testModel(entry("NOTES.TXT", false), entry("OTHER.TXT", false))
	openMenuAt(&m, 5, 3)
	m.handleMenuClick(40, 12) // well below the plate, over row 9
	if m.mode != modeNormal {
		t.Fatalf("outside press must dismiss, mode=%d", m.mode)
	}
	got := pendingJoined(&m)
	if !strings.Contains(got, markerMenuClose+"NOTES.TXT") {
		t.Fatalf("dismiss marker = %q", got)
	}
	if _, ok := m.takeLaunch(); ok {
		t.Fatal("a dismiss press must not queue an exec")
	}
}

func TestMenuEscapeDismisses(t *testing.T) {
	withApps(t, menuAppsTxt)
	withHead(t, []byte("some plain prose\n"))
	m := testModel(entry("NOTES.TXT", false))
	openMenuAt(&m, 5, 3)
	m.handleKey(keys.Event{Key: keys.KeyEsc})
	if m.mode != modeNormal {
		t.Fatalf("esc must dismiss, mode=%d", m.mode)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerMenuClose+"NOTES.TXT") {
		t.Fatalf("esc marker = %q", got)
	}
}

// A directory row gets the one-item menu — Open enters it through the
// same gesture Enter would take; no submenu exists.
func TestRightClickOnDirOpensIt(t *testing.T) {
	withApps(t, menuAppsTxt)
	m := testModel(entry("SUB", true), entry("NOTES.TXT", false))
	openMenuAt(&m, 5, 3) // row 0 = SUB
	if labels := m.ctxTopLabels(); len(labels) != 1 || labels[0] != "Open" {
		t.Fatalf("a dir menu is Open only: %v", labels)
	}
	if m.ctxOpenWithRow() != -1 {
		t.Fatal("a dir must have no submenu parent")
	}
	m.ctxActivate(0)
	if m.path != "/host/FM/SUB" {
		t.Fatalf("Open on a dir must enter it: path=%q", m.path)
	}
}

// An empty eligibility set shows the honest row and launches nothing.
func TestMenuNoHandlersShowsTheEmptyRow(t *testing.T) {
	withApps(t, menuAppsTxt)
	withHead(t, []byte("RIFF\x00\x00\x00\x00WAVErest"))
	m := testModel(entry("CLIP.WAV", false))
	openMenuAt(&m, 5, 3)
	m.ctxOpenSub()
	if subs := m.ctxSubLabels(); len(subs) != 1 || subs[0] != "(no handlers)" {
		t.Fatalf("empty submenu = %v; want the (no handlers) row", subs)
	}
	m.ctxChooseSub(0)
	if _, ok := m.takeLaunch(); ok {
		t.Fatal("the (no handlers) row must launch nothing")
	}
}

// An unreadable manifest is an empty catalog, not a crash and not a guess.
func TestMenuUnreadableManifest(t *testing.T) {
	saved := readAppsFile
	readAppsFile = func(string, int) ([]byte, int64) { return nil, -4 }
	t.Cleanup(func() { readAppsFile = saved })
	withHead(t, []byte("some plain prose\n"))
	m := testModel(entry("NOTES.TXT", false))
	openMenuAt(&m, 5, 3)
	if len(m.ctx.apps) != 0 {
		t.Fatalf("unreadable manifest must list no apps: %v", m.ctx.apps)
	}
	got := pendingJoined(&m)
	if !strings.Contains(got, markerMenu+"NOTES.TXT mime=text/plain apps=0") {
		t.Fatalf("menu marker = %q", got)
	}
}

func TestOpensAcceptsRule(t *testing.T) {
	cases := []struct {
		opens []string
		mt    string
		want  bool
	}{
		{[]string{"text"}, "text/plain", true},
		{[]string{"text", "binary"}, "binary", true},
		{[]string{"image"}, "image/png", true},
		{[]string{"text/plain"}, "text/plain", true},
		{[]string{"text/markdown"}, "text/plain", false},
		{[]string{"http", "https"}, "text/plain", false},
		{[]string{"image"}, "application/octet-stream", false},
		{[]string{"text"}, "", false},
		{nil, "text/plain", false},
	}
	for _, c := range cases {
		if got := opensAccepts(c.opens, c.mt); got != c.want {
			t.Errorf("opensAccepts(%v, %q) = %v, want %v", c.opens, c.mt, got, c.want)
		}
	}
}

// The menu's Open on a file is the plain Enter dispatch — the registry
// default, not a second launch path of its own.
func TestMenuOpenIsTheDefaultDispatch(t *testing.T) {
	withApps(t, menuAppsTxt)
	withHead(t, []byte("some plain prose\n"))
	m := testModel(entry("NOTES.TXT", false))
	openMenuAt(&m, 5, 3)
	m.ctxActivate(0) // "Open"
	if m.mode != modeNormal {
		t.Fatalf("Open must close the menu, mode=%d", m.mode)
	}
	r, ok := m.takeLaunch()
	if !ok || r.bin != "GOEDIT.ELF" || r.path != "/host/FM/NOTES.TXT" {
		t.Fatalf("Open launch = %+v ok=%v; want the text default", r, ok)
	}
}

// The overlay is painted in place: CUP-addressed rows over the frame, the
// Open With… row carrying its descend affordance.
func TestMenuOverlayPaintsInPlace(t *testing.T) {
	withApps(t, menuAppsTxt)
	withHead(t, []byte("some plain prose\n"))
	m := testModel(entry("NOTES.TXT", false))
	openMenuAt(&m, 5, 3)
	frame := m.render()
	tx, ty, _, _ := m.ctxTopRect()
	anchor := "\x1b[" + vi.Itoa64(int64(ty+1)) + ";" + vi.Itoa64(int64(tx+1)) + "H"
	if !strings.Contains(frame, anchor) {
		t.Fatalf("frame must CUP the plate's anchor cell %q", anchor)
	}
	if !strings.Contains(frame, "Open With") {
		t.Fatal("the plate must show the Open With… row")
	}
	m.ctxOpenSub()
	frame = m.render()
	if !strings.Contains(frame, "Code Editor (default)") {
		t.Fatal("the submenu must show the marked default")
	}
}
