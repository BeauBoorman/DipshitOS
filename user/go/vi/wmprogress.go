// M123c (#2577): the progress-reporting half of the WM_RPC wire — kind 22
// client -> seat, kind 23 seat -> client.
//
// A progress report is a standing surface in the seat's notification
// center, not a transient toast: an app that is copying, downloading or
// indexing can tell the user "this is happening" without a dialog, and the
// user can say "stop" without finding the app's window. The wire is the
// frozen 38-byte frame, so the whole payload rides the 24-byte title as
// BINARY — the kind-17/18 raw-title precedent, not a SetTitle string:
//
//	title[0]  op:    the app-scoped operation id, 1..255. 0 is refused:
//	                 a report must name its operation so a later update
//	                 or the user's cancel can find it.
//	title[1]  pct:   0..100, or ProgressPctIndeterminate (0xff) for an
//	                 operation with no measurable total.
//	title[2:] label: NUL-padded, at most ProgressLabelMax bytes; the
//	                 center row's second line.
//
// The request id is the sender's own window, as with kind 12 — the row's
// click-back and the cancel route both come from it. The seat answers a
// live row's Cancel by pushing kind 23 (reply_to=0, the asynchronous
// notice shape kinds 15/20 already use) to the reporter's pid with
// title[0] = the cancelled op, so one frame cancels exactly one operation
// and a forged cancel still has to quote the window's session token.
package vi

const (
	// WmRpcKindProgress reports one operation's progress to the seat
	// (client -> seat). Additive — the frozen kinds are not renumbered.
	WmRpcKindProgress uint8 = 22
	// WmRpcKindProgressCancel is the seat's asynchronous cancel notice
	// (seat -> client, reply_to=0), pushed when the user presses a live
	// progress row's Cancel.
	WmRpcKindProgressCancel uint8 = 23
	// ProgressPctIndeterminate is title[1]'s "unknown total" byte.
	ProgressPctIndeterminate uint8 = 0xff
)

// ProgressIndeterminate is the pct argument for an operation with no
// measurable total — the seat paints the sweeping bar, not a fraction.
const ProgressIndeterminate = -1

// ProgressLabelMax is the wire's label budget: the title minus the op and
// pct bytes. A longer label is truncated, the same bound kind 12's message
// text already lives inside.
const ProgressLabelMax = WmRpcTitleMax - 2

// EncodeProgressTitle packs op/pct/label into the kind-22 title field.
// ok=false only for op==0: no operation id means no row to update and no
// op to cancel, so a report without one is refused before the mailbox.
// pct is clamped to the wire's 0..100; negative selects the indeterminate
// byte. The label is truncated at the wire budget.
func EncodeProgressTitle(op uint8, pct int, label string) ([WmRpcTitleMax]byte, bool) {
	if op == 0 {
		return [WmRpcTitleMax]byte{}, false
	}
	var t [WmRpcTitleMax]byte
	t[0] = op
	switch {
	case pct < 0:
		t[1] = ProgressPctIndeterminate
	case pct > 100:
		t[1] = 100
	default:
		t[1] = byte(pct)
	}
	copy(t[2:], label)
	return t, true
}

// DecodeProgressTitle is the seat-side inverse. A byte 101..0xfe in
// title[1] is neither a percent nor the indeterminate mark — a malformed
// frame is refused rather than painted as a plausible-looking row.
func DecodeProgressTitle(t [WmRpcTitleMax]byte) (op uint8, pct int, label string, ok bool) {
	if t[0] == 0 {
		return 0, 0, "", false
	}
	if t[1] == ProgressPctIndeterminate {
		pct = ProgressIndeterminate
	} else if t[1] <= 100 {
		pct = int(t[1])
	} else {
		return 0, 0, "", false
	}
	n := 2
	for n < len(t) && t[n] != 0 {
		n++
	}
	return t[0], pct, string(t[2:n]), true
}

// NotifyProgress posts winID's progress report to the seat (kind 22).
// op names the operation this report belongs to — a second report with the
// same op updates the center's row in place, a different op is another
// row — so an app running several operations gives each a stable id. pct
// is 0..100 or ProgressIndeterminate. The label is the row's second line;
// it shares the notify text's short-string budget (ProgressLabelMax).
//
// Progress rows are a Go-seat surface, so like gpu3d and the surface
// handoff the request refuses (false) before the mailbox when no Go seat
// is registered — a Zig seat would only refuse the unknown kind anyway.
// A refused or timed-out ack likewise returns false, and the caller
// should say so rather than assume the user is watching a bar.
func NotifyProgress(winID uint32, op uint8, pct int, label, selfName string) bool {
	t, ok := EncodeProgressTitle(op, pct, label)
	if !ok || !fitsWire8(winID) {
		return false
	}
	peers := WmPeers(selfName)
	if peers.WM == 0 || peers.Self == 0 || !fitsWire8(peers.Self) || !peers.Go {
		return false
	}
	rep, ok := wmRequestGoTitle(WmRpcKindProgress, uint8(winID), t, label, peers)
	return ok && rep.Applied != 0
}

// PollProgressCancel returns the op the user cancelled in the seat's
// notification center — the asynchronous kind-23 frame, reply_to=0 —
// or ok=false when none is queued. Same inbox discipline as
// PollSettingChanged and PollStateAsk: a bound window accepts only a
// notice quoting its session token, so a forged cancel cannot stop an
// operation the attacker does not own. It never waits; the event loop
// calls it once per pass and routes the op to the right widget.
func PollProgressCancel(winID uint32) (op uint8, ok bool) {
	if !fitsWire8(winID) {
		return 0, false
	}
	matches := func(m WmRpc) bool {
		if m.Kind != WmRpcKindProgressCancel || m.ReplyTo != 0 ||
			m.ID != uint8(winID) || m.Title[0] == 0 {
			return false
		}
		if tok := wmToken(uint8(winID)); tok != 0 {
			return m.Pad == WmRpcPadBound && WmAuth(m) == tok
		}
		return true
	}
	if m, ok := takePendingWmMessage(matches); ok {
		return m.Title[0], true
	}
	for i := 0; i < MailboxMaxMessages; i++ {
		m, ok := receiveWmMessage()
		if !ok {
			return 0, false
		}
		if matches(m) {
			return m.Title[0], true
		}
		enqueueWmMessage(m)
	}
	return 0, false
}
