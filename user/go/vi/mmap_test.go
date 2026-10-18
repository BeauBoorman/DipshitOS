package vi

import "testing"

func TestMmapHintRejectsBadArgs(t *testing.T) {
	if _, err := MmapHint(0, 0, ProtRead|ProtWrite, MapAnonymous); err != errno(ErrEINVAL) {
		t.Fatalf("zero size err = %v want EINVAL", err)
	}
	if _, err := MmapHint(0x1234, PageSize, ProtRead, MapAnonymous); err != errno(ErrEINVAL) {
		t.Fatalf("misaligned hint err = %v want EINVAL", err)
	}
}

// A page-aligned hint passes the pre-check and reaches the syscall, which
// degrades to ENOSYS off the guest — proving the alignment gate let a
// 4096-multiple through rather than refusing it.
func TestMmapHintHostDegrades(t *testing.T) {
	if b, err := MmapHint(0x10000, PageSize*2, ProtRead|ProtWrite, MapAnonymous|MapPrivate); err != errno(ErrENOSYS) || b != nil {
		t.Fatalf("host MmapHint = (%v,%v) want (nil,ENOSYS)", b, err)
	}
	if _, err := MmapHint(0, 1, ProtRead|ProtWrite, MapAnonymous); err != errno(ErrENOSYS) {
		t.Fatalf("hint=0 should still reach the syscall: %v", err)
	}
}

// The rounded length is a whole number of pages (the kernel's mmap contract).
func TestMmapHintRoundsToPage(t *testing.T) {
	// 4097 -> 8192, but off-guest we cannot observe n. What we CAN pin is that
	// a non-multiple size is accepted (not EINVAL) before the syscall.
	if _, err := MmapHint(0x20000, PageSize+1, ProtRead|ProtWrite, MapAnonymous); err != errno(ErrENOSYS) {
		t.Fatalf("odd size should reach the syscall: %v", err)
	}
}

func TestMunmapRejectsEmpty(t *testing.T) {
	if err := Munmap(nil); err != errno(ErrEINVAL) {
		t.Fatalf("nil unmap err = %v want EINVAL", err)
	}
}

// Off the guest the slot-64 stub answers ENOSYS, matching MmapHint's
// degrade — the wrapper must pass the syscall's verdict straight back.
func TestMunmapHostDegrades(t *testing.T) {
	if err := Munmap(make([]byte, PageSize)); err != errno(ErrENOSYS) {
		t.Fatalf("host Munmap = %v want ENOSYS", err)
	}
}
