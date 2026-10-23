# VirelaiOS hardware contract

This file records every hardware and firmware assumption the project makes.
Anything listed here is a commitment: code in later milestones must either
honor it or update this file first. Entries are tagged **[observed]** when we
have log/command evidence on a real machine and **[inferred]** when the
assumption comes from documentation or reasoning only.

> **Trimmed 2026-08-21 (issue #270):** this file keeps the device summary
> table and the actionable facts only. The full per-device discovery
> narratives (the claim-by-claim histories behind each fact) are preserved
> verbatim in [`archive/hardware-contract-detail.md`](archive/hardware-contract-detail.md).

## Device summary (Apple Virtualization.framework, macOS 27+, Apple silicon)

| Device | PCI ID | Reset at ExitBootServices | Actionable quirks |
|--------|--------|---------------------------|-------------------|
| Disk (virtio-blk) | `0x1af4/0x1042` cls `0x018000` | **YES** (`st=00`) | M34 HF6 (issue #740) **deleted the guest side of this device entirely**: the kernel no longer probes, mounts, or re-arms it (the old post-MMU queue re-arm + final `st=00` read apply to the HF1–HF5 era only; claim 6420's FAT driver and the DATA partition are gone). The boot volume is firmware-parsed: a single GPT FAT32 partition (~33.7 MiB floor) carrying exactly `EFI/BOOT/BOOTAA64.EFI` + `KERNEL.BIN`. The guest's only storage surface is the custom-virtio host file channel (queue 5; see the host-file-channel row). **[observed]** claims 6420/3678 → retired 2026-09-01 |
| Data disk (virtio-blk #2, `--data-disk`) | `0x1af4/0x1042` (second function beside the boot disk) | **YES** (`st=00`, same class as the boot blk) | ADR 0050 (M100a) pins the attach: the runner appends a second `VZVirtioBlockDeviceConfiguration` to `config.storageDevices` (coexists with `--overlay-base`, which covers the boot disk only) with `blockDeviceIdentifier` = `virelai-vlfs` — the guest identifies it by `VIRTIO_BLK_T_GET_ID` and **refuses writes to any blk function whose ID does not match** (`not_vlfs_disk`), so the boot ESP is unwritable by construction; PCI slot order is never used as identity. Attachment is `VZDiskImageStorageDeviceAttachment(url:readOnly:false, cachingMode:.automatic, synchronizationMode:.full)` — `.full` makes a guest FLUSH a host full-sync ("no synchronized data is lost on panic or loss of power" per the header); the image is a **raw file, size a multiple of 512 B**, the only format the URL attachment accepts. API facts **[observed]** in the Xcode 27 SDK headers (`VZVirtioBlockDeviceConfiguration.h`: identifier is macOS 12.3+, ≤20 ASCII bytes, read via GET_ID; `VZDiskImageStorageDeviceAttachment.h`: modes init macOS 12.0+). Wire behavior **[inferred]** until M100b's probe records what is observed. |
| Console (virtio-console) | `0x1af4/0x1043` cls `0x078000` | Armed pre-exit; post-switch access needs the T0SZ=16+TLBI fix | UEFI `ConOut` is NOT routed here (firmware log stays empty) — the kernel drives it itself. BAR0 is a 64-bit BAR whose assignment **varies per boot** — map in place, never rebase. TX **and** RX queues driven. **[observed]** claims 1517/6684 |
| GPU (virtio-gpu) | `0x1af4/0x1050` cls `0x038000` | **YES** (`st=00`) | Accepts `VIRTIO_F_VERSION_1` alone (split rings, 16-bit notify). Scanout is **B8G8R8X8_UNORM with OPAQUE alpha** (X/A=0 renders transparent). Device is **virtio-gpu 1.2** (24-byte `display_one`; the 1.0 shape wedges the queue). Tail descriptor's `next` must be 0. Spec 2D command path only. **[observed]** claims 6053/3868 |
| USB XHCI | `0x106b/0x1a06` cls `0x0c0330` | **NO** (VZ leaves it halted: USBCMD=0, USBSTS=0x9 — the driver HCRSTs) | Input devices are USB HID behind XHCI, **not** virtio-input. Interrupter set *i* lives at `RTSOFF+0x20+(0x20×i)` — writing ERSTSZ into the MFINDEX region (`RTSOFF+0x00…`) wedges the emulation. Keyboard = port 9, pointer = port 10. **[observed]** claims 4272/4116 |
| USB HID keyboard (port 9) | `0x05ac/0x8105` | n/a | Full speed, boot protocol ACCEPTED, interrupt-IN EP1 maxpkt=8. The driver arms depth 8; the old depth-1 conclusion predated the report-buffer wrap fix (issue #117). Both HID devices share one event ring: snapshots must survive command/control/bulk waits and decode in completion order. Synthesized keyDowns depend on window activation; historical modifier injection failed (claims 4116/6050/0935/4769/5093), not proof that physical modifiers fail. Unit tests pin modifier/release handling and unchanged-report suppression (no auto-repeat); human acceptance remains required. |
| USB HID pointer (port 10) | `0x05ac/0x8106` | n/a | Full speed, absolute screen-coordinate pointer; interface protocol **0** (non-boot). Native packets start with report ID **1**, then buttons and LE16 X/Y in **0..32767**; ignore the following wheel/pan fields for pointer position. The canonical custom-virtio pointer payload remains 5 bytes without a report ID. **[observed]** #1857: raw 10-byte captures and HID report descriptor on macOS 27.2. M91b does not request boot protocol on this non-boot interface. Programmatic NSEvent pointer delivery is not reliable USB proof; human trackpad/mouse acceptance remains required (claims 4993/4769). |
| USB mass storage (`--usb-msd`) | `0x05ac/0x1503` iface `0x08/0x06/0x50` (BOT) | n/a (M43 U6 flag) | Attached via `VZUSBMassStorageDeviceConfiguration` into a `VZXHCIControllerConfiguration.usbDevices` array (macOS 15+ API, this host's floor is 27). **Each MSD gets its OWN XHCI controller** — the HID controller never sees it (two live controllers in a `--input --usb-msd` boot; the single-controller guest driver probes exactly one, so the devices never meet in one boot). Enumerated on port 1 at **speed=4 (SuperSpeed)**. The bulk pair is **EP2 OUT + EP1 IN** (not the EP1 pair) at **maxpkt=1024**; DCI = 2×EP+dir (OUT 4, IN 3). Configure Endpoint with Context Entries=4 / add-flags bit 4 completes cc=1. Honest wire: arbitrary bulk OUT bytes with no MSC CBW **stall both directions (cc=6 Stall Error)** — real device responses, not timeouts; U2's BOT driver is what talks protocol. VZ's disk-image sniffer **refuses** a fully-zeroed raw image AND a bare 0x55AA MBR — it demands parseable disk structure (a pure-python MBR+minimal-FAT32 volume attaches; this host's `hdiutil`/`newfs_msdos` are sandbox-denied for the gate harness). **[observed]** M43 U1+U6 (claim #1040), live-usb-bulk 2/2. **U2 [observed]** (claim #1044, live-usb-msc 1/1 on macOS 27.0 build 26A428): BOT over the U1 pipe works end to end — TEST UNIT READY passes (CSW status 0), INQUIRY reports vendor `Apple`, product `Virtual Disk`, rev `1` (trailing-space padded), READ CAPACITY(10) reports **last_lba=16383 / block_len=512** for the 8 MiB image (one LUN, LUN 0), and **WRITE(10) is accepted — a 512-byte sector write/read-back at LBA 100 is byte-exact (diff=0)** (the disk is writable, not read-only). VZ echoes the CBW tag and returns residue 0 on success. **U3 [observed]** (claim #1048, live-usb-block 1/1): the same device is reachable READ-ONLY from EL0 through the file-table `.usb` volume (512-byte sequential sectors); BLKD.BIN read the host-staged LBA-1 marker `M43USBMSDPROBE` byte-exact. **U4 [observed]** (claim #1051, live-usb-lifecycle 2/2): lifecycle is a guest-side contract (the runner attaches USB statically — no host hotplug exists in the flag set). `usb detach` quiesces the bulk device (slot 1 port 1) and the next `usb msc probe` fails on the clean path (`usb msc: no bulk-capable device`); `usb rescan` reattaches the same entry (`added=0 removed=0 reattached=1 count=1`) and the following probe is byte-exact again (`write_ok=1 read_ok=1 diff=0 ok=1` twice in one boot). A HID-only boot's rescan is a counted no-op (`reattached=0 count=2`, `input: armed` intact). Polled rescan chosen over port-change-event IRQs (all XHCI event handling is polled; no new IRQ machinery for no observed need). Recorded limits: detach keeps the HC slot/contexts/rings (no Disable-Slot teardown), so a physically swapped device behind the same port would revive the stale identity; **M70f F1 [observed]** (issue #1458, `live-usb-block` 1/1, 195-255 s across three runs on macOS 27.2 build 26B5086k (wall clock moves with host load; the spec's script timeout is 240 s)): the attached disk is now a real volume surface. The MBR walk reports `partitions=2`; the FAT32 volume parses to `label=USBPROBE cluster_bytes=2048 clusters=3562 root_cluster=2` at `start_lba=2048 sectors=14336`; the root lists two entries (a 120-byte `PROBE.TXT` and the `DOCS` directory) and `DOCS` lists exactly one (`. ` and `..` are skipped). Byte-exactness is observed through a whole-file FNV-1a 32 rather than a dump: `PROBE.TXT` `read=120 sum=0x133d22a5`, and the 5000-byte `DOCS/NOTE.TXT`, which spans clusters 5 -> 6 -> 7, `read=5000 sum=0x52e785f5`. The same 120 bytes are read again from EL0 (`BLKD.BIN`) through the file-table `usb1/PROBE.TXT` handle — `blkd: fat=usb-bulk-probe`, then EOF on the second read. Honest refusals, observed live rather than argued: a present `0x83` partition -> `partition 2 is not a readable FAT32 volume (not-fat32)`, an empty MBR slot (`part=3 absent`, `no such MBR partition`), an absent name, a directory read by `usb cat`, and a file listed by `usb ls`. The reader is READ-ONLY (no write, create, rename, delete or chmod path reaches a volume) and speaks 512-byte sectors / FAT32 only. **Stated limit:** VZ's `--usb-msd` is the only attachment path, so "a real stick in a real port" remains unprovable here. |
| Entropy (virtio-rng) | `0x1af4/0x1044` | **YES** (`st=00`) | Re-arm post-MMU before the first read. Delivers genuine non-deterministic entropy (two boots → different sequences). **[observed]** claim 2665 |
| Network (virtio-net) | `0x1af4/0x1041` cls `0x020000` | **NO** (`st=0f`, DRIVER_OK intact) | Feature ladder must include **`VIRTIO_NET_F_MTU`** (landed mask VER1\|MTU\|MAC = `0x28/0x1`; VER1-only is rejected). Host-set MAC comes from device-config offset 0 under `VIRTIO_NET_F_MAC`. A zeroed **12-byte virtio_net_hdr** is consumed on EVERY TX buffer and WRITTEN into every RX buffer (`rx_hdr_len=12`). RX buffers < **1530 B wedge the device** (production buffer 4096). Sub-60-byte frames travel UNPADDED both directions. Used-buffer IRQ unobserved — drain polled. MAC filter accepts own+broadcast+all-nodes mcast (`33:33:00:00:00:01`)+the IID's solicited-node group (`33:33:ff:xx:xx:xx`), drops rest with a counter. **[observed]** claims 1373/6076/7293/0148 |
| NAT attachment | (same net device) | n/a | Serves **no DHCP** (DISCOVER goes unanswered — static fallback still reaches the gateway). Closed TCP port → **RST**, not silent drop. Subnet observed 192.168.64.0/24, gateway .1 (no prefix API). Router MAC **varies per boot** — assert learned-line prefixes, never literal MACs. Sends an IPv6 RA multicast at boot: the M117b MAC filter now admits it to the bounded RA handler (it was filtered out before M117b). Whether the NAT's RA carries an autonomous /64 PIO is **not yet observed** (no NAT capture — M117d surface); if it does, the guest forms a SLAAC global and its DAD/RS train goes out on the link, and the `ndp=`/`v6=` counters will show it. No proxy-ARP off-subnet. Guest default route is next-hop ARP: an off-subnet destination resolves the gateway — the DHCP router option when bound, else the derived `.1` of the (DHCP-or-/24) subnet — and the wire request asks who-has-the-gateway, never the literal peer. The learned gateway entry is the only off-subnet channel; with no derivable gateway the exact-peer behaviour stands unchanged. No capture file — evidence is guest-observed counters. **[observed]** claims 4678/0351/7026 |
| Sound (virtio-snd) | `0x1af4/0x1059` cls `0x040100` | **NO** (`st=0f`) | Device config counts read **0/0/0** (jacks/streams/chmaps) — enumerate topology via CONTROL-queue JACK_INFO/PCM_INFO queries. VZ speaks the **virtio-1.3 control renumbering** (OK=`0x8000`; PCM_INFO `0x0100` … STOP `0x0105`). Control replies are `[status hdr][entries]` (status FIRST — Linux reads the reverse). Playback TX queue = **queue 2**. Formats S16\|S32\|FLOAT, rates 48k\|96k, 1–2 ch, OUTPUT. **[observed]** claims 6140/5877/7636/3206. **M70f2 [observed]** (issue #1476, `go-fart` 2/2 + `live-sound-control` 2/2 + `live-sound-playback` 1/1 + `live-sound-app` 1/1 on macOS 27.2 build 26B5086k, 28–45 s a run): the stream-state rows are reachable from GOOS=virelai with these results. Slot 44's bound is **0..100**; 101 is REFUSED with `EINVAL` (no silent clamping) and an in-range value is accepted and echoed (`vol set=40 echo=40`), with the kernel's stored gain readable through a different path (`sound` then prints `vol=40`). The kernel's own defaults are **volume 100 / mute off**, observed as `sound: vol=100 mute=0` on a boot that sets neither. Slot 45's mute does **not** shorten a drain: one 250 ms / 96000-byte buffer submitted unmuted and then muted confirmed **96000 bytes both times** (the muted-drain identity), and a soundless VM leaves both rows at zero calls. The accounting identity holds on the monitor path too: `beep 440 300` reports `submitted=115200 drained=115200 frames=14400`, i.e. every submitted byte drained (FLOAT/stereo, 8 B a frame at 48 kHz). **Stated limit:** the samples the device actually receives are not observable anywhere in this project — there is no capture path — so muted playback is evidenced as accounting plus kernel state, never as measured silence. **M118a input-stream probe [observed]** (#2479, `live-sound-in-probe`, macOS 27.2 build 26B5112a, `SoundInProbe --sound-in`): `VZVirtioSoundDeviceInputStreamConfiguration` + `VZHostAudioInputStreamSource` is accepted by `config.validate()` and boots — DID `0x1059`, class `0x040100`, features `0x30000000`, queue sizes and the armed control/TX queues identical to the output-only attach. With the input stream at index 0 (the only index the guest's PCM_INFO can reach — `snd_pcm_probe` is hardcoded `start_id=0`), the reply is **dir=1 (INPUT), formats=`0xa0020` (S16\|S32\|FLOAT), rates=`0x480` (48k\|96k), ch=1..2** — the same capability bitmap VZ advertises for output. `beep` then refuses by name: `beep: FAILED (no supported output channel tuple)` (dir≠0). The devcfg counts still read 0/0/0 at the pre-exit capture; the post-exit fresh re-read reports **jacks=1 streams=0 chmaps=0** — jacks=1 also appears with output-only attach on this build, so it is not input-specific (an older macOS observed 0/0/0 there). **Mic/TCC [observed]:** the ad-hoc-signed runner process reports `AVCaptureDevice.authorizationStatus(.audio) = 0 (notDetermined)`, and attach + boot + PCM_INFO enumeration ran with **no consent prompt and no denial** — macOS defers mic TCC to actual capture, so whether PCM_START on the input queue triggers consent or silent failure is M118b's open question, untested on this card. Flag off attaches nothing: `sound` and `beep` refuse `no virtio-snd device (DID 0x1059 not found on bus 0)` — the named refusal the gate pins. The flag lives on `SoundInProbe` (`Sources/SoundInProbe/`, same package + entitlements) because VMRunner's argument loop has no extension point and `main.swift` was held by other claims; the VMRunner `--sound-in` splice is a later change. The "no capture path" limit above stands — this probe enumerated topology only and read zero samples.  |
| Memory balloon (virtio-balloon, `--balloon`) | `0x1af4/0x1045` cls `0x058000` | **NO** (`st=0f`, DRIVER_OK intact) | Attached via `VZVirtioTraditionalMemoryBalloonDeviceConfiguration` (public VZ API since macOS 11; **one device per VM**) — "traditional" names the inflate/deflate model, not the transport: the PCI function is **modern**. The host writes `targetVirtualMachineMemorySize` (MiB-clamped to `minimumAllowedMemorySize`…`memorySize`); the device then reports `num_pages = (memorySize − target)/4096` in its device config. The feature ladder must take **every offered low bit** — offered lo `0x30000005` (MUST_TELL_HOST, DEFLATE_ON_OOM, + unknown bits 29/30), VER1-only is **refused** (FEATURES_OK never lands — the virtio-net lesson); the hi word takes VERSION_1 alone, never RING_PACKED. **`actual` never leaves 0** even after acknowledged inflates — the driver reconciles `num_pages` against its own tracked PFN count, not `actual`. Both queues carry driver→device `le32` PFN arrays (pfn = PA >> 12): inflate = queue 0 (guest hands pages over), deflate = queue 1 (guest picks pages out of its own ballooned store and re-frees them after the ack). No config-change IRQ plumbing — the guest polls `num_pages` from the idle pass. Guest-observed: `pages` free= drops by exactly the inflated page count and recovers byte-exact on deflate. **[observed]** live boot (issue #3172, macOS 27) |
| Custom virtio | `0x1af4/0x1082` (vendor-defined) | n/a | Firmware boots it with the PCI command register **disabled** (`0x10`) — write `command=0x16` in init before any BAR access. Used-buffer IRQ is a real SPI (69) but **coalesced per burst** — drain the whole used ring. **[observed]** claims 5844/0828/9737 |
| UEFI Secure Boot (firmware, `VZEFIVariableStore`) | n/a (firmware; no PCI function) | n/a | macOS 27+ SDK exposes enrollment: `enableSecureBoot(platformKey:)` (custom `SecCertificate`) or `enableSecureBootUsingDefaultPlatformKey`, `enrollSecureBootSignatures(_:)` with `VZEFISignatureDatabaseConfiguration` (KEK/db/dbx arrays of `VZEFISignatureList`; db accepts `VZEFISignatureSHA256Hash`, also reachable as a raw 32-byte hash file via `VZEFISignatureList(contentsOf:)`), plus `getSecureBootEnabled`/`disableSecureBoot`/`resetSecureBoot`. **No TPM exists anywhere in the framework** — `grep -ril tpm` over the headers is empty — so "measured boot" here means verified boot: the firmware refuses an unpinned image. **M113a probe [observed]** (#2417, `artifacts/sb-probe/`, host macOS 27.2 build 26B5112a, Xcode 27.1 / SDK 27.0): with a self-signed RSA-2048 PK + db hash enrolled on a fresh variable store — (a) the db SHA-256 is the **PE/COFF Authenticode digest**, not the raw file hash (stock image + raw file SHA-256 `bd7203d8…` REFUSED; same image + Authenticode digest `35de135d…` BOOTED: `BOOTED.TXT` on the ESP + serial log); (b) a `BOOTAA64.EFI` tampered by one byte whose digest is not in db is **refused by the firmware** — the VM halts within ~0.4 s with zero serial bytes and no ESP markers (no guest code ever runs); (c) enrolling the tampered image's own digest boots it — enforcement is hash-matching, not incidental. ADR 0054 Part I anchors the verified+measured boot chain here. |
| UEFI Secure Boot runner enrollment (`--secure-boot` flag family) | n/a (host-side enrollment; no PCI function) | n/a | **M113b** (#2418, ADR 0054 Part I): `--secure-boot` plus `--secure-boot-pk <DER X.509>` and one or more of `--secure-boot-db-efi <PE>` / `--secure-boot-db-hash <64-hex>` makes the runner build a **fresh per-run** variable store at `--vars`, call `enableSecureBoot(platformKey:)` with the custom PK, and enroll the db via `enrollSecureBootSignatures` (`VZEFISignatureDatabaseConfiguration` with empty KEK/dbx, a `VZEFISignatureList` of `VZEFISignature.sha256` digests). For each `--secure-boot-db-efi` the runner itself computes the **PE/COFF Authenticode** digest (layout order, CheckSum field skipped, security-directory entry skipped, certificate table skipped — the convention the M113a probe observed). Enrollment flags without `--secure-boot` are a loud runner error, never an ignored flag. **OFF by default**: without the flag the variable store is created/opened exactly as before — byte-identical VM configuration, boot default unmoved. Verified-boot refusal is a firmware halt with zero serial and no ESP markers, as the probe recorded. |

**B7 continuous PCM [observed]** (#1874, `live-sound-playback`, macOS
27.2/arm64): the real VZ output device accepts FLOAT32/48 kHz/stereo,
32 TX descriptors and eight 4096-byte periods. A 131072-byte stream
returns every period with one START and one STOP/RELEASE, no reset.
Full prefill refuses with EAGAIN/zero acceptance; empty running supply
enters sticky XRUN; explicit abort and owner-death/reopen are verified.
Without `--sound`, open and legacy playback refuse ENXIO loudly.
Ownership/completion accounting is not captured audio, an audible
continuity measurement, capture support, or a low-latency guarantee.

**B7 pump cadence [observed]** (M99a, #2179, `m99a-probe` ×3 spec
passes on macOS 27.2 build 26B5101f, instrumented scratch kernel):
the stream pump (`snd_stream_drive`, entered from stream syscalls and
the scheduler main-context poll, never IRQ) ran 174k–502k drive
entries per 12–19 s run at a mean drive-to-drive gap of 24–72 µs with
≥ 99.97 % of gaps < 1 ms across baseline, GOTOP+WEB-corpus+GOSTRESS,
and saturating-spin loads; the largest gap on a zero-XRUN boot was
19 ms. Every gap ≥ 500 ms coincided with an owner-starvation / sticky
XRUN window (0–8 XRUNs per run under load) — the user-side owner, not
the kernel pump, is what starves the ring. A busy-polling userland
doorbell consumer measured publish→submit p50 7–9 µs but p99 64–68 ms
over the mailbox IPC path — multi-10 ms and ≥ 64 ms timeslice stalls
are routine for a user process even near idle — which is why ADR 0046
puts the mixer in the kernel rather than in an `AUDIOD.ELF` daemon.
All figures are buffer/accounting evidence; the no-capture-path limit
above still stands.

Custom-virtio identity rationale (claim 3141): the device keeps the
virtio-pci transitional scheme — vendor `0x1af4` is REQUIRED so the
transport is discoverable as virtio (a private vendor ID would make it a
vendor-specific PCI device and break the capability walk every guest driver
here uses); DID = `0x1040 + deviceID`, with `deviceID = 0x42`. The OASIS
virtio device-type registry has no type 66 assigned (registered types end
well below `0x40`; `0x40+` are unassigned/reserved), and VZ exposes
`deviceID` verbatim in config space, so `0x1af4/0x1082` cannot collide with
any real virtio device shipped by VZ. If the TC ever assigns type 0x42, this
spike must move its deviceID. Class `0x00/0x00` (pre-PCI-2.0 "legacy",
unclaimed by any class driver) keeps macOS from binding anything to it.

Host-push channel (queue 2, claim 3141, `--cvc-echo` only — the classic
`--custom-virtio` attach stays two-queue): the Xcode 27 SDK exposes NO
host-side enqueue — `VZVirtioQueue` elements exist only as descriptors the
guest posted, and `returnToQueue` (used-ring advance + SPI assert) is the
framework's ONLY host→guest signaling. The push therefore uses the
virtio-net-RX pattern: the guest pre-arms ONE empty device-write receive
buffer and signals readiness over queue 1; the host dequeues it via
`nextElement()`, writes the request, returns it; the guest replies on the
same queue. Queue COUNT (2 vs 3) is the capability signal — probed through
the common-config `queue_size` read of select=2, which reads 0 per spec on
the two-queue device (**[observed]** both shapes). Byte protocol:
`CVC-PING-0x42` (13 B) request → verbatim echo reply → `OK:13` ack.
Productionization status (claim 0680, 2026-08-24): the control plane is
BUILT for all three seams — input injection (kinds 1/2, claims 9588/9367),
structured console + framebuffer snapshots (kinds 3/4 and queue 4, below).
Feature-bit-driven capabilities remain future work; queue-count stays the
capability signal.

USB device classes (host configuration surface) — **[observed]** claim #1046,
2026-09-10. The M43 U5 probe (USB serial / CDC-ACM) **could not be
constructed: Virtualization.framework exposes no USB serial device
configuration class.** The complete `VZUSB*` header set at the tested SDK is
`VZUSBController` + `VZUSBControllerConfiguration`, `VZUSBDevice`,
`VZUSBDeviceConfiguration`, `VZUSBKeyboardConfiguration`,
`VZUSBScreenCoordinatePointingDeviceConfiguration`,
`VZUSBMassStorageDeviceConfiguration`, and
`VZUSBPassthroughDeviceConfiguration` (plus the device handles). The
attachable USB classes are therefore keyboard, pointing device, mass
storage, and **host USB passthrough** — and passthrough needs a physical USB
device present on the host
(`VZUSBPassthroughDeviceConfiguration`), which is outside M43's
no-new-hardware scope. There is no emulated serial class to probe, so U5
closes as a **recorded negative**, not a fake probe. The only serial surface
VZ offers remains the virtio-console device (row above).

## Input channel over the custom virtio device

Claim 9588 (issue #523 item 3): queue 3 of the custom virtio device carries
host→guest keyboard injection, retiring the synthesized-NSEvent seam for
gates (the claim-4769 activation wall and the claim-8844 `events=0` failure
mode do not apply — no window, view, or CGEvent exists on this path).

Device shape (queue count IS the capability signal, unchanged rule):

| Runner flag | Queues | Queue plan |
|-------------|--------|------------|
| `--custom-virtio` | 2 | 0 exchange · 1 guest log |
| `--cvc-echo` | 3 | + 2 host-push echo |
| `--via-virtio` | 4 | + **3 input** |
| `--cvc-snap` | 5 | + **4 snapshot** (claim 0680) |
| `--cvc-file <dir>` | 6 | + **5 host file channel** (M34, issues #735/#736) |

Virtqueues are contiguous, so each deeper flag implies the full shape below
it (`--cvc-file` implies the five-queue world including snapshot; the
"deepest flag" rule). The guest driver probes each optional queue's size
through the common config: a non-zero read arms it; zero means absent and
everything upstream stays byte-identical.

## Host file channel over the custom virtio device

M34 HF1+HF2 (issues #735/#736): queue 5 is the HOST FILE CHANNEL — the
guest userland filesystem becomes a macOS folder served by the runner with
plain `FileManager` calls rooted at `--cvc-file <host-dir>`. Guest client
`kernel/src/virtio_file.zig`; host wire module `Sources/VFWire/VFWire.swift`
(pure Swift, zero Virtualization imports — `swift test` runs without a VM).
The wire format is pinned byte-for-byte by the checked-in fixtures
`tests/vf-*.bin` (sha256-pinned by `tools/verify-vf-class-a.sh`) and the
host tests S1–S4 / guest tests G1–G6.

Wire format (one request per element, polled like the exchange queue; the
HF1/HF2 ops hold ZERO state between requests — READ carries an explicit
offset, so an untrusted guest cannot leak host fds):

```
request  [op u8][flags u8][len u16le][payload]      (len = payload length)
reply    [status u8][dlen u16le][data]              (dlen = data length)
```

Read-only ops:

| Op | Payload | Reply data |
|----|---------|-----------|
| VF_PROBE `0x00` | (empty) | the RAW 32,768-byte pattern `pattern[i]=(i&0xff)^((i>>8)&0xff)` — **no frame** (transport-only; the op tells the guest what the reply means) |
| LIST `0x01` | path (empty = root) | 40-byte rows `[name 31][type u8][size u64le]`, ≤128 rows, sorted by name |
| READ `0x02` | `[path][u64le offset]` | ≤ 32,765 data bytes (the 3-byte frame leaves 32,765 of the 32 KiB reply cap) |
| STAT `0x03` | path | `[size u64le][type u8]`; v2 appends `[mtime_sec u64le][mtime_nsec u32le]` (21 B), v3 appends `[ctime_sec u64le][ctime_nsec u32le][birth_sec u64le][birth_nsec u32le][alloc_bytes u64le]` (53 B); a shorter reply's absent groups are flagged absent, never zero-filled |
| STATFS `0x11` | path (share root) | `[total u64le][free u64le][avail u64le][block_size u32le]` (28 B; counts in `block_size` units). Additive — an old host answers status `4`, the guest's named "statfs unsupported" |

Mutation ops (HF3, issue #737 — **additive** 0x04..0x0b, so old hosts
answer them with status `4` and old guests never send them: no version
churn). OPEN/CLOSE/WRITE/TRUNCATE/FSYNC ride an 8-slot host handle table
(parity with the kernel's `file_table.zig` ABI — the write cursors live on
the HOST); RENAME/MKDIR/DELETE stay stateless path ops. All paths are
resolved inside the share root by the same defense as reads.

| Op | Payload | Reply data |
|----|---------|-----------|
| OPEN `0x04` | path · flags: bit0 = create-if-missing, bit1 = append | `[handle u16le]` |
| CLOSE `0x05` | `[handle u16le]` | — (flush + free the slot) |
| WRITE `0x06` | `[handle u16le][data]` (≤ 32,763 data bytes) | `[written u64le]` (cursor advances; append handles write at EOF) |
| TRUNCATE `0x07` | `[handle u16le][size u64le]` | — (cursor clamped below new size) |
| FSYNC `0x08` | `[handle u16le]` | — (synchronize() on the live fd — real durability) |
| RENAME `0x09` | `[from][0x00][to]` (NUL separator; paths are NUL-free) | — |
| MKDIR `0x0a` | path (one level; parents must exist) | — |
| DELETE `0x0b` | path (file or EMPTY directory — never recursive) | — |
| CLONE `0x0c` | `[from][0x00][to]` (both paths resolved inside the share root) | — (APFS COW clone; `to` must NOT exist → status `5`) |

Status: `0` ok, `1` not found, `2` is a directory, `3` truncated (reply
exceeded the guest's buffer), `4` host error (unknown op / bad request),
`5` exists (create/rename/mkdir target collision), `6` handle error (host
handle table full or bad handle).

The host's 8-slot table is VZ-free (`VFWire.FileHandleTable`) — unit-tested
for the cap, cursor advance, append-at-EOF, truncate clamp, and fsync on
the live fd. WRITE data is capped at `write_chunk_max = 32763` per round
trip (the 2-byte handle + the reply-cap symmetry); larger writes stream
across chunks, and the guest's pattern write advances by the
host-CONFIRMED written count so a partial write never corrupts the stream.

CLONE (HF7, issue #741 — additive `0x0c`) is the worktree-dedup op: the
host clones with APFS copy-on-write semantics, so N worktrees of one repo
share blocks until a worktree actually edits a file. Regular files use
`Darwin.clonefile(2)`; DIRECTORY TREES use `copyfile(3)` with
`COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_RECURSIVE` (the clonefile(2)
man page explicitly prefers copyfile(3) for directories). Both subpaths
go through `VFWire.resolveSubpath` — absolute paths, `..`, and symlink
escapes are refused before any syscall, and directory cloning copies
symlinks as links (never chased). `to` must not exist: pre-checked
(→ status `5`), plus an EEXIST race fallback that maps honestly. Space
savings are measured at the VOLUME level, not with `du` — du reports
logical `st_blocks` and cannot see COW sharing (empirically identical for
a clone and a `cp` copy of the same fixture). Guarded live by the HF7
phases of `tools/verify-live-vf.sh` with raw before/after numbers under
`artifacts/m34-hf7-measurement.txt`. **[observed]** issue #741, claim 1312

VF_PROBE is HF1's acceptance case A — it proves the ONE unproven transport
fact, a full **32,768-byte device-write reply** (claim 0680 proved 32 KiB
device-reads; the claim-9492 echo was the largest device-write at 12,340
bytes). The used ring must report the FULL writtenByteCount (32768); the
guest regenerates and compares all 32,768 bytes. The XOR-symmetric pattern's
RFC-1071 checksum folds to `0x0000` — genuine, and all three implementations
(guest Zig, Swift, python) agree; the full byte compare is the real proof.
Paths are ≤ 255 bytes, root-relative, `/`-separated; the host rejects
absolute paths, `..`, and symlink escapes (`VFWire.resolveSubpath`).
**[observed]** claims 4515

Wire format — one message per receive buffer, written by the HOST into a
buffer the GUEST pre-armed (the only host→guest data path the SDK exposes,
the claim-3141 virtio-net-RX pattern):

```
offset  size  field
0       1     kind    1 = HID keyboard boot report
                      2 = absolute-pointer report (claim 9367)
                      3 = console control (claim 0680)
                      4 = framebuffer snapshot request (claim 0680)
1       1     flags   reserved, host writes 0
2       2     len     payload length, little-endian (8 for kind 1,
                      5 for kind 2, 1 for kind 3, 0 for kind 4)
4       12    payload kind 1: the raw 8-byte report [mods, 0, k0..k5]
              (HID boot protocol: mods bit0=LCtrl bit1=LShift bit2=LAlt
              bit3=LCmd; k0..k5 = usage IDs, 0-padded)
              kind 2: the raw 5-byte report [buttons, x_lo, x_hi, y_lo,
              y_hi] — the canonical shape input.decode_pointer_report reads;
              NOT a raw native XHCI packet; buttons bit0 = button 1;
              x/y are HID ABSOLUTE logicals 0..32767 (the guest's
              map_pointer_axis scales them onto the framebuffer axis —
              the same convention the USB screen-coordinate pointer uses)
              kind 3: one control byte — bit0 set arms the structured-
              console tee, bit0 clear disarms it
              kind 4: empty — a request to stream one snapshot
```

Fixed total size 16 bytes. Receive buffers are posted at capacity 32 bytes
(a size mismatch is a guest-side malformed-message counter, never a wedge).

Native VZ USB `05ac:8106` is decoded separately: report ID 1, buttons,
LE16 X/Y (0..32767), then ignored wheel/pan fields. Genuine descriptor and
motion captures are pinned under `tests/fixtures/input/m91/`, with source
provenance and capture gaps. Synthetic endpoint/button vectors are labeled
as such. The canonical five-byte payload is unchanged; neither decoder
guesses a transport from packet length.

Semantics:

- The guest pre-arms a pool of EIGHT device-write buffers on queue 3 at
  spike-init time (one kick) and replenishes each buffer immediately after
  consuming its completion (free → re-alloc → re-post → kick). A message
  whose envelope or `len` does not validate increments the bad-message
  counter and is dropped loudly-by-counter, never decoded partially.
- Kind-1 payloads are handed to `input.decode_keyboard_report` verbatim —
  the exact function XHCI keyboard reports go through — so injected keys
  are ordinary keys everywhere downstream: the per-process event FIFO
  (`sys_poll_event`/`sys_wait_event`) when an app window owns focus, the
  console byte FIFO + line editor when the terminal does, and the `input`
  monitor command's counters either way.
- Kind-2 payloads (claim 9367) are handed to `input.decode_pointer_report`
  verbatim — the exact function an XHCI pointer report goes through — so
  injected pointers are ordinary pointers downstream: cursor motion,
  `dui` click-to-focus (the window manager's pointer_tick edge logic sees
  a press exactly as it would from USB), and the `input` ptr-* counters.
- The guest pumps completions from the shell idle loop's RX poll seam (one
  cheap used-ring read when unarmed); polled, like every other
  custom-virtio path — no IRQ dependency.
- Host pacing: keyboard messages enqueue at 0.25 s spacing on the device's
  serial delegate queue (all element access single-threaded with the
  callbacks); if the pool is momentarily empty the enqueue retries
  (bounded, loud on exhaustion) instead of dropping. POINTER sequences
  pace at 2.5 s per message instead: presses are edge-detected by
  `driving_award.pointer_tick`, which runs once per shell-idle pass — at
  the Road Pops present cadence (~1.5–2 s), NOT per message — and
  sub-tick spacing collapses press+release into one pass so the click
  never fires (**[observed]** claim 9367 live failure at 0.25 s, clean
  focus moves at 2.5 s).
- Host token→usage mapping is the guest keymap's inverse over the same
  vocabulary `macKey`/`macChord` accept (a–z, 0–9, punctuation, Enter,
  named nav tokens, ctrl-x); keyUp is the all-zero report, so held-set
  transitions drive KEY_DOWN/KEY_UP exactly like a real keyboard.

Version detection is loud: `--via-virtio`/`--cvc-echo`/`--custom-virtio`
on a binary without the SPIKE custom-virtio code, or on a host older than
macOS 27, is a fatal runner error — never a silent flag ignore. The serial
console keeps its panic/fallback role untouched; the input channel is
additive and default-off (without the flags the VM configuration is
byte-identical).

**[observed]** claim 9588 (2026-08-24, macOS 27.0 build 26A5416b): the full
channel proved live and headless (`GATE_VIRTIO=1 bash tools/verify-live-input.sh`,
evidence under `artifacts/live-input-virtio-*`). One boot carried the whole
assertion set byte-exactly: four-queue device attach + DRIVER_OK; guest q3
pool armed (`cvspike: q3 armed bufs=0x0000000000000008`) alongside a GREEN
claim-3141 push echo (`cvspike: q2 ok=1`) in the same boot; six HID-shaped
16-byte messages enqueued strictly in order and consumed via the idle-loop
pump (queue-3 replenish notifications observed host-side); and the guest's
own report `input: armed=0 fifo=0/64 dropped=0 events=6 kb-mods=0x0
kb-usage=0x28 kb-byte=0xa ptr-btns=0 ptr-x=0 ptr-y=0 ptr-reports=0` —
armed=0 proving no USB keyboard was ever attached while events=6 proves the
injected keys decoded through the standard path. Two live findings pinned
here as contract facts: (1) a fixed-schedule burst can outrun the pool's
replenish under desktop load, so delivery is STRICTLY ORDERED — each stroke
is enqueued only after the previous was accepted, and a pool-empty retry
delays (never reorders) the rest of the sequence (a reordered burst was
observed typing `inpu⏎t`); (2) without a window manager (headless boot) the
terminal is the keyboard sink by definition — the FIFO→line-editor bridge
flows unconditionally when the WM is unarmed, unchanged focus discipline
when it is armed.

**[observed]** claim 9367 (2026-08-24, macOS 27.0 build 26A5416b): kind-2
pointer messages proved live and headless
(`bash tools/verify-live-pointer-virtio.sh`, evidence under
`artifacts/live-pointer-virtio-*`): four-queue attach; q3 pool armed +
claim-3141 push echo green in the same boot; eight kind-2 messages
(2 moves + 2×[down,up] over WINLOOP → terminal) enqueued strictly in
order at 2.5 s pacing and decoded through `decode_pointer_report`; guest's
own report `input: armed=0 ... ptr-x=16384 ptr-y=27307 ptr-reports=8`
(armed=0 — NO USB HID device was ever attached); and two click-driven
focus moves printed by the window manager itself (`dui: pointer focus=2`
then `focus=0`) — issue #151's pointer-focus proof upgraded from
class-C-only to class-B-headless. Two live findings pinned as contract
facts: (1) the pointer pacing rule above (0.25 s collapses clicks);
(2) hit-testing scans the window ARRAY from the end (raise() moves a
window to the array end), so a gate must `dui raise <id>` a user window
above the fullscreen terminal before clicking it — session setup via
documented monitor commands, with the focus proof still driven purely by
the injected messages.

## Structured console + framebuffer snapshots over the custom virtio device

Claim 0680 (issue #523 item 3 capstone): the two remaining observation
channels ride the device, so a gate can drive guest input AND read guest
output with no CGEvent synthesis and no ScreenCaptureKit screenshot
scraping (and none of their TCC permissions) anywhere in the critical path.

Structured console (queues 1 + 3): the guest sends `cvconsole-ready` on
queue 1 right after arming its queue-3 pool; the host answers with ONE
kind-3 control message (bit0=1) when it wants the tee. While armed, every
kernel console byte is DUPLICATED onto queue 1 as it already goes to
serial — line-buffered into messages of up to 256 bytes; a partial line
(the prompt case) flushes from the shell idle seam. The host writes the
raw bytes verbatim into its `--cvc-console-file` (NO injected newlines),
so the capture stays byte-faithful to serial. Serial keeps flowing
unchanged; the tee is additive and default-off. A send whose host ACK does
not arrive within a tight budget increments a drop counter instead of
stalling output.

Framebuffer snapshots (queue 4): a kind-4 request arms a pending flag; the
guest's idle seam then streams the composed scanout (`virtio_gpu.gpu_fb`,
1280×720 BGRX, 3,686,400 bytes) as tagged little-endian messages:

```
header  [tag=0x01]['S''N''A''P'][ver=1][bpp][width u32le]
        [height u32le][total u32le][chunk u32le]              (32 bytes)
chunk   [tag=0x02][seq u16le][len u16le][cksum u16le][rsvd x6]
        [payload ≤ chunk_len]                                 (12 + len)
done    [tag=0x03][chunks u16le][total u32le][cksum u16le]
        [rsvd x8]                                             (16 bytes)
```

`cksum` is the RFC 1071 one's-complement checksum over the chunk payload /
the whole frame. Chunks are 32 KiB (113 per frame) submitted strictly in
order, each acknowledged by the host (`OK:<n>`, the log-transport
convention); chunk payloads point DIRECTLY into `gpu_fb` — no staging
copy. The host reassembles into `<screen-base>-snap-<n>.raw`, verifying
sequence continuity, per-chunk checksums, totals, and the whole-frame
checksum before writing the file; any mismatch aborts the assembly loudly
on both ends (never a silently corrupt image).

Contract facts pinned live (claim 0680, macOS 27.0 build 26A5416b):

1. **Polled sends must free their descriptor chains.** A submit+wait that
   never returns the chain to the free list leaks two descriptors per
   send; the spike's five lines survived, but sustained tee traffic
   exhausted the 32-descriptor ring within seconds and every later send
   dropped silently-by-counter until the fix (`defer free_chain_q`).
2. **RFC 1071 needs a u64 accumulator at whole-frame scale** — a 32-bit
   sum overflows long before 3.5 MiB (the host side died mid-stream with
   a Swift arithmetic-overflow trap). Guest and host both accumulate u64
   and fold once.
3. **Injected keys go to whoever owns keyboard focus** — at a headless
   boot the fullscreen terminal is the sink only until a user window
   opens; a gate must type BEFORE opening windows (or refocus first).
4. The five-queue attach is otherwise byte-identical: all four-queue and
   smaller gates re-ran PASS unchanged on the same build.

Non-PCI platform facts:

- **EFI variable store**: file-backed (`VZEFIVariableStore`); create with
  `init(creatingVariableStoreAt:options:)` on first boot. **EFI runtime
  services survive `ExitBootServices`** — post-exit `SetVariable` persists
  (the NVRAM marker/fallback channel). **[observed]** claim 0009.
- **Guest RAM is NOT mapped into the host runner process** — a host-side
  memory-dump fallback is impossible on VZ. **[observed]** claim 0009.
- **VZ machine-state save/restore**: **[observed]** #1370, macOS 27.2
  (26B5086k), arm64, Xcode 27.0 (27A266a). `--vz-restore` passes
  `validateSaveRestoreSupport`, then `pause` → `saveMachineStateTo` → `stop`
  → `restoreMachineStateFrom` → `resume`; a fresh serial query recovers the
  RAM-only clipboard UUID (`live-vz-restore`). Same-process, same-host
  headless EFI/disk/serial/entropy, including the ASIF overlay. Saved state is
  deleted on success; failures may leave it beside the serial log until
  enclosing temporary-directory cleanup. This is not a framebuffer snapshot.
  **M70g G3 (#1459) — [observed] 2026-09-18, same host/build, `live-vz-restore`
  runs `save`/`load`/`gpu`/`usb`/`msd`/`cvc`:**
  - **Cross-process restore works.** `--vz-restore-save <dir>` (process A)
    saves state + the ASIF overlay + the marker and exits; `--vz-restore-load
    <dir>` (process B, a fresh `VZVirtualMachine`) restores without booting —
    B's serial log carries no kernel banner — resumes, and a fresh serial query
    recovers the RAM-only marker A stored. **VZ enforces one identity fact:**
    the `VZGenericPlatformConfiguration.machineIdentifier` must be the saved
    one (persisted as `machine-id.bin`); with VZ's per-configuration random
    identifier the restore fails `VZErrorRestore` (12) "invalid argument". The
    measurement reused the same EFI variable store file and the overlay the
    save process persisted; a mismatched store or a fresh overlay was **not
    tried** (**[inferred]** they would also have to match).
  - **virtio-gpu attached (`--display`, headless, no view): full cycle PASS.**
  - **USB HID keyboard+pointer on XHCI (`--input`): full cycle PASS.**
  - **USB mass storage on XHCI (`--usb-msd`): mixed.** `validateSaveRestoreSupport`
    and the save pass every time; the restore PASSED 8 of 9 measurement cycles
    and failed once, under the gate harness, with `VZErrorRestore` (12)
    "permission denied" at `restoreMachineStateFrom` — not reproduced by the
    backing file's shape (sparse vs. zero-filled), its location (`/tmp` vs.
    `/var/folders`), or a preceding `--input` boot. That count is a
    measurement-session observation whose per-cycle logs are not retained; the
    refusal is not deliberately reproducible, so `live-vz-restore` run `msd`
    pins the deterministic half hard and accepts exactly those two cycle
    outcomes. **[observed]** #2261, macOS 27.2 (26B5101f): the same
    `VZErrorDomain Code=12` "permission denied" restore refusal hit every
    `restoreMachineStateFrom` leg (headless-base, cross-process load,
    virtio-gpu, usb-hid, fs-load — 5 of 5 restores) of a `live-vz-restore`
    run executed while a second VZ gate held a running VM; the identical
    spec passed 18/18 when rerun with no concurrent VZ VM. The refusal is
    therefore not msd-specific and is aggravated by concurrent VZ load.
    **[observed]** #2489 (M119e), 2026-10-17, macOS 27.2 (26B5112a), arm64:
    the characterized bound — and it is broader than the card's framing.
    A dedicated repro loop drove 600+ `restoreMachineStateFrom` calls
    (same-process `--vz-restore --usb-msd` cycles, plus headless-base and
    cross-process-load legs) across varying host load: **every call
    refused `VZErrorDomain Code=12`, 0 passes** — with 1-8 foreign
    `VMRunner` VMs resident AND across a ~90-second window with ZERO
    other VMRunners resident (14 consecutive solo cycles, all refused).
    Even a VMRunner binary built at the 071eef6b era — the code that went
    18/18 green on 26B5101f — refuses identically, so this is NOT a
    VirelaiOS runner regression. The reason string varies within one
    build — "invalid argument" (~600) and "permission denied" (32) were
    both recorded on 26B5112a — so Code=12 is the stable signature, not
    the reason text. The refusal is image-independent (sparse-zeroed,
    real MBR+FAT32, and no-overlay plain-disk boots all refuse
    identically) and device-independent (matching #2261's all-legs
    refusal). A second signature was observed at VM START:
    `VZErrorDomain Code=2 "The storage device attachment is invalid."` on
    ~4% of attach attempts under load, on both image shapes. What this
    bounds: the M70g "8/9" flake is the leading edge of a refusal mode
    that can saturate to 100% — observed correlated with concurrent VZ
    load (#2261) and, on this session's host state, persistent even
    without it; whether 26B5112a carries an unconditional restore
    regression or the host was left degraded by churn cannot be decided
    without a quiet reference host (the solo-pass evidence stays #2261's
    18/18 on 26B5101f and M70g's 8/9 on 26B5086k). No guest-side or
    runner-side fix applies — VZ offers no partial-state or quiesce API,
    and the refusal is persistent (not flappable), so a retry would only
    mask it. `live-vz-restore` run `msd` accepts a PASS or a Code=12
    refusal carrying either recorded reason; the stricter legs still pin
    PASS, so on a host in this state the spec reports the refusal
    honestly as FAIL (observed: 13/18) rather than masking it.
  - **custom-virtio attached: VZ REFUSES** at `validateSaveRestoreSupport`:
    `VZErrorDomain Code=2 "Unsupported custom virtio device in configuration."`
    Every configuration carrying the custom-virtio device (input queue, host
    file channel, snapshot channel, structured console) is therefore
    unsaveable on macOS 27.2; the gate run `cvc` pins the refusal verbatim so
    a release that lifts it fails loudly.
  - **gpu3d-metal attached (`--gpu3d-metal`, the M102 VIR1 render device):
    VZ REFUSES the same way** — it is a `VZCustomVirtioDevice`, so the same
    `VZErrorDomain Code=2` refusal applies. **[observed]** #2261, macOS 27.2
    (26B5101f), arm64, Xcode 27.1 (27A9275), `live-vz-restore` runs `gpu3d`
    and `cvboth` (`--custom-virtio --gpu3d-metal` together). `--gpu3d-metal`
    is admitted under `--vz-restore` as a device knob so the verdict is
    measured rather than refused at parse time.
  - **Refusal contract (#2261):** a configuration carrying any custom-virtio
    attachment is unsaveable, and VZ offers no device-detach, quiesce, or
    partial-state API — `customVirtioDevices` are part of the immutable
    configuration, so a graceful detach/save/reattach path does not exist on
    this platform. The runner's refusal names the blocking attachment(s)
    (`Blocking device(s): custom-virtio[,gpu3d-metal]`) instead of only the
    full device list; the gate runs `cvc`/`gpu3d`/`cvboth` pin that naming.
  - **Standard VirtioFS configuration: [observed, host-side validation only]**
    an entitlement-signed host probe with
    `VZVirtioFileSystemDeviceConfiguration` passes
    `validateSaveRestoreSupport` on this Mac. This establishes configuration
    eligibility only; the guest observation is recorded below.
  - **Not measured:** cross-host and cross-macOS-version portability of a
    saved state (one host available). Nothing here promises them.
- **M83g (#1780) — standard VirtioFS/FUSE: [observed] 2026-09-27,
  macOS 27.2 (26B5091g), arm64, `live-vz-restore` 16/16:**
  - `VZVirtioFileSystemDeviceConfiguration` passes
    `validateSaveRestoreSupport`. In the guest, PCI device `0x1af4:0x105a`
    initializes with tag `virelaios`, two queues (high-priority plus one
    request queue), FUSE 7.31, and a 2048-byte maximum write.
  - `/host` works through the FUSE queue: a live `vf ls` lists the attached
    directory, and `vf cat` reads a host file byte-exactly (85 bytes,
    checksum `0xf346` in the focused I/O boot).
  - The cross-process `fs-save`/`fs-load` pair passes. GOTABWM reads
    `SETTINGS.TXT` (`wm=gotabwm`, `theme=light`) and `SESSION.TABS`
    (`Notes,Calc`, pinned `1,0`, active tab `1`) before save, then emits the
    same state-bearing witness after process B restores and resumes. A fresh
    `vf cat VZRESTORE.WITNESS` after resume returns all 13 bytes. The guest
    also writes and syncs a 4,097-byte deterministic pattern in three FUSE
    writes, and the host byte-checks it; the staged settings/session/witness
    bytes remain unchanged.
  - The custom-virtio negative remains pinned: VZ refuses it at
    `validateSaveRestoreSupport` on this host. VirtioFS remains explicit
    (`--virtio-fs`); the boot default and `/host` API are unchanged.
- **M115a (#2460) — `VZVirtioSocketDevice` (`--vsock`): [observed]
  2026-10-17, macOS 27.2 (26B5112a), arm64, `live-vsock-restore`:**
  - **Configuration-eligible.** `config.socketDevices` carrying a
    `VZVirtioSocketDeviceConfiguration` passes
    `validateSaveRestoreSupport` — unlike every `VZCustomVirtioDevice`,
    which VZ refuses at validation (`VZErrorDomain` Code=2). The device
    is therefore the only in-SDK guest↔host channel that can reach the
    restore question.
  - **The channel works.** On a plain `--vsock` boot the guest sees the
    modern virtio-pci device `0x1af4:0x1053` (virtio device ID 19), arms
    rx/tx/event queues, reads `guest_cid` (observed 3), and a serial-driven
    `vsock <port>` issues a stream `OP_REQUEST` to `VMADDR_CID_HOST` —
    the runner's `VZVirtioSocketListener` on the port accepts it
    (`VSOCK: listener accepted guest connect dport=1208`, guest prints
    `vsock: connected`). An unlistened port answers `OP_RST`
    (`vsock: refused`).
  - **Save completes; the restore leg is bounded by the host.** The
    cross-process `--vz-restore-save` run with vsock attached saves
    cleanly (`SAVE PASS`). Every `restoreMachineStateFrom` attempt on
    this host — vsock same-process, vsock cross-process load, and the
    headless-base control — refused `VZErrorDomain` Code=12 ("permission
    denied"), the M119e saturating bound already recorded above: on this
    build the refusal is host-wide, not device-specific, so **whether a
    guest connect survives restore is undecidable here**. The spec's
    `load` leg accepts exactly two outcomes: CROSS-PROCESS PASS with the
    post-restore connect accepted, or the verbatim Code=12 refusal.
    A reference host where the bound does not saturate decides it.
  - **Fallback if a refusal emerges on a quieter host:** the VirtioFS
    marker + host-poll path (the M115 index's named fallback), since
    `VZVirtioFileSystemDeviceConfiguration` is already proven
    restore-safe (M83g above).
- **M131d (#2641) — warm-checkpoint fleet census + the vz-restore flag
  bound: [observed] 2026-10-19, macOS 27.2 (26B5112a), arm64:**
  - The runner's `--vz-restore` mode is a standalone headless probe with a
    fixed flag allow-list: `--overlay-base`, `--vars`, `--serial`,
    `--cpus`, `--timeout`, the `--vz-restore-*` knobs, the `--script*`
    family on load, `--virtio-fs`, `--display`, `--input`, `--usb-msd`,
    `--custom-virtio`, `--gpu3d-metal`, `--vsock`. A checkpoint base boot
    carrying `--data-disk` exits rc=1 on the probe's usage guard — so legs
    whose shape needs `--data-disk`, `--net*` capture/responders,
    `--sound*`, console or input-injection machinery can never restore
    under the current harness. `fleet.sh census` classes them (c).
  - Fleet census (988 legs): 810 device-ineligible, semantic a=25 b=31
    c=52 d=6 e=32 f=12, warm-adopted 20, unclassified 0.
  - On this host every restore still refuses `VZErrorDomain` Code=12 —
    warm legs degrade to a single cold boot (`warm=fallback(12)`), so the
    fleet cold-vs-warm wall-clock row waits on the reference host where
    `live-vz-restore` headless-base restores (`warm=restored`).
- Config used: 512 MiB RAM, 2 vCPUs, optional virtio-gpu/sound/net devices
  (flag-gated; the default VM stays byte-identical without flags).
- **A large image is not a RAM problem by itself, and the guest does not
  stage it.** [observed] `GOBIG.ELF` — a real stripped `GOOS=virelai` Go
  binary of 9,502,880 B, 8,416,224 B of that one initialized `.data`
  payload — execs in-guest and reads its own bytes back from 1, 4 and 8 MiB
  into that payload (`go-hello` run 02, `datapages=2097`). The payload
  crosses the host file channel in 32 KiB replies; the loader maps exactly
  the image's declared segments (`text`/`rodata`/`data`, W^X) and holds no
  whole-file buffer for that shape — the 2 MiB staging array is only for
  DSK1/DSK3/contiguous-ELF/PT_INTERP images, which are still refused past
  it. The image-independent ceiling is the physical allocator: 512 MiB of
  guest RAM, against a 32 MiB acceptance bound on the file.
- **A guest read of the host share costs at most two round trips per 32 KiB
  call, and runs at ~66 MB/s.** [observed] `go-hello` run 04 has the guest
  read a 9,502,880 B image out of the share end to end: 291 `sys_file_read`
  calls (exactly `ceil(bytes/32768)`), ~67,815 KiB/s best observed measured
  from EL0 with CNTPCT_EL0 (card #3035 evidence: 36,834–67,815 KiB/s across
  three same-shape boots). The 32 KiB per-call cap is the EL0 surface's
  (`kernel/src/syscall.zig` `file_io_max` = `virtio_file.reply_cap`, raised
  from the old 2048-byte stack stage by card #3035), not the wire's — a
  READ reply carries ≤32,765 data bytes, so one EL0 call is one wire round
  trip (occasionally two at the cap edge). Writes are capped the same way
  (32 KiB). `mmap` story: ADR 0035.
- The project targets Apple silicon / Virtualization.framework only; there
  is no QEMU path.

## Capacity bounds (measured ceilings)

M129c (#2612): every row below is a deliberate bound, not a stall — a
caller that reaches one is refused by name. Each row gives the ceiling,
the pinned constant (file or ADR), the symptom at the wall, and the leg
that measured it. "Measured" means observed on a live boot; comptime
constants are cited where they live. The live occupancy lines come from
the monitor's `resources` command. M129b (#2611) raised the task pool
16 → 64 with the process registry in parity — the pre-raise saturation
run (2026-10-18) took `tasks=3/16 → 16/16`, `procs=1/16 → 14/16`,
`tables=38 → 306/512`, the 14th `exec` printing `error: no free
scheduler pool slot`; after the raise, exec's first wall is the
512-page table carve-out (~20 tables per live root, refused
`page-table carve-out exhausted`), and the pool itself saturates only
through `sys_thread` tasks (`go-stress` run 07). A `sysinfo`/`pages`
read on the M129a (#2610)
512 MiB boot reports `memory: usable=0x1febf000` (~511 MiB of the
compiled 512 MiB; `pages: total=0x1febf free=0x1eeb8 excluded=0x1007`).
card #2757 re-measured every row on the post-#2755 + post-#2756
tree (2026-10-20): `live-scale` run 01 (ten USER.BIN execs all fit;
USER.BIN is a 2-tick transient — the closing `resources` read landed
past its `status=43` reap: `tasks=4/64` kernel+counter,
`procs=12/64` mid-teardown descriptors, `tables=60/512` freed
roots), `live-m16-resources` run 01 (22 COUNTER.BIN roots →
`tasks=25/64`, `procs=23/64`, `tables=498/512`, the carve-out
refusal by name), and `go-stress` run 07 on the retuned storm
fixture (pool `tasks=64/64` through slot-73 children, `error: no
free scheduler pool slot` on one more exec). Two card #2755 naming
fixes are folded in below: physical-pool exhaustion is ENOMEM, not
ENOSPC.

| Bound | Ceiling | Symptom at the wall | Source / measured by |
|-------|---------|---------------------|----------------------|
| Scheduler task pool | 64 slots = shell + worker + idle + **61 EL0t user slots** (M129b #2611, raised 16 → 64) | `pool_full` → ENOSPC; serial `error: no free scheduler pool slot` (exec path); `sys_thread` op 0 → `EAGAIN` (thread path) | `scheduler.max_tasks` (`kernel/src/scheduler.zig`); **[observed]** `go-stress` run 07, re-measured card #2757 on the retuned fixture — twelve storm programs seat the pool to `tasks=64/64` through slot-73 children, the next exec refuses by name |
| Threads per process | 16 extra seats per descriptor (M129b #2611, raised 6 → 16 — the storm leg showed a runtime's `newosproc` EAGAIN-throw at the 6-bound while the pool still had slots) | `sys_thread` op 0 → `EAGAIN` | `process.max_threads` (`kernel/src/process.zig`); **[observed]** `go-stress` run 07 first attempt — `fatal error: newosproc` at `tasks=61/64` pinned the wrong bound refusing |
| Concurrent Go runtimes | ~20 at `GOMAXPROCS=1` (3 tasks/runtime → 60+3=63/64); ~15 at compiled `GOMAXPROCS=2` (4 Ms/runtime → 60+3=63/64) | same `pool_full` wall — at this bound the exec-side table carve-out (~24 concurrent roots) refuses first | ADR 0027 D1/D6 (one M per task), ADR 0052; **[observed]** `go-wm-hid` run 07 seats four runtimes (seat+GOEDIT+GOTERM+GOCALC) well inside the budget |
| Process registry | 64 (M129b #2611 — parity with the pool: every live task's process holds a descriptor; ~33.5 KiB BSS per descriptor) | `process_full` → ENOSPC; `process registry exhausted (all processes live; wait for one to exit)` | `process.max_processes` (`kernel/src/process.zig`); **[observed]** `live-m16-resources` `procs=` occupancy line — card #2757 re-measure `procs=23/64` (1 exited + 22 live roots) with the pool still far off |
| Page-table carve-out | 512 pages (2 MiB fixed BSS; reaped roots return their subtree to the free list — M129b note: the "monotonic" claim predates #2116) | `table_full` → ENOSPC; `page-table carve-out exhausted (too many user-root rebuilds)` — **exec's first wall at the 64-slot pool** | `mmu.table_page_count` (`kernel/src/mmu.zig`); **[observed]** card #2757 `live-m16-resources` run 01 — 22 live COUNTER.BIN roots take `tables=498/512` (~20.8 pages/root) at the refusal with `tasks=25/64` |
| File handles per process | 8 slots shared by open handles, captured-directory streams, and `/dev/tty` (`resource_count` counts all three — the *file* ceiling is lower once a process holds its tty or a dir stream; finding routed to card #2736) | `-5` = ENOSPC (`HandleLimit` / table full) on open | `file_table.max_handles_per_process` (`kernel/src/file_table.zig`), ADR 0010; **[observed]** `live-m16-resources` `fds=8` — the `resources` line prints the bound, not live occupancy |
| Host share handle table | 8 slots (parity with the guest ABI — write cursors live on the host) | wire status `6` (handle error) | `VFWire.FileHandleTable` + `kernel/src/virtio_file.zig`; cap unit-tested host-side (`swift test`) |
| Event FIFO / mailbox ring | 64 events, 32 messages per process | ENOSPC (-5) checked before any bytes are copied | `events.max_events`, `mailbox.max_messages`; **[observed]** `live-m16-resources` `events=64 mbox=32` — the `resources` line prints the bounds; `mbox <pid>` reports a process's live pending count |
| User windows | 8 slots (ids 2..9; the registry total `max_windows` is 13) | `sys_win_open` → ENOSPC (-5) when all eight are open; ENOMEM (-10) when the pool has no contiguous run | `driving_award.user_windows_max` / `user_open`; occupancy audited live (`resources: windows=N/13` — `windows=0/13` at boot on the card #2757 re-measure) |
| mmap regions per process | 16 | `sys_mmap` → ENOMEM (-10) when `add_mmap_region` fails at the ceiling | `process.max_mmap_regions`; `go-stress` header: the kernel's loud-refusal budget, observed 8 on the landed roster |
| Native TCP socket table | 4 listeners + 4 connections, ≤4 owners, ≤2 accepted children per listener, 24 KiB per-connection budget | `Capacity` → ENOSPC → `vi.ErrConnBusy`; a wire-admitted child also charges the listener's owner — a SYN to an owner at `owner_limit` is refused (`owner_saturated`, `net: owner-saturated`) exactly like a listener at `child_limit` | `socket_core.zig` `listener_limit`/`conn_limit`/`owner_limit`/`child_limit`/`core_limit`; bounded table landed M99f/g (#2184/#2185) |
| TCP window / segment | fixed advertised window 4096; payload ≤1460 B per segment (our MSS 1460); fixed src port 8000 on the legacy monitor client | oversized payload truncated honestly; peer RST kills the connection (`connection refused`) | `tcp.zig` `window`/`payload_max`/`our_mss`; **[observed]** `live-net-tcp-syscall` asserts the refusal packet `window=4096` |
| Terminals | 4 | `terminal.create` → null → `-5` ENOSPC on the `/dev/tty` open | `terminal.max_terminals` (`kernel/src/terminal.zig`), minted lazily in `file_table.zig` |
| Tabs (GOTABWM seat) | 16 | `full()` declines a new tab; persisted `.tabs` v2 state is ≤1110 B | `tabwm.max_tabs` (`user/src/tabwm.zig`), `gotabwm.MaxTabs` (ADR 0033 cap), `tools/go/tabcodec` |
| EL0 share I/O rate | 32 KiB per `sys_file_read`/`sys_file_write` call (`file_io_max` = `virtio_file.reply_cap`; raised from 2048 B by card #3035) — the EL0 surface; one wire READ reply carries ≤32,765 data bytes | a larger write is refused ENOSPC; a larger read truncates to 32 KiB; measured ~66 MB/s | `syscall.zig` `file_io_max`; **[observed]** `go-hello` run 04: a 9,502,880 B read in 291 calls at the 32 KiB cap (CNTPCT_EL0); card #3035 re-measure 36,834–67,815 KiB/s |
| Host-file-channel wire caps | LIST ≤128 rows; READ ≤32,765 B/reply; WRITE ≤32,763 B/round trip; path ≤255 B; reply ≤32,768 B | status `3` (truncated) / `5` (exists) / `6` (handle error) | `virtio_file.reply_cap`/`write_chunk_max`, `VFWire`; byte-pinned by `tests/vf-*.bin` (`tools/verify-vf-class-a.sh`) |
| vsock transport | 8 descriptors per queue; rx pool 4×2048 B; event pool 2×64 B; default host-listen port 1208 | unlistened port → `OP_RST` (`vsock: refused port=`) | `kernel/src/virtio_vsock.zig`; **[observed]** `live-vsock-restore` / M115a #2460 — connect accepted on 1208, RST on 9 |
| Exec wait budget | `execWaitNs` = 15 s per spawned-child wait (the default `vi.Wait` budget is 120 s) | deadline → `vi.ErrWaitGone` ("wait: target not waitable") | `user/go/store/install.go`, `user/go/vi/proc.go`; **[observed]** M109f #2402 — a fresh-share FLINT clone lands `clone ok` ~21 s, past the bound: `live-agent-loop` run 06 fails 0/5 on a quiet host; margin card #2522 |
| Host recorder | `hardCap` = 60 s at `fps` = 15 (≤ ~900 frames per take) | the cap timer ends the take honestly; receipt `recording=off frames=N bytes=B` | `HostRecorder.swift` (M114e #2458); **[observed]** `live-host-ui` run 05 drives record-start/record-stop; `HostRecorderTests` pin the cap |
| Guest RAM (compiled default) | 512 MiB (`config.memorySize`; `--memory-mib <n>` overrides, bounded 64…2048). VZ anchors guest RAM at phys 0x7000_0000 growing upward (**[observed]** 256 MiB → [0x7000_0000, 0x8000_0000), 512 MiB → [0x7000_0000, 0x9000_0000)); the allocator bitmap + COW refcounts + identity map span a fixed 4 GiB from that base, and the user-stack VA band opens at 4 GiB, so RAM must stay below it — 2304 MiB is the hard geometry ceiling, 2048 the flag bound | physical allocator exhausted → `out_of_memory` → **ENOMEM** (`out of physical pages (text/stack/exception stack)` at the monitor; card #2755 split the fold — capacity tables stay ENOSPC, memory is -10); a guest whose RAM reached the fixed user `stack_va` used to fail `build_identity_map` at M2_TABLE (zero serial) — M129a (#2610) moved the boot stack VA to 0x1_8000_0000 | `main.swift` `config.memorySize`; **[observed]** `sysinfo`/`pages` on the 512 MiB boot: `usable=0x1febf000`, `total=0x1febf free=0x1eeb8 excluded=0x1007`. M129a (#2610) moved the compiled default 256 → 512 MiB; M129b (#2611) then raised the pool 16 → 64 — the table carve-out above is now exec's first concurrency binder |
| Per-app RAM / exec image | file ≤32 MiB (`exec_image_max` → `image_too_large`); initialized bytes ≤32 MiB (`elf.load_max` → `segment_too_large`); mapped bytes ≤64 MiB (`elf.map_max` → `map_too_large`, VIRTUAL — the zero-fill tail is demand-zero since card #3032); an idled GOCALC holds 5,984,260 B resident (~5.7 MiB) | the named loader refusals, then `out_of_memory` → **ENOMEM** (card #2755); the pre-#3032 "~4-5 concurrent heavy apps" wall is retired — at ~5.7 MiB per app the task pool's ~15–20-runtime bound (row above) refuses first | `kernel/src/exec.zig`/`elf.zig`, M72a #1579; per-app figure **[observed]** card #3042 `live-bench` `go-rss` leg (`sys_procs` v2 `mem_bytes` on the idled app; card #3032's PR #3088 measured a 48 MiB-virtual image resident at exec = 2,057 pages ≈ 8.4 MiB) |
| Application timer | 1 countdown per process | second `sys_timer_set` re-arms the single slot (no queue) | `kernel/src/app_timers.zig`; **[observed]** `live-m16-resources` `timers=1` |

## Instruction set

- **AArch64 (ARMv8 / ARMv9-A)**. All guest code compiles for
  `aarch64-uefi`. **[observed]** — the EFI binary is AArch64 PE/COFF (see
  `zig build inspect` output).

## Firmware interface

- **UEFI 2.x**. The guest uses only the EFI System Table: the
  `SimpleTextOutput` protocol (`ConOut`) and, implicitly, the standard
  "return from entry point" exit convention.
- The standard removable-media ARM64 boot path is used:
  `\EFI\BOOT\BOOTAA64.EFI` on a FAT volume.
- **[inferred]** Firmware scans removable media for `BOOTAA64.EFI` when no
  explicit boot entry exists (both edk2 and Apple Virtualization implement
  this part of the UEFI spec).
- UEFI firmware: Apple's Virtualization EFI. Vendor and revision are
  unknown/undocumented by Apple. **[inferred]**

## Boot & handoff invariants

- The loader may place the kernel image at any free 4K-aligned address
  (`AllocatePages`, `EfiLoaderCode`) — the kernel must be
  position-independent. **[observed]**
- The loader cleans D-cache + invalidates I-cache over the image
  (`dc cvau` / `ic ivau` / `dsb` / `isb`) before the jump — without it the
  kernel never executes. **[observed]**
- **Image content sits at `base+0`** (the loader parses the header but
  does not load it into RAM): ELF VMA `V` lives at RAM `base+V`. This is the
  addressing invariant the kernel's PC-relative references depend on
  (`adr` rides the content offset inside the PC; `adrp`+`add` resolves only
  with content at `base+0`). ADR 0002. **[observed]**
- **PC-relative addressing alone does NOT cover every reference.** The
  toolchain (Zig 0.17 / lld) still emits **absolute, base-0 pointer tables**
  in initialized data for some code shapes — LLVM jump tables and
  outlined-function pointer arrays. Observed on the M43 U1 kernel
  (`--emit-relocs`, 2026-09-10): **70 `R_AARCH64_ABS64` in `.rodata` + 44 in
  `.data` = 114** absolute slots, with **0** in `.text` (all code refs are
  `ADR_PREL`/`ADD_ABS_LO12`/`CALL26`). Before issue #1042 the loader applied
  no relocations, so those slots were live base-0 values that faulted only
  when a path actually branched through them (the U1 silent death). The
  **KRN2** image now carries the loader-applied relocation table (see ADR
  0002); the build fails if an absolute relocation in loadable content
  cannot be represented. `--usb-msd` U1: `live-usb-bulk` 2/2. **[observed]**
  issue #1042.
- From milestone two on, the boot stub **never exits** (it keeps UEFI Boot
  Services forever) while the kernel proper calls `ExitBootServices` and may
  then touch MMU and device MMIO (ADR 0004). **[observed]**

## CPU / MMU (actionable facts)

- The kernel runs at EL1 with the MMU enabled and the firmware's identity
  map in effect at entry; it builds its own TTBR0_EL1 tables (4K granule,
  identity map for RAM/kernel/MMIO) and never uses firmware tables.
  **[inferred/design]**
- The guest implements the ARMv8.1+ TCR_EL1 layout (TG0 bits [15:14]=0b00 =
  4 KB granule, 36-bit IPS). **[observed]** claims 0010/0021.
- **The MMU takeover requires T0SZ=16 + `tlbi vmalle1` at the switch.**
  Under the legacy start level (T0SZ=25/W=39 over L0-rooted tables) every
  fresh TLB walk faults after the switch — the first post-switch BAR read
  hung (claims 0013/0018/0020); the start-level mismatch was isolated
  (claims 6460/7896) and the production fix landed (claim 1517). With the
  fix, **post-MMU virtio TX is [observed]** end to end on real VZ: the
  takeover banner + memory-map print + `virelai>` prompt land in
  `vm-serial.log`. The invalidation list in **ADR 0006**
  (`docs/decisions/0006-mmu-debt-boundary.md`) remains binding for every
  later re-mapping milestone.
- The identity map covers the low 4 GiB as Normal Write-Back and **every
  other address (including undeclared firmware MMIO)** as Device nGnRnE, so
  no post-switch access faults or hangs on an unmapped address.
  **[observed]** claim 0010.
- **Under a task's own TTBR0 root, an untouched user page still resolves for
  EL1.** The per-task root clones the identity overlay verbatim, so a user VA
  the process has not faulted in yet is a present-but-EL1-only entry
  (AP = 0b00) whose physical twin is the VA itself — Device-nGnRnE where that
  VA is not RAM. An EL1 store there **succeeds and is lost**: no EL0 access
  can ever observe it. Observed during #1391 with a temporary descriptor
  probe on GOSELF's read destinations in the mmap arena
  (`kind=3 ap=0 memattr=0 desc=0x4809a403`, physical == VA); the guest then
  read a correct length of zeros, because the page EL0 later got was a
  different, demand-filled one. The kernel's copy path now resolves every
  destination page in the process's own root before storing (ADR 0032), so
  the overlay is never a store target. **[observed]** #1391.
- **TTBR1 translation is incompatible with this kernel's tables on VZ**
  [measured, claim 5804]: 4 KiB-aligned tables fault at the first descent
  level in every configuration; 64 KiB-aligned tables resolve but Normal-WB
  data accesses abort (TLB conflict / external abort DFSC=0x21). The kernel
  therefore stays identity-mapped in TTBR0 (T0SZ=16, TTBR1=0) and every task
  gets a per-task TTBR0 root (EL1-only kernel overlay + own EL0 leaves;
  AP bits enforce EL1-only, UXN/PXN enforce W^X). Never re-adopt a TTBR1 KVA
  shadow without re-validating live.
- Firmware translation state at the switch: `SCTLR_EL1.M=1`,
  `TCR_EL1=0x18080351c` (T0SZ=28, TG0=4K, 36-bit IPS),
  `MAIR_EL1=0xffbb4400` (Attr0 Device-nGnRnE, Attr3 Normal WB),
  `TTBR1_EL1=0`. The firmware maps the virtio BAR window as a 1 GiB L1
  identity block (Device-nGnRnE, XN=1) and RAM as L3 pages Normal WB
  inner-shareable — attributes match the kernel's choices; the structural
  differences were granularity/XN/T0SZ/start-level. **[observed]** claim 0021.
- MAIR_EL1 uses two attributes: Device `nGnRnE` for MMIO and Normal
  Write-Back for RAM. IPS is read from `ID_AA64MMFR0_EL1` at runtime.
  **[inferred]**

## Serial console (actionable facts)

- **The declared MMIO windows are not the console**: `0x01000000..0x01010000`
  is Apple's EFI variable-store region (post-exit reads hang);
  `0x20050000..0x20051000` is a PL011-family PrimeCell UART that is Apple's
  internal EFI debug UART — writes produce zero bytes. **[observed]** claim 0013.
- The console is a **modern virtio-pci console**: bus 0 device 5,
  discovered by pre-exit ECAM (`0x40000000`, MCFG) enumeration. BAR0 is a
  64-bit BAR firmware-assigned above the 4 GiB identity blanket; the
  assignment varies across boots — map in place. **[observed]** claim 0013.
- **Config-space access discipline: aligned-u32 reads only** — VZ returns
  garbage for byte reads of config space; unaligned reads alignment-fault.
  Transport layout: common cfg @ BAR0+`0x0000`, ISR @ `+0x1000`, notify @
  `+0x4000` (multiplier 4), device cfg @ `+0x8000`; the 16-bit kick writes
  the queue index as the value. **[observed]** claims 0013/6684.
- Both queues are driven and observed (TX + RX): host input bytes reach the
  kernel's polled `readByte` end to end through queue 0. **[observed]** claim 6684.
- ACPI names no console: no SPCR/DBG2 in the XSDT; DSDT declares only
  `PCI0` + `efivars`. **[observed]** claim 0013.

## Interrupts & timer (actionable facts)

- **GICv3**: distributor `GICD` @ `0x10000000`, redistributor `GICR` @
  `0x10010000` (the boot CPU's active frame is the same address);
  `GICD_CTLR=0x50` (ARE_NS → v3). VZ's MADT does not yield a usable
  GICD/GICR tuple — use the live-probed fixed-layout fallback. **[observed]**
  claims 7948/9187.
- **SGI/PPI register accesses MUST target the SGI frame at `GICR+0x10000`**
  (e.g. `GICR_IGROUPR0=0x10080`, `ISENABLER0=0x10100`, `ICFGR1=0x10c04`):
  RD-frame offsets silently never enable PPIs — this was the observed timer
  delivery blocker. **[observed]** claim 9187 (+ Xcode 27 SDK audit,
  `artifacts/vz-irq-api-audit.txt`).
- The ARM generic timer runs at `CNTFRQ_EL0=24 MHz`; the GTDT supplies EL1
  physical-timer GSIV **30**, level-triggered. A real CNTP PPI 30 interrupt
  is delivered, acknowledged (`ICC_IAR1_EL1`), EOI'd (`ICC_EOIR1_EL1`), and
  re-armed — the production idle loop does not poll the comparator.
  **[observed]** claim 9187.
- The one-second timer PPI is the kernel's preemption clock (tick-driven
  round-robin scheduler). **[observed]** claim 5275.
- **EL1 virtual sampling timer (CNTV, PPI 27)**: an active slot-82 session
  arms CNTV at 100 Hz on both vCPUs, independently of the 1 Hz CNTP clock.
  **[observed]** #2004's counter-timed 10 s IRQ-only probe:
  core 0 **99.499907 Hz**, core 1 **99.499983 Hz** (995 acknowledged/EOI'd
  IRQs each, zero polls, 24 MHz counter, 10 physical ticks each).
  Evidence: `artifacts/live-observe-*-timer-probe`; no poll fallback.
- Xcode 27's public Virtualization.framework SDK exposes no
  `VZGICConfiguration` or host interrupt-injection API (Hypervisor.framework
  separately exposes `hv_gic_create`/`hv_gic_set_spi`/`hv_gic_send_msi`);
  none is needed for the timer PPI path. **[observed]** claim 9187.
- Interrupts are masked at kernel entry (firmware behavior) and explicitly
  unmasked only after vectors, GIC, dispatcher, and timer are armed.

## Input (actionable facts)

- Screen-side input is **USB XHCI + HID, not virtio-input** — no 0x1052
  device exists on the bus. **[observed]** claim 3868.
- **The activation wall**: VZ only translates host input for its KEY window,
  and macOS 14+ refuses programmatic focus-stealing from a background
  process while another app holds focus. Synthesized keyboard keyDowns work
  only while the machine is idle; modifier chords never reach the HID
  report; **every synthesized pointer route fails** (five routes probed with
  responder tracing, claim 4769). Live proof routes: the class-C real-mouse
  gate (`tools/verify-pointer-manual.sh`) and the trust-self-gating CG gate
  (`tools/verify-live-pointer-cg.sh`). **[observed]** claims 0935/4993/4769.
- The input drain must run BEFORE the framebuffer present in the shell idle
  loop so a report is never starved behind a slow full-frame present.
  **[observed]** claim 6050.

## What milestone zero does NOT assume (and does not touch)

- No direct MMIO. No UART programming. No DMA. No interrupts. No GIC.
- No memory map assumptions beyond what the firmware provides.
- No timer services. (The "wait" in the boot application is a plain busy
  loop with no hardware access.)
- No platform clock, no RTC, no power management.
