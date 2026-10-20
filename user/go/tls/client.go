// TLS 1.3 client — the 1-RTT handshake driver and the application record
// path (RFC 8446), the Go mirror of user/src/lib/tls/client.zig's contract:
// TLS_AES_128_GCM_SHA256 + x25519 only, full certificate verification against
// a configured trust store, no PSK / 0-RTT / client certificates, and
// HelloRetryRequest rejected (a missing key share surfaces as
// ErrUnsupportedGroup) rather than mishandled.
//
// The handshake is a state machine: only `connected` permits application
// data, and `connected` is reachable only after the server's Finished
// verifies. Pinned end-to-end against RFC 8448's published flight in
// client_test.go and against a live Go-stdlib TLS 1.3 server (interop.go).

package tls

import "virelai/ed25519"

// record layer bounds (RFC 8446 §5.2: length MUST NOT exceed 2^14 + 256).
const (
	recordHeaderLen  = 5
	maxPlaintext     = 16384
	maxCiphertext    = maxPlaintext + 256
	maxHandshakeMsg  = 16 * 1024
	maxIntermediates = 8
	maxCertDER       = 4096
	keyLen           = 16
	ivLen            = 12
)

// content types and handshake types (RFC 8446 §5.1, §4).
const (
	ctChangeCipherSpec = 20
	ctAlert            = 21
	ctHandshake        = 22
	ctApplicationData  = 23

	hsClientHello         = 1
	hsServerHello         = 2
	hsNewSessionTicket    = 4
	hsEncryptedExtensions = 8
	hsCertificate         = 11
	hsCertificateRequest  = 13
	hsCertificateVerify   = 15
	hsFinished            = 20
	hsKeyUpdate           = 24
)

// extension numbers and the offered suite / signature schemes. The offer
// lists exactly what verifyCertificateVerify can check — never more (an
// advertised scheme the client cannot verify is a downgrade-shaped lie).
const (
	extServerName          = 0
	extSupportedGroups     = 10
	extSignatureAlgorithms = 13
	extSupportedVersions   = 43
	extKeyShare            = 51
	extPSKKeyExchangeModes = 45

	groupX25519  = 0x001d
	suiteOffered = 0x1301 // TLS_AES_128_GCM_SHA256
	versionTLS12 = 0x0303
	versionTLS13 = 0x0304

	sigEcdsaSecp256r1Sha256 = 0x0403
	sigEcdsaSecp384r1Sha384 = 0x0503
	sigRsaPssRsaeSha256     = 0x0804
	sigRsaPssRsaeSha384     = 0x0805
	sigRsaPssRsaeSha512     = 0x0806
	sigRsaPkcs1Sha256       = 0x0401
	sigRsaPkcs1Sha384       = 0x0501
	sigRsaPkcs1Sha512       = 0x0601
	sigEd25519              = 0x0807
)

// offeredSigAlgs is the ClientHello signature_algorithms list — the same
// set the Zig client offers (user/src/lib/tls/handshake.zig), Ed25519 last.
var offeredSigAlgs = []uint16{
	sigEcdsaSecp256r1Sha256,
	sigEcdsaSecp384r1Sha384,
	sigRsaPssRsaeSha256,
	sigRsaPssRsaeSha384,
	sigRsaPssRsaeSha512,
	sigRsaPkcs1Sha256,
	sigRsaPkcs1Sha384,
	sigRsaPkcs1Sha512,
	sigEd25519,
}

// serverCVContext is the RFC 8446 §4.4.3 context string a server signs.
const serverCVContext = "TLS 1.3, server CertificateVerify"

// tlsState is the handshake state machine's shape: application data is
// reachable only from stateConnected.
type tlsState int

const (
	stateIdle tlsState = iota
	stateSentClientHello
	stateReceivedServerHello
	stateReceivedEncryptedExtensions
	stateReceivedCertificate
	stateReceivedCertificateVerify
	stateReceivedFinished
	stateConnected
	stateFailed
	stateClosed
	// stateServerFlightSent: the server half's "whole flight is on the
	// wire, waiting on the client Finished" state (M135a).
	stateServerFlightSent
)

func (s tlsState) allowsApplicationData() bool { return s == stateConnected }

// trafficKeys is one direction's AEAD material.
type trafficKeys struct {
	key [keyLen]byte
	iv  [ivLen]byte
}

// recordNonce is RFC 8446 §5.3: iv XOR the 64-bit sequence number,
// right-aligned.
func recordNonce(iv *[12]byte, seq uint64) [12]byte {
	var n [12]byte
	copy(n[:], iv[:])
	v := uint64(n[4])<<56 | uint64(n[5])<<48 | uint64(n[6])<<40 | uint64(n[7])<<32 |
		uint64(n[8])<<24 | uint64(n[9])<<16 | uint64(n[10])<<8 | uint64(n[11])
	v ^= seq
	n[4] = byte(v >> 56)
	n[5] = byte(v >> 48)
	n[6] = byte(v >> 40)
	n[7] = byte(v >> 32)
	n[8] = byte(v >> 24)
	n[9] = byte(v >> 16)
	n[10] = byte(v >> 8)
	n[11] = byte(v)
	return n
}

// client is the TLS 1.3 client over a transport. The record layer and its
// state live in the embedded session (session.go) — shared verbatim with
// the server half.
type client struct {
	session

	host   string // SNI and hostname verification name
	now    int64
	rand   func(p []byte) error
	verify bool
	// store is the trust anchor set for chain validation; nil means the
	// vendored default (the guest's pinned root).
	store *trustStore

	// captured chain (leaf copied out of hsBuf, which is compacted)
	leafDER           []byte
	intermediates     [][]byte
	pendingClientCert bool

	// negotiated
	lastValidation validationResult

	// corruptFinished flips a bit in the client's Finished MAC — the
	// host-test seam for the server's bad-Finished negative leg.
	corruptFinished bool
}

func newClient(t transport, host string, now int64, rand func(p []byte) error, verify bool) *client {
	c := &client{host: host, now: now, rand: rand, verify: verify}
	c.t = t
	return c
}

// handshake runs ClientHello through the client Finished.
func (c *client) handshake() error {
	var random, sessionID, priv [32]byte
	if err := c.rand(random[:]); err != nil {
		return err
	}
	if err := c.rand(sessionID[:]); err != nil {
		return err
	}
	if err := c.rand(priv[:]); err != nil {
		return err
	}
	pub, ok := x25519Base(priv)
	if !ok {
		return errKeyShareRejected
	}

	ch := c.buildClientHello(random, sessionID, pub)
	c.transcript = sha256Init()
	c.transcript.write(ch)
	if err := c.sendRecord(ch, ctHandshake); err != nil {
		return err
	}
	c.state = stateSentClientHello

	for {
		n, inner, err := c.readRecord()
		if err != nil {
			return err
		}
		if inner == ctChangeCipherSpec {
			continue
		}
		if inner == ctApplicationData || inner == ctHandshake {
			// Decrypted handshake bytes (application_data is the AEAD outer
			// type once keys are installed).
			if err := c.feedHandshake(c.plainBuf[:n], func(t byte, m []byte) error {
				return c.processMessage(t, m, priv)
			}); err != nil {
				return err
			}
			if c.state == stateReceivedFinished {
				return c.finishHandshake()
			}
			continue
		}
		if inner == ctAlert {
			return ErrAlertReceived
		}
	}
}

func (c *client) buildClientHello(random, sessionID, x25519Pub [32]byte) []byte {
	var w byteWriter
	w.u8(hsClientHello)
	hdrLenAt := w.len
	w.u24(0)

	w.u16(versionTLS12)
	w.raw(random[:])
	w.u8(32) // legacy_session_id (middlebox compat)
	w.raw(sessionID[:])

	// cipher_suites
	at := w.reserve16()
	w.u16(suiteOffered)
	w.patch16(at)
	// legacy_compression_methods
	w.u8(1)
	w.u8(0)

	extAt := w.reserve16()

	// RFC 6066 prohibits literal IP addresses in host_name. Verification
	// still uses c.host, including exact iPAddress SAN checks.
	if _, literal := parseIPLiteral([]byte(c.host)); !literal {
		w.u16(extServerName)
		at := w.reserve16()
		inner := w.reserve16()
		w.u8(0) // host_name
		nameAt := w.reserve16()
		w.raw([]byte(c.host))
		w.patch16(nameAt)
		w.patch16(inner)
		w.patch16(at)
	}

	// supported_versions
	{
		w.u16(extSupportedVersions)
		at := w.reserve16()
		w.u8(2)
		w.u16(versionTLS13)
		w.patch16(at)
	}

	// supported_groups
	{
		w.u16(extSupportedGroups)
		at := w.reserve16()
		inner := w.reserve16()
		list := w.reserve16()
		w.u16(groupX25519)
		w.patch16(list)
		w.patch16(inner)
		w.patch16(at)
	}

	// signature_algorithms
	{
		w.u16(extSignatureAlgorithms)
		at := w.reserve16()
		inner := w.reserve16()
		list := w.reserve16()
		for _, s := range offeredSigAlgs {
			w.u16(s)
		}
		w.patch16(list)
		w.patch16(inner)
		w.patch16(at)
	}

	// key_share
	{
		w.u16(extKeyShare)
		at := w.reserve16()
		inner := w.reserve16()
		w.u16(groupX25519)
		w.u16(32)
		w.raw(x25519Pub[:])
		w.patch16(inner)
		w.patch16(at)
	}

	// psk_key_exchange_modes (present but no PSK offered)
	{
		w.u16(extPSKKeyExchangeModes)
		at := w.reserve16()
		w.u8(1)
		w.u8(1) // psk_dhe_ke
		w.patch16(at)
	}

	w.patch16(extAt)
	// Back-patch the handshake header length (hdrLenAt is the u24 field).
	bodyLen := w.len - hdrLenAt - 3
	w.buf[hdrLenAt] = byte(bodyLen >> 16)
	w.buf[hdrLenAt+1] = byte(bodyLen >> 8)
	w.buf[hdrLenAt+2] = byte(bodyLen)
	return w.buf[:w.len]
}

// byteWriter is the fixed-buffer message writer (back-patching lengths).
type byteWriter struct {
	buf []byte
	len int
}

func (w *byteWriter) ensure(n int) {
	for len(w.buf)-w.len < n {
		if w.buf == nil {
			w.buf = make([]byte, 256)
			continue
		}
		grown := make([]byte, len(w.buf)*2)
		copy(grown, w.buf)
		w.buf = grown
	}
}

func (w *byteWriter) u8(v byte) {
	w.ensure(1)
	w.buf[w.len] = v
	w.len++
}

func (w *byteWriter) u16(v uint16) {
	w.ensure(2)
	w.buf[w.len] = byte(v >> 8)
	w.buf[w.len+1] = byte(v)
	w.len += 2
}

func (w *byteWriter) u24(v uint32) {
	w.ensure(3)
	w.buf[w.len] = byte(v >> 16)
	w.buf[w.len+1] = byte(v >> 8)
	w.buf[w.len+2] = byte(v)
	w.len += 3
}

func (w *byteWriter) raw(p []byte) {
	w.ensure(len(p))
	copy(w.buf[w.len:], p)
	w.len += len(p)
}

func (w *byteWriter) reserve16() int {
	at := w.len
	w.u16(0)
	return at
}

func (w *byteWriter) reserve24() int {
	at := w.len
	w.u24(0)
	return at
}

func (w *byteWriter) patch24(at int) {
	n := w.len - at - 3
	w.buf[at] = byte(n >> 16)
	w.buf[at+1] = byte(n >> 8)
	w.buf[at+2] = byte(n)
}

func (w *byteWriter) patch16(at int) {
	n := w.len - at - 2
	w.buf[at] = byte(n >> 8)
	w.buf[at+1] = byte(n)
}

func (c *client) processMessage(msgType byte, msg []byte, priv [32]byte) error {
	body := msg[4:]
	switch msgType {
	case hsServerHello:
		if c.state != stateSentClientHello {
			return ErrUnexpectedState
		}
		suite, peer, ok, err := parseServerHello(body)
		if err != nil {
			return err
		}
		if suite != suiteOffered {
			return ErrUnsupportedSuite
		}
		if !ok {
			return ErrUnsupportedGroup
		}
		c.transcript.write(msg)
		if err := c.deriveHandshakeKeys(peer, priv); err != nil {
			return err
		}
		c.state = stateReceivedServerHello
	case hsEncryptedExtensions:
		if c.state != stateReceivedServerHello {
			return ErrUnexpectedState
		}
		if err := parseEncryptedExtensions(body); err != nil {
			return err
		}
		c.transcript.write(msg)
		c.state = stateReceivedEncryptedExtensions
	case hsCertificate:
		if c.state != stateReceivedEncryptedExtensions {
			return ErrUnexpectedState
		}
		if err := c.captureCertificate(body); err != nil {
			return err
		}
		c.transcript.write(msg)
		c.state = stateReceivedCertificate
	case hsCertificateVerify:
		if c.state != stateReceivedCertificate {
			return ErrUnexpectedState
		}
		scheme, sig, err := parseCertificateVerify(body)
		if err != nil {
			return err
		}
		// The signature covers the transcript through Certificate, so hash
		// BEFORE adding this message.
		if !c.verifyCertificateVerify(scheme, sig) {
			return ErrCertificateVerify
		}
		c.transcript.write(msg)
		c.state = stateReceivedCertificateVerify
	case hsFinished:
		if c.state != stateReceivedCertificateVerify {
			return ErrUnexpectedState
		}
		if len(body) != 32 {
			return ErrFinishedMismatch
		}
		var th [32]byte
		th = c.transcript.sum()
		expect := hmacSha256(c.serverFinishedKey[:], th[:])
		var diff byte
		for i := 0; i < 32; i++ {
			diff |= expect[i] ^ body[i]
		}
		if diff != 0 {
			return ErrFinishedMismatch
		}
		c.transcript.write(msg)
		c.state = stateReceivedFinished
	case hsCertificateRequest:
		// We have no client certificate; the answer is an empty Certificate
		// before our Finished (RFC 8446 §4.4.2).
		c.transcript.write(msg)
		c.pendingClientCert = true
	case hsNewSessionTicket:
		// Legal to ignore for a client that did not offer a PSK.
		c.transcript.write(msg)
	default:
		return ErrUnexpectedMessage
	}
	return nil
}

// parseServerHello extracts the suite and the x25519 key share.
func parseServerHello(body []byte) (uint16, [32]byte, bool, error) {
	var peer [32]byte
	ok := false
	r := newWireReader(body)
	if _, err := r.u16(); err != nil { // legacy_version
		return 0, peer, false, err
	}
	if _, err := r.take(32); err != nil { // random
		return 0, peer, false, err
	}
	if _, err := r.vec8(); err != nil { // legacy_session_id_echo
		return 0, peer, false, err
	}
	suite, err := r.u16()
	if err != nil {
		return 0, peer, false, err
	}
	if _, err := r.u8(); err != nil { // legacy_compression_method
		return 0, peer, false, err
	}
	exts, err := r.vec16()
	if err != nil {
		return 0, peer, false, err
	}
	er := newWireReader(exts)
	for !er.atEnd() {
		at, err := er.u16()
		if err != nil {
			return 0, peer, false, err
		}
		b2, err := er.vec16()
		if err != nil {
			return 0, peer, false, err
		}
		if at == extKeyShare {
			kr := newWireReader(b2)
			g, err := kr.u16()
			if err != nil {
				return 0, peer, false, err
			}
			key, err := kr.vec16()
			if err != nil {
				return 0, peer, false, err
			}
			if g == groupX25519 && len(key) == 32 {
				copy(peer[:], key)
				ok = true
			}
		} else if at == extSupportedVersions {
			vr := newWireReader(b2)
			v, err := vr.u16()
			if err != nil {
				return 0, peer, false, err
			}
			if v != versionTLS13 {
				return 0, peer, false, errBadExtension
			}
		}
	}
	return suite, peer, ok, nil
}

func parseEncryptedExtensions(body []byte) error {
	r := newWireReader(body)
	exts, err := r.vec16()
	if err != nil {
		return err
	}
	er := newWireReader(exts)
	for !er.atEnd() {
		if _, err := er.u16(); err != nil {
			return err
		}
		if _, err := er.vec16(); err != nil {
			return err
		}
	}
	return nil
}

func parseCertificateVerify(body []byte) (uint16, []byte, error) {
	r := newWireReader(body)
	scheme, err := r.u16()
	if err != nil {
		return 0, nil, err
	}
	sig, err := r.vec16()
	if err != nil {
		return 0, nil, err
	}
	return scheme, sig, nil
}

// captureCertificate keeps the leaf DER (copied: hsBuf is compacted) and the
// intermediates.
func (c *client) captureCertificate(body []byte) error {
	r := newWireReader(body)
	if _, err := r.vec8(); err != nil { // certificate_request_context
		return err
	}
	list, err := r.vec24()
	if err != nil {
		return err
	}
	lr := newWireReader(list)
	idx := 0
	for !lr.atEnd() {
		certDER, err := lr.vec24()
		if err != nil {
			return err
		}
		if !lr.atEnd() {
			if _, err := lr.vec16(); err != nil { // per-entry extensions
				return err
			}
		}
		if idx == 0 {
			if len(certDER) > maxCertDER {
				return ErrCertificateParse
			}
			cp := make([]byte, len(certDER))
			copy(cp, certDER)
			c.leafDER = cp
		} else if len(c.intermediates) < maxIntermediates {
			if len(certDER) > maxCertDER {
				return ErrCertificateParse
			}
			cp := make([]byte, len(certDER))
			copy(cp, certDER)
			c.intermediates = append(c.intermediates, cp)
		}
		idx++
	}
	if c.leafDER == nil {
		return ErrCertificateParse
	}
	return nil
}

// verifyCertificateVerify checks the server's transcript signature.
func (c *client) verifyCertificateVerify(scheme uint16, sig []byte) bool {
	th := c.transcript.sum()
	// 64 spaces || context || 0x00 || transcript hash (RFC 8446 §4.4.3).
	blob := make([]byte, 0, 64+len(serverCVContext)+1+32)
	for i := 0; i < 64; i++ {
		blob = append(blob, 0x20)
	}
	blob = append(blob, serverCVContext...)
	blob = append(blob, 0x00)
	blob = append(blob, th[:]...)

	leaf, err := parseCert(c.leafDER)
	if err != nil {
		return false
	}
	switch scheme {
	case sigEcdsaSecp256r1Sha256:
		if leaf.key.kind != keyEC || leaf.key.curve != curveKindP256 {
			return false
		}
		return verifyLeafSig(leaf, sig, blob, hashSHA256, ecP256(), 32)
	case sigEcdsaSecp384r1Sha384:
		if leaf.key.kind != keyEC || leaf.key.curve != curveKindP384 {
			return false
		}
		return verifyLeafSig(leaf, sig, blob, hashSHA384, ecP384(), 48)
	case sigRsaPssRsaeSha256:
		if leaf.key.kind != keyRSA {
			return false
		}
		return verifyRsaPss(leaf.key.rsaModulus, leaf.key.rsaExponent, hashSHA256, blob, sig)
	case sigRsaPssRsaeSha384:
		if leaf.key.kind != keyRSA {
			return false
		}
		return verifyRsaPss(leaf.key.rsaModulus, leaf.key.rsaExponent, hashSHA384, blob, sig)
	case sigRsaPssRsaeSha512:
		if leaf.key.kind != keyRSA {
			return false
		}
		return verifyRsaPss(leaf.key.rsaModulus, leaf.key.rsaExponent, hashSHA512, blob, sig)
	case sigRsaPkcs1Sha256:
		if leaf.key.kind != keyRSA {
			return false
		}
		return verifyRsaPkcs1(leaf.key.rsaModulus, leaf.key.rsaExponent, hashSHA256, blob, sig)
	case sigRsaPkcs1Sha384:
		if leaf.key.kind != keyRSA {
			return false
		}
		return verifyRsaPkcs1(leaf.key.rsaModulus, leaf.key.rsaExponent, hashSHA384, blob, sig)
	case sigRsaPkcs1Sha512:
		if leaf.key.kind != keyRSA {
			return false
		}
		return verifyRsaPkcs1(leaf.key.rsaModulus, leaf.key.rsaExponent, hashSHA512, blob, sig)
	case sigEd25519:
		if leaf.key.kind != keyEd25519 || len(leaf.key.point) != 32 || len(sig) != 64 {
			return false
		}
		var sigB [64]byte
		var pkB [32]byte
		copy(sigB[:], sig)
		copy(pkB[:], leaf.key.point)
		return ed25519.EdVerify(sigB, blob, pkB)
	}
	return false
}

// verifyLeafSig verifies an ECDSA CertificateVerify signature (DER
// ECDSA-Sig-Value) over blob with the given hash and curve.
func verifyLeafSig(leaf *cert, sig, blob []byte, h hashAlg, curve *ecCurve, zlen int) bool {
	outer := newDERReader(sig)
	seq, err := outer.expect(derTagSequence)
	if err != nil || !outer.atEnd() {
		return false
	}
	sr := newDERReader(seq.content)
	rElem, err := sr.expect(derTagInteger)
	if err != nil {
		return false
	}
	sElem, err := sr.expect(derTagInteger)
	if err != nil {
		return false
	}
	r, err := derInteger(rElem)
	if err != nil {
		return false
	}
	s, err := derInteger(sElem)
	if err != nil {
		return false
	}
	point := leaf.key.point
	if len(point) < 1 || point[0] != 0x04 {
		return false
	}
	flen := (len(point) - 1) / 2
	digest := h.hashSum(blob)
	if len(digest) < zlen {
		return false
	}
	return curve.verifyECDSA(point[1:1+flen], point[1+flen:], r, s, digest[:zlen])
}

// deriveHandshakeKeys runs the RFC 8446 §7.1 schedule through the handshake
// secrets and installs the handshake traffic keys.
func (c *client) deriveHandshakeKeys(serverPub [32]byte, priv [32]byte) error {
	shared, ok := x25519(priv, serverPub)
	if !ok {
		return errKeyShareRejected
	}
	var zero [32]byte
	if string(shared[:]) == string(zero[:]) {
		return errKeyShareRejected
	}

	early := hkdfExtract(zero[:], zero[:])
	var emptyHash [32]byte
	emptyHash = sha256Sum(nil)
	derived := deriveSecret(early, "derived", emptyHash)

	hsSecret := hkdfExtract(derived[:], shared[:])
	c.handshakeSecret = hsSecret

	th := c.transcript.sum()
	cHS := deriveSecret(hsSecret, "c hs traffic", th)
	sHS := deriveSecret(hsSecret, "s hs traffic", th)

	c.writeKeys.key = trafficKey(cHS)
	c.writeKeys.iv = trafficIv(cHS)
	c.readKeys.key = trafficKey(sHS)
	c.readKeys.iv = trafficIv(sHS)
	c.clientFinishedKey = finishedKey(cHS)
	c.serverFinishedKey = finishedKey(sHS)

	c.writeKeysReady = true
	c.readEncrypted = true
	c.readSeq = 0
	c.writeSeq = 0
	// 16-byte keys; newAES128 cannot fail on them.
	c.writeCipher, _ = newAES128(c.writeKeys.key[:])
	c.readCipher, _ = newAES128(c.readKeys.key[:])
	return nil
}

// finishHandshake validates the chain, sends the client Finished, and
// switches to the application keys.
func (c *client) finishHandshake() error {
	if c.verify {
		store := c.store
		if store == nil {
			store = defaultStore
		}
		res := validateChain(c.leafDER, c.intermediates, store, []byte(c.host), c.now)
		c.lastValidation = res
		if res != resultValid {
			return chainValidationError{res: res}
		}
	}

	var zero [32]byte
	var emptyHash [32]byte
	emptyHash = sha256Sum(nil)
	derived := deriveSecret(c.handshakeSecret, "derived", emptyHash)
	master := hkdfExtract(derived[:], zero[:])

	thAP := c.transcript.sum()
	cAP := deriveSecret(master, "c ap traffic", thAP)
	sAP := deriveSecret(master, "s ap traffic", thAP)

	if c.pendingClientCert {
		emptyCert := []byte{0x0b, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00}
		if err := c.sendRecord(emptyCert, ctHandshake); err != nil {
			return err
		}
		c.transcript.write(emptyCert)
	}

	th := c.transcript.sum()
	expect := hmacSha256(c.clientFinishedKey[:], th[:])
	if c.corruptFinished {
		expect[0] ^= 0xff // test seam: the server must answer decrypt_error
	}
	fin := make([]byte, 4+32)
	fin[0] = hsFinished
	fin[1] = 0
	fin[2] = 0
	fin[3] = 32
	copy(fin[4:], expect[:])
	if err := c.sendRecord(fin, ctHandshake); err != nil {
		return err
	}
	c.transcript.write(fin)

	c.writeKeys.key = trafficKey(cAP)
	c.writeKeys.iv = trafficIv(cAP)
	c.readKeys.key = trafficKey(sAP)
	c.readKeys.iv = trafficIv(sAP)
	writeCipher, err := newAES128(c.writeKeys.key[:])
	if err != nil {
		return err
	}
	readCipher, err := newAES128(c.readKeys.key[:])
	if err != nil {
		return err
	}
	c.writeCipher = writeCipher
	c.readCipher = readCipher
	c.readSeq = 0
	c.writeSeq = 0
	c.state = stateConnected
	return nil
}
