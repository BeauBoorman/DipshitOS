package vi

// M81f (#1766): the file-watch subscribe seam — the guest-poller shape the
// probe named. The probe (recorded on the card) measured that the host HF
// channel cannot carry change events: queue 5 is a stateless guest-initiated
// request/reply transport (13 opcodes, reply written into the requesting
// element), the macOS 27 SDK's only host→guest data path is returning a
// guest-armed element, and the kernel's file driver arms exactly one
// request/reply pair per exchange — a host-pushed feed would need a kernel
// transport seam. So "something changed over there" is observed here, over
// the ops that already exist: a subscriber snapshots sys_dir_list and diffs
// it against the previous snapshot. No kernel change, no new ABI.
//
// The 40-byte dir rows carry name/size/is_dir (no mtime), and the listing
// window is MaxDirEntries rows — so a watch sees create/remove/resize, and
// only for the first 16 names of a directory, same window the file manager
// paints.

// WatchKind names what a WatchEvent observed.
type WatchKind uint8

const (
	WatchCreated  WatchKind = iota + 1 // name appeared since the previous snapshot
	WatchRemoved                       // name is gone since the previous snapshot
	WatchChanged                       // same name, different size or kind
	WatchPathGone                      // the watched directory itself stopped listing
)

// String names the kind for serial markers ("created", "removed", …).
func (k WatchKind) String() string {
	switch k {
	case WatchCreated:
		return "created"
	case WatchRemoved:
		return "removed"
	case WatchChanged:
		return "changed"
	case WatchPathGone:
		return "path gone"
	}
	return "unknown"
}

// WatchEvent is one observed change. Name is empty for WatchPathGone.
type WatchEvent struct {
	Kind WatchKind
	Name string
	Size uint32
}

// DirSnapshot is one observed listing of a directory. OK is false when the
// listing failed (the path is gone or unreadable); Rows is then empty.
type DirSnapshot struct {
	OK   bool
	Rows []DirEntry
}

// SnapshotDir lists path into a fresh snapshot — one sys_dir_list call.
// Rows are sorted dirs-first then by name, the file manager's paint order,
// so diff output is deterministic.
func SnapshotDir(path string) DirSnapshot {
	var buf [MaxDirEntries]DirEntry
	n, rc := DirList(path, buf[:])
	if rc < 0 {
		return DirSnapshot{OK: false}
	}
	rows := make([]DirEntry, n)
	copy(rows, buf[:n])
	sortDirRows(rows)
	return DirSnapshot{OK: true, Rows: rows}
}

// sortDirRows orders rows dirs-first then by name (16 rows max; insertion
// sort — no import, and the input is already near-sorted in practice).
func sortDirRows(rows []DirEntry) {
	for i := 1; i < len(rows); i++ {
		for j := i; j > 0 && dirRowLess(rows[j], rows[j-1]); j-- {
			rows[j], rows[j-1] = rows[j-1], rows[j]
		}
	}
}

func dirRowLess(a, b DirEntry) bool {
	if a.Dir() != b.Dir() {
		return a.Dir()
	}
	an, bn := a.NameString(), b.NameString()
	return an < bn
}

// Watcher is one subscription's diff state: the previous snapshot of the
// watched path. It is not safe for concurrent use — the file manager runs
// its feed on its own loop thread, and a subscriber that shares one across
// threads owns that sync.
type Watcher struct {
	prev   DirSnapshot
	primed bool
}

// Observe adopts snap as the new baseline and returns what changed since
// the previous snapshot. The first call only primes the baseline and
// returns nil — a watcher that has never seen the path cannot name a
// change against it.
func (w *Watcher) Observe(snap DirSnapshot) []WatchEvent {
	evs := w.diff(snap)
	w.prev = snap
	w.primed = true
	return evs
}

// ObserveDir snapshots path (one listing) then Observe()s it — the poller
// loop's one-liner.
func (w *Watcher) ObserveDir(path string) []WatchEvent {
	return w.Observe(SnapshotDir(path))
}

// Adopt rebaselines the subscription to a listing the app itself just took,
// without emitting events: the feed reports what the app did NOT cause, so
// its own refreshes (cd, rename, paste) must not come back as news. The
// zero-value snapshot (OK=false) is a valid baseline — it is what a failed
// refresh adopts, so the directory's return later diffs as Created events.
func (w *Watcher) Adopt(snap DirSnapshot) {
	w.prev = snap
	w.primed = true
}

// diff is the pure half: prev vs next, no syscalls, so host tests pin the
// event shapes directly.
func (w *Watcher) diff(next DirSnapshot) []WatchEvent {
	if !w.primed {
		return nil
	}
	prev := w.prev
	if !next.OK {
		if prev.OK {
			return []WatchEvent{{Kind: WatchPathGone}}
		}
		return nil // still gone, nothing new to say
	}
	if !prev.OK {
		// The path came back: everything now listed is (re)created.
		evs := make([]WatchEvent, 0, len(next.Rows))
		for _, r := range next.Rows {
			evs = append(evs, WatchEvent{Kind: WatchCreated, Name: r.NameString(), Size: r.Size})
		}
		return evs
	}
	present := make(map[string]DirEntry, len(prev.Rows))
	for _, r := range prev.Rows {
		present[r.NameString()] = r
	}
	wasThere := make(map[string]bool, len(next.Rows))
	var evs []WatchEvent
	for _, r := range next.Rows {
		name := r.NameString()
		wasThere[name] = true
		old, ok := present[name]
		if !ok {
			evs = append(evs, WatchEvent{Kind: WatchCreated, Name: name, Size: r.Size})
			continue
		}
		if old.Size != r.Size || old.Dir() != r.Dir() {
			evs = append(evs, WatchEvent{Kind: WatchChanged, Name: name, Size: r.Size})
		}
	}
	for _, r := range prev.Rows {
		name := r.NameString()
		if !wasThere[name] {
			evs = append(evs, WatchEvent{Kind: WatchRemoved, Name: name})
		}
	}
	return evs
}
