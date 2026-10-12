package sshlib

import (
	"bytes"
	"testing"
)

func mustHexB(t *testing.T, s string) []byte {
	t.Helper()
	b, ok := ParseHex(s)
	if !ok {
		t.Fatalf("bad hex %q", s)
	}
	return b
}

func mustHex32B(t *testing.T, s string) [32]byte {
	t.Helper()
	v, ok := ParseHex32(s)
	if !ok {
		t.Fatalf("bad hex32 %q", s)
	}
	return v
}

// Writer→Reader round trips pin the wire encoding; the negatives pin that a
// truncated or malformed buffer is refused, never partially consumed.
func TestWireWriterReaderRoundTrip(t *testing.T) {
	var w Writer
	w.Byte(0x14)
	w.BoolVal(true)
	w.BoolVal(false)
	w.U32(0xdeadbeef)
	w.Str([]byte{0xaa, 0xbb})
	w.StrS("ssh-ed25519")
	w.NameList([]string{"curve25519-sha256", "curve25519-sha256@libssh.org"})
	w.NameList(nil)
	w.Raw([]byte{0x01, 0x02, 0x03})

	r := Reader{B: w.B}
	if b, ok := r.Byte(); !ok || b != 0x14 {
		t.Fatalf("byte = %x ok=%v", b, ok)
	}
	if v, ok := r.BoolVal(); !ok || !v {
		t.Fatalf("bool true = %v ok=%v", v, ok)
	}
	if v, ok := r.BoolVal(); !ok || v {
		t.Fatalf("bool false = %v ok=%v", v, ok)
	}
	if v, ok := r.U32(); !ok || v != 0xdeadbeef {
		t.Fatalf("u32 = %x ok=%v", v, ok)
	}
	if s, ok := r.Str(); !ok || !bytes.Equal(s, []byte{0xaa, 0xbb}) {
		t.Fatalf("str = %x ok=%v", s, ok)
	}
	if s, ok := r.StrUTF8(); !ok || s != "ssh-ed25519" {
		t.Fatalf("strutf8 = %q ok=%v", s, ok)
	}
	want := []string{"curve25519-sha256", "curve25519-sha256@libssh.org"}
	nl, ok := r.NameList()
	if !ok || len(nl) != 2 || nl[0] != want[0] || nl[1] != want[1] {
		t.Fatalf("namelist = %v ok=%v", nl, ok)
	}
	if nl, ok := r.NameList(); !ok || nl != nil {
		t.Fatalf("empty namelist = %v ok=%v", nl, ok)
	}
	if r.Remaining() != 3 {
		t.Fatalf("remaining = %d want 3", r.Remaining())
	}
}

func TestWireReaderNegatives(t *testing.T) {
	cases := []struct {
		name string
		buf  []byte
		read func(r *Reader) bool
	}{
		{"byte empty", nil, func(r *Reader) bool { _, ok := r.Byte(); return ok }},
		{"bool empty", nil, func(r *Reader) bool { _, ok := r.BoolVal(); return ok }},
		{"bool invalid", []byte{2}, func(r *Reader) bool { _, ok := r.BoolVal(); return ok }},
		{"u32 short", []byte{0, 0, 0}, func(r *Reader) bool { _, ok := r.U32(); return ok }},
		{"str short header", []byte{0, 0, 0}, func(r *Reader) bool { _, ok := r.Str(); return ok }},
		{"str overrun", []byte{0, 0, 0, 9, 'a'}, func(r *Reader) bool { _, ok := r.Str(); return ok }},
		{"strutf8 overrun", []byte{0, 0, 0, 4, 'a'}, func(r *Reader) bool { _, ok := r.StrUTF8(); return ok }},
		{"namelist overrun", []byte{0, 0, 0, 8, 'a'}, func(r *Reader) bool { _, ok := r.NameList(); return ok }},
	}
	for _, tc := range cases {
		r := Reader{B: tc.buf}
		if tc.read(&r) {
			t.Fatalf("%s accepted %x", tc.name, tc.buf)
		}
	}
	// "a,,b" carries an empty element — RFC 4251 §5 forbids it.
	var w Writer
	w.Str([]byte("a,,b"))
	r := Reader{B: w.B}
	if _, ok := r.NameList(); ok {
		t.Fatal("namelist with empty element accepted")
	}
	var w2 Writer
	w2.Str([]byte(",a"))
	r = Reader{B: w2.B}
	if _, ok := r.NameList(); ok {
		t.Fatal("namelist with leading comma accepted")
	}
	var w3 Writer
	w3.Str([]byte("a,"))
	r = Reader{B: w3.B}
	if _, ok := r.NameList(); ok {
		t.Fatal("namelist with trailing comma accepted")
	}
	// A failed read does not advance Pos past the end (the Str overrun case
	// leaves Pos after the consumed length header only).
	r = Reader{B: []byte{0, 0, 0, 9, 'a'}}
	if _, ok := r.Str(); ok || r.Pos != 4 {
		t.Fatalf("str overrun pos = %d", r.Pos)
	}
}

func TestContainsName(t *testing.T) {
	list := []string{"ssh-ed25519", "rsa-sha2-256"}
	if !ContainsName(list, "ssh-ed25519") {
		t.Fatal("present name missed")
	}
	if ContainsName(list, "ssh-rsa") {
		t.Fatal("absent name found")
	}
	if ContainsName(nil, "ssh-ed25519") {
		t.Fatal("nil list matched")
	}
}
