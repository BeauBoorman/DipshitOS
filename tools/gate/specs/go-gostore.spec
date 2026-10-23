# go-gostore.spec -- M110c (#2405) class-B: GOSTORE, the GUI store. Browse,
# search, detail, install, update, remove and rollback as a tab on the
# DEFAULT Go seat, driving the same signed legs STORE.ELF runs (verify ->
# fetch -> sha -> publish -> .prev) through package virelai/store linked
# in-process. STORE stays the scriptable path and the only implementation
# of the legs — GOSTORE never execs STORE.ELF: seat + GOSTORE + STORE +
# FLINT would be four concurrent Go runtimes (16 > 13 user slots); linking
# keeps seat + GOSTORE + FLINT at the proven three-runtime envelope
# (M65d/#1442). The GUI is driven by --input-string keys; the mid-publish
# kill is the --kill-at=prev marker hook. The visual check is a class-C
# owner leg, not this gate.
#
# Runs (one share, state persists):
#   01  browse/search/detail + install, legs visible + GOHELLO exec
#   02  replica advance + update -> v2 exec
#   03  rollback -> v1 exec
#   04  update killed mid-publish (--kill-at=prev): .prev.new survives
#   05  rollback after the kill -> v1 exec (the .prev target survived)
#   06  elf_mismatch        07  release_mismatch    08  key_unknown+key_revoked
#   09  prev_mismatch       10  state_mismatch x2   11  remove
#   12  install v2 then pin to the prior signed head (v1) -> v1 exec
#   13  ReleaseDepends resolved install: NEEDY pulls BOUNCE first
#   14  ReleaseDepends dep_missing refusal
#
# HOST PREREQ:
#   bash tools/go/build-gotabwm.sh -> GOTABWM.ELF
#   bash tools/go/build-gostore.sh -> GOSTORE.ELF
#   bash tools/go/build-store.sh   -> STORE.ELF
#   bash tools/go/build-flint.sh   -> FLINT.ELF
#   bash tools/go/build-gosh.sh    -> GOSH.ELF
#   bash tools/go/build-go.sh      -> GOHELLO.ELF
#   ../flint-server checkout (or FLINT_SERVER_DIR=...): the hook zig-builds
#   flintd and serves it on 127.0.0.1:4857 (go-gostore's own lane, like
#   go-flint's 4749 — sibling gates must not share a port).
#
# exec-order: assert-proven -- every phase anchors on a guest marker, and
# each run ends on a script-owned echo or the killed process's reap line.

vgate_name go-gostore "M110c #2405: GOSTORE GUI — browse/search/detail/install/update/remove/rollback through STORE's signed legs on the default seat"
vgate_share none
vgate_runner_flags -Xswiftc -DSPIKE

# --- scripts -----------------------------------------------------------------
# Phase a always configures the hermetic net before anything dials, then
# execs GOSTORE (or the one GOSH -c step some legs need).
vgate_file script-01a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-01x.txt <<'EOF'
exec GOSTORE.ELF --remote=10.0.0.2:4857 --channel=/host/DROP
EOF

vgate_file script-01b.txt <<'EOF'
exec GOHELLO.ELF
EOF

vgate_file script-02a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-02b.txt <<'EOF'
exec GOSTORE.ELF --remote=10.0.0.2:4858 --channel=/host/DROPV2
EOF

vgate_file script-02c.txt <<'EOF'
exec GOHELLO.ELF
EOF

vgate_file script-03a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-03x.txt <<'EOF'
exec GOSTORE.ELF --remote=10.0.0.2:4857 --channel=/host/DROPV2
EOF

vgate_file script-03b.txt <<'EOF'
exec GOHELLO.ELF
EOF

vgate_file script-04a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-04x.txt <<'EOF'
exec GOSTORE.ELF --remote=10.0.0.2:4858 --channel=/host/DROPV2 --kill-at=prev
EOF

vgate_file script-04b.txt <<'EOF'
kill GOSTORE.ELF
EOF

vgate_file script-05a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-05x.txt <<'EOF'
exec GOSTORE.ELF --remote=10.0.0.2:4857 --channel=/host/DROPV2
EOF

vgate_file script-05b.txt <<'EOF'
exec GOHELLO.ELF
EOF

vgate_file script-06a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-06x.txt <<'EOF'
exec GOSTORE.ELF --remote=10.0.0.2:4858 --channel=/host/DROPV2BAD
EOF

vgate_file script-06b.txt <<'EOF'
echo rx-gostore-06-ok
EOF

vgate_file script-07a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-07x.txt <<'EOF'
exec GOSTORE.ELF --remote=10.0.0.2:4857 --channel=/host/DROPBADDESC
EOF

vgate_file script-07b.txt <<'EOF'
echo rx-gostore-07-ok
EOF

vgate_file script-08a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-08x.txt <<'EOF'
exec GOSTORE.ELF --remote=10.0.0.2:4857 --channel=/host/DROP
EOF

vgate_file script-08b.txt <<'EOF'
echo rx-gostore-08-ok
EOF

vgate_file script-08c.txt <<'EOF'
echo rx-gostore-08-done
EOF

vgate_file script-09a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-09b.txt <<'EOF'
exec GOSTORE.ELF --remote=10.0.0.2:4857 --channel=/host/DROPV2 --tear=/host/GOHELLO.ELF.prev
EOF

vgate_file script-09c.txt <<'EOF'
echo rx-gostore-09-ok
EOF

vgate_file script-10a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-10b.txt <<'EOF'
exec GOSTORE.ELF --remote=10.0.0.2:4858 --channel=/host/DROPV2 --tear=/host/GOHELLO.ELF
EOF

vgate_file script-10c.txt <<'EOF'
echo rx-gostore-10-ok
EOF

vgate_file script-11a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-11x.txt <<'EOF'
exec GOSTORE.ELF --remote=10.0.0.2:4857 --channel=/host/DROPV2
EOF

vgate_file script-11b.txt <<'EOF'
echo rx-gostore-11-ok
EOF

vgate_file script-12a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-12x.txt <<'EOF'
exec GOSTORE.ELF --remote=10.0.0.2:4858 --channel=/host/DROPV2
EOF

vgate_file script-12b.txt <<'EOF'
exec GOHELLO.ELF
EOF

vgate_file script-13a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-13x.txt <<'EOF'
exec GOSTORE.ELF --remote=10.0.0.2:4857 --channel=/host/DROP
EOF

vgate_file script-13b.txt <<'EOF'
exec NEEDY.ELF
EOF

vgate_file script-14a.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script-14x.txt <<'EOF'
exec GOSTORE.ELF --remote=10.0.0.2:4857 --channel=/host/DROP
EOF

vgate_file script-14b.txt <<'EOF'
echo rx-gostore-14-ok
EOF

# --- setup -------------------------------------------------------------------
vgate_setup_python <<'PY'
import hashlib, json, os, shutil, socket, subprocess, sys, time

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")

for name, cmd in (
    ("GOTABWM.ELF", "bash tools/go/build-gotabwm.sh"),
    ("GOSTORE.ELF", "bash tools/go/build-gostore.sh"),
    ("STORE.ELF", "bash tools/go/build-store.sh"),
    ("FLINT.ELF", "bash tools/go/build-flint.sh"),
    ("GOSH.ELF", "bash tools/go/build-gosh.sh"),
    ("GOHELLO.ELF", "bash tools/go/build-go.sh"),
):
    if not os.path.isfile(os.path.join(".build", "go", name)):
        sys.exit(name + " missing (expected .build/go/" + name +
                 ") - build it first: " + cmd)

# ---- host flintd (the go-flint discovery pattern, its own port lane) --------
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
    capture_output=True, text=True,
).stdout.strip()
subprocess.check_call(["zig", "build"], cwd=flint_server_dir)
flintd = os.path.join(flint_server_dir, "zig-out", "bin", "flintd")
if not os.path.isfile(flintd):
    sys.exit("flintd missing after zig build (expected " + flintd + ")")

# The shared --auth-key secret: 64 lowercase hex + newline (guest copy rides
# the slot-70 lane bound to the named apps, never the share).
AUTH_KEY_HEX = "ab" * 32
auth_key_file = os.path.join(run, "flint-auth.key")
open(auth_key_file, "w", encoding="utf-8").write(AUTH_KEY_HEX + "\n")

# flintd serves the pinned sync-seed `main` plus the release streams the
# catalog legs enumerate (rel/rel2/legacy replicas are staged on the share
# verbatim — the wire read cannot carry a release-sized Change, the same
# ~1460 B boundary go-flint's header documents — while the key-refused
# badkey/revkey stay remote-only so clone/verify runs for real).
good_raw = open(os.path.join("user", "go", "flint", "testdata", "sync", "seed-stream.jsonl"), "rb").read()
good_changes = [json.loads(l) for l in good_raw.decode("utf-8").splitlines() if l.strip()]
stream_id = good_changes[-1]["stream"]
rel_stream_id = "0199de2d-dc00-7000-8000-00000000b010"
flintd_store = os.path.join(run, "flintd-store")
os.makedirs(os.path.join(flintd_store, "streams"), exist_ok=True)
with open(os.path.join(flintd_store, "streams", stream_id + ".jsonl"), "wb") as f:
    f.write(good_raw)
with open(os.path.join(flintd_store, "streams", stream_id + ".json"), "w") as f:
    f.write(json.dumps(
        {"id": stream_id, "name": "main", "head": good_changes[-1]["id"],
         "created": good_changes[0]["ts"], "forked_from": None},
        separators=(",", ":")) + "\n")

# ---- signed release fixtures (store's env-gated generator) ------------------
gohello = os.path.join(".build", "go", "GOHELLO.ELF")
elf_bytes = open(gohello, "rb").read()
REL_SUMMARY = "Go Hello greets VirelaiOS"
REL_DESCRIPTION = ("Go Hello prints a greeting over the serial console.\n"
                   "It is the fleet's smallest signed release.")
REL_CATEGORY = "demo"


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

gen_release_fixture({
    "STORE_FIXTURE_SUMMARY": REL_SUMMARY,
    "STORE_FIXTURE_DESCRIPTION": REL_DESCRIPTION,
    "STORE_FIXTURE_CATEGORY": REL_CATEGORY,
})
rel_change_line = open(os.path.join("user", "go", "store", "testdata",
                                    "release-stream.jsonl"),
                       "r", encoding="utf-8").read().strip()
rel_change = json.loads(rel_change_line)
release_go = open(os.path.join("user", "go", "store", "testdata", "release.go"),
                  "r", encoding="utf-8").read()

# v2: marker-patched GOHELLO (distinct bytes/sha/marker, no second build).
mark_v1 = b"virelai-go OK"
mark_v2 = b"virelai-go V2"
if elf_bytes.count(mark_v1) != 1:
    sys.exit("GOHELLO.ELF marker %r occurs %d times (need exactly 1)"
             % (mark_v1, elf_bytes.count(mark_v1)))
elf_v2 = elf_bytes.replace(mark_v1, mark_v2)
open(os.path.join(fixture_dir, "gohello-v2.elf"), "wb").write(elf_v2)

gen_release_fixture({
    "STORE_FIXTURE_ELF": os.path.join(fixture_dir, "gohello-v2.elf"),
    "STORE_FIXTURE_VERSION": "2.0.0",
    "STORE_FIXTURE_PARENT": rel_change["id"],
    "STORE_FIXTURE_PREV_ELF": os.path.abspath(gohello),
    "STORE_FIXTURE_PREV_VERSION": "1.0.0",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000c002",
    "STORE_FIXTURE_TS": "1760000100000",
    "STORE_FIXTURE_SUMMARY": REL_SUMMARY,
    "STORE_FIXTURE_DESCRIPTION": REL_DESCRIPTION,
    "STORE_FIXTURE_CATEGORY": REL_CATEGORY,
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "v2",
})
rel_v2_line = open(os.path.join(fixture_dir, "release-v2-stream.jsonl"),
                   "r", encoding="utf-8").read().strip()
rel_v2 = json.loads(rel_v2_line)
release_v2_go = open(os.path.join(fixture_dir, "release-v2.go"),
                     "r", encoding="utf-8").read()

# rel2: second publisher with every catalog field + pinned icon.
ICON_BLOB = (b"<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 8 8'>"
             b"<rect width='8' height='8' fill='#36c'/>"
             b"<circle cx='4' cy='4' r='3' fill='#fff'/></svg>\n")
icon_sha = hashlib.sha256(ICON_BLOB).hexdigest()
gen_release_fixture({
    "STORE_FIXTURE_ELF": os.path.abspath(gohello),
    "STORE_FIXTURE_NAME": "BOUNCE",
    "STORE_FIXTURE_VERSION": "1.4.0",
    "STORE_FIXTURE_ROW": "BOUNCE.ELF | Bounce | g | dock=false",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000b011",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000c010",
    "STORE_FIXTURE_TS": "1760000400000",
    "STORE_FIXTURE_MSG": "bounce release",
    "STORE_FIXTURE_SEED_HEX": "b3" * 32,
    "STORE_FIXTURE_SUMMARY": "A bouncing ball demo",
    "STORE_FIXTURE_DESCRIPTION": ("Bounce renders a ball on the desktop.\n"
                                  "Shipped by a second publisher."),
    "STORE_FIXTURE_CATEGORY": "game",
    "STORE_FIXTURE_ICON_SHA256": icon_sha,
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "rel2",
})
gen_release_fixture({
    "STORE_FIXTURE_ELF": os.path.abspath(gohello),
    "STORE_FIXTURE_NAME": "LEGACY",
    "STORE_FIXTURE_VERSION": "0.9.0",
    "STORE_FIXTURE_ROW": "LEGACY.ELF | Legacy | g | dock=false",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000b012",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000c011",
    "STORE_FIXTURE_TS": "1760000500000",
    "STORE_FIXTURE_MSG": "legacy four-const release",
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "legacy",
})
gen_release_fixture({
    "STORE_FIXTURE_EMPTY": "1",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000e010",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000e001",
    "STORE_FIXTURE_TS": "1760000200000",
    "STORE_FIXTURE_MSG": "untrusted publisher",
    "STORE_FIXTURE_SEED_HEX": "b1" * 32,
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "badkey",
})
gen_release_fixture({
    "STORE_FIXTURE_EMPTY": "1",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000e011",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000e002",
    "STORE_FIXTURE_TS": "1760000300000",
    "STORE_FIXTURE_MSG": "revoked publisher",
    "STORE_FIXTURE_SEED_HEX": "b2" * 32,
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "revkey",
})


# M188c legs: rel3 (NEEDY) declares ReleaseDepends=BOUNCE — the resolved
# dep is rel2's release name; rel4 (ORPHAN) declares a dep no stream
# carries — the dep_missing leg. NEEDY.ELF is the marker-patched GOHELLO
# (same 13-byte marker slot the v2 fixture uses).
mark_dp = b"virelai-go DP"
if len(mark_dp) != len(mark_v1):
    sys.exit("marker length mismatch")
elf_dp = elf_bytes.replace(mark_v1, mark_dp)
open(os.path.join(fixture_dir, "gohello-dp.elf"), "wb").write(elf_dp)
gen_release_fixture({
    "STORE_FIXTURE_ELF": os.path.join(fixture_dir, "gohello-dp.elf"),
    "STORE_FIXTURE_NAME": "NEEDY",
    "STORE_FIXTURE_VERSION": "1.0.0",
    "STORE_FIXTURE_ROW": "NEEDY.ELF | Needy | g | dock=false",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000b013",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000c012",
    "STORE_FIXTURE_TS": "1760000600000",
    "STORE_FIXTURE_MSG": "needy release",
    "STORE_FIXTURE_DEPENDS": "BOUNCE",
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "rel3",
})
gen_release_fixture({
    "STORE_FIXTURE_ELF": os.path.abspath(gohello),
    "STORE_FIXTURE_NAME": "ORPHAN",
    "STORE_FIXTURE_VERSION": "1.0.0",
    "STORE_FIXTURE_ROW": "ORPHAN.ELF | Orphan | g | dock=false",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000b014",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000c013",
    "STORE_FIXTURE_TS": "1760000700000",
    "STORE_FIXTURE_MSG": "orphan release",
    "STORE_FIXTURE_DEPENDS": "NOSUCHAPP",
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "rel4",
})


def load_gen_change(tag):
    line = open(os.path.join(fixture_dir, "release-%s-stream.jsonl" % tag),
                "r", encoding="utf-8").read().strip()
    return json.loads(line), line


badkey_ch, badkey_line = load_gen_change("badkey")
revkey_ch, revkey_line = load_gen_change("revkey")
rel2_ch, rel2_line = load_gen_change("rel2")
legacy_ch, legacy_line = load_gen_change("legacy")
rel3_ch, rel3_line = load_gen_change("rel3")
rel4_ch, rel4_line = load_gen_change("rel4")
rel2_go = open(os.path.join(fixture_dir, "release-rel2.go"),
               "r", encoding="utf-8").read()
legacy_go = open(os.path.join(fixture_dir, "release-legacy.go"),
                 "r", encoding="utf-8").read()
rel3_go = open(os.path.join(fixture_dir, "release-rel3.go"),
               "r", encoding="utf-8").read()
rel4_go = open(os.path.join(fixture_dir, "release-rel4.go"),
               "r", encoding="utf-8").read()

# badkey/revkey are remote-only — the keyring gate fires inside FLINT.ELF
# on the real clone the GUI's list and install legs run.
for ch, line, sname in ((badkey_ch, badkey_line, "badkey"),
                        (revkey_ch, revkey_line, "revkey")):
    with open(os.path.join(flintd_store, "streams", ch["stream"] + ".jsonl"), "w") as f:
        f.write(line + "\n")
    with open(os.path.join(flintd_store, "streams", ch["stream"] + ".json"), "w") as f:
        f.write(json.dumps(
            {"id": ch["stream"], "name": sname, "head": ch["id"],
             "created": ch["ts"], "forked_from": None},
            separators=(",", ":")) + "\n")

for ch, line, sname in ((rel_change, rel_change_line, "rel"),
                        (rel2_ch, rel2_line, "rel2"),
                        (legacy_ch, legacy_line, "legacy"),
                        (rel3_ch, rel3_line, "rel3"),
                        (rel4_ch, rel4_line, "rel4")):
    with open(os.path.join(flintd_store, "streams", ch["stream"] + ".jsonl"), "w") as f:
        f.write(line + "\n")
    with open(os.path.join(flintd_store, "streams", ch["stream"] + ".json"), "w") as f:
        f.write(json.dumps(
            {"id": ch["stream"], "name": sname, "head": ch["id"],
             "created": ch["ts"], "forked_from": None},
            separators=(",", ":")) + "\n")

subprocess.run(
    ["sh", "-c", "lsof -ti tcp:4857 | xargs kill -9"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
time.sleep(0.2)
flintd_log = open(os.path.join(run, "flintd.log"), "wb")
flintd_proc = subprocess.Popen(
    [flintd, "serve", "--store=" + flintd_store,
     "--listen=127.0.0.1:4857", "--auth-key=" + auth_key_file],
    stdout=flintd_log, stderr=subprocess.STDOUT, start_new_session=True,
)
flintd_up = False
for _ in range(100):
    try:
        s = socket.create_connection(("127.0.0.1", 4857), 0.2)
        s.close()
        flintd_up = True
        break
    except OSError:
        if flintd_proc.poll() is not None:
            break
        time.sleep(0.1)
if not flintd_up:
    sys.exit("flintd did not come up on 127.0.0.1:4857 (see flintd.log)")
print("flintd: serving %s on 127.0.0.1:4857 pid=%d rev=%s"
      % (flintd_store, flintd_proc.pid, flintd_rev))

# A second remote on 4858 carries rel at the v2 head (v1+v2 lines) — the
# update legs pull the 1.2 KiB v2 Change over the wire like any other
# sync (MaxLineBytes is 4 MiB; "release-sized" only names the payload a
# Change's ops embed, never the ELF, which still arrives via --channel).
flintd_store_v2 = os.path.join(run, "flintd-store-v2")
if os.path.isdir(flintd_store_v2):
    shutil.rmtree(flintd_store_v2)
shutil.copytree(flintd_store, flintd_store_v2)
with open(os.path.join(flintd_store_v2, "streams",
                       rel_stream_id + ".jsonl"), "w") as f:
    f.write(rel_change_line + "\n" + rel_v2_line + "\n")
with open(os.path.join(flintd_store_v2, "streams",
                       rel_stream_id + ".json"), "w") as f:
    f.write(json.dumps(
        {"id": rel_stream_id, "name": "rel", "head": rel_v2["id"],
         "created": rel_v2["ts"], "forked_from": None},
        separators=(",", ":")) + "\n")
subprocess.run(
    ["sh", "-c", "lsof -ti tcp:4858 | xargs kill -9"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
time.sleep(0.2)
flintd2_proc = subprocess.Popen(
    [flintd, "serve", "--store=" + flintd_store_v2,
     "--listen=127.0.0.1:4858", "--auth-key=" + auth_key_file],
    stdout=flintd_log, stderr=subprocess.STDOUT, start_new_session=True,
)
flintd2_up = False
for _ in range(100):
    try:
        s = socket.create_connection(("127.0.0.1", 4858), 0.2)
        s.close()
        flintd2_up = True
        break
    except OSError:
        if flintd2_proc.poll() is not None:
            break
        time.sleep(0.1)
if not flintd2_up:
    sys.exit("flintd did not come up on 127.0.0.1:4858 (see flintd.log)")
print("flintd: v2 remote serving %s on 127.0.0.1:4858 pid=%d"
      % (flintd_store_v2, flintd2_proc.pid))

# ---- the store-share: the seat's desktop plus the consumer side -------------
store_share = os.path.join(run, "store-share")
os.makedirs(os.path.join(store_share, "FLINT", "streams"), exist_ok=True)
os.makedirs(os.path.join(store_share, "FLINTJ"), exist_ok=True)

# The seat's app-bundle assets, same set the gate seed stages.
for name in ("GOTABWM.ELF", "GOSTORE.ELF", "STORE.ELF", "FLINT.ELF", "GOSH.ELF"):
    shutil.copy(os.path.join(".build", "go", name), os.path.join(store_share, name))
shutil.copy(os.path.join("image", "apps.txt"), os.path.join(store_share, "APPS.TXT"))
if os.path.isfile(os.path.join("image", "WALLPAPER.QOI")):
    shutil.copy(os.path.join("image", "WALLPAPER.QOI"),
                os.path.join(store_share, "WALLPAPER.QOI"))
if os.path.isfile(os.path.join("user", "src", "lib", "fixtures", "qoi",
                               "mascot_64x64.qoi")):
    shutil.copy(os.path.join("user", "src", "lib", "fixtures", "qoi",
                             "mascot_64x64.qoi"),
                os.path.join(store_share, "SEXIBURGER.QOI"))
for src, dst in (("Inter-Regular.ttf", "INTER.TTF"),
                 ("Inter-Bold.ttf", "INTERB.TTF"),
                 ("Inter-Italic.ttf", "INTERI.TTF"),
                 ("Inter-BoldItalic.ttf", "INTERBI.TTF"),
                 ("FiraCode-Regular.ttf", "FIRACODE.TTF")):
    p = os.path.join("image", "fonts", src)
    if os.path.isfile(p):
        shutil.copy(p, os.path.join(store_share, dst))

# A present-but-empty SESSION.TABS v2 ([version=2][active+1=0][count=0]
# [seq lo][seq hi][prefs]) reads as restored, so no boot takes the
# first-boot starter GOSH — the runtime envelope stays the proven three
# (seat + GOSTORE + the FLINT child), never the overflow shape.
open(os.path.join(store_share, "SESSION.TABS"), "wb").write(b"\x02\x00\x00\x00\x00\x00")

# OWNERS.TXT makes the three secret-bound apps uid_system-owned images
# (the slot-70 binding needs the name match AND the ownership bit).
open(os.path.join(store_share, "OWNERS.TXT"), "w", encoding="utf-8").write(
    "#v1\nFLINT.ELF\t644\t0\t-\nSTORE.ELF\t644\t0\t-\nGOSTORE.ELF\t644\t0\t-\n"
)
# flint-remote: the wire auth secret, bound to every process that may
# speak FLINT-SYNC/1 — the GUI speaks it in-process now, so GOSTORE.ELF
# joins the allowlist beside FLINT.ELF and STORE.ELF.
open(os.path.join(store_share, "SECRETS.TXT"), "w", encoding="utf-8").write(
    "#v1\nflint-remote\t1000\t" + AUTH_KEY_HEX + "\tFLINT.ELF,STORE.ELF,GOSTORE.ELF\n"
)

# The publisher keyring: the release author pinned, the second publisher
# labeled acme, revkey's author revoked; badkey's stays absent.
open(os.path.join(store_share, "FLINT", "TRUSTED.TXT"), "w", encoding="utf-8").write(
    "#v1\nkey=" + good_changes[-1]["author"] + " name=sync-seed\n"
    "key=" + rel2_ch["author"] + " name=acme\n"
    "revoked=" + revkey_ch["author"] + "\n"
)

# Local replicas, byte-identical to what clone would write.
for ch, line, sname in ((good_changes[-1], good_raw.decode("utf-8"), "main"),
                        (rel_change, rel_change_line, "rel"),
                        (rel2_ch, rel2_line, "rel2"),
                        (legacy_ch, legacy_line, "legacy"),
                        (rel3_ch, rel3_line, "rel3"),
                        (rel4_ch, rel4_line, "rel4")):
    sid = ch["stream"]
    with open(os.path.join(store_share, "FLINT", "streams", sid + ".jsonl"), "w") as f:
        f.write(line if line.endswith("\n") else line + "\n")
    with open(os.path.join(store_share, "FLINT", "streams", sid + ".json"), "w") as f:
        f.write(json.dumps(
            {"id": sid, "name": sname, "head": ch["id"],
             "created": ch["ts"], "forked_from": None},
            separators=(",", ":")) + "\n")



def write_drop(drop, rel_text, elf, sname="rel", bin_name="GOHELLO.ELF"):
    d = os.path.join(store_share, drop, sname)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "release.go"), "w", encoding="utf-8").write(rel_text)
    open(os.path.join(d, bin_name), "wb").write(elf)


write_drop("DROP", release_go, elf_bytes)
write_drop("DROP", rel2_go, elf_bytes, sname="rel2", bin_name="BOUNCE.ELF")
open(os.path.join(store_share, "DROP", "rel2", "icon"), "wb").write(ICON_BLOB)
write_drop("DROP", legacy_go, elf_bytes, sname="legacy", bin_name="LEGACY.ELF")
write_drop("DROPV2", release_v2_go, elf_v2)
write_drop("DROPV2BAD", release_v2_go, elf_v2 + b"\x00")
write_drop("DROPV2SIG", release_v2_go.replace('"2.0.0"', '"9.9.9"'), elf_v2)
write_drop("DROP", rel3_go, elf_dp, sname="rel3", bin_name="NEEDY.ELF")
write_drop("DROP", rel4_go, elf_bytes, sname="rel4", bin_name="ORPHAN.ELF")

# The pinned member for rel's v1 head (ADR 0055 D9): `store pin` to the
# prior signed head fetches <stream>/<head-change-id-hex>/ off the same
# channel the v2 drop rides.
pin_v1 = os.path.join(store_share, "DROPV2", "rel",
                      rel_change["id"].replace("-", ""))
os.makedirs(pin_v1, exist_ok=True)
open(os.path.join(pin_v1, "release.go"), "w", encoding="utf-8").write(release_go)
open(os.path.join(pin_v1, "GOHELLO.ELF"), "wb").write(elf_bytes)
desc_tampered = release_v2_go.replace("smallest signed release",
                                      "smallest unsigned release")
assert desc_tampered != release_v2_go
shutil.copytree(os.path.join(store_share, "DROP"),
                os.path.join(store_share, "DROPBADDESC"))
write_drop("DROPBADDESC", desc_tampered, elf_v2)

# Pinned ids/shas the run asserts read back.
open(os.path.join(run, "ids.json"), "w").write(json.dumps({
    "rel": rel_change["id"], "v1_sha": hashlib.sha256(elf_bytes).hexdigest(),
    "v2": rel_v2["id"], "v2_sha": hashlib.sha256(elf_v2).hexdigest(),
    "rel_sid": rel_stream_id,
    "rel_row": "GOHELLO.ELF | Go Hello | g | dock=false",
}))
print("staged store-share: seat assets + GOSTORE/STORE/FLINT/GOSH ELFs, "
      "TRUSTED/SECRETS keyring, four replicas, five drops")
PY

# ---- 01: browse -> search -> detail -> install, each leg visible -----------
vgate_run 01 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-01' \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap01.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4857:relay --net-tcp-respond-relay 127.0.0.1:4857 \
    --script '$RUN_DIR/script-01a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-01x.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/gohello\ni' \
    --input-string-after 'gostore: ready' \
    --script3 '$RUN_DIR/script-01b.txt' \
    --script3-after 'store: install ok' \
    --script-expect 'virelai-go OK' --timeout 900

vgate_assert 01 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-absent 'gotabwm: first-boot workspace'
vgate_assert 01 serial-contains 'exec: loaded GOSTORE.ELF'
vgate_assert 01 serial-contains 'gostore: open id='
vgate_assert 01 serial-contains 'gostore: declare accepted'
vgate_assert 01 serial-contains 'gostore: ready'
vgate_assert 01 serial-contains 'gostore: list rows='
vgate_assert 01 serial-contains 'gostore: stream rel release'
vgate_assert 01 serial-contains 'gostore: stream main no-release'
vgate_assert 01 serial-contains 'gostore: stream badkey sync-failed'
vgate_assert 01 serial-contains 'gostore: stream revkey sync-failed'
# The two keyring negatives refuse inside the FLINT children the GUI's own
# catalog sync spawned — the live negatives on the happy-path boot.
vgate_assert 01 serial-count 'flint: refuse key_unknown' 1
vgate_assert 01 serial-count 'flint: refuse key_revoked' 1
# install + every leg of the signed pipeline visible in the GUI's narration.
vgate_assert 01 serial-contains 'gostore: install rel'
vgate_assert 01 serial-contains 'gostore: leg sync'
vgate_assert 01 serial-contains 'gostore: leg verify'
vgate_assert 01 serial-contains 'gostore: leg fetch'
vgate_assert 01 serial-contains 'gostore: leg sha'
vgate_assert 01 serial-contains 'gostore: leg publish'
vgate_assert 01 serial-contains 'store: install ok GOHELLO.ELF version=1.0.0'
vgate_assert 01 serial-contains 'gostore: install rc=0'
vgate_assert 01 serial-contains 'virelai-go OK'
vgate_assert 01 serial-absent 'store: refuse'
vgate_assert 01 serial-absent 'sig_invalid'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import hashlib, json, os, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
elf = os.path.join(share, "GOHELLO.ELF")
if not os.path.isfile(elf):
    sys.exit("GOHELLO.ELF missing at share root after install")
ids = json.load(open(os.path.join(run, "ids.json")))
got = hashlib.sha256(open(elf, "rb").read()).hexdigest()
if got != ids["v1_sha"]:
    sys.exit("installed GOHELLO.ELF hash %s != v1 %s" % (got, ids["v1_sha"]))
apps = open(os.path.join(share, "APPS.TXT"), "r", encoding="utf-8").read()
if apps.count("GOHELLO.ELF |") != 1:
    sys.exit("expected exactly one GOHELLO row in APPS.TXT: %r" % apps)
print("run-01 GUI install landed the pinned v1 bytes + one manifest row")
PY

vgate_assert 01 python <<'PY2'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
# WINDOWS.SAV restores kernel-owned windows next boot — delete it so the
# seat's session windows do not accumulate into the 8-slot cap.
# SESSION.TABS gets the empty-seed bytes back, not a delete: a missing
# file is the seat's first-boot branch (starter GOSH).
p = os.path.join(share, "WINDOWS.SAV")
if os.path.isfile(p):
    os.remove(p)
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x00" * 6)
print("reset seat session files")
PY2

# ---- 02: replica advance + update through the GUI -> v2 runs --------------
vgate_run 02 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-02' \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap02.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4858:relay --net-tcp-respond-relay 127.0.0.1:4858 \
    --script '$RUN_DIR/script-02a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-02b.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/gohello\nu' \
    --input-string-after 'gostore: ready' \
    --script3 '$RUN_DIR/script-02c.txt' \
    --script3-after 'store: update ok' \
    --script-expect 'virelai-go V2' --timeout 900

vgate_assert 02 serial-contains 'gostore: update GOHELLO'
vgate_assert 02 serial-contains 'gostore: leg sync'
vgate_assert 02 serial-contains 'gostore: leg verify'
vgate_assert 02 serial-contains 'gostore: leg fetch'
vgate_assert 02 serial-contains 'gostore: leg sha'
vgate_assert 02 serial-contains 'gostore: leg publish'
vgate_assert 02 serial-contains 'gostore: leg prev'
vgate_assert 02 serial-contains 'store: update ok GOHELLO.ELF version=2.0.0'
vgate_assert 02 serial-contains 'gostore: update rc=0'
vgate_assert 02 serial-contains 'virelai-go V2'
vgate_assert 02 serial-absent 'store: refuse'
vgate_assert 02 serial-absent 'sig_invalid'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import hashlib, json, os, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
ids = json.load(open(os.path.join(run, "ids.json")))
live = hashlib.sha256(open(os.path.join(share, "GOHELLO.ELF"), "rb").read()).hexdigest()
prev = hashlib.sha256(open(os.path.join(share, "GOHELLO.ELF.prev"), "rb").read()).hexdigest()
if live != ids["v2_sha"]:
    sys.exit("post-update live ELF %s != v2" % live)
if prev != ids["v1_sha"]:
    sys.exit("post-update .prev %s != v1" % prev)
print("run-02 GUI update published v2 and retained v1 as .prev")
PY

vgate_assert 02 python <<'PY2'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
# WINDOWS.SAV restores kernel-owned windows next boot — delete it so the
# seat's session windows do not accumulate into the 8-slot cap.
# SESSION.TABS gets the empty-seed bytes back, not a delete: a missing
# file is the seat's first-boot branch (starter GOSH).
p = os.path.join(share, "WINDOWS.SAV")
if os.path.isfile(p):
    os.remove(p)
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x00" * 6)
print("reset seat session files")
PY2

# ---- 03: rollback through the GUI -> v1 runs -------------------------------
vgate_run 03 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-03' \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap03.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4857:relay --net-tcp-respond-relay 127.0.0.1:4857 \
    --script '$RUN_DIR/script-03a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-03x.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/gohello\nr' \
    --input-string-after 'gostore: ready' \
    --script3 '$RUN_DIR/script-03b.txt' \
    --script3-after 'store: rollback ok' \
    --script-expect 'virelai-go OK' --timeout 900

vgate_assert 03 serial-contains 'gostore: rollback GOHELLO'
vgate_assert 03 serial-contains 'gostore: leg prev'
vgate_assert 03 serial-contains 'gostore: leg publish'
vgate_assert 03 serial-contains 'store: rollback ok GOHELLO.ELF'
vgate_assert 03 serial-contains 'gostore: rollback rc=0'
vgate_assert 03 serial-contains 'virelai-go OK'
vgate_assert 03 serial-absent 'virelai-go V2'
vgate_assert 03 serial-absent 'store: refuse'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import hashlib, json, os, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
ids = json.load(open(os.path.join(run, "ids.json")))
live = hashlib.sha256(open(os.path.join(share, "GOHELLO.ELF"), "rb").read()).hexdigest()
prev = hashlib.sha256(open(os.path.join(share, "GOHELLO.ELF.prev"), "rb").read()).hexdigest()
if live != ids["v1_sha"]:
    sys.exit("post-rollback live ELF %s != v1" % live)
if prev != ids["v2_sha"]:
    sys.exit("post-rollback .prev %s != v2" % prev)
print("run-03 GUI rollback restored v1 and rotated v2 into .prev")
PY

vgate_assert 03 python <<'PY2'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
# WINDOWS.SAV restores kernel-owned windows next boot — delete it so the
# seat's session windows do not accumulate into the 8-slot cap.
# SESSION.TABS gets the empty-seed bytes back, not a delete: a missing
# file is the seat's first-boot branch (starter GOSH).
p = os.path.join(share, "WINDOWS.SAV")
if os.path.isfile(p):
    os.remove(p)
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x00" * 6)
print("reset seat session files")
PY2

# ---- 04: update killed mid-publish — the .prev target must survive ---------
vgate_run 04 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-04' \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap04.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4858:relay --net-tcp-respond-relay 127.0.0.1:4858 \
    --script '$RUN_DIR/script-04a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-04x.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/gohello\nu' \
    --input-string-after 'gostore: ready' \
    --script3 '$RUN_DIR/script-04b.txt' \
    --script3-after 'gostore: pause prev' \
    --script-expect 'kill: GOSTORE.ELF armed' \
    --script-expect-tail 3 --timeout 900

vgate_assert 04 serial-contains 'gostore: update GOHELLO'
vgate_assert 04 serial-contains 'gostore: leg publish'
vgate_assert 04 serial-contains 'gostore: pause prev'
vgate_assert 04 serial-contains 'kill: GOSTORE.ELF armed'
vgate_assert 04 serial-contains 'exited status=137'
vgate_assert 04 serial-absent 'store: update ok'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 python <<'PY'
import hashlib, json, os, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
ids = json.load(open(os.path.join(run, "ids.json")))
# The kill landed after the STORE.TXT commit (state names v2, prev = v1)
# and before the .prev rotation — the documented torn shape.
live = hashlib.sha256(open(os.path.join(share, "GOHELLO.ELF"), "rb").read()).hexdigest()
if live != ids["v2_sha"]:
    sys.exit("live ELF after kill %s != committed v2" % live)
staged = os.path.join(share, "GOHELLO.ELF.prev.new")
if not os.path.isfile(staged):
    sys.exit("GOHELLO.ELF.prev.new missing — the staged rollback bytes died with the kill")
staged_sha = hashlib.sha256(open(staged, "rb").read()).hexdigest()
if staged_sha != ids["v1_sha"]:
    sys.exit("staged .prev.new %s != the v1 rollback target" % staged_sha)
state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if ids["v2"] not in state or ids["v1_sha"] not in state:
    sys.exit("STORE.TXT did not commit v2 + prev=v1 before the kill:\n" + state)
print("run-04 killed mid-publish: commit landed, .prev.new keeps the v1 rollback target")
PY

vgate_assert 04 python <<'PY2'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
# WINDOWS.SAV restores kernel-owned windows next boot — delete it so the
# seat's session windows do not accumulate into the 8-slot cap.
# SESSION.TABS gets the empty-seed bytes back, not a delete: a missing
# file is the seat's first-boot branch (starter GOSH).
p = os.path.join(share, "WINDOWS.SAV")
if os.path.isfile(p):
    os.remove(p)
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x00" * 6)
print("reset seat session files")
PY2

# ---- 05: rollback after the kill — the .prev target re-materializes --------
vgate_run 05 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-05' \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap05.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4857:relay --net-tcp-respond-relay 127.0.0.1:4857 \
    --script '$RUN_DIR/script-05a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-05x.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/gohello\nr' \
    --input-string-after 'gostore: ready' \
    --script3 '$RUN_DIR/script-05b.txt' \
    --script3-after 'store: rollback ok' \
    --script-expect 'virelai-go OK' --timeout 900

vgate_assert 05 serial-contains 'gostore: rollback GOHELLO'
vgate_assert 05 serial-contains 'gostore: leg prev'
vgate_assert 05 serial-contains 'store: rollback ok GOHELLO.ELF'
vgate_assert 05 serial-contains 'virelai-go OK'
vgate_assert 05 serial-absent 'store: refuse'
vgate_assert 05 serial-absent 'store: refuse prev_missing'
vgate_assert 05 serial-absent 'store: refuse prev_mismatch'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 python <<'PY'
import hashlib, json, os, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
ids = json.load(open(os.path.join(run, "ids.json")))
live = hashlib.sha256(open(os.path.join(share, "GOHELLO.ELF"), "rb").read()).hexdigest()
if live != ids["v1_sha"]:
    sys.exit("rollback after the killed update restored %s != v1" % live)
print("run-05 the killed update's .prev target re-materialized as the live v1")
PY

vgate_assert 05 python <<'PY2'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
# WINDOWS.SAV restores kernel-owned windows next boot — delete it so the
# seat's session windows do not accumulate into the 8-slot cap.
# SESSION.TABS gets the empty-seed bytes back, not a delete: a missing
# file is the seat's first-boot branch (starter GOSH).
p = os.path.join(share, "WINDOWS.SAV")
if os.path.isfile(p):
    os.remove(p)
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x00" * 6)
print("reset seat session files")
PY2

# ---- 06: elf_mismatch through the GUI update --------------------------------
vgate_run 06 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-06' \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap06.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4858:relay --net-tcp-respond-relay 127.0.0.1:4858 \
    --script '$RUN_DIR/script-06a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-06x.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/gohello\nu' \
    --input-string-after 'gostore: ready' \
    --script-expect 'gostore: update rc=1' \
    --script-expect-tail 3 --timeout 900

vgate_assert 06 serial-contains 'gostore: leg sha'
vgate_assert 06 serial-contains 'store: refuse elf_mismatch GOHELLO.ELF'
vgate_assert 06 serial-contains 'gostore: refuse elf_mismatch GOHELLO.ELF'
vgate_assert 06 serial-contains 'gostore: update rc=1'
vgate_assert 06 serial-absent 'store: update ok'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 python <<'PY'
import hashlib, json, os, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
ids = json.load(open(os.path.join(run, "ids.json")))
live = hashlib.sha256(open(os.path.join(share, "GOHELLO.ELF"), "rb").read()).hexdigest()
if live != ids["v1_sha"]:
    sys.exit("refused update touched the live ELF: %s != v1" % live)
print("run-06 elf_mismatch refused before any publish; live bytes untouched")
PY

vgate_assert 06 python <<'PY2'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
# WINDOWS.SAV restores kernel-owned windows next boot — delete it so the
# seat's session windows do not accumulate into the 8-slot cap.
# SESSION.TABS gets the empty-seed bytes back, not a delete: a missing
# file is the seat's first-boot branch (starter GOSH).
p = os.path.join(share, "WINDOWS.SAV")
if os.path.isfile(p):
    os.remove(p)
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x00" * 6)
print("reset seat session files")
PY2

# ---- 07: release_mismatch — the tampered manifest refuses at browse --------
vgate_run 07 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-07' \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap07.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4857:relay --net-tcp-respond-relay 127.0.0.1:4857 \
    --script '$RUN_DIR/script-07a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-07x.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/rel\n\n' \
    --input-string-after 'gostore: ready' \
    --script-expect 'gostore: detail rel open' --timeout 900

vgate_assert 07 serial-contains 'gostore: stream rel catalog-invalid release_mismatch'
vgate_assert 07 serial-contains 'gostore: detail rel open'
vgate_assert 07 serial-absent 'gostore: stream rel release'
vgate_assert 07 serial-absent 'store: install ok'
vgate_assert 07 serial-absent '[EXC] parking:'

vgate_assert 07 python <<'PY2'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
# WINDOWS.SAV restores kernel-owned windows next boot — delete it so the
# seat's session windows do not accumulate into the 8-slot cap.
# SESSION.TABS gets the empty-seed bytes back, not a delete: a missing
# file is the seat's first-boot branch (starter GOSH).
p = os.path.join(share, "WINDOWS.SAV")
if os.path.isfile(p):
    os.remove(p)
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x00" * 6)
print("reset seat session files")
PY2

# ---- 08: key_unknown + key_revoked — GUI install attempts refuse by name ---
vgate_run 08 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-08' \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap08.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4857:relay --net-tcp-respond-relay 127.0.0.1:4857 \
    --script '$RUN_DIR/script-08a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-08x.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/badkey\nijjjiq' \
    --input-string-after 'gostore: ready' \
    --script-expect 'gostore OK' \
    --script-expect-tail 2 --timeout 900

vgate_assert 08 serial-count 'flint: refuse key_unknown' 1
vgate_assert 08 serial-count 'flint: refuse key_revoked' 1
vgate_assert 08 serial-count 'store: refuse sync_failed' 2
vgate_assert 08 serial-count 'gostore: install rc=1' 2
vgate_assert 08 serial-absent 'store: install ok'
vgate_assert 08 serial-absent '[EXC] parking:'

vgate_assert 08 python <<'PY2'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
# WINDOWS.SAV restores kernel-owned windows next boot — delete it so the
# seat's session windows do not accumulate into the 8-slot cap.
# SESSION.TABS gets the empty-seed bytes back, not a delete: a missing
# file is the seat's first-boot branch (starter GOSH).
p = os.path.join(share, "WINDOWS.SAV")
if os.path.isfile(p):
    os.remove(p)
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x00" * 6)
print("reset seat session files")
PY2

# ---- 09: prev_mismatch — torn .prev refuses the GUI rollback ---------------
vgate_run 09 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-09' \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap09.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4857:relay --net-tcp-respond-relay 127.0.0.1:4857 \
    --script '$RUN_DIR/script-09a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-09b.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/gohello\nr' \
    --input-string-after 'gostore: ready' \
    --script-expect 'gostore: rollback rc=1' --timeout 900

vgate_assert 09 serial-contains 'gostore: leg prev'
vgate_assert 09 serial-contains 'store: refuse prev_mismatch GOHELLO.ELF'
vgate_assert 09 serial-contains 'gostore: refuse prev_mismatch GOHELLO.ELF'
vgate_assert 09 serial-contains 'gostore: rollback rc=1'
vgate_assert 09 serial-absent 'store: rollback ok'
vgate_assert 09 serial-absent '[EXC] parking:'

vgate_assert 09 python <<'PY2'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
# WINDOWS.SAV restores kernel-owned windows next boot — delete it so the
# seat's session windows do not accumulate into the 8-slot cap.
# SESSION.TABS gets the empty-seed bytes back, not a delete: a missing
# file is the seat's first-boot branch (starter GOSH).
p = os.path.join(share, "WINDOWS.SAV")
if os.path.isfile(p):
    os.remove(p)
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x00" * 6)
print("reset seat session files")
PY2

# ---- 10: state_mismatch — torn live ELF refuses update AND rollback --------
vgate_run 10 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-10' \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap10.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4858:relay --net-tcp-respond-relay 127.0.0.1:4858 \
    --script '$RUN_DIR/script-10a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-10b.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/gohello\nur' \
    --input-string-after 'gostore: ready' \
    --script-expect 'gostore: rollback rc=1' --timeout 900

vgate_assert 10 serial-count 'store: refuse state_mismatch GOHELLO.ELF' 2
vgate_assert 10 serial-contains 'gostore: update rc=1'
vgate_assert 10 serial-contains 'gostore: rollback rc=1'
vgate_assert 10 serial-absent 'store: update ok'
vgate_assert 10 serial-absent 'store: rollback ok'
vgate_assert 10 serial-absent '[EXC] parking:'

vgate_assert 10 python <<'PY2'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
# WINDOWS.SAV restores kernel-owned windows next boot — delete it so the
# seat's session windows do not accumulate into the 8-slot cap.
# SESSION.TABS gets the empty-seed bytes back, not a delete: a missing
# file is the seat's first-boot branch (starter GOSH).
p = os.path.join(share, "WINDOWS.SAV")
if os.path.isfile(p):
    os.remove(p)
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x00" * 6)
print("reset seat session files")
PY2

# ---- 11: remove through the GUI --------------------------------------------
vgate_run 11 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-11' \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap11.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4857:relay --net-tcp-respond-relay 127.0.0.1:4857 \
    --script '$RUN_DIR/script-11a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-11x.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/gohello\nd' \
    --input-string-after 'gostore: ready' \
    --script-expect 'gostore: remove rc=0' --timeout 900

vgate_assert 11 serial-contains 'gostore: remove GOHELLO'
vgate_assert 11 serial-contains 'gostore: leg publish'
vgate_assert 11 serial-contains 'store: remove ok GOHELLO.ELF'
vgate_assert 11 serial-contains 'gostore: remove rc=0'
vgate_assert 11 serial-absent 'store: refuse'
vgate_assert 11 serial-absent '[EXC] parking:'
vgate_assert 11 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
for gone in ("GOHELLO.ELF", "GOHELLO.ELF.prev", "GOHELLO.ELF.prev.new"):
    if os.path.exists(os.path.join(share, gone)):
        sys.exit(gone + " survived the GUI remove")
apps = open(os.path.join(share, "APPS.TXT"), "r", encoding="utf-8").read()
if "GOHELLO.ELF |" in apps:
    sys.exit("GOHELLO row survived remove: %r" % apps)
state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if "GOHELLO.ELF" in state:
    sys.exit("STORE.TXT entry survived remove: %r" % state)
print("run-11 GUI remove dropped ELF, .prev, manifest row, and state entry")
PY

vgate_assert 11 python <<'PY2'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
# WINDOWS.SAV restores kernel-owned windows next boot — delete it so the
# seat's session windows do not accumulate into the 8-slot cap.
# SESSION.TABS gets the empty-seed bytes back, not a delete: a missing
# file is the seat's first-boot branch (starter GOSH).
p = os.path.join(share, "WINDOWS.SAV")
if os.path.isfile(p):
    os.remove(p)
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x00" * 6)
print("reset seat session files")
PY2

# ---- 12: install the v2 head, then pin to the prior signed head (v1) -------
vgate_run 12 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-12' \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap12.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4858:relay --net-tcp-respond-relay 127.0.0.1:4858 \
    --script '$RUN_DIR/script-12a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-12x.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/gohello\nip' \
    --input-string-after 'gostore: ready' \
    --script3 '$RUN_DIR/script-12b.txt' \
    --script3-after 'store: pin ok' \
    --script-expect 'virelai-go OK' --timeout 900

vgate_assert 12 serial-contains 'store: install ok GOHELLO.ELF version=2.0.0'
vgate_assert 12 serial-contains 'gostore: pin GOHELLO'
vgate_assert 12 serial-contains 'gostore: leg deps'
vgate_assert 12 serial-contains 'gostore: leg fetch'
vgate_assert 12 serial-contains 'gostore: leg sha'
vgate_assert 12 serial-contains 'gostore: leg publish'
vgate_assert 12 serial-contains 'gostore: leg prev'
vgate_assert 12 serial-contains 'store: pin ok GOHELLO.ELF head='
vgate_assert 12 serial-contains 'gostore: pin rc=0'
vgate_assert 12 serial-contains 'virelai-go OK'
vgate_assert 12 serial-absent 'store: refuse'
vgate_assert 12 serial-absent '[EXC] parking:'
vgate_assert 12 python <<'PY'
import hashlib, json, os, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
ids = json.load(open(os.path.join(run, "ids.json")))
live = hashlib.sha256(open(os.path.join(share, "GOHELLO.ELF"), "rb").read()).hexdigest()
prev = hashlib.sha256(open(os.path.join(share, "GOHELLO.ELF.prev"), "rb").read()).hexdigest()
if live != ids["v1_sha"]:
    sys.exit("post-pin live ELF %s != v1" % live)
if prev != ids["v2_sha"]:
    sys.exit("post-pin .prev %s != v2" % prev)
state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if ids["rel"] not in state or ids["v2"] not in state:
    sys.exit("STORE.TXT did not pin v1 head with v2 as prev:\n" + state)
print("run-12 pin to the prior signed head restored v1; v2 rides .prev")
PY

vgate_assert 12 python <<'PY2'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
# WINDOWS.SAV restores kernel-owned windows next boot — delete it so the
# seat's session windows do not accumulate into the 8-slot cap.
# SESSION.TABS gets the empty-seed bytes back, not a delete: a missing
# file is the seat's first-boot branch (starter GOSH).
p = os.path.join(share, "WINDOWS.SAV")
if os.path.isfile(p):
    os.remove(p)
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x00" * 6)
print("reset seat session files")
PY2

# ---- 13: ReleaseDepends resolved — NEEDY pulls BOUNCE first ----------------
vgate_run 13 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-13' \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap13.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4857:relay --net-tcp-respond-relay 127.0.0.1:4857 \
    --script '$RUN_DIR/script-13a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-13x.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/needy\ni' \
    --input-string-after 'gostore: ready' \
    --script3 '$RUN_DIR/script-13b.txt' \
    --script3-after 'store: install ok NEEDY.ELF' \
    --script-expect 'virelai-go DP' --timeout 900

vgate_assert 13 serial-contains 'gostore: install rel3'
vgate_assert 13 serial-contains 'gostore: leg deps'
vgate_assert 13 serial-contains 'store: dep BOUNCE -> rel2'
vgate_assert 13 serial-contains 'store: install ok BOUNCE.ELF'
vgate_assert 13 serial-contains 'store: install ok NEEDY.ELF'
vgate_assert 13 serial-contains 'gostore: install rc=0'
vgate_assert 13 serial-contains 'virelai-go DP'
vgate_assert 13 serial-absent '[EXC] parking:'
vgate_assert 13 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
for name in ("BOUNCE.ELF", "NEEDY.ELF"):
    if not os.path.isfile(os.path.join(share, name)):
        sys.exit(name + " missing after dep-resolved install")
apps = open(os.path.join(share, "APPS.TXT"), "r", encoding="utf-8").read()
if "BOUNCE.ELF |" not in apps or "NEEDY.ELF |" not in apps:
    sys.exit("dep-resolved install rows missing:\n" + apps)
print("run-13 dep-resolved install landed BOUNCE then NEEDY")
PY

vgate_assert 13 python <<'PY2'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
# WINDOWS.SAV restores kernel-owned windows next boot — delete it so the
# seat's session windows do not accumulate into the 8-slot cap.
# SESSION.TABS gets the empty-seed bytes back, not a delete: a missing
# file is the seat's first-boot branch (starter GOSH).
p = os.path.join(share, "WINDOWS.SAV")
if os.path.isfile(p):
    os.remove(p)
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x00" * 6)
print("reset seat session files")
PY2

# ---- 14: dep_missing — ORPHAN names a release no stream carries ------------
vgate_run 14 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-14' \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap14.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4857:relay --net-tcp-respond-relay 127.0.0.1:4857 \
    --script '$RUN_DIR/script-14a.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script-14x.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'/orphan\ni' \
    --input-string-after 'gostore: ready' \
    --script-expect 'gostore: install rc=1' \
    --script-expect-tail 3 --timeout 900

vgate_assert 14 serial-contains 'gostore: install rel4'
vgate_assert 14 serial-contains 'gostore: leg deps'
vgate_assert 14 serial-contains 'store: refuse dep_missing NOSUCHAPP'
vgate_assert 14 serial-contains 'gostore: refuse dep_missing NOSUCHAPP'
vgate_assert 14 serial-contains 'gostore: install rc=1'
vgate_assert 14 serial-absent 'store: install ok ORPHAN'
vgate_assert 14 serial-absent '[EXC] parking:'
vgate_assert 14 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
if os.path.exists(os.path.join(share, "ORPHAN.ELF")):
    sys.exit("ORPHAN.ELF landed despite dep_missing")
apps = open(os.path.join(share, "APPS.TXT"), "r", encoding="utf-8").read()
if "ORPHAN.ELF" in apps:
    sys.exit("ORPHAN row landed despite dep_missing")
print("run-14 dep_missing refused before any publish")
PY
