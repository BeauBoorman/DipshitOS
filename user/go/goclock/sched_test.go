package main

// sched_test.go — the class-A half of M144a (#2794): the deadline
// multiplexer's ordering, cancellation and 8-entry bound, plus the
// repeater arithmetic an alarm rides on. All pure: deadlines are compared
// in wall-clock seconds the test supplies.
import "testing"

func ids(fired []Deadline) []string {
	out := make([]string, len(fired))
	for i, d := range fired {
		out[i] = d.ID
	}
	return out
}

func eqIDs(got []string, want ...string) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range want {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}

// Out-of-order inserts fire in deadline order; a tie keeps arm order.
func TestSchedFireOrdering(t *testing.T) {
	var s Sched
	for _, d := range []Deadline{
		{ID: "c", At: 30},
		{ID: "a", At: 10},
		{ID: "b", At: 20},
		{ID: "tie1", At: 40},
		{ID: "tie2", At: 40},
	} {
		if !s.Add(d) {
			t.Fatalf("Add(%s) refused", d.ID)
		}
	}
	if got := ids(s.Fire(25)); !eqIDs(got, "a", "b") {
		t.Fatalf("Fire(25) = %v, want [a b]", got)
	}
	if got := ids(s.Fire(100)); !eqIDs(got, "c", "tie1", "tie2") {
		t.Fatalf("Fire(100) = %v, want [c tie1 tie2] (ties in arm order)", got)
	}
	if s.Len() != 0 {
		t.Fatalf("Len = %d, want 0 after everything fired", s.Len())
	}
}

// One deadline due while others wait fires alone, in order.
func TestSchedPartialFire(t *testing.T) {
	var s Sched
	s.Add(Deadline{ID: "now", At: 5})
	s.Add(Deadline{ID: "later", At: 50})
	if got := ids(s.Fire(5)); !eqIDs(got, "now") {
		t.Fatalf("Fire = %v, want [now]", got)
	}
	if !s.Armed("later") || s.Armed("now") {
		t.Fatalf("armed set wrong after partial fire")
	}
}

// Cancel removes an armed deadline and reports it; the surviving entries
// still fire.
func TestSchedCancel(t *testing.T) {
	var s Sched
	s.Add(Deadline{ID: "timer", At: 10})
	s.Add(Deadline{ID: "alarm", At: 20})
	if !s.Cancel("timer") {
		t.Fatal("Cancel(timer) = false, want true")
	}
	if s.Cancel("timer") || s.Cancel("ghost") {
		t.Fatal("Cancel of a missing id must report false")
	}
	if got := ids(s.Fire(100)); !eqIDs(got, "alarm") {
		t.Fatalf("Fire after cancel = %v, want [alarm]", got)
	}
}

// The bound is the contract: the ninth deadline is refused, never
// silently dropped, and a duplicate id is refused the same way.
func TestSchedBound(t *testing.T) {
	var s Sched
	for i := 0; i < MaxDeadlines; i++ {
		d := Deadline{ID: string(rune('a'+i)) + "x", At: int64(i)}
		if !s.Add(d) {
			t.Fatalf("Add #%d refused under the bound", i)
		}
	}
	if s.Len() != MaxDeadlines {
		t.Fatalf("Len = %d, want %d", s.Len(), MaxDeadlines)
	}
	if s.Add(Deadline{ID: "ninth", At: 0}) {
		t.Fatal("the 9th deadline must be refused")
	}
	if s.Add(Deadline{ID: "axx", At: 0}) {
		t.Fatal("a duplicate id must be refused")
	}
	if s.Add(Deadline{ID: "", At: 0}) {
		t.Fatal("an empty id must be refused")
	}
	if s.Len() != MaxDeadlines {
		t.Fatalf("Len = %d after refusals, want %d", s.Len(), MaxDeadlines)
	}
	// A cancel frees a slot a new deadline can take.
	s.Cancel("ax")
	if !s.Add(Deadline{ID: "ninth", At: 0}) {
		t.Fatal("Add after cancel should succeed — a slot freed")
	}
}

// M152b (#2916): the card's full house — the face cadence, the countdown
// and MaxAlarms daily rows all fit; the deadline past that is refused.
func TestSchedSevenAlarmsPlusTimer(t *testing.T) {
	var s Sched
	s.Add(Deadline{ID: faceDeadline, At: 1, Repeat: 1, Quiet: true})
	s.Add(Deadline{ID: "timer", At: 60})
	for i := 0; i < MaxAlarms; i++ {
		if !s.Add(Deadline{ID: alarmID(i), At: 100, Repeat: dailyRepeat}) {
			t.Fatalf("alarm #%d refused under the bound", i)
		}
	}
	if s.Len() != MaxDeadlines {
		t.Fatalf("Len = %d, want %d (face + timer + %d alarms)",
			s.Len(), MaxDeadlines, MaxAlarms)
	}
	if s.Add(Deadline{ID: "overflow", At: 0}) {
		t.Fatal("the deadline past face + timer + seven alarms must be refused")
	}
	// And the daily re-arm floor: after a fire each row lands exactly one
	// day out, never sooner.
	fired := s.Fire(100) // face + timer + all seven alarms are due
	if len(fired) != MaxAlarms+2 {
		t.Fatalf("Fire(100) fired %d, want %d", len(fired), MaxAlarms+2)
	}
	for _, d := range s.ds {
		if i, ok := alarmIndex(d.ID); ok {
			if d.At != 100+dailyRepeat {
				t.Fatalf("alarm%d re-armed at %d, want %d", i, d.At, 100+dailyRepeat)
			}
		} else if d.ID == "timer" {
			t.Fatal("the one-shot timer must not re-arm")
		}
	}
}

// ArmDelay answers for the earliest deadline only.
func TestSchedArmDelay(t *testing.T) {
	var s Sched
	if d := s.ArmDelay(0); d != 0 {
		t.Fatalf("ArmDelay empty = %d, want 0", d)
	}
	s.Add(Deadline{ID: "far", At: 100})
	s.Add(Deadline{ID: "near", At: 12})
	if d := s.ArmDelay(10); d != 2 {
		t.Fatalf("ArmDelay = %d, want 2 (earliest wins)", d)
	}
	// Past-due still arms at 1 — a 0 arm is the kernel's documented refusal,
	// so the fire lands one honest tick out.
	if d := s.ArmDelay(50); d != 1 {
		t.Fatalf("ArmDelay past-due = %d, want 1", d)
	}
}

// A repeater reschedules in whole periods until it clears the fire time —
// an alarm's daily cadence — and keeps its slot in firing order.
func TestSchedRepeat(t *testing.T) {
	var s Sched
	s.Add(Deadline{ID: "alarm", At: 10, Repeat: 86400})
	s.Add(Deadline{ID: "timer", At: 30})
	fired := s.Fire(10)
	if !eqIDs(ids(fired), "alarm") {
		t.Fatalf("Fire = %v, want [alarm]", ids(fired))
	}
	if !s.Armed("alarm") {
		t.Fatal("repeater must stay armed")
	}
	// Fired at 90000 (20s past the second occurrence): it advances to
	// 10+2*86400 = 172810, still after the one-off timer.
	fired = s.Fire(90000)
	if !eqIDs(ids(fired), "timer", "alarm") {
		t.Fatalf("Fire(90000) = %v, want [timer alarm] — the repeater re-armed at 86530 already passed", ids(fired))
	}
	for _, d := range s.ds {
		if d.ID == "alarm" && d.At != 172810 {
			t.Fatalf("alarm re-armed at %d, want 172810", d.At)
		}
	}
}

// The face cadence is a deadline like any other: quiet, one-second repeat.
func TestSchedFaceCadence(t *testing.T) {
	var s Sched
	s.Add(Deadline{ID: faceDeadline, At: 11, Repeat: 1, Quiet: true})
	for tick := int64(11); tick < 15; tick++ {
		fired := s.Fire(tick)
		if !eqIDs(ids(fired), faceDeadline) {
			t.Fatalf("tick %d fired %v, want [face]", tick, ids(fired))
		}
		if d := s.ArmDelay(tick); d != 1 {
			t.Fatalf("ArmDelay after tick %d = %d, want 1", tick, d)
		}
	}
}
