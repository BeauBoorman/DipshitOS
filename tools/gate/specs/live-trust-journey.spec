# live-trust-journey.spec -- M116f (issue #2472, ADR 0054): the M116
# acceptance — ONE confined third-party app, the whole journey end to
# end on VZ, on a share provisioned with `GRANTS.TXT` `#v1
# mode=enforce`. The building blocks are the fleet's own: install +
# consent (live-install-consent), the word gate (live-grant-enforce),
# the row-write escapes (live-sandbox-negatives). This spec composes
# them into the single signed-app journey:
#
#   * run 01 — install -> consent -> confined run -> refused escalation:
#     TPAPP.ELF is a signed third-party release (stream `tpapp`,
#     publisher pinned in TRUSTED.TXT) declaring ReleaseCaps
#     file,memory,process,debug,net. `exec -u0 GOSTORE.ELF` runs the real
#     install pipeline (flint clone, keyring verify, stage), the seat's
#     prompt stands (`gostore: consent name=TPAPP.ELF`), the typed `g`
#     writes the hash-bound row through slot 89, and the exec'd app runs
#     INSIDE its words: the `file` read and the `net` dial land, while
#     the undeclared `audio` query is refused by name
#     (`refused:audio_denied` + the app's own EACCES print) and every
#     grant-table escape — the slot-89 read, a cross-app row write, the
#     file-ABI GRANTS.TXT write — answers EACCES. A final Return keystroke
#     gated on `journey: done` toggles GOSTORE's detail row: the seat that
#     took the consent gesture still routes input after the confined app
#     ran and exited (seat stays green).
#   * run 02 — a second boot of the same share: no install, no prompt.
#     `exec TPAPP.ELF` binds the row consent persisted in run 01 (the
#     hash matches the staged image) and the same confined legs replay —
#     consent is durable state, not a per-boot gesture.
#
# K=3 is three gate invocations (the live-sandbox-negatives rule): run
# 01's consent persists GRANTS.TXT, so in-spec vgate_repeat would re-boot
# a share whose journey already ran.
#
# HOST PREREQ:
#   bash tools/go/build-gotabwm.sh -> GOTABWM.ELF
#   bash tools/go/build-gostore.sh -> GOSTORE.ELF
#   bash tools/go/build-store.sh   -> STORE.ELF
#   bash tools/go/build-flint.sh   -> FLINT.ELF
#   bash tools/go/build-gosh.sh    -> GOSH.ELF
#   ../flint-server checkout (or FLINT_SERVER_DIR=...): the hook zig-builds
#   flintd and serves it on 127.0.0.1:4879 (this spec's own lane — sibling
#   gates must not share a port). flint-server is drawmeanelephant's repo
#   under the VirelaiOS proprietary source-available license (not
#   GPL-family). The probe ELF is built from the in-spec source via
#   tools/go/build-go.sh.
#
# exec-order: assert-proven -- run 01 ends on `gostore: detail`, guest
# output the --input-key Return produces only after `journey: done` (the
# program's own terminal marker gates the keystroke); run 02 ends on
# `journey: done` itself. A probe that never ran fails both runs.

vgate_name live-trust-journey "#2472 M116f: the confined third-party app journey — install, consent, granted words only, refused words named EACCES, seat stays green"
vgate_share none
vgate_runner_flags -Xswiftc -DSPIKE

# --- the third-party app: one binary driving the whole confined boundary.
# Granted words land (file read, the dial reaches the wire); the
# undeclared `audio` word and every grant-table escape answer EACCES —
# refused, never stuck, exit 0.
vgate_file journey_probe.go <<'EOF'
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
    me := "?"
    if args := vi.Args(); len(args) > 0 {
        me = args[0]
    }
    // Granted: the `file` word opens the share fixture.
    if _, rc := vi.ReadFileAll("PROBE.TXT", 64); rc < 0 {
        vsys.Println("journey: file refused name=" + me + " rc=" + errnoName(rc))
    } else {
        vsys.Println("journey: file ok name=" + me)
    }
    // Granted: the `net` word dials the flintd relay — "ok" means the
    // handshake reached the wire, not just failed to receipt.
    c, err := vi.DialTimeout("10.0.0.2", 4879, 5*time.Second)
    if err != nil {
        vsys.Println("journey: net refused name=" + me + " rc=" + err.Error())
    } else {
        vsys.Println("journey: net ok name=" + me)
        _ = c.Close()
    }
    // Refused by name: `audio` is no part of the signed ask, so the
    // consented row cannot carry it.
    if _, aerr := vi.AudioQuery(); aerr != nil {
        vsys.Println("journey: audio refused name=" + me + " rc=" + aerr.Error())
    } else {
        vsys.Println("journey: audio ok name=" + me)
    }
    // The escalation batch — the confined app reaches for the grant
    // table itself: the slot-89 read, a row naming ANOTHER app, and the
    // file-ABI GRANTS.TXT write. Every seam answers EACCES.
    var buf [vi.GrantLineMax]byte
    _, grc := vi.GrantReadRow(0, buf[:])
    vsys.Println("journey: grant-read name=" + me + " rc=" + errnoName(grc))
    wrc := vi.GrantWriteLine(vi.GrantLine(vi.GrantRow{
        Name:  "VICTIM.ELF",
        SHA:   "*",
        Words: "file,net",
    }))
    vsys.Println("journey: grant-write name=" + me + " rc=" + errnoName(wrc))
    fh, frc := vi.FileOpen("GRANTS.TXT", vi.ModeWrite)
    if frc < 0 {
        vsys.Println("journey: grants-file name=" + me + " rc=" + errnoName(frc))
    } else {
        vi.FileClose(uint32(fh))
        vsys.Println("journey: grants-file name=" + me + " rc=OK")
    }
    vsys.Println("journey: done name=" + me)
    vsys.Exit(0)
}
EOF

# --- scripts -------------------------------------------------------------
# Monitor `exec` is fire-and-forget — sequential legs chain through the
# script slots' -after markers, never through lines inside one file.
vgate_file script-01a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-01x.txt <<'EOF'
exec -u0 GOSTORE.ELF --remote=10.0.0.2:4879 --channel=/host/DROP
EOF

vgate_file script-01b.txt <<'EOF'
exec TPAPP.ELF
EOF

vgate_file script-02.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec TPAPP.ELF
EOF

# --- setup -----------------------------------------------------------------
vgate_setup_python <<'PY'
import hashlib, json, os, shutil, socket, subprocess, sys, time

run = os.environ["RUN_DIR"]
share = os.path.join(run, "journey-share")

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

# The third-party payload: the in-spec journey probe.
probe_dir = os.path.join(run, "probe-build")
os.makedirs(probe_dir, exist_ok=True)
env = dict(os.environ, TMPDIR=probe_dir,
           GO_BUILD_OUT=probe_dir, GO_BUILD_NAME="JPROBE",
           GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh",
                os.path.join(run, "journey_probe.go")], env=env, check=True)
probe = os.path.join(probe_dir, "JPROBE.ELF")
probe_bytes = open(probe, "rb").read()

# ---- host flintd (the live-install-consent pattern, its own port lane) ----
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

# ---- the signed release fixture (store's env-gated generator) -------------
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

# tpapp: the signed ask the consent prompt answers — file+net are the
# boundary words, memory/process/debug the Go runtime's existence verbs.
JOURNEY_CAPS = "file,memory,process,debug,net"
gen_release_fixture({
    "STORE_FIXTURE_ELF": probe,
    "STORE_FIXTURE_NAME": "TPAPP",
    "STORE_FIXTURE_STREAM": "0199de2d-dd00-7000-8000-00000000e010",
    "STORE_FIXTURE_CHANGE": "0199de2d-dd00-7000-8000-00000000e001",
    "STORE_FIXTURE_CAPS": JOURNEY_CAPS,
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "tpapp",
})

line = open(os.path.join(fixture_dir, "release-tpapp-stream.jsonl"),
            "r", encoding="utf-8").read().strip()
ch = json.loads(line)
rel_go = open(os.path.join(fixture_dir, "release-tpapp.go"),
              "r", encoding="utf-8").read()

flintd_store = os.path.join(run, "flintd-store")
os.makedirs(os.path.join(flintd_store, "streams"), exist_ok=True)
with open(os.path.join(flintd_store, "streams", ch["stream"] + ".jsonl"), "w") as f:
    f.write(line + "\n")
with open(os.path.join(flintd_store, "streams", ch["stream"] + ".json"), "w") as f:
    f.write(json.dumps(
        {"id": ch["stream"], "name": "tpapp", "head": ch["id"],
         "created": ch["ts"], "forked_from": None},
        separators=(",", ":")) + "\n")

subprocess.run(
    ["sh", "-c", "lsof -ti tcp:4879 | xargs kill -9"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
time.sleep(0.2)
flintd_log = open(os.path.join(run, "flintd.log"), "wb")
flintd_proc = subprocess.Popen(
    [flintd, "serve", "--store=" + flintd_store,
     "--listen=127.0.0.1:4879", "--auth-key=" + auth_key_file],
    stdout=flintd_log, stderr=subprocess.STDOUT, start_new_session=True,
)
flintd_up = False
for _ in range(100):
    try:
        s = socket.create_connection(("127.0.0.1", 4879), 0.2)
        s.close()
        flintd_up = True
        break
    except OSError:
        if flintd_proc.poll() is not None:
            break
        time.sleep(0.1)
if not flintd_up:
    sys.exit("flintd did not come up on 127.0.0.1:4879 (see flintd.log)")
print("flintd: serving %s on 127.0.0.1:4879 pid=%d rev=%s"
      % (flintd_store, flintd_proc.pid, flintd_rev))

# ---- the journey share: the seat's desktop plus the store lane -----------
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

# The file-word target the app opens.
open(os.path.join(share, "PROBE.TXT"), "w", encoding="utf-8").write(
    "journey-probe-payload\n")

# The M116b posture: `#v1 mode=enforce` — file/audio/net are row-only
# words for any binary no row names. The consent gesture's landed row
# appears here through the slot-89 persist.
open(os.path.join(share, "GRANTS.TXT"), "w", encoding="utf-8").write(
    "#v1 mode=enforce\n")

# OWNERS.TXT marks the secret-bound apps uid_system-owned images (the
# slot-70 binding needs the name match AND the ownership bit).
open(os.path.join(share, "OWNERS.TXT"), "w", encoding="utf-8").write(
    "#v1\nFLINT.ELF\t644\t0\t-\nSTORE.ELF\t644\t0\t-\nGOSTORE.ELF\t644\t0\t-\n"
)
# flint-remote lanes: uid_user (1000) covers the plain execs; uid_system
# (0) covers the -u0 GOSTORE and its FLINT children — the wire secret is
# served to the admin principal's lane only.
open(os.path.join(share, "SECRETS.TXT"), "w", encoding="utf-8").write(
    "#v1\nflint-remote\t1000\t" + AUTH_KEY_HEX + "\tFLINT.ELF,STORE.ELF,GOSTORE.ELF\n"
    "flint-remote\t0\t" + AUTH_KEY_HEX + "\tFLINT.ELF,STORE.ELF,GOSTORE.ELF\n"
)

# The publisher keyring: the fixture author pinned — the third-party
# signature that makes this not-first-party.
open(os.path.join(share, "FLINT", "TRUSTED.TXT"),
     "w", encoding="utf-8").write(
    "#v1\nkey=" + ch["author"] + " name=journey-seed\n"
)

# The local replica, byte-identical to what clone would write (the wire
# read cannot carry a release-sized Change — the staged-bytes seam).
sid = ch["stream"]
with open(os.path.join(share, "FLINT", "streams", sid + ".jsonl"), "w") as f:
    f.write(line if line.endswith("\n") else line + "\n")
with open(os.path.join(share, "FLINT", "streams", sid + ".json"), "w") as f:
    f.write(json.dumps(
        {"id": sid, "name": "tpapp", "head": ch["id"],
         "created": ch["ts"], "forked_from": None},
        separators=(",", ":")) + "\n")

d = os.path.join(share, "DROP", "tpapp")
os.makedirs(d, exist_ok=True)
open(os.path.join(d, "release.go"), "w", encoding="utf-8").write(rel_go)
open(os.path.join(d, "TPAPP.ELF"), "wb").write(probe_bytes)

open(os.path.join(run, "ids.json"), "w").write(json.dumps({
    "probe_sha": hashlib.sha256(probe_bytes).hexdigest(),
}))
print("staged journey-share: seat assets + GOSTORE/STORE/FLINT/GOSH ELFs, "
      "enforce GRANTS.TXT, TRUSTED/SECRETS keyring, one replica, "
      "one drop, probe sha pinned")
PY

# ---- 01: install -> consent -> confined run -> refused escalation -------
# -> seat still routing input. Every stage is guest-output anchored; the
# final Return reaches the still-focused GOSTORE only after the app's own
# `journey: done`, so `gostore: detail` is both the run's end marker and
# the seat-green receipt.
vgate_run 01 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-01' \
    --cvc-file '$RUN_DIR/journey-share' \
    --virtio-fs '$RUN_DIR/journey-share' \
    --net '$RUN_DIR/cap01.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4879:relay --net-tcp-respond-relay 127.0.0.1:4879 \
    --script '$RUN_DIR/script-01a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-01x.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/tpapp\ni' \
    --input-string-after 'gostore: ready' \
    --input-chords 'g' \
    --input-chords-after 'gostore: consent name=TPAPP.ELF' \
    --script3 '$RUN_DIR/script-01b.txt' \
    --script3-after 'gostore: grant written name=TPAPP.ELF' \
    --input-key 36 \
    --input-key-after 'journey: done name=TPAPP.ELF' \
    --script-expect 'gostore: detail' --timeout 900

# The install: signed pipeline landed, the signed ask surfaced.
vgate_assert 01 serial-contains 'store: install ok TPAPP.ELF version=1.0.0'
vgate_assert 01 serial-contains 'store: grant propose TPAPP.ELF words=file,memory,process,debug,net'
# The consent prompt stood on the seat and the `g` gesture wrote the
# hash-bound row — the user's answer, not the publisher's.
vgate_assert 01 serial-contains 'gostore: consent name=TPAPP.ELF words=file,memory,process,debug,net'
vgate_assert 01 serial-contains 'gostore: grant written name=TPAPP.ELF words=file,memory,process,debug,net'
# The confined run: measured in under the consented row; the granted
# words land, the undeclared word and every table escape refuse EACCES.
vgate_assert 01 serial-contains 'verdict=measured name=TPAPP.ELF'
vgate_assert 01 serial-contains 'journey: file ok name=TPAPP.ELF'
vgate_assert 01 serial-contains 'journey: net ok name=TPAPP.ELF'
vgate_assert 01 serial-contains 'refused:audio_denied name=TPAPP.ELF word=audio'
vgate_assert 01 serial-contains 'journey: audio refused name=TPAPP.ELF rc=EACCES'
vgate_assert 01 serial-contains 'journey: grant-read name=TPAPP.ELF rc=EACCES'
vgate_assert 01 serial-contains 'journey: grant-write name=TPAPP.ELF rc=EACCES'
vgate_assert 01 serial-contains 'journey: grants-file name=TPAPP.ELF rc=EACCES'
vgate_assert 01 serial-contains 'journey: done name=TPAPP.ELF'
vgate_assert 01 serial-contains 'TPAPP.ELF exited status=0'
# Granted words never receipt a denial naming this app.
vgate_assert 01 serial-absent 'denied name=TPAPP.ELF word=file'
vgate_assert 01 serial-absent 'denied name=TPAPP.ELF word=net'
# The seat stays green: after the confined app's whole run, a keystroke
# still routes to the store app — and no refusal ever names the seat.
vgate_assert 01 serial-contains 'gostore: detail'
vgate_assert 01 serial-absent 'denied name=GOSTORE.ELF'
vgate_assert 01 serial-absent 'denied name=GOTABWM.ELF'
# No exec ever refused by name — the only `verdict=refused:` receipts are
# the app's own word denials, asserted above.
vgate_assert 01 serial-absent 'verdict=refused:grant_stale'
vgate_assert 01 serial-absent 'verdict=audit:'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import hashlib, os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "journey-share")

sha = hashlib.sha256(open(os.path.join(share, "TPAPP.ELF"), "rb").read()).hexdigest()
grants = open(os.path.join(share, "GRANTS.TXT"), "r", encoding="utf-8").read()
lines = [l for l in grants.splitlines() if l and not l.startswith("#")]
want = "TPAPP.ELF\t" + sha + "\tfile,memory,process,debug,net"
if lines != [want]:
    sys.exit("GRANTS.TXT after consent: %r (sha %s)" % (lines, sha))
state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if "name=TPAPP.ELF" not in state or "caps=file,memory,process,debug,net" not in state:
    sys.exit("STORE.TXT did not record the declared ask: %r" % state)
print("run-01 verified: consent wrote the hash-bound row; the ask is recorded")
PY

# ---- 02: a second boot — consent persisted, no prompt, same confines ------
vgate_run 02 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-02' \
    --cvc-file '$RUN_DIR/journey-share' \
    --virtio-fs '$RUN_DIR/journey-share' \
    --net '$RUN_DIR/cap02.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4879:relay --net-tcp-respond-relay 127.0.0.1:4879 \
    --script '$RUN_DIR/script-02.txt' \
    --script-expect 'journey: done name=TPAPP.ELF' --timeout 300

# The persisted row binds the measured image — no prompt, no re-consent,
# and the identical confined legs replay against the durable grant.
vgate_assert 02 serial-contains 'verdict=measured name=TPAPP.ELF'
vgate_assert 02 serial-contains 'journey: file ok name=TPAPP.ELF'
vgate_assert 02 serial-contains 'journey: net ok name=TPAPP.ELF'
vgate_assert 02 serial-contains 'refused:audio_denied name=TPAPP.ELF word=audio'
vgate_assert 02 serial-contains 'journey: audio refused name=TPAPP.ELF rc=EACCES'
vgate_assert 02 serial-contains 'journey: grant-read name=TPAPP.ELF rc=EACCES'
vgate_assert 02 serial-contains 'journey: grant-write name=TPAPP.ELF rc=EACCES'
vgate_assert 02 serial-contains 'journey: grants-file name=TPAPP.ELF rc=EACCES'
vgate_assert 02 serial-contains 'journey: done name=TPAPP.ELF'
vgate_assert 02 serial-contains 'TPAPP.ELF exited status=0'
vgate_assert 02 serial-absent 'gostore: consent'
vgate_assert 02 serial-absent 'verdict=refused:grant_stale'
vgate_assert 02 serial-absent 'verdict=audit:'
vgate_assert 02 serial-absent '[EXC] parking:'
# The grant table after both boots still carries exactly the consented
# row — the journey's refused writes never landed (no armed share under
# `vgate_share none`, so this reads $RUN_DIR/journey-share directly).
vgate_assert 02 python <<'PY'
import os, sys
share = os.path.join(os.environ["RUN_DIR"], "journey-share")
grants = open(os.path.join(share, "GRANTS.TXT"), "r", encoding="utf-8").read()
rows = [l for l in grants.splitlines() if l and not l.startswith("#")]
tpapp = [l for l in rows if l.startswith("TPAPP.ELF\t")]
if len(tpapp) != 1 or not tpapp[0].endswith("\tfile,memory,process,debug,net"):
    sys.exit("GRANTS.TXT after the journey: %r" % rows)
if "VICTIM.ELF" in grants:
    sys.exit("the refused cross-app write landed: %r" % rows)
print("run-02 verified: the consented row persisted; refused writes never landed")
PY
