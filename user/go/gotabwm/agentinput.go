// GOTABWM.ELF — M137a (#2771, ADR 0007 R2): WM_RPC kind 29, agent_input.
//
// AGENTD asks the seat to place ONE HID event — a key or a pointer
// sample — onto the focused pane, through the same dispatch path a real
// key takes: the synthesized vi.Event enters consumeSeatEvent, so seat
// chords, chrome hit-tests, and the kernel content-pointer forward all
// behave byte-for-byte as they do for hardware input. No new syscall:
// R1's recorded reason is that the wave's surfaces ride existing seams,
// and the seat's own input path is the seam this kind rides.
//
// The event travels in the request's title field — x/y/w/h carry the
// session-token auth union (M97g-F2), so they are not free payload
// bytes. The title packs:
//
//	t[0]  event class: 'k' = key, 'p' = pointer
//	key:     t[1] = modifier flags (ADR 0009 Mod* bits), t[2] = HID usage
//	pointer: t[1] = button bits, t[2..3] = x LE, t[4..5] = y LE
//
// Admission is the card's own bar, checked in order and each refusal
// named on both the serial marker and the ack's title (the client reads
// the refusal name from its own ack, the same channel nav-poll uses):
//
//   - gateRPC's bound-binding check already ran — the requester had to
//     prove ownership of req.ID through the challenge round (the
//     "grant" half: only the kernel-registered owner binds);
//   - the bound pid's proc-table name must read AGENTD.ELF — the sender
//     half. ReplyTo is the client's own pid in the frame, which the
//     binding ties to the proven owner;
//   - a focused pane must exist: an empty strip or a placeholder-held
//     focus is agent_input_no_focus, not a dispatch into nothing.
package main

import "virelai/vi"

// wmKindAgentInput is ADR 0007 R2's reserved WM_RPC kind (AGENTD →
// seat). Local like wmKindWindowsQuery/wmKindPalette: the vi constant
// lands with the client-side card (#2780), which this seat handler is
// the consumer half of.
const wmKindAgentInput uint8 = 29

// The wire event classes packed in the request title's byte 0.
const (
	agentEvKey byte = 'k'
	agentEvPtr byte = 'p'
)

// The markers the class-B gate greps. The refusal spellings are R2's
// own — the client must be able to read them off its ack.
const (
	MarkerAgentInput        = "gotabwm: agent-input "
	MarkerAgentInputDenied  = "gotabwm: agent_input_denied"
	MarkerAgentInputNoFocus = "gotabwm: agent_input_no_focus"
)

// agentInputReply carries the refusal name back on the ack's title so a
// refused client can tell denied from no_focus — applied=0 alone would
// collapse both into "no".
const (
	agentRefuseDenied  = "agent_input_denied"
	agentRefuseNoFocus = "agent_input_no_focus"
)

// agentProcName is the proc-table lookup seam (vi.Procs in the guest; a
// stub off-guest): name and liveness of one pid. ok=false when the pid
// is absent or dead.
// agentIpcSend is the ack-send seam (vi.IpcSend in the guest; a
// recorder off-guest, the writeHostFile pattern).
var agentIpcSend = vi.IpcSend

// forwardContentKey is the app-delivery half a real HID report's kernel
// decode performs before the kind-21 mirror ever reaches the seat: the
// focused owner's KEY_DOWN/KEY_UP pair (or the bound terminal's bytes).
// Kind-21 is a fan-out only — a seat-synthesized event has no way into
// an app's queue without this echo, which is the slot-65 cmd-23 sibling
// of hid.go's forwardContentPointer. The indirection lets host tests
// observe the forward.
var forwardContentKey = vi.WmctlContentKey

var agentProcName = func(pid uint32) (name string, ok bool) {
	var rows [64]vi.ProcRow
	n, r := vi.Procs(rows[:])
	if r < 0 {
		return "", false
	}
	for i := 0; i < n; i++ {
		if rows[i].PID == uint64(pid) {
			if rows[i].State != vi.ProcCreated && rows[i].State != vi.ProcRunning {
				return "", false
			}
			return rows[i].Name(), true
		}
	}
	return "", false
}

// agentInputEvent decodes the request title's packed event into the
// vi.Event the dispatch path consumes. False on an unknown class or a
// truncated field — the refusal lands as agent_input_denied (the
// request is not a well-formed agent_input at all).
func agentInputEvent(req vi.WmRpc) (vi.Event, bool) {
	t := req.Title
	switch t[0] {
	case agentEvKey:
		return vi.Event{
			Kind:  vi.EvWmKey,
			Flags: uint16(t[1]),
			Arg0:  uint32(t[2]),
		}, true
	case agentEvPtr:
		x := uint32(t[2]) | uint32(t[3])<<8
		y := uint32(t[4]) | uint32(t[5])<<8
		return vi.Event{
			Kind:  vi.EvWmPointer,
			Flags: uint16(t[1]),
			Arg0:  x | y<<16,
		}, true
	}
	return vi.Event{}, false
}

// serveAgentInput answers one kind-29 request. It owns its own reply
// (the serveWindowsQuery/serveGpu3d pattern): the refusal name rides
// the ack's title even when applied=0, which buildReply's payload rule
// does not do. Runs only after gateRPC bound the window, so Pad is
// always Bound and the token rides the union like every bound ack.
func serveAgentInput(req vi.WmRpc, auth uint64) {
	// The sender half: the bound pid's proc-table name must be
	// AGENTD.ELF. rpcBindings[id].pid == req.ReplyTo is gateRPC's
	// guarantee upstream; the name check is the principal's own.
	name, ok := agentProcName(uint32(req.ReplyTo))
	if !ok || name != "AGENTD.ELF" {
		vi.ConsoleLine(MarkerAgentInputDenied)
		agentInputAck(req, auth, false, agentRefuseDenied)
		return
	}
	e, ok := agentInputEvent(req)
	if !ok {
		vi.ConsoleLine(MarkerAgentInputDenied)
		agentInputAck(req, auth, false, agentRefuseDenied)
		return
	}
	// The target half: a live focused pane. A placeholder id is not a
	// live client yet (mid-restore), and an empty strip has no pane at
	// all — R2's no_focus refusal.
	fid, focused := tabs.Focused()
	if !focused || fid >= sessionIDBase {
		vi.ConsoleLine(MarkerAgentInputNoFocus)
		agentInputAck(req, auth, false, agentRefuseNoFocus)
		return
	}
	// A real report's decode pushes KEY_DOWN to the focused owner BEFORE
	// the kind-21 mirror reaches the seat, so the app half goes first:
	// an injected chord that moves focus must not re-route the press the
	// old pane already owns. Pointer samples stay on the kernel's own
	// forward inside the dispatch path (WmctlContentPtr, #1688).
	if e.Kind == vi.EvWmKey {
		forwardContentKey(uint8(e.Arg0), e.Flags)
	}
	// The event enters at the same seam a real WM_KEY/WM_POINTER takes:
	// consumeSeatEvent marks, hit-tests, dispatches chords, and forwards
	// content pointer samples through the kernel's own path.
	consumeSeatEvent(e)
	if e.Kind == vi.EvWmKey {
		vi.ConsoleLine(MarkerAgentInput + "key usage=" +
			vi.Itoa64(int64(e.Arg0)) + " id=" + vi.Itoa64(int64(fid)))
	} else {
		vi.ConsoleLine(MarkerAgentInput + "ptr id=" + vi.Itoa64(int64(fid)))
	}
	agentInputAck(req, auth, true, "")
}

// agentInputAck sends the one-frame answer: Pad/auth from gateRPC's
// verdict, applied on success, or the refusal name on the title so the
// client reads WHICH refusal landed.
func agentInputAck(req vi.WmRpc, auth uint64, applied bool, refusal string) {
	var rep vi.WmRpc
	rep.Kind = req.Kind | vi.WmRpcReplyFlag
	rep.ID = req.ID
	rep.Seq = req.Seq
	rep.ReplyTo = req.ReplyTo
	rep.Pad = vi.WmRpcPadBound
	vi.SetWmAuth(&rep, auth)
	if applied {
		rep.Applied = 1
	} else {
		copy(rep.Title[:], refusal)
	}
	if req.ReplyTo != 0 {
		_ = agentIpcSend(uint32(req.ReplyTo), rep.Encode())
	}
}
