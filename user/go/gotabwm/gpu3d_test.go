// M102e (issue #2169): the seat-side kind-17 tests. The kernel broker
// (d1) owns the device, the render and the pixel copy — so these tables
// pin what the SEAT owes: authenticated routing, the two-record pool
// keyed by bound window/session + generation, the once-per-completed-
// frame publish with fresh captured geometry, the named refusals, the
// lifetime closes, and that "presented" is earned only by a real present.
//
// fakeBroker models the frozen kernel contract (gpu3d_broker.zig): a
// verify-per-op context pool, a staged readback per completed frame, and
// a PUBLISH that clips the bounded copy into the window's ordinary
// surface at its live rect. compScanout models the kernel's ordinary
// surface composition (opaque blit, chrome band above client, z order) —
// the real mixed-scanout pixels remain M102f2's hardware assertions.
package main

import (
	"encoding/binary"
	"testing"

	"virelai/gpu3d"
	"virelai/vi"
)

// ---------------------------------------------------------------------------
// The kernel model.
// ---------------------------------------------------------------------------

// fakeGpuWin is one user window as the kernel sees it: a live rect and the
// ordinary surface PUBLISH copies into. The seat never writes these bytes;
// every change flows through a broker descriptor.
type fakeGpuWin struct {
	w, h    uint32
	surf    []uint32
	damages int
}

// fakeGpuCtx is one broker record: a generation-bearing handle, the render
// extent, and the newest completed frame staged for publication.
type fakeGpuCtx struct {
	handle uint64
	win    uint32
	ew, eh uint32
	clear  uint32
	verts  [3]vi.Gpu3dVertex
	hasTri bool
	staged []uint32
	dead   bool
}

// fakeBroker is the host model of gpu3d_broker.zig — the documented
// semantics only, so a seat bug shows up as a wrong descriptor or a wrong
// answer, never as a model shortcut.
type fakeBroker struct {
	wins   map[uint32]*fakeGpuWin
	ctxs   map[uint64]*fakeGpuCtx
	winCtx map[uint32]uint64
	gen    uint64
	maxCtx int
	calls  []vi.Gpu3dDesc

	// Fault injection.
	createErr     int64 // refuses CREATE before any live record is touched
	createLateErr int64 // refuses CREATE after extent-change revocation
	presentErr    int64
	pollRes       int64 // when set, POLL returns this verbatim
	pollSet       bool
}

func newFakeBroker(wins map[uint32]*fakeGpuWin) *fakeBroker {
	return &fakeBroker{wins: wins, ctxs: map[uint64]*fakeGpuCtx{},
		winCtx: map[uint32]uint64{}, maxCtx: gpu3dMaxRecs}
}

func newFakeWin(w, h uint32, fill uint32) *fakeGpuWin {
	s := &fakeGpuWin{w: w, h: h, surf: make([]uint32, w*h)}
	for i := range s.surf {
		s.surf[i] = fill
	}
	return s
}

// resize is the kernel-side window mutation a WM layout change causes: a
// new rect and a fresh surface (the old backing is gone — nothing may read
// beyond it).
func (w *fakeGpuWin) resize(nw, nh uint32, fill uint32) {
	w.w, w.h = nw, nh
	w.surf = make([]uint32, nw*nh)
	for i := range w.surf {
		w.surf[i] = fill
	}
	w.damages = 0
}

func (f *fakeBroker) verify(d vi.Gpu3dDesc) (*fakeGpuCtx, int64) {
	c, ok := f.ctxs[d.Handle]
	if !ok || c.dead || c.win != d.WindowID {
		return nil, -vi.ErrEBADF
	}
	return c, 0
}

func (f *fakeBroker) create(d vi.Gpu3dDesc) int64 {
	if f.createErr != 0 {
		return f.createErr
	}
	if old, ok := f.winCtx[d.WindowID]; ok {
		c := f.ctxs[old]
		if c != nil && c.ew == d.Width && c.eh == d.Height {
			return int64(old) // same extent is idempotent
		}
		// The extent changed: the old generation is revoked BEFORE the
		// re-open can fail — the broker kills first, then allocates.
		delete(f.ctxs, old)
		delete(f.winCtx, d.WindowID)
	}
	if f.createLateErr != 0 {
		return f.createLateErr
	}
	if len(f.ctxs) >= f.maxCtx {
		return -vi.ErrENOSPC
	}
	f.gen++
	h := (f.gen << 16) | f.gen
	f.ctxs[h] = &fakeGpuCtx{handle: h, win: d.WindowID, ew: d.Width, eh: d.Height}
	f.winCtx[d.WindowID] = h
	return int64(h)
}

func rgb565to888(v uint16) uint32 {
	r := uint32(v>>11&0x1f) * 255 / 31
	g := uint32(v>>5&0x3f) * 255 / 63
	b := uint32(v&0x1f) * 255 / 31
	return r<<16 | g<<8 | b
}

// render produces the completed frame for the context's staged ops: the
// clear colour everywhere and the triangle's axis-aligned bounding box in
// its first vertex colour — deterministic, so a published pixel has one
// expected value per table row.
func (f *fakeBroker) render(c *fakeGpuCtx, v [3]vi.Gpu3dVertex) []uint32 {
	px := make([]uint32, c.ew*c.eh)
	for i := range px {
		px[i] = 0xff000000 | c.clear
	}
	norm := func(i int16, extent uint32) uint32 {
		u := uint32(uint16(i) + 0x8000)
		r := u * extent / 0x10000
		if r >= extent {
			r = extent - 1
		}
		return r
	}
	x0, x1 := c.ew, uint32(0)
	y0, y1 := c.eh, uint32(0)
	for _, vert := range v {
		x, y := norm(vert.X, c.ew), norm(vert.Y, c.eh)
		if x < x0 {
			x0 = x
		}
		if x > x1 {
			x1 = x
		}
		if y < y0 {
			y0 = y
		}
		if y > y1 {
			y1 = y
		}
	}
	for y := y0; y <= y1 && y < c.eh; y++ {
		for x := x0; x <= x1 && x < c.ew; x++ {
			px[y*c.ew+x] = 0xff000000 | rgb565to888(v[0].RGB)
		}
	}
	return px
}

func (f *fakeBroker) dispatch(d vi.Gpu3dDesc) int64 {
	switch d.Op {
	case vi.Gpu3dOpCreate:
		return f.create(d)
	case vi.Gpu3dOpClear:
		c, code := f.verify(d)
		if code != 0 {
			return code
		}
		c.clear = d.RGB
		return 0
	case vi.Gpu3dOpTriangle:
		c, code := f.verify(d)
		if code != 0 {
			return code
		}
		c.verts, c.hasTri = d.Verts, true
		return 0
	case vi.Gpu3dOpPresent:
		c, code := f.verify(d)
		if code != 0 {
			return code
		}
		if f.presentErr != 0 {
			return f.presentErr
		}
		// PRESENT waits out the render and stages the newest completed
		// frame — the last TRIANGLE's draw, or the clear colour when the
		// app presented nothing.
		var v [3]vi.Gpu3dVertex
		if c.hasTri {
			v = c.verts
		}
		c.staged = f.render(c, v)
		return 0
	case vi.Gpu3dOpPoll:
		c, code := f.verify(d)
		if code != 0 {
			return code
		}
		if f.pollSet {
			return f.pollRes
		}
		if c.staged == nil {
			return -vi.ErrEAGAIN
		}
		return 1
	case vi.Gpu3dOpPublish:
		c, code := f.verify(d)
		if code != 0 {
			return code
		}
		w := f.wins[d.WindowID]
		if w == nil {
			return -vi.ErrENOENT
		}
		if w.w != d.Width || w.h != d.Height {
			return -vi.ErrEINVAL // stale captured geometry
		}
		if c.staged == nil {
			return -vi.ErrEAGAIN
		}
		cw, ch := min(c.ew, w.w), min(c.eh, w.h)
		if cw < w.w || ch < w.h {
			// The copy is bounded: the uncovered band takes the clear
			// colour through the ordinary fill, never left stale.
			for y := 0; y < int(w.h); y++ {
				for x := int(cw); x < int(w.w); x++ {
					w.surf[y*int(w.w)+x] = 0xff000000 | c.clear
				}
			}
			for y := int(ch); y < int(w.h); y++ {
				for x := 0; x < int(cw); x++ {
					w.surf[y*int(w.w)+x] = 0xff000000 | c.clear
				}
			}
		}
		for y := 0; y < int(ch); y++ {
			copy(w.surf[y*int(w.w):][:cw], c.staged[y*int(c.ew):][:cw])
		}
		w.damages++
		return 0
	case vi.Gpu3dOpClose:
		if _, code := f.verify(d); code != 0 {
			return code
		}
		delete(f.ctxs, d.Handle)
		if f.winCtx[d.WindowID] == d.Handle {
			delete(f.winCtx, d.WindowID)
		}
		return 0
	}
	return -vi.ErrEINVAL
}

func (f *fakeBroker) opCount(op uint32) int {
	n := 0
	for _, c := range f.calls {
		if c.Op == op {
			n++
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// The seat harness.
// ---------------------------------------------------------------------------

// gpu3dSeat stubs the kernel seams (broker, reply send, log, descriptor
// page) and resets the record/mirror tables.
type gpu3dSeat struct {
	broker *fakeBroker
	acks   []vi.WmRpc
	logs   []string
}

func stubGpu3d(t *testing.T, b *fakeBroker) *gpu3dSeat {
	t.Helper()
	s := &gpu3dSeat{broker: b}
	prevBroker, prevSend, prevLog, prevMap := gpu3dBroker, gpu3dSend, gpu3dLog, gpu3dDescMap
	prevBuf, prevRecs, prevRects := gpu3dDescBuf, gpu3dRecs, gpu3dRects
	gpu3dDescBuf = nil
	gpu3dDescMap = func() ([]byte, error) { return make([]byte, vi.PageSize), nil }
	gpu3dBroker = func(desc []byte) int64 {
		if len(desc) != vi.Gpu3dDescBytes {
			t.Fatalf("broker saw %d descriptor bytes, want %d", len(desc), vi.Gpu3dDescBytes)
		}
		d := vi.Gpu3dDesc{
			Op:       binary.LittleEndian.Uint32(desc[0:]),
			Handle:   binary.LittleEndian.Uint64(desc[8:]),
			WindowID: binary.LittleEndian.Uint32(desc[16:]),
			Width:    binary.LittleEndian.Uint32(desc[20:]),
			Height:   binary.LittleEndian.Uint32(desc[24:]),
			RGB:      binary.LittleEndian.Uint32(desc[28:]),
		}
		for i := range d.Verts {
			o := 32 + 8*i
			d.Verts[i] = vi.Gpu3dVertex{
				X:   int16(binary.LittleEndian.Uint16(desc[o:])),
				Y:   int16(binary.LittleEndian.Uint16(desc[o+2:])),
				Z:   binary.LittleEndian.Uint16(desc[o+4:]),
				RGB: binary.LittleEndian.Uint16(desc[o+6:]),
			}
		}
		b.calls = append(b.calls, d)
		return b.dispatch(d)
	}
	gpu3dSend = func(_ uint32, buf []byte) int64 {
		rep, ok := vi.DecodeWmRpc(buf)
		if !ok {
			t.Fatalf("seat sent an undecodable kind-17 ack %x", buf)
		}
		s.acks = append(s.acks, rep)
		return int64(len(buf))
	}
	gpu3dLog = func(line string) { s.logs = append(s.logs, line) }
	gpu3dRecs = [gpu3dMaxRecs]gpu3dRec{}
	gpu3dRects = [256]uint32{}
	dropAllRpcBindings()
	t.Cleanup(func() {
		gpu3dBroker, gpu3dSend, gpu3dLog, gpu3dDescMap = prevBroker, prevSend, prevLog, prevMap
		gpu3dDescBuf, gpu3dRecs, gpu3dRects = prevBuf, prevRecs, prevRects
		dropAllRpcBindings()
	})
	return s
}

// gpu3dReq builds one authenticated kind-17 request frame.
func gpu3dReq(id, pid, seq, op uint8, payload [gpu3d.PayloadBytes]byte, token uint64) vi.WmRpc {
	req := vi.WmRpc{Kind: vi.WmRpcKindGpu3d, ID: id, Seq: seq, ReplyTo: pid,
		Applied: op, Pad: vi.WmRpcPadBound, Title: payload}
	vi.SetWmAuth(&req, token)
	return req
}

// drive services one request directly and decodes the reply it earns.
func (s *gpu3dSeat) drive(t *testing.T, req vi.WmRpc) gpu3d.Reply {
	t.Helper()
	before := len(s.acks)
	serveGpu3d(req, vi.WmAuth(req))
	if len(s.acks) != before+1 {
		t.Fatalf("kind-17 request earned %d replies, want 1", len(s.acks)-before)
	}
	rep := s.acks[len(s.acks)-1]
	if rep.Kind != vi.WmRpcKindGpu3d|vi.WmRpcReplyFlag ||
		rep.ID != req.ID || rep.Seq != req.Seq || rep.ReplyTo != req.ReplyTo ||
		rep.Pad != vi.WmRpcPadBound || vi.WmAuth(rep) != vi.WmAuth(req) {
		t.Fatalf("ack shape = %+v", rep)
	}
	r, err := gpu3d.DecodeReply(rep.Title)
	if err != nil {
		t.Fatalf("undecodable reply payload: %v", err)
	}
	return r
}

func (s *gpu3dSeat) bind(id uint8, pid uint8, token uint64) {
	rpcBindings[id] = rpcBinding{pid: pid, token: token}
}

// compWin is one window in the composition oracle: its kernel surface plus
// where the chrome band and client area land on the scanout.
type compWin struct {
	win    *fakeGpuWin
	x, y   int
	chrome uint32
}

const compChromeH = 8

// compScanout composes the windows the way the kernel's ordinary path does:
// desktop fill, then per window in z order the chrome band and the client
// surface blit — fully opaque, nothing premultiplied or scaled.
func compScanout(w, h int, desktop uint32, ws []compWin) []uint32 {
	fb := make([]uint32, w*h)
	for i := range fb {
		fb[i] = desktop
	}
	for _, c := range ws {
		for y := 0; y < compChromeH; y++ {
			for x := 0; x < int(c.win.w); x++ {
				fb[(c.y+y)*w+c.x+x] = 0xff000000 | c.chrome
			}
		}
		for y := 0; y < int(c.win.h); y++ {
			copy(fb[(c.y+compChromeH+y)*w+c.x:][:c.win.w],
				c.win.surf[y*int(c.win.w):])
		}
	}
	return fb
}

// ---------------------------------------------------------------------------
// Authentication: kind 17 rides the same gate as every other bound kind.
// ---------------------------------------------------------------------------

// The card's zero-broker-call table: a frame the gate refuses must never
// reach the broker — invalid token, a reply_to the binding did not prove,
// an unbound window, and a binding the window's death retired.
func TestGpu3dForgedFramesNeverReachBroker(t *testing.T) {
	b := newFakeBroker(nil)
	stubGpu3d(t, b)
	stubAuthSeams(t, func(uint8) (string, bool) { return "", false })

	const tok = 0x5afe1234
	rpcBindings[4] = rpcBinding{pid: 7, token: tok}

	open := gpu3d.PayloadOpen(64, 48)
	frames := [][]byte{
		// Wrong session token.
		gpu3dReq(4, 7, 1, gpu3d.OpOpen, open, tok^0xff).Encode(),
		// Forged reply_to: a pid the binding never proved.
		gpu3dReq(4, 9, 2, gpu3d.OpOpen, open, tok).Encode(),
		// Unbound window: a kind-17 frame draws the ordinary challenge.
		gpu3dReq(5, 7, 3, gpu3d.OpOpen, open, tok).Encode(),
	}
	acks := decodeAcks(t, serveWmRpcFrames(t, frames))
	if len(acks) != 3 {
		t.Fatalf("acks = %d want 3", len(acks))
	}
	if acks[0].Pad != vi.WmRpcPadPlain || acks[0].Applied != 0 {
		t.Fatalf("wrong-token ack = %+v want bare refusal", acks[0])
	}
	if acks[1].Pad != vi.WmRpcPadPlain || acks[1].Applied != 0 {
		t.Fatalf("forged-pid ack = %+v want bare refusal", acks[1])
	}
	if acks[2].Pad != vi.WmRpcPadChallenge || acks[2].Applied != 0 {
		t.Fatalf("unbound ack = %+v want challenge", acks[2])
	}
	if len(b.calls) != 0 {
		t.Fatalf("refused frames reached the broker: %d calls", len(b.calls))
	}

	// Reused binding: the window dies and rebinds under a new session;
	// the old credentials are ashes — refused before the broker.
	dropAllRpcBindings()
	rpcBindings[4] = rpcBinding{pid: 8, token: 0x9ead}
	stale := gpu3dReq(4, 7, 4, gpu3d.OpOpen, open, tok).Encode()
	wrongSess := gpu3dReq(4, 8, 5, gpu3d.OpOpen, open, tok).Encode()
	acks = decodeAcks(t, serveWmRpcFrames(t, [][]byte{stale, wrongSess}))
	if len(acks) != 2 || acks[0].Applied != 0 || acks[1].Applied != 0 {
		t.Fatalf("reused-binding acks = %+v want refusals", acks)
	}
	if len(b.calls) != 0 {
		t.Fatalf("dead-session frames reached the broker: %d calls", len(b.calls))
	}
}

// A malformed payload on a valid binding is a named refusal, still zero
// broker calls.
func TestGpu3dMalformedPayloadIsNamedRefusal(t *testing.T) {
	b := newFakeBroker(nil)
	s := stubGpu3d(t, b)
	s.bind(4, 7, 0x5afe)

	bad := gpu3d.PayloadOpen(64, 48)
	bad[9] = 1 // nonzero reserved byte
	r := s.drive(t, gpu3dReq(4, 7, 1, gpu3d.OpOpen, bad, 0x5afe))
	if r.Status != gpu3d.StatusInvalid {
		t.Fatalf("status = %d want Invalid", r.Status)
	}
	if len(b.calls) != 0 {
		t.Fatalf("malformed frame reached the broker: %d calls", len(b.calls))
	}
	// An unknown opcode the same way.
	r = s.drive(t, gpu3dReq(4, 7, 2, 9, gpu3d.PayloadEmpty(), 0x5afe))
	if r.Status != gpu3d.StatusInvalid || len(b.calls) != 0 {
		t.Fatalf("unknown op: status %d calls %d", r.Status, len(b.calls))
	}
}

// ---------------------------------------------------------------------------
// The happy path and the publish contract.
// ---------------------------------------------------------------------------

var gpu3dVerts = [3]gpu3d.Vertex{
	{X: -0x8000, Y: -0x8000, RGB: 0x07e0}, // green — full left/top
	{X: 0x7fff, Y: -0x8000, RGB: 0x07e0},
	{X: 0x7fff, Y: 0x7fff, RGB: 0x07e0},
}

func packWH(w, h uint32) uint32 { return w | h<<16 }

// A completed frame publishes exactly once into the window's surface: the
// full OPEN→CLEAR→TRIANGLE→PRESENT→POLL flow, then a second POLL that sees
// the same staged frame must not re-copy it.
func TestGpu3dPublishOnceThenSteady(t *testing.T) {
	win := newFakeWin(64, 48, 0xff101010)
	b := newFakeBroker(map[uint32]*fakeGpuWin{4: win})
	s := stubGpu3d(t, b)
	s.bind(4, 7, 0x5afe)
	gpu3dRects[4] = packWH(64, 48)

	r := s.drive(t, gpu3dReq(4, 7, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(64, 48), 0x5afe))
	if r.Status != gpu3d.StatusOK {
		t.Fatalf("OPEN status = %d", r.Status)
	}
	if b.opCount(vi.Gpu3dOpCreate) != 1 {
		t.Fatal("OPEN did not create a context")
	}
	s.drive(t, gpu3dReq(4, 7, 2, gpu3d.OpClear, gpu3d.PayloadClear(0x203040), 0x5afe))
	s.drive(t, gpu3dReq(4, 7, 3, gpu3d.OpTriangle, gpu3d.PayloadTriangle(gpu3dVerts), 0x5afe))
	r = s.drive(t, gpu3dReq(4, 7, 4, gpu3d.OpPresent, gpu3d.PayloadEmpty(), 0x5afe))
	if r.Frame != 1 {
		t.Fatalf("PRESENT frame = %d want 1", r.Frame)
	}

	// POLL stages the completed frame and triggers the one PUBLISH.
	r = s.drive(t, gpu3dReq(4, 7, 5, gpu3d.OpPoll, gpu3d.PayloadEmpty(), 0x5afe))
	if !r.Staged || r.Status != gpu3d.StatusOK {
		t.Fatalf("POLL reply = %+v want staged ok", r)
	}
	if b.opCount(vi.Gpu3dOpPublish) != 1 {
		t.Fatalf("publishes = %d want 1", b.opCount(vi.Gpu3dOpPublish))
	}
	pub := b.calls[len(b.calls)-1]
	if pub.Width != 64 || pub.Height != 48 || pub.WindowID != 4 {
		t.Fatalf("PUBLISH geometry = %dx%d win %d", pub.Width, pub.Height, pub.WindowID)
	}
	want := 0xff000000 | rgb565to888(0x07e0)
	for i, px := range win.surf {
		if px != want {
			t.Fatalf("surface pixel %d = %#x want %#x", i, px, want)
		}
	}

	// The same staged frame polls again — reported staged, never re-published.
	r = s.drive(t, gpu3dReq(4, 7, 6, gpu3d.OpPoll, gpu3d.PayloadEmpty(), 0x5afe))
	if !r.Staged || b.opCount(vi.Gpu3dOpPublish) != 1 {
		t.Fatalf("second poll re-published: %+v publishes %d", r, b.opCount(vi.Gpu3dOpPublish))
	}

	// The marker is earned by the composite tick's real present, not the
	// publish or the fence.
	if countPresented(s.logs) != 0 {
		t.Fatalf("presented logged before a present: %v", s.logs)
	}
	gpu3dPresented(false)
	if countPresented(s.logs) != 0 {
		t.Fatal("a failed present earned the marker")
	}
	gpu3dPresented(true)
	gpu3dPresented(true) // a second present must not double-log
	if n := countPresented(s.logs); n != 1 {
		t.Fatalf("presented markers = %d want exactly 1 (logs %v)", n, s.logs)
	}
}

func countPresented(logs []string) int {
	n := 0
	for _, l := range logs {
		if len(l) >= len(MarkerGpu3dPresented) &&
			l[:len(MarkerGpu3dPresented)] == MarkerGpu3dPresented {
			n++
		}
	}
	return n
}

// Pending, errored and never-completed polls never publish — the surface
// keeps the last completed frame.
func TestGpu3dPendingAndErrorsKeepLastFrame(t *testing.T) {
	win := newFakeWin(64, 48, 0xff101010)
	b := newFakeBroker(map[uint32]*fakeGpuWin{4: win})
	s := stubGpu3d(t, b)
	s.bind(4, 7, 0x5afe)
	gpu3dRects[4] = packWH(64, 48)

	s.drive(t, gpu3dReq(4, 7, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(64, 48), 0x5afe))
	s.drive(t, gpu3dReq(4, 7, 2, gpu3d.OpClear, gpu3d.PayloadClear(0x203040), 0x5afe))
	s.drive(t, gpu3dReq(4, 7, 3, gpu3d.OpTriangle, gpu3d.PayloadTriangle(gpu3dVerts), 0x5afe))
	s.drive(t, gpu3dReq(4, 7, 4, gpu3d.OpPresent, gpu3d.PayloadEmpty(), 0x5afe))
	s.drive(t, gpu3dReq(4, 7, 5, gpu3d.OpPoll, gpu3d.PayloadEmpty(), 0x5afe))
	saved := append([]uint32(nil), win.surf...)

	// A new frame still on the fence: the last completed surface stands.
	b.pollSet, b.pollRes = true, 0
	r := s.drive(t, gpu3dReq(4, 7, 6, gpu3d.OpPoll, gpu3d.PayloadEmpty(), 0x5afe))
	if r.Staged {
		t.Fatal("pending poll reported staged")
	}
	// A device fault mid-poll: the named error, still no publish. The vi
	// errno table has no EIO — an unmapped magnitude lands on DeviceFault.
	b.pollRes = -99
	r = s.drive(t, gpu3dReq(4, 7, 7, gpu3d.OpPoll, gpu3d.PayloadEmpty(), 0x5afe))
	if r.Status != gpu3d.StatusDeviceFault {
		t.Fatalf("fault poll status = %d want DeviceFault", r.Status)
	}
	b.pollSet = false
	for i, px := range win.surf {
		if px != saved[i] {
			t.Fatalf("pending/error publish touched pixel %d", i)
		}
	}
	if b.opCount(vi.Gpu3dOpPublish) != 1 {
		t.Fatalf("publishes = %d want still 1", b.opCount(vi.Gpu3dOpPublish))
	}
}

// A WM layout change refreshes the publish geometry: the next POLL after a
// resize carries the new rect, the kernel clips the bounded image into it,
// and a stale capture is a named refusal that paints nothing.
func TestGpu3dLayoutChangeClipsBoundedImage(t *testing.T) {
	win := newFakeWin(64, 48, 0xff101010)
	b := newFakeBroker(map[uint32]*fakeGpuWin{4: win})
	s := stubGpu3d(t, b)
	s.bind(4, 7, 0x5afe)
	gpu3dRects[4] = packWH(64, 48)

	s.drive(t, gpu3dReq(4, 7, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(64, 48), 0x5afe))
	s.drive(t, gpu3dReq(4, 7, 2, gpu3d.OpTriangle, gpu3d.PayloadTriangle(gpu3dVerts), 0x5afe))
	s.drive(t, gpu3dReq(4, 7, 3, gpu3d.OpPresent, gpu3d.PayloadEmpty(), 0x5afe))

	// The layout shrinks the window before the poll: the mirror has not
	// caught up, so the captured extent is stale — a named refusal, no
	// paint, then the refreshed mirror publishes clipped.
	win.resize(40, 32, 0xff101010)
	r := s.drive(t, gpu3dReq(4, 7, 4, gpu3d.OpPoll, gpu3d.PayloadEmpty(), 0x5afe))
	if r.Staged {
		t.Fatal("stale-geometry publish reported staged")
	}
	if win.damages != 0 {
		t.Fatal("stale publish painted")
	}
	gpu3dRects[4] = packWH(40, 32)
	r = s.drive(t, gpu3dReq(4, 7, 5, gpu3d.OpPoll, gpu3d.PayloadEmpty(), 0x5afe))
	if !r.Staged {
		t.Fatal("refreshed poll did not publish")
	}
	pub := b.calls[len(b.calls)-1]
	if pub.Width != 40 || pub.Height != 32 {
		t.Fatalf("PUBLISH carried %dx%d want the live 40x32", pub.Width, pub.Height)
	}
	want := 0xff000000 | rgb565to888(0x07e0)
	for y := 0; y < 32; y++ {
		for x := 0; x < 40; x++ {
			if win.surf[y*40+x] != want {
				t.Fatalf("clipped pixel %d,%d = %#x", x, y, win.surf[y*40+x])
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Composition: a completed GPU surface is an ordinary opaque window surface.
// ---------------------------------------------------------------------------

// The card's composition table: a published GPU surface composed beside and
// behind ordinary 2D surfaces — exact clipped pixels, opaque alpha, the
// chrome band above the client, and every guard pixel outside the
// destination rectangles unchanged.
func TestGpu3dComposesBesideAndBehind2D(t *testing.T) {
	const (
		desktop = 0xff0c0c14
		fill2D  = 0xff303050
	)
	win4 := newFakeWin(64, 48, fill2D) // the 3D window's ordinary surface
	win5 := newFakeWin(40, 40, fill2D) // a plain 2D neighbour
	b := newFakeBroker(map[uint32]*fakeGpuWin{4: win4, 5: win5})
	s := stubGpu3d(t, b)
	s.bind(4, 7, 0x5afe)
	gpu3dRects[4] = packWH(64, 48)

	// The window had 2D content; the completed GPU frame publishes into
	// the same ordinary surface.
	s.drive(t, gpu3dReq(4, 7, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(64, 48), 0x5afe))
	s.drive(t, gpu3dReq(4, 7, 2, gpu3d.OpClear, gpu3d.PayloadClear(0x102030), 0x5afe))
	tri := [3]gpu3d.Vertex{
		{X: -0x4000, Y: -0x4000, RGB: 0xf800},
		{X: 0x3fff, Y: -0x4000, RGB: 0xf800},
		{X: 0x3fff, Y: 0x3fff, RGB: 0xf800},
	}
	s.drive(t, gpu3dReq(4, 7, 3, gpu3d.OpTriangle, gpu3d.PayloadTriangle(tri), 0x5afe))
	s.drive(t, gpu3dReq(4, 7, 4, gpu3d.OpPresent, gpu3d.PayloadEmpty(), 0x5afe))
	r := s.drive(t, gpu3dReq(4, 7, 5, gpu3d.OpPoll, gpu3d.PayloadEmpty(), 0x5afe))
	if !r.Staged {
		t.Fatal("frame did not publish")
	}

	triRGB := 0xff000000 | rgb565to888(0xf800)
	// Inside the published surface: the triangle's bbox is rendered, the
	// rest is the clear colour, every pixel opaque.
	norm := func(i int16, extent uint32) uint32 {
		u := uint32(uint16(i) + 0x8000)
		x := u * extent / 0x10000
		if x >= extent {
			x = extent - 1
		}
		return x
	}
	x0, x1 := norm(-0x4000, 64), norm(0x3fff, 64)
	y0, y1 := norm(-0x4000, 48), norm(0x3fff, 48)
	for y := uint32(0); y < 48; y++ {
		for x := uint32(0); x < 64; x++ {
			got := win4.surf[y*64+x]
			want := uint32(0xff000000 | 0x102030)
			if x >= x0 && x <= x1 && y >= y0 && y <= y1 {
				want = triRGB
			}
			if got != want {
				t.Fatalf("surface %d,%d = %#x want %#x", x, y, got, want)
			}
			if got>>24 != 0xff {
				t.Fatalf("surface %d,%d is not opaque: %#x", x, y, got)
			}
		}
	}

	// Composed beside/behind: win4 at (16,16), win5 overlapping it at
	// (40,40) on top. z order: win4 then win5 — win5's surface occludes
	// where they overlap; win4's GPU pixels show through beside it; the
	// chrome band above each client never takes a GPU pixel.
	fb := compScanout(128, 96, desktop, []compWin{
		{win: win4, x: 16, y: 16, chrome: 0x804040},
		{win: win5, x: 40, y: 40, chrome: 0x408040},
	})
	at := func(x, y int) uint32 { return fb[y*128+x] }
	// Guards: outside every destination rectangle stays the desktop.
	for _, p := range [][2]int{{0, 0}, {127, 0}, {0, 95}, {127, 95}, {15, 50}, {90, 20}} {
		if at(p[0], p[1]) != desktop {
			t.Fatalf("guard pixel %d,%d = %#x want desktop %#x", p[0], p[1], at(p[0], p[1]), desktop)
		}
	}
	// Chrome bands: win4's title row and win5's, chrome colour only.
	for x := 16; x < 80; x++ {
		if at(x, 16) != 0xff804040 {
			t.Fatalf("win4 chrome %d = %#x", x, at(x, 16))
		}
	}
	for x := 40; x < 80; x++ {
		if at(x, 40) != 0xff408040 {
			t.Fatalf("win5 chrome %d = %#x", x, at(x, 40))
		}
	}
	// Beside: win4's client left of win5's rect shows the GPU clear colour
	// (x<16+16 → outside triangle bbox's column range in the client? use a
	// definite clear pixel and a definite triangle pixel).
	if at(17, 25) != 0xff102030 { // client (1,1): left of the triangle bbox
		t.Fatalf("win4 clear pixel = %#x", at(17, 25))
	}
	if at(16+int(x0), 16+compChromeH+int(y0)) != triRGB {
		t.Fatalf("win4 triangle pixel = %#x", at(16+int(x0), 16+compChromeH+int(y0)))
	}
	// Behind: inside win5's footprint, win5's 2D pixels win the overlap.
	if at(41, 41+compChromeH) != fill2D {
		t.Fatalf("occluded pixel = %#x want win5 fill %#x", at(41, 41+compChromeH), fill2D)
	}
}

// ---------------------------------------------------------------------------
// Lifetime, the pool bound, and reuse.
// ---------------------------------------------------------------------------

// Two live contexts exhaust the pool: a third window's OPEN is the named
// Exhausted refusal with zero broker calls, and the live contexts still
// drive.
func TestGpu3dThirdContextIsRefused(t *testing.T) {
	b := newFakeBroker(map[uint32]*fakeGpuWin{
		4: newFakeWin(32, 24, 0),
		5: newFakeWin(32, 24, 0),
		6: newFakeWin(32, 24, 0),
	})
	s := stubGpu3d(t, b)
	s.bind(4, 7, 0x1111)
	s.bind(5, 8, 0x2222)
	s.bind(6, 9, 0x3333)
	for _, w := range []uint8{4, 5, 6} {
		gpu3dRects[w] = packWH(32, 24)
	}

	s.drive(t, gpu3dReq(4, 7, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(32, 24), 0x1111))
	s.drive(t, gpu3dReq(5, 8, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(32, 24), 0x2222))
	calls := len(b.calls)
	r := s.drive(t, gpu3dReq(6, 9, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(32, 24), 0x3333))
	if r.Status != gpu3d.StatusExhausted {
		t.Fatalf("third OPEN status = %d want Exhausted", r.Status)
	}
	if len(b.calls) != calls {
		t.Fatal("the refused OPEN reached the broker")
	}
	// The existing contexts are untouched and still serve.
	r = s.drive(t, gpu3dReq(4, 7, 2, gpu3d.OpClear, gpu3d.PayloadClear(1), 0x1111))
	if r.Status != gpu3d.StatusOK {
		t.Fatalf("live context broken by the refusal: %d", r.Status)
	}
}

// Closing the focused 3D window drops the binding, closes the context
// through the broker, and returns focus to the remaining tab.
func TestGpu3dCloseReleasesContextAndRestoresFocus(t *testing.T) {
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}
	if !tabs.OpenTab(5, "other") || !tabs.OpenTab(4, "gpu") {
		t.Fatal("OpenTab")
	}
	tabs.FocusTab(4)

	b := newFakeBroker(map[uint32]*fakeGpuWin{4: newFakeWin(32, 24, 0)})
	s := stubGpu3d(t, b)
	s.bind(4, 7, 0x5afe)
	gpu3dRects[4] = packWH(32, 24)
	s.drive(t, gpu3dReq(4, 7, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(32, 24), 0x5afe))
	if len(b.ctxs) != 1 {
		t.Fatal("no live context")
	}

	if !tabs.CloseTab(4) {
		t.Fatal("CloseTab")
	}
	if b.opCount(vi.Gpu3dOpClose) != 1 {
		t.Fatalf("window close did not close the context: %d closes",
			b.opCount(vi.Gpu3dOpClose))
	}
	if len(b.ctxs) != 0 {
		t.Fatal("broker still holds the context")
	}
	if gpu3dLiveRec(4) != nil {
		t.Fatal("seat kept a record for the dead window")
	}
	if id, ok := tabs.Focused(); !ok || id != 5 {
		t.Fatalf("focus = %v,%v want 5,true — ordinary focus not restored", id, ok)
	}
}

// A released-mirror event (the kernel's own window teardown) runs the same
// funnel: rect forgotten, context closed.
func TestGpu3dReleasedMirrorClosesContext(t *testing.T) {
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}

	b := newFakeBroker(map[uint32]*fakeGpuWin{4: newFakeWin(32, 24, 0)})
	s := stubGpu3d(t, b)
	s.bind(4, 7, 0x5afe)
	gpu3dRects[4] = packWH(32, 24)
	s.drive(t, gpu3dReq(4, 7, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(32, 24), 0x5afe))

	consumeSeatEvent(vi.Event{Kind: vi.EvWmWindow, Flags: 4 | (1 << 13)})
	if gpu3dRects[4] != 0 {
		t.Fatal("released window kept a mirrored extent")
	}
	if b.opCount(vi.Gpu3dOpClose) != 1 || len(b.ctxs) != 0 {
		t.Fatal("released mirror did not close the context")
	}
}

// A reused window id cannot drive a dead context: the new binding finds no
// record, and the stale staged frame in the dead kernel context never
// paints the new window's surface.
func TestGpu3dReusedIDCannotPaintStaleFrame(t *testing.T) {
	win := newFakeWin(32, 24, 0xff101010)
	b := newFakeBroker(map[uint32]*fakeGpuWin{4: win})
	s := stubGpu3d(t, b)
	s.bind(4, 7, 0x5afe)
	gpu3dRects[4] = packWH(32, 24)
	s.drive(t, gpu3dReq(4, 7, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(32, 24), 0x5afe))
	s.drive(t, gpu3dReq(4, 7, 2, gpu3d.OpTriangle, gpu3d.PayloadTriangle(gpu3dVerts), 0x5afe))
	s.drive(t, gpu3dReq(4, 7, 3, gpu3d.OpPresent, gpu3d.PayloadEmpty(), 0x5afe))

	// The window dies mid-flight (a completed frame staged, never polled)
	// and the id is reused by a new bound session.
	dropRpcBinding(4)
	s.bind(4, 9, 0xfeed)
	r := s.drive(t, gpu3dReq(4, 9, 1, gpu3d.OpPoll, gpu3d.PayloadEmpty(), 0xfeed))
	if r.Status != gpu3d.StatusBadHandle {
		t.Fatalf("reused-id poll status = %d want BadHandle", r.Status)
	}
	if b.opCount(vi.Gpu3dOpPublish) != 0 {
		t.Fatal("a dead generation's frame published into the reused window")
	}
	for i, px := range win.surf {
		if px != 0xff101010 {
			t.Fatalf("reused window's surface pixel %d painted", i)
		}
	}
}

// A render-extent change revokes the old generation before the new one
// exists: the broker hands back a new handle and the seat's record drives
// only it.
func TestGpu3dExtentChangeRegenerates(t *testing.T) {
	win := newFakeWin(64, 48, 0)
	b := newFakeBroker(map[uint32]*fakeGpuWin{4: win})
	s := stubGpu3d(t, b)
	s.bind(4, 7, 0x5afe)
	gpu3dRects[4] = packWH(64, 48)

	s.drive(t, gpu3dReq(4, 7, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(64, 48), 0x5afe))
	old := b.winCtx[4]

	r := s.drive(t, gpu3dReq(4, 7, 2, gpu3d.OpOpen, gpu3d.PayloadOpen(40, 30), 0x5afe))
	if r.Status != gpu3d.StatusOK {
		t.Fatalf("extent-change OPEN status = %d", r.Status)
	}
	if b.winCtx[4] == old {
		t.Fatal("extent change kept the old generation")
	}
	if _, live := b.ctxs[old]; live {
		t.Fatal("old generation still live after the extent change")
	}
	if gpu3dRecs[0].w != 40 || gpu3dRecs[0].h != 30 {
		t.Fatalf("record extent = %dx%d want 40x30", gpu3dRecs[0].w, gpu3dRecs[0].h)
	}
}

// An extent-change re-open that fails leaves the old generation revoked —
// the record dies and further ops are named BadHandle without broker calls.
func TestGpu3dFailedReopenDropsDeadRecord(t *testing.T) {
	b := newFakeBroker(map[uint32]*fakeGpuWin{4: newFakeWin(64, 48, 0)})
	s := stubGpu3d(t, b)
	s.bind(4, 7, 0x5afe)
	gpu3dRects[4] = packWH(64, 48)
	s.drive(t, gpu3dReq(4, 7, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(64, 48), 0x5afe))

	b.createLateErr = -99 // a device fault: unmapped errno → DeviceFault
	r := s.drive(t, gpu3dReq(4, 7, 2, gpu3d.OpOpen, gpu3d.PayloadOpen(40, 30), 0x5afe))
	if r.Status != gpu3d.StatusDeviceFault {
		t.Fatalf("failed re-open status = %d want DeviceFault", r.Status)
	}
	calls := len(b.calls)
	r = s.drive(t, gpu3dReq(4, 7, 3, gpu3d.OpClear, gpu3d.PayloadClear(0), 0x5afe))
	if r.Status != gpu3d.StatusBadHandle {
		t.Fatalf("dead record op status = %d want BadHandle", r.Status)
	}
	if len(b.calls) != calls {
		t.Fatal("the dead record still reached the broker")
	}
}

// WM shutdown closes every live context.
func TestGpu3dShutdownClosesAll(t *testing.T) {
	b := newFakeBroker(map[uint32]*fakeGpuWin{
		4: newFakeWin(32, 24, 0),
		5: newFakeWin(32, 24, 0),
	})
	s := stubGpu3d(t, b)
	s.bind(4, 7, 0x5afe)
	s.bind(5, 8, 0xbeef)
	gpu3dRects[4], gpu3dRects[5] = packWH(32, 24), packWH(32, 24)
	s.drive(t, gpu3dReq(4, 7, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(32, 24), 0x5afe))
	s.drive(t, gpu3dReq(5, 8, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(32, 24), 0xbeef))

	gpu3dCloseAll()
	if b.opCount(vi.Gpu3dOpClose) != 2 || len(b.ctxs) != 0 {
		t.Fatalf("shutdown left contexts: closes %d live %d",
			b.opCount(vi.Gpu3dOpClose), len(b.ctxs))
	}
	for i := range gpu3dRecs {
		if gpu3dRecs[i].live {
			t.Fatalf("record %d still live after shutdown", i)
		}
	}
}

// Unsupported extents are the seat's named refusal — zero broker calls.
func TestGpu3dUnsupportedExtentRefused(t *testing.T) {
	b := newFakeBroker(map[uint32]*fakeGpuWin{4: newFakeWin(64, 48, 0)})
	s := stubGpu3d(t, b)
	s.bind(4, 7, 0x5afe)
	for _, wh := range [][2]uint32{{0, 48}, {64, 0}, {gpu3d.MaxWidth + 1, 48}, {64, gpu3d.MaxHeight + 1}} {
		r := s.drive(t, gpu3dReq(4, 7, 1, gpu3d.OpOpen, gpu3d.PayloadOpen(wh[0], wh[1]), 0x5afe))
		if r.Status != gpu3d.StatusInvalid {
			t.Fatalf("OPEN %dx%d status = %d want Invalid", wh[0], wh[1], r.Status)
		}
	}
	if len(b.calls) != 0 {
		t.Fatalf("unsupported extents reached the broker: %d calls", len(b.calls))
	}
}
