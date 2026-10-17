package main

// Host-side tests for GPUTRIANGLE.ELF (M102f1, issue #2170). Every journey
// runs against injected transport/window seams — nothing here is a live GPU
// claim, and the fakes deliberately model ONLY the contract: a kind-17
// exchange with a genuine bound-token ack, a staged reply on Poll, and the
// seat-side publish that drops pixels into the app's own surface.

import (
	"context"
	"errors"
	"math"
	"strings"
	"testing"
	"unsafe"

	"virelai/gpu3d"
	"virelai/vi"
)

// The seat's declare handler (kind-8) resizes declared windows to the full
// viewport; the kernel then refuses a smaller surface bind (issue #2225).
const seatViewportW, seatViewportH = 1280, 720

// fakeTransport is the injected kind-17 transport. It records the opcode
// order exactly as the client drives it, answers with genuine bound-token
// acks (the client still revalidates them), and lets the test script per-op
// status, transport errors, and when Poll turns staged.
type fakeTransport struct {
	ops         []uint8
	seq         uint8
	token       uint64
	frame       uint32
	stagedAfter int // polls to answer pending before staged
	polls       int
	status      map[uint8]uint8 // op -> forced wire status
	transport   error           // injected transport failure
	onStaged    func()          // models the seat-side publish
	stagedOnce  bool
}

func (f *fakeTransport) Exchange(_ context.Context, windowID uint32, op uint8, payload [gpu3d.PayloadBytes]byte) (gpu3d.Trip, error) {
	f.ops = append(f.ops, op)
	f.seq++
	var req vi.WmRpc
	req.Kind = gpu3d.Kind
	req.ID = uint8(windowID)
	req.Seq = f.seq
	req.ReplyTo = 7
	req.Applied = op
	req.Pad = vi.WmRpcPadBound
	req.Title = payload
	vi.SetWmAuth(&req, f.token)

	if f.transport != nil {
		return gpu3d.Trip{}, f.transport
	}
	status := gpu3d.StatusOK
	if s, ok := f.status[op]; ok {
		status = s
	}
	staged := false
	if op == gpu3d.OpPoll {
		f.polls++
		if f.polls > f.stagedAfter {
			staged = true
			if !f.stagedOnce {
				f.stagedOnce = true
				if f.onStaged != nil {
					f.onStaged()
				}
			}
		}
	}
	if op == gpu3d.OpPresent {
		f.frame++
	}
	applied := uint8(1)
	if status != gpu3d.StatusOK {
		applied = 0
	}
	var ack vi.WmRpc
	ack.Kind = gpu3d.Kind | vi.WmRpcReplyFlag
	ack.ID = req.ID
	ack.Seq = req.Seq
	ack.ReplyTo = req.ReplyTo
	ack.Applied = applied
	ack.Pad = vi.WmRpcPadBound
	ack.Title = gpu3d.EncodeReply(status, staged, f.frame)
	vi.SetWmAuth(&ack, f.token)
	return gpu3d.Trip{Req: req, Ack: ack, Token: f.token}, nil
}

// fakeHost is the injected window/file/mailbox seam. It enforces two real
// kernel/share rules so the ordering bugs stay unrepresentable: a declared
// window is seat-resized to the full viewport, after which a smaller bind
// fails the capacity check (issue #2225), and the /host share has no
// implicit mkdir — a write into a dir the app never created fails
// (issue #2226).
type fakeHost struct {
	tr       *fakeTransport
	nextWin  int
	surf     []byte
	surfW    uint32
	files    map[string][]byte
	dirs     map[string]bool
	declared map[int]bool
	order    []string
	lines    []string
	ipc      [][]byte
	closed   []int
	shared   []int
	shareOK  bool
	presents int
	events   []vi.Event
	openErr  error
	bindErr  error
	writeErr error
	peersOK  bool
}

func newFakeHost() (*fakeHost, *fakeTransport) {
	tr := &fakeTransport{token: 0x5150aa}
	return &fakeHost{
		tr:       tr,
		files:    map[string][]byte{},
		dirs:     map[string]bool{},
		declared: map[int]bool{},
		peersOK:  true,
		shareOK:  true,
	}, tr
}

func (f *fakeHost) OpenWindow(x, y, w, h uint32) (int, error) {
	if f.openErr != nil {
		return 0, f.openErr
	}
	f.nextWin++
	return f.nextWin, nil
}

func (f *fakeHost) DeclareTab(win int, title string) bool {
	f.declared[win] = true
	f.order = append(f.order, "declare")
	return true
}

func (f *fakeHost) BindSurface(win int, w, h uint32) ([]byte, error) {
	f.order = append(f.order, "bind")
	if f.bindErr != nil {
		return nil, f.bindErr
	}
	if f.declared[win] && (w < seatViewportW || h < seatViewportH) {
		return nil, errors.New("bind under the declared viewport")
	}
	f.surf = make([]byte, int(w*h)*4)
	f.surfW = w
	return f.surf, nil
}

func (f *fakeHost) ShareSurface(win int, surf []byte, stride, rows int) bool {
	f.order = append(f.order, "share")
	f.shared = append(f.shared, win)
	return f.shareOK
}
func (f *fakeHost) PresentWindow(win int) error { f.presents++; return nil }
func (f *fakeHost) PollEvent() (vi.Event, int64, bool) {
	if len(f.events) == 0 {
		return vi.Event{}, 0, false
	}
	ev := f.events[0]
	f.events = f.events[1:]
	return ev, 1, true
}
func (f *fakeHost) CloseWindow(win int) { f.closed = append(f.closed, win) }
func (f *fakeHost) MkdirShare(path string) error {
	f.dirs[path] = true
	return nil
}
func (f *fakeHost) WriteShareFile(path string, b []byte) error {
	if f.writeErr != nil {
		return f.writeErr
	}
	if strings.HasPrefix(path, receiptDir+"/") && !f.dirs[receiptDir] {
		return errors.New("write: no such directory")
	}
	f.files[path] = append([]byte(nil), b...)
	return nil
}
func (f *fakeHost) ConsoleLine(s string)          { f.lines = append(f.lines, s) }
func (f *fakeHost) Sleep(ticks uint64)            {}
func (f *fakeHost) Peers() (uint32, uint32, bool) { return 9, 8, f.peersOK }
func (f *fakeHost) IpcSend(target uint32, b []byte) int64 {
	f.ipc = append(f.ipc, append([]byte(nil), b...))
	return 0
}
func (f *fakeHost) Transport() gpu3d.Transport { return f.tr }

// publishInto writes the "seat-published" pixels for one render extent into
// the fake surface: the clear colour everywhere and the triangle colour in a
// deterministic block — a stand-in for e's PUBLISH, so tests never have the
// app fabricate pixels.
func publishInto(h *fakeHost, ew, eh uint32) {
	b, g, r := byte(clearRGB&0xff), byte((clearRGB>>8)&0xff), byte((clearRGB>>16)&0xff)
	for y := uint32(0); y < eh; y++ {
		for x := uint32(0); x < ew; x++ {
			o := (y*h.surfW + x) * 4
			h.surf[o], h.surf[o+1], h.surf[o+2], h.surf[o+3] = b, g, r, 0xff
		}
	}
	// A solid triangle-ish block the comparator could check: rows 10..30,
	// narrowing like a real raster — inside the render destination only.
	for y := uint32(10); y < 30; y++ {
		for x := uint32(8); x < 8+(y-10); x++ {
			o := (y*h.surfW + x) * 4
			h.surf[o], h.surf[o+1], h.surf[o+2], h.surf[o+3] = 0, 0, 0xff, 0xff
		}
	}
}

func runJ(t *testing.T, h *fakeHost, journey string) error {
	t.Helper()
	return run(h, journey)
}

func receiptRows(h *fakeHost) []string {
	return strings.Split(strings.TrimRight(string(h.files[receiptPath]), "\n"), "\n")
}

func rowsWith(h *fakeHost, name string) []string {
	var out []string
	for _, l := range receiptRows(h) {
		if strings.HasPrefix(l, name+"\t") {
			out = append(out, l)
		}
	}
	return out
}

func hasLine(h *fakeHost, prefix string) bool {
	for _, l := range h.lines {
		if strings.HasPrefix(l, prefix) {
			return true
		}
	}
	return false
}

// --- the journeys --------------------------------------------------------------

func TestTriangleJourneyPublishes(t *testing.T) {
	h, tr := newFakeHost()
	tr.onStaged = func() { publishInto(h, extentW, extentH) }
	if err := runJ(t, h, "triangle"); err != nil {
		t.Fatalf("triangle: %v", err)
	}
	pub := rowsWith(h, "published")
	if len(pub) != 1 || !strings.Contains(pub[0], "EXPO_1_1.BGRA") {
		t.Fatalf("published rows: %v", pub)
	}
	if got := rowsWith(h, "completed"); len(got) != 1 || !strings.HasSuffix(got[0], "\t1") {
		t.Fatalf("completed rows: %v", got)
	}
	expo, ok := h.files[receiptDir+"/EXPO_1_1.BGRA"]
	if !ok || len(expo) != int(extentW*extentH)*4 {
		t.Fatalf("export missing/short: %d", len(expo))
	}
	if !hasLine(h, "gputri: published frame=1") || !hasLine(h, "gputri OK") {
		t.Fatalf("markers: %v", h.lines)
	}
}

// The revert-fails target: the request ORDER must carry Open, Clear,
// Triangle, Present, Poll, Close in contract order. Removing the Triangle
// call from the journey leaves a gap this test names.
func TestRequestOrderCarriesTriangle(t *testing.T) {
	h, tr := newFakeHost()
	tr.onStaged = func() { publishInto(h, extentW, extentH) }
	if err := runJ(t, h, "triangle"); err != nil {
		t.Fatalf("triangle: %v", err)
	}
	want := []uint8{gpu3d.OpOpen, gpu3d.OpClear, gpu3d.OpTriangle,
		gpu3d.OpPresent, gpu3d.OpPoll, gpu3d.OpClose}
	if len(tr.ops) != len(want) {
		t.Fatalf("ops %v, want %v", tr.ops, want)
	}
	for i, op := range want {
		if tr.ops[i] != op {
			t.Fatalf("ops %v, want %v (first divergence at %d)", tr.ops, want, i)
		}
	}
}

// Control for the revert-fails pair: clear + lifecycle receipts exist
// whether or not the triangle op ran.
func TestClearAndLifecycleControls(t *testing.T) {
	h, tr := newFakeHost()
	tr.onStaged = func() { publishInto(h, extentW, extentH) }
	if err := runJ(t, h, "triangle"); err != nil {
		t.Fatalf("triangle: %v", err)
	}
	if len(rowsWith(h, "window")) != 1 || len(rowsWith(h, "ctx")) != 1 {
		t.Fatalf("lifecycle rows: %v", receiptRows(h))
	}
	if tr.ops[0] != gpu3d.OpOpen || tr.ops[1] != gpu3d.OpClear {
		t.Fatalf("open/clear order broken: %v", tr.ops)
	}
	if tr.ops[len(tr.ops)-1] != gpu3d.OpClose {
		t.Fatalf("no close: %v", tr.ops)
	}
}

// Completed is not on-screen: when Poll never reports staged there is no
// published row, no export file and no published marker — a submitted or
// completed frame is never passed off as pixels.
func TestCompletedOnlyIsNotPublished(t *testing.T) {
	h, tr := newFakeHost()
	tr.stagedAfter = 1 << 30 // Poll stays pending forever
	err := runJ(t, h, "triangle")
	if err == nil {
		t.Fatal("expected pending outcome")
	}
	if len(rowsWith(h, "completed")) != 1 {
		t.Fatalf("missing completed row: %v", receiptRows(h))
	}
	if len(rowsWith(h, "published")) != 0 {
		t.Fatalf("published without staged: %v", receiptRows(h))
	}
	for name := range h.files {
		if strings.HasSuffix(name, ".BGRA") {
			t.Fatalf("export file written without publication: %s", name)
		}
	}
	if hasLine(h, "gputri: published") {
		t.Fatalf("on-screen marker without publication: %v", h.lines)
	}
}

// The app must not paint its own triangle: with the fake seat publishing
// nothing, the exported extent can carry no red pixels.
func TestAppNeverRasterizesItsTriangle(t *testing.T) {
	h, tr := newFakeHost()
	tr.onStaged = func() {} // the seat "publishes" nothing into the surface
	if err := runJ(t, h, "triangle"); err != nil {
		t.Fatalf("triangle: %v", err)
	}
	expo := h.files[receiptDir+"/EXPO_1_1.BGRA"]
	for i := 0; i+3 < len(expo); i += 4 {
		if expo[i] == 0 && expo[i+1] == 0 && expo[i+2] == 0xff {
			t.Fatalf("app-painted red pixel at export offset %d", i)
		}
	}
}

func TestMixedJourneyKeepsMargins(t *testing.T) {
	h, tr := newFakeHost()
	tr.onStaged = func() { publishInto(h, extentW, extentH) }
	if err := runJ(t, h, "mixed"); err != nil {
		t.Fatalf("mixed: %v", err)
	}
	mb, mg, mr := byte(marginRGB&0xff), byte((marginRGB>>8)&0xff), byte((marginRGB>>16)&0xff)
	// Right margin and bottom margin hold the flat margin colour; the
	// render destination is the published pixels.
	o := (0*h.surfW + extentW + 4) * 4
	if h.surf[o] != mb || h.surf[o+1] != mg || h.surf[o+2] != mr {
		t.Fatalf("right margin not 2D-filled: %v", h.surf[o:o+4])
	}
	o = ((extentH+10)*h.surfW + 8) * 4
	if h.surf[o] != mb || h.surf[o+1] != mg || h.surf[o+2] != mr {
		t.Fatalf("bottom margin not 2D-filled: %v", h.surf[o:o+4])
	}
}

func TestResizeCarriesDistinctGenerations(t *testing.T) {
	h, tr := newFakeHost()
	tr.onStaged = func() { publishInto(h, extentW, extentH) }
	first := true
	tr.onStaged = func() {
		if first {
			publishInto(h, extentW, extentH)
			first = false
			return
		}
		publishInto(h, resizeW, resizeH)
	}
	if err := runJ(t, h, "resize"); err != nil {
		t.Fatalf("resize: %v", err)
	}
	pub := rowsWith(h, "published")
	if len(pub) != 2 {
		t.Fatalf("published rows: %v", pub)
	}
	if !strings.HasPrefix(pub[0], "published\t1\t1\t") ||
		!strings.HasPrefix(pub[1], "published\t1\t2\t") {
		t.Fatalf("generations not distinct: %v", pub)
	}
	if h.files[receiptDir+"/EXPO_1_1.BGRA"] == nil ||
		h.files[receiptDir+"/EXPO_1_2.BGRA"] == nil {
		t.Fatal("missing per-generation exports")
	}
	if len(h.files[receiptDir+"/EXPO_1_2.BGRA"]) != int(resizeW*resizeH)*4 {
		t.Fatal("resized export has the old extent")
	}
}

func TestCloseReuseDistinctGenerations(t *testing.T) {
	h, tr := newFakeHost()
	tr.onStaged = func() { publishInto(h, extentW, extentH) }
	if err := runJ(t, h, "closereuse"); err != nil {
		t.Fatalf("closereuse: %v", err)
	}
	pub := rowsWith(h, "published")
	if len(pub) != 2 ||
		!strings.HasPrefix(pub[0], "published\t1\t") ||
		!strings.HasPrefix(pub[1], "published\t2\t") {
		t.Fatalf("window generations not distinct: %v", pub)
	}
	if h.nextWin != 2 || len(h.closed) < 2 {
		t.Fatalf("window lifetime: id=%d closed=%v", h.nextWin, h.closed)
	}
	found := false
	for name := range h.files {
		if strings.Contains(name, "/EXPO_2_") {
			found = true
		}
	}
	if !found {
		t.Fatalf("reused window export missing: %v", h.files)
	}
}

// The invalid journey: every refusal is a named error row, the refused
// requests never reach the wire, and NO success receipt exists.
func TestInvalidJourneyNamedErrorsNoSuccess(t *testing.T) {
	h, tr := newFakeHost()
	if err := runJ(t, h, "invalid"); err != nil {
		t.Fatalf("invalid journey: %v", err)
	}
	errs := rowsWith(h, "error")
	if len(errs) != 5 {
		t.Fatalf("error rows: %v", errs)
	}
	for _, want := range []string{"\tinvalid", "\tinvalid", "\tinvalid", "\tinvalid", "\tclosed"} {
		found := false
		for _, e := range errs {
			if strings.HasSuffix(e, want) {
				found = true
			}
		}
		if !found {
			t.Fatalf("missing named error %q in %v", want, errs)
		}
	}
	// Only the one valid open and its close ever hit the transport — the
	// over-cap opens and the wide clear died before the wire.
	for _, op := range tr.ops {
		if op != gpu3d.OpOpen && op != gpu3d.OpClose {
			t.Fatalf("refused op reached the wire: %v", tr.ops)
		}
	}
	if len(rowsWith(h, "published")) != 0 || len(rowsWith(h, "completed")) != 0 {
		t.Fatalf("success receipt in invalid journey: %v", receiptRows(h))
	}
}

// The forged journey: one kind-17 frame with a wrong token goes out the
// ordinary mailbox; the genuine session then completes a second frame —
// the receipts prove both.
func TestForgedRequestUsesOrdinaryMailbox(t *testing.T) {
	h, tr := newFakeHost()
	tr.onStaged = func() { publishInto(h, extentW, extentH) }
	if err := runJ(t, h, "forged"); err != nil {
		t.Fatalf("forged: %v", err)
	}
	if len(h.ipc) != 1 {
		t.Fatalf("ipc frames: %d", len(h.ipc))
	}
	m, ok := vi.DecodeWmRpc(h.ipc[0])
	if !ok || m.Kind != gpu3d.Kind || m.ID != 1 || m.Applied != gpu3d.OpClear ||
		m.Pad != vi.WmRpcPadBound || vi.WmAuth(m) != forgedToken {
		t.Fatalf("forged frame shape: %+v", m)
	}
	if len(rowsWith(h, "forged")) != 1 || len(rowsWith(h, "intact")) != 1 {
		t.Fatalf("receipt rows: %v", receiptRows(h))
	}
	if len(rowsWith(h, "published")) != 2 {
		t.Fatalf("published rows: %v", rowsWith(h, "published"))
	}
}

// Native-only: an unsupported OPEN is a named refusal, prints the honest
// marker and writes NO receipts.
func TestUnsupportedIsNamedAndReceiptless(t *testing.T) {
	h, tr := newFakeHost()
	tr.status = map[uint8]uint8{gpu3d.OpOpen: gpu3d.StatusUnsupported}
	if err := runJ(t, h, "triangle"); err != nil {
		t.Fatalf("unsupported path should exit clean: %v", err)
	}
	if !hasLine(h, "gputri: unsupported") {
		t.Fatalf("markers: %v", h.lines)
	}
	if hasLine(h, "gputri OK") || len(h.files) != 0 {
		t.Fatalf("success claim on a native-only host: %v %v", h.lines, h.files)
	}
}

// A lost-context answer mid-journey is a named error, never success.
func TestLostContextIsNamed(t *testing.T) {
	h, tr := newFakeHost()
	tr.status = map[uint8]uint8{gpu3d.OpPresent: gpu3d.StatusLostContext}
	tr.onStaged = func() { publishInto(h, extentW, extentH) }
	if err := runJ(t, h, "triangle"); err == nil {
		t.Fatal("lost context should abort the journey")
	}
	if !hasLine(h, "gputri: refuse present lost-context") {
		t.Fatalf("markers: %v", h.lines)
	}
	if len(rowsWith(h, "published")) != 0 {
		t.Fatal("published row on a lost context")
	}
}

// --- the M102 live-path fixes (#2224, #2225, #2226) -----------------------------

// Issue #2224: the surface bind must issue the mmap syscall, not die
// client-side. The old MmapHint(winTag|win, …) call failed its own
// page-alignment check — EINVAL with zero kernel contact — while
// MmapWindowSurface passes the tag|win hint through to slot-63. On the
// host every issued syscall degrades to -ENOSYS, so ENOSYS (not EINVAL)
// IS the proof the bind reached the kernel.
func TestBindSurfaceIssuesTheMmapSyscall(t *testing.T) {
	_, err := (guestHost{}).BindSurface(7, extentW, extentH)
	if err == nil {
		t.Fatal("the host stub must surface an error")
	}
	if err.Error() != "ENOSYS" {
		t.Fatalf("bind error %q — EINVAL means the syscall never issued", err)
	}
}

// Issue #2225: bind must precede declare. The fake enforces the kernel's
// capacity rule — a declared window is seat-resized to the full viewport,
// so a smaller post-declare bind is EINVAL — which makes every journey an
// ordering check; this test names the contract directly.
func TestBindPrecedesDeclare(t *testing.T) {
	h, tr := newFakeHost()
	tr.onStaged = func() { publishInto(h, extentW, extentH) }
	if err := runJ(t, h, "triangle"); err != nil {
		t.Fatalf("triangle: %v", err)
	}
	if len(h.order) < 3 || h.order[0] != "bind" || h.order[1] != "share" || h.order[2] != "declare" {
		t.Fatalf("window setup order: %v", h.order)
	}
}

// Issue #2226: the first export must not depend on writeReceipts' mkdir —
// it runs first, so exportSurface creates the receipt dir itself. The
// fake share refuses writes into a dir that was never created.
func TestExportCreatesReceiptDirFirst(t *testing.T) {
	h, tr := newFakeHost()
	tr.onStaged = func() { publishInto(h, extentW, extentH) }
	if err := runJ(t, h, "triangle"); err != nil {
		t.Fatalf("triangle: %v", err)
	}
	if !h.dirs[receiptDir] {
		t.Fatalf("receipt dir never created: %v", h.dirs)
	}
	if _, ok := h.files[receiptDir+"/EXPO_1_1.BGRA"]; !ok {
		t.Fatal("first export missing")
	}
}

// Issue #2236 defect #11: the independent pixel oracle
// (test/fixtures/gpu3d/pixels.json) rasterizes its expectation in the
// VIR1 convention — NDC y grows toward LARGER pixel rows, so (-1,-1) is
// the top-left readback pixel. The fixture triangle sits at pixels
// (8,8) (56,20) (20,40) in the 64×48 frame; mapping the scene's wire
// verts through that convention must land on those pixels. The GL-style
// y-up encoding this replaces produced the exact vertical mirror — a
// red pixel where the oracle wants clear — so this pin fails on the
// sign bug even before the live comparator runs.
func TestSceneVertsMapToFixturePixels(t *testing.T) {
	const (
		ndcHalf = 32768 // i16 wire magnitude of NDC ±1
		w       = 64
		h       = 48
	)
	want := [3][2]int{{8, 8}, {56, 20}, {20, 40}}
	for i, v := range sceneVerts {
		px := int(math.Round(float64(int64(v.X)+ndcHalf) / (2 * ndcHalf) * w))
		py := int(math.Round(float64(int64(v.Y)+ndcHalf) / (2 * ndcHalf) * h))
		if px != want[i][0] || py != want[i][1] {
			t.Fatalf("sceneVerts[%d] NDC (%d,%d) -> pixel (%d,%d), want %v",
				i, v.X, v.Y, px, py, want[i])
		}
		if v.RGB != 0xf800 {
			t.Fatalf("sceneVerts[%d] rgb %#x want red 0xf800", i, v.RGB)
		}
	}
}

// --- M111b compute journeys (issue #2409) -------------------------------------
//
// The guest side of slot 90 pinned host-side: a fake kernel answers the
// sys_gpucomp descriptor stream — WRITE/READ move bytes through the app's
// own mapped windows (the desc's arg_a is a real VA into them), and
// RUN(GEMM) computes C = A·B in f16, so the pinned readback exercises the
// whole encode→dispatch→readback chain.

// compKernel fakes sys_gpucomp: buffers are byte slices keyed by issued
// handle; descriptor VAs resolve through the windows CompMap handed out.
type compKernel struct {
	maps     map[uintptr][]byte // window base VA -> window
	bufs     map[uint64][]byte
	nextBuf  uint64
	submits  uint64
	refusals uint64
}

func (k *compKernel) mmap(_ uintptr, size int, _, _ uint64) ([]byte, error) {
	b := make([]byte, size)
	k.maps[sliceAddr(b)] = b
	return b, nil
}

func sliceAddr(b []byte) uintptr {
	if len(b) == 0 {
		return 0
	}
	return uintptr(unsafe.Pointer(&b[0]))
}

// window resolves a descriptor VA (arg_a) + length into the mapped window
// that contains it — the same range check the kernel's uaccess does.
func (k *compKernel) window(va uint64, n uint64) []byte {
	for base, b := range k.maps {
		if va >= uint64(base) && va+uint64(n) <= uint64(base)+uint64(len(b)) {
			return b[va-uint64(base):][:n]
		}
	}
	return nil
}

func u64le(b []byte) uint64 {
	var v uint64
	for i := 0; i < 8; i++ {
		v |= uint64(b[i]) << (8 * i)
	}
	return v
}

func gpu3dLE32(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}

func (k *compKernel) sys(desc []byte) int64 {
	if len(desc) != vi.GpucompDescBytes {
		return -vi.ErrEINVAL
	}
	switch op := gpu3dLE32(desc[0:]); op {
	case vi.GpucompOpen:
		k.bufs = map[uint64][]byte{}
		return 0x1_0007 // generation 1 | ctx 7
	case vi.GpucompClose:
		return 0
	case vi.GpucompBufAlloc:
		k.nextBuf++
		h := 1<<24 | k.nextBuf<<16 | 0x7 // gen | slot | ctx — buffer handle
		k.bufs[h] = make([]byte, u64le(desc[16:]))
		return int64(h)
	case vi.GpucompWrite, vi.GpucompRead:
		h := u64le(desc[8:])
		b, ok := k.bufs[h]
		if !ok {
			return -vi.ErrEBADF
		}
		win := k.window(u64le(desc[16:]), u64le(desc[24:]))
		if win == nil {
			return -vi.ErrEFAULT
		}
		off := u64le(desc[32:])
		if off+uint64(len(win)) > uint64(len(b)) {
			return -vi.ErrEINVAL
		}
		if op == vi.GpucompWrite {
			copy(b[off:], win)
		} else {
			copy(win, b[off:])
		}
		return 0
	case vi.GpucompRun:
		if gpu3dLE32(desc[64:]) != vi.GpuKernelGEMM {
			k.refusals++
			return -vi.ErrEINVAL // kernel id outside the curated mask
		}
		k.submits++
		a := k.bufs[u64le(desc[88:])]
		bb := k.bufs[u64le(desc[96:])]
		c := k.bufs[u64le(desc[104:])]
		if a == nil || bb == nil || c == nil {
			k.refusals++
			return -vi.ErrEINVAL
		}
		f := func(x []byte, i int) float32 {
			return gpu3d.F32bits(uint16(x[2*i]) | uint16(x[2*i+1])<<8)
		}
		for r := 0; r < 2; r++ {
			for cc := 0; cc < 2; cc++ {
				v := f(a, r*2)*f(bb, cc) + f(a, r*2+1)*f(bb, 2+cc)
				h := gpu3d.F16bits(v)
				c[2*(r*2+cc)] = byte(h)
				c[2*(r*2+cc)+1] = byte(h >> 8)
			}
		}
		return 0
	case vi.GpucompStats:
		dst := k.window(u64le(desc[16:]), 64)
		if dst == nil {
			return -vi.ErrEFAULT
		}
		for i := range dst[:64] {
			dst[i] = 0
		}
		for i := 0; i < 8; i++ {
			dst[32+i] = byte(k.submits >> (8 * i)) // submits
			dst[40+i] = byte(k.submits >> (8 * i)) // completed
			dst[48+i] = byte(k.refusals >> (8 * i))
		}
		return 0
	}
	return -vi.ErrEINVAL
}

// compJourney swaps the package seams: CompSyscall answers the descriptor
// stream and CompMap registers each window under its REAL base address so
// the desc's arg_a resolves the way uaccess would.
func compJourney(t *testing.T, h *fakeHost, k *compKernel, journey string) error {
	t.Helper()
	oldSys, oldMap := gpu3d.CompSyscall, gpu3d.CompMap
	gpu3d.CompSyscall = k.sys
	gpu3d.CompMap = k.mmap
	t.Cleanup(func() { gpu3d.CompSyscall, gpu3d.CompMap = oldSys, oldMap })
	return run(h, journey)
}

func TestGemmJourneyRoundTrip(t *testing.T) {
	h, _ := newFakeHost()
	k := &compKernel{maps: map[uintptr][]byte{}}
	if err := compJourney(t, h, k, "gemm"); err != nil {
		t.Fatalf("gemm: %v", err)
	}
	if !hasLine(h, "gputri: gemm c=19,22,43,50") {
		t.Fatalf("markers: %v", h.lines)
	}
	if !hasLine(h, "gputri OK") {
		t.Fatalf("markers: %v", h.lines)
	}
	if k.submits != 1 {
		t.Fatalf("submits=%d", k.submits)
	}
}

func TestGemmRefuseJourneyNamesTheRefusal(t *testing.T) {
	h, _ := newFakeHost()
	k := &compKernel{maps: map[uintptr][]byte{}}
	if err := compJourney(t, h, k, "gemmrefuse"); err != nil {
		t.Fatalf("gemmrefuse: %v", err)
	}
	if !hasLine(h, "gputri: refused invalid") {
		t.Fatalf("markers: %v", h.lines)
	}
	if !hasLine(h, "gputri: stats refusals=1") {
		t.Fatalf("markers: %v", h.lines)
	}
	if k.submits != 0 {
		t.Fatalf("a refusal must not submit")
	}
}
