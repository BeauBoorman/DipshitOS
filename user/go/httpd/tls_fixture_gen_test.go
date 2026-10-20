package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestGenTLSFixture writes the HTTPS credential GOHTTPD --tls serves from
// the share: a DER self-signed Ed25519 certificate (CA:TRUE so the guest
// validator can anchor it, serverAuth EKU, SANs for the guest's NAT address
// and its gate name) plus the raw 32-byte seed that signs CertificateVerify.
// Host-stdlib crypto/x509 + crypto/ed25519 — the same pattern as
// user/go/store's fixture generator (fixture_gen_test.go).
//
//	HTTPD_TLS_GEN_FIXTURE=1   required, else skipped (gate setup hook sets it)
//	HTTPD_TLS_FIXTURE_DIR     output dir (default .)
//
// Writes TLS.CRT (DER) and TLS.SEED (32 raw bytes) into the dir.
func TestGenTLSFixture(t *testing.T) {
	if os.Getenv("HTTPD_TLS_GEN_FIXTURE") == "" {
		t.Skip("fixture generation is env-gated (the gate setup hook sets HTTPD_TLS_GEN_FIXTURE)")
	}
	dir := os.Getenv("HTTPD_TLS_FIXTURE_DIR")
	if dir == "" {
		dir = "."
	}

	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "virelai-https"},
		NotBefore:             time.Unix(1577836800, 0), // 2020-01-01
		NotAfter:              time.Unix(2524608000, 0), // 2050-01-01
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:              []string{"virelai-https.local"},
		IPAddresses:           []net.IP{net.ParseIP("10.0.0.1").To4()},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, pub, priv)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := x509.ParseCertificate(der); err != nil {
		t.Fatalf("generated cert does not re-parse: %v", err)
	}

	certPath := filepath.Join(dir, "TLS.CRT")
	seedPath := filepath.Join(dir, "TLS.SEED")
	if err := os.WriteFile(certPath, der, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(seedPath, priv.Seed(), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Logf("wrote %s (%d bytes DER) and %s (32-byte seed)", certPath, len(der), seedPath)
}
