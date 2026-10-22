package vsys

import (
	"runtime"
	"sync/atomic"
)

// SlotWrite is sys_write(fd, buf, len) (ADR 0007). Virelai has ONE console,
// so both runtime descriptors alias to it and fd is accepted then ignored.
const (
	// SlotWrite is sys_write(fd, buf, len) (ADR 0007). Virelai has ONE
	// console, so both runtime descriptors alias to it.
	SlotWrite uintptr = 1
	// SlotExit is sys_exit(status) — process exit, noreturn.
	SlotExit uintptr = 3
	// SlotSleep is sys_sleep(ticks) — a bounded scheduler sleep.
	SlotSleep uintptr = 4
	// SlotSleepNs is sys_sleep_ns(ns) — slot 94, the deadline-overlay arm
	// of the same blocking sleep (card #3036).
	SlotSleepNs uintptr = 94
)

// virConsoleStaging is the console staging buffer. sys_write validates the
// SOURCE pointer against the caller's registered uaccess regions, and a Go
// stack lives in the sbrk heap (registered as a whole-mapping region only for
// the image's own RW data), so every chunk is staged here first — the same
// reason the runtime's write1 stages into virWriteStaging.
var virConsoleStaging [256]byte
var virConsoleHeld uint32

// Print writes s to the process console. It is the fixture-facing output
// path (os.Stdout's stand-in until the std os port lands). The kernel caps a
// write at 256 bytes; anything longer is truncated here rather than looped,
// because every extra byte of code costs image space the kernel's fixed text
// gap does not have (see build-go.sh's LOAD-layout guard).
func Print(s string) {
	if len(s) > 256 {
		s = s[:256]
	}
	// Hold the global uaccess buffer until sys_write has consumed it.
	// Cooperative scheduling must let its owner run even with only one P.
	for !atomic.CompareAndSwapUint32(&virConsoleHeld, 0, 1) {
		runtime.Gosched()
	}
	copy(virConsoleStaging[:], s)
	r := syscallFn(SlotWrite, 1, strPtr(virConsoleStaging[:len(s)]), uintptr(len(s)), 0)
	_ = r
	atomic.StoreUint32(&virConsoleHeld, 0)
}

// Println writes s followed by a newline.
func Println(s string) { Print(s + "\n") }

// Exit terminates the process (slot 3). It does not return.
func Exit(status int) { syscallFn(SlotExit, uintptr(status), 0, 0, 0) }

// Sleep yields the CPU for ticks scheduler ticks (slot 4).
func Sleep(ticks uint64) { syscallFn(SlotSleep, uintptr(ticks), 0, 0, 0) }

// SleepNs blocks for at least ns nanoseconds (slot 94). A pre-card-#3036
// kernel answers ENOSYS and the call falls back to slot 4, rounding up.
func SleepNs(ns uint64) {
	if syscallFn(SlotSleepNs, uintptr(ns), 0, 0, 0) == -ErrENOSYS {
		Sleep((ns + 999_999_999) / 1_000_000_000)
	}
}

// Itoa64 formats v in base 10. Local on purpose: importing strconv would drag
// stdlib text into an image the kernel's fixed text gap must fit.
func Itoa64(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	// Format from the UNSIGNED magnitude. `v = -v` overflows for
	// math.MinInt64 (two's complement has no positive counterpart), which
	// used to drain the digit loop and print a bare "-" — a wrong byte
	// count or errno in every fixture that prints one.
	u := uint64(v)
	if neg {
		u = uint64(-(v + 1)) + 1
	}
	var buf [20]byte
	i := len(buf)
	for u > 0 {
		i--
		buf[i] = byte('0' + u%10)
		u /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
