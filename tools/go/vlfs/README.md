# tools/go/vlfs — `mkfs.vlfs`, the VLFS formatter/checker

M100c (issue #2308, arc #2302). VLFS is the guest's journaled filesystem on a
dedicated virtio-blk image; the on-disk format is frozen in
`docs/decisions/0050-vlfs.md` (ADR 0050 §D3/D5/D7). This directory is one of
two implementations of those bytes — the other is the kernel reader in
`kernel/src/vlfs/` — and the committed `kernel/src/vlfs/testdata/*.regions`
goldens are the proof that both agree byte-for-byte.

## Usage

```bash
go run . -mib 64 /tmp/vlfs.img                  # format (default 64 MiB)
go run . -bytes 16777216 /tmp/vlfs.img          # exact size (block-aligned)
go run . -volume-id 5eed5eed -time 1760000000   # deterministic fields
go run . --check /tmp/vlfs.img                  # read-only structural check
go run . --emit-regions /tmp/vlfs.img           # dump non-zero regions

# sealed v2 volumes (ADR 0061)
go run . --seal --passphrase-file pass.txt /tmp/vlfs.img
go run . --check --passphrase-file pass.txt /tmp/vlfs.img
echo hunter2 | go run . --check --passphrase-file - /tmp/vlfs.img
```

`--check` is the offline half of fsck.vlfs (D5): superblock pair + geometry,
journal scan (`journal_unreplayed`/`journal_torn` are informational), inode
checksums and kinds, extent bounds/overlap, bbitmap consistency, and a
single-parent tree under inode 1 at depth ≤ 8 — all evaluated against the
as-replayed state computed in memory. It never repairs.

`--seal` writes a format-v2 volume: every block in the sealed span
`[2, tag_first)` is ChaCha20-Poly1305 ciphertext under a minted DEK, with
nonces and tags in a plaintext tag region and the DEK wrapped into the
superblock under a PBKDF2-HMAC-SHA256 KEK (iterations calibrated to ~1 s at
seal time, or pinned with `-kdf-iters`). The passphrase comes only from a
file or stdin (`--passphrase-file -`), never argv. `--check` on a sealed
image verifies the v2 structure alone without the passphrase; with it,
`bad_block_auth` names any block whose tag fails and
`sealed_bad_passphrase` is a failed DEK unwrap. The AEAD is an in-tree
port (`aead.go`) pinned to the same RFC 8439 vectors as
`kernel/src/aead.zig`; there is still no third-party module.

## Golden fixtures

A valid volume's floor is 16 MiB (D7), so the committed goldens are
`.regions` text: the image's non-zero byte runs plus its size — a complete
byte-exact description that stays KiB-scale. Canonical copies live in
`kernel/src/vlfs/testdata/` (the Zig tests `@embedFile` them; they cannot
reach outside the kernel package). Regenerate after any format-affecting
change:

```bash
cd tools/go/vlfs
go test -run Golden -update
```

Then run both suites: `go test ./...` here and `zig test kernel/src/vlfs/vlfs.zig`
(or the unified `zig build test`) from the repo root — the Zig side asserts
the same regions byte-for-byte.

## Build

```bash
bash tools/go/vlfs/build.sh   # .build/go/mkfs.vlfs
```

Stdlib only. Tested with the stock host toolchain (go 1.27).
