package vsys

// Milestone 14 (claim 0169): the ONE shared kernel clipboard. The slot
// numbers are ADR 0007's; the single source is kernel/src/syscall.zig
// (sys_clipboard_set = 38, sys_clipboard_get = 39).
//
// These live here rather than in the app-facing SDK because vsys IS the raw
// syscall layer (console.go's Write/Exit/Sleep sit next to them) and because
// user/go/vi was held by an active claim when the M66c follow-on (#1485) needed
// a Go client for the two slots. They return a raw kernel result next to the
// value, like the file calls do, rather than an interface-typed error — see the
// image-budget note below, which is why that is not a style preference here.
//
// Two size decisions in this file are load-bearing, not tidiness:
//
//   - The calls marshal through virConsoleStaging, the 256-byte buffer
//     console.go already keeps. The kernel packs argv+envp (256 + 2048 bytes,
//     kernel/src/exec.zig) into the data segment's tail while the Go runtime's
//     sbrk heap starts at `memRound(firstmoduledata.end)`, and `mmap_collides`
//     extends the data aperture through `argv_end_va`. So when an image's
//     `mem_size mod 4096 > 1792` the packed block straddles that break start and
//     the runtime's FIRST sys_mmap is refused — observed live as `fatal error:
//     runtime: cannot allocate memory` inside mallocinit, i.e. a dead app, not a
//     diagnosable error. 512 bytes of extra BSS moved GOEDIT.ELF from
//     `mem_size mod 4096 = 1520` to 2064 and killed it, so a slot wrapper has no
//     business spending image bytes it does not need. Those two figures are the
//     live observation on the 2026-09-19 tree, hand-measured (memsz mod 4096 per
//     ELF, see #1495 review): illustrative, not gate-pinned.
//   - There is no `error` here for the same reason: an interface value drags
//     the errno strings and their itab into the image's data segment, and every
//     byte there is slack the argv block above needs.
const (
	// SlotClipboardSet is sys_clipboard_set(buf_ptr, len) — copy len bytes
	// through uaccess into the shared kernel buffer. len > ClipboardMax is
	// truncated; len 0 clears the clipboard. Returns the stored length.
	SlotClipboardSet uintptr = 38
	// SlotClipboardGet is sys_clipboard_get(buf_ptr, max) — copy the current
	// contents OUT through uaccess WITHOUT consuming them (a clipboard is a
	// shared, non-destructive read, unlike the mailbox's recv). Returns the
	// copied length; max > ClipboardMax clamps.
	SlotClipboardGet uintptr = 39
	// ClipboardMax is the largest transfer this package makes: the size of the
	// staging buffer it shares with the console. It is NOT the kernel's buffer
	// bound (kernel/src/clipboard.zig holds 512 bytes), and the truncation at
	// this bound is SILENT — a 257..512 byte body sets fine and reads back 256,
	// with no error, because the kernel accepted everything it was handed. So a
	// caller whose body can exceed this must compare the returned count against
	// len(p) (that is why ClipboardSet returns it) and transfer the rest
	// through its own uaccess-valid region via the slot, or accept the loss.
	ClipboardMax = len(virConsoleStaging)
)

// ClipboardSet copies p into the shared kernel clipboard (slot 38). It returns
// the number of bytes the kernel actually stored and the RAW kernel result
// (negative = errno) — the (value, rc) shape the file calls use. p longer than
// ClipboardMax is truncated to it, exactly as the kernel truncates a longer
// body.
func ClipboardSet(p []byte) (int, int64) {
	if len(p) > ClipboardMax {
		p = p[:ClipboardMax]
	}
	copy(virConsoleStaging[:], p)
	r := syscallFn(SlotClipboardSet, strPtr(virConsoleStaging[:len(p)]), uintptr(len(p)), 0, 0)
	if r < 0 {
		return 0, r
	}
	return int(r), r
}

// ClipboardGet copies the current clipboard contents out (slot 39) without
// consuming them, and returns a copy the caller owns plus the raw kernel result.
// An empty clipboard is (nil, 0) — not a failure: "nothing has been copied yet"
// is a state, which is why the kernel returns 0 rather than an errno there.
func ClipboardGet(max int) ([]byte, int64) {
	if max <= 0 || max > ClipboardMax {
		max = ClipboardMax
	}
	r := syscallFn(SlotClipboardGet, strPtr(virConsoleStaging[:max]), uintptr(max), 0, 0)
	if r < 0 {
		return nil, r
	}
	if r == 0 {
		return nil, 0
	}
	out := make([]byte, r)
	copy(out, virConsoleStaging[:r])
	return out, r
}

// ClipboardSetAll is ClipboardSet for a caller that already holds its body
// in uaccess-valid memory (any live Go heap/stack slice is — the scheduler
// registers the runtime's mmap'd regions as EL0 apertures, issue #1163 A1).
// It skips the staging copy, so the kernel's own 512-byte bound — not the
// 256-byte staging pool — is the transfer cap. The seat's host-integration
// lane (ADR 0051, M108b) is the caller this exists for: the lane bound IS
// the kernel bound, and halving it would be a silent fidelity loss.
func ClipboardSetAll(p []byte) (int, int64) {
	if len(p) == 0 {
		// len 0 clears the clipboard; the slot still runs (with a nil
		// pointer it never touches).
		r := syscallFn(SlotClipboardSet, 0, 0, 0, 0)
		if r < 0 {
			return 0, r
		}
		return int(r), r
	}
	r := syscallFn(SlotClipboardSet, strPtr(p), uintptr(len(p)), 0, 0)
	if r < 0 {
		return 0, r
	}
	return int(r), r
}

// ClipboardGetInto is ClipboardGet for the same caller: the kernel copies
// the current contents into buf (truncated to len(buf); the kernel clamps
// to its own 512 too) without consuming them. Returns (copied, raw result);
// an empty clipboard is (0, 0).
func ClipboardGetInto(buf []byte) (int, int64) {
	if len(buf) == 0 {
		return 0, 0
	}
	r := syscallFn(SlotClipboardGet, strPtr(buf), uintptr(len(buf)), 0, 0)
	if r < 0 {
		return 0, r
	}
	return int(r), r
}
