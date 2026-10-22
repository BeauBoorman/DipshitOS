---
title: Drivers
parent: architecture
status: published
tags: [architecture, drivers]
---

# Drivers

VirelaiOS has no driver framework. Each device the kernel needs has one
dedicated module — `kernel/src/virtio_net.zig`, `kernel/src/xhci.zig`, and
their siblings — that owns discovery, feature negotiation, a bounded set of
split virtqueues or DMA rings, and an honest accounting of everything the
device did or refused to do. There is no generic `DriverCfg` registration
interface, no dynamic probing beyond the fixed PCI scan, and no loadable
drivers: the roster is compiled in, and a device that is absent is a named
negative, never a probe hang.

## The discovery discipline

Every driver obeys the same two-phase contract, which the platform itself
enforces. PCI config-space reads and capability walks run **before**
`ExitBootServices`, because post-exit ECAM reads hang on VZ. Then, after
the kernel installs its own page tables, the transport is **re-armed**:
Virtualization.framework resets most virtio devices at the boot-services
boundary, so the whole status/feature/queue sequence re-runs on the
pre-exit-resolved BAR addresses. Whether a given device comes back reset
(`st=00`, like GPU/block/entropy) or still live (`st=0f`, like net and
sound) was measured per device and recorded in
[`docs/hardware-contract.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/hardware-contract.md) —
each row there is tagged `[observed]` or `[inferred]`.

I/O is polled everywhere. No virtio driver's used-buffer interrupt is in
production on this platform; completions are read off the used ring inside
bounded spin budgets, and a device that never answers is refused by name
(`io_timeout`), never hung on. DMA cache discipline is uniform: clean the
driver-written rings and buffers before the doorbell or notify write,
invalidate device-written rings and buffers before reading them.

## The virtio-mmio and virtio-pci roster

The guest finds devices by walking the bus-0 ECAM window and matching PCI
vendor `0x1af4` device IDs — the modern `0x1040 + type` scheme plus the
transitional forms VZ still presents.

| Device | PCI ID | Runner flag | Kernel module | What it does |
|--------|--------|-------------|---------------|--------------|
| Console | `0x1af4:0x1043` | always attached (`--serial`, `--console`) | `virtio_console.zig` | The serial pipe and the byte-everywhere evidence seam; TX and RX queues both driven. `--console-tcp <port>` upgrades it to a real TCP listener served at EL0 (gate `live-console-tcp`). |
| Entropy | `0x1af4:0x1044` | always attached (`--no-entropy` removes it) | `virtio_entropy.zig` | The stack's only entropy source — one device-write descriptor the device fills, ≤256 B per request, feeding the ChaCha20 CSPRNG. `live-entropy-refusal` proves the guest fails closed unseeded. |
| GPU | `0x1af4:0x1050` | `--display` | `virtio_gpu.zig` | The spec 2D scanout — see [[graphics]]. |
| Network | `0x1af4:0x1041` | `--net`, `--net-nat`, `--net-bridged`, `--net-vmnet` | `virtio_net.zig` | Bounded Ethernet RX/TX on queues 0/1 — see [[networking]]. |
| Sound | `0x1af4:0x1059` | `--sound` | `virtio_snd.zig` | PCM playback on stream queue 2 plus a bounded input-capture path; the `live-sound-*` family gates both directions. |
| Boot block | `0x1af4:0x1042` | the boot image itself | (none) | The ESP is parsed by firmware only. No guest code touches the boot disk post-exit — the guest side of this device was deliberately deleted when storage moved to the host channel. |
| Data block | `0x1af4:0x1042` (second function) | `--data-disk <img>` | `virtio_blk.zig` | The VLFS backing device — see [[storage]]. |
| Filesystem | `0x1af4:0x105a` | `--virtio-fs <dir>` | `virtio_fs.zig` | Standard VirtioFS/FUSE, opt-in — see [[storage]]. |
| vsock | `0x1af4:0x1053` | `--vsock`, `--vsock-ctl` | `virtio_vsock.zig`, `vsock_ctl.zig` | The restore-safe guest↔host stream channel. |
| Custom virtio | `0x1af4:0x1082` | `--custom-virtio`/`--cvc-*`/`--via-virtio`/`--cvc-file` | `virtio_custom.zig` | The private multi-queue channel — below. |
| GPU 3D | `0x1af4:0x1083` | `--gpu3d-metal` | `gpu3d_*.zig` | The private VIR1/VIC1 Metal render+compute device — see [[graphics]]. |
| USB XHCI | `0x106b:0x1a06` | `--input`, `--usb-msd` | `xhci.zig` | Apple USB host controller — below. |

Feature negotiation is per-device and minimal on purpose. The net device's
mask is `VERSION_1 | MTU | MAC` (a VER1-only offer is rejected by VZ); the
GPU takes `VIRTIO_F_VERSION_1` alone on split rings; the block driver asks
for the FLUSH bit because the journal's ordering contract depends on it.

## The custom-virtio channel

`0x1af4:0x1082` is the project's private device — deviceID `0x42`, a type
no real VZ device can collide with, attached as
`VZCustomVirtioDeviceConfiguration`. Its defining quirk: **queue count is
the capability signal.** The guest probes each optional queue's size
through the common config; a non-zero read arms it, zero means absent, and
every deeper flag implies the whole shape below it.

| Runner flag | Queues | Queue plan |
|-------------|--------|------------|
| `--custom-virtio` | 2 | 0 exchange · 1 guest log |
| `--cvc-echo` | 3 | + 2 host-push echo |
| `--via-virtio` | 4 | + 3 input injection |
| `--cvc-snap` | 5 | + 4 framebuffer snapshots |
| `--cvc-file <dir>` | 6 | + 5 host file channel |

Queue 0 is a request/reply exchange with a real descriptor allocator —
multiple chains in flight, freed chains recycled. Queue 1 carries the
guest log and the structured-console tee (`--cvc-console-file`): every
kernel console byte can be duplicated to the host byte-faithfully, with a
drop counter instead of a stall when the host falls behind. Queue 2 is the
SDK's only host→guest data path done at scale: the guest pre-arms an empty
device-write buffer, the host dequeues it, writes, and returns it — the
same virtio-net-RX pattern that drives queue 3's keyboard/pointer
injection pool (see [[input]]) and queue 4's checksummed scanout snapshots.
Queue 5 is the host file channel behind `--cvc-file`, the default backing
of the `/host` filesystem (see [[storage]]).

<Aside kind="warning">

**LIMITATION.** Any configuration carrying a custom-virtio attachment is
unsaveable under VZ machine-state save/restore — the framework refuses it
at `validateSaveRestoreSupport`, and the device is part of the immutable
configuration, so no detach/save/reattach path exists. The runner names
the blocking attachment rather than hiding it. VirtioFS and vsock are the
restore-safe alternatives; this is the whole reason `--virtio-fs` exists.

</Aside>

## The GPU-3D sibling device

`--gpu3d-metal` attaches a second private device, `0x1af4:0x1083`
(deviceID `0x43`), that speaks virtio-gpu CONTROL-queue envelopes carrying
the private `VIR1` capset — render — and, when the host backend supports
it, a second `VIC1` capset for compute. It is not a second virtio-gpu: the
native `1050` 2D device keeps its own BAR, rings, and scanout. The guest
side is `kernel/src/gpu3d_device.zig` (transport, a shared pool of two
contexts, fence-matched completion), `gpu3d_submit.zig`/`gpu3d_stream.zig`
(resource and transfer encoders), `gpu3d_broker.zig` (the seat-routed
render ABI), and `gpu3d_compute.zig` (the slot-90 compute ABI). The host
side is `host/vm-runner/Sources/VMGPU3D/` — a virgl-envelope decoder over
a Metal renderer and a Metal compute backend. Gate `live-gpu3d` pins the
pixel legs, the refusal battery, and the forgery negatives end to end; see
[[graphics]] for the pipeline.

## The vsock probe

`--vsock` attaches Apple's standard `VZVirtioSocketDevice` — virtio device
ID 19, DID `0x1053`. `virtio_vsock.zig` arms rx/tx/event rings and pushes
one stream `OP_REQUEST` to `VMADDR_CID_HOST`; the runner's
`VZVirtioSocketListener` on the port (default 1208) accepts or the device
answers `OP_RST`. The transport bounds are small: 8 descriptors per queue,
an rx pool of 4×2048 B, an event pool of 2×64 B. It exists because it is
the one in-SDK guest↔host channel VZ accepts for save/restore, which is
why `--vsock-ctl` rides it for the signed `virelai-ctl/1` guest→host
control channel (suspend, profile verbs) — gates `live-vsock-restore` and
`live-vsock-ctl`.

## USB XHCI

Screen-side input arrives as USB, because Virtualization.framework exposes
no virtio-input device: `--input` attaches
`VZUSBKeyboardConfiguration` +
`VZUSBScreenCoordinatePointingDeviceConfiguration`, which surface to the
guest as an **Apple XHCI host controller** (`0x106b:0x1a06`, class
`0x0c0330`, two MMIO BARs, 16 slots / 32 interrupters / 16 ports) with the
keyboard and pointer as HID devices behind it. `--usb-msd` attaches a
mass-storage device on its **own** second XHCI controller — the two
controllers never meet, and the driver probes exactly one per boot.

`xhci.zig` (~2,400 lines) implements a bounded slice of the xHCI spec:

- **Register windows:** capability, operational, runtime, and doorbell
  spaces parsed from HCSPARAMS/HCCPARAMS/DBOFF/RTSOFF. The controller
  arrives halted (VZ does not reset it at ExitBootServices — USBCMD=0),
  so the driver issues HCRST itself. Interrupter *i* lives at
  `RTSOFF+0x20+(0x20·i)`; writing ERSTSZ into the MFINDEX region wedges
  the emulation, an observed trap.
- **The context machinery:** a Device Context Base Address Array whose
  entry 0 is the scratchpad pointer (zero — no scratchpad buffers) and
  whose slots 1..N point at per-device Device Contexts (slot context +
  EP0 + EP1/EP2 in/out endpoint contexts). 32 doorbell registers, one per
  slot, each rung with the xHCI DCI rule `2·EP + dir`.
- **Rings:** one command ring, one event ring with a single-segment ERST,
  and per-endpoint transfer rings. Completions are drained **polled** —
  the event IRQ is unproven on this platform — with the producer/consumer
  cycle-bit rule; a NO-OP command to a Command Completion Event was the
  first proof the ring machinery worked.
- **Enumeration:** port reset → Enable Slot → Address Device → device and
  config descriptors over the EP0 control transfer → Set Configuration →
  class dispatch. The class/subclass/protocol facts decide the path:
  `bDeviceClass 0x03` (HID) with `bInterfaceProtocol` 1 or 2 gets
  Set_Protocol(boot) and an armed interrupt-IN endpoint; a non-HID device
  presenting both a bulk OUT and a bulk IN endpoint gets a Configure
  Endpoint command (Context Entries=4) and becomes the mass-storage
  candidate. VZ's MSC presents the surprising pair — EP2 OUT + EP1 IN at
  1024-byte packets, DCI 4 and 3 — which is why the endpoint contexts are
  not optional depth.
- **The pending-report table:** both HID devices share one event ring, so
  completions are stashed in bounded `hid_pending` slots that survive
  command and bulk waits and decode in completion order.

## USB mass storage: BOT + SCSI

`usb_msc.zig` is the protocol layer above the bulk engine: Bulk-Only
Transport wraps every SCSI command in a 31-byte CBW (`"USBC"`), an
optional data stage, and a 13-byte CSW (`"USBS"`) that echoes the command
tag and carries residue + status. The SCSI set is deliberately minimal —
TEST UNIT READY, INQUIRY, READ CAPACITY(10), READ(10), WRITE(10) — enough
for sector-accurate I/O. A failing stage is reported by name
(`cbw`/`data`/`csw`/`csw_signature`/`csw_tag`), and a garbage OUT stream
stalls both directions honestly rather than wedging.

On VZ the emulated disk enumerates SuperSpeed on port 1, INQUIRY reports
vendor `Apple` product `Virtual Disk`, and WRITE(10) is accepted — the
`live-usb-msc` gate writes a 512-byte sector and reads it back byte-exact.
The block seam this feeds is described in [[storage]].

## The read-only FAT view

`fat32_ro.zig` parses FAT32 over an abstract 512-byte `SectorSource` —
the MSC device in production, an in-memory image in host tests. It walks
the MBR's four partition slots, the BPB, directories, LFN entries (low
byte of each UTF-16 unit), and cluster chains. It is new code, not the
deleted FAT driver resurrected: strictly read-only, and a chain that
ends early, loops, or lies about its length latches `broken` — never a
hang, never invented bytes.

## What is deliberately absent

- **virtio-balloon** — not attached; demand paging does not provide memory
  reclaim.
- **virtio-input** — does not exist on this platform; input is USB or the
  custom-virtio channel.
- **USB hubs, a full HID report-descriptor parser, and USB serial/CDC** —
  the two known HID devices only, and VZ exposes no USB-serial class at
  all (a recorded negative probe).
- **AHCI/ATA** — no guest driver exists or is needed.
- **Multi-display** — one scanout, ever.

<Aside kind="info">

**LIVE-GATED.** The device fleet is pinned by the discovered spec set:
`live-virtio-e2e`, `live-xhci`, `live-usb`, `live-usb-bulk`,
`live-usb-msc`, `live-usb-block`, `live-usb-lifecycle`, `live-input`,
`live-entropy`, `live-entropy-refusal`, `live-vlfs-blk`, `live-vf`,
`live-vsock-restore`, `live-vsock-ctl`, `live-gpu3d`, `live-devcons`, and
the `live-sound-*` family. `just gate <id>` runs any of them; see
[[evidence]] for what a gate green actually means.

</Aside>
