# live-verified-boot -- M113b (#2418, ADR 0054 Part I): verified + measured
# boot on the new opt-in runner flag family.
#
# exec-order: assert-proven -- all runs boot independent VMs with private
# --vars stores; tamper legs halt before any script runs (their serial is
# empty by definition, asserted), so nothing orders on another run.
#
# Four legs:
#   ok              -- the canonical image boots under Secure Boot with its
#                      Authenticode digest enrolled in db; the host
#                      recomputes BOTH receipt digests independently
#                      (Authenticode of the extracted BOOTAA64.EFI, raw
#                      SHA-256 of KERNEL.BIN) and pins the serial lines +
#                      the RCPT.TXT share file to them.
#   tampered-loader -- one flipped byte in BOOTAA64.EFI, digest NOT in db:
#                      the firmware refuses the image — VM halts with zero
#                      serial bytes and no receipt (the M113a probe's
#                      observed refusal shape, now gated under the flag).
#   tampered-kernel -- canonical BOOTAA64.EFI, one flipped byte in
#                      KERNEL.BIN: the loader's pin check fires — the named
#                      refusal `kernel_hash_mismatch` lands in the per-run
#                      variable store (the ESP \REFUSED.TXT receipt is
#                      written too, but ESP writes die in the discarded
#                      ASIF overlay, so the NVRAM copy is the assertion).
#   off             -- NO --secure-boot flags: the byte-identical path —
#                      the same store-open code as every spec, the boot
#                      reaches userspace, and the measured chain receipt
#                      still publishes (measurement is always on; the
#                      firmware anchor is the opt-in part).

vgate_name live-verified-boot "verified+measured boot: db-pinned loader, pinned KERNEL.BIN, chain receipt"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file boot.txt <<'EOF'
echo vboot-rcpt-ok
EOF

vgate_setup_python <<'PY'
import pathlib, subprocess, os

run = pathlib.Path(os.environ["RUN_DIR"])
img = "artifacts/disk.img"

# Pull the two boot-chain members out of the canonical image — the digests
# are recomputed in the assert hooks from these exact bytes.
for member, name in (("EFI/BOOT/BOOTAA64.EFI", "BOOTAA64.EFI"), ("KERNEL.BIN", "KERNEL.BIN")):
    with open(run / name, "wb") as fh:
        subprocess.run(["python3", "image/mkfat32.py", "--cat-file", "/" + member, img],
                       check=True, stdout=fh)

good_efi = (run / "BOOTAA64.EFI").read_bytes()
good_krn = (run / "KERNEL.BIN").read_bytes()

# Single-byte tampers, mid-file (inside each image's code/payload span).
bad_efi = bytearray(good_efi); bad_efi[0x4000] ^= 0xFF
bad_krn = bytearray(good_krn); bad_krn[0x40000] ^= 0xFF
(run / "BOOTBAD.EFI").write_bytes(bad_efi)
(run / "KERNEL.BAD").write_bytes(bad_krn)

# Tampered boot media: bad loader + good kernel, and good loader + bad kernel.
subprocess.run(["python3", "image/mkfat32.py", str(run / "tampered-loader.img"),
                str(run / "BOOTBAD.EFI"), str(run / "KERNEL.BIN")],
               check=True, stdout=subprocess.DEVNULL)
subprocess.run(["python3", "image/mkfat32.py", str(run / "tampered-kernel.img"),
                str(run / "BOOTAA64.EFI"), str(run / "KERNEL.BAD")],
               check=True, stdout=subprocess.DEVNULL)

# The custom Platform Key (DER X.509) the runner enrolls. Self-signed —
# ADR 0054 D1 enrolls OUR PK, no Microsoft signatures.
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(run / "pk.key"), "-out", str(run / "pk.der"),
                "-outform", "DER", "-subj", "/CN=VirelaiOS-test-PK", "-days", "1"],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY

# --- leg ok: enrolled digest boots, receipt cross-checked -------------------
vgate_run ok -- --secure-boot --secure-boot-pk '$RUN_DIR/pk.der' \
    --secure-boot-db-efi '$RUN_DIR/BOOTAA64.EFI' \
    --script '$RUN_DIR/boot.txt' --script-after 'tasks user-el0 exited status=7' \
    --script-expect 'vboot-rcpt-ok' --timeout 90

vgate_assert ok serial-contains 'RCPT stage=loader sha256='
vgate_assert ok serial-contains 'RCPT stage=kernel sha256='
vgate_assert ok serial-count 'verdict=measured' 2
vgate_assert ok serial-contains 'vboot-rcpt-ok'
vgate_assert ok share-contains RCPT.TXT 'RCPT stage=loader sha256='
vgate_assert ok share-contains RCPT.TXT 'RCPT stage=kernel sha256='
vgate_assert ok output-contains 'secure-boot: enabled'
vgate_assert ok output-contains 'authenticode('
# The host is the verifier (ADR 0054 D4): recompute both digests from the
# bytes the image carried and pin every published copy to them. The serial
# lines and RCPT.TXT must carry the same two lines byte-for-byte.
vgate_assert ok python <<'PY'
import hashlib, os, re, sys

run = os.environ["RUN_DIR"]
ser = open(os.environ["VG_SER"], errors="replace").read()
efi = open(os.path.join(run, "BOOTAA64.EFI"), "rb").read()
krn = open(os.path.join(run, "KERNEL.BIN"), "rb").read()

def pe_authenticode(data):
    # The same convention the loader and runner implement: hash the image
    # in file order, skipping the CheckSum field, the security directory
    # entry, and the certificate table it names.
    e = int.from_bytes(data[0x3c:0x40], "little")
    opt = e + 24
    magic = int.from_bytes(data[opt:opt + 2], "little")
    dirbase = opt + (112 if magic == 0x20B else 96)
    numoff = opt + (108 if magic == 0x20B else 92)
    ndirs = int.from_bytes(data[numoff:numoff + 4], "little")
    chk = opt + 64
    secdir = dirbase + 4 * 8
    h = hashlib.sha256()
    if ndirs <= 4 or secdir + 8 > len(data):
        h.update(data[:chk]); h.update(data[chk + 4:])
    else:
        coff, csize = int.from_bytes(data[secdir:secdir + 4], "little"), \
                      int.from_bytes(data[secdir + 4:secdir + 8], "little")
        h.update(data[:chk]); h.update(data[chk + 4:secdir])
        end = coff if coff else len(data)
        h.update(data[secdir + 8:end])
        if coff:
            h.update(data[coff + csize:])
    return h.hexdigest()

want = {
    "loader": pe_authenticode(efi),
    "kernel": hashlib.sha256(krn).hexdigest(),
}
rcpt = re.findall(r"RCPT stage=(\w+) sha256=([0-9a-f]{64}) verdict=(\w+)", ser)
got = {stage: (digest, verdict) for stage, digest, verdict in rcpt}
assert len(rcpt) == 2, "expected exactly 2 RCPT lines, got %r" % rcpt
for stage, digest in want.items():
    assert stage in got, "missing RCPT stage=%s line" % stage
    assert got[stage][0] == digest, "stage=%s digest mismatch: %s != %s" % (stage, got[stage][0], digest)
    assert got[stage][1] == "measured", "stage=%s verdict=%s != measured" % (stage, got[stage][1])

share = open(os.path.join(os.environ["VG_SHARE"], "RCPT.TXT"), "rb").read().decode()
for stage in want:
    line = "RCPT stage=%s sha256=%s verdict=measured" % (stage, want[stage])
    assert line in share, "share receipt missing: %s" % line
PY

# --- leg tampered-loader: firmware refusal, nothing runs --------------------
vgate_run tampered-loader -- --overlay-base '$RUN_DIR/tampered-loader.img' \
    --secure-boot --secure-boot-pk '$RUN_DIR/pk.der' \
    --secure-boot-db-efi '$RUN_DIR/BOOTAA64.EFI' \
    --script '$RUN_DIR/boot.txt' --script-after 'tasks user-el0 exited status=7' \
    --script-expect 'vboot-rcpt-ok' --timeout 60
vgate_allow_rc tampered-loader 1

# Zero serial, zero receipt — the firmware never lets a byte of guest code
# run (the probe's observed refusal shape).
vgate_assert tampered-loader capture-empty vm-serial-tampered-loader.log
vgate_assert tampered-loader output-contains 'secure-boot: enabled'
vgate_assert tampered-loader python <<'PY'
import os
data = open(os.environ["VG_SER"], "rb").read() if os.path.exists(os.environ["VG_SER"]) else b""
assert b"RCPT" not in data, "a receipt appeared despite the firmware refusal"
assert len(data) == 0, "serial not empty (%d bytes) despite the firmware refusal" % len(data)
PY

# --- leg tampered-kernel: the loader refuses by name ------------------------
vgate_run tampered-kernel -- --overlay-base '$RUN_DIR/tampered-kernel.img' \
    --secure-boot --secure-boot-pk '$RUN_DIR/pk.der' \
    --secure-boot-db-efi '$RUN_DIR/BOOTAA64.EFI' \
    --script '$RUN_DIR/boot.txt' --script-after 'tasks user-el0 exited status=7' \
    --script-expect 'vboot-rcpt-ok' --timeout 60
vgate_allow_rc tampered-kernel 1

# The loader passed Secure Boot (its digest is in db), read KERNEL.BIN,
# found the hash mismatch, and refused BY NAME. The refusal lands in the
# NVRAM variable `VirelaiBoot` = `refused=kernel_hash_mismatch` inside the
# per-run variable store — byte-scan the store, UTF-16 name and all.
vgate_assert tampered-kernel python <<'PY'
import os
run = os.environ["RUN_DIR"]
vars_path = os.path.join(run, "efi-vars.bin")
raw = open(vars_path, "rb").read()
assert b"refused=kernel_hash_mismatch" in raw, \
    "the named refusal is absent from the variable store (%d bytes)" % len(raw)
ser = open(os.environ["VG_SER"], "rb").read() if os.path.exists(os.environ["VG_SER"]) else b""
assert b"RCPT" not in ser, "a receipt was published by a refused kernel"
PY

# --- leg off: no flags, the byte-identical path ----------------------------
vgate_run off -- --script '$RUN_DIR/boot.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script-expect 'vboot-rcpt-ok' --timeout 90

# Boot unchanged: userspace reached, the script ran to its marker. The
# measured chain receipt still publishes — measurement is always on.
vgate_assert off serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert off serial-contains 'tasks user-el0 exited status=7'
vgate_assert off serial-contains 'vboot-rcpt-ok'
vgate_assert off serial-contains 'RCPT stage=loader sha256='
vgate_assert off serial-contains 'RCPT stage=kernel sha256='
vgate_assert off serial-count 'verdict=measured' 2
vgate_assert off share-contains RCPT.TXT 'verdict=measured'
vgate_assert off python <<'PY'
import os
out = os.path.join(os.environ["RUN_DIR"], "run-%s.out" % os.environ["VG_TAG"])
text = open(out, errors="replace").read()
assert "secure-boot: enabled" not in text, \
    "the flags-off run enrolled Secure Boot"
PY
