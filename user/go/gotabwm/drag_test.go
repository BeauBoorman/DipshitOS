package main

// M124a (#2580): the guest drag-and-drop protocol's seat half. The seams
// stand in for the staged share file and the mailbox notices — the same
// indirection pattern as stateFixture. The acceptance leg: a drag armed
// by GOFILES carrying text/plain lands on GOEDIT (opens=text), and
// image/png lands on GOVIEW (opens=image), while a refusing target takes
// nothing.

import (
	"bytes"
	"strings"
	"testing"

	"virelai/hostint"
	"virelai/vi"
)

// dragFixture swaps the drag seams for a fake /host filesystem and a
// recorded-notice outbox, restoring every touched global on cleanup.
type dragFixture struct {
	files   map[string][]byte
	deleted []string
	notices []vi.WmRpc
	pids    []uint32 // the mailbox each notice was posted to
	logs    []string
}

const dragManifest = "" +
	"GOEDIT.ELF | Code Editor | e | dock=true | v=2 | opens=text,binary\n" +
	"GOVIEW.ELF | Image Viewer | v | dock=false | v=2 | opens=image\n" +
	"GOFILES.ELF | Files | f | dock=true | v=2 | caps=file,window\n"

func (f *dragFixture) install(t *testing.T) {
	t.Helper()
	f.files = map[string][]byte{}
	oldRead, oldWrite, oldDel := dragFileRead, dragFileWrite, dragFileDelete
	oldOutW, oldOutD, oldOutE := dragOutWrite, dragOutDelete, dragOutExists
	oldPost, oldLog := dragPost, dragLog
	oldTabs := tabs
	oldBind := rpcBindings
	oldApps := readAppsFile
	oldXY, oldRects := surfaceXY, gpu3dRects
	oldDrag := drag
	t.Cleanup(func() {
		dragFileRead, dragFileWrite, dragFileDelete = oldRead, oldWrite, oldDel
		dragOutWrite, dragOutDelete, dragOutExists = oldOutW, oldOutD, oldOutE
		dragPost, dragLog = oldPost, oldLog
		tabs = oldTabs
		rpcBindings = oldBind
		readAppsFile = oldApps
		surfaceXY, gpu3dRects = oldXY, oldRects
		drag = oldDrag
	})
	dragFileRead = func(path string, max int) ([]byte, int64) {
		b, ok := f.files[path]
		if !ok {
			return nil, -2 // -ENOENT
		}
		return append([]byte(nil), b...), int64(len(b))
	}
	dragFileWrite = func(path string, data []byte) int64 {
		f.files[path] = append([]byte(nil), data...)
		return 0
	}
	dragFileDelete = func(path string) int64 {
		if _, ok := f.files[path]; ok {
			delete(f.files, path)
			f.deleted = append(f.deleted, path)
			return 0
		}
		return -2
	}
	dragOutWrite = func(path string, b []byte) int64 {
		f.files[path] = append([]byte(nil), b...)
		return 0
	}
	dragOutDelete = func(path string) int64 {
		if _, ok := f.files[path]; ok {
			delete(f.files, path)
			return 0
		}
		return -vi.ErrENOENT
	}
	dragOutExists = func(path string) bool {
		_, ok := f.files[path]
		return ok
	}
	dragPost = func(target uint32, b []byte) int64 {
		if m, ok := vi.DecodeWmRpc(b); ok {
			f.notices = append(f.notices, m)
			f.pids = append(f.pids, target)
		}
		return 0
	}
	dragLog = func(s string) { f.logs = append(f.logs, s) }
	readAppsFile = func(path string, max int) ([]byte, int64) {
		return []byte(dragManifest), int64(len(dragManifest))
	}
	tabs = TabStrip{}
	rpcBindings = [256]rpcBinding{}
	surfaceXY, gpu3dRects = [256]uint32{}, [256]uint32{}
	drag = dragSession{}
}

func (f *dragFixture) hasLog(sub string) bool {
	for _, l := range f.logs {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

// stage puts a valid envelope at id's rendezvous path — the bytes a
// source publishes before posting kind-22.
func (f *dragFixture) stage(id uint32, mime string, blob []byte) {
	enc, ok := vi.EncodeDrag(mime, blob)
	if !ok {
		panic("stage: illegal payload")
	}
	f.files[vi.DragPath(id)] = enc
}

// hostTab puts a live tab on the strip under bin with a mirrored rect —
// surfaceXY carries x|y<<16, gpu3dRects w|h<<16 (the kind-20 pair).
func (f *dragFixture) hostTab(id uint32, bin string, x, y, w, h uint32) {
	if !tabs.OpenTab(id, bin+" window") {
		panic("hostTab: OpenTab refused")
	}
	tabs.tabs[tabs.index(id)].Bin = bin
	surfaceXY[id] = (x & 0xffff) | (y&0xffff)<<16
	gpu3dRects[id] = (w & 0xffff) | (h&0xffff)<<16
}

func dragBeginReq(id uint32, mime string) vi.WmRpc {
	var r vi.WmRpc
	r.Kind = vi.WmRpcKindDragBegin
	r.ID = uint8(id)
	r.ReplyTo = 21
	r.SetTitle(mime)
	return r
}

func dragCancelReq(id uint32) vi.WmRpc {
	var r vi.WmRpc
	r.Kind = vi.WmRpcKindDragCancel
	r.ID = uint8(id)
	r.ReplyTo = 21
	return r
}

// The acceptance leg, end to end: GOFILES arms text/plain, the pointer
// hovers GOEDIT's rect (opens=text accepts the subtype), the release
// republishes the envelope under the target's own rendezvous path and
// posts its Seq=0 delivery notice; the source gets the Seq=1 receipt.
func TestDragDropRoutesPlainTextToGoEdit(t *testing.T) {
	f := &dragFixture{}
	f.install(t)

	f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
	f.hostTab(3, "GOEDIT.ELF", 500, 100, 600, 500)
	rpcBindings[7] = rpcBinding{pid: 21, token: 0xAAAA}
	rpcBindings[3] = rpcBinding{pid: 33, token: 0xBBBB}

	blob := []byte("drop me at the caret")
	f.stage(7, "text/plain", blob)

	if !applyRPC(dragBeginReq(7, "text/plain")) {
		t.Fatal("drag_begin refused")
	}
	if !drag.armed || drag.src != 7 || drag.mime != "text/plain" {
		t.Fatalf("armed = %+v", drag)
	}
	if _, ok := f.files[vi.DragPath(7)]; ok {
		t.Fatal("the source staging was not consumed at arm")
	}
	if !f.hasLog(MarkerDragArm + "7 mime=text/plain len=20") {
		t.Fatalf("no arm marker: %v", f.logs)
	}

	// Motion into GOEDIT's rect: hover resolves, opens=text accepts.
	handleDragPointer(600, 200, false)
	if drag.hover != 3 || !drag.accept {
		t.Fatalf("hover=%d accept=%v", drag.hover, drag.accept)
	}
	if !f.hasLog(MarkerDragOver + "3 accept=1") {
		t.Fatalf("no hover marker: %v", f.logs)
	}

	// The release edge delivers.
	handleDragPointer(600, 200, true)
	if drag.armed {
		t.Fatal("the drag stayed armed after the drop")
	}
	if !f.hasLog(MarkerDragDrop + "3 from=7 mime=text/plain") {
		t.Fatalf("no drop marker: %v", f.logs)
	}
	// The payload waits at the TARGET's rendezvous path — the app's
	// DragTake consumes it and the envelope decodes byte-exact.
	enc, ok := f.files[vi.DragPath(3)]
	if !ok {
		t.Fatal("no staged envelope at the target")
	}
	mime, got, ok := vi.DecodeDrag(enc)
	if !ok || mime != "text/plain" || !bytes.Equal(got, blob) {
		t.Fatalf("delivered = %q %x", mime, got)
	}
	// Two notices: Seq=0 delivery to the target's bound pid, Seq=1
	// receipt to the source's.
	if len(f.notices) != 2 || len(f.pids) != 2 || f.pids[0] != 33 || f.pids[1] != 21 {
		t.Fatalf("notices = %+v pids = %v", f.notices, f.pids)
	}
	d, r := f.notices[0], f.notices[1]
	if d.Kind != vi.WmRpcKindDragDrop || d.ID != 3 || d.Seq != 0 ||
		d.Applied != 7 || d.TitleString() != "text/plain" ||
		d.Pad != vi.WmRpcPadBound || vi.WmAuth(d) != 0xBBBB || d.ReplyTo != 0 {
		t.Fatalf("delivery = %+v", d)
	}
	if r.Kind != vi.WmRpcKindDragDrop || r.ID != 7 || r.Seq != 1 ||
		r.Applied != 3 || r.Pad != vi.WmRpcPadBound || vi.WmAuth(r) != 0xAAAA {
		t.Fatalf("receipt = %+v", r)
	}
}

// image/png rides the same leg to GOVIEW (opens=image).
func TestDragDropRoutesPNGToGoView(t *testing.T) {
	f := &dragFixture{}
	f.install(t)

	f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
	f.hostTab(9, "GOVIEW.ELF", 500, 100, 600, 500)
	rpcBindings[7] = rpcBinding{pid: 21, token: 0xAAAA}
	rpcBindings[9] = rpcBinding{pid: 44, token: 0xCCCC}

	png := []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 1, 2, 3}
	f.stage(7, "image/png", png)
	if !applyRPC(dragBeginReq(7, "image/png")) {
		t.Fatal("drag_begin refused")
	}
	handleDragPointer(600, 200, false)
	if drag.hover != 9 || !drag.accept {
		t.Fatalf("hover=%d accept=%v", drag.hover, drag.accept)
	}
	handleDragPointer(600, 200, true)
	if !f.hasLog(MarkerDragDrop + "9 from=7 mime=image/png") {
		t.Fatalf("no drop marker: %v", f.logs)
	}
	enc, ok := f.files[vi.DragPath(9)]
	if !ok {
		t.Fatal("no staged envelope at GOVIEW")
	}
	if _, got, ok := vi.DecodeDrag(enc); !ok || !bytes.Equal(got, png) {
		t.Fatalf("delivered blob = %x", got)
	}
}

// A release over a window whose opens= refuses the mime delivers nothing:
// the kind-24 notice reports the undelivered ending and no staging moves.
func TestDragRefuseDeliversNothing(t *testing.T) {
	f := &dragFixture{}
	f.install(t)

	f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
	f.hostTab(9, "GOVIEW.ELF", 500, 100, 600, 500)
	rpcBindings[7] = rpcBinding{pid: 21, token: 0xAAAA}
	rpcBindings[9] = rpcBinding{pid: 44, token: 0xCCCC}

	f.stage(7, "text/plain", []byte("not an image"))
	applyRPC(dragBeginReq(7, "text/plain"))
	handleDragPointer(600, 200, false)
	if drag.accept {
		t.Fatal("image should refuse text — accept must be false")
	}
	if !f.hasLog(MarkerDragOver + "9 accept=0") {
		t.Fatalf("no refuse-hover marker: %v", f.logs)
	}
	handleDragPointer(600, 200, true)
	if drag.armed {
		t.Fatal("a refused drop stayed armed")
	}
	if !f.hasLog(MarkerDragCancel + "7 refuse") {
		t.Fatalf("no refuse marker: %v", f.logs)
	}
	if _, ok := f.files[vi.DragPath(9)]; ok {
		t.Fatal("a refused drop staged at the target")
	}
	if len(f.notices) != 1 || f.notices[0].Kind != vi.WmRpcKindDragCancel ||
		f.notices[0].ID != 7 || vi.WmAuth(f.notices[0]) != 0xAAAA {
		t.Fatalf("notices = %+v", f.notices)
	}
}

// A release over chrome (the rail) is an undelivered ending too.
func TestDragReleaseOverRailIsEmpty(t *testing.T) {
	f := &dragFixture{}
	f.install(t)
	f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
	rpcBindings[7] = rpcBinding{pid: 21, token: 0xAAAA}
	f.stage(7, "text/plain", []byte("x"))
	applyRPC(dragBeginReq(7, "text/plain"))
	handleDragPointer(100, 5, false) // y < RailHeight: the rail is chrome
	if drag.hover != 0 {
		t.Fatalf("hover over rail = %d", drag.hover)
	}
	handleDragPointer(100, 5, true)
	if !f.hasLog(MarkerDragCancel + "7 empty") {
		t.Fatalf("no empty marker: %v", f.logs)
	}
}

// A mismatched envelope mime, a missing stage, an unhosted source, and a
// second arm while one is armed are all refusals named by marker.
func TestDragBeginRefusalsAreNamed(t *testing.T) {
	cases := []struct {
		name    string
		setup   func(f *dragFixture)
		reqMime string
		want    string
	}{
		{"missing staging", func(f *dragFixture) {
			f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
		}, "text/plain", " missing"},
		{"mime disagreement", func(f *dragFixture) {
			f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
			f.stage(7, "image/png", []byte("x"))
		}, "text/plain", " bad"},
		{"empty mime", func(f *dragFixture) {
			f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
			f.stage(7, "x", []byte("x"))
		}, "", " nomime"},
		{"not a tab", func(f *dragFixture) {
			f.stage(7, "text/plain", []byte("x"))
		}, "text/plain", " notab"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := &dragFixture{}
			f.install(t)
			tc.setup(f)
			if applyRPC(dragBeginReq(7, tc.reqMime)) {
				t.Fatal("a bad arm applied")
			}
			if !f.hasLog(MarkerDragRefuse + "7" + tc.want) {
				t.Fatalf("refuse marker missing (%q): %v", tc.want, f.logs)
			}
			if drag.armed {
				t.Fatal("a refused arm armed the drag")
			}
		})
	}
}

// One armed drag at a time — a second begin while armed is refused.
func TestDragBeginBusyRefuses(t *testing.T) {
	f := &dragFixture{}
	f.install(t)
	f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
	f.hostTab(3, "GOEDIT.ELF", 500, 100, 600, 500)
	f.stage(7, "text/plain", []byte("a"))
	f.stage(3, "text/plain", []byte("b"))
	applyRPC(dragBeginReq(7, "text/plain"))
	if applyRPC(dragBeginReq(3, "text/plain")) {
		t.Fatal("a second arm applied")
	}
	if !f.hasLog(MarkerDragRefuse + "3 busy") {
		t.Fatalf("no busy marker: %v", f.logs)
	}
}

// The source's own cancel aborts the armed drag; a different window's
// cancel is refused.
func TestDragCancelRequest(t *testing.T) {
	f := &dragFixture{}
	f.install(t)
	f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
	rpcBindings[7] = rpcBinding{pid: 21, token: 0xAAAA}
	f.stage(7, "text/plain", []byte("x"))
	applyRPC(dragBeginReq(7, "text/plain"))

	if applyRPC(dragCancelReq(3)) {
		t.Fatal("a foreign window cancelled the drag")
	}
	if !applyRPC(dragCancelReq(7)) {
		t.Fatal("the source's own cancel was refused")
	}
	if drag.armed {
		t.Fatal("cancel left the drag armed")
	}
	if !f.hasLog(MarkerDragCancel + "7 request") {
		t.Fatalf("no cancel marker: %v", f.logs)
	}
	if len(f.notices) != 1 || f.notices[0].Kind != vi.WmRpcKindDragCancel {
		t.Fatalf("notices = %+v", f.notices)
	}
	// Nothing armed: a cancel is an honest refusal.
	if applyRPC(dragCancelReq(7)) {
		t.Fatal("cancel applied with no armed drag")
	}
}

// A dead source's armed drag ends silently with the binding teardown —
// no ghost, no delivery, and its staging slot cannot leak to a reused id.
func TestDragDiesWithTheSourceWindow(t *testing.T) {
	f := &dragFixture{}
	f.install(t)
	f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
	rpcBindings[7] = rpcBinding{pid: 21, token: 0xAAAA}
	f.stage(7, "text/plain", []byte("x"))
	applyRPC(dragBeginReq(7, "text/plain"))
	f.files[vi.DragPath(7)] = []byte("orphan")
	dropRpcBinding(7)
	if drag.armed {
		t.Fatal("the drag survived its source's death")
	}
	if !f.hasLog(MarkerDragCancel + "7 dead") {
		t.Fatalf("no dead marker: %v", f.logs)
	}
	if _, ok := f.files[vi.DragPath(7)]; ok {
		t.Fatal("orphan staging survived teardown")
	}
}

// opensAccepts is the admission vocabulary: a bare family word takes any
// subtype under it; a subtype spelling takes only itself.
func TestOpensAcceptsVocabulary(t *testing.T) {
	cases := []struct {
		opens []string
		mime  string
		want  bool
	}{
		{[]string{"text"}, "text/plain", true},    // GOEDIT's row
		{[]string{"text"}, "text/markdown", true}, // family covers subtypes
		{[]string{"text"}, "image/png", false},    // family is not a substring
		{[]string{"image"}, "image/png", true},    // GOVIEW's row
		{[]string{"image"}, "text/plain", false},
		{[]string{"text/plain"}, "text/plain", true}, // subtype exact
		{[]string{"text/plain"}, "text/html", false}, // subtype names itself only
		{[]string{"binary", "text"}, "text/x-go", true},
		{nil, "text/plain", false},
		{[]string{"text"}, "", false},
	}
	for _, tc := range cases {
		if got := opensAccepts(tc.opens, tc.mime); got != tc.want {
			t.Fatalf("opensAccepts(%v, %q) = %v want %v", tc.opens, tc.mime, got, tc.want)
		}
	}
}

// A hosted tab with no manifest row (or no opens=) refuses by omission.
func TestDragTargetWithoutOpensRefuses(t *testing.T) {
	f := &dragFixture{}
	f.install(t)
	f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
	f.hostTab(3, "GOTERM.ELF", 500, 100, 600, 500) // no opens= in the manifest
	rpcBindings[7] = rpcBinding{pid: 21, token: 0xAAAA}
	f.stage(7, "text/plain", []byte("x"))
	applyRPC(dragBeginReq(7, "text/plain"))
	handleDragPointer(600, 200, false)
	if drag.hover != 3 || drag.accept {
		t.Fatalf("hover=%d accept=%v — a row-less bin must refuse", drag.hover, drag.accept)
	}
}

// The ghost is a presented-frame plate over the pointer, tri-stated by
// the hover verdict — the pixels are the same plate primitives every
// other seat popover uses.
func TestDragGhostPaints(t *testing.T) {
	scan := make([]byte, vi.ScanoutWidth*vi.ScanoutHeight*4)
	if paintDragGhost(scan) != 0 {
		t.Fatal("ghost painted with no armed drag")
	}
	drag = dragSession{armed: true, src: 7, mime: "text/plain", x: 100, y: 100}
	t.Cleanup(func() { drag = dragSession{} })
	if paintDragGhost(scan) == 0 {
		t.Fatal("armed ghost painted nothing")
	}
	if _, once := dragGhostPaintMarker(true, true); !once {
		t.Fatal("no presented-ghost marker")
	}
	if _, once := dragGhostPaintMarker(true, true); once {
		t.Fatal("the ghost marker is per-drag, not per-tick")
	}
}

// M184b (#3175): a held-drag sample pinned on the scanout edge hands the
// armed drag's payload to the host — the seat stages the blob into
// OUTBOX/ under a minted name, signs a DRAGOUT record on the outbox
// lane, and receipts the source delivered (applied=0: no guest window).
func TestDragOutEdgeHandsOffToHost(t *testing.T) {
	f := &dragFixture{}
	f.install(t)
	h := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	h.plantArmed(0xBEEF, hostint.LaneOutbox)
	hostintSeatTick()

	f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
	rpcBindings[7] = rpcBinding{pid: 21, token: 0xAAAA}

	blob := []byte("through the glass")
	f.stage(7, "text/plain", blob)
	if !applyRPC(dragBeginReq(7, "text/plain")) {
		t.Fatal("drag_begin refused")
	}
	// The held sample pins x to the right scanout edge: the handoff.
	handleDragPointer(vi.ScanoutWidth-1, 400, false)
	if drag.armed {
		t.Fatal("the drag stayed armed after the edge handoff")
	}
	// The staged payload: minted name from the mime, byte-equal blob.
	staged, ok := f.files["/host/OUTBOX/GuestDrag.txt"]
	if !ok || !bytes.Equal(staged, blob) {
		t.Fatalf("staged = %v %x", ok, staged)
	}
	// The signed record: DRAGOUT-00000001, sender = the source window.
	rec, rok := hostint.DecodeRecord(h.files["DRAGOUT-00000001"])
	if !rok || rec.Tag != hostint.TagDragOut || rec.Seq != 1 ||
		rec.Epoch != 0xBEEF || rec.Sender != 7 || !rec.Verify(h.key) {
		t.Fatalf("record = %+v ok=%v", rec, rok)
	}
	name, size, ok := dropPayload(rec.Payload)
	if !ok || name != "GuestDrag.txt" || size != uint64(len(blob)) {
		t.Fatalf("payload = %q %d %v", name, size, ok)
	}
	if !h.hasLog(MarkerHostintDragOut+"seq=1 name=GuestDrag.txt") {
		t.Fatalf("no emit marker: %v", h.logs)
	}
	// The source's receipt: Seq=1, applied=0 — delivered to no guest
	// window, i.e. the host took it.
	if len(f.notices) != 1 || f.notices[0].Kind != vi.WmRpcKindDragDrop ||
		f.notices[0].Seq != 1 || f.notices[0].Applied != 0 ||
		vi.WmAuth(f.notices[0]) != 0xAAAA {
		t.Fatalf("notices = %+v", f.notices)
	}
}

// Every boundary pixel counts as the edge: left column, top row, right
// column, bottom row.
func TestDragOutAtEdgeBounds(t *testing.T) {
	for _, p := range [][2]uint32{{0, 400}, {400, 0},
		{vi.ScanoutWidth - 1, 400}, {400, vi.ScanoutHeight - 1}} {
		if !dragOutAtEdge(p[0], p[1]) {
			t.Fatalf("(%d,%d) not an edge", p[0], p[1])
		}
	}
	for _, p := range [][2]uint32{{1, 400}, {400, 1},
		{vi.ScanoutWidth - 2, 400}, {400, vi.ScanoutHeight - 2}, {640, 360}} {
		if dragOutAtEdge(p[0], p[1]) {
			t.Fatalf("(%d,%d) an edge", p[0], p[1])
		}
	}
}

// No armed lane: the edge is an undelivered ending named "edge" — byte
// silence holds (nothing staged, nothing emitted), the source gets the
// cancel notice.
func TestDragOutEdgeWithoutLaneAborts(t *testing.T) {
	f := &dragFixture{}
	f.install(t)
	oldEng := hostintEngine
	hostintEngine = nil
	t.Cleanup(func() { hostintEngine = oldEng })

	f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
	rpcBindings[7] = rpcBinding{pid: 21, token: 0xAAAA}
	f.stage(7, "text/plain", []byte("x"))
	applyRPC(dragBeginReq(7, "text/plain"))
	handleDragPointer(vi.ScanoutWidth-1, 400, false)
	if drag.armed {
		t.Fatal("the drag stayed armed with no lane")
	}
	if !f.hasLog(MarkerDragCancel + "7 edge") {
		t.Fatalf("no edge marker: %v", f.logs)
	}
	for path := range f.files {
		if strings.HasPrefix(path, "/host/OUTBOX/") {
			t.Fatalf("a payload staged with no lane: %s", path)
		}
	}
	if len(f.notices) != 1 || f.notices[0].Kind != vi.WmRpcKindDragCancel {
		t.Fatalf("notices = %+v", f.notices)
	}
}

// An armed mask without lane_outbox: the emit refuses lane_disabled and
// the staged payload is deleted before the abort — no partial file.
func TestDragOutEdgeLaneDisabledCleansStage(t *testing.T) {
	f := &dragFixture{}
	f.install(t)
	h := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	h.plantArmed(3, hostint.LaneClip) // armed, but not the outbox bit
	hostintSeatTick()

	f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
	rpcBindings[7] = rpcBinding{pid: 21, token: 0xAAAA}
	f.stage(7, "text/plain", []byte("x"))
	applyRPC(dragBeginReq(7, "text/plain"))
	handleDragPointer(vi.ScanoutWidth-1, 400, false)
	if drag.armed {
		t.Fatal("the drag stayed armed after the refusal")
	}
	if !h.hasLog(hostintMarkerPrefix + " refuse lane=dragout reason=" +
		hostint.RefuseLaneDisabled) {
		t.Fatalf("no lane_disabled refusal: %v", h.logs)
	}
	if _, ok := f.files["/host/OUTBOX/GuestDrag.txt"]; ok {
		t.Fatal("a refused emit left its staged payload behind")
	}
	if _, ok := f.files["DRAGOUT-00000001"]; ok {
		t.Fatal("a refused emit published a record")
	}
	if !f.hasLog(MarkerDragCancel + "7 edge") {
		t.Fatalf("no edge marker: %v", f.logs)
	}
}

// A name already parked in OUTBOX/ (an in-flight REQ export) gets the
// landing suffix — the staged payload can never clobber it.
func TestDragOutNameCollisionSuffixes(t *testing.T) {
	f := &dragFixture{}
	f.install(t)
	h := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	h.plantArmed(5, hostint.LaneOutbox)
	hostintSeatTick()

	f.files["/host/OUTBOX/GuestDrag.png"] = []byte("the pending export")
	f.hostTab(7, "GOFILES.ELF", 0, RailHeight, 400, 300)
	rpcBindings[7] = rpcBinding{pid: 21, token: 0xAAAA}
	f.stage(7, "image/png", []byte{0x89, 'P', 'N', 'G'})
	applyRPC(dragBeginReq(7, "image/png"))
	handleDragPointer(vi.ScanoutWidth-1, 400, false)
	if _, ok := f.files["/host/OUTBOX/GuestDrag-2.png"]; !ok {
		t.Fatalf("no suffixed stage: %v", f.files)
	}
	if got := f.files["/host/OUTBOX/GuestDrag.png"]; string(got) != "the pending export" {
		t.Fatalf("the pending export was clobbered: %q", got)
	}
	if !h.hasLog("name=GuestDrag-2.png") {
		t.Fatalf("marker missed the suffix: %v", h.logs)
	}
}
