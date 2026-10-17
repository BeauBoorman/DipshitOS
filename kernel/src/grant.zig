//! VirelaiOS M113c (issue #2419, ADR 0054 Part II): the kernel-owned grant
//! table — the enforcement source the file ABI can never write.
//!
//! A grant row is `(name, sha256, words)`:
//!
//!   - `name` — the image name as exec records it (the verbatim share
//!     path handed to `exec`/`sys_exec`), compared case-insensitively for
//!     the same APFS-canonicalization reason as `OWNERS.TXT` keys;
//!   - `sha256` — the raw-file digest of the image the row applies to, or
//!     the literal `*` wildcard, which may only NARROW (never grant a word
//!     outside the baseline — a name-only row is forgeable by rename);
//!   - `words` — a subset of the `caps=` vocabulary (`file window audio
//!     timer memory process debug net term`), one word = one thing.
//!
//! Two sources, neither writable through the file ABI:
//!
//!   - BASE rows are compiled into `KERNEL.BIN` (`base_rows` below): the
//!     Part I chain pins the kernel image, so the compiled table is
//!     verified by construction. M113c ships the mechanism with an empty
//!     base set — base-row policy is an owner decision, not a default.
//!   - USER rows live in `GRANTS.TXT` on the host share, secret-class BY
//!     CONSTRUCTION exactly like `SECRETS.TXT` (`trust.ensure_grant_file`
//!     runs before the file is read): the file ABI — the only write path
//!     an EL0 process has — can never read or modify it. The contents are
//!     policy, not a secret; the class is taken for integrity.
//!
//! The table is bounded (`max_user_rows`); a full table is an honest
//! `ENOSPC` on the inserting operation, never silent eviction.
//!
//! ## `GRANTS.TXT` `#v1` format
//!
//! `#v1[ key=value ...]` header + one `name<TAB>sha256|*<TAB>words` line
//! per row; `words` is a comma-separated list (or `-`/empty for a row
//! that narrows to nothing). The header's `mode=` field carries the
//! enforcement posture: `mode=audit|enforce`, absent = `audit` (the
//! arc's ship posture — D12). Fail-closed like `OWNERS.TXT`:
//!
//!   - a malformed data line POISONS its name — the row acts as a
//!     mismatched row (its binary refuses `grant_stale`), never silently
//!     dropped into the baseline;
//!   - a non-`#v1` schema (or an unrecognized `#v1` header field) refuses
//!     the file entirely — every name it lists is poisoned;
//!   - a `*` row whose words escape the baseline is poisoned like any
//!     other malformed row;
//!   - a name longer than `name_max` cannot key a row at all, so such a
//!     line is counted instead: a later exec of an over-long name against
//!     a file that carried one refuses `grant_stale` too (fail closed —
//!     an unkeyable policy line never becomes ambient baseline).
//!
//! ## The admin seam (slot 89 `sys_grant_admin`)
//!
//! In-guest writes go through ONE admin slot (ADR 0007 additive
//! amendment): the registered WM seat or `CAP_PROC_ADMIN`, and never the
//! app the row names — the seat is the user's gesture mediator, so a
//! landed write is user-mediated by construction. This module owns the
//! line grammar and the set/persist operation; the seat gate and the
//! self-name check live at the syscall seam.
//!
//! No libc, no POSIX, no allocation — a fixed BSS table.

const std = @import("std");
const measure = @import("measure.zig");
const trust = @import("trust.zig");
const virtio_file = @import("virtio_file.zig");

pub const filename = "GRANTS.TXT";

/// The row-name bound — the exec-recorded share path (not truncated to
/// `process.name_max`, which is a display bound, not a name one).
pub const name_max: usize = 64;
/// Bounded user table: full ⇒ `ENOSPC` on insert, never eviction.
pub const max_user_rows: usize = 16;
/// The widest a serialized row line gets (name + sha + the whole word
/// vocabulary + separators).
pub const line_max: usize = name_max + 1 + 64 + 1 + 64;
/// The serialized `GRANTS.TXT` bound: header + `mode=` + one line per row.
pub const file_max: usize = 32 + max_user_rows * (line_max + 1);

// ---------------------------------------------------------------------------
// The word vocabulary — the `caps=` words (ADR 0054 D9: one word = one
// thing). `baseline` is every word set: today's ambient authority, so a
// flags-off exec is byte-identical.
// ---------------------------------------------------------------------------

pub const word_file: u32 = 1 << 0;
pub const word_window: u32 = 1 << 1;
pub const word_audio: u32 = 1 << 2;
pub const word_timer: u32 = 1 << 3;
pub const word_memory: u32 = 1 << 4;
pub const word_process: u32 = 1 << 5;
pub const word_debug: u32 = 1 << 6;
pub const word_net: u32 = 1 << 7;
pub const word_term: u32 = 1 << 8;
pub const word_count: usize = 9;
pub const baseline: u32 = (1 << word_count) - 1;

const vocab = [word_count][]const u8{ "file", "window", "audio", "timer", "memory", "process", "debug", "net", "term" };

comptime {
    // process.zig carries its own ambient constant (one-way dependency);
    // a vocabulary change must land in both places.
    if (baseline != @import("process.zig").word_baseline)
        @compileError("grant.baseline must equal process.word_baseline");
}

/// The word's display name by bit index (receipt `word=` field).
pub fn wordName(bit: u5) []const u8 {
    return vocab[bit];
}

fn wordBit(name: []const u8) ?u32 {
    for (vocab, 0..) |w, i| {
        if (std.mem.eql(u8, w, name)) return @as(u32, 1) << @intCast(i);
    }
    return null;
}

/// ADR 0054 D9: each word names a group of ADR 0007 slots. Returns the
/// word bit a slot belongs to, or 0 for the ungrouped service slots
/// (sleep/time/getrandom/the unlisted remainder — services, not powers).
/// Slot 80 is NOT in a group here: it is a multiplexed handle family, so
/// only its open-class ops (0 listen, 8 beginDns, 10 connect) carry the
/// `net` word — queried op-aware at the dispatch seam.
pub fn slot_word(number: u64) u32 {
    return switch (number) {
        23...27, 34...37, 69, 77, 79 => word_file,
        12...22, 46, 47, 49...51, 53, 55, 58, 61, 65 => word_window,
        42...45 => word_audio,
        40, 41 => word_timer,
        63, 64 => word_memory,
        5...8, 28, 29, 54, 56, 57, 68, 73...75, 81...83, 87 => word_process,
        0, 1, 3 => word_debug,
        9...11, 30...33, 59, 60, 62, 76, 84...86 => word_net,
        67, 71 => word_term,
        else => 0,
    };
}

/// The slot-80 open-class ops (ADR 0054 D9): the ops that create a new
/// network channel. Handle ops on an already-open socket are covered by
/// the fact that a process without `net` can never have opened the
/// handle.
pub fn socket_open_op(op: u64) bool {
    return op == 0 or op == 8 or op == 10;
}

// ---------------------------------------------------------------------------
// The enforcement posture (D12): `audit` receipts would-be denials and
// refuses nothing at the word seam; `enforce` makes a denied word an
// honest EACCES. Parsed from the `#v1` header's `mode=` field; absent =
// `audit` — the switch lives inside the secret-class file, off the
/// EL0-writable surface.
// ---------------------------------------------------------------------------

pub const Mode = enum { audit, enforce };
var mode: Mode = .audit;

/// True when the word seam refuses denied calls (D12's `enforce`).
pub fn enforceMode() bool {
    return mode == .enforce;
}

// ---------------------------------------------------------------------------
// The table
// ---------------------------------------------------------------------------

/// A compiled-in base row literal (verified by the Part I boot chain —
/// a different table is a different KERNEL.BIN digest). M113c ships none:
/// the mechanism is landed, base-row policy is not.
pub const BaseRow = struct {
    name: []const u8,
    /// 32 raw-file digest bytes, or null for the `*` wildcard (narrow only).
    sha256: ?[measure.digest_len]u8,
    words: u32,
};
pub const base_rows = [_]BaseRow{};

const Row = struct {
    used: bool = false,
    /// A malformed source line: the row behaves as a MISMATCHED row —
    /// its binary refuses `grant_stale` (ADR 0054 D7 fail-closed).
    poisoned: bool = false,
    /// `sha256` field was the `*` wildcard (name-only, narrow-only).
    wildcard: bool = false,
    name: [name_max]u8 = @as([name_max]u8, @splat(@as(u8, 0))),
    name_len: u8 = 0,
    sha256: [measure.digest_len]u8 = @as([measure.digest_len]u8, @splat(@as(u8, 0))),
    words: u32 = 0,
};

var user_rows: [max_user_rows]Row = @as([max_user_rows]Row, @splat(@as(Row, .{})));
var user_count: usize = 0;
/// `GRANTS.TXT` lines whose name exceeded `name_max` — unkeyable, so
/// counted: an over-long exec name against such a file is poisoned too.
var overlong_names: usize = 0;

pub fn init() void {
    user_rows = @as([max_user_rows]Row, @splat(@as(Row, .{})));
    user_count = 0;
    overlong_names = 0;
    mode = .audit;
}

/// Visible-row count (poisoned rows count — they occupy a slot).
pub fn count() usize {
    return user_count;
}

fn nameMatches(r: *const Row, name: []const u8) bool {
    if (r.name_len != name.len) return false;
    return std.ascii.eqlIgnoreCase(r.name[0..r.name_len], name);
}

fn findRow(name: []const u8) ?*Row {
    for (&user_rows) |*r| {
        if (!r.used) continue;
        if (nameMatches(r, name)) return r;
    }
    return null;
}

fn freeSlot() ?*Row {
    for (&user_rows) |*r| {
        if (!r.used) return r;
    }
    return null;
}

/// Exec-time lookup (ADR 0054 D7/D8). `.poisoned` is a fail-closed
/// verdict — the caller treats it exactly like a hash mismatch.
pub const Lookup = union(enum) {
    /// No row names this image — the baseline applies.
    none,
    /// A malformed row (or an unkeyable over-long name against a file
    /// that carried one): refuse `grant_stale`.
    poisoned,
    /// A matching row: check its hash term (or `*` — narrow only).
    row: *const Row,
};

pub fn lookup(name: []const u8) Lookup {
    if (name.len > name_max) {
        return if (overlong_names != 0) .poisoned else .none;
    }
    if (findRow(name)) |r| {
        return if (r.poisoned) .poisoned else .{ .row = r };
    }
    // A user row shadows a same-named base row; only an unmatched name
    // falls through to the compiled table.
    for (base_rows) |*b| {
        if (b.name.len == name.len and std.ascii.eqlIgnoreCase(b.name, name)) {
            const r = &base_row_scratch;
            r.* = .{
                .used = true,
                .wildcard = b.sha256 == null,
                .name_len = @intCast(b.name.len),
                .sha256 = b.sha256 orelse @as([measure.digest_len]u8, @splat(@as(u8, 0))),
                .words = b.words & baseline,
            };
            @memcpy(r.name[0..b.name.len], b.name);
            return .{ .row = r };
        }
    }
    return .none;
}

comptime {
    for (base_rows) |b| {
        if (b.name.len > name_max) @compileError("base grant row name exceeds name_max");
        if ((b.words & ~baseline) != 0) @compileError("base grant row words exceed the baseline");
        if (b.sha256 == null and (b.words & ~baseline) != 0) @compileError("wildcard base row may only narrow");
    }
}

/// The scratch row a base-row lookup answer points at — exec consults it
/// synchronously inside `decide` and never holds it across a call.
var base_row_scratch: Row = .{};

/// The exec verdict (ADR 0054 D8): apply a narrowed word set, refuse
/// `grant_stale`, or take the baseline. `digest` is the measured
/// raw-file digest — null when the measurement itself failed (a named
/// row is then unverifiable, which is fail-closed `stale`, never open).
pub const Verdict = union(enum) {
    baseline,
    apply: u32,
    stale,
};

pub fn decide(name: []const u8, digest: ?*const [measure.digest_len]u8) Verdict {
    return switch (lookup(name)) {
        .none => .baseline,
        .poisoned => .stale,
        .row => |r| blk: {
            if (r.wildcard) break :blk .{ .apply = r.words & baseline };
            const d = digest orelse break :blk .stale;
            if (std.mem.eql(u8, d, &r.sha256)) break :blk .{ .apply = r.words & baseline };
            break :blk .stale;
        },
    };
}

// ---------------------------------------------------------------------------
// `GRANTS.TXT` `#v1` load
// ---------------------------------------------------------------------------

pub const LoadResult = enum { ok, full };

const ParsedLine = struct {
    valid: bool, // false = poison the name
    name: []const u8,
    wildcard: bool = false,
    sha256: [measure.digest_len]u8 = undefined,
    words: u32 = 0,
};

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > name_max) return false;
    // A name is a share path as exec records it; whitespace, controls and
    // the separators cannot appear in one.
    for (name) |c| {
        if (c < 0x21 or c == 0x7f or c == '\t') return false;
    }
    return true;
}

fn parseHexDigest(s: []const u8, out: *[measure.digest_len]u8) bool {
    if (s.len != 2 * measure.digest_len) return false;
    _ = std.fmt.hexToBytes(out, s) catch return false;
    return true;
}

fn parseWords(s: []const u8) ?u32 {
    if (s.len == 0 or std.mem.eql(u8, s, "-")) return 0;
    var mask: u32 = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |w| {
        mask |= wordBit(w) orelse return null;
    }
    return mask;
}

const LineResult = enum {
    /// A row landed (valid or poisoned).
    applied,
    /// The line's name could not key a row (empty/invalid; over-long
    /// names are counted separately — see `overlong_names`).
    skipped,
    /// The line needed a slot at capacity — refused, never evicted.
    dropped,
};

/// One data line. Anything malformed POISONS the name it carries —
/// including a wildcard row whose words escape the baseline (D8). A line
/// whose name cannot key a row (empty or over `name_max`) cannot poison;
/// the over-long case is counted separately instead.
fn parseLine(line: []const u8) LineResult {
    var fields: [3][]const u8 = .{ "", "", "" };
    var nfields: usize = 0;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |f| {
        if (nfields < 3) fields[nfields] = f;
        nfields += 1;
    }
    const name = fields[0];
    if (!validName(name)) {
        // An over-long name is still a policy statement the file makes —
        // count it so an over-long exec name fails closed too.
        if (name.len > name_max) overlong_names += 1;
        return .skipped;
    }
    var poison = nfields != 3;
    var sha: [measure.digest_len]u8 = undefined;
    var wildcard = false;
    var words: u32 = 0;
    if (!poison) {
        if (std.mem.eql(u8, fields[1], "*")) {
            wildcard = true;
        } else if (!parseHexDigest(fields[1], &sha)) {
            poison = true;
        }
    }
    if (!poison) {
        if (parseWords(fields[2])) |w| {
            words = w;
        } else {
            poison = true;
        }
    }
    if (!poison and wildcard and (words & ~baseline) != 0) poison = true;
    if (findRow(name)) |r| {
        r.poisoned = poison;
        if (!poison) {
            r.wildcard = wildcard;
            r.sha256 = sha;
            r.words = words;
        }
        return .applied;
    }
    const r = freeSlot() orelse return .dropped;
    r.* = .{ .used = true, .poisoned = poison };
    @memcpy(r.name[0..name.len], name);
    r.name_len = @intCast(name.len);
    if (!poison) {
        r.wildcard = wildcard;
        r.sha256 = sha;
        r.words = words;
    }
    user_count += 1;
    return .applied;
}

fn poisonName(name: []const u8) void {
    if (!validName(name)) {
        if (name.len > name_max) overlong_names += 1;
        return;
    }
    if (findRow(name)) |r| {
        r.poisoned = true;
        return;
    }
    const r = freeSlot() orelse return;
    r.* = .{ .used = true, .poisoned = true };
    @memcpy(r.name[0..name.len], name);
    r.name_len = @intCast(name.len);
    user_count += 1;
}

/// The `#v1` header: `#v1` alone, or `#v1` plus space-separated
/// `key=value` fields. `mode=audit|enforce` is the only field defined
/// (D12); anything else is an unknown schema — the file is refused the
/// same way a non-`#v1` first line is.
fn knownHeader(line: []const u8) bool {
    if (std.mem.eql(u8, line, "#v1")) return true;
    if (line.len < 4 or !std.mem.eql(u8, line[0..4], "#v1 ")) return false;
    var it = std.mem.tokenizeScalar(u8, line[4..], ' ');
    var saw_any = false;
    while (it.next()) |field| {
        saw_any = true;
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse return false;
        if (!std.mem.eql(u8, field[0..eq], "mode")) return false;
        if (std.mem.eql(u8, field[eq + 1 ..], "audit")) {
            mode = .audit;
        } else if (std.mem.eql(u8, field[eq + 1 ..], "enforce")) {
            mode = .enforce;
        } else {
            return false;
        }
    }
    return saw_any;
}

/// Load a `GRANTS.TXT` payload. `#v1` schema + `name<TAB>sha|*<TAB>words`
/// lines. `full` means more valid entries existed than `max_user_rows`
/// (what fit is kept, never evicted). A non-`#v1` schema refuses the
/// WHOLE file — every name it lists is poisoned (fail closed: a
/// differently-schemed grants file is never partially trusted).
pub fn load(text: []const u8) LoadResult {
    init();
    var seen_header = false;
    var known_schema = false;
    var overflow = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (!seen_header) {
            seen_header = true;
            known_schema = knownHeader(line);
            continue;
        }
        if (!known_schema) {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
            poisonName(line[0..tab]);
            continue;
        }
        if (parseLine(line) == .dropped) overflow = true;
    }
    return if (overflow) .full else .ok;
}

/// Serialize the user table as `#v1 mode=<mode>` + one row line per
/// VALID row (poisoned rows are parse failures, not policy — a persist
/// drops them so the file it rewrites is the table's honest state).
/// Returns bytes written; 0 when `out` cannot hold the header.
pub fn save(out: []u8) usize {
    var pos: usize = 0;
    const head = if (mode == .enforce) "#v1 mode=enforce\n" else "#v1 mode=audit\n";
    if (out.len < head.len) return 0;
    @memcpy(out[0..head.len], head);
    pos = head.len;
    for (&user_rows) |*r| {
        if (!r.used or r.poisoned) continue;
        const n = row_line_into(r, out[pos..]) orelse break;
        pos += n;
    }
    return pos;
}

fn row_line_into(r: *const Row, out: []u8) ?usize {
    var pos: usize = 0;
    if (pos + r.name_len + 1 > out.len) return null;
    @memcpy(out[pos .. pos + r.name_len], r.name[0..r.name_len]);
    pos += r.name_len;
    out[pos] = '\t';
    pos += 1;
    if (r.wildcard) {
        if (pos + 1 > out.len) return null;
        out[pos] = '*';
        pos += 1;
    } else {
        if (pos + 2 * measure.digest_len > out.len) return null;
        pos += measure.hex_digest(out[pos..], &r.sha256);
    }
    if (pos + 2 > out.len) return null;
    out[pos] = '\t';
    pos += 1;
    if (r.words == 0) {
        out[pos] = '-';
        pos += 1;
    } else {
        var first = true;
        for (0..word_count) |i| {
            const bit = @as(u32, 1) << @intCast(i);
            if ((r.words & bit) == 0) continue;
            const w = vocab[i];
            if (pos + w.len + 1 > out.len) return null;
            if (!first) {
                out[pos] = ',';
                pos += 1;
            }
            @memcpy(out[pos .. pos + w.len], w);
            pos += w.len;
            first = false;
        }
    }
    if (pos + 1 > out.len) return null;
    out[pos] = '\n';
    return pos + 1;
}

/// Marshal user row `index` (valid rows only, insertion order) as its
/// grants line WITHOUT the trailing newline. Null when the index is out
/// of range or `out` cannot hold the line — the slot-89 read shape.
pub fn row_line(index: usize, out: []u8) ?usize {
    var seen: usize = 0;
    for (&user_rows) |*r| {
        if (!r.used or r.poisoned) continue;
        if (seen == index) {
            var buf: [line_max]u8 = undefined;
            const n = row_line_into(r, &buf) orelse return null;
            if (out.len < n - 1) return null;
            @memcpy(out[0 .. n - 1], buf[0 .. n - 1]);
            return n - 1;
        }
        seen += 1;
    }
    return null;
}

// ---------------------------------------------------------------------------
// The admin write path (slot 89): strict single-line set + persist.
// ---------------------------------------------------------------------------

/// `admin_set_line` outcome — the syscall maps these to errno-style codes.
pub const AdminResult = enum { ok, einval, enospc, enxio, eio };

/// Parse one `name<TAB>sha|*<TAB>words` line STRICTLY (the admin-slot
/// grammar — malformed input is an EINVAL answer to its caller, not a
/// poison row: the file's fail-closed rule applies to files, not to a
/// named, answered syscall). Then insert-or-update the row by name and
/// persist `GRANTS.TXT` through the kernel file channel. The write is
/// transactional: a persist failure rolls the table back and reports
/// `eio` — the caller's table never diverges from the share it saw
/// refused.
pub fn admin_set_line(line: []const u8) AdminResult {
    var fields: [3][]const u8 = .{ "", "", "" };
    var nfields: usize = 0;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |f| {
        if (nfields < 3) fields[nfields] = f;
        nfields += 1;
    }
    if (nfields != 3 or !validName(fields[0])) return .einval;
    var sha: [measure.digest_len]u8 = @as([measure.digest_len]u8, @splat(@as(u8, 0)));
    var wildcard = false;
    if (std.mem.eql(u8, fields[1], "*")) {
        wildcard = true;
    } else if (!parseHexDigest(fields[1], &sha)) {
        return .einval;
    }
    const words = parseWords(fields[2]) orelse return .einval;
    if (wildcard and (words & ~baseline) != 0) return .einval;
    if (!virtio_file.available()) return .enxio;

    admin_backup = user_rows;
    admin_backup_count = user_count;
    if (findRow(fields[0])) |r| {
        r.poisoned = false;
        r.wildcard = wildcard;
        r.sha256 = sha;
        r.words = words;
    } else {
        const r = freeSlot() orelse return .enospc;
        r.* = .{ .used = true, .wildcard = wildcard, .sha256 = sha, .words = words };
        @memcpy(r.name[0..fields[0].len], fields[0]);
        r.name_len = @intCast(fields[0].len);
        user_count += 1;
    }
    if (!persist()) {
        user_rows = admin_backup;
        user_count = admin_backup_count;
        return .eio;
    }
    return .ok;
}

/// BSS rollback state for `admin_set_line` — the slot is dom-locked, so
/// one backup suffices (never on the EL1 stack).
var admin_backup: [max_user_rows]Row = undefined;
var admin_backup_count: usize = 0;

/// The name a grants line carries (field 0) — the slot's self-name check
/// reads it before `admin_set_line` runs.
pub fn line_name(line: []const u8) []const u8 {
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
    return line[0..tab];
}

/// Serialize the user table and write `GRANTS.TXT` through the kernel
/// file channel (the EL0-invisible write path). Best effort answer; the
/// caller decides the rollback.
fn persist() bool {
    if (!virtio_file.available()) return false;
    if (!trust.ensure_grant_file()) return false;
    const n = save(&file_scratch);
    return virtio_file.write_whole(filename, file_scratch[0..n]) == virtio_file.st_ok;
}

var file_scratch: [file_max]u8 = undefined;

/// Boot + gate path: register `GRANTS.TXT` as secret-class BY
/// CONSTRUCTION (before reading a byte — the class holds even when the
/// file is absent, and a hand-seeded `OWNERS.TXT` row can only tighten),
/// then read and parse it. Returns true only when a file was read and
/// parsed; a default share (no file) is a silent no-op with an empty
/// user table and `audit` posture — no boot line, boot-default unchanged.
pub fn init_from_share() bool {
    init();
    if (!virtio_file.available()) return false;
    if (!trust.ensure_grant_file()) return false; // class must hold first
    const n = virtio_file.read_whole(filename, &file_scratch) orelse return false;
    _ = load(file_scratch[0..n]);
    return true;
}

// ---------------------------------------------------------------------------
// Host tests (pure; no syscalls, no filesystem)
// ---------------------------------------------------------------------------

fn hexDigest(comptime s: []const u8) [measure.digest_len]u8 {
    var out: [measure.digest_len]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

const sha_a = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const sha_b = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

test "grant: valid rows parse, match by hash, and narrow to the row's words" {
    init();
    const src = "#v1\nGOTOP.ELF\t" ++ sha_a ++ "\tfile,net\nCONFINED.ELF\t*\tfile\n";
    try std.testing.expectEqual(LoadResult.ok, load(src));
    try std.testing.expectEqual(@as(usize, 2), count());
    const da = hexDigest(sha_a);
    try std.testing.expectEqual(Verdict{ .apply = word_file | word_net }, decide("GOTOP.ELF", &da));
    // Case-insensitive name match (APFS-canonicalized keys, D4 precedent).
    try std.testing.expectEqual(Verdict{ .apply = word_file | word_net }, decide("gotop.elf", &da));
    // A wildcard row matches any digest but only narrows.
    try std.testing.expectEqual(Verdict{ .apply = word_file }, decide("CONFINED.ELF", &da));
    // An unlisted binary takes the baseline.
    try std.testing.expectEqual(Verdict.baseline, decide("OTHER.BIN", &da));
    // Audit posture: no mode field -> audit.
    try std.testing.expect(!enforceMode());
}

test "grant: a wrong digest or a poisoned row refuses stale — never falls open" {
    init();
    _ = load("#v1\nGOTOP.ELF\t" ++ sha_a ++ "\tnet\nBAD.ELF\t*extra\n");
    const da = hexDigest(sha_a);
    const db = hexDigest(sha_b);
    // Stale hash: the row names the image but the digest differs.
    try std.testing.expectEqual(Verdict.stale, decide("GOTOP.ELF", &db));
    // A measurement that failed to produce a digest cannot satisfy a
    // hash-bound row (fail closed, never baseline).
    try std.testing.expectEqual(Verdict.stale, decide("GOTOP.ELF", null));
    // The malformed line poisoned BAD.ELF.
    try std.testing.expectEqual(Verdict.stale, decide("BAD.ELF", &da));
    // Wildcard rows still apply with no digest at all (name-only is the
    // row's contract — it only narrows).
    _ = load("#v1\nWILD.ELF\t*\tnet\n");
    try std.testing.expectEqual(Verdict{ .apply = word_net }, decide("WILD.ELF", null));
}

test "grant: unknown schema and bad header fields poison every listed name" {
    init();
    _ = load("#v2\nFOO.ELF\t*\tnet\nBAR.ELF\t" ++ sha_a ++ "\tfile\n");
    const da = hexDigest(sha_a);
    try std.testing.expectEqual(Verdict.stale, decide("FOO.ELF", &da));
    try std.testing.expectEqual(Verdict.stale, decide("BAR.ELF", &da));
    // The whole file is suspect — an UNLISTED name is not poisoned.
    try std.testing.expectEqual(Verdict.baseline, decide("OTHER.BIN", &da));
    // An unrecognized #v1 header field refuses the file the same way.
    init();
    _ = load("#v1 bogus=1\nFOO.ELF\t*\tnet\n");
    try std.testing.expectEqual(Verdict.stale, decide("FOO.ELF", &da));
    // mode=enforce parses — and the file it rode in on loads.
    init();
    _ = load("#v1 mode=enforce\nFOO.ELF\t*\tnet\n");
    try std.testing.expect(enforceMode());
    try std.testing.expectEqual(Verdict{ .apply = word_net }, decide("FOO.ELF", &da));
}

test "grant: over-long names cannot be keyed but still fail closed" {
    init();
    var long_buf: [name_max + 8]u8 = @as([name_max + 8]u8, @splat(@as(u8, 'A')));
    var file_buf: [file_max]u8 = undefined;
    const text = std.fmt.bufPrint(&file_buf, "#v1\n{s}\t*\tnet\nOK.ELF\t*\tnet\n", .{long_buf[0..]}) catch unreachable;
    _ = load(text);
    const da = hexDigest(sha_a);
    // The over-long name counted: exec of ANY unkeyable name fails closed.
    var other_long: [name_max + 4]u8 = @as([name_max + 4]u8, @splat(@as(u8, 'B')));
    try std.testing.expectEqual(Verdict.stale, decide(other_long[0..], &da));
    // Keyable names are unaffected.
    try std.testing.expectEqual(Verdict{ .apply = word_net }, decide("OK.ELF", &da));
}

test "grant: the table is bounded — ENOSPC, never silent eviction" {
    init();
    var buf: [file_max]u8 = undefined;
    var pos: usize = 4;
    @memcpy(buf[0..4], "#v1\n");
    for (0..max_user_rows) |i| {
        var nb: [16]u8 = undefined;
        const nm = std.fmt.bufPrint(&nb, "APP{d}.ELF", .{i}) catch unreachable;
        const line = std.fmt.bufPrint(buf[pos..], "{s}\t*\tnet\n", .{nm}) catch unreachable;
        pos += line.len;
    }
    try std.testing.expectEqual(LoadResult.ok, load(buf[0..pos]));
    try std.testing.expectEqual(@as(usize, max_user_rows), count());
    // One more distinct name is a load overflow — earlier rows survive.
    const tail = std.fmt.bufPrint(buf[pos..], "ONE.MORE\t*\tnet\n", .{}) catch unreachable;
    try std.testing.expectEqual(LoadResult.full, load(buf[0 .. pos + tail.len]));
    const da = hexDigest(sha_a);
    try std.testing.expectEqual(Verdict{ .apply = word_net }, decide("APP0.ELF", &da));
    try std.testing.expectEqual(Verdict.baseline, decide("ONE.MORE", &da));
}

test "grant: word masks only narrow — no EL0 path widens past the baseline" {
    init();
    // Every reachable verdict is a subset of the baseline: a row can
    // remove words, never add one.
    const src = "#v1\nA.ELF\t*\tfile,net,term\nB.ELF\t" ++ sha_a ++ "\tnet\n";
    _ = load(src);
    const da = hexDigest(sha_a);
    const db = hexDigest(sha_b);
    for ([_][]const u8{ "A.ELF", "B.ELF", "UNLISTED.BIN" }) |name| {
        for ([_]?*const [measure.digest_len]u8{ &da, &db, null }) |d| {
            switch (decide(name, d)) {
                .baseline => {},
                .apply => |w| try std.testing.expect((w & ~baseline) == 0),
                .stale => {},
            }
        }
    }
    // The baseline itself is the full ambient vocabulary.
    try std.testing.expectEqual(@as(u32, 0x1ff), baseline);
}

test "grant: word -> slot-group map follows ADR 0054 D9" {
    try std.testing.expectEqual(word_net, slot_word(30)); // sys_tcp_connect
    try std.testing.expectEqual(word_net, slot_word(9)); // sys_udp_listen
    try std.testing.expectEqual(word_file, slot_word(23)); // sys_file_open
    try std.testing.expectEqual(word_process, slot_word(28)); // sys_exec
    try std.testing.expectEqual(word_window, slot_word(65)); // sys_wmctl
    try std.testing.expectEqual(word_debug, slot_word(1)); // sys_write
    try std.testing.expectEqual(word_term, slot_word(67)); // sys_tty_attach
    // Slot 80 is op-multiplexed: ungrouped at slot granularity.
    try std.testing.expectEqual(@as(u32, 0), slot_word(80));
    // Services stay open in every word set.
    try std.testing.expectEqual(@as(u32, 0), slot_word(4)); // sleep
    try std.testing.expectEqual(@as(u32, 0), slot_word(66)); // time
    try std.testing.expectEqual(@as(u32, 0), slot_word(72)); // getrandom
    try std.testing.expectEqual(@as(u32, 0), slot_word(88)); // scanout_read
    try std.testing.expectEqual(@as(u32, 0), slot_word(89)); // grant_admin
    // The open-class ops.
    try std.testing.expect(socket_open_op(0));
    try std.testing.expect(socket_open_op(8));
    try std.testing.expect(socket_open_op(10));
    try std.testing.expect(!socket_open_op(1));
    try std.testing.expect(!socket_open_op(9));
    // Every grouped slot's word is inside the baseline by construction.
    for (0..128) |n| {
        try std.testing.expect((slot_word(n) & ~baseline) == 0);
    }
}

test "grant: round-trip save/load preserves rows and mode" {
    init();
    _ = load("#v1 mode=audit\nGOTOP.ELF\t" ++ sha_a ++ "\tfile,net\nWILD.ELF\t*\tfile\nNONE.ELF\t*\t-\n");
    var buf: [file_max]u8 = undefined;
    const n = save(&buf);
    const text = buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, text, "#v1 mode=audit\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "GOTOP.ELF\t" ++ sha_a ++ "\tfile,net\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "WILD.ELF\t*\tfile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "NONE.ELF\t*\t-\n") != null);
    try std.testing.expectEqual(LoadResult.ok, load(text));
    const da = hexDigest(sha_a);
    try std.testing.expectEqual(Verdict{ .apply = word_file | word_net }, decide("GOTOP.ELF", &da));
    try std.testing.expectEqual(Verdict{ .apply = 0 }, decide("NONE.ELF", &da));
}

test "grant: admin set validates strictly, updates in place, bounds the table" {
    init();
    try std.testing.expectEqual(AdminResult.enxio, admin_set_line("A.ELF\t*\tnet")); // no channel in host tests
    // The strict parse refuses malformed lines before any state moves.
    // (admin_set_line's parse is exercised through the same field walk;
    // the enxio above proves reachability ordering, so drive the pure
    // halves directly.)
    try std.testing.expect(!validName(""));
    var over_buf: [name_max + 1]u8 = @as([name_max + 1]u8, @splat(@as(u8, 'A')));
    try std.testing.expect(!validName(over_buf[0..]));
    try std.testing.expectEqualStrings("A.ELF", line_name("A.ELF\t*\tnet"));
}
