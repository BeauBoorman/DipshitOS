package main

// ADR 0052 D1: the AGENTS.TXT grammar — valid rows, the fail-closed
// malformed matrix, revocation semantics, and the bounds.

import (
	"strings"
	"testing"

	"virelai/vi"
)

func TestKeyringParseGreen(t *testing.T) {
	kr, ok := keyringParse([]byte(
		"#v1\n" +
			"# a comment and a blank line follow\n" +
			"\n" +
			"agent=devin key=" + pinnedPubHex + " caps=file,process,window,term\n" +
			"agent=bobby key=" + strings.Repeat("11", 32) + " caps=file\n" +
			"agent=nobody key=" + strings.Repeat("22", 32) + "\n" +
			"revoked=" + strings.Repeat("33", 32) + "\n"))
	if !ok {
		t.Fatal("valid keyring refused")
	}
	row := kr.lookup("devin")
	if row == nil || row.pub[0] != 0xd7 {
		t.Fatalf("devin row = %+v", row)
	}
	for _, c := range []string{"file", "process", "window", "term"} {
		if !row.caps[c] {
			t.Fatalf("devin missing cap %s", c)
		}
	}
	if len(row.list) != 4 || row.list[0] != "file" {
		t.Fatalf("declared order = %v", row.list)
	}
	// caps absent is a valid row with an empty grant set.
	if r := kr.lookup("nobody"); r == nil || len(r.caps) != 0 || len(r.list) != 0 {
		t.Fatalf("caps-less row = %+v", r)
	}
	if kr.lookup("mallory") != nil {
		t.Fatal("unlisted id resolved")
	}
	var want [32]byte
	for i := range want {
		want[i] = 0x33
	}
	if !kr.revoked[want] {
		t.Fatal("revoked row missing")
	}
}

func TestKeyringParseMalformed(t *testing.T) {
	p := pinnedPubHex
	q := strings.Repeat("11", 32)
	for _, body := range []string{
		"",                             // no header
		"#v2\nagent=a key=" + p + "\n", // newer header
		"agent=a key=" + p + "\n",      // header missing entirely
		"#v1\nagent=a\n",               // agent row without key
		"#v1\nagent=a key=" + p + " caps=file extra\n",               // trailing field
		"#v1\nkey=" + p + " agent=a\n",                               // wrong field order
		"#v1\nagent= key=" + p + "\n",                                // empty id
		"#v1\nagent=-x key=" + p + "\n",                              // id not a NAME
		"#v1\nagent=" + strings.Repeat("a", 33) + " key=" + p + "\n", // id over bound
		"#v1\nagent=a key=zz\n",                                      // bad hex
		"#v1\nagent=a key=" + p[:62] + "\n",                          // short key
		"#v1\nagent=a key=" + p + p + "\n",                           // long key
		"#v1\nagent=a key=" + p + " caps=nope\n",                     // unknown cap
		"#v1\nagent=a key=" + p + " caps=file,file\n",                // duplicate cap
		"#v1\nagent=a key=" + p + " caps=file,,process\n",            // empty cap word
		"#v1\nagent=a key=" + p + "\nagent=a key=" + q + "\n",        // dup id
		"#v1\nagent=a key=" + p + "\nagent=b key=" + p + "\n",        // dup key
		"#v1\nrevoked=" + p + "\nrevoked=" + p + "\n",                // dup revoked
		"#v1\nrevoked=\n",                                            // empty revoked
		"#v1\nrevoked=" + p + " extra\n",                             // revoked with tail
		"#v1\nfoo=bar\n",                                             // unknown row shape
		"#v1\nagent=a key=" + strings.ToUpper(p) + "\n",              // uppercase key hex
	} {
		if _, ok := keyringParse([]byte(body)); ok {
			t.Fatalf("malformed accepted: %q", body)
		}
	}
}

func TestKeyringParseBounds(t *testing.T) {
	// 64 agent rows fit; the 65th fails the file. Keys are made distinct
	// by suffix so the duplicate-key check stays quiet.
	build := func(n int) string {
		var b strings.Builder
		b.WriteString("#v1\n")
		for i := 0; i < n; i++ {
			key := strings.Repeat("ab", 30) + hexDigits[i>>4:i>>4+1] + hexDigits[i&0xf:i&0xf+1] + "00"
			b.WriteString("agent=id")
			b.WriteString(vi.Itoa64(int64(i)))
			b.WriteString(" key=")
			b.WriteString(key)
			b.WriteString("\n")
		}
		return b.String()
	}
	if _, ok := keyringParse([]byte(build(64))); !ok {
		t.Fatal("64 agent rows refused")
	}
	if _, ok := keyringParse([]byte(build(65))); ok {
		t.Fatal("65 agent rows accepted")
	}
	// The same bound on the revoked list.
	var b strings.Builder
	b.WriteString("#v1\n")
	for i := 0; i < 65; i++ {
		key := strings.Repeat("cd", 30) + hexDigits[i>>4:i>>4+1] + hexDigits[i&0xf:i&0xf+1] + "00"
		b.WriteString("revoked=" + key + "\n")
	}
	if _, ok := keyringParse([]byte(b.String())); ok {
		t.Fatal("65 revoked rows accepted")
	}
}

// keyringLoad reports missing/malformed by name for the posture checks.
func TestKeyringLoadVerdicts(t *testing.T) {
	seamScope(t)
	old := readFileFn
	t.Cleanup(func() { readFileFn = old })
	readFileFn = func(path string, max int) ([]byte, int64) {
		return nil, -vi.ErrENOENT
	}
	if _, code := keyringLoad(); code != "missing" {
		t.Fatalf("absent = %q", code)
	}
	readFileFn = func(path string, max int) ([]byte, int64) {
		return []byte("not a keyring"), 13
	}
	if _, code := keyringLoad(); code != "malformed" {
		t.Fatalf("garbage = %q", code)
	}
	readFileFn = func(path string, max int) ([]byte, int64) {
		return []byte("#v1\n" + strings.Repeat("x", keyringMax)), int64(keyringMax + 1)
	}
	if _, code := keyringLoad(); code != "malformed" {
		t.Fatalf("oversized = %q", code)
	}
	readFileFn = func(path string, max int) ([]byte, int64) {
		return []byte(keyringBody()), int64(len(keyringBody()))
	}
	if kr, code := keyringLoad(); code != "" || kr.lookup(pinnedAgent) == nil {
		t.Fatalf("good = %q", code)
	}
}
