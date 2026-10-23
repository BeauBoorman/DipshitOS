package main

import (
	"strings"

	"virelai/draw"
	"virelai/store"
	"virelai/theme"
	"virelai/widgets"
)

// render.go — the frame. The layout is deliberately text-first: the
// browse list renders one line per catalog row (the same fields `store
// ls` prints), the detail card is `store info`'s fields, and the log
// pane shows the tee'd `store:`/`gostore:` lines — every leg the GUI
// narrates is literally the line STORE would have printed.

const (
	rowH      = 12
	lineH     = 12
	headerH   = 20
	footerH   = 28
	detailMax = 11
	logMax    = 9
	padX      = 8
)

// rowLine renders one catalog row — stream, display name, version,
// category, publisher label/state, installed badge, refusal. Columns are
// fixed-width truncations of the signed fields.
func rowLine(r *store.CatalogRow) string {
	s := r.Stream
	switch r.Status {
	case "release":
		e := r.Entry
		line := pad(s, 8) + " " + pad(e.Rel.Name, 10) + " " + pad(e.Rel.Version, 7) + " " +
			pad(orDash(e.Rel.Category), 6) + " " + pad(orDash(e.PubLabel), 10) + " " + e.PubState
		if e.PubLabel == "" {
			line = pad(s, 8) + " " + pad(e.Rel.Name, 10) + " " + pad(e.Rel.Version, 7) + " " +
				pad(orDash(e.Rel.Category), 6) + " " + pad(short(e.Publisher, 10), 10) + " " + e.PubState
		}
		if r.Installed {
			line += " [installed]"
		}
		return line
	case "catalog-invalid":
		return pad(s, 8) + " catalog-invalid " + r.Refusal
	default:
		return pad(s, 8) + " " + r.Status
	}
}

func pad(s string, w int) string {
	if len(s) > w {
		return s[:w]
	}
	return s + strings.Repeat(" ", w-len(s))
}

func short(s string, w int) string {
	if len(s) > w {
		return s[:w]
	}
	return s
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// detailLines renders the selected row's card — the same field set
// `store info` prints.
func detailLines(r *store.CatalogRow) []string {
	if r.Status != "release" {
		line := "stream " + r.Stream + "  " + r.Status
		if r.Refusal != "" {
			line += " " + r.Refusal
		}
		return []string{line}
	}
	e := r.Entry
	lines := []string{
		"stream " + e.Stream + "  head " + orDash(e.Head),
		"name " + e.Rel.Name + "  version " + e.Rel.Version + "  category " + orDash(e.Rel.Category),
		"summary " + orDash(e.Rel.Summary),
		"sha256 " + e.Rel.ELFSHA256,
		"icon_sha256 " + orDash(e.Rel.IconSHA256),
		"publisher " + e.Publisher,
		"publisher_name=" + orDash(e.PubLabel) + " publisher_state=" + e.PubState,
	}
	if r.Installed {
		lines = append(lines, "installed yes")
	} else {
		lines = append(lines, "installed no")
	}
	lines = append(lines, "row "+e.Rel.ManifestRow)
	if e.Rel.Description == "" {
		lines = append(lines, "description -")
	} else {
		lines = append(lines, "description")
		for _, l := range strings.Split(e.Rel.Description, "\n") {
			lines = append(lines, "  "+l)
		}
	}
	return lines
}

// draw paints the frame onto the tab canvas.
func (a *app) draw() {
	c := a.ta.Canvas()
	w, h := int(a.ta.W), int(a.ta.H)
	th := theme.Current
	c.FillRect(widgets.Rect{W: w, H: h}, draw.Opaque(th.Bg))
	text := func(x, y int, s string, fg uint32) {
		(&widgets.Text{R: widgets.Rect{X: x, Y: y, W: w - x - padX, H: lineH},
			Label: s, Fg: fg, Bg: th.Bg}).Draw(c)
	}

	// Header: title + the live search line.
	head := "Store"
	if a.search != "" {
		head += "  search=" + a.search
	}
	if a.inputOn {
		head = "Store  /" + a.input + "_"
	}
	if a.busy {
		head += "  …"
	}
	text(padX, 4, head, th.Text)
	c.FillRect(widgets.Rect{X: 0, Y: headerH, W: w, H: 1}, draw.Opaque(th.ChromeBg))

	// The catalog list.
	listTop := headerH + 4
	listH := logMax*0 + 9*rowH
	rows := a.rows
	scroll := 0
	if a.sel >= 9 && len(rows) > 9 {
		scroll = a.sel - 8
	}
	for i := 0; i < 9 && i+scroll < len(rows); i++ {
		idx := i + scroll
		fg := th.Text
		bg := th.Bg
		if idx == a.sel {
			bg = th.Selection
		}
		line := rowLine(&rows[idx])
		if idx == a.sel {
			line = "> " + line
		} else {
			line = "  " + line
		}
		(&widgets.Text{R: widgets.Rect{X: padX, Y: listTop + i*rowH, W: w - 2*padX, H: rowH},
			Label: line, Fg: fg, Bg: bg}).Draw(c)
	}
	y := listTop + listH

	// The detail card (when open).
	if a.detail {
		if r := a.selRow(); r != nil {
			y += 2
			c.FillRect(widgets.Rect{X: 0, Y: y, W: w, H: 1}, draw.Opaque(th.ChromeBg))
			y += 4
			for i, l := range detailLines(r) {
				if i >= detailMax {
					break
				}
				text(padX, y, l, th.Text)
				y += lineH
			}
		}
	}

	// The log pane: the tee'd store/gostore lines, newest last.
	logTop := h - footerH - logMax*lineH - 4
	c.FillRect(widgets.Rect{X: 0, Y: logTop - 2, W: w, H: 1}, draw.Opaque(th.ChromeBg))
	start := 0
	if len(a.log) > logMax {
		start = len(a.log) - logMax
	}
	for i := 0; i < logMax && start+i < len(a.log); i++ {
		text(padX, logTop+i*lineH, a.log[start+i], th.Muted)
	}

	// Footer: key hints + status. A standing consent prompt takes the
	// hint line — the ask is modal (M116c).
	c.FillRect(widgets.Rect{X: 0, Y: h - footerH, W: w, H: 1}, draw.Opaque(th.ChromeBg))
	if a.pending != nil {
		text(padX, h-footerH+4, a.pending.bin+" requests "+a.pending.words, th.Accent)
		text(padX, h-footerH+16, "[g]rant consent — writes the grant row   [d]eny — keeps the ambient floor", th.Muted)
		return
	}
	text(padX, h-footerH+4, "[l]ist [/]search [enter]detail [i]nstall [u]pdate [r]ollback [p]in [d]elete [q]uit", th.Muted)
	if a.status != "" {
		text(padX, h-footerH+16, a.status, th.Accent)
	}
}
