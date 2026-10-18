package main

import (
	"strings"
	"testing"

	"virelai/hostint"
	"virelai/outbox"
	"virelai/vi"
)

// obxFixture is the OUTBOX dir's in-memory twin: items is the listing the
// seam returns (REQ names + payload names with kind/size), bodies the
// file contents only the REQ markers carry. The lane dir stays the
// hostintFixture's f.files — records land there, payloads/REQs here.
type obxFixture struct {
	items map[string]vi.DirItem
	body  map[string][]byte
}

func newObxFixture(t *testing.T) *obxFixture {
	o := &obxFixture{items: map[string]vi.DirItem{}, body: map[string][]byte{}}
	prevList := hostoutboxListDir
	prevRead := hostoutboxReadFile
	prevDel := hostoutboxDeleteFile
	t.Cleanup(func() {
		hostoutboxListDir = prevList
		hostoutboxReadFile = prevRead
		hostoutboxDeleteFile = prevDel
	})
	hostoutboxListDir = func() ([]vi.DirItem, bool) {
		items := make([]vi.DirItem, 0, len(o.items))
		for _, it := range o.items {
			items = append(items, it)
		}
		return items, false
	}
	hostoutboxReadFile = func(name string) ([]byte, int64) {
		b, ok := o.body[name]
		if !ok {
			return nil, -vi.ErrENOENT
		}
		out := make([]byte, len(b))
		copy(out, b)
		return out, int64(len(b))
	}
	hostoutboxDeleteFile = func(name string) int64 {
		delete(o.items, name)
		delete(o.body, name)
		return 0
	}
	return o
}

func (o *obxFixture) plantReq(id uint32, payloadName string) {
	n := outbox.ReqName(id)
	o.items[n] = vi.DirItem{Name: n, Size: uint64(len(payloadName))}
	o.body[n] = []byte(payloadName)
}

func (o *obxFixture) plantPayload(name string, size uint64, isDir bool) {
	o.items[name] = vi.DirItem{Name: name, Size: size, IsDir: isDir}
}

func (o *obxFixture) has(name string) bool { _, ok := o.items[name]; return ok }

// outboxRecords decodes every OUTBOX-* record the lane dir holds.
func (f *hostintFixture) outboxRecords() []hostint.Record {
	var out []hostint.Record
	for name, b := range f.files {
		if strings.HasPrefix(name, "OUTBOX-") {
			if rec, ok := hostint.DecodeRecord(b); ok {
				out = append(out, rec)
			}
		}
	}
	return out
}

func TestHostoutboxEmitsSignedRecord(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	o := newObxFixture(t)
	hostintSeatInit()
	f.plantArmed(0xBEEF, hostint.LaneOutbox)
	hostintSeatTick()
	if !f.hasLog("lanes=outbox") {
		t.Fatalf("armed mask missing outbox: %v", f.logs)
	}
	o.plantPayload("HELLO.TXT", 11, false)
	o.plantReq(0x00000001, "HELLO.TXT")
	hostintSeatTick()
	recs := f.outboxRecords()
	if len(recs) != 1 {
		t.Fatalf("records = %d", len(recs))
	}
	rec := recs[0]
	if rec.Tag != hostint.TagOutbox || rec.Seq != 1 || rec.Epoch != 0xBEEF || rec.Sender != 0 {
		t.Fatalf("record fields = %+v", rec)
	}
	if !rec.Verify(f.key) {
		t.Fatal("emitted record does not verify under the lane key")
	}
	name, size, ok := dropPayload(rec.Payload)
	if !ok || name != "HELLO.TXT" || size != 11 {
		t.Fatalf("payload decode = %q %d %v", name, size, ok)
	}
	if !f.hasLog(MarkerHostintOutbox+"seq=1 name=HELLO.TXT size=11") {
		t.Fatalf("missing outbox marker: %v", f.logs)
	}
	if o.has("REQ-00000001") {
		t.Fatal("consumed REQ marker not deleted")
	}
}

func TestHostoutboxRefusals(t *testing.T) {
	cases := []struct {
		name    string
		setup   func(o *obxFixture)
		refusal string
	}{
		{"gone", func(o *obxFixture) { o.plantReq(1, "MISSING.TXT") }, hostint.RefuseGone},
		{"name_rejected", func(o *obxFixture) {
			o.plantReq(1, "bad name!.txt")
		}, hostint.RefuseNameRejected},
		{"name_rejected traversal", func(o *obxFixture) {
			o.plantReq(1, "../escape")
		}, hostint.RefuseNameRejected},
		{"unsupported_kind", func(o *obxFixture) {
			o.plantReq(1, "SUBDIR")
			o.plantPayload("SUBDIR", 0, true)
		}, hostint.RefuseUnsupported},
		{"payload_too_large", func(o *obxFixture) {
			o.plantReq(1, "BIG.BIN")
			o.plantPayload("BIG.BIN", outbox.FileMax+1, false)
		}, hostint.RefuseTooLarge},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newHostintFixture(t, strings.Repeat("b7", 32))
			o := newObxFixture(t)
			hostintSeatInit()
			f.plantArmed(9, hostint.LaneOutbox)
			hostintSeatTick()
			tc.setup(o)
			hostintSeatTick()
			if !f.hasLog("lane=outbox reason=" + tc.refusal) {
				t.Fatalf("missing %s refusal: %v", tc.refusal, f.logs)
			}
			if n := len(f.outboxRecords()); n != 0 {
				t.Fatalf("refused REQ emitted %d records", n)
			}
			if o.has("REQ-00000001") {
				t.Fatal("refused REQ not deleted")
			}
		})
	}
}

func TestHostoutboxOneReqPerTick(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	o := newObxFixture(t)
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneOutbox)
	hostintSeatTick()
	o.plantPayload("A.TXT", 1, false)
	o.plantPayload("B.TXT", 2, false)
	o.plantReq(1, "A.TXT")
	o.plantReq(2, "B.TXT")
	hostintSeatTick()
	if n := len(f.outboxRecords()); n != 1 {
		t.Fatalf("one tick consumed %d REQs", n)
	}
	hostintSeatTick()
	if n := len(f.outboxRecords()); n != 2 {
		t.Fatalf("second REQ did not drain: %d records", n)
	}
}

func TestHostoutboxSilentWithoutLaneBit(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	o := newObxFixture(t)
	hostintSeatInit()
	// Clip-only ARMED: the outbox drive must not even look at the dir.
	f.plantArmed(9, hostint.LaneClip)
	hostintSeatTick()
	o.plantPayload("A.TXT", 1, false)
	o.plantReq(1, "A.TXT")
	hostintSeatTick()
	if n := len(f.outboxRecords()); n != 0 {
		t.Fatalf("unarmed lane emitted %d records", n)
	}
	if !o.has("REQ-00000001") {
		t.Fatal("REQ touched while the lane bit was off")
	}
	if f.hasLog("outbox") {
		t.Fatalf("unarmed lane logged outbox traffic: %v", f.logs)
	}
}

// The seam's v1 default: with M127c's hook unbound a NOTIFY_FOCUS record
// refuses lane_disabled — the same answer an unclaimed tag always got.
func TestNotifyFocusDefaultsToLaneDisabled(t *testing.T) {
	if got := hostintConsume(hostint.TagNotifyFocus, hostint.Record{}); got != hostint.RefuseLaneDisabled {
		t.Fatalf("unbound focus consume = %q", got)
	}
}

func TestHostoutboxBackpressuredReqWaits(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	o := newObxFixture(t)
	hostintSeatInit()
	f.plantArmed(3, hostint.LaneOutbox)
	hostintSeatTick()
	// Fill the emit bound: four unconsumed OUTBOX records (seqs the
	// runner has not drained) leave no room for the REQ's emit.
	for i := uint32(1); i <= hostint.MaxOutstanding; i++ {
		p := append([]byte{1}, 'X')
		p = append(p, make([]byte, 8)...)
		f.files[hostint.RecordName(hostint.TagOutbox, i)] =
			hostint.EncodeRecord(f.key, hostint.TagOutbox, 0, i, 3, p)
	}
	hostintSeatTick() // refresh the engine's listing view
	o.plantPayload("A.TXT", 1, false)
	o.plantReq(9, "A.TXT")
	hostintSeatTick()
	if !o.has("REQ-00000009") {
		t.Fatal("backpressured REQ was consumed — the intent must wait")
	}
	if n := len(f.outboxRecords()); n != int(hostint.MaxOutstanding) {
		t.Fatalf("emitted past the bound: %d", n)
	}
}
