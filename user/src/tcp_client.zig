//! census (M188e, #3190): TCP.BIN — gate-referenced: live-net-tcp-syscall, live-trust-grants, go-top.
//! VirelaiOS TCP proof program — TCP.BIN (milestone twelve, card N1, Issue #148).
//!
//! Exercises the userland TCP syscall seam end-to-end:
//!   1. `sys_tcp_connect(10.0.0.2, 9999)` (slot 30) -> 0.
//!   2. `sys_write(1, "tcp: connected\n", 15)` (slot 1).
//!   3. `sys_tcp_send("hello", 5)` (slot 31) -> 5.
//!   4. `sys_tcp_recv(buf, 64)` (slot 32) -> 5, prints `tcp: got echo ` + payload.
//!   5. `sys_tcp_close()` (slot 33) -> 0.
//!   6. `sys_exit(18)` (slot 3) — distinct exit status for gate assertions.

const std = @import("std");

pub const peer_ip: u32 = 0x0a000002; // 10.0.0.2 in network byte order
pub const peer_port: u32 = 9999;
pub const payload: []const u8 = "hello";
pub const exit_status: u32 = 18;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// 1. sys_tcp_connect(0x0a000002, 9999) (slot 30)
        \\movz x0, #0x0a00, lsl #16
        \\movk x0, #0x0002
        \\mov x1, #9999
        \\mov x8, #30
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f // Failed to connect
        \\
        \\// 2. sys_write(1, "tcp: connected\n", 15) (slot 1)
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #15
        \\mov x8, #1
        \\svc #0
        \\
        \\// 3. sys_tcp_send("hello", 5) (slot 31)
        \\adr x0, 2f
        \\mov x1, #5
        \\mov x8, #31
        \\svc #0
        \\cmp x0, #5
        \\b.ne 0f // Failed to send 5 bytes
        \\
        \\// 4. Poll sys_tcp_recv(sp, 64) (slot 32)
        \\sub sp, sp, #80
        \\3:
        \\mov x0, sp
        \\mov x1, #64
        \\mov x8, #32
        \\svc #0
        \\cmp x0, #0
        \\b.gt 4f // Received data!
        \\// No data yet: sys_yield() (slot 2) and retry
        \\mov x8, #2
        \\svc #0
        \\b 3b
        \\
        \\4:
        \\// x0 holds byte count (expecting 5)
        \\mov x19, x0
        \\// Print "tcp: got echo " (14 bytes)
        \\mov x0, #1
        \\adr x1, 5f
        \\mov x2, #14
        \\mov x8, #1
        \\svc #0
        \\// Print received payload (x19 bytes from sp)
        \\mov x0, #1
        \\mov x1, sp
        \\mov x2, x19
        \\mov x8, #1
        \\svc #0
        \\// Print newline
        \\mov x0, #1
        \\adr x1, 6f
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\add sp, sp, #80
        \\
        \\// 5. sys_tcp_close() (slot 33)
        \\mov x8, #33
        \\svc #0
        \\
        \\// 6. sys_exit(18) (slot 3)
        \\mov x0, #18
        \\mov x8, #3
        \\svc #0
        \\
        \\// Trap on failure
        \\0:
        \\wfi
        \\b 0b
        \\
        \\.p2align 2
        \\1: .ascii "tcp: connected\n"
        \\2: .ascii "hello"
        \\5: .ascii "tcp: got echo "
        \\6: .ascii "\n"
    );
}
