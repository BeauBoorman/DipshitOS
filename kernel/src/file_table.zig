//! VirelaiOS Milestone 10: Kernel Per-Process File Handle Table (ADR 0010, Cards F1 & F2).
//!
//! Exposes a bounded in-memory file handle table for EL0 userland storage:
//! - 8 open file handles per process slot (`max_handles_per_process = 8`).
//! - Bounded kernel-page-pool storage, no heap or guest allocator dependency.
//! - Tracks the host share partition (`.host`), path, byte cursor offset,
//!   file size, access mode.
//! - Path canonicalization and volume routing (`/host/...`, bare paths -> host share).
//! - Traversal defense (`..` rejection).
//! - Process lifecycle cleanup auto-closes all handles on process termination.
//!
//! M34 HF6 (issue #740): the FAT surface is GONE — `fat.zig`, the ESP/DATA
//! partitions, and the post-exit virtio-blk path were deleted. The `.host`
//! share (`--cvc-file`) is the ONLY file partition: reads stay stateless
//! (vf STAT for the size, vf READ at the guest cursor), writes ride the
//! host's handle-table cursor (vf OPEN/WRITE/TRUNCATE/CLOSE) with legacy
//! FAT replace semantics (write-open truncates to 0 unless append).

const std = @import("std");
const builtin = @import("builtin");
const alloc = @import("alloc.zig");
const process = @import("process.zig");
// M34 HF4 (issue #738): the `.host` partition serves the `--cvc-file`
// share through the host file channel — no FAT. HF5 (issue #739) makes
// it READ-WRITE for userland (the persistence consumers re-point from
// `/data` to `/host`); reads stay stateless (vf READ at the guest
// cursor), writes ride the host's handle-table cursor (vf OPEN/WRITE/
// TRUNCATE/CLOSE).
const virtio_file = @import("virtio_file.zig");
// M43 U3 (issue #1034): the `.usb` partition is the raw USB mass-storage
// disk behind the U2 BOT/SCSI driver — a READ-ONLY block device for now
// (the card's bounded first consumer).
const usb_msc = @import("usb_msc.zig");
// M70f F1 (issue #1458): the `.usb_fat` partition is a READ-ONLY FAT32 file on
// the same block seam. `fat32_ro.zig` is pure (a sector source in, bytes out);
// the adapter is `usb_msc.source()`, so SCSI stays owned by one module.
const fat32_ro = @import("fat32_ro.zig");
// #1072 (ADR 0020): the terminal seam. `/dev/tty` is a virtual device handle
// routed to this process's controlling terminal (open/read/write reuse the
// frozen file ABI — no new syscall slot).
const terminal = @import("terminal.zig");
const app_events = @import("events.zig");
const input = @import("input.zig");
// #1082 (ADR 0020 Amendment A): a `.tty` write to a WINDOW-bound terminal
// drains the ring into the window's presentation grid and marks the bound
// `.user` window damaged (the deferred present) — the compositor blits it.
const driving_award = @import("driving_award.zig");
// M50 TS2 (issue #1136, ADR 0024 D3/D4): the file-ownership/mode predicate
// and the bounded metadata table `OWNERS.TXT` persists.
const trust = @import("trust.zig");
pub const directory = @import("directory.zig");
pub const metadata = @import("fs_metadata.zig");

pub const max_handles_per_process: usize = 8;
pub const max_path_len: usize = directory.path_max;

// Access mode bitmasks (ADR 0010 D2)
pub const MODE_READ: u32 = 0x0001;
pub const MODE_WRITE: u32 = 0x0002;
pub const MODE_CREATE: u32 = 0x0004;
pub const MODE_APPEND: u32 = 0x0008;
/// M25 Lane B (claim 2539): with MODE_CREATE, create a DIRECTORY instead
/// of an empty file (host vf MKDIR). The returned handle rejects
/// read/write — it only marks the creation.
pub const MODE_DIR: u32 = 0x0010;

// Wire DirEntry layout (ADR 0010 D3: exactly 40 bytes)
pub const DirEntry = extern struct {
    name: [32]u8 = @as([32]u8, @splat(@as(u8, 0))),
    size: u32 = 0,
    is_dir: u8 = 0,
    reserved: [3]u8 = @as([3]u8, @splat(@as(u8, 0))),
};

/// The file partitions. M34 HF6 (issue #740) deleted the ESP/DATA
/// partitions; M43 U3 (issue #1034) adds `.usb`, the raw USB mass-storage
/// disk behind the U2 BOT/SCSI driver (read-only).
pub const Partition = enum {
    /// M34 HF4 (issue #738): the host share (`--cvc-file`), served by
    /// the queue-5 file channel. HF5 made it READ-WRITE; HF6 made it the
    /// other partition.
    host,
    /// M43 U3 (issue #1034): the USB mass-storage disk (`usb`, `/usb`,
    /// `usb:`), a READ-ONLY raw block device. Reads are 512-byte SCSI
    /// sectors through `usb_msc`; there is no directory or metadata layer.
    usb,
    /// M70f F1 (issue #1458): a READ-ONLY file inside the FAT32 volume on MBR
    /// partition `<N>` (`usb<N>/<path>`, N = 1..4; `usb<N>` alone is the
    /// volume root, a directory). No write, create, rename, delete or chmod
    /// path exists — the reader cannot mutate a volume.
    usb_fat,
    /// #1072 (ADR 0020): the virtual terminal device (`/dev/tty`) — a
    /// process's controlling terminal, backed by `terminal.zig`. Not a
    /// path on any filesystem; `open` special-cases the name.
    tty,
};

pub const FileHandle = struct {
    in_use: bool = false,
    partition: Partition = .host,
    flags: u32 = 0,
    cursor: u32 = 0,
    size: u32 = 0,
    path: [max_path_len]u8 = @as([max_path_len]u8, @splat(@as(u8, 0))),
    path_len: u16 = 0,
    dir_token: u64 = 0,
    dir_snapshot: usize = 0,
    rich_directory: bool = false,
    contained: bool = false,
    contained_cursor: u64 = 0,
    /// B5 (#1895): a pinned-directory token. It holds one FUSE lookup
    /// reference (`pin_node`) and the identity it was opened with. A stale
    /// pin (renamed or removed at/under its path) only accepts close.
    pin: bool = false,
    pin_stale: bool = false,
    pin_node: u64 = 0,
    pin_identity: metadata.Identity = .{ .filesystem = 0, .inode = 0 },
    /// M25 Lane B (claim 2539): set when MODE_DIR created the entry —
    /// the handle must never be read or written (a directory write would
    /// overwrite host metadata through the channel's replace path).
    is_dir: bool = false,
    /// M34 HF5 (issue #739): a `.host` write handle's host-side cursor
    /// (the vf wire has no write-at-offset — the HOST's 8-slot table owns
    /// the write position). Reads on host handles stay stateless (vf READ
    /// at the guest `cursor`); writes advance the host cursor, mirrored
    /// here by the confirmed byte count. Freed on close / process reset.
    host_handle: u16 = 0,
    host_handle_valid: bool = false,
    /// #1072 (ADR 0020): for a `.tty` handle, the `terminal.zig` registry
    /// index this fd reads/writes.
    term_handle: u8 = 0,
    /// M70f F1 (issue #1458): an open `.usb_fat` file's sequential reader over
    /// the volume's FAT chain (geometry + position + bytes remaining). Only
    /// meaningful when `partition == .usb_fat`.
    usb_file: fat32_ro.FileReader = .{},
};

pub const ParsedPath = struct {
    partition: Partition,
    path: [max_path_len]u8,
    path_len: u16,
    /// M70f F1 (issue #1458): the 1-based MBR partition index a `.usb_fat`
    /// path selects (0 for every other partition).
    usb_index: u8 = 0,

    pub fn parsed_len(self: ParsedPath) usize {
        return self.path_len;
    }
};

// ---------------------------------------------------------------------------
// Module State (bounded page-pool storage; small BSS indexes)
// ---------------------------------------------------------------------------

const HandleTable = [process.max_processes][max_handles_per_process]FileHandle;
const handle_pages: u64 = (@sizeOf(HandleTable) + alloc.page_size - 1) / alloc.page_size;
var handles: [][max_handles_per_process]FileHandle = &.{};
var test_handles: HandleTable = undefined;
var snapshots: [directory.cursor_max]?*directory.Snapshot = @splat(null);
var metadata_snapshots: [directory.cursor_max]?*metadata.Snapshot = @splat(null);
const metadata_pages: u64 = (@sizeOf(metadata.Snapshot) + alloc.page_size - 1) / alloc.page_size;
var test_metadata_snapshots: [directory.cursor_max]metadata.Snapshot = undefined;
var snapshot_used: [directory.cursor_max]bool = @splat(false);
const snapshot_pages: u64 = (@sizeOf(directory.Snapshot) + alloc.page_size - 1) / alloc.page_size;
var test_snapshots: [directory.cursor_max]directory.Snapshot = undefined;
var test_snapshot_pool_empty = false;
// Never reset on pid/handle reuse: a dead token cannot become live again.
var next_dir_token: u64 = 1;

fn ensure_handles() bool {
    if (handles.len != 0) return true;
    const table: *HandleTable = if (builtin.is_test) &test_handles else blk: {
        const pa = alloc.alloc_pages(handle_pages) orelse return false;
        break :blk @ptrFromInt(pa);
    };
    for (table) |*row| for (row) |*h| {
        h.* = .{};
    };
    handles = table;
    return true;
}

fn release_empty_handles() void {
    if (builtin.is_test or handles.len == 0) return;
    for (handles) |row| for (row) |h| {
        if (h.in_use) return;
    };
    _ = alloc.free_pages(@intFromPtr(handles.ptr), handle_pages);
    handles = &.{};
}

fn allocate_snapshot(slot: usize) ?*directory.Snapshot {
    if (builtin.is_test) return if (test_snapshot_pool_empty) null else &test_snapshots[slot];
    const pa = alloc.alloc_pages(snapshot_pages) orelse return null;
    return @ptrFromInt(pa);
}

fn release_snapshot(slot: usize) void {
    if (snapshots[slot]) |snapshot| {
        if (!builtin.is_test) _ = alloc.free_pages(@intFromPtr(snapshot), snapshot_pages);
    }
    snapshots[slot] = null;
    if (metadata_snapshots[slot]) |snapshot| {
        if (!builtin.is_test) _ = alloc.free_pages(@intFromPtr(snapshot), metadata_pages);
    }
    metadata_snapshots[slot] = null;
    snapshot_used[slot] = false;
}

/// B1: stream identities are disjoint from the legacy file table's 0..7.
pub const stream_base: u64 = 0x100;
pub const stream_inherit: u64 = std.math.maxInt(u64);
pub const stream_closed: u64 = stream_inherit - 1;
pub const stream_console: u64 = stream_inherit - 2;
pub const StreamRequest = extern struct {
    version: u32 = 1,
    reserved: u32 = 0,
    sources: [3]u64 = @as([3]u64, @splat(@as(u64, stream_inherit))),
};
const Binding = union(enum) { closed, console, file: usize };
const default_streams: [3]Binding = .{ .closed, .console, .console };
var streams: [process.max_processes][3]Binding = @as([process.max_processes][3]Binding, @splat(@as([3]Binding, default_streams)));
pub const stream_endpoint_max = process.max_processes * 3;
const Endpoint = struct { refs: usize = 0, file: FileHandle = .{} };
const EndpointTable = [stream_endpoint_max]Endpoint;
const endpoint_pages: u64 = (@sizeOf(EndpointTable) + alloc.page_size - 1) / alloc.page_size;
var endpoints: []Endpoint = &.{};
var test_endpoints: EndpointTable = undefined;
var test_endpoint_pool_empty = false;

fn ensure_endpoints() bool {
    if (endpoints.len != 0) return true;
    if (builtin.is_test and test_endpoint_pool_empty) return false;
    const table: *EndpointTable = if (builtin.is_test) &test_endpoints else blk: {
        const pa = alloc.alloc_pages(endpoint_pages) orelse return false;
        break :blk @ptrFromInt(pa);
    };
    for (table) |*ep| ep.* = .{};
    endpoints = table;
    return true;
}

fn release_empty_endpoints() void {
    if (builtin.is_test or endpoints.len == 0) return;
    for (endpoints) |ep| if (ep.refs != 0) return;
    _ = alloc.free_pages(@intFromPtr(endpoints.ptr), endpoint_pages);
    endpoints = &.{};
}
/// Host-only fault injection. Production always calls the real backend.
pub var test_stream_write: ?*const fn (u16, []const u8, *u64) u8 = null;
pub var test_stream_close: ?*const fn (u16) u8 = null;

/// Prepared before loading; committed immediately before task publication.
/// Explicit file sources MOVE from the parent only on successful spawn.
/// Inherited streams share the endpoint and its confirmed sequential cursor.
pub const StreamPlan = struct {
    parent: usize = 0,
    bindings: [3]Binding = default_streams,
    moved: [3]?usize = .{ null, null, null },
    active: bool = false,
};

pub fn is_stream(fd: u64) bool {
    return fd >= stream_base and fd < stream_base + 3;
}

fn release_binding(binding: Binding) i64 {
    switch (binding) {
        .file => |idx| {
            const ep = &endpoints[idx];
            if (ep.refs > 1) {
                ep.refs -= 1;
                return 0;
            }
            if (ep.file.host_handle_valid) {
                if (ep.file.contained) {
                    virtio_file.contained_close(ep.file.host_handle) catch |err| return metadata_errno(err);
                    ep.* = .{};
                    release_empty_endpoints();
                    return 0;
                }
                const st = if (builtin.is_test and test_stream_close != null)
                    test_stream_close.?(ep.file.host_handle)
                else
                    virtio_file.close(ep.file.host_handle);
                if (st != virtio_file.st_ok) return hf_handle_errno(st);
            }
            ep.* = .{};
            release_empty_endpoints();
        },
        else => {},
    }
    return 0;
}

pub fn prepare_streams(parent: usize, request: StreamRequest, plan: *StreamPlan) i64 {
    plan.* = .{ .parent = parent };
    if (parent >= process.max_processes or request.version != 1 or request.reserved != 0) return -1;
    // Validate the whole request before reserving or consuming anything.
    var needs_endpoint = false;
    for (request.sources, 0..) |source, i| {
        if (source == stream_inherit or source == stream_closed) continue;
        if (source == stream_console) {
            if (i == 0) return -7;
            continue;
        }
        if (source >= max_handles_per_process or handles.len == 0) return -2;
        const h = &handles[parent][source];
        if (!h.in_use) return -2;
        if (h.partition != .host or h.is_dir) return -1;
        const want = if (i == 0) MODE_READ else MODE_WRITE;
        if ((h.flags & want) == 0) return -7;
        for (request.sources[0..i]) |prior| {
            if (prior == source) return -1; // no accidental stdout/stderr alias
        }
        needs_endpoint = true;
    }
    if (needs_endpoint and !ensure_endpoints()) return -10;
    defer release_empty_endpoints();
    plan.active = true;
    for (request.sources, 0..) |source, i| {
        if (source == stream_inherit) {
            plan.bindings[i] = streams[parent][i];
            if (plan.bindings[i] == .file) endpoints[plan.bindings[i].file].refs += 1;
        } else if (source == stream_closed) {
            plan.bindings[i] = .closed;
        } else if (source == stream_console) {
            plan.bindings[i] = .console;
        } else {
            var free: ?usize = null;
            for (endpoints, 0..) |*ep, idx| {
                if (ep.refs == 0) {
                    free = idx;
                    break;
                }
            }
            const idx = free orelse {
                cancel_streams(plan);
                return -5;
            };
            endpoints[idx] = .{ .refs = 1, .file = handles[parent][source] };
            plan.bindings[i] = .{ .file = idx };
            plan.moved[i] = @intCast(source);
        }
    }
    return 0;
}

pub fn cancel_streams(plan: *StreamPlan) void {
    if (!plan.active) return;
    for (plan.bindings, plan.moved) |binding, moved| {
        if (moved != null) {
            // The parent still owns this file, including its host handle.
            endpoints[binding.file] = .{};
        } else {
            _ = release_binding(binding);
        }
    }
    plan.active = false;
    release_empty_endpoints();
}

pub fn commit_streams(pid: usize, plan: *StreamPlan) void {
    std.debug.assert(plan.active and pid < process.max_processes);
    for (plan.moved) |fd| {
        if (fd) |n| handles[plan.parent][n] = .{};
    }
    streams[pid] = plan.bindings;
    plan.active = false;
    release_empty_handles();
}

pub fn stream_is_console(pid: u64, fd: u64) bool {
    return pid < process.max_processes and is_stream(fd) and streams[pid][fd - stream_base] == .console;
}

pub fn stream_access(pid: u64, fd: u64, writing: bool) i64 {
    if (pid >= process.max_processes or !is_stream(fd)) return -2;
    if ((fd == stream_base) == writing) return -7;
    return if (streams[pid][fd - stream_base] == .closed) -2 else 0;
}

pub fn stream_read(pid: u64, fd: u64, out: []u8) i64 {
    const access = stream_access(pid, fd, false);
    if (access < 0) return access;
    return switch (streams[pid][fd - stream_base]) {
        .file => |idx| read_handle(pid, &endpoints[idx].file, out, true),
        else => -2, // never attach an absent input to unrelated tty input
    };
}

pub fn stream_peek(pid: u64, fd: u64, out: []u8) i64 {
    const access = stream_access(pid, fd, false);
    if (access < 0) return access;
    return switch (streams[pid][fd - stream_base]) {
        .file => |idx| blk: {
            var snapshot = endpoints[idx].file;
            break :blk read_handle(pid, &snapshot, out, true);
        },
        else => -2,
    };
}

pub fn stream_advance(pid: u64, fd: u64, count: usize) void {
    const h = &endpoints[streams[pid][fd - stream_base].file].file;
    if (h.contained) h.contained_cursor += count else h.cursor += @intCast(count);
}

pub fn stream_write(pid: u64, fd: u64, bytes: []const u8) i64 {
    const access = stream_access(pid, fd, true);
    if (access < 0) return access;
    return switch (streams[pid][fd - stream_base]) {
        .file => |idx| write_handle(pid, &endpoints[idx].file, bytes),
        else => -2, // console is emitted by syscall's registered writer
    };
}

pub fn stream_close(pid: u64, fd: u64) i64 {
    if (pid >= process.max_processes or !is_stream(fd)) return -2;
    const binding = &streams[pid][fd - stream_base];
    if (binding.* == .closed) return -2;
    const result = release_binding(binding.*);
    if (result == 0) binding.* = .closed;
    return result;
}

/// #1072 (ADR 0020): each process's controlling terminal (a `terminal.zig`
/// registry index), created on the first `/dev/tty` open and released when
/// the process is reset. Null = no terminal opened yet.
var process_terminal: [process.max_processes]?usize = @as([process.max_processes]?usize, @splat(@as(?usize, null)));

/// #1072: the terminal device names. Exact match only (no path traversal).
pub fn is_tty_path(name: []const u8) bool {
    return std.mem.eql(u8, name, "/dev/tty") or
        std.mem.eql(u8, name, "tty") or
        std.mem.eql(u8, name, "/dev/tty0") or
        std.mem.eql(u8, name, "tty0");
}

/// #1072: the process's controlling terminal (a `terminal.zig` index), or
/// null when it has not opened `/dev/tty`. Used by the attach syscall.
pub fn controlling_terminal(pid: u64) ?usize {
    if (pid >= process.max_processes) return null;
    return process_terminal[pid];
}

/// M43 U3: one sector scratch for `.usb` reads (BOT is one transfer at a
/// time; a sub-sector read still pulls a whole 512-byte sector here).
var usb_sector: [usb_msc.block_len]u8 align(64) = undefined;

/// M70f F1 (issue #1458): the sector scratch for `.usb_fat` chain reads. It
/// carries the SAME single-reader assumption `usb_sector` already has: file
/// syscalls hold the `.file` service-domain lock (see `syscall.zig`) and the
/// monitor runs one console command at a time, so a `.usb` reader and a
/// `.usb_fat` reader never share a scratch — they are separate buffers on
/// purpose, and the BOT engine refuses a second transfer on an armed
/// direction in any case.
var usb_fat_sector: [fat32_ro.sector_len]u8 align(64) = undefined;

pub fn init() void {
    for (0..process.max_processes) |pid| reset_process(pid);
    for (0..snapshots.len) |slot| release_snapshot(slot);
    if (builtin.is_test) {
        _ = ensure_handles();
        _ = ensure_endpoints();
    }
    for (handles) |*proc_handles| {
        for (proc_handles) |*h| {
            h.* = .{};
        }
    }
    for (&process_terminal) |*t| {
        if (t.*) |h| terminal.release(h);
        t.* = null;
    }
    @memset(&snapshot_used, false);
    release_empty_handles();
}

pub fn reset_process(pid: u64) void {
    if (pid >= process.max_processes) return;
    for (streams[pid]) |binding| {
        // Teardown cannot return an error. Reclaim the bounded record even
        // when a disconnected backend refuses the final close.
        if (release_binding(binding) < 0 and binding == .file) endpoints[binding.file] = .{};
    }
    streams[pid] = default_streams;
    release_empty_endpoints();
    if (handles.len != 0) for (&handles[pid]) |*h| {
        if (h.in_use and h.pin) {
            release_pin(h);
        } else if (h.in_use and h.dir_token != 0) release_snapshot(h.dir_snapshot);
        // HF5: a killed/exited process must free its HOST write handles
        // (the host table is global — a leaked slot would starve others).
        if (h.in_use and h.host_handle_valid) {
            if (h.contained) {
                virtio_file.contained_close(h.host_handle) catch {};
            } else {
                _ = virtio_file.close(h.host_handle);
            }
        }
        h.* = .{};
    };
    release_empty_handles();
    // #1072: a dead process's controlling terminal is released.
    if (process_terminal[pid]) |th| {
        terminal.release(th);
        process_terminal[pid] = null;
    }
}

// ---------------------------------------------------------------------------
// M50 TS2 (issue #1136, ADR 0024 D3/D4/D8): ownership/mode enforcement.
//
// Every entry point below calls `trust.check` AFTER `parse_path` and BEFORE
// any `virtio_file` access. The syscall seam derives the actor from the
// process principal (every EL0 process is uid_user today); kernel-internal
// consumers use `trust.kernel_actor()` at their own call sites. A non-allow
// verdict is EACCES, never a silent allow.
// ---------------------------------------------------------------------------

/// `OWNERS.TXT` save uses bounded pool pages, released on every outcome,
/// rather than a large exception-context stack or static image reservation.
var test_owners_scratch: [trust.save_max]u8 = undefined;
const owners_pages: u64 = (trust.save_max + alloc.page_size - 1) / alloc.page_size;

fn owners_buffer() ?[]u8 {
    if (builtin.is_test) return &test_owners_scratch;
    const pa = alloc.alloc_pages(owners_pages) orelse return null;
    const ptr: [*]u8 = @ptrFromInt(pa);
    return ptr[0..trust.save_max];
}

fn free_owners_buffer(buffer: []u8) void {
    if (!builtin.is_test) _ = alloc.free_pages(@intFromPtr(buffer.ptr), owners_pages);
}

/// The actor for a `file_table` caller: the process principal (ADR 0024 D2)
/// plus the kernel-recorded identity the APPLOG/CRASH label binding needs
/// (#2085 — name and pid come from the registry, never the call's args).
/// An unknown pid (host tests, a non-process caller) defaults to
/// `uid_user`/no caps — the same principal every EL0 process has today.
pub fn actorFor(pid: u64) trust.Actor {
    var actor = trust.Actor{ .uid = process.uid_user, .caps = 0 };
    if (pid < process.max_processes) {
        actor.pid = @intCast(pid);
        if (process.principal(@intCast(pid))) |p| {
            actor.uid = p.uid;
            actor.caps = p.caps;
        }
        if (process.info(@intCast(pid))) |pinfo| actor.name = pinfo.name;
    }
    return actor;
}

fn trustWant(flags: u32) trust.Want {
    if ((flags & MODE_DIR) != 0) return .create;
    if ((flags & MODE_WRITE) != 0) return if ((flags & MODE_CREATE) != 0) .create else .write;
    return .read;
}

/// M97d-F5 (#2090): the operation classes a non-privileged actor may never
/// take on `trust.filename` — the policy file is kernel-writable only.
/// Without this pin the 0644/`uid_user` default makes every EL0 app the
/// OWNER of the policy that governs it (a rewrite persists to the next
/// boot and bypasses slot-69 validation). Reads and listings stay
/// mode-governed: the file is policy, not a secret (D8).
fn policyFileDenies(want: trust.Want) bool {
    return switch (want) {
        .write, .create, .delete, .admin => true,
        .read, .list => false,
    };
}

/// The kernel-only pin: checked BEFORE `trust.check`/`trust.set_mode` so a
/// permissive authored or attacker-written table entry cannot reopen the
/// file for a non-privileged actor. The comparison is case-insensitive to
/// match the host-share keying. Kernel paths (`persist_trust`, the
/// monitor's `vf write` via `kernel_actor`, the boot-time load/save) never
/// carry an EL0 principal, so the kernel is never locked out.
fn policyPinned(actor: trust.Actor, path: []const u8, want: trust.Want) bool {
    if (actor.is_kernel or (actor.caps & process.cap_fs_any) != 0) return false;
    return policyFileDenies(want) and std.ascii.eqlIgnoreCase(path, trust.filename);
}

fn hostAllowed(pid: u64, path: []const u8, want: trust.Want) bool {
    const actor = actorFor(pid);
    if (policyPinned(actor, path, want)) return false;
    return trust.check(actor, .host, path, want) == .allow;
}

pub fn metadata_errno(err: metadata.Error) i64 {
    return switch (err) {
        error.MetadataUnavailable, error.ContainmentUnavailable => -4,
        error.FileNotFound => -6,
        error.AccessDenied, error.SymlinkRejected => -7,
        error.PathLimit => -8,
        error.HandleLimit, error.TreeLimit => -5,
        error.StaleIdentity => -2,
        error.Exists => -9, // file-domain EEXIST (B4)
        else => -1,
    };
}

fn metadataWant(access: metadata.Access) trust.Want {
    return switch (access) {
        .metadata => .list,
        .read => .read,
        .write => .write,
        .create => .create,
        .delete => .delete,
    };
}

const MetadataAuth = struct {
    pid: u64,
    root: []const u8,

    fn check(context: *anyopaque, path: []const u8, access: metadata.Access) metadata.Error!void {
        const self: *MetadataAuth = @ptrCast(@alignCast(context));
        var buffer: [metadata.max_relative_path]u8 = undefined;
        const full = try join_metadata(self.root, path, &buffer);
        // Check every share-relative ancestor, including ancestors of the
        // supplied root. Host uid/mode must never substitute for this policy.
        if (!hostAllowed(self.pid, "", .list)) return error.AccessDenied;
        var at: usize = 0;
        while (at < full.len) {
            const end = std.mem.indexOfScalarPos(u8, full, at, '/') orelse full.len;
            const want: trust.Want = if (end < full.len) .list else metadataWant(access);
            if (!hostAllowed(self.pid, full[0..end], want)) return error.AccessDenied;
            at = end + 1;
        }
    }

    fn authorizer(self: *MetadataAuth) metadata.Authorizer {
        return .{ .context = self, .check = check };
    }
};

fn metadata_root(raw: []const u8) metadata.Error![]const u8 {
    // No normalization may erase an escape or symlink component. Only the
    // documented native host prefix is stripped; USB/tty are unsupported.
    const path = if (std.mem.eql(u8, raw, "/host") or std.mem.eql(u8, raw, "/host/"))
        ""
    else if (std.mem.startsWith(u8, raw, "/host/"))
        raw[6..]
    else
        return error.ContainmentUnavailable;
    try metadata.validatePath(path);
    return path;
}

fn join_metadata(root: []const u8, relative: []const u8, out: []u8) metadata.Error![]const u8 {
    if (!directory.valid_path(root, metadata.max_depth * 2) or
        !directory.valid_path(relative, metadata.max_depth * 2)) return error.InvalidPath;
    const sep: usize = @intFromBool(root.len != 0 and relative.len != 0);
    const len = root.len + sep + relative.len;
    if (len > metadata.max_relative_path or len > out.len) return error.PathLimit;
    @memcpy(out[0..root.len], root);
    if (sep != 0) out[root.len] = '/';
    @memcpy(out[root.len + sep ..][0..relative.len], relative);
    return out[0..len];
}

pub fn metadata_at(pid: u64, root_bytes: []const u8, relative: []const u8, out: *metadata.Wire) i64 {
    if (pid >= process.max_processes) return -1;
    const path = metadata_root(root_bytes) catch |err| return metadata_errno(err);
    var root = virtio_file.MetadataRoot{ .path = path };
    var auth = MetadataAuth{ .pid = pid, .root = path };
    const value = metadata.stat(virtio_file.metadata_backend(&root), auth.authorizer(), relative) catch |err| return metadata_errno(err);
    out.* = metadata.Wire.from(value);
    return 0;
}

/// Opens an existing pinned regular file, without create/truncate/append.
/// The returned native fd uses slots 24/25/26, never reopens a pathname.
pub fn contained_open(pid: u64, root_bytes: []const u8, relative: []const u8, writing: bool) i64 {
    if (pid >= process.max_processes) return -1;
    const root_path = metadata_root(root_bytes) catch |err| return metadata_errno(err);
    var full: [max_path_len]u8 = undefined;
    const path = join_metadata(root_path, relative, &full) catch |err| return metadata_errno(err);
    if (!ensure_handles()) return -10;
    defer release_empty_handles();
    if (resource_count(pid) >= max_handles_per_process) return -5;
    var slot: usize = 0;
    while (slot < max_handles_per_process and handles[pid][slot].in_use) : (slot += 1) {}
    if (slot == max_handles_per_process) return -5;
    var root = virtio_file.MetadataRoot{ .path = root_path };
    var auth = MetadataAuth{ .pid = pid, .root = root_path };
    const token = metadata.openToken(virtio_file.metadata_backend(&root), auth.authorizer(), relative, if (writing) .write else .read) catch |err| return metadata_errno(err);
    var h = FileHandle{
        .in_use = true,
        .flags = if (writing) MODE_WRITE else MODE_READ,
        .path_len = @intCast(path.len),
        .host_handle = @intCast(token),
        .host_handle_valid = true,
        .contained = true,
    };
    @memcpy(h.path[0..path.len], path);
    handles[pid][slot] = h;
    return @intCast(slot);
}

pub fn metadata_dir_open(pid: u64, root_bytes: []const u8, relative: []const u8) i64 {
    if (pid >= process.max_processes) return -1;
    const root_path = metadata_root(root_bytes) catch |err| return metadata_errno(err);
    var full: [max_path_len]u8 = undefined;
    const path = join_metadata(root_path, relative, &full) catch |err| return metadata_errno(err);
    if (!ensure_handles()) return -10;
    defer release_empty_handles();
    if (resource_count(pid) >= max_handles_per_process) return -5;
    var fd: usize = 0;
    while (fd < max_handles_per_process and handles[pid][fd].in_use) : (fd += 1) {}
    var slot: usize = 0;
    while (slot < snapshot_used.len and snapshot_used[slot]) : (slot += 1) {}
    if (fd == max_handles_per_process or slot == snapshot_used.len or next_dir_token > std.math.maxInt(i64)) return -5;
    const snapshot: *metadata.Snapshot = if (builtin.is_test)
        &test_metadata_snapshots[slot]
    else
        @ptrFromInt(alloc.alloc_pages(metadata_pages) orelse return -10);
    metadata_snapshots[slot] = snapshot;
    var root = virtio_file.MetadataRoot{ .path = root_path };
    var auth = MetadataAuth{ .pid = pid, .root = root_path };
    virtio_file.metadata_snapshot(virtio_file.metadata_backend(&root), auth.authorizer(), relative, snapshot) catch |err| {
        release_snapshot(slot);
        return metadata_errno(err);
    };
    const token = next_dir_token;
    next_dir_token += 1;
    var h = FileHandle{
        .in_use = true,
        .is_dir = true,
        .rich_directory = true,
        .dir_token = token,
        .dir_snapshot = slot,
        .path_len = @intCast(path.len),
    };
    @memcpy(h.path[0..path.len], path);
    handles[pid][fd] = h;
    snapshot_used[slot] = true;
    return @intCast(token);
}

pub fn metadata_dir_page(pid: u64, token: u64, offset: u64, limit: u64, page: *metadata.Page) i64 {
    const h = dir_handle(pid, token) orelse return -2;
    if (!h.rich_directory) return -2;
    var auth = MetadataAuth{ .pid = pid, .root = "" };
    MetadataAuth.check(&auth, h.path[0..h.path_len], .metadata) catch |err| return metadata_errno(err);
    if (limit == 0 or limit > directory.page_max) return -1;
    const snapshot = metadata_snapshots[h.dir_snapshot].?;
    if (offset > snapshot.count) return -1;
    const take: usize = @intCast(@min(limit, snapshot.count - offset));
    // Reauthorize child rows too: a captured snapshot is not an ACL grant.
    for (snapshot.entries[@intCast(offset)..][0..take]) |entry| {
        var full: [max_path_len]u8 = undefined;
        const path = join_metadata(h.path[0..h.path_len], entry.name[0..entry.name_len], &full) catch |err| return metadata_errno(err);
        MetadataAuth.check(&auth, path, .metadata) catch |err| return metadata_errno(err);
    }
    page.header = .{ .count = @intCast(take), .next = offset + take, .end = @intFromBool(offset + take == snapshot.count) };
    @memcpy(page.entries[0..take], snapshot.entries[@intCast(offset)..][0..take]);
    return @intCast(take);
}

// ---------------------------------------------------------------------------
// B5 (#1895, ADR 0007): pinned directories and name operations below them.
// Every use reauthorizes the pin's recorded share-relative path; the backend
// acts on the pinned FUSE node, never on a re-resolved pathname.
// ---------------------------------------------------------------------------

fn pin_object(h: *const FileHandle) metadata.Object {
    var value = std.mem.zeroes(metadata.Metadata);
    value.identity = h.pin_identity;
    value.kind = .directory;
    value.host_mode = 0o040000;
    return .{ .token = h.pin_node, .metadata = value };
}

fn pin_directory(h: *const FileHandle) metadata.Directory {
    return .{ .object = pin_object(h), .path = h.path[0..h.path_len] };
}

fn release_pin(h: *FileHandle) void {
    var root = virtio_file.MetadataRoot{ .path = "" };
    const backend = virtio_file.metadata_backend(&root);
    // Without a live backend the mount lifetime (and its reference) ended.
    if (backend.ops) |ops| ops.release(backend.context, pin_object(h));
}

fn live_pin(pid: u64, token: u64) ?*FileHandle {
    const h = dir_handle(pid, token) orelse return null;
    return if (h.pin and !h.pin_stale) h else null;
}

fn free_resource_slot(pid: u64) ?usize {
    if (resource_count(pid) >= max_handles_per_process) return null;
    for (handles[pid], 0..) |h, slot| {
        if (!h.in_use) return slot;
    }
    return null;
}

fn install_pin(pid: u64, slot: usize, path: []const u8, object: metadata.Object) i64 {
    const token = next_dir_token;
    next_dir_token += 1;
    var h = FileHandle{
        .in_use = true,
        .is_dir = true,
        .dir_token = token,
        .pin = true,
        .pin_node = object.token,
        .pin_identity = object.metadata.identity,
        .path_len = @intCast(path.len),
    };
    @memcpy(h.path[0..path.len], path);
    handles[pid][slot] = h;
    return @intCast(token);
}

fn path_at_or_under(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len or !std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

/// A pin's recorded path authorizes its uses. After a successful guest
/// rename or directory removal that path may name another object, so every
/// process's pins at/under it go stale (EBADF until closed). Host-side
/// moves are not observed.
fn invalidate_pins(path: []const u8) void {
    if (handles.len == 0 or path.len == 0) return;
    for (handles) |*row| for (row) |*h| {
        if (h.in_use and h.pin and path_at_or_under(h.path[0..h.path_len], path)) h.pin_stale = true;
    };
}

/// Op 7: pins an existing directory by the B3 no-follow walk.
pub fn pin_open(pid: u64, root_bytes: []const u8, relative: []const u8) i64 {
    if (pid >= process.max_processes) return -1;
    const root_path = metadata_root(root_bytes) catch |err| return metadata_errno(err);
    var full: [max_path_len]u8 = undefined;
    const path = join_metadata(root_path, relative, &full) catch |err| return metadata_errno(err);
    if (!ensure_handles()) return -10;
    defer release_empty_handles();
    const slot = free_resource_slot(pid) orelse return -5;
    if (next_dir_token > std.math.maxInt(i64)) return -5;
    var root = virtio_file.MetadataRoot{ .path = root_path };
    var auth = MetadataAuth{ .pid = pid, .root = root_path };
    const object = metadata.openDirectory(virtio_file.metadata_backend(&root), auth.authorizer(), relative) catch |err| return metadata_errno(err);
    return install_pin(pid, slot, path, object);
}

/// Op 8: one no-follow LOOKUP of a child directory from a live pin.
pub fn pin_child(pid: u64, token: u64, name: []const u8) i64 {
    if (pid >= process.max_processes) return -1;
    const parent = live_pin(pid, token) orelse return -2;
    var child: [max_path_len]u8 = undefined;
    const path = metadata.childPath(parent.path[0..parent.path_len], name, &child) catch |err| return metadata_errno(err);
    const slot = free_resource_slot(pid) orelse return -5;
    if (next_dir_token > std.math.maxInt(i64)) return -5;
    var root = virtio_file.MetadataRoot{ .path = "" };
    var auth = MetadataAuth{ .pid = pid, .root = "" };
    const object = metadata.childDirectory(virtio_file.metadata_backend(&root), auth.authorizer(), pin_directory(parent), name) catch |err| return metadata_errno(err);
    return install_pin(pid, slot, path, object);
}

/// Op 9. Allowed after revocation or invalidation; releases the reference.
pub fn pin_close(pid: u64, token: u64) i64 {
    const h = dir_handle(pid, token) orelse return -2;
    if (!h.pin) return -2;
    release_pin(h);
    h.* = .{};
    release_empty_handles();
    return 0;
}

/// Op 10: live attributes of a pin (kind 1) or a contained fd (kind 0).
/// A changed identity is EBADF; legacy fds have no pinned object (ENOSYS).
pub fn handle_metadata(pid: u64, handle: u64, kind: u64, out: *metadata.Wire) i64 {
    if (pid >= process.max_processes) return -1;
    if (kind != metadata.handle_file and kind != metadata.handle_directory) return -1;
    var root = virtio_file.MetadataRoot{ .path = "" };
    var auth = MetadataAuth{ .pid = pid, .root = "" };
    const backend = virtio_file.metadata_backend(&root);
    var value: metadata.Metadata = undefined;
    if (kind == metadata.handle_directory) {
        const h = live_pin(pid, handle) orelse return -2;
        value = metadata.directoryMetadata(backend, auth.authorizer(), pin_directory(h)) catch |err| return metadata_errno(err);
    } else {
        if (handle >= max_handles_per_process or handles.len == 0) return -2;
        const h = &handles[pid][handle];
        if (!h.in_use or h.dir_token != 0 or h.is_dir) return -2;
        if (!h.contained or !h.host_handle_valid) return -4;
        value = metadata.handleMetadata(backend, auth.authorizer(), h.host_handle, h.path[0..h.path_len]) catch |err| return metadata_errno(err);
    }
    out.* = metadata.Wire.from(value);
    return 0;
}

/// Op 11: exclusive create below a live pin; returns a write-only fd.
pub fn pin_create(pid: u64, token: u64, name: []const u8) i64 {
    if (pid >= process.max_processes) return -1;
    const parent = live_pin(pid, token) orelse return -2;
    var child: [max_path_len]u8 = undefined;
    const path = metadata.childPath(parent.path[0..parent.path_len], name, &child) catch |err| return metadata_errno(err);
    const slot = free_resource_slot(pid) orelse return -5;
    var root = virtio_file.MetadataRoot{ .path = "" };
    var auth = MetadataAuth{ .pid = pid, .root = "" };
    const created = metadata.createFile(virtio_file.metadata_backend(&root), auth.authorizer(), pin_directory(parent), name) catch |err| return metadata_errno(err);
    var h = FileHandle{
        .in_use = true,
        .flags = MODE_WRITE,
        .path_len = @intCast(path.len),
        .host_handle = @intCast(created.handle),
        .host_handle_valid = true,
        .contained = true,
    };
    @memcpy(h.path[0..path.len], path);
    handles[pid][slot] = h;
    return @intCast(slot);
}

/// Op 12: creates a directory below a live pin and returns it pinned.
pub fn pin_mkdir(pid: u64, token: u64, name: []const u8) i64 {
    if (pid >= process.max_processes) return -1;
    const parent = live_pin(pid, token) orelse return -2;
    var child: [max_path_len]u8 = undefined;
    const path = metadata.childPath(parent.path[0..parent.path_len], name, &child) catch |err| return metadata_errno(err);
    const slot = free_resource_slot(pid) orelse return -5;
    if (next_dir_token > std.math.maxInt(i64)) return -5;
    var root = virtio_file.MetadataRoot{ .path = "" };
    var auth = MetadataAuth{ .pid = pid, .root = "" };
    const object = metadata.makeDirectory(virtio_file.metadata_backend(&root), auth.authorizer(), pin_directory(parent), name) catch |err| return metadata_errno(err);
    return install_pin(pid, slot, path, object);
}

/// Op 13: removes one file (kind 0) or empty directory (kind 1) by name.
pub fn pin_remove(pid: u64, token: u64, name: []const u8, kind: u64) i64 {
    if (pid >= process.max_processes) return -1;
    if (kind != metadata.remove_file and kind != metadata.remove_directory) return -1;
    const parent = live_pin(pid, token) orelse return -2;
    var child: [max_path_len]u8 = undefined;
    const path = metadata.childPath(parent.path[0..parent.path_len], name, &child) catch |err| return metadata_errno(err);
    const want: metadata.Kind = if (kind == metadata.remove_directory) .directory else .file;
    var root = virtio_file.MetadataRoot{ .path = "" };
    var auth = MetadataAuth{ .pid = pid, .root = "" };
    metadata.remove(virtio_file.metadata_backend(&root), auth.authorizer(), pin_directory(parent), name, want) catch |err| return metadata_errno(err);
    if (want == .directory) invalidate_pins(path);
    if (trust.remove(.host, path)) _ = persist_trust();
    return 0;
}

/// Op 14: one backend rename between two live pins of this process.
pub fn pin_rename(pid: u64, from_token: u64, from_name: []const u8, to_token: u64, to_name: []const u8, replace: bool) i64 {
    if (pid >= process.max_processes) return -1;
    const from = live_pin(pid, from_token) orelse return -2;
    const to = live_pin(pid, to_token) orelse return -2;
    var source: [max_path_len]u8 = undefined;
    var target: [max_path_len]u8 = undefined;
    const from_path = metadata.childPath(from.path[0..from.path_len], from_name, &source) catch |err| return metadata_errno(err);
    const to_path = metadata.childPath(to.path[0..to.path_len], to_name, &target) catch |err| return metadata_errno(err);
    var root = virtio_file.MetadataRoot{ .path = "" };
    var auth = MetadataAuth{ .pid = pid, .root = "" };
    metadata.rename(virtio_file.metadata_backend(&root), auth.authorizer(), pin_directory(from), from_name, pin_directory(to), to_name, replace) catch |err| return metadata_errno(err);
    invalidate_pins(from_path);
    invalidate_pins(to_path);
    if (trust.rename_meta(.host, from_path, .host, to_path)) _ = persist_trust();
    return 0;
}

/// Serialize the trust table and persist it to `OWNERS.TXT` on the share.
fn persist_trust() bool {
    const scratch = owners_buffer() orelse return false;
    defer free_owners_buffer(scratch);
    const n = trust.save(scratch);
    if (n == 0) return false;
    return virtio_file.write_whole(trust.filename, scratch[0..n]) == virtio_file.st_ok;
}

/// Load `OWNERS.TXT` from the host share at boot (no-op without a channel or
/// when the file is absent — the empty table is today's behavior).
/// M97g (#2083): `OWNERS.TXT` is self-protected BY CONSTRUCTION first — an
/// EL0 process must never write the metadata that other gates trust, even
/// on a share where the file does not exist yet.
pub fn load_trust_from_share() bool {
    _ = trust.ensure_meta_file();
    if (!virtio_file.available()) return false;
    var st = virtio_file.StatResult{};
    if (virtio_file.stat(trust.filename, &st) != virtio_file.st_ok or
        st.is_dir or st.size == 0 or st.size > trust.save_max) return false;
    // The custom-device boot probe calls this before alloc.init.
    var chunk: [1024]u8 = undefined;
    var line: [trust.max_path_len + 64]u8 = undefined;
    var len: usize = 0;
    var overlong = false;
    var offset: u64 = 0;
    trust.init();
    var state = trust.LoadState{};
    while (offset < st.size) {
        const take: usize = @intCast(@min(chunk.len, st.size - offset));
        const n = virtio_file.read_at_into(trust.filename, offset, chunk[0..take]) orelse return false;
        if (n == 0 or n > take) return false;
        for (chunk[0..n]) |c| {
            if (c == '\n') {
                state.consume(line[0..len], overlong);
                len = 0;
                overlong = false;
            } else if (len < line.len) {
                line[len] = c;
                len += 1;
            } else {
                overlong = true;
            }
        }
        offset += n;
    }
    if (len != 0 or overlong) state.consume(line[0..len], overlong);
    return state.result() == .ok;
}

/// ADR 0024 D10 slot 69: `sys_file_mode(path, mode)` — owner-only chmod on an
/// existing path, or `CAP_FS_ANY`. No chown. Persists the table to
/// `OWNERS.TXT`; a full table is ENOSPC, never eviction.
pub fn set_mode(pid: u64, path_bytes: []const u8, mode: u16) i64 {
    if (pid >= process.max_processes) return -1;
    if (path_bytes.len == 0 or path_bytes.len > max_path_len) return -1;
    const parsed = parse_path(path_bytes) orelse return -1;
    if (parsed.partition == .tty) return -1; // device semantics
    // `.usb` and `.usb_fat` are fixed read-only 0444 for every actor.
    if (parsed.partition == .usb or parsed.partition == .usb_fat) return -7;
    if (!virtio_file.available()) return -6;
    const subpath = parsed.path[0..parsed.parsed_len()];
    // M97d-F5 (#2090): the policy file is kernel-writable only — chmod on
    // it is denied even though stat resolves and the default entry would
    // name the caller its owner. Before `stat` so a non-privileged attempt
    // is a gate denial, never a persistence outcome.
    if (parsed.partition == .host and policyPinned(actorFor(pid), subpath, .admin)) return -7;
    var st = virtio_file.StatResult{};
    if (virtio_file.stat(subpath, &st) != virtio_file.st_ok) return -6; // existing path only
    switch (trust.set_mode(actorFor(pid), .host, subpath, mode)) {
        .ok => {},
        .eacces => return -7,
        .enospc => return -5,
        .einval => return -1,
    }
    if (!persist_trust()) return -5; // honest: nothing half-persisted
    return 0;
}

// ---------------------------------------------------------------------------
// Path Parsing, Canonicalization & Volume Routing (Card F2)
// ---------------------------------------------------------------------------

/// M70f F1 (issue #1458): the `usb<N>[:/]` volume form. Returns the 1-based
/// partition digit and the path remainder; null when the text is not that form
/// (so `usbx.txt` stays a host file, the same boundary rule as `host`/`usb`).
pub const UsbVolumeForm = struct { index: u8, rest: []const u8 };

pub fn usbVolumeForm(subpath: []const u8) ?UsbVolumeForm {
    if (subpath.len < 4) return null;
    if (!std.ascii.eqlIgnoreCase(subpath[0..3], "usb")) return null;
    const d = subpath[3];
    if (d < '1' or d > '9') return null;
    var rest_at: usize = 4;
    if (subpath.len > 4) {
        if (subpath[4] == '/' or subpath[4] == ':') {
            rest_at = 5;
        } else {
            return null; // `usb1x` is still a host file
        }
    }
    return .{ .index = d - '0', .rest = subpath[rest_at..] };
}

/// Parse and normalize userland path, routing to the host share partition.
/// Rejects directory traversal attempts (`..`) and paths exceeding `max_path_len`.
pub fn parse_path(raw: []const u8) ?ParsedPath {
    if (raw.len == 0 or raw.len > max_path_len) return null;

    // Check for forbidden directory traversal ('..')
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '.') {
            if (i + 1 < raw.len and raw[i + 1] == '.') {
                // Must be isolated by boundary or slash
                const prev_bound = (i == 0 or raw[i - 1] == '/');
                const next_bound = (i + 2 == raw.len or raw[i + 2] == '/');
                if (prev_bound and next_bound) {
                    return null; // Forbidden traversal
                }
            }
        }
        i += 1;
    }

    var partition: Partition = .host;
    var usb_index: u8 = 0;
    var subpath = raw;

    // Strip leading slashes for prefix detection
    while (subpath.len > 0 and subpath[0] == '/') {
        subpath = subpath[1..];
    }

    // M34 HF4 (issue #738): the host-share prefix routes to `.host` with
    // the path relative to the share root. HF6 (issue #740): with the
    // ESP/DATA partitions gone, EVERY path routes to the share — bare
    // paths, `/host/...`, and `host:...` all land on `.host`.
    if (subpath.len >= 5 and std.ascii.eqlIgnoreCase(subpath[0..5], "host/")) {
        partition = .host;
        subpath = subpath[5..];
    } else if (subpath.len >= 5 and std.ascii.eqlIgnoreCase(subpath[0..5], "host:")) {
        partition = .host;
        subpath = subpath[5..];
    } else if (subpath.len == 4 and std.ascii.eqlIgnoreCase(subpath[0..4], "host")) {
        partition = .host;
        subpath = "";
    } else if (usbVolumeForm(subpath)) |vf| {
        // M70f F1 (issue #1458): `usb<N>[/path]` is a read-only FAT32 volume on
        // MBR partition N. `usb5`..`usb9` name a slot the MBR cannot have: the
        // whole path is refused (EINVAL) rather than silently re-read as a host
        // file, so a typo fails loudly instead of opening the wrong volume.
        if (vf.index > 4) return null;
        partition = .usb_fat;
        usb_index = vf.index;
        subpath = vf.rest;
    } else if (subpath.len >= 4 and std.ascii.eqlIgnoreCase(subpath[0..4], "usb/")) {
        // M43 U3 (issue #1034): the raw USB mass-storage block device.
        partition = .usb;
        subpath = subpath[4..];
    } else if (subpath.len >= 4 and std.ascii.eqlIgnoreCase(subpath[0..4], "usb:")) {
        partition = .usb;
        subpath = subpath[4..];
    } else if (subpath.len == 3 and std.ascii.eqlIgnoreCase(subpath[0..3], "usb")) {
        partition = .usb;
        subpath = "";
    }

    // Clean up multiple consecutive slashes and strip leading/trailing slashes
    var out: [max_path_len]u8 = @as([max_path_len]u8, @splat(@as(u8, 0)));
    var out_len: usize = 0;

    var s_idx: usize = 0;
    while (s_idx < subpath.len) {
        const c = subpath[s_idx];
        if (c == '/') {
            // Collapse consecutive slashes
            if (out_len > 0 and out[out_len - 1] != '/') {
                if (out_len >= max_path_len) return null;
                out[out_len] = '/';
                out_len += 1;
            }
        } else {
            if (out_len >= max_path_len) return null;
            out[out_len] = c;
            out_len += 1;
        }
        s_idx += 1;
    }

    // Remove trailing slash if path is non-empty
    while (out_len > 0 and out[out_len - 1] == '/') {
        out_len -= 1;
    }
    // Preserve legacy deep paths; their byte bound already bounds parsing.
    if (!directory.valid_path(out[0..out_len], max_path_len)) return null;

    return ParsedPath{
        .partition = partition,
        .path = out,
        .path_len = @intCast(out_len),
        .usb_index = usb_index,
    };
}

// ---------------------------------------------------------------------------
// M66a (#1443): honest HF-status → errno mapping.
//
// The HF reply statuses (virtio_file.zig) land on the frozen ADR 0007 error
// rows so a Go app can branch on what actually happened. The four statuses a
// /host path can hit map to four DISTINCT rows — not_found → ENOENT (-6),
// is_dir → EINVAL (-1, a directory is not a writable file), exists → -9 (the
// file-domain EEXIST row the MODE_DIR mkdir path pinned in M25 Lane B; the
// ErrorCode enum names this magnitude ENXIO in the device domains), and
// handle-full → ENOSPC (-5, the same resource-exhausted row as the guest's
// own full handle table). A residual host error (status 4 — the share
// refused the I/O) stays EINVAL, the closest honest row in the frozen enum.
// Pure and host-testable; the path ops route through `hf_open_errno`.
pub fn hf_open_errno(st: u8) i64 {
    return switch (st) {
        virtio_file.st_ok => 0,
        virtio_file.st_not_found => -6, // ENOENT
        virtio_file.st_is_dir => -1, // EINVAL: a directory is not a writable file
        virtio_file.st_exists => -9, // file-domain EEXIST (M25 Lane B)
        virtio_file.st_handle => -5, // ENOSPC: the host's 8-slot table is full
        else => -1, // host error / truncated
    };
}

/// The handle-carrying ops (WRITE/TRUNCATE/FSYNC) only ever see ok, a dead
/// or unknown host handle, and the residual host error. A handle the guest
/// still holds but the host no longer knows is EBADF — the fd's other end is
/// gone — not EINVAL, and never ENOSPC (nothing is exhausted; the slot the
/// handle named is simply not there).
pub fn hf_handle_errno(st: u8) i64 {
    return switch (st) {
        virtio_file.st_ok => 0,
        virtio_file.st_handle => -2, // EBADF
        else => -1, // host error
    };
}

// ---------------------------------------------------------------------------
// File Handle Operations (Card F1)
// ---------------------------------------------------------------------------

/// Open a file for `pid` with given `flags`.
/// Returns fd (0..7) on success, or negative error code:
/// - `-1` (`EINVAL`): Invalid flags, bad path syntax, traversal attempted,
///   is-dir (M66a: HF status 2), a residual host error
/// - `-2` (`EBADF`): Not applicable for open
/// - `-5` (`ENOSPC`): Handle table full — the guest's 8 open handles, or the
///   host's 8 (M66a: HF status 6 rides the same row)
/// - `-6` (`ENOENT`): File not found and MODE_CREATE not set (or no share)
/// - `-8` (`ENAMETOOLONG`): Path length > 512
/// - `-9` (`EEXIST`): MODE_DIR create and the name already exists
pub fn open(pid: u64, path_bytes: []const u8, flags: u32) i64 {
    if (pid >= process.max_processes) return -1;
    if (flags == 0) return -1;
    if ((flags & ~(MODE_READ | MODE_WRITE | MODE_CREATE | MODE_APPEND | MODE_DIR)) != 0) return -1;
    if ((flags & (MODE_READ | MODE_WRITE)) == 0) return -1;
    // M25 Lane B: directory creation rides the mutating open flags.
    if ((flags & MODE_DIR) != 0 and (flags & (MODE_CREATE | MODE_WRITE)) != (MODE_CREATE | MODE_WRITE)) return -1;

    if (path_bytes.len > max_path_len) return -8;
    if (!ensure_handles()) return -10;
    defer release_empty_handles();

    // Find free handle slot for calling process
    if (resource_count(pid) >= max_handles_per_process) return -5;
    var free_slot: ?usize = null;
    for (handles[pid], 0..) |h, idx| {
        if (!h.in_use) {
            free_slot = idx;
            break;
        }
    }
    const slot = free_slot orelse return -5; // ENOSPC (table full)

    // #1072 (ADR 0020): `/dev/tty` is the process's controlling terminal —
    // a virtual device, not a filesystem path. Created lazily on the first
    // open and reused for the process's lifetime.
    if (is_tty_path(path_bytes)) {
        const th = process_terminal[pid] orelse blk: {
            const h = terminal.create(pid) orelse return -5;
            process_terminal[pid] = h;
            break :blk h;
        };
        handles[pid][slot] = .{
            .in_use = true,
            .partition = .tty,
            .flags = flags,
            .term_handle = @intCast(th),
        };
        return @intCast(slot);
    }

    const parsed = parse_path(path_bytes) orelse return -1;

    // M43 U3 (issue #1034): the `.usb` raw block device. READ-ONLY: any
    // write-ish flag is EINVAL; no device or no capacity is ENOENT. The
    // handle's size is the disk's byte length (clamped to the frozen u32
    // ABI); reads are sequential 512-byte sectors at the cursor.
    if (parsed.partition == .usb) {
        if ((flags & (MODE_WRITE | MODE_CREATE | MODE_APPEND | MODE_DIR)) != 0) return -1;
        const cap = usb_msc.capacity() orelse return -6;
        if (cap.block_len != usb_msc.block_len) return -6; // only 512-B sectors
        const sectors: u64 = @as(u64, cap.last_lba) + 1;
        const bytes: u64 = sectors * cap.block_len;
        handles[pid][slot] = .{
            .in_use = true,
            .partition = .usb,
            .flags = flags,
            .cursor = 0,
            .size = @intCast(@min(bytes, std.math.maxInt(u32))),
            .path = parsed.path,
            .path_len = parsed.path_len,
            .is_dir = false,
        };
        return @intCast(slot);
    }

    // M70f F1 (issue #1458): a READ-ONLY file inside MBR partition N's FAT32
    // volume. The error split is deliberate and part of the surface:
    //   -6 ENOENT — no device, no such partition, no such file;
    //   -1 EINVAL — the partition exists but is not a readable FAT32 volume,
    //                the path is the volume root (a directory), a path
    //                component that is a file, or an unusable chain.
    // Nothing here writes: every mutating flag is refused before a single
    // sector is read.
    if (parsed.partition == .usb_fat) {
        if ((flags & (MODE_WRITE | MODE_CREATE | MODE_APPEND | MODE_DIR)) != 0) return -1;
        const cap = usb_msc.capacity() orelse return -6;
        if (cap.block_len != usb_msc.block_len) return -6; // only 512-B sectors
        const src = usb_msc.source();
        const row = fat32_ro.partitionAt(src, parsed.usb_index) catch return -6;
        // A partition that claims sectors the device does not have is not a
        // volume this guest may read from.
        if (@as(u64, row.start_lba) + row.sectors > @as(u64, cap.last_lba) + 1) return -1;
        const vol = fat32_ro.mount(src, row.start_lba, row.sectors) catch |err| switch (err) {
            error.NotFat32, error.BadBpb => return -1,
            else => return -6,
        };
        const subpath = parsed.path[0..parsed.parsed_len()];
        if (subpath.len == 0) return -1; // the volume root is a directory
        var e: fat32_ro.Entry = undefined;
        fat32_ro.lookup(src, vol, subpath, &e) catch |err| switch (err) {
            error.NotFound, error.Io => return -6,
            // A path that goes THROUGH a file is a structural error, not a
            // missing one — `dir_list` answers `-1` for the same shape.
            error.NotDir => return -1,
            else => return -1,
        };
        if (e.isDir()) return -1; // a directory has no byte stream
        handles[pid][slot] = .{
            .in_use = true,
            .partition = .usb_fat,
            .flags = flags,
            .cursor = 0,
            .size = e.size,
            .path = parsed.path,
            .path_len = parsed.path_len,
            .usb_file = fat32_ro.FileReader.init(vol, e),
        };
        return @intCast(slot);
    }

    // M50 TS2 (ADR 0024 D4): the ownership/mode gate, after parse_path and
    // before any virtio_file access. `.usb`/`.usb_fat` were handled above and
    // `.tty` before parse_path; every path here is `.host`.
    if (!hostAllowed(pid, parsed.path[0..parsed.parsed_len()], trustWant(flags))) return -7; // EACCES

    if (!virtio_file.available()) return -6; // ENOENT (no host file channel)

    const subpath = parsed.path[0..parsed.parsed_len()];

    // M34 HF5 (issue #739): the host share is READ-WRITE now — the file
    // channel is user data. MODE_DIR creates a directory (parity with the
    // FAT mkdir path); MODE_WRITE (with optional CREATE/APPEND) opens a
    // host write handle (the HOST owns the cursor; write-open without
    // append truncates to 0 — the legacy FAT replace semantics the
    // persistence consumers were built on); MODE_READ-only stays
    // stateless (vf STAT for the size, vf READ at the guest cursor).
    if ((flags & MODE_DIR) != 0) {
        const md = virtio_file.mkdir(subpath);
        if (md != virtio_file.st_ok) return hf_open_errno(md); // exists → EEXIST, not_found → ENOENT
        handles[pid][slot] = .{
            .in_use = true,
            .partition = .host,
            .flags = flags,
            .path = parsed.path,
            .path_len = parsed.path_len,
            .is_dir = true,
        };
        return @intCast(slot);
    }
    if ((flags & MODE_WRITE) != 0) {
        var oflags: u8 = 0;
        if ((flags & MODE_CREATE) != 0) oflags |= virtio_file.open_flag_create;
        if ((flags & MODE_APPEND) != 0) oflags |= virtio_file.open_flag_append;
        var h: u16 = 0;
        const ost = virtio_file.open(subpath, oflags, &h);
        if (ost != virtio_file.st_ok) return hf_open_errno(ost); // M66a: not_found/is_dir/handle-full stay distinct
        if ((flags & MODE_APPEND) == 0) {
            // Replace semantics: a fresh write-open truncates. A failed
            // truncate is honest (the handle is closed; nothing leaked).
            if (virtio_file.truncate(h, 0) != virtio_file.st_ok) {
                _ = virtio_file.close(h);
                return -1;
            }
        }
        handles[pid][slot] = .{
            .in_use = true,
            .partition = .host,
            .flags = flags,
            .cursor = 0,
            .size = 0,
            .path = parsed.path,
            .path_len = parsed.path_len,
            .is_dir = false,
            .host_handle = h,
            .host_handle_valid = true,
        };
        return @intCast(slot);
    }
    var st = virtio_file.StatResult{};
    if (virtio_file.stat(subpath, &st) != virtio_file.st_ok) return -6; // ENOENT
    if (st.is_dir) return -1; // EINVAL: a directory opens as its own path, not a handle
    handles[pid][slot] = .{
        .in_use = true,
        .partition = .host,
        .flags = flags,
        .cursor = 0,
        // Clamp to u32 (the frozen ABI); host manifests are tiny and
        // the read loop's EOF bound still holds for larger files.
        .size = @intCast(@min(st.size, std.math.maxInt(u32))),
        .path = parsed.path,
        .path_len = parsed.path_len,
        .is_dir = false,
    };
    return @intCast(slot);
}

/// Read from open handle `fd`.
/// Returns bytes read (0 at EOF), or negative error code.
pub fn read(pid: u64, fd: u64, out_buf: []u8) i64 {
    if (pid >= process.max_processes or fd >= max_handles_per_process or handles.len == 0) return -2;
    return read_handle(pid, &handles[pid][fd], out_buf, false);
}

pub fn is_contained(pid: u64, fd: u64) bool {
    return pid < process.max_processes and fd < max_handles_per_process and
        handles.len != 0 and handles[pid][fd].in_use and handles[pid][fd].contained;
}

pub fn contained_peek(pid: u64, fd: u64, out: []u8) i64 {
    var h = handles[pid][fd];
    return read_handle(pid, &h, out, true);
}

pub fn contained_advance(pid: u64, fd: u64, count: usize) void {
    handles[pid][fd].contained_cursor += count;
}

fn read_handle(pid: u64, h: *FileHandle, out_buf: []u8, strict: bool) i64 {
    if (!h.in_use) return -2; // EBADF
    if ((h.flags & MODE_READ) == 0) return -7; // EACCES
    if (h.dir_token != 0) return -2;
    if (h.is_dir) return 0; // M25 Lane B: a dir handle reads as empty

    // #1072 (ADR 0020): a `.tty` handle drains the terminal's input queue
    // (front-end keys). Empty input returns 0 — a non-blocking read. The
    // serial front-end is pumped first so freshly-typed keys are visible.
    if (h.partition == .tty) {
        const t = terminal.get(h.term_handle) orelse return -2;
        _ = terminal.pumpRuntimeInput();
        // SH7 (#1083): a net-bound terminal's input comes from the TCP seam.
        _ = terminal.pumpNetInput();
        return @intCast(t.readInput(out_buf));
    }

    // M50 TS2 (ADR 0024 D4): the host-share ownership/mode gate for reads.
    if (h.partition == .host and !hostAllowed(pid, h.path[0..h.path_len], .read)) return -7; // EACCES

    if (h.contained) {
        var auth = MetadataAuth{ .pid = pid, .root = "" };
        MetadataAuth.check(&auth, h.path[0..h.path_len], .read) catch |err| return metadata_errno(err);
        const n = virtio_file.contained_read(h.host_handle, h.contained_cursor, out_buf) catch |err| return metadata_errno(err);
        h.contained_cursor += n;
        return @intCast(n);
    }
    if (out_buf.len == 0) return 0;
    if (h.cursor >= h.size) return 0; // EOF

    // M43 U3 (issue #1034): `.usb` reads are sequential 512-byte SCSI
    // sectors at the byte cursor. A multi-sector request loops; a partial
    // first/last sector is served from the sector scratch. A failed BOT
    // transfer stops the read honestly (bytes so far, 0 on the first).
    if (h.partition == .usb) {
        var total: usize = 0;
        while (total < out_buf.len and h.cursor < h.size) {
            const lba: u32 = h.cursor / @as(u32, usb_msc.block_len);
            const off: usize = h.cursor % usb_msc.block_len;
            const r = usb_msc.read_sector(lba, &usb_sector);
            if (!r.ok) break;
            const n = @min(usb_msc.block_len - off, out_buf.len - total);
            @memcpy(out_buf[total..][0..n], usb_sector[off..][0..n]);
            total += n;
            h.cursor += @intCast(n);
        }
        return @intCast(total);
    }

    // M70f F1 (issue #1458): `.usb_fat` reads walk the FAT chain from the
    // handle's own reader state (geometry + position + bytes remaining). A
    // broken chain stops the read at the last byte the disk actually held
    // (`usb_file.broken`); it never pads, repeats or invents content.
    if (h.partition == .usb_fat) {
        const src = usb_msc.source();
        const n = fat32_ro.readFile(src, &h.usb_file, out_buf, &usb_fat_sector);
        h.cursor += @intCast(n);
        return @intCast(n);
    }

    if (!virtio_file.available()) return -6;

    // M34 HF4: the host share is stateless — each chunk is one vf READ
    // round trip at the handle's cursor (a handle is path + size here).
    // Issue #846: read_chunk copies directly into out_buf under vf_lock,
    // eliminating reply-buffer races across concurrent tasks and cores.
    const subpath = h.path[0..h.path_len];
    var total: usize = 0;
    while (total < out_buf.len and h.cursor < h.size) {
        const take = @min(out_buf.len - total, h.size - h.cursor);
        const rc = virtio_file.read_chunk(subpath, h.cursor, out_buf[total..][0..take]);
        if (rc.status != virtio_file.st_ok or rc.bytes == 0) {
            if (strict and total == 0) return if (rc.status == virtio_file.st_not_found) -6 else -1;
            break;
        }
        if (rc.bytes > out_buf.len - total or rc.bytes > h.size - h.cursor) return if (total == 0) -1 else @intCast(total);
        total += rc.bytes;
        h.cursor += @intCast(rc.bytes);
    }
    return @intCast(total);
}

/// Write to open handle `fd`.
/// Returns bytes written, or negative error code.
pub fn write(pid: u64, fd: u64, in_buf: []const u8) i64 {
    if (pid >= process.max_processes or fd >= max_handles_per_process or handles.len == 0) return -2;
    return write_handle(pid, &handles[pid][fd], in_buf);
}

fn write_handle(pid: u64, h: *FileHandle, in_buf: []const u8) i64 {
    if (!h.in_use) return -2; // EBADF
    if ((h.flags & MODE_WRITE) == 0) return -7; // EACCES
    if (h.dir_token != 0) return -2;
    if (h.is_dir) return -7; // M25 Lane B: never write through a dir handle

    // #1072 (ADR 0020): a `.tty` handle appends to the terminal's output
    // ring; the pump immediately drains it to the serial front-end. #1082
    // (Amendment A): a WINDOW-bound terminal drains into its presentation
    // grid and marks the bound `.user` window damaged instead. #1630
    // (M73f-1): the window path streams write→grid in ring-sized chunks so
    // a single write larger than the 4 KiB ring cannot drop; serial/net
    // keep the drop-oldest ring policy.
    if (h.partition == .tty) {
        const t = terminal.get(h.term_handle) orelse return -2;
        if (t.front_end == .net) {
            const n = t.write(in_buf);
            // SH7 (#1083, Amendment B): drain the ring into TCP segments.
            _ = terminal.pumpNetOutput();
            return @intCast(n);
        } else if (t.window_id) |wid| {
            const n = terminal.writeWindow(h.term_handle, in_buf);
            if (n > 0) {
                _ = driving_award.user_present(wid);
            }
            return @intCast(n);
        } else {
            const n = t.write(in_buf);
            _ = terminal.pumpRuntimeOutput();
            return @intCast(n);
        }
    }

    // M50 TS2 (ADR 0024 D4): the host-share ownership/mode gate for writes.
    if (h.partition == .host and !hostAllowed(pid, h.path[0..h.path_len], .write)) return -7; // EACCES
    if (h.contained) {
        var auth = MetadataAuth{ .pid = pid, .root = "" };
        MetadataAuth.check(&auth, h.path[0..h.path_len], .write) catch |err| return metadata_errno(err);
    }

    // M34 HF5 (issue #739): host writes ride the host handle's cursor
    // (chunked across WRITE round trips; the host returns the confirmed
    // count, which is what advances our mirror cursor).
    if (!h.host_handle_valid) return -7; // EACCES (no write handle)
    if (in_buf.len == 0) return 0;
    if (in_buf.len > std.math.maxInt(u32) - h.cursor) return -5;
    var off: usize = 0;
    while (off < in_buf.len) {
        const take = @min(in_buf.len - off, virtio_file.write_chunk_limit());
        var written: u64 = 0;
        const st = if (h.contained)
            virtio_file.contained_write(h.host_handle, in_buf[off .. off + take], &written)
        else if (builtin.is_test and test_stream_write != null)
            test_stream_write.?(h.host_handle, in_buf[off .. off + take], &written)
        else
            virtio_file.write(h.host_handle, in_buf[off .. off + take], &written);
        if (st != virtio_file.st_ok or written == 0) {
            // Honest accounting (M66a): the guest mirror advances by the
            // host-CONFIRMED count only, so a mid-stream failure reports the
            // confirmed prefix — a short write, never a corrupt stream — and
            // a first-chunk failure maps the HF status (a dead host handle is
            // EBADF). A confirmed zero with ok status can never advance the
            // stream; stop instead of spinning.
            if (off > 0) return @intCast(off);
            return if (st == virtio_file.st_ok) -1 else hf_handle_errno(st);
        }
        if (written > take) return if (off == 0) -1 else @intCast(off);
        off += @intCast(written);
        h.cursor += @intCast(written);
        h.size = @max(h.size, h.cursor);
    }
    h.size = @max(h.size, h.cursor);
    return @intCast(in_buf.len);
}

/// Close open handle `fd`.
/// Returns 0 on success, or -2 (`EBADF`). A host write handle is closed
/// on the HOST (flush + free the table slot) before the guest slot frees.
pub fn close(pid: u64, fd: u64) i64 {
    if (pid >= process.max_processes or fd >= max_handles_per_process or handles.len == 0) return -2;
    if (!handles[pid][fd].in_use) return -2; // EBADF
    if (handles[pid][fd].pin) return -2; // a pin token is not an fd (op 9)
    if (handles[pid][fd].dir_token != 0) release_snapshot(handles[pid][fd].dir_snapshot);

    if (handles[pid][fd].host_handle_valid) {
        if (handles[pid][fd].contained) {
            virtio_file.contained_close(handles[pid][fd].host_handle) catch |err| return metadata_errno(err);
        } else {
            _ = virtio_file.close(handles[pid][fd].host_handle);
        }
    }
    handles[pid][fd] = .{};
    release_empty_handles();
    return 0;
}

fn resource_count(pid: u64) usize {
    var count: usize = 0;
    if (handles.len != 0) for (handles[pid]) |h| {
        if (h.in_use) count += 1;
    };
    for (streams[pid]) |binding| {
        if (binding == .file) count += 1;
    }
    return count;
}

/// Slot 27 v2: capture a complete immutable directory, reserving one of
/// the process's eight native resources. USB is explicitly unsupported.
pub fn dir_open(pid: u64, path_bytes: []const u8) i64 {
    if (pid >= process.max_processes) return -1;
    if (path_bytes.len > max_path_len) return -8;
    const parsed = parse_path(if (path_bytes.len == 0) "/host" else path_bytes) orelse return -8;
    if (parsed.partition != .host) return -4;
    const path = parsed.path[0..parsed.path_len];
    if (!directory.valid_path(path, directory.depth_max)) return -8;
    if (!hostAllowed(pid, path, .list)) return -7;
    if (!ensure_handles()) return -10;
    defer release_empty_handles();
    if (resource_count(pid) >= max_handles_per_process) return -5;
    var fd: usize = 0;
    while (fd < max_handles_per_process and handles[pid][fd].in_use) : (fd += 1) {}
    if (fd == max_handles_per_process) return -5;
    var slot: usize = 0;
    while (slot < snapshot_used.len and snapshot_used[slot]) : (slot += 1) {}
    if (slot == snapshot_used.len or next_dir_token > std.math.maxInt(i64)) return -5;
    const snapshot = allocate_snapshot(slot) orelse return -10; // ENOMEM, not cursor exhaustion
    snapshots[slot] = snapshot;
    const status = virtio_file.snapshot(path, snapshot);
    if (status != virtio_file.st_ok) {
        release_snapshot(slot);
        return switch (status) {
            virtio_file.st_limit, virtio_file.st_handle => -5,
            virtio_file.st_path_limit => -8,
            else => hf_open_errno(status),
        };
    }
    const token = next_dir_token;
    next_dir_token += 1;
    handles[pid][fd] = .{
        .in_use = true,
        .is_dir = true,
        .dir_token = token,
        .dir_snapshot = slot,
        .path = parsed.path,
        .path_len = parsed.path_len,
    };
    snapshot_used[slot] = true;
    return @intCast(token);
}

fn dir_handle(pid: u64, token: u64) ?*FileHandle {
    if (pid >= process.max_processes or token == 0 or handles.len == 0) return null;
    for (&handles[pid]) |*h| {
        if (h.in_use and h.dir_token == token) return h;
    }
    return null;
}

/// Indexed pages make retries after EFAULT lossless; `next` is the actual
/// continuation offset. Zero rows + end=1 is EOF, never an I/O refusal.
pub fn dir_page(pid: u64, token: u64, offset: u64, limit: u64, page: *directory.Page) i64 {
    const h = dir_handle(pid, token) orelse return -2;
    if (h.rich_directory or h.pin) return -2;
    if (!hostAllowed(pid, h.path[0..h.path_len], .list)) return -7;
    if (limit == 0 or limit > directory.page_max) return -1;
    const snapshot = snapshots[h.dir_snapshot].?;
    if (offset > snapshot.count) return -1;
    const take: usize = @intCast(@min(limit, snapshot.count - offset));
    page.header = .{
        .count = @intCast(take),
        .next = offset + take,
        .end = @intFromBool(offset + take == snapshot.count),
    };
    @memcpy(page.entries[0..take], snapshot.entries[@intCast(offset)..][0..take]);
    return @intCast(take);
}

pub fn dir_close(pid: u64, token: u64) i64 {
    const h = dir_handle(pid, token) orelse return -2;
    if (h.pin) return -2; // pins close through op 9 only
    release_snapshot(h.dir_snapshot);
    h.* = .{};
    release_empty_handles();
    return 0;
}

/// Enumerate directory entries at `path_bytes` into `out_entries`.
/// Returns number of entries written (>= 0), or negative error code.
pub fn dir_list(pid: u64, path_bytes: []const u8, out_entries: []DirEntry) i64 {
    if (pid >= process.max_processes) return -1;
    if (out_entries.len == 0) return 0;

    const parsed = if (path_bytes.len == 0)
        ParsedPath{ .partition = .host, .path = @as([max_path_len]u8, @splat(@as(u8, 0))), .path_len = 0 }
    else
        parse_path(path_bytes) orelse return -1;

    // M50 TS2 (ADR 0024 D4): the host-share ownership/mode gate for listing.
    if (parsed.partition == .host and !hostAllowed(pid, parsed.path[0..parsed.path_len], .list)) return -7; // EACCES

    // M70f F1 (issue #1458): listing a `.usb_fat` path reads the FAT32
    // directory chain, one sector at a time, straight into the caller's rows.
    // Names longer than the frozen 40-byte `DirEntry` row's 31 bytes are
    // truncated here (`usb ls` prints them whole); a file path is EINVAL,
    // an absent one ENOENT.
    if (parsed.partition == .usb_fat) {
        const cap = usb_msc.capacity() orelse return -6;
        if (cap.block_len != usb_msc.block_len) return -6;
        const src = usb_msc.source();
        const row = fat32_ro.partitionAt(src, parsed.usb_index) catch return -6;
        // The same end-of-device guard `open` applies: a partition table may
        // not send this guest past the disk it was handed.
        if (@as(u64, row.start_lba) + row.sectors > @as(u64, cap.last_lba) + 1) return -1;
        const vol = fat32_ro.mount(src, row.start_lba, row.sectors) catch |err| switch (err) {
            error.NotFat32, error.BadBpb => return -1,
            else => return -6,
        };
        var dir: fat32_ro.Entry = undefined;
        fat32_ro.lookup(src, vol, parsed.path[0..parsed.parsed_len()], &dir) catch |err| switch (err) {
            error.NotFound, error.Io => return -6,
            error.NotDir => return -1,
            else => return -1,
        };
        if (!dir.isDir()) return -1;
        var iter = fat32_ro.dirIter(src, vol, dir.first_cluster);
        var n: usize = 0;
        while (true) {
            if (n >= out_entries.len) break;
            const e = iter.next() orelse break;
            var de = DirEntry{
                .name = @as([32]u8, @splat(@as(u8, 0))),
                .size = e.size,
                .is_dir = if (e.isDir()) 1 else 0,
                .reserved = .{ 0, 0, 0 },
            };
            const nlen = @min(e.name_len, 31);
            @memcpy(de.name[0..nlen], e.name[0..nlen]);
            out_entries[n] = de;
            n += 1;
        }
        return @intCast(n);
    }

    if (!virtio_file.available()) return -6;

    const subpath = parsed.path[0..parsed.path_len];

    // M34 HF4: LIST the share through the file channel; the vf row shape
    // (name / size / is_dir) maps 1:1 onto the frozen 40-byte DirEntry.
    var lr = virtio_file.ListResult{};
    if (virtio_file.list(subpath, &lr) != virtio_file.st_ok) return -6;
    const take = @min(lr.count, out_entries.len);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        const raw = &lr.entries[i];
        var de = DirEntry{
            .name = @as([32]u8, @splat(@as(u8, 0))),
            .size = @intCast(@min(raw.size, std.math.maxInt(u32))),
            .is_dir = if (raw.type == virtio_file.dir_type_dir) 1 else 0,
            .reserved = .{ 0, 0, 0 },
        };
        const nlen = @min(raw.name_len, 31);
        @memcpy(de.name[0..nlen], raw.name[0..nlen]);
        out_entries[i] = de;
    }
    return @intCast(take);
}

// ---------------------------------------------------------------------------
// Mutating operations (Milestone 13, card B1 — claim 5801)
// ---------------------------------------------------------------------------

/// Delete the file at `path`. Returns 0 on success, or a negative error
/// code (EINVAL bad path / directory, ENOENT absent / unmounted).
pub fn delete(pid: u64, path_bytes: []const u8) i64 {
    if (pid >= process.max_processes) return -1;
    if (path_bytes.len == 0 or path_bytes.len > max_path_len) return -1;
    const parsed = parse_path(path_bytes) orelse return -1;
    // M70f F1 (issue #1458): only the host share is mutable through this
    // table. A device path (`.usb`, `.usb_fat`, `.tty`) is refused by name —
    // without this guard the subpath would be handed to the host channel,
    // i.e. `rm usb1/x` would have acted on the share's `x`.
    if (parsed.partition != .host) return -1;
    // M50 TS2 (ADR 0024 D4/D8): the ownership/mode gate — a secret-class
    // path is denied delete through the file ABI for every actor. Only the
    // `.host` table is keyed by paths; `.usb`/`.tty` are not mode-governed.
    if (!hostAllowed(pid, parsed.path[0..parsed.parsed_len()], .delete)) return -7; // EACCES
    if (!virtio_file.available()) return -6;
    const subpath = parsed.path[0..parsed.parsed_len()];
    // M34 HF5 (issue #739): host deletes route to the channel. M66a: the
    // host's refusal (a non-empty directory is host status 4, never a
    // missing path) is EINVAL, not ENOENT — the channel was there and
    // said no.
    const rc: i64 = switch (virtio_file.delete(subpath)) {
        virtio_file.st_ok => 0,
        virtio_file.st_not_found => -6,
        else => -1,
    };
    // M50 TS2: drop the metadata in the same transaction (persist on change).
    if (rc == 0) invalidate_pins(subpath);
    if (rc == 0 and trust.remove(.host, subpath)) _ = persist_trust();
    return rc;
}

pub const RenameMode = virtio_file.RenameMode;

/// Rename within the host share, refusing an existing destination.
pub fn rename(pid: u64, old_bytes: []const u8, new_bytes: []const u8) i64 {
    return rename_mode(pid, old_bytes, new_bytes, .preserve_existing);
}

/// Replacement and preserve-existing use the same both-end authorization.
/// Backend rejection preserves the publication; only acknowledged success
/// moves trust metadata. A lost transport reply has an unknown commit outcome.
pub fn rename_mode(pid: u64, old_bytes: []const u8, new_bytes: []const u8, mode: RenameMode) i64 {
    if (pid >= process.max_processes) return -1;
    if (old_bytes.len == 0 or old_bytes.len > max_path_len or
        new_bytes.len == 0 or new_bytes.len > max_path_len) return -1;
    const old = parse_path(old_bytes) orelse return -1;
    const new = parse_path(new_bytes) orelse return -1;
    if (old.partition != new.partition) return -1; // cross-partition unsupported
    if (old.partition != .host) return -1; // M70f F1: devices are read-only
    const oldp = old.path[0..old.parsed_len()];
    const newp = new.path[0..new.parsed_len()];
    // M50 TS2 (ADR 0024 D4/D8): the ownership/mode gate on BOTH ends — a
    // secret-class path is denied rename for every actor, so the class can
    // never be stripped by a guest rename.
    if (old.partition == .host) {
        if (!hostAllowed(pid, oldp, .delete)) return -7; // EACCES
        if (!hostAllowed(pid, newp, .create)) return -7; // EACCES
    }
    if (!virtio_file.available()) return -6;
    const status = if (mode == .replace) virtio_file.replace(oldp, newp) else virtio_file.rename(oldp, newp);
    const rc: i64 = switch (status) {
        virtio_file.st_ok => 0,
        virtio_file.st_not_found => -6,
        virtio_file.st_exists => -9,
        virtio_file.st_access => -7,
        virtio_file.st_unsupported => -4,
        else => -1,
    };
    if (rc == 0) {
        invalidate_pins(oldp);
        invalidate_pins(newp);
    }
    // M50 TS2: move the metadata with the file (persist on change).
    if (rc == 0 and old.partition == .host and trust.rename_meta(.host, oldp, .host, newp)) _ = persist_trust();
    return rc;
}

/// Resize the OPEN handle `fd` to `new_size` bytes (shrink truncates, grow
/// zero-fills). Returns 0; EBADF for a bad/closed handle, EACCES when not
/// open for write.
pub fn truncate(pid: u64, fd: u64, new_size: u32) i64 {
    if (pid >= process.max_processes or fd >= max_handles_per_process or handles.len == 0) return -2;
    var h = &handles[pid][fd];
    if (!h.in_use) return -2; // EBADF
    if ((h.flags & MODE_WRITE) == 0) return -7; // EACCES
    if (h.dir_token != 0) return -2;
    if (h.is_dir) return -7; // M25 Lane B: never truncate through a dir handle
    // M50 TS2 (ADR 0024 D4): the host-share ownership/mode gate for resize.
    if (h.partition == .host and !hostAllowed(pid, h.path[0..h.path_len], .write)) return -7; // EACCES
    // M34 HF5 (issue #739): host truncate rides the host handle. M66a: the
    // status maps honestly (a dead host handle is EBADF); the host clamps
    // its own cursor to the new size, mirrored below.
    if (!h.host_handle_valid) return -7; // EACCES
    if (h.contained) {
        var auth = MetadataAuth{ .pid = pid, .root = "" };
        MetadataAuth.check(&auth, h.path[0..h.path_len], .write) catch |err| return metadata_errno(err);
    }
    const st = if (h.contained) virtio_file.contained_truncate(h.host_handle, new_size) else virtio_file.truncate(h.host_handle, new_size);
    if (st != virtio_file.st_ok) return hf_handle_errno(st);
    h.size = new_size;
    if (h.cursor > new_size) h.cursor = new_size;
    return 0;
}

/// M66a (#1443): FSYNC the handle's host side (slot 77 — ADR 0007
/// amendment; the HF op calls synchronize() on the host's live fd, so the
/// bytes are durable before the app trusts them). A `.host` write handle
/// syncs through the channel; handles with no host-side dirty state
/// (stateless read handles, read-only `.usb`, `.tty`) are honest no-ops.
pub fn sync(pid: u64, fd: u64) i64 {
    if (pid >= process.max_processes or fd >= max_handles_per_process or handles.len == 0) return -2;
    const h = &handles[pid][fd];
    if (!h.in_use) return -2; // EBADF
    if (h.dir_token != 0) return -2;
    if (h.partition != .host) return 0; // no host-side state to push
    if (!h.host_handle_valid) return 0; // stateless read handle: nothing to sync
    if (h.contained) {
        var auth = MetadataAuth{ .pid = pid, .root = "" };
        MetadataAuth.check(&auth, h.path[0..h.path_len], if ((h.flags & MODE_WRITE) != 0) .write else .read) catch |err| return metadata_errno(err);
        return hf_handle_errno(virtio_file.contained_sync(h.host_handle));
    }
    return hf_handle_errno(virtio_file.fsync(h.host_handle));
}

/// Free bytes on a volume. M34 HF6 (issue #740): the ESP/DATA partitions
/// are GONE and the host channel has no free-space op — every volume is
/// an honest EINVAL (the frozen ABI row stays; no userland caller exists
/// since `fstest` was deleted).
pub fn free_space(pid: u64, volume: u32) i64 {
    _ = volume;
    if (pid >= process.max_processes) return -1;
    return -1; // EINVAL: no file volumes exist
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "B1: redirected input reaches real EOF and never reads unrelated input" {
    init();
    var content: [128 * 1024]u8 = undefined;
    for (&content, 0..) |*b, i| b.* = @intCast(i % 251);
    const files = [_]virtio_file.TestFile{
        .{ .name = "INPUT", .data = &content },
        .{ .name = "OTHER", .data = "unrelated" },
    };
    virtio_file.set_test_share(&files);
    defer virtio_file.set_test_share(null);
    const fd = open(0, "INPUT", MODE_READ);
    try std.testing.expectEqual(@as(i64, 0), fd);
    var plan: StreamPlan = .{};
    try std.testing.expectEqual(@as(i64, 0), prepare_streams(0, .{ .sources = .{ @intCast(fd), stream_inherit, stream_inherit } }, &plan));
    commit_streams(1, &plan);
    try std.testing.expectEqual(@as(i64, -2), read(0, @intCast(fd), content[0..1]));
    try std.testing.expectEqual(@as(i64, -2), stream_read(0, stream_base, content[0..1]));
    var buf: [3001]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = stream_read(1, stream_base, &buf);
        try std.testing.expect(n >= 0);
        if (n == 0) break;
        const count: usize = @intCast(n);
        try std.testing.expectEqualSlices(u8, content[total..][0..count], buf[0..count]);
        total += count;
    }
    try std.testing.expectEqual(content.len, total);
    try std.testing.expectEqual(@as(i64, 0), stream_read(1, stream_base, &buf));
    try std.testing.expectEqual(@as(i64, -7), stream_read(1, stream_base + 1, &buf));
    try std.testing.expectEqual(@as(i64, -7), stream_write(1, stream_base, "x"));
    try std.testing.expectEqual(@as(i64, 0), stream_close(1, stream_base));
    try std.testing.expectEqual(@as(i64, -2), stream_close(1, stream_base));
    try std.testing.expectEqual(@as(i64, -2), stream_read(1, stream_base, &buf));
    reset_process(1);
}

test "B1: inherited cursors survive parent closure death and pid reuse" {
    init();
    const files = [_]virtio_file.TestFile{.{ .name = "INPUT", .data = "abcdef" }};
    virtio_file.set_test_share(&files);
    defer virtio_file.set_test_share(null);
    const fd = open(0, "INPUT", MODE_READ);
    var first: StreamPlan = .{};
    try std.testing.expectEqual(@as(i64, 0), prepare_streams(0, .{ .sources = .{ @intCast(fd), stream_closed, stream_closed } }, &first));
    commit_streams(1, &first);
    var child: StreamPlan = .{};
    try std.testing.expectEqual(@as(i64, 0), prepare_streams(1, .{}, &child));
    commit_streams(2, &child);
    var buf: [3]u8 = undefined;
    try std.testing.expectEqual(@as(i64, 3), stream_read(1, stream_base, &buf));
    try std.testing.expectEqualStrings("abc", &buf);
    try std.testing.expectEqual(@as(i64, 0), stream_close(1, stream_base));
    reset_process(1);
    try std.testing.expectEqual(@as(i64, -2), stream_read(1, stream_base, &buf));
    try std.testing.expectEqual(@as(i64, 3), stream_read(2, stream_base, &buf));
    try std.testing.expectEqualStrings("def", &buf);
    try std.testing.expectEqual(@as(i64, 0), stream_read(2, stream_base, &buf));
    reset_process(2);
    for (endpoints) |ep| try std.testing.expectEqual(@as(usize, 0), ep.refs);
}

test "B1: two process inputs are isolated and peek does not consume on copy refusal" {
    init();
    const files = [_]virtio_file.TestFile{
        .{ .name = "ONE", .data = "one" },
        .{ .name = "TWO", .data = "two" },
    };
    virtio_file.set_test_share(&files);
    defer virtio_file.set_test_share(null);
    for ([_][]const u8{ "ONE", "TWO" }, 1..) |name, pid| {
        const fd = open(0, name, MODE_READ);
        var plan: StreamPlan = .{};
        try std.testing.expectEqual(@as(i64, 0), prepare_streams(0, .{ .sources = .{ @intCast(fd), stream_closed, stream_closed } }, &plan));
        commit_streams(pid, &plan);
    }
    var buf: [3]u8 = undefined;
    try std.testing.expectEqual(@as(i64, 3), stream_peek(1, stream_base, &buf));
    try std.testing.expectEqual(@as(i64, 3), stream_peek(1, stream_base, &buf));
    try std.testing.expectEqualStrings("one", &buf);
    try std.testing.expectEqual(@as(i64, 3), stream_read(2, stream_base, &buf));
    try std.testing.expectEqualStrings("two", &buf);
    stream_advance(1, stream_base, 3);
    try std.testing.expectEqual(@as(i64, 0), stream_read(1, stream_base, &buf));
    reset_process(1);
    reset_process(2);
}

test "B1: missing truncated or disconnected input is not fabricated EOF" {
    init();
    const files = [_]virtio_file.TestFile{.{ .name = "INPUT", .data = "abc" }};
    virtio_file.set_test_share(&files);
    defer virtio_file.set_test_share(null);
    const fd = open(0, "INPUT", MODE_READ);
    var plan: StreamPlan = .{};
    try std.testing.expectEqual(@as(i64, 0), prepare_streams(0, .{ .sources = .{ @intCast(fd), stream_closed, stream_closed } }, &plan));
    commit_streams(1, &plan);
    var buf: [3]u8 = undefined;
    const truncated = [_]virtio_file.TestFile{.{ .name = "INPUT", .data = "" }};
    virtio_file.set_test_share(&truncated);
    try std.testing.expectEqual(@as(i64, -1), stream_read(1, stream_base, &buf));
    virtio_file.set_test_share(&.{});
    try std.testing.expectEqual(@as(i64, -6), stream_read(1, stream_base, &buf));
    virtio_file.set_test_share(null);
    try std.testing.expectEqual(@as(i64, -6), stream_read(1, stream_base, &buf));
    reset_process(1);
}

test "B1: invalid spawn requests and cancelled reservations preserve parent ownership" {
    init();
    handles[0][0] = .{ .in_use = true, .flags = MODE_READ };
    handles[0][1] = .{ .in_use = true, .flags = MODE_WRITE };
    handles[0][2] = .{ .in_use = true, .flags = MODE_WRITE, .partition = .tty };
    var plan: StreamPlan = .{};
    try std.testing.expectEqual(@as(i64, -1), prepare_streams(0, .{ .version = 2 }, &plan));
    try std.testing.expectEqual(@as(i64, -1), prepare_streams(0, .{ .reserved = 1 }, &plan));
    try std.testing.expectEqual(@as(i64, -7), prepare_streams(0, .{ .sources = .{ stream_console, stream_closed, stream_closed } }, &plan));
    try std.testing.expectEqual(@as(i64, -2), prepare_streams(0, .{ .sources = .{ 7, stream_closed, stream_closed } }, &plan));
    try std.testing.expectEqual(@as(i64, -7), prepare_streams(0, .{ .sources = .{ 1, stream_closed, stream_closed } }, &plan));
    try std.testing.expectEqual(@as(i64, -1), prepare_streams(0, .{ .sources = .{ 0, 1, 1 } }, &plan));
    try std.testing.expectEqual(@as(i64, -1), prepare_streams(0, .{ .sources = .{ 0, 2, stream_closed } }, &plan));
    handles[0][0].is_dir = true;
    try std.testing.expectEqual(@as(i64, -1), prepare_streams(0, .{ .sources = .{ 0, stream_closed, stream_closed } }, &plan));
    handles[0][0].is_dir = false;
    try std.testing.expectEqual(@as(i64, 0), prepare_streams(0, .{ .sources = .{ 0, 1, stream_closed } }, &plan));
    cancel_streams(&plan);
    cancel_streams(&plan);
    try std.testing.expect(handles[0][0].in_use and handles[0][1].in_use);
    for (endpoints) |ep| try std.testing.expectEqual(@as(usize, 0), ep.refs);
    reset_process(0);
}

test "B1: endpoint exhaustion rolls back and native resources remain bounded at eight" {
    init();
    handles[0][0] = .{ .in_use = true, .flags = MODE_READ };
    handles[0][1] = .{ .in_use = true, .flags = MODE_WRITE };
    for (endpoints[1..], 1..) |_, idx| endpoints[idx].refs = 1;
    var plan: StreamPlan = .{};
    try std.testing.expectEqual(@as(i64, -5), prepare_streams(0, .{ .sources = .{ 0, 1, stream_closed } }, &plan));
    try std.testing.expect(handles[0][0].in_use and handles[0][1].in_use);
    try std.testing.expectEqual(@as(usize, 0), endpoints[0].refs);
    for (endpoints) |*ep| ep.* = .{};
    try std.testing.expectEqual(@as(i64, 0), prepare_streams(0, .{ .sources = .{ 0, stream_closed, stream_closed } }, &plan));
    commit_streams(1, &plan);
    for (handles[1][0..7], 0..) |_, idx| handles[1][idx] = .{ .in_use = true, .flags = MODE_READ };
    try std.testing.expectEqual(@as(i64, -5), open(1, "OTHER", MODE_READ));
    try std.testing.expectEqual(@as(i64, 0), stream_close(1, stream_base));
    try std.testing.expectEqual(@as(i64, -6), open(1, "OTHER", MODE_READ)); // room, no backend
    reset_process(0);
    reset_process(1);
}

var stream_test_bytes: [2][8192]u8 = undefined;
var stream_test_counts: [2]usize = .{ 0, 0 };
var stream_test_fail_at: usize = std.math.maxInt(usize);
var stream_test_zero = false;
var stream_test_over = false;
var stream_test_closes: usize = 0;
var stream_test_close_fail = false;

fn stream_test_writer(handle: u16, bytes: []const u8, written: *u64) u8 {
    const idx: usize = handle - 10;
    if (stream_test_counts[idx] >= stream_test_fail_at) return virtio_file.st_handle;
    const n = if (stream_test_zero) 0 else @min(bytes.len, 17);
    @memcpy(stream_test_bytes[idx][stream_test_counts[idx]..][0..n], bytes[0..n]);
    stream_test_counts[idx] += n;
    written.* = if (stream_test_over) bytes.len + 1 else n;
    return virtio_file.st_ok;
}

fn stream_test_closer(_: u16) u8 {
    if (stream_test_close_fail) return virtio_file.st_host_error;
    stream_test_closes += 1;
    return virtio_file.st_ok;
}

test "B1: distinct output destinations confirm short writes errors zero progress and final close" {
    init();
    test_stream_write = stream_test_writer;
    test_stream_close = stream_test_closer;
    defer {
        reset_process(1);
        reset_process(2);
        test_stream_write = null;
        test_stream_close = null;
    }
    stream_test_counts = .{ 0, 0 };
    stream_test_fail_at = std.math.maxInt(usize);
    stream_test_zero = false;
    stream_test_over = false;
    stream_test_close_fail = false;
    stream_test_closes = 0;
    for (0..2) |idx| handles[0][idx] = .{ .in_use = true, .flags = MODE_WRITE, .host_handle_valid = true, .host_handle = @intCast(10 + idx) };
    var plan: StreamPlan = .{};
    try std.testing.expectEqual(@as(i64, 0), prepare_streams(0, .{ .sources = .{ stream_closed, 0, 1 } }, &plan));
    commit_streams(1, &plan);
    var html: [6001]u8 = undefined;
    @memset(&html, 'H');
    try std.testing.expectEqual(@as(i64, html.len), stream_write(1, stream_base + 1, &html));
    try std.testing.expectEqual(@as(i64, 10), stream_write(1, stream_base + 2, "{\"err\":1}\n"));
    try std.testing.expectEqualSlices(u8, &html, stream_test_bytes[0][0..stream_test_counts[0]]);
    try std.testing.expectEqualStrings("{\"err\":1}\n", stream_test_bytes[1][0..stream_test_counts[1]]);
    stream_test_fail_at = stream_test_counts[0] + 17;
    try std.testing.expectEqual(@as(i64, 17), stream_write(1, stream_base + 1, "123456789012345678901234567890"));
    try std.testing.expectEqual(@as(i64, -2), stream_write(1, stream_base + 1, "next"));
    stream_test_fail_at = std.math.maxInt(usize);
    stream_test_zero = true;
    try std.testing.expectEqual(@as(i64, -1), stream_write(1, stream_base + 1, "next"));
    stream_test_zero = false;
    stream_test_over = true;
    try std.testing.expectEqual(@as(i64, -1), stream_write(1, stream_base + 1, "next"));
    stream_test_over = false;
    var child: StreamPlan = .{};
    try std.testing.expectEqual(@as(i64, 0), prepare_streams(1, .{}, &child));
    commit_streams(2, &child);
    try std.testing.expectEqual(@as(i64, 0), stream_close(1, stream_base + 1));
    try std.testing.expectEqual(@as(usize, 0), stream_test_closes);
    reset_process(1);
    try std.testing.expectEqual(@as(usize, 0), stream_test_closes);
    stream_test_close_fail = true;
    try std.testing.expectEqual(@as(i64, -1), stream_close(2, stream_base + 1));
    stream_test_close_fail = false;
    try std.testing.expectEqual(@as(i64, 0), stream_close(2, stream_base + 1));
    reset_process(2);
    try std.testing.expectEqual(@as(usize, 2), stream_test_closes);
    for (endpoints) |ep| try std.testing.expectEqual(@as(usize, 0), ep.refs);
}

test "B2: complete pages, long names, stable mutation snapshot and EOF" {
    init();
    trust.init();
    var files: [40]virtio_file.TestFile = undefined;
    var names: [38][16]u8 = undefined;
    for (files[0..38], 0..) |*f, i| {
        f.* = .{ .name = try std.fmt.bufPrint(&names[i], "entry-{d:0>2}", .{i}), .data = "data" };
    }
    const prefix = "abcdefghijklmnopqrstuvwxyzABCDE";
    files[38] = .{ .name = prefix ++ "-one", .data = "one" };
    files[39] = .{ .name = prefix ++ "-two", .data = "two" };
    virtio_file.set_test_share(&files);
    defer virtio_file.set_test_share(null);
    const token: u64 = @intCast(dir_open(0, "/host"));
    // Changing the backing share after capture does not change its pages.
    virtio_file.set_test_share(&.{});
    var page: directory.Page = undefined;
    var offset: u64 = 0;
    var seen: usize = 0;
    var last: [256]u8 = @splat(0);
    var last_len: usize = 0;
    while (true) {
        const count = dir_page(0, token, offset, 7, &page);
        try std.testing.expect(count >= 0);
        try std.testing.expectEqual(offset + @as(u64, @intCast(count)), page.header.next);
        for (page.entries[0..@intCast(count)]) |entry| {
            const name = entry.name[0..entry.name_len];
            if (seen > 0) try std.testing.expect(std.mem.order(u8, last[0..last_len], name) == .lt);
            @memcpy(last[0..name.len], name);
            last_len = name.len;
            if (seen == 0) try std.testing.expectEqualStrings(prefix ++ "-one", name);
            if (seen == 1) try std.testing.expectEqualStrings(prefix ++ "-two", name);
            seen += 1;
        }
        offset = page.header.next;
        if (page.header.end == 1) break;
        try std.testing.expect(count > 0);
    }
    try std.testing.expectEqual(@as(usize, 40), seen);
    try std.testing.expectEqual(@as(i64, 0), dir_page(0, token, offset, 16, &page));
    try std.testing.expectEqual(@as(u32, 1), page.header.end);
    try std.testing.expectEqual(@as(i64, -1), dir_page(0, token, offset + 1, 16, &page));
    try std.testing.expectEqual(@as(i64, -1), dir_page(0, token, 0, 17, &page));
    try std.testing.expectEqual(@as(i64, -1), dir_page(0, token, 0, 0, &page));
    try std.testing.expectEqual(@as(i64, 0), dir_close(0, token));
}

test "B2: first directory open preserves the table for ordinary files" {
    init();
    handles = &.{};
    virtio_file.set_test_share(&.{
        .{ .name = "D", .data = "", .is_dir = true },
        .{ .name = "D/item", .data = "item" },
        .{ .name = "file", .data = "file" },
    });
    defer virtio_file.set_test_share(null);
    const token = dir_open(0, "D");
    try std.testing.expect(token > 0);
    const fd = open(0, "file", MODE_READ);
    try std.testing.expectEqual(@as(i64, 1), fd);
    var page: directory.Page = undefined;
    try std.testing.expectEqual(@as(i64, 1), dir_page(0, @intCast(token), 0, 1, &page));
    try std.testing.expectEqualStrings("item", page.entries[0].name[0..page.entries[0].name_len]);
    try std.testing.expectEqual(@as(i64, 0), close(0, @intCast(fd)));
    try std.testing.expectEqual(@as(i64, 0), dir_close(0, @intCast(token)));
}

test "B2: boot ownership load streams wide keys and poisons overlong records" {
    init();
    var key: [506]u8 = undefined;
    @memset(key[0..250], 'a');
    key[250] = '/';
    @memset(key[251..], 'b');
    var second = key;
    second[505] = 'c';
    var owners: [2400]u8 = undefined;
    const text = try std.fmt.bufPrint(&owners, "#v1\r\n{s}\t600\t0\t-\r\n{s}\t600\t0\t-\r\n", .{ key, second });
    virtio_file.set_test_share(&.{.{ .name = trust.filename, .data = text }});
    defer virtio_file.set_test_share(null);
    try std.testing.expect(load_trust_from_share());
    // 2 seeded keys + the #2083 OWNERS.TXT self-protection row.
    try std.testing.expectEqual(@as(usize, 3), trust.count());
    const user = trust.Actor{ .uid = process.uid_user, .caps = 0 };
    try std.testing.expectEqual(trust.Verdict.eacces, trust.check(user, .host, &key, .list));
    try std.testing.expectEqual(trust.Verdict.eacces, trust.check(user, .host, &second, .read));

    const bad = try std.fmt.bufPrint(&owners, "#v1\n{s}\t600\t1000\t", .{key});
    @memset(owners[bad.len..][0..700], 'x');
    owners[bad.len + 700] = '\n';
    virtio_file.set_test_share(&.{.{ .name = trust.filename, .data = owners[0 .. bad.len + 701] }});
    try std.testing.expect(load_trust_from_share());
    try std.testing.expectEqual(trust.Verdict.eacces, trust.check(trust.kernel_actor(), .host, &key, .read));
}

test "B2: unopened or reclaimed table fails descriptors and tokens safely" {
    const saved = handles;
    handles = &.{};
    defer handles = saved;
    var byte: [1]u8 = undefined;
    var page: directory.Page = undefined;
    try std.testing.expectEqual(@as(i64, -2), read(0, 0, &byte));
    try std.testing.expectEqual(@as(i64, -2), write(0, 0, "x"));
    try std.testing.expectEqual(@as(i64, -2), close(0, 0));
    try std.testing.expectEqual(@as(i64, -2), truncate(0, 0, 0));
    try std.testing.expectEqual(@as(i64, -2), sync(0, 0));
    try std.testing.expectEqual(@as(i64, -2), dir_page(0, 1, 0, 1, &page));
    try std.testing.expectEqual(@as(i64, -2), dir_close(0, 1));
    var plan: StreamPlan = .{};
    try std.testing.expectEqual(@as(i64, -2), prepare_streams(0, .{ .sources = .{ 0, stream_closed, stream_closed } }, &plan));
    try std.testing.expectEqual(@as(i64, 0), prepare_streams(0, .{}, &plan));
    cancel_streams(&plan);
    reset_process(process.max_processes);
}

test "B2: file streams and directory cursors share the eight-resource limit" {
    init();
    trust.init();
    virtio_file.set_test_share(&.{
        .{ .name = "INPUT", .data = "input" },
        .{ .name = "D", .data = "", .is_dir = true },
    });
    defer virtio_file.set_test_share(null);
    const fd = open(0, "INPUT", MODE_READ);
    try std.testing.expectEqual(@as(i64, 0), fd);
    var plan: StreamPlan = .{};
    try std.testing.expectEqual(@as(i64, 0), prepare_streams(0, .{ .sources = .{ @intCast(fd), stream_closed, stream_closed } }, &plan));
    commit_streams(1, &plan);
    var tokens: [7]u64 = undefined;
    for (&tokens) |*token| {
        const opened = dir_open(1, "D");
        try std.testing.expect(opened > 0);
        token.* = @intCast(opened);
    }
    try std.testing.expectEqual(@as(i64, -5), dir_open(1, "D"));
    try std.testing.expectEqual(@as(i64, -5), open(1, "INPUT", MODE_READ));
    // A cursor's native index cannot be moved into a byte stream.
    try std.testing.expectEqual(@as(i64, -1), prepare_streams(1, .{ .sources = .{ 0, stream_closed, stream_closed } }, &plan));
    try std.testing.expectEqual(@as(i64, 0), dir_close(1, tokens[0]));
    const replacement = open(1, "INPUT", MODE_READ);
    try std.testing.expectEqual(@as(i64, 0), replacement);
    try std.testing.expectEqual(@as(i64, -5), dir_open(1, "D"));
    try std.testing.expectEqual(@as(i64, 0), stream_close(1, stream_base));
    const fresh = dir_open(1, "D");
    try std.testing.expect(fresh > 0);
    reset_process(1);
    var page: directory.Page = undefined;
    try std.testing.expectEqual(@as(i64, -2), dir_page(1, @intCast(fresh), 0, 1, &page));
    for (endpoints) |ep| try std.testing.expectEqual(@as(usize, 0), ep.refs);
    for (snapshot_used) |used| try std.testing.expect(!used);
}

test "B2: stream pool refusal preserves parent handles and default bindings" {
    init();
    const saved = endpoints;
    endpoints = &.{};
    test_endpoint_pool_empty = true;
    defer {
        test_endpoint_pool_empty = false;
        endpoints = saved;
        reset_process(0);
    }
    handles[0][0] = .{ .in_use = true, .flags = MODE_READ };
    var plan: StreamPlan = .{};
    try std.testing.expectEqual(@as(i64, -10), prepare_streams(0, .{ .sources = .{ 0, stream_closed, stream_closed } }, &plan));
    try std.testing.expect(handles[0][0].in_use);
    try std.testing.expect(!plan.active and endpoints.len == 0);
    try std.testing.expectEqual(@as(i64, 0), prepare_streams(0, .{}, &plan));
    cancel_streams(&plan);
    try std.testing.expect(stream_is_console(0, stream_base + 1));
    try std.testing.expect(handles[0][0].in_use and endpoints.len == 0);
}

test "B2: cursor ownership, stale reuse, close and process death recover capacity" {
    init();
    trust.init();
    virtio_file.set_test_share(&.{});
    defer virtio_file.set_test_share(null);
    var tokens: [8]u64 = undefined;
    for (&tokens) |*token| token.* = @intCast(dir_open(0, ""));
    try std.testing.expectEqual(@as(i64, -5), dir_open(0, ""));
    try std.testing.expectEqual(@as(i64, -5), dir_open(1, ""));
    var page: directory.Page = undefined;
    try std.testing.expectEqual(@as(i64, -2), dir_page(1, tokens[0], 0, 16, &page));
    try std.testing.expectEqual(@as(i64, -2), dir_close(1, tokens[0]));
    try std.testing.expectEqual(@as(i64, 0), dir_close(0, tokens[0]));
    try std.testing.expectEqual(@as(i64, -2), dir_close(0, tokens[0]));
    const fresh = dir_open(0, "");
    try std.testing.expect(fresh > 0 and fresh != tokens[0]);
    try std.testing.expectEqual(@as(i64, -2), dir_page(0, tokens[0], 0, 16, &page));
    reset_process(0);
    try std.testing.expectEqual(@as(i64, -2), dir_page(0, @intCast(fresh), 0, 16, &page));
    for (&tokens) |*token| token.* = @intCast(dir_open(1, ""));
    reset_process(1);
    // Cursors share native handle capacity with files, never an extra table.
    for (&handles[0]) |*h| h.* = .{ .in_use = true };
    try std.testing.expectEqual(@as(i64, -5), dir_open(0, ""));
    reset_process(0);
    test_snapshot_pool_empty = true;
    defer test_snapshot_pool_empty = false;
    try std.testing.expectEqual(@as(i64, -10), dir_open(0, ""));
    for (snapshot_used) |used| try std.testing.expect(!used);
}

test "B2: exact and over entry, full native path, component and depth bounds" {
    init();
    trust.init();
    var files: [257]virtio_file.TestFile = undefined;
    var names: [257][16]u8 = undefined;
    for (&files, 0..) |*f, i| {
        f.* = .{ .name = try std.fmt.bufPrint(&names[i], "entry-{d}", .{i}), .data = "" };
    }
    virtio_file.set_test_share(files[0..256]);
    defer virtio_file.set_test_share(null);
    const token = dir_open(0, "");
    try std.testing.expect(token > 0);
    var page: directory.Page = undefined;
    try std.testing.expectEqual(@as(i64, 16), dir_page(0, @intCast(token), 240, 16, &page));
    try std.testing.expectEqual(@as(u32, 1), page.header.end);
    try std.testing.expectEqual(@as(i64, 0), dir_close(0, @intCast(token)));
    virtio_file.set_test_share(&files);
    try std.testing.expectEqual(@as(i64, -5), dir_open(0, ""));
    const exact = "/host/" ++ (@as([255]u8, @splat(@as(u8, 'a')))) ++ "/" ++ (@as([250]u8, @splat(@as(u8, 'b'))));
    try std.testing.expectEqual(@as(usize, 512), exact.len);
    const nested = [_]virtio_file.TestFile{
        .{ .name = exact[6..], .data = "", .is_dir = true },
        .{ .name = "a/b/c/d/e/f/g/h", .data = "", .is_dir = true },
    };
    virtio_file.set_test_share(&nested);
    const exact_token = dir_open(0, exact);
    try std.testing.expect(exact_token > 0);
    try std.testing.expectEqual(@as(i64, 0), dir_close(0, @intCast(exact_token)));
    try std.testing.expectEqual(@as(i64, -8), dir_open(0, exact ++ "c"));
    const deep = dir_open(0, "/host/a/b/c/d/e/f/g/h");
    try std.testing.expect(deep > 0);
    try std.testing.expectEqual(@as(i64, 0), dir_close(0, @intCast(deep)));
    try std.testing.expectEqual(@as(i64, -8), dir_open(0, "/host/a/b/c/d/e/f/g/h/i"));
    try std.testing.expectEqual(@as(i64, -8), dir_open(0, &(@as([256]u8, @splat(@as(u8, 'x'))))));
    const long = [_]virtio_file.TestFile{.{ .name = &(@as([255]u8, @splat(@as(u8, 'x')))), .data = "" }};
    virtio_file.set_test_share(&long);
    const name_token = dir_open(0, "");
    try std.testing.expect(name_token > 0);
    try std.testing.expectEqual(@as(i64, 1), dir_page(0, @intCast(name_token), 0, 16, &page));
    try std.testing.expectEqualStrings(long[0].name, page.entries[0].name[0..page.entries[0].name_len]);
    try std.testing.expectEqual(@as(i64, 0), dir_close(0, @intCast(name_token)));
    const over = [_]virtio_file.TestFile{.{ .name = &(@as([256]u8, @splat(@as(u8, 'x')))), .data = "" }};
    virtio_file.set_test_share(&over);
    try std.testing.expectEqual(@as(i64, -8), dir_open(0, ""));
    try std.testing.expectEqual(@as(i64, -4), dir_open(0, "usb1"));
}

test "B2: access denial at capture and page, including persisted wide keys" {
    init();
    trust.init();
    const files = [_]virtio_file.TestFile{.{ .name = "private", .data = "", .is_dir = true }};
    virtio_file.set_test_share(&files);
    defer virtio_file.set_test_share(null);
    try std.testing.expectEqual(trust.LoadResult.ok, trust.load("#v1\nprivate\t600\t0\t-\n"));
    try std.testing.expectEqual(@as(i64, -7), dir_open(0, "private"));
    trust.init();
    const token = dir_open(0, "private");
    try std.testing.expect(token > 0);
    _ = trust.load("#v1\nprivate\t600\t0\t-\n");
    var page: directory.Page = undefined;
    try std.testing.expectEqual(@as(i64, -7), dir_page(0, @intCast(token), 0, 16, &page));
    try std.testing.expectEqual(@as(i64, 0), dir_close(0, @intCast(token)));
    const key = (@as([200]u8, @splat(@as(u8, 'a')))) ++ "/" ++ (@as([200]u8, @splat(@as(u8, 'b'))));
    const owners = "#v1\n" ++ key ++ "\t600\t0\t-\n";
    try std.testing.expectEqual(trust.LoadResult.ok, trust.load(owners));
    try std.testing.expectEqual(trust.Verdict.eacces, trust.check(.{ .uid = process.uid_user, .caps = 0 }, .host, key, .list));
    var saved: [trust.save_max]u8 = undefined;
    const n = trust.save(&saved);
    // The persisted form now carries the #2083 OWNERS.TXT self row too.
    try std.testing.expectEqualStrings(owners ++ "OWNERS.TXT\t604\t0\t-\n", saved[0..n]);
    trust.init();
}

test "file_table: M97d-F5 (#2090) — OWNERS.TXT is kernel-writable only at the file ABI" {
    init();
    trust.init();
    virtio_file.set_test_share(&.{
        .{ .name = "OWNERS.TXT", .data = "#v1\n" },
        .{ .name = "OTHER.TXT", .data = "x" },
    });
    defer virtio_file.set_test_share(null);

    // Every EL0 mutation class on the policy file is EACCES at the gate —
    // the 0644/uid_user default no longer makes the app its owner.
    try std.testing.expectEqual(@as(i64, -7), open(0, "OWNERS.TXT", MODE_WRITE));
    try std.testing.expectEqual(@as(i64, -7), open(0, "OWNERS.TXT", MODE_WRITE | MODE_CREATE));
    try std.testing.expectEqual(@as(i64, -7), open(0, "OWNERS.TXT", MODE_DIR | MODE_CREATE | MODE_WRITE));
    try std.testing.expectEqual(@as(i64, -7), delete(0, "OWNERS.TXT"));
    try std.testing.expectEqual(@as(i64, -7), rename(0, "OWNERS.TXT", "X.TXT"));
    try std.testing.expectEqual(@as(i64, -7), rename(0, "OTHER.TXT", "OWNERS.TXT"));
    // Case-insensitive, like the table's keying.
    try std.testing.expectEqual(@as(i64, -7), open(0, "owners.txt", MODE_WRITE));
    // chmod on it is denied even though stat resolves and the app is the
    // default owner.
    try std.testing.expectEqual(@as(i64, -7), set_mode(0, "OWNERS.TXT", 0o600));

    // Reads stay allowed: policy, not secret.
    const fd = open(0, "OWNERS.TXT", MODE_READ);
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(@as(i64, 0), close(0, @intCast(fd)));

    // chmod on OTHER paths still reaches persist_trust (which writes
    // OWNERS.TXT itself — kernel-only never locks the kernel out). With no
    // real channel the persist is an honest -5, proving the gate passed:
    // the OWNERS.TXT attempt above is a -7 at the gate, never a -5.
    try std.testing.expectEqual(@as(i64, -5), set_mode(0, "OTHER.TXT", 0o600));
    try std.testing.expectEqual(@as(usize, 1), trust.count());
    var saved: [trust.save_max]u8 = undefined;
    const n = trust.save(&saved);
    try std.testing.expect(std.mem.indexOf(u8, saved[0..n], "OTHER.TXT\t600\t") != null);
}

test "file_table: path parsing and volume routing" {
    // Bare paths default to the host share (HF6: the only partition).
    const p1 = parse_path("hello.txt").?;
    try std.testing.expectEqual(Partition.host, p1.partition);
    try std.testing.expectEqualStrings("hello.txt", p1.path[0..p1.path_len]);

    // M34 HF4 (issue #738): the host-share prefix routes to `.host` with
    // the path relative to the share root.
    const ph1 = parse_path("/host/APPS.TXT").?;
    try std.testing.expectEqual(Partition.host, ph1.partition);
    try std.testing.expectEqualStrings("APPS.TXT", ph1.path[0..ph1.path_len]);
    const ph2 = parse_path("host:sub/app.bin").?;
    try std.testing.expectEqual(Partition.host, ph2.partition);
    try std.testing.expectEqualStrings("sub/app.bin", ph2.path[0..ph2.path_len]);
    const ph3 = parse_path("/host").?;
    try std.testing.expectEqual(Partition.host, ph3.partition);
    try std.testing.expectEqual(ph3.path_len, 0);

    // M43 U3 (issue #1034): `usb`, `/usb`, and `usb:` all route to the raw
    // block device. `usbxyz` stays a host file (prefix match is boundary-
    // delimited, like the host prefixes).
    const pu1 = parse_path("usb").?;
    try std.testing.expectEqual(Partition.usb, pu1.partition);
    try std.testing.expectEqual(pu1.path_len, 0);
    const pu2 = parse_path("/usb").?;
    try std.testing.expectEqual(Partition.usb, pu2.partition);
    const pu3 = parse_path("usb:").?;
    try std.testing.expectEqual(Partition.usb, pu3.partition);
    const pu4 = parse_path("USB/").?;
    try std.testing.expectEqual(Partition.usb, pu4.partition);
    const ph4 = parse_path("usbx.txt").?;
    try std.testing.expectEqual(Partition.host, ph4.partition);

    // Traversal defense: rejection of '..'
    try std.testing.expect(parse_path("../secret.txt") == null);
    try std.testing.expect(parse_path("/host/../secret.txt") == null);
    try std.testing.expect(parse_path("dir/../../file") == null);
    try std.testing.expect(parse_path("..") == null);
    try std.testing.expect(parse_path("a/b/c/d/e/f/g/h/i/file") != null);
}

test "file_table: the usb volume is read-only and absent without a device" {
    init();
    // Write-ish flags on `.usb` are refused (EINVAL) before any device
    // probe, so this is deterministic on the host.
    try std.testing.expectEqual(@as(i64, -1), open(0, "usb", MODE_WRITE));
    try std.testing.expectEqual(@as(i64, -1), open(0, "usb", MODE_READ | MODE_CREATE));
    try std.testing.expectEqual(@as(i64, -1), open(0, "usb", MODE_READ | MODE_DIR | MODE_WRITE | MODE_CREATE));
    // A read-open with no MSC enumerated is an honest ENOENT (the host has
    // no USB device table populated).
    try std.testing.expectEqual(@as(i64, -6), open(0, "usb", MODE_READ));
    // A host handle still opens exactly as before (regression guard).
    try std.testing.expectEqual(@as(i64, -6), open(0, "hello.txt", MODE_READ)); // no host channel on the host
}

test "file_table: M70f volume paths route to .usb_fat and refuse the impossible" {
    // `usb<N>[/<path>]` and `usb<N>:<path>` select MBR partition N (1..4).
    const p1 = parse_path("usb1").?;
    try std.testing.expectEqual(Partition.usb_fat, p1.partition);
    try std.testing.expectEqual(@as(u8, 1), p1.usb_index);
    try std.testing.expectEqual(@as(u8, 0), p1.path_len);
    const p2 = parse_path("usb2/PROBE.TXT").?;
    try std.testing.expectEqual(Partition.usb_fat, p2.partition);
    try std.testing.expectEqual(@as(u8, 2), p2.usb_index);
    try std.testing.expectEqualStrings("PROBE.TXT", p2.path[0..p2.path_len]);
    // Case-insensitive, leading-slash tolerant, and the `:` form collapses the
    // same way the host prefixes do.
    const p3 = parse_path("/USB3:DOCS/NOTE.TXT").?;
    try std.testing.expectEqual(Partition.usb_fat, p3.partition);
    try std.testing.expectEqual(@as(u8, 3), p3.usb_index);
    try std.testing.expectEqualStrings("DOCS/NOTE.TXT", p3.path[0..p3.path_len]);

    // The whole-disk raw device keeps its exact previous meaning.
    try std.testing.expectEqual(Partition.usb, parse_path("usb").?.partition);
    try std.testing.expectEqual(Partition.usb, parse_path("usb:").?.partition);
    try std.testing.expectEqual(Partition.usb, parse_path("/usb/").?.partition);

    // A slot the MBR cannot have is refused outright (loud, not a host read);
    // text that is not the volume form stays a host file, boundary rule intact.
    try std.testing.expect(parse_path("usb5") == null);
    try std.testing.expect(parse_path("usb9/x") == null);
    try std.testing.expectEqual(Partition.host, parse_path("usb1x.txt").?.partition);
    try std.testing.expectEqual(Partition.host, parse_path("usb10.txt").?.partition);
    try std.testing.expectEqual(Partition.host, parse_path("usb0").?.partition);

    const f1 = usbVolumeForm("usb1").?;
    try std.testing.expectEqual(@as(u8, 1), f1.index);
    try std.testing.expectEqual(@as(usize, 0), f1.rest.len);
    const f4 = usbVolumeForm("USB4/a/b.txt").?;
    try std.testing.expectEqual(@as(u8, 4), f4.index);
    try std.testing.expectEqualStrings("a/b.txt", f4.rest);
    try std.testing.expect(usbVolumeForm("usb") == null);
    try std.testing.expect(usbVolumeForm("usb0") == null);
    try std.testing.expect(usbVolumeForm("usb ") == null);
}

test "file_table: M70f volume handles are read-only and honest with no device" {
    init();
    // Mutating flags are refused before a single sector is read.
    try std.testing.expectEqual(@as(i64, -1), open(0, "usb1/PROBE.TXT", MODE_WRITE));
    try std.testing.expectEqual(@as(i64, -1), open(0, "usb1/PROBE.TXT", MODE_READ | MODE_CREATE));
    try std.testing.expectEqual(@as(i64, -1), open(0, "usb1/PROBE.TXT", MODE_READ | MODE_APPEND));
    // With no MSC enumerated every volume path is an honest ENOENT — including
    // the root, which is not a byte stream in any case.
    try std.testing.expectEqual(@as(i64, -6), open(0, "usb1", MODE_READ));
    try std.testing.expectEqual(@as(i64, -6), open(0, "usb1/PROBE.TXT", MODE_READ));
    var rows: [4]DirEntry = undefined;
    try std.testing.expectEqual(@as(i64, -6), dir_list(0, "usb1", rows[0..]));
    try std.testing.expectEqual(@as(i64, -6), dir_list(0, "usb1/DOCS", rows[0..]));
    // A volume is never mode-governed, and never mutable through this table:
    // the subpath must not leak into the host channel.
    try std.testing.expectEqual(@as(i64, -7), set_mode(0, "usb1/PROBE.TXT", 0o600));
    try std.testing.expectEqual(@as(i64, -1), delete(0, "usb1/PROBE.TXT"));
    try std.testing.expectEqual(@as(i64, -1), delete(0, "usb"));
    try std.testing.expectEqual(@as(i64, -1), rename(0, "usb1/a.txt", "usb1/b.txt"));
}

test "file_table: handle allocation, bounds, and lifecycle reset" {
    init();
    const pid: u64 = 1;

    // Invalid flags
    try std.testing.expectEqual(@as(i64, -1), open(pid, "test.txt", 0));
    try std.testing.expectEqual(@as(i64, -1), open(pid, "test.txt", 0x100));

    // Reset process frees all handles
    reset_process(pid);
    try std.testing.expectEqual(@as(i64, -2), close(pid, 0));
}

test "file_table: wire DirEntry size is exactly 40 bytes" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(DirEntry));
}

test "file_table: mutating ops validate pids, paths, and volumes (claim 5801)" {
    // Bad pid for every new op.
    try std.testing.expectEqual(@as(i64, -1), delete(process.max_processes, "x.txt"));
    try std.testing.expectEqual(@as(i64, -1), rename(process.max_processes, "a.txt", "b.txt"));
    try std.testing.expectEqual(@as(i64, -1), free_space(process.max_processes, 0));

    // Empty / traversal paths are refused without a disk.
    try std.testing.expectEqual(@as(i64, -1), delete(1, ""));
    try std.testing.expectEqual(@as(i64, -1), delete(1, "../x.txt"));
    try std.testing.expectEqual(@as(i64, -1), rename(1, "a.txt", "../b.txt"));

    // Every volume is an honest EINVAL — the FAT volumes are gone (HF6)
    // and the host channel has no free-space op.
    try std.testing.expectEqual(@as(i64, -1), free_space(1, 0));
    try std.testing.expectEqual(@as(i64, -1), free_space(1, 1));

    // Truncate on an unopened handle is EBADF.
    init();
    try std.testing.expectEqual(@as(i64, -2), truncate(1, 0, 4));
}

test "file_table: replacement authorizes both ends before backend mutation" {
    const Probe = struct {
        var calls: usize = 0;
        fn rename_probe(_: []const u8, _: []const u8, _: RenameMode) u8 {
            calls += 1;
            return virtio_file.st_host_error;
        }
    };
    Probe.calls = 0;
    trust.init();
    defer trust.init();
    virtio_file.set_test_rename(Probe.rename_probe);
    defer virtio_file.set_test_rename(null);
    const pid = process.max_processes - 1;
    for ([_]RenameMode{ .preserve_existing, .replace }) |mode| {
        for ([_][]const u8{
            "#v1\nstage\t400\t1000\t-\n",
            "#v1\noutput\t400\t1000\t-\n",
            "#v1\nstage\t600\t0\tsecret\n",
            "#v1\noutput\t600\t0\tsecret\n",
            "#v1\noutput\tbad\t1000\t-\n",
        }) |policy| {
            _ = trust.load(policy);
            try std.testing.expectEqual(@as(i64, -7), rename_mode(pid, "stage", "output", mode));
        }
    }
    try std.testing.expectEqual(@as(usize, 0), Probe.calls);
}

test "file_table: rejected replacement keeps both trust entries" {
    const Probe = struct {
        var status: u8 = virtio_file.st_host_error;
        fn rename_probe(_: []const u8, _: []const u8, _: RenameMode) u8 {
            return status;
        }
    };
    trust.init();
    defer trust.init();
    virtio_file.set_test_rename(Probe.rename_probe);
    defer virtio_file.set_test_rename(null);
    const policy = "#v1\nstage\t600\t1000\t-\noutput\t606\t0\t-\n";
    _ = trust.load(policy);
    for ([_]struct { status: u8, errno: i64 }{
        .{ .status = virtio_file.st_host_error, .errno = -1 },
        .{ .status = virtio_file.st_not_found, .errno = -6 },
        .{ .status = virtio_file.st_exists, .errno = -9 },
        .{ .status = virtio_file.st_access, .errno = -7 },
        .{ .status = virtio_file.st_unsupported, .errno = -4 },
    }) |case| {
        Probe.status = case.status;
        try std.testing.expectEqual(case.errno, rename_mode(process.max_processes - 1, "stage", "output", .replace));
        var saved: [trust.save_max]u8 = undefined;
        const n = trust.save(&saved);
        // #2083: a loaded table always persists its OWNERS.TXT self row.
        try std.testing.expectEqualStrings(policy ++ "OWNERS.TXT\t604\t0\t-\n", saved[0..n]);
    }
}

test "file_table: M66a HF-status mapping keeps the four rows distinct" {
    // Open-path: the four statuses a /host path can hit are four errno rows.
    try std.testing.expectEqual(@as(i64, 0), hf_open_errno(virtio_file.st_ok));
    try std.testing.expectEqual(@as(i64, -6), hf_open_errno(virtio_file.st_not_found));
    try std.testing.expectEqual(@as(i64, -1), hf_open_errno(virtio_file.st_is_dir));
    try std.testing.expectEqual(@as(i64, -9), hf_open_errno(virtio_file.st_exists));
    try std.testing.expectEqual(@as(i64, -5), hf_open_errno(virtio_file.st_handle));
    // The residual host error is the closest honest row (EINVAL) and never
    // collides with the named four's ENOENT/EEXIST/ENOSPC.
    try std.testing.expectEqual(@as(i64, -1), hf_open_errno(virtio_file.st_host_error));
    try std.testing.expectEqual(@as(i64, -1), hf_open_errno(virtio_file.st_truncated));
    // Handle-carrying ops: a dead host handle is EBADF, not ENOSPC.
    try std.testing.expectEqual(@as(i64, 0), hf_handle_errno(virtio_file.st_ok));
    try std.testing.expectEqual(@as(i64, -2), hf_handle_errno(virtio_file.st_handle));
    try std.testing.expectEqual(@as(i64, -1), hf_handle_errno(virtio_file.st_host_error));
}

test "file_table: sync refuses a dead fd, no-ops for stateless handles" {
    init();
    try std.testing.expectEqual(@as(i64, -2), sync(1, 0)); // EBADF: closed fd
    try std.testing.expectEqual(@as(i64, -2), sync(process.max_processes, 0));

    // A host WRITE handle syncs through the channel — which the host-test
    // binary does not have, so the fsync reports the residual host error
    // (EINVAL) instead of pretending durability.
    init();
    handles[3][0] = .{
        .in_use = true,
        .partition = .host,
        .flags = MODE_WRITE,
        .host_handle = 2,
        .host_handle_valid = true,
    };
    try std.testing.expectEqual(@as(i64, -1), sync(3, 0));

    // A host handle WITHOUT a host write handle (stateless read handle) has
    // nothing to push: an honest no-op even with no channel.
    init();
    handles[3][0] = .{ .in_use = true, .partition = .host, .flags = MODE_READ };
    try std.testing.expectEqual(@as(i64, 0), sync(3, 0));
}

test "file_table: /dev/tty routes to the process's terminal device (#1072)" {
    init();
    const pid: u64 = 3;
    reset_process(pid);

    // Open the controlling terminal: a valid fd on the `.tty` partition
    // (works with no host file channel — it is a virtual device).
    const fd = open(pid, "/dev/tty", MODE_READ | MODE_WRITE);
    try std.testing.expect(fd >= 0);
    const h = &handles[pid][@intCast(fd)];
    try std.testing.expectEqual(Partition.tty, h.partition);

    // Writing appends to the terminal's output ring (front-end drains it).
    const th = h.term_handle;
    const t = terminal.get(th).?;
    try std.testing.expectEqual(@as(i64, 5), write(pid, @intCast(fd), "hello"));
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), t.readOut(&out));
    try std.testing.expectEqualStrings("hello", out[0..5]);

    // A front-end pushes input; the fd's read drains it.
    _ = t.pushInput("key");
    var in: [8]u8 = undefined;
    try std.testing.expectEqual(@as(i64, 3), read(pid, @intCast(fd), &in));
    try std.testing.expectEqualStrings("key", in[0..3]);

    // M66a: a `.tty` handle has no host-side state — sync is an honest no-op.
    try std.testing.expectEqual(@as(i64, 0), sync(pid, @intCast(fd)));

    // A second open reuses the SAME controlling terminal.
    const fd2 = open(pid, "tty", MODE_READ | MODE_WRITE);
    try std.testing.expect(fd2 >= 0);
    try std.testing.expectEqual(th, handles[pid][@intCast(fd2)].term_handle);

    // Process reset releases the terminal (owner death).
    reset_process(pid);
    try std.testing.expectEqual(@as(?*terminal.Terminal, null), terminal.get(th));
}

test "file_table: window tty reads preserve keyboard CSI bytes (#1794)" {
    init();
    app_events.init();
    driving_award.arm();
    for (&terminal.terminals) |*tt| tt.reset();

    const pid: u8 = 3;
    const res = driving_award.user_open(10, 10, 100, 100, pid);
    try std.testing.expect(res == .opened);
    const win_id = res.opened;
    defer _ = driving_award.user_close(win_id);

    const fd = open(pid, "/dev/tty", MODE_READ | MODE_WRITE);
    try std.testing.expect(fd >= 0);
    const th = handles[pid][@intCast(fd)].term_handle;
    const t = terminal.get(th).?;
    try std.testing.expect(t.attachWindow(win_id));

    // Consume WIN_FOCUS and clear any stale held-key state from another test.
    _ = app_events.pop(pid);
    input.decode_keyboard_report(&@as([8]u8, @splat(@as(u8, 0))));
    app_events.init();
    input.decode_keyboard_report(&[_]u8{ 0, 0, 0x52, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), app_events.pending(pid));

    var got: [8]u8 = undefined;
    const n = read(pid, @intCast(fd), &got);
    try std.testing.expectEqual(@as(i64, 3), n);
    try std.testing.expectEqualSlices(u8, "\x1b[A", got[0..@intCast(n)]);

    // Release the test key so it cannot become held state for another test.
    input.decode_keyboard_report(&@as([8]u8, @splat(@as(u8, 0))));
    reset_process(pid);
    for (&terminal.terminals) |*tt| tt.reset();
}

test "file_table: window tty write larger than the ring cannot drop (M73f-1)" {
    init();
    const pid: u64 = 3;
    reset_process(pid);

    const fd = open(pid, "/dev/tty", MODE_READ | MODE_WRITE);
    try std.testing.expect(fd >= 0);
    const th = handles[pid][@intCast(fd)].term_handle;
    const t = terminal.get(th).?;
    try std.testing.expect(t.attachWindow(7));

    const extra = 64;
    var big: [terminal.out_capacity + extra]u8 = undefined;
    @memcpy(big[0..4], "HEAD");
    for (big[4 .. big.len - 4], 0..) |*b, i| b.* = 'A' + @as(u8, @intCast(i % 26));
    @memcpy(big[big.len - 4 ..], "TAIL");

    try std.testing.expectEqual(@as(i64, @intCast(big.len)), write(pid, @intCast(fd), &big));
    try std.testing.expectEqual(@as(u64, 0), t.out_dropped);
    try std.testing.expectEqual(@as(usize, 0), t.pendingOut());

    const scr = terminal.screenOf(7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("HEAD", scr.line(0)[0..4]);
    const last_off = big.len - 4;
    const last_line = last_off / terminal.grid_cols;
    const last_col = last_off % terminal.grid_cols;
    try std.testing.expectEqual(@as(u21, 'T'), scr.cellAt(last_line, last_col).base);
    try std.testing.expectEqual(@as(u21, 'A'), scr.cellAt(last_line, last_col + 1).base);
    try std.testing.expectEqual(@as(u21, 'I'), scr.cellAt(last_line, last_col + 2).base);
    try std.testing.expectEqual(@as(u21, 'L'), scr.cellAt(last_line, last_col + 3).base);

    reset_process(pid);
}
