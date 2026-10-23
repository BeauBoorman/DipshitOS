#!/usr/bin/env python3
# gen-zones.py — M178c (#3146): emit user/go/clockfmt/zones.go from a pinned
# IANA tzdata release.
#
# The script downloads the pinned release tarball (URL + SHA-256 below),
# walks the Zone/Rule/Link source lines, and for each curated zone emits the
# zone name, its current standard offset, its DST offset, and the current
# POSIX-TZ transition rule (Mm.w.d/secs) — the shape clockfmt's evaluator
# consumes. tzdata is public domain (see the release's LICENSE file).
#
# Curation notes (the named limitations the card carries):
#   * Only the CURRENT rule travels: a zone's last era line plus the rule
#     set's TO=max entries. History before the current rule is not carried
#     (D8). Rule sets with no ongoing entries resolve as the fixed offset
#     the zone now keeps (e.g. Europe/Moscow, America/Mexico_City).
#   * Rules POSIX cannot express are skipped with a warning: fixed
#     day-of-month transitions (Asia/Jerusalem, Asia/Tehran), and Morocco's
#     Ramadan table (Africa/Casablanca). These stay reachable as fixed
#     UTC±HH:MM offsets.
#
# Usage:  python3 tools/tz/gen-zones.py > user/go/clockfmt/zones.go
#         python3 tools/tz/gen-zones.py --check   # regen and diff, no write

import hashlib
import io
import os
import re
import sys
import tarfile
import urllib.request

TZDATA_URL = "https://data.iana.org/time-zones/releases/tzdata2026e.tar.gz"
TZDATA_SHA256 = "b26882805f26aac59d5b222978e6580484b834ccdc98be89df2f05a6dc53a652"
TZDATA_VERSION = "2026e"

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_GO = os.path.join(REPO, "user/go/clockfmt/zones.go")

# Source files holding every Zone/Rule/Link line of the main DB (backward
# adds the Link aliases the curated list can name; backzone is deliberately
# excluded — it holds pre-1970 alternatives, not current rules).
SOURCES = ["africa", "antarctica", "asia", "australasia", "backward",
           "etcetera", "europe", "northamerica", "southamerica"]

MONTHS = {"Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
          "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12}
WDAYS = {"Sun": 0, "Mon": 1, "Tue": 2, "Wed": 3, "Thu": 4, "Fri": 5, "Sat": 6}

# The curated ~60-zone vocabulary. Aliases resolve through Link lines;
# zones whose current rule is not POSIX-expressible are reported and
# skipped, not silently emitted wrong.
CURATED = [
    # Europe
    "Atlantic/Reykjavik", "Europe/London", "Europe/Dublin", "Europe/Lisbon",
    "Europe/Jersey", "Europe/Berlin", "Europe/Paris", "Europe/Madrid",
    "Europe/Rome", "Europe/Amsterdam", "Europe/Brussels", "Europe/Vienna",
    "Europe/Zurich", "Europe/Prague", "Europe/Warsaw", "Europe/Budapest",
    "Europe/Stockholm", "Europe/Oslo", "Europe/Copenhagen", "Europe/Helsinki",
    "Europe/Athens", "Europe/Bucharest", "Europe/Sofia", "Europe/Kyiv",
    "Europe/Moscow", "Europe/Istanbul",
    # Americas
    "America/St_Johns", "America/Halifax", "America/New_York",
    "America/Toronto", "America/Winnipeg", "America/Chicago",
    "America/Denver", "America/Edmonton", "America/Phoenix",
    "America/Los_Angeles", "America/Vancouver", "America/Anchorage",
    "America/Mexico_City", "America/Havana", "America/Bogota",
    "America/Lima", "America/Sao_Paulo",
    "America/Argentina/Buenos_Aires", "America/Montevideo",
    # Africa
    "Africa/Cairo", "Africa/Johannesburg", "Africa/Nairobi", "Africa/Lagos",
    # Asia
    "Asia/Beirut", "Asia/Dubai", "Asia/Karachi", "Asia/Kolkata",
    "Asia/Dhaka", "Asia/Bangkok", "Asia/Jakarta", "Asia/Singapore",
    "Asia/Hong_Kong", "Asia/Shanghai", "Asia/Taipei", "Asia/Manila",
    "Asia/Seoul", "Asia/Tokyo",
    # Oceania + Atlantic
    "Australia/Perth", "Australia/Darwin", "Australia/Brisbane",
    "Australia/Adelaide", "Australia/Sydney", "Australia/Melbourne",
    "Australia/Hobart", "Australia/Lord_Howe", "Pacific/Auckland",
    "Pacific/Chatham", "Pacific/Fiji", "Pacific/Port_Moresby",
    "Pacific/Noumea", "Pacific/Guam", "Pacific/Honolulu",
    "Atlantic/Azores", "Atlantic/Cape_Verde",
]


def fetch():
    """Download (or take -i) the pinned tarball, verified byte for byte."""
    if len(sys.argv) > 1 and sys.argv[1] == "-i":
        blob = open(sys.argv[2], "rb").read()
    else:
        with urllib.request.urlopen(TZDATA_URL) as r:
            blob = r.read()
    digest = hashlib.sha256(blob).hexdigest()
    if digest != TZDATA_SHA256:
        raise SystemExit("tzdata sha256 %s != pinned %s — refusing "
                         "(the pin is the supply-chain bar, not a hint)"
                         % (digest, TZDATA_SHA256))
    return blob


def hms(s):
    """'h[:mm[:ss]][wsu]' -> (seconds, suffix); a bare '-' is 0 wall."""
    s = s.strip()
    if s == "-":
        return 0, "w"
    m = re.fullmatch(r"(-?)(\d+)(?::(\d\d))?(?::(\d\d))?([wsuzg]?)", s)
    if not m:
        raise ValueError("bad AT/STDOFF %r" % s)
    secs = int(m.group(2)) * 3600 + int(m.group(3) or 0) * 60 + \
        int(m.group(4) or 0)
    if m.group(1):
        secs = -secs
    suffix = m.group(5) or "w"
    if suffix in "zg":
        suffix = "u"
    return secs, suffix


def parse_on(on):
    """'lastSun'/'Sun>=8'/'Sun<=7' -> (month-week, wday); None if fixed-dom."""
    on = on.strip()
    m = re.fullmatch(r"last(Sun|Mon|Tue|Wed|Thu|Fri|Sat)", on)
    if m:
        return 5, WDAYS[m.group(1)]
    m = re.fullmatch(r"(Sun|Mon|Tue|Wed|Thu|Fri|Sat)>=(\d+)", on)
    if m:
        # Only n in {1,8,15,22} is month-length invariant: days 1..n-1 then
        # hold exactly n//7 of the weekday, so the first >= n is always the
        # n//7+1'th. Other n pick a different week in different months —
        # not expressible as a fixed M.w.d.
        n = int(m.group(2))
        if n % 7 != 1:
            return None
        return n // 7 + 1, WDAYS[m.group(1)]
    m = re.fullmatch(r"(Sun|Mon|Tue|Wed|Thu|Fri|Sat)<=(\d+)", on)
    if m:
        # Same invariance bound, mirrored: days 1..7k hold exactly k of the
        # weekday, so X<=7k is always the k'th.
        n = int(m.group(2))
        if n % 7 != 0:
            return None
        return n // 7, WDAYS[m.group(1)]
    if re.fullmatch(r"\d+", on):
        return None  # a fixed day of month: not expressible as M.w.d
    m = re.fullmatch(r"(Sun|Mon|Tue|Wed|Thu|Fri|Sat)", on)
    if m:
        return 1, WDAYS[m.group(1)]  # bare weekday: first of the month
    return None


class Rule:
    __slots__ = ("name", "frm", "to", "month", "on", "at", "suffix",
                 "save", "letter")


def parse_sources(blob):
    rules = {}   # name -> [Rule]
    zones = {}   # name -> [(stdoff, rules, format)]
    links = {}   # alias -> canonical
    with tarfile.open(fileobj=io.BytesIO(blob)) as tf:
        for name in SOURCES:
            text = tf.extractfile(name).read().decode()
            cur = None
            for raw in text.splitlines():
                if not raw or raw.startswith("#"):
                    continue
                f = raw.split("#", 1)[0].split()
                if not f:
                    continue
                if f[0] == "Rule":
                    r = Rule()
                    r.name, r.frm, r.to = f[1], int(f[2]), f[3]
                    r.month = MONTHS[f[5]]
                    r.on = f[6]
                    r.at, r.suffix = hms(f[7])
                    r.save, _ = hms(f[8])
                    r.letter = f[9] if len(f) > 9 else "-"
                    rules.setdefault(r.name, []).append(r)
                    continue
                if f[0] == "Zone":
                    cur = f[1]
                    f = f[2:]
                elif f[0] == "Link":
                    links[f[2]] = f[1]
                    continue
                elif cur is None or f[0] in ("Leap", "Expires"):
                    continue
                # A Zone line (or its continuation): STDOFF RULES FORMAT.
                stdoff, _ = hms(f[0])
                zones.setdefault(cur, []).append((stdoff, f[1], f[2]))
    return rules, zones, links


def abbr(fmt, letter):
    """Resolve a %s FORMAT with a rule letter; '-' means no letter."""
    if "%s" in fmt:
        return fmt.replace("%s", "" if letter == "-" else letter)
    return fmt


def state_abbr(fmt, save, letter):
    """The abbreviation an offset STATE carries: 'STD/DST' slash forms pick
    by whether the state's save is zero, %s forms by the rule's letter,
    anything else is the literal FORMAT."""
    if "/" in fmt:
        a, b = fmt.split("/", 1)
        return a if save == 0 else b
    return abbr(fmt, letter)


def emit(name, eras, rules):
    """Reduce a zone's last era line to its current POSIX-TZ rule."""
    stdoff, rname, fmt = eras[-1]
    if rname == "-":
        return fixed(name, stdoff, abbr(fmt, "-")), None
    if not re.fullmatch(r"[A-Za-z_]+", rname):
        # A numeric SAVE in the rules column: a permanent save, still a
        # fixed offset.
        save, _ = hms(rname)
        return fixed(name, stdoff + save, abbr(fmt, "-")), None
    rs = rules.get(rname, [])
    ongoing = [r for r in rs if r.to == "max"]
    if not ongoing:
        # The named set's rules all ended (Mexico 2022, Russia 2016): the
        # zone keeps its last-applied offset, which the era line's stdoff
        # carries. The %s letter comes from the most recent standard rule.
        std = [r for r in rs if r.save == 0]
        return fixed(name, stdoff,
                     abbr(fmt, std[-1].letter if std else "-")), None
    if len(ongoing) != 2:
        return None, ("%s: rule set %s has %d ongoing rules — not a "
                      "POSIX pair" % (name, rname, len(ongoing)))
    # The high-offset state is POSIX "daylight" and the low-offset state is
    # "standard" — including negative-save sets like Eire, where the era
    # STDOFF is the daylight offset and winter carries save < 0.
    hi = max(ongoing, key=lambda r: r.save)
    lo = min(ongoing, key=lambda r: r.save)
    if hi.save == lo.save:
        return None, ("%s: rule set %s ongoing saves agree — not a "
                      "POSIX pair" % (name, rname))
    hi_on, lo_on = parse_on(hi.on), parse_on(lo.on)
    if hi_on is None or lo_on is None:
        return None, ("%s: transition day %r/%r is not M.w.d-expressible" %
                      (name, hi.on, lo.on))
    std_eff = stdoff + lo.save
    dst_eff = stdoff + hi.save

    # POSIX interprets each rule's clock in the wall time in force BEFORE
    # the transition (standard for the start, daylight for the end).
    # tzdata AT suffixes convert onto that basis: w = already the
    # before-wall; s = the era's STDOFF wall; u = UTC.
    def wall_secs(r, before_off):
        if r.suffix == "w":
            return r.at
        if r.suffix == "s":
            return r.at - stdoff + before_off
        return r.at + before_off
    return {
        "name": name, "stdOff": std_eff, "dstOff": dst_eff,
        "stdAbbr": state_abbr(fmt, lo.save, lo.letter),
        "dstAbbr": state_abbr(fmt, hi.save, hi.letter),
        "start": (hi.month, hi_on[0], hi_on[1], wall_secs(hi, std_eff)),
        "end": (lo.month, lo_on[0], lo_on[1], wall_secs(lo, dst_eff)),
        "hasDST": True,
    }, None


def fixed(name, off, a):
    return {"name": name, "stdOff": off, "dstOff": off,
            "stdAbbr": a, "dstAbbr": a, "hasDST": False}


def zfmt(off):
    """%+d-style numeric abbreviations for %z format zones."""
    sign = "+" if off >= 0 else "-"
    v = abs(off)
    return "%s%02d%02d" % (sign, v // 3600, v // 60 % 60)


def gostr(s):
    """s as a Go double-quoted string literal (names/abbrs are ASCII)."""
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


def render(zs):
    out = []
    out.append("// Code generated by tools/tz/gen-zones.py from IANA tzdata"
               " %s; DO NOT EDIT." % TZDATA_VERSION)
    out.append("//")
    out.append("// Regenerate: python3 tools/tz/gen-zones.py > %s"
               % "user/go/clockfmt/zones.go")
    out.append("// The pin (URL + SHA-256) lives in the script; tzdata is")
    out.append("// public domain. Each row is the zone's CURRENT POSIX-TZ")
    out.append("// rule — history before it is not carried (D8).")
    out.append("")
    out.append("package clockfmt")
    out.append("")
    out.append("// ianaZones is the curated named-zone vocabulary, sorted by")
    out.append("// name. A named Zone value is ianaBase + its index here.")
    out.append("var ianaZones = []ianaZone{")
    for z in sorted(zs, key=lambda z: z["name"]):
        sa, da = z["stdAbbr"], z["dstAbbr"]
        if sa == "%z":
            sa = zfmt(z["stdOff"])
        if da == "%z":
            da = zfmt(z["dstOff"])
        parts = ["name: " + gostr(z["name"]),
                 "stdOff: %d" % z["stdOff"], "dstOff: %d" % z["dstOff"],
                 "stdAbbr: " + gostr(sa), "dstAbbr: " + gostr(da)]
        if z["hasDST"]:
            for k in ("start", "end"):
                m, w, d, s = z[k]
                parts.append("%s: tzRule{month: %d, week: %d, wday: %d, "
                             "secs: %d}" % (k, m, w, d, s))
            parts.append("hasDST: true")
        out.append("\t{%s}," % ", ".join(parts))
    out.append("}")
    out.append("")
    return "\n".join(out)


def main():
    blob = fetch()
    rules, zones, links = parse_sources(blob)
    zs, skipped = [], []
    for name in CURATED:
        canon = name
        seen = set()
        while canon in links and canon not in seen:
            seen.add(canon)
            canon = links[canon]
        eras = zones.get(canon)
        if eras is None:
            skipped.append("%s: no such zone in tzdata %s"
                           % (name, TZDATA_VERSION))
            continue
        z, warn = emit(name, eras, rules)
        if z is None:
            skipped.append(warn)
            continue
        zs.append(z)
    for w in skipped:
        print("# skipped: %s" % w, file=sys.stderr)
    text = render(zs)
    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        have = open(OUT_GO).read() if os.path.exists(OUT_GO) else ""
        if have != text:
            print("zones.go is stale — regenerate with gen-zones.py",
                  file=sys.stderr)
            return 1
        return 0
    sys.stdout.write(text)
    print("# %d zones emitted, %d skipped" % (len(zs), len(skipped)),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
