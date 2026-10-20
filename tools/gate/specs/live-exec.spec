# live-exec.spec -- a real user program (USER.BIN) loaded from the ESP
# through the FAT path and entered at EL0: load line, EL0 markers, and
# the exit/reap lifecycle closing, shell left responsive.
# Mirrors tools/verify-live-exec.sh (claim 6783).
#
# Runs 02-04 are the M119d (#2488) spawn-shape matrix for ADR 0035
# amendment 8's "uncharacterised" third-child death. One EL0 parent
# (GOSELFHOST.ELF, the same driver amendment 8 measured with) is swept
# across: sequential depth (spawn -> wait -> next, run 02), tree depth (a
# GOSELFHOST child that itself spawns grandchildren, run 02), concurrent
# breadth (--spawn-par: every child spawned before any wait, so the pool
# holds them all live at once, run 03), and the amendment's exact failing
# shape -- cmd/compile + cmd/link followed by the product as the THIRD
# child of the same parent (run 04). The verdict line
# `selfhost: spawn[-par] verdict=K-of-M-survived IMAGE` is both the
# per-leg stage gate and the per-leg assert; a leg that hits a bound
# still prints it (K<M is the finding, SPAWN-FAIL names the refusal) —
# it never silently passes.
#
# Run 05 is the M133a (#2755) named-OOM leg: EL0EXEC.BIN oom modes
# exhaust a 6-page memory rlimit twice — the MAP_POPULATE refusal names
# ENOMEM, the demand-fault refusal reaps the caller with the status-140
# receipt — then USER.BIN finishing 43 proves the scheduler is not
# wedged.
#
# exec-order: assert-proven -- each boot's --script-expect is the LAST
# leg's verdict marker, which only that leg's driver prints.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-go.sh                        -> .build/go/GOHELLO.ELF
#   bash tools/go/build-go.sh tools/go/selfhost.go   -> .build/go/GOSELFHOST.ELF
#   bash tools/go/build-gotool.sh                    -> .build/go/GOCMD{COMPILE,LINK}.ELF
#   bash tools/go/stage-selfhost.sh                  -> .build/go/selfhost/

vgate_name live-exec "load + exec USER.BIN at EL0; M119d spawn-shape matrix (depth x breadth x seq/par)"
vgate_share seed
vgate_repeat 1 BOOTS
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
ls
exec USER.BIN
echo rx-exec-ok
EOF

# --- M119d matrix legs -------------------------------------------------------
# Each driver invocation is ONE fresh EL0 parent; `--spawn` = sequential
# (depth), `--spawn-par` = concurrent (breadth), `--` = the spawned child's
# own argv (a GOSELFHOST child driving its own spawns is the tree-depth leg).

# Run 02, leg A: five SEQUENTIAL Zig children (STATUS43.BIN exits 43 — a
# status only the program itself can leave, so the count is proof).
vgate_file m02a.txt <<'EOF'
exec GOSELFHOST.ELF --spawn STATUS43.BIN 5 43
EOF

# Run 02, leg B: five SEQUENTIAL Go children — the runtime kind that died
# in both amendment-8 observations.
vgate_file m02b.txt <<'EOF'
exec GOSELFHOST.ELF --spawn GOHELLO.ELF 5 0
EOF

# Run 02, leg C: tree depth — a GOSELFHOST child whose own argv runs its own
# --spawn experiment (driver -> child driver -> 2 grandchildren). No expected
# status on the parent leg (argv would overrun the kernel's 7-arg exec tail):
# the nested child's own `verdict=2-of-2-survived` line is the assert.
vgate_file m02c.txt <<'EOF'
exec GOSELFHOST.ELF --spawn GOSELFHOST.ELF 1 -- --spawn STATUS43.BIN 2
EOF

# Run 03, leg A: eight CONCURRENT Zig children — proves breadth itself is
# not the bound (8 x 1-task children + the 4-task Go parent stay well
# inside the 61-slot user side of the 64-task pool — M129b).
vgate_file m03a.txt <<'EOF'
exec GOSELFHOST.ELF --spawn-par STATUS43.BIN 8 43
EOF

# Run 03, leg B: seventy concurrent Zig children — deliberately past the
# capacity bounds (M129b: 70 exec'd roots alone outrun the 512-page table
# carve-out ~24 deep, and the 61-slot user side of the pool sits right
# behind it): the excess spawns must come back as named SPAWN-FAIL
# refusals, never as deaths or wedges. The exact spawned/refused split
# rides on the zombie backlog — the bound asserted is that over-
# subscription refuses by name, not an exact count.
vgate_file m03b.txt <<'EOF'
exec GOSELFHOST.ELF --spawn-par STATUS43.BIN 70 43
EOF

# Run 03, leg C: sixteen CONCURRENT Go runtimes — deliberately over the
# pool's runtime-side bound (M129b): a GOMAXPROCS=2 child needs ~4 task
# slots of Ms (primary + sysmon + helpers), and a 4-task parent plus
# sixteen such children oversubscribes the 64-slot pool, so some child's
# newosproc throws (`sys_thread create failed` -> status 2) — the failure
# must be a named status, never the amendment-8 tombstone. Which child
# draws the short straw is scheduler order, so the leg asserts only that
# a verdict prints and no child dies badly.
vgate_file m03c.txt <<'EOF'
exec GOSELFHOST.ELF --spawn-par GOHELLO.ELF 16 0
EOF

# Run 04, leg A: the amendment-8 shape exactly — the build loop's
# compile + link children, then the linked PRODUCT as the third sequential
# child of the same EL0 parent (the boot that produced the
# far=0x47c29000 esr=0x9200004f status-139 tombstone).
vgate_file m04a.txt <<'EOF'
exec GOSELFHOST.ELF --after-loop --spawn HELLO2.ELF 1 0
EOF

# Run 04, leg B: the heavy pair then three more sequential Go children —
# children 3,4,5 of a parent that already ran two 24/6-MiB toolchain images.
vgate_file m04b.txt <<'EOF'
exec GOSELFHOST.ELF --after-loop --spawn GOHELLO.ELF 3 0
EOF

# Run 04, leg C: the heavy pair then two CONCURRENT Go children — the mixed
# shape (sequential depth AND breadth after big allocations).
vgate_file m04c.txt <<'EOF'
exec GOSELFHOST.ELF --after-loop --spawn-par GOHELLO.ELF 2 0
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
fixtures = [".build/go/GOSELFHOST.ELF", ".build/go/GOHELLO.ELF",
            ".build/go/GOCMDCOMPILE.ELF", ".build/go/GOCMDLINK.ELF"]
for src in fixtures:
    if not os.path.exists(src):
        sys.exit("%s missing — build it first (see this spec's header): "
                 "bash tools/go/build-go.sh, "
                 "bash tools/go/build-go.sh tools/go/selfhost.go, "
                 "bash tools/go/build-gotool.sh" % src)
    shutil.copy(src, os.path.join(share, os.path.basename(src)))
    print("staged %s (%d bytes)" % (os.path.basename(src), os.path.getsize(src)))
# The loop's inputs: import config naming export data, the archives, and the
# pinned source (same staging as live-selfhost-go).
stage = ".build/go/selfhost"
if not os.path.isdir(stage):
    sys.exit("missing %s — run: bash tools/go/stage-selfhost.sh" % stage)
n = total = 0
for name in sorted(os.listdir(stage)):
    if name.startswith("."):
        continue
    shutil.copy(os.path.join(stage, name), os.path.join(share, name))
    n += 1
    total += os.path.getsize(os.path.join(stage, name))
print("staged %d selfhost inputs (%.2f MiB)" % (n, total / 1048576.0))
# The products must not be leftovers: a stale HELLO2.ELF would let a broken
# loop fake the third-child leg.
for stale in ("HELLO.o", "HELLO2.ELF"):
    p = os.path.join(share, stale)
    if os.path.exists(p):
        os.remove(p)
        print("removed stale %s from a previous run" % stale)
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'tasks user-exec reaped' --timeout 60

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'USER.BIN' 2
vgate_assert 01 serial-exact 'tasks user-exec reaped' 1
vgate_assert 01 serial-exact 'rx-exec-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
# Legacy -Fc = 1: exactly one line CONTAINING the needle (substring, not
# whole-line: markers can share a line with the prompt tail).
need = [
    "exec: loaded USER.BIN size=",
    "user: hello from the ESP",
    "user: exec ok",
    "tasks user-exec exited status=43",
]
bad = [(n, sum(1 for l in lines if n in l)) for n in need]
bad = [(n, c) for n, c in bad if c != 1]
if bad:
    sys.exit("FAIL: exec markers not exactly-once: %s" % bad)
print("exec markers exactly-once ok")
PY

# Run 02 — the matrix's sequential legs: Zig depth-5 (control: a status only
# the child itself can produce), Go depth-5 (the language of both observed
# deaths), and tree depth (driver -> child driver -> grandchildren). The
# stage gates key on the PREVIOUS leg's verdict line, so every leg ran to
# completion before the next was typed.
vgate_run 02 -- --script '$RUN_DIR/m02a.txt' \
    --script2 '$RUN_DIR/m02b.txt' --script2-after 'of-5-survived STATUS43.BIN' \
    --script3 '$RUN_DIR/m02c.txt' --script3-after 'of-5-survived GOHELLO.ELF' \
    --script-expect 'of-1-survived GOSELFHOST.ELF' --timeout 240

vgate_assert 02 serial-contains 'selfhost: spawn verdict=5-of-5-survived STATUS43.BIN'
vgate_assert 02 serial-contains 'selfhost: spawn verdict=5-of-5-survived GOHELLO.ELF'
# The nested child's own verdict (its STATUS43 grandchildren) plus the
# parent's verdict on the child.
vgate_assert 02 serial-contains 'selfhost: spawn verdict=2-of-2-survived STATUS43.BIN'
vgate_assert 02 serial-contains 'selfhost: spawn verdict=1-of-1-survived GOSELFHOST.ELF'
vgate_assert 02 serial-count 'STATUS43.BIN status=43' 7
vgate_assert 02 serial-absent 'exited status=139'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'cannot allocate memory'
vgate_assert 02 serial-absent 'NO-STATUS'
vgate_assert 02 serial-absent 'SPAWN-FAIL'
vgate_assert 02 serial-absent 'newosproc'
vgate_assert 02 serial-absent 'unexpected status'

# Run 03 — the matrix's breadth legs: concurrent children live in the pool
# at once. par-zig8 is the control (breadth itself is not the bound);
# par-zig70 forces the SPAWN-side refusal (ENOSPC — the table carve-out
# is exec's first wall at 64 slots, a named bound either way, not a
# death); par-go16 oversubscribes the pool at RUNTIME init (a child's
# newosproc Ms cannot all fit, so some child exits status=2 —
# never a wedge, never a 139 tombstone).
vgate_run 03 -- --script '$RUN_DIR/m03a.txt' \
    --script2 '$RUN_DIR/m03b.txt' --script2-after 'of-8-survived STATUS43.BIN' \
    --script3 '$RUN_DIR/m03c.txt' --script3-after 'of-70-survived STATUS43.BIN' \
    --script-expect 'of-16-survived GOHELLO.ELF' --timeout 300

vgate_assert 03 serial-contains 'selfhost: spawn-par verdict=8-of-8-survived STATUS43.BIN'
# The breadth bound: over-subscription refuses by name. How many spawned
# before the bounds ran dry rides on zombie reaping, so the pin is on the
# refusal existing and the run completing — the exact split is reported.
vgate_assert 03 serial-count 'SPAWN-FAIL' 1
vgate_assert 03 serial-contains 'of-70-survived STATUS43.BIN'
# The Go-runtime bound: a verdict always prints; status=2 newosproc deaths
# are the expected shape of the refusal. The tombstones that make a bound
# a BUG are what must be absent.
vgate_assert 03 serial-contains 'of-16-survived GOHELLO.ELF'
vgate_assert 03 serial-absent 'exited status=139'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'cannot allocate memory'
vgate_assert 03 serial-absent 'NO-STATUS'
vgate_assert 03 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Report the breadth verdicts; the par-go16 leg's K is scheduler-dependent
# (which child's newosproc hits the full pool first), so it is read, not
# pinned — but SOME refusal must have occurred: if all sixteen Go children
# survived, the recorded bound is wrong and the ADR needs re-measuring.
verdicts = re.findall(r"selfhost: spawn-par verdict=(\d+)-of-(\d+)-survived (\S+)", ser)
for k, n, img in verdicts:
    print("spawn-par verdict: %s-of-%s survived %s" % (k, n, img))
go16 = [k for k, n, img in verdicts if img == "GOHELLO.ELF" and n == "16"]
if len(go16) != 1 or int(go16[0]) >= 16:
    sys.exit("FAIL: par-go16 must refuse past the pool (K<16), got %r" % go16)
print("par-go16 survived count: %s of 16 (task-pool bound: a status-2 "
      "newosproc death, never a crash)" % go16[0])
zig70 = [k for k, n, img in verdicts if img == "STATUS43.BIN" and n == "70"]
if len(zig70) != 1 or int(zig70[0]) >= 70:
    sys.exit("FAIL: par-zig70 must refuse past the bounds (K<70), got %r" % zig70)
print("par-zig70 spawned/survived: %s of 70 (the rest SPAWN-FAIL ENOSPC)" % zig70[0])
PY

# Run 04 — the amendment-8 shape itself: after the build loop's compile+link
# children, a third sequential child (the product HELLO2.ELF — the exact
# tombstone shape), then children 3-5 sequential Go, then children 3+4
# concurrent. Every leg is a fresh parent whose first two children are the
# 24-MiB compile and the link — the conditions under which a third child
# died once.
vgate_run 04 -- --script '$RUN_DIR/m04a.txt' \
    --script2 '$RUN_DIR/m04b.txt' --script2-after 'of-1-survived HELLO2.ELF' \
    --script3 '$RUN_DIR/m04c.txt' --script3-after 'of-3-survived GOHELLO.ELF' \
    --script-expect 'of-2-survived GOHELLO.ELF' --timeout 900

# Each leg must RUN its loop and every leg ends on a verdict line — including
# a 0-of-M verdict after a bound-killed toolchain child. The shape under test
# is that every outcome is NAMED (a status, a SPAWN-FAIL, a verdict); the
# failures this card exists to retire are the ones that produce no outcome at
# all. At least one loop must complete end-to-end (a loop that never links is
# a regression, not the pool bound).
vgate_assert 04 serial-count 'selfhost: compile GOCMDCOMPILE.ELF status=' 1
vgate_assert 04 serial-count 'selfhost: link GOCMDLINK.ELF status=' 1
vgate_assert 04 serial-count 'selfhost: build loop OK' 1
vgate_assert 04 serial-contains 'of-1-survived HELLO2.ELF'
vgate_assert 04 serial-contains 'of-3-survived GOHELLO.ELF'
vgate_assert 04 serial-contains 'of-2-survived GOHELLO.ELF'
# The tombstone signatures are what "the bound became a bug" looked like in
# amendment 8. A status-2 newosproc death (pool dry inside a Go runtime's
# schedinit) is the named bound — SPAWN-FAIL/status lines are legal here.
vgate_assert 04 serial-absent 'exited status=139'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'cannot allocate memory'
vgate_assert 04 serial-absent 'NO-STATUS'
vgate_assert 04 python <<'PY'
import os, sys
sys.path.insert(0, os.path.join("tools", "lib"))
import elf_rules
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
# Leg A's third child is not a liveness artifact: the loop's own products
# are checked on the host — the object is a virelai ar archive and the ELF
# passes every loader rule the kernel enforces (same checker as
# live-selfhost-go).
obj = os.path.join(share, "HELLO.o")
if not os.path.exists(obj):
    sys.exit("FAIL: the loop produced no object at " + obj)
raw = open(obj, "rb").read()
if not raw.startswith(b"!<arch>") or b"go object virelai arm64 " not in raw:
    sys.exit("FAIL: HELLO.o is not a virelai Go object (first bytes %r)" % raw[:16])
elf = os.path.join(share, "HELLO2.ELF")
if not os.path.exists(elf):
    sys.exit("FAIL: the loop produced no ELF at " + elf)
receipt, fails = elf_rules.check_file(elf, "HELLO2.ELF")
print("loop products: HELLO.o %d bytes (virelai object), %s" % (len(raw), receipt))
if fails:
    for f in fails:
        print("FAIL: " + f)
    sys.exit(1)
print("the third child's ELF satisfies every loader rule the kernel enforces")
PY

# Run 05 — M133a (#2755): named OOM. EL0EXEC.BIN's new `oom` modes set a 6-page
# memory rlimit (sys_setrlimit type 0) and exhaust it twice: refuse
# mode's MAP_POPULATE mmaps answer ENOMEM by name (the child prints
# `oom: enomem ok` and exits 0); reap mode's 7th demand-fault charge is
# refused and the kernel reaps the caller with the mem-limit receipt
# (`EL0EXEC.BIN exited status=140` on serial). USER.BIN finishing 43
# afterward proves the scheduler is not wedged — other processes keep
# running.
vgate_file m05a.txt <<'EOF'
exec EL0EXEC.BIN oom
EOF

vgate_file m05b.txt <<'EOF'
exec EL0EXEC.BIN oom reap
EOF

vgate_file m05c.txt <<'EOF'
exec USER.BIN
EOF

vgate_run 05 -- --script '$RUN_DIR/m05a.txt' \
    --script2 '$RUN_DIR/m05b.txt' --script2-after 'oom: enomem ok' \
    --script3 '$RUN_DIR/m05c.txt' --script3-after 'EL0EXEC.BIN exited status=140' \
    --script-expect 'exited status=43' --timeout 120

vgate_assert 05 serial-contains 'oom: enomem ok'
vgate_assert 05 serial-contains 'EL0EXEC.BIN exited status=140'
vgate_assert 05 serial-contains 'user: hello from the ESP'
vgate_assert 05 serial-contains 'exited status=43'
vgate_assert 05 serial-absent 'oom: setrlimit failed'
vgate_assert 05 serial-absent 'oom: mmap unexpected'
vgate_assert 05 serial-absent 'oom: reap-miss'
vgate_assert 05 serial-absent '[EXC] parking:'
