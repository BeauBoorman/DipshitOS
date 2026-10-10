# ADR 0007: EL0 syscall ABI and runtime dispatch table

Status: **accepted** · Date: 2026-08-10 · Milestone: three (claim 3594)

## B1 amendment (2026-10-01, #1868): bounded process standard streams

This additive wire amendment is submitted for approval with B1. It uses
existing slots only; ADR 0038, the 79 registered rows and the boot default
are unchanged. A3 owns the SDK/std adapter and C1 owns Oliver's actual CLI.

- **Identities:** stdin/stdout/stderr are `0x100`/`0x101`/`0x102` for
  slots 24 (read), 25 (write) and 26 (close). They never alias native file
  handles 0–7. Reads are stdin-only; writes are stdout/stderr-only, with
  wrong direction returning `EACCES`. Slot 1's fd 1/2 select the same
  stdout/stderr bindings, including panic/debug writes.
- **Defaults:** a kernel/monitor spawn has absent stdin and two console
  outputs. Absent or closed input returns `EBADF`, never tty input or
  fabricated EOF. Console outputs are separate identities but share the
  physical console unless explicitly redirected.
- **Spawn:** legacy slot 28 inherits all three caller bindings. Existing
  path/argv conventions remain unchanged. To supply bindings, set bit 63
  of x3 (argc), x4 to a request pointer and x5 to exactly 32. Low argc bits
  keep their existing bound. Without that bit, x4/x5 remain ignored.
  The request is little-endian `[version:u32=1, reserved:u32=0,
  sources:3*u64]`, ordered stdin, stdout, stderr. Unsupported version,
  nonzero reserved or wrong size is `EINVAL`; a bad pointer is `EFAULT`.
  Sources are `UINT64_MAX` (inherit), `UINT64_MAX-1` (closed),
  `UINT64_MAX-2` (console, output only), or a live caller-owned file handle
  0–7. File sources must be host-share, non-directory handles with the
  required access mode. Tty/USB/directory bindings refuse `EINVAL`, invalid
  handles `EBADF`, and wrong mode `EACCES`. Repeated explicit file sources
  refuse `EINVAL` rather than accidentally mixing diagnostics with output.
- **Ownership:** explicit file sources **move** out of the parent on
  successful spawn. Any marshalling, reservation or loader failure leaves
  parent handles and bindings unchanged. Reservations precede loading;
  commit precedes publishing the child on any core. Inherited file streams
  share a refcounted endpoint and sequential cursor, not independent
  positions. Closing one binding or losing its process drops that reference;
  the last reference closes the backend handle. Process-slot reuse never
  reconnects a child to a new owner's file. Threads share process bindings.
- **Bounds:** three bindings/process, 48 endpoint records globally, no heap
  or input-copy buffer. Capacity refusal is `ENOSPC`, never eviction.
  Open files plus file-backed stream bindings remain bounded by eight per
  process; console identities consume no native file handle. A3 separately
  charges all three stream resource records against the eight SDK records.
  Stream input/output and diagnostic byte budgets stay in workload adapters,
  not a silent truncation in this facility.
- **I/O:** slot 1 and console stream writes confirm at most 256 bytes/call;
  file stream writes confirm at most 2,048. Larger requests return a short
  count, not the old slot-1 `EINVAL`. Callers must advance by the confirmed
  count and retry; zero progress or a negative result is failure, not a
  completed flush. Existing raw file-slot write limits are unchanged.
  Backend short writes advance by confirmed counts only; a failed later
  chunk returns the confirmed prefix, while first-chunk errors, zero
  progress and impossible oversized confirmations refuse. Slot 24 clamps
  reads at 2,048 and consumes a stream cursor only after successful copy-out.
  A stream reaches EOF at its captured open size. Premature zero-byte reads,
  missing paths and backend disconnection are errors, not EOF. Host read
  handles retain the existing stateless path+size semantics; B1 does not
  promise stable inode identity or containment under mutation (B3's area).
- **Closure:** slot 26 closes only that process binding. Repeated close
  returns `EBADF`; subsequent I/O refuses, with no console fallback. A
  final backend close error is returned and keeps the binding for retry.
  Death teardown releases all references even if the disconnected backend
  refuses cleanup; it cannot manufacture successful close or remote cleanup.
  Writes are synchronous and unbuffered here; an SDK buffered flush must
  still surface its own failures.

The shell's slots 56/57 remain bounded 4 KiB sequential buffers — as of
M97g (#2081) **one per process** (a fixed 4-slot table), never one shared
global buffer: an EL0 read/write reaches only the caller's own slot, a
full table refuses `ENOSPC`, a drained or dead-owner slot releases. The
kernel shell's `|` staging keeps its own private pipe behind the console
adapters. This amendment supplies file redirection and inherited streams,
**not general concurrent pipes**, POSIX descriptors or a shell
redirection integration.
Class-A ownership/error tests and `live-user-fs`'s native probe verify the
facility. Their HTML/JSON fixture is not Oliver CLI acceptance; that needs
A3+C1 and an independent pinned-engine comparison.

## Amendment (2026-10-01, B4 #1871 — explicit staged replacement)

Slot 35 keeps its four-argument signature. `old_len` bit 63
(`0x8000_0000_0000_0000`) selects **replace-on-publish**; its remaining bits
are the source byte count. Without that bit, rename is **preserve-existing**
on every backend. Both lengths use B2's 1–512-byte bound; other set length
bits are invalid. x4/x5 remain ignored: existing four-argument gateways do not
initialize them, so making either register a flags word would break callers.
No new slot, widened path, handle, allocation or native error number.

Both operations stay within `/host` and authorize source deletion and
destination creation before backend mutation. Secret/poisoned paths refuse
at either end, including privileged actors. Success moves the source trust
metadata (implicit defaults included); a backend refusal leaves both entries
unchanged. Same-path/case-only success does not change metadata.

Replacement is one backend rename: VirtioFS `FUSE_RENAME`, or additive
legacy file-channel opcode `0x10` backed by the host's atomic rename
(B2 keeps `0x0d`–`0x0f` and statuses 7–9; B4 adds statuses 10–11).
Preserve-existing uses `FUSE_RENAME2` with `RENAME_NOREPLACE`, or legacy
opcode `0x09` backed by `RENAME_EXCL`. There is no stat-then-overwrite,
delete-then-rename or copy fallback. An unsupported primitive refuses before
mutation. An older legacy host rejects the new opcode instead of ignoring
a replacement flag.

Results: 0 success, `EINVAL` (-1) invalid path/type/backend failure,
`EFAULT` (-3) either bad user path, `ENOSYS` (-4) unsupported primitive,
`ENOENT` (-6) missing source/parent, `EACCES` (-7) permission/trust denial,
file-domain `EEXIST` (-9) preserved destination. Backend rejection preserves
the prior destination and staged source. Transport loss after submission
has an **unknown commit outcome**, not a claimed rollback guarantee.
No directory-fsync/power-loss durability or multi-file atomic switch is
promised. `live-user-fs` covers both backends and the unchanged ABI consumers.

## Context

Claim 8215 / PR #60 proved the smallest real EL0 boundary: a statically
linked EL0t task executes from a page-isolated user-text aperture, uses a
separate EL0 stack, enters EL1 with `svc #0`, and returns through the shared
exception-vector frame while the tick scheduler preserves `SP_EL0`. That card
deliberately exposed only one proof operation.

This card freezes the numbered contract before uaccess, per-task address
spaces, task lifecycle expansion, or executable loading build on accidental
register choices. The merged and VZ-proven claim-8215 convention is x8 as the
operation selector and x0 as argument/result. Docs-only commit `6b1b8cd`
later described both number and result as x0; that transcription cannot encode
`ping(value) -> value` and contradicts `userspace.zig`, claim 8215, its branch
log, and its live evidence. This ADR records the implemented boundary.

The kernel is a relocation-free flat image linked at zero and loaded at a
runtime-selected base. ADR 0005 therefore forbids const data tables containing
function or slice pointers: their link-time absolute addresses are wrong after
the load.

## Decisions

### D1. Register and exception convention

- x8 contains the syscall number.
- x0–x5 contain up to six arguments; x0 receives the return value.
- The instruction is `svc #0`. ESR_EL1's SVC immediate remains zero and is
  reserved; it does not carry a syscall number.
- The result is written to x0 in the saved claim-9746 vector frame before
  exception return restores the registers.
- SVC dispatch is EL0-only. `is_svc64_from_el0` accepts AArch64 SVC from EL0t;
  an SVC from EL1t or EL1h stays on the exception report-and-park path because
  kernel code calls functions directly.
- Claim 8215 continues to own vector entry, EL0 routing, `SP_EL0`, and return
  plumbing. The syscall module registers through its existing
  `set_svc_dispatcher` seam.

### D2. Fixed number space and table

The namespace is 0–63. The dispatch table has exactly 64 slots and is built at
runtime in module-level BSS. It is never a const function-pointer table.

| # | Name | Signature | Behavior |
|---|------|-----------|----------|
| 0 | `sys_ping` | `ping(value) -> value` | Preserves claim 8215's two-call EL0 return proof. |
| 1 | `sys_write` | `write(fd, buf, len) -> i64` | Writes at most 256 bytes to console fd 1 through the registered writer. |
| 2 | `sys_yield` | `yield() -> i64` | Cooperatively stages the next runnable task and returns 0 when the caller runs again. |
| 3 | `sys_exit` | `exit(status) -> noreturn` | Removes the caller from the runnable ring, stages its successor, and defers a shell report. |
| 4–63 | reserved | — | Returns `-ENOSYS`; later additions occupy one frozen row without renumbering. |

Every in-range slot has a monotonic call counter. `syscalls` reports the four
implemented rows and counters deterministically.

### D3. Return errors

Negative signed values are returned as their two's-complement x0 bit pattern:

| Value | Name | Meaning |
|-------|------|---------|
| 0 | success | The operation succeeded. |
| -1 | `EINVAL` | Argument arithmetic or the bounded write cap is invalid. |
| -2 | `EBADF` | The write fd is not 1. |
| -3 | `EFAULT` | Reserved for the follow-on uaccess card; not returned yet. |
| -4 | `ENOSYS` | The syscall number is unknown or reserved. |

`sys_write` currently checks the fd, 256-byte cap, addition overflow, the MMU
builder's guaranteed low 4 GiB identity blanket, and containment within one of
the two kernel-known EL0 apertures (user text or user stack) before
dereferencing. Privileged RAM and Device mappings inside the blanket are
therefore not readable through this syscall. This is bounded arithmetic over
already-known identity mappings, not fault-safe user-pointer access. The later
uaccess card owns mapping/permission checks, fault recovery, and EFAULT.

### D4. Scheduling effects stay within the fixed task model

Yield and exit reuse the claim-5275 fixed scheduler pool. Yield saves the SVC
frame and stages the next runnable task. Exit marks the EL0 caller terminated,
removes it from round-robin selection, stages another existing task, and never
returns to the terminated frame. The exception seam returns the scheduler's
selected frame just as its IRQ path already does. No dynamic task creation,
process object, allocation, or expanded loader is introduced.

The demo EL0 payload waits on a one-word witness in its existing user-BSS
aperture before calling `sys_yield`. Only the timer-switch wrapper updates that
witness; cooperative switches cannot. This preserves claim 8215's prerequisite
observation—a real timer IRQ preempts EL0 and returns to the shell—before the
new cooperative path runs.

SVC handlers execute in synchronous exception context, not IRQ context, so the
write writer may emit a short bounded line. Timer/scheduler IRQ paths remain
console-free; exit reporting is deferred to the shell idle loop.

## What this is not

- It is not POSIX, libc, `errno`, or a compatibility ABI.
- It is not uaccess, PAN, fault recovery, or safe arbitrary user-pointer
  access.
- It is not per-task address spaces, processes, dynamic task creation, or a
  user lifecycle subsystem.
- It is not an ELF loader or ESP executable path.
- It does not change the kernel takeover path, MMU ownership, or hardware
  contract.

Those later milestone-three cards build on this frozen numbering and register
contract rather than widening this card.

## Consequences

- Adding a syscall is one runtime table row, one bounded handler, and tests;
  existing numbers and errors do not move.
- The claim-8215 ping transcript remains a regression proof while the new live
  SVC gate proves dispatch-table write/yield/exit behavior and shell recovery.
- Host tests cover table shape, marshalling, errors, counters, writer output,
  scheduling hooks, and deterministic reporting; VZ evidence remains required
  for the real EL0 exception round trip.

## Amendment (2026-08-10, claim 6120 — the uaccess card)

D3's `-3`/`EFAULT` row is no longer reserved: the uaccess card implements it.
`sys_write` now copies user bytes through the uaccess layer
(`kernel/src/uaccess.zig`, `uaccess.copy_in`) instead of validating ranges
inline, so a bad user pointer returns `-3` rather than `-1`:

- `EFAULT` (`-3`) — the user pointer is bad: `buf + len` wraps, the range is
  not fully inside one of the two kernel-known EL0 apertures (user text
  read-only, user stack read-write), the range targets an unmapped address
  (above the identity blanket), or the operation lacks permission (e.g.
  `copy_out` into the read-only text aperture). Rejected before any memory
  access; a data abort taken while a copy is running is recovered into
  `EFAULT` instead of crashing EL1 (a masked uaccess window + the
  claim-9746 synchronous path advancing ELR past the faulting instruction).
- `EINVAL` (`-1`) — the bounded write cap is exceeded (`len > 256`);
  pointer-arithmetic and range errors are `EFAULT` now.
- `EBADF` (`-2`) — unchanged (fd is not 1).

The pointer-taking syscall (`sys_write`) is migrated; the EFAULT contract is
proven end to end by the EL0 payload (a bad-pointer write returns `-3` and
EL0 survives) and by the `uaccess` monitor diagnostic (a real data abort at
EL1 recovered into EFAULT on VZ), gated by `tools/verify-live-uaccess.sh`.
The ABI itself — x8 number, x0–x5 arguments, x0 result, slots 0–3,
reserved 4–63 — is unchanged.

## Amendment (2026-08-10, claim 5804 — the per-task address-space card)

The user pointer's translation now comes from the EL0 task's OWN TTBR0 root
instead of the shared identity map, and the design landed on the VZ fallback
(measured — see `kernel/src/mmu.zig`'s module doc):

- **TTBR1 is NOT used.** The original design put the kernel at a TTBR1 KVA
  shadow (`KVA_BASE + phys`) so TTBR0 could be swapped freely per task.
  Live VZ measurement proved TTBR1 translation incompatible with this
  kernel's tables: with 4 KiB-aligned tables the TTBR1 walker faults at the
  FIRST descent level in every configuration (shared L0 root, dedicated
  48-bit L0 root, dedicated 39-bit L1-rooted mirror with T1SZ=25) despite
  provably-valid descriptor chains — the signature of a walker masking
  table addresses to 64 KiB. With 64 KiB-aligned tables the walk resolves
  (block and page leaves) but a Normal-WB data access through TTBR1 then
  aborts (TLB conflict abort, then synchronous external abort DFSC=0x21
  after extra invalidations) while Device leaves were readable — so a
  kernel executing from a KVA shadow cannot work on VZ.
- **Fallback: per-task TTBR0 with an EL1-only kernel overlay.** The kernel
  stays identity-mapped in TTBR0 (T0SZ=16, TTBR1=0). Every task's TTBR0
  root carries the kernel identity map as EL1-only leaves (AP=0b00); the
  EL0 task's root (`build_user_root`) is a clone of the identity tree with
  its text+stack leaves overlaid at the user VAs. The kernel is therefore
  reachable under EVERY root, so the scheduler can switch TTBR0 per task.
- **EL0 reach is exactly the text+stack leaves.** Every other leaf — kernel
  RAM, firmware, MMIO Device windows — is EL1-only, so an EL0 access takes
  a permission fault, never a device access. UXN/PXN are enforced on every
  user leaf (W^X). MMIO is excluded from EL0 by the same EL1-only AP bits:
  the user root's Device leaves are EL1-only (`el0_device = 0` measured on
  VZ).
- The `addrspaces` monitor diagnostic reports TTBR1=0, T0SZ=16, each task's
  TTBR0 root, and the user root's leaf inventory (`el0`, `el0_device`),
  gated by `tools/verify-live-addrspaces.sh`.

The syscall ABI (x8 number, x0–x5 args, x0 result) and the EFAULT contract
are unchanged by the address-space move; the EL0 payload + uaccess recovery
prove the boundary under the user root.

## Amendment (2026-08-10, claim 3200 — the blocking syscalls card)

Slot 4 (`sys_sleep`) is frozen in the dispatch table:

| 4 | `sys_sleep` | `sleep(ticks) -> i64` | Blocks the calling task for at least `ticks` scheduler ticks (1 tick ≈ 1 s timer period on VZ). Returns 0 on wake; `EINVAL` for a zero-ticks deadline clamp or overflow. The scheduler's `blocked` state + per-task `wakeup_tick` deadline + timer-driven `wake_expired` on every tick move the sleeper back to `ready`; the round-robin ring resumes it from its saved SVC frame, exactly like `sys_yield`. |

`implemented_count` is now 5; the `syscalls` report prints rows 0–4.
`scheduler.sleep_current` clamps `ticks=0` to 1 (minimum sleep is one tick).
The `blocked` task is counted as live by `user_root_in_use` (the exec gate),
so a sleeping user program still owns the user root until it exits.

The ABI — x8 number, x0–x5 arguments, x0 result, reserved 5–63, error
codes — is unchanged.

## Amendment (2026-08-10, claim 5965 — the IPC mailbox card)

Follow-on 3 card 3f freezes slots 5 and 6 in the dispatch table (the ONE
ABI change in the follow-on 3 card set; everything else stays frozen):

| 5 | `sys_ipc_send` | `ipc_send(target, buf, len) -> i64` | Copy `len` bytes (≤ 64; longer is truncated to the slot bound) from the caller's region through uaccess into process `target`'s bounded per-process mailbox (`kernel/src/mailbox.zig`: 8 × 64 B BSS ring per process id, FIFO — the capacity is a DATA-PATH CONSTANT, raised 4 → 8 by claim 3179 on card 4b; NOT a syscall number, this ABI row is unchanged). Returns the sent length; `EINVAL` for an out-of-range/free/exited target, `EFAULT` for a bad user pointer, `ENOSPC` when the target's ring is full (checked before any bytes are copied). |
| 6 | `sys_ipc_recv` | `ipc_recv(buf, max) -> i64` | Copy the caller's OWN oldest message out through uaccess (`max` > 64 clamps to it; `max` shorter than the message truncates the copy — both documented), consuming it. Returns the copied length; 0 when the mailbox is empty; `EINVAL` when the calling task is not a process; `EFAULT` leaves the message queued (peek → copy_out → drop). |

`ENOSPC` (`-5`) joins the D3 error table: the target process's bounded
mailbox is full — the send is refused, never unbounded and never silently
dropped.

`implemented_count` is now 7; the `syscalls` report prints rows 0–6.
Every byte crosses the claim-6120 uaccess window in both directions, and a
process can only reach its own mailbox (recv) and a live target's (send) —
cross-process isolation at the mailbox level, with the ring reset whenever a
process id is created/recycled (exec path + boot-payload registration).

No POSIX pipes/fds/signals, no unbounded mailboxes, no scheduler/lifecycle
changes: this is the ONLY ABI amendment in the follow-on 3 card set.

## Data-path note (2026-08-11, claim 3179 — the IPC-depth card)

Follow-on 4 card 4b raises the mailbox capacity `mailbox.max_messages`
4 → 8 (the per-process ring grows 256 → 512 B of fixed BSS — still no
allocation) as a DATA-PATH CONSTANT, NOT a syscall number: the ABI stays
frozen (the follow-on-4 set's ABI amendments are ONLY slots 7/8, on cards
4a/4c). The truncation contract is unchanged: a message longer than 64 B
still truncates at the slot bound, a full ring still refuses with the
same `ENOSPC` (-5) — now at the 9th send — the same empty → 0 recv
result, the same drain invariant `sent − recv == pending ≤ capacity`,
and the same cross-process isolation (a process reaches only its own
mailbox and a live target's).

## Amendment (2026-08-11, claim 5799 — the process-observability card)

Follow-on 4 card 4a freezes slot 7 in the dispatch table (the ONE ABI
change in the first card of the follow-on 4 set; everything else stays
frozen):

| 7 | `sys_procs` | `procs(buf, max) -> i64` | Copy a bounded snapshot of the process table OUT into the caller's region through uaccess — a read-only view (no write path). One fixed 40-byte row per NON-FREE descriptor, in id order: `u64 pid` (LE), `u64` state code (the `process.State` enum: 1=created, 2=running, 3=exited), `u64 exit_status` (0 unless exited — the status survives the reap), `name[16]` NUL-padded. `max` truncates to WHOLE rows (`floor(max / 40)` — a partial row is never copied); `max == 0` → 0 rows. Returns the row count written; `EFAULT` for a bad buffer. |

`implemented_count` is now 8; the `syscalls` report prints rows 0–7.
The snapshot is marshaled into a fixed BSS scratch (`max_processes` × 40 =
320 B, no allocation) then copy_out'd through the claim-6120 uaccess
window; no caller-identity requirement (any EL0 task may read the table).
The EL0 proof rides PEER.BIN: it polls `sys_procs` once per quantum until
the snapshot shows a running peer, prints `peer: sees <pid> <name>
<state>` per row, then enters its recv loop — a process-level view of the
process table reachable from EL0, distinct from the EL1h monitor's own
`procs` read.

The ABI — x8 number, x0–x5 arguments, x0 result, reserved 8–63, error
codes — is unchanged.

## Amendment (2026-08-11, claim 9946 — the exit-status-propagation card)

Follow-on 4 card 4c freezes slot 8 in the dispatch table (the SECOND ABI
change in the follow-on 4 set — the set's explicit slots 7/8 amendment,
following the `sys_sleep` slot-4 and ipc slots-5/6 precedents; every
existing syscall number 0–7 stays frozen):

| 8 | `sys_wait` | `wait(target) -> i64` | Block the calling process until the process with id `target` exits, then return its exit status. NOT POSIX wait: no zombies, no fds, no children — the caller may wait on ANY registered process (the exit status is a plain kernel-recorded number, kept in the process registry after the executor reap). Errors are `EINVAL`: the caller is not a process (an EL1h task), the target is out of range or free, the target is `created` (loaded but not yet running — it may never run, and the kernel refuses a waiter that could never wake), or the caller waits on ITSELF (it would never exit while blocked — the deadlock is refused). An ALREADY-EXITED target returns its stored status immediately (no block); a RUNNING target parks the caller (`scheduler.wait_current` — the claim-0635 sleep seam: the caller's SVC frame stays on its kernel stack, and the exit path's `wake_waiters` flips it back to `ready` and patches the status into the saved frame's x0, so the syscall return lands when the ring resumes it). |

`implemented_count` is now 9; the `syscalls` report prints rows 0–8.
The block is event-driven, not time-driven: `wake_expired` (the tick
clock) never touches a task whose `wait_pid` is set, and the wake happens
in `exit_current` right after the registry records the exit — pure TCB +
saved-frame writes, safe in the exception context. Multiple waiters on
one pid all wake with the same status; a waiter can never outlive its
target (a process is only reaped AFTER it exits, which wakes the waiter
first). The EL0 proof rides COUNTER.BIN (exec'd with the wait target in
its argv): it prints `ipc: waiting pid=<n>`, blocks, and prints `ipc: saw
pid=<n> status=<s>` when the target (STATUS43.BIN, exiting 43) wakes it.

As with slot 7, this is the follow-on-4 set's final ABI change; the ABI —
x8 number, x0–x5 arguments, x0 result, reserved 9–63, error codes — is
otherwise unchanged.

## Amendment (2026-08-12, claim 1384 — the UDP syscall seam card)

Milestone-five card N6 freezes slots 9/10/11 in the dispatch table (the
card's ONE ABI change, following the `sys_sleep` slot-4, ipc slots-5/6,
and wait slot-8 precedents; every existing syscall number 0–8 stays
frozen):

| 9 | `sys_udp_listen` | `udp_listen(port) -> i64` | Bind the bounded kernel listen table (`udp.zig`'s 4-slot table — the SAME table the monitor's `net udp listen` uses) to `port`. Kernel-global: any EL0 task may bind any port (no per-process ownership — the honest bound). Returns 0; `EINVAL` for port 0/> 65535 or a duplicate/full table. |
| 10 | `sys_udp_send` | `udp_send(ip, port, buf, len) -> i64` | Send ONE UDP datagram to `ip:port` from the FIXED source port 7000 (`udp.default_src_port`). `ip` is the 4 octets in network byte order in x0's low 32 bits (extracted byte-explicitly — AArch64 is little-endian, never a bitcast). `len` (≤ `udp.payload_max` 64, truncated honestly) is copied through uaccess into fixed BSS staging, then `net_udp_send` runs the N5 path: an own-IP send takes the LOOPBACK path (no device round trip); a peer send needs its MAC in the ARP table (`EINVAL` — `.no_peer`/`.not_ready`/`.timeout`; the seam does NOT resolve ARP — the caller resolves via the monitor's `net arp` and may retry). Returns the payload length; `EFAULT` for a bad `buf`; 0 for a zero-length no-op. |
| 11 | `sys_udp_recv` | `udp_recv(port, buf, max) -> i64` | Copy the oldest datagram for the listener on `port` OUT through uaccess — the full 8-byte UDP header + payload (the caller parses the header; the src IP is not kept — honest bound). Returns the copied length (max clamps to `udp.datagram_max` 72; shorter truncates and CONSUMES); 0 when the ring is empty; `EINVAL` when not listening on `port`. The datagram is PEEKED, copied out, and only then popped — a bad recv buffer (`EFAULT`) leaves it queued (the claim-5965 contract). The device is DRAINED FIRST (`virtio_net.net_rx_drain`, the claim-6076 polled-drain contract — the used-buffer IRQ is unobserved): a recv pulls any waiting frame device → ring synchronously, so an EL0 polling loop is self-sufficient without the shell idle loop (observed live: without the drain the answer sat in the device queue until a `net` command drained it). |

`implemented_count` is now 12; the `syscalls` report prints rows 0–11.
The EL0 proof rides UDP.BIN (a new `user/src/udp.zig` program, loaded by
`exec`): it binds 7000, loopback-sends to its own IP, polls `sys_udp_recv`
for the host's `--net-udp-respond 10.0.0.2:9999` answer (the cooperative
`sys_yield` between polls — the ring must return to the program, so the
live gate keys its observation phase on the program's OWN `udp: got ping`
marker and its exit on the reap line; an early expect would kill the VM
before the round trip and the gate would fail on a healthy kernel),
observes the `EINVAL` mapping from EL0 (unbound-port recv, unresolved-
peer send), and exits 17.

As with slots 7/8, this is the milestone-five set's ABI amendment; the
ABI — x8 number, x0–x5 arguments, x0 result, reserved 12–63, error
codes — is otherwise unchanged. The UDP protocol layer itself stays in
the N5 card (`kernel/src/udp.zig`); these handlers only marshal args,
copy bytes through the claim-6120 uaccess window, and call through.

## Amendment (2026-08-13, claim 0487 — the draw/window syscall seam card)

Milestone-six card G6 freezes slots 12/13/14 in the dispatch table (the
card's ONE ABI change, following the `sys_sleep` slot-4, ipc slots-5/6,
slots-7/8, and udp slots-9/10/11 precedents; every existing syscall
number 0–11 stays frozen):

| 12 | `sys_win_open` | `win_open(x, y, w, h) -> i64` | Open a user window in the G5 window manager (`driving_award.zig`): a bounded registry slot (id 2..3, TWO user windows) with a fixed BSS back-buffer (≤ 256×192 B8G8R8X8), OWNED by the calling process (the syscall layer records the caller's pid via `process.find_by_task(scheduler.current_id())`). Returns the window id; `EINVAL` for geometry outside the back-buffer/scanout bounds, an unarmed manager (no gpu), or a non-process caller; `ENOSPC` (-5) when both user slots are already open. No uaccess — plain numbers. |
| 13 | `sys_win_fill` | `win_fill(id, x, y, w, h, rgb) -> i64` | Fill a rect (window-local coordinates) in the CALLER'S window's back-buffer with a 24-bit `0xRRGGBB` color, marking it dirty. Returns 0; `EINVAL` for an unknown id, a window the caller does NOT own (per-process ownership), an out-of-range word, or a rect outside the window bounds. No uaccess — the kernel owns the buffer; the program never touches it directly. |
| 14 | `sys_win_present` | `win_present(id) -> i64` | Mark the CALLER'S window dirty so the compositor blits its back-buffer on the next idle-loop pass (the deferred-present discipline — the syscall never touches the gpu directly; the shell idle loop's `driving_award.drain` composites). Returns 0; `EINVAL` for an unknown id or a window the caller does NOT own. |
| 15 | `sys_win_close` | `win_close(id) -> i64` | (Follow-on to claim 0487 — the teardown half of the seam.) Release a user window OWNED BY THE CALLER so it can be re-opened. Returns 0; `EINVAL` for an unknown id, a non-user window (the terminal + clock are fixed), or a window the caller does NOT own. The monitor's `win close <n>` is the EL1h PRIVILEGED equivalent (closes any user window); both call `driving_award.user_close`. |
| 16 | `sys_win_move` | `win_move(id, x, y) -> i64` | (Follow-on to claim 0487 — the move half of the seam.) Reposition the CALLER'S user window's top-left corner to (x, y), CLAMPED so the whole window stays inside the scanout (`driving_award.user_move` — a window never moves off-screen). Returns 0; `EINVAL` for an unknown id, a window the caller does NOT own, an out-of-range word, or an unarmed manager. No uaccess — plain numbers. |
| 17 | `sys_win_raise` | `win_raise(id) -> i64` | (Follow-on to claim 0487 — the restack half of the seam.) Raise the CALLER'S user window to the top of the z-order (focus unchanged — tracked by id). Returns 0; `EINVAL` for an unknown id or a window the caller does NOT own. The monitor's `win move <n> <x> <y>` / `win raise <n>` are the EL1h equivalents. |
| 18 | `sys_win_get` | `win_get(id, buf) -> i64` | (Follow-on to claim 0487 — the read-back half of the seam.) Copy the CALLER'S user window's geometry (x, y, w, h as four u32 LE words — 16 bytes) OUT through uaccess, so an EL0 program can read its window's rect back after a CLAMPED move (`sys_win_move` clamps silently; this is the read-back seam). Returns 0; `EINVAL` for an unknown id, a non-user window (the terminal + clock are fixed), or a window the caller does NOT own; `EFAULT` for a bad `buf`. The first pointer-taking win slot (the claim-6120 contract). |
| 19 | `sys_win_query` | `win_query(id, buf) -> i64` | (Follow-on to claim 0487 — the full-state introspection half of the seam.) Copy the CALLER'S user window's FULL state (x, y, w, h, z, focused, visible, dirty as eight u32 LE words — 32 bytes) OUT through uaccess, so an EL0 program can introspect its window end to end: the z-order rank (`z` = the registry index, 0 = bottom — the SAME number the monitor's `win` report prints), plus the focus/visible/dirty flags. Returns 0; `EINVAL` for an unknown id, a non-user window, or a window the caller does NOT own; `EFAULT` for a bad `buf`. The second pointer-taking win slot. |
| 20 | `sys_win_set_visible` | `win_set_visible(id, visible) -> i64` | (Follow-on to claim 0487 — the visibility half of the seam.) HIDE (`visible` 0) or SHOW (`visible` 1) the CALLER'S user window (`driving_award.user_set_visible`, owner-restricted like fill/present/close). Hiding marks the terminal dirty so the next composite repaints over the hidden window; showing marks the window dirty so it reappears. Returns 0; `EINVAL` for an unknown id, a non-user window (the terminal + clock are fixed), a window the caller does NOT own, or a `visible` flag that is not 0/1. Plain numbers, no uaccess. |

`implemented_count` is now 21; the `syscalls` report prints rows 0–20.
The EL0 proof rides WIN.BIN (a new `user/src/win.zig` program, loaded by
`exec`): it opens window 2, fills a dark-blue background + three 48×48
blocks (red/cyan/white), presents it, and exits 87 — the first EL0
graphics. No uaccess (the seam is plain numbers + kernel-owned buffers),
no allocation (fixed BSS back-buffers).

**Per-process ownership (the follow-on that supersedes the original
"kernel-global" bound):** a window is OWNED by the process that opened it
and AUTO-CLOSES when that process exits — the scheduler's `exit_current`
calls `driving_award.close_owner(pid)`, so no window leaks until reboot.
`sys_win_fill`/`sys_win_present`/`sys_win_close` are owner-restricted (a
process can only render into and close its own window; the EL1h monitor's
`dui close` stays privileged). The open → fill → present → exit
auto-close and the open → fill → present → close → re-open cycles are
host-tested end to end (`kernel/src/syscall.zig`, `kernel/src/driving_award.zig`).

The close follow-on (slot 15) makes the seam releasable: `sys_win_close`
and the monitor's `dui close <n>` both call `driving_award.user_close`,
which frees the id (2..3) for re-open and un-presents the window. The
open → fill → present → close → re-open cycle is host-tested end to end
(`kernel/src/syscall.zig`, `kernel/src/driving_award.zig`), and the
EL0 release proof rides a SEVENTH image WINCLOSE.BIN
(`user/src/winclose.zig`): it opens window 2, fills it, presents it,
CLOSES it through slot 15, and exits 88 — the class-B gate
`tools/verify-live-win-close.sh` shows the window gone from the registry
(`win: windows=2`) and a re-exec re-opening id 2 (the freed slot reused,
never id 3). The auto-close-on-exit proof rides WIN.BIN (open → exit, NO
close): the class-B gate `tools/verify-live-win-close.sh`'s sibling
`tools/verify-live-win-syscall.sh` shows `win: windows=2` with
`sys_win_close calls=0` after WIN.BIN exits — the window was released by
the exit path, not a syscall. Because WIN.BIN's window now vanishes
before a host capture, an EIGHTH image WINLOOP.BIN
(`user/src/winloop.zig`) opens the same window and yield-loops forever,
keeping it on the scanout for the gate's decoded-capture phase.

The move/raise follow-on (slots 16/17) makes the seam able to reposition
and restack: `sys_win_move` clamps the window on-scanout
(`driving_award.user_move`), `sys_win_raise` reorders the z-order
(`driving_award.user_raise`), and both are owner-restricted like
fill/present/close. The EL0 proof rides a NINTH image WINMOVE.BIN
(`user/src/winmove.zig`): open → fill → present → move → move (the second
move clamps to the scanout corner) → raise → yield-forever; the class-B
gate `tools/verify-live-win-move.sh` shows the window's final clamped
rect (`dui[2]: user user rect=1024,528,256,192`), the counters
(open=1/fill=4/present=3/move=2/raise=1/close=0), and the decoded
capture with the window's colors at the NEW position and the terminal
where it USED to be.

The get follow-on (slot 18) makes the clamp observable from EL0:
`sys_win_get(id, buf)` copies the caller's window rect (four u32 LE
words — the first pointer-taking win slot, through the claim-6120 uaccess
window) so a program can read its clamped position back instead of
inferring it from the `win` report. WINMOVE.BIN now reads the rect back
after its clamped move and prints `winmove: get 1024,528,256,192` — the
gate's `tools/verify-live-win-move.sh` assertion (get=1), alongside the
counters (move=2/raise=1/get=1/close=0).

The query follow-on (slot 19) makes the FULL state introspectable from
EL0: `sys_win_query(id, buf)` copies the caller's window rect PLUS the
z-order rank (`z` = the registry index), focus, visible, and dirty flags
(eight u32 LE words — the second pointer-taking win slot) so a program
sees its window the same way the EL1h `win` report does. WINMOVE.BIN
prints `winmove: query 1024,528,256,192 z=2 focused=1 visible=1 dirty=1`
after its clamped move — the gate's `tools/verify-live-win-move.sh`
assertion (query=1), alongside the counters (move=2/raise=1/get=1/query=1/close=0).

The set_visible follow-on (slot 20) makes the window HIDEABLE/SHOWABLE
from EL0: `sys_win_set_visible(id, visible)` toggles the caller's
window's `visible` flag (owner-restricted; the fixed terminal + clock are
refused). Hiding marks the terminal dirty so the next composite repaints
over the hidden window's pixels; showing marks the window dirty so it
reappears — the window's back-buffer and z-order rank are untouched
(only the flag flips). WINMOVE.BIN now hides its window, sleeps 2 ticks
(holding it hidden while the gate captures the GONE frame), shows it
again, and prints `winmove: hide ok` / `winmove: show ok`. The class-B
gate `tools/verify-live-win-move.sh` gained a marker-driven capture
(`--screenshot-after "winmove: hide ok"`, a new VMRunner flag) that
proves the PIXEL DISAPPEARS (no red/cyan/white blocks at the clamped
spot) while the LATEST fixed capture proves it RETURNS — alongside the
counters (move=2/raise=1/get=1/query=1/set_visible=2/close=0).

As with slots 9/10/11, this is the milestone-six set's ABI amendment; the
ABI — x8 number, x0–x5 arguments, x0 result, reserved 21–63, error
codes — is otherwise unchanged. The window registry + compositor stay in
the G5 card (`kernel/src/driving_award.zig`); these handlers only marshal
args and call through to it.

## Amendment (2026-08-15, claim 6359 — the EL0 exec seam card)

Milestone 11's A5 tracker claim called DESKTOP.BIN a "clickable application
menu to launch EL0 programs" — but the code only selected apps; `exec` was
an EL1h monitor command only. This card freezes slot 28 in the dispatch
table (the card's ONE ABI change, following the file slots-23/27 precedent;
every existing syscall number 0–27 stays frozen):

| 28 | `sys_exec` | `exec(path_ptr, path_len) -> i64` | Copy the `.BIN` name through uaccess, then run the EL1h loader (`exec.exec_file`) to load the program from the ESP into a FRESH process slot and spawn it at EL0. Returns the new process's pid on success (surfaced via `exec.last_exec_pid` — an EL0 launcher can hand it to `sys_wait` or a future `sys_kill`); `EINVAL` for a non-process caller (an EL1h task), an empty/over-long path, or a loader refusal (`.no_disk`, `.bad_magic`, `.bad_entry`, `.too_large`, `.no_args_room`, `.too_many_args`); `EFAULT` for a bad path pointer; `ENOENT` when the file is absent from the volume; `ENOSPC` for a capacity refusal (scheduler pool full, page allocator exhausted, page-table carve-out full, process registry full). No args in this row — a future amendment may add an argv block (the card-3e monitor form). |

`implemented_count` is now 29; the `syscalls` report prints rows 0–28.
The path crosses the claim-6120 uaccess window exactly like slot 23; the
loader itself is unchanged (the EL0 caller gets the SAME `exec_file` path
as the monitor command, so any program the EL1h shell can run, an EL0
program can run). A caller may exec a second program while its own window
stays up — the spawned process owns its own window slot (the G5
`user_windows_max` 4 covers up to four concurrent GUI apps).

The EL0 proof rides DESKTOP.BIN: its quick-launch buttons and Enter-on-
selection call `ui.exec_program(name)` (slot 28), and the class-B gate
`tools/verify-live-desktop.sh` types Enter after `desktop: menu ready` and
asserts `desktop: launch CALC.BIN`, the launched `calc: ready`, and
`28 sys_exec calls=1` in the `syscalls` report — the launcher is real.

As with slots 23–27, this is the Milestone 11/12 boundary's ABI amendment;
the ABI — x8 number, x0–x5 arguments, x0 result, reserved 29–63, error
codes — is otherwise unchanged. The loader stays in the milestone-three
card (`kernel/src/exec.zig`); this handler only marshals the path through
uaccess and calls through to it.

**Slot-allocation note:** Milestone 12's TCP seam (issue #148) originally
planned slots 28–31; slot 28 is now `sys_exec`, so the TCP plan moves to
slots 29–32 (the issue body is updated to match).

## Amendment (2026-08-15, claim 7604 — the EL0 termination seam card)

M11's A4 tracker claim called TOP.BIN a "click-to-kill process termination"
tool — but its Kill button only logged `top: kill requested` under a
"Future kill syscall" comment (the kernel's `kill` was an EL1h monitor
command only, claim 7786). This card freezes slot 29 in the dispatch table
(the card's ONE ABI change, following the `sys_exec` slot-28 precedent;
every existing syscall number 0–28 stays frozen):

| 29 | `sys_kill` | `kill(target_pid) -> i64` | Arm the target process's executor for termination from EL0 (the claim-7786 kill seam: `scheduler.request_kill` is a pure TCB write — the ring converts the target's NEXT selection into the existing exit path with the reserved status 137, flowing through the real exit → zombie → idle-reap → page-return lifecycle; the OS, not the program, owns process lifetime). Returns 0 once armed; `EINVAL` for a non-process caller (an EL1h task), an out-of-range / free / exited / no-executor target, or a scheduler-owned refusal (the shell or idle). Self-kill is allowed (the monitor's `kill` is equally general); a permanently blocked target keeps the EL1h kill's documented bound — the arm applies at the target's next selection, so a task blocked forever in `sys_wait_event`/`sys_wait` stays until woken. |

`implemented_count` is now 30; the `syscalls` report prints rows 0–29.
The handler validates the target through the process registry (the
`sys_wait` precedent for numeric targets) and calls through to the
claim-7786 seam — no new lifecycle machinery, no ABI change beyond the
frozen row.

The EL0 proof rides TOP.BIN: the process table auto-selects the first
RUNNING process, and the Kill button or `k`/`K` call `ui.kill_process(pid)`
(slot 29), printing `top: kill pid=<n>`. The class-B gate
`tools/verify-live-sys-kill.sh` execs COUNTER.BIN + TOP.BIN, types `k`
after `top: ready`, and asserts `top: kill pid=1`, NO `counter: alive`
after the kill, `tasks user-exec exited status=137` +
`procs COUNTER.BIN exited status=137` (the real lifecycle), and
`29 sys_kill calls=1` in the `syscalls` report — the EL0 kill, live.

As with slot 28, this is the Milestone 11/12 boundary's ABI amendment;
the ABI — x8 number, x0–x5 arguments, x0 result, reserved 30–63, error
codes — is otherwise unchanged. **The M12 TCP plan (issue #148) now runs
at slots 30–33** (28 `sys_exec`, 29 `sys_kill`, then TCP; the issue body
is updated to match).

## Amendment (2026-08-15, ADR 0012 — userland TCP socket seam)

Milestone 12 exposes the kernel's Milestone 5 TCP client to EL0 applications
through the ADR 0007 syscall seam (slots 30–33, following slot 28 `sys_exec` and slot 29 `sys_kill`):

| Slot | Name | Signature | Description |
|:---|:---|:---|:---|
| 30 | `sys_tcp_connect` | `connect(ip: u32, port: u16) -> i64` | Resolves peer MAC via ARP, initiates 3-way handshake to target IPv4:port, and blocks the caller on the scheduler sleep/event seam until `ESTABLISHED` or timeout (30 s). Returns `0` on success, or negative error code (`ECONNREFUSED` -6, `ETIMEDOUT` -7, `EINVAL` -1, `ENOTREADY` -5). |
| 31 | `sys_tcp_send` | `send(buf_ptr: [*]const u8, len: usize) -> i64` | Marshals payload (up to 64 bytes) via `uaccess.copy_in`, constructs TCP segment, and transmits. Returns bytes sent, or negative error code (`ENOTCONN` -5, `EFAULT` -3, `EINVAL` -1). |
| 32 | `sys_tcp_recv` | `recv(buf_ptr: [*]u8, max_len: usize) -> i64` | Drains the RX buffer via `uaccess.copy_out` (peek $\to$ copy $\to$ pop). Drains virtio-net device first (the N6 drain contract). Returns bytes received (0 if none pending / non-blocking EOF), or negative error code (`ENOTCONN` -5, `EFAULT` -3). |
| 33 | `sys_tcp_close` | `close() -> i64` | Initiates graceful FIN teardown (FIN $\to$ FIN-ACK $\to$ ACK) and returns connection to `closed`/`idle`. Returns 0 on success, or negative error code (`ENOTCONN` -5). |

`implemented_count` is 34; reserved slots become 34–63.
These handlers marshal arguments and user buffers through the claim-6120 `uaccess` window and invoke `kernel/src/tcp.zig`.
Proof program: `TCP.BIN` (`user/src/tcp_client.zig`, Issue #148).

### Amendment (2026-10-07, #2040 — bounded outbound connect)

Slot 30 retains its two-argument, singleton ABI; no new slot. For `ip != 0`,
x1 bits 0–15 are the nonzero destination port, bits 16–47 are an optional
unsigned **millisecond** timeout, and bits 48–63 must be zero (`EINVAL`
otherwise). A zero timeout retains the observed legacy **30-second** bound
and timeout result `EINVAL` (-1). Previously every word above `0xffff`
refused, so no formerly valid outbound argument changes meaning.
For `ip == 0`, x1 remains a plain port: timeout bits still refuse `EINVAL`.
Same-peer, owner-only idempotent reconnect and slots 31–33/76 are unchanged.

An explicit timeout expires with the existing `ETIMEDOUT` **-12**, not -7:
the original TCP table's -7 timeout label was never implemented; the modern
ABI assigns -7 to `EACCES` and -12 to `ETIMEDOUT`. Owner ruling on this card
preserves legacy -1 while giving explicit timeouts a distinct result.
RST/transport/argument refusals retain their existing errors. The fixed
retransmission ceiling still applies; if it aborts before a longer explicit
budget, the result is also -12.

The handshake budget starts before sending SYN and uses physical-counter
elapsed time, rounding the millisecond interval up to a counter tick. It
does not depend on scheduler IRQs, which the network service lock masks.
An unavailable/unrepresentable clock refuses `EINVAL` before SYN. A reply
drained after expiry cannot turn it into success. Expiry resets outbound
socket state (including owner, peer, ACK/RX and retransmission state),
preserves diagnostic counters, increments `timed_out`, and returns through
dispatch's network-lock release. No half-open singleton remains. This
does not make connect asynchronous or release the lock during the wait.
Dispatch's unlock defer now has function scope: its previous block scope
released service locks before the handler. The host connect test pins both
the held-in-handler and released-on-return sides of this existing contract.

`vi.DialTimeout(host, port, d time.Duration)` opts in. Positive durations
round up to milliseconds; nonpositive or more than `UINT32_MAX`
milliseconds refuse `EINVAL` before connecting. DNS keeps its separate
existing budget. `vi.Dial` and `vi.Listen` keep their old wire words.
Host TCP/syscall/SDK tests and `go-net` cover deadline boundaries, cleanup,
an isolated port that never answers SYN in **[5, 6) seconds**, immediate
successful reconnect, and the unchanged 30-second legacy default.
This prerequisite leaves #1998 open.

## Amendment (2026-08-16, claim 5801 — the mutating filesystem seam)

Milestone 13 card B1 turns the read-only M10 file ABI mutating — slots
34–37, following slot 33 `sys_tcp_close`:

| Slot | Name | Signature | Description |
|:---|:---|:---|:---|
| 34 | `sys_file_delete` | `delete(path_ptr, path_len) -> i64` | Delete the file at `path` (DATA by default; `/esp/` routes to the ESP). Frees the FAT cluster chain and marks the directory slot deleted. Returns 0; `EINVAL` bad path or a directory, `ENOENT` absent, `EFAULT` bad pointer. |
| 35 | `sys_file_rename` | `rename(old_ptr, old_len, new_ptr, new_len) -> i64` | Rename a file in place (same directory — cross-directory moves and cross-volume renames are refused). Returns 0; `EINVAL` bad path / target-exists (no EEXIST row — documented) / cross-directory, `ENAMETOOLONG` bad 8.3 name, `ENOENT` absent, `EFAULT` bad pointer. |
| 36 | `sys_file_truncate` | `truncate(handle, size) -> i64` | Resize the OPEN handle to `size` bytes (shrink truncates, grow zero-fills, ≤ 2048). Returns 0; `EBADF` bad/closed handle, `EACCES` not open for write, `ENOSPC` over-large, `ENOENT` absent. |
| 37 | `sys_file_free` | `free(volume) -> i64` | Free bytes on a volume (0 = DATA, 1 = ESP). Returns the byte count; `EINVAL` bad volume, `ENOENT` unmounted. |

`implemented_count` is 38; reserved slots become 38–63.
The handlers marshal paths through the claim-6120 `uaccess` window and
invoke `kernel/src/file_table.zig`'s new mutating ops, which sit on
`kernel/src/fat.zig`'s `delete_file`/`rename_file`/`truncate_file`/`free_space`.
Proof program: `FSTEST.BIN` (`user/src/fstest.zig`, issue #161); live gate
`tools/verify-live-fs-mutation.sh`. `FILE.BIN` grows Delete/Rename buttons
over slots 34/35.

## Amendment (2026-08-18, claim 0169 — the clipboard card)

Milestone 14 card S1 freezes slots 38/39 in the dispatch table (the card's
ONE ABI change, following slot 37 `sys_file_free`):

| Slot | Name | Signature | Description |
|:---|:---|:---|:---|
| 38 | `sys_clipboard_set` | `clipboard_set(buf_ptr, len) -> i64` | Copy `len` bytes from the caller's region through uaccess into the ONE shared kernel clipboard (`kernel/src/clipboard.zig`, a fixed 512-byte BSS buffer — `len` > 512 is truncated honestly, the ipc/udp truncation pattern). Returns the stored length (0 clears); `EINVAL` for a non-process caller, `EFAULT` for a bad pointer. |
| 39 | `sys_clipboard_get` | `clipboard_get(buf_ptr, max) -> i64` | Copy the current clipboard contents OUT through uaccess WITHOUT consuming them (a clipboard is a shared, non-destructive read — unlike the mailbox's recv). Returns the copied length (0 when empty, `max` > 512 clamps); `EINVAL` for a non-process caller, `EFAULT` for a bad buffer on a non-empty clipboard. |

`implemented_count` is now 40; reserved slots become 40–63 (S2 later adds
40/41). The handlers marshal bytes through the claim-6120 uaccess window;
NOTEPAD gains Copy/Cut/Paste (Ctrl+C/X/V over the whole buffer) and the
monitor gains the `clip` command (`clip <text...>` sets it, `clip` prints
it) as the EL1h half of the same buffer.

**M97g amendment (2026-10-15, #2082 — programmatic clipboard requires
`CAP_CLIPBOARD` or the registered seat).** The audit observed slots 38/39
were process-gated only: any EL0 app could silently harvest or overwrite
the machine-global buffer the user pastes from. Both slots now return
`EACCES` unless the caller's principal holds `CAP_CLIPBOARD`
(`process.cap_clipboard`, bit 2 of the spawn-time mask, bundled into
`kernel_caps`; there is no EL0 elevation path, so only monitor `-u0`
spawns qualify) OR the caller is the kernel-registered WM seat — the seat
owns the raw input fan-out and renders the tray's clipboard indicator, so
its probe is user-mediated by construction. The refusal precedes argument
validation (no EFAULT/empty probes). The user-gesture paths are unchanged:
the chrome copy/paste chords (`terminal.copySelectionToClipboard`
/`pasteFromClipboard`) and the monitor `clip` command are kernel-internal
callers that never enter these handlers, so paste remains user-mediated
for every app.

## Amendment (2026-08-18, claim 7323 — the application-timer card)

Milestone 14 card S2 freezes slots 40/41 in the dispatch table (following
slot 39 `sys_clipboard_get`):

| Slot | Name | Signature | Description |
|:---|:---|:---|:---|
| 40 | `sys_timer_set` | `timer_set(delay_ticks) -> i64` | Arm the CALLING process's ONE app timer to fire a single `TIMER` event (kind 9) into its ADR 0009 event queue after `delay_ticks` SCHEDULER ticks (the `sys_sleep` clock — 1 s on VZ). `delay_ticks` 0 clamps to 1 (the `sys_sleep` minimum); an over-long delay truncates honestly at the 3600-tick kernel bound; re-arming replaces any pending timer. Returns 0; `EINVAL` for a non-process caller. |
| 41 | `sys_timer_cancel` | `timer_cancel() -> i64` | Disarm the calling process's app timer. Returns 1 if a pending timer was canceled, 0 if none was armed; `EINVAL` for a non-process caller. |

`implemented_count` is now 42; reserved slots become 42–63 (S3/S4 do not
add slots). The facility is `kernel/src/app_timers.zig`: fixed BSS arrays
(armed flag + countdown + counters), one slot per process, zero heap. The
fire is driven from `scheduler.on_tick` (the same host-testable tick seam
that wakes sleepers) — each tick counts an armed timer down and posts the
`TIMER` event through `events.push`, which wakes a task blocked in
`sys_wait_event` via the existing `on_event_pushed` hook. Process lifecycle
resets the slot on create/exec/exit. Proof program: `TIMER.BIN`
(`user/src/timertest.zig`, issue #176); live gate
`tools/verify-live-timers.sh`.

## Amendment (2026-08-18, claim 7636 — the EL0 audio-seam card)

Milestone 15 card A3 freezes slots 42/43 in the dispatch table (following
slot 41 `sys_timer_cancel`):

| Slot | Name | Signature | Description |
|:---|:---|:---|:---|
| 42 | `sys_audio_info` | `audio_info(out_ptr) -> i64` | Copy the device's NEGOTIATED playback state out through uaccess as a fixed **16-byte** `AudioInfo` {`ready`, `format`, `rate`, `channels`, `period_bytes`, `max_len`} (this row said "24-byte" for three milestones — erratum corrected with M58e, issue #1328: `kernel/src/virtio_snd.zig` has always been `@sizeOf == 16`, as the frozen WAT contract §5.3 recorded). The FIRST call drives the probe + `SET_PARAMS` negotiation itself (before any play, the app must learn what to synthesize); later calls report the cached state. Returns 0; `EINVAL` for a non-process caller, `EFAULT` for a bad buffer. |
| 43 | `sys_audio_play` | `audio_play(buf_ptr, len) -> i64` | Play `len` bytes of PCM samples (the format/rate/channels reported by slot 42) through the virtio-snd TX queue: uaccess copy-in in bounded 4096-byte periods (zero heap), the A2 control flow (INFO → SET_PARAMS → PREPARE → START → submit/drain per period → STOP → RELEASE), every drained byte counted. Returns the bytes played; `EINVAL` for a non-process caller or zero length, `ENAMETOOLONG` over the 64 KiB `audio_max_len` bound, `EFAULT` for a bad pointer, `ENXIO` when no sound device is attached (the default VM) or a device-level refusal. |

`implemented_count` is now 44; reserved slots become 44–63. The backend is
`kernel/src/virtio_snd.zig`'s proven A1/A2 path (the sound device is
`--sound`-flag-gated on the host, so the default VM is untouched and the
seam reports `ENXIO` there). Proof program: `JINGLE.BIN`
(`user/src/jingle.zig`, card A3); live gate
`tools/verify-live-sound-app.sh`.

## Amendment (2026-08-18, claim 9297 — the stream-state control)

M15 follow-up freezes slots 44/45 in the dispatch table (following slot 43
`sys_audio_play`):

| Slot | Name | Signature | Description |
|:---|:---|:---|:---|
| 44 | `sys_audio_volume` | `audio_volume(vol) -> i64` | Set the bounded kernel-side stream gain (0..100 percent) applied to every period `sys_audio_play` submits — the same choke point `beep` and the boot chime share. Pure kernel state (works without a device; a later `--sound` attach inherits it). Returns the volume on success; `EINVAL` for a non-process caller or an out-of-range value (honest refusal, no silent clamping). |
| 45 | `sys_audio_mute` | `audio_mute(muted) -> i64` | Set the kernel-side mute state (1 = silent; zeroed samples still drain — the stream lifecycle and accounting are untouched). Returns 0 on success; `EINVAL` for a non-process caller or a value that is not 0/1. |

`implemented_count` is now 46; reserved slots become 46–63. The monitor
half is `sound volume <0-100>` / `sound mute <on|off>` on the existing
`sound` command (the report shows `vol=`/`mute=`); the EL0 half rides the
same `kernel/src/virtio_snd.zig` state. Proof program: CHIME.BIN calls
both slots (vol=50, unmuted) before its first blip — the composition
session proves the seam mutated kernel state; live gate
`tools/verify-live-sound-control.sh`.

## Amendment (2026-08-28, claim 1484 — the WMS1 render-server reservation)

Milestone 32 card WMS1 accepts ADR 0015 (window-server render seam) and
freezes slot 65 `sys_wmctl` — the WM server's exclusive control surface over
the kernel render server (following slot 64 `sys_munmap`; every existing
syscall number 0–64 stays frozen):

| 65 | `sys_wmctl` | `wmctl(cmd, a0, a1, a2, ptr, len) -> i64` | The registered WM server's control surface over the kernel render server (ADR 0015 seam A). Subcommands below; `ptr/len` are reserved for descriptor payloads (first used by SET_WINDOW chrome descriptors, WMS4). Calls from any process other than the registered WM return `EACCES`; with no WM registered, every call returns `ENOSYS`; an unknown `cmd` returns `EINVAL`. Reserved until the WMS2 claim registers the handler — until then slot 65 is not in `dispatch_table` and a call returns `-ENOSYS` naturally (the ADR 0013 reserved posture). |

### Slot-65 subcommand encoding (frozen by this amendment)

`cmd` values (x0), with argument mapping for x1–x5 (`a0..a2` + `ptr` + `len`):

| cmd | Name | Value | Args | Returns | Errors |
|:----|:-----|:-----:|:-----|:--------|:-------|
| REGISTER | `WMCTL_REGISTER` | 1 | all reserved (0) | 0 = registered | `EACCES` seat taken; `ENXIO` no gpu / unarmed compositor; `EINVAL` non-process caller |
| SET_WINDOW | `WMCTL_SET_WINDOW` | 2 | a0 = window id, a1 = packed rect (x\|y<<16), a2 = packed wh (w\|h<<16); `ptr` → chrome descriptor (WMS4; 0 = none), `len` = descriptor length | 0 = accepted | `EACCES` caller not the WM; `EINVAL` bad id/rect/len |
| REQUEST_PRESENT | `WMCTL_REQUEST_PRESENT` | 3 | all reserved (0) | 0 = present scheduled | `EACCES` caller not the WM |
| SET_STATE | `WMCTL_SET_STATE` | 4 | a0 = window id (or `0xFFFF_FFFF` for the ALL workspace broadcast), a1 = visible (bits 0–1) \| workspace << 8 \| always-on-top bit 16 | 0 = applied | `EACCES` caller not the WM; `EINVAL` bad id / workspace / visibility |
| ALT_TAB | `WMCTL_ALT_TAB` | 5 | a0 = window id, a1 = action (1 activate, 2 cycle, 3 commit, 4 dismiss) | 0 = applied | `EACCES` caller not the WM; `EINVAL` bad id / action |
| NOTIF_CENTER | `WMCTL_NOTIF_CENTER` | 6 | a0 = 0 close / 1 open / 2 clear-all | 0 = applied | `EACCES` caller not the WM; `EINVAL` bad action |
| NOTIF_DISMISS | `WMCTL_NOTIF_DISMISS` | 7 | a0 = row index | 0 = applied | `EACCES` caller not the WM; `EINVAL` out-of-range index |
| TOOLTIP | `WMCTL_TOOLTIP` | 8 | a0 = 0 hide / 1 show (show: `ptr/len` carry the text, ≤ 32 bytes) | 0 = applied | `EACCES` caller not the WM; `EINVAL` bad action / over-length; `EFAULT` bad text pointer |
| DOCK | `WMCTL_DOCK` | 9 | a0 = icon index (0–4) | 0 = applied | `EACCES` caller not the WM; `EINVAL` out-of-range icon |
| TRAY | `WMCTL_TRAY` | 10 | a0 = flags (bit 0 clock, bit 1 theme, bit 2 clipboard); a1 = 5-byte `HH:MM` clock text packed LE; a2 = theme letter (low byte) \| clipboard filled (bit 8) | 0 = applied | `EACCES` caller not the WM; `EINVAL` unknown flag bits / non-`HH:MM` clock char / theme outside `D`/`L`/`A` |

Unknown/zero `cmd` → `EINVAL`. `REGISTER` is one-seat: a second registration
refuses `EACCES`; the registered pid is observable in the monitor's `wm`
report (WMS2).

### Amendment (2026-08-29, claim 2491 — the WMS4 chrome-descriptor freeze)

`SET_WINDOW` (cmd 2) now takes the **chrome descriptor** whose layout this
amendment freezes, defined in `kernel/src/wnd_core.zig` (`ChromeDesc`, 40
bytes = 10 × u32, no pointers, per the issue's bounded-struct rule):

| Offset | Field | Meaning |
|-------:|-------|---------|
| 0 | `kind_mask` | element bitmask: BORDER=1, TITLE=2, CLOSE=4, MINIMIZE=8, PIN=16, RING=32 |
| 4 | `flags` | per-window flags (bit 0 = FOCUS_ACCENT) |
| 8 | `border_focus_rgb` | 0xRRGGBB |
| 12 | `border_unfocus_rgb` | 0xRRGGBB |
| 16 | `title_bg_rgb` | 0xRRGGBB |
| 20 | `title_fg_rgb` | 0xRRGGBB |
| 24 | `ring_rgb` | focus-ring color |
| 28 | `close_rgb` | close-glyph color |
| 32 | `minimize_rgb` | minimize-glyph color |
| 36 | `pin_rgb` | pin-glyph color |

`a0 = 0xFFFFFFFF` broadcasts the WM's chrome POLICY (applied to every
user window and inherited by windows created later); a specific id sets
that window's override (unknown id → `EINVAL`). Unknown kind bits / flag
bits → `EINVAL`; `len` is 0 (no chrome change) or 40 (the descriptor),
anything else → `EINVAL`. While a WM is registered, `REQUEST_PRESENT`
composites with `draw_chrome` painting from descriptors; with no WM, the
shim's own rules paint byte-identically to pre-M32 (one
registration-flag branch in driving_award).

#### M91f amendment (2026-10-05, #1976): per-window no chrome

A per-window descriptor with `kind_mask = 0` disables all kernel chrome,
including borders, title, buttons, shadows and the focus ring. The
`a0 = 0xFFFFFFFF` broadcast still refuses zero with `EINVAL`. Nonzero
kinds, command numbers, descriptor fields and lengths are unchanged.
GOTABWM installs this override before publishing a hosted tab; its first
hosted layout paints the legacy client opaque so native-frame pixels
cannot survive through the opening fade. Seat-owned windows keep their
own nonzero descriptors. Owner approval: #1976 comment 5994413955.

### Amendment (2026-08-29, claim 9849 — the WMS5 rect activation)

The `a1`/`a2` geometry encoding reserved in the row above ACTIVATES: the
WM proposes a window rect (`a1` = x|y<<16, `a2` = w|h<<16, framebuffer
pixels) and the kernel applies it through the existing clamped
`user_move`/`user_resize` — WM proposes, kernel clamps + blits. A nonzero
`a1` or `a2` means geometry; a call may carry rect and/or chrome (len 0
or 40). The `a0 = 0xFFFFFFFF` broadcast stays chrome-only — geometry is
per-window (a rect on the broadcast → `EINVAL`). The input seam behind
it: while a WM is registered the kernel stops consuming pointer GEOMETRY
and fans the raw stream (kind 19 `WM_POINTER`) + registry mirrors (kind
20 `WM_WINDOW`) out to the WM (ADR 0009 D2); the WM hit-tests and issues
SET_WINDOW rects. Shims never see any of this (no WM registered →
byte-identical pre-WMS5 behavior; the W1–W16 gates stay green untouched).

`implemented_count` becomes 66 when WMS2 registers the handler (this
amendment reserves the row; the `syscalls` report prints rows 0–64 until
then). Proof program and live gate ride the WMS2 claim
(`tools/verify-live-wmctl-register.sh`).

As with slots 63/64, this is the milestone-32 set's ABI amendment; the ABI —
x8 number, x0–x5 arguments, x0 result, reserved 66–127 (later 67–127 after
#1058), error codes — is
otherwise unchanged. (`slot_count` is already 128, so "reserved 66–127" is
the true remaining space — the 128-wide table has been live since M16; this
amendment writes the honest bound.)

#### M97g amendment (#2079): REGISTER eligibility + SEAT_PID (cmd 16)

`REGISTER` is a privilege: it arms the raw key/pointer fan-out and the
writable scanout bind. It is therefore gated on kernel-recorded spawn
provenance — never on a caller-chosen process name, which any EL0 exec
can forge. A caller may register iff:

* it holds `cap_proc_admin` (the operator's `exec -u0` channel), or
* its task was allocated in kernel context (`spawned_by == null` — boot
  autostart, monitor `exec`), or
* it is a launcher child — a direct `sys_exec` child of a kernel-spawned
  process (INIT's service spawn) — AND its process name is the configured
  seat program (`wm` setting: `GOTABWM.ELF` or `TABWM.BIN`).

Every other caller is refused `EACCES` before the fan-out hooks arm; the
existing `EACCES` (seat taken) / `ENXIO` (no GPU) / `EINVAL` (non-process)
refusals are unchanged and checked first.

| SEAT_PID | `WMCTL_SEAT_PID` | 16 | all reserved (0) | the registered WM pid | `ENOENT` no seat held |

`SEAT_PID` is the seat's pid-discovery query: unlike every other
subcommand it is NOT seat-gated — it answers the kernel's register so
WM_RPC clients bind to the kernel's record instead of resolving a
forgeable name through `sys_procs`. With no WM registered it returns
`ENOENT` (not `ENOSYS`): the query itself is implemented either way.

### Amendment (2026-08-29, claim 4278 — the WMS5 Gate-2 SET_STATE channel)

Gate 2 activates the **state half of the geometry seam**. `SET_STATE` (cmd 4)
`a1` encoding: bits 0–1 carry the visibility request — `0` = hidden
(minimize), `1` = shown (restore), `2` = unchanged (no visibility effect) —
bits 8–15 carry the destination workspace, and bit 16 sets always-on-top
(1 = on). The kernel applies visibility/workspace through the same clamped
primitives the shim uses (`user_set_visible` + move-to-workspace), so the WM
cannot escape the kernel's geometry bounds. `a0 = 0xFFFF_FFFF` is the one
broadcast form — a GLOBAL workspace switch (the WM's Ctrl+F1-3 / Alt+`
channels), refusing any per-window payload on the broadcast (`EINVAL`). The
keyboard input seam it rides: while a WM is registered the kernel fans the
raw key stream (kind 21 `WM_KEY`, ADR 0009 D2) out — the kernel's own
keyboard geometry consumers are gated behind `!wm_owns_input` — and the WM
decides tile/snap/workspace/minimize/maximize, issuing SET_WINDOW rects
(cmd 2) + SET_STATE state (cmd 4). No WM registered → shim byte-identical.

### Amendment (2026-08-29, claim 4510 — the WMS6 Gate-A ALT_TAB channel)

The first desktop-chrome surface to leave the kernel is the read-mostly,
keyboard-driven **Alt+Tab** (issue #626). `ALT_TAB` (cmd 5) is the exact
overlay state machine the kernel shim runs — `a1` 1 activate, 2 cycle,
3 commit, 4 dismiss — but driven by the WM's chosen window id (`a0`). On
commit (3) the kernel `focus(a0)` + `raise(a0)` + dismisses the overlay; on
activate/cycle (1/2) it builds the snapshot and highlights `a0`. The kernel
clamps: `a0` must name a live user window (commit) or a live alt-tab target
(activate/cycle — the M21 W3/W4 visible/non-minimized/current-workspace
rules), else `EINVAL`. The Alt+Tab input path it rides: while a WM is
registered the kernel fans the raw Alt+Tab chord to the WM (kind 21 `WM_KEY`
with `MOD_ALT`), its own `alt_tab_pending` is gated behind `!wm_owns_input`,
and the WM decides the target from its kind-20 mirror registry via the shared
wnd_core rule, issuing `ALT_TAB commit`. No WM registered → shim byte-identical.

### Amendment (2026-08-29, claim 7557 — the WMS6 Gate-B NOTIF_CENTER channel)

The second desktop-chrome surface to leave the kernel is the flagship **click-driven**
notification center (issue #626). `NOTIF_CENTER` (cmd 6) `a0` = 0 close / 1 open /
2 clear-all — the kernel sets `notif_center_open` / clears the ring through the same
`notif_center_set_open`/`notif_center_clear_all` primitives the shim uses (clamped, and
the panel blits from `notif_center_open` + the ring). `NOTIF_DISMISS` (cmd 7) `a0` = row
index dismisses one notification (an out-of-range index is `EINVAL`, no silent no-op). The
tray-click input path it rides: while a WM is registered the kernel fans the raw pointer
click (kind 19 `WM_POINTER` carries the HID button byte) out, its OWN tray-click
toggle + panel dismiss/clear are gated behind `!wm_owns_input`, and the WM hit-tests the
tray (the same `fb_w - 80` slice as `tray_rect`), decides, and issues `NOTIF_CENTER`.
No WM registered → shim byte-identical.

### Amendment (2026-08-29, claim 6154 — the WMS6 Gate-C TOOLTIP channel)

The third desktop-chrome surface to leave the kernel is the **read-mostly hover
chrome**: the tooltip (issue #626). The M27 G6 tooltip was a DORMANT stub (nothing ever
called `tooltip_set`); Gate C activates it under WM ownership. `TOOLTIP` (cmd 8) `a0` =
0 hide / 1 show; for show, `ptr/len` carry the text (≤ 32 bytes — the M27 bound, copied
in like the chrome descriptor; `EFAULT` bad pointer, `EINVAL` over-length). The kernel
applies through `tooltip_clear` / a new immediate `tooltip_show` (the WM owns the
hover-dwell policy by choosing WHEN to show) and blits the box below its own cursor. The
hover input path: while a WM is registered the kernel fans the raw hover (kind 19
`WM_POINTER` carries absolute moves) out, and the WM hit-tests the tray, decides what the
tooltip says, and issues `TOOLTIP`. The kernel never self-triggered a tooltip and still
doesn't; no WM registered → the dormant shim stays dormant.

### Amendment (2026-08-29, claim 9197 — the WMS6 Gate-D DOCK channel)

The fourth desktop-chrome surface to leave the kernel is the **dock** (issue #626, M15
C4). `DOCK` (cmd 9) `a0` = icon index (0–4) — the WM maps a dock click to the icon; the
kernel applies through `dock_icon_click` which is the shim's EXACT clamped chain
(restore the first minimized user window, else focus + raise a user window, else open
one), so a WM decision and a shim click are identical actions. The dock-click input path:
while a WM is registered the kernel fans the raw click (kind 19) out and its own
dock-click handler gates behind `!wm_owns_input`. The dock is also the first real
hover-label consumer of cmd 8 (TOOLTIP): the WM issues the icon's label on hover, and
the kernel's blanket tooltip-clear-on-move gates behind `!wm_owns_input` so it cannot
fight the WM's hide decisions. No WM registered → shim byte-identical.

### Amendment (2026-08-29, claim 3744 — the WMS6 Gate-E TRAY channel)

The fifth — and final — desktop-chrome surface to leave the kernel is the **tray
widget content** (issue #626): the clock string, theme letter, and clipboard indicator.
Before this gate the tray froze while a WM was registered: the shell idle's `drain`
(which refreshed the clock from the 1 Hz tick counter) is gated off when a WM is
registered, so the WM had no way to keep it alive. `TRAY` (cmd 10) closes that gap —
the WM declares the widget content, `a0` = flags (bit 0 clock, bit 1 theme, bit 2
clipboard), `a1` = the 5-byte `HH:MM` clock text packed little-endian, `a2` = theme
letter (low byte, clamped to `D`/`L`/`A`) | clipboard filled (bit 8). Each field is
OPTIONAL (a flag bit missing leaves that widget on the shim fallback); the kernel
clamps + stores + marks the taskbar dirty, and the render is source-selected —
WM-declared values when a `_set` flag is true, shim-derived otherwise (no WM →
byte-identical). WM teardown (`clear_wm_chrome`) resets the `_set` flags so the shim
fallback re-derives all three. The WM refreshes at its own cadence (every 10 ticks =
10 s), reformatting the clock from its own 1 Hz tick counter via the same
minute-rollover formula the shim's `format_hhmm` uses (parity by value) and probing the
clipboard via `sys_clipboard_get` (slot 39). This closes WMS6: all five issue-626 chrome
surfaces (alt-tab, notification center, tooltip, dock, tray) now drain into WND.BIN.

## Amendment (2026-08-30, claim 7418 — the M33 SB1 shared-anon flag reservation)

Milestone 33 card SB1 (ADR 0016, ACCEPTED by this claim) freezes the ABI binding
for seam-B cross-process shared anonymous mmap. The encoding is a **flag on the
existing `sys_mmap` (slot 63)** — NOT a new syscall slot — following the
map-vs-new-slot resolution recorded in D1. The dispatch table stays 128 rows and
every existing syscall number 0–65 stays frozen.

### `sys_mmap` (slot 63) flags — new reserved bit

The flags argument of `sys_mmap` gains one reserved bit:

| Bit | Value | Name | Meaning |
|----:|------:|------|---------|
| 15 | `0x8000` | `MAP_POPULATE` (existing, M29) | eager per-page allocation |
| 5 | `0x0020` | `MAP_ANONYMOUS` (existing, M29) | anonymous (non-file) region |
| 1 | `0x0002` | `MAP_PRIVATE` (existing, M29) | private copy semantics |
| **16** | `0x10000` | **`M33_MAP_SHARED` (RESERVED by claim 7418)** | request a CROSS-PROCESS shared-anonymous surface (ADR 0016 seam B) |

`M33_MAP_SHARED` is **reserved, not yet implemented**: until the claim-7418
follow-on SB2 wires the handler, a `sys_mmap` call carrying bit 16 still behaves
as the M29 per-process mmap behaves today (the SB1 contract card does NOT touch
`syscall.handle_mmap` behavior). SB2 interprets the bit: allocate the physical
pages once, create a `shared_region.SharedRegion` descriptor (kernel-issued
integer handle, `max_shared_regions` = 8 BSS), map an EL0-RO `sw_cow` leaf into
the registered WM server's root, and keep the owner's writable leaf — with the
D2 grant/revoke rules frozen in `kernel/src/shared_region.zig` (6 host tests).

**Error contract (SB2, following ADR 0016 D2 + the shared_region Grant table):**
- `EINVAL` — a requestor other than the surface owner asks with a WRITABLE view
  (`.writable_refused`), or the flag is used with an inapplicable `prot`/geometry.
- `EACCES` — a requestor other than the owner tries to RE-MAP a peer region
  they are not authorized to read (`.not_authorized`).
- `ENOSPC` — the `shared_region` table is full (`.capacity`, region already at
  `max_shared_regions`).
- `EFAULT` — a stale/revoked handle is re-mapped after the owner tore it down
  (`.gone`).

**Lifetime/revocation (frozen, host-tested in `shared_region`):** the owner is
NOT counted in the read refcount (its writable map is the region's creation side
and dies with the owner); reads are counted; owner teardown (`win_close` /
`sys_exit`) revokes EVERY peer RO leaf and frees the descriptor at refcount 0 —
a stale WM mirror cannot retain access past that point.

The ABI — x8 number, x0–x5 arguments, x0 result, reserved 67–127, error codes —
is otherwise unchanged. No dispatch-table row is added; this amendment only
resolves how seam B attaches to the frozen `sys_mmap` row.

---

## Amendment (2026-08-31, claims 8878 + 3633 — shared-anon IMPLEMENTED + window surface tag)

The M33 seam-B shared-anonymous flag is now **implemented**, not just reserved.

- **SB2 (claim 8878):** `M33_MAP_SHARED` (bit 16, `0x10000`) on `sys_mmap`
  (slot 63): owner `MAP_ANON|SHARED` allocates one contiguous region, maps
  WRITABLE leaves into the owner's root, registers a `SharedRegion` (kernel
  integer handle, `max_shared_regions` = 8 BSS). A registered WM attaches RO by
  handle (`addr=<handle>, prot=R, SHARED`) → `authorize_read` (D2: non-owner RO
  only) → `ref_page` → EL0-RO `sw_cow` in the WM's OWN root (`shared_mmap`,
  wired into the scheduler exit seam). Owner munmap/exit revokes the WM view.
  Live gate `verify-live-sb2-shared-anon.sh` PASS (headless VZ).
- **SB3 (claim 3633) — NEW reserved bit:** the `addr` argument carries a
  window-binding tag at bit 63, `M33_SURF_WIN_TAG` = `0x8000_0000_0000_0000`.
  `sys_mmap(addr = M33_SURF_WIN_TAG | window_id, len, prot, MAP_ANON|SHARED)`
  binds the named user window to a shared surface (back-buffer): the owner gets
  its writable leaves, a registered WM auto-mirrors RO, and `composite()` blits
  from the surface's `pa_base`. The frozen `sys_win_open`/`fill`/`present`
  slots (12–14) stay byte-identical for unmigrated apps; `sys_win_fill` routes
  into the surface when a window is bound. Live gate
  `verify-live-sb3-surface-handoff.sh` PASS (headless VZ): a migrated app stored
  `0xAB` with a plain write and the registered WM read it RO.

The dispatch table stays 128 rows; all numbers 0–66 and the error codes are
unchanged.

**M33 SB4 (claim 2382, 2026-08-31):** the COMPOSITE_TICK (kind 18) event is
redefined from `arg1 = 0 (reserved)` to `arg1 = per-surface damage bitmask`
(bit i <=> user surface i + `user_window_id_base`) — the WM's damage-notify
payload. No dispatch-table row changes; no new slots; `sys_win_fill`/`present`
stay frozen.

**M33 SB5 (claim 7397, 2026-08-31):** a second `sys_mmap` addr-tag —
`M33_SURF_SCAN_TAG` = `0x4000_0000_0000_0000` (bit 62, distinct from the SB3
window tag at bit 63). `sys_mmap(addr = M33_SURF_SCAN_TAG, len = fb_size,
prot & PROT_WRITE, MAP_ANON|SHARED)` by the REGISTERED WM maps the virtio-gpu
framebuffer WRITABLE into its own root (the compose-N target). WM seat only
(EACCES otherwise), full-frame only (EINVAL), writable required (EINVAL), no
framebuffer → ENXIO; idempotent. The GPU fb pages are kernel-owned — mapped
without ref, torn down (WM exit / full-frame munmap) without unref. The final
present: REQUEST_PRESENT (slot 65 cmd 3) is now FLUSH ONLY — the kernel paints
its layer at COMPOSITE_TICK time (`paint_scene`), the WM's compose-N stores
land after, and the present flushes (the kernel never re-paints over the WM's
stores). No dispatch-table row changes; no new slots.

### Amendment (2026-09-10, #1058 — slot 66 `sys_time`, the boot wall clock)

The first post-M32 slot: **66** = `sys_time()`, no arguments, returning the
current Unix wall-clock seconds as `u64` (the boot loader's EFI
`RuntimeServices.GetTime` epoch, carried in the v3 handoff, advanced by the
1 Hz timer ticks), or `ENOSYS` (`-4`) when the firmware provided no clock.
The choice of a real syscall over piggybacking the `sys_wmctl` query seam is
deliberate: the epoch is general-purpose (any app may timestamp), not a WM
concern, and `implemented_count` becomes **67** (rows 0–66; reserved
67–127). No existing number, argument, result, or error code changes; the
bad-handoff/handoff unit tests and ADR 0004 D5 carry the v3 handoff shape.
The wire epoch is a *wall-clock* epoch (the EFI broken-down fields treated
as written), so `sys_time() % 86400` is local seconds since midnight — the
TABWM tray's face — and the full value is monotonic + date-correct for
timestamping. Verified class-A by `boot/src/efi_time.zig` (days-from-civil
against known dates) and the timer/syscall unit tests; class-B by the live
TABWM boot reporting `tabwm: clock-source kernel`.

### Amendment (2026-09-11, #1072 — slot 67 `sys_tty_attach`, the terminal seam)

The terminal seam (ADR 0020) adds exactly one slot: **67** =
`sys_tty_attach(front_end)`. `a0`: `0` = detach the CALLING process's
controlling terminal, `1` = attach it to the serial console (the kernel
console) as a front-end; `2`/`3` (window/net front-ends) return `ENOSYS`
until they land. The process must have opened `/dev/tty` (else `EINVAL`); the
console is held by at most one terminal (busy ⇒ `EACCES`); a bad selector is
`EINVAL`. Terminal I/O itself adds **no** slot — it reuses the frozen
`sys_file_open`/`sys_file_read`/`sys_file_write` (23/24/25) against the
`/dev/tty` virtual device. `implemented_count` becomes **68** (rows 0–67;
reserved 68–127). No existing number, argument, result, or error code changes.
Verified class-A (terminal/seam/syscall host tests) and class-B
(`live-ttyecho`: an EL0 pilot opens `/dev/tty`, attaches the console, and
echoes a scripted line back through the serial log).

### Amendment (2026-09-11, #1135 — slot 68 `sys_principal`, the principal report)

M50 TS1 (ADR 0024 D2/D10) adds the trust milestone's first slot: **68** =
`sys_principal(buf)`, copying the CALLING process's principal
`{ u32 uid, u32 caps }` (8 bytes, little-endian) OUT through uaccess and
returning `principal_bytes` = **8** on success. It is
strictly **read-only**: the kernel assigns a process's uid/caps at
`process.create` (default `uid_user = 1000`, no caps), `exec` preserves them,
and there is no syscall that can set or raise either (ADR 0024 D2/D5).
`EINVAL` for a non-process caller (an EL1h task); `EFAULT` for a bad buffer.
`implemented_count` becomes **69** (rows 0–68; reserved 69–127). No existing
number, argument, result, or error code changes; the 40-byte `sys_procs`
snapshot row is byte-frozen (identity is additive, not a wire change). The
EL1h monitor's `procs` report gains `uid=`/`caps=` columns read from the SAME
descriptor field. Verified class-A (process/exec/syscall host tests) and
class-B (`live-trust-whoami`: `whoami`/`id` agree with the monitor's `procs`
row).

### Amendment (2026-09-11, #1136 — slot 69 `sys_file_mode`, the ownership/mode seam)

M50 TS2 (ADR 0024 D3/D4/D8/D10) adds the trust milestone's second slot:
**69** = `sys_file_mode(path_ptr, path_len, mode)`. Owner-only `chmod` on an
existing path, or `CAP_FS_ANY`; `chown` is **not** in scope (ADR 0024 D10).
`mode` is the 3-digit octal `rwxrwxrwx` value; the group triplet is reserved
and normalized to zero (single-user — no groups, ADR 0024 D3). Returns 0 on
success; `EINVAL` for a non-process caller, a bad/traversal path, or an
out-of-range mode; `EACCES` when the caller is not the owner or the path is
secret-class for a denied op, or for the fixed read-only `.usb`; `ENOENT`
when the path is absent or no host channel is armed; `ENOSPC` when the
64-entry ownership table is full (never silent eviction); `EFAULT` for a bad
path pointer.

The metadata lives in `kernel/src/trust.zig` (ADR 0024 D3): a bounded
64-entry BSS table keyed by the `parse_path`-normalized `(Partition, path)`
pair and persisted as `OWNERS.TXT` (`#v1`, one
`path<TAB>mode<TAB>uid<TAB>flags` line per entry). Every `file_table` entry
point (`open`/`read`/`write`/`delete`/`rename`/`truncate`/`dir_list`) calls
the single `trust.check(actor, partition, path, want)` predicate after
`parse_path` and before any `virtio_file` access; every direct
`virtio_file` consumer declares an explicit `kernel_actor()`. Malformed or
unknown-schema `OWNERS.TXT` lines fail closed (they deny their path, never
default). Keys compare case-insensitively (the host share may be
case-insensitive) while `OWNERS.TXT` preserves the authored spelling.
`implemented_count` becomes **70** (rows 0–69; reserved 70–127). No existing
number, argument, result, or error code changes. Verified class-A (the
`trust.zig` allow/deny matrix, default policy, fail-closed malformed
entries, table-full `ENOSPC`, `OWNERS.TXT` round trip, and the case-key
decision; the extended syscall/monitor table tests) and class-B
(`live-trust-modes`: EL0 `cat` → `EACCES`, owner `chmod` persists an
`OWNERS.TXT` the host inspects, the monitor `vf cat` of a secret is denied,
and the secret value never appears in the transcript).

### Amendment (2026-09-11, #1139 — slot 70 `sys_secret_get`, the secret store reader)

M50 TS5 (ADR 0024 D8/D10) adds the trust milestone's third slot: **70** =
`sys_secret_get(buf, len)`, copying the CALLING principal's entries from the
`SECRETS.TXT` secret store into caller memory as fixed `SecretRecord`s
(`{ u32 uid, u32 key_len, u32 val_len, [32]u8 key, [64]u8 val }`, 108 bytes —
`key_len`/`val_len` bounds 32/64 mirror the settings engine; 64 chars hold a
32-byte key or Ed25519 seed in hex exactly). Returns the byte length written
(a multiple of 108), 0 when the principal owns nothing, `EINVAL` for a
non-process caller or a buffer too small to hold every caller entry, and
`EFAULT` for a bad buffer. It is the ONLY in-guest reader of the secret
store; there is deliberately NO `sys_secret_set` (provisioning is host-side;
a non-echoing set path is deferred per D8). `sys_secret_get` and the
reserved-for-TS4 slot 71 `sys_tty_net_auth` are excluded from strace
argument/return tracing — the never-logged contract (secret values never
reach the serial transcript, `HISTORY.TXT`, `ENV.TXT`, monitor
`settings`/`vf` output, `sys_procs` snapshots, crash tombstones, or strace;
the monitor and the EL0 `secrets` builtin print key NAMES only).
`implemented_count` becomes **71** (rows 0–70; reserved 71–127). No existing
number, argument, result, or error code changes. Verified class-A (the
`secret.zig` bounds/round-trip/per-uid store, `trust.ensure_secret_file`
registering `SECRETS.TXT` secret-class by construction, the syscall's
owner-only + `EFAULT`/`EINVAL` contract, and the strace/snapshot/tombstone
redaction tests) and class-B (`live-secrets`: a host-seeded known value is
listed by NAME in the guest `secrets` and never appears in the serial
capture, and `cat SECRETS.TXT` / `vf cat SECRETS.TXT` are denied at both
seams).

**M97g amendment (2026-10-15, #2083):** uid scoping alone was vacuous —
every EL0 app is `uid_user`. A `SECRETS.TXT` line may now carry a fourth
field, an image-name allowlist (`key<TAB>uid<TAB>value<TAB>apps`); an
app-bound entry is served only to a caller whose recorded image is both
listed and `uid_system`-owned in `OWNERS.TXT` (`OWNERS.TXT` itself is now
self-protected by construction, so EL0 cannot author the row it would need
to forge). The wire shape, error codes, and strace redaction are unchanged;
a caller with no visible entry still sees 0.

### Amendment (2026-09-11, #1138 — slot 71 `sys_tty_net_auth`, the delegated net-auth seam)

M50 TS4 (ADR 0024 D6/D10) adds the trust milestone's fourth slot: **71** =
`sys_tty_net_auth(op, buf, len)`. It is the delegated challenge-response
channel between the kernel net pump and the process that owns the attached
net terminal (selector 3). `op` 0 copies the fresh 32-byte challenge OUT
(returns 32; 0 before it is minted or after auth); `op` 1 copies the
buffered client reply line (hex) OUT (its length; 0 when none yet); `op` 2
copies the one-byte verdict IN (0 = reject, 1 = accept) and applies it —
accept opens the byte gate and delivers pipelined post-auth bytes, reject
transmits `auth failed\n` + `tcp.reset()` + detach. The caller must be the
process that owns the attached net terminal (`EACCES` otherwise); `EINVAL`
when the terminal is not in auth mode, no reply awaits a verdict, or the op
is unknown; `EFAULT` for a bad buffer. The handler and its results are
excluded from strace (the never-logged contract, shared with slot 70).

The M46 in-band shared secret is **deleted, not layered**: `sys_tty_attach`
selector 3's `secret_ptr`/`secret_len` arguments are replaced by `a2` = the
auth scheme (**0 open, 1 hmac-sha256, 2 ed25519**; the secret never rides an
argument), `a4` stays the optional source-IP allowlist, and `terminal.zig`'s
`net_secret`/`secretEq` are gone. On TCP accept the pump mints a fresh
32-byte challenge via `csprng`, frames exactly one line
`VIRELAIOS-AUTH/1 <scheme> <hex-challenge>\n`, buffers one reply line
(length- and hex-validated against the scheme: 64 hex for HMAC-SHA256, 128
for Ed25519), and gates every post-challenge byte on the process's verdict.
Reject, a malformed line, or no verdict within the **10 s** auth deadline is
`auth failed` + reset + detach — never a bypass, and pre-auth bytes never
reach the terminal input queue. The handshake bounds raise
`tcp.payload_max` 64 → **192** and `segment_max` 84 → **212** (fixed-size,
reassembly-free; `frame_max` 118 → 246, still far under the 1514 wire
bound); `net_auth_line_max = 160` replaces the shared-secret fields.
Userland (`user/src/lib/netauth.zig`) reads the challenge and reply, verifies
`hmacSha256` + `ct.ctEq` over
`"VIRELAIOS-AUTH/1 hmac-sha256" || 0x00 || challenge[32]` (or
`ed25519.verify` over the `"VIRELAIOS-AUTH/1 ed25519"` message), and votes;
keys come from the TS5 store (`net-hmac`, the key byte-for-byte;
`net-ed25519`, the 64-hex public key) and are zeroized. CLI: `net <port>
[open]` — with a credential auth is mandatory; with none the shell refuses
to listen unless `open` is explicit (fail closed). The Stage-0 host bridge
`--console-tcp [host:]port[:secret]` runs the same HMAC handshake with
CryptoKit, and `vgate-client.py --hmac-secret` answers it with Python's
stdlib HMAC; no secret ⇒ byte-identical to the pre-TS4 bridge.
`implemented_count` becomes **72** (rows 0–71; reserved 72–127). No existing
number, argument, result, or error code changes. Verified class-A (the
`terminal.zig` pump state machine over the injectable `NetSeam`: fresh
challenge, wrong/malformed reply, replay/stale challenge, 10 s deadline,
key/challenge wipe, framing bounds; `netauth.zig` pinned HMAC RFC 4231-style
and Ed25519 CryptoKit vectors, wrong-MAC, replay, zeroize; the slot-71
owner/strace tests) and class-B (`live-remote-auth2`: wrong MAC →
`auth failed`, right MAC drives the shell, a captured handshake replayed
against the fresh challenge is rejected, explicit `open` still accepts;
`live-remote` re-pointed to `open`, `live-term-net` updated, and
`live-remote-auth` retired/removed).

### Amendment (2026-09-11, #1137 — no slot: the TS3 kill gate + monitor admin spawn)

M50 TS3 (ADR 0024 D5/D10) adds **no syscall slot** — `implemented_count`
stays **72**. It makes the process privilege enforceable at the existing
seam:

- `sys_kill` (29) is gated by the **explicit, bounded `capability_gates`
  table** in `kernel/src/syscall.zig` (one row: `sys_kill` →
  `process.cap_proc_admin`), consumed by the handler (`gated(sys_kill)`) so
  a future gate is one table row plus its explicit query. **Self and
  same-uid targets are allowed for every principal**; a cross-principal
  kill returns `EACCES` unless the caller's `caps` holds the gated
  capability. The principal check runs BEFORE the target-state checks, so
  an unprivileged caller always gets `EACCES` for a foreign principal —
  never a state-dependent `EINVAL`. The EL1h monitor is never a target: it
  has no process descriptor (no pid names it), and
  `scheduler.request_kill` independently refuses the kernel-owned
  shell/idle executor slots.
- `sys_exec` (28) stays **ungated and principal-preserving** (TS1): it
  takes only `(path_ptr, path_len)`, inherits the caller's uid/caps, and
  there is **no elevation syscall** — the table deliberately contains only
  ADR 0024 D10's gated set and nothing else.
- The tables' other D10 rows are unchanged: the `sys_file_*` family keeps
  its TS2 `trust.check` enforcement, `sys_tty_attach` (67) keeps its
  owner checks (TS4), `sys_wmctl` (65) and shared-anon mmap (63/64) hold,
  and `sys_setrlimit` (54) stays self-only.
- The EL1h monitor's `exec` gains the administrative `-u<uid>` flag:
  `exec [-c<core>] [-u<uid>] [<file> [arg...]]`. `-u0` assigns
  `uid_system` + `kernel_caps`, `-u1000` assigns the default `uid_user` +
  no caps, and any other uid is refused. This is the ONLY path that names
  a spawn principal — EL0 `sys_exec` has no principal argument — so the
  admin spawn is a raw-console monitor surface, never EL0-reachable.

Verified class-A (the gate table's exact bounded shape and the ungated
D10 rows; cross-principal `EACCES`; same-uid + self allowed; a
`uid_system` + `CAP_PROC_ADMIN` caller killing across principals; the
no-elevation slot audit; the `exec -u` CLI vocabulary with overflow
refusal) and class-B (`live-trust-caps`: a monitor admin-spawned
`uid_system` probe is untouchable from a `uid_user` process — `EACCES`
from slot 29 and the probe's markers continue — while the same-uid kill
still yields status 137). The boot default is unchanged: the all-`uid_user`
fleet's same-uid kills behave exactly as before.

### Amendment (2026-09-12, #1166 — slot 72 `sys_getrandom`, the EL0 entropy read)

M51 SSH-P1 (ADR 0025 D5) adds the SSH milestone's **only** new slot: **72** =
`sys_getrandom(buf, len)`, filling caller memory from the kernel CSPRNG
(`kernel/src/csprng.zig` `random_bytes`) through uaccess. It is strictly
**read-only**: it can never seed, reseed, or weaken the stream, and there is
deliberately no `sys_seed`. It requires **no capability** — every principal
may read entropy. `len` is **capped** at a fixed `getrandom_max` = **256**
bytes (a longer request is clamped, never refused — the caller loops; 256
matches `write_cap`, covering an ephemeral X25519 secret, a KEXINIT cookie,
and a burst of per-packet padding while keeping the BSS staging buffer and
one `copy_out` small); `len == 0` returns 0 without touching the buffer;
`EFAULT` answers a bad buffer; `EINVAL` answers a non-process (EL1h) caller.
The kernel stays crypto-free (ADR 0023 D2): it only returns bytes. Slot 72 is
a **single shared contract**: the GOOS=virelai Go runtime (#1163) consumes it
for its hash seed and does not add a second entropy slot. `implemented_count`
becomes **73** (rows 0–72; reserved 73–127). No existing number, argument,
result, or error code changes. The slot is registered but **never called on
the boot path** (ADR 0025 D9), so the boot log is byte-unchanged. Verified
class-A (the handler's cap / `len == 0` / `EFAULT` / non-process `EINVAL`
contract, the no-capability gate, the table/count pin at 73, the boot-path
call-counter-still-zero check, and the extended `syscalls` report rows) and
the existing class-B fleet stays green; the EL0 entropy end-to-end proof
rides SSH2's fresh-KEX-key proof (no new spec, per `docs/ssh-scoping.md`).

**M97g amendment (issue #2084):** while `!csprng.seeded()` the slot fails
closed — `EAGAIN` (-11), nothing written — because the deterministic
boot fallback must never be served as real entropy. An unseeded call first
attempts a lazy reseed (one transport re-arm + device read, bounded poll),
so a late-attached or ExitBootServices-reset device restores service
without a reboot. Host tests pin the refusal and the reseed; the
`live-entropy-refusal` spec boots the runner with `--no-entropy` and
observes ENTPROBE.BIN exiting 11.

### Amendment (2026-09-12, #1214 round 2 — slots 73/74 `sys_thread` / `sys_futex`, ADR 0027 D3/D4)

The GOOS=virelai thread card (ADR 0027, ACCEPTED 2026-09-12) adds the M:N
seam as **two op-based slots**, following the repo's op-selector convention
(sys_wmctl cmd, sys_tty_net_auth op). Both are **kernel-domain** syscalls,
not capability-gated: a thread can only create work inside the caller's own
address space.

**Slot 73 — `sys_thread(op, ...)`**

| op | Signature | Behavior | Errors |
|----|-----------|----------|--------|
| 0 | `thread_create(entry, stack_hi, arg, tls)` | Allocates a task bound to the CALLER'S process (same TTBR0 root, principal inherited, per-task EL1 kstack + uaccess TCB copy), arms the initial EL0 frame at the caller-provided `stack_hi` with `x0 = arg`, `pc = entry`, and joins the unpinned ready ring (claim-9498 SMP placement). The task NAME is the process name. Returns the new kernel tid (`>= 0`). | `EINVAL`: unknown op, non-process caller, `tls != 0` (reserved — pure-Go arm64 keeps g in R28), `stack_hi == 0` or not 16-byte aligned, `entry` outside the process's executable text aperture. `EAGAIN`: task pool or per-process thread bound exhausted (transient; the caller may retry). |
| 1 | `thread_exit()` | Tears down the CALLING TASK only: zombie → reap frees the thread's own EL1 kstack. **The process dies when its LAST task exits**; `sys_exit` (slot 3) stays process-exit — it requests the whole process (the first request snapshots the reported status) and arms the sibling tasks' kill conversion, force-waking blocked ones. No join (Go joins via channels); `sys_wait` keeps waiting on process exit only. | `EINVAL`: non-process caller or an inactive pool. |

**Slot 74 — `sys_futex(op, uaddr, val, timeout_ns)`**

| op | Signature | Behavior | Errors |
|----|-----------|----------|--------|
| 0 | `futex_wait(uaddr, val, timeout_ns)` | Kernel-VERIFIED compare: the 4-byte little-endian user word at `uaddr` is read through the caller's uaccess window; a mismatch returns immediately. On a match the task sleeps with a seat in the bounded BSS wait table keyed `(pid, uaddr)` (`max_tasks` entries, flat scan). The word is re-checked AFTER the seat is visible and under the scheduler lock (PR #1221 review — closes the store-then-wake lost-wake window); a failed re-check clears the seat. Returns 0 on a real wake; **`-ETIMEDOUT`** when the deadline expires — distinct from a wake; `-EAGAIN` on a mismatched word. Thread death while waiting removes the seat and performs one `wake(1)` (the Go `exitThread` contract expects the woken peer to re-check the word). | `EINVAL`: non-process caller or a misaligned `uaddr`. `EFAULT`: the word read fails the uaccess window. `EAGAIN`: word != `val`, the bounded wait table is full, or the rotation could not stage a successor (all transient — the caller re-reads). `ETIMEDOUT`: deadline expired. |
| 1 | `futex_wake(uaddr, n)` | Wakes up to `n` waiters of the CALLER'S process keyed `(pid, uaddr)`; each woken task's syscall returns 0. Returns the number woken. | `EINVAL`: non-process caller or a misaligned `uaddr`. |

**`timeout_ns` unit: nanoseconds**, rounding UP to whole scheduler ticks
(the 1 s timer period — a sub-second timeout waits one tick);
`timeout_ns == 0` waits forever.

**New error codes** (the D3 table's bounded -1..-10 namespace extends
append-only; no existing code changes):

| Value | Name | Meaning |
|-------|------|---------|
| -11 | `EAGAIN` | Futex wait: the user word no longer holds the expected value. |
| -12 | `ETIMEDOUT` | Futex wait: the nanosecond deadline expired without a wake. |

**Mmap-hint collision refusal (issue #1214 root cause).** The same round
tightens `sys_mmap` (slot 63): a mapping whose range overlaps the caller's
own text/rodata/data/STACK apertures or any earlier mmap region is refused
with `EINVAL` — the hint is honored only when honest. This is the guard the
go-args boot flake lacked: the GOOS=virelai sbrk heap reserved ~1.2 GiB
contiguously upward from the image end, the claim-2665 ASLR stack band
started at 0x1000_0000, and the runtime's arena trims then `memclr`'d the
live EL0 stack for ~54% of placements. The ASLR band itself moved above the
heap's practical ceiling (`[0x1_0000_0000, 0x2_0000_0000)`, csprng.zig — a
kernel-internal choice, no ABI change), so the refusal is the honest
backstop, not the expected path. The data aperture's collision bound
excludes the gap layout's defensive argv-headroom page: the sbrk heap starts
at `memRound(firstmoduledata.end)`, which lands on that page by design.

`implemented_count` becomes **75** (rows 0–74; reserved 75–127). No existing
number, argument, result, or error code changes. Verified class-A (the
thread lifecycle: same-process bind, thread-only exit, process death at the
last task with the requested status snapshot; the futex
mismatch/sleep/wake/timeout contract; the table/count pin at 75; the mmap
collision refusals — stack/text/overlap refused, adjacency allowed) and
class-B (`go-goroutines`: N=8 goroutines > GOMAXPROCS=2, `sys_thread`
calls >= 2, `sys_futex` parked, `task=GOROUT.ELF` on a secondary core in
the `smp` report; `go-hello`/`go-args` unchanged and green).

### Amendment (2026-09-13, #1226 — exec envp on the gap path)

The GOOS=virelai envp half is an **entry-contract extension**, not a new
syscall — the same shape as card-3e argv (`x0` = argc, `x1` = argv block
VA). Slot 28 `sys_exec` is unchanged (still path-only; EL0 has no env
argument). The kernel monitor form packs a bounded envp block into the
gap-layout ELF's extra writable page, immediately after argv:

- 16 slots × 128 bytes (`KEY=VALUE`, name ≤ 32, val ≤ 64) — enough for
  the kernel shell's whole `env_max` table.
- Source: the kernel shell `set`/`export` table, snapshotted at `exec`.
- rt0 converts argv+envp to the Unix `argv…/NULL/envp…/NULL` pointer
  array; `goenvs` fills `runtime.envs` so `gogetenv("GOMAXPROCS")` works.
- `numCPUStartup` stays **2** (ADR 0027 D6; two vCPUs). `GOMAXPROCS=N` in
  the environment is the tuning knob; no osinit default bump.

No `implemented_count` change. Verified class-A (`pack_env` shape +
truncation) and class-B (`go-args`: argv unchanged, `env n=1
[GOMAXPROCS=1]`, `procs=1`; `go-hello`/`go-goroutines` still PASS).

### Amendment (2026-09-13, #1228 — slot 75 `sys_exnotify`, phase 0c)

The GOOS=virelai fault-delivery card adds the panic seam as **one
single-argument slot** (no ops: nonzero installs, zero clears). It is a
**kernel-domain** syscall, not capability-gated: a handler can only
redirect faults inside the caller's own address space.

**Slot 75 — `sys_exnotify(handler)`**

| Signature | Behavior | Errors |
|-----------|----------|--------|
| `exnotify(handler)` | Installs the CALLER'S process EL0 fault-handler PC. A deliverable EL0 fault (see below) then resumes the SAME frame at `handler` with the fault record in registers: `x0` = signal (4 SIGILL / 7 SIGBUS / 11 SIGSEGV, matching the runtime's constants), `x1` = fault address (FAR, or the faulting PC for alignment faults whose FAR is meaningless), `x2` = fault PC, `x3` = ESR, `x4` = SP_EL0, `x5` = LR, `x6` = R29. Process-scope: every `sys_thread` task inherits it. `handler == 0` clears the handler (the reap path returns). Returns 0. | `EINVAL`: non-process caller, misaligned `handler` (AArch64 instructions are 4-byte aligned), `handler` outside the process's executable text aperture (the slot-73 "like exec" rule), or a dead process. |

**Delivery contract** (exceptions.zig, in the EL0 path after demand
paging, before the reap dispatcher): deliverable classes are illegal
encodings (EC 0x00), EL0 instruction aborts (0x20), PC/SP alignment
(0x22/0x26), and EL0 data aborts (0x24). Debug classes (breakpoint,
step, watchpoint, BRK) stay reap-only. A fault whose PC is already the
handler is refused delivery (a fault inside the handler reaps — the
backstop against delivery loops). `create` zeroes the handler and a new
exec image must re-register (the old PC is meaningless under the new
text). uaccess EL1 faults and demand-paged faults never reach delivery
(the existing order guarantees it).

`implemented_count` becomes **76** (rows 0–75; reserved 76–127). No
existing number, argument, result, or error code changes. Verified
class-A (register/unregister/refusals; the frame rewrite x0–x4 + ELR
redirect; the nested-fault refusal; the table/count pin at 76) and
class-B (`go-panic`: main + worker goroutines fault, recover with the
nil-deref message, and walk the injected sigpanic frame;
`sys_exnotify` calls >= 1; the full go fleet still PASS).

### Amendment (2026-09-15, #1333 — slot 28 carries argv; EL0 caller survives)

`sys_exec` from EL0 was path-only. A successful spawn still killed the
caller: `process.create_as` took a full `AddrSpace` by value, and
`AddrSpace.dynamic_pages` is `[4096]u64` (~32 KiB). Zig materializes that
temporary on the caller's 32 KiB EL0 kstack, which sits next to the user
stack — the overflow smashed the oldest EL0 frames. ENOENT returned
before `create_as`, so a missing file looked fine; a real child (Go
`WEB.ELF` exec'ing `FETCHS.BIN`) printed the pid and then died. The
fix is `AddrSpaceSpec` (scalars only) plus in-place `@memset` of
registry slots — never pass `AddrSpace`/`Process` by value.

Slot 28 grows the card-3e argv block as two extra arguments. No new
slot, no `implemented_count` change, no principal change (still
ungated and caller-preserving).

**Slot 28 — `sys_exec(path_ptr, path_len, argv_ptr, argc)`**

| Signature | Behavior | Errors |
|-----------|----------|--------|
| `exec(path_ptr, path_len, argv_ptr, argc)` | Copy the path through uaccess, then run the EL1h loader (`exec.exec_file_as`) into a FRESH process slot and spawn it at EL0. `argc == 0` means no args (`argv_ptr` ignored). `argc` in 1..=8 copies packed 32-byte NUL-terminated slots (card-3e; 31 bytes + NUL, truncation is the packer's). Returns the new pid. The caller keeps running. | `EINVAL`: non-process caller, empty/over-long path, `argc > 8`, or a loader refusal (`.no_disk`, `.bad_magic`, `.bad_entry`, `.too_large`, `.no_args_room`, `.too_many_args`, ELF refusals). `EFAULT`: bad path or argv pointer. `ENOENT`: file absent. `ENOSPC`: pool / pages / page-tables / process registry full. |

In-tree `ui.exec_program` now issues `syscall4(..., 0, 0)` so leftover
x2/x3 cannot be read as argc. `ui.exec_program_args` / `vi.Exec` pack
the block. Verified class-A (`AddrSpaceSpec` size pin; `argc > 8` is
EINVAL; ENOENT leaves the caller running; a successful spawn preserves
`scheduler.current_id` and the caller's process) and class-B
(`live-el0-exec`: EL0EXEC.BIN execs a missing name, then USER.BIN with
argv `alpha`, prints a survived marker from a stack buffer, waits, and
the child completes).

### Amendment (2026-09-15, phase 2 — slot 76 `sys_sock_ready`; nonblocking recv is normative)

**Append-only.** Nothing above is rewritten; this adds one slot and states
the blocking contract the Go runtime's netpoll depends on.

Context. Slot 32 `sys_tcp_recv` was already non-blocking — it returns 0 when
no segment is queued (see its table row and `handle_tcp_recv`) — so
"{n bytes read | 0}" already distinguishes "data" from "would block" without
an errno. What did not exist was any way for a task to *park* until the
socket became readable, and any readiness signal at all. A Go goroutine
blocked in `runtime_pollWait` therefore had nothing to wake it: the phase-0a
netpoll stub returned an empty list every time. Phase 2 needs a readiness
seam. This amendment adds exactly one slot for it.

Deliberately **not** added: epoll/io_uring, a second socket table, an
fd-style socket registry, any new address family, or a new errno. The
kernel's ONE-TCP-socket-per-process law (slot 30's `tcp` singleton,
`tcp.owner_pid`) is unchanged and is the reason slot 76 takes no fd.

**Slot 76 — `sys_sock_ready(op, want, timeout_ns)`**

| Signature | Behavior | Errors |
|-----------|----------|--------|
| `sock_ready(op, want, timeout_ns)` | Return the readiness mask of the calling process's TCP socket. **Both ops are a probe** — `want` is the caller's mask of wanted bits (bit 0 = readable, bit 1 = writable) and `timeout_ns` is reserved. The caller does the waiting. | `EINVAL`: a non-process caller, or a `want` with no bit set (or an unknown op). `EAGAIN`: the caller owns no socket (nothing is connected or listening) — slot 30 was never called or the connection was released. `EFAULT` is impossible (the call copies no buffer). |

**Both ops are a probe, and that is deliberate.** An earlier draft had
`op == 1` park inside the handler (`scheduler.yield_current()` in a bounded
loop). It crashed the kernel on target: `[EXC] sync from EL1h count=15179 /
esr=... ec=0x00 unknown-reason / [EXC] parking: no recovery path`. A syscall
handler must not re-enter the scheduler. The bounded wait therefore lives in
the CALLER — the Go runtime's netpoll, which yields on its own proven sleep
path between probes — and `timeout_ns` is reserved for a future in-kernel
park (a `wait_sock_current`/`wake_sock_waiters` pair mirroring
`wait_event_current`, which does not change this slot's shape).

Mask bits: **bit 0 (value 1) = readable** — a segment's payload is queued
(`tcp.rx_pending`) or the peer's FIN has been consumed and the connection can
be drained/closed; **bit 1 (value 2) = writable** — the connection is
established and no segment is pending retransmission (`tcp.tx_pending`
false), i.e. a send would build and transmit. `0` means "nothing to report
yet" and is never an error.

Ownership. Only the process whose `tcp.owner_pid` matches may probe/wait;
another process gets `EAGAIN` (it owns no socket). This mirrors slot 31/32's
`tcp_owned_by_caller` EACCES refusal but uses `EAGAIN` because "no socket" is
transient here — a probe before `sys_tcp_connect` is a race, not a
permission error.

Why a slot and not an ADR 0009 event kind. ADR 0009's queue is the
application's input/window stream, bounded at 16 events and drop-oldest. A
poller that consumed readiness from that FIFO would steal the app's keyboard
and window events, and the drop-oldest policy would silently discard
readiness. Slot 76 keeps readiness out of that stream entirely: it is a
level-triggered query, so no edge can be lost, and the task park is the
kernel's existing blocking-task mechanism, not an event push. ADR 0009 gains
a one-paragraph note (below) recording that readiness is *not* an event kind.

Verified: the class-B `go-net` gate on VZ (2/2 runs). Run 01: GONET.ELF reads
a share file, Dials an IP literal, writes a GET, reads the responder's pinned
200 OK body, and its heartbeat goroutine is running on both sides. Run 02 (the
peer answers the SYN then goes dark): the bounded read FAILS CLOSED
(`vsys: kernel error 12` = ETIMEDOUT) and the gate's order proof confirms a
heartbeat line still appears AFTER the fail-closed line. Additive static
checks (mask for idle/established/closed, EAGAIN without a socket, `want == 0`
rejected) are host-side in `user/go/vsys`

## Amendment (2026-09-18, M66a #1443 — the file-durability seam)

**Slot 77: `sys_file_sync(fd)`.** The HF3 FSYNC op (0x08) has existed on the
host file channel since M34, but only below the syscall seam: the kernel
called it internally (and never on behalf of userland), so an EL0 app had no
durability verb — close flushed the host's `FileHandle` implicitly, and
nothing told the app when its `/host` bytes were on the device. M66a makes
`/host` a surface Go apps can trust, which requires the app to *own* the
durability point. Slot 77 is that verb, one argument (the fd), no ops.

Semantics (kernel/src/file_table.zig `sync`): a `.host` handle with a live
host write handle rides the channel's FSYNC (the host calls `synchronize()`
on the live fd); handles with no host-side dirty state — stateless read
handles, read-only `.usb`, `.tty` — are honest no-ops (0); a dead fd is
EBADF; a dead host handle maps HF status 6 to EBADF via the M66a
`hf_handle_errno` row. The reply is 0 or a negative `ErrorCode`; the file
domain is the `file` service-domain lock, like the other file rows.

The same card pins the HF-status → errno rows for the whole file surface
(`hf_open_errno`/`hf_handle_errno`): not-found → ENOENT, is-dir → EINVAL,
exists → the file-domain `-9` EEXIST row (the M25 Lane B convention; the
ErrorCode enum names this magnitude ENXIO in the device domains), and
handle-full → ENOSPC. No existing row moved except rename-target-exists,
which was EINVAL and is now the honest `-9`.

## Amendment (2026-09-21, M71m #1572 — slot 28 argv: 31 bytes is measured, and it is already the envelope's maximum)

**Append-only.** No slot, argument, result, error code, or `implemented_count`
changes. This amendment records a measurement and the decision it forces; the
card's code half is owed to a follow-on (see *Decision*).

Context. M71m (#1572) exists to lift the card-3e per-arg 31-byte truncation
(`pack_args`: `take = @min(arg.len, arg_slot_bytes - 1)`), because GOSSHD wraps
every session command through `SSH/EXEC.IN` + `GOSH.ELF -c 'source
SSH/EXEC.IN'` to stay under it. The card's deliverable 1 is explicit: measure
the honest bound against the tail-page rule and record the number here — *do
not guess*.

**Observed (in tree, at 66bdbbbb).** The block is `max_exec_args` 8 ×
`arg_slot_bytes` 32 = `arg_block_bytes` 256, then `max_exec_envs` 16 ×
`env_slot_bytes` 128 = `env_block_bytes` 2048 — **2304 B** total, placed at
`block_off = align8(last_seg.mem_size)` and refused with `.no_args_room` when it
does not fit the last segment's allocated pages (`exec_static_elf_gap`,
kernel/src/exec.zig). The builders assert `slack >= 0x908` (the block plus its
8-byte alignment step): build-gosh.sh, build-gohttpd.sh, build-goping.sh.

**Observed (measured; `p_memsz` of each image's writable PT_LOAD):**

| image | W `p_memsz` | `r` = memsz mod 4096 | slack = 4096 − r | spare over `0x908` |
| --- | --- | --- | --- | --- |
| GOFETCH.ELF | 0x33188 | 392 | 3704 | 1392 |
| GOPING.ELF | 0x30350 | 848 | 3248 | 936 |
| GOSH.ELF | 0x326b0 | **1712** | **2384** | **72** |

GOSH — the `-c` consumer this card is about — clears the asserted need by **72
bytes**.

**Derived (read from the code; not measured on VZ).** Two rules govern the
block, and which one binds is the heart of this measurement:

1. the runtime's break floor — `initBlocFloor` moves the sbrk break to
   `memRound(virArgvBlockBase + virArgBlockBytes + virEnvBlockBytes)`
   (tools/go/overlay/runtime/os_virelai.go), whose two constants restate the
   kernel's 8×32 and 16×128;
2. the tail-page slack the builders assert, which is the constraint ADR 0035
   amendment 4 derived from the pre-#1540 break base (`memRound(image end)`).

Under (2), an `s`-byte slot needs `8s + 2048 <= 4096 − r`, i.e.
**`s <= (2048 − r)/8`**: the bound is a property of *the image*, not of the
ABI. GOSH's r = 1712 admits **s <= 42** — 41 usable bytes, and not a round
number: a 40-byte slot (39 usable + NUL) fits the tightest observed image with
only 16 bytes to spare, and 42 is the exact ceiling. `s = 64` needs
`r <= 1536` (GOSH already fails); `s = 256`, the card's 255-byte target, needs
`r <= 0` (all three fail). The envelope also *shrinks* as the slot grows:
today's 31 bytes is safe exactly while `r <= 1792` — ADR 0035 amendment 4 names
that as a 1792/4096 coincidence, not design — a 40-byte slot cuts it to
`r <= 1728`, and 64 to `r <= 1536`. **There is therefore no fixed in-page lift
that does not take argument support away from images that have it today**, and
none at all that leaves the observed images any headroom.

The one rule that *would* admit the 4096-byte block (`s = 256`) is the loader's
page fit alone: with the writable segment's flat `pages += 1`,
`seg_pages = ceil(memsz/4096) + 1` leaves `8192 − r` bytes past
`align8(memsz)` when r > 0 (6480 for GOSH) and exactly 4096 when r = 0. Which
rule actually binds for a 4096-byte block — that is, whether `initBlocFloor`
fully replaces the slack assertion, including for an image whose block spills
past `memRound(memsz)` — is **not resolvable by reading the tree**. It is a VZ
measurement, and the follow-on card owes it.

**Decision (the card's D3, applied).** The lift does not fit the tail page, so
the card stops at the measurement and reports the number instead of absorbing a
page-cost change by surprise; this amendment is its landing half. Concretely:
`pack_args` keeps its 31-byte truncation (31 is the maximum that holds the
documented `r <= 1792` envelope, so nothing lifts without the page decision);
GOSSHD's `SSH/EXEC.IN` wrap stays, because the command line it carries is
longer than any slot the current rule can hold; and the follow-on owns one of
two designs, to be picked by measurement — (a) page the block
(`pages` sized from `block_off + arg_block + env_block`, slot lifted to 255,
an over-long arg **refused**, never chopped), or (b) keep the ABI and lift
the slot only to the 42 bytes the tightest observed image supports (and to
nothing at all if that image's segment grows by one aligned word).

**Non-goals, restated.** No `wait`/`bg`. No `argc` growth past 8. No envp
rewrite: the 2048-byte envp block stays as packed even though halving it would
buy argv room, because that is a different ABI discussion. No third-child fix
(#1449).

## Amendment (2026-09-21, M71m #1572 — slot 28 argv is 255 bytes, refused past that)

**Append-only.** No new slot number, no new syscall argument, no `implemented_count`
change. This amendment is the code half the measurement above deferred. It
supersedes that amendment's *Decision*: design (a) is what landed.

**What was measured, by reading the loader, then checked on the class-B
gate.** The gap loader already reserved one extra writable page
(`pages += 1`) and `initBlocFloor` already starts the break at
`memRound(argv base + arg bytes + env bytes)`. A 4096-byte block
(8 × 256 + 16 × 128) placed at `align8(mem_size)` fits in that page:
exactly 4096 bytes when `mem_size` is page-aligned, and `8192 − r` bytes
past the image otherwise. Sizing `pages` from `block_off + arg_block +
env_block` is that same one page for this block — not a second page, and
not a tail-slack requirement. The builders' `slack >= 0x908` check stays;
it is stricter than the loader now needs, and images that already clear
it keep clearing it.

**Contract.** Slot 28's argv block is 8 slots × 256 bytes, NUL-terminated,
255 bytes usable. `pack_args` and `vi.Exec` **refuse** a longer argument
(`arg_too_long` → `EINVAL`). They do not chop. `argc > 8` is still
`too_many_args`. The Go entry stub (`rt0_virelai_arm64.s`) strides argv
by 256 and finds envp at `+2048`. `virArgBlockBytes` is `8*256`, so the
heap floor stays past the block when it spills out of the image's last
page.

**GOSSHD.** A session command is `GOSH.ELF -c '<command> > SSH/EXEC.OUT'`
when that one slot fits. `SSH/EXEC.IN` is gone. A line that does not fit
is refused.

## Amendment (2026-09-28, M83a #1774 — wall time in Go, no new slot)

| Existing slot | Contract | M83a consumer |
|---------------|----------|---------------|
| 66 `sys_time()` | Unix wall-clock seconds from the loader's EFI epoch plus 1 Hz kernel ticks; `-ENOSYS` without a usable firmware epoch | `vsys.Now` and `vi.Now` expose the same value alongside `Nanotime` / `Nanos`; GOSH `date` formats the calendar face — the `timezone` setting's fixed offset with its label since M83c (#1776), UTC when the row is absent or unparseable — and names a monotonic-only fallback when no epoch exists. |

This is an **append-only clarification**, not another ABI entry. Slot 66
already exported the needed seconds in #1058, and `vi.Time` already called
it. M83a's originally proposed next slot, 78 (after M66a's fsync slot 77),
would duplicate it. `implemented_count` stays 78, existing callers keep
their numbers and results, and neither NTP nor kernel-side formatting is
introduced. GOSELF compares the live epoch to the host wall clock on the
class-B reference host; host tests pin the `-ENOSYS` path without inventing
an epoch.

## Amendment (2026-09-28, M83b #1775 — slot 78 `sys_time_set`, the bounded wall-clock write)

| Slot | Name | Contract |
|------|------|----------|
| 78 | `sys_time_set` | `time_set(epoch_secs) -> i64`. Re-anchor the wall clock so slot 66 reads `epoch_secs` (Unix seconds) now. Returns `0`. `EINVAL` for a non-process caller or an `epoch_secs` outside `[1_735_689_600, 4_102_444_800]` (2025-01-01 through 2100-01-01 UTC); the clock is untouched on every refusal. Plain number, no uaccess. |

`implemented_count` becomes 79 (rows 0–78; reserved slots become 79–127).

**Why a new slot.** M83a exposed the wall clock through slot 66, which takes no
arguments. Slot 66 cannot also carry a write: existing callers do not zero `a0`,
so a stray register value would set the clock. A separate row keeps every
existing caller's meaning and gives the write its own named line in the monitor's
`syscalls` report.

**What it moves.** The clock is `boot_epoch_secs + ticks`. The call moves the
anchor (`boot_epoch_secs = epoch_secs - ticks`) and never the tick count, so
uptime, the monotonic counter and every tick-based deadline are unaffected. It
works on a boot with no firmware epoch (`no_boot_epoch`, where slot 66 was
`ENOSYS`), which is the case an SNTP sync exists for. Resolution is the 1 Hz
tick: the clock never claims sub-second accuracy.

**Trust posture.** There is no capability gate. Every EL0 process is `uid_user`
with no caps and no syscall elevates (ADR 0024 D5), so a `capability_gates` row
could only ever answer no and `time sync` would be unusable from the desktop
shell. The bound is the range check, which refuses the values a bug or a hostile
reply produces (0, a wrapped NTP era, all-ones). The consequence is real and
stated: any EL0 process may now step the wall clock, and time feeds TLS
validity checks. This matches the existing same-uid model (any EL0 process may
already kill another's), and `syscalls` shows a non-zero
`sys_time_set calls=` when anyone has used it. A capability row becomes the
right shape the day a second principal is reachable from EL0.

**Consumers.** `user/go/timesync` (one-shot SNTP over the UDP seam) and GOSH
`time sync`. GOSELF pins the write's range checks and read-back on the class-B
reference host. Not introduced: an NTP daemon or periodic sync, reference-clock
discipline, auth extension fields, or a timezone (M83c).

## Amendment (2026-10-01, B2 #1869 — versioned slot-27 directory snapshots)

This is the proposed B2 ABI amendment required by frozen ADR 0038. Approval
of this landing PR approves the interface; no additional syscall is allocated.
The registration count remains 79.

Legacy slot 27 (`path_ptr, path_len, rows_ptr, max_entries`) is unchanged:
40-byte rows, at most sixteen per call, and its historical short names.
Unused x4/x5 remain ignored. **It is not a complete directory walker.**
Version 2 is selected only by x3's high bit, which cannot be a valid legacy
user-buffer capacity:

| x3 | x0 | x1 | x2 | x4 | Result |
|----|----|----|----|----|--------|
| `0x8000000000000001` | path pointer | path byte length (0 = `/host`) | unused | unused | positive opaque snapshot token |
| `0x8000000000000002` | token | entry offset (initially 0) | page pointer | requested rows, 1–16 | row count, or error |
| `0x8000000000000003` | token | unused | unused | unused | 0 after close, or error |

All scalars are native little-endian. A page starts with a 16-byte header:
`next: u64`, `count: u32`, `end: u32` (0 or 1). Exactly `count` rows follow.
Each **272-byte** row is `[256]u8 name` (zero-padded), `size: u64`,
`name_len: u16`, `is_dir: u8`, `[5]u8 reserved` (zero). `name_len` is the
lossless byte length, 1–255; directories have size 0. `next` is the entry
offset for the next call, not a repeated listing. The final nonempty page
has `end=1`; reading offset `next` then returns count 0 and `end=1`.
An offset beyond the snapshot or row capacity outside 1–16 is `EINVAL`.
Retries of an indexed page, including after `EFAULT`, do not consume rows.

Open captures the entire directory **before** publishing the token, including
hidden and ignored names. Both backends collect through actual EOF, refuse
duplicate/malformed rows and more than 256 entries, and check directory
mtime/ctime (seconds and nanoseconds) around capture. Detected capture
mutation is `EINVAL`: restart with a new open. After successful capture,
names/type/size are immutable until close, irrespective of later host changes.
This is a directory-membership snapshot, not a snapshot of file contents or
a no-follow/containment guarantee (B3 owns those). Transport/metadata failure
is an error, never EOF.

Full native input paths are now ≤512 bytes, including the guest prefix.
Each normalized component is ≤255 bytes; at most eight components below
the **share root** are supported. Traversal, NUL and dot components refuse.
Over-limit v2 paths/names return `ENAMETOOLONG`; directory entry/cursor/native
handle exhaustion returns `ENOSPC`. USB v2 enumeration returns `ENOSYS`,
not an empty directory. Existing USB/tty interfaces remain available.

A cursor occupies one of the process's eight native resources; there are
eight snapshot slots globally, with 256 rows each. Each live snapshot uses
18 contiguous kernel-pool pages (72 KiB), freed on close/death or failed
capture, at most 576 KiB globally. Pool exhaustion is `ENOMEM`. There is no
permanent large BSS reservation. Tokens are globally unique
until exhaustion, process-bound, never recycled and explicitly closed.
Cross-process, stale and closed tokens return `EBADF`. Process teardown
releases every slot. No live resource is evicted. Ordinary file operations
cannot read/write/truncate/sync a directory cursor. Native close also frees
the slot if the caller closes its underlying resource index.
The widened shared handle table uses 19 pool pages (76 KiB), allocated
on first open and released when the last handle closes or dies. Ownership
save scratch uses nine temporary pages (36 KiB); boot load streams bounded
lines before the allocator is armed. B1's widened 48-record stream endpoint
table uses seven pool pages (28 KiB), allocated before an explicit file
binding is reserved and freed when its last reference/reservation is
released. Allocation failure returns `ENOMEM` without consuming parent
handles. Together with all eight snapshots these reservations peak at
716 KiB, without increasing the kernel BSS or bootloader image ceilings.
Files, directory cursors and file-backed stream bindings share the same
eight-resource limit per process.
The same listing authorization check runs at open **and every page**;
authorization changes do not expose a previously authorized snapshot.
Ownership keys and serialization carry the full widened path, never a prefix.

The legacy custom channel gains additive operations `0x0d/0x0e/0x0f`:
open(root-relative path) returns an eight-byte token; page takes
`token:u64, offset:u16, limit:u16` and returns the native header/row bytes;
close takes the eight-byte token. Status 7 is entry exhaustion, 8 path/name
exhaustion, 9 capture mutation. Old hosts refuse unknown operations.
The kernel materializes and closes the host snapshot before publishing its
process token; VirtioFS uses OPENDIR/READDIR's opaque continuation cookies
and RELEASEDIR, with the same limits and EOF contract.

Boris's total visited-entry limit, relative-root depth, emitted-file budget
and SDK resource accounting still belong to C3/A3. B2's conservative native
depth limit is rooted at `/host`, not an arbitrary deeper supplied root.
This discrepancy with ADR 0038's proposed root-relative workload depth must
be reported in the B2 PR, not patched into the frozen target contract.

## Amendment (2026-10-01, B3 #1870 — honest metadata and contained operations)

Landing approval approves **slot 79 `sys_fs_metadata`**, the only new slot
in B3. There are now 80 registered rows. Slots 0–78 and B2's rows remain
unchanged. This is a native bounded operation family, not POSIX `stat/openat`.

Path operations use `(op, root_ptr, root_len, relative_ptr, relative_len,
out_ptr)` in x0–x5. Root is an explicit `/host` or `/host/...` directory;
relative is normalized, may be empty, and never contains NUL, empty, dot or
dot-dot components. No prefix/path normalization can erase an escape.
The full joined guest path is ≤512 bytes, each name ≤255 bytes, and the
relative path has ≤8 components below the supplied root. The supplied root
itself also has ≤8 share-relative components. Over-limit paths return
`ENAMETOOLONG`; depth/entry/resource exhaustion returns `ENOSPC`.

| op | Operation | Output/result |
|----|-----------|---------------|
| 0 | Fresh no-follow metadata | 96-byte record at x5, result 0 |
| 1 | Fresh no-follow filesystem identity | 16-byte identity at x5, result 0 |
| 2 | Contained existing-file read-open | native fd 0–7, x5 must be 0 |
| 3 | Contained existing-file write-open | native fd 0–7, x5 must be 0 |
| 4 | Contained rich directory snapshot | positive process-owned token, x5 must be 0 |
| 5 | Indexed rich page | `(5, token, offset, limit, out_ptr, 0)`, row count |
| 6 | Close directory snapshot | `(6, token, 0, 0, 0, 0)`, result 0 |

The little-endian metadata record is `version:u32=1, kind:u32,
filesystem:u64, inode:u64, size:u64`, followed by atime/mtime/ctime,
each `seconds:i64, nanoseconds:u32, reserved:u32=0`, then
`host_mode:u32, host_uid:u32, host_gid:u32, reserved:u32=0`.
Kinds are 0 file, 1 directory, 2 symlink, 3 character device, 4 block device,
5 FIFO, 6 socket. The identity-only record is `filesystem:u64, inode:u64`.
Neither identity word may be zero. Inodes come from FUSE attributes, not a
path hash, a directory flag or FUSE's transport node ID. The filesystem word
is a mount-generation discriminator valid for this guest boot's filesystem
lifetime; it changes on reinitialization. It is not a cross-boot identity.
Host ownership/mode is factual metadata, **not** the guest principal policy.

Rich pages use B2's 16-byte header and 1–16 rows. Each **360-byte** row is
`name:[256]u8, name_len:u16, reserved:[6]u8, metadata:<96-byte record>`.
All reserved bytes/name padding are zero. Size is the actual u64 attribute,
including for directories, and timestamps are never defaulted or fabricated.
A failed capture publishes no token; malformed/missing attributes, stale
identity or changed directory mtime/ctime are errors, never partial EOF.
Indexed pages and contained file reads can retry `EFAULT` without consuming
data. A snapshot's metadata is immutable; a new op-0 query is fresh for
watch-stamp comparisons. This does not activate B6/watch or a watcher.

VirtioFS performs uncached component LOOKUPs, holds their FUSE references,
GETATTRs the pinned node and opens that same node. FORGET releases lookup
references beyond one mount-lifetime identity pin per object; OPEN handles
retain the actual object across pathname replacement. The VZ server was
observed to change attribute inode IDs after the last reference was released.
The bounded ledger retains real references for at most 512 objects, using two
pool pages, and refuses a new object at capacity (`ENOSPC`). It does not
cache paths or metadata, invent IDs, or evict pins and silently destabilize
previous identities. Reinitialization ends this lifetime and frees the ledger.
READ/WRITE/TRUNCATE/FSYNC/CLOSE use that handle and never fall back to a path
or another backend. Opens do not create, truncate or append. Root,
intermediate, leaf, dangling and enumerated symlinks are refused (`EACCES`),
never followed. Changed identity is `EBADF`; missing is `ENOENT`, denied is
`EACCES`, unsupported metadata/containment is `ENOSYS`, malformed facts or
transport I/O is `EINVAL`. Output buffers are untouched on backend refusal.
The custom file-channel backend and USB explicitly refuse this family:
their existing calls still work, but supply no B3 containment primitive.
B2's legacy name snapshot is explicitly **not containment**.

Guest ownership/secret checks apply to every ancestor and target before
lookup/open, and again at each file read/write/truncate/sync or directory
page, including the page's child rows. Close is allowed after revocation.
Cross-process/stale directory tokens refuse; no snapshot is an ACL grant.
All resources share the existing eight-native-resource/process ceiling.
Eight globally shared B2/B3 cursor slots are unchanged; a B3 rich snapshot
uses 23 temporary pool pages (92 KiB), at most 736 KiB globally, released
on close, death or any capture failure. It adds no permanent large BSS bank.
The native handle table is 19 temporary pool pages; the mount identity ledger
is the only two-page persistent reservation made by B3 queries.
SDK resource, total visited-entry, artifact and arena accounting remain
the C-card owners' responsibility; no SDK or ADR 0038 changes land here.

## Amendment (2026-10-02, B5 #1895 — pinned directories and name operations)

Landing approval approves slot 79 ops 7–14 for Boris C3 publication
(#1877). No slot is added: there are still 80 registered rows, ops 0–6 keep
B3's registers and results, and ADR 0038 and the boot default are unchanged.
This is a native bounded family, not POSIX `openat`/`mkdirat`/`renameat`.

A **pin** is a positive process-owned token for one directory object. It
holds that object's FUSE lookup reference and records its identity and
share-relative path (≤16 components, ≤512 bytes). Every use reauthorizes the
recorded path; the backend acts on the pinned node, never on a re-resolved
pathname. A name is one 1–255-byte component without `/` or NUL that is not
`.` or `..`. It is copied in once, before any lookup or mutation.

| op | x1–x5 | Result |
|----|-------|--------|
| 7 | root_ptr, root_len, relative_ptr, relative_len, 0 | pin of an existing directory (B3's no-follow walk) |
| 8 | pin, name_ptr, name_len, 0, 0 | pin of a child directory (one no-follow LOOKUP from the pin) |
| 9 | pin, 0, 0, 0, 0 | 0; releases the pin, also after revocation or staleness |
| 10 | handle, kind, 0, 0, out_ptr | 0 and B3's 96-byte record of the handle's own object; kind 0 contained fd, 1 pin |
| 11 | pin, name_ptr, name_len, 0, 0 | write-only native fd 0–7 on a newly created regular file |
| 12 | pin, name_ptr, name_len, 0, 0 | pin of a newly created directory |
| 13 | pin, name_ptr, name_len, kind, 0 | 0; removes a file (kind 0) or an empty directory (kind 1) |
| 14 | from_pin, from_ptr, to_pin, to_ptr, lengths | 0; one backend rename between two of the caller's pins |

Op 14's x5 carries `from_len` in bits 0–15, `to_len` in bits 16–31 and
**replace** in bit 32; any other set bit is `EINVAL`. Without bit 32 rename
is preserve-existing. Registers shown as 0 must be zero.

**Backend.** VirtioFS only. Create is `FUSE_CREATE` with
`O_WRONLY|O_CREAT|O_EXCL`, mode 0644. A server answering `ENOSYS` gets
`FUSE_MKNOD` (regular, 0644, itself exclusive), then OPEN of the new node ID.
Mkdir is `FUSE_MKDIR`, mode 0755. Remove classifies the name with a
LOOKUP+FORGET probe and refuses a symlink or the wrong kind before
`FUSE_UNLINK`/`FUSE_RMDIR`. Replace is `FUSE_RENAME`; preserve-existing is
`FUSE_RENAME2` with `RENAME_NOREPLACE`. There is no stat-then-act,
delete-then-rename, copy or pathname fallback. Servers older than FUSE 7.12
(create) or 7.23 (preserve-existing rename) refuse before mutation. The
custom file channel and USB refuse the whole family; op 10 on a legacy
(non-contained) fd refuses. The process's eight resources, the eight shared
VirtioFS file handles and a new object's ledger row are all checked before
the server is asked to mutate anything. A pin from an earlier mount lifetime
is stale: its node ID is never sent or forgotten.

**Policy.** Every ancestor is checked for list. The target is checked for
list (ops 7, 8, 10), create (ops 11, 12 and the op-14 destination) or delete
(op 13 and the op-14 source). Secret and poisoned paths refuse create and
delete for every actor. Success removes (op 13) or moves (op 14) the target's
trust metadata and persists `OWNERS.TXT`, as slots 34/35 do; creation mints
no entry. Host mode and uid remain facts, not policy.

**Staleness.** A successful guest rename (op 14 or slot 35) stales every
process's pins at or under either name. A successful removal (op 13 or slot
34) stales pins at or under the removed name. Matching is by whole components,
ASCII case-insensitive. A stale pin refuses everything except close with
`EBADF`. Host-side moves are not observed: the pin keeps acting on its node
and authorizing by its recorded name. A pinned node or fd object whose
identity changed is `EBADF`.

**Errors.** `EINVAL` (-1): bad name, register or kind; a non-directory pin
target; the wrong kind for removal; a malformed reply or transport I/O.
`EBADF` (-2): unknown, cross-process, stale or changed handle, or a snapshot
token given as a pin. `EFAULT` (-3): any bad user pointer, with no state
change. `ENOSYS` (-4): unsupported backend or primitive, or a cross-filesystem
rename. `ENOSPC` (-5): resource, handle or ledger exhaustion, or depth >16.
`ENOENT` (-6). `EACCES` (-7): policy denial, a symlink at the name, or server
denial. `ENAMETOOLONG` (-8): name >255 bytes or joined path >512. File-domain
`EEXIST` (-9): an occupied create, mkdir or preserve-existing target, or a
non-empty directory removal. Op 13 never recurses; op 14 never replaces
without bit 32. Transport loss or a malformed reply after submission is an
**unknown commit outcome** (the new file may exist), not a rollback.

**Resources.** A pin is one of the process's eight native resources plus one
FUSE lookup reference, released on close or process death. A created fd also
holds one of the eight shared VirtioFS file handles. Native handle records
grow to 624 bytes, so the temporary handle table is 20 pool pages (was 19).
No persistent reservation, BSS bank or path cache is added. Snapshots (ops
4–6) are unchanged and are never pins: slot 26 and op 6 refuse pins, and op 9
refuses snapshots.

The SDK exposes these through `fs.Native` and `runtime.filesystem()`, and
`File.length` uses op 10 (`tools/zig/filesystem.md`); `File.stat` stays
refused. `std.Io.Dir` wiring, watch (B6) and directory-fsync or power-loss
durability are not part of B5. Class-A wire/EL0 tests and `live-user-fs`'s
native probe verify the facility.

## Amendment (2026-10-02, B7 / #1874): opt-in continuous output PCM

Slot 43 preserves legacy `(ptr, len)` synchronous playback with its 64 KiB
per-call limit. **Bit 63 of x1** opts into streams: lower bits are the
exact byte length, x2 is the operation, x3 is the generation. Unused x2
in a legacy call is still ignored. No new slot or boot-default change.

| x2 | Operation | x0 / lower x1 | Result |
|----|-----------|---------------|--------|
| 1 | open | pointer / 8 | positive generation |
| 2 | submit | PCM pointer / 1..4096, whole frames | exact bytes accepted |
| 3 | start | 0 / 0 | 0, requires prefill |
| 4 | end | 0 / 0 | 0, begins asynchronous drain |
| 5 | abort | 0 / 0 | 0, explicit teardown, including sticky XRUN |
| 6 | status | writable pointer / 72 | 0, copies status |

Open requires x3=0. All other operations require the open generation and
the same process (threads share it). Status remains readable by that process
after close until another open. A live stream excludes legacy playback and
other opens (`EAGAIN`). Process death revokes ownership immediately and
defers transport cleanup to the main-context pump.

The 8-byte little-endian open request is `format:u8, rate:u8, channels:u8,
reserved:u8=0, version:u32=1`. Formats are S16=5, S32=17, FLOAT32=19;
rates are 8000=1, 16000=3, 22050=4, 32000=5, 44100=6, 48000=7;
channels are 1 or 2. The **exact tuple must be advertised by PCM_INFO(0)**,
whose direction must be output. No fallback, conversion, capture, or 96 kHz
claim. SET_PARAMS uses 32768 buffer bytes and 4096 period bytes.

The queue owns eight 4096-byte slots (32768 PCM bytes), 32 TX descriptors
(three per slot), and 1984 bytes of cache-line-isolated DMA metadata.
The fixed model/pump page allocation is separately charged, not a second
PCM buffer bank. Submit reserves, copies and commits atomically, with no
partial acceptance. Full queue is `EAGAIN` (-11), accepting **zero bytes**.
Bad pointers roll reservations back (`EFAULT`); invalid tuples/frames,
tokens, states or operations return `EINVAL`; periods over 4096 return
`ENAMETOOLONG`. Missing device, capacity, transport refusal or quarantine
is `ENXIO` (-9), never successful playback.

Status layout: five u64 fields `generation, accepted, submitted, completed,
canceled`, then eight u32 fields `state, reason, outstanding, slots,
starts, stops, releases, resets`. State values: closed=0, preparing=1,
prepared=2, starting=3, running=4, draining=5, stopping=6, releasing=7,
resetting=8, xrun=9, quarantined=10. Reason values: none=0, underrun=1,
owner_died=2, aborted=3, control_failed=4, device_failed=5,
malformed_completion=6, timeout=7.

Running out of queued and device-owned periods sets sticky XRUN.
Submit/start/end then refuse; abort closes the generation before reopening.
End drains before STOP/RELEASE. Failure or remaining DMA ownership after
RELEASE requires acknowledged device reset before reuse; failed reset
quarantines storage. Control, period ownership and drain budgets are 5 s
with bounded transport polling. The pump runs on stream calls and the
shell's main-context report loop, not in IRQ context. This is not a
low-latency scheduling guarantee. Completion proves returned buffer
ownership, **not measured audible consumption or captured waveform**.

Verification: the existing PCM model suite, production pump and syscall
tests, and `live-sound-playback`'s real-device 128 KiB / single START,
backpressure, copy rollback, sticky XRUN, abort, owner-death/reopen and
soundless-refusal runs. Legacy audio specs remain regression gates.

## B5 amendment — explicit TLS threads and strict coarse waits (#1872)

Slots 73/74 gain additive operations; no new slot or task budget.

| Slot / op | Arguments after op | Result |
|-----------|--------------------|--------|
| 73 / 0 | entry, stack_hi, arg, tls, 0 | tls=0: legacy detached task ID; nonzero tls: positive non-recycled process-bound join token |
| 73 / 1 | status, 0, 0, 0, 0 | exit this task; native status 0–255; legacy zero-TLS exit still status 0 |
| 73 / 2 | token, 0, 0, 0, 0 | join exactly once, block if necessary, return u8 exit status |
| 73 / 3 | tls, 0, 0, 0, 0 | attach/detach calling task's TPIDR_EL0, return 0 |
| 74 / 2 | uaddr, expected, timeout_ns, 0, 0 | strict native wait: 0 wake, EAGAIN changed/unavailable, ETIMEDOUT expiry |

Nonzero TLS is 16-byte aligned with a readable/writable 16-byte prefix;
the caller owns the entire planned template/body extent. A native child
also needs a writable 16-byte stack-top aperture and an aligned executable
entry. Bad apertures return EFAULT, alignment/op/status/token errors EINVAL,
and task/process-thread/page capacity EAGAIN. Native children stay on core 0;
legacy detached Go children retain any-core placement. Join tokens never
alias reused task IDs, accept one same-process joiner and retain unjoined
zombies inside the existing six-extra-thread and global 16-task limits.
Completion is published after teardown. Process death releases abandoned
tokens.

Op 74/2 accepts zero (indefinite) or whole-second relative durations,
refusing unsupported precision and deadline overflow with EINVAL. Its
deadline is `current_tick + timeout_ns / 1_000_000_000 + 1`; the extra
tick guards against the current period's phase and prevents early expiry.
It promises no upper resumption latency. Wait/wake atomically compare one
aligned u32 and serialize seating, recheck and wake under the scheduler
lock. Op 74/0 remains the legacy coarse Go wait. The supported context
model and caller lifetime obligations are in [ADR 0038](0038-zig-guest-target.md).

## Amendment (2026-10-03, B6 #1873): native socket handles, slot 80

Slot **80 `sys_socket(op, handle_or_ip, pointer_or_port, length)`** is a
separate native family. Existing slots 30–33 and 76 retain their legacy
singleton ABI. Slot 76's two operations are probes, never parks; the stale
park comment is corrected. `implemented_count` is 81.

### Capacity and ownership

One passive IPv4/TCP listener and **two simultaneous children system-wide**,
including unaccepted half-opens and terminal children, reuse the landed
`socket_core`. The core plus its frame scratch remains bounded by 16 KiB.
Each process-owned generation-tagged handle is distinct from a file handle
and from the legacy socket. No transfer, duplication, unbounded backlog,
IPv6, TCP options/reassembly, active connect, TLS or public listener policy
is provided. Listen binds the configured guest address; zero selects that
address, not a loopback or public-exposure promise.

Accepted children inherit the listener's owner. Closing a child immediately
releases its charge; closing the listener revokes all its children.
Process exit, kill and fault teardown release the listener, children and
DNS transaction before the PID is reusable. FIN preserves queued bytes
before EOF; reset/timeout discard them and return distinct errors.
Terminal handles remain charged until explicit close or process death.
An over-cap SYN gets independently addressed RST+ACK. The one refusal
queue preserves its existing counted-overflow contract.

The Zig `std.Io` adapter uses opaque SDK tokens and shares the existing
**four dynamic resources** with files/cursors/pins. A listener and its two
streams consume three; DNS consumes one during lookup. No resource/thread
budget expansion. SDK close and shutdown are separate: close is local
reclamation, not a promise that FIN/RST was delivered. `netShutdown`,
active connect and unsupported socket options continue to refuse.

### Operations and results

| op | x1 | x2 | x3 | result |
|---|---|---|---|---|
| 0 listen | IPv4 network-order word, or 0 | nonzero local port | unused | listener handle |
| 1 accept | listener handle | unused | unused | child handle, or `-11` |
| 2 read | child handle | writable buffer | byte capacity | bytes, 0 EOF, or error |
| 3 send | child handle | readable bytes | byte length | confirmed queued count, at most 1460 |
| 4 close | listener/child/DNS handle | unused | unused | 0 |
| 5 ready | any owned handle | unused | unused | level mask |
| 6 shutdown | child handle | unused | unused | initiate bounded FIN, or `-11` |
| 7 peer | child handle | unused | unused | `(IPv4_word << 16) \| port` |
| 8 DNS begin | resolver IPv4 word | query bytes | 17–64 bytes | DNS handle |
| 9 DNS reply | DNS handle | writable buffer | byte capacity | complete DNS message, or error |
| 11 owned-count | unused | unused | unused | caller's charged native handles |

Op 10 and unknown operations refuse `EINVAL`. x4/x5 must be zero.
Ready bits: 1 readable (including EOF/error), 2 writable, 4 accept,
8 terminal; DNS uses bit 1. All calls probe, perform bounded RX/TX work
under the NET lock, and return without entering the scheduler. The idle
network pump also advances the core, so deadlines/retries do not depend
on application polling. Kernel deadlines are 30 s; RTO is 3 s with ten
retries. Deadline equality wins before RX or retransmission.

Errors: `-1` invalid argument, `-2` stale/wrong-kind handle, `-3` bad
user buffer, `-4` unsupported, `-5` capacity, `-7` wrong owner, `-9`
network unavailable/unresolved resolver MAC, `-11` would-block, `-12`
timeout, **`-13` peer reset**, **`-14` closed**. The last two are native
socket-domain results, not POSIX errno. Reads validate the writable
aperture before consuming bytes. Zero-length reads validate the handle
and are no-ops, not EOF. `std.Io` maps reset and read timeout to their
named errors; its writer lacks Timeout, so it reports `Unexpected` with
`Network:TimedOut`, never fabricated progress.

### Names and DNS

Numeric addresses are required for listen. `std.Io.net.HostName.lookup`
and `user/zig/network.zig`'s explicit `resolve` accept ASCII RFC 1123
names (case-insensitive, optional final dot), with no search domains,
implicit host files, cache or TLS. IPv4 literals in `resolve` bypass DNS.
The default resolver is 10.0.0.2; the explicit resolver API can choose
another. Its ARP entry must already exist, as with the existing Go DNS
contract; a refusal never retries an implicit ARP operation.

One DNS transaction system-wide pins source port **7001** in the existing
four-entry UDP listen table, not legacy UDP's shared source port 7000.
A second transaction, a full UDP table or an existing bind of 7001 returns
capacity. The temporary seat is released with the DNS handle; existing
legacy binds remain usable when no native transaction is active.
Replies must match resolver IP, source port 53 and randomized transaction
ID, with valid UDP checksum when supplied. Messages over 64 bytes refuse
whole, never clamp into a purported answer. The SDK checks the echoed
question, every declared section, compression bounds, IN/A type, opcode,
rcode and truncation before returning one IPv4 address. NXDOMAIN is named;
CNAME-only, AAAA, malformed/no-A and truncated answers fail closed.
The encoded query must fit 64 bytes (at most 46 name bytes). Success,
timeout and parse failure all close the transaction; process death does
too. Duplicate legacy binds while the native seat is pinned refuse normally.

Native acceptance extends `live-net-tcp-syscall`: two independent
Ethernet peers complete std.Io preview requests, a third at another IP
gets RST, FIN/reset/timeout report and close, a process dies with a
listener and its replacement binds it, and DNS success/silence both
release resources. These boots are separate from the injected-core
fixture. This is not Boris publication/authentication or a TLS stack.

## Proposed amendment (2026-10-05, M94a #2001): observability reservations

**R1, awaiting owner approval with ADR 0043.** Slots 0–80 and the 128-slot
namespace remain unchanged. Three additional rows are registered as
**ENOSYS (-4) stubs for every input**. They allocate no ring, copy no user
memory and arm no timer. They are reservations, so the existing monitor
`syscalls` report remains byte-identical (81 implemented rows); each feature
module exposes its row when implemented by its own follow-on card.

| Slot | Name | x0–x3 | Implemented result conventions |
|---:|---|---|---|
| 81 | `sys_trace` | `op, token, ptr, bytes` | ARM=0 returns a positive CSPRNG-minted token (EAGAIN when only the deterministic fallback is keyed); DISARM=1/FILTER=2 return 0; READ=3 returns whole-record count; STATUS=4 returns 0; ARM_EXEC=5 returns an already-traced child pid. Session ops bind to the arming pid or `cap_proc_admin`, not the uid (M97g #2086, ADR 0043) |
| 82 | `sys_profile` | `op, token, ptr, bytes` | ARM=0 returns a positive CSPRNG-minted token (EAGAIN when unseeded); DISARM=1 returns 0; READ=3 returns whole-record count; STATUS=4 returns 0; op 2 and unknown ops refuse EINVAL. Same arming-pid binding as slot 81 |
| 83 | `sys_memstat` | `pid, ptr, bytes` (x3 ignored) | 240 bytes on success; exactly 240 output bytes required |

Trace/profile ignore x4/x5, and memstat ignores x3–x5. The register/result
convention remains x8 number, x0–x5 arguments, signed negative native errors
in x0. No new errno or principal-elevation surface. Unknown/reserved slots
84–127 continue answering ENOSYS.

ADR 0043 D1 freezes ops/configs/session ownership and the arm-before-exec
ordering. D2 freezes the **896-byte trace** (all six args, result, errno,
pid/tid/CNTPCT), **176-byte sample** (pid/tid/PC plus 16 bounded caller
frames), **240-byte memstat** (five receipt fields plus live counts and
region sizes) and **24-byte read header**. D3 freezes ring and loss bounds.
Records are version-1, little-endian, reserved/unused bytes zero. Same-uid
observation is allowed without a capability; cross-uid requires
`cap_proc_admin`. Slots 70/71 remain redacted, including args/results and
all user-string copies. The legacy serial tracer continues suppressing
their whole lines.

`kernel/src/syscall_abi.zig` is the machine-readable name/arg-kind table for
0–83, including op-specific shapes and whole-slot redaction. The generated
Go metadata mirror is `user/go/vi/slots_gen.go`; `go generate ./vi` from
`user/go` regenerates it and the host mirror test refuses drift.
After M94a merges, **M94b–d do not edit this amendment or any frozen layout**.
A contract change requires stopping for owner review.

## Amendment (M97b #2092/#2098/#2113/#2115 — refusal-contract tightenings, no slot changes)

No slot is added, renumbered, or reshaped. Four existing slots refuse more
inputs — every tightening is a named error where the old behavior was a
silent hazard.

- **Slot 3 `sys_exit(status)`**: statuses 137, 139, 140, and 141 are
  kernel-produced encodings (kill attribution, fault, memory-limit, and
  cpu-limit verdicts). An EL0 caller passing one is refused `EINVAL` and
  stays alive; the kernel's own exits still emit them. `sys_exit` is no
  longer strictly noreturn — a forged status returns.
- **Slot 63 `sys_mmap`**: a hint (or an auto-picked range) that wraps
  `u64` is refused `EINVAL` at the collision check, and a range whose
  slots hold kernel-live leaves (pooled RAM, an above-blanket device
  window) is refused `EINVAL` before the region registers. The same
  bounds apply to shared-surface owner creates and peer attaches through
  `M33_MAP_SHARED`.
- **Slot 64 `sys_munmap`**: the full-region-only rule for shared surfaces
  is now range-aware — ANY range overlapping a live shared seat without
  equalling it exactly is `EINVAL` (previously only a range whose START
  landed inside was refused). A `len` that wraps `addr` is `EINVAL`
  before any overlap test runs.
- **Slot 54 `sys_setrlimit` type 0**: the memory page limit is now
  enforced on charged dynamic pages (demand populate, COW promotion,
  `MAP_POPULATE`, shared-surface create). A charge at the ceiling is
  refused — `ENOMEM` on the syscall path, and a fault-driven refusal
  terminates the process with the reserved status 140. Reservations alone
  (a bare `mmap`) are uncharged; the charge lands on populate.
