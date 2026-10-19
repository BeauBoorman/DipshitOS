package main

import (
	"strings"
	"testing"

	"virelai/appkit"
	"virelai/rss/keys"
	"virelai/vi"
)

// M124b (#2581): the pick-mode face is plain functions — pin the key
// translation, the frame shape, and the picked/cancel receipts without a
// guest syscall.

func TestPickKeyEventMapsNavToHID(t *testing.T) {
	cases := []struct {
		in    keys.Event
		usage uint32
		ch    rune
	}{
		{keys.Event{Key: keys.KeyEnter}, 0x28, '\r'},
		{keys.Event{Key: keys.KeyEsc}, 0x29, 0x1b},
		{keys.Event{Key: keys.KeyCtrlC}, 0x29, 0x1b},
		{keys.Event{Key: keys.KeyUp}, 0x52, 0},
		{keys.Event{Key: keys.KeyDown}, 0x51, 0},
		{keys.Event{Key: keys.KeyBackspace}, 0x2a, 0x7f},
		{keys.Event{Key: keys.KeyHome}, 0x4a, 0},
		{keys.Event{Key: keys.KeyEnd}, 0x4d, 0},
		{keys.Event{Key: keys.KeyPageUp}, 0x4b, 0},
		{keys.Event{Key: keys.KeyPageDown}, 0x4e, 0},
	}
	for _, c := range cases {
		got := pickKeyEvent(c.in)
		if got.Kind != vi.EvKeyDown || got.Arg0 != c.usage {
			t.Fatalf("key %v -> usage %#x want %#x", c.in.Key, got.Arg0, c.usage)
		}
		if c.ch != 0 && got.Arg1 != uint32(c.ch) {
			t.Fatalf("key %v -> ch %#x want %#x", c.in.Key, got.Arg1, c.ch)
		}
	}
	if got := pickKeyEvent(keys.Event{Key: keys.KeyRune, Rune: 'x'}); got.Arg1 != 'x' || got.Arg0 != 0 {
		t.Fatalf("rune key -> usage %#x ch %#x, want usage 0 ch 'x'", got.Arg0, got.Arg1)
	}
}

func TestPickKeyEventCtrlCCancels(t *testing.T) {
	p := appkit.NewFilePicker(appkit.PickOpen, "/host")
	_, done := p.HandleKey(pickKeyEvent(keys.Event{Key: keys.KeyCtrlC}))
	if !done || p.Result != "cancel" {
		t.Fatalf("ctrl-c -> done=%v result=%q, want cancel", done, p.Result)
	}
}

func TestPickFrameShape(t *testing.T) {
	p := appkit.NewFilePicker(appkit.PickOpen, "/host/DOCS")
	// Host stubs empty the directory read; seed rows the way reload()
	// would — the face's job is the frame, not the listing.
	p.Rows = []appkit.PickerRow{
		{Label: "..", Path: "/host", Kind: appkit.PickUp},
		{Label: "DOCS", Path: "/host/DOCS", Kind: appkit.PickDir},
		{Label: "SEED.TXT", Path: "/host/DOCS/SEED.TXT", Kind: appkit.PickFile},
	}
	p.Err = ""
	frame := pickFrame(&p, 72, 20)
	if !strings.HasPrefix(frame, framePrologue) {
		t.Fatal("frame must open with the alt-screen prologue")
	}
	lines := strings.Split(strings.TrimPrefix(frame, framePrologue), "\n")
	if len(lines) != 20 {
		t.Fatalf("frame has %d lines, want 20", len(lines))
	}
	if !strings.Contains(lines[0], "pick: /host/DOCS") {
		t.Fatalf("path bar missing dir: %q", lines[0])
	}
	if !strings.Contains(lines[len(lines)-2], "path:") {
		t.Fatalf("status line missing path field: %q", lines[len(lines)-2])
	}
	if !strings.Contains(lines[len(lines)-1], "enter pick") {
		t.Fatalf("hint line missing: %q", lines[len(lines)-1])
	}
	if !strings.Contains(lines[2], ">") || !strings.Contains(lines[2], colSel) {
		t.Fatalf("selected row missing the plate: %q", lines[2])
	}
}

func TestPickFrameTagsKinds(t *testing.T) {
	p := appkit.NewFilePicker(appkit.PickOpen, "/host")
	p.Rows = []appkit.PickerRow{
		{Label: "..", Path: "/host", Kind: appkit.PickUp},
		{Label: "DOCS", Path: "/host/DOCS", Kind: appkit.PickDir},
		{Label: "SEED.TXT", Path: "/host/SEED.TXT", Kind: appkit.PickRecent},
		{Label: "OLD.TXT", Path: "/host/TRASH/OLD.item", Kind: appkit.PickTrash, TrashID: "0001"},
	}
	p.Err = ""
	frame := pickFrame(&p, 72, 30)
	for _, want := range []string{"up", "dir", "recent", "trash"} {
		if !strings.Contains(frame, want) {
			t.Fatalf("frame missing %q tag:\n%s", want, frame)
		}
	}
}
