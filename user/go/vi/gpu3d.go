package vi

import "unsafe"

// M102d2 (issue #2167): the GPU3D seam in both directions the SDK owns.
//
// SEAT SIDE: slot-65 cmd 22 carries ONE frozen 64-byte typed descriptor
// (ADR 0007, M102d1 #2166). Only the registered seat may call it; the
// kernel copies the descriptor through checked uaccess before any device
// action, so the bytes MUST live in a mapped page — the same convention
// WmctlSetWindowChrome already follows (ADR 0026 D8: a Go stack pointer
// is not guaranteed mapped for EL1). Callers MmapHint a page, EncodeDesc
// into it, and pass the slice.
//
// APP SIDE: WM_RPC kind 17 is the authenticated app -> seat request. The
// private request format puts the operation in `Applied` and the binary
// payload in Title[24]; X/Y/W/H keep the M97 auth union exactly as every
// other bound kind. The exchange below rides the SAME challenge/token
// seam as wmclient.go — kind 17 has no legacy-seat path and never sends
// an unauthenticated frame.

// ---------------------------------------------------------------------------
// Seat side — the frozen 64-byte cmd-22 descriptor.
// ---------------------------------------------------------------------------

const (
	// WmctlGpu3dCmd is slot-65 subcommand 22 (ADR 0007, M102d1).
	WmctlGpu3dCmd uint64 = 22
	// Gpu3dDescBytes is the frozen descriptor wire length; the kernel
	// refuses any other `len`.
	Gpu3dDescBytes = 64

	// The seven broker operations (gpu3d_broker.zig). 0 and >=8 fail closed.
	Gpu3dOpCreate   uint32 = 1
	Gpu3dOpClear    uint32 = 2
	Gpu3dOpTriangle uint32 = 3
	Gpu3dOpPresent  uint32 = 4
	Gpu3dOpPoll     uint32 = 5
	Gpu3dOpPublish  uint32 = 6
	Gpu3dOpClose    uint32 = 7

	// Gpu3dMaxWidth/Gpu3dMaxHeight bound the CREATE render extent (the
	// private VIR1 capability profile, index #2160 S2/S3).
	Gpu3dMaxWidth  uint32 = 256
	Gpu3dMaxHeight uint32 = 192
)

// Gpu3dVertex is one wire vertex: 8 bytes little-endian, i16 normalized
// X/Y, u16 normalized Z, u16 RGB565 (index #2160 S5).
type Gpu3dVertex struct {
	X, Y int16
	Z    uint16
	RGB  uint16
}

// Gpu3dDesc is the typed form of the cmd-22 descriptor:
//
//	off  size  field
//	0    4     op         1..7
//	4    4     flags      always 0 — the struct has no field for it
//	8    8     handle     gen:48<<16 | ctx:16; CREATE 0, others verbatim
//	16   4     window_id  the bound user window (1..255), every op
//	20   4     width      CREATE extent / PUBLISH captured width; else 0
//	24   4     height     same rule as width
//	28   4     rgb        CLEAR 0x00RRGGBB; else 0
//	32   24    verts      TRIANGLE's three wire vertices; else zero
//	56   8     reserved   always 0 — no field, cannot be expressed
//
// Every field not listed for an op must be zero; EncodeDesc refuses a
// descriptor that breaks the per-op discipline rather than emitting a
// malformed frame the kernel would only reject.
type Gpu3dDesc struct {
	Op       uint32
	Handle   uint64
	WindowID uint32
	Width    uint32
	Height   uint32
	RGB      uint32
	Verts    [3]Gpu3dVertex
}

// check enforces the per-op field rules of the ADR table: a nonzero
// foreign field, an out-of-bounds extent, a missing/extra handle or an
// unknown op is an error BEFORE the descriptor exists, never a silent
// zeroing.
func (d Gpu3dDesc) check() error {
	if d.WindowID == 0 || d.WindowID > 0xff {
		return errno(ErrEINVAL)
	}
	vertsZero := d.Verts == [3]Gpu3dVertex{}
	switch d.Op {
	case Gpu3dOpCreate:
		if d.Handle != 0 || d.RGB != 0 || !vertsZero {
			return errno(ErrEINVAL)
		}
		if d.Width == 0 || d.Width > Gpu3dMaxWidth ||
			d.Height == 0 || d.Height > Gpu3dMaxHeight {
			return errno(ErrEINVAL)
		}
	case Gpu3dOpClear:
		if d.Handle == 0 || d.Width != 0 || d.Height != 0 ||
			d.RGB > 0xffffff || !vertsZero {
			return errno(ErrEINVAL)
		}
	case Gpu3dOpTriangle:
		if d.Handle == 0 || d.Width != 0 || d.Height != 0 || d.RGB != 0 {
			return errno(ErrEINVAL)
		}
	case Gpu3dOpPresent, Gpu3dOpPoll, Gpu3dOpClose:
		if d.Handle == 0 || d.Width != 0 || d.Height != 0 ||
			d.RGB != 0 || !vertsZero {
			return errno(ErrEINVAL)
		}
	case Gpu3dOpPublish:
		if d.Handle == 0 || d.Width == 0 || d.Height == 0 ||
			d.RGB != 0 || !vertsZero {
			return errno(ErrEINVAL)
		}
	default:
		return errno(ErrEINVAL)
	}
	return nil
}

// EncodeDesc validates d and writes it little-endian into out[64]. The
// flags and reserved words are emitted as zero by construction. out is
// the caller's mapped staging slice — nothing here takes a Go stack
// pointer for the kernel.
func (d Gpu3dDesc) EncodeDesc(out []byte) error {
	if len(out) < Gpu3dDescBytes {
		return errno(ErrEINVAL)
	}
	if err := d.check(); err != nil {
		return err
	}
	for i := 0; i < Gpu3dDescBytes; i++ {
		out[i] = 0
	}
	putU32(out[0:], d.Op)
	putU64(out[8:], d.Handle)
	putU32(out[16:], d.WindowID)
	putU32(out[20:], d.Width)
	putU32(out[24:], d.Height)
	putU32(out[28:], d.RGB)
	for i, v := range d.Verts {
		o := 32 + 8*i
		putU16(out[o:], uint16(v.X))
		putU16(out[o+2:], uint16(v.Y))
		putU16(out[o+4:], v.Z)
		putU16(out[o+6:], v.RGB)
	}
	return nil
}

// gpu3dSyscall is the svc gateway for the descriptor call; host tests
// stub it to pin the argument shape (the four-arg syscallHook cannot see
// a six-arg call).
var gpu3dSyscall = syscall6

// WmctlGpu3d submits one encoded descriptor (slot 65 cmd 22). desc MUST be
// exactly 64 bytes living in a mapped page (MmapHint) — the kernel reads
// it through checked uaccess and a bad pointer is -EFAULT. a0..a2 are
// reserved-zero per the ADR call contract. Returns the op result: a
// generation-bearing handle on CREATE, 1/0 staged on POLL, 0 on the rest,
// or the negative errno (ENOSYS/EACCES/EFAULT/EINVAL/EBADF/ENOSPC/ENXIO/
// EAGAIN/ETIMEDOUT/ENOENT/EIO).
func WmctlGpu3d(desc []byte) int64 {
	if len(desc) != Gpu3dDescBytes {
		return -ErrEINVAL
	}
	return gpu3dSyscall(SlotWmctl, uintptr(WmctlGpu3dCmd), 0, 0, 0,
		uintptr(unsafe.Pointer(&desc[0])), uintptr(Gpu3dDescBytes))
}

// ---------------------------------------------------------------------------
// App side — the authenticated kind-17 exchange.
// ---------------------------------------------------------------------------

// WmRpcKindGpu3d is the additive WM_RPC kind for GPU3D requests (index
// #2160 S6). It rides the 38-byte frame and the M97 binding unchanged:
// Applied carries the request opcode, Title[24] the binary payload, the
// x/y/w/h union the session token.
const WmRpcKindGpu3d uint8 = 17

// Gpu3dOutcome names how a kind-17 exchange ended, so unsupported and
// timeout surface as distinct failures to the app.
type Gpu3dOutcome int

const (
	// Gpu3dOutcomeOK: a genuine authenticated ack was received.
	Gpu3dOutcomeOK Gpu3dOutcome = iota
	// Gpu3dOutcomeNoSeat: no Go seat is registered, the seat is a legacy
	// Zig seat (kind 17 never rides the unauthenticated bare exchange),
	// or the caller's own pid could not be resolved.
	Gpu3dOutcomeNoSeat
	// Gpu3dOutcomeRefused: the mailbox refused the send.
	Gpu3dOutcomeRefused
	// Gpu3dOutcomeTimeout: no genuine ack arrived inside the bounded
	// wait, or the bind handshake never completed in its round budget.
	Gpu3dOutcomeTimeout
	// Gpu3dOutcomeBadInput: the request was refused before the mailbox
	// (wide window id).
	Gpu3dOutcomeBadInput
)

// Gpu3dExchange sends one authenticated kind-17 request for window id and
// returns the request exactly as it went on the wire (seq, reply_to, pad
// and the auth union filled), the seat's raw ack, and the window's
// session token — the value a genuine kind-17 ack must quote. On
// Gpu3dOutcomeOK the ack already passed the seam's own pad/token check;
// the returned triple exists so the app-side client can re-validate
// kind/window/sequence/token itself. The token is never logged.
func Gpu3dExchange(id uint32, op uint8, payload [WmRpcTitleMax]byte, selfName string) (sent, ack WmRpc, token uint64, outcome Gpu3dOutcome) {
	if !fitsWire8(id) {
		return WmRpc{}, WmRpc{}, 0, Gpu3dOutcomeBadInput
	}
	peers := WmPeers(selfName)
	if peers.WM == 0 || peers.Self == 0 || !fitsWire8(peers.Self) || !peers.Go {
		// Kind 17 exists only on the authenticated Go-seat protocol: a
		// legacy seat gets no request, and no request means no
		// unauthenticated path exists.
		return WmRpc{}, WmRpc{}, 0, Gpu3dOutcomeNoSeat
	}
	return gpu3dRequestGo(uint8(id), op, payload, peers)
}

// gpu3dRequestGo is the kind-17 instance of the M97 authenticated
// exchange (wmRequestGo, wmclient.go): a bound window rides its session
// token, an unbound one walks the ownership challenge first. The
// differences are the contract's own: kind 17, Applied holds the
// opcode, Title[24] holds the binary payload verbatim, and there is no
// string title to restore after the bind proof (the window's kernel
// title returns to empty — apps set their title through the ordinary
// kinds before opening).
func gpu3dRequestGo(id uint8, op uint8, payload [WmRpcTitleMax]byte, peers WmSeat) (sent, ack WmRpc, token uint64, outcome Gpu3dOutcome) {
	for round := 0; round < wmBindMaxRounds; round++ {
		tok := wmToken(id)
		req := WmRpc{Kind: WmRpcKindGpu3d, ID: id, Seq: nextWmSeq(), ReplyTo: uint8(peers.Self), Applied: op}
		copy(req.Title[:], payload[:])
		var accept func(WmRpc) bool
		if tok != 0 {
			req.Pad = WmRpcPadBound
			SetWmAuth(&req, tok)
			// A bound request accepts the token-quoting ack — and a
			// re-challenge, which is how the seat answers a token it no
			// longer holds (a reused window's binding died with the old
			// window). The challenge tail below re-proves and rebinds in
			// the SAME round, exactly as wqPage does; anything else is
			// the forgery shape and is dropped by the wait.
			accept = func(m WmRpc) bool {
				return m.Pad == WmRpcPadChallenge ||
					(m.Pad == WmRpcPadBound && WmAuth(m) == tok)
			}
		} else {
			accept = func(m WmRpc) bool { return m.Pad == WmRpcPadChallenge }
		}
		if IpcSend(peers.WM, req.Encode()) < 0 {
			return WmRpc{}, WmRpc{}, 0, Gpu3dOutcomeRefused
		}
		rep, ok := waitWmRpcAck(req.Seq, req.ReplyTo, accept)
		if !ok {
			if tok != 0 {
				// The seat lost the binding: drop the stale entry and
				// rebind next round, exactly as wmRequestGo does.
				setWmToken(id, 0)
				continue
			}
			return WmRpc{}, WmRpc{}, 0, Gpu3dOutcomeTimeout
		}
		if rep.Pad == WmRpcPadBound {
			return req, rep, wmToken(id), Gpu3dOutcomeOK
		}
		// Challenge: prove ownership through the owner-restricted window
		// title, then resend the request with the challenge echoed.
		challenge := WmAuth(rep)
		if challenge == 0 || bindSetTitle(int(id), WmBindChallengeTitle(challenge, req.ReplyTo)) != 0 {
			return WmRpc{}, WmRpc{}, 0, Gpu3dOutcomeRefused
		}
		req.Seq = nextWmSeq()
		req.Pad = WmRpcPadBound
		SetWmAuth(&req, challenge)
		if IpcSend(peers.WM, req.Encode()) < 0 {
			return WmRpc{}, WmRpc{}, 0, Gpu3dOutcomeRefused
		}
		rep, ok = waitWmRpcAck(req.Seq, req.ReplyTo,
			func(m WmRpc) bool { return m.Pad != WmRpcPadPlain })
		if !ok || rep.Pad != WmRpcPadBound {
			continue // silent or re-challenged: another round
		}
		newToken := WmAuth(rep)
		if newToken == 0 {
			return WmRpc{}, WmRpc{}, 0, Gpu3dOutcomeRefused
		}
		setWmToken(id, newToken)
		// The challenge string is the window's kernel title right now;
		// kind 17 carries no display title, so restore it to empty.
		_ = bindSetTitle(int(id), "")
		return req, rep, newToken, Gpu3dOutcomeOK
	}
	return WmRpc{}, WmRpc{}, 0, Gpu3dOutcomeTimeout
}
