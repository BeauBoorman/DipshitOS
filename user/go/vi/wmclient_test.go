package vi

import (
	"testing"
	"time"
	"unsafe"
)

// The WmRpc wire mirror must stay byte-identical to kernel/src/wnd_core.zig /
// user/src/lib/ui/abi.zig: 38 bytes, kind@0, x@6, title@14.
func TestWmRpcWire(t *testing.T) {
	if got := unsafe.Sizeof(WmRpc{}); got != 38 {
		t.Fatalf("WmRpc size = %d want 38", got)
	}
	if off := unsafe.Offsetof(WmRpc{}.X); off != 6 {
		t.Fatalf("X offset = %d want 6", off)
	}
	if off := unsafe.Offsetof(WmRpc{}.Title); off != 14 {
		t.Fatalf("Title offset = %d want 14", off)
	}
	if WmRpcTitleMax != 24 || WmRpcMax != 64 || WmRpcReplyFlag != 0x80 {
		t.Fatalf("wm rpc consts wrong: %d/%d/%#x", WmRpcTitleMax, WmRpcMax, WmRpcReplyFlag)
	}
	if 38 > WmRpcMax {
		t.Fatalf("frame does not fit the mailbox slot")
	}
}

func TestWmRpcEncodeDecodeRoundTrip(t *testing.T) {
	m := WmRpc{Kind: WmRpcKindDeclareFullscreen, ID: 4, Seq: 1, ReplyTo: 9, Applied: 1}
	m.SetTitle("MyApp")
	b := m.Encode()
	if len(b) != 38 {
		t.Fatalf("encoded len = %d want 38", len(b))
	}
	if b[0] != 8 || b[1] != 4 || b[2] != 1 || b[3] != 9 || b[4] != 1 || b[5] != 0 {
		t.Fatalf("encoded header wrong: %v", b[:6])
	}
	got, ok := DecodeWmRpc(b)
	if !ok {
		t.Fatal("decode failed")
	}
	if got.Kind != m.Kind || got.ID != m.ID || got.Seq != m.Seq || got.ReplyTo != m.ReplyTo || got.Applied != m.Applied {
		t.Fatalf("round-trip header drift: %+v", got)
	}
	if got.TitleString() != "MyApp" {
		t.Fatalf("title = %q", got.TitleString())
	}
	if _, ok := DecodeWmRpc(b[:37]); ok {
		t.Fatal("short buffer should not decode")
	}
}

func TestWmRpcSetTitleFrameRoundTrip(t *testing.T) {
	m := WmRpc{Kind: WmRpcKindSetTitle, ID: 4, Seq: 5, ReplyTo: 9}
	m.SetTitle("notes.txt")
	got, ok := DecodeWmRpc(m.Encode())
	if !ok {
		t.Fatal("set-title frame did not decode")
	}
	if got.Kind != WmRpcKindSetTitle || got.ID != 4 || got.Seq != 5 || got.ReplyTo != 9 {
		t.Fatalf("set-title header = %+v", got)
	}
	if got.TitleString() != "notes.txt" {
		t.Fatalf("set-title payload = %q", got.TitleString())
	}
}

// The u16 rect fields are little-endian at the frozen offsets: x@6, y@8,
// w@10, h@12.
func TestWmRpcRectBytes(t *testing.T) {
	m := WmRpc{Kind: WmRpcKindConfig, X: 0x1234, Y: 0x5678, W: 0x0102, H: 0x0304}
	b := m.Encode()
	if b[6] != 0x34 || b[7] != 0x12 {
		t.Fatalf("x bytes wrong: %v", b[6:8])
	}
	got, _ := DecodeWmRpc(b)
	if got.X != 0x1234 || got.Y != 0x5678 || got.W != 0x0102 || got.H != 0x0304 {
		t.Fatalf("rect round-trip wrong: %+v", got)
	}
}

func TestWmRpcTitleTruncation(t *testing.T) {
	m := WmRpc{}
	m.SetTitle("012345678901234567890123456789") // 30 > 24
	if m.TitleString() != "012345678901234567890123" {
		t.Fatalf("title truncation = %q", m.TitleString())
	}
	if got := m.Title[WmRpcTitleMax-1]; got != '3' {
		t.Fatalf("last title byte = %q", got)
	}
}

func TestTabClientDispatch(t *testing.T) {
	c := NewTabClient(4, 512, 340)
	if a := c.Dispatch(Event{Kind: EvMouseDown, Arg0: 10, Arg1: 10}); a != WmActionNone {
		t.Fatalf("mouse action = %v", a)
	}
	if c.W != 512 || c.H != 340 {
		t.Fatalf("canvas drifted: %d x %d", c.W, c.H)
	}
	if a := c.Dispatch(Event{Kind: EvWinResize, Arg0: 1100, Arg1: 720}); a != WmActionResized {
		t.Fatalf("resize action = %v", a)
	}
	if c.W != 1100 || c.H != 720 {
		t.Fatalf("resize not tracked: %d x %d", c.W, c.H)
	}
	if a := c.Dispatch(Event{Kind: EvWinFocus}); a != WmActionNone || !c.Focused {
		t.Fatalf("focus not tracked: %v %v", a, c.Focused)
	}
	if a := c.Dispatch(Event{Kind: EvWinBlur}); a != WmActionNone || c.Focused {
		t.Fatalf("blur not tracked: %v %v", a, c.Focused)
	}
	if a := c.Dispatch(Event{Kind: EvWinClose}); a != WmActionClosed {
		t.Fatalf("close action = %v", a)
	}
}

// Off-guest there is no WM seat, so every request is an honest false (never a
// fabricated success).
func TestWmMailRequestNoSeat(t *testing.T) {
	if WmMailRequest(WmRpcKindRaise, 4, 0, 0, 0, 0, "", "DEMOAPP.ELF") {
		t.Fatal("host WmMailRequest should be false")
	}
	if DeclareFullscreen(4, "T", "DEMOAPP.ELF") {
		t.Fatal("host DeclareFullscreen should be false")
	}
	if DeclareNav(4, "/host", "DEMOAPP.ELF") {
		t.Fatal("host DeclareNav should be false")
	}
	if _, ok := PollNav(4, "DEMOAPP.ELF"); ok {
		t.Fatal("host PollNav should be false")
	}
	if SetTabTitle(4, "notes.txt", "DEMOAPP.ELF") {
		t.Fatal("host SetTabTitle should be false")
	}
	if Notify(4, "copied notes.txt", "DEMOAPP.ELF") {
		t.Fatal("host Notify should be false")
	}
}

// M79k (#1720): the notify request is the same generic frame as every other
// additive kind — kind 12, the sender's id, and the message in the title.
// The 24-byte title IS the whole text budget, so a longer message is bounded
// on the wire rather than refused.
// The fake's process table names the requester NOTE.ELF (wmMailFake.hook is
// hardwired) and WmPeers finds the SELF by process name, so the requester
// name below must be that one — anything else is refused before the
// mailbox, which is exactly the no-seat refusal TestWmMailRequestNoSeat pins.
func TestNotifyRequest(t *testing.T) {
	f := startWmMailFake(t)
	f.autoReply = true
	if !Notify(4, "copied KNOWN.TXT", "NOTE.ELF") {
		t.Fatal("notify request should receive its applied ack")
	}
	if len(f.sent) != 1 {
		t.Fatalf("sent requests = %d want 1", len(f.sent))
	}
	got := f.sent[0]
	if got.Kind != WmRpcKindNotify || got.ID != 4 || got.TitleString() != "copied KNOWN.TXT" {
		t.Fatalf("notify request = %+v title=%q", got, got.TitleString())
	}
}

func TestNotifyRefusesEmptyBeforeSend(t *testing.T) {
	f := startWmMailFake(t)
	if Notify(4, "", "NOTE.ELF") {
		t.Fatal("an empty message must refuse")
	}
	if f.procsCalls != 0 || f.sendCalls != 0 {
		t.Fatalf("an empty message touched the wire: procs=%d send=%d", f.procsCalls, f.sendCalls)
	}
}

// The text budget is the frame title, so a long message is BOUNDED (the
// tail is cut) and never silently sent whole — the app's own marker prints
// the bounded text, so the log and the screen agree.
func TestNotifyBoundsTheMessageToTheTitle(t *testing.T) {
	f := startWmMailFake(t)
	f.autoReply = true
	const long = "copied a-very-long-file-name.txt"
	if !Notify(4, long, "NOTE.ELF") {
		t.Fatal("notify request should receive its applied ack")
	}
	got := f.sent[0].TitleString()
	if len(got) != WmRpcTitleMax {
		t.Fatalf("bounded message is %d bytes, want exactly the %d-byte title budget", len(got), WmRpcTitleMax)
	}
	if long[:WmRpcTitleMax] != got {
		t.Fatalf("bounded message = %q want the first %d bytes of the request", got, WmRpcTitleMax)
	}
}

func TestWmRpcKindConstants(t *testing.T) {
	pairs := []struct {
		got, want uint8
	}{
		{WmRpcKindRaise, 1}, {WmRpcKindConfig, 2}, {WmRpcKindRegisterAction, 3},
		{WmRpcKindInvokeAction, 4}, {WmRpcKindAttachTab, 5}, {WmRpcKindDetachTab, 6},
		{WmRpcKindCycleTab, 7}, {WmRpcKindDeclareFullscreen, 8},
		{WmRpcKindNavDeclare, 9}, {WmRpcKindNavPoll, 10}, {WmRpcKindSetTitle, 11},
		{WmRpcKindNotify, 12}, {WmRpcKindSettingsSubscribe, 13},
		{WmRpcKindSettingsPublish, 14}, {WmRpcKindSettingsChanged, 15},
	}
	for _, p := range pairs {
		if p.got != p.want {
			t.Fatalf("kind = %d want %d", p.got, p.want)
		}
	}
}

// wmMailFake is a scripted kernel for the WM_RPC client: a process table
// with a live seat, a send that succeeds, and a recv that is either empty
// or a scripted ack. Slot 4 (sys_sleep) is counted so a silent seat is
// pinned as a tick-bounded park, not a yield-spin.
type wmMailFake struct {
	sendCalls  int
	recvCalls  int
	sleepCalls int
	procsCalls int
	sendTarget uint32
	selfPID    uint64
	sent       []WmRpc
	// reply, when set, is copied into the caller's recv buffer starting at
	// the replyAt-th recv (1-based). recvCalls < replyAt returns empty.
	reply   []byte
	replyAt int
	// replies optionally script one distinct frame per recv, starting at
	// replyAt. It lets a test prove that foreign acks are consumed and dropped.
	replies [][]byte
	// autoReply builds each ack from the most recently sent request.
	autoReply bool
	// replyFn, when set, is the seat's reply logic: it sees the most
	// recently sent request and returns the reply frame (nil = silent).
	// It takes precedence over autoReply/replies so a test can model the
	// Go seat's challenge→bind handshake with the real seq mirrored.
	replyFn func(WmRpc) []byte
	// wmName is the process-table name of the fake WM seat. It defaults to
	// the legacy Zig seat: bare applied acks are honest there. Go-seat tests
	// set it to GOTABWM.ELF, where the authenticated protocol applies.
	wmName string
	// kernPID, when > 0, is the fake kernel's slot-87 (sys_getpid) answer —
	// the register WmPeers prefers over the name scan (#2158). A zero
	// value models a kernel without the slot (-ENOSYS → scan fallback).
	kernPID int64
	// sendENOSPC fails the next N sends with -ENOSPC — the seat's ring
	// momentarily full, the transient #2260 made retriable.
	sendENOSPC int
	// extraProcs are appended to the fake's two built-in proc rows — the
	// duplicate-instance shape needs a second RUNNING row with the same
	// name as the caller's binary.
	extraProcs []ProcRow
}

func namedProc(pid uint64, name string) ProcRow {
	r := ProcRow{PID: pid, State: ProcRunning}
	copy(r.NameBuf[:], name)
	return r
}

func (f *wmMailFake) hook(num uintptr, a0, a1, a2, a3 uintptr) int64 {
	switch num {
	case SlotProcs:
		f.procsCalls++
		buf := hookBytes(a0, a1)
		selfPID := f.selfPID
		if selfPID == 0 {
			selfPID = 9
		}
		wmName := f.wmName
		if wmName == "" {
			wmName = "TABWM.BIN"
		}
		rows := []ProcRow{
			namedProc(3, wmName),
			namedProc(selfPID, "NOTE.ELF"),
		}
		rows = append(rows, f.extraProcs...)
		n := 0
		for _, r := range rows {
			off := n * ProcRowSize
			if off+ProcRowSize > len(buf) {
				break
			}
			putU64(buf[off:], r.PID)
			putU64(buf[off+8:], r.State)
			putU64(buf[off+16:], r.ExitStatus)
			copy(buf[off+24:], r.NameBuf[:])
			n++
		}
		return int64(n)
	case SlotWmctl:
		// #2079: the seat id is the kernel's register (cmd 16), not a
		// name match — the fake answers pid 3, the pid its proc table
		// assigns to GOTABWM.ELF.
		if a0 == uintptr(WmctlSeatPidCmd) {
			return 3
		}
		return -ErrENOSYS
	case SlotGetpid:
		// #2158: the self-pid register — a zero kernPID models a kernel
		// without the slot, exercising the name-scan fallback.
		if f.kernPID > 0 {
			return f.kernPID
		}
		return -ErrENOSYS
	case SlotIPCSend:
		f.sendCalls++
		f.sendTarget = uint32(a0)
		if f.sendENOSPC > 0 {
			f.sendENOSPC--
			return -ErrENOSPC
		}
		if frame, ok := DecodeWmRpc(hookBytes(a1, a2)); ok {
			f.sent = append(f.sent, frame)
		}
		return int64(a2)
	case SlotIPCRecv:
		f.recvCalls++
		var reply []byte
		if f.replyFn != nil && len(f.sent) > 0 {
			reply = f.replyFn(f.sent[len(f.sent)-1])
		} else if f.autoReply && len(f.sent) > 0 {
			req := f.sent[len(f.sent)-1]
			ack := WmRpc{
				Kind:    req.Kind | WmRpcReplyFlag,
				ID:      req.ID,
				Seq:     req.Seq,
				ReplyTo: req.ReplyTo,
				Applied: 1,
			}
			reply = ack.Encode()
		} else if len(f.replies) > 0 && f.replyAt > 0 {
			i := f.recvCalls - f.replyAt
			if i >= 0 && i < len(f.replies) {
				reply = f.replies[i]
			}
		} else if f.reply != nil && f.replyAt > 0 && f.recvCalls >= f.replyAt {
			reply = f.reply
		}
		if reply != nil {
			dst := hookBytes(a0, a1)
			copy(dst, reply)
			return int64(len(reply))
		}
		return 0
	case SlotSleep:
		f.sleepCalls++
		return 0
	}
	return -ErrENOSYS
}

func startWmMailFake(t *testing.T) *wmMailFake {
	t.Helper()
	wmSeq.Store(0)
	resetSettingChangeQueue()
	resetWmAuth()
	t.Cleanup(func() {
		wmSeq.Store(0)
		resetSettingChangeQueue()
		resetWmAuth()
	})
	f := &wmMailFake{}
	prev := SetSyscallHookForTest(f.hook)
	t.Cleanup(func() { SetSyscallHookForTest(prev) })
	return f
}

func TestWmMailWaitTicksIsATickBound(t *testing.T) {
	// A two-million-iteration yield loop is not a tick bound (#1489).
	if wmMailWaitTicks < 2 || wmMailWaitTicks > 32 {
		t.Fatalf("wmMailWaitTicks = %d want a small scheduler-tick budget", wmMailWaitTicks)
	}
}

func TestFitsWire8(t *testing.T) {
	for _, tc := range []struct {
		value uint32
		want  bool
	}{
		{0, true},
		{0xff, true},
		{0x100, false},
		{^uint32(0), false},
	} {
		if got := fitsWire8(tc.value); got != tc.want {
			t.Fatalf("fitsWire8(%#x) = %v want %v", tc.value, got, tc.want)
		}
	}
}

func TestWmMailRequestRefusesWideValuesBeforeSend(t *testing.T) {
	f := startWmMailFake(t)
	if WmMailRequest(WmRpcKindDeclareFullscreen, 0x100, 0, 0, 0, 0, "wide", "NOTE.ELF") {
		t.Fatal("wide window id must refuse")
	}
	if f.procsCalls != 0 || f.sendCalls != 0 || f.recvCalls != 0 {
		t.Fatalf("wide id touched the wire: procs=%d send=%d recv=%d", f.procsCalls, f.sendCalls, f.recvCalls)
	}

	f.selfPID = 0x100
	if WmMailRequest(WmRpcKindDeclareFullscreen, 4, 0, 0, 0, 0, "wide-pid", "NOTE.ELF") {
		t.Fatal("wide requester pid must refuse")
	}
	if f.sendCalls != 0 || f.recvCalls != 0 {
		t.Fatalf("wide pid touched the wire: send=%d recv=%d", f.sendCalls, f.recvCalls)
	}
}

func TestPollNavRefusesWideValuesBeforeSend(t *testing.T) {
	f := startWmMailFake(t)
	if path, ok := PollNav(0x100, "NOTE.ELF"); ok || path != "" {
		t.Fatalf("wide PollNav id = (%q, %v) want refusal", path, ok)
	}
	if f.procsCalls != 0 || f.sendCalls != 0 || f.recvCalls != 0 {
		t.Fatalf("wide PollNav id touched the wire: procs=%d send=%d recv=%d", f.procsCalls, f.sendCalls, f.recvCalls)
	}

	f.selfPID = 0x100
	if path, ok := PollNav(4, "NOTE.ELF"); ok || path != "" {
		t.Fatalf("wide PollNav pid = (%q, %v) want refusal", path, ok)
	}
	if f.sendCalls != 0 || f.recvCalls != 0 {
		t.Fatalf("wide PollNav pid touched the wire: send=%d recv=%d", f.sendCalls, f.recvCalls)
	}
}

func TestWmMailRequestRefusesGeometryUnderGoSeat(t *testing.T) {
	// #2157: under the Go seat the frame's only x/y/w/h fields are the
	// M97g-F2 auth union — a bound or challenged request can never carry
	// geometry, so a nonzero request must refuse at the call boundary
	// instead of landing on the wire with its geometry silently zeroed.
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	const challenge = uint64(0x00deadbeef00cafe)
	const token = uint64(0x0123456789abcdef)
	f.replyFn = func(req WmRpc) []byte {
		rep := WmRpc{Kind: req.Kind | WmRpcReplyFlag, ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo}
		switch WmAuth(req) {
		case 0:
			rep.Pad = WmRpcPadChallenge
			SetWmAuth(&rep, challenge)
		case challenge, token:
			rep.Pad = WmRpcPadBound
			SetWmAuth(&rep, token)
			rep.Applied = 1
		default:
			return nil
		}
		return rep.Encode()
	}
	prev := bindSetTitle
	bindSetTitle = func(id int, s string) int64 { return 0 }
	t.Cleanup(func() { bindSetTitle = prev })

	if WmMailRequest(WmRpcKindConfig, 4, 11, 22, 330, 440, "t", "NOTE.ELF") {
		t.Fatal("nonzero geometry under the Go seat must refuse, not silently drop")
	}
	if len(f.sent) != 0 {
		t.Fatalf("refused request touched the wire: sent = %d frames", len(f.sent))
	}

	// Zero geometry keeps the challenge→bind exchange byte-identical: the
	// union carries zero, the echoed challenge, then the session token.
	if !WmMailRequest(WmRpcKindConfig, 4, 0, 0, 0, 0, "t", "NOTE.ELF") {
		t.Fatal("zero-geometry config should complete the bind handshake")
	}
	if WmAuth(f.sent[0]) != 0 || WmAuth(f.sent[1]) != challenge {
		t.Fatalf("unbound/echo unions = %#x/%#x want 0/%#x",
			WmAuth(f.sent[0]), WmAuth(f.sent[1]), challenge)
	}
	if !WmMailRequest(WmRpcKindConfig, 4, 0, 0, 0, 0, "t", "NOTE.ELF") {
		t.Fatal("bound zero-geometry config should still apply")
	}
	if WmAuth(f.sent[len(f.sent)-1]) != token {
		t.Fatal("bound frame does not carry the session token")
	}

	// Contrast: under a legacy (Zig) seat the same call still carries
	// geometry — those fields are real geometry there, not an auth union.
	g := startWmMailFake(t)
	g.autoReply = true
	if !WmMailRequest(WmRpcKindConfig, 4, 11, 22, 330, 440, "t", "NOTE.ELF") {
		t.Fatal("legacy-seat config request refused")
	}
	if g.sent[0].X != 11 || g.sent[0].Y != 22 || g.sent[0].W != 330 || g.sent[0].H != 440 {
		t.Fatalf("legacy frame geometry = (%d,%d,%d,%d) want (11,22,330,440)",
			g.sent[0].X, g.sent[0].Y, g.sent[0].W, g.sent[0].H)
	}
}

func TestWmMailRequestRoutesAcksToCallersOwnPid(t *testing.T) {
	// #2158: the caller is the SECOND NOTE.ELF instance (kernel pid 8 —
	// the duplicate-tab chord's spawn); the first instance's row (pid 4)
	// is what a name scan resolves. The kernel register must stamp
	// reply_to=8 so the seat's bind challenge and every later ack lands
	// in THIS mailbox — the audit repro showed reply_to=4 and a bounded
	// 8-tick honest false under the authenticated protocol.
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	f.selfPID = 4 // the FIRST instance's row — the name-scan answer
	f.kernPID = 8
	f.extraProcs = []ProcRow{namedProc(8, "NOTE.ELF")}
	const challenge = uint64(0x00deadbeef00cafe)
	const token = uint64(0x0123456789abcdef)
	f.replyFn = func(req WmRpc) []byte {
		if req.ReplyTo != 8 {
			// The seat routed this ack to the FIRST instance's ring —
			// this mailbox hears nothing.
			return nil
		}
		rep := WmRpc{Kind: req.Kind | WmRpcReplyFlag, ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo}
		switch WmAuth(req) {
		case 0:
			rep.Pad = WmRpcPadChallenge
			SetWmAuth(&rep, challenge)
		case challenge, token:
			rep.Pad = WmRpcPadBound
			SetWmAuth(&rep, token)
			rep.Applied = 1
		default:
			return nil
		}
		return rep.Encode()
	}
	prev := bindSetTitle
	bindSetTitle = func(id int, s string) int64 { return 0 }
	t.Cleanup(func() { bindSetTitle = prev })

	if !WmMailRequest(WmRpcKindRaise, 4, 0, 0, 0, 0, "", "NOTE.ELF") {
		t.Fatal("the second instance's request must route its acks to pid 8, not the first instance's 4")
	}
	if f.sent[0].ReplyTo != 8 {
		t.Fatalf("reply_to = %d want 8 (the caller's own kernel pid)", f.sent[0].ReplyTo)
	}
}

func TestWmMailRequestAllocatesMonotonicSequences(t *testing.T) {
	f := startWmMailFake(t)
	f.autoReply = true
	if !WmMailRequest(WmRpcKindDeclareFullscreen, 4, 0, 0, 0, 0, "first", "NOTE.ELF") {
		t.Fatal("first request should receive its ack")
	}
	if !WmMailRequest(WmRpcKindRaise, 5, 0, 0, 0, 0, "second", "NOTE.ELF") {
		t.Fatal("second request should receive its ack")
	}
	if len(f.sent) != 2 {
		t.Fatalf("sent requests = %d want 2", len(f.sent))
	}
	if f.sent[0].Seq != 1 || f.sent[1].Seq != 2 {
		t.Fatalf("request sequences = %d, %d want 1, 2", f.sent[0].Seq, f.sent[1].Seq)
	}
}

func TestSetTabTitleRequest(t *testing.T) {
	f := startWmMailFake(t)
	f.autoReply = true
	if !SetTabTitle(4, "notes.txt", "NOTE.ELF") {
		t.Fatal("set-title request should receive its applied ack")
	}
	if len(f.sent) != 1 {
		t.Fatalf("sent requests = %d want 1", len(f.sent))
	}
	got := f.sent[0]
	if got.Kind != WmRpcKindSetTitle || got.ID != 4 || got.TitleString() != "notes.txt" {
		t.Fatalf("set-title request = %+v title=%q", got, got.TitleString())
	}
}

func TestSetTabTitleRefusesEmptyBeforeSend(t *testing.T) {
	f := startWmMailFake(t)
	if SetTabTitle(4, "", "NOTE.ELF") {
		t.Fatal("empty title must refuse")
	}
	if f.procsCalls != 0 || f.sendCalls != 0 {
		t.Fatalf("empty title touched the wire: procs=%d send=%d", f.procsCalls, f.sendCalls)
	}
}

func TestWaitWmRpcAckDropsForeignReplies(t *testing.T) {
	f := startWmMailFake(t)
	foreign := WmRpc{Kind: WmRpcKindDeclareFullscreen | WmRpcReplyFlag, ID: 4, Seq: 1, ReplyTo: 9, Applied: 1}
	wrongRequester := WmRpc{Kind: WmRpcKindDeclareFullscreen | WmRpcReplyFlag, ID: 4, Seq: 2, ReplyTo: 8, Applied: 1}
	matching := WmRpc{Kind: WmRpcKindDeclareFullscreen | WmRpcReplyFlag, ID: 4, Seq: 2, ReplyTo: 9, Applied: 1}
	f.replies = [][]byte{foreign.Encode(), wrongRequester.Encode(), matching.Encode()}
	f.replyAt = 1

	rep, ok := waitWmRpcAck(2, 9, func(WmRpc) bool { return true })
	if !ok || rep.Seq != 2 || rep.ReplyTo != 9 {
		t.Fatalf("matched reply = (%+v, %v) want seq=2 reply_to=9", rep, ok)
	}
	if f.recvCalls != 3 || f.sleepCalls != 2 {
		t.Fatalf("foreign replies were not dropped: recv=%d sleep=%d", f.recvCalls, f.sleepCalls)
	}
}

func TestNextWmSeqSkipsZeroOnWrap(t *testing.T) {
	wmSeq.Store(255)
	t.Cleanup(func() { wmSeq.Store(0) })
	if got := nextWmSeq(); got != 1 {
		t.Fatalf("sequence after wrap = %d want 1 (zero is skipped)", got)
	}
}

// A live WM pid that never acks must refuse in a handful of parks, not hang
// inside a million-iteration yield-spin. This is the live-wm1 path: WinOpen
// succeeded, DeclareFullscreen blocked tabapp.Init until the gate timed out.
func TestWmMailRequestSilentSeatRefuses(t *testing.T) {
	f := startWmMailFake(t)
	start := time.Now()
	if WmMailRequest(WmRpcKindDeclareFullscreen, 4, 0, 0, 0, 0, "T", "NOTE.ELF") {
		t.Fatal("silent seat must refuse, not succeed")
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("silent-seat wait hung: %v", elapsed)
	}
	if f.sendCalls != 1 || f.sendTarget != 3 {
		t.Fatalf("send = %d to pid %d, want 1 to WM pid 3", f.sendCalls, f.sendTarget)
	}
	if f.recvCalls != wmMailWaitTicks {
		t.Fatalf("recv probes = %d want %d (one per tick)", f.recvCalls, wmMailWaitTicks)
	}
	if f.sleepCalls != wmMailWaitTicks-1 {
		t.Fatalf("parks = %d want %d (sys_sleep between probes, not after the last)", f.sleepCalls, wmMailWaitTicks-1)
	}
	if DeclareFullscreen(4, "T", "NOTE.ELF") {
		t.Fatal("DeclareFullscreen must surface the refusal")
	}
}

func TestWmMailRequestAckApplied(t *testing.T) {
	f := startWmMailFake(t)
	rep := WmRpc{Kind: WmRpcKindDeclareFullscreen | WmRpcReplyFlag, ID: 4, Seq: 1, ReplyTo: 9, Applied: 1}
	f.reply = rep.Encode()
	f.replyAt = 1
	if !WmMailRequest(WmRpcKindDeclareFullscreen, 4, 0, 0, 0, 0, "T", "NOTE.ELF") {
		t.Fatal("applied ack should succeed")
	}
	if f.recvCalls != 1 {
		t.Fatalf("recv probes = %d want 1 (first probe takes a ready ack)", f.recvCalls)
	}
	if f.sleepCalls != 0 {
		t.Fatalf("parks = %d want 0 when the ack is already in the inbox", f.sleepCalls)
	}
}

func TestWmMailRequestAckRefused(t *testing.T) {
	f := startWmMailFake(t)
	rep := WmRpc{Kind: WmRpcKindDeclareFullscreen | WmRpcReplyFlag, ID: 4, Seq: 1, ReplyTo: 9, Applied: 0}
	f.reply = rep.Encode()
	f.replyAt = 1
	if WmMailRequest(WmRpcKindDeclareFullscreen, 4, 0, 0, 0, 0, "T", "NOTE.ELF") {
		t.Fatal("applied=0 ack is a refusal")
	}
	if f.sleepCalls != 0 {
		t.Fatalf("parks = %d want 0", f.sleepCalls)
	}
}

func TestWmMailRequestAckAfterPark(t *testing.T) {
	f := startWmMailFake(t)
	rep := WmRpc{Kind: WmRpcKindDeclareFullscreen | WmRpcReplyFlag, ID: 4, Seq: 1, ReplyTo: 9, Applied: 1}
	f.reply = rep.Encode()
	f.replyAt = 3
	if !WmMailRequest(WmRpcKindDeclareFullscreen, 4, 0, 0, 0, 0, "T", "NOTE.ELF") {
		t.Fatal("ack after two empty probes should succeed")
	}
	if f.recvCalls != 3 {
		t.Fatalf("recv probes = %d want 3", f.recvCalls)
	}
	if f.sleepCalls != 2 {
		t.Fatalf("parks = %d want 2", f.sleepCalls)
	}
}

func TestPollNavSilentSeatRefuses(t *testing.T) {
	f := startWmMailFake(t)
	start := time.Now()
	if path, ok := PollNav(4, "NOTE.ELF"); ok || path != "" {
		t.Fatalf("silent PollNav = (%q, %v) want empty refusal", path, ok)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("silent PollNav hung: %v", elapsed)
	}
	if f.recvCalls != wmMailWaitTicks || f.sleepCalls != wmMailWaitTicks-1 {
		t.Fatalf("PollNav wait = %d probes / %d parks, want %d / %d",
			f.recvCalls, f.sleepCalls, wmMailWaitTicks, wmMailWaitTicks-1)
	}
}

func TestPollNavAckReturnsPath(t *testing.T) {
	f := startWmMailFake(t)
	rep := WmRpc{Kind: WmRpcKindNavPoll | WmRpcReplyFlag, ID: 4, Seq: 1, ReplyTo: 9, Applied: 1}
	rep.SetTitle("/host")
	f.reply = rep.Encode()
	f.replyAt = 1
	path, ok := PollNav(4, "NOTE.ELF")
	if !ok || path != "/host" {
		t.Fatalf("PollNav = (%q, %v) want (/host, true)", path, ok)
	}
	if f.sleepCalls != 0 {
		t.Fatalf("parks = %d want 0", f.sleepCalls)
	}
}

func TestSettingsBusRequestsAndAsyncNoticeDuringAckWait(t *testing.T) {
	f := startWmMailFake(t)
	req := WmRpc{Kind: WmRpcKindSettingsSubscribe | WmRpcReplyFlag, ID: 4, Seq: 1, ReplyTo: 9, Applied: 1}
	change := WmRpc{Kind: WmRpcKindSettingsChanged, ID: 4}
	change.SetTitle("theme")
	f.replies = [][]byte{change.Encode(), req.Encode()}
	f.replyAt = 1
	if !SubscribeSetting(4, "theme", "NOTE.ELF") {
		t.Fatal("theme subscription should receive its applied ack")
	}
	if len(f.sent) != 1 || f.sent[0].Kind != WmRpcKindSettingsSubscribe ||
		f.sent[0].ID != 4 || f.sent[0].TitleString() != "theme" {
		t.Fatalf("subscription request = %+v", f.sent)
	}
	if key, ok := PollSettingChanged(4); !ok || key != "theme" {
		t.Fatalf("queued async key = (%q, %v), want (theme, true)", key, ok)
	}
	if key, ok := PollSettingChanged(4); ok || key != "" {
		t.Fatalf("notice was not consumed: (%q, %v)", key, ok)
	}
}

func TestSettingsBusRefusesInvalidKeysBeforeSending(t *testing.T) {
	f := startWmMailFake(t)
	if SubscribeSetting(4, "font_size_extra_123456789", "NOTE.ELF") {
		t.Fatal("unknown overlong setting key must refuse")
	}
	if PublishSettingChange(4, "", "NOTE.ELF") {
		t.Fatal("empty setting key must refuse")
	}
	if f.procsCalls != 0 || f.sendCalls != 0 || f.recvCalls != 0 {
		t.Fatalf("invalid key touched the wire: procs=%d send=%d recv=%d",
			f.procsCalls, f.sendCalls, f.recvCalls)
	}
}

// M97g-F2 (#2080): under the Go seat a bare applied=1 ack is FORGED — the
// authenticated protocol answers every request with a Pad-marked auth ack,
// never a plain one. Before the bind protocol the client accepted any ack
// matching seq+reply_to, so a forged frame satisfied the wait.
func TestForgedAckUnderGoSeatIsIgnored(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	f.autoReply = true // bare applied=1 acks: exactly the forgery shape
	if WmMailRequest(WmRpcKindRaise, 4, 0, 0, 0, 0, "", "NOTE.ELF") {
		t.Fatal("a tokenless ack satisfied a request under the Go seat")
	}
}

// The honest Go-seat exchange end to end: an unbound request draws the
// challenge, the client proves ownership through the window title, the echo
// completes the bind, and the applied ack delivers the session token that
// every later request must quote.
func TestGoSeatBindHandshake(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	const challenge = uint64(0x00deadbeef00cafe)
	const token = uint64(0x0123456789abcdef)
	f.replyFn = func(req WmRpc) []byte {
		rep := WmRpc{Kind: req.Kind | WmRpcReplyFlag, ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo}
		switch WmAuth(req) {
		case 0:
			rep.Pad = WmRpcPadChallenge
			SetWmAuth(&rep, challenge)
		case challenge:
			rep.Pad = WmRpcPadBound
			SetWmAuth(&rep, token)
			rep.Applied = 1
		case token:
			rep.Pad = WmRpcPadBound
			SetWmAuth(&rep, token)
			rep.Applied = 1
		default:
			return nil
		}
		return rep.Encode()
	}
	var titles []string
	prev := bindSetTitle
	bindSetTitle = func(id int, s string) int64 {
		titles = append(titles, s)
		return 0
	}
	t.Cleanup(func() { bindSetTitle = prev })

	if !WmMailRequest(WmRpcKindSetTitle, 4, 0, 0, 0, 0, "Mine", "NOTE.ELF") {
		t.Fatal("the bind handshake did not complete")
	}
	if len(f.sent) != 2 {
		t.Fatalf("sent %d frames want challenge+echo", len(f.sent))
	}
	if f.sent[0].Pad != WmRpcPadPlain || WmAuth(f.sent[0]) != 0 {
		t.Fatalf("first frame pad=%d union=%#x want unbound", f.sent[0].Pad, WmAuth(f.sent[0]))
	}
	if f.sent[1].Pad != WmRpcPadBound || WmAuth(f.sent[1]) != challenge {
		t.Fatalf("echo frame pad=%d union=%#x want challenge %#x",
			f.sent[1].Pad, WmAuth(f.sent[1]), challenge)
	}
	// The ownership proof title, then the title the request meant to wear.
	if len(titles) != 2 || titles[0] != WmBindChallengeTitle(challenge, 9) || titles[1] != "Mine" {
		t.Fatalf("title sets = %v want [%q %q]", titles, WmBindChallengeTitle(challenge, 9), "Mine")
	}
	if wmToken(4) != token {
		t.Fatalf("session token = %#x want %#x", wmToken(4), token)
	}

	// A later request rides the token and answers without a handshake.
	if !WmMailRequest(WmRpcKindRaise, 4, 0, 0, 0, 0, "", "NOTE.ELF") {
		t.Fatal("bound request refused")
	}
	last := f.sent[len(f.sent)-1]
	if last.Pad != WmRpcPadBound || WmAuth(last) != token {
		t.Fatalf("bound frame pad=%d union=%#x want token %#x", last.Pad, WmAuth(last), token)
	}
}

// The forged-ack boundary at protocol level: an ack that quotes the WRONG
// token must not satisfy a bound request, even though seq and reply_to match.
func TestGoSeatBoundAckNeedsTheToken(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	const token = uint64(0x1111222233334444)
	setWmToken(4, token)
	f.replyFn = func(req WmRpc) []byte {
		rep := WmRpc{Kind: req.Kind | WmRpcReplyFlag, ID: req.ID, Seq: req.Seq,
			ReplyTo: req.ReplyTo, Applied: 1, Pad: WmRpcPadBound}
		SetWmAuth(&rep, 0x9999) // the attacker's token guess
		return rep.Encode()
	}
	if WmMailRequest(WmRpcKindRaise, 4, 0, 0, 0, 0, "", "NOTE.ELF") {
		t.Fatal("an ack quoting a wrong token satisfied a bound request")
	}
}

// M102 defect #12 (#2236): a bound request that draws a re-challenge —
// the seat's answer to a token it no longer holds, e.g. a reused window
// id — re-proves and rebinds in the SAME call, the wqPage shape. Before
// this the wait dropped the challenge as a non-answer, burned every
// round's timeout, and the seat's queued bind surfaced only at teardown.
func TestGoSeatBoundRechallengeRebinds(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	const stale = uint64(0x5a1e5a1e5a1e5a1e)
	const challenge = uint64(0x00deadbeef00cafe)
	const token = uint64(0x0123456789abcdef)
	setWmToken(4, stale)
	f.replyFn = func(req WmRpc) []byte {
		rep := WmRpc{Kind: req.Kind | WmRpcReplyFlag, ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo}
		switch WmAuth(req) {
		case stale:
			rep.Pad = WmRpcPadChallenge
			SetWmAuth(&rep, challenge)
		case challenge, token:
			rep.Pad = WmRpcPadBound
			SetWmAuth(&rep, token)
			rep.Applied = 1
		default:
			return nil
		}
		return rep.Encode()
	}
	var titles []string
	prev := bindSetTitle
	bindSetTitle = func(id int, s string) int64 {
		titles = append(titles, s)
		return 0
	}
	t.Cleanup(func() { bindSetTitle = prev })

	if !WmMailRequest(WmRpcKindSetTitle, 4, 0, 0, 0, 0, "Mine", "NOTE.ELF") {
		t.Fatal("a re-challenged bound request must rebind, not refuse")
	}
	if len(f.sent) != 2 {
		t.Fatalf("sent %d frames want stale+echo", len(f.sent))
	}
	if f.sent[0].Pad != WmRpcPadBound || WmAuth(f.sent[0]) != stale {
		t.Fatalf("first frame pad=%d union=%#x want stale-bound", f.sent[0].Pad, WmAuth(f.sent[0]))
	}
	if f.sent[1].Pad != WmRpcPadBound || WmAuth(f.sent[1]) != challenge {
		t.Fatalf("echo frame pad=%d union=%#x want challenge %#x",
			f.sent[1].Pad, WmAuth(f.sent[1]), challenge)
	}
	if len(titles) != 2 || titles[0] != WmBindChallengeTitle(challenge, 9) || titles[1] != "Mine" {
		t.Fatalf("title sets = %v want [challenge, %q]", titles, "Mine")
	}
	if wmToken(4) != token {
		t.Fatalf("session token = %#x want rebound %#x", wmToken(4), token)
	}
	// The challenge answered the first send inline and the bound ack did
	// the same for the echo — the rebind never parked once.
	if f.sleepCalls != 0 {
		t.Fatalf("rebind parked %d times — the challenge must answer inline", f.sleepCalls)
	}
}

// M102 defect #12 (#2236), the table side: a session token belongs to its
// window's lifetime. WinOpen can hand back an id the kernel just recycled
// — the seat dropped its half of the binding on the release mirror — and
// a successful WinClose ends the binding. Neither may leave the dead
// window's token in the table for a reused id to quote.
func TestWindowLifecycleClearsWmToken(t *testing.T) {
	resetWmAuth()
	t.Cleanup(resetWmAuth)
	closeRC := int64(0)
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case SlotWinOpen:
			return 7 // the kernel hands back a recycled id
		case SlotWinClose:
			return closeRC
		}
		return -ErrENOSYS
	})
	t.Cleanup(func() { SetSyscallHookForTest(prev) })

	setWmToken(7, 0xdeadbeef)
	id, rc := WinOpen(0, 0, 8, 8)
	if id != 7 || rc < 0 {
		t.Fatalf("WinOpen = (%d, %d) want (7, >=0)", id, rc)
	}
	if got := wmToken(7); got != 0 {
		t.Fatalf("recycled id kept the dead window's token %#x", got)
	}

	setWmToken(7, 0xfeedface)
	if rc := WinClose(7); rc != 0 {
		t.Fatalf("WinClose = %d want 0", rc)
	}
	if got := wmToken(7); got != 0 {
		t.Fatalf("closed window kept its token %#x", got)
	}

	// A refused close leaves the window — and its binding — alive.
	setWmToken(7, 0xf00d)
	closeRC = -ErrEINVAL
	if rc := WinClose(7); rc != -ErrEINVAL {
		t.Fatalf("refused WinClose = %d want -EINVAL", rc)
	}
	if got := wmToken(7); got != 0xf00d {
		t.Fatalf("refused close dropped the live binding's token %#x", got)
	}
}

// #2260: a momentarily-full seat mailbox (ENOSPC from slot 5) is transient —
// the ring drains once per composite pass — so the send retries a few ticks
// instead of refusing a servable request outright.
func TestWmSendRetriesFullMailbox(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	const challenge = uint64(0x00deadbeef00cafe)
	const token = uint64(0x0123456789abcdef)
	f.replyFn = func(req WmRpc) []byte {
		rep := WmRpc{Kind: req.Kind | WmRpcReplyFlag, ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo}
		switch WmAuth(req) {
		case 0:
			rep.Pad = WmRpcPadChallenge
			SetWmAuth(&rep, challenge)
		case challenge, token:
			rep.Pad = WmRpcPadBound
			SetWmAuth(&rep, token)
			rep.Applied = 1
		default:
			return nil
		}
		return rep.Encode()
	}
	prev := bindSetTitle
	bindSetTitle = func(id int, s string) int64 { return 0 }
	t.Cleanup(func() { bindSetTitle = prev })

	f.sendENOSPC = 2 // the first two sends hit a full ring
	if !Notify(4, "copied KNOWN.TXT", "NOTE.ELF") {
		t.Fatal("a transiently full seat mailbox must retry, not refuse")
	}
	if f.sendCalls != 4 {
		t.Fatalf("send calls = %d want 4 (2 ENOSPC + unbound + echo)", f.sendCalls)
	}
	if len(f.sent) != 2 {
		t.Fatalf("delivered frames = %d want 2 (refused sends did not land)", len(f.sent))
	}
	if f.sleepCalls != 2 {
		t.Fatalf("ENOSPC retries parked %d ticks, want 2 (one per resend)", f.sleepCalls)
	}
}

// A ring that stays full still refuses — the retry is a bounded courtesy,
// not an unbounded block.
func TestWmSendGivesUpAfterBound(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	f.sendENOSPC = 99
	if Notify(4, "copied KNOWN.TXT", "NOTE.ELF") {
		t.Fatal("a permanently full mailbox must still refuse")
	}
	if f.sendCalls != wmSendRetries+1 {
		t.Fatalf("send calls = %d want %d (bounded retry then give up)",
			f.sendCalls, wmSendRetries+1)
	}
	if len(f.sent) != 0 {
		t.Fatalf("refused sends reached the wire: %d frames", len(f.sent))
	}
}
