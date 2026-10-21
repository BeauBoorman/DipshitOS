// GOTABWM.ELF — M121a (#2564): the seat-owned command palette.
//
// The palette is the launcher's second face: the same docked left-edge
// strip, the same modal input sink, the same type-to-filter ranking — but
// the catalog is the seat's own index instead of APPS.TXT. One summon
// chord (ctrl+shift+p, a registry row) opens it from any tab; the WM_RPC
// kind below lets a bound client ask for the same thing.
//
// Result sources, in catalog order:
//
//	open tabs    -> Enter focuses (the same focusHosted rail/alt-tab use)
//	recent files -> the vi trash/recent log's paths; Enter opens in GOEDIT
//	settings keys-> every key the panel can edit; Enter opens GOSET
//	help topics  -> the /host/docs bundle GOHELP browses; Enter opens GOHELP
//	chords       -> the whole chords.Global registry; Enter runs a seat
//	                row's action, anything else opens GOSET's shortcuts view
//
// Ranking is the launcher's three-tier subsequence model (rankApps)
// applied over the row's label plus one alternate match text — a chord's
// keys ("ctrl+shift+n") or a tab's binary — so "how do I pin" and "what
// was that chord" are the same query.
package main

import (
	"virelai/chords"
	"virelai/settings"
	"virelai/vi"
)

const (
	MarkerPaletteOpen    = "gotabwm: palette open n="
	MarkerPaletteFilter  = "gotabwm: palette filter q="
	MarkerPaletteExec    = "gotabwm: palette exec "
	MarkerPaletteFocus   = "gotabwm: palette focus id="
	MarkerPaletteRun     = "gotabwm: palette run "
	MarkerPaletteDismiss = "gotabwm: palette dismiss"
	// M123b (#2576): the palette's zero-match empty state.
	MarkerPaletteEmpty   = "gotabwm: palette empty"
	MarkerPaletteMissing = "gotabwm: palette missing "
	MarkerRpcPalette     = "gotabwm: rpc palette"

	// palettePrompt is the header text the strip carries in palette mode —
	// the same slot launchPrompt owns in launcher mode.
	palettePrompt = "Type a command or search"

	// wmKindPalette is the additive WM_RPC request kind: a bound client asks
	// the seat to summon the palette. It binds through the same
	// challenge/token gate every request passes; the seat-local constant
	// follows wmKindWindowsQuery's precedent (windows_query.go) — a vi-side
	// client helper lands with the first app that sends it.
	wmKindPalette uint8 = 19

	// paletteDocsDir is the help bundle GOHELP browses (user/go/help's
	// docsDir convention): help topics are its plain files.
	paletteDocsDir = "/host/docs"
)

// palKind names a palette row's source. The kind picks the Enter dispatch.
type palKind uint8

const (
	palTab palKind = iota
	palRecent
	palSetting
	palHelp
	palChord
	// palSpace (M137c #2773): "move the focused tab to space <name>" —
	// one row per dormant space plus the next unnamed slot while the
	// table has room. arg carries the space name; id the tab's window id.
	palSpace
	// palPane (M151a #2912): pane posture rows — "Zoom pane" while the
	// focused tab holds a leaf and nothing is zoomed, "Restore panes"
	// while one is. action names which apply runs.
	palPane
	// palSwitch (M151b #2913): "Switch to space <name>" — one row per
	// dormant space, the rail pill's keyboard path. arg carries the
	// space name; no tab id (a switch needs no focused tab).
	palSwitch
)

// paletteEntry is one result row. label is the painted text and the primary
// match; alt is a second match text that is never painted (a tab's bin, a
// chord's keys). detail is the row's dimmed second line. id/arg/action/
// chord carry what the Enter dispatch needs.
type paletteEntry struct {
	kind   palKind
	label  string
	alt    string
	detail string
	id     uint32       // palTab: the window id
	arg    string       // palRecent: the file path
	action string       // palChord: the seat action, "" off-seat
	chord  chords.Chord // palChord: the row's keys
}

// paletteDirList is the docs-bundle listing seam (the readAppsFile pattern:
// host tests stage a directory without a guest).
var paletteDirList = vi.DirList

// paletteSettings is the settings decode seam for the per-key detail line.
var paletteSettings = settings.Load

// paletteFocus is the tab-focus dispatch seam (the focusNotifySource
// pattern in notify.go): focusHosted on the guest, a recorder in tests
// where the kernel taskbar seam is -ENOSYS.
var paletteFocus = focusHosted

// openPalette is the ctrl+shift+p / WM_RPC entry point, sharing
// openLauncher's semantics: the chord toggles its own face closed, a
// live strip in the OTHER mode swaps contents without dropping the sink,
// and a closed strip acquires the modal input sink first.
func openPalette() {
	dragAbort("chrome") // M124a: the modal palette takes the gesture
	if launch.open && launch.palette {
		dismissLauncher()
		return
	}
	if !launch.open {
		launch.err = ""
		launch.prior, _ = tabs.Focused()
		if !acquireLauncherFocus() {
			vi.ConsoleLine("gotabwm: palette unavailable " + launch.err)
			launch.open = launch.sink != 0
			return
		}
		launch.open = true
	}
	launch.palette = true
	launch.err = ""
	launch.results = paletteSources()
	launch.catalog, launch.reasons = nil, nil
	launch.filter, launch.sel, launch.first = "", 0, 0
	launch.painted, launch.launching = false, false
	launch.refresh()
	vi.ConsoleLine(MarkerPaletteOpen + vi.Itoa64(int64(len(launch.results))))
	emitPaletteFilter()
}

// paletteSources builds the catalog in fixed order: the live strip first,
// then the recent log, the settings keyspace, the docs bundle, and the
// chord registry. Order is rank-stable: equal-tier rows keep this order.
func paletteSources() []paletteEntry {
	var out []paletteEntry
	for i := 0; i < tabs.Count(); i++ {
		t := tabs.At(i)
		out = append(out, paletteEntry{
			kind:   palTab,
			label:  t.Title,
			alt:    t.Bin,
			detail: "tab · " + t.Bin,
			id:     t.ID,
		})
	}
	out = appendSpaceRows(out)
	out = appendSpaceSwitchRows(out)
	out = appendPaneRows(out)
	out = appendRecentRows(out)
	out = appendSettingsRows(out)
	out = appendHelpRows(out)
	for _, r := range chords.Global {
		e := paletteEntry{
			kind:   palChord,
			label:  r.Label,
			alt:    r.Chord.String(),
			detail: r.Chord.String() + " · " + string(r.Scope),
			action: r.Action,
			chord:  r.Chord,
		}
		if r.Scope == chords.ScopeSeat {
			e.detail = r.Chord.String() + " · seat"
		}
		out = append(out, e)
	}
	return out
}

// appendSpaceRows offers the M137c move: the focused tab can travel to
// each dormant space, and to the next unnamed slot while the table has
// room (the palette's own space-create path). An empty strip or a
// single-space desktop with all four slots used yields no rows.
func appendSpaceRows(out []paletteEntry) []paletteEntry {
	fid, ok := tabs.Focused()
	if !ok {
		return out
	}
	title := tabs.At(tabs.focus).Title
	for si := 0; si < spaceN; si++ {
		if si == spaceCur {
			continue
		}
		out = append(out, paletteEntry{
			kind:   palSpace,
			label:  "Move " + title + " to space " + spaces[si].Name,
			alt:    "space " + spaces[si].Name,
			detail: "space " + spaces[si].Name,
			id:     fid,
			arg:    spaces[si].Name,
		})
	}
	if spaceN < MaxSpaces {
		name := spaces[spaceN].Name
		out = append(out, paletteEntry{
			kind:   palSpace,
			label:  "Move " + title + " to new space " + name,
			alt:    "space " + name,
			detail: "space " + name,
			id:     fid,
			arg:    name,
		})
	}
	return out
}

// appendSpaceSwitchRows offers the M151b direct jump: "Switch to space
// <name>", one row per dormant space — the rail pill's keyboard path.
// Unlike the move rows this needs no focused tab (an empty strip still
// switches), and the live space gets no row — switching to it would
// refuse, and the palette never offers a dead verb.
func appendSpaceSwitchRows(out []paletteEntry) []paletteEntry {
	for si := 0; si < spaceN; si++ {
		if si == spaceCur {
			continue
		}
		out = append(out, paletteEntry{
			kind:   palSwitch,
			label:  "Switch to space " + spaces[si].Name,
			alt:    "space " + spaces[si].Name,
			detail: "space " + spaces[si].Name,
			arg:    spaces[si].Name,
		})
	}
	return out
}

// appendPaneRows offers the M151a posture rows: "Zoom pane" while the
// focused tab holds a leaf in a multi-pane tree and nothing is zoomed,
// "Restore panes" while a zoom stands. Neither row exists when it would
// be a dead verb — the palette never offers a command that refuses.
func appendPaneRows(out []paletteEntry) []paletteEntry {
	if tabs.zoomTab != 0 {
		return append(out, paletteEntry{
			kind:   palPane,
			label:  "Restore panes",
			alt:    "unzoom",
			detail: "seat · panes",
			action: "restore-panes",
		})
	}
	fid, ok := tabs.Focused()
	if !ok || tabs.leafOf(fid) < 0 || tabs.leafCount() < 2 {
		return out
	}
	return append(out, paletteEntry{
		kind:   palPane,
		label:  "Zoom pane",
		alt:    "zoom",
		detail: "seat · panes",
		action: "zoom-pane",
	})
}

// appendRecentRows decodes the vi recent log's bounded tail
// (timestamp|action|id|hex(path) rows) into palRecent entries, newest last
// in the log, so the most recent row lands last in catalog order.
func appendRecentRows(out []paletteEntry) []paletteEntry {
	body, r := readAppsFile(vi.RecentLogPath, 8192)
	if r < 0 || body == nil {
		return out
	}
	rest := string(body)
	for len(rest) > 0 {
		var line string
		line, rest = cutLine(rest)
		line = trimSpace(line)
		if line == "" {
			continue
		}
		f := splitPipe(line)
		if len(f) != 4 {
			continue
		}
		path, ok := paletteHexDecode(f[3])
		if !ok || path == "" {
			continue
		}
		out = append(out, paletteEntry{
			kind:   palRecent,
			label:  path,
			detail: "recent · " + f[1],
			arg:    path,
		})
	}
	return out
}

// appendSettingsRows offers every key the settings panel may edit — the
// kernel table plus every accepted-but-unseeded group — each carrying its
// effective value so the row already says what the panel would show.
func appendSettingsRows(out []paletteEntry) []paletteEntry {
	f := paletteSettings()
	groups := [][]settings.Key{
		settings.KnownKeys, settings.PaletteKeys, settings.FontKeys,
		settings.KeyboardLayoutKeys, settings.IdleKeys, settings.NotifyKeys,
		settings.NotifySoundKeys, settings.VolumeKeys, settings.TimezoneKeys,
		settings.DataRootKeys,
	}
	for _, g := range groups {
		for _, k := range g {
			v, _ := f.Effective(k.Name)
			out = append(out, paletteEntry{
				kind:   palSetting,
				label:  "Settings: " + k.Name,
				detail: "= " + v,
				arg:    k.Name,
			})
		}
	}
	return out
}

// appendHelpRows lists the docs bundle GOHELP reads. Directories and a
// missing bundle yield nothing rather than an error row.
func appendHelpRows(out []paletteEntry) []paletteEntry {
	var entries [vi.MaxDirEntries]vi.DirEntry
	n, rc := paletteDirList(paletteDocsDir, entries[:])
	if rc < 0 || n <= 0 {
		return out
	}
	for i := 0; i < n; i++ {
		name := entries[i].NameString()
		if name == "" {
			continue
		}
		out = append(out, paletteEntry{
			kind:   palHelp,
			label:  "Help: " + name,
			detail: "topic · " + paletteDocsDir + "/" + name,
			arg:    name,
		})
	}
	return out
}

// paletteHexDecode decodes the recent log's hex-encoded path column. Pure —
// the seat cannot reach for encoding/hex (the EL0 binary-size wall
// apps.go's asciiContainsFold documents).
func paletteHexDecode(s string) (string, bool) {
	if len(s) == 0 || len(s)%2 != 0 {
		return "", false
	}
	buf := make([]byte, len(s)/2)
	for i := 0; i < len(buf); i++ {
		hi, ok1 := paletteHexNibble(s[2*i])
		lo, ok2 := paletteHexNibble(s[2*i+1])
		if !ok1 || !ok2 {
			return "", false
		}
		buf[i] = hi<<4 | lo
	}
	return string(buf), true
}

func paletteHexNibble(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// rankPalette is rankApps over the palette catalog: prefix on the label,
// substring on the label, then the query as a subsequence of label or alt.
// Tiers concatenate in catalog order, so a tab hit outranks a chord's
// fuzzy reach exactly like a manifest prefix outranks an argv match.
func rankPalette(catalog []paletteEntry, q string) []int {
	if q == "" {
		idx := make([]int, 0, len(catalog))
		for i := range catalog {
			idx = append(idx, i)
		}
		return idx
	}
	var prefix, sub, fuzzy []int
	for i, e := range catalog {
		switch {
		case asciiPrefixFold(e.label, q):
			prefix = append(prefix, i)
		case asciiContainsFold(e.label, q):
			sub = append(sub, i)
		case asciiSubseqFold(e.label, q) || asciiSubseqFold(e.alt, q):
			fuzzy = append(fuzzy, i)
		}
	}
	return append(append(prefix, sub...), fuzzy...)
}

// selectedPalette is selected()'s palette-mode twin: the ranked row, not
// the manifest row.
func (l *launcherState) selectedPalette() (paletteEntry, bool) {
	if l.sel < 0 || l.sel >= len(l.filtered) {
		return paletteEntry{}, false
	}
	i := l.filtered[l.sel]
	if i < 0 || i >= len(l.results) {
		return paletteEntry{}, false
	}
	return l.results[i], true
}

func emitPaletteFilter() {
	vi.ConsoleLine(MarkerPaletteFilter + launch.filter +
		" n=" + vi.Itoa64(int64(len(launch.filtered))))
}

// paletteExecSelected is execSelected's palette face: Enter focuses a tab,
// launches the owning surface, or runs a seat chord. The exec paths keep
// the launcher's failure contract — a refused exec stays open and names
// itself in the error line rather than closing on a lie.
func paletteExecSelected() {
	if launch.launching {
		if releaseLauncherFocus(false) {
			finishLauncher()
		}
		return
	}
	e, ok := launch.selectedPalette()
	if !ok {
		return
	}
	if !ensureLauncherFocus() {
		return
	}
	switch e.kind {
	case palTab:
		if !paletteFocus(e.id) {
			launch.err = "Focus failed"
			return
		}
		vi.ConsoleLine(MarkerPaletteFocus + vi.Itoa64(int64(e.id)))
	case palSpace:
		// Like palChord: the row closes the palette first — the moved
		// tab's window hides on the desktop, not under the modal strip.
		launch.launching = true
		if releaseLauncherFocus(false) {
			finishLauncher()
		}
		vi.ConsoleLine(MarkerPaletteRun + "move-to-space " + e.arg)
		_ = applySpaceMove(e.id, e.arg)
		return
	case palSwitch:
		// M151b: like palSpace — the row closes the palette first; the
		// switch re-lays the whole desktop, not under the modal strip.
		launch.launching = true
		if releaseLauncherFocus(false) {
			finishLauncher()
		}
		vi.ConsoleLine(MarkerPaletteRun + "switch-to-space " + e.arg)
		_ = spaceSwitchTo(spaceIndexByName(e.arg))
		return
	case palChord:
		// A seat row dispatches its own action with the palette already
		// closed so a result like "launcher" or "pin" acts on the desktop,
		// not on the palette. Non-seat rows (kernel chrome, app chords)
		// open the panel's shortcuts view — the registry's own display.
		launch.launching = true
		if releaseLauncherFocus(false) {
			finishLauncher()
		}
		if e.action != "" {
			vi.ConsoleLine(MarkerPaletteRun + e.action)
			runSeatAction(e.action, e.chord)
		} else {
			paletteExec("GOSET.ELF")
		}
		return
	case palPane:
		// M151a: like palChord — the row closes the palette first so the
		// posture acts on the desktop, not under the modal strip.
		launch.launching = true
		if releaseLauncherFocus(false) {
			finishLauncher()
		}
		vi.ConsoleLine(MarkerPaletteRun + e.action)
		switch e.action {
		case "zoom-pane":
			_ = applyPaneZoom()
		case "restore-panes":
			_ = applyPaneUnzoom()
		}
		return
	case palRecent:
		if !paletteExecArgv("GOEDIT.ELF", e.arg) {
			return
		}
	case palSetting:
		if !paletteExec("GOSET.ELF") {
			return
		}
	case palHelp:
		if !paletteExec("GOHELP.ELF") {
			return
		}
	}
	launch.launching = true
	if releaseLauncherFocus(false) {
		finishLauncher()
	}
}

// paletteExec execs a target with no arguments; paletteExecArgv carries one
// (the recent file's path). Both print the exec marker only after the
// syscall accepted the launch.
func paletteExec(bin string) bool {
	if _, err := execApp(bin); err != nil {
		vi.ConsoleLine(MarkerPaletteMissing + bin)
		launch.err = "Launch failed: " + bin
		seatRefusalErr(err, "exec "+bin, bin)
		return false
	}
	vi.ConsoleLine(MarkerPaletteExec + bin)
	return true
}

func paletteExecArgv(bin, arg string) bool {
	if _, err := execApp(bin, arg); err != nil {
		vi.ConsoleLine(MarkerPaletteMissing + bin)
		launch.err = "Launch failed: " + bin
		seatRefusalErr(err, "exec "+bin, bin)
		return false
	}
	vi.ConsoleLine(MarkerPaletteExec + bin + " argv=" + arg)
	return true
}
