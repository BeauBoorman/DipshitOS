// Command edit is the M58b (issue #1306) Go editor: open a share file, type
// into a buffer, save it back, and close - full-viewport inside Zig TABWM via
// user/go/tabapp.
//
// M66c follow-on (#1485): the three contracts the Zig NOTEPAD.BIN was the last
// live home for landed here, so the leftover binary could be deleted without
// dropping coverage. GOEDIT is the app M66c's own non-goals named as the owner
// of the editor arms race, and this file is what moved into it:
//
//   - find + goto-line (M20 U3). Ctrl-F opens the find bar, Return searches
//     from the caret and prints `goedit: find '<pat>' hit=N/M`, Ctrl-G opens
//     the goto-line bar and Return prints `goedit: goto line=N offset=O` (or
//     `miss lines=L`) as it moves the caret. The pattern buffer, the match
//     total/ordinal and the line offsets are pure functions with host tests,
//     so the live gate asserts the rules the unit tests pin.
//   - the unsaved-changes dialog client (M42 UX r2, WMS8 Gate 4). The kernel
//     posts WIN_UNSAVED (kind 17) when the user picks Save on a dirty window:
//     this app publishes the buffer and exits. The dialog's other two choices
//     never reach the owner as kind 17 - the kernel closes the window itself,
//     so they arrive as WIN_CLOSE (kind 8), which is the ActionClosed arm. An
//     editor's buffer is published by Ctrl-S or by an explicit Save, never
//     silently by a close; that is the whole point of the dialog.
//
// What did NOT land here, and why: the M14 S3 composition selfdemo (clipboard
// slots 38/39 + an app-timer blink, slot 40). It belongs to the same rehome, but
// this app's data segment is the wrong place for it. kernel/src/exec.zig packs
// argv+envp (256 + 2048 bytes) into the data segment's tail while the Go
// runtime's sbrk heap starts at `memRound(firstmoduledata.end)`, and
// `mmap_collides` extends the data aperture through `argv_end_va`: an image whose
// `mem_size mod 4096 > 1792` has that block straddling the break start, so the
// runtime's FIRST sys_mmap is refused and the app dies with `fatal error:
// runtime: cannot allocate memory` inside mallocinit. Every referenced string
// literal costs 16 bytes of that segment, and this app's budget is 240 bytes
// (hand-measured on the 2026-09-19 tree, NOT gate-pinned: memsz 0x2f610 mod
// 4096 = 1552 against the 1792 wall — treat the exact figure as illustrative
// and re-measure before betting image bytes on it).
// The selfdemo needs ~192 of them, so it lives in a purpose-built probe,
// user/go/compose, whose own budget is ~1 KB. Take this file over the wall and
// the app stops booting, silently.
//
// Find/goto parity with the Zig app it replaced is CHORD-DEEP, deliberately and
// in writing (M66c review, #1495). The four deltas, so nobody re-litigates them
// as regressions:
//
//   - there is no case-sensitivity toggle, and the search is case-SENSITIVE
//     (the shared matcher's at() is a byte compare — package virelai/find,
//     extracted M126c #2595). The Zig app was case-insensitive with a
//     compile-time constant and no live coverage for a toggle, so this is a
//     real behaviour delta, pinned by `TestCaseSensitive` in
//     find_test.go rather than left to prose.
//   - the find/goto bars are not sticky: they close on a hit or a miss instead
//     of staying open for the next search.
//   - a miss keeps the caret where it was and prints `miss`; it does not
//     re-anchor or wrap.
//   - match highlighting stays absent: the Zig side had it, the live gate
//     (`live-text-search`) never asserted it, and this card is no exception.
//
// The second pass (#2199) lands the rest of the daily-driver core, all of it
// as pure buffer-layer rules in buffer.go with the live seat proving each:
//
//   - bounded undo/redo. Ctrl-Z reverts the newest op and Ctrl-Shift-Z /
//     Ctrl-Y reapplies it; typing and delete bursts merge into one open run
//     op each (breaking at a newline), paste/cut/replace are one composite
//     op per action, and the ring caps at histCap ops — a full ring forgets
//     the oldest op rather than growing without bound.
//   - selection. Shift+arrows (or a Ctrl-Shift-M mark, the gate-drivable
//     spelling of the same anchor+caret rule) extend a selection from the
//     caret, Ctrl-A selects all, and the region paints under the text. A
//     find's match lands selected — the found region is the next edit's
//     target without a second gesture.
//   - the system clipboard. Ctrl-C copies, Ctrl-X cuts, Ctrl-V pastes
//     through sys_clipboard_set/get (slots 38/39) — the machine-global
//     buffer the monitor's `clip` command reads. M97g-F4 (#2082) gates
//     those slots on CAP_CLIPBOARD, so an unprivileged GOEDIT gets -EACCES
//     and reports it on the marker instead of keeping a shadow clipboard:
//     the policy is the boundary.
//   - replace, as the Zig app's Ctrl-R bar: `pattern`, Tab, `replacement`,
//     Return replaces the match find would land on (`hit=N/M` — same scan,
//     same ordinal), Ctrl-A replaces all matches in one op whose count
//     equals the find total (`n=N`).
//   - the status line. The chrome row right-aligns `line=L/T col=C`, adds
//     `sel=N` while a selection is live and `*` while dirty, and every
//     change republishes `goedit: status ...` on the serial console — the
//     marker the gate greps and the row the seat paints are one string.
//
// M107c (#2320) teaches the editor to speak compiler. GOBUILD.ELF runs in
// the shell (never spawned from here — the review notes' EL0-slot
// arithmetic) and writes `<dir>/.BUILD/ERRORS.TXT`, one `file:line:col:
// msg` per line. Ctrl-E reads it and opens the error panel: up/down move,
// Return jumps to the selected row, Escape closes; Ctrl-N/Ctrl-P step
// next/prev straight from the document. A jump lands the caret on the
// diagnostic's position; a row naming another file opens that file in the
// one buffer — the single-buffer answer to "the right buffer" — refused as
// `dirty` while unsaved work stands. The refusals are named: `none` (no
// diagnostics, including the empty file a clean rebuild leaves), `stale`
// (the file was saved after the list's build — mtime compared through the
// slot-79 stat op), `no-position`, `end`, `miss lines=` and `rc=`.
//
// M138b (#2776) lands the code-session surface the daily loop misses:
//
//   - bracket matching for ()[]{}. A caret on a bracket highlights its
//     match (the teal under-text cell) and Ctrl-B jumps to it; a .go
//     buffer's scan skips string, rune-literal and comment spans, so a
//     bracket inside `"{("` is not a bracket at all. `match jump off=` is
//     the landing receipt, `match none` the refusal. The chord is
//     GOEDIT's own keymap entry — the registry table keeps only the
//     documented rows, so the '?' overlay's count is unchanged.
//   - diagnostics polish. A jump lands on the row's exact column (the
//     compiler's 1-based byte column, clamped into the line), the
//     next/prev chords stay Ctrl-N/Ctrl-P from this file's keymap, and
//     the status line carries `err=I/N` while a list is loaded.
//   - format-on-save, with the card's probe verdict landed. go/format
//     links under GOOS=virelai but the image comes out over
//     exec_program_max (format.go's header has the numbers), so the
//     shipped build prints the card's named refusal on a .go save —
//     `edit: format unavailable (go/format not guest-safe)` — and
//     `-tags editfmt` is the opt-in seam for a future cap bump. The
//     contract is pinned either way: an applied format is one undoable
//     op, a parse error leaves the buffer alone, prints `format error
//     <diag>` and raises the error strip, and the publish still writes.
//
// What this is NOT: EDIT.BIN's feature list. No syntax highlighting, no
// multi-file buffers or tabs, no LSP, no auto-indent — follow-on cards own
// all of those.
//
// M149c (#2808) lands the last daily-driver surface the card list named:
//
//   - light/dark themes from the shared virelai/theme token table (NOT
//     webrender's theme — the full webrender package drags in layout + HTML
//     parsing, and the Go runtime's init then exceeds the kernel's sbrk
//     region budget). The boot palette follows /host/SETTINGS.TXT like the
//     other Go apps, and under a seat that hosts the settings bus the
//     editor subscribes to the `theme` key: a GOSET publish repaints the
//     window live (`settings repaint key=theme value=`). The caret's amber
//     and the bracket match's teal stay constant accents in both themes —
//     they are the M138b pixel-probe colours, not tokens.
//   - an optional minimap: `-minimap` reserves a miniW column at the
//     document's right edge, one pixel row per buffer line whose width
//     scales with the line's rune count (the caret's row carries the amber
//     accent). A press inside the column jumps the caret to that line
//     (`minimap line=N`), the same landing a goto bar Return produces —
//     the document body still takes no other mouse input.
//
// M153b (#2922): a picker save-as whose name ends in .pdf exports the
// buffer as a paginated fixed-pitch document through virelai/pdfwrite
// (export.go owns the wrap/page/footer rules and the named refusals). The
// export is a snapshot artifact: the session's path, the buffer and its
// dirty flag all stay with the text file, so no `saved` marker prints for
// the PDF and the lease never moves.
//
// Every marker below is printed only AFTER its syscall returned, so the
// go-edit VZ gate's asserts can only pass if the app actually ran.
package main

import (
	"strings"
	"unicode/utf8"

	"virelai/appkit"
	"virelai/draw"
	"virelai/find"
	"virelai/heap"
	"virelai/layout"
	"virelai/settings"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/vsys"
	"virelai/webrender/font"
	"virelai/widgets"
)

const (
	appName  = "GOEDIT.ELF"
	appTitle = "Edit"
	natW     = 512
	natH     = 384

	// The marker lines the class-B gate greps.
	markerOpen    = "goedit: open id="
	markerDeclare = "goedit: declare accepted"
	markerRead    = "goedit: read "
	markerPresent = "goedit: present"
	// M123b (#2576): the shared empty-state plate on an empty buffer —
	// printed once per transition into empty, from the paint that drew it.
	markerEmpty   = "goedit: empty "
	markerDirty   = "goedit: dirty"
	markerSaved   = "goedit: saved "
	markerSaveErr = "goedit: save error "
	markerClose   = "goedit: close"
	markerOK      = "goedit OK"
	markerOpenErr = "goedit: error open "

	// M20 U3 rehomed (#1485): the find and goto-line bar results, in the Zig
	// app's exact shape (`find '<pat>' hit=N/M`, `goto line=N offset=O`,
	// `goto line=N miss lines=L`) so the gate that asserted them moved by
	// binary name and marker prefix alone.
	markerFind = "goedit: find '"
	markerGoto = "goedit: goto line="

	// M83e (#1778): the dead-key stage. `layout` names the keyboard layout
	// the editor composes under, printed once after the read. `stage` prints
	// when an accent becomes pending, AFTER the frame showing it was
	// presented, so the marker means the pending mark is on the scanout. The
	// composed or literal text is the saved file's business, not a marker.
	markerLayout = "goedit: layout "
	markerStage  = "goedit: stage "

	// M42 UX r2 / WMS8 Gate 4 rehomed (#1485): the unsaved-changes dialog.
	markerUnsaved = "goedit: win_unsaved"

	// M124b (#2581): the shared file picker's receipts. `pick open <path>`
	// and `pick save <path>` name the path the picker returned; `pick
	// cancel` is the Escape receipt.
	markerPickOpen   = "goedit: pick open "
	markerPickSave   = "goedit: pick save "
	markerPickCancel = "goedit: pick cancel"

	// M153b (#2922): the .pdf save-as export's receipts — `export pdf
	// <path> pages=<n> bytes=<n>` after a published document, `export
	// refused <why>` for the named refusals (`pages=<n>` over the writer's
	// bound, the writer's own error names, `rc=` on a failed publish).
	markerExport        = "edit: export pdf "
	markerExportRefused = "edit: export refused "

	// M107c (#2320): the build-error list's receipts. One prefix carries
	// every shape: `n=` (rows loaded), `sel=` (panel selection), `jump
	// line= col=` (a landing), and the named refusals `none` / `stale` /
	// `dirty` / `no-position` / `end` / `miss lines=` / `rc=`.
	markerErrs = "goedit: errors "

	// #2199 second pass: the new features' receipts. Undo/redo report the
	// stack depth they left and the caret's landing offset; the mark and the
	// clipboard ops report their outcome (n= bytes moved, or the negative
	// kernel code the M97g-F4 policy returned — rc=-7 is the receipt, not
	// an error swallowed); the status line republishes its chrome text.
	markerStatus = "goedit: status "
	markerUndo   = "goedit: undo "
	markerRedo   = "goedit: redo "
	markerMark   = "goedit: mark "
	markerCopy   = "goedit: copy "
	markerCut    = "goedit: cut "
	markerPaste  = "goedit: paste "
	// M124a-2 (#2677): the drop target's receipt — `<mime> n=` on a
	// splice, `no-payload`/`empty`/`rc=` for the refused shapes.
	markerDrop = "goedit: drop "
	// M124e (#2584): primary-selection markers — publish on selection
	// change, paste on a seat delivery.
	markerSelPub   = "goedit: selpub "
	markerSelPaste = "goedit: sel-paste "
	markerRepl     = "goedit: replace '"
	markerReplAll  = "goedit: replace-all '"

	// M138b (#2776): bracket matching and format-on-save. `match jump
	// off=` is a landing, `match none` the caret-not-on-a-bracket (or
	// unmatched) refusal. `format n=` is the applied (or already-clean)
	// receipt carrying the formatted length; `format error <diag>` is a
	// refused parse — the buffer is left alone and the error strip shows
	// the diagnostic. The probe-failed refusal lives in format.go.
	markerMatch  = "goedit: match "
	markerFormat = "goedit: format "

	// M123d (#2578): the shared in-app error banner. `banner` is the raise
	// — the failure text the strip shows — printed only after the frame
	// that carries it is presented; `banner act` is the resolution (`copy`,
	// `copy rc=` on a refused clipboard write, or `dismiss`).
	markerBanner    = "goedit: banner "
	markerBannerAct = "goedit: banner act "
	// M121c (#2566): the '?' overlay's receipts. `hints n=` is the registry
	// row count on the painted frame; each `hints row` line after it is the
	// serial-readable copy of one row the plate shows, so the gate pins the
	// content against the shipped table; `hints close` follows the frame
	// the Esc-restore painted.
	markerHints    = "goedit: hints "
	markerHintsRow = "goedit: hints row "

	// M81d (#1764): the advisory write lease's console receipts. The open
	// marker names the holder pid the record now carries (the takeover's
	// receipt); the save-error line carries the -ErrEAGAIN refusal when
	// another writer holds it live.
	markerLeaseOK   = "goedit: lease acquired pid="
	markerLeaseHeld = "goedit: lease held rc="
	markerLeaseRel  = "goedit: lease released"
	// The gate fixture verb's receipt (see leaseFixture).
	markerLeaseFixture = "goedit: lease fixture "

	// M149c (#2808): the settings-bus theme receipts — `subscribed` at
	// declare (the GOCALC shape), `repaint key= value=` after the frame
	// carrying the new palette was presented. `minimap on` is the -minimap
	// flag's boot receipt; `minimap line=N` is a column press's landing.
	markerThemeSub     = "goedit: settings subscribed key=theme"
	markerThemeRepaint = "goedit: settings repaint "
	markerMiniOn       = "goedit: minimap on"
	markerMinimap      = "goedit: minimap line="

	// modCtrl is the ADR 0009 Ctrl modifier bit; every chord below tests it.
	modCtrl = uint16(0x0002)
	// keyS/keyF/keyG are the LOWERCASE Unicode codepoints. kernel/src/input.zig
	// puts the decoded Unicode codepoint in arg1; Ctrl chord handling retains
	// the established ASCII control-code convention ('s' & 0x1f = 0x13), so
	// both spellings are accepted for the save chord.
	keyS     = 0x73
	keyCtrlS = 0x13
	keyF     = 0x66
	keyCtrlF = 0x06
	keyG     = 0x67
	keyCtrlG = 0x07
	// #2199: the replace bar's chord and the second field's focus key. Ctrl-R
	// is unbound in both seats (checked against tabwm and gotabwm).
	keyR     = 0x72
	keyCtrlR = 0x12

	// M125b (#2587): the session-state receipt — `restored` after a blob
	// applied, `stale <why>` when it degraded to a plain open. The seat's
	// own `gotabwm: state save/restore` lines carry the transport side.
	markerState = "goedit: state "
	// M107c: the diagnostics chords. Ctrl-E opens/refreshes the error list,
	// Ctrl-N/Ctrl-P are next/prev — all unshifted letters, unbound in both
	// tab seats (checked against tabwm and gotabwm like Ctrl-R above).
	keyE     = 0x65
	keyCtrlE = 0x05
	keyN     = 0x6e
	keyCtrlN = 0x0e
	keyP     = 0x70
	keyCtrlP = 0x10
	// backspace/delete/return/escape codepoints (the kernel sends the
	// codepoint in arg1).
	codeBackspace = 0x08
	codeDelete    = 0x7f
	codeReturn    = 0x0d
	codeNewline   = 0x0a
	codeEscape    = 0x1b
	// #2199: HID usages the new input paths test on arg0 — the usage column
	// is the encoding-proof one (a ctrl chord's arg1 spelling varies, the
	// usage never does). The letter chords derive theirs from the letter
	// itself (usage = letter-'a'+0x04, see chord); the nav keys and Tab sit
	// at their documented usages.
	usageEsc    = 0x29
	usageTab    = 0x2b
	usageHome   = 0x4a
	usageFwdDel = 0x4c
	usageEnd    = 0x4d
	usageRight  = 0x4f
	usageLeft   = 0x50
	usageDown   = 0x51
	usageUp     = 0x52

	// barMax bounds the find pattern and the goto digits; gotoDigitsMax is the
	// Zig app's 5-digit bound on a goto line number.
	barMax        = 32
	gotoDigitsMax = 5
	// diagRowsMax bounds the error panel's visible rows (M107c).
	diagRowsMax = 8

	// defaultPath is the share fixture the gate seeds.
	defaultPath = "/host/EDIT/SEED.TXT"
	// maxBuffer bounds the buffer to the SDK's file bound.
	maxBuffer = vi.MaxFileBytes
)

// Event kinds the SDK does not name. WIN_UNSAVED (kernel/src/events.zig kind
// 17) carries the unsaved-changes dialog's choice in arg0: 0 save, 1 don't
// save, 2 cancel. vi.EvTimer (9), vi.EvWinClose (8) and vi.EvWinResize (10)
// come from the SDK.
const evWinUnsaved uint16 = 17

// M149c: the frame's palette is the shared token table (theme.Current —
// ChromeBg/Bg/Ink/InkMuted/Selection/Gutter/Muted). What stays local are the
// two constant accents the M138b pixel probe pins: colCaret, the caret
// block's amber, and colMatch, the matching bracket's teal under-text tint —
// accents, not theme tokens, identical under light and dark.
const (
	colCaret = uint32(0xffd75f)
	colMatch = uint32(0x3fbf9f)
)

// inputMode is which surface owns the keyboard: the document, the find bar,
// the goto-line bar (M20 U3), the replace bar (#2199), the diagnostics
// panel (M107c), or — M124b (#2581) — the shared file picker and the
// discard-confirm dialog that can precede an open on a dirty buffer.
type inputMode uint8

const (
	modeEdit inputMode = iota
	modeFind
	modeGoto
	modeReplace
	modeDiags
	modePicker
	modeDialog
	modeHints // M121c (#2566): the '?' chord-hint overlay owns the keyboard
)

// clipWrite/clipRead are the machine-global clipboard (sys_clipboard_set/get,
// slots 38/39 — the same buffer the monitor's `clip` command and the
// terminal chrome chords use). M97g-F4 (#2082) gates the slots on
// CAP_CLIPBOARD: an unprivileged GOEDIT gets -EACCES, which lands on the op's
// marker as rc= — the policy is the boundary, so there is no app-local shadow
// clipboard. The indirection is the host-test seam: vsys's syscallFn is
// package-internal, so tests swap these two instead.
var (
	clipWrite = func(p []byte) (int, int64) { return vsys.ClipboardSet(p) }
	// M107e (#2322): ClipboardGetInto reads into a 512 B caller buffer, not
	// the 256 B vsys staging pool — the kernel clipboard holds 512 and the
	// M108b host lane fills all of it, so a 257..512 B host paste used to
	// splice into the buffer silently truncated.
	clipRead = func() ([]byte, int64) {
		var buf [512]byte
		n, r := vsys.ClipboardGetInto(buf[:])
		return buf[:n], r
	}
	// M149c: the settings-bus poll is a package seam too — a host test
	// substitutes the delivered notice without a seat on the other end.
	pollChange = func(winID uint32) (string, string, bool) {
		return settings.PollChange(winID)
	}
)

// fill is one clamped background rectangle through the bound window canvas
// (or the FillerCanvas degradation path — tabapp.Canvas() picks). Opaque
// mirrors the kernel fill's byte contract on the raster path.
func (e *editor) fill(x, y, w, h int, rgb uint32) {
	if w <= 0 || h <= 0 || x < 0 || y < 0 {
		return
	}
	if e.rec != nil {
		e.rec(x, y, w, h, rgb)
		return
	}
	e.ta.Canvas().FillRect(widgets.Rect{X: x, Y: y, W: w, H: h}, draw.Opaque(rgb))
}

// drawText paints text with the VirelaiOS 8x8 face (virelai/webrender/font),
// coalescing each row's lit run into ONE fill. It is deliberately local: the
// full webrender package drags in layout + HTML parsing, and the Go runtime's
// init then exceeds the kernel's 16-region sbrk budget (observed live as
// "runtime: cannot allocate memory" in mallocinit).
func (e *editor) drawText(x, y int, text string, rgb uint32) {
	cx := x
	for _, ch := range text {
		g := font.Glyph8(ch)
		for row := 0; row < 8; row++ {
			bits := g[row]
			col := 0
			for col < 8 {
				if bits&(1<<uint(col)) == 0 {
					col++
					continue
				}
				run := 1
				for col+run < 8 && bits&(1<<uint(col+run)) != 0 {
					run++
				}
				e.fill(cx+col, y+row, run, 1, rgb)
				col += run
			}
		}
		cx += font.Advance(1)
	}
}

// editor is the whole app state: the path, the byte buffer, the caret, and the
// dirty flag.
type editor struct {
	ta    *tabapp.TabApp
	path  string
	buf   []byte
	dirty bool
	// rec, when set, receives every fill instead of the window canvas. It is
	// nil in the guest; host tests set it to observe the frame geometry.
	rec func(x, y, w, h int, rgb uint32)
	// emptyShown is the M123b marker latch: `goedit: empty` prints once per
	// transition into an empty buffer, from the paint that drew the plate.
	emptyShown bool

	// M20 U3: cur is the caret as a byte offset into buf, clamped on every use
	// so a buffer that shrank under it cannot index out of range; mode says
	// which bar owns the keyboard; bar holds that bar's typed text; bar2 is
	// the replace bar's second field (the replacement) with bar2At its focus.
	cur    int
	mode   inputMode
	bar    []byte
	bar2   []byte
	bar2At bool

	// #2199: the selection and the bounded history. sel is the selection's
	// anchor byte offset, live only while selSet; markOn is the ctrl-shift-m
	// mark — plain nav extends while it is set, which is how the gate drives
	// a selection the runner's chord table cannot spell (shift+arrow is not
	// a token). hist is the bounded op ring; status dedupes emitStatus.
	sel    int
	selSet bool
	markOn bool
	hist   history
	status string

	// M83e (#1778): the dead-key stage. It sits in front of whichever surface
	// owns the keyboard (the document or a bar) and hands it the text a
	// sequence resolves to. marked is the accent whose `stage` marker was last
	// printed, so the marker is an edge like markDirty.
	stage  layout.Stage
	marked layout.Accent

	// M81d (#1764): the advisory write lease taken at open and held for the
	// session, so a file manager cannot delete or overwrite the file out
	// from under the editing session. nil when the open-time acquire was
	// refused (another writer holds it live) — every save then retries.
	lease *vi.FileLease

	// M107c (#2320): the loaded build-error list. diagsPath is the
	// ERRORS.TXT it came from and diagsMtime that file's stamp at load —
	// the baseline the jump-time staleness check compares file mtimes
	// against. diagsSel is the panel selection AND the last-jumped row (-1
	// before any landing). diagsArg is the --diags= override.
	diags      []diagRow
	diagsPath  string
	diagsMtime int64
	diagsSel   int
	diagsArg   string

	// M125b (#2587): the session-state fields. base is the file content the
	// session opened on — the undo ring's anchor: replaying the ring onto
	// base rebuilds an unsaved buffer at restore (it aliases the load-time
	// slice and is never mutated, so it costs nothing to keep). diskLen/
	// diskHash fingerprint the file as last seen on the share (load or
	// save) — the stale-blob check. findHist/gotoHist are the bounded
	// find/goto history, newest last. pend is the decoded blob waiting for
	// load() to produce the buffer it applies against; pendBad marks a
	// blob that failed to decode.
	base     []byte
	diskLen  int
	diskHash uint64
	findHist [][]byte
	gotoHist []int
	pend     *editState
	pendBad  bool

	// M124b (#2581): the shared picker and the discard-confirm dialog.
	// pickOpenAsk marks that the open dialog's Yes answer means "now open
	// the picker" — the only flow that can destroy unsaved bytes.
	pick        appkit.FilePicker
	dlg         appkit.Dialog
	pickOpenAsk bool

	// M123d (#2578): the shared error banner — the inline strip across the
	// top of the document band for open/save failures (banner.go owns the
	// raise/route/resolve half). bannerFresh latches a raise so the marker
	// prints only after the strip's own frame is on scanout.
	banner      appkit.ErrorBanner
	bannerFresh bool

	// M121c (#2566): the shared '?' chord-hint overlay — the registry rows
	// for this app's scope plus the seat's globals. hintsEmit latches the
	// open/close edge so the marker prints only after its frame is on the
	// scanout (the bannerFresh discipline).
	hints     appkit.ChordHints
	hintsEmit int // 1 = open receipt pending, 2 = close receipt pending

	// M149c (#2808): the -minimap flag — the document's right-edge column
	// of one pixel row per buffer line, and the press-to-jump arm.
	minimap bool
}

// leaseFixture stamps a FOREIGN lease record on the edited path before the
// editor's own acquire — the second writer's side of the M81d drill without
// needing a second process (the GOSELF --panic-receipt-fixture precedent:
// a named fixture verb, not a hidden side door). `live` carries a stamp no
// run outlives (the year 2286), `stale` one every rule reads as expired
// (ts=1); pid=0 keeps the record's liveness purely on the stamp, so the
// fixture is timing-proof either way. The record text is the on-share
// VLEASE1 convention, hand-rendered the way a foreign writer would.
func leaseFixture(path, mode string) bool {
	ts := "1"
	if mode == "live" {
		ts = "9999999999"
	} else if mode != "stale" {
		return false
	}
	lp := vi.LeasePathFor(path)
	if lp == "" {
		return false
	}
	// The record's directory may not exist yet (the fixture can run before
	// any acquire); the MODE_DIR create triple's EEXIST is fine.
	h, rc := vi.FileOpen(vi.LeaseDir, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if rc < 0 && rc != -9 {
		vi.ConsoleLine(markerLeaseFixture + mode + " rc=" + vi.Itoa64(rc))
		return false
	}
	if rc >= 0 {
		vi.FileClose(uint32(h))
	}
	rec := "VLEASE1\npid=0\nts=" + ts + "\ntoken=fedcba9876543210\npath=" + path + "\n"
	if rc := vi.WriteFileSafe(lp, []byte(rec)); rc < 0 {
		vi.ConsoleLine(markerLeaseFixture + mode + " rc=" + vi.Itoa64(rc))
		return false
	}
	vi.ConsoleLine(markerLeaseFixture + mode)
	return true
}

// loadGuestTheme applies the persisted theme at boot — the same
// /host/SETTINGS.TXT read every themed Go app does (GOCALC's shape). A
// missing or unreadable file leaves the Dark default standing.
func loadGuestTheme() {
	b, r := vi.ReadFileAll("/host/SETTINGS.TXT", 2048)
	if r < 0 || b == nil {
		return
	}
	_ = theme.ApplySettings(b)
}

func main() {
	loadGuestTheme()
	args := vi.Args()
	path := defaultPath
	diagPath := ""
	minimap := false
	if len(args) > 1 && len(args[1]) > 0 {
		path = args[1]
	}
	if len(args) > 2 {
		for _, a := range args[2:] {
			if a == "-heap" {
				heap.Publish(appName, 1)
			}
			if a == "-minimap" {
				minimap = true
			}
			if strings.HasPrefix(a, "--lease-fixture=") {
				leaseFixture(path, strings.TrimPrefix(a, "--lease-fixture="))
			}
			if strings.HasPrefix(a, "--diags=") {
				diagPath = strings.TrimPrefix(a, "--diags=")
			}
		}
	}

	// M125b (#2587): the editor must exist before Init — the seat's
	// restore_answer fires the RestoreState hook INSIDE it, so the blob
	// decodes into the app's own state before the buffer even loads. The
	// decoded path wins over argv: a session re-exec runs the bare bin.
	e := &editor{path: path, diagsArg: diagPath, minimap: minimap}
	ta := tabapp.Init(tabapp.Config{
		Name:  appName,
		Title: appTitle,
		X:     32,
		Y:     32,
		W:     natW,
		H:     natH,

		StateVersion: stateAppVer,
		SaveState:    e.saveState,
		RestoreState: e.noteState,
		// M124a-2 (#2677): the drop target. The seat's opens=text,binary
		// admission already filtered the mime; a delivered payload splices
		// at the caret through the same op path as paste, then repaints —
		// the callback runs inside PollDrag, where no frame is pending.
		DropTarget: func(offer tabapp.DragOffer) {
			e.drop(offer)
			e.draw()
			e.ta.Present()
			e.markStage()
			e.emitStatus()
		},
		// M124e (#2584): the primary-selection paste sink — a seat
		// delivery (middle-click into this pane, shift+insert focused)
		// splices the bytes at the caret through the same op path.
		SelPaste: func(text []byte) {
			e.selPaste(text)
			e.draw()
			e.ta.Present()
			e.markStage()
			e.emitStatus()
		},
		// M121e (#2568): the undo hook — the seat's ctrl+z routes to this
		// tab, Dispatch classifies it ActionUndo, and the buffer's own op
		// ring answers (the same revert the old in-app binding ran).
		HandleUndo: func() bool {
			e.undo()
			return true
		},
	})
	if ta == nil {
		vi.ConsoleLine(markerOpenErr + "-1")
		vi.Exit(1)
	}
	e.ta = ta
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine("goedit: declare refused")
	}
	// M149c: subscribe to the settings bus's theme key. Under a seat that
	// hosts the bus (gotabwm) a GOSET publish reaches pollThemeChange as a
	// kind-15 notice; under the shim or the Zig seat the request fails or
	// is ignored and the boot palette simply stands.
	if settings.Subscribe("theme", uint32(ta.Win), ta.Name) {
		vi.ConsoleLine(markerThemeSub)
	}

	e.load()
	// The blob applies to the loaded buffer — staleness, ring replay and
	// caret/selection all land here, before the layout/lease/draw pass.
	e.applyRestored()
	// The layout is read once, at open: it decides which physical keys are
	// dead. A change made in GOSET while this editor is open applies to the
	// next one; until then an unmapped dead key is ignored, as it always was.
	e.stage.SetLayout(layoutFor(settings.Load()))
	vi.ConsoleLine(markerLayout + string(e.stage.Layout()))
	// M81d: the session's advisory write lease. A refusal is reported and
	// the editor stays usable — every save retries the acquire, so a
	// writer that lets go while we edit is honored on the next Ctrl-S.
	if rc := e.ensureLease(); rc < 0 {
		vi.ConsoleLine(markerLeaseHeld + vi.Itoa64(rc))
	}
	e.draw()
	ta.Present()
	// The first frame is on the scanout: the gate releases the injected
	// keystrokes on this marker, so the editor is already in its event loop.
	vi.ConsoleLine(markerPresent)
	if e.minimap {
		vi.ConsoleLine(markerMiniOn)
	}
	e.bannerFlush()
	e.emitStatus()

	for {
		// M125b (#2587): the seat's save notice is a mailbox message, not
		// an input event — answer it each pass so a snapshot/close ask is
		// serviced before the window dies (the GOTABAPP discipline).
		ta.PollStateAsk()
		// M124a-2: seat drag frames for this window — a delivered drop runs
		// DropTarget (which repaints itself) here, one poll per loop turn.
		ta.PollDrag()
		// M124e (#2584): seat primary-selection deliveries land the same
		// way; and a selection the user just changed publishes itself the
		// same pass (publishSel diffs, so a quiet pass costs a compare).
		ta.PollSelPaste()
		e.publishSel()
		// M149c: a published theme change repaints the frame it applies
		// to, and its receipt prints after that frame is on the scanout —
		// the bannerFresh discipline.
		if key, value, applied := e.pollThemeChange(); applied {
			e.draw()
			ta.Present()
			e.bannerFlush()
			e.emitStatus()
			vi.ConsoleLine(markerThemeRepaint + "key=" + key + " value=" + value)
		}
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				break
			}
			vi.Sleep(1)
			continue
		}
		// M42 UX r2: the dialog's Save choice is a request to publish the
		// buffer, not a close — handled before the tabapp dispatch, which has
		// no opinion about it.
		if ev.Kind == evWinUnsaved {
			e.unsavedExit(ev)
		}
		switch ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			e.releaseLease()
			vi.ConsoleLine(markerClose)
			vi.ConsoleLine(markerOK)
			ta.CloseAndExit(0)
		case tabapp.ActionResized:
			e.draw()
			ta.Present()
			e.bannerFlush()
			e.emitStatus()
		case tabapp.ActionUndo:
			// M121e: the seat's ctrl+z routed here — the same repaint
			// discipline as a handled key.
			if ta.Undo() {
				e.draw()
				ta.Present()
				e.bannerFlush()
				e.markStage()
				e.emitStatus()
				e.hintsFlush()
			}
		case tabapp.ActionNone:
			if e.handle(ev) {
				e.draw()
				ta.Present()
				e.bannerFlush()
				e.markStage()
				e.emitStatus()
				e.hintsFlush()
			}
		}
	}
	// The event loop broke on a poll error — the same exit discipline as the
	// clean paths, so a lease is not left standing on a dead session.
	e.releaseLease()
}

// load reads the fixture into the buffer. A missing file is not fatal: the
// editor starts on an empty buffer (the create path), which is what a real
// editor does, and the read marker reports the byte count it actually got.
// The caret starts at the END of the buffer, which is what keeps the go-edit
// gate's typed characters appending to the seed exactly as they did before the
// caret existed.
// bufRead is the buffer-read seam: vi.ReadFileAll in the guest, substituted
// in host tests (the same shape errRead in diags.go takes for the
// diagnostics file).
var bufRead = func(p string, max int) ([]byte, int64) {
	return vi.ReadFileAll(p, max)
}

// M153b (#2922): the export publish seam — vi.WriteFileSafe in the guest,
// substituted in host tests so the written PDF is inspectable (the same
// shape bufRead takes for the read).
var bufWrite = func(p string, b []byte) int64 {
	return vi.WriteFileSafe(p, b)
}

func (e *editor) load() {
	b, rc := bufRead(e.path, maxBuffer)
	if rc < 0 {
		e.buf = nil
		e.cur = 0
		e.base = nil
		e.diskLen = 0
		e.diskHash = fnv1a64(nil)
		vi.ConsoleLine(markerRead + e.path + " n=0 rc=" + vi.Itoa64(rc))
		// M123d (#2578): a missing file is the create path — the empty
		// buffer is the documented answer, not a failure. Every other
		// open refusal raises the shared error banner.
		if rc != -vi.ErrENOENT {
			e.raiseBanner("open " + e.path + " failed rc=" + vi.Itoa64(rc))
		}
		return
	}
	e.buf = b
	e.cur = len(b)
	e.base = b
	e.diskLen = len(b)
	e.diskHash = fnv1a64(b)
	vi.ConsoleLine(markerRead + e.path + " n=" + vi.Itoa64(int64(len(b))))
}

// layoutFor is the keyboard layout the kernel is translating under: the
// settings file's keyboard_layout, else the compiled default. A value the
// layout package does not know (the kernel refuses it too) is US.
func layoutFor(f settings.File) layout.ID {
	v, _ := f.Effective("keyboard_layout")
	if id, ok := layout.Parse(v); ok {
		return id
	}
	return layout.US
}

// handle is the loop's entry for events that are not window lifecycle. Losing
// focus types a staged accent as its literal, so a sequence abandoned by
// switching tabs is never swallowed.
func (e *editor) handle(ev vi.Event) bool {
	if ev.Kind == vi.EvWinBlur {
		return e.commitAll(e.stage.Flush())
	}
	// M123d: a press inside the open banner's strip is the banner's; a
	// press anywhere else is not — the document takes no mouse input, so
	// an outside click falls through untouched.
	if e.banner.Open && ev.Kind == vi.EvMouseDown {
		return e.bannerPress(int(ev.Arg0), int(ev.Arg1))
	}
	// M149c: a press inside the minimap column jumps the caret to that
	// line; the rest of the document still takes no mouse input.
	if e.minimap && ev.Kind == vi.EvMouseDown {
		if line, ok := e.minimapHit(int(ev.Arg0), int(ev.Arg1)); ok {
			e.minimapJump(line)
			return true
		}
	}
	return e.key(ev)
}

// key runs one key-down through the dead-key stage and then, unless the stage
// consumed it, through handleKey. Whatever the stage resolved to is inserted
// first, so a key that ends a sequence without being text (Ctrl-S, Return)
// still finds the accent already in the buffer. It reports whether the frame
// needs a redraw, which a changed pending state also requires.
func (e *editor) key(ev vi.Event) bool {
	if ev.Kind != vi.EvKeyDown {
		return false
	}
	// M123d: the open banner owns the keyboard ahead of even the dead-key
	// stage — a pending accent stays pending and no key reaches the
	// document or a bar while the strip stands.
	if e.banner.Open {
		return e.bannerKey(ev)
	}
	before, _ := e.stage.Pending()
	step := e.stage.Feed(layout.Input{
		Usage: ev.Arg0,
		Shift: ev.Flags&vi.ModShift != 0,
		Chord: ev.Flags&(vi.ModCtrl|vi.ModAlt) != 0,
		Sym:   rune(ev.Arg1),
	})
	changed := e.commitAll(step.Commit)
	if after, _ := e.stage.Pending(); after != before {
		changed = true
	}
	if !step.Pass {
		return changed
	}
	return e.handleKey(ev) || changed
}

// commitAll inserts resolved text into the surface that owns the keyboard.
func (e *editor) commitAll(rs []rune) bool {
	changed := false
	for _, r := range rs {
		if e.mode == modeEdit {
			changed = e.insert(r) || changed
		} else if e.mode != modeDiags && e.mode != modePicker && e.mode != modeDialog && e.mode != modeHints {
			changed = e.barAppend(r) || changed
		}
	}
	return changed
}

// markStage prints the `stage` marker when an accent becomes pending. Call it
// after the frame that shows the mark was presented.
func (e *editor) markStage() {
	if m := e.stageMarker(); m != "" {
		vi.ConsoleLine(m)
	}
}

// stageMarker is the line markStage prints now, or "" when the pending state
// has not changed since the last one. It is separate so a host test can pin
// the edge without a console (vi.ConsoleLine does not go through the
// syscall-hook seam).
func (e *editor) stageMarker() string {
	a, ok := e.stage.Pending()
	if !ok {
		e.marked = 0
		return ""
	}
	if a == e.marked {
		return ""
	}
	e.marked = a
	return markerStage + a.Name()
}

// handleKey feeds one event to the buffer or to the focused bar, and reports
// whether the frame needs a redraw. The bar chords own the keyboard from ANY
// mode, so a Ctrl-G straight after a find's Return opens the goto bar instead
// of being swallowed as text.
func (e *editor) handleKey(ev vi.Event) bool {
	if ev.Kind != vi.EvKeyDown {
		return false
	}
	// M124b: a modal surface owns the whole keyboard while it is up — the
	// bar chords below must not fire under the picker or its guard dialog.
	switch e.mode {
	case modePicker:
		return e.pickerKey(ev)
	case modeDialog:
		return e.dialogKey(ev)
	case modeHints:
		return e.hintsKey(ev)
	}
	// M121c (#2566): '?' opens the chord-hint overlay from the document or
	// the diagnostics panel — the registry's app + seat rows painted over
	// the buffer. A bar keeps '?' as text (a find pattern may literally be
	// '?'); the modals above own the keyboard while they stand.
	if (e.mode == modeEdit || e.mode == modeDiags) && ev.Arg1 == '?' &&
		ev.Flags&(modCtrl|vi.ModAlt) == 0 {
		e.hints = appkit.NewChordHints(appName)
		e.mode = modeHints
		e.hintsEmit = 1
		return true
	}
	if isChord(ev, keyF, keyCtrlF) {
		return e.openBar(modeFind)
	}
	if isChord(ev, keyG, keyCtrlG) {
		return e.openBar(modeGoto)
	}
	if isChord(ev, keyR, keyCtrlR) {
		return e.openBar(modeReplace)
	}
	// M107c: Ctrl-E loads the build diagnostics and opens the list panel —
	// a bar-style chord, so it answers from any mode like the bars do.
	if isChord(ev, keyE, keyCtrlE) {
		return e.openErrors()
	}
	switch e.mode {
	case modeFind:
		return e.barKey(ev, e.runFind)
	case modeGoto:
		return e.barKey(ev, e.runGoto)
	case modeReplace:
		return e.replaceBarKey(ev)
	case modeDiags:
		return e.diagsKey(ev)
	}
	// #2199 chords, all on the usage column via chord() so the shifted
	// spellings stay distinct: ctrl-shift-z and ctrl-y redo, ctrl-x/c/v
	// are the clipboard, ctrl-a selects all, and ctrl-shift-m is the mark —
	// the gate-drivable selection gesture. M121e moved ctrl-z out of this
	// list: tabapp.Dispatch classifies it ActionUndo ahead of handle() and
	// the HandleUndo hook runs e.undo() — one seat-owned chord, no second
	// app binding to double-fire.
	if chord(ev, 'z', true) || chord(ev, 'y', false) {
		e.redo()
		return true
	}
	if chord(ev, 'm', true) {
		return e.toggleMark()
	}
	if chord(ev, 'a', false) {
		e.selectAll()
		return true
	}
	// M107c: next/prev diagnostic. Each step jumps straight to the row
	// after/before the last landing; the list loads on first use.
	if chord(ev, 'n', false) {
		return e.stepDiag(1)
	}
	if chord(ev, 'p', false) {
		return e.stepDiag(-1)
	}
	if chord(ev, 'x', false) {
		e.cut()
		return true
	}
	if chord(ev, 'c', false) {
		e.copy()
		return true
	}
	if chord(ev, 'v', false) {
		e.paste()
		return true
	}
	// M138b (#2776): Ctrl-B jumps to the match of the bracket under the
	// caret — unshifted, free in both tab seats (checked against tabwm and
	// gotabwm like Ctrl-R above).
	if chord(ev, 'b', false) {
		return e.jumpMatch()
	}
	// M124b: Ctrl-O opens through the shared picker; Ctrl-Shift-S is the
	// save-as. The save-as check must precede isSave, whose isChord does
	// not read the Shift flag.
	if chord(ev, 'o', false) {
		return e.startPick(false)
	}
	if chord(ev, 's', true) {
		return e.startPick(true)
	}
	if isSave(ev) {
		// A failed Ctrl-S leaves the app alive and the buffer dirty: the
		// error marker is the receipt, and the next Ctrl-S tries again.
		// (Only the dialog's Save choice treats failure as terminal --
		// there the user asked to publish and close.)
		if !e.save() {
			return true
		}
		return true
	}
	if ev.Flags&modCtrl != 0 {
		return false
	}
	// Nav keys move the caret; Shift extends the selection from it, as does
	// a set mark. Alt-nav belongs to the seat, not the document.
	if ev.Flags&vi.ModAlt == 0 {
		extend := ev.Flags&vi.ModShift != 0 || e.markOn
		switch ev.Arg0 {
		case usageLeft:
			e.moveCaret(moveLeft(e.buf, e.cur), extend)
			return true
		case usageRight:
			e.moveCaret(moveRight(e.buf, e.cur), extend)
			return true
		case usageUp:
			e.moveCaret(moveLine(e.buf, e.cur, -1), extend)
			return true
		case usageDown:
			e.moveCaret(moveLine(e.buf, e.cur, 1), extend)
			return true
		case usageHome:
			e.moveCaret(moveHome(e.buf, e.cur), extend)
			return true
		case usageEnd:
			e.moveCaret(moveEnd(e.buf, e.cur), extend)
			return true
		case usageFwdDel:
			return e.deleteForward()
		}
	}
	if ev.Arg1 == codeBackspace || ev.Arg1 == codeDelete {
		return e.backspace()
	}
	if ch, ok := insertionFor(ev); ok {
		return e.insert(ch)
	}
	return false
}

// chord reports a ctrl+<letter> chord on the letter's HID usage, with the
// arg1 spellings as fallbacks (the letter — either case, since a shifted
// chord capitalizes it — and the ASCII control code). shift pins the Shift
// flag: false refuses the shifted spelling so ctrl-shift-z never re-fires
// undo, true requires it.
func chord(ev vi.Event, letter uint32, shift bool) bool {
	if ev.Kind != vi.EvKeyDown || ev.Flags&modCtrl == 0 {
		return false
	}
	if (ev.Flags&vi.ModShift != 0) != shift {
		return false
	}
	if letter >= 'a' && letter <= 'z' {
		if ev.Arg0 == letter-'a'+0x04 {
			return true
		}
		return ev.Arg1 == letter || ev.Arg1 == letter-'a'+'A' ||
			ev.Arg1 == letter-'a'+1
	}
	return false
}

// isChord reports whether ev is the Ctrl chord for a key, accepting either the
// bare codepoint or its derived control code (the duality isSave has always
// handled).
func isChord(ev vi.Event, key, ctrlCode uint32) bool {
	if ev.Kind != vi.EvKeyDown || ev.Flags&modCtrl == 0 {
		return false
	}
	if ev.Arg1 == key || ev.Arg1 == ctrlCode {
		return true
	}
	// The arg0 usage is the spelling that survives every arg1 encoding.
	return key >= 'a' && key <= 'z' && ev.Arg0 == key-'a'+0x04
}

// isSave reports whether the event is the Ctrl-S save chord.
func isSave(ev vi.Event) bool { return isChord(ev, keyS, keyCtrlS) }

// openBar focuses a bar with an empty entry — and, for replace, an empty
// second field with the focus back on the pattern. Opening a bar is a mode
// change, so it also closes an open typing run.
func (e *editor) openBar(m inputMode) bool {
	e.mode = m
	e.bar = e.bar[:0]
	e.bar2 = e.bar2[:0]
	e.bar2At = false
	e.hist.breakRun()
	return true
}

// closeBar hands the keyboard back to the document.
func (e *editor) closeBar() {
	e.mode = modeEdit
	e.bar = e.bar[:0]
	e.bar2 = e.bar2[:0]
	e.bar2At = false
}

// startPick begins the M124b open/save flow. An open on a dirty buffer goes
// through the discard-confirm first — the picker is the only flow that can
// destroy unsaved bytes, so it gets a guard the bars never need. Save-as is
// harmless (the buffer just publishes elsewhere) and opens the picker
// straight away.
func (e *editor) startPick(save bool) bool {
	if !save && e.dirty {
		e.dlg = appkit.NewConfirm("Unsaved buffer", "Open a file and discard the unsaved changes?")
		e.pickOpenAsk = true
		e.mode = modeDialog
		return true
	}
	e.openPick(save)
	return true
}

// openPick raises the shared picker over the editor's own window. The start
// directory is the buffer's parent; save-as also pretypes the current name.
func (e *editor) openPick(save bool) {
	kind := appkit.PickOpen
	if save {
		kind = appkit.PickSave
	}
	dir := dirOf(e.path)
	if dir == "" {
		dir = "/host"
	}
	e.pick = appkit.NewFilePicker(kind, dir)
	if save {
		e.pick.Input = baseOf(e.path)
	}
	e.mode = modePicker
}

// pickerKey routes one key to the open picker and lands its Result: an open
// re-loads the buffer at the picked path (the session's lease moves with the
// path), a save-as republishes under the picked name, and cancel just hands
// the keyboard back.
func (e *editor) pickerKey(ev vi.Event) bool {
	_, done := e.pick.HandleKey(ev)
	if !done {
		return true
	}
	save := e.pick.Kind == appkit.PickSave
	res := e.pick.Result
	e.mode = modeEdit
	if res == "cancel" {
		vi.ConsoleLine(markerPickCancel)
		return true
	}
	if save {
		vi.ConsoleLine(markerPickSave + res)
		// M153b: a .pdf name is an export, not a save-as — the session's
		// path and the buffer's dirty state stay with the text file.
		if exportPath(res) {
			e.exportPDF(res)
			return true
		}
		e.path = res
		e.save()
		return true
	}
	// Open: the lease belongs to the OLD path — release it first so the new
	// file's session starts with the same acquire the boot path does.
	e.releaseLease()
	e.path = res
	vi.ConsoleLine(markerPickOpen + res)
	e.load()
	e.dirty = false
	e.selSet, e.markOn = false, false
	e.hist = history{}
	e.ensureLease()
	return true
}

// hintsKey routes one key to the open '?' overlay: Esc (or a second '?')
// closes it back to the document, the nav keys scroll a list longer than
// the plate — every other key is consumed, the modal contract.
func (e *editor) hintsKey(ev vi.Event) bool {
	if _, done := e.hints.HandleKey(ev); done {
		e.mode = modeEdit
		e.hintsEmit = 2
	}
	return true
}

// hintsFlush prints the latched hints receipt after the frame it describes
// is on the scanout — the same post-present discipline bannerFlush keeps.
// The row dump is the serial-readable copy of the plate's content: it is
// built from the registry's own rows, so a hard-coded cheat sheet could
// never produce it.
func (e *editor) hintsFlush() {
	switch e.hintsEmit {
	case 1:
		vi.ConsoleLine(markerHints + "n=" + vi.Itoa64(int64(e.hints.ChordRows())))
		for _, l := range e.hints.RowLines() {
			vi.ConsoleLine(markerHintsRow + l)
		}
	case 2:
		vi.ConsoleLine(markerHints + "close")
	}
	e.hintsEmit = 0
}

// dialogKey routes the discard-confirm: Yes continues into the picker the
// guard was raised for; anything else (No, Escape) returns to the buffer.
func (e *editor) dialogKey(ev vi.Event) bool {
	_, done := e.dlg.HandleKey(ev)
	if !done {
		return true
	}
	yes := e.dlg.Result == "Yes"
	openAsk := e.pickOpenAsk
	e.pickOpenAsk = false
	e.mode = modeEdit
	if yes && openAsk {
		e.openPick(false)
	}
	return true
}

// baseOf is a path's last segment (dirOf's counterpart, already package-local
// for the diagnostics jump).
func baseOf(p string) string {
	if i := strings.LastIndexByte(p, '/'); i >= 0 {
		return p[i+1:]
	}
	return p
}

// barKey handles one key while a find/goto bar owns the keyboard: Return runs
// the bar's action and closes it, Escape closes it without one, backspace
// trims it, and printable codepoints append (bounded by barMax).
func (e *editor) barKey(ev vi.Event, run func()) bool {
	if ev.Flags&modCtrl != 0 {
		return false
	}
	if ev.Arg1 == codeEscape || ev.Arg0 == usageEsc {
		e.closeBar()
		return true
	}
	if ev.Arg1 == codeReturn || ev.Arg1 == codeNewline {
		run()
		return true
	}
	if ev.Arg1 == codeBackspace || ev.Arg1 == codeDelete {
		if len(e.bar) == 0 {
			return false
		}
		_, size := utf8.DecodeLastRune(e.bar)
		e.bar = e.bar[:len(e.bar)-size]
		return true
	}
	if ch, ok := insertionFor(ev); ok {
		return e.barAppend(ch)
	}
	return false
}

// replaceBarKey is the replace bar's two-field variant (#2199): Tab moves the
// focus between pattern and replacement, Return replaces the current match,
// Ctrl-A replaces all, and the rest follows barKey's rules.
func (e *editor) replaceBarKey(ev vi.Event) bool {
	if ev.Arg1 == codeEscape || ev.Arg0 == usageEsc {
		e.closeBar()
		return true
	}
	if ev.Arg0 == usageTab && ev.Flags&modCtrl == 0 {
		e.bar2At = !e.bar2At
		return true
	}
	if chord(ev, 'a', false) {
		e.runReplaceAll()
		return true
	}
	if ev.Flags&modCtrl != 0 {
		return false
	}
	if ev.Arg1 == codeReturn || ev.Arg1 == codeNewline {
		e.runReplace()
		return true
	}
	if ev.Arg1 == codeBackspace || ev.Arg1 == codeDelete {
		dst := &e.bar
		if e.bar2At {
			dst = &e.bar2
		}
		if len(*dst) == 0 {
			return false
		}
		_, size := utf8.DecodeLastRune(*dst)
		*dst = (*dst)[:len(*dst)-size]
		return true
	}
	if ch, ok := insertionFor(ev); ok {
		return e.barAppend(ch)
	}
	return false
}

// barAppend adds one scalar to the focused bar field — replace's Tab picks
// between them — bounded by barMax.
func (e *editor) barAppend(ch rune) bool {
	dst := &e.bar
	if e.mode == modeReplace && e.bar2At {
		dst = &e.bar2
	}
	if len(*dst)+utf8.RuneLen(ch) > barMax {
		return false
	}
	*dst = append(*dst, []byte(string(ch))...)
	return true
}

// runFind runs the find bar's Return: search from the caret, move it to the
// match — landed SELECTED, so the found region is the next op's target
// without a second gesture — and report the result. An empty pattern is a
// no-op with no marker.
func (e *editor) runFind() {
	pat := e.bar
	e.mode, e.bar = modeEdit, e.bar[:0]
	if len(pat) == 0 {
		return
	}
	e.pushFind(pat)
	total, ordinal, off := find.From(e.buf, pat, e.cur)
	if off < 0 {
		vi.ConsoleLine(findMissMarker(pat))
		return
	}
	e.hist.breakRun()
	e.sel, e.selSet, e.markOn = off+len(pat), true, false
	e.cur = off
	vi.ConsoleLine(findMarker(pat, ordinal, total))
}

// runGoto runs the goto bar's Return: move the caret to 1-based line n and
// report where that is, or how many lines the buffer actually has. An empty,
// non-digit, zero or over-long entry reports nothing (the Zig app's rule).
func (e *editor) runGoto() {
	digits := e.bar
	e.mode, e.bar = modeEdit, e.bar[:0]
	n, ok := parseLine(digits)
	if !ok {
		return
	}
	e.pushGoto(n)
	off := lineOffset(e.buf, n)
	if off < 0 {
		vi.ConsoleLine(gotoMissMarker(n, countLines(e.buf)))
		return
	}
	e.hist.breakRun()
	e.selSet, e.markOn = false, false
	e.cur = off
	vi.ConsoleLine(gotoMarker(n, off))
}

// unsavedExit answers the unsaved-changes dialog: arg0 == 0 is the Save choice
// (the only one the kernel posts today; the dialog's other two choices close
// the window in the kernel, so they arrive as WIN_CLOSE and take the
// ActionClosed arm with no write at all). The markers come in the Zig client's
// order - the save reports first, then the dialog response, then the clean
// close - so the gate's stage marker keeps meaning the bytes are on the share.
func (e *editor) unsavedExit(ev vi.Event) {
	published := true
	if ev.Arg0 == 0 {
		published = e.save()
	}
	e.releaseLease()
	vi.ConsoleLine(markerUnsaved)
	vi.ConsoleLine(markerClose)
	if !published {
		// The dialog promised to save, and the save failed. Exiting 0 here
		// would be data loss wearing a clean status (M66c review, #1495):
		// the error marker above is the receipt, and the non-zero exit is
		// what lets a caller tell the two apart.
		e.ta.CloseAndExit(1)
	}
	vi.ConsoleLine(markerOK)
	e.ta.CloseAndExit(0)
}

// insertionFor maps a key event to the Unicode scalar it inserts. The kernel
// puts the decoded codepoint in arg1 (ADR 0014); Return becomes a newline.
func insertionFor(ev vi.Event) (rune, bool) {
	if ev.Kind != vi.EvKeyDown || ev.Flags&modCtrl != 0 {
		return 0, false
	}
	if ev.Arg1 == codeReturn || ev.Arg1 == codeNewline {
		return '\n', true
	}
	if (ev.Arg1 >= 0x20 && ev.Arg1 < 0x7f || ev.Arg1 >= 0xa0) &&
		ev.Arg1 <= utf8.MaxRune &&
		(ev.Arg1 < 0xd800 || ev.Arg1 > 0xdfff) {
		return rune(ev.Arg1), true
	}
	return 0, false
}

// --- selection -----------------------------------------------------------
// #2199: the selection is an anchor (sel) plus the caret — nothing else.
// selRange is the only reader; every editor state it draws from or splices
// goes through it, so "what is selected" has exactly one definition.

// selRange returns [lo,hi) when a selection is pinned and non-empty.
func (e *editor) selRange() (lo, hi int, ok bool) {
	e.clampCaret()
	if !e.selSet || e.sel == e.cur {
		return 0, 0, false
	}
	lo, hi = e.sel, e.cur
	if lo > hi {
		lo, hi = hi, lo
	}
	if lo < 0 {
		lo = 0
	}
	if hi > len(e.buf) {
		hi = len(e.buf)
	}
	return lo, hi, lo < hi
}

// selBytes returns a COPY of the selected bytes — the clipboard stores
// bytes, not aliases, and a cut splices the buffer out from under them.
func (e *editor) selBytes() ([]byte, bool) {
	lo, hi, ok := e.selRange()
	if !ok {
		return nil, false
	}
	return append([]byte{}, e.buf[lo:hi]...), true
}

// moveCaret lands the caret at to. With extend (a Shift modifier or the
// ctrl-shift-m mark) the selection grows from its anchor; without it the
// selection collapses. Either way a caret move closes an open run.
func (e *editor) moveCaret(to int, extend bool) {
	e.clampCaret()
	if to < 0 {
		to = 0
	}
	if to > len(e.buf) {
		to = len(e.buf)
	}
	e.hist.breakRun()
	if extend {
		if !e.selSet {
			e.sel, e.selSet = e.cur, true
		}
	} else {
		e.selSet, e.markOn = false, false
	}
	e.cur = to
}

// selectAll is Ctrl-A in the document: anchor at 0, caret at the end.
func (e *editor) selectAll() {
	e.hist.breakRun()
	e.sel, e.selSet, e.markOn = 0, true, false
	e.cur = len(e.buf)
}

// toggleMark is Ctrl-Shift-M: with the mark set, plain arrows extend the
// selection — the runner's chord table cannot spell shift+arrow, so this is
// the live seat's selection gesture; clearing the mark drops the selection.
func (e *editor) toggleMark() bool {
	e.markOn = !e.markOn
	if !e.markOn {
		e.selSet = false
		vi.ConsoleLine(markerMark + "clear")
	} else {
		vi.ConsoleLine(markerMark + "set")
	}
	return true
}

// --- bounded undo/redo ----------------------------------------------------
// applyOp is the ONE path a document edit takes: splice, caret, record. Runs
// merge inside push(); every other caller-facing path (moves, mode changes,
// clipboard ops, undo/redo) calls hist.breakRun() first so a run only ever
// joins truly consecutive keystrokes.
func (e *editor) applyOp(o editOp, cur int) {
	e.buf = applySplices(e.buf, o.sp, false)
	e.cur = cur
	e.hist.push(o)
	e.selSet, e.markOn = false, false
	e.markDirty()
}

// undo reverts the newest op and parks the caret at the END of the reverted
// region's old text — the position a fresh find-from-caret scans past. An
// empty stack prints the `none` variant the gates count separately.
func (e *editor) undo() {
	o, ok := e.hist.popUndo()
	if !ok {
		vi.ConsoleLine(markerUndo + "none")
		return
	}
	e.buf = applySplices(e.buf, o.sp, true)
	e.cur = o.sp[0].pos + len(o.sp[0].old)
	e.selSet, e.markOn = false, false
	e.markDirty()
	vi.ConsoleLine(markerUndo + "n=" + vi.Itoa64(int64(len(e.hist.undo))) +
		" cur=" + vi.Itoa64(int64(e.cur)))
}

// redo reapplies the newest undone op, caret after its inserted text.
func (e *editor) redo() {
	o, ok := e.hist.popRedo()
	if !ok {
		vi.ConsoleLine(markerRedo + "none")
		return
	}
	e.buf = applySplices(e.buf, o.sp, false)
	// Caret after the last splice's inserted text — in APPLIED-buffer
	// coordinates, so shift the original pos by the earlier splices' delta.
	shift := 0
	for _, s := range o.sp[:len(o.sp)-1] {
		shift += len(s.ins) - len(s.old)
	}
	last := o.sp[len(o.sp)-1]
	e.cur = last.pos + shift + len(last.ins)
	e.selSet, e.markOn = false, false
	e.markDirty()
	vi.ConsoleLine(markerRedo + "n=" + vi.Itoa64(int64(len(e.hist.redo))) +
		" cur=" + vi.Itoa64(int64(e.cur)))
}

// --- clipboard ------------------------------------------------------------
// #2199: copy, cut and paste go through slots 38/39 unconditionally — the
// kernel decides who may touch the shared buffer, and a refusal prints the
// negative code on the op's marker so the M97g-F4 boundary is observable.

// copy stages the selection; it never touches the buffer.
func (e *editor) copy() {
	b, ok := e.selBytes()
	if !ok {
		vi.ConsoleLine(markerCopy + "none")
		return
	}
	n, r := clipWrite(b)
	if r < 0 {
		vi.ConsoleLine(markerCopy + "rc=" + vi.Itoa64(r))
		return
	}
	vi.ConsoleLine(markerCopy + "n=" + vi.Itoa64(int64(n)))
}

// cut is copy plus the delete splice; a refused write leaves the buffer
// alone (the bytes stay where they were, selection included).
func (e *editor) cut() {
	lo, hi, ok := e.selRange()
	if !ok {
		vi.ConsoleLine(markerCut + "none")
		return
	}
	n, r := clipWrite(e.buf[lo:hi])
	if r < 0 {
		vi.ConsoleLine(markerCut + "rc=" + vi.Itoa64(r))
		return
	}
	old := append([]byte{}, e.buf[lo:hi]...)
	e.applyOp(editOp{kind: opEdit, sp: []splice{{pos: lo, old: old}}}, lo)
	vi.ConsoleLine(markerCut + "n=" + vi.Itoa64(int64(n)))
}

// paste splices the clipboard at the caret — over the selection when one is
// pinned, so paste-over-selection is one undoable op too.
func (e *editor) paste() {
	b, r := clipRead()
	if r < 0 {
		vi.ConsoleLine(markerPaste + "rc=" + vi.Itoa64(r))
		return
	}
	if len(b) == 0 {
		vi.ConsoleLine(markerPaste + "empty")
		return
	}
	e.clampCaret()
	pos := e.cur
	var old []byte
	if lo, hi, ok := e.selRange(); ok {
		pos = lo
		old = append([]byte{}, e.buf[lo:hi]...)
	}
	if splicedLen(len(e.buf), []splice{{pos: pos, old: old, ins: b}}, false) > maxBuffer {
		vi.ConsoleLine(markerPaste + "rc=" + vi.Itoa64(-vsys.ErrENOMEM))
		return
	}
	e.applyOp(editOp{kind: opEdit, sp: []splice{{pos: pos, old: old, ins: b}}}, pos+len(b))
	vi.ConsoleLine(markerPaste + "n=" + vi.Itoa64(int64(len(b))))
}

// drop splices a delivered drag payload at the caret — the M124a-2 (#2677)
// drop half of paste(): same over-selection shape, same one-undoable-op
// semantics, the marker naming the seat-declared mime instead of a clipboard
// n. A nil payload is the seat's "no envelope" case, named like a refusal.
func (e *editor) drop(offer tabapp.DragOffer) {
	b := offer.Blob
	if b == nil {
		vi.ConsoleLine(markerDrop + "no-payload")
		return
	}
	if len(b) == 0 {
		vi.ConsoleLine(markerDrop + "empty")
		return
	}
	e.clampCaret()
	pos := e.cur
	var old []byte
	if lo, hi, ok := e.selRange(); ok {
		pos = lo
		old = append([]byte{}, e.buf[lo:hi]...)
	}
	if splicedLen(len(e.buf), []splice{{pos: pos, old: old, ins: b}}, false) > maxBuffer {
		vi.ConsoleLine(markerDrop + "rc=" + vi.Itoa64(-vsys.ErrENOMEM))
		return
	}
	e.applyOp(editOp{kind: opEdit, sp: []splice{{pos: pos, old: old, ins: b}}}, pos+len(b))
	vi.ConsoleLine(markerDrop + offer.Mime + " n=" + vi.Itoa64(int64(len(b))))
}

// --- primary selection (M124e, #2584) ---------------------------------------
// The seat owns the PRIMARY buffer; this app publishes its selection on
// change and splices a delivered paste at the caret. Both directions are
// gated by the manifest's selection=primary — the app speaks either way
// and the seat's refusal is the opt-out, so the code below never checks
// the cap itself.

// selPub records the last-published range so publishSel only spends an RPC
// on a real change. A cleared selection is never published — PRIMARY keeps
// the LAST selection, not the current caret state.
var (
	selPubLo, selPubHi int
	selPubOK           bool
)

// publishSel pushes the live selection to the seat's primary buffer when
// it changed since the last publish. One compare per loop pass is the
// whole idle cost; an RPC (stage + kind-27) fires only on a new non-empty
// range. A refused ack (cap off, oversize) just means no publish — the
// next change tries again, and the marker names the attempt honestly.
func (e *editor) publishSel() {
	if e.ta == nil || !e.ta.TabAware {
		return
	}
	lo, hi, ok := e.selRange()
	if !ok {
		return
	}
	if selPubOK && lo == selPubLo && hi == selPubHi {
		return
	}
	b := append([]byte{}, e.buf[lo:hi]...)
	if vi.SelPublish(uint32(e.ta.Win), b, appName) {
		selPubOK, selPubLo, selPubHi = true, lo, hi
		vi.ConsoleLine(markerSelPub + "n=" + vi.Itoa64(int64(len(b))))
	}
}

// selPaste splices a seat-delivered primary paste at the caret — the
// paste()/drop() shape again: over the selection when one is pinned, one
// undoable op, the marker naming the byte count it actually took.
func (e *editor) selPaste(b []byte) {
	if len(b) == 0 {
		vi.ConsoleLine(markerSelPaste + "empty")
		return
	}
	e.clampCaret()
	pos := e.cur
	var old []byte
	if lo, hi, ok := e.selRange(); ok {
		pos = lo
		old = append([]byte{}, e.buf[lo:hi]...)
	}
	if splicedLen(len(e.buf), []splice{{pos: pos, old: old, ins: b}}, false) > maxBuffer {
		vi.ConsoleLine(markerSelPaste + "rc=" + vi.Itoa64(-vsys.ErrENOMEM))
		return
	}
	e.applyOp(editOp{kind: opEdit, sp: []splice{{pos: pos, old: old, ins: b}}}, pos+len(b))
	vi.ConsoleLine(markerSelPaste + "n=" + vi.Itoa64(int64(len(b))))
}

// --- status line ----------------------------------------------------------

// statusText is the chrome row's right-aligned status AND the serial
// marker's body: `line=L/T col=C [sel=N] [err=I/N] [*]` — one rule, two
// readers.
func (e *editor) statusText() string {
	line, col := caretLineCol(e.buf, e.cur)
	s := "line=" + vi.Itoa64(int64(line)) + "/" + vi.Itoa64(int64(countLines(e.buf))) +
		" col=" + vi.Itoa64(int64(col))
	if lo, hi, ok := e.selRange(); ok {
		s += " sel=" + vi.Itoa64(int64(hi-lo))
	}
	// M138b: the diagnostics count rides the status line while a list is
	// loaded — `err=N` before a landing, `err=I/N` once jumpDiag selected
	// a row (diagsSel is also the last-jumped index).
	if len(e.diags) > 0 {
		s += " err="
		if e.diagsSel >= 0 {
			s += vi.Itoa64(int64(e.diagsSel+1)) + "/"
		}
		s += vi.Itoa64(int64(len(e.diags)))
	}
	if e.dirty {
		s += " *"
	}
	return s
}

// emitStatus publishes the status line on its edges: the serial marker fires
// only when the text changed, so a caret walk prints once per landing, not
// once per key.
func (e *editor) emitStatus() {
	s := e.statusText()
	if s == e.status {
		return
	}
	e.status = s
	vi.ConsoleLine(markerStatus + s)
}

// --- replace ---------------------------------------------------------------

// runReplace replaces the match find would land on — same scan, same ordinal
// — then parks the caret after the replacement.
func (e *editor) runReplace() {
	pat := append([]byte{}, e.bar...)
	repl := append([]byte{}, e.bar2...)
	e.closeBar()
	if len(pat) == 0 {
		vi.ConsoleLine(markerRepl + "' -> '" + string(repl) + "' no-pattern")
		return
	}
	total, ordinal, off := find.From(e.buf, pat, e.cur)
	if off < 0 {
		vi.ConsoleLine(markerRepl + string(pat) + "' -> '" + string(repl) + "' no-match")
		return
	}
	old := append([]byte{}, e.buf[off:off+len(pat)]...)
	if len(e.buf)-len(old)+len(repl) > maxBuffer {
		vi.ConsoleLine(markerRepl + string(pat) + "' -> '" + string(repl) +
			"' rc=" + vi.Itoa64(-vsys.ErrENOMEM))
		return
	}
	e.hist.breakRun()
	e.applyOp(editOp{kind: opEdit, sp: []splice{{pos: off, old: old, ins: repl}}}, off+len(repl))
	vi.ConsoleLine(markerRepl + string(pat) + "' -> '" + string(repl) + "' hit=" +
		vi.Itoa64(int64(ordinal)) + "/" + vi.Itoa64(int64(total)))
}

// runReplaceAll splices every match in one op — a single Ctrl-Z reverts the
// whole pass. n equals find's total for the same pattern: both walk the same
// non-overlapping scan, and the splices are computed against the ORIGINAL
// buffer so a replacement containing the pattern cannot re-match itself.
func (e *editor) runReplaceAll() {
	pat := append([]byte{}, e.bar...)
	repl := append([]byte{}, e.bar2...)
	e.closeBar()
	if len(pat) == 0 {
		vi.ConsoleLine(markerReplAll + "' -> '" + string(repl) + "' no-pattern")
		return
	}
	sp := replaceAllSplices(e.buf, pat, repl)
	if len(sp) == 0 {
		vi.ConsoleLine(markerReplAll + string(pat) + "' -> '" + string(repl) + "' n=0")
		return
	}
	if splicedLen(len(e.buf), sp, false) > maxBuffer {
		vi.ConsoleLine(markerReplAll + string(pat) + "' -> '" + string(repl) +
			"' rc=" + vi.Itoa64(-vsys.ErrENOMEM))
		return
	}
	e.hist.breakRun()
	e.applyOp(editOp{kind: opEdit, sp: sp}, sp[0].pos+len(repl))
	vi.ConsoleLine(markerReplAll + string(pat) + "' -> '" + string(repl) +
		"' n=" + vi.Itoa64(int64(len(sp))))
}

// insert splices one UTF-8 encoded scalar at the byte caret and marks the
// buffer dirty (the dirty marker prints once, on the first edit). Over a
// selection the delete+insert is one composite op, so one Ctrl-Z restores
// the selected text AND removes the typed rune.
func (e *editor) insert(ch rune) bool {
	encoded := []byte(string(ch))
	e.clampCaret()
	if lo, hi, ok := e.selRange(); ok {
		if len(e.buf)-(hi-lo)+len(encoded) > maxBuffer {
			return false
		}
		old := append([]byte{}, e.buf[lo:hi]...)
		e.applyOp(editOp{kind: opEdit, sp: []splice{{pos: lo, old: old, ins: encoded}}}, lo+len(encoded))
		return true
	}
	if len(e.buf)+len(encoded) > maxBuffer {
		return false
	}
	e.applyOp(editOp{kind: opInsRun, sp: []splice{{pos: e.cur, ins: encoded}}}, e.cur+len(encoded))
	return true
}

// backspace removes the Unicode scalar before the byte caret — or the whole
// selection, as one op.
func (e *editor) backspace() bool {
	e.clampCaret()
	if lo, hi, ok := e.selRange(); ok {
		old := append([]byte{}, e.buf[lo:hi]...)
		e.applyOp(editOp{kind: opEdit, sp: []splice{{pos: lo, old: old}}}, lo)
		return true
	}
	if e.cur == 0 {
		return false
	}
	prev := moveLeft(e.buf, e.cur)
	old := append([]byte{}, e.buf[prev:e.cur]...)
	e.applyOp(editOp{kind: opDelRun, sp: []splice{{pos: prev, old: old}}}, prev)
	return true
}

// deleteForward is the Del key — the same run merge, forward direction.
func (e *editor) deleteForward() bool {
	e.clampCaret()
	if lo, hi, ok := e.selRange(); ok {
		old := append([]byte{}, e.buf[lo:hi]...)
		e.applyOp(editOp{kind: opEdit, sp: []splice{{pos: lo, old: old}}}, lo)
		return true
	}
	if e.cur >= len(e.buf) {
		return false
	}
	next := moveRight(e.buf, e.cur)
	old := append([]byte{}, e.buf[e.cur:next]...)
	e.applyOp(editOp{kind: opDelRun, sp: []splice{{pos: e.cur, old: old}}}, e.cur)
	return true
}

// clampCaret keeps the caret inside the buffer, so a buffer that shrank under
// it (a host test builds an editor by hand) cannot make an index panic.
func (e *editor) clampCaret() {
	if e.cur < 0 {
		e.cur = 0
	}
	if e.cur > len(e.buf) {
		e.cur = len(e.buf)
	}
}

func (e *editor) markDirty() {
	if e.dirty {
		return
	}
	e.dirty = true
	vi.ConsoleLine(markerDirty)
}

// save publishes the whole buffer to the path and reports whether the bytes
// are on the share.
//
// M66c review (#1495): the first version of this function was in-place
// (FileOpen + a FileWrite loop + FileTruncate), which is parity with the Zig
// app it replaced but the wrong side of the milestone: M66b's whole point is
// that a `/host` write is a PUBLISH, not an overwrite. M66a/M66b landed
// vi.WriteFileSafe (temp + fsync + delete + rename, fail-closed, no in-place
// truncation of the live path) exactly so the M66 apps inherit it, and the app
// carrying the unsaved-decline contract is the worst place to keep a
// half-write window: the dialog's Save choice is what a user reaches for when
// they are already afraid of losing the buffer.
//
// The publish is one call, so there is no partial-write branch to report:
// WriteFileSafe either puts the whole body at the path or removes its temp and
// returns the failing step's negative code. The marker keeps the Zig shape
// (`goedit: saved <path> n=<bytes>`) because the gates parse it.
//
// Failure is REPORTED and not swallowed: the error marker is printed here (the
// only place this app writes) and the false return is what the callers use to
// decide whether they may report a clean exit.
func (e *editor) save() bool {
	// M138b: format-on-save — a .go buffer is formatted before the publish
	// (a format error leaves it alone and shows the diagnostic); a build
	// without go/format prints the named refusal. Either way the write
	// below still decides the save.
	e.formatGo()
	if rc := e.ensureLease(); rc < 0 {
		vi.ConsoleLine(markerSaveErr + e.path + " " + vi.Itoa64(rc))
		e.raiseBanner("save " + e.path + " refused rc=" + vi.Itoa64(rc))
		return false
	}
	if rc := vi.WriteFileSafe(e.path, e.buf); rc < 0 {
		vi.ConsoleLine(markerSaveErr + e.path + " " + vi.Itoa64(rc))
		e.raiseBanner("save " + e.path + " failed rc=" + vi.Itoa64(rc))
		return false
	}
	e.dirty = false
	e.diskLen = len(e.buf)
	e.diskHash = fnv1a64(e.buf)
	vi.ConsoleLine(markerSaved + e.path + " n=" + vi.Itoa64(int64(len(e.buf))))
	return true
}

// ensureLease acquires or refreshes this editor's advisory write lease
// (M81d #1764). The open-time call takes the lease for the session; every
// save re-stamps it first, so a session longer than vi.LeaseExpirySeconds
// renews instead of fighting its own record. A refusal (-ErrEAGAIN: another
// writer holds the lease live) is the caller's sign to report and back off;
// a lease that was taken over meanwhile drops the stale handle so the next
// save retries from scratch.
func (e *editor) ensureLease() int64 {
	if e.lease == nil {
		l, rc := vi.AcquireFileLease(e.path, appName)
		if rc < 0 {
			return rc
		}
		e.lease = l
		vi.ConsoleLine(markerLeaseOK + vi.Itoa64(int64(l.PID)))
		return 0
	}
	if rc := e.lease.Refresh(); rc < 0 {
		e.lease = nil
		return rc
	}
	return 0
}

// releaseLease drops the session's lease at every exit path. A lease that
// was taken over meanwhile belongs to the new holder and Release refuses to
// delete it — the marker says which happened, because the gates read these
// lines.
func (e *editor) releaseLease() {
	if e.lease == nil {
		return
	}
	if rc := e.lease.Release(); rc >= 0 {
		vi.ConsoleLine(markerLeaseRel)
	} else {
		vi.ConsoleLine(markerLeaseRel + " rc=" + vi.Itoa64(rc))
	}
	e.lease = nil
}

// findMarker is the find bar's serial result, in the Zig app's exact shape:
// the ordinal is 1-based among all matches.
func findMarker(pat []byte, ordinal, total int) string {
	return markerFind + string(pat) + "' hit=" + vi.Itoa64(int64(ordinal)) + "/" + vi.Itoa64(int64(total))
}

// findMissMarker is the find bar's no-match shape.
func findMissMarker(pat []byte) string {
	return markerFind + string(pat) + "' no-match"
}

// gotoMarker is the goto bar's success shape.
func gotoMarker(line, offset int) string {
	return markerGoto + vi.Itoa64(int64(line)) + " offset=" + vi.Itoa64(int64(offset))
}

// gotoMissMarker is the goto bar's beyond-the-buffer shape.
func gotoMissMarker(line, lines int) string {
	return markerGoto + vi.Itoa64(int64(line)) + " miss lines=" + vi.Itoa64(int64(lines))
}

// countLines is the number of '\n'-separated lines. An empty buffer is one
// empty line, and a trailing newline opens a final empty one - the Zig app's
// count_lines rule verbatim, because the goto bar reports it.
func countLines(buf []byte) int {
	n := 1
	for _, b := range buf {
		if b == '\n' {
			n++
		}
	}
	return n
}

// lineOffset is the byte offset where 1-based line n starts (0 for line 1), or
// -1 when the buffer has fewer than n lines.
func lineOffset(buf []byte, n int) int {
	if n < 1 {
		return -1
	}
	if n == 1 {
		return 0
	}
	line := 1
	for i, b := range buf {
		if b != '\n' {
			continue
		}
		line++
		if line == n {
			return i + 1
		}
	}
	return -1
}

// parseLine parses the goto bar's digits as a 1-based line number. Empty,
// non-digit, zero and beyond-the-5-digit-bound entries are refused (the Zig
// app's rule), and a refused entry prints no marker at all: the gate greps
// only the two result shapes.
func parseLine(digits []byte) (int, bool) {
	if len(digits) == 0 || len(digits) > gotoDigitsMax {
		return 0, false
	}
	v := 0
	for _, c := range digits {
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + int(c-'0')
		if v > 99999 {
			return 0, false
		}
	}
	if v == 0 {
		return 0, false
	}
	return v, true
}

// Layout constants for the frame.
const (
	chromeH    = 24
	lineH      = 10
	maxLines   = 64
	textOrigin = 6
	caretW     = 2
)

// draw repaints the frame: a chrome bar with the path, the buffer line by
// line through the M56e text surface, the caret, and the focused bar's label.
func (e *editor) draw() {
	w, h := int(e.ta.W), int(e.ta.H)
	if w <= 0 || h <= 0 {
		w, h = natW, natH
	}
	tok := theme.Current
	e.fill(0, 0, w, chromeH, tok.ChromeBg)
	e.fill(0, chromeH, w, h-chromeH, tok.Bg)
	e.drawText(textOrigin, 8, "Edit  "+e.path, tok.Ink)

	adv := font.Advance(1)
	// #2199: the status line shares the chrome row, right-aligned — the same
	// string emitStatus publishes on the serial console.
	status := e.statusText()
	if sw := utf8.RuneCountInString(status) * adv; sw < w-textOrigin {
		e.drawText(w-textOrigin-sw, 8, status, tok.InkMuted)
	}
	// M83e: a staged accent belongs to the surface that owns the keyboard, so
	// the document shows it only in edit mode; a bar shows it below.
	pre := e.stage.Preedit()
	inDoc := pre != "" && e.mode == modeEdit

	slo, shi, selOn := e.selRange()
	// M138b: the caret bracket's match cell — one scan per paint, and only
	// while the caret sits on a bracket (matchCell refuses otherwise).
	mOff, mOK := e.matchCell()
	y := chromeH + 4
	line, start := 0, 0
	caretRow, caretCol := -1, 0
	for i := 0; i <= len(e.buf); i++ {
		if i != len(e.buf) && e.buf[i] != '\n' {
			continue
		}
		if line >= maxLines {
			break
		}
		// The selection paints UNDER this row's text: the cells of the
		// [start,i) byte range the [slo,shi) selection covers, plus one cell
		// for a covered newline so a selection trailing a line still reads.
		if selOn {
			loB, hiB := slo, shi
			if loB < start {
				loB = start
			}
			if hiB > i {
				hiB = i
			}
			c0, c1 := -1, -1
			if loB < hiB {
				c0 = utf8.RuneCount(e.buf[start:loB])
				c1 = utf8.RuneCount(e.buf[start:hiB])
				if shi > i && i < len(e.buf) && hiB == i {
					c1++ // the covered newline's cell
				}
			} else if loB == i && shi > i && i < len(e.buf) {
				c0 = utf8.RuneCount(e.buf[start:i])
				c1 = c0 + 1 // a selection starting exactly on the newline
			}
			if c0 >= 0 {
				e.fill(textOrigin+c0*adv, y, (c1-c0)*adv, 8, tok.Selection)
			}
		}
		// The match paints under this row's text too, the selection's own
		// trick: the bracket's cell, teal, so the pair reads at a glance.
		if mOK && mOff >= start && mOff < i {
			mc := utf8.RuneCount(e.buf[start:mOff])
			e.fill(textOrigin+mc*adv, y, adv, 8, colMatch)
		}
		onCaret := e.cur >= start && e.cur <= i
		if inDoc && onCaret {
			// The accent is drawn where it will land, and the text after the
			// caret moves right one cell, as it will when the accent commits.
			col := utf8.RuneCount(e.buf[start:e.cur])
			e.drawText(textOrigin, y, string(e.buf[start:e.cur]), tok.Ink)
			e.drawPreedit(textOrigin+col*adv, y, pre)
			e.drawText(textOrigin+(col+1)*adv, y, string(e.buf[e.cur:i]), tok.Ink)
		} else if i > start {
			e.drawText(textOrigin, y, string(e.buf[start:i]), tok.Ink)
		}
		// M20 U3: the caret's cell, so a find or a goto visibly MOVED it.
		if onCaret {
			caretRow, caretCol = line, utf8.RuneCount(e.buf[start:e.cur])
			if inDoc {
				caretCol++
			}
		}
		y += lineH
		line++
		start = i + 1
	}
	// M123b (#2576): an empty buffer gets the shared empty-state plate —
	// icon, headline and the chords that answer on a blank document — under
	// the caret, which still paints at the text origin (type to insert).
	if len(e.buf) == 0 && e.mode != modePicker && e.mode != modeDialog && e.mode != modeDiags && e.mode != modeHints {
		(&widgets.EmptyState{
			R:        widgets.Rect{X: textOrigin, Y: chromeH + 4, W: w - 2*textOrigin, H: h - chromeH - 8},
			Icon:     "|",
			Headline: "Empty buffer",
			Hints:    []string{"type to insert", "^O open · ^S save · ^F find · ^G goto"},
		}).Draw(e.ta.Canvas())
		if !e.emptyShown {
			e.emptyShown = true
			vi.ConsoleLine(markerEmpty + e.path)
		}
	}
	if len(e.buf) != 0 {
		e.emptyShown = false
	}
	if caretRow >= 0 && caretRow < maxLines {
		e.fill(textOrigin+caretCol*adv, chromeH+4+caretRow*lineH, caretW, 8, colCaret)
	}
	// M149c: the minimap column paints over the document's right edge —
	// after the text so a long line's tail cannot bleed into the strip —
	// but under every modal surface below.
	if e.minimap {
		e.drawMinimap(w, h)
	}
	if e.mode == modeDiags {
		e.drawDiags(w, h)
	} else if e.mode != modeEdit && e.mode != modePicker && e.mode != modeDialog && e.mode != modeHints {
		label := "Find: "
		if e.mode == modeGoto {
			label = "Goto: "
		} else if e.mode == modeReplace {
			label = "Repl: "
		}
		barY := h - lineH - 2
		e.drawText(textOrigin, barY, label+string(e.bar), tok.InkMuted)
		if e.mode == modeReplace {
			// The second field follows `->`; a small block under it marks
			// which field Tab has focused.
			fx := textOrigin + (utf8.RuneCountInString(label)+utf8.RuneCount(e.bar))*adv
			e.drawText(fx, barY, " -> ", tok.InkMuted)
			fx += 4 * adv
			e.drawText(fx, barY, string(e.bar2), tok.InkMuted)
			fx += utf8.RuneCount(e.bar2) * adv
			if e.bar2At {
				e.fill(fx, barY+8, adv, 1, colCaret)
			} else {
				e.fill(textOrigin+(utf8.RuneCountInString(label)+utf8.RuneCount(e.bar))*adv, barY+8, adv, 1, colCaret)
			}
		}
		if pre != "" {
			col := utf8.RuneCountInString(label) + utf8.RuneCount(e.bar)
			e.drawPreedit(textOrigin+col*adv, barY, pre)
		}
	}
	// M124b: the modal surfaces paint over the document — the picker's own
	// canvas plate, then the guard dialog if one is up.
	if e.mode == modePicker {
		e.pick.Draw(e.ta.Canvas())
	} else if e.mode == modeDialog {
		e.dlg.Draw(e.ta.Canvas())
	} else if e.mode == modeHints {
		e.hints.Draw(e.ta.Canvas())
	}
	// M123d: the error strip paints last of all — it stands over whatever
	// the frame already drew.
	if e.banner.Open && e.ta != nil {
		e.banner.R = e.bannerRect()
		e.banner.Draw(e.ta.Canvas())
	}
}

// drawDiags paints the M107c error panel: up to diagRowsMax rows anchored
// above the bar row — each the ERRORS.TXT line it came from, the selection
// under-painted like the text selection — and a bar line naming the
// selected row's file:line:col. Rows wider than the window are clipped at
// the last full cell, never split mid-glyph.
func (e *editor) drawDiags(w, h int) {
	if len(e.diags) == 0 {
		e.mode = modeEdit
		return
	}
	if e.diagsSel < 0 || e.diagsSel >= len(e.diags) {
		e.diagsSel = 0
	}
	tok := theme.Current
	adv := font.Advance(1)
	cols := (w - 2*textOrigin) / adv
	barY := h - lineH - 2
	// The window shows at most diagRowsMax rows ending near the selection;
	// a longer list scrolls by that anchor, bottom-aligned.
	first := e.diagsSel - diagRowsMax + 1
	if first < 0 {
		first = 0
	}
	y := barY - lineH
	for i := first + diagRowsMax - 1; i >= first; i-- {
		if i < len(e.diags) {
			text := e.diags[i].raw
			if utf8.RuneCountInString(text) > cols && cols > 0 {
				cut := cols
				for cut > 0 && cut < len(text) && !utf8.RuneStart(text[cut]) {
					cut--
				}
				text = text[:cut]
			}
			if i == e.diagsSel {
				e.fill(0, y, w, lineH, tok.Selection)
			}
			e.drawText(textOrigin, y, text, tok.Ink)
		}
		y -= lineH
	}
	r := e.diags[e.diagsSel]
	label := "Err " + vi.Itoa64(int64(e.diagsSel+1)) + "/" +
		vi.Itoa64(int64(len(e.diags))) + ": " + r.file + ":" +
		vi.Itoa64(int64(r.line)) + ":" + vi.Itoa64(int64(r.col))
	e.drawText(textOrigin, barY, label, tok.InkMuted)
}

// drawPreedit paints a pending dead-key accent in the caret colour with an
// underline in the spare pixel row under the glyph (lines are lineH apart and
// glyphs are 8 rows), so it reads as text that is not committed yet.
func (e *editor) drawPreedit(x, y int, mark string) {
	e.drawText(x, y, mark, colCaret)
	e.fill(x, y+8, font.Advance(1), 1, colCaret)
}

// --- M149c: themes + minimap -------------------------------------------------

// winID is the bound window id for the settings-bus calls, or 0 before
// tabapp.Init has run (host tests leave e.ta nil; the substituted seams
// ignore the id anyway).
func (e *editor) winID() uint32 {
	if e.ta == nil {
		return 0
	}
	return uint32(e.ta.Win)
}

// pollThemeChange consumes one settings-bus notice. An applied theme change
// reports itself so the loop repaints and receipts it; a key that is not
// `theme` or a value theme.Set refuses (amber/custom — GOEDIT ships the two
// token tables, no more) leaves the frame and reports nothing.
func (e *editor) pollThemeChange() (key, value string, applied bool) {
	key, value, ok := pollChange(e.winID())
	if !ok || key != "theme" || !theme.Set(value) {
		return "", "", false
	}
	return key, value, true
}

// miniW is the minimap column's width in pixels.
const miniW = 16

// minimapHit maps a window-local press to a 1-based buffer line, or refuses
// it: the press must land inside the column (x >= w-miniW) and in the
// document band (chromeH <= y < h). A row below the buffer's last line
// clamps to it — the column is a map, and the map's bottom edge is the end
// of the file.
func (e *editor) minimapHit(x, y int) (int, bool) {
	w, h := natW, natH
	if e.ta != nil {
		if int(e.ta.W) > 0 {
			w = int(e.ta.W)
		}
		if int(e.ta.H) > 0 {
			h = int(e.ta.H)
		}
	}
	if x < w-miniW || y < chromeH || y >= h {
		return 0, false
	}
	line := y - chromeH + 1
	if n := countLines(e.buf); line > n {
		line = n
	}
	return line, true
}

// minimapJump parks the caret at the start of the clicked line — the same
// landing the goto bar's Return produces, selection and mark dropped. The
// receipt names the 1-based line so the gate can pin the mapping against
// the status line that follows.
func (e *editor) minimapJump(line int) {
	off := lineOffset(e.buf, line)
	if off < 0 {
		off = len(e.buf)
	}
	e.moveCaret(off, false)
	vi.ConsoleLine(markerMinimap + vi.Itoa64(int64(line)))
}

// drawMinimap paints the column: a Gutter band down the document's right
// edge, and one pixel row per buffer line whose width is that line's rune
// count scaled to the buffer's widest line — the silhouette a real minimap
// reads as. The caret's line carries the constant amber accent instead of
// the muted ink, so the strip also answers "where am I". Lines past the
// band's height clip at the window edge, like the text view's own 64 rows.
func (e *editor) drawMinimap(w, h int) {
	tok := theme.Current
	x := w - miniW
	e.fill(x, chromeH, miniW, h-chromeH, tok.Gutter)
	rows := h - chromeH
	if rows <= 0 {
		return
	}
	// Widest visible line is the scale — a single pass before the paint.
	maxRunes := 1
	line, start := 0, 0
	for i := 0; i <= len(e.buf) && line < rows; i++ {
		if i != len(e.buf) && e.buf[i] != '\n' {
			continue
		}
		if n := utf8.RuneCount(e.buf[start:i]); n > maxRunes {
			maxRunes = n
		}
		line++
		start = i + 1
	}
	caretLine, _ := caretLineCol(e.buf, e.cur)
	line, start = 0, 0
	for i := 0; i <= len(e.buf) && line < rows; i++ {
		if i != len(e.buf) && e.buf[i] != '\n' {
			continue
		}
		n := utf8.RuneCount(e.buf[start:i])
		bw := n * miniW / maxRunes
		col := tok.Muted
		if line+1 == caretLine {
			col = colCaret
			if bw < 2 {
				bw = 2 // the accent must stay visible on a short or empty line
			}
		}
		if bw > 0 {
			e.fill(x, chromeH+line, bw, 1, col)
		}
		line++
		start = i + 1
	}
}
