// WEB.ELF — the VirelaiOS browser (Go, EL0).
//
// The app shell (window, chrome, navigation, history, HTTP fetch) is Go, and
// the page renderer is the project's own Go library (virelai/webrender):
// parse -> bounded CSS cascade -> box layout -> native paint/presentation.
// No JavaScript or POST.
//
// Usage:  exec WEB.ELF /host/PAGE.HTML     (file channel)
//
//	exec WEB.ELF http://10.0.0.2/     (TCP fetch; IP literals only)
//	exec WEB.ELF https://10.0.0.2:24533/  (in-process TLS; fixture SNI)
//	exec WEB.ELF @/host/RSS.LINK      (first line of that file is the page)
//
// vi.Exec allows 255 bytes per argument. Callers can split longer URLs
// across argv slots (joined with no separator) or pass @path to a file whose
// first line is the URL.
package main

import (
	"strings"

	"virelai/appkit"
	"virelai/httpc"
	"virelai/settings"

	"virelai/vi"
	"virelai/webrender"
	"virelai/webstyle"
	"virelai/widgets"
)

// Raw shim geometry; the actual resized canvas controls presentation.
const (
	winX = 40
	winY = 28
	winW = 512
	winH = 384

	// The name the WM peer lookup resolves this process by, and the tab title
	// the rail shows. M69a (#1528).
	appName  = "WEB.ELF"
	appTitle = "Web"
)

// Chrome geometry (all inside the app's own surface).
//
// The kernel paints its OWN window title band over the top 16 rows of every
// user window (observed live: see the live-web pixel probes), so the app's
// chrome starts below it — otherwise the title and the JS indicator would be
// hidden under the kernel band.
const (
	kernelBand = 16
	titleY     = kernelBand
	titleH     = 16
	urlRowY    = titleY + titleH // 32
	urlRowH    = 16
	contentY   = 64 // raw fallback letterbox origin, not the layout origin
	statusH    = 16
	contentW   = webstyle.ViewportWidth
	contentH   = webstyle.ViewportHeight

	backX, backY, chipW, chipH = 6, urlRowY + 2, 14, 14
	fwdX                       = 22
	reloadX                    = 38
	urlX                       = 56
	urlY, urlH                 = urlRowY + 2, 14
)

// Serial markers. These exact bytes are the live gate's grep targets and are
// pinned by a host test (see history_test.go).
const (
	markerOpen      = "web: open id="
	markerParse     = "web: parse nodes="
	markerLayout    = "web: layout blocks="
	markerURL       = "web: url "
	markerNav       = "web: nav "
	markerNavigated = "web: navigated"
	markerError     = "web: error "
	markerPaint     = "web: paint items="
	markerPollErr   = "web: poll err="
	markerLoop      = "web: poll n="
	markerEvent     = "web: ev "
	markerRepaint   = "web: repaint items="
	markerReady     = "web: ready"
	markerNavReady  = "web: nav-ready"
	markerFetch     = "web: fetch "
	markerRedirect  = "web: redirect n="
	markerStores    = "web: stores "
	markerCache     = "web: cache store "
	markerOffline   = "web: offline "
	markerBookmark  = "web: bookmark "
	markerBmStore   = "web: bookmark-store "
	markerBmOpen    = "web: bookmarks n="
	markerBmRow     = "web: bookmarks "
	markerBmPick    = "web: bookmark pick "
	markerBmErr     = "web: bookmark error"
	markerCleared   = "web: cleared "
	markerDownload  = "web: download "
	// M126e (#2597): the download-flow markers — start/progress/done/
	// cancelled/failed for the transfer itself, toast for the seat
	// notice's verdict, open/folder for the completion plate's actions.
	markerDlStart    = "web: download start "
	markerDlProgress = "web: download progress "
	markerDlDone     = "web: download done "
	markerDlCancel   = "web: download cancelled "
	markerDlFailed   = "web: download failed "
	markerDlToast    = "web: download toast "
	markerDlOpen     = "web: download open "
	markerDlFolder   = "web: download folder "
	markerBudget     = "web: budget "
	markerOver       = "web: budget over "
	markerHistOpen   = "web: history n="
	markerHistRow    = "web: history "
	markerHistPick   = "web: history pick "
	markerFind       = "web: find "
	markerFindHit    = "web: find hit="
	// M125d (#2589): the session-state markers. `web: state restored` prints
	// inside loadBody once the stored blob's fields re-applied to the fresh
	// layout; `web: state refused` names a torn or foreign-version blob that
	// was dropped whole, never half-applied.
	markerStateRestored = "web: state restored"
	markerStateRefused  = "web: state refused"
	// M126d (#2596): the zoom rung change and the font_size read/apply.
	// `web: zoom <pct>` prints after the reflowed frame is on the wire;
	// `web: font-size <value> base=<px>` names the stored row and the
	// resolved default text size.
	markerZoom     = "web: zoom "
	markerFontSize = "web: font-size "
	// M177a (#3142): the a11y.text_scale read/apply — `web: text_scale=<n>
	// base=<px>` names the percent and the scaled base it resolves to.
	markerTextScale = "web: text_scale="
	markerReload    = "web: reload"
	markerSettled   = "web: settled"
	// M123b (#2576): the blank viewport — the shared empty-state plate owns
	// the content frame when no page is loaded and no load failed.
	markerEmpty = "web: empty "
	markerQuit  = "web: quit"
	// M121c (#2566): the '?' overlay's receipts — `hints n=` the registry
	// row count on the painted frame, one `hints row` per plate row (the
	// serial-readable copy), `hints close` after the restored frame.
	markerHints    = "web: hints "
	markerHintsRow = "web: hints row "
	// The typography probes. They carry measurable facts (engine name,
	// per-glyph advances, line heights) rather than adjectives, so a silent
	// regression to the 8x8 bitmap fails the class-B gate instead of only
	// looking slightly wrong in a screenshot.
	markerFonts = "web: fonts "
	markerText  = "web: text "
	// M69a (#1528): go-dogfood.spec's ordered marker -- printed once, on the
	// first frame of a LAID-OUT page reaching the scanout (a.lay != nil), so it
	// means "this page rendered", not "the app started".
	markerDogfoodPage = "dogfood: page"
)

// Load bounds. The response read is bounded three ways so a bad network
// cannot hang the app: a byte cap, a wall-clock deadline, and the redirect
// hop cap.
const (
	maxRedirects   = 5
	readDeadlineMs = 30000
)

// Wait durations in nanoseconds (ADR 0060 audit): settles use the deadline
// overlay (vi.SleepNs, slot 94) instead of guessed scheduler ticks.
const (
	ms = 1_000_000

	// frameSettleNs gives the compositor time to pick up a presented frame
	// before the app presents again or prints a gate marker — the observed
	// fix for a first present after a blocking fetch leaving the scanout on
	// the pre-paint buffer.
	frameSettleNs = 300 * ms
	// readyMarkerDrainNs is the drain between the snapshot marker and the
	// ready marker, so the framebuffer stream can finish before the run
	// ends.
	readyMarkerDrainNs = 300 * ms
)

// HistoryPersistence is where visits are appended (inspectable text, one
// "unix-seconds target" row per visit, after a schema line).
const (
	historyPath   = "/host/WEB-HISTORY.TXT"
	historySchema = "# virelai-web-history v1 (unix-seconds<TAB>target)"
)

// HID usage codes the OS delivers in EvKeyDown.Arg0.
const (
	keyQ        = 0x14
	keyR        = 0x15
	keyEscape   = 0x29
	keyBacksp   = 0x2a
	keyRight    = 0x4f
	keyLeft     = 0x50
	keyDown     = 0x51
	keyUp       = 0x52
	keyPageUp   = 0x4b
	keyPageDown = 0x4e
	keyHome     = 0x4a
	keyEnd      = 0x4d
	keyF5       = 0x3e
	keyX        = 0x1b
	keyB        = 0x05
	keyC        = 0x06
	keyD        = 0x07
	keyK        = 0x0e
	keyS        = 0x16
	keyH        = 0x0b
	keyF        = 0x09
	keyO        = 0x12
	keyReturn   = 0x28
)

type app struct {
	win    int
	filler vi.Filler
	// text is the engine the page is measured and painted with: real TrueType
	// when the faces load, the 8x8 bitmap when they do not.
	text webrender.TextEngine

	hist   *history
	target string
	title  string

	doc *webrender.Document
	lay *webrender.Layout

	scroll     int
	hover      string
	status     string
	errKind    string
	errMsg     string
	dirty      bool
	quit       bool
	painted    int
	navCount   int
	polls      int
	events     int
	lastFills  int
	logPaint   bool
	loggedPoll bool
	// dogfoodPage is the once-only latch for markerDogfoodPage (M69a #1528).
	dogfoodPage bool

	// In-flight HTTP load. The loop steps the socket instead of blocking
	// inside navigate(), so Stop/cancel and window-close stay live during a
	// load (a browser must not freeze on a slow peer).
	settled  bool
	loading  bool
	lastBody []byte
	// M135b: the keep-alive slot — at most one idle conn, parked on the
	// origin that produced it; loadPooled/loadReused track the conn the
	// in-flight stepped load arrived on.
	idle       *pooledConn
	loadPooled *pooledConn
	loadReused bool

	// Budget instrumentation. The numbers are printed with the first frame
	// and asserted by the gate; the budgets themselves are stated below.
	tStart   int64 // main() entry
	tNav0    int64 // navigate() entered
	tBody    int64 // body ready (or the error decided)
	tParse   int64
	tLayout  int64
	tPaint   int64
	tSettled int64 // first frame published
	over     string
	loadFrom string
	loadURL  webrender.URL
	loadBuf  []byte
	loadHops int
	loadSeen map[string]bool
	loadEnd  int64 // monotonic deadline (vi.Nanos ns) for the in-flight load
	// loadFramed/loadNeed cache the response framing once the header block
	// arrives: loadNeed >= 0 is the Content-Length body size, -1 means
	// close-delimited (the peer's FIN ends the body), -2 means unsupported
	// framing (chunked, duplicate/bogus Content-Length, over the byte cap).
	loadFramed bool
	loadNeed   int
	// loadEOF marks a peer FIN already seen on the in-flight load (a
	// complete response on a dead conn is complete, never reusable).
	// chunkDec/loadDecoded are the stepped incremental chunked decode.
	loadEOF          bool
	chunkDec         *httpc.Chunked
	loadDecoded      []byte
	chunk            [1024]byte
	loadConn         *vi.Conn
	pageEnd          int64
	loadIdle         int64
	requests         int
	frameInfo        responseFrame
	htmlTruncated    bool
	historyMove      bool
	diagnostics      []webstyle.Diagnostic
	imageSources     map[string][]byte
	imageBytes       int
	resourceWait     int64
	canvasW, canvasH int
	canvasConfigured bool
	nativePix        []uint32
	urlEditing       bool
	urlEdit          textEditor
	histOpen         bool
	histSel          int
	// The find-in-page bar (M126c #2595): open state, the field, the index
	// over the current layout, the shared matcher's offsets, and the
	// 0-based current match (-1 = none). findbar.go has the behavior.
	findOpen    bool
	findEdit    textEditor
	findIdx     *webrender.FindIndex
	findMatches []int
	findCur     int
	// M126d (#2596): this tab's zoom rung (percent; 100 = the contract's
	// own) and the default web text px resolved from font_size. zoom.go
	// owns the ladder, the settings read, and the reflow.
	// M177a (#3142): fontRung is the raw font_size resolution; fontBase is
	// the APPLIED cascade base — fontRung scaled by a11y.text_scale and
	// rounded to whole px. textScale is the row's percent (<=0 reads as
	// the unscaled 100). settingsWatch records that a seat accepted at
	// least one of the two subscriptions.
	zoomPct       int
	fontRung      int
	fontBase      int
	textScale     int
	settingsWatch bool
	// The bookmark store (FLINT ws/bookmarks atom table) + its sidebar.
	books            []bookmark
	bookStream       string
	booksErr         string
	booksMigrated    int
	sideOpen         bool
	sideSel          int
	controls         []*formControl
	focusControl     *formControl
	controlEdit      textEditor
	formOverflow     bool
	showDiagnostics  bool
	diagnosticScroll int
	resourceForTest  func(string, int) ([]byte, string)
	memoryRemaining  int64
	pageCancelled    bool
	pendingEvents    []vi.Event
	// M126e (#2597): the single-flight download — non-nil while a staged
	// write is in flight AND while its completion plate is up (the plate's
	// Open/Folder chips keep a target through a.dl).
	dl *download
	// M125d (#2589): the decoded session blob parked by noteState, consumed
	// once by applyState on the first laid-out page after restore.
	pend *webState
	// M123b (#2576): the start surface — no target, no error; render() paints
	// the shared widgets.EmptyState plate into the viewport. Set by
	// showStartSurface, cleared by the first real navigation.
	blank bool
	// M124b (#2581): the save-as picker — Ctrl+Shift+S raises the shared
	// appkit.FilePicker modal, which owns input and paint while open.
	pick savePick
	// M123d (#2578): the shared appkit.ErrorBanner — the inline strip at
	// the top of the content band for load/download/exec failures. bannerOp
	// names the arm a retry replays ("load"/"download"), bannerTarget what
	// it replays against; banner.go owns the raise/route/resolve/draw half.
	banner       appkit.ErrorBanner
	bannerOp     string
	bannerTarget string
	// M121c (#2566): the '?' chord-hint overlay — the registry's rows for
	// this app's scope (none registered) plus the seat's globals, painted
	// flat over the whole window like the picker plate. hintsEmit latches
	// the open/close edge so its marker follows the frame that shows it.
	hints     appkit.ChordHints
	hintsEmit int // 1 = open receipt pending, 2 = close receipt pending
}

// virender adapts the kernel fill batcher to the renderer's Surface.
type virender struct {
	f    *vi.Filler
	win  int
	pix  []uint32
	w, h int
}

// FillRect makes the fill-only surface a widgets.RectCanvas — the shared
// empty state paints its flat bitmap form through it (M123b #2576).
func (v virender) FillRect(r widgets.Rect, rgb uint32) {
	v.Fill(r.X, r.Y, r.W, r.H, rgb)
}

func (v virender) Fill(x, y, w, h int, rgb uint32) {
	if w <= 0 || h <= 0 {
		return
	}
	if v.pix != nil {
		for yy := max(0, y); yy < min(v.h, y+h); yy++ {
			for xx := max(0, x); xx < min(v.w, x+w); xx++ {
				v.pix[yy*v.w+xx] = rgb & 0xffffff
			}
		}
		return
	}
	if v.f != nil && x >= 0 && y >= 0 {
		v.f.Rect(v.win, uint32(x), uint32(y), uint32(w), uint32(h), rgb)
	}
}

// Budgets for this machine (Apple silicon host, VZ, software raster, one
// vCPU pair). They are deliberately loose: they exist to catch a structural
// regression (an accidental O(n^2), a fetch on the render path), not to
// micro-benchmark.
const (
	// budgetStartupMs is the cold-start cost the BROWSER owns for a page that
	// is already on the share: main() entry to navigate(), i.e. argv + window +
	// the face loads. It is NOT "cold start to a published frame" — that is
	// settle-ms, which reuses this same bar below. A network page also waits on
	// the peer; that wait is reported separately (wait-ms) and never counted as
	// browser cost.
	//
	// M69d #1531 loads four faces (~1.5 MiB) through the kernel's 2048-byte
	// sys_file_read cap (~750 calls). Measured on the reference host after
	// #1586: startup=3025ms (fonts=3022ms of it, every other phase 0-1ms) and
	// 3029-3054ms across the fourteen live-web boots — i.e. this bar is a
	// FONT-LOAD bar. #1586 removed 7013ms of WM-seat retry that used to sit in
	// this window on every boot with no seat (the shim path), which is what held
	// the number at ~10048ms and printed a budget-over line in every WEB boot
	// (13 of the 14; boot 12 launches GOFETCH) while only three boots asserted
	// its absence. The same four faces read 3027ms before that retry existed.
	// 4000ms stays the loose bar for four faces: a structural regression (faces
	// read twice, a fetch on the render path) still trips it, with ~1s of
	// headroom over the measured cost. parse/layout/paint budgets are unchanged.
	budgetStartupMs = 4000
	budgetRenderMs  = 400 // parse + layout + paint of a page
	budgetParseMs   = 120
	budgetLayoutMs  = 120
	budgetPaintMs   = 250
)

// argvTarget joins exec arguments into the page to open. args[0] is the
// program name. Later slots are concatenated because vi.Exec caps each at
// 255 bytes. A target that starts with '@' is a path; the first line of that
// file is the page (urlFromHandoff).
func argvTarget(args []string) (target string, fromFile bool) {
	if len(args) < 2 {
		return "", false
	}
	joined := strings.Join(args[1:], "")
	if strings.HasPrefix(joined, "@") && len(joined) > 1 {
		return joined[1:], true
	}
	return joined, false
}

// urlFromHandoff is the first line of an @path file, trimmed.
func urlFromHandoff(body []byte) string {
	s := string(body)
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = s[:i]
	}
	return strings.TrimSpace(s)
}

func main() {
	t0 := vi.Nanos()
	args, dns, validArgs := browserArgs(vi.Args())
	if !validArgs {
		vi.ConsoleLine("web: error dns-config")
		vi.Exit(2)
		return
	}
	if dns != "" {
		vi.DefaultDNSServer, _ = webrender.ParseIPv4(dns)
	}
	target, fromFile := argvTarget(args)
	if fromFile {
		b, rc := vi.ReadFileAll(target, 8192)
		if rc < 0 || len(b) == 0 {
			target = ""
		} else {
			target = urlFromHandoff(b)
		}
	}

	id, rc := vi.WinOpen(winX, winY, winW, winH)
	if rc < 0 || id < 0 {
		vi.ConsoleLine("web: error window")
		vi.Exit(2)
	}
	a := &app{win: id, hist: newHistory(), tStart: t0, zoomPct: 100}
	a.bindCanvas(winW, winH)
	engine, uiState, monoState, serifState := loadTextEngine()
	a.text = engine
	vi.ConsoleLine(markerFonts + engine.Name() + " ui=" + uiState + " mono=" + monoState + " serif=" + serifState)
	vi.ConsoleLine(markerText + textProbeString(engine))
	// M126d (#2596): the GOSET font_size row sets the default web text
	// size; read it once at startup, then subscribe so a live seat's
	// notices re-apply it. A shim boot has no seat — the subscribe just
	// refuses and the startup read still stands.
	fontVal, fontPx := fontSizeRead()
	a.fontRung = fontPx
	// M177a (#3142): the GOSET a11y.text_scale row multiplies the resolved
	// rung — read once at startup, then subscribed beside font_size.
	a.textScale = textScaleRead()
	a.fontBase = scaledFontBase(fontPx, a.textScale)
	vi.ConsoleLine(markerFontSize + fontVal + " base=" + itoa(a.fontBase))
	vi.ConsoleLine(markerTextScale + itoa(a.textScale) + " base=" + itoa(a.fontBase))
	vi.ConsoleLine(markerOpen + itoa(id))
	// Fullscreen eligibility uses the existing seat RPC. With no responding
	// seat, retain the raw shim; resize events determine the presentation.
	vi.WmMailRequest(vi.WmRpcKindAttachTab, uint32(id), 0, 0, 0, 0, appTitle, appName)
	vi.WmMailRequest(vi.WmRpcKindDeclareFullscreen, uint32(id), 0, 0, 0, 0, appTitle, appName)
	// M125d (#2589): the tab row exists now, so the seat can answer a
	// kind-21 restore. A re-exec'd WEB gets no argv — a stored blob is the
	// only place its URL survives; ask BEFORE navigating so the restored
	// target is the first load. No blob is the honest "start fresh".
	if v, blob, ok := vi.RequestStateRestore(uint32(id), appName); ok {
		a.noteState(v, blob)
	}
	a.settingsWatch = settings.Subscribe("font_size", uint32(id), appName)
	// The text_scale ask goes only to a Go seat — the settings bus' home.
	// A legacy seat never acks kind-13, so this ask would double the
	// bounded ack stall font_size already pays there (M177a #3142).
	if peers := vi.WmPeers(appName); peers.Go {
		a.settingsWatch = settings.Subscribe(settings.A11yTextScaleKey, uint32(id), appName) || a.settingsWatch
	}
	// The store inventory is read from disk at boot: it is how the gate sees
	// that a previous run's rows persisted. The bookmark atoms load first so
	// the count in this line is the on-disk truth, not a later cache.
	a.loadBookmarks()
	vi.ConsoleLine(a.storeSummary())
	vi.ConsoleLine(markerBmStore + "ws=" + bookWSName + " atoms=" + itoa(len(a.books)) +
		" migrated=" + itoa(a.booksMigrated) + " error=" + bmErrText(a.booksErr))

	if a.pend != nil && a.pend.url != "" {
		a.navigate(a.pend.url, "")
	} else if target == "" {
		a.showStartSurface()
	} else {
		a.navigate(target, "")
	}
	a.settleIfNeeded()
	a.loop()
}

// settleRepaint presents the first frame a second time after the scheduler has
// had a tick to pace the composite. Observed live: a single present
// immediately after a long blocking fetch could leave the scanout on the
// pre-paint buffer, while the fill accounting showed every rect accepted.
func (a *app) settleRepaint() {
	vi.SleepNs(frameSettleNs)
	a.render()
	vi.ConsoleLine(markerRepaint + itoa(itemsOf(a)) + " fills=" + itoa(a.lastFills))
	// The gate snapshots on `web: repaint` and *exits* on `web: ready`; the
	// two are deliberately different lines so the framebuffer stream has
	// time to complete before the run ends (observed live: a shared marker
	// let the runner shut down mid-stream and the snapshot never landed).
	vi.SleepNs(readyMarkerDrainNs)
	vi.ConsoleLine(markerReady)
}

// settleIfNeeded publishes the first frame exactly once, and only once the
// window has real content. With a stepped load the socket can still be in
// flight when the window opens, so `web: settled` must keep meaning "the page
// (or its error page) is on screen" rather than "the window exists".
func (a *app) settleIfNeeded() {
	if a.settled || a.loading {
		return
	}
	if a.lay == nil && a.errKind == "" && !a.blank {
		return
	}
	a.render()
	a.tSettled = vi.Nanos() // absolute; reportBudget takes the deltas
	vi.ConsoleLine(markerSettled)
	a.reportBudget()
	if a.target == "" {
		// The start surface owns no blocking fetch. Do not spend the
		// load-settle sleeps before accepting the first URL keystrokes.
		a.render()
		vi.ConsoleLine(markerRepaint + itoa(itemsOf(a)) + " fills=" + itoa(a.lastFills))
		vi.ConsoleLine(markerReady)
	} else {
		a.settleRepaint()
	}
	a.settled = true
}

// reportBudget prints the measured first-frame cost and flags any stage that
// exceeded its stated budget. The gate asserts the line exists and that no
// `web: budget over` line appears, so a regression fails the run.
func (a *app) reportBudget() {
	ms := func(ns int64) string { return itoa(int(ns / 1000000)) }
	wait := a.tBody - a.tNav0
	startup := a.tNav0 - a.tStart
	render := a.tParse + a.tLayout + a.tPaint
	settle := a.tSettled - a.tStart
	// A missing or non-monotonic timestamp means the instrumentation is
	// broken: say so out loud instead of clamping to a flattering zero. The
	// gate asserts `web: budget over` is absent, so this fails the run.
	switch {
	case a.tNav0 == 0 || a.tBody == 0 || a.tSettled == 0:
		a.over = "invalid"
		vi.ConsoleLine(markerOver + "invalid missing-timestamp")
	case wait < 0 || startup < 0 || settle < 0 || render < 0:
		a.over = "invalid"
		vi.ConsoleLine(markerOver + "invalid non-monotonic")
	}
	vi.ConsoleLine(markerBudget +
		"startup-ms=" + ms(startup) +
		" wait-ms=" + ms(wait) +
		" render-ms=" + ms(render) +
		" settle-ms=" + ms(settle) +
		" parse-ms=" + ms(a.tParse) +
		" layout-ms=" + ms(a.tLayout) +
		" paint-ms=" + ms(a.tPaint))

	checks := []struct {
		name  string
		ms    int
		limit int
	}{
		{"startup", int(startup / 1000000), budgetStartupMs},
		{"render", int(render / 1000000), budgetRenderMs},
		{"parse", int(a.tParse / 1000000), budgetParseMs},
		{"layout", int(a.tLayout / 1000000), budgetLayoutMs},
		{"paint", int(a.tPaint / 1000000), budgetPaintMs},
	}
	// settle is only the browser's to own when nothing had to be fetched.
	if wait == 0 {
		checks = append(checks, struct {
			name  string
			ms    int
			limit int
		}{"settle", int(settle / 1000000), budgetStartupMs})
	}
	for _, st := range checks {
		if st.ms > st.limit {
			a.over = st.name
			vi.ConsoleLine(markerOver + st.name + " " + itoa(st.ms) + "ms")
		}
	}
}

func (a *app) loop() {
	for !a.quit {
		a.pollFontSize()
		if a.loading {
			for burst := 0; burst < 16 && a.loading; burst++ {
				before := len(a.loadBuf)
				a.loadStep()
				if len(a.loadBuf) == before {
					break
				}
			}
		}
		a.polls++
		if a.polls%250 == 0 {
			vi.ConsoleLine(markerLoop + itoa(a.polls) + " ev=" + itoa(a.events) + " loading=" + boolStr(a.loading))
		}
		// M125d (#2589): service a pending seat save ask once per pass.
		a.pollStateAsk()
		// M126e (#2597): the seat's kind-23 cancel and the staged write
		// both advance here — the download keeps the loop's 1 ms pacing
		// while it is in flight so the bar stays live.
		if a.dl != nil && a.dl.active {
			if op, ok := vi.PollProgressCancel(uint32(a.win)); ok && op == downloadOp {
				a.cancelDownload()
			}
			a.dlStep()
		}
		ev, raw, ok := vi.Event{}, int64(0), false
		if len(a.pendingEvents) > 0 {
			ev, ok = a.pendingEvents[0], true
			a.pendingEvents = a.pendingEvents[1:]
			if len(a.pendingEvents) == 0 {
				a.pendingEvents = nil
			}
		} else {
			ev, raw, ok = vi.PollEventRaw()
		}
		if !ok {
			if raw < 0 && !a.loggedPoll {
				// A negative poll is a kernel refusal (not an empty queue):
				// surface it instead of spinning silently.
				vi.ConsoleLine(markerPollErr + itoa64(raw))
				a.loggedPoll = true
			}
			// While work is in flight, keep the short poll cadence: quiet
			// tasks leave the shell's idle loop (which paces the composite
			// and services the scanout snapshot) room to run on this
			// single-user machine.
			if a.loading || a.urlEditing || a.target == "" ||
				(a.dl != nil && a.dl.active) {
				vi.Sleep(1)
				continue
			}
			// Idle: wait on the event queue itself rather than a guessed
			// settle (ADR 0060 audit) — a pushed event wakes the loop on
			// arrival, so input no longer waits up to ~10 ticks between
			// polls. The WM-mailbox polls above still run once per pass
			// whenever an event lands; an unanswered save ask degrades per
			// the seat's own ask budget, not as an error. A refused wait
			// falls back to the tick sleep so the loop can never spin.
			ev, raw = vi.WaitEvent()
			if raw <= 0 {
				vi.Sleep(1)
				continue
			}
			ok = true
		}
		a.events++
		if a.events <= 8 {
			vi.ConsoleLine(markerEvent + "kind=" + itoa(int(ev.Kind)) + " a0=" + itoa(int(ev.Arg0)) + " a1=" + itoa(int(ev.Arg1)))
		}
		switch ev.Kind {
		case vi.EvWinClose:
			a.quit = true
		case vi.EvWinResize:
			a.bindCanvas(int(ev.Arg0), int(ev.Arg1))
			a.dirty = true
		case vi.EvKeyDown:
			a.keyEvent(ev)
		case vi.EvMouseDown:
			a.click(int(ev.Arg0), int(ev.Arg1))
		case vi.EvMouseMove:
			a.move(int(ev.Arg0), int(ev.Arg1))
		case 12: // Existing ADR 0009 MOUSE_SCROLL; SDK has no named alias.
			if ev.Arg0&0x4000 == 0 {
				step := int(ev.Arg0&0x3fff) * 40
				if ev.Arg0&0x8000 == 0 {
					step = -step
				}
				a.scrollBy(step)
			}
		}
		if a.dirty {
			a.render()
			a.dirty = false
		}
	}
	// A window close mid-write is a cancel: the partial file must not
	// outlive the app on the share looking like a finished download.
	if a.dl != nil && a.dl.active {
		a.cancelDownload()
	}
	vi.ConsoleLine(markerQuit)
	vi.WinClose(a.win)
	vi.Exit(0)
}

// --- navigation -----------------------------------------------------------

// showStartSurface renders the "nothing loaded" frame: the M123b (#2576)
// shared empty-state plate owns the viewport — icon, headline and the chords
// a blank page still answers. It owns no fetch (tBody stamps the same tick so
// the budget math stays monotonic) and no layout, so `web: paint`/`parse`
// markers stay honest about what the pipeline did.
func (a *app) showStartSurface() {
	a.tNav0 = vi.Nanos()
	a.tBody = a.tNav0
	a.pageEnd = a.tNav0 + readDeadlineMs*1_000_000
	a.target = ""
	a.title = "Start"
	a.lay, a.doc = nil, nil
	a.errKind, a.errMsg = "", ""
	a.scroll = 0
	a.blank = true
	a.logPaint = true
	a.dirty = true
	vi.ConsoleLine(markerEmpty + "start")
}

func (a *app) navigate(target, from string) {
	// M123d (#2578): a fresh navigation retires a standing error banner —
	// its text describes the load the user just moved on from.
	a.banner.Open = false
	if from != "history-back" && from != "history-forward" {
		a.historyMove = false // a replacement navigation is a fresh visit
	}
	a.histOpen = false // a navigation always dismisses the history menu
	if a.anchor(target) {
		return
	}
	a.blank = false // any navigation retires the start surface
	a.closeLoad()
	a.loading = false
	a.tNav0 = vi.Nanos()
	a.tBody = 0
	a.pageEnd = a.tNav0 + readDeadlineMs*1_000_000
	a.requests = 0
	a.pageCancelled = false
	a.htmlTruncated = false
	a.diagnostics = nil
	a.showDiagnostics, a.diagnosticScroll = false, 0
	a.focusControl = nil
	resolved, kind := resolveInput(target)
	a.target = resolved
	switch kind {
	case "empty":
		a.finishError("url", target, from)
		return
	case "unsupported":
		a.finishError("scheme", resolved, from)
		return
	}
	a.target = resolved
	a.scroll = 0
	a.loadFrom = from
	a.loadHops = 0
	a.loadSeen = nil
	vi.ConsoleLine(markerURL + resolved)

	switch kind := classifyTarget(resolved); kind {
	case "https":
		u, ok := parseBrowserURL(resolved)
		if !ok {
			a.finishError("url", resolved, from)
			return
		}
		a.startHTTPS(u)
	case "url":
		a.finishError("url", resolved, from)
	case "http":
		u, _ := parseBrowserURL(resolved)
		a.startHTTP(u)
	default:
		body := readWholeFile(strings.SplitN(resolved, "#", 2)[0], webstyle.MaxHTMLBytes+1)
		switch {
		case len(body) == 0:
			a.finishError("file", resolved, from)
		default:
			if len(body) > webstyle.MaxHTMLBytes {
				body = body[:webstyle.MaxHTMLBytes]
				a.htmlTruncated = true
			}
			a.loadBody(body, resolved)
			a.afterLoad(from)
		}
	}
}

// classifyTarget decides what a resolved target is, and it is deliberately a
// pure function: the "never send an https request in the clear" decision is
// the one thing here that must be unit-testable without a socket.
//
//	kinds: "https" (TLS fetch), "url" (malformed),
//	       "http" (cleartext fetch), "file" (file channel)
func classifyTarget(resolved string) string {
	low := strings.ToLower(resolved)
	switch {
	case strings.HasPrefix(low, "https:"):
		_, ok := parseBrowserURL(resolved)
		if !ok {
			return "url"
		}
		return "https"
	case strings.HasPrefix(low, "http:"):
		_, ok := parseBrowserURL(resolved)
		if !ok {
			return "url"
		}
		return "http"
	}
	return "file"
}

// sendAll writes b to the socket in payload-bounded chunks, so a request
// larger than one syscall send (192 B) can never be silently truncated.
func sendAll(b []byte) bool {
	for len(b) > 0 {
		n, rc := vi.TCPSend(b)
		if rc < 0 || n <= 0 {
			return false
		}
		b = b[n:]
	}
	return true
}

// startHTTP acquires the origin's connection (the pooled keep-alive one
// when it matches), sends the GET, and arms the stepped read. A stale
// pooled conn — peer closed it while idle — earns one fresh-dial retry.
func (a *app) startHTTP(u webrender.URL) {
	p, reused, kind := a.acquireConn(u)
	if kind != "" {
		a.offlineOr(kind)
		return
	}
	a.loadConn = p.conn
	a.loadPooled = p
	a.loadReused = reused
	req := formatPageRequest(u, a.cookieHeaderFor(u.Host, u.Path))
	if !sendAll([]byte(req)) {
		a.loadConn = nil
		a.dropConn(p)
		a.loadPooled = nil
		if reused {
			a.startHTTP(u)
			return
		}
		a.offlineOr("tcp")
		return
	}
	a.loadURL = u
	a.loadBuf = a.loadBuf[:0]
	a.loadFramed = false
	a.loadNeed = 0
	a.loadEOF = false
	a.chunkDec = nil
	a.loadDecoded = a.loadDecoded[:0]
	a.loading = true
	a.loadEnd = a.stageEnd(5_000_000_000)
	a.loadIdle = a.loadEnd
	vi.ConsoleLine(markerFetch + u.Host + u.Path)
}

// startHTTPS dials in-process (tls.Dial over vi.Dial), sends the GET, and
// reads the response on this goroutine. Single-goroutine fetch: no M65
// follow-up. Concurrent fetch would need one — vi.Conn is one-owner and the
// kernel allows one TCP socket per process.
func (a *app) startHTTPS(u webrender.URL) {
	a.loadURL = u
	head, body, truncated, kind := a.fetchNetwork(u, webstyle.MaxHTMLBytes, true)
	if kind != "" {
		a.finishError(kind, a.target, a.loadFrom)
		return
	}
	a.htmlTruncated = truncated
	a.loading = false
	a.finishResponse(true, head, body, truncated)
}

// bodyLen is the response body bytes buffered so far (0 before the header
// block completes).
func (a *app) bodyLen() int {
	_, body, ok := webrender.SplitHTTPResponse(a.loadBuf)
	if !ok {
		return 0
	}
	return len(body)
}

// frame parses (once) and caches the response framing.
func (a *app) frame() {
	if a.loadFramed {
		return
	}
	frame := parseResponseFrame(a.loadBuf)
	if frame.complete {
		a.loadFramed, a.frameInfo = true, frame
		a.loadNeed = frame.need
		if frame.err != "" {
			a.loadNeed = -2
		}
	}
}

// endFail closes the socket and raises a load error.
func (a *app) endFail(kind string) {
	a.closeLoad()
	a.loading = false
	a.finishError(kind, a.target, a.loadFrom)
}

// endOffline closes the socket and takes the offline fallback.
func (a *app) endOffline(kind string) {
	a.closeLoad()
	a.loading = false
	a.offlineOr(kind)
}

// loadStep advances an in-flight load by one bounded read.
//
// The body ends by its declared Content-Length, by the peer's FIN (a
// close-delimited body: readiness bit 0 with a drained recv), by the byte
// cap, or by the wall-clock deadline. An empty recv alone is NOT completion —
// the kernel returns 0 while the next segment may still be a poll away — so
// only an explicit framing or the FIN ends the read. Deadlines apply before
// every read, including progress, so queued bytes cannot extend the total.
func (a *app) loadStep() {
	if a.pageEnd > 0 && vi.Nanos() >= a.pageEnd || a.loadEnd > 0 && vi.Nanos() >= a.loadEnd ||
		a.loadIdle > 0 && vi.Nanos() >= a.loadIdle {
		a.endOffline("timeout")
		return
	}
	mask, rc := vi.TCPReady()
	if rc < 0 {
		a.endOffline("tcp")
		return
	}
	n, rc := vi.TCPRecv(a.chunk[:])
	if rc < 0 {
		a.endOffline("tcp")
		return
	}
	if n > 0 {
		if len(a.loadBuf)+n > webstyle.MaxHTMLBytes+maxHTTPHeaders+64*1024 {
			a.endFail("http-body-limit")
			return
		}
		a.loadBuf = append(a.loadBuf, a.chunk[:n]...)
		a.loadIdle = a.stageEnd(5_000_000_000)
	} else if mask&1 != 0 {
		a.loadEOF = true // readable with a drained recv is the peer's FIN
	} else {
		// No bytes and no FIN: the read is idle, so the deadline applies.
		if vi.Nanos() >= a.loadEnd {
			a.endOffline("timeout")
		}
		return
	}
	a.frame()
	if a.loadFramed {
		a.loadEnd = a.pageEnd // headers are complete; stall/overall bounds remain
	}
	switch {
	case a.loadFramed && a.frameInfo.err != "":
		a.endFail(a.frameInfo.err)
	case a.loadFramed && a.frameInfo.parsed.NoBody:
		a.completeLoad()
	case a.loadFramed && a.frameInfo.parsed.Chunked:
		if a.chunkDec == nil {
			a.chunkDec = &httpc.Chunked{}
		}
		wire := a.loadBuf[a.frameInfo.offset:]
		a.chunkDec.Feed(wire[a.chunkDec.Fed:], &a.loadDecoded, webstyle.MaxHTMLBytes)
		switch {
		case a.chunkDec.Err != "":
			a.endFail(a.chunkDec.Err)
		case a.chunkDec.Done:
			a.completeLoad()
		case n == 0: // a FIN mid-stream is a malformed chunked body
			a.endFail(httpc.ChunkedMalformed)
		}
	case a.loadFramed && a.loadNeed >= 0:
		if a.bodyLen() >= webstyle.MaxHTMLBytes && a.loadNeed > webstyle.MaxHTMLBytes {
			a.htmlTruncated = true
			a.completeLoad()
			return
		}
		if a.bodyLen() >= a.loadNeed {
			a.completeLoad()
			return
		}
		if n == 0 { // the peer closed before the declared body arrived
			a.endFail("http-premature-eof")
		}
	case n == 0:
		if len(a.loadBuf) == 0 {
			if a.loadReused {
				// A conn parked idle whose peer closed it: one fresh-dial
				// retry before declaring the target unreachable.
				a.loadReused = false
				a.loading = false
				a.closeLoad()
				a.loadPooled = nil
				a.startHTTP(a.loadURL)
				return
			}
			// The peer closed without answering: not an empty page, and not
			// a truncated one either — take the offline fallback if there is one.
			a.endOffline("tcp")
			return
		}
		a.completeLoad() // close-delimited: the FIN ended the body
	default:
		if a.bodyLen() > webstyle.MaxHTMLBytes {
			a.htmlTruncated = true
			a.completeLoad()
		}
	}
}

// completeLoad turns a finished response into a page, a redirect step, or an
// error page. A keep-alive-eligible exchange parks its conn in the idle
// slot for the next same-origin request; anything else tears down.
func (a *app) completeLoad() {
	frame := a.frameInfo
	body, truncated, failure := responseBody(frame, a.loadBuf, webstyle.MaxHTMLBytes, true)
	if failure != "" {
		a.closeLoad()
		a.loadPooled = nil
		a.loading = false
		a.finishError(failure, a.target, a.loadFrom)
		return
	}
	if a.loadPooled != nil && frame.parsed.KeepAlive() && !a.loadEOF {
		a.idle = a.loadPooled
		a.loadPooled = nil
		a.loadConn = nil
	} else {
		a.closeLoad()
		a.loadPooled = nil
	}
	a.finishResponse(false, frame.head, body, truncated)
}

func (a *app) finishResponse(viaTLS bool, head string, body []byte, truncated bool) {
	a.loading = false
	a.htmlTruncated = a.htmlTruncated || truncated
	code := webrender.HTTPStatus(head)
	if isPageRedirect(code) {
		next, kind := redirectTarget(a.loadURL, webrender.LocationHeader(head))
		if kind != "" {
			a.finishError(kind, a.target, a.loadFrom)
			return
		}
		key := formatNavURL(next)
		if a.loadSeen == nil {
			a.loadSeen = map[string]bool{}
		}
		if a.loadSeen[key] || a.loadHops >= maxRedirects {
			a.finishError("redirect-loop", a.target, a.loadFrom)
			return
		}
		a.loadSeen[key] = true
		a.loadHops++
		a.target = formatNavURL(next)
		vi.ConsoleLine(markerRedirect + itoa(a.loadHops) + " " + a.target)
		if next.Scheme == "https" || (viaTLS && next.Scheme != "http") {
			a.startHTTPS(next)
			return
		}
		a.startHTTP(next)
		return
	}
	if code != 200 {
		a.status = "HTTP " + itoa(code)
		a.finishError("http", a.target, a.loadFrom)
		return
	}
	if len(body) == 0 {
		a.finishError("empty", a.target, a.loadFrom)
		return
	}
	if len(body) > webstyle.MaxHTMLBytes {
		body = body[:webstyle.MaxHTMLBytes]
		a.htmlTruncated = true
	}
	a.loadBody(body, a.target)
	if n := a.persistCookies(head, a.loadURL.Host); n > 0 {
		vi.ConsoleLine(markerStores + "cookies+" + itoa(n))
	}
	a.cacheStore(a.target, body)
	a.afterLoad(a.loadFrom)
}

func formatNavURL(u webrender.URL) string {
	scheme := u.Scheme
	if scheme == "" {
		scheme = "http"
	}
	def := uint16(80)
	if scheme == "https" {
		def = 443
	}
	if u.Port != 0 && u.Port != def {
		return scheme + "://" + u.Host + ":" + itoa(int(u.Port)) + u.Path
	}
	return scheme + "://" + u.Host + u.Path
}

// cancelLoad stops an in-flight load (Stop / Escape / X).
func (a *app) cancelLoad() {
	if !a.loading {
		a.status = "stopped"
		a.dirty = true
		return
	}
	a.closeLoad()
	a.loading = false
	a.finishError("cancelled", a.target, a.loadFrom)
}

// offlineOr falls back to the stored copy of a page when the network cannot
// deliver it, and is explicit about it: an offline copy is never passed off as
// a fresh fetch.
func (a *app) offlineOr(kind string) {
	if kind == "tcp" || kind == "timeout" {
		if body, ok := a.cacheLookup(a.target); ok {
			a.loadBody(body, a.target)
			a.status = "offline copy (network unavailable)"
			vi.ConsoleLine(markerOffline + a.target)
			a.afterLoad(a.loadFrom)
			return
		}
	}
	a.finishError(kind, a.target, a.loadFrom)
}

// afterLoad records the visit and announces the navigation once the frame is
// up (see announceNavigation).
func (a *app) afterLoad(from string) {
	if a.historyMove {
		a.hist.replace(entry{Target: a.target, Title: a.title})
		a.historyMove = false
	} else {
		a.hist.push(entry{Target: a.target, Title: a.title})
	}
	a.persistHistory(a.target)
	if from != "" {
		a.announceNavigation()
	} else {
		a.settleIfNeeded()
	}
}

// finishError renders the error page for a failed load and records the visit.
func (a *app) finishError(kind, target, from string) {
	if a.loading {
		a.loading = false
	}
	if a.tBody == 0 {
		a.tBody = vi.Nanos()
	}
	a.setError(kind, target)
	if a.historyMove {
		a.hist.replace(entry{Target: target, Title: a.title})
		a.historyMove = false
	} else {
		a.hist.push(entry{Target: target, Title: a.title})
	}
	a.persistHistory(target)
	if from != "" {
		a.announceNavigation()
	} else {
		a.settleIfNeeded()
	}
}

// loadBody runs the renderer pipeline and emits the parse/layout markers.
func (a *app) loadBody(body []byte, target string) {
	a.errKind, a.errMsg = "", ""
	a.lastBody = body
	a.tBody = vi.Nanos()
	if !a.preflightPage(body) {
		a.tParse, a.tLayout = 0, 0
		a.setError("page-memory-limit", target)
		a.diagnostic(webstyle.DiagnosticLimit, "page-memory-limit")
		return
	}
	t0 := vi.Nanos()
	a.doc = webrender.ParseHTML(body)
	if a.htmlTruncated {
		a.doc.Truncated = true
	}
	t1 := vi.Nanos()
	// The engine this page is measured with is stored on the Layout, so Paint
	// draws it with identical metrics; a.resolveImage lets <img> decode without
	// layout ever opening a file itself (ADR 0028 D1/D3).
	a.imageSources = nil
	a.imageBytes = 0
	a.resourceWait = 0
	a.layoutPage()
	if a.pageCancelled || a.quit {
		a.tParse, a.tLayout = t1-t0, vi.Nanos()-t1-a.resourceWait
		a.setError("cancelled", target)
		return
	}
	a.initForms()
	if a.htmlTruncated {
		a.doc.Truncated = true
		a.diagnostic(webstyle.DiagnosticLimit, "html-byte-limit")
	}
	t2 := vi.Nanos()
	a.tParse = t1 - t0
	a.tLayout = t2 - t1 - a.resourceWait
	a.scroll = 0
	a.applyFragment(target)
	a.applyState() // M125d (#2589): the stored blob re-applies once, here
	vi.ConsoleLine(markerParse + itoa(a.doc.Nodes) + " text=" + itoa(a.doc.TextBytes) + " truncated=" + boolStr(a.doc.Truncated))
	vi.ConsoleLine(markerLayout + itoa(a.lay.Blocks) + " lines=" + itoa(a.lay.Lines) + " h=" + itoa(a.lay.Height))
	a.title = pageTitle(a.doc, target)
	a.status = ""
	a.logPaint = true
	a.dirty = true
	if a.findOpen {
		// The bar survives a navigation: the new page re-searches the same
		// pattern silently (the announceNavigation markers are the only
		// ordering a gate can rely on mid-load).
		a.findRecompute(false)
	}
	vi.ConsoleLine("web: diagnostics n=" + itoa(len(a.diagnostics)))
	for _, d := range a.diagnostics {
		vi.ConsoleLine("web: diagnostic " + d.Text)
	}
}

func (a *app) setError(kind, target string) {
	a.errKind = kind
	a.errMsg = errorMessage(kind, target)
	a.lay = nil
	a.doc = nil
	a.findDismiss() // the error page has no findable text
	a.controls, a.focusControl = nil, nil
	a.pend = nil // M125d: a failed restore load drops the blob, not replays it
	a.scroll = 0
	a.title = "Error"
	a.logPaint = true
	vi.ConsoleLine(markerError + kind)
	// M123d (#2578): the failure also stands inline — the error page names
	// what happened; the banner carries the actionable half (Retry on the
	// transient kinds, Copy Error always). "cancelled" is the user's own
	// stop, never a failure to answer.
	if kind != "cancelled" {
		a.raiseLoadBanner(kind, target)
	}
	a.dirty = true
}

// --- events ---------------------------------------------------------------

func (a *app) key(usage uint32, flags uint16) {
	alt := flags&vi.ModAlt != 0
	ctrl := flags&vi.ModCtrl != 0
	page := 680
	if page < 16 {
		page = 16
	}
	switch usage {
	case keyQ:
		a.quit = true
	case keyEscape, keyX:
		// The stop keys own every in-flight thing: an active download
		// first, then a page load. On a completed plate they dismiss it.
		if a.dl != nil {
			if a.dl.active {
				a.cancelDownload()
			} else {
				a.dl = nil
				a.dirty = true
			}
			return
		}
		a.cancelLoad()
	case keyB:
		if ctrl {
			// The card's chord is Ctrl+Shift+B; bare Ctrl+B is Firefox's
			// sidebar key — one toggle either way. NOTE: under shim
			// compositing the kernel also lowers the focused window on
			// Ctrl+Shift+B (input.zig, Arc4 #238, kept with no WM
			// coverage): the sidebar still toggles, the window just sinks
			// — so Ctrl+B is the path that stays visible seatless.
			a.toggleSidebar()
			return
		}
		a.bookmarkToggleUI()
	case keyC:
		vi.ConsoleLine(markerCleared + "cookies " + itoa(a.clearCookies()))
		a.status = "cookies cleared"
		a.dirty = true
	case keyD:
		if ctrl {
			// Ctrl+D — the card's "bookmark this page" chord. Bare D keeps
			// the legacy history-entry delete below.
			a.bookmarkToggleUI()
			return
		}
		vi.ConsoleLine(markerCleared + "history-entry " + boolStr(a.historyDeleteNewest()))
		a.status = "history entry deleted"
		a.dirty = true
	case keyK:
		vi.ConsoleLine(markerCleared + "cache " + itoa(a.clearCache()))
		a.status = "cache cleared"
		a.dirty = true
	case keyS:
		if ctrl && flags&vi.ModShift != 0 {
			// M124b (#2581): Ctrl+Shift+S is save-as — the shared picker;
			// bare S / Ctrl+S keep the fixed WEB-DL-* download.
			a.openSavePicker()
			return
		}
		// 's' saves the loaded page body through the staged download
		// flow (M126e): progress bar, seat row, completion plate, and
		// the ledger row all come from the same path as a link download.
		if len(a.lastBody) > 0 && a.target != "" && ledgerFieldOK(a.target) {
			a.startDownload(a.target, a.lastBody)
		}
	case keyR, keyF5:
		a.reload()
	case keyO:
		// Completion plate's Open — dispatch the saved file through
		// mime.Open, the same contract GOFILES holds.
		if a.dl != nil && a.dl.done {
			a.openDownload()
		}
	case keyF:
		// Completion plate's Show in Folder — GOFILES at the share root.
		if a.dl != nil && a.dl.done {
			a.folderDownload()
		}
	case keyH:
		a.toggleHistoryMenu()
	case keyUp:
		a.scrollBy(-40)
	case keyDown:
		a.scrollBy(40)
	case keyPageUp:
		a.scrollBy(-page)
	case keyPageDown:
		a.scrollBy(page)
	case keyHome:
		a.scroll = 0
		a.dirty = true
	case keyEnd:
		a.scroll = webrenderScrollMax(a)
		a.dirty = true
	case keyBacksp, keyLeft:
		if usage == keyLeft && !alt {
			return
		}
		a.goBack()
	case keyRight:
		if !alt && !ctrl {
			return
		}
		a.goForward()
	}
}

func (a *app) click(x, y int) {
	if a.pick.open { // M124b: the modal owns the click, wherever it lands
		a.pickClick(x, y)
		return
	}
	// M123d (#2578): a press inside the error strip is the banner's —
	// buttons choose, × dismisses, the plate swallows; a press outside
	// falls through to chrome and page as usual.
	if a.bannerClick(x, y) {
		return
	}
	w, h := a.canvasSize()
	switch {
	case inRect(x, y, backX, backY, chipW, chipH):
		a.histOpen = false
		a.goBack()
		return
	case inRect(x, y, fwdX, backY, chipW, chipH):
		a.histOpen = false
		a.goForward()
		return
	case inRect(x, y, reloadX, backY, chipW, chipH):
		a.histOpen = false
		// The reload chip doubles as the stop chip while a load is in
		// flight — the usual browser affordance.
		if a.loading {
			a.cancelLoad()
		} else {
			a.reload()
		}
		return
	case inRect(x, y, actX(w), backY, chipW, chipH):
		if a.urlEditing {
			a.submitURL()
		} else {
			a.toggleHistoryMenu()
		}
		return
	}
	if a.findOpen && inRect(x, y, 0, findBarY(h), w, findBarH) {
		// A click inside the open find strip is consumed — it must not
		// fall through to a page link hiding under the plate.
		a.dirty = true
		return
	}
	fieldHit := inRect(x, y, urlX, urlY, max(0, actX(w)-urlX-4), urlH)
	if a.histOpen {
		if i, ok := a.histMenuHit(x, y); ok {
			a.pickHistory(i)
			return
		}
		a.histOpen = false
		if !fieldHit {
			// A click outside chrome while the menu is open only
			// dismisses it — it must not fall through to a page link.
			a.dirty = true
			return
		}
	}
	if a.sideOpen && inRect(x, y, 0, histMenuY, sideW, h-statusH-histMenuY) {
		if a.sideCloseHit(x, y) {
			a.sideOpen, a.dirty = false, true
			return
		}
		if i, del, ok := a.sideHit(x, y); ok {
			if del {
				a.delBookmark(i)
			} else {
				a.pickBookmark(i)
			}
			return
		}
		// Any other click inside the docked panel is consumed — it must
		// not fall through to a page link hiding under the plate.
		a.dirty = true
		return
	}
	// M126e (#2597): the completion plate floats above the page — its
	// chips act and the rest of the plate consumes the click so it cannot
	// fall through to a link underneath.
	if a.dlToastHitTest(x, y, w, h) {
		return
	}
	if fieldHit {
		a.focusURL()
		return
	}
	a.urlEditing = false
	if a.lay == nil {
		return
	}
	cx, cy, hit := documentPresentation(w, h).inverse(x, y, a.scroll)
	if !hit {
		return
	}
	if a.clickControl(cx, cy) {
		return
	}
	if target := webrender.HitTest(a.lay, cx, cy); target != "" {
		from := a.target
		resolved, kind := resolveInput(relativeTo(from, target))
		if kind == "empty" {
			return
		}
		// M126e (#2597): a link whose target the sniff table already
		// knows is non-text is a download, not a navigation — the
		// browser renders HTML only, so saving the bytes is the honest
		// result (an image link in GOVIEW, not markup noise on screen).
		if kind != "unsupported" && wantsDownload(resolved) {
			a.startDownload(resolved, nil)
			return
		}
		a.navigate(resolved, from)
	}
}

func (a *app) move(x, y int) {
	if a.histOpen {
		if i, ok := a.histMenuHit(x, y); ok && i != a.histSel {
			a.histSel = i
			a.dirty = true
		}
		return
	}
	if a.sideOpen {
		_, h := a.canvasSize()
		if inRect(x, y, 0, histMenuY, sideW, h-statusH-histMenuY) {
			if i, _, ok := a.sideHit(x, y); ok && i != a.sideSel {
				a.sideSel = i
				a.dirty = true
			}
			return
		}
	}
	if a.lay == nil {
		if a.hover != "" {
			a.hover = ""
			a.dirty = true
		}
		return
	}
	w, h := a.canvasSize()
	cx, cy, hit := documentPresentation(w, h).inverse(x, y, a.scroll)
	if !hit {
		if a.hover != "" {
			a.hover = ""
			a.dirty = true
		}
		return
	}
	if target := webrender.HitTest(a.lay, cx, cy); target != a.hover {
		a.hover = target
		a.dirty = true
	}
}

func (a *app) goBack() {
	if e, ok := a.hist.back(); ok {
		a.historyMove = true
		vi.ConsoleLine("web: history back")
		a.navigate(e.Target, "history-back")
	}
}

func (a *app) goForward() {
	if e, ok := a.hist.forward(); ok {
		a.historyMove = true
		vi.ConsoleLine("web: history forward")
		a.navigate(e.Target, "history-forward")
	}
}

// announceNavigation paints the newly loaded page FIRST and only then prints
// the navigation markers, so `web: navigated` means "the new page is on
// screen" — the gate snapshots on that line. (Observed live: printing the
// markers inside navigate() let the snapshot capture the previous page.)
func (a *app) announceNavigation() {
	// Present, let the shell's idle path composite, then present again — the
	// same shape as settleRepaint, and for the same observed reason: a single
	// present immediately after a blocking fetch can be composited late, so a
	// marker printed right after it would still describe the previous frame.
	a.render()
	vi.SleepNs(frameSettleNs)
	a.render()
	a.dirty = false
	a.navCount++
	vi.ConsoleLine(markerNav + a.target)
	vi.ConsoleLine(markerNavigated)
	// A navigation gets its own settle marker: the gate snapshots on
	// `web: navigated` and exits on this line, so the framebuffer stream is
	// never cut off by the run ending (same reason as markerReady).
	vi.SleepNs(readyMarkerDrainNs)
	vi.ConsoleLine(markerNavReady + " n=" + itoa(a.navCount))
}

func (a *app) reload() {
	if a.target == "" {
		a.showStartSurface()
		return
	}
	a.status = "reloading"
	vi.ConsoleLine(markerReload + " " + a.target)
	a.navigate(a.target, "")
}

func (a *app) scrollBy(d int) {
	if a.lay == nil {
		return
	}
	a.scroll += d
	if a.scroll < 0 {
		a.scroll = 0
	}
	if max := webrender.ScrollMax(a.lay, contentH); a.scroll > max {
		a.scroll = max
	}
	a.dirty = true
}

// --- painting -------------------------------------------------------------

func (a *app) render() {
	start := vi.Nanos()
	f := &a.filler
	width, height := a.canvasSize()
	vs := virender{f: f, win: a.win, w: width, h: height}
	clip := webrender.Clip{X: 0, Y: 0, W: width, H: height}
	rect := func(x, y, w, h int, rgb uint32) { vs.Fill(x, y, w, h, rgb) }
	present := documentPresentation(width, height)

	// Title band.
	rect(0, titleY, width, titleH, webrender.ColorChromeBg)
	webrender.DrawText(vs, 6, titleY+4, fit("WEB.ELF  "+a.title, (width-72)/8), 1, false, webrender.ColorChromeInk, clip)
	webrender.DrawText(vs, width-58, titleY+4, "JS: off", 1, false, webrender.ColorError, clip)

	// URL row.
	rect(0, urlRowY, width, urlRowH, webrender.ColorChromeBg)
	chevBack := webrender.ColorMuted
	if a.hist.canBack() {
		chevBack = webrender.ColorChromeInk
	}
	chevFwd := webrender.ColorMuted
	if a.hist.canForward() {
		chevFwd = webrender.ColorChromeInk
	}
	webrender.DrawText(vs, backX+3, backY+3, "<", 1, false, chevBack, clip)
	webrender.DrawText(vs, fwdX+3, backY+3, ">", 1, false, chevFwd, clip)
	// Reload is the stop chip while a load is in flight.
	reloadGlyph := "R"
	if a.loading {
		reloadGlyph = "X"
	}
	webrender.DrawText(vs, reloadX+3, backY+3, reloadGlyph, 1, false, webrender.ColorChromeInk, clip)
	// The right-edge action chip: ">" submits the field while the URL edits,
	// "v" opens the history dropdown otherwise.
	actGlyph, actInk := "v", webrender.ColorMuted
	switch {
	case a.urlEditing:
		actGlyph, actInk = ">", webrender.ColorAccent
	case a.histOpen || a.hist.len() > 0:
		actInk = webrender.ColorChromeInk
	}
	webrender.DrawText(vs, actX(width)+3, backY+3, actGlyph, 1, false, actInk, clip)

	addressWidth := max(0, actX(width)-urlX-4)
	rect(urlX, urlY, addressWidth, urlH, webrender.ColorSurface)
	rect(urlX, urlY, addressWidth, 1, webrender.ColorRule)
	shown := a.target
	if a.urlEditing {
		shown = a.urlEdit.text
		rect(urlX, urlY, addressWidth, 1, webrender.ColorAccent)
	}
	if shown == "" {
		shown = "(no target)"
	}
	webrender.DrawText(vs, urlX+4, urlY+3, fit(shown, (addressWidth-8)/8), 1, false, webrender.ColorChromeInk, clip)

	// Content.
	rect(0, kernelBand+32, width, height-kernelBand-32-statusH, webrender.ColorChromeBg)
	native := a.nativeSurface()
	native.Fill(0, 0, contentW, contentH, webrender.ColorPageBg)
	if a.lay != nil {
		a.updateControlPaint()
		webrender.Paint(a.lay, native, 0, 0, contentW, contentH, a.scroll)
		a.painted = len(a.lay.Items)
		a.paintFindHighlights(native)
	} else if a.blank {
		a.paintEmptyState(native)
	} else {
		a.paintErrorPage(native)
	}
	if a.showDiagnostics {
		native.Fill(0, 0, contentW, contentH, webrender.ColorPageBg)
		for i := a.diagnosticScroll; i < min(len(a.diagnostics), a.diagnosticScroll+38); i++ {
			webrender.DrawText(native, 8, 8+(i-a.diagnosticScroll)*18, fit(a.diagnostics[i].Text, contentW/8-2),
				1, false, webrender.ColorText, webrender.Clip{W: contentW, H: contentH})
		}
	}
	a.sampleFrame(vs, present)
	if a.sideOpen {
		a.paintSidebar(vs, clip, width, height)
	}
	if a.histOpen {
		a.paintHistoryMenu(vs, clip, width)
	}
	if a.findOpen {
		a.paintFindBar(vs, clip, width, height)
	}
	vi.ConsoleLine("web: viewport css=1280x720 x=" + itoa(present.X) +
		" y=" + itoa(present.Y) + " w=" + itoa(present.W) + " h=" + itoa(present.H) + " s=" + itoa(a.scroll))

	// Status line (drawn last so nothing can cover it).
	rect(0, height-statusH, width, statusH, webrender.ColorChromeBg)
	statusCols := width/8 - 2
	if a.dl != nil && a.dl.active {
		// The progress bar owns the status line's right edge while a
		// write is in flight; the text yields those columns to it.
		statusCols -= dlBarW/8 + 2
	}
	webrender.DrawText(vs, 6, height-statusH+2, fit(a.statusText(), statusCols), 1, false, webrender.ColorMuted, clip)
	// M126e (#2597): the in-flight bar on the status line, then the
	// completion plate — last, so no other chrome covers it.
	if a.dl != nil {
		if a.dl.active {
			a.paintDlBar(vs, width, height)
		}
		if a.dl.done {
			a.paintDlToast(vs, width, height)
		}
	}
	// M123d (#2578): the error strip floats the top of the content band —
	// above the page and the download plate, under the modal picker.
	a.paintBanner(vs)

	if a.pick.open { // M124b: the modal plate paints over chrome+status
		a.paintPick()
	}
	if a.hints.Open { // M121c: the '?' overlay paints last of all
		a.hints.Draw(vs)
	}

	processed := f.Flush()
	a.lastFills = processed
	vi.WinPresent(a.win)
	a.tPaint = vi.Nanos() - start
	// M69a (#1528): the page is on the wire. Once only, and only for a real
	// laid-out page (the error page paints with a.lay == nil).
	if !a.dogfoodPage && a.lay != nil {
		a.dogfoodPage = true
		vi.ConsoleLine(markerDogfoodPage)
	}
	if a.logPaint {
		vi.ConsoleLine(markerPaint + itoa(itemsOf(a)) + " fills=" + itoa(processed))
		a.logPaint = false
	}
	// M121c: the hints receipt describes the frame just presented — the
	// open count plus one row line per registry row the plate shows, or
	// the close line after the restore frame.
	switch a.hintsEmit {
	case 1:
		vi.ConsoleLine(markerHints + "n=" + itoa(a.hints.ChordRows()))
		for _, l := range a.hints.RowLines() {
			vi.ConsoleLine(markerHintsRow + l)
		}
	case 2:
		vi.ConsoleLine(markerHints + "close")
	}
	a.hintsEmit = 0
}

func itemsOf(a *app) int {
	if a.lay == nil {
		return 0
	}
	return len(a.lay.Items)
}

func (a *app) statusText() string {
	if c := a.focusControl; c != nil {
		return "form " + c.kind + " " + c.name + " checked=" + boolStr(c.checked)
	}
	if a.hover != "" {
		return "link: " + a.hover
	}
	if a.status != "" {
		return a.status
	}
	if len(a.diagnostics) > 0 {
		return "diagnostics=" + itoa(len(a.diagnostics)) + " (F1 list) " + a.diagnostics[0].Text
	}
	if a.lay == nil {
		if a.blank {
			return "start"
		}
		return "error"
	}
	max := webrender.ScrollMax(a.lay, contentH)
	status := "nodes=" + itoa(nodeCount(a.doc)) + " blocks=" + itoa(a.lay.Blocks) +
		" lines=" + itoa(a.lay.Lines) + " items=" + itoa(len(a.lay.Items)) +
		" scroll=" + itoa(a.scroll) + "/" + itoa(max)
	if a.zoomPct != 100 {
		status += " zoom=" + itoa(a.zoomPct) + "%"
	}
	return status
}

// paintEmptyState is the M123b (#2576) blank viewport: the shared
// widgets.EmptyState plate centred in the content frame — icon, headline and
// the chords the start surface answers — the same shape GOFILES, GOEDIT and
// the launcher draw. The virender surface is fill-only, so the kit paints its
// flat bitmap form.
func (a *app) paintEmptyState(vs virender) {
	const pad = 24
	(&widgets.EmptyState{
		R:        widgets.Rect{X: pad, Y: pad, W: contentW - 2*pad, H: contentH - 2*pad},
		Icon:     "@",
		Headline: "Nothing loaded",
		Hints: []string{
			"Ctrl+L type an address · Enter loads it",
			"exec WEB.ELF /host/PAGE.HTML · H history · Q quit",
		},
	}).Draw(vs)
}

func (a *app) paintErrorPage(vs virender) {
	clip := webrender.Clip{X: 8, Y: 8, W: contentW - 16, H: contentH - 16}
	y := 12
	webrender.DrawText(vs, 12, y, "This page could not be loaded", 2, true, webrender.ColorText, clip)
	y += 26
	webrender.DrawText(vs, 12, y, fit(a.errMsg, contentW/8-2), 1, false, webrender.ColorError, clip)
	y += 18
	webrender.DrawText(vs, 12, y, fit("target: "+a.describeTarget(), contentW/8-2), 1, false, webrender.ColorMuted, clip)
	y += 18
	webrender.DrawText(vs, 12, y, "kind: "+a.errKind, 1, false, webrender.ColorMuted, clip)
	y += 24
	webrender.DrawText(vs, 12, y, "Ctrl+L URL  R reload  < back  > forward  H history  ^F find  ^D mark  ^+B marks  Esc stop  Q quit", 1, false, webrender.ColorMuted, clip)
}

func (a *app) describeTarget() string {
	if a.target == "" {
		return "(none)"
	}
	return a.target
}

func (a *app) persistHistory(target string) {
	if !ledgerFieldOK(target) {
		return
	}
	if !vi.FileExists(historyPath) {
		vi.FileAppend(historyPath, []byte(historySchema+"\n"))
	}
	line := itoa64(vi.Time()) + "\t" + target + "\n"
	vi.FileAppend(historyPath, []byte(line))
}

// --- pure helpers (host-tested) -------------------------------------------

// resolveInput classifies a command-line target or address-bar entry.
func resolveInput(in string) (string, string) {
	s := strings.TrimSpace(in)
	if s == "" {
		return "", "empty"
	}
	// A scheme prefix is recognised before anything else: "javascript:...",
	// "file:///...", "mailto:..." must be refused as schemes, never rewritten
	// into a file-channel path (which is where a bare-name rule would send
	// them).
	if i := strings.IndexByte(s, ':'); i > 0 && !strings.ContainsAny(s[:i], "/?#:") && isSchemeAlpha(s[:i]) {
		switch strings.ToLower(s[:i]) {
		case "http", "https":
			return s, "http"
		}
		return s, "unsupported"
	}
	low := strings.ToLower(s)
	switch {
	case strings.HasPrefix(low, "http://"), strings.HasPrefix(low, "https://"):
		// Scheme-shaped: hand it on unresolved so classifyTarget can pick
		// https (TLS) vs dns vs url rather than the classifier never
		// seeing it.
		return s, "http"
	case strings.Contains(low, "://"):
		return s, "unsupported"
	case strings.HasPrefix(s, "/"):
		return s, "file"
	}
	return "/host/" + s, "file"
}

// isSchemeAlpha reports whether every byte is an RFC 3986 scheme character.
func isSchemeAlpha(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z':
		case i > 0 && (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.'):
		default:
			return false
		}
	}
	return s != ""
}

// relativeTo resolves an href found on a page against the page's own target.
func relativeTo(base, href string) string {
	return resolveReference(base, href)
}

func pageTitle(doc *webrender.Document, target string) string {
	if doc != nil {
		for _, it := range doc.Root.Children {
			if t := firstHeading(it); t != "" {
				return t
			}
		}
	}
	if i := strings.LastIndexByte(target, '/'); i >= 0 && i+1 < len(target) {
		return target[i+1:]
	}
	return target
}

func firstHeading(n *webrender.Node) string {
	if n.Kind == webrender.KindElement && (n.Tag == "h1" || n.Tag == "h2" || n.Tag == "title") {
		if t := strings.TrimSpace(webrender.TextContent(n)); t != "" {
			return t
		}
	}
	for _, c := range n.Children {
		if t := firstHeading(c); t != "" {
			return t
		}
	}
	return ""
}

func nodeCount(doc *webrender.Document) int {
	if doc == nil {
		return 0
	}
	return doc.Nodes
}

// fit truncates s so it fits in cols 8-pixel columns, marking the cut.
func fit(s string, cols int) string {
	if cols < 1 {
		cols = 1
	}
	s = webrender.UpperASCII(s)
	if len(s) <= cols {
		return s
	}
	if cols <= 2 {
		return s[:cols]
	}
	return s[:cols-2] + ".."
}

func inRect(x, y, rx, ry, rw, rh int) bool {
	return x >= rx && x < rx+rw && y >= ry && y < ry+rh
}

func boolStr(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

func errorMessage(kind, target string) string {
	switch kind {
	case "file":
		return "No such file on the share (expected " + target + ")."
	case "dns":
		return "DNS lookup failed within its bounded budget."
	case "tcp":
		return "TCP connect, send, or receive failed."
	case "timeout":
		return "The server did not answer in time."
	case "truncated":
		return "The response ended before its headers were complete."
	case "empty":
		return "The target produced zero bytes."
	case "http":
		return "The server answered with a non-200 status."
	case "scheme":
		return "Only http://, https://, and the local file channel are supported."
	case "https":
		return "HTTPS could not establish a verified connection."
	case "tls":
		return "TLS handshake failed (fail closed). Nothing was sent in the clear."
	case "tls-hostname-mismatch":
		return "The certificate does not match the requested hostname."
	case "tls-expired":
		return "The certificate is expired or not yet valid."
	case "tls-unknown-root":
		return "The certificate chain has no trusted root."
	case "http-framing-unsupported":
		return "Transfer or content coding is not supported; identity framing is required."
	case "http-framing-invalid", "http-premature-eof", "chunked-malformed",
		"gzip-crc", "gzip-too-large", "gzip-malformed":
		return "The response framing is invalid, the chunked stream malformed, or the gzip body failed its check."
	case "http-header-limit", "http-body-limit", "network-request-limit":
		return "The response or request count exceeded the declared page budget."
	case "redirect-downgrade":
		return "An HTTPS to HTTP redirect was refused."
	case "redirect-location":
		return "The redirect Location is missing or unsupported."
	case "form-method-unsupported":
		return "Only GET form submission is supported. No POST was sent."
	case "form-control-unsupported":
		return "This form contains a control outside the supported GET subset."
	case "form-control-limit", "form-url-limit":
		return "The form exceeds the declared control or URL budget."
	case "page-memory-limit":
		return "This page cannot fit inside the declared browser memory budget."
	case "cancelled":
		return "Load stopped before the server answered."
	case "redirect":
		return "The server sent a redirect we could not resolve."
	case "redirect-loop":
		return "Too many redirects (or a redirect loop); stopped after " + itoa(maxRedirects) + " hops."
	}
	return "Unrecognised target."
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [24]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

func itoa64(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [24]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
