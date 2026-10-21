//go:build virelai || pulse

package main

import (
	"strings"

	tea "charm.land/bubbletea/v2"
	lipgloss "charm.land/lipgloss/v2"
)

// The grid the layout targets. The window grid is u8 (<=255 cells); 80
// columns is the classic seat-app width and every line is clamped to it.
const viewWidth = 80

var (
	styleTitle   = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("5"))
	styleTabOn   = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("15")).Background(lipgloss.Color("5")).Padding(0, 1)
	styleTabOff  = lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Padding(0, 1)
	styleHead    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	styleRun     = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("2"))
	styleCreated = lipgloss.NewStyle().Foreground(lipgloss.Color("4"))
	styleExited  = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	styleSel     = lipgloss.NewStyle().Foreground(lipgloss.Color("15")).Background(lipgloss.Color("5"))
	styleNotice  = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	styleDim     = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	styleDialog  = lipgloss.NewStyle().Border(lipgloss.NormalBorder()).BorderForeground(lipgloss.Color("1")).Padding(1, 3)
	styleHelpBox = lipgloss.NewStyle().Border(lipgloss.NormalBorder()).BorderForeground(lipgloss.Color("5")).Padding(1, 3)
)

func (m model) View() tea.View {
	var b strings.Builder
	b.WriteString("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H")
	for _, ln := range m.renderLines() {
		b.WriteString(clampVis(ln, viewWidth) + "\n")
	}
	return tea.NewView(b.String())
}

// clampVis truncates a (possibly ANSI-styled) line to w visible cells.
func clampVis(s string, w int) string {
	if lipgloss.Width(s) <= w {
		return s
	}
	// Fast ASCII path: styled runs are short, so walk runes and stop the
	// visible count at w, keeping any open ANSI prefix. Names and table
	// text are ASCII; ANSI escapes carry no visible width.
	var out strings.Builder
	vis := 0
	inEsc := false
	for _, r := range s {
		if inEsc {
			out.WriteRune(r)
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
				inEsc = false
			}
			continue
		}
		if r == 0x1b {
			inEsc = true
			out.WriteRune(r)
			continue
		}
		if vis >= w {
			break
		}
		out.WriteRune(r)
		vis++
	}
	out.WriteString("\x1b[0m")
	return out.String()
}

func (m model) renderLines() []string {
	var lines []string
	lines = append(lines, styleTitle.Render("  PULSE.ELF")+styleDim.Render(" · system monitor"))
	lines = append(lines, m.tabBar())
	lines = append(lines, strings.Repeat("-", viewWidth))
	if m.help {
		lines = append(lines, m.helpLines()...)
	} else {
		lines = append(lines, m.bodyLines()...)
	}
	lines = append(lines, strings.Repeat("-", viewWidth))
	lines = append(lines, styleDim.Render(" 1-4 tabs · j/k move · / filter · s sort · x kill · r refresh · ? help · q quit"))
	if m.notice != "" {
		lines = append(lines, styleNotice.Render(" "+m.notice))
	}
	return lines
}

func (m model) tabBar() string {
	var parts []string
	for t := tab(0); t < tabCount; t++ {
		label := " " + itoa64(uint64(t)+1) + ":" + t.name() + " "
		if t == m.tab {
			parts = append(parts, styleTabOn.Render(label))
		} else {
			parts = append(parts, styleTabOff.Render(label))
		}
	}
	return " " + strings.Join(parts, " ")
}

func (m model) bodyLines() []string {
	switch m.tab {
	case tabProcs:
		return m.procsLines()
	case tabNet:
		return m.netLines()
	case tabStorage:
		return m.storageLines()
	default:
		return m.overviewLines()
	}
}

func (m model) overviewLines() []string {
	running, created, exited := countStates(m.snap)
	lines := []string{
		"",
		"  uptime      " + styleHead.Render(formatUptime(m.snap.uptimeNs)),
		"  processes   " + styleRun.Render(itoa64(uint64(running))+" running") +
			styleDim.Render(" · ") + styleCreated.Render(itoa64(uint64(created))+" created") +
			styleDim.Render(" · ") + styleExited.Render(itoa64(uint64(exited))+" exited"),
		"  ticks       " + itoa64(m.ticks),
		"",
	}
	if m.usage.ok {
		// Real figures (ADR 0047): the machine busy share is Σ per-process
		// tick deltas over Σ core ticks; the memory bar is summed owned
		// footprint over the allocator pool.
		var memX10 uint64
		if m.usage.memTotal > 0 {
			memX10 = m.usage.memUsed * 1000 / m.usage.memTotal
		}
		lines = append(lines,
			"  cpu         "+usageBar(m.usage.cpuX10, 20)+" "+pctX10(m.usage.cpuX10),
			"  mem         "+usageBar(memX10, 20)+" "+formatBytes(int64(m.usage.memUsed))+
				styleDim.Render("/"+formatBytes(int64(m.usage.memTotal))),
		)
		return lines
	}
	return append(lines,
		styleDim.Render("  per-process memory and CPU% are not exposed by sys_procs (slot 7):"),
		styleDim.Render("  its rows carry pid, state and name only (ADR 0007)."),
	)
}

// usageBar renders a width-w share bar from a tenths-of-a-percent figure.
func usageBar(x10, w uint64) string {
	fill := x10 * w / 1000
	if fill > w {
		fill = w
	}
	return "[" + strings.Repeat("#", int(fill)) + strings.Repeat("-", int(w-fill)) + "]"
}

// pctX10 renders tenths of a percent ("250" -> "25.0%").
func pctX10(x10 uint64) string {
	if x10 > 9999 {
		x10 = 9999
	}
	return itoa64(x10/10) + "." + itoa64(x10%10) + "%"
}

func stateStyle(s uint64) lipgloss.Style {
	switch s {
	case 2:
		return styleRun
	case 1:
		return styleCreated
	case 3:
		return styleExited
	}
	return styleDim
}

func (m model) procsLines() []string {
	rows := visibleProcs(m.snap, m.sortCol, m.filter)
	var lines []string
	head := "  " + padRight("PID", 8) + padRight("NAME", 18) + padRight("STATE", 8)
	if m.usage.ok {
		head += padRight("CPU%", 8) + "MEM"
	} else {
		head = "  " + padRight("PID", 8) + padRight("NAME", 18) + "STATE"
	}
	head = markSortCol(head, m.sortCol)
	lines = append(lines, styleHead.Render(head))
	maxRows := 14
	for i, p := range rows {
		if i >= maxRows {
			break
		}
		marker := "  "
		if i == m.sel {
			marker = "> "
		}
		line := marker + padRight(itoa64(p.pid), 8) + padRight(p.name, 18)
		if m.usage.ok {
			cpu, mem := "-", "-"
			if u, found := m.usage.perProc[p.pid]; found {
				cpu, mem = pctX10(u.cpuX10), formatBytes(int64(u.memBytes))
			}
			line += padRight(stateName(p.state), 8) + padRight(cpu, 8) + mem
		} else {
			line += stateName(p.state)
		}
		if i == m.sel {
			line = styleSel.Render(line)
		} else {
			line = stateStyle(p.state).Render(line)
		}
		lines = append(lines, line)
	}
	if len(rows) > maxRows {
		lines = append(lines, styleDim.Render("  … "+itoa64(uint64(len(rows)-maxRows))+" more"))
	}
	if len(rows) == 0 {
		lines = append(lines, styleDim.Render("  (no processes match)"))
	}
	lines = append(lines, "")
	filt := m.filter
	if m.filtering {
		filt += "_"
	}
	lines = append(lines, styleDim.Render("  sort: "+m.sortCol.name()+"   filter: \""+filt+"\""))
	if m.confirm && m.sel >= 0 && m.sel < len(rows) {
		p := rows[m.sel]
		dlg := styleDialog.Render(
			"kill pid=" + itoa64(p.pid) + " (" + p.name + ")?\n\n" +
				"  [y]es      [n]o",
		)
		lines = append(lines, "")
		for _, dl := range strings.Split(dlg, "\n") {
			lines = append(lines, "  "+dl)
		}
	}
	return lines
}

// markSortCol appends a marker to the sorted column's header label.
func markSortCol(head string, col sortCol) string {
	marks := map[sortCol]string{sortPID: "PID*", sortName: "NAME*", sortState: "STATE*"}
	for c, mk := range marks {
		if c == col {
			head = strings.Replace(head, strings.TrimSuffix(mk, "*"), mk, 1)
		}
	}
	return head
}

func (m model) netLines() []string {
	state := "idle"
	st := styleDim
	if m.snap.tcpOpen {
		state = "open (one live socket)"
		st = styleRun
	}
	return []string{
		"",
		"  seat TCP socket:  " + st.Render(state),
		"",
		styleDim.Render("  the ABI exposes no interface counters to EL0: this tab reports"),
		styleDim.Render("  only this process's own socket state (slots 30-33, one per process)."),
	}
}

func (m model) storageLines() []string {
	return []string{
		"",
		"  DATA volume:  " + styleHead.Render(formatBytes(m.snap.dataFree)) + styleDim.Render(" free"),
		"  ESP volume:   " + styleHead.Render(formatBytes(m.snap.espFree)) + styleDim.Render(" free"),
		"",
		styleDim.Render("  totals are not exposed by sys_file_free (slot 37):"),
		styleDim.Render("  it reports free bytes only (ADR 0007)."),
	}
}

func (m model) helpLines() []string {
	body := strings.Join([]string{
		"1-4      switch tab",
		"j / k    move selection (processes)",
		"s        cycle sort column: pid > name > state",
		"/        filter by name (enter/esc done, backspace erases)",
		"x then y kill the selected process (asks first)",
		"r        refresh now (the timer already polls at 1 Hz)",
		"?        this help",
		"q        quit",
		"",
		"kill arms the target for termination via sys_kill (slot 29);",
		"the kernel runs it through the exit path as status 137.",
		"cross-principal kills need cap_proc_admin and are refused",
		"without it — the refusal is shown, not hidden.",
	}, "\n")
	var lines []string
	lines = append(lines, "")
	for _, dl := range strings.Split(styleHelpBox.Render(body), "\n") {
		lines = append(lines, "  "+dl)
	}
	return lines
}

func padRight(s string, w int) string {
	if len(s) >= w {
		return s[:w]
	}
	return s + strings.Repeat(" ", w-len(s))
}
