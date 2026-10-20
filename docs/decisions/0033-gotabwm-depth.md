# ADR 0033: GOTABWM is the tabbed desktop

- Status: ACCEPTED
- Date: 2026-09-17
- Issue: #1399 (this document) · milestone #1398 (M62) · cards M62a–M62h
  (#1399–#1406)
- Related: ADR 0007 (syscall ABI — unchanged), ADR 0015 (userland WM seat /
  slot 65), ADR 0030 (Go is EL0; boot default already `gotabwm`), ADR 0031
  (guest self-test; LAYOUT.txt lives next to REPORT.txt), M48 (Zig TABWM
  tab depth — flag parity only), M54 (`tools/go/tabcodec` `.tabs` v2)

> **Deepen the Go seat that already boots. Do not invent a second
> compositor.** This ADR is docs-only and carries the M62 card split
> (M62b–M62h). It adds no syscall, no Zig app, no kernel change; the boot
> default does not move.

## Context

M59 made `GOTABWM.ELF` the compiled boot default. What landed in M57 is
still a **thin seat**: register slot 65, mmap the scanout, open one Go
window, host leftover Zig CALC/NOTEPAD full-viewport over WM_RPC, present
on `COMPOSITE_TICK`. Zig `TABWM.BIN` still owns the product desktop —
tab strip, splits, pin/reorder, `.tabs` v2 session.

A 20-milestone "GOWM" rewrite (shm canvas proto, Go flush to virtio-gpu,
new caps, `/dev/tty` emulator births) would fight that. The kernel already
is the render server (ADR 0015). Seam B already gave apps buffers and one
present. `tabcodec` already round-trips `.tabs` v2. `GOEDIT` / `GOTERM` /
`GOFILES` / `GOCALC` already exist.

The gap is GOTABWM itself: it does not yet *be* the tabbed desktop it
autostarts.

## Decision

**D1. Deepen `GOTABWM.ELF`. No second compositor.** No `GOWM`, no shm IPC
canvas, no Go virtio-gpu flush, no new virtio, no kernel, no ADR 0007
slot. Apps still speak WM_RPC; the kernel still composites on the seat's
instruction.

**D2. Boot default stays `gotabwm`.** Zig `TABWM.BIN` remains the
`settings set wm tabwm` fallback. This milestone does not delete Zig
TABWM. `go-wm-seat` stays the M57 seat+interop proof (seed `wm=none`,
explicit `exec GOTABWM.ELF`). `go-wm-default` stays the boot-flip proof.

**D3. Session format is `.tabs` v2.** Independent Go codec:
`tools/go/tabcodec` (host) / in-guest import of the same layout. Header +
69-byte records, max 16 tabs, flags `pinned|frozen|dock`. Corrupt files
fail closed; the seat starts empty. Path on the share:
`/host/SESSION.TABS` (spec may also seed under `SELFTEST/`). Do not invent
JSON/YAML layout files.

**D4. Structural proof is `LAYOUT.txt`, not a PNG.** GOTABWM writes
`/host/SELFTEST/LAYOUT.txt` (UTF-8, LF, no timestamps/pointers) and closes
it before any serial line that names it. One line per surface:

```
tab=<id> bin=<name> x=<X> y=<Y> w=<W> h=<H> focus=<0|1> split=<none|h|v>
```

The host `cat`s it. Framebuffer goldens stay host-side (`vgate_assert
snapshot`) for r3d and friends. HID playback is out of this milestone.
GOSELF does not become the WM; it may read a dump the WM already wrote.

**D5. One new spec for the tabbed product path: `go-wm-tabs.spec`.**
Extend that spec across M62b–g. Do not overload `go-wm-seat`. Do not add
a `live-foo.spec` for a tab case.

**D6. Leftover Zig CALC dies last, as its own card (M62h),** and only
after the Go seat hosts `GOCALC.ELF` in `go-wm-seat` / `go-wm-default`.
TLS/SSH stay Zig helpers (ADR 0030). No caps rewrite (M50). No CI VZ
runner.

## Card split (M62, umbrella #1398)

| Card | Deliverable | Depends |
|---|---|---|
| **M62a #1399** | This ADR + testing.md (docs-only) | — |
| **M62b #1400** | Tab strip: two clients, open / close / focus | M62a |
| **M62c #1401** | Constrained split (two panes, integer px) | M62b |
| **M62d #1402** | Pin + reorder (M48 flag parity) | M62b |
| **M62e #1403** | Session save/restore via `.tabs` v2 on `/host/` | M62b, M62d |
| **M62f #1404** | Headless `LAYOUT.txt` dump | M62b |
| **M62g #1405** | Two real Go apps as tabs (GOEDIT+GOTERM) | M62b |
| **M62h #1406** | Delete `CALC.BIN`; retarget seat specs to `GOCALC.ELF` | M62g or `go-calc`+seat retarget |

M62b–g serialize on `user/go/gotabwm/`. One editor, one claim.

Pane minimum (M62c): **160×120** CSS-pixels on the 1280×720 scanout,
integer math, kernel clamp remains authoritative. Unsplit restores
full-viewport.

## Non-goals

No new `GOWM`. No shm proto. No Go GPU flush. No `/dev/tty` rewrite. No
`net/http` TLS wrapper. No GOPNG/GOTOP births. No WMP. No #1340. No
deleting `TABWM.BIN` / `NOTEPAD.BIN` / `SH.BIN` / `FETCHS.BIN` /
`SSH.BIN`. No touching `user/go/ttf/**` (#1369) or kernel uaccess. No
page-table teardown card.

## Amendment (M125a, #2586): the per-app `app_state` protocol

**D7. Blob transport is a staged share file, not the wire.** WM_RPC frames
are 38 bytes inside a 64-byte mailbox slot and a blob is up to 64 KiB, so
new request kinds `save_state` (20) and `restore_state` (21) carry only
the rendezvous. The envelope — `u8 appver | u32 len LE | blob` — is
published crash-safe at `/host/APPSTATE.<id>` by whichever side sends the
blob and deleted by the receiver. Consume-on-use is deliberate: a staging
file is a handoff, never storage, so a stale blob can never be delivered
twice or inherited by a window id reuse. The kernel's shared-region seam
was considered first and rejected: only the registered WM may peer-map,
and peers are read-only — it can carry app→seat but never seat→app.

**D8. Apps own the format; the seat owns the lifecycle.** `appver` is the
application's own serialization tag, stored and returned verbatim so a
stale serialization is refused by the app's check, not the seat's. The
seat asks (async kind-20 notice, session-token-authenticated like a
settings notice) at exactly the lifecycle points the card pins — snapshot
and tab close — and drains answers inside a bounded collect of `serviceRPC`
+ `Yield` rounds. A silent app costs the budget once and keeps whatever
it last stored; the seat never wedges.

**D9. `.tabs` v2 gains an `AS` trailer section**, not a new record field:
after the count fixed records, `u8 'A' u8 'S' | u8 ver(1) | u8 count |
u16 reserved`, then per entry `u8 index | u8 appver | u16 reserved |
u32 len | blob`. `index` binds the blob to the file's own record, so
nothing outside the file can misattach state to the wrong tab. A blob
over `AppStateMax` (64 KiB), an orphan index, or a truncated entry is
dropped BY NAME on the `state drop` marker — the record keeps its row and
its siblings still parse. The whole file stays under 96 KiB: below the
share reader's 256 KiB ceiling and the snapshot bundle's 128 KiB entry
cap, so a session with blobs still loads whole and still bundles.

**D10. Close re-delivers.** A closed tab's blob rides the reopen LIFO
(`ClosedTab`); ctrl-shift-t stages it on the exec'd pid — pid-matched
like M120b's `reexecWait` — and the declaring app adopts it onto its new
row before its `restore_state` request hands it back.

## Amendment (card #2771): the split is a tree

**D11. A tab's viewport divides recursively.** The M62c two-pane model —
one `SplitKind` plus one sash — is the depth-1 case of a fixed-pool
binary tree (`tree.go`): internal nodes split their rect `v`/`h` at a
sash position, leaves host one strip tab each, and `SplitRectsSash` is
one node's math. Depth 3 (three nested splits) and 8 panes are the
bounds; both are enforced at mutation so no reachable shape is
untileable. Pane minimum 160×120 holds inside every node rect, not just
the scanout.

**D12. Panes follow tabs, not slots.** A leaf names its hosted tab by
window id and `relinkLeaves` re-binds leaf order to strip position after
a reorder or pin — the pane the app lives in travels with it, exactly the
M79c reorder contract generalized. A close splices the leaf out (the
sibling subtree rises into the dead node's slot); a re-exec adoption
remaps the placeholder id to the live window id.

**D13. `ctrl+alt+arrows` move focus between panes by rect geometry**
(the ADR 0007 R4 rows #2752 reserved): candidates are leaves whose
centre is strictly in the asked direction, ranked by perpendicular-axis
overlap then distance, and the winner rides the same `focusByIndex` path
a rail click takes. `ctrl+shift+v` keeps its cycle on the FOCUSED pane:
none → v → h → none, where the "state" is the focused leaf's parent
kind; the depth-1 two-tab case reproduces M79c byte-for-byte.

**D14. The tree persists in a sidecar, never in `.tabs` v2.** The record
format is frozen (tabcodec parity is a gate), so `/host/SESSION.PANES`
carries the tree: `PN` + ver byte, then preorder tags — `v`/`h` + u32 LE
sash for an internal node, `0` + u8 record index for a leaf. Leaf indexes
name SESSION.TABS record positions, the only key the two files share.
Corrupt or truncated blobs refuse whole (`panes bad`); unsplit deletes
the file. The snapshot bundle carries it as a third entry
(`snapshot.EntryPanes`), so a restore on a fresh share rehydrates the
layout — the same seam the settings and session entries already ride.

**D15. WM_RPC kind 29 `agent_input` is AGENTD-only.** R2's reserved
frame carries ONE HID event in the title field (`k`+mods+usage for a
key, `p`+buttons+x+y for a pointer; x/y/w/h hold the auth union and are
not payload). Admission is gateRPC's bound binding (the ownership grant)
plus a proc-table name check for `AGENTD.ELF`; a wrong or malformed
sender is `agent_input_denied`, a strip with no live focused pane is
`agent_input_no_focus`, and both names ride the refused ack's title so
the client reads which refusal landed. The admitted event is
synthesized into `consumeSeatEvent` — the seat's own input path — so
seat chords, chrome hit-tests, and the kernel content-pointer forward
behave exactly as for hardware input. No new syscall: R1's rule that
the wave rides existing seams holds.

## Amendment (card #2773): spaces are seat-side named groups

**D16. A space is a `TabStrip` plus its pane tree, owned by the seat —
never a kernel workspace.** `workspace_max` is 3 and the card wants up
to 4 groups, so the grouping lives in `spaces.go`: `MaxSpaces` named
slots (`"1".."4"` by default), `tabs` IS the live space's strip, and a
switch parks the outgoing strip into its slot, adopts the dormant one,
and swaps per-window visibility through the seat-only
`wmctl_set_state` visibility bits (`vi.WmctlSetVisible` — bits 8-15
pinned at `0xff` so a hide/show never reads as a kernel-workspace
move). `ctrl+alt+PgUp` clamps at the first space; `ctrl+alt+PgDn` at
the last space CREATES the next slot — the keyboard's only
space-create path. Dormant windows keep running (input simply cannot
reach them while hidden); a dormant window's detach or death still
closes its row via `closeTabAcrossSpaces` so the session never
re-execs what the user killed.

**D17. The record's reserved `group` field carries the space name.**
`.tabs` v2 stays frozen byte-for-byte — the 12-byte group field it
always reserved now holds the space name, `""` naming the default
space "1". The whole space table encodes as one record list in slot
order with `active` naming the live space's focused record; a group
list longer than `MaxSpaces` fails the file closed. `SESSION.PANES`
grows a v2 frame (`PN` 0x02 + nspaces + current + per-space
`name + v1 blob`) so every space's tree — and an EMPTY space's bare
existence — round-trips the snapshot bundle's `EntryPanes` restore.
A v1 sidecar still reads: its single tree lands on the live space.

**D18. The rail names the live space; the palette moves tabs between
them.** `paintRail` draws the current space's name at the rail's right
edge once more than one space exists (a single-space desktop draws
nothing — the name distinguishes spaces, it is not chrome for its own
sake), and the `rail n=` marker line carries `space=<name>` so the
gate reads the same truth. The palette gains a `palSpace` row kind —
"Move <focused tab> to [new] space <name>" — dispatching to
`applySpaceMove`: the tab travels wholesale (bin, pin, frozen, nav,
app_state), its window hides, and its pane leaf stays behind for the
destination to re-tile.

**D19. `ctrl+shift+E` summons GOEMOJI.ELF by name** (the ADR 0007 R6
row): a hosted emoji tab focuses wherever it lives — dormant spaces
switch to it — and an absent target execs `GOEMOJI.ELF`, whose ENOENT
lands in the seat's ordinary named-refusal lane (`refusal ENOENT exec
GOEMOJI.ELF`) until card #2799 ships the picker.
