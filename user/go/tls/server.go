// TLS 1.3 server — the M135a (#2763) second half of the state machine.
// Same single-suite scope as the client (TLS_AES_128_GCM_SHA256 + X25519,
// RFC 8446 §9.1), an Ed25519 CertificateVerify signed by the configured
// seed, and every handshake failure closed with a named alert. Session
// tickets, PSK, 0-RTT, client certificates, and HelloRetryRequest are out
// of scope by the card: a ClientHello that needs an HRR (no X25519 share)
// is refused, never retried.
//
// The record layer is the client's own (session.go): the wire shape, the
// key schedule, and the decrypt-fail-closed rule do not differ by side.

package tls

import (
	"errors"

	"virelai/ed25519"
)

// Alert description bytes (RFC 8446 §6), the names the gate greps for.
const (
	alertLevelFatal            = 2
	alertDescCloseNotify       = 0
	alertDescUnexpectedMessage = 10
	alertDescBadRecordMAC      = 20
	alertDescHandshakeFailure  = 40
	alertDescIllegalParameter  = 47
	alertDescDecodeError       = 50
	alertDescDecryptError      = 51
	alertDescProtocolVersion   = 70
	alertDescInternalError     = 80
	alertDescMissingExtension  = 109
)

// alertName is the wire name a description byte carries (the serial-log
// spelling the live-httpd HTTPS legs assert).
func alertName(desc byte) string {
	switch desc {
	case alertDescCloseNotify:
		return "close_notify"
	case alertDescUnexpectedMessage:
		return "unexpected_message"
	case alertDescBadRecordMAC:
		return "bad_record_mac"
	case alertDescHandshakeFailure:
		return "handshake_failure"
	case alertDescIllegalParameter:
		return "illegal_parameter"
	case alertDescDecodeError:
		return "decode_error"
	case alertDescDecryptError:
		return "decrypt_error"
	case alertDescProtocolVersion:
		return "protocol_version"
	case alertDescInternalError:
		return "internal_error"
	case alertDescMissingExtension:
		return "missing_extension"
	}
	return "unknown_alert"
}

// alertError is a handshake failure paired with the alert it put on the
// wire. The cause carries the why; the description names the wire verdict.
type alertError struct {
	desc  byte
	cause error
}

func (e alertError) Error() string {
	return "tls: " + e.cause.Error() + " (sent alert " + alertName(e.desc) + ")"
}

func (e alertError) Unwrap() error { return e.cause }

// ServerAlertName extracts the alert description name a failed tls.Server
// handshake sent, for callers that log it (GOHTTPD's serial line).
func ServerAlertName(err error) (string, bool) {
	var a alertError
	if errors.As(err, &a) {
		return alertName(a.desc), true
	}
	return "", false
}

// PeerAlertName reports the alert description name the peer sent us, when
// the record layer saw one.
func PeerAlertName(s *TLSConn) (string, bool) {
	if s == nil || s.sess == nil || !s.sess.hasPeerAlert {
		return "", false
	}
	return alertName(s.sess.peerAlert), true
}

// ServerConfig is the credential a tls.Server handshake runs on.
type ServerConfig struct {
	// Chain is the DER certificate chain the Certificate message carries,
	// leaf first. The leaf's SPKI must be the Ed25519 public key of
	// Ed25519Seed — a mismatch is a config error, not an alert.
	Chain [][]byte
	// Ed25519Seed is the 32-byte private seed signing CertificateVerify.
	Ed25519Seed [32]byte
	// HandshakeNs bounds the whole handshake (ClientHello through the
	// client Finished); <= 0 selects DefaultHandshakeNs.
	HandshakeNs int64
}

// check validates the config before any byte moves: the chain is nonempty
// and DER-parseable, and the leaf's Ed25519 public key is the seed's.
func (cfg *ServerConfig) check() error {
	if len(cfg.Chain) == 0 {
		return errServerNoCert
	}
	leaf, err := parseCert(cfg.Chain[0])
	if err != nil {
		return errServerBadCert
	}
	if leaf.key.kind != keyEd25519 {
		return errServerKeyMismatch
	}
	pub := ed25519.EdDerivePublic(cfg.Ed25519Seed)
	if string(leaf.key.point) != string(pub[:]) {
		return errServerKeyMismatch
	}
	return nil
}

// server is the TLS 1.3 server over a transport.
type server struct {
	session
	cfg    ServerConfig
	rand   func(p []byte) error
	master [32]byte // the master secret once the flight is out
}

func newServer(t transport, cfg ServerConfig, rand func(p []byte) error) *server {
	s := &server{cfg: cfg, rand: rand}
	s.t = t
	s.state = stateIdle
	s.transcript = sha256Init()
	return s
}

// abort sends the named alert (plaintext before the write keys exist,
// AEAD-protected after) and returns the paired error — every handshake
// failure leaves the wire with its verdict (M135a).
func (s *server) abort(desc byte, cause error) error {
	_ = s.sendAlert(desc)
	s.state = stateFailed
	return alertError{desc: desc, cause: cause}
}

// handshake drives ClientHello through the client Finished. The loop is the
// client's own shape mirrored: records feed complete handshake messages to
// the state machine until stateConnected.
func (s *server) handshake() error {
	for s.state != stateConnected {
		n, inner, err := s.readRecord()
		if err != nil {
			// A transport/record failure mid-handshake still owes the peer
			// a named alert when the wire is writable.
			switch err {
			case ErrRecordDecryptFailed:
				return s.abort(alertDescBadRecordMAC, err)
			case errTruncatedRecord, errRecordTooLarge, errHandshakeTooLarge:
				return s.abort(alertDescDecodeError, err)
			}
			return err
		}
		switch inner {
		case ctChangeCipherSpec:
			continue // middlebox-compat filler: carry, never interpret
		case ctHandshake:
			if err := s.feedHandshake(s.plainBuf[:n], s.processMessage); err != nil {
				return err
			}
		case ctAlert:
			return ErrAlertReceived
		default:
			return s.abort(alertDescUnexpectedMessage, ErrUnexpectedMessage)
		}
	}
	return nil
}

// clientHelloInfo is the negotiated slice of a parsed ClientHello.
type clientHelloInfo struct {
	sessionID []byte // echoed verbatim in ServerHello (middlebox compat)
	x25519Pub [32]byte
}

// processMessage is the server's handshake state machine: ClientHello in
// stateIdle, the client Finished once the flight is out.
func (s *server) processMessage(msgType byte, msg []byte) error {
	body := msg[4:]
	switch msgType {
	case hsClientHello:
		if s.state != stateIdle {
			return s.abort(alertDescUnexpectedMessage, ErrUnexpectedState)
		}
		ch, err := s.checkClientHello(body)
		if err != nil {
			return err // the alert is already on the wire
		}
		s.transcript.write(msg)
		return s.sendFlight(ch)
	case hsFinished:
		if s.state != stateServerFlightSent {
			return s.abort(alertDescUnexpectedMessage, ErrUnexpectedState)
		}
		return s.checkClientFinished(body, msg)
	default:
		return s.abort(alertDescUnexpectedMessage, ErrUnexpectedMessage)
	}
}

// checkClientHello parses and negotiates. Every refusal maps to the alert
// the card names: protocol_version when TLS 1.3 is not offered,
// handshake_failure when no suite/group/share agrees, missing_extension
// when a required extension is absent, decode_error on malformed bytes,
// illegal_parameter on a non-zero compression offer.
func (s *server) checkClientHello(body []byte) (*clientHelloInfo, error) {
	r := newWireReader(body)
	if _, err := r.u16(); err != nil { // legacy_version
		return nil, s.abort(alertDescDecodeError, err)
	}
	if _, err := r.take(32); err != nil { // random
		return nil, s.abort(alertDescDecodeError, err)
	}
	sessionID, err := r.vec8() // legacy_session_id — echoed verbatim
	if err != nil || len(sessionID) > 32 {
		return nil, s.abort(alertDescDecodeError, err)
	}
	suites, err := r.vec16()
	if err != nil || len(suites)%2 != 0 || len(suites) == 0 {
		return nil, s.abort(alertDescDecodeError, err)
	}
	comp, err := r.vec8()
	if err != nil || len(comp) == 0 {
		return nil, s.abort(alertDescDecodeError, err)
	}
	exts, err := r.vec16()
	if err != nil {
		return nil, s.abort(alertDescDecodeError, err)
	}
	if !r.atEnd() {
		return nil, s.abort(alertDescDecodeError, errDER)
	}

	// Compression must offer the null method (RFC 8446 §4.1.2: a legacy
	// vector with anything else is illegal_parameter).
	compOK := false
	for _, m := range comp {
		if m == 0 {
			compOK = true
		}
	}
	if !compOK {
		return nil, s.abort(alertDescIllegalParameter, errBadExtension)
	}

	var hasTLS13, hasShare, hasX25519Group, hasSigAlgs, offersEd25519 bool
	var sharePub [32]byte
	seen := map[uint16]bool{}
	er := newWireReader(exts)
	for !er.atEnd() {
		at, err := er.u16()
		if err != nil {
			return nil, s.abort(alertDescDecodeError, err)
		}
		ebody, err := er.vec16()
		if err != nil {
			return nil, s.abort(alertDescDecodeError, err)
		}
		if seen[at] { // RFC 8446 §4.2: duplicated extensions are illegal
			return nil, s.abort(alertDescIllegalParameter, errBadExtension)
		}
		seen[at] = true
		switch at {
		case extSupportedVersions:
			vr := newWireReader(ebody)
			list, err := vr.vec8()
			if err != nil || len(list)%2 != 0 {
				return nil, s.abort(alertDescDecodeError, err)
			}
			for i := 0; i+1 < len(list); i += 2 {
				if uint16(list[i])<<8|uint16(list[i+1]) == versionTLS13 {
					hasTLS13 = true
				}
			}
		case extSupportedGroups:
			gr := newWireReader(ebody)
			list, err := gr.vec16()
			if err != nil || len(list)%2 != 0 {
				return nil, s.abort(alertDescDecodeError, err)
			}
			for i := 0; i+1 < len(list); i += 2 {
				if uint16(list[i])<<8|uint16(list[i+1]) == groupX25519 {
					hasX25519Group = true
				}
			}
		case extKeyShare:
			kr := newWireReader(ebody)
			list, err := kr.vec16()
			if err != nil {
				return nil, s.abort(alertDescDecodeError, err)
			}
			lr := newWireReader(list)
			for !lr.atEnd() {
				g, err := lr.u16()
				if err != nil {
					return nil, s.abort(alertDescDecodeError, err)
				}
				key, err := lr.vec16()
				if err != nil {
					return nil, s.abort(alertDescDecodeError, err)
				}
				if g == groupX25519 && len(key) == 32 {
					copy(sharePub[:], key)
					hasShare = true
				}
			}
		case extSignatureAlgorithms:
			ar := newWireReader(ebody)
			list, err := ar.vec16()
			if err != nil || len(list)%2 != 0 {
				return nil, s.abort(alertDescDecodeError, err)
			}
			hasSigAlgs = true
			for i := 0; i+1 < len(list); i += 2 {
				if uint16(list[i])<<8|uint16(list[i+1]) == sigEd25519 {
					offersEd25519 = true
				}
			}
		}
	}

	// Order matters: a TLS 1.2-only ClientHello (no 1.3 in
	// supported_versions) is protocol_version even when its suites could
	// never agree — the version is the verdict the gate greps.
	if !hasTLS13 {
		return nil, s.abort(alertDescProtocolVersion, errProtocolVersion)
	}
	suiteOK := false
	for i := 0; i+1 < len(suites); i += 2 {
		if uint16(suites[i])<<8|uint16(suites[i+1]) == suiteOffered {
			suiteOK = true
		}
	}
	if !suiteOK {
		return nil, s.abort(alertDescHandshakeFailure, ErrUnsupportedSuite)
	}
	if !seen[extKeyShare] {
		// No key_share at all — HelloRetryRequest is out of scope, so the
		// missing extension is the named refusal.
		return nil, s.abort(alertDescMissingExtension, ErrUnsupportedGroup)
	}
	if !hasShare || (seen[extSupportedGroups] && !hasX25519Group) {
		return nil, s.abort(alertDescHandshakeFailure, ErrUnsupportedGroup)
	}
	if !hasSigAlgs {
		return nil, s.abort(alertDescMissingExtension, errNoSigAlgs)
	}
	if !offersEd25519 {
		return nil, s.abort(alertDescHandshakeFailure, errNoSigAlgs)
	}
	cp := make([]byte, len(sessionID))
	copy(cp, sessionID)
	return &clientHelloInfo{sessionID: cp, x25519Pub: sharePub}, nil
}

// sendFlight writes ServerHello, derives the handshake keys, then sends
// EncryptedExtensions, Certificate, CertificateVerify and Finished under
// them — each message entering the transcript as it goes out.
func (s *server) sendFlight(ch *clientHelloInfo) error {
	var random, priv [32]byte
	if err := s.rand(random[:]); err != nil {
		return err
	}
	if err := s.rand(priv[:]); err != nil {
		return err
	}
	pub, ok := x25519Base(priv)
	if !ok {
		return s.abort(alertDescInternalError, errKeyShareRejected)
	}

	sh := buildServerHello(random, ch.sessionID, pub)
	s.transcript.write(sh)
	if err := s.sendRecord(sh, ctHandshake); err != nil {
		return err
	}

	shared, ok := x25519(priv, ch.x25519Pub)
	if !ok {
		return s.abort(alertDescIllegalParameter, errKeyShareRejected)
	}
	var zero [32]byte
	if string(shared[:]) == string(zero[:]) {
		return s.abort(alertDescIllegalParameter, errKeyShareRejected)
	}
	s.deriveHandshakeKeys(shared)

	// EncryptedExtensions: empty — this server negotiates nothing else.
	ee := []byte{hsEncryptedExtensions, 0, 0, 2, 0, 0}
	s.transcript.write(ee)
	if err := s.sendRecord(ee, ctHandshake); err != nil {
		return err
	}

	cert := buildCertificate(s.cfg.Chain)
	s.transcript.write(cert)
	if err := s.sendRecord(cert, ctHandshake); err != nil {
		return err
	}

	cv := s.buildCertificateVerify()
	s.transcript.write(cv)
	if err := s.sendRecord(cv, ctHandshake); err != nil {
		return err
	}

	fin := s.buildFinished()
	s.transcript.write(fin)
	if err := s.sendRecord(fin, ctHandshake); err != nil {
		return err
	}

	// The server's sender epoch moves to application_data the moment its
	// Finished is out (RFC 8446 §5.2): install the s_ap write keys now so a
	// refused client Finished — or an undecryptable record in its place —
	// is answered by an alert the client can actually read.
	emptyHash := sha256Sum(nil)
	derived := deriveSecret(s.handshakeSecret, "derived", emptyHash)
	s.master = hkdfExtract(derived[:], zero[:])
	sAP := deriveSecret(s.master, "s ap traffic", s.transcript.sum())
	s.writeKeys.key = trafficKey(sAP)
	s.writeKeys.iv = trafficIv(sAP)
	s.writeCipher, _ = newAES128(s.writeKeys.key[:]) // 16-byte key: cannot fail
	s.writeSeq = 0
	s.state = stateServerFlightSent
	return nil
}

// checkClientFinished verifies the client's Finished MAC (a bad one is a
// decrypt_error alert under the already-installed application write keys)
// and installs the client application read keys.
func (s *server) checkClientFinished(body, msg []byte) error {
	if len(body) != 32 {
		return s.abort(alertDescDecryptError, ErrFinishedMismatch)
	}
	// The MAC and the application secrets share the transcript through the
	// SERVER Finished — this transcript already ends there (sendFlight
	// wrote it).
	th := s.transcript.sum()
	expect := hmacSha256(s.clientFinishedKey[:], th[:])
	var diff byte
	for i := 0; i < 32; i++ {
		diff |= expect[i] ^ body[i]
	}
	if diff != 0 {
		return s.abort(alertDescDecryptError, ErrFinishedMismatch)
	}

	cAP := deriveSecret(s.master, "c ap traffic", th)
	s.readKeys.key = trafficKey(cAP)
	s.readKeys.iv = trafficIv(cAP)
	readCipher, err := newAES128(s.readKeys.key[:])
	if err != nil {
		return err
	}
	s.readCipher = readCipher
	s.readSeq = 0
	s.transcript.write(msg)
	s.state = stateConnected
	return nil
}

// buildServerHello frames the ServerHello: legacy_version 0x0303, the
// session-id echo, TLS_AES_128_GCM_SHA256, null compression, and the two
// extensions TLS 1.3 requires (supported_versions + the X25519 key_share).
func buildServerHello(random [32]byte, sessionID []byte, pub [32]byte) []byte {
	var w byteWriter
	w.u8(hsServerHello)
	hdrAt := w.len
	w.u24(0)

	w.u16(versionTLS12)
	w.raw(random[:])
	w.u8(byte(len(sessionID)))
	w.raw(sessionID)
	w.u16(suiteOffered)
	w.u8(0)

	extAt := w.reserve16()
	{
		w.u16(extSupportedVersions)
		at := w.reserve16()
		w.u16(versionTLS13)
		w.patch16(at)
	}
	{
		w.u16(extKeyShare)
		at := w.reserve16()
		w.u16(groupX25519)
		w.u16(32)
		w.raw(pub[:])
		w.patch16(at)
	}
	w.patch16(extAt)

	bodyLen := w.len - hdrAt - 3
	w.buf[hdrAt] = byte(bodyLen >> 16)
	w.buf[hdrAt+1] = byte(bodyLen >> 8)
	w.buf[hdrAt+2] = byte(bodyLen)
	return w.buf[:w.len]
}

// buildCertificate frames the Certificate message: empty request context,
// then the DER chain (leaf first) with empty per-entry extensions.
func buildCertificate(chain [][]byte) []byte {
	var w byteWriter
	w.u8(hsCertificate)
	hdrAt := w.len
	w.u24(0)

	w.u8(0) // certificate_request_context: empty on a server flight
	listAt := w.reserve24()
	for _, der := range chain {
		w.u24(uint32(len(der)))
		w.raw(der)
		w.u16(0)
	}
	w.patch24(listAt)

	bodyLen := w.len - hdrAt - 3
	w.buf[hdrAt] = byte(bodyLen >> 16)
	w.buf[hdrAt+1] = byte(bodyLen >> 8)
	w.buf[hdrAt+2] = byte(bodyLen)
	return w.buf[:w.len]
}

// buildCertificateVerify signs the transcript through Certificate with the
// configured Ed25519 seed (RFC 8446 §4.4.3, scheme ed25519/0x0807).
func (s *server) buildCertificateVerify() []byte {
	th := s.transcript.sum()
	// 64 spaces || context || 0x00 || transcript hash.
	blob := make([]byte, 0, 64+len(serverCVContext)+1+32)
	for i := 0; i < 64; i++ {
		blob = append(blob, 0x20)
	}
	blob = append(blob, serverCVContext...)
	blob = append(blob, 0x00)
	blob = append(blob, th[:]...)
	sig := ed25519.EdSign(blob, s.cfg.Ed25519Seed)

	var w byteWriter
	w.u8(hsCertificateVerify)
	hdrAt := w.len
	w.u24(0)
	w.u16(sigEd25519)
	w.u16(64)
	w.raw(sig[:])
	bodyLen := w.len - hdrAt - 3
	w.buf[hdrAt] = byte(bodyLen >> 16)
	w.buf[hdrAt+1] = byte(bodyLen >> 8)
	w.buf[hdrAt+2] = byte(bodyLen)
	return w.buf[:w.len]
}

// buildFinished frames the server Finished: HMAC over the transcript
// through CertificateVerify under the server Finished key.
func (s *server) buildFinished() []byte {
	th := s.transcript.sum()
	mac := hmacSha256(s.serverFinishedKey[:], th[:])
	fin := make([]byte, 4+32)
	fin[0] = hsFinished
	fin[3] = 32
	copy(fin[4:], mac[:])
	return fin
}

// deriveHandshakeKeys runs the RFC 8446 §7.1 schedule and installs the
// handshake traffic keys — the client schedule mirrored: the server reads
// under client_hs_traffic and writes under server_hs_traffic.
func (s *server) deriveHandshakeKeys(shared [32]byte) {
	var zero [32]byte
	early := hkdfExtract(zero[:], zero[:])
	emptyHash := sha256Sum(nil)
	derived := deriveSecret(early, "derived", emptyHash)
	hs := hkdfExtract(derived[:], shared[:])
	s.handshakeSecret = hs

	th := s.transcript.sum()
	cHS := deriveSecret(hs, "c hs traffic", th)
	sHS := deriveSecret(hs, "s hs traffic", th)

	s.readKeys.key = trafficKey(cHS)
	s.readKeys.iv = trafficIv(cHS)
	s.writeKeys.key = trafficKey(sHS)
	s.writeKeys.iv = trafficIv(sHS)
	s.clientFinishedKey = finishedKey(cHS)
	s.serverFinishedKey = finishedKey(sHS)

	s.writeKeysReady = true
	s.readEncrypted = true
	s.readSeq = 0
	s.writeSeq = 0
	// 16-byte keys; newAES128 cannot fail on them.
	s.writeCipher, _ = newAES128(s.writeKeys.key[:])
	s.readCipher, _ = newAES128(s.readKeys.key[:])
}
