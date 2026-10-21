package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"testing"

	"virelai/rfb"
	"virelai/vi"
)

func TestRFBRequiresExplicitOperatorArgument(t *testing.T) {
	for _, args := range [][]string{nil, {"GOTABWM.ELF"}, {"GOTABWM.ELF", "anything"},
		{"GOTABWM.ELF", "--rfb-hermetic", "extra"}} {
		if rfbRequested(args) {
			t.Fatalf("unexpected RFB listener with argv %q", args)
		}
	}
	if !rfbRequested([]string{"GOTABWM.ELF", "--rfb-hermetic"}) {
		t.Fatal("operator opt-in refused")
	}
	stream := newRFBStream(nil)
	if rfbInputLimit > 16 || stream.stallNs <= 0 || stream.idle == nil || stream.sendIdle == nil || stream.drain == nil {
		t.Fatal("client queue/deadlines must be bounded")
	}
}

// rfbFakeSocket is the kernel's one-connection TCP as the stream sees it:
// at most one queued viewer segment, one unACKed send, and an RST.
type rfbFakeSocket struct {
	rx    [][]byte
	reset bool // the viewer's RST arrived (queued rx survives it, as in the kernel)
	acked bool
	sent  []byte
	ackOn int // idle ticks until a pending send is ACKed; <0 never
	ticks int
}

func (f *rfbFakeSocket) ready() (int64, int64) {
	var mask int64
	if len(f.rx) > 0 || f.reset {
		mask |= 1
	}
	if f.acked && !f.reset {
		mask |= 2
	}
	return mask, 0
}

func (f *rfbFakeSocket) idle() {
	f.ticks++
	if f.ackOn >= 0 && f.ticks >= f.ackOn {
		f.acked = true
	}
}

func (f *rfbFakeSocket) Recv(p []byte) (int, error) {
	if len(f.rx) > 0 {
		n := copy(p, f.rx[0])
		f.rx = f.rx[1:]
		return n, nil
	}
	if f.reset {
		return 0, vi.ErrPeerGone
	}
	return 0, errors.New("ETIMEDOUT")
}

func (f *rfbFakeSocket) Send(p []byte) (int, error) {
	f.sent = append(f.sent, p...)
	f.acked = false
	return len(p), nil
}

func (f *rfbFakeSocket) SetRecvDeadline(int64) {}

func rfbFakeStream(f *rfbFakeSocket, stallNs int64) *rfbStream {
	return &rfbStream{conn: f, ready: f.ready, idle: f.idle, sendIdle: f.idle, stallNs: stallNs}
}

// ACK pacing must not park the worker for a full guest scheduler tick.
// The quiet session loop still uses idle; this send path uses sendIdle.
func TestRFBStreamSendYieldsBetweenSegments(t *testing.T) {
	f := &rfbFakeSocket{acked: true, ackOn: 2}
	s := rfbFakeStream(f, 3600_000_000_000)
	s.idle = func() { t.Fatal("a frame send used the quiet-session sleep") }
	body := bytes.Repeat([]byte{0xab}, vi.TCPPayloadMax+1)
	if n, err := s.Write(body); n != len(body) || err != nil {
		t.Fatalf("wrote %d, %v", n, err)
	}
	if f.ticks != 2 || !bytes.Equal(f.sent, body) {
		t.Fatalf("send paced %d yields; bytes %d, want %d", f.ticks, len(f.sent), len(body))
	}
}

// Slot 76 readiness alone cannot see an ACK still queued in the virtio RX
// ring. The slot-32 drain advances the kernel TCP state, then readiness
// admits the next segment without waiting for the monitor's idle poll.
func TestRFBStreamSendDrainsACKAndHoldsInput(t *testing.T) {
	f := &rfbFakeSocket{acked: true, ackOn: -1}
	s := rfbFakeStream(f, 3600_000_000_000)
	s.idle = func() { t.Fatal("a send slept for a scheduler tick") }
	s.sendIdle = func() { t.Fatal("ACK was not drained on the first probe") }
	input := rfbPress(1, 300, 400)
	drains := 0
	s.drain = func(p []byte) (int, int64) {
		drains++
		f.acked = true
		if drains == 1 {
			return copy(p, input), 0
		}
		return 0, 0
	}
	body := bytes.Repeat([]byte{0xab}, vi.TCPPayloadMax+1)
	if n, err := s.Write(body); n != len(body) || err != nil {
		t.Fatalf("wrote %d, %v", n, err)
	}
	if drains != 1 || !bytes.Equal(f.sent, body) {
		t.Fatalf("drains=%d, sent=%d want %d", drains, len(f.sent), len(body))
	}
	got := make([]byte, len(input))
	if n, err := s.Read(got); n != len(input) || err != nil || !bytes.Equal(got, input) {
		t.Fatalf("input after ACK drain: n=%d err=%v bytes=%x", n, err, got)
	}
}

func TestRFBStreamDrainRefusesInputOverflow(t *testing.T) {
	f := &rfbFakeSocket{ackOn: -1}
	s := rfbFakeStream(f, 3600_000_000_000)
	s.heldN = len(s.held)
	s.drain = func(p []byte) (int, int64) { p[0] = 1; return 1, 0 }
	if n, err := s.Write([]byte{1}); n != 0 || rfbDropReason(err) != rfbDropFlood {
		t.Fatalf("overflow wrote %d, %v", n, err)
	}
}

// A viewer that dies while a frame waits on its ACK ends the send at once:
// the stall budget (an hour here) is for a live viewer that stopped ACKing.
func TestRFBStreamSendSeesPeerReset(t *testing.T) {
	for _, rx := range [][][]byte{nil, {[]byte("k")}} {
		f := &rfbFakeSocket{rx: rx, reset: true, ackOn: -1}
		s := rfbFakeStream(f, 3600_000_000_000)
		n, err := s.Write(make([]byte, 400))
		if n != 0 || rfbDropReason(err) != rfbDropPeer || f.ticks != 0 {
			t.Fatalf("rx %q: wrote %d, err %v after %d ticks", rx, n, err, f.ticks)
		}
	}
}

// Input that arrives while a send waits is held for the session loop, in
// order, not consumed by the check for a dead peer.
func TestRFBStreamHoldsInputDuringSend(t *testing.T) {
	press := rfbPress(1, 300, 400)
	f := &rfbFakeSocket{rx: [][]byte{press}, ackOn: 1}
	s := rfbFakeStream(f, 3600_000_000_000)
	body := bytes.Repeat([]byte{0xab}, vi.TCPPayloadMax+10)
	if n, err := s.Write(body); n != len(body) || err != nil {
		t.Fatalf("wrote %d, %v", n, err)
	}
	if !bytes.Equal(f.sent, body) {
		t.Fatal("send bytes changed")
	}
	if mask, _ := s.poll(); mask&1 == 0 {
		t.Fatal("held input not reported readable")
	}
	head, tail := make([]byte, 4), make([]byte, 8)
	n, _ := s.Read(head)
	m, _ := s.Read(tail)
	if got := append(head[:n], tail[:m]...); !bytes.Equal(got, press) || s.heldN != 0 {
		t.Fatalf("held input read back as %v, want %v", got, press)
	}
}

func TestRFBStreamSendStallIsBounded(t *testing.T) {
	f := &rfbFakeSocket{ackOn: -1}
	if _, err := rfbFakeStream(f, 1).Write([]byte("x")); rfbDropReason(err) != rfbDropStalled {
		t.Fatalf("unACKed send ended as %v", err)
	}
}

func TestRFBInputUsesWmEventWires(t *testing.T) {
	var m rfbModifiers
	// Modifier presses are state, not extra WM_KEY events. Unknown keysyms
	// from the codec cannot turn into a usage-zero seat chord.
	if _, ok := m.key(rfb.KeyEvent{Down: true, Usage: 0xe0, Known: true}); ok {
		t.Fatal("modifier generated a WM_KEY")
	}
	if _, ok := m.key(rfb.KeyEvent{Down: true, Keysym: 0x123456, Known: false}); ok {
		t.Fatal("unknown keysym generated a WM_KEY")
	}
	e, ok := m.key(rfb.KeyEvent{Down: true, Usage: 0x2c, Known: true})
	if !ok || e.Kind != vi.EvWmKey || e.Arg0 != 0x2c || e.Flags != vi.ModCtrl {
		t.Fatalf("ctrl-space WM_KEY = %+v, %t", e, ok)
	}
	if _, ok := m.key(rfb.KeyEvent{Down: true, Usage: 0x2c, Known: true}); ok {
		t.Fatal("held-key repeat generated a second WM_KEY")
	}
	if _, ok := m.key(rfb.KeyEvent{Down: false, Usage: 0x2c, Known: true}); ok {
		t.Fatal("release generated a WM_KEY")
	}
	m.key(rfb.KeyEvent{Down: false, Usage: 0xe0, Known: true})
	e, _ = m.key(rfb.KeyEvent{Down: true, Usage: 0x28, Known: true})
	if e.Flags != 0 {
		t.Fatalf("modifier stuck after release: %+v", e)
	}
}

func TestRFBButtonOrderingMatchesSeat(t *testing.T) {
	for _, c := range []struct{ wire, seat uint8 }{
		{0, 0}, {1, 1}, {2, 4}, {4, 2}, {7, 7},
		{8, 0}, {9, 1}, {0xff, 7},
	} {
		if got := rfbButtonsToSeat(c.wire); got != c.seat {
			t.Fatalf("RFB mask %d -> seat %d want %d", c.wire, got, c.seat)
		}
	}
}

func TestRFBDecoderAcceptsWheelButton(t *testing.T) {
	client := append([]byte("RFB 003.008\n\x01\x01"), 5, 8, 0, 100, 2, 88)
	s, err := rfb.NewSession(bytes.NewReader(client), io.Discard,
		vi.ScanoutWidth, vi.ScanoutHeight, "VirelaiOS")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Handshake(); err != nil {
		t.Fatal(err)
	}
	msg, err := s.ReadMessage()
	if err != nil || msg.Kind != rfb.PointerInput || msg.Pointer.Buttons != 8 ||
		rfbButtonsToSeat(msg.Pointer.Buttons) != 0 {
		t.Fatalf("wheel-only pointer = %+v, %v", msg, err)
	}
}

func TestRFBDecoderRejectsPointerOutsideSeat(t *testing.T) {
	for _, pointer := range [][]byte{
		{5, 1, 0xea, 0x60, 0, 16}, // x=60000
		{5, 1, 0, 16, 2, 0xd0},    // y=720
	} {
		client := append([]byte("RFB 003.008\n\x01\x01"), pointer...)
		s, err := rfb.NewSession(bytes.NewReader(client), io.Discard,
			vi.ScanoutWidth, vi.ScanoutHeight, "VirelaiOS")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.Handshake(); err != nil {
			t.Fatal(err)
		}
		if msg, err := s.ReadMessage(); err == nil {
			t.Fatalf("out-of-bounds pointer reached seat: %+v", msg)
		}
	}
}

func TestRFBInputQueueIsFinite(t *testing.T) {
	s := &rfbServer{input: make(chan remoteInput, rfbInputLimit)}
	for i := 0; i < rfbInputLimit; i++ {
		if !s.enqueue(remoteInput{kind: rfb.PointerInput}) {
			t.Fatalf("queue refused before capacity at %d", i)
		}
	}
	if s.enqueue(remoteInput{kind: rfb.PointerInput}) {
		t.Fatal("input flood was not refused")
	}
}

func TestRFBDeathReleasesHeldPointer(t *testing.T) {
	oldButtons := prevPtrButtons
	defer func() { prevPtrButtons = oldButtons }()
	prevPtrButtons = 1
	s := &rfbServer{input: make(chan remoteInput, 1), lastPoint: 100 | 600<<16, lastButtons: 1}
	s.closed.Store(true)
	if !s.finishInput() {
		t.Fatal("closed session not retired")
	}
	if prevPtrButtons != 0 {
		t.Fatal("held remote button survived viewer death")
	}
}

func rfbTestServer() *rfbServer {
	return &rfbServer{
		scan:      make([]byte, vi.ScanoutFbBytes),
		presented: 1,
		input:     make(chan remoteInput, rfbInputLimit),
	}
}

// rfbTestSession completes a valid 3.8/None handshake, then serves the
// remaining client bytes to the session loop.
func rfbTestSession(t testing.TB, after []byte) *rfb.Session {
	t.Helper()
	client := append([]byte("RFB 003.008\n\x01\x01"), after...)
	s, err := rfb.NewSession(bytes.NewReader(client), io.Discard,
		vi.ScanoutWidth, vi.ScanoutHeight, "VirelaiOS")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Handshake(); err != nil {
		t.Fatal(err)
	}
	return s
}

func rfbReadable() (int64, int64) { return 1, 0 }

func rfbPress(buttons uint8, x, y uint16) []byte {
	return []byte{5, buttons, byte(x >> 8), byte(x), byte(y >> 8), byte(y)}
}

func TestRFBDropReasons(t *testing.T) {
	for _, c := range []struct {
		err  error
		want string
	}{
		{fmt.Errorf("%w: client message 99", rfb.ErrProtocol), rfbDropMalformed},
		{rfb.ErrUnsupported, rfbDropMalformed},
		{io.EOF, rfbDropPeer},
		{io.ErrUnexpectedEOF, rfbDropPeer},
		{vi.ErrPeerGone, rfbDropPeer},
		{vi.ErrConnClosed, rfbDropPeer},
		{errRFBSendStalled, rfbDropStalled},
		{errRFBInputFlood, rfbDropFlood},
		{errRFBSocket, rfbDropSocket},
		{errors.New("ETIMEDOUT"), rfbDropTimeout},
		{errors.New("EIO"), rfbDropIO},
	} {
		if got := rfbDropReason(c.err); got != c.want {
			t.Errorf("rfbDropReason(%v) = %q want %q", c.err, got, c.want)
		}
	}
}

// Hostile client bytes after a valid handshake. Each case ends the session
// for its named reason, and nothing after the offending bytes reaches the
// seat's input queue.
var rfbHostileCases = []struct {
	name   string
	wire   []byte
	reason string
	inputs int
}{
	{"unknown message", []byte{0xff}, rfbDropMalformed, 0},
	{"press then unknown message", append(rfbPress(1, 100, 200), 99, 5, 0, 0, 1, 0, 1), rfbDropMalformed, 1},
	{"oversized SetEncodings", []byte{2, 0, 0xff, 0xff, 0, 0, 0, 0}, rfbDropMalformed, 0},
	{"palette SetPixelFormat", []byte{0, 0, 0, 0, 8, 8, 0, 0, 0, 7, 0, 7, 0, 3, 0, 3, 6, 0, 0, 0}, rfbDropMalformed, 0},
	{"update outside the frame", []byte{3, 0, 5, 0, 0, 0, 0, 1, 0, 1}, rfbDropMalformed, 0},
	{"key state 2", []byte{4, 2, 0, 0, 0, 0, 0, 0x61}, rfbDropMalformed, 0},
	{"pointer outside the seat", rfbPress(1, 1280, 10), rfbDropMalformed, 0},
	{"truncated pointer", []byte{5, 1, 0}, rfbDropPeer, 0},
	{"press then peer death", rfbPress(1, 100, 200), rfbDropPeer, 1},
}

func TestRFBHostileClientsFailClosed(t *testing.T) {
	for _, c := range rfbHostileCases {
		s := rfbTestServer()
		reason := s.run(rfbTestSession(t, c.wire), rfbReadable, func() {})
		if reason != c.reason || len(s.input) != c.inputs {
			t.Errorf("%s: reason %q with %d queued inputs, want %q with %d",
				c.name, reason, len(s.input), c.reason, c.inputs)
		}
	}
}

func TestRFBRepeatedRequestsCoalesce(t *testing.T) {
	a := rfb.Request{Incremental: true, Rectangle: rfb.Rectangle{X: 10, Y: 20, Width: 30, Height: 40}}
	b := rfb.Request{Incremental: true, Rectangle: rfb.Rectangle{X: 100, Y: 5, Width: 16, Height: 16}}
	want := rfb.Request{Incremental: true, Rectangle: rfb.Rectangle{X: 10, Y: 5, Width: 106, Height: 55}}
	if got := mergeRFBRequests(a, b); got != want {
		t.Fatalf("merge %+v want %+v", got, want)
	}
	b.Incremental = false
	if mergeRFBRequests(a, b).Incremental {
		t.Fatal("a full request merged into an incremental one")
	}
	// A full request is answered at once; the next two incremental ones
	// wait on an unchanged screen together instead of ending the session.
	wire := []byte{3, 0, 0, 0, 0, 0, 0, 16, 0, 16, 3, 1, 0, 0, 0, 0, 0, 16, 0, 16, 3, 1, 0, 32, 0, 32, 0, 16, 0, 16}
	s := rfbTestServer()
	if reason := s.run(rfbTestSession(t, wire), rfbReadable, func() {}); reason != rfbDropPeer {
		t.Fatalf("repeated requests ended the session as %q", reason)
	}
}

func TestRFBInputFloodDropsSession(t *testing.T) {
	var wire []byte
	for i := 0; i <= rfbInputLimit; i++ {
		wire = append(wire, rfbPress(0, uint16(i), 10)...)
	}
	s := rfbTestServer()
	if reason := s.run(rfbTestSession(t, wire), rfbReadable, func() {}); reason != rfbDropFlood {
		t.Fatalf("undrained input flood ended as %q", reason)
	}
	if len(s.input) != rfbInputLimit {
		t.Fatalf("queue holds %d, want its %d bound", len(s.input), rfbInputLimit)
	}
}

// M52's bar for a viewer that dies holding a content press: the app sees
// the press AND a release at the last point, and the seat's capture state
// is idle for the next local click.
func TestRFBPeerDeathMidContentDragReleasesCapture(t *testing.T) {
	savedTabs, savedForward := tabs, forwardContentPointer
	savedButtons, savedContent, savedDrag := prevPtrButtons, contentDown, railDragFrom
	savedLaunch := launch
	t.Cleanup(func() {
		tabs, forwardContentPointer = savedTabs, savedForward
		prevPtrButtons, contentDown, railDragFrom = savedButtons, savedContent, savedDrag
		launch = savedLaunch
	})
	tabs = TabStrip{}
	if !tabs.OpenTab(7, "Calc") {
		t.Fatal("OpenTab")
	}
	prevPtrButtons, contentDown, railDragFrom = 0, false, -1
	launch = launcherState{}
	type sample struct {
		x, y uint32
		b, m uint8
	}
	var got []sample
	forwardContentPointer = func(x, y uint32, b, m uint8) int64 {
		got = append(got, sample{x, y, b, m})
		return 0
	}

	wire := append(rfbPress(1, 300, 400), rfbPress(1, 340, 420)...)
	s := rfbTestServer()
	if reason := s.run(rfbTestSession(t, wire), rfbReadable, func() {}); reason != rfbDropPeer {
		t.Fatalf("mid-drag EOF ended as %q", reason)
	}
	s.closed.Store(true)
	if !s.drainInput() {
		t.Fatal("dead session not retired after its queue drained")
	}
	want := []sample{{300, 400, 1, 0}, {340, 420, 1, 0}, {340, 420, 0, 0}}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("content samples %v want %v", got, want)
	}
	if prevPtrButtons != 0 || contentDown {
		t.Fatalf("capture survived viewer death: buttons=%d contentDown=%t", prevPtrButtons, contentDown)
	}
}

func FuzzRFBSessionLoop(f *testing.F) {
	for _, c := range rfbHostileCases {
		f.Add(c.wire)
	}
	f.Add([]byte{3, 1, 0, 0, 0, 0, 0, 16, 0, 16, 4, 1, 0, 0, 0, 0, 0xff, 0xe3})
	f.Fuzz(func(t *testing.T, wire []byte) {
		s := rfbTestServer()
		reason := s.run(rfbTestSession(t, wire), rfbReadable, func() {})
		if reason == "" || len(s.input) > rfbInputLimit {
			t.Fatalf("reason %q with %d queued inputs", reason, len(s.input))
		}
	})
}
