// The shared record layer: one TLS 1.3 connection's AEAD machinery, keyed
// per direction. Both handshake drivers (client.go, server.go) ride this —
// the wire shape, the bounds, and the decrypt-fail-closed rule are the same
// on either side of the handshake.
//
// record layer bounds (RFC 8446 §5.2: length MUST NOT exceed 2^14 + 256).

package tls

// transport is the byte-stream a session drives (the vi.Conn seam in the
// guest; net.Conn in host tests).
type transport interface {
	// read returns at least one byte or an error; (0, nil) is EOF.
	read(p []byte) (int, error)
	// write writes all of p or returns an error.
	write(p []byte) (int, error)
	close() error
}

// session carries the connection state both peers share: the transcript,
// the per-direction traffic keys and sequence numbers, and the buffered
// record assembly. tlsState gates application data to stateConnected.
type session struct {
	t transport

	state      tlsState
	transcript sha256Digest

	hsBuf [maxHandshakeMsg]byte
	hsLen int

	// plainBuf is the decrypted-record scratch; pending holds the unread
	// tail of a record whose application data exceeded the caller's buffer.
	plainBuf [maxPlaintext]byte
	pending  []byte

	// Separate AES contexts per direction: the round keys are key-specific,
	// and the two peers' traffic keys differ.
	readCipher  *aes128
	writeCipher *aes128

	readKeys       trafficKeys
	writeKeys      trafficKeys
	readSeq        uint64
	writeSeq       uint64
	readEncrypted  bool
	writeKeysReady bool

	// handshake secrets kept for the application-key derivation
	handshakeSecret   [32]byte
	clientFinishedKey [32]byte
	serverFinishedKey [32]byte

	// The peer's last alert description byte, when one was seen (M135a:
	// named alerts ride the log line, not a bare ErrAlertReceived).
	peerAlert    byte
	hasPeerAlert bool
}

// sendRecord frames one record. Before write keys exist the payload goes
// out as a plaintext record carrying its own content type (handshake, or
// alert when the peer must be told a negotiation failed); after, the outer
// type is always application_data and the payload is the AEAD-protected
// inner record.
func (s *session) sendRecord(payload []byte, inner byte) error {
	if !s.writeKeysReady {
		buf := make([]byte, recordHeaderLen+len(payload))
		buf[0] = inner
		buf[1] = 0x03
		buf[2] = 0x03
		buf[3] = byte(len(payload) >> 8)
		buf[4] = byte(len(payload))
		copy(buf[recordHeaderLen:], payload)
		_, err := s.t.write(buf)
		return err
	}
	innerBuf := make([]byte, len(payload)+1)
	copy(innerBuf, payload)
	innerBuf[len(payload)] = inner

	ctLen := len(innerBuf) + 16
	out := make([]byte, recordHeaderLen+ctLen)
	out[0] = ctApplicationData
	out[1] = 0x03
	out[2] = 0x03
	out[3] = byte(ctLen >> 8)
	out[4] = byte(ctLen)
	nonce := recordNonce(&s.writeKeys.iv, s.writeSeq)
	// The 5-byte record header is the AAD (RFC 8446 §5.2).
	if err := gcmSeal(s.writeCipher, out[recordHeaderLen:], innerBuf, out[:recordHeaderLen], nonce[:]); err != nil {
		return err
	}
	s.writeSeq++
	_, werr := s.t.write(out)
	return werr
}

// sendAlert puts one fatal alert on the wire — plaintext before the write
// keys exist, AEAD-protected after (RFC 8446 §6). The peer's answer is not
// waited for; the caller closes.
func (s *session) sendAlert(desc byte) error {
	return s.sendRecord([]byte{alertLevelFatal, desc}, ctAlert)
}

// readRecord reads and decrypts one record into s.plainBuf. A
// change_cipher_spec is consumed and reported as length 0.
func (s *session) readRecord() (int, byte, error) {
	var hdr [recordHeaderLen]byte
	if err := s.readAll(hdr[:]); err != nil {
		return 0, 0, err
	}
	ct := hdr[0]
	l := int(hdr[3])<<8 | int(hdr[4])
	if l > maxCiphertext {
		return 0, 0, errRecordTooLarge
	}
	rec := make([]byte, recordHeaderLen+l)
	copy(rec, hdr[:])
	if err := s.readAll(rec[recordHeaderLen:]); err != nil {
		return 0, 0, err
	}

	if ct == ctChangeCipherSpec {
		return 0, ctChangeCipherSpec, nil
	}
	if ct == ctAlert {
		if s.readEncrypted {
			// Alerts are AEAD-protected once keys are installed; an
			// unauthenticable alert is still an alert (fail closed).
			var innerType byte
			if pt, err := s.openRecord(rec, &innerType); err == nil && len(pt) >= 2 {
				s.peerAlert, s.hasPeerAlert = pt[1], true
			}
			return 0, 0, ErrAlertReceived
		}
		if l >= 2 {
			s.peerAlert, s.hasPeerAlert = rec[recordHeaderLen+1], true
		}
		return 0, 0, ErrAlertReceived
	}
	if !s.readEncrypted {
		copy(s.plainBuf[:l], rec[recordHeaderLen:recordHeaderLen+l])
		return l, ct, nil
	}
	var innerType byte
	pt, err := s.openRecord(rec, &innerType)
	if err != nil {
		return 0, 0, ErrRecordDecryptFailed // AEAD failure: fail closed
	}
	s.readSeq++
	copy(s.plainBuf[:len(pt)], pt)
	return len(pt), innerType, nil
}

// openRecord decrypts an AEAD record: TLSInnerPlaintext = content || type ||
// zeros, the type is the last non-zero byte.
func (s *session) openRecord(rec []byte, innerType *byte) ([]byte, error) {
	if len(rec) < recordHeaderLen+1+16 {
		return nil, errTruncatedRecord
	}
	declared := int(rec[3])<<8 | int(rec[4])
	if declared != len(rec)-recordHeaderLen {
		return nil, errTruncatedRecord
	}
	if rec[0] != ctApplicationData {
		return nil, errInnerTypeBad
	}
	ctLen := declared - 16
	nonce := recordNonce(&s.readKeys.iv, s.readSeq)
	pt := make([]byte, ctLen)
	// The AEAD input is the full ciphertext||tag; the 5-byte header is the AAD.
	if err := gcmOpen(s.readCipher, pt, rec[recordHeaderLen:recordHeaderLen+declared], rec[:recordHeaderLen], nonce[:]); err != nil {
		return nil, err
	}
	end := ctLen
	for end > 0 && pt[end-1] == 0 {
		end--
	}
	if end == 0 {
		return nil, errInnerTypeMissing
	}
	t := pt[end-1]
	switch t {
	case ctHandshake, ctApplicationData, ctAlert, ctChangeCipherSpec:
	default:
		return nil, errInnerTypeBad
	}
	*innerType = t
	return pt[:end-1], nil
}

// readAll fills p (the transport may return short reads — the vi.Conn seam
// caps at one 192-byte kernel segment).
func (s *session) readAll(p []byte) error {
	off := 0
	for off < len(p) {
		n, err := s.t.read(p[off:])
		if err != nil {
			return err
		}
		if n == 0 {
			return errTransport
		}
		off += n
	}
	return nil
}

// feedHandshake appends decrypted bytes and processes every complete
// handshake message through the caller's state machine.
func (s *session) feedHandshake(chunk []byte, process func(msgType byte, msg []byte) error) error {
	if s.hsLen+len(chunk) > len(s.hsBuf) {
		return errHandshakeTooLarge
	}
	copy(s.hsBuf[s.hsLen:], chunk)
	s.hsLen += len(chunk)

	off := 0
	for s.hsLen-off >= 4 {
		msgType := s.hsBuf[off]
		total := 4 + (int(s.hsBuf[off+1])<<16 | int(s.hsBuf[off+2])<<8 | int(s.hsBuf[off+3]))
		if s.hsLen-off < total {
			break
		}
		msg := s.hsBuf[off : off+total]
		if err := process(msgType, msg); err != nil {
			return err
		}
		off += total
	}
	if off > 0 {
		copy(s.hsBuf[:], s.hsBuf[off:s.hsLen])
		s.hsLen -= off
	}
	return nil
}

// write sends application data (one AEAD record; callers chunk).
func (s *session) write(data []byte) error {
	if !s.state.allowsApplicationData() {
		return ErrNotConnected
	}
	if len(data) > maxPlaintext {
		return errRecordTooLarge
	}
	return s.sendRecord(data, ctApplicationData)
}

// read returns application data, absorbing post-handshake handshake messages
// (NewSessionTicket and friends) transparently. A record larger than out
// keeps its unread tail in s.pending for the next read.
func (s *session) read(out []byte) (int, error) {
	if !s.state.allowsApplicationData() {
		return 0, ErrNotConnected
	}
	for {
		if len(s.pending) > 0 {
			if len(out) == 0 {
				return 0, nil
			}
			take := len(s.pending)
			if take > len(out) {
				take = len(out)
			}
			copy(out, s.pending[:take])
			s.pending = s.pending[take:]
			if len(s.pending) == 0 {
				s.pending = nil
			}
			return take, nil
		}
		n, inner, err := s.readRecord()
		if err != nil {
			return 0, err
		}
		switch inner {
		case ctChangeCipherSpec:
			continue
		case ctApplicationData:
			if len(out) == 0 {
				return 0, nil
			}
			take := n
			if take > len(out) {
				take = len(out)
			}
			copy(out, s.plainBuf[:take])
			if take < n {
				rest := make([]byte, n-take)
				copy(rest, s.plainBuf[take:n])
				s.pending = rest
			}
			return take, nil
		case ctHandshake:
			continue
		case ctAlert:
			if n == 2 && s.plainBuf[1] == 0 {
				return 0, errStreamClosed // authenticated close_notify
			}
			return 0, ErrAlertReceived
		}
	}
}

// close sends a close_notify alert and closes the transport.
func (s *session) close() error {
	if s.state == stateConnected {
		_ = s.sendRecord([]byte{1, 0}, ctAlert) // close_notify
	}
	s.state = stateClosed
	return s.t.close()
}
