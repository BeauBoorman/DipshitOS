package main

// splitter frames the TCP byte stream into terminator-free lines under
// the 512 B cap. A run of >510 payload bytes without LF is not a line —
// feed reports overlong once and resynchronises at the next LF, so a
// hostile or broken peer cannot grow the buffer or smuggle a half-line
// into a message.
type splitter struct {
	buf      []byte
	overlong bool
}

// feed appends p and returns the complete lines (LF-terminated, CR
// stripped) plus whether at least one overlong run was discarded.
func (s *splitter) feed(p []byte) (lines []string, overlong bool) {
	for i := 0; i < len(p); i++ {
		c := p[i]
		if s.overlong {
			if c == '\n' {
				s.overlong = false
				overlong = true
				s.buf = s.buf[:0]
			}
			continue
		}
		if c == '\n' {
			line := s.buf
			if n := len(line); n > 0 && line[n-1] == '\r' {
				line = line[:n-1]
			}
			if len(line) > 0 {
				lines = append(lines, string(line))
			}
			s.buf = s.buf[:0]
			continue
		}
		s.buf = append(s.buf, c)
		if len(s.buf) > maxPayloadBytes {
			// Cap is on the payload share of the 512 B line (510 + CRLF);
			// cross it and the run is discarded until the next LF.
			s.overlong = true
		}
	}
	return lines, overlong
}
