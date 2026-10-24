// The M74a (issue #1644) file manager's state machine — deliberately pure:
// no Bubble Tea import, no guest syscall wrappers beyond the vi surface the
// host already stubs, so `go test` on the host pins navigation, the act
// operations' marker shapes, and the modal flows. tea.go adapts it to the
// tea.Model contract; render.go draws it; main.go owns the bound-tty loop.
package main

import (
	"strings"

	"virelai/appkit"
	"virelai/mime"
	"virelai/vi"
)

// editMode is the model's modal state: the act prompts own the keyboard
// until they are committed or cancelled.
type editMode uint8

// viewMode is the frame shape — M125c (#2588): the second pane layout is
// what makes "view mode" real session state rather than a serialized
// constant. Tab toggles it.
type viewMode uint8

const (
	// viewSplit is the M74a two-pane frame: list | preview.
	viewSplit viewMode = iota
	// viewList drops the preview pane; the list spans the whole grid.
	viewList
	// viewGrid is the M167a (#2989) thumbnail grid: cell-mosaic tiles in
	// the list pane, the focused image's sixel in the preview pane.
	viewGrid
)

const (
	modeNormal editMode = iota
	modeRename
	modeConfirmDelete
	modeOpenWith  // M81b (#1762): the Open-with… candidate list owns the digits
	modeContext   // M124d (#2583): the right-click menu owns keys until dismissed
	modeHints     // M121c (#2566): the '?' chord-hint overlay owns the frame
	modeQuickLook // M149a (#2806): the spacebar preview pane owns the frame
	modeProps     // M155a (#2929): the 'i' properties card owns the frame
	// M155c (#2931): the '/' content search — the prompt owns the status
	// row like the rename prompt's, the results frame owns the grid.
	modeSearchInput
	modeSearchHits
)

// titleBarPx is the window title band the client area sits below: the
// kernel's grid is client_w/8 columns (terminal.syncWindowCols) and the
// client height is H-16 (the dui/charmhello geometry: rect 32,32,W,H with a
// 16 px title, client origin y+16).
const titleBarPx = 16

type model struct {
	path    string
	entries [vi.MaxDirEntries]vi.DirEntry
	n       int
	sel     int
	top     int // first visible list row — the scroll position
	view    viewMode
	sort    sortMode

	mode  editMode
	input string // rename buffer (starts empty: type the new name)
	// delName is the file the armed delete-confirm names (#2894): the
	// selection can shift under the prompt (a watch-event refresh
	// re-sorts or re-clamps sel), so the 'y' answer is checked against
	// the name the prompt actually showed.
	delName string

	clipSet []string // absolute source paths queued by c/x (one or a marked set)
	clipCut bool     // x (move) vs c (copy)

	// M155b (#2930): the marked set — names bound to marksDir (the
	// directory they were made in; a cd hides the set, marking elsewhere
	// starts fresh). Transient: never serialized into the session blob.
	marks    map[string]struct{}
	marksDir string

	// delSet is the batch delete the armed confirm holds (names under the
	// dir the prompt was raised in); empty for the single-file prompt.
	delSet []string

	// M155b: the queued batch main steps one item per loop pass. prog is
	// its seat-visible progress row (kind 22 via appkit.Progress.Report);
	// winID is the window the row reports for — set by main, 0 in host
	// tests where the post refuses before the mailbox.
	batch   batchOp
	batchOn bool
	prog    appkit.Progress
	winID   uint32

	preview    string // preview pane body
	previewOf  string // name the preview shows (pane header)
	previewBig bool   // file at/over the read cap: say truncated, don't lie

	status string
	cols   int
	rows   int

	quit         bool
	renamedBatch bool     // a rename landed this batch: main prints the settle marker
	pending      []string // serial markers, flushed by main AFTER the frame paints
	// M81b (#1762): the Open-with… list and the exec it queued. The model
	// decides and marks; main owns vi.Exec (open.go).
	openName  string
	openPath  string
	openID    mime.ID
	openCands []mime.Handler
	launch    launchReq

	// M124d (#2583): the right-click context menu — armed by a right SGR
	// press on a row (context.go), painted as a CUP overlay (render.go).
	ctx ctxMenu

	// notify is the M79k (#1720) toast this batch wants raised, drained by
	// main alongside `pending`. The model stays pure: it decides WHAT
	// happened, main owns the one seam that talks to the seat.
	notify string

	// M124a-2 (#2677): the press gesture's drag arm. pressRow is the list
	// index the live button-hold started on (-1 = the press was not on a
	// row), pendOpen defers a press-on-selected-row's open to its release
	// edge so a held move can arm the seat-mediated drag instead, and
	// dragOn latches once the arm acks — while it holds the seat owns the
	// pointer and no further reports reach the app. dragName/dragMT/
	// dragLen carry the armed offer's facts for the arm marker.
	pressRow int
	pendOpen bool
	dragOn   bool
	dragName string
	dragMT   string
	dragLen  int

	// M81f (#1766): the change-feed subscription for the listing being
	// shown. The watcher's baseline is adopted by every refresh (the feed
	// reports what the app did NOT cause); watchArmed gates the one-time
	// armed marker. Polled from main's idle branch via watchStep.
	watcher    vi.Watcher
	watchArmed bool

	// M123d (#2578): the shared appkit.ErrorBanner, rendered on the status
	// row while it is open (the modal prompts' takeover idiom). It carries
	// exec refusals (drainLaunch's outcome half) and the rename conflict's
	// Replace/Cancel pair. bannerOp names which arm raised it ("rename" —
	// bannerFrom/bannerTo hold the refused pair for Replace); bannerFresh
	// tells main a raise happened post-paint so the banner's own frame is
	// the next paint, not a lucky later event.
	banner      appkit.ErrorBanner
	bannerOp    string
	bannerFrom  string
	bannerTo    string
	bannerFresh bool

	// M121c (#2566): the '?' chord-hint overlay — the registry's rows for
	// this app's scope (none registered), the seat's globals, and the
	// kernel terminal chrome (a tty-bound window answers those too),
	// rendered ANSI inside this app's own frame.
	hints appkit.ChordHints

	// M190d (#3239): the appkit menubar on row 0 — titles live beside the
	// path bar; F10 (the kernel's ESC[21~) engages it and an open menu
	// plates over the frame's body like the context menu does. Every row
	// calls the identical method its rune key calls below.
	bar appkit.MenuBar

	// M149a (#2806): the spacebar QuickLook pane (quick.go). Armed by ' '
	// on the selection, dismissed by space/Esc or a pointer press; the
	// listing underneath is never touched.
	ql quickLook

	// M155a (#2929): the 'i' properties card (props.go). Armed by 'i' on
	// the selection, dismissed by Esc/`i` or a pointer press.
	props props

	// M155c (#2931): the '/' bounded content search (search.go). The
	// prompt rides the status row; the results frame shows the walk's
	// hit set and its accounting.
	search search

	// M167b (#2992): pinned places (favs.go). The pin list in the user's
	// order — the favsView pseudo-listing is never sorted, so row i IS
	// favs[i] — and the FILES.FAV store keeps the same order.
	favs []string

	// M167c (#2993): the open archive (tar.go) — non-nil while the
	// listing is a tar's read-only virtual directory. tarSub is the
	// browsed dir inside it ("" = the archive root, "DEEP/" a member
	// dir); tarRows maps the sorted row index back to tar.ents, and each
	// row's Reserved[0] byte carries its class (file/dir/link/
	// unsupported/refused).
	tar     *tarArc
	tarSub  string
	tarRows []int

	// M167a (#2989): the `t` thumbnail grid (grid.go). viewUnder is the
	// pane view `t` returns to; gridTiles is the 64-tile cache keyed by
	// path+size+mtime (cell colours only, gridOrder its FIFO eviction);
	// gridRef/gridQueue are the current listing's resolved tiles and the
	// lazy-decode backlog; gridTilesEmitted gates the one-shot stats
	// marker; gridF* is the focused tile's sixel memo — the last decoded
	// key, its sequence, thumbnail dims, the rung it was encoded under,
	// and the last name the focus marker printed.
	viewUnder        viewMode
	gridTiles        map[gridKey]*gridTile
	gridOrder        []gridKey
	gridRef          []*gridTile
	gridQueue        []int
	gridTilesEmitted bool
	gridFKey         gridKey
	gridFSixel       []byte
	gridFTW, gridFTH int
	gridFCW, gridFCH uint32
	gridFName        string
}

// hintsBin names this app's registry scope — the untagged twin of
// main.go's appName (the tagged file's constant cannot be read here).
const hintsBin = "GOFILES.ELF"

// newModel starts at path on a cols x rows grid and takes the first listing
// (its markers ride pending for main to flush after the first paint).
func newModel(path string, cols, rows int) model {
	m := model{path: path, pressRow: -1}
	m.setSize(cols, rows)
	m.buildMenus()
	if now := vi.Time(); now >= 0 {
		expired, rc := vi.TrashExpire(now)
		if rc < 0 {
			m.emit(markerTrashExpireNo + "rc=" + vi.Itoa64(rc))
		} else if expired > 0 {
			m.emit(markerTrashExpired + vi.Itoa64(int64(expired)))
		}
	}
	m.loadFavs()
	m.refresh()
	return m
}

// emit queues one serial marker; drain hands the batch to main.
func (m *model) emit(line string) { m.pending = append(m.pending, line) }

func (m *model) drain() []string {
	out := m.pending
	m.pending = nil
	return out
}

// notifyToast queues the toast text for main to raise after this frame
// paints. The last one in a batch wins: the status line already names the
// final state, and a screen that raises three toasts for one keystroke
// would be lying about how much happened.
func (m *model) notifyToast(text string) { m.notify = text }

// takeNotify consumes the queued toast (consume-on-use, like drain).
func (m *model) takeNotify() string {
	t := m.notify
	m.notify = ""
	return t
}

// setSize adopts a new grid after a window resize (M73j #1636 has not
// landed: this is the window's px-derived grid, not a queried tty winsize).
func (m *model) setSize(cols, rows int) {
	if cols < 16 {
		cols = 16
	}
	if rows < 8 {
		rows = 8
	}
	m.cols, m.rows = cols, rows
	m.ensureSelVisible()
}

// bodyRows is the pane height: path bar + pane headers + status + hints.
func (m model) bodyRows() int {
	b := m.rows - 4
	if b < 1 {
		return 1
	}
	return b
}

func (m *model) clampSel() {
	if m.n > len(m.entries) {
		m.n = len(m.entries)
	}
	if m.sel < 0 || m.sel >= m.n {
		m.sel = 0
	}
	m.ensureSelVisible()
}

// ensureSelVisible keeps the cursor inside the scroll window — the
// invariant is top <= sel < top+bodyRows, with top re-tightened when the
// listing shrinks. A selection the frame cannot show is the shape the
// serialized `top` field restores against, and the thing a small window
// would otherwise lose (M125c #2588).
func (m *model) ensureSelVisible() {
	if m.view == viewGrid {
		// The grid's window is tile ROWS, not entry rows: m.top stays an
		// entry index but is always a multiple of gridCols — the first
		// entry of the first visible tile row.
		gc, gr := m.gridCols(), m.gridRows()
		tr, topTr := m.sel/gc, m.top/gc
		if tr < topTr {
			topTr = tr
		} else if tr >= topTr+gr {
			topTr = tr - gr + 1
		}
		rows := (m.n + gc - 1) / gc
		if rows <= gr {
			topTr = 0
		} else if topTr > rows-gr {
			topTr = rows - gr
		}
		if topTr < 0 {
			topTr = 0
		}
		m.top = topTr * gc
		return
	}
	body := m.bodyRows()
	if m.sel < m.top {
		m.top = m.sel
	} else if m.sel >= m.top+body {
		m.top = m.sel - body + 1
	}
	if m.n <= body {
		m.top = 0
	} else if m.top > m.n-body {
		m.top = m.n - body
	}
	if m.top < 0 {
		m.top = 0
	}
}

// refresh re-lists the current directory, emits the M58a marker family
// (list / entry / found / list error) and reloads the preview.
//
// Every refresh also re-baselines the M81f change feed: the listing the app
// itself just took is what "unchanged" means, so its own cd/rename/paste
// never comes back as a watch event.
func (m *model) refresh() {
	if m.path == volsPath {
		m.refreshVolumes()
		return
	}
	if m.path == favsView {
		m.refreshFavs()
		return
	}
	if m.tar != nil {
		m.refreshTar()
		return
	}
	n, rc := vi.DirList(m.path, m.entries[:])
	if rc < 0 {
		m.n, m.sel = 0, 0
		m.status = "list err"
		// M134b (#2760): ENXIO under a mount row is the kernel's named
		// `not_mounted` — name it so an absent volume never reads as
		// corruption.
		if err := vi.MountErr(rc); vi.IsNotMounted(err) {
			if vol := volumeOf(m.path); vol != "" {
				m.status = vol + ": not mounted"
			}
		}
		m.emit(markerListErr + vi.Itoa64(rc))
		m.watcher.Adopt(vi.DirSnapshot{OK: false})
		m.loadPreview()
		return
	}
	m.n = n
	sortEntries(m.entries[:], m.n, m.sort)
	m.clampSel()
	m.pruneMarks()
	m.watcher.Adopt(vi.DirSnapshot{OK: true, Rows: append([]vi.DirEntry(nil), m.entries[:m.n]...)})
	m.emit(markerList + m.path + " n=" + vi.Itoa64(int64(m.n)))
	for i := 0; i < m.n; i++ {
		name := m.entries[i].NameString()
		kind := "file"
		if m.entries[i].Dir() {
			kind = "dir"
		}
		m.emit(markerEntry + name + " " + kind + " size=" + vi.Itoa64(int64(m.entries[i].Size)))
		if name == knownName {
			m.emit(markerFound)
		}
	}
	m.status = "listed"
	if m.n == 0 {
		m.emit(markerEmpty + m.path)
	}
	if m.view == viewGrid {
		m.gridSync()
	}
	m.loadPreview()
}

// refreshVolumes lists the volumes root — the kernel's mount table
// (M134b #2760): sys_dir_list("/") returns one row per mount, carrying the
// live state and kind in the wire row's reserved bytes, so the whole
// render/selection machinery applies unchanged. Every row's state is
// named each list — a mounted volume carries its rw/ro posture, an absent
// one the `not_mounted` name (ADR 0050 D6).
func (m *model) refreshVolumes() {
	mounts, rc := mountRows()
	if rc < 0 {
		m.n, m.sel = 0, 0
		m.status = "list err"
		m.emit(markerListErr + vi.Itoa64(rc))
		m.watcher.Adopt(vi.DirSnapshot{OK: false})
		m.loadPreview()
		return
	}
	m.n = 0
	for _, mt := range mounts {
		if m.n == len(m.entries) {
			break
		}
		var e vi.DirEntry
		copy(e.Name[:], mt.Name)
		if mt.Dir {
			e.IsDir = 1
		}
		e.Reserved[0] = mt.State
		e.Reserved[1] = mt.Kind
		if mt.ReadOnly {
			e.Reserved[2] = vi.MountFlagReadOnly
		}
		m.entries[m.n] = e
		m.n++
	}
	m.clampSel()
	// The feed never watches the mount-table root; adopt an empty baseline
	// so the next real listing's first poll is primed, not diffed against
	// this.
	m.watcher.Adopt(vi.DirSnapshot{OK: false})
	m.emit(markerList + m.path + " n=" + vi.Itoa64(int64(m.n)))
	for i := 0; i < m.n; i++ {
		mt := vi.MountFromEntry(m.entries[i])
		kind := "file"
		if mt.Dir {
			kind = "dir"
		}
		m.emit(markerEntry + mt.Name + " " + kind + " size=0")
		line := markerVol + mt.Name + " " + mt.StateName()
		if mt.Mounted() {
			line += " " + mt.AccessName()
		}
		m.emit(line)
	}
	m.status = "listed"
	if m.view == viewGrid {
		m.gridSync()
	}
	m.loadPreview()
}

// loadPreview fills the preview pane for the selection: directories get a
// note, files get their bytes (sanitized, capped), and every successful file
// load emits the M58a `gofiles: view …` marker.
func (m *model) loadPreview() {
	if m.view == viewGrid {
		// M167a: the selection IS the grid's focus — re-arm the sixel and
		// name it on the serial line. Runs ahead of the early returns so a
		// dead selection still clears the focus.
		m.gridFocus()
	}
	m.preview, m.previewOf, m.previewBig = "", "", false
	if m.sel < 0 || m.sel >= m.n {
		m.preview = "(no selection)"
		return
	}
	e := m.entries[m.sel]
	name := e.NameString()
	if m.path == volsPath {
		// A mount-table row: the row's reserved bytes carry the live state
		// (M134b) — `not_mounted` and the kind name read straight off the
		// kernel's answer, no probe.
		mt := vi.MountFromEntry(e)
		m.previewOf = name
		switch {
		case !mt.Dir:
			m.preview = "block device — not browsable\n(" + mt.KindName() + ", " + mt.AccessName() + ")"
		case !mt.Mounted():
			m.preview = "volume — " + mt.StateName() + "\n(boot with --data-disk to attach " + name + ")"
		default:
			m.preview = "volume — " + mt.StateName() + " " + mt.AccessName() + "\n(enter to browse)"
		}
		return
	}
	if m.path == favsView {
		// M167b: a pin row previews what it points at — the live path,
		// or the gone pin's honest missing note.
		m.previewOf = name
		pin := ""
		if m.sel < len(m.favs) {
			pin = m.favs[m.sel]
		}
		if m.favMissing(e) {
			m.preview = "pin — missing\n" + pin + "\n(the folder is gone; b unpins it)"
		} else {
			m.preview = "pinned folder\n" + pin + "\n(enter to open · b unpins)"
		}
		return
	}
	if m.tar != nil {
		m.tarPreview(e, name)
		return
	}
	if e.Dir() {
		m.previewOf = name
		m.preview = "(directory — enter to open)"
		return
	}
	child, ok := joinPath(m.path, name)
	if !ok {
		m.preview = "(path too long)"
		return
	}
	body, rc := readCapped(child, maxPreviewBytes)
	if rc < 0 {
		m.previewOf = name
		m.preview = "read err " + vi.Itoa64(rc)
		return
	}
	m.previewOf = name
	m.preview = sanitizePreview(body)
	m.previewBig = int64(len(body)) >= maxPreviewBytes && int64(e.Size) > int64(len(body))
	if m.previewBig {
		m.preview += "\n… (first " + vi.Itoa64(int64(len(body))) + " of " +
			vi.Itoa64(int64(e.Size)) + " bytes)"
	}
	m.emit(markerView + name + " bytes=" + vi.Itoa64(int64(len(body))))
}

// watchStep polls the M81f (#1766) change feed once for the listing being
// shown. It returns -1 when the feed said nothing (the common idle case),
// 0 when it armed (the first poll takes the baseline listing and queues the
// armed marker), or the number of events observed — each event is queued as
// its marker and the listing is refreshed so the screen shows what the feed
// named. main paints + flushes on anything >= 0, so every watch marker
// prints only after the frame that backs it.
//
// The event's own re-list takes a fresher snapshot than the one the event
// was diffed against; that fresher listing is the new baseline (refresh
// adopts it), so a second change landing inside that window is reported on
// the NEXT poll — the feed is advisory, never a lossless log.
func (m *model) watchStep() int {
	if m.path == volsPath || m.path == favsView || m.tar != nil {
		// The mount-table root has no feed (the mount set is boot-fixed)
		// and the favorites rows are pins, not a directory — neither is
		// a listing the feed can report on.
		return -1
	}
	first := !m.watchArmed
	m.watchArmed = true
	evs := m.watcher.ObserveDir(m.path)
	if first {
		m.emit(markerWatchArmed)
	}
	if len(evs) == 0 {
		if first {
			return 0
		}
		return -1
	}
	for _, ev := range evs {
		switch ev.Kind {
		case vi.WatchCreated:
			m.emit(markerWatchCreated + ev.Name)
		case vi.WatchRemoved:
			m.emit(markerWatchRemoved + ev.Name)
		case vi.WatchChanged:
			m.emit(markerWatchChanged + ev.Name + " size=" + vi.Itoa64(int64(ev.Size)))
		case vi.WatchPathGone:
			m.emit(markerWatchGone)
		}
	}
	m.refresh()
	return len(evs)
}

func (m *model) selEntry() (vi.DirEntry, bool) {
	if m.sel < 0 || m.sel >= m.n {
		return vi.DirEntry{}, false
	}
	return m.entries[m.sel], true
}

// move shifts the selection by delta and reloads the preview.
func (m *model) move(delta int) {
	if m.n == 0 {
		return
	}
	m.sel += delta
	if m.sel < 0 {
		m.sel = 0
	}
	if m.sel >= m.n {
		m.sel = m.n - 1
	}
	m.ensureSelVisible()
	m.loadPreview()
}

// moveTo jumps the selection to index i (clamped) and reloads the preview.
func (m *model) moveTo(i int) {
	if m.n == 0 {
		return
	}
	m.sel = i
	m.clampSel()
	m.loadPreview()
}

// openSel enters the selected directory, or OPENS the selected file.
//
// M81b (#1762) changed the file half: a second click / Enter / `l` on a file
// is "open this", which means dispatch to the type's default handler (the
// preview is already loaded by the selection itself, so nothing is lost).
func (m *model) openSel() {
	e, ok := m.selEntry()
	if !ok {
		return
	}
	if m.path == volsPath {
		m.enterVolume(e)
		return
	}
	if m.path == favsView {
		m.enterFav(e)
		return
	}
	if m.tar != nil {
		m.openTarRow(e)
		return
	}
	if e.Dir() {
		child, ok := joinPath(m.path, e.NameString())
		if !ok {
			m.status = "path too long"
			return
		}
		m.path = child
		m.sel = 0
		m.emit(markerCd + m.path)
		m.refresh()
		return
	}
	// M167c (#2993): a recognised archive browses in place instead of
	// dispatching to a handler — the mime registry has no tar row.
	if isTarName(e.NameString()) {
		m.enterTar(e)
		return
	}
	m.openFile()
}

// enterVolume descends from the volumes root into a mount-table row. The
// row's own state byte says whether the volume is live: a not-mounted row
// refuses by name — the kernel's `not_mounted` (M134b #2760, ADR 0050 D6)
// carried into the marker and the status line — and the block-device row
// is never a directory.
func (m *model) enterVolume(e vi.DirEntry) {
	mt := vi.MountFromEntry(e)
	name := mt.Name
	switch {
	case !mt.Mounted():
		m.emit(markerVolRefused + name + " " + mt.StateName())
		m.status = name + ": not mounted"
		return
	case !mt.Dir:
		m.emit(markerVolRefused + name + " " + mt.KindName())
		m.status = name + ": not a directory"
		return
	}
	m.path = "/" + name
	m.sel = 0
	m.emit(markerCd + m.path)
	m.refresh()
}

// goUp walks to the parent directory.
func (m *model) goUp() {
	if m.tar != nil {
		if m.tarSub == "" {
			// At the archive root `h` leaves: the real directory the
			// browser entered from replaces the virtual listing.
			dir := m.tar.dir
			m.emit(markerTarClose + m.tar.name)
			m.tar = nil
			m.tarSub = ""
			m.tarRows = nil
			m.path = dir
			m.sel = 0
			m.emit(markerCd + m.path)
			m.refresh()
			return
		}
		sub := strings.TrimSuffix(m.tarSub, "/")
		if i := strings.LastIndexByte(sub, '/'); i >= 0 {
			m.tarSub = sub[:i+1]
		} else {
			m.tarSub = ""
		}
		m.path = m.tar.path + "/" + m.tarSub
		m.sel = 0
		m.emit(markerCd + m.path)
		m.refresh()
		return
	}
	if m.path == volsPath {
		m.status = "at volumes root"
		return
	}
	if m.path == favsView {
		// Above the pseudo-listing is the share root — the pins
		// themselves live beside it.
		m.path = rootPath
		m.sel = 0
		m.emit(markerCd + m.path)
		m.refresh()
		return
	}
	if isMountRoot(m.path) {
		// Above a mount root is the volumes list, not another volume —
		// parentPath cannot know that (it owns share paths only).
		m.path = volsPath
		m.sel = 0
		m.emit(markerCd + m.path)
		m.refresh()
		return
	}
	parent := parentPath(m.path)
	if parent == m.path {
		m.status = "at share root"
		return
	}
	m.path = parent
	m.sel = 0
	m.emit(markerCd + m.path)
	m.refresh()
}

// showVolumes is the `v` chord: jump straight to the volumes root —
// the kernel's mount table (M134b #2760), the same view Backspace/`h`
// reaches from a mount root.
func (m *model) showVolumes() {
	if m.path == volsPath {
		return
	}
	m.tar = nil
	m.tarSub = ""
	m.tarRows = nil
	m.path = volsPath
	m.sel = 0
	m.emit(markerCd + m.path)
	m.refresh()
}

// listCols is the left pane's cell width in the active view mode — the
// whole grid in viewList (no preview pane), the 45% split otherwise.
func (m model) listCols() int {
	if m.view == viewList {
		return m.cols
	}
	return listWidth(m.cols)
}

// toggleView is the Tab chord: swap the two-pane frame for a full-width
// list. The preview still loads — selection semantics are unchanged —
// but nothing paints it in viewList. M167a: from the grid, Tab steps out
// to the OTHER pane view — it still does something visible rather than
// toggling a pane the grid is hiding.
func (m *model) toggleView() {
	cur := m.view
	if cur == viewGrid {
		cur = m.viewUnder
		m.gridFName = "" // re-entry re-emits the focus marker
	}
	if cur == viewSplit {
		m.view = viewList
	} else {
		m.view = viewSplit
	}
	m.viewUnder = m.view
	m.emit(markerViewMode + viewNameOf(m.view))
	m.status = "view " + viewNameOf(m.view)
}

func viewNameOf(v viewMode) string {
	if v == viewList {
		return "list"
	}
	if v == viewGrid {
		return "grid"
	}
	return "split"
}

// cycleSort is the `s` chord: walk dirs -> name -> size and re-sort the
// live listing in place. The selected entry follows the re-sort by name —
// the cursor stays on what the user was looking at, not the row index.
func (m *model) cycleSort() {
	m.sort = (m.sort + 1) % sortModeCount
	selName := ""
	if e, ok := m.selEntry(); ok {
		selName = e.NameString()
	}
	if m.path != volsPath && m.path != favsView {
		sortEntries(m.entries[:], m.n, m.sort)
	}
	m.sel = 0
	for i := 0; i < m.n; i++ {
		if m.entries[i].NameString() == selName {
			m.sel = i
			break
		}
	}
	m.ensureSelVisible()
	m.emit(markerSort + sortNameOf(m.sort))
	m.status = "sort " + sortNameOf(m.sort)
	if m.view == viewGrid {
		// The listing's order changed — the tile table's indices no
		// longer name the same entries, so the queue is rebuilt.
		m.gridSync()
	}
	m.loadPreview()
}

// atPseudo guards the mutating ops on the pseudo-listings: the volumes
// root is the mount table and the favorites rows are pins, so there is
// nothing to rename, trash, hold or write into — each op names the
// surface rather than sending the kernel a path it could never honor.
func (m *model) atPseudo() bool {
	switch m.path {
	case volsPath:
		m.status = "volumes: browse only"
	case favsView:
		m.status = "favorites: browse only"
	default:
		return false
	}
	return true
}
