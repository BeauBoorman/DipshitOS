package infer

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"strings"
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

// --- hostile .VIW inputs ----------------------------------------------------
//
// A crafted image gets exactly one contract: a named Load/Generate error,
// never a panic, a multi-gigabyte allocation, or a silent wrong answer.
// tinyImage builds the smallest image that loads — one layer, dim 32 — so
// every test mutates precisely one field of an otherwise valid file.

func tinyImage(t *testing.T, tok []byte, mut func(w *viwWrite)) []byte {
	t.Helper()
	h := Header{Arch: "llama", Dim: 32, Hidden: 64, Layers: 1,
		Heads: 2, KVHeads: 2, Vocab: 256, SeqCap: 16,
		Rope: "half", RopeTheta: 10000, RmsEps: 1e-5,
		Tie: true, BOS: 1, EOS: 2}
	w := newViwWrite(h, tok)
	u4 := func(rows, cols int) []byte {
		return quantU4Asym(make([]float32, rows*cols), 32)
	}
	f32pay := func(n int) []byte { return make([]byte, n*4) }
	w.add(tEmbed, viwFmtU4Asym, 32, [2]uint32{256, 32}, u4(256, 32))
	w.add(tFinalN, viwFmtF32, 0, [2]uint32{32, 0}, f32pay(32))
	w.add("l0."+tAttnN, viwFmtF32, 0, [2]uint32{32, 0}, f32pay(32))
	w.add("l0."+tWqkv, viwFmtU4Asym, 32, [2]uint32{96, 32}, u4(96, 32))
	w.add("l0."+tWo, viwFmtU4Asym, 32, [2]uint32{32, 32}, u4(32, 32))
	w.add("l0."+tFfnN, viwFmtF32, 0, [2]uint32{32, 0}, f32pay(32))
	w.add("l0."+tW13, viwFmtU4Asym, 32, [2]uint32{128, 32}, u4(128, 32))
	w.add("l0."+tW2, viwFmtU4Asym, 32, [2]uint32{32, 64}, u4(32, 64))
	if mut != nil {
		mut(w)
	}
	return w.marshal()
}

// loadErr asserts the image is refused with want in the error — and that
// the refusal is an error return, not a panic (a panic fails the test run
// on its own).
func loadErr(t *testing.T, img []byte, want string) {
	t.Helper()
	m, err := Load(bytes.NewReader(img), NewFakeDev(), 1<<20)
	if err == nil {
		m.Close()
		t.Fatalf("hostile image loaded; want refusal matching %q", want)
	}
	if !strings.Contains(err.Error(), want) {
		t.Fatalf("Load error %q, want substring %q", err, want)
	}
}

// The fixture itself is valid: a no-mutation image must load and close.
func TestTinyImageIsLoadable(t *testing.T) {
	m, err := Load(bytes.NewReader(tinyImage(t, tokEmitBytes(1, 2), nil)),
		NewFakeDev(), 1<<20)
	if err != nil {
		t.Fatalf("tiny image: %v", err)
	}
	m.Close()
}

// The tokenizer blob's section counts size the parse tables — a count that
// outruns the blob must fail before it allocates.
func TestHostileTokenizerCountsBeyondBlob(t *testing.T) {
	b := make([]byte, 16)
	binary.LittleEndian.PutUint32(b, tokKindBPE)
	binary.LittleEndian.PutUint32(b[12:], 1<<30) // n_vocab
	if _, err := parseTokenizer(b); err == nil {
		t.Fatal("n_vocab beyond the blob accepted")
	}
	v := tokEmitBPE([]string{"a"}, nil, 0, 1)
	binary.LittleEndian.PutUint32(v[len(v)-4:], 1<<30) // n_merges
	if _, err := parseTokenizer(v); err == nil {
		t.Fatal("n_merges beyond the blob accepted")
	}
}

// Header fields bound every downstream allocation — a layers count past
// the envelope must die in checkArch, before the layer table allocates.
func TestHostileHeaderLayersExceedsBound(t *testing.T) {
	img := tinyImage(t, tokEmitBytes(1, 2), func(w *viwWrite) {
		w.header.Layers = 1 << 20
	})
	loadErr(t, img, "kernel bounds")
}

// Tensor dims are attacker-writable bytes — every v1 name has one
// config-derived shape, and a consistent-with-itself lie must be refused.
func TestHostileTensorShapes(t *testing.T) {
	cases := []struct {
		name string
		mut  func(w *viwWrite)
		want string
	}{
		{"embed dims swapped", func(w *viwWrite) {
			w.dir[0].Dims = [2]uint32{128, 64} // same N, wrong shape
		}, "dims"},
		{"embed dims inflated", func(w *viwWrite) {
			w.dir[0].Dims = [2]uint32{256, 64}
			w.pay[0] = quantU4Asym(make([]float32, 256*64), 32)
		}, "dims"},
		{"embed wrong fmt", func(w *viwWrite) {
			w.dir[0].Fmt = viwFmtF32
			w.dir[0].Group = 0
			w.pay[0] = make([]byte, 256*32*4)
		}, "u4asym"},
		{"norm dims wrong", func(w *viwWrite) {
			w.dir[1].Dims = [2]uint32{64, 0}
			w.pay[1] = make([]byte, 64*4)
		}, "dims"},
		{"wqkv dims wrong", func(w *viwWrite) {
			w.dir[3].Dims = [2]uint32{48, 64} // same N, wrong split
		}, "dims"},
		{"layer index out of range", func(w *viwWrite) {
			w.add("l5."+tAttnN, viwFmtF32, 0, [2]uint32{32, 0},
				make([]byte, 128))
		}, "beyond"},
		{"unknown tensor name", func(w *viwWrite) {
			w.add("rotary", viwFmtF32, 0, [2]uint32{32, 0},
				make([]byte, 128))
		}, "vocabulary"},
		{"unknown layer tensor", func(w *viwWrite) {
			w.add("l0.rotary", viwFmtF32, 0, [2]uint32{32, 0},
				make([]byte, 128))
		}, "unknown"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			loadErr(t, tinyImage(t, tokEmitBytes(1, 2), tc.mut), tc.want)
		})
	}
}

// A second tensor landing in the same guest slot is refused — each name
// owns its accumulator exactly once.
func TestHostileDuplicateGuestTensor(t *testing.T) {
	img := tinyImage(t, tokEmitBytes(1, 2), func(w *viwWrite) {
		w.add(tEmbed, viwFmtU4Asym, 32, [2]uint32{256, 32},
			quantU4Asym(make([]float32, 256*32), 32))
	})
	loadErr(t, img, "duplicate")
}

// A tokenizer whose id space outruns the model's vocab is inconsistent —
// Load refuses it rather than panic on the first out-of-range embed row.
func TestHostileTokenizerIdSpaceExceedsVocab(t *testing.T) {
	vocab := make([]string, 300) // id space 300 against model vocab 256
	for i := range vocab {
		vocab[i] = "x"
	}
	img := tinyImage(t, tokEmitBPE(vocab, nil, 0, 1), nil)
	loadErr(t, img, "id space")
}

// A token id outside the vocab — however it reached the prompt — is a
// named error, not an out-of-bounds embed-row gather.
func TestGenerateRejectsOutOfRangeTokens(t *testing.T) {
	m, _ := loadStub(t)
	defer m.Close()
	for _, prompt := range [][]int{{9999, 1}, {-1, 1}} {
		if _, err := m.Generate(prompt, 4, nil); err == nil {
			t.Fatalf("prompt %v ran an out-of-range token id", prompt)
		}
	}
}
