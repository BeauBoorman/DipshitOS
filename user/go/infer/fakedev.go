package infer

// The kernel-emulating fake device: a Dev implementation that keeps real
// buffer bytes and executes the three pinned kernels in software, the
// same arithmetic the Metal pipelines do (f16 storage, f32 accumulate).
// It makes the forward path testable end to end on the host: a run
// through the fake is a run through every kernel binding the real
// session would issue. It is a test double — the guest binaries never
// import it.

import (
	"math"

	"virelai/gpu3d"
	"virelai/vi"
)

type FakeDev struct {
	bufs    map[uint64][]byte
	sealed  map[uint64]bool
	next    uint64
	closed  bool
	writes  int
	runs    int
	Submits map[uint32]int // kernel_id -> count
}

func NewFakeDev() *FakeDev {
	return &FakeDev{
		bufs:    map[uint64][]byte{},
		sealed:  map[uint64]bool{},
		Submits: map[uint32]int{},
		next:    1,
	}
}

func (f *FakeDev) AllocBuffer(size uint32, weight bool) (uint64, error) {
	h := f.next
	f.next++
	f.bufs[h] = make([]byte, size)
	return h, nil
}

func (f *FakeDev) FreeBuffer(h uint64) error {
	if _, ok := f.bufs[h]; !ok {
		return gpu3d.ErrComputeBadHandle
	}
	delete(f.bufs, h)
	delete(f.sealed, h)
	return nil
}

func (f *FakeDev) SealBuffer(h uint64) error {
	if _, ok := f.bufs[h]; !ok {
		return gpu3d.ErrComputeBadHandle
	}
	if f.sealed[h] {
		return gpu3d.ErrComputeInvalid
	}
	f.sealed[h] = true
	return nil
}

func (f *FakeDev) Write(h uint64, off uint64, data []byte) error {
	if f.sealed[h] {
		return gpu3d.ErrComputeInvalid
	}
	b, ok := f.bufs[h]
	if !ok {
		return gpu3d.ErrComputeBadHandle
	}
	if off+uint64(len(data)) > uint64(len(b)) {
		return gpu3d.ErrComputeInvalid
	}
	copy(b[off:], data)
	f.writes++
	return nil
}

func (f *FakeDev) Read(h uint64, off uint64, out []byte) error {
	if f.sealed[h] {
		return gpu3d.ErrComputeInvalid
	}
	b, ok := f.bufs[h]
	if !ok {
		return gpu3d.ErrComputeBadHandle
	}
	if off+uint64(len(out)) > uint64(len(b)) {
		return gpu3d.ErrComputeInvalid
	}
	copy(out, b[off:])
	return nil
}

// bound resolves a descriptor slot to a byte slice, honoring byte_off and
// the absent-slot {0,0} rule like the real validator.
func (f *FakeDev) bound(s gpu3d.KernelBuf, need uint64) ([]byte, error) {
	if s.Buf == 0 {
		if need == 0 && s.ByteOff == 0 {
			return nil, nil
		}
		return nil, gpu3d.ErrComputeInvalid
	}
	b, ok := f.bufs[uint64(s.Buf)]
	if !ok {
		return nil, gpu3d.ErrComputeBadHandle
	}
	if need > uint64(len(b)) || uint64(s.ByteOff) > uint64(len(b))-need {
		return nil, gpu3d.ErrComputeInvalid
	}
	return b[s.ByteOff : uint64(s.ByteOff)+need], nil
}

func (f *FakeDev) Run(kd gpu3d.KernelDesc) error {
	f.runs++
	f.Submits[kd.Kernel]++
	switch kd.Kernel {
	case vi.GpuKernelGEMM:
		return f.runGEMM(kd)
	case vi.GpuKernelSoftmax:
		return f.runSoftmax(kd)
	case vi.GpuKernelDequant:
		return f.runDequant(kd)
	}
	return gpu3d.ErrComputeInvalid
}

func (f *FakeDev) Stats() (gpu3d.ComputeStatsBlock, error) {
	var st gpu3d.ComputeStatsBlock
	for _, n := range f.Submits {
		st.Submits += uint64(n)
	}
	st.Completed = st.Submits
	return st, nil
}

func (f *FakeDev) Close() error { f.closed = true; return nil }

func f16At(b []byte, i int) float32 {
	return gpu3d.F32bits(uint16(b[2*i]) | uint16(b[2*i+1])<<8)
}

func f16Put(b []byte, i int, v float32) {
	h := gpu3d.F16bits(v)
	b[2*i] = byte(h)
	b[2*i+1] = byte(h >> 8)
}

// runGEMM: C[M,N] = A[M,K]·B[K,N], f16 storage, f32 accumulate — the same
// contract the Metal pipeline implements.
func (f *FakeDev) runGEMM(kd gpu3d.KernelDesc) error {
	M, N, K := int(kd.D0), int(kd.D1), int(kd.D2)
	if M < 1 || N < 1 || K < 1 || M > 4096 || N > 4096 || K > 4096 {
		return gpu3d.ErrComputeInvalid
	}
	a, err := f.bound(kd.Bufs[0], uint64(M*K*2))
	if err != nil {
		return err
	}
	bT := kd.Flags&2 != 0
	var bn uint64 = uint64(K * N * 2)
	b, err := f.bound(kd.Bufs[1], bn)
	if err != nil {
		return err
	}
	c, err := f.bound(kd.Bufs[2], uint64(M*N*2))
	if err != nil {
		return err
	}
	var bias []byte
	if kd.Flags&1 != 0 {
		bias, err = f.bound(kd.Bufs[3], uint64(N*2))
		if err != nil {
			return err
		}
	} else if kd.Bufs[3].Buf != 0 || kd.Bufs[3].ByteOff != 0 {
		return gpu3d.ErrComputeInvalid
	}
	for m := 0; m < M; m++ {
		for n := 0; n < N; n++ {
			acc := float64(0)
			for k := 0; k < K; k++ {
				av := float64(f16At(a, m*K+k))
				var bv float64
				if bT {
					bv = float64(f16At(b, n*K+k)) // B is [N,K]
				} else {
					bv = float64(f16At(b, k*N+n)) // B is [K,N]
				}
				acc += av * bv
			}
			if bias != nil {
				acc += float64(f16At(bias, n))
			}
			f16Put(c, m*N+n, float32(acc))
		}
	}
	return nil
}

func (f *FakeDev) runSoftmax(kd gpu3d.KernelDesc) error {
	rows, cols := int(kd.D0), int(kd.D1)
	if rows < 1 || cols < 2 {
		return gpu3d.ErrComputeInvalid
	}
	in, err := f.bound(kd.Bufs[0], uint64(rows*cols*4))
	if err != nil {
		return err
	}
	out, err := f.bound(kd.Bufs[1], uint64(rows*cols*4))
	if err != nil {
		return err
	}
	for r := 0; r < rows; r++ {
		mx := float64(math.Inf(-1))
		for c := 0; c < cols; c++ {
			v := float64(f32at(in, (r*cols+c)*4))
			if v > mx {
				mx = v
			}
		}
		var sum float64
		exps := make([]float64, cols)
		for c := 0; c < cols; c++ {
			exps[c] = math.Exp(float64(f32at(in, (r*cols+c)*4)) - mx)
			sum += exps[c]
		}
		for c := 0; c < cols; c++ {
			putF32(out[(r*cols+c)*4:], float32(exps[c]/sum))
		}
	}
	return nil
}

func (f *FakeDev) runDequant(kd gpu3d.KernelDesc) error {
	n := uint64(kd.D0)
	group := uint64(kd.D1)
	if n == 0 || (group != 32 && group != 64 && group != 128) {
		return gpu3d.ErrComputeInvalid
	}
	groups := (n + group - 1) / group
	var pkLen uint64
	switch kd.Aux {
	case vi.GpuDequantFmtI8Sym:
		pkLen = n // i8
	case vi.GpuDequantFmtU4Asym:
		pkLen = (n + 1) / 2
	default:
		return gpu3d.ErrComputeInvalid
	}
	pk, err := f.bound(kd.Bufs[0], pkLen)
	if err != nil {
		return err
	}
	sc, err := f.bound(kd.Bufs[1], groups*4)
	if err != nil {
		return err
	}
	var zr []byte
	if kd.Aux == vi.GpuDequantFmtU4Asym {
		zr, err = f.bound(kd.Bufs[2], groups*4)
		if err != nil {
			return err
		}
	}
	out, err := f.bound(kd.Bufs[3], n*2)
	if err != nil {
		return err
	}
	for e := uint64(0); e < n; e++ {
		g := e / group
		s := f32at(sc, int(g*4))
		var v float32
		if kd.Aux == vi.GpuDequantFmtI8Sym {
			v = float32(int8(pk[e])) * s
		} else {
			var q int
			if e&1 == 0 {
				q = int(pk[e/2] & 0x0f)
			} else {
				q = int(pk[e/2] >> 4)
			}
			v = (float32(q) - f32at(zr, int(g*4))) * s
		}
		f16Put(out, int(e), v)
	}
	return nil
}
