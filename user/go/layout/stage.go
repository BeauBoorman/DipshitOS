package layout

const (
	usageBackspace = 0x2a
	// A source with no usage (a host test, a synthetic event) spells
	// Backspace as one of these codepoints instead.
	codeBackspace = 0x08
	codeDelete    = 0x7f
)

// Input is one key-down as a Stage sees it.
type Input struct {
	// Usage is the USB HID usage (the event's arg0), or 0 when the source has
	// none.
	Usage uint32
	Shift bool
	// Chord is set when Ctrl or Alt is held. A chord is a command, never text.
	Chord bool
	// Sym is the symbol the kernel translated (the event's arg1), 0 for none.
	Sym rune
}

// Step is what a text surface does with one key after Feed.
type Step struct {
	// Commit is the text to insert at the caret before anything else. It
	// aliases the stage's own storage and is valid until the next call.
	Commit []rune
	// Pass reports that the stage did not consume the key: after inserting
	// Commit, the surface handles the key as it always did. When Pass is
	// false the key is fully handled, even if Commit is empty (an accent was
	// staged or cancelled and only the pending mark changed).
	Pass bool
}

// Composer is the pending-text surface a text surface consumes: Feed
// advances by one key-down, Preedit is the staged text to paint ("" when
// nothing is staged), Flush commits the staged text to the caret, Cancel
// drops it, and Candidates lists the forms the staged text can take —
// nil for a composer with exactly one form, so a painter can show the
// list without knowing which composer is active. Stage satisfies it for
// dead keys; IME (ime.go) satisfies it for romaji->kana composition.
type Composer interface {
	Feed(Input) Step
	Preedit() string
	Flush() []rune
	Cancel()
	// Candidates returns every form the staged text can commit, in the
	// order the composer cycles them, plus the index of the form Preedit
	// currently shows. (nil, 0) when nothing is staged or the composer
	// has no alternates.
	Candidates() (forms []string, sel int)
}

// Stage holds input that has been typed but not yet committed to the text: the
// pending half of a dead-key sequence. It is deliberately the whole surface a
// text field needs (Feed, Pending/Preedit for painting, Flush and Cancel for
// focus changes), so an input method that stages more than one accent could
// replace it without the field or its painter changing. That is the seam; the
// IME lives in ime.go.
//
// The zero Stage has no layout and therefore no dead keys: every key passes
// through, so a surface that never calls SetLayout behaves exactly as it did.
type Stage struct {
	layout  ID
	pending Accent
	buf     [2]rune
}

// NewStage returns a stage for a layout.
func NewStage(id ID) Stage { return Stage{layout: id} }

// Layout reports the layout the stage resolves dead keys under.
func (s *Stage) Layout() ID { return s.layout }

// SetLayout switches layouts. A half-typed sequence belongs to the old layout,
// so it is dropped; set the layout when the surface is created, not mid-word.
func (s *Stage) SetLayout(id ID) {
	s.layout = id
	s.pending = 0
}

// Pending reports the staged accent, if any.
func (s *Stage) Pending() (Accent, bool) { return s.pending, s.pending != 0 }

// Preedit is the text a painter shows for the pending state, in a face that
// can draw it, or "" when nothing is staged. See Accent.Mark.
func (s *Stage) Preedit() string {
	if s.pending == 0 {
		return ""
	}
	return string(s.pending.Mark())
}

// Cancel drops the staged accent without typing it.
func (s *Stage) Cancel() { s.pending = 0 }

// Candidates reports no alternates: a staged accent has exactly one form —
// its mark — so the pre-edit never offers a list.
func (s *Stage) Candidates() (forms []string, sel int) { return nil, 0 }

var _ Composer = (*Stage)(nil)

// Flush types the staged accent as its literal character and clears the
// state. Call it when the sequence can no longer continue in this surface (it
// lost focus, or was clicked). The result is nil when nothing was staged.
func (s *Stage) Flush() []rune {
	if s.pending == 0 {
		return nil
	}
	lit := s.pending.Literal()
	s.pending = 0
	return s.commit(lit, 0)
}

// Feed advances the stage by one key-down.
//
// With nothing staged, a dead key is staged and consumed; any other key
// passes. With an accent staged:
//   - a base that composes with it commits the composed character;
//   - any other printable commits the accent's literal, then the character, so
//     a stray combination is never swallowed;
//   - the same dead key again commits the bare accent, and a different dead key
//     commits the first accent's literal and stages the new one;
//   - Backspace drops the staged accent, as it would delete a typed character;
//   - every other key (Enter, Tab, Escape, arrows, chords) commits the literal
//     and then passes, so the key still does its job.
func (s *Stage) Feed(in Input) Step {
	if in.Chord {
		return s.flushThenPass()
	}
	dead, isDead := DeadKey(s.layout, in.Usage, in.Shift)
	if s.pending == 0 {
		if isDead {
			s.pending = dead
			return Step{}
		}
		return Step{Pass: true}
	}
	held := s.pending
	switch {
	case isBackspace(in):
		s.pending = 0
		return Step{}
	case isDead:
		s.pending = 0
		if dead != held {
			s.pending = dead
		}
		return Step{Commit: s.commit(held.Literal(), 0)}
	case Printable(in.Sym):
		s.pending = 0
		if out, ok := Compose(held, in.Sym); ok {
			return Step{Commit: s.commit(out, 0)}
		}
		return Step{Commit: s.commit(held.Literal(), in.Sym)}
	}
	return s.flushThenPass()
}

func (s *Stage) flushThenPass() Step {
	return Step{Commit: s.Flush(), Pass: true}
}

// commit returns one or two runes in the stage's own storage; a zero second
// rune means there is only one.
func (s *Stage) commit(a, b rune) []rune {
	s.buf[0], s.buf[1] = a, b
	if b == 0 {
		return s.buf[:1]
	}
	return s.buf[:2]
}

func isBackspace(in Input) bool {
	if in.Usage == usageBackspace {
		return true
	}
	return in.Usage == 0 && (in.Sym == codeBackspace || in.Sym == codeDelete)
}

// Printable reports whether r is text a surface accepts as typed input: ASCII
// graphics and any valid scalar from U+00A0. C0 and C1 controls, DEL and
// surrogates are not.
func Printable(r rune) bool {
	return r >= 0x20 && r < 0x7f || r >= 0xa0 && r <= 0x10ffff && (r < 0xd800 || r > 0xdfff)
}
