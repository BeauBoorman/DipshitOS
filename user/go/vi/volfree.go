// M160b (issue #2990): per-volume free space at EL0. Slot 37's argument
// is the kernel mount-table ROW index (kernel/src/mount_table.zig) —
// row 0 is the host share (the M160a STATFS avail x block_size), row 1
// the /disk VLFS volume (its bbitmap's free blocks x block_len). The
// usb rows and anything unnamed have no free-space source.
package vi

import "errors"

// The mount-table row indexes slot 37 answers.
const (
	volumeRowHost uint64 = 0
	volumeRowDisk uint64 = 1
)

// ErrNoVolumeRow names a mount name with no slot-37 answer — the usb
// rows and anything the table does not carry. Distinct from the
// kernel's own refusals, which arrive as their errno (an unmounted
// /disk is ENOENT, an old host EINVAL).
var ErrNoVolumeRow = errors.New("volume has no free-space row")

// volumeFree is the slot-37 seam — the svc1 gateway on the guest (vi's
// own syscallHook covers it in host tests).
var volumeFree = func(row uint64) int64 {
	return svc1(SlotFileFree, uintptr(row))
}

// VolumeFree returns the free byte count on the named volume ("host"
// or "disk"), or a named error: ErrNoVolumeRow for a name with no row,
// the kernel's errno otherwise.
func VolumeFree(name string) (uint64, error) {
	var row uint64
	switch name {
	case "host":
		row = volumeRowHost
	case "disk":
		row = volumeRowDisk
	default:
		return 0, ErrNoVolumeRow
	}
	rc := volumeFree(row)
	if rc < 0 {
		return 0, MountErr(rc)
	}
	return uint64(rc), nil
}
