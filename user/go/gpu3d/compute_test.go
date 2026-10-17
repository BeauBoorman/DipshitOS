package gpu3d

// Host-side tests for the slot-90 compute client (M111b, issue #2409):
// the frozen descriptor/kdesc byte layouts, the refusal-table mapping,
// and a full session lifecycle against a stubbed syscall — no kernel,
// no device, never fabricated.
import (
	"errors"
	"testing"

	"virelai/vi"
)

// A canned sys_gpucomp: records every call, answers per op from a queue.
type compFake struct {
	calls   [][]byte
	replies map[uint32]int64
	desc    []byte // last descriptor bytes, verbatim
}

func (f *compFake) run(desc []byte) int64 {
	f.calls = append(f.calls, append([]byte(nil), desc...))
	f.desc = append([]byte(nil), desc...)
	op := getU32(desc)
	if rc, ok := f.replies[op]; ok {
		return rc
	}
	return 0
}

func compHarness(t *testing.T, f *compFake) {
	t.Helper()
	oldSys, oldMap := CompSyscall, CompMap
	CompSyscall = f.run
	CompMap = func(_ uintptr, size int, _, _ uint64) ([]byte, error) {
		return make([]byte, size), nil
	}
	t.Cleanup(func() { CompSyscall, CompMap = oldSys, oldMap })
}

func TestKernelDescEncodeLayout(t *testing.T) {
	var d KernelDesc
	d.Kernel = vi.GpuKernelGEMM
	d.Flags = vi.GpuGemmBias | vi.GpuGemmBTransposed
	d.D0, d.D1, d.D2 = 2, 3, 4
	d.Bufs = [4]KernelBuf{{Buf: 0x1122}, {Buf: 0x3344, ByteOff: 8}, {Buf: 0x5566}, {}}
	out := d.Encode()
	if got := getU32(out[0:]); got != 1 {
		t.Fatalf("kernel_id=%d", got)
	}
	if got := getU32(out[4:]); got != 3 {
		t.Fatalf("flags=%d", got)
	}
	if got := getU32(out[8:]); got != 2 {
		t.Fatalf("d0=%d", got)
	}
	if got := getU32(out[12:]); got != 3 {
		t.Fatalf("d1=%d", got)
	}
	if got := getU32(out[16:]); got != 4 {
		t.Fatalf("d2=%d", got)
	}
	if got := getU32(out[24:]); got != 0x1122 {
		t.Fatalf("bufs[0].buf=%x", got)
	}
	if got := getU32(out[36:]); got != 8 {
		t.Fatalf("bufs[1].byte_off=%d", got)
	}
	// reserved tail is always zero.
	for i := 56; i < 64; i++ {
		if out[i] != 0 {
			t.Fatalf("reserved byte %d nonzero", i)
		}
	}
}

func TestComputeRefusalTable(t *testing.T) {
	cases := []struct {
		rc   int64
		want error
	}{
		{0, nil},
		{-vi.ErrEINVAL, ErrComputeInvalid},
		{-vi.ErrEBADF, ErrComputeBadHandle},
		{-vi.ErrENOSPC, ErrComputeExhausted},
		{-vi.ErrENXIO, ErrComputeNoDevice},
		{-vi.ErrENOSYS, ErrComputeNoDevice},
		{-vi.ErrEAGAIN, ErrComputeBusy},
		{-vi.ErrETIMEDOUT, ErrComputeTimedOut},
		{-vi.ErrENOENT, ErrComputeLost},
		{-vi.ErrEFAULT, ErrComputeFault},
		{-vi.ErrEIO, ErrComputeDevice},
	}
	for _, c := range cases {
		if got := compErr(c.rc); got != c.want {
			t.Fatalf("compErr(%d)=%v want %v", c.rc, got, c.want)
		}
	}
}

func TestComputeSessionLifecycle(t *testing.T) {
	f := &compFake{replies: map[uint32]int64{
		vi.GpucompOpen:     0x0000_0001_0000_0007, // gen 1 | ctx 7
		vi.GpucompBufAlloc: 0x0000_0005_0001_0007, // gen 5 | slot 1 | ctx 7
	}}
	compHarness(t, f)

	s, err := OpenCompute()
	if err != nil {
		t.Fatal(err)
	}
	if s.handle != 0x0000_0001_0000_0007 {
		t.Fatalf("handle=%x", s.handle)
	}
	// The descriptor arg0 must echo op (the kernel refuses a mismatch).
	if op := getU32(f.desc[0:]); op != vi.GpucompOpen {
		t.Fatalf("desc op=%d", op)
	}

	buf, err := s.AllocBuffer(4096, BufIO)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Write(buf, 0, []byte{1, 2, 3, 4}); err != nil {
		t.Fatal(err)
	}
	// WRITE carries handle=buf, arg_a=stage VA, arg_b=len, arg_c=off.
	w := f.desc
	if getU32(w) != vi.GpucompWrite {
		t.Fatalf("write op=%d", getU32(w))
	}
	if got := w[8]; false {
		_ = got
	}
	var handle uint64
	for i := 0; i < 8; i++ {
		handle |= uint64(w[8+i]) << (8 * i)
	}
	if handle != buf {
		t.Fatalf("write handle=%x want %x", handle, buf)
	}
	lenAt := func(at int) uint64 {
		var v uint64
		for i := 0; i < 8; i++ {
			v |= uint64(w[at+i]) << (8 * i)
		}
		return v
	}
	if lenAt(24) != 4 || lenAt(32) != 0 {
		t.Fatalf("write len=%d off=%d", lenAt(24), lenAt(32))
	}
	// The staged bytes went through the mmap window.
	if s.stage[0] != 1 || s.stage[3] != 4 {
		t.Fatalf("staging not loaded: %v", s.stage[:4])
	}

	// RUN carries the verbatim kdesc.
	kd := KernelDesc{Kernel: vi.GpuKernelGEMM, D0: 2, D1: 2, D2: 2}
	kd.Bufs = [4]KernelBuf{{Buf: 2}, {Buf: 3}, {Buf: 4}, {}}
	if err := s.Run(kd); err != nil {
		t.Fatal(err)
	}
	if getU32(f.desc) != vi.GpucompRun {
		t.Fatalf("run op=%d", getU32(f.desc))
	}
	if getU32(f.desc[64:]) != 1 || getU32(f.desc[72:]) != 2 {
		t.Fatalf("kdesc not embedded: %x", f.desc[64:88])
	}

	// STATS answers through its own window.
	st, err := s.Stats()
	if err != nil {
		t.Fatal(err)
	}
	_ = st

	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil { // idempotent
		t.Fatal(err)
	}
}

func TestComputeOpenRefusals(t *testing.T) {
	for _, tc := range []struct {
		rc   int64
		want error
	}{
		{-vi.ErrENXIO, ErrComputeNoDevice},
		{-vi.ErrENOSPC, ErrComputeExhausted},
	} {
		f := &compFake{replies: map[uint32]int64{vi.GpucompOpen: tc.rc}}
		compHarness(t, f)
		_, err := OpenCompute()
		if !errors.Is(err, tc.want) {
			t.Fatalf("open rc=%d → %v, want %v", tc.rc, err, tc.want)
		}
	}
}

func TestComputeEncodeRejectsForeignKdesc(t *testing.T) {
	var d vi.GpucompDesc
	d.Op = vi.GpucompOpen
	d.Kdesc[0] = 1 // kdesc belongs to RUN only
	var out [vi.GpucompDescBytes]byte
	if err := d.EncodeDesc(out[:]); err == nil {
		t.Fatal("OPEN with a kdesc must refuse")
	}
	d.Op = 99
	d.Kdesc = [vi.GpucompKdescBytes]byte{}
	if err := d.EncodeDesc(out[:]); err == nil {
		t.Fatal("unknown op must refuse")
	}
}

func TestComputeReadRoundTripsStaging(t *testing.T) {
	f := &compFake{replies: map[uint32]int64{vi.GpucompOpen: 7}}
	compHarness(t, f)
	s, err := OpenCompute()
	if err != nil {
		t.Fatal(err)
	}
	// A READ leaves the payload in the window; fake the device-written
	// bytes by answering and pre-staging.
	copy(s.stage[:3], []byte{9, 8, 7})
	f.replies[vi.GpucompRead] = 0
	// The fake doesn't write — pretend the kernel already copied out by
	// observing the READ just moves stage→out.
	var out [3]byte
	if err := s.Read(0x50001_0007, 0, out[:]); err != nil {
		t.Fatal(err)
	}
	if out != [3]byte{9, 8, 7} {
		t.Fatalf("read=%v", out)
	}
}
