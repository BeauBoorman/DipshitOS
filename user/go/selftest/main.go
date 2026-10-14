// Command selftest (GOSELF.ELF) — the tabapp shell around the case list in
// selftest.go. It runs full-viewport inside Zig TABWM (the go-edit / go-calc
// seat shape), paints every verdict, writes the share files, and prints the
// serial contract of ADR 0031.
//
// Order is load-bearing: cases -> report files -> paint -> serial summary.
// The host keys off `selftest: FAIL n=` and the files on the share; nothing
// here reports a PASS the syscalls did not return.
package main

import (
	"virelai/draw"
	"virelai/tabapp"
	"virelai/vi"
	"virelai/webrender/font"
	"virelai/widgets"
)

const (
	appName  = "GOSELF.ELF"
	appTitle = "Self-test"
	natW     = 640
	natH     = 400

	markerOpen    = "goself: open id="
	markerDeclare = "goself: declare accepted"
	markerPresent = "goself: present"
	markerOpenErr = "goself: error open "
	markerClose   = "goself: close"
	markerOK      = "goself OK"
	markerCase    = "selftest: case "
	markerReport  = "selftest: report "
	markerSummary = "selftest: summary "
	markerWriteEr = "selftest: write failed "
)

// The frame's palette (same tones as the other Go tabs).
const (
	colBg   = uint32(0x11171c)
	colInk  = uint32(0xe6edf3)
	colDim  = uint32(0x8b949e)
	colPass = uint32(0x3fb950)
	colFail = uint32(0xf85149)
)

// app is the shell state: the tab surface and the verdicts.
type app struct {
	ta *tabapp.TabApp
	rs []result
}

func main() {
	defer func() {
		if recovered := recover(); recovered != nil {
			outcome := "panic"
			switch value := recovered.(type) {
			case string:
				outcome += ": " + value
			case error:
				outcome += ": " + value.Error()
			}
			_ = vi.Log(appName, outcome)
			if rc := vi.WriteCrashReceipt(appName, outcome); rc < 0 {
				vi.ConsoleLine("goself: crash receipt failed rc=" + vi.Itoa64(rc))
			} else {
				vi.ConsoleLine("goself: crash receipt written")
			}
			vi.Exit(2)
		}
	}()
	_ = vi.Log(appName, "started")
	for _, arg := range vi.Args() {
		if arg == "--panic-receipt-fixture" {
			_ = vi.Log(appName, "fixture: before panic")
			panic("M82e fixture panic")
		}
	}
	ta := tabapp.Init(tabapp.Config{
		Name:  appName,
		Title: appTitle,
		X:     32,
		Y:     32,
		W:     natW,
		H:     natH,
	})
	if ta == nil {
		vi.ConsoleLine(markerOpenErr + "-1")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine("goself: declare refused")
	}

	s := guestSyscalls()
	// M61e: hand the window case the surface THIS process actually got. The
	// id comes from tabapp.Init's win_open return; a -1 here (open failed)
	// makes the case fail rather than query window 0.
	s.win.id = ta.Win
	s.win.reqW, s.win.reqH = ta.W, ta.H

	rs := runCases(&s)
	for _, r := range rs {
		// After its syscalls returned, never before: a marker here means
		// the case ran, not that the app thinks it should have.
		vi.ConsoleLine(caseLine(r))
	}

	// Files first, serial second (ADR 0031). A report that cannot be written
	// is a failed run: the host's proof is the file, so the summary must not
	// claim success without it.
	reportOK := true
	if n, err := writeFile(&s, reportPath, renderReport(rs)); err != nil {
		reportOK = false
		vi.ConsoleLine(markerWriteEr + reportPath + " " + err.Error())
	} else {
		vi.ConsoleLine(markerReport + reportPath + " n=" + vi.Itoa64(int64(n)))
	}
	if n, err := writeFile(&s, summaryPath, renderSummary(rs)); err != nil {
		reportOK = false
		vi.ConsoleLine(markerWriteEr + summaryPath + " " + err.Error())
	} else {
		vi.ConsoleLine(markerSummary + summaryPath + " n=" + vi.Itoa64(int64(n)))
	}

	nFailed := failed(rs)
	if !reportOK {
		nFailed++
	}

	a := &app{ta: ta, rs: rs}
	a.draw()
	ta.Present()
	vi.ConsoleLine(markerPresent)

	for _, line := range serialSummary(nFailed) {
		vi.ConsoleLine(line)
	}

	// The report screen stays up (the harness stops the VM on the summary
	// line). WIN_CLOSE exits cleanly at a human keyboard.
	for {
		ev, rc, ok := vi.PollEventRaw()
		if !ok {
			if rc < 0 {
				break
			}
			vi.Sleep(1)
			continue
		}
		switch ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			vi.ConsoleLine(markerClose)
			vi.ConsoleLine(markerOK)
			ta.CloseAndExit(0)
		case tabapp.ActionResized:
			a.draw()
			ta.Present()
		}
	}
}

// draw paints the whole frame: title, one row per case, and the summary line.
func (a *app) draw() {
	cv := a.ta.Canvas()
	w, h := int(a.ta.W), int(a.ta.H)
	if w <= 0 || h <= 0 {
		w, h = natW, natH
	}
	a.fill(cv, 0, 0, w, h, colBg)
	a.text(cv, 16, 16, "GOSELF self-test", colInk)
	a.text(cv, 16, 32, "the guest writes the report; the host reads it", colDim)

	y := 60
	for _, r := range a.rs {
		verdict, rgb := "PASS", colPass
		if !r.ok {
			verdict, rgb = "FAIL", colFail
		}
		line := verdict + "  " + r.id
		if !r.ok && r.detail != "" {
			line += "  " + r.detail
		}
		a.text(cv, 16, y, line, rgb)
		y += 12
	}

	a.text(cv, 16, y+12, summaryLine(a.rs), colInk)
	if len(a.rs) > 0 && failed(a.rs) == 0 {
		a.text(cv, 16, y+28, "selftest OK", colPass)
	}
}

// text paints ASCII with the 8x8 face, coalescing each row's lit run into ONE
// fill (the go-edit text path: the full webrender package drags in layout +
// HTML and the Go runtime's init then exceeds the kernel's sbrk budget).
func (a *app) text(cv widgets.Canvas, x, y int, s string, rgb uint32) {
	cx := x
	for i := 0; i < len(s); i++ {
		g := font.Glyph8(rune(s[i]))
		for row := 0; row < 8; row++ {
			bits := g[row]
			col := 0
			for col < 8 {
				if bits&(1<<uint(col)) == 0 {
					col++
					continue
				}
				run := 1
				for col+run < 8 && bits&(1<<uint(col+run)) != 0 {
					run++
				}
				a.fill(cv, cx+col, y+row, run, 1, rgb)
				col += run
			}
		}
		cx += font.Advance(1)
	}
}

// fill clamps one rectangle into the frame and paints it. Opaque mirrors the
// kernel fill's byte contract (it always wrote X=ff) on the raster path.
func (a *app) fill(cv widgets.Canvas, x, y, w, h int, rgb uint32) {
	if w <= 0 || h <= 0 || x < 0 || y < 0 {
		return
	}
	cv.FillRect(widgets.Rect{X: x, Y: y, W: w, H: h}, draw.Opaque(rgb))
}
