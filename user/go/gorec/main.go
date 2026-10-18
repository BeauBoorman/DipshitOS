// Command gorec is GOREC.ELF — M118d (issue #2482), card 4 of M118 "sound
// goes both ways": a recorder for the kernel's ONE capture stream.
//
//	exec GOREC.ELF <seconds> <out.wav>
//
// It records <seconds> of the v1 capture tuple (S16 / 48 kHz / mono — the
// only tuple sys_audio_rec, slot 92, accepts) into a proper RIFF/WAVE file
// published crash-safe through vi.WriteFileSafe (temp + fsync +
// delete/rename) at a path under /host (the share) or /disk (the data
// volume). The live-sound-record gate then reads the file on macOS and
// recomputes the header, the duration and the sha256 itself — capture
// correctness is byte-provable, not vibes.
//
// Bounded by construction, like the rest of M118:
//
//   - seconds is a positive integer capped at maxSeconds (the whole WAV
//     body is one WriteFileSafe publish, so duration bounds memory);
//   - each slot-92 call is capped at the kernel's 64 KiB ring, so N seconds
//     is a fixed ceil(N*96000/65536)-call loop — never a stream;
//   - every refusal passes through by name — ENXIO (no capture source),
//     ETIMEDOUT (the bounded drain: the honest host-mic-denied outcome),
//     ENOSPC (ring full), EIO (device-level), EINVAL/ENAMETOOLONG
//     (shape/cap). A refused record writes NO file: the receipt is the
//     refusal name, not a truncated WAV.
//
// Every marker is printed only AFTER the syscall it reports, so the gate's
// asserts can only pass when the app really ran. `gorec: done` terminates
// every path — the stage script needs one anchor, not two.
package main

import (
	"crypto/sha256"
	"strings"

	"virelai/vi"
)

const (
	// maxSeconds bounds the recording: the WAV body is one in-memory
	// WriteFileSafe publish, so duration IS the memory bound — 30 s of
	// S16/48k/mono is 2.88 MB, far inside the process map bound.
	maxSeconds = 30

	// maxPathLen leaves WriteFileSafe's one-byte "~" temp inside the
	// kernel's 64-byte file-table path cap (vi.go WriteFileSafe).
	maxPathLen = 63
)

// The syscall seams, as vars so host tests inject fakes (the gotabwm
// session.go convention). The guest uses the vi bindings unchanged.
var (
	capQuery  = vi.AudioCapQuery
	capture   = vi.AudioCapture
	writeFile = vi.WriteFileSafe
	mkdir     = guestMkdir
	console   = vi.ConsoleLine
	args      = vi.Args
)

func main() {
	vi.Exit(run(args()))
}

// run is the whole program as a testable function: it returns the exit
// status main passes to vi.Exit. `gorec: done` is deferred so EVERY exit
// path ends on the one anchor the gate's stage script waits for.
func run(argv []string) int {
	defer console("gorec: done")

	secs, path, ok := parseArgs(argv)
	if !ok {
		return 2
	}
	total := pcmBytes(secs)

	info, err := capQuery()
	if err != nil {
		console("gorec: info error " + err.Error())
		return 1
	}
	console("gorec: cap ready=" + vi.Itoa64(int64(info.Ready)) +
		" fmt=" + vi.Itoa64(int64(info.Format)) +
		" rate=" + vi.Itoa64(int64(info.Rate)) +
		" ch=" + vi.Itoa64(int64(info.Channels)) +
		" period=" + vi.Itoa64(int64(info.PeriodBytes)) +
		" ring=" + vi.Itoa64(int64(info.RingBytes)))

	// The WAV body is one allocation: header first, PCM captured in place
	// behind it — slot 92 copies the ring out straight into the file image,
	// so no second buffer and no copy ever exist.
	body := make([]byte, wavHeaderLen+total)
	for off := 0; off < total; {
		want := total - off
		if want > vi.AudioCapRingBytes {
			want = vi.AudioCapRingBytes
		}
		n, cerr := capture(vi.AudioCapFormat, vi.AudioCapRate,
			vi.AudioCapChannels, body[wavHeaderLen+off:wavHeaderLen+off+want])
		if cerr != nil {
			console("gorec: refused " + cerr.Error() +
				" at=" + vi.Itoa64(int64(off)) +
				" of=" + vi.Itoa64(int64(total)))
			return 1
		}
		if n != want {
			// The kernel's contract is len-or-refusal; a short read means
			// the seam lied, which is a failure, not a file.
			console("gorec: short read got=" + vi.Itoa64(int64(n)) +
				" want=" + vi.Itoa64(int64(want)))
			return 1
		}
		off += n
	}

	writeWavHeader(body[:wavHeaderLen], total)
	ensureDirs(path)
	if rc := writeFile(path, body); rc < 0 {
		console("gorec: write refused rc=" + vi.Itoa64(rc))
		return 1
	}

	sum := sha256.Sum256(body)
	console("gorec: wrote " + path +
		" seconds=" + vi.Itoa64(int64(secs)) +
		" frames=" + vi.Itoa64(int64(pcmFrames(total))) +
		" bytes=" + vi.Itoa64(int64(total)) +
		" sha256=" + hexLower(sum[:]))
	return 0
}

// parseArgs validates `GOREC.ELF <seconds> <out.wav>` and prints the named
// refusal on the bad shape. The order is the contract's: argv shape first,
// then the seconds bound, then the path root.
func parseArgs(argv []string) (int, string, bool) {
	if len(argv) != 3 {
		console("gorec: usage: GOREC.ELF <seconds 1.." +
			vi.Itoa64(int64(maxSeconds)) + "> <out.wav under /host or /disk>")
		return 0, "", false
	}
	secs, ok := parseSeconds(argv[1])
	if !ok {
		console("gorec: refused seconds=" + argv[1] + " (want 1.." +
			vi.Itoa64(int64(maxSeconds)) + ")")
		return 0, "", false
	}
	if why := validOutPath(argv[2]); why != "" {
		console("gorec: refused path " + why)
		return 0, "", false
	}
	return secs, argv[2], true
}

// parseSeconds is the bounded atoi for the duration argument: decimal digits
// only, in 1..maxSeconds. (No strconv — the fleet formats through vi.Itoa64.)
func parseSeconds(s string) (int, bool) {
	if s == "" || len(s) > 3 {
		return 0, false
	}
	v := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + int(c-'0')
	}
	if v < 1 || v > maxSeconds {
		return 0, false
	}
	return v, true
}

// validOutPath enforces the card's roots: a file path under /host or /disk
// that WriteFileSafe can publish — short enough for the "~" temp, no
// dot/empty segments, no control bytes. Returns "" on accept, else the
// refusal reason the marker prints.
func validOutPath(path string) string {
	root := strings.HasPrefix(path, "/host/") || strings.HasPrefix(path, "/disk/")
	if !root {
		return "outside /host or /disk"
	}
	if len(path) > maxPathLen {
		return "over path cap"
	}
	segs := strings.Split(path, "/")
	for _, seg := range segs[2:] { // ["", "host"|"disk", ...]
		if seg == "" || seg == "." || seg == ".." {
			return "bad segment"
		}
	}
	for i := 0; i < len(path); i++ {
		if path[i] < 0x20 || path[i] == 0x7f {
			return "control byte"
		}
	}
	return ""
}

// ensureDirs best-effort creates each intermediate directory below the
// mount root so an unseeded share path lands (e.g. /host/GOREC). A refusal
// here is NOT reported: the file open after it names the real error, the
// same posture selftest's mkdir takes with EEXIST.
func ensureDirs(filePath string) {
	segs := strings.Split(filePath, "/")
	cur := ""
	// segs[0] is "" and segs[1] is the mount root — never "created".
	for i := 2; i < len(segs)-1; i++ {
		cur += "/" + segs[i]
		// The kernel dir-create triple; EEXIST is a pass, and every other
		// answer is left for the WriteFileSafe open to report.
		_ = mkdir("/" + segs[1] + cur)
	}
}

// guestMkdir is the kernel's directory create (MODE_WRITE|MODE_CREATE|
// MODE_DIR — the same triple user/go/git and selftest use): -9 EEXIST means
// the dir was already there, not an error.
func guestMkdir(dir string) int64 {
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

// hexLower renders the receipt's sha256 without pulling encoding/hex into a
// guest image for 32 bytes.
func hexLower(b []byte) string {
	const digs = "0123456789abcdef"
	out := make([]byte, len(b)*2)
	for i, c := range b {
		out[2*i] = digs[c>>4]
		out[2*i+1] = digs[c&0x0f]
	}
	return string(out)
}
