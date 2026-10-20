// GOTABWM.ELF — M81g (#1767): the snapshot bundle, and the restore drill.
//
// The card's deliverable is the DRILL, not the archive step: state a person
// would hate to lose (the settings table, the session strip, a selection of
// documents) goes into one crash-safe bundle under a standard path, and a
// fresh boot rehydrates from it byte-exact. The container itself is
// virelai/snapshot — one codec, two consumers, the M71f arrangement — so the
// bytes the self-test proves are the bytes this seat restores.
//
// # Restore is a FILE rehydration, not a state injection
//
// The restore writes the bundle's entries back to the share through the SAME
// crash-safe publish everything else uses (vi.WriteFileSafe: temp + fsync +
// delete/rename), and then the seat's ordinary boot continues: loadSettings
// and loadSession read the files they always read. That is deliberate, and it
// is why this card needs no change to either of them:
//
//   - a restored settings table is decoded by the M66b path, so a restored
//     file that is somehow still bad produces the SAME "settings bad" line
//     and the SAME compiled defaults a hand-corrupted file does;
//   - a restored SESSION.TABS is applied by the M62e path, so the restored
//     strip carries the same placeholder-id and freeze semantics.
//
// Restore therefore adds a way for the three files to BE there before the
// boot reads them, and no new way for them to be wrong.
//
// # All-or-nothing
//
// snapshot.Parse validates the WHOLE container before this file writes a
// single byte, so a bundle whose last entry is corrupt has not already
// republished its first. A corrupt or absent bundle is refused WHOLE: no
// entry is written, the live files are left exactly as they were, and the
// seat's existing corrupt-fails-closed handling takes over — compiled
// defaults, an empty strip, never a boot failure. That is the M66b
// corrupt-settings behavior, reused verbatim rather than reimplemented.
//
// The one thing that is not all-or-nothing is an I/O error partway through a
// VALID bundle: the entries validated, and a failed publish leaves that one
// file either its old bytes or absent (never garbage — that is what the safe
// publish buys). A failed step is named on its own marker, so a partial
// restore is reported as partial and never claimed as byte-exact.
//
// # The drill is opt-in, in both directions
//
// Neither half runs on its own: a bundle is not taken because time passed
// (no scheduled snapshots), and it is not applied because it happens to exist
// (which would silently rewind every later boot to the snapshot).
//
//   - SAVE is a chord the person presses: Ctrl+Shift+S (see hid.go). It is
//     the on-demand shape the card asks for.
//   - RESTORE is a one-shot REQUEST staged on the share: a
//     /host/SNAPSHOT.RESTORE file. The seat consumes it either way, so a
//     corrupt bundle cannot poison every later boot and a good one restores
//     exactly once. This is the same explicit-trigger idiom as the seat's
//     existing GOTABWM.DEMO mode file (M79a), and it is what lets a gate
//     stage "restore this into a fresh boot" without a kernel verb.
package main

import (
	"virelai/settings"
	"virelai/snapshot"
	"virelai/vi"
)

const (
	// bundlePath is the standard place the bundle lives. It is a top-level
	// share file beside SETTINGS.TXT and SESSION.TABS, so the three things a
	// restore carries are all reachable by a person with a file manager.
	bundlePath = "/host/SNAPSHOT.BUNDLE"
	// restoreFlag is the one-shot request: stage this file on the share and
	// the next seat boot rehydrates from bundlePath.
	restoreFlag = "/host/SNAPSHOT.RESTORE"
	// docsDir is the documents selection's root. Only this directory is
	// captured and only into this directory is a restore written, so a
	// bundle can never place a file outside it.
	docsDir = "/host/DOCS"

	// maxDocs bounds the documents selection. The kernel's sys_dir_list
	// window is 16 entries (vi.MaxDirEntries), so a selection is a bounded
	// prefix of what a listing can even see; 6 leaves room for the two
	// state entries plus headroom under the 8-entry container cap.
	maxDocs = 6
	// maxDocBytes bounds ONE captured document. A document larger than this
	// is SKIPPED, not truncated: a half-copied document restored later
	// would be worse than a document that was honestly left out, and the
	// `docs=` count on the marker says how many actually went in.
	maxDocBytes = 8 * 1024
	// maxBundleRead reads one byte past the cap, so a bundle LARGER than the
	// container allows is refused whole rather than silently truncated into
	// something that would still parse (the settings stat gate's shape).
	maxBundleRead = snapshot.MaxBundle + 1

	// Marker lines the class-B gates grep. Each prints only AFTER the
	// syscall that made it true (the M57a discipline): the `saved` and
	// `restore` lines after the last publish returned, the refusals after
	// the read that refused.
	MarkerSnapshotSaved   = "gotabwm: snapshot saved "
	MarkerSnapshotRestore = "gotabwm: snapshot restore "
	MarkerSnapshotBad     = "gotabwm: snapshot bad "
	MarkerSnapshotMissing = "gotabwm: snapshot missing"
	MarkerSnapshotFail    = "gotabwm: snapshot fail "
	// MarkerSnapshotPersist is the one condition that weakens the one-shot
	// guarantee: the request could not be consumed, so it is still on the
	// share and the NEXT boot will try the same bundle again. It never
	// changes this boot's verdict — a restore that worked worked, a refusal
	// still refused — it only says out loud that the guarantee did not hold.
	MarkerSnapshotPersist = "gotabwm: snapshot request persist "
)

// The share calls the bundle is written through. Vars, not direct calls, for
// the reason session.go's writeHostFile is a var: vi.WriteFileSafe goes
// through the raw syscall gateway and degrades to -ENOSYS off the guest, which
// would make the whole capture/restore path unobservable to a host test. The
// execApp / closeWin pattern again (hid.go, interop.go).
var (
	snapWrite  = vi.WriteFileSafe
	snapRead   = vi.ReadFileAll
	snapList   = vi.DirList
	snapExists = vi.FileExists
	snapDelete = vi.FileDelete
	// snapLog is the marker sink, a var for the same reason the rest are:
	// vi.ConsoleLine goes to the console device, so off-guest the ORDER
	// discipline this card is judged on — a marker only AFTER the syscall
	// that made it true — would be untestable. With a recorder the tests
	// assert a refusal line exists and that it did not appear before the
	// read that refused.
	snapLog   = vi.ConsoleLine
	snapMkdir = func(path string) int64 {
		// MODE_DIR creates the directory, but the kernel's open validation
		// wants it together with MODE_WRITE|MODE_CREATE (the same triple
		// user/go/git and the self-test use). "Already exists" (-9) is not
		// an error: a pre-created DOCS must not fail a capture or a restore.
		h, rc := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
		if rc >= 0 {
			vi.FileClose(uint32(h))
		}
		return rc
	}
)

// captureBundle reads the state the bundle carries and encodes it. It reports
// the encoded bytes, the entry count, the documents count and whether the
// capture is honest.
//
// A MISSING settings file or session file is not a capture failure: a fresh
// share has neither, and "this bundle restores a boot with no settings and no
// session" is a true thing to say. Such an entry is simply ABSENT from the
// bundle, so restoring it leaves that file missing — which every reader
// already treats as defaults. (A negative read is how both settings.Load and
// restoreSessionBytes spell "missing" too, so there is no second kind of read
// failure to tell apart here.)
//
// What IS a failure is having nothing to carry: snapshot.Build refuses an
// empty entry list, so a share with no settings, no session and no documents
// reports a failed capture instead of publishing an empty container and calling
// it a snapshot. That is why the absent case `continue`s rather than returning
// — an early return here would claim success while the bundle was still nil.
func captureBundle() ([]byte, int, int, bool) {
	var entries []snapshot.Entry
	if b, rc := snapRead(settings.Path, settings.MaxBody+1); rc >= 0 && b != nil {
		entries = append(entries, snapshot.Entry{Name: snapshot.EntrySettings, Body: b})
	}
	// M125a (#2586): the session entry may now carry an app_state trailer,
	// so the file bound is the codec's own cap — an oversize read is a
	// truncation the bundle must not silently carry, so it is skipped.
	if b, rc := snapRead(sessionPath, tabsV2MaxBytes+1); rc >= 0 && b != nil && len(b) <= tabsV2MaxBytes {
		entries = append(entries, snapshot.Entry{Name: snapshot.EntrySession, Body: b})
	}
	// M137a (#2771): the pane-tree sidecar rides the bundle too, so a
	// restore on a fresh share still rehydrates the split layout. Absent
	// is the unsplit shape, exactly like the session file's own missing
	// rule.
	if b, rc := snapRead(panesPath, panesMaxBytes+1); rc >= 0 && b != nil && len(b) <= panesMaxBytes {
		entries = append(entries, snapshot.Entry{Name: snapshot.EntryPanes, Body: b})
	}
	docs := captureDocs()
	for _, d := range docs {
		entries = append(entries, d)
	}
	raw, ok := snapshot.Build(entries)
	if !ok {
		return nil, 0, 0, false
	}
	// The docs count is captureDocs' OWN length, never a subtraction from
	// the entry count: either state entry may be legitimately absent, and a
	// marker that guessed would misreport the selection.
	return raw, len(entries), len(docs), true
}

// captureDocs is the documents selection: the maxDocs alphabetically-first
// regular files of docsDir. Sorting is not decoration — it makes the encoded
// bundle a function of the directory's CONTENTS rather than of the order the
// host happened to hand back, so the same share captures the same bytes twice
// and a gate can compare a capture against itself. Truncating AFTER the sort
// (not before) is what makes that true when the directory holds more than
// maxDocs files: take the first maxDocs of the LISTING and the selection would
// depend on readdir order, so a share with seven documents could capture a
// different bundle on two boots with nothing on the share having changed.
//
// A missing or unreadable docsDir is an empty selection, not a failure: the
// documents are the optional part of the bundle, and a share with no DOCS must
// still be able to snapshot its settings and session. A document over
// maxDocBytes, or one that cannot be read, is skipped — see maxDocBytes.
func captureDocs() []snapshot.Entry {
	var rows [vi.MaxDirEntries]vi.DirEntry
	n, rc := snapList(docsDir, rows[:])
	if rc < 0 || n == 0 {
		return nil
	}
	type doc struct {
		name string
		size uint32
	}
	var found []doc
	for i := 0; i < n; i++ {
		e := rows[i]
		if e.Dir() {
			continue
		}
		name := e.NameString()
		// A name the container would refuse is skipped here, at capture,
		// rather than failing the whole snapshot: one unusable share name
		// must not cost the person their settings and session. Build would
		// refuse the bundle, so the check has to happen before it.
		if !snapshot.ValidName(name) || e.Size > maxDocBytes {
			continue
		}
		found = append(found, doc{name: name, size: e.Size})
	}
	// Insertion sort by name, bounded by the kernel's 16-entry listing
	// window. A capture of that window does not need a general sort, and the
	// guest keeps no heap.
	for i := 1; i < len(found); i++ {
		d := found[i]
		j := i - 1
		for j >= 0 && found[j].name > d.name {
			found[j+1] = found[j]
			j--
		}
		found[j+1] = d
	}
	if len(found) > maxDocs {
		found = found[:maxDocs]
	}
	out := make([]snapshot.Entry, 0, len(found))
	for _, d := range found {
		b, rc := snapRead(docsDir+"/"+d.name, maxDocBytes+1)
		if rc < 0 || len(b) > maxDocBytes {
			continue // gone, unreadable, or bigger than the cap: skip it
		}
		out = append(out, snapshot.Entry{
			Name: snapshot.DocsPrefix + d.name,
			Body: b,
		})
	}
	return out
}

// saveSnapshot is the Ctrl+Shift+S arm: capture, publish, report. It is the
// card's archive step, deliberately not automatic — nothing here runs because
// time passed, only because the chord was pressed.
func saveSnapshot() bool {
	// M125a (#2586): the bundle must carry each tab's CURRENT state —
	// ask every bound tab to serialize, drain their answers inside the
	// bounded collect, then republish SESSION.TABS so the captured bytes
	// hold the blobs that just landed. Silent apps keep whatever they
	// last stored; the snapshot never waits longer than the ask budget.
	askAllStateSave("snap")
	collectStateAsks()
	_ = writeSession()
	raw, entries, docs, ok := captureBundle()
	if !ok {
		snapLog(MarkerSnapshotFail + "capture")
		return false
	}
	if rc := snapWrite(bundlePath, raw); rc != 0 {
		snapLog(MarkerSnapshotFail + "publish=" + vi.Itoa64(rc))
		return false
	}
	// Only after the publish returned: the bundle is on the share.
	snapLog(MarkerSnapshotSaved + snapshotTail(int64(len(raw)), entries, docs))
	return true
}

// restoreSnapshot is the drill's other half. It is a NO-OP unless the share
// carries the one-shot request, so an ordinary boot never rewinds to a
// snapshot that happens to be lying around.
//
// The request is consumed on BOTH outcomes. A good bundle restores once; a
// corrupt or absent one refuses once and is not re-refused on every later
// boot, and the refusal is already on the serial log and in the gate's
// evidence. Consuming it is also what keeps "refuse whole" whole: the request
// is the only thing that could make the seat write the bundle's bytes, and it
// is gone by the time it could try again.
func restoreSnapshot() bool {
	if !snapExists(restoreFlag) {
		return false
	}
	// The return is checked rather than dropped: a failed delete leaves the
	// request on the share, which is the one way the one-shot guarantee can
	// fail, and the reader of this serial deserves to be told instead of
	// being shown a clean restore and a request that is still there.
	if rc := snapDelete(restoreFlag); rc != 0 {
		snapLog(MarkerSnapshotPersist + vi.Itoa64(rc))
	}

	raw, rc := snapRead(bundlePath, maxBundleRead)
	if rc < 0 || raw == nil {
		// Absent: nothing to restore, and nothing written. The seat's
		// ordinary missing-file handling is the whole story from here.
		snapLog(MarkerSnapshotMissing)
		return false
	}
	if len(raw) > snapshot.MaxBundle {
		snapLog(MarkerSnapshotBad + "oversize")
		return false
	}
	bundle, ok, reason := snapshot.Parse(raw)
	if !ok {
		// Refused whole. Validation is complete, so NOTHING below has run
		// and the live files are exactly as the share left them — the
		// M66b corrupt-settings shape, one line, then defaults.
		snapLog(MarkerSnapshotBad + reason)
		return false
	}

	// Past this point the bundle is valid and the writes begin. Each is the
	// same crash-safe publish, and each failure names itself rather than
	// letting the marker claim a byte-exact restore that did not happen.
	if b, found := bundle.Get(snapshot.EntrySettings); found {
		if w := snapWrite(settings.Path, b); w != 0 {
			snapLog(MarkerSnapshotFail + "settings=" + vi.Itoa64(w))
			return false
		}
	}
	if b, found := bundle.Get(snapshot.EntrySession); found {
		if w := snapWrite(sessionPath, b); w != 0 {
			snapLog(MarkerSnapshotFail + "session=" + vi.Itoa64(w))
			return false
		}
	}
	if b, found := bundle.Get(snapshot.EntryPanes); found {
		if w := snapWrite(panesPath, b); w != 0 {
			snapLog(MarkerSnapshotFail + "panes=" + vi.Itoa64(w))
			return false
		}
	} else if panesDelete(panesPath) == 0 {
		// A bundle with no sidecar restores the unsplit shape: a stale
		// SESSION.PANES on this share must not survive a bundle that
		// never carried one.
		snapLog(MarkerPanesWrite + "0")
	}
	docs := bundle.Docs()
	if len(docs) > 0 {
		// The directory may not exist on a fresh share. "Already exists"
		// (-9) is the normal case and is not a failure.
		if m := snapMkdir(docsDir); m < 0 && m != vi.ErrFileExists {
			snapLog(MarkerSnapshotFail + "docs=" + vi.Itoa64(m))
			return false
		}
		for _, d := range docs {
			if w := snapWrite(docsDir+"/"+d.Name, d.Body); w != 0 {
				snapLog(MarkerSnapshotFail + "doc=" + d.Name + "=" + vi.Itoa64(w))
				return false
			}
		}
	}
	snapLog(MarkerSnapshotRestore + snapshotTail(int64(len(raw)),
		len(bundle.Entries), len(docs)))
	return true
}

// snapshotTail is the shared marker tail: `bytes=<n> entries=<e> docs=<d>`.
// One helper so the save and restore markers cannot drift in shape — a gate
// that greps one greps both.
func snapshotTail(bytes int64, entries, docs int) string {
	return "bytes=" + vi.Itoa64(bytes) +
		" entries=" + vi.Itoa64(int64(entries)) +
		" docs=" + vi.Itoa64(int64(docs))
}
