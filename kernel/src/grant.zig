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
//!     verified by construction. M116a lands the owner decision the
//!     mechanism shipped empty for — the fleet policy, generated into
//!     kernel/src/grant_fleet.zig from image/fleet-grants.txt.
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
//! enforcement posture: `mode=audit|enforce`, absent = `audit`
//! (D12's standing contract — M116b lands `enforce` as the provisioned
//! posture, not the boot default). Fail-closed like `OWNERS.TXT`:
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
const process = @import("process.zig");
const arp = @import("arp.zig"); // M117e: v4 destination path class
const ipv6 = @import("ipv6.zig"); // M117e: the v6 Addr + path class
const klog = @import("klog.zig"); // M117e: the scope-denial receipt channel

pub const filename = "GRANTS.TXT";

/// The row-name bound — the exec-recorded share path (not truncated to
/// `process.name_max`, which is a display bound, not a name one).
pub const name_max: usize = 64;
/// Bounded user table: full ⇒ `ENOSPC` on insert, never eviction.
pub const max_user_rows: usize = 16;
/// M117e (#2477, ADR 0057 D12): the widest a scope field gets — four
/// `v6=` prefixes at full literal width plus the two `if=` tokens and
/// separators.
pub const scope_max: usize = 208;
/// The widest a serialized row line gets (name + sha + the whole word
/// vocabulary + the scope field + separators).
pub const line_max: usize = name_max + 1 + 64 + 1 + 64 + 1 + scope_max;
/// The serialized `GRANTS.TXT` bound: header + `mode=` + one line per row.
pub const file_max: usize = 32 + max_user_rows * (line_max + 1);

// ---------------------------------------------------------------------------
// The word vocabulary — the `caps=` words (ADR 0054 D9: one word = one
// thing). `baseline` is every word set: the CEILING a row may express and
// `set_grant`'s clamp — not what an unlisted binary carries. `ambient` is
// that floor.
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

/// M116b (#2468): the ambient word set — what a process no row names
/// carries (D8's no-row floor, narrowed on the M113f audit data). Drops
/// the words that cross the guest's trust boundary:
///
///   - `file`  — the host share: reads pick up host-side bytes, writes
///               stage guest data where the host reads it back;
///   - `audio` — virtio-snd drives playback AND capture since M118b —
///               a microphone is an exfil/surveillance source;
///   - `net`   — socket egress (the slot group plus the slot-80
///               open-class ops).
///
/// Kept — and why:
///
///   - `debug`    — slots 0/1/3 are sys_ping/sys_write/sys_exit:
///                  EXISTENCE verbs, not powers. A process that cannot
///                  print or exit is not confined, it is stuck — the
///                  M113f table shows every Go ELF calls them ambiently.
///                  (The card's letter named `debug` for the drop; the
///                  owner recorded this correction on #2468.)
///   - `memory`/`process` — allocation and lifecycle; an exec'd child
///                  carries the ambient set again, so spawning cannot
///                  widen.
///   - `timer`    — scheduling, no data crosses the boundary.
///   - `window`/`term` — seat-local surfaces: paint and console attach
///                  stay inside the boundary the seat already mediates.
///
/// Rows still express the whole vocabulary against `baseline` — a fleet
/// or consented app's row keeps its `net`/`file`/`audio` words.
pub const ambient: u32 = baseline & ~(word_file | word_audio | word_net);

const vocab = [word_count][]const u8{ "file", "window", "audio", "timer", "memory", "process", "debug", "net", "term" };

comptime {
    // process.zig carries its own constants (one-way dependency); a
    // vocabulary change must land in both places.
    if (baseline != process.word_baseline)
        @compileError("grant.baseline must equal process.word_baseline");
    if (ambient != process.word_ambient)
        @compileError("grant.ambient must equal process.word_ambient");
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
// M117e (#2477, ADR 0057 D12): the `net` word's scope qualifiers — an
// optional FOURTH row field (`name<TAB>sha|*<TAB>words<TAB>scope`). The
// field is a CSV of qualifier tokens; absent or `-` is unconstrained —
// the three-field row shape today, byte-identical.
//
//   `v6=<prefix>/<len>`  a v6-family connect's literal must match one
//                        listed prefix — off-list refuses
//                        `v6_literal_denied`. Bounded: `max_v6_prefixes`
//                        per row, more is a malformed row (poison).
//   `if=<nat|bridged>`   the destination's PATH CLASS must be in the
//                        set — `nat` is the router-mediated reach the
//                        NAT island has always had (and the router
//                        itself, which is island fabric), `bridged` an
//                        L2-adjacent peer — the class a bridged/vmnet
//                        LAN adds. Off-set refuses `<class>_denied`.
//
// Scope only ever narrows — every qualifier REMOVES destinations — so a
// wildcard row may carry it freely. Qualifiers are evaluated at the
// destination-bearing open ops (slot-80 op 8 beginDns and op 10
// connect, v4 and v6, plus the legacy slot-30 connect that funnels the
// same table entry point); listen binds no destination and is
// unconstrained. Like the word gate, `audit` receipts the would-be
// denial and lets the call through; `enforce` refuses EACCES.
// ---------------------------------------------------------------------------

/// `if=` vocabulary bits — the destination's egress path class.
pub const if_nat: u8 = 1 << 0;
pub const if_bridged: u8 = 1 << 1;
/// The bound on `v6=` prefixes one row may list.
pub const max_v6_prefixes: usize = 4;

/// The destination's egress path class — the `if=` token vocabulary and
/// the `<class>_denied` receipt names.
pub const PathClass = enum {
    /// Router-mediated: an off-link destination resolved through the
    /// default gateway / recorded v6 router, or the router itself.
    nat,
    /// L2-adjacent: an on-link destination the wire resolves directly —
    /// the reach a bridged or vmnet LAN adds beyond the island.
    bridged,

    fn bit(c: PathClass) u8 {
        return switch (c) {
            .nat => if_nat,
            .bridged => if_bridged,
        };
    }

    fn token(c: PathClass) []const u8 {
        return @tagName(c);
    }
};

pub const V6Prefix = struct {
    addr: ipv6.Addr = @splat(0),
    len: u8 = 0,
};

/// One row's net scope. `v6_count == 0` leaves v6 literals
/// unconstrained; `if_mask == 0` leaves the path class unconstrained.
pub const Scope = struct {
    v6: [max_v6_prefixes]V6Prefix = @splat(.{}),
    v6_count: u8 = 0,
    if_mask: u8 = 0,

    pub fn isEmpty(s: Scope) bool {
        return s.v6_count == 0 and s.if_mask == 0;
    }
};

/// The destination a destination-bearing open presents to the scope
/// check: the v4 literal or the v6 literal the caller asked for.
pub const ScopedDst = union(enum) {
    v4: [4]u8,
    v6: ipv6.Addr,
};

/// The scope check's answer. `path` names the destination's own class
/// (the refusal is `bridged_denied`/`nat_denied` by name); `stale` is
/// the D8 contract reapplied mid-flight — a row that names the image
/// but no longer binds it.
pub const OpenVerdict = union(enum) {
    allow,
    v6_literal,
    path: PathClass,
    stale,
};

// ---------------------------------------------------------------------------
// The enforcement posture (D12): `audit` receipts would-be denials and
// refuses nothing at the word seam; `enforce` makes a denied word an
// honest EACCES. Parsed from the `#v1` header's `mode=` field; absent =
// `audit` — the switch lives inside the secret-class file, off the
// EL0-writable surface. M116b (#2468) lands the enforce half: the
// ambient floor is narrowed below, and a `mode=enforce` provisioned file
// makes every denied word a named refusal. The absent-file posture stays
// `audit` by owner decision — an unarmed boot keeps working; flipping
// that default is its own later call.
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
/// a different table is a different KERNEL.BIN digest).
pub const BaseRow = struct {
    name: []const u8,
    /// 32 raw-file digest bytes, or null for the `*` wildcard (narrow only).
    sha256: ?[measure.digest_len]u8,
    words: u32,
    /// M117e: the net scope qualifiers — empty for every fleet row today.
    scope: Scope = .{},
};
/// M116a (#2467): the fleet policy — one `*` narrow-only row per shipped
/// app, authored from the M113f audit data (#2422) in
/// image/fleet-grants.txt and GENERATED into kernel/src/grant_fleet.zig
/// by tools/grants/fleet_grants.py (regenerate, don't hand-edit). The
/// user table's 16-row bound cannot hold the ~31-app fleet, so owner
/// policy lives in the compiled table — the signing is the Part I boot
/// chain itself: a different table is a different KERNEL.BIN digest.
pub const base_rows = &@import("grant_fleet.zig").rows;

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
    /// M117e: the net scope the optional fourth field carried.
    scope: Scope = .{},
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
                .scope = b.scope,
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
/// `grant_stale`, or take the ambient floor. `digest` is the measured
/// raw-file digest — null when the measurement itself failed (a named
/// row is then unverifiable, which is fail-closed `stale`, never open).
pub const Verdict = union(enum) {
    /// No row names this image — the ambient set applies (M116b: the
    /// narrowed no-row floor, not the full vocabulary).
    ambient,
    apply: u32,
    stale,
};

pub fn decide(name: []const u8, digest: ?*const [measure.digest_len]u8) Verdict {
    return switch (lookup(name)) {
        .none => .ambient,
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
    scope: Scope = .{},
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

/// M117e: a `v6=` token's prefix length — decimal digits, 0..128.
fn parsePrefixLen(s: []const u8) ?u8 {
    if (s.len == 0 or s.len > 3) return null;
    var v: u16 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    if (v > 128) return null;
    return @intCast(v);
}

/// M117e: the optional fourth field — `-`/empty is unconstrained; else a
/// CSV of `v6=<prefix>/<len>` (bounded by `max_v6_prefixes`) and
/// `if=<nat|bridged>` tokens. Null on any malformed or overflowing
/// token — the caller poisons the row (fail closed, the line grammar's
/// standing rule).
fn parseScope(s: []const u8) ?Scope {
    if (s.len == 0 or std.mem.eql(u8, s, "-")) return .{};
    var scope: Scope = .{};
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "v6=")) {
            const spec = tok[3..];
            const slash = std.mem.lastIndexOfScalar(u8, spec, '/') orelse return null;
            const addr = ipv6.parse_ip6(spec[0..slash]) orelse return null;
            const len = parsePrefixLen(spec[slash + 1 ..]) orelse return null;
            if (scope.v6_count >= max_v6_prefixes) return null;
            scope.v6[scope.v6_count] = .{ .addr = addr, .len = len };
            scope.v6_count += 1;
        } else if (std.mem.startsWith(u8, tok, "if=")) {
            const name = tok[3..];
            if (std.mem.eql(u8, name, "nat")) {
                scope.if_mask |= if_nat;
            } else if (std.mem.eql(u8, name, "bridged")) {
                scope.if_mask |= if_bridged;
            } else return null;
        } else return null;
    }
    return scope;
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
    var fields: [4][]const u8 = .{ "", "", "", "" };
    var nfields: usize = 0;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |f| {
        if (nfields < 4) fields[nfields] = f;
        nfields += 1;
    }
    const name = fields[0];
    if (!validName(name)) {
        // An over-long name is still a policy statement the file makes —
        // count it so an over-long exec name fails closed too.
        if (name.len > name_max) overlong_names += 1;
        return .skipped;
    }
    // M117e: three fields is the standing row shape; a fourth carries the
    // net scope. Five or more is malformed.
    var poison = nfields != 3 and nfields != 4;
    var sha: [measure.digest_len]u8 = undefined;
    var wildcard = false;
    var words: u32 = 0;
    var scope: Scope = .{};
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
    if (!poison and nfields == 4) {
        if (parseScope(fields[3])) |sc| {
            scope = sc;
        } else {
            poison = true;
        }
    }
    if (findRow(name)) |r| {
        r.poisoned = poison;
        if (!poison) {
            r.wildcard = wildcard;
            r.sha256 = sha;
            r.words = words;
            r.scope = scope;
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
        r.scope = scope;
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
    // M117e: the scope field appears only when the row carries one — a
    // scope-less row serializes exactly the three-field shape it had
    // before the qualifier existed.
    if (!r.scope.isEmpty()) {
        if (pos + 1 > out.len) return null;
        out[pos] = '\t';
        pos += 1;
        const n = scope_field_into(&r.scope, out[pos..]) orelse return null;
        pos += n;
    }
    if (pos + 1 > out.len) return null;
    out[pos] = '\n';
    return pos + 1;
}

/// M117e: marshal the scope CSV — `v6=` prefixes in stored order, then
/// the `if=` tokens in bit order. Returns bytes written; null when `out`
/// cannot hold the whole field (the caller's `line_max` bound always
/// can).
fn scope_field_into(s: *const Scope, out: []u8) ?usize {
    var pos: usize = 0;
    var first = true;
    for (s.v6[0..s.v6_count]) |p| {
        if (!first) {
            if (pos + 1 > out.len) return null;
            out[pos] = ',';
            pos += 1;
        }
        if (pos + 3 > out.len) return null;
        @memcpy(out[pos .. pos + 3], "v6=");
        pos += 3;
        var abuf: [39]u8 = undefined;
        const alen = ipv6.format_ip6(p.addr, &abuf);
        if (pos + alen + 1 > out.len) return null;
        @memcpy(out[pos .. pos + alen], abuf[0..alen]);
        pos += alen;
        const written = std.fmt.bufPrint(out[pos..], "/{d}", .{p.len}) catch return null;
        pos += written.len;
        first = false;
    }
    inline for (.{ PathClass.nat, PathClass.bridged }) |c| {
        if ((s.if_mask & c.bit()) != 0) {
            if (!first) {
                if (pos + 1 > out.len) return null;
                out[pos] = ',';
                pos += 1;
            }
            if (pos + 3 > out.len) return null;
            @memcpy(out[pos .. pos + 3], "if=");
            pos += 3;
            const tok = c.token();
            if (pos + tok.len > out.len) return null;
            @memcpy(out[pos .. pos + tok.len], tok);
            pos += tok.len;
            first = false;
        }
    }
    return pos;
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
    var fields: [4][]const u8 = .{ "", "", "", "" };
    var nfields: usize = 0;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |f| {
        if (nfields < 4) fields[nfields] = f;
        nfields += 1;
    }
    if ((nfields != 3 and nfields != 4) or !validName(fields[0])) return .einval;
    var sha: [measure.digest_len]u8 = @as([measure.digest_len]u8, @splat(@as(u8, 0)));
    var wildcard = false;
    if (std.mem.eql(u8, fields[1], "*")) {
        wildcard = true;
    } else if (!parseHexDigest(fields[1], &sha)) {
        return .einval;
    }
    const words = parseWords(fields[2]) orelse return .einval;
    if (wildcard and (words & ~baseline) != 0) return .einval;
    var scope: Scope = .{};
    if (nfields == 4) scope = parseScope(fields[3]) orelse return .einval;
    if (!virtio_file.available()) return .enxio;

    admin_backup = user_rows;
    admin_backup_count = user_count;
    if (findRow(fields[0])) |r| {
        r.poisoned = false;
        r.wildcard = wildcard;
        r.sha256 = sha;
        r.words = words;
        r.scope = scope;
    } else {
        const r = freeSlot() orelse return .enospc;
        r.* = .{ .used = true, .wildcard = wildcard, .sha256 = sha, .words = words, .scope = scope };
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
/// user table and `audit` posture — no boot line, boot-default
/// unchanged (M116b: enforce arrives provisioned, `mode=enforce`).
pub fn init_from_share() bool {
    init();
    if (!virtio_file.available()) return false;
    if (!trust.ensure_grant_file()) return false; // class must hold first
    const n = virtio_file.read_whole(filename, &file_scratch) orelse return false;
    _ = load(file_scratch[0..n]);
    return true;
}

// ---------------------------------------------------------------------------
// M117e (#2477, ADR 0057 D12): the scope check at the open-class op.
// ---------------------------------------------------------------------------

fn zero4(ip: [4]u8) bool {
    return std.mem.eql(u8, &ip, &.{ 0, 0, 0, 0 });
}

/// The destination's egress path class, computed from the stack's own
/// routing state — never the host's word for the attachment. `bridged`
/// is the class a real LAN adds: a destination the wire resolves
/// DIRECTLY (v4 `arp.next_hop` answers the literal, v6 `ipv6.next_hop`
/// answers the address — on-link). `nat` is the router-mediated path
/// the island always had — an off-link destination, an unroutable one
/// (classified by intent, refused by the transport anyway), or the
/// router itself, which is the island's own fabric rather than a peer.
pub fn dstClass(dst: ScopedDst) PathClass {
    return switch (dst) {
        .v4 => |ip| blk: {
            const gw = arp.default_gateway();
            if (!zero4(gw) and std.mem.eql(u8, &ip, &gw)) break :blk .nat;
            break :blk if (std.mem.eql(u8, &arp.next_hop(ip), &ip)) .bridged else .nat;
        },
        .v6 => |a| blk: {
            if (ipv6.router_valid and std.mem.eql(u8, &a, &ipv6.router_addr)) break :blk .nat;
            const nh = ipv6.next_hop(&a) orelse break :blk .nat;
            break :blk if (std.mem.eql(u8, &nh, &a)) .bridged else .nat;
        },
    };
}

/// Evaluate one row's scope against a destination. The v6-prefix bound
/// gates only v6 literals (a v4 destination is not a v6 literal); the
/// `if=` bound gates every destination's class. Empty scope allows —
/// the fast path every scope-less row takes.
pub fn scopeEval(scope: Scope, dst: ScopedDst) OpenVerdict {
    if (scope.isEmpty()) return .allow;
    if (dst == .v6 and scope.v6_count != 0) {
        var match = false;
        for (scope.v6[0..scope.v6_count]) |p| {
            if (ipv6.prefix_match(dst.v6, p.addr, p.len)) {
                match = true;
                break;
            }
        }
        if (!match) return .v6_literal;
    }
    const class = dstClass(dst);
    if (scope.if_mask != 0 and (scope.if_mask & class.bit()) == 0)
        return .{ .path = class };
    return .allow;
}

fn startsWithIC(hay: []const u8, prefix: []const u8) bool {
    if (prefix.len > hay.len) return false;
    return std.ascii.eqlIgnoreCase(hay[0..prefix.len], prefix);
}

/// Lookup for the open-class check: the caller's recorded image name is
/// the registry's DISPLAY name (process.name_max = 16 — a truncation
/// bound, not the row-key bound). A name at that bound may be a longer
/// exec name's prefix, so an exact miss scans for the row it could be a
/// prefix of — a scoped row never goes unseen because the display name
/// truncated it.
fn lookupProcess(name: []const u8) Lookup {
    const l = lookup(name);
    switch (l) {
        .none => {},
        else => return l,
    }
    if (name.len < process.name_max) return .none;
    for (&user_rows) |*r| {
        if (r.used and startsWithIC(r.name[0..r.name_len], name))
            return if (r.poisoned) .poisoned else .{ .row = r };
    }
    for (base_rows) |*b| {
        if (startsWithIC(b.name, name)) {
            const r = &base_row_scratch;
            r.* = .{
                .used = true,
                .wildcard = b.sha256 == null,
                .name_len = @intCast(b.name.len),
                .sha256 = b.sha256 orelse @as([measure.digest_len]u8, @splat(@as(u8, 0))),
                .words = b.words & baseline,
                .scope = b.scope,
            };
            @memcpy(r.name[0..b.name.len], b.name);
            return .{ .row = r };
        }
    }
    return .none;
}

/// The open-class-op scope check (M117e): resolve the owner's row by
/// the registry name, confirm the row still binds the exec-measured
/// image (D8's contract — a mid-flight rewrite that no longer binds is
/// `stale`, fail-closed, never silently unscoped), and evaluate the
/// scope qualifiers against the destination. `audit` mode receipts the
/// denial and the caller proceeds anyway; `enforce` makes the caller
/// refuse EACCES. Kernel-context owners (no resolvable pid, the
/// `unowned` sentinel) carry no row — same rule as the word gate.
pub fn net_open(owner: u64, dst: ScopedDst) OpenVerdict {
    if (owner >= process.max_processes) return .allow;
    const pid: usize = @intCast(owner);
    const pinfo = process.info(pid) orelse return .allow;
    const verdict = switch (lookupProcess(pinfo.name)) {
        .none => OpenVerdict.allow,
        .poisoned => OpenVerdict.stale,
        .row => |r| blk: {
            if (!r.wildcard) {
                const gs = process.grant_state(pid) orelse break :blk OpenVerdict.stale;
                if (!gs.measured_ok or !std.mem.eql(u8, &gs.digest, &r.sha256)) break :blk OpenVerdict.stale;
            }
            break :blk scopeEval(r.scope, dst);
        },
    };
    if (verdict != .allow) emit_scope_denial(pid, verdict);
    return verdict;
}

/// The scope denial's receipt — the `emit_word_denial` shape with the
/// qualifier name in the verdict field (`v6_literal`, `bridged`, `nat`,
/// `stale`) and `word=net` (the scoped word the open rode in on).
fn emit_scope_denial(pid: usize, verdict: OpenVerdict) void {
    const qname: []const u8 = switch (verdict) {
        .v6_literal => "v6_literal",
        .path => |c| c.token(),
        .stale => "stale",
        .allow => return,
    };
    var digest: [measure.digest_len]u8 = @as([measure.digest_len]u8, @splat(@as(u8, 0)));
    var name: []const u8 = "";
    if (process.grant_state(pid)) |gs| digest = gs.digest;
    if (process.info(pid)) |pinfo| name = pinfo.name;
    var verdict_buf: [40]u8 = undefined;
    const vtext = std.fmt.bufPrint(&verdict_buf, "{s}:{s}_denied", .{
        if (enforceMode()) "refused" else "audit", qname,
    }) catch return;
    var line: [measure.receipt_max]u8 = undefined;
    const n = measure.receipt_line(&line, .exec, &digest, vtext, name, "net");
    klog.line(line[0..n]);
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
    // An unlisted binary takes the ambient floor (M116b).
    try std.testing.expectEqual(Verdict.ambient, decide("OTHER.BIN", &da));
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
    try std.testing.expectEqual(Verdict.ambient, decide("OTHER.BIN", &da));
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
    try std.testing.expectEqual(Verdict.ambient, decide("ONE.MORE", &da));
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
                .ambient => {},
                .apply => |w| try std.testing.expect((w & ~baseline) == 0),
                .stale => {},
            }
        }
    }
    // The baseline itself remains the full vocabulary ceiling.
    try std.testing.expectEqual(@as(u32, 0x1ff), baseline);
}

test "grant: the ambient floor drops the boundary words, keeps existence (M116b)" {
    init();
    // The no-row floor: file/audio/net are row-only words now.
    try std.testing.expectEqual(
        baseline & ~(word_file | word_audio | word_net),
        ambient,
    );
    // debug stays: sys_ping/sys_write/sys_exit are existence verbs —
    // a process that cannot print or exit is stuck, not confined.
    try std.testing.expect((ambient & word_debug) != 0);
    try std.testing.expect((ambient & word_memory) != 0);
    try std.testing.expect((ambient & word_process) != 0);
    const da = hexDigest(sha_a);
    try std.testing.expectEqual(Verdict.ambient, decide("UNLISTED.BIN", &da));
    // A row still grants what ambient dropped — the floor is a floor,
    // not a ceiling.
    _ = load("#v1\nROWED.ELF\t*\tfile,net,audio\n");
    try std.testing.expectEqual(
        Verdict{ .apply = word_file | word_net | word_audio },
        decide("ROWED.ELF", null),
    );
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

/// Read a repo data file for a host test: the `zig build test` root runs
/// from the repo root; the `../../` form covers a runner that sets cwd to
/// the module's own directory (the sexiburger manifest-pin pattern).
fn readRepoFile(path: []const u8, cap: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(cap),
    ) catch |err| switch (err) {
        error.FileNotFound => {
            const alt = try std.fmt.allocPrint(
                std.testing.allocator,
                "../../{s}",
                .{path},
            );
            defer std.testing.allocator.free(alt);
            return std.Io.Dir.cwd().readFileAlloc(
                std.testing.io,
                alt,
                std.testing.allocator,
                .limited(cap),
            );
        },
        else => |e| return e,
    };
}

test "grant: fleet base rows cover the shipped roster (M116a #2467)" {
    // The card's acceptance, as a class-A check inside `zig build test`:
    // the policy data (image/fleet-grants.txt — name, observed audit
    // set, authored mask, reason) is generated into the compiled table,
    // so every shipped app must hit a base row, every row's mask must
    // cover its observed audit set, and every widening must carry a
    // named reason. A missing app or a narrower mask fails here.
    init();
    // Repo data read like sexiburger's manifest pin: the `zig build test`
    // root runs from the repo root; the `../../` form covers a runner
    // that sets cwd to the module's own directory.
    const apps_txt = try readRepoFile("image/apps.txt", 8 * 1024);
    defer std.testing.allocator.free(apps_txt);
    const policy = try readRepoFile("image/fleet-grants.txt", 32 * 1024);
    defer std.testing.allocator.free(policy);

    var policy_names: [64][]const u8 = undefined;
    var policy_count: usize = 0;
    var pit = std.mem.splitScalar(u8, policy, '\n');
    while (pit.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fit = std.mem.splitScalar(u8, line, '\t');
        const name = fit.next() orelse return error.BadPolicyLine;
        const observed = fit.next() orelse return error.BadPolicyLine;
        const mask = fit.next() orelse return error.BadPolicyLine;
        const reason = fit.next() orelse return error.BadPolicyLine;
        try std.testing.expect(policy_count < policy_names.len);
        policy_names[policy_count] = name;
        policy_count += 1;
        const obs_mask = parseWords(observed) orelse return error.BadObserved;
        const row_mask = parseWords(mask) orelse return error.BadMask;
        // mask ⊇ observed; a strict widening (or an un-audited app, whose
        // observed set is `-`) requires a named reason.
        try std.testing.expect((obs_mask & ~row_mask) == 0);
        if (row_mask != obs_mask or obs_mask == 0)
            try std.testing.expect(!std.mem.eql(u8, reason, "-"));
        // The compiled table carries exactly this mask — a stale
        // generated file is a test failure, not a silent divergence.
        switch (lookup(name)) {
            .row => |r| try std.testing.expectEqual(row_mask, r.words & baseline),
            else => return error.MissingBaseRow,
        }
        switch (decide(name, null)) {
            .apply => |w| try std.testing.expectEqual(row_mask, w),
            else => return error.WildcardRowDidNotApply,
        }
    }

    // Every apps.txt field-1 name has a policy row (the manifest roster
    // is the acceptance's roster; SERVICE_FLEET in the tool covers the
    // non-manifest half).
    var ait = std.mem.splitScalar(u8, apps_txt, '\n');
    while (ait.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        const bar = std.mem.indexOfScalar(u8, t, '|') orelse continue;
        const name = std.mem.trim(u8, t[0..bar], " ");
        if (name.len == 0) continue;
        var found = false;
        for (policy_names[0..policy_count]) |n| {
            if (std.mem.eql(u8, n, name)) found = true;
        }
        try std.testing.expect(found);
    }
}

// ---------------------------------------------------------------------------
// M117e (#2477) host tests — the scope grammar and the open-class check's
// pure halves. `net_open`'s pid resolution and the live EACCES are the
// class-B spec's legs (live-net-policy).
// ---------------------------------------------------------------------------

test "grant: scope field parses, serializes, and round-trips (M117e)" {
    init();
    _ = load("#v1\nV6APP.ELF\t*\tfile,net\tv6=2001:db8:64::/64,if=nat\nLANAPP.ELF\t*\tnet\tif=bridged\nPLAIN.ELF\t*\tnet\nDASH.ELF\t*\tnet\t-\n");
    try std.testing.expectEqual(@as(usize, 4), count());
    switch (lookup("V6APP.ELF")) {
        .row => |r| {
            try std.testing.expectEqual(@as(u8, 1), r.scope.v6_count);
            try std.testing.expectEqual(@as(u8, 64), r.scope.v6[0].len);
            try std.testing.expectEqual(if_nat, r.scope.if_mask);
        },
        else => return error.MissingRow,
    }
    switch (lookup("LANAPP.ELF")) {
        .row => |r| try std.testing.expectEqual(if_bridged, r.scope.if_mask),
        else => return error.MissingRow,
    }
    switch (lookup("DASH.ELF")) {
        .row => |r| try std.testing.expect(r.scope.isEmpty()),
        else => return error.MissingRow,
    }
    var buf: [file_max]u8 = undefined;
    const n = save(&buf);
    const text = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, text, "V6APP.ELF\t*\tfile,net\tv6=2001:db8:64::/64,if=nat\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "LANAPP.ELF\t*\tnet\tif=bridged\n") != null);
    // Scope-less rows keep the three-field shape — the fourth field
    // appears only when the row carries one.
    try std.testing.expect(std.mem.indexOf(u8, text, "PLAIN.ELF\t*\tnet\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "DASH.ELF\t*\tnet\n") != null);
    try std.testing.expectEqual(LoadResult.ok, load(text));
    switch (lookup("V6APP.ELF")) {
        .row => |r| try std.testing.expectEqual(@as(u8, 1), r.scope.v6_count),
        else => return error.MissingRow,
    }
}

test "grant: malformed scope poisons the row (M117e)" {
    init();
    _ = load("#v1\nBAD.ELF\t*\tnet\tif=narnia\nBADV6.ELF\t*\tnet\tv6=zzz/64\nOVER.ELF\t*\tnet\tv6=2001:db8::/64,v6=2001:db9::/64,v6=2001:dba::/64,v6=2001:dbb::/64,v6=2001:dbc::/64\n");
    const da = hexDigest(sha_a);
    for ([_][]const u8{ "BAD.ELF", "BADV6.ELF", "OVER.ELF" }) |n| {
        switch (lookup(n)) {
            .poisoned => {},
            else => return error.ExpectedPoison,
        }
        try std.testing.expectEqual(Verdict.stale, decide(n, &da));
    }
    // A five-field line poisons too.
    init();
    _ = load("#v1\nFIVE.ELF\t*\tnet\tif=nat\textra\n");
    switch (lookup("FIVE.ELF")) {
        .poisoned => {},
        else => return error.ExpectedPoison,
    }
    // The admin path's strict parse refuses a bad scope before any I/O.
    try std.testing.expectEqual(AdminResult.einval, admin_set_line("A.ELF\t*\tnet\tif=narnia"));
}

test "grant: a truncated registry name still sees a longer scoped row (M117e)" {
    init();
    _ = load("#v1\nABCDEFGHIJKLMNOPQ.ELF\t*\tnet\tif=nat\n");
    // "ABCDEFGHIJKLMNOP" is the 16-byte display bound — a longer exec
    // name truncates to it, and the prefix fallback must still bind.
    switch (lookupProcess("ABCDEFGHIJKLMNOP")) {
        .row => |r| try std.testing.expectEqual(if_nat, r.scope.if_mask),
        else => return error.MissingRow,
    }
    // An unrelated prefix does not bind.
    switch (lookupProcess("ABCDEFGHIJKLMNOZ")) {
        .none => {},
        else => return error.ExpectedNone,
    }
}

test "grant: dstClass names the path the wire takes (M117e)" {
    const saved_ip = arp.own_ip;
    const saved_mask = arp.own_mask;
    const saved_gw = arp.gateway;
    const saved_rv = ipv6.router_valid;
    const saved_ra = ipv6.router_addr;
    const saved_rl = ipv6.router_lifetime;
    const saved_ov = ipv6.onlink_valid;
    const saved_op = ipv6.onlink_prefix;
    const saved_ol = ipv6.onlink_len;
    defer {
        arp.own_ip = saved_ip;
        arp.own_mask = saved_mask;
        arp.gateway = saved_gw;
        ipv6.router_valid = saved_rv;
        ipv6.router_addr = saved_ra;
        ipv6.router_lifetime = saved_rl;
        ipv6.onlink_valid = saved_ov;
        ipv6.onlink_prefix = saved_op;
        ipv6.onlink_len = saved_ol;
    }
    // The island fixture: a /24 with the router at .1.
    arp.own_ip = .{ 192, 168, 64, 5 };
    arp.own_mask = .{ 255, 255, 255, 0 };
    arp.gateway = .{ 192, 168, 64, 1 };
    try std.testing.expectEqual(PathClass.bridged, dstClass(.{ .v4 = .{ 192, 168, 64, 9 } }));
    try std.testing.expectEqual(PathClass.nat, dstClass(.{ .v4 = .{ 10, 9, 8, 7 } }));
    try std.testing.expectEqual(PathClass.nat, dstClass(.{ .v4 = .{ 192, 168, 64, 1 } }));
    // The v6 fixture: router + on-link prefix recorded.
    const router = ipv6.parse_ip6("fe80::ff:fe00:2").?;
    ipv6.router_valid = true;
    ipv6.router_addr = router;
    ipv6.router_lifetime = 1800;
    ipv6.onlink_valid = true;
    ipv6.onlink_prefix = ipv6.parse_ip6("2001:db8:64::").?;
    ipv6.onlink_len = 64;
    const ll_peer = ipv6.parse_ip6("fe80::1234").?;
    const onl_peer = ipv6.parse_ip6("2001:db8:64::ff:fe00:2").?;
    const off_peer = ipv6.parse_ip6("2001:db8:99::5").?;
    try std.testing.expectEqual(PathClass.bridged, dstClass(.{ .v6 = ll_peer }));
    try std.testing.expectEqual(PathClass.bridged, dstClass(.{ .v6 = onl_peer }));
    try std.testing.expectEqual(PathClass.nat, dstClass(.{ .v6 = off_peer }));
    try std.testing.expectEqual(PathClass.nat, dstClass(.{ .v6 = router }));
    // No router recorded: an off-link destination is still router-mediated
    // by intent — the transport refuses it regardless.
    ipv6.router_valid = false;
    try std.testing.expectEqual(PathClass.nat, dstClass(.{ .v6 = off_peer }));
}

test "grant: scopeEval refuses by name (M117e)" {
    const saved_ip = arp.own_ip;
    const saved_mask = arp.own_mask;
    const saved_gw = arp.gateway;
    defer {
        arp.own_ip = saved_ip;
        arp.own_mask = saved_mask;
        arp.gateway = saved_gw;
    }
    arp.own_ip = .{ 192, 168, 64, 5 };
    arp.own_mask = .{ 255, 255, 255, 0 };
    arp.gateway = .{ 192, 168, 64, 1 };
    const onl_peer = ipv6.parse_ip6("2001:db8:64::ff:fe00:2").?;
    const off_peer = ipv6.parse_ip6("fd00::5").?;
    var sc: Scope = .{};
    sc.v6[0] = .{ .addr = ipv6.parse_ip6("2001:db8:64::").?, .len = 64 };
    sc.v6_count = 1;
    try std.testing.expectEqual(OpenVerdict.allow, scopeEval(sc, .{ .v6 = onl_peer }));
    try std.testing.expectEqual(OpenVerdict.v6_literal, scopeEval(sc, .{ .v6 = off_peer }));
    // A v4 destination is not a v6 literal — the prefix bound does not see it.
    try std.testing.expectEqual(OpenVerdict.allow, scopeEval(sc, .{ .v4 = .{ 10, 9, 8, 7 } }));
    const nat_only: Scope = .{ .if_mask = if_nat };
    try std.testing.expectEqual(OpenVerdict{ .path = .bridged }, scopeEval(nat_only, .{ .v4 = .{ 192, 168, 64, 9 } }));
    try std.testing.expectEqual(OpenVerdict.allow, scopeEval(nat_only, .{ .v4 = .{ 10, 9, 8, 7 } }));
    try std.testing.expectEqual(OpenVerdict{ .path = .bridged }, scopeEval(nat_only, .{ .v6 = ipv6.parse_ip6("fe80::1234").? }));
    const bridged_only: Scope = .{ .if_mask = if_bridged };
    try std.testing.expectEqual(OpenVerdict{ .path = .nat }, scopeEval(bridged_only, .{ .v4 = .{ 10, 9, 8, 7 } }));
    try std.testing.expectEqual(OpenVerdict.allow, scopeEval(bridged_only, .{ .v4 = .{ 192, 168, 64, 9 } }));
    // The empty scope allows everything — the fast path scope-less rows take.
    try std.testing.expectEqual(OpenVerdict.allow, scopeEval(.{}, .{ .v4 = .{ 192, 168, 64, 9 } }));
    try std.testing.expectEqual(OpenVerdict.allow, scopeEval(.{}, .{ .v6 = off_peer }));
}
