# live-vlfs-blk.spec -- M100b (issue #2307, ADR 0050) class-B
#
# gate: the virtio-blk data-disk path on real VZ hardware. The runner's
# --data-disk attaches a second DID-0x1042 function named "virelai-vlfs"
# (blockDeviceIdentifier); the guest collects every blk function pre-exit,
# re-arms post-MMU, names each by VIRTIO_BLK_T_GET_ID, and the boot probe
# writes one sector, FLUSHes, reads it back, and restores. Asserts: both
# functions identified by name, the vlfs capacity line, and the probe
# marker with a negotiated flush (flush=1 — a device that cannot flush
# fails this gate honestly, since ADR 0050's ordering contract needs the
# barrier, not a hint). What this proves: attach + identity + RW +
# completed-FLUSH on the wire — NOT the journal's crash ordering (M100e
# owns that; a clean run leaves the image byte-untouched by restore).

vgate_name live-vlfs-blk "M100b (#2307) class-B: virtio-blk RW + --data-disk attach"

vgate_setup_python <<'PY'
import os
from pathlib import Path
# The ADR's default shape: a 64 MiB raw image. The last 512 bytes carry a
# known pattern so the probe's save/write/readback/restore runs against
# non-zero prior contents.
img = Path(os.environ["RUN_DIR"]) / "d.img"
data = bytearray(64 * 1024 * 1024)
sig = b"HOST-KNOWN-PATTERN"
data[-512:-512 + len(sig)] = sig
for i in range(len(sig), 512):
    data[-512 + i] = (i * 17 + 3) & 0xFF
img.write_bytes(bytes(data))
PY

vgate_run 01 -- --data-disk '$RUN_DIR/d.img' --expect 'vlfs-probe: write+readback ok' --timeout 60

vgate_assert 01 output-contains 'data-disk: ENABLED'
vgate_assert 01 serial-contains "id='virelai-vlfs' vlfs"
vgate_assert 01 serial-contains 'not_vlfs_disk'
vgate_assert 01 serial-contains 'disk: 0x0000000000020000 sectors id=virelai-vlfs'
vgate_assert 01 serial-contains 'vlfs-probe: write+readback ok lba=0x000000000001ffff flush=1 restored'
vgate_assert 01 serial-absent '[EXC] parking:'
