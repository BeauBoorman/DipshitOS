package main

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"

	"virelai/gpu3d"
)

// fakeHost is the platform seam's test double: console lines recorded,
// files in a map, compute sessions served by the kernel-emulating fake.
type fakeHost struct {
	console []string
	files   map[string][]byte
	dirs    map[string]bool
	devs    []*fakeDev
	openErr error
	now     int64
}

func newFakeHost() *fakeHost {
	return &fakeHost{files: map[string][]byte{}, dirs: map[string]bool{}}
}

func (f *fakeHost) ConsoleLine(s string) { f.console = append(f.console, s) }

func (f *fakeHost) MkdirShare(p string) error { f.dirs[p] = true; return nil }

func (f *fakeHost) WriteShareFile(p string, b []byte) error {
	f.files[p] = append([]byte(nil), b...)
	return nil
}

func (f *fakeHost) FileExists(p string) bool {
	_, ok := f.files[p]
	return ok
}

type rcReader struct{ io.Reader }

func (rcReader) Close() error { return nil }

func (f *fakeHost) OpenRead(p string) (io.ReadCloser, error) {
	b, ok := f.files[p]
	if !ok {
		return nil, errors.New("open -2")
	}
	return rcReader{bytes.NewReader(b)}, nil
}

func (f *fakeHost) OpenComp() (dev, error) {
	if f.openErr != nil {
		return nil, f.openErr
	}
	d := newFakeDev()
	f.devs = append(f.devs, d)
	return d, nil
}

// Nanos advances a fixed tick per call so tok/s fields are populated and
// deterministic without a real clock.
func (f *fakeHost) Nanos() int64 {
	f.now += 1e6
	return f.now
}

func (f *fakeHost) SelfMemBytes() uint64 { return 30 << 20 }

func (f *fakeHost) hasConsole(sub string) bool {
	for _, l := range f.console {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

// --- VIW container --------------------------------------------------------

func TestViwRoundTrip(t *testing.T) {
	h := viwHeader{Arch: "llama", Dim: 8, Hidden: 16, Layers: 1,
		Heads: 2, KVHeads: 2, Vocab: 32, SeqCap: 16,
		Rope: "half", RopeTheta: 10000, RmsEps: 1e-5,
		Tie: true, BOS: 1, EOS: 2,
		Model: viwModel{ID: "x", License: "MIT"}}
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
	img := synthStub()
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

// --- the stub model on the emulated kernels ---------------------------------

func TestStubRunsDeterministicAndCoversKernels(t *testing.T) {
	h := newFakeHost()
	if err := run(h, []string{"stub"}); err != nil {
		t.Fatalf("run stub: %v", err)
	}
	// One journey, one compute session (the fixed-VA window makes a process
	// single-session anyway): the five runs share it and each frees its own
	// buffers.
	if len(h.devs) != 1 {
		t.Fatalf("sessions = %d want 1", len(h.devs))
	}
	d := h.devs[0]
	for _, k := range []uint32{kernelGEMM, kernelSoftmax, kernelDequant} {
		if d.submits[k] == 0 {
			t.Fatalf("kernel %d never ran", k)
		}
	}
	if !h.hasConsole("goinfer: stub consistent K=5") {
		t.Fatalf("console: %v", h.console)
	}
	if !h.hasConsole("goinfer OK") {
		t.Fatalf("console: %v", h.console)
	}
	body := string(h.files[receiptTSV])
	if !strings.Contains(body, "stub\tconsistent\tK=5") {
		t.Fatalf("receipt:\n%s", body)
	}
	// Every run must be a full session: same id sequence, nonzero submits.
	var firstIds string
	for i, l := range h.console {
		if strings.HasPrefix(l, "goinfer: stub run k=") {
			j := strings.Index(l, "ids=") + 4
			k := strings.Index(l[j:], " ")
			ids := l[j : j+k]
			if firstIds == "" {
				firstIds = ids
			} else if ids != firstIds {
				t.Fatalf("run %d diverged: %s vs %s", i, ids, firstIds)
			}
		}
	}
	if firstIds == "" {
		t.Fatal("no stub run lines")
	}
}

func TestStubAnswerPinnedOnHost(t *testing.T) {
	// The host-emulated answer is pinned here; the gate pins the Metal
	// answer separately — both deterministic, possibly differing in the
	// last ulp of f16 rounding.
	h := newFakeHost()
	if err := run(h, []string{"stub"}); err != nil {
		t.Fatal(err)
	}
	for _, l := range h.console {
		if strings.HasPrefix(l, "goinfer: stub answer ") {
			t.Logf("stub answer line: %s", l)
			return
		}
	}
	t.Fatal("no answer line")
}

func TestModelJourneyReportsAbsentWeights(t *testing.T) {
	h := newFakeHost()
	err := run(h, []string{"model"})
	if err == nil || !h.hasConsole("goinfer: weights absent") {
		t.Fatalf("want weights-absent: err=%v console=%v", err, h.console)
	}
}

func TestModelJourneyRunsStagedVIW(t *testing.T) {
	h := newFakeHost()
	// Stage a stub image at the model path — the model journey only cares
	// that a real file arrived through the share.
	h.files[modelPath] = synthStub()
	if err := run(h, []string{"model"}); err != nil {
		t.Fatalf("model run: %v", err)
	}
	if !h.hasConsole("goinfer: model answer") {
		t.Fatalf("console: %v", h.console)
	}
	body := string(h.files[receiptTSV])
	if !strings.Contains(body, "model\tloaded\t") {
		t.Fatalf("receipt:\n%s", body)
	}
}

func TestUnsupportedNamesItself(t *testing.T) {
	h := newFakeHost()
	h.openErr = gpu3d.ErrComputeNoDevice
	if err := run(h, []string{"stub"}); err != nil {
		t.Fatalf("unsupported should exit clean: %v", err)
	}
	if !h.hasConsole("goinfer: unsupported") {
		t.Fatalf("console: %v", h.console)
	}
	if _, ok := h.files[receiptTSV]; ok {
		t.Fatal("a receipt landed on a device-less boot")
	}
}

func TestUsageError(t *testing.T) {
	h := newFakeHost()
	if err := run(h, []string{"bogus"}); !errors.Is(err, errUsage) {
		t.Fatalf("want usage: %v", err)
	}
}
