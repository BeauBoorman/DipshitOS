// AGENTD.ELF — the agent control channel daemon (ADR 0044). One JSON-Lines
// session at a time on guest TCP 4747 behind an HMAC-SHA256 challenge.
// Startup posture refuses before Listen; every auth failure is damped and
// relistened; nothing sensitive is ever logged (D6).
package main

import (
	"virelai/vi"
)

// argvEnvpGuard keeps the writable segment's bss end far enough from the
// page boundary for the kernel's packed argv+envp (see GOSH.ELF).
var argvEnvpGuard [0x2000]byte

func init() {
	argvEnvpGuard[len(argvEnvpGuard)-1] = byte(len(argvEnvpGuard) & 0xff)
}

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
	// refusal is one marker and exit 1, before any Listen.
	uid, caps, ok := principalFn()
	if !ok || uid != vi.UidUser || caps != 0 {
		refuseExit("privileged")
		return
	}
	if !hasCredential() {
		refuseExit("no-credential")
		return
	}
	if !dirExists(sandboxDir) {
		refuseExit("no-root")
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

// session runs one connection: the key is loaded fresh, the greeting and
// single auth attempt run, then the request loop. The key, challenge and
// reply buffers are wiped when the session ends (D2). It returns true
// when the AUTH phase failed (the caller applies the 1 s damping before
// relistening); request-phase endings are not damped.
func session(c connIO, allowExec bool) bool {
	r := newLineReader(c)

	key, keyOK := loadKey()
	if !keyOK {
		consoleFn(markerSessEnd + "io_error")
		return false
	}
	defer wipeBytes(key)

	challenge, ok := agentChallenge()
	if !ok {
		consoleFn(markerSessEnd + "io_error")
		return false
	}
	greeting := `{"proto":"virelai-agent/1","auth":"hmac-sha256","challenge":"` +
		hexString(challenge[:]) + `"}`
	if err := sendLine(c, greeting); err != nil {
		consoleFn(markerSessEnd + "client_close")
		return false
	}

	// One auth attempt, one 10 s budget, one 256-byte line.
	c.SetRecvDeadline(authBudgetNs)
	line, outcome := r.readLine(lineMaxPreAuth)
	if outcome != readOK {
		authEnd(c, outcome, "")
		return true
	}
	v, code := parseLine(line)
	if code != "" {
		authEndCode(c, "malformed")
		return true
	}
	// A first line carrying a verb key is auth_required regardless of what
	// else it holds (D2); anything else must be exactly {"auth":"<hex>"}.
	for _, m := range v.membs {
		if m.key == "verb" {
			authEndCode(c, "preauth")
			return true
		}
	}
	if len(v.membs) != 1 || v.membs[0].key != "auth" || v.membs[0].val.kind != jStr {
		authEndCode(c, "malformed")
		return true
	}
	authHex := v.membs[0].val.str
	mac := agentMAC(key, &challenge)
	verdict := ctEqStr(hexString(mac[:]), authHex)
	wipeBytes(mac[:])
	wipeBytes(challenge[:])
	wipeBytes(line) // the reply bytes held the MAC
	if !verdict {
		authEndCode(c, "mac")
		return true
	}
	consoleFn(markerAuthOK)

	ready := `{"ok":true,"session":"ready","verbs":["proc.list","proc.get","fs.read","fs.write","ui.windows"`
	if allowExec {
		ready += `,"gosh.run"`
	}
	ready += `]}`
	if err := sendLine(c, ready); err != nil {
		consoleFn(markerSessEnd + "client_close")
		return false
	}

	// Request loop: one response per line, strictly in order.
	for {
		c.SetRecvDeadline(idleBudgetNs)
		line, outcome := r.readLine(lineMaxSession)
		switch outcome {
		case readOK:
		case readPeerGone:
			consoleFn(markerSessEnd + "client_close")
			return false
		case readTimeout:
			_ = sendLine(c, respondErr(-1, "idle_timeout", errMessages["idle_timeout"]))
			consoleFn(markerSessEnd + "idle_timeout")
			return false
		case readTooLong:
			_ = sendLine(c, respondErr(-1, "line_too_long", errMessages["line_too_long"]))
			consoleFn(markerSessEnd + "line_too_long")
			return false
		default:
			consoleFn(markerSessEnd + "io_error")
			return false
		}
		serveLine(c, line, allowExec)
	}
}

// authEnd maps a pre-auth read outcome onto its D2/D4 ending.
func authEnd(c connIO, outcome int, _ string) {
	switch outcome {
	case readTimeout:
		_ = sendLine(c, respondErr(-1, "auth_timeout", errMessages["auth_timeout"]))
		consoleFn(markerAuthFail + "timeout")
		consoleFn(markerSessEnd + "auth_timeout")
	case readPeerGone:
		consoleFn(markerSessEnd + "client_close")
	case readTooLong:
		_ = sendLine(c, respondErr(-1, "line_too_long", errMessages["line_too_long"]))
		consoleFn(markerSessEnd + "line_too_long")
	default:
		consoleFn(markerSessEnd + "io_error")
	}
}

// authEndCode finishes a failed auth attempt: one error line, the auth-fail
// marker with its D2 reason, and the session-end line.
func authEndCode(c connIO, reason string) {
	code := "auth_failed"
	msg := errMessages["auth_failed"]
	if reason == "preauth" {
		code = "auth_required"
		msg = errMessages["auth_required"]
	}
	_ = sendLine(c, respondErr(-1, code, msg))
	consoleFn(markerAuthFail + reason)
	consoleFn(markerSessEnd + code)
}

// serveLine parses one post-auth line, runs it through dispatch, and writes
// the response with its req/refuse marker. Every refusal here is non-fatal
// (D4: the fatal codes are transport-level and handled by the caller).
func serveLine(c connIO, line []byte, allowExec bool) {
	id := int64(-1)
	verb := "-"
	v, code := parseLine(line)
	var req *request
	if code == "" {
		req, code = validateRequest(v)
		id = reqID(req)
		if code == "" {
			verb = req.verb
		}
	}
	var result string
	if code == "" {
		result, code = dispatch(req, allowExec)
	}
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
	"seat_unsupported": "the window seat cannot answer this query",
	"seat_timeout":     "the window seat did not answer in time",
	"io_error":         "kernel call failed",
	"auth_required":    "authenticate before sending requests",
	"auth_failed":      "authentication failed",
	"auth_timeout":     "authentication did not complete in time",
	"line_too_long":    "line exceeds its byte limit",
	"idle_timeout":     "session idle too long",
}
