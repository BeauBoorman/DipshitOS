// GOTABWM.ELF — M124a (#2580): the guest drag-and-drop protocol's seat
// half. The wire + client surface live in vi/wmdrag.go; this file is the
// arbiter:
//
//	drag_begin (24): a bound, hosted tab arms the drag. The request's
//	    title carries the mime spelling and the payload rides the staged
//	    rendezvous file (vi.DragPath) — the 38-byte frame never carries
//	    the blob, exactly like M125a's app_state. The seat validates the
//	    envelope (mime must match the frame — the ghost's label and the
//	    delivered bytes can never describe different things), consumes
//	    the staging file, and owns the gesture from there.
//	The armed drag owns the pointer: every kind-19 sample feeds the
//	    ghost's position and the hit-test, and the RELEASE edge settles
//	    it. No chrome (toast, rail, sash, launcher) can see a click
//	    mid-drag, and nothing forwards to content.
//	Hit-test resolves the hosted tab whose live window rect holds the
//	    pointer (surfaceXY / gpu3dRects — the kind-20 mirror pair). The
//	    rail band is chrome, never a drop target.
//	Accept/refuse is the manifest, not a guess: the target's opens= row
//	    from APPS.TXT decides (opensAccepts). GOEDIT's opens=text takes
//	    text/plain; GOVIEW's opens=image takes image/png.
//	An accepted drop republishes the envelope under the TARGET's own
//	    rendezvous path and posts its kind-25 notice (Seq=0); the source
//	    gets the Seq=1 receipt. Every other ending — release over chrome,
//	    a refusing target, a publish refusal, the source dying, a
//	    request abort — ends in the kind-26 notice (or silence when the
//	    source is already dead).
package main

import (
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// The drag markers the gate greps. Exported so drag_test.go pins the
// shapes (the MarkerNotify discipline): a marker prints only after the
// state transition it names — arm after the envelope validated, over on
// hover transitions, drop after the republish+notice pair, cancel after
// the abort cleared the session.
const (
	MarkerDragArm    = "gotabwm: drag arm id="
	MarkerDragOver   = "gotabwm: drag over id="
	MarkerDragDrop   = "gotabwm: drag drop id="
	MarkerDragCancel = "gotabwm: drag cancel id="
	MarkerDragRefuse = "gotabwm: drag refuse id="
	// MarkerDragGhost is the presented-frame marker — printed once per
	// drag, after the composite tick that painted the ghost flushed (the
	// MarkerNotifyPaint "pixels before claims" rule).
	MarkerDragGhost = "gotabwm: drag ghost"
)

// dragSession is the one armed drag: the source window (a bound hosted
// tab), the mime both sides agreed on, the envelope the arm consumed for
// republication, the ghost's last pointer position, and the hit-test's
// current verdict. catalog is APPS.TXT decoded at arm time — the opens=
// authority the whole gesture routes against.
type dragSession struct {
	armed   bool
	src     uint32
	mime    string
	staged  []byte
	x, y    uint32
	hover   uint32 // hit-tested target window id; 0 = over chrome / nothing
	accept  bool   // hover's opens= takes mime
	catalog []AppEntry
}

// The package-level armed session — exactly one drag can be in flight
// because exactly one pointer can be held.
var drag dragSession

// dragGhostPainted latches the presented-ghost marker for THIS drag (the
// notifyPainted burst discipline); armed at each drag_begin.
var dragGhostPainted bool

// The protocol's seams — appstate.go's pattern: the vi calls all cross
// the raw syscall gateway (-ENOSYS off the guest), so the vars are the
// host-test surface.
var (
	dragFileRead   = vi.ReadFileAll
	dragFileWrite  = vi.WriteFileSafe
	dragFileDelete = vi.FileDelete
	dragPost       = vi.IpcSend
	dragLog        = vi.ConsoleLine
)

// serveDragBegin is the kind-24 arm: gateRPC already proved the sender
// owns req.ID. The staged envelope is read whole (bounded), its mime must
// equal the frame's, and the file is consumed at arm — a staging slot is
// a handoff, never storage, so a refused arm leaves the source's slot to
// the source's own cleanup (the client deletes on a refused ack).
func serveDragBegin(req vi.WmRpc) bool {
	id := uint32(req.ID)
	mime := req.TitleString()
	refuse := func(why string) bool {
		dragLog(MarkerDragRefuse + vi.Itoa64(int64(id)) + " " + why)
		return false
	}
	if drag.armed {
		return refuse("busy")
	}
	if tabs.index(id) < 0 || id >= sessionIDBase {
		return refuse("notab")
	}
	if mime == "" {
		return refuse("nomime")
	}
	path := vi.DragPath(id)
	raw, r := dragFileRead(path, 1+vi.WmRpcTitleMax+4+vi.DragMax)
	if r < 0 {
		return refuse("missing")
	}
	em, blob, ok := vi.DecodeDrag(raw)
	if !ok || em != mime {
		return refuse("bad")
	}
	_ = dragFileDelete(path)
	// The press that became this drag forwarded as content; while the
	// drag is armed its own release is the drop edge — no pane selection,
	// no rail reorder, no sash move may ride the same button hold.
	contentDown, railDragFrom, sashDragging = false, -1, false
	drag = dragSession{
		armed:   true,
		src:     id,
		mime:    mime,
		staged:  raw,
		catalog: dragCatalog(),
	}
	dragGhostPainted = false
	// An app starting a gesture is still hosted — the demo close
	// countdown restarts like every other RPC arm.
	hostTicksLeft = hostTicks
	dragLog(MarkerDragArm + vi.Itoa64(int64(id)) + " mime=" + mime +
		" len=" + vi.Itoa64(int64(len(blob))))
	return true
}

// serveDragCancel is the kind-26 request arm: the source's own abort.
// Only the armed source may cancel its own drag — a different window's
// cancel is refused, and no armed drag is an honest no-op refusal.
func serveDragCancel(req vi.WmRpc) bool {
	if !drag.armed || drag.src != uint32(req.ID) {
		return false
	}
	dragAbort("request")
	return true
}

// dragAbort ends the armed session without delivering: the kind-26
// notice goes to the source (its DragEnd sees delivered=false), the
// marker names the ending, the state clears.
func dragAbort(why string) {
	if !drag.armed {
		return
	}
	src, mime := drag.src, drag.mime
	dragNotice(src, vi.WmRpcKindDragCancel, 0, 0, mime)
	dragLog(MarkerDragCancel + vi.Itoa64(int64(src)) + " " + why)
	drag = dragSession{}
}

// dragNotice posts an asynchronous kind-25/26 frame to id's bound owner —
// reply_to=0, Pad=Bound + the session token, the shape a kind-15 settings
// notice rides. seq selects the recipient's role on a drop (0 = target
// delivery, 1 = source receipt); applied carries the peer window id.
// False when id is unbound (a window that cannot authenticate the notice
// cannot receive one) or the post refused.
func dragNotice(id uint32, kind, seq, applied uint8, mime string) bool {
	if id > 255 {
		return false
	}
	b := rpcBindings[id]
	if b.token == 0 || b.pid == 0 {
		return false
	}
	var ev vi.WmRpc
	ev.Kind = kind
	ev.ID = uint8(id)
	ev.Seq = seq
	ev.Applied = applied
	ev.Pad = vi.WmRpcPadBound
	vi.SetWmAuth(&ev, b.token)
	ev.SetTitle(mime)
	return dragPost(uint32(b.pid), ev.Encode()) >= 0
}

// handleDragPointer owns every kind-19 sample while a drag is armed.
// Motion tracks the ghost and re-resolves the hover; the up edge settles
// the drop. The caller (handleWmPointer) intercepts before any chrome
// path, so a drag can never click a toast or the rail.
func handleDragPointer(px, py uint32, up bool) {
	drag.x, drag.y = px, py
	// M184b (#3175): a held-drag sample pinned on the scanout boundary
	// is the pointer leaving the glass — hand the payload to the host
	// lane and end the guest gesture. The release edge never reaches
	// here once handed off (the session is already cleared).
	if !up && dragOutAtEdge(px, py) {
		dragOutHandoff()
		return
	}
	tgt, hit := dragTargetAt(px, py)
	accept := hit && opensAccepts(dragOpensFor(tgt), drag.mime)
	if tgt != drag.hover || accept != drag.accept {
		if hit {
			b := "0"
			if accept {
				b = "1"
			}
			dragLog(MarkerDragOver + vi.Itoa64(int64(tgt)) + " accept=" + b)
		} else {
			dragLog(MarkerDragOver + "none")
		}
		drag.hover, drag.accept = tgt, accept
	}
	if !up {
		return
	}
	dst := drag.hover
	if dst != 0 && drag.accept && dragDeliver(dst) {
		dragLog(MarkerDragDrop + vi.Itoa64(int64(dst)) +
			" from=" + vi.Itoa64(int64(drag.src)) + " mime=" + drag.mime)
		// Seq=1 receipt: the source learns who took it, and DragEnd
		// reports delivered=true.
		dragNotice(drag.src, vi.WmRpcKindDragDrop, 1, uint8(dst), drag.mime)
		drag = dragSession{}
		return
	}
	why := "empty"
	if dst != 0 && !drag.accept {
		why = "refuse" // hit a hosted window whose opens= says no
	} else if dst != 0 && drag.accept {
		why = "publish" // accepted but the handoff could not stage
	}
	dragAbort(why)
}

// dragDeliver republishes the consumed envelope under the TARGET's own
// rendezvous path and posts its Seq=0 delivery notice. The publish lands
// first: a notice that could not post takes the staged bytes back, so a
// delivery is never claimed without its payload.
func dragDeliver(dst uint32) bool {
	path := vi.DragPath(dst)
	if dragFileWrite(path, drag.staged) != 0 {
		return false
	}
	if !dragNotice(dst, vi.WmRpcKindDragDrop, 0, uint8(drag.src), drag.mime) {
		_ = dragFileDelete(path)
		return false
	}
	return true
}

// dragTargetAt resolves the hosted tab whose live window rect holds the
// pointer. The rects are the kind-20 mirror pair — surfaceXY's x|y<<16
// and gpu3dRects' w|h<<16, the seat's only legible geometry source. The
// rail band is chrome and never a drop target; a tab whose mirror never
// landed has no rect to hit. The focused tab wins an overlap — a split's
// abutting pane edges should land where the user is looking.
func dragTargetAt(px, py uint32) (uint32, bool) {
	if py < uint32(RailHeight) {
		return 0, false
	}
	fid, hasFocus := tabs.Focused()
	var hit uint32
	found := false
	for i := 0; i < tabs.Count(); i++ {
		id := tabs.At(i).ID
		if id >= sessionIDBase {
			continue // a restored placeholder has no window
		}
		xy, wh := surfaceXY[id], gpu3dRects[id]
		w, h := wh&0xffff, wh>>16
		if w == 0 || h == 0 {
			continue
		}
		x, y := xy&0xffff, xy>>16
		if px < x || px >= x+w || py < y || py >= y+h {
			continue
		}
		if hasFocus && id == fid {
			return id, true
		}
		hit, found = id, true
	}
	return hit, found
}

// dragOpensFor resolves the target window's opens= declarations: tab →
// its executable → the APPS.TXT row the arm read. An unmanifested bin or
// a non-tab window has no declarations — it refuses by omission.
func dragOpensFor(id uint32) []string {
	i := tabs.index(id)
	if i < 0 {
		return nil
	}
	bin := tabs.tabs[i].Bin
	for _, e := range drag.catalog {
		if e.Bin == bin {
			return e.Opens
		}
	}
	return nil
}

// opensAccepts is the drop admission rule — the only place opens= means
// anything on a drag. A row entry is an M81b family word (text, image,
// audio, archive, binary) or a full type/subtype spelling (text/plain,
// image/png; this card's vocabulary extension). A bare family word
// accepts any subtype under it — GOEDIT's opens=text takes text/plain,
// GOVIEW's opens=image takes image/png — while a subtype spelling takes
// only itself. Both directions are exact-byte compares; a mime the
// source declared and the seat validated is never substring-matched.
func opensAccepts(opens []string, mime string) bool {
	if mime == "" {
		return false
	}
	fam := mime
	for i := 0; i < len(mime); i++ {
		if mime[i] == '/' {
			fam = mime[:i]
			break
		}
	}
	for _, o := range opens {
		if o == mime {
			return true
		}
		slash := false
		for i := 0; i < len(o); i++ {
			if o[i] == '/' {
				slash = true
				break
			}
		}
		if !slash && o == fam {
			return true
		}
	}
	return false
}

// dragCatalog decodes APPS.TXT once per drag — the opens= authority the
// hit-test routes against, read through the same seam the launcher uses.
// A share the seat cannot read is an empty catalog: every target then
// refuses by opens= rather than the seat guessing at a handler.
func dragCatalog() []AppEntry {
	body, r := readAppsFile(appsPath, appsMaxBytes)
	if r < 0 {
		return nil
	}
	return parseAppsTXT(string(body))
}

// dropDragWindow is the drag half of window teardown — the same rule as
// the session token and the ask latch, running from dropRpcBinding: a
// dead source's armed drag can never finish (its mailbox died with it,
// so the abort is a silent clear, not a notice), a dead target's staged
// handoff must not survive into a reused id, and a dead hover simply
// stops being a candidate on the next sample.
func dropDragWindow(id uint32) {
	if id > 255 {
		return
	}
	if drag.armed && drag.src == id {
		dragLog(MarkerDragCancel + vi.Itoa64(int64(id)) + " dead")
		drag = dragSession{}
	}
	_ = dragFileDelete(vi.DragPath(id))
}

// paintDragGhost paints the armed drag's plate — the mime label riding
// the pointer, carrying the seat's identity rule tri-stated: Accent on
// an accepting hover, Danger over a window whose opens= refuses, Muted
// over chrome or nothing. It is painted after every other chrome layer
// (the gesture owns the frame while it lives) and clamps on-scanout.
func paintDragGhost(scan []byte) int {
	if !drag.armed {
		return 0
	}
	c := seatCanvas(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	if c == nil {
		return 0
	}
	tok := theme.Current
	label := drag.mime
	w := seatTextWidth(label, seatSmallPx) + 2*tok.PadMD + seatRuleW
	h := ChromeH
	x := int(drag.x) + 12
	y := int(drag.y) + 12
	if x+w > vi.ScanoutWidth {
		x = vi.ScanoutWidth - w
	}
	if y+h > vi.ScanoutHeight {
		y = vi.ScanoutHeight - h
	}
	if x < 0 {
		x = 0
	}
	if y < 0 {
		y = 0
	}
	rule := tok.Muted
	if drag.hover != 0 {
		if drag.accept {
			rule = tok.Accent
		} else {
			rule = tok.Danger
		}
	}
	plate := widgets.Rect{X: x, Y: y, W: w, H: h}
	seatShadow(c, plate, radiusControl)
	n := seatPlate(c, plate, radiusControl, rule, tok.Surface)
	seatText(c, plate, x+tok.PadMD+seatRuleW, y+chromePad, seatSmallPx, label, tok.Ink)
	return n
}

// dragGhostPaintMarker returns the presented-ghost marker once per drag
// — the MarkerNotifyPaint rule: a gate wants to know the ghost reached
// the scanout, and the marker lands only after the frame carrying it
// flushed.
func dragGhostPaintMarker(ghostPainted, presented bool) (string, bool) {
	if !ghostPainted || !presented || dragGhostPainted {
		return "", false
	}
	dragGhostPainted = true
	return MarkerDragGhost + vi.Itoa64(int64(drag.src)), true
}
