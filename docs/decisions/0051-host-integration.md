# ADR 0051: Host-integration wire — three consented lanes over signed share files

- Date: 2026-10-15
- Status: **Proposed** — awaiting owner review. No code lands here; this
  ADR is the card (#2324) and, if approved, the split in D8 is the arc.
- Card: **#2324** (M108, program index #2305) — card 1 of 5. The wire
  shape and consent model that M108b/c/d implement and M108e accepts.
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
Toast click does nothing — dismiss only (there is no sender tab to
focus; a click-to-open seam is a later card, not this design).
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
`auth_denied`. v1 is one-way FYI, stated plainly: **a banner click
lands nowhere** — no delegate action, no VM focus, no deep link.

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

- Click-through semantics for drop toasts and banners (focus a tab,
  open INBOX in GOFILES, focus the VM window) — deliberately FYI-only
  in v1; the seam exists when a card wants it.
- Whether interactive sessions want a seat-side arm toggle (a chrome
  chord to suspend host lanes mid-session). The flags are boot-time;
  a runtime toggle is a consent upgrade, not a gap.
- Clipboard richness beyond UTF-8 text (the index's explicit non-goal)
  and a `CLIP_OUT` of non-text guest bytes — refused by name today.
- The `no_credential` boot policy could tighten to a fatal runner
  error if owners prefer arm-time failure to a dead lane; D6 picked
  the agentd-style per-lane refusal because the lanes are independent
  and the boot is not.
