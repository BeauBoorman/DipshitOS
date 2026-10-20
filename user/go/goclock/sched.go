package main

// sched.go — M144a (#2794): the deadline multiplexer.
//
// The kernel gives each process ONE app timer (kernel/src/app_timers.zig:
// sys_timer_set arms a countdown that posts exactly one TIMER event, and
// re-arming replaces it). GOCLOCK has several things that need time —
// the world face's 1 Hz repaint, a running countdown, a daily alarm —
// so this scheduler multiplexes up to MaxDeadlines app deadlines onto
// that single kernel timer: it owns the arm decision (the earliest
// deadline wins) and the fan-out when the TIMER event lands.
//
// The type is pure — no vi, no syscalls — so ordering, cancellation and
// the bound are host-testable. Deadlines compare in wall-clock seconds
// (vi.Now's clock): the app's caller passes the current epoch.

// MaxDeadlines is the multiplexer's bound: eight entries ride the one
// kernel timer (the card's "up to 8 deadlines").
const MaxDeadlines = 8

// Deadline is one scheduled firing.
//
//	At      wall-clock Unix second the deadline becomes due.
//	Repeat  seconds between firings; 0 is one-shot. A repeater advances
//	        in Repeat steps until it clears the fire time, so a suspended
//	        run lands exactly on the next future occurrence (an alarm's
//	        86400 is "repeats daily at most" — nothing schedules tighter
//	        than its own period).
//	Quiet   internal deadline: fired silently (the world face's 1 Hz
//	        repaint), never toasted and never marked `goclock: fired`.
type Deadline struct {
	ID     string
	At     int64
	Repeat int64
	Quiet  bool

	seq int
}

// Sched is the multiplexer: a (At, seq)-sorted table of pending deadlines.
type Sched struct {
	ds   []Deadline
	seqN int
}

// Len reports the armed count.
func (s *Sched) Len() int { return len(s.ds) }

// Add inserts d in firing order. It refuses an empty or duplicate id and
// the entry past the bound — a deadline the table cannot hold must be
// refused by name, never silently dropped.
func (s *Sched) Add(d Deadline) bool {
	if d.ID == "" || len(s.ds) >= MaxDeadlines {
		return false
	}
	for _, e := range s.ds {
		if e.ID == d.ID {
			return false
		}
	}
	d.seq = s.seqN
	s.seqN++
	s.ds = append(s.ds, Deadline{})
	i := len(s.ds) - 1
	for i > 0 && less(d, s.ds[i-1]) {
		s.ds[i] = s.ds[i-1]
		i--
	}
	s.ds[i] = d
	return true
}

// Cancel disarms id, true when it was armed.
func (s *Sched) Cancel(id string) bool {
	for i, e := range s.ds {
		if e.ID == id {
			s.ds = append(s.ds[:i], s.ds[i+1:]...)
			return true
		}
	}
	return false
}

// Armed reports whether id is scheduled.
func (s *Sched) Armed(id string) bool {
	for _, e := range s.ds {
		if e.ID == id {
			return true
		}
	}
	return false
}

// ArmDelay is the arm decision handed to sys_timer_set: whole ticks (one
// tick is one second on VZ) until the earliest pending deadline. Zero
// means nothing is armed — the caller disarms. A deadline already past
// due still arms at 1: a 0-tick arm is a refusal the kernel documents,
// so the fire waits one honest tick.
func (s *Sched) ArmDelay(now int64) int64 {
	if len(s.ds) == 0 {
		return 0
	}
	if d := s.ds[0].At - now; d > 1 {
		return d
	}
	return 1
}

// Fire returns every deadline due at now in firing order and re-arms
// repeaters (each keeps its insertion seq, so a tie after rescheduling
// still fires in the order the user armed them). The caller prints and
// toasts in the returned order.
func (s *Sched) Fire(now int64) []Deadline {
	var fired, again []Deadline
	keep := s.ds[:0]
	for _, d := range s.ds {
		if d.At <= now {
			fired = append(fired, d)
			if d.Repeat > 0 {
				for d.At <= now {
					d.At += d.Repeat
				}
				again = append(again, d)
			}
			continue
		}
		keep = append(keep, d)
	}
	s.ds = keep
	for _, d := range again {
		s.insert(d)
	}
	return fired
}

// insert places d at its (At, seq) slot — the same order Add keeps.
func (s *Sched) insert(d Deadline) {
	s.ds = append(s.ds, Deadline{})
	i := len(s.ds) - 1
	for i > 0 && less(d, s.ds[i-1]) {
		s.ds[i] = s.ds[i-1]
		i--
	}
	s.ds[i] = d
}

// less is the firing order: earlier At first, insertion order on a tie.
func less(a, b Deadline) bool {
	if a.At != b.At {
		return a.At < b.At
	}
	return a.seq < b.seq
}
