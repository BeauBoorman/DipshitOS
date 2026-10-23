> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone forty-three march — device depth: USB beyond HID (living tracker)

> [`docs/status.md`](../status.md) is the canonical milestone-level source. This
> file holds M43's per-card detail, order, and gate notes. A card's row flips
> to ✅ only with real observed evidence.
> Umbrella issue: **#1031** (M43: Device depth — USB beyond HID).
> GitHub milestone: **30 — M43 — Device depth: USB beyond HID**.

## Where we are

M43 was scoped 2026-09-06 (claim #1038) with the tracker at zero open issues —
the first milestone planned from a fully-green board since M40. The theme was
chosen by the user from the post-arc5 roadmap's "distant mountains"
([`docs/archive/roadmap-post-arc5.md`](roadmap-post-arc5.md), "What this roadmap does NOT
cover"): most of that list has since been climbed (SMP → M28, VM depth → M29,
dynamic linking → M30/M31, browser-class HTTP → `HTTPD.BIN`, claim 0750), and
**USB-everything** is the last one that needs no new host capability — the
mass-storage device class is already attachable
(`VZUSBMassStorageDeviceConfiguration`, macOS 13.0+; existence verified at
scoping time against Apple's documentation).

**U1 + U6 landed 2026-09-07** (PR #1041, claim #1040): the runner
`--usb-msd` flag and the XHCI bulk transfer engine (`live-usb-bulk`
PASS 2/2, issues #1032/#1037/#1040 closed). That work exposed a
kernel-wide hazard — an LLVM-emitted base-0 pointer table the flat loader
never relocated — which became issue **#1042**; the **loader-side
absolute-relocation pass landed 2026-09-10** (claim #1042, **ADR 0019**):
the kernel image is now **KRN2**, carrying a 114-entry absolute-relocation
table (`elf2bin --relocs` + `lld --emit-relocs`) that `BOOTAA64.EFI`
applies before the jump. `live-usb-bulk` 2/2 and `live-args` 1/1 green.

**U2 landed 2026-09-10** (claim #1044, issue #1033): BOT + minimal SCSI
(`kernel/src/usb_msc.zig`, `usb msc probe`) — TUR passes, INQUIRY
`Apple`/`Virtual Disk`, capacity last_lba=16383/block_len=512, 512-byte
sector write/read-back byte-exact (`live-usb-msc` 1/1).

**U5 recorded negative 2026-09-10** (claim #1046, issue #1036):
Virtualization.framework exposes no USB serial/CDC-ACM device class, so
the card closed per its own acceptance clause with an `[observed]`
contract row — and the U6 `--usb-serial` flag died with it (the runner
flag surface stays `--usb-msd` only).

**U3 landed 2026-09-10** (claim #1048, issue #1034): the file-table `.usb`
read-only raw-block volume + the EL0 `BLKD.BIN` consumer
(`live-usb-block` 1/1, host-staged LBA-1 marker byte-exact).

**U4 landed 2026-09-10** (claim #1051, issue #1035, PR #1052): polled
`usb rescan` + administrative `usb detach` with the clean error path
(`live-usb-lifecycle` 2/2; zero-regression across the whole USB fleet).

**M43 is done 2026-09-10** (closeout claim #1053): all six cards closed,
the USB fleet re-verified 7/7 at HEAD, umbrella #1031 closed, GH
milestone 30 closed.

What exists today (the honest starting line):

- **`kernel/src/xhci.zig` (1,536 lines)** — the M7 driver: probe, init,
  command/event rings, device enumeration, and **interrupt-IN only**
  (`xhci_poll_intr_nb` + `xhci_report`, consumed by `kernel/src/input.zig`
  for HID keyboard/pointer). No bulk endpoints, no control transfers beyond
  the enumeration minimum, no device lifecycle after boot.
- **The hardware contract** (`docs/hardware-contract.md`) documents the VZ
  XHCI emulation in detail: the controller is `0x106b/0x1a06` (VZ leaves it
  halted; the driver HCRSTs), keyboard = port 9 (`0x05ac/0x8105`), pointer =
  port 10 (`0x05ac/0x8106`), the interrupter-register trap (ERSTSZ must go to
  `RTSOFF+0x20+(0x20×i)`, never the MFINDEX region), the **arm-ONE-transfer-
  TRB** rule (multi-TRB depth wraps the ring and drops reports), and the
  delivery cadence (≈ one report per full-frame present).
- **The runner** attaches exactly two USB device classes
  (`VZUSBKeyboardConfiguration` +
  `VZUSBScreenCoordinatePointingDeviceConfiguration`, `main.swift` ~line
  1117, behind the `--input` flag gate).
- **No FAT stack** — HF6 (M34) deleted `fat.zig`/`esp.zig`/`virtio_blk.zig`;
  the userland filesystem is the host-file channel. A USB disk therefore has
  no ready-made filesystem consumer; U3 scopes that honestly.

M43 makes USB a *device family* instead of an input substrate: bulk
transfers, mass storage end to end with a real consumer, an honest
lifecycle, and — probe permitting — serial. Every card lands with a class-B
spec (the M40 GF rule) and `[observed]` hardware-contract rows.

## The cards, in order

> **U6 rides with the first consumer → U1 bulk engine → U2 MSC probe → U3 seam+consumer → U4 lifecycle → U5 serial (parallel after U1).**

| Card | Issue | Phase | Depends on | Status | Touches | Notes |
|:-----|:------|:------|:-----------|:-------|:--------|:------|
| **U6** | [#1037](https://github.com/drawmeanelephant/DipshitOS/issues/1037) **Runner `--usb-msd` / `--usb-serial` flags** | host | — | 🟢 `--usb-msd` landed (U1's PR); `--usb-serial` will never land — U5 closed negative (no CDC-ACM class exists), so the flag surface stays `--usb-msd` only | `host/vm-runner/Sources/VMRunner/main.swift` | `--usb-msd` landed: `VZUSBMassStorageDeviceConfiguration(attachment:)` inside `VZXHCIControllerConfiguration.usbDevices` on `config.usbControllers` (macOS 15+ API). Flag-gated, OFF by default — the default VM byte-identical (the M9/N7 rule). [observed]: the MSD gets its OWN controller; VZ's sniffer needs parseable disk structure. |
| **U1** | [#1032](https://github.com/drawmeanelephant/DipshitOS/issues/1032) **XHCI bulk transfer engine** | kernel | U6 (evidence) | 🟢 landed (U1+U6 PR) | `kernel/src/xhci.zig`, `kernel/src/input.zig`, one spec | Bulk endpoint capture at enumeration (EP2 OUT + EP1 IN on the VZ MSC, maxpkt 1024), per-slot bulk rings, doorbells by honest DCI (2×EP+dir), Configure Endpoint with Context Entries=max, one-transfer-at-a-time per direction. Proven by `live-usb-bulk` 2/2: raw probe gets real device completions (cc=6 Stall on non-CBW traffic — the wire's honest answer). Zero HID regression: run 02. [observed, debugging]: a 4-case switch over field addresses made LLVM emit an UNRELOCATED base-0 pointer table — computed `@ptrFromInt(base + @offsetOf)` instead; see the code comment in `xhci_configure_endpoint`. The **kernel-wide** hazard this exposed is fixed by **#1042 / ADR 0019** (KRN2 loader relocation table; 114 absolute slots relocated at load). |
| **U2** | [#1033](https://github.com/drawmeanelephant/DipshitOS/issues/1033) **USB MSC probe: BOT + minimal SCSI** | kernel | U1 | 🟢 landed (claim #1044) | `kernel/src/usb_msc.zig`, `kernel/src/xhci.zig`, `kernel/src/monitor.zig`, `tools/gate/specs/live-usb-msc.spec` | Bulk-Only Transport (CBW → data → CSW) + TEST UNIT READY / INQUIRY / READ CAPACITY(10) / READ(10) / WRITE(10), behind `usb msc probe [lba]`. `live-usb-msc` 1/1: TUR passes, INQUIRY `Apple`/`Virtual Disk` rev `1`, capacity **last_lba=16383 / block_len=512** (one LUN), **512-byte sector write/read-back byte-exact (diff=0) — WRITE(10) accepted**. `bulk_buf_len` 128→512 so one sector rides one U1 transfer. Host tests for CBW/CSW/CDB/parsers; `[observed]` contract rows added. `live-usb-bulk` 2/2 zero-regression. |
| **U3** | [#1034](https://github.com/drawmeanelephant/DipshitOS/issues/1034) **Block-device userland seam + a real consumer** | kernel+user | U2 | 🟢 landed (claim #1048) | `kernel/src/file_table.zig`, `kernel/src/usb_msc.zig`, `user/src/blkd.zig`, one spec | Consumer chosen by U2's evidence: **(b) raw-block** — the guest has had no FAT stack since M34, and the bounded first consumer is a read-only seam. `file_table` gains the `.usb` volume (`usb`/`/usb`/`usb:`, READ-ONLY, EINVAL on write, ENOENT without a device); reads are sequential 512-byte SCSI sectors from `usb_msc` at the handle cursor. EL0 consumer `BLKD.BIN` opens `usb`, reads 1024 B (LBA 0+1), and prints the host-staged LBA-1 marker. `live-usb-block` 1/1: `blkd: pattern=M43USBMSDPROBE` byte-exact. Host tests: routing + read-only refusal + ENOENT. |
| **U4** | [#1035](https://github.com/drawmeanelephant/DipshitOS/issues/1035) **Honest device lifecycle** | kernel | U2 | 🟢 landed (claim #1051) | `kernel/src/xhci.zig`, `kernel/src/input.zig`, `kernel/src/monitor.zig`, `kernel/src/shell.zig`, `tools/gate/specs/live-usb-lifecycle.spec` | Polled `usb rescan` (reuses the boot enumerate path for arrivals, quiesces CCS-cleared removals, reattaches quiesced entries whose port still reports connected) + `usb detach [slot]` (administrative quiesce — present=false, live count decremented, HC slot/contexts/rings kept; every consumer fails clean via the pre-existing guards). `live-usb-lifecycle` 2/2: bulk-only boot detaches slot 1, the next probe fails `no bulk-capable device`, rescan reattaches, the next probe is byte-exact (count 2); HID-only boot rescan is a no-op with `input: armed` intact. Zero-regression: `live-usb-bulk` 2/2, `live-usb-msc` 1/1, `live-usb-block` 1/1, `live-usb` 1/1, host tests green. Port-change IRQs declined (recorded); full Disable-Slot teardown + stale-identity-on-swap recorded as limits. |
| **U5** | [#1036](https://github.com/drawmeanelephant/DipshitOS/issues/1036) **USB serial (CDC-ACM), probe-first** | kernel | U1 | ⬛ **closed negative** (claim #1046) | `docs/hardware-contract.md` | **Probed and recorded negative 2026-09-10.** Virtualization.framework exposes **no USB serial/CDC-ACM device configuration** — the attachable USB classes are keyboard, pointing, mass storage, and host-USB passthrough (physical hardware, out of scope). With no emulated serial class there is nothing to attach, so the card closes per its own acceptance clause: the absence is a `[observed]` hardware-contract row, no fake probe. The virtio-console device remains the only serial surface. |

## Scoping-time ground truth (so no card re-derives it)

- `VZUSBMassStorageDeviceConfiguration` — **exists**, macOS 13.0+ (Apple
  documentation, checked 2026-09-06). Not yet attached by any gate; first
  observed facts land in U6/U2.
- VZ CDC-ACM emulation — **unknown**. U5's first deliverable is the probe.
- The Apple XHCI emulation **resets nothing at ExitBootServices for USB**
  (unlike virtio-blk, which resets and needs `blk_rearm`) — the M7 contract
  row records the halted-at-boot state; whether a post-boot device arrival
  behaves like the boot-time devices is exactly what U4 observes.
- The per-gate class-B fleet runs on ONE shared read-only image with
  per-gate private shares (HF6) — the MSD is a **second, additive** disk;
  the share model is untouched.

## Invariants & design principles

1. **Zero-Regression**: the HID keyboard/pointer paths and every class-B
   gate stay green; the default VM stays byte-identical; new devices attach
   behind runner flags that are OFF by default.
2. **Driver-scoped kernel work**: new code lives in `kernel/src/xhci.zig` +
   one device module per class; nothing crosses the block/char-device seam
   without its own card.
3. **Every card ends in an observed gate** — a spec under
   `tools/gate/specs/` (never a one-off `verify-*.sh`), with the M40
   rotation-audit rules applied: no speed-calibrated holds, report rings
   sized for the choreography.
4. **Hardware contract first**: every VZ-observed behavior gets an
   `[observed]` row with claim refs — observed facts, never the spec's
   promise, are what later cards build on.

## Out of scope (recorded at scoping time)

- USB hubs; isochronous devices (USB audio/video); USB3 speeds.
- A second filesystem family (exFAT/NTFS) — if FAT revives at all it is the
  bounded read-only 8.3 reader of U3(a).
- Network-over-USB (CDC-NCM/EEM) — virtio-net is the network story.
- Rewriting the HID paths — U1 generalizes the transport without touching
  the HID consumers' behavior.

## Next actions

1. ~~U6 + U1 together: the flag lands with a raw-bulk probe spec~~ — **done
   2026-09-07** (PR #1041); the kernel-wide pointer-table hazard it exposed
   is fixed by **#1042 / ADR 0019** (2026-09-10).
2. ~~U2 next, on the same device: BOT/SCSI probe-and-record~~ — **done
   2026-09-10** (claim #1044, `live-usb-msc` 1/1; VZ's MSD is a writable
   single-LUN `Apple Virtual Disk`, 16 384 × 512 B sectors).
3. ~~U5's probe can run in parallel with U2 (one boot, one flag, an honest
   contract row either way)~~ — **done 2026-09-10, recorded negative** (claim
   #1046): no USB serial class exists to probe (contract row above).
4. ~~U3's consumer decision (FAT reader vs raw-block)~~ — **done 2026-09-10**
   (claim #1048): **(b) raw-block**, a read-only `.usb` file-table volume +
   the EL0 `BLKD.BIN` consumer; `live-usb-block` 1/1 reads the host-staged
   marker byte-exact. FAT revival stays out until a card needs it.
5. ~~**U4** (device lifecycle): rescan/attach/detach with the honest error
   path~~ — **done 2026-09-10** (claim #1051, PR #1052):
   `live-usb-lifecycle` 2/2; polled rescan + administrative detach, HID
   zero-regression.
6. ~~Closeout~~ — **done 2026-09-10** (claim #1053): USB fleet re-verified
   7/7 at HEAD (`live-usb` 1/1, `live-usb-bulk` 2/2, `live-usb-msc` 1/1,
   `live-usb-block` 1/1, `live-usb-lifecycle` 2/2); umbrella #1031 closed;
   GH milestone 30 closed. M43 is done.
