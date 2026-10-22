package main

import (
	"strings"
	"testing"

	"virelai/hostint"
)

// hostnotify_test.go — M108d (#2328, ADR 0051 D5): the notify-out lane's
// seat half. The hostintFixture drives the real engine against an in-memory
// lane directory; resetNotify stubs the strip's file/sound seams. The
// runner-side drain is simulated by deleting NOTIFY-* files.

// newNotifyFixture layers the notify strip's inert state onto the lane
// fixture: DND off, sound seams inert, pending queue empty.
func newNotifyFixture(t *testing.T, key string) *hostintFixture {
	resetNotify(t)
	f := newHostintFixture(t, key)
	prevPlay := notifyPlayChime
	prevPending := hostNotifyPending
	notifyPlayChime = func() {}
	hostNotifyPending = nil
	t.Cleanup(func() {
		notifyPlayChime = prevPlay
		hostNotifyPending = prevPending
	})
	return f
}

// notifySeqs returns the seqs of the NOTIFY-* records in the lane dir, in
// filename order (STEM-%08x sorts by seq).
func (f *hostintFixture) notifyRecords() []hostint.Record {
	var names []string
	for name := range f.files {
		if strings.HasPrefix(name, "NOTIFY-") {
			names = append(names, name)
		}
	}
	for i := 1; i < len(names); i++ {
		for j := i; j > 0 && names[j] < names[j-1]; j-- {
			names[j], names[j-1] = names[j-1], names[j]
		}
	}
	var out []hostint.Record
	for _, name := range names {
		if rec, ok := hostint.DecodeRecord(f.files[name]); ok {
			out = append(out, rec)
		}
	}
	return out
}

// drainNotify simulates the runner's consume: delete every NOTIFY-* file.
func (f *hostintFixture) drainNotify() {
	for name := range f.files {
		if strings.HasPrefix(name, "NOTIFY-") {
			delete(f.files, name)
		}
	}
}

func TestHostNotifyEmitsOnToast(t *testing.T) {
	f := newNotifyFixture(t, strings.Repeat("c8", 32))
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneNotify)
	hostintSeatTick()

	if _, ok, _ := notifyPush(4, "build done", seatTick); !ok {
		t.Fatal("toast refused")
	}
	if len(hostNotifyPending) != 1 {
		t.Fatalf("pending = %v", hostNotifyPending)
	}
	hostintSeatTick()
	recs := f.notifyRecords()
	if len(recs) != 1 {
		t.Fatalf("records = %d", len(recs))
	}
	rec := recs[0]
	if rec.Tag != hostint.TagNotifyOut || rec.Seq != 1 || rec.Epoch != 7 {
		t.Fatalf("record = %+v", rec)
	}
	if !rec.Verify(f.key) {
		t.Fatal("record does not verify under the lane key")
	}
	// M127c (V2-D3): the record carries the toast's sender tab id — the
	// correlation a banner click echoes back as NOTIFY_FOCUS.
	if rec.Sender != 4 {
		t.Fatalf("sender = %d, want 4", rec.Sender)
	}
	if string(rec.Payload) != "build done" {
		t.Fatalf("payload = %q", rec.Payload)
	}
	if !f.hasLog(MarkerHostintNotifyOut + "seq=1 len=10") {
		t.Fatalf("missing emit marker: %v", f.logs)
	}
}

func TestHostNotifyOneRecordPerTick(t *testing.T) {
	f := newNotifyFixture(t, strings.Repeat("c8", 32))
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneNotify)
	hostintSeatTick()

	for _, text := range []string{"a", "b", "c"} {
		notifyPush(4, text, seatTick)
	}
	// One tick emits only the oldest; the rest drain one per tick.
	hostintSeatTick()
	if recs := f.notifyRecords(); len(recs) != 1 || string(recs[0].Payload) != "a" {
		t.Fatalf("after tick 1: %d records", len(recs))
	}
	f.drainNotify()
	hostintSeatTick()
	if recs := f.notifyRecords(); len(recs) != 1 || string(recs[0].Payload) != "b" || recs[0].Seq != 2 {
		t.Fatalf("after tick 2: %+v", f.notifyRecords())
	}
	f.drainNotify()
	hostintSeatTick()
	if recs := f.notifyRecords(); len(recs) != 1 || string(recs[0].Payload) != "c" || recs[0].Seq != 3 {
		t.Fatalf("after tick 3: %+v", f.notifyRecords())
	}
	if len(hostNotifyPending) != 0 {
		t.Fatalf("pending tail = %v", hostNotifyPending)
	}
}

func TestHostNotifyBackpressuredHolds(t *testing.T) {
	f := newNotifyFixture(t, strings.Repeat("c8", 32))
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneNotify)
	hostintSeatTick()

	// Fill the runner-visible window: four emitted, none consumed.
	for i, text := range []string{"w", "x", "y", "z"} {
		notifyPush(4, text, seatTick)
		hostintSeatTick()
		if n := len(f.notifyRecords()); n != i+1 {
			t.Fatalf("tick %d: %d records", i, n)
		}
	}
	// A fifth toast stages but cannot emit while four are outstanding.
	notifyPush(4, "late", seatTick)
	hostintSeatTick()
	if n := len(f.notifyRecords()); n != hostint.MaxOutstanding {
		t.Fatalf("emitted past the bound: %d", n)
	}
	if len(hostNotifyPending) != 1 {
		t.Fatalf("backpressured entry lost: %v", hostNotifyPending)
	}
	// The runner drains; the held record emits next tick with the next seq.
	f.drainNotify()
	hostintSeatTick()
	recs := f.notifyRecords()
	if len(recs) != 1 || recs[0].Seq != 5 || string(recs[0].Payload) != "late" {
		t.Fatalf("resumed emit: %+v", recs)
	}
}

func TestHostNotifyOverflowDropsOldest(t *testing.T) {
	f := newNotifyFixture(t, strings.Repeat("c8", 32))
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneNotify)
	hostintSeatTick()

	// Five pushes before any tick: the lane's staging drops the oldest
	// through the strip's own drop accounting (the strip itself also
	// evicts — both surfaces share the counter and the marker).
	for _, text := range []string{"t1", "t2", "t3", "t4", "t5"} {
		notifyPush(4, text, seatTick)
	}
	if len(hostNotifyPending) != hostint.MaxOutstanding {
		t.Fatalf("pending = %v", hostNotifyPending)
	}
	if hostNotifyPending[0].text != "t2" {
		t.Fatalf("oldest staged = %q, want t2", hostNotifyPending[0].text)
	}
	if notifyDropped == 0 || !f.hasLog(MarkerNotifyDrop) {
		t.Fatalf("missing drop accounting: %v", f.logs)
	}
	// The survivors emit in order; t1 never crosses.
	for want, text := range []string{"t2", "t3", "t4", "t5"} {
		f.drainNotify()
		hostintSeatTick()
		recs := f.notifyRecords()
		if len(recs) != 1 || string(recs[0].Payload) != text || recs[0].Seq != uint32(want+1) {
			t.Fatalf("emit %d: %+v", want+1, recs)
		}
	}
}

func TestHostNotifyLaneMaskGate(t *testing.T) {
	f := newNotifyFixture(t, strings.Repeat("c8", 32))
	hostintSeatInit()
	// ARMED names only the clip lane — the consent posture has no notify bit.
	f.plantArmed(7, hostint.LaneClip)
	hostintSeatTick()

	notifyPush(4, "quiet", seatTick)
	if len(hostNotifyPending) != 0 {
		t.Fatalf("staged without consent: %v", hostNotifyPending)
	}
	hostintSeatTick()
	if n := len(f.notifyRecords()); n != 0 {
		t.Fatalf("emitted %d records with the lane off", n)
	}
	if f.hasLog(MarkerHostintNotifyOut) {
		t.Fatalf("emit marker without consent: %v", f.logs)
	}
}

func TestHostNotifyBeforeArmed(t *testing.T) {
	f := newNotifyFixture(t, strings.Repeat("c8", 32))
	hostintSeatInit()
	// The credential exists but no ARMED has verified: toasts stay local.
	notifyPush(4, "early", seatTick)
	hostintSeatTick()
	if len(hostNotifyPending) != 0 || len(f.notifyRecords()) != 0 {
		t.Fatalf("pre-adoption traffic: %v %v", hostNotifyPending, f.notifyRecords())
	}
}

func TestHostNotifyDNDNeverCrosses(t *testing.T) {
	f := newNotifyFixture(t, strings.Repeat("c8", 32))
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneNotify)
	hostintSeatTick()

	notifyDND = true
	if _, ok, _ := notifyPush(4, "held", seatTick); !ok {
		t.Fatal("DND notice refused")
	}
	if len(hostNotifyPending) != 0 {
		t.Fatalf("DND notice staged for the host: %v", hostNotifyPending)
	}
	hostintSeatTick()
	if len(f.notifyRecords()) != 0 {
		t.Fatal("DND notice emitted")
	}
}

func TestHostNotifyRevokedMaskClearsStaging(t *testing.T) {
	f := newNotifyFixture(t, strings.Repeat("c8", 32))
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneNotify)
	hostintSeatTick()
	notifyPush(4, "pending", seatTick)

	// A re-ARMED in the same epoch drops the notify bit — the consent that
	// staged the entry is revoked.
	f.files["ARMED-00000002"] = hostint.EncodeRecord(
		f.key, hostint.TagArmed, 0, 2, 7, []byte{hostint.LaneClip})
	hostintSeatTick()
	if len(hostNotifyPending) != 0 {
		t.Fatalf("staging survived mask revocation: %v", hostNotifyPending)
	}
	if len(f.notifyRecords()) != 0 {
		t.Fatal("emitted after revocation")
	}
	if !f.hasLog("lane=notify reason=" + hostint.RefuseLaneDisabled) {
		t.Fatalf("missing lane_disabled refusal: %v", f.logs)
	}
}

func TestHostNotifyTooLargeDropsEntryKeepsQueue(t *testing.T) {
	// A staged toast over the wire's 512-byte payload bound draws
	// payload_too_large — a defect of THAT entry, not a lane posture:
	// the poll drops the head alone and the queue behind it survives.
	f := newNotifyFixture(t, strings.Repeat("c8", 32))
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneNotify)
	hostintSeatTick()

	hostnotifyQueue(strings.Repeat("x", hostint.PayloadMax+1))
	notifyPush(4, "after", seatTick)
	if len(hostNotifyPending) != 2 {
		t.Fatalf("pending = %v", hostNotifyPending)
	}
	hostintSeatTick()
	if len(hostNotifyPending) != 1 || hostNotifyPending[0].text != "after" {
		t.Fatalf("queue tail lost with the head: %v", hostNotifyPending)
	}
	if !f.hasLog("lane=notify reason=" + hostint.RefuseTooLarge) {
		t.Fatalf("missing payload_too_large refusal: %v", f.logs)
	}
	// The survivor emits on the next tick, first seq — the refused entry
	// never consumed one.
	hostintSeatTick()
	recs := f.notifyRecords()
	if len(recs) != 1 || recs[0].Seq != 1 || string(recs[0].Payload) != "after" {
		t.Fatalf("survivor emit: %+v", recs)
	}
}

func TestHostNotifySeatToastSendsSenderZero(t *testing.T) {
	// V2-D3: a seat-originated toast (tab id 0 — a host drop, an agent
	// milestone, an action toast) crosses with sender 0. A click on its
	// banner raises the runner's window and emits no record.
	f := newNotifyFixture(t, strings.Repeat("c8", 32))
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneNotify)
	hostintSeatTick()

	if _, ok, _ := notifyPush(0, "seat notice", seatTick); !ok {
		t.Fatal("seat toast refused")
	}
	hostintSeatTick()
	recs := f.notifyRecords()
	if len(recs) != 1 || recs[0].Sender != 0 {
		t.Fatalf("records = %+v, want one sender-0 record", recs)
	}
}
