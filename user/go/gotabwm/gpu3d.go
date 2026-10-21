// WM_RPC kind 17, GPU3D (M102e, issue #2169): the seat's server half of the
// bounded experimental-3D render contract. Apps drive six operations
// (gpu3d.OpOpen..OpClose) over the authenticated WM_RPC seam; the seat turns
// each one into ONE slot-65 cmd-22 descriptor for the kernel broker
// (ADR 0007 M102d1 amendment) and answers with the frozen reply payload —
// status byte, staged flag, and the seat-minted frame counter.
//
// The seat never paints GPU pixels itself and never hands the compositor a
// shortcut: PUBLISH is the kernel's bounded copy of a completed readback
// into the window's ORDINARY surface/back-buffer, and the next ordinary
// composite/present puts it on the scanout like any other window. This
// file owns exactly the four things the contract assigns the seat:
//
//   - AUTHENTICATION: kind 17 routes AFTER gateRPC like every other bound
//     kind (the serviceRPC edit in interop.go). There is no exemption and
//     no trust derived from reply_to alone: an unbound window draws the
//     ordinary challenge, a wrong token/pid the ordinary bare refusal, and
//     neither reaches the broker — zero calls.
//   - RECORDS: at most two live records (the VIR1 contexts bound), keyed by
//     the bound window/session AND the generation-bearing handle the broker
//     minted. The record is re-validated against the live binding before
//     every broker call; a dead binding kills the record.
//   - PUBLICATION: a completed frame publishes exactly once (the published
//     counter is the guard) and only while POLL reports it staged — a
//     pending or failed frame can never replace the last completed one.
//     The destination extent is read fresh from the kind-20 registry
//     mirror for every publish (WinQuery is owner-only), so a WM layout
//     change refreshes bounds/stride and the broker clips the bounded
//     image; a captured-geometry mismatch is the broker's EINVAL, a named
//     refusal that paints nothing.
//   - LIFETIME: binding drop (tab close or released mirror — both funnel
//     through dropRpcBinding) and WM shutdown close the context. The
//     kernel is still the final lifetime authority.
//
// `gotabwm: gpu3d presented id=<w> frame=<n>` is printed only after the
// composite tick following the publish ACTUALLY presented — never at
// submit, fence or copy time.
package main

import (
	"virelai/gpu3d"
	"virelai/vi"
)

// The serial markers. Presented carries the published frame number so a
// gate can pair it with the app's own receipt.
const (
	MarkerGpu3dOpen      = "gotabwm: gpu3d open id="
	MarkerGpu3dClose     = "gotabwm: gpu3d close id="
	MarkerGpu3dPresented = "gotabwm: gpu3d presented id="
)

// gpu3dMaxRecs is the VIR1 `contexts` bound: two render contexts
// system-wide, one per hosted window.
const gpu3dMaxRecs = 2

// gpu3dRec is one bound window's render session. It is keyed by
// (win, token, handle): the window id routes the request, the session
// token must still be the live binding before every broker call, and the
// handle carries the kernel's render generation — an extent change or a
// revocation mints a new one and the old record stops driving anything.
type gpu3dRec struct {
	live   bool
	win    uint32
	pid    uint8  // the reply_to the binding proved at CREATE
	token  uint64 // the session token at CREATE
	handle uint64 // generation-bearing broker handle
	w, h   uint32 // render extent (the VIR1 bounds are enforced at Open)

	frames     uint32 // applied PRESENT ops — the reply's staleness oracle
	published  uint32 // frames that actually reached the window surface
	presentDue bool   // a publish awaits its first real composite present
}

var gpu3dRecs [gpu3dMaxRecs]gpu3dRec

// gpu3dRects is the seat's copy of each user window's live extent, packed
// w|h<<16 exactly as the kind-20 registry mirror delivers it (arg1). It is
// the publish path's captured geometry: refreshed by every state mirror,
// so a layout change between two polls clips instead of stretching, and a
// mirror the seat never saw leaves the window unpublishable until one
// lands. Zero means no mirror has named the window.
var gpu3dRects [256]uint32

// The kernel seams, injectable the same way closeWin/focusRaise are: host
// tests stub the broker (a 64-byte descriptor in, an op result out) and
// the reply sender, and capture the log lines.
var (
	gpu3dSend   = vi.IpcSend
	gpu3dBroker = vi.WmctlGpu3d
	gpu3dLog    = vi.ConsoleLine
)

// The cmd-22 descriptor must live in a mapped page — the kernel copies it
// through checked uaccess, and a Go stack/heap address is not guaranteed
// mapped for EL1 (ADR 0026 D8). scratchVA is the seat's descriptor band;
// the chrome descriptor owns pages 0-1. The map seam exists so host tests
// hand back an ordinary slice where MmapHint is -ENOSYS.
var gpu3dDescMap = func() ([]byte, error) {
	return vi.MmapHint(scratchVA+2*vi.PageSize, vi.PageSize,
		vi.ProtRead|vi.ProtWrite, vi.MapAnonymous)
}

var gpu3dDescBuf []byte

// gpu3dCall encodes d into the mapped staging page and submits it (slot 65
// cmd 22). res is the broker's op result — a generation-bearing handle on
// CREATE, 1/0 staged on POLL, 0 on the rest, or a negative errno. A nonzero
// pre means the call never reached the broker: the staging page could not
// be mapped (Exhausted) or the descriptor failed its own per-op field
// discipline (Invalid) — either way zero device work happened.
func gpu3dCall(d vi.Gpu3dDesc) (res int64, pre uint8) {
	buf := gpu3dDescBuf
	if buf == nil {
		b, err := gpu3dDescMap()
		if err != nil || len(b) < vi.Gpu3dDescBytes {
			return 0, gpu3d.StatusExhausted
		}
		gpu3dDescBuf = b[:vi.Gpu3dDescBytes]
		buf = gpu3dDescBuf
	}
	if d.EncodeDesc(buf) != nil {
		return 0, gpu3d.StatusInvalid
	}
	return gpu3dBroker(buf), 0
}

// boundStill re-verifies the record's session against the live binding —
// run before EVERY broker call so a request can only drive a context whose
// window is still bound to the session that opened it. The wire gate
// authenticates the frame; this authenticates the context.
func (r *gpu3dRec) boundStill() bool {
	b := rpcBindings[r.win]
	return b.token != 0 && b.token == r.token && b.pid == r.pid
}

// gpu3dStatus maps a broker errno magnitude onto the reply's status byte —
// the same named values end to end (the wire constants ARE the magnitudes).
func gpu3dStatus(res int64) uint8 {
	switch -res {
	case vi.ErrEINVAL:
		return gpu3d.StatusInvalid
	case vi.ErrEBADF:
		return gpu3d.StatusBadHandle
	case vi.ErrENOSPC:
		return gpu3d.StatusExhausted
	case vi.ErrENOENT:
		return gpu3d.StatusLostContext
	case vi.ErrENXIO:
		return gpu3d.StatusUnsupported
	case vi.ErrEAGAIN:
		return gpu3d.StatusPending
	case vi.ErrETIMEDOUT:
		return gpu3d.StatusTimeout
	default:
		return gpu3d.StatusDeviceFault
	}
}

// gpu3dDeadOn drops the record when the broker answers that the handle is
// gone (EBADF) or the session was quarantined (ENOENT): the kernel is the
// lifetime authority and a revoked generation can never drive again, so the
// seat forgets it — a CLOSE would only earn the same EBADF.
func gpu3dDeadOn(rec *gpu3dRec, res int64) {
	if res == -vi.ErrEBADF || res == -vi.ErrENOENT {
		*rec = gpu3dRec{}
	}
}

// gpu3dReply sends the one kind-17 ack: Pad=Bound + the session token in
// the auth union (so a forged ack cannot satisfy the app's wait) and the
// encoded status/staged/frame payload in Title[24].
func gpu3dReply(req vi.WmRpc, auth uint64, applied bool, status uint8, staged bool, frame uint32) {
	if req.ReplyTo == 0 {
		return
	}
	rep := buildReply(req, applied, "", vi.WmRpcPadBound, auth)
	rep.Title = gpu3d.EncodeReply(status, staged, frame)
	_ = gpu3dSend(uint32(req.ReplyTo), rep.Encode())
}

// gpu3dLiveRec returns the window's live record, or nil. A record whose
// session token no longer binds the window — rebound, released, closed —
// is dead by definition: it is closed through the broker (a second close
// on an already-revoked handle is the harmless EBADF) and dropped, so a
// stale generation can never serve the new session.
func gpu3dLiveRec(id uint32) *gpu3dRec {
	for i := range gpu3dRecs {
		r := &gpu3dRecs[i]
		if !r.live || r.win != id {
			continue
		}
		if r.boundStill() {
			return r
		}
		gpu3dCloseRec(r)
		return nil
	}
	return nil
}

// gpu3dAlloc returns a dead record slot, or nil at the VIR1 bound — the
// seat's own pool check, so an over-pool OPEN is a named refusal that
// never reaches the broker and never evicts a live context.
func gpu3dAlloc() *gpu3dRec {
	for i := range gpu3dRecs {
		if !gpu3dRecs[i].live {
			return &gpu3dRecs[i]
		}
	}
	return nil
}

// gpu3dCloseRec issues the broker CLOSE and drops the record. The kernel
// invalidates the handle before it drains, so whatever the call answers —
// including EBADF for an already-revoked handle — the seat's bookkeeping
// is the same: the record is gone.
func gpu3dCloseRec(r *gpu3dRec) {
	if r.live && r.handle != 0 {
		_, _ = gpu3dCall(vi.Gpu3dDesc{Op: vi.Gpu3dOpClose,
			Handle: r.handle, WindowID: r.win})
		gpu3dLog(MarkerGpu3dClose + vi.Itoa64(int64(r.win)))
	}
	*r = gpu3dRec{}
}

// gpu3dDropWindow closes the window's context, if any, and forgets its
// mirrored extent. Called from dropRpcBinding — the one funnel every
// window-leaves-registry path (tab close, released mirror) already runs —
// so the context dies with the binding that owned it, never later.
func gpu3dDropWindow(id uint32) {
	if id > 255 {
		return
	}
	gpu3dRects[id] = 0
	for i := range gpu3dRecs {
		if gpu3dRecs[i].live && gpu3dRecs[i].win == id {
			gpu3dCloseRec(&gpu3dRecs[i])
		}
	}
}

// gpu3dCloseAll closes every live record — WM shutdown. Window teardown
// already revoked them kernel-side (the broker is the final lifetime
// authority); the CLOSE calls simply retire the seat's records the same
// way they were born.
func gpu3dCloseAll() {
	for i := range gpu3dRecs {
		if gpu3dRecs[i].live {
			gpu3dCloseRec(&gpu3dRecs[i])
		}
	}
	gpu3dRects = [256]uint32{}
}

// gpu3dNoteMirror tracks the kind-20 registry mirror: arg1 packs the
// window's live w|h<<16, the released bit (13) clears it. The record drop
// itself rides dropRpcBinding — this table only needs the geometry truth.
func gpu3dNoteMirror(e vi.Event) {
	if e.Kind != vi.EvWmWindow {
		return
	}
	id := uint32(e.Flags & 0xff)
	if e.Flags&(1<<13) != 0 {
		// #2870: a stale release mirror must not zero the LIVE window's
		// extent — the id may have been reissued to a bound successor,
		// and a 0 reads as "no mirror yet" until the next one lands.
		if !deathMirrorStale(id) {
			gpu3dRects[id] = 0
		}
		return
	}
	gpu3dRects[id] = e.Arg1
}

// gpu3dPresented runs after the composite tick's present. A frame that was
// PUBLISHed but never presented is not "on screen"; the marker is owed only
// once an actual present flushed it.
func gpu3dPresented(presented bool) {
	if !presented {
		return
	}
	for i := range gpu3dRecs {
		r := &gpu3dRecs[i]
		if r.live && r.presentDue {
			r.presentDue = false
			gpu3dLog(MarkerGpu3dPresented + vi.Itoa64(int64(r.win)) +
				" frame=" + vi.Itoa64(int64(r.published)))
		}
	}
}

// gpu3dPublish copies the staged completed frame into the window's surface
// through the broker — the "completed frame" half of POLL. Exactly once per
// completed frame: the published counter guards it, and a geometry or
// capacity race reports Pending so the next POLL retries with the mirror's
// refreshed extent instead of forcing stale geometry into a resized window.
func gpu3dPublish(rec *gpu3dRec) uint8 {
	wh := gpu3dRects[rec.win]
	w, h := wh&0xffff, wh>>16
	if w == 0 || h == 0 {
		// No mirror has named the window yet — the surface rect is
		// unknown, so publication is still owed, not failed.
		return gpu3d.StatusPending
	}
	res, pre := gpu3dCall(vi.Gpu3dDesc{Op: vi.Gpu3dOpPublish,
		Handle: rec.handle, WindowID: rec.win, Width: w, Height: h})
	if pre != 0 {
		return pre
	}
	switch {
	case res == 0:
		rec.published = rec.frames
		rec.presentDue = true
		return gpu3d.StatusOK
	case res == -vi.ErrEINVAL:
		// The captured extent disagreed with the live rect, or the
		// destination surface was absent/revoked/undersized — the broker
		// painted nothing, the last completed surface stays valid, and
		// the next poll retries against the refreshed mirror.
		return gpu3d.StatusPending
	default:
		gpu3dDeadOn(rec, res)
		return gpu3dStatus(res)
	}
}

// serveGpu3d services one authenticated kind-17 request — serviceRPC only
// reaches it after gateRPC bound the frame's window/session, so every op
// below already knows WHO is asking. The frame the client sees is the
// frozen reply: Applied plus status/staged/frame in Title[24].
func serveGpu3d(req vi.WmRpc, auth uint64) {
	r, err := gpu3d.DecodeRequest(req)
	if err != nil {
		// A malformed payload is a named refusal with zero broker calls —
		// never a guess at what the bytes meant.
		gpu3dReply(req, auth, false, gpu3d.StatusInvalid, false, 0)
		return
	}
	id := uint32(req.ID)
	if r.Op == gpu3d.OpOpen {
		gpu3dServeOpen(req, auth, id, r.W, r.H)
		return
	}
	rec := gpu3dLiveRec(id)
	if rec == nil {
		gpu3dReply(req, auth, false, gpu3d.StatusBadHandle, false, 0)
		return
	}
	switch r.Op {
	case gpu3d.OpClear:
		gpu3dOpReply(req, auth, rec, vi.Gpu3dDesc{
			Op: vi.Gpu3dOpClear, Handle: rec.handle, WindowID: id, RGB: r.RGB})
	case gpu3d.OpTriangle:
		var verts [3]vi.Gpu3dVertex
		for i, v := range r.Verts {
			verts[i] = vi.Gpu3dVertex{X: v.X, Y: v.Y, Z: v.Z, RGB: v.RGB}
		}
		gpu3dOpReply(req, auth, rec, vi.Gpu3dDesc{
			Op: vi.Gpu3dOpTriangle, Handle: rec.handle, WindowID: id, Verts: verts})
	case gpu3d.OpPresent:
		res, pre := gpu3dCall(vi.Gpu3dDesc{
			Op: vi.Gpu3dOpPresent, Handle: rec.handle, WindowID: id})
		if pre != 0 {
			gpu3dReply(req, auth, false, pre, false, rec.frames)
			return
		}
		if res < 0 {
			frames := rec.frames
			gpu3dDeadOn(rec, res)
			gpu3dReply(req, auth, false, gpu3dStatus(res), false, frames)
			return
		}
		// The broker waited out the fence-matched completion, so this
		// count is the app's staleness oracle: one applied PRESENT is one
		// completed frame.
		rec.frames++
		gpu3dReply(req, auth, true, gpu3d.StatusOK, false, rec.frames)
	case gpu3d.OpPoll:
		gpu3dServePoll(req, auth, rec)
	case gpu3d.OpClose:
		res, pre := gpu3dCall(vi.Gpu3dDesc{
			Op: vi.Gpu3dOpClose, Handle: rec.handle, WindowID: id})
		// The record dies whatever the answer — the kernel invalidated
		// the handle first, so the session is over either way.
		*rec = gpu3dRec{}
		gpu3dLog(MarkerGpu3dClose + vi.Itoa64(int64(id)))
		if pre != 0 {
			gpu3dReply(req, auth, false, pre, false, 0)
			return
		}
		if res < 0 {
			gpu3dReply(req, auth, false, gpu3dStatus(res), false, 0)
			return
		}
		gpu3dReply(req, auth, true, gpu3d.StatusOK, false, 0)
	}
}

// gpu3dServeOpen services OPEN: extent bounds are the seat's named refusal
// (zero broker calls), the two-record pool is enforced before the broker
// sees anything, and the broker's CREATE stays authoritative — same-extent
// re-open is idempotent, an extent change revokes the old generation
// before the re-open, and a failed re-open leaves the old generation dead.
func gpu3dServeOpen(req vi.WmRpc, auth uint64, id uint32, w, h uint32) {
	if w == 0 || w > gpu3d.MaxWidth || h == 0 || h > gpu3d.MaxHeight {
		gpu3dReply(req, auth, false, gpu3d.StatusInvalid, false, 0)
		return
	}
	rec := gpu3dLiveRec(id)
	fresh := rec == nil
	if fresh {
		rec = gpu3dAlloc()
		if rec == nil {
			// Two live contexts is the whole pool — a named refusal,
			// never an eviction, a partial open, or a broker call.
			gpu3dReply(req, auth, false, gpu3d.StatusExhausted, false, 0)
			return
		}
	}
	res, pre := gpu3dCall(vi.Gpu3dDesc{Op: vi.Gpu3dOpCreate, WindowID: id, Width: w, Height: h})
	if pre != 0 {
		if fresh {
			*rec = gpu3dRec{}
		}
		gpu3dReply(req, auth, false, pre, false, 0)
		return
	}
	if res <= 0 {
		// A failure AFTER the kernel matched this window's live record on
		// a changed extent already revoked the old generation — the record
		// is dead whether the seat clears it or not. A failure before that
		// point (device unsupported, pool, a same-extent idempotent retry)
		// leaves a pre-existing record intact.
		if !fresh && (rec.w != w || rec.h != h) {
			*rec = gpu3dRec{}
		}
		gpu3dReply(req, auth, false, gpu3dStatus(res), false, 0)
		return
	}
	rec.live = true
	rec.win = id
	rec.pid = req.ReplyTo
	rec.token = auth
	rec.handle = uint64(res)
	rec.w, rec.h = w, h
	rec.presentDue = false
	// frames/published keep counting for this window across a regen — the
	// app-visible staleness oracle stays monotonic and an old-generation
	// frame can never pass as new.
	gpu3dLog(MarkerGpu3dOpen + vi.Itoa64(int64(id)) + " " +
		vi.Itoa64(int64(w)) + "x" + vi.Itoa64(int64(h)))
	gpu3dReply(req, auth, true, gpu3d.StatusOK, false, rec.frames)
}

// gpu3dOpReply is the shared tail for the stage-and-forget ops (CLEAR,
// TRIANGLE): one broker call, one reply.
func gpu3dOpReply(req vi.WmRpc, auth uint64, rec *gpu3dRec, d vi.Gpu3dDesc) {
	res, pre := gpu3dCall(d)
	if pre != 0 {
		gpu3dReply(req, auth, false, pre, false, rec.frames)
		return
	}
	if res < 0 {
		frames := rec.frames
		gpu3dDeadOn(rec, res)
		gpu3dReply(req, auth, false, gpu3dStatus(res), false, frames)
		return
	}
	gpu3dReply(req, auth, true, gpu3d.StatusOK, false, rec.frames)
}

// gpu3dServePoll services POLL — the non-blocking completion check plus
// the publish trigger. The broker answers staged/pending without any wait;
// when the newest completed frame is staged and not yet published, the seat
// issues exactly one PUBLISH (the published counter is the once-guard),
// re-verifying the live binding before that second broker call.
func gpu3dServePoll(req vi.WmRpc, auth uint64, rec *gpu3dRec) {
	res, pre := gpu3dCall(vi.Gpu3dDesc{Op: vi.Gpu3dOpPoll,
		Handle: rec.handle, WindowID: rec.win})
	if pre != 0 {
		gpu3dReply(req, auth, false, pre, false, rec.frames)
		return
	}
	if res < 0 {
		frames := rec.frames
		gpu3dDeadOn(rec, res)
		gpu3dReply(req, auth, false, gpu3dStatus(res), false, frames)
		return
	}
	staged := res == 1
	if staged && rec.published < rec.frames {
		if !rec.boundStill() {
			// The session died between the gate and the publish —
			// the record is dead and nothing may paint for it.
			gpu3dCloseRec(rec)
			gpu3dReply(req, auth, false, gpu3d.StatusBadHandle, false, 0)
			return
		}
		frames := rec.frames
		st := gpu3dPublish(rec)
		if st != gpu3d.StatusOK {
			if st == gpu3d.StatusPending {
				// Still owed: report pending so the app retries and
				// the retry publishes with refreshed geometry.
				gpu3dReply(req, auth, true, gpu3d.StatusOK, false, frames)
				return
			}
			gpu3dReply(req, auth, false, st, false, frames)
			return
		}
	}
	gpu3dReply(req, auth, true, gpu3d.StatusOK, staged, rec.frames)
}
