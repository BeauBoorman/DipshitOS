# ADR 0053: The GPU compute surface — one queue, a three-kernel ABI, bounded buffers

- Date: 2026-10-16
- Status: **Accepted** — shipped by M111b (M111 closed, index #2384):
  the GPU compute surface is live (`kernel/src/syscall.zig:201,1198`);
  this ADR is the card (#2408), and the split in §D8 is the arc.
- Card: **#2408** (M111a, arc index #2384) — card 1 of 5. The surface
  M111b implements and M111e accepts.
- Related: ADR 0007 (syscall ABI — this ADR names one new slot, §D5),
  ADR 0024 (trust baseline), ADR 0043 (observability — counters are a
  syscall row, not a log), ADR 0047 (`sys_procs` versioned-row precedent
  for STATS), M102 (index #2160 — the VIR1 render device this extends).

> M102's `1af4:1083` device is a render device: the guest paints a
> bounded triangle into a Metal render target and the CPU composites the
> readback. M111 opens the same device as a *compute* device. The
> decision is deliberately boring: **one control queue, one new private
> command (`COMPUTE_SUBMIT`), one new capset (`VIC1`) advertising a
> curated three-kernel library — GEMM, SOFTMAX, DEQUANT — as the entire
> shader language, and one new syscall slot (90) with owner-keyed,
> generation-bearing handles.** Every byte of VIR1, every render
> refusal and every M102 test stays byte-identical; a host that cannot
> run Metal compute advertises `VIC1 ready=0` and the guest answers
> `ENXIO`. The proof is a tiny quantized model answering in-guest on
> the GPU — and the model's licence is an acceptance criterion, not a
> footnote.

## Mission

Pin, before implementation: the wire surface (capset, command,
descriptor), the queue and fence semantics, the kernel library v1 as an
ABI (shapes, dtypes, bounds), the buffer model and who allocates, the
counters GOTOP displays, the memory budget against the guest's
**512 MiB**, the model licence gate, and the file-level Touches for
M111b–e. Out of scope: any code, any fourth kernel, and any general
shader path.

## Grounding (observed in tree `d0a14b6d`, 2026-10-16)

**Observed** means checked in the tree; **inferred** means reasoning
only.

- **The device is split three ways (observed).** Guest kernel broker
  `kernel/src/gpu3d_{wire,device,submit,stream,broker}.zig`; app wire +
  client `user/go/gpu3d/{wire,api}.go` riding WM_RPC kind 17 and the
  slot-65 cmd-22 descriptor (`user/go/vi/gpu3d.go`); host device core +
  Metal backend `host/vm-runner/Sources/VMGPU3D/{Wire,Device,
  VirglDecoder,MetalRenderer,Backend,RunnerConfiguration}.swift`.
  Compute touches all three: the kernel descriptor is frozen in the
  kernel wire file AND `Wire.swift`, the dispatch in `Device.swift`,
  the pipelines in a new Metal compute backend.
- **One queue, one outstanding request (observed).** The device has a
  single split control ring (`queue_size = 8`, `gpu3d_device.zig:76-78`)
  and refuses a second deferred request with `deviceBusy`
  (`Device.swift:353`: `guard pending == nil else { return .refuse(.deviceBusy) }`).
  Compute submissions ride the same ring and the same rule — there is no
  second in-flight slot to give them.
- **Completion is the fence-matched response (observed).** Every command
  carries `VIRTIO_GPU_FLAG_FENCE`; the device holds a deferred element
  until the backend reports that request's full u64 fence
  (`Device.swift` pending/`noteFenceCompleted`; the 5 ms fence pump at
  `Device.swift:104`). Guest-side, `completion_is_fenced_response`
  (`gpu3d_submit.zig:116`) is the revert-fails seam — consumption is
  never completion. A timed-out exchange parks the chain and poisons the
  session (quarantine + bounded drain, `gpu3d_submit.zig` `open`/`drain`).
- **Contexts are a device-wide pool of 2 (observed).** VIR1 advertises
  `contexts=2`; `Device.swift:199` refuses a third with
  `contextSlotsFull`. Resources are created device-globally but attached
  per-context; M102 derives global ids as `res_color = 2·ctx − 1`,
  `res_vbo = 2·ctx` (`gpu3d_stream.zig:26,126-129`).
- **Buffers already exist (observed).** The vbo path creates a
  `PIPE_BUFFER` resource (`target_buffer`, format 0, `width` = byte
  size), attaches pinned kernel BSS backing (`RESOURCE_ATTACH_BACKING`),
  uploads with `TRANSFER_TO_HOST_3D` as a 1-D box (`{x=off, w=len, h=1,
  d=1}` + backing `offset`, `gpu3d_submit.zig:188-207,437`), and reads
  back with `TRANSFER_FROM_HOST_3D`. `RESOURCE_DETACH_BACKING` is already
  decoded by all three layers (`Wire.swift:163`,
  `gpu3d_submit.zig:47,178`). Compute buffers reuse every one of these
  verbs unchanged.
- **The Metal side keeps its own copy (observed).** `MetalRenderer`
  transfers through the `GPU3DMemory` seam into `MTLTexture`/`MTLBuffer`
  objects it retains (`MetalRenderer.swift:81-88`); guest backing is the
  DMA window, not the storage. After upload the device-side copy is
  authoritative — a detached buffer remains valid for kernels.
- **Guest RAM is 512 MiB (observed).**
  `host/vm-runner/Sources/VMRunner/main.swift` computes
  `config.memorySize = UInt64(memoryMiB) * 1024 * 1024` with the M129a
  (#2610) compiled default `memoryMiB = 512` (the `--memory-mib` flag
  overrides it per run).
- **The syscall table ends at slot 87 (observed).**
  `kernel/src/syscall_abi.zig:154` is `row(87, "sys_getpid", .{})`;
  `slot_count = 128`. ADR 0054 reserved slots 88/89 for its grant-admin and audit rows; slot 90 is the next free row for this surface (amended post-merge — this ADR originally said 88 before 0054 landed). Slot 65 is
  seat-gated (`EACCES` non-WM) and cmd 22's descriptor is window-bound
  (`window_id` required on every op, ADR 0007 M102d1 amendment).
- **Counters are a syscall row (observed).** `sys_procs` (slot 7) and
  `sys_net_stats` (slot 62) copy a versioned/fixed struct out through
  uaccess to any caller; GOTOP is a tabbed Go app (`user/go/top/`, procs
  + netview tabs) that already renders them.
- **`num_capsets` is a config word (observed).** `deviceConfigBytes`
  (`Wire.swift:143-148`) advertises `num_capsets = 1`;
  `GET_CAPSET_INFO` answers only index 0 today (`capsetIndex = 0`,
  `Wire.swift:110`).
- **`--gpu3d-metal` wires the whole attachment inside VMGPU3D
  (observed).** Flag parsing, backend construction and the SPIKE gate
  live in `VMGPU3D/RunnerConfiguration.swift`; `main.swift` treats the
  flag as a bare token (`main.swift:1025`). VIC1 rides the same flag —
  no new runner flag is needed.
- **Eight legs pin the render contract (observed).**
  `tools/gate/specs/live-gpu3d.spec` — pixel proofs, refusal battery,
  forged-frame, wrong-fence, stall/drain — none of which compute may
  regress.

## D1 — Discovery: a second capset, `VIC1`

The device advertises a second capability profile beside VIR1. VIR1
(index 0, version 1, 32-byte payload) stays byte-frozen; every M102
assertion keeps passing on a device that also speaks compute.

- `deviceConfigBytes.num_capsets` becomes **2** when the device is
  assembled with a compute-capable backend (the same `--gpu3d-metal`
  flag; `RunnerConfiguration.swift` owns the assembly).
- `GET_CAPSET_INFO` index **1** reports capset id **`VIC1` =
  `0x56494331`** ("VIC1" LE), `max_version` 1, `max_size` 32.
- `GET_CAPSET` (capset `VIC1`, version 1) returns eight LE u32 words —
  the pinned compute profile:

  | word | name | pinned value |
  |-----:|------|-------------:|
  | 0 | `version` | 1 |
  | 1 | `max_buffers_per_ctx` | 16 |
  | 2 | `max_buffer_bytes` | 16777216 (16 MiB) |
  | 3 | `kernels_mask` | 7 (bit0 GEMM, bit1 SOFTMAX, bit2 DEQUANT) |
  | 4 | `max_dim` | 4096 (per-dimension bound; SOFTMAX adds a wider column bound, §D3) |
  | 5 | `max_elems` | 16777216 (2²⁴, the elementwise bound) |
  | 6 | `reserved` | 0 |
  | 7 | `ready` | 0 \| 1 — 0 means "device present, no compute backend" |

- Payload length stays pinned at 32: a reply of any other size is a
  different profile, refused — same rule as `parse_vir1`.
- A device without the capset (older host, `--gpu3d-metal` absent,
  compute backend failed to build) advertises `num_capsets` 1 / index 1
  unanswered or `ready=0`; guest-side every compute op answers `ENXIO`.
- Contexts are **not** extended: the same device-wide pool of 2 covers
  render and compute contexts. A compute session takes one `CTX_CREATE`;
  render and one compute session coexist; a third live context of any
  kind is `contextSlotsFull` → `ENOSPC`, as today.

## D2 — The queue model and the named refusals

**One queue.** Compute rides the same control ring (queue 0), the same
24-byte `virtio_gpu_ctrl_hdr` envelope, the same mandatory FENCE flag,
and the same **at-most-one-in-flight** rule — a compute submission is
just a new envelope type the dispatcher validates. There is no compute
queue, no concurrent submission, and no reordering: the device completes
requests in post order.

**Submit/finish/fence semantics.** `COMPUTE_SUBMIT` is a fenced deferred
request, identical in lifecycle to `SUBMIT_3D`:

1. The guest posts hdr + 64-byte kernel descriptor (§D3); the device
   requires FENCE (`fenceRequired`) and a free pending slot (`deviceBusy`).
2. The backend encodes the Metal compute command buffer and returns
   `.deferred`; the device holds the element.
3. The Metal completion handler runs → `gpu3dPoll()` reports **this
   request's fence** → the device writes the OK response and returns the
   element. Queue consumption is never completion; the fence is read
   from the held element, same as render.
4. The guest's bounded exchange returns only on the fence-matched
   response; a timeout parks the chain and poisons the compute session —
   the same quarantine, drain and next-open retry rules M102 pins.

`RUN` is **synchronous from the caller's side**: the syscall returns
when the fenced response lands or the named refusal fires. There is no
async submit in v1 — the app's loop is its batching, and one outstanding
device request means concurrency would buy nothing.

**Named refusals** (device-side names extend the `GPU3DRefusal` family;
wire-mapped onto the existing virtio-gpu error responses; guest errno in
parentheses):

- `unknownKernel` — `kernel_id` not in `kernels_mask` →
  `ERR_INVALID_PARAMETER` (`EINVAL`).
- `badKernelShape` — a dimension outside the kernel's §D3 bounds →
  `ERR_INVALID_PARAMETER` (`EINVAL`).
- `badKernelBinding` — a buffer slot names no attached buffer of this
  context, or the declared tensor overruns the buffer →
  `ERR_INVALID_RESOURCE_ID` (`EINVAL`).
- `reservedBits` / `truncatedRequest` / `trailingBytes` — the existing
  envelope hygiene refusals, unchanged (`EINVAL`/`EIO`).
- `invalidContext` / `contextSlotsFull` — ctx rules unchanged
  (`EBADF`/`ENOSPC`).
- `deviceBusy` — a deferred request is already in flight (`EAGAIN`; the
  caller retries, never queues).
- `backendUnavailable` (`VIC1 ready=0`) and `backendRefused` →
  `ENXIO`/`EIO`.
- `timeout` — exchange deadline → `ETIMEDOUT`, session poisoned → all
  later ops `ENOENT`.
- Wire response shape: `COMPUTE_SUBMIT` answers `RESP_OK_NODATA` on the
  deferred fence (24 bytes, no timing payload in v1 — kernel time is
  measured guest-side, §D6).

## D3 — Kernel library v1: the ABI

One new private envelope command inside the same header:

- **`COMPUTE_SUBMIT` = `0x0400`** (outside the standard virtio-gpu range
  `0x0100`–`0x0301` and outside `unsupportedTypes`; a stock device calls
  it `unknownCommand`, ours validates it). Request = hdr + **64-byte
  kernel descriptor** = 88 bytes. `COMPUTE_SUBMIT` is a ctx command —
  `ctx_id` names the compute session's context.

The kernel descriptor (64 bytes, LE — the same bytes on the wire and
inside the slot-90 `RUN` descriptor):

| off | size | field | rule |
|----:|-----:|-------|------|
| 0 | 4 | `kernel_id` | 1 GEMM, 2 SOFTMAX, 3 DEQUANT; else `unknownKernel` |
| 4 | 4 | `flags` | per-kernel bits below; undefined bits must be 0 |
| 8 | 4 | `d0` | dim 0 (see kernel) |
| 12 | 4 | `d1` | dim 1 |
| 16 | 4 | `d2` | dim 2 / 0 |
| 20 | 4 | `aux` | per-kernel (DEQUANT `fmt`); else 0 |
| 24 | 32 | `bufs[4]` | four `{u32 buf, u32 byte_off}` slots — on the wire `buf` is the resource id; inside the slot-90 desc it is the caller's buffer **handle** and the broker translates |
| 56 | 8 | `reserved` | always 0 |

A buf slot of `{0, 0}` is "absent" — slot 3 must be absent when the
kernel's flag does not name it, and present when it does.

**The kernels** (row-major, contiguous, no stride fields in v1; the
caller packs the data):

| id | kernel | buffers | dims / aux | bounds |
|---:|--------|---------|------------|--------|
| 1 | **GEMM** — `C[M,N] = A[M,K]·B[K,N]` (+bias) | buf0 A f16, buf1 B f16, buf2 C f16 out; buf3 bias f16[N] iff `flags` bit0; `flags` bit1 = B is `[N,K]` (transposed) | d0=M, d1=N, d2=K | M,N,K ∈ 1..`max_dim` (4096); M·N ≤ 2²²; accumulate f32, output f16 |
| 2 | **SOFTMAX** — row-wise | buf0 in f32, buf1 out f32 (`flags` bit0 required when in = out) | d0=rows, d1=cols | rows·cols ≤ 2²²; cols ∈ 2..49152 (covers a tiny-model vocab head) |
| 3 | **DEQUANT** — weights → f16 | buf0 packed q, buf1 scales f32[`groups`], buf2 zeros f32[`groups`] iff fmt 2 (absent for fmt 1), buf3 out f16[`n`] | d0=`n`, d1=`group_size` ∈ {32,64,128}; `aux` byte0 = `fmt`: 1 = i8 symmetric (`out=q·s`), 2 = u4 packed asymmetric (`out=(q4−z)·s`, 2 nibbles/byte, low nibble first) | n ≤ `max_elems` (2²⁴); `groups` = ⌈n/G⌉ ≤ 2¹⁹ |

Everything else — a fourth kernel, a general shader, a strided tensor,
an f32 GEMM, a fused anything — is a named refusal in v1, not an error
to negotiate. RMSNorm, RoPE, embedding gather, residual adds and the
sampling loop run on the guest CPU in the app: on a tiny model they are
not the bottleneck, and keeping them off the wire keeps the library
three entries long.

## D4 — The buffer model

**Who allocates: the kernel broker, never the app.** Compute buffers
live in kernel-owned pinned backing, exactly like the render path's BSS
pools — no DMA into application pages, no caller-supplied physical
address anywhere in the contract. Two classes, chosen at `BUF_ALLOC`:

- **I/O buffers** (activations, inputs, logits): dedicated pinned pages
  from the broker's **8 MiB I/O pool**, attached with
  `RESOURCE_ATTACH_BACKING`; `WRITE`/`READ` move bytes between the app's
  user pages and the backing through checked uaccess, then a fenced
  `TRANSFER_TO/FROM_HOST_3D` keeps the device copy honest.
- **Weight buffers** (the model): created at full declared size
  (≤ `max_buffer_bytes`) but backed only by the shared **4 MiB staging
  window** — `WRITE` copies ≤ 4 MiB into staging and issues a chunked
  `TRANSFER_TO_HOST_3D` (`box.x = buf_off`), so a ≤ 64 MiB model streams
  through a 4 MiB window. `SEAL` issues `RESOURCE_DETACH_BACKING` and
  frees the share: the Metal buffer is already authoritative host-side,
  so sealed weights cost **zero** resident guest RAM. `WRITE`/`READ` on
  a sealed buffer refuse `EINVAL`; kernel binds are unaffected.

Resource ids stay device-global and non-colliding: compute buffer slot
`i` (1..16) of context `c` is `res_id = c·256 + i` — disjoint from
render's `2c−1`/`2c` ids and from every other ctx.

Session and buffer handles are generation-bearing and owner-keyed (the
`socket_core` pattern): `session = gen:48 | ctx:16`, `buffer = gen:32 |
slot:8 | ctx:16`; a stale, dead or foreign handle is `EBADF`; the
owning pid is recorded at `OPEN` and checked at every op, so a handle
smuggled to another process is useless. Owner exit revokes the session:
handles invalidated first (generation bump), then the bounded drain —
identical revocation order to cmd-22's.

## D5 — The guest ABI: new slot 90 `sys_gpucomp`

**Why a new slot and not slot-65 cmd 23.** Slot 65 is the seat's
exclusive surface and cmd 22's descriptor is window-bound because render
publishes into other principals' pixels — the seat is the choke point
for a cross-window write. Compute writes nothing to anyone else's
state: inputs and outputs stay inside the calling process's own
buffers. Routing ≤ 4 MiB weight chunks through the seat would put the
WM on the data path for zero trust benefit, and the consumers here are
ordinary apps (GOINFER, GOTOP), not the seat. The established pattern
for a process-owned kernel resource is an owner-keyed handle table on a
normal slot — `sys_socket` (80), owned UDP (84–86), the file slots —
and compute takes the next free row:

| 90 | `sys_gpucomp` | `gpucomp(op, a0, a1, a2, ptr, len) -> i64` | `a0..a2` reserved (0); `ptr` → **128-byte** compute descriptor, `len` = 128 exactly. `EFAULT` unreadable; `EINVAL` malformed; `EBADF` bad/stale handle; `ENOSPC` pool/context exhausted; `ENXIO` no VIC1 device or `ready=0`; `EAGAIN` device busy; `ETIMEDOUT` exchange deadline; `ENOENT` poisoned session; `EIO` device fault |

The descriptor (128 B LE — `len` is 128, never 64):

| off | size | field | rule |
|----:|-----:|-------|------|
| 0 | 4 | `op` | 1..9 below; 0 and ≥10 fail closed |
| 4 | 4 | `flags` | BUF_ALLOC bit0 = `WEIGHT`; else 0 |
| 8 | 8 | `handle` | session or buffer handle; OPEN requires 0 |
| 16 | 8 | `arg_a` | per-op |
| 24 | 8 | `arg_b` | per-op |
| 32 | 8 | `arg_c` | per-op |
| 40 | 16 | `reserved` | always 0 |
| 56 | 8 | `reserved2` | always 0 |
| 64 | 64 | `kdesc` | RUN only: the §D3 kernel descriptor, buf slots carrying **buffer handles** the broker validates and translates to resource ids; all-zero for other ops |

| op | name | fields | returns | semantics |
|---:|------|--------|---------|-----------|
| 1 | OPEN | none | session `handle` | one compute session system-wide; takes a device ctx from the shared pool of 2; `ENOSPC` both live, `ENXIO` no VIC1/`ready=0` |
| 2 | CLOSE | `handle`=session | 0 | invalidate first, then the bounded drain; idempotent |
| 3 | BUF_ALLOC | `handle`=session, `arg_a`=size, `flags` | buffer `handle` | size 1..`max_buffer_bytes`; ≤ 16 live per session; I/O class must fit the 8 MiB pool, `WEIGHT` class uses shared staging |
| 4 | BUF_FREE | `handle`=buffer | 0 | `DETACH_BACKING` (when still attached) + `UNREF`, frees pool pages; a buffer bound by an in-flight RUN cannot exist (one outstanding request) |
| 5 | WRITE | `handle`=buffer, `arg_a`=src VA, `arg_b`=len, `arg_c`=buf_off | 0 | uaccess copy → backing (≤4 MiB per call for `WEIGHT`; ≤ buffer remainder for I/O), fenced `TRANSFER_TO_HOST_3D`; `EINVAL` sealed/overrun, `EFAULT` bad src |
| 6 | READ | `handle`=buffer, `arg_a`=dst VA, `arg_b`=len, `arg_c`=buf_off | 0 | fenced `TRANSFER_FROM_HOST_3D` → backing → uaccess out; `EINVAL` sealed/overrun, `EFAULT` bad dst |
| 7 | SEAL | `handle`=buffer | 0 | `DETACH_BACKING` + `UNREF`-less: the resource stays, its backing is released (frees the staging share or the pool pages); irreversible — a second SEAL, or any later WRITE/READ, is `EINVAL` |
| 8 | RUN | `handle`=session, `kdesc` | 0 | validate + translate → `COMPUTE_SUBMIT`; returns on the fence-matched response or the named refusal; `EAGAIN` device busy |
| 9 | STATS | `arg_a`=dst VA | 0 | copies the §D6 counter block (64 B) out; **no handle required** — any process may read it |

The `arg_*` fields not listed for an op must be zero — the cmd-22
foreign-field rule. `EFAULT`/`EINVAL` fire before any device activity;
rejections never move the counters' submit total (they increment
`refusals`, §D6).

## D6 — The counters M111d displays

Broker-maintained, copied out by `STATS` as a fixed 64-byte block
(versioned implicitly by `len`; new fields append at the tail):

| off | field | meaning |
|----:|-------|---------|
| 0 | `busy` u32 | 1 while a device request is in flight |
| 4 | `queued` u32 | broker-held submits waiting for the device (0 or 1 in v1 — one in flight, one caller) |
| 8 | `sessions_live` u32 | live compute sessions (0 or 1) |
| 12 | `reserved` u32 | 0 |
| 16 | `last_kernel_us` u64 | last completed RUN's fenced round-trip in µs — submit-to-fence, the honest number available guest-side |
| 24 | `total_kernel_us` u64 | sum over all completed RUNs |
| 32 | `submits` u64 | RUNs that reached the device |
| 40 | `completed` u64 | fence-matched completions |
| 48 | `refusals` u64 | named refusals before/at the device |
| 56 | `timeouts` u64 | exchange-deadline timeouts |

GOTOP's `gpu` panel shows `busy`, `queued` and `last_kernel_us` (the
card's three numbers) plus the totals; a `VIC1`-absent boot shows the
panel as **unsupported**, exactly as the netview tab shows absent
devices — never a fabricated zero-load.

## D7 — The memory budget against 512 MiB

Numbers, not adjectives. Device-resident means host Metal memory — it
does not consume the VM's 512 MiB (M129a #2610 raised the compiled
default from 256 MiB).

| consumer | guest-resident | device-resident (host) |
|----------|---------------:|-----------------------:|
| Compute broker fixed costs (envelope staging 4128 B, kernel-desc scratch, session table) | ≤ 16 KiB | — |
| Shared weight staging window | 4 MiB | — |
| I/O buffer pool (activations, inputs, logits) | 8 MiB | — |
| Weights, ≤ `max_buffer_bytes` × ≤ 16 buffers | 0 (streamed + sealed) | ≤ 64 MiB chosen by M111c |
| Workspace/scratch for kernels | 0 | ≤ 16 MiB |
| GOINFER app (weights file streaming in ≤ 4 MiB chunks, Go runtime, CPU-side activations/logits) | ≤ 32 MiB | — |
| **Compute feature total** | **≤ ~44 MiB (≤ 9 % of the 512 MiB VM)** | ≤ 80 MiB |

The rule the number enforces: the model is chosen so that *weights ÷
4 MiB* upload chunks stay bounded in count and the sealed footprint
stays 0 — a model that cannot state its resident size under this table
is not the model, and that is decided at M111c's licence review, not
discovered at run time. `BUF_ALLOC`/`WRITE`/`OPEN` enforce every row
above with `ENOSPC`/`EINVAL`; nothing grows by demand.

## D8 — The model rule

- **M111c names the model on the card**: exact model id and release,
  the licence, and the **sha256** of every weight file it will fetch —
  before any fetch. The owner approves on the issue; no approval, no
  download.
- **Licence:** Apache-2.0 or MIT preferred. GPL-family is forbidden —
  the AGENTS.md rule applies to weights as to code: no GPL/LGPL/AGPL
  anywhere in the repo, the boot image, the share seed or the disk.
  Non-OSI "community" licences (non-commercial, use-restriction or
  click-through terms) need **explicit owner approval** — "it has a
  licence file" is not approval.
- **Staging:** weights land on the `--cvc-file` share or on `/disk`
  (VLFS — permitted only if #2365 has landed), never in the boot image.
  The fetch/staging tooling records the sha256 beside the payload and
  the acceptance spec verifies the digest of what it actually staged —
  the pinned value on the card is checked against the bytes, not the
  URL.

## D9 — Card split and file-level Touches

This ADR carries the split; each card's own issue restates it.

| card | scope | Touches | verification |
|------|-------|---------|--------------|
| **M111b** (#2409) | compute path end to end: VIC1 probe + `COMPUTE_SUBMIT` wire, kernel broker + pools, host decoder + Metal compute backend, slot 90 + Go client | `kernel/src/gpu3d_compute.zig` (new), `kernel/src/gpu3d_{device,submit,wire,broker}.zig`, `kernel/src/syscall.zig`, `kernel/src/syscall_abi.zig`, `docs/decisions/0007-syscall-abi.md` (the slot-90 amendment), `host/vm-runner/Sources/VMGPU3D/*`, `host/vm-runner/Tests/VMRunnerTests/GPU3D*Tests.swift`, `user/go/gpu3d/*`, `user/go/vi/gpucompute.go` (new) | `zig build test`; `swift test --filter GPU3D`; `cd user/go && go test ./...`; a submit→fence→readback round trip evidenced over serial |
| **M111c** (#2410) | GOINFER: the tiny model answering in-guest on the GPU | `user/go/goinfer/*`, `tools/go/build-goinfer.sh`, `image/apps.txt`, `user/go/gotabwm/apps_test.go` | model name + licence + sha256 recorded on #2410 and owner-approved **before any fetch**; `go test`; the model's answer observed on serial and pinned |
| **M111d** (#2411) | GOTOP `gpu` panel: busy, queue depth, last kernel time | `user/go/top/*` | `go test`; panel renders real counters; absent-device boot shows unsupported (the panel leg rides M111e's spec) |
| **M111e** (#2412) | acceptance: class-B spec + status row + index closure | `tools/gate/specs/live-gpu-compute.spec` (new; extending `live-gpu3d` instead is a card-time choice, not renegotiation), `docs/status.md` | `live-gpu-compute` green on the reference host: the model answers, output pinned, K consecutive runs; owner sign-off |

## Non-goals

Training; general-purpose shaders / SPIR-V / user-supplied MSL; a
second queue or concurrent in-flight requests; multi-session compute
(v1 is single-tenant); user pinning or DMA into app pages; moving the
compositor or the render path; weights in the boot image; any fourth
kernel; f32 GEMM or strided tensors; a model that cannot state its
resident size under §D7.

## Acceptance

Owner review passes. Every structure above maps to a capset word, an
envelope, a descriptor field, a pool or a counter that M111b implements
without renegotiation — and every refusal has a name.
