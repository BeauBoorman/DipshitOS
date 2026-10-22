package main

import (
	"testing"
	"unsafe"

	"virelai/vi"
)

// M97g-F2 (#2080): the mailbox is any-to-any and carries no sender identity
// (ADR 0007 slots 5/6), so a frame's arrival proves nothing about who sent
// it. Before the bind protocol the seat applied every well-formed frame, so
// a forged SetTitle renamed another app's tab. These tests pin the refusal:
// a request that does not carry the window's session token must never reach
// applyRPC, and the ownership handshake must bind only the process that can
// produce the kernel-visible title proof.

// serveWmRpcFrames feeds the seat's mailbox frames one per recv and captures
// every ack the seat sends back, in order.
func serveWmRpcFrames(t *testing.T, frames [][]byte) (acks [][]byte) {
	t.Helper()
	next := 0
	prev := vi.SetSyscallHookForTest(func(num, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case vi.SlotIPCRecv:
			if next >= len(frames) {
				return 0
			}
			frame := frames[next]
			next++
			dst := hookBuf(a0, a1)
			copy(dst, frame)
			return int64(len(frame))
		case vi.SlotIPCSend:
			ack := make([]byte, a2)
			copy(ack, hookBuf(a1, a2))
			acks = append(acks, ack)
			return int64(a2)
		}
		return -vi.ErrENOSYS
	})
	t.Cleanup(func() { vi.SetSyscallHookForTest(prev) })
	_ = serviceRPC()
	return acks
}

// hookBuf reads a caller pointer the syscall hook hands the seat — the
// mailbox destination/source buffers arrive as raw user addresses.
func hookBuf(addr, n uintptr) []byte {
	return unsafe.Slice((*byte)(unsafe.Pointer(addr)), int(n))
}

func serveOneWmRpc(t *testing.T, frame []byte) [][]byte {
	return serveWmRpcFrames(t, [][]byte{frame})
}

// stubAuthSeams replaces the kernel read-back and CSPRNG seams so the
// handshake runs off-guest, and resets the binding tables on cleanup.
func stubAuthSeams(t *testing.T, nameFn func(uint8) (string, bool)) {
	t.Helper()
	prevName, prevMint := readWindowName, mintAuthValue
	readWindowName = nameFn
	mintSeq := uint64(0x1000)
	mintAuthValue = func() uint64 {
		mintSeq += 0x9e3779b97f4a7c15
		return mintSeq
	}
	dropAllRpcBindings()
	t.Cleanup(func() {
		readWindowName, mintAuthValue = prevName, prevMint
		dropAllRpcBindings()
	})
}

func decodeAcks(t *testing.T, acks [][]byte) []vi.WmRpc {
	t.Helper()
	out := make([]vi.WmRpc, 0, len(acks))
	for _, raw := range acks {
		rep, ok := vi.DecodeWmRpc(raw)
		if !ok {
			t.Fatalf("seat sent an undecodable ack %x", raw)
		}
		out = append(out, rep)
	}
	return out
}

func TestServiceRPCRefusesUnauthenticatedFrame(t *testing.T) {
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}
	if !tabs.OpenTab(4, "x") {
		t.Fatal("OpenTab")
	}
	stubAuthSeams(t, func(uint8) (string, bool) { return "", false })

	// The forged frame: a SetTitle for a hosted window, reply_to pointing at
	// a pid that never opened it. Under the pre-fix seat this applied.
	req := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4, Seq: 1, ReplyTo: 3}
	req.SetTitle("pwned")
	acks := decodeAcks(t, serveOneWmRpc(t, req.Encode()))

	if tabs.At(0).Title != "x" {
		t.Fatalf("seat applied an unauthenticated frame: title = %q", tabs.At(0).Title)
	}
	if len(acks) != 1 || acks[0].Pad != vi.WmRpcPadChallenge || acks[0].Applied != 0 {
		t.Fatalf("acks = %+v want one challenge refusal", acks)
	}
	if vi.WmAuth(acks[0]) == 0 {
		t.Fatal("challenge ack carried a zero challenge")
	}
}

// The honest handshake end to end: challenge → title proof → echo → bound
// applied ack — and the session token then guards the window.
func TestServiceRPCBindHandshake(t *testing.T) {
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}
	if !tabs.OpenTab(4, "x") {
		t.Fatal("OpenTab")
	}
	ownerTitle := ""
	stubAuthSeams(t, func(id uint8) (string, bool) {
		if id != 4 || ownerTitle == "" {
			return "", false
		}
		return ownerTitle, true
	})

	// 1. An unbound frame draws the challenge.
	req := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4, Seq: 1, ReplyTo: 7}
	req.SetTitle("real")
	acks := decodeAcks(t, serveOneWmRpc(t, req.Encode()))
	if len(acks) != 1 || acks[0].Pad != vi.WmRpcPadChallenge {
		t.Fatalf("challenge step acks = %+v", acks)
	}
	challenge := vi.WmAuth(acks[0])
	if challenge == 0 {
		t.Fatal("zero challenge")
	}

	// 2. A foreign process that cannot set the title echoes the challenge
	//    anyway — refused and re-challenged, nothing applied.
	echo := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4, Seq: 2, ReplyTo: 9,
		Pad: vi.WmRpcPadBound}
	echo.SetTitle("stolen")
	vi.SetWmAuth(&echo, challenge)
	acks = decodeAcks(t, serveOneWmRpc(t, echo.Encode()))
	if len(acks) != 1 || acks[0].Pad != vi.WmRpcPadChallenge || acks[0].Applied != 0 {
		t.Fatalf("unproven echo acks = %+v want re-challenge", acks)
	}
	if tabs.At(0).Title != "x" {
		t.Fatalf("unproven echo applied: title = %q", tabs.At(0).Title)
	}

	// 3. The owner produces the kernel-visible title proof (slot 61 is
	//    owner-restricted; the stub models what the kernel would read back)
	//    and the echo binds pid 7 under a fresh session token.
	ownerTitle = vi.WmBindChallengeTitle(challenge, 7)
	echo.ReplyTo = 7
	echo.Seq = 3
	acks = decodeAcks(t, serveOneWmRpc(t, echo.Encode()))
	if len(acks) != 1 || acks[0].Pad != vi.WmRpcPadBound || acks[0].Applied != 1 {
		t.Fatalf("bind ack = %+v want bound applied", acks)
	}
	token := vi.WmAuth(acks[0])
	if token == 0 || token == challenge {
		t.Fatalf("session token = %#x", token)
	}
	if tabs.At(0).Title != "stolen" {
		t.Fatalf("bound request did not apply: title = %q", tabs.At(0).Title)
	}

	// 4. Wrong-token and wrong-pid frames are refused outright — the
	//    attacker cannot satisfy either side of the binding alone.
	forged := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4, Seq: 4, ReplyTo: 7,
		Pad: vi.WmRpcPadBound}
	forged.SetTitle("pwned")
	vi.SetWmAuth(&forged, token^0xff)
	wrongPid := forged
	wrongPid.ReplyTo = 9
	vi.SetWmAuth(&wrongPid, token)
	acks = decodeAcks(t, serveWmRpcFrames(t, [][]byte{forged.Encode(), wrongPid.Encode()}))
	for i, a := range acks {
		if a.Applied != 0 || a.Pad != vi.WmRpcPadPlain {
			t.Fatalf("forged frame %d ack = %+v want bare refusal", i, a)
		}
	}
	if tabs.At(0).Title != "stolen" {
		t.Fatalf("forged frame applied: title = %q", tabs.At(0).Title)
	}

	// 5. The bound owner's frames still apply: right pid, right token.
	bound := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4, Seq: 5, ReplyTo: 7,
		Pad: vi.WmRpcPadBound}
	bound.SetTitle("legit")
	vi.SetWmAuth(&bound, token)
	acks = decodeAcks(t, serveOneWmRpc(t, bound.Encode()))
	if len(acks) != 1 || acks[0].Applied != 1 || acks[0].Pad != vi.WmRpcPadBound ||
		vi.WmAuth(acks[0]) != token {
		t.Fatalf("bound-owner ack = %+v", acks)
	}
	if tabs.At(0).Title != "legit" {
		t.Fatalf("bound request did not apply: title = %q", tabs.At(0).Title)
	}
}

// #3048: the pre-queued forged echo. The challenge is disclosed to ANY
// requester and the mailbox is any-to-any, so an attacker holding the
// challenge can slip an echo in while the owner's title proof stands —
// before the owner's own echo arrives. The proof title commits to the pid
// the echo claims as reply_to, so the forged echo is refused and the
// honest echo still binds. Before the pid entered the proof this same
// sequence bound the attacker: the title read `wrpc:<challenge>` for any
// reply_to, so the first echo to land won the session.
func TestServiceRPCForgedEchoCannotStealBind(t *testing.T) {
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}
	if !tabs.OpenTab(4, "x") {
		t.Fatal("OpenTab")
	}
	ownerTitle := ""
	stubAuthSeams(t, func(id uint8) (string, bool) {
		if id != 4 || ownerTitle == "" {
			return "", false
		}
		return ownerTitle, true
	})

	// 1. The owner's request draws the challenge; the attacker learns the
	//    same value by asking for one itself (challengeFor(id) returns the
	//    pending challenge to any requester).
	req := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4, Seq: 1, ReplyTo: 7}
	req.SetTitle("real")
	acks := decodeAcks(t, serveOneWmRpc(t, req.Encode()))
	if len(acks) != 1 || acks[0].Pad != vi.WmRpcPadChallenge {
		t.Fatalf("challenge step acks = %+v", acks)
	}
	challenge := vi.WmAuth(acks[0])
	if challenge == 0 {
		t.Fatal("zero challenge")
	}

	// 2. The owner has set its title proof — committed to pid 7 — but its
	//    echo has not landed yet. The attacker pre-queues the winning
	//    shape: the echoed challenge with reply_to pointing at ITS pid.
	ownerTitle = vi.WmBindChallengeTitle(challenge, 7)
	forged := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4, Seq: 2, ReplyTo: 9,
		Pad: vi.WmRpcPadBound}
	forged.SetTitle("pwned")
	vi.SetWmAuth(&forged, challenge)
	acks = decodeAcks(t, serveOneWmRpc(t, forged.Encode()))
	if len(acks) != 1 || acks[0].Pad != vi.WmRpcPadChallenge || acks[0].Applied != 0 {
		t.Fatalf("forged echo ack = %+v want re-challenge refusal", acks)
	}
	if rpcBindings[4].token != 0 {
		t.Fatalf("forged echo installed a binding: %+v", rpcBindings[4])
	}
	if tabs.At(0).Title != "x" {
		t.Fatalf("forged echo applied: title = %q", tabs.At(0).Title)
	}

	// 3. The challenge is still pending — the forged echo consumed
	//    nothing — so the owner's echo binds pid 7 under the session token.
	echo := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4, Seq: 3, ReplyTo: 7,
		Pad: vi.WmRpcPadBound}
	echo.SetTitle("real")
	vi.SetWmAuth(&echo, challenge)
	acks = decodeAcks(t, serveOneWmRpc(t, echo.Encode()))
	if len(acks) != 1 || acks[0].Pad != vi.WmRpcPadBound || acks[0].Applied != 1 {
		t.Fatalf("honest echo after forged attempt = %+v want bound applied", acks)
	}
	token := vi.WmAuth(acks[0])
	if rpcBindings[4].pid != 7 || rpcBindings[4].token != token {
		t.Fatalf("binding = %+v want pid 7 under the ack token", rpcBindings[4])
	}
}

// The binding dies with the window: after the tab closes, the id's old token
// must open nothing — the next frame walks the challenge again.
func TestServiceRPCBindingDiesWithWindow(t *testing.T) {
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}
	if !tabs.OpenTab(4, "x") {
		t.Fatal("OpenTab")
	}
	stubAuthSeams(t, func(uint8) (string, bool) { return "", false })

	rpcBindings[4] = rpcBinding{pid: 7, token: 0xbeef}
	if !tabs.CloseTab(4) {
		t.Fatal("CloseTab")
	}
	if rpcBindings[4].token != 0 {
		t.Fatal("close left a live session token")
	}

	// A frame quoting the dead token must not apply — it is re-challenged.
	req := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4, Seq: 1, ReplyTo: 7,
		Pad: vi.WmRpcPadBound}
	vi.SetWmAuth(&req, 0xbeef)
	acks := decodeAcks(t, serveOneWmRpc(t, req.Encode()))
	if len(acks) != 1 || acks[0].Pad != vi.WmRpcPadChallenge || acks[0].Applied != 0 {
		t.Fatalf("dead-token frame ack = %+v want re-challenge", acks)
	}
}

// #2260: a client that loses its session token (ack timeout / full-mailbox
// send refusal under load) while the seat still holds the binding used to
// wedge permanently — every unauthed retry drew a bare refusal and no
// challenge, so the client could never rebind and its requests (the notify
// post included) starved forever. The seat now answers an unauthed frame
// on a bound id with a fresh challenge; the title-proven echo rebinds.
func TestServiceRPCReChallengesBoundIdWithNoCredentials(t *testing.T) {
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}
	if !tabs.OpenTab(4, "x") {
		t.Fatal("OpenTab")
	}
	ownerTitle := ""
	stubAuthSeams(t, func(id uint8) (string, bool) {
		if id != 4 || ownerTitle == "" {
			return "", false
		}
		return ownerTitle, true
	})
	// The seat's half of the original session: pid 7 bound window 4.
	rpcBindings[4] = rpcBinding{pid: 7, token: 0xbeef}

	// 1. An unauthed frame (client's token is gone) draws a challenge,
	//    not a bare refusal — the client's documented recovery expects it.
	req := vi.WmRpc{Kind: vi.WmRpcKindNotify, ID: 4, Seq: 1, ReplyTo: 7}
	req.SetTitle("copied X")
	acks := decodeAcks(t, serveOneWmRpc(t, req.Encode()))
	if len(acks) != 1 || acks[0].Pad != vi.WmRpcPadChallenge || acks[0].Applied != 0 {
		t.Fatalf("lost-token frame ack = %+v want a fresh challenge", acks)
	}
	challenge := vi.WmAuth(acks[0])
	if challenge == 0 {
		t.Fatal("zero challenge")
	}

	// 2. The echo with the owner-only title proof rebinds under a FRESH
	//    token — the stale binding retires — and the request applies.
	ownerTitle = vi.WmBindChallengeTitle(challenge, 7)
	echo := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4, Seq: 2, ReplyTo: 7,
		Pad: vi.WmRpcPadBound}
	echo.SetTitle("real")
	vi.SetWmAuth(&echo, challenge)
	acks = decodeAcks(t, serveOneWmRpc(t, echo.Encode()))
	if len(acks) != 1 || acks[0].Pad != vi.WmRpcPadBound || acks[0].Applied != 1 {
		t.Fatalf("heal echo ack = %+v want bound applied", acks)
	}
	token := vi.WmAuth(acks[0])
	if token == 0 || token == 0xbeef || token == challenge {
		t.Fatalf("rebind token = %#x want a fresh value", token)
	}
	if rpcBindings[4].token != token || rpcBindings[4].pid != 7 {
		t.Fatalf("binding after heal = %+v", rpcBindings[4])
	}

	// 3. The wedge is healed: the rebound client's frames apply again.
	bound := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4, Seq: 3, ReplyTo: 7,
		Pad: vi.WmRpcPadBound}
	bound.SetTitle("legit")
	vi.SetWmAuth(&bound, token)
	acks = decodeAcks(t, serveOneWmRpc(t, bound.Encode()))
	if len(acks) != 1 || acks[0].Applied != 1 {
		t.Fatalf("post-heal bound ack = %+v", acks)
	}
}

// The heal must not soften the credential check: a nonzero auth value that
// is neither the session token nor the pending challenge still draws the
// bare refusal — no challenge oracle for credential guessing.
func TestServiceRPCStillRefusesWrongTokenOnBoundId(t *testing.T) {
	savedTabs := tabs
	defer func() { tabs = savedTabs }()
	tabs = TabStrip{}
	if !tabs.OpenTab(4, "x") {
		t.Fatal("OpenTab")
	}
	stubAuthSeams(t, func(uint8) (string, bool) { return "", false })
	rpcBindings[4] = rpcBinding{pid: 7, token: 0xbeef}

	forged := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4, Seq: 1, ReplyTo: 7,
		Pad: vi.WmRpcPadBound}
	forged.SetTitle("pwned")
	vi.SetWmAuth(&forged, 0xdead) // wrong nonzero token
	acks := decodeAcks(t, serveOneWmRpc(t, forged.Encode()))
	if len(acks) != 1 || acks[0].Applied != 0 || acks[0].Pad != vi.WmRpcPadPlain {
		t.Fatalf("wrong-token ack = %+v want bare refusal", acks)
	}
	if tabs.At(0).Title != "x" {
		t.Fatalf("wrong-token frame applied: title = %q", tabs.At(0).Title)
	}
}
