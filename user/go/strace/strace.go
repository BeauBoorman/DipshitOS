// Package strace controls and renders the bounded ADR 0043 syscall tracer.
// It is shared by STRACE, the crash viewer and the combined observer.
package strace

import (
	"fmt"
	"strconv"
	"strings"

	"virelai/vi"
)

// Error retains a native errno magnitude, without a POSIX translation.
type Error struct{ Code int64 }

func (e Error) Error() string { return errno(uint32(e.Code), 0) }

func resultError(result int64) error {
	if result < 0 {
		return Error{Code: -result}
	}
	return nil
}

// Session is bound to the arming pid (M97g #2086), not merely the uid:
// a same-uid app cannot drive it even with a leaked token, and only
// CAP_PROC_ADMIN crosses the binding. The token is a CSPRNG mint.
// Opening another session invalidates it. Disarm retains unread records.
type Session struct{ Token uint64 }

func config(pids, slots []uint64) (vi.TraceConfig, error) {
	c := vi.TraceConfig{Version: vi.ObserveVersion}
	if len(pids) > vi.ObserveMaxPIDs {
		return c, Error{vi.ErrEINVAL}
	}
	c.PIDCount = uint32(len(pids))
	copy(c.PIDs[:], pids)
	if slots == nil {
		c.Slots = [2]uint64{^uint64(0), ^uint64(0)}
	} else {
		for _, slot := range slots {
			if slot >= 128 {
				return c, Error{vi.ErrEINVAL}
			}
			c.Slots[slot/64] |= uint64(1) << (slot % 64)
		}
	}
	return c, nil
}

// Arm observes exactly pids. Nil slots selects all 128 slots; an empty,
// non-nil slots slice selects none. An empty pid set supports ArmExec.
func Arm(pids, slots []uint64) (*Session, error) {
	c, err := config(pids, slots)
	if err != nil {
		return nil, err
	}
	result := vi.TraceOpen(c)
	if err = resultError(result); err != nil {
		return nil, err
	}
	if result == 0 {
		return nil, Error{vi.ErrEINVAL}
	}
	return &Session{Token: uint64(result)}, nil
}

// ArmExec opens an empty session, then atomically spawns and traces file.
// No child syscall can precede arming. On spawn failure the session is disarmed.
func ArmExec(file string, args []string, slots []uint64) (*Session, uint64, error) {
	session, err := Arm(nil, slots)
	if err != nil {
		return nil, 0, err
	}
	pid, err := session.Exec(file, args)
	if err != nil {
		_ = session.Disarm()
		return nil, 0, err
	}
	return session, pid, nil
}

// Exec adds an already-traced child to this active session.
func (s *Session) Exec(file string, args []string) (uint64, error) {
	result := vi.TraceExec(s.Token, file, args)
	if err := resultError(result); err != nil {
		return 0, err
	}
	return uint64(result), nil
}

func (s *Session) Filter(pids, slots []uint64) error {
	c, err := config(pids, slots)
	if err != nil {
		return err
	}
	return resultError(vi.TraceReplaceFilter(s.Token, c))
}

func (s *Session) Disarm() error {
	return resultError(vi.Trace(vi.TraceDisarm, s.Token, nil))
}

func (s *Session) Status() (vi.ObserveReadHeader, error) {
	header, result := vi.TraceGetStatus(s.Token)
	return header, resultError(result)
}

// Read returns a bounded batch and the cumulative dropped count.
func (s *Session) Read() ([]vi.TraceRecord, uint64, error) {
	header, records, result := vi.TraceReadBatch(s.Token)
	return records, header.Dropped, resultError(result)
}

// Drain is the read-render-print loop every consumer had open-coded
// (#3189's deduplicated pull): read until the ring answers an empty batch —
// or for at most maxBatches reads when maxBatches > 0 — rendering every
// record to the console. fn, when non-nil, observes each record after its
// line prints (the rendered line comes along so a caller retaining rows
// never renders twice) and may end the drain early by returning false. The
// returned count is the ring's cumulative dropped total from the last batch
// read.
func (s *Session) Drain(maxBatches int, fn func(vi.TraceRecord, string) bool) (uint64, error) {
	var dropped uint64
	for batch := 0; maxBatches <= 0 || batch < maxBatches; batch++ {
		records, loss, err := s.Read()
		if err != nil {
			return dropped, err // the failed read's header is zeroed; keep the last good total
		}
		dropped = loss
		for _, record := range records {
			line := Render(record)
			vi.ConsoleLine(line)
			if fn != nil && !fn(record, line) {
				return dropped, nil
			}
		}
		if len(records) == 0 {
			break
		}
	}
	return dropped, nil
}

func errno(code uint32, slot uint64) string {
	names := [...]string{"", "EINVAL", "EBADF", "EFAULT", "ENOSYS", "ENOSPC",
		"ENOENT", "EACCES", "ENAMETOOLONG", "ENXIO", "ENOMEM", "EAGAIN", "ETIMEDOUT"}
	if slot == 80 && code == 13 {
		return "PEER_RESET"
	}
	if slot == 80 && code == 14 {
		return "CLOSED"
	}
	if code == 9 && (slot == 23 || slot == 35 || slot == 79) {
		return "EEXIST"
	}
	if int(code) < len(names) && code != 0 {
		return names[code]
	}
	return "E" + strconv.FormatUint(uint64(code), 10)
}

func flags(slot uint64, index int, value uint64) string {
	var names []string
	take := func(bit uint64, name string) {
		if value&bit != 0 {
			names = append(names, name)
			value &^= bit
		}
	}
	switch {
	case slot == 20 && index == 1 && value <= 1:
		return [...]string{"HIDE", "SHOW"}[value]
	case slot == 45 && index == 0 && value <= 1:
		return [...]string{"UNMUTED", "MUTED"}[value]
	case slot == 53 && index == 1 && value <= 1:
		return [...]string{"SAVED", "UNSAVED"}[value]
	case slot == 23 && index == 2:
		take(1, "READ")
		take(2, "WRITE")
		take(4, "CREATE")
		take(8, "APPEND")
		take(16, "DIR")
	case slot == 35 && index == 1:
		take(uint64(1)<<63, "REPLACE")
	case slot == 28 && index == 3:
		take(uint64(1)<<63, "STREAMS")
	case slot == 27 && index == 3:
		switch value {
		case uint64(1)<<63 | 1:
			return "CURSOR_OPEN"
		case uint64(1)<<63 | 2:
			return "CURSOR_READ"
		case uint64(1)<<63 | 3:
			return "CURSOR_CLOSE"
		}
	case slot == 43 && index == 1:
		take(uint64(1)<<63, "AUDIO_STREAM")
	case slot == 63 && index == 2:
		take(1, "READ")
		take(2, "WRITE")
		take(4, "EXEC")
	case slot == 63 && index == 3:
		take(2, "PRIVATE")
		take(0x20, "ANON")
		take(0x8000, "POPULATE")
		take(0x10000, "SHARED")
	case slot == 69 && index == 2:
		for _, entry := range []struct {
			bit  uint64
			name string
		}{
			{0400, "OWNER_READ"}, {0200, "OWNER_WRITE"}, {0100, "OWNER_EXEC"},
			{0040, "GROUP_READ"}, {0020, "GROUP_WRITE"}, {0010, "GROUP_EXEC"},
			{0004, "OTHER_READ"}, {0002, "OTHER_WRITE"}, {0001, "OTHER_EXEC"},
		} {
			take(entry.bit, entry.name)
		}
	case slot == 76 && index == 1:
		take(1, "READ")
		take(2, "WRITE")
	}
	if value != 0 || len(names) == 0 {
		names = append(names, "0x"+strconv.FormatUint(value, 16))
	}
	return strings.Join(names, "|")
}

func argName(slot uint64, index int) string {
	switch slot {
	case 23:
		return [...]string{"path", "len", "flags"}[index]
	case 24, 25:
		return [...]string{"fd", "buf", "len"}[index]
	case 26, 77:
		return "fd"
	case 3:
		return "status"
	}
	return "arg" + strconv.Itoa(index)
}

// Render produces one escaped decoded line, with no trailing newline.
// Redaction depends on both the slot and flag, so malformed input cannot
// persuade the renderer to reveal the never-logged slots.
func Render(record vi.TraceRecord) string {
	name := "sys_" + strconv.FormatUint(record.Number, 10)
	if record.Number < uint64(len(vi.SyscallSlots)) {
		name = vi.SyscallSlots[record.Number].Name
	}
	prefix := fmt.Sprintf("[strace %d] %s(", record.PID, name)
	if record.Flags&vi.TraceRedacted != 0 || record.Number == 70 || record.Number == 71 {
		return prefix + "<redacted>)"
	}
	if record.Number >= uint64(len(vi.SyscallSlots)) {
		return prefix + ") = " + strconv.FormatInt(record.Result, 10)
	}
	shape := vi.SyscallSlots[record.Number]
	count, args := shape.ArgCount, shape.Args
	for _, variant := range vi.SyscallVariants {
		if uint64(variant.Number) == record.Number && record.Args[variant.Selector] == variant.Op {
			count, args = variant.ArgCount, variant.Args
			break
		}
	}
	decoded := make([]string, int(count))
	for i := range decoded {
		value := record.Args[i]
		var text string
		switch args[i].Kind {
		case vi.ArgPtr:
			text = "0x" + strconv.FormatUint(value, 16)
		case vi.ArgFlags:
			text = flags(record.Number, i, value)
		case vi.ArgString:
			bit := uint32(1) << i
			switch {
			case record.FaultMask&bit != 0:
				text = "<fault>"
			case record.StringMask&bit == 0 || record.StringLengths[i] > vi.TraceStringBytes:
				text = "<fault>"
			default:
				text = strconv.QuoteToASCII(string(record.Strings[i][:record.StringLengths[i]]))
				if record.TruncatedMask&bit != 0 {
					text += "…"
				}
			}
		case vi.ArgRedacted:
			text = "<redacted>"
		default:
			text = strconv.FormatInt(int64(value), 10)
		}
		decoded[i] = argName(record.Number, i) + "=" + text
	}
	result := strconv.FormatInt(record.Result, 10)
	if record.Flags&vi.TraceNoReturn != 0 {
		result = "<no-return>"
	} else if record.Errno != 0 {
		result = "-" + errno(record.Errno, record.Number)
	}
	return prefix + strings.Join(decoded, ", ") + ") = " + result
}
