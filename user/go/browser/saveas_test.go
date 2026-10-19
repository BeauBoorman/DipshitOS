package main

import (
	"testing"

	"virelai/vi"
)

// M124b (#2581): the save-as modal is plain state — pin the chord, the
// modal's keyboard ownership, the seeded name, and the cancel/refusal legs
// without a guest syscall (writeFileAll is a host stub, so the success leg
// proves itself on the live gate).

func TestSaveAsChordOpensPicker(t *testing.T) {
	a := &app{target: "/host/PAGE.HTML", title: "P"}
	a.key(keyS, vi.ModCtrl|vi.ModShift)
	if !a.pick.open {
		t.Fatal("ctrl+shift+s did not open the picker")
	}
	if a.pick.p.Input != "PAGE.HTML" {
		t.Fatalf("input seeded %q, want PAGE.HTML", a.pick.p.Input)
	}
}

func TestSaveAsModalOwnsKeys(t *testing.T) {
	a := &app{}
	a.openSavePicker()
	// 'q' would quit the app outside the modal; inside it edits the input.
	a.keyEvent(vi.Event{Kind: vi.EvKeyDown, Arg1: 'q'})
	if a.quit {
		t.Fatal("modal leaked a key to the app's quit chord")
	}
	if a.pick.p.Input != "q" {
		t.Fatalf("modal did not take the rune, input=%q", a.pick.p.Input)
	}
}

func TestSaveAsEscapeCancels(t *testing.T) {
	a := &app{}
	a.openSavePicker()
	a.keyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: 0x29, Arg1: 0x1b})
	if a.pick.open {
		t.Fatal("escape did not close the picker")
	}
}

func TestSaveAsResultFeedsSaveLeg(t *testing.T) {
	a := &app{target: "/host/PAGE.HTML"}
	a.openSavePicker()
	a.pick.p.Result = "/host/OUT.HTML"
	a.finishPick()
	if a.pick.open {
		t.Fatal("finish left the modal open")
	}
	// The host write stub refuses; the refusal status is the pinned leg —
	// the live gate observes the write+ledger success.
	if a.status != "save refused" {
		t.Fatalf("status=%q, want the refusal word", a.status)
	}
}
