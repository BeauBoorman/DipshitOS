package gpu3d

import (
	"testing"

	"virelai/vi"
)

// The kind-17 wire contract (index #2160 S6): opcode in Applied, binary
// payload in Title[24], M97 auth union in x/y/w/h. These tables are
// hand-computed — independent of the encoders they pin.

func TestKindIsSeventeen(t *testing.T) {
	if Kind != 17 {
		t.Fatalf("kind = %d want 17", Kind)
	}
	pairs := []struct {
		got, want uint8
	}{
		{OpOpen, 1}, {OpClear, 2}, {OpTriangle, 3},
		{OpPresent, 4}, {OpPoll, 5}, {OpClose, 6},
	}
	for _, p := range pairs {
		if p.got != p.want {
			t.Fatalf("op = %d want %d", p.got, p.want)
		}
	}
	if PayloadBytes != 24 || VertexBytes != 8 || MaxWidth != 256 || MaxHeight != 192 {
		t.Fatalf("bounds drifted: %d %d %d %d", PayloadBytes, VertexBytes, MaxWidth, MaxHeight)
	}
}

func TestVertexWireBytes(t *testing.T) {
	v := Vertex{X: -32768, Y: 32767, Z: 0x1234, RGB: 0xF81F}
	var out [VertexBytes]byte
	v.EncodeVertex(out[:])
	want := [VertexBytes]byte{0x00, 0x80, 0xFF, 0x7F, 0x34, 0x12, 0x1F, 0xF8}
	if out != want {
		t.Fatalf("vertex bytes = %v want %v", out, want)
	}
	if got := DecodeVertex(out[:]); got != v {
		t.Fatalf("vertex round-trip = %+v want %+v", got, v)
	}
}

// Three vertices occupy exactly the 24-byte payload — the fit the frozen
// mailbox was chosen for.
func TestPayloadTriangleThreeVerticesRoundTrip(t *testing.T) {
	verts := [3]Vertex{
		{X: -16384, Y: 16384, Z: 0, RGB: 0xF800},
		{X: 16384, Y: 16384, Z: 0x8000, RGB: 0x07E0},
		{X: 0, Y: -16384, Z: 0xFFFF, RGB: 0x001F},
	}
	p := PayloadTriangle(verts)
	var want [PayloadBytes]byte
	copy(want[0:], []byte{0x00, 0xC0, 0x00, 0x40, 0x00, 0x00, 0x00, 0xF8})
	copy(want[8:], []byte{0x00, 0x40, 0x00, 0x40, 0x00, 0x80, 0xE0, 0x07})
	copy(want[16:], []byte{0x00, 0x00, 0x00, 0xC0, 0xFF, 0xFF, 0x1F, 0x00})
	if p != want {
		t.Fatalf("triangle payload = %v want %v", p, want)
	}
	req, err := DecodeRequest(vi.WmRpc{Kind: Kind, Applied: OpTriangle, Title: p})
	if err != nil || req.Op != OpTriangle || req.Verts != verts {
		t.Fatalf("triangle request = (%+v, %v) want verts %+v", req, err, verts)
	}
}

func TestPayloadByteTables(t *testing.T) {
	var open [PayloadBytes]byte
	open[0], open[1], open[4] = 0x00, 0x01, 0xC0 // w=256, h=192 LE
	if got := PayloadOpen(256, 192); got != open {
		t.Fatalf("open payload = %v want %v", got, open)
	}
	var clear [PayloadBytes]byte
	clear[0], clear[1], clear[2] = 0xC3, 0xB2, 0xA1 // 0x00A1B2C3 LE
	if got := PayloadClear(0x00A1B2C3); got != clear {
		t.Fatalf("clear payload = %v want %v", got, clear)
	}
	if got := PayloadEmpty(); got != [PayloadBytes]byte{} {
		t.Fatalf("empty payload = %v want zeroed", got)
	}
}

// The complete 38-byte request frame against an independent table: kind
// 17, the opcode in Applied, the token in the x/y/w/h union, the binary
// payload in Title.
func TestRequestFrameByteTable(t *testing.T) {
	const token = uint64(0x0badf00d12345678)
	m := vi.WmRpc{Kind: Kind, ID: 4, Seq: 9, ReplyTo: 7, Applied: OpClear, Pad: vi.WmRpcPadBound}
	vi.SetWmAuth(&m, token)
	payload := PayloadClear(0x000000FF)
	copy(m.Title[:], payload[:])
	b := m.Encode()
	if len(b) != 38 {
		t.Fatalf("frame = %d bytes want 38", len(b))
	}
	want := make([]byte, 38)
	want[0], want[1], want[2], want[3] = 17, 4, 9, 7
	want[4], want[5] = OpClear, vi.WmRpcPadBound
	// token LE across x/y/w/h: 78 56 34 12 0d f0 ad 0b
	copy(want[6:14], []byte{0x78, 0x56, 0x34, 0x12, 0x0D, 0xF0, 0xAD, 0x0B})
	want[14], want[15], want[16] = 0xFF, 0x00, 0x00
	if string(b) != string(want) {
		t.Fatalf("request frame = %v want %v", b, want)
	}
}

func TestDecodeRequestRejectsMalformed(t *testing.T) {
	open := PayloadOpen(64, 48)
	cases := []struct {
		name string
		m    vi.WmRpc
	}{
		{"wrong kind", vi.WmRpc{Kind: 11, Applied: OpOpen, Title: open}},
		{"reply flag", vi.WmRpc{Kind: Kind | vi.WmRpcReplyFlag, Applied: OpOpen, Title: open}},
		{"op zero", vi.WmRpc{Kind: Kind, Applied: 0}},
		{"op seven", vi.WmRpc{Kind: Kind, Applied: 7}},
		{"op 255", vi.WmRpc{Kind: Kind, Applied: 0xff}},
	}
	for _, tc := range cases {
		if _, err := DecodeRequest(tc.m); err == nil {
			t.Fatalf("%s: malformed request decoded", tc.name)
		}
	}

	// Reserved payload bytes must be zero.
	bad := open
	bad[9] = 1
	if _, err := DecodeRequest(vi.WmRpc{Kind: Kind, Applied: OpOpen, Title: bad}); err == nil {
		t.Fatal("open with nonzero reserved tail decoded")
	}
	clr := PayloadClear(0x112233)
	clr[3] = 1 // rgb top byte: 0x00RRGGBB only
	if _, err := DecodeRequest(vi.WmRpc{Kind: Kind, Applied: OpClear, Title: clr}); err == nil {
		t.Fatal("clear with nonzero rgb top byte decoded")
	}
	clr[3], clr[10] = 0, 1
	if _, err := DecodeRequest(vi.WmRpc{Kind: Kind, Applied: OpClear, Title: clr}); err == nil {
		t.Fatal("clear with nonzero reserved tail decoded")
	}
	for _, op := range []uint8{OpPresent, OpPoll, OpClose} {
		p := PayloadEmpty()
		p[23] = 1
		if _, err := DecodeRequest(vi.WmRpc{Kind: Kind, Applied: op, Title: p}); err == nil {
			t.Fatalf("op %d with nonzero payload decoded", op)
		}
	}
}

func TestDecodeRequestValidOps(t *testing.T) {
	req, err := DecodeRequest(vi.WmRpc{Kind: Kind, Applied: OpOpen, Title: PayloadOpen(200, 100)})
	if err != nil || req.Op != OpOpen || req.W != 200 || req.H != 100 {
		t.Fatalf("open request = (%+v, %v)", req, err)
	}
	req, err = DecodeRequest(vi.WmRpc{Kind: Kind, Applied: OpClear, Title: PayloadClear(0x0000FF00)})
	if err != nil || req.Op != OpClear || req.RGB != 0x0000FF00 {
		t.Fatalf("clear request = (%+v, %v)", req, err)
	}
	for _, op := range []uint8{OpPresent, OpPoll, OpClose} {
		req, err = DecodeRequest(vi.WmRpc{Kind: Kind, Applied: op, Title: PayloadEmpty()})
		if err != nil || req.Op != op {
			t.Fatalf("op %d request = (%+v, %v)", op, req, err)
		}
	}
}

func TestReplyCodec(t *testing.T) {
	var want [PayloadBytes]byte
	want[0], want[1], want[2] = StatusPending, 1, 0x2A
	if got := EncodeReply(StatusPending, true, 42); got != want {
		t.Fatalf("reply payload = %v want %v", got, want)
	}
	rep, err := DecodeReply(want)
	if err != nil || rep.Status != StatusPending || !rep.Staged || rep.Frame != 42 {
		t.Fatalf("reply round-trip = (%+v, %v)", rep, err)
	}
	bad := EncodeReply(0, false, 0)
	bad[6] = 1
	if _, err := DecodeReply(bad); err == nil {
		t.Fatal("reply with nonzero reserved tail decoded")
	}
}
