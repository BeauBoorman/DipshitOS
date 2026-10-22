---
title: Userspace & syscalls
parent: architecture
status: published
tags: [architecture, syscalls, el0]
---

# Userspace & syscalls

Real EL0 user programs run under VirelaiOS: loaded off the host share by
`exec`, scheduled as processes on their own address spaces, and reaching
the kernel through a frozen, numbered syscall ABI. There is no libc and
no POSIX anywhere on this side of the boundary — every byte a program
needs crosses one numbered seam, and every refusal at that seam is a
named error, not a trap.

## The ABI (ADR 0007)

The calling convention is small and has never moved: the syscall number
goes in `x8`, up to six arguments go in `x0–x5`, the instruction is
`svc #0`, and the result comes back in `x0`. Negative results are native
errno values in two's complement — `-1 EINVAL`, `-2 EBADF`, `-3 EFAULT`,
`-4 ENOSYS`, `-5 ENOSPC`, and so on — not POSIX translations. The SVC
dispatch path only accepts an `svc` issued at EL0; the kernel never
traps into itself this way, because kernel code calls functions directly.

Dispatch runs through a **128-slot table built at runtime in BSS** — a
hard consequence of the kernel's flat-image format: a const table of
function pointers would carry link-time absolute addresses that are wrong
after the load, so every row is installed during boot. As of today,
**96 slots are registered — rows 0 through 95, dense** — and slots 96–127
answer `ENOSYS`. The monitor's `syscalls` command prints the table plus a
per-core call counter on every row, which is how the gates verify that a
real program made a real call rather than a plausible-looking print.

Two rules keep the ABI stable under change. First, it is **append-only**:
new syscalls take the next free number, existing numbers and error
meanings never move, and a slot that is not yet implemented returns
`ENOSYS` — the table has carried named `ENOSYS` reservations before (a
row exists so the numbering stays dense while a feature is still being
built). Second, since the M132 wave work, ADR 0007 carries a **wave
reservation table**: parallel development lanes claim ABI slots, manifest
fields, and other shared surfaces in a table up front — the row *is* the
claim — so concurrent cards cannot collide on a number mid-flight.

Some rows are op-dispatched rather than single-purpose: `sys_wmctl` (65)
takes a command, `sys_thread` (73) and `sys_futex` (74) take operation
codes, `sys_fs_metadata` (79) and `sys_socket` (80) take op words, and a
few rows carry *variants* — alternate argument shapes selected by a tag
in an argument register. The single source of truth for every row's name,
argument count, and argument kinds (including which are strings,
pointers, or redacted) is
[`kernel/src/syscall_abi.zig`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/kernel/src/syscall_abi.zig)
— a data-only table that doubles as the input to the Go SDK's generated
mirror. A handler-by-handler implementation lives in
[`kernel/src/syscall.zig`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/kernel/src/syscall.zig).

## The registered surface

The ninety-six rows, by region:

| Slots | Region |
|-------|--------|
| 0–8 | Process basics: `ping`, `write`, `yield`, `exit`, `sleep`, `ipc_send`/`ipc_recv`, `procs`, `wait` |
| 9–11 | UDP: `udp_listen`, `udp_send`, `udp_recv` (extended by 84–86) |
| 12–20 | Windows: `win_open`/`fill`/`present`/`close`/`move`/`raise`/`get`/`query`/`set_visible` |
| 21–22 | Events: `poll_event`, `wait_event` |
| 23–27 | Files: `file_open`/`read`/`write`/`close`, `dir_list` |
| 28–29 | `exec`, `kill` — spawn and termination |
| 30–33 | TCP: `tcp_connect`/`send`/`recv`/`close` |
| 34–37 | File mutation: `file_delete`/`rename`/`truncate`/`free` |
| 38–39 | The machine-global clipboard |
| 40–41 | Per-process app timers |
| 42–45 | Audio playback: `audio_info`/`play`/`volume`/`mute` |
| 46–55 | Window-management depth: batch fill, resize, drag, z-order, notify, workspaces, unsaved marks, rlimits |
| 56–57 | Shell pipes (bounded 4 KiB, one per process) |
| 58 | Terminal font size |
| 59–60 | ICMP ping seam |
| 61–62 | Window title, `net_stats` |
| 63–64 | `mmap`/`munmap` — anonymous user memory ([[memory]]) |
| 65 | `wmctl` — the registered WM server's exclusive control surface (ADR 0015) |
| 66 | `time` — wall-clock seconds |
| 67 | `tty_attach` — the controlling-terminal seam (ADR 0020) |
| 68–72 | Trust: `principal`, `file_mode`, `secret_get`, `tty_net_auth`, `getrandom` (ADR 0024/0025) |
| 73–74 | `thread`/`futex` — the GOOS=virelai thread + wait/wake seam (ADR 0027) |
| 75–77 | `exnotify` (EL0 fault handler), `sock_ready` (the Go netpoll), `file_sync` |
| 78–80 | `time_set`, `fs_metadata` (the VLFS `/disk` surface), op-dispatched `socket` |
| 81–83 | Observability: `trace`, `profile`, `memstat` (ADR 0043 — see [[services]]) |
| 84–86 | Bound-source UDP: `udp_send_from`/`udp_recv_from`/`udp_close` |
| 87 | `getpid` — an unforgeable self-pid answer (ADR 0048) |
| 88 | `scanout_read` — bounded readback of the displayed framebuffer |
| 89 | `grant_admin` — the in-guest `GRANTS.TXT` row surface, seat/admin gated |
| 90 | `gpucomp` — the bounded GPU-compute seam (opt-in Metal device) |
| 91–92 | Audio capture: `audio_rec_info`/`audio_rec` |
| 93 | `vsock_ctl` — the EL0 door to the host control channel; the kernel holds the credential, no key crosses the seam |
| 94–95 | Nanosecond timing: `sleep_ns`, `timer_set_ns` |
| 96–127 | Reserved — `ENOSYS` |

The two secret-bearing slots — `secret_get` (70) and `tty_net_auth` (71) —
are marked *redacted* in the ABI table: they are never logged, never
traced, and their arguments carry a redacted kind so the observability
ring records zeroed fields for them by construction.

## The EL0 model

A user program runs at EL0 under its own `TTBR0` root and can reach only
its own leaves: its image segments, its stack, its mmap regions, its
library aperture — each with its own permissions under UXN/PXN (W^X).
Kernel RAM, firmware, and every MMIO window are EL1-only under that root,
so a wild user pointer is a permission fault, not a device access.
[[memory]] has the address-space half; [[kernel]] the exception machinery
that makes the `svc` cross.

The seam exists at all because EL0 was proven incrementally before it was
trusted: the first user program was a boot-registered assembly payload
that round-tripped `ping` twice through `svc #0` — the second valid call
being the only possible proof that the first one returned — and the live
chain still asserts that `userspace: el0=1 svc=2 roundtrips=1` line on
every relevant boot.

## Fault-safe uaccess

Pointer-taking syscalls never dereference a user address directly. Every
copy crosses the `uaccess` layer, which validates the range against the
calling task's own armed aperture list (text read-only, stack read-write,
plus whatever regions exec armed) and returns `EFAULT` (`-3`) rather than
faulting the kernel. A range that wraps arithmetic, escapes the apertures,
or targets an unmapped address is rejected before a single byte moves;
a data abort taken *while* a validated copy runs is caught by a masked
recovery window that latches the abort, advances `ELR` past the faulting
instruction, and converts it into the same clean `EFAULT`. The `uaccess`
monitor command provokes a real EL1 data abort into that path on
hardware, and the boot payload's bad-pointer write is the oldest EL0-side
proof on the books.

<Aside kind="info">

**LIVE-GATED.** `live-userspace` pins the EL0 round-trip;
`live-uaccess` the fault-recovery window; `live-svc` the SVC dispatch,
per-row counters, and call ordering; `live-el0-exec` the slot-28
spawn-and-survive contract; `live-sys-kill` the kill seam. Per-feature
gates — `live-user-fs`, `live-ipc`, `live-wait`,
`live-net-udp-syscall`/`live-net-tcp-syscall`, `live-events`,
`live-procs-syscall` — pin the numbered regions row by row.

</Aside>

## Programs and processes

`exec` streams a program out of the host share — flat and staged formats
through a bounded buffer, gap-layout ELF segments streamed directly into
their mapped pages — and spawns it under the same ABI. The bounded argv
block (eight 256-byte slots) rides inside the image, a bounded envp block
follows on the gap path, and the caller's principal — uid and capability
mask — is preserved rather than elevated. Dynamic executables take the
`PT_INTERP` path through `LD.SO`, still entirely freestanding. The
result is a real process with a lifecycle (`created → running → exited →
reaped`), an exit status that outlives its task slot, and a mailbox it
can trade bytes through; [[processes]] covers the lifecycle and IPC half
and [[services]] the supervision layer that now launches the desktop on
top of it.

<Aside kind="warning">

**LIMITATION.** The ABI is deliberately not POSIX: there are no signals,
no `fork`, no file-descriptor model beyond the eight bounded handles, and
no `errno` table that matches a real Unix. Compatibility shims that
pretend otherwise would break the honesty rule — a program either speaks
this ABI or it does not run.

</Aside>
