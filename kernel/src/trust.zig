//! VirelaiOS M50 TS2 (issue #1136, ADR 0024 D3/D4/D8/D10): the guest-side
//! file-ownership / mode-bit metadata table and the single access predicate.
//!
//! This module is the substrate the milestone promised:
//!
//!   - A bounded in-kernel metadata table (`max_entries` = 64, pure BSS, no
//!     allocation, no eviction). A full table is an honest `ENOSPC` on the
//!     creating operation (`set_mode`), never a silent eviction.
//!   - A single pure predicate `check(actor, partition, path, want)` keyed by
//!     the normalized `(Partition, path)` pair that `file_table.parse_path`
//!     produces. The five `want` values map to the classic mode bits:
//!     `read`/`list` need the read bit, `write`/`create`/`delete` the write
//!     bit, and `admin` (chmod) is owner-only or `CAP_FS_ANY`.
//!   - Default policy when no entry exists: regular file `0644`, directory
//!     `0755`, owner `uid_user`, `secret = false`; `.usb` is read-only `0444`;
//!     `.tty` keeps device semantics and is not mode-governed.
//!   - A `secret` class flagged by `OWNERS.TXT` (D8): a secret-class path is
//!     denied read/list/delete/create through the file ABI for EVERY actor,
//!     including `uid_system`/`CAP_FS_ANY` and the EL1h monitor's `vf` seam.
//!   - `OWNERS.TXT` `#v1` load/save: one `path<TAB>mode<TAB>uid<TAB>flags`
//!     line per entry. Malformed or unknown-schema lines FAIL CLOSED (deny
//!     that path) rather than defaulting.
//!
//! ## Mode semantics
//!
//! `mode` is a 9-bit `rwxrwxrwx` value. The group triplet is **reserved and
//! enforced as zero**: there are no groups in a single-user guest (ADR 0024
//! D3), so every authored mode is accepted in the conventional 3-digit octal
//! form (`0644`, `0755`, `0600`) and normalized with its group triplet
//! cleared before it is stored or serialized. Enforcement reads only the
//! owner triplet (when `caller.uid == entry.uid`) or the other triplet. This
//! makes `OWNERS.TXT` canonical: no persisted mode ever has group bits set.
//!
//! ## Key canonicalization (ADR 0024 D4 / `docs/archive/trust-scoping.md` "Risks")
//!
//! The host share is a macOS folder; the default APFS volume is
//! case-INSENSITIVE while the guest `parse_path` key is byte-exact. A
//! byte-exact lookup would let `secret.txt` bypass an entry written for
//! `SECRETS.TXT`. The table therefore compares keys case-insensitively
//! (`std.ascii.eqlIgnoreCase`) while preserving the authored spelling in the
//! file. A case-varied request can no longer bypass an explicit entry. On a
//! case-SENSITIVE host the rule may apply an entry to a distinct
//! same-lowercase file: that is an over-deny, i.e. fail-closed, not a bypass.
//! Default policy is unaffected.
//!
//! ## Return value
//!
//! `check` returns `allow`/`eacces`/`enoent`. `enoent` is reserved for the
//! filesystem layer's own "missing path" report; `check` never fabricates it,
//! because absent metadata means the documented default policy, never a
//! silent allow or a silent deny. Enforcement callers treat anything other
//! than `allow` as a denial.
//!
//! Directory-name listings (`virtio_file.list` called from the monitor's
//! `ls`/`du`/`find`/`inventory` and the shell's glob/completion) are
//! intentionally NOT gated: D8 allows the monitor to print secret *names*,
//! and a listing is not a content read. A `list` request whose path is
//! itself secret-class is denied by `check`.

const std = @import("std");
const file_table = @import("file_table.zig");
const process = @import("process.zig");

/// ADR 0024 D3: the bounded table size. Full ⇒ `ENOSPC` on the creating
/// operation, never silent eviction.
pub const max_entries: usize = 64;
pub const max_path_len: usize = file_table.max_path_len;
/// The serialized `OWNERS.TXT` bound: 64 entries × (path ≤ 512 + separators +
/// octal mode + uid + flags) plus the header, with generous headroom.
pub const save_max: usize = 64 * (max_path_len + 32) + 4;
pub const filename = "OWNERS.TXT";
/// The secret store's share file (ADR 0024 D8). Defined here (not imported
/// from `secret.zig`, which imports THIS module) so `ensure_secret_file`
/// can flag it by construction without a circular dependency.
pub const secret_filename = "SECRETS.TXT";
/// The grant table's share file (ADR 0054 D7, M113c #2419). Same split:
/// `grant.zig` imports this module, so `ensure_grant_file`'s name lives
/// here. Its contents are POLICY, not a secret — the secret class is
/// taken for integrity (the file ABI is the only EL0 write surface).
pub const grant_filename = "GRANTS.TXT";

/// ADR 0024 D3 defaults (owner/other policy; group is reserved/zero).
pub const default_file_mode: u16 = 0o644;
pub const default_dir_mode: u16 = 0o755;
pub const usb_mode: u16 = 0o444;

/// The actor whose request is being authorized. `is_kernel` is informational;
/// the capability bit is what bypasses ordinary mode checks. `pid` and `name`
/// are the kernel-recorded process identity (the registry row, never a
/// caller-supplied string): the M97g APPLOG/CRASH label binding consults them
/// for non-privileged actors.
pub const Actor = struct {
    uid: u32,
    caps: u32,
    is_kernel: bool = false,
    pid: ?usize = null,
    name: []const u8 = "",
};

/// The operation class (ADR 0024 D4). `admin` is the chmod surface (owner or
/// `CAP_FS_ANY`), not a mode-bit test.
pub const Want = enum { read, write, create, delete, list, admin };

/// The frozen predicate result (ADR 0024 D4).
pub const Verdict = enum { allow, eacces, enoent };

/// `set_mode` outcome. `enospc` is the table-full refusal (never eviction).
pub const SetResult = enum { ok, eacces, enospc, einval };

/// `load` outcome. `full` means the file carried more valid entries than the
/// 64-entry cap; what fit was loaded and the rest was refused (never evicted
/// an earlier entry).
pub const LoadResult = enum { ok, full };

/// Kernel/internal actors (the EL1h monitor and every kernel consumer) act as
/// `uid_system` with both capabilities (ADR 0024 D5).
pub fn kernel_actor() Actor {
    return .{ .uid = process.uid_system, .caps = process.kernel_caps, .is_kernel = true };
}

const Entry = struct {
    used: bool = false,
    /// A poisoned / malformed source line: deny this path for every actor.
    deny: bool = false,
    secret: bool = false,
    partition: file_table.Partition = .host,
    path: [max_path_len]u8 = @as([max_path_len]u8, @splat(@as(u8, 0))),
    path_len: u16 = 0,
    mode: u16 = default_file_mode,
    uid: u32 = process.uid_user,
};

/// Metadata table (pure BSS). Entries are never evicted to make room.
var entries: [max_entries]Entry = @as([max_entries]Entry, @splat(@as(Entry, .{})));
var entry_count: usize = 0;

/// Clear the table (boot + host tests; `load` also starts from empty).
pub fn init() void {
    // Avoid embedding a second full-width table in rodata just to reset it.
    for (&entries) |*entry| entry.* = .{};
    entry_count = 0;
}

pub fn count() usize {
    return entry_count;
}

/// The reserved group triplet is enforced zero (single-user; no groups).
pub fn normalizeMode(mode: u16) u16 {
    return mode & 0o707;
}

fn pathMatches(e: *const Entry, partition: file_table.Partition, path: []const u8) bool {
    if (e.partition != partition) return false;
    if (e.path_len != path.len) return false;
    return std.ascii.eqlIgnoreCase(e.path[0..e.path_len], path);
}

fn find(partition: file_table.Partition, path: []const u8) ?*Entry {
    for (&entries) |*e| {
        if (!e.used) continue;
        if (pathMatches(e, partition, path)) return e;
    }
    return null;
}

fn freeSlot() ?*Entry {
    for (&entries) |*e| {
        if (!e.used) return e;
    }
    return null;
}

fn setEntry(e: *Entry, partition: file_table.Partition, path: []const u8, mode: u16, uid: u32, secret: bool) void {
    const n = @min(path.len, max_path_len);
    @memcpy(e.path[0..n], path[0..n]);
    e.path_len = @intCast(n);
    e.partition = partition;
    e.mode = normalizeMode(mode);
    e.uid = uid;
    e.secret = secret;
}

fn isPrivileged(actor: Actor) bool {
    return actor.is_kernel or (actor.caps & process.cap_fs_any) != 0;
}

/// M97g (#2085): the diagnostic-label overlay. A direct child of `APPLOG/`
/// or `CRASH/` on the host share carries an app label in its stem
/// ("APPLOG/GOSH.LOG" -> "GOSH", "CRASH/GSCHK.STK" -> "GSCHK"). A
/// non-privileged actor may touch a labeled file only when the label binds
/// to the CALLER'S OWN kernel-recorded image name (modulo a ".ELF"
/// suffix) or to a registry row the caller spawned — the supervisor case:
/// INIT, `gosh` and a service manager write a crashed child's receipt,
/// and the row survives the child's exit. Anything else is EACCES: one
/// app can no longer append to, read or receipt another's diagnostic
/// records. Privileged actors (`CAP_FS_ANY`, kernel) keep the bypass —
/// the `-u0` viewer/producer channel.
fn labelOwned(actor: Actor, partition: file_table.Partition, path: []const u8) bool {
    if (partition != .host) return true;
    const rest = stripPrefixFold(path, "APPLOG/") orelse
        stripPrefixFold(path, "CRASH/") orelse return true;
    if (rest.len == 0 or std.mem.indexOfScalar(u8, rest, '/') != null) return true;
    const stem = if (std.mem.lastIndexOfScalar(u8, rest, '.')) |dot| rest[0..dot] else rest;
    if (stem.len == 0) return false;
    const own = process.label_stem(actor.name);
    if (own.len != 0 and std.ascii.eqlIgnoreCase(own, process.label_stem(stem))) return true;
    if (actor.pid) |pid| return process.spawned_label(stem, pid);
    return false;
}

fn stripPrefixFold(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (path.len < prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix)) return null;
    return path[prefix.len..];
}

/// The secret class (D8) denies these operation classes for every actor: the
/// file ABI can never read a secret, and rename/delete cannot strip the class.
fn secretDenies(want: Want) bool {
    return switch (want) {
        .read, .list, .delete, .create => true,
        .write, .admin => false,
    };
}

fn defaultMode(partition: file_table.Partition, want: Want) u16 {
    return switch (partition) {
        .usb, .usb_fat => usb_mode, // M70f F1: a USB volume is read-only too
        // M100c (issue #2308, ADR 0050 D6): every .disk object is
        // world-readable/writable in v1 — the mode is a statement, and the
        // fs never consults the trust table for it anyway.
        .disk => 0o777,
        .tty => 0o666, // unreachable: tty returns allow early
        .host => if (want == .list) default_dir_mode else default_file_mode,
    };
}

fn modeVerdict(actor: Actor, mode: u16, owner: u32, want: Want) Verdict {
    if (want == .admin) return if (actor.uid == owner) .allow else .eacces;
    const bits: u16 = if (actor.uid == owner) (mode >> 6) & 7 else mode & 7;
    const need: u16 = switch (want) {
        .read, .list => 4,
        .write, .create, .delete => 2,
        .admin => 4, // unreachable
    };
    return if ((bits & need) != 0) .allow else .eacces;
}

/// ADR 0024 D4: the one policy predicate. See the module doc for the secret
/// class, the mode semantics, and the canonicalization decision. `path` is
/// the caller's `parse_path`-normalized key (share-relative for `.host`).
pub fn check(actor: Actor, partition: file_table.Partition, path: []const u8, want: Want) Verdict {
    if (partition == .tty) return .allow; // device semantics, not mode-governed
    const privileged = isPrivileged(actor);

    if (path.len <= max_path_len) {
        if (find(partition, path)) |e| {
            if (e.deny) return .eacces; // malformed entry: fail closed
            if (e.secret and secretDenies(want)) return .eacces; // D8
            if (privileged) return .allow;
            if (!labelOwned(actor, partition, path)) return .eacces; // #2085
            return modeVerdict(actor, e.mode, e.uid, want);
        }
    }
    // No explicit entry (or a path too long to carry one): default policy.
    if (privileged) return .allow;
    if (!labelOwned(actor, partition, path)) return .eacces; // #2085
    return modeVerdict(actor, defaultMode(partition, want), defaultOwner(partition, path), want);
}

/// M173b (#3041, ADR 0052 amendment / index D16): the default owner of an
/// unlisted path. A path under an agent-owned ancestor defaults to
/// `uid_agent` — the kernel-minted rows on AGENT/ and AGENT/AUDIT/ then
/// carry their ownership down the whole subtree, so the daemon writes
/// inside its roots as owner without spending a table row per file
/// (the 64-entry bound only ever holds the two roots). Every other
/// subtree keeps the `uid_user` default it always had — an authored
/// uid_system/uid_user row changes nothing below it.
pub fn defaultOwner(partition: file_table.Partition, path: []const u8) u32 {
    if (partition == .host) {
        var rest = path;
        while (std.mem.lastIndexOfScalar(u8, rest, '/')) |i| {
            rest = rest[0..i];
            if (find(partition, rest)) |e| {
                if (!e.deny and e.uid == process.uid_agent) return process.uid_agent;
                break;
            }
        }
    }
    return process.uid_user;
}

/// M173b (#3041, ADR 0052 amendment / index D16): kernel-minted rows for
/// the two roots AGENTD must write — the `ensure_meta_file` pattern. An
/// existing row is forced back to `uid_agent` + `0755` (a hand-seeded
/// line can never loosen the agent's ownership); a missing row is minted
/// through the regular `setEntry` path. The two rows live inside the
/// shared 64-entry bound — false only when the table cannot hold them.
pub fn ensure_agent_roots() bool {
    const roots = [_][]const u8{ "AGENT", "AGENT/AUDIT" };
    for (roots) |root| {
        if (find(.host, root)) |e| {
            e.used = true;
            e.deny = false;
            e.secret = false;
            e.uid = process.uid_agent;
            e.mode = default_dir_mode;
            continue;
        }
        const slot = freeSlot() orelse return false;
        slot.used = true;
        slot.deny = false;
        slot.secret = false;
        setEntry(slot, .host, root, default_dir_mode, process.uid_agent, false);
        entry_count += 1;
    }
    return true;
}

/// ADR 0024 D10 slot 69: owner-only chmod on an existing path, or
/// `CAP_FS_ANY`. Creates the metadata entry when none exists (the creating
/// operation that can return `ENOSPC`); never chowns, never mutates the
/// secret flag. Existence and path syntax are the caller's business.
pub fn set_mode(actor: Actor, partition: file_table.Partition, path: []const u8, mode: u16) SetResult {
    if (partition == .tty) return .einval; // device semantics
    if (partition == .usb or partition == .usb_fat) return .eacces; // fixed read-only 0444
    if (mode > 0o777) return .einval;
    if (path.len == 0 or path.len > max_path_len) return .einval;

    if (find(partition, path)) |e| {
        if (e.deny) return .eacces; // never heal a poisoned path via chmod
        if (!isPrivileged(actor) and actor.uid != e.uid) return .eacces;
        // #2085: without this an app could chmod a foreign diagnostic label
        // (all uid_user files) to 000 and revoke the owner's ring access.
        if (!isPrivileged(actor) and !labelOwned(actor, partition, path)) return .eacces;
        e.mode = normalizeMode(mode);
        return .ok;
    }
    // No entry: the effective owner is the resolved default (uid_user, or
    // uid_agent under an agent-owned ancestor — M173b), so only that owner
    // or a privileged actor may mint the entry.
    if (check(actor, partition, path, .admin) != .allow) return .eacces;
    const slot = freeSlot() orelse return .enospc;
    slot.used = true;
    slot.deny = false;
    slot.secret = false;
    setEntry(slot, partition, path, mode, defaultOwner(partition, path), false);
    entry_count += 1;
    return .ok;
}

/// Drop any metadata for a deleted path. Returns true when the table changed.
pub fn remove(partition: file_table.Partition, path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_len) return false;
    if (find(partition, path)) |e| {
        e.* = .{};
        entry_count -%= 1;
        return true;
    }
    return false;
}

/// M97g (#2083): `OWNERS.TXT` itself is operator-only BY CONSTRUCTION. An
/// EL0 process that could write the metadata file could author a
/// `uid_system` ownership row for an image it controls and launder it into
/// `system_owned_key` — forging the identity the secret-store app binding
/// trusts. The self entry is therefore forced to `uid_system` `0644` on
/// every load and at boot: an EL0 writer/renamer/deleter is refused, and a
/// hand-seeded self line can never loosen it (fail closed). The guest may
/// still READ it (0644 other-read — names and modes are not secrets).
pub fn ensure_meta_file() bool {
    if (find(.host, filename)) |e| {
        e.used = true;
        e.deny = false;
        e.secret = false;
        e.uid = process.uid_system;
        e.mode = 0o644;
        return true;
    }
    const slot = freeSlot() orelse return false;
    slot.used = true;
    slot.deny = false;
    slot.secret = false;
    setEntry(slot, .host, filename, 0o644, process.uid_system, false);
    entry_count += 1;
    return true;
}

/// M97g (#2083): true when `key` (a `parse_path`-normalized `.host` path)
/// names a file the operator pinned to `uid_system` with no non-owner write
/// bit — i.e. an EL0 process can neither modify the file's bytes nor have
/// authored the metadata that claims it. Used by the secret store's app
/// binding: a process's recorded image name is only meaningful when the
/// image itself is operator-provisioned.
pub fn system_owned_key(key: []const u8) bool {
    const e = find(.host, key) orelse return false;
    return !e.deny and e.uid == process.uid_system and (e.mode & 0o002) == 0;
}

/// M50 TS5 (issue #1139, ADR 0024 D8): register the secret store's file as
/// a secret-class path BY CONSTRUCTION — the class holds even when no
/// hand-seeded `OWNERS.TXT` names `SECRETS.TXT`. An existing entry is
/// upgraded to `secret = true` (never downgraded, never un-poisoned);
/// otherwise a new entry is minted in the ADR's documented shape (mode
/// `0600`, owner `uid_system`). Returns false ONLY when the bounded table
/// is so full that the class cannot be registered — the caller must then
/// fail closed (an unclassified `SECRETS.TXT` would read as an ordinary
/// 0644 file). The entry persists to `OWNERS.TXT` on the next save, which
/// is exactly what a guest chmod already triggers.
pub fn ensure_secret_file() bool {
    return ensureSecretClass(secret_filename);
}

/// M113c (#2419, ADR 0054 D7): `GRANTS.TXT` is secret-class BY
/// CONSTRUCTION exactly like `SECRETS.TXT` — same `0600`/`uid_system`/
/// `secret = true` shape, minted at load and at boot even when the file
/// is absent. The contents are policy, not secret material; the class is
/// taken for INTEGRITY: the file ABI is the only write path an EL0
/// process has, and `secretDenies` refuses its read/list/delete/create
/// for every actor while the mode bits refuse a non-owner write.
pub fn ensure_grant_file() bool {
    return ensureSecretClass(grant_filename);
}

/// The shared by-construction registration both secret-class files use:
/// upgrade an existing entry (never downgrade, never un-poison) or mint
/// the `0600`/`uid_system`/`secret` entry. False only when the bounded
/// table cannot hold the class — callers fail closed then.
fn ensureSecretClass(name: []const u8) bool {
    if (find(.host, name)) |e| {
        e.used = true;
        e.deny = false;
        e.secret = true;
        return true;
    }
    const slot = freeSlot() orelse return false;
    slot.used = true;
    slot.deny = false;
    slot.secret = true;
    setEntry(slot, .host, name, 0o600, process.uid_system, true);
    entry_count += 1;
    return true;
}

/// Move metadata old→new in the same transaction as a rename. Returns true
/// when the table changed. A successful replacement adopts the source's
/// metadata, including implicit defaults; failures must not call this.
pub fn rename_meta(old_partition: file_table.Partition, old_path: []const u8, new_partition: file_table.Partition, new_path: []const u8) bool {
    if (old_path.len == 0 or old_path.len > max_path_len) return false;
    if (new_path.len == 0 or new_path.len > max_path_len) return false;
    // A same-key rename (a case-only rename canonicalizes the same way) is a
    // no-op: its source and destination are literally the same slot.
    if (old_partition == new_partition and std.ascii.eqlIgnoreCase(old_path, new_path)) return false;
    const src = find(old_partition, old_path) orelse return remove(new_partition, new_path);
    // Snapshot the source before any mutation (find returns a pointer into
    // the same table, so move the bytes into a local first).
    const moved = src.*;
    // Drop any existing destination entry.
    if (find(new_partition, new_path)) |dst| {
        dst.* = .{};
        entry_count -%= 1;
    }
    // Drop the source name and re-add under the new key (reuse its slot).
    src.* = .{};
    entry_count -%= 1;
    src.used = true;
    src.deny = moved.deny;
    setEntry(src, new_partition, new_path, moved.mode, moved.uid, moved.secret);
    entry_count += 1;
    return true;
}

// ---------------------------------------------------------------------------
// OWNERS.TXT `#v1` persistence
// ---------------------------------------------------------------------------

const header = "#v1\n";

/// Serialize the table as `#v1\n` + one `path<TAB>mode<TAB>uid<TAB>flags`
/// line per non-poisoned entry. Returns bytes written (0 when `out` is too
/// small to hold even the header). Insertion order is preserved.
pub fn save(out: []u8) usize {
    if (out.len < header.len) return 0;
    @memcpy(out[0..header.len], header);
    var pos: usize = header.len;
    for (&entries) |*e| {
        if (!e.used or e.deny) continue;
        // path
        if (pos + e.path_len + 1 > out.len) break;
        @memcpy(out[pos .. pos + e.path_len], e.path[0..e.path_len]);
        pos += e.path_len;
        out[pos] = '\t';
        pos += 1;
        // mode: exactly three octal digits (group triplet is always zero)
        if (pos + 3 > out.len) break;
        out[pos] = '0' + @as(u8, @intCast((e.mode >> 6) & 7));
        out[pos + 1] = '0' + @as(u8, @intCast((e.mode >> 3) & 7));
        out[pos + 2] = '0' + @as(u8, @intCast(e.mode & 7));
        pos += 3;
        out[pos] = '\t';
        pos += 1;
        // uid: decimal
        var ubuf: [10]u8 = undefined;
        const ulen = std.fmt.bufPrint(&ubuf, "{d}", .{e.uid}) catch break;
        if (pos + ulen.len + 1 > out.len) break;
        @memcpy(out[pos .. pos + ulen.len], ulen);
        pos += ulen.len;
        out[pos] = '\t';
        pos += 1;
        // flags
        const flags: []const u8 = if (e.secret) "secret" else "-";
        if (pos + flags.len + 1 > out.len) break;
        @memcpy(out[pos .. pos + flags.len], flags);
        pos += flags.len;
        out[pos] = '\n';
        pos += 1;
    }
    return pos;
}

fn allOctal(s: []const u8) bool {
    if (s.len == 0 or s.len > 3) return false;
    for (s) |c| if (c < '0' or c > '7') return false;
    return true;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Add (or upgrade to) a fail-closed deny entry for `path`. Used for every
/// malformed or unknown-schema source line. No-op when the path is not a
/// keyable host-share path (a request for it cannot parse either).
fn addDeny(raw_path: []const u8) void {
    const parsed = file_table.parse_path(raw_path) orelse return;
    if (parsed.partition != .host) return;
    const key = parsed.path[0..parsed.parsed_len()];
    if (find(.host, key)) |e| {
        e.deny = true;
        return;
    }
    const slot = freeSlot() orelse return;
    slot.used = true;
    slot.deny = true;
    slot.secret = false;
    setEntry(slot, .host, key, 0, process.uid_user, false);
    entry_count += 1;
}

/// Parse one well-formed `path<TAB>mode<TAB>uid<TAB>flags` line. A malformed
/// field makes the whole line a deny entry (fail closed, never default).
fn parseEntry(line: []const u8) void {
    var fields: [4][]const u8 = .{ "", "", "", "" };
    var nfields: usize = 0;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |f| {
        if (nfields < 4) fields[nfields] = f;
        nfields += 1;
    }
    if (nfields != 4) return addDeny(fields[0]);
    const parsed = file_table.parse_path(fields[0]) orelse return;
    if (parsed.partition != .host) return;
    if (parsed.parsed_len() == 0) return; // the share root is not a metadata key

    if (!allOctal(fields[1])) return addDeny(fields[0]);
    const mode = std.fmt.parseInt(u16, fields[1], 8) catch return addDeny(fields[0]);
    if (mode > 0o777) return addDeny(fields[0]);

    if (!allDigits(fields[2])) return addDeny(fields[0]);
    const uid = std.fmt.parseInt(u32, fields[2], 10) catch return addDeny(fields[0]);

    var secret = false;
    if (std.mem.eql(u8, fields[3], "-") or fields[3].len == 0) {
        secret = false;
    } else if (std.mem.eql(u8, fields[3], "secret")) {
        secret = true;
    } else {
        return addDeny(fields[0]);
    }

    const key = parsed.path[0..parsed.parsed_len()];
    if (find(.host, key)) |e| {
        e.used = true;
        e.deny = false;
        setEntry(e, .host, key, mode, uid, secret);
        return;
    }
    const slot = freeSlot() orelse return; // cap reached: refuse, never evict
    slot.used = true;
    slot.deny = false;
    setEntry(slot, .host, key, mode, uid, secret);
    entry_count += 1;
}

/// True when `line`'s first field already maps to a table row (a valid
/// update, or a poison that landed). Used to distinguish an update from a
/// cap refusal while `load` counts entries.
fn lineKeyExists(line: []const u8) bool {
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return true;
    const parsed = file_table.parse_path(line[0..tab]) orelse return true;
    if (parsed.partition != .host) return true;
    return find(.host, parsed.path[0..parsed.parsed_len()]) != null;
}

/// Load an `OWNERS.TXT` payload. The file must open with `#v1`; any other
/// leading `#` header (or a data-first file) is an unknown schema, and every
/// keyable path it lists becomes a fail-closed deny entry. Returns `full`
/// when more valid entries existed than the 64-entry cap (what fit is kept).
pub fn load(text: []const u8) LoadResult {
    init();
    var state = LoadState{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| state.consume(raw, false);
    return state.result();
}

/// Boot runs before the page allocator is armed. Stream bounded lines rather
/// than reserve a second whole ownership table in the kernel image.
pub const LoadState = struct {
    seen_header: bool = false,
    known_schema: bool = false,
    overflow: bool = false,

    pub fn consume(self: *LoadState, raw: []const u8, overlong: bool) void {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 and !overlong) return;
        if (!self.seen_header) {
            self.seen_header = true;
            self.known_schema = !overlong and std.mem.eql(u8, line, "#v1");
            if (self.known_schema) return;
            // Unknown/absent schema: fall through and poison the line.
        }
        if (!self.known_schema or overlong) {
            // Poison the listed path (field 0) — fail closed.
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
            addDeny(line[0..tab]);
            return;
        }
        const before = entry_count;
        parseEntry(line);
        if (entry_count == before and !lineKeyExists(line)) self.overflow = true;
    }

    pub fn result(self: LoadState) LoadResult {
        // M97g (#2083): a loaded table always carries the self-protection
        // row — a hand-seeded `OWNERS.TXT` self line can tighten (it is
        // overwritten here) but never loosen the metadata file's own
        // ownership. A table too full to hold the row cannot protect the
        // metadata; report that as full rather than silently unprotected.
        if (!ensure_meta_file()) return .full;
        return if (self.overflow) .full else .ok;
    }
};

// ---------------------------------------------------------------------------
// Host tests (pure; no syscalls, no filesystem)
// ---------------------------------------------------------------------------

const actor_user = Actor{ .uid = process.uid_user, .caps = 0 };
const actor_system = Actor{ .uid = process.uid_system, .caps = process.kernel_caps, .is_kernel = true };
const actor_other = Actor{ .uid = 2000, .caps = 0 };

test "trust: default policy — regular file 0644, dir 0755, usb 0444, tty allow" {
    init();
    // Owner (uid_user) may read/write a default file.
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, "a.txt", .read));
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, "a.txt", .write));
    // A different uid gets the other bits: read yes, write no.
    try std.testing.expectEqual(Verdict.allow, check(actor_other, .host, "a.txt", .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_other, .host, "a.txt", .write));
    // A directory defaults 0755: other may read/list but not write.
    try std.testing.expectEqual(Verdict.allow, check(actor_other, .host, "d", .list));
    try std.testing.expectEqual(Verdict.eacces, check(actor_other, .host, "d", .create));
    // `.usb` is fixed read-only 0444 for every actor.
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .usb, "", .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .usb, "", .write));
    // `.tty` keeps device semantics (not mode-governed).
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .tty, "", .write));
}

test "trust: owner vs other mode bits (read/write) from OWNERS" {
    init();
    _ = load("#v1\nlocked.txt\t600\t1000\t-\npublic.txt\t644\t1000\t-\n");
    // uid_user owns both; owner bits allow read+write on 600 and 644.
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, "locked.txt", .read));
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, "locked.txt", .write));
    // A different uid is "other": 600 denies read, 644 allows read but not write.
    try std.testing.expectEqual(Verdict.eacces, check(actor_other, .host, "locked.txt", .read));
    try std.testing.expectEqual(Verdict.allow, check(actor_other, .host, "public.txt", .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_other, .host, "public.txt", .write));
}

test "trust: create/delete/list/rename-class matrix" {
    init();
    _ = load("#v1\nro.txt\t400\t1000\t-\nrw.txt\t600\t1000\t-\nsysdir\t755\t0\t-\n");
    // Owner cannot delete a read-only 400 file (write bit absent).
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "ro.txt", .delete));
    // Owner can delete a writable 600 file.
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, "rw.txt", .delete));
    // Other cannot write either file.
    try std.testing.expectEqual(Verdict.eacces, check(actor_other, .host, "rw.txt", .delete));
    // A uid_system-owned dir denies uid_user create/delete but allows list.
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, "sysdir", .list));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "sysdir", .create));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "sysdir", .delete));
    // Kernel actors bypass ordinary bits (CAP_FS_ANY).
    try std.testing.expectEqual(Verdict.allow, check(actor_system, .host, "sysdir", .create));
}

test "trust: secret class denies read/list/delete/create for every actor (D8)" {
    init();
    _ = load("#v1\nSECRETS.TXT\t600\t0\tsecret\n");
    // Every actor — user, other, and the kernel/monitor — is denied the read.
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "SECRETS.TXT", .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_other, .host, "SECRETS.TXT", .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_system, .host, "SECRETS.TXT", .read));
    // list/delete/create are denied too; write stays mode-governed.
    try std.testing.expectEqual(Verdict.eacces, check(actor_system, .host, "SECRETS.TXT", .list));
    try std.testing.expectEqual(Verdict.eacces, check(actor_system, .host, "SECRETS.TXT", .delete));
    try std.testing.expectEqual(Verdict.eacces, check(actor_system, .host, "SECRETS.TXT", .create));
}

test "trust: ensure_secret_file makes SECRETS.TXT secret-class by construction (D8)" {
    // NO hand-seeded OWNERS.TXT: the class holds because the store registers
    // it, not because a host file says so.
    init();
    try std.testing.expect(ensure_secret_file());
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "SECRETS.TXT", .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_other, .host, "SECRETS.TXT", .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_system, .host, "SECRETS.TXT", .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_system, .host, "SECRETS.TXT", .list));
    try std.testing.expectEqual(Verdict.eacces, check(actor_system, .host, "SECRETS.TXT", .delete));
    try std.testing.expectEqual(Verdict.eacces, check(actor_system, .host, "SECRETS.TXT", .create));
    // The registered entry serializes into OWNERS.TXT on the next save.
    var buf: [save_max]u8 = undefined;
    const n = save(&buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "SECRETS.TXT\t600\t0\tsecret\n") != null);

    // An existing hand-authored entry is upgraded (never downgraded) and the
    // authored owner/spelling survive.
    init();
    _ = load("#v1\nSECRETS.TXT\t600\t1000\t-\n");
    try std.testing.expect(ensure_secret_file());
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "SECRETS.TXT", .read));
    const n2 = save(&buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n2], "SECRETS.TXT\t600\t1000\tsecret\n") != null);
}

test "trust: malformed + unknown-schema lines fail closed on the named path" {
    init();
    // Bad mode, bad uid, bad flags, wrong field count: each poisons its path.
    _ = load("#v1\nbadmode.txt\t999\t1000\t-\nbaduid.txt\t644\tzzz\t-\nbadflag.txt\t644\t1000\tbogus\noneline.txt\n");
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "badmode.txt", .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "baduid.txt", .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "badflag.txt", .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "oneline.txt", .read));
    // Even the privileged actor is denied a poisoned path (fail closed).
    try std.testing.expectEqual(Verdict.eacces, check(actor_system, .host, "badmode.txt", .read));
    // A path NOT listed still gets the default policy (no global poisoning).
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, "fine.txt", .read));

    // Unknown schema: the header is not #v1, so every listed path is poisoned.
    init();
    _ = load("#v2\nfoo.txt\t644\t1000\t-\n");
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "foo.txt", .read));
}

test "trust: group triplet is reserved and normalized to zero" {
    init();
    _ = load("#v1\na.txt\t777\t1000\t-\n");
    var buf: [save_max]u8 = undefined;
    const n = save(&buf);
    // 0777 normalizes to 0707: the group triplet is always zero.
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "a.txt\t707\t1000\t-\n") != null);
    try std.testing.expectEqual(SetResult.ok, set_mode(actor_user, .host, "a.txt", 0o644));
    const n2 = save(&buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n2], "a.txt\t604\t1000\t-\n") != null);
}

test "trust: table-full is ENOSPC on chmod, never silent eviction" {
    init();
    var i: usize = 0;
    while (i < max_entries) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "f{d}.txt", .{i}) catch unreachable;
        try std.testing.expectEqual(SetResult.ok, set_mode(actor_user, .host, name, 0o600));
    }
    try std.testing.expectEqual(@as(usize, max_entries), count());
    // The 65th distinct path cannot mint an entry.
    try std.testing.expectEqual(SetResult.enospc, set_mode(actor_user, .host, "overflow.txt", 0o600));
    // The pre-existing entries were NOT evicted and still hold their mode.
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, "f0.txt", .read));
    // Updating an existing entry still works at capacity.
    try std.testing.expectEqual(SetResult.ok, set_mode(actor_user, .host, "f0.txt", 0o400));
}

test "trust: chmod is owner-only or CAP_FS_ANY (no chown)" {
    init();
    _ = load("#v1\nmine.txt\t644\t1000\t-\ntheirs.txt\t644\t2000\t-\n");
    try std.testing.expectEqual(SetResult.ok, set_mode(actor_user, .host, "mine.txt", 0o600));
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, "mine.txt", .write));
    // A non-owner cannot chmod even a writable file.
    try std.testing.expectEqual(SetResult.eacces, set_mode(actor_user, .host, "theirs.txt", 0o600));
    // CAP_FS_ANY can.
    try std.testing.expectEqual(SetResult.ok, set_mode(actor_system, .host, "theirs.txt", 0o600));
    // Chmod never changes the owner.
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "theirs.txt", .write));
    // Invalid modes and non-mode-governed partitions are refused honestly.
    try std.testing.expectEqual(SetResult.einval, set_mode(actor_user, .host, "mine.txt", 0o7000));
    try std.testing.expectEqual(SetResult.einval, set_mode(actor_user, .tty, "mine.txt", 0o600));
    try std.testing.expectEqual(SetResult.eacces, set_mode(actor_user, .usb, "sector", 0o600));
}

test "trust: OWNERS.TXT round-trip parse/serialize" {
    const src = "#v1\nSECRETS.TXT\t600\t0\tsecret\na.txt\t644\t1000\t-\nsub/b.txt\t755\t1000\t-\n";
    try std.testing.expectEqual(LoadResult.ok, load(src));
    var buf: [save_max]u8 = undefined;
    const n = save(&buf);
    try std.testing.expect(n > 0);
    const out = buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, out, "#v1\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "SECRETS.TXT\t600\t0\tsecret\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a.txt\t604\t1000\t-\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sub/b.txt\t705\t1000\t-\n") != null);
    // Re-loading the serialized form reproduces the same decisions.
    try std.testing.expectEqual(LoadResult.ok, load(out));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "SECRETS.TXT", .read));
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, "a.txt", .read));
}

test "trust: case-insensitive host-share keys cannot bypass an entry (D4 risk)" {
    init();
    // The entry was authored with mixed case; storage preserves the spelling.
    _ = load("#v1\nSecret.TXT\t600\t1000\tsecret\n");
    // Every case variant resolves to the same entry (case-insensitive compare).
    try std.testing.expectEqual(Verdict.eacces, check(actor_system, .host, "SECRET.TXT", .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_system, .host, "secret.txt", .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_system, .host, "Secret.Txt", .read));
    // A genuinely different name is not poisoned.
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, "secret2.txt", .read));
    // Save preserves the authored spelling so the host file is not lower-cased.
    var buf: [save_max]u8 = undefined;
    const n = save(&buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Secret.TXT\t600\t1000\tsecret\n") != null);
}

test "trust: remove and rename_meta keep the table consistent" {
    init();
    _ = load("#v1\na.txt\t600\t1000\t-\nb.txt\t644\t1000\t-\n");
    try std.testing.expectEqual(Verdict.eacces, check(actor_other, .host, "a.txt", .read));
    // Rename a -> c moves the metadata with it.
    try std.testing.expect(rename_meta(.host, "a.txt", .host, "c.txt"));
    try std.testing.expectEqual(Verdict.eacces, check(actor_other, .host, "c.txt", .read));
    try std.testing.expectEqual(Verdict.allow, check(actor_other, .host, "a.txt", .read)); // default now
    // Delete b drops its entry. (+1: the #2083 OWNERS.TXT self row every
    // loaded table carries.)
    try std.testing.expect(remove(.host, "b.txt"));
    try std.testing.expectEqual(@as(usize, 2), count());
}

test "trust: replacement adopts explicit or implicit source metadata" {
    init();
    defer init();
    _ = load("#v1\nstage\t600\t1000\t-\noutput\t606\t0\t-\n");
    try std.testing.expect(rename_meta(.host, "stage", .host, "output"));
    try std.testing.expectEqual(@as(usize, 2), count()); // output + OWNERS.TXT self row
    try std.testing.expectEqual(Verdict.eacces, check(actor_other, .host, "output", .read));
    var buf: [save_max]u8 = undefined;
    const n = save(&buf);
    try std.testing.expectEqualStrings("#v1\noutput\t600\t1000\t-\nOWNERS.TXT\t604\t0\t-\n", buf[0..n]);

    _ = load("#v1\noutput\t600\t1000\t-\n");
    try std.testing.expect(rename_meta(.host, "implicit-stage", .host, "output"));
    try std.testing.expectEqual(@as(usize, 1), count()); // the self row remains
    try std.testing.expectEqual(Verdict.allow, check(actor_other, .host, "output", .read));
    try std.testing.expect(!rename_meta(.host, "implicit-stage", .host, "output"));
}

test "trust: OWNERS.TXT self-protection by construction (#2083)" {
    init();
    // An absent file: the registration still lands — an EL0 process can
    // never author the metadata it would need to forge `system_owned_key`.
    try std.testing.expect(ensure_meta_file());
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, filename, .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, filename, .write));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, filename, .delete));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, filename, .admin));
    // A hand-seeded row naming OWNERS.TXT cannot loosen the self entry:
    // load force-normalizes it (uid_system, no non-owner write).
    try std.testing.expectEqual(LoadResult.ok, load("#v1\nOWNERS.TXT\t666\t1000\t-\n"));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, filename, .write));
    try std.testing.expect(system_owned_key(filename));
    // system_owned_key: absent rows and uid_user rows are never trusted;
    // a uid_system row with an other-write bit is not either.
    init();
    try std.testing.expect(!system_owned_key("NOPE.ELF"));
    _ = load("#v1\nMINE.ELF\t644\t1000\t-\nSYS.ELF\t644\t0\t-\nLOOSE.ELF\t666\t0\t-\n");
    try std.testing.expect(!system_owned_key("MINE.ELF"));
    try std.testing.expect(system_owned_key("SYS.ELF"));
    try std.testing.expect(!system_owned_key("LOOSE.ELF"));
}

test "trust: APPLOG/CRASH labels bind to process identity (#2085)" {
    init();
    process.init();
    const gosh = process.create("GOSH.ELF", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const gosh_actor = Actor{ .uid = process.uid_user, .caps = 0, .pid = gosh, .name = "GOSH.ELF" };
    // The caller's own ring and receipt — name or its ".ELF" stem both bind.
    try std.testing.expectEqual(Verdict.allow, check(gosh_actor, .host, "APPLOG/GOSH.ELF.LOG", .write));
    try std.testing.expectEqual(Verdict.allow, check(gosh_actor, .host, "APPLOG/GOSH.LOG", .write));
    try std.testing.expectEqual(Verdict.allow, check(gosh_actor, .host, "CRASH/GOSH.ELF.TXT", .write));
    try std.testing.expectEqual(Verdict.allow, check(gosh_actor, .host, "APPLOG/GOSH.ELF.LOG", .read));
    // A foreign label is refused for every operation class.
    try std.testing.expectEqual(Verdict.eacces, check(gosh_actor, .host, "APPLOG/VICTIM.ELF.LOG", .write));
    try std.testing.expectEqual(Verdict.eacces, check(gosh_actor, .host, "APPLOG/VICTIM.ELF.LOG", .read));
    try std.testing.expectEqual(Verdict.eacces, check(gosh_actor, .host, "APPLOG/VICTIM.ELF.LOG", .create));
    try std.testing.expectEqual(Verdict.eacces, check(gosh_actor, .host, "APPLOG/VICTIM.ELF.LOG", .delete));
    try std.testing.expectEqual(Verdict.eacces, check(gosh_actor, .host, "CRASH/VICTIM.ELF.TXT", .write));
    try std.testing.expectEqual(Verdict.eacces, check(gosh_actor, .host, "CRASH/VICTIM.ELF.STK", .write));
    // The supervisor carve-out: a row the caller spawned keeps its label
    // authority while the row exists — the spawner field lives on the
    // descriptor and outlives the child's exit by construction.
    const child = process.create("GSCHK.ELF", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    process.set_spawner(child, gosh);
    try std.testing.expectEqual(Verdict.allow, check(gosh_actor, .host, "CRASH/GSCHK.TXT", .write));
    try std.testing.expectEqual(Verdict.allow, check(gosh_actor, .host, "APPLOG/GSCHK.LOG", .read));
    // A same-uid peer that did not spawn the child is still refused.
    const peer = process.create("PEER.ELF", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const peer_actor = Actor{ .uid = process.uid_user, .caps = 0, .pid = peer, .name = "PEER.ELF" };
    try std.testing.expectEqual(Verdict.eacces, check(peer_actor, .host, "CRASH/GSCHK.TXT", .write));
    try std.testing.expectEqual(Verdict.eacces, check(peer_actor, .host, "APPLOG/GSCHK.LOG", .read));
    // Privileged actors (the -u0 viewer channel) bypass the binding.
    try std.testing.expectEqual(Verdict.allow, check(kernel_actor(), .host, "APPLOG/VICTIM.ELF.LOG", .read));
    try std.testing.expectEqual(Verdict.allow, check(kernel_actor(), .host, "CRASH/VICTIM.ELF.TXT", .write));
    // The directory itself is not a labeled file: names stay enumerable.
    try std.testing.expectEqual(Verdict.allow, check(gosh_actor, .host, "APPLOG", .list));
    // chmod on a foreign labelled file is refused too: every diagnostic
    // file is uid_user-owned, so the uid check alone would allow any app
    // to revoke a victim's access to its own ring.
    _ = load("#v1\nAPPLOG/VICTIM.LOG\t664\t1000\t-\n");
    try std.testing.expectEqual(SetResult.eacces, set_mode(gosh_actor, .host, "APPLOG/VICTIM.LOG", 0o000));
    try std.testing.expectEqual(SetResult.ok, set_mode(gosh_actor, .host, "APPLOG/GOSH.LOG", 0o600));
    // Nested paths are not labelled files: the overlay stays out of them.
    try std.testing.expectEqual(Verdict.allow, check(gosh_actor, .host, "APPLOG/SUB/VICTIM.LOG", .write));
    process.init();
}

test "trust: over-long paths never falsely match a short entry" {
    init();
    _ = load("#v1\na.txt\t600\t1000\t-\n");
    // A path longer than the 64-byte key window cannot equal a stored key.
    var long_buf: [88]u8 = undefined;
    @memcpy(long_buf[0..5], "a.txt");
    @memset(long_buf[5..], 'x');
    try std.testing.expectEqual(Verdict.allow, check(actor_other, .host, long_buf[0..], .read));
}

test "trust: agent roots minted as uid_agent, forced over authored rows (M173b #3041)" {
    init();
    try std.testing.expect(ensure_agent_roots());
    try std.testing.expectEqual(@as(usize, 2), count());
    const agent = Actor{ .uid = process.uid_agent, .caps = 0 };
    // Agent owns its roots as owner; the user reads through the other triplet.
    try std.testing.expectEqual(Verdict.allow, check(agent, .host, "AGENT", .write));
    try std.testing.expectEqual(Verdict.allow, check(agent, .host, "AGENT/AUDIT", .list));
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, "AGENT", .list));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "AGENT", .write));
    // An authored row naming AGENT cannot loosen/steal the agent's ownership.
    init();
    _ = load("#v1\nAGENT\t777\t1000\t-\n");
    try std.testing.expect(ensure_agent_roots());
    try std.testing.expectEqual(Verdict.allow, check(agent, .host, "AGENT", .write));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "AGENT", .write));
    // A hand-seeded write under the audit dir stays refused for the user.
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "AGENT/AUDIT", .create));
}

test "trust: unlisted paths under an agent-owned ancestor are agent-owned (M173b #3041)" {
    init();
    try std.testing.expect(ensure_agent_roots());
    const agent = Actor{ .uid = process.uid_agent, .caps = 0 };
    // The agent creates and writes inside its roots without per-file rows.
    try std.testing.expectEqual(Verdict.allow, check(agent, .host, "AGENT/OUT.TXT", .create));
    try std.testing.expectEqual(Verdict.allow, check(agent, .host, "AGENT/AUDIT/RCPT-00000001", .create));
    try std.testing.expectEqual(Verdict.allow, check(agent, .host, "AGENT/OUT.TXT", .write));
    // The user keeps other-triplet read, never write, inside the agent's roots.
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, "AGENT/OUT.TXT", .read));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "AGENT/OUT.TXT", .write));
    try std.testing.expectEqual(Verdict.eacces, check(actor_user, .host, "AGENT/OUT.TXT", .create));
    // Agent admin on its own subtree entry (chmod mint carries uid_agent).
    try std.testing.expectEqual(SetResult.ok, set_mode(agent, .host, "AGENT/OUT.TXT", 0o600));
    // Everything outside the agent roots keeps the uid_user default, unchanged.
    try std.testing.expectEqual(Verdict.allow, check(actor_user, .host, "PLAIN.TXT", .write));
    try std.testing.expectEqual(Verdict.eacces, check(agent, .host, "PLAIN.TXT", .write));
    // A non-agent owned ancestor changes nothing below it (load() clears
    // and repopulates — boot mints the agent rows AFTER the file load).
    _ = load("#v1\nSYSROOT\t755\t0\t-\n");
    try std.testing.expect(ensure_agent_roots());
    try std.testing.expectEqual(process.uid_user, defaultOwner(.host, "SYSROOT/CHILD.TXT"));
    try std.testing.expectEqual(process.uid_agent, defaultOwner(.host, "AGENT/CHILD.TXT"));
    // The two roots are the only rows inside the 64-entry bound.
    try std.testing.expectEqual(@as(usize, 4), count()); // 2 roots + OWNERS.TXT self + SYSROOT
}

test "trust: ensure_agent_roots respects the 64-entry bound (M173b #3041)" {
    init();
    var i: usize = 0;
    while (i < max_entries) : (i += 1) {
        var nb: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "f{d}.txt", .{i}) catch unreachable;
        try std.testing.expectEqual(SetResult.ok, set_mode(actor_user, .host, name, 0o600));
    }
    try std.testing.expect(!ensure_agent_roots());
}
