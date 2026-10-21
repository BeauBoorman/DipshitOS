package main

import (
	"strings"
	"testing"

	"virelai/rss/keys"
	"virelai/vi"
)

// stubPropsStat pins the M134a mtime seam for one test: the fixture's
// nanosecond stamp is the gate's staged epoch (1700000000 s).
func stubPropsStat(t *testing.T, ok bool) {
	t.Helper()
	prev := statMtime
	statMtime = func(string) (int64, bool) {
		if !ok {
			return 0, false
		}
		return 1_700_000_000_000_000_000, true
	}
	t.Cleanup(func() { statMtime = prev })
}

func TestPropsFileCardMarkerAndRows(t *testing.T) {
	fileBacker(t, map[string][]byte{
		"/host/FM/PROPS.TXT": []byte("props-card-body\n"),
	})
	stubPropsStat(t, true)
	stubMounts(t, false)
	m := testModel(entry("PROPS.TXT", false))
	m.handleKey(runeKey('i'))
	if m.mode != modeProps {
		t.Fatalf("i must open the card: mode=%d", m.mode)
	}
	p := m.props
	if p.kind != "file" || p.path != "/host/FM/PROPS.TXT" || p.size != 19 {
		t.Fatalf("card identity wrong: kind=%q path=%q size=%d", p.kind, p.path, p.size)
	}
	if !p.mtOK || p.mtSec != 1_700_000_000 {
		t.Fatalf("mtime = (%v,%d), want the stat wire's 1700000000", p.mtOK, p.mtSec)
	}
	if p.mimeID != "text" {
		t.Fatalf("mime = %q, want text", p.mimeID)
	}
	if !p.volOK || p.vol != "host" || p.volKind != "share" ||
		p.volSt != "mounted" || p.volAcc != "rw" {
		t.Fatalf("volume = %q %q %q %q ok=%v, want host share mounted rw",
			p.vol, p.volKind, p.volSt, p.volAcc, p.volOK)
	}
	if got := pendingJoined(&m); !strings.Contains(got,
		markerProps+"/host/FM/PROPS.TXT mtime=1700000000 mime=text vol=host") {
		t.Fatalf("open marker missing: %q", got)
	}
	// The render golden: the frame's visible lines, row by row.
	lines := visibleLines(m.render())
	want := []string{
		"  props: PROPS.TXT",
		"  file properties",
		"   name      PROPS.TXT",
		"   path      /host/FM/PROPS.TXT",
		"   kind      file",
		"   size      19 bytes (19 B)",
		"   modified  2023-11-14T22:13:20Z",
		"   mime      text",
		"   volume    host · share · mounted · rw",
		"   created   not available — not on the stat wire",
		"   on disk   not available — not on the stat wire",
		"   vol free  not available — not on the mount wire",
	}
	for i, w := range want {
		if i >= len(lines) || !strings.HasPrefix(strings.TrimRight(lines[i], " "), w) {
			got := ""
			if i < len(lines) {
				got = strings.TrimRight(lines[i], " ")
			}
			t.Fatalf("frame line %d = %q, want %q", i, got, w)
		}
	}
	// Esc closes; the close marker rides the next batch and the list
	// frame is back.
	m.handleKey(keys.Event{Key: keys.KeyEsc})
	if m.mode != modeNormal {
		t.Fatalf("escape must close: mode=%d", m.mode)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerPropsClose) {
		t.Fatalf("close marker missing: %q", got)
	}
	if !strings.Contains(m.render(), " preview: ") {
		t.Fatal("closing must restore the list frame")
	}
}

func TestPropsDirectoryAndVolumeCards(t *testing.T) {
	stubPropsStat(t, false)
	stubMounts(t, false)
	// A directory row: no sniff bytes, the stat still runs (it answers
	// for /host dirs on the wire — here the stubbed absence keeps the
	// honest "—" shape pinned).
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.handleKey(runeKey('i'))
	if m.mode != modeProps || m.props.kind != "directory" {
		t.Fatalf("a directory is still a card: mode=%d kind=%q", m.mode, m.props.kind)
	}
	if m.props.mimeID != "" {
		t.Fatalf("a directory must not carry a sniff word: %q", m.props.mimeID)
	}
	if got := pendingJoined(&m); !strings.Contains(got,
		markerProps+"/host/FM/SUB mtime=none mime=none vol=host") {
		t.Fatalf("dir marker missing: %q", got)
	}
	frame := m.render()
	for _, want := range []string{"kind      directory", "mime      —", "size      —"} {
		if !strings.Contains(frame, want) {
			t.Fatalf("dir card row %q missing", want)
		}
	}
	// A mount-table row IS the volume fact — the card names the row's
	// own kernel words, no second call.
	m.mode = modeNormal
	m.path = volsPath
	var usb vi.DirEntry
	copy(usb.Name[:], "usb1")
	usb.IsDir = 1
	usb.Reserved[0] = vi.MountNotMounted
	usb.Reserved[1] = vi.MountKindFAT32
	usb.Reserved[2] = vi.MountFlagReadOnly
	m.entries[0] = usb
	m.n, m.sel = 1, 0
	m.handleKey(runeKey('i'))
	if m.props.kind != "volume" || !m.props.volOK || m.props.vol != "usb1" {
		t.Fatalf("volume row = kind=%q vol=%q ok=%v", m.props.kind, m.props.vol, m.props.volOK)
	}
	if got := pendingJoined(&m); !strings.Contains(got,
		markerProps+"/usb1 mtime=none mime=none vol=usb1") {
		t.Fatalf("volume marker missing: %q", got)
	}
	if !strings.Contains(m.render(), "volume    usb1 · fat32 · not_mounted") {
		t.Fatal("the volume card must name the row's own state words")
	}
}

func TestPropsNothingSelectedAndPressDismiss(t *testing.T) {
	m := testModel()
	m.handleKey(runeKey('i'))
	if m.mode == modeProps {
		t.Fatal("i on an empty listing must not open the card")
	}
	if got := pendingJoined(&m); strings.Contains(got, markerProps) {
		t.Fatalf("no-selection emitted a props marker: %q", got)
	}
	// A press dismisses the card like every other floating surface —
	// it must not act on the list underneath.
	fileBacker(t, map[string][]byte{"/host/FM/A.TXT": []byte("a\n")})
	m = testModel(entry("A.TXT", false))
	m.handleKey(runeKey('i'))
	if m.mode != modeProps {
		t.Fatal("card did not open")
	}
	m.handleClick(10, 10)
	if m.mode != modeNormal {
		t.Fatalf("a press must dismiss the card: mode=%d", m.mode)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerPropsClose) {
		t.Fatalf("press-dismiss emitted no close marker: %q", got)
	}
}

func TestPropsKeysSwallowWhileOpen(t *testing.T) {
	fileBacker(t, map[string][]byte{"/host/FM/A.TXT": []byte("a\n")})
	m := testModel(entry("A.TXT", false))
	m.handleKey(runeKey('i'))
	// List bindings must not fire under the card.
	m.handleKey(runeKey('j'))
	if m.sel != 0 {
		t.Fatal("j moved the selection under the open card")
	}
	m.handleKey(runeKey('q'))
	if m.quit {
		t.Fatal("q under the card must not quit the app")
	}
	// A second `i` closes — the same chord that raised it.
	m.handleKey(runeKey('i'))
	if m.mode != modeNormal {
		t.Fatalf("second i must close: mode=%d", m.mode)
	}
}

func TestHumanSize(t *testing.T) {
	for _, c := range []struct {
		n    uint64
		want string
	}{
		{0, "0 B"},
		{19, "19 B"},
		{1023, "1023 B"},
		{1024, "1.0 KiB"},
		{1536, "1.5 KiB"},
		{10240, "10 KiB"},
		{262144, "256 KiB"},
		{1572864, "1.5 MiB"},
		{5 << 20, "5.0 MiB"},
		{64 << 20, "64 MiB"},
		{3 << 30, "3.0 GiB"},
	} {
		if got := humanSize(c.n); got != c.want {
			t.Errorf("humanSize(%d) = %q, want %q", c.n, got, c.want)
		}
	}
}

func TestIsoUTC(t *testing.T) {
	if got := isoUTC(1_700_000_000); got != "2023-11-14T22:13:20Z" {
		t.Fatalf("isoUTC(1700000000) = %q", got)
	}
	if got := isoUTC(0); got != "1970-01-01T00:00:00Z" {
		t.Fatalf("isoUTC(0) = %q", got)
	}
}
