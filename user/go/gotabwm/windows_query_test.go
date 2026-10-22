package main

// ADR 0044 D5 / AC2: the kind-16 seat paging table — 0, 1, 4, 5 and 16
// tabs, a start past the end, and an ENOSPC that ends a page mid-way —
// plus the routing proof that the query now rides the M97g-F2 bind: an
// unbound kind-16 frame is challenged, bad credentials are refused, and
// only a bound window's page requests carry the session token.

import (
	"testing"

	"virelai/vi"
)

// wqTab is one scripted strip entry for the paging table.
type wqTab struct {
	id             uint32
	title          string
	pinned, frozen bool
}

// stageTabs installs a strip of n rows and returns a restore func.
func stageTabs(t *testing.T, rows []wqTab) {
	t.Helper()
	savedTabs := tabs
	tabs = TabStrip{}
	for _, r := range rows {
		if !tabs.OpenTab(r.id, r.title) {
			t.Fatalf("OpenTab(%d)", r.id)
		}
		if r.pinned {
			tabs.Pin(r.id)
		}
		if r.frozen {
			tabs.Freeze(r.id)
		}
	}
	t.Cleanup(func() { tabs = savedTabs })
}

// captureWqSend replaces the send seam, recording every reply frame.
func captureWqSend(t *testing.T, failAfter int) (frames *[]vi.WmRpc) {
	t.Helper()
	got := &[]vi.WmRpc{}
	prev := wqSend
	sent := 0
	wqSend = func(target uint32, b []byte) int64 {
		sent++
		if failAfter >= 0 && sent > failAfter {
			return -vi.ErrENOSPC
		}
		if m, ok := vi.DecodeWmRpc(b); ok {
			*got = append(*got, m)
		}
		return int64(len(b))
	}
	t.Cleanup(func() { wqSend = prev })
	return got
}

func wqTabs(n int) []wqTab {
	rows := make([]wqTab, n)
	for i := 0; i < n; i++ {
		rows[i] = wqTab{id: uint32(100 + i), title: "T"}
	}
	return rows
}

// wqQueryReq builds a kind-16 request as the bound client sends it: id is
// the caller's window, the page start rides title[0].
func wqQueryReq(winID uint8, start int) vi.WmRpc {
	req := vi.WmRpc{Kind: wmKindWindowsQuery, ID: winID, Seq: 7, ReplyTo: 9}
	req.Title[0] = byte(start)
	return req
}

func TestServeWindowsQueryPages(t *testing.T) {
	const auth = 0xbeef
	for _, tc := range []struct {
		name      string
		tabs      int
		start     int
		wantRows  int // applied row frames (the end frame always adds one)
		wantFirst int // index of first row frame, or -1 for an empty page
	}{
		{"empty strip", 0, 0, 0, -1},
		{"one tab", 1, 0, 1, 0},
		{"full page", 4, 0, 4, 0},
		{"second page short", 5, 4, 1, 4},
		{"full strip first page", 16, 0, 4, 0},
		{"full strip last page", 16, 12, 4, 12},
		{"start past end", 5, 5, 0, -1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stageTabs(t, wqTabs(tc.tabs))
			frames := captureWqSend(t, -1)
			req := wqQueryReq(5, tc.start)
			serveWindowsQuery(req, auth)
			if len(*frames) != tc.wantRows+1 {
				t.Fatalf("reply frames = %d want %d rows + end", len(*frames), tc.wantRows)
			}
			for i, m := range *frames {
				if m.Kind != wmKindWindowsQuery|vi.WmRpcReplyFlag ||
					m.Seq != req.Seq || m.ReplyTo != req.ReplyTo ||
					m.Pad != vi.WmRpcPadBound || vi.WmAuth(m) != auth {
					t.Fatalf("frame %d shape = %+v", i, m)
				}
			}
			// The last frame is the end-of-page marker: applied=0 with
			// the strip count in title[0].
			term := (*frames)[len(*frames)-1]
			if term.Applied != 0 || int(term.Title[0]) != tc.tabs {
				t.Fatalf("end frame = %+v want applied=0 count=%d", term, tc.tabs)
			}
			for i, m := range (*frames)[:tc.wantRows] {
				if m.Applied != 1 {
					t.Fatalf("row frame %d Applied = %d", i, m.Applied)
				}
				if int(m.ID) != tc.wantFirst+i {
					t.Fatalf("row frame %d index = %d want %d", i, m.ID, tc.wantFirst+i)
				}
				winID := uint32(m.Title[0]) | uint32(m.Title[1])<<8
				if winID != uint32(100+tc.wantFirst+i) {
					t.Fatalf("row frame %d window id = %d", i, winID)
				}
			}
		})
	}
}

// The flag bits land in title[2] and the tab title starts at title[3]
// (x/y/w/h quote the token). Rows decode through this helper.
func wqRowTail(m vi.WmRpc) string {
	n := 3
	for n < len(m.Title) && m.Title[n] != 0 {
		n++
	}
	return string(m.Title[3:n])
}

func TestServeWindowsQueryFlagsAndTitle(t *testing.T) {
	stageTabs(t, []wqTab{
		{id: 10, title: "Calc"},
		{id: 11, title: "PinnedTab", pinned: true},
		{id: 12, title: "FrozenTab", frozen: true},
	})
	// OpenTab focuses the first entry when the strip was empty.
	frames := captureWqSend(t, -1)
	serveWindowsQuery(wqQueryReq(5, 0), 0xbeef)
	if len(*frames) != 4 {
		t.Fatalf("frames = %d want 3 rows + end", len(*frames))
	}
	// Pinned normalizes to the left of the rail, so order is
	// PinnedTab, Calc, FrozenTab; Calc stays focused.
	got := (*frames)[:3]
	if wqRowTail(got[0]) != "PinnedTab" || got[0].Title[2] != 0x2 {
		t.Fatalf("frame 0 = %q flags %#x", wqRowTail(got[0]), got[0].Title[2])
	}
	if wqRowTail(got[1]) != "Calc" || got[1].Title[2]&0x1 == 0 {
		t.Fatalf("frame 1 = %q flags %#x want focused", wqRowTail(got[1]), got[1].Title[2])
	}
	if wqRowTail(got[2]) != "FrozenTab" || got[2].Title[2] != 0x4 {
		t.Fatalf("frame 2 = %q flags %#x", wqRowTail(got[2]), got[2].Title[2])
	}
	focused := 0
	for _, m := range got {
		if m.Title[2]&0x1 != 0 {
			focused++
		}
	}
	if focused != 1 {
		t.Fatalf("focused rows = %d want exactly 1", focused)
	}
}

// A failed send ends the page without a retry (D5): the client budget,
// not the seat, owns the timeout.
func TestServeWindowsQuerySendFailureEndsPage(t *testing.T) {
	stageTabs(t, wqTabs(8))
	frames := captureWqSend(t, 2) // the third send fails
	serveWindowsQuery(wqQueryReq(5, 0), 0xbeef)
	if len(*frames) != 2 {
		t.Fatalf("frames after ENOSPC = %d want 2", len(*frames))
	}
}

// No reply_to means nowhere to answer — the query is dropped, not sent.
func TestServeWindowsQueryNoReplyTo(t *testing.T) {
	stageTabs(t, wqTabs(2))
	frames := captureWqSend(t, -1)
	serveWindowsQuery(vi.WmRpc{Kind: wmKindWindowsQuery, ID: 5, Seq: 1, ReplyTo: 0}, 0xbeef)
	if len(*frames) != 0 {
		t.Fatalf("reply_to=0 sent %d frames", len(*frames))
	}
}

// serviceRPC routes kind 16 THROUGH gateRPC: an unbound request draws the
// ownership challenge and no row frames; a bound request with the wrong
// pid or token is refused plainly; only the bound owner's frames carry
// rows — each quoting Pad=Bound + the session token.
func TestServiceRPCGatesWindowsQuery(t *testing.T) {
	stageTabs(t, wqTabs(2))
	ownerTitle := ""
	stubAuthSeams(t, func(id uint8) (string, bool) {
		if id != 5 || ownerTitle == "" {
			return "", false
		}
		return ownerTitle, true
	})

	// 1. Unbound: a bare kind-16 frame is challenged — never served.
	req := wqQueryReq(5, 0)
	acks := decodeAcks(t, serveOneWmRpc(t, req.Encode()))
	if len(acks) != 1 || acks[0].Pad != vi.WmRpcPadChallenge || acks[0].Applied != 0 {
		t.Fatalf("unbound kind-16 acks = %+v want one challenge", acks)
	}
	challenge := vi.WmAuth(acks[0])
	if challenge == 0 || rpcChallenges[5] != challenge {
		t.Fatalf("challenge = %#x table = %#x", challenge, rpcChallenges[5])
	}

	// 2. The owner proves the title and echoes: the echo itself is a page
	//    request, and its bound row frames both mint the token and answer.
	ownerTitle = vi.WmBindChallengeTitle(challenge, 9)
	req.Pad = vi.WmRpcPadBound
	req.Seq = 8
	vi.SetWmAuth(&req, challenge)
	acks = decodeAcks(t, serveOneWmRpc(t, req.Encode()))
	if len(acks) != 3 {
		t.Fatalf("bound echo acks = %d want 2 rows + end", len(acks))
	}
	token := vi.WmAuth(acks[0])
	if token == 0 || token == challenge {
		t.Fatalf("row token = %#x", token)
	}
	for i, a := range acks[:2] {
		if a.Pad != vi.WmRpcPadBound || vi.WmAuth(a) != token || a.Applied != 1 {
			t.Fatalf("row %d = %+v want bound applied", i, a)
		}
	}
	if acks[2].Applied != 0 || acks[2].Pad != vi.WmRpcPadBound || vi.WmAuth(acks[2]) != token {
		t.Fatalf("end frame = %+v want bound end-of-page", acks[2])
	}
	if rpcBindings[5].pid != 9 || rpcBindings[5].token != token {
		t.Fatalf("binding = %+v want pid 9 token %#x", rpcBindings[5], token)
	}

	// 3. Bound but forged: wrong token, right pid → bare refusal, no rows.
	forged := wqQueryReq(5, 0)
	forged.Pad = vi.WmRpcPadBound
	vi.SetWmAuth(&forged, token^0xff)
	acks = decodeAcks(t, serveOneWmRpc(t, forged.Encode()))
	if len(acks) != 1 || acks[0].Pad != vi.WmRpcPadPlain || acks[0].Applied != 0 {
		t.Fatalf("forged-token acks = %+v want bare refusal", acks)
	}

	// 4. Bound but forged: right token, wrong pid → bare refusal, no rows.
	wrongPid := wqQueryReq(5, 0)
	wrongPid.ReplyTo = 3
	wrongPid.Pad = vi.WmRpcPadBound
	vi.SetWmAuth(&wrongPid, token)
	acks = decodeAcks(t, serveOneWmRpc(t, wrongPid.Encode()))
	if len(acks) != 1 || acks[0].Pad != vi.WmRpcPadPlain || acks[0].Applied != 0 {
		t.Fatalf("wrong-pid acks = %+v want bare refusal", acks)
	}

	// 5. The bound owner's next page request answers without a rebind.
	page := wqQueryReq(5, 0)
	page.Pad = vi.WmRpcPadBound
	page.Seq = 12
	vi.SetWmAuth(&page, token)
	acks = decodeAcks(t, serveOneWmRpc(t, page.Encode()))
	if len(acks) != 3 {
		t.Fatalf("bound page acks = %d want 2 rows + end", len(acks))
	}
	for i, a := range acks {
		if a.Pad != vi.WmRpcPadBound || vi.WmAuth(a) != token {
			t.Fatalf("page frame %d = %+v", i, a)
		}
	}
}

// A kind-16 frame with the reply bit set is an ack, not a request — the
// seat must not answer its own replies.
func TestServiceRPCSkipsWindowsQueryAck(t *testing.T) {
	stageTabs(t, wqTabs(1))
	req := vi.WmRpc{Kind: wmKindWindowsQuery | vi.WmRpcReplyFlag, ID: 0,
		Seq: 1, ReplyTo: 3}
	acks := serveOneWmRpc(t, req.Encode())
	if len(acks) != 0 {
		t.Fatalf("seat answered an ack frame: %d replies", len(acks))
	}
}
