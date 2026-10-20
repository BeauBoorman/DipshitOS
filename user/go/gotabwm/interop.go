// GOTABWM.ELF - M57c (issue #1318): the Go seat hosts UNMODIFIED Zig apps.
//
// This is the card that makes the seat real. The client under test is the Go
// editor NOTE.ELF (it replaced the Zig notepad, which #1485 deleted): it rides
// user/go/tabapp, opens its own window, then declares itself to the running WM
// over the WM_RPC mailbox and waits for the ack. It discovers the WM
// purely by process name (abi.zig wm_proc_names), which M57c extended with
// GOTABWM.ELF - the same additive step M42 SX3 took for TABWM.BIN. No app
// source change, no port: the same binaries that run under TABWM run here.
//
// The seat is the SERVER half. It drains its own mailbox, applies each request
// with the kernel's own primitives, and acks to the requester. The markers are:
//
//	declare_fullscreen (8)      gotabwm: tab open id=<n>
//	                            gotabwm: host focus / tab focus id=<n>
//	                            gotabwm: host view id=<n>
//	                            gotabwm: rpc declare id=<n>
//	raise (1)                   gotabwm: rpc raise / tab focus id=<n>
//	attach (5)                  gotabwm: tab open (if new); rpc attach id=<n>
//	detach (6)                  gotabwm: rpc detach id=<n>
//	cycle (7)                   gotabwm: tab focus id=<n>; rpc cycle
//	set title (11)              gotabwm: title id=<n> <text>
//	notify (12)                 gotabwm: notify id=<n> <text>
//	                            gotabwm: notify dismiss id=<n> (on expiry or click)
//	anything else               gotabwm: rpc other kind=<n>
//	rail after paint            gotabwm: rail n=<n> focus=<id>
//	close focused / last        gotabwm: host close / tab close id=<n>
//	                            then tab focus remaining, or tabs empty
//	loop ends                   gotabwm: host done
//
// The ack is the M56b wire (wmclient.go / wnd_core.zig): kind | 0x80, id, seq,
// applied. The hosted Go calc's "gocalc: declare accepted" proves the ack
// carried applied=1; "gocalc: present" / "notepad: resize relayout"
// proves the full-viewport proposal reached it; "gocalc: close" proves the
// close did.
package main

import (
	"virelai/vi"
)

// The interop markers the class-B gate greps. Exported so interop_test.go can
// pin the exact shapes (a drift is a host-test failure, not a silent live miss).
const (
	MarkerRpcDeclare = "gotabwm: rpc declare id="
	MarkerRpcRaise   = "gotabwm: rpc raise id="
	MarkerRpcAttach  = "gotabwm: rpc attach id="
	MarkerRpcDetach  = "gotabwm: rpc detach id="
	MarkerRpcCycle   = "gotabwm: rpc cycle"
	MarkerTitle      = "gotabwm: title id="
	MarkerRpcOther   = "gotabwm: rpc other kind="
	MarkerRpcBind    = "gotabwm: rpc bind id="
	MarkerRpcRefuse  = "gotabwm: rpc refuse id="
	MarkerHostFocus  = "gotabwm: host focus id="
	MarkerHostView   = "gotabwm: host view id="
	MarkerHostClose  = "gotabwm: host close id="
	MarkerHostDone   = "gotabwm: host done"
)

// M97g-F2 (#2080): WM_RPC sender authentication. The mailbox is any-to-any
// and carries no sender identity (ADR 0007 slots 5/6), so the frame alone
// can never prove who sent it. The seat binds each window to a session
// token only the window's kernel-registered owner can obtain:
//
//  1. a request for an UNBOUND window draws a challenge ack — Pad=Challenge
//     with an 8-byte value in the frame's x/y/w/h union;
//  2. the owner proves itself by setting the window's kernel title to the
//     challenge string — slot 61 (sys_win_set_title) refuses non-owners —
//     and resends the request with the challenge echoed in the union;
//  3. the seat reads the title back (wmctl cmd 14), mints the session
//     token, and binds the window to the request's reply_to pid + token;
//  4. every later frame for the window must carry the token and the bound
//     reply_to; every bound-window ack carries Pad=Bound + the token, so a
//     forged ack cannot satisfy the client's wait.
//
// The 38-byte wire is unchanged: x/y/w/h are zero in every request kind the
// client sends, so the auth value rides existing fields.

// rpcBinding is one bound session: the window id indexes the table, the pid
// is the reply_to that proved ownership, the token is the shared secret.
type rpcBinding struct {
	pid   uint8
	token uint64
}

// rpcBindings is the bound-session table, indexed directly by window id:
// rpcBindings[id].token == 0 means "no binding". rpcChallenges holds the
// pending ownership challenge per window id (0 = none outstanding).
var (
	rpcBindings   [256]rpcBinding
	rpcChallenges [256]uint64
)

// readWindowName / mintAuthValue are the kernel seams the bind proof needs
// — wmctl cmd 14 (the seat's window-name read-back) and slot 72 (the
// CSPRNG). Wrapped so host tests can drive the handshake off-guest.
var (
	readWindowName = func(id uint8) (string, bool) {
		var buf [64]byte
		n, r := vi.WmctlWindowName(uint32(id), buf[:])
		if r < 0 || n <= 0 {
			return "", false
		}
		return string(buf[:n]), true
	}
	mintAuthValue = func() uint64 {
		var b [8]byte
		if n, err := vi.Random(b[:]); err != nil || n != len(b) {
			return 0
		}
		return uint64(b[0]) | uint64(b[1])<<8 | uint64(b[2])<<16 | uint64(b[3])<<24 |
			uint64(b[4])<<32 | uint64(b[5])<<40 | uint64(b[6])<<48 | uint64(b[7])<<56
	}
)

// challengeFor returns the outstanding ownership challenge for id, minting
// a fresh nonzero one when none is pending. The challenge is not secret —
// the proof is the owner-restricted title set, not knowledge of the value.
func challengeFor(id uint8) uint64 {
	if rpcChallenges[id] != 0 {
		return rpcChallenges[id]
	}
	if v := mintAuthValue(); v != 0 {
		rpcChallenges[id] = v
		return v
	}
	return 0
}

// completeBind finishes the ownership handshake: the echoed challenge must
// match the pending one and the window's kernel title must read as the
// challenge string — a state only the kernel-registered owner can produce.
// On success the window binds to the request's reply_to pid under a fresh
// session token.
func completeBind(req vi.WmRpc) bool {
	pending := rpcChallenges[req.ID]
	if pending == 0 || vi.WmAuth(req) != pending || req.ReplyTo == 0 {
		return false
	}
	name, ok := readWindowName(req.ID)
	if !ok || name != vi.WmBindChallengeTitle(pending) {
		return false
	}
	token := mintAuthValue()
	if token == 0 || token == pending {
		return false
	}
	rpcBindings[req.ID] = rpcBinding{pid: req.ReplyTo, token: token}
	rpcChallenges[req.ID] = 0
	vi.ConsoleLine(MarkerRpcBind + vi.Itoa64(int64(req.ID)) + " pid=" + vi.Itoa64(int64(req.ReplyTo)))
	return true
}

// dropRpcBinding forgets the session token and any pending challenge for a
// window. Called wherever a window leaves the registry (tab close and the
// released-window mirror): an id reused by a later window must bind fresh,
// and a stale token must die with the window it authenticated.
func dropRpcBinding(id uint32) {
	if id > 255 {
		return
	}
	rpcBindings[id] = rpcBinding{}
	rpcChallenges[id] = 0
	// M102e (#2169): the window's GPU3D context dies with the session that
	// opened it — same rule as the token. The kernel revokes it too (its
	// own window-release path is the final authority); this is the seat's
	// bookkeeping of the same fact.
	gpu3dDropWindow(id)
	// A shared-surface handoff dies the same way: the kernel revokes the
	// peer mirror at owner teardown, so a reused id must never blit a dead
	// window's pages (#2236 defect #13).
	surfaceDropWindow(id)
	// M125a (#2586): the ask latch and any staged rendezvous file die
	// with the session too.
	clearAppState(id)
	// M124a (#2580): an armed drag dies with its source, and a staged
	// handoff dies with its target — a reused id inherits neither.
	dropDragWindow(id)
	// M124e (#2584): a staged selection handoff dies the same way. The
	// seat's primary BUFFER survives — it outlives its publisher.
	dropSelWindow(id)
}

func dropAllRpcBindings() {
	rpcBindings = [256]rpcBinding{}
	rpcChallenges = [256]uint64{}
	surfaceRecs = [surfaceMaxRecs]surfaceRec{}
	surfaceXY = [256]uint32{}
}

// serviceRPCBuf is the mailbox drain's receive buffer. Package-level, not a
// stack local: the host-test syscall seam hands &buf[0] to the fake kernel as
// a uintptr, and a goroutine stack move mid-hook would leave the write in a
// stale segment — the buffer must not live on a movable stack.
var serviceRPCBuf [vi.WmRpcMax]byte

// gateRPC is the sender-authentication check ahead of applyRPC. It returns
// the Pad and auth union the ack must carry plus whether the request may
// apply. A frame that fails authentication never reaches the WM state, and
// a bound window answers bad credentials with a bare refusal — the token
// never rides a frame that failed the check.
func gateRPC(req vi.WmRpc) (pad uint8, auth uint64, apply bool) {
	b := rpcBindings[req.ID]
	if b.token != 0 {
		if req.ReplyTo == b.pid && vi.WmAuth(req) == b.token {
			return vi.WmRpcPadBound, b.token, true
		}
		// #2260 heal: a bound id presenting NO credentials is a client
		// that lost its session token (ack timeout / full-mailbox send
		// refusal under load) while the seat still holds its half of the
		// binding. Bare-refusing wedges that client forever — it can only
		// send unauthed frames and each is refused — so offer a fresh
		// challenge instead. The echo still has to produce the
		// owner-restricted title proof, the same bar as the first bind.
		if vi.WmAuth(req) == 0 {
			return vi.WmRpcPadChallenge, challengeFor(req.ID), false
		}
		// A bound id quoting the pending challenge is that client's echo:
		// completeBind re-checks it against the kernel title and installs
		// a fresh token, retiring the stale binding the same way a first
		// bind does. Wrong-token frames (a forged credential guess) still
		// fall through to the bare refusal.
		if completeBind(req) {
			return vi.WmRpcPadBound, rpcBindings[req.ID].token, true
		}
		return vi.WmRpcPadPlain, 0, false
	}
	if vi.WmAuth(req) == 0 {
		return vi.WmRpcPadChallenge, challengeFor(req.ID), false
	}
	if completeBind(req) {
		return vi.WmRpcPadBound, rpcBindings[req.ID].token, true
	}
	return vi.WmRpcPadChallenge, challengeFor(req.ID), false
}

// M79e (#1708): the pending navigation target. ONE slot, keyed by the window
// id it belongs to and drained poll-once — Zig tabwm's pending_nav_id /
// pending_nav_path, same bound. A second step before the first is polled
// overwrites the first: the seat queues what the user most recently asked
// for, not a backlog.
var (
	pendingNavID   uint32
	pendingNavPath string
)

// rpcReplyPayload is the nav-poll channel's answer: the ack's `title` field
// carries the target path the app must navigate to, which is exactly how
// TABWM does it (Zig's rpc_reply_payload, consumed by the reply). Kept
// separate from pendingNav* because they have different lifetimes — this
// one lives for exactly one reply, that one until the app polls.
var rpcReplyPayload string

// setPendingNav queues a step target for one app.
func setPendingNav(id uint32, path string) {
	pendingNavID = id
	pendingNavPath = path
}

// navPoll drains the queued target for id, clearing the slot. A slot queued
// for a different window is NOT stolen — the poll is refused and the target
// stays for its own app.
func navPoll(id uint32) (string, bool) {
	if id == 0 || pendingNavID != id || pendingNavPath == "" {
		return "", false
	}
	p := pendingNavPath
	pendingNavID = 0
	pendingNavPath = ""
	return p, true
}

// clearPendingNav drops any target queued for id. Called from the one place
// a tab leaves the strip: Zig lets the slot outlive its tab, which means a
// LATER window that reuses the same id can poll and receive a dead tab's
// navigation. One line at the choke point is cheaper than that bug.
func clearPendingNav(id uint32) {
	if pendingNavID == id {
		pendingNavID = 0
		pendingNavPath = ""
	}
}

// takeReplyPayload consumes the pending ack payload. Consume-on-use (not a
// read) so a payload can never leak into the NEXT request's reply.
func takeReplyPayload() string {
	p := rpcReplyPayload
	rpcReplyPayload = ""
	return p
}

// tabs is the in-process strip (M62b). hostedApp is the focused client's
// window id (0 = none) kept in sync so the M57c paint-suppression check
// and go-wm-seat close path keep working with one hosted app.
var (
	tabs      TabStrip
	hostedApp uint32
	// dogfoodHosted (M69a, issue #1528) latches at the first tab this boot
	// put on the strip -- the declare and attach paths both set it. It is the
	// honesty gate for `dogfood: ok`: the seat closes its tabs before
	// host-done, so the strip is empty again by then and the latch is the only
	// record that this boot hosted anything at all.
	dogfoodHosted bool
)

// hostTicks is how long the seat hosts a SINGLE app before closing it —
// enough composite ticks for the app to declare, take the viewport and relayout,
// plus one `--pointer-virtio` click (pointerClickHold). Two tabs skip this
// countdown and use the strip choreography in seat.go.
// M79a (#1704): both the countdown and the choreography are DEMO mode only
// (the seeded /host/GOTABWM.DEMO trigger); live mode never auto-closes.
// M62g: GOEDIT starts slower than the other clients (the Zig CALC/NOTEPAD pair
// when this was written; both are Go apps now — GOCALC.ELF/NOTE.ELF), so the
// second declare needs more than three ticks or the first tab is closed.
const hostTicks = 16

// hostTicksLeft counts down while exactly one tab is open; the composite
// loop closes that tab when it reaches zero (go-wm-seat / go-wm-default).
var hostTicksLeft int

// Two-tab close choreography (M62b): wait until the rail has been painted
// with n>=2, close the focused tab, then close the last. The seat stays
// registered after the strip is empty.
var (
	stripSawTwo    bool
	stripClosedOne bool
	stripDone      bool
	stripStep      int // two-tab: rail → reorder → pin → V → unsplit → H → unsplit → close pinned → close last
	stripHoldLeft  int // M63b: ticks left before stripStep advances
)

// serviceRPC drains the seat's mailbox and services every queued WM_RPC
// request. It is called from the composite loop, so the seat answers while it
// holds the scanout cadence. Bounded per call so a flood cannot starve the tick
// loop. Returns how many requests were served.
func serviceRPC() int {
	buf := serviceRPCBuf[:]
	served := 0
	// M119c (#2487): the kernel's ring grew 8 → 32 so a stalled seat
	// stops refusing posts; the per-pass bound stays the client-side
	// constant — a deeper backlog clears over multiple iterations,
	// not one pass.
	for i := 0; i < vi.MailboxMaxMessages; i++ {
		n, r := vi.IpcRecv(buf[:])
		if r < 0 || n < 38 {
			return served
		}
		req, ok := vi.DecodeWmRpc(buf[:n])
		if !ok {
			continue
		}
		// An ack is never a request (the M56b reply flag).
		if req.Kind&vi.WmRpcReplyFlag != 0 {
			continue
		}
		pad, auth, apply := gateRPC(req)
		if apply {
			// Kind 16 (WINDOWS_QUERY, ADR 0044 D5) sends its own page
			// of row frames, each carrying Pad=Bound + the token — it
			// binds like every other request, then bypasses replyRPC.
			if req.Kind == wmKindWindowsQuery {
				serveWindowsQuery(req, auth)
				served++
				continue
			}
			// Kind 17 (GPU3D, M102e) binds like every other request —
			// no exemption: unbound windows draw the challenge and
			// bad credentials draw the bare refusal below, so a forged
			// frame never reaches the broker. serveGpu3d answers with
			// the frozen status/staged/frame payload itself.
			if req.Kind == vi.WmRpcKindGpu3d {
				serveGpu3d(req, auth)
				served++
				continue
			}
			// Kind 29 (agent_input, ADR 0007 R2, M137a) binds like every
			// other request too — the bound window's ownership proof IS
			// the grant half of the admission check — then the AGENTD
			// principal check runs inside serveAgentInput. It answers
			// its own ack so the refusal name rides the title even on
			// applied=0.
			if req.Kind == wmKindAgentInput {
				serveAgentInput(req, auth)
				served++
				continue
			}
		}
		applied := false
		if apply {
			applied = applyRPC(req)
			if !applied {
				// The gate passed but the seat refused the request;
				// `declare refused` client-side is otherwise silent
				// about which step failed (#2652: live-rfb run 01).
				vi.ConsoleLine(MarkerRpcRefuse + vi.Itoa64(int64(req.ID)) +
					" apply kind=" + vi.Itoa64(int64(req.Kind&0x7f)))
			}
		} else if pad == vi.WmRpcPadPlain {
			// #2260: name why the bound id refused — which pid asked,
			// which kind, and whether any credentials rode the frame.
			// Never print the auth value itself (it is the session
			// credential); the 0/1 flag is enough to split "sender had
			// no token" from "sender held a stale token".
			authed := int64(0)
			if vi.WmAuth(req) != 0 {
				authed = 1
			}
			vi.ConsoleLine(MarkerRpcRefuse + vi.Itoa64(int64(req.ID)) +
				" pid=" + vi.Itoa64(int64(req.ReplyTo)) +
				" kind=" + vi.Itoa64(int64(req.Kind&0x7f)) +
				" authed=" + vi.Itoa64(authed))
		}
		replyRPC(req, applied, pad, auth)
		served++
	}
	return served
}

var configureHostedChrome = setHostedWindowChrome

// applyRPC performs one WM_RPC request with the kernel's own primitives and
// returns whether it was applied. Only the paths a tab-aware Zig app exercises
// are implemented; everything else is refused (applied=0) rather than faked.
func applyRPC(req vi.WmRpc) bool {
	id := uint32(req.ID)
	switch req.Kind & 0x7f {
	case vi.WmRpcKindDeclareFullscreen: // 8, the path lib/tabapp.zig uses
		// Publish no hosted tab until its explicit no-chrome decision is in
		// the kernel. This also precedes the resize and the next seat present.
		if !configureHostedChrome(id) {
			return false
		}
		// M120b (#2559): a declare from a pending re-exec pid ADOPTS the
		// placeholder row it was exec'd for — position, title, pin, frozen
		// and the recorded focus all ride the row, so the declare must not
		// steal focus the way a fresh tab's does. The settle pass lands the
		// recorded focus once the pending set drains.
		adopted := adoptReexec(req.ReplyTo, id) >= 0
		if adopted {
			dogfoodHosted = true
			vi.ConsoleLine(MarkerTabOpen + vi.Itoa64(int64(id)))
		} else if tabs.OpenTab(id, req.TitleString()) {
			noteStripOpen()
			dogfoodHosted = true
			vi.ConsoleLine(MarkerTabOpen + vi.Itoa64(int64(id)))
		}
		// M125a (#2586): a reopen's exec carries the closed tab's blob —
		// attach it to the row its pid just landed on (harmless no-op for
		// every other declare; a restored row's blob already rides it).
		adoptPendingState(req.ReplyTo, id)
		hostTicksLeft = hostTicks
		if !adopted {
			hostedApp = id
			// Focus and raise through the kernel's taskbar-click primitive, so the
			// app receives the real WIN_FOCUS. New declares take focus so two
			// clients leave exactly one focused tab (M62b).
			if vi.WmctlTaskbarClick(id) == 0 {
				_ = tabs.FocusTab(id)
				vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(id)))
				vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(id)))
			}
		}
		// Propose the full viewport. The kernel clamps (WM proposes, kernel
		// clamps) and pushes WIN_RESIZE to the app, which relayouts.
		if vi.WmctlSetWindowRect(id, 0, 0, uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight)) == 0 {
			vi.ConsoleLine(MarkerHostView + vi.Itoa64(int64(id)))
		}
		vi.ConsoleLine(MarkerRpcDeclare + vi.Itoa64(int64(id)))
		// M79g (#1718): an app that joined the strip is part of the
		// session. This is the arm a launcher exec reaches (Ctrl+Space ->
		// execSelected has no marker-gated write site of its own), so the
		// RPC — not the launcher — owns the write.
		noteSessionMutation()
		if adopted {
			maybeFinishReexec()
		}
		return true
	case vi.WmRpcKindRaise: // 1
		if vi.WmctlTaskbarClick(id) == 0 {
			_ = tabs.FocusTab(id)
			vi.ConsoleLine(MarkerRpcRaise + vi.Itoa64(int64(id)))
			vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(id)))
			return true
		}
		return false
	case vi.WmRpcKindAttachTab: // 5
		if !configureHostedChrome(id) {
			return false
		}
		// M120b (#2559): the same re-exec adoption as the declare arm — an
		// attached window from a pending pid re-inhabits its row rather
		// than appending and stealing the recorded focus.
		adopted := adoptReexec(req.ReplyTo, id) >= 0
		adoptPendingState(req.ReplyTo, id)
		if adopted {
			dogfoodHosted = true
			vi.ConsoleLine(MarkerTabOpen + vi.Itoa64(int64(id)))
			noteSessionMutation()
		} else if tabs.OpenTab(id, req.TitleString()) {
			noteStripOpen()
			dogfoodHosted = true
			vi.ConsoleLine(MarkerTabOpen + vi.Itoa64(int64(id)))
			noteSessionMutation() // M79g (#1718): a new tab persists
		}
		// Same host-state sync as declare: an attach-without-declare client
		// still lands on the strip with focus and the single-tab close
		// budget. An adopted row keeps the recorded focus instead.
		if !adopted {
			_ = tabs.FocusTab(id)
			hostedApp = id
		}
		hostTicksLeft = hostTicks
		vi.ConsoleLine(MarkerRpcAttach + vi.Itoa64(int64(id)))
		if adopted {
			maybeFinishReexec()
		}
		return true
	case vi.WmRpcKindDetachTab: // 6
		// M125a (#2586): a detach is the app's own close — it gets the
		// same bounded save ask first so its blob reaches the reopen LIFO.
		askStateSave(id, "detach")
		collectStateAsks()
		// M137c: the detaching window may belong to a dormant space.
		closed := closeTabAcrossSpaces(id)
		syncHostedFromStrip()
		vi.ConsoleLine(MarkerRpcDetach + vi.Itoa64(int64(id)))
		if closed {
			// M79g (#1718): the tab really left the strip, so the file
			// must say so. An unknown id changed nothing and is not a
			// write.
			noteSessionMutation()
		}
		return true
	case vi.WmRpcKindCycleTab: // 7
		if nid, ok := tabs.NextID(); ok {
			if vi.WmctlTaskbarClick(nid) == 0 {
				_ = tabs.FocusTab(nid)
				vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(nid)))
			}
		}
		vi.ConsoleLine(MarkerRpcCycle)
		return true
	case wmKindPalette: // 19, client -> seat: summon the command palette
		// M121a (#2564): the palette is seat-owned; a bound client asks
		// for it over the same authenticated seam the declare rides. The
		// request's payload is unused — the palette indexes live state.
		openPalette()
		if launch.open && launch.palette {
			vi.ConsoleLine(MarkerRpcPalette)
			return true
		}
		return false
	case vi.WmRpcKindNavDeclare: // 9, client -> seat: the app navigated
		// The path rides the request title, exactly as TABWM reads it.
		// A re-declaration of the current entry is a no-op that still
		// ACKS applied=1 (the tab is known and the request was honoured)
		// but prints no marker — the state did not move, and a marker
		// claiming a record that was deduped would be a lie.
		known, changed := tabs.NavDeclare(id, req.TitleString())
		if !known {
			return false
		}
		// An app still declaring navigation is still being hosted: reset
		// the demo close countdown the same way a declare/attach does,
		// or the close lands in the middle of a nav round trip (observed
		// go-wm-tabs run 08: chord at arm+12, close at arm+16 raced the
		// client's poll for the queued target).
		hostTicksLeft = hostTicks
		if !changed {
			return true
		}
		vi.ConsoleLine(MarkerNavDeclare + vi.Itoa64(int64(id)) + " path=" + req.TitleString())
		return true
	case vi.WmRpcKindNavPoll: // 10, client -> seat: give me my back/forward
		path, ok := navPoll(id)
		if !ok {
			// Nothing queued: applied=0, and NO marker. The client reads
			// the empty ack as "no target", which is the honest answer.
			return false
		}
		rpcReplyPayload = path
		vi.ConsoleLine(MarkerNavPoll + vi.Itoa64(int64(id)) + " path=" + path)
		return true
	case vi.WmRpcKindSetTitle: // 11, client -> seat
		title := req.TitleString()
		if !tabs.SetTitle(id, title) {
			return false
		}
		// The strip is the rail's render model; the next composite tick paints
		// the new label. The marker follows the successful state mutation.
		vi.ConsoleLine(MarkerTitle + vi.Itoa64(int64(id)) + " " + title)
		// M79g (#1718): a title the app set is the title the session
		// restores. Bin is untouched — SetTitle never re-guesses it, so
		// reopen identity survives a rename.
		noteSessionMutation()
		return true
	case vi.WmRpcKindNotify: // 12, client -> seat: say something to the user
		// M79k (#1720). The request id is the SENDER, so the toast's
		// click-through has a tab to focus without a second lookup, and
		// the title is the whole message budget (24 NUL-trimmed bytes).
		//
		// An unknown sender or an empty message is REFUSED (applied=0,
		// no marker): a toast that cannot be clicked back to anything is
		// noise, and the client learns the truth from its own ack instead
		// of the user learning it from a toast that does nothing.
		text := req.TitleString()
		if text == "" || tabs.index(id) < 0 {
			return false
		}
		text, _, dropped := notifyPush(id, text, compositeClock)
		// M82d2 (#1785): under do-not-disturb the notice is in the center's
		// history and nothing else — no toast was queued, so there is no
		// drop to report and no `notify id=` to claim. The ack is applied
		// all the same: an app must not learn the user is away.
		if notifyDND {
			vi.ConsoleLine(MarkerNotifyHeld + vi.Itoa64(int64(id)) + " " + text)
			return true
		}
		// The drop marker comes FIRST: the older toast has already left
		// the queue, and a stream that silently lost one must say so
		// before it announces the one it kept.
		if dropped {
			vi.ConsoleLine(MarkerNotifyDrop + vi.Itoa64(int64(notifyDropped)))
		}
		// Printed after the push, so the marker can never claim a toast
		// the queue does not hold. The next composite tick paints it.
		vi.ConsoleLine(MarkerNotify + vi.Itoa64(int64(id)) + " " + text)
		return true
	case vi.WmRpcKindProgress: // 22, client -> seat: one operation's progress
		// M123c (#2577). The request title is BINARY (the kind-17/18
		// precedent): op, pct, then the NUL-trimmed label — 22 bytes is
		// the whole budget. An unknown sender or a malformed frame is
		// refused like kind 12's empty text. Reports update the center's
		// row in place and never raise a toast, so do-not-disturb does
		// not gate them — suppression is for transients, and an
		// operation's standing row is not one.
		op, pct, label, ok := vi.DecodeProgressTitle(req.Title)
		if !ok || tabs.index(id) < 0 {
			return false
		}
		created, done := notifyProgressUpdate(id, req.ReplyTo, op, pct, label)
		if created {
			vi.ConsoleLine(MarkerNotifyProgress + vi.Itoa64(int64(id)) +
				" op=" + vi.Itoa64(int64(op)) + " " + label)
		}
		if done {
			vi.ConsoleLine(MarkerNotifyProgressDone + vi.Itoa64(int64(id)) +
				" op=" + vi.Itoa64(int64(op)))
		}
		return true
	case vi.WmRpcKindShareSurface: // 18, client -> seat: hand off its bound surface
		return serveSurfaceShare(req)
	case vi.WmRpcKindSaveState: // 20, client -> seat: collect its staged blob
		return serveStateSave(req)
	case vi.WmRpcKindRestoreState: // 21, client -> seat: hand the blob back
		return serveStateRestore(req)
	case vi.WmRpcKindDragBegin: // 24, client -> seat: arm a drag (M124a)
		return serveDragBegin(req)
	case vi.WmRpcKindDragCancel: // 26, client -> seat: abort its own drag
		return serveDragCancel(req)
	case vi.WmRpcKindSelPublish: // 27, client -> seat: store its selection (M124e)
		return serveSelPublish(req)
	case vi.WmRpcKindSelPaste: // 28, client -> seat: pull the primary buffer
		return serveSelPaste(req)
	case vi.WmRpcKindSettingsSubscribe: // 13, client -> seat: subscribe to one key
		return applySettingsSubscribe(req)
	case vi.WmRpcKindSettingsPublish: // 14, writer -> seat: a persisted key changed
		return applySettingsPublish(req)
	default:
		vi.ConsoleLine(MarkerRpcOther + vi.Itoa64(int64(req.Kind&0x7f)))
		return false
	}
}

// replyRPC acks one request to its requester. The frame mirrors the request's
// id/seq and carries the applied flag plus the reply bit, exactly like TABWM's
// wnd_mail_reply, so an unmodified app accepts it. The Pad/auth arguments are
// gateRPC's verdict: a bound window's acks always carry Pad=Bound + the
// session token, so a forged ack cannot satisfy the client's wait.
func replyRPC(req vi.WmRpc, applied bool, pad uint8, auth uint64) {
	// M79e (#1708): the title carries the nav-poll payload, the same
	// channel TABWM uses (Zig's rpc_reply_payload). takeReplyPayload is
	// consume-on-use, so only the nav-poll reply carries a path and the
	// next ack is zeroed again.
	if req.ReplyTo != 0 {
		_ = vi.IpcSend(uint32(req.ReplyTo), buildReply(req, applied, takeReplyPayload(), pad, auth).Encode())
	}
}

// buildReply is the pure half of replyRPC: the ack frame for one request. Split
// out so the host test pins the wire (reply bit, mirrored id/seq, applied flag,
// the auth Pad/union, and the nav-poll title payload) without a guest.
func buildReply(req vi.WmRpc, applied bool, payload string, pad uint8, auth uint64) vi.WmRpc {
	var rep vi.WmRpc
	rep.Kind = req.Kind | vi.WmRpcReplyFlag
	rep.ID = req.ID
	rep.Seq = req.Seq
	rep.ReplyTo = req.ReplyTo
	rep.Pad = pad
	vi.SetWmAuth(&rep, auth)
	if applied {
		rep.Applied = 1
		// Only an applied ack carries a payload: a refused poll must not
		// hand the client a path it was not given.
		if payload != "" {
			n := len(payload)
			if n > len(rep.Title) {
				n = len(rep.Title)
			}
			copy(rep.Title[:], payload[:n])
		}
	}
	return rep
}

// closeWin / focusRaise are the close path's WM-primitive seams (the execApp
// pattern in hid.go): vi.Wmctl* calls the raw syscall2 gateway and so bypasses
// vi's host-test syscall hook, which would leave the close decision
// unobservable off the guest. They are vi.WmctlWinClose / WmctlTaskbarClick
// in the guest.
var (
	closeWin   = vi.WmctlWinClose
	focusRaise = vi.WmctlTaskbarClick
)

// closeTabByID closes id's window through the WM seam; the app receives the
// real WIN_CLOSE and exits. Every close path lands here (the choreography's
// closeHosted, M79b's close-x), so `host close id=` / `tab close id=` carry
// exactly one shape. A close of the FOCUSED tab moves focus to the remaining
// tab (M62b) and says so; closing an unfocused tab (the close-x) changes no
// focus and prints no focus markers. Returns whether a close was issued.
func closeTabByID(id uint32) bool {
	if id == 0 {
		return false
	}
	fid, focused := tabs.Focused()
	wasFocused := focused && fid == id
	// M125a (#2586): the closing tab gets its one-shot save ask before the
	// window dies — the app's blob lands on its record in time for
	// CloseTab to carry it into the reopen LIFO. Bounded: a dead or
	// silent app costs stateAskRounds once.
	askStateSave(id, "close")
	collectStateAsks()
	if closeWin(id) != 0 {
		return false
	}
	vi.ConsoleLine(MarkerHostClose + vi.Itoa64(int64(id)))
	vi.ConsoleLine(MarkerTabClose + vi.Itoa64(int64(id)))
	closed := tabs.CloseTab(id)
	syncHostedFromStrip()
	if closed {
		// M79g (#1718): every close lands on this seam (choreography,
		// close-x, exit sweep), so one hook here covers them all — a
		// closed tab must not be on the next boot's strip. Closing the
		// LAST tab leaves an empty strip, which writeSession refuses:
		// the file keeps the previous contents rather than publishing an
		// empty session.
		noteSessionMutation()
	}
	if nid, ok := tabs.Focused(); ok {
		// Closing one side of a split leaves a single tab: restore
		// full-viewport (Unsplit already ran in the two-tab choreography;
		// this covers a close while still split).
		if tabs.Count() == 1 {
			_ = applyRect(nid, FullRect(uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight)))
		}
		// The focus handoff is the focused close's story (M62b): an
		// unfocused close-x leaves the keyboard where it was, so it
		// neither raises nor reports a focus change.
		if wasFocused {
			if focusRaise(nid) == 0 {
				vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(nid)))
				vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(nid)))
			}
		}
	} else {
		vi.ConsoleLine(MarkerTabsEmpty)
	}
	return true
}

// closeHosted closes the focused tab's window (the M62b choreography close
// seam). Focus moves to the remaining tab or the strip goes empty.
func closeHosted() bool {
	id, ok := tabs.Focused()
	if !ok {
		if hostedApp == 0 {
			return false
		}
		id = hostedApp
	}
	return closeTabByID(id)
}

func syncHostedFromStrip() {
	if id, ok := tabs.Focused(); ok {
		hostedApp = id
		return
	}
	hostedApp = 0
}

// noteStripOpen restarts close-handling when a tab lands on an empty strip.
// Without this, a late OpenTab after the single-tab path set stripDone would
// stay open until process exit (the gate-unreachable edge: a second declare
// more than hostTicks after the first). A second tab on an already-populated
// strip must not clear stripSawTwo — that latch is what keeps the two-tab
// close path from falling through to the single-tab countdown.
func noteStripOpen() {
	if tabs.Count() != 1 {
		return
	}
	stripDone = false
	stripSawTwo = false
	stripClosedOne = false
	stripStep = 0
	stripHoldLeft = 0
}
