#!/usr/bin/env python3
"""fleet-census.py -- the warm-checkpoint leg census (ADR 0059, M131d #2641).

Classifies every `vgate_run` leg in the spec fleet without booting anything:

  device     D1 static rule: the spec declares `vgate_share arm|seed`
             (harness-armed --cvc-file, unsaveable), or the leg's flag
             vector carries a Grounding-4 custom-virtio-arming flag.
             Never attempted warm — receipt vocabulary `warm=cold`.
  warm       the leg carries `--from-checkpoint` (already adopted).
  a-f        D7 semantic classes: computed where a flag or assert reveals
             them, or declared by a `# warm-cold:` comment (see SPEC.md).
  unclassified
             device-clean, not adopted, no computed or declared reason.
             A reported number, not a failure — the sweep drives it to 0.

Classification is the conjunction of D1 and D7 in that order: a leg
ineligible on both grounds lands under `device` (the static refusal the
harness would actually hit first). A `# warm-cold:` declaration only ever
excludes — it can never make a leg eligible.

Deterministic by construction (issue #1177 rules): spec order is LC_ALL=C
sorted, every count is order/locale invariant, and no dates, revisions or
host state appear. `fleet.sh census [pattern]` is the entry point;
`--spec-dir DIR` retargets it at fixtures (tools/gate/fixtures/warm-census/).

Usage:
  python3 tools/gate/fleet-census.py [--spec-dir DIR] [--legs] [pattern]
"""
import os
import re
import sys

# Grounding-4 / D1: flags that arm a VZCustomVirtioDevice (unsaveable;
# VZ refuses validateSaveRestoreSupport Code=2) or the second custom
# device (--gpu3d-metal, the M102 VIR1 render device).
D1_FLAGS = frozenset((
    "--custom-virtio", "--cvc-echo", "--via-virtio", "--pointer-virtio",
    "--cvc-snap", "--cvc-file", "--cvc-console-file", "--snapshot-after",
    "--gpu3d-metal",
))

# D7 computed classes — the flags a leg's vector can reveal.
CLASS_B_FLAGS = frozenset((
    "--resume", "--apply-update", "--rollback-update",
))
CLASS_C_FLAGS = frozenset((
    "--console-tcp", "--net-tcp-respond-relay",
))
# The runner's --vz-restore mode is a standalone headless probe accepting a
# fixed flag set (observed rc=1 usage error on anything else). A checkpoint
# leg's inherited device shape must stay inside it; a leg whose flag vector
# names machinery outside this set can never restore — runner-side state
# outside the bundle (D3/D7(c)).
RESTORE_EXPRESSIBLE = frozenset((
    "--overlay-base", "--vars", "--serial", "--cpus", "--timeout",
    "--virtio-fs", "--display", "--input", "--usb-msd",
    "--custom-virtio", "--gpu3d-metal", "--vsock",
))
# Prefixes always expressible: workload selectors and the vz-restore knobs.
EXPRESSIBLE_PREFIXES = ("--script", "--vz-restore")
CLASS_E_FLAGS = frozenset((
    "--usb-msd", "--host-cmd-after", "--profile", "--profile-init",
))
# Boot-settle waits the epoch (D6) hides — a restored guest never re-emits
# the marker these wait on.
CLASS_A_FLAGS = frozenset((
    "--expect", "--terminal-marker",
))
# (a) boot markers: the epoch (D6) hides base-boot bytes. An assert of
# presence on one of these needles can never hold warm; serial-absent
# deliberately does NOT classify (absence still holds inside the epoch).
BOOT_NEEDLES = ("kern:", "VirelaiOS kernel has seized control")
CLASS_A_KINDS = frozenset((
    "serial-contains", "serial-count", "serial-exact", "serial-echo",
    "output-contains", "serial-contains-file",
))

CLASSES = "abcdef"

RUN_RE = re.compile(r"^vgate_run\s+(\S+)\s*(.*)$")
CKPT_RE = re.compile(r"^vgate_checkpoint\s+(\S+)\s*(.*)$")
SHARE_RE = re.compile(r"^vgate_share\s+(\S+)")
CLIENT_RE = re.compile(r"^vgate_client\s+(\S+)\s")
ASSERT_RE = re.compile(r"^vgate_assert\s+(\S+)\s+(\S+)\s*(.*)$")
FILE_RE = re.compile(r"^vgate_file\s+(\S+)\s+<<'([A-Z]+)'\s*$")
HDOC_RE = re.compile(r"<<'([A-Z]+)'\s*$")
SEP_RE = re.compile(r"(?:^|\s)--(?=\s|$)")
VAR_DEFAULT_RE = re.compile(r"^\$\{[^}:-]+:-([^}]+)\}$")
DECL_RE = re.compile(r"^#\s*warm-cold:\s*(.*)$")
DECL_FULL_RE = re.compile(r"^([A-Za-z0-9_,.]+)\s*\(([a-z])\)\s*(\S.*)$")
QUOTED_RE = re.compile(r"'[^']*'|\"[^\"]*\"")
FLAG_RE = re.compile(r"--[A-Za-z0-9][A-Za-z0-9-]*")


def resolve_default(tok):
    """${VAR:-default} -> default (Grounding 11's share-mode rule)."""
    m = VAR_DEFAULT_RE.match(tok)
    return m.group(1) if m else tok


def flags_of(text):
    """Flag names in a flag vector; quoted spans are stripped first so a
    marker like --script-expect 'a --b c' cannot read as a flag."""
    return frozenset(FLAG_RE.findall(QUOTED_RE.sub("", text)))


def unquote(text):
    """'foo bar' / \"foo bar\" -> foo bar (keeps contents, drops quotes)."""
    return QUOTED_RE.sub(lambda m: m.group(0)[1:-1], text)


def split_dashdash(rest):
    """(pre_opts, flags) around the FIRST standalone `--` token, or None."""
    m = SEP_RE.search(rest)
    if not m:
        return None
    return rest[:m.start()], rest[m.end():]


def scan(path):
    """Parse one spec: (share_mode, legs, clients, asserts, decls, errors).

    legs:   [(tag, from_ckpt, flag_set)]
    decls:  [(tag, class, reason)] flattened from every warm-cold comment
    errors: [(where, message)]
    """
    with open(path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read().split("\n")
    share = "none"
    legs = []
    clients = set()
    asserts = []
    decls = []
    errors = []
    bodies = {}
    i = 0
    pending = ""
    while i < len(raw):
        line = raw[i]
        # Declarations are read on PHYSICAL lines (a comment is never part
        # of a continued logical line), like check_spec_order's DECL_RE.
        d = DECL_RE.match(line)
        if d:
            rest = d.group(1).strip()
            fm = DECL_FULL_RE.match(rest)
            if not fm:
                errors.append(("%s:%d" % (os.path.basename(path), i + 1),
                               "malformed '# warm-cold:' declaration — want "
                               "`# warm-cold: <tag>[,<tag>…] (<a-f>) <reason>`"))
            else:
                tags, cls, reason = fm.groups()
                if cls not in CLASSES:
                    errors.append(("%s:%d" % (os.path.basename(path), i + 1),
                                   "warm-cold class '%s' is not one of a-f"
                                   % cls))
                else:
                    for tag in tags.split(","):
                        decls.append((tag, cls, reason))
            i += 1
            continue
        fm = FILE_RE.match(line)
        if fm:
            name, term = fm.groups()
            body = []
            i += 1
            while i < len(raw) and raw[i].strip() != term:
                body.append(raw[i])
                i += 1
            bodies[name] = "\n".join(body)
            i += 1
            continue
        # Any other heredoc (vgate_setup_python, vgate_assert python|snapshot)
        # is opaque to the census — skip its body.
        hm = HDOC_RE.search(line)
        if hm and re.match(r"^vgate_", line):
            term = hm.group(1)
            i += 1
            while i < len(raw) and raw[i].strip() != term:
                i += 1
            i += 1
            continue
        if line.rstrip().endswith("\\"):
            pending += line.rstrip()[:-1]
            i += 1
            continue
        logical = pending + line
        pending = ""
        i += 1
        m = SHARE_RE.match(logical)
        if m:
            share = resolve_default(m.group(1))
            continue
        m = CLIENT_RE.match(logical)
        if m:
            clients.add(m.group(1))
            continue
        m = ASSERT_RE.match(logical)
        if m:
            asserts.append(m.groups())
            continue
        m = RUN_RE.match(logical)
        if m:
            tag, rest = m.groups()
            parts = split_dashdash(rest)
            if parts is None:
                errors.append(("%s run %s" % (os.path.basename(path), tag),
                               "vgate_run missing -- separator"))
                continue
            pre, flags = parts
            pflags = flags_of(pre)
            from_ckpt = ""
            if "--from-checkpoint" in pflags:
                pm = re.search(r"--from-checkpoint\s+(\S+)", pre)
                from_ckpt = pm.group(1) if pm else "?"
            legs.append((tag, from_ckpt, flags_of(flags)))
    return share, legs, clients, asserts, decls, errors, bodies


def main(argv):
    spec_dir = None
    leg_detail = False
    pattern = ""
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--spec-dir":
            spec_dir = args.pop(0)
        elif a == "--legs":
            leg_detail = True
        elif a.startswith("-"):
            sys.stderr.write("fleet-census: unknown option %s\n" % a)
            return 2
        else:
            pattern = a
    if spec_dir is None:
        spec_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "specs")
    if not os.path.isdir(spec_dir):
        sys.stderr.write("fleet-census: no spec dir %s\n" % spec_dir)
        return 2

    rows = []
    errors = []
    for fname in sorted(os.listdir(spec_dir)):
        if not fname.endswith(".spec"):
            continue
        if pattern and pattern not in fname[:-5]:
            continue
        path = os.path.join(spec_dir, fname)
        share, legs, clients, asserts, decls, errs, bodies = scan(path)
        errors.extend((fname, w, msg) for w, msg in errs)

        declared = {}
        for tag, cls, reason in decls:
            if tag in declared:
                errors.append((fname, "spec",
                               "warm-cold: leg '%s' declared twice" % tag))
            declared[tag] = cls
        leg_tags = {t for t, _, _ in legs}
        for tag in declared:
            if tag not in leg_tags:
                errors.append((fname, "spec",
                               "warm-cold: '%s' names no vgate_run" % tag))
            elif any(t == tag and ck for t, ck, _ in legs):
                errors.append((fname, "spec",
                               "warm-cold: '%s' is adopted (--from-checkpoint)"
                               " — a cold declaration cannot apply" % tag))

        verdicts = []
        for tag, from_ckpt, fl in legs:
            if share in ("arm", "seed"):
                verdicts.append((tag, "device", "vgate_share " + share))
                continue
            d1 = sorted(fl & D1_FLAGS)
            if d1:
                verdicts.append((tag, "device", d1[0]))
                continue
            if from_ckpt:
                verdicts.append((tag, "warm", "--from-checkpoint " + from_ckpt))
                continue
            if tag in declared:
                verdicts.append((tag, declared[tag], "declared"))
                continue
            cls = None
            reason = "—"
            b_hits = sorted(fl & CLASS_B_FLAGS |
                            {f for f in fl if f.startswith("--vz-restore")})
            c_hits = sorted(fl & CLASS_C_FLAGS)
            e_hits = sorted(fl & CLASS_E_FLAGS |
                            {f for f in fl if f.startswith("--host-")})
            a_hits = sorted(fl & CLASS_A_FLAGS)
            if b_hits:
                cls, reason = "b", b_hits[0]
            elif c_hits or tag in clients:
                cls, reason = "c", c_hits[0] if c_hits else "vgate_client"
            elif e_hits:
                cls, reason = "e", e_hits[0]
            elif a_hits:
                cls, reason = "a", a_hits[0]
            else:
                for atag, kind, arg in asserts:
                    if atag != tag:
                        continue
                    needle = arg
                    if kind == "serial-contains-file":
                        needle = bodies.get(unquote(arg).strip(), arg)
                    needle = unquote(needle)
                    # Both directions: an assert may name the marker
                    # ('kern: map' ⊃ kern:) or a substring of it
                    # ('kernel has seized control' ⊂ the seize line — a
                    # ≥6-char substring, so 'kern'/'control' can't trigger).
                    if kind in CLASS_A_KINDS and any(
                            n in needle or (len(needle) >= 6 and needle in n)
                            for n in BOOT_NEEDLES):
                        cls, reason = "a", "%s names a base-boot marker" % kind
                        break
            if cls is None:
                inexpr = sorted(f for f in fl
                                if f not in RESTORE_EXPRESSIBLE
                                and not f.startswith(EXPRESSIBLE_PREFIXES))
                if inexpr:
                    cls = "c"
                    reason = ("%s is outside the vz-restore probe's flag set"
                              % inexpr[0])
            verdicts.append((tag, cls or "unclassified", reason))
        rows.append((fname[:-5], verdicts))

    for fname, where, msg in errors:
        sys.stderr.write("fleet-census: %s %s: %s\n" % (fname, where, msg))
    if errors:
        return 1

    totals = dict.fromkeys(("device", "warm", "unclassified") +
                           tuple(CLASSES), 0)
    print("%-44s %5s %6s %2s %2s %2s %2s %2s %2s %4s %7s"
          % ("spec", "legs", "device", "a", "b", "c", "d", "e", "f",
             "warm", "unclass"))
    for spec, verdicts in rows:
        counts = dict.fromkeys(totals, 0)
        for _, cls, _ in verdicts:
            counts[cls] += 1
        for k, v in counts.items():
            totals[k] += v
        print("%-44s %5d %6d %2d %2d %2d %2d %2d %2d %4d %7d"
              % ((spec, len(verdicts), counts["device"], counts["a"],
                  counts["b"], counts["c"], counts["d"], counts["e"],
                  counts["f"], counts["warm"], counts["unclassified"])))
        if leg_detail:
            for tag, cls, reason in verdicts:
                print("%-44s   %-20s %s (%s)" % ("", tag, cls, reason))
    print("%-44s %5d %6d %2d %2d %2d %2d %2d %2d %4d %7d"
          % ("FLEET", sum(len(v) for _, v in rows), totals["device"],
             totals["a"], totals["b"], totals["c"], totals["d"],
             totals["e"], totals["f"], totals["warm"],
             totals["unclassified"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
