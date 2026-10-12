package gpu3d

// The app-side GPU3D client (M102d2, issue #2167). Six operations and
// nothing else: Open/Clear/Triangle/Present/Poll/Close. One triangle
// replaces the pending frame — no accumulated draw list, no textures, no
// shader handles, no raw streams, no GPU addresses, no resource IDs.
//
// The client owns the kind-17 protocol's app half: it builds each
// request's opcode+payload, drives ONE outstanding request at a time
// under an explicit bounded deadline, and validates the ack's kind,
// window, sequence and session token itself before trusting the reply.
// The transport is injectable; the production one is the authenticated
// vi seam (vi.Gpu3dExchange), which shares the M97 token table with
// every other WM_RPC kind so one window holds one binding.

import (
	"context"
	"errors"
	"sync/atomic"
	"time"

	"virelai/vi"
)

var (
	// The named outcomes the wire's status byte carries. They stay
	// distinct on purpose: a pending frame, an unsupported device, a
	// malformed request, an exhausted pool, a device timeout and a lost
	// context are different facts and the app must be able to tell.
	ErrPending     = errors.New("gpu3d: pending")
	ErrUnsupported = errors.New("gpu3d: unsupported")
	ErrInvalid     = errors.New("gpu3d: invalid")
	ErrExhausted   = errors.New("gpu3d: pool exhausted")
	ErrTimeout     = errors.New("gpu3d: timed out")
	ErrLostContext = errors.New("gpu3d: context lost")
	ErrBadHandle   = errors.New("gpu3d: stale handle")
	ErrDeviceFault = errors.New("gpu3d: device fault")

	// ErrClosed follows a successful Close.
	ErrClosed = errors.New("gpu3d: closed")
	// ErrBusy refuses a second request while one is outstanding; the
	// transport is never touched.
	ErrBusy = errors.New("gpu3d: request in flight")
	// ErrProtocol is an ack that fails kind/window/sequence/token
	// validation or a reply payload with nonzero reserved bytes — the
	// shape a forged or confused frame takes.
	ErrProtocol = errors.New("gpu3d: unauthenticated or malformed ack")
	// ErrRefused is a request the seat refused without a named status.
	ErrRefused = errors.New("gpu3d: request refused")
	// errWire is the codec's malformed-frame refusal.
	errWire = errors.New("gpu3d: malformed frame")
)

// Trip is one transport exchange's record: the request exactly as sent
// (seq/reply_to/pad/auth union filled by the transport), the peer's raw
// ack, and the window's session token the genuine ack must quote.
type Trip struct {
	Req   vi.WmRpc
	Ack   vi.WmRpc
	Token uint64
}

// Transport performs one authenticated kind-17 round-trip for windowID:
// it fills the request's auth fields, sends it, waits for the matching
// ack and returns the triple. The production binding shares the SDK's
// M97 session seam; tests inject a fake. Implementations answer before
// ctx's deadline or keep their own internal bound — the client enforces
// the deadline either way.
type Transport interface {
	Exchange(ctx context.Context, windowID uint32, op uint8, payload [PayloadBytes]byte) (Trip, error)
}

// DefaultDeadline bounds one full exchange, bind round-trips included.
// The M97 ack wait is itself bounded (per-tick parks, never a spin); this
// is the outer, explicit cap an app can tighten on its own client.
const DefaultDeadline = 10 * time.Second

// SelfName is the process-table name the default transport resolves the
// caller's pid with (the same "APP.ELF" name every WM_RPC caller passes
// to WmPeers). Empty derives argv[0]'s basename at Open; set it before
// Open when the exec name and the registered name differ.
var SelfName string

// viTransport is the production binding: the authenticated vi seam. The
// challenge/token handshake, the shared token table and the bounded
// mailbox wait all live there.
type viTransport struct{ self string }

func (t viTransport) Exchange(_ context.Context, windowID uint32, op uint8, payload [PayloadBytes]byte) (Trip, error) {
	sent, ack, token, outcome := vi.Gpu3dExchange(windowID, op, payload, t.self)
	switch outcome {
	case vi.Gpu3dOutcomeOK:
		return Trip{Req: sent, Ack: ack, Token: token}, nil
	case vi.Gpu3dOutcomeTimeout:
		return Trip{}, ErrTimeout
	case vi.Gpu3dOutcomeRefused:
		return Trip{}, ErrRefused
	default:
		return Trip{}, ErrUnsupported
	}
}

func selfName() string {
	if SelfName != "" {
		return SelfName
	}
	args := vi.Args()
	if len(args) == 0 || args[0] == "" {
		return ""
	}
	base := args[0]
	for i := len(base) - 1; i >= 0; i-- {
		if base[i] == '/' || base[i] == '\\' {
			base = base[i+1:]
			break
		}
	}
	return base
}

// Client is one window's GPU3D session: six operations, one outstanding
// request, a bounded deadline on every exchange.
type Client struct {
	tr       Transport
	win      uint32
	inflight atomic.Bool
	closed   atomic.Bool
	// Deadline bounds one exchange; DefaultDeadline when zero.
	Deadline time.Duration
}

// Open binds windowID (1..255) to a render context of extent w×h
// (1..256 × 1..192) over the authenticated seam. An out-of-bounds
// argument is refused before the transport — never clamped.
func Open(windowID uint32, w, h uint32) (*Client, error) {
	return OpenTransport(viTransport{self: selfName()}, windowID, w, h)
}

// OpenTransport is Open over an explicit transport — the host-test and
// custom-binding seam. Same validation, same six methods.
func OpenTransport(tr Transport, windowID uint32, w, h uint32) (*Client, error) {
	if tr == nil || windowID == 0 || windowID > 0xff ||
		w == 0 || w > MaxWidth || h == 0 || h > MaxHeight {
		return nil, ErrInvalid
	}
	c := &Client{tr: tr, win: windowID, Deadline: DefaultDeadline}
	payload := PayloadOpen(w, h)
	if _, err := c.call(OpOpen, payload); err != nil {
		return nil, err
	}
	return c, nil
}

// checkAck re-validates the returned ack against the sent request: kind
// 17 with the reply flag, our window, our sequence, and the bound-session
// pad quoting the window's session token. A mismatch is the forged-ack
// shape and can never succeed.
func checkAck(t Trip) error {
	ack, req := t.Ack, t.Req
	if ack.Kind != Kind|vi.WmRpcReplyFlag ||
		ack.ID != req.ID || ack.Seq != req.Seq || ack.ReplyTo != req.ReplyTo {
		return ErrProtocol
	}
	if t.Token == 0 || ack.Pad != vi.WmRpcPadBound || vi.WmAuth(ack) != t.Token {
		return ErrProtocol
	}
	return nil
}

// statusErr maps the reply's status byte to the named error; 0 and
// EAGAIN both reach the caller distinctly (EAGAIN is ErrPending).
func statusErr(status uint8) error {
	switch status {
	case StatusOK:
		return nil
	case StatusInvalid:
		return ErrInvalid
	case StatusBadHandle:
		return ErrBadHandle
	case StatusExhausted:
		return ErrExhausted
	case StatusLostContext:
		return ErrLostContext
	case StatusUnsupported:
		return ErrUnsupported
	case StatusPending:
		return ErrPending
	case StatusTimeout:
		return ErrTimeout
	case StatusDeviceFault:
		return ErrDeviceFault
	}
	return ErrProtocol
}

// call runs one full op round-trip: admission control, the deadline, the
// exchange, ack validation and the reply decode. Validation failures
// return before the transport is touched.
func (c *Client) call(op uint8, payload [PayloadBytes]byte) (Reply, error) {
	if c.closed.Load() {
		return Reply{}, ErrClosed
	}
	if !c.inflight.CompareAndSwap(false, true) {
		return Reply{}, ErrBusy
	}
	defer c.inflight.Store(false)

	deadline := c.Deadline
	if deadline <= 0 {
		deadline = DefaultDeadline
	}
	ctx, cancel := context.WithTimeout(context.Background(), deadline)
	defer cancel()

	type result struct {
		trip Trip
		err  error
	}
	ch := make(chan result, 1)
	go func() {
		t, err := c.tr.Exchange(ctx, c.win, op, payload)
		ch <- result{t, err}
	}()
	var trip Trip
	select {
	case r := <-ch:
		if r.err != nil {
			if ctx.Err() != nil {
				return Reply{}, ErrTimeout
			}
			return Reply{}, r.err
		}
		trip = r.trip
	case <-ctx.Done():
		return Reply{}, ErrTimeout
	}

	if err := checkAck(trip); err != nil {
		return Reply{}, err
	}
	rep, err := DecodeReply(trip.Ack.Title)
	if err != nil {
		return Reply{}, ErrProtocol
	}
	if trip.Ack.Applied == 0 {
		if e := statusErr(rep.Status); e != nil {
			return Reply{}, e
		}
		return Reply{}, ErrRefused
	}
	return rep, statusErr(rep.Status)
}

// Clear stages rgb (0x00RRGGBB) as the pending frame's clear color; it
// rides the next Present. A value with a nonzero top byte is refused —
// never masked.
func (c *Client) Clear(rgb uint32) error {
	if rgb > 0xffffff {
		return ErrInvalid
	}
	_, err := c.call(OpClear, PayloadClear(rgb))
	return err
}

// Triangle replaces the pending frame's geometry with exactly three wire
// vertices — it never accumulates a draw list.
func (c *Client) Triangle(v [3]Vertex) error {
	_, err := c.call(OpTriangle, PayloadTriangle(v))
	return err
}

// Present submits the staged frame: the seat uploads, submits and waits
// the bounded device completion before the ack.
func (c *Client) Present() error {
	_, err := c.call(OpPresent, PayloadEmpty())
	return err
}

// Poll asks whether the newest completed frame's pixels are staged for
// publication: (true, nil) when staged, ErrPending while the device or
// the seat still owes the readback, and any other named error verbatim.
func (c *Client) Poll() (bool, error) {
	rep, err := c.call(OpPoll, PayloadEmpty())
	if err != nil {
		return false, err
	}
	if !rep.Staged {
		return false, ErrPending
	}
	return true, nil
}

// Close ends the session; it is idempotent. A failed exchange still
// closes the client — the seat/kernel revocation paths (window close,
// owner exit, WM unregister) retire the context regardless.
func (c *Client) Close() error {
	if c.closed.Load() {
		return nil
	}
	_, err := c.call(OpClose, PayloadEmpty())
	if err == ErrClosed || err == ErrBusy {
		return err
	}
	c.closed.Store(true)
	return err
}
