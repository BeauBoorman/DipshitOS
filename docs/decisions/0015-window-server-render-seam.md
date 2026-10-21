# ADR 0015: Window-server render seam (userland window manager migration)

Status: **ACCEPTED** · Date: 2026-08-28 · Milestone: thirty-two (M32) ·
Accepted by: claim 1484 (WMS1, issue #621)

> **Accepted by M32 WMS1 (claim 1484).** Slot 65 and event kind 18 below are now
> **freeze reservations**: the exact `sys_wmctl` subcommand encoding is frozen
> in the live `docs/decisions/0007-syscall-abi.md` slot-65 amendment, and kind
> 18 `COMPOSITE_TICK` (with its routing restriction) in ADR 0009 D2. Each later
> WMS claim implements one reservation, citing this ADR. Until the relevant
> claim lands its handler, slot 65 is not in `dispatch_table` (a call returns
> `-ENOSYS` -4 naturally) and kind 18 is not delivered.

## Context

The desktop composition + window-management *policy* today lives entirely in the
kernel, in `kernel/src/driving_award.zig` (~4,740 lines): window registry,
z-order, hit-testing, chrome (title bars, borders, focus ring, close/minimize/
pin buttons), geometry (move/resize/tile/snap/workspaces/minimize/maximize/
fullscreen/always-on-top), and the desktop chrome (notification center, dock,
tray, alt-tab, tooltips, modal/transient dialogs, about/preview). Three couplings
are too deep:

1. **Policy in the privileged component.** Every desktop behavior is a kernel
   change — high blast radius, no isolation, no hot-reload, cannot grow without
   a new milestone.
2. **Compositing rides the shell idle loop.** `shell.zig:3425` calls
   `driving_award.drain(...)`. Present pacing, animation, and click handling all
   inherit the shell's idle cadence (the reason pointer gates pace clicks at
   ~2.5 s).
3. **Apps touch the desktop only through syscalls.** No app↔WM↔desktop
   message protocol; the toolkit (`user/src/lib/ui.zig`, `LIBUI.SO`) issues
   per-rect fill syscalls (one `win_fill` per 1×1 glyph pixel).

The downside is not a missing feature — it is a missing *boundary*. This ADR
moves desktop policy out of the kernel and into a userland **window-manager
server process**, leaving the kernel a thin **render + input + surface server**.

## Enabling seams that already exist

- **Per-process event queues** (`events.zig`): input already flows as kinds
  (KEY_*, MOUSE_MOVE/DOWN/UP, WIN_FOCUS/BLUR, WIN_RESIZE, DRAG_*, WIN_UNSAVED)
  to owning processes.
- **Cross-process IPC** slots 5/6 (`sys_ipc_send`/`sys_ipc_recv`, bounded
  per-process mailboxes) — the transport for an app↔WM protocol.
- **Process lifecycle**: `sys_exec` (28), `sys_kill` (29), `sys_wait` (8),
  anonymous mmap (63/64), dynamic linking (M30/M31) — a long-lived EL0 server
  process is a supported shape.
- **Thin GPU interface**: `virtio_gpu` is transfer+flush of a 3.52 MiB BSS
  scanout; all the *weight* is policy stacked on `driving_award`.

## Decisions

### D1. Target architecture — seam A (render-server)

The kernel keeps **surfaces + blit + input fan-out**; a userland **WM server
process** owns all *policy*:

```
+---------------+   IPC (slots 5/6)   +------------------+   sys_wmctl (65)   +----------------------+
|  Apps (EL0)   | <-----------------> |  WM server (EL0) | <----------------> | kernel: render server |
| talk win-msgs  |   win-open/close/   |   registry, z-ish,|   submit window   | surfaces + blit +     |
| to server       |   raise/move/frame  |   chrome, hittest,|   list/chrome,    | input fan-out; hands  |
+---------------+                    |   geometry, nodes |   request-present  | event 18 (composite   |
                                     +------------------+                    | tick) to the WM        |
                                      * policy lives here *                  +----------------------+
```

- The kernel keeps **kernel-owned per-window surfaces and the blitter**, but
  exercises them **only on the WM server's instruction** via a single control
  syscall (D2) — it makes no policy decision of its own.
- The WM server drives present pacing itself (D3) instead of the shell idle.
- Apps keep rendering into their own kernel-owned surface slots for now; the
  toolkit's *policy* queries (open/raise/move/request-frame/config) re-point to
  the WM server over IPC, not to syscall slots.

### D2. Syscall reservation — slot 65 `sys_wmctl`

`0x41 (65)` — first free slot in the 128-wide table (highest used today: 64,
`sys_munmap`).

| Slot | Name | Signature | One-line semantics |
|:---:|:---|:---|:---|
| 65 | `sys_wmctl` | `wmctl(cmd, a0, a1, a2, ptr, len) -> i64` | The **WM server's** exclusive control surface over the kernel render server. Subcommands (a design sketch; each implementing claim freezes its exact encoding): `REGISTER` (this process becomes the active compositor — ownership of composite pacing moves off the shell idle; refused if another is registered), `SET_WINDOW` (submit one window's z-order rank, rect, chrome kind/colors, visibility, workspace — the kernel blits that surface per this geometry), `REQUEST_PRESENT` (ask the kernel to transfer+flush now). Calls from any process other than the registered WM return `EPERM`; no WM registered → `ENOSYS`. |

The moving policy (D1's right-hand side) is **not** part of this syscall — it
is WM-server-internal and exposed to apps only via IPC.

### D3. Event-kind reservation — kind 18 `COMPOSITE_TICK`

Kind 18 is the present/composite cadence the kernel delivers to the **registered
WM server** (arg0 = present sequence, arg1 = reserved). The WM server uses it to
drive its own composite loop, releasing the shell idle dependency. Kind 17
(`WIN_UNSAVED`) remains the highest live kind; 18 reserves the first free value.

### D4. Shim-and-slim migration (extract, don't rewrite)

- **Shim phase (frozen ABI stays the shim):** slots 12–20 (`sys_win_*`) and the
  existing kernel `driving_award` compositor remain fully functional and fully
  gated. Every M18–M31 gate stays green. The userland WM server (new EL0
  process under `user/src/`) grows beside it, reusing `driving_award`'s *pure*
  geometry/logic as userland code so the two never drift behaviorally.
- **Prove parity** through the shim: the WM server commands the kernel render
  server (D2) to reproduce what the kernel WM did — same geometry, chrome,
  z-order, focus rules.
- **Slim the kernel:** once parity is observed behind the shim, the policy code
  drains out of `driving_award.zig`, which shrinks to "surfaces + blit + input
  fan-out + the D2/D3 registers." Slots 12–20 remain frozen (back-compat, and
  used by the shim path until removed); individual claims delete one policy
  block at a time, each behind its gate.
- **Rewire the toolkit** (`ui.zig`/`LIBUI.SO`) on the surface seam (batched
  spans, not per-pixel fills) as the desktop-wide performance side effect.

### D5. Deferred option — seam B (full pixel ownership)

The deeper end-state — apps render into their own mmap'd memory and the WM
composites + presents one final buffer — is **not** chosen for the first pass.
It requires **cross-process shared anonymous mmap** (shared surface between two
EL0 address spaces), a genuinely new MMU fundamental. It is deferred; seam B
can be layered on top of the D1 render-server boundary without re-architecting
it (the render server already separates policy from blit).

## What this is not

- Not POSIX, libc, `errno`, or a compatibility ABI. The WM protocol uses the
  Mailbox IPC (slots 5/6), not signals or sockets.
- Not a kernel rewrite. Seam A keeps the blitter; only *policy* moves.
- Not a uaccess change, scheduler change, or MMU change (in this pass).
- Not a commit. Each M32 claim amends ADR 0007 (slot 65) or the event table
  (kind 18), citing **this** ADR.

## Consequences

- Desktop policy becomes a **hot-replaceable userland component** with its own
  process boundary, own memory, own fault tombstone — the kernel no longer
  faults on find-the-typo-in-my-focus-rule.
- The shell idle loop no longer owns compositing; the WM server does (D3).
- Apps grow a real app↔WM message protocol instead of a syscall-drawn surface.
- Existing behavior is preserved the whole way through the shim (D4) — no
  capability regression at any intermediate commit.

## Amendment log

- 2026-08-28 — claim 1484 (WMS1, issue #621): **accepted as binding**; slot 65
  `sys_wmctl` + kind 18 `COMPOSITE_TICK` reservations frozen in ADR 0007 /
  ADR 0009. The `sys_wmctl` subcommand encoding and error contract are frozen in
  the ADR 0007 slot-65 amendment — `EACCES` (-7) for the WM-exclusive refusal
  (the draft's `EPERM` does not exist in the frozen `ErrorCode` enum; see claim
  1484), seat-taken also `EACCES` (EL1h force-unregister escapes), no-GPU
  `REGISTER` → `ENXIO` (-9), `COMPOSITE_TICK` on the scheduler tick seam; the
   ADR 0007 amendment writes the honest `reserved 66–127` tail (`slot_count` is
   128). The `SET_WINDOW` chrome-descriptor layout remains open (WMS4).
- 2026-09-10 — issue #1056: **additive WMCTL subcommand 14** (seat-gated
  like every other subcommand; no existing opcode or arg layout changes).
  `WINDOW_NAME` (`wmctl(cmd=14, id, buf_ptr, len, 0, 0)`) copies a window's
  display name — the app-set title, else the owning process's executable name
  — OUT through uaccess and returns the byte count, so a WM whose kind-20
  mirror carries no title bytes can still name non-tabapp windows. This backs
  the TABWM window-title polish in issue #1056.
  (The tray clock that #1056 first exposed as WMCTL cmd 15 is superseded by
  the **ADR 0007 slot 66 `sys_time`** in #1058 — a general-purpose epoch read
  is not a WM concern, so the WMCTL clock subcommand was dropped before
  either PR merged.)
- 2026-09-23 — issue #1688: **additive WMCTL subcommand 15** (seat-gated like
  every other subcommand; no existing opcode or arg layout changes — and the
  number is the very one the note above left free).
  `CONTENT_PTR` (`wmctl(cmd=15, x|(y<<16), buttons, mods, 0, 0)`) relays one
  pointer sample from the registered seat into the kernel's LOCAL content
  path — terminal text selection (M49 SD5) and mouse-tracking reports (M73i)
  — the decision block WMS5 made dormant under a seat by returning from
  `pointer_tick` before every selection site. Press/release edges derive from
  the seat-serialized sample stream itself, so the content pass is
  edge-identical to the raw path; chrome the seat consumed (start surface,
  rail, launcher) is never forwarded, so the kernel only ever sees content
  coordinates. Backs the M73z acceptance card #1638: without this forward,
  `dui: term sel end` can never print in a seated boot and the >256 B
  Ctrl+Shift+V paste chain is unreachable there.
- 2026-10-21 — issue #2896: **additive a2 on subcommand 15** — the HID
  modifier byte the kernel stamped on the sample's kind-19 event (`arg1`)
  at decode time, echoed back untouched. The report-vs-selection judgment
  (`mouseOwnsAt`) and the delivered event flags now use the modifiers held
  AT CAPTURE; a drain-time `kb_mods` read misattributed a concurrent chord
  burst's Shift to an older queued press (go-dogfood boot 08's stolen drag).
- 2026-10-21 — issue #3007: **additive WMCTL subcommand 23** (seat-gated
  like every other subcommand; no existing opcode or arg layout changes).
  `CONTENT_KEY` (`wmctl(cmd=23, usage, flags, 0, 0, 0)`) relays one
  agent-injected key press (WM_RPC kind 29 `agent_input` 'k', ADR 0007
  R2) into the kernel's focused-owner delivery — the half
  `decode_keyboard_report` performs for a real report that the
  seat-side mirror never could: kind-21 `WM_KEY` is a fan-out, never the
  path a kind-1 `KEY_DOWN` takes to an app. The kernel resolves the
  focused window exactly as decode does — a kernel-terminal front-end
  gets the encoded bytes, any other owner gets the KEY_DOWN/KEY_UP pair
  with the codepoint in `arg1` and the press's ADR 0009 modifier word in
  `flags`. A press is one down+up pair; no held-set or compose state is
  touched. Backs the go-agentd run-15 fix: kind-29 keys applied at the
  seat but never reached the app, so `goedit: dirty` could not fire.

## Open issues (left to implementing claims)

- ~~Exact `sys_wmctl` subcommand encoding (opcode constants, arg layout, return
  codes)~~ — **resolved by WMS1 (claim 1484)**: freezed in the ADR 0007
  slot-65 amendment (REGISTER=1 / SET_WINDOW=2 / REQUEST_PRESENT=3 + error
  contract). The `SET_WINDOW` **chrome descriptor** layout stays open (WMS4).
- Kernel BSS for the WM registry (the D2 register + composite-tick sequence);
  the scanout fb (3.52 MiB) is untouched.
- Whether mailboxes (8 × 64 B today) suffice for the app↔WM protocol or a larger
  bounded message type is needed — the WM-server claim decides; prefer growing
  the mailbox data-path constant over a new syscall.
  **Resolved by WMS7 Gate A (claim 9604, issue #627):** the WM_RPC wire format
  fits the FROZEN 64-byte slot — the size decision is "grow nothing". `WmRpc`
  (single-sourced in `kernel/src/wnd_core.zig`, compiled by both WND.BIN and
  WMRPC.BIN) packs kind / target id / seq / reply pid / applied flag / u16 rect /
  a ≤24-byte bounded title into 64 B, so `message_max` (8 × 64 B, the
  `verify-live-ipc.sh` exact-capacity contract) and BSS are untouched. Requests
  ride `sys_ipc_send`/`sys_ipc_recv` (slots 5/6) to the registered WM's own
  inbox; the WM serves them in its 1 Hz kind-18 wake (≤ 1 s latency, accepted),
  applies through its OWN clamped primitives (WIN_RAISE → the ALT_TAB-commit
  path, WIN_CONFIG → the SET_WINDOW rect path), replies an ack (kind | 0x80) to
  the requesting app's pid, and emits `wnd: mail` (the gate grep target). Apps
  poll their own inbox for the ack; with no WM the app prints `wmrpc: no-wm`
  and parks (additive back-compat — frozen syscalls untouched).
- **Toolkit re-point (WMS7 Gate B, claim 9994):** `user/src/lib/ui.zig` — the
  toolkit compiled into every static app — carries the WM_RPC client. It holds a
  FROZEN wire mirror of `WmRpc` (byte-identical layout; `lib/ui.zig`'s module
  path cannot import `kernel/src/`, so the 28 app modules get the mirror and
  the live gate's byte-level round-trip is the integration drift guard, plus a
  host test in `wmrpc.zig` locks `ui.wm_rpc_*`/`ui.WmRpc` byte-size to
  `wnd_core`'s). `wm_raise_front(id, self_name)` / `wm_config(id, x,y,w,h,
  self_name)` are the re-pointed policy calls: send WIN_RAISE / WIN_CONFIG mail
  to the WM and await the ack (synchronous-shaped — the issue's async-inversion
  note answered: no async break), falling back to the FROZEN `sys_win_raise_front`
  (slot 49) / `sys_win_move` (slot 16) when no WM is registered (additive).
  The shipped `LIBUI.SO` note: it is a bare-syscall thunk library generated by
  `tools/mkdyn-elf.py`, so async mail (send + poll + fallback) cannot be
  exposed  there without duplicating the client in emitted asm — the client
  lives in `lib/ui.zig` and grows the toolkit, but dynamic-app (ELF) mail is
  out of scope; `libui_so.zig`/`ld.zig` untouched.
- **WMS8 Gate 2 (claim 9980, issue #628) — the about dialog DRAINS (a DRAIN,
  not a deletion).** WMS6 left the modal/transient dialogs on the WMS8 delete-
  runbook backlog, and the about dialog is still the shim's ONLY implementation
  (live in default no-WM boots, which WMS8's "shim compositor core stays until
  the very last deletion" forbids deleting). So Gate 2 gives the WM ownership
  via new slot-65 cmd 11 `DIALOG`: a0 = 0 close / 1 open / 2 toggle, applied
  through the SAME clamped `about_dialog_open_dialog`/`about_dialog_close`/
  `about_dialog_toggle` primitives the shim's Ctrl+Shift+A chord runs — parity
  by construction. The WM decides WHEN (it owns the kind-21 keyboard stream it
  already got from WMS5 Gate 2); the kernel still blits the modal from its own
  `about_dialog_open` state and its own about self-toggle gates behind
  `!wm_owns_input` (input.zig), so a registered WM cannot be fought. `dialog=`
  joins the `wm` observability row; `key_fan` proves the kind-21 fan-out.
  **Gate 3 (claim 7736) DELETED the kernel about-decision**: with Gate 2's
  parity green, WMS8's delete rule is satisfied, so `about_pending` +
  `take_about()` in input.zig, the shell idle self-toggle block, and the now-
  provably-dead `about_dialog_hit_test` + pointer close-button path were
  removed (~58 lines). The applied primitives + `about_dialog_open` + the
  modal blit stay (cmd 11 still drives them). Ctrl+Shift+A is now WM-only
  (the issue's shim "no compositing policy" end-state). Still ahead: the
  unsaved dialog, which needs the kind-20 mirror to carry an `unsaved` bit.
  **Gate 4 (claim 6155) DRAINED + DELETED the unsaved-changes dialog.** The
  kind-20 WM_WINDOW mirror gains an UNSAVED bit (flags bit 12) fanned by
  `user_set_unsaved`, so the registered WM learns each window's dirty state
  as it changes (the decision input Gate 3's close-out promised). DIALOG
  (cmd 11) gains actions 3 show / 4 save / 5 don't-save / 6 cancel, applied
  through the kernel's OWN `unsaved_dialog_show`/`save`/`dont_save`/`cancel`
  primitives — parity by construction (the shim's button clicks ran the same
  code). WND.BIN owns the decision: a close-button DOWN EDGE on a DIRTY
  mirror issues DIALOG 3 (`wnd: unsaved-dialog`); a dialog-button click
  issues DIALOG 4/5/6 (`wnd: unsaved-save/discard/cancel`) via the SHARED
  `wnd_core.unsaved_dialog_choice_at` rule — the same centered 200×100 rects
  the kernel's `unsaved_dialog_click` applies (parity by construction, both
  sides single-sourced). DELETED per WMS8's delete rule (the drain parity is
  green with the WM registered): the pointer_tick dialog intercept, the
  close-button dirty-check, and the 5-tick auto-close timeout (the WM now
  decides duration). Shim end-state degradation (intended): closing a dirty
  window in shim mode closes it immediately — no dialog, the issue's "no
  compositing policy" end-state. **Review fixes (claim 7639, post-merge):**
  the WM now CONSUMES the close-click DOWN EDGE (no fall-through into the
  WMS5 title-bar grab — the shim's `handled_btn` discipline), scans mirrors
  TOP-DOWN for the close button (the shim walks win_count..0), and cmd-11
  DIALOG actions 4/5/6 return EINVAL when no dialog is open (the stale
  BSS-zero target stays unreachable — the shim's click path returned
  `.none` first); the shared Cancel rect matches the painted 30px button
  (x+160..190). **Gate 5 (claim 9879) DELETED the geometry-policy
  KEYBOARD-DECISION layer.** WMS5 Gate 2 had already moved these chords to
  the WM (kind-21 -> handle_wm_key -> SET_WINDOW/SET_STATE); with the W5
  matrix re-running green while a WM is seated, WMS8's delete rule is
  satisfied, so the kernel's own chord consumers (pending flags, decode
  branches, `take_*` accessors in input.zig + the shell idle consumer
  blocks) are removed for tile/master/minimize/maximize/workspace switch+
  cycle/fullscreen/always-on-top. The applied primitives are KEPT and stay
  monitor/dui + SET_STATE driven (the matrix re-runs green THROUGH them);
  lower-back (Ctrl+Shift+B) + move (Alt+arrows) keyboard consumers are kept
  (no WM coverage yet — deleting would regress shim mode); Alt+Tab stays
  (separate WMS6 focus surface). Shim consequence (intended): a drained
  geometry chord now does nothing in shim (no-WM) mode — the "no compositing
  policy" end-state. **Gate 6 (claim 3687) DELETED the pointer title-bar
  DRAG+SNAP decision layer.** WMS5's input seam proved the WM owns pointer
  geometry (kind-19 fan-out, kernel consumes none); with the W5 geometry
  gate re-ran green, WMS8's delete rule is satisfied, so the kernel's drag
  path is removed from `driving_award.zig` (net −215 lines): `drag_id`/
  `drag_offset_*` state, title-bar drag-initiation, drag-move +
  snap-on-release, `snap_zone`/`snap_last_*`/`snap_snapped` tracking, the
  applied `snap_window`/`snap_restore`/`snap_is_snapped`/
  `snap_current_zone` primitives, the snap-preview render, and the cursor
  move-glyph. KEPT: resize (no WM coverage — deleting would regress shim
  mode), close/minimize buttons, modal blocking, dock/tray/notif-center
  clicks, app pointer-event DELIVERY, and app-level DnD. Shim consequence
  (intended): with no WM a title-bar drag does nothing. Gate
  `verify-live-wnd8-ptr-drag-delete` **PASS on VZ** both boots; the wnd5
  geometry parity gate re-ran **PASS**.
- Which `driving_award` policy block drains out of the kernel first (recommended:
  chrome, being minimal and highly observable).