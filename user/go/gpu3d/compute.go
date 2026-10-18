package gpu3d

// The app-side GPU compute client (M111b, issue #2409; ADR 0053 + the
// ADR 0007 slot-90 amendment). The seam is ONE frozen 128-byte
// descriptor through sys_gpucomp — open a session, allocate bounded
// buffers, stage bytes through an owned mmap window, run one of the
// three pinned kernels, read results back. There is no general shader
// path, no raw stream and no GPU address anywhere in this API.
//
// Everything synchronous: RUN blocks inside the kernel's bounded
// exchange until the device's fence completes — the fence wait IS the
// call returning. A refused or poisoned session surfaces through the
// named error table below, which mirrors the kernel's refusal list
// exactly (ADR 0053 D5).

import (
	"errors"
	"math"
	"strconv"
	"unsafe"

	"virelai/vi"
)

// The named refusal table — one Go error per kernel refusal class, so a
// caller can distinguish a malformed descriptor from a busy device or a
// poisoned session without parsing strings.
var (
	// ErrComputeInvalid is EINVAL: a malformed descriptor, an unknown
	// kernel id, a bad shape or a bad buffer binding.
	ErrComputeInvalid = errors.New("gpu3d: compute descriptor invalid")
	// ErrComputeBadHandle is EBADF: a handle that never was, or a stale
	// generation after close/free/owner-exit.
	ErrComputeBadHandle = errors.New("gpu3d: bad or stale compute handle")
	// ErrComputeExhausted is ENOSPC: the single session is taken, the
	// ctx pool or the bounded io/staging pools are full.
	ErrComputeExhausted = errors.New("gpu3d: compute pool exhausted")
	// ErrComputeNoDevice is ENXIO (or ENOSYS on an older kernel): no
	// VIC1 capset, or the backend advertised ready=0.
	ErrComputeNoDevice = errors.New("gpu3d: no compute device")
	// ErrComputeBusy is EAGAIN: the one-outstanding device request is
	// occupied — never a reason to fabricate work.
	ErrComputeBusy = errors.New("gpu3d: device busy")
	// ErrComputeTimedOut is ETIMEDOUT: the bounded exchange deadline
	// passed; the session is poisoned from here on.
	ErrComputeTimedOut = errors.New("gpu3d: compute exchange timed out")
	// ErrComputeLost is ENOENT: the session was poisoned/quarantined —
	// only CLOSE still answers.
	ErrComputeLost = errors.New("gpu3d: compute session lost")
	// ErrComputeFault is EFAULT: a user VA the kernel could not read or
	// write (descriptor, payload or stats dst).
	ErrComputeFault = errors.New("gpu3d: user address fault")
	// ErrComputeDevice is EIO: the device refused or faulted mid-op.
	ErrComputeDevice = errors.New("gpu3d: compute device fault")
)

// compErr maps a sys_gpucomp return into the named table — every kernel
// refusal lands on a name a caller can switch on.
func compErr(rc int64) error {
	if rc >= 0 {
		return nil
	}
	switch -rc {
	case vi.ErrEINVAL:
		return ErrComputeInvalid
	case vi.ErrEBADF:
		return ErrComputeBadHandle
	case vi.ErrENOSPC:
		return ErrComputeExhausted
	case vi.ErrENXIO, vi.ErrENOSYS:
		return ErrComputeNoDevice
	case vi.ErrEAGAIN:
		return ErrComputeBusy
	case vi.ErrETIMEDOUT:
		return ErrComputeTimedOut
	case vi.ErrENOENT:
		return ErrComputeLost
	case vi.ErrEFAULT:
		return ErrComputeFault
	case vi.ErrEIO:
		return ErrComputeDevice
	default:
		return errors.New("gpu3d: compute syscall errno " + strconv.FormatInt(-rc, 10))
	}
}

// ---------------------------------------------------------------------------
// The frozen 64-byte kernel descriptor (ADR 0053 D3)
// ---------------------------------------------------------------------------

// KernelBuf is one descriptor buffer slot: `buf` is the low 32 bits of
// the buffer handle (gen:8 | slot:8 | ctx:16 — the kernel decodes and
// translates it to a wire res_id), 0 = the slot is absent.
type KernelBuf struct {
	Buf     uint32
	ByteOff uint32
}

// KernelDesc is the typed form of the frozen 64-byte kernel descriptor —
// the same bytes the COMPUTE_SUBMIT request carries on the wire. The
// trailing u64 reserved word is always emitted zero.
type KernelDesc struct {
	Kernel uint32 // vi.GpuKernel* — 1 GEMM, 2 SOFTMAX, 3 DEQUANT
	Flags  uint32 // per-kernel bits (vi.GpuGemm*/GpuSoftmax*)
	D0     uint32 // GEMM M / SOFTMAX rows / DEQUANT n
	D1     uint32 // GEMM N / SOFTMAX cols / DEQUANT group_size
	D2     uint32 // GEMM K; else 0
	Aux    uint32 // DEQUANT fmt in byte 0; else 0
	Bufs   [4]KernelBuf
}

// Encode marshals the descriptor little-endian — the same layout the
// kernel's parse_kernel_desc reads.
func (d KernelDesc) Encode() (out [vi.GpucompKdescBytes]byte) {
	put := func(at int, v uint32) {
		out[at] = byte(v)
		out[at+1] = byte(v >> 8)
		out[at+2] = byte(v >> 16)
		out[at+3] = byte(v >> 24)
	}
	put(0, d.Kernel)
	put(4, d.Flags)
	put(8, d.D0)
	put(12, d.D1)
	put(16, d.D2)
	put(20, d.Aux)
	for i, b := range d.Bufs {
		put(24+i*8, b.Buf)
		put(28+i*8, b.ByteOff)
	}
	return out
}

// ---------------------------------------------------------------------------
// Session + buffers
// ---------------------------------------------------------------------------

// Weight marks a BUF_ALLOC as a weight-class buffer (descriptor flags
// bit 0): it stages through the shared 4 MiB window, one chunk per WRITE.
const BufWeight = true
const BufIO = false

// ComputeStatsBlock is the frozen 64-byte STATS block (ADR 0053 D6).
type ComputeStatsBlock struct {
	Busy          uint32
	Queued        uint32
	SessionsLive  uint32
	Reserved      uint32
	LastKernelUs  uint64
	TotalKernelUs uint64
	Submits       uint64
	Completed     uint64
	Refusals      uint64
	Timeouts      uint64
}

// compStageBytes is the app's I/O staging window — every WRITE/READ/STATS
// payload VA must be an mmap'd region; app data is chunked through here.
const compStageBytes = 256 * 1024

// One mapped window carries every kernel-visible buffer: the 128-byte
// descriptor at offset 0, the 64-byte STATS block at 128, and the I/O
// staging from the first page boundary. One region matters — the guest
// kernel caps a process's mmap table at 16 entries and the Go runtime's
// own reservations already use several.
const compMapBytes = compStageBytes + 4096

// compScratchVA is the compute window's address hint — the same band
// the seat's descriptor pages use (clear of the sbrk heap and the
// randomized EL0 stack band); an auto-picked VA can collide with the
// runtime's hinted reservations because those never advance the
// kernel's own mmap cursor.
const compScratchVA = 0x0000_0002_8000_0000

// ComputeSession is one live OPEN: owner-keyed, generation-bearing,
// single-tenancy (a second CONCURRENT OPEN is ErrComputeExhausted; a
// second session after Close works — Close releases the fixed-VA
// window). Not safe for concurrent use — the device itself allows at
// most one outstanding request.
type ComputeSession struct {
	handle uint64
	window []byte // the whole compMapBytes aperture, for unmap on Close
	desc   []byte // window[0:128] — the descriptor bytes
	stats  []byte // window[128:192] — the STATS block
	stage  []byte // window[4096:] — WRITE/READ payloads
	closed bool
}

// CompSyscall issues one sys_gpucomp on the encoded descriptor page;
// CompMap reserves a uaccess-reachable window (vi.MmapHint in the
// guest) and CompUnmap releases it (vi.Munmap). All three are the
// deliberate injection seam — host tests replace them to drive a
// session offline, exactly like the render client's injectable
// Transport.
var (
	CompSyscall = vi.Gpucomp
	CompMap     = vi.MmapHint
	CompUnmap   = vi.Munmap
)

func (s *ComputeSession) call(d vi.GpucompDesc) (int64, error) {
	if s.closed {
		// The window is gone after Close — never encode into it, and
		// answer with the same refusal the kernel gives a stale handle.
		return -vi.ErrEBADF, nil
	}
	if err := d.EncodeDesc(s.desc); err != nil {
		return 0, err
	}
	return CompSyscall(s.desc[:vi.GpucompDescBytes]), nil
}

// OpenCompute takes the single compute session: probes VIC1, claims a
// shared-pool ctx, and maps the descriptor/staging windows. ENXIO when
// the device is absent or the backend reports ready=0.
func OpenCompute() (*ComputeSession, error) {
	s := &ComputeSession{}
	window, err := CompMap(compScratchVA, compMapBytes,
		vi.ProtRead|vi.ProtWrite, vi.MapAnonymous)
	if err != nil {
		return nil, err
	}
	s.window = window
	s.desc = window[:vi.GpucompDescBytes]
	s.stats = window[vi.GpucompDescBytes : vi.GpucompDescBytes+vi.GpucompStatsBytes]
	s.stage = window[4096:]
	rc, err := s.call(vi.GpucompDesc{Op: vi.GpucompOpen})
	if err == nil {
		err = compErr(rc)
	}
	if err != nil {
		// A refused OPEN must not keep the fixed-VA aperture claimed —
		// the process's next OpenCompute maps this same band.
		_ = s.unmapWindow()
		return nil, err
	}
	s.handle = uint64(rc)
	return s, nil
}

// unmapWindow releases the descriptor/staging aperture so the fixed-VA
// band at compScratchVA is claimable by the process's next session.
// Idempotent; the sub-slices go nil so no later op can stage into the
// unmapped VA.
func (s *ComputeSession) unmapWindow() error {
	if s.window == nil {
		return nil
	}
	err := CompUnmap(s.window)
	s.window, s.desc, s.stats, s.stage = nil, nil, nil, nil
	return err
}

// Close invalidates the handle (every later op is EBADF), drains the
// session's buffers and ctx, and unmaps the fixed-VA window — the bit
// #2494 was missing, which capped a process at one session ever.
// Idempotent.
func (s *ComputeSession) Close() error {
	if s == nil || s.closed {
		return nil
	}
	rc, err := s.call(vi.GpucompDesc{Op: vi.GpucompClose, Handle: s.handle})
	s.closed = true
	unmapErr := s.unmapWindow()
	if err != nil {
		return err
	}
	if cerr := compErr(rc); cerr != nil {
		return cerr
	}
	return unmapErr
}

// AllocBuffer reserves a bounded buffer: `size` bytes (1..16 MiB); weight
// buffers stage through the shared window. Returns the generation-bearing
// buffer handle — its low 32 bits are what a KernelDesc buf slot takes.
func (s *ComputeSession) AllocBuffer(size uint32, weight bool) (uint64, error) {
	if size == 0 || size > (16*1024*1024) {
		return 0, ErrComputeInvalid
	}
	var flags uint32
	if weight {
		flags = 1 // kernel flag_weight
	}
	rc, err := s.call(vi.GpucompDesc{
		Op: vi.GpucompBufAlloc, Handle: s.handle, Flags: flags, ArgA: uint64(size),
	})
	if err != nil {
		return 0, err
	}
	if err := compErr(rc); err != nil {
		return 0, err
	}
	return uint64(rc), nil
}

// FreeBuffer drains one live buffer (detach → unref → pool release).
func (s *ComputeSession) FreeBuffer(buf uint64) error {
	rc, err := s.call(vi.GpucompDesc{Op: vi.GpucompBufFree, Handle: buf})
	if err != nil {
		return err
	}
	return compErr(rc)
}

// SealBuffer detaches the buffer's guest backing: the DMA share is gone,
// later WRITE/READ on it refuse. A second seal is ErrComputeInvalid.
func (s *ComputeSession) SealBuffer(buf uint64) error {
	rc, err := s.call(vi.GpucompDesc{Op: vi.GpucompSeal, Handle: buf})
	if err != nil {
		return err
	}
	return compErr(rc)
}

// Write stages `data` into the buffer at `off` — one bounded transfer per
// staging chunk (≤ compStageBytes each; the kernel additionally caps a
// weight chunk at the 4 MiB window).
func (s *ComputeSession) Write(buf uint64, off uint64, data []byte) error {
	done := 0
	for done < len(data) {
		n := len(data) - done
		if n > len(s.stage) {
			n = len(s.stage)
		}
		copy(s.stage[:n], data[done:done+n])
		rc, err := s.call(vi.GpucompDesc{
			Op: vi.GpucompWrite, Handle: buf,
			ArgA: stageVA(s.stage), ArgB: uint64(n), ArgC: off + uint64(done),
		})
		if err != nil {
			return err
		}
		if err := compErr(rc); err != nil {
			return err
		}
		done += n
	}
	return nil
}

// Read fetches `len(out)` bytes of the buffer starting at `off` back
// through the staging window — the DMA runs device → kernel pool → user.
func (s *ComputeSession) Read(buf uint64, off uint64, out []byte) error {
	done := 0
	for done < len(out) {
		n := len(out) - done
		if n > len(s.stage) {
			n = len(s.stage)
		}
		rc, err := s.call(vi.GpucompDesc{
			Op: vi.GpucompRead, Handle: buf,
			ArgA: stageVA(s.stage), ArgB: uint64(n), ArgC: off + uint64(done),
		})
		if err != nil {
			return err
		}
		if err := compErr(rc); err != nil {
			return err
		}
		copy(out[done:done+n], s.stage[:n])
		done += n
	}
	return nil
}

// Run submits one kernel descriptor and returns when the device's fence
// completes — the synchronous fence wait IS this call (the kernel's
// bounded exchange). Its result is visible to a following Read.
func (s *ComputeSession) Run(kd KernelDesc) error {
	d := vi.GpucompDesc{Op: vi.GpucompRun, Handle: s.handle}
	d.Kdesc = kd.Encode()
	rc, err := s.call(d)
	if err != nil {
		return err
	}
	return compErr(rc)
}

// Stats copies the frozen 64-byte block through the session's stats
// window. STATS is handle-free in the kernel, but the session's own
// staging keeps one mmap discipline in one place.
func (s *ComputeSession) Stats() (ComputeStatsBlock, error) {
	var b ComputeStatsBlock
	rc, err := s.call(vi.GpucompDesc{
		Op: vi.GpucompStats, ArgA: stageVA(s.stats),
	})
	if err != nil {
		return b, err
	}
	if err := compErr(rc); err != nil {
		return b, err
	}
	return decodeStats(s.stats), nil
}

// decodeStats reads the frozen 64-byte STATS block (ADR 0053 D6) out of a
// mapped window — the one decode both Stats and SampleStats share.
func decodeStats(blk []byte) ComputeStatsBlock {
	var b ComputeStatsBlock
	u32 := func(at int) uint32 {
		return uint32(blk[at]) | uint32(blk[at+1])<<8 |
			uint32(blk[at+2])<<16 | uint32(blk[at+3])<<24
	}
	u64 := func(at int) uint64 {
		return uint64(u32(at)) | uint64(u32(at+4))<<32
	}
	b.Busy = u32(0)
	b.Queued = u32(4)
	b.SessionsLive = u32(8)
	b.Reserved = u32(12)
	b.LastKernelUs = u64(16)
	b.TotalKernelUs = u64(24)
	b.Submits = u64(32)
	b.Completed = u64(40)
	b.Refusals = u64(48)
	b.Timeouts = u64(56)
	return b
}

// statsScratchVA is the stats-only window's hint — compMapBytes above the
// session aperture so a process holding a session AND sampling stats does
// not collide with its own mapping.
const statsScratchVA = compScratchVA + compMapBytes

// statsWindow is the lazily-mapped descriptor+block aperture SampleStats
// reuses. The kernel caps a process's mmap table at 16 entries, so one
// process-lifetime page is kept rather than a map/unmap pair per call —
// a 1 Hz poll would otherwise churn the bounded table for no gain.
var statsWindow []byte

// SampleStats reads the broker's frozen 64-byte STATS block WITHOUT
// claiming the compute session — STATS is handle-free in the kernel
// (gpu3d_compute's do_stats needs only a destination VA), so a monitor can
// poll the counters while a real workload holds the single OPEN.
func SampleStats() (ComputeStatsBlock, error) {
	var b ComputeStatsBlock
	if statsWindow == nil {
		window, err := CompMap(statsScratchVA, 4096,
			vi.ProtRead|vi.ProtWrite, vi.MapAnonymous)
		if err != nil {
			return b, err
		}
		statsWindow = window
	}
	desc := statsWindow[:vi.GpucompDescBytes]
	blk := statsWindow[vi.GpucompDescBytes : vi.GpucompDescBytes+vi.GpucompStatsBytes]
	d := vi.GpucompDesc{Op: vi.GpucompStats, ArgA: stageVA(blk)}
	if err := d.EncodeDesc(desc); err != nil {
		return b, err
	}
	if err := compErr(CompSyscall(desc)); err != nil {
		return b, err
	}
	return decodeStats(blk), nil
}

// stageVA is the payload pointer the kernel copies through checked
// uaccess — the same seam the cmd-22 descriptor uses.
func stageVA(b []byte) uint64 {
	if len(b) == 0 {
		return 0
	}
	return uint64(uintptr(unsafe.Pointer(&b[0])))
}

// ---------------------------------------------------------------------------
// IEEE 754 half codec — GEMM/DEQUANT payloads are f16 (original: standard
// round-to-nearest-even conversion, no imported code)
// ---------------------------------------------------------------------------

// F16bits converts a float32 to its IEEE binary16 bit pattern. Round to
// nearest, ties to even; overflow saturates to ±Inf; subnormals carry.
func F16bits(v float32) uint16 {
	f := math.Float32bits(v)
	sign := uint16(f>>16) & 0x8000
	exp := int(f>>23) & 0xff
	mant := f & 0x7fffff
	if exp == 0xff { // Inf/NaN — NaN keeps a nonzero payload bit
		out := sign | 0x7c00 | uint16(mant>>13)
		if mant != 0 {
			out |= 1
		}
		return out
	}
	he := exp - 127 + 15
	switch {
	case he >= 31:
		return sign | 0x7c00 // overflow → Inf
	case he <= 0: // subnormal or zero
		if he < -10 {
			return sign // too small — underflows to signed zero
		}
		m := mant | 0x800000 // restore the implicit leading bit
		shift := uint(14 - he)
		h := uint16(m >> shift)
		rem := m & ((1 << shift) - 1)
		mid := uint32(1) << (shift - 1)
		if rem > mid || (rem == mid && h&1 == 1) {
			h++
		}
		return sign | h
	default:
		h := uint16(he<<10) | uint16(mant>>13)
		rem := mant & 0x1fff // dropped low 13 bits
		if rem > 0x1000 || (rem == 0x1000 && h&1 == 1) {
			h++
		}
		return sign | h
	}
}

// F32bits converts an IEEE binary16 pattern back to float32.
func F32bits(h uint16) float32 {
	sign := float64(1)
	if h&0x8000 != 0 {
		sign = -1
	}
	exp := int(h>>10) & 0x1f
	mant := float64(h & 0x3ff)
	switch {
	case exp == 0:
		return float32(sign * mant / 1024 * 0x1p-14)
	case exp == 31:
		if mant == 0 {
			return float32(math.Inf(int(sign)))
		}
		return float32(math.NaN())
	default:
		return float32(sign * (1 + mant/1024) * math.Ldexp(1, exp-15))
	}
}
