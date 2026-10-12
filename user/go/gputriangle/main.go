// Command gputriangle (GPUTRIANGLE.ELF) — M102f1 (issue #2170): the bounded
// GPU3D demo app and receipt producer for the live-gpu3d acceptance gate.
//
// The app requests GPU work ONLY through the M102d2 gpu3d API — Open/Clear/
// Triangle/Present/Poll/Close over the authenticated WM_RPC kind-17 seam. It
// never rasterizes its own triangle, never touches a raw stream, and never
// claims pixels the seat did not publish. Its own shared-anon window surface
// (M33 win-tag bind, ADR 0016 seam B) is how the seat's PUBLISH reaches it:
// after Poll reports a staged frame the app reads back ONLY the bounded
// render extent out of its own mapping and exports it as a raw packed-BGRA
// receipt through the ordinary /host file seam. No pixel-read syscall, no
// new ABI.
//
// Receipts distinguish the three frame states the contract names:
//
//	submitted   — a kind-17 request the transport accepted (recorded op row)
//	completed   — a Present ack applied (device completion waited; carries
//	              the seat-minted frame counter from the reply payload)
//	published   — Poll staged AND the surface receipt exported; ONLY then
//	              does a marker say pixels are on screen
//
// Every receipt row carries the app's window generation (wgen, per window
// lifetime) and render generation (rgen, per context/extent) so close/reuse
// and resize runs can never pass an old frame off as new.
//
// Journeys (argv[1], default `triangle`):
//
//	triangle  window + surface + one 64x48 clear/red-triangle frame -> publish
//	mixed     larger window, render extent at the client origin, 2D-filled
//	          margins around it (ordinary CPU fill of OUR OWN surface margin
//	          only — the render destination is never CPU-painted)
//	resize    publish at 64x48, then close the context and re-open at 96x64:
//	          a new rgen with fresh receipts, proving extent change works
//	closereuse close ctx + window, open a NEW window (wgen=2), publish again
//	invalid   refused-call battery: out-of-cap geometry, wide RGB, op after
//	          close — named errors, NO success receipt
//	forged    publish, then emit a kind-17 frame with a wrong session token
//	          through the ordinary any-to-any mailbox, then prove the real
//	          session still completes (the seat must refuse the forgery)
//
// On a host without the render device Open returns gpu3d.ErrUnsupported and
// the app prints `gputri: unsupported` and exits WITHOUT writing a receipt —
// the native-only leg's honest answer.
//
// All platform contact goes through the `host` seam so `go test` runs every
// journey with injected fakes; the guest build wires it to vi.
package main

import (
	"context"
	"errors"
	"strconv"

	"virelai/gpu3d"
	"virelai/vi"
)

const (
	appName  = "GPUTRIANGLE.ELF"
	appTitle = "GPU Triangle"

	// Window + default render extent. The extent rides the private VIR1
	// bound (1..256 x 1..192); the window is a fixed modest rect.
	winX, winY         = 40, 32
	winW, winH         = 320, 240
	mixedWinW, mixedH  = 384, 288
	mixedExW, mixedExH = 96, 72 // mixed export rect: extent + margin ring
	extentW, extentH   = 64, 48
	resizeW, resizeH   = 96, 64
	clearRGB           = 0x102030
	marginRGB          = 0x4a3020
	forgedToken        = 0xdeadbeef
	maxPublishPolls    = 240
	maxIdleTicks       = 120
)

// The deterministic scene: a red right-ish triangle, asymmetric so a flipped
// or channel-swapped image is visible to the comparator. i16 normalized X/Y
// with Y up, u16 normalized Z, u16 RGB565 — the wire vertex, nothing else.
var sceneVerts = [3]gpu3d.Vertex{
	{X: -24576, Y: 21626, Z: 0, RGB: 0xf800},
	{X: 24576, Y: 5243, Z: 0, RGB: 0xf800},
	{X: -12288, Y: -21626, Z: 0, RGB: 0xf800},
}

const (
	receiptDir  = "/host/GPUTRI"
	receiptPath = receiptDir + "/RECEIPT.TSV"
)

// host is the injected app platform seam. The guest implementation rides
// vi; tests fake every call. Nothing below this interface may reach a
// syscall, a GPU stream or a pixel.
type host interface {
	OpenWindow(x, y, w, h uint32) (int, error)
	DeclareTab(win int, title string) bool
	// BindSurface creates+binds the window's M33 shared back-buffer and
	// returns the app's own writable view (stride = window width, BGRX).
	BindSurface(win int, w, h uint32) ([]byte, error)
	PresentWindow(win int) error
	PollEvent() (vi.Event, int64, bool)
	CloseWindow(win int)
	// MkdirShare creates a /host directory (EEXIST is not an error).
	MkdirShare(path string) error
	// WriteShareFile publishes bytes through the ordinary file seam.
	WriteShareFile(path string, b []byte) error
	ConsoleLine(s string)
	Sleep(ticks uint64)
	// Peers resolves the seat pid and this process's own pid for the
	// ordinary any-to-any mailbox (the forged-request journey).
	Peers() (wm uint32, self uint32, ok bool)
	IpcSend(target uint32, b []byte) int64
	// Transport returns the kind-17 transport for windowID; nil means the
	// production vi seam (viExchange below re-exposes its Trip so the app
	// can read the seat-minted frame counter).
	Transport() gpu3d.Transport
}

// --- receipts ----------------------------------------------------------------

// recorder accumulates the TSV receipt rows; a `published` row is only ever
// appended by publish(), so its presence IS the on-screen claim.
type recorder struct {
	rows []string
}

func (r *recorder) row(fields ...string) {
	line := ""
	for i, f := range fields {
		if i != 0 {
			line += "\t"
		}
		line += f
	}
	r.rows = append(r.rows, line)
}

func (r *recorder) body() []byte {
	out := ""
	for _, l := range r.rows {
		out += l + "\n"
	}
	return []byte(out)
}

// --- the app ------------------------------------------------------------------

type app struct {
	h     host
	rec   recorder
	win   int
	wgen  int
	rgen  int
	surf  []byte
	surfW uint32 // surface row stride in pixels (the window width)
}

// tripTransport wraps a gpu3d.Transport and keeps the last exchange's Trip
// so the seat-minted frame counter (reply payload) is readable. The app's
// six calls all land here first — it is also the submitted-op record.
type tripTransport struct {
	inner gpu3d.Transport
	trip  gpu3d.Trip
	ok    bool
}

func (t *tripTransport) Exchange(ctx context.Context, windowID uint32, op uint8, payload [gpu3d.PayloadBytes]byte) (gpu3d.Trip, error) {
	trip, err := t.inner.Exchange(ctx, windowID, op, payload)
	if err == nil {
		t.trip, t.ok = trip, true
	}
	return trip, err
}

// frame returns the frame counter of the last successful exchange's reply.
func (t *tripTransport) frame() uint32 {
	if !t.ok {
		return 0
	}
	rep, err := gpu3d.DecodeReply(t.trip.Ack.Title)
	if err != nil {
		return 0
	}
	return rep.Frame
}

// viExchange is the app's own binding to the production authenticated seam:
// vi.Gpu3dExchange already returns the full (req, ack, token) triple, so the
// app can record the genuine reply while gpu3d.Client still validates it.
type viExchange struct{ self string }

func (t viExchange) Exchange(_ context.Context, windowID uint32, op uint8, payload [gpu3d.PayloadBytes]byte) (gpu3d.Trip, error) {
	sent, ack, token, outcome := vi.Gpu3dExchange(windowID, op, payload, t.self)
	switch outcome {
	case vi.Gpu3dOutcomeOK:
		return gpu3d.Trip{Req: sent, Ack: ack, Token: token}, nil
	case vi.Gpu3dOutcomeTimeout:
		return gpu3d.Trip{}, gpu3d.ErrTimeout
	case vi.Gpu3dOutcomeRefused:
		return gpu3d.Trip{}, gpu3d.ErrRefused
	default:
		return gpu3d.Trip{}, gpu3d.ErrUnsupported
	}
}

func u32s(v uint32) string { return strconv.FormatUint(uint64(v), 10) }
func is(v int) string      { return strconv.Itoa(v) }

// transport returns the kind-17 transport for this window: the injected one
// under test, the production vi seam otherwise.
func (a *app) transport() gpu3d.Transport {
	if tr := a.h.Transport(); tr != nil {
		return tr
	}
	return viExchange{self: appName}
}

// openCtx opens a GPU3D context on the current window at extent w×h and
// bumps the render generation. The geometry refusal surfaces as the named
// error; no request reaches the wire for out-of-cap extents.
func (a *app) openCtx(w, h uint32) (*gpu3d.Client, *tripTransport, error) {
	tr := &tripTransport{inner: a.transport()}
	cl, err := gpu3d.OpenTransport(tr, uint32(a.win), w, h)
	if err != nil {
		return nil, nil, err
	}
	a.rgen++
	a.rec.row("submitted", is(a.wgen), is(a.rgen), "open")
	a.rec.row("ctx", is(a.wgen), is(a.rgen), u32s(w)+"x"+u32s(h))
	a.h.ConsoleLine("gputri: gpu open " + u32s(w) + "x" + u32s(h) + " gen=" + is(a.wgen) + "." + is(a.rgen))
	return cl, tr, nil
}

// errName maps a gpu3d error to its stable receipt/console token.
func errName(err error) string {
	switch {
	case errors.Is(err, gpu3d.ErrUnsupported):
		return "unsupported"
	case errors.Is(err, gpu3d.ErrInvalid):
		return "invalid"
	case errors.Is(err, gpu3d.ErrExhausted):
		return "exhausted"
	case errors.Is(err, gpu3d.ErrTimeout):
		return "timeout"
	case errors.Is(err, gpu3d.ErrLostContext):
		return "lost-context"
	case errors.Is(err, gpu3d.ErrBadHandle):
		return "bad-handle"
	case errors.Is(err, gpu3d.ErrDeviceFault):
		return "device-fault"
	case errors.Is(err, gpu3d.ErrPending):
		return "pending"
	case errors.Is(err, gpu3d.ErrClosed):
		return "closed"
	case errors.Is(err, gpu3d.ErrBusy):
		return "busy"
	case errors.Is(err, gpu3d.ErrProtocol):
		return "protocol"
	case errors.Is(err, gpu3d.ErrRefused):
		return "refused"
	case errors.Is(err, errUsage):
		return "usage"
	default:
		return "error"
	}
}

// op runs one named gpu3d call. A `submitted` receipt row is only recorded
// when a genuine exchange happened on the wire (tr.ok): a pre-wire refusal —
// bad geometry, a wide colour, a call on a closed client — is an `error` row
// with no submitted claim. The marker prints only after the call returned.
func (a *app) op(tr *tripTransport, name string, f func() error) error {
	tr.ok = false
	err := f()
	if tr.ok {
		a.rec.row("submitted", is(a.wgen), is(a.rgen), name)
	}
	if err != nil {
		a.rec.row("error", is(a.wgen), is(a.rgen), name, errName(err))
		a.h.ConsoleLine("gputri: refuse " + name + " " + errName(err))
		return err
	}
	a.h.ConsoleLine("gputri: " + name)
	return nil
}

// fillMargin paints the app's OWN surface outside the render destination
// [0,0,ew,eh) with the flat 2D margin colour. Plain stores only; the render
// destination itself is never written by the app.
func (a *app) fillMargin(ew, eh uint32) {
	b, g, r := byte(marginRGB&0xff), byte((marginRGB>>8)&0xff), byte((marginRGB>>16)&0xff)
	surfH := uint32(len(a.surf)) / a.surfW / 4
	put := func(x, y uint32) {
		o := (y*a.surfW + x) * 4
		a.surf[o], a.surf[o+1], a.surf[o+2], a.surf[o+3] = b, g, r, 0xff
	}
	for y := uint32(0); y < surfH; y++ {
		for x := ew; x < a.surfW; x++ {
			put(x, y)
		}
	}
	for y := eh; y < surfH; y++ {
		for x := uint32(0); x < ew; x++ {
			put(x, y)
		}
	}
}

// exportSurface copies the bounded render extent [0,0,ew,eh) out of the
// app's own surface mapping into a packed BGRA receipt (alpha forced opaque)
// and publishes it through the file seam. Called only after the seat has
// staged the completed frame — this is the published-pixel evidence, read
// back through the window mapping, never a GPU read. The receipt dir is
// created here (issue #2226): the first export runs before writeReceipts'
// own mkdir, so it cannot rely on it existing.
func (a *app) exportSurface(name string, ew, eh uint32) error {
	if a.surf == nil || ew == 0 || eh == 0 || ew > a.surfW ||
		uint64(eh)*uint64(a.surfW)*4 > uint64(len(a.surf)) {
		return errors.New("export geometry")
	}
	if err := a.h.MkdirShare(receiptDir); err != nil {
		return err
	}
	out := make([]byte, 0, int(ew*eh)*4)
	for y := uint32(0); y < eh; y++ {
		row := a.surf[y*a.surfW*4 : (y*a.surfW+ew)*4]
		out = append(out, row...)
	}
	// The surface is BGRX; the receipt is opaque BGRA.
	for i := 3; i < len(out); i += 4 {
		out[i] = 0xff
	}
	return a.h.WriteShareFile(receiptDir+"/"+name, out)
}

// publish waits (bounded) for the completed frame to be staged, then exports
// the surface receipt and emits the ONLY on-screen receipt/marker.
func (a *app) publish(cl *gpu3d.Client, tr *tripTransport, file string, ew, eh uint32) error {
	for i := 0; i < maxPublishPolls; i++ {
		staged, err := cl.Poll()
		a.rec.row("submitted", is(a.wgen), is(a.rgen), "poll")
		if err == nil && staged {
			if werr := a.exportSurface(file, ew, eh); werr != nil {
				a.rec.row("error", is(a.wgen), is(a.rgen), "publish", "write")
				return werr
			}
			a.rec.row("published", is(a.wgen), is(a.rgen), u32s(tr.frame()), file)
			a.h.ConsoleLine("gputri: published frame=" + u32s(tr.frame()) + " " + file)
			return nil
		}
		if err != nil && !errors.Is(err, gpu3d.ErrPending) {
			a.rec.row("error", is(a.wgen), is(a.rgen), "poll", errName(err))
			a.h.ConsoleLine("gputri: refuse poll " + errName(err))
			return err
		}
		a.h.Sleep(1)
	}
	a.rec.row("error", is(a.wgen), is(a.rgen), "publish", "pending")
	a.h.ConsoleLine("gputri: refuse publish pending")
	return gpu3d.ErrPending
}

// frame runs one clear+triangle+present+poll+publish cycle at render extent
// ew×eh, exporting the [0,0,xw,xh) surface rect as the receipt (xw×xh >= the
// render extent so margin guard pixels ride along). A named error anywhere
// aborts the cycle.
func (a *app) frame(ew, eh, xw, xh uint32) error {
	cl, tr, err := a.openCtx(ew, eh)
	if err != nil {
		a.rec.row("error", is(a.wgen), is(a.rgen), "open", errName(err))
		return err
	}
	defer cl.Close()
	if err := a.op(tr, "clear", func() error { return cl.Clear(clearRGB) }); err != nil {
		return err
	}
	if err := a.op(tr, "triangle", func() error { return cl.Triangle(sceneVerts) }); err != nil {
		return err
	}
	if err := a.op(tr, "present", func() error { return cl.Present() }); err != nil {
		return err
	}
	a.rec.row("completed", is(a.wgen), is(a.rgen), u32s(tr.frame()))
	a.h.ConsoleLine("gputri: completed frame=" + u32s(tr.frame()))
	if err := a.publish(cl, tr, a.exportName(), xw, xh); err != nil {
		return err
	}
	// The seat composes the shared surface; the ordinary window present is
	// still the app's honest ask for the new frame.
	if err := a.h.PresentWindow(a.win); err != nil {
		a.rec.row("error", is(a.wgen), is(a.rgen), "win-present", "error")
		return err
	}
	a.h.ConsoleLine("gputri: win-present")
	if err := cl.Close(); err != nil {
		a.rec.row("error", is(a.wgen), is(a.rgen), "close", errName(err))
		return err
	}
	a.rec.row("submitted", is(a.wgen), is(a.rgen), "close")
	return nil
}

// openWindow opens the app window, binds its shared back-buffer, declares
// the ordinary tab and records the window generation. The bind must come
// FIRST (issue #2225): the seat's declare handler resizes the window to the
// full viewport, and a later smaller bind would fail the capacity check —
// bound first, the kernel honestly keeps the window at its opened size.
func (a *app) openWindow(w, h uint32) error {
	win, err := a.h.OpenWindow(winX, winY, w, h)
	if err != nil {
		return err
	}
	a.win, a.wgen = win, a.wgen+1
	surf, err := a.h.BindSurface(win, w, h)
	if err != nil {
		return err
	}
	a.surf, a.surfW = surf, w
	if a.h.DeclareTab(win, appTitle) {
		a.h.ConsoleLine("gputri: declare accepted")
	}
	a.rec.row("window", is(a.wgen), is(win), u32s(w)+"x"+u32s(h))
	a.h.ConsoleLine("gputri: open id=" + is(win) + " surface")
	return nil
}

// writeReceipts publishes the TSV receipt last: a `published` surface row in
// it is only ever written after the surface file landed.
func (a *app) writeReceipts() error {
	if err := a.h.MkdirShare(receiptDir); err != nil {
		return err
	}
	if err := a.h.WriteShareFile(receiptPath, a.rec.body()); err != nil {
		return err
	}
	a.h.ConsoleLine("gputri: receipt " + receiptPath)
	return nil
}

// waitClose idles on the event queue until the WM closes the window (or the
// bounded idle expires — the app then leaves honestly, without printing the
// close marker).
func (a *app) waitClose() {
	for idle := 0; idle < maxIdleTicks; {
		ev, rc, ok := a.h.PollEvent()
		if rc < 0 {
			return
		}
		if !ok {
			idle++
			a.h.Sleep(1)
			continue
		}
		if ev.Kind == vi.EvWinClose {
			a.h.ConsoleLine("gputri: close")
			a.h.CloseWindow(a.win)
			return
		}
		if ev.Kind == vi.EvWinResize {
			a.h.ConsoleLine("gputri: resized " + u32s(ev.Arg0) + "x" + u32s(ev.Arg1))
		}
	}
}

// exportName builds the bounded BGRA receipt name for this generation pair.
func (a *app) exportName() string {
	return "EXPO_" + is(a.wgen) + "_" + is(a.rgen) + ".BGRA"
}

// --- journeys -----------------------------------------------------------------

// jTriangle is the default leg: one deterministic frame end to end.
func (a *app) jTriangle() error {
	if err := a.openWindow(winW, winH); err != nil {
		return err
	}
	defer a.h.CloseWindow(a.win)
	if err := a.frame(extentW, extentH, extentW, extentH); err != nil {
		return err
	}
	if err := a.writeReceipts(); err != nil {
		return err
	}
	a.waitClose()
	return nil
}

// jMixed renders the same extent into a larger window and 2D-fills the
// margins — the mixed-layout leg: GPU pixels at the client origin, ordinary
// margin pixels around them.
func (a *app) jMixed() error {
	if err := a.openWindow(mixedWinW, mixedH); err != nil {
		return err
	}
	defer a.h.CloseWindow(a.win)
	a.fillMargin(extentW, extentH)
	if err := a.frame(extentW, extentH, mixedExW, mixedExH); err != nil {
		return err
	}
	if err := a.writeReceipts(); err != nil {
		return err
	}
	a.waitClose()
	return nil
}

// jResize publishes at the base extent, then replaces the context at the
// larger extent — the render-resize leg: a new rgen per extent, the frame
// counter and receipts proving the generations are distinct.
func (a *app) jResize() error {
	if err := a.openWindow(winW, winH); err != nil {
		return err
	}
	defer a.h.CloseWindow(a.win)
	if err := a.frame(extentW, extentH, extentW, extentH); err != nil {
		return err
	}
	a.fillMargin(resizeW, resizeH)
	if err := a.frame(resizeW, resizeH, resizeW, resizeH); err != nil {
		return err
	}
	if err := a.writeReceipts(); err != nil {
		return err
	}
	a.waitClose()
	return nil
}

// jCloseReuse runs a full window lifetime, then a second one: wgen 1 then 2.
// An old context/frame cannot leak into the new window's receipts.
func (a *app) jCloseReuse() error {
	if err := a.openWindow(winW, winH); err != nil {
		return err
	}
	if err := a.frame(extentW, extentH, extentW, extentH); err != nil {
		a.h.CloseWindow(a.win)
		return err
	}
	a.h.CloseWindow(a.win)
	a.surf = nil
	if err := a.openWindow(winW, winH); err != nil {
		return err
	}
	defer a.h.CloseWindow(a.win)
	if err := a.frame(extentW, extentH, extentW, extentH); err != nil {
		return err
	}
	if err := a.writeReceipts(); err != nil {
		return err
	}
	a.waitClose()
	return nil
}

// jInvalid is the negative battery: every refusal must be a NAMED error and
// the journey writes NO success receipt (the TSV exists but carries only
// error rows — a gate that finds a `published` row here fails).
func (a *app) jInvalid() error {
	if err := a.openWindow(winW, winH); err != nil {
		return err
	}
	defer a.h.CloseWindow(a.win)
	// Geometry refused before the transport: zero and over-cap extents.
	for _, ext := range [][2]uint32{{0, extentH}, {gpu3d.MaxWidth + 1, 1}, {8, gpu3d.MaxHeight + 1}} {
		_, err := gpu3d.OpenTransport(a.transport(), uint32(a.win), ext[0], ext[1])
		if err == nil {
			a.rec.row("error", is(a.wgen), is(a.rgen), "open", "accepted")
			return errors.New("over-cap extent accepted")
		}
		a.rec.row("error", is(a.wgen), is(a.rgen), "open", errName(err))
		a.h.ConsoleLine("gputri: refuse open " + errName(err))
	}
	cl, tr, err := a.openCtx(extentW, extentH)
	if err != nil {
		return err
	}
	// A wide RGB (nonzero top byte) is refused before the transport.
	if err := a.op(tr, "clear-wide", func() error { return cl.Clear(0x1000000 | clearRGB) }); err == nil {
		a.rec.row("error", is(a.wgen), is(a.rgen), "clear-wide", "accepted")
		return errors.New("wide clear accepted")
	}
	// An operation after Close is the named closed error, off the wire.
	if err := cl.Close(); err != nil {
		a.rec.row("error", is(a.wgen), is(a.rgen), "close", errName(err))
	}
	if err := a.op(tr, "closed-present", func() error { return cl.Present() }); err == nil {
		a.rec.row("error", is(a.wgen), is(a.rgen), "closed-present", "accepted")
		return errors.New("op after close accepted")
	}
	if err := a.writeReceipts(); err != nil {
		return err
	}
	return nil
}

// jForged publishes once, then emits a kind-17 frame for its OWN bound
// window carrying a wrong session token through the ordinary any-to-any
// mailbox, then proves the real session still completes a second frame.
// The seat must answer the forgery with silence — zero broker submissions —
// so the app itself simply sends and moves on.
func (a *app) jForged() error {
	if err := a.openWindow(winW, winH); err != nil {
		return err
	}
	defer a.h.CloseWindow(a.win)
	if err := a.frame(extentW, extentH, extentW, extentH); err != nil {
		return err
	}
	wm, self, ok := a.h.Peers()
	if !ok {
		return errors.New("peers")
	}
	// The forged request: genuine kind/opcode/window, wrong token. The
	// window is bound by now, so a forged auth union is the refused shape.
	var m vi.WmRpc
	m.Kind = gpu3d.Kind
	m.ID = uint8(a.win)
	m.Seq = 0x41
	m.ReplyTo = uint8(self)
	m.Applied = gpu3d.OpClear
	m.Pad = vi.WmRpcPadBound
	vi.SetWmAuth(&m, forgedToken)
	m.Title = gpu3d.PayloadClear(0xffffff)
	if rc := a.h.IpcSend(wm, m.Encode()); rc < 0 {
		return errors.New("forged send")
	}
	a.rec.row("forged", is(a.wgen), is(a.rgen), "sent")
	a.h.ConsoleLine("gputri: forged sent")
	// The real session still works — the forgery did not disturb it.
	if err := a.frame(extentW, extentH, extentW, extentH); err != nil {
		return err
	}
	a.rec.row("intact", is(a.wgen), is(a.rgen))
	a.h.ConsoleLine("gputri: session intact")
	if err := a.writeReceipts(); err != nil {
		return err
	}
	a.waitClose()
	return nil
}

var errUsage = errors.New("usage")

func run(h host, journey string) error {
	a := &app{h: h}
	a.rec.row("schema", "1")
	a.rec.row("app", appName, journey)
	var err error
	switch journey {
	case "", "triangle":
		err = a.jTriangle()
	case "mixed":
		err = a.jMixed()
	case "resize":
		err = a.jResize()
	case "closereuse":
		err = a.jCloseReuse()
	case "invalid":
		err = a.jInvalid()
	case "forged":
		err = a.jForged()
	default:
		err = errUsage
	}
	if errors.Is(err, gpu3d.ErrUnsupported) {
		// The native-only leg: named refusal, NO receipt files — there is
		// no 3D success to claim.
		a.h.ConsoleLine("gputri: unsupported")
		return nil
	}
	if err != nil {
		// A failed journey still publishes its receipt: the error rows are
		// the evidence, and no `published` row exists to claim success.
		_ = a.writeReceipts()
		a.h.ConsoleLine("gputri: error " + errName(err))
		return err
	}
	a.h.ConsoleLine("gputri OK")
	return nil
}

// --- guest platform -------------------------------------------------------------

type guestHost struct{}

func (guestHost) OpenWindow(x, y, w, h uint32) (int, error) {
	id, rc := vi.WinOpen(x, y, w, h)
	if rc < 0 {
		return 0, errors.New("win_open " + strconv.FormatInt(rc, 10))
	}
	return id, nil
}

func (guestHost) DeclareTab(win int, title string) bool {
	return vi.DeclareFullscreen(uint32(win), title, appName)
}

func (guestHost) BindSurface(win int, w, h uint32) ([]byte, error) {
	n := int(w*h) * 4
	// Issue #2224: MmapWindowSurface carries the tag|win hint that MmapHint
	// would reject as unaligned — the bind must reach the kernel.
	surf, err := vi.MmapWindowSurface(win, n)
	if err != nil {
		return nil, err
	}
	if len(surf) < n {
		return nil, errors.New("short surface")
	}
	return surf[:n], nil
}

func (guestHost) PresentWindow(win int) error {
	if rc := vi.WinPresent(win); rc < 0 {
		return errors.New("present " + strconv.FormatInt(rc, 10))
	}
	return nil
}

func (guestHost) PollEvent() (vi.Event, int64, bool) { return vi.PollEventRaw() }

func (guestHost) CloseWindow(win int) { _ = vi.WinClose(win) }

func (guestHost) MkdirShare(path string) error {
	h, rc := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if rc == 0 {
		vi.FileClose(uint32(h))
		return nil
	}
	if rc == -9 { // EEXIST
		return nil
	}
	return errors.New("mkdir " + strconv.FormatInt(rc, 10))
}

func (guestHost) WriteShareFile(path string, b []byte) error {
	if rc := vi.WriteFileSafe(path, b); rc < 0 {
		return errors.New("write " + strconv.FormatInt(rc, 10))
	}
	return nil
}

func (guestHost) ConsoleLine(s string) { vi.ConsoleLine(s) }
func (guestHost) Sleep(ticks uint64)   { vi.Sleep(ticks) }

func (guestHost) Peers() (uint32, uint32, bool) {
	peers := vi.WmPeers(appName)
	return peers.WM, peers.Self, peers.WM != 0 && peers.Self != 0
}

func (guestHost) IpcSend(target uint32, b []byte) int64 { return vi.IpcSend(target, b) }

func (guestHost) Transport() gpu3d.Transport { return nil }

func main() {
	journey := ""
	if args := vi.Args(); len(args) > 1 {
		journey = args[1]
	}
	if err := run(guestHost{}, journey); err != nil {
		vi.Exit(1)
	}
	vi.Exit(0)
}
