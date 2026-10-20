//! M134b (issue #2760): the one mount table — the enumerable volume
//! namespace behind `/`. `/host`, `/disk` and `/usbN` are no longer ad-hoc
//! prefixes owned by `file_table.parse_path`; each is a row here carrying a
//! name, a kind, a read-only flag, and the LIVE mount state probed at call
//! time (a removable device's answer is never cached, and there is no
//! runtime mount op in v1 — the table is boot-fixed, opt-in stays opt-in).
//!
//! `file_table.dir_list("/")` enumerates one 40-byte `DirEntry` row per
//! mount: `name` is the volume name, `is_dir` marks the browsable
//! (directory-rooted) kinds, and the `reserved` triple carries
//! `{state, kind, flags}` so userland can name `not_mounted` and `ro`
//! without a second call. Resolving a path onto a row whose state is
//! `not_mounted` refuses ENXIO — `user/go/vi/mounts.go` names it
//! `not_mounted`.

const std = @import("std");
const virtio_file = @import("virtio_file.zig");
const usb_msc = @import("usb_msc.zig");
const fat32_ro = @import("fat32_ro.zig");
const vlfs_disk = @import("vlfs/disk.zig");

/// The volume kind, as it rides `DirEntry.reserved[1]` on the wire.
pub const Kind = enum(u8) {
    /// The host share (`/host`) — the `--cvc-file` file channel.
    share = 1,
    /// The VLFS data volume (`/disk`) — the opt-in `--data-disk`.
    vlfs = 2,
    /// The raw USB mass-storage device (`/usb`) — a byte stream, never a
    /// directory.
    block = 3,
    /// A FAT32 volume on MBR partition N (`/usbN`, N = 1..4).
    fat32 = 4,
};

/// The mount state, as it rides `DirEntry.reserved[0]` on the wire.
/// `not_mounted` is a boot-fixed answer for v1: the row exists so the
/// namespace is enumerable, not because the slot may come alive.
pub const State = enum(u8) { not_mounted = 0, mounted = 1 };

/// `DirEntry.reserved[2]` bits: the mounted volume refuses writes.
pub const flag_read_only: u8 = 1;

/// One mount-table row. `usb_index` is the 1-based MBR partition index for
/// `.fat32` rows and 0 elsewhere.
pub const Row = struct {
    name: []const u8,
    kind: Kind,
    read_only: bool = false,
    usb_index: u8 = 0,
};

/// The boot-fixed table. `usb1`..`usb4` are the MBR's four slots — a slot
/// with no FAT32 behind it reports `not_mounted`, never disappears.
pub const rows = [_]Row{
    .{ .name = "host", .kind = .share },
    .{ .name = "disk", .kind = .vlfs },
    .{ .name = "usb", .kind = .block, .read_only = true },
    .{ .name = "usb1", .kind = .fat32, .read_only = true, .usb_index = 1 },
    .{ .name = "usb2", .kind = .fat32, .read_only = true, .usb_index = 2 },
    .{ .name = "usb3", .kind = .fat32, .read_only = true, .usb_index = 3 },
    .{ .name = "usb4", .kind = .fat32, .read_only = true, .usb_index = 4 },
};

/// Row indexes `file_table` maps its `Partition` onto.
pub const row_host: usize = 0;
pub const row_disk: usize = 1;
pub const row_usb: usize = 2;

/// The `.usb_fat` row for MBR index 1..4 (the caller's parse has already
/// refused 0 and >4 — `parse_path` never reaches this table with them).
pub fn usbRow(index: u8) Row {
    std.debug.assert(index >= 1 and index <= fat32_ro.max_partitions);
    return rows[row_usb + index];
}

/// The row's live state — probed fresh every call.
pub fn state(row: Row) State {
    return if (mounted(row)) .mounted else .not_mounted;
}

/// True when the volume behind the row is present and servable right now.
pub fn mounted(row: Row) bool {
    return switch (row.kind) {
        .share => virtio_file.available(),
        .vlfs => vlfs_disk.mounted(),
        .block => usbMounted(),
        .fat32 => usbFatMounted(row.usb_index),
    };
}

/// The raw MSC device: enumerated and answering READ CAPACITY(10) with the
/// 512-byte sector shape this driver speaks.
fn usbMounted() bool {
    const cap = usb_msc.capacity() orelse return false;
    return cap.block_len == usb_msc.block_len;
}

/// A FAT32 slot mounts only when the device is there, its geometry is the
/// driver's, the MBR slot is populated inside the device's own bounds, and
/// the boot sector validates as a volume this reader can serve.
fn usbFatMounted(index: u8) bool {
    const cap = usb_msc.capacity() orelse return false;
    if (cap.block_len != usb_msc.block_len) return false;
    const src = usb_msc.source();
    const prow = fat32_ro.partitionAt(src, index) catch return false;
    if (@as(u64, prow.start_lba) + prow.sectors > @as(u64, cap.last_lba) + 1) return false;
    _ = fat32_ro.mount(src, prow.start_lba, prow.sectors) catch return false;
    return true;
}

/// `DirEntry.reserved[2]` flags for the row.
pub fn flags(row: Row) u8 {
    return if (row.read_only) flag_read_only else 0;
}

/// A directory-rooted row can be descended into when mounted; the `.block`
/// row is a byte stream and lists nothing.
pub fn browsable(row: Row) bool {
    return row.kind != .block;
}
