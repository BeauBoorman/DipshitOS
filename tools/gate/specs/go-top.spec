# go-top.spec -- M71g (issue #1566) class-B gate: GOTOP.ELF lists a live
# process, kills it with `k`, and closes -- full-viewport inside Zig TABWM.
#
# user/go/top is a tabapp client: init -> declare (kind-8 WM_RPC) -> sys_procs
# (slot 7) -> paint -> `k` arms the selected pid through sys_kill (slot 29) ->
# the kernel converts it into the reserved status 137 -> window close.
#
# The card's D2 is "kill is the live proof, not a pretty chart", so this spec
# proves the kill against a process it first listed by NAME (the pid is read
# out of GOTOP's own row line, not pinned, so the boot's pid allocation stays
# free to move). GOTOP.ELF is the successor to Zig TOP.BIN and SYSMON.BIN, both
# deleted by this card; it keeps TOP's `top:` marker vocabulary and its
# 40,40 512x384 declaration, so the retargeted live-* specs moved by binary
# name.
#
# exec-order: assert-proven -- the run ends on `rx-gotop-ok`, which only the
# script prints, and the stage gate that forwards the close waits on the
# kernel's own `tasks user-exec exited status=137` (the kill's consequence),
# so a boot in which the kill never landed cannot reach the echo.
#
# Run 02 (issue #2197) is the filter leg: TOP.BIN's retired text filter is
# back on the Go kit's widgets.TextInput. `/` opens the field, typed text
# live-narrows the table (the row dump then shows only matching names), Enter
# commits it, `/` reopens the committed text and Escape clears it -- the full
# list returns. The leg fails before the widget exists: none of its `top:
# filter*` markers are ever printed.
#
# Run 03 (issue #2198) is the real-figures leg: GOSCALE.ELF's four spinning
# workers saturate the cores for a ~6 s window, so a GOTOP snapshot taken
# after `goscale: released` MUST show that pid's cpu_ticks > 0 — under the
# pre-0047 kernel the `top: usage` marker and the cpu=/mem= row fields do not
# exist at all, so every assert below fails before this card. GOSCALE is the
# honest fixture: it holds real runnable Ms instead of parking between
# yields, which is exactly what tick-attributed accounting measures.
#
# Run 04 is the PULSE half — and, since M194f (#3286), PULSE's registry-
# pinned owning leg: PULSE.ELF's negotiated read prints
# `pulse: usage cpux10= memused= memtotal=` right after `pulse: ready` when
# the v2 rows arrived — absent on a v1 kernel — and a `2` chord repaints the
# Processes tab with real CPU%/MEM columns over the same busy guest. The
# `2` rides after `pulse: tick` (the armed 1 Hz timer's first marker), the
# close waits on `pulse: key 2`, and the run ends on `pulse OK`, so the
# leg pins face + tick + key + named quit.
#
# Run 06 (issue #2411, M111d) is the gpu tab leg: GPUTRIANGLE's `gemm`
# journey runs one real Metal compute submit first (slot-90 sys_gpucomp,
# --gpu3d-metal arms the VIC1 device), then GOTOP opens and `c` switches to
# the gpu tab. The `top: gpu` marker is printed only after the handle-free
# STATS op returned, so its submits/completed/lastus fields are nonzero
# evidence of a real kernel — the run ends on that marker (assert-proven,
# the same convention run 03 uses). busy/queued are the broker's
# instantaneous flags: a synchronous RUN leaves both at zero once its fence
# completes, so the assert pins the ledger, not the flags.
#
# Run 07 (issue #2421, M113e) is the trust tab leg: a confined app and a
# granted app run under real GRANTS.TXT rows first (CONFINE.BIN's socket
# path receipts the kernel's own audit:net_denied while still connecting —
# audit mode records, does not refuse), then GOTOP opens through the
# monitor's admin spawn (`exec -u0`, the CAP_PROC_ADMIN half of the slot-89
# gate) and `t` renders per-app posture: uid, declared-vs-granted words,
# the measured sha256 against the row's pin, the ADR 0055-derived
# publisher fingerprint, and the published RCPT.TXT receipts. The kernel's
# own denial receipts on the same serial log cross-prove the rendered
# denied-word sets are real.
#
# The old-row decode leg is pinned on the host, not here: a v2 kernel always
# answers a tagged request with v2 rows, so "v1 stream decodes correctly"
# is `go test ./vi ./top` (TestProcsV2OldKernel, TestUsageGoneOnV1) plus the
# kernel-side byte-frozen snapshot test.
#
# Runs 10/11 (issue #3249, M192d) are the appver-1 state legs, and they seat
# GOTABWM — the snapshot chord and SESSION.TABS restore are Go-seat features
# (Zig TABWM owns neither). Run 10 sorts the procs tab name-descending (`2
# 2`), dumps the order (`r`), makes mounts the active tab (`m`), then
# ctrl-shift-s asks the seat to take GOTOP's 4-byte blob — `u8 fmtver | u8
# page | u8 col | u8 dir` — into SESSION.TABS's app_state trailer. Run 11 is
# the fresh boot on that share: the seat session-reexecs GOTOP.ELF, the
# restore_state request hands the blob back at appver=1, and the startup row
# dump lands in the same name-descending order on the mounts tab — sorted
# like you left it. Staging GOTABWM.ELF arms the kernel's compiled
# wm=gotabwm autostart, so SETTINGS.TXT carries wm=none to keep runs 01-09
# booting exactly as before (the go-emoji/go-term idiom).
#
# HOST PREREQUISITES (fail the gate honestly when missing):
#   bash tools/go/build-gotop.sh                    -> .build/go/GOTOP.ELF
#   bash tools/go/build-go.sh tools/go/smpscale.go  -> .build/go/GOSCALE.ELF
#   bash tools/go/build-pulse.sh                    -> .build/go/PULSE.ELF
#   bash tools/go/build-gputriangle.sh              -> .build/go/GPUTRIANGLE.ELF
#   bash tools/go/build-gotabwm.sh                  -> .build/go/GOTABWM.ELF

vgate_name go-top "issue #1566 M71g: GOTOP.ELF lists a live pid and kills it in Zig TABWM on VZ; #2197: `/` filter leg; #2411: `c` gpu tab over real slot-90 counters; #2421: `t` trust tab — real grant posture + receipts; #3249: appver-1 sort+tab persistence under the Go seat"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec COUNTER.BIN
exec GOTOP.ELF
EOF

# The close is driven from the harness only AFTER the kernel has reported the
# killed process's exit, so both the kill and its consequence are on the serial
# log before the window goes away. `procs` is the kernel's OWN table read-back:
# the killed pid must show exited/137 there, which is what makes the kill more
# than a marker.
vgate_file script3.txt <<'EOF'
procs
dui close 2
echo rx-gotop-ok
EOF

# Run 02's close rides on the filter's own last marker: the clear is on the
# serial log before the window goes away.
vgate_file script3f.txt <<'EOF'
dui close 2
echo rx-gotop-filter-ok
EOF

# Run 03's busy fixture + GOTOP launch: the exec waits on `goscale: busy m=4`
# so both snapshots land inside the ~6 s spin window — the workers' pids have
# real per-core tick charges by then, while the process row is still live.
vgate_file script2u.txt <<'EOF'
exec GOSCALE.ELF
EOF

vgate_file script3u.txt <<'EOF'
exec GOTOP.ELF
EOF

vgate_setup_python <<'PY'
import json, os, shutil, subprocess, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTOP.ELF")
if not os.path.exists(src):
    sys.exit("GOTOP.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotop.sh")
shutil.copy(src, os.path.join(share, "GOTOP.ELF"))
print("staged GOTOP.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "GOTOP.ELF")))
gsrc = os.path.join(".build", "go", "GOSCALE.ELF")
if not os.path.exists(gsrc):
    sys.exit("GOSCALE.ELF missing (expected " + gsrc + ") - build it first: "
             "bash tools/go/build-go.sh tools/go/smpscale.go")
shutil.copy(gsrc, os.path.join(share, "GOSCALE.ELF"))
print("staged GOSCALE.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "GOSCALE.ELF")))
psrc = os.path.join(".build", "go", "PULSE.ELF")
if not os.path.exists(psrc):
    sys.exit("PULSE.ELF missing (expected " + psrc + ") - build it first: "
             "bash tools/go/build-pulse.sh")
shutil.copy(psrc, os.path.join(share, "PULSE.ELF"))
print("staged PULSE.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "PULSE.ELF")))
# M109c run 05: the agent-activity leg. Stage the audit lane AGENT/AUDIT/
# would carry after an AGENTD session — four RCPT files, one with a
# deliberately bad MAC — plus the agent-hmac row GOTOP shares with
# AGENTD.ELF (ADR 0052 D4; GOTOP.ELF must be uid_system-owned for the
# app-bound row to be served, hence the OWNERS.TXT entry).
import hashlib as _hashlib, hmac as _hmac
KEY = "a5" * 32
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n" + "agent-hmac\t1000\t" + KEY + "\tAGENTD.ELF,GOTOP.ELF\n")
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nGOTOP.ELF\t644\t0\t-\n")
adir = os.path.join(share, "AGENT", "AUDIT")
os.makedirs(adir, exist_ok=True)


def rcpt(seq, agent, verb, args, result, forge=False):
    line = ('{"seq":%d,"epoch":"01020304","agent":"%s","verb":"%s",'
            '"args":%s,"ts":1761234567,"mono":42,"result":"%s"}'
            % (seq, agent, verb, args, result))
    mac = _hmac.new(KEY.encode(), line.encode(), _hashlib.sha256).hexdigest()
    if forge:
        mac = ("0" if mac[0] != "0" else "1") + mac[1:]
    return (line + "\n" + mac + "\n").encode()


open(os.path.join(adir, "RCPT-01020304-00000001"), "wb").write(
    rcpt(1, "-", "session", '{"event":"open"}', "ok"))
open(os.path.join(adir, "RCPT-01020304-00000002"), "wb").write(
    rcpt(2, "devin", "fs.write",
         '{"path":"HELLO.TXT","size":27,"sha256_8":"01234567"}', "ok"))
open(os.path.join(adir, "RCPT-01020304-00000003"), "wb").write(
    rcpt(3, "viewer", "fs.read", '{"path":"SEED.TXT"}', "cap_required:file"))
open(os.path.join(adir, "RCPT-01020304-00000004"), "wb").write(
    rcpt(4, "mallory", "gosh.run", '{"cmd":"rm -rf /"}', "ok", forge=True))
# A second-epoch receipt from an older boot — the lane keeps it, the view
# shows it verified.
open(os.path.join(adir, "RCPT-00aa11bb-00000007"), "wb").write(
    rcpt(7, "ghost", "proc.list", '{}', "ok"))
# Foreign files the view must skip.
open(os.path.join(adir, "RCPT-01020304-0000000~"), "wb").write(b"tmp\n")
open(os.path.join(adir, "OTHER.TXT"), "wb").write(b"x\n")
print("staged audit lane (5 receipts, 1 forged, + noise files)")
# M111d run 06: GPUTRIANGLE.ELF is the compute-submit fixture — its `gemm`
# journey is the real slot-90 workload whose counters the gpu tab must show.
trsrc = os.path.join(".build", "go", "GPUTRIANGLE.ELF")
if not os.path.exists(trsrc):
    sys.exit("GPUTRIANGLE.ELF missing (expected " + trsrc + ") - build it first: "
             "bash tools/go/build-gputriangle.sh")
shutil.copy(trsrc, os.path.join(share, "GPUTRIANGLE.ELF"))
print("staged GPUTRIANGLE.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "GPUTRIANGLE.ELF")))
# M113e run 07 (issue #2421): the trust tab leg. CONFINE.BIN/GRANTD.BIN
# are byte-identical TCP.BIN copies (live-trust-grants' controlled
# variable — rows key the recorded name): CONFINE rides a confined
# wildcard row (file only, so its socket path receipts audit:net_denied
# while still connecting — audit records, does not refuse), GRANTD a
# HASH-BOUND row pinned to the bytes staged here. STORE.TXT carries
# GRANTD's signed ReleaseCaps declaration and stream name; the FLINT
# stream replica under FLINT/streams/ is what ADR 0055 D5 derives the
# publisher fingerprint from (the head change's author key). The OWNERS
# rows split the two images' recorded owner uid (GRANTD operator-
# provisioned uid_system, CONFINE the uid_user default). No other leg's
# exec name is rowed, so GRANTS.TXT leaves their posture at baseline.
tcp = os.path.join(share, "TCP.BIN")
if not os.path.exists(tcp):
    sys.exit("TCP.BIN missing from the seeded share - zig build first")
for dst in ("CONFINE.BIN", "GRANTD.BIN"):
    shutil.copyfile(tcp, os.path.join(share, dst))
grantd_sha = _hashlib.sha256(
    open(os.path.join(share, "GRANTD.BIN"), "rb").read()).hexdigest()
open(os.path.join(share, "GRANTS.TXT"), "w").write(
    "#v1\n"
    "CONFINE.BIN\t*\tfile\n"
    "GRANTD.BIN\t" + grantd_sha + "\tfile,net\n")
with open(os.path.join(share, "OWNERS.TXT"), "a") as f:
    f.write("GRANTD.BIN\t644\t0\t-\n")
TRUST_STREAM = "0199de2d-dc00-7000-8000-00000000f020"
TRUST_HEAD = "0199de2d-dc00-7000-8000-00000000f021"
TRUST_PUB = "0123abcd" * 8
tdir = os.path.join(share, "FLINT", "streams")
os.makedirs(tdir, exist_ok=True)
open(os.path.join(tdir, TRUST_STREAM + ".json"), "w").write(
    '{"id":"%s","name":"trustrel","head":"%s","created":1760000000000,'
    '"forked_from":null}\n' % (TRUST_STREAM, TRUST_HEAD))
open(os.path.join(tdir, TRUST_STREAM + ".jsonl"), "w").write(
    '{"id":"%s","parent":null,"stream":"%s","ts":1760000000000,'
    '"author":"%s","message":"release","ops":[],"merged":null,'
    '"sig":"%s"}\n' % (TRUST_HEAD, TRUST_STREAM, TRUST_PUB, "00" * 64))
open(os.path.join(share, "STORE.TXT"), "w").write(
    "#v1\n"
    "name=GRANTD.BIN stream=trustrel head=" + TRUST_HEAD +
    " sha256=" + grantd_sha +
    " caps=file,net prev_head=- prev_sha256=- prev_caps=- prev_row=-\n")
print("staged trust fixtures: confined+hash-bound rows, store entry, "
      "stream replica (grantd sha256=%s)" % grantd_sha)
# M128d run 08 (issue #2608): the profile-info leg. One minted
# .virelaivm arms this boot — the bundle's name (prof) is the answer's
# profile field — pointed at a private base.img whose .prev sibling makes
# rollback true, while the seeded cvc share carries exactly two named
# SNAPSHOTS members and the uid_system vsock-ctl credential (the cvc
# channel wins the guest's SECRETS.TXT read on a both-armed boot, and the
# host's snapshot count reads the armed share — both are the seeded one).
with open(os.path.join(share, "SECRETS.TXT"), "a") as f:
    f.write("vsock-ctl\t0\t" + KEY + "\n")
snapdir = os.path.join(share, "SNAPSHOTS")
os.makedirs(snapdir, exist_ok=True)
for n in ("ALPHA", "BETA"):
    open(os.path.join(snapdir, n + ".vzsave"), "wb").write(b"snap\n")
prof = os.path.join(rd, "prof.virelaivm")
if not os.path.exists(prof):
    base = os.path.join(rd, "base.img")
    shutil.copyfile(os.path.join("artifacts", "disk.img"), base)
    open(base + ".prev", "wb").write(b"prev\n")
    runner = os.path.join("host", "vm-runner", ".build", "release", "VMRunner")
    r = subprocess.run([runner, "--profile", prof, "--profile-init"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("--profile-init refused the mint: " + r.stdout + r.stderr)
    cfg_path = os.path.join(prof, "config.json")
    cfg = json.load(open(cfg_path))
    cfg["baseImage"] = base
    cfg.setdefault("devices", {})["share"] = False
    json.dump(cfg, open(cfg_path, "w"), indent=2, sort_keys=True)
    print("minted profile fixture: base.img+.prev, 2 snapshots, ctl credential")
# M192d runs 10/11 (issue #3249): the appver state legs seat GOTABWM — the
# snapshot chord and SESSION.TABS restore are Go-seat features. Staging the
# binary arms the kernel's compiled wm=gotabwm autostart on EVERY leg of
# this spec, so wm=none keeps runs 01-09 seatless exactly as before (their
# `tabwm start` / direct execs are unaffected); runs 10/11 exec the seat
# from the monitor (the go-emoji/go-term idiom).
gsrc = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(gsrc):
    sys.exit("GOTABWM.ELF missing (expected " + gsrc + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(gsrc, os.path.join(share, "GOTABWM.ELF"))
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("staged GOTABWM.ELF + SETTINGS.TXT wm=none")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-string 'k' \
    --input-string-after 'top: ready' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'tasks user-exec exited status=137' \
    --script-expect 'rx-gotop-ok' --timeout 150

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOTOP.ELF'
vgate_assert 01 serial-contains 'top: open id='
vgate_assert 01 serial-contains 'top: tab-aware (full-viewport)'
vgate_assert 01 serial-contains 'top: procs n='
vgate_assert 01 serial-contains 'name=COUNTER.BIN state=running'
vgate_assert 01 serial-contains 'top: kill pid='
vgate_assert 01 serial-contains 'tasks user-exec exited status=137'
vgate_assert 01 serial-contains 'top: refreshed ok'
vgate_assert 01 serial-contains 'top: win_close'
vgate_assert 01 serial-contains 'top: exiting 43'
vgate_assert 01 serial-contains 'rx-gotop-ok'
vgate_assert 01 serial-absent '[EXC] parking:'

# The kill is real: the pid GOTOP ARMED is the pid its own listing showed for
# COUNTER.BIN, the listing came first, and the counter stops afterwards.
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
listed = next((i for i, l in enumerate(lines)
               if l.startswith("top: row pid=") and "name=COUNTER.BIN state=running" in l), None)
if listed is None:
    sys.exit("FAIL: GOTOP never listed COUNTER.BIN as a running row")
m = re.search(r"top: row pid=(\d+) name=COUNTER\.BIN state=running", lines[listed])
pid = m.group(1)
killed = next((i for i, l in enumerate(lines) if l.strip() == "top: kill pid=" + pid), None)
if killed is None:
    cands = [repr(l) for l in lines if "top: kill" in l]
    sys.exit("FAIL: no exact `top: kill pid=%s` for the listed COUNTER.BIN row; saw: %s"
             % (pid, "; ".join(cands) or "nothing"))
if killed < listed:
    sys.exit("FAIL: the kill preceded the listing it names")
# SMP caveat (observed 2026-10-12): sys_kill only ARMS the task — the
# kill_pending flag converts to status 137 at the counter's next resume — so
# a counter mid-quantum on another core can land ONE more `counter: alive`
# between the arm marker and its exit report. The hard invariant is zero
# markers after the kernel's own `exited status=137`: a dead task cannot
# print.
exit_line = next((i for i, l in enumerate(lines)
                  if i > killed and "exited status=137" in l), None)
if exit_line is None:
    sys.exit("FAIL: no exit report follows the kill marker")
after = sum(1 for l in lines[exit_line + 1:] if "counter: alive" in l)
if after != 0:
    sys.exit("FAIL: the killed process produced %d markers after its exit report" % after)
inflight = sum(1 for l in lines[killed + 1:exit_line] if "counter: alive" in l)
if inflight > 1:
    sys.exit("FAIL: %d markers between arm and exit — at most one in-flight "
             "tick is explainable" % inflight)
if not re.search(r"procs: id=%s name=COUNTER\.BIN .*state=exited .*exit=137" % pid, ser):
    sys.exit("FAIL: no exited/137 row for the killed pid %s" % pid)
print("gotop kill ok: listed+armed pid=%s, status 137, no markers after" % pid)
PY

# Run 02 -- the `/` filter leg (issue #2197). One cv-input chord sequence does
# the whole dance: `/` opens the field, `counter` narrows the table to the one
# matching row, `return` commits it, `/` reopens the committed text and
# `escape` clears it -- the unfiltered list comes back. Each edit dumps the
# filtered rows (`top: row pid=`), so the serial holds the row names the list
# showed, not just a count.
vgate_run 02 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords '/,c,o,u,n,t,e,r,return,/,escape' \
    --input-chords-after 'top: ready' \
    --script3 '$RUN_DIR/script3f.txt' \
    --script3-after 'top: filter cleared' \
    --script-expect 'rx-gotop-filter-ok' --timeout 150

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 02 serial-contains 'exec: loaded GOTOP.ELF'
vgate_assert 02 serial-contains 'top: ready'
vgate_assert 02 serial-contains 'top: filter open'
vgate_assert 02 serial-contains 'top: filter=counter n=1'
vgate_assert 02 serial-contains 'top: filter commit'
vgate_assert 02 serial-contains 'top: filter cleared'
vgate_assert 02 serial-contains 'top: win_close'
vgate_assert 02 serial-contains 'top: exiting 43'
vgate_assert 02 serial-contains 'rx-gotop-filter-ok'
vgate_assert 02 serial-absent '[EXC] parking:'

# The filter really narrowed the LIVE table: between `top: filter open` and
# `top: filter cleared` every row line the app dumped names COUNTER.BIN and
# nothing else (non-match rows hidden), and after the clear the dumped list
# names the seat and GOTOP again -- the full table restored, not a reprint of
# the narrowed one.
vgate_assert 02 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
try:
    op = next(i for i, l in enumerate(lines) if l.strip() == "top: filter open")
    cl = next(i for i, l in enumerate(lines) if l.strip() == "top: filter cleared")
except StopIteration:
    sys.exit("FAIL: filter open/cleared markers missing")
if cl <= op:
    sys.exit("FAIL: filter cleared precedes filter open")
narrowed = [l for l in lines[op:cl] if l.startswith("top: row pid=")]
if not narrowed:
    sys.exit("FAIL: no filtered row dump between open and cleared")
bad = [l for l in narrowed if "name=COUNTER.BIN" not in l]
if bad:
    sys.exit("FAIL: non-match rows visible while filtered: %s" % bad)
restored = [l for l in lines[cl:] if l.startswith("top: row pid=")]
names = {l.split("name=")[1].split(" ")[0] for l in restored if "name=" in l}
missing = {"COUNTER.BIN", "TABWM.BIN", "GOTOP.ELF"} - names
if missing:
    sys.exit("FAIL: full list not restored after clear; missing %s (saw %s)"
             % (sorted(missing), sorted(names)))
print("gotop filter ok: %d narrowed row(s) all COUNTER.BIN; restored names %s"
      % (len(narrowed), sorted(names)))
PY

# --- Run 03 (issue #2198): real CPU/MEM figures against a busy fixture ---------
#
# script2 execs GOSCALE.ELF once the seat is up; script3 execs GOTOP.ELF only
# after `goscale: released m=4` — by then the four spinning workers have held
# the cores for the whole ~6 s window, so the busy pid has real tick charges
# on whichever cores ran them (the per-core attribution is the point: a
# core-0-only charge would read 0 here). The run ends on `top: refreshed ok`
# from the post-'r' dump, which is program output — assert-proven, and the
# pre-0047 kernel cannot emit `top: usage` or cpu=/mem= row fields at all.
vgate_run 03 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2u.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --script3 '$RUN_DIR/script3u.txt' \
    --script3-after 'goscale: busy m=4' \
    --input-string 'r' \
    --input-string-after 'top: ready' \
    --script-expect 'top: refreshed ok' --timeout 240

vgate_assert 03 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 03 serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert 03 serial-contains 'goscale: busy m=4'
vgate_assert 03 serial-contains 'exec: loaded GOTOP.ELF'
vgate_assert 03 serial-contains 'top: ready'
vgate_assert 03 serial-contains 'top: usage cpux10='
vgate_assert 03 serial-contains 'top: refreshed ok'
vgate_assert 03 serial-absent '[EXC] parking:'

vgate_assert 03 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# The busy fixture's row must carry a nonzero tick count — real scheduler
# attribution, not wall-clock math.
busy = [l for l in lines if l.startswith("top: row pid=") and "name=GOSCALE.ELF" in l]
if not busy:
    sys.exit("FAIL: GOTOP never listed GOSCALE.ELF")
cpus = [int(m.group(1)) for l in busy
        for m in [re.search(r" cpu=(\d+)", l)] if m]
if not cpus or max(cpus) == 0:
    sys.exit("FAIL: GOSCALE.ELF rows have no nonzero cpu= tick count: %s" % busy)
# Memory: a live process (GOTOP itself) must report a real footprint.
gotop = [l for l in lines if "name=GOTOP.ELF" in l and "state=running" in l]
mems = [int(m.group(1)) for l in gotop
        for m in [re.search(r" mem=(\d+)", l)] if m]
if not mems or max(mems) == 0:
    sys.exit("FAIL: GOTOP.ELF rows have no nonzero mem= footprint: %s" % gotop)
# The machine summary: nonzero busy share and a real pool denominator.
us = [l for l in lines if l.startswith("top: usage cpux10=")]
if not us:
    sys.exit("FAIL: no `top: usage` marker — v2 rows never arrived")
m = re.search(r"cpux10=(\d+) memused=(\d+) memtotal=(\d+)", us[-1])
if not m or int(m.group(1)) == 0 or int(m.group(3)) == 0:
    sys.exit("FAIL: usage marker carries no real figures: %r" % us[-1])
print("gotop usage ok: busy cpu_ticks=%d, gotop mem=%dB, machine cpux10=%s"
      % (max(cpus), max(mems), m.group(1)))
PY


# --- Run 04 (issue #2198): PULSE renders the same real figures -----------------
#
# PULSE.ELF on the default seat: its usage seam negotiates the v2 row, so
# `pulse: usage` is the proof the bars have real numerators — it is absent
# on a pre-0047 kernel. The `2` chord repaints the Processes tab (CPU%/MEM
# columns) before the close. M194f (#3286) completes the owning-leg shape
# and repairs the chord race at once: the `2` rides AFTER `pulse: tick` —
# on a GOSCALE-busy guest the ready-anchored chord could outrun HID
# routing and never land — and the close waits on `pulse: key 2`, so the
# leg proves tick + key + repaint before the named quit, and the run ends
# on `pulse OK`, the last line of the app's own exit path.
vgate_file script4p.txt <<'EOS'
exec GOSCALE.ELF
EOS

vgate_file script4q.txt <<'EOS'
exec PULSE.ELF
EOS

vgate_file script4r.txt <<'EOS'
dui close 2
EOS

vgate_run 04 -- \
    --screen '$RUN_DIR/screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script4p.txt' \
    --script2 '$RUN_DIR/script4q.txt' \
    --script2-after 'goscale: released m=4' \
    --input-chords '2' \
    --input-chords-after 'pulse: tick' \
    --script3 '$RUN_DIR/script4r.txt' \
    --script3-after 'pulse: key 2' \
    --script-expect 'pulse OK' --timeout 240

vgate_assert 04 serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert 04 serial-contains 'exec: loaded PULSE.ELF'
vgate_assert 04 serial-contains 'pulse: ready'
vgate_assert 04 serial-contains 'pulse: procs '
vgate_assert 04 serial-contains 'pulse: usage cpux10='
vgate_assert 04 serial-contains 'pulse: key 2'
vgate_assert 04 serial-contains 'pulse: repainted'
vgate_assert 04 serial-contains 'pulse: tick'
vgate_assert 04 serial-contains 'pulse: close'
vgate_assert 04 serial-contains 'pulse OK'
vgate_assert 04 serial-absent '[EXC] parking:'

vgate_assert 04 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"pulse: usage cpux10=(\d+) memused=(\d+) memtotal=(\d+)", ser)
if not m:
    sys.exit("FAIL: no `pulse: usage` marker - the v2 rows never arrived")
if int(m.group(2)) == 0 or int(m.group(3)) == 0:
    sys.exit("FAIL: pulse usage has no real memory figures: %r" % m.group(0))
print("pulse usage ok: cpux10=%s memused=%sB memtotal=%sB" % m.groups())
PY


# --- Run 05 (M109c #2399): the agent-activity tab renders the audit lane ------
#
# A staged AGENT/AUDIT lane — three good receipts and one forged MAC —
# renders through the `g` chord: GOTOP marks each RCPT verified/forged
# under the shared agent-hmac row (served to GOTOP.ELF through the same
# app-bound SECRETS.TXT entry AGENTD uses). The leg fails before the tab
# exists: `top: tab=agent` and the `top: agent` markers are never printed.
vgate_file script5a.txt <<'EOS'
dui close 2
echo rx-gotop-agent-ok
EOS

vgate_run 05 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-string 'g' \
    --input-string-after 'top: ready' \
    --script3 '$RUN_DIR/script5a.txt' \
    --script3-after 'top: agent rcpt agent=- verb=session result=ok mark=v' \
    --script-expect 'rx-gotop-agent-ok' --timeout 150

vgate_assert 05 serial-contains 'exec: loaded GOTOP.ELF'
vgate_assert 05 serial-contains 'top: ready'
vgate_assert 05 serial-contains 'top: tab=agent'
vgate_assert 05 serial-contains 'top: agent n=5 verified=4 bad=1 key=yes'
vgate_assert 05 serial-contains 'top: agent rcpt agent=viewer verb=fs.read result=cap_required:file mark=v'
vgate_assert 05 serial-contains 'top: agent rcpt agent=mallory verb=gosh.run result=ok mark=!'
vgate_assert 05 serial-contains 'top: agent rcpt agent=ghost verb=proc.list result=ok mark=v'
vgate_assert 05 serial-contains 'top: agent rcpt agent=- verb=session result=ok mark=v'
vgate_assert 05 serial-contains 'top: win_close'
vgate_assert 05 serial-contains 'top: exiting 43'
vgate_assert 05 serial-contains 'rx-gotop-agent-ok'
vgate_assert 05 serial-absent '[EXC] parking:'


# --- Run 06 (M111d #2411): the gpu tab shows real slot-90 counters ------------
#
# GPUTRIANGLE.ELF's `gemm` journey does the real work first — a Metal GEMM
# submit through sys_gpucomp (slot 90) that the host's own counter line
# proves reached the device (compute-submits=1). GOTOP then opens on the
# same boot and `c` switches to the gpu tab; the `top: gpu` marker prints
# only after the handle-free STATS op returned the broker's block. The run
# ends on that marker — a boot in which the tab never sampled cannot reach
# it (assert-proven, run 03's convention).
vgate_file script6a.txt <<'EOF2'
exec GPUTRIANGLE.ELF gemm
EOF2

vgate_file script6b.txt <<'EOF2'
exec GOTOP.ELF
EOF2

vgate_run 06 -- \
    --screen '$RUN_DIR/screen' \
    --gpu3d-metal \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script6a.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --script3 '$RUN_DIR/script6b.txt' \
    --script3-after 'gputri: gemm c=19,22,43,50' \
    --input-string 'c' \
    --input-string-after 'top: ready' \
    --script-expect 'top: gpu busy=' --timeout 180

vgate_assert 06 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 06 serial-contains 'exec: loaded GPUTRIANGLE.ELF'
vgate_assert 06 serial-contains 'gputri: gemm c=19,22,43,50 submits=1 completed=1'
vgate_assert 06 serial-contains 'exec: loaded GOTOP.ELF'
vgate_assert 06 serial-contains 'top: ready'
vgate_assert 06 serial-contains 'top: tab=gpu'
vgate_assert 06 serial-contains 'top: gpu busy='
vgate_assert 06 serial-absent 'top: gpu err='
vgate_assert 06 serial-absent '[EXC] parking:'
# The runner advertised the second capset and a REAL compute pipeline; one
# submit reached Metal — the host's own ledger, not the guest's claim.
vgate_assert 06 output-contains 'VIC1 capset 0x56494331'
vgate_assert 06 output-contains 'compute=1'
vgate_assert 06 output-contains 'compute-submits=1'

# The marker's counters are real: a completed submit means submits/completed
# are nonzero and lastus carries the kernel's measured run time. busy and
# queued are instantaneous flags — honestly zero after the fence — and are
# pinned present, not nonzero.
vgate_assert 06 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
marks = [l for l in ser.splitlines() if l.strip().startswith("top: gpu busy=")]
if not marks:
    sys.exit("FAIL: no `top: gpu` stats marker — the tab never sampled")
m = re.search(r"busy=(\d+) queued=(\d+) sessions=(\d+) lastus=(\d+)"
              r" totalus=(\d+) submits=(\d+) completed=(\d+)"
              r" refusals=(\d+) timeouts=(\d+)", marks[-1])
if not m:
    sys.exit("FAIL: `top: gpu` marker is not the full counter set: %r" % marks[-1])
busy, queued, sessions, lastus, totalus, submits, completed, refusals, timeouts = \
    (int(g) for g in m.groups())
if submits < 1 or completed < 1:
    sys.exit("FAIL: no submit completed in the ledger: %r" % marks[-1])
if lastus < 1 or totalus < 1:
    sys.exit("FAIL: no kernel time recorded: %r" % marks[-1])
print("gotop gpu ok: submits=%d completed=%d lastus=%d busy=%d queued=%d"
      % (submits, completed, lastus, busy, queued))
PY


# --- Run 07 (M113e #2421): the trust tab renders real posture -----------------
#
# script7a arms the echo peer and runs both fixture apps under their
# GRANTS.TXT rows: CONFINE.BIN (wildcard `file`) receipts audit:net_denied
# on its socket path AND still connects — audit records the would-be
# denial, it does not refuse — while GRANTD.BIN (hash-bound `file,net`)
# connects clean and receipts only audit:debug_denied. script7b then opens
# GOTOP through the monitor's ADMIN spawn (`exec -u0` — uid_system +
# kernel_caps, the CAP_PROC_ADMIN half of the slot-89 gate) so the grant
# table is actually served to the view; `t` switches to the trust tab.
#
# The markers are the view's own evidence: per app, the OWNERS.TXT uid,
# the declared-vs-granted word split (STORE.TXT ReleaseCaps vs the live
# grant row), the viewer-measured sha256 against the row's pin, and the
# publisher fingerprint derived off the FLINT stream replica — plus the
# kernel's RCPT.TXT receipts verbatim. The kernel's own serial receipts
# (`audit:*_denied name=...`) are the cross-proof that the rendered
# denied-word set is the real posture.
#
# Issue #2982 extends the leg: slot 89 op 2 drains the kernel's
# denial-receipt ring at EL0, so the trust tab now also renders the
# OBSERVED denials — `top: trust denial app=<n> verdict=<v> word=<w>`
# per (app, verdict, word) group, then the `top: trust denials n=<k>
# dropped=<d>` summary. The python assert pairs every rendered entry
# with the kernel's own `<v>:<w>_denied name=<n>` serial receipt — the
# same boot, the same denial.
#
# The ring is 32 entries deep and TABWM.BIN receipts audit:file_denied
# on a steady cadence (observed: ~800 while the fixture apps run), so
# receipts emitted early are evicted before GOTOP reads. script7a
# therefore execs GOTOP WITH the fixture apps and script7b — gated on
# `top: ready`, when the boot's flood has subsided — re-execs them
# (GRANTD first so its debug_denied lands ahead of CONFINE's
# net_denied). `ta` types `t` to render the trust tab and `a` to arm the
# 1 Hz auto-refresh, which re-drains the ring and reprints the marker
# block every tick. The run's expect is CONFINE's own rendered denial:
# it cannot match until a refresh has observed a FRESH receipt inside
# the ring window, and the --expect-tail holds the boot for GRANTD's
# (earlier-receipted) entry and the summary to land too.
vgate_file script7a.txt <<'EOS'
net ip 10.0.0.1
net arp 10.0.0.2
exec CONFINE.BIN
exec GRANTD.BIN
exec -u0 GOTOP.ELF
EOS

vgate_file script7b.txt <<'EOS'
exec GRANTD.BIN
exec CONFINE.BIN
EOS

vgate_run 07 -- \
    --screen '$RUN_DIR/screen' \
    --net '$RUN_DIR/cap7.bin' \
    --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:9999 \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script7a.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --script3 '$RUN_DIR/script7b.txt' \
    --script3-after 'top: ready' \
    --input-string 'ta' \
    --input-string-after 'top: ready' \
    --script-expect 'top: trust denial app=CONFINE.BIN verdict=audit word=net' \
    --script-expect-tail 5 --timeout 180

vgate_assert 07 serial-contains 'exec: loaded CONFINE.BIN'
vgate_assert 07 serial-contains 'exec: loaded GRANTD.BIN'
vgate_assert 07 serial-contains 'exec: loaded GOTOP.ELF'
vgate_assert 07 serial-contains 'top: ready'
vgate_assert 07 serial-contains 'top: tab=trust'
vgate_assert 07 serial-contains 'top: trust n='
vgate_assert 07 serial-contains 'top: trust app name=CONFINE.BIN'
vgate_assert 07 serial-contains 'top: trust app name=GRANTD.BIN'
vgate_assert 07 serial-contains 'top: trust rcpt RCPT stage=kernel'
vgate_assert 07 serial-contains 'top: trust denial app=CONFINE.BIN verdict=audit word=net'
vgate_assert 07 serial-contains 'top: trust denial app=GRANTD.BIN verdict=audit word=debug'
vgate_assert 07 serial-contains 'top: trust denials n='
vgate_assert 07 serial-absent 'top: trust denials err='
vgate_assert 07 serial-absent 'top: trust table=err='
vgate_assert 07 serial-absent '[EXC] parking:'

# The confined app's rendered posture vs the kernel's own receipts: GOTOP
# shows granted=file and a denied set carrying net — and the kernel
# DID receipt audit:net_denied for that same app on the same boot. The
# granted app: hash-bound pin matches GOTOP's own measurement of the
# staged bytes (verdict=match), declared==granted (file,net), and the
# publisher fingerprint is the staged replica's head-change author.
vgate_assert 07 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()

apps = {}
for l in lines:
    m = re.match(r"top: trust app name=(\S+) uid=(\S+) declared=(\S+)"
                 r" granted=(\S+) denied=(\S+) state=(\S+)", l.strip())
    if m:
        apps[m.group(1)] = m.groups()

for want in ("CONFINE.BIN", "GRANTD.BIN"):
    if want not in apps:
        sys.exit("FAIL: no trust row for %s (saw %s)" % (want, sorted(apps)))

co = apps["CONFINE.BIN"]
if co[1] != "1000":
    sys.exit("FAIL: CONFINE.BIN uid=%s want the uid_user default 1000" % co[1])
if co[3] != "file":
    sys.exit("FAIL: CONFINE.BIN granted=%s want file" % co[3])
if "net" not in co[4].split(","):
    sys.exit("FAIL: CONFINE.BIN denied=%s does not carry net" % co[4])

gr = apps["GRANTD.BIN"]
if gr[1] != "0":
    sys.exit("FAIL: GRANTD.BIN uid=%s want the OWNERS uid_system row" % gr[1])
if gr[2] != "file,net" or gr[3] != "file,net":
    sys.exit("FAIL: GRANTD.BIN declared/granted = %s/%s want file,net/file,net"
             % (gr[2], gr[3]))

# The measured digest against the row's pin — GOTOP's own sha256 of the
# staged file must equal the host-side pin the setup wrote into GRANTS.TXT.
shas = {}
for l in lines:
    m = re.match(r"top: trust sha name=(\S+) measured=(\S+) pin=(\S+)"
                 r" verdict=(\S+)", l.strip())
    if m:
        shas[m.group(1)] = m.groups()
g = shas.get("GRANTD.BIN")
if not g or g[3] != "match" or g[2] != g[1]:
    sys.exit("FAIL: GRANTD.BIN sha marker = %r" % (g,))
c = shas.get("CONFINE.BIN")
if not c or c[3] != "wild":
    sys.exit("FAIL: CONFINE.BIN sha marker = %r" % (c,))

pubs = {}
for l in lines:
    m = re.match(r"top: trust pub name=(\S+) stream=(\S+) publisher=(\S+)",
                 l.strip())
    if m:
        pubs[m.group(1)] = m.groups()
p = pubs.get("GRANTD.BIN")
if not p or p[1] != "trustrel" or p[2] != "0123abcd" * 8:
    sys.exit("FAIL: GRANTD.BIN publisher = %r (want the staged head "
             "author)" % (p,))
if pubs.get("CONFINE.BIN", (None, None, "x"))[2] != "-":
    sys.exit("FAIL: untracked CONFINE.BIN shows a publisher: %r"
             % (pubs.get("CONFINE.BIN"),))

# Cross-proof: the kernel's own denial receipts for the same apps on the
# same boot — the rendered denied= set names what the kernel receipted.
if "audit:net_denied name=CONFINE.BIN" not in ser:
    sys.exit("FAIL: kernel never receipted CONFINE.BIN's net denial")
if "audit:debug_denied name=GRANTD.BIN" not in ser:
    sys.exit("FAIL: kernel never receipted GRANTD.BIN's debug denial")
if "name=GRANTD.BIN word=net" in ser:
    sys.exit("FAIL: GRANTD.BIN's granted word receipted a denial")

# The observed-denial leg (#2982): every rendered `top: trust denial`
# entry must pair with the kernel's own serial receipt for the same
# boot — the op-2 ring is evidence, not a prediction. The summary's
# count must cover at least the two receipted denials above.
denials = []
for l in lines:
    m = re.match(r"top: trust denial app=(\S+) verdict=(\S+) word=(\S+)",
                 l.strip())
    if m:
        denials.append(m.groups())
if not denials:
    sys.exit("FAIL: no `top: trust denial` markers — the op-2 drain "
             "never reached the trust tab")
for app, verdict, word in denials:
    want = "%s:%s_denied name=%s" % (verdict, word, app)
    if want not in ser:
        sys.exit("FAIL: rendered denial %s:%s_denied app=%s has no "
                 "kernel receipt (%r not on serial)"
                 % (verdict, word, app, want))
pairs = set((a, w) for a, v, w in denials)
if ("CONFINE.BIN", "net") not in pairs:
    sys.exit("FAIL: CONFINE.BIN's receipted net denial not rendered")
if ("GRANTD.BIN", "debug") not in pairs:
    sys.exit("FAIL: GRANTD.BIN's receipted debug denial not rendered")
m = re.search(r"top: trust denials n=(\d+) dropped=(\d+)", ser)
if not m or int(m.group(1)) < 2:
    sys.exit("FAIL: denials summary missing or under-counted: %r"
             % (m.group(0) if m else None,))
print("gotop trust ok: confined granted=file denied(+net), "
      "granted pin=match pub derived, kernel receipts agree, "
      "%d observed-denial entries cross-proven" % len(denials))
PY


# --- Run 08 (M128d #2608): the profile-info line — guest-visible identity ----
#
# The minted fixture carries a KNOWN summary: profile `prof`, base
# `base.img`, its `.prev` sibling (rollback=yes), and two SNAPSHOTS/
# members (snaps=2). GOTOP opens on the profile's own share over
# --virtio-fs with the ctl listener armed; the `top: profile` marker
# prints only after the slot-93 session answered — a boot in which the
# verb never reached the host, or the kernel dropped `result`, cannot
# emit it (assert-proven, run 03's convention).
vgate_file script8.txt <<'EOF'
exec GOTOP.ELF
EOF

# --overlay-base repeats so the fixture's base.img (with its .prev
# sibling) is the effective base — the last flag wins, so the answer's
# base/rollback fields name the file the run actually booted.
vgate_run 08 -- --profile '$RUN_DIR/prof.virelaivm' \
    --overlay-base '$RUN_DIR/base.img' \
    --vsock --vsock-ctl \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script8.txt' \
    --script-expect 'top: profile name=prof base=base.img rollback=yes snaps=2' --timeout 150

vgate_assert 08 output-contains 'VSOCK-CTL: host listener armed port=1209'
vgate_assert 08 output-contains 'identity=org.virelaios.vm.prof (loaded)'
vgate_assert 08 serial-contains 'vsock-ctl: authed'
vgate_assert 08 serial-contains 'exec: loaded GOTOP.ELF'
vgate_assert 08 serial-contains 'top: ready'
vgate_assert 08 serial-contains 'top: profile name=prof base=base.img rollback=yes snaps=2'
vgate_assert 08 serial-absent 'top: profile refused'
vgate_assert 08 serial-absent '[EXC] parking:'


# --- Run 09 (M160b #2990): the mounts tab carries real free space -----------
#
# `m` switches to the mounts tab; its per-row serial dump now ends in
# `free=<bytes|->`. The host row must carry a NUMERIC free — the slot-37
# STATFS answer, not the pre-M160b EINVAL painted as `-`.
vgate_file script9.txt <<'EOS'
exec GOTOP.ELF
EOS

vgate_run 09 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script9.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-string 'm' \
    --input-string-after 'top: ready' \
    --script-expect 'top: mount host' --timeout 120

vgate_assert 09 serial-contains 'exec: loaded GOTOP.ELF'
vgate_assert 09 serial-contains 'top: ready'
vgate_assert 09 serial-contains 'top: tab=mounts'
vgate_assert 09 serial-contains 'top: mounts n='
vgate_assert 09 serial-contains 'top: mount host'
vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"top: mount host state=\S+ kind=\S+ flags=\S+ free=(\d+)", ser)
if not m:
    sys.exit("FAIL: no numeric free= on the host mount row: %r"
             % ([l for l in ser.splitlines() if "top: mount host" in l],))
print("gotop mounts free=%d" % int(m.group(1)))
PY


# --- Run 10 (M192d #3249): the appver-1 envelope's SAVE half -----------------
#
# The go-fileman run 07 shape under the Go seat: GOTABWM seats the boot,
# `2 2` sorts the procs tab by NAME descending (non-default column AND
# direction), `r` dumps the live order, `m` makes mounts the active tab,
# then ctrl-shift-s. The seat posts the kind-20 ask; GOTOP stages
# `u8 fmtver | u8 page | u8 col | u8 dir` = 4 bytes at the rendezvous and
# posts the request; the seat stores the blob on the tab's SESSION.TABS
# record and republishes. The trailer is asserted byte-level: AS magic,
# appver=1, and the exact field bytes the chords produced.
vgate_file script-10.txt <<'EOF'
set GOMAXPROCS=1
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-10.txt <<'EOF'
dui focus 0
exec GOTOP.ELF
EOF

vgate_file script3-10.txt <<'EOF'
wm
dui
echo rx-gotop-state-save-ok
EOF

vgate_run 10 -- \
    --screen '$RUN_DIR/screen-10' \
    --via-virtio \
    --script '$RUN_DIR/script-10.txt' \
    --script2 '$RUN_DIR/script2-10.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords '2,2,r,m,ctrl-shift-s' \
    --input-chords-after 'top: ready' \
    --script3 '$RUN_DIR/script3-10.txt' \
    --script3-after 'gotabwm: snapshot saved' \
    --script-expect 'rx-gotop-state-save-ok' --timeout 300

vgate_assert 10 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 10 serial-contains 'gotabwm: registered'
vgate_assert 10 serial-contains 'exec: loaded GOTOP.ELF'
vgate_assert 10 serial-contains 'top: tab-aware (full-viewport)'
vgate_assert 10 serial-contains 'top: ready'
# A fresh tab honestly has no stored state — no restore marker may print.
vgate_assert 10 serial-absent 'top: state restored'
vgate_assert 10 serial-absent 'top: state refused'
# The two sort chords and the refresh landed; the mounts tab is live.
vgate_assert 10 serial-contains 'top: refreshed ok'
vgate_assert 10 serial-contains 'top: tab=mounts'
vgate_assert 10 serial-contains 'top: mounts n='
# The SEAT's half: the snapshot chord asked the bound tab; GOTOP staged
# 4 bytes at appver 1 (fmtver + page=mounts + col=name + dir=desc) and the
# seat stored + republished the session carrying them.
vgate_assert 10 serial-contains 'gotabwm: state ask id='
vgate_assert 10 serial-contains 'gotabwm: state save id='
vgate_assert 10 serial-contains 'len=4 ver=1'
vgate_assert 10 serial-contains 'top: state save tab=mounts sort=name dir=desc len=4'
vgate_assert 10 serial-contains 'gotabwm: snapshot saved '
vgate_assert 10 serial-absent 'gotabwm: state drop'
# Byte-level on the share: the .tabs v2 AS trailer framing and the blob's
# own fields — byte identity is the card's claim, not a checksum.
vgate_assert 10 python <<'PY'
import os, sys
b = open(os.path.join(os.environ["VG_SHARE"], "SESSION.TABS"), "rb").read()
if b[0] != 2 or b[2] != 1:
    sys.exit("SESSION.TABS header ver=%d count=%d" % (b[0], b[2]))
off = 6 + 69
if len(b) < off + 6 + 8 + 4:
    sys.exit("SESSION.TABS too short for a state trailer: %d" % len(b))
if b[off:off+2] != b"AS" or b[off+2] != 1 or b[off+3] != 1:
    sys.exit("app_state header %r" % b[off:off+6])
ent = b[off+6:off+14]
if ent[0] != 0 or ent[1] != 1:
    sys.exit("app_state entry index=%d appver=%d" % (ent[0], ent[1]))
ln = int.from_bytes(ent[4:8], "little")
blob = b[off+14:off+14+ln]
# GOTOP blob v1: u8 fmtver | u8 page | u8 col | u8 dir.
# page 5 = mounts, col 1 = name, dir 0 = descending.
if blob != bytes([1, 5, 1, 0]):
    sys.exit("blob %r is not [fmtver=1 page=5 col=1 dir=0]" % bytes(blob))
print("SESSION.TABS app_state: idx=0 appver=1 len=%d "
      "tab=mounts sort=name dir=desc" % ln)
PY
# The `r` dump after the sort chords IS the saved ordering: every dumped
# name is >= the next under the app's case-insensitive comparator (name
# descending — the non-default sort the blob recorded).
vgate_assert 10 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
ref = next((i for i, l in enumerate(lines) if l.strip() == "top: refreshed ok"), None)
if ref is None:
    sys.exit("FAIL: no `top: refreshed ok` — the r chord never landed")
procs = max(i for i, l in enumerate(lines[:ref]) if l.startswith("top: procs n="))
names = [m.group(1) for l in lines[procs:ref]
         for m in [re.search(r"top: row pid=\d+ name=(\S+)", l)] if m]
if len(names) < 2:
    sys.exit("FAIL: fewer than two rows dumped after the sort: %r" % names)
if names != sorted(names, key=str.lower, reverse=True):
    sys.exit("FAIL: post-sort dump is not name-descending: %r" % names)
print("gotop save leg: %d rows dumped name-descending %r" % (len(names), names))
PY
vgate_assert 10 serial-contains 'rx-gotop-state-save-ok'
vgate_assert 10 serial-absent '[EXC] parking:'
vgate_assert 10 serial-absent 'exited status=139'


# --- Run 11 (M192d #3249): the RESTORE half ---------------------------------
#
# A FRESH boot on the share run 10 left: the seat loads SESSION.TABS,
# re-execs GOTOP.ELF (no argv — the recorded row carries only the bin),
# and the app's restore_state request gets the blob back byte-intact. The
# proof is the app's own verdicts: `state restored tab=mounts sort=name
# dir=desc` names the round trip, and the startup row dump — printed under
# the restored sort before any user key — lands in the same
# name-descending order run 10 saved.
vgate_file script-11.txt <<'EOF'
set GOMAXPROCS=1
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-11.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-11.txt <<'EOF'
wm
dui
echo rx-gotop-state-restore-ok
EOF

vgate_run 11 -- \
    --screen '$RUN_DIR/screen-11' \
    --via-virtio \
    --script '$RUN_DIR/script-11.txt' \
    --script2 '$RUN_DIR/script2-11.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-11.txt' \
    --script3-after 'top: state restored' \
    --script-expect 'rx-gotop-state-restore-ok' --timeout 300

vgate_assert 11 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 11 serial-contains 'gotabwm: registered'
vgate_assert 11 serial-contains 'gotabwm: session load n=1 mode=restore'
vgate_assert 11 serial-contains 'gotabwm: session reexec n=1'
vgate_assert 11 serial-contains 'gotabwm: session exec GOTOP.ELF'
vgate_assert 11 serial-contains 'gotabwm: session live n=1'
# The seat's re-exec path, not the monitor `exec` builtin — the load's
# proof is the app's own open marker (`exec: loaded` is a monitor line).
vgate_assert 11 serial-contains 'top: open id='
vgate_assert 11 serial-contains 'top: tab-aware (full-viewport)'
# The seat staged the stored blob for the re-exec'd tab and the app's own
# decode applied it — the full protocol leg: the mounts tab is active and
# the sort is the saved name-descending.
vgate_assert 11 serial-contains 'gotabwm: state restore id='
vgate_assert 11 serial-contains 'len=4 ver=1'
vgate_assert 11 serial-contains 'top: tab=mounts'
vgate_assert 11 serial-contains 'top: state restored tab=mounts sort=name dir=desc'
vgate_assert 11 serial-contains 'top: mounts n='
vgate_assert 11 serial-contains 'top: procs n='
vgate_assert 11 serial-contains 'top: ready'
vgate_assert 11 serial-absent 'top: state refused'
vgate_assert 11 serial-absent 'gotabwm: state drop'
# Same ordering: the startup dump between the restore marker and `top:
# ready` is the post-restore listing — non-increasing names, and NOT the
# pid-ascending default a cold start would print.
vgate_assert 11 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
res = next((i for i, l in enumerate(lines)
            if l.strip().startswith("top: state restored")), None)
rdy = next((i for i, l in enumerate(lines) if l.strip() == "top: ready"), None)
if res is None or rdy is None or rdy <= res:
    sys.exit("FAIL: restore/ready markers missing or misordered")
names = [m.group(1) for l in lines[res:rdy]
         for m in [re.search(r"top: row pid=\d+ name=(\S+)", l)] if m]
if len(names) < 2:
    sys.exit("FAIL: fewer than two rows dumped after restore: %r" % names)
if names != sorted(names, key=str.lower, reverse=True):
    sys.exit("FAIL: restored listing is not name-descending: %r" % names)
pids = [int(m.group(1)) for l in lines[res:rdy]
        for m in [re.search(r"top: row pid=(\d+)", l)] if m]
if pids == sorted(pids):
    sys.exit("FAIL: restored listing is pid-ascending — the default sort, "
             "not the saved one: %r" % pids)
print("gotop restore leg: %d rows in the saved name-desc order %r"
      % (len(names), names))
PY
vgate_assert 11 serial-contains 'rx-gotop-state-restore-ok'
vgate_assert 11 serial-absent '[EXC] parking:'
vgate_assert 11 serial-absent 'exited status=139'
