// Command wmrpcprobe is the M97g-F2 (#2080) class-B fixture: an in-guest
// attacker sharing the desktop with the Go WM seat.
//
// The mailbox is any-to-any and carries no sender identity, so this app —
// after proving its OWN window can drive the authenticated handshake —
// sprays forged WM_RPC frames at every other user window id: bare frames,
// frames carrying a guessed session token, and an echo of a challenge it was
// issued but cannot prove ownership of (slot 61 sys_win_set_title is
// owner-restricted, so the title proof is unforgeable). It counts how many
// the seat APPLIES. The gate passes exactly when that count is zero and the
// honest path still works.
//
// Build:  bash tools/go/build-web.sh wmrpcprobe WMRPCPROBE
// Run:    exec WMRPCPROBE.ELF
package main

import (
	"virelai/vi"
)

const (
	selfName  = "WMRPCPROBE.ELF"
	winFirst  = 2 // kernel user_window_id_base
	winLast   = 9 // base + user_windows_max - 1
	guessTok  = uint64(0xdeadbeefcafef00d)
	recvTries = 64
)

func recvFrame(buf []byte) (vi.WmRpc, bool) {
	for i := 0; i < recvTries; i++ {
		n, r := vi.IpcRecv(buf)
		if r < 0 {
			return vi.WmRpc{}, false
		}
		if n > 0 {
			if m, ok := vi.DecodeWmRpc(buf[:n]); ok {
				return m, true
			}
			continue
		}
		vi.Sleep(1)
	}
	return vi.WmRpc{}, false
}

func main() {
	buf := make([]byte, vi.MailboxMessageMax)
	fail := func(what string) {
		vi.ConsoleLine("wmrpcprobe: FAIL " + what)
		vi.Exit(1)
	}

	peers := vi.WmPeers(selfName)
	if peers.WM == 0 || peers.Self == 0 {
		fail("no wm seat")
	}

	// --- The honest leg: own a window, bind it, drive it ----------------
	id, r := vi.WinOpen(64, 64, 320, 200)
	if r < 0 {
		fail("win open " + vi.Itoa64(r))
	}
	vi.ConsoleLine("wmrpcprobe: win id=" + vi.Itoa64(int64(id)))
	if !vi.WmMailRequest(vi.WmRpcKindDeclareFullscreen, uint32(id), 0, 0, 0, 0, "wmrpcprobe", selfName) {
		fail("declare refused")
	}
	vi.ConsoleLine("wmrpcprobe: bound id=" + vi.Itoa64(int64(id)))
	if !vi.SetTabTitle(uint32(id), "wmrpcprobe", selfName) {
		fail("bound set_title refused")
	}
	vi.ConsoleLine("wmrpcprobe: title ok")

	// --- The attack legs -------------------------------------------------
	applied, refused := 0, 0
	var challengeID int
	var challenge uint64

	// Bare + guessed-token frames at every foreign user window id. A bound
	// window answers a bare refusal; an unbound one answers a challenge the
	// attacker cannot complete — neither may apply.
	for wid := winFirst; wid <= winLast; wid++ {
		if wid == id {
			continue
		}
		for _, auth := range []uint64{0, guessTok} {
			req := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: uint8(wid),
				Seq: 1, ReplyTo: uint8(peers.Self), Pad: vi.WmRpcPadBound}
			req.SetTitle("pwned")
			vi.SetWmAuth(&req, auth)
			if vi.IpcSend(peers.WM, req.Encode()) < 0 {
				continue
			}
			rep, ok := recvFrame(buf)
			if !ok {
				continue
			}
			if rep.Applied != 0 {
				applied++
				continue
			}
			refused++
			if rep.Pad == vi.WmRpcPadChallenge && vi.WmAuth(rep) != 0 {
				challengeID, challenge = wid, vi.WmAuth(rep)
			}
		}
	}
	if applied != 0 {
		fail("foreign frames applied=" + vi.Itoa64(int64(applied)))
	}
	vi.ConsoleLine("wmrpcprobe: foreign applied=0 refused=" + vi.Itoa64(int64(refused)))

	// The unproven echo: replay a challenge the seat issued for a window the
	// attacker does not own. It cannot produce the kernel title proof, so the
	// echo must be refused — never applied, never bound.
	if challenge != 0 {
		echo := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: uint8(challengeID),
			Seq: 2, ReplyTo: uint8(peers.Self), Pad: vi.WmRpcPadBound}
		echo.SetTitle("pwned")
		vi.SetWmAuth(&echo, challenge)
		if vi.IpcSend(peers.WM, echo.Encode()) >= 0 {
			if rep, ok := recvFrame(buf); ok {
				if rep.Applied != 0 {
					fail("unproven echo applied on id=" + vi.Itoa64(int64(challengeID)))
				}
				vi.ConsoleLine("wmrpcprobe: echo refused id=" + vi.Itoa64(int64(challengeID)))
			}
		}
	}

	// A guessed-token frame at the attacker's OWN bound window: the real
	// token never left the seat's ack channel, so this must be refused.
	forged := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: uint8(id),
		Seq: 3, ReplyTo: uint8(peers.Self), Pad: vi.WmRpcPadBound}
	forged.SetTitle("pwned")
	vi.SetWmAuth(&forged, guessTok)
	if vi.IpcSend(peers.WM, forged.Encode()) >= 0 {
		if rep, ok := recvFrame(buf); ok && rep.Applied != 0 {
			fail("guessed token applied on own window")
		}
		vi.ConsoleLine("wmrpcprobe: bad-token refused")
	}

	// M137a (#2771, ADR 0007 R2): kind 29 is AGENTD-only. This sender is
	// bound and honest — the refusal must be agent_input_denied, not an
	// auth refusal: the session token is real, the principal is not.
	var agentTitle [vi.WmRpcTitleMax]byte
	agentTitle[0] = 'k' // key event, usage 0x28 (enter)
	agentTitle[2] = 0x28
	if vi.WmMailRequest(29, uint32(id), 0, 0, 0, 0,
		string(agentTitle[:]), selfName) {
		fail("agent_input applied from a non-AGENTD sender")
	}
	vi.ConsoleLine("wmrpcprobe: agent-input refused")

	// Card #2985 (ADR 0044 D5c): kind 30 is AGENTD-only the same way —
	// a bound honest sender still hears win_geometry_denied.
	var geomTitle [vi.WmRpcTitleMax]byte
	geomTitle[0] = 0 // op query
	geomTitle[1] = byte(id)
	geomTitle[2] = byte(uint16(id) >> 8)
	if vi.WmMailRequest(30, uint32(id), 0, 0, 0, 0,
		string(geomTitle[:]), selfName) {
		fail("win_geometry applied from a non-AGENTD sender")
	}
	vi.ConsoleLine("wmrpcprobe: win-geometry refused")

	vi.ConsoleLine("wmrpcprobe: auth probe ok")
	vi.Exit(0)
}
