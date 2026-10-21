// GOTABWM.ELF — M137c (#2773): spaces — named tab groups.
//
// A space is a whole tab strip plus its M137a split-pane tree, named and
// bounded (MaxSpaces). One space is live: its strip IS `tabs`, so every
// existing mutation path (declares, closes, splits, reorders) touches only
// the live space. Dormant spaces sit in `spaces[i].Strip` — their windows
// stay running but leave the composite through the seat-only
// wmctl_set_state visibility bit (vi.WmctlSetVisible), NOT through kernel
// workspaces: kernel workspaces cap at workspace_max=3, the card wants
// four groups, and the seat's own word for the grouping is "space".
//
// The switch is ctrl+alt+PageUp/PageDown — the seat rows ADR 0007 R5
// reserved for this card. PageDown at the last space CREATES the next one
// (like a Mission Control "+"): the palette's move-to-space action is the
// only other way a space comes to exist, so a switch chord that merely
// clamped would leave the feature unreachable by keyboard alone.
// PageUp at the first space is a clamped no-op. cap = MaxSpaces.
//
// Persistence: the record's 12-byte `group` field — reserved-but-unused
// since .tabs v2 froze — finally does the job it was laid out for and
// carries the space name; the SESSION.PANES sidecar gains a v2 section
// (panesVerSpaces) holding each space's name, its preorder tree blob, and
// the current-space index. A v1 file (no groups, single blob) decodes
// exactly as before — group "" lands on space "1".

package main

import "virelai/vi"

// MaxSpaces bounds the space table — the card's "up to 4".
const MaxSpaces = 4

// Marker lines the class-B gate greps. The word is always `space`, never
// `workspace` — the kernel's workspace_id is a different axis (and
// MarkerFirstBootWorkspace already owns that token).
const (
	MarkerSpaceNew    = "gotabwm: space new name="
	MarkerSpaceSwitch = "gotabwm: space switch "
	MarkerSpaceMove   = "gotabwm: space move "
	// M151b (#2913): the rail pill's click marker — the pointer gesture's
	// own record, printed before the switch marker the call runs.
	MarkerSpacePick     = "gotabwm: space pick "
	MarkerSessionSpaces = "gotabwm: session spaces "
)

// Space is one named group: a name plus the strip it owns while dormant.
// For the CURRENT space the strip field is dead storage — `tabs` is the
// live truth — so nothing but the switch path may read
// spaces[spaceCur].Strip.
type Space struct {
	Name  string
	Strip TabStrip
}

var (
	// spaces names all four slots up front: an unnamed space's identity
	// is its ordinal, so "1".."4" are assigned whether or not the slot is
	// in use — decode overwrites the names a file records.
	spaces = [MaxSpaces]Space{
		{Name: "1"}, {Name: "2"}, {Name: "3"}, {Name: "4"},
	}
	// spaceN counts live spaces (1..MaxSpaces); spaceCur is the live one.
	spaceN   = 1
	spaceCur = 0
)

// wmctlSetVisible is the per-window hide/show seam (the execApp /
// closeWin pattern): vi.WmctlSetVisible on the guest, a recorder in host
// tests where slot-65 is -ENOSYS.
var wmctlSetVisible = vi.WmctlSetVisible

// summonFocus is the summon's focus seam (the paletteFocus pattern):
// focusHosted on the guest, a stub in tests.
var summonFocus = focusHosted

func resetSpaces() {
	spaces = [MaxSpaces]Space{
		{Name: "1"}, {Name: "2"}, {Name: "3"}, {Name: "4"},
	}
	spaceN = 1
	spaceCur = 0
}

// stripOf is the strip-space duality spelled once: the live space's strip
// is `tabs`; a dormant space's strip is its slot. Mutations route through
// this so restore can name a space's strip without knowing which is live.
func stripOf(si int) *TabStrip {
	if si == spaceCur {
		return &tabs
	}
	return &spaces[si].Strip
}

func spaceIndexByName(name string) int {
	for i := 0; i < spaceN; i++ {
		if spaces[i].Name == name {
			return i
		}
	}
	return -1
}

// spaceEnsure finds name's slot or opens the next one for it. False at
// the cap — the refusing call sites report their own context.
func spaceEnsure(name string) (int, bool) {
	if si := spaceIndexByName(name); si >= 0 {
		return si, true
	}
	if spaceN >= MaxSpaces {
		return -1, false
	}
	si := spaceN
	spaces[si].Name = name
	spaceN++
	vi.ConsoleLine(MarkerSpaceNew + name)
	return si, true
}

// spaceSetVisible walks a strip's live rows (id < sessionIDBase — a
// placeholder is not a kernel window) and applies visibility. Used on
// switch and on restore's settle.
func spaceSetVisible(s *TabStrip, visible bool) {
	for i := 0; i < s.Count(); i++ {
		if id := s.At(i).ID; id < sessionIDBase {
			wmctlSetVisible(id, visible)
		}
	}
}

// spaceSwitchTo makes dst the live space: parks the outgoing strip into
// its slot, adopts the dormant strip, hides the outgoing space's windows
// and shows the incoming's, then lands focus on the incoming space's
// recorded focus. The parked copy is the dormant truth again; `tabs` is
// always the live space's.
func spaceSwitchTo(dst int) bool {
	if dst < 0 || dst >= spaceN || dst == spaceCur {
		return false
	}
	// M151a: a space switch re-lays the desktop — a standing zoom on
	// the outgoing strip restores before it parks.
	restorePaneZoom()
	old := spaceCur
	spaces[old].Strip = tabs
	spaceCur = dst
	tabs = spaces[dst].Strip
	spaceSetVisible(&spaces[old].Strip, false)
	spaceSetVisible(&tabs, true)
	hostedApp = 0
	if fid, ok := tabs.Focused(); ok && fid < sessionIDBase {
		if focusRaise(fid) == 0 {
			hostedApp = fid
			vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(fid)))
			vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(fid)))
			tabs.mruNote(fid) // M151a: the landing focus is a focus
		}
	}
	vi.ConsoleLine(MarkerSpaceSwitch + spaces[old].Name + "->" + spaces[dst].Name)
	noteSessionMutation()
	return true
}

// applySpacePick is the M151b rail-pill dispatch: a pointer click on a
// space's pill. The pick marker names the gesture itself — it prints on
// every pill hit, even a click on the live space (whose switch refuses
// and stays silent); the existing switch marker then names the outcome.
func applySpacePick(si int) bool {
	if si < 0 || si >= spaceN {
		return false
	}
	vi.ConsoleLine(MarkerSpacePick + spaces[si].Name)
	return spaceSwitchTo(si)
}

// applySpaceSwitch is the ctrl+alt+PageUp/PageDown dispatch. PageDown at
// the last space opens the next slot (the keyboard-reachable create);
// PageUp at the first clamps.
func applySpaceSwitch(dir int) bool {
	dst := spaceCur + dir
	if dst < 0 {
		return false
	}
	if dst >= spaceN {
		if dir <= 0 || spaceN >= MaxSpaces {
			return false
		}
		si, ok := spaceEnsure(spaces[spaceN].Name)
		if !ok {
			return false
		}
		dst = si
	}
	return spaceSwitchTo(dst)
}

// applySpaceMove carries the focused-or-named tab id to the named space —
// the palette's move action. The tab keeps every field (bin, pin, frozen,
// nav history, app_state) by wholesale Tab copy; its pane leaf stays
// behind (the destination strip re-tiles on its own next split), and its
// window hides since the destination is, by construction, dormant.
func applySpaceMove(id uint32, name string) bool {
	i := tabs.index(id)
	if i < 0 {
		return false
	}
	// M151a: a move detaches a leaf from the live tree — a standing
	// zoom restores first.
	restorePaneZoom()
	si := spaceIndexByName(name)
	if si == spaceCur {
		return false
	}
	if si < 0 {
		var ok bool
		si, ok = spaceEnsure(name)
		if !ok {
			return false
		}
	}
	dst := &spaces[si].Strip
	if dst.Count() >= MaxTabs {
		return false
	}
	t0, ok := tabs.detachTabAt(i)
	if !ok {
		return false
	}
	if !dst.OpenTab(id, t0.Title) {
		return false
	}
	dst.tabs[dst.count-1] = t0
	if t0.Pinned {
		dst.normalizePinned()
	}
	dst.focus = dst.index(id)
	dst.mruNote(id) // M151a: the moved tab is the destination's most recent
	if id < sessionIDBase {
		wmctlSetVisible(id, false)
	}
	if hostedApp == id {
		hostedApp = 0
		if fid, ok := tabs.Focused(); ok && fid < sessionIDBase {
			if focusRaise(fid) == 0 {
				hostedApp = fid
			}
		}
	}
	vi.ConsoleLine(MarkerSpaceMove + "id=" + vi.Itoa64(int64(id)) +
		" to=" + spaces[si].Name)
	noteSessionMutation()
	return true
}

// applySummonEmoji is the ctrl+shift+E dispatch (ADR 0007 R6): focus
// GOEMOJI.ELF's tab wherever it lives — a dormant space's tab switches
// the desktop to it — or exec it by name. While the app is absent the
// kernel's ENOENT lands in the seat's ordinary named-refusal lane.
func applySummonEmoji() bool {
	const bin = "GOEMOJI.ELF"
	for si := 0; si < spaceN; si++ {
		s := stripOf(si)
		for i := 0; i < s.Count(); i++ {
			if s.At(i).Bin != bin {
				continue
			}
			id := s.At(i).ID
			if si != spaceCur {
				if !spaceSwitchTo(si) {
					return false
				}
			}
			if summonFocus(id) {
				vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(id)))
				vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(id)))
				return true
			}
			return false
		}
	}
	if _, err := execApp(bin); err != nil {
		seatRefusalErr(err, "exec "+bin, bin)
		return false
	}
	return true
}

// closeTabAcrossSpaces is the death path's space-aware removal: a window
// that detaches or dies while its space is dormant still closes its row —
// otherwise a stale record would re-exec on the next boot. The live strip
// is tried first so all existing close markers keep their timing.
func closeTabAcrossSpaces(id uint32) bool {
	if tabs.CloseTab(id) {
		return true
	}
	for si := 0; si < spaceN; si++ {
		if si != spaceCur && spaces[si].Strip.CloseTab(id) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Session decode/encode across spaces.
// ---------------------------------------------------------------------------

// applySpacesV2 decodes the `.tabs` v2 file into the space table: each
// record's group field names its space, "" lands on "1", and a group that
// exceeds MaxSpaces fails the WHOLE file (a foreign group list is as
// corrupt as a truncated record — fail closed, never half-restored).
// The active record's group selects the live space; its position inside
// that space's subset is that strip's focus. Placeholder ids index the
// FILE's record list globally so a reexec pair can never collide across
// spaces.
func applySpacesV2(raw []byte) (uint16, bool) {
	seq, recs, active, hasActive, drops, ok := decodeTabsV2(raw)
	if !ok {
		return 0, false
	}
	resetSpaces()
	firstSpace := 0
	for i := 0; i < len(recs); i++ {
		name := recs[i].Group
		if name == "" {
			name = spaces[0].Name
		}
		si := spaceIndexByName(name)
		if si < 0 {
			if spaceN >= MaxSpaces {
				resetSpaces()
				tabs = TabStrip{}
				return 0, false
			}
			si = spaceN
			spaces[si].Name = name
			spaceN++
		}
		if i == 0 {
			firstSpace = si
		}
		s := &spaces[si].Strip
		if !s.OpenTab(sessionIDBase+uint32(i), recs[i].Title) {
			resetSpaces()
			tabs = TabStrip{}
			return 0, false
		}
		j := s.count - 1
		s.tabs[j].Bin = recs[i].Bin
		s.tabs[j].Pinned = recs[i].Pinned
		s.tabs[j].Frozen = recs[i].Frozen
		s.tabs[j].State = recs[i].State
		s.tabs[j].StateVer = recs[i].StateVer
		if hasActive && active == i {
			spaceCur = si
			s.focus = j
		}
	}
	// A file with no active record keeps focus discipline by landing on
	// the space its first record named — never on an empty default while
	// populated spaces sit dormant.
	if !hasActive {
		spaceCur = firstSpace
	}
	for _, d := range drops {
		stateLog(MarkerStateDrop + d)
	}
	tabs = spaces[spaceCur].Strip
	return seq, true
}

// sessionRecordsV2 collects the whole space table into one record list —
// every space's sessionRows() in slot order, group-named. The returned
// active index is the live space's focused record's position in the file
// (-1 = no active). Returns ok=false when nothing anywhere is live —
// writeSession's empty-file refusal.
func sessionRecordsV2() (recs []tabsV2Record, active int, ok bool) {
	active = -1
	for si := 0; si < spaceN; si++ {
		live := stripOf(si).sessionRows()
		base := len(recs)
		for i := 0; i < live.count; i++ {
			r := recordOf(live.tabs[i])
			if spaceN > 1 {
				r.Group = spaces[si].Name
			}
			recs = append(recs, r)
		}
		if si == spaceCur && live.focus >= 0 {
			active = base + live.focus
		}
	}
	return recs, active, len(recs) > 0
}
