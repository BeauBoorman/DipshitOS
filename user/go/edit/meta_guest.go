//go:build virelai

package main

import (
	"encoding/binary"
	"strings"
	"unsafe"
)

// rawsvc6 is the raw six-argument SVC — the same idiom vi's own gateway
// uses (user/go/vi/vi_arm64.s); a copy lives here because vi's is
// unexported and vi is outside this card's Touches (the gobuild
// spawn_guest.go precedent).
func rawsvc6(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64

// Slot-79 fs_metadata op 0 (kernel/src/fs_metadata.zig stat_op) writes the
// 96-byte metadata.Wire. The ABI's shape is root + relative: the root must
// resolve to a DIRECTORY (resolve refuses a file root with NotDirectory —
// passing the target as root reads rc<0, observed in-guest), so the call
// roots at /host and walks the share-relative rest. mtime's WireTime sits
// at wire offsets 48/56 (seconds, then nanoseconds).
const (
	slotFsMetadata   = 79
	metaStatOp       = 0
	metaWireBytes    = 96
	metaMtimeSecOff  = 48
	metaMtimeNsecOff = 56
	metaRoot         = "/host"
)

// fileMtime is a share path's nanosecond mtime — the stamp the stale-
// diagnostics rule compares against the buffer's file. ok=false means the
// kernel could not report one (a never-saved file, a refused path); the
// caller skips the check rather than inventing a stamp.
func fileMtime(path string) (int64, bool) {
	rel := strings.TrimPrefix(path, metaRoot+"/")
	if rel == path {
		return 0, false // the metadata ABI is /host-rooted only
	}
	var wire [metaWireBytes]byte
	rc := rawsvc6(slotFsMetadata, metaStatOp,
		uintptr(unsafe.Pointer(unsafe.StringData(metaRoot))), uintptr(len(metaRoot)),
		uintptr(unsafe.Pointer(unsafe.StringData(rel))), uintptr(len(rel)),
		uintptr(unsafe.Pointer(&wire[0])))
	if rc < 0 {
		return 0, false
	}
	sec := int64(binary.LittleEndian.Uint64(wire[metaMtimeSecOff:]))
	nsec := int64(binary.LittleEndian.Uint32(wire[metaMtimeNsecOff:]))
	return sec*1e9 + nsec, true
}
