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
	oldSys, oldMap, oldUnmap := CompSyscall, CompMap, CompUnmap
	CompSyscall = f.run
	CompMap = func(_ uintptr, size int, _, _ uint64) ([]byte, error) {
		return make([]byte, size), nil
	}
	CompUnmap = func([]byte) error { return nil }
	t.Cleanup(func() { CompSyscall, CompMap, CompUnmap = oldSys, oldMap, oldUnmap })
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

// #2494: a refused OPEN must still release the fixed-VA window — before
// the unmap landed, one ENOSPC left the band claimed for the process's
// lifetime, so the retry the refusal invites could never succeed.
func TestComputeRefusedOpenUnmaps(t *testing.T) {
	var unmaps [][]byte
	f := &compFake{replies: map[uint32]int64{vi.GpucompOpen: -vi.ErrENOSPC}}
	compHarness(t, f)
	CompUnmap = func(b []byte) error {
		unmaps = append(unmaps, b)
		return nil
	}
	if _, err := OpenCompute(); !errors.Is(err, ErrComputeExhausted) {
		t.Fatalf("err=%v, want ErrComputeExhausted", err)
	}
	if len(unmaps) != 1 || len(unmaps[0]) != compMapBytes {
		t.Fatalf("unmaps=%d, want the one refused window released", len(unmaps))
	}
	// The window is free: a retry after the other session drained opens
	// normally.
	f.replies[vi.GpucompOpen] = 0x0000_0001_0000_0007
	s, err := OpenCompute()
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
}

// #2494: the landable unit — a second session in one process. Close must
// unmap the fixed-VA window so the next OpenCompute can claim the same
// band again.
func TestComputeSecondSession(t *testing.T) {
	var maps, unmaps int
	f := &compFake{replies: map[uint32]int64{vi.GpucompOpen: 0x0000_0001_0000_0007}}
	compHarness(t, f)
	CompMap = func(_ uintptr, size int, _, _ uint64) ([]byte, error) {
		maps++
		return make([]byte, size), nil
	}
	CompUnmap = func([]byte) error {
		unmaps++
		return nil
	}

	s1, err := OpenCompute()
	if err != nil {
		t.Fatal(err)
	}
	if err := s1.Close(); err != nil {
		t.Fatal(err)
	}
	if maps != 1 || unmaps != 1 {
		t.Fatalf("after close: maps=%d unmaps=%d, want 1/1", maps, unmaps)
	}
	// The second session maps a fresh window and runs a full op.
	s2, err := OpenCompute()
	if err != nil {
		t.Fatalf("second OpenCompute: %v", err)
	}
	if maps != 2 {
		t.Fatalf("maps=%d, want 2", maps)
	}
	buf, err := s2.AllocBuffer(4096, BufIO)
	if err != nil {
		t.Fatal(err)
	}
	if err := s2.Write(buf, 0, []byte{1, 2, 3}); err != nil {
		t.Fatal(err)
	}
	if err := s2.Close(); err != nil {
		t.Fatal(err)
	}
	if unmaps != 2 {
		t.Fatalf("unmaps=%d, want 2", unmaps)
	}
	// Close stays idempotent: a third Close does not unmap again.
	if err := s2.Close(); err != nil {
		t.Fatal(err)
	}
	if unmaps != 2 {
		t.Fatalf("double-Close unmapped again: unmaps=%d", unmaps)
	}
}

// #2494 follow-through: once Close has dropped the window, no later op
// may stage into the unmapped VA — every session op refuses with the
// same ErrComputeBadHandle the kernel gives a stale handle.
func TestComputePostCloseOpsRefuse(t *testing.T) {
	f := &compFake{replies: map[uint32]int64{
		vi.GpucompOpen:     7,
		vi.GpucompBufAlloc: 0x0000_0005_0001_0007,
	}}
	compHarness(t, f)
	s, err := OpenCompute()
	if err != nil {
		t.Fatal(err)
	}
	buf, err := s.AllocBuffer(4096, BufIO)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	calls := len(f.calls)
	if err := s.Write(buf, 0, []byte{1}); !errors.Is(err, ErrComputeBadHandle) {
		t.Fatalf("write after close=%v, want ErrComputeBadHandle", err)
	}
	var out [4]byte
	if err := s.Read(buf, 0, out[:]); !errors.Is(err, ErrComputeBadHandle) {
		t.Fatalf("read after close=%v, want ErrComputeBadHandle", err)
	}
	if _, err := s.Stats(); !errors.Is(err, ErrComputeBadHandle) {
		t.Fatalf("stats after close=%v, want ErrComputeBadHandle", err)
	}
	if err := s.Run(KernelDesc{Kernel: vi.GpuKernelGEMM}); !errors.Is(err, ErrComputeBadHandle) {
		t.Fatalf("run after close=%v, want ErrComputeBadHandle", err)
	}
	if _, err := s.AllocBuffer(64, BufIO); !errors.Is(err, ErrComputeBadHandle) {
		t.Fatalf("alloc after close=%v, want ErrComputeBadHandle", err)
	}
	if len(f.calls) != calls {
		t.Fatalf("post-close ops issued %d syscalls", len(f.calls)-calls)
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

// TestSampleStatsDecodesTheBlock is the session-free sampler (M111d): the
// STATS op is handle-free in the kernel, so a monitor polls the counters
// without an OPEN — and never claims the single session.
func TestSampleStatsDecodesTheBlock(t *testing.T) {
	statsWindow = nil // the lazy window must not leak a stale map between tests
	t.Cleanup(func() { statsWindow = nil })
	var window []byte
	f := &compFake{replies: map[uint32]int64{vi.GpucompStats: 0}}
	oldSys, oldMap := CompSyscall, CompMap
	CompSyscall = func(desc []byte) int64 {
		f.run(desc)
		// The kernel writes the 64-byte block at arg_a — the window's
		// stats offset, which the fake mapped.
		put := func(at int, v uint64) {
			for i := 0; i < 8; i++ {
				window[at+i] = byte(v >> (8 * i))
			}
		}
		putU32s := func(at int, v uint32) { put(at, uint64(v)) }
		putU32s(128, 1) // busy
		putU32s(132, 2) // queued
		putU32s(136, 1) // sessions_live
		put(144, 1234)  // last_kernel_us
		put(152, 5678)  // total_kernel_us
		put(160, 3)     // submits
		put(168, 3)     // completed
		put(176, 1)     // refusals
		put(184, 0)     // timeouts
		return 0
	}
	CompMap = func(_ uintptr, size int, _, _ uint64) ([]byte, error) {
		window = make([]byte, size)
		return window, nil
	}
	t.Cleanup(func() { CompSyscall, CompMap = oldSys, oldMap })

	st, err := SampleStats()
	if err != nil {
		t.Fatal(err)
	}
	// One STATS descriptor went out; no OPEN preceded it.
	if len(f.calls) != 1 || getU32(f.calls[0]) != vi.GpucompStats {
		t.Fatalf("calls=%d ops=%v", len(f.calls), f.calls)
	}
	if st.Busy != 1 || st.Queued != 2 || st.SessionsLive != 1 ||
		st.LastKernelUs != 1234 || st.TotalKernelUs != 5678 ||
		st.Submits != 3 || st.Completed != 3 || st.Refusals != 1 || st.Timeouts != 0 {
		t.Fatalf("stats=%+v", st)
	}
	// A second sample reuses the mapped window (the mmap table is bounded).
	maps := 0
	CompMap = func(_ uintptr, size int, _, _ uint64) ([]byte, error) {
		maps++
		return make([]byte, size), nil
	}
	if _, err := SampleStats(); err != nil {
		t.Fatal(err)
	}
	if maps != 0 {
		t.Fatalf("SampleStats re-mapped %d times", maps)
	}
}

func TestSampleStatsRefusals(t *testing.T) {
	statsWindow = nil
	t.Cleanup(func() { statsWindow = nil })
	f := &compFake{replies: map[uint32]int64{vi.GpucompStats: -vi.ErrENXIO}}
	compHarness(t, f)
	if _, err := SampleStats(); !errors.Is(err, ErrComputeNoDevice) {
		t.Fatalf("err=%v, want ErrComputeNoDevice", err)
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
