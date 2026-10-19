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
