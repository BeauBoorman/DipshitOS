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

// timerPresets is the preset row (M152b, #2916): one digit key picks an
// index and arms that many seconds immediately — 1, 3, 5, 10 or 25
// minutes. The custom-seconds entry survives behind 'e'.
var timerPresets = [5]int64{60, 180, 300, 600, 1500}

var timerPresetLabels = [5]string{"1m", "3m", "5m", "10m", "25m"}

// --- alarm -------------------------------------------------------------------

// alarmAt computes the next epoch at which the civil time in zone z reads
// h:m — today's occurrence when it is still ahead, tomorrow's otherwise.
// The zone's own civil day bounds the math, so a UTC+05:30 alarm lands on
// the user's 07:30, not UTC's; under a named zone the solve runs against
// the instant-dependent offset (M178c), so a 07:30 alarm set the night
// before a DST switch still rings at civil 07:30.
func alarmAt(now int64, z clockfmt.Zone, h, m int) int64 {
	c := clockfmt.At(now, z)
	target := int64(h)*3600 + int64(m)*60
	// The local wall clock at now is epoch + the offset now in force;
	// today's wall midnight plus the h:m target is the candidate wall.
	wallMidnight := now + clockfmt.Offset(now, z) -
		int64(c.Hour*3600+c.Minute*60+c.Second)
	t := localEpoch(wallMidnight+target, now, z)
	if t <= now {
		t = localEpoch(wallMidnight+86400+target, now, z)
	}
	return t
}

// localEpoch solves e + Offset(e, z) = wall for e: the wall reading is the
// user-facing civil time, the offset is what the zone charges at the
// answer. A fixed offset converges in one pass and lands exactly where the
// old dayStart arithmetic did; a named zone can step once mid-day (the
// twice-a-year transition), so the guess refines a few times. A wall time
// the transition skips or repeats pins to the transition's edge — an alarm
// set inside the spring gap fires at the jump, which is the honest answer.
func localEpoch(wall, guess int64, z clockfmt.Zone) int64 {
	e := wall - clockfmt.Offset(guess, z)
	for i := 0; i < 3; i++ {
		e = wall - clockfmt.Offset(e, z)
	}
	return e
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

// --- alarms ------------------------------------------------------------------
//
// M152b (#2916): the tab is a list, not a single daily slot — up to
// MaxAlarms entries, each once or daily, each armed or switched off. The
// cap leaves the multiplexer's remaining slot for the countdown timer
// (face + timer + seven alarms = MaxDeadlines).
const MaxAlarms = 7

// dailyRepeat is the re-arm floor for a daily alarm: 86400 keeps a fire
// from ever ringing twice inside one day.
const dailyRepeat = 86400

// Alarm is one row of the Alarm tab.
//
//	At       wall-clock epoch of the next occurrence (the armed instant).
//	HHMM     the civil field the user typed — the face and the markers
//	         speak it.
//	Daily    re-arms every 86400 s; false is one-shot.
//	Enabled  false keeps the row but drops the deadline (the toggle).
type Alarm struct {
	At      int64
	HHMM    int
	Daily   bool
	Enabled bool
}

// alarmIndex parses the deadline id of list row i ("alarm<i>") back into
// i — false for any other id (the timer's, the face's).
func alarmIndex(id string) (int, bool) {
	if len(id) <= 5 || id[:5] != "alarm" {
		return 0, false
	}
	n := 0
	for i := 5; i < len(id); i++ {
		if id[i] < '0' || id[i] > '9' {
			return 0, false
		}
		n = n*10 + int(id[i]-'0')
	}
	return n, true
}

// --- persisted alarms --------------------------------------------------------
//
// M144b (#2795) persisted the ONE armed daily alarm as `gocal1 <at>
// <hhmm>` on both carriers — the app's crash-safe share file and the
// seat's save_state blob. M152b (#2916) extends the record to the whole
// list: `gocal2 <n>` followed by n triples of `<at> <hhmm> <flags>`,
// where flags is `d` (daily) or `o` (once) plus `+` (enabled) or `-`
// (switched off):
//
//	gocal2 2 1792502700 0645 d+ 1792522800 1920 o-
//
// `at` is the armed instant as a wall-clock epoch so a start after the
// deadline can tell "still ahead" from "came due while we were off";
// `hhmm` is the civil field the user typed. A `gocal1` record still
// reads — it decodes as the single daily enabled alarm it always was.

// alarmMagic versions the record: a blob or file whose framing does not
// match is refused whole, never guessed at.
const alarmMagic = "gocal1 "

const alarmListMagic = "gocal2 "

// hhmmString renders h:m as the typed four-digit field.
func hhmmString(h, m int) string {
	return two(int64(h)) + two(int64(m))
}

// encodeAlarms renders the gocal2 list. A list past MaxAlarms is refused
// — the bound is the contract, never truncated silently.
func encodeAlarms(list []Alarm) []byte {
	if len(list) > MaxAlarms {
		return nil
	}
	s := alarmListMagic + itoa(int64(len(list)))
	for _, al := range list {
		h, m, ok := parseHHMM(al.HHMM)
		if !ok || al.At < 0 {
			return nil
		}
		f := "o"
		if al.Daily {
			f = "d"
		}
		if al.Enabled {
			f += "+"
		} else {
			f += "-"
		}
		s += " " + itoa(al.At) + " " + hhmmString(h, m) + " " + f
	}
	return []byte(s)
}

// decodeAlarms reads either framing: the gocal2 list, or the gocal1
// single-record it supersedes (which decodes as one daily enabled
// alarm). Anything else refuses whole — torn writes and foreign blobs
// are "no state", never a guess.
func decodeAlarms(b []byte) ([]Alarm, bool) {
	s := string(b)
	if len(b) > 0 && b[len(b)-1] == '\n' {
		s = s[:len(s)-1]
	}
	if len(s) > len(alarmListMagic) && s[:len(alarmListMagic)] == alarmListMagic {
		return decodeGocal2(s[len(alarmListMagic):])
	}
	if at, hhmm, ok := decodeAlarm([]byte(s)); ok {
		return []Alarm{{At: at, HHMM: hhmm, Daily: true, Enabled: true}}, true
	}
	return nil, false
}

// decodeGocal2 parses `<n> <at> <hhmm> <flags>…`: n decimal triples,
// each a non-negative epoch, a valid HHMM field and the two-letter
// flag pair. A count that does not match the token count — or n past
// MaxAlarms — is a foreign record and refuses.
func decodeGocal2(rest string) ([]Alarm, bool) {
	var toks []string
	start := 0
	for i := 0; i <= len(rest); i++ {
		if i == len(rest) || rest[i] == ' ' {
			toks = append(toks, rest[start:i])
			start = i + 1
		}
	}
	n, ok := atoiField(toks[0])
	if !ok || n > int64(MaxAlarms) || len(toks) != 1+3*int(n) {
		return nil, false
	}
	list := make([]Alarm, 0, n)
	for i := 0; i < int(n); i++ {
		at, ok1 := atoiField(toks[1+3*i])
		hhmm, ok2 := atoiField(toks[2+3*i])
		f := toks[3+3*i]
		if !ok1 || !ok2 || len(f) != 2 {
			return nil, false
		}
		if _, _, ok3 := parseHHMM(int(hhmm)); !ok3 {
			return nil, false
		}
		var al Alarm
		switch f[0] {
		case 'd':
			al.Daily = true
		case 'o':
		default:
			return nil, false
		}
		switch f[1] {
		case '+':
			al.Enabled = true
		case '-':
		default:
			return nil, false
		}
		al.At, al.HHMM = at, int(hhmm)
		list = append(list, al)
	}
	return list, true
}

// atoiField is the strict unsigned-decimal parse the records want:
// non-empty, all digits, no sign.
func atoiField(s string) (int64, bool) {
	if len(s) == 0 {
		return 0, false
	}
	var v int64
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		v = v*10 + int64(s[i]-'0')
	}
	return v, true
}

// decodeAlarm is the total inverse of the gocal1 record: anything that
// is not exactly `gocal1 <digits> <HHMM>` refuses (ok=false) rather than
// trusting a torn or foreign record.
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
