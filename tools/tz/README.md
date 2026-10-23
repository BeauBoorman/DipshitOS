# tools/tz — the IANA zone table generator (M178c, #3146)

`gen-zones.py` emits `user/go/clockfmt/zones.go`, the named-zone table the
`timezone` settings row can store (`Europe/Berlin`, `Australia/Sydney`, …).
Each emitted row is the zone's **current POSIX-TZ rule**: the standard
offset, the DST offset, the two `Mm.w.d/secs` transition rules, and the
abbreviations.

## Data

- Release: **IANA tzdata 2026e**
  (`https://data.iana.org/time-zones/releases/tzdata2026e.tar.gz`,
  SHA-256 `b26882805f26aac59d5b222978e6580484b834ccdc98be89df2f05a6dc53a652`)
- tzdata is public domain — see the release's `LICENSE` file.
- The pin (URL + SHA-256) lives in the script; a tampered or drifted
  tarball is refused.

## Regenerate

```bash
python3 tools/tz/gen-zones.py > user/go/clockfmt/zones.go
# or against a downloaded copy:
python3 tools/tz/gen-zones.py -i /path/to/tzdata2026e.tar.gz > user/go/clockfmt/zones.go
```

## Limitations (named on the card)

- **Current rule only.** History before each zone's current POSIX rule is
  not carried (D8): formatted instants apply today's rules to every year.
- **Not every IANA zone is expressible.** POSIX `Mm.w.d` cannot name fixed
  calendar dates (`Asia/Jerusalem`, `Asia/Tehran`), month-dependent week
  picks (`America/Santiago`'s `Sun>=2`), or non-periodic tables
  (`Africa/Casablanca`'s Ramadan rules). The curated list skips them —
  the generator prints `# skipped: …` rather than emitting a wrong rule;
  those names stay reachable as fixed `UTC±HH:MM` offsets.
- Zones whose rules already ended (`Europe/Moscow`, `America/Mexico_City`)
  resolve as the fixed offset they now keep.
- The 2026e release moves `America/Edmonton`, `America/Vancouver` and
  `America/Winnipeg` to permanent offsets (the source's "temporary hack"
  for Canada's DST end) — they are emitted as fixed, matching the pinned
  release, not older hosts' zoneinfo.
