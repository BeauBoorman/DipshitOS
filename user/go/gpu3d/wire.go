// Package gpu3d is the app-facing client for the experimental virtio-3D
// render channel (M102 index, issue #2160; this card #2167). Apps get
// exactly six operations — Open/Clear/Triangle/Present/Poll/Close — over
// the authenticated WM_RPC kind-17 seam; no GL or Vulkan surface, no raw
// command streams, no GPU addresses and no resource IDs ever escape to
// the app.
//
// This file pins the kind-17 wire contract, which d2 owns: the opcode
// rides the frame's `Applied` field, Title[24] carries the binary
// payload, and the x/y/w/h union keeps the existing M97 binding/token.
// The seat side of these codecs is the same code — DecodeRequest is how
// the WM validates an incoming frame.
package gpu3d

import "virelai/vi"

// Kind is the WM_RPC kind reserved for GPU3D requests (index #2160 S6).
const Kind = vi.WmRpcKindGpu3d

// The request opcodes, carried in the frame's `Applied` field. They are
// the app's six operations in contract order; the kernel bridge's
// seat-internal PUBLISH op has no app-side opcode.
const (
	OpOpen     uint8 = 1 // payload: u32 width, u32 height
	OpClear    uint8 = 2 // payload: u32 rgb (0x00RRGGBB)
	OpTriangle uint8 = 3 // payload: three 8-byte vertices
	OpPresent  uint8 = 4 // payload: none (all zero)
	OpPoll     uint8 = 5 // payload: none
	OpClose    uint8 = 6 // payload: none
)

const (
	// PayloadBytes is the Title[24] binary-payload budget.
	PayloadBytes = vi.WmRpcTitleMax
	// VertexBytes is the frozen wire vertex width.
	VertexBytes = 8
	// MaxWidth/MaxHeight bound the render extent (the private VIR1
	// capability profile).
	MaxWidth  uint32 = 256
	MaxHeight uint32 = 192
)

// The reply status byte (reply Title[0]): the kernel's errno magnitudes,
// so a refusal names the same condition end to end and pending,
// unsupported, invalid, exhausted, timeout and lost-context never
// collapse into each other.
const (
	StatusOK          uint8 = 0
	StatusInvalid     uint8 = 1  // EINVAL — malformed request/foreign field
	StatusBadHandle   uint8 = 2  // EBADF — stale context handle
	StatusExhausted   uint8 = 5  // ENOSPC — context pool full
	StatusLostContext uint8 = 6  // ENOENT — quarantined session
	StatusUnsupported uint8 = 9  // ENXIO — no VIR1 device / feature
	StatusPending     uint8 = 11 // EAGAIN — frame/device pending
	StatusTimeout     uint8 = 12 // ETIMEDOUT — device deadline
	StatusDeviceFault uint8 = 13 // EIO — protocol/submission fault
)

// Vertex is the app-side vertex: exactly 8 wire bytes — signed LE i16
// normalized X/Y, LE u16 normalized Z (0..1), LE u16 RGB565.
type Vertex struct {
	X, Y int16
	Z    uint16
	RGB  uint16
}

func putU16(b []byte, v uint16) { b[0], b[1] = byte(v), byte(v>>8) }
func getU16(b []byte) uint16    { return uint16(b[0]) | uint16(b[1])<<8 }
func putU32(b []byte, v uint32) {
	b[0], b[1], b[2], b[3] = byte(v), byte(v>>8), byte(v>>16), byte(v>>24)
}
func getU32(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}

// EncodeVertex writes v into out[0..8).
func (v Vertex) EncodeVertex(out []byte) {
	putU16(out[0:], uint16(v.X))
	putU16(out[2:], uint16(v.Y))
	putU16(out[4:], v.Z)
	putU16(out[6:], v.RGB)
}

// DecodeVertex reads one 8-byte wire vertex.
func DecodeVertex(b []byte) Vertex {
	return Vertex{
		X:   int16(getU16(b[0:])),
		Y:   int16(getU16(b[2:])),
		Z:   getU16(b[4:]),
		RGB: getU16(b[6:]),
	}
}

// PayloadOpen builds the OPEN payload: u32 width@0, u32 height@4, the
// remaining 16 bytes zero.
func PayloadOpen(w, h uint32) [PayloadBytes]byte {
	var p [PayloadBytes]byte
	putU32(p[0:], w)
	putU32(p[4:], h)
	return p
}

// PayloadClear builds the CLEAR payload: u32 0x00RRGGBB@0, rest zero.
func PayloadClear(rgb uint32) [PayloadBytes]byte {
	var p [PayloadBytes]byte
	putU32(p[0:], rgb)
	return p
}

// PayloadTriangle builds the TRIANGLE payload: exactly the three 8-byte
// wire vertices, filling the whole budget.
func PayloadTriangle(v [3]Vertex) [PayloadBytes]byte {
	var p [PayloadBytes]byte
	for i := range v {
		v[i].EncodeVertex(p[i*VertexBytes:])
	}
	return p
}

// PayloadEmpty is the all-zero payload PRESENT/POLL/CLOSE carry.
func PayloadEmpty() [PayloadBytes]byte { return [PayloadBytes]byte{} }

// zeroTail reports whether b is all zero — the reserved-byte rule every
// fixed-field payload keeps.
func zeroTail(b []byte) bool {
	for _, c := range b {
		if c != 0 {
			return false
		}
	}
	return true
}

// Request is one decoded kind-17 request: the opcode and its typed
// fields. Fields that do not belong to the opcode stay zero — the wire
// requires them zero, so a nonzero value never reaches here.
type Request struct {
	Op    uint8
	W, H  uint32    // OPEN render extent
	RGB   uint32    // CLEAR 0x00RRGGBB
	Verts [3]Vertex // TRIANGLE
}

// DecodeRequest validates one kind-17 request frame (the seat's side of
// the contract): the kind must be 17 with no reply flag, the opcode must
// be one of the six, and every payload byte outside the op's own fields
// must be zero. A violated rule is an error, never a silent read.
func DecodeRequest(m vi.WmRpc) (Request, error) {
	if m.Kind != Kind || m.Kind&vi.WmRpcReplyFlag != 0 {
		return Request{}, errWire
	}
	p := m.Title
	switch m.Applied {
	case OpOpen:
		if !zeroTail(p[8:]) {
			return Request{}, errWire
		}
		return Request{Op: OpOpen, W: getU32(p[0:]), H: getU32(p[4:])}, nil
	case OpClear:
		if !zeroTail(p[4:]) || p[3] != 0 {
			return Request{}, errWire
		}
		return Request{Op: OpClear, RGB: getU32(p[0:])}, nil
	case OpTriangle:
		var v [3]Vertex
		for i := range v {
			v[i] = DecodeVertex(p[i*VertexBytes:])
		}
		return Request{Op: OpTriangle, Verts: v}, nil
	case OpPresent, OpPoll, OpClose:
		if !zeroTail(p[:]) {
			return Request{}, errWire
		}
		return Request{Op: m.Applied}, nil
	default:
		return Request{}, errWire
	}
}

// Reply is the kind-17 ack payload (reply Title[24]):
//
//	@0  u8   status — 0 applied, else an errno magnitude above
//	@1  u8   staged — POLL replies: 1 when a completed frame is staged
//	@2  u32  frame  — the seat's count of applied PRESENT ops for this
//	                 window (the app's staleness oracle; seat-minted)
//	@6  18B  reserved — always zero
type Reply struct {
	Status uint8
	Staged bool
	Frame  uint32
}

// EncodeReply builds the reply Title bytes for status/staged/frame with
// the reserved tail zero (the seat's side).
func EncodeReply(status uint8, staged bool, frame uint32) [PayloadBytes]byte {
	var p [PayloadBytes]byte
	p[0] = status
	if staged {
		p[1] = 1
	}
	putU32(p[2:], frame)
	return p
}

// DecodeReply parses a reply Title, refusing a nonzero reserved tail.
func DecodeReply(title [PayloadBytes]byte) (Reply, error) {
	if !zeroTail(title[6:]) {
		return Reply{}, errWire
	}
	return Reply{Status: title[0], Staged: title[1] != 0, Frame: getU32(title[2:])}, nil
}
