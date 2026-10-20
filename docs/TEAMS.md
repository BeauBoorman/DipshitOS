# VirelaiOS teams & file ownership

> Rule: **don't touch another team's files — file a GitHub issue against them.**
> This isn't enforced by tooling; it's a convention that lets 3–5 agents
> work in parallel without merge-conflicting each other.

## Teams

### Core — boot, memory, interrupts, EL state

| File | Lines | Role |
|------|-------|------|
| `kernel/src/main.zig` | 2,537 | boot sequence, init order |
| `kernel/src/alloc.zig` | — | physical page allocator |
| `kernel/src/memmap.zig` | — | EFI memory map |
| `kernel/src/mmu.zig` | — | EL1 page tables, TTBR0/TTBR1 |
| `kernel/src/exceptions.zig` | — | VBAR_EL1, sync/IRQ vectors |
| `kernel/src/userspace.zig` | — | EL0 entry contract |
| `kernel/src/uaccess.zig` | — | copy_in/copy_out + fault recovery |
| `kernel/src/console.zig` | — | serial mock + real console |
| `kernel/src/gic.zig` | — | GIC distributor + redistributor |
| `kernel/src/timer.zig` | — | CNTP timer |
| `kernel/src/machine.zig` | — | EFI runtime services, reboot |
| `kernel/src/evidence.zig` | — | NVRAM markers |
| `kernel/src/handoff.zig` | — | loader → kernel handoff |
| `kernel/src/mmio.zig` | — | MMIO accessors |
| `kernel/src/pci.zig` | — | PCI config space |
| `kernel/src/virtio_console.zig` | — | virtio serial console |
| `kernel/src/virtio_custom.zig` | — | custom virtio device (diag) |
| `kernel/src/walkprobe.zig` | — | diagnostic walk probe |
| `kernel/src/nvram_console.zig` | — | NVRAM console fallback |
| `kernel/src/smp.zig` | — | secondary-core bring-up |
| `build.zig` | — | Zig build system |
| `.github/` | — | CI workflows |
| `justfile` | — | developer quick-ref |

**Owns:** Boot pipeline, memory model, interrupt dispatch, exception levels,
platform init. Everything from UEFI exit to the first shell prompt.

### Desktop — the Go seat, rendering, input, windows

The boot default seat is the Go seat `user/go/gotabwm/` (the `wm` settings
key's compiled default); the Zig seats remain reachable via the persisted
fallback (`settings set wm tabwm` → `user/src/tabwm.zig`).

| File | Lines | Role |
|------|-------|------|
| `user/go/gotabwm/` | — | Go seat: tab host, chrome, WM_RPC server |
| `user/go/tabapp/` | — | hosted-tab contract for Go apps |
| `user/go/appkit/` | — | appkit widgets + controllers |
| `user/go/draw/` | — | raster primitives (0xAARRGGBB buffers) |
| `user/go/widgets/` | — | kit controls (scrollbar, toggle, slider) |
| `user/go/chords/` | — | global shortcuts registry |
| `user/go/calc/` | — | calculator app |
| `user/go/note/` | — | notepad app |
| `user/go/top/` | — | task manager app |
| `user/go/files/` | — | file manager app |
| `kernel/src/wnd_core.zig` | 1,233 | pure WM rules, shared kernel shim + EL0 WM |
| `kernel/src/text.zig` | — | framebuffer text renderer |
| `kernel/src/font8x8.zig` | — | 8×8 glyph table |
| `kernel/src/road_pops.zig` | — | Road Pops tee (boot terminal) |
| `kernel/src/input.zig` | — | HID → keycode decode |
| `kernel/src/xhci.zig` | — | XHCI USB host controller |
| `kernel/src/clipboard.zig` | — | kernel clipboard |
| `user/src/tabwm.zig` | — | Zig tabbed seat (persisted fallback) |
| `user/src/wnd.zig` | — | EL0 WM server (Zig) |
| `user/src/lib/ui.zig` | — | Zig UI widget toolkit |

**Owns:** Screen, windows, mouse/keyboard input, UI toolkits, the Go seat
and the hosted desktop apps.

### Net — network stack, TCP, DNS, DHCP

| File | Lines | Role |
|------|-------|------|
| `kernel/src/virtio_net.zig` | 2,439 | virtio-net driver |
| `kernel/src/arp.zig` | — | ARP table + requests |
| `kernel/src/ipv4.zig` | — | IPv4 dispatch, ICMP echo |
| `kernel/src/ipv6.zig` | — | IPv6 dispatch (ADR 0057) |
| `kernel/src/ndp.zig` | — | neighbor discovery |
| `kernel/src/udp.zig` | — | UDP listener table |
| `kernel/src/tcp.zig` | — | TCP state machine |
| `kernel/src/socket_core.zig` | — | TCP socket table |
| `kernel/src/dhcp.zig` | — | DHCP client lifecycle |
| `kernel/src/dns.zig` | — | DNS resolver |
| `kernel/src/csprng.zig` | — | ChaCha20 CSPRNG |
| `kernel/src/virtio_entropy.zig` | — | virtio entropy driver |
| `user/go/fetch/` | — | HTTP fetch client |
| `user/go/ping/` | — | ICMP ping client |
| `user/src/tcp_client.zig` | — | TCP syscall proof |

**Owns:** All network I/O from the virtio queue to the application socket.

### Shell/Process — shell, process model, IPC, app lifecycle

| File | Lines | Role |
|------|-------|------|
| `kernel/src/shell.zig` | 4,641 | interactive shell |
| `kernel/src/monitor.zig` | 9,384 | monitor commands |
| `kernel/src/process.zig` | — | process registry |
| `kernel/src/exec.zig` | — | ELF/flat image loader |
| `kernel/src/elf.zig` | — | ELF parser |
| `kernel/src/scheduler.zig` | 3,783 | task scheduler |
| `kernel/src/mailbox.zig` | — | inter-process mailbox |
| `kernel/src/pipe.zig` | — | shell pipe buffer |
| `kernel/src/events.zig` | — | per-process event queues |
| `kernel/src/app_timers.zig` | — | per-app timers |
| `kernel/src/settings.zig` | — | persistent settings |
| `kernel/src/lineedit.zig` | — | line editor |
| `kernel/src/tokenizer.zig` | — | command tokenizer |
| `kernel/src/scrollback.zig` | — | terminal scrollback |
| `kernel/src/tombstone.zig` | — | crash tombstones |
| `kernel/src/serial_ring.zig` | — | serial event ring |
| `user/src/` | all non-Desktop non-Net Zig apps | user programs |
| `user/go/` | all non-Desktop non-Net Go dirs | Go apps + packages |

**Owns:** Shell, commands, process lifecycle, IPC, event system, all
non-Desktop/non-Net user programs.

### Storage/Files — host file channel, file table, disk image

| File | Lines | Role |
|------|-------|------|
| `kernel/src/virtio_file.zig` | 1,997 | host file channel (queue 5) |
| `kernel/src/virtio_fs.zig` | — | virtio-fs/FUSE host share client |
| `kernel/src/vlfs/` | — | VLFS journaled volume (ADR 0050) |
| `kernel/src/file_table.zig` | — | per-process file handles |
| `kernel/src/directory.zig` | — | directory table |
| `kernel/src/fs_metadata.zig` | — | stat/metadata path |
| `kernel/src/fat32_ro.zig` | — | read-only FAT32 (`.usb` device tree) |
| `kernel/src/virtio_blk.zig` | — | virtio-blk driver |
| `kernel/src/usb_msc.zig` | — | USB mass-storage (BOT + SCSI) |
| `image/mkfat32.py` | — | FAT image builder |
| `image/make-image.sh` | — | disk image assembly |
| `image/apps.txt` | — | application manifest |

**Owns:** Everything from the host file channel and the block devices to
the file descriptor table.

### VZ/Host — host runner, CI, gate fleet, tools

| File | Role |
|------|------|
| `host/vm-runner/` | VZ host launcher (Swift) |
| `tools/gate/` | declarative gate fleet (SPEC.md, specs/, fleet.sh) |
| `tools/status/` | claim + coordination tooling |
| `tools/tests/` | host-side Python unit tests |
| `tools/lib/` | shared gate helpers |
| `tools/verify-*.sh` | class-A verify gates |
| `tools/elf2bin.py` | ELF → flat image converter |
| `tools/mkhello-elf.py` | example ELF generator |
| `tools/decode-screen-glyphs.py` | glyph screenshot decoder |
| `AGENTS.md` | repo rules for agents |
| `docs/status.md` | living status |
| `docs/testing.md` | testing policy |
| `docs/gate-inventory.md` | gate classification |
| `docs/gate-fleet-inventory.md` | generated fleet snapshot |
| `docs/decisions/` | ADRs |
| `docs/archive/agent-concurrency-plan.md` | lane assignments (closed-arc plan, archived by #1671) |
| `docs/TEAMS.md` | this file |
| GitHub issues (label `claim`) | active-work claims |

**Owns:** Host tooling, CI, gate infrastructure, docs (except ADRs owned
by the relevant team).

## Shared files: the syscall table

`kernel/src/syscall.zig` (5,410 lines) is touched by every team that adds
a new service. Convention:

1. **File a GitHub issue** before you need a slot. Issue title: "Reserve
   syscall slot N for `<purpose>`". Tag the Core team.
2. **Core owns the dispatch table structure** — they add the slot number,
   the handler stub, and bump `implemented_count`.
3. **Your team implements the handler function** (in a file you own) and
   Core plumbs it into the dispatch.
4. **Event kinds** follow the same pattern: file an issue, Core reserves
   the kind number in `kernel/src/events.zig`, your team uses it.

## Cross-team dependency rule

When you need something from another team's zone, you file a **real
GitHub issue** on the project repository. The issue body should state:

- What you need (precisely)
- What depends on it (so they can prioritize)
- What the interface is (function signature, syscall slot, event kind)

Do not just edit another team's file and hope they notice. The issue
is the coordination surface.

## Active work tracking

Claims are **GitHub issues labeled `claim`** (see `AGENTS.md`): file one
before starting non-trivial work, comment progress on it, close it when
done. The coordination gate
(`bash tools/status/verify-issue-coordination.sh`) fails when two open
claim issues from different branches declare overlapping file touches.
The old docs/claims + docs/logs file tracker and its generated indexes
were deleted 2026-09-03.
