package store

import (
	"strings"
	"testing"

	"virelai/sshlib"
	"virelai/vi"
)

// M116c (#2469, ADR 0054 Part II D10): install-time consent verbs —
// `store consent` lands the recorded ask's row through the admin slot,
// `store decline` leaves the ambient floor standing. The table itself
// stays behind grantWriteFn, stubbed like the M113d tests.

// seedConsentStore writes a STORE.TXT carrying one installed app.
func seedConsentStore(t *testing.T, caps string) *memFS {
	t.Helper()
	fs := newMemFS()
	sum := sshlib.SHA256Sum(testELF)
	if err := writeStateEntry(fs, &storeEntry{
		Name: "GOHELLO.ELF", Stream: "rel", Head: "h1",
		SHA256: sshlib.EncodeHex(sum[:]), Caps: caps,
	}); err != nil {
		t.Fatalf("seed state: %v", err)
	}
	return fs
}

func TestConsentWritesRecordedRow(t *testing.T) {
	fs := seedConsentStore(t, "net,file")
	lines, restore := collectConsole()
	defer restore()
	var writes []string
	prev := grantWriteFn
	grantWriteFn = func(line string) int64 { writes = append(writes, line); return 0 }
	defer func() { grantWriteFn = prev }()

	if rc := Consent(fs, "GOHELLO"); rc != 0 {
		t.Fatalf("consent rc=%d lines=%v", rc, *lines)
	}
	if len(writes) != 1 {
		t.Fatalf("writes=%v want exactly one row", writes)
	}
	sum := sshlib.SHA256Sum(testELF)
	want := "GOHELLO.ELF\t" + sshlib.EncodeHex(sum[:]) + "\tfile,net"
	if writes[0] != want {
		t.Fatalf("row %q want %q", writes[0], want)
	}
	var echo, written bool
	for _, l := range *lines {
		echo = echo || l == "store: consent GOHELLO.ELF"
		written = written || l == "store: grant written name=GOHELLO.ELF words=file,net"
	}
	if !echo || !written {
		t.Fatalf("markers missing in %v", *lines)
	}
}

func TestConsentLineRefusals(t *testing.T) {
	fs := seedConsentStore(t, "")
	if _, err := ConsentLine(fs, "GOHELLO.ELF"); err == nil {
		t.Fatal("empty caps did not refuse")
	} else {
		refuseCode(t, err, "no_ask")
	}
	if _, err := ConsentLine(fs, "OTHER.ELF"); err == nil {
		t.Fatal("unknown bin did not refuse")
	} else {
		refuseCode(t, err, "not_installed")
	}
}

func TestConsentRefusals(t *testing.T) {
	fs := seedConsentStore(t, "file")
	lines, restore := collectConsole()
	defer restore()

	if rc := Consent(fs, "not a bin"); rc != 1 {
		t.Fatalf("name_invalid rc=%d", rc)
	}
	if rc := Consent(fs, "MISSING"); rc != 1 {
		t.Fatalf("not_installed rc=%d", rc)
	}
	var badName, missing bool
	for _, l := range *lines {
		badName = badName || strings.HasPrefix(l, "store: refuse name_invalid")
		missing = missing || strings.HasPrefix(l, "store: refuse not_installed")
	}
	if !badName || !missing {
		t.Fatalf("named refusals missing in %v", *lines)
	}
}

func TestConsentWriteRefused(t *testing.T) {
	fs := seedConsentStore(t, "file")
	lines, restore := collectConsole()
	defer restore()
	prev := grantWriteFn
	grantWriteFn = func(string) int64 { return -vi.ErrEACCES }
	defer func() { grantWriteFn = prev }()

	if rc := Consent(fs, "GOHELLO"); rc != 1 {
		t.Fatalf("eacces rc=%d", rc)
	}
	var got bool
	for _, l := range *lines {
		got = got || l == "store: refuse eacces"
	}
	if !got {
		t.Fatalf("eacces refusal missing in %v", *lines)
	}
}

func TestDeclineWritesNothing(t *testing.T) {
	fs := seedConsentStore(t, "file,net")
	lines, restore := collectConsole()
	defer restore()
	var writes int
	prev := grantWriteFn
	grantWriteFn = func(string) int64 { writes++; return 0 }
	defer func() { grantWriteFn = prev }()

	if rc := Decline(fs, "GOHELLO"); rc != 0 {
		t.Fatalf("decline rc=%d lines=%v", rc, *lines)
	}
	if writes != 0 {
		t.Fatalf("decline wrote %d rows", writes)
	}
	var declined bool
	for _, l := range *lines {
		declined = declined || l == "store: consent declined name=GOHELLO.ELF"
	}
	if !declined {
		t.Fatalf("declined marker missing in %v", *lines)
	}
	// A decline for a bin with no pending ask refuses like consent does.
	if rc := Decline(fs, "MISSING"); rc != 1 {
		t.Fatalf("decline not_installed rc=%d", rc)
	}
}
