// state.go — M125b (#2587): GOEDIT's half of the M125a per-app state
// protocol. The seat stores and hands back a blob verbatim; the format is
// the app's own and fmtVer inside it is GOEDIT's refusal check for a stale
// serialization — a torn, short or foreign blob decodes to nothing and the
// restore degrades to opening the path, never a crash.
//
// What the blob carries and what it deliberately does not:
//
//   - the file path — the seat's re-exec runs the bare bin, so argv never
//     arrives at a restored session; the blob is the only place the file
//     lives.
//   - caret, selection anchor, dirty flag, the undo/redo rings, and the
//     bounded find/goto history.
//   - fingerprints: the buffer's (bufLen/bufHash), the file-on-disk's at
//     snapshot time (diskLen/diskHash) and the load-time content's
//     (baseLen/baseHash). The disk pair is the staleness check: a file
//     changed or missing under the stored blob degrades the restore.
//
// Unsaved-buffer recovery IS the undo ring, exactly as the card scopes it:
// the live invariant `buf = applySplices(base, undo)` means replaying the
// whole ring onto the load-time content rebuilds the unsaved buffer.
// When the file was saved mid-session the on-disk bytes are no longer the
// ring's anchor, so the base bytes ride the blob too (hasBase). A ring a
// full histCap already evicted from (dropped>0) cannot replay — that is
// "beyond the undo ring" and the restore degrades. Rings the blob cannot
// afford are truncated oldest-first: redo first (it only powers future
// redos), then undo — but only while clean, where restore never replays
// at all and a shorter ring just means shallower undo. A dirty session
// that cannot fit falls back to a path-only "shell" blob.
package main

import "virelai/vi"

const (
	// stateFmtVer is the per-record serialization's own version — the
	// first byte of each record. stateFmtVer2 is the OUTER blob's version:
	// M166a (#2979) wraps one record per open buffer (u8 ver, u8 count,
	// then u32-len-prefixed records), so the envelope doubles as the ring.
	// stateAppVer is the envelope appver the seat stores; it stays 1 — a
	// format-1 blob still decodes (as one record) and the seat's
	// RestoredVersion check must not refuse it. All are GOEDIT-owned (the
	// seat never interprets any of them).
	stateFmtVer  = 1
	stateFmtVer2 = 2
	stateAppVer  = 1

	// findHistCap/gotoHistCap bound the find/goto history — the newest
	// entries are the ones a user would miss.
	findHistCap = 8
	gotoHistCap = 8

	stateCapBytes = vi.AppStateMax // 64 KiB — the envelope's bound

	flagDirty   = 1 << 0 // the buffer had unsaved edits at snapshot
	flagSelSet  = 1 << 1 // sel carries a live selection anchor
	flagHasBase = 1 << 2 // base bytes follow baseHash (saved mid-session)
	flagShell   = 1 << 3 // path-only degrade: rings did not fit / could not replay
)

// editState is the decoded blob. The integer/hashes are the cheap prechecks;
// base is present only under flagHasBase.
type editState struct {
	dirty, selSet, hasBase, shell bool
	cur, sel                      int
	path                          string
	bufLen                        int
	bufHash                       uint64
	diskLen                       int
	diskHash                      uint64
	baseLen                       int
	baseHash                      uint64
	base                          []byte
	dropped                       int
	undo, redo                    []editOp
	finds                         [][]byte
	gotos                         []int
}

// fnv1a64 is the same hash the lease record's path naming uses (vi's
// leaseHash rule): a cheap fingerprint for "same bytes", never a checksum
// a hostile blob could be trusted against — it guards accidents, and a
// colliding stale blob still only restores an older self-consistent state.
func fnv1a64(b []byte) uint64 {
	h := uint64(0xcbf29ce484222325)
	for _, c := range b {
		h ^= uint64(c)
		h *= 0x100000001b3
	}
	return h
}

// --- bounded encode --------------------------------------------------------

// enc is the append cursor. Every writer is infallible; the cap check runs
// on the finished length.
type enc struct{ out []byte }

func (w *enc) u8(v int)  { w.out = append(w.out, byte(v)) }
func (w *enc) u16(v int) { w.out = append(w.out, byte(v), byte(v>>8)) }
func (w *enc) u32(v int) { w.out = append(w.out, byte(v), byte(v>>8), byte(v>>16), byte(v>>24)) }
func (w *enc) u64(v uint64) {
	for i := 0; i < 8; i++ {
		w.out = append(w.out, byte(v>>(8*uint(i))))
	}
}
func (w *enc) bytes(b []byte) { w.out = append(w.out, b...) }

func (w *enc) op(o editOp) {
	w.u8(int(o.kind))
	w.u32(len(o.sp))
	for _, s := range o.sp {
		w.u32(s.pos)
		w.u32(len(s.old))
		w.bytes(s.old)
		w.u32(len(s.ins))
		w.bytes(s.ins)
	}
}

func (w *enc) ring(r []editOp) {
	w.u32(len(r))
	for _, o := range r {
		w.op(o)
	}
}

// encode renders the blob. shell strips everything but identity — path and
// the find/goto history — so an over-cap dirty session still reopens the
// right file instead of leaving nothing for the seat to store.
func (st *editState) encode() []byte {
	w := &enc{}
	flags := 0
	if st.dirty {
		flags |= flagDirty
	}
	if st.selSet {
		flags |= flagSelSet
	}
	if st.hasBase {
		flags |= flagHasBase
	}
	if st.shell {
		flags |= flagShell
	}
	w.u8(stateFmtVer)
	w.u8(flags)
	w.u32(st.cur)
	w.u32(st.sel)
	w.u16(len(st.path))
	w.bytes([]byte(st.path))
	if st.shell {
		w.u8(len(st.finds))
		for _, f := range st.finds {
			w.u16(len(f))
			w.bytes(f)
		}
		w.u8(len(st.gotos))
		for _, g := range st.gotos {
			w.u32(g)
		}
		return w.out
	}
	w.u32(st.bufLen)
	w.u64(st.bufHash)
	w.u32(st.diskLen)
	w.u64(st.diskHash)
	w.u32(st.baseLen)
	w.u64(st.baseHash)
	if st.hasBase {
		w.bytes(st.base)
	}
	w.u32(st.dropped)
	w.ring(st.undo)
	w.ring(st.redo)
	w.u8(len(st.finds))
	for _, f := range st.finds {
		w.u16(len(f))
		w.bytes(f)
	}
	w.u8(len(st.gotos))
	for _, g := range st.gotos {
		w.u32(g)
	}
	return w.out
}

// --- tolerant decode --------------------------------------------------------
// Every read bounds-checks before slicing; one overrun marks the decode bad
// and the whole blob is refused — a stale serialization is never trusted
// halfway.

type dec struct {
	b   []byte
	off int
	bad bool
}

func (d *dec) take(n int) []byte {
	if d.bad || n < 0 || d.off+n > len(d.b) {
		d.bad = true
		return nil
	}
	s := d.b[d.off : d.off+n]
	d.off += n
	return s
}

func (d *dec) u8() int {
	s := d.take(1)
	if s == nil {
		return 0
	}
	return int(s[0])
}

func (d *dec) u16() int {
	s := d.take(2)
	if s == nil {
		return 0
	}
	return int(s[0]) | int(s[1])<<8
}

func (d *dec) u32() int {
	s := d.take(4)
	if s == nil {
		return 0
	}
	return int(s[0]) | int(s[1])<<8 | int(s[2])<<16 | int(s[3])<<24
}

func (d *dec) u64() uint64 {
	s := d.take(8)
	if s == nil {
		return 0
	}
	var v uint64
	for i := 0; i < 8; i++ {
		v |= uint64(s[i]) << (8 * uint(i))
	}
	return v
}

// decOp reads one editOp. Splice counts and byte runs are only ever bounded
// by the blob's own remaining length, so a lying count fails the next take
// rather than allocating or panicking.
func (d *dec) decOp() editOp {
	kind := d.u8()
	nsp := d.u32()
	o := editOp{kind: opKind(kind)}
	for i := 0; i < nsp && !d.bad; i++ {
		s := splice{pos: d.u32()}
		if n := d.u32(); !d.bad {
			s.old = append([]byte{}, d.take(n)...)
		}
		if n := d.u32(); !d.bad {
			s.ins = append([]byte{}, d.take(n)...)
		}
		o.sp = append(o.sp, s)
	}
	// A kind the codec does not know still decodes; it only loses merge
	// continuation, which a restore never needs anyway.
	if o.kind > opEdit {
		o.kind = opEdit
	}
	return o
}

// decodeRecord parses one v1 record — a whole format-1 blob, or one
// u32-prefixed member of a format-2 blob. nil means it arrived torn or
// with a foreign fmtVer — the caller's degrade is a plain open.
func decodeRecord(b []byte) *editState {
	d := &dec{b: b}
	if d.u8() != stateFmtVer {
		return nil
	}
	flags := d.u8()
	st := &editState{
		dirty:   flags&flagDirty != 0,
		selSet:  flags&flagSelSet != 0,
		hasBase: flags&flagHasBase != 0,
		shell:   flags&flagShell != 0,
	}
	st.cur = d.u32()
	st.sel = d.u32()
	if n := d.u16(); !d.bad {
		st.path = string(d.take(n))
	}
	if !st.shell {
		st.bufLen = d.u32()
		st.bufHash = d.u64()
		st.diskLen = d.u32()
		st.diskHash = d.u64()
		st.baseLen = d.u32()
		st.baseHash = d.u64()
		if st.hasBase {
			st.base = append([]byte{}, d.take(st.baseLen)...)
		}
		st.dropped = d.u32()
		for n := d.u32(); n > 0 && !d.bad; n-- {
			st.undo = append(st.undo, d.decOp())
		}
		for n := d.u32(); n > 0 && !d.bad; n-- {
			st.redo = append(st.redo, d.decOp())
		}
	}
	nf := d.u8()
	for i := 0; i < nf && !d.bad; i++ {
		if n := d.u16(); !d.bad {
			if f := d.take(n); f != nil && len(st.finds) < findHistCap {
				st.finds = append(st.finds, append([]byte{}, f...))
			}
		}
	}
	ng := d.u8()
	for i := 0; i < ng && !d.bad; i++ {
		if g := d.u32(); !d.bad && len(st.gotos) < gotoHistCap {
			st.gotos = append(st.gotos, g)
		}
	}
	if d.bad {
		return nil
	}
	return st
}

// decodeState parses the session blob into its records. A format-1 blob is
// one record; a format-2 blob is u8 ver + u8 count + count u32-len-prefixed
// records, active buffer first. nil means the envelope arrived torn or
// with a foreign version — the caller's degrade is a plain open.
func decodeState(b []byte) []*editState {
	if len(b) == 0 {
		return nil
	}
	if b[0] == stateFmtVer {
		st := decodeRecord(b)
		if st == nil {
			return nil
		}
		return []*editState{st}
	}
	if b[0] != stateFmtVer2 {
		return nil
	}
	d := &dec{b: b}
	d.u8() // the outer version
	n := d.u8()
	var out []*editState
	for i := 0; i < n && !d.bad; i++ {
		l := d.u32()
		rec := d.take(l)
		if rec == nil {
			return nil
		}
		st := decodeRecord(rec)
		if st == nil {
			return nil
		}
		out = append(out, st)
	}
	if d.bad || len(out) != n {
		return nil
	}
	return out
}

// --- the app's half of the lifecycle ----------------------------------------

// collectState snapshots the doc into an editState. hasBase is decided
// here: a dirty buffer whose file was saved mid-session needs the
// load-time bytes carried, because the file on the share is no longer the
// ring's anchor.
func (d *doc) collectState() *editState {
	st := &editState{
		dirty:    d.dirty,
		selSet:   d.selSet,
		cur:      d.cur,
		sel:      d.sel,
		path:     d.path,
		bufLen:   len(d.buf),
		bufHash:  fnv1a64(d.buf),
		diskLen:  d.diskLen,
		diskHash: d.diskHash,
		baseLen:  len(d.base),
		baseHash: fnv1a64(d.base),
		dropped:  d.hist.dropped,
		undo:     d.hist.undo,
		redo:     d.hist.redo,
		finds:    d.findHist,
		gotos:    d.gotoHist,
	}
	if st.dirty && (st.baseLen != st.diskLen || st.baseHash != st.diskHash) {
		st.hasBase = true
		st.base = d.base
	}
	return st
}

// shrinkRecord is saveState's per-record budget pass: the same oldest-first
// truncation the v1 blob ran (redo head always, undo head only while clean),
// the same shell degrade when a dirty ring cannot fit intact, and the same
// shell-side history trim — only the budget changed, from the whole
// envelope to whatever the outer blob still has. nil means even a shell
// record will not fit: the record is dropped, never an oversized answer.
func shrinkRecord(st *editState, budget int) []byte {
	if st.dirty && st.dropped != 0 {
		st.shell = true
	}
	b := st.encode()
	for len(b) > budget && !st.shell {
		switch {
		case len(st.redo) > 0:
			st.redo = st.redo[1:]
		case !st.dirty && len(st.undo) > 0:
			st.undo = st.undo[1:]
		default:
			st.shell = true
		}
		b = st.encode()
	}
	if st.shell {
		st.dirty, st.selSet, st.hasBase = false, false, false
		st.base, st.undo, st.redo, st.dropped = nil, nil, nil, 0
		st.cur, st.sel = 0, 0
		b = st.encode()
		for len(b) > budget {
			switch {
			case len(st.finds) > 0:
				st.finds = st.finds[1:]
			case len(st.gotos) > 0:
				st.gotos = st.gotos[1:]
			default:
				return nil
			}
			b = st.encode()
		}
	}
	return b
}

// saveState is the tabapp.SaveState hook — the seat's ask lands once per
// loop pass and gets this blob staged. M166a (#2979): format 2 — one record
// per open buffer, the ACTIVE buffer's record first, then the rest in ring
// order. Each record is a full v1 record while the remaining budget fits
// it, else the shell degrade; a record even a shell cannot fit is dropped
// from the blob, never an oversized answer.
func (e *editor) saveState() []byte {
	docs := e.docList()
	var recs [][]byte
	used := 2 // the outer ver + count
	emit := func(i int) {
		st := docs[i].collectState()
		if b := shrinkRecord(st, stateCapBytes-used-4); b != nil {
			recs = append(recs, b)
			used += 4 + len(b)
		}
	}
	emit(e.active)
	for i := range docs {
		if i != e.active {
			emit(i)
		}
	}
	w := &enc{}
	w.u8(stateFmtVer2)
	w.u8(len(recs))
	for _, b := range recs {
		w.u32(len(b))
		w.bytes(b)
	}
	return w.out
}

// noteState is the tabapp.RestoreState hook, run inside Init before the
// first paint — before the buffer exists. It only decodes and stashes:
// record 0's path applies immediately so load() opens the blob's file (a
// re-exec'd GOEDIT gets no argv at all), the rest waits in pend for the
// buffer.
func (e *editor) noteState(b []byte) {
	sts := decodeState(b)
	if sts == nil {
		e.pendBad = true
		return
	}
	e.pend = sts
	if len(sts) > 0 && sts[0].path != "" {
		e.path = sts[0].path
	}
}

// applyRecord lands one decoded record on a doc whose buf/base/disk
// fingerprint are already loaded — the load just performed IS the blob's
// staleness witness. Returns "" on a full apply, "shell" for a shell
// record (the path+caret degrade), else the stale reason name: a file that
// changed or went missing under the blob degrades to the plain open, and a
// dirty record replays its ring onto the base — the buffer-hash check the
// last word on splice integrity.
func applyRecord(d *doc, st *editState) string {
	if st.shell {
		return "shell"
	}
	if len(d.buf) != st.diskLen || fnv1a64(d.buf) != st.diskHash {
		return "file"
	}
	if st.dirty {
		if st.dropped != 0 {
			return "ring"
		}
		base := d.buf
		if st.hasBase {
			if len(st.base) != st.baseLen || fnv1a64(st.base) != st.baseHash {
				return "base"
			}
			base = st.base
		}
		buf := base
		for _, o := range st.undo {
			buf = applySplices(buf, o.sp, false)
		}
		if len(buf) != st.bufLen || fnv1a64(buf) != st.bufHash {
			return "buf"
		}
		d.buf = buf
		d.dirty = true
	}
	d.cur = st.cur
	if d.cur < 0 {
		d.cur = 0
	}
	if d.cur > len(d.buf) {
		d.cur = len(d.buf)
	}
	if st.selSet {
		d.sel = st.sel
		if d.sel < 0 {
			d.sel = 0
		}
		if d.sel > len(d.buf) {
			d.sel = len(d.buf)
		}
		d.selSet = true
	}
	d.hist.undo = st.undo
	d.hist.redo = st.redo
	d.hist.open = false
	d.hist.dropped = st.dropped
	d.findHist = st.finds
	d.gotoHist = st.gotos
	return ""
}

// restoreDoc reads one extra record's file and applies the record to the
// doc value it returns — the non-active half of a format-2 restore. The
// degrade shapes match the active doc's: a missing file is the create path
// (empty buffer at the path), a changed file opens its live bytes clean —
// both count as shells in the marker because no record state rode back.
func (e *editor) restoreDoc(d *doc, st *editState) string {
	b, rc := bufRead(d.path, maxBuffer)
	if rc < 0 {
		d.buf, d.base, d.diskLen, d.diskHash = nil, nil, 0, fnv1a64(nil)
		return "shell"
	}
	d.buf, d.base, d.diskLen, d.diskHash = b, b, len(b), fnv1a64(b)
	d.cur = len(b)
	out := applyRecord(d, st)
	if out == "file" || out == "shell" {
		return "shell" // a plain open either way — the file or the shell record
	}
	if out != "" {
		return out // ring/base/buf degrades keep the loaded buffer
	}
	return ""
}

// applyRestored runs right after load(): the file just read IS record 0's
// staleness witness, applied to the active doc exactly as the v1 restore
// did. The format-2 records after it restore as the ring's other buffers —
// each opens its file and takes its own lease — and the marker keeps its
// v1 prefix with ` bufs=<n> shell=<m>` appended (m counts the buffers that
// came back without their record state: shell records and degrades).
func (e *editor) applyRestored() {
	if e.pendBad {
		e.pendBad = false
		vi.ConsoleLine(markerState + "stale bad")
		return
	}
	sts := e.pend
	e.pend = nil
	if len(sts) == 0 {
		return
	}
	// The envelope's appver is the seat-visible tag; RestoredVersion is the
	// app's check for a stale serialization. noteState runs inside Init
	// before e.ta exists, so the check lands here — a foreign version is
	// refused even though the blob itself decoded (the formats may share
	// a first byte by accident).
	if e.ta != nil && e.ta.RestoredVersion != stateAppVer {
		vi.ConsoleLine(markerState + "stale version")
		return
	}
	e.docs = e.docList()
	outcome := applyRecord(&e.doc, sts[0])
	shells := 0
	for _, st := range sts[1:] {
		if st == nil || st.path == "" {
			continue
		}
		d := doc{path: st.path}
		if out := e.restoreDoc(&d, st); out != "" {
			shells++
		}
		e.docs = append(e.docs, d)
	}
	if outcome == "shell" {
		shells++
	}
	switch outcome {
	case "":
		selTag := "-"
		if lo, hi, ok := e.selRange(); ok {
			selTag = vi.Itoa64(int64(lo)) + ".." + vi.Itoa64(int64(hi))
		}
		vi.ConsoleLine(markerState + "restored cur=" + vi.Itoa64(int64(e.cur)) +
			" sel=" + selTag +
			" undo=" + vi.Itoa64(int64(len(e.hist.undo))) +
			" redo=" + vi.Itoa64(int64(len(e.hist.redo))) +
			" fh=" + vi.Itoa64(int64(len(e.findHist))) +
			" gh=" + vi.Itoa64(int64(len(e.gotoHist))) +
			" bufs=" + vi.Itoa64(int64(len(e.docs))) +
			" shell=" + vi.Itoa64(int64(shells)))
	case "shell":
		vi.ConsoleLine(markerState + "stale ring")
	default:
		vi.ConsoleLine(markerState + "stale " + outcome)
	}
	// Leases: each restored buffer takes its own M81d lease for the session,
	// the same acquire the boot path runs for the active one.
	for i := range e.docs {
		if i == e.active {
			continue
		}
		if rc := ensureLeaseOf(&e.docs[i]); rc < 0 {
			vi.ConsoleLine(markerLeaseHeld + vi.Itoa64(rc))
		}
	}
}

// pushFind records one find-bar run's pattern — the bounded newest-last
// history the session state carries. pat aliases the bar's storage, so the
// entry is a copy.
func (e *editor) pushFind(pat []byte) {
	if len(pat) == 0 {
		return
	}
	e.findHist = append(e.findHist, append([]byte{}, pat...))
	if len(e.findHist) > findHistCap {
		copy(e.findHist, e.findHist[1:])
		e.findHist = e.findHist[:findHistCap]
	}
}

// pushGoto records one goto-bar run's parsed line.
func (e *editor) pushGoto(n int) {
	e.gotoHist = append(e.gotoHist, n)
	if len(e.gotoHist) > gotoHistCap {
		copy(e.gotoHist, e.gotoHist[1:])
		e.gotoHist = e.gotoHist[:gotoHistCap]
	}
}
