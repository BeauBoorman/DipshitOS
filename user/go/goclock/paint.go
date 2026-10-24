// paint.go — the face: fixed native geometry helpers and the per-tab
// painters (world rows, stopwatch, timer presets, the alarm list) plus
// the post-present `goclock: painted` marker main flushes after each
// frame. Event dispatch and the deadline verbs live in main.go and
// alarms.go.
package main

import (
	"virelai/draw"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// drawText paints one labelled plate (widgets.Text.Draw has a pointer
// receiver, so the call sites cannot chain it off a literal).
func drawText(cv widgets.Canvas, r widgets.Rect, label string, fg, bg uint32) {
	t := widgets.Text{R: r, Label: label, Fg: fg, Bg: bg}
	t.Draw(cv)
}

// --- paint -------------------------------------------------------------------

// flushPainted prints the post-present marker: the frame carrying epoch
// a.paintedEpoch's face is flushed when the line lands.
func (a *app) flushPainted() {
	if a.tab == tabWorld && a.paintedEpoch > 0 {
		vi.ConsoleLine(markerPainted + vi.Itoa64(a.paintedEpoch))
	}
}

func (a *app) paint() {
	cv := a.ta.Canvas()
	if cv == nil {
		return
	}
	th := theme.Current
	cv.FillRect(widgets.Rect{W: int(a.ta.W), H: int(a.ta.H)}, draw.Opaque(th.Bg))
	a.paintStrip(cv)
	switch a.tab {
	case tabWorld:
		a.paintWorld(cv)
	case tabStopwatch:
		a.paintStopwatch(cv)
	case tabTimer:
		a.paintTimer(cv)
	case tabAlarm:
		a.paintAlarm(cv)
	}
}

func (a *app) paintStrip(cv widgets.Canvas) {
	th := theme.Current
	cv.FillRect(stripR, draw.Opaque(th.Border))
	for i := 0; i < tabCount; i++ {
		cr := stripCell(i)
		face := th.Surface
		if i == a.tab {
			face = th.Selection
		}
		cv.FillRect(cr.Inset(1), draw.Opaque(face))
		widgets.DrawText(cv, cr.Inset(4), tabNames[i], draw.Opaque(th.Text))
	}
}

func (a *app) paintWorld(cv widgets.Canvas) {
	th := theme.Current
	now := a.now()
	if now < 0 {
		drawText(cv, displayR, "no wall clock", th.InkMuted, th.Surface)
		return
	}
	a.paintedEpoch = now
	for i, z := range a.zones {
		fg := th.Ink
		if i == 0 {
			fg = th.Accent
		}
		drawText(cv, worldRowR(i), worldRow(now, z), fg, th.Surface)
	}
}

func (a *app) paintStopwatch(cv widgets.Canvas) {
	th := theme.Current
	drawText(cv, displayR, FormatElapsed(a.sw.Elapsed(a.nano())), th.Ink, th.Surface)
	hint := "space start/pause - r reset"
	if a.sw.Running() {
		hint = "running - space stops - r resets"
	}
	drawText(cv, hintR, hint, th.InkMuted, th.Surface)
	a.buttons[0] = widgets.Button{R: btnR0, Label: "Start"}
	if a.sw.Running() {
		a.buttons[0].Label = "Pause"
	}
	a.buttons[1] = widgets.Button{R: btnR1, Label: "Reset"}
	a.buttons[0].Draw(cv)
	a.buttons[1].Draw(cv)
}

func (a *app) paintTimer(cv widgets.Canvas) {
	th := theme.Current
	e := a.entryFor(tabTimer)
	disp := "timer"
	if r := a.remaining("timer"); r >= 0 {
		disp = itoa(r) + "s left"
	} else if a.timerEdit && !e.Empty() {
		disp = e.String() + "s"
	}
	drawText(cv, displayR, disp, th.Ink, th.Surface)
	hint := "1-5 preset min - e custom seconds - x cancels"
	if a.timerEdit {
		drawText(cv, entryR, "seconds: "+e.String(), th.Ink, th.Surface)
		hint = "digits seconds - return arms - esc presets"
	} else {
		for i := 0; i < len(timerPresets); i++ {
			a.presetButtons[i] = widgets.Button{R: presetR(i), Label: timerPresetLabels[i]}
			a.presetButtons[i].Draw(cv)
		}
	}
	drawText(cv, hintR, hint, th.InkMuted, th.Surface)
	a.buttons[0] = widgets.Button{R: btnR0, Label: "Arm"}
	a.buttons[1] = widgets.Button{R: btnR1, Label: "Cancel"}
	a.buttons[0].Draw(cv)
	a.buttons[1].Draw(cv)
}

// nextAlarmRemaining is the seconds-to-go of the earliest enabled row;
// ok is false when nothing is armed (a past-due row counts as armed —
// it is about to fire).
func (a *app) nextAlarmRemaining() (int64, bool) {
	best := int64(0)
	found := false
	for _, al := range a.alarms {
		if al.Enabled && (!found || al.At < best) {
			best, found = al.At, true
		}
	}
	return best - a.now(), found
}

func (a *app) paintAlarm(cv widgets.Canvas) {
	th := theme.Current
	e := a.entryFor(tabAlarm)
	disp := "alarms"
	if r, ok := a.nextAlarmRemaining(); ok {
		disp = "next in " + FormatElapsed(r*1_000_000_000)
	} else if s := e.String(); len(s) > 2 {
		disp = s[:len(s)-2] + ":" + s[len(s)-2:]
	} else {
		disp = s
	}
	drawText(cv, displayR, disp, th.Ink, th.Surface)
	entryLab := "HHMM: " + e.String()
	hint := "4 digits - return daily - o once - e edits - up/dn pick - spc toggles - x del"
	if a.alarmEdit {
		entryLab = "edit HHMM: " + e.String()
		hint = "retype 4 digits - return commits - esc cancels"
	}
	drawText(cv, entryR, entryLab, th.Ink, th.Surface)
	drawText(cv, hintR, hint, th.InkMuted, th.Surface)
	a.buttons[0] = widgets.Button{R: btnR0, Label: "Daily"}
	a.buttons[1] = widgets.Button{R: btnR1, Label: "Once"}
	a.buttons[0].Draw(cv)
	a.buttons[1].Draw(cv)
	for i, al := range a.alarms {
		h, m, _ := parseHHMM(al.HHMM)
		state := "on"
		fg := th.Ink
		if !al.Enabled {
			state = "off"
			fg = th.InkMuted
		}
		label := two(int64(h)) + ":" + two(int64(m)) + "  " + alarmMode(al.Daily) + "  " + state
		if al.Summary != "" {
			label += "  " + al.Summary
		}
		bg := th.Surface
		if i == a.alarmSel {
			bg = th.Selection
			if al.Enabled {
				fg = th.Text
			}
		}
		drawText(cv, alarmRowR(i), label, fg, bg)
	}
}

// remaining is the armed deadline's seconds-to-go, -1 when unarmed.
func (a *app) remaining(id string) int64 {
	for _, d := range a.sched.ds {
		if d.ID == id {
			return d.At - a.now()
		}
	}
	return -1
}
