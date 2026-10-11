package shlib

// session.go — M98h (issue #2134): the four session-polish pieces that share
// one implementation between GOSH and GOTERM — the tab-title tracker, the
// Ctrl-X Ctrl-E round trip through GOEDIT.ELF, and the duration formatter
// `time` and the `\D` prompt escape both print.

import (
	"errors"
	"strings"
	"unicode/utf8"

	"virelai/vi"
	"virelai/vsys"
)

// timeMono is the monotonic clock `time`, `\D` and EditLine's unique temp
// name share. Replaceable in host tests so durations are deterministic
// (the dateMonotonic pattern).
var timeMono = vi.Nanos

// --- tab title -------------------------------------------------------------

// TitleFor builds the tab title for one shell front-end: "<prefix> — <tail>"
// where tail is the same basename `\W` prints ("/" at the share root). The
// wm_rpc title budget is 24 bytes; an overlong tail is cut on a rune
// boundary, never mid-rune.
func TitleFor(prefix, pwd string) string {
	t := prefix + " — " + baseName(pwd)
	if len(t) <= vi.WmRpcTitleMax {
		return t
	}
	n := vi.WmRpcTitleMax
	for n > 0 && !utf8.RuneStart(t[n]) {
		n--
	}
	return t[:n]
}

// TitleSync dedups SetTabTitle sends for one session: the front-end calls
// Sync after every RunLine and it invokes send only when the wanted title
// differs from the last one acked. A refused ack (send == false) leaves the
// tracker unsent, so the next RunLine retries without a loop.
type TitleSync struct{ sent string }

// Sync sends want through send when it differs from the last acked title.
// send nil — no hosted seat, a serial/net front-end — is a no-op.
func (t *TitleSync) Sync(want string, send func(string) bool) {
	if send == nil || want == t.sent {
		return
	}
	if send(want) {
		t.sent = want
	}
}

// --- Ctrl-X Ctrl-E ---------------------------------------------------------

// editApp is the external editor EditLine round-trips through. It is a var
// only so tests can pin the exec name without a string search.
const editApp = "GOEDIT.ELF"

// EditLine writes line to a temp file unique to this shell instance, runs
// GOEDIT.ELF on it through the interruptible foreground wait (Ctrl-C
// abandons the edit), reads the file back and returns its non-empty lines.
// Whatever the file holds when GOEDIT exits runs — unsaved lines and all;
// an empty file runs nothing. The temp is always removed.
//
// A failure leaves the editor buffer to the caller: the front-end prints
// `gosh: edit: <reason>; line not run` and puts the original line back.
func (s *Shell) EditLine(line string) ([]string, error) {
	path := s.editTempPath()
	if err := s.host.WriteFile(path, []byte(line+"\n"), false); err != nil {
		return nil, err
	}
	defer s.host.DeleteFile(path)
	pid, err := s.host.RunExternal(editApp, []string{path})
	if err != nil {
		return nil, errors.New(editApp + " not found")
	}
	var st int
	if intr := s.ttyPoll(); intr != nil {
		var killed bool
		st, killed = s.waitForeground(editApp, pid, intr)
		if killed {
			return nil, errors.New("interrupted")
		}
	} else {
		st64, werr := s.host.WaitExternal(pid)
		if werr != nil {
			return nil, errors.New("wait failed")
		}
		st = int(st64)
	}
	if st != 0 {
		return nil, errors.New(editApp + " exited " + vsys.Itoa64(int64(st)))
	}
	b, err := s.host.ReadFile(path, maxSourceBytes)
	if err != nil {
		return nil, err
	}
	var lines []string
	for _, ln := range strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n") {
		ln = strings.TrimRight(ln, "\r")
		if strings.TrimSpace(ln) != "" {
			lines = append(lines, ln)
		}
	}
	return lines, nil
}

// editTempPath names EditLine's scratch file. The name carries the shell
// counter and the monotonic clock, so two shells on one share — GOSH on
// serial and GOTERM in a window — never collide, and it sits hidden so a
// mid-edit listing does not show it. At ~20 bytes it is far inside the
// kernel's 64-byte path cap (and WriteFileSafe's one-byte sibling).
func (s *Shell) editTempPath() string {
	s.editSeq++
	return "/host/.GEDIT" + vsys.Itoa64(timeMono()) + "-" + vsys.Itoa64(int64(s.editSeq)) + ".TMP"
}

// --- durations --------------------------------------------------------------

// formatDuration is the `\D` prompt face: 0.4s under ten seconds, 12s under
// a minute, 3m04s under an hour, 1h02m past it.
func formatDuration(ns int64) string {
	if ns < 0 {
		ns = 0
	}
	sec := ns / 1_000_000_000
	switch {
	case sec < 10:
		return vsys.Itoa64(sec) + "." + vsys.Itoa64(ns%1_000_000_000/100_000_000) + "s"
	case sec < 60:
		return vsys.Itoa64(sec) + "s"
	case sec < 3600:
		return vsys.Itoa64(sec/60) + "m" + twoDigit(sec%60) + "s"
	default:
		return vsys.Itoa64(sec/3600) + "h" + twoDigit(sec/60%60) + "m"
	}
}

// formatReal is `time`'s report line: centisecond seconds, the card's
// `real 0.42s` shape, at every magnitude.
func formatReal(ns int64) string {
	if ns < 0 {
		ns = 0
	}
	return vsys.Itoa64(ns/1_000_000_000) + "." + twoDigit(ns%1_000_000_000/10_000_000) + "s"
}

func twoDigit(n int64) string {
	if n < 10 {
		return "0" + vsys.Itoa64(n)
	}
	return vsys.Itoa64(n)
}
