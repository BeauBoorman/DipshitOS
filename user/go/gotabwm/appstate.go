// GOTABWM.ELF — M125a (#2586): the per-app state protocol's seat half.
//
// The WM_RPC frame is 38 bytes inside a 64-byte mailbox slot and the blob
// bound is 64 KiB, so the blob cannot ride the wire. Both directions
// rendezvous on a staged share file — vi.AppStatePath(id) — published
// crash-safe by whichever side SENDS the blob and deleted by the receiver
// (consume-on-use: a staging file is a handoff, never storage):
//
//	save_state (kind 20): the app publishes `u8 appver | u32 len | blob`
//	    at the rendezvous path, then posts the request; the seat reads,
//	    validates the framing, stores the blob on the tab's `.tabs`
//	    record, deletes the file, acks applied, and republishes the
//	    session so the app_state trailer carries it.
//	restore_state (kind 21): the app posts the request; the seat
//	    publishes the stored envelope, consumes its own copy (a blob is
//	    a one-shot handoff), and acks applied; the app reads and deletes.
//
// The seat ASKS through an asynchronous kind-20 notice — reply_to=0,
// Pad=Bound + the session token, the same shape a kind-15 settings notice
// rides — at the two lifecycle points the card pins: snapshot and tab
// close. The collect loop drains the mailbox for a bounded number of
// yield rounds so a silent app cannot wedge the seat.
//
// The seat never interprets the bytes: apps own the format, the seat owns
// the lifecycle. `appver` is the app's own tag, stored and returned
// verbatim so a stale serialization is refused by the app's check.
package main

import "virelai/vi"

// The protocol's seams — vi.WriteFileSafe/ReadFileAll/FileDelete/IpcSend
// all cross the raw syscall gateway and degrade to -ENOSYS off the guest,
// so the vars are the host-test surface (the writeHostFile / readSessionFile
// / sendSettingsNotice pattern).
var (
	stateFileRead    = vi.ReadFileAll
	stateFileWrite   = vi.WriteFileSafe
	stateFileDelete  = vi.FileDelete
	stateNoticePost  = vi.IpcSend
	// stateYield is the collect round's wait: one scheduler tick, not a
	// cooperative yield. A yield only hands the slice to a READY task on
	// the merged ring view — since #3107 floated the seat, it can land on
	// a secondary ring whose view holds no claimable task (apps asleep in
	// vi.Sleep, kernel tasks not steal-eligible), so the whole round
	// budget used to self-rotate in microseconds: the ask went out, the
	// collect drained before any app noticed, and `snapshot saved`
	// published ahead of every `state save` (observed go-wm-tabs runs
	// 16/18: trailer short or absent; WEB's idle ~10-tick poll never
	// answered inside the run). One tick per round restores the wall-
	// clock window the protocol was always asking for.
	stateYield = func() { vi.Sleep(1) }
	// stateLog is the protocol's marker sink — vi.ConsoleLine on the
	// guest, a recorder in tests (the snapLog pattern).
	stateLog = vi.ConsoleLine
)

// stateServiceDrain is the collect loop's mailbox pass — serviceRPC on the
// guest, a stub in tests. It stays nil at package init: serviceRPC's call
// chain reaches collectStateAsks (the detach arm), so an eager binding
// would be an initialization cycle; the collect loop binds the default
// lazily on first use.
var stateServiceDrain func() int

// stateAskPend marks a posted save ask by window id; serveStateSave clears
// it when the app's request lands. The collect loop's bound is a round
// count, not a timer.
var stateAskPend [256]bool

// stateAskRounds bounds the drain between the ask and giving up: each
// round is one serviceRPC pass plus one tick of real wait, so the app gets
// wall-clock time to notice the ask and answer — the notice lands in a
// mailbox nothing wakes, so the app's own poll cadence (Sleep(1) for an
// editor/terminal, up to ~10 ticks for an idle browser) is the floor the
// budget must cover. An unanswered ask is not an error — the tab keeps
// whatever state it already stored (or none) and the lifecycle point
// proceeds.
const stateAskRounds = 24

// askStateSave posts the kind-20 notice to id's bound owner and returns
// whether an ask is now outstanding. An unbound or oversized id is
// skipped silently — a window with no session token cannot authenticate
// the handoff anyway, and the collect loop never waits on an ask that was
// never posted.
func askStateSave(id uint32, why string) bool {
	if id > 255 {
		return false
	}
	b := rpcBindings[id]
	if b.token == 0 || b.pid == 0 {
		return false
	}
	var ev vi.WmRpc
	ev.Kind = vi.WmRpcKindSaveState
	ev.ID = uint8(id)
	ev.Pad = vi.WmRpcPadBound
	vi.SetWmAuth(&ev, b.token)
	if stateNoticePost(uint32(b.pid), ev.Encode()) < 0 {
		return false
	}
	stateAskPend[id] = true
	stateLog(MarkerStateAsk + vi.Itoa64(int64(id)) + " " + why)
	return true
}

// askAllStateSave posts the ask to every bound live tab (the snapshot arm)
// and returns how many notices were actually posted.
func askAllStateSave(why string) int {
	posted := 0
	for i := 0; i < tabs.count; i++ {
		if askStateSave(tabs.tabs[i].ID, why) {
			posted++
		}
	}
	return posted
}

// collectStateAsks drains the mailbox until every posted ask has been
// answered or the round budget runs out — whichever first. Each round
// services real requests (the app's kind-20 save IS a request), then
// yields a slice so the app can notice its ask. Silent apps cost the full
// budget once, never more.
func collectStateAsks() {
	for i := 0; i < stateAskRounds; i++ {
		pending := false
		for _, p := range stateAskPend {
			if p {
				pending = true
				break
			}
		}
		if !pending {
			return
		}
		drain := stateServiceDrain
		if drain == nil {
			drain = serviceRPC
		}
		drain()
		stateYield()
	}
}

// serveStateSave is the kind-20 request arm: the app says its envelope is
// staged at the rendezvous path. The seat reads it whole (bounded at the
// per-app cap plus framing), validates, and stores the blob on the tab's
// record — noteSessionMutation republishes the file so the `.tabs`
// trailer carries it. Missing, oversized, or malformed staging is refused
// BY NAME; the ack still reports applied=0.
func serveStateSave(req vi.WmRpc) bool {
	id := uint32(req.ID)
	stateAskPend[req.ID] = false
	i := tabs.index(id)
	if i < 0 {
		return false
	}
	name := tabs.tabs[i].Title
	if name == "" {
		name = tabs.tabs[i].Bin
	}
	path := vi.AppStatePath(id)
	raw, r := stateFileRead(path, stateMaxBytes+8)
	if r < 0 {
		stateLog(MarkerStateDrop + name + " missing")
		return false
	}
	_ = stateFileDelete(path)
	if len(raw) > stateMaxBytes+5 {
		stateLog(MarkerStateDrop + name + " oversize")
		return false
	}
	ver, blob, ok := vi.DecodeAppState(raw)
	if !ok {
		stateLog(MarkerStateDrop + name + " bad")
		return false
	}
	_ = tabs.SetState(id, ver, blob)
	stateLog(MarkerStateSave + vi.Itoa64(int64(id)) +
		" len=" + vi.Itoa64(int64(len(blob))) +
		" ver=" + vi.Itoa64(int64(ver)))
	// M79g discipline for the new field: a stored blob is a strip
	// mutation, so the file must say so immediately.
	noteSessionMutation()
	return true
}

// serveStateRestore is the kind-21 arm: hand the stored blob back. The
// seat publishes the envelope at the rendezvous path and the ack reports
// applied — the app's read+delete finishes the consume-on-use handoff.
// The seat's copy is consumed the moment it is staged: a re-request after
// delivery honestly finds nothing (the fresh answer is "start clean").
func serveStateRestore(req vi.WmRpc) bool {
	id := uint32(req.ID)
	i := tabs.index(id)
	if i < 0 || len(tabs.tabs[i].State) == 0 {
		return false
	}
	enc, ok := vi.EncodeAppState(tabs.tabs[i].StateVer, tabs.tabs[i].State)
	if !ok || stateFileWrite(vi.AppStatePath(id), enc) != 0 {
		return false
	}
	ver := tabs.tabs[i].StateVer
	n := len(tabs.tabs[i].State)
	tabs.tabs[i].State = nil
	tabs.tabs[i].StateVer = 0
	stateLog(MarkerStateRestore + vi.Itoa64(int64(id)) +
		" len=" + vi.Itoa64(int64(n)) +
		" ver=" + vi.Itoa64(int64(ver)))
	return true
}

// pendingAppState carries a closed tab's blob across ctrl-shift-t: keyed
// by the exec'd pid, the same pid-matched discipline as reexecWait — a
// reopened tab is a NEW row, not a placeholder, so the blob attaches at
// the declare arm rather than riding a row.
type pendingAppState struct {
	pid  uint8
	ver  uint8
	blob []byte
}

var (
	pendingAppStates [MaxTabs]pendingAppState
	pendingAppStateN int
)

// stagePendingState records the blob a reopen's exec should deliver. Dead
// slots are evicted on the way in so the bounded table cannot fill with
// pids that never declared.
func stagePendingState(pid int64, ver uint8, blob []byte) {
	if pid <= 0 || pid > 255 || len(blob) == 0 {
		return
	}
	for i := 0; i < pendingAppStateN; {
		if procsAlive(pendingAppStates[i].pid) {
			i++
			continue
		}
		pendingAppStates[i] = pendingAppStates[pendingAppStateN-1]
		pendingAppStates[pendingAppStateN-1] = pendingAppState{}
		pendingAppStateN--
	}
	if pendingAppStateN >= MaxTabs {
		return
	}
	pendingAppStates[pendingAppStateN] = pendingAppState{
		pid: uint8(pid), ver: ver, blob: blob,
	}
	pendingAppStateN++
}

// adoptPendingState attaches a staged reopen blob to the row the declaring
// pid just landed on. Called from both the declare and the attach arms —
// whichever the reopened app speaks first.
func adoptPendingState(pid uint8, id uint32) {
	for i := 0; i < pendingAppStateN; i++ {
		if pendingAppStates[i].pid != pid {
			continue
		}
		p := pendingAppStates[i]
		pendingAppStates[i] = pendingAppStates[pendingAppStateN-1]
		pendingAppStates[pendingAppStateN-1] = pendingAppState{}
		pendingAppStateN--
		_ = tabs.SetState(id, p.ver, p.blob)
		return
	}
}

// clearAppState is the per-window teardown for this protocol's slots —
// the ask latch and any staged file the rendezvous left behind. It runs
// from dropRpcBinding: the binding dying is exactly when the window's
// auth and its staging slot both expire, so a reused id can never
// inherit a dead window's ask or blob.
func clearAppState(id uint32) {
	if id > 255 {
		return
	}
	stateAskPend[id] = false
	_ = stateFileDelete(vi.AppStatePath(id))
}
