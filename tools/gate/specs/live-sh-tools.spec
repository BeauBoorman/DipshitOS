# live-sh-tools.spec -- M49 card SD3 class-B gate (issue #1130).
#
# The freestanding tool multicall (lib/toolbox.zig) two ways:
#   1. the standalone TOOL.BIN from the monitor (`exec TOOL.BIN wc -l FILE`),
#      with the first argument selecting the tool;
#   2. the same engine as shell builtins, sourced from a share script by the
#      Go shell (M68b #1450 retarget: the lane used to exec SH.BIN):
#      head/wc/grep/sort/cut/printf/test/[/case/read plus a pipe
#      (`env | grep PWD`) and redirection (`read RV < DATA.TXT`).
# Boot default unchanged; markers single writes.
#
# HOST PREREQ: bash tools/go/build-gosh.sh -> .build/go/GOSH.ELF

vgate_name live-sh-tools "#1130 SD3: TOOL.BIN multicall + shell tool builtins over the host share"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec TOOL.BIN wc -l DATA.TXT
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
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
with open(os.path.join(share, "DATA.TXT"), "w") as f:
    f.write("beta\nalpha\ngamma\n")
with open(os.path.join(share, "CUT.TXT"), "w") as f:
    f.write("one:two:three\n")
lines = [
    "echo TOOLS-START",
    "cd /",
    "head -n 2 DATA.TXT",
    "wc -l DATA.TXT",
    "grep alpha DATA.TXT",
    "sort DATA.TXT",
    "printf TOOL-OK",
    "set V=beta",
    "case $V in beta) echo CASE-B;; *) echo CASE-X;; esac",
    "cut -d : -f 1 CUT.TXT",
    "read RV < DATA.TXT; echo READ=$RV",
    "env | grep PWD",
    "echo TOOLS-END",
]
with open(os.path.join(share, "TOOLS.SH"), "w") as f:
    f.write("\n".join(lines) + "\n")
with open(os.path.join(run, "edit2.bin"), "wb") as f:
    f.write(b"exec GOSH.ELF serial\r")
with open(os.path.join(run, "edit3.bin"), "wb") as f:
    f.write(b"source TOOLS.SH\r")
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/edit2.bin' --script2-after 'tool: done status=0' --script3 '$RUN_DIR/edit3.bin' --script3-after 'gosh: attached' --script-expect 'TOOLS-END' --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tool: ready'
vgate_assert 01 serial-contains 'tool: done status=0'
vgate_assert 01 serial-contains '3 DATA.TXT'
vgate_assert 01 serial-contains 'gosh: attached'
vgate_assert 01 serial-contains 'TOOLS-START'
vgate_assert 01 serial-contains 'alpha'
vgate_assert 01 serial-contains 'gamma'
vgate_assert 01 serial-contains 'TOOL-OK'
vgate_assert 01 serial-contains 'CASE-B'
vgate_assert 01 serial-contains 'READ=beta'
vgate_assert 01 serial-contains 'PWD=/'
vgate_assert 01 serial-contains 'TOOLS-END'
vgate_assert 01 serial-absent 'CASE-X'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

# M97g #2081: the EL0 pipe is bound per-process, not one global buffer.
# A victim GOSH runs eight staged pipelines appending PIPE-OK rows;
# meanwhile eight FRESH TOOL.BIN readers hammer slot 56 (`grep PIPE-OK`
# on their own — empty — pipe). Under the old shared buffer a reader
# landing in the victim's stage window could steal a staged line (status
# 0 + the row printed); per-pid every read sees only its own slot, so
# grep reports no match (status 1) every time, and the victim's file
# stays byte-exact. `-c` allows at most four `;` segments and expands the
# body once before runFor binds the loop variable, so the loop emits
# identical rows — byte-exactness is still the observable. Two traps in
# the old line (#2649): parseFor DISCARDS everything after `done`, so
# `done; sleep 25; echo VICTIM-DONE` never slept and never printed — the
# marker only ever matched its own typed echo; and an echoed needle lets
# --script-expect's substring search match the ECHO instantly, tearing
# the VM down while the eighth reader was mid-flight (observed 7/8).
# (gosh `sleep` cannot substitute here: it maps seconds to ticks at 100/s
# while the kernel timer runs at 1 Hz.) The late marker is now HELLO.ELF's
# banner — `elf: hello from HELLO.ELF` never appears in a typed script
# line, so the expect waits for real output after the readers report.
vgate_file pipevictim.txt <<'EOF'
exec GOSH.ELF -c "for i in a b c d e f g h; do echo PIPE-OK | grep PIPE-OK >> /host/PIPED.TXT; sort /host/APPS.TXT; done"
EOF

vgate_file pipehammer.txt <<'EOF'
exec TOOL.BIN grep PIPE-OK
exec TOOL.BIN grep PIPE-OK
exec TOOL.BIN grep PIPE-OK
exec TOOL.BIN grep PIPE-OK
exec TOOL.BIN grep PIPE-OK
exec TOOL.BIN grep PIPE-OK
exec TOOL.BIN grep PIPE-OK
exec TOOL.BIN grep PIPE-OK
exec HELLO.ELF
EOF

vgate_run 02 -- --script '$RUN_DIR/pipevictim.txt' --script2 '$RUN_DIR/pipehammer.txt' --script2-after 'exec: loaded GOSH.ELF' --script-expect 'elf: hello from HELLO.ELF' --timeout 120

vgate_assert 02 serial-contains 'elf: hello from HELLO.ELF'
vgate_assert 02 serial-count 'tool: done status=1' 8
vgate_assert 02 serial-absent 'tool: done status=0'
vgate_assert 02 share-equals PIPED.TXT $'PIPE-OK\nPIPE-OK\nPIPE-OK\nPIPE-OK\nPIPE-OK\nPIPE-OK\nPIPE-OK\nPIPE-OK\n'
vgate_assert 02 serial-absent '[EXC] parking:'
