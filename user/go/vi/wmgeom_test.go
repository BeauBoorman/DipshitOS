package vi

// Card #2985 (ADR 0044 D5c): the kind-30 client — the packed request
// title, the bound-window exchange, the applied query payload decode,
// and the three ack shapes (applied, named refusal, silence).

import "testing"

// agentGeomSeat scripts the Go seat's kind-30 answer: challenge an
// unbound request, bind the echo, and answer bound requests with the
// applied or refusal-named ack serveAgentGeom sends.
type agentGeomSeat struct {
	challenge uint64
	token     uint64
	refusal   string    // ack title when set (applied=0)
	view      WmGeomView // payload when refusal is empty
	saw       []WmRpc
}

func (s *agentGeomSeat) reply(req WmRpc) []byte {
	if req.Kind != WmRpcKindAgentGeom {
		return nil
	}
	s.saw = append(s.saw, req)
	auth := WmAuth(req)
	if s.challenge == 0 {
		s.challenge = 0x0a9e17
	}
	if (s.token != 0 && auth == s.token) || auth == s.challenge {
		if s.token == 0 {
			s.token = 0x7ab1e5
		}
		rep := WmRpc{Kind: WmRpcKindAgentGeom | WmRpcReplyFlag,
			ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo,
			Pad: WmRpcPadBound}
		SetWmAuth(&rep, s.token)
		if s.refusal != "" {
			copy(rep.Title[:], s.refusal)
		} else {
			rep.Applied = 1
			if req.Title[0] == WmGeomOpQuery {
				rep.Title[0] = s.view.Space
				rep.Title[1] = s.view.Pane
				rep.Title[2] = s.view.Split
				put := func(i int, v uint16) {
					rep.Title[i] = byte(v)
					rep.Title[i+1] = byte(v >> 8)
				}
				put(3, s.view.X)
				put(5, s.view.Y)
				put(7, s.view.W)
				put(9, s.view.H)
			}
		}
		return rep.Encode()
	}
	rep := WmRpc{Kind: WmRpcKindAgentGeom | WmRpcReplyFlag,
		ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo,
		Pad: WmRpcPadChallenge}
	SetWmAuth(&rep, s.challenge)
	return rep.Encode()
}

func startAgentGeomFake(t *testing.T, seat *agentGeomSeat) *wmMailFake {
	t.Helper()
	f := startWmMailFake(t)
	f.wmName = wmGoSeatName
	f.extraProcs = append(f.extraProcs, namedProc(9, "AGENTD.ELF"))
	prev := bindSetTitle
	bindSetTitle = func(int, string) int64 { return 0 }
	t.Cleanup(func() { bindSetTitle = prev })
	f.replyFn = seat.reply
	return f
}

// The request packs op, target id and arg in the title and rides the
// caller's own bound window — kind 30, x/y/w/h left to the auth union.
func TestWmAgentGeometryPacking(t *testing.T) {
	seat := &agentGeomSeat{}
	startAgentGeomFake(t, seat)
	rep, ok := WmAgentGeometry(7, WmGeomOpSash, 0x1234, 30, "AGENTD.ELF")
	if !ok || rep.Applied == 0 {
		t.Fatalf("sash op refused: ok=%v applied=%d", ok, rep.Applied)
	}
	if len(seat.saw) != 2 { // bare + echo
		t.Fatalf("requests = %d want 2", len(seat.saw))
	}
	req := seat.saw[1]
	if req.Kind != WmRpcKindAgentGeom || req.ID != 7 {
		t.Fatalf("request = kind %d id %d want 30/7", req.Kind, req.ID)
	}
	if req.Title[0] != WmGeomOpSash || req.Title[1] != 0x34 ||
		req.Title[2] != 0x12 || req.Title[3] != 30 {
		t.Fatalf("geom title = %v want [op idLE arg]", req.Title[:4])
	}
}

// An applied query ack unpacks through WmGeomDecode: space, pane,
// split kind and the rect's four uint16 fields.
func TestWmAgentGeometryQueryDecode(t *testing.T) {
	seat := &agentGeomSeat{view: WmGeomView{
		Space: 1, Pane: 2, Split: 2, X: 387, Y: 0, W: 893, H: 720}}
	startAgentGeomFake(t, seat)
	rep, ok := WmAgentGeometry(7, WmGeomOpQuery, 9, 0, "AGENTD.ELF")
	if !ok {
		t.Fatal("query never answered")
	}
	v, ok := WmGeomDecode(rep)
	if !ok || v != seat.view {
		t.Fatalf("decoded = %+v ok=%v want %+v", v, ok, seat.view)
	}
	// A refused frame is not a view.
	seat2 := &agentGeomSeat{refusal: AgentGeomNoWindow}
	startAgentGeomFake(t, seat2)
	rep, ok = WmAgentGeometry(7, WmGeomOpQuery, 9, 0, "AGENTD.ELF")
	if !ok {
		t.Fatal("refusal never answered")
	}
	if _, ok = WmGeomDecode(rep); ok {
		t.Fatal("a refused ack decoded as a view")
	}
	if rep.TitleString() != AgentGeomNoWindow {
		t.Fatalf("ack title = %q want %q", rep.TitleString(), AgentGeomNoWindow)
	}
}

// Each refusal name rides the ack title verbatim.
func TestWmAgentGeometryRefusals(t *testing.T) {
	for _, name := range []string{AgentGeomDenied, AgentGeomNoWindow, AgentGeomBadOp} {
		seat := &agentGeomSeat{refusal: name}
		startAgentGeomFake(t, seat)
		rep, ok := WmAgentGeometry(7, WmGeomOpMove, 9, 1, "AGENTD.ELF")
		if !ok {
			t.Fatalf("%s: ack never arrived", name)
		}
		if rep.Applied != 0 || rep.TitleString() != name {
			t.Fatalf("ack = applied %d title %q want 0/%q",
				rep.Applied, rep.TitleString(), name)
		}
	}
}

// A seat that never answers is answered=false; a legacy seat's bare
// applied=0 carries no name — seat_unsupported territory for the caller.
func TestWmAgentGeometrySilentAndLegacy(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = wmGoSeatName
	f.extraProcs = append(f.extraProcs, namedProc(9, "AGENTD.ELF"))
	f.replyFn = func(WmRpc) []byte { return nil }
	if _, ok := WmAgentGeometry(7, WmGeomOpQuery, 9, 0, "AGENTD.ELF"); ok {
		t.Fatal("silent seat answered")
	}
	f2 := startWmMailFake(t)
	f2.extraProcs = append(f2.extraProcs, namedProc(9, "AGENTD.ELF"))
	f2.replyFn = func(req WmRpc) []byte {
		rep := WmRpc{Kind: WmRpcKindAgentGeom | WmRpcReplyFlag,
			ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo,
			Applied: 0, Pad: WmRpcPadPlain}
		return rep.Encode()
	}
	rep, ok := WmAgentGeometry(7, WmGeomOpMove, 9, 1, "AGENTD.ELF")
	if !ok || rep.Applied != 0 || rep.TitleString() != "" {
		t.Fatalf("legacy ack = ok %v applied %d title %q",
			ok, rep.Applied, rep.TitleString())
	}
}
