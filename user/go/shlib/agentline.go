// The M98 agent-channel helpers (ADR 0044): CheckAgentLine is the cmd
// grammar gate for AGENTD.ELF's `gosh.run`, and HMACSHA256 exports the
// package's existing HMAC construction (hmac.go) for the channel's
// challenge verifier. No copies of either primitive: the check drives the
// real tokenizer, the MAC drives the in-tree SHA-256.
package shlib

// CheckAgentLine reports whether cmd may run under `gosh.run`. The daemon
// appends its own `> /host/AGENT/AUDIT/AGENTD.OUT` capture redirect before spawning
// GOSH.ELF -c, so the check's whole job is proving that the redirect lands
// on the line the operator intended and nowhere else:
//
//   - cmd must tokenize: an unbalanced quote or a trailing backslash is a
//     refusal (the real tokenizer's errors, not a second opinion);
//   - no token may be an unquoted `>`, `>>` or `&` — the daemon owns the
//     one output redirect, and a backgrounded line escapes the wait;
//   - tokenizing `cmd + " > X"` must yield cmd's tokens plus exactly the
//     appended `tokOut` + word `X`. A `#` comment would silently eat the
//     appended redirect (the daemon would read a file that was never
//     written), and an unterminated trailing word could fuse with it —
//     both show up as a token-list mismatch here.
//
// Pipes and `<` are deliberately allowed: `a | b > OUT` still captures,
// and an input redirect cannot write outside the sandbox.
func CheckAgentLine(cmd string) bool {
	toks, err := tokenize(cmd)
	if err != nil {
		return false
	}
	for _, t := range toks {
		switch t.kind {
		case tokOut, tokAppend, tokAmp:
			return false
		}
	}
	ext, err := tokenize(cmd + " > X")
	if err != nil || len(ext) != len(toks)+2 {
		return false
	}
	for i, t := range toks {
		if ext[i] != t {
			return false
		}
	}
	return ext[len(toks)].kind == tokOut &&
		ext[len(toks)+1].kind == tokWord && ext[len(toks)+1].text == "X"
}

// HMACSHA256 is RFC 2104 HMAC over the in-tree SHA-256 (hmac.go). It exists
// so the agent channel's MAC uses the same construction GOSH's net-auth
// verifier already proves — same bytes in, same bytes out, one primitive.
func HMACSHA256(key, msg []byte) [32]byte {
	return hmacSha256(key, msg)
}
