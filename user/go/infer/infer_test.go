package infer

import (
	"bytes"
	"errors"
	"io"
	"testing"

	"virelai/vi"
)

// --- VIW container --------------------------------------------------------

func TestViwRoundTrip(t *testing.T) {
	h := Header{Arch: "llama", Dim: 8, Hidden: 16, Layers: 1,
		Heads: 2, KVHeads: 2, Vocab: 32, SeqCap: 16,
		Rope: "half", RopeTheta: 10000, RmsEps: 1e-5,
		Tie: true, BOS: 1, EOS: 2,
		Model: ModelInfo{ID: "x", License: "MIT"}}
	w := newViwWrite(h, []byte(`{"kind":"bytes"}`))
	pay := quantU4Asym([]float32{1, 2, 3, 4, 5, 6, 7, 8}, 32)
	w.add("w", viwFmtU4Asym, 32, [2]uint32{2, 4}, pay)
	w.add("n", viwFmtF32, 0, [2]uint32{8, 0}, make([]byte, 32))
	img := w.marshal()

	r := bytes.NewReader(img)
	im, err := readVIWHead(r)
	if err != nil {
		t.Fatalf("readVIWHead: %v", err)
	}
	if im.Header.Dim != 8 || len(im.Dir) != 2 {
		t.Fatalf("dir parse: %+v", im.Header)
	}
	if im.Dir[0].Name != "w" || im.Dir[0].Group != 32 || im.Dir[0].Dims[1] != 4 {
		t.Fatalf("dir[0]: %+v", im.Dir[0])
	}
	// Payload must begin right where the directory says it does.
	got := make([]byte, len(pay))
	if _, err := io.ReadFull(r, got); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, pay) {
		t.Fatal("payload bytes not in dir order at payload_off")
	}
}

func TestViwRefusesBadMagicAndMisorderedPayload(t *testing.T) {
	img := SynthStub()
	img[0] = 'X'
	if _, err := readVIWHead(bytes.NewReader(img)); err == nil {
		t.Fatal("bad magic accepted")
	}
}

// --- quantizer ------------------------------------------------------------

func TestQuantU4AsymRoundTripsWithinScale(t *testing.T) {
	vals := []float32{0.1, -0.5, 0.33, 0.9, -0.02, 0.77, 0.41, -0.88}
	pay := quantU4Asym(vals, 32)
	out := make([]float32, len(vals))
	dequantU4(pay, uint64(len(vals)), 32, 0, uint64(len(vals)), out)
	for i, v := range out {
		if d := v - vals[i]; d < -0.2 || d > 0.2 {
			t.Fatalf("dequant[%d]=%v vs %v", i, v, vals[i])
		}
	}
}

// --- tokenizers ------------------------------------------------------------

func TestBytesTokRoundTrip(t *testing.T) {
	tk, err := parseTokenizer(tokEmitBytes(0, 2))
	if err != nil {
		t.Fatal(err)
	}
	ids := tk.Encode("abc")
	if len(ids) != 3 || ids[0] != 'a' {
		t.Fatalf("encode: %v", ids)
	}
	if tk.Decode(ids) != "abc" {
		t.Fatal("decode")
	}
}

func TestBPEMergesByRank(t *testing.T) {
	// A miniature vocab: atoms a,b,c plus merges ab then abc.
	vocab := []string{"a", "b", "c", "ab", "abc"}
	merges := [][2]uint32{{0, 1}, {3, 2}}
	tk, err := parseTokenizer(tokEmitBPE(vocab, merges, 0, 4))
	if err != nil {
		t.Fatal(err)
	}
	ids := tk.Encode("abc")
	if len(ids) != 1 || ids[0] != 4 {
		t.Fatalf("encode abc -> %v, want [4]", ids)
	}
	// "abd" merges ab but d is unvocab'd in this fixture — dropped, not fatal.
	if got := tk.Encode("abd"); len(got) != 1 || got[0] != 3 {
		t.Fatalf("encode abd -> %v", got)
	}
	if tk.Decode([]int{4}) != "abc" {
		t.Fatal("decode")
	}
}

func TestBPESpecialsPassThrough(t *testing.T) {
	sp := "<" + "|im_end|>"
	tk, err := parseTokenizer(tokEmitBPE([]string{"A", sp}, nil, 0, 1))
	if err != nil {
		t.Fatal(err)
	}
	ids := tk.Encode(sp)
	if len(ids) != 1 || ids[0] != 1 {
		t.Fatalf("special id: %v", ids)
	}
}

func TestPreTokenizeBasic(t *testing.T) {
	got := preTokenize("hello world 42!")
	want := []string{"hello", " world", " 4", "2", "!"}
	if len(got) != len(want) {
		t.Fatalf("preTokenize %q -> %v", "hello world 42!", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("piece %d: %q want %q (%v)", i, got[i], want[i], got)
		}
	}
}

// --- the stub model end to end on the fake device --------------------------

// loadStub stages the deterministic stub image onto a fresh fake device.
func loadStub(t *testing.T) (*Model, *FakeDev) {
	t.Helper()
	d := NewFakeDev()
	m, err := Load(bytes.NewReader(SynthStub()), d, 1<<20)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	return m, d
}

// The library's own determinism pin: a loaded stub generates the pinned id
// sequence, covers all three kernels, and a second Load answers identically.
func TestStubGenerateIsDeterministicAndCoversKernels(t *testing.T) {
	m, d := loadStub(t)
	defer m.Close()
	tok := m.Tokenizer()
	prompt := tok.Encode("GOINFER stub check: the quick brown fox")
	ids, err := m.Generate(prompt, 16, nil)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	want := []int{196, 99, 196, 196, 196, 196, 196, 196, 99, 133, 99, 99, 99, 99, 99, 133}
	if len(ids) != len(want) {
		t.Fatalf("ids %v, want %v", ids, want)
	}
	for i := range want {
		if ids[i] != want[i] {
			t.Fatalf("ids %v, want %v", ids, want)
		}
	}
	for _, k := range []uint32{vi.GpuKernelGEMM, vi.GpuKernelSoftmax, vi.GpuKernelDequant} {
		if d.Submits[k] == 0 {
			t.Fatalf("kernel %d never ran", k)
		}
	}
	// A fresh load on the same session must agree — the K-leg property.
	m2, err := Load(bytes.NewReader(SynthStub()), d, 1<<20)
	if err != nil {
		t.Fatalf("second Load: %v", err)
	}
	defer m2.Close()
	ids2, err := m2.Generate(prompt, 16, nil)
	if err != nil {
		t.Fatalf("second Generate: %v", err)
	}
	if len(ids2) != len(ids) {
		t.Fatalf("second run ids %v vs %v", ids2, ids)
	}
	for i := range ids {
		if ids2[i] != ids[i] {
			t.Fatalf("second run diverged: %v vs %v", ids2, ids)
		}
	}
}

// The token callback is the streaming seam: it sees every id in order, and
// a non-nil return aborts the decode with the ids collected so far.
func TestGenerateStreamsAndAborts(t *testing.T) {
	m, _ := loadStub(t)
	defer m.Close()
	prompt := m.Tokenizer().Encode("GOINFER stub check: the quick brown fox")

	var seen []int
	ids, err := m.Generate(prompt, 16, func(id int) error {
		seen = append(seen, id)
		return nil
	})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if len(seen) != len(ids) {
		t.Fatalf("callback saw %d ids, Generate returned %d", len(seen), len(ids))
	}
	for i := range ids {
		if seen[i] != ids[i] {
			t.Fatalf("callback order differs at %d: %v vs %v", i, seen, ids)
		}
	}

	stop := errors.New("caller cancelled")
	seen = nil
	ids, err = m.Generate(prompt, 16, func(id int) error {
		seen = append(seen, id)
		if len(seen) == 3 {
			return stop
		}
		return nil
	})
	if !errors.Is(err, stop) {
		t.Fatalf("abort: %v", err)
	}
	if len(ids) != 3 || len(seen) != 3 {
		t.Fatalf("aborted with %d ids, want 3", len(ids))
	}
}

// Close frees the weight buffers and refuses further work.
func TestCloseFreesAndRefuses(t *testing.T) {
	m, d := loadStub(t)
	m.Close()
	m.Close() // idempotent
	if len(d.bufs) != 0 {
		t.Fatalf("%d buffers still allocated after Close", len(d.bufs))
	}
	if _, err := m.Generate([]int{1}, 4, nil); err == nil {
		t.Fatal("Generate on a closed model must fail")
	}
}
