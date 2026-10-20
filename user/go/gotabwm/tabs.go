// GOTABWM.ELF — M62b–g (issues #1400–#1405): an in-process tab strip
// with a two-pane constrained split, pin, reorder, `.tabs` v2 session,
// a headless LAYOUT.txt dump, and a shipping Go ELF as a tab (GOEDIT).
//
// OpenTab / CloseTab / FocusTab / SplitH / SplitV / Unsplit / Pin / Unpin /
// Reorder / Freeze / Thaw are a pure state machine: no syscalls, no WM_RPC.
// The seat hooks each successful mutation with the kernel primitive that
// made it true, then prints a marker.
//
// Close of the focused tab moves focus to the neighbour that shifts into
// its slot (Zig TABWM remove_tab). Close of the last tab leaves the strip
// empty; the seat stays registered. Max 16 tabs (ADR 0033 / `.tabs` v2).
// Split is exactly two panes; pane minimum is 160×120 (ADR 0033) on the
// 1280×720 scanout. Integer math; the kernel clamp stays authoritative.
package main

import (
	"virelai/icons"
	"virelai/theme"
	"virelai/widgets"
)

// MaxTabs is the `.tabs` v2 / ADR 0033 cap.
const MaxTabs = 16

// RailHeight is the tab strip's scanout band, matching the kernel's
// tab_bar_height so the compose-N overlay covers the same chrome row Zig
// TABWM paints into a window.
const RailHeight = 22

// M71e (#1564): the frozen badge's geometry. Zig paints a '~' glyph at x=132
// (tabwm.zig:3339); this rail is solid cells with no glyphs, so the badge is
// a Warning-coloured block inset at the cell's right edge instead.
const (
	railBadgeW     = 4
	railBadgeInset = 4
)

// M79b (#1705): the close-x geometry. railCloseW is the hit zone's width —
// the cell's rightmost railCloseW px, full strip height, mirrored exactly by
// hid.go's railCloseZoneAt so the painted glyph and the hit target can never
// disagree. railCloseInset keeps the 8x8 ✕ glyph clear of the frozen badge,
// which sits hard against the cell's right edge.
const (
	railCloseW     = 16
	railCloseInset = 2
)

// Tab is one strip entry. ID is the kernel window id the client declared.
type Tab struct {
	ID     uint32
	Title  string
	Bin    string // `.tabs` v2 bin field (guessBin from the declared title)
	Pinned bool   // FlagPinned (0x01); pinned tabs sit at the left of the rail
	// M79e (#1708): the per-tab navigation history (M48/BT5). Zig keeps
	// `hist` INSIDE Tab for the same reason this does: a reorder or a
	// close moves the Tab value and the history travels with it for free,
	// so there is no parallel index that can drift out of step with the
	// strip. Fixed byte arrays, never strings — D2: the ring is BSS with
	// no per-entry heap.
	navHist  [navHistMax][navPathMax]byte
	navLen   [navHistMax]int
	navCount int
	navPos   int
	// Frozen is FlagFrozen (0x02). M71e (#1564): Zig's BT6 frozen is a
	// STATUS BADGE (docs/march-m39-tabbed-desktop.md labels it "a frozen
	// status badge (Ctrl+Shift+F)", and tabwm.zig's field comment calls it
	// "future demand-paging freeze"). It is deliberately NOT a lock: Zig
	// has no frozen check anywhere in its close path, so GOTABWM refuses
	// nothing on a frozen tab either. The badge just rides the rail.
	Frozen bool
	// M125a (#2586): the app's serialized state — a blob the seat asked
	// for (or the app pushed) and stores verbatim, at most vi.AppStateMax
	// bytes, tagged with the app's own format version. It rides the Tab
	// value like navHist does, so a reorder, a pin, or a re-exec adoption
	// carries it for free, and a close carries it into the reopen LIFO.
	State    []byte
	StateVer uint8
}

// TabStrip is the in-process tab list. The zero value is empty (unsplit).
type TabStrip struct {
	tabs  [MaxTabs]Tab
	count int
	focus int // index into tabs[0:count]; ignored when count == 0
	split SplitKind
	// M79c (#1706): the drag-set divider position in scanout px. 0 means
	// unset: the split tiles edge-to-edge at the midpoint exactly as
	// SplitRects always did. A set sash carries a SashWidth gutter centred
	// on it (the visible divider — the seat paints no content-area chrome,
	// so the gap is background showing between the two client rects).
	// Stored, not derived: PaneRects/layoutFileBody read it, so the sash
	// survives relayout and lands in LAYOUT.txt's x=/w= fields (no new
	// field: ADR 0033 pins that line format). Reset by setSplit, Unsplit,
	// and any close that drops the strip below two tabs.
	sash int
	// M71d (#1563, M48 BT1): the bounded reopen LIFO. closed is a fixed
	// array and closedCount is monotonic, exactly like Zig tabwm.closed_count,
	// so the ring is BSS/fixed with no heap catalog of every close (D2).
	// closedLive is how many entries are still live (<= MaxTabs): Zig's
	// recently_closed_at only guards k < max_tabs, so once closed_count exceeds
	// the ring, reopen walks back over slots a later close already overwrote
	// and hands out evicted entries. The live counter makes the bound real.
	// Only Bin and Title are kept — never a window id — so reopen re-execs the
	// executable rather than cloning a process (D1).
	closed      [MaxTabs]ClosedTab
	closedCount int
	closedLive  int
}

// ClosedTab is one reopen-LIFO entry: the executable and title recorded when
// the tab closed. Zig tabwm.ClosedTab minus the window id. M125a (#2586):
// the entry also carries the blob the seat collected at close — ctrl-shift-t
// then redelivers it to the re-exec'd app through restore_state.
type ClosedTab struct {
	Bin   string
	Title string
	// M125a (#2586): the state captured by the close-time save ask. Empty
	// when the app held none or never answered.
	State    []byte
	StateVer uint8
}

// The tab-strip marker lines the class-B gate greps. Exported so tabs_test.go
// pins the exact shapes.
const (
	MarkerTabOpen       = "gotabwm: tab open id="
	MarkerTabFocus      = "gotabwm: tab focus id="
	MarkerTabClose      = "gotabwm: tab close id="
	MarkerRail          = "gotabwm: rail "
	MarkerTabsEmpty     = "gotabwm: tabs empty"
	MarkerSplit         = "gotabwm: split "
	MarkerUnsplit       = "gotabwm: unsplit"
	MarkerLayout        = "gotabwm: layout "
	MarkerLayoutFile    = "gotabwm: layout file="
	MarkerPane          = "gotabwm: pane "
	MarkerPin           = "gotabwm: pin "
	MarkerReorder       = "gotabwm: reorder "
	MarkerOrder         = "gotabwm: order "
	MarkerSessionWrite  = "gotabwm: session write n="
	MarkerSessionLoad   = "gotabwm: session load n="
	MarkerSessionTitles = "gotabwm: session titles="
	MarkerSessionBad    = "gotabwm: session bad"
	// M120b (#2559): the restore's live half. reexec counts the bins the
	// seat exec'd back, live counts the rows a declare actually
	// re-inhabited, and drop names a row nothing could run (unbacked bin,
	// refused exec, dead or late pid).
	MarkerSessionReexec = "gotabwm: session reexec n="
	MarkerSessionLive   = "gotabwm: session live n="
	MarkerSessionDrop   = "gotabwm: session drop "
	MarkerSessionExec   = "gotabwm: session exec "
	// M71e (#1564): the frozen-badge chord outcomes and the restore count.
	// Zig's shapes are `tabwm: tab-freeze <id> on|off` and `freeze=<n>` on
	// its tabs-applied line; these follow GOTABWM's own pin style
	// (`gotabwm: pin id=<n> on`) instead of the Zig spelling.
	MarkerFreeze        = "gotabwm: freeze id="
	MarkerThaw          = "gotabwm: thaw id="
	MarkerSessionFreeze = "gotabwm: session freeze n="
	// M79c (#1706): the sash-drag outcome. <kind> is v/h, from/to are the
	// divider centres in scanout px. Printed only after both SET_WINDOW
	// calls returned, like the split markers.
	MarkerSash = "gotabwm: sash "
	// M79e (#1708): the per-tab nav seam. `declare`/`poll` are the two RPC
	// arms (kinds 9/10); `back`/`forward` are the Ctrl+Shift+[ / ]
	// affordance. All four print only after the state actually moved —
	// a deduped declare, an exhausted step, and an empty poll are silent,
	// exactly as Zig's nav_declare returns early on a no-op record.
	MarkerNavDeclare = "gotabwm: nav declare id="
	MarkerNavPoll    = "gotabwm: nav poll id="
	MarkerNavBack    = "gotabwm: nav back id="
	MarkerNavForward = "gotabwm: nav forward id="
	// M125a (#2586): the per-app state protocol. `ask` is the seat's
	// notice to one bound tab (snapshot/close); `save` is the app's
	// stored answer; `restore` is the blob staged back for a re-exec'd
	// or reopened tab; `drop` names a blob refused — oversized, malformed
	// staging, an index outside the records, or the file cap.
	MarkerStateAsk     = "gotabwm: state ask id="
	MarkerStateSave    = "gotabwm: state save id="
	MarkerStateRestore = "gotabwm: state restore id="
	MarkerStateDrop    = "gotabwm: state drop "
)

// M79e (#1708): the nav-history bounds, taken from Zig's tabwm rather than
// invented. navHistMax is `hist_max`; navPathMax is `hist_path_max`, which
// is not a free choice — it is the WM_RPC title field, the only channel a
// declared path and a polled target can travel in. A path longer than the
// field is truncated at the wire, so the seat records what the client can
// actually get back.
const (
	navHistMax = 8
	navPathMax = 24
)

// FlagPinned / FlagFrozen are `.tabs` v2 bits 0 and 1 — the same values as
// tabcodec.FlagPinned / tabcodec.FlagFrozen / tabwm.tab_flag_pinned /
// tabwm.tab_flag_frozen. Dock (0x04) stays unused (M62d non-goal).
const (
	FlagPinned uint8 = 0x01
	FlagFrozen uint8 = 0x02
)

// tabFlags packs a tab's persisted flag byte. M71e (#1564): frozen joined
// pinned so the byte round-trips through `.tabs` v2 as tabcodec defines it.
func tabFlags(t Tab) uint8 {
	var f uint8
	if t.Pinned {
		f |= FlagPinned
	}
	if t.Frozen {
		f |= FlagFrozen
	}
	return f
}

// Freeze sets FlagFrozen on id. False when id is missing or already frozen.
// A badge, not a lock: closing a frozen tab is still allowed (Zig parity).
func (s *TabStrip) Freeze(id uint32) bool {
	i := s.index(id)
	if i < 0 || s.tabs[i].Frozen {
		return false
	}
	s.tabs[i].Frozen = true
	return true
}

// Thaw clears FlagFrozen on id. False when id is missing or not frozen.
func (s *TabStrip) Thaw(id uint32) bool {
	i := s.index(id)
	if i < 0 || !s.tabs[i].Frozen {
		return false
	}
	s.tabs[i].Frozen = false
	return true
}

// FrozenCount is how many tabs carry the frozen badge (the restore line's n).
func (s *TabStrip) FrozenCount() int {
	n := 0
	for i := 0; i < s.count; i++ {
		if s.tabs[i].Frozen {
			n++
		}
	}
	return n
}

// guessBin fills the `.tabs` v2 bin field from a declared title. WM_RPC
// carries the window title, not the executable name.
func guessBin(title string) string {
	switch title {
	case "Calc":
		return "GOCALC.ELF"
	case "Notepad":
		// M66c (#1445, completed by #1485): the text editor this shell
		// restores is the Go app, NOTE.ELF. The Zig binary is deleted, so
		// this is now the only app a restored "Notepad" tab can name.
		return "NOTE.ELF"
	case "Edit":
		return "GOEDIT.ELF"
	case "Files":
		// M125c (#2588): GOFILES's declared title — the session state leg
		// re-execs the recorded row, so "Files" must name the real binary.
		return "GOFILES.ELF"
	case "Image Viewer":
		// M124a-2 (#2677): GOVIEW's declared title — without the row its
		// opens=image manifest can never resolve and every drop refuses.
		return "GOVIEW.ELF"
	case "GoTabApp":
		// The M56d tabapp demo's declared title — the M125a spec leg's
		// client, so its restore row must name the real binary.
		return "GOTABAPP.ELF"
	case "Term":
		return "GOTERM.ELF"
	case "Web":
		// M125g (#2592): the browser's declared title — without the row a
		// restored tab execs "Web" and the row drops by name.
		return "WEB.ELF"
	case "RSS Reader":
		// The reader declares this title (user/go/rss). The default arm would
		// otherwise record the title itself as the binary, and a restored tab
		// would look for a file named "RSS Reader".
		return "RSS.ELF"
	case "Sh":
		// M123e (#2579): the shell's declared title — without the row a
		// restored starter tab execs "Sh" and drops by name (go-dogfood
		// boot 06: `refusal ENOENT exec Sh`).
		return "GOSH.ELF"
	case "Vault":
		// M148a (#2804): GOVAULT's declared title — without the row the
		// recorded bin is "Vault", the APPS.TXT selection=primary lookup
		// misses, and every sel_publish refuses by cap.
		return "GOVAULT.ELF"
	case "Snapshots":
		// M120d (#2561): the snapshot manager's declared title — the
		// PWR row focuses the tab by bin, and a restored row needs the
		// real binary like every app above.
		return "GOSNAP.ELF"
	default:
		return title
	}
}

func railIdleRGB() uint32   { return theme.Current.BtnIdle }
func railFocusRGB() uint32  { return theme.Current.Accent }
func railGapRGB() uint32    { return theme.Current.Bg }
func railFrozenRGB() uint32 { return theme.Current.Warning }

// M79b (#1705): the hover tint is the theme's own hover token — distinct
// from idle (BtnIdle) and focus (Accent) by construction. The close-x glyph
// is muted ink: visible on idle, hover, and focus cells without shouting.
func railHoverRGB() uint32 { return theme.Current.BtnHover }
func railCloseRGB() uint32 { return theme.Current.Muted }

// Count is how many tabs are currently open.
func (s *TabStrip) Count() int { return s.count }

// At returns the tab at i, or a zero Tab when i is out of range.
func (s *TabStrip) At(i int) Tab {
	if i < 0 || i >= s.count {
		return Tab{}
	}
	return s.tabs[i]
}

// Focused returns the focused tab's window id.
func (s *TabStrip) Focused() (uint32, bool) {
	if s.count == 0 || s.focus < 0 || s.focus >= s.count {
		return 0, false
	}
	return s.tabs[s.focus].ID, true
}

// OpenTab adds id to the strip. A duplicate id updates the title and is
// not a new tab (returns false). id 0 is refused. The first tab becomes
// focused; a later OpenTab does not steal focus (FocusTab does that).
func (s *TabStrip) OpenTab(id uint32, title string) bool {
	if id == 0 {
		return false
	}
	if i := s.index(id); i >= 0 {
		s.tabs[i].Title = title
		if s.tabs[i].Bin == "" {
			s.tabs[i].Bin = guessBin(title)
		}
		return false
	}
	if s.count >= MaxTabs {
		return false
	}
	s.tabs[s.count] = Tab{ID: id, Title: title, Bin: guessBin(title)}
	if s.count == 0 {
		s.focus = 0
	}
	s.count++
	return true
}

// SetTitle replaces the visible label on an existing tab without touching its
// recorded executable. The declaration title establishes Bin; later document
// titles must not turn reopen into a request for a file named after the file.
func (s *TabStrip) SetTitle(id uint32, title string) bool {
	if title == "" {
		return false
	}
	i := s.index(id)
	if i < 0 {
		return false
	}
	s.tabs[i].Title = title
	return true
}

// SetState stores the app's serialized blob on id (M125a, #2586). An empty
// or oversized blob CLEARS the slot rather than being stored: the seat
// never keeps a blob it would later refuse, and an empty answer is the
// app's own "no state". False only when id is not on the strip.
func (s *TabStrip) SetState(id uint32, ver uint8, blob []byte) bool {
	i := s.index(id)
	if i < 0 {
		return false
	}
	if len(blob) == 0 || len(blob) > stateMaxBytes {
		s.tabs[i].State = nil
		s.tabs[i].StateVer = 0
		return true
	}
	s.tabs[i].State = append([]byte(nil), blob...)
	s.tabs[i].StateVer = ver
	return true
}

// --- M79e (#1708): per-tab navigation history (M48/BT5) --------------------
//
// A line-for-line mirror of Zig tabwm.Tab.nav_record / nav_back /
// nav_forward, including the two rules that are easy to get subtly wrong:
// a declare DROPS the forward stack (you navigated somewhere new, so the
// old forward entries are no longer reachable), and a declare at the cap
// evicts the OLDEST entry rather than refusing.

// navEntry is the recorded path at slot i, NUL-trimmed to its length.
func (t *Tab) navEntry(i int) string {
	return string(t.navHist[i][:t.navLen[i]])
}

// navSet stores path at slot i, truncated to the wire's title field.
func (t *Tab) navSet(i int, path string) {
	n := len(path)
	if n > navPathMax {
		n = navPathMax
	}
	copy(t.navHist[i][:], path[:n])
	t.navLen[i] = n
}

// navRecord appends a declared path. False means NOTHING changed: an
// empty path, or a re-declaration of the current entry (consecutive
// dedupe, so a repaint that re-declares does not grow the history).
func (t *Tab) navRecord(path string) bool {
	if path == "" {
		return false
	}
	if t.navCount > 0 && t.navEntry(t.navPos) == path {
		return false
	}
	// Drop the forward stack: the entry after navPos was the next append
	// slot, and everything past it is unreachable now.
	if t.navCount != 0 {
		t.navCount = t.navPos + 1
	}
	// At the cap, shift down one and drop the oldest. navLen shifts WITH
	// navHist — they are parallel arrays, and a path copied without its
	// length would read as trailing NULs from a stale entry.
	if t.navCount == navHistMax {
		for i := 1; i < navHistMax; i++ {
			t.navHist[i-1] = t.navHist[i]
			t.navLen[i-1] = t.navLen[i]
		}
		t.navCount = navHistMax - 1
	}
	t.navSet(t.navCount, path)
	t.navCount++
	t.navPos = t.navCount - 1
	return true
}

// canNavBack / canNavForward: navPos is the CURRENT entry, so back needs a
// previous one and forward needs a following one.
func (t *Tab) canNavBack() bool    { return t.navCount > 0 && t.navPos > 0 }
func (t *Tab) canNavForward() bool { return t.navPos+1 < t.navCount }

// navBack steps the cursor back one entry and returns the new current path.
// False when there is nothing behind the cursor.
func (t *Tab) navBack() (string, bool) {
	if !t.canNavBack() {
		return "", false
	}
	t.navPos--
	return t.navEntry(t.navPos), true
}

// navForward steps the cursor forward one entry. False at the newest entry.
func (t *Tab) navForward() (string, bool) {
	if !t.canNavForward() {
		return "", false
	}
	t.navPos++
	return t.navEntry(t.navPos), true
}

// NavDeclare records an app-declared navigation for id. False when the tab
// is not on the strip (Zig's `manager.find_by_id(id) orelse return false`).
// The caller must distinguish "no such tab" from "recorded but
// deduped": only the latter is a state change worth a marker.
func (s *TabStrip) NavDeclare(id uint32, path string) (known, changed bool) {
	i := s.index(id)
	if i < 0 {
		return false, false
	}
	return true, s.tabs[i].navRecord(path)
}

// NavBack / NavForward step id's history. Both return the target path the
// app must navigate to, ready to be queued and handed back on its poll.
func (s *TabStrip) NavBack(id uint32) (string, bool) {
	i := s.index(id)
	if i < 0 {
		return "", false
	}
	return s.tabs[i].navBack()
}

func (s *TabStrip) NavForward(id uint32) (string, bool) {
	i := s.index(id)
	if i < 0 {
		return "", false
	}
	return s.tabs[i].navForward()
}

// NavDepth is the recorded entry count for id (0 when the tab is unknown).
// Exported for the host test that pins the bound, and for any future rail
// affordance that wants to grey out a back button at depth 1.
func (s *TabStrip) NavDepth(id uint32) int {
	i := s.index(id)
	if i < 0 {
		return 0
	}
	return s.tabs[i].navCount
}

// CloseTab removes id. If it was focused, focus moves to the neighbour
// that occupies its slot after the shift (or the new last tab). Closing
// the last tab leaves the strip empty with no focus. Returns whether id
// was present.
func (s *TabStrip) CloseTab(id uint32) bool {
	i := s.index(id)
	if i < 0 {
		return false
	}
	// M71d (#1563, M48 BT1): record the closed tab in the bounded reopen
	// LIFO before it is shifted out of the strip. Zig push_closed_tab runs at
	// the same close decision point, so every close path (HID, RPC detach,
	// choreography) feeds the ring through this one seam.
	s.recordClosed(s.tabs[i])
	// M79e (#1708): a queued back/forward target dies with its tab. Every
	// close path (HID, RPC detach, choreography) funnels through here, so
	// this is the one place the pending slot has to be cleared — otherwise
	// a later window reusing the id polls and gets a dead tab's path.
	clearPendingNav(id)
	// M79k (#1720): same rule for a toast — a click-through whose sender is
	// gone would focus nothing. clearNotify prints the dismiss markers.
	clearNotify(id)
	clearSettingsSubscriptions(id)
	// M97g-F2 (#2080): the window's WM_RPC session token dies with the tab —
	// a later window reusing the id must bind fresh.
	dropRpcBinding(id)
	for j := i; j+1 < s.count; j++ {
		s.tabs[j] = s.tabs[j+1]
	}
	s.tabs[s.count-1] = Tab{}
	s.count--
	if s.count == 0 {
		s.focus = 0
		s.split = SplitNone
		s.sash = 0
		return true
	}
	if s.focus > i {
		s.focus--
	} else if s.focus >= s.count {
		s.focus = s.count - 1
	}
	if s.count < 2 {
		s.split = SplitNone
		s.sash = 0
	}
	return true
}

// recordClosed pushes t onto the bounded reopen LIFO. Bounded: at most MaxTabs
// entries are live and the oldest is overwritten (D2).
func (s *TabStrip) recordClosed(t Tab) {
	s.closed[s.closedCount%MaxTabs] = ClosedTab{
		Bin: t.Bin, Title: t.Title,
		State: t.State, StateVer: t.StateVer,
	}
	s.closedCount++
	if s.closedLive < MaxTabs {
		s.closedLive++
	}
}

// RecentlyClosed returns the k-th most recently closed tab (0 = most recent),
// or false when the ring holds fewer than k+1 live entries.
func (s *TabStrip) RecentlyClosed(k int) (ClosedTab, bool) {
	if k < 0 || k >= s.closedLive {
		return ClosedTab{}, false
	}
	return s.closed[(s.closedCount-1-k)%MaxTabs], true
}

// ReopenLastClosed pops the most recently closed tab and returns it for the
// caller to re-exec. Entries with no recorded bin are popped and skipped —
// Zig's rule: a tab the WM never spawned cannot be rebuilt, so the next press
// tries an older one. False when the ring holds nothing reopenable.
func (s *TabStrip) ReopenLastClosed() (ClosedTab, bool) {
	for s.closedLive > 0 {
		c := s.closed[(s.closedCount-1)%MaxTabs]
		s.closedCount--
		s.closedLive--
		if c.Bin == "" {
			continue
		}
		return c, true
	}
	return ClosedTab{}, false
}

// DuplicateFocused returns the focused tab's executable so the caller can
// re-exec it as a new tab. Honest no-op (false) when nothing is focused or
// the focused tab has no recorded bin. Zig duplicate_active_tab.
func (s *TabStrip) DuplicateFocused() (string, bool) {
	id, ok := s.Focused()
	if !ok {
		return "", false
	}
	i := s.index(id)
	if i < 0 || s.tabs[i].Bin == "" {
		return "", false
	}
	return s.tabs[i].Bin, true
}

// FocusTab makes id the focused tab. Returns false when id is not open.
func (s *TabStrip) FocusTab(id uint32) bool {
	i := s.index(id)
	if i < 0 {
		return false
	}
	s.focus = i
	return true
}

// NextID is the window id cycle would move to (wrap). One tab returns
// that tab; none returns false.
func (s *TabStrip) NextID() (uint32, bool) {
	if s.count == 0 {
		return 0, false
	}
	i := 0
	if s.focus >= 0 && s.focus < s.count {
		i = (s.focus + 1) % s.count
	}
	return s.tabs[i].ID, true
}

func (s *TabStrip) index(id uint32) int {
	for i := 0; i < s.count; i++ {
		if s.tabs[i].ID == id {
			return i
		}
	}
	return -1
}

// Pin sets FlagPinned on id and stable-partitions pinned tabs to the
// front (M48/BT3). Focus follows the same tab by id. False when id is
// missing or already pinned.
func (s *TabStrip) Pin(id uint32) bool {
	i := s.index(id)
	if i < 0 || s.tabs[i].Pinned {
		return false
	}
	s.tabs[i].Pinned = true
	s.normalizePinned()
	return true
}

// Unpin clears FlagPinned on id and re-partitions. Closing a pinned tab
// is allowed separately — pin is not a lock.
func (s *TabStrip) Unpin(id uint32) bool {
	i := s.index(id)
	if i < 0 || !s.tabs[i].Pinned {
		return false
	}
	s.tabs[i].Pinned = false
	s.normalizePinned()
	return true
}

// Reorder moves the tab at from to to. Same as Zig TABWM move_tab: any
// pair of indices, including pinned tabs. Pin-left is restored by Pin /
// Unpin (normalize_pinned), not by every move — a reorder can briefly
// leave a pinned tab off the front, matching M48. Focus follows by id.
func (s *TabStrip) Reorder(from, to int) bool {
	if from < 0 || to < 0 || from >= s.count || to >= s.count || from == to {
		return false
	}
	moved := s.tabs[from]
	fid, has := s.Focused()
	if from < to {
		for i := from; i < to; i++ {
			s.tabs[i] = s.tabs[i+1]
		}
	} else {
		for i := from; i > to; i-- {
			s.tabs[i] = s.tabs[i-1]
		}
	}
	s.tabs[to] = moved
	if has {
		s.focus = s.index(fid)
	}
	return true
}

func (s *TabStrip) normalizePinned() {
	if s.count == 0 {
		return
	}
	fid, has := s.Focused()
	var pinned, rest [MaxTabs]Tab
	np, nr := 0, 0
	for i := 0; i < s.count; i++ {
		if s.tabs[i].Pinned {
			pinned[np] = s.tabs[i]
			np++
		} else {
			rest[nr] = s.tabs[i]
			nr++
		}
	}
	n := 0
	for i := 0; i < np; i++ {
		s.tabs[n] = pinned[i]
		n++
	}
	for i := 0; i < nr; i++ {
		s.tabs[n] = rest[i]
		n++
	}
	if has {
		s.focus = s.index(fid)
	}
}

// orderLine is the rail report: ids and pin bits in strip order, plus
// who is focused. Not a LAYOUT.txt line (ADR 0033 has no pin= field).
func orderLine(s *TabStrip) string {
	ids := "ids="
	pins := "pin="
	for i := 0; i < s.count; i++ {
		if i > 0 {
			ids += ","
			pins += ","
		}
		ids += dec(s.tabs[i].ID)
		if s.tabs[i].Pinned {
			pins += "1"
		} else {
			pins += "0"
		}
	}
	f := uint32(0)
	if id, ok := s.Focused(); ok {
		f = id
	}
	return ids + " " + pins + " focus=" + dec(f)
}

// SplitKind is the two-pane layout (ADR 0033 LAYOUT.txt `split=`).
type SplitKind uint8

const (
	SplitNone  SplitKind = iota // split=none — full viewport
	SplitHoriz                  // split=h — top / bottom (horizontal divider)
	SplitVert                   // split=v — left / right (vertical divider)
)

func (k SplitKind) String() string {
	switch k {
	case SplitHoriz:
		return "h"
	case SplitVert:
		return "v"
	default:
		return "none"
	}
}

// PaneMinW / PaneMinH are the ADR 0033 pane floor (CSS-pixels on 1280×720).
const (
	PaneMinW uint32 = 160
	PaneMinH uint32 = 120
)

// Rect is a window rectangle in scanout pixels.
type Rect struct{ X, Y, W, H uint32 }

// FullRect is the unsplit viewport (origin + scanout size).
func FullRect(scanW, scanH uint32) Rect {
	return Rect{X: 0, Y: 0, W: scanW, H: scanH}
}

// Split reports the current two-pane kind.
func (s *TabStrip) Split() SplitKind { return s.split }

// SplitH splits two already-open tabs top/bottom. Refused unless count==2.
func (s *TabStrip) SplitH() bool { return s.setSplit(SplitHoriz) }

// SplitV splits two already-open tabs left/right. Refused unless count==2.
func (s *TabStrip) SplitV() bool { return s.setSplit(SplitVert) }

func (s *TabStrip) setSplit(k SplitKind) bool {
	if s.count != 2 || k == SplitNone {
		return false
	}
	s.split = k
	s.sash = 0
	return true
}

// Unsplit restores the unsplit (full-viewport) kind. False when already none.
func (s *TabStrip) Unsplit() bool {
	if s.split == SplitNone {
		return false
	}
	s.split = SplitNone
	s.sash = 0
	return true
}

// SplitRects is the integer two-pane layout. Remainder goes to the right
// (SplitV) or bottom (SplitH) pane so odd widths/heights do not drop a
// pixel. Refused when either pane would fall under PaneMinW×PaneMinH.
func SplitRects(kind SplitKind, scanW, scanH uint32) (Rect, Rect, bool) {
	if kind == SplitNone {
		full := FullRect(scanW, scanH)
		return full, full, true
	}
	if kind == SplitVert {
		left := scanW / 2
		right := scanW - left
		if left < PaneMinW || right < PaneMinW || scanH < PaneMinH {
			return Rect{}, Rect{}, false
		}
		return Rect{0, 0, left, scanH}, Rect{left, 0, right, scanH}, true
	}
	if kind == SplitHoriz {
		top := scanH / 2
		bot := scanH - top
		if scanW < PaneMinW || top < PaneMinH || bot < PaneMinH {
			return Rect{}, Rect{}, false
		}
		return Rect{0, 0, scanW, top}, Rect{0, top, scanW, bot}, true
	}
	return Rect{}, Rect{}, false
}

// PaneRects returns the two pane rects for the current split, or false
// when the strip is not two tabs.
func (s *TabStrip) PaneRects(scanW, scanH uint32) (Rect, Rect, bool) {
	if s.count != 2 {
		return Rect{}, Rect{}, false
	}
	return SplitRectsSash(s.split, scanW, scanH, s.sash)
}

// SashWidth is the M79c (#1706) divider width in scanout px: the gutter the
// seat leaves between split panes once the sash is dragged. The seat paints
// no content-area chrome (clients own their rects), so the divider is a real
// gap — background showing between the two client windows — not a painted
// strip. It applies only to a SET sash; the unset split tiles edge-to-edge
// exactly as before, so every pre-M79c gate assertion still holds.
const SashWidth = 6

// clampSash bounds a divider centre so both panes keep their ADR 0033
// minimum outside the SashWidth gutter. SplitVert centres an x, SplitHoriz
// a y; anything else (and a degenerate scanout) clamps to 0, which
// SplitRectsSash reads as unset.
func clampSash(kind SplitKind, pos int, scanW, scanH uint32) int {
	half := SashWidth / 2
	switch kind {
	case SplitVert:
		lo := int(PaneMinW) + half
		hi := int(scanW) - int(PaneMinW) - half
		if hi < lo {
			return 0
		}
		if pos < lo {
			return lo
		}
		if pos > hi {
			return hi
		}
		return pos
	case SplitHoriz:
		lo := int(PaneMinH) + half
		hi := int(scanH) - int(PaneMinH) - half
		if hi < lo {
			return 0
		}
		if pos < lo {
			return lo
		}
		if pos > hi {
			return hi
		}
		return pos
	default:
		return 0
	}
}

// SplitRectsSash is SplitRects with a drag-set divider: sash <= 0 is the
// unset midpoint tiling (byte-identical to SplitRects, gutterless), a set
// sash centres a SashWidth gutter on the clamped position. Refused when a
// pane would fall under PaneMinW×PaneMinH, like SplitRects.
func SplitRectsSash(kind SplitKind, scanW, scanH uint32, sash int) (Rect, Rect, bool) {
	if kind == SplitNone {
		full := FullRect(scanW, scanH)
		return full, full, true
	}
	if sash <= 0 {
		return SplitRects(kind, scanW, scanH)
	}
	c := clampSash(kind, sash, scanW, scanH)
	if c <= 0 {
		return Rect{}, Rect{}, false
	}
	half := SashWidth / 2
	if kind == SplitVert {
		lw := c - half
		rx := c + half
		rw := int(scanW) - rx
		if lw < int(PaneMinW) || rw < int(PaneMinW) || scanH < PaneMinH {
			return Rect{}, Rect{}, false
		}
		return Rect{0, 0, uint32(lw), scanH}, Rect{uint32(rx), 0, uint32(rw), scanH}, true
	}
	if kind == SplitHoriz {
		th := c - half
		by := c + half
		bh := int(scanH) - by
		if scanW < PaneMinW || th < int(PaneMinH) || bh < int(PaneMinH) {
			return Rect{}, Rect{}, false
		}
		return Rect{0, 0, scanW, uint32(th)}, Rect{0, uint32(by), scanW, uint32(bh)}, true
	}
	return Rect{}, Rect{}, false
}

// sashCenter is the strip's effective divider centre in scanout px for the
// current split: the stored sash, or the midpoint when unset. -1 when there
// is no split to divide.
func (s *TabStrip) sashCenter(scanW, scanH uint32) int {
	switch s.split {
	case SplitVert:
		if s.sash > 0 {
			return clampSash(s.split, s.sash, scanW, scanH)
		}
		return int(scanW) / 2
	case SplitHoriz:
		if s.sash > 0 {
			return clampSash(s.split, s.sash, scanW, scanH)
		}
		return int(scanH) / 2
	default:
		return -1
	}
}

// SetSash stores a drag-set divider centre. Refused unless the strip is two
// tabs in a split, and a no-op (false) when the clamped position equals the
// current centre — a release where the press landed must not relayout or
// mark. No syscalls: the seat applies the rects after a true change.
func (s *TabStrip) SetSash(pos int, scanW, scanH uint32) bool {
	if s.count != 2 || (s.split != SplitVert && s.split != SplitHoriz) {
		return false
	}
	c := clampSash(s.split, pos, scanW, scanH)
	if c <= 0 || c == s.sashCenter(scanW, scanH) {
		return false
	}
	s.sash = c
	return true
}

// sashZoneAt is the M79c (#1706) divider hit test: within half the SashWidth
// of the divider centre, below the rail and clear of the bottom chrome, so
// the zone can never disagree with the gutter SplitRectsSash leaves. It
// mirrors railCellAt's shape (pure geometry, caller owns strip state).
// False for SplitNone and off-zone points.
func sashZoneAt(px, py uint32, kind SplitKind, center int, scanW, scanH int) bool {
	if center < 0 || scanW <= 0 || scanH <= 0 {
		return false
	}
	// The rail owns y < RailHeight and the bottom 22 px stay chrome-clear
	// (the clock panel sits bottom-right); the sash owns neither.
	if py < uint32(RailHeight) || int(py)+22 > scanH {
		return false
	}
	half := SashWidth / 2
	switch kind {
	case SplitVert:
		if int(px) >= scanW {
			return false
		}
		d := int(px) - center
		return d >= -half && d <= half
	case SplitHoriz:
		if int(px) >= scanW {
			return false
		}
		d := int(py) - center
		return d >= -half && d <= half
	default:
		return false
	}
}

// rectsWithin reports whether a and b differ by at most tol on every edge.
func rectsWithin(a, b Rect, tol uint32) bool {
	return uabs(a.X, b.X) <= tol && uabs(a.Y, b.Y) <= tol &&
		uabs(a.W, b.W) <= tol && uabs(a.H, b.H) <= tol
}

func uabs(a, b uint32) uint32 {
	if a > b {
		return a - b
	}
	return b - a
}

// layoutLine is one ADR 0033 LAYOUT.txt surface line (no trailing LF).
// bin is a single token: a space or newline would break bin=\S+ and the
// one-line-per-tab dump. Gate titles are app-controlled (GOCALC.ELF etc.).
func layoutLine(id uint32, bin string, r Rect, focus bool, kind SplitKind) string {
	if bin == "" {
		bin = "-"
	}
	f := "0"
	if focus {
		f = "1"
	}
	return "tab=" + dec(id) +
		" bin=" + bin +
		" x=" + dec(r.X) +
		" y=" + dec(r.Y) +
		" w=" + dec(r.W) +
		" h=" + dec(r.H) +
		" focus=" + f +
		" split=" + kind.String()
}

// paneLine is the applied-rect counterpart the gate pairs with layoutLine.
func paneLine(id uint32, r Rect) string {
	return "id=" + dec(id) +
		" x=" + dec(r.X) +
		" y=" + dec(r.Y) +
		" w=" + dec(r.W) +
		" h=" + dec(r.H)
}

func dec(v uint32) string {
	if v == 0 {
		return "0"
	}
	var b [10]byte
	i := len(b)
	for v > 0 {
		i--
		b[i] = byte('0' + v%10)
		v /= 10
	}
	return string(b[i:])
}

// paintRail fills the top stripH rows of a width x height scanout with
// one cell per tab. The focused cell carries the §2.3.6 selection
// treatment — Selection fill plus the 3px Accent left-edge marker — the
// hovered cell (M79b #1705, `hover` is the cell index or -1) uses
// railHoverRGB, and the rest railIdleRGB. Every cell carries the close
// glyph (VirelaiChrome window-close, the bitmap 'x' when the symbol face
// is absent) in its close zone, tinted Danger while `closeHover` points
// at it. Returns how many pixels in the strip were written. No syscalls —
// the seat paints, then presents, then prints the rail marker.
func paintRail(scan []byte, width, height, stripH int, ts *TabStrip, hover, closeHover int) int {
	n := ts.Count()
	if n == 0 || width <= 0 || height <= 0 || stripH <= 0 || len(scan) < 4 {
		return 0
	}
	if stripH > height {
		stripH = height
	}
	if pixN := len(scan) / 4; pixN < width {
		return 0
	}
	c := seatCanvas(scan, width, stripH)
	if c == nil {
		return 0
	}
	stripH = c.H
	// Trough behind the cells (matches the blank desktop so a gap is a gap).
	written := seatFill(c, widgets.Rect{X: 0, Y: 0, W: width, H: stripH}, railGapRGB())
	cellW := width / n
	if cellW < 48 {
		cellW = 48
	}
	focus, _ := ts.Focused()
	tok := theme.Current
	for i := 0; i < n; i++ {
		x := i * cellW
		w := cellW
		if x >= width {
			break
		}
		if x+w > width {
			w = width - x
		}
		if w <= 1 {
			continue
		}
		cell := widgets.Rect{X: x + 1, Y: 0, W: w - 1, H: stripH}
		if ts.At(i).ID == focus {
			// §2.3.6: the selected cell is a Selection fill carrying the
			// 3px Accent marker the Zig tab chrome drew as a 3x22 bar.
			written += seatFill(c, cell, tok.Selection)
			written += seatFill(c, widgets.Rect{X: x + 1, Y: 0, W: seatMarkerW, H: stripH}, tok.Accent)
		} else {
			rgb := railIdleRGB()
			if i == hover {
				// M79b (#1705): the hover tint. Focus wins on the focused
				// cell so the pointer never masks the keyboard's target.
				rgb = railHoverRGB()
			}
			// 1px trough on the left, like kernel paint_tab_strip.
			written += seatFill(c, cell, rgb)
		}
		// M71e (#1564): the frozen badge, inset at the cell's right edge and
		// painted after the cell fill so it reads on both idle and focused
		// cells. A badge only — nothing about the tab's behaviour changes.
		if ts.At(i).Frozen {
			bw := railBadgeW
			if bw > w-2 {
				bw = w - 2
			}
			if bw > 0 && stripH > 2*railBadgeInset {
				written += seatFill(c, widgets.Rect{X: x + w - 1 - bw, Y: railBadgeInset, W: bw, H: stripH - 2*railBadgeInset}, railFrozenRGB())
			}
		}
		// M79b (#1705): the close glyph — VirelaiChrome's window-close,
		// the bitmap 'x' when the symbol face is absent — inside the
		// cell's close zone and left of the frozen badge's edge strip.
		// Painted on every cell (idle, hovered, focused): a user must be
		// able to FIND the button before they can hover it. Cells too
		// narrow for the zone get no glyph and no hit target
		// (railCloseZoneAt). Under the pointer the glyph tints Danger —
		// the §2.4 destructive-hover state.
		if w >= railCloseW && stripH >= 8 {
			ink := railCloseRGB()
			if i == closeHover {
				ink = tok.Danger
			}
			zone := widgets.Rect{X: x + w - railCloseW, Y: 0, W: railCloseW, H: stripH}
			closeIcon, _ := icons.Codepoint("window-close")
			seatGlyph(c, zone, closeIcon, ink, "x",
				x+w-railCloseW+railCloseInset, (stripH-8)/2)
			written++
		}
	}
	return written
}
