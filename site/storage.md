---
title: Storage & filesystem
parent: capabilities
status: published
tags: [capabilities, storage]
---

# Storage & filesystem

VirelaiOS keeps three kinds of storage, each with a different trust
relationship to the host. The **host share** (`/host`) is the writable
store and the app-delivery path — a macOS folder served to the guest.
The **data disk** (`/disk`) is an opt-in, guest-owned journaled
filesystem on a dedicated virtio-blk image. The **USB mass-storage**
seam (`/usb`, `/usbN`) is a removable read-only block view. Everything
else about storage — the boot ESP, the deleted FAT era, ASIF overlays —
is scaffolding the guest deliberately never touches after boot.

## The /host file channel

`/host` is served by the runner over **queue 5 of the custom-virtio
device** (`--cvc-file <host-dir>`). The kernel side,
`kernel/src/virtio_file.zig`, is a polled request/reply wire with zero
host state between calls — the guest can never leak a host fd because
the wire doesn't hold any.

The wire is a small envelope: request `[op][flags][len][payload]`,
reply `[status][dlen][data]`. Every byte of it is pinned by checked-in
fixtures (`tests/vf-*.bin`) that a host-side pure-Swift twin (`VFWire`)
also decodes, so the guest and host serializers cannot drift.

| Op | Name | Shape |
|----|------|-------|
| `0x00` | VF_PROBE | transport-only 32,768-byte pattern; no frame |
| `0x01` | LIST | ≤128 sorted 40-byte rows `[name 31][type][size u64]` |
| `0x02` | READ | `[path][offset u64]` → ≤32,765 bytes, stateless |
| `0x03` | STAT | size/type, then mtime, then ctime/btime/alloc as versioned tail |
| `0x04..0x05` | OPEN / CLOSE | mint/free a slot on the host's 8-handle table |
| `0x06` | WRITE | ≤32,763 B per round trip, confirmed-count advance |
| `0x07` | TRUNCATE | cursor clamped below the new size |
| `0x08` | FSYNC | `synchronize()` on the live fd — real durability |
| `0x09..0x0b` | RENAME / MKDIR / DELETE | path ops; DELETE is never recursive |
| `0x0c` | CLONE | APFS copy-on-write dedup — `clonefile(2)`/`copyfile(3)` |
| `0x11` | STATFS | share-root total/free/avail/block-size |

Status codes: `0` ok, `1` not found, `2` is a directory, `3` truncated,
`4` host error, `5` exists (rename/clone/mkdir target collision),
`6` handle error. The guest translates these into honest errno rows —
`hf_open_errno` keeps not-found/is-dir/exists/handle-full distinct
(`ENOENT`/`EINVAL`/`EEXIST`/`ENOSPC`), and `hf_handle_errno` answers
`EBADF` for a handle the host no longer knows. A mutation's wire
cap is symmetric (≈32 KiB per round trip); `vi.FileWriteAll` chunks by
the *host-confirmed* count so a short write can never silently tear a
file. `FSYNC` maps to syscall slot 77, so `sys_file_sync` on a `/host`
handle is a real `fsync` on the Mac's fd, not a courtesy flag.

Paths are share-root-relative, `/`-separated, ≤255 bytes; the host
refuses absolute paths, `..`, and symlink escapes before any syscall.
Measured: a guest read costs one wire round trip per ≤32 KiB call and
sustains roughly 36–68 MiB/s from EL0.

### The second transport: standard VirtioFS

`--virtio-fs <host-dir>` serves the same `/host` API through the
**standard** virtio-fs/FUSE device (`0x1af4:0x105a`, tag `virelaios`,
FUSE 7.31, one request queue plus the mandatory hiprio queue, 2048-byte
max message). `virtio_fs.zig` implements the bounded op set the file
API needs — nothing more.

The reason to use it is persistence, not speed: custom-virtio is
unsaveable, while VirtioFS passes `validateSaveRestoreSupport`, so a
`/host`-backed machine survives VZ save/restore byte-intact (settings,
session strips, witness files — the `live-vz-restore` fs legs). It
stays opt-in; `--cvc-file` remains the default channel.

<Aside kind="warning">

**LIMITATION.** The two transports are alternatives, not a pair — one
`/host` backend per boot. VirtioFS is restore-safe but younger and its
write ceiling (2048 B per FUSE message) is tighter than the cvc
channel's ≈32 KiB round trips. Neither is a POSIX filesystem: the
8-handle table, the 40-byte dir rows, and the op set above are the
whole contract.
</Aside>

## VLFS: a disk of our own

`--data-disk <img>` attaches a second virtio-blk function (same DID
`0x1042` as the boot disk) with `blockDeviceIdentifier = "virelai-vlfs"`.
The kernel collects every DID-0x1042 function pre-exit, re-arms post-MMU,
and issues `VIRTIO_BLK_T_GET_ID`: the device answering `virelai-vlfs` is
the data disk, and **every other blk function is refused for writes by
name (`not_vlfs_disk`)** — so the firmware-read boot ESP is unwritable by
construction and PCI slot order is never identity. Attachment is
`VZDiskImageStorageDeviceAttachment` with `synchronizationMode: .full`,
which makes a guest `VIRTIO_BLK_T_FLUSH` a host full-sync — the
durability contract the journal is built on.

On top of that sits **VLFS** (ADR 0050), the guest's own journaled
filesystem, in `kernel/src/vlfs/`:

- **Format.** 4 KiB blocks over 512 B sectors; ping-pong superblocks in
  blocks 0/1 (the higher `sb_seq` valid copy wins); a journal region,
  inode bitmap, block bitmap, inode table (128 B inodes, ≤8 inline
  extents plus ≤4 chained extent blocks), and data region. Every
  structure ends in an FNV-1a-32 checksum; every name, bound, and
  refusal is part of the format.
- **Journaled commits.** One mutating op = one transaction. Payload
  blocks stage into the journal, then `DESC` + `COMMIT` + `FLUSH` —
  the transaction is durable exactly when that flush returns — then
  the checkpoint writes home blocks, flushes, ping-pongs the
  superblock, flushes, and resets the cursor. The journal is empty at
  every operation boundary, so reads never consult it and "journal
  outstanding" is exactly one transaction.
- **Real fsync.** `FileSync` on a `/disk` handle issues one device
  FLUSH and waits — the same barrier `WriteFileSafe`'s
  temp+fsync+rename publish relies on, now on guest-owned blocks.
  `rename` still refuses a live target, so the publish is
  delete-then-rename and the crash state is old-file-or-absent.
- **Mount-time check.** `mountChecked` runs a bounded fsck — inode
  checksums and kinds vs the ibitmap, extent bounds/overlap, bbitmap
  consistency — against the journal's as-replayed overlay *before* any
  write. A corrupt volume is refused by name having received no byte.
  `mkfs.vlfs` (host-side, `tools/go/vlfs`) formats images and its
  `--check` is the offline deep fsck.
- **Named refusals, never invention.** `no_disk`, `not_vlfs_disk`,
  `journal_unreplayed`, `no_space`, `no_inodes`, `dir_full`,
  `txn_too_large`, `extent_overflow`, `bad_inode`, `bad_dirent`,
  `bad_extent`, `extent_chain_corrupt` — a failed checksum or bounds
  check fails the operation outright, the same `broken`-latching
  posture `fat32_ro` uses.

<Aside kind="info">

**LIVE-GATED.** `live-vlfs-blk` proves the transport and the FLUSH
barrier (a sector write → flush → byte-exact read-back → restore).
`live-vlfs-write` gates the journaled commit path. The standing crash
gate `live-vlfs-crash` hard-kills the VM **mid-write and mid-metadata
storm**, then proves on remount that the volume is either at the last
committed anchor or a committed-prefix state — the
absent-or-committed-prefix guarantee run K=5. `live-vlfs-dataroot`
pins the opt-in `/disk` data root below.

</Aside>

### The opt-in data root

`/disk` is per-boot opt-in: the kernel mounts it only when a
GET_ID-matching disk is present *and* its superblock validates; a
missing or unformatted disk leaves the boot share-only, never wedged.
A `data_root=disk` settings row then moves the *movable* set — shell
history, notify history, the assist store — onto `/disk` when the
volume mounted, with a named fallback (`data_root=disk but /disk
not_mounted; using /host`) when it did not. Apps never have to guess
which volume is writable today.

## The mount table

`kernel/src/mount_table.zig` is the enumerable volume namespace behind
`/` — one boot-fixed row per store: `host` (share), `disk` (VLFS),
`usb` (the raw block stream), `usb1..usb4` (the four MBR FAT32 slots).
Each row carries a name, a kind, a read-only flag, and live mount
state probed at call time — a removable device's answer is never
cached. `dir_list("/")` returns the rows; resolving a path onto a
`not_mounted` row refuses ENXIO by name, and `vi/mounts.go` surfaces
the same vocabulary to Go apps.

## USB mass storage: raw sectors, read-only FAT

`--usb-msd <img>` attaches a USB mass-storage device on its own XHCI
controller. `usb_msc.zig` speaks Bulk-Only Transport + a minimal SCSI
set over the bulk engine — a real sector path: the `live-usb-msc` gate
writes a 512-byte sector at LBA 100 and reads it back byte-exact, and
`live-usb-block` reads a host-staged marker from EL0. The guest-side
block seam is deliberately read-only: `fat32_ro.zig` parses MBR
partition slots 1–4 into the `/usbN` rows (8.3 names plus low-byte LFN,
`broken`-latched corrupt chains), while `/usb` itself is the raw
stream. There is no guest-side writable FAT filesystem.

## State that survives a reboot

Three mechanisms carry state across the machine boundary:

- **`virelai/snapshot` bundles** — a length-framed container
  (`#vb1` header + counted entries) the seat writes on `Ctrl+Shift+S`
  and restores only through a one-shot `/host/SNAPSHOT.RESTORE`: the
  whole bundle parses or nothing is written, and the header's entry
  count makes any truncation point a refusal.
- **`.virelaivm` profiles + `GOSNAP.ELF`** — the profile bundle holds
  vars/overlay/data-disk/share in one place; `live-persistence` runs
  snapshot → suspend → resume → stage → apply → rollback on one
  profile.
- **`vi.WriteFileSafe`** — the temp+fsync+delete-then-rename publish
  every app uses for crash-safe saves on `/host` *and* `/disk`.

<Aside kind="info">

**VERIFIED.** `live-fs` and `live-gfs` gate the share end to end
(write → reboot → read back off the Mac's disk); `live-user-fs` pins
the EL0 file ABI across two boots; `live-vlfs-*` covers the disk. The
class-A `tests/vf-*.bin` fixtures pin the channel byte-for-byte.
</Aside>
