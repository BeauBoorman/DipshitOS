// The M50 (ADR 0024) trust surface for Go userland: the read-only principal
// report (slot 68), owner-only chmod (slot 69) and the secret store's
// caller-visible entries (slot 70). The Zig shell read these through
// user/src/lib/ui/abi.zig; a Go app needs the same three seams, and nothing
// here is a setter — identity is the kernel's to assign, and the secret store
// has no write path at all (ADR 0024 D8).
package vi

import "unsafe"

// The trust surface's fixed geometry, mirrored from user/src/lib/ui/abi.zig.
// A drift here would mis-parse the kernel's records rather than fail, so the
// host suite pins every one of them (trust_test.go).
const (
	// PrincipalBytes is the slot-68 result: two little-endian u32 words.
	PrincipalBytes = 8
	// SecretKeyMax / SecretValMax bound one store entry's name and value.
	SecretKeyMax = 32
	SecretValMax = 64
	// SecretEntryBytes is the fixed sys_secret_get record: uid, key_len,
	// val_len, then the two bounds as fixed arrays.
	SecretEntryBytes = 4 + 4 + 4 + SecretKeyMax + SecretValMax
	// SecretEntriesMax bounds one sys_secret_get call's record count.
	SecretEntriesMax = 8
)

// The principal ids (ADR 0024 D1). Duplicated from the kernel because the
// kernel module is not reachable from the guest module graph; the same
// duplication user/src/lib/ui/abi.zig carries.
const (
	UidSystem uint32 = 0
	UidUser   uint32 = 1000
	// UidAgent is the kernel-assigned agent principal (ADR 0052 amendment,
	// index D15): AGENTD.ELF binds it by recorded name at exec and agent
	// children inherit it.
	UidAgent uint32 = 2000
)

// Principal reads the calling process's identity through slot 68. It returns
// ok=false when the call did not answer the full 8-byte record — which is
// what a host build (no `svc`) sees, so callers must treat !ok as "no
// identity available" rather than "uid 0". There is no setter.
//
// The `caps` word here is the principal capability BITMASK (cap_fs_any /
// cap_proc_admin / cap_clipboard — ADR 0024), NOT the grant word set: the
// per-process word mask the manifest caps= ceiling narrows (M188a) lives
// on the process's grant state and is never exposed through this slot.
func Principal() (uid uint32, caps uint32, ok bool) {
	var buf [PrincipalBytes]byte
	r := svc1(SlotPrincipal, uintptr(unsafe.Pointer(&buf[0])))
	if r != PrincipalBytes {
		return 0, 0, false
	}
	return le32(buf[0:]), le32(buf[4:]), true
}

// FileMode is owner-only chmod on an existing path (slot 69). mode is the
// 3-digit octal permission value; the group triplet is the kernel's and is
// stored zero. Returns 0, or the negative ADR 0007 error (EACCES when the
// caller does not own the entry, ENOENT absent, EINVAL bad path or mode,
// ENOSPC when the ownership table is full).
func FileMode(path string, mode uint16) int64 {
	return svc3(SlotFileMode, strPtr(path), uintptr(len(path)), uintptr(mode))
}

// SecretRecord is one sys_secret_get record: the entry's owner, the two
// lengths, and both fields as fixed arrays (the kernel's wire shape).
type SecretRecord struct {
	UID    uint32
	KeyLen uint32
	ValLen uint32
	Key    [SecretKeyMax]byte
	Val    [SecretValMax]byte
}

// KeyString is the entry's name, trimmed to its recorded length. Names are
// the only part of an entry a caller may log.
func (r *SecretRecord) KeyString() string { return cstrN(r.Key[:], int(r.KeyLen)) }

// ValString is the entry's value. It exists because a verifier must be able
// to consume it (the net front-end's credential); nothing may print it.
func (r *SecretRecord) ValString() string { return cstrN(r.Val[:], int(r.ValLen)) }

// SecretList reads the CALLING principal's entries (slot 70) into dst,
// returning the entry count. It is the only in-guest reader of the store:
// `cat < SECRETS.TXT` is denied at the file ABI by construction (ADR 0024
// D8), so a caller that needs the value needs this seam.
func SecretList(dst []SecretRecord) (int, int64) {
	if len(dst) == 0 {
		return 0, 0
	}
	if len(dst) > SecretEntriesMax {
		dst = dst[:SecretEntriesMax]
	}
	buf := make([]byte, len(dst)*SecretEntryBytes)
	r := svc2(SlotSecretGet, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if r < 0 {
		return 0, r
	}
	n := int(r) / SecretEntryBytes
	if n > len(dst) {
		n = len(dst)
	}
	for i := 0; i < n; i++ {
		off := i * SecretEntryBytes
		rec := SecretRecord{}
		rec.UID = le32(buf[off:])
		rec.KeyLen = le32(buf[off+4:])
		rec.ValLen = le32(buf[off+8:])
		copy(rec.Key[:], buf[off+12:off+12+SecretKeyMax])
		copy(rec.Val[:], buf[off+12+SecretKeyMax:off+12+SecretKeyMax+SecretValMax])
		dst[i] = rec
	}
	return n, r
}

// ErrnoName renders a syscall result as the kernel's own error name (the
// spelling the gates assert: "EACCES", "ENOENT"), or "" when r is not an
// error. Guest code should print this rather than a generic "not found": an
// ownership denial and an absent file are different facts, and M50's whole
// point is that the shell reports which one it hit.
func ErrnoName(r int64) string {
	if r >= 0 {
		return ""
	}
	return errno(-r).Error()
}

func le32(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}

// cstrN takes the first n bytes of a fixed field as a string (n is the
// recorded length, already bounded by the kernel).
func cstrN(b []byte, n int) string {
	if n < 0 {
		return ""
	}
	if n > len(b) {
		n = len(b)
	}
	return string(b[:n])
}
