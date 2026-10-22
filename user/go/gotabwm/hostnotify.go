// GOTABWM.ELF — M108d (#2328, ADR 0051 D5): the notify-out lane, seat half.
//
// Every toast the seat queues on the kind-12 strip while the lane is armed
// also becomes a signed NOTIFY_OUT record carrying the same ≤24-byte text —
// and, since M127c (ADR 0051 V2-D3), the toast's sender tab id in the
// record's sender_id, so a macOS banner click can echo it back as a
// NOTIFY_FOCUS (hostfocus.go owns the inbound half).
// the strip itself is the M97g user-visible indicator, so what the user sees
// on glass is exactly what crosses it. A notice held under do-not-disturb
// never reaches the strip, so it never crosses either: DND's "do not flash
// me" posture must not be defeated by a macOS banner.
//
// The rate bound is structural (D5): ≤1 record emitted per seat tick
// (~1 Hz) and ≤ MaxOutstanding unconsumed (the strip's own depth). Toasts
// arriving between ticks wait in a pending queue of the same depth; overflow
// drops the oldest pending copy through the strip's own `notify drop
// total=` accounting (D5's reuse rule — the toast stays on the strip, what
// is dropped is the host-side copy), and a backpressured emit holds for the
// next tick rather than dropping: the runner's 250 ms drain paces us.
package main

import (
	"virelai/hostint"
	"virelai/shlib"
	"virelai/vi"
)

// MarkerHostintNotifyOut is the seat's emit receipt — seq, len and
// sha256[:8], the same shape the clip lane's markers carry. The toast text
// itself rides MarkerNotify already; the lane marker never repeats it
// (never-logged contract).
const MarkerHostintNotifyOut = "gotabwm: hostint notify-out "

// hostNotifyPendingEntry is one staged toast: the wire-bounded text plus
// its sender — the toast's tabID, which is the correlation a macOS banner
// click echoes back as NOTIFY_FOCUS{sender_id} (M127c, ADR 0051 V2-D3).
// Seat-originated toasts (host drops, agent milestones, action toasts)
// stage sender 0: there is no tab to focus, so a click emits no record.
type hostNotifyPendingEntry struct {
	sender uint32
	text   string
}

// hostNotifyPending is the lane's outbound staging: toasts accepted
// since the last emit, oldest first, bounded at the strip's own depth.
var hostNotifyPending []hostNotifyPendingEntry

// hostnotifyQueue is notifyPush's one-line hook: a toast that just reached
// the strip stages its text for the lane. It runs only while the engine
// holds a verified ARMED naming the notify bit — dormant otherwise, so a
// flags-off or consent-off boot never buffers text for a lane that cannot
// carry it.
//
// The sender is read off the strip itself: the hook runs immediately
// after notifyPushAction's queue append, so the newest queued toast is
// the one being staged — no second plumbing of tabID through the call.
func hostnotifyQueue(text string) {
	eng := hostintEngine
	if eng == nil || !eng.Armed() || eng.LaneMask()&hostint.LaneNotify == 0 {
		return
	}
	if len(hostNotifyPending) >= hostint.MaxOutstanding {
		// Full: drop the OLDEST pending copy — the strip's own eviction
		// order — and account it through the same counter and marker the
		// strip reports, per D5's accounting reuse.
		hostNotifyPending = hostNotifyPending[1:]
		notifyDropped++
		hostintLog(MarkerNotifyDrop + vi.Itoa64(int64(notifyDropped)))
	}
	var sender uint32
	if n := len(notifyQueue); n > 0 {
		sender = notifyQueue[n-1].tabID
	}
	hostNotifyPending = append(hostNotifyPending, hostNotifyPendingEntry{sender: sender, text: text})
}

// hostnotifyPoll drains at most one pending toast per tick into a signed
// NOTIFY_OUT record — the 1-per-tick half of the D5 bound (the 4-outstanding
// half is the engine's Emit check). A backpressured emit keeps the entry
// queued for next tick; a hard refusal consumes the entry and names it once.
func hostnotifyPoll() {
	eng := hostintEngine
	if eng == nil || len(hostNotifyPending) == 0 {
		return
	}
	entry := hostNotifyPending[0]
	// The wire's sender_id is u16; a window id wider than that cannot
	// cross. 0 is the honest name for "no tab to focus" (V2-D3: a click
	// on such a banner raises the runner's window and stops).
	sender := uint16(entry.sender)
	if uint32(sender) != entry.sender {
		sender = 0
	}
	seq, refusal := eng.EmitSender(hostint.TagNotifyOut, 0, sender, []byte(entry.text))
	switch refusal {
	case "":
		hostNotifyPending = hostNotifyPending[1:]
		sum := shlib.SHA256Sum([]byte(entry.text))
		hostintLog(MarkerHostintNotifyOut + "seq=" + vi.Itoa64(int64(seq)) +
			" len=" + vi.Itoa64(int64(len(entry.text))) + " sha=" + hostint.HexDigest8(sum[:]))
	case hostint.RefuseBackpressure:
		// The runner has four of ours unconsumed — wait a tick.
	case hostint.RefuseLaneDisabled:
		// A posture refusal (lane_disabled after a re-ARMED mask change)
		// kills the whole staging queue: the consent that staged them is
		// gone, so the tail goes with the head, named once.
		hostNotifyPending = hostNotifyPending[:0]
		eng.RefuseLane(hostint.TagNotifyOut, refusal)
	default:
		// A per-entry refusal — payload_too_large on an over-budget
		// toast, io_error on the publish — condemns the head entry only.
		// The rest of the queue is not party to it: drop the one, name
		// the refusal, keep the tail.
		hostNotifyPending = hostNotifyPending[1:]
		eng.RefuseLane(hostint.TagNotifyOut, refusal)
	}
}
