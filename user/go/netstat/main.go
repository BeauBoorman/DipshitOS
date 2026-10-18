// Command netstat is GONETSTAT.ELF, the M78a Go replacement for NETSTAT.BIN.
// It reads the frozen slot-62 snapshot and paints it into an ordinary guest
// window. The syscall and rendering paths are entirely guest-native: no host
// terminal, libc, or POSIX compatibility layer.
package main

import (
	"virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/vsys"
	"virelai/widgets"
)

const (
	winX         = 40
	winY         = 40
	winW         = 512
	winH         = 512
	exitStatus   = 44
	refreshTicks = 4 // ~1 Hz at the Zig app's 250 ms scheduler quantum
)

// canvas carries the frame surface (the window's bound pages through
// tabapp.Attach, or the FillerCanvas degrade) plus the socket-table diff
// state — the serial log of table changes headless runs assert.
type canvas struct {
	cv       widgets.Canvas
	lastSock []vi.SocketRow // last table paint, for the serial diff log
}

func ipString(ip [4]byte) string { return vi.FormatIPv4(ip) }

func macString(mac [6]byte) string {
	const hex = "0123456789abcdef"
	b := make([]byte, 17)
	for i, v := range mac {
		if i != 0 {
			b[i*3-1] = ':'
		}
		b[i*3] = hex[v>>4]
		b[i*3+1] = hex[v&15]
	}
	return string(b)
}

func dhcpName(state byte) string {
	switch state {
	case 1:
		return "selecting"
	case 2:
		return "requesting"
	case 3:
		return "bound"
	case 4:
		return "renewing"
	case 5:
		return "rebinding"
	default:
		return "idle"
	}
}

func tcpName(state byte) string {
	switch state {
	case 1:
		return "SYN-SENT"
	case 2:
		return "ESTABLISHED"
	case 3:
		return "FIN-WAIT"
	case 4:
		return "CLOSED"
	default:
		return "IDLE"
	}
}

// sockStateName names a socket-table row's core state (M99g #2185): the
// op-12 snapshot's connection lifecycle, not the singleton TCP machine's.
func sockStateName(state byte) string {
	switch state {
	case 0:
		return "syn-sent"
	case 1:
		return "established"
	case 2:
		return "closing"
	case 3:
		return "terminal"
	default:
		return "?"
	}
}

// socketRowLine renders one live table socket: "pid=7 listen 10.0.0.1:2222"
// or "pid=7 tcp 10.0.0.1:2222 -> 10.0.0.2:12345 established".
func socketRowLine(r vi.SocketRow) string {
	owner := "pid=" + vi.Itoa64(int64(r.Owner))
	if r.Kind == 0 {
		return owner + " listen " + ipString(r.LocalIP) + ":" + vi.Itoa64(int64(r.LocalPort))
	}
	return owner + " tcp " + ipString(r.LocalIP) + ":" + vi.Itoa64(int64(r.LocalPort)) +
		" -> " + ipString(r.RemoteIP) + ":" + vi.Itoa64(int64(r.RemotePort)) +
		" " + sockStateName(r.State)
}

func socketRowsEqual(a, b []vi.SocketRow) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// sockDiff console-logs the socket-table rows whenever the snapshot
// changes — the same rows the window paints, so headless runs can assert
// the table view. Returns the current rows for the painter.
func sockDiff(last *[]vi.SocketRow) []vi.SocketRow {
	rows := vi.SocketTable()
	if !socketRowsEqual(*last, rows) {
		for _, r := range rows {
			vi.ConsoleLine("netstat: sock " + socketRowLine(r))
		}
		*last = append((*last)[:0], rows...)
	}
	return rows
}

func drawLine(c *canvas, y int, label, value string, color uint32) {
	t := theme.Current
	left := widgets.Text{
		R:     widgets.Rect{X: 12, Y: y, W: 108, H: 14},
		Label: label,
		Fg:    t.Muted,
		Bg:    t.Bg,
	}
	left.Draw(c.cv)
	right := widgets.Text{
		R:     widgets.Rect{X: 128, Y: y, W: 372, H: 14},
		Label: value,
		Fg:    color,
		Bg:    t.Bg,
	}
	right.Draw(c.cv)
}

func drawSection(c *canvas, y int, name string) int {
	section := widgets.Text{
		R:     widgets.Rect{X: 12, Y: y, W: 488, H: 16},
		Label: name,
		Fg:    theme.Current.Accent,
		Bg:    theme.Current.Bg,
	}
	section.Draw(c.cv)
	return y + 15
}

func drawSnapshot(c *canvas, s vi.NetStats) {
	t := theme.Current
	c.cv.FillRect(widgets.Rect{W: winW, H: winH}, draw.Opaque(t.Bg))
	title := widgets.Text{
		R:     widgets.Rect{X: 12, Y: 8, W: 488, H: 20},
		Label: "GONETSTAT.ELF - network dashboard",
		Fg:    t.Accent,
		Bg:    t.Bg,
	}
	title.Draw(c.cv)

	y := drawSection(c, 30, "Interface")
	drawLine(c, y, "MAC", macString(s.MAC), t.Text)
	y += 14
	drawLine(c, y, "IP", ipString(s.OwnIP), t.Text)
	y += 14
	drawLine(c, y, "GW", ipString(s.Gateway), t.Text)
	y += 17

	y = drawSection(c, y, "DHCP")
	drawLine(c, y, "State", dhcpName(s.DHCPState)+" ("+vi.Itoa64(int64(s.LeaseSecs))+" s lease)", t.Text)
	y += 14
	drawLine(c, y, "Lease IP", ipString(s.LeaseIP), t.Text)
	y += 17

	y = drawSection(c, y, "TCP")
	drawLine(c, y, "Peer", ipString(s.TCPPeerIP)+":"+vi.Itoa64(int64(s.TCPPeerPort))+" ("+tcpName(s.TCPState)+")", t.Text)
	y += 17

	// M99g (#2185): the live socket table — every listener and connection
	// with its owner pid, from the slot-80 op-12 snapshot. Console-log the
	// diff so headless runs can assert the same rows the window paints.
	y = drawSection(c, y, "Sockets")
	rows := sockDiff(&c.lastSock)
	if len(rows) == 0 {
		drawLine(c, y, "Table", "(empty)", t.Text)
		y += 14
	} else {
		for _, r := range rows {
			if y > winH-32 {
				break
			}
			drawLine(c, y, "sock", socketRowLine(r), t.Text)
			y += 14
		}
	}
	y += 3

	y = drawSection(c, y, "UDP listeners")
	ports := "none"
	if s.UDPCount > 0 {
		ports = ""
		count := int(s.UDPCount)
		if count > len(s.UDPPorts) {
			count = len(s.UDPPorts)
		}
		for i := 0; i < count; i++ {
			if i > 0 {
				ports += " "
			}
			ports += vi.Itoa64(int64(s.UDPPorts[i]))
		}
	}
	drawLine(c, y, "Ports", ports, t.Text)
	y += 17

	y = drawSection(c, y, "ARP")
	if s.ARPCount == 0 {
		drawLine(c, y, "Table", "(empty)", t.Text)
		y += 14
	} else {
		count := int(s.ARPCount)
		if count > len(s.ARPIPs) {
			count = len(s.ARPIPs)
		}
		for i := 0; i < count && y < winH-32; i++ {
			drawLine(c, y, "ARP", ipString(s.ARPIPs[i])+" -> "+macString(s.ARPMACs[i]), t.Text)
			y += 14
		}
	}
	y += 3

	_ = drawSection(c, y, "Counters")
	y += 15
	drawLine(c, y, "TX", vi.Itoa64(int64(s.TXFrames))+" frames / "+vi.Itoa64(int64(s.TXBytes))+" B", t.Text)
	y += 14
	drawLine(c, y, "RX", vi.Itoa64(int64(s.RXFrames))+" frames / "+vi.Itoa64(int64(s.RXBytes))+" B ("+vi.Itoa64(int64(s.RXOverflow))+" dropped)", t.Text)
}

func main() {
	win, rc := vi.WinOpen(winX, winY, winW, winH)
	if rc < 0 {
		headlessMain()
		return
	}
	vi.ConsoleLine("netstat: open id=" + vi.Itoa64(int64(win)))
	// No tab declaration — the M78a shape stands — but the paint path is the
	// same bound-surface canvas every migrated app uses.
	ta := tabapp.Attach(win, "GONETSTAT.ELF", winW, winH)

	snap, ok := vi.NetStatsSnapshot()
	if !ok {
		snap = vi.NetStats{}
	}
	for _, section := range []string{"iface", "dhcp", "tcp", "sockets", "udp", "arp", "counters"} {
		vi.ConsoleLine("netstat: section " + section)
	}
	c := &canvas{cv: ta.Canvas()}
	drawSnapshot(c, snap)
	ta.Present()
	vi.ConsoleLine("netstat: ready")
	if vsys.TimerSet(refreshTicks) < 0 {
		ta.Close()
		vi.Exit(1)
	}

	closed := false
	for !closed {
		ev, result, ok := vi.PollEventRaw()
		if !ok {
			if result < 0 {
				vsys.TimerCancel()
				ta.Close()
				vi.Exit(1)
			}
			vi.Sleep(1)
			continue
		}
		switch ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			closed = true
		case tabapp.ActionResized:
			// The canvas view re-strides inside Dispatch; repaint the native
			// layout onto it.
			c.cv = ta.Canvas()
			drawSnapshot(c, snap)
			ta.Present()
		case tabapp.ActionNone:
			if ev.Kind == vi.EvTimer {
				if next, valid := vi.NetStatsSnapshot(); valid {
					snap = next
				}
				drawSnapshot(c, snap)
				ta.Present()
				if vsys.TimerSet(refreshTicks) < 0 {
					vsys.TimerCancel()
					ta.Close()
					vi.Exit(1)
				}
			}
		}
	}
	vsys.TimerCancel()
	ta.Close()
	vi.Exit(exitStatus)
}

// headlessMain is the no-compositor path: a class-B run booted without
// the window server still gets the dashboard's report — the section
// markers, the ready marker, and the same refresh loop's sock diff-log —
// just no window. The kernel table is as readable here as it is painted.
func headlessMain() {
	vi.ConsoleLine("netstat: headless")
	for _, section := range []string{"iface", "dhcp", "tcp", "sockets", "udp", "arp", "counters"} {
		vi.ConsoleLine("netstat: section " + section)
	}
	var last []vi.SocketRow
	_ = sockDiff(&last)
	vi.ConsoleLine("netstat: ready")
	// Sleep-tick the same ~1 Hz cadence — no window event loop exists to
	// carry timer events here.
	for {
		vi.Sleep(refreshTicks)
		_ = sockDiff(&last)
	}
}
