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
// fields M134a (#2759) fills for /host on either file channel.
const (
	slotFsMetadata   = 79
	metaStatOp       = 0
	metaWireBytes    = 96
	metaMtimeSecOff  = 48
	metaMtimeNsecOff = 56
	metaRoot         = "/host"
)

// fileMtime is a share path's nanosecond mtime — the stamp the QuickLook
// card shows. ok=false means the kernel could not report one (a non-/host
// path the metadata ABI does not root, a refused path, or the channel's
// honest "mtime absent" zero) — the card prints "—" rather than inventing
// a stamp.
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
	if sec == 0 && nsec == 0 {
		return 0, false // M134a's "mtime absent" reads zero — named, not shown
	}
	return sec*1e9 + nsec, true
}
