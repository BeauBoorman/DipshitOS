# live-vlfs-blk.spec -- M100b (issue #2307, ADR 0050) class-B
#
# gate: the virtio-blk data-disk path on real VZ hardware. The runner's
# --data-disk attaches a second DID-0x1042 function named "virelai-vlfs"
# (blockDeviceIdentifier); the guest collects every blk function pre-exit,
# re-arms post-MMU, names each by VIRTIO_BLK_T_GET_ID, and the boot probe
# writes one sector, FLUSHes, reads it back, and restores. Two legs
# (issue #2381: the probe targets a scratch block, never live data):
#   01 — a VLFS image (golden 16 MiB regions + a seeded journal-tail
#     sector): the probe must pick the last sector of the journal region
#     (LBA 0x100f — journal blocks 2..513, tail sector (2+512)*8-1), the
#     volume must still mount, and the post-run image must be byte-exact:
#     restore lands and a clean mount writes nothing.
#   02 — a raw 64 MiB scratch image (last sector seeded): no valid
#     superblock, so the probe keeps the last-sector target (LBA 0x1ffff)
#     and the mount names its not_vlfs refusal.
# Asserts: both functions identified by name, the vlfs capacity line, and
# the probe marker with a negotiated flush (flush=1 — a device that cannot
# flush fails this gate honestly, since ADR 0050's ordering contract needs
# the barrier, not a hint). What this proves: attach + identity + RW +
# completed-FLUSH on the wire — NOT the journal's crash ordering (M100e
# owns that; a clean run leaves the image byte-untouched by restore).

vgate_name live-vlfs-blk "M100b (#2307) class-B: virtio-blk RW + --data-disk attach"

vgate_setup_python <<'PY'
import os
from pathlib import Path
run = Path(os.environ["RUN_DIR"])
sig = b"HOST-KNOWN-PATTERN"

def seed(sector_bytes, sig=sig):
    sector_bytes[:len(sig)] = sig
    for i in range(len(sig), len(sector_bytes)):
        sector_bytes[i] = (i * 17 + 3) & 0xFF

# Leg 01: the golden empty 16 MiB VLFS volume rebuilt from its .regions
# description, with a host-known pattern seeded into the last sector of
# the journal region (blocks 2..513 -> byte offset 0x100f*512) so the
# probe's save/write/readback/restore runs against non-zero contents.
img = None
for line in Path("kernel/src/vlfs/testdata/empty-16m.regions").read_text().splitlines():
    if not line or line.startswith("#") or line == "vlfs-regions 1":
        continue
    if line.startswith("bytes "):
        img = bytearray(int(line[6:]))
        continue
    off, hexs = line.split(" ", 1)
    img[int(off):int(off) + len(hexs) // 2] = bytes.fromhex(hexs)
assert img is not None and len(img) == 16 * 1024 * 1024
seed(memoryview(img)[0x100F * 512:0x100F * 512 + 512])
(run / "vlfs.img").write_bytes(bytes(img))
(run / "vlfs.expected.img").write_bytes(bytes(img))

# Leg 02: the ADR's default shape, a 64 MiB raw scratch image — no
# superblock, so the probe keeps the last-sector target. The last 512
# bytes carry the same known pattern.
data = bytearray(64 * 1024 * 1024)
seed(memoryview(data)[-512:])
(run / "d.img").write_bytes(bytes(data))
(run / "d.expected.img").write_bytes(bytes(data))
PY

vgate_run 01 -- --data-disk '$RUN_DIR/vlfs.img' --expect 'vlfs-probe: write+readback ok' --timeout 60

vgate_assert 01 output-contains 'data-disk: ENABLED'
vgate_assert 01 serial-contains "id='virelai-vlfs' vlfs"
vgate_assert 01 serial-contains 'not_vlfs_disk'
vgate_assert 01 serial-contains 'disk: 0x0000000000008000 sectors id=virelai-vlfs'
vgate_assert 01 serial-contains 'vlfs-probe: write+readback ok lba=0x000000000000100f flush=1 restored'
vgate_assert 01 serial-contains 'vlfs: mounted /disk'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, sys
from pathlib import Path
run = Path(os.environ["RUN_DIR"])
# The probe wrote the journal tail and restored it; a clean mount writes
# nothing — the post-run image must be byte-exact with its seeded copy.
if (run / "vlfs.img").read_bytes() != (run / "vlfs.expected.img").read_bytes():
    sys.exit("vlfs.img differs from its pre-run bytes (probe restore or clean-mount write leaked)")
print("vlfs.img byte-exact after probe + mount")
PY

vgate_run 02 -- --data-disk '$RUN_DIR/d.img' --expect 'vlfs-probe: write+readback ok' --timeout 60

vgate_assert 02 output-contains 'data-disk: ENABLED'
vgate_assert 02 serial-contains "id='virelai-vlfs' vlfs"
vgate_assert 02 serial-contains 'not_vlfs_disk'
vgate_assert 02 serial-contains 'disk: 0x0000000000020000 sectors id=virelai-vlfs'
vgate_assert 02 serial-contains 'vlfs-probe: write+readback ok lba=0x000000000001ffff flush=1 restored'
vgate_assert 02 serial-contains 'vlfs: mount refused not_vlfs'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os, sys
from pathlib import Path
run = Path(os.environ["RUN_DIR"])
if (run / "d.img").read_bytes() != (run / "d.expected.img").read_bytes():
    sys.exit("d.img differs from its pre-run bytes (probe restore leaked)")
print("d.img byte-exact after probe")
PY

# --- M172d (#3037, ADR 0061): the sealed v2 mount -------------------------
#
#   03 — a sealed 16 MiB image (mkfs.vlfs --seal): the runner types the
#     passphrase at the prompt; the volume unseals, mounts, and a write +
#     readback cross the AEAD block layer. serial-absent 'swordfish' is
#     the echo-suppression evidence — the passphrase never hits serial.
#   04 — the same image, five wrong answers: the named wrong-passphrase
#     lines count down, the fifth locks out, the mount refuses sealed,
#     and the boot continues share-only (a shell prompt still arrives).
#   05 — the same image, no input: the 120 s idle budget ends unsealing
#     with the named no-passphrase line — /disk is not mounted and the
#     boot continues share-only.
# What this proves: the prompt's budget/timeout, DEK unwrap, per-block
# AEAD on the live mount path, and share-only continuation — NOT the
# crash/canary surface (M172e owns that) or the v1 journal ordering
# (M100e). Passphrases never appear in any serial output.

vgate_setup_python <<'PY'
import os, subprocess
from pathlib import Path
run = Path(os.environ["RUN_DIR"])
subprocess.check_call(["go", "-C", "tools/go/vlfs", "build", "-o", str(run / "mkfs.vlfs"), "."])
(run / "pass.txt").write_text("swordfish\n")
for i, name in enumerate(("sealed.img", "sealed2.img", "sealed3.img")):
    subprocess.check_call([str(run / "mkfs.vlfs"), "--seal",
                           "--passphrase-file", str(run / "pass.txt"),
                           "-mib", "16", "-kdf-iters", "4000",
                           "-volume-id", "0x5eed5eed0000030%d" % i, "-time", "1760000000",
                           str(run / name)])
    print("built %s (v2 sealed, kdf-iters 4000)" % name)
(run / "script-pass.txt").write_text("swordfish\n")
(run / "script-sealed.txt").write_text(
    "write /disk/SEAL.TXT sealed volume writes through aead\n"
    "vf cat /disk/SEAL.TXT\n"
    "vf ls /disk\n"
    "echo sealed-mount-done\n")
(run / "script-wrong.txt").write_text(
    "bad-pass-1\nbad-pass-2\nbad-pass-3\nbad-pass-4\nbad-pass-5\n")
(run / "script-lockout.txt").write_text("echo sealed-lockout-done\n")
PY

vgate_run 03 -- --data-disk '$RUN_DIR/sealed.img' \
    --script '$RUN_DIR/script-pass.txt' --script-after 'vlfs: sealed — passphrase: ' \
    --script2 '$RUN_DIR/script-sealed.txt' --script2-after 'virelai> ' \
    --script-expect 'sealed-mount-done' --timeout 120

vgate_assert 03 output-contains 'data-disk: ENABLED'
vgate_assert 03 serial-contains 'vlfs: sealed — unsealed'
vgate_assert 03 serial-contains 'vlfs: mounted /disk'
vgate_assert 03 serial-contains 'write: ok (journaled 33 bytes to disk:SEAL.TXT)'
vgate_assert 03 serial-contains 'vf: cat ok bytes=33'
vgate_assert 03 serial-contains 'SEAL.TXT'
vgate_assert 03 serial-absent 'swordfish'
vgate_assert 03 serial-absent 'vlfs: mount refused'
vgate_assert 03 serial-absent '[EXC] parking:'

vgate_run 04 -- --data-disk '$RUN_DIR/sealed2.img' \
    --script '$RUN_DIR/script-wrong.txt' --script-after 'vlfs: sealed — passphrase: ' \
    --script2 '$RUN_DIR/script-lockout.txt' --script2-after 'virelai> ' \
    --script-expect 'sealed-lockout-done' --timeout 120

vgate_assert 04 serial-contains 'vlfs: sealed — wrong passphrase (4 left)'
vgate_assert 04 serial-contains 'vlfs: sealed — wrong passphrase (3 left)'
vgate_assert 04 serial-contains 'vlfs: sealed — wrong passphrase (2 left)'
vgate_assert 04 serial-contains 'vlfs: sealed — wrong passphrase (1 left)'
vgate_assert 04 serial-contains 'vlfs: sealed — locked out, /disk not mounted'
vgate_assert 04 serial-contains 'vlfs: mount refused sealed'
vgate_assert 04 serial-absent 'vlfs: mounted /disk'
vgate_assert 04 serial-absent 'bad-pass-1'
vgate_assert 04 serial-absent '[EXC] parking:'

vgate_run 05 -- --data-disk '$RUN_DIR/sealed3.img' --expect 'virelai> ' --timeout 240

vgate_assert 05 serial-contains 'vlfs: sealed — no passphrase, /disk not mounted'
vgate_assert 05 serial-contains 'vlfs: mount refused sealed'
vgate_assert 05 serial-contains 'virelai> '
vgate_assert 05 serial-absent 'vlfs: mounted /disk'
vgate_assert 05 serial-absent 'vlfs: sealed — unsealed'
vgate_assert 05 serial-absent '[EXC] parking:'
