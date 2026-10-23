//! census (M188e, #3190): BLKD.BIN — gate-referenced: live-usb-block.
//! VirelaiOS M43 U3 / M70f F1 EL0 consumer — BLKD.BIN (issue #1034, claim
//! #1048; M70f F1 added 2026-09-18, issue #1458).
//!
//! Two phases over the SAME file-table seam, in one boot:
//!
//! Phase 1 (M43 U3) — the RAW block device:
//!   1. sys_file_open("usb", 3, MODE_READ) -> fd   (slot 23)
//!   2. sys_file_read(fd, buf, 1024)       -> n    (slot 24; LBA 0 + LBA 1)
//!   3. prints `blkd: pattern=` + the first 14 bytes of the host-staged
//!      LBA-1 marker, then `blkd: done`
//!   4. sys_file_close(fd) (slot 26)
//!
//! Phase 2 (M70f F1) — a READ-ONLY file inside MBR partition 1's FAT32 volume:
//!   5. sys_file_open("usb1/PROBE.TXT", 3, MODE_READ)  (slot 23)
//!   6. sys_file_read(fd, buf, 256) -> 120 exactly, then a second read -> 0
//!      (EOF). A short read or a non-empty second read prints its own line and
//!      exits 2 — the app never reports success it did not observe.
//!   7. prints `blkd: fat=` + the first 14 content bytes + `blkd: fat-eof=1`
//!   8. sys_file_close(fd) (slot 26); sys_exit(0) (slot 3)
//!
//! The gate's MSD image stages the ASCII marker "M43USBMSDPROBE" at LBA 1 and
//! a 120-byte `PROBE.TXT` (content `usb-bulk-probe\n` x8) in the FAT32 volume,
//! so the transcript asserts those bytes BYTE-EXACT from EL0 — once through the
//! raw device and once through the volume handle.

const std = @import("std");

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// ---------------- phase 1: the raw `.usb` block device ----------------
        \\// 1. open("usb", 3, MODE_READ=1)
        \\adr x0, 1f
        \\mov x1, #3
        \\mov x2, #1
        \\mov x8, #23
        \\svc #0
        \\cmp x0, #0
        \\b.ge 10f
        \\// open failed: say so and exit 1
        \\mov x0, #1
        \\adr x1, 5f
        \\mov x2, #18
        \\mov x8, #1
        \\svc #0
        \\mov x0, #1
        \\mov x8, #3
        \\svc #0
        \\10:
        \\mov x19, x0 // fd
        \\// 2. read(fd, sp-1024, 1024) — LBA 0 (MBR) + LBA 1 (marker)
        \\sub sp, sp, #1024
        \\mov x0, x19
        \\mov x1, sp
        \\mov x2, #1024
        \\mov x8, #24
        \\svc #0
        \\// 3a. write(1, "blkd: pattern=", 14)
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #14
        \\mov x8, #1
        \\svc #0
        \\// 3b. write(1, sp+512, 14) — the LBA-1 marker bytes. Printed even
        \\// on a short read: the gate must see the real bytes (or junk), and
        \\// fail loudly; the app never invents content.
        \\mov x0, #1
        \\add x1, sp, #512
        \\mov x2, #14
        \\mov x8, #1
        \\svc #0
        \\// 3c. write(1, "\nblkd: done\n", 12)
        \\mov x0, #1
        \\adr x1, 3f
        \\mov x2, #12
        \\mov x8, #1
        \\svc #0
        \\// 4. close(fd)
        \\mov x0, x19
        \\mov x8, #26
        \\svc #0
        \\// ---------------- phase 2: the FAT32 volume handle (M70f F1) --------
        \\// 5. open("usb1/PROBE.TXT", 14, MODE_READ=1)
        \\adr x0, 20f
        \\mov x1, #14
        \\mov x2, #1
        \\mov x8, #23
        \\svc #0
        \\cmp x0, #0
        \\b.ge 30f
        \\mov x0, #1
        \\adr x1, 21f
        \\mov x2, #22
        \\mov x8, #1
        \\svc #0
        \\mov x0, #1
        \\mov x8, #3
        \\svc #0
        \\30:
        \\mov x20, x0 // volume fd
        \\// 6a. read(fd, sp, 256) — the staged file is exactly 120 bytes.
        \\mov x0, x20
        \\mov x1, sp
        \\mov x2, #256
        \\mov x8, #24
        \\svc #0
        \\mov x21, x0
        \\cmp x21, #120
        \\b.eq 31f
        \\mov x0, #1
        \\adr x1, 22f
        \\mov x2, #21
        \\mov x8, #1
        \\svc #0
        \\mov x0, #2
        \\mov x8, #3
        \\svc #0
        \\31:
        \\// 6b. a second read must be EOF (0): the chain walk ends where the
        \\// file's size says it does.
        \\mov x0, x20
        \\mov x1, sp
        \\mov x2, #256
        \\mov x8, #24
        \\svc #0
        \\cmp x0, #0
        \\b.eq 32f
        \\mov x0, #1
        \\adr x1, 23f
        \\mov x2, #18
        \\mov x8, #1
        \\svc #0
        \\mov x0, #2
        \\mov x8, #3
        \\svc #0
        \\32:
        \\// 7a. write(1, "blkd: fat=", 10)
        \\mov x0, #1
        \\adr x1, 24f
        \\mov x2, #10
        \\mov x8, #1
        \\svc #0
        \\// 7b. write(1, sp, 14) — the first content bytes, verbatim.
        \\mov x0, #1
        \\mov x1, sp
        \\mov x2, #14
        \\mov x8, #1
        \\svc #0
        \\// 7c. write(1, "\nblkd: fat-eof=1\n", 17)
        \\mov x0, #1
        \\adr x1, 25f
        \\mov x2, #17
        \\mov x8, #1
        \\svc #0
        \\// 8. close(fd) and exit(0)
        \\mov x0, x20
        \\mov x8, #26
        \\svc #0
        \\add sp, sp, #1024
        \\mov x0, #0
        \\mov x8, #3
        \\svc #0
        \\1:
        \\.ascii "usb"
        \\2:
        \\.ascii "blkd: pattern="
        \\3:
        \\.ascii "\nblkd: done\n"
        \\5:
        \\.ascii "blkd: open failed\n"
        \\20:
        \\.ascii "usb1/PROBE.TXT"
        \\21:
        \\.ascii "blkd: vol open failed\n"
        \\22:
        \\.ascii "blkd: fat short read\n"
        \\23:
        \\.ascii "blkd: fat not eof\n"
        \\24:
        \\.ascii "blkd: fat="
        \\25:
        \\.ascii "\nblkd: fat-eof=1\n"
    );
}
