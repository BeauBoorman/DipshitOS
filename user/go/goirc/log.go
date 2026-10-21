package main

// log.go — M152e (#2919): bounded per-channel logs on the host share.
// `/log on` arms a channel; every backlog line that lands on it while
// armed joins an in-memory retained set, flushed to
// /host/GOIRC/<net>-<chan>.LOG every logFlushEvery pending lines and on
// part or quit. The file channel has no append or seek, so a flush is a
// whole-file rewrite through WriteFileSafe — the retained set IS the
// file body, which is also how the 64 KiB cap is honest: the oldest
// lines drop first and the body opens with a `# truncated` header
// naming the loss instead of pretending the file is complete.

import (
	"errors"
	"strconv"
	"strings"

	"virelai/vi"
)

const (
	logDir        = "/host/GOIRC"
	logFlushEvery = 32        // lines between whole-file rewrites
	logMaxBytes   = 64 * 1024 // the file cap, header included
	logLineMax    = 1024      // one rendered line's byte bound
	logTruncMark  = "# truncated"
	logNetMax     = 20 // <net> file-name component bound
	logChanMax    = 24 // <chan> file-name component bound
)

// logHost is the injected platform seam (the goinfer host pattern):
// syscalls below, fakes in tests.
type logHost interface {
	// MkdirShare creates a /host directory (EEXIST is not an error).
	MkdirShare(path string) error
	// WriteShareFile publishes bytes through WriteFileSafe.
	WriteShareFile(path string, b []byte) error
}

type guestLogHost struct{}

func (guestLogHost) MkdirShare(path string) error {
	h, rc := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if rc == 0 {
		vi.FileClose(uint32(h))
		return nil
	}
	if rc == -9 { // EEXIST
		return nil
	}
	return errors.New("mkdir " + strconv.FormatInt(rc, 10))
}

func (guestLogHost) WriteShareFile(path string, b []byte) error {
	if rc := vi.WriteFileSafe(path, b); rc < 0 {
		return errors.New("publish " + strconv.FormatInt(rc, 10))
	}
	return nil
}

// sanitizeFilePart maps a net or channel name to a file-name component:
// uppercase, every non-alnum byte folded to '-', runs collapsed, edges
// stripped, bound bytes kept. An all-punctuation input falls back to
// "X" so the path is always well-formed.
func sanitizeFilePart(s string, bound int) string {
	var b []byte
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
		if !ok {
			if len(b) == 0 || b[len(b)-1] == '-' {
				continue
			}
			c = '-'
		} else if c >= 'a' && c <= 'z' {
			c -= 'a' - 'A'
		}
		b = append(b, c)
	}
	for len(b) > 0 && b[len(b)-1] == '-' {
		b = b[:len(b)-1]
	}
	if len(b) > bound {
		b = b[:bound]
		// A cut can leave a trailing '-' edge — strip it again.
		for len(b) > 0 && b[len(b)-1] == '-' {
			b = b[:len(b)-1]
		}
	}
	if len(b) == 0 {
		return "X"
	}
	return string(b)
}

// logPath is the channel's share file: /host/GOIRC/<net>-<chan>.LOG,
// bounded so WriteFileSafe's one-byte temp stays inside the kernel's
// 64-byte path cap (61 max + '~').
func logPath(net, ch string) string {
	return logDir + "/" + sanitizeFilePart(net, logNetMax) +
		"-" + sanitizeFilePart(ch, logChanMax) + ".LOG"
}

// formatLogLine renders one backlog Entry the way the scrollback paints
// it — a log file reads like the channel looked.
func formatLogLine(en Entry) string {
	switch en.Kind {
	case EntryMsg:
		return "<" + en.From + "> " + en.Text
	case EntryNotice:
		return "-" + en.From + "- " + en.Text
	case EntryJoin, EntryPart, EntryKick, EntryNick:
		return "* " + en.Text
	case EntryError:
		return "! " + en.Text
	default:
		return "= " + en.Text
	}
}

// chanLog is one channel's retained log: the newest lines that fit the
// 64 KiB file cap, plus the count pending since the last flush.
type chanLog struct {
	path      string
	lines     []string
	bytes     int // sum(len(line) + '\n') — the body sans header
	pending   int
	truncated bool
}

// hdrBytes is the header's share of the file body.
func (l *chanLog) hdrBytes() int {
	if l.truncated {
		return len(logTruncMark) + 1
	}
	return 0
}

// add appends one rendered line and enforces the cap: oldest lines drop
// until the body fits again (the `# truncated` header then says so).
// Returns true once logFlushEvery lines are pending.
func (l *chanLog) add(line string) bool {
	if len(line) > logLineMax {
		line = line[:logLineMax]
	}
	l.lines = append(l.lines, line)
	l.bytes += len(line) + 1
	l.pending++
	for l.bytes+l.hdrBytes() > logMaxBytes && len(l.lines) > 1 {
		l.bytes -= len(l.lines[0]) + 1
		l.lines = l.lines[1:]
		l.truncated = true
	}
	return l.pending >= logFlushEvery
}

// body is the whole-file rewrite payload.
func (l *chanLog) body() []byte {
	out := make([]byte, 0, l.bytes+l.hdrBytes())
	if l.truncated {
		out = append(out, logTruncMark...)
		out = append(out, '\n')
	}
	for _, s := range l.lines {
		out = append(out, s...)
		out = append(out, '\n')
	}
	return out
}

// flush publishes pending lines; a no-op flush is free (nothing new
// since the last write).
func (l *chanLog) flush(h logHost) error {
	if l.pending == 0 {
		return nil
	}
	if err := h.MkdirShare(logDir); err != nil {
		return err
	}
	if err := h.WriteShareFile(l.path, l.body()); err != nil {
		return err
	}
	l.pending = 0
	return nil
}

// logAdd routes one backlog entry into the channel's log when armed;
// the 32-line cadence and an own-PART close-out both flush here.
func (u *uiApp) logAdd(en Entry) {
	l := u.logs[en.Channel]
	if l == nil {
		return
	}
	if l.add(formatLogLine(en)) {
		u.flushLog(en.Channel)
		return
	}
	// Part close-out: our own PART is the last line the channel earns —
	// flush under the 32-line cadence too so it lands whole.
	if en.Kind == EntryPart && u.cli != nil && en.From == u.cli.Nick() {
		u.flushLog(en.Channel)
	}
}

// flushLog writes one channel's pending lines, naming the file in the
// marker so the gate reads the publish from the serial log. A chanLog
// with nothing pending never claims a write.
func (u *uiApp) flushLog(ch string) {
	l := u.logs[ch]
	if l == nil || u.logH == nil || l.pending == 0 {
		return
	}
	if err := l.flush(u.logH); err != nil {
		vi.ConsoleLine("goirc: log write-fail " + ch + " " + err.Error())
		u.status("log write failed for " + ch)
		return
	}
	vi.ConsoleLine("goirc: log write " + l.path)
}

// flushAllLogs writes every channel's pending lines — the quit path.
func (u *uiApp) flushAllLogs() {
	for _, ch := range u.bufs {
		u.flushLog(ch)
	}
}

// logVerb is the /log family: `/log on|off [#chan]` (default the
// focused channel); bare lists the armed channels.
func (u *uiApp) logVerb(rest string) {
	fields := strings.Fields(rest)
	if len(fields) == 0 {
		var on []string
		for _, ch := range u.bufs {
			if u.logs[ch] != nil {
				on = append(on, ch)
			}
		}
		if len(on) == 0 {
			u.status("log: no channels logging")
		} else {
			u.status("log: " + strings.Join(on, " "))
		}
		return
	}
	if len(fields) > 2 {
		u.status("usage: /log [on|off] [#channel]")
		return
	}
	ch := u.focusedBuf()
	if len(fields) == 2 {
		ch = fields[1]
	}
	if !isChannel(ch) {
		u.status("usage: /log [on|off] [#channel]")
		return
	}
	switch strings.ToLower(fields[0]) {
	case "on":
		if u.logs[ch] != nil {
			u.status("log: already on for " + ch)
			return
		}
		u.logs[ch] = &chanLog{path: logPath(u.cfg.Host, ch)}
		vi.ConsoleLine("goirc: log on " + ch)
		u.status("log: on for " + ch + " -> " + u.logs[ch].path)
	case "off":
		l := u.logs[ch]
		if l == nil {
			u.status("log: not on for " + ch)
			return
		}
		// Off is a close-out: pending lines flush before the channel
		// stops logging, so nothing recorded is silently dropped.
		u.flushLog(ch)
		delete(u.logs, ch)
		vi.ConsoleLine("goirc: log off " + ch)
		u.status("log: off for " + ch)
	default:
		u.status("usage: /log [on|off] [#channel]")
	}
}
