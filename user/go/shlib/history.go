// M69f1 (#1537): persistent recall — the shell's own history file at the
// host seam, moved wholesale out of user/go/sh/main.go with the M73b split
// (issue #1626): the front-end drives it, the host tests test it, so it
// belongs to the core.
//
// The monitor's HISTORY.TXT (M18 T4) belongs to the kernel actor; GOSH's
// recall was session-only, so a reboot cost the Up arrow. This is the
// shell's own file on the same share: a different name, the same
// one-line-per-entry LF shape, so a human can cat it and neither writer can
// clobber the other.
package shlib

import (
	"virelai/settings"
	"virelai/vi"
)

const (
	// M69f1 (#1537): the shell's own persistent history. NOT the monitor's
	// HISTORY.TXT -- mixing the kernel actor's `virelai>` verbs into GOSH's
	// Up-arrow recall would be worse than no persistence at all.
	histName = "GOSH-HISTORY.TXT"
	// M69f1 (#1537) D3: persistence is best-effort. ONE line, once, and the
	// session continues -- a share that refuses the write must not end a
	// shell.
	markerHistFail = "gosh: history not persisted"
	// M100f (#2311): the data-root lines — printed once per process at the
	// latched resolution, and only when the row opted in. `not_mounted` is
	// the kernel's named refusal for an absent VLFS mount (ADR 0050 D6).
	markerHistRoot         = "gosh: data_root=/disk"
	markerHistRootFallback = "gosh: data_root=disk but /disk not_mounted; using /host"
)

// histPath is where the history file lives this boot: the share path unless
// the data_root row opted in AND a VLFS data disk mounted (M100f, ADR 0050
// D6). Resolved lazily on first use and latched — the mount table is fixed
// for a boot, and a mid-session `data_root` flip must not split one shell's
// history across two volumes.
var histPath = settings.DataRootHost + "/" + histName

// histResolved latches the boot's resolution; histResolve is the seam itself
// (a var so host tests pin the disk and fallback legs).
var histResolved bool
var histResolve = func() (string, bool) {
	return settings.Load().ResolveDataRoot()
}

func resolveHistPath() {
	if histResolved {
		return
	}
	histResolved = true
	root, fellBack := histResolve()
	if root == "" {
		root = settings.DataRootHost
	}
	histPath = root + "/" + histName
	switch {
	case fellBack:
		vi.ConsoleLine(markerHistRootFallback)
	case root == settings.DataRootDisk:
		vi.ConsoleLine(markerHistRoot)
	}
}

// maxHistoryBytes bounds the load. The writer keeps the file inside the ring
// bound, so a larger file is not ours: refuse it whole instead of parsing a
// prefix of somebody else's data. historyMax lines of maxLineBytes is the
// worst case the ring can produce.
const maxHistoryBytes = historyMax * maxLineBytes

// histStore is the slice of the host seam persistence needs. The front-end's
// *goshHost is the real one; the host tests drive SaveHistory/LoadHistory
// with their fakeHost through this interface.
type histStore interface {
	ReadFile(path string, max int) ([]byte, error)
	WriteFile(path string, b []byte, appendMode bool) error
}

// HistorySink is the write side's state: the last line appended (the ring's
// dup rule, carried across boots) and how many appends have landed since the
// file was last rewritten whole.
type HistorySink struct {
	last     string
	appended int
	warned   bool // the one-line failure report is emitted at most once
}

// LoadHistory seeds the ring from the share. A missing file is an empty
// ring, not an error; a read failure is treated the same way (D3: the file
// is a convenience, and a share that cannot answer must not stop the boot).
func LoadHistory(st histStore, h *History, s *HistorySink) {
	resolveHistPath()
	b, err := st.ReadFile(histPath, maxHistoryBytes)
	if err != nil || len(b) == 0 {
		return
	}
	h.Load(b)
	if e := h.Entries(); len(e) > 0 {
		s.last = e[len(e)-1]
	}
}

// SaveHistory appends one submitted line and keeps the file inside the ring
// bound (D2). Runs AFTER the editor pushed the line into the ring, so the
// ring is the writer's source of truth: once the appends alone would push
// the file past the bound, it is rewritten whole from the ring, which has
// already dropped the oldest lines.
func SaveHistory(st histStore, h *History, line string, s *HistorySink) {
	resolveHistPath()
	// Idempotent: the editor already pushed this line when it submitted, so
	// this is a no-op in the shell and the reason the function is honest on
	// its own in a test.
	h.Push(line)
	if line == "" || line == s.last {
		return
	}
	if s.appended >= historyMax {
		// The ring already holds this line (the editor pushes on submit), so
		// the rewrite IS the append: compact and stop. From here the file is
		// rewritten to the ring's own contents, which is the bound D2 asks
		// for -- at most historyMax lines, never an unbounded append log.
		if err := writeHistoryFile(st, h); err != nil {
			s.warn()
			return
		}
		s.last = line
		s.appended = len(h.Entries())
		return
	}
	// The APPEND, and it stays one (M81e2 #1787). vi.WriteFileSafe is
	// replace-only — it publishes a whole new body — so it cannot express
	// this case at all; routing the append through it would rewrite the
	// entire history file once per submitted line, which is slower and
	// strictly worse. The hazard the safe publish fixes is a TORN file from
	// a rewrite, and an append never rewrites: nothing already in the file
	// is at risk when this one line lands, or fails to. The one honest
	// limit is that a crash mid-append can leave a partial LAST line, which
	// LoadHistory already treats as a line to drop (it parses LF-terminated
	// rows) rather than a file to refuse.
	if err := st.WriteFile(histPath, []byte(line+"\n"), true); err != nil {
		s.warn()
		return
	}
	s.last = line
	s.appended++
}

// writeHistoryFile replaces the file with the ring's contents. This IS a
// rewrite — the ring has dropped the oldest lines, so the file must shrink —
// which makes it app state and puts it on the same crash-safe publish as
// settings, the editor buffer and the session file (M81e2 #1787). The host
// hook (goshHost.WriteFile / termHost.WriteFile) routes appendMode=false
// through vi.WriteFileSafe, so a crash here leaves the previous history file
// or none, never a history that has lost its oldest entries to a torn write.
// The appendMode=false is the whole contract; what that means for a redirect
// is argued in user/go/sh/main.go.
func writeHistoryFile(st histStore, h *History) error {
	var b []byte
	for _, ln := range h.Entries() {
		b = append(b, ln...)
		b = append(b, '\n')
	}
	return st.WriteFile(histPath, b, false)
}

// warn reports a persistence failure ONCE, on one serial line, and never
// ends the session (D3).
func (s *HistorySink) warn() {
	if s.warned {
		return
	}
	s.warned = true
	vi.ConsoleLine(markerHistFail)
}
