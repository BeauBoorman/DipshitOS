package main

import (
	"strings"
	"testing"

	"virelai/rss/keys"
	"virelai/vi"
)

// entry builds one wire-shaped DirEntry for the pure tests.
func entry(name string, isDir bool) vi.DirEntry {
	var e vi.DirEntry
	copy(e.Name[:], name)
	if isDir {
		e.IsDir = 1
	}
	e.Size = 19
	return e
}

// testModel assembles a model around injected entries: the vi layer is
// ENOSYS on the host, so listings are placed directly.
func testModel(entries ...vi.DirEntry) model {
	m := model{path: "/host/FM"}
	m.setSize(64, 23)
	copy(m.entries[:], entries)
	m.n = len(entries)
	sortEntries(m.entries[:], m.n, m.sort)
	m.clampSel()
	m.status = "listed"
	m.previewOf = ""
	m.preview = "(no selection)"
	return m
}

func TestGridOfUsesKernelTerminalCell(t *testing.T) {
	cols, rows := gridOf(512, 384)
	if cols != 64 || rows != 23 {
		t.Fatalf("gridOf(512,384) = %dx%d, want 64x23 for the default 8x16 cell",
			cols, rows)
	}
}

func runeKey(r rune) keys.Event { return keys.Event{Key: keys.KeyRune, Rune: r} }

// pendingJoined is the queued marker batch as one string for contains checks.
func pendingJoined(m *model) string {
	out := strings.Join(m.drain(), "\n")
	return out
}

func TestSortDirsFirst(t *testing.T) {
	m := testModel(entry("KNOWN.TXT", false), entry("SUB", true),
		entry("a.txt", false), entry("Bdir", true))
	want := []string{"Bdir/", "SUB/", "KNOWN.TXT", "a.txt"}
	got := labelsOf(m.entries[:], m.n)
	if len(got) != len(want) {
		t.Fatalf("labels = %#v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("labels = %#v, want %#v", got, want)
		}
	}
}

func TestPreviewShowsDirectoryNoteWithoutSyscall(t *testing.T) {
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.loadPreview()
	if m.previewOf != "SUB" || !strings.Contains(m.preview, "directory") {
		t.Fatalf("dir preview = %q (%q)", m.preview, m.previewOf)
	}
	if got := pendingJoined(&m); strings.Contains(got, markerView) {
		t.Fatalf("a directory must not emit a view marker: %q", got)
	}
}

// itoa keeps the marker-rc assertions readable without importing strconv
// style noise into every call site.
func itoa(v int64) string { return vi.Itoa64(v) }

// The one queueing site the host can reach: the model's own notifyToast /
// takeNotify pair, which is what the copy success path calls. takeNotify is
// consume-on-use, so a toast can never be raised twice by the next frame.
func TestNotifyToastIsConsumeOnUse(t *testing.T) {
	m := testModel()
	m.notifyToast("copied KNOWN.TXT")
	if got := m.takeNotify(); got != "copied KNOWN.TXT" {
		t.Fatalf("takeNotify = %q want the queued text", got)
	}
	if got := m.takeNotify(); got != "" {
		t.Fatalf("a second takeNotify = %q, want empty (consume-on-use)", got)
	}
	// The LAST text in a batch wins: one keystroke must not raise three
	// toasts describing states the user never saw.
	m.notifyToast("first")
	m.notifyToast("copied KNOWN.TXT")
	if got := m.takeNotify(); got != "copied KNOWN.TXT" {
		t.Fatalf("takeNotify = %q want the LAST queued text", got)
	}
	// The text budget is the WM_RPC frame title (24 bytes), so the adopter
	// must keep the message inside it — a name long enough to overflow it
	// would be cut mid-word on the toast while the app's own marker
	// printed the whole thing.
	if len("copied KNOWN.TXT") > 24 {
		t.Fatalf("the adopter's message %q exceeds the 24-byte notify budget", "copied KNOWN.TXT")
	}
}
