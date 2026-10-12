// rfbprobe is a deliberately independent RFB 3.8 client for the hermetic
// live-rfb gate. Its stdin/stdout are a binary byte stream supplied by the
// runner's --net attachment, NOT a host TCP socket or routable endpoint.
// The one exception is -bridge, the trusted-local tape path (ADR 0037 D5):
// it accepts exactly one viewer on a loopback address and pipes it through.
package main

import (
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"time"
)

const (
	frameW = 1280
	frameH = 720
	patchX = 80
	patchY = 150
	patchW = 16
	patchH = 16

	// Content inside the hosted Calc window, below the seat's rail and away
	// from the launcher panel: a press here is forwarded to the app.
	contentX = 88
	contentY = 158

	// Plain desktop past the launcher strip's right edge (#2054: the strip
	// owns x<264, so the old x=100 point is INSIDE it now): a press here
	// dismisses the open launcher.
	dismissX = 800
	dismissY = 600

	// Exit status of a viewer that dies without closing its socket. The
	// runner answers a non-zero exit with a TCP RST toward the guest.
	diedStatus = 3
)

// closeWait bounds how long a probe waits for the seat to hang up. The
// guest's own read budget is 30 s, so a stalled viewer needs longer.
var closeWait = 50 * time.Second

// settle gives the seat a composite pass to take earlier input before the
// next write, so the two land in distinct TCP segments.
var settle = 3 * time.Second

var modes = map[string]func(io.Reader, io.Writer) error{
	"pixels":    probe,
	"security":  probeSecurityRefused,
	"malformed": probeMalformed,
	"stall":     probeStall,
	"die-drag":  probeDieDrag,
	"die-focus": probeDieFocus,
}

func main() {
	mode := flag.String("mode", "pixels", "probe mode")
	bridge := flag.String("bridge", "", "loopback host:port for one real viewer (tape only)")
	passwordFIFO := flag.String("bridge-password-fifo", "", "named pipe for the one-shot bridge password (tape only)")
	flag.Parse()
	if *bridge != "" {
		if err := runBridge(*bridge, *passwordFIFO, os.Stdin, os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, "RFBPROBE: FAIL:", err)
			os.Exit(1)
		}
		return
	}
	if *passwordFIFO != "" {
		fmt.Fprintln(os.Stderr, "RFBPROBE: FAIL: -bridge-password-fifo requires -bridge")
		os.Exit(2)
	}
	run, ok := modes[*mode]
	if !ok {
		fmt.Fprintln(os.Stderr, "RFBPROBE: FAIL: unknown mode", *mode)
		os.Exit(2)
	}
	err := run(os.Stdin, os.Stdout)
	var death errDied
	if errors.As(err, &death) {
		fmt.Fprintln(os.Stderr, "RFBPROBE: viewer dies "+string(death))
		os.Exit(diedStatus)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "RFBPROBE: FAIL:", err)
		os.Exit(1)
	}
	if *mode == "pixels" {
		fmt.Fprintln(os.Stderr, "RFBPROBE: pixel and input exchange complete")
	}
}

// errDied is not a failure: the mode's point is to vanish at this moment.
type errDied string

func (e errDied) Error() string { return "died " + string(e) }

// negotiate runs the client side of RFB 3.8 with security None.
func negotiate(r io.Reader, w io.Writer) error {
	if err := readBanner(r); err != nil {
		return err
	}
	if err := write(w, []byte("RFB 003.008\n")); err != nil {
		return err
	}
	if err := readNoneOffer(r); err != nil {
		return err
	}
	if err := write(w, []byte{1}); err != nil {
		return err
	}
	var result [4]byte
	if _, err := io.ReadFull(r, result[:]); err != nil {
		return fmt.Errorf("security result: %w", err)
	}
	if result != [4]byte{} {
		return fmt.Errorf("security result %x", result)
	}
	if err := write(w, []byte{1}); err != nil {
		return err
	}
	var init [24]byte
	if _, err := io.ReadFull(r, init[:]); err != nil {
		return fmt.Errorf("ServerInit: %w", err)
	}
	if binary.BigEndian.Uint16(init[0:2]) != frameW || binary.BigEndian.Uint16(init[2:4]) != frameH ||
		init[4] != 32 || init[5] != 24 || init[6] != 0 || init[7] != 1 ||
		init[14] != 16 || init[15] != 8 || init[16] != 0 {
		return fmt.Errorf("ServerInit dimensions or pixel format: %x", init[:20])
	}
	n := binary.BigEndian.Uint32(init[20:24])
	if n > 255 {
		return fmt.Errorf("server name length %d", n)
	}
	name := make([]byte, n)
	if _, err := io.ReadFull(r, name); err != nil {
		return fmt.Errorf("server name: %w", err)
	}
	fmt.Fprintf(os.Stderr, "RFBPROBE: RFB 3.8 None %dx%d %s\n", frameW, frameH, name)
	return nil
}

func readBanner(r io.Reader) error {
	var banner [12]byte
	if _, err := io.ReadFull(r, banner[:]); err != nil {
		return fmt.Errorf("server banner: %w", err)
	}
	if string(banner[:]) != "RFB 003.008\n" {
		return fmt.Errorf("server banner %q", banner)
	}
	return nil
}

func readNoneOffer(r io.Reader) error {
	var security [2]byte
	if _, err := io.ReadFull(r, security[:]); err != nil {
		return fmt.Errorf("security types: %w", err)
	}
	if security != [2]byte{1, 1} {
		return fmt.Errorf("security types %v, want exactly None", security)
	}
	return nil
}

func probe(r io.Reader, w io.Writer) error {
	if err := negotiate(r, w); err != nil {
		return err
	}
	// Raw only, never a library call into the server codec. The probe asks
	// for a 16x16 region fully inside Calc's first idle button, where its
	// token is dark BtnIdle #2d3748. The empty desktop is #182026, so a
	// passing comparison cannot come from the seat's blank frame alone.
	// SetEncodings and the request go out as one write: one TCP segment.
	req := append([]byte{2, 0, 0, 1, 0, 0, 0, 0}, 3, 0, 0, patchX, 0, patchY, 0, patchW, 0, patchH)
	if err := write(w, req); err != nil {
		return err
	}
	var header [16]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return fmt.Errorf("FramebufferUpdate: %w", err)
	}
	if header[0] != 0 || binary.BigEndian.Uint16(header[2:4]) != 1 ||
		binary.BigEndian.Uint16(header[4:6]) != patchX ||
		binary.BigEndian.Uint16(header[6:8]) != patchY ||
		binary.BigEndian.Uint16(header[8:10]) != patchW ||
		binary.BigEndian.Uint16(header[10:12]) != patchH ||
		binary.BigEndian.Uint32(header[12:16]) != 0 {
		return fmt.Errorf("raw rectangle header: %x", header)
	}
	pixels := make([]byte, patchW*patchH*4)
	if _, err := io.ReadFull(r, pixels); err != nil {
		return fmt.Errorf("raw pixels: %w", err)
	}
	const wantB, wantG, wantR = 0x48, 0x37, 0x2d
	for i := 0; i < len(pixels); i += 4 {
		if pixels[i] != wantB || pixels[i+1] != wantG || pixels[i+2] != wantR || pixels[i+3] != 0 {
			return fmt.Errorf("Calc button pixel (%d,%d) = %x want BGR0 48372d00",
				patchX+(i/4)%patchW, patchY+(i/4)/patchW, pixels[i:i+4])
		}
	}
	fmt.Fprintln(os.Stderr, "RFBPROBE: Calc BtnIdle 16x16 pixels = #2d3748")

	// Ctrl+Space opens the seat launcher. A left press OUTSIDE its strip
	// dismisses it. They traverse the same kind-21/19 path as local input.
	return write(w, concat(
		key(true, 0xffe3), key(true, ' '), key(false, ' '), key(false, 0xffe3),
		pointer(1, dismissX, dismissY), pointer(0, dismissX, dismissY),
	))
}

// probeSecurityRefused asks for VNC authentication (type 2), which the
// seat never offers, then keeps talking as if it had been let in: a
// 16-byte challenge answer and a pointer press. None of it may reach the
// seat, and the seat must hang up.
func probeSecurityRefused(r io.Reader, w io.Writer) error {
	if err := readBanner(r); err != nil {
		return err
	}
	if err := write(w, []byte("RFB 003.008\n")); err != nil {
		return err
	}
	if err := readNoneOffer(r); err != nil {
		return err
	}
	answer := make([]byte, 16) // what a VncAuth DES response would occupy
	for i := range answer {
		answer[i] = byte(0xa5 ^ i)
	}
	if err := write(w, concat([]byte{2}, answer, []byte{1}, pointer(1, contentX, contentY))); err != nil {
		return err
	}
	var result [8]byte
	if _, err := io.ReadFull(r, result[:]); err != nil {
		return fmt.Errorf("refusal SecurityResult: %w", err)
	}
	if binary.BigEndian.Uint32(result[:4]) != 1 {
		return fmt.Errorf("SecurityResult %x, want failed (1)", result[:4])
	}
	n := binary.BigEndian.Uint32(result[4:])
	if n == 0 || n > 255 {
		return fmt.Errorf("refusal reason length %d", n)
	}
	reason := make([]byte, n)
	if _, err := io.ReadFull(r, reason); err != nil {
		return fmt.Errorf("refusal reason: %w", err)
	}
	fmt.Fprintf(os.Stderr, "RFBPROBE: security type 2 refused: %s\n", reason)
	return expectClose(r, "after the refusal")
}

// probeMalformed holds a content press, then sends a SetEncodings whose
// count (65535) is beyond the codec's 256 bound. The seat must drop the
// session and release the press itself.
func probeMalformed(r io.Reader, w io.Writer) error {
	if err := negotiate(r, w); err != nil {
		return err
	}
	if err := write(w, pointer(1, contentX, contentY)); err != nil {
		return err
	}
	// The seat's receipt for the press must land before the malformed bytes.
	time.Sleep(settle)
	if err := write(w, []byte{2, 0, 0xff, 0xff, 0, 0, 0, 0}); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "RFBPROBE: sent SetEncodings count=65535 with a held press")
	return expectClose(r, "after the oversized message")
}

// probeStall starts a FramebufferUpdateRequest and never finishes it.
func probeStall(r io.Reader, w io.Writer) error {
	if err := negotiate(r, w); err != nil {
		return err
	}
	if err := write(w, []byte{3, 0, 0}); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "RFBPROBE: stalled 7 bytes short of a FramebufferUpdateRequest")
	return expectClose(r, "while stalled mid-message")
}

// probeDieDrag presses on Calc, drags, then asks for the whole screen raw
// and vanishes after reading the first rectangle's opening bytes: the
// viewer dies mid-drag and mid-update at once.
func probeDieDrag(r io.Reader, w io.Writer) error {
	if err := negotiate(r, w); err != nil {
		return err
	}
	if err := write(w, concat(
		pointer(1, contentX, contentY), pointer(1, contentX+40, contentY+30),
		[]byte{2, 0, 0, 1, 0, 0, 0, 0},
		[]byte{3, 0, 0, 0, 0, 0, frameW >> 8, frameW & 0xff, frameH >> 8, frameH & 0xff},
	)); err != nil {
		return err
	}
	var header [16]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return fmt.Errorf("FramebufferUpdate: %w", err)
	}
	if header[0] != 0 || binary.BigEndian.Uint32(header[12:16]) != 0 {
		return fmt.Errorf("full-frame update header: %x", header)
	}
	part := make([]byte, 2048)
	if _, err := io.ReadFull(r, part); err != nil {
		return fmt.Errorf("full-frame pixels: %w", err)
	}
	return errDied(fmt.Sprintf("mid-drag and mid-update (%d of %d raw bytes read)",
		len(part), frameW*frameH*4))
}

// probeDieFocus opens the launcher, types into its filter, and dies with
// the key still down: the seat's modal keyboard owner is the one the dead
// viewer summoned.
func probeDieFocus(r io.Reader, w io.Writer) error {
	if err := negotiate(r, w); err != nil {
		return err
	}
	if err := write(w, concat(
		key(true, 0xffe3), key(true, ' '), key(false, ' '), key(false, 0xffe3),
		key(true, 'c'),
	)); err != nil {
		return err
	}
	time.Sleep(settle)
	return errDied("mid-focus with the launcher open and 'c' held")
}

// expectClose reads until the seat closes the stream. Any byte the seat
// sends after a refusal is a failure: nothing may follow a hang-up.
func expectClose(r io.Reader, when string) error {
	start := time.Now()
	done := make(chan error, 1)
	go func() {
		var b [1]byte
		n, err := r.Read(b[:])
		if n > 0 {
			done <- fmt.Errorf("seat sent %x %s", b[:n], when)
			return
		}
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil && err != io.EOF {
			return err
		}
		fmt.Fprintf(os.Stderr, "RFBPROBE: seat closed the connection %s (%.0fs)\n",
			when, time.Since(start).Seconds())
		return nil
	case <-time.After(closeWait):
		return fmt.Errorf("seat kept the connection open %s for %s", when, closeWait)
	}
}

// runBridge is the D5(1) trusted-local path for the class-C tape. The
// password is handed to the operator, never to the runner's log when the
// tape supplies a FIFO. Only the host bridge speaks VNC auth; the guest
// still sees its usual RFB 3.8/None client.
func runBridge(addr, passwordFIFO string, guestIn io.Reader, guestOut io.Writer) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return err
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("bridge address %q is not loopback", addr)
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	defer ln.Close()
	password, err := randomVNCPassword()
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "RFBPROBE: bridge listening %s (one viewer, loopback only)\n", ln.Addr())
	if err := deliverPassword(passwordFIFO, password); err != nil {
		return err
	}
	return bridgeOne(ln.(*net.TCPListener), 120*time.Second, password, guestIn, guestOut)
}

func bridgeOne(ln *net.TCPListener, wait time.Duration, password string, guestIn io.Reader, guestOut io.Writer) error {
	defer ln.Close()
	_ = ln.SetDeadline(time.Now().Add(wait))
	const maxAuthAttempts = 3
	var viewer *net.TCPConn
	var lastAuthError error
	for attempt := 1; attempt <= maxAuthAttempts; attempt++ {
		next, err := ln.AcceptTCP()
		if err != nil {
			if lastAuthError != nil {
				return fmt.Errorf("no authenticated viewer after attempt %d (%v): %w", attempt-1, lastAuthError, err)
			}
			return fmt.Errorf("no viewer connected: %w", err)
		}
		fmt.Fprintf(os.Stderr, "RFBPROBE: bridge viewer %s (attempt %d)\n", next.RemoteAddr(), attempt)
		// Screen Sharing can close its first connection after seeing the
		// security offer, then reconnect when the operator enters a password.
		// Neither attempt touches the guest before authentication succeeds.
		_ = next.SetDeadline(time.Now().Add(wait))
		if err := authenticateViewer(next, password); err != nil {
			lastAuthError = err
			fmt.Fprintf(os.Stderr, "RFBPROBE: bridge auth attempt %d refused: %v\n", attempt, err)
			_ = next.Close()
			continue
		}
		viewer = next
		break
	}
	if viewer == nil {
		return fmt.Errorf("no authenticated viewer after %d attempts: %w", maxAuthAttempts, lastAuthError)
	}
	_ = ln.Close() // a successful viewer consumes the one session
	defer viewer.Close()
	_ = viewer.SetDeadline(time.Now().Add(wait))
	shared, err := negotiateGuest(viewer, guestIn, guestOut)
	if err != nil {
		return fmt.Errorf("guest None handshake: %w", err)
	}
	fmt.Fprintf(os.Stderr, "RFBPROBE: bridge ClientInit shared=%d (viewer VNC auth -> guest None)\n", shared)
	var init [24]byte
	if _, err := io.ReadFull(guestIn, init[:]); err != nil {
		return fmt.Errorf("guest ServerInit: %w", err)
	}
	nameLen := binary.BigEndian.Uint32(init[20:24])
	if nameLen > 255 || init[4] != 8 && init[4] != 16 && init[4] != 32 {
		return fmt.Errorf("guest ServerInit bounds or pixel format refused")
	}
	name := make([]byte, nameLen)
	if _, err := io.ReadFull(guestIn, name); err != nil {
		return fmt.Errorf("guest ServerInit name: %w", err)
	}
	if err := write(viewer, append(init[:], name...)); err != nil {
		return fmt.Errorf("viewer ServerInit: %w", err)
	}
	plan := newBridgeFramePlan(int(init[4] / 8))
	_ = viewer.SetDeadline(time.Time{})
	done := make(chan string, 2)
	go func() {
		var n int64
		var err error
		if plan.mode() {
			n, err = forwardTranscodedFrames(guestIn, viewer, plan)
		} else {
			n, err = io.Copy(viewer, guestIn)
		}
		if err != nil && err != io.EOF {
			fmt.Fprintln(os.Stderr, "RFBPROBE: bridge guest frames:", err)
		}
		done <- fmt.Sprintf("seat->viewer %d bytes", n)
	}()
	go func() {
		n, err := forwardViewerMessagesWithPlan(viewer, onlyWriter{guestOut}, plan)
		if err != nil {
			fmt.Fprintln(os.Stderr, "RFBPROBE: bridge viewer messages:", err)
		}
		done <- fmt.Sprintf("viewer->seat %d bytes", n)
	}()
	fmt.Fprintln(os.Stderr, "RFBPROBE: bridge closed:", <-done)
	return nil
}

type onlyWriter struct{ w io.Writer }

func (o onlyWriter) Write(p []byte) (int, error) { return o.w.Write(p) }

func concat(parts ...[]byte) []byte {
	var out []byte
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func key(down bool, sym uint32) []byte {
	b := []byte{4, 0, 0, 0, 0, 0, 0, 0}
	if down {
		b[1] = 1
	}
	binary.BigEndian.PutUint32(b[4:], sym)
	return b
}

func pointer(buttons uint8, x, y uint16) []byte {
	b := []byte{5, buttons, 0, 0, 0, 0}
	binary.BigEndian.PutUint16(b[2:4], x)
	binary.BigEndian.PutUint16(b[4:6], y)
	return b
}

func write(w io.Writer, data []byte) error {
	for len(data) > 0 {
		n, err := w.Write(data)
		if err != nil {
			return err
		}
		if n <= 0 {
			return io.ErrShortWrite
		}
		data = data[n:]
	}
	return nil
}
