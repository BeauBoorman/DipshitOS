//! disk.zig — VLFS mount state and the `/disk` partition glue (M100c #2308;
//! write path M100d #2309).
//!
//! `vlfs.zig` is the pure format reader, `write.zig` the journaled write
//! path; this module owns the one mounted volume: the `SectorSource`, the
//! validated `Volume`, and the per-mount epoch that becomes `fs_metadata`
//! `identity.filesystem`.
//!
//! **The attach seam.** `attach(src)` is the single entry point; the boot
//! path calls `attachBlk()` after the virtio-blk driver's `virelai-vlfs`
//! GET_ID match (ADR 0050 D1/D6). A mount failure latches the ADR refusal
//! name in `last_refusal` and leaves `.disk` unmounted; the boot continues
//! share-only by construction (nothing else consults the mount). With no
//! data-disk device attached, `/disk` paths refuse `not_mounted` (ENOENT).
//!
//! **fs_metadata (slot 79).** VLFS supplies a real `ContainedOps` backend
//! (ADR D6): a pin token is the inode number, `identity` is
//! (mount epoch, inode). Pins survive every mutation (a rename does not
//! invalidate an inode pin); a delete marks its inode's pins and contained
//! handles stale at removal. An inode number recycled within one mount can
//! alias a still-live pin of the same kind — bounded by the forward-only
//! inode allocation scan in v1.

const std = @import("std");
const vlfs = @import("vlfs.zig");
const vlfs_write = @import("write.zig");
const metadata = @import("../fs_metadata.zig");
const virtio_blk = @import("../virtio_blk.zig");
const timer = @import("../timer.zig");
const seal = @import("../seal.zig");
const process = @import("../process.zig");
const scheduler = @import("../scheduler.zig");

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
/// Transactions the last successful mount replayed out of the journal
/// (ADR D5) — the boot log reports it as recovery evidence.
pub var last_replayed: u32 = 0;

/// One shared 4 KiB block scratch for every `/disk` path op, and the write
/// path's compose buffer. The file ABI runs under the `.file` service-domain
/// lock (syscall.zig), so concurrent callers cannot tear either.
var block_scratch: [vlfs.block_len]u8 align(64) = undefined;
var compose_scratch: [vlfs.block_len]u8 align(64) = undefined;

/// The mount check's working state (≈55 KiB of bitmaps, journal overlay,
/// and a chain work block — M134c #2761). Live only inside attach().
var check_state: vlfs.CheckState = undefined;
/// `check=<name>` formatting for last_refusal — a check-phase refusal is
/// named separately from a mount-structure refusal on the serial line.
var refusal_buf: [96]u8 = undefined;

/// Contained-open file handles minted by the fs_metadata backend (op 2).
/// Plain slot-23 opens on `/disk` stay stateless in file_table and never
/// land here. v1 bound: 8, matching the per-process handle table.
const contained_max = 8;
const ContainedFile = struct {
    used: bool = false,
    ino: u32 = 0,
    cursor: u64 = 0,
    epoch: u64 = 0,
    /// Opened for write (ops.open .write or an exclusive create).
    writable: bool = false,
};
var contained_files: [contained_max]ContainedFile = @splat(.{});

/// Inode timestamps come from the firmware-anchored wall clock; absent one,
/// zero keeps mounts deterministic rather than inventing a date.
fn now() u64 {
    return timer.wall_epoch() orelse 0;
}

/// M188b (#3187): the acting uid for a /disk op — the process principal of
/// the task the op runs on (the same find_by_task resolution the syscall
/// layer makes, so an EL0 caller's uid_agent/uid_user is what the inode's
/// owner_uid is checked against). A call that resolves no process — the
/// monitor's `vf` verbs, boot-time ops, host tests — acts as uid_system:
/// the kernel authority, which the opt-in rule always admits.
pub fn actingUid() u32 {
    if (process.find_by_task(scheduler.current_id())) |pid| {
        if (process.principal(pid)) |p| return p.uid;
    }
    return process.uid_system;
}

/// Attach and mount a VLFS volume through the mount-time check (M134c
/// #2761): a corrupt image is refused by name before any write reaches it.
/// Returns true on success; on refusal the named reason is in
/// `last_refusal` — `check=<name>` when the fsck pass failed, the plain
/// refusal name for mount-structure failures — and the previous mount (if
/// any) is gone: detach-before-attach keeps a stale mount from surviving a
/// failed remount.
pub fn attach(src: vlfs.SectorSource) bool {
    active = null;
    for (&contained_files) |*f| f.* = .{};
    last_replayed = 0;
    const vol = vlfs.mountChecked(src, &block_scratch, &check_state) catch |err| {
        last_refusal = if (check_state.check_error != null)
            std.fmt.bufPrint(&refusal_buf, "check={s}", .{vlfs.refusalName(err)}) catch "check=io_error"
        else
            vlfs.refusalName(err);
        return false;
    };
    epoch_ctr += 1;
    active = .{ .src = src, .vol = vol, .epoch = epoch_ctr };
    last_refusal = null;
    last_replayed = vol.replayed;
    return true;
}

/// Drop the mount (tests; a device detach in a later milestone).
pub fn detach() void {
    active = null;
    seal_ctx.wipe();
    for (&contained_files) |*f| f.* = .{};
    last_replayed = 0;
}

pub fn mounted() bool {
    return active != null;
}

/// M188b (#3187): the mounted volume's seal posture for the mount-table
/// row — `unsealed` for a live v2 mount, `locked` when the last attach
/// refused a sealed volume (the boot continues share-only, ADR 0061 D10),
/// `none` for v1 or no disk. GOFILES's volume face names it honestly.
pub const SealState = enum(u8) { none, locked, unsealed };
pub fn sealState() SealState {
    if (active) |m| {
        if (m.vol.seal != null) return .unsealed;
        return .none;
    }
    if (last_refusal) |r| {
        if (std.mem.eql(u8, r, "sealed")) return .locked;
    }
    return .none;
}

/// The mounted volume, or not_mounted.
fn mountOr() vlfs.Error!Mount {
    return active orelse error.NotMounted;
}

/// The mounted volume by pointer — the write path mutates next_txn_seq /
/// journal_applied / the superblock slot in place.
fn mountPtr() vlfs.Error!*Mount {
    if (active) |*m| return m;
    return error.NotMounted;
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
    return vlfs.readAs(m.src, m.vol, ino, actingUid(), offset, out, &block_scratch);
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

// --- The M100d write ops ----------------------------------------------------
// Every one is one journaled transaction (ADR D4) — committed and
// checkpointed before it returns. Named refusals propagate unchanged.

/// Create `path` (kind_file or kind_dir); returns the new inode. The
/// inode's owner_uid is claimed by the acting principal (M188b): an EL0
/// create mints the caller's uid; kernel-actor creates (the monitor's `vf`
/// verbs) mint 0 — unowned, world-accessible, the mkfs default.
pub fn create(path: []const u8, kind: u8) vlfs.Error!u32 {
    const m = try mountPtr();
    return vlfs_write.createPathAs(m.src, &m.vol, path, kind, actingUid(), now(), &block_scratch, &compose_scratch);
}

/// Write `bytes` at `offset` inside inode `ino` (one transaction).
pub fn write(ino: u32, offset: u64, bytes: []const u8) vlfs.Error!usize {
    const m = try mountPtr();
    return vlfs_write.writeFileAs(m.src, &m.vol, ino, actingUid(), offset, bytes, now(), &block_scratch, &compose_scratch);
}

/// Resize inode `ino` (journaled shrink or zero-filled grow).
pub fn truncate(ino: u32, new_size: u32) vlfs.Error!void {
    const m = try mountPtr();
    return vlfs_write.truncateFileAs(m.src, &m.vol, ino, actingUid(), new_size, now(), &block_scratch, &compose_scratch);
}

/// Remove `path`; returns the freed inode so callers can stale handles and
/// pins that referenced it.
pub fn remove(path: []const u8) vlfs.Error!u32 {
    const m = try mountPtr();
    const ino = try vlfs_write.removePathAs(m.src, &m.vol, path, actingUid(), now(), &block_scratch, &compose_scratch);
    invalidateIno(ino);
    return ino;
}

/// Rename `old` to `new`; `replace` permits overwriting a live target (a
/// directory target must still be empty). Refuses cross-mount moves because
/// both paths resolve inside this volume.
pub fn rename(old: []const u8, new: []const u8, replace: bool) vlfs.Error!void {
    const m = try mountPtr();
    return vlfs_write.renamePath(m.src, &m.vol, old, new, replace, now(), &block_scratch, &compose_scratch);
}

/// fsync (slot 77): one device FLUSH, waited out — the ADR D4 barrier.
pub fn sync() vlfs.Error!void {
    const m = try mountOr();
    return vlfs_write.sync(m.src);
}

/// Whole-file replace on a path: create when missing, truncate when
/// present, then write `bytes` and fsync — the monitor `write` verb's
/// shape, one journaled transaction per stage.
pub fn writeWhole(path: []const u8, bytes: []const u8) vlfs.Error!void {
    const m = try mountPtr();
    const uid = actingUid();
    const ino = blk: {
        const found = vlfs.lookup(m.src, m.vol, path, &block_scratch) catch |err| switch (err) {
            error.NotFound => break :blk try vlfs_write.createPathAs(m.src, &m.vol, path, vlfs.kind_file, uid, now(), &block_scratch, &compose_scratch),
            else => return err,
        };
        if (found.kind == vlfs.kind_dir) return error.IsDir;
        break :blk found.inode;
    };
    if (bytes.len == 0) {
        try vlfs_write.truncateFileAs(m.src, &m.vol, ino, uid, 0, now(), &block_scratch, &compose_scratch);
    } else {
        const st = try vlfs.stat(m.src, m.vol, ino, &block_scratch);
        if (st.size != 0) try vlfs_write.truncateFileAs(m.src, &m.vol, ino, uid, 0, now(), &block_scratch, &compose_scratch);
        _ = try vlfs_write.writeFileAs(m.src, &m.vol, ino, uid, 0, bytes, now(), &block_scratch, &compose_scratch);
    }
    try vlfs_write.sync(m.src);
}

/// Append `bytes` to `path`, creating it when missing — the chunked write
/// the monitor's `vf write /disk/...` verb loops over.
pub fn writeAppend(path: []const u8, bytes: []const u8) vlfs.Error!void {
    const m = try mountPtr();
    const uid = actingUid();
    const ino = blk: {
        const found = vlfs.lookup(m.src, m.vol, path, &block_scratch) catch |err| switch (err) {
            error.NotFound => break :blk try vlfs_write.createPathAs(m.src, &m.vol, path, vlfs.kind_file, uid, now(), &block_scratch, &compose_scratch),
            else => return err,
        };
        if (found.kind == vlfs.kind_dir) return error.IsDir;
        break :blk found.inode;
    };
    const st = try vlfs.stat(m.src, m.vol, ino, &block_scratch);
    _ = try vlfs_write.writeFileAs(m.src, &m.vol, ino, uid, st.size, bytes, now(), &block_scratch, &compose_scratch);
}

/// A deleted inode's contained handles and pins are stale immediately —
/// the removal transaction already made the inode unreadable.
fn invalidateIno(ino: u32) void {
    for (&contained_files) |*f| {
        if (f.used and f.ino == ino) f.epoch = 0;
    }
}

// --- The virtio-blk data disk as a SectorSource -----------------------------

fn blkRead(_: ?*anyopaque, lba: u64, out: *[vlfs.sector_len]u8) bool {
    virtio_blk.read_sector(lba, out) catch return false;
    return true;
}

fn blkWrite(_: ?*anyopaque, lba: u64, data: *const [vlfs.sector_len]u8) bool {
    virtio_blk.write_sector(lba, data) catch return false;
    return true;
}

fn blkFlush(_: ?*anyopaque) bool {
    virtio_blk.flush() catch return false;
    return true;
}

/// The `virelai-vlfs` device as a SectorSource — always bound at the
/// driver's vlfs_disk function index, never the boot disk.
pub fn blkSource() ?vlfs.SectorSource {
    const sectors = virtio_blk.capacity_sectors() catch return null;
    return .{
        .total_sectors = sectors,
        .readFn = blkRead,
        .writeFn = blkWrite,
        .flushFn = blkFlush,
    };
}

/// The one live seal context (M172d, ADR 0061) — armed by the boot
/// prompt's unwrap, wiped on detach and on a failed sealed mount. The
/// DEK lives in kernel RAM only for the life of the mount.
var seal_ctx: seal.Seal = undefined;

/// Boot-path mount: attach the data disk the runner attached with
/// `--data-disk`. A refusal latches `last_refusal`; no device → `no_disk`.
/// A v2 superblock with the SLFS mark routes through the unseal prompt
/// first (ADR 0061): the console reads the passphrase echo-free under a
/// five-attempt budget and a 120 s idle timeout, and lockout or timeout
/// refuses the mount — the boot continues share-only either way.
pub fn attachBlk(ops: *const seal.PromptOps) bool {
    const raw = blkSource() orelse {
        last_refusal = "no_disk";
        return false;
    };
    const sb = vlfs.selectSuperblock(raw) catch |err| {
        last_refusal = vlfs.refusalName(err);
        return false;
    };
    if (sb.seal) |info| {
        switch (seal.unseal(&seal_ctx, raw, sb, info, ops)) {
            .unsealed => {
                if (attach(seal.source(&seal_ctx))) return true;
                seal_ctx.wipe();
                return false;
            },
            else => {
                last_refusal = "sealed";
                return false;
            },
        }
    }
    return attach(raw);
}

// --- fs_metadata slot-79 backend (ADR D6: real ContainedOps) ---------------

pub fn vlfsToMetaError(err: vlfs.Error) metadata.Error {
    return switch (err) {
        error.NotMounted => error.MetadataUnavailable,
        error.NotFound => error.FileNotFound,
        error.NotDir => error.NotDirectory,
        error.IsDir => error.NotFile,
        error.Exists, error.NotEmpty => error.Exists,
        error.NameTooLong => error.InvalidPath,
        error.ReadOnly, error.NotOwner => error.AccessDenied,
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
        // M188b (#3187): the inode's owner_uid rides the wire honestly —
        // 0 is unowned (world), never a substitute for access policy.
        .host_uid = s.owner,
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
    if (access != .read and access != .write) return error.AccessDenied;
    const m = mountOr() catch |err| return vlfsToMetaError(err);
    // A write-mode open on a read-only mount refuses at open, not on the
    // first write — honest refusal placement.
    if (access == .write and !m.src.writable()) return error.AccessDenied;
    const s = vlfs.stat(m.src, m.vol, @intCast(object.token), &block_scratch) catch |err|
        return vlfsToMetaError(err);
    if (s.kind != vlfs.kind_file) return error.NotFile;
    for (&contained_files, 0..) |*f, i| {
        if (!f.used) {
            f.* = .{ .used = true, .ino = @intCast(object.token), .epoch = m.epoch, .writable = access == .write };
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
    const n = vlfs.readAs(m.src, m.vol, f.ino, actingUid(), f.cursor, out, &block_scratch) catch |err|
        return vlfsToMetaError(err);
    f.cursor += n;
    return n;
}

fn opsWrite(_: *anyopaque, handle: u64, bytes: []const u8) metadata.Error!usize {
    if (handle == 0 or handle > contained_max) return error.StaleIdentity;
    const f = &contained_files[handle - 1];
    if (!f.used) return error.StaleIdentity;
    if (!f.writable) return error.AccessDenied;
    const m = mountPtr() catch |err| return vlfsToMetaError(err);
    if (f.epoch != m.epoch) return error.StaleIdentity;
    const n = vlfs_write.writeFileAs(m.src, &m.vol, f.ino, actingUid(), f.cursor, bytes, now(), &block_scratch, &compose_scratch) catch |err|
        return vlfsToMetaError(err);
    f.cursor += n;
    return n;
}

fn opsCreate(_: *anyopaque, parent: metadata.Object, name: []const u8) metadata.Error!metadata.Created {
    const m = mountPtr() catch |err| return vlfsToMetaError(err);
    const ino = vlfs_write.createAs(m.src, &m.vol, @intCast(parent.token), name, vlfs.kind_file, actingUid(), now(), &block_scratch, &compose_scratch) catch |err|
        return vlfsToMetaError(err);
    for (&contained_files, 0..) |*f, i| {
        if (!f.used) {
            f.* = .{ .used = true, .ino = ino, .epoch = m.epoch, .writable = true };
            return .{ .handle = i + 1, .metadata = try metaOf(m.*, ino) };
        }
    }
    return error.HandleLimit;
}

fn opsMkdir(_: *anyopaque, parent: metadata.Object, name: []const u8) metadata.Error!metadata.Object {
    const m = mountPtr() catch |err| return vlfsToMetaError(err);
    const ino = vlfs_write.createAs(m.src, &m.vol, @intCast(parent.token), name, vlfs.kind_dir, actingUid(), now(), &block_scratch, &compose_scratch) catch |err|
        return vlfsToMetaError(err);
    return .{ .token = ino, .metadata = try metaOf(m.*, ino) };
}

fn opsRemove(_: *anyopaque, parent: metadata.Object, name: []const u8, kind: metadata.Kind) metadata.Error!void {
    const m = mountPtr() catch |err| return vlfsToMetaError(err);
    // ContainedOps removes exactly `kind`; a directory must be empty inside
    // removeAt (not_empty).
    const dir = vlfs.readInode(m.src, m.vol, @intCast(parent.token), &block_scratch) catch |err|
        return vlfsToMetaError(err);
    if (dir.kind != vlfs.kind_dir) return error.NotDirectory;
    var iter = vlfs.DirIter.init(m.src, m.vol, dir, &block_scratch);
    var found: ?u32 = null;
    var found_kind: u8 = 0;
    while (iter.next() catch |err| return vlfsToMetaError(err)) |d| {
        if (std.mem.eql(u8, d.nameSlice(), name)) {
            found = d.inode;
            found_kind = d.kind;
            break;
        }
    }
    if (found == null) return error.FileNotFound;
    const want: u8 = if (kind == .directory) vlfs.kind_dir else vlfs.kind_file;
    if (found_kind != want) return if (kind == .directory) error.NotDirectory else error.NotFile;
    // Kind-checked (pin inode, name) removal — the pin never re-resolves.
    const ino = vlfs_write.removeAtAs(m.src, &m.vol, @intCast(parent.token), name, actingUid(), now(), &block_scratch, &compose_scratch) catch |err|
        return vlfsToMetaError(err);
    invalidateIno(ino);
}

fn opsRename(_: *anyopaque, from: metadata.Object, from_name: []const u8, to: metadata.Object, to_name: []const u8, replace: bool) metadata.Error!void {
    const m = mountPtr() catch |err| return vlfsToMetaError(err);
    vlfs_write.renameAt(m.src, &m.vol, @intCast(from.token), from_name, @intCast(to.token), to_name, replace, now(), &block_scratch, &compose_scratch) catch |err|
        return vlfsToMetaError(err);
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
    .create = opsCreate,
    .mkdir = opsMkdir,
    .remove = opsRemove,
    .rename = opsRename,
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
    const n = try vlfs.readAs(m.src, m.vol, f.ino, actingUid(), f.cursor, out, &block_scratch);
    f.cursor += n;
    return n;
}

/// Write through a contained-open handle (the `disk_handle` field of a
/// FileHandle), for file_table's write dispatch.
pub fn containedWrite(handle: u32, bytes: []const u8) vlfs.Error!usize {
    if (handle == 0 or handle > contained_max) return error.BadInode;
    const f = &contained_files[handle - 1];
    if (!f.used or !f.writable) return error.BadInode;
    const m = try mountPtr();
    if (f.epoch != m.epoch) return error.BadInode;
    const n = try vlfs_write.writeFileAs(m.src, &m.vol, f.ino, actingUid(), f.cursor, bytes, now(), &block_scratch, &compose_scratch);
    f.cursor += n;
    return n;
}

/// The inode a contained handle refers to (truncate/stat dispatch by fd).
pub fn containedIno(handle: u32) ?u32 {
    if (handle == 0 or handle > contained_max) return null;
    const f = &contained_files[handle - 1];
    if (!f.used) return null;
    return f.ino;
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
