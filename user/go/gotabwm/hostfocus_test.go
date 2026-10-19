package main

import (
	"strings"
	"testing"

	"virelai/hostint"
	"virelai/shlib"
)

// hostfocus_test.go — M127c (#2601, ADR 0051 V2-D3): the NOTIFY_FOCUS
// consume half. The hostintFixture drives the real engine against an
// in-memory lane directory; hostfocusFocus is a recorder, so the whole
// verify → mask → seq → focus chain is pinned without the slot-65
// syscall.

// plantNFocus stages a signed NOTIFY_FOCUS for (epoch, seq, sender).
func (f *hostintFixture) plantNFocus(epoch, seq uint32, sender uint16) {
	f.files[hostint.RecordName(hostint.TagNotifyFocus, seq)] =
		hostint.EncodeRecordSender(f.key, hostint.TagNotifyFocus, 0, sender, seq, epoch, nil)
}

// plantNFocusRaw stages a hand-signed NOTIFY_FOCUS the encoder would
// refuse — a sender-0 record is MAC-valid but violates the tag's
// contract, which is exactly the bad_record posture under test.
func (f *hostintFixture) plantNFocusRaw(epoch, seq uint32, sender uint16) {
	raw := make([]byte, 0, hostint.HeaderLen+hostint.MACLen)
	raw = append(raw, 'V', 'H', 'I', '1', hostint.TagNotifyFocus, 0,
		byte(sender), byte(sender>>8),
		byte(seq), byte(seq>>8), byte(seq>>16), byte(seq>>24),
		byte(epoch), byte(epoch>>8), byte(epoch>>16), byte(epoch>>24),
		0, 0)
	mac := shlib.HMACSHA256(f.key, raw)
	f.files[hostint.RecordName(hostint.TagNotifyFocus, seq)] = append(raw, mac[:]...)
}

// focusRecorder swaps the slot-65 focus seam for a list of the ids a
// record asked to raise; ok=false simulates the kernel/seat refusing
// (the dead-tab `gone` case).
func focusRecorder(t *testing.T, ok bool) *[]uint32 {
	t.Helper()
	got := &[]uint32{}
	prev := hostfocusFocus
	hostfocusFocus = func(id uint32) bool {
		*got = append(*got, id)
		return ok
	}
	t.Cleanup(func() { hostfocusFocus = prev })
	return got
}

func TestHostFocusClickThroughFocusesTab(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("d4", 32))
	focused := focusRecorder(t, true)
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneNotify)
	hostintSeatTick()

	f.plantNFocus(7, 1, 42)
	hostintSeatTick()
	if len(*focused) != 1 || (*focused)[0] != 42 {
		t.Fatalf("focused = %v, want [42]", *focused)
	}
	if !f.hasLog(MarkerHostintNotifyFocus + "seq=1 id=42") {
		t.Fatalf("missing notify-focus receipt: %v", f.logs)
	}
	if _, ok := f.files["NFOCUS-00000001"]; ok {
		t.Fatal("consumed record left behind")
	}
}

func TestHostFocusDeadSenderIsGone(t *testing.T) {
	// The tab closed between banner and click: focusHosted's false is
	// the named `gone` refusal, and the record is still consumed.
	f := newHostintFixture(t, strings.Repeat("d4", 32))
	focused := focusRecorder(t, false)
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneNotify)
	hostintSeatTick()

	f.plantNFocus(7, 1, 9)
	hostintSeatTick()
	if len(*focused) != 1 {
		t.Fatalf("focus seam not reached: %v", *focused)
	}
	if !f.hasLog("refuse lane=notify reason=" + hostint.RefuseGone) {
		t.Fatalf("missing gone refusal: %v", f.logs)
	}
	if _, ok := f.files["NFOCUS-00000001"]; ok {
		t.Fatal("refused record left behind")
	}
}

func TestHostFocusSenderZeroIsBadRecord(t *testing.T) {
	// A signed sender-0 NFOCUS cannot be produced by a lawful encoder —
	// the header is the whole payload, so its absence is bad_record, not
	// "focus nothing".
	f := newHostintFixture(t, strings.Repeat("d4", 32))
	focused := focusRecorder(t, true)
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneNotify)
	hostintSeatTick()

	f.plantNFocusRaw(7, 1, 0)
	hostintSeatTick()
	if len(*focused) != 0 {
		t.Fatalf("sender-0 record focused a tab: %v", *focused)
	}
	if !f.hasLog("refuse lane=notify reason=" + hostint.RefuseBadRecord) {
		t.Fatalf("missing bad_record refusal: %v", f.logs)
	}
}

func TestHostFocusLaneOffIsConsentDenied(t *testing.T) {
	// NOTIFY_FOCUS rides lane_notify: an ARMED naming only clip leaves
	// the record signed but unconsented — the engine's posture, before
	// this file's route is ever asked.
	f := newHostintFixture(t, strings.Repeat("d4", 32))
	focused := focusRecorder(t, true)
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneClip)
	hostintSeatTick()

	f.plantNFocus(7, 1, 5)
	hostintSeatTick()
	if len(*focused) != 0 {
		t.Fatalf("unarmed lane focused a tab: %v", *focused)
	}
	if !f.hasLog("refuse lane=notify reason=" + hostint.RefuseConsent) {
		t.Fatalf("missing consent_denied refusal: %v", f.logs)
	}
}

func TestHostFocusConsumeIsBounded(t *testing.T) {
	// Like every inbound tag: ≤ 1 record per seat tick, in seq order —
	// the second waits for the next Poll.
	f := newHostintFixture(t, strings.Repeat("d4", 32))
	focused := focusRecorder(t, true)
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneNotify)
	hostintSeatTick()

	f.plantNFocus(7, 1, 11)
	f.plantNFocus(7, 2, 12)
	hostintSeatTick()
	if len(*focused) != 1 || (*focused)[0] != 11 {
		t.Fatalf("tick 1 focused %v, want [11]", *focused)
	}
	hostintSeatTick()
	if len(*focused) != 2 || (*focused)[1] != 12 {
		t.Fatalf("tick 2 focused %v, want [11 12]", *focused)
	}
}
