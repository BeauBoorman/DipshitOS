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
	// stateFmtVer is this serialization's own version — the first byte of
	// the blob. stateAppVer is the envelope appver the seat stores; both
	// are GOEDIT-owned (the seat never interprets either).
	stateFmtVer = 1
	stateAppVer = 1

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

// decodeState parses the blob. nil means the envelope arrived torn or with a
// foreign fmtVer — the caller's degrade is a plain open.
func decodeState(b []byte) *editState {
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

// --- the app's half of the lifecycle ----------------------------------------

// collectState snapshots the editor into an editState. hasBase is decided
// here: a dirty buffer whose file was saved mid-session needs the load-time
// bytes carried, because the file on the share is no longer the ring's
// anchor.
func (e *editor) collectState() *editState {
	st := &editState{
		dirty:    e.dirty,
		selSet:   e.selSet,
		cur:      e.cur,
		sel:      e.sel,
		path:     e.path,
		bufLen:   len(e.buf),
		bufHash:  fnv1a64(e.buf),
		diskLen:  e.diskLen,
		diskHash: e.diskHash,
		baseLen:  len(e.base),
		baseHash: fnv1a64(e.base),
		dropped:  e.hist.dropped,
		undo:     e.hist.undo,
		redo:     e.hist.redo,
		finds:    e.findHist,
		gotos:    e.gotoHist,
	}
	if st.dirty && (st.baseLen != st.diskLen || st.baseHash != st.diskHash) {
		st.hasBase = true
		st.base = e.base
	}
	return st
}

// saveState is the tabapp.SaveState hook — the seat's ask lands once per
// loop pass and gets this blob staged. Truncation is oldest-first: the redo
// head always, the undo head only while clean (a replayed dirty ring must
// stay whole). What still will not fit — or a ring histCap already evicted
// from — degrades to the shell, which restores the file and nothing else.
func (e *editor) saveState() []byte {
	st := e.collectState()
	if st.dirty && st.dropped != 0 {
		st.shell = true
	}
	b := st.encode()
	for len(b) > stateCapBytes && !st.shell {
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
		// The shell is bounded too: an absurd path plus full histories can
		// still exceed the cap. Histories trim oldest-first; a path that
		// alone will not fit stores nothing — never an oversized answer.
		for len(b) > stateCapBytes {
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

// noteState is the tabapp.RestoreState hook, run inside Init before the
// first paint — before the buffer exists. It only decodes and stashes:
// the path applies immediately so load() opens the blob's file (a re-exec'd
// GOEDIT gets no argv at all), the rest waits in pend for the buffer.
func (e *editor) noteState(b []byte) {
	st := decodeState(b)
	if st == nil {
		e.pendBad = true
		return
	}
	e.pend = st
	if st.path != "" {
		e.path = st.path
	}
}

// applyRestored runs right after load(): the file just read IS the blob's
// staleness witness. A mismatch — the file changed or went missing since
// the snapshot — degrades to the plain open load() already produced, which
// is the card's stale-blob rule. A dirty blob then replays its ring onto
// the base (the file itself when never saved, the carried bytes otherwise)
// and the buffer-hash check is the last word on splice integrity.
func (e *editor) applyRestored() {
	if e.pendBad {
		e.pendBad = false
		vi.ConsoleLine(markerState + "stale bad")
		return
	}
	st := e.pend
	e.pend = nil
	if st == nil {
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
	if st.shell {
		vi.ConsoleLine(markerState + "stale ring")
		return
	}
	if len(e.buf) != st.diskLen || fnv1a64(e.buf) != st.diskHash {
		vi.ConsoleLine(markerState + "stale file")
		return
	}
	if st.dirty {
		if st.dropped != 0 {
			vi.ConsoleLine(markerState + "stale ring")
			return
		}
		base := e.buf
		if st.hasBase {
			if len(st.base) != st.baseLen || fnv1a64(st.base) != st.baseHash {
				vi.ConsoleLine(markerState + "stale base")
				return
			}
			base = st.base
		}
		buf := base
		for _, o := range st.undo {
			buf = applySplices(buf, o.sp, false)
		}
		if len(buf) != st.bufLen || fnv1a64(buf) != st.bufHash {
			vi.ConsoleLine(markerState + "stale buf")
			return
		}
		e.buf = buf
		e.dirty = true
	}
	e.cur = st.cur
	e.clampCaret()
	if st.selSet {
		e.sel = st.sel
		if e.sel < 0 {
			e.sel = 0
		}
		if e.sel > len(e.buf) {
			e.sel = len(e.buf)
		}
		e.selSet = true
	}
	e.hist.undo = st.undo
	e.hist.redo = st.redo
	e.hist.open = false
	e.hist.dropped = st.dropped
	e.findHist = st.finds
	e.gotoHist = st.gotos
	selTag := "-"
	if lo, hi, ok := e.selRange(); ok {
		selTag = vi.Itoa64(int64(lo)) + ".." + vi.Itoa64(int64(hi))
	}
	vi.ConsoleLine(markerState + "restored cur=" + vi.Itoa64(int64(e.cur)) +
		" sel=" + selTag +
		" undo=" + vi.Itoa64(int64(len(e.hist.undo))) +
		" redo=" + vi.Itoa64(int64(len(e.hist.redo))) +
		" fh=" + vi.Itoa64(int64(len(e.findHist))) +
		" gh=" + vi.Itoa64(int64(len(e.gotoHist))))
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
