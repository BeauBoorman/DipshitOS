// Reversed interop: the M135a server half against real peers. The host Go
// stdlib crypto/tls client handshakes with `server` (Ed25519 leaf, TLS 1.3
// only) and exchanges application data both ways — the same transport seam
// interop_test.go uses for the client direction, run backwards. Negatives
// pin the named alerts: a TLS 1.2-only offer, no shared cipher suite, no
// X25519 key share, and a bad client Finished.

package tls

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"testing"
	"time"
)

// buildEd25519Cert makes a self-signed Ed25519 certificate: CA:TRUE (so the
// guest's validator can anchor on it) plus serverAuth EKU and SANs for the
// names given — the same credential shape the share fixture generator emits.
func buildEd25519Cert(t *testing.T, dnsNames []string, ips []net.IP) (der []byte, seed [32]byte) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(11),
		Subject:               pkix.Name{CommonName: "virelai-test-https"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:              dnsNames,
		IPAddresses:           ips,
	}
	der, err = x509.CreateCertificate(rand.Reader, tmpl, tmpl, pub, priv)
	if err != nil {
		t.Fatal(err)
	}
	copy(seed[:], priv.Seed())
	return der, seed
}

// serverPair runs a `server` on a loopback TCP listener and returns the
// host-side conn plus the server object; the handshake runs on its own
// goroutine and reports to done. (Real TCP, not net.Pipe: the pipe's
// synchronous writes deadlock the moment a flight write crosses an alert
// write — the same reason interop_test.go runs on the loopback.)
type serverResult struct {
	s   *server
	err error
}

func serverPair(t *testing.T, cfg ServerConfig) (host net.Conn, done chan serverResult) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done = make(chan serverResult, 1)
	go func() {
		defer ln.Close()
		guest, err := ln.Accept()
		if err != nil {
			done <- serverResult{err: err}
			return
		}
		// The caller owns the conn after the handshake (app-data exchange
		// happens in the test body; s.close() shuts the transport).
		s := newServer(&netTransport{conn: guest}, cfg, func(p []byte) error {
			_, err := rand.Read(p)
			return err
		})
		done <- serverResult{s: s, err: s.handshake()}
	}()
	host, err = net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	return host, done
}

func TestServerInteropHostStdlibClient(t *testing.T) {
	der, seed := buildEd25519Cert(t, []string{"virelai.example"}, nil)
	cfg := ServerConfig{Chain: [][]byte{der}, Ed25519Seed: seed}
	host, done := serverPair(t, cfg)

	pool := x509.NewCertPool()
	ca, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	pool.AddCert(ca)
	cli := tls.Client(host, &tls.Config{
		RootCAs:    pool,
		ServerName: "virelai.example",
		MinVersion: tls.VersionTLS13,
	})
	if err := cli.Handshake(); err != nil {
		t.Fatalf("host client handshake: %v", err)
	}
	// The host verified the chain AND the Ed25519 CertificateVerify.
	res := <-done
	if res.err != nil {
		t.Fatalf("server handshake: %v", res.err)
	}
	srv := res.s
	if !srv.state.allowsApplicationData() {
		t.Fatal("server not connected after handshake")
	}

	// Application data both ways.
	if _, err := cli.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 64)
	n, err := srv.read(buf)
	if err != nil {
		t.Fatalf("server read: %v", err)
	}
	if string(buf[:n]) != "ping" {
		t.Fatalf("server read %q", buf[:n])
	}
	if err := srv.write([]byte("echo:ping")); err != nil {
		t.Fatal(err)
	}
	n, err = cli.Read(buf)
	if err != nil {
		t.Fatalf("client read: %v", err)
	}
	if string(buf[:n]) != "echo:ping" {
		t.Fatalf("client read %q", buf[:n])
	}
	_ = cli.Close()
	_ = srv.close()
}

func TestServerGuestClientRoundTrip(t *testing.T) {
	// Guest-shaped client (in-process over the loopback transport seam)
	// against the server — the Ed25519 chain-verification path end to end.
	der, seed := buildEd25519Cert(t, []string{"virelai.example"}, nil)
	host, done := serverPair(t, ServerConfig{Chain: [][]byte{der}, Ed25519Seed: seed})

	store := newTrustStore("test")
	if err := store.addRoot(der); err != nil {
		t.Fatal(err)
	}
	cl := newClient(&netTransport{conn: host}, "virelai.example", time.Now().Unix(), func(p []byte) error {
		_, err := rand.Read(p)
		return err
	}, true)
	cl.store = store
	if err := cl.handshake(); err != nil {
		t.Fatalf("guest client handshake: %v", err)
	}
	if cl.lastValidation != resultValid {
		t.Fatalf("verdict %v", cl.lastValidation)
	}
	res := <-done
	if res.err != nil {
		t.Fatalf("server handshake: %v", res.err)
	}
	srv := res.s
	// Bidirectional app data over the established channel.
	if err := cl.write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 64)
	n, err := srv.read(buf)
	if err != nil || string(buf[:n]) != "hello" {
		t.Fatalf("server read n=%d err=%v", n, err)
	}
	if err := srv.write([]byte("world")); err != nil {
		t.Fatal(err)
	}
	n, err = cl.read(buf)
	if err != nil || string(buf[:n]) != "world" {
		t.Fatalf("client read n=%d err=%v", n, err)
	}
	_ = cl.close()
}

// patchCH rewrites the first occurrence of old with new inside a built
// ClientHello handshake message — the test's way to offer a hostile CH
// without reimplementing the encoder.
func patchCH(ch, old, new []byte) []byte {
	i := bytes.Index(ch, old)
	if i < 0 {
		return nil
	}
	out := append([]byte(nil), ch[:i]...)
	out = append(out, new...)
	return append(out, ch[i+len(old):]...)
}

// rawClientHello drives the hostile-CH negatives: write one plaintext
// handshake record carrying the (possibly patched) ClientHello, read the
// one alert record the server must answer with.
func rawClientHello(t *testing.T, ch []byte) (desc byte, closed bool) {
	t.Helper()
	der, seed := buildEd25519Cert(t, []string{"virelai.example"}, nil)
	host, done := serverPair(t, ServerConfig{Chain: [][]byte{der}, Ed25519Seed: seed})
	defer host.Close()

	rec := make([]byte, 5+len(ch))
	rec[0] = ctHandshake
	rec[1], rec[2] = 0x03, 0x03
	rec[3] = byte(len(ch) >> 8)
	rec[4] = byte(len(ch))
	copy(rec[5:], ch)
	if _, err := host.Write(rec); err != nil {
		t.Fatalf("write CH: %v", err)
	}
	ans := make([]byte, 64)
	n, err := host.Read(ans)
	if err != nil {
		t.Fatalf("read alert: %v", err)
	}
	if n < 7 || ans[0] != ctAlert {
		t.Fatalf("answer is not an alert record: %x", ans[:n])
	}
	desc = ans[6]
	res := <-done
	if res.err == nil {
		t.Fatal("server accepted a hostile ClientHello")
	}
	name, ok := ServerAlertName(res.err)
	if !ok || name != alertName(desc) {
		t.Fatalf("server error %v names %q, wire sent desc %d (%q)", res.err, name, desc, alertName(desc))
	}
	return desc, true
}

func goodCH(t *testing.T) []byte {
	cl := &client{}
	var random, sessionID, pub [32]byte
	for i := range random {
		random[i] = byte(i)
		sessionID[i] = byte(i + 1)
		pub[i] = byte(i + 2)
	}
	return cl.buildClientHello(random, sessionID, pub)
}

func TestServerTLS12OnlyClient(t *testing.T) {
	// supported_versions 0x0304 -> 0x0303: a TLS 1.2-only offer.
	ch := goodCH(t)
	patched := patchCH(ch, []byte{0x00, 0x2b, 0x00, 0x03, 0x02, 0x03, 0x04},
		[]byte{0x00, 0x2b, 0x00, 0x03, 0x02, 0x03, 0x03})
	if patched == nil {
		t.Fatal("supported_versions pattern not found")
	}
	desc, _ := rawClientHello(t, patched)
	if desc != alertDescProtocolVersion {
		t.Fatalf("TLS1.2-only got alert %q, want protocol_version", alertName(desc))
	}
}

func TestServerNoSharedSuite(t *testing.T) {
	// cipher_suites [0x1301] -> [0x1302] (AES_256_GCM only): no shared suite.
	ch := goodCH(t)
	patched := patchCH(ch, []byte{0x00, 0x02, 0x13, 0x01}, []byte{0x00, 0x02, 0x13, 0x02})
	if patched == nil {
		t.Fatal("cipher_suites pattern not found")
	}
	desc, _ := rawClientHello(t, patched)
	if desc != alertDescHandshakeFailure {
		t.Fatalf("no-shared-suite got alert %q, want handshake_failure", alertName(desc))
	}
}

func TestServerNoX25519Share(t *testing.T) {
	// key_share entry group 0x001d -> 0x0017 (secp256r1): a share we cannot
	// use, and HelloRetryRequest is out of scope.
	ch := goodCH(t)
	patched := patchCH(ch, []byte{0x00, 0x1d, 0x00, 0x20}, []byte{0x00, 0x17, 0x00, 0x20})
	if patched == nil {
		t.Fatal("key_share pattern not found")
	}
	desc, _ := rawClientHello(t, patched)
	if desc != alertDescHandshakeFailure {
		t.Fatalf("no-x25519-share got alert %q, want handshake_failure", alertName(desc))
	}
}

func TestServerBadClientFinished(t *testing.T) {
	der, seed := buildEd25519Cert(t, []string{"virelai.example"}, nil)
	host, done := serverPair(t, ServerConfig{Chain: [][]byte{der}, Ed25519Seed: seed})

	store := newTrustStore("test")
	_ = store.addRoot(der)
	cl := newClient(&netTransport{conn: host}, "virelai.example", time.Now().Unix(), func(p []byte) error {
		_, err := rand.Read(p)
		return err
	}, false) // verify off: the point is the server's Finished check
	cl.store = store
	cl.corruptFinished = true
	// The client's handshake returns after ITS Finished goes out — it never
	// waits for a post-Finished ack — so nil here is expected; the verdict
	// is the server's refusal and the alert it then surfaces on read.
	err := cl.handshake()
	if err != nil {
		// The server may have raced the alert back before the client
		// returned — also a pass shape.
		_ = host.Close()
	} else {
		// Established-looking conn must still die on the alert.
		_, rerr := cl.read(make([]byte, 8))
		if rerr != ErrAlertReceived {
			t.Fatalf("post-handshake read = %v, want ErrAlertReceived", rerr)
		}
	}
	res := <-done
	if res.err == nil {
		t.Fatal("server accepted a bad client Finished")
	}
	if name, ok := ServerAlertName(res.err); !ok || name != "decrypt_error" {
		t.Fatalf("bad Finished alert = %v (%q), want decrypt_error", res.err, name)
	}
}

func TestServerConfigRejectsWrongSeed(t *testing.T) {
	der, _ := buildEd25519Cert(t, []string{"virelai.example"}, nil)
	var wrong [32]byte
	wrong[0] = 1
	cfg := ServerConfig{Chain: [][]byte{der}, Ed25519Seed: wrong}
	if err := cfg.check(); err != errServerKeyMismatch {
		t.Fatalf("wrong seed: %v", err)
	}
	cfg.Ed25519Seed = [32]byte{}
	if err := cfg.check(); err != errServerKeyMismatch {
		t.Fatalf("zero seed: %v", err)
	}
	cfg.Chain = nil
	if err := cfg.check(); err != errServerNoCert {
		t.Fatalf("no cert: %v", err)
	}
	cfg = ServerConfig{Chain: [][]byte{[]byte{0x30, 0x00}}, Ed25519Seed: wrong}
	if err := cfg.check(); err == nil {
		t.Fatal("garbage DER accepted")
	}
}
