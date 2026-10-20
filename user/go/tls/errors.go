// Error surface. Every failure is a specific sentinel — fail closed, never
// partially accept (ADR 0029 D4). The names mirror the Zig client's error set
// in user/src/lib/tls so the two clients report the same failure taxonomy.

package tls

import "errors"

var (
	// Transport errors (the vi.Conn seam reports these through the client).
	errTransport      = errors.New("tls: transport failed")
	errStreamClosed   = errors.New("tls: peer closed")
	errStreamTimeout  = errors.New("tls: peer timeout")
	errStreamOverflow = errors.New("tls: TCP stash overflow")

	// Record layer.
	errRecordTooLarge   = errors.New("tls: record too large")
	errTruncatedRecord  = errors.New("tls: truncated record")
	errInnerTypeMissing = errors.New("tls: inner content type missing")
	errInnerTypeBad     = errors.New("tls: inner content type not allowed")
	// ErrRecordDecryptFailed: AEAD verification failed on a record — fail
	// closed, never output unauthenticated plaintext.
	ErrRecordDecryptFailed = errors.New("tls: record decrypt failed")

	// Handshake.
	ErrUnexpectedMessage = errors.New("tls: unexpected handshake message")
	ErrUnexpectedState   = errors.New("tls: unexpected handshake state")
	ErrUnsupportedSuite  = errors.New("tls: server negotiated an unsupported cipher suite")
	ErrUnsupportedGroup  = errors.New("tls: no usable x25519 key share (includes HelloRetryRequest, which is unsupported by scope)")
	ErrAlertReceived     = errors.New("tls: received a TLS alert")
	ErrCertificateParse  = errors.New("tls: server certificate did not parse")
	ErrCertificateVerify = errors.New("tls: CertificateVerify signature did not verify")
	ErrFinishedMismatch  = errors.New("tls: server Finished did not verify")
	ErrNotConnected      = errors.New("tls: handshake not complete")
	errBadServerName     = errors.New("tls: server name too long")
	errHandshakeTooLarge = errors.New("tls: handshake flight too large")
	errKeyShareRejected  = errors.New("tls: x25519 produced the all-zero shared secret")
	ErrEntropyFailed     = errors.New("tls: entropy source failed")

	// Server half (M135a).
	errProtocolVersion   = errors.New("tls: client does not offer TLS 1.3")
	errNoSigAlgs         = errors.New("tls: no usable signature_algorithms (need ed25519)")
	errServerNoCert      = errors.New("tls: server config carries no certificate")
	errServerBadCert     = errors.New("tls: server certificate did not parse")
	errServerKeyMismatch = errors.New("tls: server seed does not match the leaf's Ed25519 key")

	// Chain validation (ErrChainValidationFailed wraps the specific Result).
	ErrChainValidationFailed = errors.New("tls: certificate chain validation failed")
	ErrNoTrustAnchor         = errors.New("tls: trust anchor missing or bad")

	// Primitives.
	errHKDFLength     = errors.New("hkdf: requested output length out of bounds")
	errAESKeyLen      = errors.New("aes: key must be 16 bytes")
	errGCMArgs        = errors.New("gcm: bad arguments")
	errGCMTagMismatch = errors.New("gcm: authentication failed")
	errDER            = errors.New("der: malformed input")
	errX509           = errors.New("x509: malformed certificate")
	errMontOddModulus = errors.New("mont: modulus must be odd and nonzero")

	// X.509.
	errNotACertificate    = errors.New("x509: not a certificate")
	errUnsupportedVersion = errors.New("x509: unsupported version")
	errMissingField       = errors.New("x509: missing or misplaced field")
	errBadExtension       = errors.New("x509: malformed extension")
	errBadAlgorithm       = errors.New("x509: unsupported key algorithm")
	errBadIPAddress       = errors.New("x509: malformed IP SAN")
	errTooManyExtensions  = errors.New("x509: extension capacity exceeded")

	// Trust store.
	errNoTrustAnchor = errors.New("tls: trust anchor missing or bad")
)

// chainValidationError carries the ADR 0029 D4 verdict so callers can tell
// hostname_mismatch from expired from no_path_to_root (the live-tls13
// negatives). Unwrap keeps errors.Is(..., ErrChainValidationFailed) working.
type chainValidationError struct {
	res validationResult
}

func (e chainValidationError) Error() string {
	return ErrChainValidationFailed.Error() + ": " + e.res.String()
}

func (e chainValidationError) Unwrap() error { return ErrChainValidationFailed }

func validationOf(err error) (validationResult, bool) {
	var c chainValidationError
	if errors.As(err, &c) {
		return c.res, true
	}
	return 0, false
}

// IsHostnameMismatch reports a fail-closed wrong-name handshake.
func IsHostnameMismatch(err error) bool {
	res, ok := validationOf(err)
	return ok && res == resultHostnameMismatch
}

// IsExpired reports a fail-closed expired (or not-yet-valid) chain.
func IsExpired(err error) bool {
	res, ok := validationOf(err)
	return ok && (res == resultExpired || res == resultNotYetValid)
}

// IsNoPathToRoot reports a fail-closed chain that does not reach an anchor.
func IsNoPathToRoot(err error) bool {
	res, ok := validationOf(err)
	return ok && res == resultNoPathToRoot
}
