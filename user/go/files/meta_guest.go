//go:build virelai

package main

import (
	"encoding/binary"
	"strings"
	"unsafe"
)

// rawsvc6 is the raw six-argument SVC, bound to vi's unexported gateway by
// linkname — the same seam GOEDIT rides (edit/meta_guest.go, M112a #2413):
// an asm trampoline is the one thing the in-guest toolchain cannot rebuild
// (no cmd/asm on GOOS=virelai), and GOFILES is a fleet member that must
// build in-guest. virelai/vi.syscall6 comes out of the staged GPKG archive
// — identical instruction sequence, no second gateway.
//
//go:linkname rawsvc6 virelai/vi.syscall6
func rawsvc6(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64

// Slot-79 fs_metadata op 0 (kernel/src/fs_metadata.zig stat_op) writes the
// 96-byte metadata.Wire. The ABI's shape is root + relative: the root must
// resolve to a DIRECTORY (resolve refuses a file root with NotDirectory),
// so the call roots at /host and walks the share-relative rest. mtime's
// WireTime sits at wire offsets 48/56 (seconds, then nanoseconds) — the
// fields M134a (#2759) fills for /host on either file channel — and
// ctime's at 64/72, the change stamp M160a's v3 STAT carries.
const (
	slotFsMetadata   = 79
	metaStatOp       = 0
	metaWireBytes    = 96
	metaMtimeSecOff  = 48
	metaMtimeNsecOff = 56
	metaCtimeSecOff  = 64
	metaCtimeNsecOff = 72
	metaOwnerOff     = 84 // wire.host_uid — /disk carries owner_uid (M188b)
	metaRoot         = "/host"
)

// fileTimes is a share path's nanosecond mtime and ctime — the stamps the
// QuickLook and properties cards show, read in ONE stat call because the
// same wire carries both. Each flag reports its own stamp: ok=false means
// the kernel could not answer at all (a non-/host path the metadata ABI
// does not root, or a refused path), and a stamp whose fields read the
// wire's absent zero reports false on its own — the card prints its named
// reason rather than inventing a stamp.
func fileTimes(path string) (mt, ct int64, mtOK, ctOK bool) {
	rel := strings.TrimPrefix(path, metaRoot+"/")
	if rel == path {
		return 0, 0, false, false // the metadata ABI is /host-rooted only
	}
	var wire [metaWireBytes]byte
	rc := rawsvc6(slotFsMetadata, metaStatOp,
		uintptr(unsafe.Pointer(unsafe.StringData(metaRoot))), uintptr(len(metaRoot)),
		uintptr(unsafe.Pointer(unsafe.StringData(rel))), uintptr(len(rel)),
		uintptr(unsafe.Pointer(&wire[0])))
	if rc < 0 {
		return 0, 0, false, false
	}
	msec := int64(binary.LittleEndian.Uint64(wire[metaMtimeSecOff:]))
	mnsec := int64(binary.LittleEndian.Uint32(wire[metaMtimeNsecOff:]))
	csec := int64(binary.LittleEndian.Uint64(wire[metaCtimeSecOff:]))
	cnsec := int64(binary.LittleEndian.Uint32(wire[metaCtimeNsecOff:]))
	// M134a's "absent reads zero" rule applies to each stamp on its own.
	return msec*1e9 + mnsec, csec*1e9 + cnsec,
		msec != 0 || mnsec != 0, csec != 0 || cnsec != 0
}

// fileOwner is the stat wire's owner word (M188b #3187): on /host it is
// the share's host uid, on /disk the inode's owner_uid — 0 names the
// unowned, world-accessible case, never a substitute for policy. A path
// outside both roots, or a refused stat, reports ok=false and the card
// prints its named reason rather than inventing an owner.
func fileOwner(path string) (uint32, bool) {
	root, rel := "", ""
	switch {
	case path == "/host" || path == "/disk":
		root = path
	case strings.HasPrefix(path, "/host/"):
		root, rel = "/host", path[len("/host/"):]
	case strings.HasPrefix(path, "/disk/"):
		root, rel = "/disk", path[len("/disk/"):]
	default:
		return 0, false
	}
	var wire [metaWireBytes]byte
	rc := rawsvc6(slotFsMetadata, metaStatOp,
		uintptr(unsafe.Pointer(unsafe.StringData(root))), uintptr(len(root)),
		uintptr(unsafe.Pointer(unsafe.StringData(rel))), uintptr(len(rel)),
		uintptr(unsafe.Pointer(&wire[0])))
	if rc < 0 {
		return 0, false
	}
	return binary.LittleEndian.Uint32(wire[metaOwnerOff:]), true
}
