//! B3 (#1870): honest metadata and a bounded, no-follow traversal core.
//!
//! The live adapter is virtio_fs.zig; file_table.zig authorizes every use,
//! and syscall slot 79 exposes the bounded metadata/contained operations.
//! An adapter may opt into `ContainedOps` only when it pins each lookup
//! result, never follows links, and operates on those pins rather than
//! re-opening a checked pathname. A stat-then-path-open adapter is unsafe.
//! Backends without that primitive explicitly return ContainmentUnavailable.
//!
//! FUSE attributes are decoded without path hashes, synthetic directory
//! inodes, clamped sizes, default timestamps, or host-to-guest ownership
//! translation. `filesystem` identifies the adapter's filesystem lifetime;
//! it must be nonzero, stable for that lifetime, and change on remount.

const std = @import("std");
const directory = @import("directory.zig");

pub const Error = error{
    InvalidPath,
    PathLimit,
    TreeLimit,
    InvalidMetadata,
    MetadataUnavailable,
    ContainmentUnavailable,
    FileNotFound,
    AccessDenied,
    NotDirectory,
    NotFile,
    SymlinkRejected,
    StaleIdentity,
    HandleLimit,
    /// B5: an occupied preserve-existing/exclusive target or a non-empty
    /// directory removal. Never a replacement or a recursive delete.
    Exists,
    Io,
};

pub const Kind = enum(u32) {
    file,
    directory,
    symlink,
    character_device,
    block_device,
    fifo,
    socket,
};

pub const Identity = extern struct {
    filesystem: u64,
    inode: u64,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.filesystem == b.filesystem and a.inode == b.inode;
    }
};

pub const Timestamp = struct {
    seconds: i64,
    nanoseconds: u32,

    pub fn toNanoseconds(self: Timestamp) i128 {
        return @as(i128, self.seconds) * 1_000_000_000 + self.nanoseconds;
    }
};

/// All fields are required. Host mode/uid/gid are facts from FUSE, NOT the
/// Virelai principal/mode policy; the caller must still authorize each use.
pub const Metadata = struct {
    identity: Identity,
    kind: Kind,
    size: u64,
    atime: Timestamp,
    mtime: Timestamp,
    ctime: Timestamp,
    host_mode: u32,
    host_uid: u32,
    host_gid: u32,

    pub fn validate(self: Metadata) Error!void {
        if (self.identity.filesystem == 0 or self.identity.inode == 0)
            return error.InvalidMetadata;
        for ([_]Timestamp{ self.atime, self.mtime, self.ctime }) |t| {
            if (t.nanoseconds >= 1_000_000_000) return error.InvalidMetadata;
        }
        if (try kindFromMode(self.host_mode) != self.kind) return error.InvalidMetadata;
    }

    /// Boris's watch prerequisite, not a watcher or a filesystem change feed.
    pub fn watchChanged(old: Metadata, new: Metadata) bool {
        return old.size != new.size or old.mtime.toNanoseconds() != new.mtime.toNanoseconds();
    }
};

fn read32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

fn read64(bytes: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, bytes[off..][0..8], .little);
}

fn kindFromMode(mode: u32) Error!Kind {
    // Avoid LLVM's pointer table of constant error-union results. Such
    // absolute rodata pointers are not relocated by the current encoder.
    var kind: Kind = undefined;
    const out: *volatile Kind = &kind;
    switch (mode & 0o170000) {
        0o100000 => out.* = .file,
        0o040000 => out.* = .directory,
        0o120000 => out.* = .symlink,
        0o020000 => out.* = .character_device,
        0o060000 => out.* = .block_device,
        0o010000 => out.* = .fifo,
        0o140000 => out.* = .socket,
        else => return error.InvalidMetadata,
    }
    return kind;
}

pub const fuse_attr_bytes: usize = 88;
pub const fuse_entry_bytes: usize = 128;
pub const fuse_getattr_bytes: usize = 104;

/// FUSE 7.31 `fuse_attr`, used by both LOOKUP and GETATTR. Timestamp zero
/// is accepted only when actually present in the reply, never as a fallback.
pub fn decodeFuseAttr(filesystem: u64, bytes: []const u8) Error!Metadata {
    if (bytes.len < fuse_attr_bytes) return error.InvalidMetadata;
    const mode = read32(bytes, 60);
    const result = Metadata{
        .identity = .{ .filesystem = filesystem, .inode = read64(bytes, 0) },
        .kind = try kindFromMode(mode),
        .size = read64(bytes, 8),
        .atime = .{ .seconds = @bitCast(read64(bytes, 24)), .nanoseconds = read32(bytes, 48) },
        .mtime = .{ .seconds = @bitCast(read64(bytes, 32)), .nanoseconds = read32(bytes, 52) },
        .ctime = .{ .seconds = @bitCast(read64(bytes, 40)), .nanoseconds = read32(bytes, 56) },
        .host_mode = mode,
        .host_uid = read32(bytes, 68),
        .host_gid = read32(bytes, 72),
    };
    try result.validate();
    return result;
}

pub const Lookup = struct {
    node: u64,
    generation: u64,
    metadata: Metadata,
};

pub fn decodeFuseLookup(filesystem: u64, bytes: []const u8) Error!Lookup {
    if (bytes.len < fuse_entry_bytes or read64(bytes, 0) == 0)
        return error.InvalidMetadata;
    return .{
        .node = read64(bytes, 0),
        .generation = read64(bytes, 8),
        .metadata = try decodeFuseAttr(filesystem, bytes[40..]),
    };
}

pub fn decodeFuseGetattr(filesystem: u64, bytes: []const u8) Error!Metadata {
    if (bytes.len < fuse_getattr_bytes) return error.InvalidMetadata;
    return decodeFuseAttr(filesystem, bytes[16..]);
}

/// These are transport-side FUSE error numbers, never native syscall errno.
/// An unrecognized or malformed response cannot turn into not-found or EOF.
pub fn fuseError(errno: i32) Error {
    return switch (errno) {
        -1, -13 => error.AccessDenied,
        -2 => error.FileNotFound,
        -17, -39 => error.Exists, // EEXIST, ENOTEMPTY
        -18 => error.ContainmentUnavailable, // EXDEV
        -20 => error.NotDirectory,
        -21 => error.NotFile, // EISDIR
        -40 => error.SymlinkRejected,
        -38, -95 => error.MetadataUnavailable,
        -116 => error.StaleIdentity,
        0...std.math.maxInt(i32) => error.InvalidMetadata,
        else => error.Io,
    };
}

// B2's approved full-native-path/name ceilings, still bounded below a root.
pub const guest_prefix = "/host/";
pub const max_guest_path: usize = directory.path_max;
pub const max_relative_path: usize = max_guest_path - guest_prefix.len;
pub const max_component: usize = directory.name_max;
pub const max_depth: usize = directory.depth_max;

pub const stat_op: u64 = 0;
pub const identity_op: u64 = 1;
pub const read_open_op: u64 = 2;
pub const write_open_op: u64 = 3;
pub const dir_open_op: u64 = 4;
pub const dir_page_op: u64 = 5;
pub const dir_close_op: u64 = 6;
// B5 (#1895): pinned-directory handles and mutations relative to them.
pub const pin_open_op: u64 = 7;
pub const pin_child_op: u64 = 8;
pub const pin_close_op: u64 = 9;
pub const handle_metadata_op: u64 = 10;
pub const create_op: u64 = 11;
pub const mkdir_op: u64 = 12;
pub const remove_op: u64 = 13;
pub const rename_op: u64 = 14;
pub const handle_file: u64 = 0;
pub const handle_directory: u64 = 1;
pub const remove_file: u64 = 0;
pub const remove_directory: u64 = 1;
pub const rename_length_mask: u64 = 0xffff;
pub const rename_replace: u64 = 1 << 32;
/// A pinned path may join a ≤8-component root and ≤8 relative components.
pub const max_pinned_depth: usize = max_depth * 2;

pub const WireTime = extern struct {
    seconds: i64,
    nanoseconds: u32,
    reserved: u32 = 0,
};

/// M134a (#2759): the /host path-stat's filesystem word over the legacy
/// file channel — nonzero per the wire contract, stable for the armed
/// share's lifetime (one boot). The high bit keeps it out of VirtioFS's
/// mount-generation counter space forever.
pub const legacy_share_epoch: u64 = 0x8000_0000_0000_0001;

/// Host attributes are facts, never guest ownership/capabilities.
pub const Wire = extern struct {
    version: u32 = 1,
    kind: Kind,
    identity: Identity,
    size: u64,
    atime: WireTime,
    mtime: WireTime,
    ctime: WireTime,
    host_mode: u32,
    host_uid: u32,
    host_gid: u32,
    reserved: u32 = 0,

    pub fn from(value: Metadata) Wire {
        return .{
            .kind = value.kind,
            .identity = value.identity,
            .size = value.size,
            .atime = .{ .seconds = value.atime.seconds, .nanoseconds = value.atime.nanoseconds },
            .mtime = .{ .seconds = value.mtime.seconds, .nanoseconds = value.mtime.nanoseconds },
            .ctime = .{ .seconds = value.ctime.seconds, .nanoseconds = value.ctime.nanoseconds },
            .host_mode = value.host_mode,
            .host_uid = value.host_uid,
            .host_gid = value.host_gid,
        };
    }
};

pub const Entry = extern struct {
    name: [256]u8 = @splat(0),
    name_len: u16,
    reserved: [6]u8 = @splat(0),
    metadata: Wire,
};
pub const Page = extern struct {
    header: directory.Header = .{},
    entries: [directory.page_max]Entry = undefined,
};
pub const Snapshot = struct {
    count: usize = 0,
    entries: [directory.entry_max]Entry = undefined,

    pub fn append(self: *Snapshot, name: []const u8, value: Metadata) Error!void {
        if (!directory.valid_name(name)) return error.InvalidMetadata;
        try value.validate();
        if (value.kind == .symlink) return error.SymlinkRejected;
        if (self.count == directory.entry_max) return error.TreeLimit;
        for (self.entries[0..self.count]) |entry| {
            if (std.mem.eql(u8, entry.name[0..entry.name_len], name)) return error.StaleIdentity;
        }
        var entry = Entry{ .name_len = @intCast(name.len), .metadata = Wire.from(value) };
        @memcpy(entry.name[0..name.len], name);
        self.entries[self.count] = entry;
        self.count += 1;
    }

    fn less(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.name[0..a.name_len], b.name[0..b.name_len]) == .lt;
    }

    pub fn sort(self: *Snapshot) void {
        // Block sort's 512-entry cache consumes 184,320 stack bytes here.
        // Names are unique, so stable ordering is unnecessary.
        std.sort.heap(Entry, self.entries[0..self.count], {}, less);
    }
};
comptime {
    if (@sizeOf(Wire) != 96 or @sizeOf(Entry) != 360)
        @compileError("B3 metadata wire layout changed");
}

pub fn validatePath(path: []const u8) Error!void {
    if (path.len > max_relative_path) return error.PathLimit;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (path.len == 0) return; // the supplied content root itself
    var parts = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            return error.InvalidPath;
        if (part.len > max_component) return error.PathLimit;
        depth += 1;
        if (depth > max_depth) return error.TreeLimit;
    }
}

fn validateRootedPath(root: []const u8, path: []const u8) Error!void {
    try validatePath(root);
    try validatePath(path);
    const separator: usize = if (root.len != 0 and path.len != 0) 1 else 0;
    if (root.len + separator + path.len > max_relative_path) return error.PathLimit;
}

/// A backend-owned pin, not an unchecked pathname, cached stat, or EL0 fd.
pub const Object = struct {
    token: u64,
    metadata: Metadata,
};

pub const Access = enum { metadata, read, write, create, delete };
pub const Authorizer = struct {
    context: *anyopaque,
    /// Paths are relative to Backend.root_path. The adapter must join that
    /// root before applying the real Virelai principal policy. Empty path
    /// means root. Called before lookup/open and at every use.
    check: *const fn (*anyopaque, []const u8, Access) Error!void,
};

pub const ContainedOps = struct {
    /// Pins the actual supplied root without following a root symlink.
    root: *const fn (*anyopaque) Error!Object,
    /// Looks up one component relative to the pinned directory, no-follow.
    /// The returned object stays pinned until release, even if renamed.
    lookup: *const fn (*anyopaque, Object, []const u8) Error!Object,
    release: *const fn (*anyopaque, Object) void,
    /// Reads attributes from the pin, not its former pathname.
    stat: *const fn (*anyopaque, Object) Error!Metadata,
    /// Opens that exact pinned regular file, no-follow, without truncating.
    /// Inability to preserve identity/containment is an explicit refusal.
    open: *const fn (*anyopaque, Object, Access) Error!u64,
    close: *const fn (*anyopaque, u64) Error!void,
    read: *const fn (*anyopaque, u64, []u8) Error!usize,
    write: *const fn (*anyopaque, u64, []const u8) Error!usize,
    /// B5: the remaining operations act on one name inside a pinned
    /// directory, never on a re-resolved pathname. Each preflights its own
    /// bounded resources and refuses before mutation when they are full.
    /// Exclusive create returns a write-only handle on the new object.
    create: *const fn (*anyopaque, Object, []const u8) Error!Created,
    /// Returns the new directory pinned; the caller must release it.
    mkdir: *const fn (*anyopaque, Object, []const u8) Error!Object,
    /// Removes a file or an empty directory of exactly `Kind`.
    remove: *const fn (*anyopaque, Object, []const u8, Kind) Error!void,
    /// `true` replaces an existing target; `false` refuses it atomically.
    rename: *const fn (*anyopaque, Object, []const u8, Object, []const u8, bool) Error!void,
    /// Live attributes of an open handle's own object, never its old name.
    handle_stat: *const fn (*anyopaque, u64) Error!Metadata,
};

pub const Created = struct {
    handle: u64,
    metadata: Metadata,
};

/// A pinned directory and the share-relative name it was authorized under.
/// The name is kept only for reauthorization at every use.
pub const Directory = struct {
    object: Object,
    path: []const u8,
};

pub const Backend = struct {
    context: *anyopaque,
    /// Canonical, share-relative spelling of the root pinned by `ops.root`.
    /// Accounted in the full /host/ path budget, not an unchecked host path.
    root_path: []const u8,
    ops: ?*const ContainedOps,

    fn contained(self: Backend) Error!*const ContainedOps {
        return self.ops orelse error.ContainmentUnavailable;
    }
};

fn noSymlink(metadata: Metadata) Error!void {
    try metadata.validate();
    if (metadata.kind == .symlink) return error.SymlinkRejected;
}

pub fn checkedStat(backend: Backend, object: Object) Error!Metadata {
    const result = try (try backend.contained()).stat(backend.context, object);
    try noSymlink(result);
    if (!result.identity.eql(object.metadata.identity) or result.kind != object.metadata.kind)
        return error.StaleIdentity;
    return result;
}

fn authorizePath(auth: Authorizer, path: []const u8, access: Access) Error!void {
    try auth.check(auth.context, "", .metadata);
    var at: usize = 0;
    while (at < path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, at, '/') orelse path.len;
        try auth.check(auth.context, path[0..end], if (end == path.len) access else .metadata);
        at = end + 1;
    }
}

/// At most two simultaneous pins. No per-depth handles, heap, or recursion.
/// The caller owns the returned pin and must release it.
pub fn resolve(backend: Backend, auth: Authorizer, path: []const u8, access: Access) Error!Object {
    try validateRootedPath(backend.root_path, path);
    const ops = try backend.contained();
    try auth.check(auth.context, "", .metadata);
    var current = try ops.root(backend.context);
    errdefer ops.release(backend.context, current);
    try noSymlink(current.metadata);
    if (current.metadata.kind != .directory) return error.NotDirectory;
    const filesystem = current.metadata.identity.filesystem;
    if (path.len == 0) return current;

    var at: usize = 0;
    while (at < path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, at, '/') orelse path.len;
        const want: Access = if (end == path.len) access else .metadata;
        try auth.check(auth.context, path[0..end], want);
        const child = try ops.lookup(backend.context, current, path[at..end]);
        ops.release(backend.context, current);
        current = child;
        try noSymlink(current.metadata);
        if (current.metadata.identity.filesystem != filesystem)
            return error.ContainmentUnavailable;
        if (end < path.len and current.metadata.kind != .directory)
            return error.NotDirectory;
        at = end + 1;
    }
    return current;
}

pub fn stat(backend: Backend, auth: Authorizer, path: []const u8) Error!Metadata {
    const ops = try backend.contained();
    const object = try resolve(backend, auth, path, .metadata);
    defer ops.release(backend.context, object);
    try authorizePath(auth, path, .metadata);
    return checkedStat(backend, object);
}

/// Retains the pathname solely for reauthorization. Reads/writes use the
/// backend handle, so swapping the former path for a symlink cannot redirect
/// an already-open stream. No successful EOF is returned for backend errors.
pub const File = struct {
    backend: Backend,
    auth: Authorizer,
    token: u64,
    access: Access,
    path: [max_relative_path]u8,
    path_len: usize,
    closed: bool = false,

    pub fn read(self: *File, out: []u8) Error!usize {
        if (self.closed) return error.StaleIdentity;
        if (self.access != .read) return error.AccessDenied;
        try authorizePath(self.auth, self.path[0..self.path_len], .read);
        const n = try (try self.backend.contained()).read(self.backend.context, self.token, out);
        if (n > out.len) return error.InvalidMetadata;
        return n;
    }

    pub fn write(self: *File, bytes: []const u8) Error!usize {
        if (self.closed) return error.StaleIdentity;
        if (self.access != .write) return error.AccessDenied;
        try authorizePath(self.auth, self.path[0..self.path_len], .write);
        const n = try (try self.backend.contained()).write(self.backend.context, self.token, bytes);
        if (n > bytes.len) return error.InvalidMetadata;
        if (bytes.len != 0 and n == 0) return error.Io;
        return n;
    }

    pub fn close(self: *File) Error!void {
        if (self.closed) return error.StaleIdentity;
        const ops = self.backend.ops orelse unreachable;
        try ops.close(self.backend.context, self.token);
        self.closed = true;
    }
};

pub fn openToken(backend: Backend, auth: Authorizer, path: []const u8, access: Access) Error!u64 {
    if (access != .read and access != .write) return error.NotFile;
    const ops = try backend.contained();
    const object = try resolve(backend, auth, path, access);
    defer ops.release(backend.context, object);
    const metadata = try checkedStat(backend, object);
    if (metadata.kind != .file) return error.NotFile;
    try authorizePath(auth, path, access);
    return ops.open(backend.context, object, access);
}

pub fn open(backend: Backend, auth: Authorizer, path: []const u8, access: Access) Error!File {
    const token = try openToken(backend, auth, path, access);
    var result = File{
        .backend = backend,
        .auth = auth,
        .token = token,
        .access = access,
        .path = undefined,
        .path_len = path.len,
    };
    @memcpy(result.path[0..path.len], path);
    return result;
}

/// Joins one validated name below a pinned directory's path. The result
/// keeps B2's full-path and component bounds and B5's 16-component depth.
pub fn childPath(parent: []const u8, name: []const u8, out: []u8) Error![]const u8 {
    if (name.len > max_component) return error.PathLimit;
    if (!directory.valid_name(name)) return error.InvalidPath;
    const separator: usize = @intFromBool(parent.len != 0);
    const len = parent.len + separator + name.len;
    if (len > max_relative_path or len > out.len) return error.PathLimit;
    const depth = if (parent.len == 0) 1 else std.mem.count(u8, parent, "/") + 2;
    if (depth > max_pinned_depth) return error.TreeLimit;
    @memcpy(out[0..parent.len], parent);
    if (separator != 0) out[parent.len] = '/';
    @memcpy(out[parent.len + separator ..][0..name.len], name);
    return out[0..len];
}

fn pinnedDirectory(backend: Backend, object: Object) Error!Object {
    const ops = try backend.contained();
    errdefer ops.release(backend.context, object);
    try noSymlink(object.metadata);
    if (object.metadata.kind != .directory) return error.NotDirectory;
    const fresh = try checkedStat(backend, object);
    if (fresh.kind != .directory) return error.NotDirectory;
    return object;
}

/// Pins an existing directory by the B3 no-follow walk. Caller releases.
pub fn openDirectory(backend: Backend, auth: Authorizer, path: []const u8) Error!Object {
    return pinnedDirectory(backend, try resolve(backend, auth, path, .metadata));
}

/// One no-follow LOOKUP from the pinned parent, never a path re-walk.
pub fn childDirectory(backend: Backend, auth: Authorizer, parent: Directory, name: []const u8) Error!Object {
    var buffer: [max_relative_path]u8 = undefined;
    const path = try childPath(parent.path, name, &buffer);
    const ops = try backend.contained();
    try authorizePath(auth, path, .metadata);
    const child = try ops.lookup(backend.context, parent.object, name);
    if (child.metadata.identity.filesystem != parent.object.metadata.identity.filesystem) {
        ops.release(backend.context, child);
        return error.ContainmentUnavailable;
    }
    return pinnedDirectory(backend, child);
}

pub fn directoryMetadata(backend: Backend, auth: Authorizer, dir: Directory) Error!Metadata {
    try authorizePath(auth, dir.path, .metadata);
    return checkedStat(backend, dir.object);
}

/// `path` is the handle's authorized name; the attributes come from the
/// handle itself. A changed identity or kind is stale, never re-resolved.
pub fn handleMetadata(backend: Backend, auth: Authorizer, handle: u64, path: []const u8) Error!Metadata {
    const ops = try backend.contained();
    try authorizePath(auth, path, .metadata);
    const result = try ops.handle_stat(backend.context, handle);
    try noSymlink(result);
    if (result.kind != .file) return error.StaleIdentity;
    return result;
}

pub fn createFile(backend: Backend, auth: Authorizer, dir: Directory, name: []const u8) Error!Created {
    var buffer: [max_relative_path]u8 = undefined;
    const ops = try backend.contained();
    try authorizePath(auth, try childPath(dir.path, name, &buffer), .create);
    const result = try ops.create(backend.context, dir.object, name);
    if (result.metadata.kind != .file) {
        ops.close(backend.context, result.handle) catch {};
        return error.InvalidMetadata;
    }
    return result;
}

/// Returns the new directory pinned. Caller releases.
pub fn makeDirectory(backend: Backend, auth: Authorizer, dir: Directory, name: []const u8) Error!Object {
    var buffer: [max_relative_path]u8 = undefined;
    const ops = try backend.contained();
    try authorizePath(auth, try childPath(dir.path, name, &buffer), .create);
    const result = try ops.mkdir(backend.context, dir.object, name);
    if (result.metadata.kind != .directory) {
        ops.release(backend.context, result);
        return error.InvalidMetadata;
    }
    return result;
}

pub fn remove(backend: Backend, auth: Authorizer, dir: Directory, name: []const u8, kind: Kind) Error!void {
    if (kind != .file and kind != .directory) return error.InvalidPath;
    var buffer: [max_relative_path]u8 = undefined;
    const ops = try backend.contained();
    try authorizePath(auth, try childPath(dir.path, name, &buffer), .delete);
    return ops.remove(backend.context, dir.object, name, kind);
}

/// Authorizes deletion at the source and creation at the destination,
/// then submits one backend rename between the two pinned directories.
pub fn rename(backend: Backend, auth: Authorizer, from: Directory, from_name: []const u8, to: Directory, to_name: []const u8, replace: bool) Error!void {
    var source: [max_relative_path]u8 = undefined;
    var target: [max_relative_path]u8 = undefined;
    const from_path = try childPath(from.path, from_name, &source);
    const to_path = try childPath(to.path, to_name, &target);
    const ops = try backend.contained();
    try authorizePath(auth, from_path, .delete);
    try authorizePath(auth, to_path, .create);
    if (from.object.metadata.identity.filesystem != to.object.metadata.identity.filesystem)
        return error.ContainmentUnavailable;
    return ops.rename(backend.context, from.object, from_name, to.object, to_name, replace);
}

// Unit fixtures are an explicit in-memory backend. Passing these tests does
// not opt VirtioFS or the legacy host channel into the containment contract.
fn testAttr(inode: u64, mode: u32) [fuse_attr_bytes]u8 {
    var bytes = @as([fuse_attr_bytes]u8, @splat(@as(u8, 0)));
    std.mem.writeInt(u64, bytes[0..8], inode, .little);
    std.mem.writeInt(u64, bytes[8..16], 0x1_0000_0017, .little);
    std.mem.writeInt(i64, bytes[24..32], -1, .little);
    std.mem.writeInt(u64, bytes[32..40], 1_790_897_123, .little);
    std.mem.writeInt(u64, bytes[40..48], 1_790_897_124, .little);
    std.mem.writeInt(u32, bytes[48..52], 123, .little);
    std.mem.writeInt(u32, bytes[52..56], 456, .little);
    std.mem.writeInt(u32, bytes[56..60], 789, .little);
    std.mem.writeInt(u32, bytes[60..64], mode, .little);
    std.mem.writeInt(u32, bytes[68..72], 501, .little);
    std.mem.writeInt(u32, bytes[72..76], 20, .little);
    return bytes;
}

const Fixture = struct {
    const Edge = struct { parent: u64, name: []const u8, child: u64 };
    objects: [5]Metadata,
    edges: [4]Edge = .{
        .{ .parent = 0, .name = "a", .child = 1 },
        .{ .parent = 1, .name = "b", .child = 2 },
        .{ .parent = 2, .name = "page.md", .child = 3 },
        .{ .parent = 0, .name = "link", .child = 4 },
    },
    root_token: u64 = 0,
    pins: usize = 0,
    peak_pins: usize = 0,
    handles: usize = 0,
    lookups: usize = 0,
    opens: usize = 0,
    reads: usize = 0,
    writes: usize = 0,
    denies: ?[]const u8 = null,
    deny_access: ?Access = null,
    lookup_failure: ?Error = null,
    stat_failure: ?Error = null,
    open_failure: ?Error = null,
    read_failure: ?Error = null,
    write_failure: ?Error = null,
    close_failure: ?Error = null,
    invalid_count: bool = false,
    zero_write: bool = false,
    replace_after_lookup: ?usize = null,
    replace_before_open: bool = false,
    bytes: [4]u8 = .{ 's', 'a', 'f', 'e' },
    mutations: usize = 0,
    mutation_failure: ?Error = null,
    created_kind: Kind = .file,
    last_kind: ?Kind = null,
    last_replace: ?bool = null,

    fn init() !Fixture {
        var result: Fixture = .{ .objects = undefined };
        for (&result.objects, 0..) |*metadata, i| {
            const mode: u32 = if (i < 3) 0o040755 else if (i == 3) 0o100644 else 0o120777;
            const bytes = testAttr(100 + i, mode);
            metadata.* = try decodeFuseAttr(7, &bytes);
        }
        return result;
    }

    fn self(context: *anyopaque) *Fixture {
        return @ptrCast(@alignCast(context));
    }

    fn backend(f: *Fixture) Backend {
        return .{ .context = f, .root_path = "", .ops = &ops };
    }

    fn auth(f: *Fixture) Authorizer {
        return .{ .context = f, .check = check };
    }

    fn check(context: *anyopaque, path: []const u8, access: Access) Error!void {
        const f = self(context);
        if (f.denies) |denied| {
            if (std.mem.eql(u8, path, denied) and
                (f.deny_access == null or f.deny_access.? == access))
                return error.AccessDenied;
        }
    }

    fn pin(f: *Fixture, token: u64) Object {
        f.pins += 1;
        f.peak_pins = @max(f.peak_pins, f.pins);
        return .{ .token = token, .metadata = f.objects[token] };
    }

    fn root(context: *anyopaque) Error!Object {
        const f = self(context);
        return f.pin(f.root_token);
    }

    fn lookup(context: *anyopaque, parent: Object, name: []const u8) Error!Object {
        const f = self(context);
        f.lookups += 1;
        if (f.lookup_failure) |err| return err;
        for (&f.edges, 0..) |*edge, i| {
            if (edge.parent == parent.token and std.mem.eql(u8, edge.name, name)) {
                const child = f.pin(edge.child);
                // Replace the name AFTER pinning the original object.
                if (f.replace_after_lookup == i) edge.child = 4;
                return child;
            }
        }
        return error.FileNotFound;
    }

    fn release(context: *anyopaque, _: Object) void {
        self(context).pins -= 1;
    }

    fn attr(context: *anyopaque, object: Object) Error!Metadata {
        const f = self(context);
        if (f.stat_failure) |err| return err;
        return f.objects[object.token];
    }

    fn openFile(context: *anyopaque, object: Object, _: Access) Error!u64 {
        const f = self(context);
        f.opens += 1;
        if (f.open_failure) |err| return err;
        if (f.replace_before_open) f.edges[2].child = 4;
        if (object.token != 3) return error.NotFile;
        f.handles += 1;
        return object.token;
    }

    fn closeFile(context: *anyopaque, _: u64) Error!void {
        const f = self(context);
        if (f.close_failure) |err| return err;
        f.handles -= 1;
    }

    fn readFile(context: *anyopaque, token: u64, out: []u8) Error!usize {
        const f = self(context);
        f.reads += 1;
        if (f.read_failure) |err| return err;
        if (token != 3) return error.StaleIdentity;
        if (f.invalid_count) return out.len + 1;
        const n = @min(out.len, f.bytes.len);
        @memcpy(out[0..n], f.bytes[0..n]);
        return n;
    }

    fn writeFile(context: *anyopaque, token: u64, bytes: []const u8) Error!usize {
        const f = self(context);
        f.writes += 1;
        if (f.write_failure) |err| return err;
        if (token != 3) return error.StaleIdentity;
        if (f.invalid_count) return bytes.len + 1;
        if (f.zero_write) return 0;
        const n = @min(bytes.len, f.bytes.len);
        @memcpy(f.bytes[0..n], bytes[0..n]);
        return n;
    }

    fn mutate(f: *Fixture) Error!void {
        f.mutations += 1;
        if (f.mutation_failure) |err| return err;
    }

    fn createEntry(context: *anyopaque, _: Object, _: []const u8) Error!Created {
        const f = self(context);
        try f.mutate();
        f.handles += 1;
        var value = f.objects[3];
        if (f.created_kind != .file) value = f.objects[1];
        return .{ .handle = 3, .metadata = value };
    }

    fn makeDir(context: *anyopaque, _: Object, _: []const u8) Error!Object {
        const f = self(context);
        try f.mutate();
        return f.pin(if (f.created_kind == .directory) 1 else 3);
    }

    fn removeEntry(context: *anyopaque, _: Object, _: []const u8, kind: Kind) Error!void {
        const f = self(context);
        f.last_kind = kind;
        try f.mutate();
    }

    fn renameEntry(context: *anyopaque, _: Object, _: []const u8, _: Object, _: []const u8, replace: bool) Error!void {
        const f = self(context);
        f.last_replace = replace;
        try f.mutate();
    }

    fn handleAttr(context: *anyopaque, token: u64) Error!Metadata {
        const f = self(context);
        if (f.stat_failure) |err| return err;
        return f.objects[token];
    }

    const ops = ContainedOps{
        .root = root,
        .lookup = lookup,
        .release = release,
        .stat = attr,
        .open = openFile,
        .close = closeFile,
        .read = readFile,
        .write = writeFile,
        .create = createEntry,
        .mkdir = makeDir,
        .remove = removeEntry,
        .rename = renameEntry,
        .handle_stat = handleAttr,
    };
};

test "metadata: FUSE facts preserve 64-bit sizes and all timestamps" {
    const attr = testAttr(0xabcdef0123456789, 0o100640);
    const value = try decodeFuseAttr(7, &attr);
    try std.testing.expectEqual(@as(u64, 0xabcdef0123456789), value.identity.inode);
    try std.testing.expectEqual(@as(u64, 7), value.identity.filesystem);
    try std.testing.expectEqual(@as(u64, 0x1_0000_0017), value.size);
    try std.testing.expectEqual(@as(i128, -999_999_877), value.atime.toNanoseconds());
    try std.testing.expectEqual(@as(i128, 1_790_897_123_000_000_456), value.mtime.toNanoseconds());
    try std.testing.expectEqual(@as(i128, 1_790_897_124_000_000_789), value.ctime.toNanoseconds());
    try std.testing.expectEqual(@as(u32, 0o100640), value.host_mode);
    try std.testing.expectEqual(@as(u32, 501), value.host_uid);
    try std.testing.expectEqual(@as(u32, 20), value.host_gid);
}

test "metadata: all seven FUSE kinds are distinguished" {
    const modes = [_]u32{ 0o100000, 0o040000, 0o120000, 0o020000, 0o060000, 0o010000, 0o140000 };
    const kinds = [_]Kind{ .file, .directory, .symlink, .character_device, .block_device, .fifo, .socket };
    for (modes, kinds) |mode, kind| {
        const attr = testAttr(1, mode | 0o644);
        try std.testing.expectEqual(kind, (try decodeFuseAttr(7, &attr)).kind);
    }
}

test "metadata: every truncated FUSE attribute refuses" {
    const attr = testAttr(1, 0o040755);
    for (0..fuse_attr_bytes) |cut|
        try std.testing.expectError(error.InvalidMetadata, decodeFuseAttr(7, attr[0..cut]));
}

test "metadata: zero identities invalid kinds and nanoseconds refuse" {
    var attr = testAttr(0, 0o040755);
    try std.testing.expectError(error.InvalidMetadata, decodeFuseAttr(7, &attr));
    attr = testAttr(1, 0o040755);
    try std.testing.expectError(error.InvalidMetadata, decodeFuseAttr(0, &attr));
    var inconsistent = try decodeFuseAttr(7, &attr);
    inconsistent.kind = .file;
    try std.testing.expectError(error.InvalidMetadata, inconsistent.validate());
    attr = testAttr(1, 0o755);
    try std.testing.expectError(error.InvalidMetadata, decodeFuseAttr(7, &attr));
    for ([_]usize{ 48, 52, 56 }) |off| {
        attr = testAttr(1, 0o040755);
        std.mem.writeInt(u32, attr[off..][0..4], 1_000_000_000, .little);
        try std.testing.expectError(error.InvalidMetadata, decodeFuseAttr(7, &attr));
    }
}

test "metadata: valid epoch zero comes from actual reply bytes" {
    var attr = @as([fuse_attr_bytes]u8, @splat(@as(u8, 0)));
    std.mem.writeInt(u64, attr[0..8], 1, .little);
    std.mem.writeInt(u32, attr[60..64], 0o040755, .little);
    const value = try decodeFuseAttr(7, &attr);
    try std.testing.expectEqual(@as(i128, 0), value.mtime.toNanoseconds());
    try std.testing.expectEqual(@as(u64, 0), value.size);
}

test "metadata: LOOKUP rejects every cut and a zero node id" {
    var entry = @as([fuse_entry_bytes]u8, @splat(@as(u8, 0)));
    std.mem.writeInt(u64, entry[0..8], 99, .little);
    std.mem.writeInt(u64, entry[8..16], 17, .little);
    @memcpy(entry[40..], &testAttr(123, 0o040755));
    for (0..fuse_entry_bytes) |cut|
        try std.testing.expectError(error.InvalidMetadata, decodeFuseLookup(7, entry[0..cut]));
    const result = try decodeFuseLookup(7, &entry);
    try std.testing.expectEqual(@as(u64, 99), result.node);
    try std.testing.expectEqual(@as(u64, 17), result.generation);
    try std.testing.expectEqual(@as(u64, 123), result.metadata.identity.inode);
    std.mem.writeInt(u64, entry[0..8], 0, .little);
    try std.testing.expectError(error.InvalidMetadata, decodeFuseLookup(7, &entry));
}

test "metadata: GETATTR rejects every cut and decodes root attributes" {
    var reply = @as([fuse_getattr_bytes]u8, @splat(@as(u8, 0)));
    @memcpy(reply[16..], &testAttr(77, 0o040700));
    for (0..fuse_getattr_bytes) |cut|
        try std.testing.expectError(error.InvalidMetadata, decodeFuseGetattr(7, reply[0..cut]));
    const result = try decodeFuseGetattr(7, &reply);
    try std.testing.expectEqual(@as(u64, 77), result.identity.inode);
    try std.testing.expectEqual(Kind.directory, result.kind);
    try std.testing.expectEqual(@as(u64, 0x1_0000_0017), result.size);
}

test "metadata: FUSE failures have explicit distinct meanings" {
    try std.testing.expectEqual(error.FileNotFound, fuseError(-2));
    try std.testing.expectEqual(error.AccessDenied, fuseError(-13));
    try std.testing.expectEqual(error.AccessDenied, fuseError(-1));
    try std.testing.expectEqual(error.NotDirectory, fuseError(-20));
    try std.testing.expectEqual(error.SymlinkRejected, fuseError(-40));
    try std.testing.expectEqual(error.MetadataUnavailable, fuseError(-38));
    try std.testing.expectEqual(error.MetadataUnavailable, fuseError(-95));
    try std.testing.expectEqual(error.StaleIdentity, fuseError(-116));
    try std.testing.expectEqual(error.Exists, fuseError(-17));
    try std.testing.expectEqual(error.Exists, fuseError(-39));
    try std.testing.expectEqual(error.ContainmentUnavailable, fuseError(-18));
    try std.testing.expectEqual(error.NotFile, fuseError(-21));
    try std.testing.expectEqual(error.Io, fuseError(-5));
    try std.testing.expectEqual(error.Io, fuseError(std.math.minInt(i32)));
    try std.testing.expectEqual(error.InvalidMetadata, fuseError(0));
    try std.testing.expectEqual(error.InvalidMetadata, fuseError(2));
}

test "metadata: watch stamp detects independent mtime and size changes" {
    var f = try Fixture.init();
    const before = f.objects[3];
    try std.testing.expect(!Metadata.watchChanged(before, before));
    f.objects[3].mtime.nanoseconds += 1;
    try std.testing.expect(Metadata.watchChanged(before, f.objects[3]));
    f.objects[3] = before;
    f.objects[3].size += 1;
    try std.testing.expect(Metadata.watchChanged(before, f.objects[3]));
    f.objects[3] = before;
    f.objects[3].atime.seconds += 1;
    f.objects[3].ctime.seconds += 1;
    try std.testing.expect(!Metadata.watchChanged(before, f.objects[3]));
}

test "metadata: approved B2 full-path and component budgets are exact" {
    try validatePath(&@as([255:0]u8, @splat("x"[0])));
    try std.testing.expectError(error.PathLimit, validatePath(&@as([256:0]u8, @splat("x"[0]))));
    const exact = &@as([255:0]u8, @splat("x"[0])) ++ "/" ++ &@as([250:0]u8, @splat("y"[0]));
    try std.testing.expectEqual(@as(usize, max_guest_path), exact.len + guest_prefix.len);
    try validatePath(exact);
    try std.testing.expectError(error.PathLimit, validatePath(exact ++ "y"));
    const at_content_root = &@as([255:0]u8, @splat("x"[0])) ++ "/" ++ &@as([242:0]u8, @splat("y"[0]));
    try std.testing.expectEqual(@as(usize, max_guest_path), guest_prefix.len + "content/".len + at_content_root.len);
    try validateRootedPath("content", at_content_root);
    try std.testing.expectError(error.PathLimit, validateRootedPath("content", at_content_root ++ "y"));
    var f = try Fixture.init();
    var backend = f.backend();
    backend.root_path = "content";
    try std.testing.expectError(error.PathLimit, stat(backend, f.auth(), at_content_root ++ "y"));
    try std.testing.expectEqual(@as(usize, 0), f.pins);
}

test "metadata: depth and unnormalized paths refuse before lookup" {
    try validatePath("");
    try validatePath("a/b/c/d/e/f/g/h");
    try std.testing.expectError(error.TreeLimit, validatePath("a/b/c/d/e/f/g/h/i"));
    for ([_][]const u8{ "/a", "a/", "a//b", ".", "..", "a/../b", "a/./b", "a\x00b" }) |path|
        try std.testing.expectError(error.InvalidPath, validatePath(path));
    var f = try Fixture.init();
    try std.testing.expectError(error.InvalidPath, stat(f.backend(), f.auth(), "a/../b"));
    try std.testing.expectEqual(@as(usize, 0), f.lookups);
    try std.testing.expectEqual(@as(usize, 0), f.pins);
}

test "metadata: nested scanner identities are distinct stable and filesystem scoped" {
    var f = try Fixture.init();
    var seen = std.AutoHashMap(Identity, void).init(std.testing.allocator);
    defer seen.deinit();
    for ([_][]const u8{ "", "a", "a/b" }) |path| {
        const first = try stat(f.backend(), f.auth(), path);
        const again = try stat(f.backend(), f.auth(), path);
        try std.testing.expect(first.identity.eql(again.identity));
        try std.testing.expect(!seen.contains(first.identity));
        try seen.put(first.identity, {});
    }
    try std.testing.expectEqual(@as(usize, 3), seen.count());
    const same_inode_other_fs = Identity{ .filesystem = 8, .inode = 100 };
    try std.testing.expect(!seen.contains(same_inode_other_fs));
    try std.testing.expectEqual(@as(usize, 0), f.pins);
    try std.testing.expectEqual(@as(usize, 2), f.peak_pins);
}

test "metadata: root intermediate leaf and dangling symlinks are rejected" {
    for (0..4) |position| {
        var f = try Fixture.init();
        if (position == 0) {
            f.root_token = 4;
        } else {
            f.edges[position - 1].child = 4;
        }
        try std.testing.expectError(error.SymlinkRejected, stat(f.backend(), f.auth(), "a/b/page.md"));
        try std.testing.expectError(error.SymlinkRejected, open(f.backend(), f.auth(), "a/b/page.md", .read));
        try std.testing.expectEqual(@as(usize, 0), f.opens);
        try std.testing.expectEqual(@as(usize, 0), f.pins);
    }
    var f = try Fixture.init();
    try std.testing.expectError(error.SymlinkRejected, stat(f.backend(), f.auth(), "link"));
}

test "metadata: directory replacement after lookup cannot redirect traversal" {
    var f = try Fixture.init();
    f.replace_after_lookup = 0;
    const found = try stat(f.backend(), f.auth(), "a/b/page.md");
    try std.testing.expectEqual(@as(u64, 103), found.identity.inode);
    try std.testing.expectEqual(@as(usize, 0), f.pins);
    try std.testing.expectError(error.SymlinkRejected, stat(f.backend(), f.auth(), "a/b/page.md"));
}

test "metadata: leaf replacement between check and open never opens the replacement" {
    var f = try Fixture.init();
    f.replace_before_open = true;
    var file = try open(f.backend(), f.auth(), "a/b/page.md", .read);
    var bytes: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try file.read(&bytes));
    try std.testing.expectEqualStrings("safe", &bytes);
    try file.close();
    try std.testing.expectError(error.SymlinkRejected, open(f.backend(), f.auth(), "a/b/page.md", .read));
    try std.testing.expectEqual(@as(usize, 0), f.handles);
    try std.testing.expectEqual(@as(usize, 0), f.pins);
}

test "metadata: mutation after leaf replacement writes only the pinned file" {
    var f = try Fixture.init();
    var file = try open(f.backend(), f.auth(), "a/b/page.md", .write);
    f.edges[2].child = 4;
    try std.testing.expectEqual(@as(usize, 4), try file.write("edit"));
    try std.testing.expectEqualStrings("edit", &f.bytes);
    try file.close();
    try std.testing.expectError(error.SymlinkRejected, open(f.backend(), f.auth(), "a/b/page.md", .write));
    try std.testing.expectEqual(@as(usize, 0), f.pins);
}

test "metadata: changed identity or kind at stat refuses instead of trusting old metadata" {
    var f = try Fixture.init();
    const object = try resolve(f.backend(), f.auth(), "a/b/page.md", .metadata);
    defer Fixture.release(&f, object);
    f.objects[3].identity.inode += 1;
    try std.testing.expectError(error.StaleIdentity, checkedStat(f.backend(), object));
    f.objects[3] = f.objects[4];
    try std.testing.expectError(error.SymlinkRejected, checkedStat(f.backend(), object));
}

test "metadata: cross-filesystem lookup is an explicit containment refusal" {
    var f = try Fixture.init();
    f.objects[1].identity.filesystem = 8;
    try std.testing.expectError(error.ContainmentUnavailable, stat(f.backend(), f.auth(), "a/b/page.md"));
    try std.testing.expectEqual(@as(usize, 0), f.pins);
}

test "metadata: missing metadata or containment is never a successful empty stat" {
    var f = try Fixture.init();
    const unsupported = Backend{ .context = &f, .root_path = "", .ops = null };
    try std.testing.expectError(error.ContainmentUnavailable, stat(unsupported, f.auth(), ""));
    try std.testing.expectError(error.ContainmentUnavailable, open(unsupported, f.auth(), "a", .read));
    f.stat_failure = error.MetadataUnavailable;
    try std.testing.expectError(error.MetadataUnavailable, stat(f.backend(), f.auth(), ""));
    try std.testing.expectEqual(@as(usize, 0), f.pins);
}

test "metadata: root intermediate and leaf authorization precedes backend use" {
    for ([_][]const u8{ "", "a", "a/b", "a/b/page.md" }, 0..) |path, allowed_lookups| {
        var f = try Fixture.init();
        f.denies = path;
        try std.testing.expectError(error.AccessDenied, stat(f.backend(), f.auth(), "a/b/page.md"));
        try std.testing.expectEqual(allowed_lookups -| 1, f.lookups);
        try std.testing.expectEqual(@as(usize, 0), f.pins);
    }
}

test "metadata: permission revocation is enforced on every read and write" {
    for ([_]Access{ .read, .write }) |access| {
        for ([_][]const u8{ "", "a", "a/b", "a/b/page.md" }) |denied| {
            var f = try Fixture.init();
            var file = try open(f.backend(), f.auth(), "a/b/page.md", access);
            f.denies = denied;
            var bytes: [4]u8 = undefined;
            if (access == .read) {
                try std.testing.expectError(error.AccessDenied, file.read(&bytes));
            } else {
                try std.testing.expectError(error.AccessDenied, file.write("evil"));
                try std.testing.expectEqualStrings("safe", &f.bytes);
            }
            try std.testing.expectEqual(@as(usize, 0), f.reads + f.writes);
            try file.close();
        }
    }
}

test "metadata: wrong-direction access and closed handles explicitly refuse" {
    var f = try Fixture.init();
    var file = try open(f.backend(), f.auth(), "a/b/page.md", .read);
    try std.testing.expectError(error.AccessDenied, file.write("evil"));
    try file.close();
    var bytes: [4]u8 = undefined;
    try std.testing.expectError(error.StaleIdentity, file.read(&bytes));
    try std.testing.expectError(error.StaleIdentity, file.close());
    try std.testing.expectEqual(@as(usize, 0), f.handles);
}

test "metadata: lookup stat and open failures release all traversal pins" {
    for ([_]Error{ error.FileNotFound, error.AccessDenied, error.Io, error.StaleIdentity, error.HandleLimit }) |err| {
        var f = try Fixture.init();
        f.lookup_failure = err;
        try std.testing.expectError(err, stat(f.backend(), f.auth(), "a/b/page.md"));
        try std.testing.expectEqual(@as(usize, 0), f.pins);
        f.lookup_failure = null;
        f.stat_failure = err;
        try std.testing.expectError(err, open(f.backend(), f.auth(), "a/b/page.md", .read));
        try std.testing.expectEqual(@as(usize, 0), f.pins);
        f.stat_failure = null;
        f.open_failure = err;
        try std.testing.expectError(err, open(f.backend(), f.auth(), "a/b/page.md", .write));
        try std.testing.expectEqual(@as(usize, 0), f.pins);
        try std.testing.expectEqual(@as(usize, 0), f.handles);
    }
}

test "metadata: directory and special-file opens refuse without touching data" {
    var f = try Fixture.init();
    try std.testing.expectError(error.NotFile, open(f.backend(), f.auth(), "a/b", .read));
    try std.testing.expectError(error.NotFile, open(f.backend(), f.auth(), "a/b/page.md", .metadata));
    f.objects[3] = try decodeFuseAttr(7, &testAttr(103, 0o010600));
    try std.testing.expectError(error.NotFile, open(f.backend(), f.auth(), "a/b/page.md", .write));
    try std.testing.expectEqual(@as(usize, 0), f.opens);
    try std.testing.expectEqual(@as(usize, 0), f.pins);
}

test "metadata: failed I/O cannot become EOF or confirmed progress" {
    var f = try Fixture.init();
    var reader = try open(f.backend(), f.auth(), "a/b/page.md", .read);
    var writer = try open(f.backend(), f.auth(), "a/b/page.md", .write);
    f.read_failure = error.Io;
    f.write_failure = error.Io;
    var bytes: [4]u8 = undefined;
    try std.testing.expectError(error.Io, reader.read(&bytes));
    try std.testing.expectError(error.Io, writer.write("evil"));
    try std.testing.expectEqualStrings("safe", &f.bytes);
    f.read_failure = null;
    f.write_failure = null;
    f.invalid_count = true;
    try std.testing.expectError(error.InvalidMetadata, reader.read(&bytes));
    try std.testing.expectError(error.InvalidMetadata, writer.write("evil"));
    f.invalid_count = false;
    f.zero_write = true;
    try std.testing.expectError(error.Io, writer.write("evil"));
    try std.testing.expectEqual(@as(usize, 0), try writer.write(""));
    try reader.close();
    try writer.close();
}

test "metadata: close failure is explicit and does not pretend resource recovery" {
    var f = try Fixture.init();
    var file = try open(f.backend(), f.auth(), "a/b/page.md", .read);
    f.close_failure = error.Io;
    try std.testing.expectError(error.Io, file.close());
    try std.testing.expect(!file.closed);
    try std.testing.expectEqual(@as(usize, 1), f.handles);
    f.close_failure = null;
    try file.close();
    try std.testing.expect(file.closed);
    try std.testing.expectEqual(@as(usize, 0), f.handles);
}

test "B3: rich snapshot wire preserves facts padding and exact entry ceiling" {
    var snapshot = Snapshot{};
    const attr = testAttr(123, 0o040755);
    const value = try decodeFuseAttr(7, &attr);
    try snapshot.append("directory", value);
    const row = snapshot.entries[0];
    try std.testing.expectEqual(@as(u64, 0x1_0000_0017), row.metadata.size);
    try std.testing.expectEqual(value.identity, row.metadata.identity);
    try std.testing.expectEqual(@as(u32, 456), row.metadata.mtime.nanoseconds);
    try std.testing.expectEqualSlices(u8, &(@as([6]u8, @splat(@as(u8, 0)))), &row.reserved);
    try std.testing.expectEqualSlices(u8, &(@as([247]u8, @splat(@as(u8, 0)))), row.name[9..]);
    try std.testing.expectEqual(@as(u32, 0), row.metadata.mtime.reserved);
    try std.testing.expectError(error.StaleIdentity, snapshot.append("directory", value));
    const link = try decodeFuseAttr(7, &testAttr(124, 0o120777));
    try std.testing.expectError(error.SymlinkRejected, snapshot.append("link", link));
    var name: [16]u8 = undefined;
    while (snapshot.count < directory.entry_max) {
        try snapshot.append(try std.fmt.bufPrint(&name, "row-{d}", .{snapshot.count}), value);
    }
    try std.testing.expectError(error.TreeLimit, snapshot.append("overflow", value));
    try std.testing.expectEqual(directory.entry_max, snapshot.count);
}

test "B3: supplied root and relative depth budgets remain independent" {
    try validateRootedPath("content/one/two/three", "a/b/c/d/e/f/g/h");
    try std.testing.expectError(error.TreeLimit, validateRootedPath("content", "a/b/c/d/e/f/g/h/i"));
    try std.testing.expectError(error.PathLimit, validateRootedPath("root", &@as([255:0]u8, @splat("a"[0])) ++ "/" ++ &@as([250:0]u8, @splat("b"[0]))));
}

test "B3: in-place snapshot sort preserves every full-capacity row" {
    var snapshot = Snapshot{};
    var name: [16]u8 = undefined;
    for (0..directory.entry_max) |i| {
        const index = directory.entry_max - i - 1;
        var value = try decodeFuseAttr(7, &testAttr(index + 1, 0o100640));
        value.size = index;
        try snapshot.append(try std.fmt.bufPrint(&name, "row-{d:0>3}", .{index}), value);
    }
    for (0..2) |_| {
        snapshot.sort();
        try std.testing.expectEqual(directory.entry_max, snapshot.count);
        for (snapshot.entries[0..snapshot.count], 0..) |entry, i| {
            try std.testing.expectEqualStrings(
                try std.fmt.bufPrint(&name, "row-{d:0>3}", .{i}),
                entry.name[0..entry.name_len],
            );
            try std.testing.expectEqual(@as(u64, i + 1), entry.metadata.identity.inode);
            try std.testing.expectEqual(@as(u64, i), entry.metadata.size);
            try std.testing.expectEqual(@as(u32, 0o100640), entry.metadata.host_mode);
            try std.testing.expect(std.mem.allEqual(u8, entry.name[entry.name_len..], 0));
            try std.testing.expect(std.mem.allEqual(u8, &entry.reserved, 0));
        }
    }
}

fn testDirectory(f: *Fixture, token: u64, path: []const u8) Directory {
    return .{ .object = .{ .token = token, .metadata = f.objects[token] }, .path = path };
}

test "B5: names joined paths and depth refuse before backend use" {
    var buffer: [max_relative_path]u8 = undefined;
    try std.testing.expectEqualStrings("a/b", try childPath("a", "b", &buffer));
    try std.testing.expectEqualStrings("b", try childPath("", "b", &buffer));
    for ([_][]const u8{ "", ".", "..", "a/b", "a\x00" }) |name|
        try std.testing.expectError(error.InvalidPath, childPath("a", name, &buffer));
    try std.testing.expectError(error.PathLimit, childPath("a", &@as([256:0]u8, @splat("x"[0])), &buffer));
    _ = try childPath(&@as([255:0]u8, @splat("x"[0])), &@as([250:0]u8, @splat("y"[0])), &buffer);
    try std.testing.expectError(error.PathLimit, childPath(&@as([255:0]u8, @splat("x"[0])), &@as([251:0]u8, @splat("y"[0])), &buffer));
    const deep = "a/b/c/d/e/f/g/h/i/j/k/l/m/n/o";
    _ = try childPath(deep, "p", &buffer);
    try std.testing.expectError(error.TreeLimit, childPath(deep ++ "/p", "q", &buffer));
    var f = try Fixture.init();
    const dir = testDirectory(&f, 1, "a");
    try std.testing.expectError(error.InvalidPath, createFile(f.backend(), f.auth(), dir, ".."));
    try std.testing.expectError(error.InvalidPath, makeDirectory(f.backend(), f.auth(), dir, "x/y"));
    try std.testing.expectError(error.InvalidPath, remove(f.backend(), f.auth(), dir, "", .file));
    try std.testing.expectError(error.InvalidPath, remove(f.backend(), f.auth(), dir, "x", .symlink));
    try std.testing.expectError(error.InvalidPath, rename(f.backend(), f.auth(), dir, ".", dir, "x", false));
    try std.testing.expectError(error.InvalidPath, rename(f.backend(), f.auth(), dir, "x", dir, "..", true));
    try std.testing.expectError(error.InvalidPath, childDirectory(f.backend(), f.auth(), dir, "x/y"));
    try std.testing.expectEqual(@as(usize, 0), f.mutations + f.lookups + f.pins);
}

test "B5: every mutation authorizes root ancestors and target before backend use" {
    for ([_][]const u8{ "", "a", "a/x" }) |denied| {
        var f = try Fixture.init();
        f.denies = denied;
        const dir = testDirectory(&f, 1, "a");
        try std.testing.expectError(error.AccessDenied, createFile(f.backend(), f.auth(), dir, "x"));
        try std.testing.expectError(error.AccessDenied, makeDirectory(f.backend(), f.auth(), dir, "x"));
        try std.testing.expectError(error.AccessDenied, remove(f.backend(), f.auth(), dir, "x", .file));
        try std.testing.expectError(error.AccessDenied, rename(f.backend(), f.auth(), dir, "x", dir, "y", true));
        try std.testing.expectError(error.AccessDenied, rename(f.backend(), f.auth(), dir, "y", dir, "x", true));
        try std.testing.expectError(error.AccessDenied, childDirectory(f.backend(), f.auth(), dir, "x"));
        if (denied.len < 2) {
            try std.testing.expectError(error.AccessDenied, directoryMetadata(f.backend(), f.auth(), dir));
            try std.testing.expectError(error.AccessDenied, openDirectory(f.backend(), f.auth(), "a"));
        }
        try std.testing.expectEqual(@as(usize, 0), f.mutations + f.lookups + f.pins);
    }
    var f = try Fixture.init();
    const dir = testDirectory(&f, 1, "a");
    f.denies = "a/x";
    f.deny_access = .delete;
    try std.testing.expectError(error.AccessDenied, rename(f.backend(), f.auth(), dir, "x", dir, "y", false));
    try std.testing.expectError(error.AccessDenied, remove(f.backend(), f.auth(), dir, "x", .directory));
    try rename(f.backend(), f.auth(), dir, "y", dir, "x", false);
    try std.testing.expectEqual(@as(?bool, false), f.last_replace);
    _ = try createFile(f.backend(), f.auth(), dir, "x");
    f.deny_access = .create;
    try std.testing.expectError(error.AccessDenied, rename(f.backend(), f.auth(), dir, "y", dir, "x", true));
    try std.testing.expectError(error.AccessDenied, createFile(f.backend(), f.auth(), dir, "x"));
    try std.testing.expectError(error.AccessDenied, makeDirectory(f.backend(), f.auth(), dir, "x"));
    try rename(f.backend(), f.auth(), dir, "x", dir, "y", true);
    try std.testing.expectEqual(@as(?bool, true), f.last_replace);
    try remove(f.backend(), f.auth(), dir, "x", .directory);
    try std.testing.expectEqual(@as(?Kind, .directory), f.last_kind);
    try std.testing.expectEqual(@as(usize, 4), f.mutations);
}

test "B5: child pins refuse links files stale identities and other filesystems" {
    var f = try Fixture.init();
    const root_pin = try openDirectory(f.backend(), f.auth(), "");
    const parent = Directory{ .object = root_pin, .path = "" };
    const a = try childDirectory(f.backend(), f.auth(), parent, "a");
    try std.testing.expectEqual(@as(u64, 101), a.metadata.identity.inode);
    try std.testing.expectEqual(@as(u64, 101), (try directoryMetadata(f.backend(), f.auth(), .{ .object = a, .path = "a" })).identity.inode);
    Fixture.release(&f, a);
    try std.testing.expectError(error.SymlinkRejected, childDirectory(f.backend(), f.auth(), parent, "link"));
    try std.testing.expectError(error.FileNotFound, childDirectory(f.backend(), f.auth(), parent, "missing"));
    const b = try openDirectory(f.backend(), f.auth(), "a/b");
    try std.testing.expectError(error.NotDirectory, childDirectory(f.backend(), f.auth(), .{ .object = b, .path = "a/b" }, "page.md"));
    try std.testing.expectError(error.NotDirectory, openDirectory(f.backend(), f.auth(), "a/b/page.md"));
    f.objects[2].identity.inode += 1;
    try std.testing.expectError(error.StaleIdentity, directoryMetadata(f.backend(), f.auth(), .{ .object = b, .path = "a/b" }));
    Fixture.release(&f, b);
    f.objects[1].identity.filesystem = 8;
    try std.testing.expectError(error.ContainmentUnavailable, childDirectory(f.backend(), f.auth(), parent, "a"));
    Fixture.release(&f, root_pin);
    try std.testing.expectEqual(@as(usize, 0), f.pins);
}

test "B5: created objects must have the requested kind and refusals stay refusals" {
    var f = try Fixture.init();
    const dir = testDirectory(&f, 1, "a");
    const created = try createFile(f.backend(), f.auth(), dir, "x");
    try std.testing.expectEqual(@as(u64, 103), created.metadata.identity.inode);
    try std.testing.expectError(error.InvalidMetadata, makeDirectory(f.backend(), f.auth(), dir, "x"));
    try std.testing.expectEqual(@as(usize, 0), f.pins);
    f.created_kind = .directory;
    try std.testing.expectError(error.InvalidMetadata, createFile(f.backend(), f.auth(), dir, "x"));
    Fixture.release(&f, try makeDirectory(f.backend(), f.auth(), dir, "x"));
    try std.testing.expectEqual(@as(usize, 0), f.pins);
    f.mutation_failure = error.Exists;
    try std.testing.expectError(error.Exists, createFile(f.backend(), f.auth(), dir, "x"));
    try std.testing.expectError(error.Exists, makeDirectory(f.backend(), f.auth(), dir, "x"));
    try std.testing.expectError(error.Exists, remove(f.backend(), f.auth(), dir, "x", .directory));
    try std.testing.expectError(error.Exists, rename(f.backend(), f.auth(), dir, "x", dir, "y", false));
    try std.testing.expectEqual(@as(u64, 103), (try handleMetadata(f.backend(), f.auth(), 3, "a/b/page.md")).identity.inode);
    try std.testing.expectError(error.StaleIdentity, handleMetadata(f.backend(), f.auth(), 1, "a/b/page.md"));
    try std.testing.expectError(error.SymlinkRejected, handleMetadata(f.backend(), f.auth(), 4, "a/b/page.md"));
    f.denies = "a/b/page.md";
    try std.testing.expectError(error.AccessDenied, handleMetadata(f.backend(), f.auth(), 3, "a/b/page.md"));
    var other = testDirectory(&f, 2, "a/b");
    other.object.metadata.identity.filesystem = 8;
    f.mutation_failure = null;
    try std.testing.expectError(error.ContainmentUnavailable, rename(f.backend(), f.auth(), dir, "x", other, "y", true));
}

test "B5: backends without containment refuse every pinned operation" {
    var f = try Fixture.init();
    const unsupported = Backend{ .context = &f, .root_path = "", .ops = null };
    const dir = testDirectory(&f, 1, "a");
    try std.testing.expectError(error.ContainmentUnavailable, openDirectory(unsupported, f.auth(), ""));
    try std.testing.expectError(error.ContainmentUnavailable, childDirectory(unsupported, f.auth(), dir, "b"));
    try std.testing.expectError(error.ContainmentUnavailable, directoryMetadata(unsupported, f.auth(), dir));
    try std.testing.expectError(error.ContainmentUnavailable, handleMetadata(unsupported, f.auth(), 3, "a/b/page.md"));
    try std.testing.expectError(error.ContainmentUnavailable, createFile(unsupported, f.auth(), dir, "x"));
    try std.testing.expectError(error.ContainmentUnavailable, makeDirectory(unsupported, f.auth(), dir, "x"));
    try std.testing.expectError(error.ContainmentUnavailable, remove(unsupported, f.auth(), dir, "x", .file));
    try std.testing.expectError(error.ContainmentUnavailable, rename(unsupported, f.auth(), dir, "x", dir, "y", true));
    try std.testing.expectEqual(@as(usize, 0), f.mutations + f.lookups + f.pins);
}
