// GOTABWM.ELF — M127c (#2601, ADR 0051 V2-D3): notify click-through, the
// seat half.
//
// The loop: a toast pushed with sender T emits NOTIFY_OUT{sender_id=T};
// the runner binds T to the banner it posts, and a click — or the
// notify-click bus verb, the class-B equivalent — sends a signed
// NOTIFY_FOCUS{sender_id=T} back. The record is plen 0 by wire contract:
// the header's sender field IS the whole request (the codec refuses any
// other shape at both encode and decode, so what reaches this file is
// already verified: MAC, epoch, seq, lane_notify mask bit).
//
// A verified record runs focusHosted — the same seam alt-tab, rail
// clicks and the strip's own toast clicks take, so the app receives the
// real WIN_FOCUS and the refusal story is the ADR's: sender 0 cannot be
// emitted lawfully (bad_record — the one field the record carries is
// absent), a tab that died between banner and click is `gone`, never
// silent.
package main

import (
	"virelai/hostint"
	"virelai/vi"
)

// MarkerHostintNotifyFocus is the seat's consume receipt — the NFOCUS
// record's seq and the tab it focused, the mirror of the runner's
// `host-notify: click-focus` line. Printed only on a successful focus;
// declines are the shared `refuse lane=notify reason=<code>` shape.
const MarkerHostintNotifyFocus = "gotabwm: hostint notify-focus "

// hostfocusFocus is the seam the verified record dispatches through —
// focusHosted itself. A var on the paletteFocus precedent: the seat's
// slot-65 focus syscall cannot run under `go test`, so the host test
// substitutes a recorder.
var hostfocusFocus = focusHosted

func init() { hostfocusConsume = hostfocusApply }

// hostfocusApply is the engine's NOTIFY_FOCUS route (wired through the
// hostfocusConsume hook so this file needs no hostint.go change): the
// sender names the tab to raise. Returns "" on success — the receipt
// line below is this file's own — or the refusal code the engine logs.
func hostfocusApply(rec hostint.Record) string {
	if rec.Sender == 0 {
		// The tag's whole payload is the sender; a signed record without
		// one violates the wire contract (the encoder refuses to emit
		// it), so the decode-shape refusal is the honest name.
		return hostint.RefuseBadRecord
	}
	id := uint32(rec.Sender)
	if !hostfocusFocus(id) {
		return hostint.RefuseGone
	}
	hostintLog(MarkerHostintNotifyFocus + "seq=" + vi.Itoa64(int64(rec.Seq)) +
		" id=" + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(id)))
	return ""
}
