// WM_RPC kind 16, WINDOWS_QUERY (ADR 0044 D5): the agentd seat query. It
// reads seat-wide strip state, binds no window and mutates nothing, so
// serviceRPC serves it BEFORE gateRPC — no challenge, no token, no
// binding. The reply is paged four rows to a request (the 8-slot mailbox
// bound); each row carries the kernel window id in X, the flag bits in Y
// (bit 0 focused, bit 1 pinned, bit 2 frozen), and the strip count in W.
package main

import "virelai/vi"

// wmKindWindowsQuery is the additive request kind; wqPageSize is the D5
// page bound (four frames per request, fitting the mailbox ring).
const (
	wmKindWindowsQuery uint8 = 16
	wqPageSize               = 4
)

// wqSend is the mailbox seam so host tests can watch the page shape —
// the same injectable-seam pattern closeWin/focusRaise use.
var wqSend = vi.IpcSend

// MarkerWq is the one serial line per query (D6): indices and counts only.
const MarkerWq = "gotabwm: wq start="

// serveWindowsQuery answers one kind-16 request. Rows in
// [start, min(start+4, count)) each get one applied reply frame; a start
// past the strip's end (including an empty strip) gets a single
// applied=0 frame with W=count. A send that fails ends the page without
// a retry — the client's own budget expires instead (D5).
func serveWindowsQuery(req vi.WmRpc) {
	if req.ReplyTo == 0 {
		return
	}
	start := int(req.ID)
	count := tabs.Count()
	sent := 0
	if start >= count {
		rep := buildReply(req, false, "", vi.WmRpcPadPlain, 0)
		rep.W = uint16(count)
		_ = wqSend(uint32(req.ReplyTo), rep.Encode())
	} else {
		end := start + wqPageSize
		if end > count {
			end = count
		}
		fid, focused := tabs.Focused()
		for i := start; i < end; i++ {
			t := tabs.At(i)
			rep := buildReply(req, true, "", vi.WmRpcPadPlain, 0)
			rep.ID = uint8(i)
			rep.X = uint16(t.ID)
			var flags uint16
			if focused && t.ID == fid {
				flags |= 0x1
			}
			if t.Pinned {
				flags |= 0x2
			}
			if t.Frozen {
				flags |= 0x4
			}
			rep.Y = flags
			rep.W = uint16(count)
			rep.SetTitle(t.Title)
			if wqSend(uint32(req.ReplyTo), rep.Encode()) < 0 {
				break
			}
			sent++
		}
	}
	vi.ConsoleLine(MarkerWq + vi.Itoa64(int64(start)) +
		" rows=" + vi.Itoa64(int64(sent)) + " count=" + vi.Itoa64(int64(count)))
}
