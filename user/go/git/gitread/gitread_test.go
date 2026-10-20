package gitread

import (
	"bytes"
	"crypto/sha1"
	"testing"
	"virelai/flate"
)

func TestSHA1MatchesStdlib(t *testing.T) {
	cases := [][]byte{
		nil,
		[]byte(""),
		[]byte("abc"),
		[]byte("hello, git\n"),
		bytes.Repeat([]byte("x"), 1000),
	}
	for _, c := range cases {
		got := sha1Sum(c)
		want := sha1.Sum(c)
		if got != want {
			t.Fatalf("sha1(%q) = %x want %x", c, got, want)
		}
	}
}

func TestHexRoundTrip(t *testing.T) {
	sum := sha1Sum([]byte("blob"))
	s := HexEncode(sum[:])
	if len(s) != 40 {
		t.Fatalf("hex len %d", len(s))
	}
	back, ok := HexDecode(s)
	if !ok || back != sum {
		t.Fatalf("HexDecode(%q) = %x ok=%v", s, back, ok)
	}
	if _, ok := HexDecode("zz"); ok {
		t.Fatal("bad hex accepted")
	}
}

func TestDeltaCopyInsert(t *testing.T) {
	base := []byte("hello, git\n")
	target := []byte("hello, git!\n")
	d := encodeDelta(base, target)
	got, err := applyDelta(base, d)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, target) {
		t.Fatalf("delta = %q want %q", got, target)
	}
}

func TestPackRefDelta(t *testing.T) {
	blob1 := GitObj{Type: ObjBlob, Data: []byte("hello, git\n")}
	blob1.ID = HashObject(ObjBlob, blob1.Data)
	blob2 := GitObj{Type: ObjBlob, Data: []byte("hello, git!\n")}
	blob2.ID = HashObject(ObjBlob, blob2.Data)
	tree := GitObj{Type: ObjTree, Data: encodeTree([]TreeEnt{{Mode: "100644", Name: "HELLO", ID: blob2.ID}})}
	tree.ID = HashObject(ObjTree, tree.Data)
	commitData := []byte("tree " + HexEncode(tree.ID[:]) + "\n" +
		"author g <g@g> 1000000000 +0000\n" +
		"committer g <g@g> 1000000000 +0000\n\nsecond\n")
	commit := GitObj{Type: ObjCommit, Data: commitData}
	commit.ID = HashObject(ObjCommit, commit.Data)

	objs := []GitObj{blob1, blob2, tree, commit}
	deltaFrom := []int{-1, 0, -1, -1}
	pack := PackObjects(objs, deltaFrom, nil)
	got, nDelta, err := ParsePack(pack)
	if err != nil {
		t.Fatal(err)
	}
	if nDelta != 1 {
		t.Fatalf("nDelta = %d want 1", nDelta)
	}
	if len(got) != 4 {
		t.Fatalf("len = %d", len(got))
	}
	if got[1].ID != blob2.ID || !bytes.Equal(got[1].Data, blob2.Data) {
		t.Fatalf("delta blob mismatch %x vs %x", got[1].ID, blob2.ID)
	}
	if got[2].ID != tree.ID || got[3].ID != commit.ID {
		t.Fatalf("tree/commit ids")
	}
}

func TestPackOfsDelta(t *testing.T) {
	blob1 := GitObj{Type: ObjBlob, Data: []byte("hello, git\n")}
	blob1.ID = HashObject(ObjBlob, blob1.Data)
	blob2 := GitObj{Type: ObjBlob, Data: []byte("hello, git!\n")}
	blob2.ID = HashObject(ObjBlob, blob2.Data)
	objs := []GitObj{blob1, blob2}
	pack := PackObjects(objs, []int{-1, 0}, []bool{false, true})
	got, nDelta, err := ParsePack(pack)
	if err != nil {
		t.Fatal(err)
	}
	if nDelta != 1 {
		t.Fatalf("nDelta = %d want 1", nDelta)
	}
	if got[1].ID != blob2.ID || !bytes.Equal(got[1].Data, blob2.Data) {
		t.Fatalf("ofs-delta blob mismatch")
	}
}

// TestParsePackThinExternalBase is the fetch case (#2203): a ref-delta
// whose base the pack does not carry. ParsePack must refuse it honestly
// and ParsePackThin must resolve it through the object-store lookup.
func TestParsePackThinExternalBase(t *testing.T) {
	base := GitObj{Type: ObjBlob, Data: []byte("hello, git\n")}
	base.ID = HashObject(ObjBlob, base.Data)
	target := []byte("hello, git!\n")
	d := encodeDelta(base.Data, target)
	z := flate.ZlibStore(d)
	var body []byte
	body = append(body, encodePackHdr(ObjRefDelta, len(d))...)
	body = append(body, base.ID[:]...)
	body = append(body, z...)
	hdr := make([]byte, 12)
	copy(hdr, "PACK")
	putBE32(hdr[4:], 2)
	putBE32(hdr[8:], 1)
	all := append(hdr, body...)
	sum := sha1Sum(all)
	pack := append(all, sum[:]...)

	if _, _, err := ParsePack(pack); err != errPackDelta {
		t.Fatalf("ParsePack on thin pack = %v want errPackDelta", err)
	}
	if _, _, err := ParsePackThin(pack, func(id [20]byte) (GitObj, bool) {
		return GitObj{}, false
	}); err != errPackDelta {
		t.Fatalf("ParsePackThin missing base = %v want errPackDelta", err)
	}
	got, nDelta, err := ParsePackThin(pack, func(id [20]byte) (GitObj, bool) {
		if id == base.ID {
			return base, true
		}
		return GitObj{}, false
	})
	if err != nil {
		t.Fatal(err)
	}
	if nDelta != 1 || len(got) != 1 {
		t.Fatalf("nDelta=%d len=%d", nDelta, len(got))
	}
	if got[0].Type != ObjBlob || !bytes.Equal(got[0].Data, target) {
		t.Fatalf("thin delta data = %q", got[0].Data)
	}
	if got[0].ID != HashObject(ObjBlob, target) {
		t.Fatalf("thin delta id = %x", got[0].ID)
	}
}

// TestParsePackThinInPackBase — a base that arrives in the SAME pack but
// unresolved must not be snatched from the store; the in-pack copy wins.
func TestParsePackThinInPackBase(t *testing.T) {
	base := GitObj{Type: ObjBlob, Data: []byte("hello, git\n")}
	base.ID = HashObject(ObjBlob, base.Data)
	target := []byte("hello, git!\n")
	d := encodeDelta(base.Data, target)
	z := flate.ZlibStore(d)
	var body []byte
	// delta first, base second — forces the pass-ordering path.
	body = append(body, encodePackHdr(ObjRefDelta, len(d))...)
	body = append(body, base.ID[:]...)
	body = append(body, z...)
	body = append(body, encodePackHdr(ObjBlob, len(base.Data))...)
	body = append(body, flate.ZlibStore(base.Data)...)
	hdr := make([]byte, 12)
	copy(hdr, "PACK")
	putBE32(hdr[4:], 2)
	putBE32(hdr[8:], 2)
	all := append(hdr, body...)
	sum := sha1Sum(all)
	pack := append(all, sum[:]...)
	got, _, err := ParsePackThin(pack, func(id [20]byte) (GitObj, bool) {
		return GitObj{}, false // store has nothing: in-pack must resolve
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || !bytes.Equal(got[0].Data, target) || !bytes.Equal(got[1].Data, base.Data) {
		t.Fatalf("got = %+v", got)
	}
}

func TestOfsRoundTrip(t *testing.T) {
	for _, v := range []int{1, 2, 127, 128, 129, 1000, 20000} {
		enc := encodeOfs(v)
		off, n, err := readOfsDelta(enc)
		if err != nil || n != len(enc) || off != v {
			t.Fatalf("ofs %d: got %d n=%d err=%v enc=%x", v, off, n, err, enc)
		}
	}
}

func TestObjectPathFits(t *testing.T) {
	id := HashObject(ObjBlob, []byte("hello, git!\n"))
	p, ok := ObjectPath("/host/G/.git", id)
	if !ok {
		t.Fatal("object path refused")
	}
	if len(p) > maxPath {
		t.Fatalf("path len %d > %d: %s", len(p), maxPath, p)
	}
	ents := ParseTree(encodeTree([]TreeEnt{{Mode: "100644", Name: "HELLO", ID: id}}))
	if len(ents) != 1 || ents[0].Name != "HELLO" || ents[0].ID != id {
		t.Fatalf("tree ents = %+v", ents)
	}
}

func TestLooseObjectInflates(t *testing.T) {
	o := GitObj{Type: ObjBlob, Data: []byte("hello, git\n")}
	o.ID = HashObject(ObjBlob, o.Data)
	z := LooseBytes(o)
	out := make([]byte, 64)
	n, _, err := flate.InflateZlib(out, z)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(out[:n], []byte("blob ")) || !bytes.Contains(out[:n], o.Data) {
		t.Fatalf("loose = %q", out[:n])
	}
}
