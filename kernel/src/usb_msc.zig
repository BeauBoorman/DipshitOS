//! USB Mass Storage — Bulk-Only Transport (BOT) + a minimal SCSI command set
//! (M43 card U2, issue #1033).
//!
//! This is the protocol layer above the U1 bulk engine (`xhci.zig`): the
//! Bulk-Only Transport wraps every SCSI command in a 31-byte Command Block
//! Wrapper (CBW, signature "USBC"), an optional data stage, and a 13-byte
//! Command Status Wrapper (CSW, signature "USBS") that echoes the CBW tag and
//! carries the residual count + command status. The minimal SCSI set is
//! TEST UNIT READY, INQUIRY, READ CAPACITY(10), READ(10), WRITE(10) — enough
//! for sector-accurate I/O against the emulated disk.
//!
//! The card is **probe-and-record**: the wire's honest behavior (INQUIRY
//! strings, capacity geometry, write acceptance) is what lands in
//! `docs/hardware-contract.md` as `[observed]` — never the spec's promise.
//! The CBW/CSW/CDB encode/decode is pure and host-tested; only `transfer`
//! and `probe` touch hardware.

const std = @import("std");
const xhci = @import("xhci.zig");
// M70f F1 (issue #1458): the read-only FAT32 reader lives above this module in
// the storage stack, so the SECTOR SOURCE adapter belongs here — the block seam
// keeps its single owner (this file) and the reader stays hardware-free.
const fat32_ro = @import("fat32_ro.zig");

pub const cbw_len = 31;
pub const csw_len = 13;
/// Wire signatures, read as little-endian u32 ("USBC" / "USBS").
pub const cbw_signature: u32 = 0x43425355;
pub const csw_signature: u32 = 0x53425355;
pub const csw_status_passed: u8 = 0;
/// The only block size this driver speaks (512-byte logical sectors).
pub const block_len: usize = 512;

pub const Csw = struct {
    signature: u32 = 0,
    tag: u32 = 0,
    residue: u32 = 0,
    status: u8 = 0xff,
};

/// Build the 31-byte CBW: signature, tag, data length, direction flag,
/// LUN, CDB length, then the 16-byte CDB area (zero-padded).
pub fn buildCbw(buf: *[cbw_len]u8, tag: u32, data_len: u32, dir_in: bool, lun: u8, cdb: []const u8) void {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], cbw_signature, .little);
    std.mem.writeInt(u32, buf[4..8], tag, .little);
    std.mem.writeInt(u32, buf[8..12], data_len, .little);
    buf[12] = if (dir_in) 0x80 else 0x00;
    buf[13] = lun & 0x0f;
    buf[14] = @intCast(cdb.len & 0x1f);
    const n = @min(cdb.len, 16);
    @memcpy(buf[15 .. 15 + n], cdb[0..n]);
}

pub fn parseCsw(buf: *const [csw_len]u8) Csw {
    return .{
        .signature = std.mem.readInt(u32, buf[0..4], .little),
        .tag = std.mem.readInt(u32, buf[4..8], .little),
        .residue = std.mem.readInt(u32, buf[8..12], .little),
        .status = buf[12],
    };
}

// --- SCSI CDB builders (big-endian multi-byte fields, per SCSI) ------------

pub fn cdbTestUnitReady() [6]u8 {
    return .{ 0x00, 0, 0, 0, 0, 0 };
}

pub fn cdbInquiry(alloc_len: u8) [6]u8 {
    return .{ 0x12, 0, 0, 0, alloc_len, 0 };
}

pub fn cdbReadCapacity10() [10]u8 {
    return .{ 0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
}

pub fn cdbRead10(lba: u32, blocks: u16) [10]u8 {
    return .{
        0x28,                          0,
        @as(u8, @truncate(lba >> 24)), @as(u8, @truncate(lba >> 16)),
        @as(u8, @truncate(lba >> 8)),  @as(u8, @truncate(lba)),
        0,                             @as(u8, @truncate(blocks >> 8)),
        @as(u8, @truncate(blocks)),    0,
    };
}

pub fn cdbWrite10(lba: u32, blocks: u16) [10]u8 {
    var c = cdbRead10(lba, blocks);
    c[0] = 0x2a;
    return c;
}

// --- SCSI response parsers -------------------------------------------------

pub const Inquiry = struct {
    vendor: [8]u8 = @as([8]u8, @splat(@as(u8, ' '))),
    product: [16]u8 = @as([16]u8, @splat(@as(u8, ' '))),
    rev: [4]u8 = @as([4]u8, @splat(@as(u8, ' '))),
};

/// INQUIRY response: vendor at bytes 8..15, product at 16..31, revision at
/// 32..35. A short response leaves the missing fields as spaces.
pub fn parseInquiry(data: []const u8) Inquiry {
    var q = Inquiry{};
    if (data.len >= 16) @memcpy(q.vendor[0..8], data[8..16]);
    if (data.len >= 32) @memcpy(q.product[0..16], data[16..32]);
    if (data.len >= 36) @memcpy(q.rev[0..4], data[32..36]);
    return q;
}

pub const Capacity = struct {
    last_lba: u32 = 0,
    block_len: u32 = 0,
};

/// READ CAPACITY(10) response: last valid LBA then block length, big-endian.
pub fn parseCapacity(data: []const u8) Capacity {
    if (data.len < 8) return .{};
    return .{
        .last_lba = std.mem.readInt(u32, data[0..4], .big),
        .block_len = std.mem.readInt(u32, data[4..8], .big),
    };
}

// --- Bulk-Only Transport over the U1 engine --------------------------------

const cc_success: u32 = 1;

/// Which BOT stage failed (diagnosis; `ok` is the verdict).
pub const Stage = enum { none, cbw, data, csw, csw_signature, csw_tag };

pub const BotResult = struct {
    stage: Stage = .none,
    cc: u32 = 0, // xHCI completion code of the failing stage (0 = none)
    status: u8 = 0xff,
    residue: u32 = 0,
    ok: bool = false,
};

/// Transaction tag, echoed by the CSW. Starts at 0 and wraps; 0 is skipped
/// (the spec calls for a nonzero, changing tag).
var tag_counter: u32 = 0;

/// One BOT transaction: CBW OUT -> optional data stage -> CSW IN. The data
/// buffer must hold `data_len` bytes (OUT: the payload; IN: the response).
/// `data_len` must be <= `xhci.bulk_buf_len` (one U1 transfer).
pub fn transfer(slot: u8, cdb: []const u8, dir_in: bool, data: []u8, data_len: u32) BotResult {
    var res = BotResult{};
    tag_counter +%= 1;
    if (tag_counter == 0) tag_counter = 1;
    const tag = tag_counter;

    var cbw: [cbw_len]u8 = undefined;
    buildCbw(&cbw, tag, data_len, dir_in, 0, cdb);
    const rc = xhci.xhci_bulk_transfer(slot, false, &cbw, cbw_len);
    if (rc.cc != cc_success) {
        res.stage = .cbw;
        res.cc = rc.cc;
        return res;
    }
    if (data_len > 0) {
        const rd = xhci.xhci_bulk_transfer(slot, dir_in, data.ptr, data_len);
        if (rd.cc != cc_success) {
            res.stage = .data;
            res.cc = rd.cc;
            return res;
        }
    }
    var cswbuf: [csw_len]u8 = undefined;
    const rw = xhci.xhci_bulk_transfer(slot, true, &cswbuf, csw_len);
    if (rw.cc != cc_success) {
        res.stage = .csw;
        res.cc = rw.cc;
        return res;
    }
    const csw = parseCsw(&cswbuf);
    res.status = csw.status;
    res.residue = csw.residue;
    if (csw.signature != csw_signature) {
        res.stage = .csw_signature;
        return res;
    }
    if (csw.tag != tag) {
        res.stage = .csw_tag;
        return res;
    }
    res.ok = (csw.status == csw_status_passed);
    return res;
}

/// The `usb msc` probe result (the [observed] contract evidence).
pub const Info = struct {
    slot: u8 = 0,
    present: bool = false,
    tur: BotResult = .{},
    inquiry: Inquiry = .{},
    inquiry_ok: bool = false,
    capacity: Capacity = .{},
    capacity_ok: bool = false,
    /// Write-then-read-back verification at `rw_lba`.
    rw_lba: u32 = 0,
    rw_byte: u8 = 0,
    rw_write: BotResult = .{},
    rw_read: BotResult = .{},
    rw_done: bool = false,
    rw_ok: bool = false,
    /// Bytes read back that mismatched the written pattern (first 0..N).
    rw_diff: u32 = 0,
};

/// Where the write/read-back lands by default — a scratch sector in the
/// partition gap of the gate's staged image (LBA 100), clear of the MBR,
/// the LBA-1 pattern, and the FAT volume at LBA 2048.
pub const probe_default_lba: u32 = 100;

/// Probe the first bulk-capable device: TEST UNIT READY, INQUIRY, READ
/// CAPACITY(10), then write a deterministic 512-byte pattern at `lba` and
/// read it back byte-exact. No result is assumed — every outcome (including
/// a refused write) is recorded.
pub fn probe(lba: u32) Info {
    var info = Info{};
    const slot = xhci.usb_bulk_dev();
    if (slot == 0) return info;
    info.slot = slot;
    info.present = true;

    var no_data: [0]u8 = .{};
    const tur = cdbTestUnitReady();
    info.tur = transfer(slot, &tur, false, &no_data, 0);

    var ibuf: [36]u8 = @as([36]u8, @splat(@as(u8, 0)));
    const inq = cdbInquiry(36);
    const ir = transfer(slot, &inq, true, ibuf[0..36], 36);
    if (ir.ok) {
        const got: usize = 36 - @min(ir.residue, 36);
        info.inquiry = parseInquiry(ibuf[0..got]);
        info.inquiry_ok = got >= 36;
    }

    var cbuf: [8]u8 = @as([8]u8, @splat(@as(u8, 0)));
    const cap = cdbReadCapacity10();
    const cr = transfer(slot, &cap, true, cbuf[0..8], 8);
    if (cr.ok) {
        const got: usize = 8 - @min(cr.residue, 8);
        info.capacity = parseCapacity(cbuf[0..got]);
        info.capacity_ok = got >= 8;
    }

    info.rw_lba = lba;
    var wbuf: [block_len]u8 = undefined;
    var rbuf: [block_len]u8 = undefined;
    for (&wbuf, 0..) |*b, i| b.* = @as(u8, @truncate(i *% 7 +% 3));
    info.rw_byte = wbuf[0];

    const wr = cdbWrite10(lba, 1);
    info.rw_write = transfer(slot, &wr, false, wbuf[0..block_len], @intCast(block_len));
    if (info.rw_write.ok) {
        const rd = cdbRead10(lba, 1);
        info.rw_read = transfer(slot, &rd, true, rbuf[0..block_len], @intCast(block_len));
        if (info.rw_read.ok) {
            info.rw_done = true;
            var diff: u32 = 0;
            for (wbuf, rbuf) |a, b| {
                if (a != b) diff += 1;
            }
            info.rw_diff = diff;
            info.rw_ok = diff == 0;
        }
    }
    return info;
}

// --- The consumer seam: block access used by the file table (U3) -----------

/// True when a bulk-capable device (the emulated MSC) is enumerated.
pub fn present() bool {
    return xhci.usb_bulk_dev() != 0;
}

/// Query READ CAPACITY(10) on the first bulk device. Returns null when no
/// device is present or the command fails. A fresh BOT round trip per call —
/// open is infrequent, and a removable device's geometry is not cached.
pub fn capacity() ?Capacity {
    const slot = xhci.usb_bulk_dev();
    if (slot == 0) return null;
    var cbuf: [8]u8 = @as([8]u8, @splat(@as(u8, 0)));
    const cap = cdbReadCapacity10();
    const cr = transfer(slot, &cap, true, cbuf[0..8], 8);
    if (!cr.ok) return null;
    const got: usize = 8 - @min(cr.residue, 8);
    if (got < 8) return null;
    return parseCapacity(cbuf[0..got]);
}

/// M70f F1 (issue #1458): the `fat32_ro.SectorSource` over the BOT/SCSI pipe —
/// one 512-byte READ(10) per sector, exactly what `.usb` reads already do. A
/// failed transfer is a false return, which the reader turns into `error.Io`
/// (or a latched `broken` mid-file) rather than a fabricated sector.
pub fn source() fat32_ro.SectorSource {
    return .{ .ctx = null, .readFn = sourceRead };
}

fn sourceRead(ctx: ?*anyopaque, lba: u32, out: *[fat32_ro.sector_len]u8) bool {
    _ = ctx;
    if (!present()) return false;
    return read_sector(lba, out[0..]).ok;
}

/// Read one 512-byte logical sector at `lba` into `buf` (must hold
/// `block_len` bytes). The U3 consumer's primitive.
pub fn read_sector(lba: u32, buf: []u8) BotResult {
    if (buf.len < block_len) return .{ .stage = .data, .cc = 0 };
    const slot = xhci.usb_bulk_dev();
    if (slot == 0) return .{ .stage = .cbw, .cc = 0 };
    const cdb = cdbRead10(lba, 1);
    return transfer(slot, &cdb, true, buf[0..block_len], @intCast(block_len));
}

// --- Host tests (pure encode/decode; no hardware) --------------------------

test "usb_msc: CBW encodes signature/tag/len/dir/lun/cdb" {
    var cbw: [cbw_len]u8 = undefined;
    const cdb = cdbRead10(0x00112233, 0x0045);
    buildCbw(&cbw, 0xdeadbeef, 512, true, 0, &cdb);
    try std.testing.expectEqual(@as(u32, cbw_signature), std.mem.readInt(u32, cbw[0..4], .little));
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), std.mem.readInt(u32, cbw[4..8], .little));
    try std.testing.expectEqual(@as(u32, 512), std.mem.readInt(u32, cbw[8..12], .little));
    try std.testing.expectEqual(@as(u8, 0x80), cbw[12]);
    try std.testing.expectEqual(@as(u8, 0), cbw[13]);
    try std.testing.expectEqual(@as(u8, 10), cbw[14]);
    try std.testing.expectEqual(@as(u8, 0x28), cbw[15]);
    // The CDB's big-endian LBA rides verbatim at CBW offset 15+2.
    try std.testing.expectEqual(@as(u8, 0x00), cbw[17]);
    try std.testing.expectEqual(@as(u8, 0x11), cbw[18]);
    try std.testing.expectEqual(@as(u8, 0x22), cbw[19]);
    try std.testing.expectEqual(@as(u8, 0x33), cbw[20]);
    // OUT direction clears the flag byte.
    buildCbw(&cbw, 1, 0, false, 0, &cdb);
    try std.testing.expectEqual(@as(u8, 0x00), cbw[12]);
}

test "usb_msc: CSW parses signature/tag/residue/status" {
    var buf: [csw_len]u8 = @as([csw_len]u8, @splat(@as(u8, 0)));
    std.mem.writeInt(u32, buf[0..4], csw_signature, .little);
    std.mem.writeInt(u32, buf[4..8], 0x0badf00d, .little);
    std.mem.writeInt(u32, buf[8..12], 7, .little);
    buf[12] = 1;
    const csw = parseCsw(&buf);
    try std.testing.expectEqual(@as(u32, csw_signature), csw.signature);
    try std.testing.expectEqual(@as(u32, 0x0badf00d), csw.tag);
    try std.testing.expectEqual(@as(u32, 7), csw.residue);
    try std.testing.expectEqual(@as(u8, 1), csw.status);
}

test "usb_msc: SCSI CDB shapes (opcodes + big-endian LBA/length)" {
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0, 0, 0, 0, 0 }, &cdbTestUnitReady());
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0, 0, 0, 36, 0 }, &cdbInquiry(36));
    try std.testing.expectEqualSlices(u8, &.{ 0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &cdbReadCapacity10());
    // LBA 0x00000002, 1 block.
    try std.testing.expectEqualSlices(u8, &.{ 0x28, 0, 0, 0, 0, 2, 0, 0, 1, 0 }, &cdbRead10(2, 1));
    try std.testing.expectEqualSlices(u8, &.{ 0x2a, 0, 0, 0, 0, 2, 0, 0, 1, 0 }, &cdbWrite10(2, 1));
    // A large LBA/block count is big-endian byte order.
    try std.testing.expectEqualSlices(u8, &.{ 0x28, 0, 0x12, 0x34, 0x56, 0x78, 0, 0x01, 0x00, 0 }, &cdbRead10(0x12345678, 256));
}

test "usb_msc: INQUIRY/CAPACITY parsers" {
    var inq: [36]u8 = @as([36]u8, @splat(@as(u8, 0)));
    @memcpy(inq[8..16], "ACME    ");
    @memcpy(inq[16..32], "USB DISK 2.0    ");
    @memcpy(inq[32..36], "1.00");
    const q = parseInquiry(&inq);
    try std.testing.expectEqualSlices(u8, "ACME    ", &q.vendor);
    try std.testing.expectEqualSlices(u8, "USB DISK 2.0    ", &q.product);
    try std.testing.expectEqualSlices(u8, "1.00", &q.rev);
    // A short response leaves the tail as spaces, never garbage: 16 bytes
    // carries the vendor but not the product/rev.
    const short = parseInquiry(inq[0..16]);
    try std.testing.expectEqualSlices(u8, "ACME    ", &short.vendor);
    try std.testing.expectEqualSlices(u8, "                ", &short.product);

    var cap: [8]u8 = undefined;
    std.mem.writeInt(u32, cap[0..4], 0x00004000, .big);
    std.mem.writeInt(u32, cap[4..8], 512, .big);
    const c = parseCapacity(&cap);
    try std.testing.expectEqual(@as(u32, 0x00004000), c.last_lba);
    try std.testing.expectEqual(@as(u32, 512), c.block_len);
    try std.testing.expectEqual(@as(u32, 0), parseCapacity(cap[0..4]).block_len);
}
