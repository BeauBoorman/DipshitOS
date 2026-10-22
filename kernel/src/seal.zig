//! seal.zig — the VLFS v2 sealed-volume layer (M172d, issue #3037; ADR
//! 0061).
//!
//! **What this is.** The mount half of the sealed format: `unwrapDek`
//! runs the passphrase → KEK → DEK unwrap (PBKDF2-HMAC-SHA256 in kdf.zig,
//! ChaCha20-Poly1305 in aead.zig, both M172b), `unseal` drives the boot
//! prompt's five-attempt budget and 120 s idle timeout, and `Seal`
//! presents the armed volume as a `vlfs.SectorSource` whose block-level
//! hooks run every block in the sealed span [2, tag_first) through AEAD
//! with its tag-region entry. The superblock pair and the tag region
//! itself stay plaintext (ADR 0061 — nonces and tags are public).
//!
//! **I/O hooks, not a fork.** `vlfs.SectorSource` carries optional
//! readBlock/writeBlock/err hooks; this module is the only producer of
//! them. On a sealed write the hook draws a fresh 96-bit nonce per block
//! (never reused under one DEK — a rewrite gets a new nonce too), seals
//! the block, writes the ciphertext home, then records {nonce, tag} in
//! the tag entry at slot b−2. Tag homes are plaintext blocks written
//! through the inner source directly (the ADR's single non-recursive
//! exception); a torn pair reads back as bad_block_auth, never wrong
//! plaintext, and the journal replays over it the same way v1 recovers.
//!
//! **Journaled tag blocks (#3104).** The eager paragraph above now holds
//! only for journal records (a record must authenticate before the
//! transaction carrying it can replay). A home write — anything at or
//! above `journal_end` — is a txn checkpoint write: the write path
//! stages each sealed dest's {nonce, tag} at append time, appends the
//! updated tag homes as payloads of the same transaction, and the
//! checkpoint's writeBlock lands exactly the staged ciphertext. A
//! mid-checkpoint kill therefore replays payload and tag as one pair —
//! it can no longer leave a bad_block_auth home the replay tolerates
//! but --check flags. A staged-miss home write falls back to the eager
//! pair (the test seam; a crafted or pre-M172f transaction).
//!
//! **No allocation, no libc, no POSIX.** All buffers are fixed BSS/ctx
//! fields; the passphrase buffer is zeroed after every attempt (D10).
//! Every host-facing dependency — console write/read, the monotonic
//! clock, the nonce CSPRNG — is injected through `PromptOps`/`nonceFn`
//! so the module unit-tests on the host against an in-memory image.

const std = @import("std");
const vlfs = @import("vlfs/vlfs.zig");
const aead = @import("aead.zig");
const kdf = @import("kdf.zig");

pub const dek_len: usize = aead.key_len;
/// The sentinel block number in the DEK wrap's AAD — the same
/// volume_id‖block shape as sealed-block AAD but no real block can claim
/// it (tools/go/vlfs agrees: wrapBlockNum = 0xFFFFFFFF).
pub const wrap_block_num: u32 = 0xFFFFFFFF;

pub const max_attempts: u32 = 5;
/// The idle budget: 120 s without an input byte ends unsealing (D10).
pub const idle_secs: u32 = 120;
/// Passphrase line bound; a longer line is truncated to this and read to
/// its end (the unwrap then fails honestly — it is not the passphrase).
pub const pass_max: usize = 127;

// ---------------------------------------------------------------------------
// The block AAD (ADR 0061 D9): volume UUID ‖ block number, little-endian —
// a tag verifies only at this position in this volume.
// ---------------------------------------------------------------------------

fn blockAad(volume_id: u64, blk: u32) [12]u8 {
    var aad: [12]u8 = undefined;
    std.mem.writeInt(u64, aad[0..8], volume_id, .little);
    std.mem.writeInt(u32, aad[8..12], blk, .little);
    return aad;
}

/// The DEK unwrap: PBKDF2 over the passphrase into a KEK, then one AEAD
/// open of the wrapped DEK. A wrong passphrase and a corrupt wrap are the
/// same honest failure — authentication fails, nothing is released
/// (returns false, `dek` untouched, the KEK zeroed).
pub fn unwrapDek(info: vlfs.SealInfo, volume_id: u64, pass: []const u8, dek: *[dek_len]u8) bool {
    var kek: [dek_len]u8 = undefined;
    defer @memset(&kek, 0);
    kdf.pbkdf2_hmac_sha256(pass, &info.salt, info.kdf_iters, &kek);
    const aad = blockAad(volume_id, wrap_block_num);
    return aead.open(dek, &info.wrapped_dek, &info.wrap_tag, &aad, &info.wrap_nonce, &kek);
}

// ---------------------------------------------------------------------------
// Seal — the armed volume context behind the sealed SectorSource
// ---------------------------------------------------------------------------

/// A tag entry staged for a txn's sealed dest: the {nonce, tag} the
/// checkpoint's home write must land so the journaled tag block —
/// appended to the same transaction — verifies it (ADR 0061, #3104).
const StagedEntry = struct { dest: u32, nonce: [aead.nonce_len]u8, tag: [aead.tag_len]u8 };

pub const Seal = struct {
    inner: vlfs.SectorSource,
    dek: [dek_len]u8 = @splat(0),
    volume_id: u64 = 0,
    volume_blocks: u32 = 0,
    tag_first: u32 = 0,
    /// End of the journal region (= ibitmap_first): sealed writes below
    /// it are journal records, whose tag entries update eagerly — a
    /// record must authenticate before the transaction carrying it can
    /// replay — while writes at/above it are txn checkpoint homes whose
    /// entries ride in the journaled tag blocks (ADR 0061, #3104).
    journal_end: u32 = 0,
    /// Staged tag entries for the in-flight transaction, one per dest,
    /// bounded by max_payload; cleared at txn boundaries and drained by
    /// the checkpoint's writeBlock calls.
    staged: [vlfs.max_payload]StagedEntry = undefined,
    staged_n: u32 = 0,
    /// Block-write nonce source (kernel CSPRNG on hardware; tests inject
    /// deterministic nonces to pin vectors).
    nonceFn: *const fn (ctx: ?*anyopaque, out: *[aead.nonce_len]u8) void = undefined,
    nonceCtx: ?*anyopaque = null,
    /// Named reason for the last failed block op (blockError surface).
    fail: vlfs.Error = error.Io,
    /// Authentication failures seen on this mount — evidence a tampered
    /// or torn ciphertext was refused, never served.
    auth_failures: u64 = 0,
    raw: [vlfs.block_len]u8 align(64) = undefined, // ciphertext scratch
    tagblk: [vlfs.block_len]u8 align(64) = undefined, // tag-home scratch
    blkbuf: [vlfs.block_len]u8 align(64) = undefined, // sector-view scratch

    /// True when block `blk` lives inside the sealed span [2, tag_first).
    pub fn sealed(self: *const Seal, blk: u32) bool {
        return blk >= 2 and blk < self.tag_first;
    }

    /// Zero the DEK and the scratch blocks — detach/refusal paths wipe so
    /// the key lives in RAM only for the life of the mount (D9).
    pub fn wipe(self: *Seal) void {
        @memset(&self.dek, 0);
        @memset(&self.raw, 0);
        @memset(&self.blkbuf, 0);
        self.tag_first = 0;
        self.staged_n = 0;
    }
};

fn sealErr(ctx: ?*anyopaque) vlfs.Error {
    const s: *Seal = @ptrCast(@alignCast(ctx orelse return error.Io));
    return s.fail;
}

fn tagHome(slot: u32, s: *const Seal) struct { blk: u32, off: usize } {
    return .{
        .blk = s.tag_first + slot / vlfs.tag_entries_per_block,
        .off = (slot % vlfs.tag_entries_per_block) * vlfs.tag_entry_len,
    };
}

fn sealReadBlock(ctx: ?*anyopaque, blk: u32, out: *[vlfs.block_len]u8) bool {
    const s: *Seal = @ptrCast(@alignCast(ctx orelse return false));
    s.fail = error.Io;
    if (!s.sealed(blk)) {
        if (!s.inner.readBlock(blk, out)) {
            s.fail = error.Io;
            return false;
        }
        return true;
    }
    if (blk >= s.volume_blocks or !s.inner.readBlock(blk, &s.raw)) {
        s.fail = error.Io;
        return false;
    }
    const t = tagHome(blk - 2, s);
    if (!s.inner.readBlock(t.blk, &s.tagblk)) {
        s.fail = error.Io;
        return false;
    }
    const nonce: *const [aead.nonce_len]u8 = s.tagblk[t.off..][0..aead.nonce_len];
    const tag: *const [aead.tag_len]u8 = s.tagblk[t.off + aead.nonce_len ..][0..aead.tag_len];
    const aad = blockAad(s.volume_id, blk);
    if (!aead.open(out, &s.raw, tag, &aad, nonce, &s.dek)) {
        s.fail = error.BadBlockAuth;
        s.auth_failures += 1;
        return false;
    }
    return true;
}

fn stagedFind(s: *Seal, dest: u32) ?usize {
    for (s.staged[0..s.staged_n], 0..) |*e, i| {
        if (e.dest == dest) return i;
    }
    return null;
}

fn sealWriteBlock(ctx: ?*anyopaque, blk: u32, data: *const [vlfs.block_len]u8) bool {
    const s: *Seal = @ptrCast(@alignCast(ctx orelse return false));
    s.fail = error.Io;
    if (!s.sealed(blk)) {
        if (!s.inner.writeBlock(blk, data)) {
            s.fail = error.Io;
            return false;
        }
        return true;
    }
    if (blk >= s.journal_end) {
        // A txn checkpoint home: the transaction carrying this dest
        // already committed the {nonce, tag} pair in its journaled tag
        // blocks — land exactly that ciphertext. A re-read payload
        // re-seals identically; a mismatch is corruption, refused by
        // name, never written.
        if (stagedFind(s, blk)) |idx| {
            const e = &s.staged[idx];
            const aad = blockAad(s.volume_id, blk);
            var tag: [aead.tag_len]u8 = undefined;
            aead.seal(&s.raw, &tag, data, &aad, &e.nonce, &s.dek);
            if (!std.mem.eql(u8, &tag, &e.tag)) {
                s.fail = error.BadBlockAuth;
                s.auth_failures += 1;
                return false;
            }
            if (!s.inner.writeBlock(blk, &s.raw)) {
                s.fail = error.Io;
                return false;
            }
            s.staged[idx] = s.staged[s.staged_n - 1];
            s.staged_n -= 1;
            return true;
        }
        // No staged entry: a non-txn home write (the test seam, a
        // crafted or pre-M172f transaction without tag payloads) falls
        // back to the eager pair below — consistent, just not covered
        // by a journal commit.
    }
    // Journal records (below journal_end) and the eager fallback share
    // this path: a fresh random nonce on EVERY write — including
    // rewrites of the same block (D9's never-repeat rule under one DEK).
    var nonce: [aead.nonce_len]u8 = undefined;
    s.nonceFn(s.nonceCtx, &nonce);
    const aad = blockAad(s.volume_id, blk);
    var tag: [aead.tag_len]u8 = undefined;
    aead.seal(&s.raw, &tag, data, &aad, &nonce, &s.dek);
    if (!s.inner.writeBlock(blk, &s.raw)) {
        s.fail = error.Io;
        return false;
    }
    // The tag entry is a plaintext home block; a torn pair (ciphertext
    // without its entry or vice versa) reads back as bad_block_auth and
    // the journal replays over it — never wrong plaintext.
    const t = tagHome(blk - 2, s);
    if (!s.inner.readBlock(t.blk, &s.tagblk)) {
        s.fail = error.Io;
        return false;
    }
    @memcpy(s.tagblk[t.off..][0..aead.nonce_len], &nonce);
    @memcpy(s.tagblk[t.off + aead.nonce_len ..][0..aead.tag_len], &tag);
    if (!s.inner.writeBlock(t.blk, &s.tagblk)) {
        s.fail = error.Io;
        return false;
    }
    return true;
}

fn sealReadSector(ctx: ?*anyopaque, lba: u64, out: *[vlfs.sector_len]u8) bool {
    const s: *Seal = @ptrCast(@alignCast(ctx orelse return false));
    const blk: u32 = @intCast(lba / vlfs.sectors_per_block);
    if (!s.sealed(blk)) return s.inner.readSector(lba, out);
    // A sector read inside the sealed span is a block open plus a slice —
    // the mount probe only exercises this on superblock sectors (blocks
    // 0–1, plaintext), but the path is correct anywhere.
    if (!sealReadBlock(ctx, blk, &s.blkbuf)) return false;
    const sub: usize = @intCast(lba % vlfs.sectors_per_block);
    @memcpy(out, s.blkbuf[sub * vlfs.sector_len ..][0..vlfs.sector_len]);
    return true;
}

fn sealWriteSector(ctx: ?*anyopaque, lba: u64, data: *const [vlfs.sector_len]u8) bool {
    const s: *Seal = @ptrCast(@alignCast(ctx orelse return false));
    const blk: u32 = @intCast(lba / vlfs.sectors_per_block);
    if (!s.sealed(blk)) {
        const w = s.inner.writeFn orelse return false;
        return w(s.inner.ctx, lba, data);
    }
    // Sub-block write inside the span: read-modify-write through the
    // block hook (fresh nonce, updated tag entry).
    if (!sealReadBlock(ctx, blk, &s.blkbuf)) return false;
    const sub: usize = @intCast(lba % vlfs.sectors_per_block);
    @memcpy(s.blkbuf[sub * vlfs.sector_len ..][0..vlfs.sector_len], data);
    return sealWriteBlock(ctx, blk, &s.blkbuf);
}

fn sealFlush(ctx: ?*anyopaque) bool {
    const s: *Seal = @ptrCast(@alignCast(ctx orelse return false));
    return s.inner.flush();
}

// ---------------------------------------------------------------------------
// The sealed-txn hooks (ADR 0061, #3104): stageBlock draws the nonce a home
// write must land and returns the tag home the pair belongs to — the write
// path then journals that home as a payload of the same transaction.
// applyStaged writes the staged entries living in one tag home into its
// updated contents; injectEntry replants a journaled entry for the replay's
// writeBlock; clearStaged drops the set at a txn boundary. Only txn
// checkpoint homes stage — journal records keep eager entries because a
// record must authenticate before the transaction carrying it can replay.
// ---------------------------------------------------------------------------

fn sealStageBlock(ctx: ?*anyopaque, dest: u32, contents: *const [vlfs.block_len]u8) u32 {
    const s: *Seal = @ptrCast(@alignCast(ctx orelse return 0));
    if (!s.sealed(dest) or dest < s.journal_end) return 0;
    const idx = stagedFind(s, dest) orelse blk: {
        if (s.staged_n >= s.staged.len) return 0; // unreachable: ≤ max_payload dests
        const i = s.staged_n;
        s.staged_n += 1;
        break :blk i;
    };
    const e = &s.staged[idx];
    e.dest = dest;
    s.nonceFn(s.nonceCtx, &e.nonce);
    const aad = blockAad(s.volume_id, dest);
    aead.seal(&s.raw, &e.tag, contents, &aad, &e.nonce, &s.dek);
    return tagHome(dest - 2, s).blk;
}

fn sealApplyStaged(ctx: ?*anyopaque, home: u32, tagblk: *[vlfs.block_len]u8) u32 {
    const s: *Seal = @ptrCast(@alignCast(ctx orelse return 0));
    var n: u32 = 0;
    for (s.staged[0..s.staged_n]) |*e| {
        const t = tagHome(e.dest - 2, s);
        if (t.blk != home) continue;
        @memcpy(tagblk[t.off..][0..aead.nonce_len], &e.nonce);
        @memcpy(tagblk[t.off + aead.nonce_len ..][0..aead.tag_len], &e.tag);
        n += 1;
    }
    return n;
}

fn sealInjectEntry(ctx: ?*anyopaque, dest: u32, entry: *const [vlfs.tag_entry_len]u8) void {
    const s: *Seal = @ptrCast(@alignCast(ctx orelse return));
    const idx = stagedFind(s, dest) orelse blk: {
        if (s.staged_n >= s.staged.len) return; // unreachable: ≤ max_payload dests
        const i = s.staged_n;
        s.staged_n += 1;
        break :blk i;
    };
    s.staged[idx].dest = dest;
    @memcpy(&s.staged[idx].nonce, entry[0..aead.nonce_len]);
    @memcpy(&s.staged[idx].tag, entry[aead.nonce_len..][0..aead.tag_len]);
}

fn sealClearStaged(ctx: ?*anyopaque) void {
    const s: *Seal = @ptrCast(@alignCast(ctx orelse return));
    s.staged_n = 0;
}

/// The armed seal as a SectorSource: same wire shape as the inner source,
/// with the block hooks running AEAD over the sealed span.
pub fn source(s: *Seal) vlfs.SectorSource {
    return .{
        .ctx = s,
        .total_sectors = s.inner.total_sectors,
        .readFn = sealReadSector,
        .writeFn = if (s.inner.writeFn != null) sealWriteSector else null,
        .flushFn = if (s.inner.flushFn != null) sealFlush else null,
        .readBlockFn = sealReadBlock,
        .writeBlockFn = if (s.inner.writeFn != null) sealWriteBlock else null,
        .errFn = sealErr,
        .stageBlockFn = sealStageBlock,
        .applyStagedFn = sealApplyStaged,
        .injectEntryFn = sealInjectEntry,
        .clearStagedFn = sealClearStaged,
    };
}

// ---------------------------------------------------------------------------
// unseal — the boot prompt's attempt budget, idle timeout, and named lines
// ---------------------------------------------------------------------------

/// The console/entropy/clock surface the prompt needs — injected so the
/// kernel wires uart_puts + virtio_console RX + CNTPCT + csprng in
/// main.zig and tests wire a scripted session. `writeFn` emits only the
/// prompt and the named outcome lines: input bytes are never written
/// back (the prompt is echo-suppressed by construction).
pub const PromptOps = struct {
    ctx: ?*anyopaque = null,
    writeFn: *const fn (ctx: ?*anyopaque, bytes: []const u8) void,
    /// One input byte or null — non-blocking.
    readByteFn: *const fn (ctx: ?*anyopaque) ?u8,
    /// True when an input path is armed; false means the prompt can never
    /// be answered and the mount skips the wait (share-only, named).
    armedFn: *const fn (ctx: ?*anyopaque) bool,
    /// Monotonic counter at `hz` ticks per second.
    nowFn: *const fn (ctx: ?*anyopaque) u64,
    hz: u64,
    /// Block-write nonce source and its readiness — an unseeded CSPRNG
    /// refuses the sealed mount outright (D9: a deterministic stream
    /// would repeat nonces).
    nonceFn: *const fn (ctx: ?*anyopaque, out: *[aead.nonce_len]u8) void,
    rngReadyFn: *const fn (ctx: ?*anyopaque) bool,
};

/// What the prompt's run produced — the serial line for each outcome is
/// the card's named evidence.
pub const Outcome = enum {
    /// `vlfs: sealed — unsealed` — the DEK is armed in the Seal.
    unsealed,
    /// `vlfs: sealed — locked out, /disk not mounted` — five failed
    /// unwraps; the budget for this boot is spent.
    locked_out,
    /// `vlfs: sealed — no passphrase, /disk not mounted` — 120 s idle,
    /// or no input path at all.
    no_passphrase,
    /// `vlfs: sealed — no entropy, /disk not mounted` — unseeded CSPRNG.
    no_entropy,
};

fn write(ops: *const PromptOps, bytes: []const u8) void {
    ops.writeFn(ops.ctx, bytes);
}

/// Read one passphrase line: bytes until CR or LF, echo-suppressed, the
/// buffer zeroed by the caller afterwards. Returns the line, or null
/// when the idle deadline (idle_secs of no input) fires first. A CR/LF
/// pair is one terminator, not two attempts.
fn readLine(ops: *const PromptOps, buf: *[pass_max]u8, deadline_ticks: u64, skip_lf: *bool) ?[]u8 {
    var len: usize = 0;
    var deadline = ops.nowFn(ops.ctx) + deadline_ticks;
    while (true) {
        if (ops.readByteFn(ops.ctx)) |b| {
            deadline = ops.nowFn(ops.ctx) + deadline_ticks; // any byte resets the idle clock
            if (b == '\r' or b == '\n') {
                if (len == 0 and b == '\n' and skip_lf.*) {
                    skip_lf.* = false;
                    continue;
                }
                skip_lf.* = (b == '\r');
                write(ops, "\n"); // a line break only — the input itself is never echoed
                return buf[0..len];
            }
            skip_lf.* = false;
            if (b == 0x08 or b == 0x7f) {
                if (len > 0) len -= 1;
                continue;
            }
            if (len < pass_max) {
                buf[len] = b;
                len += 1;
            }
            continue;
        }
        if (ops.nowFn(ops.ctx) >= deadline) return null;
    }
}

/// Drive the boot prompt: up to max_attempts line reads, each a PBKDF2 +
/// AEAD unwrap; the named outcomes go to the console as they happen.
/// On .unsealed the Seal is armed (dek, geometry, nonceFn) — the caller
/// mounts through `source(&s)`.
pub fn unseal(s: *Seal, inner: vlfs.SectorSource, sb: vlfs.Superblock, info: vlfs.SealInfo, ops: *const PromptOps) Outcome {
    if (!ops.rngReadyFn(ops.ctx)) {
        write(ops, "vlfs: sealed — no entropy, /disk not mounted\n");
        return .no_entropy;
    }
    if (!ops.armedFn(ops.ctx)) {
        write(ops, "vlfs: sealed — no passphrase, /disk not mounted\n");
        return .no_passphrase;
    }
    var buf: [pass_max]u8 = undefined;
    defer @memset(&buf, 0);
    const deadline_ticks = @as(u64, idle_secs) * ops.hz;
    var skip_lf = false;
    var left: u32 = max_attempts;
    while (left > 0) {
        write(ops, "vlfs: sealed — passphrase: ");
        const line = readLine(ops, &buf, deadline_ticks, &skip_lf) orelse {
            write(ops, "vlfs: sealed — no passphrase, /disk not mounted\n");
            return .no_passphrase;
        };
        var dek: [dek_len]u8 = undefined;
        if (unwrapDek(info, sb.volume_id, line, &dek)) {
            s.* = .{
                .inner = inner,
                .dek = dek,
                .volume_id = sb.volume_id,
                .volume_blocks = sb.volume_blocks,
                .tag_first = info.tag_first,
                .journal_end = sb.ibitmap_first,
                .nonceFn = ops.nonceFn,
                .nonceCtx = ops.ctx,
            };
            @memset(&buf, 0); // the passphrase leaves RAM here (D10)
            write(ops, "vlfs: sealed — unsealed\n");
            return .unsealed;
        }
        @memset(&dek, 0);
        left -= 1;
        if (left == 0) {
            write(ops, "vlfs: sealed — locked out, /disk not mounted\n");
            return .locked_out;
        }
        write(ops, "vlfs: sealed — wrong passphrase (");
        var digits: [10]u8 = undefined;
        const ds = std.fmt.bufPrint(&digits, "{}", .{left}) catch "?";
        write(ops, ds);
        write(ops, " left)\n");
    }
    unreachable;
}

// ---------------------------------------------------------------------------
// Host tests — unwrap KAT, tamper refusal, nonce freshness, lockout, and a
// full sealed mount over an in-memory image.
// ---------------------------------------------------------------------------

const MemDisk = struct {
    img: []u8,
    fn readFn(ctx: ?*anyopaque, lba: u64, out: *[vlfs.sector_len]u8) bool {
        const d: *MemDisk = @ptrCast(@alignCast(ctx));
        if (lba >= d.img.len / vlfs.sector_len) return false;
        @memcpy(out, d.img[lba * vlfs.sector_len ..][0..vlfs.sector_len]);
        return true;
    }
    fn writeFn(ctx: ?*anyopaque, lba: u64, data: *const [vlfs.sector_len]u8) bool {
        const d: *MemDisk = @ptrCast(@alignCast(ctx));
        if (lba >= d.img.len / vlfs.sector_len) return false;
        @memcpy(d.img[lba * vlfs.sector_len ..][0..vlfs.sector_len], data);
        return true;
    }
    fn flushFn(_: ?*anyopaque) bool {
        return true;
    }
    fn rw(self: *MemDisk) vlfs.SectorSource {
        return .{ .ctx = self, .total_sectors = @intCast(self.img.len / vlfs.sector_len), .readFn = readFn, .writeFn = writeFn, .flushFn = flushFn };
    }
};

var test_nonce_ctr: u64 = 0;
fn testNonce(_: ?*anyopaque, out: *[aead.nonce_len]u8) void {
    test_nonce_ctr += 1;
    @memset(out, 0);
    std.mem.writeInt(u64, out[0..8], test_nonce_ctr, .little);
}

fn makeSeal(volume_id: u64, volume_blocks: u32, tag_first: u32, inner: vlfs.SectorSource) Seal {
    var dek: [dek_len]u8 = undefined;
    for (&dek, 0..) |*b, i| b.* = @intCast(i * 7 + 1);
    return .{ .inner = inner, .dek = dek, .volume_id = volume_id, .volume_blocks = volume_blocks, .tag_first = tag_first, .nonceFn = testNonce };
}

test "seal: unwrapDek round-trips the mkfs wrap and refuses wrong pass/tamper" {
    const volume_id: u64 = 0x5eed5eed;
    var dek: [dek_len]u8 = undefined;
    for (&dek, 0..) |*b, i| b.* = @intCast(i +% 3);
    var info = vlfs.SealInfo{
        .kdf_iters = 512,
        .salt = @splat(0xAB),
        .wrap_nonce = @splat(0xCD),
        .wrapped_dek = undefined,
        .wrap_tag = undefined,
        .tag_first = 0,
        .tag_blocks = 0,
    };
    var kek: [dek_len]u8 = undefined;
    kdf.pbkdf2_hmac_sha256("correct horse", &info.salt, info.kdf_iters, &kek);
    const aad = blockAad(volume_id, wrap_block_num);
    aead.seal(&info.wrapped_dek, &info.wrap_tag, &dek, &aad, &info.wrap_nonce, &kek);
    @memset(&kek, 0);

    var out: [dek_len]u8 = undefined;
    try std.testing.expect(unwrapDek(info, volume_id, "correct horse", &out));
    try std.testing.expectEqualSlices(u8, &dek, &out);
    // Wrong passphrase is the same honest refusal as a corrupt wrap.
    try std.testing.expect(!unwrapDek(info, volume_id, "wrong horse", &out));
    info.wrapped_dek[7] ^= 1;
    try std.testing.expect(!unwrapDek(info, volume_id, "correct horse", &out));
    // AAD binds the wrap to this volume: a foreign volume_id refuses.
    try std.testing.expect(!unwrapDek(info, volume_id ^ 1, "correct horse", &out));
}

test "seal: block seal/open round-trip, tag entry, tamper -> bad_block_auth" {
    var img: [8 * vlfs.block_len]u8 = @splat(0);
    var disk = MemDisk{ .img = &img };
    var s = makeSeal(0x55, 8, 7, disk.rw()); // sealed span [2,7), tag home 7
    const src = source(&s);

    var pt: [vlfs.block_len]u8 = @splat(0);
    pt[0] = 'V';
    pt[1] = 'L';
    pt[4095] = 0x5A;
    try std.testing.expect(src.writeBlock(3, &pt));
    // The home block is ciphertext, not the plaintext.
    try std.testing.expect(!std.mem.eql(u8, img[3 * vlfs.block_len ..][0..4], pt[0..4]));
    // The tag entry for block 3 is slot 1 of tag home 7.
    const n_off = 1 * vlfs.tag_entry_len;
    var out: [vlfs.block_len]u8 = undefined;
    try std.testing.expect(src.readBlock(3, &out));
    try std.testing.expectEqualSlices(u8, &pt, &out);
    _ = n_off;

    // A flipped ciphertext bit refuses by name and serves nothing.
    img[3 * vlfs.block_len + 100] ^= 1;
    try std.testing.expect(!src.readBlock(3, &out));
    try std.testing.expectEqual(error.BadBlockAuth, src.blockError());
    try std.testing.expectEqual(@as(u64, 1), s.auth_failures);

    // Plaintext regions pass through untouched: superblocks + tag region.
    var sb0: [vlfs.block_len]u8 = @splat(0xA5);
    try std.testing.expect(src.writeBlock(0, &sb0));
    try std.testing.expectEqualSlices(u8, &sb0, img[0..vlfs.block_len]);
    try std.testing.expect(src.readBlock(0, &out));
    try std.testing.expectEqualSlices(u8, &sb0, &out);
}

test "seal: fresh nonce on every write — a rewrite never reuses one" {
    var img: [8 * vlfs.block_len]u8 = @splat(0);
    var disk = MemDisk{ .img = &img };
    var s = makeSeal(0x55, 8, 7, disk.rw());
    const src = source(&s);
    test_nonce_ctr = 0;

    var pt: [vlfs.block_len]u8 = @splat(0x11);
    try std.testing.expect(src.writeBlock(4, &pt));
    const first_nonce = img[7 * vlfs.block_len + (4 - 2) * vlfs.tag_entry_len ..][0..aead.nonce_len].*;
    pt[0] ^= 1;
    try std.testing.expect(src.writeBlock(4, &pt));
    const second_nonce = img[7 * vlfs.block_len + (4 - 2) * vlfs.tag_entry_len ..][0..aead.nonce_len].*;
    try std.testing.expect(!std.mem.eql(u8, &first_nonce, &second_nonce));
}

// Scripted prompt session for the unseal tests.
const FakePrompt = struct {
    input: []const u8 = "",
    pos: usize = 0,
    out: std.ArrayList(u8),
    now: u64 = 0,
    armed: bool = true,
    rng_ready: bool = true,

    fn writeFn(ctx: ?*anyopaque, bytes: []const u8) void {
        const p: *FakePrompt = @ptrCast(@alignCast(ctx));
        p.out.appendSlice(std.testing.allocator, bytes) catch unreachable;
    }
    fn readByteFn(ctx: ?*anyopaque) ?u8 {
        const p: *FakePrompt = @ptrCast(@alignCast(ctx));
        // Advance the fake clock once per empty poll so the idle deadline
        // is reachable in tests (one poll == one tick at hz=1).
        if (p.pos >= p.input.len) {
            p.now += 1;
            return null;
        }
        const b = p.input[p.pos];
        p.pos += 1;
        return b;
    }
    fn armedFn(ctx: ?*anyopaque) bool {
        return @as(*FakePrompt, @ptrCast(@alignCast(ctx))).armed;
    }
    fn nowFn(ctx: ?*anyopaque) u64 {
        return @as(*FakePrompt, @ptrCast(@alignCast(ctx))).now;
    }
    fn nonceFn(ctx: ?*anyopaque, out: *[aead.nonce_len]u8) void {
        _ = ctx;
        testNonce(null, out);
    }
    fn rngReadyFn(ctx: ?*anyopaque) bool {
        return @as(*FakePrompt, @ptrCast(@alignCast(ctx))).rng_ready;
    }
    fn ops(self: *FakePrompt) PromptOps {
        return .{ .ctx = self, .writeFn = writeFn, .readByteFn = readByteFn, .armedFn = armedFn, .nowFn = nowFn, .hz = 1, .nonceFn = nonceFn, .rngReadyFn = rngReadyFn };
    }
};

fn wrapInfo(volume_id: u64, pass: []const u8, iters: u32) vlfs.SealInfo {
    var info = vlfs.SealInfo{
        .kdf_iters = iters,
        .salt = @splat(7),
        .wrap_nonce = @splat(9),
        .wrapped_dek = undefined,
        .wrap_tag = undefined,
        .tag_first = 0,
        .tag_blocks = 0,
    };
    var dek: [dek_len]u8 = @splat(0x42);
    var kek: [dek_len]u8 = undefined;
    kdf.pbkdf2_hmac_sha256(pass, &info.salt, info.kdf_iters, &kek);
    const aad = blockAad(volume_id, wrap_block_num);
    aead.seal(&info.wrapped_dek, &info.wrap_tag, &dek, &aad, &info.wrap_nonce, &kek);
    return info;
}

fn fakeSb(volume_id: u64) vlfs.Superblock {
    return .{
        .seq = 2,
        .volume_id = volume_id,
        .volume_bytes = 16 << 20,
        .volume_blocks = 4096,
        .journal_first = 2,
        .journal_blocks = 512,
        .ibitmap_first = 514,
        .ibitmap_blocks = 1,
        .bbitmap_first = 515,
        .bbitmap_blocks = 1,
        .itable_first = 516,
        .itable_blocks = 8,
        .data_first = 524,
        .data_blocks = 3544,
        .inode_count = 256,
        .journal_applied = 0,
        .next_txn_seq = 1,
        .slot = 0,
        .seal = null,
    };
}

test "seal: unseal arms on the right passphrase; wrong lines count the budget" {
    var img: [vlfs.block_len]u8 = @splat(0);
    var disk = MemDisk{ .img = &img };
    var p = FakePrompt{ .input = "wrong-1\nwrong-2\nright-pass\n", .out = .empty };
    defer p.out.deinit(std.testing.allocator);
    var s: Seal = undefined;
    var ops = p.ops();
    const info = wrapInfo(0x77, "right-pass", 1);
    const sb = fakeSb(0x77);
    try std.testing.expectEqual(Outcome.unsealed, unseal(&s, disk.rw(), sb, info, &ops));
    const transcript = p.out.items;
    try std.testing.expect(std.mem.indexOf(u8, transcript, "vlfs: sealed — wrong passphrase (4 left)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "vlfs: sealed — wrong passphrase (3 left)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "vlfs: sealed — unsealed\n") != null);
    try std.testing.expect(s.tag_first == info.tag_first);
}

test "seal: five wrong answers lock out; no input and unarmed RX are no_passphrase" {
    var img: [vlfs.block_len]u8 = @splat(0);
    var disk = MemDisk{ .img = &img };
    const info = wrapInfo(0x77, "right-pass", 1);
    const sb = fakeSb(0x77);

    // Lockout: five failed unwraps end the budget for the boot.
    var p1 = FakePrompt{ .input = "a\nb\nc\nd\ne\n", .out = .empty };
    defer p1.out.deinit(std.testing.allocator);
    var s1: Seal = undefined;
    var ops1 = p1.ops();
    try std.testing.expectEqual(Outcome.locked_out, unseal(&s1, disk.rw(), sb, info, &ops1));
    try std.testing.expect(std.mem.indexOf(u8, p1.out.items, "vlfs: sealed — wrong passphrase (1 left)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, p1.out.items, "vlfs: sealed — locked out, /disk not mounted\n") != null);

    // Idle timeout: no bytes at all — the fake clock walks past 120 ticks.
    var p2 = FakePrompt{ .input = "", .out = .empty };
    defer p2.out.deinit(std.testing.allocator);
    var s2: Seal = undefined;
    var ops2 = p2.ops();
    try std.testing.expectEqual(Outcome.no_passphrase, unseal(&s2, disk.rw(), sb, info, &ops2));
    try std.testing.expect(std.mem.indexOf(u8, p2.out.items, "vlfs: sealed — no passphrase, /disk not mounted\n") != null);

    // No input path: same named outcome without the wait.
    var p3 = FakePrompt{ .input = "x\n", .armed = false, .out = .empty };
    defer p3.out.deinit(std.testing.allocator);
    var s3: Seal = undefined;
    var ops3 = p3.ops();
    try std.testing.expectEqual(Outcome.no_passphrase, unseal(&s3, disk.rw(), sb, info, &ops3));

    // Unseeded entropy refuses before the first prompt (D9).
    var p4 = FakePrompt{ .input = "right-pass\n", .rng_ready = false, .out = .empty };
    defer p4.out.deinit(std.testing.allocator);
    var s4: Seal = undefined;
    var ops4 = p4.ops();
    try std.testing.expectEqual(Outcome.no_entropy, unseal(&s4, disk.rw(), sb, info, &ops4));
    try std.testing.expect(std.mem.indexOf(u8, p4.out.items, "vlfs: sealed — no entropy, /disk not mounted\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, p4.out.items, "passphrase:") == null);
}

// A 16 MiB sealed image built in-test: v1 structures per the golden
// geometry, v2 seal fields, every span block encrypted — the same bytes
// mkfs.vlfs --seal emits (cross-checked by check.go on the Go side).
fn formatSealedImage(img: []u8, volume_id: u64, pass: []const u8, dek: *[dek_len]u8) vlfs.SealInfo {
    const vb: u32 = @intCast(img.len / vlfs.block_len);
    const journal_blocks: u32 = @min(@max(vb / 16, 512), 2048);
    const inode_count: u32 = @min(@max(img.len / 65536, vlfs.min_inodes), vlfs.max_inodes);
    const bbitmap_blocks: u32 = @intCast((@as(u64, vb) + 8 * vlfs.block_len - 1) / (8 * vlfs.block_len));
    const itable_blocks: u32 = (inode_count + vlfs.inodes_per_block - 1) / vlfs.inodes_per_block;
    const ibitmap_first = 2 + journal_blocks;
    const bbitmap_first = ibitmap_first + 1;
    const itable_first = bbitmap_first + bbitmap_blocks;
    const data_first = itable_first + itable_blocks;
    const tag_blocks = vlfs.tagBlocksFor(vb);
    const tag_first = vb - tag_blocks;
    const data_blocks = tag_first - data_first;

    for (img, 0..) |*b, i| b.* = @intCast(i % 251);
    @memset(img, 0);

    var dek_local: [dek_len]u8 = undefined;
    for (&dek_local, 0..) |*b, i| b.* = @truncate(i * 11 + 5);
    dek.* = dek_local;

    var info = vlfs.SealInfo{
        .kdf_iters = 8,
        .salt = @splat(0x5A),
        .wrap_nonce = @splat(0x33),
        .wrapped_dek = undefined,
        .wrap_tag = undefined,
        .tag_first = tag_first,
        .tag_blocks = tag_blocks,
    };
    var kek: [dek_len]u8 = undefined;
    kdf.pbkdf2_hmac_sha256(pass, &info.salt, info.kdf_iters, &kek);
    const aad = blockAad(volume_id, wrap_block_num);
    aead.seal(&info.wrapped_dek, &info.wrap_tag, dek, &aad, &info.wrap_nonce, &kek);
    @memset(&kek, 0);

    const sb_rec = vlfs.Superblock{
        .seq = 2,
        .volume_id = volume_id,
        .volume_bytes = img.len,
        .volume_blocks = vb,
        .journal_first = 2,
        .journal_blocks = journal_blocks,
        .ibitmap_first = ibitmap_first,
        .ibitmap_blocks = 1,
        .bbitmap_first = bbitmap_first,
        .bbitmap_blocks = bbitmap_blocks,
        .itable_first = itable_first,
        .itable_blocks = itable_blocks,
        .data_first = data_first,
        .data_blocks = data_blocks,
        .inode_count = inode_count,
        .journal_applied = 0,
        .next_txn_seq = 1,
        .slot = 0,
        .seal = info,
    };
    var sb0: [vlfs.block_len]u8 = @splat(0);
    vlfs.writeSuperblockSector(sb0[0..vlfs.sector_len], sb_rec);
    @memcpy(img[0..vlfs.block_len], &sb0);
    var sb1_rec = sb_rec;
    sb1_rec.seq = 1;
    sb1_rec.slot = 1;
    vlfs.writeSuperblockSector(sb0[0..vlfs.sector_len], sb1_rec);
    @memcpy(img[vlfs.block_len .. 2 * vlfs.block_len], &sb0);

    // ibitmap: inodes 0+1 used. bbitmap: structural + tag + root dir block.
    const set = struct {
        fn f(m: []u8, i: u32) void {
            m[i / 8] |= @as(u8, 1) << @intCast(i % 8);
        }
    }.f;
    const ib = img[ibitmap_first * vlfs.block_len ..][0..vlfs.block_len];
    set(ib, 0);
    set(ib, 1);
    const bb = img[bbitmap_first * vlfs.block_len ..][0..vlfs.block_len];
    for (0..data_first + 1) |i| set(bb, @intCast(i));
    for (tag_first..vb) |i| set(bb, @intCast(i));

    // itable: every slot checksummed; inode 1 = root dir at data_first.
    for (0..inode_count) |i| {
        const slot = img[(itable_first + i / vlfs.inodes_per_block) * vlfs.block_len + (i % vlfs.inodes_per_block) * vlfs.inode_len ..][0..vlfs.inode_len];
        std.mem.writeInt(u32, slot[vlfs.in_cksum..][0..4], vlfs.fnv32(slot[0..vlfs.in_cksum]), .little);
    }
    const root = img[itable_first * vlfs.block_len + vlfs.inode_len ..][0..vlfs.inode_len];
    @memset(root, 0);
    root[vlfs.in_kind] = vlfs.kind_dir;
    std.mem.writeInt(u16, root[vlfs.in_nextents..][0..2], 1, .little);
    std.mem.writeInt(u32, root[vlfs.in_size..][0..4], vlfs.block_len, .little);
    std.mem.writeInt(u32, root[vlfs.in_extents..][0..4], data_first, .little);
    std.mem.writeInt(u32, root[vlfs.in_extents + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, root[vlfs.in_cksum..][0..4], vlfs.fnv32(root[0..vlfs.in_cksum]), .little);

    // Seal every block in [2, tag_first) — deterministic nonces.
    var s = makeSeal(volume_id, vb, tag_first, .{
        .ctx = undefined,
        .readFn = struct {
            fn f(_: ?*anyopaque, _: u64, _: *[vlfs.sector_len]u8) bool {
                return false;
            }
        }.f,
    });
    s.dek = dek.*;
    var nonce: [aead.nonce_len]u8 = undefined;
    var b: u32 = 2;
    while (b < tag_first) : (b += 1) {
        @memset(&nonce, 0);
        std.mem.writeInt(u64, nonce[0..8], b, .little);
        const baad = blockAad(volume_id, b);
        var tag: [aead.tag_len]u8 = undefined;
        const home = img[b * vlfs.block_len ..][0..vlfs.block_len];
        aead.seal(home, &tag, home, &baad, &nonce, dek);
        const t = tagHome(b - 2, &s);
        @memcpy(img[t.blk * vlfs.block_len + t.off ..][0..aead.nonce_len], &nonce);
        @memcpy(img[t.blk * vlfs.block_len + t.off + aead.nonce_len ..][0..aead.tag_len], &tag);
    }
    return info;
}

var test_img: [16 << 20]u8 = undefined;

test "seal: a sealed image mounts through the source — lookup and read" {
    const volume_id: u64 = 0xC0FFEE;
    const pass = "gate-pass";
    const img = &test_img;
    var dek: [dek_len]u8 = undefined;
    const info = formatSealedImage(img, volume_id, pass, &dek);
    var disk = MemDisk{ .img = img };

    // The probe sees the v2 superblock + seal span.
    const sb = try vlfs.selectSuperblock(disk.rw());
    try std.testing.expect(sb.seal != null);
    try std.testing.expectEqual(info.tag_first, sb.seal.?.tag_first);
    try std.testing.expectEqual(info.tag_blocks, sb.seal.?.tag_blocks);

    // Unseal through the scripted prompt, then mount through the source.
    var p = FakePrompt{ .input = "gate-pass\n", .out = .empty };
    defer p.out.deinit(std.testing.allocator);
    var s: Seal = undefined;
    var ops = p.ops();
    try std.testing.expectEqual(Outcome.unsealed, unseal(&s, disk.rw(), sb, info, &ops));
    try std.testing.expectEqualSlices(u8, &dek, &s.dek);

    const src = source(&s);
    var scratch: [vlfs.block_len]u8 = undefined;
    var check: vlfs.CheckState = undefined;
    const vol = try vlfs.mountChecked(src, &scratch, &check);
    try std.testing.expect(vol.seal != null);
    try std.testing.expectEqual(info.tag_first, vol.data_first + vol.data_blocks);

    // The root directory reads back through AEAD.
    var out: [16]vlfs.Dirent = undefined;
    try std.testing.expectEqual(@as(usize, 0), try vlfs.listDir(src, vol, vlfs.root_inode, &out, &scratch));

    // Tamper with a sealed home block: the read names bad_block_auth.
    img[vol.data_first * vlfs.block_len + 9] ^= 1;
    try std.testing.expectError(error.BadBlockAuth, vlfs.listDir(src, vol, vlfs.root_inode, &out, &scratch));
}

// ---------------------------------------------------------------------------
// Sealed-txn crash tests (#3104, ADR 0061 journaled tag blocks) — the write
// path is vlfs/write.zig ops over a sealed source; the crash harness is the
// write.zig RecDisk pattern at the inner (sector) layer.
// ---------------------------------------------------------------------------

const vlfs_write = @import("vlfs/write.zig");

const Op = struct {
    flush: bool = false,
    lba: u64 = 0,
    data: [vlfs.sector_len]u8 = undefined,
};

var op_log: [32768]Op = undefined;
var op_log_n: usize = 0;

/// In-memory device that logs sector writes + flushes (crashImage replays
/// the log onto a pre-image to enumerate legal crash states).
const RecDisk = struct {
    img: []u8,
    record: bool = true,
    fn readFn(ctx: ?*anyopaque, lba: u64, out: *[vlfs.sector_len]u8) bool {
        const d: *RecDisk = @ptrCast(@alignCast(ctx));
        if (lba >= d.img.len / vlfs.sector_len) return false;
        @memcpy(out, d.img[lba * vlfs.sector_len ..][0..vlfs.sector_len]);
        return true;
    }
    fn writeFn(ctx: ?*anyopaque, lba: u64, data: *const [vlfs.sector_len]u8) bool {
        const d: *RecDisk = @ptrCast(@alignCast(ctx));
        if (lba >= d.img.len / vlfs.sector_len) return false;
        @memcpy(d.img[lba * vlfs.sector_len ..][0..vlfs.sector_len], data);
        if (d.record and op_log_n < op_log.len) {
            op_log[op_log_n] = .{ .flush = false, .lba = lba, .data = data.* };
            op_log_n += 1;
        }
        return true;
    }
    fn flushFn(ctx: ?*anyopaque) bool {
        const d: *RecDisk = @ptrCast(@alignCast(ctx));
        if (d.record and op_log_n < op_log.len) {
            op_log[op_log_n] = .{ .flush = true };
            op_log_n += 1;
        }
        return true;
    }
    fn source(d: *RecDisk) vlfs.SectorSource {
        return .{ .ctx = d, .total_sectors = @intCast(d.img.len / vlfs.sector_len), .readFn = readFn, .writeFn = writeFn, .flushFn = flushFn };
    }
};

/// Replay a recorded op log onto a base image: `flush_k` flushes completed
/// (all writes before the k-th FLUSH are durable), plus the post-flush
/// window's writes in [lo1,hi1) ∪ [lo2,hi2) — the family (empty, full,
/// every prefix, every suffix, every singleton, every leave-one-out)
/// enumerates without a bitmask because a sealed txn's window can exceed
/// 64 sector writes (each append is ciphertext + tag-entry update).
fn crashImage(base: []const u8, flush_k: usize, lo1: usize, hi1: usize, lo2: usize, hi2: usize, out: []u8) void {
    @memcpy(out, base);
    var seen: usize = 0;
    var boundary: usize = 0;
    for (op_log[0..op_log_n], 0..) |op, i| {
        if (op.flush) {
            seen += 1;
            if (seen == flush_k) {
                boundary = i + 1;
                break;
            }
        }
    }
    for (op_log[0..boundary]) |op| {
        if (!op.flush) {
            const off = op.lba * vlfs.sector_len;
            @memcpy(out[off..][0..vlfs.sector_len], &op.data);
        }
    }
    var i: usize = 0;
    for (op_log[boundary..op_log_n]) |op| {
        if (op.flush) break;
        if ((i >= lo1 and i < hi1) or (i >= lo2 and i < hi2)) {
            const off = op.lba * vlfs.sector_len;
            @memcpy(out[off..][0..vlfs.sector_len], &op.data);
        }
        i += 1;
    }
}

var img_pre: [16 << 20]u8 align(64) = undefined;
var img_crash: [16 << 20]u8 align(64) = undefined;
var s_walk: [vlfs.block_len]u8 align(64) = undefined;
var s_compose: [vlfs.block_len]u8 align(64) = undefined;

/// Read a file's bytes on a mounted sealed volume (≤ 8 KiB fixtures).
fn fileBytes(src: vlfs.SectorSource, vol: vlfs.Volume, ino: u32, out: []u8) vlfs.Error!usize {
    return vlfs.read(src, vol, ino, 0, out, &s_walk);
}

test "seal: commit journals the tag homes covering a txn's sealed dests" {
    const volume_id: u64 = 0xBEEF;
    const pass = "txn-pass";
    const img = &test_img;
    var dek: [dek_len]u8 = undefined;
    const info = formatSealedImage(img, volume_id, pass, &dek);
    var disk = RecDisk{ .img = img, .record = false };
    var p = FakePrompt{ .input = "txn-pass\n", .out = .empty };
    defer p.out.deinit(std.testing.allocator);
    var s: Seal = undefined;
    var ops = p.ops();
    const sb = try vlfs.selectSuperblock(disk.source());
    try std.testing.expectEqual(Outcome.unsealed, unseal(&s, disk.source(), sb, info, &ops));
    const src = source(&s);
    var vol = try vlfs.mount(src, &s_walk);

    const ino = try vlfs_write.create(src, &vol, vlfs.root_inode, "F.TXT", vlfs.kind_file, test_now, &s_walk, &s_compose);
    _ = try vlfs_write.writeFile(src, &vol, ino, 0, "sealed payload", test_now, &s_walk, &s_compose);

    // The last transaction's DESC (journal cursor is the region start
    // under eager checkpointing) names a tag-home dest — the updated tag
    // block rode in the same transaction as the payloads it covers.
    var desc: [vlfs.block_len]u8 = undefined;
    try std.testing.expect(src.readBlock(vol.journal_first, &desc));
    const n = vlfs.rd16(&desc, vlfs.jd_count);
    var saw_tag_dest = false;
    for (0..n) |i| {
        const dest = vlfs.rd32(&desc, vlfs.jd_entries + 8 * i);
        if (dest >= vol.seal.?.tag_first) saw_tag_dest = true;
    }
    try std.testing.expect(saw_tag_dest);
    // The checkpoint consumed every staged entry — none leaked.
    try std.testing.expectEqual(@as(u32, 0), s.staged_n);
    // The file's bytes read back through the landed ciphertext+tag pair.
    var out: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 14), try fileBytes(src, vol, ino, &out));
    try std.testing.expectEqualSlices(u8, "sealed payload", out[0..14]);
}

test "seal: every legal crash state replays to pre/post and leaves no unauthenticated home" {
    const volume_id: u64 = 0xCAFE;
    const pass = "crash-pass";
    const img = &test_img;
    var dek: [dek_len]u8 = undefined;
    const info = formatSealedImage(img, volume_id, pass, &dek);
    var disk_a = RecDisk{ .img = img, .record = false };
    var p = FakePrompt{ .input = "crash-pass\n", .out = .empty };
    defer p.out.deinit(std.testing.allocator);
    var s: Seal = undefined;
    var ops = p.ops();
    const sb = try vlfs.selectSuperblock(disk_a.source());
    try std.testing.expectEqual(Outcome.unsealed, unseal(&s, disk_a.source(), sb, info, &ops));
    const src = source(&s);
    var vol = try vlfs.mount(src, &s_walk);

    // A representative op: create + stable write, then the measured txn.
    const ino = try vlfs_write.create(src, &vol, vlfs.root_inode, "F.TXT", vlfs.kind_file, test_now, &s_walk, &s_compose);
    _ = try vlfs_write.writeFile(src, &vol, ino, 0, "stable base\n", test_now, &s_walk, &s_compose);
    const pre_len = blk: {
        var b: [64]u8 = undefined;
        break :blk try fileBytes(src, vol, ino, &b);
    };
    @memcpy(&img_pre, img);

    var payload: [5000]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i % 97);
    disk_a.record = true;
    op_log_n = 0;
    _ = try vlfs_write.writeFile(src, &vol, ino, 3000, &payload, test_now, &s_walk, &s_compose);
    disk_a.record = false;
    var post: [8192]u8 = undefined;
    const post_len = try fileBytes(src, vol, ino, &post);

    // The blocks a torn write can leave mismatched: the txn's dests plus
    // every block whose tag entry shares a journaled tag home. Read the
    // committed DESC on the completed image to enumerate them — the
    // --check contract is that every one authenticates post-remount.
    var dests: [vlfs.max_payload]u32 = undefined;
    var ndests: usize = 0;
    var thomes: [vlfs.max_payload]u32 = undefined;
    var nthomes: usize = 0;
    {
        var desc: [vlfs.block_len]u8 = undefined;
        try std.testing.expect(src.readBlock(vol.journal_first, &desc));
        const n = vlfs.rd16(&desc, vlfs.jd_count);
        for (0..n) |i| {
            const d = vlfs.rd32(&desc, vlfs.jd_entries + 8 * i);
            if (d >= vol.seal.?.tag_first) {
                thomes[nthomes] = d;
                nthomes += 1;
            } else {
                dests[ndests] = d;
                ndests += 1;
            }
        }
        try std.testing.expect(nthomes > 0);
    }

    // Flush boundaries in the measured transaction's op log.
    var flush_idx: [16]usize = undefined;
    var nf: usize = 0;
    for (op_log[0..op_log_n], 0..) |op, i| {
        if (op.flush) {
            flush_idx[nf] = i;
            nf += 1;
        }
    }
    try std.testing.expect(nf >= 3);

    var cases: usize = 0;
    for (0..nf + 1) |k| {
        const boundary: usize = if (k == 0) 0 else flush_idx[k - 1] + 1;
        const limit: usize = if (k < nf) flush_idx[k] else op_log_n;
        var window: usize = 0;
        for (op_log[boundary..limit]) |op| {
            if (!op.flush) window += 1;
        }
        // The legal family at every boundary: empty tail, full tail, and
        // for each window index its prefix cut, suffix, singleton, and
        // leave-one-out — O(w) cases like the v1 enumerator.
        var c: usize = 0;
        while (c < 2 + 4 * window) : (c += 1) {
            var lo1: usize = 0;
            var hi1: usize = 0;
            var lo2: usize = 0;
            var hi2: usize = 0;
            if (c == 0) {
                // empty tail
            } else if (c == 1) {
                hi1 = window; // full tail
            } else {
                const m = (c - 2) % 4;
                const a = (c - 2) / 4;
                switch (m) {
                    0 => hi1 = a, // prefix
                    1 => {
                        lo1 = a; // suffix
                        hi1 = window;
                    },
                    2 => {
                        lo1 = a; // singleton
                        hi1 = a + 1;
                    },
                    else => {
                        hi1 = a; // leave-one-out
                        lo2 = a + 1;
                        hi2 = window;
                    },
                }
            }
            crashImage(&img_pre, k, lo1, hi1, lo2, hi2, &img_crash);
            // A fresh Seal mounts the crash image — the staged set is a
            // mount's own state, never on disk.
            var disk_c = RecDisk{ .img = &img_crash, .record = false };
            var sc = makeSeal(volume_id, info.tag_first + info.tag_blocks, info.tag_first, disk_c.source());
            sc.journal_end = s.journal_end;
            sc.dek = dek;
            const src_c = source(&sc);
            const vol_c = try vlfs.mount(src_c, &s_walk);
            var out: [8192]u8 = undefined;
            const got = try fileBytes(src_c, vol_c, ino, &out);
            // Two legal outcomes: the pre-write bytes or the post-write
            // bytes — never a third state.
            if (got == post_len) {
                try std.testing.expectEqualSlices(u8, post[0..post_len], out[0..got]);
            } else {
                try std.testing.expectEqual(pre_len, got);
                try std.testing.expectEqualSlices(u8, "stable base\n", out[0..pre_len]);
            }
            // Every txn-dest home authenticates post-remount — a torn
            // write can only ever be a journal record (journal_torn),
            // never a mismatched home.
            for (dests[0..ndests]) |d| {
                try std.testing.expect(src_c.readBlock(d, &s_walk));
            }
            // And so does every block sharing a journaled tag home — the
            // torn-tag-home blast radius a mid-checkpoint kill used to
            // leave flagged.
            for (thomes[0..nthomes]) |home| {
                var b2: u32 = 2 + (home - vol.seal.?.tag_first) * vlfs.tag_entries_per_block;
                const hi = @min(b2 + vlfs.tag_entries_per_block, vol.seal.?.tag_first);
                while (b2 < hi) : (b2 += 1) {
                    if (b2 >= sc.journal_end) {
                        try std.testing.expect(src_c.readBlock(b2, &s_walk));
                    }
                }
            }
            cases += 1;
        }
    }
    try std.testing.expect(cases > 200);
}

const test_now: u64 = 1_800_000_000;
