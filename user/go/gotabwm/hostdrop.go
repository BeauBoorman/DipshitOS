// GOTABWM.ELF — M108c (#2326, ADR 0051 D4): the file-drop lane, seat half.
//
// The runner lands bulk payloads in /host/INBOX/ itself (temp+rename — the
// guest never sees a partial file) and announces each one with a signed
// DROP record. The seat's part is the NOTICE: the engine verifies
// epoch/MAC/seq, this file decodes [name_len u8][name][size u64le], and
// the toast `host drop: <name>` goes through the same bounded strip every
// kind-12 notice uses. M127b (V2-D4) makes the toast actionable: sender
// stays 0 (there is still no tab to focus) but the click — or the center
// row's activation — runs the `open-drop` action bound to the name the
// verified record carried (dropopen.go).
//
// The payload file is unsigned bulk content by design: provenance is the
// record, so a guest app planting a file in INBOX/ produces no notice and
// the seat never attributes a guest-written file to the host. Delivery
// and notice are independent — the seat does not check INBOX before
// toasting (the runner's `host-drop: file` marker is the delivery
// receipt), and MIME dispatch is the M81b path unchanged: `open` /
// GOFILES sniff the head and the registry picks the app.
package main

import (
	"virelai/hostint"
	"virelai/vi"
)

// MarkerHostintDrop is the seat's drop-lane receipt — seq + sanitized name
// + size, the same shape the runner's `host-drop: file` marker carries.
const MarkerHostintDrop = "gotabwm: hostint drop "

// dropPayload decodes the D4 notice payload [name_len u8][name][size
// u64le]. ok=false is the caller's bad_record refusal — a length that does
// not add up exactly is a malformed record, not a delivery. The name goes
// verbatim into the serial marker line and the toast text, so it is
// sanitized on decode (dropName): a raw control byte would split the
// marker the class-B gate greps.
func dropPayload(p []byte) (name string, size uint64, ok bool) {
	if len(p) < 1+1+8 {
		return "", 0, false
	}
	n := int(p[0])
	if n == 0 || len(p) != 1+n+8 {
		return "", 0, false
	}
	for i := 7; i >= 0; i-- {
		size = size<<8 | uint64(p[1+n+i])
	}
	return dropName(p[1 : 1+n]), size, true
}

// dropName renders the payload's raw name bytes marker-safe: control bytes
// (<0x20, DEL) become '?' — a newline in a host-dropped filename would
// otherwise split the serial marker line. Bytes ≥ 0x80 pass through: the
// name may be UTF-8 and the sender is the trusted runner.
func dropName(raw []byte) string {
	b := make([]byte, len(raw))
	for i, c := range raw {
		if c < 0x20 || c == 0x7f {
			c = '?'
		}
		b[i] = c
	}
	return string(b)
}

// hostdropApply is the engine's Consume hook for TagDrop — verified
// records only. It announces the landing through the seat's own kind-12
// path (notifyPush: bounded strip, center history, chime, DND hold) with
// the same marker discipline the WM_RPC handler prints: drop-first, then
// the accepted (or held) toast line.
func hostdropApply(rec hostint.Record) string {
	name, size, ok := dropPayload(rec.Payload)
	if !ok {
		return hostint.RefuseBadRecord
	}
	text := "host drop: " + name
	hostintLog(MarkerHostintDrop + "seq=" + vi.Itoa64(int64(rec.Seq)) +
		" name=" + name + " size=" + vi.Itoa64(int64(size)))
	// V2-D4: the toast carries the open-drop action bound to THIS record's
	// sanitized name — the click can never be retargeted at a file the
	// record did not announce. The binding lands on the center row too,
	// so a DND-held notice stays actionable there.
	_, _, dropped := notifyPushAction(0, text, compositeClock, notifyActionDropOpen, name)
	if dropped {
		hostintLog(MarkerNotifyDrop + vi.Itoa64(int64(notifyDropped)))
	}
	if notifyDND {
		hostintLog(MarkerNotifyHeld + "0 " + text)
	} else {
		hostintLog(MarkerNotify + "0 " + text)
	}
	return ""
}
