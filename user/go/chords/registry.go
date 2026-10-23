// Package chords is M82c (#1770): the global shortcuts registry.
//
// Before this package every global chord was owned by whoever remembered to
// document it: the kernel's chrome chords lived as comments in
// kernel/src/input.zig, the seat's chords as scattered `if`s in
// gotabwm/hid.go, and each app's chords as its own key handler. Two features
// could claim the same chord silently. This package is the ONE table that
// names every global chord, its owner, and the dispatch point it is served
// at — plus the checker that refuses two owners of one chord with a named
// error.
//
// Ownership is per DISPATCH POINT (Scope), because the machine really has
// several: the kernel consumes its chrome chords while a kernel terminal
// front-end is focused, the seat acts on kind-21 WM_KEY always, and an app
// acts on its own KEY_DOWN while focused. One owner per (chord, scope) is
// the invariant; the checker refuses a second. Where a chord is genuinely
// served at two dispatch points today — ctrl+shift+f and ctrl+shift+v are
// both kernel terminal-window chrome AND seat chords — the table records
// both rows, so the coexistence is documented instead of silent; any THIRD
// claimant at either dispatch point is refused.
//
// The kernel's rows are FROZEN: the kernel is untouched by this card and no
// seat or app may take a kernel chrome chord at the kernel's dispatch point.
//
// Consumers:
//
//   - gotabwm/hid.go dispatches its seat chords FROM the table (a chord not
//     in the table is not the seat's, and still reaches the app per ADR 0009).
//   - goset renders the table (ctrl+shift+s toggles its shortcuts view).
//   - The host tests in this package pin the shipped table and prove the
//     checker refuses the deliberately conflicting fixture.
package chords

import (
	"errors"
	"fmt"
	"strings"
)

// Mods is a chord's modifier mask — the subset of the ADR 0009 modifier
// flags the dispatch points test (ctrl/shift/alt; cmd is in the flags word
// but no global chord uses it).
type Mods uint8

const (
	ModCtrl Mods = 1 << iota
	ModShift
	ModAlt
)

// USB HID keyboard usages (the kernel's WM_KEY arg0 / the boot report's
// keycodes). These are the same numbers gotabwm's hid.go pins against the
// runner and input.zig consumes; they live here so the table is the single
// source the dispatch matches against.
// The letter usages are the HID keyboard block: 'a' = 0x04 .. 'z' = 0x1D.
// table_test.go pins every one of them against that arithmetic.
const (
	UsageA            uint8 = 0x04
	UsageC            uint8 = 0x06
	UsageD            uint8 = 0x07
	UsageE            uint8 = 0x08
	UsageF            uint8 = 0x09
	UsageG            uint8 = 0x0A
	UsageH            uint8 = 0x0B
	UsageI            uint8 = 0x0C
	UsageK            uint8 = 0x0E
	UsageL            uint8 = 0x0F
	UsageN            uint8 = 0x11
	UsageP            uint8 = 0x13
	UsageR            uint8 = 0x15
	UsageS            uint8 = 0x16
	UsageT            uint8 = 0x17
	UsageU            uint8 = 0x18
	UsageV            uint8 = 0x19
	UsageW            uint8 = 0x1A
	UsageY            uint8 = 0x1C
	UsageZ            uint8 = 0x1D
	UsageDigit1       uint8 = 0x1E // digits 1..9 are 0x1E..0x26
	UsageLeftBracket  uint8 = 0x2F
	UsageRightBracket uint8 = 0x30
	UsageEnter        uint8 = 0x28
	UsageEscape       uint8 = 0x29
	UsageBksp         uint8 = 0x2A
	UsageTab          uint8 = 0x2B
	UsageSpace        uint8 = 0x2C
	UsageHome         uint8 = 0x4A
	UsagePageUp       uint8 = 0x4B
	UsageEnd          uint8 = 0x4D
	UsagePageDown     uint8 = 0x4E
	UsageRight        uint8 = 0x4F
	UsageLeft         uint8 = 0x50
	UsageDown         uint8 = 0x51
	UsageUp           uint8 = 0x52
	// UsageInsert is the keymap's Insert usage (0x70 — the runner's "insert"
	// token and input.zig's `\e[2~` encoder agree). M124e's primary-paste
	// chord is shift+insert.
	UsageInsert uint8 = 0x70
)

// Chord identifies one global shortcut: a modifier mask plus a USB HID
// keyboard usage. It is the registry's key — dispatch, the checker, and the
// GOSET view all match on exactly this pair.
type Chord struct {
	Mods  Mods
	Usage uint8
}

// String renders the chord the way the table, the refusal, and GOSET name
// it: modifiers in ctrl,shift,alt order, then the key ("ctrl+shift+p").
func (c Chord) String() string {
	var b strings.Builder
	if c.Mods&ModCtrl != 0 {
		b.WriteString("ctrl+")
	}
	if c.Mods&ModShift != 0 {
		b.WriteString("shift+")
	}
	if c.Mods&ModAlt != 0 {
		b.WriteString("alt+")
	}
	b.WriteString(usageName(c.Usage))
	return b.String()
}

// usageName names one HID usage for String. The letters, digits and the
// handful of named keys the table carries; anything else is hex, because
// inventing a name for a key nobody binds is how drift starts.
func usageName(u uint8) string {
	switch {
	case u >= UsageA && u <= UsageA+25:
		return string(rune('a' + u - UsageA))
	case u >= UsageDigit1 && u <= UsageDigit1+8:
		return string(rune('1' + u - UsageDigit1))
	}
	switch u {
	case UsageEnter:
		return "enter"
	case UsageEscape:
		return "escape"
	case UsageBksp:
		return "bksp"
	case UsageTab:
		return "tab"
	case UsageSpace:
		return "space"
	case UsageHome:
		return "home"
	case UsagePageUp:
		return "pageup"
	case UsageEnd:
		return "end"
	case UsagePageDown:
		return "pagedown"
	case UsageRight:
		return "right"
	case UsageLeft:
		return "left"
	case UsageDown:
		return "down"
	case UsageUp:
		return "up"
	case UsageLeftBracket:
		return "["
	case UsageRightBracket:
		return "]"
	case UsageInsert:
		return "insert"
	}
	return fmt.Sprintf("0x%02x", u)
}

// Scope names the ONE dispatch point that serves a chord. Ownership is per
// scope: the same chord may be served at two scopes only when the machine
// really dispatches both (see the package comment), and the checker refuses
// a second owner at one scope.
type Scope string

const (
	// ScopeKernelTerminal is the kernel presentation's consumption while a
	// kernel terminal front-end (a tty-bound window) is focused. The kernel
	// is untouched by this registry; its rows are recorded, frozen owners.
	ScopeKernelTerminal Scope = "kernel-terminal"
	// ScopeSeat is GOTABWM's handleWmKey: kind-21 WM_KEY fanned to the
	// registered seat on every key-DOWN edge, whatever is focused.
	ScopeSeat Scope = "seat"
)

// AppScope is the dispatch point of a focused app's own KEY_DOWN path
// (ADR 0009 E2). It is per-app because focus is exclusive — two apps never
// dispatch the same event, so each app's chords live in their own scope
// ("app/GOEDIT.ELF"). Validate ties an app row's scope to its owner, so the
// two can never drift apart.
func AppScope(binary string) Scope { return Scope("app/" + binary) }

// IsAppScope reports whether the scope is a per-app dispatch point.
func IsAppScope(s Scope) bool {
	return len(s) > 4 && string(s[:4]) == "app/"
}

// Row is one registry entry: one chord, one owner, one dispatch point.
type Row struct {
	Chord Chord
	// Owner names who serves the chord at Scope: "kernel", "seat", or the
	// app binary ("GOEDIT.ELF").
	Owner string
	// Scope is the dispatch point the chord is served at.
	Scope Scope
	// Action is the seat-scope machine name hid.go dispatches on. Non-seat
	// rows carry no action (their owners implement their own handling).
	Action string
	// Label is the user-facing description GOSET shows.
	Label string
	// Since names the card that landed the row.
	Since string
	// Frozen marks a row whose owner may not be changed or re-homed (the
	// kernel chrome chords).
	Frozen bool
}

// Table is the registry: every global chord and its one owner per dispatch
// point.
type Table []Row

// SeatRows returns the table's seat-scope rows in declaration order — the
// order hid.go's dispatch walks.
func (t Table) SeatRows() []Row {
	out := make([]Row, 0, len(t))
	for _, r := range t {
		if r.Scope == ScopeSeat {
			out = append(out, r)
		}
	}
	return out
}

// ErrChordConflict is the named error the checker refuses two owners of one
// chord with. Callers test it with errors.Is.
var ErrChordConflict = errors.New("chord conflict")

// Validate refuses two owners of one chord at one dispatch point, a row
// listed twice, and rows whose shape cannot dispatch (a seat row without
// its action; an app row whose scope does not name its owner). The returned
// error wraps ErrChordConflict for the ownership case and names both
// owners, so a refusal reads as a sentence.
func (t Table) Validate() error {
	seen := make(map[Chord]map[Scope]string, len(t))
	for _, r := range t {
		if r.Owner == "" {
			return fmt.Errorf("chord registry: %s at %s has no owner", r.Chord, r.Scope)
		}
		if r.Scope == ScopeSeat && r.Action == "" {
			return fmt.Errorf("chord registry: %s at %s owned by %s has no action", r.Chord, r.Scope, r.Owner)
		}
		if r.Scope != ScopeSeat && r.Action != "" {
			return fmt.Errorf("chord registry: %s at %s carries an action but only seat rows dispatch", r.Chord, r.Scope)
		}
		if IsAppScope(r.Scope) && r.Scope != AppScope(r.Owner) {
			return fmt.Errorf("chord registry: %s owned by %s carries scope %s — an app row's scope must name its owner",
				r.Chord, r.Owner, r.Scope)
		}
		owners, ok := seen[r.Chord]
		if !ok {
			seen[r.Chord] = map[Scope]string{r.Scope: r.Owner}
			continue
		}
		if prev, dup := owners[r.Scope]; dup {
			if prev == r.Owner {
				return fmt.Errorf("chord registry: %s at %s listed twice (%s)", r.Chord, r.Scope, r.Owner)
			}
			return fmt.Errorf("%w: %s at %s owned by %s and %s",
				ErrChordConflict, r.Chord, r.Scope, prev, r.Owner)
		}
		owners[r.Scope] = r.Owner
	}
	return nil
}

// fixtureOwner names the deliberately conflicting registration the tests and
// the gate's fixture run feed the checker: an app claiming a seat-owned
// chord at the seat's own dispatch point.
const fixtureOwner = "FIXTURE.ELF"

// FixtureRow is the deliberate conflict: the seat's palette chord (pin's
// home before M121a re-homed it) claimed by an app at the seat's dispatch
// point. Appending it to Global must be refused by Validate with
// ErrChordConflict — that refusal is the checker's test, on the host and
// (seeded by /host/GOTABWM.CHORDCONFLICT) in the guest.
func FixtureRow() Row {
	return Row{
		Chord:  Chord{Mods: ModCtrl | ModShift, Usage: UsageP},
		Owner:  fixtureOwner,
		Scope:  ScopeSeat,
		Action: "pin",
		Label:  "deliberately conflicting fixture (M82c): a second owner of the seat's palette chord",
		Since:  "#1770",
		Frozen: false,
	}
}

// FixtureOwner is the fixture row's owner token, exported so a refusal can
// be asserted end to end without reaching into the package.
func FixtureOwner() string { return fixtureOwner }
