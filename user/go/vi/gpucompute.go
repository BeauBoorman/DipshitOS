package vi

import "unsafe"

// M111b (issue #2409, ADR 0053 D5 + the ADR 0007 slot-90 amendment):
// sys_gpucomp — the GPU compute seam. ONE 128-byte descriptor per call,
// copied through checked uaccess; the bytes MUST live in a mapped page
// (MmapHint) — a Go stack pointer is not guaranteed mapped for EL1, the
// same convention the slot-65 cmd-22 descriptor follows. a0 mirrors
// desc.op (the kernel refuses a mismatch) and a1..a3 are reserved-zero
// per the slot's call contract.

const (
	// GpucompDescBytes is the frozen descriptor wire length; the kernel
	// refuses any other `len`.
	GpucompDescBytes = 128
	// GpucompKdescBytes is the embedded kernel-descriptor wire length —
	// the same 64 bytes the COMPUTE_SUBMIT request carries.
	GpucompKdescBytes = 64
	// GpucompStatsBytes is the frozen STATS block length.
	GpucompStatsBytes = 64
)

// The nine broker operations (gpu3d_compute.zig). 0 and >=10 fail closed.
const (
	GpucompOpen     uint32 = 1 // -> session handle
	GpucompClose    uint32 = 2 // handle
	GpucompBufAlloc uint32 = 3 // arg_a=size -> buffer handle
	GpucompBufFree  uint32 = 4 // arg_a=buffer handle
	GpucompWrite    uint32 = 5 // arg_a=buf, arg_b=dst VA, arg_c=len
	GpucompRead     uint32 = 6 // arg_a=buf, arg_b=src VA, arg_c=len
	GpucompSeal     uint32 = 7 // handle -> seal weight-side buffers
	GpucompRun      uint32 = 8 // handle + kdesc
	GpucompStats    uint32 = 9 // arg_a=dst VA -> the 64-byte block
)

// The curated kernel library (ADR 0053 D3).
const (
	GpuKernelGEMM    uint32 = 1
	GpuKernelSoftmax uint32 = 2
	GpuKernelDequant uint32 = 3
)

// The flag/aux vocabulary.
const (
	GpuGemmBias         uint32 = 1 // buf3 is bias f16[N]
	GpuGemmBTransposed  uint32 = 2 // B is [N,K] instead of [K,N]
	GpuSoftmaxInPlace   uint32 = 1 // caller declares in == out
	GpuDequantFmtI8Sym  uint32 = 1 // aux fmt: q8 symmetric, scales only
	GpuDequantFmtU4Asym uint32 = 2 // aux fmt: nibble + zeros + scales
)

// ErrEIO is the device-fault errno the compute broker maps a backend
// refusal/fault to; it was already the errno table's default name and
// now has a named constant.
const ErrEIO int64 = 13

// GpucompDesc is the typed form of the 128-byte descriptor:
//
//	off  size  field
//	0    4     op         1..9
//	4    4     flags      op-scoped — BUF_ALLOC bit0 is flag_weight
//	8    8     handle     generation-bearing session or buffer handle
//	16   8     arg_a      op-dependent (size / dst-or-src VA / STATC dst)
//	24   8     arg_b      op-dependent (WRITE/READ len)
//	32   8     arg_c      op-dependent (WRITE/READ buffer offset)
//	40   24    reserved   always 0 — no field, cannot be expressed
//	64   64    kdesc      the frozen kernel descriptor (RUN only)
//
// Fields a given op does not take must be zero; EncodeDesc refuses an
// out-of-vocabulary descriptor rather than emitting a frame the kernel
// would only reject.
type GpucompDesc struct {
	Op     uint32
	Flags  uint32
	Handle uint64
	ArgA   uint64
	ArgB   uint64
	ArgC   uint64
	// Kdesc is the verbatim 64-byte kernel descriptor (see the gpu3d
	// package's KernelDesc marshaler); RUN only, zero elsewhere.
	Kdesc [GpucompKdescBytes]byte
}

// EncodeDesc validates d and writes it little-endian into out[128].
// flags and the 24 reserved bytes are emitted as zero by construction.
// out is the caller's mapped staging slice — nothing here takes a Go
// stack pointer for the kernel.
func (d GpucompDesc) EncodeDesc(out []byte) error {
	if len(out) < GpucompDescBytes {
		return errno(ErrEINVAL)
	}
	if d.Op < GpucompOpen || d.Op > GpucompStats {
		return errno(ErrEINVAL)
	}
	// Per-op field discipline: kdesc is RUN's only; handle semantics are
	// the kernel's to check (a stale handle is EBADF, not EINVAL).
	kdescZero := d.Kdesc == [GpucompKdescBytes]byte{}
	if d.Op != GpucompRun && !kdescZero {
		return errno(ErrEINVAL)
	}
	for i := 0; i < GpucompDescBytes; i++ {
		out[i] = 0
	}
	putU32(out[0:], d.Op)
	putU32(out[4:], d.Flags)
	putU64(out[8:], d.Handle)
	putU64(out[16:], d.ArgA)
	putU64(out[24:], d.ArgB)
	putU64(out[32:], d.ArgC)
	copy(out[64:], d.Kdesc[:])
	return nil
}

// gpucompSyscall is the svc gateway; host tests stub it to pin the
// argument shape (the four-arg syscallHook cannot see a six-arg call).
var gpucompSyscall = syscall6

// Gpucomp submits one encoded 128-byte descriptor (slot 90). a0 echoes
// the descriptor's op — a mismatch is EINVAL — a1..a3 are reserved-zero.
// Returns the op result: a generation-bearing handle on OPEN/BUF_ALLOC,
// 0 on the rest, or the negative errno from the refusal table
// (ENOSYS/EFAULT/EINVAL/EBADF/ENOSPC/ENXIO/EAGAIN/ETIMEDOUT/ENOENT/EIO).
func Gpucomp(desc []byte) int64 {
	if len(desc) != GpucompDescBytes {
		return -ErrEINVAL
	}
	return gpucompSyscall(SlotGpucomp, uintptr(getU32LE(desc[0:])), 0, 0, 0,
		uintptr(unsafe.Pointer(&desc[0])), uintptr(GpucompDescBytes))
}

func getU32LE(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}
