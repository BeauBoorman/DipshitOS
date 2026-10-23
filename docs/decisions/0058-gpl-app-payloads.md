# ADR 0058: GPL app payloads — the engine lives in a sibling repo and ships as a signed store release

- Date: 2026-10-18
- Status: **Accepted** — shipped by the M130 arc (#2617, closed;
  `tools/gate/specs/live-doom.spec:1,69`); this ADR is the card (#2618),
  and the M130 arc implemented it in the filed order: M130b the sibling
  engine repo + `DG_*` shim (#2619), M130c the playable slice (#2620),
  M130d sound (#2621, ∥ c), M130e store packaging (#2622), M130f
  acceptance (#2623). (Number 0058 was provisionally held for this
  card; 0059 is the warm-checkpoint ADR, merged.)
- Card: **#2618** (M130 index **#2617**) — card 1 of 6. This is the
  one doc for the arc (AGENTS.md: one doc per arc, not four).
- Related: `AGENTS.md` *Scope rules* (the GPL bullet D7 amends),
  `LICENSE` (proprietary source-available — the direction the link
  boundary must satisfy), ADR 0049 (FLINT — signing primitives),
  ADR 0049 + `tools/gate/specs/go-flint.spec` (the `../flint-server`
  sibling-checkout precedent), ADR 0026/0030 (the EL0 build surface —
  Go today, no libc, no POSIX), ADR 0055 (the signed release manifest
  this release carries, and the `Release*` extension path D6 uses),
  ADR 0054 D10 (`ReleaseCaps` → seat consent → `GRANTS.TXT`), ADR
  0015/0016 (the window/shared-anon present seam the framebuffer maps
  to).

> The blocker for "it runs Doom" was never technical — it is
> licensing. The owner's policy is already ratified (2026-10-18,
> `docs/status.md` M130 row and index #2617): **GPL is fine as a
> runnable app payload; the system, the build, and this repository
> stay GPL-free.** This ADR does not re-litigate that; it fixes the
> mechanism. A GPL-2.0 Doom engine (doomgeneric — the codebase
> that exists precisely to be ported) lives in its own sibling
> repository, `doom-engine`, located exactly like `../flint-server`.
> It is built there into a freestanding AArch64 ELF that speaks the
> raw syscall ABI — nothing from this tree is linked into it, and
> nothing GPL is linked, vendored, fetched into, or quoted in this
> tree. The engine repo signs a release manifest with its own
> publisher key — the acme second-publisher drill made real — and the
> payload installs through STORE with `doom1.wad` riding as a
> hash-pinned channel member. `AGENTS.md` gets a one-bullet
> carve-out: the ban stands for system/build/repo; the store payload
> is the sole exception. GPL never crosses the boundary in either
> direction.

## Mission

Pin, before M130b creates the sibling repo: the operative policy
text; the repo name, location and fetch convention; the link
boundary the proprietary `LICENSE` forces; the engine pick and the
build route for C-without-libc; the WAD asset license, hosting, and
gate fetch; the release identity and capability request; the exact
`AGENTS.md` amendment; and the file-level Touches for M130b–f so
those cards land without renegotiation.

## Grounding (observed in tree `b9115058` and on this host, 2026-10-18)

**[observed]** means checked in the tree, the live record, the
upstream repositories named, or reproduced on this host;
**[inferred]** means reasoning only.

1. **The policy is ratified.** `docs/status.md`'s M130 row records
   "Owner policy ratified 2026-10-18: GPL payloads okay via store,
   never in system/build/repo"; index #2617 restates it and names the
   sibling-repo + signed-store architecture it makes obvious. This
   ADR documents and operationalizes it. **[observed]**
2. **The rule being amended.** `AGENTS.md` *Scope rules* carries the
   bullet "**No GPL-family code, ever.** Never vendor, copy, port,
   translate, link or ship GPL, LGPL or AGPL code anywhere in
   VirelaiOS: the guest, the host app, the build or this repository."
   Its final sentences bind third-party inputs generally: "A new
   dependency, host tool or test reference must not be GPL-family
   either; if no alternative exists, stop and ask the owner. Record
   the license whenever you adopt a third-party input." **[observed]**
3. **VirelaiOS is proprietary source-available.** `LICENSE` grants
   view/link rights only: no copying, modifying, translating,
   porting, derivative works, or incorporation "into another project
   or codebase" without written permission (§3), no implied license
   (§5). The GPL engine therefore cannot contain, translate, or wrap
   any VirelaiOS code — and no in-repo permissive helper library can
   be offered for it to link, because that would be the Software
   incorporated into another codebase. **[observed]**
4. **The sibling-checkout pattern is established twice.**
   `tools/gate/specs/go-flint.spec` locates `flint-server` as
   `FLINT_SERVER_DIR` else `../flint-server`, zig-builds `flintd` per
   run, and records `flintd_rev` in the output. `tools/go/*.sh`
   locate the `go-virelai` toolchain fork as `GO_FORK_DIR` else
   `../go-virelai` — itself a sibling repo holding foreign-licensed
   upstream code (Go, BSD-3-Clause) that never enters this tree.
   **[observed]**
5. **The third-party-publisher drill ran.** go-flint runs 20–21
   (M110d #2406): a second Ed25519 publisher key pinned `name=acme`
   in `TRUSTED.TXT` signs a third release stream whose ELF is
   `tools/gate/fixtures/third-party-app/acmeapp.go` (in-repo,
   project-licensed — a stand-in); on a fresh share the catalog lists
   it, `store install acme` verifies and publishes `ACMEAPP.ELF`, and
   the app runs. The stranger's-app journey is already proven end to
   end; Doom makes it real. **[observed]**
6. **The ELF loader contract is narrow.** `kernel/src/elf.zig`
   accepts statically linked AArch64 ELF64 little-endian, at most
   `max_segments` = 3 PT_LOADs ordered R+X / optional R rodata / RW
   last (middle writable is `writable_rodata`; last read-only is
   `readable_data`), file ranges disjoint and forward-ordered, gap
   layout allowed with page-aligned vaddrs strictly below
   `gap_base_max` = 0x1000_0000, `e_entry` inside segment 0's
   *initialized file bytes* (`bad_entry` otherwise), `load_max` =
   32 MiB of `Σ filesz`, `map_max` = 64 MiB of `Σ memsz`.
   **[observed]**
7. **Every seam the port needs already exists.** The syscall table
   (`kernel/src/syscall_abi.zig`) covers the whole platform surface a
   `DG_*`-class shim requires: window/present — `sys_win_open` (12),
   `sys_win_present` (14), `sys_win_resize` (47), and the shared-anon
   framebuffer via `sys_mmap` (63) bound as the window surface (the
   `vi.MmapWindowSurface`/`ScanoutFbBytes` path `tabapp` uses; ADR
   0015/0016); input — `sys_poll_event`/`sys_wait_event` (21/22);
   timing — `sys_timer_set`/`sys_timer_cancel` (40/41), `sys_time`
   (66), `sys_sleep` (4); audio — `sys_audio_info`/`sys_audio_play`
   (42/43; ADR 0046); files — `sys_file_open/read/close` (23/24/26)
   for the WAD; process — `sys_exit` (3), `sys_write` (1),
   `sys_getrandom` (72). A payload needs no new slot. **[observed]**
8. **EL0 apps today are Go or Zig — no libc, no POSIX, no C
   toolchain.** The Go runtime port (ADR 0026/0030) builds with the
   `go-virelai` fork into the gap-layout ELF shape; nothing in the
   guest build compiles C. The engine is C, so its toolchain is
   engine-repo work. **[observed]**
9. **The Zig toolchain compiles freestanding C for AArch64.** Probe
   on this host (Zig 0.17.0): `zig cc -target
   aarch64-freestanding-none -nostdlib` compiles C with an `svc #0`
   entry stub to a valid ELF64 `EM_AARCH64` — no libc objects.
   **But** the default link emits four program headers (two PT_LOAD
   plus `PT_GNU_STACK`/`PT_GNU_RELRO`) and lands the entry outside
   segment 0 — refused under Grounding 6 as-is. A linker script
   placing `.text` first in one R+X segment, one R rodata, one RW
   data satisfies the contract's shape; that script is engine-repo
   work. **[observed]** for the toolchain verdict; **[inferred]**
   that the shaped layout satisfies every loader check — M130b's
   smoke build is the proof.
10. **doomgeneric is the porting base.** `ozkl/doomgeneric` (upstream
    record) is licensed GPL version 2 and exists to minimize port
    surface: the porter implements a small `DG_*` function set —
    present buffer, key input, sleep/tick timing, window title —
    while the game, WAD loader, renderer and sound mixer ship as-is.
    **[observed]**
11. **`doom1.wad` is redistributable and non-GPL.** The shareware
    episode WAD is © id Software under its Limited Use Software
    License Agreement: the unmodified file may be copied and given to
    others without charge; modification and extraction are forbidden.
    id's GPL release of the Doom source (1999) covered *code*, never
    game data — the WAD was never GPL. `DOOM1.WAD` ≈ 4 MiB.
    **[observed]**
12. **Freedoom is the fallback.** `freedoom1.wad` is BSD-3-Clause —
    cleanly redistributable and modifiable, at the cost of not being
    Doom. **[observed]**
13. **The release grammar covers this payload.** ADR 0055: four
    required consts, optional signed catalog consts, additive and
    ignored-when-unknown; publisher identity derived from the head
    Change's `author` key — never declared by a const (D5); channel
    members are `<stream>/<name>` with ≤32-byte `[A-Za-z0-9._-]`
    components fetched over the untrusted channel and verified
    byte-for-byte; a new `Release*` const enters the grammar through
    an amendment to 0055 or a new ADR citing §D6 — this ADR is that
    route. ADR 0054 D10: `ReleaseCaps` is a publisher *request* —
    STORE proposes, GOSET seat consent writes the `GRANTS.TXT` row.
    The `caps=` vocabulary is `file window audio timer memory
    process debug net term`. **[observed]**
14. **What may never land here.** AGENTS.md evidence rules permit
    committing only small pinned fixtures (a golden file, a byte
    vector). A ≈4 MiB WAD and an engine ELF are neither; both arrive
    through the sibling checkout or the signed channel, pinned by
    hash. **[observed]**

## Decision

### D1. Policy — GPL is a payload license, never a project input

The ratified policy, stated operatively:

- **The system, the build, and this repository are GPL-free.**
  Nothing licensed GPL, LGPL or AGPL — source, header, patch,
  license text, object code, binary, or test fixture — is committed
  to, fetched into, vendored by, translated into, or linked into
  VirelaiOS: guest, host app, build, docs, or specs. This ADR itself
  quotes no GPL text and no engine source.
- **A GPL-family program may ship exclusively as a signed store
  payload**: built in its own repository, signed under its own
  publisher key, installed through STORE on a user's VM, run as an
  ordinary EL0 app. The payload carries whatever license its authors
  chose — the license governs the payload, never the platform.
- **The direction is one-way.** GPL reaches the guest only as an
  installed artifact over the signed channel. No path lets GPL code
  become part of the image, the toolchain, or the tree; no path lets
  VirelaiOS code become part of the GPL work (Grounding 3).

`AGENTS.md` carries this as the D7 amendment. A future non-Doom GPL
payload follows the same route; a *new* GPL surface (an engine vendored
for the build, a GPL host tool) is still refused by the unchanged first
half of the bullet.

### D2. Repo boundary — `doom-engine`, located like `flint-server`

- **Name:** `doom-engine` under `drawmeanelephant`
  (`github.com/drawmeanelephant/doom-engine`). Fixed here; M130b
  creates it and carries upstream doomgeneric under its own GPLv2
  license, plus the shim, minimal runtime, linker script, and license
  texts — all GPL-side.
- **Location:** sibling checkout `../doom-engine`, overridable by
  `DOOM_ENGINE_DIR` — byte-for-byte the `FLINT_SERVER_DIR` /
  `GO_FORK_DIR` convention (Grounding 4). Gate setup hooks fail with
  a clone hint when the checkout is absent, exactly as go-flint does.
- **May cross into this repo:** gate spec text and hook code that
  clones/builds/fetches the sibling; the WAD's pinned sha256 (a
  fixture, not the asset); ABI facts (syscall numbers, register
  conventions, the ELF contract) restated in comments and engine-repo
  headers; non-GPL fixtures authored here.
- **Never crosses:** engine source, headers, patches, GPL license
  text, built engine binaries, the WAD — nothing derived from the
  GPL work. A gate that needs the engine binary builds it from the
  sibling checkout into the armed share (a gitignored artifact), or
  fetches the signed release through the channel. Checkout rev is
  recorded in gate output, as `flintd_rev` is today.

### D3. Link boundary — the raw syscall ABI, nothing else

The engine ELF is fully standalone: it enters at `_start`, issues
`svc #0` traps under the documented slot-and-register convention,
and links **nothing** from VirelaiOS — no object, header, archive,
or runtime. Two constraints force this shape:

- `LICENSE` forbids VirelaiOS code crossing into another codebase
  (Grounding 3) — an in-repo shim library for the GPL side to call
  would be exactly that.
- GPL forbids the reverse — proprietary VirelaiOS objects inside a
  GPL binary would demand their source under GPL, which the LICENSE
  never grants.

So the whole contract is the ABI: syscall numbers and argument
registers are interface *facts*, which the engine repo restates in
its own words in its own headers — no text from
`kernel/src/syscall_abi.zig` or `user/go/vi` is copied, translated,
or wrapped. The `DG_*` shim is owned by the engine repo, on the GPL
side, written against the documented seam list in Grounding 7. This
is the only boundary compatible with both licenses, so it is the
decision, not a preference.

### D4. Engine pick — doomgeneric port shim, built by Zig as freestanding C

- **Base:** doomgeneric (GPLv2; Grounding 10). The port is a shim,
  not an engine: implement `DG_*` — framebuffer into the shared-anon
  window surface + `sys_win_present`, key events off
  `sys_poll_event`/`sys_wait_event`, `DG_SleepMs`/`DG_GetTimeMs` off
  `sys_sleep`/`sys_timer_set`/`sys_time`, PCM submit stub on
  `sys_audio_*` (filled by M130d), window title — against seams that
  all exist (Grounding 7).
- **Build route:** freestanding C compiled by the Zig toolchain's
  bundled clang (`zig cc -target aarch64-freestanding-none` or the
  engine repo's `build.zig` C step), no libc anywhere — the engine
  repo supplies the minimal runtime doomgeneric needs (memory ops,
  a bounded allocator over a fixed heap or `sys_mmap`, file I/O over
  `sys_file_*`, formatted output to `sys_write`), written
  engine-side. The output ELF must satisfy the Grounding-6 contract;
  a linker script in the engine repo owns the ≤3-segment R+X/R/RW
  shape with the entry inside segment 0's file bytes (Grounding 9 —
  toolchain proven, layout inferred until the smoke build).
- **Named alternative, rejected:** the card-b Go/Zig from-scratch
  subset. See Rejected alternatives.

### D5. Assets — shareware `doom1.wad`, hosted engine-side, hash-pinned

- **Primary asset:** `doom1.wad`, the shareware episode — the real
  thing ("it runs Doom" means Doom), redistributable unmodified and
  without charge (Grounding 11). It lives in the engine repo (as a
  committed binary or a release asset — M130b's choice, recorded
  there with its license notice) and is **never committed to this
  repo**: a ≈4 MiB binary is not a pinnable fixture (Grounding 14).
- **Gate fetch (pre-store legs, M130c/d):** the `live-doom` setup
  hook copies `doom1.wad` from the `DOOM_ENGINE_DIR` checkout into
  the armed share; the spec pins its sha256 — fetch is mechanical,
  integrity is asserted.
- **Store path (M130e+):** the WAD rides the `doom` release stream
  as channel member `doom1.wad` (≤32-byte `[A-Za-z0-9._-]` — fits),
  pinned by the signed const in D6 and fetched over the same
  untrusted, verified byte-for-byte channel as the ELF. It lands on
  the share as a file the engine opens with `sys_file_*`; the
  install-side fetch mechanics are M130e's, and if they require a
  STORE change that is filed against the store, per card e.
- **Fallback, recorded not implemented:** Freedoom `freedoom1.wad`
  (BSD-3-Clause; Grounding 12) if shareware redistribution is ever
  contested. Swapping assets changes no boundary — the ADR stands.
- **License record (AGENTS.md: record every third-party input):**
  doomgeneric GPLv2; `doom1.wad` id Software Limited Use
  Software License (shareware, unmodified-redistribution);
  Freedoom BSD-3-Clause (fallback only).

### D6. Store release — stream `doom`, binary `DOOM.ELF`, its own publisher key

- **Release stream:** `doom`. **Binary:** `DOOM.ELF` — `ReleaseName`
  grammar is 1–28 of `[A-Z0-9_-]`; `DOOM` fits, and the `GO*` prefix
  convention denotes Go-built binaries, which this is not.
- **Publisher:** a distinct Ed25519 key held by the engine repo,
  pinned in `TRUSTED.TXT` as `name=doom` — the acme second-publisher
  precedent (Grounding 5) made real: the dogfood is "software from
  anyone," so the payload's key is not the VirelaiOS base key.
  Identity is derived from the signature per ADR 0055 D5; no const
  claims it.
- **Asset pin:** one new signed optional const,
  `ReleaseAssetSHA256`, entering the grammar through ADR 0055 §D6's
  new-ADR extension path — the sanctioned route. Grammar:
  comma-separated `<member>:<64-lower-hex>` pairs naming channel
  members and their digests; the `doom` release carries
  `doom1.wad:<sha256>`. Readers validate it like every signed
  catalog const and ignore it when unknown (0055 D4) — a v1 STORE
  still installs `DOOM.ELF`; the asset fetch is on demand like the
  D7 icon pin.
- **`ReleaseCaps` request:** `file window audio timer memory` —
  `memory` because the shared-anon window surface and the heap are
  `sys_mmap`; `file` covers the WAD and savegames; `window`,
  `timer`, `audio` name the rest of the shim's seam list. GOSET seat
  consent writes the grant row per ADR 0054 D10.
- **The GPL text travels with the payload.** The release stream's
  atoms carry the engine repo's license notice as payload content —
  inside the signed channel, never into this repo.

### D7. `AGENTS.md` amendment — the carve-out, as a minimal diff

The ban's wording stays; its scope clause narrows to where it always
meant, and the payload exception is appended. Exact diff:

```diff
-- **No GPL-family code, ever.** Never vendor, copy, port, translate, link or
-  ship GPL, LGPL or AGPL code anywhere in VirelaiOS: the guest, the host app,
-  the build or this repository. A new dependency, host tool or test reference
-  must not be GPL-family either; if no alternative exists, stop and ask the
-  owner. Record the license whenever you adopt a third-party input.
+- **No GPL-family code in the system, the build, or this repository, ever.**
+  Never vendor, copy, port, translate, link or ship GPL, LGPL or AGPL code
+  in the guest system, the host app, the build or this repository. A new
+  dependency, host tool or test reference must not be GPL-family either; if
+  no alternative exists, stop and ask the owner. Record the license whenever
+  you adopt a third-party input.
+  - The one exception is a GPL-family program shipped as a signed store
+    payload built in its own sibling repository and installed through STORE
+    (ADR 0058): everything GPL — source, headers, patches, license text,
+    binaries — lives in that sibling repo and travels the signed channel,
+    never this repository, the system image, or the build.
```

The edit is applied in this PR; merge approval is the owner
sign-off. If the owner prefers to defer the amendment, the hunk
reverts as a one-comment fix and this section records the deferral.

## Non-goals (explicit)

| Non-goal | Where it stands |
|---|---|
| Re-litigating the ratified policy | It is recorded, not reopened — D1 operationalizes it |
| Any code, the sibling repo, the build machinery | M130b (#2619) creates them |
| Full Doom compatibility — all episodes, demos, multiplayer, mods | Index non-goal; the bet is a playable E1M1-class slice |
| Any GPL text in this repo — including quoting it here | Permanent; the card's own out-of-scope |
| The WAD or engine binary committed to this repo | Grounding 14's fixture rule — hash pins travel, assets don't |
| A `ReleaseCaps`/`Release*` grammar beyond `ReleaseAssetSHA256` | ADR 0054 owns `ReleaseCaps`; further consts take 0055 §D6's path |
| Store/STORE code changes | M130e files one against the store if the asset fetch needs it |
| The boot default, image contents, or gate fleet inventory | Untouched; gates fetch the payload at run time |
| Music fidelity, network play, mods | M130d names the music posture; the rest is the index's non-goal |

## Card split — file-level Touches

Lanes `a → b → {c ∥ d} → e → f` (the index). This ADR is a; the rest:

| Card | Issue | Delivers | Touches |
|------|-------|----------|---------|
| M130b | #2619 | sibling repo + upstream import under GPLv2, `build.zig`/linker script producing the contract ELF, `DG_*` shim on the Grounding-7 seams, minimal C runtime, WAD load + TITLEPIC decode host legs | `doom-engine` repo (new, sibling `../doom-engine`); this repo: nothing, or only ADR-sanctioned non-GPL plumbing named at claim |
| M130c | #2620 | game loop at tick rate, input → move/use/fire, E1M1 renders; `live-doom` spec + setup hook (builds engine from `DOOM_ENGINE_DIR`, copies `doom1.wad`, pins sha256), first class-B leg | `doom-engine` repo; `tools/gate/specs/live-doom.spec`; `image/*` only if the binary must be staged before M130e |
| M130d | #2621 | WAD PCM lumps → `sys_audio` negotiated format → bounded playback; music implemented or refused by name; separate sound spec keeps it ∥ c | `doom-engine` repo; `tools/gate/specs/live-doom-sound.spec` |
| M130e | #2622 | signed release manifest, `ReleaseAssetSHA256` pin, `ReleaseCaps` request (`file window audio timer memory`), APPS.TXT v2 row, publisher key `name=doom`; install leg: fresh VM → STORE install → launch → TITLEPIC | `doom-engine` repo; `flint-server` repo testdata as needed; `tools/gate/specs/live-doom.spec` |
| M130f | #2623 | acceptance journey fresh VM → store install → scripted E1M1 walkthrough → clean exit, K=3; status row; index closure | `tools/gate/specs/live-doom.spec`; `docs/status.md` |

## Consequences

- **The GPL exception is enumerable.** One route (signed store
  payload), one boundary shape (sibling repo, `*_DIR` override), one
  link surface (raw syscall ABI). An auditor can verify the whole
  exception from this file plus the amended bullet.
- **Nothing in the trust model bends.** The payload rides the same
  keyring, manifest, `ReleaseCaps`→consent, and grant-table path as
  any stranger's app; GPL-ness changes a copyright fact, not a
  privilege. The acme drill's "software from anyone" thesis becomes
  real software.
- **The ELF contract becomes the third-party payload ABI.** Any
  future freestanding payload — C, Rust, anything — follows D3's
  boundary and Grounding 6's layout; Doom is the first consumer, not
  a special case.
- **Coordination claims stay honest.** A card editing only the
  sibling repo declares `doom-engine repo (new, sibling)` in
  Touches; the overlap gate compares like for like because the
  sibling paths can't collide with in-repo paths.
- **The license record is complete.** Every third-party input the
  arc adopts is named with its license in D5 — the standing rule
  survives the exception it permits.

## Rejected alternatives

- **Vendoring doomgeneric into `user/` or `tools/`.** GPL code in
  the repo is the exact thing the ban exists to prevent; the policy
  ratified a *payload* route, not a vendoring route.
- **A from-scratch Doom subset in Go or Zig** (the card-b
  alternative). It dodges GPL entirely but trades a licensing card
  for an engine-research arc — the index's bet is a playable slice,
  and the licensing record stands identically either way, so the
  path where the game is already written wins.
- **An in-repo permissive shim library the GPL binary links.**
  Refused by `LICENSE` §3 in one direction (VirelaiOS code
  incorporated into another codebase) and by GPL in the other
  (proprietary objects in a GPL binary). The raw ABI is the only
  boundary both licenses admit (D3).
- **Porting/translating the engine into this repo.** "Port" and
  "translate" are banned verbs in the bullet itself; a rewrite here
  is still GPL-derived.
- **Freedoom as the primary asset.** Legally cleaner (BSD-3) and
  kept as fallback, but the milestone is "it runs Doom" — the
  shareware WAD is Doom.
- **Committing `doom1.wad` or the built ELF here.** A ≈4 MiB binary
  asset and a GPL binary both violate Grounding 14's pinned-fixture
  rule; hashes are committed, artifacts are fetched.
- **Embedding the WAD inside `DOOM.ELF`.** Legal but spends the
  mapped-memory bound on static data and entangles non-GPL assets
  with the GPL artifact; a hash-pinned channel member is the
  store-native shape (D5/D6).
- **Signing the release with the VirelaiOS base key.** Defeats the
  third-party dogfood — the payload must arrive the way a stranger's
  app does (D6).
- **Reusing `GODOOM` as the binary name.** The `GO*` convention
  marks Go-built binaries; naming a C engine `GODOOM` is a lie the
  catalog would print forever.

## Open issues

- **Whether `zig cc`'s output can be shaped to every loader check**
  (Grounding 9). Toolchain proven; layout inferred. M130b's first
  leg is a smoke build + `elf.zig` host parse; if the shaped layout
  can't satisfy a check, that is M130b's blocked step, named — not a
  reason to reopen D4.
- **The in-guest install location of `doom1.wad`** (D5). Pinned: it
  lands on the share, engine-readable via `sys_file_*`. The
  mechanics — STORE fetch step vs replica-side read — are M130e's,
  and a required STORE change is filed there.
- **The engine repo's commit-vs-release-asset choice for the WAD**
  and its internal layout — M130b's, recorded there.

## Acceptance

- ADR merged with owner sign-off; the `AGENTS.md` amendment merged
  with it (or explicitly deferred by the owner, recorded in D7).
- M130b–f (#2619–#2623) cite this ADR's decisions — the `doom-engine`
  name and `DOOM_ENGINE_DIR` convention (D2), the raw-ABI link
  boundary (D3), the doomgeneric pick and freestanding-C build route
  (D4), the `doom1.wad` asset posture (D5), the `doom`/`DOOM.ELF`/
  `name=doom`/`ReleaseAssetSHA256`/`file window audio timer memory`
  release shape (D6) — without reopening them.
- Nothing GPL enters this repository, ever: this PR's own diff is
  two markdown/rulebook files and no upstream text.
