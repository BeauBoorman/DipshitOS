package vi

// M139b (#2780, ADR 0007 R2): the kind-29 client — the packed title's
// byte layout, the bound-window bind exchange, and the three ack shapes
// (applied, named refusal, silence).

import "testing"

// agentInputSeat scripts the Go seat's kind-29 answer: challenge an
// unbound request, bind the echo, and answer bound requests with the
// applied or refusal-named ack serveAgentInput sends.
type agentInputSeat struct {
	challenge uint64
	token     uint64
	refusal   string // ack title when set (applied=0)
	drop      bool   // never answer — the silent seat
	saw       []WmRpc
}

func (s *agentInputSeat) reply(req WmRpc) []byte {
	if req.Kind != WmRpcKindAgentInput {
		return nil
	}
	s.saw = append(s.saw, req)
	auth := WmAuth(req)
	if s.challenge == 0 {
		s.challenge = 0x0a9e17
	}
	// A token-authed request and the challenge echo both carry the event:
	// the echo's bound ack (the minted token in the auth union) IS the
	// event's answer — the seat consumed or refused it right there.
	if (s.token != 0 && auth == s.token) || auth == s.challenge {
		if s.token == 0 {
			s.token = 0x7ab1e5
		}
		rep := WmRpc{Kind: WmRpcKindAgentInput | WmRpcReplyFlag,
			ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo,
			Pad: WmRpcPadBound}
		SetWmAuth(&rep, s.token)
		if s.refusal != "" {
			copy(rep.Title[:], s.refusal)
		} else {
			rep.Applied = 1
		}
		return rep.Encode()
	}
	rep := WmRpc{Kind: WmRpcKindAgentInput | WmRpcReplyFlag,
		ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo,
		Pad: WmRpcPadChallenge}
	SetWmAuth(&rep, s.challenge)
	return rep.Encode()
}

func startAgentInputFake(t *testing.T, seat *agentInputSeat) *wmMailFake {
	t.Helper()
	f := startWmMailFake(t)
	f.wmName = wmGoSeatName
	prev := bindSetTitle
	bindSetTitle = func(int, string) int64 { return 0 }
	t.Cleanup(func() { bindSetTitle = prev })
	f.replyFn = seat.reply
	return f
}

// The request packs the event in the title and rides the caller's own
// bound window — kind 29, one event per frame, x/y/w/h left to the auth
// union.
func TestWmAgentInputKeyPacking(t *testing.T) {
	seat := &agentInputSeat{}
	startAgentInputFake(t, seat)
	rep, ok := WmAgentInputKey(7, uint8(ModCtrl|ModShift), 0x28, "NOTE.ELF")
	if !ok || rep.Applied == 0 {
		t.Fatalf("key event refused: ok=%v applied=%d", ok, rep.Applied)
	}
	if len(seat.saw) != 2 { // bare + echo
		t.Fatalf("requests = %d want 2", len(seat.saw))
	}
	req := seat.saw[1]
	if req.Kind != WmRpcKindAgentInput || req.ID != 7 {
		t.Fatalf("request = kind %d id %d want 29/7", req.Kind, req.ID)
	}
	if req.Title[0] != 'k' || req.Title[1] != byte(ModCtrl|ModShift) ||
		req.Title[2] != 0x28 {
		t.Fatalf("key title = %v want [k mods usage]", req.Title[:4])
	}
}

func TestWmAgentInputPtrPacking(t *testing.T) {
	seat := &agentInputSeat{}
	startAgentInputFake(t, seat)
	rep, ok := WmAgentInputPtr(4, 1, 0x1234, 0x5678, "NOTE.ELF")
	if !ok || rep.Applied == 0 {
		t.Fatalf("ptr event refused: ok=%v applied=%d", ok, rep.Applied)
	}
	req := seat.saw[len(seat.saw)-1]
	if req.Title[0] != 'p' || req.Title[1] != 1 ||
		req.Title[2] != 0x34 || req.Title[3] != 0x12 ||
		req.Title[4] != 0x78 || req.Title[5] != 0x56 {
		t.Fatalf("ptr title = %v want [p btn xLE yLE]", req.Title[:6])
	}
}

// A refused ack still answers: applied=0 and the refusal name rides the
// title — the client surfaces it verbatim.
func TestWmAgentInputRefusals(t *testing.T) {
	for _, name := range []string{AgentInputDenied, AgentInputNoFocus} {
		seat := &agentInputSeat{refusal: name}
		startAgentInputFake(t, seat)
		rep, ok := WmAgentInputKey(7, 0, 0x04, "NOTE.ELF")
		if !ok {
			t.Fatalf("%s: ack never arrived", name)
		}
		if rep.Applied != 0 || rep.TitleString() != name {
			t.Fatalf("ack = applied %d title %q want 0/%q",
				rep.Applied, rep.TitleString(), name)
		}
	}
}

// A seat that never answers is answered=false — honest silence, not a
// fabricated refusal.
func TestWmAgentInputSilent(t *testing.T) {
	seat := &agentInputSeat{}
	f := startAgentInputFake(t, seat)
	f.replyFn = func(WmRpc) []byte { return nil }
	if _, ok := WmAgentInputKey(7, 0, 0x04, "NOTE.ELF"); ok {
		t.Fatal("silent seat answered")
	}
	if f.sleepCalls == 0 {
		t.Fatal("the bounded wait never parked")
	}
}

// A legacy (Zig) seat answers the unknown kind with a bare applied=0 —
// answered, refused, no refusal name. The caller maps that to
// seat_unsupported (no kind-29 handler exists there).
func TestWmAgentInputLegacySeat(t *testing.T) {
	f := startWmMailFake(t)
	f.replyFn = func(req WmRpc) []byte {
		rep := WmRpc{Kind: WmRpcKindAgentInput | WmRpcReplyFlag,
			ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo,
			Applied: 0, Pad: WmRpcPadPlain}
		return rep.Encode()
	}
	rep, ok := WmAgentInputKey(7, 0, 0x04, "NOTE.ELF")
	if !ok || rep.Applied != 0 || rep.TitleString() != "" {
		t.Fatalf("legacy ack = ok %v applied %d title %q",
			ok, rep.Applied, rep.TitleString())
	}
}

// No seat at all: no peers resolve, nothing is sent.
func TestWmAgentInputNoSeat(t *testing.T) {
	startWmMailFake(t) // kernel register holds no seat
	if _, ok := WmAgentInputKey(7, 0, 0x04, "NOTE.ELF"); ok {
		t.Fatal("seat-less request answered")
	}
	if _, ok := WmAgentInputPtr(7, 0, 1, 1, "NOTE.ELF"); ok {
		t.Fatal("seat-less ptr answered")
	}
}
