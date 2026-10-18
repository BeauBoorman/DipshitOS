# live-install-consent.spec -- M116c (#2469, ADR 0054 D10 + D12): the
# install-time consent gesture, live on VZ on one share provisioned with
# `GRANTS.TXT` `#v1 mode=enforce`:
#
#   * GRANTME.ELF — a signed release stream (`grantme`) declaring
#     ReleaseCaps file,memory,process,debug,net. GOSTORE -u0 (the
#     CAP_PROC_ADMIN half of the seat-or-cap admin gate, the go-flint
#     run-22 drive shape) installs it: the ask prints
#     (`store: grant propose`), the install-time prompt stands
#     (`gostore: consent name=GRANTME.ELF words=...`), the typed `g`
#     writes the hash-bound row through slot 89, and the exec'd probe
#     gets its words — file read lands, the dial reaches the wire.
#   * DENYME.ELF — same probe bytes, same ask, the prompt answered `d`:
#     NO row is written, and the exec falls to the M116b ambient floor —
#     `refused:file_denied`/`refused:net_denied` name the app and the
#     words, the syscall answers honest EACCES, and the app still prints
#     and exits (confined, not stuck).
#   * Runs 03-04 — the scriptable consent path plus the by-name
#     negatives: `store install badcaps` refuses `caps_unknown` (a
#     signed manifest whose ReleaseCaps names a word outside the
#     vocabulary), `store install badkey` refuses through the keyring
#     gate (`flint: refuse key_unknown`), an unprivileged `store
#     consent` answers `store: refuse eacces` (the seat-or-cap gate
#     stands), `store decline` writes nothing, and `-u0 store consent`
#     lands the row — the exec then runs granted.
#
# The rows key the RECORDED image name; the two fixture streams ship the
# same probe bytes so the consent/denial gesture is the experiment's
# controlled variable.
#
# HOST PREREQ:
#   bash tools/go/build-gotabwm.sh -> GOTABWM.ELF
#   bash tools/go/build-gostore.sh -> GOSTORE.ELF
#   bash tools/go/build-store.sh   -> STORE.ELF
#   bash tools/go/build-flint.sh   -> FLINT.ELF
#   bash tools/go/build-gosh.sh    -> GOSH.ELF
#   ../flint-server checkout (or FLINT_SERVER_DIR=...): the hook zig-builds
#   flintd and serves it on 127.0.0.1:4871 (this spec's own lane — sibling
#   gates must not share a port). flint-server is drawmeanelephant's repo
#   under the VirelaiOS proprietary source-available license (not
#   GPL-family). The probe ELF is built from the in-spec source via
#   tools/go/build-go.sh.
#
# exec-order: assert-proven -- runs 01/02/04 end on `probe: done` (the
# post-gesture execs) and run 03 ends on `store: refuse eacces` (the
# seat-or-cap gate answering the unprivileged consent).

vgate_name live-install-consent "#2469 M116c: install-time consent — prompt stands, consent writes the row, the app runs with the granted words only"
vgate_share none
vgate_runner_flags -Xswiftc -DSPIKE

# --- the probe: one binary exercising the two boundary words the consent
# row grants (file -> share read, net -> slot-80 dial). Runs granted AND
# refused from the same bytes: the row is the only variable. -----------
vgate_file consent_probe.go <<'EOF'
package main

import (
    "time"
    "virelai/vi"
    "virelai/vsys"
)

func errnoName(rc int64) string {
    switch -rc {
    case vi.ErrEACCES:
        return "EACCES"
    case vi.ErrENOENT:
        return "ENOENT"
    }
    return "errno" + vsys.Itoa64(-rc)
}

func main() {
    if _, rc := vi.ReadFileAll("PROBE.TXT", 64); rc < 0 {
        vsys.Println("probe: file refused " + errnoName(rc))
    } else {
        vsys.Println("probe: file read")
    }
    c, err := vi.DialTimeout("10.0.0.2", 4871, 5*time.Second)
    if err != nil {
        vsys.Println("probe: dial refused " + err.Error())
    } else {
        vsys.Println("probe: connected")
        _ = c.Close()
    }
    vsys.Println("probe: done")
    vsys.Exit(0)
}
EOF

# --- scripts -------------------------------------------------------------
vgate_file script-01a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-01x.txt <<'EOF'
exec -u0 GOSTORE.ELF --remote=10.0.0.2:4871 --channel=/host/DROP
EOF

vgate_file script-01b.txt <<'EOF'
exec GRANTME.ELF
EOF

vgate_file script-02a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-02x.txt <<'EOF'
exec -u0 GOSTORE.ELF --remote=10.0.0.2:4871 --channel=/host/DROP
EOF

vgate_file script-02b.txt <<'EOF'
exec DENYME.ELF
EOF

# Monitor `exec` is fire-and-forget — sequential legs chain through the
# script slots' -after markers, never through lines inside one file.
vgate_file script-03a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec STORE.ELF install badcaps --remote=10.0.0.2:4871 --channel=/host/DROP
EOF

vgate_file script-03b.txt <<'EOF'
exec STORE.ELF install badkey --remote=10.0.0.2:4871 --channel=/host/DROP
EOF

vgate_file script-03c.txt <<'EOF'
exec STORE.ELF consent DENYME
EOF

vgate_file script-04a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec STORE.ELF decline DENYME
EOF

vgate_file script-04b.txt <<'EOF'
exec -u0 STORE.ELF consent DENYME
EOF

vgate_file script-04c.txt <<'EOF'
exec DENYME.ELF
EOF

# --- setup -----------------------------------------------------------------
vgate_setup_python <<'PY'
import hashlib, json, os, shutil, socket, subprocess, sys, time

run = os.environ["RUN_DIR"]
share = os.path.join(run, "consent-share")

# ---- guest binaries -------------------------------------------------------
for name, cmd in (
    ("GOTABWM.ELF", "bash tools/go/build-gotabwm.sh"),
    ("GOSTORE.ELF", "bash tools/go/build-gostore.sh"),
    ("STORE.ELF", "bash tools/go/build-store.sh"),
    ("FLINT.ELF", "bash tools/go/build-flint.sh"),
    ("GOSH.ELF", "bash tools/go/build-gosh.sh"),
):
    if not os.path.isfile(os.path.join(".build", "go", name)):
        subprocess.run(["sh", "-c", cmd], check=True)

# The probe: file-word read + net-word dial, built once, shipped as both
# fixture ELFs (the row names the recorded image — same bytes, different
# names is the controlled variable).
probe_dir = os.path.join(run, "probe-build")
os.makedirs(probe_dir, exist_ok=True)
env = dict(os.environ, TMPDIR=probe_dir,
           GO_BUILD_OUT=probe_dir, GO_BUILD_NAME="PROBE",
           GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh",
                os.path.join(run, "consent_probe.go")], env=env, check=True)
probe = os.path.join(probe_dir, "PROBE.ELF")
probe_bytes = open(probe, "rb").read()

# ---- host flintd (the go-gostore pattern, its own port lane) ---------------
repo = os.getcwd()
flint_server_dir = os.environ.get("FLINT_SERVER_DIR") or os.path.join(repo, "..", "flint-server")
flint_server_dir = os.path.abspath(flint_server_dir)
if not os.path.isfile(os.path.join(flint_server_dir, "build.zig")):
    sys.exit(
        "flint-server checkout missing at %s - clone it once (outside the repo): "
        "git clone https://github.com/drawmeanelephant/flint-server %s"
        % (flint_server_dir, flint_server_dir)
    )
flintd_rev = subprocess.run(
    ["git", "-C", flint_server_dir, "rev-parse", "HEAD"],
    capture_output=True, text=True).stdout.strip()
subprocess.check_call(["zig", "build"], cwd=flint_server_dir)
flintd = os.path.join(flint_server_dir, "zig-out", "bin", "flintd")
if not os.path.isfile(flintd):
    sys.exit("flintd missing after zig build (expected " + flintd + ")")

AUTH_KEY_HEX = "ab" * 32
auth_key_file = os.path.join(run, "flint-auth.key")
open(auth_key_file, "w", encoding="utf-8").write(AUTH_KEY_HEX + "\n")

# ---- signed release fixtures (store's env-gated generator) ------------------
def gen_release_fixture(env):
    g = subprocess.run(
        ["go", "test", "./store", "-run", "TestGenReleaseFixture", "-count=1"],
        cwd="user/go",
        env={**os.environ, "STORE_GEN_FIXTURE": "1", **env},
        capture_output=True, text=True)
    if g.returncode != 0:
        sys.exit("fixture generation failed (tag=%s):\n%s%s"
                 % (env.get("STORE_FIXTURE_TAG", "?"),
                    g.stdout[-2000:], g.stderr[-2000:]))

fixture_dir = os.path.join(run, "fixtures")
os.makedirs(fixture_dir, exist_ok=True)

CONSENT_CAPS = "file,memory,process,debug,net"

# grantme / denyme: signed releases over the SAME probe bytes, each
# declaring the full ask the probe needs — file+net for the boundary
# words, memory/process/debug for the Go runtime's existence verbs (a
# row is the app's WHOLE word set under enforce — the ambient floor the
# denied leg falls to keeps those three anyway).
gen_release_fixture({
    "STORE_FIXTURE_ELF": probe,
    "STORE_FIXTURE_NAME": "GRANTME",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000d010",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000d001",
    "STORE_FIXTURE_CAPS": CONSENT_CAPS,
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "grantme",
})
gen_release_fixture({
    "STORE_FIXTURE_ELF": probe,
    "STORE_FIXTURE_NAME": "DENYME",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000d011",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000d002",
    "STORE_FIXTURE_CAPS": CONSENT_CAPS,
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "denyme",
})
# badcaps: a properly-signed manifest whose ReleaseCaps names a word
# outside the closed vocabulary — refused `caps_unknown` by name at
# parse, the manifest-side of "caps-mismatched installs refuse".
gen_release_fixture({
    "STORE_FIXTURE_ELF": probe,
    "STORE_FIXTURE_NAME": "BADAPP",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000d012",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000d003",
    "STORE_FIXTURE_CAPS": "file,narnia",
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "badcaps",
})
# badkey: an empty-ops Change signed by a key the keyring does not pin —
# remote-only, so the clone runs the real key check inside FLINT.ELF.
gen_release_fixture({
    "STORE_FIXTURE_EMPTY": "1",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000d013",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000d004",
    "STORE_FIXTURE_MSG": "untrusted publisher",
    "STORE_FIXTURE_SEED_HEX": "b1" * 32,
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "badkey",
})

def load_gen(tag):
    line = open(os.path.join(fixture_dir, "release-%s-stream.jsonl" % tag),
                "r", encoding="utf-8").read().strip()
    return json.loads(line), line

fixture = {}
for tag in ("grantme", "denyme", "badcaps", "badkey"):
    ch, line = load_gen(tag)
    rel_go = ""
    if tag != "badkey":
        rel_go = open(os.path.join(fixture_dir, "release-%s.go" % tag),
                      "r", encoding="utf-8").read()
    fixture[tag] = (ch, line, rel_go)

flintd_store = os.path.join(run, "flintd-store")
os.makedirs(os.path.join(flintd_store, "streams"), exist_ok=True)
for tag in ("grantme", "denyme", "badcaps", "badkey"):
    ch, line, _ = fixture[tag]
    with open(os.path.join(flintd_store, "streams", ch["stream"] + ".jsonl"), "w") as f:
        f.write(line + "\n")
    with open(os.path.join(flintd_store, "streams", ch["stream"] + ".json"), "w") as f:
        f.write(json.dumps(
            {"id": ch["stream"], "name": tag, "head": ch["id"],
             "created": ch["ts"], "forked_from": None},
            separators=(",", ":")) + "\n")

subprocess.run(
    ["sh", "-c", "lsof -ti tcp:4871 | xargs kill -9"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
time.sleep(0.2)
flintd_log = open(os.path.join(run, "flintd.log"), "wb")
flintd_proc = subprocess.Popen(
    [flintd, "serve", "--store=" + flintd_store,
     "--listen=127.0.0.1:4871", "--auth-key=" + auth_key_file],
    stdout=flintd_log, stderr=subprocess.STDOUT, start_new_session=True,
)
flintd_up = False
for _ in range(100):
    try:
        s = socket.create_connection(("127.0.0.1", 4871), 0.2)
        s.close()
        flintd_up = True
        break
    except OSError:
        if flintd_proc.poll() is not None:
            break
        time.sleep(0.1)
if not flintd_up:
    sys.exit("flintd did not come up on 127.0.0.1:4871 (see flintd.log)")
print("flintd: serving %s on 127.0.0.1:4871 pid=%d rev=%s"
      % (flintd_store, flintd_proc.pid, flintd_rev))

# ---- the consent-share: the seat's desktop plus the consumer side ---------
os.makedirs(os.path.join(share, "FLINT", "streams"), exist_ok=True)
os.makedirs(os.path.join(share, "FLINTJ"), exist_ok=True)

for name in ("GOTABWM.ELF", "GOSTORE.ELF", "STORE.ELF", "FLINT.ELF", "GOSH.ELF"):
    shutil.copy(os.path.join(".build", "go", name), os.path.join(share, name))
shutil.copy(os.path.join("image", "apps.txt"), os.path.join(share, "APPS.TXT"))
if os.path.isfile(os.path.join("image", "WALLPAPER.QOI")):
    shutil.copy(os.path.join("image", "WALLPAPER.QOI"),
                os.path.join(share, "WALLPAPER.QOI"))
if os.path.isfile(os.path.join("user", "src", "lib", "fixtures", "qoi",
                               "mascot_64x64.qoi")):
    shutil.copy(os.path.join("user", "src", "lib", "fixtures", "qoi",
                             "mascot_64x64.qoi"),
                os.path.join(share, "SEXIBURGER.QOI"))
for src, dst in (("Inter-Regular.ttf", "INTER.TTF"),
                 ("Inter-Bold.ttf", "INTERB.TTF"),
                 ("Inter-Italic.ttf", "INTERI.TTF"),
                 ("Inter-BoldItalic.ttf", "INTERBI.TTF"),
                 ("FiraCode-Regular.ttf", "FIRACODE.TTF")):
    p = os.path.join("image", "fonts", src)
    if os.path.isfile(p):
        shutil.copy(p, os.path.join(share, dst))

# A present-but-empty SESSION.TABS v2 reads as restored, so no boot
# takes the first-boot starter GOSH — the runtime envelope stays the
# proven three (seat + GOSTORE + the FLINT child).
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x02\x00\x00\x00\x00\x00")

# The file-word target the probe opens.
open(os.path.join(share, "PROBE.TXT"), "w", encoding="utf-8").write(
    "consent-probe-payload\n")

# The M116b posture: `#v1 mode=enforce` — the ambient floor drops
# file/audio/net for any binary no row names. Consent's landed rows
# appear here through the slot-89 persist.
open(os.path.join(share, "GRANTS.TXT"), "w", encoding="utf-8").write(
    "#v1 mode=enforce\n")

# OWNERS.TXT marks the secret-bound apps uid_system-owned images (the
# slot-70 binding needs the name match AND the ownership bit).
open(os.path.join(share, "OWNERS.TXT"), "w", encoding="utf-8").write(
    "#v1\nFLINT.ELF\t644\t0\t-\nSTORE.ELF\t644\t0\t-\nGOSTORE.ELF\t644\t0\t-\n"
)
# flint-remote lanes: uid_user (1000) covers the plain execs; uid_system
# (0) covers the -u0 GOSTORE and its FLINT children — the wire secret is
# served to the admin principal's lane only (the go-flint keep pattern).
open(os.path.join(share, "SECRETS.TXT"), "w", encoding="utf-8").write(
    "#v1\nflint-remote\t1000\t" + AUTH_KEY_HEX + "\tFLINT.ELF,STORE.ELF,GOSTORE.ELF\n"
    "flint-remote\t0\t" + AUTH_KEY_HEX + "\tFLINT.ELF,STORE.ELF,GOSTORE.ELF\n"
)

# The publisher keyring: the fixture author pinned. Every stream above
# except badkey signs with the default seed — one author serves them all.
open(os.path.join(share, "FLINT", "TRUSTED.TXT"),
     "w", encoding="utf-8").write(
    "#v1\nkey=" + fixture["grantme"][0]["author"] + " name=consent-seed\n"
)

# Local replicas, byte-identical to what clone would write (the wire
# read cannot carry a release-sized Change — the staged-bytes seam).
# badkey stays remote-only so clone runs the real key check.
for tag in ("grantme", "denyme", "badcaps"):
    ch, line, _ = fixture[tag]
    sid = ch["stream"]
    with open(os.path.join(share, "FLINT", "streams", sid + ".jsonl"), "w") as f:
        f.write(line if line.endswith("\n") else line + "\n")
    with open(os.path.join(share, "FLINT", "streams", sid + ".json"), "w") as f:
        f.write(json.dumps(
            {"id": sid, "name": tag, "head": ch["id"],
             "created": ch["ts"], "forked_from": None},
            separators=(",", ":")) + "\n")

def write_drop(drop, tag, bin_name):
    ch, _, rel_go = fixture[tag]
    d = os.path.join(share, drop, tag)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "release.go"), "w", encoding="utf-8").write(rel_go)
    open(os.path.join(d, bin_name), "wb").write(probe_bytes)

write_drop("DROP", "grantme", "GRANTME.ELF")
write_drop("DROP", "denyme", "DENYME.ELF")
write_drop("DROP", "badcaps", "BADAPP.ELF")

open(os.path.join(run, "ids.json"), "w").write(json.dumps({
    "probe_sha": hashlib.sha256(probe_bytes).hexdigest(),
}))
print("staged consent-share: seat assets + GOSTORE/STORE/FLINT/GOSH ELFs, "
      "enforce GRANTS.TXT, TRUSTED/SECRETS keyring, three replicas, "
      "one drop, probe sha pinned")
PY

# ---- 01: install -> prompt -> consent writes the row -> exec granted ------
vgate_run 01 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-01' \
    --cvc-file '$RUN_DIR/consent-share' \
    --virtio-fs '$RUN_DIR/consent-share' \
    --net '$RUN_DIR/cap01.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4871:relay --net-tcp-respond-relay 127.0.0.1:4871 \
    --script '$RUN_DIR/script-01a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-01x.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/grantme\ni' \
    --input-string-after 'gostore: ready' \
    --input-chords 'g' \
    --input-chords-after 'gostore: consent name=GRANTME.ELF' \
    --script3 '$RUN_DIR/script-01b.txt' \
    --script3-after 'gostore: grant written name=GRANTME.ELF' \
    --script-expect 'probe: done' --timeout 900

# The install's signed ask printed as the propose line, then the prompt
# stood on the seat app and the typed gesture landed the hash-bound row.
vgate_assert 01 serial-contains 'store: install ok GRANTME.ELF version=1.0.0'
vgate_assert 01 serial-contains 'store: grant propose GRANTME.ELF words=file,memory,process,debug,net'
vgate_assert 01 serial-contains 'gostore: consent name=GRANTME.ELF words=file,memory,process,debug,net'
vgate_assert 01 serial-contains 'gostore: grant written name=GRANTME.ELF words=file,memory,process,debug,net'
# The granted exec: measured, both boundary words land — "allowed"
# reached the wire (the relay answered the SYN), and no denied receipt
# names the app anywhere in the boot.
vgate_assert 01 serial-contains 'verdict=measured name=GRANTME.ELF'
vgate_assert 01 serial-contains 'probe: file read'
vgate_assert 01 serial-contains 'probe: connected'
vgate_assert 01 serial-contains 'probe: done'
vgate_assert 01 serial-contains 'GRANTME.ELF exited status=0'
vgate_assert 01 serial-absent 'denied name=GRANTME.ELF'
vgate_assert 01 serial-absent 'verdict=refused'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import hashlib, os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "consent-share")

sha = hashlib.sha256(open(os.path.join(share, "GRANTME.ELF"), "rb").read()).hexdigest()
grants = open(os.path.join(share, "GRANTS.TXT"), "r", encoding="utf-8").read()
lines = [l for l in grants.splitlines() if l and not l.startswith("#")]
if lines != ["GRANTME.ELF\t" + sha + "\tfile,memory,process,debug,net"]:
    sys.exit("GRANTS.TXT after consent: %r (sha %s)" % (lines, sha))
state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if "name=GRANTME.ELF" not in state or "caps=file,memory,process,debug,net" not in state:
    sys.exit("STORE.TXT did not record the declared ask: %r" % state)
print("run-01 verified: prompt -> consent wrote the hash-bound row")
PY

# ---- 02: install -> prompt -> denial leaves the ambient floor --------------
vgate_run 02 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-02' \
    --cvc-file '$RUN_DIR/consent-share' \
    --virtio-fs '$RUN_DIR/consent-share' \
    --net '$RUN_DIR/cap02.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4871:relay --net-tcp-respond-relay 127.0.0.1:4871 \
    --script '$RUN_DIR/script-02a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-02x.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/denyme\ni' \
    --input-string-after 'gostore: ready' \
    --input-chords 'd' \
    --input-chords-after 'gostore: consent name=DENYME.ELF' \
    --script3 '$RUN_DIR/script-02b.txt' \
    --script3-after 'gostore: grant declined name=DENYME.ELF' \
    --script-expect 'probe: done' --timeout 900

vgate_assert 02 serial-contains 'store: install ok DENYME.ELF version=1.0.0'
vgate_assert 02 serial-contains 'store: grant propose DENYME.ELF words=file,memory,process,debug,net'
vgate_assert 02 serial-contains 'gostore: consent name=DENYME.ELF words=file,memory,process,debug,net'
vgate_assert 02 serial-contains 'gostore: grant declined name=DENYME.ELF'
vgate_assert 02 serial-absent 'gostore: grant written name=DENYME.ELF'
# The denied exec falls to the ambient floor: file and net are refused
# BY NAME (the app and the word), the syscall answers honest EACCES the
# app prints itself, and the app still reaches exit — debug/memory/
# process are existence verbs the floor keeps.
vgate_assert 02 serial-contains 'verdict=measured name=DENYME.ELF'
vgate_assert 02 serial-contains 'refused:file_denied name=DENYME.ELF word=file'
vgate_assert 02 serial-contains 'refused:net_denied name=DENYME.ELF word=net'
vgate_assert 02 serial-contains 'probe: file refused EACCES'
vgate_assert 02 serial-contains 'probe: dial refused EACCES'
vgate_assert 02 serial-contains 'probe: done'
vgate_assert 02 serial-contains 'DENYME.ELF exited status=0'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "consent-share")

grants = open(os.path.join(share, "GRANTS.TXT"), "r", encoding="utf-8").read()
rows = [l for l in grants.splitlines() if l and not l.startswith("#")]
denyme = [l for l in rows if l.startswith("DENYME.ELF\t")]
if denyme:
    sys.exit("denial still wrote a row: %r" % denyme)
state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if "name=DENYME.ELF" not in state or "caps=file,memory,process,debug,net" not in state:
    sys.exit("STORE.TXT lost the denied install's ask: %r" % state)
print("run-02 verified: declined consent wrote no row — the ask stays recorded")
PY

# ---- 03: the by-name negatives + the seat-or-cap gate on the verb ---------
# Monitor-driven, each leg gated by the previous refusal's marker: the
# caps-malformed manifest refuses caps_unknown by name, the unsigned
# stream refuses through the keyring gate inside the FLINT child, and an
# unprivileged `store consent` answers the seat-or-cap gate's EACCES —
# nothing the publisher signs becomes power off a script.
vgate_run 03 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-03' \
    --cvc-file '$RUN_DIR/consent-share' \
    --virtio-fs '$RUN_DIR/consent-share' \
    --net '$RUN_DIR/cap03.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4871:relay --net-tcp-respond-relay 127.0.0.1:4871 \
    --script '$RUN_DIR/script-03a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-03b.txt' \
    --script2-after 'store: refuse caps_unknown' \
    --script3 '$RUN_DIR/script-03c.txt' \
    --script3-after 'store: refuse sync_failed' \
    --script-expect 'store: refuse eacces' --timeout 600

vgate_assert 03 serial-contains 'store: install badcaps'
vgate_assert 03 serial-contains 'store: refuse caps_unknown narnia'
vgate_assert 03 serial-contains 'store: install badkey'
vgate_assert 03 serial-contains 'flint: refuse key_unknown'
vgate_assert 03 serial-contains 'store: refuse sync_failed'
vgate_assert 03 serial-contains 'store: consent DENYME.ELF'
vgate_assert 03 serial-contains 'store: refuse eacces'
vgate_assert 03 serial-absent 'store: grant written name=DENYME.ELF'
vgate_assert 03 serial-absent '[EXC] parking:'

# ---- 04: the scriptable consent chain --------------------------------------
# decline writes nothing (the ambient floor stands), then the -u0
# consent lands the row the denied install left pending — the exec runs
# granted: the whole declare -> answer -> confined-run chain without a
# GUI in the loop.
vgate_run 04 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-04' \
    --cvc-file '$RUN_DIR/consent-share' \
    --virtio-fs '$RUN_DIR/consent-share' \
    --net '$RUN_DIR/cap04.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4871:relay --net-tcp-respond-relay 127.0.0.1:4871 \
    --script '$RUN_DIR/script-04a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-04b.txt' \
    --script2-after 'store: consent declined name=DENYME.ELF' \
    --script3 '$RUN_DIR/script-04c.txt' \
    --script3-after 'store: grant written name=DENYME.ELF' \
    --script-expect 'probe: done' --timeout 600

vgate_assert 04 serial-contains 'store: decline DENYME.ELF'
vgate_assert 04 serial-contains 'store: consent declined name=DENYME.ELF'
vgate_assert 04 serial-contains 'store: consent DENYME.ELF'
vgate_assert 04 serial-contains 'store: grant written name=DENYME.ELF words=file,memory,process,debug,net'
vgate_assert 04 serial-contains 'verdict=measured name=DENYME.ELF'
vgate_assert 04 serial-contains 'probe: file read'
vgate_assert 04 serial-contains 'probe: connected'
vgate_assert 04 serial-contains 'probe: done'
vgate_assert 04 serial-contains 'DENYME.ELF exited status=0'
vgate_assert 04 serial-absent 'denied name=DENYME.ELF'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 python <<'PY'
import hashlib, os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "consent-share")

sha = hashlib.sha256(open(os.path.join(share, "DENYME.ELF"), "rb").read()).hexdigest()
grants = open(os.path.join(share, "GRANTS.TXT"), "r", encoding="utf-8").read()
rows = [l for l in grants.splitlines() if l and not l.startswith("#")]
want = "DENYME.ELF\t" + sha + "\tfile,memory,process,debug,net"
if want not in rows:
    sys.exit("scripted consent did not land the row: %r" % rows)
print("run-04 verified: decline wrote nothing; -u0 consent landed the row")
PY
