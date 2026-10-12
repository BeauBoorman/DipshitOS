package main

// ADR 0044 D5 / AC2: the kind-16 seat paging table — 0, 1, 4, 5 and 16
// tabs, a start past the end, and an ENOSPC that ends a page mid-way —
// plus the routing proof that the query is answered ahead of gateRPC and
// never draws a challenge.

import (
	"testing"

	"virelai/vi"
)

// wqTab is one scripted strip entry for the paging table.
type wqTab struct {
	id            uint32
	title         string
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

func TestServeWindowsQueryPages(t *testing.T) {
	for _, tc := range []struct {
		name      string
		tabs      int
		start     uint8
		wantRows  int // reply frames
		wantFirst int // index of first row frame, or -1 for the applied=0 path
	}{
		{"empty strip", 0, 0, 1, -1},
		{"one tab", 1, 0, 1, 0},
		{"full page", 4, 0, 4, 0},
		{"second page short", 5, 4, 1, 4},
		{"full strip first page", 16, 0, 4, 0},
		{"full strip last page", 16, 12, 4, 12},
		{"start past end", 5, 5, 1, -1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stageTabs(t, wqTabs(tc.tabs))
			frames := captureWqSend(t, -1)
			req := vi.WmRpc{Kind: wmKindWindowsQuery, ID: tc.start, Seq: 7, ReplyTo: 9}
			serveWindowsQuery(req)
			if len(*frames) != tc.wantRows {
				t.Fatalf("reply frames = %d want %d", len(*frames), tc.wantRows)
			}
			for i, m := range *frames {
				if m.Kind != wmKindWindowsQuery|vi.WmRpcReplyFlag ||
					m.Seq != req.Seq || m.ReplyTo != req.ReplyTo ||
					m.Pad != vi.WmRpcPadPlain {
					t.Fatalf("frame %d shape = %+v", i, m)
				}
				if int(m.W) != tc.tabs {
					t.Fatalf("frame %d count W = %d want %d", i, m.W, tc.tabs)
				}
			}
			if tc.wantFirst < 0 {
				if (*frames)[0].Applied != 0 {
					t.Fatalf("empty-page frame Applied = %d want 0", (*frames)[0].Applied)
				}
				return
			}
			for i, m := range *frames {
				if m.Applied != 1 {
					t.Fatalf("row frame %d Applied = %d", i, m.Applied)
				}
				if int(m.ID) != tc.wantFirst+i {
					t.Fatalf("row frame %d index = %d want %d", i, m.ID, tc.wantFirst+i)
				}
				if uint32(m.X) != uint32(100+tc.wantFirst+i) {
					t.Fatalf("row frame %d window id = %d", i, m.X)
				}
			}
		})
	}
}

// The focused/pinned/frozen flag bits land in Y (D5), with the title in the
// 24-byte field.
func TestServeWindowsQueryFlagsAndTitle(t *testing.T) {
	stageTabs(t, []wqTab{
		{id: 10, title: "Calc"},
		{id: 11, title: "PinnedTab", pinned: true},
		{id: 12, title: "FrozenTab", frozen: true},
	})
	// OpenTab focuses the first entry when the strip was empty.
	frames := captureWqSend(t, -1)
	req := vi.WmRpc{Kind: wmKindWindowsQuery, ID: 0, Seq: 1, ReplyTo: 3}
	serveWindowsQuery(req)
	if len(*frames) != 3 {
		t.Fatalf("frames = %d want 3", len(*frames))
	}
	// Pinned normalizes to the left of the rail, so order is
	// PinnedTab, Calc, FrozenTab; Calc stays focused.
	want := []struct {
		title string
		flags uint16
	}{
		{"PinnedTab", 0x2},
		{"Calc", 0x1},
		{"FrozenTab", 0x4},
	}
	_ = want
	got := *frames
	if got[0].TitleString() != "PinnedTab" || got[0].Y != 0x2 {
		t.Fatalf("frame 0 = %q flags %#x", got[0].TitleString(), got[0].Y)
	}
	if got[1].TitleString() != "Calc" || got[1].Y&0x1 == 0 {
		t.Fatalf("frame 1 = %q flags %#x want focused", got[1].TitleString(), got[1].Y)
	}
	if got[2].TitleString() != "FrozenTab" || got[2].Y != 0x4 {
		t.Fatalf("frame 2 = %q flags %#x", got[2].TitleString(), got[2].Y)
	}
	focused := 0
	for _, m := range got {
		if m.Y&0x1 != 0 {
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
	req := vi.WmRpc{Kind: wmKindWindowsQuery, ID: 0, Seq: 1, ReplyTo: 3}
	serveWindowsQuery(req)
	if len(*frames) != 2 {
		t.Fatalf("frames after ENOSPC = %d want 2", len(*frames))
	}
}

// No reply_to means nowhere to answer — the query is dropped, not sent.
func TestServeWindowsQueryNoReplyTo(t *testing.T) {
	stageTabs(t, wqTabs(2))
	frames := captureWqSend(t, -1)
	serveWindowsQuery(vi.WmRpc{Kind: wmKindWindowsQuery, ID: 0, Seq: 1, ReplyTo: 0})
	if len(*frames) != 0 {
		t.Fatalf("reply_to=0 sent %d frames", len(*frames))
	}
}

// serviceRPC serves kind 16 BEFORE gateRPC: no challenge ack, no binding
// state touched, and the strip answers plainly — even with live bindings
// for other windows.
func TestServiceRPCRoutesWindowsQueryBeforeGate(t *testing.T) {
	stageTabs(t, wqTabs(2))
	dropAllRpcBindings()
	t.Cleanup(dropAllRpcBindings)
	rpcBindings[5] = rpcBinding{pid: 1, token: 0xdead}

	req := vi.WmRpc{Kind: wmKindWindowsQuery, ID: 0, Seq: 9, ReplyTo: 42}
	acks := decodeAcks(t, serveOneWmRpc(t, req.Encode()))
	if len(acks) != 2 {
		t.Fatalf("kind-16 acks = %d want 2 row frames", len(acks))
	}
	for i, a := range acks {
		if a.Kind != wmKindWindowsQuery|vi.WmRpcReplyFlag || a.Applied != 1 ||
			a.Pad != vi.WmRpcPadPlain {
			t.Fatalf("ack %d = %+v want plain applied row", i, a)
		}
	}
	// The query drew no challenge and minted no binding.
	if rpcChallenges[0] != 0 {
		t.Fatal("windows query minted a challenge")
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
