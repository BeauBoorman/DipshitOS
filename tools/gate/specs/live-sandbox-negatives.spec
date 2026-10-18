# live-sandbox-negatives.spec -- M116e (issue #2471, ADR 0054 D7-D12):
# the sandbox NEGATIVE corpus, live on VZ on one share provisioned with
# the fixture `GRANTS.TXT` `#v1 mode=enforce` table
# (tools/gate/fixtures/sandbox-negatives/). One probe binary is staged
# under every corpus name — the row is the controlled variable (the
# live-trust-grants same-bytes pattern). Every refusal must produce its
# named receipt: a kernel `verdict=refused:*` / `refused:*_denied` line
# where the seam emits one, and the honest errno the app prints itself
# where it does not (the live-grant-enforce precedent).
#
#   * NOROW.ELF — no row: the M116b ambient floor confines (file + net
#     refused by name, honest EACCES, clean exit — confined not stuck).
#   * NONET.ELF / NOFILE.ELF — `*` rows missing one boundary word each:
#     the undeclared word refuses, the declared one lands.
#   * GRANTED.ELF — the full-words control: both calls land on the wire.
#   * STALE.ELF — a hash-bound row whose sha256 is not the image's:
#     `verdict=refused:grant_stale`, no process is born.
#   * BADSHA / BADWORDS / BADTO / BADFS / BADCNT — one poisoned row per
#     malformed shape (bad digest field, unknown word, bad `to=`
#     endpoint, off-vocabulary `fs=` volume, a fifth field): fail closed,
#     `grant_stale` by name at exec.
#   * WRITER.ELF (uid_user, a `file`-word row) — the row-write escapes:
#     slot-89 read and another app's row write refuse EACCES at the
#     seat-or-cap gate, its own row write refuses, and the file-ABI
#     GRANTS.TXT write refuses — the share's GRANTS.TXT is byte-identical
#     after the boot (share-equals is the receipt nothing landed).
#   * run 02: `exec -u0 WRITER.ELF` (the CAP_PROC_ADMIN half of the
#     gate) — a row naming ITSELF still refuses EACCES (never the app
#     the row names); a well-formed row naming FORGED.ELF bound to a
#     sha the file does not carry lands as policy text but refuses
#     `grant_stale` at exec — a written row cannot arm bytes it does
#     not pin; a malformed line answers EINVAL.
#
# K=3 is three gate invocations (persist() rewrites GRANTS.TXT after
# run 02, so the poisoned rows exist only on a fresh share's boot —
# in-spec vgate_repeat would re-boot against the persisted file).
vgate_name live-sandbox-negatives "#2471 M116e: sandbox negative corpus — undeclared words, stale/poisoned rows, row-write escapes, all refused by name"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt kernel/src/*.zig user/src/*.zig build.zig

vgate_setup_python <<'PY'
import os, pathlib, shutil, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
share = pathlib.Path(os.environ.get("VG_SHARE") or rd / "share")
fix = pathlib.Path("tools/gate/fixtures/sandbox-negatives")
tmp = rd / "neg-build"
tmp.mkdir(exist_ok=True)
env = dict(os.environ, TMPDIR=str(tmp), GO_BUILD_OUT=str(tmp),
           GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh", str(fix / "probe.go")],
               env={**env, "GO_BUILD_NAME": "NEGPROBE"}, check=True)
subprocess.run(["bash", "tools/go/build-go.sh", str(fix / "rowwriter.go")],
               env={**env, "GO_BUILD_NAME": "ROWWRITE"}, check=True)
probe = tmp / "NEGPROBE.ELF"
for name in ("NOROW", "NONET", "NOFILE", "GRANTED", "STALE", "BADSHA",
             "BADWORDS", "BADTO", "BADFS", "BADCNT", "FORGED"):
    shutil.copyfile(probe, share / (name + ".ELF"))
shutil.copyfile(tmp / "ROWWRITE.ELF", share / "WRITER.ELF")
(share / "PROBE.TXT").write_text("negatives-probe-payload\n")
# The seeded user table — the fixture file IS the manifest corpus.
grants = (fix / "GRANTS.TXT").read_bytes()
(share / "GRANTS.TXT").write_bytes(grants)
(rd / "grants-seeded.txt").write_bytes(grants)
print("negatives fixtures + GRANTS.TXT staged")
PY

# --- run 01: the refusal battery -----------------------------------------
# The exec-refused names emit their receipts synchronously inside the
# `exec` line and never spawn; the live probes are sequenced through the
# script stages — the 16-slot task ring cannot hold five Go ELFs at once
# (observed: `newosproc: sys_thread create failed` on the fourth) — each
# stage waits on the previous program's own terminal marker, so at most
# two probes are alive at once and the run ends on the last one's.
vgate_file script-01.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec STALE.ELF
exec BADSHA.ELF
exec BADWORDS.ELF
exec BADTO.ELF
exec BADFS.ELF
exec BADCNT.ELF
exec NOROW.ELF
exec NONET.ELF
EOF

vgate_file script-01b.txt <<'EOF'
exec NOFILE.ELF
exec GRANTED.ELF
EOF

vgate_file script-01c.txt <<'EOF'
exec WRITER.ELF batch
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' \
    --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:8080 \
    --script '$RUN_DIR/script-01.txt' \
    --script2 '$RUN_DIR/script-01b.txt' --script2-after 'negprobe: done name=NONET.ELF' \
    --script3 '$RUN_DIR/script-01c.txt' --script3-after 'negprobe: done name=GRANTED.ELF' \
    --script-expect 'rowwrite: done name=WRITER.ELF op=batch' --timeout 90

# --- ambient floor: an unlisted binary stays confined --------------------
vgate_assert 01 serial-contains 'verdict=measured name=NOROW.ELF'
vgate_assert 01 serial-contains 'refused:file_denied name=NOROW.ELF word=file'
vgate_assert 01 serial-contains 'refused:net_denied name=NOROW.ELF word=net'
vgate_assert 01 serial-contains 'negprobe: file denied name=NOROW.ELF rc=EACCES'
vgate_assert 01 serial-contains 'negprobe: net denied name=NOROW.ELF rc=EACCES'
vgate_assert 01 serial-contains 'negprobe: done name=NOROW.ELF'
vgate_assert 01 serial-contains 'NOROW.ELF exited status=0'

# --- undeclared words: the row grants the other word, refuses this one ---
vgate_assert 01 serial-contains 'verdict=measured name=NONET.ELF'
vgate_assert 01 serial-contains 'negprobe: file ok name=NONET.ELF'
vgate_assert 01 serial-contains 'refused:net_denied name=NONET.ELF word=net'
vgate_assert 01 serial-contains 'negprobe: net denied name=NONET.ELF rc=EACCES'
vgate_assert 01 serial-absent 'denied name=NONET.ELF word=file'

vgate_assert 01 serial-contains 'verdict=measured name=NOFILE.ELF'
vgate_assert 01 serial-contains 'refused:file_denied name=NOFILE.ELF word=file'
vgate_assert 01 serial-contains 'negprobe: file denied name=NOFILE.ELF rc=EACCES'
vgate_assert 01 serial-contains 'negprobe: net ok name=NOFILE.ELF'
vgate_assert 01 serial-absent 'denied name=NOFILE.ELF word=net'

# --- the full-words control: same bytes, both calls land ------------------
vgate_assert 01 serial-contains 'verdict=measured name=GRANTED.ELF'
vgate_assert 01 serial-contains 'negprobe: file ok name=GRANTED.ELF'
vgate_assert 01 serial-contains 'negprobe: net ok name=GRANTED.ELF'
vgate_assert 01 serial-contains 'negprobe: done name=GRANTED.ELF'
vgate_assert 01 serial-absent 'denied name=GRANTED.ELF'
# "Allowed" reached the wire — the responder saw the SYNs.
vgate_assert 01 output-contains 'NET-TCP: answered the guest'

# --- stale + poisoned rows: refused by name, no process born -------------
vgate_assert 01 serial-contains 'verdict=refused:grant_stale name=STALE.ELF'
vgate_assert 01 serial-contains 'STALE.ELF: exec refused (grant_stale'
vgate_assert 01 serial-absent 'verdict=measured name=STALE.ELF'
vgate_assert 01 serial-contains 'verdict=refused:grant_stale name=BADSHA.ELF'
vgate_assert 01 serial-absent 'verdict=measured name=BADSHA.ELF'
vgate_assert 01 serial-contains 'verdict=refused:grant_stale name=BADWORDS.ELF'
vgate_assert 01 serial-absent 'verdict=measured name=BADWORDS.ELF'
vgate_assert 01 serial-contains 'verdict=refused:grant_stale name=BADTO.ELF'
vgate_assert 01 serial-absent 'verdict=measured name=BADTO.ELF'
vgate_assert 01 serial-contains 'verdict=refused:grant_stale name=BADFS.ELF'
vgate_assert 01 serial-absent 'verdict=measured name=BADFS.ELF'
vgate_assert 01 serial-contains 'verdict=refused:grant_stale name=BADCNT.ELF'
vgate_assert 01 serial-absent 'verdict=measured name=BADCNT.ELF'

# --- row-write escapes, unprivileged: the seat-or-cap gate, the self-name
# check, and the file-ABI GRANTS.TXT write all answer EACCES --------------
vgate_assert 01 serial-contains 'verdict=measured name=WRITER.ELF'
vgate_assert 01 serial-contains 'rowwrite: admin read name=WRITER.ELF rc=EACCES'
vgate_assert 01 serial-contains 'rowwrite: admin write name=WRITER.ELF target=VICTIM.ELF rc=EACCES'
vgate_assert 01 serial-contains 'rowwrite: self write name=WRITER.ELF target=WRITER.ELF rc=EACCES'
vgate_assert 01 serial-contains 'rowwrite: file write name=WRITER.ELF target=GRANTS.TXT rc=EACCES'
vgate_assert 01 serial-contains 'rowwrite: done name=WRITER.ELF op=batch'
vgate_assert 01 serial-absent 'denied name=WRITER.ELF'
# The receipt that nothing landed: the share's GRANTS.TXT is byte-identical
# to the seeded fixture (no VICTIM row, no WRITER self-row, no file write).
vgate_assert 01 share-equals 'GRANTS.TXT' 'grants-seeded.txt'

# --- posture: enforce boots emit no audit receipts, no exceptions --------
vgate_assert 01 serial-absent 'verdict=audit:'
vgate_assert 01 serial-absent '[EXC] parking:'

# --- run 02: the CAP_PROC_ADMIN holder's row writes -----------------------
# `exec -u0` = uid_system + kernel_caps (the monitor's admin spawn). The
# batch runs in-process order: self-name write (EACCES), the forged
# FORGED.ELF binding (lands — it is the consent-shaped write), the
# malformed line (EINVAL), the op-0 read (the gate's admit half).
vgate_file script-02.txt <<'EOF'
exec -u0 WRITER.ELF adminbatch
EOF

vgate_file script-02b.txt <<'EOF'
exec FORGED.ELF
echo neg-02-done
EOF

vgate_run 02 -- --net '$RUN_DIR/cap2.bin' \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script-02b.txt' --script2-after 'rowwrite: done name=WRITER.ELF op=adminbatch' \
    --script-expect 'neg-02-done' --timeout 90

# Never the app the row names — the cap holder cannot widen its own row.
vgate_assert 02 serial-contains 'rowwrite: self write name=WRITER.ELF target=WRITER.ELF rc=EACCES'
# The strict grammar answers malformed input by name.
vgate_assert 02 serial-contains 'rowwrite: admin write name=WRITER.ELF target=MALROW.ELF rc=EINVAL'
# The gate's admit half: reads and the well-formed cross-app write land.
vgate_assert 02 serial-contains 'rowwrite: admin read name=WRITER.ELF rc=OK'
vgate_assert 02 serial-contains 'rowwrite: admin write name=WRITER.ELF target=FORGED.ELF rc=OK'
# ...but a written row cannot arm bytes it does not pin: FORGED.ELF's
# measured sha mismatches the written row and refuses grant_stale.
vgate_assert 02 serial-contains 'verdict=refused:grant_stale name=FORGED.ELF'
vgate_assert 02 serial-contains 'FORGED.ELF: exec refused (grant_stale'
vgate_assert 02 serial-absent 'verdict=measured name=FORGED.ELF'
vgate_assert 02 serial-absent 'FORGED.ELF exited'
# The forged row persisted as text (the write landed); VICTIM and MALROW
# never did — the table's honest state is on the share.
vgate_assert 02 share-contains 'GRANTS.TXT' 'FORGED.ELF'
vgate_assert 02 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
grants = open(os.path.join(share, "GRANTS.TXT"), "r", encoding="utf-8").read()
if "FORGED.ELF" not in grants:
    sys.exit("FAIL: forged FORGED.ELF row not persisted")
if "VICTIM.ELF" in grants:
    sys.exit("FAIL: refused VICTIM.ELF row landed")
if "MALROW.ELF" in grants:
    sys.exit("FAIL: malformed MALROW.ELF line landed")
if "WRITER.ELF\t*\tfile,net" in grants:
    sys.exit("FAIL: self-name widening write landed")
if "WRITER.ELF" not in grants:
    sys.exit("FAIL: seeded WRITER.ELF row missing")
print("negatives GRANTS.TXT state ok")
PY
vgate_assert 02 serial-absent '[EXC] parking:'
