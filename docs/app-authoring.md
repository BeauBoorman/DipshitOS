# Authoring a VirelaiOS Go app

This is the short path from an empty `user/go/<app>/main.go` to an app
that can be staged into a VZ gate. It describes the Go EL0 surface; it does
not replace the syscall or window-management ADRs.

## 1. Start with the app shell

A normal windowed Go app uses `tabapp` for the window/WM handshake and
`appkit.Loop` for the lifecycle. `appkit` is deliberately small: it presents
once, dispatches close/resize events, and repaints only when the app says its
state changed.

```go
package main

import (
	"virelai/appkit"
	"virelai/tabapp"
	"virelai/vi"
)

const (
	appName  = "MYAPP.ELF"
	appTitle = "My App"
	natW     = 512
	natH     = 384
)

func draw(ta *tabapp.TabApp) {
	r := ta.Layout(tabapp.Rect{W: natW, H: natH}, natW, natH)
	// Replace this with the app's current frame and paint r into ta.Win.
	_ = r
}

func main() {
	ta := tabapp.Init(tabapp.Config{
		Name: appName, Title: appTitle,
		X: 32, Y: 32, W: natW, H: natH,
	})
	if ta == nil {
		vi.ConsoleLine("myapp: error open -1")
		vi.Exit(1)
	}
	vi.ConsoleLine("myapp: open id=" + vi.Itoa64(int64(ta.Win)))

	loop := appkit.NewLoop(ta, func() { draw(ta) }, nil)
	loop.OnInitialPresent = func() { vi.ConsoleLine("myapp: present") }
	loop.OnExit = func(status int) {
		ta.Close()
		vi.ConsoleLine("myapp: close") // after WinClose returned
		vi.Exit(status)
	}
	loop.Run()
}
```

`tabapp.Init` opens the window and makes a best-effort fullscreen-tab
declaration. A refused declaration is not fatal: the app remains a normal
window at its requested size. The live implementation is in
[`user/go/tabapp/tabapp.go`](../user/go/tabapp/tabapp.go); the lifecycle
implementation is in [`user/go/appkit/loop.go`](../user/go/appkit/loop.go).
The [`user/go/tabapp/demo`](../user/go/tabapp/demo) app shows widgets and
resize-aware drawing.

For keyboard, mouse, dialog, or button state, use the existing widgets and
pure helpers rather than inventing a second event or geometry model. The
small dialog state machine is in
[`user/go/appkit/dialog.go`](../user/go/appkit/dialog.go), and the widget
surface is [`user/go/widgets/widgets.go`](../user/go/widgets/widgets.go).

A TTY application is different: it owns `/dev/tty` and feeds terminal bytes
into its own model. [`user/go/charmhello/main.go`](../user/go/charmhello/main.go)
is the bound-tty/Bubble Tea example; do not put a TUI behind the widget
window loop merely because both are Go apps.

## 2. Markers are evidence, not decoration

A gate marker must be printed only after the operation that makes it true has
returned. For example:

```go
ta.Present()
vi.ConsoleLine("myapp: present") // after WinPresent returned
```

Likewise, print an error only after the syscall or operation that produced it
has returned, and keep the marker's value stable enough for a spec to pin.
`vi.ConsoleLine` is serial-observable; bytes written to a windowed `/dev/tty`
paint the terminal grid instead. Choose the channel deliberately, and never
claim a result from a marker printed before the work.

## 3. WM_RPC: ask, do not bypass

Apps do not call the WM-only `wmctl` syscall. They send a 38-byte WM_RPC
frame through the registered seat with the helpers in
[`user/go/vi/wmclient.go`](../user/go/vi/wmclient.go). The frame is bounded:
64-byte mailbox maximum, 24-byte title, 8-bit window id and requester, and a
short bounded wait for the matching ack. A timeout, missing seat, or invalid
width is an honest `false`, not a reason to spin.

The current `GOTABWM.ELF` Go seat applies these request kinds:

| Kind | Name | Meaning |
| ---: | --- | --- |
| 1 | `raise` | Focus/raise the tab. |
| 5 | `attach` | Add/attach the client tab. |
| 6 | `detach` | Remove the client tab. |
| 7 | `cycle` | Advance tab focus. |
| 8 | `declare_fullscreen` | Register the tab and propose the full viewport. |

The current `GOTABWM.ELF` seat refuses kinds **2 (`config`), 3
(`register_action`), 4 (`invoke_action`), 9 (`nav_declare`), and 10
(`nav_poll`)** with `applied=0`. Those kinds exist in the frozen/additive wire
vocabulary, but a guide must not imply that the current Go seat implements
them. Use the higher-level `tabapp` methods when available and handle refusal
explicitly if an app needs a capability that is not implemented yet.

`tabapp.Init` already performs kind 8. For an app that implements a later
capability, call the corresponding `vi` helper only after checking its return
value, and keep the fallback path in the same app rather than making the WM
silently guess.

## 4. Build and run the host tests

The guest build uses the pinned `GOOS=virelai` fork. Ordinary Go package tests
run from the module root:

```bash
cd user/go
go test ./...
```

A shipping app gets a small builder beside the existing builders. The compact
[`tools/go/build-goterm.sh`](../tools/go/build-goterm.sh) is the basic example;
[`tools/go/build-rss.sh`](../tools/go/build-rss.sh) shows the complete current
image checks. A builder must:

1. set `GOOS=virelai GOARCH=arm64`, `CGO_ENABLED=0`, and the pinned
   `GOROOT`; use `GO111MODULE=off` with a temporary `GOPATH` for a basic app,
   or the transient module/overlay shape when the app has external modules;
2. build `virelai/<app>` to `.build/go/<APP>.ELF`;
3. fail if the output is missing or its initialized image exceeds 32 MiB; leave
   the loader's 64 MiB mapped-image bound and any stricter ceiling required by
   the chosen image shape enforced; and
4. leave module-cache and repository sources unchanged.

Run the builder before a live gate:

```bash
bash tools/go/build-myapp.sh
```

The guest has no libc or POSIX. Prefer the in-tree packages under
[`user/go`](../user/go) — vi, tabapp, appkit, widgets — over host-only
standard-library assumptions.

## 5. Add one declarative gate

Copy the shape of [`tools/gate/specs/go-charmhello.spec`](../tools/gate/specs/go-charmhello.spec),
not a new ad-hoc verification script. A useful app spec has:

- a `vgate_name`, `vgate_share seed`, and runner flags;
- a monitor script that launches the app;
- a setup block that fails honestly if `.build/go/<APP>.ELF` is missing, then
  stages it into the share;
- a bounded `vgate_run` with a script/input stage keyed to an app marker;
- `vgate_assert` lines for boot, launch, lifecycle, and absence of crashes;
- a final `--script-expect` set to the app's post-close marker, so the runner
  stops only after that marker rather than after a script-supplied echo.

Use `--input-chords` for HID input, `--input-string` for literal text, and
`--screenshot-after` only when the claim is about scanout pixels. The gate must
be able to fail if the app is replaced by a constant: sequence on a marker
emitted after the syscall or after real work, and assert a value that the guest
computed. Keep each run bounded; a missing marker is a failure, never a skip.

The reusable spec format is documented in
[`tools/gate/SPEC.md`](../tools/gate/SPEC.md). Run one class-B member with:

```bash
just gate <gate-id>
```

A class-A host test is still useful for pure state and byte-shaping logic, but
it is not a substitute for the VZ gate when the card claims real guest input,
window ownership, or pixels.

## 6. Ship it in the desktop catalogue

For a user-visible app, add its executable to [`image/apps.txt`](../image/apps.txt)
with the display name, icon, and (when appropriate) `dock=true`. Keep the
manifest executable name and the builder's output name in agreement. A gate
may stage an app directly without adding it to the daily catalogue, but that
proves the binary, not the launcher integration.

## 7. Claim a manifest entry (M82a, #1768)

The catalogue row in [`image/apps.txt`](../image/apps.txt) — baked into the
image as `/host/APPS.TXT` — is a **versioned, additive** schema. Fields 1–4
are the v1 shape every reader already parses; everything a v2 row adds is a
trailing `key=value` field:

```
NAME | Display Name | icon | dock=true | v=2 | argv= | caps= | opens=
```

A minimal v2 entry for an undocked app:

```
MYAPP.ELF | My App | y | dock=false | v=2 | caps=window | opens=text
```

The rules the parser actually enforces (the format's normative description is
the comment header at the top of `image/apps.txt`):

- A row with a tail must carry `v=` and all four positional fields: field 4 is
  the dock flag in every reader, so an undocked v2 row writes `dock=false`
  rather than leaving the field empty. A `v=` value that is not a positive
  integer refuses the row instead of guessing at it.
- Trailing fields are order-insensitive and unknown keys are ignored, so a v1
  reader that stops at field 4 is not wrong. No `v=` means v1 and no trailing
  fields are honoured.
- `argv=` is the fixed arguments after the binary, space separated, at most 8
  (the kernel's exec ceiling). Extra arguments are dropped rather than refused
  — the app still launches.
- `caps=` is declarative metadata: nothing grants or gates power from it. The
  vocabulary is `file window audio timer memory process debug net term`, the
  WASM import contract's Cap names.
- `opens=` names what the app can be handed: an M81b mime type (`text image
  audio archive binary document`), a URL scheme (`http https`), or an
  M124a subtype spelling — text/plain, image/png — where a bare family
  word takes any subtype on the drag hit-test and a subtype spelling
  takes only itself (chapter 18). A fourth trailing key,
  `selection=primary`, opts the app into the seat's primary selection
  (chapter 22).
- Every launcher-visible row must open a window (M122c, #2572): a bare
  launch that can only print usage to the serial console dies silently —
  `TestManifestHonestyRowsOpenAWindowOrAreSeatBound` fails the row. A
  pure-CLI tool does not get a row; it is driven from the shell's `exec`.
- Keep the manifest small: every reader buffers 4096 bytes and a file at or
  over that is truncated at the last whole line, silently dropping tail rows
  from a seat's menu.

The Go decoder is pure and host-tested
([`user/go/gotabwm/apps.go`](../user/go/gotabwm/apps.go), `parseAppLine`), and
its tolerance of trailing v1 fields is itself pinned. The seam is pinned by
[`go-wm-default`](../tools/gate/specs/go-wm-default.spec) (dock decode),
[`go-dogfood`](../tools/gate/specs/go-dogfood.spec) (launcher row → entry) and
[`live-inventory`](../tools/gate/specs/live-inventory.spec).

## 8. Settings: subscribe, do not re-read (M82b, #1769)

When a persisted setting changes, the seat broadcasts the key over the same
WM_RPC wire the rest of the app platform uses. The mailbox carries only the
key and never becomes a second settings store: the subscriber re-reads the
persisted value. With `appkit` the common case is one line inside the section
1 skeleton:

```go
var theme string // the app's current theme; draw() reads it

loop := appkit.NewLoop(ta, func() { draw(ta) }, nil)
loop.SubscribeSetting("theme", func(value string) bool {
    theme = value // value is the current persisted value
    return true   // true only when the frame changed: the loop presents
})
loop.Run()
```

The handler runs in the same loop that dispatches window and input events,
and `loop.OnSettingPresent` fires after the resulting frame was presented — a
marker printed there is honest (section 2). A key `settings.Editable` refuses
is not subscribed: `SubscribeSetting` returns false and the app keeps its
static behaviour.

Outside the loop the same seam is explicit: `settings.Subscribe(key,
uint32(ta.Win), appName)` subscribes and `settings.PollChange(uint32(ta.Win))`
consumes one delivered key. A writer is GOSET's shape — save crash-safe first,
publish only after the save returned:

```go
f := settings.Load()
f.Rows = settings.Set(f.Rows, "theme", "light")
if f.Save() == 0 {
    settings.PublishChange("theme", uint32(ta.Win), appName) // after Save
}
```

Subscribing is best-effort like every WM_RPC call: a missing seat, a timeout,
or an id that does not fit the wire is an honest `false`. The seam is pinned by
[`go-wm-seat`](../tools/gate/specs/go-wm-seat.spec) (the codec and the notice
dispatch) and [`go-wm-default`](../tools/gate/specs/go-wm-default.spec) (app A
changes a setting, app B's repaint follows without a restart).

## 9. Chords: one owner per chord (M82c, #1770)

A global shortcut is a row in the registry
[`user/go/chords/table.go`](../user/go/chords/table.go) — the one table that
names every global chord, its owner, and the dispatch point it is served at.
An app's chords are rows in the app's own scope, which exclusive focus makes
legal (GOEDIT.ELF and NOTE.ELF both own `ctrl+s`, at different dispatch
points):

```go
{Chord{ModCtrl, UsageS}, "MYAPP.ELF", AppScope("MYAPP.ELF"), "",
    "save the document", "#<your card>", false},
```

The fields are the chord (modifier mask plus USB HID usage), the owner (the
app binary), the scope — `AppScope("MYAPP.ELF")` must name the owner;
`Validate` refuses drift — an action name (seat rows only), the label GOSET
shows, the card that landed the row, and the frozen flag (kernel chrome rows
only).

Adding the row is how you claim the chord. `chords.Table.Validate()` refuses
two owners of one chord at one dispatch point with the named
`ErrChordConflict` sentence, so a conflict fails the `user/go/chords` host
tests and trips the seat's fail-closed prologue (the deliberate fixture is
seeded through `/host/GOTABWM.CHORDCONFLICT` and refused) rather than
surprising a person.
GOSET's shortcuts view (its own registered chord, `ctrl+shift+h`) renders the
whole table — look there before you claim anything. The seam is pinned by
[`go-wm-hid`](../tools/gate/specs/go-wm-hid.spec) (the registry walk, the
refused fixture, the table dump, the GOSET view) and
[`live-help`](../tools/gate/specs/live-help.spec) (the monitor's chord list is
unchanged).

## 10. Notify: tell the user something (M82d1/d2, #1771/#1785)

```go
if !ta.Notify("copied notes.txt") {
    vi.ConsoleLine("myapp: notify refused") // the user was not told; say so
}
```

One call (WM_RPC kind 12). The frame's 24-byte title is the whole message
budget, so the text is a short human string — never a path or a payload. The
request id is the sender, so the toast is click-to-focus back to your tab;
when an app dies its toasts are dropped with it (the M52 client-death
discipline) while the notifications center keeps the history.

Best-effort, and the refusals are honest: empty text, a sender with no tab, a
missing seat, or a timeout ack all return `false`. A full toast queue drops
its oldest entry and counts the drops. Return values are the only truth —
never assume the user was told.

Do-not-disturb is the user's choice, not an error. With the `notify_dnd`
settings key on (GOSET's row, or the center's header toggle) the seat still
acks your notice — an app must not learn the user is away — but holds the
toast off the strip. The notice lands in the notifications center and its
crash-safe history survives a seat restart. So `true` means "the seat took
it", not "the user saw it". The seam is pinned by
[`go-wm-seat`](../tools/gate/specs/go-wm-seat.spec) (notify → center lists →
dismiss → clear), [`go-dogfood`](../tools/gate/specs/go-dogfood.spec) (DND
holds the toast but keeps the notice; history survives the restart) and
[`go-wm-default`](../tools/gate/specs/go-wm-default.spec) (the DND key and the
corrupt-history heal).

## 11. Logs and crash receipts (M82e, #1772)

When an app misbehaves there must be somewhere to look. `vi.Log` appends one
line to a bounded per-app ring on the share, and the failure path publishes a
receipt — the GOSELF shape:

```go
defer func() {
    if recovered := recover(); recovered != nil {
        outcome := "panic"
        if s, ok := recovered.(string); ok {
            outcome += ": " + s
        }
        _ = vi.Log(appName, outcome)
        _ = vi.WriteCrashReceipt(appName, outcome) // /host/CRASH/MYAPP.ELF.TXT
        vi.Exit(2)
    }
}()
_ = vi.Log(appName, "started")
```

The ring is `/host/APPLOG/<APP>.LOG`: at most 32 lines of 256 bytes, each
message normalized to one line and capped before it enters. The receipt at
`/host/CRASH/<APP>.TXT` carries the app, the outcome, and the last eight log
lines. These are deliberately small share files a host-side helper can read
after the app exits — diagnostic records only, never an isolation or
authorization mechanism (ADR 0024). In the guest, GOSH's `log [APP]` reads
one app's ring or all of them (`log` with no argument).

Markers still rule (section 2): log the line after the work returned.
`GOSH.ELF` logs its own start/exit and writes a receipt on every exit — copy
that shape rather than inventing a second one. The seam is pinned by
[`go-panic`](../tools/gate/specs/go-panic.spec) (a panicking app leaves a
receipt the host reads), [`go-selftest`](../tools/gate/specs/go-selftest.spec)
(the ring-buffer receipt, host-compared) and
[`go-sh`](../tools/gate/specs/go-sh.spec) (the `log` builtin).

## 12. The versioned dev loop: FLINT in the guest (M107d, #2321)

The guest edits, builds, and runs its own programs, and FLINT
(`FLINT.ELF`, [`user/go/flint`](../user/go/flint/), ADR 0049) versions
that work without leaving the guest. One workspace per program: the
store lives at `/host/FLINT`, each workspace is a name under
`/host/FLINT/ws/` bound to a `/host` source dir, and `src` on disk stays
the source of truth — streams carry Atom hashes and Ops, not source
text.

A fresh guest needs two entries in `SECRETS.TXT` (the staged shape is in
[`go-flint`](../tools/gate/specs/go-flint.spec)):

- `agent-sign`, app-bound to `FLINT.ELF` — the Ed25519 seed `commit`
  signs every Change with. Missing → `flint: refuse secret_not_found`
  and nothing is written.
- `flint-remote` — the FLINT-SYNC/1 `--auth-key` shared with `flintd`
  for `push`/`pull`/`clone`/`ls-remote`. Wrong → `flint: refuse
  auth_failed`.

The loop, from GOSH:

```sh
FLINT.ELF init --name=myapp --src=/host/MYAPP   # once; ws_exists, src_missing
GOEDIT.ELF /host/MYAPP/main.go                  # edit (M107c)
GOBUILD.ELF /host/MYAPP -o /host/MYAPP.ELF      # build (M107a)
MYAPP.ELF                                       # run
FLINT.ELF add /host/MYAPP                       # stage; syntax, parse_unsupported,
                                              # duplicate_decl refuse atomically
FLINT.ELF status                                # staged Op counts + names
FLINT.ELF diff                                  # staged Ops by file (below)
FLINT.ELF commit -m "describe the change"       # nothing_to_commit,
                                              # message_invalid, secret_not_found
FLINT.ELF push --remote=<host>:4748 --stream=main
                                              # auth_failed, stale_head,
                                              # stream_missing (no --stream and
                                              # no REMOTE.json binding yet)
```

`push` creates the stream on the remote when needed and sends the unsent
suffix of the raw Change log; it writes `<ws>/REMOTE.json` so later rounds
are a bare `flint push`. On the host, against the served store:

```sh
flint verify --all --store <store-dir>
```

Each pushed line lands verbatim, so a byte-compare of the last line of
the guest's `/host/FLINT/streams/<id>.jsonl` against the server's
`streams/<id>.jsonl` plus `flint verify` proves the signature chain end
to end.

`flint diff` is a status-depth diff, not a content diff — FLINT tracks
hashes, not source lines. It prints
`flint: diff ws=<n> stream=<s> files=<f> staged=<n> add=<a> modify=<m> delete=<d>`
then one `flint: diff <type> <file> <qualified-name>` per staged Op
(capped at 64, `flint: diff … +<n>` overflow). Deletes carry only an
AtomID, so their file and name resolve by replaying the workspace's
stream chain for the introducing add Op; an Atom that resolves nowhere
prints `-` and its AtomID.

The build leg is pinned by
[`live-gobuild`](../tools/gate/specs/live-gobuild.spec); the FLINT verbs
by [`go-flint`](../tools/gate/specs/go-flint.spec); the whole
init→edit→add→diff→commit→push→host-verify round-trip by
[`live-flint-loop`](../tools/gate/specs/live-flint-loop.spec). The
capstone — a real app (GODIFF, a unified context diff) authored through
GOEDIT, built by in-guest GOBUILD, run, committed and pushed by FLINT,
verified byte-for-byte and cryptographically on the host — is pinned by
[`live-godiff-loop`](../tools/gate/specs/live-godiff-loop.spec).

Two share-transport facts matter for `flint push` specifically: FLINT's
store index resolves `--stream=<name>` by listing `/host/FLINT/streams/`, and
the legacy cv channel's frozen directory rows truncate names at 31
bytes — a `<uuid>.json` record is 41, so on a cv-only share the push
refuses `stream_missing`. Mount the share with `--virtio-fs` (the paged
listing backend) for push legs. The `vf ls` monitor command shows what
the guest's readdir actually sees; a truncated tail is the tell.

Before opening a PR, run the focused host tests, the app's class-B gate,
`bash tools/status/verify-issue-coordination.sh`, and the relevant portable
checks. The canonical gate policy is in [`docs/testing.md`](testing.md); the
canonical milestone state is in [`docs/status.md`](status.md).

## 13. The `?` overlay: chord hints (M121c, #2566)

A user who presses `?` in a hints-aware app gets a modal plate listing
every chord that answers while the app is focused — the app's own scope
first, then the seat scopes the caller names — rendered out of the live
registry, never a hard-coded sheet. `appkit.ChordHints`
([`user/go/appkit/hints.go`](../user/go/appkit/hints.go)) is the same
shape as the file picker: a pure state machine with `Draw` for canvas
apps and `Lines` for VT grids. The registry is the chapter-9 table, so an
app that declared its chords honestly gets its help plate for free.

GOEDIT's arm is the whole contract — a plain `?` in the edit modes, while
the find bar keeps `?` as a literal
([`user/go/edit/main.go:987`](../user/go/edit/main.go)):

```go
if (e.mode == modeEdit || e.mode == modeDiags) && ev.Arg1 == '?' &&
    ev.Flags&(modCtrl|vi.ModAlt) == 0 {
    e.hints = appkit.NewChordHints(appName)
    e.mode = modeHints
    e.hintsEmit = 1
    return true
}
```

`NewChordHints` takes the binary name so the app scope resolves against
the registry, and the emitted receipt (`goedit: hints n=40`) is the row
count on the painted frame. Open the overlay as a mode — modals own the
keyboard while they stand — not as a floating widget beside the app's
own input. The seam is pinned by
[`go-dogfood`](../tools/gate/specs/go-dogfood.spec) boot 09: the M121f
acceptance drives `?`, dumps the `hints row` lines, and asserts the plate
in pixels.

Bounds: rows are read at open, so a chord the app handles outside the
registry never appears on its own plate; and a VT app renders `Lines`
itself (GOFILES's truecolour grid, GOTERM's alternate screen).

## 14. Undo is a seat chord (M121e, #2568)

Plain `ctrl+z` belongs to the seat, not the app. The registry's seat row
routes it to the focused tab, the KEY_DOWN arrives unchanged (ADR 0009),
and `TabApp.Dispatch` classifies it as `ActionUndo` — consumed, never
delivered to the app's own key handling. The app answers through one hook
([`user/go/tabapp/tabapp.go:70`](../user/go/tabapp/tabapp.go)):

```go
// M121e (#2568): the undo hook. The seat's ctrl+z chord routes to the
// focused tab, whose own KEY_DOWN arrives here unchanged (ADR 0009) —
// Dispatch classifies it as ActionUndo and the app's loop calls Undo(),
// which runs this hook. A nil hook is the documented no-op default:
// the chord is still consumed, nothing is reverted. True means the
// hook ran an undo step — the caller repaints on it.
HandleUndo func() bool
```

GOEDIT wires its buffer's op ring
([`user/go/edit/main.go:685`](../user/go/edit/main.go)):

```go
HandleUndo: func() bool {
    e.undo()
    return true
},
```

Return true only when a step was reverted — the loop repaints on it. A
nil hook is the documented no-op: the chord is still consumed, so never
shadow it with a second in-app binding. Shifted spellings are not the
seat chord — `ctrl-shift-z` stays the app's own redo. The seam is pinned
by [`go-edit`](../tools/gate/specs/go-edit.spec) run 05 (`goedit: undo
n=` three deep, `undo none` at the floor, the post-undo buffer verified
on the host) and by [`go-dogfood`](../tools/gate/specs/go-dogfood.spec)
boot 09 (`gotabwm: undo id=` routes, the buffer answers `undo n=0`).

## 15. Empty surfaces are a widget (M123b, #2576)

A zero-content surface is still a surface. `widgets.EmptyState`
([`user/go/widgets/empty.go`](../user/go/widgets/empty.go)) is the shared
presenter: a Surface plate ringed in Border carrying an optional icon
row, a headline, and chord-hint lines, centred in the rect the content
would have filled. GOFILES's empty list, WEB's start viewport, GOEDIT's
empty buffer, and the launcher's zero-match all run the same model, so a
user never meets a bare rect.

Canvas apps `Draw` it; a VT surface renders the same content through
`Lines` — GOFILES's row model is the text half
([`user/go/files/render.go:364`](../user/go/files/render.go)):

```go
func (m model) emptyListRows(w, body int) []string {
    return widgets.EmptyState{
        Icon:     "Ø",
        Headline: "This folder is empty",
        Hints:    []string{"p paste · backspace up", "v volumes · q quit"},
    }.Lines(w, body)
}
```

The hints should name chords that still answer on the empty surface —
paste, climb, quit — not ones that need a selection. The seam is pinned
by [`go-dogfood`](../tools/gate/specs/go-dogfood.spec): its per-boot
refusal-pairing audit counts a `: empty` plate as a named non-failure
surface and fails a boot whose only evidence of a refusal is on the
serial.

## 16. Progress the user can cancel (M123c, #2577)

`appkit.Progress` ([`user/go/appkit/progress.go`](../user/go/appkit/progress.go))
is a pure determinate-or-indeterminate bar: `Set`/`Advance`/`Tick`
mutate, `Draw` paints through the canvas contract, and `Phase` steps the
sweep once per repaint cadence. Its `Op` field is the seat half: a
nonzero op posts the bar's state to a notifications-center row over
WM_RPC kind 22, and the user's Cancel comes back on
`vi.PollProgressCancel` — poll it once per loop pass and route the
returned op to the matching bar, which is why the op is the app's own
handle rather than a widget index.

WEB's download is the forcing adopter
([`user/go/browser/downloads.go:177`](../user/go/browser/downloads.go)):

```go
d.prog = appkit.NewProgress(widgets.Rect{}, len(body))
d.prog.Op = downloadOp
d.prog.Label = name
d.prog.ShowValue = true
```

— and its loop posts `vi.NotifyProgress` when the percent crosses a
tenth (`:295`). A zero `Op` is the widget-only bar that never reaches
the seat: legal, silent. The end-to-end wire — bound window, report,
Cancel, the app's kind-23 receipt — is driven by GOPROGRESS.ELF
([`user/go/goprogress/main.go`](../user/go/goprogress/main.go)) and
pinned by [`go-wm-seat`](../tools/gate/specs/go-wm-seat.spec) run 16.

## 17. Fail inside the frame: the error banner (M123d, #2578)

The in-app counterpart of the seat's refusal toast. `appkit.ErrorBanner`
([`user/go/appkit/banner.go`](../user/go/appkit/banner.go)) is a
non-modal strip the app's own frame paints — the failure text, a Copy
Error button, and contextual action buttons (Replace and Cancel for a
rename conflict) — stealing keys and clicks only while open and never
drawing outside its rect. The state machine is pure:
`HandleKey`/`HandleMouse` set `Choice` and the app acts on the result;
VT apps drive the same machine through `Activate`/`Dismiss`/`Cycle` and
render `Line(cols)` — GOFILES maps its keys onto it exactly so.

The banner never syscalls: Copy Error hands back a `BannerCopy` choice
and the app runs its own clipboard seam — GOFILES's resolution is the
shape ([`user/go/files/act.go:155`](../user/go/files/act.go)):

```go
case choice == appkit.BannerCopy:
    n, rc := vsys.ClipboardSetTyped(vsys.ClipText, []byte(m.banner.Text))
```

An action choice is an app vocabulary word (`replace`, `cancel`), not a
banner enum: the banner reports, the app decides. The seam is pinned by
[`go-dogfood`](../tools/gate/specs/go-dogfood.spec) — the same per-boot
audit counts `<app>: banner` and `<app>: banner act` as the honest
surfaces a serial-only refusal must not substitute for.

## 18. Drag a payload between apps (M124a, #2580)

A real pointer drag — press, held move, release over another tab — moves
bytes between apps through the seat. Three hooks on `tabapp.Config`
([`user/go/tabapp/tabapp.go:57`](../user/go/tabapp/tabapp.go)):

```go
DragSource func() (mime string, blob []byte, ok bool)
DropTarget func(offer DragOffer)
DragEnd    func(delivered bool, peer uint32)
```

The source arm: the gesture calls `ta.BeginDrag()`, the seat asks
`DragSource` for the (mime, blob) pair, stages the blob at the window's
rendezvous path, and posts kind-24 with the mime in the frame title.
From there the seat owns the ghost, the hit-test, and the `opens=`
admission — the target's manifest row is the gate, so a drop lands only
where the mime is acceptable. `DropTarget` receives a `DragOffer`: the
agreed mime, the source window id, and the payload consumed from the
target's own rendezvous path — a nil `Blob` is a transport failure the
app is told about, never a silently-empty payload. `DragEnd` is the
source's outcome notice (`delivered=true` with the peer, or false on a
cancel); `ta.CancelDrag()` is the app-side Esc. Service the asynchronous
frames with `ta.PollDrag()` once per loop pass, the same discipline as
`PollStateAsk`.

The honesty rule is the clipboard's: the declared mime must describe the
bytes. GOFILES's `fileMime`
([`user/go/files/drag.go:60`](../user/go/files/drag.go)) names a row by
its sniffed family refined to the subtype the in-tree decoders read, and
unknown bytes answer application/octet-stream.

The seam is pinned by [`go-drag`](../tools/gate/specs/go-drag.spec) —
GOFILES drags a file onto GOEDIT (text/plain splice) and GOVIEW
(image/png decode) through the live seat — and by
[`go-dogfood`](../tools/gate/specs/go-dogfood.spec), whose boot leg arms
a drag with a real press+move and asserts `"goedit: drop text/plain"`
plus the source's `gofiles: drag end delivered` receipt.

## 19. One file picker for every app (M124b, #2581)

No app grows its own path prompt. `appkit.FilePicker`
([`user/go/appkit/filepicker.go`](../user/go/appkit/filepicker.go)) is
the shared modal: one state machine covering open and save (`PickOpen`
and `PickSave` — the same list, a different verb and `Result` meaning),
painted with `Draw` on a canvas or driven through its own renderer on a
text surface.

`NewFilePicker` clamps the start dir onto the share root when it is
empty or off-share (`:101`):

```go
func NewFilePicker(kind PickerKind, dir string) FilePicker {
```

The listing is three things in one scroll: the current directory (a `..`
climb row, subdirectories, files), the vi recent log's newest distinct
paths, and /host/TRASH's pending items — Enter on a trash row restores
it in place rather than picking it, and `PickerRow.Kind` names which
activation a row takes. `Tab` walks focus from the list across the
buttons so the keyboard reaches Cancel; `Activate` descends a directory,
picks a file, restores a trashed path, or takes the typed `Input`
resolved against `Dir`.

Adopters: GOEDIT and WEB `Draw` it
([`user/go/edit/main.go:1224`](../user/go/edit/main.go),
[`user/go/browser/saveas.go:33`](../user/go/browser/saveas.go)), GOSHEET
imports and exports through it
([`user/go/gosheet/main.go:480`](../user/go/gosheet/main.go)), GOREADER
saves a byte copy through it
([`user/go/goreader/main.go:595`](../user/go/goreader/main.go)), and
GOFILES's pick mode runs the same model over the bound tty —
`exec GOFILES.ELF pick [dir]` paints the rows as ANSI and prints
`gofiles: picked <path>` on the serial
([`user/go/files/pick.go:1`](../user/go/files/pick.go)).

The seam is pinned by [`go-fileman`](../tools/gate/specs/go-fileman.spec)
run 09 (the pick-mode directory leg),
[`go-reader`](../tools/gate/specs/go-reader.spec) (a document saved
through the picker), and [`go-dogfood`](../tools/gate/specs/go-dogfood.spec)
(a typed save name resolved against the picker's cwd, then reopened).

## 20. The clipboard is typed (M124c, #2582)

The kernel clipboard is still one raw byte buffer — the type is a
reading of the bytes, not an envelope field. `vsys`
([`user/go/vsys/cliptype.go`](../user/go/vsys/cliptype.go)) classifies on
both paths: `ClipboardClassify` derives what a body IS (magic for
images, shape for the text types, octet-stream for the unnameable), and
`ClipboardSetTyped` takes the writer's DECLARED mime and refuses it when
the bytes cannot be that thing — the same rule the drag arm pins, so a
label and the delivered bytes can never describe different things:

```go
func ClipboardSetTyped(mime string, blob []byte) (int, int64)
func ClipboardGetTyped(buf []byte) (mime string, n int, rc int64)
```

A reader never sees the declaration; it sees the classification of the
bytes, so a legacy reader (the kernel paste chords, slot 39) still gets
the blob undisturbed. The vocabulary is `ClipText`, `ClipURIList`,
`ClipHTML`, `ClipCSV` (chapter 24), `ClipPNG`, `ClipQOI`, `ClipGIF`,
`ClipJPEG`, `ClipBMP`, and `ClipOctet` — the honest "we cannot name
it", never a label to reach for. Bounds are the wire's own: the blob is
the kernel buffer's 512 bytes and a spelling is `ClipMimeMax` = 24, the
WM_RPC title budget. Writing needs the clipboard capability — a gate
leg's `exec -u0` is the capable path — and a refused Set is an honest
negative rc, never a partial write.

Writers: GOSHEET copies its used box as text/csv
([`user/go/gosheet/main.go:324`](../user/go/gosheet/main.go)), GOVIEW
declares the decoded format's image mime
([`user/go/view/main.go:557`](../user/go/view/main.go)), GOFILES's batch
copy stages a uri-list
([`user/go/files/batch.go:387`](../user/go/files/batch.go)), and the
Copy Error arms in WEB and GOFILES declare text/plain. The seam is
pinned by [`go-dogfood`](../tools/gate/specs/go-dogfood.spec) (a
`gview: copy mime=image/png` receipt read back through `clip`),
[`go-sheet`](../tools/gate/specs/go-sheet.spec) runs 03/05 (a csv
round-trip; `clip-too-large` refuses an over-bound copy), and
[`live-host-clipboard`](../tools/gate/specs/live-host-clipboard.spec)
(the host negotiation leg).

## 21. Open With: the registry is the menu (M124d, #2583)

`mime.Open` was already the shared "open this" decision — magic, then
extension, then the text heuristic. The registry half —
`Register`/`Handlers`/`Default` in
[`user/go/mime/mime.go:261`](../user/go/mime/mime.go) — is data: the
first registration for a type is the default `Open` dispatches to, and
the rest are the candidates a menu lists:

```go
func init() {
    Register(Image, "GOVIEW.ELF", "Image Viewer")
    Register(Text, "GOEDIT.ELF", "Code Editor")
    Register(Image, "GOEDIT.ELF", "Code Editor (raw bytes)")
    Register(Audio, "GOSOUND.ELF", "Sound Player")
    Register(Document, "GOREADER.ELF", "Reader")
    Register(Text, "GOSHEET.ELF", "Sheet")
    Register(Image, "GOPAINT.ELF", "Paint")
}
```

An app joins the table by declaring `opens=` on its manifest row
(chapter 7) and registering at init — the M132b wave reserved GOREADER
for Document, GOSHEET as a second Text candidate, and GOPAINT as a third
Image one, and order matters because the first registration stays the
default. The eligibility rule is one function both sides run: GOFILES's
context menu matches the file's `fileMime` spelling against manifest
`opens=` rows through `opensAccepts`
([`user/go/files/manifest.go:147`](../user/go/files/manifest.go)) — the
same rule the seat's drop admission runs — so "Open With…"
([`user/go/files/context.go:1`](../user/go/files/context.go)) can never
offer an app the seat would refuse to deliver to. A bare family word
takes any subtype; a subtype spelling takes only itself. `Register` is
a no-op for a repeated binary, so init cannot double-list itself.

The seam is pinned by [`go-fileman`](../tools/gate/specs/go-fileman.spec)
— a right-press descends "Open With…" and launches GOEDIT, with the
`gofiles: open with PIC.QOI type=image candidates=3` marker naming the
candidate count — and by [`go-selftest`](../tools/gate/specs/go-selftest.spec)
(the `mime` receipt pins the table and the default on the share).

## 22. The primary selection (M124e, #2584)

A second, gesture clipboard: select text and it is published;
middle-click or shift+insert pastes it — no copy chord. Opt-in is a
manifest word, `selection=primary` on the app's row — a real gate: no
word, no publish, no delivery (GOEDIT and GOTERM carry it in
[`image/apps.txt`](../image/apps.txt)).

The sink is one hook on `tabapp.Config`
([`user/go/tabapp/tabapp.go:68`](../user/go/tabapp/tabapp.go)): the seat
stages the buffer at the window's rendezvous path and pushes a kind-28
notice; `ta.PollSelPaste()` once per loop pass consumes it and calls
`SelPaste` with the bytes — nil when the staged envelope was absent, a
transport failure the app is told about rather than a silently-empty
paste. The pull half is `ta.RequestSelPaste()`, an app's own chord
spelling of the paste gesture: `ok=false` is the honest no-paste —
empty buffer, no cap, or a transport refusal, all the same answer.
GOVAULT's password arm wraps the pull with one retry against the lossy
ring ([`user/go/govault/main.go:415`](../user/go/govault/main.go)).

The seam is pinned by [`go-dogfood`](../tools/gate/specs/go-dogfood.spec)
run 08 — publish, then a middle-click inside GOTERM's pane, receipted
`gotabwm: sel paste id=` — and a cap-less app never gets a delivery: the
seat refuses before the notice is posted.

## 23. Save state: the seat asks, the app answers (M125, #2586)

A snapshot or a close does not lose the app. Three hooks and a version
tag on `tabapp.Config`
([`user/go/tabapp/tabapp.go:31`](../user/go/tabapp/tabapp.go)): the app
owns the serialized format, the seat owns the lifecycle. `SaveState`
runs whenever the seat asks (a snapshot, a tab close); its bytes — at
most `AppStateMax` = 64 KiB — are staged at `/host/APPSTATE.<win>` and
stored verbatim. `RestoreState` runs inside `tabapp.Init` when the seat
held a blob for this tab — before the app draws, so a re-exec lands in
the same boot slice. `StateVersion` tags every saved envelope so a stale
serialization is refused by the app's own check, never silently misread.

GOFILES's wiring is the shape
([`user/go/files/main.go:196`](../user/go/files/main.go)):

```go
StateVersion: stateFmtVer,
SaveState:    func() []byte { return m.encodeState() },
RestoreState: func(b []byte) {
    restored, restoredOK = decodeState(b)
},
```

`SaveState` closes over the live model so an ask always serializes the
current session; `RestoreState` only decodes — the apply lands once the
first listing exists, and `ta.RestoredVersion` is the app's own check
against its format tag.

The ask/answer is asynchronous like every seat notice:
`ta.PollStateAsk()` once per loop pass answers a waiting ask — staging
`SaveState()` through the rendezvous file and posting the kind-20
request — and an app with no hook still answers, an empty blob is "no
state", and the seat's bounded collect drains deterministically instead
of burning its ask budget on silence. `ta.SaveStateNow()` is the
unsolicited push for when the app's own state moved. The wire itself —
envelope, rendezvous, refusals — is
[`user/go/vi/wmstate.go`](../user/go/vi/wmstate.go): `EncodeAppState`
refuses an over-bound blob, `DecodeAppState` refuses a short or
mismatched envelope.

The seam is pinned by [`go-fileman`](../tools/gate/specs/go-fileman.spec)
(`gofiles: state save`/`state restore`/`state refused` across a session
kill), [`go-wm-journey`](../tools/gate/specs/go-wm-journey.spec) (a
snapshot, a hard kill, `session reexec` with the panes and spaces
intact), and [`live-session-persistence`](../tools/gate/specs/live-session-persistence.spec).

## 24. Documents are their own mime (M132b, #2753)

`mime.Document` joins the type table in
[`user/go/mime/mime.go:44`](../user/go/mime/mime.go) — PDF today — so a
reader app claims `opens=document` without pretending the bytes are
text. Magic beats the name here too: %PDF- at offset 0. The manifest row
is the reservation —
`GOREADER.ELF | Reader | d | dock=false | v=2 | caps=file,window | opens=document`
in [`image/apps.txt:54`](../image/apps.txt) — and
`Register(Document, "GOREADER.ELF", "Reader")` keeps dispatch's default
(`:610`).

The same card extended the clipboard vocabulary: `ClipCSV` is a
text/plain refinement — the same UTF-8 shape rule with a name a sheet
declares honestly ([`user/go/vsys/cliptype.go:33`](../user/go/vsys/cliptype.go)).
GOSHEET's copy arm declares it
([`user/go/gosheet/main.go:324`](../user/go/gosheet/main.go)) and its
paste arm reads the classified mime (`:339`), so csv between apps is
typed bytes on the chapter-20 wire, not a convention.

The seam is pinned by [`go-reader`](../tools/gate/specs/go-reader.spec) —
three chains route a PDF to the handler: WEB downloads it as
`type=document` rather than navigating, GOFILES opens
`DOC.PDF type=document handler=GOREADER.ELF`, and the completion plate
dispatches `mime.Open` — and by
[`go-sheet`](../tools/gate/specs/go-sheet.spec) run 03 (the text/csv
lane read back through `clip`).

## 25. Mounts and mtime are real rows (M134a/b, #2759/#2760)

`/host`, `/disk`, and `/usbN` are rows in one kernel mount table
([`kernel/src/mount_table.zig`](../kernel/src/mount_table.zig)), not
ad-hoc prefixes. `sys_dir_list("/")` enumerates it — one `DirEntry` per
row, the Reserved triple carrying state, kind, and flags — so
`vi.Mounts()` ([`user/go/vi/mounts.go:114`](../user/go/vi/mounts.go))
hands the app every volume's name, live state, kind, and read-only flag
in one call, and `vi.MountNamed` resolves a single row:

```go
// Mount kinds, as they ride DirEntry.Reserved[1].
const (
    MountKindShare uint8 = 1 // /host — the --cvc-file share
    MountKindVLFS  uint8 = 2 // /disk — the opt-in VLFS data volume
    MountKindBlock uint8 = 3 // /usb  — the raw MSC device, a byte stream
    MountKindFAT32 uint8 = 4 // /usbN — MBR partition N's FAT32 volume
)
```

A path resolved onto a not-mounted row answers ENXIO; `vi.ErrNotMounted`
names it and `vi.MountErr`/`vi.IsNotMounted` map the raw errno.

The mtime half is the slot-79 stat: fs_metadata op 0 writes the 96-byte
`metadata.Wire` with `WireTime` at offsets 48 and 56 — seconds, then
nanoseconds — on either file channel. GOFILES's seam is the compiled
adopter ([`user/go/files/meta_guest.go:41`](../user/go/files/meta_guest.go)):
`fileMtime` roots at /host, walks the share-relative rest, and reads
`ok=false` as "the kernel could not report one" — a non-/host path, a
refused path, or the channel's honest zero — never an invented stamp;
the QuickLook card prints "—"
([`user/go/files/quick.go:144`](../user/go/files/quick.go)).

The seam is pinned by [`live-fs`](../tools/gate/specs/live-fs.spec): the
m134d leg enumerates the table (`m134d-mount host mounted share rw`,
`usb not_mounted block ro`), names the refusal
(`vf ls: disk:/: not_mounted`), and asserts a pinned mtime through both
channels (`m134d-stat rc=0 mtime_sec=1700000123`).

## 26. Split panes are seat-owned geometry (M137a, #2771)

A split is not an app feature — it is the seat's tree. GOTABWM's pane
tree ([`user/go/gotabwm/split.go`](../user/go/gotabwm/split.go)) pushes
every placed leaf's rect through the kernel's `wm_apply_rect` seam, so
each pane arrives at the app as a real WIN_RESIZE, not a paint-only
fake:

```go
func applyTreeRects() bool {
    panes := tabs.PaneRectsAll(uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
    for _, p := range panes {
        if !applyRect(p.id, p.rect) {
            return false
        }
    }
    return true
}
```

The app contract is therefore the chapter-1 one: `Dispatch` returns
`ActionResized` after re-viewing the bound surface at the new stride
([`user/go/tabapp/tabapp.go:326`](../user/go/tabapp/tabapp.go)) and the
app's draw runs at the new canvas. An unplaced tab's window is never
touched — it keeps the full-viewport stack. Bounds are the seat's: at
most `MaxPanes` = 8 leaves, nested splits at most `MaxTreeDepth` = 3
deep ([`user/go/gotabwm/tree.go:26`](../user/go/gotabwm/tree.go)), and
the tree persists through the `SESSION.PANES` sidecar.

Do not grow a second pane model inside the app to mirror the seat's,
and do not read pane geometry off the serial markers — `gotabwm: split
v`/`split h` are the gate's evidence lines, not an API. The seam is
pinned by [`go-wm-journey`](../tools/gate/specs/go-wm-journey.spec):
split v plus split h apply the pane rects (`x=0 y=0 w=640 h=360`,
`x=0 y=360 w=640 h=360`, `x=640 y=0 w=640 h=720`), `panes write n=2`
and `panes load n=2` round-trip them through a snapshot, and `panes
bad` is the named failure.

## 27. The kit's v2 controls: menu bar, tree, table (M137b, #2772)

Three controls, one discipline: a pure model plus a controller that
implements `Focusable`, so they drop into a `FocusRing` next to lists
and fields and the app keeps owning its event loop.

- `appkit.MenuBar`
  ([`user/go/appkit/menubar.go`](../user/go/appkit/menubar.go)): titled
  menus with `&` mnemonics, each dropping a popover. F10 or a bare Alt
  engages menu mode; an open menu owns the keyboard until Escape backs
  out one level. `MenuItem.Action` reports whether app state changed —
  fired inside the key/click path so the loop's dirty bit repaints.
- `appkit.TreeController`
  ([`user/go/appkit/tree.go`](../user/go/appkit/tree.go)): an outline
  over `widgets.Tree` — lazy children (`Lazy` plus a `Load` producer),
  expand/collapse, arrow and type-ahead navigation, scroll-into-view.
  `OnActivate` fires on Enter over a leaf; branches toggle.
- `appkit.TableController`
  ([`user/go/appkit/table.go`](../user/go/appkit/table.go)): keyboard
  cell focus over `widgets.Table` — `Row`/`Col` are the selection, the
  widget virtualizes rows, and the controller only moves the focus and
  two scroll offsets, so a sheet-sized model costs nothing per
  keystroke.

GODEMO ([`user/go/appkit/demo/main.go:139`](../user/go/appkit/demo/main.go))
is the smallest wired example — a `NewTableController` with an
`OnActivate` receipt, a `FocusRing` over tree and table, and a `MenuBar`
whose View menu drives `treeCtl.ExpandAll()`. GOSHEET is the forcing
consumer at real size ([`user/go/gosheet/main.go:205`](../user/go/gosheet/main.go)):
a 128×64 `widgets.Table` behind a `TableController`, plus a `MenuBar`
whose item Actions call the same paths the chords use.

The seam is pinned by [`go-wm-journey`](../tools/gate/specs/go-wm-journey.spec)
— `godemo: menu expand-all` and `godemo: table activate r=2 c=1` inside
the seat journey — and by [`go-sheet`](../tools/gate/specs/go-sheet.spec),
where the table IS the app.

## 28. Spaces: named tab groups (M137c, #2773)

A space is a whole tab strip plus its split-pane tree, named and bounded
at `MaxSpaces` = 4. One space is live — its strip IS `tabs`, so every
mutation touches only it; dormant spaces keep their windows running but
off the composite through the seat's own visibility bit, not kernel
workspaces (workspace_max is a different axis, and the word on this
surface is always "space"). The seat side is
[`user/go/gotabwm/spaces.go`](../user/go/gotabwm/spaces.go).

The app contract: there isn't one. A tab moves spaces wholesale — the
window keeps running, input follows focus, and nothing about
`Dispatch`, the surface, or save_state changes. The switch chords are
seat rows: ctrl+alt+PageDown steps forward and creates the next space at
the end (the palette's move action is the only other way a space comes
to exist); ctrl+alt+PageUp clamps at the first. Persistence rides the
record's 12-byte `group` field, so a v1 session file with no groups
lands everything on space "1".

What an app must not do: learn the word "workspace" — kernel
workspace_id is a different axis — react to `gotabwm: space` markers
(gate evidence, not an API), or assume its tab is on the visible strip
at paint time. Paint when the loop says so; visibility is the seat's
bookkeeping. The seam is pinned by
[`go-wm-journey`](../tools/gate/specs/go-wm-journey.spec): `space new
name=2`, `space move id= … to=2`, `space switch 1->2` and back, and
`session spaces n=2` surviving snapshot and restore.

## 29. Agents can drive your window: ui.input (M139b, #2780)

AGENTD's `"ui.input"` verb injects real HID events into the focused
pane — one key press or absolute pointer sample per WM_RPC kind-29
frame ([`user/go/vi/wminject.go`](../user/go/vi/wminject.go)),
dispatched through the same `consumeSeatEvent` path a physical event
takes. The app's side of the contract is zero code: an injected key
arrives as an ordinary `EvKeyDown`, a click as ordinary pointer events.
The same honesty rule as the seat's chords applies — your app's input
handling IS the agent surface.

The verb takes `{win, events}`
([`user/go/agentd/verbs.go:565`](../user/go/agentd/verbs.go)): `win` is
the strip index `"ui.windows"` reports as focused — the verb re-queries
and the seat re-checks at dispatch, so a race still lands
`agent_input_no_focus` — and `events` is a bounded batch of at most 64
flat objects, `{"type":"key","usage":N,"mods":N}` or
`{"type":"ptr","x":N,"y":N,"buttons":N}`. The whole batch validates
before the first frame goes out — a malformed event N never causes
events 1..N-1 to fire — and the first refusal stops it.

Admission is double-gated. The daemon maps `"ui.input"` to the `input`
grant — distinct from `window`, so an observer that may only read the
desktop cannot drive it (`:101`) — and the seat ties the request to the
caller's bound window and requires the bound pid's name to read
AGENTD.ELF. Refusals answer with their name — `agent_input_denied`,
`agent_input_no_focus`, `seat_absent`, `seat_unsupported`, `too_large`,
`bad_request` — because a bare applied=0 would collapse every refusal
into the same "no".

The seam is pinned by [`go-agentd`](../tools/gate/specs/go-agentd.spec)
run 15 (`verb=ui.input ok`, the named refusals, and audit receipts
including `too_large`) and by
[`live-host-ui`](../tools/gate/specs/live-host-ui.spec) run 10 (an agent
types and clicks into the focused pane over the host bus).
