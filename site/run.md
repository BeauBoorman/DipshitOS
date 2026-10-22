---
title: Running the VM
parent: getting-started
status: published
tags: [guides, vm, reference]
---

# Running the VM

The VM is launched by a Swift launcher (`host/vm-runner`) built on
Apple's Virtualization.framework. There is no other host. This page is
the reference: how to build and boot, then the full flag catalog,
grouped by what each flag arms. The lifecycle the machine flags drive
is on [[machine]]; the remote doors are on [[remote]]; the host
integration lanes are on [[host-int]].

## Build and boot

```bash
zig build image                        # bake artifacts/disk.img (UEFI loader + KERNEL.BIN)
swift build --package-path host/vm-runner -c release   # the VMRunner binary
zig build run                          # boot to the serial log -> artifacts/vm-serial.log
zig build console                      # interactive virelai> console over live serial
just session                           # bundled windowed session: builds, seeds the share, opens the seat
just session --save-capable            #   ...riding virtio-fs so suspend/snapshot are armed
just session --resume                  #   ...continuing a suspended machine
just gate <id>                         # one class-B gate spec on real hardware
```

`zig build run` and `zig build console` build the image and runner for
you; `swift build` alone is what the fleet's runner path
(`host/vm-runner/.build/release/VMRunner`) expects. Everything below is
a `VMRunner` flag; usage is `VMRunner <disk-image> [serial-log]
[flags...]`, and every flag is **off by default** so the bare VM stays
byte-identical across runs.

## Boot & machine

The machine-lifecycle flags — the profile bundle, resume, self-update —
are described end to end on [[machine]]; this is the spelling table.

| Flag | Arms |
|------|------|
| `--profile <path>` | Boot from a `.virelaivm` bundle. An absent path is minted; an existing one must carry a readable `virelaivm/1` manifest. Member paths are defaults — explicit `--vars`/`--overlay-base`/`--data-disk`/`--cvc-file`/`--cpus` win |
| `--profile-init` | Mint/validate the `--profile` bundle and exit without booting |
| `--resume <path>` | Boot the profile's `saved-state/state.vzsave` instead of the boot image — the continuation of a ctl `suspend`. Requires an existing bundle; mutually exclusive with `--vz-restore` and `--profile-init` |
| `--apply-update` | Verify the signed staged set in `<share>/UPDATE/` and swap it in as the boot base image, retaining `<base>.prev`. "none staged" when empty — safe to carry |
| `--rollback-update` | Swap `<base>.prev` back over the base image |
| `--update-key <64-hex>` | Ed25519 public key pinning staged updates; overrides the profile's `config.updatePubkey` |
| `--data-disk <img>` | A second virtio-blk device (`virelai-vlfs`); a `mkfs.vlfs`-formatted image mounts at `/disk`. Created raw if absent |
| `--overlay-base <base.img>` | DiskImageKit stacked image: read-only base + a throwaway ASIF overlay per run |
| `--vars <path>` | Per-run EFI variable store |
| `--cpus <n>` | VCPU count, 1–8 (default 2) |
| `--memory-mib <n>` | Guest RAM, 64–2048 MiB (default 512) |
| `--timeout <s>` | Run bound in seconds; `0` runs until Ctrl-C |
| `--expect <line>` | Exit once this line appears on serial (the evidence-gate mechanism) |
| `--terminal-marker <line>` | The second line the default evidence mode waits on |
| `--secure-boot` + `--secure-boot-pk`/`-db-efi`/`-db-hash` | Opt-in UEFI Secure Boot: fresh vars store, custom platform key, `db` entries — the firmware refuses an unpinned loader pre-exit |

## Save/restore probes

The raw `saveMachineStateTo`/`restoreMachineStateFrom` seam the
suspend and warm-checkpoint machinery sits on. These are gate
machinery — the headless probe is `--vz-restore`, a standalone mode
that accepts only its own flag family.

| Flag | Arms |
|------|------|
| `--vz-restore` | Standalone headless save/restore probe: pause → save → stop → restore → resume in one process |
| `--vz-restore-save <dir>` | Boot, park `state.vzsave` + `overlay.asif` + `machine-id.bin` into `<dir>`, exit — the checkpoint half |
| `--vz-restore-load <dir>` | A *new* process restores from `<dir>` instead of booting; the `--script*` family is legal here |
| `--vz-restore-settle <marker>` | The base boot's quiescent marker — the checkpoint point |
| `--vz-restore-witness <line>` | The serial line the post-restore guest must re-emit |
| `--vz-restore-verify-command`/`-output` | A guest command + expected reply proving liveness after restore |

## Display & capture

| Flag | Arms |
|------|------|
| `--display` | The virtio-gpu device *and* a live session window for the whole run |
| `--screen <path>` | The virtio-gpu device headless — the framebuffer is dumped to `<path>` (the evidence-capture path) |
| `--screenshot-after <marker>` | One framebuffer capture when `<marker>` appears on serial; writes into the `--screen` base name |
| `--screenshot-after-delay <s>` | Wait this long after the marker before grabbing — the composite lags a frame behind the state flip |
| `--host-capture-keys` | Arm the machine view's `capturesSystemKeys` at startup (the same `capture-keys` bus verb ⌥⌘K dispatches); needs `--screen`/`--display`/`--host-session` |
| `--snapshot-after <marker>` | Fire one guest-side framebuffer-snapshot request at the marker (repeatable; implies the queue-4 snapshot channel) |
| `--snapshot-out <base>` / `--snapshot-drain-timeout <s>` | Snapshot output path override / teardown drain bound while a stream is in flight |
| `--gpu3d-metal` | The opt-in custom-virtio Metal render device beside the native 2D scanout (SPIKE build only) |

## Input

| Flag | Arms |
|------|------|
| `--input` | USB keyboard + pointing devices over the guest's XHCI/HID stack |
| `--input-key <code>` | Synthesize one macOS virtual keycode |
| `--input-key-after <marker>` | Delay the key until the marker appears |
| `--input-string <text>` / `--input-string-after <marker>` | Type a literal string, optionally marker-timed |
| `--input-chords <spec>` / `--input-chords-after <marker>` / `--input-chords-delay <s>` | Chord trains for the seat's keyboard shortcuts, marker-anchored and paced |
| `--chords-view` | Route chords through the slow view-path pacing for launch-then-focus handoffs |
| `--pointer <x>,<y>[,c][;…]` | Synthesize pointer samples through the view |
| `--pointer-virtio <x>,<y>[,c][;…]` / `--pointer-virtio-after <marker>` | Pointer trains through the custom-virtio INPUT queue — headless-safe, no window or activation needed |
| `--via-virtio` | Inject keys through the custom-virtio input queue instead of synthesizing NSEvents (implies `--custom-virtio` + `--cvc-echo`) |
| `--debug-input` | Log bytes handed to the serial-input attachment |

## Storage & the share

The guest's user-visible filesystem is a macOS folder served over a
virtqueue — two transports, one `/host` API. See
[[host-int|host integration]] for what rides on top of it.

| Flag | Arms |
|------|------|
| `--cvc-file <host-dir>` | The custom-virtio host file channel (queue 5): `/host` backed by `<host-dir>`. Deepest flag — implies the whole custom-virtio queue shape. **Cannot be saved/restored** — see `--virtio-fs` |
| `--virtio-fs <host-dir>` | Apple's standard VirtioFS device, tag `virelaios`, same `/host` API — the *save-capable* transport (ADR 0036). Explicit opt-in; never the boot default |
| `--usb-msd <image>` | A USB mass-storage device over XHCI — bulk-only transport + minimal SCSI, read-only FAT view guest-side |
| `--host-write <relpath>` + `--host-write-content <text>` + `--host-write-after <marker>` | One marker-anchored host-side share mutation — the test-choreography seam the change-feed gates use |

## Networking

One network device per guest: `--net`, `--net-nat`, `--net-bridged`,
and `--net-vmnet` are mutually exclusive attachments. The responder
family all requires `--net` — they are deterministic peers inside the
capture thread, and the whole family is harness surface, not something
a user drives by hand.

| Flag | Arms |
|------|------|
| `--net <capture-file>` | virtio-net with a file-handle attachment; guest TX frames captured byte-exactly to `<capture-file>`. Fixed guest MAC `02:00:00:00:00:01` |
| `--net-nat` | virtio-net with a real `VZNATNetworkDeviceAttachment` — outbound NAT to outside networks. No port-forward exists inbound |
| `--net-bridged <iface>` | A `VZBridgedNetworkDeviceAttachment` on the named interface — the guest sits on the host's LAN (restricted entitlement) |
| `--net-vmnet` [+ `--net-vmnet-subnet <a.b.c.d>/<len>`] | A `VZVmnetNetworkDeviceAttachment` on a shared-mode vmnet logical network; the subnet flag pins its IPv4 /24 |
| `--net-inject <file>` [+ `--net-inject-after <text>`] | The host→guest RX direction: the file's bytes delivered once at the marker |
| `--net-arp-respond <ip>` / `--net-icmp-respond <ip>` / `--net-udp-respond <ip>:<port>` | Deterministic ARP / echo / UDP-echo answerers |
| `--net-dns-respond <ip>:<port>` [+ `-wrong-question` / `-truncate`] | A fixed DNS answerer, plus the malformed-reply negatives |
| `--net-dhcp-respond <lease-ip>[:<secs>]` [+ `-norenew` / `-norebind`] | A deterministic DHCP server with a pinned lease; the norenew/norebind flags refuse the lifecycle legs |
| `--net-sntp-respond <ip>[:<port>]` + `--net-sntp-skew <s>` | A small RFC 4330 SNTP server; the skew proves the guest clock actually moved |
| `--net-tcp-respond <ip>:<port>[:handshake|packet|ssh|relay|options]` | A deterministic TCP peer — echo server, black-hole handshake, paced payload, a minimal SSH-2 server, a byte-forwarding relay to a real upstream, or an option-carrying peer. Modifiers: `-payload`/`-chunk`, `-ssh-hostkey`/`-ssh-userkey`/`-ssh-tamper-mac`/`-ssh-marker`/`-ssh-exit`, `-relay` |
| `--net-tcp-connect <ip>:<port>[:<payload-file>|ssh]` | The reverse direction — the host initiates one inbound connection to a guest listener. Modifiers: `-after`/`-close-after`, `-secret`/`-mac`, `-stream <exe>` + `-stream-arg` + `-intruder`, `-ssh-exec`/`-ssh-user`/`-ssh-pty`/`-ssh-keys`/`-ssh-session-file` |
| `--net-ra-respond` / `--net-ndp-respond` / `--net-icmp6-respond` | The IPv6 hermetic responders: router advertisement, neighbor answer, echo reply |
| `--net-udp6-respond [<v6>]:<port>` / `--net-tcp6-respond [<v6>]:<port>` | The v6 transport responders — the UDP echo and TCP handshake/echo shapes over the fixed 40-byte header |

## Remote & console

The doors [[remote]] describes.

| Flag | Arms |
|------|------|
| `--console` | An interactive stdin/stdout serial console (guest output teed to terminal *and* log) |
| `--console-tcp [host:]port[:secret]` | The hardened serial bridge on TCP — single client, busy refusal, auth deadline, line bound, stall drop, mid-line `^C` cancel |
| `--console-tcp-secret-file <path>` | Read the bridge secret from a file's first line — never argv (mutually exclusive with the inline `:secret`) |
| `--nvram-console <file>` | Reconstruct the post-exit console stream from the EFI variable store (nvram-console builds only) |
| `--cvc-console-file <path>` | Structured console: capture every queue-1 guest log line to `<path>` (implies `--custom-virtio`) |
| `--vsock` [+ `--vsock-port <n>`] | Apple's `VZVirtioSocketDevice` plus a host listener (default port 1208) that accepts and logs guest connects |
| `--vsock-ctl` [+ `--vsock-ctl-port <n>`] | The `virelai-ctl/1` endpoint (default port 1209) — the HMAC-challenged suspend/snapshot/restore/profile-info channel. Requires `--vsock` and the share's `vsock-ctl` row |
| `--dump-marker <file>` | Save the kernel's M2_* takeover-marker ladder from the EFI variable store |

## Host integration

The ADR 0051 lanes — all *modifiers on `--cvc-file`*, all requiring the
share's `host-int` SECRETS.TXT row, all default-off. See [[host-int]].

| Flag | Arms |
|------|------|
| `--host-clipboard` | Bidirectional clipboard over signed `HOSTINT/` records; `.general` pasteboard |
| `--host-pasteboard <name>` | Retarget the clipboard lane to `NSPasteboard(name:)` — mandatory for gates |
| `--host-clip-in <text>` / `-after <marker>` / `-file` / `-mime` | Test hooks: inject a host-side paste, marker-timed |
| `--host-drop` | The `.fileURL` drop target + `INBOX/` + signed `DROP` notices; needs a display path |
| `--host-drop-file <path>` / `--host-drop-after <marker>` | Test hooks: feed files through the real drop handler, marker-timed (repeatable) |
| `--host-notify` | Seat toasts out as `NOTIFY_OUT` records → macOS banners (bundle) or `no_bundle` drops (bare runner) |
| `--host-outbox` [+ `--host-outbox-dir <path>`] | The guest→host export lane; default landing `~/Downloads` |
| `--host-cmd-after <marker>:<verb>` | Dispatch a HostCommand-bus verb at the marker — the same seam every menu item uses; repeatable, `verb@<arg>` and `vm<k>:` qualifying |
| `--host-serial-send <line>` | Arm the inspector's input line for a `send-serial` dispatch |
| `--host-session` | The bundled session front door: windowed, close/Quit stops the VM, failures stay visible |

`send-file` is a **bus verb**, not an argv flag — it is "Send File to
INBOX…" in the Integration menu, and headless runs dispatch it through
`--host-cmd-after <marker>:send-file` (or stage its source with
`--host-drop-file`).

## Sound

| Flag | Arms |
|------|------|
| `--sound` | One virtio-snd device with a PCM output stream to the host speakers |
| `--sound-in` | *(on the separate `SoundInProbe` binary, not `VMRunner`)* — the input-stream observation vehicle; a `VZVirtioSoundDevice` with a host-mic input stream, driven by `live-sound-in-probe` |

## Scripting

The fleet's driving surface — all harness, all off by default.

| Flag | Arms |
|------|------|
| `--script <file>` / `--script-after <text>` | Forward a script file into the console once a marker appears |
| `--script-expect <text>` / `--script-expect-tail <s>` | The expected transcript tail + how long to hold the VM afterward |
| `--script2`/`--script3` + `-after`/`-delay` | Second and third scripted phases, each gated on its own marker |
| `--pointer-request-trust` / `--debug-input` | Input-side diagnostics and trust requests |

Helper tools around the runner carry their own flags rather than
runner argv: `tools/rfb-tape.sh --type-password` answers Screen
Sharing's password sheet for the RFB demo (see [[remote]]), and the
gate client `vgate-client.py --send-file` ships a fixture through a
during-run connection.

## What you should see

A successful `zig build run` ends with the kernel's banner in
`artifacts/vm-serial.log`:

```text
VirelaiOS - AArch64 firmware-assisted kernel monitor
Type 'help' before touching anything expensive.
virelai>
```

From there the interactive monitor serves the [[architecture|kernel]]'s
command surface — `help` lists the registry, from `mem` and `pages`
through `exec`, `net`, `screen`, `dui`, `smp`, and `vsock`.

<Aside kind="info">

**CLAIM / EVIDENCE.** The exact serial banner and terminal state are
asserted by the class-B `zig build run` gate (claim 1517) and the live
transcript gate (claim 6684). See [[live-gates]].

</Aside>
