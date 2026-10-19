// M124e (#2584): the seat-owned primary selection's transport half.
//
// The seat holds ONE primary buffer — the last selection any opted-in app
// published. The 38-byte WM_RPC frame cannot carry it, so the payload
// rendezvous is a staged share file (vi.SelPath) in both directions,
// exactly like M125a's app_state and M124a's drag envelope:
//
//	sel_publish (27): the app stages `u32 len | bytes` at SelPath(win),
//	    then posts the request; the seat reads, validates, stores the
//	    bytes as THE primary buffer, and deletes the staging file. A
//	    refused request (no selection=primary cap, malformed envelope)
//	    leaves the file, so the app cleans its own slot then — the
//	    handoff was never claimed.
//	sel_paste (28): bidirectional, the kind-20 pattern —
//	    seat -> app notice (reply_to=0, Pad=Bound + the session token):
//	        middle-click or the seat's paste chord landed on this window;
//	        the buffer is already staged at SelPath(win) — SelTake reads
//	        and deletes it.
//	    app -> seat request: the pull half for a keyboard-driven paste;
//	        the seat stages the buffer at SelPath(win) and acks applied;
//	        RequestSelPaste reads and deletes it.
//
// Consume-on-use like every staged handoff in this seam: a staging file
// is delivery, never storage, so a reused window id can never inherit a
// dead window's paste.
//
// The card's chord check, for the record: Ctrl+Shift+V is NOT free — the
// seat owns it for split-cycle (M79c, exercised by go-drag.spec) and the
// kernel's terminal-window path owns it for clipboard paste (M73e), so
// the keyboard spelling ships as Shift+Insert, the canonical
// primary-paste chord, served at seat scope.
package vi

const (
	// WmRpcKindSelPublish is the app->seat arm (27): the request says the
	// staged envelope waits at SelPath(win). Kinds 24-26 are M124a's drag
	// trio — the selection kinds start at 27.
	WmRpcKindSelPublish uint8 = 27
	// WmRpcKindSelPaste delivers the buffer (28). As a notice (reply_to=0)
	// it is the seat pushing a middle-click/chord delivery; as a request
	// it is the app pulling the buffer for its own keyboard chord.
	WmRpcKindSelPaste uint8 = 28
)

// SelMax is the per-selection bound. Primary is text: 8 KiB covers a long
// paragraph while keeping the seat's buffer a bounded BSS carve-out, not
// a policy.
const SelMax = 8 * 1024

// selHdr is the envelope's fixed framing: len(4). The file's exact size
// is the integrity check (DecodeAppState's discipline).
const selHdr = 4

// SelPath is the staged-file rendezvous for win's selection bytes — one
// spelling for publish, notice delivery, and pull request, derived from
// the window id so nothing about the location is negotiated on the wire.
func SelPath(win uint32) string {
	return "/host/SEL." + Itoa64(int64(win))
}

// EncodeSel frames the selection bytes into the staged envelope. ok=false
// for a payload over SelMax — the sender refuses rather than publishing
// something the receiver must drop.
func EncodeSel(text []byte) ([]byte, bool) {
	if len(text) > SelMax {
		return nil, false
	}
	out := make([]byte, selHdr+len(text))
	putU32(out[:4], uint32(len(text)))
	copy(out[selHdr:], text)
	return out, true
}

// DecodeSel is the total inverse: a short envelope, a declared length
// over SelMax, or a file whose size does not match the declared length
// exactly is refused (ok=false) rather than trusted.
func DecodeSel(b []byte) ([]byte, bool) {
	if len(b) < selHdr {
		return nil, false
	}
	n := int(getU32(b[:4]))
	if n > SelMax || len(b) != selHdr+n {
		return nil, false
	}
	return b[selHdr:], true
}

// The staged-file seams — the wmstate.go/wmdrag.go pattern: the raw
// syscall gateway degrades to -ENOSYS off the guest, so the vars keep the
// client half observable to a host test.
var (
	selFileWrite  = WriteFileSafe
	selFileRead   = ReadFileAll
	selFileDelete = FileDelete
)

// SelPublish stages text at SelPath(winID) and posts the kind-27 request —
// the app's "my selection changed" arm. The seat deletes the staging file
// when it stores the buffer; a refused request leaves it behind, so the
// app cleans its own slot then. false on a missing seat, a refused ack
// (no selection=primary cap is one refusal), an over-bounded payload, or
// a stage failure.
func SelPublish(winID uint32, text []byte, selfName string) bool {
	enc, ok := EncodeSel(text)
	if !ok {
		return false
	}
	if selFileWrite(SelPath(winID), enc) != 0 {
		return false
	}
	if WmMailRequest(WmRpcKindSelPublish, winID, 0, 0, 0, 0, "", selfName) {
		return true
	}
	_ = selFileDelete(SelPath(winID))
	return false
}

// PollSelPaste reports whether a seat delivery notice is waiting for
// winID — the asynchronous kind-28 frame (reply_to=0). Same inbox
// discipline as PollDragNotice/PollStateAsk: a bound window accepts only
// notices carrying its session token, so a forged delivery cannot hand
// the window a payload it was never sent. Never waits; the event loop
// calls it once per pass.
func PollSelPaste(winID uint32) bool {
	if !fitsWire8(winID) {
		return false
	}
	matches := func(m WmRpc) bool {
		if m.ReplyTo != 0 || m.ID != uint8(winID) {
			return false
		}
		if m.Kind != WmRpcKindSelPaste {
			return false
		}
		if tok := wmToken(uint8(winID)); tok != 0 {
			return m.Pad == WmRpcPadBound && WmAuth(m) == tok
		}
		return true
	}
	if _, ok := takePendingWmMessage(matches); ok {
		return true
	}
	for i := 0; i < MailboxMaxMessages; i++ {
		m, ok := receiveWmMessage()
		if !ok {
			return false
		}
		if matches(m) {
			return true
		}
		enqueueWmMessage(m)
	}
	return false
}

// SelTake consumes the staged envelope a delivery left at SelPath(winID):
// read, delete, decode. ok=false when nothing is staged — a consumed
// handoff honestly finds nothing — or the envelope is malformed.
func SelTake(winID uint32) ([]byte, bool) {
	path := SelPath(winID)
	raw, r := selFileRead(path, selHdr+SelMax)
	if r < 0 {
		return nil, false
	}
	_ = selFileDelete(path)
	return DecodeSel(raw)
}

// RequestSelPaste is the pull half: the app's keyboard-chord request
// (kind 28 as a request). On an applied ack the buffer's envelope waits
// at SelPath — this reads it, deletes the staging file, and returns the
// bytes. ok=false covers "no primary selection", a cap-less requester's
// refusal, and every transport failure — all the same honest answer: no
// paste happened.
func RequestSelPaste(winID uint32, selfName string) ([]byte, bool) {
	rep, answered := wmRequest(WmRpcKindSelPaste, winID, 0, 0, 0, 0, "", selfName)
	if !answered || rep.Applied == 0 {
		return nil, false
	}
	return SelTake(winID)
}
