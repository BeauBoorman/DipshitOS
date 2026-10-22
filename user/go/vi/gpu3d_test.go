package vi

import (
	"testing"
	"unsafe"
)

// M102d2 (issue #2167): the seat-side cmd-22 descriptor codec and the
// app-side kind-17 authenticated exchange.

// The frozen 64-byte descriptor (ADR 0007, M102d1) against independent
// byte tables — hand-computed, not derived from the encoder.
func TestGpu3dDescByteTables(t *testing.T) {
	var wantCreate [Gpu3dDescBytes]byte
	wantCreate[0] = 1
	wantCreate[16] = 4
	wantCreate[20] = 0x00 // width 256 LE
	wantCreate[21] = 0x01
	wantCreate[24] = 0xC0 // height 192 LE

	d := Gpu3dDesc{Op: Gpu3dOpCreate, WindowID: 4, Width: 256, Height: 192}
	var out [Gpu3dDescBytes]byte
	if err := d.EncodeDesc(out[:]); err != nil {
		t.Fatalf("create encode: %v", err)
	}
	if out != wantCreate {
		t.Fatalf("create descriptor drift:\ngot  %v\nwant %v", out, wantCreate)
	}

	// CLEAR: handle gen 5 ctx 3 = 0x0005_0003, rgb 0x00A1B2C3.
	var wantClear [Gpu3dDescBytes]byte
	wantClear[0] = 2
	wantClear[8], wantClear[10] = 0x03, 0x05
	wantClear[16] = 4
	wantClear[28], wantClear[29], wantClear[30] = 0xC3, 0xB2, 0xA1

	d = Gpu3dDesc{Op: Gpu3dOpClear, Handle: 0x0005_0003, WindowID: 4, RGB: 0x00A1B2C3}
	if err := d.EncodeDesc(out[:]); err != nil {
		t.Fatalf("clear encode: %v", err)
	}
	if out != wantClear {
		t.Fatalf("clear descriptor drift:\ngot  %v\nwant %v", out, wantClear)
	}

	// TRIANGLE: three wire vertices at @32, i16 x/y, u16 z, u16 rgb565.
	verts := [3]Gpu3dVertex{
		{X: -32768, Y: 32767, Z: 0, RGB: 0xF800},
		{X: 0, Y: 0, Z: 0x8000, RGB: 0x07E0},
		{X: 100, Y: -200, Z: 0xFFFF, RGB: 0x001F},
	}
	var wantTri [Gpu3dDescBytes]byte
	wantTri[0] = 3
	wantTri[8], wantTri[10] = 0x03, 0x05
	wantTri[16] = 4
	// v0: x 0x8000, y 0x7FFF, z 0, rgb 0xF800
	copy(wantTri[32:40], []byte{0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00, 0x00, 0xF8})
	// v1: x 0, y 0, z 0x8000, rgb 0x07E0
	copy(wantTri[40:48], []byte{0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0xE0, 0x07})
	// v2: x 0x0064, y -200 = 0xFF38, z 0xFFFF, rgb 0x001F
	copy(wantTri[48:56], []byte{0x64, 0x00, 0x38, 0xFF, 0xFF, 0xFF, 0x1F, 0x00})

	d = Gpu3dDesc{Op: Gpu3dOpTriangle, Handle: 0x0005_0003, WindowID: 4, Verts: verts}
	if err := d.EncodeDesc(out[:]); err != nil {
		t.Fatalf("triangle encode: %v", err)
	}
	if out != wantTri {
		t.Fatalf("triangle descriptor drift:\ngot  %v\nwant %v", out, wantTri)
	}

	// PUBLISH carries the captured client rect in width/height.
	var wantPub [Gpu3dDescBytes]byte
	wantPub[0] = 6
	wantPub[8], wantPub[10] = 0x03, 0x05
	wantPub[16] = 4
	wantPub[20] = 0x40 // 320 LE
	wantPub[21] = 0x01
	wantPub[24] = 0xC8 // 200 LE

	d = Gpu3dDesc{Op: Gpu3dOpPublish, Handle: 0x0005_0003, WindowID: 4, Width: 320, Height: 200}
	if err := d.EncodeDesc(out[:]); err != nil {
		t.Fatalf("publish encode: %v", err)
	}
	if out != wantPub {
		t.Fatalf("publish descriptor drift:\ngot  %v\nwant %v", out, wantPub)
	}
}

// Every reserved/foreign byte must refuse BEFORE the descriptor exists —
// the encoder has no silent-zero path.
func TestGpu3dDescRejectsMalformed(t *testing.T) {
	var out [Gpu3dDescBytes]byte
	good := Gpu3dDesc{Op: Gpu3dOpCreate, WindowID: 4, Width: 64, Height: 64}
	if err := good.EncodeDesc(out[:]); err != nil {
		t.Fatalf("control encode refused: %v", err)
	}
	cases := []struct {
		name string
		d    Gpu3dDesc
	}{
		{"op zero", Gpu3dDesc{Op: 0, WindowID: 4, Width: 64, Height: 64}},
		{"op past close", Gpu3dDesc{Op: 8, WindowID: 4, Width: 64, Height: 64}},
		{"window zero", Gpu3dDesc{Op: 1, WindowID: 0, Width: 64, Height: 64}},
		{"window wide", Gpu3dDesc{Op: 1, WindowID: 0x100, Width: 64, Height: 64}},
		{"create width cap", Gpu3dDesc{Op: 1, WindowID: 4, Width: 257, Height: 64}},
		{"create height cap", Gpu3dDesc{Op: 1, WindowID: 4, Width: 64, Height: 193}},
		{"create zero extent", Gpu3dDesc{Op: 1, WindowID: 4, Width: 0, Height: 64}},
		{"create handle", Gpu3dDesc{Op: 1, WindowID: 4, Width: 64, Height: 64, Handle: 9}},
		{"create rgb foreign", Gpu3dDesc{Op: 1, WindowID: 4, Width: 64, Height: 64, RGB: 1}},
		{"create verts foreign", Gpu3dDesc{Op: 1, WindowID: 4, Width: 64, Height: 64, Verts: [3]Gpu3dVertex{{X: 1}}}},
		{"clear no handle", Gpu3dDesc{Op: 2, WindowID: 4, RGB: 1}},
		{"clear rgb top byte", Gpu3dDesc{Op: 2, WindowID: 4, Handle: 9, RGB: 0x01000000}},
		{"clear extent foreign", Gpu3dDesc{Op: 2, WindowID: 4, Handle: 9, RGB: 1, Width: 8}},
		{"triangle no handle", Gpu3dDesc{Op: 3, WindowID: 4}},
		{"triangle rgb foreign", Gpu3dDesc{Op: 3, WindowID: 4, Handle: 9, RGB: 1}},
		{"present verts foreign", Gpu3dDesc{Op: 4, WindowID: 4, Handle: 9, Verts: [3]Gpu3dVertex{{Z: 1}}}},
		{"poll no handle", Gpu3dDesc{Op: 5, WindowID: 4}},
		{"publish no extent", Gpu3dDesc{Op: 6, WindowID: 4, Handle: 9}},
		{"publish rgb foreign", Gpu3dDesc{Op: 6, WindowID: 4, Handle: 9, Width: 8, Height: 8, RGB: 1}},
		{"close no handle", Gpu3dDesc{Op: 7, WindowID: 4}},
		{"close width foreign", Gpu3dDesc{Op: 7, WindowID: 4, Handle: 9, Width: 8}},
	}
	for _, tc := range cases {
		if err := tc.d.EncodeDesc(out[:]); err == nil {
			t.Fatalf("%s: malformed descriptor encoded", tc.name)
		}
	}
	if err := good.EncodeDesc(make([]byte, Gpu3dDescBytes-1)); err == nil {
		t.Fatal("short output buffer encoded")
	}
}

// The cmd-22 call contract (ADR 0007): slot 65, cmd 22, a0..a2 reserved
// zero, ptr -> the caller's mapped 64-byte descriptor, len exactly 64.
func TestWmctlGpu3dArgShape(t *testing.T) {
	var got []uintptr
	prev := gpu3dSyscall
	gpu3dSyscall = func(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64 {
		got = []uintptr{num, a0, a1, a2, a3, a4, a5}
		return 0
	}
	t.Cleanup(func() { gpu3dSyscall = prev })

	var desc [Gpu3dDescBytes]byte
	if r := WmctlGpu3d(desc[:]); r != 0 {
		t.Fatalf("wmctl gpu3d = %d want 0", r)
	}
	want := []uintptr{SlotWmctl, uintptr(WmctlGpu3dCmd), 0, 0, 0,
		uintptr(unsafe.Pointer(&desc[0])), Gpu3dDescBytes}
	if len(got) != len(want) {
		t.Fatalf("syscall args = %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("arg %d = %#x want %#x (args %v)", i, got[i], want[i], got)
		}
	}
}

func TestWmctlGpu3dRefusesBadLength(t *testing.T) {
	calls := 0
	prev := gpu3dSyscall
	gpu3dSyscall = func(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64 {
		calls++
		return 0
	}
	t.Cleanup(func() { gpu3dSyscall = prev })
	if r := WmctlGpu3d(make([]byte, Gpu3dDescBytes-1)); r != -ErrEINVAL {
		t.Fatalf("short descriptor = %d want -EINVAL", r)
	}
	if r := WmctlGpu3d(make([]byte, Gpu3dDescBytes+8)); r != -ErrEINVAL {
		t.Fatalf("long descriptor = %d want -EINVAL", r)
	}
	if calls != 0 {
		t.Fatalf("bad lengths reached the syscall: %d calls", calls)
	}
}

// Kind 17 has no legacy path: a Zig seat answers no request and nothing
// is sent — the authenticated protocol is the only protocol.
func TestGpu3dExchangeLegacySeatRefusesBeforeSend(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "TABWM.BIN"
	var payload [WmRpcTitleMax]byte
	_, _, _, outcome := Gpu3dExchange(4, 1, payload, "NOTE.ELF")
	if outcome != Gpu3dOutcomeNoSeat {
		t.Fatalf("legacy-seat outcome = %d want NoSeat", outcome)
	}
	if f.sendCalls != 0 {
		t.Fatalf("legacy seat touched the wire: %d sends", f.sendCalls)
	}
}

func TestGpu3dExchangeHostNoSeat(t *testing.T) {
	var payload [WmRpcTitleMax]byte
	_, _, _, outcome := Gpu3dExchange(4, 1, payload, "NOTE.ELF")
	if outcome != Gpu3dOutcomeNoSeat {
		t.Fatalf("host outcome = %d want NoSeat", outcome)
	}
}

func TestGpu3dExchangeRefusesWideIDBeforePeers(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	var payload [WmRpcTitleMax]byte
	_, _, _, outcome := Gpu3dExchange(0x100, 1, payload, "NOTE.ELF")
	if outcome != Gpu3dOutcomeBadInput {
		t.Fatalf("wide id outcome = %d want BadInput", outcome)
	}
	if f.procsCalls != 0 || f.sendCalls != 0 {
		t.Fatalf("wide id touched the wire: procs=%d send=%d", f.procsCalls, f.sendCalls)
	}
}

// The full authenticated kind-17 round-trip: opcode in Applied, binary
// payload in Title[24], and the M97 challenge/token exchange riding the
// same seam every other bound kind uses.
func TestGpu3dExchangeBindHandshake(t *testing.T) {
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
	var titles []string
	prevBind := bindSetTitle
	bindSetTitle = func(id int, s string) int64 {
		titles = append(titles, s)
		return 0
	}
	t.Cleanup(func() { bindSetTitle = prevBind })

	payload := payload24(64, 48)
	sent, ack, tok, outcome := Gpu3dExchange(4, 1, payload, "NOTE.ELF")
	if outcome != Gpu3dOutcomeOK {
		t.Fatalf("exchange outcome = %d want OK", outcome)
	}
	if len(f.sent) != 2 {
		t.Fatalf("sent %d frames want challenge+echo", len(f.sent))
	}
	if f.sent[0].Kind != WmRpcKindGpu3d || f.sent[0].Applied != 1 ||
		f.sent[0].Pad != WmRpcPadPlain || WmAuth(f.sent[0]) != 0 {
		t.Fatalf("first frame = %+v union=%#x want unbound kind-17 op 1",
			f.sent[0], WmAuth(f.sent[0]))
	}
	if f.sent[0].Title != payload {
		t.Fatalf("payload did not reach Title verbatim: %v want %v", f.sent[0].Title, payload)
	}
	if f.sent[1].Pad != WmRpcPadBound || WmAuth(f.sent[1]) != challenge {
		t.Fatalf("echo frame pad=%d union=%#x want challenge %#x",
			f.sent[1].Pad, WmAuth(f.sent[1]), challenge)
	}
	if sent.Seq != f.sent[1].Seq || ack.Pad != WmRpcPadBound {
		t.Fatalf("returned frames = %+v / %+v want the echo + its bound ack", sent, ack)
	}
	if tok != token {
		t.Fatalf("session token = %#x want %#x", tok, token)
	}
	if len(titles) != 2 || titles[0] != WmBindChallengeTitle(challenge, 9) || titles[1] != "" {
		t.Fatalf("title sets = %v want [challenge, empty]", titles)
	}

	// A bound window's next request rides the token with no handshake.
	sent, _, tok, outcome = Gpu3dExchange(4, 4, [24]byte{}, "NOTE.ELF")
	if outcome != Gpu3dOutcomeOK || tok != token {
		t.Fatalf("bound exchange = (%d, %#x) want (OK, %#x)", outcome, tok, token)
	}
	last := f.sent[len(f.sent)-1]
	if last.Kind != WmRpcKindGpu3d || last.Applied != 4 ||
		last.Pad != WmRpcPadBound || WmAuth(last) != token {
		t.Fatalf("bound frame = %+v union=%#x want token %#x", last, WmAuth(last), token)
	}
	if sent.Title != [24]byte{} {
		t.Fatalf("empty-op payload = %v want zeroed Title", sent.Title)
	}
}

// A bound-window ack quoting a wrong token is consumed and dropped inside
// the wait — the exchange times out honestly, it cannot succeed.
func TestGpu3dExchangeForgedAckCannotSucceed(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	const token = uint64(0x1111222233334444)
	setWmToken(4, token)
	f.replyFn = func(req WmRpc) []byte {
		rep := WmRpc{Kind: req.Kind | WmRpcReplyFlag, ID: req.ID, Seq: req.Seq,
			ReplyTo: req.ReplyTo, Applied: 1, Pad: WmRpcPadBound}
		SetWmAuth(&rep, 0x9999) // the attacker's guess
		return rep.Encode()
	}
	var payload [WmRpcTitleMax]byte
	if _, _, _, outcome := Gpu3dExchange(4, 4, payload, "NOTE.ELF"); outcome != Gpu3dOutcomeTimeout {
		t.Fatalf("forged-ack outcome = %d want Timeout", outcome)
	}
}

// M102 defect #12 (#2236): the live closereuse leg showed the second
// window-lifetime open timing out ~250s — the seat answered the
// stale-token request with a challenge the wait was dropping, so the
// queued bind surfaced only at teardown. A bound kind-17 request that
// draws Pad=Challenge must re-prove and rebind inside the same call.
func TestGpu3dExchangeBoundRechallengeRebinds(t *testing.T) {
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
	prevBind := bindSetTitle
	bindSetTitle = func(id int, s string) int64 {
		titles = append(titles, s)
		return 0
	}
	t.Cleanup(func() { bindSetTitle = prevBind })

	payload := payload24(64, 48)
	sent, ack, tok, outcome := Gpu3dExchange(4, 1, payload, "NOTE.ELF")
	if outcome != Gpu3dOutcomeOK {
		t.Fatalf("re-challenged exchange outcome = %d want OK", outcome)
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
	if sent.Seq != f.sent[1].Seq || ack.Pad != WmRpcPadBound || tok != token {
		t.Fatalf("returned (%+v, %+v, %#x) want echo + bound ack + new token", sent, ack, tok)
	}
	if wmToken(4) != token {
		t.Fatalf("session token = %#x want rebound %#x", wmToken(4), token)
	}
	if len(titles) != 2 || titles[0] != WmBindChallengeTitle(challenge, 9) || titles[1] != "" {
		t.Fatalf("title sets = %v want [challenge, empty]", titles)
	}
	if f.sleepCalls != 0 {
		t.Fatalf("rebind parked %d times — the challenge must answer inline", f.sleepCalls)
	}
}

func TestGpu3dExchangeSilentSeatTimesOut(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	var payload [WmRpcTitleMax]byte
	if _, _, _, outcome := Gpu3dExchange(4, 4, payload, "NOTE.ELF"); outcome != Gpu3dOutcomeTimeout {
		t.Fatalf("silent-seat outcome = %d want Timeout", outcome)
	}
	if f.recvCalls != wmMailWaitTicks || f.sleepCalls != wmMailWaitTicks-1 {
		t.Fatalf("wait = %d probes / %d parks, want bounded %d / %d",
			f.recvCalls, f.sleepCalls, wmMailWaitTicks, wmMailWaitTicks-1)
	}
}

// payload24 builds a kind-17 OPEN-shaped test payload (u32 w, u32 h) for
// the vi-level exchange tests; the app's codec owns the real encoders.
func payload24(w, h uint32) [WmRpcTitleMax]byte {
	var p [WmRpcTitleMax]byte
	putU32(p[0:], w)
	putU32(p[4:], h)
	return p
}
