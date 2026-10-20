// M139b (#2780): the client half of WM_RPC kind 29, agent_input (ADR 0007
// R2 — the seat handler is M137a #2771, gotabwm/agentinput.go).
//
// AGENTD asks the seat to place ONE HID event — a key press or an
// absolute pointer sample — onto the focused pane, through the same
// consumeSeatEvent dispatch a real event takes. The event travels in the
// request's 24-byte title field because x/y/w/h are the M97g-F2 session
// token union, not free payload:
//
//	t[0]  event class: 'k' = key, 'p' = pointer
//	key:     t[1] = modifier flags (ADR 0009 Mod* bits), t[2] = HID usage
//	pointer: t[1] = button bits, t[2..3] = x LE, t[4..5] = y LE
//
// Admission is the seat's: gateRPC's bound-binding check ties the request
// to the caller's own window, and the bound pid's proc-table name must
// read AGENTD.ELF. A refused ack still answers — applied=0 with the
// refusal name on the title (agent_input_denied for a wrong principal or
// malformed event, agent_input_no_focus when no live pane holds focus),
// so the client can report WHICH refusal landed rather than a bare "no".
package vi

// WmRpcKindAgentInput is ADR 0007 R2's reserved kind: AGENTD -> seat, one
// HID event per request for the focused pane. Local here and in
// gotabwm (wmKindAgentInput) — the kind is the reservation, the wire is
// the frozen 38-byte frame.
const WmRpcKindAgentInput uint8 = 29

// The wire event classes packed in title[0] — mirror of
// gotabwm/agentinput.go's agentEvKey/agentEvPtr.
const (
	agentInputEvKey byte = 'k'
	agentInputEvPtr byte = 'p'
)

// The refusal spellings R2 fixes: the seat writes one onto a refused
// ack's title, and the daemon surfaces it verbatim as its own refusal
// code (R2's readable-refusal rule — applied=0 alone would collapse
// denied and no_focus into the same "no").
const (
	AgentInputDenied  = "agent_input_denied"
	AgentInputNoFocus = "agent_input_no_focus"
)

// WmAgentInputKey posts one kind-29 key event — HID usage plus the ADR
// 0009 modifier bits — through the caller's bound window winID and waits
// the usual bounded ack budget.
//
//   - answered=true, rep.Applied!=0: the seat dispatched the event into
//     the focused pane.
//   - answered=true, rep.Applied==0: refused — rep.TitleString() names it
//     (AgentInputDenied / AgentInputNoFocus under the Go seat; an empty
//     name is a legacy seat's bare applied=0).
//   - answered=false: no resolvable peers, a refused send, or no genuine
//     ack inside the budget — silent-seat territory.
func WmAgentInputKey(winID uint32, mods, usage uint8, selfName string) (rep WmRpc, answered bool) {
	return wmRequest(WmRpcKindAgentInput, winID, 0, 0, 0, 0,
		string([]byte{agentInputEvKey, mods, usage}), selfName)
}

// WmAgentInputPtr posts one kind-29 absolute pointer sample — x/y in
// framebuffer pixels, buttons the HID button byte (bit0 left, bit1
// right; press/release edges derive from the serialized stream). Same
// answer contract as WmAgentInputKey.
func WmAgentInputPtr(winID uint32, buttons uint8, x, y uint16, selfName string) (rep WmRpc, answered bool) {
	return wmRequest(WmRpcKindAgentInput, winID, 0, 0, 0, 0,
		string([]byte{agentInputEvPtr, buttons,
			byte(x), byte(x >> 8), byte(y), byte(y >> 8)}), selfName)
}
