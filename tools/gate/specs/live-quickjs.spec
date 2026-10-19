# Standalone ADR 0039 QJS.BIN: file/tty eval, explicit refusals and budgets.
# All evals run on VZ. Node goldens are pinned inputs, never guest substitutes.
# Policy-only unreachable arithmetic limits are labeled separately.
# Cleanup requires procs receipt QJS.BIN and exact independent pages recovery.
# exec-order: assert-proven -- every snapshot follows guest reap or launcher
# exit; output, receipt and page assertions fail if any guest work is absent.

vgate_name live-quickjs "ADR 0039 file, interactive, refusal, bounds and cold/cleanup acceptance"
vgate_share arm-virtiofs
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt user/src/quickjs.zig tools/js-client/*.zig
vgate_note "QJS-FILE-EVAL QJS-INTERACTIVE-EVAL QJS-REFUSALS QJS-BOUNDS QJS-COLD-AND-CLEANUP"

vgate_setup_python <<'PY'
import os, pathlib, sys
sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path("tools/js-client").resolve()))
from prepare import prepare
prepare(pathlib.Path(os.environ["RUN_DIR"]))
PY

vgate_file check.py <<'PY'
import pathlib, sys
sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path("tools/js-client").resolve()))
from assertions import check
check()
PY

# ADR 0059 (M131c #2640): one dedicated base boot checkpoints the armed
# arm-virtiofs guest at the default boot-settle marker `tasks user-el0 reaped`,
# before any leg's workload (D4). The 16 script-only legs below restore it via
# --from-checkpoint qjs; their first --script-after is re-based onto the
# post-restore handshake (D5), while their later markers gate on the leg's own
# exec and re-occur inside the leg's epoch. The seven cold legs keep a
# `warm-cold:` comment naming their ADR D7 class.
vgate_checkpoint qjs --

vgate_run file --from-checkpoint qjs -- --script '$RUN_DIR/file.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90
vgate_run refused --from-checkpoint qjs -- --script '$RUN_DIR/refused.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90
vgate_run exact --from-checkpoint qjs -- --script '$RUN_DIR/exact.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90
vgate_run over --from-checkpoint qjs -- --script '$RUN_DIR/over.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90
vgate_run invalid --from-checkpoint qjs -- --script '$RUN_DIR/invalid.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90
vgate_run dense --from-checkpoint qjs -- --script '$RUN_DIR/dense.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90
vgate_run string --from-checkpoint qjs -- --script '$RUN_DIR/string.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90
vgate_run conversion --from-checkpoint qjs -- --script '$RUN_DIR/conversion.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90
vgate_run missing --from-checkpoint qjs -- --script '$RUN_DIR/missing.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90
vgate_run denied --from-checkpoint qjs -- --script '$RUN_DIR/denied.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90
vgate_run exists --from-checkpoint qjs -- --script '$RUN_DIR/exists.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90
vgate_run bounds --from-checkpoint qjs -- --script '$RUN_DIR/bounds.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90
# warm-cold: cold (d) cold-start sampling — qjs-cold: sample= x5 + --script2-delay measure launch latency; a timing budget formed across the freeze is uninterpretable post-restore (ADR 0059 D7(d))
vgate_run cold -- --script '$RUN_DIR/cold.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'procs QLAUNCH.BIN exited status=0' --script2-delay 2 --script-expect 'qjs-gate-done' --timeout 90
# warm-cold: repl,session,evals,diagnostics,receipt,eof (c) --console-tcp bridges a live host socket into serial input — listener/bridge state lives outside the checkpoint bundle (ADR 0059 D7(c))
vgate_run repl -- --console-tcp '127.0.0.1:24786' --timeout 180
vgate_run line --from-checkpoint qjs -- --script '$RUN_DIR/line.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/line-input.txt' --script2-after 'qjs: ready eval=0' --script3 '$RUN_DIR/after.txt' --script3-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90
vgate_run line-over --from-checkpoint qjs -- --script '$RUN_DIR/line-over.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/line-over-input.txt' --script2-after 'qjs: ready eval=0' --script3 '$RUN_DIR/after.txt' --script3-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90
vgate_run session -- --console-tcp '127.0.0.1:24787' --timeout 180
vgate_run evals -- --console-tcp '127.0.0.1:24788' --timeout 600
vgate_run diagnostics -- --console-tcp '127.0.0.1:24789' --timeout 180
vgate_run receipt -- --console-tcp '127.0.0.1:24790' --timeout 600
vgate_run eof -- --console-tcp '127.0.0.1:24791' --timeout 90
vgate_run idle --from-checkpoint qjs -- --script '$RUN_DIR/idle.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 100
vgate_run usage --from-checkpoint qjs -- --script '$RUN_DIR/usage.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'qjs-gate-done' --timeout 90

vgate_assert file serial-contains 'procs QJS.BIN exited status=0'
vgate_assert refused serial-contains 'procs QJS.BIN exited status=0'
vgate_assert exact serial-contains 'procs QJS.BIN exited status=0'
vgate_assert over serial-contains 'qjs: InputLimit'
vgate_assert invalid serial-contains 'qjs: InvalidUtf8'
vgate_assert dense serial-contains 'qjs: OutOfMemory'
vgate_assert string serial-contains 'qjs: clean'
vgate_assert conversion serial-contains 'qjs: ContextReset'
vgate_assert missing serial-contains 'qjs: FileNotFound'
vgate_assert denied serial-contains 'qjs: AccessDenied'
vgate_assert exists serial-exact 'ReceiptExists' 1
vgate_assert bounds serial-contains 'qjs-bounds: done'
vgate_assert cold serial-count 'qjs-cold: sample=' 5
vgate_assert repl serial-contains 'qjs: ContextReset'
vgate_assert line serial-contains 'qjs: quit'
vgate_assert line-over serial-contains 'qjs: LineLimit'
vgate_assert session serial-contains 'qjs: SessionLimit'
vgate_assert evals serial-contains 'qjs: SessionLimit'
vgate_assert diagnostics serial-contains 'qjs: DiagnosticLimit'
vgate_assert receipt serial-contains 'qjs: ReceiptLimit'
vgate_assert eof serial-contains 'qjs: quit'
vgate_assert idle serial-contains 'qjs: IdleLimit'
vgate_assert usage serial-exact 'Usage' 1

vgate_assert file python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert refused python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert exact python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert over python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert invalid python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert dense python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert string python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert conversion python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert missing python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert denied python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert exists python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert bounds python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert cold python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert repl python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert line python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert line-over python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert session python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert evals python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert diagnostics python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert receipt python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert eof python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert idle python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
vgate_assert usage python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check.py"))
PY
