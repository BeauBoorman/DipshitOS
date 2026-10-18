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

The guest has no libc or POSIX. Prefer the `virelai/vi`, `virelai/tabapp`,
`virelai/appkit`, and `virelai/widgets` packages already in this tree over
host-only standard-library assumptions.

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
  audio archive binary`) or a URL scheme (`http https`).
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
`ErrChordConflict` sentence, so a conflict fails `go test ./chords/...` and
the seat's fail-closed prologue (the deliberate fixture is seeded through
`/host/GOTABWM.CHORDCONFLICT` and refused) rather than surprising a person.
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
suffix of the raw Change log; it writes `REMOTE.json` so later rounds
are a bare `flint push`. On the host, against the served store:

```sh
flint verify --all --store <store-dir>
```

Each pushed line lands verbatim, so a byte-compare of the last line of
the guest's `FLINT/streams/<id>.jsonl` against the server's
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
store index resolves `--stream=<name>` by listing `FLINT/streams/`, and
the legacy cv channel's frozen directory rows truncate names at 31
bytes — a `<uuid>.json` record is 41, so on a cv-only share the push
refuses `stream_missing`. Mount the share with `--virtio-fs` (the paged
listing backend) for push legs. The `vf ls` monitor command shows what
the guest's readdir actually sees; a truncated tail is the tell.

Before opening a PR, run the focused host tests, the app's class-B gate,
`bash tools/status/verify-issue-coordination.sh`, and the relevant portable
checks. The canonical gate policy is in [`docs/testing.md`](testing.md); the
canonical milestone state is in [`docs/status.md`](status.md).
