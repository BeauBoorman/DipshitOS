# go-shell-polish.spec -- M98i (issue #2135) class-B acceptance gate: the
# whole M98 arc on VZ in one spec, one leg per card so a single regression
# names its card. Boot 01 rides serial GOSH end to end (cwd, glob, alias,
# history, dirstack, toolbox, jobs/Ctrl-C, contextual Tab, time CMD, the \?
# prompt); boot 02 rides the DEFAULT Go seat for the window-only legs (tab
# title follows cwd, Ctrl-X Ctrl-E through hosted GOEDIT). Legs that move
# the cwd restore it before the next leg.
#
# HOST PREREQUISITES (fail the gate honestly when missing): .build/go/
#   GOSH.ELF (tools/go/build-gosh.sh), GOEDIT.ELF (build-goedit.sh),
#   GOTABWM.ELF (build-gotabwm.sh).
# exec-order: assert-proven -- boot 01 ends on m98i-01-done, printed only by
# the post-interrupt burst; boot 02 ends on rx-polish-02-ok, gated on the
# post-GOEDIT submit marker.

vgate_name go-shell-polish "issue #2135 M98i: the M98 arc's acceptance journey -- every card's leg on VZ (serial GOSH + hosted seat)"
# Both share transports on the SAME dir in boot 01 only: the slot-79 paged
# listing that glob (M98a) and contextual completion (M98g) list through is
# virtiofs-only -- virtio_file.metadata_backend refuses the cv channel
# outright -- so boot 01 adds --virtio-fs on the armed share. Boot 02 stays
# pure cv like every seat spec: its legs need no directory listing, and the
# wm autostart's exec lookup races the FUSE session init when virtiofs is
# armed (observed: "GOTABWM.ELF not on the share" on an armed, seeded dir).
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

# Boot 01, phase 1 (monitor): prompt=[\?] so the M98h status escape is
# observable on every repaint, then hand the console to serial GOSH.
# The typed `\\` survives the kernel tokenizer's escape pass as a literal
# backslash, so the stored template really is [\?] (a bare `\?` is eaten).
vgate_file script-01a.txt <<'EOF'
settings set prompt [\\?]
exec GOSH.ELF serial
EOF

# Boot 02, phase 1 (monitor): the M57b blur handshake -- the default seat's
# startup probe must lose focus before the first-boot GOSH workspace opens
# (go-dogfood boot 01's shape).
vgate_file script-02a.txt <<'EOF'
dui focus 0
EOF

# Boot 02, phase 2 (monitor): release GOEDIT's hosted window after its own
# `goedit: present` (printed after the window exists and the first frame is
# up). The id is pinned by this boot's fixed allocation order -- 2/3 are the
# wm surface and the starter GOSH tab, 4 is the clock, GOEDIT takes 5. A
# clean buffer closes with no unsaved-changes dialog; EditLine then reads
# the file back and submits what it holds.
vgate_file script-02b.txt <<'EOF'
dui close 5
EOF

# Boot 02, phase 3 (monitor): end marker, gated on the edited line's submit.
vgate_file script-02c.txt <<'EOF'
echo rx-polish-02-ok
EOF

# M98e's tee payload, byte-equal on the host after the pipe runs.
vgate_file tee-expected.txt <<'EOF'
a
b
EOF

# The alias STARTUP.SH defines runs in both boots; it is the only startup
# line, so the typed choreography below owns history ordering.
vgate_file STARTUP.SH <<'EOF'
alias hi='echo alias-ok'
EOF

vgate_setup_python <<'PY'
import os, shutil, subprocess, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
# The staged GOSH must be the ELF this tree's source builds -- the card
# pins stamp verification through the issue-#1503 tool, fail closed.
rc = subprocess.run(["bash", "tools/go/ensure-guest-elf.sh", "check", "GOSH"]).returncode
if rc != 0:
    sys.exit("GOSH.ELF stamp check failed - rebuild: bash tools/go/build-gosh.sh")
for name, how in (("GOSH.ELF", "build-gosh.sh"),
                  ("GOEDIT.ELF", "build-goedit.sh"),
                  ("GOTABWM.ELF", "build-gotabwm.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + how)
    shutil.copy(src, os.path.join(share, name))
# Card fixtures: two glob targets plus a non-match for M98a, one directory
# with one inner file for M98j/d/g, and the STARTUP.SH alias for M98b.
for n in ("M98A1.TXT", "M98A2.TXT", "M98B.LOG"):
    with open(os.path.join(share, n), "w") as f:
        f.write(n + " body\n")
os.makedirs(os.path.join(share, "M98DIR"), exist_ok=True)
with open(os.path.join(share, "M98DIR", "INNER.TXT"), "w") as f:
    f.write("m98i-inner-payload\n")
shutil.copy(os.path.join(rd, "STARTUP.SH"), os.path.join(share, "STARTUP.SH"))
print("staged GOSH/GOEDIT/GOTABWM + M98 fixtures + STARTUP.SH")
PY

# Boot 01's typed legs, one burst gated on `gosh: attached` (the
# live-sh-complete pattern; the 1024-byte tty input queue holds it whole).
# The foreground COUNTER.BIN is LAST: it never returns, so nothing in this
# burst may follow it. script-01c carries the Ctrl-C byte, gated on the
# child's own `counter: alive` so the interrupt lands while it runs (the
# M98f spike lesson: a same-burst \x03 queues behind the child and never
# reaches the interrupter).
vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
seq = (b"cd M98DIR\r"
       b"cat INNER.TXT\r"
       b"cd ..\r"
       b"pwd\r"
       b"echo M98A*.TXT\r"
       b"echo 'M98A*.TXT'\r"
       b"hi\r"
       b"echo hist-one\r"
       b"!!\r"
       b"^one^two\r"
       b"pushd M98DIR\r"
       b"dirs\r"
       b"popd\r"
       b"cd -\r"
       b"cd /\r"
       b"printf 'a\\nb\\n' | tee /host/M98TEE.TXT\r"
       b"printf 'X1\\nX2\\n' | xargs echo\r"
       b"pus\tM98DIR\r"
       b"popd\r"
       b"cd M98\t\r"
       b"cd /\r"
       b"time echo t-ok\r"
       b"false\r"
       b"COUNTER.BIN &\r"
       b"jobs -l\r"
       b"kill %1\r"
       b"COUNTER.BIN\r")
with open(os.path.join(rd, "typed-01.bin"), "wb") as f:
    f.write(seq)
with open(os.path.join(rd, "typed-01c.bin"), "wb") as f:
    f.write(b"\x03echo rc=$?\r" b"echo m98i-01-done\r")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --virtio-fs '$RUN_DIR/share' \
    --script '$RUN_DIR/script-01a.txt' \
    --script2 '$RUN_DIR/typed-01.bin' --script2-after 'gosh: attached' \
    --script3 '$RUN_DIR/typed-01c.bin' --script3-after 'counter: alive' \
    --script-expect 'm98i-01-done' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'gosh: attached'
# M98j: real cwd -- cat INNER.TXT works only if `cd M98DIR` moved the share
# resolution root; `pwd` answers `/` after `cd ..`.
# M98a: glob expands against PWD; quoting keeps it literal.
# M98b: the STARTUP.SH alias expands at the head.
# M98c: !! replays, ^one^two substitutes -- each expansion's marker shows the
# EXPANDED line, so `gosh: line echo hist-one` prints twice and the
# substituted line runs.
# M98d: pushd/dirs/popd/cd -.
# M98e: tee's file is host-side byte-equal (asserted separately below);
# xargs glues its chunks into `X1 X2`.
# M98f: kill %1 on the background counter, then Ctrl-C on a foreground one.
# M98g: `pus<Tab>` -> `pushd`, `cd M98<Tab>` -> `cd M98DIR/` (dirs only,
# trailing /) -- the submitted-line markers prove what ran.
# M98h: `time echo t-ok` prints `real ` on the terminal; after `false` the
# [\?] prompt paints `[1]`.
# All output legs anchor at line start: a bare substring could be satisfied
# by the echo of the typed line itself (go-sh's lesson).
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()

def find(pat, start=0):
    m = re.search(pat, ser[start:], re.M)
    return None if m is None else start + m.start()

pos = 0
missing = []
def need(pat, what):
    global pos
    i = find(pat, pos)
    if i is None:
        missing.append("missing %s (pattern %r, after byte %d)" % (what, pat, pos))
    else:
        pos = i

need(r'^gosh: line cd M98DIR\b', "M98j leg: cd M98DIR")
need(r'^m98i-inner-payload', "M98j leg: cat INNER.TXT output")
need(r'^gosh: line pwd\b', "M98j leg: pwd")
need(r'^/$', "M98j leg: pwd output /")
need(r'^M98A1\.TXT M98A2\.TXT', "M98a leg: glob expansion")
need(r'^M98A\*\.TXT', "M98a leg: quoted glob stays literal")
need(r'^alias-ok', "M98b leg: alias output")
h1 = len(re.findall(r'(?m)^gosh: line echo hist-one', ser))
if h1 != 2:
    missing.append("M98c leg: 'gosh: line echo hist-one' x%d, want 2 (!! replay)" % h1)
need(r'^gosh: line echo hist-two', "M98c leg: ^one^two substitution")
need(r'^/M98DIR /', "M98d leg: dirs shows /M98DIR /")
need(r'^gosh: line cd -$', "M98d leg: cd -")
need(r'^/M98DIR$', "M98d leg: cd - prints /M98DIR")
need(r'^X1 X2', "M98e leg: xargs output")
need(r'^gosh: line pushd M98DIR\b', "M98g leg: pus<Tab> -> pushd")
need(r'^gosh: line cd M98DIR/', "M98g leg: cd M98<Tab> -> M98DIR/ (dirs only)")
need(r'^t-ok', "M98h leg: timed command output")
need(r'^real ', "M98h leg: time CMD report")
need(r'^gosh: line false', "M98h leg: false")
# `[1] ` must paint INSIDE the window between the `false` submit marker and
# the `COUNTER.BIN &` submit marker -- only the [\?] prompt repaint lands
# there. A bare forward search is satisfied by the later jobs banner
# `[1] running:` on a binary with no \? escape (observed false-passing).
i_counter = find(r'^gosh: line COUNTER\.BIN &', pos)
if i_counter is None:
    missing.append("missing M98f leg: COUNTER.BIN & submitted (pattern '^gosh: line COUNTER\\.BIN &', after byte %d)" % pos)
    missing.append("missing M98h leg: \\? prompt paints [1] after failure (window unbounded)")
else:
    if re.search(r'^\[1\] ', ser[pos:i_counter], re.M) is None:
        missing.append("missing M98h leg: \\? prompt paints [1] after failure (window [%d:%d])" % (pos, i_counter))
    pos = i_counter
need(r'^rc=130', "M98f leg: foreground COUNTER.BIN -> Ctrl-C -> rc=130")
need(r'^m98i-01-done', "boot 01 end marker")
if missing:
    for m in missing:
        print(m)
    sys.exit("go-shell-polish 01: %d leg(s) missing" % len(missing))
print("go-shell-polish 01: all ordered leg markers present")
PY

vgate_assert 01 serial-contains 'gosh: job 1 done exit=137'
vgate_assert 01 serial-contains 'gosh: interrupt pid='
vgate_assert 01 share-equals M98TEE.TXT tee-expected.txt
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'fatal error: runtime:'

# --- boot 02: the DEFAULT Go seat (title sync + Ctrl-X Ctrl-E) -------------
# Same share (fresh boot on it). No SETTINGS.TXT `wm` row is staged: the
# compiled default seats GOTABWM.ELF, and with no SESSION.TABS the first-boot
# path opens a starter GOSH tab -- the card's seat journey needs no monitor
# exec for either. Boot 01's `settings set prompt` persisted prompt=[\?] into
# SETTINGS.TXT, so the hosted GOSH prompts `[0]`-style too -- harmless here.
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --via-virtio \
    --script '$RUN_DIR/script-02a.txt' \
    --script-after 'gotabwm: win focus' \
    --input-chords 'c,d,space,M,9,8,D,I,R,return,c,d,space,.,/,M,9,8,D,I,R,ctrl-x,ctrl-e' \
    --input-chords-after 'gosh: prompt' \
    --script2 '$RUN_DIR/script-02b.txt' \
    --script2-after 'goedit: present' \
    --script3 '$RUN_DIR/script-02c.txt' \
    --script3-after 'gosh: line cd ./M98DIR' \
    --script-expect 'rx-polish-02-ok' --timeout 300

vgate_assert 02 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 02 serial-contains 'gosh: attached'
vgate_assert 02 serial-contains 'goedit: present'
vgate_assert 02 serial-contains 'goedit: close'
# Title sync: `cd M98DIR` retitles the hosted GOSH tab (id 3 in this boot's
# fixed allocation order) to `Sh — M98DIR` -- the wm_rpc wire text, em dash
# included. Flat, not ordered: the retitle rides the next repaint, which
# lands wherever GOEDIT's focus steal left it.
vgate_assert 02 serial-contains 'gotabwm: title id=3 Sh — M98DIR'
# The edited line is `cd ./M98DIR` -- typed into the buffer, carried through
# the GOEDIT temp file, submitted on close. Command output rides the tab
# pane, not serial, and the cwd is unchanged so no title re-sync fires --
# the host-side observable is the line landing in GOSH-HISTORY.TXT, which
# only SaveHistory inside the real submit path can write. The spelling is
# unique to boot 02 (boot 01 types `cd M98DIR` and `cd /`), so the share
# assert is this boot's own proof.
vgate_assert 02 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()

def find(pat, start=0):
    m = re.search(pat, ser[start:], re.M)
    return None if m is None else start + m.start()

pos = 0
missing = []
def need(pat, what):
    global pos
    i = find(pat, pos)
    if i is None:
        missing.append("missing %s (pattern %r, after byte %d)" % (what, pat, pos))
    else:
        pos = i

need(r'^gosh: line cd M98DIR', "boot 02 leg: cd M98DIR")
need(r'^goedit: open id=', "M98h leg: GOEDIT exec'd by Ctrl-X Ctrl-E")
need(r'^goedit: present', "M98h leg: GOEDIT first frame")
need(r'^dui close: closed=5', "M98h leg: GOEDIT tab released")
need(r'^goedit: close', "M98h leg: GOEDIT observed WIN_CLOSE")
need(r'^gosh: line cd \./M98DIR$', "M98h leg: edited line submitted")
need(r'^rx-polish-02-ok', "boot 02 end marker")
if missing:
    for m in missing:
        print(m)
    sys.exit("go-shell-polish 02: %d leg(s) missing" % len(missing))
print("go-shell-polish 02: title sync + Ctrl-X Ctrl-E round trip")
PY
vgate_assert 02 share-contains GOSH-HISTORY.TXT 'cd ./M98DIR'

# Between-run cleanup (the go-dogfood tag-03 idiom): the seat's close writes
# SESSION.TABS to the shared share, so a repeat iteration's boot 02 would
# RESTORE the previous strip (placeholder tabs, no live GOSH) instead of
# reaching the first-boot starter tab -- observed on 02-02: `session load
# n=1 mode=restore`, no `gosh: attached`, chords never typed. Asserts run
# after the run and before the next (vgate.sh's run/assert loop), and the
# setup hooks all ran before run 01, so the delete has to live here.
# GOSH-HISTORY.TXT goes too: boot 01 appends to it every iteration, and a
# stale `cd ./M98DIR` line would keep share-contains green after a boot 02
# that never reached its submit. Missing files are fine -- a boot 02 that
# died before the seat wrote is a legitimate cleanup outcome.
vgate_assert 02 python <<'PY'
import os
share = os.environ.get("VG_SHARE", "")
removed = []
for rel in ("SESSION.TABS", "GOSH-HISTORY.TXT"):
    p = os.path.join(share, rel)
    if os.path.exists(p):
        os.remove(p)
        removed.append(rel)
print("between-run cleanup: removed %s" % (", ".join(removed) if removed else "nothing"))
PY

vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'fatal error: runtime:'
