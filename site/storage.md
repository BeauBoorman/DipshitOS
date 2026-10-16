---
title: Storage & filesystem
parent: capabilities
status: published
tags: [capabilities, storage, fat]
---

# Storage & filesystem

Files live on the macOS **host share**, exposed to the guest through the
existing `/host` API. The runner can use the retained custom-virtio channel or
the explicitly selected standard VirtioFS/FUSE backend (`--virtio-fs`); the
guest-facing API is the same. Files are not stored in a guest FAT volume.
Since M34 HF6 (issue #740) the boot image is a boot volume only: it embeds
`EFI/BOOT/BOOTAA64.EFI` + `KERNEL.BIN` and nothing else; applications, data,
and evidence all ride the share.

Since M100b/c the guest can also own a disk: the runner's `--data-disk <img>`
attaches a second virtio-blk function, and a `mkfs.vlfs`-formatted image
mounts read-only at `/disk` — VLFS, the ADR 0050 journaled guest filesystem.
The journaled write path and fsck are still open cards (M100d/M100e), so the
share remains the only writable store today.

## The stack

- **`virtio_file.zig`** — the guest-facing host-file API and backend
  selection. The legacy custom-virtio channel uses queue 5
  (`--cvc-file <host-dir>`); standard VirtioFS/FUSE is an explicit
  alternative for VZ save/restore (`--virtio-fs <host-dir>`). Both feed the
  same `/host` file API.
  The custom-virtio request/reply wire includes
  (`PROBE`/`LIST`/`READ`/`STAT` plus the HF3 mutation set — OPEN/CLOSE/
  WRITE/TRUNCATE/FSYNC/RENAME/MKDIR/DELETE — and `CLONE` dedup) pinned
  byte-for-byte by the class-A channel fixtures.
- **`file_table.zig`** — the per-process 8-handle file table behind the file
  syscalls (open/read/write/close/dir at slots 23–27, the mutating slots
  34–37, `file_sync` at 77, and `fs_metadata` at 79), with paths
  canonicalized onto `/host/...` (or `/disk/...` when a VLFS data disk is
  attached).
- **`virtio_blk.zig`** — the M100b read/write virtio-blk driver. The kernel
  collects every DID-0x1042 function pre-exit, re-arms post-MMU, names each
  by `VIRTIO_BLK_T_GET_ID`, and negotiates the FLUSH barrier the journal's
  ordering contract needs (`live-vlfs-blk` writes a sector, flushes, reads
  it back, and restores it — a device that cannot flush fails honestly).
- **`vlfs/vlfs.zig` + `vlfs/disk.zig`** — the M100c read half of VLFS: a pure
  reader over a sector source (ADR 0050's format — ping-pong superblocks,
  journal region, bitmaps, checksummed everything), mounted at `/disk` and
  reached through the slot-79 metadata surface. Mount replays committed
  journal transactions when the source can write; a read-only source with an
  unreplayed journal is refused `journal_unreplayed`, and any checksum or
  bounds failure is a named refusal, never a hang. `mkfs.vlfs` (host-side,
  `tools/go/vlfs`) formats and structurally checks images.
- **`fat32_ro.zig`** — read-only FAT32 parsing for images attached through
  the USB mass-storage seam (`--usb-msd <image>`): the guest can read files
  off a USB disk image. The MSC block layer itself can write raw sectors
  (the `usb msc probe` writes a gap sector — `live-usb-msc`), but there is
  no writeable FAT filesystem; the guest's own writeable FAT driver went
  with M34 HF6.
- **Commands** — `ls [<dir>]`, `cat <file|path>`, `write <file> <text...>`,
  `mount` (reports the armed host-share store).

## Two stores: the share and the data disk

The share is the writable store — the host folder the runner was pointed at.
`mount` reports it, `write` appends to it, and the host disk is the ground
truth: a file written in-guest is a file on the Mac, byte for byte, across a
reboot.

The second store is the optional VLFS data disk (`--data-disk`): in v1 it is
read-only — `/disk` directory listings and file reads route to the VLFS
reader, while write-shaped calls are refused by name rather than risking the
format. Writing into the journal (M100d), crash-recovery gating (M100e), and
adoption as a data root (M100f) are the cards that turn it into a writable
guest-owned volume.

## The userland file ABI

Milestone ten opened storage to EL0: a per-process file-handle table
(8 static handles, reset at process lifecycle) behind
`sys_file_open`/`read`/`write`/`close` and `sys_dir_list` (slots 23–27).
The original `SAVETEXT.BIN`, `TYPE.BIN`, and `DIR.BIN` demos (retired M78c)
proved the seam; current `GOSH.ELF` redirection/`cat` and `GOFILES.ELF`
listing exercise it, while `NOTE.ELF` (the editor since M66c) uses it for
real work. Milestone
thirteen's B1 card extended it with `sys_file_delete`/`rename`/`truncate`/
`free` (slots 34–37); the original `FSTEST.BIN` proof was deleted with the
second volume (M34 HF6 #740), and the wire it exercised is now pinned
byte-for-byte by the channel fixtures. The current file manager is
`GOFILES.ELF` (gate `go-fileman`: list/open).

## Loading programs

`exec <file> [args...]` streams the flat image out of the share — the
stateless `READ` op, at the honest 2 KiB EL0 read cap — strips its header,
rebuilds the user root around its pages, and spawns it at EL0. Program
images seed the share at build and gate time; they are not embedded in the
boot image.

<Aside kind="info">

**VERIFIED.** `live-fs` (write/ls/cat persisting across a reboot onto the
host disk) and `live-gfs` (the general store *is* the share) gate the
storage path; `live-exec` gates program loading, and `live-user-fs` gates
the userland file syscall ABI across two boots.

</Aside>

<Aside kind="warning">

**LIMITATION.** The share remains the only writable store — the VLFS data
disk is read-only until M100d lands, so there is still no guest-side
journaling or block cache in service, and a bounded direct-read cap (2 KiB
per EL0 call — larger reads loop) applies to the share API. The ABI covers
delete, rename, truncate, free, fsync, and metadata operations (slots 34–37,
77, and 79), but it is a bounded file API, not a POSIX filesystem. VirtioFS
remains opt-in and its save/restore observation is limited to the documented
macOS 27.2 host.

</Aside>
