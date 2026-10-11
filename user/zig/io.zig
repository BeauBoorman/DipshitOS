//! Synchronous native std.Io. No POSIX calls, implicit tty, or invented metadata.
const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const platform = @import("platform.zig");
const refusals = @import("refusals.zig");
const fs = @import("fs.zig");
const network = @import("network.zig");

pub fn Backend(comptime Driver: type) type {
    return struct {
        const Self = @This();
        const NativeFs = fs.Native(Driver);
        const Net = network.Native(Driver);
        const wide_paths = if (@hasDecl(Driver, "filesystem_b2")) Driver.filesystem_b2 else false;
        const path_bytes = if (wide_paths) fs.path_max else 64;
        const Record = struct {
            token: i64,
            fd: u64,
            writable: bool = false,
            kind: enum { file, snapshot, directory, listener, stream } = .file,
        };
        // Three reserved streams + borrowed cwd + FOUR files/cursors/pins combined.
        records: [4]?Record = @splat(null),
        next_token: i64 = 1,
        peak_files: usize = 0,
        cancel_protection: Io.CancelProtection = .unblocked,
        canceled: bool = false,
        debug_locked: bool = false,
        debug_writer: File.Writer = undefined,

        pub const vtable: Io.VTable = table: {
            @setEvalBranchQuota(100000);
            const names = @import("operations.zig").names;
            const fields = std.meta.fieldNames(Io.VTable);
            if (fields.len != names.len) @compileError("UnreviewedIoVTable");
            var table: Io.VTable = undefined;
            for (fields, names) |field_name, name| {
                if (!std.mem.eql(u8, field_name, name)) @compileError("UnreviewedIoVTable:" ++ field_name);
                @field(table, name) = if (@hasDecl(Self, name))
                    @field(Self, name)
                else
                    refusals.function(Driver, name, @FieldType(Io.VTable, name));
            }
            break :table table;
        };

        pub fn io(self: *Self) Io {
            return .{ .userdata = self, .vtable = &vtable };
        }
        pub fn state(ptr: ?*anyopaque) *Self {
            return @ptrCast(@alignCast(ptr orelse Driver.instance()));
        }
        pub fn reject(comptime name: []const u8, comptime R: type) R {
            return refusals.result(Driver, name, R);
        }
        pub fn fileRecord(self: *Self, file: File) ?*Record {
            for (&self.records) |*entry| {
                if (entry.*) |*record| {
                    if (record.token == file.handle and record.kind == .file) return record;
                }
            }
            return null;
        }
        pub fn liveFiles(self: *Self) usize {
            var count: usize = 0;
            for (self.records) |record| if (record != null) {
                count += 1;
            };
            return count;
        }
        pub fn liveResources(self: *Self) usize {
            return 4 + self.liveFiles();
        }
        pub fn reserve(self: *Self) fs.Error!*?Record {
            if (self.next_token == std.math.maxInt(i64)) return error.ResourceLimit;
            for (&self.records) |*entry| if (entry.* == null) return entry;
            return error.ResourceLimit;
        }
        pub fn track(self: *Self, entry: *?Record, fd: u64, kind: @FieldType(Record, "kind"), writable: bool) i64 {
            const token = self.next_token;
            self.next_token += 1;
            entry.* = .{ .token = token, .fd = fd, .kind = kind, .writable = writable };
            self.peak_files = @max(self.peak_files, self.liveFiles());
            return token;
        }
        /// Fresh no-follow PATH metadata. Never an fd-stat implementation.
        pub fn metadata(_: *Self, root: []const u8, relative: []const u8) fs.Error!fs.Metadata {
            return NativeFs.metadata(root, relative);
        }
        pub fn identity(_: *Self, root: []const u8, relative: []const u8) fs.Error!fs.Identity {
            return NativeFs.identity(root, relative);
        }
        pub fn openContained(self: *Self, root: []const u8, relative: []const u8, mode: fs.OpenMode) fs.Error!File {
            const entry = try self.reserve();
            const fd = try NativeFs.pathCall(if (mode == .read) 2 else 3, root, relative, 0);
            if (fd >= 8) Driver.fatal("InvalidNativeHandle");
            const token = self.track(entry, fd, .file, mode == .write);
            return .{ .handle = @intCast(token), .flags = .{ .nonblocking = false } };
        }
        pub fn openSnapshot(self: *Self, root: []const u8, relative: []const u8) fs.Error!fs.Snapshot {
            const entry = try self.reserve();
            const cursor = try NativeFs.pathCall(4, root, relative, 0);
            if (cursor == 0) return error.ProtocolViolation;
            return .{ .token = self.track(entry, cursor, .snapshot, false) };
        }
        pub fn snapshotRecord(self: *Self, snapshot: fs.Snapshot) fs.Error!*?Record {
            for (&self.records) |*entry| if (entry.*) |record| {
                if (record.token == snapshot.token and record.kind == .snapshot) return entry;
            };
            return error.InvalidHandle;
        }
        pub fn snapshotPage(self: *Self, snapshot: fs.Snapshot, offset: u64, limit: usize, output: *fs.Page) fs.Error!void {
            const entry = try self.snapshotRecord(snapshot);
            try NativeFs.page(entry.*.?.fd, offset, limit, output);
        }
        pub fn closeSnapshot(self: *Self, snapshot: fs.Snapshot) fs.Error!void {
            const entry = try self.snapshotRecord(snapshot);
            try NativeFs.close(entry.*.?.fd);
            entry.* = null;
        }
        /// Live attributes of a contained or exclusively created file's own
        /// object. Legacy path fds refuse `Unsupported`; no pathname is
        /// retained to emulate them.
        pub fn fileMetadata(self: *Self, file: File) fs.Error!fs.Metadata {
            const record = self.fileRecord(file) orelse return error.InvalidHandle;
            return NativeFs.handleMetadata(record.fd, fs.handle_file);
        }
        pub fn directoryRecord(self: *Self, dir: fs.Directory) fs.Error!*?Record {
            for (&self.records) |*entry| if (entry.*) |record| {
                if (record.token == dir.token and record.kind == .directory) return entry;
            };
            return error.InvalidHandle;
        }
        pub fn pin(self: *Self, dir: fs.Directory) fs.Error!u64 {
            return (try self.directoryRecord(dir)).*.?.fd;
        }
        /// B5: pins an existing directory. Name operations below act on the
        /// pinned object, never on a re-resolved pathname.
        pub fn openDirectory(self: *Self, root: []const u8, relative: []const u8) fs.Error!fs.Directory {
            const entry = try self.reserve();
            const native = try NativeFs.openDirectory(root, relative);
            return .{ .token = self.track(entry, native, .directory, false) };
        }
        pub fn openChildDirectory(self: *Self, dir: fs.Directory, name: []const u8) fs.Error!fs.Directory {
            const parent = try self.pin(dir);
            const entry = try self.reserve();
            const native = try NativeFs.childDirectory(parent, name);
            return .{ .token = self.track(entry, native, .directory, false) };
        }
        /// Also succeeds for a stale or revoked pin. A failure keeps the record.
        pub fn closeDirectory(self: *Self, dir: fs.Directory) fs.Error!void {
            const entry = try self.directoryRecord(dir);
            try NativeFs.closeDirectory(entry.*.?.fd);
            entry.* = null;
        }
        pub fn directoryMetadata(self: *Self, dir: fs.Directory) fs.Error!fs.Metadata {
            return NativeFs.handleMetadata(try self.pin(dir), fs.handle_directory);
        }
        /// A new write-only regular file below the pin; `PathAlreadyExists`
        /// when the name is occupied. Never opens or truncates an existing one.
        pub fn createExclusive(self: *Self, dir: fs.Directory, name: []const u8) fs.Error!File {
            const parent = try self.pin(dir);
            const entry = try self.reserve();
            const fd = try NativeFs.create(parent, name);
            if (fd >= 8) Driver.fatal("InvalidNativeHandle");
            const token = self.track(entry, fd, .file, true);
            return .{ .handle = @intCast(token), .flags = .{ .nonblocking = false } };
        }
        /// Returns the new directory already pinned.
        pub fn makeDirectory(self: *Self, dir: fs.Directory, name: []const u8) fs.Error!fs.Directory {
            const parent = try self.pin(dir);
            const entry = try self.reserve();
            const native = try NativeFs.makeDirectory(parent, name);
            return .{ .token = self.track(entry, native, .directory, false) };
        }
        pub fn removeFile(self: *Self, dir: fs.Directory, name: []const u8) fs.Error!void {
            try NativeFs.remove(try self.pin(dir), name, .file);
        }
        /// Empty directories only; never recursive.
        pub fn removeDirectory(self: *Self, dir: fs.Directory, name: []const u8) fs.Error!void {
            try NativeFs.remove(try self.pin(dir), name, .directory);
        }
        /// One native rename between two pins. A guest rename stales pins at
        /// or under either name; reopen them from a live parent.
        pub fn rename(self: *Self, from_dir: fs.Directory, from: []const u8, to_dir: fs.Directory, to: []const u8, mode: fs.Publication) fs.Error!void {
            try NativeFs.rename(try self.pin(from_dir), from, try self.pin(to_dir), to, mode);
        }
        pub fn publish(_: *Self, from: []const u8, to: []const u8, mode: fs.Publication) fs.Error!void {
            try NativeFs.publish(from, to, mode);
        }
        pub fn openError(err: fs.Error) File.OpenError {
            return switch (err) {
                error.ResourceLimit, error.OutOfMemory => error.SystemResources,
                error.FileNotFound => error.FileNotFound,
                error.AccessDenied => error.AccessDenied,
                error.NameTooLong => error.NameTooLong,
                error.PathAlreadyExists => error.PathAlreadyExists,
                else => rejected: {
                    Driver.diagnostic("Filesystem:");
                    Driver.diagnostic(@errorName(err));
                    Driver.diagnostic("\n");
                    break :rejected error.Unexpected;
                },
            };
        }
        /// Preserve the pre-B2 helper used by bounded workload preflights.
        /// Native Io and fs operations use the wider B2 contract separately.
        pub fn path(dir: Dir, name: []const u8, buffer: *[64]u8) File.OpenError![]const u8 {
            if (dir.handle != platform.cwd_token) return reject("DirectoryToken", File.OpenError![]const u8);
            if (name.len == 0 or std.mem.indexOfAny(u8, name, "\x00\\:") != null)
                return error.BadPathName;
            const absolute = name[0] == '/';
            if (absolute and !std.mem.startsWith(u8, name, "/host/")) return error.AccessDenied;
            const relative = if (absolute) name[6..] else name;
            var parts = std.mem.splitScalar(u8, relative, '/');
            while (parts.next()) |part| {
                if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
                    return error.BadPathName;
                if (part.len > 31) return error.NameTooLong;
            }
            if (relative.len > 58) return error.NameTooLong;
            @memcpy(buffer[0..6], "/host/");
            @memcpy(buffer[6..][0..relative.len], relative);
            return buffer[0 .. 6 + relative.len];
        }
        /// Cwd is lexical SDK state, not proof of no-follow containment.
        pub fn nativePath(dir: Dir, name: []const u8, buffer: []u8) File.OpenError![]const u8 {
            if (dir.handle != platform.cwd_token) return reject("DirectoryToken", File.OpenError![]const u8);
            return fs.fullPath(name, buffer) catch |err| return switch (err) {
                error.InvalidArgument => error.BadPathName,
                else => openError(err),
            };
        }
        pub fn open(self: *Self, dir: Dir, name: []const u8, flags: u32) File.OpenError!File {
            var buffer: [path_bytes]u8 = undefined;
            const full = try if (wide_paths) nativePath(dir, name, &buffer) else path(dir, name, &buffer);
            const entry = self.reserve() catch return error.ProcessFdQuotaExceeded;
            const result = Driver.call(23, .{ @intFromPtr(full.ptr), full.len, flags, 0, 0, 0 });
            const fd = fs.result(result) catch |err| return openError(err);
            if (result >= 8) Driver.fatal("InvalidNativeHandle");
            const token = self.track(entry, fd, .file, flags & 2 != 0);
            return .{ .handle = @intCast(token), .flags = .{ .nonblocking = false } };
        }
        pub fn dirOpenFile(ptr: ?*anyopaque, dir: Dir, name: []const u8, options: Dir.OpenFileOptions) File.OpenError!File {
            if (options.mode == .read_write or options.path_only or options.lock != .none or
                options.lock_nonblocking or options.allow_ctty)
                return reject("OpenOptions", File.OpenError!File);
            if (!options.follow_symlinks or options.resolve_beneath) {
                var buffer: [path_bytes]u8 = undefined;
                const full = try if (wide_paths) nativePath(dir, name, &buffer) else path(dir, name, &buffer);
                return state(ptr).openContained("/host", full[6..], if (options.mode == .read_only) .read else .write) catch |err| return openError(err);
            }
            if (options.mode != .read_only) return reject("OpenOptions", File.OpenError!File);
            return state(ptr).open(dir, name, 1);
        }
        pub fn dirCreateFile(ptr: ?*anyopaque, dir: Dir, name: []const u8, options: Dir.CreateFileOptions) File.OpenError!File {
            if (options.read or !options.truncate or options.exclusive or options.lock != .none or
                options.lock_nonblocking or options.resolve_beneath or options.permissions != .default_file)
                return reject("CreateOptions", File.OpenError!File);
            return state(ptr).open(dir, name, 2 | 4);
        }
        pub fn dirCreateDir(ptr: ?*anyopaque, dir: Dir, name: []const u8, permissions: Dir.Permissions) Dir.CreateDirError!void {
            if (permissions != .default_dir) return reject("DirectoryPermissions", Dir.CreateDirError!void);
            const self = state(ptr);
            const file = self.open(dir, name, 2 | 4 | 16) catch |err| return switch (err) {
                error.AccessDenied => error.AccessDenied,
                error.NameTooLong => error.NameTooLong,
                error.BadPathName => error.BadPathName,
                error.FileNotFound => error.FileNotFound,
                error.PathAlreadyExists => error.PathAlreadyExists,
                else => error.Unexpected,
            };
            self.closeChecked(file) catch Driver.fatal("CloseFailed");
        }
        /// Fallible SDK close for callers that need to propagate failure.
        /// std's void close must terminate on failure, never imply success.
        pub fn closeChecked(self: *Self, file: File) error{CloseFailed}!void {
            for (&self.records) |*entry| {
                if (entry.*) |record| {
                    if (record.token != file.handle or record.kind != .file) continue;
                    if (Driver.call(26, .{ record.fd, 0, 0, 0, 0, 0 }) != 0) return error.CloseFailed;
                    entry.* = null;
                    return;
                }
            }
            return error.CloseFailed;
        }
        pub fn closeAll(self: *Self) error{CloseFailed}!void {
            // Children first: closing the listener revokes their native handles.
            for (&self.records) |*entry| if (entry.*) |record| {
                if (record.kind == .stream) {
                    Net.close(record.fd) catch return error.CloseFailed;
                    entry.* = null;
                }
            };
            for (self.records) |entry| if (entry) |record| switch (record.kind) {
                .snapshot => self.closeSnapshot(.{ .token = record.token }) catch return error.CloseFailed,
                .directory => self.closeDirectory(.{ .token = record.token }) catch return error.CloseFailed,
                .file => try self.closeChecked(.{ .handle = @intCast(record.token), .flags = .{ .nonblocking = false } }),
                .listener, .stream => {
                    Net.close(record.fd) catch return error.CloseFailed;
                    for (&self.records) |*r| if (r.*) |value| {
                        if (value.token == record.token) r.* = null;
                    };
                },
            };
        }
        /// A full std `File.Stat` would need invented fields; use fileMetadata.
        pub fn fileStat(_: ?*anyopaque, _: File) File.StatError!File.Stat {
            return reject("FdMetadataUnavailable", File.StatError!File.Stat);
        }
        pub fn fileLength(ptr: ?*anyopaque, file: File) File.LengthError!u64 {
            const value = state(ptr).fileMetadata(file) catch |err| return switch (err) {
                error.InvalidHandle => reject("UnboundOrClosedFile", File.LengthError!u64),
                error.Unsupported => reject("FdMetadataUnavailable", File.LengthError!u64),
                error.AccessDenied => error.AccessDenied,
                error.ResourceLimit, error.OutOfMemory => error.SystemResources,
                else => refused: {
                    Driver.diagnostic("Filesystem:");
                    Driver.diagnostic(@errorName(err));
                    Driver.diagnostic("\n");
                    break :refused error.Unexpected;
                },
            };
            return value.size;
        }
        pub fn renameError(err: fs.Error) Dir.RenamePreserveError {
            return switch (err) {
                error.InvalidArgument => refused: {
                    Driver.diagnostic("Filesystem:InvalidArgument\n");
                    break :refused error.Unexpected;
                },
                error.Unsupported => error.OperationUnsupported,
                error.AccessDenied => error.AccessDenied,
                error.FileNotFound => error.FileNotFound,
                error.NameTooLong => error.NameTooLong,
                error.PathAlreadyExists => error.PathAlreadyExists,
                error.ResourceLimit, error.OutOfMemory => error.SystemResources,
                else => refused: {
                    Driver.diagnostic("Filesystem:");
                    Driver.diagnostic(@errorName(err));
                    Driver.diagnostic("\n");
                    break :refused error.Unexpected;
                },
            };
        }
        pub fn checkRenamePaths(from_dir: Dir, from: []const u8, to_dir: Dir, to: []const u8) Dir.RenameError!void {
            if (from_dir.handle != platform.cwd_token or to_dir.handle != platform.cwd_token)
                return reject("DirectoryToken", Dir.RenameError!void);
            if (!wide_paths) {
                var buffer: [64]u8 = undefined;
                for ([_][]const u8{ from, to }) |name| {
                    _ = path(from_dir, name, &buffer) catch |err| return switch (err) {
                        error.AccessDenied => error.AccessDenied,
                        error.NameTooLong => error.NameTooLong,
                        error.BadPathName => error.BadPathName,
                        else => error.Unexpected,
                    };
                }
            }
        }
        pub fn dirRenamePreserve(ptr: ?*anyopaque, from_dir: Dir, from: []const u8, to_dir: Dir, to: []const u8) Dir.RenamePreserveError!void {
            try checkRenamePaths(from_dir, from, to_dir, to);
            state(ptr).publish(from, to, .preserve_existing) catch |err| return renameError(err);
        }
        pub fn dirRename(ptr: ?*anyopaque, from_dir: Dir, from: []const u8, to_dir: Dir, to: []const u8) Dir.RenameError!void {
            try checkRenamePaths(from_dir, from, to_dir, to);
            state(ptr).publish(from, to, .replace) catch |err| return switch (renameError(err)) {
                error.OperationUnsupported, error.PathAlreadyExists => reject("RenameUnavailable", Dir.RenameError!void),
                else => |mapped| mapped,
            };
        }
        pub fn fileClose(ptr: ?*anyopaque, files: []const File) void {
            for (files) |file| state(ptr).closeChecked(file) catch Driver.fatal("CloseFailed");
        }
        pub fn fileSync(ptr: ?*anyopaque, file: File) File.SyncError!void {
            const record = state(ptr).fileRecord(file) orelse return reject("UnboundOrClosedFile", File.SyncError!void);
            const result = Driver.call(77, .{ record.fd, 0, 0, 0, 0, 0 });
            if (result != 0) return switch (result) {
                -7 => error.AccessDenied,
                -5 => error.NoSpaceLeft,
                else => error.InputOutput,
            };
        }
        pub fn fileSetLength(ptr: ?*anyopaque, file: File, length: u64) File.SetLengthError!void {
            if (length > std.math.maxInt(u32)) return error.FileTooBig;
            const record = state(ptr).fileRecord(file) orelse return reject("UnboundOrClosedFile", File.SetLengthError!void);
            if (!record.writable) return error.AccessDenied;
            if (Driver.call(36, .{ record.fd, length, 0, 0, 0, 0 }) != 0) return error.Unexpected;
        }
        pub fn read(self: *Self, op: Io.Operation.FileReadStreaming) Io.Operation.FileReadStreaming.Result {
            const record = self.fileRecord(op.file) orelse return reject("UnboundOrClosedInput", Io.Operation.FileReadStreaming.Result);
            if (record.writable) return error.NotOpenForReading;
            for (op.data) |buffer| {
                if (buffer.len == 0) continue;
                const chunk = buffer[0..@min(buffer.len, 2048)];
                const n = Driver.call(24, .{ record.fd, @intFromPtr(chunk.ptr), chunk.len, 0, 0, 0 });
                if (n < 0) return if (n == -7) error.AccessDenied else error.InputOutput;
                if (n > chunk.len) return error.InputOutput;
                if (n == 0) return error.EndOfStream;
                return @intCast(n);
            }
            return 0; // A supported, valid handle and an empty request.
        }
        pub fn writeChunk(self: *Self, file: File, bytes: []const u8) Io.Operation.FileWriteStreaming.Result {
            if (file.handle == platform.diagnostic_token) {
                Driver.diagnostic(bytes);
                return bytes.len;
            }
            const record = self.fileRecord(file) orelse return reject("UnboundOrClosedOutput", Io.Operation.FileWriteStreaming.Result);
            if (!record.writable) return error.NotOpenForWriting;
            if (bytes.len == 0) return 0;
            const chunk = bytes[0..@min(bytes.len, 2048)];
            const n = Driver.call(25, .{ record.fd, @intFromPtr(chunk.ptr), chunk.len, 0, 0, 0 });
            if (n <= 0 or n > chunk.len) return switch (n) {
                -5 => error.NoSpaceLeft,
                -7 => error.AccessDenied,
                else => error.InputOutput,
            };
            return @intCast(n);
        }
        pub fn write(self: *Self, op: Io.Operation.FileWriteStreaming) Io.Operation.FileWriteStreaming.Result {
            // Validate even an empty request; an unbound stream is not a sink.
            if (op.file.handle != platform.diagnostic_token) {
                const record = self.fileRecord(op.file) orelse
                    return reject("UnboundOrClosedOutput", Io.Operation.FileWriteStreaming.Result);
                if (!record.writable) return error.NotOpenForWriting;
            }
            if (op.header.len != 0) return self.writeChunk(op.file, op.header);
            for (op.data, 0..) |bytes, i| {
                if (i + 1 == op.data.len and op.splat == 0) break;
                if (bytes.len != 0) return self.writeChunk(op.file, bytes);
            }
            return 0;
        }
        pub fn operate(ptr: ?*anyopaque, op: Io.Operation) Io.Cancelable!Io.Operation.Result {
            try checkCancel(ptr);
            return switch (op) {
                .file_read_streaming => |request| .{ .file_read_streaming = state(ptr).read(request) },
                .file_write_streaming => |request| .{ .file_write_streaming = state(ptr).write(request) },
                .net_receive => refused: {
                    Driver.diagnostic("Unsupported:net_receive\n");
                    break :refused .{ .net_receive = .{ error.Unexpected, 0 } };
                },
                .net_send => refused: {
                    Driver.diagnostic("Unsupported:net_send\n");
                    break :refused .{ .net_send = .{ error.Unexpected, 0 } };
                },
                .net_read => |request| .{
                    .net_read = socketRead(ptr, request) catch |err| switch (err) {
                        error.Canceled => return error.Canceled,
                        else => |e| e,
                    },
                },
                .net_write => |request| .{
                    .net_write = socketWrite(ptr, request) catch |err| switch (err) {
                        error.Canceled => return error.Canceled,
                        else => |e| e,
                    },
                },
                .device_io_control => Driver.fatal("Unsupported:device_io_control"),
            };
        }
        pub fn socketRecord(self: *Self, handle: Io.net.Socket.Handle) ?*Record {
            for (&self.records) |*entry| if (entry.*) |*r| {
                if (r.token == handle and (r.kind == .listener or r.kind == .stream)) return r;
            };
            return null;
        }
        pub fn netListenIp(ptr: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ListenOptions) Io.net.IpAddress.ListenError!Io.net.Socket {
            try checkCancel(ptr);
            if (address.* != .ip4) return error.AddressFamilyUnsupported;
            if (options.mode != .stream) return error.SocketModeUnsupported;
            if (options.protocol != .tcp) return error.ProtocolUnsupportedBySystem;
            if (options.reuse_address or options.kernel_backlog > 2 or options.kernel_backlog == 0) return error.OptionUnsupported;
            const self = state(ptr);
            const entry = self.reserve() catch return error.ProcessFdQuotaExceeded;
            const h = Net.call(0, network.word(address.ip4.bytes), address.ip4.port, 0) catch |err| return switch (err) {
                error.Capacity => error.SystemResources,
                error.NetworkDown => error.NetworkDown,
                error.InvalidArgument => error.AddressUnavailable,
                else => error.Unexpected,
            };
            return .{ .handle = @intCast(self.track(entry, h, .listener, false)), .address = address.* };
        }
        pub fn netAccept(ptr: ?*anyopaque, handle: Io.net.Socket.Handle, _: Io.net.Server.AcceptOptions) Io.net.Server.AcceptError!Io.net.Socket {
            const self = state(ptr);
            const listener = self.socketRecord(handle) orelse return error.SocketNotListening;
            if (listener.kind != .listener) return error.SocketNotListening;
            const fd = listener.fd;
            const entry = self.reserve() catch return error.ProcessFdQuotaExceeded;
            const deadline = Net.now() +| network.budget_ns;
            while (true) {
                try checkCancel(ptr);
                const child = Net.call(1, fd, 0, 0) catch |err| switch (err) {
                    error.WouldBlock => {
                        _ = Net.wait(fd, 4, deadline) catch |failure| return switch (failure) {
                            error.TimedOut => error.WouldBlock,
                            else => error.SocketNotListening,
                        };
                        continue;
                    },
                    else => return error.SocketNotListening,
                };
                const peer = Net.call(7, child, 0, 0) catch {
                    Net.close(child) catch Driver.fatal("SocketCloseFailed");
                    return error.ConnectionAborted;
                };
                return .{ .handle = @intCast(self.track(entry, child, .stream, true)), .address = .{ .ip4 = .{
                    .bytes = .{ @truncate(peer >> 40), @truncate(peer >> 32), @truncate(peer >> 24), @truncate(peer >> 16) },
                    .port = @truncate(peer),
                } } };
            }
        }
        pub fn socketRead(ptr: ?*anyopaque, request: Io.Operation.NetRead) Io.net.Stream.Reader.Error!Io.net.Stream.ReadResult {
            if (request.control.len != 0) {
                Driver.diagnostic("Unsupported:net_read:control\n");
                return error.Unexpected;
            }
            const r = state(ptr).socketRecord(request.socket_handle) orelse return error.SocketUnconnected;
            if (r.kind != .stream) return error.SocketUnconnected;
            const deadline = Net.now() +| network.budget_ns;
            for (request.data) |bytes| {
                if (bytes.len == 0) continue;
                while (true) {
                    try checkCancel(ptr);
                    return .{ .data_len = Net.read(r.fd, bytes) catch |err| switch (err) {
                        error.WouldBlock => {
                            _ = Net.wait(r.fd, 1, deadline) catch |failure| return readError(failure);
                            continue;
                        },
                        else => return readError(err),
                    } };
                }
            }
            return .{ .data_len = 0 };
        }
        pub fn readError(err: network.Error) Io.net.Stream.Reader.Error {
            return switch (err) {
                error.PeerReset => error.ConnectionResetByPeer,
                error.TimedOut => error.ConnectionTimedOut,
                error.AccessDenied => error.AccessDenied,
                error.Closed, error.InvalidHandle => error.SocketUnconnected,
                error.NetworkDown => error.NetworkDown,
                else => named: {
                    Driver.diagnostic("Network:Read:");
                    Driver.diagnostic(@errorName(err));
                    Driver.diagnostic("\n");
                    break :named error.Unexpected;
                },
            };
        }
        pub fn socketWrite(ptr: ?*anyopaque, request: Io.Operation.NetWrite) Io.net.Stream.Writer.Error!usize {
            if (request.control.len != 0) {
                Driver.diagnostic("Unsupported:net_write:control\n");
                return error.Unexpected;
            }
            const r = state(ptr).socketRecord(request.socket_handle) orelse return error.SocketUnconnected;
            if (r.kind != .stream) return error.SocketUnconnected;
            const deadline = Net.now() +| network.budget_ns;
            const bytes = if (request.header.len != 0) request.header else select: {
                for (request.data, 0..) |part, i| {
                    if (i + 1 == request.data.len and request.splat == 0) break;
                    if (part.len != 0) break :select part;
                }
                return 0;
            };
            while (true) {
                try checkCancel(ptr);
                return Net.send(r.fd, bytes) catch |err| switch (err) {
                    error.WouldBlock => {
                        _ = Net.wait(r.fd, 2 | 8, deadline) catch return error.Unexpected;
                        continue;
                    },
                    error.PeerReset => error.ConnectionResetByPeer,
                    error.Closed, error.InvalidHandle => error.SocketUnconnected,
                    error.NetworkDown => error.NetworkDown,
                    error.TimedOut => error.ConnectionTimedOut,
                    else => error.Unexpected,
                };
            }
        }
        pub fn netClose(ptr: ?*anyopaque, sockets: []const Io.net.Socket) void {
            const self = state(ptr);
            for (sockets) |socket| {
                const handle = socket.handle;
                const record = self.socketRecord(handle) orelse Driver.fatal("Unsupported:netClose:InvalidSocket");
                const fd = record.fd;
                const listener = record.kind == .listener;
                Net.close(fd) catch Driver.fatal("SocketCloseFailed");
                for (&self.records) |*entry| if (entry.*) |r| {
                    // Closing a listener revokes all of this backend's children.
                    if (r.token == handle or (listener and r.kind == .stream)) entry.* = null;
                };
            }
        }
        pub fn netLookup(ptr: ?*anyopaque, name: Io.net.HostName, queue: *Io.Queue(Io.net.HostName.LookupResult), options: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
            const self = state(ptr);
            const io_value = self.io();
            defer queue.close(io_value);
            try checkCancel(ptr);
            if (options.family == .ip6) return error.AddressFamilyUnsupported;
            const entry = self.reserve() catch return error.ProcessFdQuotaExceeded;
            // Reserve one of the SAME four slots for the transaction's lifetime.
            entry.* = .{ .token = 0, .fd = 0 };
            defer entry.* = null;
            const ip = Net.resolve(name.bytes, network.default_dns) catch |err| return switch (err) {
                error.NameNotFound => error.UnknownHostName,
                error.NetworkDown => error.NetworkDown,
                error.Capacity => error.SystemResources,
                else => refused: {
                    Driver.diagnostic("DNS:");
                    Driver.diagnostic(@errorName(err));
                    Driver.diagnostic("\n");
                    break :refused error.NameServerFailure;
                },
            };
            queue.putOne(io_value, .{ .address = .{ .ip4 = .{ .bytes = ip, .port = options.port } } }) catch |err| return switch (err) {
                error.Canceled => error.Canceled,
                error.Closed => error.Unexpected,
            };
            if (options.canonical_name_buffer) |buffer| {
                @memcpy(buffer[0..name.bytes.len], name.bytes);
                queue.putOne(io_value, .{ .canonical_name = .{ .bytes = buffer[0..name.bytes.len] } }) catch return error.Unexpected;
            }
        }
        pub fn fileReadPositional(_: ?*anyopaque, _: File, _: []const []u8, _: u64) File.ReadPositionalError!usize {
            return error.Unseekable;
        }
        pub fn fileWritePositional(_: ?*anyopaque, _: File, _: []const u8, _: []const []const u8, _: usize, _: u64) File.WritePositionalError!usize {
            return error.Unseekable;
        }
        pub fn fileSeekTo(_: ?*anyopaque, _: File, _: u64) File.SeekError!void {
            return error.Unseekable;
        }
        pub fn fileSeekBy(_: ?*anyopaque, _: File, _: i64) File.SeekError!void {
            return error.Unseekable;
        }
        pub fn processCurrentPath(_: ?*anyopaque, buffer: []u8) std.process.CurrentPathError!usize {
            if (buffer.len < 5) return error.NameTooLong;
            @memcpy(buffer[0..5], "/host");
            return 5;
        }
        pub fn randomSecure(_: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
            var at: usize = 0;
            while (at < buffer.len) {
                const chunk = buffer[at..][0..@min(256, buffer.len - at)];
                const n = Driver.call(72, .{ @intFromPtr(chunk.ptr), chunk.len, 0, 0, 0, 0 });
                if (n <= 0 or n > chunk.len) return error.EntropyUnavailable;
                at += @intCast(n);
            }
        }
        pub fn random(ptr: ?*anyopaque, buffer: []u8) void {
            randomSecure(ptr, buffer) catch Driver.fatal("EntropyUnavailable");
        }
        pub fn async(_: ?*anyopaque, result: []u8, _: std.mem.Alignment, context: []const u8, _: std.mem.Alignment, start: *const fn (*const anyopaque, *anyopaque) void) ?*Io.AnyFuture {
            start(context.ptr, result.ptr);
            return null; // The result has actually been populated synchronously.
        }
        pub fn concurrent(_: ?*anyopaque, _: usize, _: std.mem.Alignment, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque, *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
            return error.ConcurrencyUnavailable;
        }
        pub fn groupAsync(_: ?*anyopaque, _: *Io.Group, context: []const u8, _: std.mem.Alignment, start: *const fn (*const anyopaque) void) void {
            start(context.ptr);
        }
        pub fn groupConcurrent(_: ?*anyopaque, _: *Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) void) Io.ConcurrentError!void {
            return error.ConcurrencyUnavailable;
        }
        pub fn batchAwaitConcurrent(_: ?*anyopaque, _: *Io.Batch, _: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
            return error.ConcurrencyUnavailable;
        }
        pub fn recancel(ptr: ?*anyopaque) void {
            state(ptr).canceled = true;
        }
        pub fn swapCancelProtection(ptr: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
            const self = state(ptr);
            const old = self.cancel_protection;
            self.cancel_protection = new;
            return old;
        }
        pub fn checkCancel(ptr: ?*anyopaque) Io.Cancelable!void {
            const self = state(ptr);
            if (self.cancel_protection == .unblocked and self.canceled) {
                self.canceled = false;
                return error.Canceled;
            }
        }
        pub fn lockStderr(ptr: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
            const self = state(ptr);
            if (self.debug_locked) Driver.fatal("Unsupported:ReentrantDebugLock");
            if (mode != null and mode.? != .no_color) Driver.fatal("Unsupported:DebugTerminalMode");
            self.debug_locked = true;
            self.debug_writer = .initStreaming(.{
                .handle = platform.diagnostic_token,
                .flags = .{ .nonblocking = false },
            }, self.io(), &.{});
            return .{ .file_writer = &self.debug_writer, .terminal_mode = .no_color };
        }
        pub fn tryLockStderr(ptr: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
            if (state(ptr).debug_locked) return null;
            return try lockStderr(ptr, mode);
        }
        pub fn unlockStderr(ptr: ?*anyopaque) void {
            const self = state(ptr);
            if (!self.debug_locked) Driver.fatal("InvalidDebugUnlock");
            self.debug_writer.interface.flush() catch Driver.fatal("DebugFlushFailed");
            if (self.debug_writer.err != null) Driver.fatal("DebugWriteFailed");
            self.debug_writer.interface.buffer = &.{};
            self.debug_locked = false;
        }
    };
}

test "native Io: short writes, splats, empty header, sequential EOF, bounded read" {
    Mock.reset();
    var backend: TestBackend = .{};
    const io = backend.io();
    const file = try platform.cwd().createFile(io, "output", .{});
    Mock.maximum = 17;
    var buffer: [29]u8 = undefined;
    var writer = file.writer(io, &buffer); // default positional path falls back honestly
    try writer.interface.writeAll(&@as([5000:0]u8, @splat("x"[0])));
    try writer.interface.flush();
    try file.writeStreamingAll(io, "end");
    try std.testing.expectEqual(@as(usize, 5003), Mock.output_len);
    try std.testing.expectEqualStrings(&@as([5000:0]u8, @splat("x"[0])) ++ "end", Mock.output[0..Mock.output_len]);
    var vectors = [_][]const u8{ "", "ab", "z" };
    try writer.interface.writeSplatAll(&vectors, 3);
    try writer.interface.flush();
    try std.testing.expectEqualStrings("abzzz", Mock.output[5003..Mock.output_len]);
    var no_last = [_][]const u8{ "prefix", "absent" };
    try writer.interface.writeSplatAll(&no_last, 0);
    try writer.interface.flush();
    try std.testing.expectEqualStrings("prefix", Mock.output[5008..Mock.output_len]);
    try file.sync(io);
    file.close(io);
    const input = try platform.cwd().openFile(io, "input", .{});
    const empty_write = try io.operate(.{ .file_write_streaming = .{ .file = input, .data = &.{} } });
    try std.testing.expectError(error.NotOpenForWriting, empty_write.file_write_streaming);
    Mock.input = &@as([5000:0]u8, @splat("a"[0]));
    const out = try std.testing.allocator.alloc(u8, 5000);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(Mock.input, try readBounded(input, io, out));
    input.close(io);
    const over = try platform.cwd().openFile(io, "input", .{});
    Mock.input = &@as([5001:0]u8, @splat("a"[0]));
    Mock.input_at = 0;
    try std.testing.expectError(error.InputLimit, readBounded(over, io, out));
    over.close(io);
    try std.testing.expectEqual(@as(usize, 0), backend.liveFiles());
}

test "native Io: zero progress, overcount and native read write sync close failures" {
    Mock.reset();
    var backend: TestBackend = .{};
    const io = backend.io();
    const output = try platform.cwd().createFile(io, "output", .{});
    for ([_]i64{ 0, -1, 2049 }) |n| {
        Mock.forced = n;
        try std.testing.expectError(error.InputOutput, output.writeStreamingAll(io, "hello"));
    }
    Mock.forced = -7;
    try std.testing.expectError(error.AccessDenied, output.writeStreamingAll(io, "hello"));
    Mock.forced = -5;
    try std.testing.expectError(error.NoSpaceLeft, output.writeStreamingAll(io, "hello"));
    try std.testing.expectError(error.NoSpaceLeft, output.sync(io));
    try std.testing.expectError(error.CloseFailed, backend.closeChecked(output));
    try std.testing.expectEqual(@as(usize, 1), backend.liveFiles());
    Mock.forced = null;
    try backend.closeChecked(output);
    const input = try platform.cwd().openFile(io, "input", .{});
    var byte: [1]u8 = undefined;
    for ([_]i64{ -1, 2 }) |n| {
        Mock.forced = n;
        try std.testing.expectError(error.InputOutput, readBounded(input, io, &byte));
    }
    Mock.forced = null;
    try backend.closeChecked(input);
}

test "native Io: unbound streams and stale tokens never alias native fd zero" {
    Mock.reset();
    var backend: TestBackend = .{};
    const io = backend.io();
    const file = try platform.cwd().createFile(io, "output", .{});
    file.close(io);
    const next = try platform.cwd().createFile(io, "next", .{});
    try std.testing.expect(file.handle != next.handle);
    const before = Mock.calls;
    const standard = [_]File{
        .{ .handle = -1, .flags = .{ .nonblocking = false } },
        .{ .handle = -2, .flags = .{ .nonblocking = false } },
        .{ .handle = -3, .flags = .{ .nonblocking = false } },
        file,
    };
    for (standard) |stream| {
        try std.testing.expectError(error.Unexpected, stream.writeStreamingAll(io, "x"));
        var byte: [1]u8 = undefined;
        try std.testing.expectError(error.Unexpected, readBounded(stream, io, &byte));
        try std.testing.expectError(error.CloseFailed, backend.closeChecked(stream));
    }
    try std.testing.expectEqual(before, Mock.calls);
    next.close(io);
}

test "native Io: unsupported open options refuse before touching a path" {
    Mock.reset();
    var backend: TestBackend = .{};
    const io = backend.io();
    for ([_]Dir.OpenFileOptions{
        .{ .mode = .write_only }, .{ .mode = .read_write }, .{ .path_only = true },
        .{ .lock = .exclusive },  .{ .allow_ctty = true },  .{ .lock_nonblocking = true },
    }) |options| try std.testing.expectError(error.Unexpected, platform.cwd().openFile(io, "unchanged", options));
    for ([_]Dir.CreateFileOptions{
        .{ .read = true },            .{ .truncate = false }, .{ .exclusive = true },
        .{ .resolve_beneath = true }, .{ .lock = .shared },   .{ .lock_nonblocking = true },
    }) |options| try std.testing.expectError(error.Unexpected, platform.cwd().createFile(io, "unchanged", options));
    try std.testing.expectEqual(@as(usize, 0), Mock.calls);
}

test "native Io: path component and full limits reject escapes without clipping" {
    var path_buffer: [64]u8 = undefined;
    const cwd = platform.cwd();
    try std.testing.expectEqualStrings("/host/a/b", try TestBackend.path(cwd, "a/b", &path_buffer));
    try std.testing.expectEqual(@as(usize, 64), (try TestBackend.path(cwd, &@as([31:0]u8, @splat("x"[0])) ++ "/" ++ &@as([26:0]u8, @splat("y"[0])), &path_buffer)).len);
    try std.testing.expectError(error.NameTooLong, TestBackend.path(cwd, &@as([31:0]u8, @splat("x"[0])) ++ "/" ++ &@as([27:0]u8, @splat("y"[0])), &path_buffer));
    try std.testing.expectError(error.NameTooLong, TestBackend.path(cwd, &@as([32:0]u8, @splat("x"[0])), &path_buffer));
    for ([_][]const u8{ "", "a/../b", "./a", "a//b", "a/", "a\x00b", "host:x", "a\\b" }) |name|
        try std.testing.expectError(error.BadPathName, TestBackend.path(cwd, name, &path_buffer));
    for ([_][]const u8{ "/usb/x", "/dev/tty", "/hostile/x", "//host/x" }) |name|
        try std.testing.expectError(error.AccessDenied, TestBackend.path(cwd, name, &path_buffer));
    Mock.reset();
    var backend: TestBackend = .{};
    try std.testing.expectError(error.NameTooLong, cwd.openFile(backend.io(), &@as([32:0]u8, @splat("x"[0])), .{}));
    try std.testing.expectEqual(@as(usize, 0), Mock.calls);
}

test "native Io: resource ceiling, output preflight and native truncate width" {
    Mock.reset();
    var backend: TestBackend = .{};
    const io = backend.io();
    var files: [4]File = undefined;
    for (&files) |*file| file.* = try platform.cwd().createFile(io, "output", .{});
    const calls = Mock.calls;
    try std.testing.expectError(error.ProcessFdQuotaExceeded, platform.cwd().createFile(io, "overflow", .{}));
    try std.testing.expectError(error.OutputLimit, writeBounded(files[0], io, "12345", 4));
    try std.testing.expectError(error.FileTooBig, files[0].setLength(io, 0x1_0000_0000));
    try std.testing.expectEqual(calls, Mock.calls);
    try writeBounded(files[0], io, "1234", 4);
    try files[0].setLength(io, 0xffff_ffff);
    try std.testing.expectEqual(@as(u64, 0xffff_ffff), Mock.last_args[1]);
    try backend.closeAll();
    try std.testing.expectEqual(@as(usize, 4), backend.peak_files);
    try std.testing.expectEqual(@as(usize, 0), backend.liveFiles());
}

test "native Io: fd metadata, locks, std traversal, network and spawn refuse" {
    Mock.reset();
    var backend: TestBackend = .{};
    const io = backend.io();
    const file = try platform.cwd().openFile(io, "input", .{});
    try std.testing.expectError(error.Unexpected, file.stat(io));
    try std.testing.expectError(error.Unexpected, file.length(io));
    try std.testing.expectError(error.Unexpected, file.tryLock(io, .exclusive));
    try std.testing.expectError(error.Unseekable, io.vtable.fileSeekTo(io.userdata, file, 0));
    try std.testing.expectError(error.Unexpected, platform.cwd().openDir(io, "nested", .{}));
    try std.testing.expectError(error.OperationUnsupported, io.vtable.processSpawn(io.userdata, .{ .argv = &.{"child"} }));
    try std.testing.expectEqual(error.Unexpected, (try io.operate(.{ .net_send = .{
        .socket_handle = 0,
        .messages = &.{},
        .flags = .{},
    } })).net_send[0].?);
    try std.testing.expect(Mock.diagnostics > 0);
    file.close(io);
}

test "native Io: entropy short fill and errors, never zero-filled fallback" {
    Mock.reset();
    var backend: TestBackend = .{};
    const io = backend.io();
    var bytes: [513]u8 = undefined;
    Mock.maximum = 17;
    try io.randomSecure(&bytes);
    try std.testing.expect(std.mem.allEqual(u8, &bytes, 0xa7));
    try std.testing.expectEqual(@as(usize, 31), Mock.calls);
    for ([_]i64{ 0, -1, 257 }) |n| {
        Mock.forced = n;
        @memset(&bytes, 0xcc);
        try std.testing.expectError(error.EntropyUnavailable, io.randomSecure(&bytes));
        try std.testing.expect(std.mem.allEqual(u8, &bytes, 0xcc));
    }
}

test "native Io: synchronous async actually runs; concurrent cannot pretend to run" {
    Mock.reset();
    var backend: TestBackend = .{};
    const io = backend.io();
    const Work = struct {
        fn run(n: u32) u32 {
            return n + 1;
        }
    };
    var task = io.async(Work.run, .{@as(u32, 41)});
    try std.testing.expectEqual(@as(u32, 42), task.await(io));
    try std.testing.expectError(error.ConcurrencyUnavailable, io.concurrent(Work.run, .{@as(u32, 41)}));
    const GroupWork = struct {
        fn run(value: *u32) void {
            value.* += 1;
        }
    };
    var group: Io.Group = .init;
    var completed: u32 = 0;
    group.async(io, GroupWork.run, .{&completed});
    try group.await(io);
    group.cancel(io);
    try std.testing.expectEqual(@as(u32, 1), completed);
    io.recancel();
    const old = io.swapCancelProtection(.blocked);
    try io.checkCancel();
    _ = io.swapCancelProtection(old);
    try std.testing.expectError(error.Canceled, io.checkCancel());
    try io.checkCancel();
}

const TestBackend = Backend(Mock);
const Mock = struct {
    var calls: usize = 0;
    var diagnostics: usize = 0;
    var maximum: usize = 2048;
    var forced: ?i64 = null;
    var input: []const u8 = "";
    var input_at: usize = 0;
    var output: [8192]u8 = undefined;
    var output_len: usize = 0;
    var last_args: [6]u64 = undefined;
    fn reset() void {
        calls = 0;
        diagnostics = 0;
        maximum = 2048;
        forced = null;
        input = "";
        input_at = 0;
        output_len = 0;
    }
    pub fn instance() *anyopaque {
        @panic("test must supply userdata");
    }
    pub fn diagnostic(_: []const u8) void {
        diagnostics += 1;
    }
    pub fn fatal(_: []const u8) noreturn {
        @panic("unexpected fatal refusal");
    }
    pub fn call(number: u64, args: [6]u64) i64 {
        calls += 1;
        last_args = args;
        if (forced) |n| return n;
        switch (number) {
            23 => return 0, // Deliberately recycle native fd zero.
            24 => {
                std.debug.assert(args[2] <= 2048);
                const n = @min(args[2], maximum, input.len - input_at);
                const out: [*]u8 = @ptrFromInt(args[1]);
                @memcpy(out[0..n], input[input_at..][0..n]);
                input_at += n;
                return @intCast(n);
            },
            25 => {
                std.debug.assert(args[2] <= 2048);
                const n = @min(args[2], maximum);
                const bytes: [*]const u8 = @ptrFromInt(args[1]);
                @memcpy(output[output_len..][0..n], bytes[0..n]);
                output_len += n;
                return @intCast(n);
            },
            26, 36, 77 => return 0,
            79 => {
                // Op 10 on a legacy path fd: no pinned object to describe.
                std.debug.assert(args[0] == fs.handle_metadata_op and args[2] == fs.handle_file);
                return -4;
            },
            72 => {
                std.debug.assert(args[1] <= 256);
                const n = @min(args[1], maximum);
                const bytes: [*]u8 = @ptrFromInt(args[0]);
                @memset(bytes[0..n], 0xa7);
                return @intCast(n);
            },
            else => @panic("unexpected native operation"),
        }
    }
};

/// Metadata-free sequential reader. A full limit is probed by one extra byte.
pub fn readBounded(file: File, io: Io, output: []u8) (File.Reader.Error || error{InputLimit})![]u8 {
    var reader: File.Reader = .initStreaming(file, io, &.{});
    const n = reader.interface.readSliceShort(output) catch return reader.err.?;
    if (n == output.len) {
        var extra: [1]u8 = undefined;
        if ((reader.interface.readSliceShort(&extra) catch return reader.err.?) != 0)
            return error.InputLimit;
    }
    return output[0..n];
}

/// Check a complete rendered output before the first write. No seek/stat needed.
pub fn writeBounded(file: File, io: Io, bytes: []const u8, limit: usize) (File.Writer.Error || error{OutputLimit})!void {
    if (bytes.len > limit) return error.OutputLimit;
    try file.writeStreamingAll(io, bytes);
}
