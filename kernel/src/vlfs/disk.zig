//! disk.zig — VLFS mount state and the `/disk` partition glue (M100c, #2308).
//!
//! `vlfs.zig` is the pure format reader; this module owns the one mounted
//! volume: the `SectorSource`, the validated `Volume`, and the per-mount
//! epoch that becomes `fs_metadata` `identity.filesystem`.
//!
//! **The attach seam.** `attach(src)` is the single entry point — ADR 0050
//! D1/D6: the M100b virtio-blk driver calls it after the `virelai-vlfs`
//! GET_ID match. A mount failure latches the ADR refusal name in
//! `last_refusal` and leaves `.disk` unmounted; the boot continues
//! share-only by construction (nothing else consults the mount). With no
//! data-disk device attached, nothing calls attach and `/disk` paths refuse
//! `not_mounted` (ENOENT on the wire).
//!
//! **fs_metadata (slot 79).** VLFS supplies a real `ContainedOps` backend
//! (ADR D6): a pin token is the inode number, `identity` is
//! (mount epoch, inode). The v1 volume is read-only — mutations return
//! `AccessDenied` until the M100d write path owns them. Because nothing can
//! mutate the volume while it is mounted, an inode-number pin cannot dangle;
//! M100d must revisit pins once deletes can recycle inode numbers.

const std = @import("std");
const vlfs = @import("vlfs.zig");
const metadata = @import("../fs_metadata.zig");

const Mount = struct {
    src: vlfs.SectorSource,
    vol: vlfs.Volume,
    epoch: u64,
};

var active: ?Mount = null;
var epoch_ctr: u64 = 0;
/// The ADR refusal name of the last failed attach (static text), for the
/// boot log. null when the last attach succeeded or none ran.
pub var last_refusal: ?[]const u8 = null;

/// One shared 4 KiB block scratch for every `/disk` path op. The file ABI
/// runs under the `.file` service-domain lock (syscall.zig), so concurrent
/// callers cannot tear it.
var block_scratch: [vlfs.block_len]u8 align(64) = undefined;

/// Contained-open file handles minted by the fs_metadata backend (op 2).
/// Plain slot-23 opens on `/disk` stay stateless in file_table and never
/// land here. v1 bound: 8, matching the per-process handle table.
const contained_max = 8;
const ContainedFile = struct {
    used: bool = false,
    ino: u32 = 0,
    cursor: u64 = 0,
    epoch: u64 = 0,
};
var contained_files: [contained_max]ContainedFile = @splat(.{});

/// Attach and mount a VLFS volume. Returns true on success; on refusal the
/// named reason is in `last_refusal` and the previous mount (if any) is
/// gone — detach-before-attach keeps a stale mount from surviving a failed
/// remount.
pub fn attach(src: vlfs.SectorSource) bool {
    active = null;
    for (&contained_files) |*f| f.* = .{};
    const vol = vlfs.mount(src, &block_scratch) catch |err| {
        last_refusal = vlfs.refusalName(err);
        return false;
    };
    epoch_ctr += 1;
    active = .{ .src = src, .vol = vol, .epoch = epoch_ctr };
    last_refusal = null;
    return true;
}

/// Drop the mount (tests; a device detach in a later milestone).
pub fn detach() void {
    active = null;
    for (&contained_files) |*f| f.* = .{};
}

pub fn mounted() bool {
    return active != null;
}

/// The mounted volume, or not_mounted.
fn mountOr() vlfs.Error!Mount {
    return active orelse error.NotMounted;
}

/// True when the handle's recorded mount epoch is still the live one —
/// a remount (same device re-attached) invalidates open `.disk` handles,
/// which then read as EBADF rather than a silently different volume.
pub fn epochLive(live_epoch: u64) bool {
    const m = active orelse return false;
    return m.epoch == live_epoch;
}

pub fn mountEpoch() u64 {
    const m = active orelse return 0;
    return m.epoch;
}

// --- The file_table-facing operations -------------------------------------

/// Resolve a canonical `/disk`-relative path to (inode, kind, size).
/// file_table maps the refusal to an errno row.
pub fn lookup(path: []const u8) vlfs.Error!vlfs.Dirent {
    const m = try mountOr();
    return vlfs.lookup(m.src, m.vol, path, &block_scratch);
}

pub fn read(ino: u32, offset: u64, out: []u8) vlfs.Error!usize {
    const m = try mountOr();
    return vlfs.read(m.src, m.vol, ino, offset, out, &block_scratch);
}

/// Name-sorted dirents of directory `dir_ino`, the smallest `out.len` by
/// byte-wise name order.
pub fn listDir(dir_ino: u32, out: []vlfs.Dirent) vlfs.Error!usize {
    const m = try mountOr();
    return vlfs.listDir(m.src, m.vol, dir_ino, out, &block_scratch);
}

pub fn statInode(ino: u32) vlfs.Error!vlfs.Stat {
    const m = try mountOr();
    return vlfs.stat(m.src, m.vol, ino, &block_scratch);
}

// --- fs_metadata slot-79 backend (ADR D6: real ContainedOps) ---------------

pub fn vlfsToMetaError(err: vlfs.Error) metadata.Error {
    return switch (err) {
        error.NotMounted => error.MetadataUnavailable,
        error.NotFound => error.FileNotFound,
        error.NotDir => error.NotDirectory,
        error.IsDir => error.NotFile,
        else => error.Io,
    };
}

/// The live attributes of one inode in the mounted volume — the Metadata a
/// dirent stat or a slot-79 answer carries.
pub fn inodeMeta(ino: u32) metadata.Error!metadata.Metadata {
    const m = mountOr() catch |err| return vlfsToMetaError(err);
    return metaOf(m, ino);
}

fn metaOf(m: Mount, ino: u32) metadata.Error!metadata.Metadata {
    const s = vlfs.stat(m.src, m.vol, ino, &block_scratch) catch |err| return vlfsToMetaError(err);
    return .{
        .identity = .{ .filesystem = m.epoch, .inode = ino },
        .kind = if (s.kind == vlfs.kind_dir) .directory else .file,
        .size = s.size,
        // No atime (D6): reads never dirty the journal.
        .atime = .{ .seconds = 0, .nanoseconds = 0 },
        .mtime = .{ .seconds = @intCast(s.mtime), .nanoseconds = 0 },
        .ctime = .{ .seconds = @intCast(s.ctime), .nanoseconds = 0 },
        // Every .disk object is world-readable/writable in v1 (D6) — the
        // mode is a statement, not a policy check.
        .host_mode = if (s.kind == vlfs.kind_dir) 0o040777 else 0o100666,
        .host_uid = 0,
        .host_gid = 0,
    };
}

fn opsRoot(ctx: *anyopaque) metadata.Error!metadata.Object {
    const m = mountOr() catch |err| return vlfsToMetaError(err);
    // The pinned root is the /disk-relative directory named by root_path
    // ("" is the volume root).
    const found = vlfs.lookup(m.src, m.vol, ctxPath(ctx), &block_scratch) catch |err|
        return vlfsToMetaError(err);
    if (found.kind != vlfs.kind_dir) return error.NotDirectory;
    return .{ .token = found.inode, .metadata = try metaOf(m, found.inode) };
}

fn opsLookup(_: *anyopaque, parent: metadata.Object, name: []const u8) metadata.Error!metadata.Object {
    const m = mountOr() catch |err| return vlfsToMetaError(err);
    const dir = vlfs.readInode(m.src, m.vol, @intCast(parent.token), &block_scratch) catch |err|
        return vlfsToMetaError(err);
    if (dir.kind != vlfs.kind_dir) return error.NotDirectory;
    var iter = vlfs.DirIter.init(m.src, m.vol, dir, &block_scratch);
    while (iter.next() catch |err| return vlfsToMetaError(err)) |d| {
        if (std.mem.eql(u8, d.nameSlice(), name)) {
            const child = vlfs.readInode(m.src, m.vol, d.inode, &block_scratch) catch |err|
                return vlfsToMetaError(err);
            if (child.kind != d.kind) return error.Io; // bad_dirent
            return .{ .token = d.inode, .metadata = try metaOf(m, d.inode) };
        }
    }
    return error.FileNotFound;
}

fn opsRelease(_: *anyopaque, _: metadata.Object) void {
    // Inode-number pins need no refcount on a read-only volume; nothing can
    // recycle an inode while the mount is live. M100d revisits this.
}

fn opsStat(_: *anyopaque, object: metadata.Object) metadata.Error!metadata.Metadata {
    const m = mountOr() catch |err| return vlfsToMetaError(err);
    return metaOf(m, @intCast(object.token));
}

fn opsOpen(_: *anyopaque, object: metadata.Object, access: metadata.Access) metadata.Error!u64 {
    if (access != .read) return error.AccessDenied; // v1 is read-only
    const m = mountOr() catch |err| return vlfsToMetaError(err);
    const s = vlfs.stat(m.src, m.vol, @intCast(object.token), &block_scratch) catch |err|
        return vlfsToMetaError(err);
    if (s.kind != vlfs.kind_file) return error.NotFile;
    for (&contained_files, 0..) |*f, i| {
        if (!f.used) {
            f.* = .{ .used = true, .ino = @intCast(object.token), .epoch = m.epoch };
            return i + 1;
        }
    }
    return error.HandleLimit;
}

fn opsClose(_: *anyopaque, handle: u64) metadata.Error!void {
    if (handle == 0 or handle > contained_max) return error.StaleIdentity;
    contained_files[handle - 1] = .{};
}

fn opsRead(_: *anyopaque, handle: u64, out: []u8) metadata.Error!usize {
    if (handle == 0 or handle > contained_max) return error.StaleIdentity;
    const f = &contained_files[handle - 1];
    if (!f.used) return error.StaleIdentity;
    const m = mountOr() catch |err| return vlfsToMetaError(err);
    if (f.epoch != m.epoch) return error.StaleIdentity;
    const n = vlfs.read(m.src, m.vol, f.ino, f.cursor, out, &block_scratch) catch |err|
        return vlfsToMetaError(err);
    f.cursor += n;
    return n;
}

fn opsWrite(_: *anyopaque, _: u64, _: []const u8) metadata.Error!usize {
    return error.AccessDenied; // v1 is read-only (M100d owns the write path)
}

fn opsDenied(_: *anyopaque, _: metadata.Object, _: []const u8) metadata.Error!metadata.Created {
    return error.AccessDenied;
}

fn opsMkdirDenied(_: *anyopaque, _: metadata.Object, _: []const u8) metadata.Error!metadata.Object {
    return error.AccessDenied;
}

fn opsRemoveDenied(_: *anyopaque, _: metadata.Object, _: []const u8, _: metadata.Kind) metadata.Error!void {
    return error.AccessDenied;
}

fn opsRenameDenied(_: *anyopaque, _: metadata.Object, _: []const u8, _: metadata.Object, _: []const u8, _: bool) metadata.Error!void {
    return error.AccessDenied;
}

fn opsHandleStat(_: *anyopaque, handle: u64) metadata.Error!metadata.Metadata {
    if (handle == 0 or handle > contained_max) return error.StaleIdentity;
    const f = &contained_files[handle - 1];
    if (!f.used) return error.StaleIdentity;
    const m = mountOr() catch |err| return vlfsToMetaError(err);
    if (f.epoch != m.epoch) return error.StaleIdentity;
    return metaOf(m, f.ino);
}

const contained_ops = metadata.ContainedOps{
    .root = opsRoot,
    .lookup = opsLookup,
    .release = opsRelease,
    .stat = opsStat,
    .open = opsOpen,
    .close = opsClose,
    .read = opsRead,
    .write = opsWrite,
    .create = opsDenied,
    .mkdir = opsMkdirDenied,
    .remove = opsRemoveDenied,
    .rename = opsRenameDenied,
    .handle_stat = opsHandleStat,
};

/// The backend context: the `/disk`-relative directory a slot-79 caller
/// pinned as its root — `ops.root` resolves it to the inode the pin refers
/// to. file_table calls `backend()` at the top of each op and the ops run
/// inside it, so one static store is safe under the file-domain lock.
const BackendCtx = struct {
    path: [metadata.max_relative_path]u8 = undefined,
    len: usize = 0,
};
var backend_ctx: BackendCtx = .{};

fn ctxPath(ctx: *anyopaque) []const u8 {
    const c: *BackendCtx = @ptrCast(@alignCast(ctx));
    return c.path[0..c.len];
}

/// The slot-79 backend for `/disk` roots. `root_path` is the /disk-relative
/// directory the caller pinned as its root; the fs_metadata core treats it
/// exactly like a share-relative root for path accounting.
pub fn backend(root_path: []const u8) metadata.Backend {
    @memcpy(backend_ctx.path[0..root_path.len], root_path);
    backend_ctx.len = root_path.len;
    return .{ .context = @ptrCast(&backend_ctx), .root_path = root_path, .ops = &contained_ops };
}

fn allowAll(_: *anyopaque, _: []const u8, _: metadata.Access) metadata.Error!void {}

/// Every .disk object is world-accessible in v1 (ADR D6): the authorizer
/// admits all accesses. Used by file_table for /disk metadata paths.
pub const authorizer = metadata.Authorizer{
    .context = @ptrCast(&backend_ctx),
    .check = allowAll,
};

/// Read from a contained-open handle (the `disk_handle` field of a
/// FileHandle), for file_table's read dispatch.
pub fn containedRead(handle: u32, out: []u8) vlfs.Error!usize {
    if (handle == 0 or handle > contained_max) return error.BadInode;
    const f = &contained_files[handle - 1];
    if (!f.used) return error.BadInode;
    const m = try mountOr();
    if (f.epoch != m.epoch) return error.BadInode;
    const n = try vlfs.read(m.src, m.vol, f.ino, f.cursor, out, &block_scratch);
    f.cursor += n;
    return n;
}

/// Release a contained handle when a file_table fd closes.
pub fn containedClose(handle: u32) void {
    if (handle == 0 or handle > contained_max) return;
    contained_files[handle - 1] = .{};
}

// ---------------------------------------------------------------------------
// Host tests — mount-state glue. (The pure reader is covered in vlfs.zig; the
// file-ABI routing is covered in file_table.zig.)
// ---------------------------------------------------------------------------

test "vlfs disk: attach/detach gate, epoch, and named refusal" {
    const src = vlfs.SectorSource{
        .total_sectors = 8,
        .readFn = struct {
            fn read(_: ?*anyopaque, _: u64, _: *[vlfs.sector_len]u8) bool {
                return false;
            }
        }.read,
    };
    detach();
    try std.testing.expect(!mounted());
    try std.testing.expectEqual(@as(u64, 0), mountEpoch());
    // A dead device is io_error; mount state stays clean for share-only.
    try std.testing.expect(!attach(src));
    try std.testing.expectEqualStrings("io_error", last_refusal.?);
    try std.testing.expect(!mounted());
    // Reads and lookups refuse not_mounted.
    var out: [8]u8 = undefined;
    try std.testing.expectError(error.NotMounted, lookup("x"));
    try std.testing.expectError(error.NotMounted, read(1, 0, &out));
    try std.testing.expectError(error.NotMounted, statInode(1));
}
