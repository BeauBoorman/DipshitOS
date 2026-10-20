//! VLFS — the read half of the ADR 0050 journaled volume (M100c, #2308).
//!
//! **What this is.** A pure reader over an arbitrary 512-byte sector source,
//! the same shape as `fat32_ro.zig`: a `SectorSource` (function pointers +
//! one context word) goes in, validated bytes come out, and the whole module
//! is host-testable against an in-memory image — no VZ, no device. The live
//! source is the M100b virtio-blk driver once it lands; `disk.zig` holds
//! the mounted-volume state and the `/disk` partition glue.
//!
//! **Format authority is docs/decisions/0050-vlfs.md §D3.** One VLFS block is
//! 4096 B = 8 sectors; every structure ends in an FNV-1a-32 checksum over its
//! preceding bytes; superblocks ping-pong in blocks 0/1; the journal sits at
//! blocks `2 .. 2+J-1`; then ibitmap, bbitmap, itable, data. Inode *i* is the
//! i-th 128-byte itable slot (inode 0 is never a file), directories carry
//! packed 272-byte dirents, and root is inode 1.
//!
//! **v1 read semantics.** Reads never consult or dirty the journal (D4: the
//! journal is empty at every operation boundary). Mount replays committed
//! transactions when the source can write (D5); a source that cannot write
//! is refused `journal_unreplayed` rather than silently serving the
//! pre-transaction state. Any structure that fails a checksum or bounds
//! check on the read path fails the operation — `bad_inode`, `bad_dirent`,
//! `bad_extent`, `extent_chain_corrupt` — never a hang, never invented
//! bytes.
//!
//! **The mount-time check (M134c #2761).** `mountChecked` runs a bounded
//! fsck — inode checksums/kinds vs the ibitmap, extent bounds/overlap/
//! coverage, bbitmap consistency — against the journal's as-replayed
//! overlay BEFORE any write, so a corrupt volume is refused by name having
//! received no byte. Dirent and tree checks stay lazy on the read path;
//! the host `--check` (tools/go/vlfs) owns the offline deep scan. `mount`
//! is the unchecked form kept for the write-path tests.

const std = @import("std");

pub const sector_len: usize = 512;
pub const block_len: usize = 4096;
pub const sectors_per_block: u32 = block_len / sector_len;

pub const magic_super: u32 = 0x53464C56; // "VLFS"
pub const magic_desc: u32 = 0x4353444A; // "JDSC"
pub const magic_commit: u32 = 0x544D434A; // "JCMT"
pub const magic_extent: u32 = 0x42455856; // "VXEB"
pub const format_version: u32 = 1;

pub const min_volume_bytes: u64 = 16 << 20;
pub const max_volume_bytes: u64 = 1 << 30;
pub const max_inodes: u32 = 16384;
pub const min_inodes: u32 = 256;
pub const inode_len: usize = 128;
pub const inodes_per_block: u32 = block_len / inode_len;
pub const dirent_len: usize = 272;
pub const dirents_per_block: u32 = block_len / dirent_len;
pub const max_dirents: u32 = 1024;
pub const max_name: usize = 255;
pub const max_payload: u32 = 64;
pub const inline_extents: usize = 8;
pub const max_extent_blocks: u32 = 4;
pub const extents_per_block: u32 = (block_len - 12) / 8; // 510
pub const root_inode: u32 = 1;

/// Volume blocks at the 1 GiB ceiling — the check's refs bitmap bound.
pub const max_volume_blocks: u32 = max_volume_bytes / block_len; // 262144
/// Bits of the block bitmap one bbitmap block carries (32768).
pub const bits_per_map_block: u32 = 8 * block_len;
/// The journal-region ceiling (the D3 sizing formula's clamp); also the
/// bound on payload blocks across all live transactions — the mount
/// check's overlay table is sized by it.
pub const max_journal_blocks: u32 = 2048;

pub const kind_free: u8 = 0;
pub const kind_file: u8 = 1;
pub const kind_dir: u8 = 2;

/// The error set names the ADR 0050 refusal codes one-for-one (camelCase Zig
/// spelling); `refusalName` renders them in the ADR's snake_case for the
/// boot log.
pub const Error = error{
    /// io_error — the sector source failed.
    Io,
    /// not_vlfs — no VLFS magic in either superblock slot.
    NotVlfs,
    /// bad_superblock — VLFS magic present, every copy fails validation.
    BadSuperblock,
    /// unsupported_version — a version other than 1.
    UnsupportedVersion,
    /// geometry_mismatch — the superblock's region map is not the D3 tiling.
    GeometryMismatch,
    /// volume_too_small / volume_too_large — outside the 16 MiB..1 GiB bound.
    VolumeTooSmall,
    VolumeTooLarge,
    /// journal_unreplayed — committed transactions wait for replay but the
    /// source cannot write (the read path never serves pre-commit state).
    JournalUnreplayed,
    /// inode_checksum — an itable slot's trailing FNV-1a fails (mount check).
    InodeChecksum,
    /// extent_out_of_range — an extent escapes the data region, or an
    /// inode's coverage falls short of its size (mount check).
    ExtentOutOfRange,
    /// extent_overlap — two inodes claim the same block, or an extent
    /// claims an extent-chain block (mount check).
    ExtentOverlap,
    /// bitmap_inconsistent — the ibitmap/bbitmap disagree with the inode
    /// records and extent references (mount check).
    BitmapInconsistent,
    /// not_mounted — no attached volume (file_table maps this to ENOENT).
    NotMounted,
    /// The path component does not exist.
    NotFound,
    /// A path component that must be a directory is not one.
    NotDir,
    /// The path names a directory where a file was required.
    IsDir,
    /// bad_inode — checksum, kind, or coverage failure on an inode.
    BadInode,
    /// bad_dirent — a directory row violates the D3 record invariants.
    BadDirent,
    /// bad_extent — a file offset has no covering extent.
    BadExtent,
    /// extent_chain_corrupt — an extent block's magic/count/checksum fails.
    ExtentChainCorrupt,
    /// bad_journal — a journal record or a txn dest violates the D3/D4
    /// shape (runtime corruption or a writer invariant breach).
    BadJournal,
    /// read_only_partition — the sector source cannot write/flush.
    ReadOnly,
    /// exists — a create/rename target name is already live.
    Exists,
    /// no_space — the block bitmap has no free data block (device full).
    NoSpace,
    /// no_inodes — the inode bitmap has no free inode.
    NoInodes,
    /// dir_full — the directory already holds 1024 live dirents.
    DirFull,
    /// txn_too_large — the operation's payload set exceeds 64 blocks (the
    /// ADR D7 span bound); under eager checkpointing this is also the
    /// journal-full answer (the journal holds one transaction).
    TxnTooLarge,
    /// extent_overflow — the file's extent list would exceed 8 inline +
    /// 4 chained extent blocks.
    ExtentOverflow,
    /// file_too_large — the byte size would exceed 4 GiB − 1 (u32 size).
    FileTooLarge,
    /// name_too_long — a dirent name outside 1..255 bytes or containing a
    /// forbidden character.
    NameTooLong,
    /// not_empty — a remove target is a directory with live dirents.
    NotEmpty,
};

/// The ADR D7 refusal spelling, for logs and gate evidence.
pub fn refusalName(err: Error) []const u8 {
    return switch (err) {
        error.Io => "io_error",
        error.NotVlfs => "not_vlfs",
        error.BadSuperblock => "bad_superblock",
        error.UnsupportedVersion => "unsupported_version",
        error.GeometryMismatch => "geometry_mismatch",
        error.VolumeTooSmall => "volume_too_small",
        error.VolumeTooLarge => "volume_too_large",
        error.JournalUnreplayed => "journal_unreplayed",
        error.InodeChecksum => "inode_checksum",
        error.ExtentOutOfRange => "extent_out_of_range",
        error.ExtentOverlap => "extent_overlap",
        error.BitmapInconsistent => "bitmap_inconsistent",
        error.NotMounted => "not_mounted",
        error.NotFound => "not_found",
        error.NotDir => "not_directory",
        error.IsDir => "is_directory",
        error.BadInode => "bad_inode",
        error.BadDirent => "bad_dirent",
        error.BadExtent => "bad_extent",
        error.ExtentChainCorrupt => "extent_chain_corrupt",
        error.BadJournal => "bad_journal",
        error.ReadOnly => "read_only_partition",
        error.Exists => "exists",
        error.NoSpace => "no_space",
        error.NoInodes => "no_inodes",
        error.DirFull => "dir_full",
        error.TxnTooLarge => "txn_too_large",
        error.ExtentOverflow => "extent_overflow",
        error.FileTooLarge => "file_too_large",
        error.NameTooLong => "name_too_long",
        error.NotEmpty => "not_empty",
    };
}

/// FNV-1a-32 (offset basis 2166136261, prime 16777619) — the house checksum
/// every VLFS structure trails.
pub fn fnv32(bytes: []const u8) u32 {
    var h: u32 = 2166136261;
    for (bytes) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return h;
}

// ---------------------------------------------------------------------------
// Sector source (the fat32_ro seam shape, plus optional write/flush for the
// mount-time journal replay — reads alone never mutate)
// ---------------------------------------------------------------------------

pub const SectorSource = struct {
    ctx: ?*anyopaque = null,
    /// Total device size in 512-byte sectors; 0 means "unbounded" (tests).
    total_sectors: u64 = 0,
    readFn: *const fn (ctx: ?*anyopaque, lba: u64, out: *[sector_len]u8) bool,
    /// Journal replay (D5) needs both; a read-only source leaves them null
    /// and a non-empty journal then refuses mount with journal_unreplayed.
    writeFn: ?*const fn (ctx: ?*anyopaque, lba: u64, data: *const [sector_len]u8) bool = null,
    flushFn: ?*const fn (ctx: ?*anyopaque) bool = null,

    pub fn readSector(self: SectorSource, lba: u64, out: *[sector_len]u8) bool {
        if (self.total_sectors != 0 and lba >= self.total_sectors) return false;
        return self.readFn(self.ctx, lba, out);
    }

    pub fn writeSector(self: SectorSource, lba: u64, data: *const [sector_len]u8) bool {
        const w = self.writeFn orelse return false;
        if (self.total_sectors != 0 and lba >= self.total_sectors) return false;
        return w(self.ctx, lba, data);
    }

    /// A device without a flush reports the call as failed rather than
    /// silently pretending durability: the replay path fails honestly.
    pub fn flush(self: SectorSource) bool {
        const f = self.flushFn orelse return false;
        return f(self.ctx);
    }

    pub fn writable(self: SectorSource) bool {
        return self.writeFn != null and self.flushFn != null;
    }

    /// One 4 KiB VLFS block is 8 sector reads; a sector failure fails it.
    pub fn readBlock(self: SectorSource, blk: u32, out: *[block_len]u8) bool {
        for (0..sectors_per_block) |i| {
            var sector: [sector_len]u8 = undefined;
            const lba = @as(u64, blk) * sectors_per_block + i;
            if (!self.readSector(lba, &sector)) return false;
            @memcpy(out[i * sector_len ..][0..sector_len], &sector);
        }
        return true;
    }

    /// One 4 KiB VLFS block is 8 sector writes; a sector failure fails it.
    pub fn writeBlock(self: SectorSource, blk: u32, data: *const [block_len]u8) bool {
        for (0..sectors_per_block) |i| {
            const lba = @as(u64, blk) * sectors_per_block + i;
            if (!self.writeSector(lba, @ptrCast(data[i * sector_len ..][0..sector_len]))) return false;
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Superblock (one 512-B sector inside each of blocks 0 and 1; rest zero)
// ---------------------------------------------------------------------------

const sb_magic: usize = 0;
const sb_version: usize = 4;
const sb_seq: usize = 8;
const sb_volume_id: usize = 16;
const sb_volume_bytes: usize = 24;
const sb_block_shift: usize = 32;
const sb_volume_blocks: usize = 36;
const sb_journal_first: usize = 40;
const sb_journal_blocks: usize = 44;
const sb_ibitmap_first: usize = 48;
const sb_ibitmap_blocks: usize = 52;
const sb_bbitmap_first: usize = 56;
const sb_bbitmap_blocks: usize = 60;
const sb_itable_first: usize = 64;
const sb_itable_blocks: usize = 68;
const sb_data_first: usize = 72;
const sb_data_blocks: usize = 76;
const sb_inode_count: usize = 80;
const sb_journal_applied: usize = 84;
const sb_next_txn_seq: usize = 92;
const sb_mkfs_time: usize = 100;
const sb_cksum: usize = 508;

/// The chosen superblock: geometry plus the journal cursor state.
pub const Superblock = struct {
    seq: u64,
    volume_id: u64,
    volume_bytes: u64,
    volume_blocks: u32,
    journal_first: u32,
    journal_blocks: u32,
    ibitmap_first: u32,
    ibitmap_blocks: u32,
    bbitmap_first: u32,
    bbitmap_blocks: u32,
    itable_first: u32,
    itable_blocks: u32,
    data_first: u32,
    data_blocks: u32,
    inode_count: u32,
    journal_applied: u64,
    next_txn_seq: u64,
    /// Which physical slot (0 or 1) this copy was read from — the ping-pong
    /// update lands on the other one.
    slot: u8,
};

pub fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

pub fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

pub fn rd64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

const SbResult = union(enum) {
    empty, // no magic — an unused slot
    ok: Superblock,
    bad: Error,
};

/// Validate one superblock sector. A VLFS-magic sector that fails any check
/// is `.bad`; the ADR's geometry self-consistency includes the mkfs formulas
/// (journal/inode scaling, region tiling), so a drifted image is refused
/// rather than trusted.
fn parseSuperblock(sector: *const [sector_len]u8, slot: u8) SbResult {
    if (rd32(sector, sb_magic) != magic_super) return .empty;
    if (rd32(sector, sb_version) != format_version) return .{ .bad = error.UnsupportedVersion };
    if (rd32(sector, sb_cksum) != fnv32(sector[0..sb_cksum])) return .{ .bad = error.BadSuperblock };
    const s = Superblock{
        .seq = rd64(sector, sb_seq),
        .volume_id = rd64(sector, sb_volume_id),
        .volume_bytes = rd64(sector, sb_volume_bytes),
        .volume_blocks = rd32(sector, sb_volume_blocks),
        .journal_first = rd32(sector, sb_journal_first),
        .journal_blocks = rd32(sector, sb_journal_blocks),
        .ibitmap_first = rd32(sector, sb_ibitmap_first),
        .ibitmap_blocks = rd32(sector, sb_ibitmap_blocks),
        .bbitmap_first = rd32(sector, sb_bbitmap_first),
        .bbitmap_blocks = rd32(sector, sb_bbitmap_blocks),
        .itable_first = rd32(sector, sb_itable_first),
        .itable_blocks = rd32(sector, sb_itable_blocks),
        .data_first = rd32(sector, sb_data_first),
        .data_blocks = rd32(sector, sb_data_blocks),
        .inode_count = rd32(sector, sb_inode_count),
        .journal_applied = rd64(sector, sb_journal_applied),
        .next_txn_seq = rd64(sector, sb_next_txn_seq),
        .slot = slot,
    };
    if (geometryError(s, sector)) |err| return .{ .bad = err };
    return .{ .ok = s };
}

fn clamp(v: u64, lo: u64, hi: u64) u64 {
    return @min(@max(v, lo), hi);
}

fn geometryError(s: Superblock, sector: *const [sector_len]u8) ?Error {
    if (s.volume_id == 0) return error.GeometryMismatch;
    if (rd32(sector, sb_block_shift) != 12) return error.GeometryMismatch;
    if (s.volume_bytes == 0 or s.volume_bytes % block_len != 0) return error.GeometryMismatch;
    if (s.volume_blocks != s.volume_bytes / block_len) return error.GeometryMismatch;
    if (s.volume_bytes < min_volume_bytes) return error.VolumeTooSmall;
    if (s.volume_bytes > max_volume_bytes) return error.VolumeTooLarge;
    // The mkfs sizing formulas are part of the v1 layout (D3), not hints.
    if (s.journal_blocks != clamp(s.volume_blocks / 16, 512, 2048)) return error.GeometryMismatch;
    if (s.inode_count != clamp(s.volume_bytes / 65536, min_inodes, max_inodes)) return error.GeometryMismatch;
    if (s.journal_first != 2 or s.ibitmap_first != 2 + s.journal_blocks or s.ibitmap_blocks != 1)
        return error.GeometryMismatch;
    const bbitmap_blocks = (s.volume_blocks + 8 * block_len - 1) / (8 * block_len);
    if (s.bbitmap_first != s.ibitmap_first + 1 or s.bbitmap_blocks != bbitmap_blocks)
        return error.GeometryMismatch;
    if (s.itable_first != s.bbitmap_first + s.bbitmap_blocks or
        s.itable_blocks != (s.inode_count + inodes_per_block - 1) / inodes_per_block)
        return error.GeometryMismatch;
    if (s.data_first != s.itable_first + s.itable_blocks or
        @as(u64, s.data_first) + s.data_blocks != s.volume_blocks)
        return error.GeometryMismatch;
    if (s.next_txn_seq == 0) return error.GeometryMismatch;
    return null;
}

// ---------------------------------------------------------------------------
// Journal record field offsets (ADR 0050 D3) — pub for the M100d write path
// (write.zig emits the same records this reader validates).
// ---------------------------------------------------------------------------

pub const jd_magic: usize = 0;
pub const jd_seq: usize = 4;
pub const jd_count: usize = 12;
pub const jd_flags: usize = 14;
pub const jd_entries: usize = 16;
pub const jd_cksum: usize = block_len - 4;
pub const jc_magic: usize = 0;
pub const jc_seq: usize = 4;
pub const jc_txn: usize = 12;
pub const jc_cksum: usize = block_len - 4;

/// A mounted, validated volume — the chosen superblock's geometry.
pub const Volume = struct {
    seq: u64,
    volume_id: u64,
    volume_blocks: u32,
    journal_first: u32,
    journal_blocks: u32,
    ibitmap_first: u32,
    bbitmap_first: u32,
    bbitmap_blocks: u32,
    itable_first: u32,
    itable_blocks: u32,
    data_first: u32,
    data_blocks: u32,
    inode_count: u32,
    journal_applied: u64,
    next_txn_seq: u64,
    /// The physical superblock slot the volume was read from (0/1).
    sb_slot: u8,
    /// M100d: the write path's forward-only bbitmap scan cursor (in-memory
    /// only, never on disk) — the next data block to probe for a free bit.
    alloc_hint: u32,
    /// M100e: transactions this mount replayed out of the journal (0 when
    /// the journal was clean or held only a torn tail). In-memory evidence
    /// for the boot log — never on disk.
    replayed: u32,
};

/// The live volume state re-expressed as a Superblock record — the shape the
/// ping-pong update writes (M100d's commit path and D5's replay share it).
pub fn volumeSuperblock(vol: Volume, slot: u8) Superblock {
    return .{
        .seq = vol.seq,
        .volume_id = vol.volume_id,
        .volume_bytes = @as(u64, vol.volume_blocks) * block_len,
        .volume_blocks = vol.volume_blocks,
        .journal_first = vol.journal_first,
        .journal_blocks = vol.journal_blocks,
        .ibitmap_first = vol.ibitmap_first,
        .ibitmap_blocks = 1,
        .bbitmap_first = vol.bbitmap_first,
        .bbitmap_blocks = vol.bbitmap_blocks,
        .itable_first = vol.itable_first,
        .itable_blocks = vol.itable_blocks,
        .data_first = vol.data_first,
        .data_blocks = vol.data_blocks,
        .inode_count = vol.inode_count,
        .journal_applied = vol.journal_applied,
        .next_txn_seq = vol.next_txn_seq,
        .slot = slot,
    };
}

/// One DESC record's verdict: `torn` stops the scan; the journal tail is
/// whatever follows — discarded either way.
const JournalStep = union(enum) {
    /// A fully valid transaction spanning blocks [pos, pos+n+2).
    valid: u32, // n payload blocks
    torn,
};

fn checkJournalRecord(src: SectorSource, sb: Superblock, pos: u32, scratch: *[block_len]u8) Error!JournalStep {
    const end = sb.journal_first + sb.journal_blocks;
    if (!src.readBlock(pos, scratch)) return error.Io;
    if (rd32(scratch, jd_magic) != magic_desc) {
        // An all-zero block is the clean end of an empty region.
        for (scratch) |c| {
            if (c != 0) return .torn;
        }
        return .torn;
    }
    const n: u32 = rd16(scratch, jd_count);
    if (n < 1 or n > max_payload or pos + n + 2 > end) return .torn;
    if (rd64(scratch, jd_seq) != sb.journal_applied + 1) return .torn;
    // ^ only meaningful for the FIRST record; the caller threads `expected`
    //   through subsequent records by bumping journal_applied.
    if (rd16(scratch, jd_flags) != 0) return .torn;
    if (rd32(scratch, jd_cksum) != fnv32(scratch[0..jd_cksum])) return .torn;
    const desc = scratch.*;
    var txn_hash: u32 = fnv32(desc[0 .. jd_entries + 8 * n]);
    for (0..n) |i| {
        const dest = rd32(&desc, jd_entries + 8 * @as(usize, @intCast(i)));
        if (dest < sb.journal_first + sb.journal_blocks or dest >= sb.volume_blocks) return .torn;
        if (!src.readBlock(pos + 1 + @as(u32, @intCast(i)), scratch)) return error.Io;
        if (rd32(&desc, jd_entries + 8 * @as(usize, @intCast(i)) + 4) != fnv32(scratch)) return .torn;
        txn_hash = fnv32Continue(txn_hash, scratch);
    }
    if (!src.readBlock(pos + 1 + n, scratch)) return error.Io;
    if (rd32(scratch, jc_magic) != magic_commit) return .torn;
    if (rd64(scratch, jc_seq) != sb.journal_applied + 1) return .torn;
    if (rd32(scratch, jc_txn) != txn_hash) return .torn;
    if (rd32(scratch, jc_cksum) != fnv32(scratch[0..jc_cksum])) return .torn;
    return .{ .valid = n };
}

/// FNV-1a continued over another block (for the COMMIT txn_cksum over
/// DESC[+0..+16+8n] + all payload blocks).
pub fn fnv32Continue(h: u32, bytes: []const u8) u32 {
    var hash = h;
    for (bytes) |c| {
        hash ^= c;
        hash *%= 16777619;
    }
    return hash;
}

/// One journal-overlay entry: a committed transaction's payload block at
/// journal block `src` lands on home block `dest` at replay.
const DestRef = struct { dest: u32, src: u32 };

/// The mount-time check's working state (≈55 KiB BSS): the journal
/// overlay, the referenced-block bitmap, the inode-liveness copy, a second
/// work block for extent chains, and the check-phase refusal for the
/// `check=<name>` verdict line. One per mount — disk.zig owns the live
/// instance; tests carry their own.
pub const CheckState = struct {
    /// dest→journal-block pairs for every payload block of every committed
    /// transaction at the journal head, in journal order — the fsck
    /// overlay (ADR D5's in-memory replay, literal). Latest writer wins:
    /// checkRead scans from the tail.
    dests: [max_journal_blocks]DestRef = undefined,
    dest_count: u32 = 0,
    /// One bit per volume block: "some inode's extents claim this data
    /// block" — the overlap oracle and the bbitmap's cross-check.
    refs: [max_volume_blocks / 8]u8 = undefined,
    /// One bit per inode copied out of the on-disk ibitmap.
    ib_used: [max_inodes / 8]u8 = undefined,
    /// The check's second work block: extent-chain blocks are read here
    /// while the caller's scratch holds the itable/bbitmap block under
    /// iteration.
    chain: [block_len]u8 align(64) = undefined,
    /// Set by mountChecked when the refusal came from the check phase —
    /// attach() renders those as `check=<name>`.
    check_error: ?Error = null,
};

/// Scan the journal from the region start. Returns the count of fully valid
/// committed transactions found at the head (the `expected` sequence starts
/// at journal_applied + 1 and each record must carry it). With a CheckState
/// it also records each transaction's dest→journal-block pairs — the mount
/// check's as-replayed overlay.
fn journalWalk(src: SectorSource, sb: Superblock, scratch: *[block_len]u8, st: ?*CheckState) Error!u32 {
    var live: u32 = 0;
    var pos = sb.journal_first;
    var expected = sb.journal_applied + 1;
    var probe = sb;
    while (pos < sb.journal_first + sb.journal_blocks) {
        probe.journal_applied = expected - 1;
        const n = switch (try checkJournalRecord(src, probe, pos, scratch)) {
            .valid => |n| n,
            .torn => break,
        };
        if (st) |s| {
            // Re-read DESC for the dest table (scratch holds COMMIT).
            if (!src.readBlock(pos, scratch)) return error.Io;
            for (0..n) |i| {
                if (s.dest_count >= max_journal_blocks) return error.BadJournal;
                s.dests[s.dest_count] = .{
                    .dest = rd32(scratch, jd_entries + 8 * @as(usize, @intCast(i))),
                    .src = pos + 1 + @as(u32, @intCast(i)),
                };
                s.dest_count += 1;
            }
        }
        live += 1;
        expected += 1;
        pos += n + 2;
    }
    return live;
}

/// Scan the journal from the region start. Returns the count of fully valid
/// committed transactions found at the head (the `expected` sequence starts
/// at journal_applied + 1 and each record must carry it).
fn scanJournal(src: SectorSource, sb: Superblock, scratch: *[block_len]u8) Error!u32 {
    return journalWalk(src, sb, scratch, null);
}

/// Replay the live journal transactions (ADR D5): each committed payload
/// lands on its dest blocks, then FLUSH, then the ping-pong superblock
/// update (journal_applied = last replayed seq, next_txn_seq = max), then
/// FLUSH. Idempotent — the same bytes land on the same blocks.
fn replayJournal(src: SectorSource, sb: *Superblock, count: u32, scratch: *[block_len]u8) Error!void {
    _ = count;
    var pos = sb.journal_first;
    var expected = sb.journal_applied + 1;
    const end = sb.journal_first + sb.journal_blocks;
    while (pos < end) {
        var probe = sb.*;
        probe.journal_applied = expected - 1;
        const n = switch (try checkJournalRecord(src, probe, pos, scratch)) {
            .valid => |n| n,
            .torn => break,
        };
        // Re-read DESC (scratch currently holds COMMIT).
        if (!src.readBlock(pos, scratch)) return error.Io;
        const desc = scratch.*;
        for (0..n) |i| {
            const dest = rd32(&desc, jd_entries + 8 * @as(usize, @intCast(i)));
            if (!src.readBlock(pos + 1 + @as(u32, @intCast(i)), scratch)) return error.Io;
            const payload = scratch.*;
            if (!src.writeBlock(dest, &payload)) return error.Io;
        }
        expected += 1;
        pos += n + 2;
    }
    if (!src.flush()) return error.Io;
    // Ping-pong: the new superblock lands on the slot holding the LOWER
    // seq — the one we did not read from.
    sb.journal_applied = expected - 1;
    sb.next_txn_seq = @max(sb.next_txn_seq, expected);
    sb.seq += 1;
    const target_slot: u32 = 1 - sb.slot;
    var blk: [block_len]u8 = @splat(0);
    writeSuperblockSector(blk[0..sector_len], sb.*);
    if (!src.writeBlock(target_slot, &blk)) return error.Io;
    if (!src.flush()) return error.Io;
    sb.slot = @intCast(target_slot);
}

/// Serialize one superblock sector (512 B; the caller zero-pads the rest of
/// the block). Shared by D5 replay and the M100d commit's ping-pong update.
pub fn writeSuperblockSector(sector: *[sector_len]u8, s: Superblock) void {
    @memset(sector, 0);
    std.mem.writeInt(u32, sector[sb_magic..][0..4], magic_super, .little);
    std.mem.writeInt(u32, sector[sb_version..][0..4], format_version, .little);
    std.mem.writeInt(u64, sector[sb_seq..][0..8], s.seq, .little);
    std.mem.writeInt(u64, sector[sb_volume_id..][0..8], s.volume_id, .little);
    std.mem.writeInt(u64, sector[sb_volume_bytes..][0..8], s.volume_bytes, .little);
    std.mem.writeInt(u32, sector[sb_block_shift..][0..4], 12, .little);
    std.mem.writeInt(u32, sector[sb_volume_blocks..][0..4], s.volume_blocks, .little);
    std.mem.writeInt(u32, sector[sb_journal_first..][0..4], s.journal_first, .little);
    std.mem.writeInt(u32, sector[sb_journal_blocks..][0..4], s.journal_blocks, .little);
    std.mem.writeInt(u32, sector[sb_ibitmap_first..][0..4], s.ibitmap_first, .little);
    std.mem.writeInt(u32, sector[sb_ibitmap_blocks..][0..4], s.ibitmap_blocks, .little);
    std.mem.writeInt(u32, sector[sb_bbitmap_first..][0..4], s.bbitmap_first, .little);
    std.mem.writeInt(u32, sector[sb_bbitmap_blocks..][0..4], s.bbitmap_blocks, .little);
    std.mem.writeInt(u32, sector[sb_itable_first..][0..4], s.itable_first, .little);
    std.mem.writeInt(u32, sector[sb_itable_blocks..][0..4], s.itable_blocks, .little);
    std.mem.writeInt(u32, sector[sb_data_first..][0..4], s.data_first, .little);
    std.mem.writeInt(u32, sector[sb_data_blocks..][0..4], s.data_blocks, .little);
    std.mem.writeInt(u32, sector[sb_inode_count..][0..4], s.inode_count, .little);
    std.mem.writeInt(u64, sector[sb_journal_applied..][0..8], s.journal_applied, .little);
    std.mem.writeInt(u64, sector[sb_next_txn_seq..][0..8], s.next_txn_seq, .little);
    std.mem.writeInt(u64, sector[sb_mkfs_time..][0..8], 0, .little);
    std.mem.writeInt(u32, sector[sb_cksum..][0..4], fnv32(sector[0..sb_cksum]), .little);
}

/// Validate both superblocks and keep the highest-seq valid copy — the
/// shared head of mount()/mountChecked().
fn selectSuperblock(src: SectorSource) Error!Superblock {
    var best: ?Superblock = null;
    var first_bad: ?Error = null;
    var saw_magic = false;
    for (0..2) |slot| {
        var sector: [sector_len]u8 = undefined;
        if (!src.readSector(@as(u64, slot) * sectors_per_block, &sector)) return error.Io;
        switch (parseSuperblock(&sector, @intCast(slot))) {
            .empty => {},
            .bad => |e| {
                saw_magic = true;
                if (first_bad == null) first_bad = e;
            },
            .ok => |s| {
                saw_magic = true;
                if (best == null or s.seq > best.?.seq) best = s;
            },
        }
    }
    return best orelse if (saw_magic) (first_bad orelse error.BadSuperblock) else error.NotVlfs;
}

/// Mount: validate both superblocks, keep the highest-seq valid copy, bound
/// the volume against the device size, then scan the journal. A clean or
/// torn-empty journal mounts directly; committed transactions replay when
/// the source is writable and refuse the mount (`journal_unreplayed`) when
/// it is not — reads never serve a half-checkpointed state. This is the
/// unchecked form kept for the write-path tests; the attach path mounts
/// through `mountChecked`.
pub fn mount(src: SectorSource, scratch: *[block_len]u8) Error!Volume {
    return mountChecked(src, scratch, null);
}

/// Mount with the D5 fsck contract applied (M134c #2761): after the journal
/// scan builds the dest overlay, a bounded structural check evaluates the
/// as-replayed state BEFORE any write, so a corrupt volume is refused by
/// name having received no byte — replay proceeds only for a volume that
/// checks clean. A check failure sets `st.check_error`; attach() renders
/// the verdict as `check=<name>`.
pub fn mountChecked(src: SectorSource, scratch: *[block_len]u8, st: ?*CheckState) Error!Volume {
    if (st) |s| s.* = .{};
    var sb = try selectSuperblock(src);
    if (src.total_sectors != 0 and sb.volume_bytes > src.total_sectors * sector_len)
        return error.GeometryMismatch;

    const live = try journalWalk(src, sb, scratch, st);
    if (st) |s| {
        checkVolume(src, sb, s, scratch) catch |err| {
            s.check_error = err;
            return err;
        };
    }
    if (live > 0) {
        if (!src.writable()) return error.JournalUnreplayed;
        try replayJournal(src, &sb, live, scratch);
    }
    return .{
        .seq = sb.seq,
        .volume_id = sb.volume_id,
        .volume_blocks = sb.volume_blocks,
        .journal_first = sb.journal_first,
        .journal_blocks = sb.journal_blocks,
        .ibitmap_first = sb.ibitmap_first,
        .bbitmap_first = sb.bbitmap_first,
        .bbitmap_blocks = sb.bbitmap_blocks,
        .itable_first = sb.itable_first,
        .itable_blocks = sb.itable_blocks,
        .data_first = sb.data_first,
        .data_blocks = sb.data_blocks,
        .inode_count = sb.inode_count,
        .journal_applied = sb.journal_applied,
        .next_txn_seq = sb.next_txn_seq,
        .sb_slot = sb.slot,
        .alloc_hint = sb.data_first,
        .replayed = live,
    };
}

// ---------------------------------------------------------------------------
// The mount-time check (M134c #2761) — ADR 0050 D5's fsck contract, bounded
// to inode checksums/kinds, extent integrity, and bitmap consistency; all
// evaluated through the journal overlay, the same as-replayed state the
// host `--check` computes in memory. Dirent/tree checks stay out of the
// mount path: the read path refuses those lazily (bad_dirent family) and
// offline fsck owns the deep scan.
// ---------------------------------------------------------------------------

/// Bit i of a bitmap (LSB-first per byte — the D3 bitmap order).
fn bitmapBit(map: []const u8, i: u32) bool {
    return map[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
}

/// Read block `blk` as the journal overlay reports it: a committed payload
/// dest redirects to its journal block (latest writer wins — dests are in
/// journal order, so scan from the tail). Everything else reads home.
fn checkRead(st: *CheckState, src: SectorSource, blk: u32, out: *[block_len]u8) bool {
    var i = st.dest_count;
    while (i > 0) {
        i -= 1;
        if (st.dests[i].dest == blk) return src.readBlock(st.dests[i].src, out);
    }
    return src.readBlock(blk, out);
}

/// Set block `b`'s reference bit; an already-set bit is extent_overlap.
fn refMark(st: *CheckState, b: u32) Error!void {
    if (bitmapBit(&st.refs, b)) return error.ExtentOverlap;
    st.refs[b / 8] |= @as(u8, 1) << @intCast(b % 8);
}

/// Mark one extent's blocks in refs; out-of-data-range is
/// extent_out_of_range, an already-claimed block is extent_overlap.
/// Returns the extent's block count.
fn markExtent(st: *CheckState, sb: Superblock, first: u32, count: u32) Error!u64 {
    if (first < sb.data_first or count == 0 or @as(u64, first) + count > sb.volume_blocks)
        return error.ExtentOutOfRange;
    var b = first;
    while (b < first + count) : (b += 1) try refMark(st, b);
    return count;
}

/// Walk one live inode's inline extents and its extent-block chain,
/// marking every claimed data block in refs and returning the file's
/// covered block count. Chain blocks themselves count as references, so a
/// data extent claiming one — or a second inode's chain — is overlap.
fn checkExtents(src: SectorSource, sb: Superblock, st: *CheckState, rec: *const [inode_len]u8) Error!u64 {
    var covered: u64 = 0;
    const next: usize = @min(@as(usize, rd16(rec, in_nextents)), inline_extents);
    for (0..next) |e| {
        covered += try markExtent(st, sb, rd32(rec, in_extents + e * 8), rd32(rec, in_extents + e * 8 + 4));
    }
    var chain = rd32(rec, in_next_ext);
    var depth: u32 = 0;
    while (chain != 0) {
        if (depth >= max_extent_blocks) return error.ExtentOverflow;
        depth += 1;
        if (chain < sb.data_first or chain >= sb.volume_blocks) return error.ExtentOutOfRange;
        try refMark(st, chain);
        if (!checkRead(st, src, chain, &st.chain)) return error.Io;
        if (rd32(&st.chain, xb_magic) != magic_extent or
            rd32(&st.chain, xb_cksum) != fnv32(st.chain[0..xb_cksum]) or
            rd16(&st.chain, xb_resv) != 0) return error.ExtentChainCorrupt;
        const cnt = rd16(&st.chain, xb_count);
        if (cnt > extents_per_block) return error.ExtentChainCorrupt;
        for (0..cnt) |e| {
            covered += try markExtent(st, sb, rd32(&st.chain, xb_extents + e * 8), rd32(&st.chain, xb_extents + e * 8 + 4));
        }
        chain = rd32(&st.chain, xb_next);
    }
    return covered;
}

/// The bounded structural check: inode checksums/kinds against the ibitmap,
/// every extent inside the data region and non-overlapping with coverage
/// to size, then the bbitmap explained by exactly one reference (leaks and
/// unmarked use both refuse). Reads go through checkRead, so the verdict
/// is the as-replayed verdict.
fn checkVolume(src: SectorSource, sb: Superblock, st: *CheckState, scratch: *[block_len]u8) Error!void {
    // The ibitmap copies out once — the inode passes consult it by bit.
    const ib_bytes: usize = (sb.inode_count + 7) / 8;
    if (!checkRead(st, src, sb.ibitmap_first, scratch)) return error.Io;
    @memcpy(st.ib_used[0..ib_bytes], scratch[0..ib_bytes]);

    // Inode table: checksum and kind on every slot, then the ibitmap
    // cross-check — a set bit on a free slot or a live slot unmarked is
    // bitmap_inconsistent (inode 0 is exempt: it is pre-allocated free).
    var root_kind: u8 = kind_free;
    var i: u32 = 0;
    while (i < sb.inode_count) : (i += 1) {
        if (i % inodes_per_block == 0) {
            if (!checkRead(st, src, sb.itable_first + i / inodes_per_block, scratch)) return error.Io;
        }
        const rec = scratch[(i % inodes_per_block) * inode_len ..][0..inode_len];
        if (rd32(rec, in_cksum) != fnv32(rec[0..in_cksum])) return error.InodeChecksum;
        const kind = rec[in_kind];
        if (kind != kind_free and kind != kind_file and kind != kind_dir) return error.BadInode;
        if (i == root_inode) root_kind = kind;
        const used = bitmapBit(&st.ib_used, i);
        if (i != 0 and used and kind == kind_free) return error.BitmapInconsistent;
        if (!used and kind != kind_free) return error.BitmapInconsistent;
    }
    if (!bitmapBit(&st.ib_used, 0)) return error.BitmapInconsistent;
    if (root_kind != kind_dir) return error.BadInode;

    // Extents: bounds, cross-inode overlap, and coverage ≥ ⌈size/4096⌉.
    // A checksum-failed slot already refused above; skip it here rather
    // than walk extents nobody validated.
    @memset(st.refs[0 .. (sb.volume_blocks + 7) / 8], 0);
    i = 0;
    while (i < sb.inode_count) : (i += 1) {
        if (i % inodes_per_block == 0) {
            if (!checkRead(st, src, sb.itable_first + i / inodes_per_block, scratch)) return error.Io;
        }
        const raw = scratch[(i % inodes_per_block) * inode_len ..][0..inode_len];
        if (!bitmapBit(&st.ib_used, i) or raw[in_kind] == kind_free) continue;
        if (rd32(raw, in_cksum) != fnv32(raw[0..in_cksum])) continue;
        var rec: [inode_len]u8 = undefined;
        @memcpy(&rec, raw);
        const covered = try checkExtents(src, sb, st, &rec);
        const need = (@as(u64, rd32(&rec, in_size)) + block_len - 1) / block_len;
        if (covered < need) return error.ExtentOutOfRange;
    }

    // bbitmap: every structural block marked; every data-region bit
    // explained by exactly one reference. The map spans bbitmap_blocks
    // blocks — reload the covering map block only when the bit index
    // crosses bits_per_map_block.
    var bb_idx: u32 = std.math.maxInt(u32);
    var b: u32 = 0;
    while (b < sb.volume_blocks) : (b += 1) {
        const idx = b / bits_per_map_block;
        if (idx != bb_idx) {
            bb_idx = idx;
            if (!checkRead(st, src, sb.bbitmap_first + idx, scratch)) return error.Io;
        }
        const marked = bitmapBit(scratch, b % bits_per_map_block);
        const referenced = bitmapBit(&st.refs, b);
        if (b < sb.data_first) {
            if (!marked) return error.BitmapInconsistent;
        } else if (marked != referenced) {
            return error.BitmapInconsistent;
        }
    }
}

// ---------------------------------------------------------------------------
// Inodes (128-B records in the itable; slot i = inode i)
// ---------------------------------------------------------------------------

pub const in_kind: usize = 0;
pub const in_flags: usize = 1;
pub const in_nextents: usize = 2;
pub const in_size: usize = 4;
pub const in_mtime: usize = 8;
pub const in_ctime: usize = 16;
pub const in_extents: usize = 24;
pub const in_next_ext: usize = 88;
pub const in_cksum: usize = 124;

pub const xb_magic: usize = 0;
pub const xb_next: usize = 4;
pub const xb_count: usize = 8;
pub const xb_resv: usize = 10;
pub const xb_extents: usize = 12;
pub const xb_cksum: usize = block_len - 4;

pub const Extent = struct { first: u32, count: u32 };

/// A validated inode record. `nextents` is clamped to the inline array; the
/// disk value is what it is — the extent walk ignores entries past 8.
pub const Inode = struct {
    kind: u8,
    nextents: u16,
    size: u32,
    mtime: u64,
    ctime: u64,
    extents: [inline_extents]Extent,
    next_extent_block: u32,

    pub fn isDir(self: Inode) bool {
        return self.kind == kind_dir;
    }
};

/// Read and validate inode `ino` (1..inode_count-1). A free or corrupt slot
/// is bad_inode — the runtime-corruption refusal, never served bytes.
pub fn readInode(src: SectorSource, vol: Volume, ino: u32, scratch: *[block_len]u8) Error!Inode {
    if (ino == 0 or ino >= vol.inode_count) return error.BadInode;
    const blk = vol.itable_first + ino / inodes_per_block;
    // Bound against the declared itable: a foreign volume whose inode_count
    // overruns itable_blocks must not read inode records out of the data
    // region (geometryError now requires the ceil count).
    if (blk >= vol.itable_first + vol.itable_blocks) return error.BadInode;
    if (!src.readBlock(blk, scratch)) return error.Io;
    const rec = scratch[(ino % inodes_per_block) * inode_len ..][0..inode_len];
    return parseInode(rec);
}

fn parseInode(rec: *const [inode_len]u8) Error!Inode {
    if (rd32(rec, in_cksum) != fnv32(rec[0..in_cksum])) return error.BadInode;
    const kind = rec[in_kind];
    if (kind != kind_file and kind != kind_dir) return error.BadInode;
    var ino = Inode{
        .kind = kind,
        .nextents = @min(rd16(rec, in_nextents), inline_extents),
        .size = rd32(rec, in_size),
        .mtime = rd64(rec, in_mtime),
        .ctime = rd64(rec, in_ctime),
        .extents = undefined,
        .next_extent_block = rd32(rec, in_next_ext),
    };
    for (0..inline_extents) |i| {
        ino.extents[i] = .{
            .first = rd32(rec, in_extents + i * 8),
            .count = rd32(rec, in_extents + i * 8 + 4),
        };
    }
    return ino;
}

/// Map file block index `fblock` to a disk block. Walks the dense inline
/// extents, then up to `max_extent_blocks` chained extent blocks (D3).
/// `null` means the file's extent list does not cover the offset — the
/// caller turns that into bad_extent.
pub fn fileBlock(src: SectorSource, vol: Volume, ino: Inode, fblock: u32, scratch: *[block_len]u8) Error!?u32 {
    var base: u64 = 0;
    for (ino.extents[0..ino.nextents]) |e| {
        if (e.first < vol.data_first or e.count == 0 or
            @as(u64, e.first) + e.count > vol.volume_blocks) return error.BadExtent;
        if (fblock >= base and fblock < base + e.count) return e.first + @as(u32, @intCast(fblock - base));
        base += e.count;
    }
    var chain = ino.next_extent_block;
    for (0..max_extent_blocks) |_| {
        if (chain == 0) break;
        if (chain < vol.data_first or chain >= vol.volume_blocks) return error.ExtentChainCorrupt;
        if (!src.readBlock(chain, scratch)) return error.Io;
        const blk = scratch.*;
        if (rd32(&blk, xb_magic) != magic_extent or rd16(&blk, xb_count) > extents_per_block or
            rd32(&blk, xb_cksum) != fnv32(blk[0..xb_cksum])) return error.ExtentChainCorrupt;
        const count = rd16(&blk, xb_count);
        for (0..count) |e| {
            const first = rd32(&blk, xb_extents + e * 8);
            const n = rd32(&blk, xb_extents + e * 8 + 4);
            if (first < vol.data_first or n == 0 or
                @as(u64, first) + n > vol.volume_blocks) return error.BadExtent;
            if (fblock >= base and fblock < base + n) return first + @as(u32, @intCast(fblock - base));
            base += n;
        }
        chain = rd32(&blk, xb_next);
    }
    return null;
}

/// Read `out` bytes of file `ino` starting at `offset`. Returns bytes read
/// (0 at EOF); a mid-read structural failure stops at the last good byte
/// like fat32_ro, and a failure on the first block is the error.
pub fn read(src: SectorSource, vol: Volume, ino: u32, offset: u64, out: []u8, scratch: *[block_len]u8) Error!usize {
    const rec = try readInode(src, vol, ino, scratch);
    if (rec.kind != kind_file) return error.IsDir;
    return readExtentBytes(src, vol, rec, offset, out, scratch);
}

fn readExtentBytes(src: SectorSource, vol: Volume, rec: Inode, offset: u64, out: []u8, scratch: *[block_len]u8) Error!usize {
    if (offset >= rec.size or out.len == 0) return 0;
    const want: usize = @intCast(@min(@as(u64, out.len), @as(u64, rec.size) - offset));
    var done: usize = 0;
    while (done < want) {
        const pos = offset + done;
        const fblock: u32 = @intCast(pos / block_len);
        const blk = (try fileBlock(src, vol, rec, fblock, scratch)) orelse return error.BadExtent;
        if (!src.readBlock(blk, scratch)) {
            return if (done == 0) error.Io else done;
        }
        const data = scratch.*;
        const boff: usize = @intCast(pos % block_len);
        const n = @min(block_len - boff, want - done);
        @memcpy(out[done..][0..n], data[boff..][0..n]);
        done += n;
    }
    return done;
}

// ---------------------------------------------------------------------------
// Directory entries (272-B records packed inside a directory's payload)
// ---------------------------------------------------------------------------

pub const de_inode: usize = 0;
pub const de_name_len: usize = 4;
pub const de_kind: usize = 6;
pub const de_flags: usize = 7;
pub const de_reserved: usize = 8;
pub const de_name: usize = 16;

pub const Dirent = struct {
    inode: u32,
    kind: u8,
    name_len: u8,
    name: [max_name]u8,

    pub fn nameSlice(self: *const Dirent) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Live-slot capacity of a directory payload of `size` bytes. Dirents pack
/// 15 per 4 KiB block and the trailing 16 B of each block are pad, so a
/// block-aligned size of k blocks holds exactly 15k slots — `size / 272`
/// overcounts from k = 18 up (271 "slots" in 18 blocks, the last of which
/// maps past the final extent). The ceil term keeps a partial tail block's
/// complete rows addressable on a non-aligned foreign image.
pub fn dirSlotCount(size: u32) u32 {
    const blocks = (size + block_len - 1) / block_len;
    return @min(size / @as(u32, dirent_len), blocks * dirents_per_block);
}

/// Sequential reader over a directory's live dirents. The state is a single
/// absolute slot index — `next()` maps it to (block, slot) and re-reads the
/// block through `scratch` every call, so callers may reuse the same scratch
/// between iterations (e.g. stat each dirent's inode while listing).
pub const DirIter = struct {
    src: SectorSource,
    vol: Volume,
    dir: Inode,
    scratch: *[block_len]u8,
    /// Absolute dirent index into the payload: dirSlotCount(size) slots.
    abs_slot: u32 = 0,
    slots_total: u32,

    pub fn init(src: SectorSource, vol: Volume, dir: Inode, scratch: *[block_len]u8) DirIter {
        return .{
            .src = src,
            .vol = vol,
            .dir = dir,
            .scratch = scratch,
            .slots_total = dirSlotCount(dir.size),
        };
    }

    /// The next live dirent, or null at end of directory. Tombstone slots
    /// (inode 0) are skipped; a malformed row is bad_dirent.
    pub fn next(self: *DirIter) Error!?Dirent {
        while (self.abs_slot < self.slots_total) {
            const fblock = self.abs_slot / dirents_per_block;
            const slot = self.abs_slot % dirents_per_block;
            self.abs_slot += 1;
            const disk = (try fileBlock(self.src, self.vol, self.dir, fblock, self.scratch)) orelse
                return error.BadExtent;
            if (!self.src.readBlock(disk, self.scratch)) return error.Io;
            const blk = self.scratch.*;
            const row = blk[slot * dirent_len ..][0..dirent_len];
            const e = try parseDirent(row);
            if (e) |d| {
                if (d.inode >= self.vol.inode_count) return error.BadDirent;
                return d;
            }
        }
        return null;
    }
};

/// Parse one 272-B record; null for a tombstone (inode 0).
fn parseDirent(row: *const [dirent_len]u8) Error!?Dirent {
    const ino = rd32(row, de_inode);
    if (ino == 0) return null;
    const name_len = rd16(row, de_name_len);
    if (name_len == 0 or name_len > max_name) return error.BadDirent;
    const kind = row[de_kind];
    if (kind != kind_file and kind != kind_dir) return error.BadDirent;
    if (row[de_flags] != 0 or rd64(row, de_reserved) != 0) return error.BadDirent;
    const name = row[de_name..][0..name_len];
    if (std.mem.indexOfScalar(u8, name, 0) != null or std.mem.indexOfScalar(u8, name, '/') != null or
        std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
        return error.BadDirent;
    var d = Dirent{ .inode = ino, .kind = kind, .name_len = @intCast(name_len), .name = @splat(0) };
    @memcpy(d.name[0..name_len], name);
    return d;
}

/// Resolve `path` (a canonical, `/`-separated path with no `.`/`..`) to its
/// dirent. The empty path resolves to the root directory itself.
pub fn lookup(src: SectorSource, vol: Volume, path: []const u8, scratch: *[block_len]u8) Error!Dirent {
    var current = Dirent{ .inode = root_inode, .kind = kind_dir, .name_len = 0, .name = @splat(0) };
    if (path.len == 0) return current;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) return error.NotFound;
        const dir = try readInode(src, vol, current.inode, scratch);
        if (dir.kind != kind_dir) return error.NotDir;
        var iter = DirIter.init(src, vol, dir, scratch);
        var found = false;
        while (try iter.next()) |d| {
            if (std.mem.eql(u8, d.nameSlice(), comp)) {
                // The dirent's kind must match the inode it names.
                const child = try readInode(src, vol, d.inode, scratch);
                if (child.kind != d.kind) return error.BadDirent;
                current = d;
                found = true;
                break;
            }
        }
        if (!found) return error.NotFound;
    }
    return current;
}

/// Fill `out` with the name-sorted smallest `out.len` live dirents of
/// directory `dir_ino`. Directories hold at most 1024 live entries (D3);
/// when more exist than fit, the returned prefix is the true first `out.len`
/// by byte-wise name order — the sort is a selection over the full scan,
/// not a sorted subset of a truncated scan.
pub fn listDir(src: SectorSource, vol: Volume, dir_ino: u32, out: []Dirent, scratch: *[block_len]u8) Error!usize {
    const dir = try readInode(src, vol, dir_ino, scratch);
    if (dir.kind != kind_dir) return error.NotDir;
    var iter = DirIter.init(src, vol, dir, scratch);
    var count: usize = 0;
    while (try iter.next()) |d| {
        const name = d.nameSlice();
        if (count < out.len) {
            const pos = insertPos(out[0..count], name);
            shiftInsert(out, pos, d, count + 1);
            count += 1;
        } else if (out.len != 0 and std.mem.order(u8, name, out[out.len - 1].nameSlice()) == .lt) {
            const pos = insertPos(out[0..out.len], name);
            shiftInsert(out, pos, d, out.len);
        }
    }
    return count;
}

fn insertPos(list: []const Dirent, name: []const u8) usize {
    var i: usize = 0;
    while (i < list.len and std.mem.order(u8, list[i].nameSlice(), name) == .lt) : (i += 1) {}
    return i;
}

/// Insert `d` at `pos` in `list[0..keep]`, discarding whatever falls off
/// the end. `keep` is the number of occupied slots INCLUDING the newcomer.
fn shiftInsert(list: []Dirent, pos: usize, d: Dirent, keep: usize) void {
    var i = keep - 1;
    while (i > pos) : (i -= 1) {
        list[i] = list[i - 1];
    }
    list[pos] = d;
}

/// Inode attributes for stat/metadata surfaces.
pub const Stat = struct {
    ino: u32,
    kind: u8,
    size: u32,
    mtime: u64,
    ctime: u64,
};

pub fn stat(src: SectorSource, vol: Volume, ino: u32, scratch: *[block_len]u8) Error!Stat {
    const rec = try readInode(src, vol, ino, scratch);
    return .{ .ino = ino, .kind = rec.kind, .size = rec.size, .mtime = rec.mtime, .ctime = rec.ctime };
}

// ---------------------------------------------------------------------------
// Host tests — fixture images are the committed .regions goldens shared with
// tools/go/vlfs (the two implementations assert the same bytes).
// ---------------------------------------------------------------------------

const empty_regions = @embedFile("testdata/empty-16m.regions");
const populated_regions = @embedFile("testdata/populated-16m.regions");

const test_image_bytes: usize = 16 << 20;

/// An in-memory sector device for tests: read/write/flush over a flat
/// image, with counters so journal-replay ordering is observable.
const MemDisk = struct {
    img: []u8,
    writes: u32 = 0,
    flushes: u32 = 0,
    fail_reads: bool = false,

    fn sector(img: []u8, lba: u64) []u8 {
        const off = lba * sector_len;
        return img[off..][0..sector_len];
    }

    fn readFn(ctx: ?*anyopaque, lba: u64, out: *[sector_len]u8) bool {
        const d: *MemDisk = @ptrCast(@alignCast(ctx));
        if (d.fail_reads) return false;
        if (lba >= d.img.len / sector_len) return false;
        @memcpy(out, sector(d.img, lba));
        return true;
    }

    fn writeFn(ctx: ?*anyopaque, lba: u64, data: *const [sector_len]u8) bool {
        const d: *MemDisk = @ptrCast(@alignCast(ctx));
        if (lba >= d.img.len / sector_len) return false;
        @memcpy(sector(d.img, lba), data);
        d.writes += 1;
        return true;
    }

    fn flushFn(ctx: ?*anyopaque) bool {
        const d: *MemDisk = @ptrCast(@alignCast(ctx));
        d.flushes += 1;
        return true;
    }

    fn rw(self: *MemDisk) SectorSource {
        return .{
            .ctx = self,
            .total_sectors = @intCast(self.img.len / sector_len),
            .readFn = readFn,
            .writeFn = writeFn,
            .flushFn = flushFn,
        };
    }

    fn ro(self: *MemDisk) SectorSource {
        return .{
            .ctx = self,
            .total_sectors = @intCast(self.img.len / sector_len),
            .readFn = readFn,
        };
    }
};

var image_buf: [test_image_bytes]u8 = undefined;

/// Rebuild the image a .regions document describes: zero-fill `bytes`, then
/// place each `<offset> <hex>` run. See tools/go/vlfs/regions.go.
fn buildImage(regions: []const u8, img: []u8) !void {
    @memset(img, 0);
    var it = std.mem.splitScalar(u8, regions, '\n');
    var lines: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (lines == 0) {
            if (!std.mem.eql(u8, line, "vlfs-regions 1")) return error.BadFixture;
            lines += 1;
            continue;
        }
        if (lines == 1) {
            if (!std.mem.startsWith(u8, line, "bytes ")) return error.BadFixture;
            const n = try std.fmt.parseInt(usize, line[6..], 10);
            if (n != img.len) return error.BadFixture;
            lines += 1;
            continue;
        }
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadFixture;
        const off = try std.fmt.parseInt(usize, line[0..sp], 10);
        const hexs = line[sp + 1 ..];
        if (hexs.len % 2 != 0 or off + hexs.len / 2 > img.len) return error.BadFixture;
        _ = try std.fmt.hexToBytes(img[off..][0 .. hexs.len / 2], hexs);
        lines += 1;
    }
}

var test_scratch: [block_len]u8 align(64) = undefined;

test "vlfs: golden empty volume mounts with the ADR geometry" {
    try buildImage(empty_regions, &image_buf);
    var disk = MemDisk{ .img = &image_buf };
    const vol = try mount(disk.ro(), &test_scratch);
    try std.testing.expectEqual(@as(u64, 2), vol.seq); // A is newest (seqs 2/1)
    try std.testing.expectEqual(@as(u64, 0x5eed5eed5eed5eed), vol.volume_id);
    try std.testing.expectEqual(@as(u32, 4096), vol.volume_blocks);
    try std.testing.expectEqual(@as(u32, 2), vol.journal_first);
    try std.testing.expectEqual(@as(u32, 512), vol.journal_blocks);
    try std.testing.expectEqual(@as(u32, 514), vol.ibitmap_first);
    try std.testing.expectEqual(@as(u32, 515), vol.bbitmap_first);
    try std.testing.expectEqual(@as(u32, 1), vol.bbitmap_blocks);
    try std.testing.expectEqual(@as(u32, 516), vol.itable_first);
    try std.testing.expectEqual(@as(u32, 8), vol.itable_blocks);
    try std.testing.expectEqual(@as(u32, 524), vol.data_first);
    try std.testing.expectEqual(@as(u32, 3572), vol.data_blocks);
    try std.testing.expectEqual(@as(u32, 256), vol.inode_count);
    try std.testing.expectEqual(@as(u64, 0), vol.journal_applied);
    try std.testing.expectEqual(@as(u64, 1), vol.next_txn_seq);
    try std.testing.expectEqual(@as(u64, 1760000000), (try stat(disk.ro(), vol, root_inode, &test_scratch)).mtime);
    // Root is a directory with zero live dirents.
    var out: [16]Dirent = undefined;
    try std.testing.expectEqual(@as(usize, 0), try listDir(disk.ro(), vol, root_inode, &out, &test_scratch));
}

test "vlfs: populated golden — lookup, read, sorted readdir, tombstone" {
    try buildImage(populated_regions, &image_buf);
    var disk = MemDisk{ .img = &image_buf };
    const src = disk.ro();
    const vol = try mount(src, &test_scratch);

    // Sorted readdir of the root: APPLE.TXT CHAINED.BIN DOCS EMPTY.BIN ZEBRA.TXT.
    var out: [16]Dirent = undefined;
    const n = try listDir(src, vol, root_inode, &out, &test_scratch);
    try std.testing.expectEqual(@as(usize, 5), n);
    const want_names = [_][]const u8{ "APPLE.TXT", "CHAINED.BIN", "DOCS", "EMPTY.BIN", "ZEBRA.TXT" };
    for (want_names, 0..) |name, i| {
        try std.testing.expectEqualStrings(name, out[i].nameSlice());
    }
    try std.testing.expectEqual(kind_dir, out[2].kind);
    try std.testing.expectEqual(kind_file, out[0].kind);

    // A file spanning two extents-worth of data: APPLE.TXT is 4113 bytes.
    const apple = try lookup(src, vol, "APPLE.TXT", &test_scratch);
    try std.testing.expectEqual(kind_file, apple.kind);
    var buf: [5000]u8 = undefined;
    const got = try read(src, vol, apple.inode, 0, &buf, &test_scratch);
    try std.testing.expectEqual(@as(usize, 4113), got);
    var expect: [BlockLenLiteral + 17]u8 = undefined;
    for (0..BlockLenLiteral + 17) |i| expect[i] = "apple\n"[i % 6];
    try std.testing.expectEqualSlices(u8, expect[0..4113], buf[0..4113]);
    // Offset read lands inside the second block.
    const tail = try read(src, vol, apple.inode, 4110, &buf, &test_scratch);
    try std.testing.expectEqual(@as(usize, 3), tail);
    try std.testing.expectEqualSlices(u8, expect[4110..4113], buf[0..3]);

    // Nested path lookup through two directories.
    const leaf = try lookup(src, vol, "DOCS/DEEP/LEAF.TXT", &test_scratch);
    const lgot = try read(src, vol, leaf.inode, 0, &buf, &test_scratch);
    try std.testing.expectEqualSlices(u8, "leaf\n", buf[0..lgot]);

    // The chained file exercises the extent-block path: 10 single-block
    // extents (8 inline + one VXEB chain block of 2).
    const chained = try lookup(src, vol, "CHAINED.BIN", &test_scratch);
    const cgot = try read(src, vol, chained.inode, 0, &buf, &test_scratch);
    try std.testing.expectEqual(@as(usize, 5000), cgot); // 10 blocks claimed, size caps at buf
    const cino = try readInode(src, vol, chained.inode, &test_scratch);
    try std.testing.expect(cino.next_extent_block != 0);
    const b9 = try fileBlock(src, vol, cino, 9, &test_scratch);
    try std.testing.expect(b9 != null);
    var blk9: [block_len]u8 = undefined;
    try std.testing.expect(src.readBlock(b9.?, &blk9));
    try std.testing.expectEqualStrings("chain-block-9", blk9[0..13]);

    // Empty file, tombstone, misses, and a through-a-file lookup.
    const empty = try lookup(src, vol, "EMPTY.BIN", &test_scratch);
    try std.testing.expectEqual(@as(usize, 0), try read(src, vol, empty.inode, 0, &buf, &test_scratch));
    try std.testing.expectError(error.NotFound, lookup(src, vol, "GONE.TXT", &test_scratch));
    try std.testing.expectError(error.NotFound, lookup(src, vol, "NOPE", &test_scratch));
    try std.testing.expectError(error.NotDir, lookup(src, vol, "APPLE.TXT/X", &test_scratch));
    // The root itself resolves to inode 1 and refuses a byte read.
    const root = try lookup(src, vol, "", &test_scratch);
    try std.testing.expectEqual(@as(u32, 1), root.inode);
    try std.testing.expectError(error.IsDir, read(src, vol, root.inode, 0, &buf, &test_scratch));
}

const BlockLenLiteral: usize = 4096;

test "vlfs: torn newest superblock falls back to the older copy" {
    try buildImage(empty_regions, &image_buf);
    image_buf[100] ^= 0x01; // tear A's cksum-covered body
    var disk = MemDisk{ .img = &image_buf };
    const vol = try mount(disk.ro(), &test_scratch);
    try std.testing.expectEqual(@as(u64, 1), vol.seq);
    try std.testing.expectEqual(@as(u8, 1), vol.sb_slot);
}

test "vlfs: named refusals — not_vlfs, bad_superblock, small, torn dirent" {
    // All-zero image has no magic anywhere.
    @memset(&image_buf, 0);
    var disk = MemDisk{ .img = &image_buf };
    try std.testing.expectError(error.NotVlfs, mount(disk.ro(), &test_scratch));

    // Magic present, checksum broken in both copies.
    try buildImage(empty_regions, &image_buf);
    image_buf[100] ^= 0x01;
    image_buf[block_len + 100] ^= 0x01;
    try std.testing.expectError(error.BadSuperblock, mount(disk.ro(), &test_scratch));

    // A device shorter than the superblock's declared volume refuses.
    try buildImage(empty_regions, &image_buf);
    var short = MemDisk{ .img = image_buf[0 .. 4 * block_len] };
    try std.testing.expectError(error.GeometryMismatch, mount(short.ro(), &test_scratch));

    // Inode checksum corruption surfaces on the read path as bad_inode.
    try buildImage(populated_regions, &image_buf);
    var disk2 = MemDisk{ .img = &image_buf };
    const src = disk2.ro();
    const vol = try mount(src, &test_scratch);
    const apple = try lookup(src, vol, "APPLE.TXT", &test_scratch);
    const ino_off = (@as(usize, vol.itable_first) * block_len) + apple.inode * inode_len;
    image_buf[ino_off + 8] ^= 0x01;
    try std.testing.expectError(error.BadInode, read(src, vol, apple.inode, 0, undefined, &test_scratch));

    // A dirent row with a bogus kind is bad_dirent, not a file listing.
    try buildImage(populated_regions, &image_buf);
    var disk3 = MemDisk{ .img = &image_buf };
    const vol2 = try mount(disk3.ro(), &test_scratch);
    const root_block = @as(usize, vol2.data_first) * block_len;
    image_buf[root_block + de_kind] = 9; // slot 0 = APPLE.TXT
    var out: [16]Dirent = undefined;
    try std.testing.expectError(error.BadDirent, listDir(disk3.ro(), vol2, root_inode, &out, &test_scratch));
}

/// Hand-encode one committed journal transaction (DESC + payload + COMMIT)
/// into the image — the same bytes M100d's write path will emit.
fn journalAppend(img: []u8, pos: u32, seq: u64, dest: u32, payload: *const [block_len]u8) void {
    var desc: [block_len]u8 = @splat(0);
    std.mem.writeInt(u32, desc[jd_magic..][0..4], magic_desc, .little);
    std.mem.writeInt(u64, desc[jd_seq..][0..8], seq, .little);
    std.mem.writeInt(u16, desc[jd_count..][0..2], 1, .little);
    std.mem.writeInt(u32, desc[jd_entries..][0..4], dest, .little);
    std.mem.writeInt(u32, desc[jd_entries + 4 ..][0..4], fnv32(payload), .little);
    std.mem.writeInt(u32, desc[jd_cksum..][0..4], fnv32(desc[0..jd_cksum]), .little);
    @memcpy(img[@as(usize, pos) * block_len ..][0..block_len], &desc);
    @memcpy(img[@as(usize, pos + 1) * block_len ..][0..block_len], payload);
    var commit: [block_len]u8 = @splat(0);
    std.mem.writeInt(u32, commit[jc_magic..][0..4], magic_commit, .little);
    std.mem.writeInt(u64, commit[jc_seq..][0..8], seq, .little);
    var h = fnv32(desc[0 .. jd_entries + 8]);
    h = fnv32Continue(h, payload);
    std.mem.writeInt(u32, commit[jc_txn..][0..4], h, .little);
    std.mem.writeInt(u32, commit[jc_cksum..][0..4], fnv32(commit[0..jc_cksum]), .little);
    @memcpy(img[@as(usize, pos + 2) * block_len ..][0..block_len], &commit);
}

test "vlfs: mount replays a committed transaction; read-only refuses" {
    try buildImage(empty_regions, &image_buf);
    var disk = MemDisk{ .img = &image_buf };
    const src = disk.ro();
    const vol = try mount(src, &test_scratch);
    var payload: [block_len]u8 = @splat(0);
    @memcpy(payload[0..9], "journaled");
    // Commit seq 1 at the journal cursor: dest = root's data block is NOT
    // picked (that would corrupt the tree); use a free data block.
    const dest = vol.data_first + 5;
    journalAppend(&image_buf, vol.journal_first, 1, dest, &payload);

    // Read-only source: the live transaction refuses the mount by name.
    var ro_disk = MemDisk{ .img = &image_buf };
    try std.testing.expectError(error.JournalUnreplayed, mount(ro_disk.ro(), &test_scratch));

    // Writable source: replay lands the payload on dest and ping-pongs the
    // superblock (the older copy, slot 1, now carries seq 3).
    var rw_disk = MemDisk{ .img = &image_buf };
    const vol2 = try mount(rw_disk.rw(), &test_scratch);
    try std.testing.expectEqual(@as(u32, 1), vol2.replayed);
    try std.testing.expectEqual(@as(u64, 1), vol2.journal_applied);
    try std.testing.expectEqual(@as(u64, 2), vol2.next_txn_seq);
    try std.testing.expect(rw_disk.writes > 0 and rw_disk.flushes >= 2);
    var check: [block_len]u8 = undefined;
    try std.testing.expect(rw_disk.ro().readBlock(dest, &check));
    try std.testing.expectEqualSlices(u8, payload[0..9], check[0..9]);
    // The journal region no longer holds live transactions.
    try std.testing.expectEqual(@as(u32, 0), try scanJournal(rw_disk.ro(), .{
        .seq = vol2.seq,
        .volume_id = vol2.volume_id,
        .volume_bytes = @as(u64, vol2.volume_blocks) * block_len,
        .volume_blocks = vol2.volume_blocks,
        .journal_first = vol2.journal_first,
        .journal_blocks = vol2.journal_blocks,
        .ibitmap_first = vol2.ibitmap_first,
        .ibitmap_blocks = 1,
        .bbitmap_first = vol2.bbitmap_first,
        .bbitmap_blocks = vol2.bbitmap_blocks,
        .itable_first = vol2.itable_first,
        .itable_blocks = vol2.itable_blocks,
        .data_first = vol2.data_first,
        .data_blocks = vol2.data_blocks,
        .inode_count = vol2.inode_count,
        .journal_applied = vol2.journal_applied,
        .next_txn_seq = vol2.next_txn_seq,
        .slot = vol2.sb_slot,
    }, &test_scratch));
}

// ---------------------------------------------------------------------------
// M134c (#2761): the corrupt corpus — committed fixtures whose `# expect:`
// line is the host `--check` verdict on the same bytes (regenerate with
// testdata/gen-corrupt.py). mountChecked must reach the same verdict;
// `clean` means the image mounts.
// ---------------------------------------------------------------------------

const corpus_names = [_][]const u8{
    "corrupt-not-vlfs.regions",
    "corrupt-bad-superblock.regions",
    "corrupt-unsupported-version.regions",
    "corrupt-geometry-mismatch.regions",
    "corrupt-inode-checksum.regions",
    "corrupt-bad-inode-kind.regions",
    "corrupt-extent-out-of-range.regions",
    "corrupt-extent-coverage.regions",
    "corrupt-extent-overlap.regions",
    "corrupt-extent-chain-corrupt.regions",
    "corrupt-extent-overflow.regions",
    "corrupt-bitmap-leak.regions",
    "corrupt-bitmap-unmarked.regions",
    "corrupt-ibitmap-free.regions",
    "corrupt-ibitmap-clear.regions",
    "corrupt-journal-torn.regions",
    "corrupt-journal-overlay.regions",
    "corrupt-journal-with-cksum.regions",
};

const CorpusCase = struct { name: []const u8, expect: []const u8, regions: []const u8 };

const corpus = blk: {
    @setEvalBranchQuota(100_000);
    var cases: [corpus_names.len]CorpusCase = undefined;
    for (corpus_names, 0..) |name, i| {
        const regions = @embedFile("testdata/" ++ name);
        var expect: []const u8 = "";
        var it = std.mem.splitScalar(u8, regions, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "# expect: ")) {
                expect = line["# expect: ".len..];
                break;
            }
        }
        cases[i] = .{ .name = name, .expect = expect, .regions = regions };
    }
    break :blk cases;
};

/// Mount-phase refusal names — a verdict outside this set is a check-phase
/// verdict, so `check_error` must be set (attach renders it `check=<name>`).
fn mountPhaseVerdict(name: []const u8) bool {
    const mount_phase = [_][]const u8{
        "io_error",            "not_vlfs",           "bad_superblock",
        "unsupported_version", "geometry_mismatch",  "volume_too_small",
        "volume_too_large",    "journal_unreplayed",
    };
    for (mount_phase) |m| {
        if (std.mem.eql(u8, name, m)) return true;
    }
    return false;
}

test "vlfs check: corrupt corpus verdicts match --check, refused before any write" {
    var st: CheckState = undefined;
    for (corpus) |case| {
        try buildImage(case.regions, &image_buf);
        var disk = MemDisk{ .img = &image_buf };
        const vol = mountChecked(disk.rw(), &test_scratch, &st) catch |err| {
            try std.testing.expectEqualStrings(case.expect, refusalName(err));
            // The check refused before any write: a corrupt image received
            // no byte — replay waits for a clean verdict (the
            // journal-with-cksum fixture pins this with a pending txn).
            try std.testing.expectEqual(@as(u32, 0), disk.writes);
            try std.testing.expectEqual(mountPhaseVerdict(case.expect) == false, st.check_error != null);
            continue;
        };
        try std.testing.expectEqualStrings("clean", case.expect);
        _ = vol;
    }
}

test "vlfs check: committed txn overlay repairs the verdict; read-only still refuses replay" {
    // corrupt-journal-overlay.regions carries a home-state
    // bitmap_inconsistent that only the committed transaction repairs —
    // the check sees the as-replayed overlay (clean), then replay lands it.
    try buildImage(@embedFile("testdata/corrupt-journal-overlay.regions"), &image_buf);
    var disk = MemDisk{ .img = &image_buf };
    var st: CheckState = undefined;
    const vol = try mountChecked(disk.rw(), &test_scratch, &st);
    try std.testing.expectEqual(@as(u32, 1), vol.replayed);
    try std.testing.expect(disk.writes > 0);

    // The same image on a read-only source: the overlay checks clean but
    // replay cannot run, so the operational refusal stands.
    try buildImage(@embedFile("testdata/corrupt-journal-overlay.regions"), &image_buf);
    var ro = MemDisk{ .img = &image_buf };
    var st2: CheckState = undefined;
    try std.testing.expectError(error.JournalUnreplayed, mountChecked(ro.ro(), &test_scratch, &st2));
}

test "vlfs: torn journal tail is discarded, mount still succeeds" {
    try buildImage(empty_regions, &image_buf);
    var disk = MemDisk{ .img = &image_buf };
    const vol = try mount(disk.ro(), &test_scratch);
    var payload: [block_len]u8 = @splat(0);
    @memcpy(payload[0..4], "torn");
    journalAppend(&image_buf, vol.journal_first, 1, vol.data_first + 7, &payload);
    // Corrupt the COMMIT checksum — the record is now torn.
    image_buf[@as(usize, vol.journal_first + 2) * block_len + jc_cksum] ^= 0xff;
    var ro2 = MemDisk{ .img = &image_buf };
    const vol2 = try mount(ro2.ro(), &test_scratch); // torn tail: mounts fine
    try std.testing.expectEqual(@as(u64, 0), vol2.journal_applied);
    try std.testing.expectEqual(@as(u32, 0), vol2.replayed);
    var check: [block_len]u8 = undefined;
    try std.testing.expect(ro2.ro().readBlock(vol.data_first + 7, &check));
    try std.testing.expect(check[0] != 't'); // payload never reached home
}

// #2365: the D3 itable size is ⌈inode_count/32⌉. A 17 MiB image written
// by the pre-amendment truncating formula (inode_count 272, itable_blocks
// 8) leaves its tail inode slots inside the data region, so mount now
// refuses it — and readInode bounds the slot against the declared itable
// for a Volume that never passed geometryError.
var image17_buf: [17 << 20]u8 = undefined;

test "vlfs: truncated itable_blocks geometry refuses mount; readInode bounds the itable" {
    @memset(&image17_buf, 0);
    var disk = MemDisk{ .img = &image17_buf };
    const vol_blocks: u32 = 4352;
    const prefix = Superblock{
        .seq = 2,
        .volume_id = 0x1234,
        .volume_bytes = 17 << 20,
        .volume_blocks = vol_blocks,
        .journal_first = 2,
        .journal_blocks = 512,
        .ibitmap_first = 514,
        .ibitmap_blocks = 1,
        .bbitmap_first = 515,
        .bbitmap_blocks = 1,
        .itable_first = 516,
        .itable_blocks = 8, // truncating 272/32 — the pre-fix shape
        .data_first = 524,
        .data_blocks = vol_blocks - 524,
        .inode_count = 272,
        .journal_applied = 0,
        .next_txn_seq = 1,
        .slot = 0,
    };
    var blk: [block_len]u8 = @splat(0);
    writeSuperblockSector(blk[0..sector_len], prefix);
    try std.testing.expect(disk.rw().writeBlock(0, &blk));
    try std.testing.expect(disk.rw().writeBlock(1, &blk));
    try std.testing.expectError(error.GeometryMismatch, mount(disk.ro(), &test_scratch));

    // The same volume under the ceil rule (itable_blocks 9) mounts, and
    // every inode slot — including the partial tail block — sits inside
    // the itable.
    var fixed = prefix;
    fixed.itable_blocks = 9;
    fixed.data_first = 525;
    fixed.data_blocks = vol_blocks - 525;
    writeSuperblockSector(blk[0..sector_len], fixed);
    try std.testing.expect(disk.rw().writeBlock(0, &blk));
    try std.testing.expect(disk.rw().writeBlock(1, &blk));
    const vol = try mount(disk.ro(), &test_scratch);
    try std.testing.expectEqual(@as(u32, 9), vol.itable_blocks);
    try std.testing.expectEqual(@as(u32, 272), vol.inode_count);
    try std.testing.expectEqual(@as(u32, 525), vol.data_first);
    try std.testing.expect(vol.itable_first + (vol.inode_count - 1) / inodes_per_block < vol.data_first);

    // Defense in depth: a Volume whose inode_count overruns its declared
    // itable must not read records out of the data region — ino 256 maps
    // to itable_first + 8, one block past a truncated 8-block table.
    var wild = vol;
    wild.itable_blocks = 8;
    try std.testing.expectError(error.BadInode, readInode(disk.ro(), wild, 256, &test_scratch));
    try std.testing.expectError(error.BadInode, readInode(disk.ro(), wild, 271, &test_scratch));
    try std.testing.expectError(error.BadInode, readInode(disk.ro(), vol, 272, &test_scratch));
}
