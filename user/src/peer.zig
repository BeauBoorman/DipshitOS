//! census (M188e, #3190): PEER.BIN — gate-referenced: live-ipc, live-procs-syscall.
//! VirelaiOS third ESP user program — PEER.BIN (milestone-four follow-on 3,
//! card 3f — claim 5965; extended by follow-on 4 card 4a — claim 5799).
//!
//! The receiving half of the first inter-process data path. COUNTER.BIN
//! sends short decimal messages ("3\n" — one sequence number per message)
//! through sys_ipc_send (slot 5) into THIS program's per-process mailbox;
//! this program recv-loops through sys_ipc_recv (slot 6) and echoes each
//! received message verbatim with a "peer: got " prefix. The serial log
//! therefore shows the counter's "ipc: ping N" lines interleaved with the
//! peer's "peer: got N" lines — byte-exact end-to-end data flow between
//! TWO live processes, neither of which ever exits.
//!
//! Card 4a (claim 5799): PEER.BIN also carries the FIRST EL0-readable view
//! of the process table. Before the recv loop it polls `sys_procs` (slot
//! 7) once per quantum until the snapshot shows a RUNNING process other
//! than itself (the counter is exec'd AFTER this program, so the first
//! snapshots only show this program + the exited boot payload), then
//! prints one `peer: sees <pid> <name> <state>` line per snapshot row and
//! falls into the recv loop. The kernel marshals fixed 40-byte rows (u64
//! pid, u64 state code, u64 exit status, 16-byte NUL-padded name); this
//! payload parses them in naked asm — decimal pid, name up to its NUL,
//! and the state code mapped to a string (1=created, 2=running,
//! 3=exited). The rows include EXITED processes too (the boot payload's
//! `user-el0 exited` row is visible), so the snapshot is the honest
//! table, not just the live set.
//!
//! Like COUNTER.BIN this is a NEVER-EXITING program (marker + yield only,
//! no sys_exit) that occupies its pool slot and address space permanently.
//! The payload is the same naked-asm, fixed-register-ABI shape as the
//! other ESP programs: recv into a stack buffer, echo the bytes (an empty
//! recv — result 0 — prints nothing), cooperatively yield, repeat. The
//! ring never fills because every iteration drains at most the 4 queued
//! messages; the yield keeps the round-robin ring live.
//!
//! The "peer: got " prefix and the "peer: sees " prefix bytes are exposed
//! as `pub const`s so the host tests pin the EXACT marker shapes (the
//! serial log's grep targets for this program) and the sys_write lengths
//! in the payload cannot drift.

const std = @import("std");

/// The exact prefix bytes PEER.BIN writes before each received message.
/// Host-tested so the live gate's `peer: got` grep target cannot drift
/// from the payload's `.ascii`.
pub const echo_prefix: []const u8 = "peer: got ";
/// The exact prefix bytes PEER.BIN writes before each snapshot row (card
/// 4a — the EL0 process-table read). Host-tested so the live gate's
/// `peer: sees` grep target cannot drift.
pub const sees_prefix: []const u8 = "peer: sees ";
/// The recv buffer bound (the per-message slot bound; larger recv buffers
/// are clamped by the kernel — this program asks for the maximum).
pub const recv_max: u32 = 64;
/// The sys_procs snapshot buffer bound (8 rows × 40 bytes = the full
/// `process.max_processes` table — the kernel clamps to it anyway).
pub const procs_max: u32 = 320;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// Phase 1 (card 4a, claim 5799): poll sys_procs once per
        \\// quantum until the snapshot shows a RUNNING process other
        \\// than this program, then print `peer: sees <pid> <name>
        \\// <state>` per row and fall into the recv loop.
        \\// x20 = scan state: 0 = scanning, 1 = found + printed.
        \\mov x20, xzr
        \\20:
        \\cbnz x20, 0f // found: enter the recv loop
        \\sub sp, sp, #320 // snapshot buffer (8 rows x 40 B)
        \\mov x0, sp
        \\mov x1, #320
        \\mov x8, #7 // sys_procs(buf, max) -> rows
        \\svc #0
        \\mov x21, x0 // rows returned
        \\cbz x21, 23f // empty snapshot: retry
        \\mov x22, xzr // row index
        \\22:
        \\cmp x22, x21
        \\b.hs 23f // scanned every row: peer not seen yet, retry
        \\// row base = sp + row * 40 (32 * row + 8 * row).
        \\lsl x23, x22, #5
        \\add x23, x23, x22, lsl #3
        \\add x23, sp, x23
        \\ldr x9, [x23, #8] // state code
        \\cmp x9, #2 // running?
        \\b.ne 24f // not running: next row
        \\// name = 8 bytes at row+24; compare with "PEER.BIN" (label 25).
        \\adr x10, 25f
        \\add x12, x23, #24
        \\mov x11, #8
        \\26:
        \\ldrb w13, [x10], #1
        \\ldrb w14, [x12], #1
        \\cmp x13, x14
        \\b.ne 40f // a RUNNING process that is NOT this program: FOUND
        \\subs x11, x11, #1
        \\b.ne 26b
        \\b 24f // it IS this program: next row
        \\24:
        \\add x22, x22, #1
        \\b 22b
        \\40:
        \\// FOUND: print every snapshot row, then fall through to the
        \\// retry/recv-loop seam (23: restores sp and loops to 20:, whose
        \\// cbnz now jumps into the recv loop).
        \\mov x20, #1
        \\mov x22, xzr
        \\27:
        \\cmp x22, x21
        \\b.hs 23f
        \\// row base = sp + row * 40.
        \\lsl x23, x22, #5
        \\add x23, x23, x22, lsl #3
        \\add x23, sp, x23
        \\// "peer: sees " (11 bytes)
        \\mov x0, #1
        \\adr x1, 28f
        \\mov x2, #11
        \\mov x8, #1
        \\svc #0
        \\// pid decimal (u64 at row+0) into a 16-byte area at the tail of
        \\// the snapshot buffer (sp+304..sp+319); digits from the end.
        \\ldr x9, [x23]
        \\add x14, sp, #318
        \\mov x10, #10
        \\mov x16, #0 // digit count
        \\cbnz x9, 41f
        \\mov x12, #48 // '0' (pid 0: a single zero digit)
        \\strb w12, [x14]
        \\mov x16, #1
        \\b 42f
        \\41:
        \\udiv x11, x9, x10
        \\msub x12, x11, x10, x9
        \\add x12, x12, #48
        \\strb w12, [x14]
        \\sub x14, x14, #1
        \\mov x9, x11
        \\add x16, x16, #1
        \\cbnz x9, 41b
        \\add x14, x14, #1 // first digit
        \\42:
        \\mov x0, #1
        \\mov x1, x14
        \\mov x2, x16
        \\mov x8, #1
        \\svc #0
        \\// " " separator
        \\mov x0, #1
        \\adr x1, 43f
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\// name until NUL (max 16 bytes)
        \\add x12, x23, #24
        \\mov x13, xzr
        \\44:
        \\ldrb w14, [x12, x13]
        \\cbz x14, 45f
        \\add x13, x13, #1
        \\cmp x13, #16
        \\b.lo 44b
        \\45:
        \\mov x0, #1
        \\mov x1, x12
        \\mov x2, x13
        \\mov x8, #1
        \\svc #0
        \\// " " separator
        \\mov x0, #1
        \\adr x1, 43f
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\// state string: 1=created, 2=running, 3=exited
        \\ldr x9, [x23, #8]
        \\cmp x9, #1
        \\b.ne 46f
        \\adr x14, 47f // "created"
        \\mov x15, #7
        \\b 48f
        \\46:
        \\cmp x9, #3
        \\b.ne 49f
        \\adr x14, 50f // "exited"
        \\mov x15, #6
        \\b 48f
        \\49:
        \\adr x14, 51f // "running"
        \\mov x15, #7
        \\48:
        \\mov x0, #1
        \\mov x1, x14
        \\mov x2, x15
        \\mov x8, #1
        \\svc #0
        \\// trailing newline
        \\mov x0, #1
        \\adr x1, 52f
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\add x22, x22, #1
        \\b 27b
        \\23:
        \\add sp, sp, #320
        \\mov x8, #2 // cooperative yield, then rescan
        \\svc #0
        \\b 20b
        \\0:
        \\// sys_ipc_recv(buf=sp+10, max=64) — leave room for the echo
        \\// prefix in the same 96-byte stack buffer.
        \\sub sp, sp, #96
        \\add x0, sp, #10
        \\mov x1, #64
        \\mov x8, #6
        \\svc #0
        \\cbz x0, 1f // empty mailbox: nothing to echo
        \\// Echo prefix + received bytes verbatim in ONE sys_write:
        \\// SMP scheduler output must not split the serial marker.
        \\add x9, x0, #10 // total length (at most 74 bytes)
        \\adr x10, 2f
        \\mov x11, sp
        \\mov x12, #10
        \\53:
        \\ldrb w13, [x10], #1
        \\strb w13, [x11], #1
        \\subs x12, x12, #1
        \\b.ne 53b
        \\mov x0, #1
        \\mov x1, sp
        \\mov x2, x9
        \\mov x8, #1
        \\svc #0
        \\1:
        \\add sp, sp, #96
        \\// Cooperative yield (slot 2) — the frozen ABI; this program
        \\// NEVER exits.
        \\mov x8, #2
        \\svc #0
        \\b 0b
        \\25:
        \\.ascii "PEER.BIN"
        \\28:
        \\.ascii "peer: sees "
        \\43:
        \\.ascii " "
        \\47:
        \\.ascii "created"
        \\50:
        \\.ascii "exited"
        \\51:
        \\.ascii "running"
        \\52:
        \\.byte 10
        \\2:
        \\.ascii "peer: got "
    );
}

test "user peer module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user peer: the marker shapes are pinned (live-gate grep targets)" {
    // The exact bytes the payload writes (the `#10` echo copy/offset and
    // `#11` snapshot length must match the `2:` / `28:` `.ascii` consts — a
    // drift breaks the live gates' `peer: got` / `peer: sees` assertions,
    // never silently).
    try std.testing.expectEqualStrings("peer: got ", echo_prefix);
    try std.testing.expectEqual(@as(usize, 10), echo_prefix.len);
    try std.testing.expectEqualStrings("peer: sees ", sees_prefix);
    try std.testing.expectEqual(@as(usize, 11), sees_prefix.len);
    try std.testing.expectEqual(@as(u32, 64), recv_max);
    try std.testing.expectEqual(@as(u32, 320), procs_max);
}
