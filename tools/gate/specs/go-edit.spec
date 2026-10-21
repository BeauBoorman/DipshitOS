# go-edit.spec -- M58b (issue #1306) class-B gate: a Go editor opens a share
# file, edits the buffer, saves it, and closes, full-viewport inside Zig TABWM.
#
# user/go/edit is a tabapp client: init -> declare (kind-8 WM_RPC) -> read the
# seeded /host/EDIT/SEED.TXT -> accept injected keystrokes into the buffer
# (Win_DOWN arg1 is the Unicode codepoint) -> Ctrl-S writes the buffer back ->
# WIN_CLOSE exits. Zig EDIT.BIN is gone (M60 / #1297) and so is the Zig notepad
# (M66c / #1485); this gate pins the Go editor that replaced EDIT.BIN. Kernel untouched.
#
# The load-bearing evidence is NOT only the app's own markers: the run's last
# assert reads the share file back ON THE HOST and requires it to equal the
# seed plus the typed characters, so a save that reported success without
# writing the bytes cannot pass.
#
# M81d (#1764) adds the advisory write lease. Run 01 takes the lease, saves
# under it, and releases it at close. Run 02 is the SECOND WRITER: a foreign
# live record (stamped so no run outlives it) is on the path, the open-time
# acquire refuses with `lease held rc=-11`, Ctrl-S refuses with the
# save-error line carrying -11, and the host assert proves the bytes were
# NOT written. Run 03 is the takeover: a foreign STALE record (ts=1) is
# taken over at the open-time acquire, the save lands, and the record reads
# back as GOEDIT's own (pid= present, the foreign token gone). Runs 02/03
# drive /host/EDIT/LEASE.TXT (its own seed) so run 01's saved bytes are
# never on their paths; `--lease-fixture=` is the app's named fixture verb
# (the GOSELF --panic-receipt-fixture precedent).
#
# #2199 (second pass) adds runs 05-08, one leg per landed feature:
#   05 undo/redo + status line -- a typed run, a newline, another run and a
#      backspace are undone three deep and redone once; `goedit: undo n=` /
#      `redo n=` count the stacks, `goedit: status line=L/T col=C [*]` tracks
#      each landing, and the saved bytes are the post-undo buffer exactly.
#   06 selection + clipboard, CAP_CLIPBOARD path -- `exec -u0`, the monitor's
#      `clip` preloads the shared buffer, paste splices it, ctrl-a selects
#      all (sel=8 in the status line), ctrl-shift-m + arrows extend a mark
#      selection (the runner cannot spell shift+arrow -- mark mode is the
#      same anchor+caret rule), ctrl-x cuts it and a second `clip` reads the
#      cut text back through the kernel buffer an app cannot fake.
#   07 the M97g-F4 (#2082) refusal leg -- a plain `exec` GOEDIT gets -EACCES
#      from slots 38/39; the markers carry rc=-7 and the share stays clean.
#   08 replace -- Ctrl-R's two-field bar: Return replaces the match find
#      lands on (hit=N/M), a find after it reports the remaining total, and
#      Ctrl-A replaces all in one op whose n= equals that total.
#   M138b (#2776) adds run 13: bracket matching — caret on `{`, the `}`
#      match under-painted teal (pixel probe on the captured frame), and
#      Ctrl-B jumping caret->match->caret->`match none` on a non-bracket.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goedit.sh   ->  .build/go/GOEDIT.ELF
#
# exec-order: assert-proven -- the runs end on `rx-goedit-*`, which only the
# scripts print, and the stage gates that forward the close wait on the app's
# own markers; a program that never ran cannot pass.

vgate_name go-edit "issue #1306 M58b: a Go editor opens, edits and saves a share file in Zig TABWM on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/SEED.TXT
EOF

# The close is driven from the harness after the app's own `goedit: saved `
# (the stage gate), so the bytes are on the share before the window closes.
vgate_file script3.txt <<'EOF'
dui close 2
echo rx-goedit-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOEDIT.ELF")
if not os.path.exists(src):
    sys.exit("GOEDIT.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goedit.sh")
shutil.copy(src, os.path.join(share, "GOEDIT.ELF"))
ed = os.path.join(share, "EDIT")
os.makedirs(ed, exist_ok=True)
seed = os.path.join(ed, "SEED.TXT")
with open(seed, "wb") as f:
    f.write(b"seed-line\n")
# M81d runs 02/03: the lease drill's own target, seeded separately so run
# 01's saved SEED.TXT bytes are never on its path.
lease_seed = os.path.join(ed, "LEASE.TXT")
with open(lease_seed, "wb") as f:
    f.write(b"lease-seed\n")
# #2199: the second-pass runs' own targets — an undo/redo drill, a clipboard
# drill, and a three-match replace document, each seeded so the saved-bytes
# assert is an exact host-side compare. M138b adds the bracket-match
# drill's one-liner: `{` at offset 0, its `}` at offset 7.
for name, body in [("UNDO.TXT", b"ab\n"), ("CLIP.TXT", b"clipthis"),
                   ("REPL.TXT", b"one two one\ntwo one\n"),
                   ("BKT.TXT", b"{abcdef}")]:
    with open(os.path.join(ed, name), "wb") as f:
        f.write(body)
print("staged GOEDIT.ELF into share (%d bytes) and %s (%d bytes)" %
      (os.path.getsize(os.path.join(share, "GOEDIT.ELF")),
       seed, os.path.getsize(seed)))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'X,Y,Z,ctrl-s' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'goedit: saved ' \
    --script-expect 'rx-goedit-ok' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 01 serial-contains 'goedit: open id='
vgate_assert 01 serial-contains 'goedit: declare accepted'
# The seeded fixture was read (10 bytes: "seed-line\n").
vgate_assert 01 serial-contains 'goedit: read /host/EDIT/SEED.TXT n=10'
# The first frame is on the scanout (this is also the chord-release stage).
vgate_assert 01 serial-contains 'goedit: present'
# The injected keystrokes reached the buffer.
vgate_assert 01 serial-contains 'goedit: dirty'
# Ctrl-S wrote the buffer back (13 bytes: the seed plus the three typed chars).
vgate_assert 01 serial-contains 'goedit: saved /host/EDIT/SEED.TXT n=13'
# M81d: the session lease was taken at open (the marker names the holder pid)
# and released at close — the release line with no rc suffix.
vgate_assert 01 serial-contains 'goedit: lease acquired pid='
vgate_assert 01 serial-contains 'goedit: lease released'
vgate_assert 01 serial-contains 'goedit: close'
vgate_assert 01 serial-contains 'goedit OK'
vgate_assert 01 serial-contains 'rx-goedit-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The load-bearing assert: the share file on the HOST must now hold exactly the
# seed plus the typed characters. A save that reported success without writing
# the bytes cannot pass this.
vgate_assert 01 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "EDIT", "SEED.TXT")
want = b"seed-line\nXYZ"
got = open(path, "rb").read()
if got != want:
    print("SAVED CONTENT MISMATCH: got %r want %r" % (got, want))
    raise SystemExit(1)
print("saved content verified on the host: %r (%d bytes)" % (got, len(got)))
PY

# --- M81d (#1764) run 02: the second writer is refused ----------------------
# The fixture verb stamps a foreign LIVE record (ts=9999999999: no boot outlives
# it, so the run has no timing edge) on /host/EDIT/LEASE.TXT before the editor's
# own acquire. The open-time acquire refuses (`lease held rc=-11`), the typed
# Ctrl-S refuses with the save-error line carrying -11, and the host assert
# proves the typed bytes never reached the share — the silent-loss shape the
# lease exists to make visible.
vgate_file script2-02.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/LEASE.TXT --lease-fixture=live
EOF

vgate_file script3-02.txt <<'EOF'
dui close 2
echo rx-goedit-lease-ok
EOF

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'A,B,ctrl-s' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after 'goedit: save error ' \
    --script-expect 'rx-goedit-lease-ok' --timeout 240

vgate_assert 02 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 02 serial-contains 'goedit: lease fixture live'
# The open-time acquire read the foreign record and refused it.
vgate_assert 02 serial-contains 'goedit: read /host/EDIT/LEASE.TXT n=11'
vgate_assert 02 serial-contains 'goedit: lease held rc=-11'
# The typed keystrokes still reach the buffer — only the PUBLISH is refused.
vgate_assert 02 serial-contains 'goedit: dirty'
vgate_assert 02 serial-contains 'goedit: save error /host/EDIT/LEASE.TXT -11'
# The refused save must NOT have produced a save marker anywhere.
vgate_assert 02 serial-absent 'goedit: saved '
vgate_assert 02 serial-contains 'goedit: close'
vgate_assert 02 serial-contains 'rx-goedit-lease-ok'
vgate_assert 02 serial-absent '[EXC] parking:'

# The refused save must leave the foreign record standing — and its place
# and bytes are the host↔guest cross-check of the record NAME contract: the
# python re-implements fnv1a64 (big-endian 16 hex digits, the leaseHash rule)
# and requires the exact fixture text at that path. If the guest hashed to a
# different name or wrote a different shape, this fails.
vgate_assert 02 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "EDIT", "LEASE.TXT")
want = b"lease-seed\n"
got = open(path, "rb").read()
if got != want:
    print("REFUSED SAVE WROTE THE FILE: got %r want %r" % (got, want))
    raise SystemExit(1)
print("refused save verified on the host: file untouched (%d bytes)" % len(got))

def fnv1a64(data: bytes) -> int:
    h = 0xcbf29ce484222325
    for b in data:
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h

target = "/host/EDIT/LEASE.TXT"
lp = os.path.join(share, "LEASES", "%016x" % fnv1a64(target.encode()))
want_rec = ("VLEASE1\npid=0\nts=9999999999\ntoken=fedcba9876543210\npath=%s\n" % target).encode()
got_rec = open(lp, "rb").read()
if got_rec != want_rec:
    print("LEASE RECORD MISMATCH at %s: got %r want %r" % (lp, got_rec, want_rec))
    raise SystemExit(1)
print("foreign live record verified at the contract path: %s" % lp)
PY

# --- M81d (#1764) run 03: a stale lease is taken over -----------------------
# The fixture stamps a foreign STALE record (ts=1: expired by any clock). The
# open-time acquire takes the lease over (`lease acquired`), the save lands,
# and the record reads back as GOEDIT's own: pid=<n> present, the foreign
# token gone — proof the takeover rewrote it, not merely ignored it.
vgate_file script2-03.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/LEASE.TXT --lease-fixture=stale
EOF

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-03.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'X,Y,Z,ctrl-s' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'goedit: saved ' \
    --script-expect 'rx-goedit-ok' --timeout 240

vgate_assert 03 serial-contains 'goedit: lease fixture stale'
# The stale record was taken over at the open-time acquire, and the marker
# names the holder pid the record now carries (run 01 pins the same shape).
vgate_assert 03 serial-contains 'goedit: read /host/EDIT/LEASE.TXT n=11'
vgate_assert 03 serial-contains 'goedit: lease acquired pid='
vgate_assert 03 serial-contains 'goedit: saved /host/EDIT/LEASE.TXT n=14'
# The close released the lease: the success line has NO rc suffix (a release
# that refused to delete a foreign record would carry one).
vgate_assert 03 serial-contains 'goedit: lease released'
vgate_assert 03 serial-absent 'goedit: lease released rc='
vgate_assert 03 serial-contains 'rx-goedit-ok'
vgate_assert 03 serial-absent '[EXC] parking:'

# The load-bearing asserts: the save landed on the share, and the release is
# itself the ownership receipt — Release refuses to delete a record whose
# token is not ours, so a deleted record is one the takeover made ours. The
# python proves the record is GONE at the contract path (fnv1a64 recomputed
# host-side, the same rule run 02 cross-checks against the fixture text).
vgate_assert 03 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "EDIT", "LEASE.TXT")
want = b"lease-seed\nXYZ"
got = open(path, "rb").read()
if got != want:
    print("TAKEN-OVER SAVE MISMATCH: got %r want %r" % (got, want))
    raise SystemExit(1)
print("taken-over save verified on the host: %r (%d bytes)" % (got, len(got)))

def fnv1a64(data: bytes) -> int:
    h = 0xcbf29ce484222325
    for b in data:
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h

target = "/host/EDIT/LEASE.TXT"
lp = os.path.join(share, "LEASES", "%016x" % fnv1a64(target.encode()))
if os.path.exists(lp):
    print("LEASE RECORD SURVIVED THE RELEASE: %r" % open(lp, "rb").read())
    raise SystemExit(1)
print("lease record released at the contract path: %s" % lp)
PY

# M94d: opt-in publisher only. Original boots and default argv are unchanged.
vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(".build", "go", "HEAP.ELF")
if not os.path.exists(src):
    sys.exit("HEAP.ELF missing: bash tools/go/build-heap.sh")
shutil.copy(src, os.path.join(share, "HEAP.ELF"))
with open(os.path.join(share, "EDIT", "HEAP.TXT"), "wb") as f:
    f.write(b"heap-seed\n")
PY

vgate_file script2-heap.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/HEAP.TXT -heap
EOF
vgate_file script3-heap.txt <<'EOF'
exec HEAP.ELF -p GOEDIT.ELF --polls 120 --samples 5
EOF

vgate_run 04 -- \
    --screen '$RUN_DIR/screen-heap' --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-heap.txt' --script2-after 'tabwm: sidebar-rendered' \
    --script3 '$RUN_DIR/script3-heap.txt' --script3-after 'goedit: present' \
    --input-chords 'A,ctrl-s,B,ctrl-s,C,ctrl-s,D,ctrl-s,E,ctrl-s' \
    --input-chords-after 'heap: sample app=GOEDIT.ELF' \
    --script-expect 'heap: done app=GOEDIT.ELF' --timeout 180

vgate_assert 04 serial-contains 'heap: memstats ok'
vgate_assert 04 serial-contains 'heap: sample app=GOEDIT.ELF'
vgate_assert 04 serial-contains 'heap: done app=GOEDIT.ELF'
vgate_assert 04 serial-count 'goedit: saved /host/EDIT/HEAP.TXT' 5
vgate_assert 04 serial-absent 'heap: leak suspected'
vgate_assert 04 serial-absent 'heap: publisher error'
vgate_assert 04 serial-absent 'fatal error:'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 share-contains 'EDIT/HEAP.TXT' 'ABCDE'
vgate_assert 04 share-contains 'HEAP/GOEDIT.ELF.TXT' 'H1 '

vgate_assert 04 python <<'PY'
import math, os, re, shutil, statistics
ser = open(os.environ["VG_SER"], errors="replace").read()
assert open(os.path.join(os.environ["VG_SHARE"], "EDIT", "HEAP.TXT"), "rb").read() == b"heap-seed\nABCDE"
samples = list(re.finditer(
    r"heap: sample app=GOEDIT\.ELF pid=(\d+) seq=(\d+) live=(\d+) "
    r"objects=(\d+) mallocs=(\d+) frees=(\d+) num_gc=(\d+) pages=(\d+) peak_pages=(\d+)", ser))
assert len(samples) >= 5, "need at least N+2 joined post-GC samples"
saves = list(re.finditer(r"goedit: saved /host/EDIT/HEAP\.TXT n=(\d+)", ser))
assert [int(m[1]) for m in saves] == [11, 12, 13, 14, 15], "five exact edit/save cycles"
assert samples[0].start() < saves[0].start(), "no pre-edit joined sample"
after = [m for m in samples if m.start() > saves[-1].start()]
assert after and int(samples[0][3]) > 0 and any(m[3] != samples[0][3] for m in after), "live bytes unchanged after editing"
for m in samples:
    pid, seq, live, objects, mallocs, frees, gc, pages, peak = map(int, m.groups())
    assert objects == mallocs-frees and gc > 0 and 0 < live
    assert 0 <= pages <= peak <= 4096, (pages, peak)
print("GOEDIT post-GC series:", [(int(m[2]), int(m[3]), int(m[8])) for m in samples])
frequency = int(re.search(r"freq=0x([0-9a-f]+)", ser)[1], 16)
counters = [int(n) for n in re.findall(r"cntpct=(\d+) snapshot_ns=", ser)]
assert frequency > 0 and counters and all(b-a >= frequency for a, b in zip(counters, counters[1:]))
costs = [int(n) for n in re.findall(r"snapshot_ns=(\d+)", ser)]
assert costs and all(cost > 0 for cost in costs), costs
mean = statistics.mean(costs)
p95 = sorted(costs)[math.ceil(len(costs)*0.95)-1]
# Editing/forced GC is not the >=100-poll quiet acceptance window.
# Keep every timing visible; go-stress boot 06 enforces mean/p95 <= 100 us.
publishes = [tuple(map(int, row)) for row in re.findall(r"gc_ns=(\d+) publish_ns=(\d+)", ser)]
assert publishes and all(0 < gc <= total for gc, total in publishes)
print("GOEDIT snapshot/GC/publish ns:", costs, publishes, "counter Hz:", frequency,
      "mean:", mean, "p95:", p95, "max:", max(costs))
source = os.path.join(os.environ["VG_SHARE"], "HEAP", "GOEDIT.ELF.TXT")
rows = open(source).read().splitlines()
assert 5 <= len(rows) <= 32 and all(len(row) <= 256 for row in rows)
shutil.copy(source, os.path.join("artifacts", "m94d-goedit-series-" + os.environ["VG_TAG"] + ".txt"))
PY

# --- #2199 run 05: bounded undo/redo + the status line --------------------
# On "ab\n" (caret at end): a leading ctrl-z proves the empty-stack marker,
# then X, Return, Y build three ops (the newline breaks the typing run) and
# backspace a fourth. Three undos pop the delete, the Y and the newline in
# newest-first order; one ctrl-shift-z re-applies the newline. The saved
# file is exactly the post-redo buffer "ab\nX\n" — the ops, the markers and
# the bytes must all agree.
vgate_file script2-05.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/UNDO.TXT
EOF

vgate_file script3-05.txt <<'EOF'
dui close 2
echo rx-goedit-undo-ok
EOF

vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-05.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'ctrl-z,X,return,Y,backspace,ctrl-z,ctrl-z,ctrl-z,ctrl-shift-z,ctrl-s' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3-05.txt' \
    --script3-after 'goedit: saved ' \
    --script-expect 'rx-goedit-undo-ok' --timeout 240

vgate_assert 05 serial-contains 'goedit: read /host/EDIT/UNDO.TXT n=3'
# Empty stack, then three reverted ops newest-first, then one redo.
vgate_assert 05 serial-contains 'goedit: undo none'
vgate_assert 05 serial-count 'goedit: undo n=' 3
vgate_assert 05 serial-contains 'goedit: redo n='
# The status line tracks the caret on every landing: the open frame, the
# typed X, the newline's line 3, and the post-save clean flag (no *).
vgate_assert 05 serial-contains 'goedit: status line=2/2 col=1'
vgate_assert 05 serial-contains 'goedit: status line=2/2 col=2 *'
vgate_assert 05 serial-contains 'goedit: status line=3/3 col=1 *'
# The post-redo buffer is "ab\nX\n" — five bytes.
vgate_assert 05 serial-contains 'goedit: saved /host/EDIT/UNDO.TXT n=5'
vgate_assert 05 serial-contains 'rx-goedit-undo-ok'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'

vgate_assert 05 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "EDIT", "UNDO.TXT")
want = b"ab\nX\n"
got = open(path, "rb").read()
if got != want:
    print("UNDO/REDO SAVE MISMATCH: got %r want %r" % (got, want))
    raise SystemExit(1)
print("post-undo buffer verified on the host: %r (%d bytes)" % (got, len(got)))
PY

# --- #2199 run 06: selection + the shared clipboard (CAP_CLIPBOARD) -------
# `exec -u0` is the M97g-F4 capable path (the live-m14-composition
# precedent); the monitor's `clip` preloads "gateext" so the paste reads
# bytes an app cannot fake. The drill: paste it, undo back to the seed,
# ctrl-a selects all (sel=8) and copies, then a ctrl-shift-m mark plus three
# rights selects "cli" — shift+arrow is not a runner token, so the mark is
# the same anchor+caret rule driven by a chord the gate can spell — ctrl-x
# cuts it, ctrl-v puts it back, and the harness-side `clip` prints the cut
# text from the KERNEL buffer after the save.
vgate_file script2-06.txt <<'EOF'
clip gateext
exec -u0 GOEDIT.ELF /host/EDIT/CLIP.TXT
EOF

vgate_file script3-06.txt <<'EOF'
clip
dui close 2
echo rx-goedit-clip-ok
EOF

vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-06.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'ctrl-v,ctrl-z,ctrl-a,ctrl-c,home,ctrl-shift-m,right,right,right,ctrl-x,ctrl-v,ctrl-s' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3-06.txt' \
    --script3-after 'goedit: saved ' \
    --script-expect 'rx-goedit-clip-ok' --timeout 240

vgate_assert 06 serial-contains 'goedit: read /host/EDIT/CLIP.TXT n=8'
# The kernel buffer held the preloaded bytes before the app ever ran.
vgate_assert 06 serial-contains 'clip: stored 7 bytes'
vgate_assert 06 serial-contains 'goedit: paste n=7'
# The paste is one op — one undo restores the seed (n=0 ops left, caret 8).
vgate_assert 06 serial-contains 'goedit: undo n=0 cur=8'
vgate_assert 06 serial-contains 'goedit: copy n=8'
vgate_assert 06 serial-contains 'goedit: mark set'
vgate_assert 06 serial-contains 'goedit: cut n=3'
vgate_assert 06 serial-contains 'goedit: paste n=3'
# sel=N is in the status line while the mark selection is live.
vgate_assert 06 serial-contains 'goedit: status line=1/1 col=9 sel=8 *'
vgate_assert 06 serial-contains 'goedit: status line=1/1 col=4 sel=3 *'
vgate_assert 06 serial-contains 'goedit: saved /host/EDIT/CLIP.TXT n=8'
# The external read: the kernel clipboard holds exactly the cut text. Line-
# anchored because 'clip: cli' is a substring of 'clip: clipthis' — a serial-
# contains could be satisfied by the copy that ran earlier in the drill.
vgate_assert 06 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
assert re.search(r"(?m)^clip: cli\n", ser), "kernel clipboard must read back exactly 'cli'"
print("clipboard read-back verified: 'clip: cli'")
PY
vgate_assert 06 serial-contains 'rx-goedit-clip-ok'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'

vgate_assert 06 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "EDIT", "CLIP.TXT")
want = b"clipthis"
got = open(path, "rb").read()
if got != want:
    print("CLIP DRILL SAVE MISMATCH: got %r want %r" % (got, want))
    raise SystemExit(1)
print("cut/paste round-trip verified on the host: %r (%d bytes)" % (got, len(got)))
PY

# --- #2199 run 07: the M97g-F4 refusal leg ---------------------------------
# A plain `exec` GOEDIT has no CAP_CLIPBOARD: slots 38/39 answer -EACCES and
# the markers carry rc=-7 — the policy boundary is the receipt, and the cut
# must NOT have removed the bytes (serial-absent n=, file untouched: the run
# closes a clean buffer, no save marker anywhere). `clip sentinel` preloads
# the shared buffer so a refused paste cannot be mistaken for an empty one.
vgate_file script2-07.txt <<'EOF'
clip sentinel
exec GOEDIT.ELF /host/EDIT/CLIP.TXT
EOF

vgate_file script3-07.txt <<'EOF'
dui close 2
echo rx-goedit-refuse-ok
EOF

# The expect is the app's own `goedit: close`, not the script's echo: the
# WM's close dispatch to a running app is asynchronous (observed ~1 s of
# serial between `dui close: closed=2` and the marker on healthy legs), so
# an expect on rx-goedit-refuse-ok tears the VM down ~1.5 s after the echo
# and the close marker can lose that race — the leg then fails on an
# assert the code satisfied. Waiting on the marker itself bounds the wait
# by the run timeout instead of by delivery latency.
vgate_run 07 -- \
    --screen '$RUN_DIR/screen-07' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-07.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'ctrl-a,ctrl-x,ctrl-v' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3-07.txt' \
    --script3-after 'goedit: paste rc=' \
    --script-expect 'goedit: close' --timeout 240

vgate_assert 07 serial-contains 'clip: stored 8 bytes'
vgate_assert 07 serial-contains 'goedit: cut rc=-7'
vgate_assert 07 serial-contains 'goedit: paste rc=-7'
# No clipboard op may have reported a byte count or a save.
vgate_assert 07 serial-absent 'goedit: cut n='
vgate_assert 07 serial-absent 'goedit: paste n='
vgate_assert 07 serial-absent 'goedit: saved '
vgate_assert 07 serial-contains 'goedit: close'
vgate_assert 07 serial-contains 'rx-goedit-refuse-ok'
vgate_assert 07 serial-absent '[EXC] parking:'

# --- #2199 run 08: replace-current and replace-all ------------------------
# On "one two one\ntwo one\n" ('one' x3): Ctrl-R opens the two-field bar,
# `one`, Tab, `X`, Return replaces the match find would land on — hit=1/3 —
# a find then reports the remaining total (1/2), and a second bar's Ctrl-A
# replaces every match in one op whose n= equals that total. The saved file
# is the host-side proof: "X two X\ntwo X\n" (14 bytes).
vgate_file script2-08.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/REPL.TXT
EOF

vgate_file script3-08.txt <<'EOF'
dui close 2
echo rx-goedit-repl-ok
EOF

vgate_run 08 -- \
    --screen '$RUN_DIR/screen-08' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-08.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'ctrl-r,o,n,e,tab,X,return,ctrl-f,o,n,e,return,ctrl-r,o,n,e,tab,X,ctrl-a,ctrl-s' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3-08.txt' \
    --script3-after 'goedit: saved ' \
    --script-expect 'rx-goedit-repl-ok' --timeout 240

vgate_assert 08 serial-contains 'goedit: read /host/EDIT/REPL.TXT n=20'
vgate_assert 08 serial-contains "goedit: replace 'one' -> 'X' hit=1/3"
# find's remaining total after the first replacement is 2 — the number
# replace-all then reports, so N and M are the same scan.
vgate_assert 08 serial-contains "goedit: find 'one' hit=1/2"
vgate_assert 08 serial-contains "goedit: replace-all 'one' -> 'X' n=2"
vgate_assert 08 serial-contains 'goedit: saved /host/EDIT/REPL.TXT n=14'
vgate_assert 08 serial-contains 'rx-goedit-repl-ok'
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 serial-absent 'exited status=139'

vgate_assert 08 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "EDIT", "REPL.TXT")
want = b"X two X\ntwo X\n"
got = open(path, "rb").read()
if got != want:
    print("REPLACE SAVE MISMATCH: got %r want %r" % (got, want))
    raise SystemExit(1)
print("replace-all result verified on the host: %r (%d bytes)" % (got, len(got)))
PY

# M124b (#2581) adds run 09: the shared appkit.FilePicker's open and save-as
# legs. Ctrl-O raises the modal (clean buffer, so no discard confirm); a
# typed name resolves against the current dir and picks PICK2.TXT
# (`goedit: pick open` + the read marker). Ctrl-Shift-S then raises the
# save-as face seeded with the open file's basename — nine backspaces clear
# it, a fresh name goes in, and `goedit: pick save` + the saved marker land.
# The host assert compares PICKSAVE.TXT's bytes to the PICK2.TXT seed
# exactly: a save that did not write the loaded buffer cannot pass.
vgate_setup_python <<'PY'
import os
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
ed = os.path.join(share, "EDIT")
os.makedirs(ed, exist_ok=True)
with open(os.path.join(ed, "PICK.TXT"), "wb") as f:
    f.write(b"pick-me!\n")
with open(os.path.join(ed, "PICK2.TXT"), "wb") as f:
    f.write(b"pick-two\n")
PY

vgate_file script2-09.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/PICK.TXT
EOF

vgate_file script3-09.txt <<'EOF'
dui close 2
echo rx-goedit-pick-ok
EOF

vgate_run 09 -- \
    --screen '$RUN_DIR/screen-09' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-09.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'ctrl-o,P,I,C,K,2,.,T,X,T,return,ctrl-shift-s,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,P,I,C,K,S,A,V,E,.,T,X,T,return' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3-09.txt' \
    --script3-after 'goedit: saved /host/EDIT/PICKSAVE.TXT' \
    --script-expect 'rx-goedit-pick-ok' --timeout 240

vgate_assert 09 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 09 serial-contains 'goedit: read /host/EDIT/PICK.TXT n=9'
vgate_assert 09 serial-contains 'goedit: present'
vgate_assert 09 serial-contains 'goedit: pick open /host/EDIT/PICK2.TXT'
vgate_assert 09 serial-contains 'goedit: read /host/EDIT/PICK2.TXT n=9'
vgate_assert 09 serial-contains 'goedit: pick save /host/EDIT/PICKSAVE.TXT'
vgate_assert 09 serial-contains 'goedit: saved /host/EDIT/PICKSAVE.TXT n=9'
vgate_assert 09 serial-contains 'rx-goedit-pick-ok'
vgate_assert 09 serial-absent 'goedit: pick cancel'
vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 serial-absent 'exited status=139'

vgate_assert 09 python <<'PY'
import os
share = os.environ["VG_SHARE"]
got = open(os.path.join(share, "EDIT", "PICKSAVE.TXT"), "rb").read()
want = b"pick-two\n"
if got != want:
    print("PICKER SAVE-AS MISMATCH: got %r want %r" % (got, want))
    raise SystemExit(1)
print("picker save-as verified on the host: %r (%d bytes)" % (got, len(got)))
PY

# --- M123b (#2576) run 10: the empty buffer's shared empty state -----------
# Boot the editor on a path that does not exist: the create path opens an
# empty buffer, the shared widgets.EmptyState plate paints in the document
# area (icon, headline, chord hints), and `goedit: empty <path>` prints from
# the paint that drew it. The snapshot counts the Surface plate inside the
# window, which a bare document page cannot produce.
vgate_setup_python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
fresh = os.path.join(share, "EDIT", "FRESH.TXT")
if os.path.exists(fresh):
    sys.exit("EDIT/FRESH.TXT must not exist - the leg renders the empty buffer")
PY

# The leg boots with NO seat: under the registered tabwm seat the kernel
# skips blitting migrated (surface-backed) windows and only a
# surface-composing seat (gotabwm) carries them to the scanout — the app's
# document area would composite black and the pixel assert could never
# pass. Under the bare shim the kernel composites every window itself, so
# the streamed scanout really carries the painted plate.
vgate_file script-10.txt <<'EOS'
exec GOEDIT.ELF /host/EDIT/FRESH.TXT
EOS

# The echo IS the snapshot trigger and the run's expect — no close verb:
# the window must still be up (and its plate composited) when the kind-4
# stream reads gpu_fb. script3's 5 s settle gives the shim's composite the
# frame before the marker fires.
vgate_file script3-10.txt <<'EOS'
echo rx-goedit-empty-ok
EOS

vgate_run 10 -- \
    --screen '$RUN_DIR/screen-10' \
    --via-virtio \
    --snapshot-out '$RUN_DIR/snap-10' \
    --script '$RUN_DIR/script-10.txt' \
    --snapshot-after 'rx-goedit-empty-ok' \
    --script3 '$RUN_DIR/script3-10.txt' \
    --script3-after 'goedit: empty /host/EDIT/FRESH.TXT' \
    --script3-delay 5 \
    --script-expect 'rx-goedit-empty-ok' --timeout 240

vgate_assert 10 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 10 serial-contains 'goedit: read /host/EDIT/FRESH.TXT n=0 rc='
vgate_assert 10 serial-contains 'goedit: empty /host/EDIT/FRESH.TXT'
vgate_assert 10 serial-contains 'goedit: present'
vgate_assert 10 serial-contains 'rx-goedit-empty-ok'
vgate_assert 10 serial-absent 'goedit: saved '
# M123d: a missing file is the create path — the banner must NOT raise here.
vgate_assert 10 serial-absent 'goedit: banner '
vgate_assert 10 serial-absent '[EXC] parking:'
vgate_assert 10 serial-absent 'exited status=139'

# The guest's own composite, streamed raw: --snapshot-after rides the
# kind-4 channel, so the probe reads the real 1280x720 BGRX scanout — no
# host screen-capture permission in the path. The empty-state plate is
# the dark Surface fill (34,45,53) the EmptyState widget paints over the
# page background (24,32,38) across the client area — hundreds of
# thousands of pixels in one wide, tall region when the plate paints,
# none when a blank document does not.
vgate_assert 10 snapshot 'snap-10-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)"
             % (len(raw), need, W, H))

plate = 0
xs = []
ys = []
for y in range(H):
    base = y * W * 4
    for x in range(W):
        k = base + x * 4
        if max(abs(raw[k + 2] - 34), abs(raw[k + 1] - 45), abs(raw[k] - 53)) <= 12:
            plate += 1
            xs.append(x)
            ys.append(y)
n = plate
assert n >= 80000, "empty-state plate absent from the document area (%d px)" % n
bw = max(xs) - min(xs) + 1
bh = max(ys) - min(ys) + 1
assert bw >= 300 and bh >= 200, \
    "plate pixels are scattered accents, not one plate (%dx%d)" % (bw, bh)
print("goedit empty leg: surface-plate pixels=%d bbox=%dx%d" % (n, bw, bh))
PY

# --- M123d (#2578) run 11: the shared error banner --------------------------
# The deferred GOEDIT leg (the file was held by #2584 until #2693 merged).
# `exec -u0` — the capable path, so CAP_CLIPBOARD lets Copy Error land —
# opens GOEDIT on a DIRECTORY: the read refuses EINVAL (rc=-1, not the
# ENOENT create path run 10 keeps banner-free), so the shared
# appkit.ErrorBanner stands over the document and `goedit: banner open
# /host/EDIT failed rc=-1` prints only after the strip's own frame. `c` is
# the Copy Error arm: `goedit: banner act copy`, and the monitor's `clip`
# reads the strip's text back out of the KERNEL buffer — bytes a fake
# marker cannot produce. A typed char plus Ctrl-S then hits the staged
# live lease (`--lease-fixture=live`): `goedit: save error /host/EDIT -11`
# and a second raise — `goedit: banner save /host/EDIT refused rc=-11` —
# that Escape dismisses (`goedit: banner act dismiss`). No snapshot leg:
# under the shim-composited seat the app surface never reaches the
# framebuffer the --screen capture reads (run 10's plate assert has the
# same gap on this path) — the strip's paint is proven by the appkit
# widget's own coverage and go-fileman's pixel leg; here the raise marker
# is post-paint and the copy arm is verified through the kernel buffer.
vgate_file script2-11.txt <<'EOS'
exec -u0 GOEDIT.ELF /host/EDIT --lease-fixture=live
EOS

vgate_file script3-11.txt <<'EOS'
clip
dui close 2
echo rx-goedit-banner-ok
EOS

vgate_run 11 -- \
    --screen '$RUN_DIR/screen-11' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-11.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'c,X,ctrl-s,escape' \
    --input-chords-after 'goedit: banner open /host/EDIT' \
    --script3 '$RUN_DIR/script3-11.txt' \
    --script3-after 'goedit: banner act dismiss' \
    --script-expect 'rx-goedit-banner-ok' --timeout 240

vgate_assert 11 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 11 serial-contains 'goedit: lease fixture live'
# A directory is not a readable file: EINVAL, not the ENOENT create path.
vgate_assert 11 serial-contains 'goedit: read /host/EDIT n=0 rc=-1'
# The staged live lease refuses the open-time acquire too.
vgate_assert 11 serial-contains 'goedit: lease held rc=-11'
# The raise marker is post-paint: the strip is on scanout when it prints.
vgate_assert 11 serial-contains 'goedit: banner open /host/EDIT failed rc=-1'
# `c` was the Copy Error arm — the clipboard write succeeded (u0).
vgate_assert 11 serial-contains 'goedit: banner act copy'
vgate_assert 11 serial-contains 'goedit: dirty'
vgate_assert 11 serial-contains 'goedit: save error /host/EDIT -11'
vgate_assert 11 serial-contains 'goedit: banner save /host/EDIT refused rc=-11'
vgate_assert 11 serial-contains 'goedit: banner act dismiss'
vgate_assert 11 serial-contains 'rx-goedit-banner-ok'
vgate_assert 11 serial-absent 'goedit: saved '
vgate_assert 11 serial-absent '[EXC] parking:'
vgate_assert 11 serial-absent 'exited status=139'

# The external read: the kernel clipboard must hold the strip's own text —
# the banner is the only path that could have put it there.
vgate_assert 11 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
assert re.search(r"(?m)^clip: open /host/EDIT failed rc=-1\n", ser), \
    "kernel clipboard must read back exactly the banner's error text"
print("clipboard read-back verified: the banner's own text left the VM")
PY

# --- M121c (#2566) run 12: the '?' chord-hint overlay ----------------------
# A bare '?' keystroke opens the appkit overlay fed by the chord registry;
# Esc closes it. The markers are the serial-readable copy of the plate:
# n= is the row count (3 GOEDIT app rows + the seat's globals — the kernel
# terminal rows do not apply to a canvas window), and each `hints row`
# line is one registry row verbatim, so the content pin is the table, not
# a screenshot.
vgate_file script2-12.txt <<'EOFX'
exec GOEDIT.ELF /host/EDIT/SEED.TXT
EOFX

vgate_file script3-12.txt <<'EOFX'
dui close 2
echo rx-goedit-hints-ok
EOFX

vgate_run 12 -- \
    --screen '$RUN_DIR/screen-12' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-12.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords '?,escape' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3-12.txt' \
    --script3-after 'goedit: hints close' \
    --script-expect 'rx-goedit-hints-ok' --timeout 240

vgate_assert 12 serial-contains 'goedit: present'
# The app's four rows (ctrl+s/z/f/g — the undo row is M121e's) + every
# seat row (29 in the shipped table + M132a's seven reserved rows = 36)
# = 40; NO kernel-terminal rows — this window is not a tty front-end, so
# those chords do not answer here.
vgate_assert 12 serial-contains 'goedit: hints n=40'
vgate_assert 12 serial-contains 'goedit: hints row ctrl+s publish the buffer (save)'
vgate_assert 12 serial-contains 'goedit: hints row ctrl+f '
vgate_assert 12 serial-contains 'goedit: hints row ctrl+g '
vgate_assert 12 serial-contains 'goedit: hints row ctrl+shift+p summon the command palette'
vgate_assert 12 serial-absent 'goedit: hints row ctrl+shift+c '
vgate_assert 12 serial-contains 'goedit: hints close'
vgate_assert 12 serial-contains 'goedit: close'
vgate_assert 12 serial-contains 'rx-goedit-hints-ok'
vgate_assert 12 serial-absent '[EXC] parking:'
vgate_assert 12 serial-absent 'exited status=139'

# --- M138b (#2776) run 13: bracket match highlight + jump ------------------
# On "{abcdef}": `home` parks the caret on the `{` at offset 0 — the frame
# that status line stamps carries the `}` at offset 7 under-painted teal
# (colMatch, the pixel probe below). Ctrl-B jumps to it (`match jump
# off=7`, status col=8), a second Ctrl-B jumps back (off=0), a caret parked
# on 'a' answers the `match none` refusal, and the trailing `home` restores
# the probe frame (caret on `{`, `}` teal) so it is the one resident on the
# scanout when the snapshot fires.
# The leg boots with NO seat: under the registered tabwm seat the kernel
# skips blitting migrated (surface-backed) windows and only a
# surface-composing seat (gotabwm) carries them to the scanout — the
# document's pixels would never reach gpu_fb. Under the bare shim the
# kernel composites every window itself, so the teal cell is really there
# to stream.
vgate_file script-13.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/BKT.TXT
EOF

# The echo IS the snapshot trigger and the run's expect — no close verb:
# the window must still be up showing the probe frame when the kind-4
# stream reads gpu_fb.
vgate_file script3-13.txt <<'EOF'
echo rx-goedit-match-ok
EOF

vgate_run 13 -- \
    --screen '$RUN_DIR/screen-13' \
    --via-virtio \
    --snapshot-out '$RUN_DIR/snap-13' \
    --script '$RUN_DIR/script-13.txt' \
    --input-chords 'home,ctrl-b,ctrl-b,right,ctrl-b,home' \
    --input-chords-after 'goedit: present' \
    --snapshot-after 'rx-goedit-match-ok' \
    --script3 '$RUN_DIR/script3-13.txt' \
    --script3-after 'goedit: match none' \
    --script3-delay 5 \
    --script-expect 'rx-goedit-match-ok' --timeout 240

vgate_assert 13 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 13 serial-contains 'goedit: read /host/EDIT/BKT.TXT n=8'
vgate_assert 13 serial-contains 'goedit: present'
vgate_assert 13 serial-contains 'goedit: match jump off=7'
vgate_assert 13 serial-contains 'goedit: status line=1/1 col=8'
vgate_assert 13 serial-contains 'goedit: match jump off=0'
vgate_assert 13 serial-contains 'goedit: match none'
vgate_assert 13 serial-contains 'rx-goedit-match-ok'
vgate_assert 13 serial-absent '[EXC] parking:'
vgate_assert 13 serial-absent 'exited status=139'

# The pixel probe reads the guest's own composite: --snapshot-after rides
# the kind-4 channel, so the evidence is the real 1280x720 BGRX scanout —
# no host screen-capture permission in the path. The probe does not trust
# window geometry — the teal set must be one tight 8x8-ish cell, and the
# caret's amber block (2x8) must sit exactly 7 cells (56 px) to its left
# on the same row.
vgate_assert 13 snapshot 'snap-13-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)"
             % (len(raw), need, W, H))

teal = []
amber = []
for y in range(H):
    base = y * W * 4
    for x in range(W):
        k = base + x * 4
        b, g, r = raw[k], raw[k + 1], raw[k + 2]
        if max(abs(r - 0x3f), abs(g - 0xbf), abs(b - 0x9f)) <= 12:
            teal.append((x, y))
        elif max(abs(r - 0xff), abs(g - 0xd7), abs(b - 0x5f)) <= 24:
            amber.append((x, y))
n = len(teal)
assert n > 0, "no colMatch-teal pixels on the scanout — the match was not highlighted"
xs = [p[0] for p in teal]
ys = [p[1] for p in teal]
x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
bw, bh = x1 - x0 + 1, y1 - y0 + 1
assert n >= 24, "teal highlight is a speckle, not a cell fill (%d px)" % n
assert bw <= 24 and bh <= 16, \
    "teal is not one cell (%dx%d)" % (bw, bh)
# The caret block paints 7 cells left of the match on the same row —
# `{` under the caret, `}` the match — so amber must sit in that band.
band = [p for p in amber if x0 - 62 <= p[0] <= x0 - 50 and y0 - 2 <= p[1] <= y1 + 2]
assert len(band) >= 8, \
    "no amber caret block 7 cells left of the match cell (%d px in the band)" % len(band)
print("goedit bracket leg: teal px=%d cell=(%d..%d,%d..%d) %dx%d, caret px=%d"
      % (n, x0, x1, y0, y1, bw, bh, len(band)))
PY

# --- M149c (#2808) run 14: the -minimap column — pixels + press-to-jump ---
# GOTABWM.ELF/GOSET.ELF stage here for run 15; MINI.TXT is 60 lines of
# stepped widths (line 30 the widest) so the column's silhouette is not a
# block, THEME.TXT the two-line theme leg fixture. The armed share is ONE
# share for every leg — wm=none keeps each boot seatless now that
# GOTABWM.ELF is staged (the go-fileman idiom): run 15 execs the seat from
# the monitor instead of letting wm=gotabwm autostart answer every boot.
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name in ("GOTABWM.ELF", "GOSET.ELF"):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: "
                 "bash tools/go/build-%s.sh" % (name, src, name[:-4].lower()))
    shutil.copy(src, os.path.join(share, name))
ed = os.path.join(share, "EDIT")
os.makedirs(ed, exist_ok=True)
lines = []
for i in range(1, 61):
    n = 4 + (i % 6) * 6
    if i == 30:
        n = 40
    lines.append(b"x" * n)
with open(os.path.join(ed, "MINI.TXT"), "wb") as f:
    f.write(b"\n".join(lines) + b"\n")
with open(os.path.join(ed, "THEME.TXT"), "wb") as f:
    f.write(b"ab\ncd")
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("staged GOTABWM.ELF, GOSET.ELF, MINI.TXT (61 lines, 1236 bytes), "
      "THEME.TXT and SETTINGS.TXT wm=none")
PY

# The leg boots with NO seat (the run 10/13 rule: the kernel composites
# every window itself, so the strip's pixels really reach gpu_fb). The
# press is one --pointer-virtio click at the row for line 30 — the window
# sits at (32,32,512,384), so guest (536,85) is window-local (504,53): x is
# inside the 16 px column at the right edge, y = chromeH+29 maps to line
# 30. `minimap line=30` and the status line's landing are the serial half;
# the snapshot probe finds the gutter band, the scaled line rows and the
# caret line's amber row.
vgate_file script-14.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/MINI.TXT -minimap
EOF

# The echo IS the snapshot trigger and the run's expect — no close verb:
# the window must still be up showing the post-click frame when the kind-4
# stream reads gpu_fb (the run 10/13 shape).
vgate_file script3-14.txt <<'EOF'
echo rx-goedit-mini-ok
EOF

vgate_run 14 -- \
    --screen '$RUN_DIR/screen-14' \
    --via-virtio \
    --snapshot-out '$RUN_DIR/snap-14' \
    --script '$RUN_DIR/script-14.txt' \
    --pointer-virtio '536,85,d;536,85,u' \
    --pointer-virtio-after 'goedit: minimap on' \
    --snapshot-after 'rx-goedit-mini-ok' \
    --script3 '$RUN_DIR/script3-14.txt' \
    --script3-after 'goedit: minimap line=30' \
    --script3-delay 5 \
    --script-expect 'rx-goedit-mini-ok' --timeout 240

vgate_assert 14 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 14 serial-contains 'goedit: read /host/EDIT/MINI.TXT n=1236'
vgate_assert 14 serial-contains 'goedit: present'
vgate_assert 14 serial-contains 'goedit: minimap on'
# The press at local (504,53) mapped to line 30 and landed the caret there —
# the status line is the same string the chrome row paints.
vgate_assert 14 serial-contains 'goedit: minimap line=30'
vgate_assert 14 serial-contains 'goedit: status line=30/61 col=1'
vgate_assert 14 serial-contains 'rx-goedit-mini-ok'
vgate_assert 14 serial-absent '[EXC] parking:'
vgate_assert 14 serial-absent 'exited status=139'

# The probe reads the guest's own composite like run 13's. The window is
# declared at (32,32,512,384), so the column's guest rect is fixed —
# x in [528,544), y in [56,416) — and the probe reads exactly that: a
# colour-only hunt cannot work here, because the gutter tone sits inside
# the dark wallpaper gradient's tolerance and the whole bottom half of
# the desktop matches (observed: 655 k px, bbox 1256x700). Inside the
# window's own band the strip is unambiguous: thousands of gutter px
# spanning the full document height, hundreds of muted line-row px, and
# the caret line's amber row (the text-area caret block is outside the
# column's x-range by construction).
vgate_assert 14 snapshot 'snap-14-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)"
             % (len(raw), need, W, H))

def close(px, r, g, b, tol):
    return max(abs(px[2] - r), abs(px[1] - g), abs(px[0] - b)) <= tol

X0, X1, Y0, Y1 = 528, 544, 56, 416
gut = muted = amber = 0
gy = []
for y in range(Y0, Y1):
    base = y * W * 4
    for x in range(X0, X1):
        k = base + x * 4
        px = raw[k:k + 3]
        if close(px, 0x0b, 0x0e, 0x11, 8):
            gut += 1
            gy.append(y)
        elif close(px, 0x94, 0xa3, 0xb8, 12):
            muted += 1
        elif close(px, 0xff, 0xd7, 0x5f, 24):
            amber += 1
assert gut >= 3000, "no gutter band inside the column region (%d px)" % gut
span = (max(gy) - min(gy) + 1) if gy else 0
assert span >= 300, "the gutter band does not span the document (%d px)" % span
assert muted >= 200, "line rows did not paint inside the column (%d px)" % muted
assert amber >= 10, "the caret line's amber row is missing (%d px)" % amber
print("goedit minimap leg: column gutter px=%d yspan=%d, line px=%d, caret-row px=%d"
      % (gut, span, muted, amber))
PY

# --- M149c (#2808) run 15: light/dark theme follows the settings bus -----
# Under the Go seat the editor subscribes to `theme` at declare; GOSET is
# the writer (the go-wm-default run 10 shape): `theme=light` typed into it
# saves the file and publishes, the seat broadcasts to the one subscriber,
# and GOEDIT repaints — `settings repaint key=theme value=light` prints
# after that frame is on the scanout. snap-15-0 (fired at `goedit:
# present`) pins the DARK frame the boot palette painted; the alt-tab puts
# focus back on GOEDIT (GOSET took it on exec) so the following `q` lands
# in the buffer — its dirty `*` status is the run's last marker and the
# second snapshot's anchor, a full focus-flip later than the repaint.
vgate_file script-15.txt <<'EOF'
exec GOTABWM.ELF
EOF

vgate_file script2-15.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/THEME.TXT
EOF

vgate_file script3-15.txt <<'EOF'
exec GOSET.ELF
EOF

vgate_run 15 -- \
    --screen '$RUN_DIR/screen-15' \
    --via-virtio \
    --snapshot-out '$RUN_DIR/snap-15' \
    --script '$RUN_DIR/script-15.txt' \
    --script2 '$RUN_DIR/script2-15.txt' \
    --script2-after 'gotabwm: mode live' \
    --script3 '$RUN_DIR/script3-15.txt' \
    --script3-after 'goedit: settings subscribed key=theme' \
    --input-string $'theme=light\n' \
    --input-string-after 'goset: ready ' \
    --snapshot-after 'goedit: present' \
    --input-chords 'alt-tab' \
    --input-chords-after 'goedit: settings repaint key=theme value=light' \
    --input-key 12 \
    --input-key-after 'gotabwm: alt-tab id=' \
    --snapshot-after 'goedit: status line=2/2 col=4' \
    --script-expect 'goedit: status line=2/2 col=4' --timeout 300

vgate_assert 15 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 15 serial-contains 'gotabwm: mode live'
vgate_assert 15 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 15 serial-contains 'goedit: declare accepted'
# The subscription receipt is the script3 gate — the seat's own subscribe
# line names the subscriber pid.
vgate_assert 15 serial-contains 'goedit: settings subscribed key=theme'
vgate_assert 15 serial-contains 'gotabwm: settings subscribe pid='
vgate_assert 15 serial-contains 'goedit: present'
vgate_assert 15 serial-contains 'exec: loaded GOSET.ELF'
vgate_assert 15 serial-contains 'goset: set theme=light'
vgate_assert 15 serial-contains 'goset: saved '
vgate_assert 15 serial-contains 'goset: settings notified key=theme'
# GOEDIT is the only theme subscriber in this leg.
vgate_assert 15 serial-contains 'gotabwm: settings broadcast key=theme listeners=1'
# The repaint receipt prints after the light frame was presented.
vgate_assert 15 serial-contains 'goedit: settings repaint key=theme value=light'
vgate_assert 15 serial-contains 'gotabwm: alt-tab id='
# The typed q landed in the focused GOEDIT buffer — caret stays on line 2,
# column moves to 4, the dirty flag joins the status.
vgate_assert 15 serial-contains 'goedit: status line=2/2 col=4 *'
vgate_assert 15 serial-absent '[EXC] parking:'
vgate_assert 15 serial-absent 'exited status=139'
# The publish is the persisted half: the file on the host share says light.
vgate_assert 15 share-contains SETTINGS.TXT 'theme=light'

# snap-15-0 is the pre-switch frame: the dark page fill (24,32,38) covers
# the editor's document area and light-Bg pixels are essentially absent
# (only the light-ish ink of text rows). snap-15-1 is post-repaint plus a
# focus flip and a keystroke: the SAME probe then counts the light page
# (241,245,249) in the tens of thousands — the delta is the feature.
vgate_assert 15 snapshot 'snap-15-0.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)"
             % (len(raw), need, W, H))

dark = light = 0
for y in range(H):
    base = y * W * 4
    for x in range(W):
        k = base + x * 4
        b, g, r = raw[k], raw[k + 1], raw[k + 2]
        if max(abs(r - 24), abs(g - 32), abs(b - 38)) <= 12:
            dark += 1
        elif max(abs(r - 241), abs(g - 245), abs(b - 249)) <= 12:
            light += 1
assert dark >= 30000, \
    "the boot (dark) page did not cover the editor (%d px)" % dark
assert light <= 20000, \
    "light-Bg pixels before the switch: the probe cannot prove a transition (%d px)" % light
print("goedit theme leg pre-switch: dark page px=%d, light px=%d" % (dark, light))
PY

vgate_assert 15 snapshot 'snap-15-1.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)"
             % (len(raw), need, W, H))

light = dark_page = 0
xs = []
ys = []
for y in range(H):
    base = y * W * 4
    for x in range(W):
        k = base + x * 4
        b, g, r = raw[k], raw[k + 1], raw[k + 2]
        if max(abs(r - 241), abs(g - 245), abs(b - 249)) <= 12:
            light += 1
            xs.append(x)
            ys.append(y)
        elif max(abs(r - 24), abs(g - 32), abs(b - 38)) <= 12:
            dark_page += 1
assert light >= 50000, \
    "the light page fill did not reach the scanout (%d px)" % light
bw = max(xs) - min(xs) + 1
bh = max(ys) - min(ys) + 1
assert bw >= 200 and bh >= 150, \
    "light pixels are scattered, not a repainted document (%dx%d)" % (bw, bh)
print("goedit theme leg post-switch: light page px=%d bbox=%dx%d "
      "(dark-page remainder=%d)" % (light, bw, bh, dark_page))
PY

# --- M153b (#2922) run 16: a .pdf save-as name exports the buffer --------
# The seed is two short lines; Ctrl-Shift-S pretypes the basename, eleven
# backspaces clear it, EXPORT.PDF goes in, and the picker's save landing is
# an export — `edit: export pdf <path> pages=1 bytes=`, never a `saved`
# line at the PDF path. The follow-up Ctrl-S then publishes the buffer to
# the ORIGINAL path with the seed's exact byte count: the export moved
# neither the session path nor the dirty flag.
vgate_setup_python <<'PY'
import os
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
ed = os.path.join(share, "EDIT")
os.makedirs(ed, exist_ok=True)
with open(os.path.join(ed, "PDFSEED.TXT"), "wb") as f:
    f.write(b"export seed\nline two\n")
PY

vgate_file script2-16.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/PDFSEED.TXT
EOF

vgate_file script3-16.txt <<'EOF'
dui close 2
echo rx-goedit-pdf-ok
EOF

vgate_run 16 -- \
    --screen '$RUN_DIR/screen-16' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-16.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'ctrl-shift-s,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,E,X,P,O,R,T,.,P,D,F,return,ctrl-s' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3-16.txt' \
    --script3-after 'goedit: saved ' \
    --script-expect 'rx-goedit-pdf-ok' --timeout 240

vgate_assert 16 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 16 serial-contains 'goedit: read /host/EDIT/PDFSEED.TXT n=21'
vgate_assert 16 serial-contains 'goedit: present'
vgate_assert 16 serial-contains 'goedit: pick save /host/EDIT/EXPORT.PDF'
vgate_assert 16 serial-contains 'edit: export pdf /host/EDIT/EXPORT.PDF pages=1 bytes='
# The session stayed on the text file: path, buffer and dirty unmoved.
vgate_assert 16 serial-contains 'goedit: saved /host/EDIT/PDFSEED.TXT n=21'
vgate_assert 16 serial-absent 'goedit: saved /host/EDIT/EXPORT.PDF'
vgate_assert 16 serial-absent 'edit: export refused'
vgate_assert 16 serial-contains 'rx-goedit-pdf-ok'
vgate_assert 16 serial-absent '[EXC] parking:'
vgate_assert 16 serial-absent 'exited status=139'

# The load-bearing assert: the share's EXPORT.PDF is a real PDF — the
# %PDF-1. header, a classic xref whose in-use offsets each land on their
# "N 0 obj" header, and the page tree's /Count is the export's one page.
vgate_assert 16 python <<'PY'
import os, re
share = os.environ["VG_SHARE"]
path = os.path.join(share, "EDIT", "EXPORT.PDF")
data = open(path, "rb").read()
if not data.startswith(b"%PDF-1."):
    raise SystemExit("bad header: %r" % data[:16])
m = re.search(rb"startxref\s*(\d+)\s*%%EOF", data)
if not m:
    raise SystemExit("no startxref")
xref = int(m[1])
if not data[xref:xref + 4] == b"xref":
    raise SystemExit("startxref does not land on xref (%d)" % xref)
sec = data[xref:].split(b"\n", 2)
n = int(sec[1].split()[1])
lines = sec[2].split(b"\n")[:n]
for i, line in enumerate(lines):
    off, gen, flag = line.split()
    if flag == b"f":
        continue
    off = int(off)
    want = ("%d 0 obj" % i).encode()
    if data[off:off + len(want)] != want:
        raise SystemExit("xref offset %d -> %r, want %r" % (i, data[off:off + 16], want))
m = re.search(rb"/Type /Pages[^>]*?/Count (\d+)", data)
if not m or int(m[1]) != 1:
    raise SystemExit("page count %r" % (m[1] if m else None))
print("EXPORT.PDF verified: %d bytes, %d xref objects, pages=1" % (len(data), n))
PY
