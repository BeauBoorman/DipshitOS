// Command view is GOVIEW.ELF — the M71h (issue #1567) Go image viewer: open a
// share image, paint it full-viewport inside the tabbed desktop, and stay open
// on a missing or undecodable file (Zig VIEW.BIN's "don't panic" rule).
//
// It replaces Zig VIEW.BIN (M36 IMG5, #826). The decode is NOT a second
// decoder: webrender.DecodeImage already owns the formats this project
// decodes — QOI in-tree, PNG off the guest — and this app reuses it (D1).
//
// Every marker below is printed only AFTER the syscall it reports returned, so
// the live-image-viewer gate's asserts can only pass if the app actually ran.
package main

import (
	"errors"

	"virelai/appkit"
	"virelai/draw"
	"virelai/settings"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/vsys"
	"virelai/webrender"
	"virelai/webrender/font"
	"virelai/webrender/qoi"
	"virelai/widgets"
)

const (
	appName  = "GOVIEW.ELF"
	appTitle = "Image Viewer"

	// exitQuit is VIEW.BIN's own exit status (view.zig exit_status): the gate
	// asserts `user-exec exited status=43`, so the successor keeps it.
	exitQuit = 43

	// maxPathLen is the usable bytes of one kernel argv slot (M71m:
	// arg_slot_bytes 256 - 1 for the NUL); vi.ExecArgMax names the same
	// bound. The kernel refuses a longer argv before this process starts.
	maxPathLen = vi.ExecArgMax

	markerOpen        = "gview: open id="
	markerTabAware    = "gview: tab-aware (full-viewport)"
	markerNotTabAware = "gview: not-tab-aware (shim or WND desktop)"
	markerOpenFailed  = "gview: failed to open window"
	markerEmpty       = "gview: empty (no args)"
	markerLoaded      = "gview: loaded "
	markerTitleSet    = "gview: title set"
	markerPresent     = "gview: present"
	markerReady       = "gview: ready"
	markerZoom        = "gview: zoom z="
	markerPan         = "gview: pan ox="
	markerQuit        = "gview: quit"
	markerWinClose    = "gview: win_close"
	markerResize      = "gview: resize relayout "
	markerExiting     = "gview: exiting "
	// M124a-2 (#2677): the drop target's receipt — `<mime> WxH bytes=` on
	// a decoded image, `no-payload`/`unsupported <tag>`/`decode <mime>`/
	// `too-large` for the refused shapes.
	markerDrop        = "gview: drop "
	markerOpenErr     = "gview: open err"
	markerReadErr     = "gview: read err"
	markerTooLarge    = "gview: too large"
	markerDecodeErr   = "gview: decode err"
	markerUnsupported = "gview: unsupported "

	// M124c (#2582): the typed-clipboard copy. `gview: copy mime=<m> n=<n>`
	// after slot 38 stored the bytes; the refused form names why.
	markerCopy       = "gview: copy "
	markerCopyRefuse = "gview: copy refused "

	// M162a (#2975): the frame stepper's receipt — `frame <i>/<n> delay=<ms>
	// sum=<fnv>` — printed on load for frame 1 and on every step.
	markerFrame = "gview: frame "

	// M170e (#3039): the playback receipt — `play frames=<n>
	// elapsed_ms=<t>` — printed each time a playing GIF wraps to frame 1:
	// n frames of one loop took t wall milliseconds of PLAYING time (a
	// pause inside the loop does not count).
	markerPlay = "gview: play "

	// M177a (#3142): `-play` under a11y.reduce_motion — the animation
	// opens parked on frame 1 and this line says why; space still plays
	// because pressing it is the user's own request.
	markerMotionReduced = "gview: motion reduced"

	// M177a (#3142): one line per settings subscription the seat accepts
	// — the same evidence shape as gocalc's settings-subscribed line.
	markerSettingSubscribed = "gview: settings subscribed key="

	// M162c (#2986): the save-as legs — `pick save` at raise, `pick save
	// <path>`/`pick cancel` at result, `saved <path> fmt=<png|qoi> n=<bytes>
	// sum=<fnv>` on the write, `save refused <path>` when the name names no
	// known format.
	markerPick       = "gview: pick "
	markerSaved      = "gview: saved "
	markerSaveRefuse = "gview: save refused "

	markerOK = "goview OK"
)

// loadState is which step of the open→read→decode path failed. The markers are
// emitted from this state, never from the error text, so a gate can assert the
// reason without parsing a message.
type loadState int

const (
	loadNone loadState = iota
	loadFailedOpen
	loadFailedRead
	loadTooLarge
	loadFailedDecode
	loadUnsupported
	loadOkay
)

type app struct {
	ta   *tabapp.TabApp
	name string
	path string
	fm   format
	st   loadState

	img    *webrender.Image
	iw, ih uint32

	// The animation behind a decoded GIF (M162a): every composited frame
	// and the index being shown. nil on every other format.
	anim  *webrender.GIFAnimation
	frame int

	// M170e playback state: playing while the app timer is armed to post
	// EvTimer for the current frame's delay. playFireAt is the armed
	// deadline on the playNow clock; playStretch is when the current
	// unpaused stretch began; playAccum is the playing time banked across
	// pauses this loop, so elapsed_ms measures frames actually shown.
	// playLastElapsed is the last completed loop's ns — the receipt's
	// value, kept on the app so a host test reads it without a console.
	playing         bool
	playFireAt      int64
	playStretch     int64
	playAccum       int64
	playLastElapsed int64

	// M177a (#3142): the a11y.reduce_motion row in force — read at startup
	// and kept live by the settings subscription; it gates playback the
	// app would start on its own (-play), never a key the user pressed.
	// settingsWatch records that at least one subscription landed, so the
	// poll can skip its syscall on a shim boot.
	reduceMotion  bool
	settingsWatch bool

	// The M162c save-as modal: while pick.Open every key/mouse event is the
	// picker's — the same FilePicker GOPAINT raises, painted over the
	// viewer's own canvas.
	pick appkit.FilePicker

	zoomIdx        int
	ox, oy         uint32
	titleAnnounced bool

	drag           bool
	dragX, dragY   int
	dragOX, dragOY uint32

	unsupportedTag string
}

// The playback seams (M170e): slot 95's arm, slot 41's cancel, and the EL0
// counter the receipts measure on. Package vars so a host test injects a
// fake timer and clock — the kernel's re-arm-replaces contract means the
// schedule a test records IS the delay schedule the guest ran.
var (
	playArm    = func(ns uint64) int64 { return vsys.TimerSetNs(ns) }
	playCancel = func() int64 { return vsys.TimerCancel() }
	playNow    = func() int64 { return vi.Nanos() }
)

// loadGuestTheme applies /host/SETTINGS.TXT at startup — the theme base
// AND the a11y.contrast switch through the one ApplySettings door every
// themed app uses, so GOVIEW's backdrop and bars honour the same pair.
func loadGuestTheme() {
	b, r := vi.ReadFileAll("/host/SETTINGS.TXT", 2048)
	if r < 0 || b == nil {
		return
	}
	_ = theme.ApplySettings(b)
}

// reduceMotionRead is the startup read of a11y.reduce_motion — the schema
// decode, not a raw-line scan. Missing or corrupt reads off.
func reduceMotionRead() bool {
	f := settings.Load()
	if f.State != settings.StateOK {
		return false
	}
	v, ok := f.Effective(settings.A11yReduceMotionKey)
	if !ok {
		return false
	}
	on, _ := settings.A11yReduceMotion(v)
	return on
}

func main() {
	loadGuestTheme()
	reduceMotion := reduceMotionRead()
	path := argPath()

	// Header first, window second: the window is sized to the image before it
	// opens, which is why the gate can assert `gview: open id=N 328x264` for a
	// 160x120 fixture. VIEW.BIN read the same 24 bytes for the same reason.
	var head []byte
	if path != "" {
		head = readHead(path)
	}
	iw, ih, haveDims := headerDims(head)
	size := headerSize(head)
	title := appTitle
	if path != "" {
		if haveDims {
			title = composeTitle(basename(path), iw, ih, formatOfHeader(head), zoomTable[zoomDefaultIdx])
		} else {
			title = basename(path)
		}
	}

	ta := tabapp.Init(tabapp.Config{
		Name:  appName,
		Title: title,
		X:     windowX,
		Y:     windowY,
		W:     size.W,
		H:     size.H,
	})
	if ta == nil {
		vi.ConsoleLine(markerOpenFailed)
		vi.Exit(1)
	}
	if ta.TabAware {
		vi.ConsoleLine(markerTabAware)
	} else {
		vi.ConsoleLine(markerNotTabAware)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)) + " " + u32s(ta.W) + "x" + u32s(ta.H))

	a := &app{ta: ta, name: basename(path), path: path, fm: formatOfHeader(head), zoomIdx: zoomDefaultIdx,
		reduceMotion: reduceMotion}
	// M177a (#3142): theme plus the two a11y keys GOVIEW honours — asked
	// only of a Go seat, the one seat running the settings bus: a legacy
	// seat or the shim never acks kind-13, and each ask would park the
	// startup path for the whole bounded ack window.
	if peers := vi.WmPeers(appName); peers.Go {
		for _, key := range []string{"theme", settings.A11yContrastKey, settings.A11yReduceMotionKey} {
			if settings.Subscribe(key, uint32(ta.Win), appName) {
				a.settingsWatch = true
				vi.ConsoleLine(markerSettingSubscribed + key)
			}
		}
	}
	// M124a-2 (#2677): the drop target. The seat's opens=image admission
	// filtered the mime; a delivered payload decodes through the same
	// DecodeImage path as a file load, and the callback repaints itself.
	a.ta.DropTarget = a.drop

	if path == "" {
		vi.ConsoleLine(markerEmpty)
	} else {
		a.load(path)
		a.reportLoad()
	}
	// `-play` (flagPlay): playback starts armed on load — the live gate's
	// way in, since no scripted input channel is free to press space.
	if argFlag(flagPlay) {
		a.requestPlay()
	}

	a.pushTitle()
	a.draw()
	a.ta.Present()
	vi.ConsoleLine(markerPresent)
	vi.ConsoleLine(markerReady)

	a.eventLoop()

	vi.ConsoleLine(markerExiting + vi.Itoa64(exitQuit))
	a.ta.CloseAndExit(exitQuit)
}

// argPath is the file to open: the first argument after the program name
// (`exec GOVIEW.ELF /host/TEST.QOI`), skipping the `-play` switch when one
// is present. Empty when nothing was passed — VIEW.BIN's clean empty state.
func argPath() string {
	args := vi.Args()
	if len(args) < 2 {
		return ""
	}
	for _, s := range args[1:] {
		if s != flagPlay {
			return s
		}
	}
	return ""
}

// argFlag reports whether want is one of the argv words after the program
// name — `exec GOVIEW.ELF -play /host/PLAY.GIF` and
// `exec GOVIEW.ELF /host/PLAY.GIF -play` both set it.
func argFlag(want string) bool {
	args := vi.Args()
	if len(args) < 2 {
		return false
	}
	for _, s := range args[1:] {
		if s == want {
			return true
		}
	}
	return false
}

// readHead peeks the head of the file without decoding. QOI's 14-byte header
// and PNG's IHDR live in the first 24 bytes; JPEG's SOF sits behind APPn/DQT
// segments, so the read runs deeper — still trivially inside the 512 KiB
// file cap. Best-effort: an unreadable file simply yields no dimensions.
const headMax = 4096

func readHead(path string) []byte {
	h, r := vi.FileOpen(path, vi.ModeRead)
	if r < 0 {
		return nil
	}
	defer vi.FileClose(uint32(h))
	buf := make([]byte, headMax)
	n := 0
	for n < headMax {
		got, rr := vi.FileRead(uint32(h), buf[n:])
		if rr < 0 {
			return nil
		}
		n += got
		if got == 0 {
			break
		}
	}
	if n == 0 {
		return nil
	}
	return buf[:n]
}

// load opens, reads and decodes path, recording the first step that failed.
func (a *app) load(path string) {
	// VIEW.BIN refused a path past the argv slot bound before touching the file.
	if len(path) == 0 || len(path) > maxPathLen {
		a.st = loadFailedOpen
		return
	}
	if a.name == "" {
		a.name = basename(path)
	}
	data, st := readImage(path)
	if st != loadOkay {
		a.st = st
		return
	}
	im, anim, err := decodeForView(data)
	if err != nil {
		// "This format has no guest decoder" is a different fact from "these
		// bytes are broken", and the app is the only place that can tell them
		// apart for the user. See image_png_guest.go: PNG has no in-guest
		// decoder because the fork's stdlib image/png drags in fmt/os.
		if errors.Is(err, webrender.ErrImageUnsupported) {
			a.st = loadUnsupported
			a.unsupportedTag = formatOfHeader(data).tag()
			return
		}
		a.st = loadFailedDecode
		return
	}
	if im.Width*im.Height > pixelsMax {
		a.st = loadTooLarge
		return
	}
	a.img = im
	a.iw, a.ih = uint32(im.Width), uint32(im.Height)
	a.anim, a.frame = anim, 0
	a.st = loadOkay
	line := markerLoaded + a.name + " " + u32s(a.iw) + "x" + u32s(a.ih) + " " +
		a.fm.tag() + " bytes=" + vi.Itoa64(int64(len(data)))
	if im.Frames > 0 {
		// A container that carries more than one image reports its count in
		// the same receipt; a bound that stopped the GIF walk names itself.
		line += " frames=" + vi.Itoa64(int64(im.Frames))
	}
	if anim != nil && anim.Truncated != "" {
		line += " truncated=" + anim.Truncated
	}
	vi.ConsoleLine(line)
	a.announceFrame()
}

// decodeForView routes a GIF through webrender.DecodeGIFFrames — the
// stepper's frame list — and everything else through DecodeImage. The
// returned Image is the shown frame: the first composite for a GIF, the
// whole decode otherwise. anim is nil on every non-GIF format.
func decodeForView(data []byte) (im *webrender.Image, anim *webrender.GIFAnimation, err error) {
	if formatOfHeader(data) == fmtGIF {
		anim, err = webrender.DecodeGIFFrames(data, webrender.GIFLimits{})
		if err != nil {
			return nil, nil, err
		}
		return &webrender.Image{
			Width: anim.Width, Height: anim.Height,
			Pix: anim.Frames[0].Pix, Frames: len(anim.Frames),
		}, anim, nil
	}
	im, err = webrender.DecodeImage(data)
	return im, nil, err
}

// readImage reads at most fileMax bytes. The loop is ours rather than
// vi.ReadFileAll's because ReadFileAll silently clamps `max` to
// vi.MaxFileBytes (256 KiB): VIEW.BIN's own cap is 512 KiB, and a silent clamp
// would turn "file too large" into "truncated, then a decode error".
func readImage(path string) ([]byte, loadState) {
	h, r := vi.FileOpen(path, vi.ModeRead)
	if r < 0 {
		return nil, loadFailedOpen
	}
	defer vi.FileClose(uint32(h))
	out := make([]byte, 0, 8192)
	buf := make([]byte, 4096)
	for len(out) < fileMax {
		n, rr := vi.FileRead(uint32(h), buf)
		if rr < 0 {
			return out, loadFailedRead
		}
		if n == 0 {
			break
		}
		take := n
		if len(out)+take > fileMax {
			take = fileMax - len(out)
		}
		out = append(out, buf[:take]...)
		if take < n {
			break
		}
	}
	// Exactly fileMax in hand: is there more? One more byte decides.
	if len(out) == fileMax {
		if n, rr := vi.FileRead(uint32(h), buf[:1]); rr >= 0 && n > 0 {
			return out, loadTooLarge
		}
	}
	return out, loadOkay
}

// drop is the M124a-2 (#2677) DropTarget: a delivered drag payload decodes
// through the same DecodeImage path load() uses and replaces the shown
// image — zoom and pan reset because the old geometry meant the old pixels.
// A nil payload is the seat's "no envelope" case, named like a refusal; the
// refused decodes name their shape, never a stack trace.
func (a *app) drop(offer tabapp.DragOffer) {
	if !a.applyDrop(offer) {
		return
	}
	a.pushTitle()
	a.draw()
	a.ta.Present()
}

// applyDrop is drop's testable half: decode, replace the shown image, and
// print the receipt. The chrome steps stay in the callback — a host test
// has no seat to repaint for.
func (a *app) applyDrop(offer tabapp.DragOffer) bool {
	data := offer.Blob
	if data == nil {
		vi.ConsoleLine(markerDrop + "no-payload")
		return false
	}
	im, anim, err := decodeForView(data)
	if err != nil {
		if errors.Is(err, webrender.ErrImageUnsupported) {
			tag := formatOfHeader(data).tag()
			if tag == "" || tag == "???" {
				tag = "format"
			}
			vi.ConsoleLine(markerDrop + "unsupported " + tag)
			return false
		}
		vi.ConsoleLine(markerDrop + "decode " + offer.Mime)
		return false
	}
	if im.Width*im.Height > pixelsMax {
		vi.ConsoleLine(markerDrop + "too-large")
		return false
	}
	// A new image ends the old animation's loop: cancel the arm and clear
	// the clock before the swap, so no deadline lands on the new file.
	a.stopPlay()
	a.img = im
	a.iw, a.ih = uint32(im.Width), uint32(im.Height)
	a.anim, a.frame = anim, 0
	a.fm = formatOfHeader(data)
	a.name = "drop:" + offer.Mime
	a.st = loadOkay
	a.unsupportedTag = ""
	a.zoomIdx = zoomDefaultIdx
	a.ox, a.oy = 0, 0
	vi.ConsoleLine(markerDrop + offer.Mime + " " + u32s(a.iw) + "x" + u32s(a.ih) +
		" bytes=" + vi.Itoa64(int64(len(data))))
	a.announceFrame()
	return true
}

// reportLoad prints the one marker that names how the load ended.
func (a *app) reportLoad() {
	switch a.st {
	case loadFailedOpen:
		vi.ConsoleLine(markerOpenErr)
	case loadFailedRead:
		vi.ConsoleLine(markerReadErr)
	case loadTooLarge:
		vi.ConsoleLine(markerTooLarge)
	case loadFailedDecode:
		vi.ConsoleLine(markerDecodeErr)
	case loadUnsupported:
		tag := a.unsupportedTag
		if tag == "" || tag == "???" {
			tag = "format"
		}
		vi.ConsoleLine(markerUnsupported + tag)
	}
}

// stepFrame is the M162a frame stepper: `.` forward, `,` back, wrapping.
// The shown image becomes the frame's own composite — every frame is the
// logical screen, so pan and zoom keep meaning. A single-frame GIF (or no
// GIF at all) makes the keys inert.
func (a *app) stepFrame(dir int) bool {
	if a.anim == nil || len(a.anim.Frames) < 2 {
		return false
	}
	a.setFrame(stepFrameIdx(a.frame, dir, len(a.anim.Frames)))
	a.announceFrame()
	return true
}

// setFrame shows frame i's own composite without a receipt — the stepper
// announces, playback does not (its evidence is the loop receipt; a line
// per tick would only drown it).
func (a *app) setFrame(i int) {
	a.frame = i
	f := &a.anim.Frames[i]
	a.img = &webrender.Image{Width: a.anim.Width, Height: a.anim.Height, Pix: f.Pix}
}

// --- playback (M170e) -------------------------------------------------------

// requestPlay is -play's arm: playback the APP would start on its own, so
// a11y.reduce_motion gates it (M177a #3142). With the row on, a multi-frame
// animation stays parked on frame 1 and the marker says why; without a
// playable animation there is no motion to reduce and nothing prints.
// Space is unaffected — togglePlay answers the user's own request.
func (a *app) requestPlay() {
	if a.reduceMotion && a.anim != nil && len(a.anim.Frames) >= 2 {
		vi.ConsoleLine(markerMotionReduced)
		return
	}
	a.togglePlay()
}

// settingsApply is one delivered settings notice (M177a #3142): theme and
// contrast repaint through theme.Current like the startup ApplySettings
// did; reduce_motion only re-arms the -play gate, so it reports no visual
// change. Returns whether the frame needs repainting.
func (a *app) settingsApply(key, value string) bool {
	switch key {
	case "theme":
		return theme.Set(value)
	case settings.A11yContrastKey:
		high, ok := settings.A11yContrast(value)
		if !ok || high == (theme.Contrast() == "high") {
			return false
		}
		theme.SetContrast(high)
		return true
	case settings.A11yReduceMotionKey:
		on, ok := settings.A11yReduceMotion(value)
		if !ok || on == a.reduceMotion {
			return false
		}
		a.reduceMotion = on
	}
	return false
}

// pollSettings drains one delivered settings notice per loop turn — the
// same shape browser's pollFontSize keeps. A refusal or a foreign key is
// just consumed; a repaint asks the caller to present.
func (a *app) pollSettings() bool {
	if !a.settingsWatch {
		return false
	}
	key, value, ok := settings.PollChange(uint32(a.ta.Win))
	if !ok {
		return false
	}
	return a.settingsApply(key, value)
}

// togglePlay is the space key: start playback on a multi-frame GIF, or
// pause it. Inert — like the stepper keys — when there is no animation to
// play. Resuming picks the current frame up with its own full delay; the
// loop clock excludes the pause, so elapsed_ms stays a frame-time number.
func (a *app) togglePlay() bool {
	if a.anim == nil || len(a.anim.Frames) < 2 {
		return false
	}
	if a.playing {
		a.pausePlay()
		return true // the status line's play/pause hint changed
	}
	a.playing = true
	a.playStretch = playNow()
	a.armPlay()
	return true
}

// armPlay points the one app timer at the current frame's delay. Re-arming
// replaces any pending arm (the kernel's own contract), so exactly one
// timer is ever in flight.
func (a *app) armPlay() {
	d := playDelayNs(a.anim.Frames[a.frame].Delay)
	a.playFireAt = playNow() + int64(d)
	_ = playArm(d)
}

// pausePlay freezes playback mid-loop: the armed timer is cancelled and
// the playing time so far is banked in playAccum, so a later resume
// continues the loop clock instead of restarting it.
func (a *app) pausePlay() {
	if !a.playing {
		return
	}
	a.playing = false
	a.playAccum += playNow() - a.playStretch
	_ = playCancel()
}

// stopPlay leaves playback entirely — the image under it went away (a
// drop), so the loop clock resets rather than carrying into a new file.
func (a *app) stopPlay() {
	a.pausePlay()
	a.playAccum = 0
}

// playTick is one TIMER event: advance a frame and re-arm with that
// frame's delay. Wrapping to frame 1 closes a loop — the receipt prints
// its frame count and playing-time milliseconds. A stray event while
// paused or animationless is consumed and ignored (the single app timer
// can only be ours, and a queued event can outlive its own cancel).
func (a *app) playTick() bool {
	if !a.playing || a.anim == nil || len(a.anim.Frames) < 2 {
		return false
	}
	now := playNow()
	a.setFrame(stepFrameIdx(a.frame, 1, len(a.anim.Frames)))
	if a.frame == 0 {
		a.playLastElapsed = a.playAccum + now - a.playStretch
		a.playAccum, a.playStretch = 0, now
		vi.ConsoleLine(markerPlay + "frames=" + vi.Itoa64(int64(len(a.anim.Frames))) +
			" elapsed_ms=" + vi.Itoa64(a.playLastElapsed/1_000_000))
	}
	a.armPlay()
	return true
}

// announceFrame prints the stepper's receipt: the 1-based index, the
// frame's delay in milliseconds (the GCE carries centiseconds), and the
// FNV-1a of the composited pixels.
func (a *app) announceFrame() {
	if a.anim == nil {
		return
	}
	f := &a.anim.Frames[a.frame]
	vi.ConsoleLine(markerFrame + vi.Itoa64(int64(a.frame+1)) + "/" +
		vi.Itoa64(int64(len(a.anim.Frames))) + " delay=" +
		vi.Itoa64(int64(f.Delay*10)) + " sum=" + hex64(frameSum(f.Pix)))
}

func (a *app) zoom() uint32 { return zoomTable[a.zoomIdx] }

func (a *app) viewport() viewport { return viewportRect(a.ta.W, a.ta.H) }

func (a *app) eventLoop() {
	for {
		// M124a-2: seat drag frames for this window — a delivered drop
		// runs DropTarget (which repaints) here, one poll per loop turn.
		a.ta.PollDrag()
		// M177a (#3142): one settings notice per loop turn, same cadence —
		// a theme/contrast notice repaints out of theme.Current.
		if a.pollSettings() {
			a.draw()
			a.ta.Present()
		}
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				// The window is gone: there is nobody left to repaint for.
				vi.ConsoleLine(markerWinClose)
				vi.ConsoleLine(markerOK)
				a.ta.CloseAndExit(exitQuit)
			}
			a.idleSleep()
			continue
		}
		switch a.ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			vi.ConsoleLine(markerWinClose)
			vi.ConsoleLine(markerOK)
			a.ta.CloseAndExit(exitQuit)
		case tabapp.ActionResized:
			// The canvas the WM granted, not the size we asked for: on the
			// tabbed desktop this is the full viewport, and it is the only
			// marker that proves the app relayouts to it (the `open` line
			// above reports the request).
			vi.ConsoleLine(markerResize + u32s(a.ta.W) + "x" + u32s(a.ta.H))
			a.recenterClamp()
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

// idleSleep parks one empty-queue pass for the next reason to wake.
// Paused, that's the whole scheduler tick — the pre-M170e contract. While
// playing it is the nanosecond doze ending at the next frame's deadline:
// event posts only wake wait_event waiters, never a sys_sleep park, so a
// tick-long sleep would bury every sub-second delay. The cap keeps a long
// frame's dwell from starving keys or drag frames; the floor lets a
// just-past deadline land its TIMER event instead of spinning.
func (a *app) idleSleep() {
	if !a.playing {
		vi.Sleep(1)
		return
	}
	rem := a.playFireAt - playNow()
	switch {
	case rem > playIdleCapNs:
		rem = playIdleCapNs
	case rem < playIdleMinNs:
		rem = playIdleMinNs
	}
	vi.SleepNs(uint64(rem))
}

// handle returns whether the screen needs repainting.
func (a *app) handle(ev vi.Event) bool {
	// TIMER is the app's own event, not the modal's: playback keeps
	// advancing under the save-as picker instead of stalling on an arm
	// nobody would re-issue.
	if ev.Kind == vi.EvTimer {
		return a.playTick()
	}
	if a.pick.Open {
		return a.pickerEvent(ev)
	}
	switch ev.Kind {
	case vi.EvKeyDown:
		switch ev.Arg0 {
		case keyZoomIn:
			return a.applyZoom(zoomIn)
		case keyZoomOut:
			return a.applyZoom(zoomOut)
		case keyReset:
			return a.applyZoom(zoomReset)
		case keyLeft:
			return a.panBy(-1, 0)
		case keyRight:
			return a.panBy(1, 0)
		case keyUp:
			return a.panBy(0, -1)
		case keyDown:
			return a.panBy(0, 1)
		case keyFrameNext:
			return a.stepFrame(1)
		case keyFramePrev:
			return a.stepFrame(-1)
		case keyPlay:
			return a.togglePlay()
		case keyCopy:
			a.copy()
			return false
		case keySave:
			return a.startSave()
		case keyQuitQ, keyEscape:
			vi.ConsoleLine(markerQuit)
			a.ta.CloseAndExit(exitQuit)
		}
	case vi.EvMouseDown:
		if ev.Flags&vi.BtnLeft == 0 {
			return false
		}
		a.drag = true
		a.dragX, a.dragY = int(ev.Arg0), int(ev.Arg1)
		a.dragOX, a.dragOY = a.ox, a.oy
	case vi.EvMouseMove:
		if a.drag {
			return a.dragPan(int(ev.Arg0), int(ev.Arg1))
		}
	case vi.EvMouseUp:
		a.drag = false
	}
	return false
}

// copy pushes the open file's bytes to the typed clipboard (M124c): the
// mime is read off the file's own magic — never the extension — so a PNG
// named "pic.qoi" still crosses as image/png. The kernel buffer's 512-byte
// bound is the cap; a bigger file is refused by name, not truncated into a
// half-decodeable blob. A refused slot (EACCES under the seat) lands on the
// marker like every other op here — the policy is the boundary.
func (a *app) copy() {
	refuse := func(why string) {
		vi.ConsoleLine(markerCopyRefuse + why)
	}
	if a.path == "" {
		refuse("empty")
		return
	}
	data, st := readImage(a.path)
	if st != loadOkay {
		refuse("read")
		return
	}
	var mime string
	switch formatOfHeader(data) {
	case fmtPNG:
		mime = vsys.ClipPNG
	case fmtQOI:
		mime = vsys.ClipQOI
	case fmtJPEG:
		mime = vsys.ClipJPEG
	case fmtGIF:
		mime = vsys.ClipGIF
	default:
		refuse("type")
		return
	}
	n, rc := vsys.ClipboardSetTyped(mime, data)
	if rc < 0 {
		vi.ConsoleLine(markerCopyRefuse + "rc=" + vi.Itoa64(rc))
		return
	}
	vi.ConsoleLine(markerCopy + "mime=" + mime + " n=" + vi.Itoa64(int64(n)))
}

// --- save-as (M162c) ----------------------------------------------------------

// startSave is the 's' key: the save-as picker over the loaded image. With
// nothing decoded there is nothing to save — refused like the copy path's
// "empty", never a silent no-op. The input starts blank: save-as names a NEW
// file, and a prefilled basename would only ever re-save the same name.
func (a *app) startSave() bool {
	if a.img == nil {
		vi.ConsoleLine(markerSaveRefuse + "empty")
		return false
	}
	dir := dirname(a.path)
	if dir == "" {
		dir = "/host"
	}
	a.pick = appkit.NewFilePicker(appkit.PickSave, dir)
	a.pick.Title = "Save as"
	// The plate assumes a roomy canvas; GOVIEW's window can be the 320x240
	// default, so clamp the picker inside what the window actually got.
	p := &a.pick
	p.R.W = min(p.R.W, int(a.ta.W))
	p.R.H = min(p.R.H, int(a.ta.H))
	p.R.X = max(min(p.R.X, int(a.ta.W)-p.R.W), 0)
	p.R.Y = max(min(p.R.Y, int(a.ta.H)-p.R.H), 0)
	vi.ConsoleLine(markerPick + "save")
	return true
}

// pickerEvent routes one event to the open picker — every key is the modal's
// while it is up (arrows walk rows, chars extend Input, Enter resolves,
// Escape cancels). The picker closing is itself a repaint, so done always
// redraws regardless of what the state machine reported.
func (a *app) pickerEvent(ev vi.Event) bool {
	var changed, done bool
	switch ev.Kind {
	case vi.EvKeyDown:
		changed, done = a.pick.HandleKey(ev)
	case vi.EvMouseDown:
		changed, done = a.pick.HandleMouse(int(ev.Arg0), int(ev.Arg1), true)
	}
	if done {
		a.pickerDone()
		return true
	}
	return changed
}

// pickerDone applies the picker's result: "cancel" gets the cancel receipt;
// a path is logged, then handed to saveAs which owns the format decision.
func (a *app) pickerDone() {
	res := a.pick.Result
	if res == "cancel" {
		vi.ConsoleLine(markerPick + "cancel")
		return
	}
	vi.ConsoleLine(markerPick + "save " + res)
	a.saveAs(res)
}

// saveAs writes the shown image under the name the picker produced. For an
// animated GIF that is the current frame's composite — a.img already holds
// it, so no special-casing the animation here. The extension picks the
// encoder; anything else is refused by name so a typo can never mint a file
// that lies about its format.
func (a *app) saveAs(path string) bool {
	if a.img == nil {
		vi.ConsoleLine(markerSaveRefuse + "empty")
		return false
	}
	var enc []byte
	var tag string
	switch saveFormat(path) {
	case fmtPNG:
		enc, tag = webrender.EncodePNG(a.img.Pix, int(a.iw), int(a.ih)), "png"
	case fmtQOI:
		enc, tag = qoi.Encode(a.img.Pix, int(a.iw), int(a.ih)), "qoi"
	default:
		vi.ConsoleLine(markerSaveRefuse + path)
		return false
	}
	if enc == nil {
		vi.ConsoleLine(markerSaveRefuse + "encode")
		return false
	}
	if rc := vi.WriteFileSafe(path, enc); rc != 0 {
		vi.ConsoleLine(markerSaveRefuse + "rc=" + vi.Itoa64(rc))
		return false
	}
	vi.ConsoleLine(markerSaved + path + " fmt=" + tag + " n=" +
		vi.Itoa64(int64(len(enc))) + " sum=" + hex64(frameSum(a.img.Pix)))
	return true
}

// pushTitle is VIEW.BIN's push_title: the window title carries the file, its
// dimensions, the format tag and the zoom. VIEW announced the FIRST successful
// push and re-pushed silently on every zoom change; so does this, through the
// slot-61 wrapper (vi.WinSetTitle) — on the tabbed desktop the tab's own title
// comes from the kind-8 declare instead, which is a separate path.
func (a *app) pushTitle() {
	if vi.WinSetTitle(a.ta.Win, a.titleText()) < 0 {
		return
	}
	if !a.titleAnnounced {
		a.titleAnnounced = true
		vi.ConsoleLine(markerTitleSet)
	}
}

// applyZoom steps the zoom table, re-clamps the pan and announces the new zoom.
// Returns false when the table would not move (both ends), so nothing repaints.
func (a *app) applyZoom(dir zoomDir) bool {
	idx := stepZoom(a.zoomIdx, dir)
	if idx == a.zoomIdx {
		return false
	}
	a.zoomIdx = idx
	a.recenterClamp()
	vi.ConsoleLine(markerZoom + u32s(a.zoom()) + "%")
	a.pushTitle()
	return true
}

func (a *app) recenterClamp() {
	if a.img == nil {
		return
	}
	vp := a.viewport()
	disp := displayedSize(a.iw, a.ih, a.zoom())
	a.ox = clampOrigin(a.ox, a.iw, disp.W, vp.W)
	a.oy = clampOrigin(a.oy, a.ih, disp.H, vp.H)
}

// panBy is VIEW.BIN's arrow pan: one display step is an eighth of the
// viewport, converted to image pixels at the current zoom.
func (a *app) panBy(ddx, ddy int32) bool {
	if a.img == nil {
		return false
	}
	vp := a.viewport()
	disp := displayedSize(a.iw, a.ih, a.zoom())
	sx := int32(maxU32(1, (vp.W*100/maxU32(1, disp.W))/8))
	sy := int32(maxU32(1, (vp.H*100/maxU32(1, disp.H))/8))
	nx := applyDelta(a.ox, ddx*sx, panMax(a.iw, disp.W, vp.W))
	ny := applyDelta(a.oy, ddy*sy, panMax(a.ih, disp.H, vp.H))
	if nx == a.ox && ny == a.oy {
		return false
	}
	a.ox, a.oy = nx, ny
	vi.ConsoleLine(markerPan + u32s(nx) + " oy=" + u32s(ny))
	return true
}

// dragPan is VIEW.BIN's drag pan: display pixels dragged back into image
// pixels at the current zoom, inverted (the image follows the pointer).
func (a *app) dragPan(curX, curY int) bool {
	if a.img == nil {
		return false
	}
	vp := a.viewport()
	disp := displayedSize(a.iw, a.ih, a.zoom())
	ddx := (curX - a.dragX) * 100 / int(maxU32(1, disp.W))
	ddy := (curY - a.dragY) * 100 / int(maxU32(1, disp.H))
	nx := applyDelta(a.dragOX, int32(-ddx), panMax(a.iw, disp.W, vp.W))
	ny := applyDelta(a.dragOY, int32(-ddy), panMax(a.ih, disp.H, vp.H))
	if nx == a.ox && ny == a.oy {
		return false
	}
	a.ox, a.oy = nx, ny
	vi.ConsoleLine(markerPan + u32s(nx) + " oy=" + u32s(ny))
	return true
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

// canvasSurface is the webrender.Surface the bound window canvas implements:
// one rect per span, Opaque at the boundary so the raster path writes the
// same bytes the kernel's fill batcher forced (it always made pixels X=ff).
// Text goes through webrender.DrawText so the viewer shares the seat's 8x8
// face instead of carrying a second glyph table.
type canvasSurface struct {
	cv widgets.Canvas
}

func (s *canvasSurface) Fill(x, y, w, h int, rgb uint32) {
	if w <= 0 || h <= 0 || x < 0 || y < 0 {
		return
	}
	s.cv.FillRect(widgets.Rect{X: x, Y: y, W: w, H: h}, draw.Opaque(rgb))
}

func (a *app) draw() {
	vp := a.viewport()
	cv := a.ta.Canvas()
	surf := &canvasSurface{cv: cv}
	// Window ground: the token table's Bg, so a resize never shows garbage.
	cv.FillRect(widgets.Rect{W: int(a.ta.W), H: int(a.ta.H)}, draw.Opaque(theme.Current.Bg))
	a.drawBackdrop(surf, vp)
	switch a.st {
	case loadOkay:
		a.blit(surf, vp)
	case loadNone:
		a.drawEmpty(surf, vp)
	default:
		a.drawError(surf, vp)
	}
	a.drawTitleBand(surf, vp)
	a.drawStatus(surf, vp)
	if a.pick.Open {
		a.pick.Draw(cv)
	}
}

// drawBackdrop is VIEW.BIN's checkerboard: transparent image pixels show it
// through, so "the file painted nothing here" is visible rather than black.
func (a *app) drawBackdrop(s *canvasSurface, vp viewport) {
	const cell uint32 = 8
	for cy := uint32(0); cy < vp.H; cy += cell {
		for cx := uint32(0); cx < vp.W; cx += cell {
			w := minU32(cell, vp.W-cx)
			h := minU32(cell, vp.H-cy)
			rgb := uint32(0x2a2a2a)
			if (cx/cell+cy/cell)%2 != 0 {
				rgb = 0x3a3a3a
			}
			s.Fill(int(vp.X+cx), int(vp.Y+cy), int(w), int(h), rgb)
		}
	}
}

// blit is a straight port of view.zig's blit_view: nearest-neighbour
// crop+scale from the pan origin, one span per same-colour run, transparent
// pixels skipped so the backdrop shows.
func (a *app) blit(s *canvasSurface, vp viewport) {
	if a.img == nil || a.iw == 0 || a.ih == 0 {
		return
	}
	disp := displayedSize(a.iw, a.ih, a.zoom())
	d := destLayout(vp, disp.W, disp.H)
	if d.W == 0 || d.H == 0 {
		return
	}
	imgW := uint32(a.img.Width)
	for dy := uint32(0); dy < d.H; dy++ {
		sy := a.oy + dy*a.ih/disp.H
		if sy >= a.ih {
			break
		}
		row := sy * imgW
		for dx := uint32(0); dx < d.W; {
			sx := a.ox + dx*a.iw/disp.W
			if sx >= a.iw {
				break
			}
			idx := row + sx
			if idx >= uint32(len(a.img.Pix)) {
				break
			}
			px := a.img.Pix[idx]
			if px>>24 == 0 {
				dx++
				continue
			}
			rgb := px & 0x00ffffff
			start := dx
			dx++
			for dx < d.W {
				sx2 := a.ox + dx*a.iw/disp.W
				if sx2 >= a.iw {
					break
				}
				idx2 := row + sx2
				if idx2 >= uint32(len(a.img.Pix)) {
					break
				}
				px2 := a.img.Pix[idx2]
				if px2>>24 == 0 || px2&0x00ffffff != rgb {
					break
				}
				dx++
			}
			s.Fill(int(d.X+start), int(d.Y+dy), int(dx-start), 1, rgb)
		}
	}
}

// titleText is what both the window title bar and the in-window title band
// show: the file and its facts when one is loaded, the app's name otherwise.
func (a *app) titleText() string {
	if a.name == "" {
		return appTitle
	}
	if a.st == loadOkay {
		return composeTitle(a.name, a.iw, a.ih, a.fm, a.zoom())
	}
	return a.name
}

func (a *app) drawTitleBand(s *canvasSurface, vp viewport) {
	s.Fill(0, 0, int(a.ta.W), titleBandH, theme.Current.Surface)
	s.Fill(0, titleBandH, int(a.ta.W), 1, theme.Current.Border)
	clip := webrender.Clip{X: 0, Y: 0, W: int(a.ta.W), H: titleBandH}
	webrender.DrawText(s, 4, 4, webrender.UpperASCII(a.titleText()), 1, false, theme.Current.Text, clip)
}

func (a *app) drawStatus(s *canvasSurface, vp viewport) {
	barY := int(vp.Y + vp.H)
	s.Fill(0, barY, int(a.ta.W), statusH, theme.Current.Surface)
	text := u32s(a.zoom()) + "%  +/- zoom  0 reset  arrows/drag pan  s save"
	if a.anim != nil && len(a.anim.Frames) > 1 {
		f := &a.anim.Frames[a.frame]
		text += "  ./, frame " + u32s(uint32(a.frame+1)) + "/" +
			u32s(uint32(len(a.anim.Frames))) + " - " + u32s(uint32(f.Delay*10)) + " ms"
		if a.playing {
			text += "  space pause"
		} else {
			text += "  space play"
		}
	}
	if a.st != loadOkay {
		text = loadSummary(a.st, a.name)
	}
	clip := webrender.Clip{X: 0, Y: barY, W: int(a.ta.W), H: statusH}
	webrender.DrawText(s, 4, barY+2, webrender.UpperASCII(text), 1, false, theme.Current.Muted, clip)
}

func (a *app) drawEmpty(s *canvasSurface, vp viewport) {
	centred(s, vp, 1, appName, theme.Current.Text)
	centred(s, vp, 2, "no image loaded", theme.Current.Muted)
	centred(s, vp, 3, "exec GOVIEW.ELF /host/FILE.QOI", theme.Current.Muted)
}

func (a *app) drawError(s *canvasSurface, vp viewport) {
	centred(s, vp, 1, "cannot open", theme.Current.Danger)
	centred(s, vp, 2, loadSummary(a.st, a.name), theme.Current.Muted)
	centred(s, vp, 3, "stay open - q quits", theme.Current.Muted)
}

// centred paints one line of the empty/error state. line 1 is the headline and
// is drawn in the accent-adjacent slot, the rest are body text.
func centred(s *canvasSurface, vp viewport, line int, text string, rgb uint32) {
	shown := webrender.UpperASCII(text)
	advance := font.Advance(1)
	if advance < 1 {
		advance = 1
	}
	width := advance * len(shown)
	y := int(vp.Y+vp.H/4) + (line-1)*20
	x := int(vp.X) + (int(vp.W)-width)/2
	if x < 0 {
		x = 0
	}
	clip := webrender.Clip{X: int(vp.X), Y: int(vp.Y), W: int(vp.W), H: int(vp.H)}
	webrender.DrawText(s, x, y, shown, 1, false, rgb, clip)
}

// loadSummary names the failure the way VIEW.BIN's error page did.
func loadSummary(st loadState, name string) string {
	switch st {
	case loadFailedOpen:
		return "open failed " + name
	case loadFailedRead:
		return "read failed " + name
	case loadTooLarge:
		return "file too large " + name
	case loadFailedDecode:
		return "decode failed " + name
	case loadUnsupported:
		return "no guest decoder for this format " + name
	}
	return name
}
