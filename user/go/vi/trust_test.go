package vi

import (
	"testing"
	"unsafe"
)

// The trust slot numbers are the kernel's (ADR 0007 slot 68/69/70); pin them
// so a drift fails the host suite instead of the VM gate.
func TestTrustSlotNumbers(t *testing.T) {
	if SlotPrincipal != 68 || SlotFileMode != 69 || SlotSecretGet != 70 {
		t.Fatalf("trust slots = %d/%d/%d want 68/69/70",
			SlotPrincipal, SlotFileMode, SlotSecretGet)
	}
}

// The record geometry is the kernel's wire format: a drift would mis-parse
// the byte stream rather than fail, so every bound is pinned.
func TestTrustGeometry(t *testing.T) {
	if PrincipalBytes != 8 {
		t.Fatalf("PrincipalBytes = %d want 8", PrincipalBytes)
	}
	if SecretEntryBytes != 108 {
		t.Fatalf("SecretEntryBytes = %d want 108", SecretEntryBytes)
	}
	if SecretKeyMax != 32 || SecretValMax != 64 || SecretEntriesMax != 8 {
		t.Fatalf("secret bounds = %d/%d/%d want 32/64/8",
			SecretKeyMax, SecretValMax, SecretEntriesMax)
	}
	if UidSystem != 0 || UidUser != 1000 || UidAgent != 2000 {
		t.Fatalf("uids = %d/%d/%d want 0/1000/2000", UidSystem, UidUser, UidAgent)
	}
}

// Off-guest there is no kernel: the principal report cannot answer its full
// record, so Principal must report ok=false rather than a fabricated uid 0.
func TestPrincipalUnavailableOffGuest(t *testing.T) {
	if uid, caps, ok := Principal(); ok {
		t.Fatalf("host Principal = (%d,%d,ok) want ok=false", uid, caps)
	}
}

// The principal record is two little-endian u32 words: uid then caps.
func TestPrincipalParsesTheRecord(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotPrincipal {
			t.Fatalf("called slot %d want %d", num, SlotPrincipal)
		}
		buf := unsafe.Slice((*byte)(unsafe.Pointer(a0)), PrincipalBytes)
		buf[0], buf[1] = 0xe8, 0x03 // 1000
		buf[4] = 0x00               // caps 0
		return PrincipalBytes
	})
	defer SetSyscallHookForTest(prev)

	uid, caps, ok := Principal()
	if !ok || uid != UidUser || caps != 0 {
		t.Fatalf("Principal = (%d,%d,%v) want (1000,0,true)", uid, caps, ok)
	}
}

// A short answer is not an identity: the kernel returns the byte count, so
// anything but 8 must be refused.
func TestPrincipalRefusesAShortRecord(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		return 4
	})
	defer SetSyscallHookForTest(prev)
	if _, _, ok := Principal(); ok {
		t.Fatal("Principal accepted a 4-byte record")
	}
}

// chmod forwards (path, len, mode) to slot 69 and returns the kernel's result
// untouched.
func TestFileModeForwardsTheTriplet(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotFileMode {
			t.Fatalf("called slot %d want %d", num, SlotFileMode)
		}
		got := unsafe.String((*byte)(unsafe.Pointer(a0)), int(a1))
		if got != "PLAIN.TXT" {
			t.Fatalf("path = %q want PLAIN.TXT", got)
		}
		if a2 != 0o600 {
			t.Fatalf("mode = %o want 600", a2)
		}
		return 0
	})
	defer SetSyscallHookForTest(prev)
	if r := FileMode("PLAIN.TXT", 0o600); r != 0 {
		t.Fatalf("FileMode = %d want 0", r)
	}
}

// An ownership denial must come back as the kernel's own errno, not folded
// into a generic failure: the shell prints this name.
func TestFileModePropagatesEACCES(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		return -ErrEACCES
	})
	defer SetSyscallHookForTest(prev)
	if r := FileMode("TARGET.TXT", 0o600); r != -ErrEACCES {
		t.Fatalf("FileMode = %d want %d", r, -ErrEACCES)
	}
}

// The secret records parse into names and values with the recorded lengths,
// and a caller with nothing gets zero entries (not an error).
func TestSecretListParsesRecords(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotSecretGet {
			t.Fatalf("called slot %d want %d", num, SlotSecretGet)
		}
		if int(a1) != SecretEntriesMax*SecretEntryBytes {
			t.Fatalf("buffer = %d want %d", a1, SecretEntriesMax*SecretEntryBytes)
		}
		buf := unsafe.Slice((*byte)(unsafe.Pointer(a0)), int(a1))
		putU32(buf[0:], UidUser)
		putU32(buf[4:], 6) // "netkey"
		putU32(buf[8:], 9) // "shh-value"
		copy(buf[12:], "netkey")
		copy(buf[12+SecretKeyMax:], "shh-value")
		off := SecretEntryBytes
		putU32(buf[off:], UidUser)
		putU32(buf[off+4:], 5) // "other"
		putU32(buf[off+8:], 3) // "abc"
		copy(buf[off+12:], "other")
		copy(buf[off+12+SecretKeyMax:], "abc")
		return int64(2 * SecretEntryBytes)
	})
	defer SetSyscallHookForTest(prev)

	var dst [SecretEntriesMax]SecretRecord
	n, r := SecretList(dst[:])
	if r < 0 || n != 2 {
		t.Fatalf("SecretList = %d/%d want 2 records", n, r)
	}
	if dst[0].KeyString() != "netkey" || dst[0].ValString() != "shh-value" {
		t.Fatalf("record 0 = %q/%q", dst[0].KeyString(), dst[0].ValString())
	}
	if dst[1].KeyString() != "other" || dst[1].ValString() != "abc" {
		t.Fatalf("record 1 = %q/%q", dst[1].KeyString(), dst[1].ValString())
	}
	if dst[0].UID != UidUser {
		t.Fatalf("record 0 uid = %d want %d", dst[0].UID, UidUser)
	}
}

// The record count is bounded by the caller's buffer, never by what the
// kernel claims to have written.
func TestSecretListBoundsTheCount(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		return int64(SecretEntriesMax * SecretEntryBytes)
	})
	defer SetSyscallHookForTest(prev)
	var one [1]SecretRecord
	n, _ := SecretList(one[:])
	if n != 1 {
		t.Fatalf("SecretList filled %d records into a 1-record buffer", n)
	}
}

// A nil destination is a no-op, not a syscall with a null pointer.
func TestSecretListEmptyDestination(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		t.Fatalf("slot %d called with an empty buffer", num)
		return 0
	})
	defer SetSyscallHookForTest(prev)
	if n, r := SecretList(nil); n != 0 || r != 0 {
		t.Fatalf("SecretList(nil) = %d/%d want 0/0", n, r)
	}
}

// ErrnoName is what the shell prints, so it must spell the kernel's names and
// stay silent for a success result.
func TestErrnoName(t *testing.T) {
	if got := ErrnoName(-ErrEACCES); got != "EACCES" {
		t.Fatalf("ErrnoName(-EACCES) = %q want EACCES", got)
	}
	if got := ErrnoName(-ErrENOENT); got != "ENOENT" {
		t.Fatalf("ErrnoName(-ENOENT) = %q want ENOENT", got)
	}
	if got := ErrnoName(0); got != "" {
		t.Fatalf("ErrnoName(0) = %q want empty", got)
	}
}
