# live-trust-grants.spec -- ADR 0054 Part II (M113c, issue #2419): the
# kernel grant table live on VZ, on one share with a host-seeded
# `GRANTS.TXT` (secret-class by construction, like SECRETS.TXT):
#
#   * CONFINE.BIN — a byte-identical TCP.BIN under a confined wildcard
#     row (`file` only): its slot-80-adjacent socket path emits
#     `audit:net_denied` receipts AND the connect still lands — audit
#     mode records a would-be denial, it does not refuse.
#   * GRANTD.BIN — the same bytes granted `file,net`: the socket path is
#     unchanged (no net denial) while `debug` is still denied — the
#     narrowing is word-scoped, not app-scoped.
#   * TCP.BIN — a hash-bound row whose sha256 does not match the file:
#     the measured exec refuses `grant_stale` and no process is born
#     (a swapped ELF is no longer the granted image).
#   * BOUND.BIN (M116a #2467) — the matching half: a hash-bound row whose
#     sha256 is the staged file's real digest BINDS — the measured exec
#     applies the row's mask (net granted, debug denied, connect lands).
#   * GRANTS.TXT itself — denied at BOTH seams: the monitor's `vf cat`
#     and the EL0 file ABI (TOOL.BIN `head` reads nothing; ASM.BIN
#     cannot take it as an output path — a non-owner write is refused).
#
# The rows key the RECORDED image name, so same-bytes copies are the
# experiment's controlled variable.
vgate_name live-trust-grants "#2419 M113c: GRANTS.TXT secret-class + measured exec + word-gate audit receipts on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt kernel/src/*.zig user/src/*.zig build.zig

vgate_setup_python <<'PY'
import hashlib, os, shutil
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(share, "TCP.BIN")
for dst in ("CONFINE.BIN", "GRANTD.BIN", "BOUND.BIN"):
    shutil.copyfile(src, os.path.join(share, dst))
# The user-grant table. `#v1` with no mode field = audit (the ship
# posture). `1`*64 is a valid-looking sha256 that cannot be TCP.BIN's —
# a stale hash-bound row, refused by name at exec. BOUND.BIN's row pins
# the staged file's real digest — the binding half a non-`*` row owes.
bound_sha = hashlib.sha256(open(os.path.join(share, "BOUND.BIN"), "rb").read()).hexdigest()
open(os.path.join(share, "GRANTS.TXT"), "w").write(
    "#v1\n"
    "CONFINE.BIN\t*\tfile\n"
    "GRANTD.BIN\t*\tfile,net\n"
    "TCP.BIN\t" + "1" * 64 + "\tnet\n"
    "BOUND.BIN\t" + bound_sha + "\tfile,net\n"
)
# ASM.BIN only reaches its output-open after a source assembles, so the
# write leg needs one trivial real file.
open(os.path.join(share, "PROG.S"), "w").write("_start:\n  svc #0\n")
print("grant fixtures ok")
PY

vgate_file script-01.txt <<'EOF'
vf cat GRANTS.TXT
exec TOOL.BIN head GRANTS.TXT
exec ASM.BIN PROG.S GRANTS.TXT
exec TCP.BIN
net ip 10.0.0.1
net arp 10.0.0.2
exec CONFINE.BIN
echo legs-typed
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:9999 --script '$RUN_DIR/script-01.txt' --script-expect 'procs CONFINE.BIN exited status=18' --timeout 90

vgate_file script-02.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GRANTD.BIN
echo grantd-typed
EOF

vgate_run 02 -- --net '$RUN_DIR/cap2.bin' --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:9999 --script '$RUN_DIR/script-02.txt' --script-expect 'procs GRANTD.BIN exited status=18' --timeout 90

vgate_file script-03.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec BOUND.BIN
echo bound-typed
EOF

vgate_run 03 -- --net '$RUN_DIR/cap3.bin' --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:9999 --script '$RUN_DIR/script-03.txt' --script-expect 'procs BOUND.BIN exited status=18' --timeout 90

# --- the secret-class file: denied at both seams, untouched host-side ---
vgate_assert 01 serial-contains 'vf cat: GRANTS.TXT: permission denied'
vgate_assert 01 serial-contains 'head: GRANTS.TXT: no such file'
vgate_assert 01 serial-contains 'asm: cannot create output'
vgate_assert 01 share-contains 'GRANTS.TXT' 'CONFINE.BIN'
vgate_assert 01 share-contains 'GRANTS.TXT' '#v1'

# --- measured exec: the swapped ELF refuses by name --------------------
vgate_assert 01 serial-contains 'verdict=refused:grant_stale'
vgate_assert 01 serial-contains 'grant_stale'
# No process was born of the stale image: `name=TCP.BIN` never
# measured in — CONFINE's identical bytes are the only `tcp:` banner on
# this run.
vgate_assert 01 serial-absent 'verdict=measured name=TCP.BIN'

# --- the confined app: audit receipts AND the call still landed --------
# (status 18 is TCP.BIN's full connect/send/echo/close success path; the
# receipts can interleave inside the app's banner, so the asserts use
# the markers that survive it.)
vgate_assert 01 serial-contains 'verdict=measured name=CONFINE.BIN'
# M173c (#3044): the receipt names its principal — a monitor exec is
# uid_user, so CONFINE.BIN's measured receipt must carry uid=1000.
vgate_assert 01 serial-contains 'verdict=measured name=CONFINE.BIN uid=1000'
vgate_assert 01 serial-contains 'audit:net_denied name=CONFINE.BIN word=net'
vgate_assert 01 serial-contains 'audit:debug_denied name=CONFINE.BIN word=debug'
vgate_assert 01 serial-contains 'tcp: connected'
vgate_assert 01 serial-contains 'procs CONFINE.BIN exited status=18'

# --- the granted app: unaffected in `net`, narrowed only where rowed ---
vgate_assert 02 serial-contains 'verdict=measured name=GRANTD.BIN'
vgate_assert 02 serial-contains 'tcp: connected'
vgate_assert 02 serial-contains 'procs GRANTD.BIN exited status=18'
vgate_assert 02 serial-absent 'name=GRANTD.BIN word=net'
vgate_assert 02 serial-contains 'name=GRANTD.BIN word=debug'

# --- the hash-bound app: the row's digest matches, so the mask applies --
# A wrong digest would refuse `grant_stale` (the TCP.BIN leg); a matching
# one measures in and applies — net is granted (the connect lands, no
# `net` denial) while `debug` receipts under the narrowed mask. Same
# bytes as CONFINE/GRANTD: the binding, not the image, is the variable.
vgate_assert 03 serial-contains 'verdict=measured name=BOUND.BIN'
vgate_assert 03 serial-absent 'verdict=refused'
vgate_assert 03 serial-contains 'tcp: connected'
vgate_assert 03 serial-contains 'procs BOUND.BIN exited status=18'
vgate_assert 03 serial-absent 'name=BOUND.BIN word=net'
vgate_assert 03 serial-contains 'name=BOUND.BIN word=debug'
