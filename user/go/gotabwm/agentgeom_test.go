package main

// Card #2985 (ADR 0044 D5c): the kind-30 seat handler over a fixture
// tree — the principal check, each named refusal, the query payload
// against PaneRectsAll itself, and the move/sash ops riding the seat's
// own apply paths.

import (
	"testing"

	"virelai/vi"
)

// geomSwap stubs the two seams serveAgentGeom shares with kind 29 —
// the proc-name principal check and the ack send — returning the sent
// frames for decode.
func geomSwap(t *testing.T, name string) (sent *[][]byte) {
	t.Helper()
	savedName := agentProcName
	t.Cleanup(func() { agentProcName = savedName })
	agentProcName = func(pid uint32) (string, bool) {
		return name, true
	}
	out := [][]byte{}
	savedSend := agentIpcSend
	t.Cleanup(func() { agentIpcSend = savedSend })
	agentIpcSend = func(pid uint32, b []byte) int64 {
		out = append(out, append([]byte(nil), b...))
		return int64(len(b))
	}
	return &out
}

func geomReq(op byte, id uint32, arg byte) vi.WmRpc {
	var req vi.WmRpc
	req.Kind = wmKindAgentGeom
	req.ID = 7
	req.ReplyTo = 42
	req.Title[0] = op
	req.Title[1] = byte(id)
	req.Title[2] = byte(id >> 8)
	req.Title[3] = arg
	return req
}

// geomAck decodes the single reply frame a request drew.
func geomAck(t *testing.T, sent *[][]byte) vi.WmRpc {
	t.Helper()
	if len(*sent) != 1 {
		t.Fatalf("acks = %d want 1", len(*sent))
	}
	rep, ok := vi.DecodeWmRpc((*sent)[0])
	if !ok {
		t.Fatal("ack decode")
	}
	return rep
}

// A bound request whose pid is not AGENTD.ELF refuses by name before the
// op is even weighed — the marker and the ack title both carry
// win_geometry_denied.
func TestAgentGeomDeniedNotAgentd(t *testing.T) {
	defer saveSeatState()()
	sent := geomSwap(t, "GOEDIT.ELF")
	serveAgentGeom(geomReq(agentGeomOpQuery, 3, 0), 0)
	rep := geomAck(t, sent)
	if rep.Applied != 0 || rep.TitleString() != agentGeomDeny {
		t.Fatalf("ack applied=%d title=%q want 0/%q",
			rep.Applied, rep.TitleString(), agentGeomDeny)
	}
}

// The query answers the rect PaneRectsAll computes — the same numbers
// the layout dump prints — plus the space, the pane index, and the
// parent split's kind.
func TestAgentGeomQueryTwoPanes(t *testing.T) {
	defer saveSeatState()()
	openTwoTabs(t)
	_, restore := rectRecorder()
	defer restore()
	if !applySplit(SplitVert) {
		t.Fatal("applySplit")
	}
	sent := geomSwap(t, "AGENTD.ELF")
	panes := tabs.PaneRectsAll(uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
	if len(panes) != 2 {
		t.Fatalf("panes = %d want 2", len(panes))
	}
	for i, p := range panes {
		*sent = nil
		serveAgentGeom(geomReq(agentGeomOpQuery, p.id, 0), 0)
		rep := geomAck(t, sent)
		v, ok := vi.WmGeomDecode(rep)
		if !ok {
			t.Fatalf("tab %d: ack applied=%d title=%q", p.id, rep.Applied, rep.TitleString())
		}
		if v.Space != 0 || v.Pane != uint8(i) || v.Split != uint8(SplitVert) {
			t.Fatalf("tab %d: space=%d pane=%d split=%d want 0/%d/%d",
				p.id, v.Space, v.Pane, v.Split, i, SplitVert)
		}
		if uint32(v.X) != p.rect.X || uint32(v.Y) != p.rect.Y ||
			uint32(v.W) != p.rect.W || uint32(v.H) != p.rect.H {
			t.Fatalf("tab %d: rect %dx%dx%dx%d want %v",
				p.id, v.X, v.Y, v.W, v.H, p.rect)
		}
	}
}

// An unplaced tab has no leaf: the query reports the full-viewport
// stack, split=none and the unplaced pane sentinel rather than a pane
// number.
func TestAgentGeomQueryUnplaced(t *testing.T) {
	defer saveSeatState()()
	openTwoTabs(t)
	sent := geomSwap(t, "AGENTD.ELF")
	serveAgentGeom(geomReq(agentGeomOpQuery, 3, 0), 0)
	rep := geomAck(t, sent)
	v, ok := vi.WmGeomDecode(rep)
	if !ok {
		t.Fatalf("ack applied=%d title=%q", rep.Applied, rep.TitleString())
	}
	full := FullRect(uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
	if v.Pane != vi.WmGeomUnplaced || v.Split != uint8(SplitNone) ||
		uint32(v.X) != full.X || uint32(v.W) != full.W || uint32(v.H) != full.H {
		t.Fatalf("unplaced view = %+v", v)
	}
}

// The sash op lands on the leaf's parent node through the drag's own
// release path: percent maps onto the node rect, the tree stores the
// clamped centre, and every pane's rect goes through the kernel seam.
func TestAgentGeomSash(t *testing.T) {
	defer saveSeatState()()
	openTwoTabs(t)
	calls, restore := rectRecorder()
	defer restore()
	if !applySplit(SplitVert) {
		t.Fatal("applySplit")
	}
	*calls = nil
	sent := geomSwap(t, "AGENTD.ELF")
	serveAgentGeom(geomReq(agentGeomOpSash, 3, 30), 0)
	rep := geomAck(t, sent)
	if rep.Applied == 0 {
		t.Fatalf("sash refused: %q", rep.TitleString())
	}
	// 30 % of the root's 1280-px rect centres the gutter at x=384, so the
	// left pane lands at 381 px wide.
	want := 384
	if tabs.tree[0].sash != want {
		t.Fatalf("sash = %d want %d", tabs.tree[0].sash, want)
	}
	panes := tabs.PaneRectsAll(uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
	if len(panes) != 2 || panes[0].rect.W != 381 {
		t.Fatalf("panes after sash = %+v", panes)
	}
	if len(*calls) == 0 {
		t.Fatal("the relayout never reached the kernel seam")
	}
}

// The move op rides applySpaceMove: the tab leaves the live strip for
// the named space's strip, its window hides through the kernel seam,
// and a next query reports the new space index.
func TestAgentGeomMove(t *testing.T) {
	defer saveSeatState()()
	openTwoTabs(t)
	var hidden []uint32
	savedVis := wmctlSetVisible
	t.Cleanup(func() { wmctlSetVisible = savedVis })
	wmctlSetVisible = func(id uint32, visible bool) int64 {
		if !visible {
			hidden = append(hidden, id)
		}
		return 0
	}
	sent := geomSwap(t, "AGENTD.ELF")
	serveAgentGeom(geomReq(agentGeomOpMove, 4, 1), 0)
	rep := geomAck(t, sent)
	if rep.Applied == 0 {
		t.Fatalf("move refused: %q", rep.TitleString())
	}
	if tabs.index(4) >= 0 || spaceN != 2 || spaces[1].Strip.index(4) < 0 {
		t.Fatalf("after move: live has 4=%v spaceN=%d dormant has 4=%v",
			tabs.index(4) >= 0, spaceN, spaces[1].Strip.index(4) >= 0)
	}
	if len(hidden) != 1 || hidden[0] != 4 {
		t.Fatalf("hidden = %v want [4]", hidden)
	}
	// A dormant row still answers the query — the move stays
	// addressable — with its new space index.
	*sent = nil
	serveAgentGeom(geomReq(agentGeomOpQuery, 4, 0), 0)
	rep = geomAck(t, sent)
	v, ok := vi.WmGeomDecode(rep)
	if !ok || v.Space != 1 {
		t.Fatalf("moved query = %+v ok=%v want space 1", v, ok)
	}
}

// Every malformed or inapplicable op is bad_op; an id no strip row
// holds is no_window. Each refusal still answers — the ack names it.
func TestAgentGeomRefusals(t *testing.T) {
	defer saveSeatState()()
	openTwoTabs(t)
	sent := geomSwap(t, "AGENTD.ELF")
	for _, tc := range []struct {
		name string
		req  vi.WmRpc
		want string
	}{
		{"bad op", geomReq(9, 3, 0), agentGeomBadOp},
		{"query absent", geomReq(agentGeomOpQuery, 99, 0), agentGeomNoWindow},
		{"move absent", geomReq(agentGeomOpMove, 99, 1), agentGeomNoWindow},
		{"move past spaces", geomReq(agentGeomOpMove, 3, MaxSpaces), agentGeomBadOp},
		{"move same space", geomReq(agentGeomOpMove, 3, 0), agentGeomBadOp},
		{"sash absent", geomReq(agentGeomOpSash, 99, 30), agentGeomNoWindow},
		{"sash pct low", geomReq(agentGeomOpSash, 3, 9), agentGeomBadOp},
		{"sash pct high", geomReq(agentGeomOpSash, 3, 91), agentGeomBadOp},
		{"sash unsplit", geomReq(agentGeomOpSash, 3, 30), agentGeomBadOp},
	} {
		*sent = nil
		serveAgentGeom(tc.req, 0)
		rep := geomAck(t, sent)
		if rep.Applied != 0 || rep.TitleString() != tc.want {
			t.Fatalf("%s: ack applied=%d title=%q want 0/%q",
				tc.name, rep.Applied, rep.TitleString(), tc.want)
		}
	}
}
