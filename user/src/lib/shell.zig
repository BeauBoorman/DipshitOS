//! VirelaiOS userland shell core (M45 card SH2 — ADR 0021 D2/D3, issue
//! #1078).
//!
//! The pure half of `SH.BIN`: tokenizing, `$VAR`/`$?` expansion, the bounded
//! environment and alias tables, the shell-local cwd, builtin classification,
//! PATH-like candidate resolution, and the line interpreter. It performs no
//! syscalls and holds no file descriptors — `execute` returns an `Action`
//! (`print` / `run` / `source` / `exit`) that the thin EL0 glue in
//! `user/src/sh.zig` performs. That split makes the whole shell surface
//! host-testable.
//!
//! Shape ported from the M19 kernel shell (`kernel/src/tokenizer.zig`,
//! `shell_handle_expanded` in `kernel/src/shell.zig`) but scoped to SH2: no
//! pipes/redirection/globs (SH4), no control flow or command substitution
//! (SH5), no tab completion or Ctrl-R (SH3).

const std = @import("std");
const pipe = @import("pipe.zig");
const script = @import("script.zig");
const toolbox = @import("toolbox.zig");

pub const max_args: usize = 16;
pub const line_max: usize = 256;
pub const env_max: usize = 24;
pub const env_name_max: usize = 32;
pub const env_val_max: usize = 128;
pub const alias_max: usize = 16;
pub const path_max: usize = 64;
pub const cwd_max: usize = 128;
pub const prompt_max: usize = 64;
pub const out_max: usize = 2048;
pub const name_max: usize = 64;
pub const max_candidates: usize = 6;
/// The most glob matches the shell will materialize for one line.
pub const glob_max: usize = 64;

/// A bounded byte string with inline storage. All table cells are this shape
/// so the shell stays allocation-free (fixed BSS in the guest).
pub fn Buf(comptime N: usize) type {
    return struct {
        bytes: [N]u8 = @as([N]u8, @splat(@as(u8, 0))),
        len: usize = 0,

        const Self = @This();

        pub fn set(self: *Self, s: []const u8) void {
            const n = @min(s.len, N);
            @memcpy(self.bytes[0..n], s[0..n]);
            self.len = n;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn eql(self: *const Self, s: []const u8) bool {
            return std.mem.eql(u8, self.slice(), s);
        }
    };
}

pub const Name = Buf(env_name_max);
pub const Value = Buf(env_val_max);
pub const Path = Buf(path_max);
pub const Program = Buf(name_max);

// ---------------------------------------------------------------------------
// Tokenizer (ported from kernel/src/tokenizer.zig, minus the SH4 glob hook).
// ---------------------------------------------------------------------------

pub const TokenizeResult = struct {
    argv: [max_args + 1][]const u8 = undefined,
    /// Per-argument wildcard marker (unquoted, unescaped `*`/`?`/`[`) for the
    /// SH4 glob-expansion stage.
    arg_glob: [max_args + 1]bool = @as([(max_args + 1)]bool, @splat(@as(bool, false))),
    count: usize = 0,
    too_many: bool = false,
    unbalanced_quote: bool = false,
};

/// Split one line into at most `max_args + 1` argument slices. Contiguous
/// runs point into `line`; quoted/escaped joins point into `scratch` (which
/// must outlive every use of the returned slices and never needs to be
/// larger than the line). Quoting/escape semantics match the M19 tokenizer.
pub fn tokenize(line: []const u8, scratch: []u8) TokenizeResult {
    var result: TokenizeResult = .{};
    var index: usize = 0;
    var spos: usize = 0;
    while (index < line.len) {
        if (isSpace(line[index])) {
            index += 1;
            continue;
        }
        if (result.count >= max_args + 1) {
            result.too_many = true;
            break;
        }
        const arg_i = result.count;
        const buf_start = spos;
        var in_single = false;
        var in_double = false;
        while (index < line.len) {
            const c = line[index];
            if (in_single) {
                if (c == '\'') {
                    in_single = false;
                } else {
                    if (spos < scratch.len) scratch[spos] = c;
                    spos += 1;
                }
                index += 1;
                continue;
            }
            if (in_double) {
                if (c == '"') {
                    in_double = false;
                    index += 1;
                    continue;
                }
                if (c == '\\' and index + 1 < line.len) {
                    const n = line[index + 1];
                    switch (n) {
                        '"', '\\', '$' => {
                            if (spos < scratch.len) scratch[spos] = n;
                            spos += 1;
                        },
                        'n' => {
                            if (spos < scratch.len) scratch[spos] = '\n';
                            spos += 1;
                        },
                        't' => {
                            if (spos < scratch.len) scratch[spos] = '\t';
                            spos += 1;
                        },
                        else => {
                            if (spos + 1 < scratch.len) {
                                scratch[spos] = '\\';
                                scratch[spos + 1] = n;
                            }
                            spos += 2;
                        },
                    }
                    index += 2;
                    continue;
                }
                if (spos < scratch.len) scratch[spos] = c;
                spos += 1;
                index += 1;
                continue;
            }
            if (isSpace(c)) break;
            if (c == '\'') {
                in_single = true;
                index += 1;
                continue;
            }
            if (c == '"') {
                in_double = true;
                index += 1;
                continue;
            }
            if (c == '\\') {
                if (index + 1 < line.len) {
                    if (spos < scratch.len) scratch[spos] = line[index + 1];
                    spos += 1;
                    index += 2;
                } else {
                    if (spos < scratch.len) scratch[spos] = '\\';
                    spos += 1;
                    index += 1;
                }
                continue;
            }
            if (c == '*' or c == '?' or c == '[') result.arg_glob[arg_i] = true;
            if (spos < scratch.len) scratch[spos] = c;
            spos += 1;
            index += 1;
        }
        if (in_single or in_double) result.unbalanced_quote = true;
        result.argv[arg_i] = scratch[buf_start..@min(spos, scratch.len)];
        result.count += 1;
    }
    return result;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

// ---------------------------------------------------------------------------
// Environment and aliases.
// ---------------------------------------------------------------------------

pub const EnvEntry = struct {
    name: Name = .{},
    val: Value = .{},
    exported: bool = false,
};

pub const Env = struct {
    entries: [env_max]EnvEntry = @as([env_max]EnvEntry, @splat(@as(EnvEntry, .{}))),
    count: usize = 0,

    pub fn get(self: *const Env, name: []const u8) ?[]const u8 {
        for (self.entries[0..self.count]) |*e| {
            if (e.name.eql(name)) return e.val.slice();
        }
        return null;
    }

    /// Set (or create) a variable. Returns false when the table is full and
    /// the name is new.
    pub fn set(self: *Env, name: []const u8, val: []const u8) bool {
        if (name.len == 0 or name.len > env_name_max) return false;
        for (self.entries[0..self.count]) |*e| {
            if (e.name.eql(name)) {
                e.val.set(val);
                return true;
            }
        }
        if (self.count >= env_max) return false;
        const e = &self.entries[self.count];
        e.name.set(name);
        e.val.set(val);
        e.exported = false;
        self.count += 1;
        return true;
    }

    pub fn setExported(self: *Env, name: []const u8, val: []const u8, exported: bool) bool {
        if (!self.set(name, val)) return false;
        for (self.entries[0..self.count]) |*e| {
            if (e.name.eql(name)) e.exported = exported;
        }
        return true;
    }

    /// Remove a variable. Returns true if it existed.
    pub fn unset(self: *Env, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.entries[i].name.eql(name)) {
                var j = i;
                while (j + 1 < self.count) : (j += 1) self.entries[j] = self.entries[j + 1];
                self.count -= 1;
                return true;
            }
        }
        return false;
    }
};

pub const AliasTable = struct {
    names: [alias_max]Name = @as([alias_max]Name, @splat(@as(Name, .{}))),
    vals: [alias_max]Value = @as([alias_max]Value, @splat(@as(Value, .{}))),
    count: usize = 0,

    pub fn get(self: *const AliasTable, name: []const u8) ?[]const u8 {
        for (self.names[0..self.count], 0..) |*n, i| {
            if (n.eql(name)) return self.vals[i].slice();
        }
        return null;
    }

    pub fn set(self: *AliasTable, name: []const u8, val: []const u8) bool {
        if (name.len == 0) return false;
        for (self.names[0..self.count], 0..) |*n, i| {
            if (n.eql(name)) {
                self.vals[i].set(val);
                return true;
            }
        }
        if (self.count >= alias_max) return false;
        self.names[self.count].set(name);
        self.vals[self.count].set(val);
        self.count += 1;
        return true;
    }

    pub fn unset(self: *AliasTable, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.names[i].eql(name)) {
                var j = i;
                while (j + 1 < self.count) : (j += 1) {
                    self.names[j] = self.names[j + 1];
                    self.vals[j] = self.vals[j + 1];
                }
                self.count -= 1;
                return true;
            }
        }
        return false;
    }
};

/// The shell's view of the line editor's history ring (SH1 owns the store;
/// the `history` builtin only reads it). Index 0 = newest.
pub const HistoryView = struct {
    ctx: ?*anyopaque = null,
    count_fn: ?*const fn (?*anyopaque) usize = null,
    entry_fn: ?*const fn (?*anyopaque, usize) ?[]const u8 = null,

    pub fn count(self: HistoryView) usize {
        return if (self.count_fn) |f| f(self.ctx) else 0;
    }

    pub fn entry(self: HistoryView, i: usize) ?[]const u8 {
        return if (self.entry_fn) |f| f(self.ctx, i) else null;
    }
};

// ---------------------------------------------------------------------------
// M50 TS1 (issue #1135, ADR 0024 D2): the process principal view.
// ---------------------------------------------------------------------------

/// ADR 0024 D1: the two principal ids (`uid_system` = the kernel's
/// authority, `uid_user` = every EL0 process). Mirrored from the kernel; the
/// userland module graph cannot reach `kernel/src/process.zig`.
pub const uid_system: u32 = 0;
pub const uid_user: u32 = 1000;

/// A process principal (uid + caps). Assigned by the kernel at spawn and
/// preserved by exec; no syscall can change it.
pub const Principal = struct {
    uid: u32 = uid_user,
    caps: u32 = 0,
};

/// The shell's read-only view of the calling process's principal. The glue
/// (`user/src/sh.zig`) fills it from `sys_principal`; host tests supply a
/// fake so the builtins stay pure.
pub const PrincipalView = struct {
    ctx: ?*anyopaque = null,
    get_fn: ?*const fn (?*anyopaque) ?Principal = null,

    pub fn get(self: PrincipalView) ?Principal {
        return if (self.get_fn) |f| f(self.ctx) else null;
    }
};

/// M50 TS2 (issue #1136, ADR 0024 D10): the chmod glue for `sys_file_mode`
/// (slot 69, owner-only). The glue (`user/src/sh.zig`) supplies the syscall;
/// host tests supply a fake so the builtin stays pure.
pub const ModeView = struct {
    ctx: ?*anyopaque = null,
    set_fn: ?*const fn (?*anyopaque, []const u8, u16) i64 = null,

    pub fn set(self: ModeView, path: []const u8, mode: u16) ?i64 {
        return if (self.set_fn) |f| f(self.ctx, path, mode) else null;
    }
};

/// M50 TS5 (#1139, ADR 0024 D8): the `secrets` builtin's view of the
/// secret store — key NAMES only, never values. The glue fills it from
/// `sys_secret_get` (slot 70); host tests supply a fake so the builtin
/// stays pure. Values never leave the caller's memory; the builtin prints
/// names only.
pub const max_secret_names: usize = 8;
pub const SecretList = struct {
    names: [max_secret_names][secret_max_key_len]u8 = undefined,
    lens: [max_secret_names]usize = @as([max_secret_names]usize, @splat(@as(usize, 0))),
    count: usize = 0,

    pub fn at(self: *const SecretList, i: usize) []const u8 {
        return self.names[i][0..self.lens[i]];
    }
};
pub const secret_max_key_len: usize = 32;
pub const SecretView = struct {
    ctx: ?*anyopaque = null,
    list_fn: ?*const fn (?*anyopaque, *SecretList) bool = null,

    pub fn list(self: SecretView, out: *SecretList) bool {
        return if (self.list_fn) |f| f(self.ctx, out) else false;
    }
};

/// The ADR 0007 error mnemonics, for the shell's file-op error lines (the
/// class-B trust gate asserts the EACCES spelling).
pub fn errnoName(rc: i64) []const u8 {
    return switch (rc) {
        -1 => "EINVAL",
        -2 => "EBADF",
        -3 => "EFAULT",
        -4 => "ENOSYS",
        -5 => "ENOSPC",
        -6 => "ENOENT",
        -7 => "EACCES",
        -8 => "ENAMETOOLONG",
        -9 => "ENXIO",
        -10 => "ENOMEM",
        else => "ERROR",
    };
}

// ---------------------------------------------------------------------------
// Variable expansion.
// ---------------------------------------------------------------------------

/// Expand `$VAR`, `${VAR}` and `$?` in `line` into `out`. Single quotes
/// protect everything; a backslash pair outside single quotes passes through
/// untouched for the tokenizer to consume (so `\$VAR` is literal).
pub fn expandVars(line: []const u8, out: []u8, env: *const Env, last_status: u8) []u8 {
    var opos: usize = 0;
    var i: usize = 0;
    var in_single = false;
    while (i < line.len and opos < out.len) : (i += 1) {
        if (line[i] == '\'') {
            in_single = !in_single;
            out[opos] = '\'';
            opos += 1;
            continue;
        }
        if (!in_single and line[i] == '\\' and i + 1 < line.len) {
            out[opos] = '\\';
            opos += 1;
            if (opos < out.len) {
                out[opos] = line[i + 1];
                opos += 1;
            }
            i += 1;
            continue;
        }
        if (!in_single and line[i] == '$' and i + 1 < line.len and line[i + 1] == '?') {
            var num: [3]u8 = undefined;
            var nlen: usize = 0;
            var v = last_status;
            if (v == 0) {
                num[0] = '0';
                nlen = 1;
            } else {
                while (v > 0) {
                    num[nlen] = '0' + v % 10;
                    nlen += 1;
                    v /= 10;
                }
            }
            var d = nlen;
            while (d > 0 and opos < out.len) : (d -= 1) {
                out[opos] = num[d - 1];
                opos += 1;
            }
            i += 1;
            continue;
        }
        if (!in_single and line[i] == '$' and i + 1 < line.len) {
            var ns: usize = i + 1;
            var braced = false;
            if (line[ns] == '{') {
                braced = true;
                ns += 1;
            }
            const name_start = ns;
            while (ns < line.len and (std.ascii.isAlphanumeric(line[ns]) or line[ns] == '_')) ns += 1;
            const vname = line[name_start..ns];
            if (vname.len > 0) {
                if (env.get(vname)) |val| {
                    for (val) |b| {
                        if (opos < out.len) {
                            out[opos] = b;
                            opos += 1;
                        }
                    }
                }
                if (braced and ns < line.len and line[ns] == '}') ns += 1;
                i = ns - 1;
                continue;
            }
        }
        if (opos < out.len) {
            out[opos] = line[i];
            opos += 1;
        }
    }
    return out[0..opos];
}

// ---------------------------------------------------------------------------
// Paths and external-command resolution.
// ---------------------------------------------------------------------------

/// Normalize `cwd` + `arg` into an absolute, `.`/`..`-collapsed path.
pub fn normalizePath(cwd: []const u8, arg: []const u8, out: []u8) []u8 {
    var tmp: [path_max * 2]u8 = undefined;
    var tl: usize = 0;
    if (arg.len == 0 or arg[0] != '/') {
        const n = @min(cwd.len, tmp.len);
        @memcpy(tmp[0..n], cwd[0..n]);
        tl = n;
        if (tl < tmp.len) {
            tmp[tl] = '/';
            tl += 1;
        }
    }
    const an = @min(arg.len, tmp.len - tl);
    @memcpy(tmp[tl..][0..an], arg[0..an]);
    tl += an;

    const Part = struct { s: usize, e: usize };
    var parts: [path_max]Part = undefined;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < tl) {
        while (i < tl and tmp[i] == '/') i += 1;
        if (i >= tl) break;
        const s = i;
        while (i < tl and tmp[i] != '/') i += 1;
        const comp = tmp[s..i];
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth < parts.len) {
            parts[depth] = .{ .s = s, .e = i };
            depth += 1;
        }
    }

    var o: usize = 0;
    if (depth == 0) {
        if (o < out.len) {
            out[o] = '/';
            o += 1;
        }
        return out[0..o];
    }
    for (parts[0..depth]) |p| {
        if (o < out.len) {
            out[o] = '/';
            o += 1;
        }
        const cl = @min(p.e - p.s, out.len - o);
        @memcpy(out[o..][0..cl], tmp[p.s..p.e][0..cl]);
        o += cl;
    }
    return out[0..o];
}

fn upperInto(dst: []u8, src: []const u8) []u8 {
    const n = @min(dst.len, src.len);
    for (src[0..n], 0..) |c, i| dst[i] = std.ascii.toUpper(c);
    return dst[0..n];
}

fn addExt(base: []const u8, ext: []const u8, out: *[max_candidates]Program, n: *usize) void {
    if (n.* >= max_candidates) return;
    var p = Program{};
    const bl = @min(base.len, p.bytes.len);
    @memcpy(p.bytes[0..bl], base[0..bl]);
    const el = @min(ext.len, p.bytes.len - bl);
    @memcpy(p.bytes[bl..][0..el], ext[0..el]);
    p.len = bl + el;
    out[n.*] = p;
    n.* += 1;
}

/// The ordered candidate filenames for an external command `verb`: a verb
/// that already names an image is used as-is; otherwise `.BIN`/`.ELF` are
/// tried for the verb, then for its ASCII-uppercase form, then the bare
/// names. The guest loader is case-sensitive, so both cases are offered.
pub fn candidates(verb: []const u8, out: *[max_candidates]Program) usize {
    var n: usize = 0;
    if (std.mem.endsWith(u8, verb, ".BIN") or std.mem.endsWith(u8, verb, ".ELF") or
        std.mem.endsWith(u8, verb, ".SO"))
    {
        out[0].set(verb);
        return 1;
    }
    addExt(verb, ".BIN", out, &n);
    addExt(verb, ".ELF", out, &n);
    var up: Program = .{};
    var upbuf: [name_max]u8 = undefined;
    const up_slice = upperInto(&upbuf, verb);
    up.set(up_slice);
    addExt(up.slice(), ".BIN", out, &n);
    addExt(up.slice(), ".ELF", out, &n);
    out[n].set(verb);
    n += 1;
    out[n].set(up.slice());
    n += 1;
    return n;
}

// ---------------------------------------------------------------------------
// The interpreter.
// ---------------------------------------------------------------------------

pub const Builtin = enum {
    echo,
    cat,
    pwd,
    cd,
    exit,
    env,
    set,
    unset,
    export_,
    printenv,
    alias,
    unalias,
    history,
    prompt,
    type_,
    which,
    true_,
    false_,
    help,
    source,
    jobs,
    fg,
    monitor_,
    read_,
    break_,
    continue_,
    whoami,
    id_,
    chmod,
    secrets,
};

/// Builtin lookup by verb (the system command boundary, ADR 0021 D3).
pub fn classify(verb: []const u8) ?Builtin {
    const table = .{
        .{ "echo", Builtin.echo },          .{ "cat", Builtin.cat },
        .{ "pwd", Builtin.pwd },            .{ "cd", Builtin.cd },
        .{ "exit", Builtin.exit },          .{ "env", Builtin.env },
        .{ "set", Builtin.set },            .{ "unset", Builtin.unset },
        .{ "export", Builtin.export_ },     .{ "printenv", Builtin.printenv },
        .{ "alias", Builtin.alias },        .{ "unalias", Builtin.unalias },
        .{ "history", Builtin.history },    .{ "prompt", Builtin.prompt },
        .{ "type", Builtin.type_ },         .{ "which", Builtin.which },
        .{ "true", Builtin.true_ },         .{ "false", Builtin.false_ },
        .{ "help", Builtin.help },          .{ "source", Builtin.source },
        .{ ".", Builtin.source },           .{ "jobs", Builtin.jobs },
        .{ "fg", Builtin.fg },              .{ "monitor", Builtin.monitor_ },
        .{ "read", Builtin.read_ },         .{ "break", Builtin.break_ },
        .{ "continue", Builtin.continue_ }, .{ "whoami", Builtin.whoami },
        .{ "id", Builtin.id_ },             .{ "chmod", Builtin.chmod },
        .{ "secrets", Builtin.secrets },
    };
    inline for (table) |row| {
        if (std.mem.eql(u8, verb, row[0])) return row[1];
    }
    return null;
}

/// The builtin verbs, in the order `help` advertises them. Public so the
/// completion source can offer them without duplicating the list.
pub const builtin_names = [_][]const u8{
    "alias",    "break",  "cat",    "cd",      "chmod", "continue", "cut",
    "echo",     "env",    "exit",   "export",  "false", "fg",       "fn",
    "grep",     "head",   "help",   "history", "id",    "jobs",     "monitor",
    "printenv", "printf", "prompt", "pwd",     "read",  "secrets",  "set",
    "sort",     "source", "tail",   "test",    "true",  "type",     "unalias",
    "unset",    "wc",     "which",  "whoami",  "[",
};

pub const completion_max: usize = 32;

/// A sorted, de-duplicated set of completion candidates.
pub const CompletionSet = struct {
    names: [completion_max][path_max]u8 = undefined,
    lens: [completion_max]usize = @as([completion_max]usize, @splat(@as(usize, 0))),
    count: usize = 0,

    pub fn at(self: *const CompletionSet, i: usize) []const u8 {
        return self.names[i][0..self.lens[i]];
    }
};

fn addCompletion(prefix: []const u8, name: []const u8, out: *CompletionSet) void {
    if (name.len == 0 or prefix.len == 0) return;
    if (name.len < prefix.len) return;
    if (!std.ascii.startsWithIgnoreCase(name, prefix)) return;
    var k: usize = 0;
    while (k < out.count) : (k += 1) {
        if (std.mem.eql(u8, out.names[k][0..out.lens[k]], name)) return;
    }
    if (out.count >= completion_max) return;
    const n = @min(name.len, path_max);
    @memcpy(out.names[out.count][0..n], name[0..n]);
    out.lens[out.count] = n;
    out.count += 1;
}

fn sortCompletion(out: *CompletionSet) void {
    if (out.count <= 1) return;
    var i: usize = 1;
    while (i < out.count) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            const a = out.at(j - 1);
            const b = out.at(j);
            if (std.mem.order(u8, a, b) != .gt) break;
            const tmp_name = out.names[j - 1];
            const tmp_len = out.lens[j - 1];
            out.names[j - 1] = out.names[j];
            out.lens[j - 1] = out.lens[j];
            out.names[j] = tmp_name;
            out.lens[j] = tmp_len;
        }
    }
}

/// Collect completion candidates for `prefix`: in command position the
/// builtins, aliases, and share apps (with `.BIN`/`.ELF`/`.SO` basenames);
/// in argument position the share files. A `$`-prefixed prefix completes
/// environment variable names (M49 SD4: `$PA` -> `$PATH`). Case-insensitive,
/// de-duplicated, sorted.
pub fn complete(
    prefix: []const u8,
    is_cmd: bool,
    aliases: *const AliasTable,
    env: ?*const Env,
    listing: []const []const u8,
    out: *CompletionSet,
) usize {
    out.count = 0;
    if (prefix.len == 0) return 0;
    if (prefix[0] == '$') {
        // `$NAME` completion: candidates carry the sigil so the replacement
        // is the whole token.
        if (env) |e| {
            for (e.entries[0..e.count]) |*entry| {
                var buf: [env_name_max + 1]u8 = undefined;
                buf[0] = '$';
                const n = @min(entry.name.len, env_name_max);
                @memcpy(buf[1..][0..n], entry.name.slice()[0..n]);
                addCompletion(prefix, buf[0 .. n + 1], out);
            }
        }
        sortCompletion(out);
        return out.count;
    }
    if (is_cmd) {
        for (builtin_names) |b| addCompletion(prefix, b, out);
        for (aliases.names[0..aliases.count]) |*n| addCompletion(prefix, n.slice(), out);
    }
    for (listing) |entry| {
        addCompletion(prefix, entry, out);
        if (std.mem.endsWith(u8, entry, ".BIN") or
            std.mem.endsWith(u8, entry, ".ELF") or
            std.mem.endsWith(u8, entry, ".SO"))
        {
            addCompletion(prefix, entry[0 .. entry.len - 4], out);
        }
    }
    sortCompletion(out);
    return out.count;
}

pub const RunRequest = struct {
    candidates: [max_candidates]Program = @as([max_candidates]Program, @splat(@as(Program, .{}))),
    count: usize = 0,

    pub fn at(self: *const RunRequest, i: usize) []const u8 {
        return self.candidates[i].slice();
    }
};

/// M49 SD3 (#1130): a tool invocation carried to the glue. The argv is
/// copied into fixed buffers (the shell's BSS), so the glue can build the
/// `[]const []const u8` slice after the `Action` value lands.
pub const tool_arg_max: usize = 12;
/// M73a-2 (#1631): one tool argument must hold what `tokenize` can hand
/// out — slices run the whole `scratch` (`line_max * 2`) — so the fixed
/// copy buffer matches it. At 64 this silently truncated (Buf.set's
/// `@min`), cutting `printf '<long format>'` mid-sequence: observed as a
/// frame row that stopped after its first rune on the live-term gate.
pub const tool_arg_bytes: usize = line_max * 2;

pub const ToolRequest = struct {
    tool: toolbox.Tool,
    args: [tool_arg_max]Buf(tool_arg_bytes) = @as([tool_arg_max]Buf(tool_arg_bytes), @splat(@as(Buf(tool_arg_bytes), .{}))),
    count: usize = 0,

    pub fn at(self: *const ToolRequest, i: usize) []const u8 {
        return self.args[i].slice();
    }
};

pub const SourceRequest = struct {
    path: Path = .{},
};

/// M49 SD4 (#1131): the line-editor keymap the shell can select
/// (`set -o vi` / `set +o vi`; emacs is the default).
pub const EditorMode = enum {
    emacs,
    vi,
};

pub const Action = union(enum) {
    /// Nothing to do (state changed in place).
    none,
    /// Write `Shell.outSlice()` to the terminal.
    print,
    /// Run an external program; the glue tries each candidate in order.
    run: RunRequest,
    /// Read `path` and execute its lines.
    source: SourceRequest,
    /// Call the function at this `FuncTable` index; the glue runs its body
    /// commands through the full line interpreter.
    call: usize,
    /// Leave the shell with this status.
    exit: u8,
    /// M49 SD1 (#1128, ADR 0021 D1): release the terminal and hand the raw
    /// console back to the kernel monitor. Unlike `exit`, the glue detaches
    /// first, so a `shell=sh` login boot is not a one-way door.
    monitor,
    /// M49 SD4 (#1131): switch the shared line editor's keymap.
    set_editor: EditorMode,
    /// M49 SD3 (#1130): run a built-in tool from `lib/toolbox.zig` (head,
    /// tail, wc, grep, sort, cut, test/[, printf). The glue supplies the
    /// file/stream seams.
    tool: ToolRequest,
};

pub const Shell = struct {
    env: Env = .{},
    aliases: AliasTable = .{},
    cwd: Path = .{},
    prompt: Buf(prompt_max) = .{},
    last_status: u8 = 0,
    out: Buf(out_max) = .{},
    history: HistoryView = .{},
    /// M50 TS1 (#1135): the calling process's principal (uid/caps) for
    /// `whoami`/`id`. The glue fills it from `sys_principal`.
    principal: PrincipalView = .{},
    /// M50 TS2 (#1136): the `chmod` glue (slot 69, owner-only).
    mode_view: ModeView = .{},
    /// M50 TS5 (#1139): the `secrets` builtin's names-only view of the
    /// secret store (slot 70). Values never reach this struct.
    secret_view: SecretView = .{},
    /// Bound stdin for `cat` (a pipe or `<` redirect); empty = none.
    stdin: []const u8 = &.{},
    /// SH5 shell functions (`fn NAME(args) { ... }`).
    funcs: script.FuncTable = .{},
    /// SH5 loop signals set by `break`/`continue`; the glue's loop runner
    /// clears them between iterations and reads them after each body.
    loop_break: bool = false,
    loop_continue: bool = false,
    /// M49 SD4 (#1131): the currently selected editor keymap (the glue
    /// mirrors it onto the shared `lib/tty.zig` editor).
    editor_mode: EditorMode = .emacs,

    expand_buf: [line_max * 2]u8 = undefined,
    arith_buf: [line_max * 2]u8 = undefined,
    scratch: [line_max * 2]u8 = undefined,
    glob_argv: [max_args + 1][]const u8 = undefined,
    glob_names: [glob_max][path_max]u8 = undefined,

    pub fn init() Shell {
        var s = Shell{};
        s.cwd.set("/");
        s.prompt.set("sh> ");
        return s;
    }

    pub fn outSlice(self: *const Shell) []const u8 {
        return self.out.slice();
    }

    /// M49 SD3 (#1130): append externally-produced bytes (a tool writing
    /// through the glue's `Writer`) to the current capture.
    pub fn appendOut(self: *Shell, bytes: []const u8) void {
        self.emit(bytes);
    }

    pub fn promptSlice(self: *const Shell) []const u8 {
        return self.prompt.slice();
    }

    pub fn cwdSlice(self: *const Shell) []const u8 {
        return self.cwd.slice();
    }

    /// Bind (or clear) the input a `cat` builtin consumes. The slice must
    /// outlive the next `execute` call.
    pub fn setStdin(self: *Shell, data: []const u8) void {
        self.stdin = data;
    }

    fn emit(self: *Shell, text: []const u8) void {
        const room = out_max - self.out.len;
        const n = @min(text.len, room);
        @memcpy(self.out.bytes[self.out.len..][0..n], text[0..n]);
        self.out.len += n;
    }

    fn emitLine(self: *Shell, text: []const u8) void {
        self.emit(text);
        self.emit("\n");
    }

    fn emitNum(self: *Shell, v: u64) void {
        var buf: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
        self.emit(s);
    }

    /// Execute one line. `listing` is the host-share filename snapshot the
    /// glue gathered (used by `type`/`which`); resolution itself is the
    /// candidate list so the 16-entry dir_list cap cannot hide an image.
    pub fn execute(self: *Shell, line: []const u8, listing: []const []const u8) Action {
        self.out.len = 0;
        const arith = script.arithExpand(line, &self.arith_buf);
        const expanded = expandVars(arith, &self.expand_buf, &self.env, self.last_status);
        var tk = tokenize(expanded, &self.scratch);
        if (tk.too_many) {
            self.emitLine("sh: too many arguments");
            self.last_status = 2;
            return .print;
        }
        if (tk.count == 0) return .none;
        var argv: []const []const u8 = tk.argv[0..tk.count];
        var wild: []const bool = tk.arg_glob[0..tk.count];

        // Alias expansion in command position (one level, bounded). `tk2`
        // lives to the end of this call so the argv slices stay valid.
        var tk2: TokenizeResult = undefined;
        if (self.aliases.get(argv[0])) |val| {
            var joined: [line_max * 2]u8 = undefined;
            var jl: usize = 0;
            const vl = @min(val.len, joined.len);
            @memcpy(joined[0..vl], val[0..vl]);
            jl = vl;
            for (argv[1..]) |a| {
                if (jl < joined.len) {
                    joined[jl] = ' ';
                    jl += 1;
                }
                const al = @min(a.len, joined.len - jl);
                @memcpy(joined[jl..][0..al], a[0..al]);
                jl += al;
            }
            tk2 = tokenize(joined[0..jl], &self.scratch);
            if (tk2.count == 0) return .none;
            argv = tk2.argv[0..tk2.count];
            wild = tk2.arg_glob[0..tk2.count];
        }

        // SH4: expand unquoted wildcard arguments against the share listing.
        argv = self.expandGlobs(argv, wild, listing) orelse {
            self.emitLine("glob: too many matches");
            self.last_status = 2;
            return .print;
        };

        if (classify(argv[0])) |b| return self.runBuiltin(b, argv, listing);
        // M49 SD3 (#1130): the built-in tool multicall (head, tail, wc,
        // grep, sort, cut, test, [, printf). It runs before function/external
        // resolution so pipes and redirection capture its output.
        if (toolbox.lookup(argv[0])) |tool| return self.runTool(tool, argv);
        if (self.funcs.find(argv[0])) |idx| {
            self.bindFuncArgs(idx, argv);
            return .{ .call = idx };
        }
        return runExternal(argv[0]);
    }

    /// Bind `$0`, `$1..$N` and the declared named arguments for a function
    /// call (M19 semantics), then the glue runs the body.
    fn bindFuncArgs(self: *Shell, idx: usize, argv: []const []const u8) void {
        const f = &self.funcs.funcs[idx];
        _ = self.env.set("0", f.name[0..f.name_len]);
        var ai: usize = 1;
        while (ai < argv.len and ai <= script.func_arg_max) : (ai += 1) {
            var pn: [4]u8 = undefined;
            const s = std.fmt.bufPrint(&pn, "{d}", .{ai}) catch continue;
            _ = self.env.set(s, argv[ai]);
        }
        ai = 1;
        while (ai < argv.len and ai - 1 < f.arg_count) : (ai += 1) {
            _ = self.env.set(f.argName(ai - 1), argv[ai]);
        }
    }

    /// True for a `fn ...` definition line (SH5).
    pub fn isFuncDef(line: []const u8) bool {
        if (!std.mem.startsWith(u8, line, "fn")) return false;
        if (line.len == 2) return true;
        return line[2] == ' ' or line[2] == '\t' or line[2] == '(';
    }

    /// Define a shell function from a raw `fn NAME(args) { body }` line.
    pub fn defineFuncLine(self: *Shell, line: []const u8) bool {
        if (!isFuncDef(line)) return false;
        const rest = if (line.len > 2 and (line[2] == ' ' or line[2] == '\t')) line[3..] else line[2..];
        const def = script.parseFuncDef(rest) orelse return false;
        return self.funcs.define(def);
    }

    pub fn clearLoopFlags(self: *Shell) void {
        self.loop_break = false;
        self.loop_continue = false;
    }

    /// Expand every wildcard-flagged argument against `listing`, byte-sorted
    /// (nullglob-off: no match passes the literal pattern). Returns null
    /// when the expansion would exceed the shell's argv/name bounds.
    fn expandGlobs(
        self: *Shell,
        argv: []const []const u8,
        wild: []const bool,
        listing: []const []const u8,
    ) ?[]const []const u8 {
        var any = false;
        for (wild) |w| {
            if (w) {
                any = true;
                break;
            }
        }
        if (!any) return argv;

        var count: usize = 0;
        var total: usize = 0;
        for (argv, wild) |arg, is_wild| {
            if (!is_wild) {
                if (count >= self.glob_argv.len) return null;
                self.glob_argv[count] = arg;
                count += 1;
                continue;
            }
            var matches: [glob_max][]const u8 = undefined;
            var m: usize = 0;
            for (listing) |name| {
                if (!pipe.globMatch(arg, name)) continue;
                var pos = m;
                while (pos > 0 and std.mem.lessThan(u8, name, matches[pos - 1])) : (pos -= 1) {
                    matches[pos] = matches[pos - 1];
                }
                matches[pos] = name;
                m += 1;
                if (m >= glob_max) break;
            }
            if (total + m > glob_max) return null;
            if (m == 0) {
                if (count >= self.glob_argv.len) return null;
                self.glob_argv[count] = arg; // nullglob-off passthrough
                count += 1;
                continue;
            }
            for (matches[0..m]) |name| {
                if (count >= self.glob_argv.len) return null;
                const dst = &self.glob_names[total];
                const n = @min(name.len, path_max);
                @memcpy(dst[0..n], name[0..n]);
                self.glob_argv[count] = dst[0..n];
                count += 1;
                total += 1;
            }
        }
        return self.glob_argv[0..count];
    }

    fn runExternal(verb: []const u8) Action {
        var req = RunRequest{};
        req.count = candidates(verb, &req.candidates);
        // `verb` may have been an alias-expanded slice into scratch; the
        // request carries owned copies only.
        return .{ .run = req };
    }

    /// M49 SD3 (#1130): copy the invocation into the bounded tool request.
    fn runTool(self: *Shell, tool: toolbox.Tool, argv: []const []const u8) Action {
        _ = self;
        var req = ToolRequest{ .tool = tool };
        const n = @min(argv.len, tool_arg_max);
        var i: usize = 0;
        while (i < n) : (i += 1) req.args[i].set(argv[i]);
        req.count = n;
        return .{ .tool = req };
    }

    fn runBuiltin(self: *Shell, b: Builtin, argv: []const []const u8, listing: []const []const u8) Action {
        switch (b) {
            .echo => {
                var first = true;
                for (argv[1..]) |a| {
                    if (!first) self.emit(" ");
                    first = false;
                    self.emit(a);
                }
                self.emitLine("");
                self.last_status = 0;
                return .print;
            },
            .cat => {
                // SH4: emit the bound input (a pipe or `<` redirect). A file
                // argument is intentionally unsupported (`cat < FILE`).
                if (self.stdin.len == 0) {
                    self.emitLine("cat: no input (use `cat < FILE` or a pipe)");
                    self.last_status = 1;
                    return .print;
                }
                self.emit(self.stdin);
                self.last_status = 0;
                return .print;
            },
            .pwd => {
                self.emitLine(self.cwd.slice());
                self.last_status = 0;
                return .print;
            },
            .cd => {
                const target = if (argv.len >= 2) argv[1] else "/";
                var nb: [cwd_max]u8 = undefined;
                const np = normalizePath(self.cwd.slice(), target, &nb);
                self.cwd.set(np);
                _ = self.env.setExported("PWD", self.cwd.slice(), true);
                self.last_status = 0;
                return .none;
            },
            .exit => {
                var status: u8 = self.last_status;
                if (argv.len >= 2) {
                    status = std.fmt.parseInt(u8, argv[1], 10) catch self.last_status;
                }
                return .{ .exit = status };
            },
            .env, .printenv, .set, .export_ => {
                // M49 SD4 (#1131): `set -o vi` / `set +o vi` / `set -o` are
                // the keymap controls; `set` with no argument keeps listing
                // the environment (the M19 shape).
                if (b == .set and argv.len >= 2 and
                    (std.mem.eql(u8, argv[1], "-o") or std.mem.eql(u8, argv[1], "+o")))
                {
                    const enable = argv[1][0] == '-';
                    if (argv.len < 3) {
                        self.emitLine(if (self.editor_mode == .vi) "vi" else "emacs");
                        self.last_status = 0;
                        return .print;
                    }
                    if (std.mem.eql(u8, argv[2], "vi")) {
                        self.editor_mode = if (enable) .vi else .emacs;
                        self.last_status = 0;
                        return .{ .set_editor = self.editor_mode };
                    }
                    if (std.mem.eql(u8, argv[2], "emacs")) {
                        self.editor_mode = .emacs;
                        self.last_status = 0;
                        return .{ .set_editor = .emacs };
                    }
                    self.emitLine("set: usage: set -o vi | set +o vi | set -o");
                    self.last_status = 1;
                    return .print;
                }
                // `set`/`export` with no argument list (that is the M19
                // shape); a NAME=VALUE argument mutates the table.
                if (argv.len >= 2 and (b == .set or b == .export_)) {
                    const arg = argv[1];
                    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
                    const name = arg[0..eq];
                    const val = if (eq < arg.len) arg[eq + 1 ..] else "";
                    const exported = b == .export_;
                    if (!self.env.setExported(name, val, exported)) {
                        self.emitLine("sh: env table full");
                        self.last_status = 1;
                        return .print;
                    }
                    self.last_status = 0;
                    return .none;
                }
                for (self.env.entries[0..self.env.count]) |*e| {
                    self.emit(e.name.slice());
                    self.emit("=");
                    self.emitLine(e.val.slice());
                }
                self.last_status = 0;
                return .print;
            },
            .unset => {
                if (argv.len < 2) {
                    self.emitLine("unset: usage: unset VAR");
                    self.last_status = 1;
                } else {
                    _ = self.env.unset(argv[1]);
                    self.last_status = 0;
                }
                return .print;
            },
            .alias => {
                if (argv.len < 2) {
                    for (self.aliases.names[0..self.aliases.count], 0..) |*n, i| {
                        self.emit(n.slice());
                        self.emit("=");
                        self.emitLine(self.aliases.vals[i].slice());
                    }
                    self.last_status = 0;
                    return .print;
                }
                const arg = argv[1];
                const eq = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
                if (eq == 0 or eq >= arg.len) {
                    self.emitLine("alias: usage: alias NAME=VALUE");
                    self.last_status = 1;
                    return .print;
                }
                var valbuf: [env_val_max]u8 = undefined;
                var vp: usize = 0;
                const seed = arg[eq + 1 ..];
                const sn = @min(seed.len, valbuf.len);
                @memcpy(valbuf[0..sn], seed[0..sn]);
                vp = sn;
                for (argv[2..]) |a| {
                    if (vp < valbuf.len) {
                        valbuf[vp] = ' ';
                        vp += 1;
                    }
                    const an = @min(a.len, valbuf.len - vp);
                    @memcpy(valbuf[vp..][0..an], a[0..an]);
                    vp += an;
                }
                _ = self.aliases.set(arg[0..eq], valbuf[0..vp]);
                self.emitLine("alias: ok");
                self.last_status = 0;
                return .print;
            },
            .unalias => {
                if (argv.len < 2) {
                    self.emitLine("unalias: usage: unalias NAME");
                    self.last_status = 1;
                } else if (!self.aliases.unset(argv[1])) {
                    self.emit("unalias: ");
                    self.emit(argv[1]);
                    self.emitLine(": no such alias");
                    self.last_status = 1;
                } else {
                    self.last_status = 0;
                }
                return .print;
            },
            .history => {
                const count = self.history.count();
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const entry = self.history.entry(i) orelse continue;
                    self.emit("  ");
                    self.emitNum(@intCast(count - i));
                    self.emit("  ");
                    self.emitLine(entry);
                }
                self.last_status = 0;
                return .print;
            },
            .prompt => {
                if (argv.len < 2) {
                    self.emitLine("prompt: usage: prompt NEW_PROMPT");
                    self.last_status = 1;
                } else {
                    self.prompt.set(argv[1]);
                    self.last_status = 0;
                }
                return .print;
            },
            .type_, .which => {
                if (argv.len < 2) {
                    self.emitLine("type: usage: type NAME");
                    self.last_status = 1;
                    return .print;
                }
                const name = argv[1];
                if (classify(name) != null or toolbox.lookup(name) != null) {
                    self.emit(name);
                    self.emitLine(": shell builtin");
                    self.last_status = 0;
                    return .print;
                }
                var cands: [max_candidates]Program = undefined;
                const n = candidates(name, &cands);
                const first = if (n > 0) cands[0].slice() else name;
                var present = false;
                for (listing) |entry| {
                    if (std.mem.eql(u8, entry, first)) present = true;
                }
                self.emit(name);
                self.emit(": ");
                self.emit(first);
                self.emitLine(if (present) " (present)" else " (external)");
                self.last_status = 0;
                return .print;
            },
            .true_ => {
                self.last_status = 0;
                return .none;
            },
            .false_ => {
                self.last_status = 1;
                return .none;
            },
            .help => {
                self.emitLine("builtins: echo pwd cd exit env set unset export printenv alias unalias history prompt type which true false help source jobs fg monitor read whoami id chmod secrets");
                self.emitLine("tools: head tail wc grep sort cut test [ printf");
                self.last_status = 0;
                return .print;
            },
            .source => {
                if (argv.len < 2) {
                    self.emitLine("source: usage: source FILE");
                    self.last_status = 1;
                    return .print;
                }
                var req = SourceRequest{};
                req.path.set(argv[1]);
                return .{ .source = req };
            },
            .jobs => {
                self.emitLine("jobs: no background jobs");
                self.last_status = 0;
                return .print;
            },
            .fg => {
                self.emitLine("fg: no background jobs");
                self.last_status = 1;
                return .print;
            },
            .monitor_ => {
                // M49 SD1 (#1128): the escape hatch back to the kernel
                // monitor. The glue owns the detach+exit (it holds the
                // terminal session).
                self.last_status = 0;
                return .monitor;
            },
            .read_ => {
                // M49 SD3 (#1130): `read VAR` takes one line from the bound
                // input (a pipe or `<` redirect). Interactive line input
                // stays the editor's job.
                if (argv.len < 2) {
                    self.emitLine("read: usage: read VAR");
                    self.last_status = 1;
                    return .print;
                }
                if (self.stdin.len == 0) {
                    self.emitLine("read: no input (use `read VAR < FILE` or a pipe)");
                    self.last_status = 1;
                    return .print;
                }
                var end: usize = 0;
                while (end < self.stdin.len and self.stdin[end] != '\n') end += 1;
                var val = self.stdin[0..end];
                if (val.len > 0 and val[val.len - 1] == '\r') val = val[0 .. val.len - 1];
                self.stdin = if (end < self.stdin.len) self.stdin[end + 1 ..] else self.stdin[end..];
                _ = self.env.set(argv[1], val);
                self.last_status = 0;
                return .none;
            },
            .break_ => {
                self.loop_break = true;
                self.last_status = 0;
                return .none;
            },
            .continue_ => {
                self.loop_continue = true;
                self.last_status = 0;
                return .none;
            },
            .whoami => {
                // M50 TS1 (#1135): the calling process's principal, read
                // through slot 68 (the glue supplies the view).
                if (self.principal.get()) |p| {
                    self.emit("uid=");
                    self.emitNum(p.uid);
                    self.emitLine(if (p.uid == uid_system) " system" else " user");
                    self.last_status = 0;
                } else {
                    self.emitLine("whoami: no principal");
                    self.last_status = 1;
                }
                return .print;
            },
            .id_ => {
                // M50 TS1 (#1135): `id` adds the capability mask — the
                // class-B gate asserts uid=1000/caps=0 agree with whoami.
                if (self.principal.get()) |p| {
                    self.emit("uid=");
                    self.emitNum(p.uid);
                    self.emit(if (p.uid == uid_system) " system" else " user");
                    self.emit(" caps=");
                    self.emitNum(p.caps);
                    self.emitLine("");
                    self.last_status = 0;
                } else {
                    self.emitLine("id: no principal");
                    self.last_status = 1;
                }
                return .print;
            },
            .chmod => {
                // M50 TS2 (#1136, ADR 0024 D10): owner-only chmod through
                // `sys_file_mode` (slot 69). The kernel is the authority; the
                // shell only forwards the 3-digit octal mode.
                if (argv.len < 3) {
                    self.emitLine("chmod: usage: chmod MODE FILE");
                    self.last_status = 1;
                    return .print;
                }
                const mode = parseOctMode(argv[1]) orelse {
                    self.emitLine("chmod: invalid mode (use octal, e.g. 600)");
                    self.last_status = 1;
                    return .print;
                };
                if (self.mode_view.set(argv[2], mode)) |rc| {
                    if (rc == 0) {
                        self.emitLine("chmod: ok");
                        self.last_status = 0;
                    } else {
                        self.emit("chmod: ");
                        self.emit(argv[2]);
                        self.emit(": ");
                        self.emitLine(errnoName(rc));
                        self.last_status = 1;
                    }
                } else {
                    self.emitLine("chmod: no mode view");
                    self.last_status = 1;
                }
                return .print;
            },
            .secrets => {
                // M50 TS5 (#1139, ADR 0024 D8): the secret store's key NAMES
                // for the calling principal. Values leave the kernel only
                // into the caller's memory and this builtin prints names
                // only — the never-logged contract holds in the shell too.
                var list = SecretList{};
                if (self.secret_view.list(&list)) {
                    if (list.count == 0) {
                        self.emitLine("secrets: (none)");
                    } else {
                        var i: usize = 0;
                        while (i < list.count) : (i += 1) {
                            self.emit("  ");
                            self.emitLine(list.at(i));
                        }
                    }
                    self.last_status = 0;
                } else {
                    self.emitLine("secrets: unavailable");
                    self.last_status = 1;
                }
                return .print;
            },
        }
    }
};

/// Parse a 1..4 digit octal mode (e.g. `600`, `0600`, `644`). The kernel
/// re-validates and reserves the group triplet; the shell only rejects
/// non-octal input.
fn parseOctMode(s: []const u8) ?u16 {
    if (s.len == 0 or s.len > 4) return null;
    var v: u16 = 0;
    for (s) |c| {
        if (c < '0' or c > '7') return null;
        v = v * 8 + @as(u16, c - '0');
    }
    if (v > 0o777) return null;
    return v;
}

// ---------------------------------------------------------------------------
// Host tests (pure; no syscalls)
// ---------------------------------------------------------------------------

test "shell: tokenize quoted/joined/escaped arguments" {
    var scratch: [256]u8 = undefined;
    const r1 = tokenize("echo \"elephant business\"", &scratch);
    try std.testing.expectEqual(@as(usize, 2), r1.count);
    try std.testing.expectEqualStrings("elephant business", r1.argv[1]);
    const r2 = tokenize("echo ab\"cd ef\"gh", &scratch);
    try std.testing.expectEqualStrings("abcd efgh", r2.argv[1]);
    const r3 = tokenize("echo a\\ b", &scratch);
    try std.testing.expectEqualStrings("a b", r3.argv[1]);
    const r4 = tokenize("echo 'a;b|c'", &scratch);
    try std.testing.expectEqualStrings("a;b|c", r4.argv[1]);
    const r5 = tokenize("echo 'unterminated", &scratch);
    try std.testing.expect(r5.unbalanced_quote);
}

test "shell: tokenize collapses whitespace and bounds tokens" {
    var scratch: [256]u8 = undefined;
    const r = tokenize("  echo   a    b  ", &scratch);
    try std.testing.expectEqual(@as(usize, 3), r.count);
    try std.testing.expectEqualStrings("b", r.argv[2]);
    var line: [512]u8 = undefined;
    var n: usize = 0;
    var t: usize = 0;
    while (t < max_args + 2) : (t += 1) {
        if (t > 0) {
            line[n] = ' ';
            n += 1;
        }
        line[n] = 'a';
        n += 1;
    }
    const r2 = tokenize(line[0..n], &scratch);
    try std.testing.expect(r2.too_many);
}

test "shell: expandVars substitutes $VAR, ${VAR}, $? and honors quoting" {
    var env = Env{};
    _ = env.set("HOME", "/data");
    _ = env.set("X", "42");
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/data/x", expandVars("$HOME/x", &out, &env, 0));
    try std.testing.expectEqualStrings("42!", expandVars("${X}!", &out, &env, 0));
    try std.testing.expectEqualStrings("7", expandVars("$?", &out, &env, 7));
    // Single quotes protect; backslash passes the pair through to tokenize.
    try std.testing.expectEqualStrings("'$HOME'", expandVars("'$HOME'", &out, &env, 0));
    try std.testing.expectEqualStrings("\\$HOME", expandVars("\\$HOME", &out, &env, 0));
    // Unknown variables expand to empty.
    try std.testing.expectEqualStrings("", expandVars("$NOPE", &out, &env, 0));
}

test "shell: environment table set/get/unset/export and bounds" {
    var env = Env{};
    _ = env.set("A", "1");
    _ = env.set("B", "2");
    try std.testing.expectEqualStrings("1", env.get("A").?);
    _ = env.set("A", "11");
    try std.testing.expectEqualStrings("11", env.get("A").?);
    try std.testing.expect(env.unset("A"));
    try std.testing.expect(env.get("A") == null);
    try std.testing.expect(!env.unset("A"));
    _ = env.setExported("E", "v", true);
    for (env.entries[0..env.count]) |*e| {
        if (e.name.eql("E")) try std.testing.expect(e.exported);
    }
    var i: usize = 0;
    while (i < env_max) : (i += 1) {
        var nm: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&nm, "K{d}", .{i}) catch unreachable;
        _ = env.set(s, "x");
    }
    try std.testing.expectEqual(env_max, env.count);
    try std.testing.expect(!env.set("OVERFLOW", "x"));
}

test "shell: alias table set/get/unset" {
    var al = AliasTable{};
    try std.testing.expect(al.set("ll", "echo list"));
    try std.testing.expectEqualStrings("echo list", al.get("ll").?);
    try std.testing.expect(al.set("ll", "echo long"));
    try std.testing.expectEqualStrings("echo long", al.get("ll").?);
    try std.testing.expect(al.unset("ll"));
    try std.testing.expect(al.get("ll") == null);
    try std.testing.expect(!al.unset("nope"));
}

test "shell: normalizePath handles relative, absolute, dot and dotdot" {
    var out: [cwd_max]u8 = undefined;
    try std.testing.expectEqualStrings("/", normalizePath("/", "/", &out));
    try std.testing.expectEqualStrings("/data", normalizePath("/", "/data", &out));
    try std.testing.expectEqualStrings("/data/sub", normalizePath("/data", "sub", &out));
    try std.testing.expectEqualStrings("/data", normalizePath("/data/sub", "..", &out));
    try std.testing.expectEqualStrings("/", normalizePath("/data", "..", &out));
    try std.testing.expectEqualStrings("/a/c", normalizePath("/a/b", "../c", &out));
    try std.testing.expectEqualStrings("/a/b", normalizePath("/a/b", "./", &out));
    try std.testing.expectEqualStrings("/", normalizePath("/a/b", "../../..", &out));
}

test "shell: candidates order favors .BIN/.ELF then uppercase" {
    var out: [max_candidates]Program = undefined;
    const n = candidates("status43", &out);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualStrings("status43.BIN", out[0].slice());
    try std.testing.expectEqualStrings("status43.ELF", out[1].slice());
    try std.testing.expectEqualStrings("STATUS43.BIN", out[2].slice());
    try std.testing.expectEqualStrings("STATUS43.ELF", out[3].slice());
    try std.testing.expectEqualStrings("status43", out[4].slice());
    try std.testing.expectEqualStrings("STATUS43", out[5].slice());
    // An explicit image name is used as-is.
    const n2 = candidates("PS.BIN", &out);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqualStrings("PS.BIN", out[0].slice());
}

test "shell: classify maps the builtin boundary" {
    try std.testing.expectEqual(Builtin.cd, classify("cd").?);
    try std.testing.expectEqual(Builtin.export_, classify("export").?);
    try std.testing.expectEqual(Builtin.true_, classify("true").?);
    try std.testing.expectEqual(Builtin.source, classify(".").?);
    try std.testing.expectEqual(Builtin.monitor_, classify("monitor").?);
    try std.testing.expect(classify("PS.BIN") == null);
    try std.testing.expect(classify("status43") == null);
}

fn execLine(s: *Shell, line: []const u8) Action {
    return s.execute(line, &.{});
}

// M73a-2 (#1631): tool args used to land in a fixed 64-byte Buf whose
// Buf.set silently truncates — `printf '<long format>'` was cut mid-frame
// on the live-term gate (observed: fmtlen=64, 47 of 73 output bytes).
// The copy buffer now matches `scratch`, so a full line's arg survives.
test "shell: tool args keep a long printf format intact" {
    var s = Shell.init();
    const fmt = "\\e[2J\\e[31mRED\\e[0m \\e[1;44;97mBOLD\\e[0m\\n\\e[93m" ++
        "\\xE2\\x94\\x8C\\xE2\\x94\\x80\\xE2\\x94\\x90\\xE2\\x94\\x82 pad pad pad";
    try std.testing.expect(fmt.len > 64); // the old guillotine, pinned
    var line: [line_max * 2]u8 = undefined;
    const cmd = std.fmt.bufPrint(&line, "printf '{s}'", .{fmt}) catch unreachable;
    const a = execLine(&s, cmd);
    try std.testing.expect(a == .tool);
    try std.testing.expectEqualStrings(fmt, a.tool.at(1));
}

test "shell: echo joins arguments and sets success" {
    var s = Shell.init();
    const a = execLine(&s, "echo hello world");
    try std.testing.expect(a == .print);
    try std.testing.expectEqualStrings("hello world\n", s.outSlice());
    try std.testing.expectEqual(@as(u8, 0), s.last_status);
}

test "shell: pwd/cd track the shell-local cwd" {
    var s = Shell.init();
    _ = execLine(&s, "cd /data");
    const a = execLine(&s, "pwd");
    try std.testing.expect(a == .print);
    try std.testing.expectEqualStrings("/data\n", s.outSlice());
    _ = execLine(&s, "cd ..");
    _ = execLine(&s, "pwd");
    try std.testing.expectEqualStrings("/\n", s.outSlice());
    // PWD is exported for children.
    try std.testing.expectEqualStrings("/", s.env.get("PWD").?);
}

test "shell: env/set/unset/export/printenv mutate and list" {
    var s = Shell.init();
    _ = execLine(&s, "set FOO=bar");
    try std.testing.expectEqualStrings("bar", s.env.get("FOO").?);
    _ = execLine(&s, "export BAZ=qux");
    try std.testing.expectEqualStrings("qux", s.env.get("BAZ").?);
    _ = execLine(&s, "env");
    const listed = s.outSlice();
    try std.testing.expect(std.mem.indexOf(u8, listed, "FOO=bar") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "BAZ=qux") != null);
    _ = execLine(&s, "unset FOO");
    try std.testing.expect(s.env.get("FOO") == null);
}

test "shell: alias stores, lists, expands and unaliases" {
    var s = Shell.init();
    _ = execLine(&s, "alias hi=echo hello");
    try std.testing.expectEqualStrings("alias: ok\n", s.outSlice());
    try std.testing.expectEqualStrings("echo hello", s.aliases.get("hi").?);
    // Command-position alias expansion.
    const b = execLine(&s, "hi world");
    try std.testing.expect(b == .print);
    try std.testing.expectEqualStrings("hello world\n", s.outSlice());
    _ = execLine(&s, "alias");
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "hi=echo hello") != null);
    _ = execLine(&s, "unalias hi");
    try std.testing.expect(s.aliases.get("hi") == null);
}

test "shell: true/false set the exit status and exit carries it" {
    var s = Shell.init();
    _ = execLine(&s, "false");
    try std.testing.expectEqual(@as(u8, 1), s.last_status);
    _ = execLine(&s, "true");
    try std.testing.expectEqual(@as(u8, 0), s.last_status);
    _ = execLine(&s, "false");
    const a = execLine(&s, "exit");
    try std.testing.expect(a == .exit);
    try std.testing.expectEqual(@as(u8, 1), a.exit);
    // `$?` sees the status.
    _ = execLine(&s, "echo $?");
    try std.testing.expectEqualStrings("1\n", s.outSlice());
}

test "shell: monitor is a distinct escape action (M49 SD1)" {
    var s = Shell.init();
    const a = execLine(&s, "monitor");
    try std.testing.expect(a == .monitor);
    try std.testing.expectEqual(@as(u8, 0), s.last_status);
    // It is advertised by help and offered by completion.
    _ = execLine(&s, "help");
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "monitor") != null);
    try std.testing.expect(classify("monitor") != null);
    try std.testing.expect(classify("mon") == null);
}

test "shell: tool verbs dispatch to the toolbox action (M49 SD3)" {
    var s = Shell.init();
    const a = execLine(&s, "wc -l FILE.TXT");
    try std.testing.expect(a == .tool);
    try std.testing.expectEqual(toolbox.Tool.wc, a.tool.tool);
    try std.testing.expectEqual(@as(usize, 3), a.tool.count);
    try std.testing.expectEqualStrings("wc", a.tool.at(0));
    try std.testing.expectEqualStrings("FILE.TXT", a.tool.at(2));
    // Tools are not plain builtins, but `type` reports them as builtins.
    try std.testing.expect(classify("wc") == null);
    _ = execLine(&s, "type wc");
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "shell builtin") != null);
    // `[` and `printf` route too.
    const b = execLine(&s, "printf %s hi");
    try std.testing.expect(b == .tool);
    try std.testing.expectEqual(toolbox.Tool.printf, b.tool.tool);
}

test "shell: read consumes the bound stdin line (M49 SD3)" {
    var s = Shell.init();
    s.setStdin("hello\nworld\n");
    const a = execLine(&s, "read FIRST");
    try std.testing.expect(a == .none);
    try std.testing.expectEqualStrings("hello", s.env.get("FIRST").?);
    _ = execLine(&s, "read SECOND");
    try std.testing.expectEqualStrings("world", s.env.get("SECOND").?);
    const b = execLine(&s, "read THIRD");
    try std.testing.expect(b == .print);
    try std.testing.expectEqual(@as(u8, 1), s.last_status);
}

test "shell: prompt/type/help report their builtin state" {
    var s = Shell.init();
    _ = execLine(&s, "prompt 'sh# '");
    try std.testing.expectEqualStrings("sh# ", s.promptSlice());
    _ = execLine(&s, "type cd");
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "shell builtin") != null);
    _ = execLine(&s, "help");
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "builtins:") != null);
}

const test_history_lines = [_][]const u8{ "second", "first" };

fn testHistoryCount(ctx: ?*anyopaque) usize {
    _ = ctx;
    return test_history_lines.len;
}

fn testHistoryEntry(ctx: ?*anyopaque, i: usize) ?[]const u8 {
    _ = ctx;
    if (i >= test_history_lines.len) return null;
    return test_history_lines[i];
}

test "shell: history reads the injected editor view newest-first" {
    var s = Shell.init();
    s.history = .{ .count_fn = testHistoryCount, .entry_fn = testHistoryEntry };
    _ = execLine(&s, "history");
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "second") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "first") != null);
}

test "shell: external command returns an ordered run request" {
    var s = Shell.init();
    const a = execLine(&s, "status43");
    try std.testing.expect(a == .run);
    try std.testing.expectEqual(@as(usize, 6), a.run.count);
    try std.testing.expectEqualStrings("status43.BIN", a.run.at(0));
    try std.testing.expectEqualStrings("STATUS43.BIN", a.run.at(2));
}

test "shell: source returns the path to execute, jobs/fg are honest" {
    var s = Shell.init();
    const a = execLine(&s, "source /scripts/init.sh");
    try std.testing.expect(a == .source);
    try std.testing.expectEqualStrings("/scripts/init.sh", a.source.path.slice());
    _ = execLine(&s, "jobs");
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "no background jobs") != null);
}

test "shell: type consults the share listing when available" {
    var s = Shell.init();
    const listing = [_][]const u8{ "PS.BIN", "STATUS43.BIN" };
    const a = s.execute("type STATUS43.BIN", &listing);
    try std.testing.expect(a == .print);
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "(present)") != null);
    _ = s.execute("type NOPE.BIN", &listing);
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "(external)") != null);
}

test "shell: complete offers builtins, aliases and share apps (basenames stripped)" {
    var aliases = AliasTable{};
    _ = aliases.set("hello", "echo hi");
    var set: CompletionSet = undefined;
    // Command position: alias + builtins (the M49 tool verbs are offered
    // too), sorted.
    try std.testing.expectEqual(@as(usize, 3), complete("he", true, &aliases, null, &.{}, &set));
    try std.testing.expectEqualStrings("head", set.at(0));
    try std.testing.expectEqualStrings("hello", set.at(1));
    try std.testing.expectEqualStrings("help", set.at(2));
    // Share app: the full name and the extension-stripped basename.
    const listing = [_][]const u8{ "STATUS43.BIN", "PS.BIN" };
    try std.testing.expectEqual(@as(usize, 2), complete("stat", true, &aliases, null, &listing, &set));
    try std.testing.expectEqualStrings("STATUS43", set.at(0));
    try std.testing.expectEqualStrings("STATUS43.BIN", set.at(1));
    // Argument position: share files only (no builtins).
    try std.testing.expectEqual(@as(usize, 2), complete("ps", false, &aliases, null, &listing, &set));
    try std.testing.expectEqualStrings("PS", set.at(0));
    try std.testing.expectEqualStrings("PS.BIN", set.at(1));
    // No match and empty prefix yield nothing.
    try std.testing.expectEqual(@as(usize, 0), complete("zzz", true, &aliases, null, &listing, &set));
    try std.testing.expectEqual(@as(usize, 0), complete("", true, &aliases, null, &listing, &set));
}

test "shell: $VAR completion offers environment names (M49 SD4)" {
    var s = Shell.init();
    _ = execLine(&s, "export PATH=/data");
    var set: CompletionSet = undefined;
    const n = complete("$PA", true, &s.aliases, &s.env, &.{}, &set);
    try std.testing.expect(n >= 1);
    try std.testing.expectEqualStrings("$PATH", set.at(0));
    // `$?`-style non-names yield nothing.
    try std.testing.expectEqual(@as(usize, 0), complete("$?", true, &s.aliases, &s.env, &.{}, &set));
}

test "shell: set -o selects the editor keymap (M49 SD4)" {
    var s = Shell.init();
    const a = execLine(&s, "set -o vi");
    try std.testing.expect(a == .set_editor);
    try std.testing.expectEqual(EditorMode.vi, a.set_editor);
    try std.testing.expectEqual(EditorMode.vi, s.editor_mode);
    _ = execLine(&s, "set -o");
    try std.testing.expectEqualStrings("vi\n", s.outSlice());
    const b = execLine(&s, "set +o vi");
    try std.testing.expect(b == .set_editor);
    try std.testing.expectEqual(EditorMode.emacs, b.set_editor);
    try std.testing.expectEqual(EditorMode.emacs, s.editor_mode);
    const c = execLine(&s, "set -o bogus");
    try std.testing.expect(c == .print);
    try std.testing.expectEqual(@as(u8, 1), s.last_status);
}

test "shell: glob expansion sorts matches and passes unmatched literals through" {
    var s = Shell.init();
    const listing = [_][]const u8{ "STATUS43.BIN", "PS.BIN", "NOTES.TXT" };
    const a = s.execute("echo *.BIN", &listing);
    try std.testing.expect(a == .print);
    try std.testing.expectEqualStrings("PS.BIN STATUS43.BIN\n", s.outSlice());
    // No match -> literal (nullglob off).
    _ = s.execute("echo *.NOPE", &listing);
    try std.testing.expectEqualStrings("*.NOPE\n", s.outSlice());
    // Quoted and escaped wildcards stay literal.
    _ = s.execute("echo '*.BIN'", &listing);
    try std.testing.expectEqualStrings("*.BIN\n", s.outSlice());
    _ = s.execute("echo \\*.BIN", &listing);
    try std.testing.expectEqualStrings("*.BIN\n", s.outSlice());
}

test "shell: cat emits the bound stdin (pipe / redirect source)" {
    var s = Shell.init();
    s.setStdin("hello from stdin\n");
    const a = s.execute("cat", &.{});
    try std.testing.expect(a == .print);
    try std.testing.expectEqualStrings("hello from stdin\n", s.outSlice());
    // No input bound -> an honest message.
    s.setStdin(&.{});
    _ = s.execute("cat", &.{});
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "no input") != null);
}

test "shell: arithmetic expansion happens during execute" {
    var s = Shell.init();
    const a = s.execute("echo $(( (2+3)*4 ))", &.{});
    try std.testing.expect(a == .print);
    try std.testing.expectEqualStrings("20\n", s.outSlice());
    _ = s.execute("echo n=$((7-2))!", &.{});
    try std.testing.expectEqualStrings("n=5!\n", s.outSlice());
}

test "shell: fn define + call binds named and positional args" {
    var s = Shell.init();
    try std.testing.expect(Shell.isFuncDef("fn greet(name) { echo HELLO-$name }"));
    try std.testing.expect(s.defineFuncLine("fn greet(name) { echo HELLO-$name }"));
    const a = s.execute("greet world", &.{});
    try std.testing.expect(a == .call);
    const idx = a.call;
    const f = &s.funcs.funcs[idx];
    try std.testing.expectEqual(@as(usize, 1), f.body_count);
    // The glue runs the body command; here we do it directly.
    const b = s.execute(f.command(0), &.{});
    try std.testing.expect(b == .print);
    try std.testing.expectEqualStrings("HELLO-world\n", s.outSlice());
    // Positional $1 is also bound.
    _ = s.execute("echo arg=$1", &.{});
    try std.testing.expectEqualStrings("arg=world\n", s.outSlice());
    // A non-definition line is not a function definition.
    try std.testing.expect(!Shell.isFuncDef("find /"));
}

test "shell: break/continue set the loop signals" {
    var s = Shell.init();
    s.clearLoopFlags();
    _ = s.execute("break", &.{});
    try std.testing.expect(s.loop_break);
    s.clearLoopFlags();
    _ = s.execute("continue", &.{});
    try std.testing.expect(s.loop_continue);
    try std.testing.expect(!s.loop_break);
    s.clearLoopFlags();
    try std.testing.expect(!s.loop_break and !s.loop_continue);
}

fn testPrincipalGet(ctx: ?*anyopaque) ?Principal {
    const p: *const Principal = @ptrCast(@alignCast(ctx.?));
    return p.*;
}

test "shell: whoami/id render the principal from the view (M50 TS1)" {
    var s = Shell.init();
    var p = Principal{ .uid = uid_user, .caps = 0 };
    s.principal = .{ .ctx = &p, .get_fn = testPrincipalGet };
    _ = s.execute("whoami", &.{});
    try std.testing.expectEqualStrings("uid=1000 user\n", s.outSlice());
    _ = s.execute("id", &.{});
    try std.testing.expectEqualStrings("uid=1000 user caps=0\n", s.outSlice());
    // A kernel principal renders as `system`, not `user`.
    p = .{ .uid = uid_system, .caps = 3 };
    _ = s.execute("whoami", &.{});
    try std.testing.expectEqualStrings("uid=0 system\n", s.outSlice());
    _ = s.execute("id", &.{});
    try std.testing.expectEqualStrings("uid=0 system caps=3\n", s.outSlice());
    // No principal view wired: an honest refusal, never a fabricated identity.
    var bare = Shell.init();
    _ = bare.execute("whoami", &.{});
    try std.testing.expectEqualStrings("whoami: no principal\n", bare.outSlice());
    // `type` recognizes the new builtins.
    try std.testing.expectEqual(Builtin.whoami, classify("whoami").?);
    try std.testing.expectEqual(Builtin.id_, classify("id").?);
}

const ModeProbe = struct {
    path: [64]u8 = @as([64]u8, @splat(@as(u8, 0))),
    len: usize = 0,
    mode: u16 = 0,
    rc: i64 = 0,
    calls: usize = 0,
};

fn testModeSet(ctx: ?*anyopaque, path: []const u8, mode: u16) i64 {
    const p: *ModeProbe = @ptrCast(@alignCast(ctx.?));
    p.calls += 1;
    const n = @min(path.len, p.path.len);
    @memcpy(p.path[0..n], path[0..n]);
    p.len = n;
    p.mode = mode;
    return p.rc;
}

test "shell: chmod parses octal and renders the kernel verdict (M50 TS2)" {
    var s = Shell.init();
    var probe = ModeProbe{};
    s.mode_view = .{ .ctx = &probe, .set_fn = testModeSet };

    _ = s.execute("chmod 600 PLAIN.TXT", &.{});
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqualStrings("PLAIN.TXT", probe.path[0..probe.len]);
    try std.testing.expectEqual(@as(u16, 0o600), probe.mode);
    try std.testing.expectEqualStrings("chmod: ok\n", s.outSlice());

    // A kernel denial renders the EACCES mnemonic (the class-B assertion).
    probe.rc = -7;
    _ = s.execute("chmod 600 TARGET.TXT", &.{});
    try std.testing.expectEqualStrings("chmod: TARGET.TXT: EACCES\n", s.outSlice());

    // A bad mode is refused before any syscall.
    probe.rc = 0;
    const before = probe.calls;
    _ = s.execute("chmod 999 TARGET.TXT", &.{});
    try std.testing.expectEqual(before, probe.calls);
    try std.testing.expectEqualStrings("chmod: invalid mode (use octal, e.g. 600)\n", s.outSlice());

    // Missing argument -> usage.
    _ = s.execute("chmod 600", &.{});
    try std.testing.expectEqualStrings("chmod: usage: chmod MODE FILE\n", s.outSlice());

    // Classification + pure parsers.
    try std.testing.expectEqual(Builtin.chmod, classify("chmod").?);
    try std.testing.expectEqualStrings("EACCES", errnoName(-7));
    try std.testing.expectEqual(@as(?u16, 0o644), parseOctMode("644"));
    try std.testing.expectEqual(@as(?u16, 0o600), parseOctMode("0600"));
    try std.testing.expect(parseOctMode("8") == null);
    try std.testing.expect(parseOctMode("") == null);
}

const SecretProbe = struct {
    names: [4][32]u8 = undefined,
    lens: [4]usize = @as([4]usize, @splat(@as(usize, 0))),
    count: usize = 0,
    ok: bool = true,
};

fn testSecretList(ctx: ?*anyopaque, out: *SecretList) bool {
    const p: *SecretProbe = @ptrCast(@alignCast(ctx.?));
    if (!p.ok) return false;
    var i: usize = 0;
    while (i < p.count and i < out.names.len) : (i += 1) {
        const n = @min(p.lens[i], out.names[i].len);
        @memcpy(out.names[i][0..n], p.names[i][0..n]);
        out.lens[i] = n;
    }
    out.count = p.count;
    return true;
}

test "shell: secrets lists NAMES only from the view (M50 TS5)" {
    var s = Shell.init();
    var probe = SecretProbe{};
    probe.count = 2;
    @memcpy(probe.names[0][0..6], "netkey");
    probe.lens[0] = 6;
    @memcpy(probe.names[1][0..6], "audkey");
    probe.lens[1] = 6;
    s.secret_view = .{ .ctx = &probe, .list_fn = testSecretList };

    _ = s.execute("secrets", &.{});
    try std.testing.expectEqualStrings("  netkey\n  audkey\n", s.outSlice());

    // No entries: an honest `(none)`.
    probe.count = 0;
    _ = s.execute("secrets", &.{});
    try std.testing.expectEqualStrings("secrets: (none)\n", s.outSlice());

    // No view wired: an honest refusal, never a fabricated listing.
    var bare = Shell.init();
    _ = bare.execute("secrets", &.{});
    try std.testing.expectEqualStrings("secrets: unavailable\n", bare.outSlice());

    // Classification + completion name registration.
    try std.testing.expectEqual(Builtin.secrets, classify("secrets").?);
}
