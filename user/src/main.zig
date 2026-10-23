//! census (M188e, #3190): USER.BIN — gate-referenced: the canonical exec fixture — 13 specs incl. live-exec, live-args, live-fuzz.
//! VirelaiOS user program loaded from the ESP (milestone-three card 6,
//! claim 6783; extended by card 7, claim 0635 — blocking syscalls; card
//! 3e, claim 4636 — exec args).
//!
//! Built as a freestanding AArch64 flat image (USER.BIN, DSK1 format via
//! tools/elf2bin.py — the same tooling as KERNEL.BIN), embedded on the ESP
//! by the image builder, read through the claim-6420 FAT path by the
//! kernel's `exec` monitor command, and entered at EL0 under a fresh user
//! root that maps this page at `userspace.text_va`.
//!
//! The payload is deliberately identical in shape to the claim-8215 static
//! payload (naked asm, fixed register ABI only — no Zig-generated memory
//! references or calls): it proves the loaded image actually executes at
//! EL0 by (1) writing marker lines through sys_write (fd 1, slot 1), which
//! land directly in the serial log, (2) round-tripping two sequenced
//! sys_ping calls (slot 0) — the second valid call proves the first SVC
//! returned to EL0 — (3) cooperatively yielding once (sys_yield, slot 2),
//! (4) sleeping for 2 scheduler ticks (sys_sleep, slot 4) and asserting the
//! 0 return — the claim-0635 blocking proof: the payload is parked
//! (state=blocked), the tick's timer-driven wakeup resumes it from the same
//! SVC frame, and execution continues — and (5) exiting with a distinct
//! status (0x2b = 43) through the non-returning sys_exit (slot 3), closing
//! the claim-6729 lifecycle. The terminal branch is only a fail-safe park
//! if a ping round-trip or the sleep return comes back wrong.
//!
//! Card 3e (claim 4636): the kernel extends the ENTRY contract (not a
//! syscall) — `_start` receives argc in x0 and the argv block VA in x1.
//! When argc > 0 the payload prints one `user: arg=<n>` line per argument
//! (the block is 8 slots of 256 bytes, NUL-terminated, inside this
//! program's READ-ONLY text page) BEFORE the existing markers. A no-args
//! exec (argc=0) prints exactly the markers earlier cards assert, so every
//! existing live gate stays byte-identical.

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\mov x10, x0 // argc (card 3e: entry contract — x0 argc, x1 argv VA; both 0 for no args)
        \\mov x11, x1 // argv block VA
        \\cbz x10, 9f
        \\mov x9, xzr
        \\10:
        \\cmp x9, x10
        \\b.hs 9f
        \\lsl x12, x9, #8 // slot = argv_va + i*256
        \\add x12, x11, x12
        \\// Build "user: arg=<n>\n" in a 64-byte stack scratch and emit it
        \\// in ONE sys_write: three separate writes (prefix, arg, newline)
        \\// let a timer preemption split a logical line, which made the
        \\// live-args gate assert-fail on interleaved output (issue #1042).
        \\sub sp, sp, #64
        \\adr x15, 11f
        \\ldr x16, [x15] // "user: ar"
        \\str x16, [sp]
        \\ldrh w16, [x15, #8] // "g="
        \\strh w16, [sp, #8]
        \\add x15, sp, #10 // arg destination (after the 10-byte prefix)
        \\mov x13, xzr // len = strlen(slot); the 64-byte scratch holds 31 chars
        \\12:
        \\ldrb w14, [x12, x13]
        \\cbz w14, 13f
        \\strb w14, [x15, x13]
        \\add x13, x13, #1
        \\cmp x13, #31
        \\b.lo 12b
        \\13:
        \\mov w14, #10 // terminating newline
        \\strb w14, [x15, x13]
        \\add x2, x13, #11 // 10 prefix + arg + 1 newline
        \\mov x0, #1
        \\mov x1, sp
        \\mov x8, #1
        \\svc #0
        \\add sp, sp, #64
        \\add x9, x9, #1
        \\b 10b
        \\9:
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #25
        \\mov x8, #1
        \\svc #0
        \\// Two sequenced pings: x0 = 1 then 2; each SVC must return the
        \\// same value (the claim-8215 round-trip proof from a LOADED
        \\// image). Any mismatch parks in the fail-safe branch.
        \\mov x9, xzr
        \\2:
        \\add x9, x9, #1
        \\mov x0, x9
        \\mov x8, #0
        \\svc #0
        \\cmp x0, x9
        \\b.ne 3f
        \\cmp x9, #2
        \\b.lo 2b
        \\mov x0, #1
        \\adr x1, 4f
        \\mov x2, #14
        \\mov x8, #1
        \\svc #0
        \\// Claim 0635: one cooperative yield before sleeping — the caller
        \\// is staged and resumed by the ring like any other quantum.
        \\mov x8, #2
        \\svc #0
        \\mov x0, #1
        \\adr x1, 5f
        \\mov x2, #23
        \\mov x8, #1
        \\svc #0
        \\// Sleep 2 scheduler ticks (slot 4): the task blocks, other tasks
        \\// run, and the tick wakes it. The return MUST be 0 — a wrong
        \\// value parks in the fail-safe branch.
        \\mov x0, #2
        \\mov x8, #4
        \\svc #0
        \\cmp x0, #0
        \\b.ne 3f
        \\mov x0, #1
        \\adr x1, 6f
        \\mov x2, #12
        \\mov x8, #1
        \\svc #0
        \\mov x0, #0x2b
        \\mov x8, #3
        \\svc #0
        \\3:
        \\b 3b
        \\1:
        \\.ascii "user: hello from the ESP"
        \\.byte 10
        \\4:
        \\.ascii "user: exec ok"
        \\.byte 10
        \\5:
        \\.ascii "user: sleeping 2 ticks"
        \\.byte 10
        \\6:
        \\.ascii "user: awake"
        \\.byte 10
        \\11:
        \\.ascii "user: arg="
        \\14:
        \\.byte 10
    );
}

// A host-side test cannot execute the naked payload, but compiling this
// module on the host (aarch64 test runner) still type-checks the export.
test "user program module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}
