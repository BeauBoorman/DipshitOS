# App refresh ledger (#3246, index #3234)

One row per shipped app — every `image/apps.txt` row — carrying the card
that last touched it and the ISO-8601 date. The component registry
answers "what exists"; this ledger answers "what is stale". Checked by
`tools/tests/test_app_refresh.py`, which runs in `just verify-portable`:
a manifest row with no ledger row, a row out of manifest order, or a
date that is not ISO-8601 fails the build.

## The rotation rule

Each wave files one app-refresh index over the ledger's oldest tranche:
run `python3 tools/tests/test_app_refresh.py --stale`, take the top
rows, and refresh those apps. A refresh PR bumps its row — set
`last refresh` to the landing card and `date` to the merge date — so
the ledger, not memory, decides which apps the next wave sees.

Staleness is advisory, never a gate: `--stale` prints the table
oldest-first and exits 0 regardless. Time is not a build input.

## Seeding convention

A row's `last refresh`/`date` is the most recent non-merge commit on the
app's package directory (`user/go/<pkg>`; `user/src/tabwm.zig` for the
Zig fallback desktop). That counts any substantive touch — a focused
app card, a shared-library change the app consumes, a tree-wide
migration that landed in the package alike. `—` in `last refresh` marks
a touch whose commit carries no card or issue token (predates tracking);
`—` in `date` marks no recorded touch at all, and `--stale` sorts those
rows first.

## Row grammar (what the checker reads)

- `app` — the manifest display name (apps.txt field 2).
- `binary` — the manifest executable (field 1). Rows appear in manifest
  order; the checker enforces exactly one ledger row per apps.txt row,
  in order.
- `last refresh` — the card that did it: `MnnnX #issue`, `#issue`, a
  bare milestone token, or `—`.
- `date` — ISO-8601 `YYYY-MM-DD`, or `—` only when `last refresh` is
  `—` too.
- `notes` — free text: what the touch was.

## The ledger

| app | binary | last refresh | date | notes |
|-----|--------|--------------|------|-------|
| 64-bit Calc | GOCALC.ELF | M104h #2275 | 2026-10-15 | seat-rail + flagship composite goldens incl. go-calc chrome |
| Text Editor | NOTE.ELF | M170c #3129 | 2026-10-22 | free-file sleep sites → ns durations / event wait (tree-wide) |
| Code Editor | GOEDIT.ELF | M166c #2991 | 2026-10-22 | per-function heat gutter from `--prof=` .folded |
| Files | GOFILES.ELF | M187d #3185 | 2026-10-23 | .ics/.vcf file types; GOFILES contact card |
| Terminal | GOTERM.ELF | #3057 | 2026-10-22 | REVIEW-LOW sweep — term hints CSI |
| Web | WEB.ELF | M177a #3142 | 2026-10-22 | a11y keys honoured — WEB text_scale |
| Pulse | PULSE.ELF | M168c #2959 | 2026-10-21 | lipgloss v2 |
| Shell | GOSH.ELF | M138a #2775 | 2026-10-20 | shlib heredocs |
| Help | GOHELP.ELF | M170c #3129 | 2026-10-22 | free-file sleep sites → ns durations (tree-wide) |
| Welcome | GOWELCOME.ELF | M122b #2571 | 2026-10-19 | first-boot welcome tour |
| Top | GOTOP.ELF | M188d #3189 | 2026-10-22 | diagnostics census — documented split + shared drain |
| Settings | GOSET.ELF | M183a #3171 | 2026-10-22 | settings table grows past 24 via bounded second bank |
| Image Viewer | GOVIEW.ELF | M180a #3155 | 2026-10-22 | MOV demux + Motion-JPEG playback |
| Sound | GOSOUND.ELF | M186a #3178 | 2026-10-22 | extract user/go/pcm (with GOREC) |
| Tabbed Desktop | TABWM.BIN | M189b #3226 | 2026-10-23 | docs litterbox touched the fallback source |
| Gostalgia | GOSTALGIA.ELF | M97g | 2026-10-10 | eight owner-approved security follow-ups (#2080 et al.) |
| Store | GOSTORE.ELF | M188c #3188 | 2026-10-23 | store pin — signed-head rollback + ReleaseDepends |
| LLM Infer | GOINFER.ELF | M140a #2784 | 2026-10-20 | engine becomes user/go/infer |
| Recorder | GOREC.ELF | M186a #3178 | 2026-10-22 | extract user/go/pcm (with GOSOUND) |
| Snapshots | GOSNAP.ELF | M120d #2561 | 2026-10-19 | windowed GOSNAP + PWR menu Snapshot row |
| Assistant | GOASSIST.ELF | M178b #3145 | 2026-10-22 | romaji→kana composition in a text field |
| Sheet | GOSHEET.ELF | M152a #2915 | 2026-10-21 | v2 — fill series, 32-step undo, column formats, blob v2 |
| Reader | GOREADER.ELF | M164a #2988 | 2026-10-22 | ADR 0040 A4 baseline DCTDecode via decoder hook |
| Clock | GOCLOCK.ELF | M187d #3185 | 2026-10-23 | .ics/.vcf file types; GOCLOCK import verb |
| Mines | GOMINE.ELF | M152d #2918 | 2026-10-21 | GOMINE best times (with GOSOL undo + stats) |
| Solitaire | GOSOL.ELF | M152d #2918 | 2026-10-21 | undo-in-blob + stats + chime |
| Emoji | GOEMOJI.ELF | M152c #2917 | 2026-10-21 | v2 — recents + favorites shelf, save_state v2 |
| IRC | GOIRC.ELF | M152e #2919 | 2026-10-21 | v2 — /hl highlight rules, bounded per-channel logs |
| Vault | GOVAULT.ELF | M173d #3045 | 2026-10-22 | AGENTD runs as uid_agent; vault 0600 |
| Mail | GOMAIL.ELF | M187c #3192 | 2026-10-22 | IMAP4 fetch/read + SMTP submit over tls.Dial |
| Accessibility | GOA11Y.ELF | M177b #3143 | 2026-10-22 | appkit a11y outlines + GOA11Y reader |
