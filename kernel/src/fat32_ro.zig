//! Read-only FAT32 over an arbitrary 512-byte sector source (M70f shard F1,
//! issue #1458).
//!
//! **Why FAT32, and why this is not `fat.zig` coming back.** M34/HF6 deleted
//! the kernel's FAT driver, the ESP/DATA partitions, and the post-exit
//! virtio-blk surface; the host file channel (queue 5) is the guest's storage
//! and it stays FAT-free. A USB stick, though, is FAT32 in the real world, and
//! the whole point of mounting one is to read what somebody else wrote. This
//! module is therefore a NEW, strictly READ-ONLY reader reached only through
//! the `.usb` device tree: no writes, no format, no mount machinery, no DATA
//! partition, no cache, no allocator, and it never touches the boot/EFI volume.
//!
//! **Pure by construction.** The module imports only `std` and takes a
//! `SectorSource` (a function pointer + one opaque context word), so the MBR,
//! BPB, directory, LFN, chain-walk and checksum paths are all host-testable
//! against an in-memory image — no VZ, no hardware. The hardware adapter is
//! `usb_msc.source()`, so the block seam keeps its single owner (`usb_msc`).
//!
//! **v1 limits, stated rather than hidden** (the card's D6):
//!   * 512-byte logical sectors only (`mount` refuses anything else);
//!   * FAT32 only — a FAT12/16 BPB (nonzero 16-bit root-entry count, zero
//!     `fat_sectors`) is `error.NotFat32`; exFAT/NTFS are not attempted;
//!   * read-only: there is no write, truncate, create or delete path here;
//!   * 8.3 short names plus LFN read, but LFN code units are taken as their
//!     low byte (the 8-bit ASCII subset of UTF-16) and a name longer than
//!     `max_name` is truncated — the frozen 40-byte `DirEntry` row is 32
//!     bytes wide, so truncation is a property of the ABI, not a choice here;
//!   * the volume label comes from the BPB only (a root-directory label entry
//!     is skipped, not merged);
//!   * a chain that ends early, points out of range, hits a bad marker, points
//!     at itself, cycles, or fails to END where the file's size says it does
//!     stops at the last byte the disk actually held and latches `broken` —
//!     never a hang, never invented bytes. The EOF check is what makes that
//!     true for a cyclic table (A -> B -> A), which would otherwise keep
//!     serving real clusters until the byte count ran out and look clean;
//!   * a directory walk is bounded by the volume's own cluster count, so a
//!     terminator-less cyclic directory ends as a broken chain instead of
//!     spinning the caller (the monitor's `usb ls` is the shell thread).

const std = @import("std");

/// The only sector size this reader speaks (the M43 block seam's unit).
pub const sector_len: usize = 512;
/// Longest name this reader materializes (8.3 = 12; LFN is truncated here).
pub const max_name: usize = 64;
/// MBR partition slots (the DOS partition table).
pub const max_partitions: usize = 4;

pub const Error = error{
    /// The sector source failed, or the disk ended early.
    Io,
    /// LBA 0 carries no 0xAA55 signature — no DOS partition table.
    NoMbr,
    /// The requested partition slot is empty.
    NoPartition,
    /// A partition exists but does not hold a readable FAT32 volume.
    NotFat32,
    /// A FAT32 BPB with self-inconsistent geometry.
    BadBpb,
    /// The path component does not exist.
    NotFound,
    /// A path component that must be a directory is not one.
    NotDir,
    /// The FAT chain is unusable (EOC/loop/bad marker) — see `broken`.
    BadChain,
};

// ---------------------------------------------------------------------------
// Sector source
// ---------------------------------------------------------------------------

pub const SectorSource = struct {
    ctx: ?*anyopaque = null,
    readFn: *const fn (ctx: ?*anyopaque, lba: u32, out: *[sector_len]u8) bool,

    pub fn read(self: SectorSource, lba: u32, out: *[sector_len]u8) bool {
        return self.readFn(self.ctx, lba, out);
    }
};

// ---------------------------------------------------------------------------
// MBR
// ---------------------------------------------------------------------------

pub const mbr_signature: u16 = 0xaa55;
pub const mbr_entry_base: usize = 446;
pub const mbr_entry_len: usize = 16;
/// DOS partition types that promise a FAT32 volume. `0x0e` is FAT16 LBA and
/// `0xef` is an EFI System Partition; both are refused here on purpose — the
/// card's non-goal is that no boot/EFI volume is mounted, and a USB ESP is not
/// this reader's business in v1.
pub const part_type_fat32: u8 = 0x0b;
pub const part_type_fat32_lba: u8 = 0x0c;

pub const PartitionRow = struct {
    /// 1-based MBR slot (the `N` in `usb<N>`).
    index: u8,
    bootable: bool,
    part_type: u8,
    start_lba: u32,
    sectors: u32,

    pub fn isFat32Type(self: PartitionRow) bool {
        return self.part_type == part_type_fat32 or self.part_type == part_type_fat32_lba;
    }
};

/// Parse the four DOS partition entries out of an LBA-0 sector. False when the
/// 0xAA55 signature is missing (no MBR at all). An entry with type 0 or a zero
/// length is `null` — an empty slot, not an error.
pub fn parseMbr(sector: *const [sector_len]u8, out: *[max_partitions]?PartitionRow) bool {
    if (std.mem.readInt(u16, sector[510..512], .little) != mbr_signature) return false;
    for (0..max_partitions) |i| {
        const e = sector[mbr_entry_base + i * mbr_entry_len ..][0..mbr_entry_len];
        const part_type = e[4];
        const start = std.mem.readInt(u32, e[8..12], .little);
        const count = std.mem.readInt(u32, e[12..16], .little);
        if (part_type == 0 or count == 0) {
            out[i] = null;
            continue;
        }
        out[i] = .{
            .index = @intCast(i + 1),
            .bootable = e[0] == 0x80,
            .part_type = part_type,
            .start_lba = start,
            .sectors = count,
        };
    }
    return true;
}

/// Read LBA 0 and parse its partition table.
pub fn readMbr(src: SectorSource, out: *[max_partitions]?PartitionRow) Error!void {
    var lba0: [sector_len]u8 = undefined;
    if (!src.read(0, &lba0)) return error.Io;
    if (!parseMbr(&lba0, out)) return error.NoMbr;
}

/// Read LBA 0 and return MBR slot `index` (1..4).
pub fn partitionAt(src: SectorSource, index: u8) Error!PartitionRow {
    if (index == 0 or index > max_partitions) return error.NoPartition;
    var table: [max_partitions]?PartitionRow = .{ null, null, null, null };
    try readMbr(src, &table);
    return table[index - 1] orelse error.NoPartition;
}

/// Read LBA 0 and return the first populated FAT32-typed partition, or the
/// first populated partition when none is FAT32-typed (so the caller can say
/// honestly *why* there is no volume).
pub fn firstPartition(src: SectorSource) Error!PartitionRow {
    var table: [max_partitions]?PartitionRow = .{ null, null, null, null };
    try readMbr(src, &table);
    var first: ?PartitionRow = null;
    for (table) |row| {
        const r = row orelse continue;
        if (first == null) first = r;
        if (r.isFat32Type()) return r;
    }
    return first orelse error.NoPartition;
}

// ---------------------------------------------------------------------------
// BPB / volume
// ---------------------------------------------------------------------------

pub const Volume = struct {
    /// MBR partition start (LBA of the volume's boot sector).
    base_lba: u32 = 0,
    /// Absolute LBA of FAT[0].
    fat_start_lba: u32 = 0,
    /// Absolute LBA of the first sector of cluster 2.
    data_start_lba: u32 = 0,
    sectors_per_cluster: u8 = 0,
    cluster_bytes: u32 = 0,
    /// Volume length in sectors (clamped to the partition's declared length).
    total_sectors: u32 = 0,
    /// Usable data clusters; valid cluster numbers are 2..cluster_count+1.
    cluster_count: u32 = 0,
    root_cluster: u32 = 0,
    label: [11]u8 = @as([11]u8, @splat(@as(u8, ' '))),
    has_label: bool = false,

    pub fn maxCluster(self: Volume) u32 {
        return self.cluster_count + 1;
    }

    /// Absolute LBA of the first sector of `cluster`.
    pub fn clusterSector(self: Volume, cluster: u32) ?u32 {
        if (cluster < 2 or cluster > self.cluster_count + 1) return null;
        const spc: u32 = self.sectors_per_cluster;
        const delta = @as(u64, cluster - 2) * spc;
        const lba = @as(u64, self.data_start_lba) + delta;
        if (lba > std.math.maxInt(u32)) return null;
        return @intCast(lba);
    }
};

fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

/// Parse and validate a FAT32 boot sector at `base_lba`. `volume_sectors` is
/// the partition table's declared length (0 = trust the BPB); the result is
/// clamped to it, so a volume can never be read past its partition.
pub fn mount(src: SectorSource, base_lba: u32, volume_sectors: u32) Error!Volume {
    var bs: [sector_len]u8 = undefined;
    if (!src.read(base_lba, &bs)) return error.Io;
    if (rd16(&bs, 510) != mbr_signature) return error.NotFat32;

    const bytes_per_sector = rd16(&bs, 11);
    if (bytes_per_sector != sector_len) return error.NotFat32; // D6: 512-byte sectors only

    const spc = bs[13];
    const reserved = rd16(&bs, 14);
    const nfats = bs[16];
    const root_entries = rd16(&bs, 17);
    const fat_sectors = rd32(&bs, 36);
    const root_cluster = rd32(&bs, 44);

    // The FAT32 discriminators: a FAT12/16 BPB carries a nonzero 16-bit entry
    // count here and leaves `fat_sectors` at zero.
    if (root_entries != 0 or fat_sectors == 0) return error.NotFat32;

    if (spc == 0 or (spc & (spc - 1)) != 0 or spc > 128) return error.BadBpb;
    if (reserved == 0) return error.BadBpb;
    if (nfats == 0 or nfats > 4) return error.BadBpb;

    var total: u32 = rd16(&bs, 19);
    if (total == 0) total = rd32(&bs, 32);
    if (total == 0) return error.BadBpb;
    if (volume_sectors != 0 and volume_sectors < total) total = volume_sectors;

    // 64-bit here on purpose: `fat_sectors * nfats` overflows u32 for a
    // hostile BPB, and a wrapped `overhead` is a wrapped geometry check.
    const overhead64: u64 = @as(u64, reserved) + @as(u64, fat_sectors) * @as(u64, nfats);
    if (overhead64 >= @as(u64, total)) return error.BadBpb;
    const overhead: u32 = @intCast(overhead64);
    const data_sectors = total - overhead;
    const cluster_count = data_sectors / spc;
    if (cluster_count == 0) return error.BadBpb;
    if (root_cluster < 2 or root_cluster > cluster_count + 1) return error.BadBpb;
    // The FAT must have room for every data cluster (+2 reserved entries).
    const fat_bytes: u64 = @as(u64, fat_sectors) * sector_len;
    if (fat_bytes / 4 < @as(u64, cluster_count) + 2) return error.BadBpb;

    // The 8-byte filesystem type string is informational; accept it blank (some
    // builders omit it) but refuse a conflicting declaration.
    const type_str = bs[82..90];
    if (!std.mem.eql(u8, type_str, "FAT32   ") and !std.mem.eql(u8, type_str, "        ")) {
        return error.NotFat32;
    }

    const base_u: u64 = base_lba;
    if (base_u + @as(u64, total) > @as(u64, std.math.maxInt(u32))) return error.BadBpb;

    var vol = Volume{
        .base_lba = base_lba,
        .fat_start_lba = base_lba + reserved,
        .data_start_lba = base_lba + overhead,
        .sectors_per_cluster = spc,
        .cluster_bytes = @as(u32, spc) * @as(u32, sector_len),
        .total_sectors = total,
        .cluster_count = cluster_count,
        .root_cluster = root_cluster,
    };
    @memcpy(&vol.label, bs[71..82]);
    for (vol.label) |c| {
        if (c != ' ' and c != 0) {
            vol.has_label = true;
            break;
        }
    }
    return vol;
}

// ---------------------------------------------------------------------------
// FAT chain
// ---------------------------------------------------------------------------

pub const NextCluster = union(enum) {
    /// The next cluster in the chain (in range).
    next: u32,
    /// End of chain, or a free (0) entry: nothing more follows.
    eoc: void,
    /// A bad marker (0x0FFFFFF7) or an out-of-range cluster number.
    bad: void,
    /// The sector read failed.
    io: void,
};

/// Read the FAT entry for `cluster` and classify it. `max_cluster` is the
/// volume's last valid cluster (see `Volume.maxCluster`).
pub fn fatNext(src: SectorSource, fat_start_lba: u32, cluster: u32, max_cluster: u32, scratch: *[sector_len]u8) NextCluster {
    const byte_off: u64 = @as(u64, cluster) * 4;
    const sector_delta: u64 = byte_off / sector_len;
    const lba64: u64 = @as(u64, fat_start_lba) + sector_delta;
    if (lba64 > std.math.maxInt(u32)) return .bad;
    if (!src.read(@intCast(lba64), scratch)) return .io;
    const off: usize = @intCast(byte_off % sector_len);
    const raw: u32 = std.mem.readInt(u32, scratch[off..][0..4], .little) & 0x0fffffff;
    if (raw >= 0x0ffffff8 or raw == 0) return .eoc;
    if (raw < 2 or raw > max_cluster) return .bad;
    return .{ .next = raw };
}

// ---------------------------------------------------------------------------
// Directory entries (8.3 + LFN)
// ---------------------------------------------------------------------------

pub const entry_free: u8 = 0x00;
pub const entry_deleted: u8 = 0xe5;
pub const entry_korean: u8 = 0x05; // 0xE5 smuggled as a first byte
pub const attr_read_only: u8 = 0x01;
pub const attr_hidden: u8 = 0x02;
pub const attr_system: u8 = 0x04;
pub const attr_volume_id: u8 = 0x08;
pub const attr_directory: u8 = 0x10;
pub const attr_archive: u8 = 0x20;
pub const attr_lfn: u8 = 0x0f;

pub const entry_len: usize = 32;
pub const entries_per_sector: usize = sector_len / entry_len;

pub const Entry = struct {
    name: [max_name]u8 = @as([max_name]u8, @splat(@as(u8, 0))),
    name_len: u8 = 0,
    /// The 8.3 alias, always populated — FAT names an entry twice when it has
    /// an LFN, and both names are valid open() targets on a real volume.
    short: [12]u8 = @as([12]u8, @splat(@as(u8, 0))),
    short_len: u8 = 0,
    attr: u8 = 0,
    first_cluster: u32 = 0,
    size: u32 = 0,
    /// True when the name came from LFN entries (diagnostics).
    long_name: bool = false,

    pub fn nameSlice(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }

    /// True when `comp` names this entry by either of its names.
    pub fn matches(self: *const Entry, comp: []const u8) bool {
        return nameEql(self.nameSlice(), comp) or nameEql(self.short[0..self.short_len], comp);
    }

    pub fn isDir(self: *const Entry) bool {
        return (self.attr & attr_directory) != 0;
    }

    pub fn isReadOnly(self: *const Entry) bool {
        return (self.attr & attr_read_only) != 0;
    }
};

/// The volume root as a directory entry (so lookups and listings share one
/// code path).
pub fn rootEntry(vol: Volume) Entry {
    return .{ .attr = attr_directory, .first_cluster = vol.root_cluster };
}

/// The FAT short-name checksum (the standard 11-byte rotate-add), used to
/// accept an LFN sequence only when it belongs to its short entry.
pub fn shortChecksum(name: []const u8) u8 {
    var sum: u8 = 0;
    for (name) |c| sum = ((sum & 1) << 7) +% (sum >> 1) +% c;
    return sum;
}

/// Build the display form of an 8.3 name: base, '.', extension, space-padded
/// fields trimmed. Case is preserved (comparison is case-insensitive). Writes
/// at most `out.len` bytes and returns the full length (12 at most).
pub fn shortNameOf(raw: []const u8, out: []u8) u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < 8 and i < raw.len) : (i += 1) {
        var c = raw[i];
        if (c == ' ') break;
        if (i == 0 and c == entry_korean) c = 0xe5;
        if (n < out.len) out[n] = c;
        n += 1;
    }
    var ext_len: usize = 0;
    var j: usize = 8;
    while (j < 11 and j < raw.len) : (j += 1) {
        if (raw[j] == ' ') break;
        ext_len += 1;
    }
    if (ext_len > 0) {
        if (n < out.len) out[n] = '.';
        n += 1;
        var k: usize = 0;
        while (k < ext_len) : (k += 1) {
            if (n < out.len) out[n] = raw[8 + k];
            n += 1;
        }
    }
    return @intCast(n);
}

/// Case-insensitive ASCII equality (the FAT way: `PROBE.TXT` == `probe.txt`).
pub fn nameEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toUpper(x) != std.ascii.toUpper(y)) return false;
    }
    return true;
}

/// Sequential directory reader: walks the directory's cluster chain one sector
/// at a time, assembling LFN names across entries. `next()` returning null
/// means end-of-directory (or an unusable chain — check `broken`).
pub const DirIter = struct {
    src: SectorSource,
    vol: Volume,
    cluster: u32 = 0,
    sector_in_cluster: u32 = 0,
    entry_index: u32 = 0,
    sector: [sector_len]u8 = undefined,
    sector_valid: bool = false,
    done: bool = false,
    broken: bool = false,
    /// Clusters walked so far. A directory chain is bounded by the volume's
    /// own cluster count, so a cyclic table (A -> B -> A with no 0x00
    /// terminator) ends as a broken chain instead of wedging the console —
    /// the monitor's `usb ls` loop is on the single-threaded shell path.
    clusters_walked: u32 = 0,
    /// LFN assembly state.
    lfn: [max_name]u8 = @as([max_name]u8, @splat(@as(u8, 0))),
    lfn_len: u8 = 0,
    lfn_checksum: u8 = 0,
    lfn_expect: u8 = 0, // sequence number the next part must carry
    lfn_active: bool = false,

    pub fn next(self: *DirIter) ?Entry {
        while (self.nextRaw()) |raw| {
            if (raw[0] == entry_free) {
                self.done = true;
                return null;
            }
            if (raw[0] == entry_deleted) {
                self.resetLfn();
                continue;
            }
            const attr = raw[11];
            if ((attr & attr_lfn) == attr_lfn) {
                self.storeLfn(raw);
                continue;
            }
            if ((attr & attr_volume_id) != 0) {
                // A volume-label entry is metadata, not a file.
                self.resetLfn();
                continue;
            }
            var e = Entry{
                .attr = attr,
                .first_cluster = rd32(raw, 20),
                .size = rd32(raw, 28),
            };
            e.short_len = shortNameOf(raw[0..11], e.short[0..]);
            if (self.lfn_active and self.lfn_expect == 0 and self.lfn_len > 0 and
                shortChecksum(raw[0..11]) == self.lfn_checksum)
            {
                @memcpy(e.name[0..self.lfn_len], self.lfn[0..self.lfn_len]);
                e.name_len = self.lfn_len;
                e.long_name = true;
            } else {
                @memcpy(e.name[0..e.short_len], e.short[0..e.short_len]);
                e.name_len = e.short_len;
            }
            self.resetLfn();
            if (e.name_len == 0) continue;
            if (e.name[0] == '.' and (e.name_len == 1 or
                (e.name_len == 2 and e.name[1] == '.'))) continue;
            if (e.isDir()) e.size = 0;
            return e;
        }
        return null;
    }

    fn resetLfn(self: *DirIter) void {
        self.lfn_active = false;
        self.lfn_len = 0;
        self.lfn_checksum = 0;
        self.lfn_expect = 0;
    }

    fn storeLfn(self: *DirIter, raw: []const u8) void {
        const ord = raw[0];
        const seq: u8 = ord & 0x1f;
        if (ord & 0x40 != 0) {
            // The first (highest-sequence) part starts a new run.
            self.lfn = @as([max_name]u8, @splat(@as(u8, 0)));
            self.lfn_len = 0;
            self.lfn_checksum = raw[13];
            self.lfn_expect = seq;
            self.lfn_active = true;
        }
        if (!self.lfn_active or seq == 0 or seq != self.lfn_expect) {
            self.resetLfn();
            return;
        }
        // 13 UTF-16 code units: 5 + 6 + 2. v1 takes the low byte of each.
        const pos: usize = @as(usize, seq - 1) * 13;
        const offsets = [_]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
        var k: usize = 0;
        for (offsets) |off| {
            const c = raw[off];
            if (c == 0 or c == 0xff) {
                k += 1;
                continue;
            }
            const idx = pos + k;
            if (idx < max_name) {
                self.lfn[idx] = c;
                if (idx + 1 > self.lfn_len) self.lfn_len = @intCast(idx + 1);
            }
            k += 1;
        }
        self.lfn_expect = seq - 1;
    }

    fn nextRaw(self: *DirIter) ?[]const u8 {
        while (true) {
            if (self.done) return null;
            if (!self.sector_valid or self.entry_index >= entries_per_sector) {
                if (!self.advance()) return null;
            }
            const raw = self.sector[@as(usize, self.entry_index) * entry_len ..][0..entry_len];
            self.entry_index += 1;
            return raw;
        }
    }

    /// Move to the next sector of the directory (next sector in the cluster,
    /// then the next cluster in the chain).
    fn advance(self: *DirIter) bool {
        if (self.cluster == 0) {
            self.cluster = self.vol.root_cluster;
            self.sector_in_cluster = 0;
        } else if (self.sector_valid) {
            self.sector_in_cluster += 1;
            if (self.sector_in_cluster >= self.vol.sectors_per_cluster) {
                switch (fatNext(self.src, self.vol.fat_start_lba, self.cluster, self.vol.maxCluster(), &self.sector)) {
                    .next => |n| {
                        // A directory chain may not point at itself, and no
                        // directory can span more clusters than the volume
                        // holds: either one is a broken chain, not a long
                        // listing.
                        if (n == self.cluster or self.clusters_walked >= self.vol.cluster_count) {
                            self.broken = true;
                            self.done = true;
                            return false;
                        }
                        self.clusters_walked += 1;
                        self.cluster = n;
                        self.sector_in_cluster = 0;
                    },
                    .eoc => {
                        self.done = true;
                        return false;
                    },
                    .bad, .io => {
                        self.broken = true;
                        self.done = true;
                        return false;
                    },
                }
            }
        }
        const lba = self.vol.clusterSector(self.cluster) orelse {
            self.broken = true;
            self.done = true;
            return false;
        };
        // 64-bit: `lba + sector_in_cluster` wraps in u32 before any range
        // check could see it.
        const lba_abs: u64 = @as(u64, lba) + self.sector_in_cluster;
        // `fatNext` reuses `sector` as its own scratch, so read after it.
        if (lba_abs > std.math.maxInt(u32)) {
            self.broken = true;
            self.done = true;
            return false;
        }
        if (!self.src.read(@intCast(lba_abs), &self.sector)) {
            self.broken = true;
            self.done = true;
            return false;
        }
        self.sector_valid = true;
        self.entry_index = 0;
        return true;
    }
};

pub fn dirIter(src: SectorSource, vol: Volume, first_cluster: u32) DirIter {
    return .{ .src = src, .vol = vol, .cluster = first_cluster };
}

/// Resolve a `/`-separated path relative to the volume root. An empty path (or
/// one of only slashes / `.`) resolves to the root directory.
pub fn lookup(src: SectorSource, vol: Volume, path: []const u8, out: *Entry) Error!void {
    var cur = rootEntry(vol);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or (comp.len == 1 and comp[0] == '.')) continue;
        if (!cur.isDir()) return error.NotDir;
        var found: ?Entry = null;
        var iter = dirIter(src, vol, cur.first_cluster);
        while (iter.next()) |e| {
            if (e.matches(comp)) {
                found = e;
                break;
            }
        }
        cur = found orelse {
            // A directory whose chain failed is an unusable volume, not a
            // missing file — say which.
            if (iter.broken) return error.BadChain;
            return error.NotFound;
        };
    }
    out.* = cur;
}

/// Write up to `out.len` directory entries at `path`; returns how many were
/// written. A path that names a file is `error.NotDir`.
pub fn list(src: SectorSource, vol: Volume, path: []const u8, out: []Entry) Error!usize {
    var dir: Entry = undefined;
    try lookup(src, vol, path, &dir);
    if (!dir.isDir()) return error.NotDir;
    var n: usize = 0;
    var iter = dirIter(src, vol, dir.first_cluster);
    while (iter.next()) |e| {
        if (n >= out.len) break;
        out[n] = e;
        n += 1;
    }
    if (iter.broken and n == 0) return error.BadChain;
    return n;
}

// ---------------------------------------------------------------------------
// Sequential file reads
// ---------------------------------------------------------------------------

pub const FileReader = struct {
    fat_start_lba: u32 = 0,
    data_start_lba: u32 = 0,
    cluster_bytes: u32 = 0,
    max_cluster: u32 = 0,
    cluster: u32 = 0,
    cluster_off: u32 = 0,
    remaining: u32 = 0,
    /// Set once the first byte has been served (a zero-length file never
    /// touches the FAT, so it has no chain to verify).
    started: bool = false,
    /// Set once the chain's end has been checked against the file's size.
    ended: bool = false,
    /// Set when the chain ended before `remaining` reached 0, pointed at
    /// itself, cycled, or failed to end where the size says it does.
    broken: bool = false,

    pub fn init(vol: Volume, e: Entry) FileReader {
        return .{
            .fat_start_lba = vol.fat_start_lba,
            .data_start_lba = vol.data_start_lba,
            .cluster_bytes = vol.cluster_bytes,
            .max_cluster = vol.maxCluster(),
            .cluster = e.first_cluster,
            .remaining = e.size,
        };
    }
};

/// Copy up to `out.len` bytes of the file into `out`, advancing `r`. Returns
/// the bytes copied; 0 means EOF (or a chain that failed on the first byte —
/// see `r.broken`). Never returns invented bytes: a broken chain stops at the
/// last byte the disk actually held.
pub fn readFile(src: SectorSource, r: *FileReader, out: []u8, scratch: *[sector_len]u8) usize {
    var total: usize = 0;
    while (total < out.len and r.remaining > 0) {
        if (r.cluster < 2) {
            r.broken = true;
            break;
        }
        if (r.cluster_off >= r.cluster_bytes) {
            switch (fatNext(src, r.fat_start_lba, r.cluster, r.max_cluster, scratch)) {
                .next => |n| {
                    // A chain that points at itself never advances, so it can
                    // only ever repeat one cluster's bytes.
                    if (n == r.cluster) {
                        r.broken = true;
                        break;
                    }
                    r.cluster = n;
                    r.cluster_off = 0;
                },
                .eoc, .bad, .io => {
                    r.broken = true;
                    break;
                },
            }
        }
        const spc: u32 = r.cluster_bytes / @as(u32, sector_len);
        const lba64: u64 = @as(u64, r.data_start_lba) +
            @as(u64, r.cluster - 2) * spc +
            r.cluster_off / sector_len;
        if (lba64 > std.math.maxInt(u32)) {
            r.broken = true;
            break;
        }
        if (!src.read(@intCast(lba64), scratch)) {
            r.broken = true;
            break;
        }
        const in_sector: u32 = r.cluster_off % @as(u32, sector_len);
        const left_in_sector = @as(u32, sector_len) - in_sector;
        const left_in_cluster = r.cluster_bytes - r.cluster_off;
        var take = @min(left_in_sector, left_in_cluster);
        take = @min(take, r.remaining);
        take = @min(take, @as(u32, @intCast(out.len - total)));
        @memcpy(out[total..][0..take], scratch[in_sector..][0..take]);
        total += take;
        r.cluster_off += take;
        r.remaining -= take;
        r.started = true;
    }

    // The chain must END where the file's size says it does. Without this a
    // cyclic table (A -> B -> A) keeps serving real on-disk clusters until
    // `remaining` runs out and reports a clean read of bytes that were never
    // this file — the opposite of the guarantee every caller relies on. One
    // extra FAT read at EOF makes the guarantee true. An I/O failure here does
    // not cast doubt on bytes already copied, so it is not latched; a chain
    // that continues past the size is.
    if (!r.broken and r.started and r.remaining == 0 and !r.ended) {
        r.ended = true;
        switch (fatNext(src, r.fat_start_lba, r.cluster, r.max_cluster, scratch)) {
            .eoc, .io => {},
            .next, .bad => r.broken = true,
        }
    }
    return total;
}

// ---------------------------------------------------------------------------
// Content checksum (the byte-exact proof without a 5 KB serial dump)
// ---------------------------------------------------------------------------

pub const fnv_offset_basis: u32 = 2166136261;
pub const fnv_prime: u32 = 16777619;

/// FNV-1a 32-bit over `bytes`, continuing from `seed`.
pub fn fnv1a32(seed: u32, bytes: []const u8) u32 {
    var h = seed;
    for (bytes) |b| {
        h ^= b;
        h *%= fnv_prime;
    }
    return h;
}

pub const Fnv = struct {
    h: u32 = fnv_offset_basis,

    pub fn update(self: *Fnv, bytes: []const u8) void {
        self.h = fnv1a32(self.h, bytes);
    }

    pub fn digest(self: *const Fnv) u32 {
        return self.h;
    }
};

// ---------------------------------------------------------------------------
// Host tests — an in-memory FAT32 image, no hardware
// ---------------------------------------------------------------------------

/// A host-side image builder: an 8 MiB-equivalent disk is unnecessary, so the
/// test geometry is small but structurally identical to the gate's staged
/// image (MBR -> FAT32 BPB -> two FATs -> root dir -> subdirectory ->
/// multi-cluster file). `sectors_per_cluster` and the cluster count differ from
/// the live image on purpose: the reader must be geometry-generic.
const TestImage = struct {
    const total_sectors = 512; // 256 KiB
    const spc = 2; // 1 KiB clusters
    const reserved = 4;
    const nfats = 2;
    const fat_sectors = 4;
    const data_start = reserved + nfats * fat_sectors; // sector 12
    const vol_sectors = total_sectors - 8; // partition starts at LBA 8
    const cluster_count = (vol_sectors - (reserved + nfats * fat_sectors)) / spc;

    bytes: []u8,

    fn init(alloc: std.mem.Allocator) !TestImage {
        const b = try alloc.alloc(u8, total_sectors * sector_len);
        @memset(b, 0);
        return .{ .bytes = b };
    }

    fn sector(self: *TestImage, lba: u32) *[sector_len]u8 {
        return self.bytes[@as(usize, lba) * sector_len ..][0..sector_len];
    }

    /// Absolute LBA of the first sector of `cluster` (cluster 2 = data_start).
    fn clusterSector(_: *TestImage, cluster: u32, index: u32) u32 {
        return 8 + data_start + (cluster - 2) * spc + index;
    }

    fn setFat(self: *TestImage, cluster: u32, value: u32) void {
        const byte_off: usize = @as(usize, cluster) * 4;
        const sec: usize = 8 + reserved + byte_off / sector_len;
        const off = byte_off % sector_len;
        std.mem.writeInt(u32, self.bytes[sec * sector_len + off ..][0..4], value, .little);
        // Mirror into the second FAT.
        const sec2 = sec + fat_sectors;
        std.mem.writeInt(u32, self.bytes[sec2 * sector_len + off ..][0..4], value, .little);
    }

    fn writeClusters(self: *TestImage, first: u32, content: []const u8) void {
        const cluster_bytes = spc * sector_len;
        var off: usize = 0;
        var cluster = first;
        while (off < content.len) {
            const n = @min(cluster_bytes, content.len - off);
            const start = @as(usize, self.clusterSector(cluster, 0)) * sector_len;
            @memcpy(self.bytes[start .. start + n], content[off .. off + n]);
            off += n;
            const more = off < content.len;
            self.setFat(cluster, if (more) cluster + 1 else 0x0fffffff);
            cluster += 1;
        }
    }

    fn dirEntry(self: *TestImage, sector_lba: u32, slot: usize, name83: []const u8, attr: u8, first_cluster: u32, size: u32) void {
        const base = @as(usize, sector_lba) * sector_len + slot * entry_len;
        @memcpy(self.bytes[base .. base + 11], name83[0..11]);
        self.bytes[base + 11] = attr;
        std.mem.writeInt(u16, self.bytes[base + 20 ..][0..2], @intCast(first_cluster & 0xffff), .little);
        std.mem.writeInt(u16, self.bytes[base + 26 ..][0..2], @intCast((first_cluster >> 16) & 0xffff), .little);
        std.mem.writeInt(u32, self.bytes[base + 28 ..][0..4], size, .little);
    }

    /// One LFN part (13 UTF-16 units encoded as low bytes + 0 padding).
    fn lfnEntry(self: *TestImage, sector_lba: u32, slot: usize, seq: u8, last: bool, checksum: u8, text: []const u8) void {
        const base = @as(usize, sector_lba) * sector_len + slot * entry_len;
        @memset(self.bytes[base .. base + entry_len], 0);
        self.bytes[base] = seq | (if (last) @as(u8, 0x40) else 0);
        self.bytes[base + 11] = attr_lfn;
        self.bytes[base + 13] = checksum;
        const offsets = [_]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
        for (offsets, 0..) |off, k| {
            if (k < text.len) {
                self.bytes[base + off] = text[k];
            } else {
                self.bytes[base + off] = 0;
                if (k == text.len) {
                    std.mem.writeInt(u16, self.bytes[base + off ..][0..2], 0x0000, .little);
                }
            }
        }
    }

    fn buildMbr(self: *TestImage) void {
        const s = self.sector(0);
        // Slot 1: FAT32 LBA at LBA 8 (the volume under test).
        const e1 = s[446..462];
        e1[0] = 0x80;
        e1[4] = part_type_fat32_lba;
        std.mem.writeInt(u32, e1[8..12], 8, .little);
        std.mem.writeInt(u32, e1[12..16], vol_sectors, .little);
        // Slot 2: a non-FAT32-typed partition outside the volume.
        const e2 = s[462..478];
        e2[4] = 0x83;
        std.mem.writeInt(u32, e2[8..12], 440, .little);
        std.mem.writeInt(u32, e2[12..16], 32, .little);
        std.mem.writeInt(u16, s[510..512], mbr_signature, .little);
    }

    fn buildBpb(self: *TestImage) void {
        const s = self.sector(8);
        s[0] = 0xeb;
        s[1] = 0x3c;
        s[2] = 0x90;
        @memcpy(s[3..11], "TESTIMG ");
        std.mem.writeInt(u16, s[11..13], sector_len, .little);
        s[13] = spc;
        std.mem.writeInt(u16, s[14..16], reserved, .little);
        s[16] = nfats;
        std.mem.writeInt(u16, s[17..19], 0, .little); // FAT32: no 16-bit root count
        std.mem.writeInt(u16, s[19..21], 0, .little); // 16-bit total = 0
        s[21] = 0xf8;
        std.mem.writeInt(u32, s[32..36], vol_sectors, .little);
        std.mem.writeInt(u32, s[36..40], fat_sectors, .little);
        std.mem.writeInt(u32, s[44..48], 2, .little); // root cluster
        s[66] = 0x29;
        std.mem.writeInt(u32, s[67..71], 0x44544554, .little);
        @memcpy(s[71..82], "TESTVOL    ");
        @memcpy(s[82..90], "FAT32   ");
        std.mem.writeInt(u16, s[510..512], mbr_signature, .little);
        // FAT[0]/FAT[1] reserved entries + the root cluster's EOC.
        self.setFat(0, 0x0ffffff8);
        self.setFat(1, 0x0fffffff);
        self.setFat(2, 0x0fffffff); // root
    }

    /// A complete image: `PROBE.TXT` (13 bytes, cluster 3), `DOCS/` (cluster 4)
    /// holding `.`, `..` and `NOTE.TXT` (3 clusters, 2500 bytes).
    fn build(alloc: std.mem.Allocator) !TestImage {
        var img = try TestImage.init(alloc);
        img.buildMbr();
        img.buildBpb();

        const probe_content = "hello, fatchain!\n"; // 17 bytes
        img.writeClusters(3, probe_content);

        const note_len: usize = 2500;
        const note = try alloc.alloc(u8, note_len);
        defer alloc.free(note);
        for (note, 0..) |*c, i| c.* = @intCast('a' + (i % 26));
        img.writeClusters(5, note); // clusters 5 -> 6 -> 7

        // Root directory (cluster 2, one sector is enough).
        const root = img.clusterSector(2, 0);
        img.dirEntry(root, 0, "TESTVOL    ", attr_volume_id, 0, 0);
        img.dirEntry(root, 1, "PROBE   TXT", attr_archive, 3, @intCast(probe_content.len));
        img.dirEntry(root, 2, "DOCS       ", attr_directory, 4, 0);
        const docs = img.clusterSector(4, 0);
        img.dirEntry(docs, 0, ".          ", attr_directory, 4, 0);
        img.dirEntry(docs, 1, "..         ", attr_directory, 0, 0);
        img.dirEntry(docs, 2, "NOTE    TXT", attr_archive, 5, note_len);
        return img;
    }

    fn source(self: *TestImage) SectorSource {
        return .{ .ctx = self, .readFn = readFn };
    }

    fn readFn(ctx: ?*anyopaque, lba: u32, out: *[sector_len]u8) bool {
        const self: *TestImage = @ptrCast(@alignCast(ctx.?));
        const off = @as(usize, lba) * sector_len;
        if (off + sector_len > self.bytes.len) return false;
        @memcpy(out, self.bytes[off .. off + sector_len]);
        return true;
    }
};

test "fat32_ro: MBR parse accepts a signed table and marks empty slots" {
    var img = try TestImage.build(std.testing.allocator);
    defer std.testing.allocator.free(img.bytes);

    var table: [max_partitions]?PartitionRow = undefined;
    try std.testing.expect(parseMbr(img.sector(0), &table));
    try std.testing.expect(table[0] != null);
    try std.testing.expectEqual(@as(u8, 1), table[0].?.index);
    try std.testing.expect(table[0].?.bootable);
    try std.testing.expect(table[0].?.isFat32Type());
    try std.testing.expectEqual(@as(u32, 8), table[0].?.start_lba);
    try std.testing.expect(table[1] != null);
    try std.testing.expect(!table[1].?.isFat32Type());
    try std.testing.expect(table[2] == null);
    try std.testing.expect(table[3] == null);

    // An unsigned LBA 0 is not a partition table at all.
    var bare: [sector_len]u8 = @as([sector_len]u8, @splat(@as(u8, 0)));
    try std.testing.expect(!parseMbr(&bare, &table));

    // The classifier picks the FAT32-typed slot, and refuses out-of-range indices.
    const p1 = try partitionAt(img.source(), 1);
    try std.testing.expectEqual(@as(u32, 8), p1.start_lba);
    try std.testing.expectError(error.NoPartition, partitionAt(img.source(), 3));
    try std.testing.expectError(error.NoPartition, partitionAt(img.source(), 5));
    const chosen = try firstPartition(img.source());
    try std.testing.expectEqual(@as(u8, 1), chosen.index);
}

test "fat32_ro: mount validates FAT32 geometry and clamps to the partition" {
    var img = try TestImage.build(std.testing.allocator);
    defer std.testing.allocator.free(img.bytes);

    var table: [max_partitions]?PartitionRow = undefined;
    _ = parseMbr(img.sector(0), &table);
    const row = table[0].?;
    const vol = try mount(img.source(), row.start_lba, row.sectors);
    try std.testing.expectEqual(@as(u32, 8), vol.base_lba);
    try std.testing.expectEqual(@as(u32, 8 + TestImage.reserved), vol.fat_start_lba);
    try std.testing.expectEqual(@as(u32, 8 + TestImage.data_start), vol.data_start_lba);
    try std.testing.expectEqual(@as(u8, TestImage.spc), vol.sectors_per_cluster);
    try std.testing.expectEqual(@as(u32, TestImage.spc * sector_len), vol.cluster_bytes);
    try std.testing.expectEqual(@as(u32, 2), vol.root_cluster);
    try std.testing.expect(vol.has_label);
    try std.testing.expectEqualStrings("TESTVOL    ", &vol.label);
    try std.testing.expectEqual(@as(u32, TestImage.cluster_count), vol.cluster_count);

    // A FAT16-shaped BPB (nonzero 16-bit root-entry count) is not FAT32.
    var byte_buf: [sector_len]u8 = undefined;
    _ = img.source().read(row.start_lba, &byte_buf);
    var mod_img = TestImage{ .bytes = &byte_buf };
    std.mem.writeInt(u16, byte_buf[17..19], 512, .little);
    std.mem.writeInt(u32, byte_buf[36..40], 0, .little);
    try std.testing.expectError(error.NotFat32, mount(mod_img.source(), 0, 0));

    // A conflicting filesystem-type string is refused outright.
    std.mem.writeInt(u16, byte_buf[17..19], 0, .little);
    std.mem.writeInt(u32, byte_buf[36..40], TestImage.fat_sectors, .little);
    @memcpy(byte_buf[82..90], "NTFS    ");
    try std.testing.expectError(error.NotFat32, mount(mod_img.source(), 0, 0));

    // Zero sectors per cluster, a zero root cluster, and an out-of-range root
    // cluster are each BadBpb rather than a read that walks off the volume.
    @memcpy(byte_buf[82..90], "FAT32   ");
    byte_buf[13] = 0;
    try std.testing.expectError(error.BadBpb, mount(mod_img.source(), 0, 0));
    byte_buf[13] = TestImage.spc;
    std.mem.writeInt(u32, byte_buf[44..48], 1, .little);
    try std.testing.expectError(error.BadBpb, mount(mod_img.source(), 0, 0));
    std.mem.writeInt(u32, byte_buf[44..48], TestImage.cluster_count + 9, .little);
    try std.testing.expectError(error.BadBpb, mount(mod_img.source(), 0, 0));
    // A 1024-byte-sector BPB is outside v1's contract, stated not silent.
    std.mem.writeInt(u32, byte_buf[44..48], 2, .little);
    std.mem.writeInt(u16, byte_buf[11..13], 1024, .little);
    try std.testing.expectError(error.NotFat32, mount(mod_img.source(), 0, 0));
}

test "fat32_ro: directory listing skips metadata, deleted, dot and . entries" {
    var img = try TestImage.build(std.testing.allocator);
    defer std.testing.allocator.free(img.bytes);
    const src = img.source();
    const vol = try mount(src, 8, TestImage.vol_sectors);

    var entries: [16]Entry = undefined;
    const n = try list(src, vol, "", entries[0..]);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("PROBE.TXT", entries[0].nameSlice());
    try std.testing.expectEqual(@as(u32, 17), entries[0].size);
    try std.testing.expectEqual(@as(u32, 3), entries[0].first_cluster);
    try std.testing.expect(!entries[0].isDir());
    try std.testing.expectEqualStrings("DOCS", entries[1].nameSlice());
    try std.testing.expect(entries[1].isDir());
    try std.testing.expectEqual(@as(u32, 0), entries[1].size); // a dir's size is not data

    // The subdirectory lists only its file: `.` and `..` are skipped.
    const nd = try list(src, vol, "DOCS", entries[0..]);
    try std.testing.expectEqual(@as(usize, 1), nd);
    try std.testing.expectEqualStrings("NOTE.TXT", entries[0].nameSlice());
    try std.testing.expectEqual(@as(u32, 2500), entries[0].size);

    // The root resolves to itself, a missing name and a file-as-dir are honest.
    var e: Entry = undefined;
    try lookup(src, vol, "", &e);
    try std.testing.expect(e.isDir());
    try std.testing.expectError(error.NotFound, lookup(src, vol, "NOPE.TXT", &e));
    try std.testing.expectError(error.NotDir, lookup(src, vol, "PROBE.TXT/SUB", &e));
    try std.testing.expectError(error.NotDir, list(src, vol, "PROBE.TXT", entries[0..]));

    // Lookup is case-insensitive and accepts the 8.3 form with and without a dot.
    try lookup(src, vol, "probe.txt", &e);
    try std.testing.expectEqualStrings("PROBE.TXT", e.nameSlice());
    try lookup(src, vol, "/docs/note.txt", &e);
    try std.testing.expectEqualStrings("NOTE.TXT", e.nameSlice());
    try lookup(src, vol, "docs//note.txt", &e); // empty components collapse
}

test "fat32_ro: a multi-cluster file reads byte-exact through the chain" {
    var img = try TestImage.build(std.testing.allocator);
    defer std.testing.allocator.free(img.bytes);
    const src = img.source();
    const vol = try mount(src, 8, TestImage.vol_sectors);

    var e: Entry = undefined;
    try lookup(src, vol, "DOCS/NOTE.TXT", &e);
    try std.testing.expectEqual(@as(u32, 2500), e.size);
    try std.testing.expect(e.first_cluster == 5);
    // 2500 bytes at 1024 bytes/cluster spans 5 -> 6 -> 7.
    var scratch: [sector_len]u8 = undefined;
    const nx = fatNext(src, vol.fat_start_lba, 5, vol.maxCluster(), &scratch);
    try std.testing.expect(nx == .next and nx.next == 6);

    var reader = FileReader.init(vol, e);
    var out: [2500]u8 = undefined;
    // Read in awkward, non-sector-aligned chunks: the result must be identical
    // to a single big read, byte for byte.
    var got: usize = 0;
    var chunk: usize = 0;
    const sizes = [_]usize{ 7, 100, 1, 512, 111, 769, 999, 32 };
    while (got < out.len) : (chunk += 1) {
        const want = @min(sizes[chunk % sizes.len], out.len - got);
        const n = readFile(src, &reader, out[got .. got + want], &scratch);
        if (n == 0) break;
        got += n;
    }
    try std.testing.expectEqual(@as(usize, 2500), got);
    try std.testing.expect(!reader.broken);
    for (out, 0..) |c, i| try std.testing.expectEqual(@as(u8, @intCast('a' + (i % 26))), c);

    // The checksum covers every byte, so a "printed 256 bytes" gate can still
    // prove a multi-cluster read.
    const sum = fnv1a32(fnv_offset_basis, &out);
    var accum = Fnv{};
    var at: usize = 0;
    while (at < out.len) : (at += 333) {
        accum.update(out[at..@min(at + 333, out.len)]);
    }
    try std.testing.expectEqual(sum, accum.digest());

    // EOF is sticky: further reads return 0 without touching the chain.
    var tail: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), readFile(src, &reader, &tail, &scratch));
}

test "fat32_ro: broken chains stop honestly instead of inventing bytes" {
    var img = try TestImage.build(std.testing.allocator);
    defer std.testing.allocator.free(img.bytes);
    const src = img.source();
    const vol = try mount(src, 8, TestImage.vol_sectors);

    var e: Entry = undefined;
    try lookup(src, vol, "DOCS/NOTE.TXT", &e);
    var out: [2500]u8 = undefined;
    var scratch: [sector_len]u8 = undefined;

    // (a) A chain that ends early (EOC after cluster 5) yields a short read
    // with `broken` latched — 1024 of 2500 bytes, never filler.
    img.setFat(5, 0x0fffffff);
    var r = FileReader.init(vol, e);
    const n = readFile(src, &r, out[0..], &scratch);
    try std.testing.expectEqual(@as(usize, 1024), n);
    try std.testing.expect(r.broken);
    try std.testing.expectEqual(@as(u32, 2500 - 1024), r.remaining);

    // (b) An out-of-range cluster (a "cluster" past the volume) is a bad chain.
    img.setFat(5, vol.maxCluster() + 5);
    r = FileReader.init(vol, e);
    try std.testing.expectEqual(@as(usize, 1024), readFile(src, &r, out[0..], &scratch));
    try std.testing.expect(r.broken);

    // (c) The reserved bad marker (0x0FFFFFF7) is a bad chain too.
    img.setFat(5, 0x0ffffff7);
    r = FileReader.init(vol, e);
    try std.testing.expectEqual(@as(usize, 1024), readFile(src, &r, out[0..], &scratch));
    try std.testing.expect(r.broken);

    // (d) A chain that points at itself stops immediately with `broken`: the
    // bytes past the first cluster were never this file's content, and
    // reporting them as a clean 2500-byte read would be inventing content.
    img.setFat(5, 5);
    r = FileReader.init(vol, e);
    try std.testing.expectEqual(@as(usize, 1024), readFile(src, &r, out[0..], &scratch));
    try std.testing.expect(r.broken);
    try std.testing.expectEqual(@as(u32, 2500 - 1024), r.remaining);

    // (d2) A two-cluster cycle (5 -> 6 -> 5) is caught by the end-of-chain
    // check: every byte copied was real, but the chain does not end where the
    // size says it does, so the read is broken rather than silently clean.
    img.setFat(5, 6);
    img.setFat(6, 5);
    r = FileReader.init(vol, e);
    try std.testing.expectEqual(@as(usize, 2500), readFile(src, &r, out[0..], &scratch));
    try std.testing.expect(r.broken);

    // (d3) The control: restoring a well-formed chain reads the same bytes and
    // is NOT broken — the check is not a blanket refusal.
    img.setFat(5, 6);
    img.setFat(6, 7);
    img.setFat(7, 0x0fffffff);
    r = FileReader.init(vol, e);
    try std.testing.expectEqual(@as(usize, 2500), readFile(src, &r, out[0..], &scratch));
    try std.testing.expect(!r.broken);

    // (e) A zero first cluster reads nothing at all.
    var empty = e;
    empty.first_cluster = 0;
    var re = FileReader.init(vol, empty);
    try std.testing.expectEqual(@as(usize, 0), readFile(src, &re, out[0..], &scratch));
    try std.testing.expect(re.broken);
}

test "fat32_ro: a cyclic directory chain ends broken instead of hanging" {
    var img = try TestImage.build(std.testing.allocator);
    defer std.testing.allocator.free(img.bytes);
    const src = img.source();
    const vol = try mount(src, 8, TestImage.vol_sectors);

    // Clusters 4 and 8 hold 32 live entries each (a 1 KiB cluster is two
    // sectors) and carry no 0x00 terminator, so the walk can only end via the
    // FAT — exactly the shape that used to spin forever.
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        const cl: u32 = if (i < 32) 4 else 8;
        const slot: u32 = i % 32;
        const lba = img.clusterSector(cl, slot / @as(u32, entries_per_sector));
        img.dirEntry(lba, slot % entries_per_sector, "LOOP    BIN", attr_archive, 3, 1);
    }

    // (a) A self-loop ends immediately, latched broken.
    img.setFat(4, 4);
    var iter = dirIter(src, vol, 4);
    var n: usize = 0;
    while (iter.next() != null) n += 1;
    try std.testing.expect(iter.broken);
    try std.testing.expectEqual(@as(usize, 32), n);

    // (b) A two-cluster cycle (4 -> 8 -> 4) is bounded by the volume's own
    // cluster count: it terminates, and it is latched broken rather than
    // reported as a very long listing.
    img.setFat(4, 8);
    img.setFat(8, 4);
    iter = dirIter(src, vol, 4);
    n = 0;
    while (iter.next() != null) n += 1;
    try std.testing.expect(iter.broken);
    try std.testing.expect(n <= @as(usize, TestImage.cluster_count + 1) * 32);

    // Both reach `lookup` as a broken chain, not as "not found": the caller
    // must be able to tell a damaged volume from a missing name.
    var e: Entry = undefined;
    try std.testing.expectError(error.BadChain, lookup(src, vol, "DOCS/NOPE.TXT", &e));
    img.setFat(4, 4);
    try std.testing.expectError(error.BadChain, lookup(src, vol, "DOCS/NOPE.TXT", &e));

    // The healthy case still lists and resolves (the guard is not a blanket
    // refusal of multi-cluster directories).
    img.setFat(4, 0x0fffffff);
    try lookup(src, vol, "DOCS", &e);
    try std.testing.expect(e.isDir());
}

test "fat32_ro: long file names are assembled and checksum-gated" {
    const alloc = std.testing.allocator;
    var img = try TestImage.build(alloc);
    defer alloc.free(img.bytes);
    const src = img.source();
    const vol = try mount(src, 8, TestImage.vol_sectors);

    // Add a long-named entry: LFN parts carrying "Long Name Document.TXT" plus
    // the 8.3 fallback LONGNA~1.TXT. The first PHYSICAL part carries the 0x40
    // last flag and the highest sequence number.
    const long = "Long Name Document.TXT";
    const short = [_]u8{ 'L', 'O', 'N', 'G', 'N', 'A', '~', '1', 'T', 'X', 'T' };
    const csum = shortChecksum(&short);
    const root = img.clusterSector(2, 0);
    // NOTE: the root listing must not be terminated (0x00) before these slots,
    // and the reader stopping at a 0x00 entry is itself asserted below.
    img.lfnEntry(root, 3, 2, true, csum, long[13..]);
    img.lfnEntry(root, 4, 1, false, csum, long[0..13]);
    img.dirEntry(root, 5, "LONGNA~1TXT", attr_archive, 8, 4);
    img.writeClusters(8, "lfn");

    var e: Entry = undefined;
    try lookup(src, vol, "long name document.txt", &e);
    try std.testing.expect(e.long_name);
    try std.testing.expectEqualStrings(long, e.nameSlice());
    try std.testing.expectEqual(@as(u32, 4), e.size);

    // The 8.3 name still resolves when a caller uses it.
    try lookup(src, vol, "LONGNA~1.TXT", &e);
    try std.testing.expect(e.long_name); // the LFN wins when it checks out

    // A checksum mismatch means the LFN is not trusted: the entry keeps its 8.3
    // identity, so the long name stops resolving and only the alias does.
    img.lfnEntry(root, 3, 2, true, csum +% 1, long[13..]);
    img.lfnEntry(root, 4, 1, false, csum +% 1, long[0..13]);
    try std.testing.expectError(error.NotFound, lookup(src, vol, "long name document.txt", &e));
    try lookup(src, vol, "LONGNA~1.TXT", &e);
    try std.testing.expect(!e.long_name);
    try std.testing.expectEqualStrings("LONGNA~1.TXT", e.nameSlice());

    // An unterminated run (no 0x40 flag) is discarded, never half-assembled.
    img.lfnEntry(root, 3, 2, false, csum, long[13..]);
    img.lfnEntry(root, 4, 1, false, csum, long[0..13]);
    try std.testing.expectError(error.NotFound, lookup(src, vol, "long name document.txt", &e));
    try lookup(src, vol, "LONGNA~1.TXT", &e);
    try std.testing.expect(!e.long_name);
    try std.testing.expectEqualStrings("LONGNA~1.TXT", e.nameSlice());
}

test "fat32_ro: fnv1a32 pins the empty and known vectors" {
    try std.testing.expectEqual(fnv_offset_basis, fnv1a32(fnv_offset_basis, ""));
    // The standard FNV-1a 32 test vector for "a" and a two-byte string.
    try std.testing.expectEqual(@as(u32, 0xe40c292c), fnv1a32(fnv_offset_basis, "a"));
    const hello = fnv1a32(fnv_offset_basis, "hello, fatchain!\n");
    try std.testing.expectEqual(hello, fnv1a32(fnv_offset_basis, "hello, fatchain!\n"));
    // Streaming in pieces is identical to one shot (the property `usb cat` uses).
    var f = Fnv{};
    f.update("hello, ");
    f.update("fatchain!\n");
    try std.testing.expectEqual(hello, f.digest());
}
