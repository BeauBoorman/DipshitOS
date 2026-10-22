# live-bench.spec -- M119b (#2486): the benchmark corpus as a contract.
# Runs every corpus shape (tools/gate/bench/corpus.tsv) on VZ and fails on
# a breach of tools/gate/bench/budgets.tsv — every budget is baseline x
# named-margin measured on #2485. Each leg's python assert emits a
# `bench: id=... observed=... verdict=ok|breach|starved|sample` receipt
# line (`sample` = a recorded attempt measurement; the verdict-bearing
# check runs once per leg, on the direction-aware best of K attempt
# samples or the single attempt's value).
#
# TREND HISTORY (#2936): benchlib.check() — the single verdict choke
# point — also appends one row per verdict-bearing measurement to
# artifacts/bench/history.tsv (date, rev, host, id, value, budget,
# verdict; gitignored — per-host evidence, never the contract), and the
# final leg prints the `bench-check.py --trend` regression table.
#
# RETRY / SAMPLE POLICY (the card's call): a MEASUREMENT is never
# retried — a measured value is a sample, recorded in a receipt, never
# re-drawn for luck. Legs with an OBSERVED instability run K=3 attempts
# (smp{2,4}{a,b,c}, hfread{a,b,c}; M170f #3040 adds key{a,b,c} — the
# three-runtime seat leg samples K=3 per the card's best-of-K instruction,
# not an observed flake); the leg's verdict checks ONE aggregate
# — the direction-aware best sample (min for `<=`, max for `>=`: the
# corpus metric is an achievable bound and each baseline was itself a
# best-case observation; contention noise perturbs single samples, a real
# regression moves ALL of them, and best-still-breaches fails).
#   smp c2/c4: starvation-tolerant. The fixture's no-preemption placement
#     raciness (documented in live-smp-scale.spec) starved a run 1-in-2 on
#     #2485, and c2 spread 38M..83M ticks here. A no-metric attempt is
#     allowed ONLY on the signature: kernel seized + exec loaded + runner
#     timeout on --script-expect + no [EXC]; all-starved is a FAIL.
#   hf-read: variance-sampled. #2485 recorded 8.4 vs ~30 MB/s cross-host
#     and this card observed 4726 -> 2799 KiB/s same-shape intra-host —
#     a ~3x spread. NO starvation tolerance: a read that produces no
#     `goread: rate` in 300 s is a hang, not a flake (rc 1 not allowed).
#   smp c1: variance-sampled like hf-read (observed 72M then 157M ticks
#     on two same-shape boots here) but NOT starvation-tolerant: the
#     no-completion bounce needs >1 online core, so a no-metric attempt
#     is a hang and stays a hard FAIL.
# Every other leg is single-attempt: no metric there is a hard FAIL —
# extend the policy if starvation/variance is ever observed on them.
#
# FORCED-BREACH NEGATIVE (the card's second deliverable): set
# LIVE_BENCH_BUDGETS to a sabotaged budgets.tsv (e.g. inflate the hf-read
# `>=` row past any achievable rate) and the run must fail with a
# `verdict=breach` receipt naming the row. Recorded on #2486.
#
# HOST PREREQUISITE (not hermetic — tools/go/README.md):
# .build/go/{GOSH,GOSCALE,GOBIG,GOREAD,GOTABWM,GOSOUND,GOMBURST,GOCALC,
# GOTOP}.ELF; setup stages them into the seeded share and refuses when
# one is missing. TIMER.BIN rides the seeded zig-out bundle like every
# other .BIN (card #3036's jitter mode is its M170f consumer).

vgate_name live-bench "M119b: run the benchmark corpus on VZ, fail on budget breach"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

# --- the bench legs -----------------------------------------------------------
# boot-shell: `sysinfo` is the FIRST scripted command — the `uptime: ticks=`
# it reports is the boot-to-prompt wall in 1 Hz scheduler ticks.
vgate_file script-boot.txt <<'EOF'
sysinfo
echo bench-boot-done
EOF

# gosh-cmd: GOSH's own `time` builtin; `real N.NNs` is the program's line.
vgate_file script-goshls.txt <<'EOF'
exec GOSH.ELF -c "time ls"
EOF
vgate_file script-goshecho.txt <<'EOF'
exec GOSH.ELF -c "time echo bench-echo"
EOF

# hf-read: GOREAD.ELF drains the staged >8 MiB GOBIG.ELF at the kernel's
# 2048-B read cap and reports `goread: rate us <u> kib_s <k> ns_call <n>`.
vgate_file script-hfread.txt <<'EOF'
exec GOREAD.ELF /host/GOBIG.ELF
EOF

# pcm-drain: the synchronous submit+drain of `beep 440 300` on a --sound
# boot; the device-reported buffered bytes ride the `beep: tx` line.
vgate_file script-pcm.txt <<'EOF'
beep 440 300
EOF

# wm-present: the live-wm-pacing run 01 shape verbatim — that fleet run is
# the baseline the budgets were pinned from, so the bench measures the
# SAME shape: `wm` + `wnd start`, a kind-19 pointer burst over the cv-input
# queue (8 steps, 2.5 s), then a second `wm` dump after the burst lands.
vgate_file script-wm.txt <<'EOF'
wm
wnd start
EOF
vgate_file script-wm2.txt <<'EOF'
wm
echo pacing-done
EOF

# smp-scale: one exec per boot; the run ends on the program's own final
# `goscale: ticks=` line (phase B's raw CNTPCT delta around 100k units).
vgate_file script-smp.txt <<'EOF'
exec GOSCALE.ELF
EOF

vgate_file benchlib.py <<'PY'
"""live-bench shared helper — the python asserts import this from RUN_DIR.

Reads corpus.tsv + budgets.tsv (LIVE_BENCH_CORPUS / LIVE_BENCH_BUDGETS
env overrides — the forced-breach negative points the budgets override at
a sabotaged table), extracts each leg's metric from the serial log, and
prints the `bench:` receipt line. check() exits non-zero on a breach:
that nonzero exit is the assert failing, so the breach verdict is the
run's named failure, not a silent print.
"""
import importlib.util
import os
import re
import sys

# bench-check.py's hyphen keeps it out of import machinery — load it by
# path (the M119a parser; do not fork the TSV).
_bc_spec = importlib.util.spec_from_file_location(
    "bench_check", os.path.join("tools", "gate", "bench-check.py"))
bench_check = importlib.util.module_from_spec(_bc_spec)
_bc_spec.loader.exec_module(bench_check)


def tables():
    corpus_p = os.environ.get("LIVE_BENCH_CORPUS") or os.path.join(
        "tools", "gate", "bench", "corpus.tsv")
    budgets_p = os.environ.get("LIVE_BENCH_BUDGETS") or os.path.join(
        "tools", "gate", "bench", "budgets.tsv")
    errs = []
    _, crows = bench_check.parse_table(corpus_p, bench_check.CORPUS_COLS, errs)
    _, brows = bench_check.parse_table(budgets_p, bench_check.BUDGET_COLS, errs)
    if errs:
        sys.exit("bench: tables failed to parse: %s" % "; ".join(errs))
    return ({r["id"]: r for _, r in crows},
            {r["id"]: r for _, r in brows}, budgets_p)


def wm_field(ser, name):
    """The LAST `wm: rate` row is the post-burst one (the pre-`wnd start`
    row has no registered WM), exactly as live-wm-pacing reads it."""
    rows = [l for l in ser.splitlines() if "wm: rate window_ms=" in l]
    if not rows:
        return None
    m = re.search(name + r"=(\d+)", rows[-1])
    return float(m.group(1)) if m else None


def measure(row_id, ser):
    """Extract the corpus row's metric from a run's serial log; None when
    the instrument never reported (the starvation path)."""
    if row_id in ("wm-present-cadence", "wm-present-latency",
                  "seat-key-latency"):
        field = ("present_avg_ms" if row_id == "wm-present-cadence"
                 else "lat_max_us")
        return wm_field(ser, field)
    patterns = {
        "boot-shell": r"uptime:\s+ticks=(\d+)",
        "gosh-cmd-ls": r"(?m)^real (\d+\.\d+)s\r?$",
        "gosh-cmd-echo": r"(?m)^real (\d+\.\d+)s\r?$",
        "hf-read": r"goread: rate us \d+ kib_s (\d+) ns_call \d+",
        "pcm-drain": r"beep: tx submitted=\d+ drained=\d+ frames=\d+"
                     r" pcm_status=0x[0-9a-fA-F]+ latency=(\d+)",
        "smp-scale-c1": r"goscale: ticks=(\d+)",
        "smp-scale-c2": r"goscale: ticks=(\d+)",
        "smp-scale-c4": r"goscale: ticks=(\d+)",
        "seat-mbox-burst": r"mburst: accepted=(\d+) of \d+ refused=\d+",
        "go-rss": r"top: row pid=\d+ name=GOCALC\.ELF .* mem=(\d+)",
        "timer-jitter": r"timertest: jitter n=\d+ max_late_us=(\d+)",
    }
    found = re.findall(patterns[row_id], ser)
    if not found:
        return None
    return float(found[-1])


def _num(x):
    return ("%g" % x)


def receipt(row_id, observed, verdict, run=None):
    cmap, bmap, bpath = tables()
    unit = cmap.get(row_id, {}).get("unit", "?")
    b = bmap.get(row_id, {})
    print("bench: id=%s%s observed=%s %s cmp=%s budget=%s baseline=%s "
          "margin=%s ref=%s verdict=%s"
          % (row_id, (" run=" + run) if run else "", _num(observed)
             if observed is not None else "none", unit, b.get("cmp", "?"),
             b.get("budget", "?"), b.get("baseline", "?"),
             b.get("margin", "?"), b.get("ref", "?"), verdict))


def check(row_id, observed):
    """The verdict for one measured value; a breach is the named failure."""
    _, bmap, bpath = tables()
    b = bmap.get(row_id)
    if b is None:
        sys.exit("bench: no budget row for %s in %s" % (row_id, bpath))
    budget = float(b["budget"])
    ok = observed <= budget if b["cmp"] == "<=" else observed >= budget
    verdict = "ok" if ok else "breach"
    receipt(row_id, observed, verdict)
    bench_check.append_history(row_id, observed, b["budget"], verdict)
    if not ok:
        sys.exit("bench: BREACH id=%s observed=%s budget=%s%s "
                 "(baseline=%s margin=%s ref=%s) — a measurement is never "
                 "retried; re-measure and re-pin on the issue"
                 % (row_id, _num(observed), b["cmp"], b["budget"],
                    b["baseline"], b["margin"], b["ref"]))


def starved(row_id, tag):
    """Tolerated no-measurement, ONLY on the documented signature: the
    runner itself must have timed out on --script-expect (any other rc=1
    is a different failure and stays one)."""
    out_p = os.path.join(os.environ["RUN_DIR"], "run-%s.out" % tag)
    out = ""
    if os.path.exists(out_p):
        out = open(out_p, errors="replace").read()
    if "FAILURE: requested evidence not observed" not in out:
        sys.exit("bench: id=%s produced no metric AND the runner did not "
                 "time out on the metric marker — this is not the "
                 "documented starvation path, it is a different failure"
                 % row_id)
    receipt(row_id, None, "starved", run=tag)


def leg_verdict(row_id, samples):
    """The verdict for a K-attempt leg: the direction-aware BEST of the
    measured samples (min for a `<=` bound, max for a `>=` bound — the
    corpus metric is an achievable bound and each baseline was itself a
    best-case observation), then the budget check. samples=[] fails: the
    leg owes at least one real measurement."""
    if not samples:
        sys.exit("bench: id=%s produced no measurement in ANY attempt — "
                 "the retry policy is exhausted and the leg owes one"
                 % row_id)
    _, bmap, _ = tables()
    cmp_ = bmap.get(row_id, {}).get("cmp", "<=")
    best = min(samples) if cmp_ == "<=" else max(samples)
    print("bench: leg id=%s samples=%r best=%d (cmp %s picks %s)"
          % (row_id, [int(v) for v in samples], best, cmp_,
             "min" if cmp_ == "<=" else "max"))
    check(row_id, float(best))


def trend(last=10):
    """The end-of-run regression table (#2936): bench-check.py --trend
    over artifacts/bench/history.tsv, joined against the SAME corpus and
    budgets this run enforced (the LIVE_BENCH_* overrides included — a
    sabotaged-budgets run trends against the sabotage). Informational:
    a DRIFTING/OVER-BUDGET flag is the warning, never the failure — a
    breach already failed where it measured."""
    corpus_p = os.environ.get("LIVE_BENCH_CORPUS") or os.path.join(
        "tools", "gate", "bench", "corpus.tsv")
    budgets_p = os.environ.get("LIVE_BENCH_BUDGETS") or os.path.join(
        "tools", "gate", "bench", "budgets.tsv")
    rc = bench_check.print_trend(bench_check.DEFAULT_HISTORY,
                                 budgets_p, corpus_p, last)
    if rc != 0:
        sys.exit("bench: trend table could not print (rc=%d)" % rc)
PY

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
need = {
    "GOSH.ELF": "bash tools/go/build-gosh.sh",
    "GOSCALE.ELF": "bash tools/go/build-go.sh tools/go/smpscale.go",
    "GOBIG.ELF": "bash tools/go/build-go.sh tools/go/gobig.go",
    "GOREAD.ELF": "bash tools/go/build-go.sh tools/go/goread.go",
    "GOTABWM.ELF": "bash tools/go/build-gotabwm.sh",
    "GOSOUND.ELF": "bash tools/go/build-gosound.sh",
    "GOMBURST.ELF": "bash tools/go/build-go.sh tools/go/mburst.go",
    "GOCALC.ELF": "bash tools/go/build-gocalc.sh",
    "GOTOP.ELF": "bash tools/go/build-gotop.sh",
}
missing = [n for n in need if not os.path.exists(os.path.join(".build", "go", n))]
if missing:
    sys.exit("%s missing — build the fork fixtures first (%s; fork "
             "prerequisites in tools/go/README.md)"
             % (", ".join(missing), "; ".join(sorted(set(need[m] for m in missing)))))
for n in need:
    src = os.path.join(".build", "go", n)
    shutil.copy(src, os.path.join(share, n))
    print("staged %s into share (%d bytes)" % (n, os.path.getsize(src)))
# The wm leg's trace flag — same armed-share fixture live-wm-pacing run 01
# (the baseline source) carries.
with open(os.path.join(share, "M91-PRESENTATION.TRACE"), "w") as f:
    f.write("v1\n")
# The seat-mbox leg (M119c): the seat boots from the script, so the kernel
# must never autostart it — same wm=none pinning live-sound-playback's
# wav-toast carries once GOTABWM sits in the share.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
# Its sustained-PCM source: the same 3 s 44.1 kHz s16 TONE.WAV
# live-sound-playback stages (a real stream, not a beep stub).
import math, struct
d = os.path.join(share, "SND")
os.makedirs(d, exist_ok=True)
rate, frames = 44100, 132300
data = bytearray()
for i in range(frames):
    v = int(0.2 * 32767 * math.sin(2 * math.pi * 440 * i / rate))
    data += struct.pack("<hh", v, v)
hdr = (b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE" +
       b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, rate, rate * 4, 4, 16) +
       b"data" + struct.pack("<I", len(data)))
with open(os.path.join(d, "TONE.WAV"), "wb") as f:
    f.write(hdr + data)
print("staged SND/TONE.WAV (%d bytes)" % (len(hdr) + len(data)))
PY

# --- run 01: boot-shell -------------------------------------------------------
vgate_run boot -- --script '$RUN_DIR/script-boot.txt' \
    --script-expect 'bench-boot-done' --timeout 60

vgate_assert boot serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert boot serial-contains 'uptime:     ticks='
vgate_assert boot serial-absent '[EXC]'
vgate_assert boot python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("boot-shell", ser)
if v is None:
    sys.exit("bench: no `uptime: ticks=` marker — sysinfo never reported")
benchlib.check("boot-shell", v)
PY

# --- runs 02/03: gosh-cmd -----------------------------------------------------
vgate_run goshls -- --script '$RUN_DIR/script-goshls.txt' \
    --script-expect 'real ' --timeout 120

vgate_assert goshls serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert goshls serial-contains 'exec: loaded GOSH.ELF'
vgate_assert goshls serial-absent '[EXC]'
vgate_assert goshls python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("gosh-cmd-ls", ser)
if v is None:
    sys.exit("bench: no `real N.NNs` line — the timed command never reported")
benchlib.check("gosh-cmd-ls", v)
PY

vgate_run goshecho -- --script '$RUN_DIR/script-goshecho.txt' \
    --script-expect 'real ' --timeout 120

vgate_assert goshecho serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert goshecho serial-contains 'exec: loaded GOSH.ELF'
vgate_assert goshecho serial-absent '[EXC]'
vgate_assert goshecho serial-absent 'bench-echo: not found'
vgate_assert goshecho python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("gosh-cmd-echo", ser)
if v is None:
    sys.exit("bench: no `real N.NNs` line — the timed command never reported")
benchlib.check("gosh-cmd-echo", v)
PY

# --- runs 04a-c: hf-read (K=3 variance samples) -------------------------------
# Observed intra-host spread on this channel is ~3x (#2485 recorded 8.4
# MB/s vs ~30 MB/s cross-host; this card observed 4726 -> 2799 KiB/s on
# two same-shape boots), so the leg samples K=3 and the verdict is the
# direction-aware best (max — the bound is `>=`). NO starvation tolerance
# here: unlike the smp fixture there is no documented no-completion
# mechanism for a read — an attempt that produces no `goread: rate`
# inside its timeout is a hang and stays a hard FAIL (rc 1 not allowed).
vgate_run hfreada -- --script '$RUN_DIR/script-hfread.txt' \
    --script-expect 'goread: GOREAD OK' --timeout 300
vgate_run hfreadb -- --script '$RUN_DIR/script-hfread.txt' \
    --script-expect 'goread: GOREAD OK' --timeout 300
vgate_run hfreadc -- --script '$RUN_DIR/script-hfread.txt' \
    --script-expect 'goread: GOREAD OK' --timeout 300

vgate_assert hfreada serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert hfreada serial-contains 'exec: loaded GOREAD.ELF'
vgate_assert hfreada serial-absent 'goread: FAIL'
vgate_assert hfreada serial-absent '[EXC]'
vgate_assert hfreada python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("hf-read", ser)
if v is None:
    sys.exit("bench: no `goread: rate` line — a hung read is a bug, "
             "not a retryable flake")
benchlib.receipt("hf-read", v, "sample", run=os.environ["VG_TAG"])
PY

vgate_assert hfreadb serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert hfreadb serial-contains 'exec: loaded GOREAD.ELF'
vgate_assert hfreadb serial-absent 'goread: FAIL'
vgate_assert hfreadb serial-absent '[EXC]'
vgate_assert hfreadb python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("hf-read", ser)
if v is None:
    sys.exit("bench: no `goread: rate` line — a hung read is a bug, "
             "not a retryable flake")
benchlib.receipt("hf-read", v, "sample", run=os.environ["VG_TAG"])
PY

vgate_assert hfreadc serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert hfreadc serial-contains 'exec: loaded GOREAD.ELF'
vgate_assert hfreadc serial-absent 'goread: FAIL'
vgate_assert hfreadc serial-absent '[EXC]'
vgate_assert hfreadc python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("hf-read", ser)
if v is None:
    sys.exit("bench: no `goread: rate` line — a hung read is a bug, "
             "not a retryable flake")
benchlib.receipt("hf-read", v, "sample", run=os.environ["VG_TAG"])
PY
vgate_assert hfreadc python <<'PY'
import glob, os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
samples = []
for p in sorted(glob.glob(os.path.join(os.environ["RUN_DIR"],
                                       "vm-serial-hfread*.log"))):
    v = benchlib.measure("hf-read",
                         open(p, errors="replace").read())
    if v is not None:
        samples.append(v)
benchlib.leg_verdict("hf-read", samples)
PY

# --- run 05: pcm-drain --------------------------------------------------------
vgate_run pcm -- --sound --script '$RUN_DIR/script-pcm.txt' \
    --script-expect 'beep: ok' --timeout 150

vgate_assert pcm serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert pcm output-contains 'SOUND: virtio-snd attached'
vgate_assert pcm serial-contains 'beep: tx submitted='
vgate_assert pcm serial-absent '[EXC]'
vgate_assert pcm python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("pcm-drain", ser)
if v is None:
    sys.exit("bench: no `beep: tx ... latency=` line — the drain never reported")
benchlib.check("pcm-drain", v)
PY

# --- run 06: wm-present (cadence + latency rows off one boot) -----------------
vgate_run wm -- --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-wm.txt' \
    --pointer-virtio '180,180;340,180;500,180;660,180;820,180;180,360;340,360;500,360' \
    --pointer-virtio-after 'wnd: registered' \
    --script2 '$RUN_DIR/script-wm2.txt' --script2-after 'wnd: registered' --script2-delay 30 \
    --script-expect 'pacing-done' --timeout 260

vgate_assert wm serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert wm serial-contains 'wnd: registered'
vgate_assert wm serial-contains 'wm: registered pid='
vgate_assert wm serial-contains 'wm: rate window_ms='
vgate_assert wm serial-contains 'pacing-done'
vgate_assert wm serial-absent '[EXC]'
vgate_assert wm serial-absent 'm91: trace ERROR'
vgate_assert wm python <<'PY'
import os, re, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()

# Sanity floor — the measurement must be REAL before budgets apply: the
# injected burst landed (ptr_fan >= 4), presents actually happened, and at
# least one input->present latency sample exists. Same floor the baseline
# fleet run asserted in live-wm-pacing.
rows = [l for l in ser.splitlines() if "wm: rate window_ms=" in l]
if not rows:
    sys.exit("bench: no `wm: rate` row — the instrument never printed")
last = rows[-1]
def field(name):
    m = re.search(name + r"=(\d+)", last)
    if not m:
        sys.exit("bench: field %s missing from %s" % (name, last))
    return int(m.group(1))
if field("flush_n") < 2:
    sys.exit("bench: fewer than two presents — no cadence to measure")
if field("lat_n") < 1:
    sys.exit("bench: no input->present latency sample was recorded")
fan = [l for l in ser.splitlines() if "wm: ptr_fan=" in l]
if not fan or int(re.search(r"ptr_fan=(\d+)", fan[-1]).group(1)) < 4:
    sys.exit("bench: the injected pointer burst never landed")

for row_id in ("wm-present-cadence", "wm-present-latency"):
    v = benchlib.measure(row_id, ser)
    if v is None:
        sys.exit("bench: no %s field in the wm: rate row" % row_id)
    benchlib.check(row_id, v)
PY

# --- smp-scale legs -----------------------------------------------------------
# c1: K=3 variance samples, no starvation tolerance — the no-completion
# mechanism (the fixture's racy cross-core placement) needs >1 online
# core, so a no-metric c1 attempt is a hang and stays a hard FAIL.
vgate_run smp1a -- --cpus 1 --script '$RUN_DIR/script-smp.txt' \
    --script-expect 'goscale: ticks=' --timeout 240
vgate_run smp1b -- --cpus 1 --script '$RUN_DIR/script-smp.txt' \
    --script-expect 'goscale: ticks=' --timeout 240
vgate_run smp1c -- --cpus 1 --script '$RUN_DIR/script-smp.txt' \
    --script-expect 'goscale: ticks=' --timeout 240

vgate_assert smp1a serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert smp1a serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert smp1a serial-absent '[EXC]'
vgate_assert smp1a python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("smp-scale-c1", ser)
if v is None:
    sys.exit("bench: no `goscale: ticks=` line — a hung program is a bug, "
             "not a retryable flake")
benchlib.receipt("smp-scale-c1", v, "sample", run=os.environ["VG_TAG"])
PY

vgate_assert smp1b serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert smp1b serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert smp1b serial-absent '[EXC]'
vgate_assert smp1b python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("smp-scale-c1", ser)
if v is None:
    sys.exit("bench: no `goscale: ticks=` line — a hung program is a bug, "
             "not a retryable flake")
benchlib.receipt("smp-scale-c1", v, "sample", run=os.environ["VG_TAG"])
PY

vgate_assert smp1c serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert smp1c serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert smp1c serial-absent '[EXC]'
vgate_assert smp1c python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("smp-scale-c1", ser)
if v is None:
    sys.exit("bench: no `goscale: ticks=` line — a hung program is a bug, "
             "not a retryable flake")
benchlib.receipt("smp-scale-c1", v, "sample", run=os.environ["VG_TAG"])
PY
vgate_assert smp1c python <<'PY'
import glob, os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
samples = []
for p in sorted(glob.glob(os.path.join(os.environ["RUN_DIR"],
                                       "vm-serial-smp1*.log"))):
    v = benchlib.measure("smp-scale-c1",
                         open(p, errors="replace").read())
    if v is not None:
        samples.append(v)
benchlib.leg_verdict("smp-scale-c1", samples)
PY

# c2/c4: K=3 starvation attempts each (see the RETRY / SAMPLE POLICY in
# the header). A measured attempt records a `sample` receipt (not a
# verdict — samples are never individually budget-checked); a no-metric
# attempt is tolerated ONLY on the documented starvation signature. The
# leg's verdict is the budget check over the direction-aware BEST of its
# samples, run on the c-attempt's cross-scan of every attempt's serial.
vgate_run smp2a -- --cpus 2 --script '$RUN_DIR/script-smp.txt' \
    --script-expect 'goscale: ticks=' --timeout 240
vgate_allow_rc smp2a 0 1
vgate_run smp2b -- --cpus 2 --script '$RUN_DIR/script-smp.txt' \
    --script-expect 'goscale: ticks=' --timeout 240
vgate_allow_rc smp2b 0 1
vgate_run smp2c -- --cpus 2 --script '$RUN_DIR/script-smp.txt' \
    --script-expect 'goscale: ticks=' --timeout 240
vgate_allow_rc smp2c 0 1

vgate_run smp4a -- --cpus 4 --script '$RUN_DIR/script-smp.txt' \
    --script-expect 'goscale: ticks=' --timeout 240
vgate_allow_rc smp4a 0 1
vgate_run smp4b -- --cpus 4 --script '$RUN_DIR/script-smp.txt' \
    --script-expect 'goscale: ticks=' --timeout 240
vgate_allow_rc smp4b 0 1
vgate_run smp4c -- --cpus 4 --script '$RUN_DIR/script-smp.txt' \
    --script-expect 'goscale: ticks=' --timeout 240
vgate_allow_rc smp4c 0 1

# Per-attempt asserts. `exec: loaded` stays required on every attempt — a
# starved attempt still proves the boot+exec landed before it is allowed
# to count as the documented flake (a program that never LOADED is a
# different failure and stays red).
vgate_assert smp2a serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert smp2a serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert smp2a serial-absent '[EXC]'
vgate_assert smp2a python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("smp-scale-c2", ser)
if v is None:
    benchlib.starved("smp-scale-c2", os.environ["VG_TAG"])
else:
    benchlib.receipt("smp-scale-c2", v, "sample", run=os.environ["VG_TAG"])
PY

vgate_assert smp2b serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert smp2b serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert smp2b serial-absent '[EXC]'
vgate_assert smp2b python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("smp-scale-c2", ser)
if v is None:
    benchlib.starved("smp-scale-c2", os.environ["VG_TAG"])
else:
    benchlib.receipt("smp-scale-c2", v, "sample", run=os.environ["VG_TAG"])
PY

vgate_assert smp2c serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert smp2c serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert smp2c serial-absent '[EXC]'
vgate_assert smp2c python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("smp-scale-c2", ser)
if v is None:
    benchlib.starved("smp-scale-c2", os.environ["VG_TAG"])
else:
    benchlib.receipt("smp-scale-c2", v, "sample", run=os.environ["VG_TAG"])
PY
# Leg verdict on the c-attempt: min over every attempt's serial samples;
# all-starved fails. Samples are recorded, never individually checked.
vgate_assert smp2c python <<'PY'
import glob, os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
samples = []
for p in sorted(glob.glob(os.path.join(os.environ["RUN_DIR"],
                                       "vm-serial-smp2*.log"))):
    v = benchlib.measure("smp-scale-c2",
                         open(p, errors="replace").read())
    if v is not None:
        samples.append(v)
benchlib.leg_verdict("smp-scale-c2", samples)
PY

vgate_assert smp4a serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert smp4a serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert smp4a serial-absent '[EXC]'
vgate_assert smp4a python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("smp-scale-c4", ser)
if v is None:
    benchlib.starved("smp-scale-c4", os.environ["VG_TAG"])
else:
    benchlib.receipt("smp-scale-c4", v, "sample", run=os.environ["VG_TAG"])
PY

vgate_assert smp4b serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert smp4b serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert smp4b serial-absent '[EXC]'
vgate_assert smp4b python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("smp-scale-c4", ser)
if v is None:
    benchlib.starved("smp-scale-c4", os.environ["VG_TAG"])
else:
    benchlib.receipt("smp-scale-c4", v, "sample", run=os.environ["VG_TAG"])
PY

vgate_assert smp4c serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert smp4c serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert smp4c serial-absent '[EXC]'
vgate_assert smp4c python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("smp-scale-c4", ser)
if v is None:
    benchlib.starved("smp-scale-c4", os.environ["VG_TAG"])
else:
    benchlib.receipt("smp-scale-c4", v, "sample", run=os.environ["VG_TAG"])
PY
vgate_assert smp4c python <<'PY'
import glob, os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
samples = []
for p in sorted(glob.glob(os.path.join(os.environ["RUN_DIR"],
                                       "vm-serial-smp4*.log"))):
    v = benchlib.measure("smp-scale-c4",
                         open(p, errors="replace").read())
    if v is not None:
        samples.append(v)
benchlib.leg_verdict("smp-scale-c4", samples)
PY

# --- run 07: seat-mbox (M119c #2487) ------------------------------------------
# The M99 wav-toast starvation was the seat's 8-deep IPC mailbox refusing
# client posts with ENOSPC while the seat was stalled draining an input
# burst under sustained PCM — a post that never lands can never service
# (the notify toast died here; pending high-water measured 7/8 on a
# healthy run, one slot from the loss). This leg reproduces the pressure
# deterministically: the seat streams PCM while GOMBURST posts 40
# WM-RPC-shaped frames back-to-back, and a concurrently-draining seat
# clears at most one serviceRPC pass during the burst. `accepted` lands
# on the ring bound: <= 8+8 on the pre-fix kernel, >= 32 on the fix —
# the budget separates them by construction, so the leg is red before
# the raise and green after it. No retry: a measurement is never one.
vgate_file script-mburst-seat.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF
vgate_file script-mburst-stream.txt <<'EOF'
set GOMAXPROCS=1
exec GOSOUND.ELF /host/SND/TONE.WAV
EOF
vgate_file script-mburst-post.txt <<'EOF'
set GOMAXPROCS=1
exec GOMBURST.ELF
EOF

# --- run 08: app-launch (card #3042: app-launch-cold + go-rss) ---------------
# One windowed boot carries both new rows. `sysinfo` runs immediately before
# `exec GOCALC.ELF` (uptime T0); a second `sysinfo` rides script2, forwarded
# the moment the app's own first window marker `gocalc: open id=` lands in
# the serial log (uptime T1). T1-T0 in 1 Hz ticks is the launch measure,
# honestly carrying the runner's ~0.5 s marker poll + forward settle — a
# floor-resolution bound like boot-shell's, not a stopwatch. ~4 s after
# `gocalc: present` script3 execs GOTOP.ELF; its startup listing prints the
# sys_procs v2 snapshot row for the idled app (`top: row ... mem=<bytes>`).
vgate_file script-launch.txt <<'EOF'
sysinfo
exec GOCALC.ELF
EOF
vgate_file script-launch-t1.txt <<'EOF'
sysinfo
EOF
vgate_file script-launch-rss.txt <<'EOF'
exec GOTOP.ELF
EOF

vgate_run launch -- --screen '$RUN_DIR/launch-screen' --via-virtio \
    --script '$RUN_DIR/script-launch.txt' \
    --script2 '$RUN_DIR/script-launch-t1.txt' \
    --script2-after 'gocalc: open id=' --script2-delay 0 \
    --script3 '$RUN_DIR/script-launch-rss.txt' \
    --script3-after 'gocalc: present' --script3-delay 4 \
    --script-expect 'top: ready' --timeout 240

vgate_assert launch serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert launch serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert launch serial-contains 'gocalc: open id='
vgate_assert launch serial-contains 'gocalc: present'
vgate_assert launch serial-contains 'exec: loaded GOTOP.ELF'
vgate_assert launch serial-contains 'top: ready'
vgate_assert launch serial-absent '[EXC]'
vgate_assert launch python <<'PY'
import os, re, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
ticks = re.findall(r"uptime:\s+ticks=(\d+)", ser)
if len(ticks) < 2:
    sys.exit("bench: expected the two scripted `sysinfo` reads "
             "(pre-exec and post-`gocalc: open id=`), found %d" % len(ticks))
# The marker-forwarded sysinfo must actually land after the app's open
# marker, else the delta measures nothing — order-checked, not assumed.
if ser.find("gocalc: open id=") == -1 or \
   ser.rfind("uptime:") < ser.find("gocalc: open id="):
    sys.exit("bench: the second `sysinfo` did not land after `gocalc: open id=`")
v = float(int(ticks[-1]) - int(ticks[0]))
benchlib.check("app-launch-cold", v)
PY
vgate_assert launch python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("go-rss", ser)
if v is None:
    sys.exit("bench: no `top: row ... name=GOCALC.ELF ... mem=` line — "
             "GOTOP's startup listing never reported the app's resident set")
benchlib.check("go-rss", v)
PY

vgate_run mburst -- --sound --screen '$RUN_DIR/mburst-screen' --via-virtio \
    --script '$RUN_DIR/script-mburst-seat.txt' \
    --script2 '$RUN_DIR/script-mburst-stream.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-mburst-post.txt' \
    --script3-after 'gosound: streaming gen=' \
    --script-expect 'mburst: done' --timeout 240

vgate_assert mburst serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert mburst serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert mburst serial-contains 'gotabwm: holding seat'
vgate_assert mburst serial-contains 'gosound: streaming gen='
vgate_assert mburst serial-contains 'exec: loaded GOMBURST.ELF'
vgate_assert mburst serial-contains 'mburst: accepted='
vgate_assert mburst serial-contains 'mburst: done'
vgate_assert mburst serial-absent 'mburst: FAIL'
vgate_assert mburst serial-absent '[EXC]'
vgate_assert mburst python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("seat-mbox-burst", ser)
if v is None:
    sys.exit("bench: no `mburst: accepted=` line — the burst never reported")
benchlib.check("seat-mbox-burst", v)
PY

# --- run 09: timer-jitter (M170f #3040) -------------------------------------
# TIMER.BIN's jitter argv mode (card #3036): 20 sequential 10 ms arms on
# the deadline overlay (slot 95, ADR 0060 D2's 1 ms quantum), each blocked
# on its TIMER event; the summary's `max_late_us` is the worst IRQ-side
# lateness — the overlay's own number, not the heartbeat's. Single attempt
# like every leg without an observed instability: a missing summary line
# means the exec never ran, not a flake to retry.
vgate_file script-jitter.txt <<'EOF'
exec TIMER.BIN jitter 20
EOF
vgate_run jitter -- --script '$RUN_DIR/script-jitter.txt' \
    --script-expect 'timertest: jitter n=20' --timeout 120

vgate_assert jitter serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert jitter serial-contains 'exec: loaded TIMER.BIN'
vgate_assert jitter serial-contains 'timertest: jitter n=20'
vgate_assert jitter serial-absent '[EXC]'
vgate_assert jitter python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
v = benchlib.measure("timer-jitter", ser)
if v is None:
    sys.exit("bench: no `timertest: jitter ... max_late_us=` line — "
             "the sweep never reported")
benchlib.check("timer-jitter", v)
PY

# --- runs 10a-c: seat-key (M170f #3040, K=3 samples) -------------------------
# GOTABWM + GOCALC + GOSOUND = three Go runtimes — the seat envelope's
# proven ceiling (docs/testing.md's three-runtime bound). The runner types
# `1,+,2,=` over the cv-input queue after `gocalc: present` (0.25 s/stroke,
# the transport's fixed pace): each key-down is a fanned input sample
# (wm_server.fan_key -> note_input) and the seat's REQUEST_PRESENT closes
# it, so the `wm` row's lat_max_us is the worst keystroke-to-present of
# the burst — card #3034's damage tick is the thing this number proves.
# The `wm` dump rides script3 anchored on `gocalc: result 1+2=3` — a
# marker that only exists after the burst landed — plus a settle delay so
# the result's own repaint has presented and closed its sample. K=3
# samples per the card's best-of-K instruction (same verdict shape as
# hf-read: best-of-K min for a `<=` bound, no starvation tolerance — a
# boot whose keys never land is a failure, not a flake).
# Script layout: GOSOUND execs in script1 (its tab opens while the seat
# comes up — or windowless if its declare lands before registration, the
# PCM pump does not care); GOCALC execs in script2 ONLY after
# 'gosound: streaming gen=' — so Calc is always the LAST tab to bind and
# deterministically holds focus when the chords type. Exec'ing both in
# one burst lost the race on-card (Sound Player bound last 1-in-3 and ate
# the burst; 'gocalc: result' never landed).
vgate_file script-key-seat.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
exec GOSOUND.ELF /host/SND/TONE.WAV
EOF
vgate_file script-key-load.txt <<'EOF'
set GOMAXPROCS=1
exec GOCALC.ELF
EOF
vgate_file script-key-dump.txt <<'EOF'
wm
echo keylat-done
EOF

vgate_run keya -- --sound --screen '$RUN_DIR/keya-screen' --via-virtio \
    --script '$RUN_DIR/script-key-seat.txt' \
    --script2 '$RUN_DIR/script-key-load.txt' \
    --script2-after 'gosound: streaming gen=' \
    --input-chords '1,+,2,=' \
    --input-chords-after 'gocalc: present' \
    --script3 '$RUN_DIR/script-key-dump.txt' \
    --script3-after 'gocalc: result 1+2=3' --script3-delay 2 \
    --script-expect 'keylat-done' --timeout 240
vgate_run keyb -- --sound --screen '$RUN_DIR/keyb-screen' --via-virtio \
    --script '$RUN_DIR/script-key-seat.txt' \
    --script2 '$RUN_DIR/script-key-load.txt' \
    --script2-after 'gosound: streaming gen=' \
    --input-chords '1,+,2,=' \
    --input-chords-after 'gocalc: present' \
    --script3 '$RUN_DIR/script-key-dump.txt' \
    --script3-after 'gocalc: result 1+2=3' --script3-delay 2 \
    --script-expect 'keylat-done' --timeout 240
vgate_run keyc -- --sound --screen '$RUN_DIR/keyc-screen' --via-virtio \
    --script '$RUN_DIR/script-key-seat.txt' \
    --script2 '$RUN_DIR/script-key-load.txt' \
    --script2-after 'gosound: streaming gen=' \
    --input-chords '1,+,2,=' \
    --input-chords-after 'gocalc: present' \
    --script3 '$RUN_DIR/script-key-dump.txt' \
    --script3-after 'gocalc: result 1+2=3' --script3-delay 2 \
    --script-expect 'keylat-done' --timeout 240

vgate_assert keya serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert keya serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert keya serial-contains 'gotabwm: holding seat'
vgate_assert keya serial-contains 'gosound: streaming gen='
vgate_assert keya serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert keya serial-contains 'gocalc: present'
vgate_assert keya serial-contains 'gocalc: result 1+2=3'
vgate_assert keya serial-contains 'keylat-done'
vgate_assert keya serial-absent '[EXC]'
vgate_assert keya python <<'PY'
import os, re, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
# The burst must have LANDED for the measurement to mean anything: keys
# fanned to the seat, and at least one input->present sample answered.
rows = [l for l in ser.splitlines() if "wm: rate window_ms=" in l]
if not rows:
    sys.exit("bench: no `wm: rate` row — the instrument never printed")
last = rows[-1]
def field(name):
    m = re.search(name + r"=(\d+)", last)
    if not m:
        sys.exit("bench: field %s missing from %s" % (name, last))
    return int(m.group(1))
if field("lat_n") < 1:
    sys.exit("bench: no input->present latency sample was recorded")
fan = [l for l in ser.splitlines() if "wm: ptr_fan=" in l]
if not fan:
    sys.exit("bench: no `wm: ptr_fan=` row — the input seam never reported")
kf = re.search(r"key_fan=(\d+)", fan[-1])
if not kf or int(kf.group(1)) < 4:
    sys.exit("bench: fewer than 4 key samples fanned — the typed burst "
             "did not land: %s" % fan[-1])
v = benchlib.measure("seat-key-latency", ser)
if v is None:
    sys.exit("bench: no lat_max_us field in the wm: rate row")
benchlib.receipt("seat-key-latency", v, "sample", run=os.environ["VG_TAG"])
PY

vgate_assert keyb serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert keyb serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert keyb serial-contains 'gotabwm: holding seat'
vgate_assert keyb serial-contains 'gosound: streaming gen='
vgate_assert keyb serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert keyb serial-contains 'gocalc: present'
vgate_assert keyb serial-contains 'gocalc: result 1+2=3'
vgate_assert keyb serial-contains 'keylat-done'
vgate_assert keyb serial-absent '[EXC]'
vgate_assert keyb python <<'PY'
import os, re, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
rows = [l for l in ser.splitlines() if "wm: rate window_ms=" in l]
if not rows:
    sys.exit("bench: no `wm: rate` row — the instrument never printed")
last = rows[-1]
def field(name):
    m = re.search(name + r"=(\d+)", last)
    if not m:
        sys.exit("bench: field %s missing from %s" % (name, last))
    return int(m.group(1))
if field("lat_n") < 1:
    sys.exit("bench: no input->present latency sample was recorded")
fan = [l for l in ser.splitlines() if "wm: ptr_fan=" in l]
if not fan:
    sys.exit("bench: no `wm: ptr_fan=` row — the input seam never reported")
kf = re.search(r"key_fan=(\d+)", fan[-1])
if not kf or int(kf.group(1)) < 4:
    sys.exit("bench: fewer than 4 key samples fanned — the typed burst "
             "did not land: %s" % fan[-1])
v = benchlib.measure("seat-key-latency", ser)
if v is None:
    sys.exit("bench: no lat_max_us field in the wm: rate row")
benchlib.receipt("seat-key-latency", v, "sample", run=os.environ["VG_TAG"])
PY

vgate_assert keyc serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert keyc serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert keyc serial-contains 'gotabwm: holding seat'
vgate_assert keyc serial-contains 'gosound: streaming gen='
vgate_assert keyc serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert keyc serial-contains 'gocalc: present'
vgate_assert keyc serial-contains 'gocalc: result 1+2=3'
vgate_assert keyc serial-contains 'keylat-done'
vgate_assert keyc serial-absent '[EXC]'
vgate_assert keyc python <<'PY'
import os, re, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
ser = open(os.environ["VG_SER"], errors="replace").read()
rows = [l for l in ser.splitlines() if "wm: rate window_ms=" in l]
if not rows:
    sys.exit("bench: no `wm: rate` row — the instrument never printed")
last = rows[-1]
def field(name):
    m = re.search(name + r"=(\d+)", last)
    if not m:
        sys.exit("bench: field %s missing from %s" % (name, last))
    return int(m.group(1))
if field("lat_n") < 1:
    sys.exit("bench: no input->present latency sample was recorded")
fan = [l for l in ser.splitlines() if "wm: ptr_fan=" in l]
if not fan:
    sys.exit("bench: no `wm: ptr_fan=` row — the input seam never reported")
kf = re.search(r"key_fan=(\d+)", fan[-1])
if not kf or int(kf.group(1)) < 4:
    sys.exit("bench: fewer than 4 key samples fanned — the typed burst "
             "did not land: %s" % fan[-1])
v = benchlib.measure("seat-key-latency", ser)
if v is None:
    sys.exit("bench: no lat_max_us field in the wm: rate row")
benchlib.receipt("seat-key-latency", v, "sample", run=os.environ["VG_TAG"])
PY
# Leg verdict on the c-attempt: direction-aware best (min — the bound is
# `<=`) over every attempt's lat_max_us sample, then the budget check.
vgate_assert keyc python <<'PY'
import glob, os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
samples = []
for p in sorted(glob.glob(os.path.join(os.environ["RUN_DIR"],
                                       "vm-serial-key*.log"))):
    v = benchlib.measure("seat-key-latency",
                         open(p, errors="replace").read())
    if v is not None:
        samples.append(v)
benchlib.leg_verdict("seat-key-latency", samples)
PY

# --- trend table (#2936) -----------------------------------------------------
# The last assert on the last leg: every measurement of the run is in
# artifacts/bench/history.tsv by now, so print the regression table over
# it. Informational — flags warn; they never fail the run.
vgate_assert keyc python <<'PY'
import os, sys
sys.path.insert(0, os.environ["RUN_DIR"])
import benchlib
benchlib.trend()
PY
