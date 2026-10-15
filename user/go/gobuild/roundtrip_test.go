package main

import (
	"os"
	"testing"
)

// The generated GOPKGS.TXT must parse through the driver's own table reader —
// the staged artifact and the parser are the two ends of the M107b contract,
// and drift between them fails the fleet with a bad_pkgdb a boot late. Skips
// when the staging output is absent (the fork toolchain is a host
// prerequisite, same as the e2e test).
func TestRealPkgTableParses(t *testing.T) {
	b, err := os.ReadFile("../../../.build/go/selfhost/GOPKGS.TXT")
	if err != nil {
		t.Skip(".build/go/selfhost/GOPKGS.TXT missing — stage with " +
			"bash tools/go/stage-selfhost.sh")
	}
	m, d := parsePkgTable(string(b))
	if d.Code != "" {
		t.Fatalf("the staged table must parse, got %+v", d)
	}
	if !m["fmt"].known || m["fmt"].denied {
		t.Fatalf("fmt must be known-and-not-denied, got %+v", m["fmt"])
	}
	if !m["crypto/x509"].denied {
		t.Fatalf("crypto/x509 must be denied, got %+v", m["crypto/x509"])
	}
	var denied int
	for _, r := range m {
		if r.denied {
			denied++
		}
	}
	if len(m) < 300 || denied == 0 {
		t.Fatalf("staged table should cover the std universe: %d rows, %d denied",
			len(m), denied)
	}
	t.Logf("staged table: %d rows, %d denied", len(m), denied)
}
