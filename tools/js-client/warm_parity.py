"""Marker-set parity between cold and warm live-quickjs runs (ADR 0059, M131c #2640).

For each `--from-checkpoint qjs` leg, the SET of evidence-marker lines in the
warm serial must equal the cold serial's set after normalizing the volatile
fields listed in STRIP_FIELDS. Compare the same revision twice:

    VGATE_WARM=off VIRELAI_GATE_SUFFIX=-cold just gate live-quickjs
                    VIRELAI_GATE_SUFFIX=-warm just gate live-quickjs
    python3 tools/js-client/warm_parity.py

Read the suffix-aware artifacts the harness writes —
artifacts/live-quickjs-serial-<leg>-cold.log and ...-warm.log — never the
assertion.py copies under artifacts/m88-acceptance/, which are not
suffix-aware and would compare a run against itself.

Compared line families (line start, after ANSI/CR normalization):

    qjs*              'qjs:' notices, 'qjs-bounds:', 'qjs-cold:', 'qjs-gate-done'
    procs <BIN>       kernel exit reports 'procs QJS.BIN exited status=N'
    runtime-receipt:  the `procs receipt` accounting row
    pages:            the `pages` allocator snapshot

Everything else — boot banner, `kern:` receipts, `tasks ... reaped`, `tty`,
`syscalls`, echoed script input — is deliberately outside the compared set:
the cold epoch holds pre-checkpoint boot bytes the warm epoch cannot contain
(D6), and only the workload-emitted markers are the leg's evidence.

Sets, not multisets: doubled markers are not a parity failure here because the
gate's own serial-count/serial-exact asserts pin multiplicity inside each run.
Pass/fail equality is not enough — the normalized line sets must be equal.
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# The 16 live-quickjs legs converted to --from-checkpoint qjs (M131c #2640).
# The seven cold legs (cold + the six --console-tcp legs) are excluded: nothing
# warm to compare.
DEFAULT_LEGS = (
    "file", "refused", "exact", "over", "invalid", "dense", "string",
    "conversion", "missing", "denied", "exists", "bounds",
    "line", "line-over", "idle", "usage",
)

COMPARE_RE = re.compile(r"^(qjs|procs \S+\.BIN |runtime-receipt: |pages: )")

# Every normalization below names a field that legitimately varies between two
# runs of the same revision — between two cold boots, or across the
# checkpoint/restore boundary. Anything not listed here is compared
# byte-for-byte: an unexplained difference FAILS parity. To add a field you
# must show it varies between two cold runs and record why.
STRIP_FIELDS = (
    # (name, pattern, replacement, why the field legitimately varies)
    ("runtime-receipt pid",
     re.compile(r"^(runtime-receipt: pid=)\d+"), r"\1?",
     "the kernel pid counter is per-boot allocation order"),
    ("qjs-cold child pid",
     re.compile(r"(qjs-cold: sample=\d+ child=)\d+"), r"\1?",
     "child process pid; per-boot allocation order"),
    ("qjs-cold launch tick",
     re.compile(r"(qjs-cold: .*launch=)\d+"), r"\1?",
     "guest launch tick on the leg's own clock — a measurement, not evidence"),
    ("qjs-bounds cycle pointer",
     re.compile(r"(qjs-bounds: cycle=)\d+"), r"\1?",
     "@intFromPtr(runtime) — a guest address, varies with allocator layout"),
    ("pages allocator map",
     re.compile(r"(pages: armed=\d+ total=0x[0-9a-f]+ )"
                r"free=0x[0-9a-f]+ excluded=0x[0-9a-f]+ "
                r"regions=0x[0-9a-f]+ span=0x[0-9a-f]+"),
     r"\1free=? excluded=? regions=? span=?",
     "allocator map state legitimately differs across the freeze (the "
     "checkpointed guest's page history is not a fresh boot's). "
     "armed=1 and total= stay pinned; the within-leg pages[0]==pages[1] "
     "cleanup-recovery invariant stays asserted by assertions.py"),
)

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def normalize(line):
    line = ANSI_RE.sub("", line).rstrip()
    for _, pattern, repl, _ in STRIP_FIELDS:
        line = pattern.sub(repl, line)
    return line


def evidence_lines(text):
    """The normalized set of compared evidence-marker lines in a serial log."""
    return {
        normalized
        for raw in text.splitlines()
        if COMPARE_RE.match(normalized := normalize(raw))
    }


def compare(cold_text, warm_text):
    """(cold_only, warm_only) normalized marker sets that differ."""
    cold, warm = evidence_lines(cold_text), evidence_lines(warm_text)
    return cold - warm, warm - cold


def serial_path(artifacts, gate, leg, suffix):
    # vgate's art() appends VIRELAI_GATE_SUFFIX after the full name:
    # artifacts/<gate>-serial-<leg>.log-cold, not ...-<leg>-cold.log.
    return Path(artifacts) / f"{gate}-serial-{leg}.log{suffix}"


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="stripped volatile fields:\n" + "\n".join(
            f"  {name}: {why}" for name, _, _, why in STRIP_FIELDS))
    ap.add_argument("--artifacts", default=str(ROOT / "artifacts"))
    ap.add_argument("--gate", default="live-quickjs")
    ap.add_argument("--cold-suffix", default="-cold")
    ap.add_argument("--warm-suffix", default="-warm")
    ap.add_argument("legs", nargs="*", default=list(DEFAULT_LEGS))
    args = ap.parse_args(argv)

    failed = False
    for leg in args.legs:
        cold_f = serial_path(args.artifacts, args.gate, leg, args.cold_suffix)
        warm_f = serial_path(args.artifacts, args.gate, leg, args.warm_suffix)
        if not cold_f.is_file() or not warm_f.is_file():
            print(f"{leg}: MISSING serial(s) — "
                  f"{'' if cold_f.is_file() else str(cold_f) + ' '}"
                  f"{'' if warm_f.is_file() else str(warm_f)}".strip())
            failed = True
            continue
        cold_text = cold_f.read_text(errors="replace")
        warm_text = warm_f.read_text(errors="replace")
        cold_only, warm_only = compare(cold_text, warm_text)
        if not cold_only and not warm_only:
            print(f"{leg}: PARITY ({len(evidence_lines(cold_text))} markers)")
            continue
        failed = True
        print(f"{leg}: DIVERGED (+{len(warm_only)} warm-only, -{len(cold_only)} cold-only)")
        for line in sorted(cold_only):
            print(f"  cold-only: {line}")
        for line in sorted(warm_only):
            print(f"  warm-only: {line}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
