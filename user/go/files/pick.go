// M124b (#2581): GOFILES's pick mode — `exec GOFILES.ELF pick [dir]` runs the
// shared appkit.FilePicker over the same bound tty. The picker's model (dir
// listing + recents + trash-with-restore + mime) is the whole surface; this
// file is only the ANSI face and the keys.Event -> vi.Event translation the
// picker's HandleKey consumes. Enter on a file prints `gofiles: picked
// <path>` and exits — the invoker (a gate leg, a launcher script) reads the
// receipt off the serial console, the only channel a pick can answer on.
// The runtime loop is pickrun.go (tagged); everything here is plain
// functions the host test can pin.
package main

import (
	"strings"

	"virelai/appkit"
	"virelai/rss/keys"
	"virelai/vi"
)

const (
	markerPickMode   = "gofiles: pick mode "
	markerPicked     = "gofiles: picked "
	markerPickCancel = "gofiles: pick cancel"
)

// pickDone prints the result receipt: the picked path, or the cancel line.
func pickDone(p *appkit.FilePicker) {
	if p.Result == "cancel" || p.Result == "" {
		vi.ConsoleLine(markerPickCancel)
		return
	}
	vi.ConsoleLine(markerPicked + p.Result)
}

// pickKeyEvent translates a tty-decoded key into the vi.Event the picker's
// HandleKey consumes — HID usages on Arg0, the codepoint on Arg1, the same
// duality the canvas adopters' kernels deliver. Ctrl-C reads as the cancel
// it means here.
func pickKeyEvent(ev keys.Event) vi.Event {
	d := func(usage uint32, ch rune) vi.Event {
		return vi.Event{Kind: vi.EvKeyDown, Arg0: usage, Arg1: uint32(ch)}
	}
	switch ev.Key {
	case keys.KeyEnter:
		return d(0x28, '\r')
	case keys.KeyEsc, keys.KeyCtrlC:
		return d(0x29, 0x1b)
	case keys.KeyTab:
		return d(0x2b, '\t')
	case keys.KeyBackspace:
		return d(0x2a, 0x7f)
	case keys.KeyUp:
		return d(0x52, 0)
	case keys.KeyDown:
		return d(0x51, 0)
	case keys.KeyLeft:
		return d(0x50, 0)
	case keys.KeyRight:
		return d(0x4f, 0)
	case keys.KeyHome:
		return d(0x4a, 0)
	case keys.KeyEnd:
		return d(0x4d, 0)
	case keys.KeyPageUp:
		return d(0x4b, 0)
	case keys.KeyPageDown:
		return d(0x4e, 0)
	case keys.KeyRune:
		return vi.Event{Kind: vi.EvKeyDown, Arg1: uint32(ev.Rune)}
	}
	return vi.Event{Kind: vi.EvKeyDown}
}

// pickPaint writes one picker frame into the bound tty — the same
// write-the-whole-frame discipline paint() keeps.
func pickPaint(fd uint32, p *appkit.FilePicker, cols, rows int) bool {
	data := []byte(pickFrame(p, cols, rows))
	n, rc := vi.FileWriteAll(fd, data)
	return rc >= 0 && n == len(data)
}

// pickFrame renders the picker as ANSI rows in the file manager's own
// palette: a `pick:` path bar, the shared row list with kind/mime tags and
// the selection plate, the typed-path field, and the hint line — exactly
// `rows` lines like render() produces.
func pickFrame(p *appkit.FilePicker, cols, rows int) string {
	lines := make([]string, 0, rows)

	lines = append(lines, colPath+"  pick: "+clipVis(p.Dir, cols-10)+colReset)
	head := clipVis(" files · recent · trash ", cols)
	lines = append(lines, colHead+head+strings.Repeat(" ", cols-visLen(head))+colReset)

	body := rows - 4
	for i := 0; i < body; i++ {
		idx := p.Scroll + i
		if idx >= len(p.Rows) {
			lines = append(lines, strings.Repeat(" ", cols))
			continue
		}
		r := p.Rows[idx]
		if idx == p.Sel {
			label := clipVis(r.Label+"  "+pickTag(r), cols-4)
			lines = append(lines, colSel+"> "+label+
				strings.Repeat(" ", cols-2-visLen(label))+colReset)
			continue
		}
		style := colFile
		switch r.Kind {
		case appkit.PickDir, appkit.PickUp:
			style = colDir
		case appkit.PickRecent:
			style = colDim
		case appkit.PickTrash:
			style = colWarn
		}
		lines = append(lines, style+clipVis("  "+r.Label+"  "+pickTag(r), cols)+colReset)
	}

	status := " path: " + p.Input
	if p.Err != "" {
		status = " " + p.Err + "  ·  path: " + p.Input
	}
	lines = append(lines, colStat+clipVis(status, cols)+colReset)
	lines = append(lines, colDim+clipVis(" up/down move · enter pick · backspace up · type a path · esc cancel", cols)+colReset)

	return framePrologue + strings.Join(lines, "\n")
}

// pickTag is the row's muted classifier — the ANSI stand-in for the canvas
// face's mime glyph + detail tag.
func pickTag(r appkit.PickerRow) string {
	switch r.Kind {
	case appkit.PickUp:
		return "up"
	case appkit.PickDir:
		return "dir"
	case appkit.PickRecent:
		return "recent"
	case appkit.PickTrash:
		return "trash · enter restores"
	}
	if s := r.Mime.String(); s != "" {
		return s
	}
	return ""
}
