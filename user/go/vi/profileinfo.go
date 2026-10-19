// M128d (#2608): the `profile-info` verb — the guest-visible answer to
// "which machine is this". The kernel runs the ctl session through
// sys_vsock_ctl (slot 93): an ok reply relays its `result` member into
// the caller's buffer verbatim (the raw `{...}` span, NUL-terminated),
// so the fields below are what the host answered, never a guess.
package vi

import "strings"

// VerbProfileInfo is the read-only profile-summary request — a bare verb
// (no `name` member) answered by the host's armed profile/share state.
const VerbProfileInfo = "profile-info"

// ProfileInfo is the host's `profile-info` answer: the .virelaivm's name
// ("-" when no profile armed), the boot base image's name, whether the
// base's `.prev` survives (an OS-update rollback target), and how many
// named snapshots the share parks.
type ProfileInfo struct {
	Name      string
	Base      string
	Rollback  bool
	Snapshots uint64
}

// ProfileCtl is the slot-93 seam's shape: VsockCtl on the guest, a fake
// in host tests.
type ProfileCtl func(verb, name string, code []byte) int64

// FetchProfileInfo runs one `profile-info` session through ctl and parses
// the relayed result. The second return is the verdict word: "" on
// success, the refusal's ADR 0056 D4 name (or the kernel's errno word
// when the seam itself failed) otherwise — the caller prints it as the
// honest "no answer" rather than guessing.
func FetchProfileInfo(ctl ProfileCtl) (ProfileInfo, string) {
	var buf [512]byte
	r := ctl(VerbProfileInfo, "", buf[:])
	switch {
	case r == 0:
		if p, ok := ParseProfileInfo(buf[:]); ok {
			return p, ""
		}
		return ProfileInfo{}, "malformed"
	case r > 0:
		if r > int64(len(buf)) {
			r = int64(len(buf))
		}
		return ProfileInfo{}, string(buf[:r])
	default:
		return ProfileInfo{}, ErrnoName(r)
	}
}

// ParseProfileInfo reads the relayed `result` object the kernel wrote
// into the caller's buffer — a flat `{...}` span, possibly
// NUL-terminated. A short or malformed read reports ok=false; a
// truncated relay never parses as half a truth.
func ParseProfileInfo(raw []byte) (ProfileInfo, bool) {
	var p ProfileInfo
	for i, c := range raw {
		if c == 0 {
			raw = raw[:i]
			break
		}
	}
	s := string(raw)
	// The answer is one complete object — a truncated relay ends in the
	// middle of a member, not at a closing brace.
	if len(s) < 2 || s[0] != '{' || s[len(s)-1] != '}' {
		return p, false
	}
	name, ok := member(s, "profile")
	// The answer must name its machine — a result that omits the identity
	// field is not a profile summary.
	if !ok || name == "" {
		return p, false
	}
	p.Name = name
	p.Base, _ = member(s, "base")
	rb, _ := member(s, "rollback")
	p.Rollback = rb == "true"
	digs, ok := member(s, "snapshots")
	if !ok {
		return p, false
	}
	for i := 0; i < len(digs); i++ {
		if digs[i] < '0' || digs[i] > '9' {
			return p, false
		}
		p.Snapshots = p.Snapshots*10 + uint64(digs[i]-'0')
	}
	return p, true
}

// member extracts the `"<key>":` member's value — the contents of a
// quoted string (decoding ctlEscape's repertoire \" \\ \/ \b \f \n \r \t;
// a \u00xx refuses — a control character is not a name) or a bare literal
// run (true/false/uint) up to the next , or }. The match cannot land
// inside an earlier value: ctlEscape never emits a raw quote, so
// `"<key>":` only exists at member position.
func member(s, key string) (string, bool) {
	pat := `"` + key + `":`
	at := 0
	for {
		i := strings.Index(s[at:], pat)
		if i < 0 {
			return "", false
		}
		at += i
		// A raw `"` cannot appear inside a quoted value, so a copy of the
		// pattern embedded in one always arrives as \" — the backslash-
		// marked match is inside a string; step past it and keep looking.
		if at == 0 || s[at-1] != '\\' {
			break
		}
		at++
	}
	i := at + len(key) + 3
	if i >= len(s) {
		return "", false
	}
	if s[i] != '"' {
		j := i
		for j < len(s) && s[j] != ',' && s[j] != '}' && s[j] != ' ' && s[j] != '\t' {
			j++
		}
		return s[i:j], j > i
	}
	i++
	var b []byte
	for i < len(s) {
		c := s[i]
		if c == '"' {
			return string(b), true
		}
		if c == '\\' {
			if i+1 >= len(s) {
				return "", false
			}
			q := strings.IndexByte(`"\/bfnrt`, s[i+1])
			if q < 0 {
				return "", false
			}
			b = append(b, "\"\\/\b\f\n\r\t"[q])
			i += 2
			continue
		}
		b = append(b, c)
		i++
	}
	return "", false
}
