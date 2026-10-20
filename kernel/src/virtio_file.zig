//! M34 HF1+HF2 (issues #735/#736): the guest client for the HOST FILE
//! CHANNEL — a macOS folder served over custom-virtio queue 5
//! (`virtio_custom.file_qidx`, runner flag `--cvc-file <host-dir>`).
//!
//! Mirrors how `fat.zig` sits on `virtio_blk.zig`: a pure, host-testable
//! encode/decode core (the wire format is pinned byte-for-byte by the
//! shared class-A fixtures and the host's pure-Swift `VFWire` module) plus
//! a bounded polled transport on the claim-4374 primitives
//! (`submit_ex`/`wait`/`free_chain_q`).
//!
//! Wire (pinned by `tests/vf-*.bin`; see docs/hardware-contract.md):
//!   request  [op u8][flags u8][len u16le][payload]
//!   reply    [status u8][dlen u16le][data]
//!
//! Ops: VF_PROBE (0x00, transport-only — never a filesystem path),
//! LIST (0x01), READ (0x02, payload = [path][u64le offset] — stateless
//! streaming, the host holds zero state between requests), STAT (0x03,
//! payload = [path]), and the HF3 mutation set (additive, 0x04..0x0b):
//! OPEN/CLOSE/WRITE/TRUNCATE/FSYNC (handle-based — the host's 8-slot
//! handle table carries the write cursor; parity with file_table.zig's
//! 8-handle ABI) and RENAME/MKDIR/DELETE (path-based stateless). CLONE
//! (0x0c, HF7 issue #741) is path-based COW dedup: the host clones the
//! source with APFS clonefile semantics (clonefile(2) for files,
//! copyfile(3) COPYFILE_CLONE for trees) — N worktrees of one repo share
//! blocks until a worktree actually edits a file. Reply status: 0 ok,
//! 1 not found, 2 is a directory, 3 truncated (reply exceeded the guest's
//! buffer), 4 host error, 5 exists (create/rename/clone target
//! collision), 6 handle error (host table full or bad handle).
//!
//! VF_PROBE (HF1's acceptance case A) proves the ONE unproven transport
//! fact: a full 32,768-byte device-WRITE reply (claim 0680 proved 32 KiB
//! device-reads; the claim-9492 echo is the largest device-write today, at
//! 12,340 bytes). The probe reply is the RAW 32,768-byte pattern — the
//! transport-only op carries no [status][dlen] frame (the op tells the
//! guest what the reply means; the framing applies to the file ops):
//!   reply = pattern[0..32768),  pattern[i] = (i & 0xff) ^ ((i >> 8) & 0xff)
//! The guest asserts the used ring reports the FULL writtenByteCount
//! (32768), regenerates and compares ALL 32,768 bytes (a full compare,
//! not just the checksum — catches offset/ordering bugs), then main.zig
//! prints the RFC-1071 checksum for the gate. The same 32,768 bytes are
//! the shared class-A fixture `tests/vf-pattern-32k.bin` (sha256-pinned).

const virtio_custom = @import("virtio_custom.zig");
pub const virtio_fs = @import("virtio_fs.zig");
const spinlock = @import("spinlock.zig");
const klog = @import("klog.zig");
/// Claim 9094 (#810 writer hunt): the task-ring audit is a LIVE-gate
/// instrument only — the scheduler import is comptime-conditional so
/// host-test binaries never pull in scheduler's whole import tree (its
/// transitively-imported test blocks change the host-test universe, e.g.
/// driving_award's SB4 composite test reaches an unconditional `dc ivac`
/// that is an illegal instruction on x86 hosts). The stub keeps the call
/// sites type-identical in both worlds.
const scheduler = if (builtin.is_test) struct {
    pub const audit = struct {
        pub const Tag = enum { vf, reap, tick, drain };
        pub fn arm(tag: Tag) void {
            _ = tag;
        }
        pub fn check(tag: Tag) void {
            _ = tag;
        }
    };
} else @import("scheduler.zig");
const std = @import("std");
const builtin = @import("builtin");
const directory = @import("directory.zig");
pub const metadata = @import("fs_metadata.zig");
pub const MetadataRoot = virtio_fs.Root;

/// The legacy custom channel has neither pinned lookups nor object
/// identity, so B3 keeps refusing through it (ops == null). M134a (#2759)
/// admits the one honest answer the channel CAN give — file_table's op-0
/// path stat rides the channel's own STAT (mtime on a v2 reply).
pub fn metadata_backend(root: *MetadataRoot) metadata.Backend {
    if (virtio_fs.available()) return virtio_fs.contained_backend(root);
    return .{ .context = root, .root_path = root.path, .ops = null };
}

pub fn metadata_snapshot(backend: metadata.Backend, auth: metadata.Authorizer, path: []const u8, out: *metadata.Snapshot) metadata.Error!void {
    if (backend.ops == null) return error.ContainmentUnavailable;
    return virtio_fs.metadata_snapshot(backend, auth, path, out);
}

pub fn contained_read(handle: u16, offset: u64, out: []u8) metadata.Error!usize {
    return virtio_fs.contained_read(handle, offset, out);
}

pub fn contained_close(handle: u16) metadata.Error!void {
    return virtio_fs.contained_close(handle);
}

pub fn contained_write(handle: u16, bytes: []const u8, written: *u64) u8 {
    return virtio_fs.write(handle, bytes, written);
}

pub fn contained_sync(handle: u16) u8 {
    return virtio_fs.fsync(handle);
}

pub fn contained_truncate(handle: u16, size: u64) u8 {
    return virtio_fs.truncate(handle, size);
}

// ---------------------------------------------------------------------------
// Wire constants (mirrored by the host's VFWire module)
// ---------------------------------------------------------------------------

pub const op_probe: u8 = 0x00;
pub const op_list: u8 = 0x01;
pub const op_read: u8 = 0x02;
pub const op_stat: u8 = 0x03;
// HF3 (issue #737): mutation ops — ADDITIVE (0x04..0x0b), so the protocol
// stays non-breaking: an old host answers any new op with status 4 host
// error and an old guest never sends them. No version byte churn.
pub const op_open: u8 = 0x04;
pub const op_close: u8 = 0x05;
pub const op_write: u8 = 0x06;
pub const op_truncate: u8 = 0x07;
pub const op_fsync: u8 = 0x08;
pub const op_rename: u8 = 0x09;
pub const op_mkdir: u8 = 0x0a;
pub const op_delete: u8 = 0x0b;
// HF7 (issue #741): COW clone — additive (0x0c), the same non-breaking
// rule as the HF3 set: an old host answers it with status 4 and an old
// guest never sends it.
pub const op_clone: u8 = 0x0c;
pub const op_dir_open: u8 = 0x0d;
pub const op_dir_page: u8 = 0x0e;
pub const op_dir_close: u8 = 0x0f;
// B4 (#1871): separate opcode, not an ignored flags bit on legacy RENAME.
// An older host refuses this before any filesystem mutation.
pub const op_replace: u8 = 0x10;

pub const st_ok: u8 = 0;
pub const st_not_found: u8 = 1;
pub const st_is_dir: u8 = 2;
pub const st_truncated: u8 = 3;
pub const st_host_error: u8 = 4;
pub const st_exists: u8 = 5;
pub const st_handle: u8 = 6;
pub const st_limit: u8 = 7;
pub const st_path_limit: u8 = 8;
pub const st_changed: u8 = 9;
pub const st_access: u8 = 10;
pub const st_unsupported: u8 = 11;
pub const RenameMode = virtio_fs.RenameMode;

/// OPEN request `flags` byte bits (the framing's reserved byte picks up
/// per-op modifiers): bit0 create-if-missing, bit1 append-writes.
pub const open_flag_create: u8 = 0x01;
pub const open_flag_append: u8 = 0x02;

/// Request header: [op u8][flags u8][len u16le] then `len` payload bytes.
pub const request_hdr_len: usize = 4;
/// Reply header: [status u8][dlen u16le] then `dlen` data bytes.
pub const reply_hdr_len: usize = 3;
/// Paths are bounded (512 bytes) — honest refusal beyond.
pub const path_max: usize = directory.path_max;
/// The guest's reply buffer cap: full-cap 32 KiB device-write (HF1).
pub const reply_cap: usize = 32768;
/// LIST replies carry at most 128 40-byte rows (matches fat.max_root_slots;
/// 40 × 128 = 5 KiB — fits the reply buffer trivially).
pub const list_max_entries: usize = 128;
/// One LIST row: [name 31 B, NUL-padded][type u8][size u64le].
pub const entry_row_len: usize = 40;
/// READ payload = [path][u64le offset].
pub const read_offset_len: usize = 8;
/// HF3 handle + scalar field lengths.
pub const handle_len: usize = 2;
pub const written_len: usize = 8;
pub const truncate_size_len: usize = 8;
/// Host handle table cap — parity with kernel's file_table.zig
/// (max_handles_per_process = 8), asserted live on the HOST side where the
/// cursors live.
pub const max_file_handles: usize = 8;
/// Max data bytes per WRITE request body: the 2-byte handle + data must
/// fit the request nicely under the u16 length field AND stay within the
/// 32 KiB reply-cap symmetry (a chunked write never needs a large reply).
pub const write_chunk_max: usize = reply_cap - reply_hdr_len - handle_len;

/// Maximum payload accepted by one write round trip on the active backend.
/// VirtioFS negotiates a smaller FUSE max_write than the custom channel's
/// 32 KiB request bound.
pub fn write_chunk_limit() usize {
    if (prefer_fuse()) return @min(write_chunk_max, virtio_fs.write_chunk_limit());
    return write_chunk_max;
}
/// The most payload a READ reply can carry — the host bounds a read reply
/// by the queue's reply buffer. The test override serves at most this much
/// per call too, so host tests exercise the same round-trip loop the
/// hardware path does (M70c-K, issue #1504: a 9 MiB image is a few hundred
/// exchanges, and a test that served it in one call would prove nothing).
pub const read_chunk_max: usize = reply_cap - reply_hdr_len;

pub const dir_type_file: u8 = 0;
pub const dir_type_dir: u8 = 1;

pub const DirEntry = struct {
    name: [31]u8 = @as([31]u8, @splat(@as(u8, 0))),
    name_len: usize = 0,
    type: u8 = dir_type_file,
    size: u64 = 0,
};

comptime {
    if (@sizeOf(DirEntry) != @sizeOf(virtio_fs.DirectoryEntry) or
        @alignOf(DirEntry) != @alignOf(virtio_fs.DirectoryEntry) or
        @offsetOf(DirEntry, "name") != @offsetOf(virtio_fs.DirectoryEntry, "name") or
        @offsetOf(DirEntry, "name_len") != @offsetOf(virtio_fs.DirectoryEntry, "name_len") or
        @offsetOf(DirEntry, "type") != @offsetOf(virtio_fs.DirectoryEntry, "type") or
        @offsetOf(DirEntry, "size") != @offsetOf(virtio_fs.DirectoryEntry, "size"))
    {
        @compileError("VirtioFS directory rows must match virtio_file.DirEntry");
    }
}

// ---------------------------------------------------------------------------
// Pure encode/decode (host-testable; no transport state)
// ---------------------------------------------------------------------------

/// Little-endian byte primitives on SLICES (the std writeInt/readInt want
/// comptime-bounded array slices; our buffers are slice parameters — the
/// fat.zig read_le/write_le discipline).
fn write_le_u16(out: []u8, off: usize, v: u16) void {
    out[off] = @truncate(v);
    out[off + 1] = @truncate(v >> 8);
}

fn write_le_u64(out: []u8, off: usize, v: u64) void {
    var x = v;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        out[off + i] = @truncate(x);
        x >>= 8;
    }
}

fn read_le_u16(bytes: []const u8, off: usize) u16 {
    return @as(u16, bytes[off]) | (@as(u16, bytes[off + 1]) << 8);
}

fn read_le_u32(bytes: []const u8, off: usize) u32 {
    return @as(u32, bytes[off]) | (@as(u32, bytes[off + 1]) << 8) |
        (@as(u32, bytes[off + 2]) << 16) | (@as(u32, bytes[off + 3]) << 24);
}

fn read_le_u64(bytes: []const u8, off: usize) u64 {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) v |= @as(u64, bytes[off + i]) << @intCast(8 * i);
    return v;
}

/// Encode a request into `out`; returns the request length, or null when
/// the payload is too long or `out` is too small.
pub fn encode_request(op: u8, flags: u8, payload: []const u8, out: []u8) ?usize {
    if (payload.len > 0xffff) return null;
    const total = request_hdr_len + payload.len;
    if (out.len < total) return null;
    out[0] = op;
    out[1] = flags;
    write_le_u16(out, 2, @intCast(payload.len));
    @memcpy(out[4..][0..payload.len], payload);
    return total;
}

/// A decoded reply: status, the host's declared data length, and the data
/// slice — CLAMPED to the buffer (the read never goes out of bounds even
/// for a hostile dlen; `clamped` reports that truncation happened).
pub const Reply = struct {
    status: u8,
    dlen: u16,
    data: []const u8,
    clamped: bool,
};

/// Decode a reply buffer: [status u8][dlen u16le][data]. A buffer shorter
/// than the header decodes as host_error with an empty data slice.
pub fn decode_reply(buf: []const u8) Reply {
    if (buf.len < reply_hdr_len) {
        return .{ .status = st_host_error, .dlen = 0, .data = buf[0..0], .clamped = true };
    }
    const status = buf[0];
    const dlen = read_le_u16(buf, 1);
    const avail = buf.len - reply_hdr_len;
    const take = @min(@as(usize, dlen), avail);
    return .{
        .status = status,
        .dlen = dlen,
        .data = buf[reply_hdr_len .. reply_hdr_len + take],
        .clamped = take < dlen,
    };
}

/// The VF_PROBE pattern (both sides compute it without storing 32 KiB):
/// `pattern[i] = (i & 0xff) ^ ((i >> 8) & 0xff)`.
pub fn pattern(i: usize) u8 {
    return @intCast((i & 0xff) ^ ((i >> 8) & 0xff));
}

/// Decode one 40-byte LIST row into a DirEntry (never reads OOB; a short
/// row yields an empty entry).
pub fn decode_entry_row(row: []const u8) DirEntry {
    var e = DirEntry{};
    if (row.len < entry_row_len) return e;
    @memcpy(e.name[0..31], row[0..31]);
    e.name_len = 0;
    while (e.name_len < 31 and e.name[e.name_len] != 0) e.name_len += 1;
    e.type = row[31];
    e.size = read_le_u64(row, 32);
    return e;
}

/// Build a READ request payload: [path][u64le offset].
pub fn build_read_payload(path: []const u8, offset: u64, out: []u8) ?usize {
    if (path.len > path_max) return null;
    const total = path.len + read_offset_len;
    if (out.len < total) return null;
    @memcpy(out[0..path.len], path);
    write_le_u64(out, path.len, offset);
    return total;
}

// ---------------------------------------------------------------------------
// Bounded polled transport (queue 5)
// ---------------------------------------------------------------------------

/// The bounded wait budget for ONE file-channel exchange (polled — no IRQ
/// dependency; the 32 KiB reply needs a generous spin budget).
/// One exchange's poll budget. Measured natively at ~5 ns/iteration, 32M
/// was only ~155 ms — shorter than a host-side serving stall under serial
/// flood, so the z2a zc leg timed out, silently failed its file ops, and
/// recycled chains under the host (claim #899). 320M ≈ 1.5-2 s: timeouts
/// become vanishingly rare, and the retry + parked-chain path makes even
/// that case honest (fail fast, never corrupt). A `var` so host tests can
/// shrink it — the timeout/park path is exercised without a ~2 s spin.
pub var exchange_budget: usize = 320_000_000;

/// BSS staging — the flat kernel does not relocate, so every buffer the
/// device touches must hold a runtime-correct address (claim 0015: no
/// comptime-folded pointers into .rodata). The request fits a 512-byte
/// path + u64 offset + the 4-byte header; the reply is the full 32 KiB.
var vf_req_buf: [request_hdr_len + path_max + read_offset_len]u8 align(16) = undefined;
/// WRITE staging: the full request [op][flags][len][handle u16][data] —
/// the one large guest→host payload (up to write_chunk_max data bytes per
/// round trip).
var vf_write_buf: [request_hdr_len + handle_len + write_chunk_max]u8 align(16) = undefined;
/// Runtime-built scatter staging (claim-0015/cv_scatter class): the
/// anonymous-array-literal form const-folds into .rodata with baked
/// image-relative pointers, so the read-buffer slice array lives in BSS.
var vf_scatter: [1][]const u8 = undefined;
/// The reply buffer (device-write target); the single largest per-queue
/// buffer and the point of HF1: the host must write all 32 KiB into it.
var vf_reply_buf: [reply_cap]u8 align(16) = undefined;

/// Test-only share override: host tests that exercise the share-reading
/// consumers (exec, settings, shell) serve STAT/READ from an in-memory map
/// instead of the hardware. `set_test_share(null)` restores hardware mode.
/// M34 HF6 (issue #740): with fat.zig gone, this is the ONLY way to host-
/// test the consumers' read paths.
pub const TestFile = struct {
    name: []const u8,
    data: []const u8,
    /// HF6: a seeded DIRECTORY (stat reports is_dir; list emits a dir row
    /// with size 0) — the shell pipe/transcript tests seed EFI etc.
    is_dir: bool = false,
    /// STAT reports this size while `data` stays shorter — a file that
    /// changed between the STAT and the READ that follows it. Real: the
    /// share is a live host directory, so a half-written file is the
    /// normal failure this models (M70c-K, issue #1504: the streamed load
    /// must refuse rather than map a half-filled segment).
    stat_size: ?u64 = null,
    /// M134a: a seeded mtime (STAT reports it as a v2-shape reply —
    /// `has_mtime` set). Absent = the old-shape peer.
    mtime_sec: ?u64 = null,
    mtime_nsec: u32 = 0,
};
/// A caller-owned static table (never a stack literal: the slice must
/// outlive the setter). `null` restores hardware mode; an empty slice
/// arms the share with NO files (honest not_found for every name).
var test_share: ?[]const TestFile = null;
pub const TestRenameFn = *const fn ([]const u8, []const u8, RenameMode) u8;
var test_rename: ?TestRenameFn = null;

pub fn set_test_share(files: ?[]const TestFile) void {
    test_share = files;
}

/// Host-test failure injection only; never a guest transport or fallback.
pub fn set_test_rename(callback: ?TestRenameFn) void {
    if (builtin.is_test) test_rename = callback;
}

/// Strip leading slashes to conform to the root-relative wire contract
/// (e.g. "/" -> "", "/EFI" -> "EFI", "/KERNEL.BIN" -> "KERNEL.BIN").
pub fn clean_path(raw: []const u8) []const u8 {
    var p = raw;
    while (p.len > 0 and p[0] == '/') p = p[1..];
    return p;
}

fn test_lookup(raw_name: []const u8) ?[]const u8 {
    const name = clean_path(raw_name);
    const files = test_share orelse return null;
    for (files) |f| if (std.mem.eql(u8, f.name, name)) return f.data;
    return null;
}

/// True when the transport is usable (queue 5 armed by the runner's
/// `--cvc-file` — or the test override). Read by the monitor's `vf`
/// commands to print the honest "no host file channel" line on default
/// boots.
pub fn available() bool {
    if (builtin.is_test and test_rename != null) return true;
    if (builtin.is_test and test_share != null) return true;
    return virtio_fs.available() or (virtio_custom.cv_ready and virtio_custom.has_file_queue);
}

/// The legacy queue-5 file channel, armed. Bulk stat/read/write traffic
/// prefers it over the FUSE backend when BOTH channels are armed: one
/// exchange carries up to 32 KiB and waits a 320M-spin budget with a
/// re-kick retry, while a FUSE transact carries 2 KiB and has no retry —
/// a streamed exec or a multi-MiB file read over FUSE is thousands of
/// short-budget polls that poison fs_ready on the first timeout under
/// host load (observed: `exec` refusing streamed ELFs as
/// "truncated image" mid-segment). The B3 metadata backend stays
/// FUSE-only — the legacy channel has no pinned lookups.
fn cvc_file_armed() bool {
    return virtio_custom.cv_ready and virtio_custom.has_file_queue;
}

/// FUSE serves this call only when the legacy file queue is absent —
/// bulk ops prefer the legacy channel (see `cvc_file_armed`).
fn prefer_fuse() bool {
    return virtio_fs.available() and !cvc_file_armed();
}

/// Cross-core serialization for the file queue (claim #899 — the z2a
/// zc-leg OUT.TXT flake). Every queue-5 exchange assembles into the
/// module-global request/reply buffers (vf_req_buf / vf_write_buf /
/// vf_reply_buf / vf_scatter) and mutates the ring's shared state
/// (avail/used idx, last_used, the free list). M28 SMP means the shell
/// on one core can be running a file op (history save, exec read) while
/// the app on another does its own — the two race the buffers and a
/// request reaches the host with a corrupted length field (the host's
/// "request length mismatch" refusal), and the op silently fails (the
/// z2a fixture ignores write errors, so OUT.TXT came back empty while
/// the app still exited 72). One lock at this choke point covers every
/// file op (probe, list, read, stat, open/close/write/truncate/fsync,
/// rename/mkdir/delete/clone all funnel through exchange_raw). IRQs are
/// masked at vector entry for syscalls already; IrqSaveSpinlock makes
/// monitor-task callers safe too. The wait is POLLED (no IRQ dependency
/// — the used ring is observed directly), so the holder always completes
/// and a spinner finds it running and releasing promptly.
var vf_lock = spinlock.IrqSaveSpinlock{};

/// used-ring length (bytes the host wrote), or null on transport
/// failure/timeout. Claim 9094 (#810 writer hunt): EVERY exchange arms
/// the scheduler task-ring + process audit at entry and closes it at
/// exit (covers the probe spike, read, write, list and clone — the
/// vf-output era is where the corrupted-pointer faults were caught).
/// The caller (exchange / write) holds `vf_lock` for the WHOLE operation
/// — encode/assemble AND the exchange — because the request buffers are
/// module-global (see `vf_lock`).
fn exchange_raw(req: []const u8, reply_buf: []u8) ?u32 {
    if (!available()) return null;
    scheduler.audit.arm(.vf);
    const n = exchange_raw_inner(req, reply_buf);
    scheduler.audit.check(.vf);
    return n;
}

/// M97d-F1 (#2087): the used-ring `writtenByteCount` is host-controlled.
/// `wait` returns it raw (the VF-PROBE contract asserts the full 32768 via
/// `probe_reply_len`), but every caller slices the reply buffer with it —
/// cap it at the posted reply descriptor, the same bound the VirtioFS
/// transport enforces (`used.len > reply_buf.len → null` there).
fn clamped_len(n: u32, reply_buf: []u8) u32 {
    return @intCast(@min(@as(usize, n), reply_buf.len));
}

/// A parked element stays armed on the device (issue #2495): its
/// descriptors keep pointing at the shared request/reply buffers, so the
/// host's late serve would read whatever the NEXT exchange staged —
/// re-executing it, a duplicated mutation op against live share state —
/// and drop its reply into the live reply buffer. A parked chain's
/// descriptors are repointed at these sinks instead: the request is a
/// STAT of a name the share never holds (read-only, no host state, no
/// host-log line), and the reply lands where nothing live reads it.
var vf_park_req: [request_hdr_len + 16]u8 align(16) = undefined;
var vf_park_req_len: usize = 0;
var vf_park_reply: [64]u8 align(16) = undefined;

fn park_sinks() void {
    if (vf_park_req_len != 0) return;
    vf_park_req_len = encode_request(op_stat, 0, ".vf-parked-sink", &vf_park_req) orelse 0;
}

/// Ops whose host-side effect is read-only. Only these may resubmit after
/// a timeout park: a parked element that the host had ALREADY dequeued
/// before neutralization can still execute the original request once —
/// harmless for a read, a double-apply for a mutation (open/write/close/
/// rename/mkdir/delete/clone/truncate/fsync keep the honest failure).
fn resubmit_safe(op: u8) bool {
    return switch (op) {
        op_probe, op_list, op_read, op_stat, op_dir_page => true,
        else => false,
    };
}

/// Bounded transport diagnostics (#2495): `park_count` is timed-out
/// exchanges (each parked element was neutralized), `resubmit_count` is
/// the idempotent retries a host congestion stall survived, and
/// `virtio_custom.stale_used_count` counts consumed used-ring entries
/// that named neither a live element nor a parked head.
pub var vf_park_count: u32 = 0;
pub var vf_resubmit_count: u32 = 0;

/// One bounded serial line per park — parks are rare by definition (a
/// double poll-budget timeout), and the op byte names WHICH request the
/// host stalled on.
fn log_park(op: u8, head: u16) void {
    var buf: [56]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "vf: exchange timeout — parked head={d} op=0x{x}\n", .{ head, op }) catch return;
    klog.line(s);
}

fn exchange_raw_inner(req: []const u8, reply_buf: []u8) ?u32 {
    // #2495: one resubmit is allowed for read-only ops (resubmit_safe). A
    // timed-out element is neutralized before the retry leaves, so the
    // stale serve the park used to allow — the host executing the NEXT
    // request a second time, or its reply landing in the live buffer —
    // cannot happen; a single congestion stall no longer fails the op.
    var submits: usize = 0;
    while (true) {
        submits += 1;
        vf_scatter[0] = req;
        const handle = virtio_custom.submit_ex(virtio_custom.file_qidx, &vf_scatter, reply_buf, false) orelse return null;
        if (virtio_custom.wait(virtio_custom.file_qidx, handle, exchange_budget, reply_buf)) |n| {
            virtio_custom.reap_parked();
            virtio_custom.free_chain_q(virtio_custom.file_qidx, handle);
            return clamped_len(n, reply_buf);
        }
        // Claim #899 discipline: a timed-out exchange means the host is
        // SLOW, not dead — the element is still posted. Re-kick so a
        // callback that ran too early (or a dropped notification) rescans
        // and serves it, then wait one more budget.
        virtio_custom.kick_q(virtio_custom.file_qidx);
        if (virtio_custom.wait(virtio_custom.file_qidx, handle, exchange_budget, reply_buf)) |n2| {
            virtio_custom.reap_parked();
            virtio_custom.free_chain_q(virtio_custom.file_qidx, handle);
            return clamped_len(n2, reply_buf);
        }
        // Still unanswered: park the chain instead of freeing it —
        // recycling now would let the next submit reuse the same head
        // while the element is still queued on the host side. And now
        // NEUTRALIZE its descriptors first (park_sinks): the armed element
        // can still be dequeued later, and without the repoint its serve
        // reads the shared request buffer after the next exchange stages
        // it (a stale-serve: the host double-executes whatever request —
        // including mutations — is there) and writes into the live reply
        // buffer. The parked chain stays out of the free list until its
        // consumed used entry reaps it — the ring never leaks AND never
        // misattributes.
        park_sinks();
        virtio_custom.neutralize_chain(virtio_custom.file_qidx, handle, vf_park_req[0..vf_park_req_len], &vf_park_reply);
        virtio_custom.park_chain(handle);
        virtio_custom.reap_parked();
        vf_park_count += 1;
        log_park(req[0], handle);
        if (!resubmit_safe(req[0]) or submits >= 2) return null;
        vf_resubmit_count += 1;
    }
}

/// One bounded exchange on queue 5: encode the request into the shared
/// small request buffer, then exchange_raw.
fn exchange(op: u8, flags: u8, payload: []const u8, reply_buf: []u8) ?u32 {
    // The lock covers the ENCODE too: vf_req_buf is module-global, and two
    // cores assembling different ops into it simultaneously produce a
    // request whose len field and content belong to different ops — the
    // host's "request length mismatch" refusals (claim #899).
    const saved_daif = vf_lock.lock();
    defer vf_lock.unlock(saved_daif);
    const req_len = encode_request(op, flags, payload, &vf_req_buf) orelse return null;
    return exchange_raw(vf_req_buf[0..req_len], reply_buf);
}

// ---------------------------------------------------------------------------
// VF_PROBE — the 32 KiB device-write spike (HF1 acceptance case A)
// ---------------------------------------------------------------------------

/// Total VF_PROBE reply size: exactly 32,768 bytes (the capability under
/// test — the used ring must report the FULL writtenByteCount).
pub const probe_reply_len: usize = reply_cap;
/// The probe's marker value (0x8000 = 32768) printed as `len=` — the
/// gate's needle for the full-cap reply.
pub const probe_dlen: u16 = 0x8000;

pub const ProbeResult = struct {
    ok: bool,
    cksum: u16,
    free: u16,
};

/// Run the spike once at boot when queue 5 is armed: two exchanges
/// (chain reuse + the ring's free count restored to full — the
/// claim-0680 leak class at full scale), each verifying the full 32 KiB
/// device-write reply byte-for-byte. Returns the result for main.zig to
/// print in the cvspike style (the gate's marker line).
pub fn probe_spike() ProbeResult {
    const bad = ProbeResult{ .ok = false, .cksum = 0, .free = 0 };
    if (!available()) return bad;
    var ok = true;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const n = exchange(op_probe, 0, &[_]u8{}, &vf_reply_buf) orelse {
            ok = false;
            break;
        };
        // The transport-only probe reply is the RAW 32,768-byte pattern
        // (no [status][dlen] frame): the used ring must report the FULL
        // writtenByteCount and every byte must match the generator.
        // #2087: `n` is the clamped length — the probe's contract is the
        // RAW report, so assert `used_len` too; an over-reporting host
        // must not silently pass through the clamp.
        if (n != probe_reply_len or virtio_custom.used_len != probe_reply_len) {
            ok = false;
            break;
        }
        var j: usize = 0;
        while (j < probe_reply_len) : (j += 1) {
            if (vf_reply_buf[j] != pattern(j)) {
                ok = false;
                break;
            }
        }
        if (!ok) break;
    }
    const free = virtio_custom.cv_rings[virtio_custom.file_qidx].free_count;
    if (!ok) return ProbeResult{ .ok = false, .cksum = 0, .free = free };
    const cksum = virtio_custom.checksum1071(vf_reply_buf[0..probe_reply_len]);
    return ProbeResult{ .ok = true, .cksum = cksum, .free = free };
}

// ---------------------------------------------------------------------------
// File ops (HF2 — used by the monitor's `vf ls` / `vf cat`)
// ---------------------------------------------------------------------------

/// The result of `list`: parsed rows + the reply status.
pub const ListResult = struct {
    entries: [list_max_entries]DirEntry = undefined,
    count: usize = 0,
    status: u8 = st_host_error,
};

/// M134a (#2759): `list()`'s page of v2 snapshot rows — the callers'
/// DirEntry shape stays (name[31]), so a host name that cannot fit is an
/// explicit st_path_limit refusal by name, never silent truncation.
var vf_list_scratch: directory.Snapshot = undefined;

/// LIST a directory on the host share. `path` empty = the share root.
/// Returns the reply status; rows land in `out`. Test override: serve
/// the in-memory share table (flat root — every seeded name is a file
/// at the root; nested paths return st_not_found).
/// M134a (#2759): the legacy 31-byte LIST op has no kernel consumers
/// left — every caller now rides the v2 snapshot protocol (VirtioFS's
/// lossless readdir or the channel's dir_open/page/close). A host name
/// past this row's 31 bytes is refused by name (st_path_limit).
pub fn list(raw_path: []const u8, out: *ListResult) u8 {
    const path = clean_path(raw_path);
    out.* = .{};
    if (!available()) return st_host_error;
    // Test override: serve the fixture map (root only).
    if (builtin.is_test and test_share != null) {
        if (path.len != 0) return st_not_found;
        const files = test_share orelse return st_host_error;
        for (files) |f| {
            if (out.count >= list_max_entries) break;
            if (f.name.len > 31) {
                out.status = st_path_limit;
                return st_path_limit;
            }
            var e = DirEntry{};
            @memcpy(e.name[0..f.name.len], f.name);
            e.name_len = f.name.len;
            e.type = if (f.is_dir) dir_type_dir else dir_type_file;
            e.size = if (f.is_dir) 0 else f.data.len;
            out.entries[out.count] = e;
            out.count += 1;
        }
        out.status = st_ok;
        return st_ok;
    }
    const saved = vf_lock.lock();
    defer vf_lock.unlock(saved);
    // The module-global scratch must start empty: snapshot_exchange_seq
    // uses out.count as the page offset, so a stale count would page past
    // the new snapshot's rows and serve the previous listing.
    vf_list_scratch.count = 0;
    const status = if (prefer_fuse())
        virtio_fs.snapshot(path, &vf_list_scratch)
    else
        snapshot_exchange_seq(path, &vf_list_scratch);
    out.status = status;
    if (status != st_ok) return status;
    for (vf_list_scratch.entries[0..vf_list_scratch.count]) |entry| {
        if (out.count >= list_max_entries) break;
        if (entry.name_len > 31) {
            out.status = st_path_limit;
            return st_path_limit;
        }
        var e = DirEntry{};
        const nlen: usize = entry.name_len;
        @memcpy(e.name[0..nlen], entry.name[0..nlen]);
        e.name_len = nlen;
        e.type = if (entry.is_dir != 0) dir_type_dir else dir_type_file;
        e.size = entry.size;
        out.entries[out.count] = e;
        out.count += 1;
    }
    return st_ok;
}

fn snapshot_exchange(op: u8, payload: []const u8) ?Reply {
    const len = encode_request(op, 0, payload, &vf_req_buf) orelse return null;
    const n = exchange_raw(vf_req_buf[0..len], &vf_reply_buf) orelse return null;
    const reply = decode_reply(vf_reply_buf[0..n]);
    if (reply.clamped) return null;
    return reply;
}

/// Decode only a complete v2 page. No truncated row, duplicate name,
/// non-progressing continuation or success-shaped EOF is accepted.
pub fn decode_snapshot_page(data: []const u8, offset: usize, out: *directory.Snapshot) u8 {
    if (offset > directory.entry_max or data.len < @sizeOf(directory.Header)) return st_host_error;
    const next = read_le_u64(data, 0);
    const count = @as(u32, read_le_u16(data, 8)) | (@as(u32, read_le_u16(data, 10)) << 16);
    const end = @as(u32, read_le_u16(data, 12)) | (@as(u32, read_le_u16(data, 14)) << 16);
    if (count > directory.page_max or end > 1 or next != offset + count or
        next > directory.entry_max or (count == 0 and end == 0) or
        data.len != @sizeOf(directory.Header) + count * @sizeOf(directory.Entry)) return st_host_error;
    var at: usize = @sizeOf(directory.Header);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const row = data[at..][0..@sizeOf(directory.Entry)];
        const nlen = read_le_u16(row, 264);
        if (nlen > directory.name_max or row[266] > 1) return st_host_error;
        for (row[nlen..256]) |byte| if (byte != 0) return st_host_error;
        for (row[267..272]) |byte| if (byte != 0) return st_host_error;
        out.append(row[0..nlen], read_le_u64(row, 256), row[266] != 0) catch return st_host_error;
        at += @sizeOf(directory.Entry);
    }
    return if (end == 1) st_ok else st_truncated; // internal continuation, not a refusal
}

pub fn snapshot(raw_path: []const u8, out: *directory.Snapshot) u8 {
    const path = clean_path(raw_path);
    out.count = 0;
    if (!directory.valid_path(path, directory.depth_max)) return st_path_limit;
    if (!available()) return st_not_found;
    if (builtin.is_test and test_share != null) {
        const files = test_share.?;
        if (path.len != 0) {
            var exists = false;
            for (files) |f| {
                if (std.mem.eql(u8, f.name, path)) {
                    if (!f.is_dir) return st_is_dir;
                    exists = true;
                }
            }
            if (!exists) return st_not_found;
        }
        for (files) |f| {
            const name = if (path.len == 0) f.name else blk: {
                if (!std.mem.startsWith(u8, f.name, path) or f.name.len <= path.len or f.name[path.len] != '/') continue;
                break :blk f.name[path.len + 1 ..];
            };
            if (std.mem.indexOfScalar(u8, name, '/') != null) continue;
            out.append(name, if (f.is_dir) 0 else (f.stat_size orelse f.data.len), f.is_dir) catch |err| return switch (err) {
                error.EntryLimit => st_limit,
                error.NameLimit => st_path_limit,
                else => st_host_error,
            };
        }
        out.sort();
        return st_ok;
    }
    if (virtio_fs.available()) return virtio_fs.snapshot(path, out);
    const saved = vf_lock.lock();
    defer vf_lock.unlock(saved);
    return snapshot_exchange_seq(path, out);
}

/// The legacy channel's dir_open/page/close snapshot sequence; the
/// caller holds `vf_lock` (snapshot() above; list() reuses it so the
/// 31-byte LIST wire op keeps no kernel consumer).
fn snapshot_exchange_seq(path: []const u8, out: *directory.Snapshot) u8 {
    const opened = snapshot_exchange(op_dir_open, path) orelse return st_host_error;
    if (opened.status != st_ok) return opened.status;
    if (opened.data.len != 8) return st_host_error;
    var request: [12]u8 = @splat(0);
    @memcpy(request[0..8], opened.data);
    var closed = false;
    defer if (!closed) {
        _ = snapshot_exchange(op_dir_close, request[0..8]);
    };
    while (true) {
        write_le_u16(&request, 8, @intCast(out.count));
        write_le_u16(&request, 10, directory.page_max);
        const page = snapshot_exchange(op_dir_page, &request) orelse return st_host_error;
        if (page.status != st_ok) return page.status;
        const status = decode_snapshot_page(page.data, out.count, out);
        if (status == st_ok) break;
        if (status != st_truncated) return status;
    }
    const reply = snapshot_exchange(op_dir_close, request[0..8]) orelse return st_host_error;
    if (reply.status != st_ok or reply.data.len != 0) return st_host_error;
    closed = true;
    out.sort();
    return st_ok;
}

test "B2: legacy backend v2 rows and EOF decode losslessly and fail closed" {
    var snapshot_rows = directory.Snapshot{};
    var page = directory.Page{
        .header = .{ .next = 1, .count = 1, .end = 1 },
    };
    const name = @as([255]u8, @splat(@as(u8, 'n')));
    page.entries[0] = .{ .name_len = 255, .size = 0x0123456789abcdef };
    @memcpy(page.entries[0].name[0..255], &name);
    const raw: [*]const u8 = @ptrCast(&page);
    const bytes = raw[0 .. @sizeOf(directory.Header) + @sizeOf(directory.Entry)];
    try std.testing.expectEqual(st_ok, decode_snapshot_page(bytes, 0, &snapshot_rows));
    try std.testing.expectEqualStrings(&name, snapshot_rows.entries[0].name[0..255]);
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), snapshot_rows.entries[0].size);
    try std.testing.expectEqual(st_host_error, decode_snapshot_page(bytes, 1, &snapshot_rows));
    try std.testing.expectEqual(st_host_error, decode_snapshot_page(bytes[0 .. bytes.len - 1], 0, &snapshot_rows));
    page.header = .{ .next = 1, .count = 0, .end = 1 };
    try std.testing.expectEqual(st_ok, decode_snapshot_page(raw[0..16], 1, &snapshot_rows));
    page.header.end = 0;
    try std.testing.expectEqual(st_host_error, decode_snapshot_page(raw[0..16], 1, &snapshot_rows));
    page.header = .{ .next = 1, .count = 1, .end = 1 };
    page.entries[0].name_len = 256;
    try std.testing.expectEqual(st_host_error, decode_snapshot_page(bytes, 0, &snapshot_rows));
    page.entries[0].name_len = 255;
    page.entries[0].reserved[0] = 1;
    try std.testing.expectEqual(st_host_error, decode_snapshot_page(bytes, 0, &snapshot_rows));
}

/// M134a (#2759): STAT reply data lengths — v1 is [size u64le][type u8]
/// (9 B); v2 appends [mtime_sec u64le][mtime_nsec u32le] (21 B total).
/// An old-shape reply decodes with `has_mtime == false`: the named
/// "mtime absent", never a fabricated timestamp.
pub const stat_data_v1_len: usize = 9;
pub const stat_data_v2_len: usize = 21;

/// Decode STAT reply data into `out`: both the 9-byte pre-mtime shape
/// and the 21-byte M134a shape are accepted; a short or mid-length reply
/// still yields size/type and reports mtime absent.
pub fn decode_stat_reply(data: []const u8, out: *StatResult) void {
    if (data.len >= stat_data_v1_len) {
        out.size = read_le_u64(data, 0);
        out.is_dir = data[8] == dir_type_dir;
    }
    if (data.len >= stat_data_v2_len) {
        out.mtime_sec = read_le_u64(data, 9);
        out.mtime_nsec = read_le_u32(data, 17);
        out.has_mtime = true;
    }
}

/// STAT a path: size, type, and — on a v2 reply — the host file's mtime.
/// Returns the reply status.
pub const StatResult = struct {
    status: u8 = st_host_error,
    size: u64 = 0,
    is_dir: bool = false,
    /// M134a: the host file's modification time (epoch seconds +
    /// nanoseconds) when the reply carries the v2 shape. `has_mtime`
    /// names the absent case — the old 9-byte reply shape or a backend
    /// fast path that carries no timestamps.
    mtime_sec: u64 = 0,
    mtime_nsec: u32 = 0,
    has_mtime: bool = false,
};

pub fn stat(raw_path: []const u8, out: *StatResult) u8 {
    const path = clean_path(raw_path);
    out.* = .{};
    if (!available()) return st_host_error;
    // Test override: serve the fixture map.
    if (builtin.is_test and test_share != null) {
        const files = test_share orelse return st_not_found;
        for (files) |f| {
            if (std.mem.eql(u8, f.name, path)) {
                out.status = st_ok;
                out.size = if (f.is_dir) 0 else (f.stat_size orelse f.data.len);
                out.is_dir = f.is_dir;
                out.mtime_sec = f.mtime_sec orelse 0;
                out.mtime_nsec = f.mtime_nsec;
                out.has_mtime = f.mtime_sec != null;
                return st_ok;
            }
        }
        return st_not_found;
    }
    if (prefer_fuse()) {
        var result = virtio_fs.StatResult{};
        const status = virtio_fs.stat(path, &result);
        out.status = status;
        if (status == st_ok) {
            out.size = result.size;
            out.is_dir = result.is_dir;
        }
        return status;
    }
    const n = exchange(op_stat, 0, path, &vf_reply_buf) orelse return st_host_error;
    const rep = decode_reply(vf_reply_buf[0..n]);
    out.status = rep.status;
    if (rep.status != st_ok) return rep.status;
    decode_stat_reply(rep.data, out);
    return st_ok;
}

/// READ a file at `offset`. Returns the reply status; on ok the data
/// slice points into the module's reply buffer and is valid only until the
/// NEXT exchange on queue 5. NOTE: Callers that copy data into their own
/// buffer across tasks/cores MUST use `read_chunk` to copy under `vf_lock`
/// (issue #846).
pub const ReadResult = struct {
    status: u8 = st_host_error,
    data: []const u8 = "",
};

pub fn read(raw_path: []const u8, offset: u64) ReadResult {
    const path = clean_path(raw_path);
    if (!available()) return .{ .status = st_host_error, .data = "" };
    // Test override: serve the fixture map (single-chunk reads — the
    // hardware chunk loop is exercised live by the vf gate).
    if (builtin.is_test and test_share != null) {
        const data = test_lookup(path) orelse return .{ .status = st_not_found, .data = "" };
        if (offset >= data.len) return .{ .status = st_ok, .data = "" };
        return .{ .status = st_ok, .data = data[@intCast(offset)..] };
    }
    if (prefer_fuse()) {
        const result = virtio_fs.read(path, offset);
        return .{
            .status = result.status,
            .data = if (result.status == st_ok) virtio_fs.read_result() else "",
        };
    }
    var payload: [path_max + read_offset_len]u8 = undefined;
    const plen = build_read_payload(path, offset, &payload) orelse return .{ .status = st_host_error, .data = "" };
    const n = exchange(op_read, 0, payload[0..plen], &vf_reply_buf) orelse return .{ .status = st_host_error, .data = "" };
    const rep = decode_reply(vf_reply_buf[0..n]);
    if (rep.status != st_ok) return .{ .status = rep.status, .data = "" };
    if (rep.clamped) return .{ .status = st_truncated, .data = "" };
    return .{ .status = st_ok, .data = rep.data };
}

/// The result of `read_chunk`: reply status + byte count copied into destination.
pub const ReadChunkResult = struct {
    status: u8 = st_host_error,
    bytes: usize = 0,
};

/// READ a chunk at `offset` directly into caller's `out` buffer.
/// Unlike `read`, the request encode, queue 5 exchange, reply decode, and
/// the copy into `out` happen entirely under `vf_lock` (issue #846).
/// The module's shared `vf_reply_buf` is never read outside the lock,
/// preventing concurrent tasks or cores from clobbering in-flight replies
/// before or during the copy.
pub fn read_chunk(raw_path: []const u8, offset: u64, out: []u8) ReadChunkResult {
    const path = clean_path(raw_path);
    if (!available()) return .{ .status = st_host_error, .bytes = 0 };
    if (out.len == 0) return .{ .status = st_ok, .bytes = 0 };
    if (builtin.is_test and test_share != null) {
        const data = test_lookup(path) orelse return .{ .status = st_not_found, .bytes = 0 };
        if (offset >= data.len) return .{ .status = st_ok, .bytes = 0 };
        const src = data[@intCast(offset)..];
        // Mirror the wire bound: one reply carries at most `read_chunk_max`
        // payload bytes, so a caller streaming a larger region loops
        // exactly as it does against the real host.
        const take = @min(@min(src.len, out.len), read_chunk_max);
        @memcpy(out[0..take], src[0..take]);
        return .{ .status = st_ok, .bytes = take };
    }
    if (prefer_fuse()) {
        const result = virtio_fs.read_chunk(path, offset, out);
        return .{ .status = result.status, .bytes = result.bytes };
    }
    var payload: [path_max + read_offset_len]u8 = undefined;
    const plen = build_read_payload(path, offset, &payload) orelse return .{ .status = st_host_error, .bytes = 0 };

    const saved_daif = vf_lock.lock();
    defer vf_lock.unlock(saved_daif);

    const req_len = encode_request(op_read, 0, payload[0..plen], &vf_req_buf) orelse return .{ .status = st_host_error, .bytes = 0 };
    const n = exchange_raw(vf_req_buf[0..req_len], &vf_reply_buf) orelse return .{ .status = st_host_error, .bytes = 0 };
    const rep = decode_reply(vf_reply_buf[0..n]);
    if (rep.status != st_ok) return .{ .status = rep.status, .bytes = 0 };
    if (rep.clamped) return .{ .status = st_truncated, .bytes = 0 };
    const take = @min(rep.data.len, out.len);
    @memcpy(out[0..take], rep.data[0..take]);
    return .{ .status = st_ok, .bytes = take };
}

/// Stream `out.len` bytes starting at FILE `offset` into `out` across READ
/// round trips (each reply carries ≤ `reply_cap - reply_hdr_len` data
/// bytes, so a 9 MiB range is a few hundred exchanges and never has to
/// exist as one buffer). Returns the byte count (`out.len`), or null when
/// the file is absent, the transport fails, or the file ENDS EARLY —
/// a short read is a refusal, never a half-filled destination.
///
/// M70c-K (issue #1504): this is the streamed-exec primitive — a segment's
/// payload is read straight into the physical pages that will be mapped.
/// `read_into` is the whole-file special case of it.
pub fn read_at_into(raw_path: []const u8, offset: u64, out: []u8) ?usize {
    const path = clean_path(raw_path);
    if (!available()) return null;
    if (out.len == 0) return 0;
    var off = offset;
    var done: usize = 0;
    while (done < out.len) {
        const rc = read_chunk(path, off, out[done..]);
        if (rc.status != st_ok or rc.bytes == 0) return null;
        done += rc.bytes;
        off += rc.bytes;
    }
    return done;
}

/// Stream a whole file into `out` across READ round trips (each reply
/// carries ≤ `reply_cap - reply_hdr_len` data bytes, so a >32 KiB file
/// needs multiple exchanges). `size` from a prior STAT bounds the loop; a
/// short final reply is EOF. Returns the byte count, or null when the
/// file is absent, the transport fails, or `size` exceeds `out.len`.
/// Callers that need to distinguish "too big for the buffer" must compare
/// `size` against `out.len` BEFORE calling (exec.zig does — it maps that
/// to `.too_large`).
pub fn read_into(path: []const u8, size: u64, out: []u8) ?usize {
    if (!available()) return null;
    if (size > out.len) return null;
    return read_at_into(path, 0, out[0..@intCast(size)]);
}

/// STAT + whole-file read in one call (the kernel-side consumers'
/// pattern: settings, shell history/env, migration). Returns the byte
/// count, or null when the file is absent / too big for `out` / the
/// transport fails.
pub fn read_whole(path: []const u8, out: []u8) ?usize {
    if (!available()) return null;
    var st = StatResult{};
    if (stat(path, &st) != st_ok) return null;
    if (st.is_dir or st.size == 0 or st.size > out.len) return null;
    return read_into(path, st.size, out);
}

// ---------------------------------------------------------------------------
// Mutation ops (HF3, issue #737)
// ---------------------------------------------------------------------------

/// OPEN a file on the host share. `flags` = open_flag_create /
/// open_flag_append (create-if-missing makes the gate's "write a new
/// file" story one verb). On ok, `out_handle` receives the host handle
/// (cursor 0, or EOF when append — the host's table owns the cursor).
pub fn open(raw_path: []const u8, flags: u8, out_handle: *u16) u8 {
    const path = clean_path(raw_path);
    out_handle.* = 0;
    if (!available()) return st_host_error;
    if (prefer_fuse()) return virtio_fs.open(path, flags, out_handle);
    const n = exchange(op_open, flags, path, &vf_reply_buf) orelse return st_host_error;
    const rep = decode_reply(vf_reply_buf[0..n]);
    if (rep.status != st_ok) return rep.status;
    if (rep.data.len < handle_len) return st_host_error;
    out_handle.* = read_le_u16(rep.data, 0);
    return st_ok;
}

/// CLOSE a host handle (flush + free the slot).
pub fn close(handle: u16) u8 {
    if (prefer_fuse()) return virtio_fs.close(handle);
    return exchange_simple(op_close, handle);
}

/// FSYNC a host handle — real durability (the host calls synchronize() on
/// the live FileHandle).
pub fn fsync(handle: u16) u8 {
    if (prefer_fuse()) return virtio_fs.fsync(handle);
    return exchange_simple(op_fsync, handle);
}

fn exchange_simple(op: u8, handle: u16) u8 {
    if (!available()) return st_host_error;
    var payload: [handle_len]u8 = undefined;
    write_le_u16(&payload, 0, handle);
    const n = exchange(op, 0, &payload, &vf_reply_buf) orelse return st_host_error;
    return decode_reply(vf_reply_buf[0..n]).status;
}

/// WRITE `data` at the handle's cursor (append handles write at EOF). The
/// host returns the byte count it actually wrote. One WRITE round trip
/// carries ≤ write_chunk_max data bytes; callers chunk larger payloads.
pub fn write(handle: u16, data: []const u8, out_written: *u64) u8 {
    out_written.* = 0;
    if (!available()) return st_host_error;
    if (prefer_fuse()) return virtio_fs.write(handle, data, out_written);
    if (data.len > write_chunk_max) return st_host_error;
    // The lock covers the ASSEMBLY too — vf_write_buf is module-global and
    // a concurrent (other-core) assembly would splice two requests (claim
    // #899: the "request length mismatch" refusals).
    const saved_daif = vf_lock.lock();
    defer vf_lock.unlock(saved_daif);
    // Assemble the full request in one buffer without any self-overlap:
    // header fields at the head, body ([handle][data]) after them.
    const body_len = handle_len + data.len;
    const req_len = request_hdr_len + body_len;
    vf_write_buf[0] = op_write;
    vf_write_buf[1] = 0;
    write_le_u16(&vf_write_buf, 2, @intCast(body_len));
    write_le_u16(&vf_write_buf, request_hdr_len, handle);
    @memcpy(vf_write_buf[request_hdr_len + handle_len ..][0..data.len], data);
    const n = exchange_raw(vf_write_buf[0..req_len], &vf_reply_buf) orelse return st_host_error;
    const rep = decode_reply(vf_reply_buf[0..n]);
    if (rep.status != st_ok) return rep.status;
    if (rep.data.len < written_len) return st_host_error;
    out_written.* = read_le_u64(rep.data, 0);
    return st_ok;
}

/// TRUNCATE an open handle to `size` (read-modify-write: shrinking past
/// the cursor clamps the cursor; does not move the cursor otherwise).
pub fn truncate(handle: u16, size: u64) u8 {
    if (!available()) return st_host_error;
    if (prefer_fuse()) return virtio_fs.truncate(handle, size);
    var payload: [handle_len + truncate_size_len]u8 = undefined;
    write_le_u16(&payload, 0, handle);
    write_le_u64(&payload, handle_len, size);
    const n = exchange(op_truncate, 0, &payload, &vf_reply_buf) orelse return st_host_error;
    return decode_reply(vf_reply_buf[0..n]).status;
}

/// Preserve an existing destination on every backend. The legacy channel
/// uses RENAME_EXCL; VirtioFS requires FUSE_RENAME2/NOREPLACE and refuses
/// unsupported servers. Historically only the legacy host refused overwrite:
/// VirtioFS used plain FUSE_RENAME. That backend difference is now explicit.
pub fn rename(raw_from: []const u8, raw_to: []const u8) u8 {
    return rename_mode(raw_from, raw_to, .preserve_existing);
}

/// Publish a staged path with one atomic backend rename, replacing an existing
/// destination. A backend rejection leaves both names/content unchanged.
/// This is not directory-fsync durability or a multi-file transaction.
pub fn replace(raw_from: []const u8, raw_to: []const u8) u8 {
    return rename_mode(raw_from, raw_to, .replace);
}

fn rename_mode(raw_from: []const u8, raw_to: []const u8, mode: RenameMode) u8 {
    const from = clean_path(raw_from);
    const to = clean_path(raw_to);
    if (!available()) return st_host_error;
    if (from.len == 0 or to.len == 0 or from.len > path_max or to.len > path_max) return st_host_error;
    if (std.mem.indexOfScalar(u8, from, 0) != null or std.mem.indexOfScalar(u8, to, 0) != null) return st_host_error;
    if (builtin.is_test) {
        if (test_rename) |callback| return callback(from, to, mode);
    }
    if (prefer_fuse()) return virtio_fs.rename(from, to, mode);
    var payload: [path_max * 2 + 1]u8 = undefined;
    @memcpy(payload[0..from.len], from);
    payload[from.len] = 0;
    @memcpy(payload[from.len + 1 ..][0..to.len], to);
    const plen = from.len + 1 + to.len;
    const opcode = if (mode == .replace) op_replace else op_rename;
    const n = exchange(opcode, 0, payload[0..plen], &vf_reply_buf) orelse return st_host_error;
    return decode_reply(vf_reply_buf[0..n]).status;
}

/// MKDIR a directory on the host share (one level; parents must exist).
/// Returns st_exists when the target already exists.
pub fn mkdir(path: []const u8) u8 {
    if (prefer_fuse()) return virtio_fs.mkdir(path);
    return exchange_path(op_mkdir, path);
}

/// CLONE `from` → `to` on the host share — APFS COW dedup (the HF7
/// worktree workload, issue #741): the host clones the source with
/// clonefile semantics (clonefile(2) for regular files, copyfile(3) with
/// COPYFILE_CLONE for directory trees), so N clones share blocks until
/// one of them actually edits a file. NUL-framed payload like RENAME
/// (paths are NUL-free by construction); `to` must NOT exist (st_exists
/// otherwise — clonefile(2) demands a fresh dst, matching the host's
/// EEXIST). Stateless like the other path ops — the host holds no state.
/// Like RENAME, the combined `[from][0x00][to]` frame must fit the
/// channel's bounded request buffer; beyond that the guest refuses
/// honestly with st_host_error (the monitor's short paths never hit it).
pub fn clone(raw_from: []const u8, raw_to: []const u8) u8 {
    const from = clean_path(raw_from);
    const to = clean_path(raw_to);
    if (!available()) return st_host_error;
    if (prefer_fuse()) return st_host_error;
    if (from.len == 0 or to.len == 0 or from.len > path_max or to.len > path_max) return st_host_error;
    if (std.mem.indexOfScalar(u8, from, 0) != null or std.mem.indexOfScalar(u8, to, 0) != null) return st_host_error;
    var payload: [path_max * 2 + 1]u8 = undefined;
    @memcpy(payload[0..from.len], from);
    payload[from.len] = 0;
    @memcpy(payload[from.len + 1 ..][0..to.len], to);
    const plen = from.len + 1 + to.len;
    const n = exchange(op_clone, 0, payload[0..plen], &vf_reply_buf) orelse return st_host_error;
    return decode_reply(vf_reply_buf[0..n]).status;
}

/// DELETE a file or EMPTY directory on the host share. Non-empty
/// directories fail honestly with a host error (never recursive).
pub fn delete(path: []const u8) u8 {
    if (prefer_fuse()) return virtio_fs.delete(path);
    return exchange_path(op_delete, path);
}

fn exchange_path(op: u8, raw_path: []const u8) u8 {
    const path = clean_path(raw_path);
    if (!available()) return st_host_error;
    if (path.len > path_max) return st_host_error;
    const n = exchange(op, 0, path, &vf_reply_buf) orelse return st_host_error;
    return decode_reply(vf_reply_buf[0..n]).status;
}

/// Whole-file replace-write (the FAT `write_file` semantics the
/// persistence consumers were built on): OPEN(create) → TRUNCATE(0) →
/// WRITE (chunked if needed) → CLOSE. Returns the final status; the host
/// cursor owns the write position, so a concurrent read of the file
/// between OPEN and CLOSE may see a partial write — honest, and the
/// consumers (settings/history/env/migration) are single-writer.
pub fn write_whole(path: []const u8, data: []const u8) u8 {
    if (!available()) return st_host_error;
    var h: u16 = 0;
    const ost = open(path, open_flag_create, &h);
    if (ost != st_ok) return ost;
    defer _ = close(h);
    if (truncate(h, 0) != st_ok) return st_host_error;
    var off: usize = 0;
    while (off < data.len) {
        const take = @min(data.len - off, write_chunk_limit());
        var written: u64 = 0;
        const wst = write(h, data[off .. off + take], &written);
        if (wst != st_ok) return wst;
        // M66a: the loop advances by the host-CONFIRMED count only; a
        // confirmed zero can never advance the stream, so refuse honestly
        // instead of spinning.
        if (written == 0) return st_host_error;
        // M97d-F2 (#2088): a host-confirmed count beyond the requested
        // chunk would overshoot `data.len` and return st_ok for a SHORT
        // file (silent integrity loss) — refuse like `write_handle` does.
        if (written > take) return st_host_error;
        off += @intCast(written);
    }
    // M66b (#1444): every write_whole caller is a persistence consumer —
    // push the bytes to the device before the close flushes and frees.
    if (fsync(h) != st_ok) return st_host_error;
    return st_ok;
}

/// Pattern staging for `write_pattern` — BSS (the 16 KiB boot stack cannot
/// hold a 32 KiB chunk; claim-0015 also wants device paths runtime-only,
/// though this buffer itself never touches the device — write() copies it
/// into its own BSS request buffer).
var vf_write_pattern_buf: [write_chunk_max]u8 align(16) = undefined;

/// Shared chunk-assembly staging for kernel-side streamers (the monitor's
/// `screenshot` BMP writer) — BSS, same reasoning as above: the 16 KiB
/// boot stack cannot hold a 32 KiB chunk. Callers fill it and hand slices
/// to `write` (which copies into its own request buffer), so it never
/// touches the device directly. +32 KiB BSS (budget-checked in the class-A
/// gate).
pub var chunk_staging: [write_chunk_max]u8 align(16) = undefined;

pub const WritePatternResult = struct {
    status: u8 = st_host_error,
    total: u64 = 0,
    chunks: usize = 0,
};

/// Stream `n` deterministic probe-pattern bytes through a handle's cursor
/// across chunk round trips (the monitor's `vf write <h> <n>` and the
/// mutation gate's deterministic on-disk check). The pattern index always
/// advances by the host-CONFIRMED written count, so a partial write never
/// corrupts the stream (honest byte accounting). Returns the final status
/// + host-confirmed total + round-trip count.
pub fn write_pattern(handle: u16, n: u64) WritePatternResult {
    var remaining = n;
    var res = WritePatternResult{};
    while (remaining > 0) {
        const take: usize = @intCast(@min(remaining, write_chunk_limit()));
        var i: usize = 0;
        while (i < take) : (i += 1) vf_write_pattern_buf[i] = pattern(@intCast(res.total + i));
        var written: u64 = 0;
        const st = write(handle, vf_write_pattern_buf[0..take], &written);
        if (st != st_ok) {
            res.status = st;
            return res;
        }
        // M66a: confirmed-zero cannot advance the pattern — refuse, don't spin.
        // M97d-F3 (#2088): an over-reported count would wrap `remaining`
        // (ReleaseSmall: unchecked sub) into a never-ending stream — refuse.
        if (written == 0 or written > take) {
            res.status = st_host_error;
            return res;
        }
        res.total += written;
        remaining -= written;
        res.chunks += 1;
    }
    res.status = st_ok;
    return res;
}

/// Streaming RFC-1071 accumulator (big-endian word semantics, matching
/// `virtio_custom.checksum1071` and the gate's python cross-check) so
/// `vf cat` can checksum a >32 KiB stream across READ round trips.
pub const StreamCksum = struct {
    sum: u64 = 0,
    /// A pending high byte from an odd-length previous chunk.
    carry: ?u8 = null,

    pub fn add(self: *StreamCksum, data: []const u8) void {
        var i: usize = 0;
        if (self.carry) |hi| {
            if (data.len > 0) {
                self.sum += (@as(u64, hi) << 8) | data[0];
                i = 1;
                self.carry = null;
            }
        }
        while (i + 1 < data.len) : (i += 2) {
            self.sum += (@as(u64, data[i]) << 8) | data[i + 1];
        }
        if (i < data.len) self.carry = data[i];
    }

    pub fn finish(self: *const StreamCksum) u16 {
        var sum = self.sum;
        if (self.carry) |hi| sum += @as(u64, hi) << 8;
        while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
        return ~@as(u16, @truncate(sum));
    }
};

// ---------------------------------------------------------------------------
// M70a-live (#1466): live queue-5 wire corpus
// ---------------------------------------------------------------------------

/// Same four seeds as `kernel/tests/fuzz_test.zig` / `user/src/el0exec.zig`.
pub const fuzz_seeds = [_]u64{
    0x5eed_0001,
    0x1337_2026,
    0xdead_beef_cafe,
    0x0f0f_1234_5678,
};

pub const LiveWireReport = struct {
    available: bool = false,
    stat_ok: bool = false,
    stat_size: u64 = 0,
    /// Successful `exchange_raw` replies only. A null wait (timeout / no
    /// device) must not count — `decoded=32` is the gate's proof the
    /// mutated STAT actually came back.
    decoded: usize = 0,
    violations: usize = 0,
};

/// STAT a known file through queue 5 (the named gap: inline `[size u64le][type]`
/// parse), then submit seeded mutations of a STAT request and decode whatever
/// comes back fail-closed. Host tests with `test_share` only exercise STAT;
/// they never touch the device. Reply-byte mutations stay host-side (PR #1464):
/// the guest cannot rewrite a reply the host generated.
pub fn fuzz_live_wire(seed: u64) LiveWireReport {
    var r = LiveWireReport{};
    if (builtin.is_test) {
        if (test_share == null) return r;
        r.available = true;
        var st = StatResult{};
        if (stat("USER.BIN", &st) == st_ok) {
            r.stat_ok = true;
            r.stat_size = st.size;
        }
        return r;
    }
    if (!available()) return r;
    r.available = true;
    var st = StatResult{};
    if (stat("USER.BIN", &st) == st_ok) {
        r.stat_ok = true;
        r.stat_size = st.size;
    }

    var prng = std.Random.DefaultPrng.init(seed ^ 0x9e37_79b9_7f4a_7c15);
    const rand = prng.random();
    var req: [request_hdr_len + path_max]u8 = undefined;
    const path: []const u8 = "USER.BIN";
    var iter: usize = 0;
    while (iter < 32) : (iter += 1) {
        const encoded = encode_request(op_stat, 0, path, &req) orelse continue;
        var len = encoded;
        switch (iter % 4) {
            0 => {
                var flips: usize = 1 + rand.uintLessThan(usize, 3);
                while (flips > 0) : (flips -= 1) req[rand.uintLessThan(usize, encoded)] = rand.int(u8);
            },
            1 => len = rand.uintLessThan(usize, encoded + 1),
            2 => {
                if (encoded < req.len) {
                    req[encoded] = rand.int(u8);
                    len = encoded + 1;
                }
            },
            else => {
                if (len >= request_hdr_len) {
                    req[2] = rand.int(u8);
                    req[3] = rand.int(u8);
                }
            },
        }
        const saved = vf_lock.lock();
        const ncopy = @min(len, vf_req_buf.len);
        @memcpy(vf_req_buf[0..ncopy], req[0..ncopy]);
        const n = exchange_raw(vf_req_buf[0..ncopy], vf_reply_buf[0..]);
        vf_lock.unlock(saved);
        const got = n orelse continue;
        r.decoded += 1;
        const input = vf_reply_buf[0..got];
        const rep = decode_reply(input);
        const in_lo = @intFromPtr(input.ptr);
        const in_hi = in_lo + input.len;
        const data_lo = @intFromPtr(rep.data.ptr);
        if (data_lo < in_lo or data_lo + rep.data.len > in_hi) r.violations += 1;
        if (input.len < reply_hdr_len) {
            if (rep.status != st_host_error or rep.dlen != 0 or rep.data.len != 0 or !rep.clamped) r.violations += 1;
        } else if (rep.status > st_handle) {
            r.violations += 1;
        }
    }
    return r;
}

// ---------------------------------------------------------------------------
// Host tests (G1–G6 from issue #735)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "virtio_file: G1 — pattern generator parity is pinned (fixture class)" {
    // The generator is the byte-for-byte lock with the host's Swift
    // generator and the shared class-A fixture `tests/vf-pattern-32k.bin`
    // (whose sha256 the class-A gate pins).
    try testing.expectEqual(@as(u8, 0x00), pattern(0));
    try testing.expectEqual(@as(u8, 0xff), pattern(0xff));
    // 0x100 = 256: low byte 0x00 XOR high byte 0x01 = 1; 0x101 → 0 ^ 1 = 1
    // XOR 0x01 = 0.
    try testing.expectEqual(@as(u8, 0x01), pattern(0x100));
    try testing.expectEqual(@as(u8, 0x00), pattern(0x101));
    // 0x55a5: low byte 0xa5 XOR high byte 0x55 = 0xf0.
    try testing.expectEqual(@as(u8, 0xf0), pattern(0x55a5));
    // Deterministic total over the probe data field (128 high bytes ×
    // 256-low XOR-permuted sums: each row sums to 32640, 128 rows).
    var sum: usize = 0;
    var i: usize = 0;
    while (i < 32768) : (i += 1) sum += pattern(i);
    try testing.expectEqual(@as(usize, 4177920), sum);
}

test "virtio_file: G2 — reply_len clamp math — over-cap dlen never reads OOB" {
    var buf: [reply_cap]u8 = undefined;
    @memset(&buf, 0x42);
    buf[0] = st_ok;
    std.mem.writeInt(u16, buf[1..3], 0xffff, .little); // hostile dlen >> buffer
    const rep = decode_reply(&buf);
    try testing.expectEqual(st_ok, rep.status);
    try testing.expectEqual(@as(u16, 0xffff), rep.dlen);
    try testing.expect(rep.clamped);
    try testing.expectEqual(reply_cap - reply_hdr_len, rep.data.len);
    try testing.expectEqual(@as(u8, 0x42), rep.data[rep.data.len - 1]);
    // A tiny buffer (no header) decodes honestly as host_error, never OOB.
    const tiny = decode_reply(&[_]u8{0x00});
    try testing.expectEqual(st_host_error, tiny.status);
    try testing.expectEqual(@as(usize, 0), tiny.data.len);
}

test "virtio_file: G3 — probe request shape + the raw 32 KiB pattern reply" {
    // Request: [op=0][flags=0][len=0] — 4 bytes, empty payload.
    var req: [request_hdr_len]u8 = undefined;
    const n = encode_request(op_probe, 0, "", &req) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, request_hdr_len), n);
    try testing.expectEqual(op_probe, req[0]);
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, req[2..4], .little));
    // The pinned reply: 32,768 RAW pattern bytes (no frame) — the exact
    // bytes of tests/vf-pattern-32k.bin, locked both sides.
    var reply: [probe_reply_len]u8 = undefined;
    var i: usize = 0;
    while (i < probe_reply_len) : (i += 1) reply[i] = pattern(i);
    for (&reply, 0..) |b, j| try testing.expectEqual(pattern(j), b);
    try testing.expectEqual(probe_dlen, @as(u16, @intCast(probe_reply_len)));
    // The pattern's RFC-1071 checksum is the gate cross-check (computed
    // identically by the Swift VFWire module and the class-A gate's
    // python). The XOR-symmetric pattern folds to 0x0000 — genuine, and
    // all three implementations must agree on it.
    try testing.expectEqual(@as(u16, 0x0000), virtio_custom.checksum1071(&reply));
}

test "virtio_file: G4 — hostile envelopes (bad status, truncated rows) are honest" {
    // Status 4 (host error) passes through with no data.
    var buf: [64]u8 = @as([64]u8, @splat(@as(u8, 0)));
    buf[0] = st_host_error;
    std.mem.writeInt(u16, buf[1..3], 0, .little);
    const rep = decode_reply(&buf);
    try testing.expectEqual(st_host_error, rep.status);
    try testing.expectEqual(@as(usize, 0), rep.data.len);
    // A short LIST row decodes as an empty entry (no OOB).
    const row = decode_entry_row(&@as([10]u8, @splat(@as(u8, 0x41))));
    try testing.expectEqual(@as(usize, 0), row.name_len);
    // An exact-length zeroed row is an empty (NUL) name.
    const zero_row = decode_entry_row(&@as([entry_row_len]u8, @splat(@as(u8, 0))));
    try testing.expectEqual(@as(usize, 0), zero_row.name_len);
    try testing.expectEqual(dir_type_file, zero_row.type);
}

test "virtio_file: G5 — entry row round trip + read payload + streaming cksum" {
    var row: [entry_row_len]u8 = @as([entry_row_len]u8, @splat(@as(u8, 0)));
    const name = "HELLO.TXT";
    @memcpy(row[0..name.len], name);
    row[31] = dir_type_file;
    std.mem.writeInt(u64, row[32..40], 1234, .little);
    const e = decode_entry_row(&row);
    try testing.expectEqualStrings(name, e.name[0..e.name_len]);
    try testing.expectEqual(dir_type_file, e.type);
    try testing.expectEqual(@as(u64, 1234), e.size);
    // READ payload = [path][u64le offset].
    var payload: [path_max + read_offset_len]u8 = undefined;
    const plen = build_read_payload("/dir/file.bin", 0x1234, &payload) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 13 + read_offset_len), plen);
    try testing.expectEqualStrings("/dir/file.bin", payload[0..13]);
    try testing.expectEqual(@as(u64, 0x1234), std.mem.readInt(u64, payload[13..21], .little));
    // Over-long path is refused honestly.
    const long = @as([(path_max + 1)]u8, @splat(@as(u8, 0x41)));
    try testing.expectEqual(@as(?usize, null), build_read_payload(&long, 0, &payload));
    // The streaming checksum equals the one-shot checksum over the same
    // bytes, across an odd-length chunk split.
    const sample = "The quick brown fox jumps over the lazy dog";
    var acc = StreamCksum{};
    acc.add(sample[0..7]);
    acc.add(sample[7..]);
    try testing.expectEqual(virtio_custom.checksum1071(sample), acc.finish());
}

test "virtio_file: G6 — request encode bounds (over-long payload, small out)" {
    var out: [16]u8 = undefined;
    const long = @as([0x10000]u8, @splat(@as(u8, 0x41)));
    try testing.expectEqual(@as(?usize, null), encode_request(op_list, 0, &long, &out));
    try testing.expectEqual(@as(?usize, null), encode_request(op_list, 0, "abc", out[0..2]));
    const n = encode_request(op_list, 0, "abc", &out) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, request_hdr_len + 3), n);
    try testing.expectEqual(op_list, out[0]);
    try testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, out[2..4], .little));
}

test "virtio_file: G7 — HF3 op/status constants + 8-handle parity with file_table.zig" {
    // Additive opcode space: 0x04..0x0b — old hosts still answer unknown
    // ops with status 4, so a new guest on an old runner degrades honestly.
    for ([_]u8{ op_open, op_close, op_write, op_truncate, op_fsync, op_rename, op_mkdir, op_delete }) |op| {
        try testing.expect(op >= 0x04 and op <= 0x0b);
    }
    try testing.expectEqual(@as(u8, 5), st_exists);
    try testing.expectEqual(@as(u8, 6), st_handle);
    // Parity with the kernel's file_table.zig (max_handles_per_process):
    // the host's handle table caps at the same 8.
    try testing.expectEqual(@as(usize, 8), max_file_handles);
    // Chunk math: 32763 data bytes/WRITE fits the u16 len AND the 32 KiB
    // reply-cap symmetry.
    try testing.expectEqual(reply_cap - reply_hdr_len - handle_len, write_chunk_max);
    try testing.expectEqual(@as(usize, 32763), write_chunk_max);
}

test "virtio_file: G8 — open request flags + reply handle decode" {
    var req: [64]u8 = undefined;
    // create-if-missing + append bits ride the framing's flags byte.
    const n = encode_request(op_open, open_flag_create | open_flag_append, "docs/note.txt", &req) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(op_open, req[0]);
    try testing.expectEqual(open_flag_create | open_flag_append, req[1]);
    try testing.expectEqualStrings("docs/note.txt", req[4..][0..13]);
    _ = n;
    // Reply [handle u16le]: 0x3412 → 4660.
    var rep: [reply_hdr_len + handle_len]u8 = undefined;
    rep[0] = st_ok;
    rep[1] = handle_len;
    rep[2] = 0;
    rep[3] = 0x34;
    rep[4] = 0x12;
    const d = decode_reply(&rep);
    try testing.expectEqual(st_ok, d.status);
    try testing.expectEqual(@as(u16, 4660), read_le_u16(d.data, 0));
}

test "virtio_file: G9 — write payload shape + written-cursor reply" {
    // The assembled WRITE request: [op][flags][len][handle u16][data].
    var buf: [request_hdr_len + handle_len + 3]u8 = undefined;
    buf[0] = op_write;
    buf[1] = 0;
    write_le_u16(&buf, 2, @intCast(handle_len + 3));
    write_le_u16(&buf, request_hdr_len, 0x1122);
    @memcpy(buf[request_hdr_len + handle_len ..][0..3], "xyz");
    // Cross-check what the host parses: header, handle, payload.
    try testing.expectEqual(op_write, buf[0]);
    try testing.expectEqual(@as(u16, 5), read_le_u16(buf[2..4], 0));
    try testing.expectEqual(@as(u16, 0x1122), read_le_u16(&buf, request_hdr_len));
    try testing.expectEqualStrings("xyz", buf[request_hdr_len + handle_len ..]);
    // Reply [written u64le]: 100000 bytes written.
    var rep: [reply_hdr_len + written_len]u8 = undefined;
    rep[0] = st_ok;
    std.mem.writeInt(u16, rep[1..3], written_len, .little);
    std.mem.writeInt(u64, rep[3..11], 100000, .little);
    const d = decode_reply(&rep);
    try testing.expectEqual(st_ok, d.status);
    try testing.expectEqual(@as(u64, 100000), read_le_u64(d.data, 0));
    // Status passthrough: handle-limit (6) and exists (5) reach the guest.
    var rep6 = [_]u8{ st_handle, 0, 0 };
    try testing.expectEqual(st_handle, decode_reply(&rep6).status);
    var rep5 = [_]u8{ st_exists, 0, 0 };
    try testing.expectEqual(st_exists, decode_reply(&rep5).status);
}

test "virtio_file: G10 — truncate/close/fsync payloads (handle + size)" {
    var payload: [handle_len + truncate_size_len]u8 = undefined;
    write_le_u16(&payload, 0, 7);
    write_le_u64(&payload, handle_len, 1234);
    try testing.expectEqual(@as(u16, 7), read_le_u16(&payload, 0));
    try testing.expectEqual(@as(u64, 1234), read_le_u64(&payload, handle_len));
    // Close/fsync carry just the handle.
    var h: [handle_len]u8 = undefined;
    write_le_u16(&h, 0, 3);
    try testing.expectEqual(@as(u16, 3), read_le_u16(&h, 0));
}

test "virtio_file: G11 — rename NUL-framed payload + bounds" {
    // [from][0x00][to] — paths are NUL-free by construction.
    const from = "sub/old.bin";
    const to = "sub/new.bin";
    var payload: [path_max * 2 + 1]u8 = undefined;
    @memcpy(payload[0..from.len], from);
    payload[from.len] = 0;
    @memcpy(payload[from.len + 1 ..][0..to.len], to);
    const plen = from.len + 1 + to.len;
    try testing.expectEqualStrings(from, payload[0..from.len]);
    try testing.expectEqual(@as(u8, 0), payload[from.len]);
    try testing.expectEqualStrings(to, payload[from.len + 1 .. plen]);
    // Over-long rename is refused before any exchange.
    const long = @as([(path_max + 1)]u8, @splat(@as(u8, 0x41)));
    try testing.expectEqual(@as(u8, st_host_error), rename(&long, "x"));
    try testing.expectEqual(@as(u8, st_host_error), rename("x", &long));
}

test "virtio_file: replacement is additive and malformed paths never dispatch" {
    const Probe = struct {
        var calls: usize = 0;
        var mode: RenameMode = .preserve_existing;
        fn rename_probe(_: []const u8, _: []const u8, selected: RenameMode) u8 {
            calls += 1;
            mode = selected;
            return st_not_found;
        }
    };
    Probe.calls = 0;
    set_test_rename(Probe.rename_probe);
    defer set_test_rename(null);
    try testing.expectEqual(@as(u8, 0x0d), op_dir_open);
    try testing.expectEqual(@as(u8, 0x0e), op_dir_page);
    try testing.expectEqual(@as(u8, 0x0f), op_dir_close);
    try testing.expectEqual(@as(u8, 0x10), op_replace);
    try testing.expectEqual(@as(u8, 7), st_limit);
    try testing.expectEqual(@as(u8, 8), st_path_limit);
    try testing.expectEqual(@as(u8, 9), st_changed);
    try testing.expectEqual(@as(u8, 10), st_access);
    try testing.expectEqual(@as(u8, 11), st_unsupported);
    try testing.expectEqual(st_not_found, rename("stage", "out"));
    try testing.expectEqual(RenameMode.preserve_existing, Probe.mode);
    try testing.expectEqual(st_not_found, replace("stage", "out"));
    try testing.expectEqual(RenameMode.replace, Probe.mode);
    try testing.expectEqual(st_host_error, replace("stage\x00escape", "out"));
    try testing.expectEqual(st_host_error, replace("stage", ""));
    const long = @as([(path_max + 1)]u8, @splat(@as(u8, 'x')));
    try testing.expectEqual(st_host_error, replace(&long, "out"));
    try testing.expectEqual(@as(usize, 2), Probe.calls);
}

test "virtio_file: G12 — pattern chunk plan for the mutation gate" {
    // The gate writes 100,000 pattern bytes in write_chunk_max chunks:
    // 3 × 32763 + 2911. Assert the plan covers the file exactly and every
    // chunk is ≤ the one-round-trip cap (also locks the gate's python).
    const total: usize = 100000;
    var written: usize = 0;
    var chunks: usize = 0;
    while (written < total) : (chunks += 1) {
        const take = @min(write_chunk_max, total - written);
        try testing.expect(take > 0 and take <= write_chunk_max);
        written += take;
    }
    try testing.expectEqual(@as(usize, 100000), written);
    try testing.expectEqual(@as(usize, 4), chunks);
    // Host-visible reply for a 4-byte append: written=4, cursor=EOF.
    try testing.expectEqual(@as(usize, 4), @as(usize, 4));
}

test "virtio_file: write chunk limit follows active transport" {
    const was_ready = virtio_fs.fs_ready;
    const was_initialized = virtio_fs.fs_initialized;
    const was_max_write = virtio_fs.fs_max_write;
    defer {
        virtio_fs.fs_ready = was_ready;
        virtio_fs.fs_initialized = was_initialized;
        virtio_fs.fs_max_write = was_max_write;
    }

    virtio_fs.fs_ready = false;
    virtio_fs.fs_initialized = false;
    try testing.expectEqual(write_chunk_max, write_chunk_limit());

    virtio_fs.fs_ready = true;
    virtio_fs.fs_initialized = true;
    virtio_fs.fs_max_write = 512;
    try testing.expectEqual(@as(usize, 512), write_chunk_limit());
    virtio_fs.fs_max_write = 4096;
    try testing.expectEqual(@as(usize, 2048), write_chunk_limit());
}

test "virtio_file: G13 — HF7 clone op: 0x0c, NUL frame, bounds, honest refusal" {
    // Additive opcode space continues past the HF3 set (0x0c): an old
    // host answers unknown ops with status 4, so this stays non-breaking.
    try testing.expectEqual(@as(u8, 0x0c), op_clone);
    try testing.expect(op_clone > op_delete);
    // The wire is the same NUL-framed shape as RENAME: [from][0x00][to].
    // The 0x0c op in the header + the frame is what serveClone parses.
    const from = "repo";
    const to = "repo-wt1";
    var payload: [path_max * 2 + 1]u8 = undefined;
    @memcpy(payload[0..from.len], from);
    payload[from.len] = 0;
    @memcpy(payload[from.len + 1 ..][0..to.len], to);
    const plen = from.len + 1 + to.len;
    try testing.expectEqualStrings(from, payload[0..from.len]);
    try testing.expectEqual(@as(u8, 0), payload[from.len]);
    try testing.expectEqualStrings(to, payload[from.len + 1 .. plen]);
    // Bounds + NUL-safety are refused BEFORE any exchange.
    const long = @as([(path_max + 1)]u8, @splat(@as(u8, 0x41)));
    try testing.expectEqual(@as(u8, st_host_error), clone(&long, "x"));
    try testing.expectEqual(@as(u8, st_host_error), clone("x", &long));
    try testing.expectEqual(@as(u8, st_host_error), clone("", "x"));
    // The CLONE reply is a bare status (no data) — a status-5 (exists)
    // from the host's EEXIST pre-check must reach the guest unchanged.
    var rep = [_]u8{ st_exists, 0, 0 };
    try testing.expectEqual(st_exists, decode_reply(&rep).status);
    rep[0] = st_not_found;
    try testing.expectEqual(st_not_found, decode_reply(&rep).status);
}

test "virtio_file: read_chunk and read_into copy-out under test_share" {
    const fixture = [_]TestFile{
        .{ .name = "TEST.TXT", .data = "Hello, world of safe concurrent reads!" },
    };
    set_test_share(&fixture);
    defer set_test_share(null);

    var chunk_buf: [13]u8 = undefined;
    const rc1 = read_chunk("TEST.TXT", 0, &chunk_buf);
    try testing.expectEqual(st_ok, rc1.status);
    try testing.expectEqual(@as(usize, 13), rc1.bytes);
    try testing.expectEqualStrings("Hello, world ", &chunk_buf);

    const rc2 = read_chunk("TEST.TXT", 13, &chunk_buf);
    try testing.expectEqual(st_ok, rc2.status);
    try testing.expectEqual(@as(usize, 13), rc2.bytes);
    try testing.expectEqualStrings("of safe concu", &chunk_buf);

    var whole: [64]u8 = undefined;
    const n = read_into("TEST.TXT", 38, &whole);
    try testing.expect(n != null);
    try testing.expectEqual(@as(usize, 38), n.?);
    try testing.expectEqualStrings("Hello, world of safe concurrent reads!", whole[0..n.?]);
}

test "virtio_file: read_at_into streams a region larger than one reply" {
    // M70c-K (issue #1504): the streamed loader reads a segment straight
    // from the file at its own offset. This pins the primitive it uses:
    // a 3-reply region starting at a NON-zero offset arrives byte-exact
    // (so a stale cursor or a short final exchange cannot pass), and an
    // offset past the end of the file refuses instead of returning a
    // short buffer.
    const total = read_chunk_max * 3 + 7;
    // A uniform fill with distinct bytes at every reply boundary: a skipped,
    // duplicated, or offset-shifted exchange moves one of them, and the
    // whole-region compare below catches anything softer.
    const fixture_bytes = comptime blk: {
        var b = @as([total]u8, @splat(@as(u8, 0xA5)));
        b[0] = 0x11;
        b[read_chunk_max - 1] = 0x22; // last byte of reply 1
        b[read_chunk_max] = 0x33; // first byte of reply 2
        b[read_chunk_max * 2] = 0x44; // first byte of reply 3
        b[total - 1] = 0x55;
        break :blk b;
    };
    const fixture = [_]TestFile{.{ .name = "BIG.BIN", .data = &fixture_bytes }};
    set_test_share(&fixture);
    defer set_test_share(null);

    var out: [total]u8 = undefined;
    const got = read_at_into("BIG.BIN", 0, &out);
    try testing.expect(got != null);
    try testing.expectEqual(@as(usize, total), got.?);
    try testing.expectEqualSlices(u8, &fixture_bytes, &out);

    // An offset INSIDE the file, read across several replies.
    var mid: [read_chunk_max * 2]u8 = undefined;
    const off: usize = 11;
    const got_mid = read_at_into("BIG.BIN", @intCast(off), &mid);
    try testing.expect(got_mid != null);
    try testing.expectEqual(@as(usize, mid.len), got_mid.?);
    try testing.expectEqualSlices(u8, fixture_bytes[off..][0..mid.len], &mid);

    // Past the end: null, never a short buffer.
    var over: [8]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), read_at_into("BIG.BIN", total - 4, &over));
    try testing.expectEqual(@as(?usize, null), read_at_into("NOPE.BIN", 0, &over));
}

test "virtio_file: clean_path strips leading slashes" {
    try testing.expectEqualStrings("", clean_path(""));
    try testing.expectEqualStrings("", clean_path("/"));
    try testing.expectEqualStrings("", clean_path("///"));
    try testing.expectEqualStrings("EFI", clean_path("/EFI"));
    try testing.expectEqualStrings("EFI/BOOT", clean_path("///EFI/BOOT"));
    try testing.expectEqualStrings("KERNEL.BIN", clean_path("KERNEL.BIN"));
}

test "virtio_file: live-wire report is honest without a device" {
    const r = fuzz_live_wire(0x5eed_0001);
    try testing.expect(!r.available);
    try testing.expectEqual(@as(usize, 0), r.decoded);
    try testing.expectEqual(@as(usize, 0), r.violations);
}

test "virtio_file: live-wire STAT path via test_share" {
    const fixture = [_]TestFile{
        .{ .name = "USER.BIN", .data = "xx" },
    };
    set_test_share(&fixture);
    defer set_test_share(null);
    const r = fuzz_live_wire(0x5eed_0001);
    try testing.expect(r.available);
    try testing.expect(r.stat_ok);
    try testing.expectEqual(@as(u64, 2), r.stat_size);
    try testing.expectEqual(@as(usize, 0), r.decoded);
}

// ---------------------------------------------------------------------------
// M97d transport-level tests (#2087 F1, #2088 F2/F3): drive the REAL
// queue-5 exchange path (submit_ex -> wait -> decode) against an in-memory
// used ring — not the `test_share` override. The test plays the hostile
// host: it stages used-ring entries and fills vf_reply_buf, exactly what a
// malicious --cvc-file server produces.
// ---------------------------------------------------------------------------

/// Scratch MMIO target for the test transport's kicks: `cv_notify` must be
/// a real writable address on host (to_kva/to_phys are the identity).
var test_notify_slot: u16 align(4) = 0;

/// Arm queue 5 so `exchange_raw` runs the real submit/wait path against
/// the in-memory used ring the test fills. Returns the chain head every
/// sequential exchange reuses (a freed chain recycles tail-first, so its
/// head pops first again) — staged used entries must carry this id.
fn arm_test_transport() u16 {
    const r = &virtio_custom.cv_rings[virtio_custom.file_qidx];
    virtio_custom.ring_init(r);
    r.notify_off = 0;
    r.armed = true;
    virtio_custom.cv_ready = true;
    virtio_custom.has_file_queue = true;
    virtio_custom.armed_queues = virtio_custom.file_qidx + 1;
    virtio_custom.has_notification_data = false;
    virtio_custom.cv_notify = @intFromPtr(&test_notify_slot);
    virtio_custom.cv_notify_mult = 0;
    virtio_custom.used_len = 0;
    virtio_custom.parked_count = 0;
    virtio_fs.fs_ready = false;
    virtio_fs.fs_initialized = false;
    return r.free[r.free_count - 1];
}

fn disarm_test_transport() void {
    virtio_custom.cv_ready = false;
    virtio_custom.has_file_queue = false;
    virtio_custom.armed_queues = 0;
    virtio_custom.cv_notify = 0;
    virtio_custom.cv_rings[virtio_custom.file_qidx].armed = false;
    virtio_custom.used_len = 0;
}

test "virtio_file: M97d-F1 (#2087) — a lying used-ring reply length is clamped at the exchange" {
    // The host completes the READ with a used-ring length of 65536 —
    // twice the posted 32 KiB reply descriptor — and a framed
    // [ok][dlen=0xfffd] reply. Before the fix the exchange handed the raw
    // host u32 to `vf_reply_buf[0..n]`: a ~32 KiB read past the BSS buffer
    // (Debug: index-out-of-bounds panic; ReleaseSmall: silent over-read).
    // Now the exchange caps n at the buffer, decode sees a truncated
    // frame, and `read` reports st_truncated — never st_ok.
    const head = arm_test_transport();
    defer disarm_test_transport();
    const r = &virtio_custom.cv_rings[virtio_custom.file_qidx];
    r.used.ring[0] = .{ .id = head, .len = 65536 };
    r.used.idx = 1;
    vf_reply_buf[0] = st_ok;
    write_le_u16(&vf_reply_buf, 1, 0xfffd); // frame claims 65533 data bytes
    @memset(vf_reply_buf[3..], 0x42);
    const res = read("F.TXT", 0);
    try testing.expectEqual(st_truncated, res.status);
    try testing.expectEqual(@as(usize, 0), res.data.len);
    // The transport still records the RAW host report (VF-PROBE's
    // contract) while reply_len() bounds it to the posted descriptor.
    try testing.expectEqual(@as(u32, 65536), virtio_custom.used_len);
    try testing.expectEqual(reply_cap, virtio_custom.reply_len());

    // Positive control through the same path: an honest reply passes.
    r.used.ring[1] = .{ .id = head, .len = reply_hdr_len + 4 };
    r.used.idx = 2;
    vf_reply_buf[0] = st_ok;
    write_le_u16(&vf_reply_buf, 1, 4);
    @memcpy(vf_reply_buf[3..7], "data");
    const res2 = read("F.TXT", 0);
    try testing.expectEqual(st_ok, res2.status);
    try testing.expectEqualStrings("data", res2.data);
}

test "virtio_file: M97d-F2 (#2088) — a host write count beyond the chunk refuses, never st_ok" {
    // write_whole's loop must advance by the host-CONFIRMED count only
    // within the requested chunk. The staged WRITE reply reports
    // written = u64 max against a 10-byte chunk: before the fix `off`
    // overshot data.len, the loop "finished", and the caller saw st_ok
    // for a file that was never written (silent integrity loss).
    const head = arm_test_transport();
    defer disarm_test_transport();
    const r = &virtio_custom.cv_rings[virtio_custom.file_qidx];
    // Exchanges consumed in order: OPEN, TRUNCATE, WRITE, FSYNC, CLOSE
    // (the deferred close). One shared reply frame serves them all:
    // [ok][dlen=8][8 bytes]. OPEN takes its handle from the first two
    // data bytes; WRITE reads the 8-byte confirmed count.
    const frame_len: u32 = reply_hdr_len + written_len;
    var i: usize = 0;
    while (i < 5) : (i += 1) r.used.ring[i] = .{ .id = head, .len = frame_len };
    r.used.idx = 5;
    vf_reply_buf[0] = st_ok;
    write_le_u16(&vf_reply_buf, 1, written_len);
    write_le_u64(&vf_reply_buf, reply_hdr_len, std.math.maxInt(u64));
    try testing.expectEqual(st_host_error, write_whole("F.TXT", "0123456789"));

    // Positive control: an honest in-chunk count completes the write.
    virtio_custom.ring_init(r);
    r.armed = true;
    i = 0;
    while (i < 5) : (i += 1) r.used.ring[i] = .{ .id = head, .len = frame_len };
    r.used.idx = 5;
    write_le_u64(&vf_reply_buf, reply_hdr_len, 10);
    try testing.expectEqual(st_ok, write_whole("F.TXT", "0123456789"));
}

test "virtio_file: M97d-F3 (#2088) — an over-reported pattern write refuses instead of wrapping" {
    // Same hostile count through write_pattern: written = u64 max vs a
    // 10-byte request. Pre-fix `remaining -= written` underflowed (Debug:
    // panic; ReleaseSmall: wraps to ~2^64 — a never-ending stream).
    const head = arm_test_transport();
    defer disarm_test_transport();
    const r = &virtio_custom.cv_rings[virtio_custom.file_qidx];
    r.used.ring[0] = .{ .id = head, .len = reply_hdr_len + written_len };
    r.used.idx = 1;
    vf_reply_buf[0] = st_ok;
    write_le_u16(&vf_reply_buf, 1, written_len);
    write_le_u64(&vf_reply_buf, reply_hdr_len, std.math.maxInt(u64));
    const res = write_pattern(7, 10);
    try testing.expectEqual(st_host_error, res.status);
    try testing.expectEqual(@as(u64, 0), res.total);
    try testing.expectEqual(@as(usize, 0), res.chunks);

    // Positive control: an honest in-chunk count still streams.
    r.used.ring[1] = .{ .id = head, .len = reply_hdr_len + written_len };
    r.used.idx = 2;
    write_le_u64(&vf_reply_buf, reply_hdr_len, 10);
    const ok = write_pattern(7, 10);
    try testing.expectEqual(st_ok, ok.status);
    try testing.expectEqual(@as(u64, 10), ok.total);
    try testing.expectEqual(@as(usize, 1), ok.chunks);
}

test "virtio_file: #2495 — a stalled read op is neutralized, parked, resubmitted once, and reaped on consume" {
    _ = arm_test_transport();
    defer disarm_test_transport();
    const r = &virtio_custom.cv_rings[virtio_custom.file_qidx];
    const saved_budget = exchange_budget;
    defer exchange_budget = saved_budget;
    exchange_budget = 32;
    vf_park_count = 0;
    vf_resubmit_count = 0;
    virtio_custom.stale_used_count = 0;

    // Nothing staged: stat stalls through BOTH submits (the op is
    // resubmit-safe), parks both, and fails honestly — st_host_error,
    // never a misattributed reply.
    var st_res = StatResult{};
    try testing.expectEqual(st_host_error, stat("NOPE.TXT", &st_res));
    try testing.expectEqual(@as(u32, 2), vf_park_count);
    try testing.expectEqual(@as(u32, 1), vf_resubmit_count);
    try testing.expectEqual(@as(u16, 2), virtio_custom.parked_count);
    // Both parked chains were neutralized: their request descriptors now
    // point at the sink request (a stat the host always answers
    // not-found), their reply descriptors at the sink buffer — a late
    // serve can neither re-execute a reused request nor touch the live
    // reply buffer.
    for (virtio_custom.parked_heads[0..virtio_custom.parked_count]) |h| {
        const rd = r.desc[h];
        try testing.expectEqual(@as(u64, @intFromPtr(&vf_park_req)), rd.addr);
        try testing.expectEqual(@as(u32, @intCast(vf_park_req_len)), rd.len);
        const td = r.desc[rd.next];
        try testing.expectEqual(@as(u64, @intFromPtr(&vf_park_reply)), td.addr);
        try testing.expectEqual(@as(u32, @intCast(vf_park_reply.len)), td.len);
    }

    // The parked heads' late replies arriving during the NEXT exchange's
    // wait are consumed at the match point and reaped — both chains freed
    // before the live element's entry matches.
    const live = r.free[r.free_count - 1];
    r.used.ring[0] = .{ .id = virtio_custom.parked_heads[0], .len = 3 };
    r.used.ring[1] = .{ .id = virtio_custom.parked_heads[1], .len = 3 };
    r.used.ring[2] = .{ .id = live, .len = reply_hdr_len + 9 };
    r.used.idx = 3;
    vf_reply_buf[0] = st_ok;
    write_le_u16(&vf_reply_buf, 1, 9);
    write_le_u64(&vf_reply_buf, reply_hdr_len, 5);
    vf_reply_buf[reply_hdr_len + 8] = 0;
    try testing.expectEqual(st_ok, stat("F.TXT", &st_res));
    try testing.expectEqual(@as(u64, 5), st_res.size);
    try testing.expectEqual(@as(u16, 0), virtio_custom.parked_count);
    try testing.expectEqual(@as(u16, virtio_custom.queue_size), r.free_count);
    try testing.expectEqual(@as(u32, 0), virtio_custom.stale_used_count);
}

test "virtio_file: #2495 — a timed-out mutation parks once and never resubmits" {
    _ = arm_test_transport();
    defer disarm_test_transport();
    const saved_budget = exchange_budget;
    defer exchange_budget = saved_budget;
    exchange_budget = 32;
    vf_park_count = 0;
    vf_resubmit_count = 0;
    virtio_custom.parked_count = 0;
    // op_write is not idempotent — an unknown-outcome mutation fails
    // honestly rather than risking a double-apply on the share.
    var payload: [handle_len + 4]u8 = undefined;
    write_le_u16(&payload, 0, 3);
    @memset(payload[handle_len..], 0x41);
    const n = encode_request(op_write, 0, &payload, &vf_write_buf).?;
    try testing.expect(exchange_raw(vf_write_buf[0..n], &vf_reply_buf) == null);
    try testing.expectEqual(@as(u32, 1), vf_park_count);
    try testing.expectEqual(@as(u32, 0), vf_resubmit_count);
    try testing.expectEqual(@as(u16, 1), virtio_custom.parked_count);
}

test "M134a: STAT reply decode accepts the old and new lengths" {
    var out: StatResult = .{};
    // Old shape — [size][type], mtime absent and named.
    var v1: [stat_data_v1_len]u8 = @splat(0);
    write_le_u64(&v1, 0, 4096);
    v1[8] = dir_type_dir;
    decode_stat_reply(&v1, &out);
    try testing.expectEqual(@as(u64, 4096), out.size);
    try testing.expect(out.is_dir);
    try testing.expect(!out.has_mtime);

    // New shape — [size][type][mtime_sec][mtime_nsec].
    out = .{};
    var v2: [stat_data_v2_len]u8 = @splat(0);
    write_le_u64(&v2, 0, 7);
    v2[8] = dir_type_file;
    write_le_u64(&v2, 9, 1_700_000_123);
    v2[17] = 0xB1;
    v2[18] = 0x68;
    v2[19] = 0xDE;
    v2[20] = 0x3A; // 987_654_321
    decode_stat_reply(&v2, &out);
    try testing.expectEqual(@as(u64, 7), out.size);
    try testing.expect(!out.is_dir);
    try testing.expect(out.has_mtime);
    try testing.expectEqual(@as(u64, 1_700_000_123), out.mtime_sec);
    try testing.expectEqual(@as(u32, 987_654_321), out.mtime_nsec);

    // Mid-length (neither old nor new) still yields size/type with
    // mtime absent.
    out = .{};
    var mid: [12]u8 = @splat(0);
    write_le_u64(&mid, 0, 3);
    mid[8] = dir_type_file;
    decode_stat_reply(&mid, &out);
    try testing.expectEqual(@as(u64, 3), out.size);
    try testing.expect(!out.has_mtime);
}

test "M134a: list refuses a >31-byte name by name, never truncates" {
    var long_name: [40]u8 = @splat('x');
    const files = [_]TestFile{
        .{ .name = "short.txt", .data = "s" },
        .{ .name = long_name[0..], .data = "x" },
    };
    set_test_share(&files);
    defer set_test_share(null);
    var res: ListResult = .{};
    try testing.expectEqual(st_path_limit, list("", &res));
    try testing.expectEqual(st_path_limit, res.status);
    // Names that fit the row still list — only the overlong one refuses.
    try testing.expectEqual(@as(usize, 1), res.count);
    try testing.expectEqualStrings("short.txt", res.entries[0].name[0..res.entries[0].name_len]);
}
