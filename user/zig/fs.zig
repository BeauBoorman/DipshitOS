//! ADR 0007 B2/B3/B4/B5, not POSIX. Host attributes are facts, not guest ACLs.
//! Use runtime.filesystem() so cursors, pins and files share the SDK resource table.
const std = @import("std");

pub const path_max = 512;
pub const name_max = 255;
pub const depth_max = 8;
/// B5: a pinned directory's share-relative path, including child pins.
pub const pinned_depth_max = 16;
pub const entry_max = 256;
pub const page_max = 16;
// B5 slot-79 operations and register encodings (native wire values).
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
pub const rename_replace: u64 = 1 << 32;
pub const Error = error{
    InvalidArgument,
    InvalidHandle,
    BadAddress,
    Unsupported,
    ResourceLimit,
    FileNotFound,
    AccessDenied,
    NameTooLong,
    PathAlreadyExists,
    OutOfMemory,
    ProtocolViolation,
};
pub const OpenMode = enum { read, write };
pub const Publication = enum { replace, preserve_existing };
/// Not a native cursor or file descriptor. Tokens are never recycled.
pub const Snapshot = struct { token: i64 };
/// A B5 pinned directory: the native object, not its pathname. SDK tokens
/// are never recycled and never alias snapshots or files.
pub const Directory = struct { token: i64 };
pub const EntryKind = enum { file, directory };
pub const Identity = extern struct {
    filesystem: u64,
    inode: u64,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.filesystem == b.filesystem and a.inode == b.inode;
    }
    fn validate(self: Identity) Error!void {
        if (self.filesystem == 0 or self.inode == 0) return error.ProtocolViolation;
    }
};
pub const Kind = enum(u32) { file, directory, symlink, character_device, block_device, fifo, socket, _ };
pub const Timestamp = extern struct {
    seconds: i64,
    nanoseconds: u32,
    reserved: u32 = 0,

    pub fn toNanoseconds(self: Timestamp) i128 {
        return @as(i128, self.seconds) * 1_000_000_000 + self.nanoseconds;
    }
};
pub const Metadata = extern struct {
    version: u32,
    kind: Kind,
    identity: Identity,
    size: u64,
    atime: Timestamp,
    mtime: Timestamp,
    ctime: Timestamp,
    host_mode: u32,
    host_uid: u32,
    host_gid: u32,
    reserved: u32,

    pub fn validate(self: Metadata) Error!void {
        if (self.version != 1 or @backingInt(self.kind) > 6 or self.reserved != 0)
            return error.ProtocolViolation;
        try self.identity.validate();
        for ([_]Timestamp{ self.atime, self.mtime, self.ctime }) |time| {
            if (time.nanoseconds >= 1_000_000_000 or time.reserved != 0)
                return error.ProtocolViolation;
        }
        const mode_kind: u32 = switch (self.kind) {
            .file => 0o100000,
            .directory => 0o040000,
            .symlink => 0o120000,
            .character_device => 0o020000,
            .block_device => 0o060000,
            .fifo => 0o010000,
            .socket => 0o140000,
            _ => return error.ProtocolViolation,
        };
        if (self.host_mode & 0o170000 != mode_kind) return error.ProtocolViolation;
        // The supported family promises no-follow, including returned rows.
        if (self.kind == .symlink) return error.ProtocolViolation;
    }
};
pub const Entry = extern struct {
    name: [256]u8,
    name_len: u16,
    reserved: [6]u8,
    metadata: Metadata,

    pub fn nameBytes(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }
};
pub const Page = extern struct {
    header: extern struct { next: u64, count: u32, end: u32 },
    entries: [page_max]Entry,

    pub fn rows(self: *const Page) []const Entry {
        return self.entries[0..self.header.count];
    }
    pub fn done(self: *const Page) bool {
        return self.header.end == 1;
    }
    pub fn validate(self: *const Page, offset: u64, limit: usize, count: i64) Error!void {
        if (count < 0 or count > limit or self.header.count != count or
            self.header.end > 1 or offset > entry_max or
            self.header.next != offset + self.header.count or self.header.next > entry_max or
            (count == 0 and !self.done()))
            return error.ProtocolViolation;
        for (self.rows(), 0..) |*entry, i| {
            if (entry.name_len == 0 or entry.name_len > name_max or
                !std.mem.allEqual(u8, entry.name[entry.name_len..], 0) or
                !std.mem.allEqual(u8, &entry.reserved, 0))
                return error.ProtocolViolation;
            const name = entry.nameBytes();
            if (std.mem.indexOfAny(u8, name, "/\x00") != null or
                std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
                return error.ProtocolViolation;
            try entry.metadata.validate();
            // Native snapshots are sorted. Never silently drop duplicate names.
            if (i != 0 and std.mem.order(u8, self.entries[i - 1].nameBytes(), name) != .lt)
                return error.ProtocolViolation;
        }
    }
};
comptime {
    if (@sizeOf(Metadata) != 96 or @offsetOf(Metadata, "host_mode") != 80 or
        @sizeOf(Identity) != 16 or @sizeOf(Entry) != 360 or
        @offsetOf(Entry, "metadata") != 264 or @sizeOf(Page) != 5776)
        @compileError("UnreviewedFilesystemWire");
}

/// Native file-domain errors only. EINVAL may be transport I/O; never relabel
/// it EOF, a type conflict, or proof that a submitted rename did not commit.
pub fn result(value: i64) Error!u64 {
    if (value >= 0) return @intCast(value);
    return switch (value) {
        -1 => error.InvalidArgument,
        -2 => error.InvalidHandle,
        -3 => error.BadAddress,
        -4 => error.Unsupported,
        -5 => error.ResourceLimit,
        -6 => error.FileNotFound,
        -7 => error.AccessDenied,
        -8 => error.NameTooLong,
        -9 => error.PathAlreadyExists,
        -10 => error.OutOfMemory,
        else => error.ProtocolViolation,
    };
}

fn relativePath(name: []const u8) Error!void {
    if (name.len == 0) return;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidArgument;
    var parts = std.mem.splitScalar(u8, name, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            return error.InvalidArgument;
        if (part.len > name_max) return error.NameTooLong;
        depth += 1;
        if (depth > depth_max) return error.ResourceLimit;
    }
}

/// Validates spelling/bounds only. Containment is supplied by slot 79 itself.
pub fn rootedPath(root: []const u8, relative: []const u8) Error!void {
    if (!std.mem.eql(u8, root, "/host") and !std.mem.startsWith(u8, root, "/host/"))
        return error.AccessDenied;
    if (root.len > path_max or relative.len > path_max or
        root.len + @intFromBool(relative.len != 0) + relative.len > path_max)
        return error.NameTooLong;
    if (root.len != 5) {
        if (root.len == 6) return error.InvalidArgument;
        try relativePath(root[6..]);
    }
    try relativePath(relative);
}

/// One B5 directory entry name. Opaque bytes except `/`, NUL and dot names.
pub fn entryName(name: []const u8) Error!void {
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\x00") != null or
        std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
        return error.InvalidArgument;
    if (name.len > name_max) return error.NameTooLong;
}

/// Legacy/B4 full paths have eight components below /host, not below an
/// arbitrary deeper content root. No normalization, clipping or escape repair.
pub fn fullPath(name: []const u8, buffer: []u8) Error![]const u8 {
    if (name.len == 0) return error.InvalidArgument;
    if (std.mem.indexOfAny(u8, name, "\\:") != null) return error.InvalidArgument;
    const absolute = name[0] == '/';
    if (absolute and !std.mem.startsWith(u8, name, "/host/")) return error.AccessDenied;
    const relative = if (absolute) name[6..] else name;
    if (relative.len == 0) return error.InvalidArgument;
    try rootedPath("/host", relative);
    if (6 + relative.len > buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..6], "/host/");
    @memcpy(buffer[6..][0..relative.len], relative);
    return buffer[0 .. 6 + relative.len];
}

/// Wire calls only. The Io backend owns every returned resource.
pub fn Native(comptime Driver: type) type {
    return struct {
        pub fn pathCall(op: u64, root: []const u8, relative: []const u8, out: usize) Error!u64 {
            try rootedPath(root, relative);
            return result(Driver.call(79, .{ op, @intFromPtr(root.ptr), root.len, @intFromPtr(relative.ptr), relative.len, out }));
        }
        pub fn metadata(root: []const u8, relative: []const u8) Error!Metadata {
            var value = std.mem.zeroes(Metadata);
            if (try pathCall(0, root, relative, @intFromPtr(&value)) != 0) return error.ProtocolViolation;
            try value.validate();
            return value;
        }
        pub fn identity(root: []const u8, relative: []const u8) Error!Identity {
            var value = std.mem.zeroes(Identity);
            if (try pathCall(1, root, relative, @intFromPtr(&value)) != 0) return error.ProtocolViolation;
            try value.validate();
            return value;
        }
        pub fn page(token: u64, offset: u64, limit: usize, output: *Page) Error!void {
            if (limit == 0 or limit > page_max or offset > entry_max) return error.InvalidArgument;
            var scratch = std.mem.zeroes(Page);
            const count = try result(Driver.call(79, .{ 5, token, offset, limit, @intFromPtr(&scratch), 0 }));
            if (count > page_max) return error.ProtocolViolation;
            try scratch.validate(offset, limit, @intCast(count));
            @memcpy(std.mem.asBytes(output), std.mem.asBytes(&scratch));
        }
        pub fn close(token: u64) Error!void {
            if (try result(Driver.call(79, .{ 6, token, 0, 0, 0, 0 })) != 0) return error.ProtocolViolation;
        }
        fn pinToken(value: u64) Error!u64 {
            return if (value == 0) error.ProtocolViolation else value;
        }
        fn named(op: u64, dir: u64, name: []const u8, x4: u64) Error!u64 {
            try entryName(name);
            return result(Driver.call(79, .{ op, dir, @intFromPtr(name.ptr), name.len, x4, 0 }));
        }
        /// B5 pins an existing directory by the B3 no-follow walk.
        pub fn openDirectory(root: []const u8, relative: []const u8) Error!u64 {
            return pinToken(try pathCall(pin_open_op, root, relative, 0));
        }
        /// One no-follow lookup from the pinned directory, not a path walk.
        pub fn childDirectory(dir: u64, name: []const u8) Error!u64 {
            return pinToken(try named(pin_child_op, dir, name, 0));
        }
        pub fn closeDirectory(dir: u64) Error!void {
            if (try result(Driver.call(79, .{ pin_close_op, dir, 0, 0, 0, 0 })) != 0) return error.ProtocolViolation;
        }
        /// Live attributes of the handle's own object, never of its old name.
        pub fn handleMetadata(handle: u64, kind: u64) Error!Metadata {
            var value = std.mem.zeroes(Metadata);
            if (try result(Driver.call(79, .{ handle_metadata_op, handle, kind, 0, 0, @intFromPtr(&value) })) != 0)
                return error.ProtocolViolation;
            try value.validate();
            const expected: Kind = if (kind == handle_directory) .directory else .file;
            if (value.kind != expected) return error.ProtocolViolation;
            return value;
        }
        /// Exclusive create of a new regular file; returns a write-only fd.
        /// Never opens, truncates or replaces an existing entry.
        pub fn create(dir: u64, name: []const u8) Error!u64 {
            return named(create_op, dir, name, 0);
        }
        /// Returns the new directory already pinned.
        pub fn makeDirectory(dir: u64, name: []const u8) Error!u64 {
            return pinToken(try named(mkdir_op, dir, name, 0));
        }
        /// One file or one empty directory of exactly `kind`; never recursive.
        pub fn remove(dir: u64, name: []const u8, kind: EntryKind) Error!void {
            if (try named(remove_op, dir, name, @backingInt(kind)) != 0) return error.ProtocolViolation;
        }
        /// One backend rename between two pins. No rollback or fallback after
        /// failure, whose outcome may be unknown.
        pub fn rename(from_dir: u64, from: []const u8, to_dir: u64, to: []const u8, mode: Publication) Error!void {
            try entryName(from);
            try entryName(to);
            const lengths: u64 = from.len | to.len << 16 | (if (mode == .replace) rename_replace else 0);
            if (try result(Driver.call(79, .{ rename_op, from_dir, @intFromPtr(from.ptr), to_dir, @intFromPtr(to.ptr), lengths })) != 0)
                return error.ProtocolViolation;
        }
        /// Path-based single-entry B4 publication, NOT contained mutation.
        /// No rollback or fallback after failure, whose outcome may be unknown.
        pub fn publish(from: []const u8, to: []const u8, mode: Publication) Error!void {
            var from_buf: [path_max]u8 = undefined;
            var to_buf: [path_max]u8 = undefined;
            const source = try fullPath(from, &from_buf);
            const destination = try fullPath(to, &to_buf);
            const flag: u64 = if (mode == .replace) @as(u64, 1) << 63 else 0;
            if (try result(Driver.call(35, .{ @intFromPtr(source.ptr), source.len | flag, @intFromPtr(destination.ptr), destination.len, 0, 0 })) != 0)
                return error.ProtocolViolation;
        }
    };
}
