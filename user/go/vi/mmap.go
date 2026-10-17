package vi

import "unsafe"

// M56c (issue #1314): address-hinted mmap for the shared-anonymous present
// path (slot 63; ADR 0016 shared-anon, ADR 0026 the Go-runtime port).
//
// `MmapAnon` (vi_guest.go) reserves memory with a hint of ZERO, which lets the
// kernel place the mapping wherever it likes. That is fine for a heap or a
// scratch buffer, but it cannot serve a CONTIGUOUS present buffer: a
// shared-anon surface the compositor later maps read-only must land at a
// caller-chosen, page-aligned base so the guest's writes and the WM's leaf
// agree on one address. That is the GOWIN hole — `tools/go/gowin.go` fills a
// back-buffer that the WM must present, and a relocated mapping would break
// the hand-off.
//
// MmapHint closes the hole: it passes the caller's page-aligned address hint
// straight through to `sys_mmap(addr, len, prot, flags)`. The kernel still owns
// placement (it refuses a hint that collides with the caller's own apertures,
// ADR 0007 amendment), so a refused hint is an honest error, not a silent
// relocation.
//
// ADR 0026 D8 stays in force: console writes stage through the data segment
// because Go stacks live in unregistered sbrk regions, so a direct uaccess
// pointer into a stack local is not guaranteed to be mapped for EL1. This
// helper allocates no stack-backed wire buffer.

// MmapHint reserves `size` bytes with `prot`/`flags`, requesting `hint` as the
// base address. The hint must be page-aligned (or zero, meaning "no
// preference"); a non-zero, misaligned hint is EINVAL before any syscall. The
// returned slice is the kernel's own mapping base for the reservation. Off the
// guest this degrades to -ENOSYS.
func MmapHint(hint uintptr, size int, prot, flags uint64) ([]byte, error) {
	if size <= 0 {
		return nil, errno(ErrEINVAL)
	}
	if hint != 0 && hint%PageSize != 0 {
		return nil, errno(ErrEINVAL)
	}
	n := (size + PageSize - 1) &^ (PageSize - 1)
	r := syscall4(SlotMmap, hint, uintptr(n), uintptr(prot), uintptr(flags))
	if r < 0 {
		return nil, errno(-r)
	}
	return mmapSlice(uintptr(r), n), nil
}

// Munmap releases the region `b` maps (sys_munmap, slot 64) — the MmapHint
// counterpart. Pass the slice MmapHint handed back: its base and length are
// exactly the reservation's, so a caller cannot tear half a region by
// accident. A shared-anon surface is full-region only (#2113); a private
// anonymous window unmaps page by page. Off the guest this degrades to
// -ENOSYS, same as MmapHint.
func Munmap(b []byte) error {
	if len(b) == 0 {
		return errno(ErrEINVAL)
	}
	r := syscall2(SlotMunmap, uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)))
	if r < 0 {
		return errno(-r)
	}
	return nil
}
