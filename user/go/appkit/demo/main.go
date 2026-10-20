// Command demo is the appkit showcase. It opens on the M86 prompt dialog —
// the chrome the wnd4 live gate probes — over the M137b (#2772) controls: a
// MenuBar across the top, a Tree with lazy branches, and a virtualized
// Table, all keyboard-drivable so M137d can boot it and drive the menu bar
// and table with keys alone. File>Open re-arms the dialog; File>Quit exits.
package main

import (
	"virelai/appkit"
	"virelai/draw"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// Leave the kernel's argv/envp tail out of the runtime's first sbrk page.
var argvHeadroom [0x1000]byte

// num formats a small non-negative integer without strconv — the demo shares
// the app footprint budget.
func num(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [12]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

func main() {
	const w, h = 512, 448
	id, rc := vi.WinOpen(56, 56, w, h)
	if rc < 0 {
		vi.ConsoleLine("godialog: open failed")
		vi.Exit(1)
	}
	c, err := draw.WindowCanvas(id, w, h)
	if err != nil {
		vi.ConsoleLine("godialog: surface failed")
		vi.WinClose(id)
		vi.Exit(2)
	}
	// A tab attachment keeps the requested native geometry: the window's
	// bound surface must not be resized independently of its mapped bytes.
	_ = vi.WmMailRequest(vi.WmRpcKindAttachTab, uint32(id), 0, 0, 0, 0, "Dialog", "GODIALOG.ELF")
	d := appkit.NewPrompt("Open file", "Enter a path to open")
	d.Input = "notes.txt"
	ui, err := draw.ReadFont("/host/INTER.TTF", 500000)
	if err != nil {
		vi.ConsoleLine("godialog: fonts missing")
		vi.WinClose(id)
		vi.Exit(3)
	}
	icon, err := draw.ReadFont("/host/CHROME.TTF", 8192)
	if err != nil {
		vi.ConsoleLine("godialog: fonts missing")
		vi.WinClose(id)
		vi.Exit(3)
	}
	d.UIFace, d.IconFace = ui, icon

	// The M137b controls. The strip between the bar and the dialog zone
	// stays background so the wnd4 chrome probes keep seeing untouched
	// pixels; the controls live under the dialog's span and are reached by
	// dismissing the dialog or starting on the menu bar.
	tree := &widgets.Tree{
		R:  widgets.Rect{X: 8, Y: 236, W: 184, H: 204},
		Fg: theme.Current.Text, Bg: theme.Current.Surface,
		Face: ui, IconFace: icon,
	}
	lazyServices := func(*appkit.TreeNode) []*appkit.TreeNode {
		return []*appkit.TreeNode{{Label: "net"}, {Label: "wm"}, {Label: "snd"}}
	}
	lazyDocs := func(*appkit.TreeNode) []*appkit.TreeNode {
		return []*appkit.TreeNode{{Label: "spec"}, {Label: "notes"}}
	}
	treeCtl := appkit.NewTreeController(tree, []*appkit.TreeNode{
		{Label: "system", Expanded: true, Kids: []*appkit.TreeNode{
			{Label: "kernel"},
			{Label: "services", Lazy: true, Load: lazyServices},
		}},
		{Label: "apps", Kids: []*appkit.TreeNode{
			{Label: "gosheet"}, {Label: "goreader"},
		}},
		{Label: "docs", Lazy: true, Load: lazyDocs},
	})

	table := &widgets.Table{
		R: widgets.Rect{X: 200, Y: 236, W: 304, H: 204},
		Cols: []widgets.TableColumn{
			{Title: "Name", W: 96}, {Title: "Kind", W: 56},
			{Title: "Size", W: 64}, {Title: "State", W: 80},
		},
		Rows: 64,
		Row:  0, Col: 0,
		Face: ui, Fg: theme.Current.Text, Bg: theme.Current.Surface,
	}
	names := []string{"kernel", "vm", "net", "fs", "gpu", "hid", "snd", "wm"}
	kinds := []string{"sys", "app"}
	states := []string{"idle", "busy", "ready"}
	table.Cell = func(r, col int) string {
		switch col {
		case 0:
			return names[r%len(names)] + "-" + num(r)
		case 1:
			return kinds[r%len(kinds)]
		case 2:
			return num(4+r*13%2040) + " K"
		default:
			return states[r%len(states)]
		}
	}
	tableCtl := appkit.NewTableController(table)
	tableCtl.OnActivate = func(r, col int) bool { return true }

	ring := appkit.NewFocusRing(treeCtl, tableCtl)
	ring.Focus(0)

	// The menu bar owns the top strip. Item actions call back through this
	// same loop — firing returns dirty and the next iteration repaints.
	running := true
	bar := &appkit.MenuBar{
		R:      widgets.Rect{X: 0, Y: 0, W: w, H: 24},
		UIFace: ui,
		Menus: []appkit.Menu{
			{Title: "&File", Items: []appkit.MenuItem{
				{Label: "&Open…", Action: func() bool {
					d.Open = true
					return true
				}},
				{Label: "&Quit", Shortcut: "Ctrl+Q", Action: func() bool {
					running = false
					return true
				}},
			}},
			{Title: "&Edit", Items: []appkit.MenuItem{
				{Label: "&Copy", Disabled: true},
				{Label: "&Paste", Disabled: true},
			}},
			{Title: "&View", Items: []appkit.MenuItem{
				{Label: "&Expand All", Action: func() bool { return treeCtl.ExpandAll() }},
				{Label: "&Collapse All", Action: func() bool { return treeCtl.CollapseAll() }},
			}},
		},
	}

	painted := false
	for running {
		draw.FillRect(c, widgets.Rect{W: w, H: h}, draw.Opaque(theme.Current.Bg))
		treeCtl.Draw(c)
		tableCtl.Draw(c)
		if d.Open {
			d.Draw(c)
		}
		bar.Draw(c)
		if vi.WinPresent(id) < 0 {
			vi.ConsoleLine("godialog: present failed")
			vi.WinClose(id)
			vi.Exit(4)
		}
		if !painted {
			vi.ConsoleLine("godialog: painted")
			painted = true
		}
		ev, ok := vi.PollEvent()
		if !ok {
			vi.Sleep(1)
			continue
		}
		switch ev.Kind {
		case vi.EvWinClose:
			running = false
		case vi.EvKeyDown:
			if d.Open {
				d.HandleKey(ev)
				continue
			}
			k, ok := appkit.NormalizeKey(ev)
			if !ok {
				continue
			}
			if k.Ctrl && k.Usage == 0x14 { // HID 'q' — NormalizeKey drops Rune under Ctrl
				running = false
				continue
			}
			if bar.OnKey(k) {
				continue
			}
			ring.HandleKey(k)
		case vi.EvMouseDown:
			x, y := int(ev.Arg0), int(ev.Arg1)
			if d.Open {
				d.HandleMouse(x, y, true)
				continue
			}
			if bar.OnClick(x, y) {
				continue
			}
			ring.HandleClick(x, y)
		}
	}
	vi.WinClose(id)
	vi.ConsoleLine("godialog: done")
}
