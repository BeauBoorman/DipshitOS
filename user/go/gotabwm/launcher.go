// GOTABWM.ELF — the pointer-first Apps affordance and Ctrl+Space share one
// APPS.TXT catalog, exec path and seat-owned input sink.
//
// #2054 (the Quicksilver upgrade): the palette is no longer a centred panel —
// it is a vertical strip docked to the scanout's LEFT edge, the sexiburger
// emblem on top, the "Where do you want to go today?" prompt under it, the
// filter field under that, and a ranked single-column result list below.
// The emblem is the real mascot raster (image/WALLPAPER.QOI-style staging:
// /host/SEXIBURGER.QOI decoded by the virelai/webrender/qoi leaf), not a
// rect-drawn approximation, and the chrome's god-menu button and start
// surface carry the same mark so hotkey and pointer converge on one path.
//
// M82a (#1768): the row the manifest gives is the row that launches. The
// `argv=` field's fixed arguments ride the exec, and the decode receipt says
// what the manifest said — how many rows, the highest row version, and how
// many rows spoke each trailing key (a zero is reported, not hidden).
//
// M191b (#3243): the launcher learns verbs. A non-empty filter adds a
// second result kind — bounded filename hits under the share — and every
// row carries a verb affordance (Tab or the horizontal arrows): open,
// reveal in GOFILES, and the manifest's opens= candidates for the hit's
// mime spelling. The M165f "Search files for" hand-off rides last on
// this face too — content search stays GOFILES' walk, never inline.
package main

import (
	"errors"

	"virelai/draw"
	"virelai/find"
	"virelai/mime"
	"virelai/theme"
	"virelai/vi"
	"virelai/webrender/qoi"
	"virelai/widgets"
)

const (
	MarkerLaunchOpen    = "gotabwm: launcher open n="
	MarkerLaunchFilter  = "gotabwm: launcher filter q="
	MarkerLaunchExec    = "gotabwm: launcher exec "
	MarkerLaunchDismiss = "gotabwm: launcher dismiss"
	MarkerLaunchMissing = "gotabwm: launcher missing "
	MarkerLaunchEmblem  = "gotabwm: launcher emblem "
	// M123b (#2576): the zero-match empty state — printed once per filter
	// change from the frame that painted the shared plate, not per paint.
	MarkerLaunchEmpty = "gotabwm: launcher empty"
	MarkerAppsDecode  = "gotabwm: apps decode n="

	// M191b (#3243): the filename-hit walk, the verb affordance and the
	// launcher's own face of the M165f search hand-off.
	MarkerLaunchFiles  = "gotabwm: launcher files "
	MarkerLaunchVerb   = "gotabwm: launcher verb "
	MarkerLaunchSearch = "gotabwm: launcher search q="

	hidUsageSpace  uint8 = 0x2C
	hidUsageEnter  uint8 = 0x28
	hidUsageEscape uint8 = 0x29
	hidUsageBksp   uint8 = 0x2A
	hidUsageLeft   uint8 = 0x50
	hidUsageDown   uint8 = 0x51
	hidUsageUp     uint8 = 0x52
	hidUsageRight  uint8 = 0x4F

	// The strip: docked at the left edge, full scanout height. The seat's
	// 2px accent rule marks the edge facing the desktop, the same mark the
	// clock panel carries on its left.
	launchX    = 0
	launchY    = 0
	launchW    = 264
	launchRule = 2

	// Header block inside the strip: emblem, prompt, filter field, the
	// error/status line, then the results list at launchHdr.
	launchAvatarY = 16
	launchEmblem  = 64 // the staged mascot_64x64.qoi raster
	launchPromptY = launchAvatarY + launchEmblem + 8
	launchFieldY  = launchPromptY + 16
	launchFieldH  = 20
	launchErrY    = launchFieldY + launchFieldH + 4
	launchHdr     = launchErrY + 12

	// launchPrompt is the AC-B1 prompt text — byte-identical by card.
	launchPrompt = "Where do you want to go today?"

	filterMax = 24

	// The emblem's staging path and decode budget: /host/SEXIBURGER.QOI is
	// the repo's existing mascot_64x64.qoi fixture, copied to the share by
	// gate-run/session.sh exactly like APPS.TXT and WALLPAPER.QOI.
	emblemPath     = "/host/SEXIBURGER.QOI"
	emblemMaxBytes = 65536
	emblemMaxDim   = 256
	emblemMaxPix   = 256 * 256

	// M191b: the filename-hit bounds. The walk covers the share's subtree
	// to M155c's own depth and never counts more entries than GOFILES'
	// search looks at files — the launcher's budget is the walk's, not
	// doubled (the M155c walk bounds are the card's ceiling).
	launchFileMaxDepth = 4
	launchFileMaxVisit = 256
	// The entry cap is the rows a strip can honestly offer — GOFILES'
	// 64-hit bound is the content walk's, not a name list's.
	launchFileMaxHits = 16
	launchFilesRoot   = "/host"
	launchMaxPath     = 64 // the kernel path cap (files' maxPath)

	// launchFileIdx0 is the filtered-index sentinel file hits sit at:
	// hit j encodes as launchFileIdx0-j, so every file index is <= -2 —
	// distinct from the manifest indices (>=0) and paletteSearchIdx (-1).
	launchFileIdx0 = -2
)

type launcherState struct {
	open       bool
	palette    bool // M121a: the strip is the command palette, not the APPS.TXT launcher
	catalog    []AppEntry
	results    []paletteEntry // palette-mode catalog (launcher.go ranks one of the two)
	filter     string
	filtered   []int
	sel        int
	first      int // first visible filtered row
	reasons    []string
	err        string
	sink       uint32
	prior      uint32
	painted    bool
	emptyShown bool // M123b: the `empty` marker printed for the current frame
	// M165f (#2978): the palette's synthetic "Search files for '<q>'"
	// row. Not a results entry — refresh rebuilds it on each filter
	// change and filtered carries the paletteSearchIdx sentinel for it,
	// always last. M191b gives the launcher's own face the same row: a
	// query with no name hit still has one honest answer, and it is the
	// hand-off, not an inline content search.
	search paletteEntry
	width      int
	height     int
	launching  bool

	// M191b: the filename hits. filtered rows encoded <= launchFileIdx0
	// index into hits; hitsVisit is the entries the last walk counted
	// and hitsTrunc names the bound that stopped it ("" when none did).
	hits      []launchHit
	hitsTrunc string
	hitsVisit int
	// The verb affordance. verbSel is the selection verbs were built
	// for (-1 disarmed — selection moves and filter changes disarm, a
	// pointer click on a different row disarms the same way), verb is
	// the armed index into verbs, and verbs is the cached list: verb 0
	// is the row's own open, verb 1 reveal-in-GOFILES, the rest the
	// opens= candidates for the hit's mime spelling.
	verbSel int
	verb    int
	verbs   []launchVerb

	// emblem is the decoded mascot raster, decoded once lazily (the
	// god-menu button paints it every tick, long before the first
	// summon). tried gates the one-shot marker and the retry: a share
	// that lacks the file is named once per boot, not once per paint.
	// It lives on launcherState so the seat-state snapshot tests already
	// take carries it. The scaled variants the old box filter memoized
	// are gone: BlitScaled resamples from this one decode per paint.
	emblem emblemState
}

type emblemState struct {
	tried bool
	w, h  int
	pix   []uint32
}

// launchHit is one filename hit — the second result kind M191b adds.
// path is what the verbs act on, name the base name the row paints, dir
// the parent GOFILES opens at on a reveal.
type launchHit struct {
	path string
	name string
	dir  string
}

// launchVerb is one row's verb affordance. name is the marker word and
// the second-line text ("open", "reveal", "open-with <Label>"); bin/argv
// are the exec when the verb commits — bin == "" on the manifest row's
// own "open", which is not a verb exec but the M82a contract itself.
type launchVerb struct {
	name string
	bin  string
	argv []string
}

var launch launcherState

// readAppsFile is the share-file read seam: APPS.TXT at summon, and since
// #2054 the SEXIBURGER.QOI emblem — one seam, both fixtures a host test
// stages without a second indirection.
var readAppsFile = vi.ReadFileAll

func launcherEmblem() []uint32 {
	em := &launch.emblem
	if !em.tried {
		em.tried = true
		body, r := readAppsFile(emblemPath, emblemMaxBytes)
		if r >= 0 && body != nil {
			w, h, pix, err := qoi.Decode(body, emblemMaxDim, emblemMaxPix)
			if err == nil {
				em.w, em.h, em.pix = w, h, pix
			}
		}
		if em.pix != nil {
			vi.ConsoleLine(MarkerLaunchEmblem + "qoi " +
				vi.Itoa64(int64(em.w)) + "x" + vi.Itoa64(int64(em.h)))
		} else {
			vi.ConsoleLine(MarkerLaunchEmblem + "unavailable")
		}
	}
	return em.pix
}

func appUnavailable(e AppEntry) string {
	bin := e.Bin
	if bin == "TABWM.BIN" || bin == "GOTABWM.ELF" || bin == "WND.BIN" {
		return "Seat: use settings wm"
	}
	h, r := openFile("/host/"+bin, vi.ModeRead)
	if r < 0 {
		return "Binary not staged"
	}
	vi.FileClose(uint32(h))
	return ""
}

func (l *launcherState) rowH() int {
	h := theme.Current.PadLG + theme.Current.PadMD
	if h < 20 {
		h = 20
	}
	return h
}

// panelH is the strip's height: the full scanout, always — a docked edge
// panel does not size to content.
func (l *launcherState) panelH() int {
	return vi.ScanoutHeight
}

func (l *launcherState) refresh() {
	l.painted = false
	l.hits, l.hitsTrunc, l.hitsVisit = nil, "", 0
	l.verb, l.verbSel, l.verbs = 0, -1, nil
	if l.palette {
		l.filtered = rankPalette(l.results, l.filter)
	} else {
		l.filtered = rankApps(l.catalog, l.filter)
		if l.filter != "" {
			// M191b: filename hits are the second result kind — a
			// bounded name walk of the share ranked after the app
			// rows, never a content scan.
			l.walkFiles(l.filter)
			for j := range l.hits {
				l.filtered = append(l.filtered, launchFileIdx0-j)
			}
		}
	}
	if l.filter != "" {
		// M165f: a non-empty query always offers the file-search
		// hand-off, ranked last — ranking itself is unchanged. M191b
		// extends the same synthetic row to the launcher's own face,
		// where it is the answer to a content-intent query.
		l.search = paletteEntry{
			kind:   palSearch,
			label:  "Search files for '" + l.filter + "'",
			detail: "files · " + gofilesBin + " --search",
			arg:    l.filter,
		}
		l.filtered = append(l.filtered, paletteSearchIdx)
	}
	if l.sel >= len(l.filtered) {
		l.sel = len(l.filtered) - 1
	}
	if l.sel < 0 {
		l.sel = 0
	}
	l.first = 0
	l.emptyShown = false // the filter change re-arms the empty marker
	l.keepSelectionVisible()
}

func (l *launcherState) visibleRows() int {
	return (l.panelH() - launchHdr - theme.Current.PadMD) / l.rowH()
}

func (l *launcherState) keepSelectionVisible() {
	first := l.first
	n := l.visibleRows()
	if n < 1 {
		return
	}
	if l.sel < l.first {
		l.first = l.sel
	}
	if l.sel >= l.first+n {
		l.first = l.sel - n + 1
	}
	if l.first != first {
		l.painted = false
	}
}

// A row is only a target where its complete painted rectangle exists.
// Header pixels — emblem, prompt, filter field, the error line — are not
// targets, exactly like the old title band was not.
func (l *launcherState) rowRect(i, width, height int) (x, y, w, h int, ok bool) {
	x, y = launchX+theme.Current.PadMD, launchY+launchHdr+(i-l.first)*l.rowH()
	w, h = launchW-2*theme.Current.PadMD-launchRule, l.rowH()-theme.Current.PadXS
	ok = i >= l.first && i < len(l.filtered) && i < l.first+l.visibleRows() &&
		w > 0 && h >= 8 && x+w <= width && y+l.rowH() <= height
	return
}

func (l *launcherState) selected() (AppEntry, bool) {
	if l.sel < 0 || l.sel >= len(l.filtered) {
		return AppEntry{}, false
	}
	i := l.filtered[l.sel]
	if i < 0 || i >= len(l.catalog) {
		return AppEntry{}, false
	}
	return l.catalog[i], true
}

func openLauncher() {
	// M124a (#2580): seat chrome taking the gesture ends any armed drag
	// — the release the drag waited on is now a menu click.
	dragAbort("chrome")
	if launch.open && !launch.palette {
		dismissLauncher()
		return
	}
	if !launch.open {
		launch.err = ""
		launch.prior, _ = tabs.Focused()
		if !acquireLauncherFocus() {
			vi.ConsoleLine("gotabwm: launcher unavailable " + launch.err)
			// Never claim a modal menu while an app still owns keyboard focus.
			// The always-visible button paints the failed-open error instead.
			launch.open = launch.sink != 0
			return
		}
	}
	// M121a: the palette's strip swaps contents in place — the modal sink
	// and the prior-focus record carry over. A cold open takes both here.
	launch.palette = false
	launch.open = true
	loadLauncherCatalog()
}

// loadLauncherCatalog fills the strip with the APPS.TXT manifest and its
// per-row availability reasons, then publishes the decode/open markers.
// The palette's summon is the same shape over paletteSources (palette.go).
func loadLauncherCatalog() {
	launch.err = ""
	launch.catalog, launch.reasons, launch.filtered, launch.results = nil, nil, nil, nil
	launch.filter, launch.sel, launch.first = "", 0, 0
	launch.painted, launch.launching = false, false
	launch.hits, launch.hitsTrunc, launch.hitsVisit = nil, "", 0
	launch.verb, launch.verbSel, launch.verbs = 0, -1, nil
	body, r := readAppsFile(appsPath, appsMaxBytes)
	if r < 0 || body == nil {
		launch.catalog = nil
		launch.err = "APPS.TXT unavailable"
	} else {
		launch.catalog = parseAppsTXT(string(body))
	}
	launch.reasons = make([]string, len(launch.catalog))
	for i, e := range launch.catalog {
		launch.reasons[i] = appUnavailable(e)
	}
	launch.refresh()
	// The manifest's own report, before the launcher's: a reader that
	// silently ignored every v2 field would still print `launcher open n=14`,
	// so the decode numbers are what a gate reads to know the v2 fields were
	// decoded rather than skipped.
	s := SummarizeApps(launch.catalog)
	vi.ConsoleLine(MarkerAppsDecode + vi.Itoa64(int64(s.Rows)) +
		" v=" + vi.Itoa64(int64(s.Schema)) +
		" schema=" + vi.Itoa64(int64(appsSchemaVersion)) +
		" argv=" + vi.Itoa64(int64(s.Argv)) +
		" caps=" + vi.Itoa64(int64(s.Caps)) +
		" opens=" + vi.Itoa64(int64(s.Opens)))
	vi.ConsoleLine(MarkerLaunchOpen + vi.Itoa64(int64(len(launch.catalog))))
	vi.ConsoleLine(MarkerLaunchFilter + launch.filter + " n=" + vi.Itoa64(int64(len(launch.filtered))))
	// The emblem is warm by now (the chrome button decoded it on its first
	// paint), but calling it here pins the raster's presence to a summon:
	// the one-shot marker still names what the header will paint.
	_ = launcherEmblem()
}

func dismissLauncher() {
	if !launch.open {
		return
	}
	if !releaseLauncherFocus(true) {
		return
	}
	finishLauncher()
}

func finishLauncher() {
	marker := MarkerLaunchDismiss
	if launch.palette {
		marker = MarkerPaletteDismiss
	}
	launch.open = false
	launch.palette = false
	launch.filter = ""
	launch.painted = false
	vi.ConsoleLine(marker)
}

func emitLaunchFilter() {
	if launch.palette {
		emitPaletteFilter()
		return
	}
	vi.ConsoleLine(MarkerLaunchFilter + launch.filter + " n=" + vi.Itoa64(int64(len(launch.filtered))))
}

func execSelected() {
	if launch.palette {
		paletteExecSelected()
		return
	}
	if launch.launching {
		if releaseLauncherFocus(false) {
			finishLauncher()
		}
		return
	}
	if launch.sel >= 0 && launch.sel < len(launch.filtered) {
		ci := launch.filtered[launch.sel]
		switch {
		case ci == paletteSearchIdx:
			// The M165f hand-off row — the launcher's own face runs
			// the same `GOFILES.ELF --search <q>` the palette's does.
			if !ensureLauncherFocus() {
				return
			}
			if !launchExecSearch(launch.search.arg) {
				return
			}
			launch.launching = true
			if releaseLauncherFocus(false) {
				finishLauncher()
			}
			return
		case ci <= launchFileIdx0, launch.verbArmed():
			// M191b: a filename hit — or any row with an armed verb —
			// dispatches its verb, not the manifest contract.
			launch.execVerbRow(ci)
			return
		}
	}
	launch.execManifestRow()
}

// execManifestRow is Enter on a manifest row: the M82a contract — the
// probe's named refusal first (unstaged binary, seat entry), then the
// exec with the row's fixed argv=. The verb affordance hands control
// back here for the row's own "open" so a wrapped-around verb never
// bypasses the checks.
func (l *launcherState) execManifestRow() {
	e, ok := launch.selected()
	if !ok || e.Bin == "" {
		return
	}
	if !ensureLauncherFocus() {
		return
	}
	ci := launch.filtered[launch.sel]
	if ci < len(launch.reasons) && launch.reasons[ci] != "" {
		launch.err = launch.reasons[ci]
		return
	}
	bin := e.Bin
	// Non-app seat entries are refused even if a caller skipped the probe.
	if bin == "TABWM.BIN" || bin == "GOTABWM.ELF" || bin == "WND.BIN" {
		launch.err = "Seat: use settings wm"
		return
	}
	// Preserve the manifest's fixed argv; v1 rows still launch with argc=0.
	_, err := execApp(bin, e.Args...)
	if err != nil {
		vi.ConsoleLine(MarkerLaunchMissing + e.Bin)
		launch.err = "Launch failed: " + bin
		// M123a (#2575): the serial marker keeps its job; the toast
		// gives the refusal a face with a per-errno action.
		seatRefusalErr(err, "exec "+bin, bin)
		return
	}
	// M188a: the marker reports the declared ceiling the kernel now
	// enforces — the manifest's caps= plus the implied runtime floor.
	caps := ""
	if len(e.Caps) > 0 {
		caps = " caps=" + vi.GrantWordsCanonical(vi.CapsCeiling(e.Caps))
	}
	if len(e.Args) > 0 {
		vi.ConsoleLine(MarkerLaunchExec + e.Bin + " argv=" + joinSpace(e.Args) + caps)
	} else {
		vi.ConsoleLine(MarkerLaunchExec + e.Bin + caps)
	}
	launch.launching = true
	if releaseLauncherFocus(false) {
		finishLauncher()
	}
}

// joinSpace renders a decoded argv for the marker. It is the inverse of the
// `argv=` split, so the marker and the manifest read the same.
func joinSpace(args []string) string {
	out := ""
	for i, a := range args {
		if i > 0 {
			out += " "
		}
		out += a
	}
	return out
}

// --- M191b (#3243): filename hits + verb rows -----------------------------
//
// The launcher finds; these verbs make it act. A non-empty filter adds a
// second result kind — filenames under the share matching the query — and
// every result row carries a verb affordance (Tab or the horizontal
// arrows cycle): open (the row's own Enter), reveal in GOFILES (the file
// manager open at the containing folder), and one open-with row per
// manifest opens= candidate for the hit's mime spelling. Content search
// is not a verb — the M165f hand-off row stays the answer to 'find
// inside files', on this face exactly as on the palette's.

// launchDirList is the walk's directory seam — vi.DirList on the guest,
// swapped by the host tests (the searchDirList/readAppsFile pattern).
var launchDirList = vi.DirList

var errLaunchRead = errors.New("launcher: head unreadable")

// launchHeadRead adapts the share-file seam to mime.Open's ReadFunc.
func launchHeadRead(p string, max int) ([]byte, error) {
	b, rc := readAppsFile(p, max)
	if rc < 0 {
		return nil, errLaunchRead
	}
	return b, nil
}

// walkFiles runs the bounded name walk for one filter change. Every
// bound the walk reaches is named in the marker (truncated=<bound>) the
// way GOFILES names its own: the hits already collected are real.
func (l *launcherState) walkFiles(q string) {
	needle := make([]byte, len(q))
	for i := 0; i < len(q); i++ {
		needle[i] = find.FoldByte(q[i])
	}
	l.walkFilesDir(launchFilesRoot, 0, needle)
	line := MarkerLaunchFiles + "q=" + q +
		" n=" + vi.Itoa64(int64(len(l.hits))) +
		" visited=" + vi.Itoa64(int64(l.hitsVisit))
	if l.hitsTrunc != "" {
		line += " truncated=" + l.hitsTrunc
	}
	vi.ConsoleLine(line)
}

// walkFilesDir lists one directory, collects its matching filenames,
// then descends — files before subdirs, the same order GOFILES' search
// walks so a too-deep directory cannot cut off same-depth files the
// bound still covers. Every listed entry counts toward the traversal
// bound; only files can match.
func (l *launcherState) walkFilesDir(dir string, depth int, needle []byte) {
	var ents [vi.MaxDirEntries]vi.DirEntry
	n, rc := launchDirList(dir, ents[:])
	if rc < 0 {
		return // an unreadable dir contributes nothing — its parent still counts
	}
	for i := 0; i < n; i++ {
		if l.hitsTrunc != "" {
			return
		}
		if l.hitsVisit >= launchFileMaxVisit {
			l.hitsTrunc = "visited"
			return
		}
		l.hitsVisit++
		if ents[i].Dir() {
			continue
		}
		name := ents[i].NameString()
		if !find.ContainsFold([]byte(name), needle) {
			continue
		}
		path, ok := launchJoin(dir, name)
		if !ok {
			continue
		}
		if len(l.hits) >= launchFileMaxHits {
			l.hitsTrunc = "hits"
			return
		}
		l.hits = append(l.hits, launchHit{path: path, name: name, dir: dir})
	}
	for i := 0; i < n; i++ {
		if l.hitsTrunc != "" {
			return
		}
		if !ents[i].Dir() {
			continue
		}
		if depth+1 > launchFileMaxDepth {
			l.hitsTrunc = "depth"
			return
		}
		child, ok := launchJoin(dir, ents[i].NameString())
		if !ok {
			continue
		}
		l.walkFilesDir(child, depth+1, needle)
	}
}

// launchJoin joins a dir entry to its parent under the kernel path cap —
// a name that cannot form a legal path is visited but never a hit.
func launchJoin(dir, name string) (string, bool) {
	if name == "" || name == "." || name == ".." {
		return "", false
	}
	out := dir + "/" + name
	if len(out) > launchMaxPath {
		return "", false
	}
	return out, true
}

// verbsFor builds the selected row's verb list. Every result gets open
// and reveal; the manifest's opens= rows whose admission takes the
// file's mime spelling follow as open-with. The hand-off row is the one
// row with a single gesture — verbs are for results, not affordances.
func (l *launcherState) verbsFor(ci int) []launchVerb {
	switch {
	case ci == paletteSearchIdx:
		return nil
	case ci <= launchFileIdx0:
		j := launchFileIdx0 - ci
		if j < 0 || j >= len(l.hits) {
			return nil
		}
		h := l.hits[j]
		vs := []launchVerb{l.openFileVerb(h)}
		vs = append(vs, launchVerb{name: "reveal", bin: gofilesBin, argv: []string{h.dir}})
		return append(vs, l.openWithVerbs(h.path, h.name)...)
	case ci >= 0 && ci < len(l.catalog):
		// A manifest row's file is its binary on the share: reveal
		// lists /host, open-with routes the .ELF's own spelling.
		path := "/host/" + l.catalog[ci].Bin
		vs := []launchVerb{{name: "open"}}
		vs = append(vs, launchVerb{name: "reveal", bin: gofilesBin, argv: []string{"/host"}})
		return append(vs, l.openWithVerbs(path, l.catalog[ci].Bin)...)
	}
	return nil
}

// openFileVerb resolves a filename hit's open: the M81b mime dispatch
// GOFILES' Enter takes, with GOFILES at the containing folder as the
// no-handler (and unreadable) fallback — the drop-open precedent.
func (l *launcherState) openFileVerb(h launchHit) launchVerb {
	req, err := mime.Open(h.path, "/", launchHeadRead)
	if err != nil {
		return launchVerb{name: "open", bin: gofilesBin, argv: []string{h.dir}}
	}
	return launchVerb{name: "open", bin: req.Handler.Bin, argv: []string{req.Target}}
}

// openWithVerbs is the opens= candidate list for one path: every
// manifest row whose opens= accepts the file's mime spelling, in
// manifest order — the same candidates GOFILES' Open With… submenu
// computes for it. An unreadable head has no spelling and no rows.
func (l *launcherState) openWithVerbs(path, name string) []launchVerb {
	head, rc := readAppsFile(path, mime.HeadBytes)
	if rc < 0 {
		return nil
	}
	mt := mime.Spelling(name, head)
	var out []launchVerb
	for _, e := range l.catalog {
		if !opensAccepts(e.Opens, mt) {
			continue
		}
		argv := append(append([]string{}, e.Args...), path)
		out = append(out, launchVerb{name: "open-with " + e.Label, bin: e.Bin, argv: argv})
	}
	return out
}

// hitRowText is the two-line text for a non-manifest row: the hand-off
// sentinel paints the palette row's own label/detail, a filename hit its
// base name and containing folder.
func (l *launcherState) hitRowText(ci int) (label, detail string) {
	if ci == paletteSearchIdx {
		return l.search.label, l.search.detail
	}
	j := launchFileIdx0 - ci
	if j < 0 || j >= len(l.hits) {
		return "", ""
	}
	return l.hits[j].name, l.hits[j].dir
}

// stepVerb cycles the armed verb on the selected row — Tab and the
// horizontal arrows walk the list in either direction. Selection moves
// and filter changes disarm (verbSel no longer names the selection).
func (l *launcherState) stepVerb(delta int) {
	if l.palette || l.sel < 0 || l.sel >= len(l.filtered) {
		return
	}
	ci := l.filtered[l.sel]
	if l.sel != l.verbSel {
		l.verb, l.verbSel, l.verbs = 0, l.sel, l.verbsFor(ci)
	}
	if n := len(l.verbs); n >= 2 {
		l.verb = (l.verb + delta + n) % n
		l.painted = false
		vi.ConsoleLine(MarkerLaunchVerb + l.verbs[l.verb].name)
	}
}

// verbArmed reports whether the selection still owns a built verb list.
func (l *launcherState) verbArmed() bool {
	return l.sel == l.verbSel && l.verb < len(l.verbs)
}

// effVerb is the verb Enter commits: the armed one, verb 0 (the row's
// own open) otherwise.
func (l *launcherState) effVerb() int {
	if l.verbArmed() {
		return l.verb
	}
	return 0
}

// execVerbRow runs the armed verb on the row filtered[sel] names — or
// the row's open when no verb is armed. The manifest row's own "open" is
// not a verb exec: it falls back to the manifest path itself so its
// refusal contract (unstaged binary, seat entry) stands unchanged.
func (l *launcherState) execVerbRow(ci int) {
	vs := l.verbsFor(ci)
	if len(vs) == 0 {
		return
	}
	i := l.effVerb()
	if i >= len(vs) {
		i = 0
	}
	v := vs[i]
	if v.bin == "" {
		l.execManifestRow()
		return
	}
	if !ensureLauncherFocus() {
		return
	}
	if _, err := execApp(v.bin, v.argv...); err != nil {
		vi.ConsoleLine(MarkerLaunchMissing + v.bin)
		l.err = "Launch failed: " + v.bin
		seatRefusalErr(err, "exec "+v.bin, v.bin)
		return
	}
	vi.ConsoleLine(MarkerLaunchExec + v.bin + " argv=" + joinSpace(v.argv))
	l.launching = true
	if releaseLauncherFocus(false) {
		finishLauncher()
	}
}

// launchExecSearch is the launcher face's half of the M165f hand-off:
// the palette's own exec shape — the 64-byte bound, the named refusal —
// under this face's marker name.
func launchExecSearch(q string) bool {
	if len(q) > paletteSearchMax {
		launch.err = "Search query too long (64 B max)"
		return false
	}
	if _, err := execApp(gofilesBin, "--search", q); err != nil {
		vi.ConsoleLine(MarkerLaunchMissing + gofilesBin)
		launch.err = "Launch failed: " + gofilesBin
		seatRefusalErr(err, "exec "+gofilesBin, gofilesBin)
		return false
	}
	vi.ConsoleLine(MarkerLaunchSearch + q)
	return true
}

// rankApps is the #2054 result model, three tiers over the catalog:
//
//  1. rows whose display name starts with the query,
//  2. rows the query is a substring of (label or binary, the old flat
//     match — apps.go's asciiContainsFold, unchanged),
//  3. fuzzy matches: the query as a subsequence of the label or of the
//     row's `argv=` — Quicksilver's type-a-few-letters reach.
//
// Tiers concatenate in manifest order, so a fixed query over a fixed
// catalog ranks identically on every paint (AC-C2).
func rankApps(catalog []AppEntry, q string) []int {
	if q == "" {
		idx := make([]int, 0, len(catalog))
		for i := range catalog {
			idx = append(idx, i)
		}
		return idx
	}
	// The bin is the app's stable identity; the label is presentation.
	// A query that hits the executable name ("edit" → GOEDIT.ELF) is a
	// stronger intent than one that only lands inside a display word
	// ("Text Editor" / "Code Editor" both contain it — go-wm-tabs run 22
	// observed the catalog-order tie exec'ing NOTE for "edit").
	var prefix, binSub, labelSub, fuzzy []int
	for i, e := range catalog {
		switch {
		case asciiPrefixFold(e.Label, q):
			prefix = append(prefix, i)
		case asciiContainsFold(e.Bin, q):
			binSub = append(binSub, i)
		case asciiContainsFold(e.Label, q):
			labelSub = append(labelSub, i)
		case asciiSubseqFold(e.Label, q) || asciiSubseqFold(joinSpace(e.Args), q):
			fuzzy = append(fuzzy, i)
		}
	}
	return append(append(append(prefix, binSub...), labelSub...), fuzzy...)
}

// asciiPrefixFold is tier 1's predicate: s starts with q, A–Z folded.
func asciiPrefixFold(s, q string) bool {
	if len(q) > len(s) {
		return false
	}
	for i := 0; i < len(q); i++ {
		if asciiFold(s[i]) != asciiFold(q[i]) {
			return false
		}
	}
	return true
}

// asciiSubseqFold is tier 3's predicate: every rune of q appears in s, in
// order, not necessarily adjacent ("clc" reaches "Calculator" — well, it
// would reach "64-bit Calc" through the substring tier first, which is the
// point of ranking: fuzzy is a floor, not a ceiling).
func asciiSubseqFold(s, q string) bool {
	j := 0
	for i := 0; i < len(s) && j < len(q); i++ {
		if asciiFold(s[i]) == asciiFold(q[j]) {
			j++
		}
	}
	return j == len(q)
}

// handleLauncherKey owns the launcher's MODAL keys. M82c (#1770): the
// summon chord itself (ctrl+space) is a registry row — hid.go's table
// dispatch opens the launcher with it when the launcher is closed; this
// handler owns only what happens while it is open, including the
// re-summon below.
func handleLauncherKey(e vi.Event) bool {
	usage := uint8(e.Arg0)
	ctrl := e.Flags&vi.ModCtrl != 0
	shift := e.Flags&vi.ModShift != 0
	alt := e.Flags&vi.ModAlt != 0
	if !launch.open {
		return false
	}
	if usage == hidUsageEscape {
		// #2054 AC-C4: Esc is a two-step dismiss. A non-empty filter
		// clears first — the keystroke nobody meant for the app still
		// cannot reach it — and only an already-clear filter dismisses.
		if launch.filter != "" {
			launch.filter = ""
			launch.refresh()
			emitLaunchFilter()
		} else {
			dismissLauncher()
		}
		return true
	}
	if !ensureLauncherFocus() {
		return true
	}
	if alt {
		return true // swallow while modal
	}
	switch usage {
	case hidUsageEnter:
		execSelected()
		return true
	case hidUsageUp, hidUsageDown:
		if usage == hidUsageUp && launch.sel > 0 {
			launch.sel--
		}
		if usage == hidUsageDown && launch.sel+1 < len(launch.filtered) {
			launch.sel++
		}
		launch.keepSelectionVisible()
		return true
	case hidUsageBksp:
		if len(launch.filter) > 0 {
			launch.filter = launch.filter[:len(launch.filter)-1]
			launch.refresh()
			emitLaunchFilter()
		}
		return true
	case hidUsageTab, hidUsageRight:
		// M191b: the verb affordance — Tab and the horizontal arrows
		// cycle the selected row's verbs in either direction.
		launch.stepVerb(1)
		return true
	case hidUsageLeft:
		launch.stepVerb(-1)
		return true
	}
	// Type-to-filter even if Ctrl is still down from the summon chord
	// (virtio HID keeps the modifier on the next report).
	if c, ok := hidUsageChar(usage); ok {
		if usage == hidUsageSpace && ctrl {
			// The summon chord while the launcher is open re-opens it —
			// the same behaviour the old top-of-handler summon had for
			// both open and closed (the closed case now dispatches
			// through the registry row). ctrl+shift+space stays
			// swallowed, exactly as before.
			if shift {
				return true
			}
			openLauncher()
			return true
		}
		if usage == hidUsageP && ctrl && shift {
			// M121a: the palette's own summon chord is modal too —
			// toggles an open palette, crosses over from the launcher.
			openPalette()
			return true
		}
		if len(launch.filter) < filterMax {
			launch.filter += string(c)
			launch.refresh()
			emitLaunchFilter()
		}
		return true
	}
	return true
}

func hidUsageChar(usage uint8) (byte, bool) {
	if usage >= 0x04 && usage <= 0x1d {
		return 'a' + (usage - 0x04), true
	}
	if usage >= 0x1e && usage <= 0x26 {
		return '1' + (usage - 0x1e), true
	}
	if usage == 0x27 {
		return '0', true
	}
	if usage == hidUsageSpace {
		return ' ', true
	}
	if usage == 0x2d {
		return '-', true
	}
	if usage == 0x37 {
		return '.', true
	}
	return 0, false
}

func launchRowAt(px, py uint32) (int, bool) {
	if !launch.open || !launch.painted {
		return 0, false
	}
	x, y := int(px), int(py)
	if y < launchY+launchHdr {
		return 0, false
	}
	row := launch.first + (y-launchY-launchHdr)/launch.rowH()
	// The scanout is fixed in the guest. Tests can also pin a clipped
	// paint; hit-testing then uses precisely that paint's dimensions.
	width, height := launch.width, launch.height
	rx, ry, rw, rh, ok := launch.rowRect(row, width, height)
	return row, ok && x >= rx && x < rx+rw && y >= ry && y < ry+rh
}

func paintLauncher(scan []byte, width, height int) int {
	launch.painted = false
	if !launch.open || width <= 0 || height <= 0 || len(scan) < 4 {
		return 0
	}
	c := seatCanvas(scan, width, height)
	if c == nil {
		return 0
	}
	maxH := c.H
	tok := theme.Current
	launch.painted, launch.width, launch.height = true, width, maxH
	// The strip is DOCKED chrome — flat plate, no shadow — with the seat's
	// accent rule on the edge facing the desktop.
	written := seatFill(c, widgets.Rect{X: launchX, Y: launchY, W: launchW, H: maxH}, tok.Surface)
	written += seatFill(c, widgets.Rect{X: launchX + launchW - launchRule, Y: launchY, W: launchRule, H: maxH}, tok.Accent)
	strip := widgets.Rect{X: launchX, Y: launchY, W: launchW - launchRule, H: maxH}
	// The emblem is the seat's front door: the real sexiburger raster,
	// centred in the strip and resampled by the engine's BlitScaled. A
	// share without it gets a bordered box and the marker's
	// `unavailable`, never a fabricated mascot.
	if icon := emblemCanvas(); icon != nil {
		dst := widgets.Rect{X: launchX + (launchW-launchRule-icon.W)/2,
			Y: launchY + launchAvatarY, W: icon.W, H: icon.H}
		draw.BlitScaled(c, icon, dst)
		written += seatArea(c, dst)
	} else {
		ex, ey := launchX+(launchW-launchRule-launchEmblem)/2, launchY+launchAvatarY
		written += seatFill(c, widgets.Rect{X: ex, Y: ey, W: launchEmblem, H: launchEmblem}, tok.Surface)
		written += seatFill(c, widgets.Rect{X: ex, Y: ey, W: launchEmblem, H: tok.BorderW}, tok.Border)
		written += seatFill(c, widgets.Rect{X: ex, Y: ey + launchEmblem - tok.BorderW, W: launchEmblem, H: tok.BorderW}, tok.Border)
		written += seatFill(c, widgets.Rect{X: ex, Y: ey, W: tok.BorderW, H: launchEmblem}, tok.Border)
		written += seatFill(c, widgets.Rect{X: ex + launchEmblem - tok.BorderW, Y: ey, W: tok.BorderW, H: launchEmblem}, tok.Border)
		seatText(c, strip, ex+24, ey+28, seatTextPx, "SB", tok.InkMuted)
	}
	prompt := launchPrompt
	if launch.palette {
		prompt = palettePrompt
	}
	seatText(c, strip, launchX+tok.PadMD, launchY+launchPromptY, seatTextPx, prompt, tok.Ink)
	// The filter field: an inset control with the §2.3.5 Accent focus
	// ring (the field IS the focus while the strip is open), the query,
	// then the caret — the keystroke sink made visible.
	fx, fy, fw := launchX+tok.PadMD, launchY+launchFieldY, launchW-2*tok.PadMD-launchRule
	field := widgets.Rect{X: fx, Y: fy, W: fw, H: launchFieldH}
	draw.StrokeRoundedRect(c, field, radiusControl, tok.FocusW, draw.Opaque(tok.Accent))
	draw.FillRoundedRect(c, field.Inset(tok.FocusW), radiusControl, draw.Opaque(tok.Bg))
	written += seatArea(c, field)
	q := launchText(launch.filter, (fw-14)/8)
	seatText(c, field, fx+6, fy+6, seatTextPx, q, tok.Ink)
	written += seatFill(c, widgets.Rect{X: fx + 8 + seatTextWidth(q, seatTextPx), Y: fy + 6, W: 1, H: 8}, tok.Caret)
	if launch.err != "" {
		seatText(c, strip, launchX+tok.PadMD, launchY+launchErrY, seatSmallPx, launchText(launch.err, 30), tok.Danger)
	}
	if len(launch.filtered) == 0 {
		// M123b (#2576): the shared empty-state plate in the results
		// region — icon, the same headlines, and the chords that still
		// answer on a zero-match strip.
		headline := "No matching apps"
		marker := MarkerLaunchEmpty
		if launch.palette {
			headline = "No matching commands"
			marker = MarkerPaletteEmpty
		}
		hints := []string{"type a filter · esc clears"}
		if launch.filter == "" {
			hints = []string{"esc dismisses"}
		}
		(&widgets.EmptyState{
			R: widgets.Rect{X: launchX + tok.PadMD, Y: launchY + launchHdr,
				W: launchW - 2*tok.PadMD - launchRule, H: maxH - launchHdr - tok.PadMD},
			Icon:     "?",
			Headline: headline,
			Hints:    hints,
			Face:     seatFaceUI(),
		}).Draw(c)
		written += seatArea(c, widgets.Rect{X: launchX + tok.PadMD, Y: launchY + launchHdr,
			W: launchW - 2*tok.PadMD - launchRule, H: maxH - launchHdr - tok.PadMD})
		if !launch.emptyShown {
			launch.emptyShown = true
			vi.ConsoleLine(marker)
		}
	}
	for i := launch.first; i < len(launch.filtered); i++ {
		x, y, w, rh, ok := launch.rowRect(i, width, maxH)
		if !ok {
			break
		}
		ci := launch.filtered[i]
		if launch.palette {
			e, ok := launch.paletteRow(ci)
			if !ok {
				continue
			}
			row := widgets.Rect{X: x, Y: y, W: w, H: rh}
			paintLauncherRow(c, row, i == launch.sel)
			written += seatArea(c, row)
			seatText(c, row, x+6, y+3, seatTextPx, launchText(e.label, 29), tok.Ink)
			seatText(c, row, x+6, y+13, seatSmallPx, launchText(e.detail, 29), tok.Muted)
			continue
		}
		if ci == paletteSearchIdx || ci <= launchFileIdx0 {
			// M191b: the filename hits and the M165f hand-off share the
			// palette rows' two-line shape — name and context (the
			// containing folder, or the armed verb's name on the
			// selected row).
			label, detail := launch.hitRowText(ci)
			if i == launch.sel && launch.verbArmed() {
				detail = launch.verbs[launch.verb].name
			}
			row := widgets.Rect{X: x, Y: y, W: w, H: rh}
			paintLauncherRow(c, row, i == launch.sel)
			written += seatArea(c, row)
			seatText(c, row, x+6, y+3, seatTextPx, launchText(label, 29), tok.Ink)
			seatText(c, row, x+6, y+13, seatSmallPx, launchText(detail, 29), tok.Muted)
			continue
		}
		if ci < 0 || ci >= len(launch.catalog) {
			continue
		}
		row := widgets.Rect{X: x, Y: y, W: w, H: rh}
		paintLauncherRow(c, row, i == launch.sel)
		written += seatArea(c, row)
		ink := tok.Ink
		reason := ""
		if ci < len(launch.reasons) {
			reason = launch.reasons[ci]
		}
		if reason != "" {
			// A dimmed row names its own refusal: label and reason on
			// two lines inside the one row, never a launchable facade.
			ink = tok.InkMuted
			seatText(c, row, x+6, y+3, seatTextPx, launchText(launch.catalog[ci].Label, 28), ink)
			seatText(c, row, x+6, y+13, seatSmallPx, launchText(reason, 28), tok.Muted)
			continue
		}
		if i == launch.sel && launch.verbArmed() {
			// The armed verb takes the row's second line — the affordance
			// made visible, exactly like the file rows'.
			seatText(c, row, x+6, y+3, seatTextPx, launchText(launch.catalog[ci].Label, 28), ink)
			seatText(c, row, x+6, y+13, seatSmallPx, launchText(launch.verbs[launch.verb].name, 28), tok.Muted)
			continue
		}
		seatText(c, row, x+6, y+6, seatTextPx, launchText(launch.catalog[ci].Label, 29), ink)
	}
	return written
}

// paintLauncherRow fills one result row: the §2.3.6 Selection fill with the
// 3px Accent left-edge marker when selected, a flat Surface fill otherwise.
// Both strip faces — the manifest launcher and the M121a palette — share it.
func paintLauncherRow(c *draw.BufferCanvas, row widgets.Rect, selected bool) {
	tok := theme.Current
	if selected {
		draw.FillRoundedRect(c, row, radiusControl, draw.Opaque(tok.Accent))
		inner := row
		inner.X += seatMarkerW
		inner.W -= seatMarkerW
		draw.FillRoundedRect(c, inner, radiusControl, draw.Opaque(tok.Selection))
		return
	}
	draw.FillRoundedRect(c, row, radiusControl, draw.Opaque(tok.Surface))
}

func launchText(s string, max int) string {
	if len(s) > max {
		return s[:max-3] + "..."
	}
	return s
}
