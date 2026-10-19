package main

// M124e (#2584): the seat-owned primary selection — publish gating,
// delivery, and the cap's real gate in both directions. The fixture swaps
// the sel seams for a fake /host filesystem and a recorded-notice outbox,
// the dragFixture pattern.

import (
	"strings"
	"testing"

	"virelai/vi"
)

const selManifest = "" +
	"GOEDIT.ELF | Code Editor | e | dock=true | v=2 | opens=text,binary | selection=primary\n" +
	"GOTERM.ELF | Terminal | t | dock=true | v=2 | selection=primary\n" +
	"GOFILES.ELF | Files | f | dock=true | v=2 | caps=file,window\n"

type selFixture struct {
	files   map[string][]byte
	notices []vi.WmRpc
	pids    []uint32
	logs    []string
}

func (f *selFixture) install(t *testing.T) {
	t.Helper()
	f.files = map[string][]byte{}
	oldR, oldW, oldD := selFileRead, selFileWrite, selFileDelete
	oldPost, oldLog := selPost, selLog
	oldTabs, oldBind, oldApps := tabs, rpcBindings, readAppsFile
	oldXY, oldRects := surfaceXY, gpu3dRects
	oldSel, oldSet := primSel, primSelSet
	t.Cleanup(func() {
		selFileRead, selFileWrite, selFileDelete = oldR, oldW, oldD
		selPost, selLog = oldPost, oldLog
		tabs, rpcBindings, readAppsFile = oldTabs, oldBind, oldApps
		surfaceXY, gpu3dRects = oldXY, oldRects
		primSel, primSelSet = oldSel, oldSet
	})
	selFileRead = func(path string, max int) ([]byte, int64) {
		b, ok := f.files[path]
		if !ok {
			return nil, -2
		}
		return append([]byte(nil), b...), int64(len(b))
	}
	selFileWrite = func(path string, b []byte) int64 {
		f.files[path] = append([]byte(nil), b...)
		return 0
	}
	selFileDelete = func(path string) int64 {
		delete(f.files, path)
		return 0
	}
	selPost = func(target uint32, b []byte) int64 {
		if m, ok := vi.DecodeWmRpc(b); ok {
			f.notices = append(f.notices, m)
			f.pids = append(f.pids, target)
		}
		return 0
	}
	selLog = func(s string) { f.logs = append(f.logs, s) }
	readAppsFile = func(path string, max int) ([]byte, int64) {
		return []byte(selManifest), int64(len(selManifest))
	}
	tabs = TabStrip{}
	rpcBindings = [256]rpcBinding{}
	surfaceXY, gpu3dRects = [256]uint32{}, [256]uint32{}
	primSel, primSelSet = nil, false
}

func (f *selFixture) hasLog(sub string) bool {
	for _, l := range f.logs {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

// hostTab puts a bound live tab on the strip under bin with a mirrored
// rect (surfaceXY/gpu3dRects are the drag hit-test's geometry source).
func (f *selFixture) hostTab(id uint32, bin string, x, y, w, h uint32) {
	if !tabs.OpenTab(id, bin+" window") {
		panic("hostTab: OpenTab refused")
	}
	tabs.tabs[tabs.index(id)].Bin = bin
	rpcBindings[id] = rpcBinding{pid: uint8(id), token: 0x5e1}
	surfaceXY[id] = (x & 0xffff) | (y&0xffff)<<16
	gpu3dRects[id] = (w & 0xffff) | (h&0xffff)<<16
}

func (f *selFixture) stage(id uint32, text string) {
	enc, ok := vi.EncodeSel([]byte(text))
	if !ok {
		panic("stage: illegal payload")
	}
	f.files[vi.SelPath(id)] = enc
}

func selReq(id uint32, kind uint8) vi.WmRpc {
	var r vi.WmRpc
	r.Kind = kind
	r.ID = uint8(id)
	r.ReplyTo = uint8(id)
	return r
}

func TestSelPublishStores(t *testing.T) {
	f := &selFixture{}
	f.install(t)
	f.hostTab(5, "GOEDIT.ELF", 0, 22, 640, 698)
	f.stage(5, "the selection")
	if !serveSelPublish(selReq(5, vi.WmRpcKindSelPublish)) {
		t.Fatal("publish refused")
	}
	if !primSelSet || string(primSel) != "the selection" {
		t.Fatalf("buffer = %q set=%v", primSel, primSelSet)
	}
	if _, ok := f.files[vi.SelPath(5)]; ok {
		t.Fatal("staging file not consumed")
	}
	if !f.hasLog("gotabwm: sel pub id=5 len=13") {
		t.Fatalf("missing pub marker: %v", f.logs)
	}
}

func TestSelPublishRefusals(t *testing.T) {
	f := &selFixture{}
	f.install(t)
	f.hostTab(5, "GOEDIT.ELF", 0, 22, 640, 698)
	f.hostTab(6, "GOFILES.ELF", 0, 22, 640, 698) // no selection= cap
	// A cap-less publisher is refused and its staging file is left for
	// the app's own cleanup (the unclaimed-handoff rule).
	f.stage(6, "nope")
	if serveSelPublish(selReq(6, vi.WmRpcKindSelPublish)) {
		t.Fatal("cap-less publish applied")
	}
	if primSelSet {
		t.Fatal("refused publish still stored")
	}
	if _, ok := f.files[vi.SelPath(6)]; !ok {
		t.Fatal("refused publish's stage must survive for the app to clean")
	}
	if !f.hasLog("sel refuse 6 pub cap") {
		t.Fatalf("missing cap refusal: %v", f.logs)
	}
	// A non-tab window and a missing stage refuse by name too.
	if serveSelPublish(selReq(9, vi.WmRpcKindSelPublish)) {
		t.Fatal("non-tab publish applied")
	}
	if !f.hasLog("sel refuse 9 pub notab") {
		t.Fatalf("missing notab refusal: %v", f.logs)
	}
	if serveSelPublish(selReq(5, vi.WmRpcKindSelPublish)) {
		t.Fatal("missing-stage publish applied")
	}
	if !f.hasLog("sel refuse 5 pub missing") {
		t.Fatalf("missing-stage refusal: %v", f.logs)
	}
	// A malformed envelope is consumed and refused bad.
	f.files[vi.SelPath(5)] = []byte{9, 9, 9}
	if serveSelPublish(selReq(5, vi.WmRpcKindSelPublish)) {
		t.Fatal("bad-envelope publish applied")
	}
	if !f.hasLog("sel refuse 5 pub bad") {
		t.Fatalf("missing bad refusal: %v", f.logs)
	}
}

func TestSelDeliversOnMiddleClickAndChord(t *testing.T) {
	f := &selFixture{}
	f.install(t)
	f.hostTab(5, "GOEDIT.ELF", 0, 22, 640, 698)
	f.hostTab(7, "GOTERM.ELF", 640, 22, 640, 698)
	f.stage(5, "cross-app text")
	if !serveSelPublish(selReq(5, vi.WmRpcKindSelPublish)) {
		t.Fatal("publish refused")
	}
	// Middle-click inside GOTERM's pane delivers: stage at ITS rendezvous
	// path, notice to its bound pid, marker after both.
	applySelPasteAt(900, 300)
	if len(f.notices) != 1 || f.notices[0].Kind != vi.WmRpcKindSelPaste ||
		f.notices[0].ID != 7 || f.pids[0] != 7 {
		t.Fatalf("delivery notice = %+v pid=%v", f.notices, f.pids)
	}
	staged, ok := f.files[vi.SelPath(7)]
	if !ok {
		t.Fatal("no staged envelope at the target's path")
	}
	got, ok := vi.DecodeSel(staged)
	if !ok || string(got) != "cross-app text" {
		t.Fatalf("staged payload = %q ok=%v", got, ok)
	}
	if !f.hasLog("gotabwm: sel paste id=7 len=14") {
		t.Fatalf("missing paste marker: %v", f.logs)
	}
	// The chord delivers to the focused tab — focus is GOEDIT (index 0),
	// so shifting focus to GOTERM lands the same delivery there.
	_ = tabs.FocusTab(7)
	delete(f.files, vi.SelPath(7))
	f.notices = f.notices[:0]
	applySelPasteChord()
	if len(f.notices) != 1 || f.notices[0].ID != 7 {
		t.Fatalf("chord delivery = %+v", f.notices)
	}
}

func TestSelDeliveryRefusals(t *testing.T) {
	f := &selFixture{}
	f.install(t)
	f.hostTab(5, "GOEDIT.ELF", 0, 22, 640, 698)
	f.hostTab(6, "GOFILES.ELF", 640, 22, 640, 698)
	f.stage(5, "buf")
	if !serveSelPublish(selReq(5, vi.WmRpcKindSelPublish)) {
		t.Fatal("publish refused")
	}
	// Cap-off target: no stage, no notice, named refusal.
	applySelPasteAt(900, 300)
	if len(f.notices) != 0 || len(f.files) != 0 {
		t.Fatalf("cap-less target was delivered to: notices=%v files=%v", f.notices, f.files)
	}
	if !f.hasLog("sel refuse 6 paste cap") {
		t.Fatalf("missing cap refusal: %v", f.logs)
	}
	// The pull path gates identically: a cap-less requester gets
	// applied=0 and nothing staged.
	if serveSelPaste(selReq(6, vi.WmRpcKindSelPaste)) {
		t.Fatal("cap-less pull applied")
	}
	if serveSelPaste(selReq(5, vi.WmRpcKindSelPaste)) {
		// GOEDIT is cap'd and the buffer is set: the pull stages its copy.
		if _, ok := f.files[vi.SelPath(5)]; !ok {
			t.Fatal("pull staged nothing")
		}
	}
	// An empty buffer refuses the pull too.
	primSelSet = false
	if serveSelPaste(selReq(5, vi.WmRpcKindSelPaste)) {
		t.Fatal("empty-buffer pull applied")
	}
	// No hit under the pointer refuses without touching a window.
	primSelSet = true
	applySelPasteAt(1500, 700) // scanout is 1280 — outside every pane
	if !f.hasLog("sel refuse none paste notab") {
		t.Fatalf("missing no-hit refusal: %v", f.logs)
	}
}

func TestDropSelWindowCleansStage(t *testing.T) {
	f := &selFixture{}
	f.install(t)
	f.files[vi.SelPath(7)] = []byte("leftover")
	dropSelWindow(7)
	if _, ok := f.files[vi.SelPath(7)]; ok {
		t.Fatal("dead window's staging survived")
	}
}
