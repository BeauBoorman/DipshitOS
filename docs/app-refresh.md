# App refresh ledger (#3246, index #3234)

One row per shipped app — every `image/apps.txt` row — carrying the card
that last touched it and the ISO-8601 date. The component registry
answers "what exists"; this ledger answers "what is stale". Checked by
`tools/tests/test_app_refresh.py`, which runs in `just verify-portable`:
a manifest row with no ledger row, a row out of manifest order, or a
date that is not ISO-8601 fails the build. Bump your row: a PR that
touches an app's package re-dates that row in the same diff.

## The rotation rule

Each wave files one app-refresh index over the ledger's oldest tranche:
run `python3 tools/tests/test_app_refresh.py --stale`, take the top
rows, and refresh those apps. A refresh PR bumps its row — set
`last refresh` to the landing card and `date` to the merge date — so
the ledger, not memory, decides which apps the next wave sees.

Staleness is advisory, never a gate: `--stale` prints the table
oldest-first and exits 0 regardless. Time is not a build input.

## Seeding convention

A row's `last refresh`/`date` is the newest non-merge commit on the
app's package directory (`user/go/<pkg>`; `user/src/tabwm.zig` for the
Zig fallback desktop) — spelled exactly, `git log --no-merges -1
--format=%ad --date=short -- <dir>`. Non-merge means single-parent: a
squash-landed PR is an ordinary commit and counts; a two-parent merge
(a `Merge main: …` landing) does not — seed from the newest non-merge
commit beneath it, never the merge's own date. That counts any
substantive touch — a focused app card, a shared-library change the
app consumes, a tree-wide migration that landed in the package alike.
`—` in `last refresh` marks a touch whose commit carries no card or
issue token (predates tracking); `—` in `date` marks no recorded touch
at all, and `--stale` sorts those rows first.

## Row grammar (what the checker reads)

- `app` — the manifest display name (apps.txt field 2).
- `binary` — the manifest executable (field 1). Rows appear in manifest
  order; the checker enforces exactly one ledger row per apps.txt row,
  in order.
- `last refresh` — the card that did it: whitespace-separated tokens,
  each either `Mnnnx` (a card) or `#issue`, or the whole cell `—`.
- `date` — ISO-8601 `YYYY-MM-DD`, or `—` only when `last refresh` is
  `—` too.
- `notes` — free text: what the touch was.

## The ledger

| app | binary | last refresh | date | notes |
|-----|--------|--------------|------|-------|
| 64-bit Calc | GOCALC.ELF | #3248 | 2026-10-23 | appver 1 envelope — mode + bounded tape + copy-tape verb |
| Text Editor | NOTE.ELF |  #3247 | 2026-10-23 | appver-1 envelope + status bar |
| Code Editor | GOEDIT.ELF |  #2991 | 2026-10-22 | per-function heat gutter from `--prof=` .folded |
| Files | GOFILES.ELF |  #3255 | 2026-10-23 | .vcf contact-card face — QuickLook pane + GOMAIL hand-off |
| Terminal | GOTERM.ELF |  #3251 | 2026-10-23 | notify-on-finish toast for >5s unfocused commands |
| Web | WEB.ELF |  #3142 | 2026-10-22 | a11y keys honoured — WEB text_scale |
| Pulse | PULSE.ELF |  #2959 | 2026-10-21 | lipgloss v2 |
| Shell | GOSH.ELF |  #2775 | 2026-10-20 | shlib heredocs |
| Help | GOHELP.ELF |  #3129 | 2026-10-22 | free-file sleep sites → ns durations (tree-wide) |
| Welcome | GOWELCOME.ELF |  #2571 | 2026-10-19 | first-boot welcome tour |
| Top | GOTOP.ELF |  #3249 | 2026-10-23 | appver-1 envelope — sort + active tab persist |
| Settings | GOSET.ELF |  #3171 | 2026-10-22 | settings table grows past 24 via bounded second bank |
| Image Viewer | GOVIEW.ELF |  #3155 | 2026-10-22 | MOV demux + Motion-JPEG playback |
| Sound | GOSOUND.ELF |  #3178 | 2026-10-22 | extract user/go/pcm (with GOREC) |
| Tabbed Desktop | TABWM.BIN |  #3226 | 2026-10-23 | docs litterbox touched the fallback source |
| Gostalgia | GOSTALGIA.ELF | M97g | 2026-10-09 | eight owner-approved security follow-ups (#2080 et al.) |
| Store | GOSTORE.ELF |  #3188 | 2026-10-23 | store pin — signed-head rollback + ReleaseDepends |
| LLM Infer | GOINFER.ELF |  #2784 | 2026-10-20 | engine becomes user/go/infer |
| Recorder | GOREC.ELF |  #3178 | 2026-10-22 | extract user/go/pcm (with GOSOUND) |
| Snapshots | GOSNAP.ELF |  #2561 | 2026-10-19 | windowed GOSNAP + PWR menu Snapshot row |
| Assistant | GOASSIST.ELF |  #3145 | 2026-10-22 | romaji→kana composition in a text field |
| Sheet | GOSHEET.ELF |  #2915 | 2026-10-21 | v2 — fill series, 32-step undo, column formats, blob v2 |
| Reader | GOREADER.ELF |  #3244 | 2026-10-23 | shared appkit find overlay — GOREADER migrates |
| Clock | GOCLOCK.ELF |  #3254 | 2026-10-23 | editable events — ical write-back |
| Mines | GOMINE.ELF |  #2918 | 2026-10-21 | GOMINE best times (with GOSOL undo + stats) |
| Solitaire | GOSOL.ELF |  #2918 | 2026-10-21 | undo-in-blob + stats + chime |
| Emoji | GOEMOJI.ELF |  #2917 | 2026-10-21 | v2 — recents + favorites shelf, save_state v2 |
| IRC | GOIRC.ELF |  #2919 | 2026-10-21 | v2 — /hl highlight rules, bounded per-channel logs |
| Vault | GOVAULT.ELF |  #3240 | 2026-10-23 | PWR Lock row + ctrl+shift-l screen lock |
| Mail | GOMAIL.ELF |  #3253 | 2026-10-23 | folder browse over real LIST + bounded /host/MAIL cache, offline search |
| Accessibility | GOA11Y.ELF |  #3143 | 2026-10-22 | appkit a11y outlines + GOA11Y reader |
