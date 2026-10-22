// rec.go — M118e (issue #2483): GOSOUND's record half. `record N out.wav`
// drives GOREC's flow — bounded slot-92 captures into one WAV body published
// crash-safe through vi.WriteFileSafe — with the mic meter live in the
// window; `meter [N]` is the meter alone, a bounded mic check that writes
// nothing.
//
// The markers mirror GOREC's contract under the gosound: prefix so the
// go-dogfood record leg reads like the sibling's: the cap report, the named
// refusal carrying the kernel's errno (ENXIO device-absent, ETIMEDOUT the
// bounded drain — the honest host-mic-denied outcome), the wrote receipt
// with frames/bytes/sha256, and `gosound: rec done` terminating EVERY path
// — the stage script needs one anchor, not two.
//
// A refused or stopped record writes NO file: the receipt is the refusal
// name, never a truncated WAV.
package main

import (
	"crypto/sha256"
	"errors"
	"strings"

	"virelai/pcm"
	"virelai/vi"
)

const (
	// recChunkBytes is the capture quantum: four RX periods ≈ 85 ms of the
	// v1 tuple — the meter's refresh rate and the bounded-read size, well
	// under the kernel's 64 KiB per-call ring bound.
	recChunkBytes = 8192

	// meterDefaultSeconds is the meter mode's run with no argument — the
	// mode is bounded by construction whether or not a window exists.
	meterDefaultSeconds = 10

	// levelPrintTicks bounds the level marker to at most one line per 12
	// chunks (~1 s) and only when the 10% bucket moved — serial stays
	// readable on a live mic instead of one line per 85 ms chunk. The
	// first reading always prints.
	levelPrintTicks = 12
)

// Record-mode markers — the record leg's gate surface. `gosound: cap` is
// the slot-91 report, `gosound: rec level=` is one meter tick reaching
// serial (bounded by levelPrintTicks), `gosound: rec done` terminates every
// path.
const (
	markerRec        = "gosound: rec secs="
	markerCap        = "gosound: cap "
	markerLevel      = "gosound: rec level="
	markerRecRefused = "gosound: rec refused "
	markerRecShort   = "gosound: rec short read "
	markerRecStopped = "gosound: rec stopped "
	markerRecWrote   = "gosound: rec wrote "
	markerRecWrite   = "gosound: rec write refused rc="
	markerRecDone    = "gosound: rec done"

	markerMeter        = "gosound: meter secs="
	markerMeterLevel   = "gosound: meter level="
	markerMeterRefused = "gosound: meter refused "
	markerMeterEnd     = "gosound: meter end "
	markerMeterDone    = "gosound: meter done"
)

// The syscall seams, as vars so host tests inject fakes (the gorec
// convention). The guest uses the vi bindings unchanged.
var (
	recQuery   = vi.AudioCapQuery
	recCap     = vi.AudioCapture
	recWrite   = vi.WriteFileSafe
	recMkdir   = recGuestMkdir
	recConsole = vi.ConsoleLine
)

// errRecShort is a capture that returned fewer bytes than it was handed —
// the kernel's contract is len-or-refusal, so a short read means the seam
// lied: a failure, not a file.
type errRecShort struct{ got, want int }

func (e *errRecShort) Error() string {
	return "short read got=" + vi.Itoa64(int64(e.got)) + " want=" + vi.Itoa64(int64(e.want))
}

// recState extends the window's playState machine with the record-side
// states — the capture run and the meter-only run.
const (
	stRecording playState = iota + 100
	stMetering
	stRecDone // record finished, file written
)

// recordMain is `GOSOUND.ELF record <seconds> <out.wav>`: GOREC's flow with
// the meter live. Returns the exit status main hands to vi.Exit — it never
// calls Exit itself, so the host corpus drives it end to end (no window on
// the host: tabapp.Init fails closed and the pump runs headless).
//
// `gosound: rec done` is the RUN's terminal marker — the stage script's one
// anchor — so it prints when the run reaches its outcome, not at process
// exit: a parked window would hold a deferred print hostage until quit.
func (a *app) recordMain(argv []string) int {
	secs, path, ok := parseRecArgs(argv)
	if !ok {
		recConsole(markerRecDone)
		return 2
	}
	a.mode = modeRecord
	a.name = basename(path)
	a.recSecs, a.recTotal = secs, pcm.CaptureBytes(secs)
	recConsole(markerRec + vi.Itoa64(int64(secs)) + " out=" + path)

	if !a.capInfo() {
		recConsole(markerRecDone)
		return 1
	}
	a.openWindow()
	a.st = stRecording
	a.draw()
	a.present()

	body := make([]byte, pcm.WavHeaderLen+a.recTotal)
	off, err := a.recPump(body[pcm.WavHeaderLen:], a.recTotal, markerLevel)

	rc := 1
	switch {
	case a.quit:
		recConsole(markerRecDone)
		a.quitApp()
	case errors.Is(err, errStopped):
		// A user stop is not a failure — the app did what it was asked;
		// the marker names it and no file is written.
		recConsole(markerRecStopped + "at=" + vi.Itoa64(int64(off)) +
			" of=" + vi.Itoa64(int64(a.recTotal)))
		a.st = stStopped
		rc = 0
	case err != nil:
		var sh *errRecShort
		if errors.As(err, &sh) {
			recConsole(markerRecShort + "got=" + vi.Itoa64(int64(sh.got)) +
				" want=" + vi.Itoa64(int64(sh.want)))
		} else {
			recConsole(markerRecRefused + err.Error() +
				" at=" + vi.Itoa64(int64(off)) +
				" of=" + vi.Itoa64(int64(a.recTotal)))
		}
		a.reason = "record failed"
		a.st = stRefused
	default:
		pcm.WriteWavHeader(body[:pcm.WavHeaderLen], a.recTotal)
		ensureRecDirs(path)
		if wrc := recWrite(path, body); wrc < 0 {
			recConsole(markerRecWrite + vi.Itoa64(wrc))
			a.reason = "write refused"
			a.st = stRefused
		} else {
			sum := sha256.Sum256(body)
			recConsole(markerRecWrote + path +
				" seconds=" + vi.Itoa64(int64(secs)) +
				" frames=" + vi.Itoa64(int64(pcm.CaptureFrames(a.recTotal))) +
				" bytes=" + vi.Itoa64(int64(a.recTotal)) +
				" peak=" + vi.Itoa64(int64(a.recPeak)) +
				" sha256=" + recHex(sum[:]))
			a.st = stRecDone
			rc = 0
		}
	}
	recConsole(markerRecDone)
	a.park()
	return rc
}

// meterMain is `GOSOUND.ELF meter [seconds]` — the mic meter alone, bounded
// by seconds (meterDefaultSeconds when the arg is absent). It captures the
// same chunks as record and discards them: no file is ever written.
func (a *app) meterMain(argv []string) int {
	secs, ok := parseMeterArgs(argv)
	if !ok {
		recConsole(markerMeterDone)
		return 2
	}
	a.mode = modeMeter
	a.recSecs, a.recTotal = secs, pcm.CaptureBytes(secs)
	recConsole(markerMeter + vi.Itoa64(int64(secs)))

	if !a.capInfo() {
		recConsole(markerMeterDone)
		return 1
	}
	a.openWindow()
	a.st = stMetering
	a.draw()
	a.present()

	off, err := a.recPump(nil, a.recTotal, markerMeterLevel)

	rc := 0
	switch {
	case a.quit:
		recConsole(markerMeterDone)
		a.quitApp()
	case errors.Is(err, errStopped):
		// A user stop on a meter is just an early done.
		a.st = stStopped
	case err != nil:
		recConsole(markerMeterRefused + err.Error() +
			" at=" + vi.Itoa64(int64(off)) +
			" of=" + vi.Itoa64(int64(a.recTotal)))
		a.reason = "meter refused"
		a.st = stRefused
		rc = 1
	default:
		recConsole(markerMeterEnd + "peak=" + vi.Itoa64(int64(a.recPeak)))
		a.st = stRecDone
	}
	recConsole(markerMeterDone)
	a.park()
	return rc
}

// capInfo prints the slot-91 capability report — the same fields GOREC's
// cap line carries, so both shapes of the record leg read alike.
func (a *app) capInfo() bool {
	info, err := recQuery()
	if err != nil {
		recConsole(markerCap + "err " + err.Error())
		return false
	}
	recConsole(markerCap + "ready=" + vi.Itoa64(int64(info.Ready)) +
		" fmt=" + vi.Itoa64(int64(info.Format)) +
		" rate=" + vi.Itoa64(int64(info.Rate)) +
		" ch=" + vi.Itoa64(int64(info.Channels)) +
		" period=" + vi.Itoa64(int64(info.PeriodBytes)) +
		" ring=" + vi.Itoa64(int64(info.RingBytes)))
	return true
}

// recPump captures `total` bytes in recChunkBytes pieces, updating the
// meter and servicing the window each chunk. dst == nil runs the meter
// without keeping the audio (meter mode). Returns the bytes captured and
// the refusal error (nil on completion), errStopped when the user stopped,
// or *errRecShort when the seam lied.
func (a *app) recPump(dst []byte, total int, levelMarker string) (int, error) {
	var scratch [recChunkBytes]byte
	off := 0
	for off < total {
		want := total - off
		if want > recChunkBytes {
			want = recChunkBytes
		}
		buf := scratch[:want]
		if dst != nil {
			buf = dst[off : off+want]
		}
		n, err := recCap(vi.AudioCapFormat, vi.AudioCapRate, vi.AudioCapChannels, buf)
		if err != nil {
			return off, err
		}
		if n != want {
			return off, &errRecShort{got: n, want: want}
		}
		off += n
		a.recGot = off
		a.noteLevel(pcm.ChunkLevel(buf[:n]), levelMarker)
		// service() consults recStop only when a window exists — the flag
		// check stands alone so a headless stop request still unwinds.
		if a.service() || a.recStop {
			return off, errStopped
		}
	}
	return off, nil
}

// noteLevel folds one chunk's reading into the meter: the live level, the
// run peak, a bounded level marker, and a repaint. The serial line prints
// the first reading always, then at most once per levelPrintTicks chunks
// and only when the 10% bucket moved.
func (a *app) noteLevel(level int, marker string) {
	a.recTicks++
	a.recLevel = level
	if level > a.recPeak {
		a.recPeak = level
	}
	bucket := level / 10
	if a.levelTick == 0 ||
		(bucket != a.levelBucket && a.recTicks-a.levelTick >= levelPrintTicks) {
		recConsole(marker + vi.Itoa64(int64(level)))
		a.levelBucket = bucket
		a.levelTick = a.recTicks
	}
	a.draw()
	a.present()
}

// park is the record/meter end state: windowed, hold the result on screen
// until quit (GOVIEW's error rule — eventLoop exits through quitApp);
// headless, return at once so the caller's status reaches vi.Exit.
func (a *app) park() {
	if a.ta == nil {
		return
	}
	a.draw()
	a.present()
	a.eventLoop()
}

// parseRecArgs validates `GOSOUND.ELF record <seconds 1..30> <out.wav>` —
// GOREC's argv contract behind the record verb. The order is the
// contract's: argv shape first, then the seconds bound, then the path root.
func parseRecArgs(argv []string) (int, string, bool) {
	if len(argv) != 4 {
		recConsole("gosound: rec usage: GOSOUND.ELF record <seconds 1.." +
			vi.Itoa64(int64(pcm.MaxRecordSeconds)) + "> <out.wav under /host or /disk>")
		return 0, "", false
	}
	secs, ok := pcm.ParseRecordSeconds(argv[2])
	if !ok {
		recConsole(markerRecRefused + "seconds=" + argv[2] + " (want 1.." +
			vi.Itoa64(int64(pcm.MaxRecordSeconds)) + ")")
		return 0, "", false
	}
	if why := pcm.ValidRecordPath(argv[3]); why != "" {
		recConsole(markerRecRefused + "path " + why)
		return 0, "", false
	}
	return secs, argv[3], true
}

// parseMeterArgs validates `GOSOUND.ELF meter [seconds 1..30]`; the bound
// defaults to meterDefaultSeconds.
func parseMeterArgs(argv []string) (int, bool) {
	if len(argv) < 2 || len(argv) > 3 {
		recConsole("gosound: meter usage: GOSOUND.ELF meter [seconds 1.." +
			vi.Itoa64(int64(pcm.MaxRecordSeconds)) + "]")
		return 0, false
	}
	if len(argv) == 2 {
		return meterDefaultSeconds, true
	}
	secs, ok := pcm.ParseRecordSeconds(argv[2])
	if !ok {
		recConsole(markerMeterRefused + "seconds=" + argv[2] + " (want 1.." +
			vi.Itoa64(int64(pcm.MaxRecordSeconds)) + ")")
		return 0, false
	}
	return secs, true
}

// ensureRecDirs best-effort creates each intermediate directory below the
// mount root so an unseeded share path lands (e.g. /host/GOSOUND). A refusal
// here is NOT reported: the file open after it names the real error.
func ensureRecDirs(filePath string) {
	segs := strings.Split(filePath, "/")
	cur := ""
	// segs[0] is "" and segs[1] is the mount root — never "created".
	for i := 2; i < len(segs)-1; i++ {
		cur += "/" + segs[i]
		// The kernel dir-create triple; EEXIST is a pass, and every other
		// answer is left for the WriteFileSafe open to report.
		_ = recMkdir("/" + segs[1] + cur)
	}
}

// recGuestMkdir is the kernel's directory create (MODE_WRITE|MODE_CREATE|
// MODE_DIR — the same triple gorec and selftest use): EEXIST means the dir
// was already there, not an error.
func recGuestMkdir(dir string) int64 {
	h, rc := vi.FileOpen(dir, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if rc >= 0 {
		vi.FileClose(uint32(h))
		return 0
	}
	if rc == vi.ErrFileExists {
		return 0
	}
	return rc
}

// recHex renders the receipt's sha256 without pulling encoding/hex into a
// guest image for 32 bytes.
func recHex(b []byte) string {
	const digs = "0123456789abcdef"
	out := make([]byte, len(b)*2)
	for i, c := range b {
		out[2*i] = digs[c>>4]
		out[2*i+1] = digs[c&0x0f]
	}
	return string(out)
}
