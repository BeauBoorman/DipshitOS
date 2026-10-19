// M124e (#2584): the primary-selection wire — envelope codec round-trips
// and refusals, the rendezvous path's spelling, and the client half's
// honest off-guest behavior (no seat: publish/pull refuse, take of a
// staged envelope still consumes it).
package vi

import "testing"

func TestSelPath(t *testing.T) {
	if p := SelPath(7); p != "/host/SEL.7" {
		t.Fatalf("SelPath(7) = %q", p)
	}
}

func TestSelCodecRoundTrip(t *testing.T) {
	for _, text := range []string{"", "a", "the selected paragraph\n"} {
		enc, ok := EncodeSel([]byte(text))
		if !ok {
			t.Fatalf("EncodeSel(%q) refused", text)
		}
		got, ok := DecodeSel(enc)
		if !ok || string(got) != text {
			t.Fatalf("round-trip %q -> %q ok=%v", text, got, ok)
		}
	}
}

func TestSelCodecRefusals(t *testing.T) {
	if _, ok := EncodeSel(make([]byte, SelMax+1)); ok {
		t.Fatal("EncodeSel over SelMax did not refuse")
	}
	if _, ok := DecodeSel([]byte{1, 2}); ok {
		t.Fatal("DecodeSel short header did not refuse")
	}
	if _, ok := DecodeSel([]byte{0xff, 0xff, 0xff, 0xff}); ok {
		t.Fatal("DecodeSel over-bound length did not refuse")
	}
	enc, _ := EncodeSel([]byte("hello"))
	if _, ok := DecodeSel(enc[:len(enc)-1]); ok {
		t.Fatal("DecodeSel truncated envelope did not refuse")
	}
	if _, ok := DecodeSel(append(append([]byte{}, enc...), 0)); ok {
		t.Fatal("DecodeSel trailing byte did not refuse")
	}
}

// A refused publish must still stage-then-clean its own slot: off-guest
// the request has no seat to answer, so SelPublish is false AND the staged
// file is deleted — the handoff was never claimed.
func TestSelPublishNoSeatCleansStage(t *testing.T) {
	files := map[string][]byte{}
	oldW, oldR, oldD := selFileWrite, selFileRead, selFileDelete
	defer func() { selFileWrite, selFileRead, selFileDelete = oldW, oldR, oldD }()
	selFileWrite = func(path string, b []byte) int64 {
		files[path] = append([]byte(nil), b...)
		return 0
	}
	selFileRead = func(path string, max int) ([]byte, int64) {
		b, ok := files[path]
		if !ok {
			return nil, -2
		}
		return append([]byte(nil), b...), int64(len(b))
	}
	var deleted []string
	selFileDelete = func(path string) int64 {
		if _, ok := files[path]; !ok {
			return -2
		}
		delete(files, path)
		deleted = append(deleted, path)
		return 0
	}
	if SelPublish(9, []byte("primary"), "TEST.ELF") {
		t.Fatal("SelPublish off-guest must refuse (no seat)")
	}
	if len(files) != 0 || len(deleted) != 1 || deleted[0] != SelPath(9) {
		t.Fatalf("staging not cleaned: files=%v deleted=%v", files, deleted)
	}
	if _, ok := RequestSelPaste(9, "TEST.ELF"); ok {
		t.Fatal("RequestSelPaste off-guest must refuse (no seat)")
	}
}

// SelTake is consume-on-use even without a seat: read, delete, decode.
func TestSelTakeConsumes(t *testing.T) {
	enc, _ := EncodeSel([]byte("sel bytes"))
	files := map[string][]byte{SelPath(4): enc}
	oldR, oldD := selFileRead, selFileDelete
	defer func() { selFileRead, selFileDelete = oldR, oldD }()
	selFileRead = func(path string, max int) ([]byte, int64) {
		b, ok := files[path]
		if !ok {
			return nil, -2
		}
		return append([]byte(nil), b...), int64(len(b))
	}
	selFileDelete = func(path string) int64 {
		delete(files, path)
		return 0
	}
	got, ok := SelTake(4)
	if !ok || string(got) != "sel bytes" {
		t.Fatalf("SelTake = %q ok=%v", got, ok)
	}
	if _, ok := SelTake(4); ok {
		t.Fatal("consumed handoff must find nothing")
	}
}
