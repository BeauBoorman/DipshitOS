// Command fetch is the Go HTTP consumer. M67b (issue #1447) added the
// windowed HTTPS mode: GET https:// in-process via virelai/tls over vi.Dial
// (ADR 0029). M78b (issue #1683) added the headless cleartext mode that
// succeeded the retired Zig FETCH.BIN/DOWNLOAD.BIN (legacy.go):
//
//	exec GOFETCH.ELF https://10.0.0.2:24533/ [sni [expect-fail]]  (windowed TLS)
//	exec GOFETCH.ELF http://10.0.0.2/                           (console fetch, exit 42)
//	exec GOFETCH.ELF --download [http://10.0.0.2/file.bin [DEST]] (save body, exit 0)
//
// expect-fail is name|expired|chain: the handshake must fail closed (the
// live-tls13-equivalent negatives). An https URL is never rewritten to
// http and never armed as a cleartext GET; an explicit http:// URL is the
// only path onto the cleartext socket.
package main

import (
	"virelai/draw"
	"virelai/tabapp"
	"virelai/tls"
	"virelai/vi"
	"virelai/widgets"
)

const (
	appName  = "GOFETCH.ELF"
	appTitle = "Fetch"
	natW     = 512
	natH     = 384

	markerOpen       = "gofetch: open id="
	markerDeclare    = "gofetch: declare accepted"
	markerURL        = "gofetch: url "
	markerDial       = "gofetch: dial "
	markerHandshake  = "gofetch: handshake ok"
	markerHSErr      = "gofetch: handshake error "
	markerFailClosed = "gofetch: fail-closed "
	markerSent       = "gofetch: request sent"
	markerBody       = "gofetch: body complete"
	markerPresent    = "gofetch: present"
	markerReady      = "gofetch: ready"
	markerClose      = "gofetch: close"
	markerOK         = "gofetch OK"
	markerError      = "gofetch: error "

	keyEscape = 0x29
	keyQ      = 0x14
)

// argvPad keeps the Go sbrk heap from overlapping the kernel's argv+envp
// block. sys_exec packs 256+2048 bytes after BSS on an extra mapped page;
// if that tail spills past memRound(end), the runtime's first sys_mmap is
// a collision and dies with "fatal error: runtime: cannot allocate memory"
// before main (observed live-web boot 12, memsz remainder 0x850, tail
// 1968 < 2304). WEB.ELF lucks into a larger last-page tail. Kernel
// untouched — this pad is the app-side fix.
var argvPad [2048]byte

type app struct {
	ta     *tabapp.TabApp
	url    string
	sni    string
	expect string
	status string
	title  widgets.Text
	body   widgets.Text
	stat   widgets.Text
}

func main() {
	argvPad[0] = 1
	// M78b: an explicit http:// URL (or --download) is the headless legacy
	// path and never opens a window; everything else (including no args)
	// is the windowed HTTPS consumer.
	if _, legacy := parseLegacyArgs(vi.Args()); legacy {
		runLegacyCLI(vi.Args())
	}
	ta := tabapp.Init(tabapp.Config{Name: appName, Title: appTitle, X: 40, Y: 28, W: natW, H: natH})
	if ta == nil {
		vi.ConsoleLine("gofetch: error open -1")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine("gofetch: declare refused")
	}

	url, sni, expect := startArgs()
	a := &app{ta: ta, url: url, sni: sni, expect: expect, status: "starting"}
	vi.ConsoleLine(markerURL + a.url)
	a.draw()
	a.ta.Present()
	vi.ConsoleLine(markerPresent)
	a.runFetch()
	a.draw()
	a.ta.Present()
	vi.ConsoleLine(markerReady)

	for {
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				break
			}
			vi.Sleep(1)
			continue
		}
		switch a.ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			vi.ConsoleLine(markerClose)
			vi.ConsoleLine(markerOK)
			a.ta.CloseAndExit(0)
		case tabapp.ActionResized:
			a.draw()
			a.ta.Present()
		case tabapp.ActionNone:
			if a.handle(ev) {
				a.draw()
				a.ta.Present()
			}
		}
	}
}

func startArgs() (url, sni, expect string) {
	args := vi.Args()
	url = "https://10.0.0.2/"
	if len(args) > 1 && args[1] != "" {
		url = args[1]
	}
	if len(args) > 2 {
		sni = args[2]
	}
	if len(args) > 3 {
		expect = args[3]
	}
	return url, sni, expect
}

func (a *app) runFetch() {
	tgt := Classify(a.url)
	if WouldSendCleartext(tgt) {
		a.fail(KindHTTP, "cleartext refused")
		return
	}
	plan, ok := PlanDial(tgt)
	if !ok {
		a.fail(tgt.Kind, a.url)
		return
	}
	if a.sni != "" {
		plan.SNI = a.sni
	}
	vi.ConsoleLine(markerDial + plan.Addr + " " + portString(plan.Port) + " " + plan.SNI)
	conn, err := httpsDial(plan.Addr, plan.Port, plan.SNI)
	if err != nil {
		vi.ConsoleLine(markerHSErr + err.Error())
		if failClosedMatches(a.expect, err) {
			vi.ConsoleLine(markerFailClosed + a.expect)
			a.status = "fail-closed " + a.expect
			return
		}
		a.fail("tls", err.Error())
		return
	}
	if a.expect == "name" || a.expect == "expired" || a.expect == "chain" {
		_ = conn.Close()
		a.fail("tls", "expected fail-closed "+a.expect)
		return
	}
	vi.ConsoleLine(markerHandshake)
	body, err := httpsGetOn(conn, plan.SNI, plan.Path)
	_ = conn.Close()
	if err != nil {
		a.fail("tls", err.Error())
		return
	}
	vi.ConsoleLine(markerSent)
	writeBody(body)
	vi.ConsoleLine(markerBody)
	a.status = "ok " + vi.Itoa64(int64(len(body))) + " bytes"
}

func failClosedMatches(expect string, err error) bool {
	switch expect {
	case "name":
		return tls.IsHostnameMismatch(err)
	case "expired":
		return tls.IsExpired(err)
	case "chain":
		return tls.IsNoPathToRoot(err)
	}
	return false
}

func writeBody(body []byte) {
	// Print the HTTP response to the serial so the gate can see the
	// responder's pinned body (live-web-https-ok / live-tls13-ok).
	start := 0
	for i := 0; i <= len(body); i++ {
		if i == len(body) || body[i] == '\n' {
			line := body[start:i]
			if len(line) > 0 && line[len(line)-1] == '\r' {
				line = line[:len(line)-1]
			}
			if len(line) > 0 {
				vi.ConsoleLine(string(line))
			}
			start = i + 1
		}
	}
}

func (a *app) fail(kind, detail string) {
	vi.ConsoleLine(markerError + kind)
	a.status = kind + " " + detail
}

func (a *app) handle(ev vi.Event) bool {
	if ev.Kind != vi.EvKeyDown {
		return false
	}
	switch ev.Arg0 {
	case keyEscape, keyQ:
		vi.ConsoleLine(markerClose)
		vi.ConsoleLine(markerOK)
		a.ta.CloseAndExit(0)
	}
	return false
}

func (a *app) draw() {
	cv := a.ta.Canvas()
	cv.FillRect(widgets.Rect{W: int(a.ta.W), H: int(a.ta.H)}, draw.Opaque(0x101418))
	a.title = widgets.Text{
		R:     scaleR(a.ta, widgets.Rect{X: 8, Y: 8, W: int(natW) - 16, H: 20}),
		Label: appTitle,
		Fg:    0xffffff,
		Bg:    0x1e2430,
	}
	a.body = widgets.Text{
		R:     scaleR(a.ta, widgets.Rect{X: 8, Y: 36, W: int(natW) - 16, H: 20}),
		Label: a.url,
		Fg:    0xe6edf3,
		Bg:    0x161c24,
	}
	a.stat = widgets.Text{
		R:     scaleR(a.ta, widgets.Rect{X: 8, Y: 64, W: int(natW) - 16, H: 20}),
		Label: a.status,
		Fg:    0xa8b0b8,
		Bg:    0x101418,
	}
	a.title.Draw(cv)
	a.body.Draw(cv)
	a.stat.Draw(cv)
}

func scaleR(ta *tabapp.TabApp, r widgets.Rect) widgets.Rect {
	s := ta.Layout(tabapp.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}, natW, natH)
	return widgets.Rect{X: s.X, Y: s.Y, W: s.W, H: s.H}
}
