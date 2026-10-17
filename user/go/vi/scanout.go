// The scanout read seam (slot 88, ADR 0007 M109b amendment, #2398): a
// bounded READ copy of the virtio-gpu framebuffer — what the display DMAs —
// for any EL0 process. The writable full-frame bind stays registered-WM
// only (MmapScanout); this is the asymmetric read side ui.screenshot rides.
package vi

import "unsafe"

// ScanoutReadMax is the slot's per-call byte bound (scanout_read_max):
// 64 KiB of pixel data. A bigger rect reads in more calls. The framebuffer
// geometry itself is the ScanoutWidth/ScanoutHeight/ScanoutBPP const block
// in wmseat.go — compile-time on both sides of the ABI.
const ScanoutReadMax = 65536

// ScanoutRead copies the (x, y, w, h) rectangle of the framebuffer out
// through uaccess into buf, which must hold exactly w*h*4 bytes. Returns
// the bytes copied, or a negative errno: ENXIO when the framebuffer is not
// armed, EINVAL for a zero/off-frame rect, a wrong length, or a rect over
// ScanoutReadMax, EFAULT for a bad buf (per-row: earlier rows may already
// have landed). Host builds return -ENOSYS.
func ScanoutRead(x, y, w, h uint32, buf []byte) int64 {
	return syscall6(SlotScanoutRead,
		uintptr(x), uintptr(y), uintptr(w), uintptr(h),
		uintptr(unsafe.Pointer(unsafe.SliceData(buf))), uintptr(len(buf)))
}
