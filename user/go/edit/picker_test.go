package main

// M124b (#2581): the shared picker's adoption legs — Ctrl-O opens through
// appkit.FilePicker (with a discard guard on a dirty buffer), Ctrl-Shift-S
// is the save-as, and the picker's Result moves the buffer's path.

import (
	"testing"

	"virelai/appkit"
	"virelai/vi"
)

func TestCtrlOOpensTheSharedPicker(t *testing.T) {
	e := &editor{doc: doc{path: "/host/EDIT/SEED.TXT"}}
	e.handleKey(usDown(0x12, modCtrl, 'o'))
	if e.mode != modePicker || !e.pick.Open {
		t.Fatalf("ctrl-o did not open the picker: mode=%d open=%v", e.mode, e.pick.Open)
	}
	if e.pick.Kind != appkit.PickOpen {
		t.Fatalf("picker kind %d", e.pick.Kind)
	}
	if e.pick.Dir != "/host/EDIT" {
		t.Fatalf("picker rooted at %q", e.pick.Dir)
	}
}

func TestPickerCancelHandsBackTheKeyboard(t *testing.T) {
	e := &editor{doc: doc{path: "/host/EDIT/SEED.TXT"}}
	e.handleKey(usDown(0x12, modCtrl, 'o'))
	if !e.handleKey(usDown(0x29, 0, 0x1b)) {
		t.Fatal("escape not consumed")
	}
	if e.mode != modeEdit || e.pick.Result != "cancel" {
		t.Fatalf("after escape mode=%d result=%q", e.mode, e.pick.Result)
	}
	// The document owns keys again — a rune inserts.
	e.key(usDown(0x14, 0, 't'))
	if len(e.buf) == 0 {
		t.Fatal("buffer did not take text after the picker closed")
	}
}

func TestPickerOpenResultLoadsThePickedPath(t *testing.T) {
	read := ""
	old := bufRead
	bufRead = func(p string, max int) ([]byte, int64) {
		read = p
		return []byte("picked-bytes"), int64(len("picked-bytes"))
	}
	t.Cleanup(func() { bufRead = old })
	e := &editor{doc: doc{path: "/host/EDIT/SEED.TXT"}}
	e.handleKey(usDown(0x12, modCtrl, 'o'))
	// A typed path resolves straight through — no listing is needed for the
	// host leg (the share is a guest resource).
	for _, r := range "OTHER.TXT" {
		e.handleKey(usDown(0, 0, uint32(r)))
	}
	e.handleKey(usDown(0x28, 0, '\r'))
	if e.path != "/host/EDIT/OTHER.TXT" {
		t.Fatalf("path %q", e.path)
	}
	if read != e.path || string(e.buf) != "picked-bytes" {
		t.Fatalf("picked load read=%q buf=%q", read, e.buf)
	}
	if e.dirty || e.mode != modeEdit {
		t.Fatalf("post-open state dirty=%v mode=%d", e.dirty, e.mode)
	}
}

func TestPickerSaveAsRepublishesAtThePickedPath(t *testing.T) {
	e := &editor{doc: doc{path: "/host/EDIT/SEED.TXT"}}
	e.handleKey(usDown(0x16, modCtrl|vi.ModShift, 'S'))
	if e.mode != modePicker || e.pick.Kind != appkit.PickSave {
		t.Fatalf("ctrl-shift-s: mode=%d kind=%d", e.mode, e.pick.Kind)
	}
	// The current name is pretyped for the save-as.
	if e.pick.Input != "SEED.TXT" {
		t.Fatalf("save-as input %q", e.pick.Input)
	}
	e.pick.Input = "NEW.TXT"
	e.handleKey(usDown(0x28, 0, '\r'))
	if e.path != "/host/EDIT/NEW.TXT" {
		t.Fatalf("save-as path %q", e.path)
	}
}

func TestPickerOpenOnDirtyAsksFirst(t *testing.T) {
	e := &editor{doc: doc{path: "/host/EDIT/SEED.TXT", dirty: true}}
	e.handleKey(usDown(0x12, modCtrl, 'o'))
	if e.mode != modeDialog {
		t.Fatalf("dirty open did not guard: mode=%d", e.mode)
	}
	// NewConfirm focuses No — Enter refuses, no picker, buffer intact.
	e.handleKey(usDown(0x28, 0, '\r'))
	if e.mode != modeEdit || !e.dirty || e.pickOpenAsk {
		t.Fatalf("after No: mode=%d dirty=%v", e.mode, e.dirty)
	}
	// Ask again, say Yes this time.
	e.handleKey(usDown(0x12, modCtrl, 'o'))
	e.dlg.Focus = 0
	e.handleKey(usDown(0x28, 0, '\r'))
	if e.mode != modePicker {
		t.Fatalf("Yes did not continue into the picker: mode=%d", e.mode)
	}
}

// The picker and the bars never mix: a Ctrl-F under an open picker feeds the
// picker, it does not open the find bar.
func TestPickerOwnsTheKeyboardWhileOpen(t *testing.T) {
	e := &editor{doc: doc{path: "/host/EDIT/SEED.TXT"}}
	e.handleKey(usDown(0x12, modCtrl, 'o'))
	e.handleKey(usDown(0x09, modCtrl, 'f')) // ctrl-f
	if e.mode != modePicker {
		t.Fatalf("ctrl-f stole the keyboard: mode=%d", e.mode)
	}
}
