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
