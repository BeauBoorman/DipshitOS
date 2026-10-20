#!/usr/bin/env python3
"""fleet_grants.py -- M116a (#2467): the fleet grant-authoring tool.

Turns the fleet grant policy (image/fleet-grants.txt, authored from the
M113f audit data on issue #2422) into the row forms the system consumes:

  emit      regenerate kernel/src/grant_fleet.zig — the compiled
            `grant.base_rows` table. Compiled base rows are the signed
            form for owner-authored fleet policy: the Part I boot chain
            (firmware db -> loader -> KERNEL.BIN digest) verifies the
            table by construction, and the 16-row GRANTS.TXT user table
            could not hold the fleet anyway (~31 apps > max_user_rows).
  rows      print the same policy as `#v1` GRANTS.TXT text
            (`NAME<TAB>*<TAB>words`) for file-provisioning use.
  bind      print `#v1` GRANTS.TXT text with each row hash-bound to the
            sha256 of the binary of the same name in --dir (the strongest
            row-level binding: the row applies only to the measured
            image; a swapped image refuses `grant_stale`). Binaries absent
            from --dir keep `*` and a warning is printed.
  ingest    read `audit:<word>_denied name=<BIN>` receipts (stdin or a
            file) and print the observed per-name word sets — the draft
            OBSERVED column for a future audit pass.
  check     the class-A gate: every fleet app has a row whose mask covers
            its observed audit set, no mask is wider than observed
            without a named reason, and the generated table is in sync
            with the data. Exits nonzero on any violation.

Stdlib only, no libc/POSIX assumptions beyond python3 + hashlib.
"""

import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.path.join(ROOT, "image", "fleet-grants.txt")
APPS = os.path.join(ROOT, "image", "apps.txt")
ZIG_OUT = os.path.join(ROOT, "kernel", "src", "grant_fleet.zig")

# kernel/src/grant.zig `vocab` — canonical mask order, one byte-shape per
# word set (vi.GrantWordsCanonical renders the same order).
VOCAB = ["file", "window", "audio", "timer", "memory",
         "process", "debug", "net", "term"]
WORD_BIT = {w: 1 << i for i, w in enumerate(VOCAB)}

# kernel/src/grant.zig name_max: a row name is the exec-recorded share
# path, bounded at 64 bytes.
NAME_MAX = 64

# The non-manifest half of the fleet — shipped service/helper ELFs the
# M113f audit exercised beside the apps.txt roster (plus GOSSH.ELF, which
# the card names and the audit could not collect). M122c (#2572) moved
# three pure-CLI tools out of the manifest — a launcher row must open a
# window — but they still ship and still `exec`, so their grant rows stay.
SERVICE_FLEET = [
    "GOTABWM.ELF", "GOFETCH.ELF", "GOPING.ELF", "GOHTTPD.ELF",
    "GOSSHD.ELF", "GOBUILD.ELF", "FLINT.ELF", "STORE.ELF",
    "AGENTD.ELF", "INIT.ELF", "GOHELLO.ELF", "GOSSH.ELF",
    "GOSNAP.ELF", "GODIFF.ELF", "ZC.BIN",
    # M132b (#2753): GOPAINT.ELF is store-delivered and self-registers its
    # apps.txt row at install, so it has no manifest row — but grants are
    # name-bound, not manifest-bound, so its reservation row lives here.
    "GOPAINT.ELF",
]


def fail(msg):
    print("fleet-grants: ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


def parse_csv(s):
    """'-'/'' -> empty set; else a set of vocabulary words (None on bad)."""
    if s in ("", "-"):
        return set()
    out = set()
    for w in s.split(","):
        if w not in WORD_BIT or w in out:
            return None
        out.add(w)
    return out


def canonical(words):
    return ",".join(w for w in VOCAB if w in words) or "-"


def valid_name(name):
    return (0 < len(name) <= NAME_MAX
            and all(ord(c) >= 0x21 and c != "\x7f" for c in name))


def load_policy(path=DATA):
    """Parse image/fleet-grants.txt -> {name: (observed, mask, reason)}."""
    rows = {}
    order = []
    for ln, raw in enumerate(open(path), 1):
        line = raw.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            fail("%s:%d: expected NAME<TAB>OBSERVED<TAB>MASK<TAB>REASON"
                 % (path, ln))
        name, obs_s, mask_s, reason = fields
        obs, mask = parse_csv(obs_s), parse_csv(mask_s)
        if obs is None:
            fail("%s:%d: bad OBSERVED word set '%s'" % (path, ln, obs_s))
        if mask is None:
            fail("%s:%d: bad MASK word set '%s'" % (path, ln, mask_s))
        rows[name] = (obs, mask, reason)
        order.append(name)
    return rows, order


def apps_txt_names(path=APPS):
    """Field-1 names of every apps.txt row (the manifest roster)."""
    names = []
    for raw in open(path):
        line = raw.strip()
        if not line or line.startswith("#") or "|" not in line:
            continue
        name = line.split("|", 1)[0].strip()
        if name:
            names.append(name)
    return names


def cmd_emit(args):
    rows, order = load_policy()
    out = [
        "//! GENERATED by tools/grants/fleet_grants.py — do not hand-edit.",
        "//! Regenerate with `python3 tools/grants/fleet_grants.py emit`.",
        "//!",
        "//! M116a (#2467) fleet grant policy, ADR 0054 Part II base rows:",
        "//! one `*`-bound (narrow-only) row per shipped app, authored from",
        "//! the M113f audit data (issue #2422) in image/fleet-grants.txt.",
        "//! Compiled into KERNEL.BIN, the table is verified by the Part I",
        "//! boot chain — a different policy is a different kernel digest.",
        "//! The user table's 16-row bound cannot hold the ~31-app fleet,",
        "//! which is why owner-authored fleet policy lives here and not",
        "//! in GRANTS.TXT.",
        "",
        'const grant = @import("grant.zig");',
        "",
        "pub const rows = [_]grant.BaseRow{",
    ]
    for name in order:
        obs, mask, _reason = rows[name]
        del obs
        expr = " | ".join("grant.word_" + w for w in VOCAB if w in mask) or "0"
        out.append('    .{ .name = "%s", .sha256 = null, .words = %s },'
                   % (name, expr))
    out.append("};")
    out.append("")
    dst = args[0] if args else ZIG_OUT
    with open(dst, "w") as f:
        f.write("\n".join(out))
    print("fleet-grants: emitted %d base rows -> %s" % (len(order), dst))


def grants_text(rows, order, bind_dir=None):
    """The rows as `#v1` GRANTS.TXT text; hash-bound when bind_dir is set."""
    lines = ["#v1"]
    warned = []
    for name in order:
        _obs, mask, _reason = rows[name]
        sha = "*"
        if bind_dir is not None:
            path = os.path.join(bind_dir, name)
            if os.path.isfile(path):
                h = hashlib.sha256()
                with open(path, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
                sha = h.hexdigest()
            else:
                warned.append(name)
        lines.append("%s\t%s\t%s" % (name, sha, canonical(mask)))
    for name in warned:
        print("fleet-grants: WARNING: %s not in %s — left `*`-bound"
              % (name, bind_dir), file=sys.stderr)
    return "\n".join(lines) + "\n"


def cmd_rows(args):
    rows, order = load_policy()
    sys.stdout.write(grants_text(rows, order))


def cmd_bind(args):
    bind_dir = args[0] if args else fail("bind: expected a directory")
    if not os.path.isdir(bind_dir):
        fail("bind: '%s' is not a directory" % bind_dir)
    rows, order = load_policy()
    sys.stdout.write(grants_text(rows, order, bind_dir))


RECEIPT = re.compile(r"audit:(\w+)_denied name=(\S+)")


def cmd_ingest(args):
    """audit:<word>_denied receipts -> observed word sets (draft OBSERVED)."""
    text = open(args[0]).read() if args else sys.stdin.read()
    seen = {}
    for m in RECEIPT.finditer(text):
        word, name = m.group(1), m.group(2)
        if word not in WORD_BIT:
            continue
        seen.setdefault(name, set()).add(word)
    for name in sorted(seen):
        print("%s\t%s" % (name, canonical(seen[name])))


def cmd_check(_args):
    rows, order = load_policy()
    errors = []

    # Per-row rules: keyable name, mask superset of observed, a named
    # reason for every widening or un-audited row.
    for name in order:
        obs, mask, reason = rows[name]
        if not valid_name(name):
            errors.append("%s: row name is not a valid row key" % name)
        if not obs <= mask:
            errors.append("%s: mask %s narrower than observed %s"
                          % (name, canonical(mask), canonical(obs)))
        if (mask != obs or not obs) and reason in ("", "-"):
            errors.append("%s: mask wider than observed without a reason"
                          % name)
        if mask == obs and reason not in ("", "-"):
            errors.append("%s: reason given but mask == observed" % name)

    # Roster coverage, both directions: every apps.txt name and every
    # service ELF has a row, and no row names a non-fleet app.
    roster = set(apps_txt_names()) | set(SERVICE_FLEET)
    for name in sorted(roster - set(order)):
        errors.append("%s: fleet app has no row" % name)
    for name in sorted(set(order) - roster):
        errors.append("%s: row names a non-fleet app" % name)

    # The generated table must be byte-identical to what emit produces.
    if os.path.exists(ZIG_OUT):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".zig",
                                         delete=False) as t:
            tmp = t.name
        cmd_emit([tmp])
        fresh = open(tmp).read()
        os.unlink(tmp)
        if fresh != open(ZIG_OUT).read():
            errors.append("%s is stale — run "
                          "`python3 tools/grants/fleet_grants.py emit`"
                          % ZIG_OUT)
    else:
        errors.append("%s missing — run "
                      "`python3 tools/grants/fleet_grants.py emit`" % ZIG_OUT)

    if errors:
        for e in errors:
            print("fleet-grants: FAIL: " + e, file=sys.stderr)
        sys.exit(1)
    print("fleet-grants: check ok — %d rows, roster covered, "
          "masks superset of observed, table in sync" % len(order))


def main(argv):
    if not argv:
        fail(__doc__.strip().splitlines()[0] +
             "\nusage: fleet_grants.py emit [OUT.zig] | rows | bind DIR | "
             "ingest [RECEIPTS] | check")
    cmd = argv[0]
    if cmd == "emit":
        cmd_emit(argv[1:])
    elif cmd == "rows":
        cmd_rows(argv[1:])
    elif cmd == "bind":
        cmd_bind(argv[1:])
    elif cmd == "ingest":
        cmd_ingest(argv[1:])
    elif cmd == "check":
        cmd_check(argv[1:])
    else:
        fail("unknown command '%s'" % cmd)


if __name__ == "__main__":
    main(sys.argv[1:])
