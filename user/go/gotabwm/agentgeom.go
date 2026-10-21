// GOTABWM.ELF — card #2985 (ADR 0044 D5c): WM_RPC kind 30, win_geometry.
//
// AGENTD asks the seat where a window is, moves it to another space, or
// sets the sash of the split its pane sits in — the same arrangement a
// human reaches through the rail pills and the sash drag, through the
// same seat-checked path kind 29 established: gateRPC's bound-binding
// runs first (the grant half), then the bound pid's proc-table name must
// read AGENTD.ELF (the sender half). No new syscall: every op lands on
// the seat's own apply path — a move is applySpaceMove (the palette's
// move-to-space row), a sash set is applySashDrag (the drag's release
// edge), and a query reads the same PaneRectsAll the relayout pushes.
//
// The request's title packs the op and target — x/y/w/h carry the
// session-token auth union, and id is the caller's own bound window, so
// the window the op names travels in the title:
//
//	t[0]    op: 0 = query, 1 = move to space N, 2 = set sash percent
//	t[1..2] target kernel window id, little-endian
//	t[3]    arg: space index (move) / percent (sash); unused for query
//
// A query reply carries the answer in ITS title, same reason — the auth
// union owns x/y/w/h on bound frames:
//
//	t[0]    space index
//	t[1]    pane index in PaneRectsAll order, or 0xFF when the tab has
//	        no leaf (the headless full-viewport stack)
//	t[2]    the parent split's kind (SplitNone when unplaced)
//	t[3..10] rect x/y/w/h, uint16 little-endian each
//
// Refusals are named on both the serial marker and the ack's title, the
// R2 rule agent_input established: win_geometry_denied (the bound pid is
// not AGENTD.ELF), win_geometry_no_window (no strip row holds the id —
// and mutations ask only about the live strip), win_geometry_bad_op
// (the op is unknown, its arg is out of range, or the window's state
// gives the op nothing to act on — a sash set on an unsplit window, a
// move into the space the window already occupies).
package main

import "virelai/vi"

// wmKindAgentGeom is ADR 0044 D5c's reserved WM_RPC kind (AGENTD →
// seat). Local like wmKindAgentInput: the reservation is the kind, the
// wire is the frozen 38-byte frame.
const wmKindAgentGeom uint8 = 30

// The ops packed in request title[0].
const (
	agentGeomOpQuery byte = 0
	agentGeomOpMove  byte = 1
	agentGeomOpSash  byte = 2
)

// The marker the class-B gate greps; every request prints exactly one
// line — op and target id first, then ok or the refusal name.
const MarkerAgentGeom = "gotabwm: win_geometry "

// The refusal spellings D5c fixes: the client reads them off its own
// ack's title, same as kind 29.
const (
	agentGeomDeny     = "win_geometry_denied"
	agentGeomNoWindow = "win_geometry_no_window"
	agentGeomBadOp    = "win_geometry_bad_op"
)

// The sash op's percent bound — the card's 10–90 %. Outside it is a
// bad_op refusal, not a clamp: an agent asking for 4 % or 96 % asked
// for something the seat has no semantics for.
const (
	agentGeomPctMin byte = 10
	agentGeomPctMax byte = 90
)

// agentGeomUnplaced is the wire's pane index for a tab the tree does
// not hold — it keeps the full-viewport stack, so there is no pane
// number to report.
const agentGeomUnplaced byte = 0xFF

// serveAgentGeom answers one kind-30 request. It owns its own reply,
// the serveAgentInput pattern: the refusal name (or the query payload)
// rides the ack's title, which buildReply's payload rule does not do.
// Runs only after gateRPC bound the window, so Pad is always Bound and
// the token quotes the union like every bound ack.
func serveAgentGeom(req vi.WmRpc, auth uint64) {
	op := req.Title[0]
	id := uint32(req.Title[1]) | uint32(req.Title[2])<<8
	arg := req.Title[3]
	refuse := func(name string) {
		vi.ConsoleLine(MarkerAgentGeom + "op=" + vi.Itoa64(int64(op)) +
			" id=" + vi.Itoa64(int64(id)) + " " + name)
		agentGeomAck(req, auth, false, name)
	}
	// The sender half, kind 29's check verbatim: the bound pid's
	// proc-table name must read AGENTD.ELF. gateRPC already proved
	// reply_to is the bound owner; the name check is the principal's own.
	name, ok := agentProcName(uint32(req.ReplyTo))
	if !ok || name != "AGENTD.ELF" {
		refuse(agentGeomDeny)
		return
	}
	switch op {
	case agentGeomOpQuery:
		si, r, pane, kind, found := agentGeomLookup(id)
		if !found {
			refuse(agentGeomNoWindow)
			return
		}
		vi.ConsoleLine(MarkerAgentGeom + "op=" + vi.Itoa64(int64(op)) +
			" id=" + vi.Itoa64(int64(id)) + " ok")
		agentGeomAckQuery(req, auth, si, r, pane, kind)
	case agentGeomOpMove:
		if int(arg) >= MaxSpaces {
			refuse(agentGeomBadOp)
			return
		}
		// applySpaceMove is the seat's own move (the palette row): it
		// needs the tab on the live strip — a dormant strip's row is not
		// movable through this op, the same way the palette cannot row it.
		if tabs.index(id) < 0 {
			refuse(agentGeomNoWindow)
			return
		}
		if !applySpaceMove(id, spaces[arg].Name) {
			refuse(agentGeomBadOp)
			return
		}
		vi.ConsoleLine(MarkerAgentGeom + "op=" + vi.Itoa64(int64(op)) +
			" id=" + vi.Itoa64(int64(id)) + " ok")
		agentGeomAck(req, auth, true, "")
	case agentGeomOpSash:
		if arg < agentGeomPctMin || arg > agentGeomPctMax {
			refuse(agentGeomBadOp)
			return
		}
		// The window's split is its leaf's parent node; a live tab with
		// no leaf, or a leaf at the root, has no sash to set — bad_op,
		// while an absent id is no_window.
		if tabs.index(id) < 0 {
			refuse(agentGeomNoWindow)
			return
		}
		leaf := tabs.leafOf(id)
		if leaf < 0 {
			refuse(agentGeomBadOp)
			return
		}
		p := tabs.parentOf(leaf)
		if p < 0 {
			refuse(agentGeomBadOp)
			return
		}
		node := tabs.tree[p]
		r := tabs.nodeRect(p, uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
		var c int
		if node.kind == SplitVert {
			c = int(r.X) + int(r.W)*int(arg)/100
		} else {
			c = int(r.Y) + int(r.H)*int(arg)/100
		}
		// applySashDrag is the drag's own release edge: clamp, apply the
		// tree rects through slot 65, marker, dump, layout file, session
		// write-through — identical to a human's sash drop.
		if !applySashDrag(p, c) {
			refuse(agentGeomBadOp)
			return
		}
		vi.ConsoleLine(MarkerAgentGeom + "op=" + vi.Itoa64(int64(op)) +
			" id=" + vi.Itoa64(int64(id)) + " ok")
		agentGeomAck(req, auth, true, "")
	default:
		refuse(agentGeomBadOp)
	}
}

// agentGeomLookup resolves the query op's answer: which space's strip
// holds id (dormant spaces answer too — a moved window stays
// addressable), its applied rect (the full-viewport stack while
// unplaced or zoomed, exactly the dumpPanes rule), its pane index in
// PaneRectsAll order (agentGeomUnplaced without a leaf), and its parent
// split's kind.
func agentGeomLookup(id uint32) (si int, r Rect, pane int, kind SplitKind, found bool) {
	scanW, scanH := uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight)
	for i := 0; i < spaceN; i++ {
		s := stripOf(i)
		if s.index(id) < 0 {
			continue
		}
		rect, placed := s.rectOf(id, scanW, scanH)
		kind = SplitNone
		pane = -1
		if placed {
			kind = s.paneParentKind(id)
			for pi, pr := range s.PaneRectsAll(scanW, scanH) {
				if pr.id == id {
					pane = pi
					break
				}
			}
		}
		// M151a: a zoomed leaf's window IS the full viewport while its
		// tree pane is recorded — the same report dumpPanes gives.
		if i == spaceCur && s.zoomTab == id {
			rect = FullRect(scanW, scanH)
		}
		return i, rect, pane, kind, true
	}
	return 0, Rect{}, -1, SplitNone, false
}

// agentGeomAck sends the one-frame answer: Pad/auth from gateRPC's
// verdict, applied on success, or the refusal name on the title so the
// client reads WHICH refusal landed.
func agentGeomAck(req vi.WmRpc, auth uint64, applied bool, refusal string) {
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

// agentGeomAckQuery is the applied ack carrying the query payload in
// its title — see the file header for the byte layout.
func agentGeomAckQuery(req vi.WmRpc, auth uint64, si int, r Rect, pane int, kind SplitKind) {
	var rep vi.WmRpc
	rep.Kind = req.Kind | vi.WmRpcReplyFlag
	rep.ID = req.ID
	rep.Seq = req.Seq
	rep.ReplyTo = req.ReplyTo
	rep.Pad = vi.WmRpcPadBound
	vi.SetWmAuth(&rep, auth)
	rep.Applied = 1
	rep.Title[0] = byte(si)
	if pane < 0 {
		rep.Title[1] = agentGeomUnplaced
	} else {
		rep.Title[1] = byte(pane)
	}
	rep.Title[2] = byte(kind)
	put16 := func(i int, v uint32) {
		rep.Title[i] = byte(v)
		rep.Title[i+1] = byte(v >> 8)
	}
	put16(3, r.X)
	put16(5, r.Y)
	put16(7, r.W)
	put16(9, r.H)
	if req.ReplyTo != 0 {
		_ = agentIpcSend(uint32(req.ReplyTo), rep.Encode())
	}
}
