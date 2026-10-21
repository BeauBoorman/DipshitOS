// The M74a (issue #1644) file manager's state machine — deliberately pure:
// no Bubble Tea import, no guest syscall wrappers beyond the vi surface the
// host already stubs, so `go test` on the host pins navigation, the act
// operations' marker shapes, and the modal flows. tea.go adapts it to the
// tea.Model contract; render.go draws it; main.go owns the bound-tty loop.
package main

import (
	"virelai/appkit"
	"virelai/chords"
	"virelai/mime"
	"virelai/rss/keys"
	"virelai/vi"
	"virelai/vsys"
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
}

// hintsBin names this app's registry scope — the untagged twin of
// main.go's appName (the tagged file's constant cannot be read here).
const hintsBin = "GOFILES.ELF"

// newModel starts at path on a cols x rows grid and takes the first listing
// (its markers ride pending for main to flush after the first paint).
func newModel(path string, cols, rows int) model {
	m := model{path: path, pressRow: -1}
	m.setSize(cols, rows)
	if now := vi.Time(); now >= 0 {
		expired, rc := vi.TrashExpire(now)
		if rc < 0 {
			m.emit(markerTrashExpireNo + "rc=" + vi.Itoa64(rc))
		} else if expired > 0 {
			m.emit(markerTrashExpired + vi.Itoa64(int64(expired)))
		}
	}
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
	m.loadPreview()
}

// loadPreview fills the preview pane for the selection: directories get a
// note, files get their bytes (sanitized, capped), and every successful file
// load emits the M58a `gofiles: view …` marker.
func (m *model) loadPreview() {
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
	if m.path == volsPath {
		return -1 // the mount-table root has no feed — the mount set is boot-fixed
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
	if m.path == volsPath {
		m.status = "at volumes root"
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

// handleClick maps a kernel SGR mouse press (1-based cell coords over the
// client area) onto the list: first press selects, press on the already-
// selected row PENDS its open to the release edge — the M58a
// "click again opens" contract re-stated for M124a-2 (#2677): a held move
// off the press arms the seat-mediated drag, so "open" cannot fire until
// the gesture proved it was a click and not a drag.
func (m *model) handleClick(x, y int) {
	m.pressRow = -1
	m.pendOpen = false
	col, row := x-1, y-1
	// M123d (#2578): while the error banner stands, a press on its row
	// (the status line) dismisses it; presses elsewhere are swallowed —
	// the strip holds the prompt open until it is answered.
	if m.banner.Open {
		if row == m.rows-2 {
			m.banner.Dismiss()
			m.bannerResolve()
		}
		return
	}
	if m.mode == modeQuickLook {
		// M149a (#2806): a press anywhere dismisses the pane — it floats
		// over the list like macOS's, never selects underneath itself.
		m.closeQuickLook()
		return
	}
	if m.mode == modeProps {
		// M155a (#2929): same rule as the QuickLook pane — a press
		// dismisses the card, never acts on the list underneath it.
		m.closeProps()
		return
	}
	if m.mode == modeSearchHits {
		// M155c (#2931): same modal rule — a press dismisses the
		// results frame, never selects a row underneath it.
		m.closeSearch()
		return
	}
	if m.mode == modeSearchInput {
		// The prompt's press rule is the armed confirm's: the click was
		// acting on the list, not answering, so it sheds the prompt.
		m.mode = modeNormal
		m.input = ""
		m.status = "search cancelled"
		return
	}
	if m.mode == modeConfirmDelete {
		// #2894: a press while the confirm is armed is acting on the
		// list, not answering — shed the prompt. The press is swallowed
		// like every other overlay's dismiss, never a selection under it.
		m.cancelDelete("key=press")
		return
	}
	if col < 0 || col >= m.cols || row < 2 || row >= 2+m.bodyRows() {
		return
	}
	if col >= m.listCols() {
		return // preview pane: no click action in v1
	}
	idx := m.top + row - 2
	if idx < 0 || idx >= m.n {
		return
	}
	m.pressRow = idx
	if idx == m.sel {
		m.pendOpen = true
		return
	}
	m.sel = idx
	m.ensureSelVisible()
	m.loadPreview()
}

// releaseClick settles a press's open intent on the release edge: a press
// that deferred its open (pendOpen) and was never stolen by a drag now
// opens. Releases with nothing pending — a press on an unselected row, or
// chrome — are honest no-ops.
func (m *model) releaseClick() {
	m.pressRow = -1
	if m.pendOpen {
		m.pendOpen = false
		m.openSel()
	}
}

// handleKey is the whole keyboard contract, decoded from the bound tty by
// keys.Decode (runes verbatim, CSI arrows, Return/Backspace/Esc).
func (m *model) handleKey(ev keys.Event) {
	// M123d (#2578): the open error banner owns the keyboard first — it is
	// the status row while it stands, so no list binding may fire under it.
	if m.banner.Open {
		m.bannerKey(ev)
		return
	}
	if m.mode == modeRename {
		switch ev.Key {
		case keys.KeyEnter:
			m.commitRename()
		case keys.KeyEsc:
			m.mode = modeNormal
			m.status = "rename cancelled"
		case keys.KeyBackspace:
			if len(m.input) > 0 {
				m.input = m.input[:len(m.input)-1]
			}
		case keys.KeyRune:
			if len(m.input) < maxNameLen {
				m.input += string(ev.Rune)
			}
		case keys.KeyCtrlC:
			m.quit = true
		}
		return
	}
	if m.mode == modeOpenWith {
		switch ev.Key {
		case keys.KeyRune:
			if ev.Rune >= '1' && ev.Rune <= '9' {
				m.chooseOpen(int(ev.Rune - '0'))
				return
			}
		case keys.KeyEsc, keys.KeyBackspace:
			m.cancelOpenWith()
		case keys.KeyCtrlC:
			m.quit = true
		}
		return
	}
	if m.mode == modeContext {
		// The menu owns the keyboard: arrows walk the plate (and the open
		// submenu), Right/Enter descend, Left closes the submenu, Esc
		// dismisses — nothing leaks through to the list bindings.
		switch ev.Key {
		case keys.KeyUp:
			m.ctxMove(-1)
		case keys.KeyDown:
			m.ctxMove(1)
		case keys.KeyRight:
			if !m.ctx.sub {
				if m.ctx.sel == m.ctxOpenWithRow() {
					m.ctxOpenSub()
				}
			}
		case keys.KeyLeft:
			m.ctx.sub = false
		case keys.KeyEnter:
			m.ctxCommit()
		case keys.KeyEsc, keys.KeyBackspace:
			m.cancelCtx()
		case keys.KeyCtrlC:
			m.quit = true
		}
		return
	}
	if m.mode == modeHints {
		m.hintsKey(ev)
		return
	}
	if m.mode == modeQuickLook {
		m.qlKey(ev)
		return
	}
	if m.mode == modeProps {
		m.propsKey(ev)
		return
	}
	if m.mode == modeSearchInput {
		m.searchKey(ev)
		return
	}
	if m.mode == modeSearchHits {
		m.hitsKey(ev)
		return
	}
	if m.mode == modeConfirmDelete {
		// #2894: the prompt answers y/Y only — every other key sheds it
		// instead of being swallowed, so a stray 'd' cannot hold the
		// keyboard hostage until a much-later stray 'y' commits. The
		// shedding key is consumed (the same dismiss-and-swallow rule
		// the context menu's off-plate press uses): a key that was never
		// meant as an answer must not also act on the list.
		switch ev.Key {
		case keys.KeyRune:
			if ev.Rune == 'y' || ev.Rune == 'Y' {
				m.doDelete()
			} else {
				m.cancelDelete("key=" + keyLabel(ev))
			}
		case keys.KeyCtrlC:
			m.quit = true
		default:
			m.cancelDelete("key=" + keyLabel(ev))
		}
		return
	}

	switch ev.Key {
	case keys.KeyUp:
		m.move(-1)
	case keys.KeyDown:
		m.move(1)
	case keys.KeyPageUp:
		m.move(-m.bodyRows())
	case keys.KeyPageDown:
		m.move(m.bodyRows())
	case keys.KeyHome:
		m.moveTo(0)
	case keys.KeyEnd:
		m.moveTo(m.n - 1)
	case keys.KeyEnter:
		m.openSel()
	case keys.KeyBackspace, keys.KeyEsc:
		m.goUp()
	case keys.KeyCtrlC:
		m.quit = true
	case keys.KeyCtrlZ:
		// M121e (#2568): the seat's ctrl+z chord reaches this tty-bound
		// tab as the 0x1a control byte; it is the `u` key's own path —
		// restore the newest trashed entry. Called on the model receiver
		// (Update's copy) so the marker/status survive the value write-back.
		m.restoreLatest()
	case keys.KeyTab:
		m.toggleView()
	case keys.KeyRune:
		switch ev.Rune {
		case 'j':
			m.move(1)
		case 'k':
			m.move(-1)
		case 'h':
			m.goUp()
		case 'l':
			m.openSel()
		case 'g':
			m.moveTo(0)
		case 'G':
			m.moveTo(m.n - 1)
		case 'q':
			m.quit = true
		case 'v':
			m.showVolumes()
		case 's':
			m.cycleSort()
		case 'r':
			m.startRename()
		case 'd':
			m.startDelete()
		case 'u':
			m.restoreLatest()
		case 'c':
			m.yankClip(false)
		case 'x':
			m.yankClip(true)
		case 'p':
			m.pasteClip()
		case ' ':
			m.openQuickLook()
		case 'i':
			m.openProps()
		case 'm':
			m.toggleMark()
		case 'M':
			m.clearMarks()
		case '/':
			m.startSearch()
		case 'o':
			m.startOpenWith()
		case 'e':
			m.exportSel()
		case '?':
			m.openHints()
		}
	}
}

// openHints raises the M121c (#2566) '?' overlay — the registry's rows for
// this app's scope plus the seat's globals and the kernel terminal chrome,
// all read off chords.Global so a hard-coded sheet can never drift. The
// row markers ride pending like every other model receipt, so they print
// after the frame that carries them.
func (m *model) openHints() {
	m.hints = appkit.NewChordHints(hintsBin, chords.ScopeKernelTerminal)
	m.hints.R.W = m.cols * 8 // the overlay plate's logical width only — Lines uses cells
	m.mode = modeHints
	m.emit(markerHints + "n=" + vi.Itoa64(int64(m.hints.ChordRows())))
	for _, l := range m.hints.RowLines() {
		m.emit(markerHintsRow + l)
	}
}

// hintsKey is the modeHints keyboard contract: Esc or a second '?' hands
// the frame back to the list, and the nav keys scroll a list taller than
// the window.
func (m *model) hintsKey(ev keys.Event) {
	vis := m.rows - 2 // the renderHints list window: title + footer off-grid
	if vis < 1 {
		vis = 1
	}
	switch ev.Key {
	case keys.KeyEsc:
		m.closeHints()
	case keys.KeyRune:
		if ev.Rune == '?' {
			m.closeHints()
		}
	case keys.KeyUp:
		m.hints.Move(-1)
	case keys.KeyDown:
		m.hints.Move(1)
	case keys.KeyPageUp:
		m.hints.Move(-vis)
	case keys.KeyPageDown:
		m.hints.Move(vis)
	case keys.KeyHome:
		m.hints.Scroll = 0
	case keys.KeyEnd:
		m.hints.Scroll = len(m.hints.Rows) - vis
		if m.hints.Scroll < 0 {
			m.hints.Scroll = 0
		}
	case keys.KeyCtrlC:
		m.quit = true
	}
}

func (m *model) closeHints() {
	m.mode = modeNormal
	m.emit(markerHints + "close")
}

// showVolumes is the `v` chord: jump straight to the volumes root —
// the kernel's mount table (M134b #2760), the same view Backspace/`h`
// reaches from a mount root.
func (m *model) showVolumes() {
	if m.path == volsPath {
		return
	}
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
// but nothing paints it in viewList.
func (m *model) toggleView() {
	if m.view == viewSplit {
		m.view = viewList
	} else {
		m.view = viewSplit
	}
	m.emit(markerViewMode + viewNameOf(m.view))
	m.status = "view " + viewNameOf(m.view)
}

func viewNameOf(v viewMode) string {
	if v == viewList {
		return "list"
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
	if m.path != volsPath {
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
	m.loadPreview()
}

// atVolumes guards the mutating ops: the volumes root is the mount table,
// so there is nothing to rename, trash, hold or write into — each op names
// that rather than sending the kernel a path it could never honor.
func (m *model) atVolumes() bool {
	if m.path == volsPath {
		m.status = "volumes: browse only"
		return true
	}
	return false
}

// startRename opens the prompt with an EMPTY buffer: the typeable name is
// the new name (the gate types `newname.txt` one chord at a time).
func (m *model) startRename() {
	if m.atVolumes() {
		return
	}
	if _, ok := m.selEntry(); !ok {
		m.status = "rename: nothing selected"
		return
	}
	m.mode = modeRename
	m.input = ""
	m.status = "rename"
}

// commitRename validates, runs the syscall, and on success emits the gate's
// `gofiles: renamed <from> -> <to>` marker before the re-list markers.
func (m *model) commitRename() {
	from, ok := m.selEntry()
	m.mode = modeNormal
	if !ok {
		m.status = "rename: nothing selected"
		return
	}
	fromName := from.NameString()
	to := m.input
	switch {
	case to == "":
		m.status = "rename cancelled"
		return
	case !validName(to):
		m.emit(markerRenameNo + fromName + " -> " + to)
		m.status = "rename: invalid name"
		return
	case to == fromName:
		m.status = "rename unchanged"
		return
	case containsName(m.entries[:], m.n, to):
		m.emit(markerRenameNo + fromName + " -> " + to + " exists")
		m.raiseRenameConflict(fromName, to)
		return
	}
	rc := renameEntry(m.path, fromName, to)
	if rc < 0 {
		m.emit(markerRenameNo + fromName + " -> " + to + " rc=" + vi.Itoa64(rc))
		m.status = refusalStatus("rename", rc)
		return
	}
	m.emit(markerRenamed + fromName + " -> " + to)
	m.status = "renamed " + to
	m.renamedBatch = true
	m.refresh()
	m.status = "renamed " + to // refresh's "listed" must not mask it
}

// --- M123d (#2578): the shared error banner ---------------------------------
//
// The banner is the status row while it is open: raiseBanner shows it and
// latches bannerFresh when the raise happened after the batch's paint
// (drainLaunch's exec outcome), so main knows a second paint owes the
// frame. Keys route through bannerKey — the appkit vocabulary on the tty
// keyspace (digits pick actions, c is Copy Error, Enter takes the focused
// safe-last button, Esc/Backspace dismiss) — and the resolution runs
// through bannerResolve.

// raiseBanner opens the banner over the status row and emits the raise
// marker. The marker rides pending like every other model marker, so the
// serial line still lands only after a frame that shows the strip.
func (m *model) raiseBanner(text string, actions ...appkit.BannerAction) {
	m.banner.Show(text, actions...)
	m.bannerFresh = true
	m.emit(markerBanner + text)
}

// raiseExecRefusal is drainLaunch's failure arm, kept on the model so the
// raise itself is host-pinnable: the exec outcome lands after the batch's
// own paint (bannerFresh asks main for the strip's frame), carries no
// contextual actions — Copy Error and dismiss are the honest answers.
func (m *model) raiseExecRefusal(bin string, err error) {
	m.bannerOp = ""
	m.raiseBanner("exec " + bin + " refused: " + err.Error())
	m.status = "open: " + bin + " refused"
}

// raiseRenameConflict arms the Replace/Cancel banner for a name-exists
// rename. The refused pair is remembered on the model — Replace cannot
// re-ask the prompt, it runs delete-the-incumbent + rename directly.
// Cancel is listed LAST: it is the focused default, so Enter never arms
// the destructive arm by accident.
func (m *model) raiseRenameConflict(from, to string) {
	m.bannerOp = "rename"
	m.bannerFrom, m.bannerTo = from, to
	m.status = "rename: name exists"
	m.raiseBanner("rename "+to+" exists",
		appkit.BannerAction{ID: "replace", Label: "Replace"},
		appkit.BannerAction{ID: "cancel", Label: "Cancel"})
}

// bannerKey feeds one key to the open banner. A resolved banner (Choice
// set, Open cleared) hands straight to bannerResolve so the outcome — the
// replace, the copy, or the dismissal — is applied in the same batch.
func (m *model) bannerKey(ev keys.Event) {
	switch ev.Key {
	case keys.KeyEsc, keys.KeyBackspace:
		m.banner.Dismiss()
	case keys.KeyEnter:
		m.banner.ActivateFocused()
	case keys.KeyTab:
		m.banner.Cycle(1)
	case keys.KeyRune:
		switch {
		case ev.Rune >= '1' && ev.Rune <= '9':
			m.banner.Activate(int(ev.Rune - '1'))
		case ev.Rune == 'c' || ev.Rune == 'C':
			m.banner.CopyChoice()
		}
	case keys.KeyCtrlC:
		m.quit = true
	}
	if !m.banner.Open {
		m.bannerResolve()
	}
}

// bannerResolve acts on the banner's Choice once it closes. `replace`
// runs the held rename's overwrite arm; `copy` publishes the error text
// on the machine clipboard (ClipText — the same slot-38 seam a file copy
// uses, different payload type); cancel/dismiss settles the prompt. Every
// path names itself on `gofiles: banner act …` — a banner that resolved
// silently would be a failure nobody saw answered.
func (m *model) bannerResolve() {
	choice := m.banner.Choice
	m.banner.Choice = ""
	op := m.bannerOp
	m.bannerOp = ""
	switch {
	case choice == appkit.BannerCopy:
		n, rc := vsys.ClipboardSetTyped(vsys.ClipText, []byte(m.banner.Text))
		if rc < 0 {
			m.emit(markerClipSys + "rc=" + vi.Itoa64(rc))
		} else {
			m.emit(markerClipSys + "n=" + vi.Itoa64(int64(n)))
		}
		m.emit(markerBannerAct + "copy")
		m.status = "error copied"
	case op == "rename" && choice == "replace":
		m.replaceRename()
	case op == "rename":
		m.emit(markerBannerAct + choice)
		m.status = "rename cancelled"
	default:
		m.emit(markerBannerAct + choice)
	}
}

// replaceRename is the conflict banner's Replace arm: the incumbent entry
// goes to TRASH (deleteEntry — lease-honest, and directories are refused
// at the model like startDelete's) and the held rename runs against the
// freed name. A refused delete leaves the rename untried; a `u` restore
// can still pull the incumbent back out of TRASH.
func (m *model) replaceRename() {
	from, to := m.bannerFrom, m.bannerTo
	m.bannerFrom, m.bannerTo = "", ""
	for i := 0; i < m.n; i++ {
		if m.entries[i].NameString() == to && m.entries[i].Dir() {
			m.emit(markerBannerAct + "replace refused dir")
			m.status = "replace: directories stay"
			return
		}
	}
	if _, rc := deleteEntry(m.path, to); rc < 0 {
		m.emit(markerBannerAct + "replace refused rc=" + vi.Itoa64(rc))
		m.status = refusalStatus("replace", rc)
		return
	}
	rc := renameEntry(m.path, from, to)
	if rc < 0 {
		m.emit(markerRenameNo + from + " -> " + to + " rc=" + vi.Itoa64(rc))
		m.status = refusalStatus("rename", rc)
		return
	}
	m.emit(markerRenamed + from + " -> " + to)
	m.emit(markerBannerAct + "replace " + to)
	m.status = "renamed " + to
	m.renamedBatch = true
	m.refresh()
	m.status = "renamed " + to
}

// startDelete arms the confirm step for a file — or, with marks present
// (M155b #2930), ONE confirm for the whole set: the prompt asks once and
// names the count, and 'y' queues the delete batch. Directories are
// refused honestly (ADR 0007 has no rmdir slot, so EASY delete would fail
// anyway) — the set cannot contain one because marks refuse them first.
func (m *model) startDelete() {
	if m.atVolumes() {
		return
	}
	if set := m.markedSet(); len(set) > 0 {
		m.mode = modeConfirmDelete
		m.delName = ""
		m.delSet = set
		m.emit(markerDeleteArm + "n=" + vi.Itoa64(int64(len(set))))
		m.status = "delete " + vi.Itoa64(int64(len(set))) + " marked? y/n"
		return
	}
	e, ok := m.selEntry()
	if !ok {
		m.status = "delete: nothing selected"
		return
	}
	if e.Dir() {
		m.emit(markerDeleteNo + e.NameString() + " (dir)")
		m.status = "delete: directories not supported"
		return
	}
	m.mode = modeConfirmDelete
	m.delName = e.NameString()
	m.emit(markerDeleteArm + m.delName)
	m.status = "delete " + m.delName + "? y/n"
}

// cancelDelete sheds the armed confirm without deleting: n/Esc, the
// first key that is not an answer, or a pointer press. The marker names
// the file the prompt held and what shed it — the arm/cancel pair is
// the serial receipt an armed-but-silent prompt never left (#2894).
func (m *model) cancelDelete(cause string) {
	if m.mode != modeConfirmDelete {
		return
	}
	m.mode = modeNormal
	if len(m.delSet) > 0 {
		m.emit(markerDeleteCancel + "n=" + vi.Itoa64(int64(len(m.delSet))) + " " + cause)
		m.delSet = nil
	} else {
		m.emit(markerDeleteCancel + m.delName + " " + cause)
	}
	m.delName = ""
	m.status = "delete cancelled"
}

func (m *model) doDelete() {
	if len(m.delSet) > 0 {
		// M155b (#2930): the 'y' answered the set's one confirm — queue
		// the delete batch, stepped like every other batch. A batch still
		// running is named rather than queued behind itself.
		items := m.delSet
		m.delSet, m.delName = nil, ""
		m.mode = modeNormal
		if m.batchOn {
			m.status = "delete: a batch is running"
			return
		}
		m.startBatch(batchDelete, items, m.path)
		return
	}
	name := m.delName
	m.delName = ""
	m.mode = modeNormal
	e, ok := m.selEntry()
	if !ok {
		m.status = "delete: nothing selected"
		return
	}
	if e.NameString() != name {
		// The listing shifted under the armed prompt — the 'y' answered
		// a different file's name, so the answer expired with it.
		m.emit(markerDeleteCancel + name + " key=stale")
		m.status = "delete cancelled"
		return
	}
	id, rc := deleteEntry(m.path, name)
	if rc < 0 {
		m.emit(markerDeleteNo + name + " rc=" + vi.Itoa64(rc))
		m.status = refusalStatus("delete", rc)
		return
	}
	m.emit(markerDeleted + name + " trash=" + id)
	m.status = "deleted " + name
	m.refresh()
	m.status = "deleted " + name
}

// restoreLatest restores the newest item in the shared trash. The vi helper
// refuses an occupied original path, so restore never overwrites user data.
func (m *model) restoreLatest() {
	path, id, rc := vi.TrashRestoreLatest()
	if rc < 0 {
		m.emit(markerRestoreNo + "rc=" + vi.Itoa64(rc))
		m.status = "restore refused"
		return
	}
	name := baseName(path)
	m.status = "restored " + name
	if parentPath(path) == m.path {
		m.refresh()
		m.status = "restored " + name
	}
	// Emit after refresh so a gate waiting on this marker also observes the
	// restored item in the immediately preceding listing rows.
	m.emit(markerRestored + name + " trash=" + id)
}

// yankClip holds the selected file — or the whole marked set (M155b
// #2930) — for a later paste (c = copy, x = move). The set is queued in
// listing order so the batch's progress sequence reads the way the list
// did. A copy also publishes the sources' URIs on the machine clipboard
// (one file:// line each); a cut publishes nothing.
func (m *model) yankClip(cut bool) {
	if m.atVolumes() {
		return
	}
	verb := "copy"
	if cut {
		verb = "cut"
	}
	if names := m.markedSet(); len(names) > 0 {
		var set []string
		for _, name := range names {
			src, ok := joinPath(m.path, name)
			if !ok {
				m.emit(markerClip + verb + " refused " + name + " path")
				m.status = "clip: path too long"
				return
			}
			set = append(set, src)
		}
		m.clipSet = set
		m.clipCut = cut
		m.emit(markerClip + verb + " set n=" + vi.Itoa64(int64(len(set))))
		m.status = verb + " " + vi.Itoa64(int64(len(set))) + " marked"
		if !cut {
			m.publishClipURIs(set)
		}
		return
	}
	e, ok := m.selEntry()
	if !ok {
		m.status = "clip: nothing selected"
		return
	}
	if e.Dir() {
		m.emit(markerPasteNo + e.NameString() + " (dir)")
		m.status = "clip: files only"
		return
	}
	src, ok := joinPath(m.path, e.NameString())
	if !ok {
		m.status = "clip: path too long"
		return
	}
	m.clipSet = []string{src}
	m.clipCut = cut
	m.emit(markerClip + verb + " " + e.NameString())
	m.status = verb + " " + e.NameString()
	if !cut {
		// M124c (#2582): a copy also publishes the file's URI on the
		// machine clipboard as text/uri-list — "copy file → paste path"
		// — while the in-app clip keeps its own paste semantics. A cut
		// publishes nothing: the URI would name a path about to go
		// stale. EACCES under the seat lands on the marker like every
		// other refused op; the local clip already succeeded.
		m.publishClipURIs([]string{src})
	}
}

// pasteClip materializes the held file(s) in the current directory: copy
// reads the bytes and safe-writes them, move renames. An existing target
// is refused — a paste never overwrites. A queued SET (M155b #2930)
// hands off to the batch planner, which steps the items one per frame.
func (m *model) pasteClip() {
	if len(m.clipSet) == 0 {
		m.emit(markerPasteNo + "empty clip")
		m.status = "paste: nothing held"
		return
	}
	if m.atVolumes() {
		return
	}
	if len(m.clipSet) > 1 {
		m.startPasteBatch()
		return
	}
	src := m.clipSet[0]
	name := baseName(src)
	if m.clipCut && volumeOf(src) != volumeOf(m.path) {
		// A rename is same-volume only by ABI (ADR 0050 D6: pin_rename
		// refuses a cross-partition pair), so a held move cannot land off
		// its own volume — copy (c) crosses volumes; move (x) does not.
		m.emit(markerPasteNo + name + " cross-volume")
		m.status = "paste: a move stays on one volume"
		return
	}
	if containsName(m.entries[:], m.n, name) {
		m.emit(markerPasteNo + name + " exists")
		m.status = "paste: name exists"
		return
	}
	if m.clipCut {
		rc := pasteMove(m.path, src)
		if rc < 0 {
			m.emit(markerPasteNo + name + " rc=" + vi.Itoa64(rc))
			m.status = refusalStatus("paste", rc)
			return
		}
		m.emit(markerPasted + name)
		m.status = "moved " + name
		m.notifyToast("moved " + name)
		m.clipSet = nil
		m.refresh()
		m.status = "moved " + name
		return
	}
	data, rc := readCapped(src, maxPasteBytes)
	if rc < 0 {
		m.emit(markerPasteNo + name + " rc=" + vi.Itoa64(rc))
		m.status = "paste refused"
		return
	}
	if len(data) >= maxPasteBytes {
		m.emit(markerPasteNo + name + " at read cap")
		m.status = "paste: file too large"
		return
	}
	rc = pasteCopy(m.path, src, data)
	if rc < 0 {
		m.emit(markerPasteNo + name + " rc=" + vi.Itoa64(rc))
		m.status = refusalStatus("paste", rc)
		return
	}
	m.emit(markerPasted + name)
	m.status = "copied " + name
	m.notifyToast("copied " + name)
	m.refresh()
	m.status = "copied " + name
}

// keyLabel names a decoded key for the `gofiles: key …` marker, using the
// same vocabulary the gate's chord tokens use (return/backspace/down/…).
func keyLabel(ev keys.Event) string {
	switch ev.Key {
	case keys.KeyRune:
		if ev.Rune == ' ' {
			return "space"
		}
		return string(ev.Rune)
	case keys.KeyEnter:
		return "return"
	case keys.KeyEsc:
		return "escape"
	case keys.KeyBackspace:
		return "backspace"
	case keys.KeyUp:
		return "up"
	case keys.KeyDown:
		return "down"
	case keys.KeyLeft:
		return "left"
	case keys.KeyRight:
		return "right"
	case keys.KeyHome:
		return "home"
	case keys.KeyEnd:
		return "end"
	case keys.KeyPageUp:
		return "pageup"
	case keys.KeyPageDown:
		return "pagedown"
	case keys.KeyTab:
		return "tab"
	case keys.KeyCtrlC:
		return "ctrl-c"
	case keys.KeyCtrlZ:
		return "ctrl-z"
	default:
		return "none"
	}
}
