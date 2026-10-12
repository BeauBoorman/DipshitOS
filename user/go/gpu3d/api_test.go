package gpu3d

import (
	"context"
	"errors"
	"testing"
	"time"

	"virelai/vi"
)

// fakeTransport is the injected seam: it counts calls, captures each
// request, and answers from a script. The genuine-session shape is a
// bound ack quoting the window's session token — the same shape the vi
// exchange returns.
type fakeTransport struct {
	calls   int
	win     uint32
	op      uint8
	payload [PayloadBytes]byte
	token   uint64
	// reply builds the ack for the last captured request (nil = the
	// transport errors / never replies, per block/replyErr).
	reply    func(req vi.WmRpc) vi.WmRpc
	replyErr error
	// block parks inside Exchange until ctx ends (deadline tests).
	block bool
	// inside closes when Exchange is entered (concurrency tests).
	inside chan struct{}
}

func (f *fakeTransport) Exchange(ctx context.Context, windowID uint32, op uint8, payload [PayloadBytes]byte) (Trip, error) {
	f.calls++
	f.win, f.op, f.payload = windowID, op, payload
	if f.inside != nil {
		select {
		case f.inside <- struct{}{}:
		default:
		}
	}
	if f.block {
		<-ctx.Done()
		return Trip{}, ctx.Err()
	}
	if f.replyErr != nil {
		return Trip{}, f.replyErr
	}
	req := vi.WmRpc{Kind: Kind, ID: uint8(windowID), Seq: uint8(f.calls), ReplyTo: 9,
		Applied: op, Pad: vi.WmRpcPadBound, Title: payload}
	vi.SetWmAuth(&req, f.token)
	var ack vi.WmRpc
	if f.reply != nil {
		ack = f.reply(req)
	}
	return Trip{Req: req, Ack: ack, Token: f.token}, nil
}

// newFake returns a transport bound to token tok whose default reply is
// the honest applied ack quoting that token.
func newFake(tok uint64) *fakeTransport {
	f := &fakeTransport{token: tok}
	f.reply = func(req vi.WmRpc) vi.WmRpc {
		ack := vi.WmRpc{Kind: Kind | vi.WmRpcReplyFlag, ID: req.ID, Seq: req.Seq,
			ReplyTo: req.ReplyTo, Applied: 1, Pad: vi.WmRpcPadBound,
			Title: EncodeReply(StatusOK, false, 1)}
		vi.SetWmAuth(&ack, tok)
		return ack
	}
	return f
}

func mustOpen(t *testing.T, f *fakeTransport) *Client {
	t.Helper()
	c, err := OpenTransport(f, 4, 256, 192)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	return c
}

// --- geometry / argument admission: refused before the transport ------

// The no-send bound test (the revert-fails bounds target): out-of-cap
// geometry must refuse with ErrInvalid and ZERO transport calls.
func TestOpenRefusesOverCapBeforeTransport(t *testing.T) {
	for _, tc := range []struct {
		name string
		win  uint32
		w, h uint32
	}{
		{"window zero", 0, 64, 64},
		{"window wide", 0x100, 64, 64},
		{"width zero", 4, 0, 64},
		{"width over cap", 4, 257, 64},
		{"height zero", 4, 64, 0},
		{"height over cap", 4, 64, 193},
	} {
		f := newFake(1)
		if _, err := OpenTransport(f, tc.win, tc.w, tc.h); err != ErrInvalid {
			t.Fatalf("%s: open err = %v want ErrInvalid", tc.name, err)
		}
		if f.calls != 0 {
			t.Fatalf("%s: invalid geometry reached the transport (%d calls)", tc.name, f.calls)
		}
	}
}

func TestOpenSendsCreateOp(t *testing.T) {
	f := newFake(1)
	c := mustOpen(t, f)
	defer c.Close()
	if f.calls != 1 || f.op != OpOpen || f.win != 4 {
		t.Fatalf("open sent calls=%d op=%d win=%d", f.calls, f.op, f.win)
	}
	want := PayloadOpen(256, 192)
	if f.payload != want {
		t.Fatalf("open payload = %v want %v", f.payload, want)
	}
}

func TestClearRefusesHighByteBeforeTransport(t *testing.T) {
	f := newFake(1)
	c := mustOpen(t, f)
	calls := f.calls
	if err := c.Clear(0x01000000); err != ErrInvalid {
		t.Fatalf("clear high byte = %v want ErrInvalid", err)
	}
	if f.calls != calls {
		t.Fatal("a wide rgb reached the transport")
	}
	if err := c.Clear(0x00FF00FF); err != nil {
		t.Fatalf("clear: %v", err)
	}
}

// --- one outstanding request ------------------------------------------

func TestConcurrentCallGetsBusyWithoutTransport(t *testing.T) {
	openFake := newFake(1)
	c := mustOpen(t, openFake)
	c.Deadline = 60 * time.Millisecond

	f := newFake(0xC0FFEE)
	f.block = true
	f.inside = make(chan struct{}, 1)
	c.tr = f

	done := make(chan error, 1)
	go func() { done <- c.Present() }()
	<-f.inside // the first request is genuinely outstanding
	if err := c.Clear(1); err != ErrBusy {
		t.Fatalf("second outstanding = %v want ErrBusy", err)
	}
	if f.calls != 1 {
		t.Fatalf("the refused call reached the transport: %d calls", f.calls)
	}
	if err := <-done; !errors.Is(err, ErrTimeout) {
		t.Fatalf("blocked present err = %v want ErrTimeout", err)
	}
}

// --- ack validation: kind / window / sequence / token ------------------

// The forged-ack bound test (the revert-fails auth target): an ack whose
// token does not quote the session token must never satisfy the request.
func TestForgedAckCannotSucceed(t *testing.T) {
	f := newFake(0xC0FFEE)
	f.reply = func(req vi.WmRpc) vi.WmRpc {
		ack := vi.WmRpc{Kind: Kind | vi.WmRpcReplyFlag, ID: req.ID, Seq: req.Seq,
			ReplyTo: req.ReplyTo, Applied: 1, Pad: vi.WmRpcPadBound,
			Title: EncodeReply(StatusOK, false, 1)}
		vi.SetWmAuth(&ack, 0xBADBAD) // the attacker's guess, not the session token
		return ack
	}
	if _, err := OpenTransport(f, 4, 64, 64); err != ErrProtocol {
		t.Fatalf("forged-token ack open = %v want ErrProtocol", err)
	}
}

func TestValidAckControlPasses(t *testing.T) {
	f := newFake(0xC0FFEE)
	if _, err := OpenTransport(f, 4, 64, 64); err != nil {
		t.Fatalf("valid-ack control open = %v want nil", err)
	}
}

// Wrong kind / window / sequence are the rest of the forged shapes.
func TestMismatchedAckFieldsCannotSucceed(t *testing.T) {
	mutate := []struct {
		name string
		m    func(*vi.WmRpc)
	}{
		{"wrong kind", func(a *vi.WmRpc) { a.Kind = 11 | vi.WmRpcReplyFlag }},
		{"no reply flag", func(a *vi.WmRpc) { a.Kind = Kind }},
		{"wrong window", func(a *vi.WmRpc) { a.ID++ }},
		{"wrong seq", func(a *vi.WmRpc) { a.Seq++ }},
		{"wrong requester", func(a *vi.WmRpc) { a.ReplyTo++ }},
		{"plain pad", func(a *vi.WmRpc) { a.Pad = vi.WmRpcPadPlain }},
	}
	for _, tc := range mutate {
		f := newFake(0xC0FFEE)
		f.reply = func(req vi.WmRpc) vi.WmRpc {
			ack := vi.WmRpc{Kind: Kind | vi.WmRpcReplyFlag, ID: req.ID, Seq: req.Seq,
				ReplyTo: req.ReplyTo, Applied: 1, Pad: vi.WmRpcPadBound,
				Title: EncodeReply(StatusOK, false, 1)}
			vi.SetWmAuth(&ack, 0xC0FFEE)
			tc.m(&ack)
			return ack
		}
		if _, err := OpenTransport(f, 4, 64, 64); err != ErrProtocol {
			t.Fatalf("%s: open = %v want ErrProtocol", tc.name, err)
		}
	}

	// A zero session token can never authenticate an ack.
	f := newFake(0)
	if _, err := OpenTransport(f, 4, 64, 64); err != ErrProtocol {
		t.Fatalf("zero-token ack open = %v want ErrProtocol", err)
	}
}

func TestReplyReservedTailRejected(t *testing.T) {
	f := newFake(0xC0FFEE)
	f.reply = func(req vi.WmRpc) vi.WmRpc {
		ack := vi.WmRpc{Kind: Kind | vi.WmRpcReplyFlag, ID: req.ID, Seq: req.Seq,
			ReplyTo: req.ReplyTo, Applied: 1, Pad: vi.WmRpcPadBound}
		vi.SetWmAuth(&ack, 0xC0FFEE)
		ack.Title = EncodeReply(StatusOK, false, 0)
		ack.Title[10] = 1 // nonzero reserved reply byte
		return ack
	}
	if _, err := OpenTransport(f, 4, 64, 64); err != ErrProtocol {
		t.Fatalf("reserved-tail ack open = %v want ErrProtocol", err)
	}
}

// --- distinct outcomes -------------------------------------------------

func TestStatusBytesStayDistinct(t *testing.T) {
	cases := []struct {
		status uint8
		want   error
	}{
		{StatusInvalid, ErrInvalid},
		{StatusBadHandle, ErrBadHandle},
		{StatusExhausted, ErrExhausted},
		{StatusLostContext, ErrLostContext},
		{StatusUnsupported, ErrUnsupported},
		{StatusPending, ErrPending},
		{StatusTimeout, ErrTimeout},
		{StatusDeviceFault, ErrDeviceFault},
		{0x7F, ErrProtocol}, // an unassigned status is a protocol violation
	}
	for _, tc := range cases {
		f := newFake(0xC0FFEE)
		st := tc.status
		f.reply = func(req vi.WmRpc) vi.WmRpc {
			ack := vi.WmRpc{Kind: Kind | vi.WmRpcReplyFlag, ID: req.ID, Seq: req.Seq,
				ReplyTo: req.ReplyTo, Applied: 1, Pad: vi.WmRpcPadBound,
				Title: EncodeReply(st, false, 0)}
			vi.SetWmAuth(&ack, 0xC0FFEE)
			return ack
		}
		if _, err := OpenTransport(f, 4, 64, 64); err != tc.want {
			t.Fatalf("status %d: open err = %v want %v", st, err, tc.want)
		}
	}
}

func TestRefusedAckIsNamed(t *testing.T) {
	f := newFake(0xC0FFEE)
	f.reply = func(req vi.WmRpc) vi.WmRpc {
		ack := vi.WmRpc{Kind: Kind | vi.WmRpcReplyFlag, ID: req.ID, Seq: req.Seq,
			ReplyTo: req.ReplyTo, Applied: 0, Pad: vi.WmRpcPadBound,
			Title: EncodeReply(StatusUnsupported, false, 0)}
		vi.SetWmAuth(&ack, 0xC0FFEE)
		return ack
	}
	if _, err := OpenTransport(f, 4, 64, 64); err != ErrUnsupported {
		t.Fatalf("applied=0 ENXIO open = %v want ErrUnsupported", err)
	}
	f.replyErr = errors.New("no seat")
	if _, err := OpenTransport(f, 4, 64, 64); err == nil {
		t.Fatal("transport error must surface")
	}
}

// --- the six operations ------------------------------------------------

func TestTriangleSendsExactVertices(t *testing.T) {
	f := newFake(0xC0FFEE)
	c := mustOpen(t, f)
	defer c.Close()
	verts := [3]Vertex{
		{X: -1, Y: 1, Z: 2, RGB: 3},
		{X: -4, Y: 5, Z: 6, RGB: 7},
		{X: -8, Y: 9, Z: 10, RGB: 11},
	}
	if err := c.Triangle(verts); err != nil {
		t.Fatalf("triangle: %v", err)
	}
	if f.op != OpTriangle || f.payload != PayloadTriangle(verts) {
		t.Fatalf("triangle sent op=%d payload=%v", f.op, f.payload)
	}
	got := [3]Vertex{DecodeVertex(f.payload[0:]), DecodeVertex(f.payload[8:]), DecodeVertex(f.payload[16:])}
	if got != verts {
		t.Fatalf("triangle wire round-trip = %+v want %+v", got, verts)
	}
}

func TestPresentAndPollAndClose(t *testing.T) {
	f := newFake(0xC0FFEE)
	c := mustOpen(t, f)
	if err := c.Present(); err != nil {
		t.Fatalf("present: %v", err)
	}
	if f.op != OpPresent || f.payload != [PayloadBytes]byte{} {
		t.Fatalf("present sent op=%d payload=%v", f.op, f.payload)
	}

	// Pending first, staged on the second poll.
	staged := false
	f.reply = func(req vi.WmRpc) vi.WmRpc {
		ack := vi.WmRpc{Kind: Kind | vi.WmRpcReplyFlag, ID: req.ID, Seq: req.Seq,
			ReplyTo: req.ReplyTo, Applied: 1, Pad: vi.WmRpcPadBound,
			Title: EncodeReply(StatusOK, staged, 7)}
		vi.SetWmAuth(&ack, 0xC0FFEE)
		return ack
	}
	if ok, err := c.Poll(); ok || err != ErrPending {
		t.Fatalf("pending poll = (%v, %v) want (false, ErrPending)", ok, err)
	}
	staged = true
	if ok, err := c.Poll(); !ok || err != nil {
		t.Fatalf("staged poll = (%v, %v) want (true, nil)", ok, err)
	}

	if err := c.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	if f.op != OpClose {
		t.Fatalf("close sent op=%d want %d", f.op, OpClose)
	}
	if err := c.Close(); err != nil {
		t.Fatalf("second close = %v want nil", err)
	}
	if err := c.Present(); err != ErrClosed {
		t.Fatalf("post-close present = %v want ErrClosed", err)
	}
}

// --- the deadline -------------------------------------------------------

func TestDeadlineBoundsTheExchange(t *testing.T) {
	openFake := newFake(0xC0FFEE)
	c := mustOpen(t, openFake)

	f := newFake(0xC0FFEE)
	f.block = true
	c.tr = f
	c.Deadline = 40 * time.Millisecond
	start := time.Now()
	if err := c.Present(); err != ErrTimeout {
		t.Fatalf("blocked present = %v want ErrTimeout", err)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("the deadline did not bound the exchange: %v", elapsed)
	}
}
