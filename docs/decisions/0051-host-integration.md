# ADR 0051: Host-integration wire — three consented lanes over signed share files

- Date: 2026-10-15
- Status: **Accepted** — v1 landed with M108b–e (clip #2341, drop #2347,
  notify #2350, gate live-hostint). **v2 amendment proposed** under
  M127a (#2599) — see the amendment section at the end.
- Card: **#2324** (M108, program index #2305) — card 1 of 5. The wire
  shape and consent model that M108b/c/d implement and M108e accepts.
  The v2 amendment's card is **#2599** (M127, index #2555).
- Related: ADR 0007 (M97g amendment — clipboard consent gate), ADR 0009
  (event kinds and routing restrictions), ADR 0024 (trust baseline:
  OWNERS.TXT uid enforcement, SECRETS.TXT app-bound secrets), ADR 0044
  (agentd — the fail-closed host↔guest channel precedent), ADR 0045 (the
  arm-and-indicator consent pattern), ADR 0037 §S4 (recorded negatives:
  no routable host→guest path).

> The VM is a sealed box today: the clipboard is kernel-internal, files
> cross only through the share folder, and a seat toast dies inside the
> guest. M108 opens three lanes — clipboard both ways, host→guest file
> drop, guest→host notify — and this ADR pins the wire before any Swift
> or guest code. The decision below is deliberately boring: **the lanes
> are signed files in the `--cvc-file` share, consumed on the guest side
> by the seat alone.** No new virtqueue, no new syscall, no new event
> kind, no kernel diff. The authentication is the ADR 0044 pattern
> (HMAC-SHA256, SECRETS.TXT app-bound key) carried on files instead of a
> socket, and the consent is the M97g rule (seat as choke point plus a
> user-visible indicator), not a prompt vocabulary that does not exist.

## Mission

Pin, before implementation: the message envelope (tags, directions,
bounds, refusal names), the consent mapping onto `cap_clipboard`/seat
mediation, the file-drop destination, the notify-out rate bound and
bundle posture, the runner flag vocabulary, and the rule that a
flags-off boot is byte-silent. Out of scope: any code, and any fourth
lane.

## Grounding (observed in tree `d7f950c3`, 2026-10-15)

- **Custom-virtio has no host-initiated send.** The only host→guest
  path is the guest pre-arming device-write buffers that the host
  dequeues and fills (`kernel/src/virtio_custom.zig:46-55`: "the
  pre-arm/dequeue/write/return pattern is the only host→guest data
  path"; used by queue 2 `--cvc-echo` and queue 3 `--via-virtio`).
  Queue count IS the capability signal: optional queues 2–5 are probed
  by size (`virtio_custom.zig:150-172`), and the deepest-flag rule
  (`docs/hardware-contract.md` queue-plan table) means each deeper flag
  implies every queue below it.
- **The share is already a two-party channel.** `--cvc-file <dir>`
  serves a macOS folder as `/host` over queue 5
  (`kernel/src/virtio_file.zig`, wire pinned in
  `docs/hardware-contract.md` §host file channel). The runner owns the
  folder host-side and already writes into it (`tools/session.sh`
  writes `.clock`); atomic landing is the `WriteFileSafe`/HF3 pattern —
  temp name, fsync, RENAME (`vi/vi.go:656-689`). Path ceiling is 64
  bytes (`max_path_len`).
- **Clipboard state.** One 512-byte machine-global buffer
  (`kernel/src/clipboard.zig:25`, pure storage, `set_count` per set).
  Slots 38/39 return `EACCES` unless the caller holds `CAP_CLIPBOARD`
  **or is the kernel-registered seat** — the check is
  `pid == wm_server.registered_pid()`
  (`kernel/src/syscall.zig:2771-2776`, ADR 0007 M97g amendment). The
  user-gesture writes (terminal copy/paste chords, monitor `clip`) are
  kernel-internal and never touch the gate. Consequence, observed:
  GOEDIT's own clipboard calls get `EACCES` on the default seat
  (`user/go/edit/main.go:70-74` documents the wall), so **only the seat
  can observe a default-seat user's copy**. `vsys.ClipboardSet/Get`
  exist (`user/go/vsys/clipboard.go:58`).
- **Consent is a capability gate, not a prompt.** There is no
  consent-dialog vocabulary anywhere in the tree; M97g's transferable
  rule is "privileged seam acceptable when the seat is the choke point
  **and** the seat makes the activity visible" (ADR 0045 records the
  same rule for remote input). The kernel `WMCTL_TRAY` ABI (slot 65 cmd
  10: flags bit 2 = clipboard field, a2 bit 8 = filled,
  `syscall.zig` `wmctl_tray` case) targets the kernel-shim taskbar; the
  Go seat composites the whole scanout and paints its own chrome
  (`user/go/gotabwm/chrome.go`), so under GOTABWM the indicator is a
  seat-painted glyph, not a wmctl call — no `WmctlTray` wrapper exists
  in `user/go/vi` today.
- **No clipboard-changed event exists.** ADR 0009 kinds run 1–21
  (`kernel/src/events.zig:27-97`); nothing reports a clipboard change.
  Kinds 18–21 are routing-restricted to the registered WM. Adding a
  kind is an ADR 0009 amendment — real surface, and pointless for a
  consumer that is always the seat anyway (no other process may read
  the buffer).
- **The seat already ticks.** GOTABWM's composite loop is paced by the
  kind-18 `COMPOSITE_TICK` at ~1 Hz and interleaves `serviceRPC` +
  housekeeping per pass (`user/go/gotabwm/seat.go:103`,`:377-391`).
  `vi.ListDirAt`, `vi.FileRename`, `vi.FileDelete` exist. A per-tick
  directory read is one cheap syscall.
- **Notify exists in-seat.** WM_RPC kind 12 carries a toast; the whole
  text budget is the frame's 24-byte title
  (`user/go/vi/wmclient.go:106-112`, `vi.Notify` `:558`). The seat's
  toast strip is a bounded 4-deep drop-oldest queue with markers
  `gotabwm: notify id=` / `notify drop n=` (M79k, status.md).
- **Mime dispatch exists.** `virelai/mime` sniffs a file head (magic →
  extension → text heuristic) and the `opens=` registry in APPS.TXT
  names the handler (`user/go/mime/mime.go`, `user/go/files/open.go`,
  `user/go/gotabwm/apps.go:33`). A file under `/host` already routes to
  its app — GOVIEW for an image — with no new machinery.
- **Ownership cannot bind a file to the seat.** ADR 0024 D3: OWNERS.TXT
  rows bind a path to a **uid** and enforcement is owner-bits vs
  other-bits (`caller.uid == entry.uid`). The seat is exec'd plain
  (uid_user, `tools/gate/specs/go-wm-seat.spec:98`), so a
  `uid_user`-owned lane file is writable by every unprivileged app and
  a `uid_system`-owned one excludes the seat itself. Verified: there is
  no per-pid file ownership, and no second non-system uid exists to
  give the seat (ADR 0024 D1).
- **App-bound secrets do bind to an image.** `SECRETS.TXT` rows are
  served only to a caller whose uid matches the row and whose image is
  `uid_system`-owned with no non-owner write bit (ADR 0024 D8;
  `vi.SecretList`, `user/go/vi/trust.go:79`). AGENTD.ELF and
  GOSSHD.ELF already hold credentials this way. The guest HMAC-SHA256
  exists (`user/go/shlib/hmac.go`; `crypto/sha256` does not build under
  `GOOS=virelai`). The runner can read the same `SECRETS.TXT` row as a
  host file — the share is a macOS folder it owns.
- **Runner flag vocabulary.** Flags are parsed in one argv walk with
  additive, default-off, loud-on-misuse semantics
  (`host/vm-runner/Sources/VMRunner/main.swift:942-1237`); marker-timed
  test hooks are the established pattern (`--input-string-after`,
  `--host-write-after`, `--net-tcp-connect-after`). The
  `VZVirtualMachineView` exists only on the `--display`/`--screenshot`
  path (`main.swift:1913`,`:2900`). No `NSPasteboard` or
  `UNUserNotificationCenter` import exists in the runner today.
- **The bundle split is real.** Only `just session` packages a bundle:
  ad-hoc-signed `VirelaiOS.app`, `CFBundleIdentifier
  org.virelaios.host` (`tools/session.sh:214-220`). The gate runner is
  the bare executable. `UNUserNotificationCenter.current()` requires a
  bundle identity — **[inferred]** an unbundled call throws/faults;
  M108d verifies on first run.
- **Fail-closed precedent.** agentd refuses at startup, before binding,
  with one named marker per missing precondition, and there is no open
  mode (ADR 0044 D2). Its never-logged contract (secrets, payloads and
  MACs never reach serial/stdout; sha/length only) applies here
  unchanged.

## D1. Carrier: signed lane files over `--cvc-file`, seat-mediated

**Decision: all three lanes ride share files. No new virtqueue, no new
syscall, no new event kind, no kernel diff.**

Two directories in the share root:

- `/host/HOSTINT/` — the lane channel: one small signed record per
  file (D2), written and consumed per the lane rules below.
- `/host/INBOX/` — the drop destination (D4): bulk payload files the
  runner writes directly with temp+rename.

The guest-side endpoint of every lane is **the registered seat**, not
an app and not the kernel: the seat polls the channel once per
composite tick, and it alone may touch slots 38/39 anyway. The
host-side endpoint is the runner process.

**Why not a dedicated virtqueue** (the alternative the index offered):
three independent reasons, each sufficient.

1. *Queue-count contiguity makes it dishonest.* A lane queue must sit
   at index 6; virtqueues are contiguous and deeper flags imply the
   whole shape below (`docs/hardware-contract.md`), so arming it
   implies queue 5 — the file channel — which needs a `--cvc-file`
   directory. A clipboard user would have to provision a share they
   never wanted, or the runner attaches a queue that answers every op
   `host error`, breaking the "an armed queue works" invariant.
2. *EL0 cannot post to a virtqueue.* `submit_ex` is kernel-internal;
   guest→host (clipboard-out, notify-out) would need either a new
   syscall surface for the seat to hand the kernel a message, or the
   kernel itself watching `clipboard.set_count` and serializing buffer
   contents — lane policy baked into the kernel. Both are new ABI for
   a lane the seat can carry with existing syscalls.
3. *Consent wants the seat in the path regardless.* A queue delivers
   host bytes to the kernel, but M97g's rule keeps the seat as the
   choke point and the visibility renderer — a kernel-direct
   `clipboard.set` on a host→guest write would bypass the one
   principal allowed to call it. The queue buys transport purity and
   still lands at the seat's door.

**Why not OWNERS.TXT binding as the spoofing defence** (the review
note asked to verify it): it does not work, and this ADR corrects the
premise. Enforcement is per-uid (Grounding), the seat runs `uid_user`,
so owner bits cannot distinguish the seat from GOEDIT. Minting a
`uid_seat` would make every `uid_user`-owned share file foreign to the
seat (APPS.TXT, SETTINGS.TXT writes would hit other-bits) — a trust-
model cascade for a file-spoofing problem that already has a cheaper
answer below.

**The spoofing defence is a record MAC**, the ADR 0044 shape on files:
every lane record carries `HMAC-SHA256(key, header‖payload)` where
`key` is a `SECRETS.TXT` row

```
host-int<TAB>1000<TAB><value><TAB>GOTABWM.ELF
```

served to the seat through `sys_secret_get` (image `uid_system`-owned
in OWNERS.TXT, per ADR 0024 D8) **and read by the runner directly as a
host file** — the same row is the credential on both sides, so
provisioning is one share-file edit. A guest app can write lane files
but cannot sign them: forged records fail the MAC and are deleted with
a named refusal. Recorded residual, same posture agentd already
carries: the key is bound to the *image*, so a process that execs
`GOTABWM.ELF` itself holds it — it still cannot register as a second
seat, and the seat-specific privileges (the wm gate, slots 38/39) stay
pid-keyed to the real one.

## D2. The message envelope — `VHI1` lane records

One record per file. Fixed binary header (no JSON, no parser
ambiguity — the file-channel wire style), then payload, then tag:

```
offset  field
0..3    magic  "VHI1"
4       tag    u8: 0=ARMED 1=CLIP_OUT 2=CLIP_IN 3=NOTIFY_OUT 4=DROP_NOTICE
5       flags  u8: bit0 TRUNCATED; bits 1-7 reserved (writer sends 0)
6..7    reserved (0)
8..11   seq    u32le — per-tag monotonic, starts at 1 per epoch
12..15  epoch  u32le — the runner's per-boot nonce
16..17  plen   u16le — payload bytes, 0..512
18..    payload[plen]
+32     mac    HMAC-SHA256(host-int key, bytes[0 .. 18+plen))
```

**Amended (M127a, #2599):** in v2, bytes 6..7 are `sender_id u16le`
(0 = none), no longer reserved-zero, and tags 5–6 join the map — the
562-byte envelope, the MAC domain and the filename grammar do not
move. See *V2-D1*/*V2-D2* below.

Bounds: a record is at most 4+1+1+2+4+4+2+512+32 = **562 bytes**; the
payload ceiling is the kernel clipboard's own 512. Filenames are
`HOSTINT/<TAGNAME>-<seq:8hex>` (`ARMED-00000001`, `CLIPIN-00000007`,
`CLIPOUT-…`, `NOTIFY-…`, `DROP-…`) — ≤ 16 bytes, `/`-free, inside the
64-byte path bound with room for the `~` temp convention. Writers
publish by write-temp-then-`RENAME` (the share's established atomicity
rule); consumers `DELETE` after processing. A producer never has more
than **4 unconsumed records outstanding per tag** — over that it
refuses to emit (`backpressured`) and counts, the toast queue's own
depth as the shared bound.

**Tag direction map** (direction is in the tag, and the consumer of
each tag is fixed):

| Tag | Name | Direction | Producer → Consumer | Payload |
|-----|------|-----------|---------------------|---------|
| 0 | `ARMED` | h→g | runner → seat | `[lane_mask u8]` (bit0 clip, bit1 drop, bit2 notify) |
| 1 | `CLIP_OUT` | g→h | seat → runner | clipboard bytes (0 = clear) |
| 2 | `CLIP_IN` | h→g | runner → seat | UTF-8 text ≤ 512, TRUNCATED flag on cut |
| 3 | `NOTIFY_OUT` | g→h | seat → runner | toast text ≤ 24 (the kind-12 budget) |
| 4 | `DROP` | h→g | runner → seat | `[name_len u8][name][size u64le]` — announces one INBOX file |

**Epoch + seq rules.** The runner mints a nonzero `epoch` per process
start and emits one `ARMED` record when it arms, naming every lane its
flags enabled in `lane_mask`. The seat stays
dormant until it has verified one `ARMED`; it then adopts `(epoch,
lane_mask)` and accepts only records bearing that epoch. Producers
start `seq` at 1 per epoch; consumers track last-accepted `seq` per
tag and refuse `stale_seq` on `seq <= last` and `stale_epoch` on a
mismatch — which makes cross-boot replay and stale leftovers named
refusals instead of silent weirdness. The seat never emits CLIP_OUT or
NOTIFY_OUT before adopting an epoch, so a lane file the host cannot
attribute is never written.

**Refusal vocabulary** (one set of names, both ends; surfaced as
runner stdout `host-int: refuse lane=<l> reason=<code>` and seat
serial `gotabwm: hostint refuse lane=<l> reason=<code>` — grep-able,
never echoing payload bytes):

| Reason | Meaning |
|--------|---------|
| `lane_disabled` | the lane's flag (or ARMED mask bit) is off |
| `no_credential` | the `host-int` SECRETS.TXT row is absent/unreadable |
| `bad_record` | wrong magic, bad tag, reserved nonzero, plen > 512, wrong total size |
| `bad_mac` | signature mismatch — the forgery refusal |
| `stale_epoch` / `stale_seq` | valid but superseded/out-of-window record |
| `backpressured` | 4 unconsumed records outstanding |
| `payload_too_large` | clipboard text > 512 host-side, drop file over cap |
| `payload_not_text` | bytes offered for a clipboard record are not valid UTF-8 |
| `name_rejected` | drop basename fails the name rule (D4) |
| `unsupported_kind` | dropped item is not a regular file (v1: no directories) |
| `consent_denied` | seat declines to apply a h→g record: lane mask bit off or seat absent |
| `no_bundle` | notify banner requested on a bundleless runner (D5) |
| `auth_denied` | macOS notification authorization was refused |
| `io_error` | share read/write failure |

**Never-logged contract** (ADR 0044 D6 verbatim): the key, MACs,
clipboard text, notify text and dropped file contents never reach
serial, `APPLOG`, runner stdout or crash receipts. Log lines carry
tag, seq, length and `sha256[:8]` only.

## D3. Clipboard lane — the M97g gate carried across the glass

`--host-clipboard` arms both directions together; they are one lane,
one flag, one consent story. The 512-byte bound stays exactly the
kernel's bound — truncation is honest (`TRUNCATED` flag) inbound, a
named refusal for non-text in both directions.

**Guest → host.** The seat, once per composite tick, reads the
clipboard via slot 39 — lawful because the caller *is* the registered
seat (`clipboard_authorized`, `syscall.zig:2771`) — and compares
`(len, FNV-1a)` against last-tick. On change it emits `CLIP_OUT`
carrying the bytes; on the runner side the record is consumed,
verified, and written to the target pasteboard as text. Because the
seat observes the *buffer* rather than the caller, sync triggers on
**every** change — terminal copy chords, monitor `clip`, a
`CAP_CLIPBOARD` holder's write, and a host-applied write are
indistinguishable to it. That is the only shape that lets a
default-seat user's copy reach the host at all (GOEDIT gets `EACCES`
by design), and it is precisely the M97g story: the seat is the
user-mediated observer, so everything it sees is already consented.
len 0 (a clear) publishes an empty pasteboard item.

**Host → guest.** `NSPasteboard` has no change notification, so the
runner polls `changeCount` every **250 ms**. A bump whose current
string equals the last value the runner itself wrote is the echo of
its own `CLIP_OUT` and is skipped — the echo guard both directions
needs (the seat mirrors it: content it last applied via `CLIP_IN` is
skipped once on its next compare). Other bumps: the runner takes
`string(forType: .string)`, refuses non-text (`payload_not_text`),
truncates to 512 with `TRUNCATED`, and emits `CLIP_IN`. The seat
verifies epoch/MAC/seq, applies via slot 38, deletes the file, and
emits one marker (`len` + `sha256[:8]`, never text). Applying is
automatic while the lane is armed — consent was the operator's flag
plus the provisioned credential, per the "no prompts" correction; the
seat's obligation under M97g-F4 is *visibility*, not interposition.

**The host→guest notice needs no new event kind.** The lawful consumer
of the kernel buffer is the seat alone, so a lane-file poll on the
seat's existing tick *is* the notification channel; an ADR 0009 kind
would add routing surface to inform a process that already polls and
that no other process may join. Rejected: kind 22 stays unallocated.

**The tray story**, per the review note: under GOTABWM the indicator
is seat-painted chrome — the seat owns the scanout and renders a
clipboard state glyph in its bottom panel; while the last buffer write
was host-sourced the glyph shows a distinct host-marked state, so a
host paste landing guest-side is never invisible (the ADR 0045 remote-
session-indicator rule applied to the clipboard). The kernel
`WMCTL_TRAY` bit-2/a2-bit-8 path remains the shim/Zig-seat ABI,
unchanged; a flags-on boot with no registered seat simply never arms —
a `CLIP_IN` file past the 4-record cap draws runner-side
`backpressured`, and seat-side application is `consent_denied`
(seat-absent) by construction. **Rate bound:** ≤ 1 `CLIP_OUT` and ≤ 1
`CLIP_IN` applied per seat tick (~1 Hz) — clipboard sync latency is
~1.25 s worst case (seat tick + runner poll), an honest number this
ADR states rather than hides.

**Pasteboard identity.** Interactive runs target `.general`; gates and
class-B runs MUST use a named board via `--host-pasteboard <name>`
(D6) so a gate never clobbers the reference host's real clipboard —
`NSPasteboard(name:)` is a private board, `pbpaste -pboard <name>`
reads it for assertions.

## D4. File drop lane — `/host/INBOX/`, announced by a signed notice

`--host-drop` arms the lane. Destination is **`/host/INBOX/`, not a
channel-direct write**: the runner already owns the share folder, so a
drop is a plain `FileManager` write with temp+rename — zero guest
involvement in delivery, atomic visibility by construction, and no new
transport to bound. The runner creates `<share>/INBOX/` at arm time.

Host side: the runner's display view (the `VZVirtualMachineView`
window's content view, `--display`/`--screenshot` path only — the headless
runner refuses `lane_disabled` at arm) registers `.fileURL` and, per
dropped item, sanitizes the basename (≤ 48 bytes, `[A-Za-z0-9._-]`
with other bytes folded to `_`, leading non-alphanumeric prefixed `F`,
collisions get `-2`…`-9` then `name_rejected`), refuses non-regular
items (`unsupported_kind`) and files over the cap, copies to
`INBOX/<name>` via `<name>~`+rename, then emits a signed `DROP` record
naming it. **Caps: ≤ 64 MiB per file, ≤ 16 files per gesture** — the
bound exists so a drop can be refused honestly before the runner
streams a disk image into a gate share, not because the transport
needs it (the share has no per-file bound; `payload_too_large` carries
the refusal).

Guest side: the seat consumes `DROP` records — verified epoch/MAC/seq —
and posts the toast `host drop: <name>` through its existing kind-12
path. The payload file itself is *not* signed (it is bulk content in a
folder the host already controls), and the notice is what carries
provenance: a guest app that plants a file in `INBOX/` produces no
notice, so the seat never attributes a guest-written file to the host.
~~Toast click does nothing — dismiss only~~ **Amended (M127a, #2599):**
v2 makes the drop toast actionable — a click or Enter dispatches the
announced INBOX file through the `opens=` table (V2-D4). There is still
no sender tab to focus (sender stays 0); the click is the action.
Opening is the M81b path unchanged: `mime.Open` sniffs the head, the
`opens=` registry picks the app, GOVIEW serves `image`. Delivery and
notice are independent: notice backpressure never un-drops a file, it
just stops announcing.

## D5. Notify-out lane — one-way FYI banners, bounded

`--host-notify` arms the lane. Every toast the seat pushes through its
kind-12 path while the lane is armed also becomes a `NOTIFY_OUT`
record carrying the same ≤ 24-byte text. **Rate bound is structural:
≤ 1 record emitted per seat tick (~1 Hz) and ≤ 4 outstanding** — the
toast strip's own depth — so the lane can never out-produce the
on-glass rate the user already accepted; overflow reuses the existing
`notify drop n=` accounting. The runner drains at its 250 ms poll and
posts each record as a `UNUserNotificationCenter` banner under the
session bundle, installing a minimal delegate whose `willPresent`
returns banner presentation so a notification shows while the runner
is frontmost. At arm it requests authorization; refusal is
`auth_denied`. v1 is one-way FYI, stated plainly: ~~**a banner click
lands nowhere** — no delegate action, no VM focus, no deep link.~~
**Amended (M127a, #2599):** v2 routes a banner click back to the seat
as a signed `NOTIFY_FOCUS` carrying `sender_id` — V2-D3.

**Bundle reality, named not waved:** banners only exist under the
`just session` bundle (`org.virelaios.host`, `tools/session.sh:214-220`,
ad-hoc signed). The bare gate runner has no bundle identity, so it
consumes `NOTIFY_OUT` records normally but logs
`host-notify: dropped reason=no_bundle seq=<n>` instead of calling
`UNUserNotificationCenter` — the lane machinery (records, MAC verify,
ordering, rate bound) is fully class-B observable and only the pixel
of the banner is a class-C human leg. If unbundled `.current()` turns
out to *throw* rather than fault [inferred, M108d verifies], the guard
is still "check bundle identity first, never call it bare".

## D6. Runner flags and test hooks — the vocabulary

All three lane flags are **modifiers on `--cvc-file <dir>`** — the
share is the transport, so a lane flag without it is a fatal runner
argument error (loud, never a silent ignore — the `--via-virtio`
rule). All additionally require the `host-int` SECRETS.TXT row; absent
or malformed the lane refuses `no_credential` at arm and the boot
continues with that lane dead (fail closed, per lane, not a boot
failure).

| Flag | Arms |
|------|------|
| `--host-clipboard` | CLIP_IN/CLIP_OUT both directions; `.general` pasteboard |
| `--host-drop` | `.fileURL` drop target on the display view + `/host/INBOX/` + `DROP` notices |
| `--host-notify` | NOTIFY_OUT consumption + banners (bundle) or `no_bundle` refusals (bare) |
| `--host-pasteboard <name>` | test hook — redirect the clipboard lane to `NSPasteboard(name:)`; mandatory for gates |
| `--host-drop-file <path>` | test hook — feed a host file through the real drop handler (the `--input-string` precedent) |
| `--host-drop-after <marker>` | test hook — delay the injected drop until `<marker>` appears on guest serial |

No new virtqueue and no queue-count change: the queue-plan table is
untouched, which is the whole point of D1.

**Runner stdout, the gate surface** (one line per event, payload-free):

```
host-int: armed lanes=clip,drop,notify epoch=<n>
host-int: refuse lane=<lane> reason=<code>
host-clip: out seq=<n> sha256=<8> len=<n>
host-clip: in  seq=<n> sha256=<8> len=<n> truncated=<0|1>
host-drop: file seq=<n> name=<name> size=<n>
host-notify: post seq=<n>
host-notify: dropped reason=<code> n=<count>
```

## D7. Defaults — flags-off is byte-silent

Every lane is default-off at both ends. Flags off means the runner
never creates `HOSTINT/` or `INBOX/`, never writes a record, never
polls a pasteboard, and the VM configuration is byte-identical to
today — the additive-device rule already proved by the other flags.
Guest-side the seat's lane engine arms only after a *verifiable*
`ARMED` record: no flag → no records → nothing to verify → one
in-tick `ListDirAt` result per second against a directory that never
exists, or nothing at all when the `host-int` row is absent (checked
once at startup). A forged `ARMED`/`CLIP_IN` written by a guest app
fails the MAC, is deleted, and draws one `bad_mac` marker — the lane
cannot be willed into existence from inside. No `SERVICES.JSON` or
`apps.txt` row, no autostart, no boot-path change.

## D8. Card split — file-level Touches so the lanes can disjoint

The index's per-lane Touches overlapped (`…/VMRunner/*`,
`gotabwm/*`, `virtio_custom.zig`). Under D1 the kernel files leave the
arc entirely — **M108b/c/d touch no kernel path** — and the residual
overlap narrows to two shared files that land once with M108b:

| Card | Owns exclusively | Notes |
|------|------------------|-------|
| M108b (clip) | `host/vm-runner/Sources/VMRunner/HostInt.swift` (VHI1 codec + key load + lane IO — the shared half), `HostClipboard.swift`, the flag-parse block in `main.swift`, `user/go/gotabwm/hostint.go` (seat lane engine: ARMED adopt, verify, seq/epoch), `gotabwm/hostclip.go`, `tools/gate/specs/live-host-clipboard.spec` | lands first; carries the shared seam |
| M108c (drop) | `HostDrop.swift`, `gotabwm/hostdrop.go`, `live-host-drop.spec` | builds on b's shared files only |
| M108d (notify) | `HostNotify.swift`, `gotabwm/hostnotify.go` + the one-line hook in `notifyPush`, `live-host-notify.spec` | same |
| M108e | `tools/gate/specs/` acceptance spec, `docs/status.md` row | flags-off silence run |

With those Touches, c and d are parallel-safe after b lands; before b
they are not, which is stated rather than discovered by the
coordination gate.

## Consequences

- The kernel, the ABI, the event table and the boot path do not move.
  The arc's entire guest surface is seat + share, its entire host
  surface is runner + share: the smallest honest cut of "three lanes
  across the glass".
- Consent is exactly M97g's and no stronger: a host push becomes
  guest clipboard by the seat's hand, with a visible chrome state —
  and it is *not* end-to-end user approval per paste. An operator who
  arms the flag and ships the credential has consented for the boot.
- The wire is files, so ordering across tags is not guaranteed (seq is
  per-tag) and delivery is poll-paced — fine for FYI lanes, and stated
  so no card mistakes it for a stream.
- The image-bound key residual (any exec'd `GOTABWM.ELF` holds it) is
  agentd's accepted posture; if a future card wants pid-binding it is
  a trust-model card, not a lane fix.

## Open questions / deferred

- ~~Click-through semantics for drop toasts and banners (focus a tab,
  open INBOX in GOFILES, focus the VM window) — deliberately FYI-only
  in v1; the seam exists when a card wants it.~~ Resolved by the v2
  amendment (M127a, #2599): V2-D3/D4.
- Whether interactive sessions want a seat-side arm toggle (a chrome
  chord to suspend host lanes mid-session). The flags are boot-time;
  a runtime toggle is a consent upgrade, not a gap.
- Clipboard richness beyond UTF-8 text (the index's explicit non-goal)
  and a `CLIP_OUT` of non-text guest bytes — refused by name today.
- The `no_credential` boot policy could tighten to a fatal runner
  error if owners prefer arm-time failure to a dead lane; D6 picked
  the agentd-style per-lane refusal because the lanes are independent
  and the boot is not.

## Amendment (2026-10-18, M127a / #2599): VHI1 v2 — the round trip

- Status: **Proposed** — submitted with the card; M127b–f implement on
  approval.
- Card: **#2599** (M127, index #2555) — card 1 of 6.
- Amends: D4's dismiss-only drop toast and D5's "a banner click lands
  nowhere" — both were deliberate FYI postures deferred to this arc,
  not design errors.
- Does not move: the 562-byte signed envelope, the MAC domain
  (`bytes[0..18+plen)`), the `STEM-<seq:8hex>` filename grammar, the
  ARMED/epoch/seq handshake, the refusal and marker shapes, the
  seat-as-endpoint rule, and D7's flags-off byte-silence.

> v1 made the lanes one-way FYI: a dropped file landed and its toast
> could only be dismissed; a banner had no click; nothing could leave
> the guest by intent. v2 closes the loop on the same wire: the two
> reserved header bytes become `sender_id`, two tags are added, the
> drop toast grows the action it was always missing, and OUTBOX gives
> the guest a signed export gesture. Every lane stays consent-shaped —
> the drop-open dispatches through the `opens=` table the operator
> already controls, exports carry host-side size/count caps, and no
> agent-initiated host action exists (AGENTD stays guest-facing per
> ADR 0044/0052 — an explicit M127 non-goal).

### V2-D1. `sender_id` — the two reserved header bytes, spent

v1 reserved bytes 6..7 and required them zero (`bad_record` otherwise —
`vhi1.go`'s `raw[6] != 0 || raw[7] != 0`, `HostInt.swift`'s decode
check). v2 redefines them as **`sender_id u16le`** — the kernel window
id a record is *about*; 0 = none. Window ids are already u8 on the
kernel wire (`kernel/src/driving_award.zig`: user windows 2..9,
`focused_window_id() u8`) and in the WM_RPC frame (`req.ID uint8` —
the seat's `tabID` is that value widened to u32, `interop.go`), so u16
is one byte of headroom inside the space v1 already reserved. The field
sits inside the MAC'd region by construction — the domain is still
`bytes[0..18+plen)`, no crypto moves — and every v1 record carries 0
there by construction, so a v2 reader accepts the v1 wire unchanged.

Semantics by tag (all tags not listed MUST send 0):

| Tag | `sender_id` |
|-----|-------------|
| `NOTIFY_OUT` | the window id of the tab whose kind-12 toast this is; 0 for seat-originated toasts (host drops, agent milestones) |
| `NOTIFY_FOCUS` | the window id the seat should focus — the echo |

The correlation *is* the field: a `NOTIFY_OUT` carries the sender the
seat already knew (`notifyPush`'s `tabID`), the runner binds it to the
banner it posts, and a click hands it back in `NOTIFY_FOCUS`. No
seat-side seq→tab table, no new identity type — the same id
`focusHosted` already takes. A record that is nothing but a correlation
echo needs no payload: `NOTIFY_FOCUS` is plen 0, the header carries the
whole request.

Cross-version honesty, stated not waved: a v1 decoder refuses a v2
record bearing nonzero `sender_id` as `bad_record`. Runner and seat are
built and shipped from one tree and one image, so the field is only
ever read by a peer that knows it; where that ever fails to hold, the
v1 refusal is the *correct* answer — the feature is absent, not
misread.

### V2-D2. The v2 tag map — complete table, supersedes D2's

| Tag | Name | Stem | Dir | Producer → Consumer | Payload | `sender_id` |
|-----|------|------|-----|---------------------|---------|-------------|
| 0 | `ARMED` | `ARMED` | h→g | runner → seat | `[lane_mask u8]` | 0 |
| 1 | `CLIP_OUT` | `CLIPOUT` | g→h | seat → runner | clipboard bytes (0 = clear) | 0 |
| 2 | `CLIP_IN` | `CLIPIN` | h→g | runner → seat | UTF-8 ≤ 512, TRUNCATED on cut | 0 |
| 3 | `NOTIFY_OUT` | `NOTIFY` | g→h | seat → runner | toast text ≤ 24 | the toast's sender tab id |
| 4 | `DROP` | `DROP` | h→g | runner → seat | `[name_len u8][name][size u64le]` | 0 |
| 5 | `OUTBOX` | `OUTBOX` | g→h | seat → runner | `[name_len u8][name][size u64le]` — the DROP shape, reversed | 0 |
| 6 | `NOTIFY_FOCUS` | `NFOCUS` | h→g | runner → seat | empty (plen MUST be 0 — else `bad_record`) | tab to focus |

Tags 0–4 are **observed** in `vhi1.go`/`HostInt.swift` as shipped;
tags 5–6 and `sender_id` are **reserved by this amendment** — no codec
carries them yet. Lane mapping: `OUTBOX` rides a new ARMED mask bit,
`lane_outbox = 1<<3` (lane name `outbox`); `NOTIFY_FOCUS` rides
`lane_notify` (bit 2) — both directions of a lane share one bit, the
LaneBit rule. `MaskNames` renders e.g. `clip,drop,notify,outbox`. Tag
6 joins the seat's consumed set beside `CLIP_IN`/`DROP`; tag 5 is a
seat emit tag like 1 and 3, so a seat-side `OUTBOX` file is its own
unconsumed emission and a runner-side `NOTIFY_FOCUS` file likewise.

### V2-D3. Notify click-through — `TagNotifyFocus` (M127c)

The loop: the seat pushes a toast with sender T → the `NOTIFY_OUT`
carries `sender_id=T` → the runner posts the banner with T recorded
against it (the `UNNotificationRequest` already carries the
`vhi1-notify-<epoch>-<seq>` identifier; the sender rides its userInfo)
→ the user clicks → `didReceive` — or the `notify-click` bus verb, the
class-B equivalent of the click — fires the click path → the runner
raises its own window (the click's first duty is always "bring the VM
forward") and, when T≠0, emits `NOTIFY_FOCUS{sender_id=T}` → the seat
verifies epoch/MAC/seq and the `lane_notify` mask bit like any inbound
record and runs `focusHosted(T)` — the same seam alt-tab and toast
clicks take, so the app receives the real WIN_FOCUS.

Rules worth pinning:

- **sender 0 emits no record.** A seat-originated toast (a host drop,
  an agent milestone) has no tab to focus; the runner still raises its
  window and stops — emitting a record could only draw `gone`.
- **A dead sender is `gone`,** not silent: the tab may close between
  banner and click (the seat's own strip solves the same race by
  clearing toasts at tab close; banners outlive that). `focusHosted`
  returning false is the named refusal.
- **Consume is bounded like every inbound tag** — ≤ 1 per seat tick —
  and subject to the same seq/epoch books; `NFOCUS-<seq:8hex>` is the
  filename.
- **The click path is class-B reachable**: the `notify-click` bus verb
  dispatches the identical code path on the most recent consumed
  NOTIFY_OUT — the bare runner keeps the same bounded posted-record
  list the delegate consults, so the leg works with no bundle and no
  banner (`host-notify: click-focus id=<tab> seq=<n>` is the runner
  receipt; the seat's is `gotabwm: hostint notify-focus seq=<n>
  id=<tab>` plus the ordinary `tab focus`/`host focus` lines).

### V2-D4. The drop-toast action policy (M127b)

v1's drop toast had sender 0 and nothing to do on click. v2 gives the
toast model an orthogonal notion — an **action**, distinct from the
sender-focus rule — and exactly one action kind:

- **`open-drop`**, bound at push time to the sanitized name the
  *verified* DROP record carried. The binding is stored on the toast
  and its center entry, so the action can never be retargeted at a
  file the record did not name — the same provenance rule the plant
  defence states: the record attests, the file is just bytes.

A click on an actionable toast dismisses it (the existing marker) and
runs the action; Enter on the notify-center row runs the same dispatch
(the row and the toast share one binding). A DND-held notice keeps its
action in the center — held is a display posture, not a consent
revocation.

`open-drop` dispatches `/host/INBOX/<name>` through `mime.Open` — the
M81b decision GOFILES `open` and GOSH `open` already share — and execs
the default handler the `opens=` registry names (GOVIEW/GOEDIT/GOSOUND
by sniff), the path as argv[1]. `OpenNoHandler` falls back to launching
GOFILES on `/host/INBOX/` — the reveal gesture is "the file manager is
open at your drop," always available. `OpenUnreadable` — the file
vanished or the channel failed — is `gone`. The seat never execs the
payload itself and never resolves outside INBOX: the name was
sanitized at ingest and is re-validated at dispatch (`name_rejected`
is the belt for a seat-internal bug; a verified name cannot legitimately
fail it).

Non-goals, pinned: no second action kind (the GOFILES fallback *is*
the reveal), no per-toast consent prompt (arming the lane was the
consent; the strip is the visibility M97g asks for and the user picks
what to open), no action on non-drop toasts — RPC toasts keep
sender-focus, seat notices keep dismiss-only; action and sender are
mutually exclusive in v2.

Markers: `gotabwm: hostint drop-open name=<name> app=<bin>` on
dispatch (the M127b leg); refusals ride the shared
`refuse lane=drop reason=<code>` shape.

### V2-D5. `TagOutbox` — the `/host/OUTBOX/` export lane (M127d)

The reverse drop. INBOX is host payload + signed notice; OUTBOX is
guest payload + signed notice — but a guest app cannot sign (the
`host-int` row is bound to the seat's image), so intent and provenance
are split:

- `/host/OUTBOX/<name>` — the payload, app-written (GOSH `export`,
  GOFILES "Export to Host"), temp+rename per the share's atomicity
  rule, name held to the D4 rule (≤ 48 bytes, `[A-Za-z0-9._-]`,
  leading-alnum). The runner creates `OUTBOX/` at arm — the SDK has no
  mkdir, the same posture `AGENT/` and `INBOX/` already take.
- `/host/OUTBOX/REQ-<8hex>` — the intent marker: the payload basename
  verbatim as its whole content (≤ 48 bytes, the same charset). The
  app-chosen hex suffix needs only per-app uniqueness — the content is
  authoritative and a collision just coalesces two requests for the
  same intent. The marker form exists because a bare basename can't
  grow a suffix inside the 64-byte path bound — "/host/OUTBOX/" is 13
  bytes, so the name field has 51, and 48+4 already exceeds it — and
  because it mirrors the `RCPT-<hex>` grammar the audit lane made
  familiar.

The seat polls `OUTBOX/` once per tick beside the lane dir (the
`agentwatch` AUDIT scan is the precedent) **only while the adopted mask
carries `lane_outbox`** — the D7 posture. For each well-formed REQ
whose payload exists, it emits one signed `OUTBOX` record — the DROP
payload shape, `[name_len u8][name][size u64le]` — and deletes the REQ;
≤ 1 REQ consumed per tick, the emit-side bound every g→h lane already
holds, plus the shared `MaxOutstanding` backpressure on the tag. A REQ
naming a missing payload is `gone`, a bad name `name_rejected`, a
non-regular payload `unsupported_kind`, over the file cap
`payload_too_large` — refused and deleted, the payload left in place.

The REQ is unsigned by design — it is intent, not provenance. What the
host trusts is the signed record; what the seat will sign is only a
REQ-marked payload. An unmarked file sitting in OUTBOX/ is the mirror
of an unannounced INBOX plant: inert, never attributed, never exported
— and a *host-side* plant cannot bounce either, because nothing
produces a REQ for it.

Host side, per verified `OUTBOX` record (epoch/MAC/seq, `lane_outbox`
in the adopted mask, the shared per-tag books, ≤ 1 consumed per 250 ms
tick like the notify drain):

- the named payload must exist (`gone`), be regular
  (`unsupported_kind`), and fit ≤ 64 MiB at move time
  (`payload_too_large`) — the D4 file cap carried symmetric; the
  record's announced size is the seat's attest-time view for markers,
  the live fstat rules the move;
- the per-epoch export count is capped at **64** — a verified record
  past the cap is consumed and refused `quota_exceeded` (a hostile or
  buggy guest can mint valid records at the emit bound forever; the
  cap is the honest wall);
- on success the runner moves `OUTBOX/<name>` to `--host-outbox-dir`
  (default `~/Downloads`; the flag is the gate redirect — a class-B
  run never touches a real Downloads), collision-suffixed `-2`…`-9`
  then `name_rejected`, and consumes the record. Marker:
  `host-outbox: file seq=<n> name=<name> size=<n>`;
- a bundled session additionally posts a banner whose click (or the
  `reveal-export` bus verb) reveals the landing in Finder — Reveal is a
  bus action like every other UI gesture; bare runners take only the
  move.

Flags: `--host-outbox` arms the lane as a `--cvc-file` modifier (the
D6 shape; `just session` adds it to the default lane set); no display
precondition — exports are not a window gesture.
`--host-outbox-dir <path>` is the destination modifier. `lane-outbox`
joins the Integration toggles.

### V2-D6. v2 vocabulary additions

Refusals — the same table, two names:

| Reason | Meaning |
|--------|---------|
| `gone` | the target a click/focus/export names no longer exists — a dead tab for `NOTIFY_FOCUS`, a vanished INBOX file for `open-drop`, a REQ whose payload is absent |
| `quota_exceeded` | the per-epoch OUTBOX export count cap (64) |

Bus verbs — `HostCommand` cases declared once (a case with no
registered handler reports `unavailable`, the enum's own convention):
`notify-click`, `reveal-export`, `lane-outbox`, `lane-agent`.

Markers — the payload-free shapes above plus:

```
host-outbox: file seq=<n> name=<name> size=<n>
host-notify: click-focus id=<tab> seq=<n>
gotabwm: hostint drop-open name=<name> app=<bin>
gotabwm: hostint notify-focus seq=<n> id=<tab>
gotabwm: hostint outbox seq=<n> name=<name> size=<n>
```

M127e needs nothing new on this wire: the companion reads the existing
`/host/AGENT/AUDIT/RCPT-*` receipts and verifies them under the
`agent-hmac` row the host already reads as a file — the M108
double-reader pattern, and the seat's M109e watch is the same consumer
one side over. `lane-agent` is a host-side choke, not a message to the
guest: pause refuses or closes the runner's agent-channel endpoint (the
`--net-tcp-connect-stream` plumbing, when one is armed) and marks the
pill; `unavailable` when no agent channel is armed. No tag ever
carries a host→agent imperative — AGENTD stays guest-facing.

### V2-D7. Card split, restated with file-level Touches

The filed cards' Touches overlap on three seams (the codec files, the
`HostCommand` enum, `main.swift`) — the same problem D8 solved. The
v2 *vocabulary* — the codec bump on both ends, the bus cases, and the
seat hook vars — is a **shared seam that lands once**: default owner
**M127c** (the wire change is its feature); if another card claims and
lands first it carries the seam instead and the rest rebase — the rule
D8 gave M108b, stated not discovered. The seam is deliberately
behavior-neutral: it relaxes the 6..7 decode rule, adds the constants
and hook vars with v1-preserving defaults, and changes no lane
semantics — so it is safe under any of the four cards.

**Seam group:** `user/go/hostint/vhi1.go`, `engine.go`,
`hostint_test.go`; `host/vm-runner/Sources/VMRunner/HostInt.swift`;
`host/vm-runner/Sources/VMAppKit/HostCommand.swift` (the four v2 verb
cases, `unavailable` until wired); `user/go/gotabwm/hostint.go` (the
`TagNotifyFocus` consume route through a `hostfocusConsume` hook var,
and an `outboxTickFn` hook in the per-tick drive — both defaulting to
v1 behavior so the dependents bind them from their own files).
`HostIntCommands.swift` is deliberately *not* shared: v2 lane verbs
register on the bus from the lane's own file (`HostRecorder`'s
self-registration is the precedent), so no two cards need it.

| Card | Owns exclusively | Depends on |
|------|------------------|------------|
| M127b | `gotabwm/hostdrop.go`, `notify.go`, `notify_center.go`, `dropopen.go` (new — the `open-drop` dispatch), their `*_test.go`, legs in `live-host-drop.spec` | the action rides `notify.go`'s click path only — no wire change; fully parallel |
| M127c | the **seam group** + `gotabwm/hostnotify.go`, `gotabwm/hostfocus.go` (new), `HostNotify.swift`, their tests, legs in `live-host-notify.spec` | — (carries the seam) |
| M127d | `gotabwm/hostoutbox.go` (new — binds `outboxTickFn`), `user/go/gosh/*` `export`, `user/go/files/*` export UI, `HostOutbox.swift` (new — registers `lane-outbox`/`reveal-export` itself), `main.swift` (flags + arm + consume), `live-host-outbox.spec` (new) | the seam's constants/hook — the seam card first |
| M127e | `Sources/VMAppKit/*` companion (status pill + inspector sub-pane) + a new `Sources/VMRunner/HostAgent*.swift` audit reader; `lane-agent` registers from its own file | the seam's `lane-agent` case — the seam card first |
| M127f | `tools/gate/specs/live-hostint.spec`, `docs/status.md` | all of the above |

The NOTIFY_OUT sender plumbing needs no shared file at all:
`hostnotifyQueue` runs inside `notifyPush` immediately after the queue
append, so the sender it stamps is the newest queued toast's `tabID` —
c reads it there and `notify.go` stays entirely b's. (If a reviewer
prefers the explicit argument, the one-line call-site change rides the
seam instead — stated, not discovered mid-flight.)

### v2 consequences and honesty notes

- The envelope, the MAC, the handshake, the names and the silence rules
  are untouched; what moved is two reserved bytes and two tags. Tags
  5–6, the `lane_outbox` bit, the two refusal names, the four verbs,
  and the REQ grammar are **reserved by this amendment — none are
  observed in code yet**; tags 0–4 and the v1 vocabulary are observed
  in `vhi1.go`/`HostInt.swift` as shipped.
- Byte-silence holds in v2: no flag → no `OUTBOX/`, no REQ watch, no
  `NOTIFY_FOCUS`, and a seat-originated toast behaves exactly as v1.
- The REQ/OUTBOX shape inherits the INBOX residual, mirrored: a guest
  app can write REQ-marked files, but the seat's signature is what the
  host acts on, the per-tick/per-epoch caps bound the rate, and the
  payload contents are never trusted to be what their name claims
  (sniff, not extension, picks the handler on the way *in*; macOS's
  own quarantine is the story on the way *out* — stated, not weakened).
- `lane-agent` can freeze only what the host owns — its own endpoint.
  An armed, connected agent keeps its guest-side session; the choke is
  the pipe, and the audit receipts (which keep landing regardless)
  record that the freeze happened. A guest-directed imperative stays a
  non-goal.
