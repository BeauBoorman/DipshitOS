package pdf

import (
	"bytes"
	"compress/flate"
	encodinghex "encoding/hex"
	"fmt"
	"strings"
	"testing"
	"virelai/vector"
)

func decoderEngine(t *testing.T, data []byte, keys string) engine {
	t.Helper()
	src := document(stream(data, keys))
	e := syntaxEngine(src)
	e.x = make([]xref, MaxObjects+1)
	e.dec = make([]decoder, 2)
	e.structure()
	if e.f.Code != OK {
		t.Fatal(e.f)
	}
	if opened, _ := e.openDecoder(0, 1, false); !opened {
		t.Fatal(e.f)
	}
	return e
}
func TestStoredFixedDynamicAndDecoderCounters(t *testing.T) {
	// Small authored RFC byte vectors, not copied decoder implementation.
	fixed, _ := encodinghex.DecodeString("789c73040000420042") // literal A, fixed block
	for _, test := range []struct {
		data []byte
		want []byte
	}{
		{fixed, []byte("A")},
		{zipData(t, []byte("stored"), flate.NoCompression), []byte("stored")},
		{zipData(t, bytes.Repeat([]byte("bounded streaming PDF\n"), 1024), flate.BestCompression), bytes.Repeat([]byte("bounded streaming PDF\n"), 1024)},
	} {
		e := decoderEngine(t, test.data, "/Filter /FlateDecode")
		before := e.l.Counts
		var out []byte
		for e.f.Code == OK {
			b, ok := e.decoded(0)
			if !ok {
				break
			}
			out = append(out, b)
		}
		e.closeDecoder(0)
		if e.f.Code != OK || !bytes.Equal(out, test.want) {
			t.Fatal(e.f, len(out))
		}
		if e.l.Expanded != uint64(len(test.want)) || e.l.Counts[DecodeByte] != uint64(len(test.want)) {
			t.Fatal("output counter")
		}
		if e.l.Counts[Checksum]-before[Checksum] != uint64(len(test.want)+4) {
			t.Fatal("checksum counter")
		}
		if bytes.Equal(test.data, fixed) {
			// Header block (3), A (8), end (7), no bit charge for zlib
			// header, byte padding or Adler footer. One fixed table build.
			if e.l.Counts[InputBit]-before[InputBit] != 18 {
				t.Fatal("fixed bits", e.l.Counts)
			}
			want := [WorkKinds]uint64{Examine: 7, Copy: 1, Zero: 1220, InputBit: 18, Huffman: 1033, Block: 1, DecodeByte: 1, Checksum: 5}
			if got := subtract(e.l.Counts, before); got != want {
				t.Fatalf("fixed decoder categories: %v want %v", got, want)
			}
		}
	}
}
func subtract(a, b [WorkKinds]uint64) [WorkKinds]uint64 {
	for i := range a {
		a[i] -= b[i]
	}
	return a
}
func TestMalformedDeflateAndExpansion(t *testing.T) {
	good, _ := encodinghex.DecodeString("789c73040000420042")
	for _, data := range [][]byte{
		{0x78, 0x9c, 0x07},                         // reserved block
		{0x78, 0x9c, 0x01, 0x01, 0x00, 0x01, 0x00}, // LEN/NLEN mismatch
		{0x78, 0x9c, 0x03},                         // truncated fixed end
		append(bytes.Clone(good), 0),               // trailing compressed data
		append(bytes.Clone(good[:len(good)-1]), 0), // bad Adler
		{0x78, 0x20},                               // preset dictionary
	} {
		e := syntaxEngine(document(stream(data, "/Filter /FlateDecode")))
		e.x = make([]xref, 8193)
		e.dec = make([]decoder, 2)
		e.structure()
		if opened, _ := e.openDecoder(0, 1, false); opened {
			for e.f.Code == OK {
				if _, ok := e.decoded(0); !ok {
					break
				}
			}
			e.closeDecoder(0)
		}
		if e.f.Code != MalformedStream || e.l.Decoders != 0 {
			t.Fatal(data, e.f, e.l.Decoders)
		}
	}
	e := decoderEngine(t, good, "/Filter /FlateDecode")
	e.l.Expanded = MaxExpansion - 1
	if b, ok := e.decoded(0); !ok || b != 'A' || e.f.Code != OK {
		t.Fatal(e.f)
	}
	if _, ok := e.decoded(0); ok || e.f.Code != OK {
		t.Fatal(e.f)
	}
	e.closeDecoder(0)
	e = decoderEngine(t, []byte("AB"), "")
	e.l.Expanded = MaxExpansion - 1
	e.decoded(0)
	e.decoded(0)
	if e.f.Code != ExpansionLimit || e.l.Expanded != MaxExpansion {
		t.Fatal(e.f)
	}
	e.closeDecoder(0)
	e = decoderEngine(t, nil, "")
	if opened, _ := e.openDecoder(1, 1, false); !opened || e.l.Decoders != 2 {
		t.Fatal(e.f)
	}
	if opened, _ := e.openDecoder(0, 1, false); opened || e.f.Code != DecoderLimit {
		t.Fatal(e.f)
	}
	e.closeDecoder(1)
	e.closeDecoder(0)
}
func TestPublicationAndRuntimeBoundaries(t *testing.T) {
	for _, test := range []struct {
		check func(uint64) Code
		limit uint64
		code  Code
	}{
		{CheckOutput, MaxOutput, OutputLimit}, {CheckReceipt, MaxReceipt, ReceiptLimit}, {CheckDiagnostics, MaxDiagnostics, ReceiptLimit},
	} {
		if test.check(test.limit) != OK || test.check(test.limit+1) != test.code {
			t.Fatal(test.limit)
		}
	}
	if CheckRuntime(3_145_728, 11) != OK || CheckRuntime(3_145_729, 11) != MemoryLimit || CheckRuntime(0, 12) != MemoryLimit {
		t.Fatal("runtime admission")
	}
	if CheckEngineSize(2_097_152, 2_097_152) != OK || CheckEngineSize(2_097_153, 0) != EngineSizeLimit || CheckEngineSize(0, 2_097_153) != EngineSizeLimit {
		t.Fatal("binary admission")
	}
	if Operation().Code != UnsupportedOperation {
		t.Fatal("operation")
	}
}
func TestSceneCapacityWithLowWorkInputs(t *testing.T) {
	for _, n := range []int{512, 513} {
		// One Move and one degenerate Line per fill. Whole validation and
		// render admit 1024 contours/paints, without many sampled pixels.
		src := simple(strings.Repeat("0 0 m 0 0 l f ", n), "")
		if n == 512 {
			_, st, _ := rendered(t, src)
			if st.Paints != 1024 || st.Contours != 1024 {
				t.Fatal(st)
			}
		} else {
			refusal(t, src, SceneLimit)
		}
	}
	for _, n := range []int{4096, 4097} {
		src := simple("0 0 m "+strings.Repeat("0 0 l ", n-1)+" f", "")
		if n == 4096 {
			_, st, _ := rendered(t, src)
			if st.Commands != 8192 {
				t.Fatal(st)
			}
		} else {
			refusal(t, src, SceneLimit)
		}
	}
	// Axis-specific image ceilings, including a full streamed RGB image with
	// no retained decoded cache. Validation and Do/render expansion all count.
	for _, test := range []struct {
		w, h int
		want Code
	}{{1024, 1, OK}, {1025, 1, CanvasLimit}, {1, 1536, OK}, {1, 1537, CanvasLimit}, {1024, 1536, OK}} {
		data := zipData(t, bytes.Repeat([]byte{255, 0, 0}, test.w*test.h), flate.BestCompression)
		src := imageDocument("", data, fmt.Sprintf("/Width %d /Height %d /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /FlateDecode", test.w, test.h))
		if test.want == OK {
			rendered(t, src)
		} else {
			refusal(t, src, test.want)
		}
	}
}
func TestVectorEdgesAndCurveCapacity(t *testing.T) {
	// Direct published consumer boundary: no copied private vector state.
	// Planning uses an empty clip to make independent geometry capacities
	// cheap enough to reach without the work/pixel ceiling.
	commands := make([]vector.Command, 8192)
	commands[0] = vector.Command{Verb: vector.Move}
	for i := 1; i < len(commands); i++ {
		commands[i] = vector.Command{Verb: vector.Line, P: [3]vector.Point{{X: float64(i % 2), Y: float64(i % 3)}}}
	}
	paints := []vector.Paint{{Count: 8192, Transform: identity, Color: 0xff000000}}
	ws := vector.Workspace{Bytes: make([]byte, 524288)}
	dst := vector.Target{Pix: []uint32{0xffffffff}, Width: 1, Height: 1, Stride: 1}
	b := vector.Budget{Max: vector.MaxWork}
	st, f := vector.Rasterize(vector.Scene{Commands: commands, Paints: paints}, dst, ws, &b)
	if f.Code != vector.OK || st.Edges != 8192 {
		t.Fatal(st, f)
	}
	commands[1] = vector.Command{Verb: vector.Cubic, P: [3]vector.Point{{X: 32768, Y: 32768}, {X: -32768, Y: 32768}, {X: 1, Y: 1}}}
	b = vector.Budget{Max: vector.MaxWork}
	_, f = vector.Rasterize(vector.Scene{Commands: commands, Paints: paints}, dst, ws, &b)
	if f.Code != vector.SegmentLimit {
		t.Fatal("expanded edge cap+1", f)
	}
	for _, c := range []vector.Command{
		{Verb: vector.Cubic, P: [3]vector.Point{{X: 0, Y: 1}, {X: 1, Y: 1}, {X: 1, Y: 0}}},
		{Verb: vector.Cubic, P: [3]vector.Point{{X: 32768, Y: 32768}, {X: -32768, Y: -32768}, {}}},
	} {
		b = vector.Budget{Max: vector.MaxWork}
		paints[0].Count = 2
		st, f = vector.Rasterize(vector.Scene{Commands: []vector.Command{{Verb: vector.Move}, c}, Paints: paints}, dst, ws, &b)
		if f.Code != vector.OK && f.Code != vector.CurveLimit {
			t.Fatal(st, f)
		}
	}
}
func FuzzRender(f *testing.F) {
	f.Add(simple("0 0 48 48 re f", ""))
	f.Add([]byte("%PDF-1.4\n"))
	f.Add(fontDocument("BT /F1 1 Tf (A) Tj ET", "1 0 0 0 1 1 d1", ""))
	a := make([]byte, ArenaBytes)
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 65536 {
			return
		}
		l := Ledger{Max: 2_000_000}
		p, _, err := Render(&memorySource{data: data}, 0, a, &l)
		if err.Code != OK && p.Pix != nil {
			t.Fatal("published failed prefix")
		}
		if l.Decoders != 0 {
			t.Fatal("decoder leak")
		}
	})
}
