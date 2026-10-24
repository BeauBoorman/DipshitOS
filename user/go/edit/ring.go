package main

// ring.go — M166a (#2979): the buffer ring. One GOEDIT holds up to bufMax
// documents; the chrome row lists them, Ctrl-PageUp/PageDown page the ring
// (wrapping), Ctrl-W closes the active buffer, Ctrl-Shift-O opens a picked
// path into a new buffer, and a diagnostics row naming another file lands
// in that file's buffer instead of being refused dirty.
//
// The storage model: editor embeds the ACTIVE doc, so every pre-ring rule
// (load, save, the bars, draw, the diagnostics walk) addresses e.buf/e.cur
// unchanged — the embedded doc is the live register set, and docs[active]
// is the parked snapshot syncDocs refreshes on every switch-out and before
// every ring-wide walk. docs[i] for i != active IS that buffer's complete
// state: buffer, caret, selection, dirty flag, undo ring, lease, disk
// fingerprint and the find/goto histories all park with it.

import (
	"unicode/utf8"

	"virelai/appkit"
	"virelai/theme"
	"virelai/vi"
	"virelai/webrender/font"
)

// doc is one open buffer: the path, the bytes, the caret/selection and the
// session state that belongs to the file — the M81d lease, the disk
// fingerprint, the undo ring and the find/goto histories.
type doc struct {
	path     string
	buf      []byte
	base     []byte
	dirty    bool
	cur      int
	sel      int
	selSet   bool
	markOn   bool
	hist     history
	lease    *vi.FileLease
	diskLen  int
	diskHash uint64
	findHist [][]byte
	gotoHist []int
	// emptyShown is the M123b marker latch, per buffer: `goedit: empty`
	// prints once per transition into an empty buffer.
	emptyShown bool
	// folds is the M166b (#2987) fold table — open-sorted brace spans
	// whose middle lines are hidden. It parks with the buffer like the
	// rest of the doc state and never enters the session blob (the card's
	// out-of-scope list).
	folds []fold
	// heatSpans is the M166c (#2991) gutter map — the --prof= profile's
	// matched function spans with their heat bucket. heatDone marks it
	// current for the buffer's bytes; load() and every splice clear it
	// so the next paint remaps against the real offsets. It parks with
	// the buffer like folds and never enters the session blob.
	heatSpans []heatSpan
	heatDone  bool
}

// bufMax bounds the ring. Four buffers cover a compile-fix loop without a
// window per file; more is out of scope (the card's own bound).
const bufMax = 4

// docList is the ring for every walk that must see the live doc: it syncs
// e.doc into docs[active] and returns the slice. An editor built without a
// ring (a host-test literal) reads as one buffer.
func (e *editor) docList() []doc {
	if len(e.docs) == 0 {
		return []doc{e.doc}
	}
	e.syncDocs()
	return e.docs
}

// syncDocs parks the live doc into its ring slot. Cheap and idempotent —
// every ring-wide walk calls it (or docList, which does) before reading.
func (e *editor) syncDocs() {
	if e.active >= 0 && e.active < len(e.docs) {
		e.docs[e.active] = e.doc
	}
}

// docIndex finds an open path in the ring, or -1. The live doc counts: its
// path is e.path whether or not the slot was synced yet.
func (e *editor) docIndex(path string) int {
	for i, d := range e.docList() {
		if d.path == path {
			return i
		}
	}
	return -1
}

// activateDoc makes ring slot i the live doc, parking the outgoing one
// first: a pending dead-key accent commits into the buffer it was typed
// for, and both sides' run state closes so a typing burst never merges
// across a switch. selPub's dedup re-arms — the incoming doc may share the
// outgoing one's selection range while holding different bytes.
func (e *editor) activateDoc(i int) {
	if i == e.active || i < 0 || i >= len(e.docs) {
		return
	}
	_ = e.commitAll(e.stage.Flush())
	e.hist.breakRun()
	e.syncDocs()
	e.active = i
	e.doc = e.docs[i]
	e.hist.breakRun()
	selPubOK = false
}

// switchDoc is a user-visible activation — the receipt names the 1-based
// slot, the ring size and the buffer's path so the gate can pin all three.
func (e *editor) switchDoc(i int) {
	if i == e.active {
		return
	}
	e.activateDoc(i)
	vi.ConsoleLine(markerBufSwitch + vi.Itoa64(int64(i+1)) + "/" +
		vi.Itoa64(int64(len(e.docs))) + " path=" + e.path)
}

// switchBuf is Ctrl-PageDown/Ctrl-PageUp: the next and previous buffer,
// wrapping. A one-buffer ring has nothing to page — quiet no-op.
func (e *editor) switchBuf(d int) bool {
	n := len(e.docList())
	if n <= 1 {
		return true
	}
	e.switchDoc((e.active + d + n) % n)
	return true
}

// openBuf brings path into the ring: an already-open path switches to its
// buffer, a full ring is the named refusal, otherwise the path lands in a
// new buffer — read, caret-at-end, its own M81d lease — and becomes active.
func (e *editor) openBuf(path string) bool {
	e.docs = e.docList()
	if i := e.docIndex(path); i >= 0 {
		e.switchDoc(i)
		return true
	}
	if len(e.docs) >= bufMax {
		vi.ConsoleLine(markerBufFull + vi.Itoa64(int64(bufMax)))
		return false
	}
	e.docs = append(e.docs, doc{path: path})
	e.switchDoc(len(e.docs) - 1)
	e.load()
	if rc := e.ensureLease(); rc < 0 {
		vi.ConsoleLine(markerLeaseHeld + vi.Itoa64(rc))
	}
	return true
}

// closeBufAsk is Ctrl-W: the last buffer is the named refusal, a dirty
// buffer asks through the appkit confirm, a clean one closes outright.
func (e *editor) closeBufAsk() bool {
	if len(e.docList()) <= 1 {
		vi.ConsoleLine(markerBufLast)
		return true
	}
	if e.dirty {
		e.dlg = appkit.NewConfirm("Unsaved buffer", "Close the buffer and discard the unsaved changes?")
		e.closeAsk = true
		e.mode = modeDialog
		return true
	}
	e.closeDoc()
	return true
}

// closeDoc drops the active buffer: its lease releases, its bytes leave
// with it, and the following buffer (the previous one when it was last)
// becomes active — reported like any switch.
func (e *editor) closeDoc() {
	e.releaseLease()
	e.docs = append(e.docs[:e.active], e.docs[e.active+1:]...)
	if e.active >= len(e.docs) {
		e.active = len(e.docs) - 1
	}
	e.doc = e.docs[e.active]
	e.hist.breakRun()
	selPubOK = false
	vi.ConsoleLine(markerBufSwitch + vi.Itoa64(int64(e.active+1)) + "/" +
		vi.Itoa64(int64(len(e.docs))) + " path=" + e.path)
}

// ensureLeaseOf is ensureLease's per-doc half: acquire or refresh the
// advisory write lease on d's path. A refusal is the caller's sign to
// report and back off; a lease taken over meanwhile drops the stale handle
// so the next save retries from scratch.
func ensureLeaseOf(d *doc) int64 {
	if d.lease == nil {
		l, rc := vi.AcquireFileLease(d.path, appName)
		if rc < 0 {
			return rc
		}
		d.lease = l
		vi.ConsoleLine(markerLeaseOK + vi.Itoa64(int64(l.PID)))
		return 0
	}
	if rc := d.lease.Refresh(); rc < 0 {
		d.lease = nil
		return rc
	}
	return 0
}

// releaseLeaseOf drops d's lease. A lease taken over meanwhile belongs to
// the new holder and Release refuses to delete it — the marker says which
// happened, because the gates read these lines.
func releaseLeaseOf(d *doc) {
	if d.lease == nil {
		return
	}
	if rc := d.lease.Release(); rc >= 0 {
		vi.ConsoleLine(markerLeaseRel)
	} else {
		vi.ConsoleLine(markerLeaseRel + " rc=" + vi.Itoa64(rc))
	}
	d.lease = nil
}

// ensureLease acquires or refreshes the active buffer's lease (M81d
// #1764). The open-time call takes it for the session; every save
// re-stamps it first, so a session longer than vi.LeaseExpirySeconds
// renews instead of fighting its own record.
func (e *editor) ensureLease() int64 { return ensureLeaseOf(&e.doc) }

// releaseLease drops the active buffer's lease.
func (e *editor) releaseLease() { releaseLeaseOf(&e.doc) }

// releaseAllLeases is the exit path: every open buffer's lease drops, not
// just the active one's — a parked buffer's record stands on the share
// exactly like a live one's.
func (e *editor) releaseAllLeases() {
	e.syncDocs()
	for i := range e.docs {
		releaseLeaseOf(&e.docs[i])
	}
	e.doc.lease = nil
}

// drawBufRow paints the chrome row's buffer list: `1 NAME[*]  2 NAME[*]`
// with the active entry in Ink and the rest in InkMuted. Inactive names
// truncate from the LEFT until the row fits beside the right-aligned
// status text; the active name is the last resort. A one-buffer ring still
// shows its single entry — the row is the document's identity.
func (e *editor) drawBufRow(w, statusW, x0 int) {
	docs := e.docList()
	tok := theme.Current
	adv := font.Advance(1)
	names := make([]string, len(docs))
	for i, d := range docs {
		names[i] = baseOf(d.path)
	}
	cellW := func(i int) int { // entry i's width in cells
		n := len(vi.Itoa64(int64(i+1))) + 1 + utf8.RuneCountInString(names[i])
		if docs[i].dirty {
			n++
		}
		return n
	}
	total := 0
	for i := range docs {
		if i > 0 {
			total += 2 // the two-space separator
		}
		total += cellW(i)
	}
	avail := (w - x0 - textOrigin - statusW - 2) / adv
	if avail < 1 {
		avail = 1
	}
	// Drop leftmost runes of the LONGEST inactive name until the row fits.
	for total > avail {
		best, bestN := -1, 0
		for i := range docs {
			if i == e.active {
				continue
			}
			if n := utf8.RuneCountInString(names[i]); n > bestN {
				best, bestN = i, n
			}
		}
		if best < 0 {
			// Inactive names bottomed out — the active name truncates
			// too. The alternative is painting over the status text.
			if utf8.RuneCountInString(names[e.active]) <= 1 {
				break
			}
			best = e.active
		}
		_, sz := utf8.DecodeRuneInString(names[best])
		names[best] = names[best][sz:]
		total--
	}
	x := x0
	for i, d := range docs {
		if i > 0 {
			x += 2 * adv
		}
		col := tok.InkMuted
		if i == e.active {
			col = tok.Ink
		}
		name := names[i]
		if d.dirty {
			name += "*"
		}
		e.drawText(x, 8, vi.Itoa64(int64(i+1))+" "+name, col)
		x += cellW(i) * adv
	}
}
