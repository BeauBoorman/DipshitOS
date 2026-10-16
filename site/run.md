---
title: Running the VM
parent: getting-started
status: published
tags: [guides, vm]
---

# Running the VM

The VM is launched by a Swift launcher (`host/vm-runner`) built on Apple's
Virtualization.framework. There is no other host.

```bash
zig build run      # boot to the kernel's serial console; output -> artifacts/vm-serial.log
zig build console  # boot an interactive virelai> console over a live serial attachment
```

The launcher supports flag-gated device modes, all **off by default** so the
default VM stays byte-identical:

| Flag | Attaches |
|------|----------|
| `--console` | an interactive stdin/stdout serial console |
| `--display` / `--screen <path>` / `--screenshot-after` | the virtio-gpu device (1280×720 scanout) for the graphical terminal and window manager, with an optional screenshot dump after boot |
| `--input` | the USB keyboard + pointing devices (an Apple XHCI controller) |
| `--net` | the virtio-net device with a deterministic file-handle attachment |
| `--net-nat` | the virtio-net device with a NAT attachment (real outbound connectivity) |
| `--virtio-fs <host-dir>` | Apple's standard VirtioFS device for `/host`; explicit opt-in, does not change the boot default |
| `--data-disk <img>` | a second virtio-blk device named `virelai-vlfs`; a `mkfs.vlfs`-formatted image mounts read-only at `/disk` (M100b/c) |
| `--host-clipboard` | the bidirectional host↔guest clipboard lane over HMAC-signed `HOSTINT/` share files (M108b; rides `--cvc-file`) |

The launcher also carries the deterministic scripted-input, network
responder, host-share, and console seams the live gates use (`--script`, `--input-string`,
`--net-udp-respond`, `--net-dhcp-respond`, `--cvc-file <host-dir>`,
`--console-tcp <port>`, `--usb-msd <image>`, and so on). Those are test
harness surface, not something an end user typically drives by hand.

## What you should see

A successful `zig build run` ends with the kernel's banner in
`artifacts/vm-serial.log`:

```text
VirelaiOS - AArch64 firmware-assisted kernel monitor
Type 'help' before touching anything expensive.
virelai>
```

From there the interactive monitor serves the [[architecture|kernel]]'s
command surface — `help` lists the registry (78 commands as of the current
tree), from `mem` and `pages` through `exec`, `net`, `screen`, `dui`, and
`smp`.

<Aside kind="info">

**CLAIM / EVIDENCE.** The exact serial banner and terminal state are asserted
by the class B gate `zig build run` (claim 1517) and the live transcript gate
(claim 6684). See [[live-gates]].

</Aside>
