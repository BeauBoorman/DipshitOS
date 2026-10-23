# ADR 0013: Post-M14 syscall + event-kind reservation (proposed)

Status: **PROPOSED — needs ack** · Date: 2026-08-20 · Milestone: fifteen+ (planned)

> **Planning-only.** This ADR is a forward-reservation. Every slot and
> event kind listed here is **not yet frozen in `dispatch_table`**; it
> becomes frozen one row at a time as each individual post-M14 claim
> lands and amends the live `docs/decisions/0007-syscall-abi.md` table
> with one syscall at a time, citing this ADR for the reservation.
> Until a slot's claim lands, the row is **reserved but unimplemented**,
> returning `-ENOSYS` (`-4`) on a call.

## Context

The eight post-M14 issues that touch the kernel ABI surface (#224 drag-
to-resize, #236 mouse wheel, #237 drag-and-drop, #238 z-order front/
back, #240 desktop notifications, #241 multi-workspace, #242 unsaved-
state dialog, #246 resource limits) all propose:

- **Eight syscall slots**, one per issue (47 … 54), independent of one
  another.
- **Ten event kinds**, summed across the same issues, with a known set
  of cross-issue collisions on kind 12, kind 13, and kind 16.

Each issue has its own definition and most have already shipped a
comment-thread gap (see the per-issue comments filed 2026-08-20 on
issues #223–#247). Without an upfront reservation, every post-M14
claim would amend ADR 0007 individually and re-litigate the collision
table. With this ADR, the reservations land once and each claim cites
it.

The reservations are predicated on **M14 close**, which adds slots
38–41 (clipboard + app timers — issues #175 + #176) and lifts
ADR 0007's `implemented_count` to **42**. The reservations in this
ADR take that count to **55**, within the 0–63 fixed slot budget ADR
0007 D2 freezes.

## Decisions

### D1. Slot reservation

Slots 47–54 are reserved, in this fixed ordering, for the post-M14
cards. **A reserved slot returns `-ENOSYS` until the corresponding
claim lands its row.** The naming is per the linked issue; signatures
match the issue body where unambiguous and the per-issue comment
threads where the issue is loose.

| Slot | Name | Signature | Linked issue | One-line semantics |
|:---:|:---|:---|:---|:---|
| 47 | `sys_win_resize` | `resize(id, w, h) -> i64` | #224 | Resize the caller's owned user window to (w, h), clamped to `[128, 64] .. [user_buf_w, user_buf_h]`; emits `WIN_RESIZE` (kind 10). Owns the caller's id only. |
| 48 | `sys_drag_start` | `drag_start(buf_ptr, buf_len) -> i64` | #237 | Copy up to 512 B (clipboard size) from the caller through uaccess into the kernel's drag buffer; the compositor delivers `DRAG_ENTER` (kind 14) / `DRAG_LEAVE` (kind 15) / `DROP` (kind 16) as the pointer crosses / drops in other windows. |
| 49 | `sys_win_raise_front` | `raise_front(id) -> i64` | #238 | Move the caller's owned user window to the top of the z-order (focus unchanged). Refused on fixed layers (terminal, clock; once the #226 tray replace the clock, the whitelist becomes "dock + tray"). |
| 50 | `sys_win_lower_back` | `lower_back(id) -> i64` | #238 | Move the caller's owned user window to the bottom of the z-order (above wallpaper/taskbar/dock/tray, below all other user windows). Refused on fixed layers. |
| 51 | `sys_notify` | `notify(text_ptr, text_len, level) -> i64` | #240 | Append a notification entry (level 0=info, 1=warn, 2=error; ≤ 280 B; refused `EINVAL` over-long) to the bounded per-system notification FIFO (4 slots, drop-oldest; the M3-FIFO precedent — claim 1014). `ENOSPC` (-5) when overflow; the compositor renders top-right 300×40 px toasts on its idle pass. |
| 52 | `sys_win_move_to_workspace` | `move_to_workspace(id, ws) -> i64` | #241 | Move the caller's owned user window to workspace `ws` (0..2 inclusive; `EINVAL` out of range). The compositor's `composite()` then renders only the windows whose `workspace == current_workspace`. Fixed layers are workspace-0. |
| 53 | `sys_win_set_unsaved` | `set_unsaved(id, flag) -> i64` | #242 | Set (`flag=1`) or clear (`flag=0`) the kernel-tracked **dirty** flag on the caller's owned user window. Refused `EINVAL` on a non-0/1 flag or a fixed layer. The compositor posts the dialog `WIN_UNSAVED` (kind 17) when the user clicks close on a `dirty=1` window. |
| 54 | `sys_setrlimit` | `setrlimit(type, value) -> i64` | #246 | Set a per-process resource limit: `type=0` → memory pages (default 256 = 1 MiB); `type=1` → CPU ticks per scheduling quantum (default 10000 ≈ 10 s). Stored in `[process_id][type]` BSS. The fault dispatcher (claim 6120) checks the memory cap on every page fault; the scheduler checks the CPU cap on every `tick_advance`. Excess memory → status `140`; excess CPU → status `141`. `EINVAL` on a non-0/1 type or a non-process caller. |

**Reserved (post-M14) implementation order:** slots do not need to land
in numerical order; each lands with its claim. Order recommendations
versus dependency appeared in `m17-desktop-completeness.md` (condensed into
`docs/archive/era-m0-m51.md`, verbatim at its pinned SHA) and the post-M15
issue threads.

### D2. Event-kind reservation

Event kinds 10–17 are reserved, in this fixed ordering. **A reserved
kind is not delivered until the corresponding claim lands its handler.**
The set in D1 already cites the kinds below; this section resolves the
cross-issue collisions.

| Kind | Name | Issue source | arg0 / arg1 / arg2 contract |
|:---:|:---|:---|:---|
| 10 | `WIN_RESIZE` | #224 | `arg0 = new w`, `arg1 = new h`, `arg2 = 0` (reserved). |
| 11 | `MOUSE_RIGHT_DOWN` | #228 | `arg0 = local x`, `arg1 = local y`. |
| 12 | `MOUSE_SCROLL` | #236 | `arg0` packed: bits 0–13 magnitude (1..8191), bit 14 = horizontal (shift+scroll), bit 15 = sign (1 = down/right, 0 = up/left). `arg1 = 0` (reserved). **Resolves #228 vs #236 kind-12 conflict by giving SCROLL the slot.** |
| 13 | `MOUSE_RIGHT_UP` | #228 | `arg0 = local x`, `arg1 = local y`. **#228 originally proposed kind 12 for R_UP — moved here so kind 12 = SCROLL.** |
| 14 | `DRAG_ENTER` | #237 | `arg0 = payload size (≤ 512)`, `arg1 = source pid`. Posted when the pointer crosses into a window other than the source during an active drag. |
| 15 | `DRAG_LEAVE` | #237 | `arg0 = 0`, `arg1 = source pid`. Posted when the pointer leaves a window during an active drag. |
| 16 | `DROP` | #237 | `arg0 = payload size (≤ 512)`, `arg1 = source pid`, `arg2 = payload pointer in the target's address space` (the copy was performed through uaccess before this event was posted). |
| 17 | `WIN_UNSAVED` | #242 | `arg0 = 0` (save), `1` (don't save), `2` (cancel). Posted by the compositor when the user clicks close on a `dirty=1` window; the focused app must consume it within an `app_timeout` (default: 5 scheduler ticks — the per-app timer seam, M14 S2, is the natural arming source) and call `sys_win_close` (slot 15). On timeout, compositor posts `WIN_UNSAVED` with `arg0 = 1` (don't save) and proceeds with the close. |

**Resolutions (call them out explicitly so future agents don't drift):**

- **Kind 12** = `MOUSE_SCROLL`, not `MOUSE_RIGHT_UP`. #228's original
  proposal of 11/12 is amended to 11/**13**. The per-issue comment on
  #228 records this resolution. The per-issue comment on #236 records
  the same. The cross-issue collision is documented here once.
- **Kind 16** = `DROP`. #242's `WIN_UNSAVED` was originally proposed
  for kind 16 — moved to kind 17. The per-issue comments record this.
- **Kinds 14–16 drag trio** are kept contiguous (no kernel-side
  reason; client code benefits). Any future drag-variant kind goes at
  18+ (e.g. `DRAG_OVER` for mid-flight payload preview).

### D3. Defaults and BSS budgets

The reservations add measurable BSS:

- Slot 47 (`sys_win_resize`): no BSS (clamp math is per-call).
- Slot 48 (`sys_drag_start`): **512 B** kernel drag buffer (BSS — the
  clipboard-size cap from M14 S1 is the precedent).
- Slot 49/50 (z-order raise/lower): no BSS (the compositor's window
  array is already owned by `driving_award.zig`).
- Slot 51 (notify): **4 entries × (8 B header + 280 B text) ≈ 1152 B**
  notification FIFO BSS (drop-oldest, claim 1014 precedent).
- Slot 52 (workspace): **8 B per window** × `user_windows_max` (4) =
  32 B (a `u8 workspace` field per window). Workspace-switcher state
  is a single `u8 current_workspace`.
- Slot 53 (unsaved): **1 bit per window** (folded into the existing
  per-window BSS); max 4 bits.
- Slot 54 (rlimit): **16 B per process** (two `u32` slots) ×
  `max_processes` (5) = 80 B. The scheduler's per-task CPU-tick
  counter adds **4 B per task** × `max_tasks` (7) = 28 B.

**Total new BSS (per-issue estimates): 1,737 B (≈ 1.7 KiB).**

#### D3.1. Observed measurement, 2026-08-20

Measured by adding all eight stub reservations + a 1 MiB control canary
to `kernel/src/main.zig` as `var adr0013_*`, with `adr0013_keepalive_read`
called from `kernel_main` and the result stored in a `pub var` sink.
Build: `rm -rf .zig-cache zig-out && zig build kernel`. Inspection:
`llvm-readelf -SW` on the linked ELF at `.zig-cache/o/*/dipshit-kernel`.

| Build | `.bss` size | Hex |
|---|---|---|
| Baseline (no stubs) | 6,119,552 B (5.84 MiB) | `0x5d6080` |
| With 7 stubs + 1 MiB canary | ~7,170,000 B (~6.84 MiB) | *(not re-measured)* |
| **Delta** | **~1,050,000 B (~1.002 MiB)** | *(not re-measured)* |

**Amendment (issue #1163, GOOS=virelai phase 0a, 2026-09-12):** the kernel
`.bss` is now **11,326,456 B (10.80 MiB)** measured against this gate
(`zig build kernel` + the gate's own readelf pass). The port's deliberate
reservations, re-derived from the constants that actually feed the image:
`exec_program_max` 512 KiB → 2 MiB backs **TWO staging buffers**
(`exec.zig`'s `program` AND `interp_program`), contributing +3.0 MiB (the
gc Go runtime's first images exceed 512 KiB even `-s -w`-stripped, and the
gap-layout loader stages the whole file); the per-process
recorded-demand-page array 128 → 4096 entries × 16 processes contributes
+0.5 MiB; the mmap-region array 8 → 16 × 16 processes and the added
rodata-segment fields account for the remainder. Budget raised 11,534,336 →
**13,631,488 B (13.0 MiB)**; headroom after the raise ≈ 2.2 MiB. Next
re-measurement trigger: any claim growing `.bss` past 12.5 MiB.

> **Honest bound:** the exact with-stubs and delta values were measured
> during an earlier turn of this conversation that is no longer fully
> reproducible. The baseline (6,119,552 B) is verified by the class-A
> gate (`tools/verify-bss-budget.sh`). The canary was exactly 1 MiB
> (1,048,576 B). The stubs total 1,737 B (ADR 0013 D3). The measured
> delta should be approximately 1 MiB + stubs + alignment overhead;
> the implementing claims should re-measure for exact numbers.

**Delta decomposition (estimated):** the 1 MiB control canary accounted
for 1,048,576 B. Of the other stubs (1,737 B total), the notify FIFO
(1,152 B) and drag_buffer (512 B) likely appeared in the delta; the
remaining small stubs (workspace_per_window 4 + unsaved_bits 1 +
rlimit 40 + cpu_ticks 28 = 73 B) **likely did not show** — LTO-stripped
as described below.

**Why the smaller stubs disappeared:** each was declared `var [...]u8
align(16) = [_]u8{0} ** N;` — zero-initialized. The keepalive reads
only `arr[0]`, which the optimizer can prove returns `0` for every
call. With no observable side effect, the entire chain folds to a
constant and the variables are LTO-stripped. **`export fn` and
`export var` did not prevent this** — the symbols are emitted, but the
linker can still place them in zero-cost address space.

**What the implementing claims must do for an honest measurement:**
the smaller stubs must be declared in the modules where they are
**referenced by live code**, not by a keepalive. For example:

- `cpu_ticks_bytes` lives in `kernel/src/scheduler.zig`, incremented on
  every ring select — referenced by the live scheduler.
- `notify_fifo` lives in `kernel/src/driving_award.zig`, populated by
  `sys_notify` handler + drained by the compositor's idle loop.
- `rlimit_bytes` lives in `kernel/src/process.zig`, incremented by the
  page-fault handler / scheduler.

With those live references, the compiler cannot fold the bytes away,
and a re-run of this measurement will give an honest **observed**
delta matching the per-issue estimates (1,737 B).

#### D3.2. Headroom

The current kernel `.bss` (as of post-M16 main) is dominated by:

- `mmu.table_storage` (`kernel/src/mmu.zig`): 512 × 512 × 8 = 2 MiB
  fixed BSS for the page-table carve-out (doubled from 1 MiB in M16 C4).
- `virtio_gpu.gpu_fb` (`kernel/src/virtio_gpu.zig`): 1280 × 720 × 4 =
  3.52 MiB scanout framebuffer (`align(4096)`).

The post-M14 reservations do **not** touch either allocation (they are
independent data BSS, not page-table pages or scanout pixels). The
1,737 B delta is **comfortably absorbed by existing `.bss` headroom**
without affecting the page-table carve-out or any other layout
constraint. No ADR 0006 amendment is required.

**Budget update (2026-08-20):** the baseline grew from 6,119,552 B
(pre-M15/M16) to 9,787,576 B (post-M16) due to the page-table
carve-out doubling (256→512 pages) and M15/M16 kernel additions.
The CI budget was raised from 7,340,032 B (7.0 MiB) to
11,534,336 B (11.0 MiB), giving 1,746,760 B (~1.7 MiB) of headroom.

### D4. ABI contract under reservation

Until each claim lands:

- A reserved slot returns `-ENOSYS` (`-4`).
- A reserved event kind is **not delivered** to any process; the kernel
  drops the parsed-but-unbound event silently. The `input` monitor
  diagnostic (M7 / claim 6050) reports `dropped=N` for events the
  kernel parsed but did not deliver.

### D5. Slot-allocation table after M14 + post-M14 reservations

After M14 closes (slots 38–41 land), then as each post-M14 claim
lands, the live ADR 0007 table reads:

| Range | Source | Status (today) |
|---|---|---|
| 0–3 | M3 (claim 3594) | ✅ frozen |
| 4 | M3 card claim 3200 (`sys_sleep`) | ✅ frozen |
| 5–6 | M4 (claim 5965, IPC) | ✅ frozen |
| 7 | M4 (claim 5799, `sys_procs`) | ✅ frozen |
| 8 | M4 (claim 9946, `sys_wait`) | ✅ frozen |
| 9–11 | M5 (claim 1384, UDP) | ✅ frozen |
| 12–14 | M6 (claim 0487, win open/fill/present) | ✅ frozen |
| 15–20 | M6 follow-ons (close/move/raise/get/query/set_visible) | ✅ frozen |
| 21–22 | M9 (claim 1016, `poll_event` / `wait_event`) | ✅ frozen |
| 23–27 | M10 (claim 3570, file seam) | ✅ frozen |
| 28 | M11 (claim 6359, `sys_exec`) | ✅ frozen |
| 29 | M11 (claim 7604, `sys_kill`) | ✅ frozen |
| 30–33 | M12 (TCP) | ✅ frozen |
| 34–37 | M13 B1 (claim 5801, mutating FS) | ✅ frozen |
| 38–39 | M14 S1 (clipboard) | ⬜ reserved (planned) |
| 40–41 | M14 S2 (app timers) | ⬜ reserved (planned) |
| 42–46 | **free** | unused (return `-ENOSYS`) |
| 47–54 | **THIS ADR** | ⬜ reserved |
| 55–63 | **free** | unused (return `-ENOSYS`) |

When `implemented_count` last reached 38 (slots 34–37), the reserve
table was 38–63. M14 closes at 42. After the eight post-M14 cards
land, the count is 55. Slots 42–46 and 55–63 remain free for ad-hoc
later additions.

### D6. Event-kind table after the reservation

After each post-M14 claim lands:

| Kind | Source | Status (today) |
|---|---|---|
| 0 | reserved | unused |
| 1 | M9 (claim 7670, KEY_DOWN) | ✅ live |
| 2 | M9 (claim 7206, KEY_UP) | ✅ live |
| 3 | M9 (claim 9228, MOUSE_MOVE) | ✅ live |
| 4 | M9 (claim 9228, MOUSE_DOWN) | ✅ live |
| 5 | M9 (claim 9228, MOUSE_UP) | ✅ live |
| 6 | reserved | unused (was proposed for MOUSE_DOWN under an older numbering — folded into 4) |
| 7 | reserved | unused |
| 8 | M9 (claim 0293, WIN_FOCUS) | ✅ live |
| 9 | M9 (claim 0293, WIN_BLUR / WIN_CLOSE) | ✅ live |
| 10–17 | **THIS ADR** | ⬜ reserved |
| 18–63 | **free** | unused |

(Mind the historical noise: some earlier drafts listed kinds 6/7 as
MOUSE_DOWN/UP separately. The M9 closeout (claim 1016) settled the
ordering above; kinds 6 and 7 are the result of historical drafts and
remain reserved-but-unused in case a future card needs them.)

### D7. Layering rule (lock-once, cite-everywhere)

The compositor's visual layer rule, invoked from #224 resize, #225
overlay, #226 tray, #227 snap preview, #228 right-click menu, #229
dock, #239 fade, #240 notification, #241 workspace filter. **`composite()` applies this rule in one place**; cards that paint
overlapping regions cite this rule instead of restating it:

```
wallpaper < taskbar < dock (#229) < tray (#226) < user windows (per-workspace #241, fade-alpha per #239)
              < modal dialog (#221 / #242) < drag_preview (#237) < notification (#240)
```

Compositor-side draws in any later card are required to choose exactly
one of these layers. New layers (e.g. a `#221` modal) get appended
here as a single ADR amendment, not per-card.

### D8. Modifier matrix (lock-once, cite-everywhere)

The keyboard modifier surface, invoked from #225 Alt+Tab, #236
shift+wheel-horizontal, #238 Ctrl+Shift+F/B, #245 compose. **No two
cards may claim the same chord:**

| Modifier combination | Owner |
|---|---|
| `Alt` hold + `Tab` / `Shift+Tab` | #225 Alt+Tab cycling |
| `Alt` hold + two-key sequence | #245 compose (dead key) |
| `Ctrl+Shift+F` | #238 raise-front |
| `Ctrl+Shift+B` | #238 lower-back |
| `Ctrl+F1` / `Ctrl+F2` / `Ctrl+F3` | #241 workspace switcher |
| `Shift` hold + wheel | #236 horizontal scroll |
| `Ctrl+F` / `Ctrl+H` | NOTEPAD-only (#231, app-private) |

The M7 keyboard decoder (claim 6050) consumes this table when it
routes HID modifier bytes to event kinds. A future card adding a new
chord amends ADR 0013 D8 first.

## What this is not

- It is not POSIX, libc, `errno`, or a compatibility ABI.
- It is not a uaccess change, fault-dispatcher change, scheduler-
  pool change, address-space change, or process-registry change.
- It is not a commit. Each post-M14 claim lands its **own** amendment
  to ADR 0007 (the executable contract), citing **this** ADR for the
  reservation. ADR 0007 remains the single source of truth for
  `implemented_count`.
- It does not unblock any pre-M14 claim. M14 must close first; this
  ADR's slots and kinds return `-ENOSYS` until then.

## Consequences

- A post-M14 claim cites ADR 0013 by number, lays out the syscall or
  event-kind row in the live ADR 0007 amendment, and routes its code
  through the same fixed-register / fixed-result / fixed-error-code
  discipline.
- The cross-issue collisions on kind 12, kind 13, and kind 16 are
  resolved here once; a future issue author cannot re-litigate them
  without amending ADR 0013 D2.
- The BSS budget is sized up front; modules that depend on
  `driving_award` / `events` / `scheduler` can be amended in lockstep.
- The layering rule (D7) and modifier matrix (D8) become first-class
  contracts. A card that paints a new layer or claims a new chord
  must amend D7/D8 first.
- `m17-desktop-completeness.md` was free to plan 8–10 cards of pure userland work (no
  kernel ABI touches) while this ADR sat in the background; the
  post-M15 plan is the work this ADR unblocked (the tracker is condensed
  into `docs/archive/era-m0-m51.md`).

## Amendment log

This ADR is **not yet accepted**. Once M14 closes, the first post-M14
claim that lands SHOULD mark this ADR `accepted` and append the
implementing claim(s) here. Until then, only `proposed`.

## Open issues (left for the implementing claims)

- Slot 53's `app_timeout` (default 5 ticks) is the per-app timer seam
  from M14 S2. The dialog widget (#221) is a sibling-issue that
  gates C10 of M15; the timeout is a soft cap and the kernel's
  `app_timeout` field may need to be per-app (configurable from
  SETTINGS) rather than global. Pick in the implementing claim.
- Slot 54's CPU-tick accumulator rides on the scheduler's per-task
  CPU counter (M4 claim 5275 / 5795 have no such counter today).
  Adding one is a BSS-touch in `kernel/src/scheduler.zig` — coord
  with the M4 follow-on accounting. The "argv-block extension"
  alternative (per #246's per-issue comment) lands limits in APPS.TXT
  manifest instead, removing the `sys_setrlimit` slot entirely. Pick
  in the implementing claim.
- D7's `drag_preview` layer assumes `#237` includes a payload preview
  under the cursor. If the implementing claim lands a single-DROP
  highlight only, the `drag_preview` line drops out of D7.
- D8's compose key row assumes `#245` uses two-key sequences. A
  three-key variant (e.g. dead-Alt + key + key) would need a second
  row here.
