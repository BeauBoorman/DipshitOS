# ADR 0055: The release manifest — the release-stream convention and its signed catalog fields

- Date: 2026-10-16
- Status: **Accepted** — shipped by the M110 arc (#2383, closed): the
  signed install path is live (`user/go/store/install.go:228,319`); this
  ADR is the card (#2403). M110b–e implemented against it, and M113's
  ADR 0054 extends it (D6).
- Card: **#2403** (M110, program index #2383) — card 1 of 5. The index's
  *Design direction* (2026-10-16, owner-delegated) is ratified here.
- Related: ADR 0049 (FLINT — the Change/Op signing this format
  inherits), ADR 0041 (the SVG subset — the icon blob's candidate
  raster format, §D7), image `apps.txt` schema v2 (M82a — the additive
  rule D4 generalizes).

> The release manifest is a signed, cross-repo format, and today it lives
> only in a code comment (`user/go/store/model.go:9-28`) and an external
> issue (flint-client#48). M110 adds catalog fields to it now; M113 adds a
> capability request to it later. Cross-cutting, security-relevant, and
> expensive to reverse — so the convention gets one documented home here,
> and every later `Release*` const enters the grammar through this file.

## Mission

Pin, before M110b writes a parser: which consts a release manifest must
carry and which it may carry, the per-field bounds and the named refusal
for each, the compatibility rule old and new readers share, the rule
that publisher identity is derived rather than declared, the catalog as
a fold over signed manifests with no flint-server change, and the
namespace discipline later arcs extend through.

## Grounding (observed in tree `d0a14b6d`, 2026-10-16)

- **The convention exists and is enforced.** A *release stream* is a
  FLINT stream whose folded head state covers `release.go` — at the src
  root or under one directory level (`isReleasePath`,
  `user/go/store/release.go:28`) — declaring four consts: `ReleaseName`,
  `ReleaseVersion`, `ReleaseELFSHA256`, `ReleaseManifestRow`
  (`requiredConsts`, `release.go:81`; minimal fixture at
  `user/go/store/testdata/release.go`). The folded signed atom set comes
  from `foldReleaseOps` (`release.go:37`): add/modify/move/rename set an
  atom's latest signed hash, delete removes it.
- **Every atom is authenticated; unsigned extras are refused.**
  `verifyRelease` (`release.go:93-125`) requires the parsed
  (kind, qname, hash) set of the fetched `release.go` to equal the
  signed folded set *exactly*: an extra unsigned declaration is
  `release_mismatch`, not extra information. `parseRelease`
  (`release.go:140-181`) then reads only the four required consts and
  ignores the rest — the additive posture already exists.
- **The existing grammar and refusals.** `validate` (`release.go:200`):
  name 1–28 chars of `[A-Z0-9_-]` starting alphanumeric (`validStem`,
  `release.go:231`; `<NAME>.ELF` must fit the 32-byte share name),
  version 1–64 of `[A-Za-z0-9._+-]` → `release_malformed`, ELF hash 64
  lowercase hex → `hash_invalid`, manifest row ≤ 512 bytes, no CR/LF,
  `|`-field 1 exactly `<NAME>.ELF`, field 2 non-empty → `row_mismatch`.
  The fetched file is bounded by `MaxReleaseBytes` = 64 KiB
  (`model.go:54` — "far past honest and keeps a hostile channel from
  staging a memory soak"); any read past its bound is `file_too_large`.
- **The keyring gate runs on every fetched Change.**
  `fetchAndVerifyStreamChanges` (`user/go/flint/remote.go:646`)
  checks each Change's `author` key against `TRUSTED.TXT`
  (`key_unknown`/`key_revoked`) and verifies its Ed25519 signature —
  verify-before-materialize, integrity independent of transport.
  `TRUSTED.TXT` is `#v1` plus `key=<64 lower hex> name=<label ≤64>` and
  `revoked=<64 lower hex>` rows, ≤ 64 KiB; absent → `keyring_missing`,
  corrupt → `keyring_malformed` (`keyring.go:30-110`). The keyring
  `name=` label is the only trusted display name a publisher has.
- **The untrusted channel is per-stream members.** `channel.fetch`
  resolves `<stream>/release.go` and `<stream>/<NAME>.ELF` over a share
  drop dir or a cleartext HTTP relay; each path component is ≤ 32 bytes
  of `[A-Za-z0-9._-]` (`checkRelPath`, `channel.go:65-89`). `<NAME>.ELF`
  already spends the whole 32-byte member budget (28 + 4), so a derived
  `<NAME>.ICON` cannot exist — see D7.
- **`store ls` is already a fold.** `cmdLs` (`install.go:191-230`)
  enumerates the remote's streams (the wire `list` op), refreshes each
  local replica, folds the head log to its signed `release.go` atom set
  (`headReleaseOps`), and prints `release` / `no-release`. The catalog
  this ADR defines is the same fold with the const values read out —
  nothing new travels any wire.
- **A Change's author is a 32-byte Ed25519 key** (ADR 0049 §Primitives),
  rendered `key=` in `TRUSTED.TXT` as 64 lowercase hex.

## Decision

### D1. One home

This ADR is the release-manifest specification. `model.go`'s convention
comment stays as the in-code pointer but stops being the authority —
when they disagree, this file wins and the comment is edited. A change
to the manifest grammar is an amendment here or a new ADR, never a
code-only edit.

### D2. The manifest and its required consts

The manifest is the signed atom set of `release.go` at a release
stream's head, plus the four required consts those atoms must declare.
The four are unchanged and stay **required** — a head `release.go`
missing any of them is not a release (`release_malformed` naming the
const):

| const | grammar | bound | refusal |
|---|---|---|---|
| `ReleaseName` | 1–28 of `[A-Z0-9_-]`, first char alphanumeric | the ELF stem; `<NAME>.ELF` fits the 32-byte share name | `name_invalid` |
| `ReleaseVersion` | 1–64 of `[A-Za-z0-9._+-]` | printable token | `release_malformed` |
| `ReleaseELFSHA256` | exactly 64 lowercase hex | sha256 of the delivered ELF | `hash_invalid` |
| `ReleaseManifestRow` | ≤ 512 bytes, no CR/LF, ≥ 2 `|` fields, field 1 = `<NAME>.ELF`, field 2 non-empty | the schema-v2 APPS.TXT row the installer writes | `row_mismatch` |

A *release* is a signed Change touching `release.go`; the Change
signature plus each Op's `new_hash` authenticates the const text end to
end (the M101b keyring path). `release.go` and every blob it names
travel the untrusted channel and are verified byte-for-byte before use.

### D3. Optional signed catalog consts

The catalog is `ls-remote` — the wire `list` op — plus the head
`release.go` of each release stream: the fold `cmdLs` already performs,
with the consts below read out of the signed atoms. **No flint-server
change**; the cross-repo card disappears.

Four optional consts may sit beside the required four. All are signed
atoms — covered by the same Change signature — so a catalog never
displays a byte the publisher's key did not authorize.

| const | presence | grammar + bound | named refusal |
|---|---|---|---|
| `ReleaseSummary` | optional | one line: 1–128 bytes, valid UTF-8, no C0/C1/DEL control characters (one line by construction) | `summary_invalid` |
| `ReleaseDescription` | optional | 1–2048 bytes, valid UTF-8; `\n` is the only permitted control character | `description_invalid` |
| `ReleaseCategory` | optional | exactly one of the closed vocabulary in D3.1 | `category_unknown` |
| `ReleaseIconSHA256` | optional | exactly 64 lowercase hex; names the blob pin in D7 | `hash_invalid` (detail `ReleaseIconSHA256`) |

A reader that consumes catalog fields validates **every present,
known** const and refuses the release by name on a violation — a signed
field outside its bound is a malformed manifest, never a value to
sanitize. Consts a reader does not know are ignored (D4). A release
that omits an optional const is valid; the field is simply absent from
its catalog entry.

#### D3.1. The category vocabulary (closed)

```
app  demo  dev  doc  game  media  net  system  tool
```

Nine lowercase words. The vocabulary is **closed and pinned here**:
adding, renaming, or removing a word is an amendment to this ADR, not a
code edit — a category the reader cannot classify is refused
`category_unknown` rather than rendered. An uncategorized release omits
the const. Free-text categories are refused permanently: a browsing
taxonomy the publisher composes at will is an unbounded string
masquerading as a label.

### D4. Compatibility: additive, signed, ignored-when-unknown

- **No wire change, no signature change.** A new const is another atom
  in `release.go`; its Op rides inside the same signed Change, and
  `verifyRelease`'s exact-set check already authenticates it. Nothing
  about FLINT, the sync protocol, or the channel format changes.
- **Older readers ignore the new consts.** `parseRelease` reads the
  required four and skips the rest — the same additive rule `apps.txt`
  v2 used for trailing `key=` fields. A v1 STORE installs a
  catalog-bearing release today; it just doesn't display the fields.
- **The additive rule is "signed extras are ignored," never "extras
  are tolerated."** An unsigned extra atom still fails
  `release_mismatch`. Unknown *optional* consts are authenticated by
  signature and ignored for meaning — a reader must not render,
  interpret, or trust a const it does not know.
- Symmetric posture for writers: a producer may emit any const this
  grammar defines (or a later ADR adds, D6). Emitting a const outside
  the grammar is legal — it is signed, after all — but readers treat
  it as unknown.

### D5. Publisher identity is derived, never declared

The publisher fingerprint a catalog shows for a stream is **the
`author` key of the stream's head Change** — the key that signed it —
checked against `TRUSTED.TXT`: pinned (not `key_unknown`), not revoked
(not `key_revoked`). It renders as 64 lowercase hex, alongside the
keyring `name=` label when the key is pinned. If the head Change was
signed by a different key than earlier history (rotation, handoff), the
fingerprint follows the head — the publisher is whoever currently
controls the stream.

**No const may claim identity.** `ReleasePublisher`, `ReleaseAuthor`,
`ReleaseKey`, `ReleaseFingerprint`, `ReleaseSignedBy`, and every other
identity-asserting name are permanently outside this grammar. A
manifest that declares who published it is a forgery waiting for a
renderer: the value is self-asserted, so it can only lie. Writers must
not emit such consts; readers must not interpret any const as
publisher, author, signer, or trust information — identity comes from
the signature chain alone.

### D6. The `Release*` namespace

- The manifest grammar owns the `Release` prefix inside `release.go`.
  A new `Release*` const enters the grammar only through this ADR (as
  an amendment) or a new ADR that cites this section — that is the
  extension path, and it is how later arcs extend the format without
  renegotiating it.
- **`ReleaseCaps` is reserved for ADR 0054 (M113).** Its grammar — a
  publisher's capability *request*, declarative only — is that ADR's
  decision and is deliberately unspecified here. M110 readers ignore it
  under D4. Reserving the name prevents a well-meaning card from
  squatting the namespace before M113 pins the semantics.
- D5's exclusion is a namespace rule too: no future amendment may add
  an identity-claiming const.

### D7. The icon blob

`ReleaseIconSHA256` names a blob fetched over the same untrusted
channel as the ELF, as channel member **`<stream>/icon`** — a fixed
name, because `<NAME>.ICON` cannot fit the 32-byte member bound a
max-length `ReleaseName` already saturates with `<NAME>.ELF`, and
because the icon is per-stream anyway (one release stream = one app).

- The blob is fetched **on demand** — when a consumer wants to render
  it — never eagerly by `install`. `store install` does not read it;
  the manifest field is a pin, not a fetch order.
- A consumer that fetches it reads at most `MaxIconBytes` = **64 KiB**
  (the already-accepted `release.go` bound; an icon past it is a soak,
  not art) → `file_too_large`. An absent member is `channel_missing`.
  Fetched bytes are used only when `sha256(blob) ==
  ReleaseIconSHA256`; anything else is `icon_mismatch` and is never
  rendered.
- The blob's pixel/vector format is the consumer's concern and is not
  pinned here. The candidate is the ADR 0041 SVG subset (resolution
  independent, already in tree). An icon the renderer cannot decode is
  not displayed; it is not an install refusal.

## Non-goals

| Non-goal | Where it goes |
|---|---|
| `ReleaseCaps` grammar and semantics | ADR 0054 (M113) — the name is reserved, nothing more |
| Any flint-server change | None needed — the catalog is a fold; the cross-repo card is dropped by the index's design direction |
| Icon pixel format, screenshots, other media | Consumers pick formats; screenshots would follow D7's sha-pinned-blob shape if ever wanted |
| `store ls`/`info` rendering, GUI browse | M110b (#2404), M110c (#2405) implement this ADR |
| Signed-by-default relaxation, unsigned or self-signed software | Never — the keyring is the whole security story (index non-goals) |
| Discovery / a public directory | A later arc; flintd stays self-hosted |
| `apps.txt` as the installed manifest | Unchanged — `ReleaseManifestRow` is still what install writes |

## Acceptance

Owner review of this file. Every D3/D7 field is implementable by M110b
without renegotiation — the grammars, bounds, refusal names, and the
icon member are all pinned above.
