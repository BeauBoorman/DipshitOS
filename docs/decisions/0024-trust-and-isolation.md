# ADR 0024: Trust and isolation baseline — principals, permissions, and authenticated remote

Status: **ACCEPTED** · Date: 2026-09-11 · Milestone: **M50** (trust &
isolation) · Umbrella **#1133** · Design card **#1134** (TS0) ·
Implementation cards **#1135** (TS1), **#1136** (TS2), **#1137** (TS3),
**#1138** (TS4), **#1139** (TS5)

> Commits the shape of the trust baseline before any TS card is written:
> where a process principal lives, what file modes mean and where they are
> enforced, which syscalls a privilege gates, how the M46 remote shared
> secret is replaced by a challenge-response built on M47 primitives, and
> what "secret" means in the settings store. Extends, and does not revise,
> ADR 0007 (syscall ABI), ADR 0010 (userland file ABI), ADR 0016
> (shared-anon owner checks), ADR 0020 Amendment B (net front-end), ADR
> 0022 (M46 remote), and ADR 0023 (M47 crypto). No code lands here; the
> binding build order was `trust-scoping.md` — condensed into
> `docs/archive/era-m0-m51.md` (verbatim at its pinned SHA).

## Context

Observed on `origin/main` at the M46/M47 merges (`f74dc3d` / `f0795dd`),
2026-09-11:

1. **There is no principal anywhere.** `Process` (`kernel/src/process.zig:144-171`)
   carries no uid/gid/credential field; a pid is the registry index
   (`process.zig:173`), and the scheduler deliberately has no parent/child
   relation (`scheduler.zig:50`). No kernel source defines `uid`, `gid`,
   `principal`, or `credential`.
2. **Files have no owner and no mode.** `FileHandle` (`kernel/src/file_table.zig:80-102`)
   stores flags, cursor, partition, and a path, but no ownership metadata;
   the only access check is the per-handle read/write flag (`file_table.zig:424`,
   `:483`). The 40-byte `DirEntry` reserves 3 bytes for future metadata
   (ADR 0010 D3, `file_table.zig:55-60`).
3. **The host share is a dumb, path-sandboxed data plane.** The M34 wire
   (`kernel/src/virtio_file.zig`, `host/vm-runner/Sources/VFWire/VFWire.swift`)
   carries no caller identity and no metadata; the host's only policy is
   `resolveSubpath` (`VFWire.swift:198-220`). The host already treats the
   guest as untrusted (`host-file-channel-scoping.md` lines 396–398 —
   condensed into `docs/archive/era-m0-m51.md`, verbatim at its pinned SHA), so
   ownership metadata cannot live host-side without inverting that posture.
4. **The monitor and kernel consumers bypass `file_table`.** `cmd_vf` calls
   `virtio_file` directly (`kernel/src/monitor.zig:1308-1330`); exec loads
   binaries (`kernel/src/exec.zig:289-294`), settings load/save
   (`kernel/src/settings.zig:428-466`), shell history/env
   (`kernel/src/shell.zig:1509/1516`), tombstones (`kernel/src/tombstone.zig:207-247`),
   and redirects (`kernel/src/redirect.zig:88`) do the same. An ownership
   check that lives only in `file_table` governs EL0 syscalls and nothing
   else.
5. **Remote auth is an in-band shared secret.** `Terminal` stores
   `net_secret` and a pre-auth line buffer (`kernel/src/terminal.zig:391-402`);
   `netAuthConsume` compares the first line byte-for-byte in the kernel net
   pump (`terminal.zig:770-811`); slot 67 selector 3 carries the secret from
   userland (`kernel/src/syscall.zig:1695-1777`). The Stage-0 host bridge
   compares its client's first line with plain Swift `==`
   (`host/vm-runner/Sources/VMRunner/main.swift:2636`). ADR 0022 D1/D6
   documents the posture: plaintext, no freshness, barrier-grade only.
6. **M47 primitives exist and are userland-only.** `user/src/lib/crypto/`
   ships streaming SHA-256/512 + HMAC (`crypto/hmac.zig:90`),
   ChaCha20-Poly1305, X25519, Ed25519 (`crypto/ed25519.zig:241`), and
   constant-time helpers (`crypto/ct.zig:20-54`). ADR 0023 D2 forbids the
   kernel importing them (Zig module-path + direct `zig test` gates); D7
   keeps randomness kernel-side in `csprng` (`kernel/src/csprng.zig:171`).
   No EL0 entropy syscall exists (ADR 0007 slots 0–67; `slot_count = 128`,
   `implemented_count = 68`, `syscall.zig:96/105`).
7. **The TCP stack is single-connection and tightly bounded.**
   `payload_max = 64`, `segment_max = 84`, no reassembly, RX payloads over
   64 bytes dropped (`kernel/src/tcp.zig:59-63`, `:630-633`). A 64-byte
   Ed25519 signature as hex is 128 characters — one handshake line does not
   fit today's bound.
8. **Existing kernel-enforced ownership is per-resource, not per-process.**
   Windows (`syscall.zig:1721`), the single TCP connection (`syscall.zig:1950`),
   the WM seat (`syscall.zig:2620-2635`), and shared regions
   (`kernel/src/shared_region.zig:72-230`, ADR 0016 D2) all check a
   caller pid against an owner pid. That pattern is the in-tree precedent
   this ADR generalizes without pretending pids are principals.

The trust problem M50 solves: the system now sits on a network behind a
remote door and owns a shared host folder, yet it cannot say *who* is asking
or *what they may touch*. "Single-user" is not "no trust boundary" — the
boundaries are network↔guest and host-share↔guest, and naming them makes
them testable.

## Decision

### D1. Two principals today: `uid_system` (0) and `uid_user` (1000)
The model is a single `uid` per process. `uid_system = 0` is the kernel's
authority (the EL1h monitor and kernel-internal consumers act as it);
`uid_user = 1000` is every EL0 process spawned today. There are no groups,
no passwords, no login, and no on-disk user database: single-user still
means one principal, but the principal is explicit and enforceable, and a
second uid can be added later without an ABI change. `uid_system` is not
assigned by any user-reachable path (D5).

**card #3029 amendment (2026-10-22, card #3029 — a third principal).**
`uid_agent = 2000` joins the pair: the kernel assigns it at exec to
processes whose recorded image name is `AGENTD.ELF` (the name binding
ADR 0054 grants already use), and children of a `uid_agent` process
inherit it — still spawn-time only, still no syscall setter and no EL0
naming path, so D5's "the only way to gain privilege is for the kernel
itself to create the process" now reads: the kernel *assigns* the agent
principal at exec; it is never requested. On `/host` the agent reads
user files through the *other* triplet — `0600` and the secret class
stay closed — and owns only its `AGENT/` sandbox and audit roots
through kernel-minted rows. The D5/D10 kill posture gains one
asymmetry: `uid_user` may signal `uid_agent`, never the reverse;
`CAP_PROC_ADMIN` is unchanged. The decision is the card #3029 amendment to
ADR 0052; per-agent uids, VLFS ownership and multi-user stay deferred.

### D2. Identity lives on the `Process` record; it is never persisted
`Process` gains `uid: u32` and `caps: u32` (kernel BSS, module-private like
every other field). The kernel assigns them at `process.create`; `exec`
preserves them (no setuid semantics); no syscall can change them. The
principal is not stored on disk and there is no `/etc/passwd` analogue: a
future `USERS.TXT` is explicitly out of scope. The read-only surface is a
new syscall slot (D10) and shell builtins `whoami`/`id`; the `sys_procs`
snapshot row (`process.zig:526-543`, 40 bytes) stays byte-frozen — identity
is additive, not a format change.

### D3. File ownership and mode bits are guest-side metadata with a documented default policy
Ownership is `{ uid: u32, mode: u16, secret: bool }` keyed by the
normalized `(Partition, path)` pair that `parse_path` already produces
(`file_table.zig:181-231`). Metadata lives in kernel BSS in a bounded table
(cap: 64 entries; full ⇒ `ENOSPC` on the creating operation, never
silent eviction) and persists as an ordinary share file `OWNERS.TXT`
(`#v1`, one `path<TAB>mode<TAB>uid<TAB>flags` line per entry, bounded by the
existing `max_path_len = 64`). The wire is unchanged: the host remains a
dumb data plane, and a malformed or unknown-schema line **denies that path**
(fail closed) rather than being ignored.

`mode` is a 9-bit `rwxrwxrwx` value; group bits are reserved and must be
zero (single-user means owner/other is the whole story). Enforcement uses
owner bits when `caller.uid == entry.uid`, other bits otherwise. **Default
policy when no entry exists:** regular file `0644`, directory `0755`, owner
`uid_user`, `secret = false`; `.usb` is read-only `0444`; `.tty` keeps
device semantics and is not governed by modes. A path whose stored mode is
malformed or unsupported is denied, not defaulted.

The single-user honesty clause: with every EL0 process at `uid_user` and
every default file owned by `uid_user`, owner checks pass trivially today.
What has teeth today is (a) the `secret` class (D8), which the file ABI
denies even to the owner, (b) `uid_system`-owned paths, which the monitor or
the host can create, and (c) the substrate TS4/TS5 need. The ADR claims no
more than that.

### D4. Enforcement is one policy function, called at two seams
A new kernel module (working name `kernel/src/trust.zig`) owns the metadata
table, persistence, and a single pure predicate:

```
check(actor, partition, path, want) -> allow | eacces | enoent
// actor = { uid, caps, is_kernel, pid, name }, want = read | write | create | delete | list | admin
```

- **Syscall seam:** every `file_table` entry point (`open` `:279`, `read`
  `:420`, `write` `:479`, `delete` `:584`, `rename` `:601`, `truncate`
  `:621`, `dir_list` `:544`) calls `trust.check` after `parse_path` and
  before touching `virtio_file`. `EACCES` is returned, never a silent
  allow.
- **Direct-consumer seam:** the monitor's `vf` verbs and the kernel
  consumers listed in Context 4 must declare an explicit actor. The
  default is `uid_system` with `CAP_FS_ANY`; `cmd_vf` becomes an explicit
  `kernel_actor()` call, and each existing consumer is audited in the TS2
  card. Secret-class paths (D8) are denied at this seam too, for every
  actor, because the file ABI must never be a way to read a secret.
  **TS2 implementation note:** every content read/write/delete consumer
  (`vf cat`/`open`/`write`/`truncate`/`rm`/`mv`/`clone`/`ls`, monitor
  `cat`/`stat`/`write`/`mktemp`/`sym`/`sh <script>`, exec, settings,
  kernel-shell history/env/`.virelairc`/`WINDOWS.SAV`, tombstones,
  redirects) is gated with `kernel_actor()` + `check`. Directory-name
  listings through `virtio_file.list` are intentionally **not** gated:
  D8 explicitly allows the monitor to print secret *names*, and a listing
  is not a content read (asking `ls`/`stat` on a secret path itself is
  denied, since `list`/`read` are denied for it).
- **Rename/delete of a secret-class path is denied through the file ABI
  entirely** (otherwise renaming would strip the class). Only a host-side
  move of the share file, outside the guest's view, can relocate it.
- The metadata key follows `parse_path`'s normalization; create/delete/
  rename update entries in the same transaction as the operation. **TS2
  resolution (2026-09-11):** keys are compared **case-insensitively**
  (`std.ascii.eqlIgnoreCase`) while `OWNERS.TXT` preserves the authored
  spelling, so a case-varied request cannot bypass an explicit entry; on a
  case-sensitive host the rule may over-apply to a distinct same-lowercase
  file, which is fail-closed, never a bypass. The group triplet is reserved
  and normalized to zero. See `kernel/src/trust.zig`.

**M97g amendment (2026-10-15, #2085 — diagnostic-label binding).** Before
this change `APPLOG/<label>.LOG` and `CRASH/<label>.{TXT,STK}` were
ordinary `uid_user` files: any process could append to, read, or receipt
another app's diagnostic records, and a forged receipt could carry another
app's last log lines. `check` now applies a label overlay for
non-privileged actors (`is_kernel`/`CAP_FS_ANY` unchanged): a direct child
of `APPLOG/` or `CRASH/` on the host share is allowed only when the file's
stem binds to the caller's kernel-recorded image name (a `.ELF` suffix is
normalized on both sides — `GSCHK` and `GSCHK.ELF` are the same label), or
to a registry row the caller spawned. The spawned rule is what keeps the
supervisor contract honest: `init`, `gosh` and `gsproc`-style managers
write a dead child's receipt, and the child's `spawner` pid (recorded at
`exec` bind from task provenance) survives on the exited descriptor. The
chosen read policy is the same binding — `ReadLog` of another app's ring
is EACCES unless the caller spawned it or is privileged; `APPLOG`/`CRASH`
directory listing stays open (names are enumerable; contents are bound).
Supervise now labels receipts by the spawned binary's stem — service names
bind to nothing the kernel can verify — so `CRASH/z-pre.TXT` becomes
`CRASH/INITPRE.BIN.TXT` and the receipt's `app=` names the real image.
Residual, recorded honestly: an EL0 process can still `exec` a staged
image named `VICTIM.ELF` and thereby own the `VICTIM` label (image-name
squatting — closing it needs pinned/signed images, out of scope), and a
recycled pid slot inherits a stale exited row's spawner number (bounded
registry, no generations). The overlay denies, never widens: entry `deny`
and the secret class still win first.

### D5. Process privilege is `uid_system` plus two capabilities; there is no elevation
`caps` is a small bitmask, spawn-time only:

| Capability | Meaning |
|---|---|
| `CAP_FS_ANY` | bypass D3/D4 checks (kernel/internal; `uid_system` has it implicitly) |
| `CAP_PROC_ADMIN` | act on processes of another principal (kill, future admin) |

Kernel-internal actors (including the EL1h monitor) act as `uid_system` +
both caps; every EL0-initiated spawn defaults to `uid_user` + no caps. The
EL1h monitor may assign a principal explicitly when it spawns a process —
an administrative surface on the raw console, used by the TS2/TS3 gates to
create a second principal; EL0 has no path to request one. `exec` preserves
uid and caps; there is **no syscall to raise either** and no setuid bit —
the only way to gain privilege is for the kernel itself to create the
process. Listening on the net front-end is deliberately **not** a
capability: the remote door is controlled by authentication (D6), not by
who opened it. The gated syscall set starts explicit and small (D10) and
grows only by amendment.

**TS3 implementation notes** (2026-09-11, #1137): (a) the D10 gate is the
explicit, bounded `capability_gates` table in `kernel/src/syscall.zig` —
one row today (`sys_kill` → `CAP_PROC_ADMIN`) — queried through
`gated(number) ?cap` by the slot-29 handler; a future gate is one row plus
its handler's explicit query, and the table's small size is what makes the
set auditable. (b) `sys_kill`'s principal check runs BEFORE the
target-state checks, so a cross-principal kill by a caller without the cap
is always `EACCES`, never a state-dependent `EINVAL` (no foreign-state
leak). (c) The EL1h monitor is never a target: it has no process
descriptor, so no pid names it, and `scheduler.request_kill` independently
refuses the kernel-owned shell/idle slots. (d) The monitor's admin spawn
is the `exec -u<uid>` flag (`-u0` = `uid_system` + `kernel_caps`;
`-u1000` = `uid_user` + no caps; any other uid refused); it is the only
path that can name a principal, EL0 `sys_exec` has no principal argument
and preserves the caller's. (e) There is no elevation syscall and no
setter on the principal surface — class-A audits every implemented slot
name and the gate table so a privilege setter cannot land unnoticed.

**M113a note (2026-10-16, #2417 — ADR 0054):** the grant table holds this
clause, it does not relax it. A measured-exec grant applies a *word mask*
(a narrowing of which ADR 0007 slot groups a process may call), never a
capability bit: a granted process remains `uid_user` + no caps, `exec`
still preserves uid and caps, and there is still no syscall that raises
either. The table's sources are kernel-owned and EL0-unwritable except
through the seat-gated admin slot (D10 note), so "the only way to gain
privilege is for the kernel itself to create the process" stays exactly
true — grants only *remove* power relative to the baseline.

### D6. Remote auth: a fresh challenge, verified in userland by M47, gated by the kernel pump
The Stage-1 shared secret is **replaced** (not layered) by a
challenge-response handshake over the same M46 seam:

1. On TCP accept, the kernel net pump mints a fresh 32-byte challenge from
   `csprng.random_bytes` (`kernel/src/csprng.zig:171`) and sends one line:
   `VIRELAIOS-AUTH/1 <scheme> <hex-challenge>\n`, `scheme ∈ {hmac-sha256, ed25519}`.
2. The client answers with one line: `hex(MAC)` (32 bytes, HMAC-SHA256) or
   `hex(signature)` (64 bytes, Ed25519). The line is buffered in the
   terminal's bounded auth line; it is never queued to the shell.
3. The attached process (SH/TERM through `user/src/lib/netauth.zig`) reads
   the challenge and the reply through a new syscall (D10), verifies with
   the M47 library — `hmacSha256` + `ct.ctEq`, or `ed25519.verify` — and
   votes accept/reject. Keys/public keys come from the TS5 store, never
   from argv.
4. The kernel gates delivery on the verdict: accept ⇒ the session is
   authenticated exactly as M46's `net_authed` is today; reject, malformed
   line, or no verdict within a 10 s auth deadline ⇒ `auth failed\n` +
   `tcp.reset()` + detach. Pre-auth bytes never reach the terminal input
   queue (the M46 pump property is preserved).

The HMAC message is domain-separated:
`"VIRELAIOS-AUTH/1 hmac-sha256" || 0x00 || challenge[32]`. The fresh server
challenge makes a captured handshake unreplayable.

**Why the verifier is userland:** the key material and all crypto stay in
the M47 library (ADR 0023 D1/D2), Ed25519 needs no kernel field arithmetic,
and the kernel keeps doing what it already does well — move bounded bytes
and refuse to deliver them before the door opens. The process already sees
every post-auth byte, so delegating the verdict does not widen its trust.
The kernel never holds the key; `sys_secret_get` returns it to the owner
process (D8) and the auth reply line is redacted from strace (D8).

**Bounds change (TS4 owns it):** the handshake needs one line up to 129
bytes; `tcp.payload_max` rises 64 → 192 (`segment_max` 84 → 212), the
shared-secret fields (`terminal.zig:396-400`) are deleted, and
`net_auth_line_max = 160` replaces `net_challenge_max`. The change is
fixed-size and reassembly-free, so the single-connection TCP contract is
unchanged in kind.

**Default posture:** if a credential exists in the TS5 store, the shell
uses it and auth is mandatory. With no credential, `net <port>` **refuses
to listen** unless the process explicitly asks for the documented insecure
mode (`net <port> open`), which reproduces M46's accept-immediately
behavior for trusted-network use and existing gates. Fail closed by
default; the M46 `live-remote` gate is re-pointed to `open` in TS4.

**Ed25519** is a first-class scheme in the framing and class-A tests (a
pinned key signs the pinned challenge); its class-B client story needs a
host Ed25519 helper and is an explicit TS4 stretch. The HMAC scheme is the
TS4 acceptance primitive.

**TS4 implementation notes** (2026-09-11, issue #1138): (a) the store key
names are `net-hmac` (the HMAC key used byte-for-byte as stored) and
`net-ed25519` (the 64-hex public key); a store with neither refuses to
listen without the explicit `open` argument. (b) The Ed25519 signed message
is `"VIRELAIOS-AUTH/1 ed25519" || 0x00 || challenge[32]`, symmetric with the
HMAC domain separation. (c) A reply line is length- and hex-validated in
the kernel (64 hex for hmac-sha256, 128 for ed25519) before the process ever
sees it; a malformed line is a failed connection. (d) Accepted pipelined
post-auth bytes are held in a bounded buffer and delivered only after the
accept verdict. (e) The Stage-0 bridge computes its HMAC with CryptoKit
(verified building and running on this host); the recorded Swift-HMAC
fallback was not needed.

### D7. Stage 0 host bridge gets the same handshake, host-side; no TLS anywhere
`--console-tcp [host:]port[:secret]` becomes HMAC-SHA256 challenge-response:
the bridge sends the same `VIRELAIOS-AUTH/1` line and requires
`hex(HMAC-SHA256(secret, msg))`. The host computes the MAC with CryptoKit
(a macOS system framework; the runner imports none today, observed) and the
gate client with Python's stdlib `hmac`, so no new gate dependency appears.
No secret is configured ⇒ the bridge is byte-identical to today (loopback
default). This is a host convenience path; the guest does not authenticate
the bridge cryptographically, and the ADR says so.

**No TLS, by decision.** Authentication without a session cipher means the
post-auth stream is still plaintext: confidentiality, integrity, and
session-content replay protection are not provided; a live relay/MITM can
proxy the handshake. ChaCha20-Poly1305 exists in M47 and is reserved for a
later session-encryption card; TLS remains out of scope.

### D8. Secrets are a bounded store the file ABI cannot read
`SECRETS.TXT` on the host share is the secret-class counterpart of
`SETTINGS.TXT`: the same bounded key/value engine (`max_key_len = 32`,
`max_val_len = 64`, `#v1` header — 64 chars hold a 32-byte key or Ed25519
seed in hex exactly), with `max_secret_entries = 8` and a distinct file.
TS2 flags the path `secret = true`, mode `0600`; from then on **every**
`file_table`/monitor `vf` read of it is denied (D4). The only in-guest
reader is `sys_secret_get` (D10), which returns the calling principal's
entries into caller memory. Provisioning is host-side (the human edits the
share file); `sys_secret_set` is deferred until there is a non-echoing
provisioning path, because the serial console echoes what is typed.

**Never-logged contract** (TS5 acceptance): secret values must not appear
in the serial transcript, shell history (`HISTORY.TXT`), env
(`ENV.TXT`), monitor `settings`/`vf` output, `sys_procs` snapshots, crash
tombstones, or syscall strace (`syscall.zig:525-537`). The monitor may
print secret *names* only. `sys_secret_get` and `sys_tty_net_auth` are
excluded from argument/return tracing, and a test asserts their buffers do
not appear in captured output.

**TS5 implementation notes** (2026-09-11, #1139): (a) the on-share line
format is `key<TAB>uid<TAB>value` — deliberately NOT `SETTINGS.TXT`'s
`key=value` — because each entry carries the principal scoping `uid`
(ADR 0024 D1); the key/value bounds and `#v1` header are the shared engine
semantics the ADR promises. (b) A malformed `SECRETS.TXT` line is SKIPPED
(not fail-closed like a malformed `OWNERS.TXT` line): the file is
host-provisioned and the file ABI cannot read it, so a bad host line is not
guest-reachable and poisoning the whole store would silently strand every
principal's secrets; the store still refuses a non-`#v1` schema entirely.
(c) The guest glue zeroes its `sys_secret_get` staging buffer after copying
out key names (key-material hygiene; TS4 follows the same discipline).

**M97g amendment (2026-10-15, #2083 — per-entry app binding).** The D8 uid
scope was observed vacuous for cross-app isolation: every ordinary EL0
process is `uid_user`, so `net-hmac`/`ssh-user-ed25519`/`ssh-host-ed25519`
were readable by any app. A `SECRETS.TXT` line now carries an OPTIONAL
fourth field — `key<TAB>uid<TAB>value<TAB>apps` — a comma-separated
allowlist of image names. An app-bound entry is served only when (a) the
caller uid matches, (b) the caller's recorded image name matches a listed
name, and (c) that image path is `uid_system`-owned in `OWNERS.TXT` with
no non-owner write bit (`trust.system_owned_key`). The name alone is
forgeable (EL0 can `exec` any path string it authors), and ownership alone
names no app; together they are honest because EL0 cannot author a
`uid_system` row (runtime `set_mode` mints `uid_user` rows only) and
cannot edit `OWNERS.TXT` to forge one — the metadata file is now
self-protected **by construction** (`trust.ensure_meta_file`, applied at
every load and at boot even when the file is absent, so an EL0 process can
never write the table that would be trusted next boot). Entries without
the field keep the legacy uid-scope behavior; the `SecretRecord` wire
shape and never-logged contract are unchanged. The provisioned bindings:
`net-hmac`/`net-ed25519` → `GOSH.ELF`, `ssh-user-ed25519` → `GOSSH.ELF`,
`ssh-host-ed25519` → `GOSSHD.ELF`.

**M113a note (2026-10-16, #2417 — ADR 0054):** `GRANTS.TXT` joins the
secret class as the second member. Its contents are policy, not a secret —
the class is taken for *integrity*: secret-class-by-construction is the
existing mechanism that makes a share file unreachable through the file
ABI, and the file ABI is the only write path an EL0 process has. The
kernel registers it at load and at boot (the `ensure_secret_file`
pattern), so `OWNERS.TXT` never has to name it, rename/delete stay
denied, and the never-logged discipline is inherited. Posture is revealed
through `sys_grant_query` (D10 note) — the `sys_secret_get` shape of a
kernel-mediated read for a file-ABI-denied file. The M97g fourth-field
app-binding shows name-only binding is forgeable; a grant row binds image
*content* via `sha256`, which is strictly stronger, and a mismatch
refuses `grant_stale` rather than silently degrading to the baseline.

### D9. Settings (non-secret) keep their existing contract
`SETTINGS.TXT` and `kernel/src/settings.zig` are unchanged in format and
semantics; they gain no secret keys. The "store" is one engine with two
files and one class flag: setting entries are public, secret entries are
file-ABI-denied. The settings UI and `settings` monitor command never grow
a value-masking requirement for settings; masking is a property of the
secret class.

### D10. Additive syscall surface (ADR 0007 freeze respected)
New slots are appended in order; existing numbers/rows never move. The
implementation cards update ADR 0007's table and `implemented_count`
(today 68, `syscall.zig:105`):

| Slot | Name | Gate |
|---|---|---|
| 68 | `sys_principal` | always; returns the caller's `{ uid, caps }` |
| 69 | `sys_file_mode` | owner-only `chmod` on an existing path, or `CAP_FS_ANY`; `chown` is **not** in scope |
| 70 | `sys_secret_get` | caller's own principal entries; app-bound entries additionally require the caller's recorded image to be allowlisted AND `uid_system`-owned (#2083); redacted from strace |
| 71 | `sys_tty_net_auth(op, buf, len)` | caller must own the attached terminal; op = challenge / response / verdict |

Gated existing syscalls:

| Syscall | Gate |
|---|---|
| `sys_kill` (29) | self or same-uid allowed; cross-principal needs `CAP_PROC_ADMIN`; the EL1h monitor is never a target |
| `sys_exec` (28) | allowed for `uid_user`; preserves uid/caps; no setuid |
| `sys_file_*` (23–27, 34–37) | D3/D4 ownership checks; `CAP_FS_ANY` bypass for kernel actors |
| `sys_tty_attach` (67) | existing serial/window owner checks unchanged; net selector uses the D6 handshake instead of a secret argument |
| `sys_wmctl` (65), shared-anon mmap (63/64) | unchanged: existing one-seat and owner/capability checks already hold |
| `sys_setrlimit` (54) | unchanged (self-limits only); watching for cross-principal growth is an open issue |

**TS3 (2026-09-11, #1137)** implements the `sys_kill` row and adds no slot:
self and same-uid targets are allowed for every principal, a
cross-principal target needs `CAP_PROC_ADMIN` (else `EACCES`), the EL1h
monitor has no pid and is never a target, and the monitor's
`exec -u<uid>` admin spawn is the only EL0-unreachable path that can name
a principal. `implemented_count` stays 72.

**M113a note (2026-10-16, #2417 — ADR 0054):** two additive slots are
reserved (numbers 88/89 at merge, per D10's append-only rule):
`sys_grant_admin` — the ONE write path into `GRANTS.TXT`, gated like the
M97g clipboard pair (the registered WM seat or `CAP_PROC_ADMIN`; never
the app the row names) — and `sys_grant_query`, the caller's own posture
read for the trust viewer. The `capability_gates` table also grows
*word-gate* rows alongside cap rows: a slot's required grant word is
checked through the same `gated()`-style lookup at dispatch, plus one
sub-op check on slot 80's open-class ops (`0`/`8`/`10`) for `net`. In
`audit` mode a failed word check receipts `audit:word_denied` and does
not refuse; `enforce` is a separate owner decision.

### D11. Verification is two-class, and the boot default does not move
- **Class A:** principal defaults and inheritance in `process.zig`; the
  `trust.check` allow/deny matrix, default policy, secret-class denial,
  malformed-metadata fail-closed in `trust.zig`; the delegated-auth state
  machine over the existing injectable `NetSeam`
  (`terminal.zig:722-739`) — wrong MAC, replay/stale challenge, deadline,
  redaction; secrets bounds/round-trip.
- **Class B:** one declarative spec per card under `tools/gate/specs/`
  (AGENTS.md M40 GF6), e.g. `live-trust-whoami`, `live-trust-modes`,
  `live-secrets`, `live-remote-auth2`, `live-trust-caps`; the inventory is
  regenerated by the implementation PR.
- **Boot default unchanged:** no new syscall is on the boot path, nothing
  listens until a process asks, no secret is read unless requested, and the
  M46/M49 gate fleet keeps passing (with TS4's two intended gate
  re-pointings recorded in its card).

## Consequences

- The remote door stops transmitting a reusable credential: only a fresh
  challenge and a MAC/signature cross the wire, and only a pass opens the
  byte gate. The M46 shared-secret code path is deleted in TS4.
- The kernel stays crypto-free; M47 gains its first live consumer outside
  the `CRYPTOD.BIN` KAT demo.
- The host share wire is untouched; ownership and secrets are guest policy
  over host bytes, which keeps the host's existing "guest is untrusted,
  share is path-sandboxed" posture intact.
- Every direct `virtio_file` consumer must declare an authority, which
  turns today's implicit bypass into an explicit, auditable list.
- The single-user caveat is recorded: today, owner checks mostly pass; the
  secret class and `uid_system`-owned paths are what change behavior.
- A second TCP bound change (64 → 192) rides TS4; it is fixed-size and
  keeps the no-reassembly contract.

## Rejected alternatives

- **A kernel-local SHA-256/HMAC twin (and Ed25519 in kernel).** Would keep
  auth entirely in the pump, but duplicates the M47 library into the
  kernel against ADR 0023's grain, and Ed25519 in-kernel needs field
  arithmetic the kernel should never carry. Delegating verification keeps
  the primitives userland and the kernel's job bounded.
- **Keeping the in-band shared secret but hashing it.** A static secret on
  the wire is replayable; a fresh challenge costs little and removes that.
- **Host-side ownership metadata (wire extension / xattrs).** The host is
  not a trust authority for guest policy, macOS attributes do not map to
  the guest model, and it would change a frozen wire for no enforcement
  gain.
- **Full POSIX: groups, setuid, ACLs.** No driver in a single-user VZ
  guest; the 9-bit mode leaves room without implementing them.
- **TLS now.** A protocol project; the milestone's goal is a trust
  boundary, not confidentiality. Documented as a limit on every remote
  claim.
- **A capability-raising syscall.** Any setuid-style elevation path is a
  new attack surface; caps stay spawn-time.

## Open issues

- Groups/multi-user identities and a `USERS.TXT`, if a driver ever exists.
- Cross-connection rate limiting / lockout after repeated auth failures
  (ADR 0022's open item, still open).
- Host key provisioning UX for Ed25519 (host keyfile vs. share file), and
  whether the Stage-0 bridge should verify a guest key too.
- A session-encryption card (ChaCha20-Poly1305 over the M46 seam) and
  whether it changes the auth framing.
- Whether remote sessions should run under a distinct principal mapped
  from the authenticated host key; TS4 uses `uid_user`.
- ~~Case/normalization resolution for `OWNERS.TXT` keys against a
  case-insensitive host share~~ **Resolved by TS2 (2026-09-11, #1136):
  case-insensitive comparison with case-preserving storage; see D4.**
