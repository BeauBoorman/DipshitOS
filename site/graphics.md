---
title: Graphics
parent: capabilities
status: published
tags: [capabilities, graphics]
---

# Graphics

The machine boots to a graphical desktop. Two paths produce pixels: the
**native virtio-gpu 2D scanout**, which everything uses, and an **opt-in
custom-virtio GPU device** that renders through the host's Metal stack —
first for bounded 3D, then for compute. On top of the scanout sit the
seat's compositing model, a TrueType typography stack, and a shared
primitives library every app draws with.

## The 2D scanout

`--display` attaches `VZVirtioGraphicsDeviceConfiguration` — a modern
virtio-gpu (`0x1af4:0x1050`, spec version 1.2, which matters: the 24-byte
`display_one` reply shape is the 1.2 form, and the 1.0 shape wedges the
queue). `virtio_gpu.zig` drives the spec 2D command pipeline over the
single control queue, one command outstanding at a time:

```
GET_DISPLAY_INFO → RESOURCE_CREATE_2D → RESOURCE_ATTACH_BACKING
→ SET_SCANOUT → TRANSFER_TO_HOST_2D → RESOURCE_FLUSH
```

The framebuffer is a fixed 4 KiB-aligned BSS array — 1280×720 in
B8G8R8X8, about 3.7 MiB, no heap. Two hardware facts shape everything
that paints: the scanout treats a zero alpha/X byte as **transparent**
(so the desktop always writes opaque pixels), and presents are
explicit — a paint is a `TRANSFER_TO_HOST_2D` plus a `FLUSH`, batched
per dirty region rather than per pixel.

The Road Pops terminal owns scanout by default: every byte still goes
to serial first (the evidence seam), and the same prompt and replies
are painted on screen, one present per output batch.

## The seat compositing model

Seam B is the ownership rule the whole desktop lives by: **apps own
their pixel buffers; the seat composes one present.** A window's
surface is a shared-anonymous mapping the app writes into directly —
`user/go/draw`'s `WindowCanvas` binds those pages at scanout stride,
reflowing on `WIN_RESIZE` without remapping. The registered seat
(GOTABWM by default, TABWM as the `settings set wm tabwm` fallback)
collects dirty windows and emits one composited frame per tick.

The kernel's own Driving Award layer is deliberately thin under this
model: a bounded window registry, z-order, focus, hit-testing, and the
chrome the seat draws. That split is what let the desktop policy move
to userland — window management is a process, not kernel code.

## Typography

Text is vector, not bitmap. `user/go/ttf` is a registry-driven
TrueType engine: `image/fonts/fonts.txt` (staged as `/host/FONTS.TXT`)
declares faces with `role=ui|mono|serif|symbol`, cascade order,
weight, and style — Inter for UI, Fira Code for mono, a serif face,
and symbol faces at the tail of every cascade. Coverage is never
declared in the manifest; the registry reads each face's `cmap`, so a
face cannot lie about what it holds. A rune nothing covers paints the
primary's `.notdef` and is counted, never a silent hole — the CJK
coverage the web renderer reaches through `NOTOCJK` rides that
mechanism.

Faces rasterize to anti-aliased BGRA glyphs blended at paint into the
scanout's `0xAARRGGBB` space, with proportional metrics rather than a
cell grid — the terminal is the exception, keeping its bounded grid for
vt semantics. A single `font_size` key (`small`/`medium`/`large`) moves
both ladders at once: the proportional text raster (11/13/17 px) and
the terminal grid's rasterized cells (7×13 / 8×16 / 10×21), reflowing
bound screens and notifying owners through `WIN_RESIZE`. The
`live-typography`, `live-font-sizes`, `live-web-ttf`, and
`live-term-depth` gates pin each rung against decoded scanout pixels.

## UI primitives v2

`user/go/draw` is the shared raster library (contract v2 in
`docs/ui-primitives.md`). Its guarantees:

- **Buffer model.** `BufferCanvas` over a caller-owned `[]u32`;
  `BytesCanvas`/`WindowCanvas` over raw and Seam-B mapped surfaces;
  `FillerCanvas` as the honest degrade path — shadows, gradients, and
  AA text simply don't appear where only fill-rects exist, and nothing
  pretends they did.
- **AA shape renderer.** Rounded rects, borders, arcs, a clip stack,
  drop shadows, vertical gradients, scaled blits — linear-light
  blending, not a gamma-naive lerp.
- **The chrome inventory.** Twenty private-use-area glyphs (batch 1)
  plus batch 2 — the close/minimize/zoom dots, chevrons, resize grip —
  pinned by golden tests so a glyph can't silently shift a pixel.
- **Design tokens.** Colors come from `theme.Tokens`, never literal
  hex in apps: `Surface` chrome plates, `ChromeBg`/`Gutter` recesses,
  the `BtnIdle→Hover→Pressed` ramp, `Accent` focus rings. `theme=custom`
  resolves the palette keys at paint; an unknown name is refused.

Golden tests compare whole composites — seat rail, appkit dialogs, the
calc chrome — so a regression in any primitive fails mechanically, not
aesthetically. `go-calc`'s run-05 chrome leg and the M104 composite
goldens are the standing pins.

## The custom-virtio GPU device

`--gpu3d-metal` attaches a second private device (`0x1af4:0x1083`)
that speaks virtio-gpu CONTROL envelopes carrying the private `VIR1`
capset. It is opt-in and additive: the 2D scanout keeps its own BAR and
rings, and without the flag the VM is byte-identical.

The render path is a routed pipeline:

```
GPUTRIANGLE.ELF → WM_RPC kind-17 → the seat
→ kernel broker (slot-65 cmd-22, a frozen 64-byte descriptor)
→ gpu3d_submit → the device → the host Metal renderer
→ PUBLISH: CPU-composited into the window's ordinary pixel store
```

Seven broker ops — CREATE, CLEAR, TRIANGLE, PRESENT, POLL, PUBLISH,
CLOSE — over generation-bearing handles; window, owner, geometry, and
generation are re-verified on every call, and a close/exit invalidates
the handle *before* the bounded drain runs. PUBLISH itself draws
nothing GPU-side: it copies the staged readback into the app's own
surface, which is why a forged-frame or wrong-session attempt is a
named refusal, not a pixel leak. `GPUTRIANGLE.ELF`'s receipt vocabulary
— `submitted`, `completed`, `published` — is what `live-gpu3d` counts.

## GPU compute

The same device opens as a compute device when the host backend
advertises the second capset, `VIC1` (a 32-byte profile: kernels mask,
16 MiB buffer bound, 4096-dim ceiling, `ready` bit). ADR 0053's shape
is deliberately small: one new envelope command `COMPUTE_SUBMIT`, one
syscall slot 90 `sys_gpucomp`, and a three-kernel ABI — **GEMM**
(f16 in, f32 accumulate), **SOFTMAX** (row-wise f32), and **DEQUANT**
(i8-symmetric and u4-packed-asymmetric weight formats). Everything
else — a fourth kernel, strided tensors, an f32 GEMM — is a named
refusal, not an error to negotiate.

The buffer model keeps the app out of DMA: the kernel broker allocates
from an 8 MiB I/O pool (activations, logits) plus a shared 4 MiB
weight-staging window, so a ≤64 MiB model streams through the window
in chunks and `SEAL` drops its guest-side backing to zero — the Metal
buffer is already authoritative host-side. One compute session exists
system-wide, owner-keyed and generation-bearing; the whole feature
costs ≤ ~44 MiB of the 512 MiB guest. The model licence is an
acceptance criterion, not a footnote: `GOINFER` runs the owner-approved
Apache-2.0 SmolLM2-135M-Instruct, answering in-guest on the real Metal
path, and `GOTOP`'s gpu tab shows the broker's real counters — busy,
queued, sessions, per-kernel microseconds, submits/completed/refusals/
timeouts — read through the descriptor-free STATS op.

<Aside kind="info">

**LIVE-GATED.** `live-gpu3d` is the standing gate: pixel proofs for the
render legs, the refusal battery, forged-frame and wrong-fence
negatives, the compute probes, and GOINFER's real-model answer —
13 legs, K=5 on the reference host. `go-top` leg 06 pins the gpu tab's
counters.
</Aside>

<Aside kind="warning">

**LIMITATION.** Single display, no multi-monitor. The default desktop is
2D; the Metal device is opt-in, absent without `--gpu3d-metal`, and
unsaveable (custom-virtio is refused by `validateSaveRestoreSupport`).
Compute is one session, three kernels, no general shader path — by
design.
</Aside>
