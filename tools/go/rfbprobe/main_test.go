package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestInputWireShapes(t *testing.T) {
	if got := key(true, 0xffe3); !bytes.Equal(got, []byte{4, 1, 0, 0, 0, 0, 0xff, 0xe3}) {
		t.Fatalf("Ctrl_L: %x", got)
	}
	if got := pointer(1, dismissX, dismissY); !bytes.Equal(got, []byte{5, 1, 3, 32, 2, 88}) {
		t.Fatalf("pointer: %x", got)
	}
}

func TestProbeRejectsWrongPixel(t *testing.T) {
	wire := fixture()
	// Same shape and handshake, but one pixel from the empty desktop.
	p := len(wire) - patchW*patchH*4
	copy(wire[p:p+4], []byte{0x26, 0x20, 0x18, 0})
	var out bytes.Buffer
	if err := probe(bytes.NewReader(wire), &out); err == nil || !strings.Contains(err.Error(), "Calc button pixel") {
		t.Fatalf("expected pixel refusal, got %v", err)
	}
}

func TestProbeNegotiatesAndRequestsRealPixels(t *testing.T) {
	var out bytes.Buffer
	if err := probe(bytes.NewReader(fixture()), &out); err != nil {
		t.Fatal(err)
	}
	b := out.Bytes()
	if !bytes.HasPrefix(b, []byte("RFB 003.008\n")) ||
		!bytes.Contains(b, []byte{3, 0, 0, patchX, 0, patchY, 0, patchW, 0, patchH}) ||
		!bytes.HasSuffix(b, pointer(0, dismissX, dismissY)) {
		t.Fatalf("client did not request pixels and send input: %x", b)
	}
}

func TestSecurityRefusalRequiresFailedResultThenClose(t *testing.T) {
	refusal := append([]byte("RFB 003.008\n"), 1, 1, 0, 0, 0, 1, 0, 0, 0, 6)
	refusal = append(refusal, "denied"...)
	var out bytes.Buffer
	if err := probeSecurityRefused(bytes.NewReader(refusal), &out); err != nil {
		t.Fatal(err)
	}
	b := out.Bytes()
	if !bytes.HasPrefix(b, []byte("RFB 003.008\n\x02")) || !bytes.HasSuffix(b, pointer(1, contentX, contentY)) {
		t.Fatalf("client did not pick VncAuth then keep talking: %x", b)
	}
	if err := probeSecurityRefused(bytes.NewReader(append(refusal, 0)), &out); err == nil ||
		!strings.Contains(err.Error(), "seat sent 00 after the refusal") {
		t.Fatalf("a byte after the refusal must fail, got %v", err)
	}
	accepted := append([]byte("RFB 003.008\n"), 1, 1, 0, 0, 0, 0, 0, 0, 0, 0)
	if err := probeSecurityRefused(bytes.NewReader(accepted), &out); err == nil ||
		!strings.Contains(err.Error(), "want failed") {
		t.Fatalf("an accepted VncAuth must fail, got %v", err)
	}
}

func TestHostileModesSendTheirBytesAndWantAHangUp(t *testing.T) {
	settle = 0
	for _, tc := range []struct {
		mode string
		run  func(io.Reader, io.Writer) error
		want []byte
	}{
		{"malformed", probeMalformed, []byte{2, 0, 0xff, 0xff, 0, 0, 0, 0}},
		{"stall", probeStall, []byte{3, 0, 0}},
	} {
		var out bytes.Buffer
		if err := tc.run(bytes.NewReader(handshake()), &out); err != nil {
			t.Fatalf("%s: %v", tc.mode, err)
		}
		if !bytes.HasSuffix(out.Bytes(), tc.want) {
			t.Fatalf("%s: wire ends %x, want %x", tc.mode, out.Bytes(), tc.want)
		}
	}
	var out bytes.Buffer
	if err := probeMalformed(bytes.NewReader(handshake()), &out); err != nil ||
		!bytes.Contains(out.Bytes(), pointer(1, contentX, contentY)) {
		t.Fatalf("malformed mode must hold a content press first: %v %x", err, out.Bytes())
	}
}

func TestExpectCloseFailsWhenTheSeatStaysOpen(t *testing.T) {
	old := closeWait
	closeWait = 50 * time.Millisecond
	defer func() { closeWait = old }()
	r, w := io.Pipe()
	defer w.Close()
	if err := expectClose(r, "while idle"); err == nil || !strings.Contains(err.Error(), "kept the connection open") {
		t.Fatalf("expected a timeout, got %v", err)
	}
}

func TestDeathModesDieOnPurpose(t *testing.T) {
	settle = 0
	var died errDied
	var out bytes.Buffer
	if err := probeDieFocus(bytes.NewReader(handshake()), &out); !errors.As(err, &died) ||
		!bytes.HasSuffix(out.Bytes(), key(true, 'c')) {
		t.Fatalf("die-focus: %v %x", err, out.Bytes())
	}
	wire := append(handshake(), 0, 0, 0, 1, 0, 0, 0, 0, 0x05, 0, 0x02, 0xd0, 0, 0, 0, 0)
	wire = append(wire, make([]byte, 2048)...)
	out.Reset()
	if err := probeDieDrag(bytes.NewReader(wire), &out); !errors.As(err, &died) {
		t.Fatalf("die-drag: %v", err)
	}
	if !bytes.Contains(out.Bytes(), concat(pointer(1, contentX, contentY), pointer(1, contentX+40, contentY+30))) {
		t.Fatalf("die-drag did not drag with the button held: %x", out.Bytes())
	}
	if err := probeDieDrag(bytes.NewReader(handshake()), &out); err == nil || errors.As(err, &died) {
		t.Fatalf("die-drag without an update must fail, not die: %v", err)
	}
}

func TestBridgeIsLoopbackOnlyAndAuthenticatesOneViewer(t *testing.T) {
	if err := runBridge("0.0.0.0:0", "", strings.NewReader(""), io.Discard); err == nil ||
		!strings.Contains(err.Error(), "not loopback") {
		t.Fatalf("wildcard bridge must be refused, got %v", err)
	}
	ln, err := net.ListenTCP("tcp", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	var toGuest bytes.Buffer
	done := make(chan error, 1)
	go func() { done <- bridgeOne(ln, 5*time.Second, "password", bytes.NewReader(handshake()), &toGuest) }()
	c, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	authenticateTestViewer(t, c, "RFB 003.003\n", "password")
	_, _ = c.Write([]byte{1})
	init := make([]byte, 24+9)
	if _, err := io.ReadFull(c, init); err != nil || string(init[24:]) != "VirelaiOS" {
		t.Fatalf("viewer ServerInit: %x %v", init, err)
	}
	_ = c.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if got := toGuest.Bytes(); !bytes.Equal(got, []byte("RFB 003.008\n\x01\x01")) {
		t.Fatalf("guest got %x, want RFB 3.8/None and ClientInit", got)
	}
	if _, err := net.DialTimeout("tcp", ln.Addr().String(), time.Second); err == nil {
		t.Fatal("bridge accepted a second viewer")
	}
}

func TestBridgeVNCAuthAcceptAndRefuse(t *testing.T) {
	for _, version := range []string{"RFB 003.003\n", "RFB 003.007\n", "RFB 003.008\n"} {
		t.Run(version[:11], func(t *testing.T) {
			client, server := net.Pipe()
			defer client.Close()
			done := make(chan error, 1)
			go func() {
				defer server.Close()
				done <- authenticateViewer(server, "password")
			}()
			_ = client.SetDeadline(time.Now().Add(5 * time.Second))
			authenticateTestViewer(t, client, version, "password")
			if err := <-done; err != nil {
				t.Fatal(err)
			}
		})
	}
	for _, tc := range []struct {
		name, version, password string
		selectType              byte
	}{
		{"wrong password 3.3", "RFB 003.003\n", "wrongpwd", 2},
		{"wrong password 3.8", "RFB 003.008\n", "wrongpwd", 2},
		{"refuse None", "RFB 003.008\n", "", 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			client, server := net.Pipe()
			defer client.Close()
			done := make(chan error, 1)
			go func() {
				defer server.Close()
				done <- authenticateViewer(server, "password")
			}()
			_ = client.SetDeadline(time.Now().Add(5 * time.Second))
			readTestBytes(t, client, 12)
			_, _ = client.Write([]byte(tc.version))
			if tc.version == "RFB 003.003\n" {
				if got := readTestBytes(t, client, 4); !bytes.Equal(got, []byte{0, 0, 0, 2}) {
					t.Fatalf("security offer: %x", got)
				}
			} else {
				if got := readTestBytes(t, client, 2); !bytes.Equal(got, []byte{1, 2}) {
					t.Fatalf("security offer: %x", got)
				}
				_, _ = client.Write([]byte{tc.selectType})
			}
			if tc.selectType == 2 {
				challenge := readTestBytes(t, client, 16)
				var block [16]byte
				copy(block[:], challenge)
				response, err := vncResponse(tc.password, block)
				if err != nil {
					t.Fatal(err)
				}
				_, _ = client.Write(response[:])
			}
			if got := readTestBytes(t, client, 4); !bytes.Equal(got, []byte{0, 0, 0, 1}) {
				t.Fatalf("refusal result: %x", got)
			}
			if tc.version == "RFB 003.008\n" {
				n := binary.BigEndian.Uint32(readTestBytes(t, client, 4))
				if n == 0 || n > 100 {
					t.Fatalf("refusal reason length %d", n)
				}
				if reason := string(readTestBytes(t, client, int(n))); reason == "" {
					t.Fatal("missing refusal reason")
				}
			}
			if err := <-done; err == nil {
				t.Fatal("unauthenticated viewer accepted")
			}
		})
	}
}

func TestBridgeRejectsViewerBeforeGuestHandshake(t *testing.T) {
	ln, err := net.ListenTCP("tcp", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	var toGuest bytes.Buffer
	done := make(chan error, 1)
	go func() { done <- bridgeOne(ln, time.Second, "password", bytes.NewReader(handshake()), &toGuest) }()
	c, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	readTestBytes(t, c, 12)
	_, _ = c.Write([]byte("RFB 003.003\n"))
	readTestBytes(t, c, 4)
	challenge := readTestBytes(t, c, 16)
	var block [16]byte
	copy(block[:], challenge)
	answer, _ := vncResponse("incorrect", block)
	_, _ = c.Write(answer[:])
	if got := readTestBytes(t, c, 4); !bytes.Equal(got, []byte{0, 0, 0, 1}) {
		t.Fatalf("refusal: %x", got)
	}
	_ = c.Close()
	if err := <-done; err == nil || !strings.Contains(err.Error(), "wrong password") {
		t.Fatalf("bridge accepted bad password: %v", err)
	}
	if toGuest.Len() != 0 {
		t.Fatalf("unauthenticated viewer reached guest: %x", toGuest.Bytes())
	}
}

func TestBridgeRetriesAfterViewerClosesBeforeAnswer(t *testing.T) {
	ln, err := net.ListenTCP("tcp", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	var toGuest bytes.Buffer
	done := make(chan error, 1)
	go func() { done <- bridgeOne(ln, 5*time.Second, "password", bytes.NewReader(handshake()), &toGuest) }()

	first, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	_ = first.SetDeadline(time.Now().Add(5 * time.Second))
	readTestBytes(t, first, 12)
	_, _ = first.Write([]byte("RFB 003.003\n"))
	if got := readTestBytes(t, first, 4); !bytes.Equal(got, []byte{0, 0, 0, 2}) {
		t.Fatalf("first offer: %x", got)
	}
	readTestBytes(t, first, 16) // challenge sent; the viewer closes without responding
	_ = first.Close()

	second, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	_ = second.SetDeadline(time.Now().Add(5 * time.Second))
	authenticateTestViewer(t, second, "RFB 003.003\n", "password")
	_, _ = second.Write([]byte{1})
	readTestBytes(t, second, 24+9)
	_ = second.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if got := toGuest.Bytes(); !bytes.Equal(got, []byte("RFB 003.008\n\x01\x01")) {
		t.Fatalf("guest got %x, want only the authenticated viewer's handshake", got)
	}
}

func TestBridgeBoundsUnauthenticatedAttempts(t *testing.T) {
	ln, err := net.ListenTCP("tcp", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	var toGuest bytes.Buffer
	done := make(chan error, 1)
	go func() { done <- bridgeOne(ln, 5*time.Second, "password", bytes.NewReader(handshake()), &toGuest) }()
	for range 3 {
		c, err := net.Dial("tcp", ln.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		_ = c.SetDeadline(time.Now().Add(5 * time.Second))
		readTestBytes(t, c, 12)
		_, _ = c.Write([]byte("RFB 003.003\n"))
		readTestBytes(t, c, 4)
		var challenge [16]byte
		copy(challenge[:], readTestBytes(t, c, 16))
		response, err := vncResponse("wrongpwd", challenge)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = c.Write(response[:])
		if got := readTestBytes(t, c, 4); !bytes.Equal(got, []byte{0, 0, 0, 1}) {
			t.Fatalf("refusal: %x", got)
		}
		_ = c.Close()
	}
	if err := <-done; err == nil || !strings.Contains(err.Error(), "after 3 attempts") {
		t.Fatalf("bridge did not bound attempts: %v", err)
	}
	if toGuest.Len() != 0 {
		t.Fatalf("unauthenticated attempts reached guest: %x", toGuest.Bytes())
	}
	if _, err := net.DialTimeout("tcp", ln.Addr().String(), time.Second); err == nil {
		t.Fatal("bridge accepted a fourth viewer")
	}
}

func TestOneShotPassword(t *testing.T) {
	a, err := randomVNCPassword()
	if err != nil {
		t.Fatal(err)
	}
	b, err := randomVNCPassword()
	if err != nil {
		t.Fatal(err)
	}
	if len(a) != 8 || len(b) != 8 || a == b {
		t.Fatalf("password length or freshness: %d, %d, equal=%t", len(a), len(b), a == b)
	}
}

func TestVNCResponseVector(t *testing.T) {
	// Independent OpenSSL DES-ECB vector: challenge 00..0f, key is the
	// bit-reversed bytes of "password" (the VNC auth key convention).
	var challenge [16]byte
	for i := range challenge {
		challenge[i] = byte(i)
	}
	response, err := vncResponse("password", challenge)
	if err != nil {
		t.Fatal(err)
	}
	if want := []byte{0xb8, 0x66, 0x92, 0x41, 0x25, 0xc8, 0xee, 0xbb,
		0x9d, 0xeb, 0xc1, 0xdb, 0x61, 0xc5, 0x38, 0xe2}; !bytes.Equal(response[:], want) {
		t.Fatalf("VNC response %x, want %x", response, want)
	}
}

func TestBridgePasswordUsesPrivateFIFO(t *testing.T) {
	path := filepath.Join(t.TempDir(), "password.pipe")
	if err := syscall.Mkfifo(path, 0600); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- deliverPassword(path, "abcdefgh") }()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	b, err := io.ReadAll(f)
	_ = f.Close()
	if err != nil || string(b) != "abcdefgh\n" || <-done != nil {
		t.Fatalf("FIFO password delivery: %q %v", b, err)
	}
	if err := deliverPassword(filepath.Join(t.TempDir(), "missing"), "abcdefgh"); err == nil {
		t.Fatal("missing private FIFO accepted")
	}
	regular := filepath.Join(t.TempDir(), "regular")
	if err := os.WriteFile(regular, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := deliverPassword(regular, "abcdefgh"); err == nil {
		t.Fatal("regular file accepted as password destination")
	}
}

func authenticateTestViewer(t *testing.T, c net.Conn, version, password string) {
	t.Helper()
	if got := string(readTestBytes(t, c, 12)); got != "RFB 003.008\n" {
		t.Fatalf("banner: %q", got)
	}
	_, _ = c.Write([]byte(version))
	if version == "RFB 003.003\n" {
		if got := readTestBytes(t, c, 4); !bytes.Equal(got, []byte{0, 0, 0, 2}) {
			t.Fatalf("security type: %x", got)
		}
	} else {
		if got := readTestBytes(t, c, 2); !bytes.Equal(got, []byte{1, 2}) {
			t.Fatalf("security types: %x", got)
		}
		_, _ = c.Write([]byte{2})
	}
	var challenge [16]byte
	copy(challenge[:], readTestBytes(t, c, 16))
	response, err := vncResponse(password, challenge)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = c.Write(response[:])
	if got := readTestBytes(t, c, 4); !bytes.Equal(got, []byte{0, 0, 0, 0}) {
		t.Fatalf("accepted result: %x", got)
	}
}

func readTestBytes(t *testing.T, r io.Reader, n int) []byte {
	t.Helper()
	b := make([]byte, n)
	if _, err := io.ReadFull(r, b); err != nil {
		t.Fatal(err)
	}
	return b
}

// handshake is a server's None negotiation through ServerInit, then EOF.
func handshake() []byte {
	b := fixture()
	return b[:len(b)-16-patchW*patchH*4]
}

func fixture() []byte {
	b := []byte("RFB 003.008\n")
	b = append(b, 1, 1, 0, 0, 0, 0) // None and SecurityResult=0
	init := make([]byte, 24)
	binary.BigEndian.PutUint16(init[:2], frameW)
	binary.BigEndian.PutUint16(init[2:4], frameH)
	init[4], init[5], init[7] = 32, 24, 1
	init[14], init[15] = 16, 8
	binary.BigEndian.PutUint32(init[20:24], 9)
	b = append(b, init...)
	b = append(b, "VirelaiOS"...)
	rect := make([]byte, 16)
	binary.BigEndian.PutUint16(rect[2:4], 1)
	binary.BigEndian.PutUint16(rect[4:6], patchX)
	binary.BigEndian.PutUint16(rect[6:8], patchY)
	binary.BigEndian.PutUint16(rect[8:10], patchW)
	binary.BigEndian.PutUint16(rect[10:12], patchH)
	b = append(b, rect...)
	for range patchW * patchH {
		b = append(b, 0x48, 0x37, 0x2d, 0)
	}
	return b
}
