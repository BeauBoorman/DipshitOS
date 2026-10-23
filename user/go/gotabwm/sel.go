// GOTABWM.ELF — M124e (#2584): the seat-owned primary selection.
//
// One buffer, owned by the seat: the last selection any opted-in app
// published. Apps are uid_user, so the kernel clipboard's slots 38/39
// refuse them (M97g's posture, unchanged by M124c) — this is the
// seat-mediated data path that arc reserved for:
//
//	sel_publish (27): a bound, hosted, selection=primary app stages its
//	    selection at SelPath(win) and posts the request; the seat reads,
//	    validates, stores the bytes as THE primary buffer, deletes the
//	    staging file, acks applied. Cap-less publishers are refused —
//	    the cap, not the app's own judgment, is what admits a selection.
//	sel_paste (28): two shapes on one kind (the kind-20 pattern) —
//	    - seat -> app notice: a middle-click inside the window's pane or
//	      the seat's primary-paste chord with it focused. The buffer is
//	      staged at the TARGET's SelPath first; the notice (reply_to=0,
//	      Pad=Bound + token) is only the signal. The manifest's
//	      selection=primary admits the target too — a cap-less window
//	      is never staged to and never noticed.
//	    - app -> seat request: the pull half for a keyboard-driven paste
//	      the app binds itself. The seat stages the buffer at the
//	      requester's SelPath and acks applied.
//
// The chord check the card asked for: Ctrl+Shift+V is taken twice — the
// seat's split-cycle (M79c, load-bearing in go-drag.spec) and the
// kernel's terminal-window clipboard paste (M73e, which consumes the key
// before a window-bound app can see it). The keyboard spelling is
// therefore Shift+Insert — the canonical primary-paste chord — bound at
// seat scope and delivered exactly like a middle-click on the focused
// pane.
package main

import "virelai/vi"

// The selection markers the gate greps. A marker prints only after the
// state transition it names — publish after the buffer stored, paste
// after the notice posted, pull after the staging file landed. The
// refusal marker names its reason so a cap-off leg reads `cap` rather
// than guessing at silence.
const (
	MarkerSelPub    = "gotabwm: sel pub id="
	MarkerSelPaste  = "gotabwm: sel paste id="
	MarkerSelPull   = "gotabwm: sel pull id="
	MarkerSelRefuse = "gotabwm: sel refuse "
)

// primSel is the seat-owned primary buffer — bytes only; the card's
// selection is text and the seat never inspects it. primSelSet
// distinguishes "no selection yet" from a stored empty span (a publish
// of zero bytes is refused, so a set buffer is never empty).
//
// M190a (#3236): primary publishes are excluded from the clipboard
// history BY CONSTRUCTION — this buffer never touches slots 38/39, so
// the ring's kernel-buffer observer cannot see it. The exclusion is a
// rule of where the bytes live, not a flag the publish path checks.
var (
	primSel    []byte
	primSelSet bool
)

// The protocol's seams — the appstate.go/drag.go pattern: the vi calls
// cross the raw syscall gateway (-ENOSYS off the guest), so the vars are
// the host-test surface.
var (
	selFileRead   = vi.ReadFileAll
	selFileWrite  = vi.WriteFileSafe
	selFileDelete = vi.FileDelete
	selPost       = vi.IpcSend
	selLog        = vi.ConsoleLine
)

// selCapFor resolves whether the window's app opted in: tab → its
// recorded executable → the APPS.TXT row's selection= field. An
// unmanifested bin, a non-tab window, and a row without the cap all fail
// closed — refusal by omission, never by guess.
func selCapFor(id uint32, catalog []AppEntry) bool {
	i := tabs.index(id)
	if i < 0 || id >= sessionIDBase {
		return false
	}
	bin := tabs.tabs[i].Bin
	for _, e := range catalog {
		if e.Bin == bin {
			return e.Selection == "primary"
		}
	}
	return false
}

// selCatalog decodes APPS.TXT — the selection= authority both directions
// route against, read through the same seam the launcher and the drag
// admission use. A share the seat cannot read is an empty catalog: every
// direction then refuses by cap rather than guessing.
func selCatalog() []AppEntry {
	body, r := readAppsFile(appsPath, appsMaxBytes)
	if r < 0 {
		return nil
	}
	return parseAppsTXT(string(body))
}

// serveSelPublish is the kind-27 arm: gateRPC already proved the sender
// owns req.ID. The cap is checked BEFORE the staging file is touched — a
// refused publish leaves the slot for the app's own cleanup (the client
// deletes on a refused ack), the same handoff discipline as serveDragBegin.
func serveSelPublish(req vi.WmRpc) bool {
	id := uint32(req.ID)
	refuse := func(why string) bool {
		selLog(MarkerSelRefuse + vi.Itoa64(int64(id)) + " pub " + why)
		return false
	}
	if tabs.index(id) < 0 || id >= sessionIDBase {
		return refuse("notab")
	}
	if !selCapFor(id, selCatalog()) {
		return refuse("cap")
	}
	path := vi.SelPath(id)
	raw, r := selFileRead(path, vi.SelMax+8)
	if r < 0 {
		return refuse("missing")
	}
	_ = selFileDelete(path)
	text, ok := vi.DecodeSel(raw)
	if !ok {
		return refuse("bad")
	}
	if len(text) == 0 {
		return refuse("empty")
	}
	primSel = append(primSel[:0], text...)
	primSelSet = true
	// An app publishing its selection is still hosted — the demo close
	// countdown restarts like every other RPC arm.
	hostTicksLeft = hostTicks
	selLog(MarkerSelPub + vi.Itoa64(int64(id)) +
		" len=" + vi.Itoa64(int64(len(text))))
	return true
}

// serveSelPaste is the kind-28 request arm: the app's own keyboard chord
// pulling the buffer. The seat stages the envelope at the requester's
// rendezvous path and acks applied; the app's read+delete finishes the
// consume-on-use handoff. The requester's cap is the gate — a cap-less
// window asks and gets nothing.
func serveSelPaste(req vi.WmRpc) bool {
	id := uint32(req.ID)
	if tabs.index(id) < 0 || id >= sessionIDBase ||
		!primSelSet || !selCapFor(id, selCatalog()) {
		return false
	}
	enc, ok := vi.EncodeSel(primSel)
	if !ok || selFileWrite(vi.SelPath(id), enc) != 0 {
		return false
	}
	selLog(MarkerSelPull + vi.Itoa64(int64(id)) +
		" len=" + vi.Itoa64(int64(len(primSel))))
	return true
}

// selDeliver is the seat-initiated half of kind 28 — one delivery for a
// middle-click inside the window's pane or the primary-paste chord with
// it focused. The buffer is staged at the target's rendezvous path BEFORE
// the notice posts (dragDeliver's order): a notice that could not post
// takes the staged bytes back, so a delivery is never claimed without
// its payload.
func selDeliver(id uint32) bool {
	if id > 255 || tabs.index(id) < 0 || id >= sessionIDBase {
		return false
	}
	if !primSelSet || len(primSel) == 0 {
		selLog(MarkerSelRefuse + vi.Itoa64(int64(id)) + " paste empty")
		return false
	}
	if !selCapFor(id, selCatalog()) {
		selLog(MarkerSelRefuse + vi.Itoa64(int64(id)) + " paste cap")
		return false
	}
	b := rpcBindings[id]
	if b.token == 0 || b.pid == 0 {
		selLog(MarkerSelRefuse + vi.Itoa64(int64(id)) + " paste unbound")
		return false
	}
	enc, ok := vi.EncodeSel(primSel)
	if !ok {
		return false
	}
	path := vi.SelPath(id)
	if selFileWrite(path, enc) != 0 {
		selLog(MarkerSelRefuse + vi.Itoa64(int64(id)) + " paste stage")
		return false
	}
	var ev vi.WmRpc
	ev.Kind = vi.WmRpcKindSelPaste
	ev.ID = uint8(id)
	ev.Pad = vi.WmRpcPadBound
	vi.SetWmAuth(&ev, b.token)
	if selPost(uint32(b.pid), ev.Encode()) < 0 {
		_ = selFileDelete(path)
		selLog(MarkerSelRefuse + vi.Itoa64(int64(id)) + " paste post")
		return false
	}
	selLog(MarkerSelPaste + vi.Itoa64(int64(id)) +
		" len=" + vi.Itoa64(int64(len(primSel))))
	return true
}

// applySelPasteAt is the middle-click half: the pointer's down edge lands
// on content (the caller already ruled out chrome), so the drag hit-test
// resolves which hosted pane holds it and that window's cap admits or
// refuses the paste.
func applySelPasteAt(px, py uint32) {
	tgt, hit := dragTargetAt(px, py)
	if !hit {
		selLog(MarkerSelRefuse + "none paste notab")
		return
	}
	_ = selDeliver(tgt)
}

// applySelPasteChord is the keyboard half: Shift+Insert delivers to the
// focused tab. An empty strip is an honest no-op — no marker, same as
// the other focused-tab actions.
func applySelPasteChord() {
	id, ok := tabs.Focused()
	if !ok {
		return
	}
	_ = selDeliver(id)
}

// dropSelWindow is the protocol's half of window teardown, running from
// dropRpcBinding: a staged handoff dies with the window it was staged
// for, so a reused id can never inherit a dead window's paste. The seat
// buffer itself survives the publisher's death — the selection outlives
// its source, exactly as a seat-owned PRIMARY does.
func dropSelWindow(id uint32) {
	if id > 255 {
		return
	}
	_ = selFileDelete(vi.SelPath(id))
}
