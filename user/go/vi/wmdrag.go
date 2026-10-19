// M124a (#2580): the guest drag-and-drop protocol's transport half.
//
// The seat mediates drops between apps. A drag begins when the SOURCE app
// publishes its payload at the staged-share rendezvous and posts
// drag_begin carrying the mime spelling in the frame title (the same
// 24-byte budget SetTabTitle lives inside); the seat owns the ghost and
// the hit-test from there, and the release edge either delivers to the
// hit-tested target or reports the ending back to the source:
//
//	drag_begin  (24): source -> seat request. Title = mime (e.g.
//	    "text/plain"); the blob already waits in the staged envelope.
//	    applied=1 arms the drag.
//	drag_drop   (25): seat -> app async notice (reply_to=0, Pad=Bound +
//	    the session token — the shape a kind-15 settings notice rides).
//	    TWO roles, discriminated by Seq: Seq=0 is the TARGET's delivery —
//	    Applied = the source window id, the payload is republished at the
//	    target's own rendezvous path; Seq=1 is the SOURCE's receipt —
//	    Applied = the target window id, nothing is staged for it.
//	drag_cancel (26): source -> seat request aborts the armed drag; seat
//	    -> source async notice (Seq=0) reports an ending that delivered
//	    nothing (release over chrome, a refusing target, a publish
//	    refusal, the source window dying mid-drag).
//
// Like M125a's app_state (D7), the 38-byte frame cannot carry the blob:
// the payload rides a staged share file — vi.DragPath — published
// crash-safe by whichever side sends it and deleted by the receiver.
// Consume-on-use again: a staging file is a handoff, never storage, so a
// stale payload can never be delivered twice or inherited by a reused id.
//
// Envelope: `u8 mime_len | mime[mime_len] | u32 len LE | blob[len]`. The
// mime is duplicated from the drag_begin frame deliberately — the seat
// refuses an arm whose envelope disagrees with its frame, so the ghost's
// label and the delivered bytes can never describe different things.
package vi

const (
	// WmRpcKindDragBegin arms a seat-mediated drag (24). The request's
	// title field carries the mime spelling; the blob is staged at
	// DragPath(win) before the request posts. Kinds 22/23 are M123c's
	// Progress/ProgressCancel — the drag kinds start at 24.
	WmRpcKindDragBegin uint8 = 24
	// WmRpcKindDragDrop is the seat's delivery notice (25). Seq selects
	// the recipient's role: 0 = this window is the TARGET (Applied holds
	// the source window id; DragTake reads the payload), 1 = this window
	// is the SOURCE's receipt (Applied holds the target window id).
	WmRpcKindDragDrop uint8 = 25
	// WmRpcKindDragCancel aborts an armed drag (26). As a request it is
	// the source's own abort; as a notice it is the seat reporting an
	// undelivered ending.
	WmRpcKindDragCancel uint8 = 26
)

// DragMax is the v1 per-drag payload bound — the same 64 KiB the
// app_state rendezvous carries. The seat holds the staged bytes while the
// drag is armed, so the bound is a BSS budget, not a policy.
const DragMax = 64 * 1024

// dragHdrLen is the envelope's fixed framing: mime_len(1) + mime(≤24) +
// len(4). The mime field is bounded by the frame title's width so the
// envelope never describes a type the request could not have carried.
const dragHdrLen = 1 + WmRpcTitleMax + 4

// DragPath is the staged-file rendezvous for win's drag payload — one
// spelling for both directions, derived from the window id so nothing
// about the location is negotiated on the wire (AppStatePath's shape).
func DragPath(win uint32) string {
	return "/host/DRAG." + Itoa64(int64(win))
}

// EncodeDrag frames mime+blob into the staged envelope. ok=false for an
// empty mime, one too wide for the frame title, or a blob over DragMax —
// the sender refuses rather than publishing something the receiver must
// drop.
func EncodeDrag(mime string, blob []byte) ([]byte, bool) {
	if mime == "" || len(mime) > WmRpcTitleMax || len(blob) > DragMax {
		return nil, false
	}
	out := make([]byte, 1+len(mime)+4+len(blob))
	out[0] = byte(len(mime))
	copy(out[1:], mime)
	putU32(out[1+len(mime):], uint32(len(blob)))
	copy(out[1+len(mime)+4:], blob)
	return out, true
}

// DecodeDrag is the total inverse: a short header, a mime_len over the
// title bound, a length over DragMax, or a file whose size does not match
// the declared length exactly is refused (ok=false) rather than trusted —
// the same discipline DecodeAppState pins.
func DecodeDrag(b []byte) (mime string, blob []byte, ok bool) {
	if len(b) < 1 || int(b[0]) > WmRpcTitleMax {
		return "", nil, false
	}
	ml := int(b[0])
	if len(b) < 1+ml+4 {
		return "", nil, false
	}
	n := int(getU32(b[1+ml:]))
	if n > DragMax || len(b) != 1+ml+4+n {
		return "", nil, false
	}
	if ml == 0 {
		return "", nil, false
	}
	return string(b[1 : 1+ml]), b[1+ml+4:], true
}

// The staged-file seams — the appstate.go pattern: the raw syscall
// gateway degrades to -ENOSYS off the guest, so the vars keep the client
// half observable to a host test.
var (
	dragFileWrite  = WriteFileSafe
	dragFileRead   = ReadFileAll
	dragFileDelete = FileDelete
)

// DragBegin stages blob at DragPath(winID) and posts the kind-24 request —
// the source's arm. The seat deletes the staging file when it takes the
// drag; a refused request leaves it behind, so the app cleans its own slot
// then (the handoff was never claimed). false on a missing seat, a refused
// ack, an over-bounded payload, or a stage failure.
func DragBegin(winID uint32, mime string, blob []byte, selfName string) bool {
	enc, ok := EncodeDrag(mime, blob)
	if !ok {
		return false
	}
	if dragFileWrite(DragPath(winID), enc) != 0 {
		return false
	}
	if WmMailRequest(WmRpcKindDragBegin, winID, 0, 0, 0, 0, mime, selfName) {
		return true
	}
	_ = dragFileDelete(DragPath(winID))
	return false
}

// DragCancel posts the kind-26 request: the source's own abort of its
// armed drag (the app-side Esc). false when no drag was armed or the
// request was refused.
func DragCancel(winID uint32, selfName string) bool {
	return WmMailRequest(WmRpcKindDragCancel, winID, 0, 0, 0, 0, "", selfName)
}

// DragNotice is one decoded seat→app drag frame. Kind is
// WmRpcKindDragDrop or WmRpcKindDragCancel. On a drop, Receipt selects
// the role: false = this window is the TARGET (Peer is the source window;
// DragTake reads the staged payload), true = this window is the SOURCE's
// delivery receipt (Peer is the target window). On a cancel, Peer is 0
// and nothing was delivered.
type DragNotice struct {
	Kind    uint8
	Receipt bool
	Peer    uint32
	Mime    string
}

// PollDragNotice returns the next asynchronous drag frame for winID —
// seat-pushed, reply_to=0, never waits. Same inbox discipline as
// PollSettingChanged/PollStateAsk: a bound window accepts only notices
// carrying its session token, so a forged delivery cannot hand a target a
// payload it was never sent.
func PollDragNotice(winID uint32) (DragNotice, bool) {
	if !fitsWire8(winID) {
		return DragNotice{}, false
	}
	matches := func(m WmRpc) bool {
		if m.ReplyTo != 0 || m.ID != uint8(winID) {
			return false
		}
		if m.Kind != WmRpcKindDragDrop && m.Kind != WmRpcKindDragCancel {
			return false
		}
		if tok := wmToken(uint8(winID)); tok != 0 {
			return m.Pad == WmRpcPadBound && WmAuth(m) == tok
		}
		return true
	}
	decode := func(m WmRpc) DragNotice {
		return DragNotice{
			Kind:    m.Kind,
			Receipt: m.Kind == WmRpcKindDragDrop && m.Seq == 1,
			Peer:    uint32(m.Applied),
			Mime:    m.TitleString(),
		}
	}
	if m, ok := takePendingWmMessage(matches); ok {
		return decode(m), true
	}
	for i := 0; i < MailboxMaxMessages; i++ {
		m, ok := receiveWmMessage()
		if !ok {
			return DragNotice{}, false
		}
		if matches(m) {
			return decode(m), true
		}
		enqueueWmMessage(m)
	}
	return DragNotice{}, false
}

// DragTake consumes the staged envelope a delivered drop left at
// DragPath(winID): read, delete, decode. ok=false when nothing is staged —
// a consumed handoff honestly finds nothing — or the envelope is
// malformed. The returned mime is the envelope's own claim, checked
// against the frame's at arm time by the seat.
func DragTake(winID uint32) (mime string, blob []byte, ok bool) {
	path := DragPath(winID)
	raw, r := dragFileRead(path, 1+WmRpcTitleMax+4+DragMax)
	if r < 0 {
		return "", nil, false
	}
	_ = dragFileDelete(path)
	return DecodeDrag(raw)
}
