// Card #2985: the client half of WM_RPC kind 30, win_geometry (ADR 0044
// D5c — the seat handler is gotabwm/agentgeom.go).
//
// AGENTD asks the seat where a window is, moves it to another space, or
// sets the sash of the split its pane sits in — the same arrangement the
// seat gives a human through the rail pills and the sash drag. The op
// and the target window id travel in the request's 24-byte title field
// because id is the caller's own bound window and x/y/w/h are the
// M97g-F2 session-token union, not free payload:
//
//	t[0]    op: 0 = query, 1 = move to space N, 2 = set sash percent
//	t[1..2] target kernel window id, little-endian
//	t[3]    arg: space index (move) / percent (sash); unused for query
//
// A refused ack still answers — applied=0 with the refusal name on the
// title (AgentGeomDenied for a wrong principal, AgentGeomNoWindow when
// no strip row holds the id, AgentGeomBadOp for a malformed op or one
// the window's state cannot take) — so the daemon surfaces WHICH refusal
// landed rather than a bare "no". An applied query ack packs its answer
// in the title too — the auth union owns x/y/w/h on bound frames —
// which WmGeomDecode unwraps.
package vi

// WmRpcKindAgentGeom is D5c's reserved kind: AGENTD -> seat, one
// geometry op per request. Local here and in gotabwm (wmKindAgentGeom)
// — the kind is the reservation, the wire is the frozen 38-byte frame.
const WmRpcKindAgentGeom uint8 = 30

// The ops packed in request title[0] — mirror of gotabwm/agentgeom.go's
// agentGeomOp* constants.
const (
	WmGeomOpQuery uint8 = 0
	WmGeomOpMove  uint8 = 1
	WmGeomOpSash  uint8 = 2
)

// The refusal spellings D5c fixes: the seat writes one onto a refused
// ack's title, and the daemon surfaces it verbatim as its own refusal
// code (the same readable-refusal rule kind 29 follows).
const (
	AgentGeomDenied   = "win_geometry_denied"
	AgentGeomNoWindow = "win_geometry_no_window"
	AgentGeomBadOp    = "win_geometry_bad_op"
)

// WmGeomUnplaced is the wire's pane index for a tab the pane tree does
// not hold — it keeps the full-viewport stack, so there is no pane
// number to report.
const WmGeomUnplaced uint8 = 0xFF

// WmGeomView is the decoded answer an applied query ack carries in its
// title: which space holds the window, its pane index in the strip's
// layout order (WmGeomUnplaced for the full-viewport stack), the parent
// split's kind (gotabwm's SplitKind byte: 0 none, 1 h, 2 v), and the
// applied rect in scanout pixels.
type WmGeomView struct {
	Space        uint8
	Pane         uint8
	Split        uint8
	X, Y, W, H   uint16
}

// WmAgentGeometry posts one kind-30 request — op plus the target window
// id and the op arg packed in the title — through the caller's bound
// window winID and waits the usual bounded ack budget.
//
//   - answered=true, rep.Applied!=0: the op landed; for WmGeomOpQuery
//     the reply title decodes through WmGeomDecode.
//   - answered=true, rep.Applied==0: refused — rep.TitleString() names
//     it (AgentGeomDenied / AgentGeomNoWindow / AgentGeomBadOp under the
//     Go seat; an empty name is a legacy seat's bare applied=0).
//   - answered=false: no resolvable peers, a refused send, or no genuine
//     ack inside the budget — silent-seat territory.
func WmAgentGeometry(winID uint32, op uint8, target uint32, arg uint8, selfName string) (rep WmRpc, answered bool) {
	return wmRequest(WmRpcKindAgentGeom, winID, 0, 0, 0, 0,
		string([]byte{op, byte(target), byte(target >> 8), arg}), selfName)
}

// WmGeomDecode unwraps the title payload an applied kind-30 query ack
// carries. False when the frame is not an applied reply — the caller
// reads the refusal name off the title instead.
func WmGeomDecode(rep WmRpc) (WmGeomView, bool) {
	if rep.Applied == 0 {
		return WmGeomView{}, false
	}
	t := rep.Title
	return WmGeomView{
		Space: t[0], Pane: t[1], Split: t[2],
		X: uint16(t[3]) | uint16(t[4])<<8,
		Y: uint16(t[5]) | uint16(t[6])<<8,
		W: uint16(t[7]) | uint16(t[8])<<8,
		H: uint16(t[9]) | uint16(t[10])<<8,
	}, true
}
