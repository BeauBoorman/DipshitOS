// The seat-side lane engine (ADR 0051 D1/D2): one directory scan per
// composite tick, verify-then-consume for inbound records, bounded signed
// emit for outbound ones. Lane-agnostic — the seat wires the IO seams and
// registers per-tag consumers; the clipboard lane (M108b) is the first
// tenant, drop (M108c) and notify-out (M108d) plug into the same engine.
//
// Ordering/consent rules the engine owns, so no lane re-derives them:
//
//   - Dormant until one ARMED verifies: the seat adopts (epoch, lane_mask)
//    and only then accepts records bearing that epoch (stale_epoch/stale_seq
//    are named refusals, never silent weirdness).
//   - Every refused or consumed record is DELETED; a record whose MAC is
//    valid but predates adoption is held (its epoch is not yet judgable).
//   - At most one record per inbound tag is consumed per Poll — the ADR's
//    per-tick apply bound; queued records wait for the next tick.
//   - A producer never has more than MaxOutstanding records unconsumed per
//    tag — over that the emit refuses `backpressured`.
package hostint

import "virelai/vi"

// EngineIO is the seam set the seat wires: the lane directory's file ops
// plus the marker sink. Every function takes/returns the bare lane filename
// (the engine joins it to the directory for the caller's benefit — the
// seat's real seams glue it to /host/HOSTINT/ there).
type EngineIO struct {
	// List returns the lane directory's entries (vi.DirList on HostDir).
	// (items, false) is a listing, (nil, true) is "the directory does not
	// exist" — the flags-off steady state, silent — and (nil, false) is a
	// real channel failure, which is an io_error refusal.
	List func() ([]vi.DirItem, bool)
	// Read returns one lane file's bytes (vi.ReadFileAll on HostDir+"/"+name,
	// bounded at RecordMax+1 so oversize is visible to Decode).
	Read func(name string) ([]byte, int64)
	// Write publishes one record file atomically (vi.WriteFileSafe — the
	// share's temp-then-rename rule).
	Write func(name string, b []byte) int64
	// Delete removes one lane file (vi.FileDelete).
	Delete func(name string) int64
	// Log emits one marker line (vi.ConsoleLine).
	Log func(line string)
}

// Engine is the seat's lane state: the ARMED adoption, per-tag seq books
// and the IO seams. The zero value is dormant-but-safe; the seat constructs
// it only when the host-int credential exists (absent = the whole lane is
// dead and nothing ever polls, per D7's byte-silence rule).
type Engine struct {
	io EngineIO

	// Marker is the log prefix — the seat's own name ("gotabwm: hostint").
	Marker string

	// Consume is the per-tag inbound dispatch for seat-consumed tags
	// (CLIP_IN, DROP). It runs only after epoch/MAC/seq/lane-mask all pass;
	// its return is "" (applied — the handler logs the lane's own success
	// marker) or a refusal code (the record is still consumed — a verified
	// record the seat declines is a dead record, not a retry).
	Consume func(tag uint8, rec Record) string

	key     []byte
	armed   bool
	epoch   uint32
	mask    uint8
	lastIn  [tagCount]uint32
	nextOut [tagCount]uint32
	// lastItems is the most recent successful lane listing — Emit's
	// backpressure view (a producer counts its unconsumed files here).
	lastItems []vi.DirItem
	// ioErrLatched holds lane filenames whose read already drew one io_error
	// marker — a persistently unreadable file must not spam the log every
	// tick. Two bounds keep the table from growing with churned names:
	// entries absent from the next successful listing are evicted (a
	// vanished file cannot fail again — the runner deleting a seat
	// emission between List and Read is the common churn), and the table
	// is capped at ioErrLatchCap.
	ioErrLatched map[string]bool
}

// ioErrLatchCap bounds the io_error latch table — the suppressor's own
// worst case. A lane directory of healthy traffic carries a handful of
// record files; a flood past this many failing names resets the table
// (latchIOErr) instead of pinning one map entry per churned filename.
const ioErrLatchCap = 64

// NewEngine builds an engine for key (the host-int credential bytes) with
// the given IO seams and marker prefix.
func NewEngine(key []byte, io EngineIO, marker string) *Engine {
	k := make([]byte, len(key))
	copy(k, key)
	return &Engine{io: io, Marker: marker, key: k}
}

// Armed reports whether a verified ARMED has been adopted this boot.
func (e *Engine) Armed() bool { return e.armed }

// LaneMask is the adopted ARMED mask (0 while dormant).
func (e *Engine) LaneMask() uint8 {
	if !e.armed {
		return 0
	}
	return e.mask
}

// laneLog writes one marker line when the seat wired a sink.
func (e *Engine) laneLog(s string) {
	if e.io.Log != nil {
		e.io.Log(s)
	}
}

// refuse emits the shared refusal marker `… refuse lane=<l> reason=<code>`
// — the seat-side half of the ADR's one-vocabulary-both-ends rule.
func (e *Engine) refuse(tag uint8, reason string) {
	e.laneLog(e.Marker + " refuse lane=" + LaneName(tag) + " reason=" + reason)
}

// RefuseLane is the lane code's way into the same refusal marker — emit
// refusals (payload_not_text on an outbound read, backpressured…) carry the
// identical line shape the engine's inbound refusals use.
func (e *Engine) RefuseLane(tag uint8, reason string) {
	e.refuse(tag, reason)
}

// Poll runs one tick of the lane: list HOSTINT, verify and consume inbound
// records in name order, count the outbound backlog for Emit. It is a no-op
// (silent) when the directory does not exist — the flags-off steady state.
func (e *Engine) Poll() {
	if e == nil || e.io.List == nil {
		return
	}
	items, absent := e.io.List()
	if items == nil {
		if absent {
			// The directory never existed: flags-off, silent per D7.
			return
		}
		// A real list failure is an io_error, latched so a persistently
		// broken channel logs once, not once a second.
		if e.latchIOErr("<dir>") {
			e.refuse(0, RefuseIO)
		}
		return
	}
	delete(e.ioErrLatched, "<dir>")
	// Evict latched names this listing no longer carries: a vanished
	// file cannot fail again, so its suppression state is dead weight —
	// and a reappearing name is a new failure that must report once more
	// rather than stay silenced by a stale latch.
	if len(e.ioErrLatched) > 0 {
		live := make(map[string]bool, len(items))
		for _, it := range items {
			live[it.Name] = true
		}
		for name := range e.ioErrLatched {
			if !live[name] {
				delete(e.ioErrLatched, name)
			}
		}
	}
	e.lastItems = items
	// Name-sorted processing gives per-tag seq order for free (STEM-%08x
	// sorts numerically inside a stem) and ARMED before CLIPIN (A < C),
	// which is the order adoption needs when both land in one window.
	names := make([]string, 0, len(items))
	for _, it := range items {
		if it.IsDir {
			continue
		}
		names = append(names, it.Name)
	}
	insertionSort(names)
	// applied[tag] enforces ≤ 1 consumed record per tag per Poll.
	var applied [tagCount]bool
	for _, name := range names {
		tag, seq, ok := ParseName(name)
		if !ok {
			continue // publish temps and foreign files are not records
		}
		raw, rc := e.io.Read(name)
		if rc < 0 {
			if e.latchIOErr(name) {
				e.refuse(tag, RefuseIO)
			}
			continue // leave the file — a transient read error retries
		}
		delete(e.ioErrLatched, name)
		rec, ok := DecodeRecord(raw)
		if !ok || rec.Tag != tag {
			// The filename claims the tag — a record whose header tag does
			// not match its own name is malformed, not a delivery.
			e.refuse(tag, RefuseBadRecord)
			e.del(name)
			continue
		}
		if !rec.Verify(e.key) {
			// The forgery refusal, for any tag, armed or not: a bad MAC
			// can never become valid, so it is deleted on sight.
			e.refuse(tag, RefuseBadMAC)
			e.del(name)
			continue
		}
		if !e.armed {
			if rec.Tag == TagArmed {
				e.adopt(rec)
				e.del(name)
			}
			// MAC-valid non-ARMED records pre-adoption are held: their
			// epoch cannot be judged until an ARMED names it.
			continue
		}
		if rec.Epoch != e.epoch {
			e.refuse(tag, RefuseStaleEpoch)
			e.del(name)
			continue
		}
		if seq <= e.lastIn[tag] {
			e.refuse(tag, RefuseStaleSeq)
			e.del(name)
			continue
		}
		switch tag {
		case TagArmed:
			if len(rec.Payload) < 1 {
				e.refuse(tag, RefuseBadRecord)
				e.del(name)
				continue
			}
			// A further ARMED in the same epoch re-adopts the mask — the
			// runner's authoritative re-declaration, seq-gated like all
			// inbound tags.
			e.lastIn[tag] = seq
			e.mask = rec.Payload[0]
			e.del(name)
			e.laneLog(e.Marker + " armed epoch=" + itoa(int64(rec.Epoch)) + " lanes=" + MaskNames(e.mask))
		case TagClipIn, TagClipInT, TagDrop, TagNotifyFocus:
			// Seat-consumed h→g tags. The mask bit is the consent posture:
			// a signed record for a lane the runner did not arm is a
			// consent_denied, per the ADR's reason mapping.
			if e.mask&LaneBit(tag) == 0 {
				e.refuse(tag, RefuseConsent)
				e.del(name)
				continue
			}
			if e.Consume == nil {
				e.refuse(tag, RefuseLaneDisabled)
				e.del(name)
				continue
			}
			if applied[tag] {
				continue // ≤ 1 per tag per tick — the rest queue for next Poll
			}
			applied[tag] = true
			reason := e.Consume(tag, rec)
			e.lastIn[tag] = seq
			e.del(name)
			if reason != "" {
				e.refuse(tag, reason)
			}
		default:
			// Outbound tags (CLIP_OUT, NOTIFY_OUT, OUTBOX) as files in the
			// lane dir are the seat's own unconsumed emissions — the runner
			// deletes them. A MAC-valid one is left alone either way.
		}
	}
}

// adopt takes a verified ARMED: adopt its epoch + lane_mask, book its seq,
// and announce — the seat's one line that says the lane is live.
func (e *Engine) adopt(rec Record) {
	if rec.Epoch == 0 || len(rec.Payload) < 1 {
		e.refuse(rec.Tag, RefuseBadRecord)
		return
	}
	e.armed = true
	e.epoch = rec.Epoch
	e.mask = rec.Payload[0]
	e.lastIn[TagArmed] = rec.Seq
	e.laneLog(e.Marker + " armed epoch=" + itoa(int64(rec.Epoch)) + " lanes=" + MaskNames(e.mask))
}

// del deletes one lane file through the seam, silently — a failed delete
// leaves a file the seq book has already consumed, and the stale_seq check
// next tick reports it then.
func (e *Engine) del(name string) {
	if e.io.Delete != nil {
		_ = e.io.Delete(name)
	}
}

// latchIOErr inserts name into the io_error latch and reports whether its
// refusal should be logged — false when the name was already latched (a
// still-failing file logs once, not once per tick). A full table resets:
// the flood case re-logs each live failure once per sweep and re-latches,
// bounded, rather than letting the map grow with a churn of dead names.
func (e *Engine) latchIOErr(name string) bool {
	if e.ioErrLatched == nil {
		e.ioErrLatched = map[string]bool{}
	}
	if e.ioErrLatched[name] {
		return false
	}
	if len(e.ioErrLatched) >= ioErrLatchCap {
		clear(e.ioErrLatched)
	}
	e.ioErrLatched[name] = true
	return true
}

// Outstanding counts the unconsumed lane files of one tag in the last
// successful Poll's listing — the producer's backpressure view.
func (e *Engine) Outstanding(tag uint8) int {
	n := 0
	stem := tagStem(tag) + "-"
	for _, it := range e.lastItems {
		if len(it.Name) > len(stem) && startsWith(it.Name, stem) {
			if _, _, ok := ParseName(it.Name); ok {
				n++
			}
		}
	}
	return n
}

// Emit signs and publishes one outbound record for tag (CLIP_OUT,
// NOTIFY_OUT, OUTBOX — the v1 form sends sender_id 0). The backpressure
// bound counts the tag's unconsumed files in this tick's listing. Returns
// the emitted seq or a refusal code; the success marker is the caller's
// because it is lane-specific.
func (e *Engine) Emit(tag uint8, flags uint8, payload []byte) (uint32, string) {
	return e.EmitSender(tag, flags, 0, payload)
}

// EmitSender is the v2 form: the record carries sender_id. Tags whose
// sender is nonzero are correlation records (NOTIFY_OUT naming the toast's
// source tab is M127c's user); the OUTBOX lane emits with sender 0.
func (e *Engine) EmitSender(tag uint8, flags uint8, sender uint16, payload []byte) (uint32, string) {
	if !e.armed {
		return 0, RefuseLaneDisabled
	}
	if bit := LaneBit(tag); bit == 0 || e.mask&bit == 0 {
		return 0, RefuseLaneDisabled
	}
	if len(payload) > PayloadMax {
		return 0, RefuseTooLarge
	}
	if e.Outstanding(tag) >= MaxOutstanding {
		return 0, RefuseBackpressure
	}
	seq := e.nextOut[tag] + 1
	rec := EncodeRecordSender(e.key, tag, flags, sender, seq, e.epoch, payload)
	if rec == nil {
		return 0, RefuseBadRecord
	}
	name := RecordName(tag, seq)
	if e.io.Write == nil || e.io.Write(name, rec) != 0 {
		return 0, RefuseIO
	}
	e.nextOut[tag] = seq
	return seq, ""
}

// insertionSort orders the lane filenames (bounded by the directory's small
// population; sort.Strings is not imported to keep the guest image lean).
func insertionSort(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

func startsWith(s, prefix string) bool {
	if len(s) < len(prefix) {
		return false
	}
	for i := 0; i < len(prefix); i++ {
		if s[i] != prefix[i] {
			return false
		}
	}
	return true
}

// itoa renders a non-negative decimal — the marker writer's vi.Itoa64
// equivalent without pulling fmt into the guest image.
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
