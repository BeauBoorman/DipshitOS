//! census (M188e, #3190): VMTEST.BIN — gate-referenced: live-vm-depth.
//! VirelaiOS VM Depth Test Binary — VMTEST.BIN (Milestone 29, Issue #598).
//!
//! Verifies userland anonymous mmap, lazy demand-zero fault resolution,
//! write faults, eager MAP_POPULATE, and munmap teardown.

const std = @import("std");
const ui = @import("lib/ui.zig");

pub export fn _start() callconv(.c) noreturn {
    ui.write_console("vmtest: starting M29 VM depth tests\n");

    // 1. Anonymous lazy mmap (8 KiB = 2 pages)
    const addr_i = ui.mmap(0, 8192, ui.PROT_READ | ui.PROT_WRITE, ui.MAP_ANONYMOUS | ui.MAP_PRIVATE);
    if (addr_i <= 0) {
        ui.write_console("vmtest: mmap failed\n");
        ui.exit_process(1);
    }
    const addr: u64 = @intCast(addr_i);
    ui.write_console("vmtest: mmap ok\n");

    // 2. Demand Zero-Fill on read touch (Page 0 and Page 1)
    const ptr0: *volatile u8 = @ptrFromInt(addr);
    const ptr1: *volatile u8 = @ptrFromInt(addr + 4096);
    if (ptr0.* != 0 or ptr1.* != 0) {
        ui.write_console("vmtest: zero-fill verification failed\n");
        ui.exit_process(2);
    }
    ui.write_console("vmtest: demand read ok\n");

    // 3. Write touch and read-back verification
    ptr0.* = 0x42;
    ptr1.* = 0x84;
    if (ptr0.* != 0x42 or ptr1.* != 0x84) {
        ui.write_console("vmtest: read-back verification failed\n");
        ui.exit_process(3);
    }
    ui.write_console("vmtest: demand write ok\n");

    // 4. munmap teardown
    const unmap_res = ui.munmap(addr, 8192);
    if (unmap_res != 0) {
        ui.write_console("vmtest: munmap failed\n");
        ui.exit_process(4);
    }
    ui.write_console("vmtest: munmap ok\n");

    // 5. Eager mmap with MAP_POPULATE
    const eager_i = ui.mmap(0, 4096, ui.PROT_READ | ui.PROT_WRITE, ui.MAP_ANONYMOUS | ui.MAP_PRIVATE | ui.MAP_POPULATE);
    if (eager_i <= 0) {
        ui.write_console("vmtest: eager mmap failed\n");
        ui.exit_process(5);
    }
    const eager_addr: u64 = @intCast(eager_i);
    const eager_ptr: *volatile u8 = @ptrFromInt(eager_addr);
    eager_ptr.* = 0x99;
    if (eager_ptr.* != 0x99) {
        ui.write_console("vmtest: eager read-back failed\n");
        ui.exit_process(6);
    }
    _ = ui.munmap(eager_addr, 4096);
    ui.write_console("vmtest: eager mmap ok\n");

    ui.write_console("vmtest: all tests passed\n");
    ui.exit_process(0);
}

test "vmtest: exports entry" {
    _ = @intFromPtr(&_start);
}
