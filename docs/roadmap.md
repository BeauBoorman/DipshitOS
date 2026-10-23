# VirelaiOS roadmap

> Live gate-by-gate status is tracked in [`docs/status.md`](status.md). This
> roadmap is the milestone plan; it does not track day-to-day gate progress.
>
> **Completed-milestone plans live in git history** — the verbatim
> `roadmap-m{N}.md` plans (moved from this file by issue #264 / claim
> 2860), the per-card `march-m*.md` trackers, and the `status-m*-detail.md`
> notes are condensed into [`docs/archive/era-m0-m51.md`](archive/era-m0-m51.md)
> (issue #3228); the digest names each file and pins the commit where it
> last lived. This file holds pointers, the current position, and the
> wishlist.

## Completed milestones (M0–M16) — archived plans

- **M0 — boot pipeline proof** — done; a Zig AArch64 UEFI app boots from
  `EFI/BOOT/BOOTAA64.EFI` on a FAT image under real firmware.
- **M1 — separate kernel image handoff** — done (ADR 0002); loader places
  `\KERNEL.BIN` at `base+0`, jumps to its entry.
- **M2 — the kernel proper** — done; ExitBootServices, identity-map MMU,
  polled virtio TX console (ADR 0004); VZ serial gate passed 2026-08-08
  (claim 1517).
- **M1.5 — interactive kernel monitor ("Virelai Monitor")** — closed
  2026-08-09, tag `m1.5-interactive-monitor`, 7/7 gates.
- **M3 — allocator, interrupts, tasks, EL0/SVC, syscalls, uaccess,
  userspace** — closed 2026-08-10, tag `m3-userspace` (claim 0707).
- **M4 — real randomness, general filesystem, processes & follow-ons**
  (entropy + ChaCha20 CSPRNG, DATA partition, process abstraction,
  concurrent/long-lived/kill, IPC mailbox, argv, wait) — closed
  2026-08-11, tag `m4-processes` (claim 2839).
- **M5 — networking** (virtio-net TX/RX, ARP, IPv4/ICMP, UDP, NAT, DHCP
  lifecycle, TCP + retransmission, UDP syscall seam N1–N11) — done
  2026-08-12 (claims 1373…5357).
- **M6 — graphics: Driving Award + Road Pops** (virtio-gpu G1–G6 plus the
  window-syscall follow-on slots) — done 2026-08-13 (claim 0487).
- **M7 — input: USB XHCI + HID** (I1 transport, I2 enumeration + HID,
  I3 event FIFO → Road Pops) — done 2026-08-13 (claim 6050) *(the historical cross-milestone
  virtio device surface table is in the era record too — `roadmap-m7.md`
  via the [era digest](archive/era-m0-m51.md))*.
- **M8 — usability: human interface** (ADR 0008; grouped help, line
  editor/history, error contract, window HIG; U4 pointer focus remains a
  known class-C-only thread, issue #151) — done 2026-08-15 (claim 2649).
- **M9 — app events** (per-process event queues, `sys_poll_event` 21 /
  `sys_wait_event` 22, E0–E6) — done 2026-08-15 (claim 9328).
- **M10 — userland filesystem & storage ABI** (ADR 0010; per-process file
  table, path canon, slots 23–27, the original SAVETEXT/TYPE/DIR demos, F0–F4;
  live storage coverage now uses GOSH/GOFILES) — done 2026-08-15 (claim 0510).
- **M11 — desktop platform** (ADR 0011; ui.zig toolkit, the original
  CALC/NOTEPAD/TOP/DESKTOP programs, `sys_exec` 28 / `sys_kill` 29, A0–A5;
  launcher and client coverage now uses GOTABWM plus Go clients) — done
  2026-08-16 (claim 2427).
- **M12 — userland network applications** (ADR 0012; TCP slots 30–33 and the
  original DNS/FETCH/CHAT programs, N0–N3; product clients are now Go) — done
  2026-08-16, PR #160 (claim 5416).
- **M13 — files & applications** (mutating FS slots 34–37, APPS.TXT
  manifest, FILE.BIN browser, manifest desktop; B1–B4) — done 2026-08-16
  (claims 5801/8877/4742/4046).
- **M14 — shared user services** (clipboard 38–39, app timers 40–41,
  NOTEPAD composition capstone, hardening audit; S1–S4) — done 2026-08-18
  (claims 0169/7323/3289/4482).
- **M15 — audio** (virtio-snd DID 0x1059, PCM playback, sys_audio 42–45,
  JINGLE/CHIME.BIN, boot chime; A1–A4) — done 2026-08-18 (claim 3206).
- **M16 — the kernel grows up** (DSK3 segmented images + writable data/BSS,
  guard pages, grown pools, page-table budget 512; C1–C4) — done
  2026-08-19 (claims 3805/8403/0339/2714).

## Current position & next work (M17+)

> The canonical, always-current answer to "where are we" is
> [`docs/status.md`](status.md); active per-card detail lives in open
> `claim` issues on the GitHub tracker (label
> `claim`). This section stays pointer-level so it cannot go stale.

- **M17 — desktop completeness** (issues #212–#228; arcs 1/2 of the M14-era
  grooming): completable widgets (Checkbox/Toggle, ProgressBar,
  ScrollView…), NOTEPAD depth, FILE.BIN preview/breadcrumbs, TOP sort/
  filter, CALC keyboard/history, SETTINGS theme preview. Shipped
  2026-08-21 — full card detail condensed into the
  [era digest](archive/era-m0-m51.md).
- **Post-M17 arcs** — ALL DONE 2026-08-21:
  - **Arc1 — widget depth**: ScrollView, Checkbox/Toggle, ProgressBar,
    Dialog, HScrollBar, DropDown. PRs #259–#261.
  - **Arc2 — window management**: drag-to-resize, context menus, system
    tray. PRs #271–#273, claim 1264.
  - **Arc3 — app upgrades**: NOTEPAD wrap/find, FILE.BIN preview/breadcrumbs,
    TOP sort/filter, CALC keyboard/history, SETTINGS live preview.
  - **Arc4 — rich interactions**: mouse wheel, drag-drop, z-order,
    animations, notifications, workspaces, unsaved dialog.
    PRs #274–#280.
  - **Arc5 — system polish**: compose sequences (ADR 0014), tombstones,
    graceful shutdown, resource limits, settings migration.
    PRs #287–#289.
- **M18–M27 — the experience layer**: the forward roadmap covering
  terminal depth, shell programming, Unicode, window management polish,
  developer tools, a text editor, CALC depth, file manager, network
  apps, and desktop polish. Full card detail condensed into the
  [era digest](archive/era-m0-m51.md).
- Known open threads carried across milestones: M8 U4 pointer focus is
  class-C-only for its live proof (issue #151, claim 4769), and the
  synthesized keyboard seam reports `events=0` (issue #179).

## Wishlist / hope chest (destinations, not commitments)

> **Maintainer's wishlist (2026-08-14).** These are *destinations*, not a
> milestone ladder — a hope chest, roughly in the order the maintainer would
> like to reach them, but nothing here is a promise and the roads between them
> stay open. If dependency discoveries reshuffle these (e.g. `M9 interactive
> apps → M10 user files → M11 application platform`), that is the point. No
> agent should treat an item here as a green-light to climb a mountain just
> because it is visible on the map.

The bridges the maintainer would be **most disappointed to see omitted** —
from "very capable kernel" to "weird little computer" — are **EL0 application
events, userland filesystem access, consumer apps, and a lightweight
app/launcher model** (items 2, 5, 4, and 10 below).

1. **Finish M8 as the usability consolidation milestone.** Help,
   editing/history, coherent errors, pointer focus/cursor, window chrome,
   first-boot experience, `sysinfo`, persistent settings — no giant new
   subsystem hiding inside it. *(This is the current, real milestone — see
   above.)*
2. **Interactive EL0 application events** *(the biggest near-term want)*.
   Per-process event queues: keyboard, pointer/button, focus/blur, close
   requests, and probably a blocking/polling event syscall. This is what turns
   graphical syscall demos into actual applications.
3. **A tiny userland application support layer.** Not a GUI framework — just
   enough shared Zig for app startup, event loops, windows, drawing, basic
   strings, and syscall wrappers. Build a couple apps first and extract only
   what they genuinely duplicate.
4. **Several deliberately small GUI apps.** Calculator, a notepad-ish thing,
   process viewer, network monitor, a dumb paint thing. Architectural probes
   disguised as toys: if every one needs a kernel modification, the app
   boundary is wrong.
5. **Userland filesystem access.** Handles (or a Virelai-native equivalent),
   read/write/create, directory enumeration, metadata, paths — deliberately
   **before** any graphical file manager.
6. **A graphical file browser.** Read-mostly at first: browse DATA, open text
   files; create/rename/delete later. The integration proof for events +
   windows + filesystem APIs.
7. **Userland TCP/network API.** UDP already crossed the boundary; eventually
   let EL0 own connections without cloning POSIX sockets by reflex. Then make
   a real user network client consume it.
8. **DNS.** Once an EL0 network app exists, numeric IPs get stupid fast. Keep
   it bounded and boring initially.
9. **Application identity/metadata.** A tiny manifest or image-metadata
   concept: name, executable, maybe an icon later, the file types it
   understands — so the launcher/file manager stop hardcoding knowledge.
10. **A launcher.** Could start hilariously simple: list installed apps, run
    one. Alongside the file browser, this is when VirelaiOS gets a recognizable
    "desktop" shape.
11. **Clipboard / shared user-interaction services.** Probably later; text
    apps will make the absence obvious. Discover the right IPC/service model
    through this rather than inventing "system services" abstractly.
12. **Timers/events available to applications.** Apps shouldn't spin or invent
    sleep loops to animate/update; a clean timer-event mechanism fits after the
    event queue exists.
13. **Resource-model cleanup when the fixed pools hurt.** Windows, processes,
    mailboxes, and network state are wonderfully bounded now — keep them that
    way until real apps expose actual pain, *then* introduce dynamic kernel
    objects/allocators because the workload demands it. *(Started 2026-08-19 —
    M16 C3, claim 0339: the scheduler executor pool grew 7→11 (8 live user
    programs) because the apps exhausted the old four; the other pools stay
    bounded — the "grow only what hurts" rule applied, live on VZ.)*
14. **Richer virtual memory only when applications force it.** More flexible
    mappings, guard pages, larger programs, maybe mmap-ish primitives, COW much
    later. No demand paging merely because Serious-OS bingo says so. *(Started
    2026-08-19 — M16 C2, claim 8403: guard pages below the stack / above the
    data segment and EL0-fault → reap, live on VZ.)*
15. **Executable-format evolution.** The DSK1 flat-image model has done heroic
    work; larger programs/libraries may eventually justify ELF loading or
    another structured native format. Consumer first. *(Started 2026-08-19 —
    M16 C1, claim 3805: the DSK3 segmented image with writable data + zeroed
    BSS and a 256 KiB load bound, live on VZ.)*
16. **Reusable UI toolkit, but late.** Buttons, labels, text fields, lists,
    scrolling, layout — *after* two or three hand-built apps have shown what
    the common pieces actually are. Otherwise someone lovingly architects
    GTKvirelai before anyone has clicked a button.
17. **Better filesystem semantics eventually.** Atomic-ish updates, truncation,
    deletion, rename, free-space management, corruption handling, maybe beyond
    FAT32 someday — but let applications create the pressure first.
18. **Audio eventually.** Fun, and another real device/service pipeline. Not
    remotely urgent; on the "VirelaiOS becomes a computer" list.
19. **Security/isolation hardening.** More permissions around resources,
    stronger validation of userspace-controlled arguments, process ownership
    everywhere, maybe capabilities — grown *alongside* userland power, not as
    one giant Security Milestone.
20. **Distant mountains (keep visible, do not climb yet).** SMP, 3D
    acceleration, dynamic linking, sophisticated VM, POSIX compatibility,
    browser-grade networking, USB-everything. Keep them on the map so nobody
    thinks we forgot them — but no agent should see "mountain" and immediately
    buy climbing gear.

## Meta-requirement for the roadmap

> Every major infrastructure card should name the small program or experience
> that will consume it next. Every milestone should end with a composition test
> that a human can see or use.
