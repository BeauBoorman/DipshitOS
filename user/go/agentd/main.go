// AGENTD.ELF — the agent control channel daemon (ADR 0044, ADR 0052).
// One JSON-Lines session at a time on guest TCP 4747 behind an
// agent-named Ed25519 challenge (virelai-agent/2 — v1 HMAC is removed:
// old clients fail closed at the greeting). Startup posture refuses
// before Listen; every auth failure is damped and relistened; nothing
// sensitive is ever logged (D6).
package main

import (
	"strings"

	"virelai/vi"
)

// Serial markers (D6). Nothing past the marker word is ever a secret, a
// path, a command, or a payload — the suffix carries ids, verbs, codes,
// and errno names only.
const (
	markerStart    = "agentd: start exec="
	markerListen   = "agentd: listen 4747"
	markerAccepted = "agentd: accepted"
	markerAuthOK   = "agentd: auth ok"
	markerAuthFail = "agentd: auth fail reason="
	markerReq      = "agentd: req id="
	markerRefuse   = "agentd: refuse id="
	markerSpawn    = "agentd: spawn pid="
	markerReap     = "agentd: reap pid="
	markerSessEnd  = "agentd: session end reason="
	markerRefuseAt = "agentd: refuse "
)

func main() {
	allowExec := false
	for i, a := range argsFn() {
		if i == 0 && a == appName {
			continue // argv[0] is the image name, not a flag
		}
		if a == "--allow-exec" {
			allowExec = true
			continue
		}
		refuseExit("argv")
		return
	}
	// Posture, in D2's order: principal, credential, sandbox root. Each
	// refusal is one marker and exit 1, before any Listen. M173d (ADR 0052
	// amendment): the daemon runs only as uid_agent — the kernel binds that
	// principal to the recorded AGENTD.ELF name at exec (and `exec -u2000`
	// names it administratively); every other uid, uid_user included, is
	// refused as privileged.
	uid, caps, ok := principalFn()
	if !ok || uid != vi.UidAgent || caps != 0 {
		refuseExit("privileged")
		return
	}
	if !hasCredential() {
		refuseExit("no-credential")
		return
	}
	switch _, code := keyringLoad(); code {
	case "":
	case "missing":
		refuseExit("no-keyring")
		return
	default:
		refuseExit("keyring-malformed")
		return
	}
	if !dirExists(sandboxDir) {
		refuseExit("no-root")
		return
	}
	if !dirExists(auditDir) {
		refuseExit("no-audit")
		return
	}
	if code := auditInit(); code != "" {
		refuseExit(code)
		return
	}
	if allowExec {
		consoleFn(markerStart + "on")
	} else {
		consoleFn(markerStart + "off")
	}
	for {
		// A closed session can leave the singleton in fin_sent — the
		// hermetic peer ACKs our FIN but never answers with its own, so
		// Listen EINVALs until the retransmission abort releases it
		// (the shell idle's poll_rto, ~30 ticks). Keep draining and
		// retry within the bound rather than refuse the relisten D2
		// requires.
		var ln *vi.Conn
		for spins := 0; ; spins++ {
			var err error
			ln, err = listenFn(agentPort)
			if err == nil {
				break
			}
			if errKind(err) != "EINVAL" || spins >= relistenSpins {
				consoleFn(markerRefuseAt + "listen errno=" + errKind(err))
				exitFn(1)
				return
			}
			zombieDrain()
		}
		consoleFn(markerListen)
		var dc drainConn
		if err := waitEstablished(&dc.pre); err != nil {
			// The bounded accept wait lapsed with no handshake; the
			// socket is dead — release it and take the next one.
			_ = ln.Close()
			continue
		}
		if err := ln.Accept(); err != nil {
			_ = ln.Close()
			continue
		}
		consoleFn(markerAccepted)
		authFailed := session(&dc, allowExec)
		// Give the peer a moment to close first: its RST/FIN consumed
		// while still established releases the socket inside Close, where
		// a guest-first FIN waits on a FIN+ACK the peer never sends.
		waitPeerGone()
		_ = ln.Close()
		if authFailed {
			sleepFn(dampingTicks) // D2 brute-force damping
		}
	}
}

// refuseExit is the uniform startup refusal: one marker, exit 1.
func refuseExit(what string) {
	consoleFn(markerRefuseAt + what)
	exitFn(1)
}

// errKind names an error for the refuse-listen marker. vi errors are
// errno-named already; anything else is opaque ("ERR").
func errKind(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// session runs one connection inside its audit bracket: the open receipt
// is written at accept, one auth_fail receipt per failed verdict (the
// claimed id when there is one), and the close receipt with the end
// reason — allowed and refused activity alike (ADR 0052 D4). runSession
// fills the trail; the emits here keep open..close in seq order around
// the per-verb receipts.
func session(c connIO, allowExec bool) bool {
	tr := &sessionTrail{end: "client_close"}
	auditSessionEvent("-", "open", "ok")
	failed := runSession(c, allowExec, tr)
	if tr.verdict != "" {
		agent := tr.claimed
		if agent == "" {
			agent = "-"
		}
		auditSessionEvent(agent, "auth_fail", tr.verdict)
	}
	agent := "-"
	if tr.authed {
		agent = tr.claimed
	}
	auditSessionEvent(agent, "close", tr.end)
	return failed
}

// runSession runs one connection: the keyring is read fresh (per-session
// resolution, ADR 0052 D6), the greeting and single auth attempt run,
// then the request loop. The challenge and reply buffers are wiped when
// the session ends (D2). It returns true when the AUTH phase failed
// (the caller applies the 1 s damping before relistening); request-phase
// endings are not damped.
func runSession(c connIO, allowExec bool, tr *sessionTrail) bool {
	r := newLineReader(c)

	kr, kcode := keyringLoad()
	if kcode != "" {
		// The posture check passed at start but the file is gone or
		// unreadable now — no identity can be resolved, so there is no
		// auth verdict to give.
		tr.end = "io_error"
		consoleFn(markerSessEnd + "io_error")
		return false
	}

	challenge, ok := agentChallenge()
	if !ok {
		tr.end = "io_error"
		consoleFn(markerSessEnd + "io_error")
		return false
	}
	greeting := `{"proto":"virelai-agent/2","auth":"ed25519","challenge":"` +
		hexString(challenge[:]) + `"}`
	if err := sendLine(c, greeting); err != nil {
		tr.end = "client_close"
		consoleFn(markerSessEnd + "client_close")
		return false
	}

	// One auth attempt, one 10 s budget, one 256-byte line.
	c.SetRecvDeadline(authBudgetNs)
	line, outcome := r.readLine(lineMaxPreAuth)
	if outcome != readOK {
		authEnd(c, outcome, tr)
		return true
	}
	v, code := parseLine(line)
	if code != "" {
		authEndCode(c, "malformed", tr)
		return true
	}
	// A first line carrying a verb key is auth_required regardless of what
	// else it holds (D2); anything else must be exactly
	// {"agent":"<id>","auth":"<128 hex>"}.
	for _, m := range v.membs {
		if m.key == "verb" {
			authEndCode(c, "preauth", tr)
			return true
		}
	}
	var agentID, authHex string
	haveAgent, haveAuth := false, false
	for _, m := range v.membs {
		if m.val.kind != jStr {
			authEndCode(c, "malformed", tr)
			return true
		}
		switch m.key {
		case "agent":
			if haveAgent {
				authEndCode(c, "malformed", tr)
				return true
			}
			agentID, haveAgent = m.val.str, true
			tr.claimed = agentID
		case "auth":
			if haveAuth {
				authEndCode(c, "malformed", tr)
				return true
			}
			authHex, haveAuth = m.val.str, true
		default:
			authEndCode(c, "malformed", tr)
			return true
		}
	}
	if !haveAgent || !haveAuth {
		authEndCode(c, "malformed", tr)
		return true
	}
	// Resolve the claimed id against the session's keyring: unknown ids
	// and revoked keys are refused by name (D2), and revocation is
	// checked before the signature — a revoked credential never reaches
	// the verify path.
	row := kr.lookup(agentID)
	if row == nil {
		authEndCode(c, "agent_unknown", tr)
		return true
	}
	if kr.revoked[row.pub] {
		authEndCode(c, "agent_revoked", tr)
		return true
	}
	verdict := agentVerify(authHex, &challenge, row)
	wipeBytes(challenge[:])
	wipeBytes(line) // the reply bytes held the signature
	if !verdict {
		authEndCode(c, "sig", tr)
		return true
	}
	tr.authed = true
	consoleFn(markerAuthOK + " agent=" + agentID)
	sess := &sessionCtx{agentID: agentID, caps: row.caps, allowExec: allowExec}

	var sb strings.Builder
	sb.WriteString(`{"ok":true,"session":"ready","agent":`)
	jwriteStr(&sb, agentID)
	sb.WriteString(`,"caps":[`)
	for i, capw := range row.list {
		if i > 0 {
			sb.WriteByte(',')
		}
		jwriteStr(&sb, capw)
	}
	sb.WriteString(`],"verbs":[`)
	for i, verb := range advertisedVerbs(sess) {
		if i > 0 {
			sb.WriteByte(',')
		}
		jwriteStr(&sb, verb)
	}
	sb.WriteString(`]}`)
	if err := sendLine(c, sb.String()); err != nil {
		tr.end = "client_close"
		consoleFn(markerSessEnd + "client_close")
		return false
	}

	// Request loop: one response per line, strictly in order — a
	// streamed verb emits its chunk lines ahead of its result.
	for {
		c.SetRecvDeadline(idleBudgetNs)
		line, outcome := r.readLine(lineMaxSession)
		switch outcome {
		case readOK:
		case readPeerGone:
			tr.end = "client_close"
			consoleFn(markerSessEnd + "client_close")
			return false
		case readTimeout:
			_ = sendLine(c, respondErr(-1, "idle_timeout", errMessages["idle_timeout"]))
			tr.end = "idle_timeout"
			consoleFn(markerSessEnd + "idle_timeout")
			return false
		case readTooLong:
			_ = sendLine(c, respondErr(-1, "line_too_long", errMessages["line_too_long"]))
			tr.end = "line_too_long"
			consoleFn(markerSessEnd + "line_too_long")
			return false
		default:
			tr.end = "io_error"
			consoleFn(markerSessEnd + "io_error")
			return false
		}
		serveLine(c, line, sess)
	}
}

// authEnd maps a pre-auth read outcome onto its D2/D4 ending. The trail
// records the end reason and — where a verdict fired — its named refusal
// for the auth_fail receipt; a peer that vanished or overran the line
// limit without a verdict leaves only the close.
func authEnd(c connIO, outcome int, tr *sessionTrail) {
	switch outcome {
	case readTimeout:
		_ = sendLine(c, respondErr(-1, "auth_timeout", errMessages["auth_timeout"]))
		consoleFn(markerAuthFail + "timeout")
		tr.verdict = "auth_timeout"
		tr.end = "auth_timeout"
		consoleFn(markerSessEnd + "auth_timeout")
	case readPeerGone:
		tr.end = "client_close"
		consoleFn(markerSessEnd + "client_close")
	case readTooLong:
		_ = sendLine(c, respondErr(-1, "line_too_long", errMessages["line_too_long"]))
		tr.end = "line_too_long"
		consoleFn(markerSessEnd + "line_too_long")
	default:
		tr.end = "io_error"
		consoleFn(markerSessEnd + "io_error")
	}
}

// authEndCode finishes a failed auth attempt: one error line, the auth-fail
// marker with its D2 reason, and the session-end line. agent_unknown and
// agent_revoked carry their own wire codes (ADR 0052 D2 — a refused
// credential is named); everything else maps onto the v1 codes. The trail
// records the wire code as the verdict and the end reason alike.
func authEndCode(c connIO, reason string, tr *sessionTrail) {
	code := "auth_failed"
	msg := errMessages["auth_failed"]
	switch reason {
	case "preauth":
		code = "auth_required"
		msg = errMessages["auth_required"]
	case "agent_unknown", "agent_revoked":
		code = reason
		msg = errMessages[reason]
	}
	_ = sendLine(c, respondErr(-1, code, msg))
	tr.verdict = code
	tr.end = code
	consoleFn(markerAuthFail + reason)
	consoleFn(markerSessEnd + code)
}

// serveLine parses one post-auth line, runs it through dispatch, and writes
// the response with its req/refuse marker. Every refusal here is non-fatal
// (D4: the fatal codes are transport-level and handled by the caller).
// sess.emit carries a verb's bounded output chunks as stream lines ahead
// of the single result line.
func serveLine(c connIO, line []byte, sess *sessionCtx) {
	id := int64(-1)
	verb := "-"
	v, code := parseLine(line)
	var req *request
	if code == "" {
		req, code = validateRequest(v)
		id = reqID(req)
	}
	if req != nil && req.hasVerb {
		verb = req.verb
	}
	var result string
	if code == "" {
		seq := 0
		sess.emit = func(chunk []byte) {
			var sb strings.Builder
			sb.WriteString(`{"id":`)
			writeID(&sb, id)
			sb.WriteString(`,"ok":true,"stream":`)
			sb.WriteString(vi.Itoa64(int64(seq)))
			sb.WriteString(`,"data_b64":`)
			jwriteStr(&sb, b64Encode(chunk))
			sb.WriteByte('}')
			_ = sendLine(c, sb.String())
			seq++
		}
		result, code = dispatch(req, sess)
	}
	// Every dispatch leaves a receipt — the D4 record lands before the
	// answer so the attempt is on file even if the send cannot be.
	auditVerb(sess, verb, req, result, code)
	bare, detail := splitCode(code)
	if bare == "" {
		if err := sendLine(c, respondOK(id, result)); err == nil {
			consoleFn(markerReq + vi.Itoa64(id) + " verb=" + verb + " ok")
		}
		return
	}
	msg := errMessages[bare]
	if msg == "" {
		msg = "request refused"
	}
	if detail != "" {
		msg += ": " + detail
	}
	_ = sendLine(c, respondErr(id, bare, msg))
	consoleFn(markerRefuse + vi.Itoa64(id) + " verb=" + verb + " code=" + bare)
}

// reqID projects the response id: the parsed id when the request carried a
// readable one, else -1 which the writer renders as null.
func reqID(req *request) int64 {
	if req != nil && req.hasID {
		return req.id
	}
	return -1
}

// splitCode splits a "code:detail" dispatch return (io_error carries its
// errno name after the colon) into the D4 code the envelope reports and
// the detail the message carries.
func splitCode(code string) (bare, detail string) {
	for i := 0; i < len(code); i++ {
		if code[i] == ':' {
			return code[:i], code[i+1:]
		}
	}
	return code, ""
}

// errMessages is the fixed English sentence per D4 code. Messages never
// echo request bytes — the detail (an errno name) is appended at send time
// for io_error only.
var errMessages = map[string]string{
	"bad_json":         "line is not a single JSON object",
	"bad_request":      "request is missing, mistyped or out of range",
	"unknown_verb":     "verb is not supported",
	"path_rejected":    "path is not a sandbox NAME",
	"not_found":        "object does not exist",
	"access_denied":    "kernel denied access",
	"not_a_file":       "name is a directory",
	"too_large":        "size limit exceeded",
	"cmd_rejected":     "command is outside the allowed grammar",
	"verb_disabled":    "verb is not enabled on this daemon",
	"spawn_failed":     "could not start the command",
	"timed_out":        "command exceeded its time budget",
	"rate_limited":     "request exceeds its per-session rate bound",
	"seat_unsupported": "the window seat cannot answer this query",
	"seat_absent":      "no window seat is running",
	"seat_timeout":     "the window seat did not answer in time",
	// M139b: the seat's kind-29 refusal names surface verbatim (R2).
	"agent_input_denied":   "the window seat refused agent input",
	"agent_input_no_focus": "no focused window pane accepts input",
	"cap_required":         "the agent's declared caps do not include this capability",
	"agent_unknown":        "no keyring row names this agent",
	"agent_revoked":        "the keyring revokes this credential",
	"io_error":             "kernel call failed",
	"auth_required":        "authenticate before sending requests",
	"auth_failed":          "authentication failed",
	"auth_timeout":         "authentication did not complete in time",
	"line_too_long":        "line exceeds its byte limit",
	"idle_timeout":         "session idle too long",
}
