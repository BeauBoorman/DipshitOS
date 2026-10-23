# live-trust-modes.spec -- M50 TS2 class-B gate (issue #1136, ADR 0024 D3/D4/D8),
# retargeted to GOSH by M68b (#1450).
#
# The ownership/mode boundary live, on one share with a host-seeded
# `OWNERS.TXT`: (1) a uid_system-owned 0600 file is EACCES for uid_user
# through the file ABI (`cat < FILE`); (2) an UNLISTED file follows the
# documented default policy (0644, owner uid_user) and reads — the empty
# table is today's behavior; (3) the owner `chmod`s it and the guest-written
# `OWNERS.TXT` is inspected ON THE HOST; (4) a secret-class `SECRETS.TXT` is
# denied at BOTH seams (the monitor's `vf cat` and the EL0 file ABI) and its
# value never appears in the transcript. Boot default unchanged: no new
# syscall is on the boot path; a clean share has no OWNERS.TXT.

vgate_name live-trust-modes "#1136 TS2: ownership/mode EACCES, owner chmod persists to OWNERS.TXT, secret class denied"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# The EL1h monitor session: prove the DIRECT-CONSUMER seam first (the monitor
# is uid_system + CAP_FS_ANY, yet a secret read is denied) at BOTH the `vf
# cat` verb and the kernel `sh <script>` loader, then hand the console to
# GOSH (serial front-end) for the EL0 file-ABI session.
vgate_file script.txt <<'EOF'
vf cat SECRETS.TXT
sh SECRETS.TXT
exec GOSH.ELF serial
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOSH.ELF")
if not os.path.exists(src):
    sys.exit("GOSH.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gosh.sh")
shutil.copy(src, os.path.join(share, "GOSH.ELF"))
print("staged GOSH.ELF (%d bytes) into share" % os.path.getsize(src))
PY

vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
# Host-seeded files + OWNERS.TXT (`#v1`; uid_system = 0).
open(os.path.join(share, "TARGET.TXT"), "w").write("ts2-owner-content\n")
open(os.path.join(share, "PLAIN.TXT"), "w").write("ts2-plain-content\n")
open(os.path.join(share, "SECRETS.TXT"), "w").write("ts2-secret-value\n")
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\n"
    "TARGET.TXT\t600\t0\t-\n"
    "SECRETS.TXT\t600\t0\tsecret\n"
)
# The EL0 shell session; CR (0x0d) submits on this seam. TARGET.TXT is read
# BOTH ways (a direct `cat FILE` argument and a `< FILE` redirect) so the
# denial message is pinned on both paths, and GONE.TXT does not exist, which
# pins the production shape of an ordinary missing file: the message must
# carry the kernel's ENOENT rather than a generic "not found".
open(os.path.join(rd, "edit.bin"), "wb").write(
    b"cat TARGET.TXT\r"
    b"cat < TARGET.TXT\r"
    b"cat < GONE.TXT\r"
    b"cat < PLAIN.TXT\r"
    b"chmod 600 PLAIN.TXT\r"
    b"cat < SECRETS.TXT\r"
    b"echo ts2-done\r"
)
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/edit.bin' \
    --script2-after 'gosh: attached' \
    --script-expect 'ts2-done' \
    --script-expect-tail 16 \
    --timeout 90

# Direct-consumer seam: the monitor's own secret read is denied for every actor
# (`vf cat`), and the kernel `sh <script>` content loader is denied too.
vgate_assert 01 serial-contains 'vf cat: SECRETS.TXT: permission denied'
vgate_assert 01 serial-contains 'sh: SECRETS.TXT: permission denied'
# EL0 file ABI: owner mismatch (uid_system-owned 0600, caller uid_user). The
# count is 2 on purpose -- `cat TARGET.TXT` and `cat < TARGET.TXT` are
# different code paths in the shell (bCat's own open vs the redirect's), and
# each must report the same kernel errno.
vgate_assert 01 serial-count 'gosh: cannot open TARGET.TXT: EACCES' 2
# An ordinary missing file names the real errno too (not a generic fallback).
vgate_assert 01 serial-contains 'gosh: cannot open GONE.TXT: ENOENT'
# Default policy: the unlisted file reads (the empty/absent table behavior).
vgate_assert 01 serial-contains 'ts2-plain-content'
# Owner chmod succeeds and persists.
vgate_assert 01 serial-contains 'chmod: ok'
# Secret class: file-ABI read denied even though it is uid_system-owned 0600.
vgate_assert 01 serial-contains 'gosh: cannot open SECRETS.TXT: EACCES'
vgate_assert 01 serial-contains 'ts2-done'
# The secret value never reaches the serial transcript.
vgate_assert 01 serial-absent 'ts2-secret-value'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

# The guest-written OWNERS.TXT, inspected on the host: the chmod persisted a
# canonical entry (group triplet zero), the pre-existing system-owned entry
# survived, and the secret class was not stripped.
vgate_assert 01 python <<'PY'
import os, sys
p = os.path.join(os.environ["VG_SHARE"], "OWNERS.TXT")
try:
    body = open(p, errors="replace").read()
except OSError:
    sys.exit("FAIL: OWNERS.TXT missing from the host share")
if "PLAIN.TXT\t600\t1000\t-" not in body:
    sys.exit("FAIL: guest-written PLAIN.TXT entry missing: " + repr(body))
if "TARGET.TXT\t600\t0\t-" not in body:
    sys.exit("FAIL: pre-existing TARGET.TXT entry lost")
if "SECRETS.TXT\t600\t0\tsecret" not in body:
    sys.exit("FAIL: SECRETS.TXT secret class lost")
print("trust-modes host inspection ok")
PY

# ---------------------------------------------------------------------------
# M173d (#3045, ADR 0052 amendment): the two-principal journey. AGENTD runs
# under uid_agent via the monitor's -u2000 admin spawn; its gosh.run child
# inherits the principal (index D15). From inside: a uid_user file reads
# (other-triplet), the 0600 VAULT.BIN refuses EACCES, a mutation and a
# create outside AGENT/ refuse, a write inside the agent-owned root lands,
# and a kill on the uid_user GOTOP refuses EACCES. Then the user side
# (uid_user GOTOP, no CAP_PROC_ADMIN) stops AGENTD — the D12 asymmetry.
# The kernel receipts on serial are the exec-stage RCPT lines; the uid
# attribution leg reads the monitor's `procs` rows (uid=2000) — the RCPT
# `uid=` field itself is #3044's format change. AGENTD's own dispatch
# receipts land MAC'd in AGENT/AUDIT/.
# ---------------------------------------------------------------------------

vgate_file script-agent.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec -u2000 AGENTD.ELF --allow-exec
procs
EOF

vgate_file script-gotop.txt <<'EOF'
exec GOTOP.ELF
EOF

vgate_file script-post.txt <<'EOF'
procs
echo modes-agent-done
EOF

# Run 02 rides its OWN share (--cvc-file overrides the armed share for
# that boot, the go-agentd posture-leg pattern): run 01's OWNERS.TXT and
# SECRETS.TXT rows are the TS2 fixture and must not be disturbed.
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.path.join(rd, "agent-share")
os.makedirs(share, exist_ok=True)
for name, cmd in (("AGENTD.ELF", "bash tools/go/build-agentd.sh"),
                  ("GOSH.ELF", "bash tools/go/build-gosh.sh"),
                  ("GOTOP.ELF", "bash tools/go/build-top.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: " + cmd)
    shutil.copy(src, os.path.join(share, name))
sys.path.insert(0, os.path.join("tools", "agentctl"))
import agentctl
KEY = "a5" * 32
DEVIN_SEED = "0a" * 32
# uid_agent owns the channel key now: the daemon reads agent-hmac as
# uid 2000, app-bound to the system-owned image.
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\nagent-hmac\t2000\t" + KEY + "\tAGENTD.ELF\n")
open(os.path.join(share, "AGENTS.TXT"), "w").write(
    "#v1\nagent=devin key="
    + agentctl.ed_public_key(bytes.fromhex(DEVIN_SEED)).hex()
    + " caps=file,process,term\n")
open(os.path.join(rd, "devin.key"), "w").write(
    "devin " + DEVIN_SEED + "\n")
os.makedirs(os.path.join(share, "GOVAULT"), exist_ok=True)
open(os.path.join(share, "GOVAULT", "VAULT.BIN"), "wb").write(b"vault-ciphertext\n")
open(os.path.join(share, "USERFILE.TXT"), "w").write("boundary-user-content\n")
os.makedirs(os.path.join(share, "AGENT", "AUDIT"), exist_ok=True)
# OWNERS: AGENTD.ELF system-owned (the app-bound secret's M97g honesty
# rule), AGENTS.TXT world-readable, the vault 0600 uid_user (the agent's
# other triplet is nothing), the user file the explicit 0644 uid_user.
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\n"
    "AGENTD.ELF\t644\t0\t-\n"
    "AGENTS.TXT\t444\t0\t-\n"
    "USERFILE.TXT\t644\t1000\t-\n"
    "GOVAULT/VAULT.BIN\t600\t1000\t-\n"
)
print("boundary share staged")
PY

vgate_run 02 -- --cvc-file '$RUN_DIR/agent-share' \
    --display --input \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=boundary' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-agent.txt' \
    --script2 '$RUN_DIR/script-gotop.txt' --script2-after 'agentd: listen 4747' \
    --input-string 'k' --input-string-after 'agentd: session end reason=client_close' \
    --script3 '$RUN_DIR/script-post.txt' --script3-after 'tasks user-exec exited status=137' \
    --script-expect 'modes-agent-done' --script-expect-tail 8 --timeout 240

# The daemon came up as the agent principal: uid_agent + caps 0.
vgate_assert 02 serial-contains 'agentd: start exec=on'
vgate_assert 02 serial-contains 'agentd: listen 4747'
vgate_assert 02 serial-contains 'agentd: auth ok agent=devin'
vgate_assert 02 serial-contains 'procs: id=1 name=AGENTD.ELF uid=2000 caps=0'
# The kernel's exec receipts name the agent image and its child.
vgate_assert 02 serial-contains 'RCPT stage=exec'
vgate_assert 02 serial-contains 'verb=gosh.run ok'
vgate_assert 02 serial-contains 'agentd: session end reason=client_close'
vgate_assert 02 output-contains 'AGENTCTL: PASS boundary'
# The D12 asymmetry: uid_user GOTOP stops uid_agent AGENTD without the cap.
vgate_assert 02 serial-contains 'top: kill pid=1'
vgate_assert 02 serial-absent 'top: kill pid=1 err='
vgate_assert 02 serial-contains 'tasks user-exec exited status=137'
# Post-kill procs: the agent principal's row is exited, the user's is not.
vgate_assert 02 serial-contains 'name=AGENTD.ELF uid=2000 caps=0 state=exited'
vgate_assert 02 serial-contains 'name=GOTOP.ELF uid=1000 caps=0 state=running'
vgate_assert 02 serial-absent '\[EXC\]'
vgate_assert 02 serial-absent '[EXC] parking:'

# Host side: the agent's write landed inside its root, the outside-sandbox
# write never materialized, the user file is untouched, and every dispatch
# left a MAC'd receipt in the agent-owned audit lane.
vgate_assert 02 python <<'PY'
import os, sys
share = os.path.join(os.environ["RUN_DIR"], "agent-share")
if open(os.path.join(share, "AGENT", "WROTE.TXT"), "rb").read() != b"boundary-write":
    sys.exit("FAIL: agent write inside AGENT/ missing or wrong")
if os.path.exists(os.path.join(share, "OUTSIDE.TXT")):
    sys.exit("FAIL: the outside-sandbox write materialized")
if open(os.path.join(share, "USERFILE.TXT"), "rb").read() != b"boundary-user-content\n":
    sys.exit("FAIL: USERFILE.TXT changed (the agent's chmod was refused)")
adir = os.path.join(share, "AGENT", "AUDIT")
names = [n for n in os.listdir(adir) if n.startswith("RCPT-") and not n.endswith("~")]
if not names:
    sys.exit("FAIL: no agentd dispatch receipts in AGENT/AUDIT")
print("boundary host inspection ok: %d receipts, write inside only" % len(names))
PY

# ---------------------------------------------------------------------------
# M188a (#3186, ADR 0054 amendment): the manifest `caps=` ceiling. One probe
# binary ships under two names on a mode=enforce share; both get a wildcard
# GRANTS.TXT row granting file+window+net, but only CAPSP.ELF has an
# APPS.TXT row — caps=file (which strips net AND window the row granted).
# The row is the controlled variable: same bytes, same grant, different
# declared set.
#   * CAPSP.ELF — the file read lands (declared), the listen is refused
#     EACCES and the kernel receipts `refused:caps_denied` naming the word
#     the manifest stripped (word=net), not a crash.
#   * NOCAPS.ELF — no manifest row: the caps-less spawn is unchanged —
#     both boundary verbs work, no denial receipt names it.
# ---------------------------------------------------------------------------

vgate_file caps_probe.go <<'EOF'
package main

import (
    "virelai/vi"
    "virelai/vsys"
)

func main() {
    if _, rc := vi.ReadFileAll("PROBE.TXT", 64); rc < 0 {
        vsys.Println("capsprobe: file refused " + vi.ErrnoName(rc))
    } else {
        vsys.Println("capsprobe: file read")
    }
    // Slot 9 (net word): a listen-table bind needs no wire state — when
    // granted it just succeeds, when caps-stripped it returns EACCES.
    if rc := vi.UDPListen(4871); rc < 0 {
        vsys.Println("capsprobe: listen refused " + vi.ErrnoName(rc))
    } else {
        vsys.Println("capsprobe: listen ok")
    }
    vsys.Println("capsprobe: done")
    vsys.Exit(0)
}
EOF

vgate_setup_python <<'PY'
import os, shutil, subprocess, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "caps-share")
os.makedirs(share, exist_ok=True)

probe_dir = os.path.join(run, "capsprobe-build")
os.makedirs(probe_dir, exist_ok=True)
env = dict(os.environ, TMPDIR=probe_dir,
           GO_BUILD_OUT=probe_dir, GO_BUILD_NAME="PROBE",
           GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh",
                os.path.join(run, "caps_probe.go")], env=env, check=True)
probe = os.path.join(probe_dir, "PROBE.ELF")
for name in ("CAPSP.ELF", "NOCAPS.ELF"):
    shutil.copy(probe, os.path.join(share, name))

open(os.path.join(share, "PROBE.TXT"), "w").write("caps-probe-payload\n")
# The manifest: ONE row, declaring file only — net and window are the
# granted words the ceiling strips.
open(os.path.join(share, "APPS.TXT"), "w").write(
    "# manifest under test\n"
    "CAPSP.ELF | Caps Probe | p | dock=false | v=2 | caps=file\n")
# Enforce posture + wildcard rows granting the same set to both names.
open(os.path.join(share, "GRANTS.TXT"), "w").write(
    "#v1 mode=enforce\n"
    "CAPSP.ELF\t*\tfile,window,memory,process,debug,net\n"
    "NOCAPS.ELF\t*\tfile,window,memory,process,debug,net\n")
print("caps-share staged: two probe names, enforce GRANTS, one caps row")
PY

vgate_file script-03a.txt <<'PYEOF'
exec CAPSP.ELF
PYEOF

vgate_file script-03b.txt <<'PYEOF'
exec NOCAPS.ELF
PYEOF

vgate_file script-03c.txt <<'PYEOF'
echo caps-run-done
PYEOF

vgate_run 03 -- --cvc-file '$RUN_DIR/caps-share' \
    --script '$RUN_DIR/script-03a.txt' \
    --script2 '$RUN_DIR/script-03b.txt' --script2-after 'capsprobe: done' \
    --script3 '$RUN_DIR/script-03c.txt' --script3-after 'NOCAPS.ELF exited status=0' \
    --script-expect 'caps-run-done' --timeout 120

# The declared verb lands; the manifest-stripped one is refused by name —
# the receipt names the LAYER (caps_denied) and the word it stripped.
vgate_assert 03 serial-contains 'verdict=measured name=CAPSP.ELF'
vgate_assert 03 serial-count 'capsprobe: file read' 2
vgate_assert 03 serial-contains 'capsprobe: listen refused EACCES'
vgate_assert 03 serial-contains 'verdict=refused:caps_denied name=CAPSP.ELF word=net'
vgate_assert 03 serial-contains 'CAPSP.ELF exited status=0'
# The caps-less spawn is unchanged: the same bytes under a plain grant row
# run the boundary verb and earn no denial of either kind.
vgate_assert 03 serial-contains 'capsprobe: listen ok'
vgate_assert 03 serial-contains 'NOCAPS.ELF exited status=0'
vgate_assert 03 serial-absent 'denied name=NOCAPS.ELF'
vgate_assert 03 serial-contains 'caps-run-done'
vgate_assert 03 serial-absent '\[EXC\]'
