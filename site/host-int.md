---
title: Host integration
parent: machine
status: published
tags: [machine, host, clipboard, integration]
---

# Host integration

The VM is a sealed box by default: the clipboard is kernel-internal,
files cross only through the share folder, and a seat toast dies inside
the guest. "Through the glass" is the set of *consented lanes* that open
that box in both directions — plus the Mac app that makes the machine
feel like one. ADR 0051 pins the wire; this page is the tour.

Two transports carry everything below. The **VHI1 lanes** are signed
record files in the `--cvc-file` share, consumed on the guest side by
the registered seat alone. The **`virelai-ctl/1` channel** is an
HMAC-challenged JSON-Lines control wire over virtio-vsock — the same
fail-closed shape, running the other direction: guest asks, host acts.

## The wire: signed files, seat-mediated

Every lane record is one small file under `<share>/HOSTINT/` — a fixed
binary header, a bounded payload, and an `HMAC-SHA256` tag over both.
The envelope is at most 562 bytes; payloads cap at the kernel
clipboard's own 512. Filenames carry the tag and a per-tag sequence
(`CLIPIN-00000007`), writers publish by write-temp-then-rename, and
consumers delete after processing.

The credential is the ADR 0044 pattern moved onto files: a
`SECRETS.TXT` row `host-int<TAB>1000<TAB><value><TAB>GOTABWM.ELF`,
app-bound so only the seat's image is served it in-guest — and read by
the runner directly as a host file. The same row is the credential on
both sides, so provisioning is one share-file edit. A guest app can
*write* lane files but cannot *sign* them: forged records fail the MAC,
get deleted, and draw a named `bad_mac` refusal.

The runner mints a nonzero `epoch` per boot and emits one `ARMED`
record naming the lanes its flags enabled. The seat stays dormant until
it verifies one; then it adopts `(epoch, lane_mask)` and accepts only
records bearing that epoch — which makes cross-boot replay and stale
leftovers named refusals (`stale_epoch`, `stale_seq`) instead of silent
weirdness.

Every refusal has a name, both ends share the vocabulary, and none of
them echo payload bytes: `lane_disabled`, `no_credential`, `bad_record`,
`bad_mac`, `stale_epoch`, `stale_seq`, `backpressured`,
`payload_too_large`, `payload_not_text`, `name_rejected`,
`unsupported_kind`, `consent_denied`, `no_bundle`, `auth_denied`,
`io_error`.

<Aside kind="info">

**LIVE-GATED.** `live-hostint` is the standing acceptance: every lane on
one armed session, plus the negatives the consent story rests on —
planted `stale_epoch` and `bad_mac` records on both inbound tags, a
guest-planted file in `INBOX/` (no notice, no toast — anti-spoof), an
unprivileged exec hitting the `EACCES` consent wall on the clipboard
syscall, a flags-off byte-silence run, and a `no_credential` run where
all three lanes refuse by name.

</Aside>

## The clipboard lane — `--host-clipboard`

One flag arms both directions; they are one lane with one consent
story.

**Guest → host.** The seat reads the kernel clipboard once per
composite tick — lawful because the caller *is* the registered seat,
the only principal the clipboard syscalls will serve — and on change
emits a `CLIP_OUT` record. The runner verifies it and writes the text
to the target pasteboard. Because the seat observes the buffer rather
than the caller, sync triggers on every write: terminal copy chords,
the monitor's `clip`, a capability-holder's set, and a host-applied
paste are indistinguishable — which is exactly the design, since only
the seat may observe the buffer at all.

**Host → guest.** The runner polls `NSPasteboard.changeCount` every
250 ms — there is no change notification on macOS — skips the echo of
its own last write, takes the string, refuses non-text
(`payload_not_text`), truncates past 512 bytes with the `TRUNCATED`
flag, and emits `CLIP_IN`. The seat verifies epoch, MAC, and seq,
applies it through the clipboard syscall, and paints a distinct
host-marked state on its chrome clipboard glyph so a host paste landing
guest-side is never invisible.

Interactive runs target `.general`; gates and class-B runs **must** use
`--host-pasteboard <name>` so a run never clobbers the real clipboard.
Sync latency is honestly bounded: at most one record each direction per
seat tick plus the poll — about 1.25 s worst case. Gate:
`live-host-clipboard`.

## The drop lane — `--host-drop`

The host→guest file gesture. The session window's machine view
registers `.fileURL`; each dropped item gets a sanitized basename (≤48
bytes of `[A-Za-z0-9._-]`, collisions numbered), a kind check
(non-regular items refuse `unsupported_kind` — no directories), a size
check (over 64 MiB refuses `payload_too_large`), a temp+rename copy into
`<share>/INBOX/`, and a signed `DROP` record announcing it. A gesture
caps at 16 files — the bound exists so a drop is refused honestly
before the runner streams a disk image into the share.

The payload file itself is *not* signed; the notice is what carries
provenance. A guest app that plants a file in `INBOX/` produces no
notice, so the seat never attributes a guest-written file to the host —
the anti-spoof leg the gate pins.

On the guest side the toast is actionable: a click (or Enter on the
notification-center row) dispatches `open-drop` — the file goes through
the mime sniffer and the `opens=` registry picks the handler, so an
image opens in GOVIEW and an unhandled type falls back to GOFILES
revealing `INBOX/` itself. The action is bound to the *verified* record
at push time, so it can never be retargeted at a file the record did
not name. Delivery and notice are independent: notice backpressure
never un-drops a file, it just stops announcing. Gate: `live-host-drop`.

## The notify lane — `--host-notify`

Seat toasts cross the glass. Every toast the seat pushes while the lane
is armed also becomes a signed `NOTIFY_OUT` record — the same ≤24-byte
text, emitted at the toast strip's own structural bound of one per tick
with at most four outstanding. The runner drains them at its 250 ms
poll and posts each as a `UNUserNotificationCenter` banner.

Banners exist only under the `just session` bundle — a notification
center call needs a bundle identity — so the bare gate runner consumes
the records normally and logs `host-notify: dropped reason=no_bundle`
per record instead. The lane machinery (records, MAC verify, ordering,
rate bound) stays fully class-B observable; only the pixel of the
banner is a human leg. At arm the runner requests notification
authorization; refusal is `auth_denied`.

Click-through closes the loop: each `NOTIFY_OUT` carries the toast's
sender tab id in the record's `sender_id` field, the runner binds it to
the banner it posts, and a click raises the VM window and emits a
signed `NOTIFY_FOCUS` back — which the seat turns into a real focus
event on that tab through the same seam alt-tab takes. A
seat-originated toast (a host drop, an agent milestone) has no tab to
focus; a tab that closed between banner and click answers `gone`. Gate:
`live-host-notify`.

## The export lane — `--host-outbox`

The reverse drop. GOSH `export <path>` or GOFILES "Export to Host"
stages a payload under `<share>/OUTBOX/` plus a `REQ-<hex>` intent
marker naming it. The seat polls the directory once per tick — only
while the adopted mask carries the outbox bit — signs one `OUTBOX`
record per REQ, and deletes the marker. The REQ is unsigned by design:
it is intent, not provenance. What the host trusts is the signed
record, and the seat signs only REQ-marked payloads — an unmarked file
sitting in `OUTBOX/` is inert, and a host-side plant cannot bounce
either because nothing produces a REQ for it.

The runner verifies each record and moves the named payload to
`--host-outbox-dir` (default `~/Downloads`), capping at 64 MiB per
file, 64 exports per epoch, and one record consumed per tick. The
`reveal-export` bus verb opens the most recent landing in Finder — the
gesture the export banner's click mirrors. Gate: `live-host-outbox`.

## Flags-off is byte-silent

Every lane is default-off at both ends, and the lane flags are
*modifiers on `--cvc-file`* — a lane flag without a share is a fatal
runner argument error, never a silent ignore. Flags off means the
runner never creates `HOSTINT/`, `INBOX/`, or `OUTBOX/`, never writes a
record, never touches a pasteboard, and the VM configuration is
byte-identical to a bare boot. Guest-side, the seat's lane engine arms
only after a *verifiable* `ARMED` record — no flag, no records, nothing
to verify, nothing to poll. A lane that cannot read its credential
refuses `no_credential` at arm and the boot continues with that lane
dead: fail closed, per lane, never a boot failure.

The lanes are also runtime-toggleable: the Integration menu's
Clipboard/File Drop/Notifications items republish `ARMED` under the
same epoch with the bit cleared, and the seat's next poll adopts the
new mask and refuses that lane `lane_disabled` — the checkmark *is* the
live state, not a UI-only flag.

## The control channel — `virelai-ctl/1` over vsock

Separate from the file lanes, and running the other direction: the
*guest* asks the *host* to act on the machine. `--vsock` attaches
Apple's `VZVirtioSocketDevice` — the one in-SDK guest↔host channel that
survives save/restore validation, which is why suspend and snapshots
ride it and not the share — and `--vsock-ctl` arms a host listener on
`--vsock-ctl-port` (default 1209).

The wire is `virelai-ctl/1`: one stream connect, a server greeting with
a fresh 32-byte challenge, one HMAC-SHA256 answer keyed by the
share's `vsock-ctl` secret row, then newline-delimited verb requests.
The `vsock-ctl` row is `uid_system`-scoped — invisible to every
`sys_secret_get` caller, readable by the kernel's own client. The MAC
domain is distinct from both the console's and AGENTD's, so a captured
answer dies with its connection's challenge. Both ends fail closed: no
credential, no listener, no service — `VSOCK-CTL: refuse no_credential`
host-side, `vsock-ctl: refuse no_credential` guest-side.

The verbs are the machine-lifecycle ones [[machine]] describes:
`suspend`, `snapshot <name>`, `restore <name>`, and the read-only
`profile-info`. In-guest callers are the kernel monitor's `vsock ctl`,
GOSH's `suspend` builtin, and the seat's PWR-menu Suspend row, all
through slot 93 `sys_vsock_ctl`. Failures are named, never silent:
`unknown_verb`, `name_rejected`, `replay`, `no_state`, `unsupported`,
`busy`, `exists`, `not_found`. Gate: `live-vsock-ctl`.

## The Mac app — `just session`

`tools/session.sh` packages the runner as a real bundle —
`org.virelaios.host`, ad-hoc signed — and inside it the runner becomes a
Mac app with a menu bar, a resizable window, and a debug surface. The
arc that built it is closed; `live-host-ui` is the acceptance.

### One seam for everything: the HostCommand bus

Every host-UI action — every menu item, toolbar pill, chord, and
lane toggle — dispatches a *verb* on the `HostCommand` action bus, and
the runner's `--host-cmd-after <marker>:<verb>` flag dispatches the
identical verb headlessly once the marker appears on serial. That is
the whole testability story: the window is never driven by synthesized
clicks (macOS activation walls refuse that from background processes),
yet every feature is class-B exercisable. Each dispatch writes one
`host-ui: cmd=<verb> vm=<n> state=<performed|disabled|unavailable>`
receipt — `vm=<n>` names the session in a multi-window run.

The menu bar is a projection of the command table — VirelaiOS,
Machine, View, Integration, Debug, Help — and the ⌘/ cheat sheet is the
other projection of the same table, so a chord the menus do not know
can never appear in the sheet. Machine Settings is ⌘,; Quit is ⌘Q.

### The window

The machine view is 16:9, resizable, and fullscreenable (⌃⌘F). When the
VM needs keys macOS would normally keep — ⌘-space, ⌘-tab — **Capture
System Keys** (⌥⌘K, the toolbar pill, or `--host-capture-keys` to arm it
at startup) toggles `capturesSystemKeys`, and the receipt reports the
live post-toggle state.

### The inspector drawer — ⌥⌘I

A slide-in drawer owns the diagnostics surface: a bounded 2000-line
serial tail with case-insensitive search/filter, a command-injector
input line whose Send writes into the console pipe (the same path
`--script` and `--host-serial-send` forward through), live HostInt lane
counters, a postmortem card that opens itself when the VM stops early,
and the serial tracer's filtered `[strace]` rows as a sibling view.

### Capture

⌘⇧5 takes a screenshot through the same framebuffer path
`--screenshot-after` uses. ⌘⇧6 toggles recording: bounded to **60
seconds hard** — a one-shot timer enforces the cap even if the stop
verb never fires — capturing 15 fps through `cacheDisplay` into an
H.264 MP4 under `<share>/CAPTURES/`, with a REC badge while live.
`cacheDisplay` is the view's own pixels, deliberately *not*
ScreenCaptureKit: an SCStream would need the TCC Screen Recording grant
a gate host does not carry, and the view's offscreen render is the
deterministic source anyway.

### Multi-VM windows

One process can host several machines — see [[remote]] for the
profile-window story; the Integration and Machine menus act on
whichever window is frontmost through a dispatch router.

## Read next

- [[machine|The machine]] — the lifecycle the ctl verbs drive.
- [[remote|Reaching the machine]] — AGENTD and the other inbound doors.
- [[run|The runner reference]] — every `--host-*` flag spelled out.
- [`docs/decisions/0051-host-integration.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0051-host-integration.md) and
  [`docs/decisions/0056-vsock-ctl-channel.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0056-vsock-ctl-channel.md)
  — the binding ADRs, including the VHI1 v2 amendment.
