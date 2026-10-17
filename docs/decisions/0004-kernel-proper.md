# ADR 0004: The kernel proper — ExitBootServices, identity-map MMU, serial console, and the boot-to-kernel handoff (milestone two)

Status: **accepted** · Date: 2026-08-05 · Milestone: two

## Context

Milestone one delivered a kernel *stub*: a separate freestanding image that
is loaded by the boot app, runs entirely on UEFI Boot Services, prints via
the Simple Text Output protocol, and returns 0 to the loader (ADR 0002). It
deliberately does **not** call `ExitBootServices`; the hardware contract
therefore forbids it from touching the MMU, interrupts, timers, or any
device MMIO.

Milestone two turns that stub into a **kernel proper**: code that seizes
the machine. Seizing the machine means three things, in order:

1. **Ending firmware services** — call `ExitBootServices`, after which no
   UEFI protocol is usable and the kernel owns all of RAM.
2. **Taking over the MMU** — replace the firmware's page tables with the
   kernel's own identity-map tables.
3. **Owning an output device** — the UEFI console channels
   (`ConOut`, `BOOTED.TXT` via the Simple File System protocol) die with
   `ExitBootServices`; after exit the only sanctioned output is direct
   device MMIO, so the kernel needs a minimal serial console driver.

Host constraints that shape every decision below:

- Apple Virtualization.framework is the **only** supported host; there is
  no QEMU path. Observed on VZ: the firmware does not route UEFI `ConOut`
  to the virtio serial port (`vm-serial.log` stays empty) and renders
  nothing to the framebuffer. A kernel-driven serial device is therefore
  the natural first *working* console.
- Apple documents neither the VZ virtual device register layouts nor their
  addresses. Every concrete address or register map in this ADR is
  **[inferred]** and must be confirmed by a device probe at milestone
  start; the design isolates those numbers so a single observed correction
  fixes the whole driver.
- Guest code stays freestanding Zig for AArch64: no libc, no POSIX.

Milestone two does **not** include: an allocator beyond fixed carve-outs, a
scheduler, processes, filesystems, graphics, networking, SMP, syscalls,
interrupts/GIC, or timers. Those remain later milestones; this ADR records
the GIC as an *assumption* (see `docs/hardware-contract.md`) so the
interrupt milestone can proceed without renegotiating the contract.

## Decisions

### D1. The kernel proper calls `ExitBootServices` itself; the boot stub never does

The boundary is clean and one-directional: the boot stub stays a normal
UEFI application ("firmware-land") and the kernel proper is the only code
that exits Boot Services. Rationale:

- The stub must keep writing its evidence (`BOOTED.TXT`, `LOADER.TXT`,
  `MEMMAP.TXT`, `RC.TXT`) and must be able to return control to the
  firmware when the kernel fails *before* exit. If the stub called
  `ExitBootServices`, both of those would be gone and a kernel failure
  would strand the VM.
- Keeping the exit inside the kernel makes "the machine takeover" a single,
  auditable point in one image, and keeps the stub identical in posture to
  milestone one (ADR 0002 D2) until the moment of the jump.

The kernel calls `ExitBootServices(ImageHandle, MapKey)` with the stub's
own image handle, passed to it in the handoff struct (D5). This is valid
because until exit the kernel executes as the stub's image in the
firmware's bookkeeping — the kernel is entered by a direct jump, not by
`LoadImage`, so it has no handle of its own. (The rejected alternative —
the stub calls `ExitBootServices` just before the jump — saves passing the
handle but loses the stub's evidence writes and its failure-return path;
see the rationale above.)

**Ordering (the "when"):** the kernel's takeover sequence is strictly:

1. Switch SP to the kernel-owned stack (provided by the stub, D5).
2. Capture the EFI memory map (D2) while Boot Services still work.
3. Call `ExitBootServices(ImageHandle, MapKey)`.
4. Only *after* a successful exit: build the identity-map tables (D3) and
   install them, then bring up the serial console (D4) and print the
   banner.

`ExitBootServices` comes first so that every later step has zero
dependencies on firmware: the firmware's identity map is still in effect
while the kernel constructs its tables, and any *pre-exit* failure can
still be reported over `ConOut` and returned to the stub.

**Retry behavior (the "how"):** `ExitBootServices` may return
`EFI_INVALID_PARAMETER` if `MapKey` is stale. On that result the kernel
re-runs `GetMemoryMap` into the same buffer and retries, up to a bound of
8 attempts. If the bound is exceeded, the kernel prints a distinctive
failure line via `ConOut` (still available pre-exit) and halts in a
self-loop — it never continues running with firmware services half-torn
down. A stale key is not expected on VZ, but the behavior is specified so
it cannot be improvised under test.

### D2. What the kernel captures before exit, and what it may never do after

Before the call, the kernel allocates (via `AllocatePool`, type
`EfiLoaderData`) a buffer and runs `GetMemoryMap`, keeping the returned
descriptor array, size, key, descriptor size, and version. That buffer is
the kernel's **sole authority on memory layout** for the rest of its life;
it is allocated *before* exit because allocation is a Boot Service.

Memory ownership after exit:

| Region | Owner / disposition |
|--------|---------------------|
| Kernel image allocation (`EfiLoaderCode`, from ADR 0002 D3) | kernel (this is its own code) |
| Kernel stack, handoff struct (`EfiLoaderData`, stub-allocated) | kernel (adopted) |
| Memory map buffer (`EfiLoaderData`, kernel-allocated) | kernel |
| All `EfiConventionalMemory` RAM | kernel, per the map |
| `EfiRuntimeServices`, ACPI/MMIO, reserved, `EfiReservedMemoryType` regions | **reserved**: mapped Device or left unmapped, never used as RAM |

Explicitly **no longer allowed** after a successful exit (a hard, auditable
list): `AllocatePool`/`AllocatePages`, `GetMemoryMap`, `SimpleTextOutput`,
`Simple File System`, `LoadImage`/`StartImage`, `SetTimer`, any event
services, any other Boot Services call. The kernel also performs its own
cache maintenance from this point on — no firmware cleanup is guaranteed.

### D3. Identity-map MMU setup

- **Tables built from scratch**, never reused or modified firmware tables.
  They live in a static, BSS-resident region inside the kernel image,
  sized for this milestone's map (RAM + MMIO windows).
- **TTBR0_EL1 only.** The kernel keeps running in a single flat address
  space where VA == PA (identity map); the later split-kernel
  (TTBR1/virtual layout) design is a separate milestone.
- **4K granule**, level-parameterized table builder: 2 MiB block
  descriptors where alignment permits, 4K pages for partial regions. The
  initial VA space size (`T0SZ`) is chosen at boot from the observed
  memory map; if VZ's MMIO devices turn out to sit above the initial
  bound, `T0SZ` widens and the walk deepens with no design change.
- **Attributes via MAIR_EL1**: Device `nGnRnE` for MMIO (the serial
  device, and later the GIC), Normal Write-Back for all RAM and the
  kernel image. The attribute for each region is derived from its EFI
  memory-map type — cacheable RAM maps WB, MMIO/reserved maps Device or
  stays unmapped.
- **IPS** is read from `ID_AA64MMFR0_EL1` at runtime (a standard CPU
  register read; no firmware dependency, so it is safe to do post-exit).
- **The switch**: new tables are built while running on the firmware's
  identity map. The new tables must identity-map the region currently
  executing (the kernel image) *and* the stack before `msr ttbr0_el1`;
  then `isb`, `tlbi vmalle1`, `isb`. The MMU stays enabled throughout —
  there is no disable/re-enable window, so the firmware map is never
  "absent". A synchronous abort during the transition halts the kernel at
  a distinctive marker (it is a machine-takeover point, not a recoverable
  error).
- **XN/PXN are deferred.** Data regions remain executable this milestone;
  marking code-non-executable everywhere except text is a hardening item
  for the allocator milestone, not a requirement here.

> **D3 addendum (2026-08-07, claims 0010/0020/0021, observed):** the
> `tlbi vmalle1` written in D3 above is **NOT executed**. Claim 0010 proved
> on VZ that a TLBI at the switch forces a page-table re-walk that faults
> on every run (ladder stops at `M2_TTBR!`); the implemented switch is
> `msr mair_el1` → `msr tcr_el1` → `msr ttbr0_el1` → `isb` → `dsb ish` →
> `isb` with **no** TLBI (the implemented sequence also opens with a
> `dsb ishst` before the first `msr`, per `install_identity_map()`),
> relying on the stale firmware TLB entries being
> identity-compatible with the new descriptors (same VA==PA, same
> attributes below the 4 GiB blanket) and on the map never changing
> descriptors post-switch. This is **technical debt with a precise
> boundary, not a completed VM subsystem**: see **ADR 0006** for the full
> safety argument, its validity window, and the binding list of later
> operations (descriptor changes, permission changes, page reclamation,
> non-identity mappings, ASID work, unmapping, above-blanket mappings,
> TCR/MAIR changes) that invalidate it. "MMU takeover fixed" means the
> identity map installs and this milestone's accesses work — it does **not**
> mean TLB invalidation or remapping is proven.
>
> **D3 addendum #2 (2026-08-08, claim 1517; preceded by claims 6460/7896,
> supersedes addendum #1):** the TLBI is now **EXECUTED**, and the start level is corrected.
> Claims 6460/7896 proved the addendum-#1 survival was stale-firmware-TLB
> interference masking a real translation defect: production T0SZ=25/W=39
> started the 4 KiB stage-1 walk at level 1 over the L0-rooted tables, so
> every fresh walk faulted (the first post-MMU virtio BAR read — claims
> 0018/0020 — was the first access whose firmware TLB entry was evicted).
> Claim 1517 lands the production fix: `install_identity_map()` programs
> **T0SZ=16** (walk starts at level 0, matching the built hierarchy) and
> ends with **`tlbi vmalle1; dsb ish; isb`**, so the first post-switch
> access deterministically re-walks correct tables. The implemented switch
> is now `dsb ishst` → `msr mair_el1` → `msr tcr_el1` → `msr ttbr0_el1` →
> `isb` → `dsb ish` → `isb` → `tlbi vmalle1` → `dsb ish` → `isb`. The
> ADR-0006 no-TLBI validity window is closed; the invalidation list
> (re-mapping/unmapping/permission/ASID/TCR-MAIR changes after the switch)
> remains binding for later milestones (see **ADR 0006**).

### D4. Minimal serial console driver

After exit, the only sanctioned output is direct device MMIO. The driver is
a small freestanding `uart` module with the smallest useful API:

- `putc` — poll the TX-ready status bit, then write one byte; no
  interrupts, no FIFO/DMA, no RX path.
- `puts` / a hex-and-u64 printer for debug output.
- `init` — minimal (device reset is a no-op or a two-register poke); the
  driver is usable as soon as the MMU maps the device window.

The **register map is [inferred]**: Apple VZ's virtual serial device layout
and address are undocumented, and the observed firmware behavior (`ConOut`
never routed to the port) gives us no register evidence. Every concrete
number — base address, register offsets, status bit positions — lives in
one table recorded in `docs/hardware-contract.md`, so a single observation
at milestone start (a probe that dumps the region and toggles candidate
registers) corrects the whole driver. The primary candidate layout is
PL011-style (the ARM/SBSA standard, and what edk2-based firmware would
expose on a virtual platform); 16550-style and the VZ virtio-console
register file are the alternatives the probe discriminates between.

**Evidence contingency**: if the probe finds no usable serial device on VZ
(the device could be virtio-transport-only, which is out of scope for a
"minimal UART driver"), output falls back to a **fixed physical memory
marker** — the kernel writes magic + status + banner to a chosen physical
address the host runner dumps — the alternative channel the milestone-one
prompt anticipated. Serial is primary because the host already captures
`vm-serial.log`; the marker is the fallback, decided at the probe, not
during implementation.

> **D4 addendum (2026-08-07, claim 0009, observed):** the *memory-dump*
> form of the contingency is impossible on VZ — guest RAM is not mapped
> into the host runner process (a full submap-aware walk finds no 256 MiB
> region; every hit is the runner's own constant array). The working form,
> implemented and gated (gate work item 3, `tools/verify-marker.sh`), is
> the **EFI NVRAM ladder**: the kernel persists each takeover stage as the
> non-volatile variable `DipshitM2` via runtime `SetVariable`, which
> survives `ExitBootServices` on VZ, and the host reads the variable store
> after the run. The ladder discriminates the serial-gate silence: every
> VZ run ends at `M2_MAPD!` (identity map built, pre-install) — the MMU
> switch in D3 is the death site; the serial probe never runs. See
> `docs/claims/0009-m2-marker-fallback.md` and `artifacts/m2-marker-gate.txt`.

The kernel's banner is exactly:

```
DipshitOS kernel has seized control.
```

(the success line defined by the milestone-one prompt), followed by a hex
print of the kernel's own memory-map view as secondary evidence.

### D5. Handoff contract (v2 → v3 → v4) (boot stub → kernel proper)

Registers keep ADR 0002's ABI where it still means something:

| register | value |
|----------|-------|
| x0 | kernel image base address (4K-aligned) |
| x1 | kernel image size in bytes |
| x2 | pointer to the EFI System Table |
| x3 | **pointer to the handoff struct v2** (replaces the ESP root directory, which is worthless after exit) |

The handoff struct is a stub-allocated `EfiLoaderData` region (4K-aligned,
via `AllocatePages`), owned by the kernel after exit:

| offset | size | field |
|--------|------|-------|
| 0      | u32  | magic `0x324B5344` ("DSK2") |
| 4      | u32  | version (4) |
| 8      | u64  | `kernel_base` (mirror of x0) |
| 16     | u64  | `kernel_size` (mirror of x1) |
| 24     | u64  | `system_table` (mirror of x2) |
| 32     | u64  | `image_handle` — the stub's own EFI handle, required by `ExitBootServices` (D1) |
| 40     | u64  | `stack_base` — 4K-aligned, `EfiLoaderData` |
| 48     | u64  | `stack_size` — 16 KiB for this milestone |
| 56     | u64  | `flags` (0) |
| 64     | u64  | `boot_epoch_secs` — **v3** (#1058, 2026-09-10): Unix wall-clock seconds from `RuntimeServices.GetTime` (days-from-civil over the broken-down face), or `0xFFFF_FFFF_FFFF_FFFF` (`no_boot_epoch`) when the firmware has no clock |
| 72     | 32 B | `measured_loader` — **v4** (#2418, 2026-10-16, ADR 0054 Part I): the loader's measured PE/COFF Authenticode SHA-256 of its own `\EFI\BOOT\BOOTAA64.EFI` image, or zeros when `measured_ok` bit0 is clear |
| 104    | 32 B | `measured_kernel` — **v4**: the loader's raw-file SHA-256 of `\KERNEL.BIN` — the digest it verified against its build-embedded pin before jumping — or zeros when `measured_ok` bit1 is clear |
| 136    | u64  | `measured_ok` — **v4**: bit0 = `measured_loader` holds a real digest; bit1 = `measured_kernel` holds a real digest. A clear bit must surface as `unmeasured` on the chain receipt, never `measured` |

The `boot_epoch_secs` field is a v3 addition: the **version bumps to 3** so
the widening is explicit and non-silent — the frozen 0..64 bytes
(magic/version/kernel_base/kernel_size/system_table/image_handle/stack_base/
stack_size/flags) keep their exact offsets, but a v2 reader that
misinterprets offset 64 is now guarded by the version check rather than
being trusted. It carries the firmware epoch to the kernel so userspace has
a real system clock with or without a host share (the loader reads `GetTime`
before the kernel's `ExitBootServices`); the sentinel preserves the honest
uptime fallback when unavailable. `boot/src/main.zig`, `kernel/src/handoff.zig`,
and this ADR move together.

The v4 measurement fields are the same additive widening (version 4): the
loader is the only honest source of the two boot-stage digests — the kernel
never re-reads the boot volume after handoff, so the measured values travel
in the record the loader already fills. They feed the ADR 0054 Part I chain
receipt (`RCPT stage=…` lines on serial plus the `RCPT.TXT` share file);
they are not part of the frozen validation contract.

The stub additionally allocates the kernel stack (16 KiB, `EfiLoaderData`,
4K-aligned) and records its bounds in the struct. The kernel validates
magic/version on entry; on mismatch it prints via `ConOut` (still up
pre-exit) and returns a non-zero status to the stub.

**Return convention changes.** ADR 0002 had the kernel always return a u64
to the loader. Under v2: on failure *before* `ExitBootServices` the kernel
returns a non-zero u64 (the stub writes `RC.TXT` and returns to firmware);
after a successful exit the kernel **never returns** — it runs until it
halts on a fatal error (self-loop at a marker). `RC.TXT` therefore stops
being the milestone-two success gate (D6).

### D6. Expected evidence and verification gates

Milestone two is not yet implemented; these are the gates the milestone
must pass, written so they cannot be faked (see AGENTS.md evidence rules):

1. `zig build`, `zig build image`, `zig build run` complete on Apple M4 /
   macOS 27.
2. **Primary gate (observed):** after a VZ boot, `vm-serial.log` — empty in
   every milestone-one run — contains the exact banner
   `DipshitOS kernel has seized control.` plus the memory-map hex print.
   The first real content in that log is the milestone-two proof.
3. **Observed:** the VM reaches its terminal state (kernel running in a
   wait loop, or clean halt) and the runner exits as configured — i.e. the
   kernel demonstrably did *not* return to the stub.
4. **Observed:** failure-path evidence still works — a deliberately broken
   handoff (bad magic) produces `RC.TXT` with a non-zero status, proving
   the pre-exit return path.
5. Each `[inferred]` assumption in `docs/hardware-contract.md` (UART
   base/layout, MMU behavior, GIC presence) is flipped to `[observed]`
   only when a corresponding log exists.
6. Logs are saved under `artifacts/`; no QEMU anywhere — VZ only.

## Consequences

- The long-empty `vm-serial.log` becomes a real evidence channel: the
  kernel's first working console is the device the firmware refused to use.
- ADR 0002's "no `ExitBootServices`" posture (D2) is superseded **for the
  kernel proper only**; ADR 0002 remains binding for milestone-one behavior
  and for the boot stub, which never exits Boot Services.
- ADR 0002's `KERNEL.TXT` corruption becomes moot for evidence: after
  `ExitBootServices` the storage path that misbehaves no longer exists.
  (It is also resolved outright — content-at-`base+0` fix, byte-perfect
  and gated — so nothing is carried forward.)
- New hardware assumptions (MMU identity map, MMIO/UART base and layout,
  GIC presence) are recorded `[inferred]` in `docs/hardware-contract.md`
  and must be observed before milestone three can rely on them.
- Interrupts stay masked and untouched in milestone two; GIC and timers
  are milestone three.
- The handoff ABI is now versioned. Any change to it must update this ADR,
  `boot/`, `kernel/`, and `tools/` together; the struct's version field
  makes a mismatch a loud, pre-exit failure rather than silent corruption.
