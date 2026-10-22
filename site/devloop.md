---
title: The in-guest dev loop
parent: development
status: published
tags: [development, toolchain, flint, store]
---

# The in-guest dev loop

An operating system earns the word *platform* when you can develop for it
**on** it. VirelaiOS crosses that line end to end: source is edited,
diagnosed, built, run, versioned and pushed — entirely inside the guest —
and the host's job is reduced to staging inputs and checking receipts.
This page walks the loop, the agent-native SCM it rides, the host-side
sync server, and the signed supply chain that carries software from any
publisher's stream to a running app.

## The loop, end to end

The daily-driver journey is deliberately unglamorous:

1. **`flint init`** a workspace over a source tree on `/host`.
2. **Edit** in `GOSH.ELF` (heredocs write real files) or `GOEDIT.ELF`.
3. **Build** with `GOBUILD.ELF` — the guest's own `cmd/compile` +
   `cmd/link` do the work.
4. **Diagnose** — compiler diagnostics aggregate into `.BUILD/ERRORS.TXT`;
   GOEDIT loads them and jumps each `file:line:col`.
5. **Fix and rebuild**, then **run** the product — a real exec.
6. **Review** with `flint status`/`diff`, **commit** a signed Change,
   **`flint blame`** the result.
7. **`flint push`** the signed stream to a host `flintd` over the hermetic
   `--net` relay; the host byte-compares the log and runs
   `flint verify --all`.

The whole chain — init → edit → diagnose → fix → build → run → commit →
blame → push → host-verified — is pinned by one standing class-B gate:
`just gate live-dev-loop`, held at K=3 consecutive passes. Nothing in it
is mocked; the compiler is the real toolchain, the SCM writes real
signed history, and the host check is byte-level.

<Aside kind="info">

**LIVE-GATED.** `live-dev-loop` is the cheap standing form (scripted
edits, three boots per iteration). The heavyweight capstone —
`live-godiff-loop` — drives every source byte through a GOEDIT paste
lane to prove the loop works at real application scale.

</Aside>

## GOBUILD: the driver and its bounds

`GOBUILD.ELF` is a guest program, not a port of `cmd/go` — `os/exec` is
`ENOSYS` in this port, so the driver sequences each step as a fresh
process through `vi.Exec`/`sys_wait`: one `GOCMDCOMPILE.ELF` child per
package in dependency order, one `GOCMDLINK.ELF` at the end, intermediates
crossing as files on `/host`. Each child's diagnostics are captured into
`.BUILD/*.diag` and aggregated into `ERRORS.TXT`.

Resolution is a **bounded dependency closure**, not a package universe. A
staged package table (`GOPKGS.TXT`, emitted host-side from
`tools/go/pkg-table.txt` with the `GPKG_*.a` archives and `GOIMPORT.CFG`)
says which std packages exist and which are denied — `crypto/x509`, for
instance, carries a `denied` row because this GOOS has no system cert-root
store. Three refusal names carry the policy: `dep_unsupported` for a known
but unstaged/denied import, `no_package` for an import in no table at all,
and `closure_too_large` past the 64-package cap — all refuse in the graph
phase, before a single compile child spawns. `just gate live-gobuild`
proves the build (six sequential compiles + a link from one EL0 parent),
the run of the product, and both refusal legs.

## GOEDIT: diagnostics as navigation

`GOEDIT.ELF` closes the editor half of the loop. It reads the build's own
`ERRORS.TXT`, and `ctrl-n` jumps the first diagnostic to its `line:col`
in the buffer — so the workflow is literally build → open → jump → fix.
`ctrl-b` round-trips bracket matching (with a named `match none` on a
non-bracket), and `ctrl-s` publishes through `WriteFileSafe` — temp +
fsync + rename — while naming its one honest gap: `edit: format
unavailable (go/format not guest-safe)`. `just gate live-goedit-diags`
pins the jump and the named refusals on VZ.

The M107 capstone proves the loop scales past toy fixtures:
`GODIFF.ELF` — a unified context diff tool — was authored, compiled,
run, and pushed **entirely in-guest** (gates `go-godiff` for fleet
behavior and `live-godiff-loop` for the provenance journey).

## FLINT: agent-native source control

The version control in that loop is not Git — it is **FLINT** ([ADR
0049](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0049-flint-scm.md)),
a system designed so every primitive is structured, queryable and signed.
The unit of history is not a text diff; an agent asks *"which Changes
touched `auth.Login`?"* because FLINT tracks declarations, not lines.

### Primitives

- **Atoms** — top-level declarations parsed from source. Go files go
  through `go/parser` running *in the guest*; Zig files go through a
  Go-native declaration scanner whose oracle is a host-only
  `std.zig.Ast` program that must agree on every corpus file. Each Atom
  gets a permanent UUIDv7, a `hash` (canonical declaration, body
  included, name excluded) and a `sig_hash` (signature only) — so a
  whitespace-only or rename-only edit moves *neither* hash, while a body
  edit and a parameter edit are distinguishable by which hash moved.
- **Ops** — `add`/`modify`/`delete` (with `move`/`rename` in the data
  model for later verbs), produced by diffing the working tree against
  the last-known Atom table and staged in `STAGE.jsonl` — folding, so
  the stage always carries one net Op per Atom.
- **Changes** — an Ed25519-signed record of sorted Ops with parent,
  stream, timestamp, author key and message, appended to a Stream's
  `.jsonl` log. Signing uses the `agent-sign` seed from `SECRETS.TXT`,
  app-bound to `FLINT.ELF` through `OWNERS.TXT`; `flint verify`
  recomputes `ops_hash` and `sig_msg` and runs `EdVerify` against the
  Change's own `author` — proving integrity *and which key signed*.
- **Streams** — named lines of Changes (`streams/<id>.json` record +
  `.jsonl` log) plus per-workspace state under `ws/<name>/`. UUIDv7 ids
  make every object sortable.

The store is flat files, by owner ruling — no SQL, no dependency.
Bounds are named: 4096 Atoms per workspace, 4096 Changes per stream,
4 MiB per file read, all refusing `store_too_large`. The commit order is
append + fsync → rewrite the record → remove the stage; a torn final
line refuses `stream_torn` and a stale record rolls its head forward —
the log is the truth.

### Merge is semantic

`flint merge <from>` folds a forked Stream back with a **three-way merge
on Ops**: compute each side's net effect per Atom since the common
ancestor, then apply a pairwise conflict table (`concurrent_modify`,
`delete_vs_rename`, `move_vs_rename`, …) — a refactor that is rename +
modify on one side merges clean against an untouched side. A clean merge
always writes a merge Change (`merged` set, never a fast-forward — a
Stream's log only holds Changes signed for that Stream); a conflicted
one writes `MERGE.json`, names each atom and its conflict type, and
exits 2 having appended nothing.

FLINT stores *structure, not text* — a merge updates history and the
Atom table but cannot rewrite source, so merged Atoms are marked
`origin: merge` and a later `flint add` that finds them missing or
different on disk refuses `src_behind <file>` rather than staging a
silent revert.

### The verb surface

`init` / `add` / `status` / `commit` / `log` / `verify` / `fork` /
`merge` / `parse-corpus` landed in M103; `diff` (the versioned review),
`blame` (per-line attribution through covering Atoms to the touching
Change), `graph` and `tags` followed. `just gate go-flint` is the live
gate — its runs cover the parse corpus, the store lifecycle, signature
verification including a `sig_invalid` negative, the `secret_not_found`
refusal, and fork/merge journeys including `concurrent_modify`
conflicts.

## The host side: `flintd` and FLINT-SYNC/1

The SCM crosses the VM boundary through **FLINT-SYNC/1** — newline-
delimited JSON over an ordered byte stream, transport-agnostic by
design (TCP today, an `--stdio` pipe or a forced-command channel
tomorrow). The host server is `flintd`, a dependency-free Zig 0.17
binary living in the sibling
[flint-server](https://github.com/drawmeanelephant/flint-server) repo;
the cross-platform Zig client is
[flint-client](https://github.com/drawmeanelephant/flint-client). Both
hold the ADR 0049 store format byte-for-byte — a store copied off the
server loads in the guest and vice versa.

The wire verbs are `hello`, `auth`, `list`, `heads`, `open`, `read`,
`create`, `append`; the client-facing ones are `clone`, `pull`, `push`
and `ls-remote`. Changes travel as **raw JSONL line bytes, verbatim** —
the server never re-serializes, so canonical bytes and signatures are
trivially preserved, and a pulled log is byte-identical to the pushed
original. `append` re-implements the guest's commit order exactly:
re-read + `stale_head`, validate the whole batch (parse, chain, ≤512 B
UTF-8 message, `VerifyChange` per Change, `sig_invalid`), then append +
fsync. One stream, one writer; a head race answers `stale_head`, never a
silent overwrite.

Two opt-in postures ride the protocol: `--auth-key` arms an
HMAC-SHA256 challenge round (`auth_failed` closes the connection) — the
same shape as the guest's remote-door auth — and `--allow-author` gates
appends to listed author keys (`author_not_allowed`). A
golden-transcript conformance suite (`testdata/sync/`) pins the wire:
recorded NDJSON sessions replay byte-for-byte, field order, escaping,
refusal envelopes and all. The in-guest legs — signed stream →
verify-before-materialize → install → run — are the `go-flint` runs
11–17 legs, and `live-flint-loop` proves a real guest→host push round
trip, `flint verify --all` on the far side.

## The signed supply chain

FLINT is also the distribution channel. A **release stream** is a FLINT
stream whose folded head state covers a `release.go` declaring the four
required consts of the release manifest ([ADR
0055](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0055-release-manifest.md)):
`ReleaseName`, `ReleaseVersion`, `ReleaseELFSHA256`, and
`ReleaseManifestRow` (the schema-v2 `APPS.TXT` row the installer
writes). Four optional signed consts — `ReleaseSummary`,
`ReleaseDescription`, `ReleaseCategory` (a closed nine-word vocabulary),
`ReleaseIconSHA256` — turn `ls-remote` into a browsable **catalog**: the
store is a fold over signed manifests, with no flint-server change.

Two rules make it a supply chain and not a tarball: **identity is
derived, never declared** (the publisher fingerprint shown for a stream
is the `author` key of its head Change, checked against the keyring —
no const may claim identity, and identity-asserting names are
permanently outside the grammar), and **every atom is authenticated**
(the parsed `release.go` must equal the signed folded atom set exactly —
an unsigned extra declaration is `release_mismatch`, not extra
information).

The trust root is `FLINT/TRUSTED.TXT` on the share: `#v1` rows of
`key=<64-hex Ed25519 pub> name=<label>` and `revoked=<64-hex>`, bounded
and fail-closed (`keyring_malformed` refuses the whole file). Every
fetched Change is checked before materialization — `key_unknown` and
`key_revoked` are named refusals, and revocation wins over listing while
keeping the row for attribution.

### STORE: install, update, rollback

`STORE.ELF` is the install seam: `store ls`/`info`/`install`/`remove`/
`update`/`rollback`. Install re-parses the fetched `release.go`, matches
every parsed atom against the signed folded ops **atom-for-atom**,
fetches the ELF over the untrusted channel (a share drop dir or a
cleartext HTTP relay — FLINT carries structure, not blobs), verifies
`sha256(ELF)` against the signed `ReleaseELFSHA256`, and publishes the
ELF plus its `APPS.TXT` row through `WriteFileSafe` — keeping the prior
binary as a `.prev` rollback target. The live negatives are part of the
standing gate: `elf_mismatch`, `release_mismatch`, `key_unknown`,
`key_revoked`, `prev_mismatch`, `state_mismatch` all refuse by name.

`GOSTORE.ELF` puts the same signed legs behind a GUI —
browse/install/update/remove/rollback through STORE's pipeline (gate
`go-gostore`). The **third-party publisher drill** proves the ecosystem
claim rather than asserting it: a second Ed25519 key pinned `name=acme`
in `TRUSTED.TXT` signs a release stream for an app this repo did not
write; on a fresh share the catalog lists it, install verifies and
publishes it, and it runs — while `key_unknown`/`key_revoked` keep
refusing at materialization.

### Install-time consent

Installation is where power is granted too — deliberately, and only by
the user. A publisher may sign a `ReleaseCaps` request into the manifest
(ADR 0054's reserved `Release*` name — a *request*, declarative only).
STORE proposes the corresponding grant row; **the seat's consent modal
is the write path**: a `g` keystroke at the prompt writes the
hash-bound `(name, sha256, words)` row through the seat-gated grant-admin
slot (89). Nothing a publisher signs becomes power until that gesture
lands it in `GRANTS.TXT`, and an update that doesn't widen its words
keeps its grant silently. `just gate live-install-consent` pins the
modal and the write; the [[trust|trust model]] page has the enforcement
half.

## The GPL exception

The rule is absolute — **no GPL-family code in the system, the build, or
this repository, ever** — with exactly one exception, carved by [ADR
0058](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0058-gpl-app-payloads.md):
a GPL-family program may ship *exclusively* as a signed store payload,
built in its own sibling repository and installed through STORE. The
first and model case is Doom: the GPLv2 `doomgeneric` engine lives in
`drawmeanelephant/doom-engine`, located exactly like `../flint-server`,
compiled by `zig cc` as freestanding C into a standalone ELF that speaks
the raw syscall ABI — **nothing from this tree is linked into it, and
nothing GPL crosses into this tree** (source, headers, patches, license
text, binaries all stay engine-side). The engine signs its `doom`
release stream under its own publisher key — the acme drill made real —
and `doom1.wad` rides as a hash-pinned channel member under the
shareware license. `just gate live-doom` plays the result: store install
→ scripted consent → a `-playdemo` E1M1 walkthrough → clean `I_Quit`.

<Aside kind="warning">

**LIMITATION.** The dev loop is honest about its edges: builds are
offline — no `GOPROXY`, no module fetch, inputs are staged and pinned;
FLINT is single-writer per workspace and stores structure not blobs, so
merge cannot rewrite source (the `src_behind` guard is the honesty, not
a bug); there is no in-guest `cmd/asm`, so the `.s`-gated packages stay
host-built; and the store channel itself is cleartext — integrity comes
from the signatures, not the transport.

</Aside>

## Where next

- [[go-runtime|The Go runtime]] — the toolchain this loop drives.
- [[contributing|Contributing & toolchain]] — the host-side half.
- [[evidence|Evidence & testing]] — how the gates above are run.
- [[trust|Trust & security]] — the grant system behind install consent.
- [[roadmap|Roadmap & status]] — where these arcs sit on the ledger.
