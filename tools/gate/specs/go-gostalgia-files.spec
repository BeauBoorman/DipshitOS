# go-gostalgia-files.spec -- M95d (#2012): Gostalgia's host-backed VFS
# confined on /host, recoverable document saves, byte-identical results
# on both share transports.
#
# One spec, three boots over ONE armed share:
#   save    -- the full pinned boot (runtime.Boot over vfs.NewHost =
#              gsport/vfs, not gssmoke's memfs substitute), then document
#              create/edit/save/readback through the fs service over the
#              env's own IPC, config persistence through the same
#              publish, plus the whole refusal class (escapes, the
#              reserved "~" suffix, over-long and over-deep names).
#   drill   -- a second boot that writes DRILL.TXT, then freezes inside
#              the publish at "target-delete" (fsynced temp closed, live
#              file gone, rename not yet run) and is killed there -- the
#              worst crash point of the sequence.
#   recover -- a third boot whose first read of DRILL.TXT completes the
#              pending publish and returns the NEW bytes; the config
#              value set in "save" must also be back.
#
# Old-or-new semantics (gsport/vfs): a live document is never truncated
# in place; "absent target + present `name~`" is provably a complete
# pending publish and the next access finishes the rename. The drill
# run's share asserts pin the intermediate state byte-exactly.
#
# Both transports: vgate_share is env-selectable. The guest program and
# every assertion are identical either way; byte-identity on the host
# side is what share-equals checks.
#   just gate go-gostalgia-files                                  # custom virtio (seed)
#   GOSTALGIA_FILES_SHARE=seed-virtiofs just gate go-gostalgia-files  # standard VirtioFS
#
# The driver ELF is a host prerequisite staged in setup: the overlay
# recipe (tools/go/build-gostalgia.sh, not in this card's Touches) is
# invoked unmodified to stage pin+overlays and emit the transient
# modfile, then ./cmd/gsvfs is built against that stage into
# .build/go/GSVFS.ELF.
#
# exec-order: assert-proven -- "save" and "recover" end on `gsvfs: done`,
# a marker only the program emits after every step succeeded; "drill"
# ends on the kernel's own kill receipt (`GSVFS.ELF exited status=137`),
# and its kill script is anchored on the program's `gsvfs: drill-armed`
# marker via --script2-after, never on timing.

vgate_name go-gostalgia-files "M95d: confined host VFS docs, recoverable saves, byte-identical on both transports"
vgate_share ${GOSTALGIA_FILES_SHARE:-seed}
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script-save.txt <<'EOF'
strace exec GSVFS.ELF save
EOF

vgate_file script-drill.txt <<'EOF'
strace exec GSVFS.ELF drill
EOF

vgate_file script-drill-kill.txt <<'EOF'
kill GSVFS.ELF
EOF

vgate_file script-recover.txt <<'EOF'
strace exec GSVFS.ELF recover
EOF

# Byte-exact expectations for share-equals (vgate_file bodies are
# newline-terminated, matching the driver's constants).
vgate_file note.expected <<'EOF'
field journal
first entry: the port holds.
second entry: edited through fs/write, saved whole.
EOF

vgate_file drill.expected <<'EOF'
drill new draft - fsynced before the kill, published by the next reader.
EOF

vgate_setup_python <<'PY'
import os, shutil, subprocess, sys

repo = os.getcwd()
rd = os.environ["RUN_DIR"]
share = os.path.join(rd, "share")
os.makedirs(share, exist_ok=True)

# Stage + build through the pinned recipe (invoked, not edited), then
# build the one command its target whitelist does not name. The recipe
# run also compiles every overlay in the staged tree (gssmoke is the
# recipe's default target and a whole-tree compile check).
r = subprocess.run(["bash", "tools/go/build-gostalgia.sh"], cwd=repo)
if r.returncode:
    sys.exit("build-gostalgia staging failed (rc=%d)" % r.returncode)
fork = os.environ.get("GO_FORK_DIR") or os.path.join(os.path.dirname(repo), "go-virelai")
env = dict(os.environ,
           GOROOT=fork,
           PATH=os.path.join(fork, "bin") + os.pathsep + os.environ["PATH"],
           GOTOOLCHAIN="local", CGO_ENABLED="0", GO111MODULE="on",
           GOWORK="off", GOFLAGS="", GOOS="virelai", GOARCH="arm64",
           LC_ALL="C", GOMAXPROCS="2", GOPROXY="off")
r = subprocess.run([os.path.join(fork, "bin", "go"), "build",
                    "-mod=mod", "-modfile", os.path.join(repo, ".build", "gostalgia.mod"),
                    "-p=2", "-ldflags", "-s -w",
                    "-o", os.path.join(repo, ".build", "go", "GSVFS.ELF"),
                    "./cmd/gsvfs"],
                   cwd=os.path.join(repo, ".build", "gostalgia-src"), env=env)
if r.returncode:
    sys.exit("gsvfs build failed (rc=%d)" % r.returncode)

src = os.path.join(repo, ".build", "go", "GSVFS.ELF")
shutil.copy(src, os.path.join(share, "GSVFS.ELF"))
print("staged GSVFS.ELF into share (%d bytes)" % os.path.getsize(src))

# Isolate headless fixture boots from the default Go seat: no WM seating.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")

# Snapshot what the share held BEFORE any gsvfs run; the confinement
# assert flags anything written outside GSVFS/ across all three boots.
seeded = sorted(p for p in (
    os.path.relpath(os.path.join(dp, f), share)
    for dp, _, fs in os.walk(share) for f in fs))
with open(os.path.join(rd, "seeded.txt"), "w") as f:
    f.write("\n".join(seeded) + "\n")
print("share seeded with %d files" % len(seeded))
PY

# --- run save ------------------------------------------------------------
vgate_run save -- \
    --script '$RUN_DIR/script-save.txt' \
    --script-expect 'gsvfs: done' --timeout 240

vgate_assert save serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert save serial-contains 'strace: armed'
vgate_assert save serial-contains 'gsvfs: ready endpoint=mem://gostalgia-'
vgate_assert save serial-contains 'gsvfs: wrote sha256='
vgate_assert save serial-contains 'gsvfs: edited sha256='
vgate_assert save serial-contains 'gsvfs: readback sha256='
vgate_assert save serial-contains 'gsvfs: mkdir+remove ok'
vgate_assert save serial-contains 'gsvfs: config sha256='
vgate_assert save serial-contains 'gsvfs: done'
vgate_assert save serial-absent 'gsvfs: FAIL'
vgate_assert save serial-absent '[EXC] parking:'
vgate_assert save serial-absent 'exited status=139'

# The refusal class, each refused by name.
vgate_assert save serial-contains 'gsvfs: refused escape-read'
vgate_assert save serial-contains 'gsvfs: refused escape-write'
vgate_assert save serial-contains 'gsvfs: refused tilde-suffix'
vgate_assert save serial-contains 'gsvfs: refused overlong-name'
vgate_assert save serial-contains 'gsvfs: refused over-depth'

# Byte identity on the armed share -- the transport (custom virtio or
# standard VirtioFS) is invisible to the assertion by design.
vgate_assert save share-equals 'GSVFS/vfs/users/guest/documents/NOTE.TXT' note.expected

# Slot evidence via the decoded strace names, same shape as
# go-gostalgia.spec: the publish sequence's slots must all burn and no
# adapted path may answer ENOSYS (the pin's Openat backend dying on
# ENOSYS is what this card replaces).
vgate_assert save python <<'PY'
import os, re, sys

serial = open(os.environ["VG_SER"], errors="replace").read()
records = re.findall(r"\[strace (\d+)\] (sys_[a-z_0-9]+)\(([^\n]*)", serial)
if not records:
    raise SystemExit("no decoded strace records")
name_to_slot = {
    "sys_file_open": 23, "sys_file_read": 24, "sys_file_write": 25,
    "sys_file_close": 26, "sys_dir_list": 27,
    "sys_file_delete": 34, "sys_file_rename": 35,
    "sys_file_sync": 77,
}
observed = {name_to_slot[n] for _, n, _ in records if n in name_to_slot}
required = {23, 24, 25, 26, 27, 34, 35, 77}
missing = sorted(required - observed)
if missing:
    raise SystemExit("adapter slots missing from trace: %s" % missing)
for pid, name, args in records:
    if args.endswith("= -ENOSYS") or args.endswith("= 0xfffffffffffffffc"):
        raise SystemExit("ENOSYS on %s from pid %s" % (name, pid))
print("slot evidence %s; no ENOSYS on %d records" % (sorted(observed & required), len(records)))
PY

# Confinement: the share may only ever hold GSVFS/ content plus the files
# the harness seeded — no escape write anywhere else, and nothing named
# 'outside.txt' or 'escape.txt' inside it either.
vgate_assert save python <<'PY'
import os, sys

share = os.environ["VG_SHARE"]
seeded = set(open(os.path.join(os.environ["RUN_DIR"], "seeded.txt")).read().split())
# The guest shell writes its own history file during any run that execs
# from it, and the kernel's measured-boot path (M113b #2418) drops the
# exec receipt RCPT.TXT at the share root — legitimate harness/kernel
# share writes, not gsvfs's.
shell_owned = {"HISTORY.TXT", "RCPT.TXT"}
stray = []
for dp, _, fs in os.walk(share):
    for f in fs:
        rel = os.path.relpath(os.path.join(dp, f), share)
        if rel in seeded or rel in shell_owned:
            continue
        if not rel.startswith("GSVFS/"):
            stray.append(rel)
        if f in ("outside.txt", "escape.txt"):
            stray.append(rel + " (refused-name landed)")
if stray:
    sys.exit("writes escaped the environment root: %s" % stray)
print("confinement holds: no share writes outside GSVFS/")
PY

# --- run drill -----------------------------------------------------------
vgate_run drill -- \
    --script '$RUN_DIR/script-drill.txt' \
    --script2 '$RUN_DIR/script-drill-kill.txt' \
    --script2-after 'gsvfs: drill-armed' \
    --script-expect 'GSVFS.ELF exited status=137' --timeout 240

vgate_assert drill serial-contains 'gsvfs: drill old sha256='
# The fsync stage printed BEFORE the armed stage -- the temp on the
# share was durable when the kill landed.
vgate_assert drill serial-contains 'gsvfs: staged temp-fsync'
vgate_assert drill serial-contains 'gsvfs: staged target-delete'
vgate_assert drill serial-contains 'gsvfs: drill-armed'
vgate_assert drill serial-contains 'kill: GSVFS.ELF armed'
vgate_assert drill serial-contains 'GSVFS.ELF exited status=137'
vgate_assert drill serial-absent 'gsvfs: FAIL'
vgate_assert drill serial-absent '[EXC] parking:'

# The pinned mid-publish state: live file absent, temp byte-complete.
# NOTE.TXT from the save run is untouched.
vgate_assert drill share-equals 'GSVFS/vfs/users/guest/documents/NOTE.TXT' note.expected
vgate_assert drill share-equals 'GSVFS/vfs/users/guest/documents/DRILL.TXT~' drill.expected
vgate_assert drill python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
live = os.path.join(share, "GSVFS/vfs/users/guest/documents/DRILL.TXT")
if os.path.exists(live):
    sys.exit("DRILL.TXT exists post-kill — the publish completed instead of stalling")
print("mid-publish state pinned: live absent, temp complete")
PY

# The config published in the save run must still be on the share after
# the drill kill — the drill freezes a document publish, not a config
# one. Pins where a cross-run loss happens if the kill ever eats it.
vgate_assert drill python <<'PY'
import os, sys
cfg = os.path.join(os.environ["VG_SHARE"], "GSVFS/config/system.json")
try:
    data = open(cfg, "rb").read()
except OSError as e:
    sys.exit("config/system.json missing after drill kill: %s" % e)
if b'"dusk"' not in data:
    sys.exit("config/system.json lost wallpaper=dusk: %r" % data)
print("config survived the kill boundary on the share")
PY

# --- run recover ---------------------------------------------------------
vgate_run recover -- \
    --script '$RUN_DIR/script-recover.txt' \
    --script-expect 'gsvfs: done' --timeout 240

vgate_assert recover serial-contains 'gsvfs: ready endpoint=mem://gostalgia-'
vgate_assert recover serial-contains 'gsvfs: recover publish users/guest/documents/DRILL.TXT'
vgate_assert recover serial-contains 'gsvfs: recovered sha256='
vgate_assert recover serial-contains 'gsvfs: config persisted wallpaper=dusk'
vgate_assert recover serial-contains 'gsvfs: done'
vgate_assert recover serial-absent 'gsvfs: FAIL'
vgate_assert recover serial-absent '[EXC] parking:'
vgate_assert recover serial-absent 'exited status=139'

# Recovery committed the NEW bytes; the temp is gone.
vgate_assert recover share-equals 'GSVFS/vfs/users/guest/documents/DRILL.TXT' drill.expected
vgate_assert recover share-equals 'GSVFS/vfs/users/guest/documents/NOTE.TXT' note.expected
vgate_assert recover python <<'PY'
import hashlib, os, sys
share = os.environ["VG_SHARE"]
docs = os.path.join(share, "GSVFS/vfs/users/guest/documents")
if os.path.exists(os.path.join(docs, "DRILL.TXT~")):
    sys.exit("DRILL.TXT~ residue survived recovery")
# The recovered-hash marker must carry the fixture's own digest.
want = hashlib.sha256(open(os.path.join(os.environ["RUN_DIR"], "drill.expected"), "rb").read()).hexdigest()
serial = open(os.environ["VG_SER"], errors="replace").read()
if "gsvfs: recovered sha256=%s" % want not in serial:
    sys.exit("recovered bytes hash %s not reported" % want)
print("recovery committed: new bytes live, temp gone")
PY
