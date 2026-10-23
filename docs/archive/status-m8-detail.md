# Milestone 8 — Eight — usability: human interface (ADR 0008) — archived detail

> **Archived from `docs/status.md` on 2026-08-21 (issue #262).**
> The canonical one-line summary now lives in `docs/status.md` Current position table.
> This file preserves the full narrative that was previously inline in `docs/status.md`
> so the live tracker can stay ~150–200 lines. See also [`docs/march-m8.md`](march-m8.md) and the claim files cited below.

## One-line summary (now in `docs/status.md`)

| Eight — usability: human interface (ADR 0008) | Command grammar, line editor, error contract, window HIG, first-boot, sysinfo, settings | ✅ done 2026-08-15 (claim 2649, cards U0–U8) |

- **Close date:** 2026-08-15
- **Claim:** 2649
- **March tracker:** [`docs/march-m8.md`](march-m8.md)

## Full narrative as it appeared in `docs/status.md` (pre-compression)

The following is the verbatim Current position table row for M8, previously at `docs/status.md:43`.

```text
| Eight — usability: human interface (ADR 0008) | One command grammar + grouped `help` (D1), a real line editor (history, cursor, Ctrl chords, tab completion — D2), one `error:`/`usage:`/`unknown command` shape (D3), a visible-focus window model (D4), an `about`/`welcome`/`motd`/`sysinfo` support surface (D5), all enforced by gates (D6). Normative contract: [`docs/decisions/0008-human-interface-guidelines.md`](../decisions/0008-human-interface-guidelines.md) | ✅ **done 2026-08-15 (cards U0–U8 landed, PRs #135–#139)** — U0 ADR 0008 (claim 8938) ✅ 2026-08-14; U1 grouped `help`/catalog (claim 3275) ✅ 2026-08-14; U2 shell editing/history (claim 1809, + the latent XHCI interrupt-ring wrap fix) ✅ 2026-08-14; U3 the one `error:`/`usage:`/`unknown command` contract (claim 1511, + the u4 history-width fix the fuzz found) ✅ 2026-08-14; U5 window HIG — focus ring + title bars (claim 0935; gate `tools/verify-live-win-hig.sh` PASS 8/8 on VZ) ✅ 2026-08-14; U6 first-boot experience — refreshed `about`, `welcome`/`tour`, boot `motd` (claim 8323) ✅ 2026-08-15; U7 `sysinfo` support snapshot (claim 2990) ✅ 2026-08-15; U8 persistent `settings` — `hostname`/`prompt`/`theme`/`scrollback` backed by `SETTINGS.TXT` on the DATA partition, live reboot persistence (claim 2649; gate `tools/verify-live-settings.sh` PASS on VZ) ✅ 2026-08-15. U4 pointer focus + cursor (claim 4993) is the ONE card without a full live proof — the guest side is DONE and host-tested (click = focus + raise via `pointer_tick`, the magenta cursor, Alt+Tab decode) but five synthesized pointer delivery routes each produced zero guest pointer reports; the follow-on gates close that: **(claim 9015) the real-mouse path is a class-C gate** `bash tools/verify-pointer-manual.sh` (a human at the mouse; gate landed ✅ 2026-08-15 and smoke-proven — the PASS run is a human action by construction), and **(claim 3692) the CG route is a self-gating class-B gate** `bash tools/verify-live-pointer-cg.sh` (runner trust detection + honest `PTR-TRUST: untrusted` reporting + the one-time Accessibility grant path; gate landed ✅ 2026-08-15 — the trusted PASS awaits the TCC grant). Per-card tracker: [`docs/march-m8.md`](march-m8.md). **Handoff (2026-08-16, claim 4769, PR #174):** a route-by-route probe pinned the root cause — VZ only translates input for its KEY window, and macOS 14+ refuses programmatic activation for a background CLI process (even `.regular` policy / `finishLaunching` / a signed `.app` bundle), so NO synthesized route delivers while the machine is busy. Retesting with the machine IDLE refuted the idle hypothesis (runner stayed frontmost, `front=VMRunner` every post, cursor warped — still `key=false`, `ptr-reports=0`). Notably the KEYBOARD seam also now yields `events=0` in the guest ring (worked at 17:59 the same day; console session re-established 19:33) — an open thread for the next session. Class-C real-mouse gate (claim 9015) remains the working route. |
```

### Readable paragraph form

**Milestone:** Eight — usability: human interface (ADR 0008)

**What it proved / is:** One command grammar + grouped `help` (D1), a real line editor (history, cursor, Ctrl chords, tab completion — D2), one `error:`/`usage:`/`unknown command` shape (D3), a visible-focus window model (D4), an `about`/`welcome`/`motd`/`sysinfo` support surface (D5), all enforced by gates (D6). Normative contract: [`docs/decisions/0008-human-interface-guidelines.md`](../decisions/0008-human-interface-guidelines.md)

**Status:** ✅ **done 2026-08-15 (cards U0–U8 landed, PRs #135–#139)** — U0 ADR 0008 (claim 8938) ✅ 2026-08-14; U1 grouped `help`/catalog (claim 3275) ✅ 2026-08-14; U2 shell editing/history (claim 1809, + the latent XHCI interrupt-ring wrap fix) ✅ 2026-08-14; U3 the one `error:`/`usage:`/`unknown command` contract (claim 1511, + the u4 history-width fix the fuzz found) ✅ 2026-08-14; U5 window HIG — focus ring + title bars (claim 0935; gate `tools/verify-live-win-hig.sh` PASS 8/8 on VZ) ✅ 2026-08-14; U6 first-boot experience — refreshed `about`, `welcome`/`tour`, boot `motd` (claim 8323) ✅ 2026-08-15; U7 `sysinfo` support snapshot (claim 2990) ✅ 2026-08-15; U8 persistent `settings` — `hostname`/`prompt`/`theme`/`scrollback` backed by `SETTINGS.TXT` on the DATA partition, live reboot persistence (claim 2649; gate `tools/verify-live-settings.sh` PASS on VZ) ✅ 2026-08-15. U4 pointer focus + cursor (claim 4993) is the ONE card without a full live proof — the guest side is DONE and host-tested (click = focus + raise via `pointer_tick`, the magenta cursor, Alt+Tab decode) but five synthesized pointer delivery routes each produced zero guest pointer reports; the follow-on gates close that: **(claim 9015) the real-mouse path is a class-C gate** `bash tools/verify-pointer-manual.sh` (a human at the mouse; gate landed ✅ 2026-08-15 and smoke-proven — the PASS run is a human action by construction), and **(claim 3692) the CG route is a self-gating class-B gate** `bash tools/verify-live-pointer-cg.sh` (runner trust detection + honest `PTR-TRUST: untrusted` reporting + the one-time Accessibility grant path; gate landed ✅ 2026-08-15 — the trusted PASS awaits the TCC grant). Per-card tracker: [`docs/march-m8.md`](march-m8.md). **Handoff (2026-08-16, claim 4769, PR #174):** a route-by-route probe pinned the root cause — VZ only translates input for its KEY window, and macOS 14+ refuses programmatic activation for a background CLI process (even `.regular` policy / `finishLaunching` / a signed `.app` bundle), so NO synthesized route delivers while the machine is busy. Retesting with the machine IDLE refuted the idle hypothesis (runner stayed frontmost, `front=VMRunner` every post, cursor warped — still `key=false`, `ptr-reports=0`). Notably the KEYBOARD seam also now yields `events=0` in the guest ring (worked at 17:59 the same day; console session re-established 19:33) — an open thread for the next session. Class-C real-mouse gate (claim 9015) remains the working route.

### Archived `## What comes immediately afterward` entries for M8

The `## What comes immediately afterward` section in pre-compression `docs/status.md` (lines 357–580)
contained 1 numbered entries that detailed M8's cards.
The entries have been removed from the live tracker; their substance lives in the march file and claims.
For historical fidelity, the original bullets that referenced M8 are excerpted below (see git history `docs/status.md` @ `aa4f111` for full section):

> **Bullet 18:**
> 18. **Milestone eight, card U0 — human interface guidelines (ADR 0008).**
>     ✅ **DONE 2026-08-14 (claim 8938).** The normative interface contract
>     (`docs/decisions/0008-human-interface-guidelines.md`: D1 command grammar
>     + grouped `help`, D2 prompt/editing, D3 error/usage shapes, D4 window
>     interface, D5 support surface, D6 gate-enforceability) plus the
>     milestone-eight per-card tracker + agent split
>     ([`docs/march-m8.md`](march-m8.md): U0–U8 — help/catalog, editing/history,
>     error contract, pointer focus, window HIG, first-boot, sysinfo, persistent
>     settings). Docs only; explicitly NOT an ADR 0007 change and NOT a
>     POSIX/readline promise.
>     **Card U1 (claim 3275) DONE 2026-08-14** — the ADR 0008 D1 discovery
>     surface: `kernel/src/monitor.zig` gains a `Category` field on all 40
>     commands + a grouped `help` catalog in the D1 group order + `help <cmd>`
>     detail + `help <topic>` pages (networking, windows, storage, graphics;
>     command-named `syscalls`/`input` resolve to their command detail). The
>     byte-identical transcript (shell.zig e2e + `tests/transcript-console.txt`)
>     regenerated to the grouped listing, and the new live gate
>     `tools/verify-live-help.sh` PASS 1/1 on VZ (scripted help walk).
>     **Card U2 (claim 1809) DONE 2026-08-14** — the ADR 0008 D2 editing
>     surface: a bounded history ring, cursor left/right + Home/End, Ctrl-
>     A/E/K/U/L/C, Delete, and tab completion in `kernel/src/lineedit.zig`;
>     arrow/Home/End/Delete usages + Ctrl-chord decoding in `kernel/src/input.zig`;
>     `\b`/`\r` honored in `kernel/src/text.zig`; the registry completer + repaint
>     wired in `kernel/src/shell.zig`; and the runner's `--input-chords` seam.
>     Live gate `tools/verify-live-editing.sh` PASS 1/1 on VZ (scripted chords
>     drive mid-line insert + Up recall; unchanged transcript paths stay
>     byte-identical). En route it root-caused + fixed a latent I3 interrupt-
>     ring wrap OOB in `kernel/src/xhci.zig` (a phantom stale-report read after
>     the Link-TRB boundary).
>     **Card U3 (claim 1511) DONE 2026-08-14** — the ADR 0008 D3 error/usage
>     contract, mechanically enforced: one `usage: <cmd> <args>` (registry
>     single usage string via `print_usage`, reused for sub-verb misuse), one
>     `error: <actionable>` (`err_prefix`) across every refusal/failure site,
>     one `unknown command '<x>' -- try 'help'`. The byte-exact misuse
>     transcript now asserts all three shapes, and three deterministic host
>     fuzz tests (tokenizer / arbitrary argv / full editor+shell input path)
>     prove no handler panics. The full-path fuzz found + this card fixed a
>     latent U2 width bug: `remember_line`'s `@min(hist_count, hist_capacity
>     - 1)` inferred **u4** and overflowed at the 16th distinct history entry
>     (explicit `usize` anchor + a fill-past-capacity regression test). Live
>     help + live transcript gates re-run green.
>     **Card U5 (claim 0935) DONE 2026-08-14** — the ADR 0008 D4 chrome: a
>     white 3-px focus ring on the focused window (focus changes repaint),
>     title bars (name + owning pid) on user windows, `win cycle` + the
>     host-tested Alt+Tab decode for keyboard cycling; the new gate
>     `tools/verify-live-win-hig.sh` PASS 8/8 on VZ (scale-aware pixel
>     proof: ring on the focused window, terminal edge not ringed, the
>     title bar). **Card U4 (claim 4993) BLOCKED at the live seam** — the
>     guest side (click = focus + raise, the cursor, the axis mapping) is
>     host-tested and the runner `--pointer` seam landed, but five
>     synthesized pointer delivery routes all produced zero guest pointer
>     reports (hardware contract); the real-mouse observation and the
>     Accessibility-granted CG route are the recorded follow-ups. A latent
>     out-of-bounds write in `text.zig`'s render (the tiny-canvas host
>     test) was found and fixed (render is now canvas-bounded).
>     **Card U6 (claim 8323) DONE 2026-08-15** — the ADR 0008 D5 first-boot
>     experience: refreshed `about` with modern architecture realities (GICv3,
>     processes, FAT32, networking, windows, xHCI input), new `welcome` (alias
>     `tour`) guided walkthrough of the system, and a deterministic boot MOTD
>     status line (`motd: aarch64 el1 kernel live; scheduler, uaccess, fs, net, gfx, xhci armed.`);
>     class A transcript gate `tools/verify-transcript.sh` and live help gate
>     re-run green. The post-M8 candidate roadmap
>     (Milestone 9: Interactive EL0 Events, Milestone 10: Userland Filesystem ABI,
>     Milestone 11: Desktop Platform & GUI Apps, Milestone 12: Network Apps) is
>     structured in `docs/roadmap.md` (claim 4951).
>     **Card U7 (claim 2990) DONE 2026-08-15** — the ADR 0008 D5 `sysinfo` support
>     snapshot: canonical `sysinfo` command in `kernel/src/monitor.zig` (growing
>     registry 42 -> 43) unifying system, cpu/timer, memory, allocator,
>     scheduler, processes, storage, networking, graphics, and input diagnostics;
>     transcript fixture regenerated; class A gate `tools/verify-transcript.sh`,
>     unit tests, and live help gate re-run green.
>     **Card U8 (claim 2649) DONE 2026-08-15** — the ADR 0008 Card U8 persistent
>     settings engine: `kernel/src/settings.zig` provides in-memory key-value
>     configuration (`hostname`, `prompt`, `theme`, `scrollback`) backed by
>     `SETTINGS.TXT` on the DATA FAT32 partition; `cmd_settings` in `kernel/src/monitor.zig`
>     (growing registry 43 -> 44) implements `list`, `get`, `set`, `reset` verbs;
>     kernel boot initializes settings from the DATA partition, and `kernel/src/shell.zig`
>     dynamically renders the configured prompt. New class-B gate `tools/verify-live-settings.sh`
>     PASS 1/1 on VZ (two boots against same disk image: sets `hostname=elephant-box` and
>     custom prompt, fresh reboot confirms custom prompt and persisted hostname loaded).
>     **Milestone Eight usability cards U0–U8 are complete.**
> 
> The command layer above is portable; `docs/archive/march-m15.md` step 15's filesystem-command **deferral is superseded 2026-08-09** — first by the pre-exit ESP file window (claim 3475) and then, **on the same day, by the real FAT32 storage driver (claim 6420)**: `ls`/`cat`/`write` now read and write the live ESP's FAT volume through a virtio-blk transport, so files persist on the disk itself and **no storage driver remains deferred**. The allocator, interrupts, first tasks, EL0 boundary, syscall ABI, uaccess, per-task address spaces, lifecycle, ESP exec, and blocking syscalls are all complete; **milestone three is closed 2026-08-10 (tag `m3-userspace`, claim 0707)**.
> 

### Gates and claims

Primary claim: **2649** (see `docs/claims/2649-*.md` if present).
Full gate inventory: [`docs/gate-inventory.md`](../gate-inventory.md)
Hardware contract: [`docs/hardware-contract.md`](../hardware-contract.md)

---
_Generated by compression of `docs/status.md` (issue #262, 2026-08-21). Do not edit the one-line summary in `docs/status.md` without updating this archive if the narrative is still relevant._