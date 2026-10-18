# live-sh.spec -- M45 card SH2 class-B gate (issue #1078, ADR 0021 D2/D3),
# retargeted to GOSH by M68b (#1450).
#
# The gate's subject is the *shell*, not the binary that hosts it: an EL0
# shell opens /dev/tty, attaches the SERIAL console, prompts, and dispatches
# through its core. A scripted burst proves the core live: `echo` (builtin),
# `cd /data` + `$PWD` expansion, external `status43` resolved
# case-insensitively (status43 -> STATUS43.BIN) and run foreground, then
# Up-history re-runs it (status43: alive twice). M69f2 (#1538) adds the
# discovery half of the M49 bar: `help` (grouped catalog, ADR 0008 D1),
# `help <cmd>` (usage + description) and the D3 unknown-verb shape, all
# typed at the same prompt so a shell that never ran cannot pass them.
# Markers are single writes.
# `GOSH.ELF serial` is the Go front-end owner of that console
# (sys_tty_attach selector 1, ADR 0020), so every assert is unchanged except
# the binary and its marker prefix. Boot default unchanged.
#
#
# Run 02 is the M69f1 (#1537) persistent-recall beat: the SAME share boots
# again and ONE Up arrow (plus Enter) recalls the last line run 01
# submitted. Run 02 types no command text at all, so `status43: alive` in
# its log can only come from a line read back off /host/GOSH-HISTORY.TXT
# and then executed -- which is the whole card.
#
# HOST PREREQ: bash tools/go/build-gosh.sh -> .build/go/GOSH.ELF

vgate_name live-sh "#1078 SH2 userland shell: builtins, cd, external app + Up-history over /dev/tty"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
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
# The `cd /data` target must actually EXIST on the share, or the assert
# below is weaker than it reads. SH.BIN's `cd` was pure shell-local
# bookkeeping (user/src/lib/shell.zig: "pwd/cd track the shell-local cwd"),
# so it accepted any string and `PWD=/data` passed for a path that was not
# there at all. GOSH verifies the directory through sys_dir_list before it
# moves, which is the behavior the M49 bar wants, so the gate has to hand
# it a real directory instead of a name.
os.makedirs(os.path.join(share, "data"), exist_ok=True)
print("staged GOSH.ELF (%d bytes) + data/ into share" % os.path.getsize(src))
PY

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
# echo sh-echo-ok; cd /data; echo PWD=$PWD; the M69f2 help trio (the
# grouped catalog, one verb page, one unknown verb); run status43; then Up
# + Enter to recall and re-run the last command from history.
seq = (b"echo sh-echo-ok\rcd /data\recho PWD=$PWD\r"
       b"help\rhelp printf\rhelp nosuchverb\r"
       b"status43\r\x1b[A\r")
with open(os.path.join(run, "edit.bin"), "wb") as f:
    f.write(seq)
# Run 02 types Up + Enter and NOTHING else: the recalled line must come
# from the persisted file, not from this byte sequence.
with open(os.path.join(run, "recall.bin"), "wb") as f:
    f.write(b"\x1b[A\r")
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/edit.bin' --script2-after 'gosh: attached' --script-expect 'status43: alive' --script-expect-tail 16 --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gosh: attached'
vgate_assert 01 serial-contains 'sh-echo-ok'
vgate_assert 01 serial-contains 'PWD=/data'
vgate_assert 01 serial-contains 'status43: alive'
vgate_assert 01 serial-count 'status43: alive' 2
# M69f2 (#1538): the catalog keeps `builtins:` as its first line, carries
# more than one group section, and `help <cmd>` prints the D1 usage line;
# an unknown name gets the D3 shape rather than a dump of everything.
vgate_assert 01 serial-contains 'builtins:'
vgate_assert 01 serial-contains 'shell: alias clear date echo exit help history log monitor time unalias'
vgate_assert 01 serial-contains 'identity: chmod id secrets whoami'
vgate_assert 01 serial-contains 'usage: printf FORMAT [ARGS...]'
vgate_assert 01 serial-contains 'subset: one pipe per line'
vgate_assert 01 serial-contains "unknown command 'nosuchverb'"
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'
# M73d follow-up (#1658): the editor's submit echo is a bare CRLF and the
# front-end paints the fresh prompt AFTER RunLine returns, so `echo PWD=$PWD`'s
# output line is immediately followed by `gosh> ` prefixing the next line --
# and never inline behind it (`gosh> PWD=/data` is the pre-M73d
# prompt-before-output shape, which fails both halves below). The pinned
# command is deliberately one whose typed line does NOT end with its output:
# with `echo sh-echo-ok` the old submit repaint (`gosh> echo sh-echo-ok`)
# forges the same adjacency and the assert could not tell the orders apart
# (observed in the negative check).
vgate_assert 01 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
norm = ser.replace("\r\n", "\n").replace("\r", "\n")
if "PWD=/data\ngosh> " not in norm:
    sys.exit("FAIL: no `PWD=/data` output line followed by the `gosh> ` prompt (post-execution order)")
if "gosh> PWD=/data" in norm:
    sys.exit("FAIL: prompt-before-output shape `gosh> PWD=/data` present (pre-M73d protocol)")
print("prompt-after-output order ok: `PWD=/data` line then `gosh> `")
PY
# M69f1 (#1537): the submitted lines are on the share in ring order, one
# per line, oldest first -- and it is GOSH's own file, not the monitor's.
vgate_assert 01 share-equals GOSH-HISTORY.TXT $'echo sh-echo-ok\ncd /data\necho PWD=$PWD\nhelp\nhelp printf\nhelp nosuchverb\nstatus43\n'

# --- Run 02: the same share, a new boot, one Up arrow -------------------
# Nothing but the chord is typed, so `status43: alive` here is a line read
# back from /host/GOSH-HISTORY.TXT and run. serial-count 1 also proves it
# ran exactly once (the paint on Up writes `status43`; only an execution
# writes `status43: alive`).
vgate_run 02 -- --screen '$RUN_DIR/screen2' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/recall.bin' --script2-after 'gosh: attached' --script-expect 'status43: alive' --script-expect-tail 8 --timeout 90

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-contains 'gosh: ready'
vgate_assert 02 serial-contains 'gosh: attached'
vgate_assert 02 serial-contains 'gosh: prompt'
vgate_assert 02 serial-contains 'status43: alive'
vgate_assert 02 serial-count 'status43: alive' 1
vgate_assert 02 serial-absent '\[EXC\]'
vgate_assert 02 serial-absent '[EXC] parking:'
