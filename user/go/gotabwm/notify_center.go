package main

import (
	"virelai/draw"
	"virelai/icons"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// The center is the history of recently accepted kind-12 notices.
// It is intentionally separate from the short-lived toast queue: expiry
// removes a toast, but the user can still review and act on its notice.
// M82d2 (#1785) adds its policy in notify_policy.go: the history is persisted
// across a seat restart, and the header carries the do-not-disturb control.
const (
	NotifyCenterMax = 8
	notifyCenterW   = 520
	notifyCenterH   = 360
	notifyRowH      = 34
	notifyHeaderH   = 30
	notifyFooterH   = 28
	notifyCenterPad = 12
	// The do-not-disturb control sits in the header, left of the close X
	// (whose hit zone is the trailing 42px). It exists only when the panel
	// is wide enough that it cannot run into the title.
	notifyDNDW    = 176
	notifyDNDMinW = 360
	notifyDNDGapX = 42

	MarkerNotifyCenterOpen   = "gotabwm: notify center open"
	MarkerNotifyCenterClose  = "gotabwm: notify center close"
	MarkerNotifyCenterPaint  = "gotabwm: notify center paint"
	MarkerNotifyCenterAction = "gotabwm: notify center "
)

type centerNotification struct {
	tabID      uint32
	id         uint32
	source     string
	text       string
	sourceGone bool
	// M123c (#2577): a kind-22 progress row — progress reports an
	// operation rather than recording a one-shot notice. op is the
	// app-scoped id (title[0] of the request), pct the last reported
	// 0..100 or -1 for indeterminate, pid the reporter's pid — the
	// kind-23 cancel push's target.
	progress bool
	op       uint8
	pct      int
	pid      uint8
	// action is the seat action this row's body click runs — the same
	// kind the toast carries (M125f's crash restore, M123a's
	// retry/grant/copy). notifyActionNone on every ordinary notice.
	action uint8
	// snap is the action's payload: the crash-save slot name on M125f's
	// recovery offer, M123a's binary name or error text. Its row's
	// click is the action, not a sender focus. Empty on every ordinary
	// notice.
	snap string
}

var (
	notifyCenter        []centerNotification
	notifyCenterOpen    bool
	notifyCenterNextID  uint32
	notifyCenterPainted bool
	focusNotifySource   = focusHosted
)

func notifyCenterPush(tabID uint32, text string) uint32 {
	return notifyCenterPushAction(tabID, text, notifyActionNone, "")
}

// notifyCenterPushAction carries the toast's action kind and payload
// onto the history row so an actionable notice survives its own toast's
// expiry: the row is the action after the toast fades.
func notifyCenterPushAction(tabID uint32, text string, action uint8, snap string) uint32 {
	source := "App " + vi.Itoa64(int64(tabID))
	if action != notifyActionNone {
		// An action toast is the seat's own, not a sender's — a
		// bogus "App 0" would send a reader hunting for window zero.
		source = "Seat"
	} else if i := tabs.index(tabID); i >= 0 && tabs.At(i).Title != "" {
		source = tabs.At(i).Title
	}
	if len(notifyCenter) == NotifyCenterMax {
		copy(notifyCenter, notifyCenter[1:])
		notifyCenter = notifyCenter[:NotifyCenterMax-1]
	}
	notifyCenterNextID++
	if notifyCenterNextID == 0 {
		notifyCenterNextID++
	}
	notifyCenter = append(notifyCenter, centerNotification{
		tabID: tabID, id: notifyCenterNextID, source: source, text: text,
		action: action, snap: snap,
	})
	notifyHistoryChanged()
	return notifyCenterNextID
}

// notifyCenterSourceClosed preserves the notification while making its dead
// source explicit. The closed bit is latched, so a later window-id reuse can
// never turn a historical item into a link to an unrelated app.
func notifyCenterSourceClosed(tabID uint32) {
	for i := range notifyCenter {
		if notifyCenter[i].tabID == tabID {
			notifyCenter[i].sourceGone = true
		}
	}
}

func dismissNotifyCenter(index int) bool {
	if index < 0 || index >= len(notifyCenter) {
		return false
	}
	copy(notifyCenter[index:], notifyCenter[index+1:])
	notifyCenter[len(notifyCenter)-1] = centerNotification{}
	notifyCenter = notifyCenter[:len(notifyCenter)-1]
	notifyHistoryChanged()
	return true
}

// dropCenterRowToast removes the toast paired to center row id, printing
// its dismiss marker when one was live — a resolved or removed row never
// leaves its toast behind to answer twice.
func dropCenterRowToast(id uint32) {
	keep := notifyQueue[:0]
	dismissed := false
	var sender uint32
	for _, toast := range notifyQueue {
		if toast.centerID == id {
			dismissed = true
			sender = toast.tabID
			continue
		}
		keep = append(keep, toast)
	}
	notifyQueueSet(keep)
	if dismissed {
		vi.ConsoleLine(MarkerNotifyDismiss + vi.Itoa64(int64(sender)))
	}
}

// dropCenterRowByID removes the history row id when present — a resolved
// offer's toast click retires the paired row with it.
func dropCenterRowByID(id uint32) {
	for i := range notifyCenter {
		if notifyCenter[i].id == id {
			dismissNotifyCenter(i)
			return
		}
	}
}

func dismissNotifyCenterEntry(index int) bool {
	if index < 0 || index >= len(notifyCenter) {
		return false
	}
	entry := notifyCenter[index]
	if entry.action == notifyActionCrashSnap {
		// M125f (#2591): dismissing the recovery offer's row is the
		// offer's Dismiss gesture — resolved and consumed, like a click's
		// Restore, only in the other direction.
		crashSnapDismiss(entry.snap)
	}
	id := entry.id
	dismissNotifyCenter(index)
	dropCenterRowToast(id)
	return true
}

func clearNotifyCenter() int {
	// Snap offers inside a clear-all are dismissed one by one — the
	// resolve is part of the removal, not a silent drop.
	for _, entry := range notifyCenter {
		if entry.action == notifyActionCrashSnap {
			crashSnapDismiss(entry.snap)
		}
	}
	n := len(notifyCenter)
	notifyCenter = nil
	if n > 0 {
		notifyHistoryChanged()
	}
	if len(notifyQueue) > 0 {
		queued := notifyQueue
		notifyQueueSet(nil)
		for _, toast := range queued {
			vi.ConsoleLine(MarkerNotifyDismiss + vi.Itoa64(int64(toast.tabID)))
		}
	}
	return n
}

func notifyCenterRect(width, height int) (x, y, w, h int) {
	if width <= 0 || height <= 0 {
		return 0, 0, 0, 0
	}
	w, h = notifyCenterW, notifyCenterH
	if w > width-2*chromeInset {
		w = width - 2*chromeInset
	}
	if h > height-2*chromeInset {
		h = height - 2*chromeInset
	}
	if w <= 0 || h <= 0 {
		return 0, 0, 0, 0
	}
	return (width - w) / 2, (height - h) / 2, w, h
}

// notifyCenterDNDRect is the do-not-disturb control's rect: the header band,
// right-aligned against the close X's zone. Paint and hit test both use it, so
// the drawn control and the clickable one cannot disagree. A panel too narrow
// to fit it beside the title has no control (the zero rect), never an
// overlapping one.
func notifyCenterDNDRect(width, height int) (x, y, w, h int) {
	px, py, pw, _ := notifyCenterRect(width, height)
	if pw < notifyDNDMinW {
		return 0, 0, 0, 0
	}
	return px + pw - notifyDNDGapX - notifyDNDW, py, notifyDNDW, notifyHeaderH
}

func notifyCenterDNDLabel() string {
	if notifyDND {
		return "Do not disturb [on]"
	}
	return "Do not disturb [off]"
}

func notifyCenterClockHit(px, py uint32, width, height int) bool {
	x, y, w, h := chromeRect(width, height)
	return w > 0 && h > 0 && int(px) >= x && int(px) < x+w &&
		int(py) >= y && int(py) < y+h
}

func notifyCenterHit(px, py uint32, width, height int) bool {
	if !notifyCenterOpen {
		return false
	}
	x, y, w, h := notifyCenterRect(width, height)
	return w > 0 && h > 0 && int(px) >= x && int(px) < x+w &&
		int(py) >= y && int(py) < y+h
}

// notifyCenterClick handles a pointer press in the center or its clock-panel
// affordance. A source click focuses the sender but leaves the center open;
// row X dismisses just that item, while the footer clears the full history.
func notifyCenterClick(px, py uint32) bool {
	if !notifyCenterOpen {
		if !notifyCenterClockHit(px, py, vi.ScanoutWidth, vi.ScanoutHeight) {
			return false
		}
		notifyCenterOpen = true
		notifyCenterPainted = false
		vi.ConsoleLine(MarkerNotifyCenterOpen)
		return true
	}

	x, y, w, h := notifyCenterRect(vi.ScanoutWidth, vi.ScanoutHeight)
	if w <= 0 || h <= 0 {
		notifyCenterOpen = false
		notifyCenterPainted = false
		vi.ConsoleLine(MarkerNotifyCenterClose)
		return true
	}
	pxi, pyi := int(px), int(py)
	if !notifyCenterHit(px, py, vi.ScanoutWidth, vi.ScanoutHeight) {
		notifyCenterOpen = false
		notifyCenterPainted = false
		vi.ConsoleLine(MarkerNotifyCenterClose)
		return true
	}
	if pyi < y+notifyHeaderH && pxi >= x+w-42 {
		notifyCenterOpen = false
		notifyCenterPainted = false
		vi.ConsoleLine(MarkerNotifyCenterClose)
		return true
	}
	if dx, dy, dw, dh := notifyCenterDNDRect(vi.ScanoutWidth, vi.ScanoutHeight); dw > 0 &&
		pxi >= dx && pxi < dx+dw && pyi >= dy && pyi < dy+dh {
		toggleNotifyDND()
		return true
	}
	visible := notifyCenterVisibleRows(h)
	rowsY := y + notifyHeaderH
	if pyi >= rowsY && pyi < rowsY+visible*notifyRowH {
		index := (pyi - rowsY) / notifyRowH
		if index < len(notifyCenter) {
			entry := notifyCenter[index]
			// M123c: a live progress row's trailing affordance is
			// "Cancel" (the wider notifyProgressCancelW zone), not the
			// plain dismiss X. A done row or one whose source is gone
			// has nothing left to cancel — plain dismiss.
			if entry.progress && !entry.progressDone() && !entry.sourceGone {
				if pxi >= x+w-notifyProgressCancelW {
					notifyProgressCancel(index)
					return true
				}
			} else if pxi >= x+w-34 {
				if dismissNotifyCenterEntry(index) {
					vi.ConsoleLine(MarkerNotifyCenterAction + "dismiss")
				}
				return true
			}
			if entry.action != notifyActionNone {
				// An action row's body click is its action's gesture —
				// the same arm a toast click runs, so the answer does not
				// depend on which surface carried the report. A resolved
				// report leaves both surfaces: the row like a dismissed
				// one, its toast like an expired one.
				runNotifyAction(entry.action, entry.snap)
				dismissNotifyCenter(index)
				dropCenterRowToast(entry.id)
				vi.ConsoleLine(MarkerNotifyCenterAction + refusalActionName(entry.action) + " " + entry.snap)
				return true
			}
			if !entry.sourceGone && tabs.index(entry.tabID) >= 0 {
				if focusNotifySource(entry.tabID) {
					vi.ConsoleLine(MarkerNotifyCenterAction + "focus id=" + vi.Itoa64(int64(entry.tabID)))
					vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(entry.tabID)))
					vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(entry.tabID)))
				} else {
					// The kernel reaps a client's windows when its process
					// exits. A refused focus latches a closed source instead
					// of retrying a dead window id on every later click.
					notifyCenter[index].sourceGone = true
					vi.ConsoleLine(MarkerNotifyCenterAction + "source closed id=" + vi.Itoa64(int64(entry.tabID)))
				}
			}
			return true
		}
	}
	if pyi >= y+h-notifyFooterH && pxi < x+w-42 {
		if clearNotifyCenter() > 0 {
			vi.ConsoleLine(MarkerNotifyCenterAction + "clear all")
		}
		return true
	}
	return true
}

func notifyCenterVisibleRows(height int) int {
	rows := (height - notifyHeaderH - notifyFooterH) / notifyRowH
	if rows < 0 {
		return 0
	}
	if rows > NotifyCenterMax {
		return NotifyCenterMax
	}
	return rows
}

func paintNotifyCenter(scan []byte, width, height int) int {
	if !notifyCenterOpen || width <= 0 || height <= 0 || len(scan) < 4 {
		return 0
	}
	x, y, w, h := notifyCenterRect(width, height)
	if w <= 0 || h <= 0 {
		return 0
	}
	c := seatCanvas(scan, width, height)
	if c == nil {
		return 0
	}
	tok := theme.Current
	plate := widgets.Rect{X: x, Y: y, W: w, H: h}
	// A floating plate: the §2.5 shadow, the §2.2 radius, the Rule border.
	seatShadow(c, plate, radiusWindow)
	written := seatPlate(c, plate, radiusWindow, tok.Accent, tok.Surface)
	draw.StrokeRoundedRect(c, plate, radiusWindow, tok.BorderW, draw.Opaque(tok.Rule))
	clip := plate.Inset(tok.BorderW)
	closeIcon, _ := icons.Codepoint("window-close")
	seatText(c, clip, x+notifyCenterPad, y+10, seatTextPx, "Notifications", tok.Ink)
	// The header's close glyph is centred on its hit zone — the trailing
	// 42px of the header — not on the old 'X' cell.
	seatGlyph(c, widgets.Rect{X: x + w - 42, Y: y, W: 42, H: notifyHeaderH},
		closeIcon, tok.Muted, "X", x+w-28, y+10)
	if dx, _, dw, _ := notifyCenterDNDRect(width, height); dw > 0 {
		// Accent when on: the mode has to be readable at a glance, because
		// a silenced center is a state the user must not forget they set.
		fg := tok.Muted
		if notifyDND {
			fg = tok.Accent
		}
		seatText(c, clip, dx, y+10, seatTextPx, notifyCenterDNDLabel(), fg)
	}
	written += seatFill(c, widgets.Rect{X: x + notifyCenterPad, Y: y + notifyHeaderH - 1,
		W: w - 2*notifyCenterPad, H: 1}, tok.Border)

	rows := notifyCenterVisibleRows(h)
	for i := 0; i < rows && i < len(notifyCenter); i++ {
		rowY := y + notifyHeaderH + i*notifyRowH
		entry := notifyCenter[i]
		source := entry.source
		fg := tok.Ink
		if entry.sourceGone || tabs.index(entry.tabID) < 0 {
			source += " [closed]"
			fg = tok.Muted
		}
		seatText(c, clip, x+notifyCenterPad, rowY+2, seatTextPx,
			centerText(source, 48), fg)
		if entry.progress {
			label := entry.text
			if entry.pct >= 0 {
				label = label + " " + vi.Itoa64(int64(entry.pct)) + "%"
			}
			seatText(c, clip, x+notifyCenterPad, rowY+16, seatTextPx,
				centerText(label, 48), tok.InkMuted)
			// The bar: accent fill for the reported fraction, or the
			// sweeping segment while the total is unknown (seatTick
			// drives it at the seat's own 1 Hz cadence).
			barW := w - 2*notifyCenterPad - notifyProgressCancelW - notifyCenterPad
			bar := widgets.Rect{X: x + notifyCenterPad, Y: rowY + 27, W: barW, H: 4}
			written += seatFill(c, bar, tok.Rule)
			if entry.pct >= 0 {
				written += seatFill(c, widgets.Rect{X: bar.X, Y: bar.Y,
					W: bar.W * entry.pct / 100, H: bar.H}, tok.Accent)
			} else {
				off, seg := notifyProgressSweep(compositeClock, bar.W)
				written += seatFill(c, widgets.Rect{X: bar.X + off, Y: bar.Y,
					W: seg, H: bar.H}, tok.Accent)
			}
			if !entry.progressDone() && !entry.sourceGone {
				seatText(c, clip, x+w-notifyProgressCancelW+4, rowY+13,
					seatTextPx, "Cancel", tok.Muted)
			} else {
				seatGlyph(c, widgets.Rect{X: x + w - 34, Y: rowY, W: 34, H: notifyRowH},
					closeIcon, tok.Muted, "X", x+w-28, rowY+10)
			}
		} else {
			seatText(c, clip, x+notifyCenterPad, rowY+16, seatTextPx,
				centerText(entry.text, 48), tok.InkMuted)
			// The row's dismiss glyph, centred on its trailing-34px hit zone.
			seatGlyph(c, widgets.Rect{X: x + w - 34, Y: rowY, W: 34, H: notifyRowH},
				closeIcon, tok.Muted, "X", x+w-28, rowY+10)
		}
		if i+1 < rows && i+1 < len(notifyCenter) {
			written += seatFill(c, widgets.Rect{X: x + notifyCenterPad, Y: rowY + notifyRowH - 1,
				W: w - 2*notifyCenterPad, H: 1}, tok.Border)
		}
	}
	footerY := y + h - notifyFooterH
	written += seatFill(c, widgets.Rect{X: x + notifyCenterPad, Y: footerY,
		W: w - 2*notifyCenterPad, H: tok.BorderW}, tok.Border)
	seatText(c, clip, x+notifyCenterPad, footerY+10, seatTextPx, "Clear all", tok.Ink)
	return written
}

func notifyCenterPaintMarker(painted, presented bool) (string, bool) {
	if !notifyCenterOpen || !painted || !presented || notifyCenterPainted {
		return "", false
	}
	notifyCenterPainted = true
	return MarkerNotifyCenterPaint, true
}

func centerText(s string, max int) string {
	if len(s) <= max {
		return s
	}
	if max <= 3 {
		return s[:max]
	}
	return s[:max-3] + "..."
}
