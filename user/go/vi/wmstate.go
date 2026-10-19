// M125a (#2586): the per-app state protocol's transport half — the staged
// file a WM_RPC frame cannot carry.
//
// A request frame is 38 bytes inside a 64-byte mailbox slot; a state blob
// is up to 64 KiB. The blob therefore rides a staged share file and the
// frames are only the rendezvous:
//
//	save_state (20):   the app crash-safe-publishes the envelope at
//	                   AppStatePath(win), then posts the request; the seat
//	                   reads, validates, stores the blob on the tab's
//	                   `.tabs` record, and deletes the staging file.
//	restore_state (21): the app posts the request; the seat publishes the
//	                   stored envelope and acks applied; the app reads and
//	                   deletes the staging file.
//
// Both directions are consume-on-use: the staging file is a handoff,
// never storage, so a stale blob can never be delivered twice or to a
// later window that reuses the id.
//
// Envelope: `u8 appver | u32 len LE | blob[len]`. `appver` is the app's
// own format tag — the seat stores and returns it verbatim so an app can
// refuse a stale serialization; the seat reads only the framing.
package vi

const (
	// AppStateMax is the card's per-app blob bound: 64 KiB. An envelope
	// declaring more is refused before it is stored or delivered.
	AppStateMax = 64 * 1024
	// appStateHdr is the envelope's fixed framing: ver(1) + len(4).
	appStateHdr = 5
)

// AppStatePath is the staged-file rendezvous for win's state blob — one
// spelling both directions, derived from the window id so nothing about
// the location is negotiated on the wire.
func AppStatePath(win uint32) string {
	return "/host/APPSTATE." + Itoa64(int64(win))
}

// EncodeAppState frames blob into the staged-file envelope. ok=false when
// the blob is over the per-app bound — the sender refuses rather than
// publishing something the receiver must drop.
func EncodeAppState(ver uint8, blob []byte) ([]byte, bool) {
	if len(blob) > AppStateMax {
		return nil, false
	}
	out := make([]byte, appStateHdr+len(blob))
	out[0] = ver
	putU32(out[1:], uint32(len(blob)))
	copy(out[appStateHdr:], blob)
	return out, true
}

// DecodeAppState is the total inverse: a short envelope, a length that
// does not match the file's exact size, or a declared length over
// AppStateMax is refused (ok=false) rather than trusted.
func DecodeAppState(b []byte) (ver uint8, blob []byte, ok bool) {
	if len(b) < appStateHdr {
		return 0, nil, false
	}
	n := int(getU32(b[1:]))
	if n > AppStateMax || len(b) != appStateHdr+n {
		return 0, nil, false
	}
	return b[0], b[appStateHdr:], true
}

// The staged-file seams. WriteFileSafe/ReadFileAll/FileDelete go through
// the raw syscall gateway on the guest and degrade to -ENOSYS off it; the
// vars keep the client-side publish/read/delete observable to a host
// test the same way gotabwm's writeHostFile/readSessionFile work.
var (
	appStateWrite = WriteFileSafe
	appStateRead  = ReadFileAll
	appStateDel   = FileDelete
)

// PostStateSave stages blob at AppStatePath(winID) and posts the kind-20
// request — the app's answer to a PollStateAsk notice, or an unsolicited
// save when the app's own state moved. The seat deletes the staging file
// after it reads; a refused request leaves the file, so the app cleans
// its own staging slot then (the handoff was never claimed).
func PostStateSave(winID uint32, ver uint8, blob []byte, selfName string) bool {
	enc, ok := EncodeAppState(ver, blob)
	if !ok {
		return false
	}
	if appStateWrite(AppStatePath(winID), enc) != 0 {
		return false
	}
	if WmMailRequest(WmRpcKindSaveState, winID, 0, 0, 0, 0, "", selfName) {
		return true
	}
	_ = appStateDel(AppStatePath(winID))
	return false
}

// PollStateAsk reports whether the seat has asked this window to
// serialize — the asynchronous kind-20 notice (reply_to=0). Same inbox
// discipline as PollSettingChanged: a bound window accepts only notices
// carrying its session token, so a forged ask cannot provoke a save.
// It never waits; the event loop calls it once per pass.
func PollStateAsk(winID uint32) bool {
	if !fitsWire8(winID) {
		return false
	}
	matches := func(m WmRpc) bool {
		if m.Kind != WmRpcKindSaveState || m.ReplyTo != 0 ||
			m.ID != uint8(winID) {
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

// RequestStateRestore asks the seat for this window's stored blob (kind
// 21). On an applied ack the envelope waits at AppStatePath — this reads
// it, deletes the staging file, and returns the blob with the appver tag
// it was stored under. ok=false covers both "no stored state" (a fresh
// start, the honest empty answer) and every transport refusal — an app
// treats both as "start clean".
func RequestStateRestore(winID uint32, selfName string) (ver uint8, blob []byte, ok bool) {
	rep, answered := wmRequest(WmRpcKindRestoreState, winID, 0, 0, 0, 0, "", selfName)
	if !answered || rep.Applied == 0 {
		return 0, nil, false
	}
	path := AppStatePath(winID)
	raw, r := appStateRead(path, AppStateMax+appStateHdr)
	if r < 0 {
		return 0, nil, false
	}
	_ = appStateDel(path)
	v, b, ok := DecodeAppState(raw)
	if !ok {
		return 0, nil, false
	}
	return v, b, true
}
