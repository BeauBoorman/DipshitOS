package main

import (
	"errors"
	"testing"

	"virelai/vi"
)

// view_test.go — M120d (#2561): class-A tests for the windowed face's
// model. The whole state machine — listing, selection, the two-step
// confirm, the focus ring — runs on the host against the same fakeEnv
// seams the argv tests use; only the paint itself stays guest-only.
//
// newSnapView takes a nil TabApp here deliberately: nothing in the
// model path touches the window. (draw()/present() do, and are covered
// by the go-snap spec's windowed leg instead.)

func newTestView() *snapView { return newSnapView(nil) }

func keyEvent(usage uint32, ch byte) vi.Event {
	return vi.Event{Kind: vi.EvKeyDown, Arg0: usage, Arg1: uint32(ch)}
}

func TestViewRefreshListsSortedRows(t *testing.T) {
	f := &fakeEnv{items: []vi.DirItem{
		dirItem("SECOND.vzsave", 64),
		dirItem("FIRST.vzsave", 32),
		dirItem("FIRST.vzsave.part", 8),
	}}
	f.install(t)
	v := newTestView()
	v.refresh()
	if len(v.rows) != 2 || v.rows[0].name != "FIRST" || v.rows[1].name != "SECOND" {
		t.Fatalf("rows = %v", v.rows)
	}
	if len(v.list.Items) != 2 {
		t.Fatalf("items = %v", v.list.Items)
	}
	if !f.has("gosnap: snap name=FIRST bytes=32") || !f.has("gosnap: ls n=2") {
		t.Fatalf("missing ls markers: %v", f.logs)
	}
}

func TestViewRefreshMissingDirIsEmpty(t *testing.T) {
	f := &fakeEnv{listErr: errors.New("ENOENT")}
	f.install(t)
	v := newTestView()
	v.refresh()
	if len(v.rows) != 0 || v.sel != -1 {
		t.Fatalf("rows=%v sel=%d", v.rows, v.sel)
	}
	if !f.has("gosnap: ls n=0") {
		t.Fatalf("missing empty marker: %v", f.logs)
	}
	if _, ok := v.selName(); ok {
		t.Fatal("empty list must not have a selection name")
	}
	if !v.restBtn.Disabled || !v.delBtn.Disabled {
		t.Fatal("row verbs must be disabled with no selection")
	}
}

func TestViewSaveRunsTheVerbAndRelists(t *testing.T) {
	f := &fakeEnv{}
	f.install(t)
	v := newTestView()
	v.field.SetValue("BASE")
	v.save()
	if len(f.ctlCalls) != 1 || f.ctlCalls[0] != "snapshot/BASE" {
		t.Fatalf("ctl calls = %v", f.ctlCalls)
	}
	if !f.has("gosnap: save BASE ok") {
		t.Fatalf("missing save marker: %v", f.logs)
	}
	if v.field.Value() != "" {
		t.Fatalf("field not cleared: %q", v.field.Value())
	}
	// The re-list ran: the ls marker followed the save marker.
	if !f.has("gosnap: ls n=0") {
		t.Fatalf("missing refresh marker: %v", f.logs)
	}
}

func TestViewSaveEmptyFieldIsAHintNotAVerb(t *testing.T) {
	f := &fakeEnv{}
	f.install(t)
	v := newTestView()
	v.save()
	if len(f.ctlCalls) != 0 {
		t.Fatalf("an empty name must never reach the wire: %v", f.ctlCalls)
	}
	if v.status == "" {
		t.Fatal("no status hint for the empty name")
	}
}

func TestViewRestoreNeedsTwoGestures(t *testing.T) {
	f := &fakeEnv{items: []vi.DirItem{dirItem("BASE.vzsave", 64)}}
	f.install(t)
	v := newTestView()
	v.refresh()
	v.sel, v.list.Sel = 0, 0
	// First gesture: the consent ask, the Confirm? face, no wire call.
	v.activate("restore")
	if v.armed != "restore" || v.armedName != "BASE" {
		t.Fatalf("armed=%q %q", v.armed, v.armedName)
	}
	if len(f.ctlCalls) != 0 {
		t.Fatalf("restore ran on the first gesture: %v", f.ctlCalls)
	}
	if !f.has("gosnap: consent restore BASE") {
		t.Fatalf("missing consent marker: %v", f.logs)
	}
	if v.restBtn.Label != "Confirm?" {
		t.Fatalf("armed label = %q", v.restBtn.Label)
	}
	// Second gesture: the verb, the staged marker, disarmed.
	v.activate("restore")
	if len(f.ctlCalls) != 1 || f.ctlCalls[0] != "restore/BASE" {
		t.Fatalf("ctl calls = %v", f.ctlCalls)
	}
	if !f.has("gosnap: restore BASE staged") {
		t.Fatalf("missing staged marker: %v", f.logs)
	}
	if v.armed != "" || v.restBtn.Label != "Restore" {
		t.Fatalf("still armed after confirm: %q %q", v.armed, v.restBtn.Label)
	}
}

func TestViewDeleteNeedsTwoGestures(t *testing.T) {
	f := &fakeEnv{
		items:  []vi.DirItem{dirItem("BASE.vzsave", 64)},
		exists: map[string]bool{"/host/SNAPSHOTS/BASE.vzsave": true},
	}
	f.install(t)
	// Model the delete against the listing too — a faithful share drops
	// the file, so the post-rm refresh sees it gone.
	fileDelete = func(p string) int64 {
		f.deleted = append(f.deleted, p)
		var kept []vi.DirItem
		for _, it := range f.items {
			if snapsDir+"/"+it.Name != p {
				kept = append(kept, it)
			}
		}
		f.items = kept
		return 0
	}
	v := newTestView()
	v.refresh()
	v.sel, v.list.Sel = 0, 0
	v.activate("rm")
	if len(f.deleted) != 0 {
		t.Fatalf("rm ran on the first gesture: %v", f.deleted)
	}
	v.activate("rm")
	if len(f.deleted) != 1 || f.deleted[0] != "/host/SNAPSHOTS/BASE.vzsave" {
		t.Fatalf("deleted = %v", f.deleted)
	}
	if !f.has("gosnap: rm BASE ok") {
		t.Fatalf("missing rm marker: %v", f.logs)
	}
	// The row left the list — the refresh re-read the share.
	if len(v.rows) != 0 || v.sel != -1 {
		t.Fatalf("rows=%v sel=%d after rm", v.rows, v.sel)
	}
}

func TestViewSwitchingRowsDisarms(t *testing.T) {
	f := &fakeEnv{items: []vi.DirItem{
		dirItem("FIRST.vzsave", 32),
		dirItem("SECOND.vzsave", 64),
	}}
	f.install(t)
	v := newTestView()
	v.refresh()
	v.sel, v.list.Sel = 0, 0
	v.activate("restore")
	// A moved selection drops the arm — the confirm named a row.
	v.selTo(1)
	if v.armed != "" {
		t.Fatalf("arm survived a selection change: %q", v.armed)
	}
	if len(f.ctlCalls) != 0 {
		t.Fatalf("a wire verb ran: %v", f.ctlCalls)
	}
}

func TestViewEscapeDisarmsBeforeQuitting(t *testing.T) {
	f := &fakeEnv{items: []vi.DirItem{dirItem("BASE.vzsave", 64)}}
	f.install(t)
	v := newTestView()
	v.refresh()
	v.sel, v.list.Sel = 0, 0
	v.activate("rm")
	if !v.handle(keyEvent(keyEscape, 0)) {
		t.Fatal("Esc did not report a frame change")
	}
	if v.armed != "" {
		t.Fatal("Esc did not disarm")
	}
	if v.quit {
		t.Fatal("the cancel Esc also quit")
	}
	if len(f.deleted) != 0 || len(f.ctlCalls) != 0 {
		t.Fatal("a verb ran without the second gesture")
	}
	// Disarmed, the next Esc is the quit gesture.
	if !v.handle(keyEvent(keyEscape, 0)) || !v.quit {
		t.Fatal("second Esc did not quit")
	}
}

func TestViewArmingADifferentVerbReselects(t *testing.T) {
	f := &fakeEnv{items: []vi.DirItem{dirItem("BASE.vzsave", 64)}}
	f.install(t)
	v := newTestView()
	v.refresh()
	v.sel, v.list.Sel = 0, 0
	v.activate("restore")
	v.activate("rm") // arm switches verbs, still first-gesture
	if v.armed != "rm" {
		t.Fatalf("armed=%q", v.armed)
	}
	if len(f.ctlCalls) != 0 || len(f.deleted) != 0 {
		t.Fatal("a verb ran on a re-arm")
	}
}

func TestViewListKeysAndFocusRing(t *testing.T) {
	f := &fakeEnv{items: []vi.DirItem{
		dirItem("A.vzsave", 1),
		dirItem("B.vzsave", 2),
		dirItem("C.vzsave", 3),
	}}
	f.install(t)
	v := newTestView()
	v.refresh()
	// Up/Down move the list from every focus slot (the field included).
	v.handle(keyEvent(keyDown, 0))
	if v.sel != 0 {
		t.Fatalf("sel=%d", v.sel)
	}
	v.handle(keyEvent(keyDown, 0))
	v.handle(keyEvent(keyDown, 0))
	if v.sel != 2 {
		t.Fatalf("sel=%d", v.sel)
	}
	v.handle(keyEvent(keyDown, 0))
	if v.sel != 2 {
		t.Fatalf("sel ran past the end: %d", v.sel)
	}
	// Tab walks the ring field -> save -> restore -> delete -> list.
	v.handle(keyEvent(keyTab, 0))
	if v.focus != fSave {
		t.Fatalf("focus=%d", v.focus)
	}
	v.handle(keyEvent(keyTab, 0))
	v.handle(keyEvent(keyTab, 0))
	if v.focus != fDel {
		t.Fatalf("focus=%d", v.focus)
	}
	v.handle(keyEvent(keyTab, 0))
	if v.focus != fList {
		t.Fatalf("focus=%d (ring did not wrap)", v.focus)
	}
}

func TestViewPollRepaintsOnlyOnChange(t *testing.T) {
	f := &fakeEnv{items: []vi.DirItem{dirItem("A.vzsave", 1)}}
	f.install(t)
	v := newTestView()
	v.refresh()
	logs := len(f.logs)
	// Same listing: no repaint, no new marker lines.
	if v.poll(v.pollAt + pollNanos) {
		t.Fatal("unchanged listing repainted")
	}
	if len(f.logs) != logs {
		t.Fatalf("unchanged listing printed: %v", f.logs[logs:])
	}
	// A snapshot minted out of band arrives on the next poll.
	f.items = append(f.items, dirItem("MENU-1.vzsave", 9))
	if !v.poll(v.pollAt + pollNanos) {
		t.Fatal("changed listing did not repaint")
	}
	if len(v.rows) != 2 || v.rows[1].name != "MENU-1" {
		t.Fatalf("rows = %v", v.rows)
	}
	if !f.has("gosnap: snap name=MENU-1 bytes=9") {
		t.Fatalf("missing row marker: %v", f.logs)
	}
	// Under the cadence nothing polls early.
	if v.poll(v.pollAt + pollNanos/2) {
		t.Fatal("poll fired early")
	}
}

func TestViewPollChangeDisarms(t *testing.T) {
	f := &fakeEnv{items: []vi.DirItem{dirItem("BASE.vzsave", 64)}}
	f.install(t)
	v := newTestView()
	v.refresh()
	v.sel, v.list.Sel = 0, 0
	v.activate("rm")
	f.items = append(f.items, dirItem("OTHER.vzsave", 1))
	v.poll(v.pollAt + pollNanos)
	if v.armed != "" {
		t.Fatal("a listing change left the arm live")
	}
	if len(f.deleted) != 0 {
		t.Fatal("a verb ran")
	}
}
