// M155b (issue #2930): marks and batch operations — "move three files
// into a folder in one gesture and watch it happen."
//
// `m` toggles a mark on the cursor row (at most maxMarks), `M` clears the
// set, and a marked row paints a '*' in the gutter while the status line
// counts the set. With marks present the act verbs take the set: c/x
// queue the whole marked set for paste, d arms one confirm for the count,
// and p runs the queued copy/move over the set.
//
// A batch never runs inside the keystroke: startBatch arms it and main
// steps ONE item per loop pass, so every item is its own painted frame —
// the status counter and the seat's progress row (vi.NotifyProgress
// through appkit.Progress.Report, M123c #2577) visibly advance. The first
// failure stops the run with a named marker that says what finished and
// what remains; nothing rolls back. Marks are transient working state —
// bound to the directory they were made in, pruned by refresh, and never
// serialized into the session blob (M125c's rule for selection sets,
// #2588).
package main

import (
	"strings"

	"virelai/appkit"
	"virelai/vi"
	"virelai/vsys"
)

const (
	// maxMarks bounds the marked set (the card's 64). The kernel's
	// dir_list window is 16 rows, so the bound is unreachable through the
	// UI today — it is the ceiling the type promises, pinned by the host
	// test against a seeded set.
	maxMarks = 64
	// batchOpID is this app's kind-22 operation id for the batch row in
	// the seat's notification center; one batch runs at a time, so one id
	// is the whole namespace.
	batchOpID uint8 = 1
	// batchSelf names the binary on the progress wire — the untagged
	// twin of main.go's appName (the same shape hintsBin already uses).
	batchSelf = "GOFILES.ELF"
)

// batchVerb is the operation a queued batch runs.
type batchVerb uint8

const (
	batchCopy batchVerb = iota + 1
	batchMove
	batchDelete
)

func (v batchVerb) word() string {
	switch v {
	case batchMove:
		return "move"
	case batchDelete:
		return "delete"
	default:
		return "copy"
	}
}

// past is the verb's completed form for the toast ("moved 3 files").
func (v batchVerb) past() string {
	switch v {
	case batchMove:
		return "moved"
	case batchDelete:
		return "deleted"
	default:
		return "copied"
	}
}

// batchOp is one armed multi-item operation. items are absolute source
// paths for copy/move and plain names under dir for delete (the marked
// names the confirm was answered for). dir is the destination for
// copy/move and the marked names' directory for delete — captured at arm
// time, so a mid-batch navigation can never retarget the run.
type batchOp struct {
	verb   batchVerb
	items  []string
	dir    string
	i      int  // next item index
	done   int  // completed items
	progNo bool // the seat report already refused once this batch
}

// --- marks --------------------------------------------------------------

// markCount is the live marked set's size: the set belongs to the
// directory it was made in, so away from that directory it reads as
// empty rather than lying about rows that are not on screen.
func (m *model) markCount() int {
	if m.marksDir != m.path {
		return 0
	}
	return len(m.marks)
}

// isMarked is the gutter-glyph lookup for one row's name.
func (m *model) isMarked(name string) bool {
	if m.marksDir != m.path {
		return false
	}
	_, ok := m.marks[name]
	return ok
}

// toggleMark is the `m` chord: mark the cursor row, or unmark it when it
// is already marked. Files only — a directory row refuses by name (the
// verbs a set feeds cannot take one: delete has no rmdir and clip is
// files-only). Marking into a different directory starts a fresh set
// there: the old directory's marks are dropped, because a mark the
// gutter cannot show is a mark the user cannot see.
func (m *model) toggleMark() {
	if m.atVolumes() {
		return
	}
	e, ok := m.selEntry()
	if !ok {
		m.status = "mark: nothing selected"
		return
	}
	name := e.NameString()
	if e.Dir() {
		m.emit(markerMarkNo + name + " (dir)")
		m.status = "mark: files only"
		return
	}
	if m.marksDir != m.path {
		m.marks = nil
		m.marksDir = m.path
	}
	if _, ok := m.marks[name]; ok {
		delete(m.marks, name)
		m.emit(markerUnmark + name + " n=" + vi.Itoa64(int64(len(m.marks))))
		m.status = "unmarked " + name
		return
	}
	if len(m.marks) >= maxMarks {
		m.emit(markerMarkNo + name + " bound=" + vi.Itoa64(maxMarks))
		m.status = "mark: at most 64"
		return
	}
	if m.marks == nil {
		m.marks = make(map[string]struct{})
	}
	m.marks[name] = struct{}{}
	m.emit(markerMark + name + " n=" + vi.Itoa64(int64(len(m.marks))))
	m.status = "marked " + name
}

// clearMarks is the `M` chord: drop the whole set. Clearing an empty set
// still says so — a silent no-op key would be indistinguishable from a
// dead binding.
func (m *model) clearMarks() {
	k := m.markCount()
	if k == 0 {
		m.status = "no marks"
		return
	}
	m.marks = nil
	m.marksDir = ""
	m.emit(markerMarksClear + "n=" + vi.Itoa64(int64(k)))
	m.status = "marks cleared"
}

// pruneMarks drops marks the current listing no longer holds — a file
// renamed, trashed or batch-moved away loses its mark instead of leaving
// a ghost the batch planner could feed.
func (m *model) pruneMarks() {
	if m.marksDir != m.path || len(m.marks) == 0 {
		return
	}
	for name := range m.marks {
		if !containsName(m.entries[:], m.n, name) {
			delete(m.marks, name)
		}
	}
}

// markedSet is the marked names in LISTING order — the batch's item
// order, so the progress sequence reads the same way the list did.
// Directories cannot be marked (toggleMark refuses), but the check is
// repeated here so a stale set can never smuggle one in.
func (m *model) markedSet() []string {
	if m.marksDir != m.path {
		return nil
	}
	var out []string
	for i := 0; i < m.n; i++ {
		if m.entries[i].Dir() {
			continue
		}
		name := m.entries[i].NameString()
		if _, ok := m.marks[name]; ok {
			out = append(out, name)
		}
	}
	return out
}

// --- the batch ------------------------------------------------------------

// startBatch arms a stepped batch over items: main drains it one item
// per pass so the seat's progress row and the in-pane counter advance
// between frames instead of blinking to done.
func (m *model) startBatch(verb batchVerb, items []string, dir string) {
	m.batch = batchOp{verb: verb, items: items, dir: dir}
	m.batchOn = true
	m.prog = appkit.Progress{Max: len(items), Op: batchOpID}
	n := len(items)
	m.emit(markerBatchStart + verb.word() + " n=" + vi.Itoa64(int64(n)))
	m.status = verb.word() + " 0/" + vi.Itoa64(int64(n))
	m.reportProgress()
}

// reportProgress posts the batch's current state to the seat (kind 22 —
// appkit.Progress.Report -> vi.NotifyProgress). A refusal is named once
// per batch: a seatless boot is the common case (the class-B runs exec
// the app on the kernel desktop), and spamming the line per item would
// hide the real sequence under it.
func (m *model) reportProgress() {
	if m.prog.Report(m.winID, batchSelf) {
		return
	}
	if !m.batch.progNo {
		m.batch.progNo = true
		m.emit(markerBatchProgNo)
	}
}

// batchStep runs the next queued item — the per-pass unit main calls
// while a batch is armed. Each item emits its own receipt in the single-op
// vocabulary (`gofiles: pasted`/`gofiles: deleted`) plus the `files:
// batch <verb> <k>/<n>` progress marker the seat report mirrors. The
// first failure stops the run: the stop marker names the item, what
// finished (done=) and what remains (left=, the failed item included),
// and nothing rolls back.
func (m *model) batchStep() {
	if !m.batchOn {
		return
	}
	b := &m.batch
	n := len(b.items)
	if b.i >= n {
		m.finishBatch()
		return
	}
	item := b.items[b.i]
	name := baseName(item)
	receipt, fail := m.batchItem(item)
	if fail != "" {
		m.batchOn = false
		m.emit(markerBatchStop + name + " " + fail +
			" done=" + vi.Itoa64(int64(b.done)) +
			" left=" + vi.Itoa64(int64(n-b.i)))
		m.prog.Label = b.verb.word() + " stopped"
		m.reportProgress()
		m.status = "batch stopped at " + name + " — " +
			vi.Itoa64(int64(b.done)) + " done, " +
			vi.Itoa64(int64(n-b.i)) + " left"
		m.refresh()
		m.status = "batch stopped at " + name
		return
	}
	b.i++
	b.done++
	k := b.i
	label := b.verb.word() + " " + vi.Itoa64(int64(k)) + "/" + vi.Itoa64(int64(n))
	switch b.verb {
	case batchDelete:
		m.emit(markerDeleted + name + " trash=" + receipt)
	default:
		m.emit(markerPasted + name)
	}
	m.emit(markerBatch + label + " " + name)
	m.prog.Label = label
	m.prog.Set(b.done)
	m.reportProgress()
	m.status = label
	if b.i >= n {
		m.finishBatch()
	}
}

// finishBatch closes a completed batch: the `files: batch done n=` marker
// ahead of the re-list (so a gate waiting on it sees the count before the
// refreshed rows), the toast in the single-op vocabulary, and the clip
// drop a move owes — a moved source cannot paste twice.
func (m *model) finishBatch() {
	b := &m.batch
	m.batchOn = false
	m.emit(markerBatchDone + vi.Itoa64(int64(b.done)))
	m.notifyToast(b.verb.past() + " " + vi.Itoa64(int64(b.done)) + " files")
	if b.verb == batchMove {
		m.clipSet = nil
	}
	m.status = "batch done n=" + vi.Itoa64(int64(b.done))
	m.refresh()
	m.status = "batch done n=" + vi.Itoa64(int64(b.done)) // refresh's "listed" must not mask it
}

// batchItem runs one queued item against the batch's captured directory.
// fail is "" on success or the refusal token the stop marker carries —
// "rc=-4" for a syscall answer, "cap" for the read-cap refusal a copy
// owes (the same boundary the single paste names).
func (m *model) batchItem(item string) (receipt, fail string) {
	b := &m.batch
	switch b.verb {
	case batchCopy:
		data, rc := readCapped(item, maxPasteBytes)
		if rc < 0 {
			return "", "rc=" + vi.Itoa64(rc)
		}
		if len(data) >= maxPasteBytes {
			return "", "cap"
		}
		if rc := pasteCopy(b.dir, item, data); rc < 0 {
			return "", "rc=" + vi.Itoa64(rc)
		}
		return "", ""
	case batchMove:
		if rc := pasteMove(b.dir, item); rc < 0 {
			return "", "rc=" + vi.Itoa64(rc)
		}
		return "", ""
	default: // batchDelete — items are names under dir
		id, rc := deleteEntry(b.dir, item)
		if rc < 0 {
			return "", "rc=" + vi.Itoa64(rc)
		}
		return id, ""
	}
}

// startPasteBatch is `p` over a queued SET: the planner answers every
// static refusal BEFORE the first item runs — a batch that half-started
// on a conflict anybody could see coming would be lying about the
// gesture. Same-volume and name-exists are the same rules the single
// paste holds; the batch names the offending item.
func (m *model) startPasteBatch() {
	if m.batchOn {
		m.status = "paste: a batch is running"
		return
	}
	verb := batchCopy
	if m.clipCut {
		verb = batchMove
	}
	for _, src := range m.clipSet {
		name := baseName(src)
		if _, ok := joinPath(m.path, name); !ok {
			m.emit(markerBatchNo + name + " path")
			m.status = "paste: path too long"
			return
		}
		if containsName(m.entries[:], m.n, name) {
			m.emit(markerBatchNo + name + " exists")
			m.status = "paste: " + name + " exists"
			return
		}
		if m.clipCut && volumeOf(src) != volumeOf(m.path) {
			m.emit(markerBatchNo + name + " cross-volume")
			m.status = "paste: a move stays on one volume"
			return
		}
	}
	m.startBatch(verb, m.clipSet, m.path)
}

// publishClipURIs is the machine-clipboard half of a copy yank (M124c
// #2582): text/uri-list, one file:// URI per line for a set. A cut
// publishes nothing — the URIs would name paths about to go stale. The
// refusal rides the same marker the single publish uses.
func (m *model) publishClipURIs(paths []string) {
	var b strings.Builder
	for i, p := range paths {
		if i > 0 {
			b.WriteByte('\n')
		}
		b.WriteString("file://")
		b.WriteString(p)
	}
	n, rc := vsys.ClipboardSetTyped(vsys.ClipURIList, []byte(b.String()))
	if rc < 0 {
		m.emit(markerClipSys + "rc=" + vi.Itoa64(rc))
	} else {
		m.emit(markerClipSys + "n=" + vi.Itoa64(int64(n)))
	}
}
