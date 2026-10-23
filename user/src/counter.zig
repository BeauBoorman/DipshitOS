//! census (M188e, #3190): COUNTER.BIN — gate-referenced: the never-exiting fixture — 19 specs incl. live-long-lived, live-ipc, go-top.
//! VirelaiOS second ESP user program — COUNTER.BIN (milestone-four
//! follow-on 2, claim 4613; extended by follow-on 3 card 3f, claim 5965 —
//! the IPC sender; extended by follow-on 4 card 4b, claim 3179 — the
//! burst cadence; extended by follow-on 4 card 4c, claim 9946 — the
//! exit-status observer).
//!
//! The strong liveness proof the claim-0826 concurrent gate lacks: claim
//! 0826 ran TWO live processes, but both were copies of the SAME program
//! (USER.BIN) and BOTH exited after a few ticks. This program is the
//! permanent occupant: a DISTINCT second image (built from this file by
//! the same build/elf2bin pipeline as USER.BIN, embedded on the ESP as
//! COUNTER.BIN) that NEVER exits — it loops forever writing its own
//! distinct marker through sys_write (fd 1, slot 1) each quantum, spins
//! briefly, and yields (sys_yield, slot 2) — only the frozen ADR-0007
//! slots 1 + 2, no sys_exit. While it runs, the shell, the worker, AND
//! other concurrently-exec'd programs all stay responsive: the process
//! occupies its pool slot and address space permanently, and the live
//! gate reaps + re-execs the short USER.BIN into a freed slot while the
//! counter's markers keep landing.
//!
//! Card 3f (claim 5965) + card 4b (claim 3179): COUNTER.BIN is also the
//! IPC SENDER. When exec'd with a target process id argument
//! (`exec COUNTER.BIN <pid>`, claim-4636 argv), it parses argv[0] as the
//! peer's pid and — every 6th iteration — sends a BURST of 6 messages
//! back-to-back in ONE quantum: each message is formatted as "ping <d>\n"
//! into a 64-byte stack scratch buffer, printed as "ipc: ping <d>"
//! (sys_write, slot 1 — the live gate's send marker), and sent through
//! sys_ipc_send (slot 5, the card-3f ABI amendment) to the peer's
//! per-process mailbox. A negative send result (ENOSPC -5 or an error)
//! prints the distinct "ipc: enospc\n" marker — the live gate asserts
//! ZERO of them. The 5 quiet iterations between bursts let the peer drain
//! one message per round (the peer is not scheduled mid-burst — one
//! quantum is one task — so the 8-slot ring peaks at 6 of 8 and drains to
//! 0 before the next burst: NEVER refused, deterministically). The peer
//! echoes each message back ("peer: got ping <d>", byte-exact). Exec'd
//! WITHOUT an argument (argc == 0 — how the earlier long-lived gates run
//! it), the counter's behavior is byte-identical to claim 4613: marker +
//! spin + yield, no IPC.
//!
//! Card 4c (claim 9946): COUNTER.BIN is also the EXIT-STATUS OBSERVER.
//! When exec'd with a SECOND argument (`exec COUNTER.BIN 0 <waitpid>` —
//! argv[0] stays the optional IPC target, argv[1] the wait target), the
//! counter's FIRST iteration prints the "ipc: waiting pid=<n>" marker and
//! blocks in sys_wait (slot 8) until the target process exits; the wake
//! patches the observed status into the counter's saved frame, and the
//! counter prints "ipc: saw pid=<n> status=<s>" — the EL0-side proof that
//! the kernel propagated the target's exit status to a peer — then falls
//! into the permanent-occupant marker loop (the wait runs exactly ONCE).
//! argv[0] = 0 (a pid the guard treats as no target) keeps the IPC path
//! silent in the wait gate.
//!
//! The payload is the same shape as USER.BIN's (naked asm, fixed register
//! ABI only — no Zig-generated memory references or calls): registers
//! x19-x28 carry the entry contract and loop state across SVC boundaries
//! (the kernel saves/restores the full frame), the scratch buffer lives on
//! the program's OWN writable EL0 stack, and the terminal branch is
//! unreachable by construction (the loop never exits).
//!
//! The marker bytes are also exposed as `pub const`s so the host tests
//! pin the EXACT marker shapes (the serial log's grep targets for this
//! program) and the sys_write/sys_ipc_send lengths used in the payload
//! cannot drift from them.

const std = @import("std");

/// The exact bytes COUNTER.BIN writes every iteration. Host-tested (the
/// marker-shape test below) so the live gate's grep target cannot drift
/// from the payload's `.ascii`.
pub const marker: []const u8 = "counter: alive\n";
/// The "ipc: ping " prefix printed before each sent sequence number.
pub const ipc_prefix: []const u8 = "ipc: ping ";
/// The "ping " prefix of the SENT payload (the peer echoes it back).
pub const ping_prefix: []const u8 = "ping ";
/// The distinct marker printed when a send is refused (ENOSPC -5 or any
/// negative result). The live gate asserts ZERO of these — the burst
/// never overflows the 8-slot ring (card 4b).
pub const enospc_marker: []const u8 = "ipc: enospc\n";
/// The marker printed just BEFORE the sys_wait that blocks the counter on
/// its wait target (card 4c — the live gate forwards its phase-2 snapshot
/// after this line appears, while the counter is still blocked).
pub const wait_prefix: []const u8 = "ipc: waiting pid=";
/// The marker printed after the wake: the observed exit status, the
/// EL0-side proof of the propagation ("ipc: saw pid=<n> status=<s>").
pub const saw_prefix: []const u8 = "ipc: saw pid=";
/// The status separator inside the saw marker.
pub const saw_status_prefix: []const u8 = " status=";
/// The burst length (card 4b): 6 messages back-to-back in ONE quantum.
/// The peer cannot drain mid-burst, so the ring peaks at 6 of the 8
/// slots; 5 quiet iterations drain it to 0 before the next burst.
pub const burst_len: u32 = 6;
/// The bounded spin between the write and the yield (nops). Bounded so a
/// misprogrammed tick cannot starve the round-robin ring; a 16-bit
/// immediate so the payload stays a single `movz` (no movk chains).
pub const spin_limit: u32 = 50_000;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// Claim 4636 entry contract: x0 = argc, x1 = argv block VA.
        \\mov x20, x0
        \\mov x21, x1
        \\mov x22, #1 // send sequence number (starts at 1)
        \\mov x23, #0 // iteration counter (burst cadence)
        \\mov x24, xzr // target pid (default: none)
        \\mov x27, xzr // wait target pid (card 4c: argv[1], default none)
        \\mov x28, xzr // wait-done flag (the wait runs ONCE)
        \\cbz x20, 6f // no args: no target, no wait (claim-4613 behavior)
        \\// Parse argv[0] (the first 256-byte slot) as a decimal pid.
        \\mov x25, x21
        \\mov x26, #32
        \\mov x10, #10
        \\10:
        \\ldrb w9, [x25]
        \\sub x9, x9, #48 // '0' = 0x30
        \\cmp x9, #10
        \\b.hs 11f // non-digit: done parsing
        \\mul x24, x24, x10
        \\add x24, x24, x9
        \\add x25, x25, #1
        \\subs x26, x26, #1
        \\b.ne 10b
        \\11:
        \\// Card 4c: parse argv[1] (the SECOND 256-byte slot) as the wait
        \\// target pid (only when a second argument was given).
        \\cmp x20, #2
        \\b.lo 6f
        \\mov x25, x21
        \\add x25, x25, #256
        \\mov x26, #32
        \\mov x10, #10
        \\12:
        \\ldrb w9, [x25]
        \\sub x9, x9, #48
        \\cmp x9, #10
        \\b.hs 6f
        \\mul x27, x27, x10
        \\add x27, x27, x9
        \\add x25, x25, #1
        \\subs x26, x26, #1
        \\b.ne 12b
        \\6:
        \\0:
        \\// Card 4c (claim 9946): the wait mode runs ONCE, at the top of
        \\// the first iteration. With a wait target, print the "ipc:
        \\// waiting pid=" marker, block in sys_wait (slot 8) until the
        \\// target process exits, print the observed status ("ipc: saw
        \\// pid=<n> status=<s>"), then fall into the permanent-occupant
        \\// marker loop below (the wait never runs again — x28).
        \\cbnz x28, 13f // already waited
        \\cbz x27, 13f // no wait target: claim-4613/3f/4b behavior
        \\sub sp, sp, #64 // decimal-format scratch (digits at sp+46..sp+62)
        \\mov x0, #1
        \\adr x1, 30f // "ipc: waiting pid="
        \\mov x2, #17
        \\mov x8, #1
        \\svc #0
        \\mov x9, x27 // decimal pid, digits from the end of the scratch
        \\add x14, sp, #62
        \\mov x10, #10
        \\mov x16, #0 // digit count
        \\cbnz x9, 31f
        \\mov x12, #48 // '0'
        \\strb w12, [x14]
        \\mov x16, #1
        \\b 32f
        \\31:
        \\udiv x11, x9, x10
        \\msub x12, x11, x10, x9 // remainder = value - q*10
        \\add x12, x12, #48 // '0'
        \\strb w12, [x14]
        \\sub x14, x14, #1
        \\mov x9, x11
        \\add x16, x16, #1
        \\cbnz x9, 31b
        \\add x14, x14, #1 // x14 = first digit
        \\32:
        \\mov x0, #1
        \\mov x1, x14
        \\mov x2, x16
        \\mov x8, #1
        \\svc #0
        \\mov x0, #1
        \\adr x1, 33f // "\n"
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\// sys_wait(target): slot 8 — the caller blocks until the target
        \\// exits; the kernel patches the observed status into the saved
        \\// frame, so x0 carries it when the ring resumes this task. It
        \\// survives in x19 (callee-saved across the SVC frame).
        \\mov x0, x27
        \\mov x8, #8
        \\svc #0
        \\mov x19, x0
        \\mov x0, #1
        \\adr x1, 34f // "ipc: saw pid="
        \\mov x2, #13
        \\mov x8, #1
        \\svc #0
        \\mov x9, x27 // decimal pid again
        \\add x14, sp, #62
        \\mov x10, #10
        \\mov x16, #0
        \\cbnz x9, 35f
        \\mov x12, #48
        \\strb w12, [x14]
        \\mov x16, #1
        \\b 36f
        \\35:
        \\udiv x11, x9, x10
        \\msub x12, x11, x10, x9
        \\add x12, x12, #48
        \\strb w12, [x14]
        \\sub x14, x14, #1
        \\mov x9, x11
        \\add x16, x16, #1
        \\cbnz x9, 35b
        \\add x14, x14, #1
        \\36:
        \\mov x0, #1
        \\mov x1, x14
        \\mov x2, x16
        \\mov x8, #1
        \\svc #0
        \\mov x0, #1
        \\adr x1, 37f // " status="
        \\mov x2, #8
        \\mov x8, #1
        \\svc #0
        \\mov x9, x19 // decimal status (the observed exit status)
        \\add x14, sp, #62
        \\mov x10, #10
        \\mov x16, #0
        \\cbnz x9, 38f
        \\mov x12, #48
        \\strb w12, [x14]
        \\mov x16, #1
        \\b 39f
        \\38:
        \\udiv x11, x9, x10
        \\msub x12, x11, x10, x9
        \\add x12, x12, #48
        \\strb w12, [x14]
        \\sub x14, x14, #1
        \\mov x9, x11
        \\add x16, x16, #1
        \\cbnz x9, 38b
        \\add x14, x14, #1
        \\39:
        \\mov x0, #1
        \\mov x1, x14
        \\mov x2, x16
        \\mov x8, #1
        \\svc #0
        \\mov x0, #1
        \\adr x1, 33f // "\n"
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\add sp, sp, #64
        \\mov x28, #1 // waited once: the marker loop below never re-waits
        \\13:
        \\// Write the marker: sys_write(fd=1, buf=marker, len=marker.len).
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #15
        \\mov x8, #1
        \\svc #0
        \\// Bounded spin (this program must never dominate a quantum).
        \\movz x9, #50000
        \\2:
        \\sub x9, x9, #1
        \\cbnz x9, 2b
        \\// Card 4b: every 6th iteration, a BURST of 6 messages sent
        \\// back-to-back in ONE quantum (the peer is not scheduled
        \\// mid-burst), then 5 quiet iterations (the peer drains 1 per
        \\// round, so the ring peaks at 6 of the 8 slots and drains to
        \\// 0 before the next burst — NO ENOSPC, deterministically).
        \\add x23, x23, #1
        \\cmp x23, #6
        \\b.lo 3f
        \\mov x23, xzr // reset the cadence counter
        \\cbz x24, 3f // no target (argc == 0 or argv[0] = 0): no sends
        \\mov x26, #6 // burst length
        \\7:
        \\// Build the payload "ping <d>\n" on a 64-byte stack scratch:
        \\// digits written from the end, then the newline, then the
        \\// "ping " prefix immediately before them.
        \\sub sp, sp, #64
        \\mov x9, x22 // seq
        \\mov x10, #10
        \\add x14, sp, #62 // write digits from the second-to-last byte (the
        \\// '\n' lands at sp+63 — the uaccess stack region is EXCLUSIVE at
        \\// the top, so the whole payload must stay inside sp..sp+63).
        \\mov x16, #0 // digit count
        \\4:
        \\udiv x11, x9, x10
        \\msub x12, x11, x10, x9 // remainder = seq - q*10
        \\add x12, x12, #48 // '0'
        \\strb w12, [x14]
        \\sub x14, x14, #1
        \\mov x9, x11
        \\add x16, x16, #1
        \\cbnz x9, 4b
        \\add x14, x14, #1 // x14 = first digit
        \\mov x12, #10
        \\strb w12, [x14, x16] // '\n' after the digits
        \\add x16, x16, #1 // tail len = digits + 1 (the "<d>\n" part)
        \\sub x15, x14, #5 // message start: the "ping " prefix before the digits
        \\mov x12, #112 // 'p'
        \\strb w12, [x15]
        \\mov x12, #105 // 'i'
        \\strb w12, [x15, #1]
        \\mov x12, #110 // 'n'
        \\strb w12, [x15, #2]
        \\mov x12, #103 // 'g'
        \\strb w12, [x15, #3]
        \\mov x12, #32 // ' '
        \\strb w12, [x15, #4]
        \\// Prepend the send marker in the same stack buffer. One
        \\// sys_write keeps SMP scheduler output from splitting the
        \\// prefix from "<d>\n"; the IPC payload at x15 is unchanged.
        \\sub x17, x15, #5
        \\adr x13, 5f // "ipc: ping " overlaps the existing "ping "
        \\mov x12, #10
        \\53:
        \\ldrb w11, [x13], #1
        \\strb w11, [x17], #1
        \\subs x12, x12, #1
        \\b.ne 53b
        \\mov x0, #1
        \\sub x1, x15, #5
        \\add x2, x16, #10
        \\mov x8, #1
        \\svc #0
        \\// Send the payload "ping <d>\n": sys_ipc_send(pid, buf, len) —
        \\// slot 5 (the card-3f ABI amendment).
        \\mov x0, x24
        \\mov x1, x15
        \\mov x2, x16
        \\add x2, x2, #5
        \\mov x8, #5
        \\svc #0
        \\// Check the result: a negative return (ENOSPC -5 or an error)
        \\// prints the distinct "ipc: enospc\n" marker — the live gate
        \\// asserts ZERO of them (the burst never overflows the ring).
        \\cmp x0, #0
        \\b.ge 9f
        \\mov x0, #1
        \\adr x1, 8f
        \\mov x2, #12
        \\mov x8, #1
        \\svc #0
        \\9:
        \\add sp, sp, #64
        \\add x22, x22, #1 // next sequence number
        \\subs x26, x26, #1
        \\b.ne 7b
        \\3:
        \\// Yield cooperatively: sys_yield (slot 2) — the frozen ABI, no
        \\// sys_exit anywhere in this program.
        \\mov x8, #2
        \\svc #0
        \\b 0b
        \\1:
        \\.ascii "counter: alive\n"
        \\5:
        \\.ascii "ipc: ping "
        \\8:
        \\.ascii "ipc: enospc\n"
        \\30:
        \\.ascii "ipc: waiting pid="
        \\34:
        \\.ascii "ipc: saw pid="
        \\37:
        \\.ascii " status="
        \\33:
        \\.byte 10
    );
}

test "user counter module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user counter: the marker shape is pinned (live-gate grep target)" {
    // The exact bytes the payload writes (the `#15` length in the asm and
    // the `1:` `.ascii` must match this const — a drift breaks the live
    // gate's `counter: alive` assertions, never silently).
    try std.testing.expectEqualStrings("counter: alive\n", marker);
    try std.testing.expectEqual(@as(usize, 15), marker.len);
    // The send marker's prefix (the `#10` copy/length in the asm and the
    // `5:` `.ascii` must match this const).
    try std.testing.expectEqualStrings("ipc: ping ", ipc_prefix);
    try std.testing.expectEqual(@as(usize, 10), ipc_prefix.len);
    // The sent payload's prefix (the five `strb` immediates in the asm
    // must spell this exact string).
    try std.testing.expectEqualStrings("ping ", ping_prefix);
    try std.testing.expectEqual(@as(usize, 5), ping_prefix.len);
    // The refusal marker (the `#12` length in the asm and the `8:`
    // `.ascii` must match this const — the live gate asserts ZERO).
    try std.testing.expectEqualStrings("ipc: enospc\n", enospc_marker);
    try std.testing.expectEqual(@as(usize, 12), enospc_marker.len);
    // The wait markers (card 4c — the `#17` / `#13` / `#8` lengths in the
    // asm and the `30:` / `34:` / `37:` `.ascii` must match these consts:
    // the wait gate's grep targets).
    try std.testing.expectEqualStrings("ipc: waiting pid=", wait_prefix);
    try std.testing.expectEqual(@as(usize, 17), wait_prefix.len);
    try std.testing.expectEqualStrings("ipc: saw pid=", saw_prefix);
    try std.testing.expectEqual(@as(usize, 13), saw_prefix.len);
    try std.testing.expectEqualStrings(" status=", saw_status_prefix);
    try std.testing.expectEqual(@as(usize, 8), saw_status_prefix.len);
    // The burst length (the `#6` immediate in the asm must match this
    // const — 6 messages per burst quantum, 6 of the 8 slots at the peak).
    try std.testing.expectEqual(@as(u32, 6), burst_len);
    // The payload is naked asm — no Zig-generated memory references or
    // calls; the module still type-checks the export on the host.
    try std.testing.expectEqual(@as(u32, 50_000), spin_limit);
}
