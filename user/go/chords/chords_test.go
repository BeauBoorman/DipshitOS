package chords

import (
	"errors"
	"strings"
	"testing"
)

// TestGlobalValidates pins the shipped table: it must pass the checker, or
// the seat's fail-closed prologue would refuse to run.
func TestGlobalValidates(t *testing.T) {
	if err := Global.Validate(); err != nil {
		t.Fatalf("Global.Validate: %v", err)
	}
}

// TestFixtureRefused is the card's conflict test: the deliberately
// conflicting fixture — FIXTURE.ELF claiming the seat's palette chord
// (pin's home before M121a) at the seat's own dispatch point — is refused
// with the NAMED error, and the refusal names the chord, the scope, and
// both owners.
func TestFixtureRefused(t *testing.T) {
	bad := append(Global[:0:0], Global...)
	bad = append(bad, FixtureRow())
	err := bad.Validate()
	if !errors.Is(err, ErrChordConflict) {
		t.Fatalf("fixture must be refused with ErrChordConflict, got: %v", err)
	}
	for _, want := range []string{"ctrl+shift+p", "seat", "seat", FixtureOwner()} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("refusal %q does not name %q", err, want)
		}
	}
}

// TestSecondOwnerConflict synthesizes the case the registry exists to end:
// two features claiming one chord at one dispatch point.
func TestSecondOwnerConflict(t *testing.T) {
	chord := Chord{Mods: ModCtrl, Usage: UsageL}
	bad := Table{
		{Chord: chord, Owner: "seat", Scope: ScopeSeat, Action: "clear"},
		{Chord: chord, Owner: "SOMEAPP.ELF", Scope: ScopeSeat, Action: "clear"},
	}
	err := bad.Validate()
	if !errors.Is(err, ErrChordConflict) {
		t.Fatalf("want ErrChordConflict, got: %v", err)
	}
	if !strings.Contains(err.Error(), "seat") || !strings.Contains(err.Error(), "SOMEAPP.ELF") {
		t.Errorf("refusal must name both owners: %v", err)
	}
}

// TestCrossScopeCoexistence: the same chord at DIFFERENT dispatch points is
// not a conflict — that is the documented kernel-chrome/seat coexistence
// (ctrl+shift+f, ctrl+shift+v), not something the checker refuses.
func TestCrossScopeCoexistence(t *testing.T) {
	chord := Chord{Mods: ModCtrl | ModShift, Usage: UsageF}
	ok := Table{
		{Chord: chord, Owner: "kernel", Scope: ScopeKernelTerminal, Frozen: true},
		{Chord: chord, Owner: "seat", Scope: ScopeSeat, Action: "freeze-badge"},
	}
	if err := ok.Validate(); err != nil {
		t.Fatalf("cross-scope rows must validate: %v", err)
	}
}

// TestDuplicateRowRefused: the same row twice is a table bug, named as one.
func TestDuplicateRowRefused(t *testing.T) {
	row := Row{Chord: Chord{Mods: ModCtrl, Usage: UsageP}, Owner: "seat", Scope: ScopeSeat, Action: "pin"}
	bad := Table{row, row}
	err := bad.Validate()
	if err == nil || !strings.Contains(err.Error(), "listed twice") {
		t.Fatalf("duplicate row must be refused, got: %v", err)
	}
}

// TestSeatRowIntegrity: a seat row without an action cannot dispatch; a
// non-seat row with one has no dispatcher.
func TestSeatRowIntegrity(t *testing.T) {
	noAction := Table{{Chord: Chord{Mods: ModCtrl, Usage: UsageP}, Owner: "seat", Scope: ScopeSeat}}
	if err := noAction.Validate(); err == nil || !strings.Contains(err.Error(), "no action") {
		t.Fatalf("seat row without action must be refused, got: %v", err)
	}
	strayAction := Table{{Chord: Chord{Mods: ModCtrl, Usage: UsageP}, Owner: "GOEDIT.ELF", Scope: AppScope("GOEDIT.ELF"), Action: "pin"}}
	if err := strayAction.Validate(); err == nil || !strings.Contains(err.Error(), "action") {
		t.Fatalf("non-seat row with action must be refused, got: %v", err)
	}
	// An app row's scope must name its owner — the redundancy can never
	// drift into a row claiming another app's dispatch point.
	mismatch := Table{{Chord: Chord{Mods: ModCtrl, Usage: UsageS}, Owner: "GOEDIT.ELF", Scope: AppScope("NOTE.ELF")}}
	if err := mismatch.Validate(); err == nil || !strings.Contains(err.Error(), "scope must name its owner") {
		t.Fatalf("app scope/owner mismatch must be refused, got: %v", err)
	}
}

// TestAppScopesAreIndependent: GOEDIT.ELF and NOTE.ELF both own ctrl+s —
// real, grep-verified consumers — and that is not a conflict, because focus
// is exclusive: two apps never dispatch the same event.
func TestAppScopesAreIndependent(t *testing.T) {
	both := Table{
		{Chord: Chord{Mods: ModCtrl, Usage: UsageS}, Owner: "GOEDIT.ELF", Scope: AppScope("GOEDIT.ELF")},
		{Chord: Chord{Mods: ModCtrl, Usage: UsageS}, Owner: "NOTE.ELF", Scope: AppScope("NOTE.ELF")},
	}
	if err := both.Validate(); err != nil {
		t.Fatalf("per-app scopes must not conflict: %v", err)
	}
}

// TestLetterUsages pins the HID letter block: 'a' = 0x04 .. 'z' = 0x1D, the
// arithmetic kernel/src/input.zig and the runner both assume.
func TestLetterUsages(t *testing.T) {
	for letter, usage := range map[string]uint8{
		"a": UsageA, "c": UsageC, "d": UsageD, "e": UsageE, "f": UsageF,
		"g": UsageG, "k": UsageK, "l": UsageL, "n": UsageN, "p": UsageP, "r": UsageR,
		"s": UsageS, "t": UsageT, "u": UsageU, "v": UsageV, "w": UsageW, "y": UsageY,
	} {
		if want := uint8(0x04 + letter[0] - 'a'); usage != want {
			t.Errorf("usage %q = %#x want %#x (USB HID keyboard block)", letter, usage, want)
		}
	}
}

// TestChordString pins the rendering the refusal and GOSET name chords by:
// modifiers in ctrl,shift,alt order, then the key.
func TestChordString(t *testing.T) {
	cases := map[Chord]string{
		{ModCtrl | ModShift, UsageP}:           "ctrl+shift+p",
		{ModCtrl | ModShift | ModAlt, UsageR}:  "ctrl+shift+alt+r",
		{ModCtrl, UsageDigit1 + 2}:             "ctrl+3",
		{0, UsageEnter}:                        "enter",
		{0, UsagePageUp}:                       "pageup",
		{ModShift, UsageEnd}:                   "shift+end",
		{ModCtrl | ModShift, UsageLeftBracket}: "ctrl+shift+[",
		{ModAlt | ModShift, UsageTab}:          "shift+alt+tab",
		{ModCtrl, UsageSpace}:                  "ctrl+space",
		{ModCtrl, 0x99}:                        "ctrl+0x99",
	}
	for c, want := range cases {
		if got := c.String(); got != want {
			t.Errorf("Chord(%d,%#x).String() = %q want %q", c.Mods, c.Usage, got, want)
		}
	}
}

// TestEveryUsageNamed: a row whose usage renders as hex is a transcription
// error — the table only carries keys the name table knows.
func TestEveryUsageNamed(t *testing.T) {
	for i, r := range Global {
		if strings.Contains(r.Chord.String(), "0x") {
			t.Errorf("row %d (%s): usage %#x has no name", i, r.Chord, r.Chord.Usage)
		}
	}
}

// TestKernelRowsFrozen: the kernel chrome rows are recorded as frozen
// owners — the kernel is untouched by this registry.
func TestKernelRowsFrozen(t *testing.T) {
	for _, r := range Global {
		if r.Scope == ScopeKernelTerminal && !r.Frozen {
			t.Errorf("kernel row %s is not frozen", r.Chord)
		}
		if r.Scope != ScopeKernelTerminal && r.Frozen {
			t.Errorf("non-kernel row %s must not be frozen", r.Chord)
		}
	}
}

// TestCoexistenceRowsDocumented: the two chords genuinely served at two
// dispatch points (kernel terminal chrome + seat) carry both rows, so the
// coexistence is in the table instead of silent.
func TestCoexistenceRowsDocumented(t *testing.T) {
	for _, usage := range []uint8{UsageF, UsageV} {
		chord := Chord{Mods: ModCtrl | ModShift, Usage: usage}
		owners := map[Scope]bool{}
		for _, r := range Global {
			if r.Chord == chord {
				owners[r.Scope] = true
			}
		}
		if !owners[ScopeKernelTerminal] || !owners[ScopeSeat] {
			t.Errorf("%s must be recorded at both dispatch points, got %v", chord, owners)
		}
	}
}

// TestSeatRowsAreTheSeatSurface: the seat's rows are exactly the chords
// hid.go dispatches — the full named set, plus the nine digit rows, plus
// M132a's seven reserved rows (R4–R6: registered ahead of their handlers,
// honest no-ops until the named consumer lands its case).
func TestSeatRowsAreTheSeatSurface(t *testing.T) {
	wantActions := map[string]int{
		"launcher": 1, "start-surface": 1, "cycle-focus": 4, "focus-index": 9,
		"pin": 1, "palette": 1, "reopen": 1, "duplicate": 1, "snapshot-bundle": 1,
		"freeze-badge": 1, "split-cycle": 1, "nav-back": 1, "nav-forward": 1,
		"sel-paste": 1, "close": 1, "move-left": 1, "move-right": 1,
		"undo":      1,
		"clip-menu": 1,
		// M190b (#3237): the guest's own camera — full scanout and the
		// focused window's rect of it.
		"shot-full": 1, "shot-window": 1,
		// M132a (#2752): the wave's reserved seat chords.
		"pane-focus-left": 1, "pane-focus-right": 1, "pane-focus-up": 1,
		"pane-focus-down": 1, "space-prev": 1, "space-next": 1,
		"summon-emoji": 1,
	}
	got := map[string]int{}
	for _, r := range Global.SeatRows() {
		got[r.Action]++
	}
	for action, want := range wantActions {
		if got[action] != want {
			t.Errorf("seat action %q: %d rows want %d", action, got[action], want)
		}
	}
	if len(got) != len(wantActions) {
		t.Errorf("unexpected seat actions: %v", got)
	}
}

// TestM121bTabChordPicks pins the card's chosen spellings: close is
// ctrl+shift+w (the proposed ctrl+w is GOSH.ELF's kill-word — the seat must
// never bind it) and the move pair is ctrl+shift+pageup/pagedown. The
// collision half of the acceptance is TestGlobalValidates: these rows only
// exist because they pass it.
func TestM121bTabChordPicks(t *testing.T) {
	want := map[Chord]string{
		{ModCtrl | ModShift, UsageW}:        "close",
		{ModCtrl | ModShift, UsagePageUp}:   "move-left",
		{ModCtrl | ModShift, UsagePageDown}: "move-right",
	}
	got := map[Chord]string{}
	for _, r := range Global.SeatRows() {
		got[r.Chord] = r.Action
	}
	for c, action := range want {
		if got[c] != action {
			t.Errorf("seat chord %s: action %q want %q", c, got[c], action)
		}
	}
	// Plain ctrl+w must never become a seat chord: it is GOSH.ELF's
	// kill-word, and a seat row would eat the editor's key.
	if _, bound := got[Chord{ModCtrl, UsageW}]; bound {
		t.Error("ctrl+w must stay unbound at the seat (GOSH.ELF kill-word)")
	}
}

// TestM190bShotChordPicks pins the screenshot pair's spellings: the
// macOS shot chords (3 = full screen, 4 = the window) spelt in this
// table's modifier block — plain ctrl+digit is focus-index (M79f) and
// must stay the ONLY unshifted digit owner at the seat. The collision
// half of the acceptance is TestGlobalValidates.
func TestM190bShotChordPicks(t *testing.T) {
	want := map[Chord]string{
		{ModCtrl | ModShift, UsageDigit1 + 2}: "shot-full",
		{ModCtrl | ModShift, UsageDigit1 + 3}: "shot-window",
	}
	got := map[Chord]string{}
	for _, r := range Global.SeatRows() {
		got[r.Chord] = r.Action
	}
	for c, action := range want {
		if got[c] != action {
			t.Errorf("seat chord %s: action %q want %q", c, got[c], action)
		}
	}
	// The unshifted digit row is focus-index's and stays so: a shot
	// spelling without shift would eat M79f's rail-focus chord.
	for i := uint8(0); i < 9; i++ {
		if a := got[Chord{ModCtrl, UsageDigit1 + i}]; a != "focus-index" {
			t.Errorf("ctrl+%d: action %q want focus-index", i+1, a)
		}
	}
}

// TestM132aReservedChordPicks pins the wave reservation table's R4–R6
// spellings (ADR 0007 "M132 wave reservations"): the seat claims these
// chords now so no other lane binds them, and their actions are the
// names the consumer cards (M137a/M137c) implement. The collision half
// is TestGlobalValidates — the rows exist because they pass it.
func TestM132aReservedChordPicks(t *testing.T) {
	want := map[Chord]string{
		{ModCtrl | ModAlt, UsageLeft}:     "pane-focus-left",
		{ModCtrl | ModAlt, UsageRight}:    "pane-focus-right",
		{ModCtrl | ModAlt, UsageUp}:       "pane-focus-up",
		{ModCtrl | ModAlt, UsageDown}:     "pane-focus-down",
		{ModCtrl | ModAlt, UsagePageUp}:   "space-prev",
		{ModCtrl | ModAlt, UsagePageDown}: "space-next",
		{ModCtrl | ModShift, UsageE}:      "summon-emoji",
	}
	got := map[Chord]string{}
	for _, r := range Global.SeatRows() {
		got[r.Chord] = r.Action
	}
	for c, action := range want {
		if got[c] != action {
			t.Errorf("reserved seat chord %s: action %q want %q", c, got[c], action)
		}
	}
}
