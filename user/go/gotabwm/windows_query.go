// WM_RPC kind 16, WINDOWS_QUERY (ADR 0044 D5): the agentd seat query. It
// reads seat-wide strip state and mutates nothing, but it is NOT exempt
// from M97g-F2: serviceRPC routes it through gateRPC like every other
// request, so a kind-16 frame must arrive from a window the caller owns
// and is bound to — owner ruling: auth wins over the pre-auth exemption.
// The page index rides the request title's first byte (id is the bound
// window and x/y/w/h are the auth union).
//
// Reply frames quote the session token in x/y/w/h, so the row payload
// cannot share them: a row carries its strip index in ID and packs
// title[0:2]=window id LE, title[2]=flags, title[3:]=tab title (21-byte
// cap). Every request ends with one applied=0 end-of-page frame whose
// title[0] is the strip count — the client learns the page is done and
// whether another start remains without a W field to quote.
package main

import "virelai/vi"

// wmKindWindowsQuery is the additive request kind; wqPageSize is the D5
// page bound (four row frames plus the end frame fit the mailbox ring).
const (
	wmKindWindowsQuery uint8 = 16
	wqPageSize               = 4
)

// wqSend is the mailbox seam so host tests can watch the page shape —
// the same injectable-seam pattern closeWin/focusRaise use.
var wqSend = vi.IpcSend

// MarkerWq is the one serial line per query (D6): indices and counts only.
const MarkerWq = "gotabwm: wq start="

// serveWindowsQuery answers one bound kind-16 request; auth is the window's
// session token from gateRPC, quoted in every reply frame. The page index
// is req.Title[0]. Rows in [start, min(start+4, count)) each get one
// applied reply frame, then ONE applied=0 end-of-page frame with
// title[0]=count always follows (a start past the end sends only that
// frame). A send that fails ends the page without a retry — the client's
// own budget expires instead (D5).
func serveWindowsQuery(req vi.WmRpc, auth uint64) {
	if req.ReplyTo == 0 {
		return
	}
	start := int(req.Title[0])
	count := tabs.Count()
	sent := 0
	if start < count {
		end := start + wqPageSize
		if end > count {
			end = count
		}
		fid, focused := tabs.Focused()
		for i := start; i < end; i++ {
			t := tabs.At(i)
			rep := buildReply(req, true, "", vi.WmRpcPadBound, auth)
			rep.ID = uint8(i)
			rep.Title[0] = byte(t.ID)
			rep.Title[1] = byte(t.ID >> 8)
			var flags byte
			if focused && t.ID == fid {
				flags |= 0x1
			}
			if t.Pinned {
				flags |= 0x2
			}
			if t.Frozen {
				flags |= 0x4
			}
			rep.Title[2] = flags
			copy(rep.Title[3:], t.Title)
			if wqSend(uint32(req.ReplyTo), rep.Encode()) < 0 {
				break
			}
			sent++
		}
	}
	term := buildReply(req, false, "", vi.WmRpcPadBound, auth)
	term.Title[0] = byte(count)
	_ = wqSend(uint32(req.ReplyTo), term.Encode())
	vi.ConsoleLine(MarkerWq + vi.Itoa64(int64(start)) +
		" rows=" + vi.Itoa64(int64(sent)) + " count=" + vi.Itoa64(int64(count)))
}
