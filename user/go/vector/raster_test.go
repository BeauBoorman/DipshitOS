package vector

import (
	"math"
	"reflect"
	"testing"
	"unsafe"
)

func rectScene(w, h float64) Scene {
	return Scene{Commands: []Command{
		{Verb: Move}, {Verb: Line, P: [3]Point{{w, 0}}},
		{Verb: Line, P: [3]Point{{w, h}}}, {Verb: Line, P: [3]Point{{0, h}}}, {Verb: Close},
	}, Paints: []Paint{{Count: 5, Transform: Affine{A: 1, D: 1}, Clip: Rect{0, 0, 1024, 1536}, Color: 0xffff0000}}}
}
func scratchBuffer() Workspace { return Workspace{make([]byte, WorkspaceSize)} }
func TestRectAndExactWork(t *testing.T) {
	s := rectScene(1, 1)
	dst := Target{[]uint32{0}, 1, 1, 1}
	b := Budget{Max: MaxWork}
	m := meter{b: &b}
	var stats Stats
	f := rasterize(s, dst, scratchBuffer(), &m, &stats)
	if f.Code != OK || dst.Pix[0] != 0xffff0000 || stats.Edges != 4 || stats.ScratchBytes != MaxEdges*48+1024*8+16 {
		t.Fatalf("%+v %+v %x", f, stats, dst.Pix)
	}
	want := [workKinds]uint64{6, 12, 0, 10, 40, 16, 8, 24, 16, 8, 10, 2, 16}
	if m.counts != want {
		t.Fatalf("counter buckets: got %v want %v", m.counts, want)
	}
	var total uint64
	for _, n := range want {
		total += n
	}
	if b.Used != total {
		t.Fatal(b)
	}
	// Preflight succeeds, but reservation fails one unit before the whole
	// call fits. No clear or first-paint pixel is permitted.
	for _, maxWork := range []uint64{0, 6, total / 2, total - 1} {
		dst.Pix[0] = 0x12345678
		b = Budget{Max: maxWork}
		_, f = Rasterize(s, dst, scratchBuffer(), &b)
		if f.Code != WorkLimit || dst.Pix[0] != 0x12345678 || b.Used > b.Max {
			t.Fatalf("max %d: %+v %x %+v", maxWork, f, dst.Pix, b)
		}
	}
}
func TestSubdivisionCounters(t *testing.T) {
	b := Budget{Max: MaxWork}
	m := meter{b: &b}
	f := flattener{sc: workspace(scratchBuffer()), m: &m}
	if !f.curve(Point{}, Point{1, 1}, Point{2, 0}, Point{}, false, 0) {
		t.Fatal(f.code)
	}
	if m.counts[subdivideWork] != 7 || m.counts[edgeWork] != 4 || f.n != 4 {
		t.Fatal(m.counts, f.n)
	}
}
func TestBlendFormula(t *testing.T) {
	// Independent integer rational expression, exercised over all alpha and
	// coverage bytes and transparent/nonopaque/opaque backgrounds.
	for a := uint32(0); a < 256; a++ {
		for c := uint32(0); c < 256; c++ {
			for _, d := range []uint32{0x00123456, 0x80775533, 0xff12abef} {
				src := a<<24 | 0xa37129
				sa, da := uint64((a*c+127)/255), uint64(d>>24)
				want := d
				if sa != 0 {
					den := sa*255 + da*(255-sa)
					want = uint32((den+127)/255) << 24
					for shift := uint(0); shift < 24; shift += 8 {
						num := uint64(src>>shift&255)*sa*255 + uint64(d>>shift&255)*da*(255-sa)
						want |= uint32((num+den/2)/den) << shift
					}
				}
				if got := blend(d, src, c); got != want {
					t.Fatalf("%x %x %d: %x != %x", d, src, c, got, want)
				}
			}
		}
	}
}
func TestCoverageClipStrideAndPage(t *testing.T) {
	s := rectScene(1024, 1536)
	pix := make([]uint32, 1040*1536+1)
	for i := range pix {
		pix[i] = 0x11223344
	}
	dst := Target{pix, 1024, 1536, 1040}
	b := Budget{Max: MaxWork}
	stats, f := Rasterize(s, dst, scratchBuffer(), &b)
	if f.Code != OK || stats.Work > MaxWork || pix[1535*1040+1023] != 0xffff0000 {
		t.Fatal(f, stats)
	}
	for y := 0; y < 1536; y++ {
		for x := 1024; x < 1040; x++ {
			if pix[y*1040+x] != 0x11223344 {
				t.Fatal("padding changed")
			}
		}
	}
	if pix[len(pix)-1] != 0x11223344 {
		t.Fatal("tail changed")
	}
	s = rectScene(.5, 1)
	dst = Target{make([]uint32, 1), 1, 1, 1}
	b = Budget{Max: MaxWork}
	_, f = Rasterize(s, dst, scratchBuffer(), &b)
	if f.Code != OK || dst.Pix[0] != 0x80ff0000 {
		t.Fatalf("%v %x", f, dst.Pix)
	}
}
func TestFailuresAndImmutability(t *testing.T) {
	dst := Target{[]uint32{0x12345678}, 1, 1, 1}
	for _, tc := range []struct {
		name string
		edit func(*Scene)
		code Code
	}{
		{"range", func(s *Scene) { s.Paints[0].Count = math.MaxUint32 }, Malformed},
		{"gap", func(s *Scene) { s.Paints[0].First = 1 }, Malformed},
		{"rule", func(s *Scene) { s.Paints[0].Rule = 2 }, Malformed},
		{"verb", func(s *Scene) { s.Commands[0].Verb = 99 }, Malformed},
		{"unused", func(s *Scene) { s.Commands[0].P[2].X = 1 }, Malformed},
		{"start", func(s *Scene) { s.Commands[0].Verb = Line }, Malformed},
		{"nan", func(s *Scene) { s.Commands[1].P[0].X = math.NaN() }, CoordinateLimit},
		{"local", func(s *Scene) { s.Commands[1].P[0].X = 32769 }, CoordinateLimit},
		{"affine", func(s *Scene) { s.Paints[0].Transform.A = 257 }, CoordinateLimit},
		{"mapped", func(s *Scene) { s.Paints[0].Transform.E = 32768 }, CoordinateLimit},
		{"clip", func(s *Scene) { s.Paints[0].Clip = Rect{1, 0, 0, 1} }, Malformed},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := rectScene(1, 1)
			tc.edit(&s)
			b := Budget{Max: MaxWork}
			_, f := Rasterize(s, dst, scratchBuffer(), &b)
			if f.Code != tc.code || dst.Pix[0] != 0x12345678 {
				t.Fatalf("%+v %x", f, dst.Pix)
			}
		})
	}
	s := rectScene(1, 1)
	before := append([]Command(nil), s.Commands...)
	b := Budget{Max: MaxWork}
	ws := scratchBuffer()
	_, f := Rasterize(s, dst, ws, &b)
	if f.Code != OK || !reflect.DeepEqual(before, s.Commands) {
		t.Fatal(f, "commands changed")
	}
	for _, bad := range []Workspace{{ws.Bytes[:WorkspaceSize-1]}, {ws.Bytes[1:]}} {
		b = Budget{Max: MaxWork}
		_, f = Rasterize(s, dst, bad, &b)
		if f.Code != ScratchLimit {
			t.Fatal(f)
		}
	}
}
func TestNoAllocationAndReuse(t *testing.T) {
	s := rectScene(2, 2)
	ws := scratchBuffer()
	dst := Target{make([]uint32, 4), 2, 2, 2}
	for i := 0; i < 100; i++ {
		b := Budget{Max: MaxWork}
		run := func() {
			b.Used = 0
			_, f := Rasterize(s, dst, ws, &b)
			if f.Code != OK {
				panic(f.Error())
			}
		}
		// AllocsPerRun compares the process-wide MemStats.Mallocs counter
		// around the call, so a runtime-internal mallocgc that happens to
		// land inside the window — a semaphore sudog for an STW in
		// ReadMemStats/GOMAXPROCS/GC, a new M under scheduler churn —
		// counts the same as an allocation by run itself (issue #2534).
		// Such noise does not repeat on re-measurement; a real per-call
		// allocation in Rasterize does, so retry before failing.
		n := testing.AllocsPerRun(1, run)
		for try := 0; n != 0 && try < 4; try++ {
			n = testing.AllocsPerRun(1, run)
		}
		if n != 0 {
			t.Fatalf("iteration %d: %v allocs", i, n)
		}
	}
	if unsafe.Sizeof(Command{}) != 56 || unsafe.Sizeof(Paint{}) != 96 || scratchUsed > WorkspaceSize {
		t.Fatal("POD layout changed", unsafe.Sizeof(Command{}), unsafe.Sizeof(Paint{}))
	}
}
func TestCompoundRulesAndReflection(t *testing.T) {
	s := rectScene(4, 4)
	inner := rectScene(2, 2)
	for i := range inner.Commands {
		for k := 0; k < arity(inner.Commands[i].Verb); k++ {
			inner.Commands[i].P[k].X++
			inner.Commands[i].P[k].Y++
		}
	}
	s.Commands = append(s.Commands, inner.Commands...)
	s.Paints[0].Count = uint32(len(s.Commands))
	for _, rule := range []Rule{NonZero, EvenOdd} {
		s.Paints[0].Rule = rule
		for _, transform := range []Affine{{A: 1, D: 1}, {A: -1, D: 1, E: 4}} {
			s.Paints[0].Transform = transform
			dst := Target{make([]uint32, 16), 4, 4, 4}
			b := Budget{Max: MaxWork}
			_, f := Rasterize(s, dst, scratchBuffer(), &b)
			if f.Code != OK || dst.Pix[0] != 0xffff0000 || (dst.Pix[5] == 0) != (rule == EvenOdd) {
				t.Fatalf("%v %x", f, dst.Pix)
			}
		}
	}
}
