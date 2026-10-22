package main

import (
	"strings"
	"testing"

	"virelai/hostint"
)

// plantDrop stages a valid runner DROP record: payload [name_len u8]
// [name][size u64le], signed under the fixture key.
func (f *hostintFixture) plantDrop(epoch, seq uint32, name string, size uint64) {
	p := make([]byte, 0, 1+len(name)+8)
	p = append(p, byte(len(name)))
	p = append(p, name...)
	for i := 0; i < 8; i++ {
		p = append(p, byte(size>>(8*i)))
	}
	f.files[hostint.RecordName(hostint.TagDrop, seq)] =
		hostint.EncodeRecord(f.key, hostint.TagDrop, 0, seq, epoch, p)
}

func TestHostdropConsumeToasts(t *testing.T) {
	resetNotify(t)
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	f.plantArmed(0xBEEF, hostint.LaneDrop)
	hostintSeatTick()
	if !f.hasLog(hostintMarkerPrefix + " armed epoch=48879 lanes=drop") {
		t.Fatalf("missing armed marker: %v", f.logs)
	}

	f.plantDrop(0xBEEF, 1, "PHOTO.QOI", 4100)
	hostintSeatTick()
	if !f.hasLog(MarkerHostintDrop + "seq=1 name=PHOTO.QOI size=4100") {
		t.Fatalf("missing drop marker: %v", f.logs)
	}
	if !f.hasLog("gotabwm: notify id=0 host drop: PHOTO.QOI") {
		t.Fatalf("missing notify marker: %v", f.logs)
	}
	if len(notifyQueue) != 1 || notifyQueue[0].text != "host drop: PHOTO.QOI" {
		t.Fatalf("toast queue = %+v", notifyQueue)
	}
	if notifyQueue[0].tabID != 0 {
		t.Fatal("drop toast carries a sender id — there is no tab to focus")
	}
	// V2-D4: the toast and its center row share the open-drop binding to
	// THIS record's name — the click can never be retargeted.
	if notifyQueue[0].action != notifyActionDropOpen ||
		notifyQueue[0].snap != "PHOTO.QOI" {
		t.Fatalf("drop toast = %+v want open-drop on PHOTO.QOI", notifyQueue[0])
	}
	if len(notifyCenter) != 1 || notifyCenter[0].action != notifyActionDropOpen ||
		notifyCenter[0].snap != "PHOTO.QOI" {
		t.Fatalf("center row = %+v want the same binding", notifyCenter)
	}
	// A stale DROP on the next tick is a named refusal, never a toast.
	f.plantDrop(0xBEEF, 1, "PHOTO.QOI", 4100)
	hostintSeatTick()
	if !f.hasLog("lane=drop reason=" + hostint.RefuseStaleSeq) {
		t.Fatalf("missing stale_seq refusal: %v", f.logs)
	}
	if len(notifyQueue) != 1 {
		t.Fatalf("stale record produced a toast: %+v", notifyQueue)
	}
}

func TestHostdropBadPayloadRefused(t *testing.T) {
	resetNotify(t)
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	f.plantArmed(9, hostint.LaneDrop)
	hostintSeatTick()
	// A signed record whose payload does not decode: name_len overruns.
	p := append([]byte{200}, []byte("short")...)
	f.files[hostint.RecordName(hostint.TagDrop, 1)] =
		hostint.EncodeRecord(f.key, hostint.TagDrop, 0, 1, 9, p)
	hostintSeatTick()
	if !f.hasLog("lane=drop reason=" + hostint.RefuseBadRecord) {
		t.Fatalf("missing bad_record refusal: %v", f.logs)
	}
	if len(notifyQueue) != 0 {
		t.Fatalf("malformed record produced a toast: %+v", notifyQueue)
	}
}

// The D4 name bound holds at DECODE, not just at click dispatch: a signed
// record announcing a name past outbox.NameMax is a malformed record, not
// a delivery — its toast text ("host drop: <name>") would otherwise sail
// past the strip's text budget.
func TestHostdropOverBoundNameRefused(t *testing.T) {
	resetNotify(t)
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	f.plantArmed(9, hostint.LaneDrop)
	hostintSeatTick()
	f.plantDrop(9, 1, strings.Repeat("A", 49), 10)
	hostintSeatTick()
	if !f.hasLog("lane=drop reason=" + hostint.RefuseBadRecord) {
		t.Fatalf("missing bad_record refusal: %v", f.logs)
	}
	if len(notifyQueue) != 0 {
		t.Fatalf("over-bound name produced a toast: %+v", notifyQueue)
	}
	// A name AT the bound still delivers — the refusal is the over-bound
	// contract break, not the 48-byte name itself.
	f.plantDrop(9, 2, strings.Repeat("B", 48), 10)
	hostintSeatTick()
	if !f.hasLog(MarkerHostintDrop + "seq=2 name=" + strings.Repeat("B", 48)) {
		t.Fatalf("at-bound name refused: %v", f.logs)
	}
}

func TestHostdropConsentDeniedWithoutLaneBit(t *testing.T) {
	resetNotify(t)
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	// A clip-only ARMED: a signed DROP against an unarmed lane is the
	// ADR's consent_denied, never a toast.
	f.plantArmed(7, hostint.LaneClip)
	hostintSeatTick()
	f.plantDrop(7, 1, "SNEAK.QOI", 12)
	hostintSeatTick()
	if !f.hasLog("lane=drop reason=" + hostint.RefuseConsent) {
		t.Fatalf("missing consent_denied refusal: %v", f.logs)
	}
	if len(notifyQueue) != 0 {
		t.Fatalf("unarmed lane produced a toast: %+v", notifyQueue)
	}
}

// A control byte in a dropped name must never reach the serial marker:
// it would split the line the class-B gate greps. The sanitizer maps
// <0x20 and DEL to '?'; the toast text shares the sanitized string.
func TestHostdropNameSanitized(t *testing.T) {
	name, size, ok := dropPayload([]byte("\x05A\nB\x7fC\x01\x00\x00\x00\x00\x00\x00\x00"))
	if !ok || name != "A?B?C" || size != 1 {
		t.Fatalf("dropPayload = %q %d %v", name, size, ok)
	}

	resetNotify(t)
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	f.plantArmed(0xBEEF, hostint.LaneDrop)
	hostintSeatTick()
	f.plantDrop(0xBEEF, 1, "A\nB.QOI", 10)
	hostintSeatTick()
	if !f.hasLog(MarkerHostintDrop + "seq=1 name=A?B.QOI size=10") {
		t.Fatalf("missing sanitized drop marker: %v", f.logs)
	}
	for _, l := range f.logs {
		if strings.Contains(l, "name=A\nB") {
			t.Fatalf("a raw newline reached a marker line: %q", l)
		}
	}
	if notifyQueue[0].text != "host drop: A?B.QOI" {
		t.Fatalf("toast text = %q, want the sanitized name", notifyQueue[0].text)
	}
}

func TestDropPayloadDecode(t *testing.T) {
	name, size, ok := dropPayload([]byte("\x03ABC\x01\x00\x00\x00\x00\x00\x00\x00"))
	if !ok || name != "ABC" || size != 1 {
		t.Fatalf("dropPayload = %q %d %v", name, size, ok)
	}
	for _, p := range [][]byte{
		{},                                  // empty
		{0},                                 // zero name_len alone
		{2, 'A'},                            // truncated name
		{1, 'A', 1, 2, 3},                   // short size field
		{1, 'A', 1, 2, 3, 4, 5, 6, 7, 8, 9}, // trailing byte
	} {
		if _, _, ok := dropPayload(p); ok {
			t.Fatalf("dropPayload(%x) decoded a malformed payload", p)
		}
	}
}
