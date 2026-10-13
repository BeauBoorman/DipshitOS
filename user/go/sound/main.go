// Command sound is GOSOUND.ELF — M99c (issue #2181): the bounded WAV player
// for the `audio` mime type. Double-clicking a .wav in GOFILES lands here
// (mime.Register in virelai/mime's init names this binary for Audio).
//
// The shape is the card's: RIFF/WAVE is parsed as a stream (wav.go), the
// samples are converted and LINEARLY resampled into the mixer's negotiated
// tuple (pipe.go — the quality bound is named, never hidden), and playback
// is M99b's vi.AudioStream on slot 43. Memory is constant in the file's
// size: one read block, one output period, the resampler window.
//
// Every marker below is printed only AFTER the syscall it reports, so the
// live-sound-playback gate's asserts can only pass if the app really ran.
package main

import (
	"errors"
	"strings"

	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/webrender"
)

const (
	appName  = "GOSOUND.ELF"
	appTitle = "Sound Player"

	// The native presentation: a small bounded window (the tabbed desktop
	// re-canvases it full-viewport anyway via tabapp).
	winX, winY = 96, 80
	winW, winH = 344, 152

	titleBandH = 16
	statusH    = 14

	// readBlock is the one read buffer. It must hold several input frames
	// (the largest frame is 8 B) — 16 KiB keeps read syscalls rare without
	// ever growing with the file.
	readBlock = 16 * 1024

	// headPeek is the container sniff: enough for RIFF+WAVE, OggS, fLaC, ID3
	// and the raw MPEG sync word.
	headPeek = 16

	// drainBudget bounds the post-End status poll. pcm_guest.zig uses a 10 s
	// hardware-counter budget; an EL0 syscall plus a yield is on the order of
	// a microsecond, so this bound is the same order of wait without needing
	// a wall clock that may not exist (no-epoch boots).
	drainBudget = 20_000_000
)

// Marker lines — the gate surface. `gosound: refused` and
// `gosound: <container>: no decoder` are the named refusals; `gosound: done`
// carries the stream counters the gate asserts equal the file's expected
// post-resample byte count.
const (
	markerOpen        = "gosound: open id="
	markerTabAware    = "gosound: tab-aware (full-viewport)"
	markerNotTabAware = "gosound: not-tab-aware (shim or WND desktop)"
	markerOpenFailed  = "gosound: failed to open window"
	markerEmpty       = "gosound: empty (no args)"
	markerRefused     = "gosound: refused "
	markerOpenErr     = "gosound: open err"
	markerNoDevice    = "gosound: no audio device"
	markerMixerFull   = "gosound: mixer full"
	markerStreamErr   = "gosound: stream err "
	markerLoaded      = "gosound: loaded "
	markerOut         = "gosound: out "
	markerStreaming   = "gosound: streaming gen="
	markerStopped     = "gosound: stopped"
	markerDone        = "gosound: done "
	markerDrainFail   = "gosound: drain failed "
	markerQuit        = "gosound: quit"
	markerWinClose    = "gosound: win_close"
	markerOK          = "gosound OK"
)

// errStopped unwinds the pump when the user stops playback mid-stream. It is
// not an error worth reporting — Stop's own marker was already printed.
var errStopped = errors.New("stopped")

// playState is the UI state machine: what the window shows and which keys do
// what. refused covers every way a file can fail before a seat exists.
type playState int

const (
	stEmpty playState = iota
	stNoDevice
	stRefused
	stLoaded
	stPlaying
	stStopped
	stDone
)

type app struct {
	ta   *tabapp.TabApp
	name string // file basename, for the title band
	path string

	st     playState
	reason string // stRefused text

	info     WavInfo
	out      OutFmt
	inSecs   uint64 // input duration, whole seconds
	outSecs  uint64 // resampled duration
	position uint64 // output seconds submitted (playing position)

	stream *vi.AudioStream // nil when no seat is held
	quit   bool            // the event service saw quit/close
	stop   bool            // the event service saw stop
	started bool           // the seat went live (first period submitted)

	submitted uint64 // output bytes accepted this playback (position readout)
}

func main() {
	a := &app{st: stEmpty}
	path := argPath()
	a.path = path
	a.name = basename(path)

	// The verdicts first, window-independent: probe parses the file and
	// queries the device, and its markers are the contract whether or not a
	// display exists for a window to paint on. A headless boot (no
	// compositor) simply carries the same truth on the console.
	if path == "" {
		vi.ConsoleLine(markerEmpty)
	} else {
		a.st = a.probe(path)
	}

	a.openWindow()
	a.draw()
	a.present()

	switch {
	case a.st == stNoDevice:
		// The card's soundless-VM rule: say it once, exit clean.
		vi.ConsoleLine(markerNoDevice)
		a.exit(0)
	case a.st != stLoaded:
		// Empty and refused park in the window (GOVIEW's error rule) until
		// quit/close; headless, eventLoop exits at once.
		a.eventLoop()
		a.exit(0)
	}

	// stLoaded: play it. The pump services events through its sink, so the
	// window stays live while the file streams. Afterwards the app parks —
	// stopped/done can be re-armed with `p`, every state quits on q/close.
	a.play()
	for {
		a.draw()
		a.present()
		a.eventLoop()
		if a.st == stLoaded {
			a.play()
		}
	}
}

// openWindow is best-effort: no display means no window, and the console
// verdicts stand alone. Playback itself never needs the window — the pump
// works headless; draw/service/eventLoop no-op or exit when a.ta is nil.
func (a *app) openWindow() {
	ta := tabapp.Init(tabapp.Config{
		Name: appName, Title: titleOf(a.path),
		X: winX, Y: winY, W: winW, H: winH,
	})
	if ta == nil {
		vi.ConsoleLine(markerOpenFailed)
		return
	}
	a.ta = ta
	if ta.TabAware {
		vi.ConsoleLine(markerTabAware)
	} else {
		vi.ConsoleLine(markerNotTabAware)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)) + " " +
		vi.Itoa64(int64(ta.W)) + "x" + vi.Itoa64(int64(ta.H)))
}

// present flushes the window when one exists.
func (a *app) present() {
	if a.ta != nil {
		a.ta.Present()
	}
}

// exit closes the window when there is one and exits — the single point
// every clean-exit path funnels through.
func (a *app) exit(status int) {
	if a.ta != nil {
		a.ta.CloseAndExit(status)
	}
	vi.Exit(status)
}

// argPath is argv[1]: the canonical share path GOFILES hands handlers.
func argPath() string {
	args := vi.Args()
	if len(args) < 2 {
		return ""
	}
	return args[1]
}

// probe is everything before playback: sniff the container, parse the
// header, check the device, build the output tuple. Returns the state the
// window should show — stLoaded means a playable file and a live device.
func (a *app) probe(path string) playState {
	h, r := vi.FileOpen(path, vi.ModeRead)
	if r < 0 {
		vi.ConsoleLine(markerOpenErr)
		a.reason = "cannot open " + a.name
		return stRefused
	}
	var head [headPeek]byte
	n, rr := vi.FileRead(uint32(h), head[:])
	if rr < 0 || n <= 0 {
		vi.FileClose(uint32(h))
		vi.ConsoleLine(markerRefused + "unreadable")
		a.reason = "unreadable " + a.name
		return stRefused
	}
	if c := Container(a.name, head[:n]); c != "wav" {
		vi.FileClose(uint32(h))
		vi.ConsoleLine("gosound: " + c + ": no decoder")
		a.reason = c + ": no decoder"
		return stRefused
	}
	size := a.fileSize()
	src := catSource(head[:n], fileReader(uint32(h)))
	info, err := ParseWav(src, size)
	vi.FileClose(uint32(h))
	if err != nil {
		name := "unreadable"
		if errors.Is(err, ErrNeedMore) {
			name = "truncated header"
		}
		var we *WavError
		if errors.As(err, &we) {
			name = we.Name
			if we.Detail != 0 {
				name += " " + itoa(we.Detail)
			}
		}
		vi.ConsoleLine(markerRefused + name)
		a.reason = name
		return stRefused
	}
	a.info = info
	a.inSecs = info.Frames / uint64(info.Rate)

	// `loaded` reports the FILE's parse, so a soundless boot still shows the
	// header was read before "no audio device" closes.
	vi.ConsoleLine(markerLoaded + a.name + " fmt=" + tagName(info) +
		" ch=" + vi.Itoa64(int64(info.Channels)) + " rate=" + vi.Itoa64(int64(info.Rate)) +
		" frames=" + vi.Itoa64(int64(info.Frames)))

	// The device tuple is authoritative: the mixer does not resample, so the
	// seat must be opened in exactly what AudioQuery negotiated.
	q, err := vi.AudioQuery()
	if err != nil || q.Ready == 0 {
		return stNoDevice
	}
	out, ok := outFmt(q)
	if !ok {
		vi.ConsoleLine(markerStreamErr + "out fmt=" + vi.Itoa64(int64(q.Format)) +
			" rate=" + vi.Itoa64(int64(q.Rate)) + " ch=" + vi.Itoa64(int64(q.Channels)))
		a.reason = "unsupported output tuple"
		return stRefused
	}
	a.out = out
	p := NewPipe(info, out, readBlock, vi.AudioPeriodBytes, nil)
	a.outSecs = p.ExpectedFrames() / uint64(out.Rate)

	vi.ConsoleLine(markerOut + outName(out) +
		" rate=" + vi.Itoa64(int64(out.Rate)) + " ch=" + vi.Itoa64(int64(out.Channels)) +
		" frames=" + vi.Itoa64(int64(p.ExpectedFrames())))
	return stLoaded
}

// fileSize reads the entry's size through the paged directory listing — the
// only honest "how big is this path" seam at EL0 (there is no stat slot).
// Zero means unknown: the parser's data-beyond-eof check is skipped and the
// streamer's own byte count still enforces the declared size.
func (a *app) fileSize() uint64 {
	dir, base := splitDir(a.path)
	if dir == "" || base == "" {
		return 0
	}
	items, err := vi.ListDirAt(dir)
	if err != nil {
		return 0
	}
	for _, it := range items {
		if it.Name == base {
			return it.Size
		}
	}
	return 0
}

// play opens a mixer seat, streams the whole file through the pipe, and ends
// in stDone (drained), stStopped (user stop), or stRefused (mid-stream
// refusal — truncation surfaces here when the size check could not run).
// quit exits the process directly.
func (a *app) play() {
	h, r := vi.FileOpen(a.path, vi.ModeRead)
	if r < 0 {
		vi.ConsoleLine(markerOpenErr)
		a.st = stRefused
		return
	}
	// Re-parse to land at the data offset (the header walk is cheap and
	// keeps replay honest — a file that changed under us is refused fresh).
	src := fileReader(uint32(h))
	if _, err := ParseWav(src, 0); err != nil {
		vi.FileClose(uint32(h))
		vi.ConsoleLine(markerRefused + "re-parse")
		a.st = stRefused
		return
	}

	stream, err := vi.AudioStreamOpen(vi.AudioStreamParams{
		Format: a.out.Fmt, Rate: a.out.Code, Channels: uint8(a.out.Channels),
		Version: 1,
	})
	if err != nil {
		vi.FileClose(uint32(h))
		switch err {
		case vi.ErrNoAudioDevice:
			vi.ConsoleLine(markerNoDevice)
			a.st = stNoDevice
		case vi.ErrAudioStreamFull:
			vi.ConsoleLine(markerMixerFull)
			a.st = stRefused
			a.reason = "mixer full"
		default:
			vi.ConsoleLine(markerStreamErr + "open")
			a.st = stRefused
			a.reason = "stream open refused"
		}
		return
	}
	a.stream = stream
	a.stop, a.quit = false, false
	a.started = false
	a.position = 0
	a.submitted = 0
	a.st = stPlaying

	p := NewPipe(a.info, a.out, readBlock, vi.AudioPeriodBytes, a.submit)
	perr := p.Play(src)
	vi.FileClose(uint32(h))

	switch {
	case a.quit:
		// The service already aborted the seat; exit below.
	case errors.Is(perr, errStopped):
		a.stream = nil
		a.st = stStopped
	case perr != nil:
		stream.Abort()
		a.stream = nil
		var we *WavError
		if errors.As(perr, &we) {
			vi.ConsoleLine(markerRefused + we.Name)
		} else {
			vi.ConsoleLine(markerStreamErr + perr.Error())
		}
		a.st = stRefused
		a.reason = "stream failed"
	default:
		if !a.started {
			// A zero-frame file never submitted, so the seat is still idle
			// — free it with Abort (End's drain semantics assume live).
			stream.Abort()
			a.stream = nil
			vi.ConsoleLine(markerDone + "accepted=0 submitted=0 " +
				"completed=0 underruns=0 peak=1 clipped=0")
			a.st = stDone
		} else {
			a.st = a.finish()
		}
	}
	if a.quit {
		a.quitApp()
	}
}

// submit is the pipe's sink: one output period into the seat's bounded
// queue. The first accepted period arms the seat with Start (the kernel
// refuses Start on an empty queue); after that EAGAIN backpressure paces
// the pump — on EAGAIN the guest yields rather than churns. UI events are
// serviced here so the window stays live while the stream runs; a stop or
// quit unwinds Play through errStopped.
func (a *app) submit(period []byte) error {
	for {
		n, err := a.stream.Submit(period)
		if err == nil && n == len(period) {
			a.submitted += uint64(n)
			if !a.started {
				a.started = true
				if err := a.stream.Start(); err != nil {
					return err
				}
				vi.ConsoleLine(markerStreaming + vi.Itoa64(int64(a.stream.Generation())))
			}
			if a.service() {
				return errStopped
			}
			return nil
		}
		if err != nil && err != vi.ErrAudioBusy {
			return err
		}
		// Queue full or a short write: service the UI, yield, retry.
		if a.service() {
			return errStopped
		}
		vi.Yield()
	}
}

// finish closes the seat and waits for the mixer to drain it, then prints
// the counter line the gate asserts. pcm_guest's closed() is the reference:
// the post-close snapshot reads state 0 and outstanding 0 when the seat is
// already gone.
func (a *app) finish() playState {
	s := a.stream
	a.stream = nil
	if err := s.End(); err != nil {
		vi.ConsoleLine(markerDrainFail + "end")
		return stRefused
	}
	var st vi.AudioStreamStatus
	drained := false
	for i := 0; i < drainBudget; i++ {
		var err error
		st, err = s.Status()
		if err != nil {
			vi.ConsoleLine(markerDrainFail + "status")
			return stRefused
		}
		if st.State == 0 && st.Outstanding == 0 {
			drained = true
			break
		}
		// pcm.Model's numbering: 8 = resetting, 10 = quarantined (the values
		// pcm_guest's closed() bails on — the seat cannot drain from there).
		if st.State == 10 || st.State == 8 {
			vi.ConsoleLine(markerDrainFail + "st=" + vi.Itoa64(int64(st.State)) +
				" reason=" + vi.Itoa64(int64(st.Reason)))
			return stRefused
		}
		vi.Yield()
	}
	if !drained {
		vi.ConsoleLine(markerDrainFail + "timeout")
		return stRefused
	}
	vi.ConsoleLine(markerDone +
		"accepted=" + vi.Itoa64(int64(st.Accepted)) +
		" submitted=" + vi.Itoa64(int64(st.Submitted)) +
		" completed=" + vi.Itoa64(int64(st.Completed)) +
		" underruns=" + vi.Itoa64(int64(st.Underruns)) +
		" peak=" + vi.Itoa64(int64(st.PeakSources)) +
		" clipped=" + vi.Itoa64(int64(st.Clipped)))
	return stDone
}

// service drains the event queue once and refreshes the position readout.
// Returns true when the pump should stop (stop or quit/close). Headless
// there is no event source and nothing to repaint, so it no-ops.
func (a *app) service() bool {
	if a.ta == nil {
		return false
	}
	for {
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				a.quit = true
			}
			break
		}
		switch a.ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			a.quit = true
		case tabapp.ActionResized:
			a.draw()
			a.ta.Present()
		case tabapp.ActionNone:
			a.key(ev)
		}
	}
	pos := a.submitted / uint64(a.out.FrameBytes()) / uint64(a.out.Rate)
	if pos != a.position {
		a.position = pos
		a.draw()
		a.ta.Present()
	}
	return a.quit || a.stop
}

// HID usages (the file_browser/notepad key map): Arg0 is the physical key,
// not the character.
const (
	keyP      = 0x13
	keyQ      = 0x14
	keyS      = 0x16
	keyEnter  = 0x28
	keyEscape = 0x29
	keySpace  = 0x2c
)

// key handles raw keys the tab harness does not own. space/enter/p toggles
// play, s stops, q/esc quit — all after Dispatch, so M78 ctrl-chords (close
// / quit / Ctrl+Q) arrive through ActionClosed like everyone else's.
func (a *app) key(ev vi.Event) {
	if ev.Kind != vi.EvKeyDown {
		return
	}
	switch ev.Arg0 {
	case keyQ, keyEscape:
		a.quit = true
	case keyS:
		if a.st == stPlaying && a.stream != nil {
			a.stream.Abort()
			a.stream = nil
			vi.ConsoleLine(markerStopped)
			a.stop = true
		}
	case keySpace, keyP, keyEnter:
		if a.st == stStopped || a.st == stDone {
			a.st = stLoaded
		}
	}
}

// eventLoop is the parked loop (no live seat). Returns true only when a
// parked-state `play` should re-enter the pump. Headless there are no
// events to wait on — the parked states have nothing left to do, so it
// exits rather than blocking on a queue that can never fill.
func (a *app) eventLoop() bool {
	if a.ta == nil {
		a.exit(0)
	}
	for {
		ev, r := vi.WaitEvent()
		if r < 0 {
			vi.ConsoleLine(markerWinClose + " poll=" + vi.Itoa64(r))
			a.quitApp()
		}
		switch a.ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			a.quitApp()
		case tabapp.ActionResized:
			a.draw()
			a.present()
		case tabapp.ActionNone:
			a.key(ev)
			if a.quit {
				a.quitApp()
			}
			if a.st == stLoaded {
				return true
			}
		}
	}
}

// quitApp tears down a live seat and exits — every clean-exit path lands here.
func (a *app) quitApp() {
	if a.stream != nil {
		a.stream.Abort()
		a.stream = nil
	}
	vi.ConsoleLine(markerQuit)
	vi.ConsoleLine(markerOK)
	a.exit(0)
}

// ---------------------------------------------------------------------------
// Sources: the adapters between vi's file handles and the parser's byteSource.

// sysErr carries a raw negative kernel result through a byteSource's error
// return; its text is only ever logged, never matched on.
type sysErr int64

func (e sysErr) Error() string { return "sys " + vi.Itoa64(int64(e)) }

// fileReader adapts one open share handle to byteSource. A kernel short read
// just makes the next fill smaller; n<=0 is EOF; a refusal propagates.
func fileReader(h uint32) byteSource {
	return func(buf []byte) (int, error) {
		n, r := vi.FileRead(h, buf)
		if r < 0 {
			return n, sysErr(r)
		}
		if n <= 0 {
			return 0, nil
		}
		return n, nil
	}
}

// catSource serves the already-read sniff head first, then the rest of the
// file — the parser sees one continuous stream and no seek is needed.
func catSource(head []byte, rest byteSource) byteSource {
	off := 0
	return func(buf []byte) (int, error) {
		if off < len(head) {
			n := copy(buf, head[off:])
			off += n
			return n, nil
		}
		return rest(buf)
	}
}

// splitDir splits a canonical share path (/host/…) into the directory in the
// shell-canonical form ListDirAt wants (/-rooted, /host stripped) and the
// entry name.
func splitDir(path string) (canon, base string) {
	i := lastByte(path, '/')
	if i < 0 {
		return "/", path
	}
	base = path[i+1:]
	dir := path[:i]
	switch {
	case dir == "" || dir == "/host":
		canon = "/"
	case strings.HasPrefix(dir, "/host/"):
		canon = dir[len("/host"):]
	default:
		canon = dir
	}
	return canon, base
}

func basename(path string) string {
	if i := lastByte(path, '/'); i >= 0 {
		return path[i+1:]
	}
	return path
}

// titleOf is the title-band text: the player name plus the file's basename.
func titleOf(path string) string {
	if path == "" {
		return appTitle
	}
	return appTitle + ": " + basename(path)
}

// rateHzTable decodes a RATE_* code to Hz. Index = virtio-snd rate bit;
// the kernel's snd_rate_hz only negotiates the 8k..48k span, and the seat
// params carry the CODE verbatim regardless — this table is for the
// resampler, which needs the real Hz.
var rateHzTable = [...]uint32{
	5512, 8000, 11025, 16000, 22050, 32000, 44100, 48000,
	64000, 88200, 96000, 176400, 192000, 384000,
}

func rateHz(code uint8) uint32 {
	if int(code) < len(rateHzTable) {
		return rateHzTable[code]
	}
	return 0
}

// outFmt validates the negotiated tuple into the pipeline's OutFmt. The seat
// params get the kernel's codes verbatim (the mixer refuses anything that is
// not exactly what AudioQuery reported); the resampler gets the decoded Hz.
func outFmt(q vi.AudioInfo) (OutFmt, bool) {
	var o OutFmt
	switch q.Format {
	case vi.AudioFmtS16, vi.AudioFmtS32, vi.AudioFmtFloat:
		o.Fmt = q.Format
	default:
		return o, false
	}
	hz := rateHz(q.Rate)
	if hz == 0 || q.Channels < 1 || q.Channels > 2 {
		return o, false
	}
	o.Code, o.Rate, o.Channels = q.Rate, hz, uint16(q.Channels)
	return o, true
}

// tagName is the input format's display name ("pcm16", "float32").
func tagName(w WavInfo) string {
	if w.Tag == FormatFloat {
		return "float" + itoa(uint64(w.Bits))
	}
	return "pcm" + itoa(uint64(w.Bits))
}

// outName is the negotiated format's display name.
func outName(o OutFmt) string {
	switch o.Fmt {
	case fmtS16:
		return "s16"
	case fmtS32:
		return "s32"
	}
	return "f32"
}

// clock renders whole seconds as m:ss.
func clock(s uint64) string {
	m := itoa(s / 60)
	sec := s % 60
	if sec < 10 {
		return m + ":0" + itoa(sec)
	}
	return m + ":" + itoa(sec)
}

// ---------------------------------------------------------------------------
// Painting. The same shape as GOVIEW: a filler-backed webrender.Surface, the
// shared 8x8 face, one present per redraw.

type fillSurf struct {
	f   *vi.Filler
	win int
}

func (s *fillSurf) Fill(x, y, w, h int, rgb uint32) {
	if w <= 0 || h <= 0 || x < 0 || y < 0 {
		return
	}
	s.f.Rect(s.win, uint32(x), uint32(y), uint32(w), uint32(h), rgb)
}

func (a *app) draw() {
	if a.ta == nil {
		return
	}
	W, H := int(a.ta.W), int(a.ta.H)
	var f vi.Filler
	s := &fillSurf{f: &f, win: a.ta.Win}
	f.Rect(a.ta.Win, 0, 0, a.ta.W, a.ta.H, theme.Current.Bg)

	// Title band, then the body text below it.
	s.Fill(0, 0, W, titleBandH, theme.Current.Surface)
	s.Fill(0, titleBandH, W, 1, theme.Current.Border)
	webrender.DrawText(s, 6, 4, webrender.UpperASCII(titleOf(a.path)),
		1, false, theme.Current.Text, webrender.Clip{X: 0, Y: 0, W: W, H: titleBandH})

	body := webrender.Clip{X: 0, Y: titleBandH + 2, W: W, H: H - titleBandH - 2}
	line := func(n int, text string, rgb uint32) {
		webrender.DrawText(s, 8, titleBandH+10+n*14,
			webrender.UpperASCII(text), 1, false, rgb, body)
	}

	switch a.st {
	case stEmpty:
		line(1, "no file", theme.Current.Text)
		line(2, "exec GOSOUND.ELF /host/FILE.WAV", theme.Current.Muted)
	case stNoDevice:
		line(1, "no audio device", theme.Current.Danger)
	case stRefused:
		line(1, "cannot play "+a.name, theme.Current.Danger)
		line(2, a.reason, theme.Current.Muted)
	default:
		// Loaded/playing/stopped/done: the track line, the position readout
		// and a thin progress bar.
		line(0, a.name, theme.Current.Text)
		line(1, tagName(a.info)+" "+itoa(uint64(a.info.Channels))+"ch "+
			itoa(uint64(a.info.Rate))+"Hz -> "+outName(a.out)+" "+
			itoa(uint64(a.out.Rate))+"Hz", theme.Current.Muted)
		state := "playing"
		switch a.st {
		case stLoaded:
			state = "ready"
		case stStopped:
			state = "stopped"
		case stDone:
			state = "done"
		}
		line(2, clock(a.position)+" / "+clock(a.outSecs)+"  "+state,
			theme.Current.Text)
		// Progress bar: position over the expected output duration.
		barY := titleBandH + 10 + 3*14 + 6
		barW := W - 16
		s.Fill(8, barY, barW, 8, theme.Current.Border)
		if a.outSecs > 0 {
			w := int(a.position * uint64(barW) / a.outSecs)
			if w > barW {
				w = barW
			}
			s.Fill(8, barY, w, 8, theme.Current.Accent)
		}
		line(5, "p/space play  s stop  q quit", theme.Current.Muted)
		line(6, "resample: linear interp", theme.Current.Muted)
	}
	f.Flush()
}
