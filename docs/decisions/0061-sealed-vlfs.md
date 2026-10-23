# ADR 0061: Sealed VLFS — a passphrase-unlocked encrypted guest disk (format v2)

- Date: 2026-10-22
- Status: **Accepted** — shipped by the sealed-VLFS arc (index #3024;
  all five cards closed): the sealed-mount reservation is live (ADR 0007
  X6 :2886); this ADR is the card (#3028), and the arc implemented it in
  the filed order: card #3030 kernel ChaCha20-Poly1305 +
  PBKDF2-HMAC-SHA256 (card #3030), card #3031 `mkfs.vlfs --seal` and the
  v2 format (card #3031), card #3037 the sealed mount — boot prompt,
  unwrap, block AEAD, lockout (card #3037), card #3043 the canary gate
  re-run under encryption (card #3043). The D-numbers are the owner
  decisions recorded on the index #3024 (card #3024), continuing the
  numbering ADR 0050 closed at D7; this document is their record
  (D11).
- Card: **#3028** (index #3024 **#3024**) — card 1 of 5. This is the
  one doc for the arc (AGENTS.md: one doc per arc, not four).
- Related: ADR 0050 (VLFS v1 — the format, journal ordering, and
  mount model this seals; its status flips to Accepted in the same
  change), ADR 0059 (warm checkpoints — D3's `state.vzsave` is why a
  sealed boot refuses save-state), ADR 0024 (trust baseline).

> A copied or stolen `vlfs.img` must reveal nothing. The guest's own
> disk — shell history, notification history, app data roots — is a
> host file like any other, and the threat that matters is the one a
> filesystem cannot negotiate with: the image leaving the machine it
> was written on. Sealing makes the image ciphertext at rest under a
> key that exists only inside a boot that was handed a passphrase.
> Everything else — format changes, the prompt, the crash contract —
> is in service of that one property, and this ADR pins it on paper
> before cards #3030, #3031, #3037, #3043 write a byte of code.

## Grounding (verified against `origin/main`, 2026-10-22)

**Observed** means checked in the tree; **inferred** means reasoning
only.

- **v1 data blocks are raw.** Block payloads are plaintext 4096-byte
  blocks (`kernel/src/vlfs/vlfs.zig:44,282-295`; ADR 0050 D3) — there
  is no per-block room for a tag, so sealing is a format change:
  **v2**, not a flag on v1.
- **The block hook is per 512-byte sector.** `disk.zig:260-285`
  exposes the `virelai-vlfs` function as a `SectorSource`
  (`blkRead`/`blkWrite`/`blkFlush`); the AEAD layer sits on the
  4096-byte block layer above it, never on the wire format.
- **The mount point already exists and already fails soft.**
  `main.zig:949-960` mounts `/disk` via `vlfs_disk.attachBlk()` and,
  on refusal, prints `vlfs: mount refused <name>` and continues
  **share-only** — the exact seam the unseal prompt and the lockout
  reuse. `SECRETS.TXT` loads earlier, at `main.zig:818`, before
  `/disk` mounts.
- **The kernel has a CSPRNG, not an AEAD.** `csprng.zig:1-20` is a
  freestanding ChaCha20 stream seeded with 64 bytes from the
  virtio-entropy device at boot; a failed device read falls back to
  a fixed deterministic key and the module reports
  `seeded() == false` honestly. The only AEAD in-tree is at EL0
  (`user/src/lib/crypto/aead.zig:1-20`, RFC 8439 §2.8, class-A
  `zig test` against the §2.8.2 vector); EL0's AES cannot decrypt
  and is not constant-time (`user/src/lib/crypto/aes.zig:1-20`).
  The kernel port is card #3030 (card #3030); the EL0 AES is rejected
  for this purpose on both counts.
- **There is no non-echo input path.** `secret.zig:50-62` records
  the D8 contract: secrets are host-provisioned, there is no
  `sys_secret_set`, and nothing reads a secret at boot. The unseal
  prompt is the kernel's own console read — see D10.
- **A save-state captures guest RAM.** ADR 0059 D3 (line 208):
  `state.vzsave` = guest RAM, vCPU registers, device state via
  `saveMachineStateTo`. An unwrapped DEK and every decrypted block
  live in that RAM.
- **The space for v2 already exists.** The v1 superblock carries
  400 reserved bytes at +108 and each inode 32 reserved bytes at
  +92 (ADR 0050 D3); v2 consumes both without growing either
  structure.
- **The crash gate is already the right shape.**
  `tools/gate/specs/live-vlfs-crash.spec:1-40` runs the kill/remount
  pair at `vgate_repeat 5` (line 29 — K=5 is the standing record)
  and builds `mkfs.vlfs` in setup; its honesty bound carries over
  verbatim: `vm.stop` proves ordering at completed-request
  granularity, not FLUSH correctness under a host power cut.
- **`mkfs.vlfs` exists and is stdlib-only Go** (`tools/go/vlfs/README.md`);
  its `--check` is the offline fsck half. The seal-time KDF
  calibration and the host-side CSPRNG (`crypto/rand`) are its job
  in card #3031.
- **VZ exposes no TPM or sealed-key device to the guest** —
  consistent with the hardware contract's device inventory; treated
  as **[inferred]** from the absence of any such device in the
  runner configuration, not from an SDK citation.

## Threat model — what sealing is for, and what it is not

**In scope: a copied or stolen image at rest.** The `vlfs.img` file
is read by a backup, a sync client, another account on the Mac, or
anyone holding the disk it sits on. Under sealing, every byte of
guest content on that image is ciphertext; the image alone — with
its superblock, its tag region, and its wrapped DEK — yields
nothing without the passphrase. Offline guessing is bounded by the
KDF cost alone (D10's honest limit).

**Out of scope, stated so no card overclaims:**

- **A live compromised host.** The host owns the VM's RAM and
  device path wholesale; sealing changes nothing about it.
- **RAM capture.** The unwrapped DEK lives in guest kernel memory
  for the life of the mount; anything that reads that memory reads
  the key.
- **Warm checkpoints of an unsealed VM.** A `state.vzsave` taken
  after unseal is the image plus the key — the stolen-image threat
  verbatim. The default checkpoint rule applies (D10): **sealed
  boots refuse save-state.**

## D8. `/host` secrets stay host-provisioned — not this wave

The index's secret-migration item is not carded. `SECRETS.TXT` and
every named secret live on the `/host` share and load
(`main.zig:818`) before `/disk` mounts; moving them changes who
provisions them, which is a different decision than encrypting the
disk. Sealing `/disk` therefore does not move the secrets' trust
boundary, and this ADR claims no improvement for them. Host
keychain escrow for the passphrase is likewise out of scope.

## D9. Keys, cipher, and the nonce rule

### Key hierarchy

```
passphrase
   │  PBKDF2-HMAC-SHA256(salt = 16 B random, iters = stored,
   │                    calibrated to ~1 s on the reference host
   │                    at seal time)
   ▼
KEK (32 B) ──unwrap──▶ DEK (32 B random, minted at --seal)
```

- The DEK is minted randomly at format/seal time and never leaves
  the volume except wrapped. The v2 superblock stores the wrap:
  `wrap_nonce` (12 B), the 32-byte ciphertext, and the DEK's **own
  16-byte AEAD tag** under the KEK — an unwrap is an AEAD open, so a
  wrong passphrase and a corrupt wrap are the same honest failure:
  authentication fails, nothing is released.
- The KEK exists only at the unseal prompt; it is derived, used,
  and dropped. The DEK is what lives in kernel RAM for the mount.
- **A passphrase change rewraps without re-encrypting.** New salt,
  new iteration count, new wrap nonce, same DEK: the only blocks
  touched are the superblock pair. Rotating the DEK itself would
  re-encrypt the volume and is a different tool (Deferred).

### Cipher and nonces

- **ChaCha20-Poly1305 per 4096-byte block** — the RFC 8439 §2.8
  construction already class-A-tested at EL0 (`aead.zig`), ported
  into the kernel by card #3030. The AEAD unit is the VLFS block,
  not the device sector.
- **Fresh random 96-bit nonce on every block write**, drawn from
  the kernel CSPRNG — including rewrites of the same block. The
  nonce need not be secret; it must never repeat under one DEK.
- **Nonce and tag (28 B per sealed block) live in a tag region**
  (format below), not inline — v1's block bodies are full.
- **AAD = volume UUID ‖ block number** (`volume_id` u64 LE ‖
  block number u32 LE): the tag binds the ciphertext to this
  volume and this position, so sealed blocks cannot be swapped —
  between volumes, or between offsets within one.
- **Sealed span:** every block number in `[2, tag_first)` —
  journal DESC/PAYLOAD/COMMIT, bitmaps, inode table, extent
  blocks, and data — is stored as ciphertext. Blocks 0–1
  (superblocks; they carry the wrapped DEK and must be readable
  before unseal) and `[tag_first, volume_blocks)` (the tag
  region; its contents are public nonces and tags) are plaintext.
- **Unseeded CSPRNG refuses sealing.** If `csprng.seeded()` is
  false the deterministic fallback would repeat nonces; a sealed
  mount refuses by name rather than mint catastrophic ciphertext.

### The birthday bound per DEK

Random 96-bit nonces collide with probability ≤ n²/2⁹⁷ after n
sealed-block writes under one DEK. The volume caps at 262,144
blocks (ADR 0050 D7), so even 2³² sealed-block writes —
≈ 16,000 full-volume rewrites — hold the bound at ≈ 2⁻³³
(~10⁻¹⁰). A (key, nonce) repeat is fatal — it exposes the
keystream XOR of the two plaintexts and the Poly1305 one-time key
to forgery — so the bound is written down here and the DEK is
documented as volume-lifetime-fixed: passphrase changes rewrap,
they do not rotate. At this workload the bound is a stated
argument, not an enforced counter.

## Format v2 — the on-disk changes

`version` (+4) = 2. Everything not listed below is ADR 0050 D3
verbatim.

### Superblock fields (inside the 400 reserved bytes at +108)

```
+108  seal_magic   u32   0x53464C53 ("SLFS") — sealed-volume mark
+112  kdf_id       u32   1 = PBKDF2-HMAC-SHA256
+116  kdf_iters    u32   stored; calibrated ~1 s at seal time
+120  kdf_salt     16 B  random at seal and at each rewrap
+136  wrap_nonce   12 B  random at seal and at each rewrap
+148  wrapped_dek  32 B  DEK ciphertext under the KEK
+180  wrap_tag     16 B  AEAD tag of the wrap
+196  tag_first    u32   first tag-region block
+200  tag_blocks   u32
+204  reserved          zero through +508 (cksum)
```

The superblock pair stays plaintext and ping-ponged exactly as v1;
`seal_magic` distinguishes a sealed v2 volume from an unsealed one
(v2 superblocks without it are malformed: `bad_superblock`).

### Tag region

The last region of the volume: `tag_blocks` tag blocks ending at
`volume_blocks`. Each tag block is **146 entries × 28 B** = 4,088 B
(`{nonce 12 B, tag 16 B}` per sealed block) with an 8-byte zero
tail. The entry for sealed block `b` (`2 ≤ b < tag_first`) is slot
`b − 2`: tag block `tag_first + (b−2)/146`, byte offset
`((b−2) mod 146) × 28`. `mkfs.vlfs` solves the fixpoint
`tag_blocks = ⌈(volume_blocks − 2 − tag_blocks)/146⌉` — 28 tag
blocks on the 16-MiB floor volume, ~1,784 on the 1-GiB cap (under
1% of the volume either way).

Tag-region home blocks are plaintext (their contents are public),
which is the single non-recursive exception to the sealed span.
Their atomicity is the journal's, and their malleability buys an
attacker only refusals: a tampered tag makes its block fail open,
never read back wrong. Block-granularity rollback — replaying an
older (nonce, ciphertext, tag) triple — is undetectable and stated
as a limit below.

### Inode reservation (D13)

Six of the inode's 32 reserved bytes at +92 are claimed:

```
+92   owner_uid   u32   minted 0 at format/create; unenforced in v2
+96   mode        u16   minted 0; unenforced in v2
+98   reserved    26 B  zero
```

Ownership is deferred (D13): the bytes are reserved now so a later
ownership card does not reformat the volume. No enforcement,
policy, or syscall change is implied by this reservation.

### v1 mounts unchanged

`version` 1 mounts exactly as today: no seal fields consulted, no
tag region, all blocks plaintext, the same code path with the same
named refusals. Sealing is opt-in per volume at format time
(`mkfs.vlfs --seal`, card #3031); nothing about an unsealed
deployment changes.

## Crash semantics

- **The tag region is journaled with metadata.** A commit carries
  the sealed payloads of every touched block *and* the updated tag
  blocks in one transaction; the commit line is unchanged (ADR 0050
  D4: DESC + PAYLOAD + COMMIT, then FLUSH). A journaled tag block
  occupies a journal block number, which is itself inside the
  sealed span — journal bytes are ciphertext uniformly, so a sealed
  volume's journal is unreadable without the passphrase, and a
  forged transaction tail fails authentication where a v1 tail
  fails checksum.
- **Replay is unchanged in shape.** Mount order on a sealed
  volume: superblock (plaintext) → unseal prompt → DEK → the
  existing D5 scan, with every journal block authenticated before
  it is parsed and every replayed payload block authenticated
  before it lands. A record that fails AEAD open truncates the
  journal at that point, exactly as a checksum failure does.
- **A torn data write reads back as an authentication failure,
  never as wrong plaintext.** Any sealed block whose tag does not
  verify refuses by name (`bad_block_auth`); there is no path that
  serves unauthenticated bytes. Because home blocks are written
  only at checkpoint, post-commit, a mid-checkpoint kill replays
  the committed transaction and re-lands both payload and tag —
  the same convergence v1 proves, now authenticated.
- **The proof is card #3043's K=5 crash spec** (card #3043):
  `live-vlfs-crash` re-run under encryption — the spec already runs
  at `vgate_repeat 5` and builds `mkfs.vlfs` in setup, so the
  canary is the standing gate with the disk sealed, not a new
  harness. Its honesty bound is inherited: completed-request
  granularity on `vm.stop`, not host-power-cut FLUSH.

## D10. Unseal at boot — the prompt, the lockout, and the checkpoint rule

- **A kernel prompt at the `/disk` mount.** When the v2 superblock
  shows `seal_magic`, the mount path (`main.zig:949-960`) prompts
  on the console UART before INIT runs. The kernel owns the UART,
  so the read is echo-suppressed at the prompt itself — there is
  no non-echo input path in-tree today (secret.zig:50-62), and
  building one is part of card #3037, not a syscall and never an
  EL0 surface. The passphrase reaches kernel memory only; the
  serial transcript records the prompt, never the input.
- **Five attempts per boot.** Each failure is an AEAD unwrap
  refusal (`sealed_bad_passphrase`) and a re-prompt; the fifth
  refusal ends unsealing for the boot.
- **No input for 120 s, or lockout, continues share-only** — the
  existing behaviour at `main.zig:950-952`: a named line
  (`sealed_timeout`, `sealed_locked`) on the serial transcript and
  a boot that proceeds without `/disk`. A sealed disk is an
  enhancement, never a requirement — the same rule v1 pins.
- **Honest limit: there is no unattended boot.** VZ exposes no
  TPM, so nothing on the host can hold the DEK or attest the boot;
  every sealed boot waits for a human. The lockout slows guessing
  at the console only — against the stolen image itself, the sole
  barrier is the KDF cost (~1 s per guess on the reference host at
  seal time), so passphrase strength is the whole defense and a
  weak passphrase stays weak.
- **Sealed boots refuse save-state.** `state.vzsave` is guest RAM
  (ADR 0059 D3); on a boot that unsealed `/disk` it captures the
  DEK and the decrypted block cache. `vgate_checkpoint` and
  `--vz-restore` save on a sealed boot are refused by name — the
  enforcement point is card #3037's, the rule is pinned here.

## Limits (stated so no card overclaims)

- **No freshness.** Block-granularity rollback to an older valid
  (nonce, ciphertext, tag) triple is undetectable; a whole-image
  rollback mounts as the older state. There is no monotonic
  counter available to fix this — same root cause as no unattended
  boot.
- **Offline guessing is bounded by the KDF cost alone.** ~1 s per
  candidate on the reference host; the iteration count is stored,
  so an attacker pays the calibration, not more.
- **DEK rotation re-encrypts the volume** and is not provided;
  the birthday-bound margin makes it a hygiene question, not a
  lifetime limit.
- **No side-channel claim.** The kernel port inherits the crypto
  library's stated posture (ADR 0023): correctness pinned by
  known-answer tests, no side-channel hardening claimed.
- **A killed sealed boot leaves the DEK nowhere durable** — RAM
  dies with `vm.stop`; the image never holds it unwrapped.

## Not this wave

- Moving `/host` secrets onto the sealed volume (D8 — their
  provisioning boundary is a separate decision).
- Host keychain escrow or any unattended-unseal machinery.
- Enforcement of `owner_uid`/`mode` (D13 reserves the bytes only).
- Code. This ADR is the card.

## Deferred questions

- **DEK rotation tooling.** A `mkfs.vlfs --rekey` that
  re-encrypts under a fresh DEK; the birthday bound sets the
  hygiene bar, not the format.
- **Unattended unseal.** Would require a hardware root VZ does
  not provide; if a platform ever offers one, it lands as a new
  ADR, not an amendment here.
- **Deferred-checkpoint interplay.** ADR 0050's deferred
  checkpoint batching is orthogonal to sealing but changes which
  blocks are dirty when; a card taking it up must re-derive the
  tag-update ordering against this ADR.
- **Ownership enforcement.** The consumer of the D13 bytes is a
  later card; this ADR only keeps its format seat.

## Touches

```
docs/decisions/0061-sealed-vlfs.md    (this file)
docs/decisions/0050-vlfs.md           (status → Accepted + pointer)
```

Implementers: card #3030 (kernel crypto), card #3031 (`mkfs.vlfs
--seal`, v2 layout, `--check`), card #3037 (sealed mount, prompt,
lockout, checkpoint refusal), card #3043 (encrypted K=5 canary).
