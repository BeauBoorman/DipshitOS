package hostint

import (
	"strings"
	"testing"

	"virelai/vi"
)

// testKey is the pinned test credential — the agentd `a5`x32 shape (the
// secret value bytes ARE the HMAC key; no encoding layer).
var testKey = []byte(strings.Repeat("a5", 32))

// fakeDir is an in-memory lane directory: files map name -> bytes, and it
// records deletes + logs so a test asserts the whole disposition.
type fakeDir struct {
	files    map[string][]byte
	absent   bool
	listErr  bool // a real channel failure — (nil, false), not the absent case
	readErr  map[string]bool // listed-but-unreadable files (Read rc < 0)
	logs     []string
	consumed []Record
	consumedReasons []string
}

func (d *fakeDir) list() ([]vi.DirItem, bool) {
	if d.listErr {
		return nil, false
	}
	if d.absent {
		return nil, true
	}
	var items []vi.DirItem
	for name := range d.files {
		items = append(items, vi.DirItem{Name: name})
	}
	return items, false
}

func (d *fakeDir) read(name string) ([]byte, int64) {
	if d.readErr[name] {
		return nil, -vi.ErrEIO
	}
	b, ok := d.files[name]
	if !ok {
		return nil, -vi.ErrENOENT
	}
	out := make([]byte, len(b))
	copy(out, b)
	return out, int64(len(b))
}

func (d *fakeDir) write(name string, b []byte) int64 {
	cp := make([]byte, len(b))
	copy(cp, b)
	d.files[name] = cp
	return 0
}

func (d *fakeDir) del(name string) int64 {
	delete(d.files, name)
	return 0
}

func (d *fakeDir) log(s string) { d.logs = append(d.logs, s) }

func (d *fakeDir) hasLog(sub string) bool {
	for _, l := range d.logs {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

func (d *fakeDir) countLog(sub string) int {
	n := 0
	for _, l := range d.logs {
		if strings.Contains(l, sub) {
			n++
		}
	}
	return n
}

func (d *fakeDir) engine() *Engine {
	e := NewEngine(testKey, EngineIO{
		List:   d.list,
		Read:   d.read,
		Write:  d.write,
		Delete: d.del,
		Log:    d.log,
	}, "seat: hostint")
	e.Consume = func(tag uint8, rec Record) string {
		d.consumed = append(d.consumed, rec)
		return ""
	}
	return e
}

// armed plants a valid ARMED record for epoch with the given lane mask.
func (d *fakeDir) armed(epoch uint32, mask uint8, seq uint32) {
	d.files[RecordName(TagArmed, seq)] = EncodeRecord(testKey, TagArmed, 0, seq, epoch, []byte{mask})
}

// plant writes a signed record file for (tag, seq, epoch, payload).
func (d *fakeDir) plant(tag, flags uint8, seq, epoch uint32, payload []byte) {
	d.files[RecordName(tag, seq)] = EncodeRecord(testKey, tag, flags, seq, epoch, payload)
}

// --- codec -----------------------------------------------------------------

func TestRecordRoundTripAndGoldenLayout(t *testing.T) {
	payload := []byte("hello")
	raw := EncodeRecord(testKey, TagClipIn, FlagTruncated, 7, 0xC0FFEE, payload)
	if len(raw) != HeaderLen+len(payload)+MACLen {
		t.Fatalf("record len %d want %d", len(raw), HeaderLen+len(payload)+MACLen)
	}
	// Pin the wire layout byte-for-byte: magic, tag, flags, reserved,
	// seq/epoch/plen little-endian, payload, then the 32-byte tag.
	if string(raw[0:4]) != "VHI1" {
		t.Fatalf("magic %q", raw[0:4])
	}
	if raw[4] != TagClipIn || raw[5] != FlagTruncated || raw[6] != 0 || raw[7] != 0 {
		t.Fatalf("tag/flags/reserved %02x %02x %02x %02x", raw[4], raw[5], raw[6], raw[7])
	}
	if le32(raw[8:12]) != 7 || le32(raw[12:16]) != 0xC0FFEE || le16(raw[16:18]) != 5 {
		t.Fatal("seq/epoch/plen fields wrong")
	}
	if string(raw[HeaderLen:HeaderLen+5]) != "hello" {
		t.Fatal("payload not at offset 18")
	}
	rec, ok := DecodeRecord(raw)
	if !ok {
		t.Fatal("decode failed")
	}
	if rec.Tag != TagClipIn || rec.Flags != FlagTruncated || rec.Seq != 7 || rec.Epoch != 0xC0FFEE {
		t.Fatal("decode fields wrong")
	}
	if string(rec.Payload) != "hello" {
		t.Fatalf("payload %q", rec.Payload)
	}
	if !rec.Verify(testKey) {
		t.Fatal("verify failed on a record we just signed")
	}
	if rec.Verify([]byte("wrong-key")) {
		t.Fatal("verify passed under a different key")
	}
}

func TestDecodeRefusals(t *testing.T) {
	good := EncodeRecord(testKey, TagClipIn, 0, 1, 9, []byte("x"))
	cases := map[string][]byte{
		"short":      good[:HeaderLen+MACLen-1],
		"oversize":   make([]byte, RecordMax+1),
		"bad magic":  append(append([]byte{}, "BAD!"...), good[4:]...),
		"bad tag":    append(append([]byte{}, good[:4]...), append([]byte{9, 0, 0, 0}, good[8:]...)...),
		"plen drift": append(append([]byte{}, good[:16]...), append([]byte{5, 0}, good[18:]...)...),
	}
	for name, raw := range cases {
		if _, ok := DecodeRecord(raw); ok {
			t.Fatalf("%s: decoded a malformed record", name)
		}
	}
}

// v2: bytes 6..7 are sender_id, not reserved zeros. A v1 record carries
// 0 there by construction; a nonzero sender decodes into the field and
// the MAC domain is unchanged (bytes[0..18+plen) still covers it).
func TestSenderIdRoundTrip(t *testing.T) {
	raw := EncodeRecordSender(testKey, TagNotifyOut, 0, 4, 3, 9, []byte("toast"))
	rec, ok := DecodeRecord(raw)
	if !ok {
		t.Fatal("a sender-bearing record must decode")
	}
	if rec.Sender != 4 {
		t.Fatalf("sender = %d want 4", rec.Sender)
	}
	if !rec.Verify(testKey) {
		t.Fatal("sender_id sits inside the MAC domain — verify must hold")
	}
	// The v1 form still encodes 0 and still decodes.
	rec2, ok := DecodeRecord(EncodeRecord(testKey, TagClipIn, 0, 1, 9, []byte("x")))
	if !ok || rec2.Sender != 0 {
		t.Fatalf("v1 form: ok=%v sender=%d", ok, rec2.Sender)
	}
}

// NOTIFY_FOCUS is plen 0 by grammar: a payload on the tag is bad_record
// on decode and refused at encode; the encode side also refuses a
// senderless focus request (the header is its whole payload).
func TestNotifyFocusGrammar(t *testing.T) {
	if EncodeRecordSender(testKey, TagNotifyFocus, 0, 0, 1, 9, nil) != nil {
		t.Fatal("a senderless NOTIFY_FOCUS must refuse at encode")
	}
	if EncodeRecordSender(testKey, TagNotifyFocus, 0, 7, 1, 9, []byte("x")) != nil {
		t.Fatal("a payload-bearing NOTIFY_FOCUS must refuse at encode")
	}
	raw := EncodeRecordSender(testKey, TagNotifyFocus, 0, 7, 1, 9, nil)
	if raw == nil {
		t.Fatal("plen-0 sender-bearing NOTIFY_FOCUS is the legal form")
	}
	rec, ok := DecodeRecord(raw)
	if !ok || rec.Sender != 7 || rec.Tag != TagNotifyFocus {
		t.Fatalf("decode: ok=%v sender=%d tag=%d", ok, rec.Sender, rec.Tag)
	}
	// Hand-mutate plen onto the wire form: still fails decode.
	mut := append(append([]byte{}, raw[:16]...), append([]byte{1, 0, 'x'}, raw[18:]...)...)
	if _, ok := DecodeRecord(mut); ok {
		t.Fatal("a payload-bearing NFOCUS must decode as bad_record")
	}
}

func TestOutboxTagAndLane(t *testing.T) {
	for _, tc := range []struct {
		tag  uint8
		seq  uint32
		want string
	}{
		{TagOutbox, 3, "OUTBOX-00000003"},
		{TagNotifyFocus, 9, "NFOCUS-00000009"},
	} {
		if got := RecordName(tc.tag, tc.seq); got != tc.want {
			t.Fatalf("RecordName(%d,%08x) = %q want %q", tc.tag, tc.seq, got, tc.want)
		}
		tag, seq, ok := ParseName(tc.want)
		if !ok || tag != tc.tag || seq != tc.seq {
			t.Fatalf("ParseName(%q) = %d,%d,%v", tc.want, tag, seq, ok)
		}
	}
	if LaneBit(TagOutbox) != LaneOutbox || LaneName(TagOutbox) != "outbox" {
		t.Fatal("outbox lane mapping wrong")
	}
	if LaneBit(TagNotifyFocus) != LaneNotify || LaneName(TagNotifyFocus) != "notify" {
		t.Fatal("notify-focus rides the notify lane bit")
	}
	if got := MaskNames(LaneClip | LaneDrop | LaneNotify | LaneOutbox); got != "clip,drop,notify,outbox" {
		t.Fatalf("MaskNames = %q", got)
	}
	// M124c: the typed clip tags ride the clip lane's bit + name.
	if LaneBit(TagClipOutT) != LaneClip || LaneBit(TagClipInT) != LaneClip {
		t.Fatal("typed clip tags must ride LaneClip")
	}
	if LaneName(TagClipOutT) != "clip" || LaneName(TagClipInT) != "clip" {
		t.Fatal("typed clip refusals render lane=clip")
	}
}

// The M124c typed envelope: `u8 mime_len | mime | blob`, bounded by the
// record's own 512 — the mime spends payload bytes the blob then cannot.
func TestTypedClipEnvelope(t *testing.T) {
	enc := EncodeTypedClip("image/png", []byte("\x89PNGbody"))
	if enc == nil {
		t.Fatal("png envelope refused")
	}
	mime, blob, ok := DecodeTypedClip(enc)
	if !ok || mime != "image/png" || string(blob) != "\x89PNGbody" {
		t.Fatalf("roundtrip = %q %q %v", mime, blob, ok)
	}
	if EncodeTypedClip("", []byte("x")) != nil {
		t.Fatal("empty mime encoded")
	}
	if EncodeTypedClip("this/mime-is-far-too-long", []byte("x")) != nil {
		t.Fatal("over-bound mime encoded")
	}
	if EncodeTypedClip("image/png", make([]byte, PayloadMax)) != nil {
		t.Fatal("envelope past the record bound encoded")
	}
	if _, _, ok := DecodeTypedClip([]byte{9, 'x'}); ok {
		t.Fatal("short envelope decoded")
	}
	if _, _, ok := DecodeTypedClip([]byte{0, 'x'}); ok {
		t.Fatal("zero mime_len decoded")
	}
	if _, _, ok := DecodeTypedClip(EncodeTypedClip("text/uri-list", []byte("f"))[:3]); ok {
		t.Fatal("truncated envelope decoded")
	}
}

// Flag bits 1-7 are reserved (the writer sends 0): the encoder refuses
// them outright and the decoder names a wire record carrying one a
// bad_record — one grammar on both ends of the channel.
func TestRecordFlagsReservedRefused(t *testing.T) {
	if EncodeRecord(testKey, TagClipIn, 0x02, 1, 9, []byte("x")) != nil {
		t.Fatal("encode with a reserved flag bit must refuse")
	}
	raw := EncodeRecord(testKey, TagClipIn, FlagTruncated, 1, 9, []byte("x"))
	if raw == nil {
		t.Fatal("FlagTruncated is the one legal flag")
	}
	raw[5] |= 0x02
	if _, ok := DecodeRecord(raw); ok {
		t.Fatal("a reserved flag bit must decode as bad_record")
	}
}

func TestRecordNames(t *testing.T) {
	for _, tc := range []struct {
		tag  uint8
		seq  uint32
		want string
	}{
		{TagArmed, 1, "ARMED-00000001"},
		{TagClipIn, 7, "CLIPIN-00000007"},
		{TagClipOut, 0xffffffff, "CLIPOUT-ffffffff"},
		{TagNotifyOut, 2, "NOTIFY-00000002"},
		{TagDrop, 10, "DROP-0000000a"},
		{TagClipOutT, 5, "CLIPTOUT-00000005"},
		{TagClipInT, 3, "CLIPTIN-00000003"},
	} {
		if got := RecordName(tc.tag, tc.seq); got != tc.want {
			t.Fatalf("RecordName(%d,%08x) = %q want %q", tc.tag, tc.seq, got, tc.want)
		}
		tag, seq, ok := ParseName(tc.want)
		if !ok || tag != tc.tag || seq != tc.seq {
			t.Fatalf("ParseName(%q) = %d,%d,%v", tc.want, tag, seq, ok)
		}
	}
	for _, bad := range []string{
		"CLIPIN-00000007~", "X-00000001", "CLIPIN-", "CLIPIN-12345",
		"clipin-00000001", ".clock", "", "CLIPIN-0000000g",
	} {
		if _, _, ok := ParseName(bad); ok {
			t.Fatalf("%q must not parse as a record", bad)
		}
	}
}

// --- engine ----------------------------------------------------------------

func TestEngineDormantUntilArmed(t *testing.T) {
	d := &fakeDir{files: map[string][]byte{}}
	e := d.engine()
	// A valid CLIP_IN whose epoch cannot yet be judged: held, not consumed.
	d.plant(TagClipIn, 0, 1, 77, []byte("from host"))
	e.Poll()
	if e.Armed() {
		t.Fatal("engine armed without an ARMED record")
	}
	if len(d.consumed) != 0 {
		t.Fatal("consumed before adoption")
	}
	if _, ok := d.files["CLIPIN-00000001"]; !ok {
		t.Fatal("pre-adoption record must be held, not deleted")
	}
	// Now ARMED with a DIFFERENT epoch: the held record is stale_epoch.
	d.armed(9, LaneClip, 1)
	e.Poll()
	if !e.Armed() {
		t.Fatal("adoption failed")
	}
	if _, ok := d.files["CLIPIN-00000001"]; ok {
		t.Fatal("stale-epoch record not deleted")
	}
	if !d.hasLog("refuse lane=clip reason=stale_epoch") {
		t.Fatalf("missing stale_epoch refusal; logs=%v", d.logs)
	}
	if !d.hasLog("armed epoch=9 lanes=clip") {
		t.Fatalf("missing armed marker; logs=%v", d.logs)
	}
}

func TestEngineConsumesClipIn(t *testing.T) {
	d := &fakeDir{files: map[string][]byte{}}
	e := d.engine()
	d.armed(42, LaneClip, 1)
	d.plant(TagClipIn, 0, 1, 42, []byte("host text"))
	e.Poll()
	if len(d.consumed) != 1 || string(d.consumed[0].Payload) != "host text" {
		t.Fatalf("consumed=%v", d.consumed)
	}
	if _, ok := d.files["CLIPIN-00000001"]; ok {
		t.Fatal("consumed record not deleted")
	}
	// Replay of the same seq -> stale_seq.
	d.plant(TagClipIn, 0, 1, 42, []byte("replayed"))
	e.Poll()
	if len(d.consumed) != 1 {
		t.Fatal("stale seq was consumed")
	}
	if !d.hasLog("reason=stale_seq") {
		t.Fatalf("missing stale_seq; logs=%v", d.logs)
	}
}

func TestEngineBadMACDeleted(t *testing.T) {
	d := &fakeDir{files: map[string][]byte{}}
	e := d.engine()
	d.armed(1, LaneClip, 1)
	raw := EncodeRecord([]byte("forged-key"), TagClipIn, 0, 1, 1, []byte("evil"))
	d.files["CLIPIN-00000001"] = raw
	e.Poll()
	if _, ok := d.files["CLIPIN-00000001"]; ok {
		t.Fatal("forged record not deleted")
	}
	if !d.hasLog("reason=bad_mac") {
		t.Fatalf("missing bad_mac; logs=%v", d.logs)
	}
	if len(d.consumed) != 0 {
		t.Fatal("forged record consumed")
	}
}

func TestEngineConsentDeniedWhenLaneBitOff(t *testing.T) {
	d := &fakeDir{files: map[string][]byte{}}
	e := d.engine()
	// ARMED without the clip bit: a signed CLIP_IN is consent_denied.
	d.armed(5, LaneDrop, 1)
	d.plant(TagClipIn, 0, 1, 5, []byte("x"))
	e.Poll()
	if !d.hasLog("refuse lane=clip reason=consent_denied") {
		t.Fatalf("missing consent_denied; logs=%v", d.logs)
	}
	if len(d.consumed) != 0 {
		t.Fatal("unconsented record applied")
	}
}

func TestEngineOneApplyPerTick(t *testing.T) {
	d := &fakeDir{files: map[string][]byte{}}
	e := d.engine()
	d.armed(7, LaneClip, 1)
	d.plant(TagClipIn, 0, 1, 7, []byte("one"))
	d.plant(TagClipIn, 0, 2, 7, []byte("two"))
	e.Poll()
	if len(d.consumed) != 1 {
		t.Fatalf("applied %d records in one tick", len(d.consumed))
	}
	e.Poll()
	if len(d.consumed) != 2 || string(d.consumed[1].Payload) != "two" {
		t.Fatalf("second record not consumed next tick: %v", d.consumed)
	}
}

func TestEngineEmitAndBackpressure(t *testing.T) {
	d := &fakeDir{files: map[string][]byte{}}
	e := d.engine()
	// Not armed: emit refuses lane_disabled and writes nothing.
	if _, r := e.Emit(TagClipOut, 0, []byte("x")); r != RefuseLaneDisabled {
		t.Fatalf("dormant emit refused %q want lane_disabled", r)
	}
	d.armed(3, LaneClip, 1)
	e.Poll()
	seq, r := e.Emit(TagClipOut, 0, []byte("hello host"))
	if r != "" || seq != 1 {
		t.Fatalf("emit seq=%d refusal=%q", seq, r)
	}
	raw, ok := d.files["CLIPOUT-00000001"]
	if !ok {
		t.Fatal("emit wrote no record")
	}
	rec, ok := DecodeRecord(raw)
	if !ok || !rec.Verify(testKey) || rec.Epoch != 3 || string(rec.Payload) != "hello host" {
		t.Fatal("emitted record does not decode+verify")
	}
	// Payload bound.
	if _, r := e.Emit(TagClipOut, 0, make([]byte, PayloadMax+1)); r != RefuseTooLarge {
		t.Fatalf("oversize emit refused %q", r)
	}
	// Four outstanding per tag is the cap: fill to it, then backpressured.
	for i := 0; i < 3; i++ {
		if _, r := e.Emit(TagClipOut, 0, []byte("x")); r != "" {
			t.Fatalf("emit %d refused %q", i, r)
		}
	}
	// The last listing still holds the emitted files only if we re-poll:
	// Outstanding reads lastItems — refresh it.
	e.Poll()
	if e.Outstanding(TagClipOut) != 4 {
		t.Fatalf("outstanding %d want 4", e.Outstanding(TagClipOut))
	}
	if _, r := e.Emit(TagClipOut, 0, []byte("x")); r != RefuseBackpressure {
		t.Fatalf("fifth emit refused %q want backpressured", r)
	}
}

// A real dir-list failure is an io_error refusal, and the marker names a
// lane — never the empty `lane=` a bare tag-0 used to render.
func TestEngineDirListErrorNamesDirlist(t *testing.T) {
	d := &fakeDir{files: map[string][]byte{}, listErr: true}
	e := d.engine()
	e.Poll()
	if !d.hasLog("refuse lane=dirlist reason=io_error") {
		t.Fatalf("missing named dir-list refusal; logs=%v", d.logs)
	}
	// The refusal is latched: a still-broken channel does not re-log.
	e.Poll()
	if len(d.logs) != 1 {
		t.Fatalf("io_error must latch, logs=%v", d.logs)
	}
}

func TestEngineAbsentDirIsSilent(t *testing.T) {
	d := &fakeDir{files: map[string][]byte{}, absent: true}
	e := d.engine()
	for i := 0; i < 5; i++ {
		e.Poll()
	}
	if len(d.logs) != 0 {
		t.Fatalf("absent lane dir logged: %v", d.logs)
	}
}

// A latched io_error name that leaves the listing is evicted: the latch
// suppresses one continuous failure, not the name forever — a file that
// reappears and fails again is a new failure and reports once more.
func TestEngineIOErrLatchEvictsDeadNames(t *testing.T) {
	d := &fakeDir{files: map[string][]byte{}, readErr: map[string]bool{}}
	e := d.engine()
	// A foreign file keeps the listing non-empty (fakeDir's nil list is
	// a channel failure, not an empty dir).
	d.files["KEEP.TXT"] = []byte("x")
	d.plant(TagClipIn, 0, 1, 7, []byte("x"))
	d.readErr["CLIPIN-00000001"] = true
	e.Poll()
	e.Poll() // still listed + still failing: one marker, not two
	if got := d.countLog("reason=io_error"); got != 1 {
		t.Fatalf("io_error count %d want 1; logs=%v", got, d.logs)
	}
	// The file leaves the listing (a runner-side delete, or the
	// List/Read race settled): the latch drops its name.
	delete(d.files, "CLIPIN-00000001")
	e.Poll()
	if len(e.ioErrLatched) != 0 {
		t.Fatalf("latch held %d dead names", len(e.ioErrLatched))
	}
	// A same-named file that reappears unreadable is not silenced by the
	// stale latch.
	d.plant(TagClipIn, 0, 1, 7, []byte("x"))
	e.Poll()
	if got := d.countLog("reason=io_error"); got != 2 {
		t.Fatalf("reappearing failing name did not re-report; logs=%v", d.logs)
	}
}

// The latch table is capped: a listing full of failing names cannot grow
// the seat's map past ioErrLatchCap, and each first failure still logs.
func TestEngineIOErrLatchIsBounded(t *testing.T) {
	d := &fakeDir{files: map[string][]byte{}, readErr: map[string]bool{}}
	e := d.engine()
	for i := uint32(1); i <= ioErrLatchCap+4; i++ {
		name := RecordName(TagClipIn, i)
		d.files[name] = []byte("unreadable")
		d.readErr[name] = true
	}
	e.Poll()
	if len(e.ioErrLatched) > ioErrLatchCap {
		t.Fatalf("latch grew to %d > cap %d", len(e.ioErrLatched), ioErrLatchCap)
	}
	if got := d.countLog("reason=io_error"); got != ioErrLatchCap+4 {
		t.Fatalf("first-failure markers %d want %d", got, ioErrLatchCap+4)
	}
}
