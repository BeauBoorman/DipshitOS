//go:build virelai

package vsys

// Volume free space over sys_file_free (slot 37, ADR 0007).
//
// free(volume) returns the free byte count on a mount-table row
// (kernel/src/mount_table.zig): 0 = host share (STATFS avail), 1 = the
// /disk VLFS volume's free blocks, 2-6 = usb rows. Returns the byte
// count, or a negative errno (EINVAL no free-space source — old host or
// the usb rows, ENOENT /disk unmounted, EIO transport).
const SlotFileFree uintptr = 37

// VolumeFree returns the free byte count on the given volume (slot 37), or
// the raw negative kernel error.
func VolumeFree(volume uint64) int64 {
	return syscallFn(SlotFileFree, uintptr(volume), 0, 0, 0)
}
