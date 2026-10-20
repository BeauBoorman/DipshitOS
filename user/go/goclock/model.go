package main

// model.go — M144a (#2794): the pure halves of the four tabs.
//
// Everything time-shaped the app decides is computed here against an
// injected clock so the host test drive is deterministic: the stopwatch
// counts monotonic nanoseconds (vsys.Nanotime's EL0 counter — a wall
// step must never move a measurement), while countdown and alarm
// deadlines are wall-clock seconds (vi.Now's epoch) because they name
// civil times the user can see.
import (
	"virelai/clockfmt"
)

// --- world -----------------------------------------------------------------

// worldZones returns the World tab's row list: the settings zone first,
// then clockfmt's curated fixed offsets. A fixed offset equal to the
// settings zone is dropped — two rows spelling the same zone tell the
// user nothing.
func worldZones(local clockfmt.Zone) []clockfmt.Zone {
	zones := make([]clockfmt.Zone, 0, len(clockfmt.Offsets)+1)
	zones = append(zones, local)
	for _, z := range clockfmt.Offsets {
		if z != local {
			zones = append(zones, z)
		}
	}
	return zones
}

// worldRow renders one World row: the shared formatter's
// "YYYY-MM-DD HH:MM:SS UTC±HH:MM" — the whole row IS the clockfmt string
// so the gate's host-computed expectation needs no second convention.
func worldRow(epoch int64, z clockfmt.Zone) string {
	return clockfmt.Format(epoch, z)
}

// --- stopwatch ---------------------------------------------------------------

// Stopwatch is a pause-able monotonic elapsed counter. acc banks the
// nanoseconds measured while paused; since is the last start stamp.
type Stopwatch struct {
	running bool
	acc     int64
	since   int64
}

// Running reports whether the watch is counting.
func (s *Stopwatch) Running() bool { return s.running }

// Elapsed returns nanoseconds measured as of now.
func (s *Stopwatch) Elapsed(now int64) int64 {
	if s.running {
		return s.acc + now - s.since
	}
	return s.acc
}

// Toggle starts a stopped watch or stops a running one at now.
func (s *Stopwatch) Toggle(now int64) {
	if s.running {
		s.acc += now - s.since
	} else {
		s.since = now
	}
	s.running = !s.running
}

// Reset stops the watch and zeroes the bank.
func (s *Stopwatch) Reset() {
	s.running = false
	s.acc = 0
	s.since = 0
}

// FormatElapsed renders nanos as H:MM:SS — sub-second precision is a
// fiction on a 1 Hz repaint, so the face drops it honestly.
func FormatElapsed(ns int64) string {
	if ns < 0 {
		ns = 0
	}
	s := ns / 1_000_000_000
	return itoa(s/3600) + ":" + two((s/60)%60) + ":" + two(s%60)
}

// itoa is the model's own non-negative integer render (the package stays
// free of vi for host tests).
func itoa(v int64) string {
	if v == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for v > 0 {
		i--
		b[i] = byte('0' + v%10)
		v /= 10
	}
	return string(b[i:])
}

// two renders v (0..99) zero-padded to two digits.
func two(v int64) string {
	return string([]byte{byte('0' + v/10%10), byte('0' + v%10)})
}

// --- digit entry -----------------------------------------------------------

// DigitEntry accumulates the bounded decimal field the timer and alarm
// tabs type into: digits append at the right, backspace drops one, the
// cap refuses silently-overflowing input rather than wrapping it.
type DigitEntry struct {
	digits []byte
	max    int
}

// NewDigitEntry bounds the field at max digits.
func NewDigitEntry(max int) DigitEntry {
	return DigitEntry{max: max}
}

// Digit appends d (0..9); false when the field is full or d is not a digit.
func (e *DigitEntry) Digit(d int) bool {
	if d < 0 || d > 9 || len(e.digits) >= e.max {
		return false
	}
	e.digits = append(e.digits, byte('0'+d))
	return true
}

// Backspace drops the last digit; false on an empty field.
func (e *DigitEntry) Backspace() bool {
	if len(e.digits) == 0 {
		return false
	}
	e.digits = e.digits[:len(e.digits)-1]
	return true
}

// Clear empties the field.
func (e *DigitEntry) Clear() { e.digits = e.digits[:0] }

// Empty reports whether nothing is typed.
func (e *DigitEntry) Empty() bool { return len(e.digits) == 0 }

// Value is the accumulated number.
func (e *DigitEntry) Value() int {
	v := 0
	for _, b := range e.digits {
		v = v*10 + int(b-'0')
	}
	return v
}

// String is the raw typed digits.
func (e *DigitEntry) String() string { return string(e.digits) }

// --- countdown timer -----------------------------------------------------------

// maxTimerSeconds bounds a countdown: five digits of seconds, a little
// over a day — the entry cap is the bound, so this is documentation of
// what the field holds rather than a second check.
const timerEntryDigits = 5

// --- alarm -------------------------------------------------------------------

// alarmAt computes the next epoch at which the civil time in zone z reads
// h:m — today's occurrence when it is still ahead, tomorrow's otherwise.
// The zone's own civil day bounds the math, so a UTC+05:30 alarm lands on
// the user's 07:30, not UTC's.
func alarmAt(now int64, z clockfmt.Zone, h, m int) int64 {
	c := clockfmt.At(now, z)
	dayStart := now - int64(c.Hour*3600+c.Minute*60+c.Second)
	t := dayStart + int64(h)*3600 + int64(m)*60
	if t <= now {
		t += 86400
	}
	return t
}

// parseHHMM validates a four-digit HHMM field and splits it.
func parseHHMM(v int) (h, m int, ok bool) {
	if v < 0 || v > 9999 {
		return 0, 0, false
	}
	h, m = v/100, v%100
	if h > 23 || m > 59 {
		return 0, 0, false
	}
	return h, m, true
}

// --- persisted alarm ---------------------------------------------------------
//
// M144b (#2795): the armed daily alarm survives the app. ONE record —
// `gocal1 <at> <hhmm>` — rides both carriers: the app's own share file
// (crash-safe through vi.WriteFileSafe) and the seat's save_state blob.
// `at` is the armed instant as a wall-clock epoch so a start after the
// deadline can tell "still ahead" from "came due while we were off";
// `hhmm` is the civil field the user typed — the marker and the face
// speak it.

// alarmMagic versions the record: a blob or file whose framing does not
// match is refused whole, never guessed at.
const alarmMagic = "gocal1 "

// hhmmString renders h:m as the typed four-digit field.
func hhmmString(h, m int) string {
	return two(int64(h)) + two(int64(m))
}

// encodeAlarm renders the persisted record.
func encodeAlarm(at int64, hhmm int) []byte {
	h, m, ok := parseHHMM(hhmm)
	if !ok || at < 0 {
		return nil
	}
	return []byte(alarmMagic + itoa(at) + " " + hhmmString(h, m))
}

// decodeAlarm is the total inverse: anything that is not exactly
// `gocal1 <digits> <HHMM>` refuses (ok=false) rather than trusting a
// torn or foreign record.
func decodeAlarm(b []byte) (at int64, hhmm int, ok bool) {
	s := string(b)
	if len(b) > 0 && b[len(b)-1] == '\n' {
		s = s[:len(s)-1]
	}
	if len(s) <= len(alarmMagic) || s[:len(alarmMagic)] != alarmMagic {
		return 0, 0, false
	}
	rest := s[len(alarmMagic):]
	sp := -1
	for i := 0; i < len(rest); i++ {
		if rest[i] == ' ' {
			sp = i
			break
		}
	}
	if sp <= 0 || sp+5 != len(rest) {
		return 0, 0, false
	}
	atStr, hmStr := rest[:sp], rest[sp+1:]
	for i := 0; i < len(atStr); i++ {
		if atStr[i] < '0' || atStr[i] > '9' {
			return 0, 0, false
		}
	}
	for i := 0; i < len(atStr); i++ {
		at = at*10 + int64(atStr[i]-'0')
	}
	v := 0
	for i := 0; i < 4; i++ {
		if hmStr[i] < '0' || hmStr[i] > '9' {
			return 0, 0, false
		}
		v = v*10 + int(hmStr[i]-'0')
	}
	if _, _, ok = parseHHMM(v); !ok {
		return 0, 0, false
	}
	return at, v, true
}
