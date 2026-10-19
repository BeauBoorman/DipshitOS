package vsockctl

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

// The ADR 0056 D2 pinned vector (computed with Python hmac/hashlib while
// drafting the ADR): key = ASCII "a5" x 32, challenge = 00 01 .. 1f.
var (
	pinKey       = bytes.Repeat([]byte("a5"), 32)
	pinChallenge = [32]byte{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
		16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31}
	pinMAC = "87b459ff70564dd354e1415d16618cc768bf5f2181124a2b495c73b01e274b6c"
)

func TestAuthLinePinnedVector(t *testing.T) {
	line := string(AuthLine(pinKey, pinChallenge))
	want := `{"auth":"` + pinMAC + `"}` + "\n"
	if line != want {
		t.Fatalf("AuthLine = %q want %q", line, want)
	}
}

func TestEncodeRequestShape(t *testing.T) {
	l, err := EncodeRequest(1, "suspend", "")
	if err != nil || string(l) != "{\"id\":1,\"verb\":\"suspend\"}\n" {
		t.Fatalf("suspend = %q err=%v", l, err)
	}
	l, err = EncodeRequest(2, "snapshot", "BEFORE-1.2_x")
	if err != nil || string(l) != "{\"id\":2,\"verb\":\"snapshot\",\"name\":\"BEFORE-1.2_x\"}\n" {
		t.Fatalf("snapshot = %q err=%v", l, err)
	}
	for _, bad := range []struct{ id uint32; verb, name string }{
		{0, "suspend", ""},
		{1, "bad verb", ""},
		{1, "evil\"x", ""},
		{1, "", ""},
		{1, "snapshot", "a/b"},
		{1, "snapshot", strings.Repeat("n", 32)},
	} {
		if _, err := EncodeRequest(bad.id, bad.verb, bad.name); err == nil {
			t.Fatalf("EncodeRequest(%d,%q,%q) unexpectedly ok", bad.id, bad.verb, bad.name)
		}
	}
}

func TestParseGreeting(t *testing.T) {
	line := []byte(`{"proto":"virelai-ctl/1","auth":"hmac-sha256","challenge":"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"}`)
	g, ok := ParseGreeting(line)
	if !ok || g.Challenge != pinChallenge || g.Proto != Proto {
		t.Fatalf("greeting parse failed: %+v ok=%v", g, ok)
	}
	for _, bad := range []string{
		`{"proto":"virelai-ctl/1","auth":"hmac-sha256","challenge":"zz0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"}`,
		`{"proto":"virelai-ctl/1","auth":"hmac-sha256","challenge":"00"}`,
		`{"proto":"other","auth":"hmac-sha256","challenge":"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"}`,
		`not json`,
		`{"proto":"virelai-ctl/1","auth":"hmac-sha256"}`,
	} {
		if _, ok := ParseGreeting([]byte(bad)); ok {
			t.Fatalf("greeting %q unexpectedly parsed", bad)
		}
	}
}

func TestParseReplyVerdicts(t *testing.T) {
	r, err := ParseReply([]byte(`{"id":1,"ok":true,"result":{"verb":"suspend"}}`))
	if err != nil || !r.OK || r.ID != 1 {
		t.Fatalf("ok reply: %+v err=%v", r, err)
	}
	r, err = ParseReply([]byte(`{"id":2,"ok":false,"error":{"code":"replay","message":"id must increase"}}`))
	if err != nil || r.OK || r.ID != 2 || r.Code != "replay" {
		t.Fatalf("err reply: %+v err=%v", r, err)
	}
	for _, bad := range []string{
		`{"id":1}`,
		`{"id":"x","ok":true}`,
		`{"id":1,"ok":false,"error":{"message":"no code"}}`,
		`{}`,
		`[1,2]`,
		`{"id":1,"ok":true}x`,
	} {
		if _, err := ParseReply([]byte(bad)); err == nil {
			t.Fatalf("reply %q unexpectedly parsed", bad)
		}
	}
}

// scripted is a Transport playing the server: writes go to w, reads
// replay r. A Session over it exercises the whole client flow.
type scripted struct {
	r *bytes.Buffer
	w *bytes.Buffer
}

func (s *scripted) Read(p []byte) (int, error)  { return s.r.Read(p) }
func (s *scripted) Write(p []byte) (int, error) { return s.w.Write(p) }

func greetingLine(challengeHex string) string {
	return `{"proto":"virelai-ctl/1","auth":"hmac-sha256","challenge":"` + challengeHex + `"}` + "\n"
}

func TestSessionHappyPath(t *testing.T) {
	tr := &scripted{r: &bytes.Buffer{}, w: &bytes.Buffer{}}
	tr.r.WriteString(greetingLine("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
	tr.r.WriteString(`{"ok":true,"session":"ready","verbs":["suspend","snapshot"]}` + "\n")
	tr.r.WriteString(`{"id":1,"ok":false,"error":{"code":"unimplemented","message":"verb deferred"}}` + "\n")
	tr.r.WriteString(`{"id":2,"ok":false,"error":{"code":"unknown_verb","message":"no such verb"}}` + "\n")

	s := NewSession(pinKey)
	if err := s.Handshake(tr); err != nil {
		t.Fatalf("handshake: %v", err)
	}
	if !strings.Contains(tr.w.String(), `"auth":"`+pinMAC+`"`) {
		t.Fatalf("client sent %q want pinned MAC", tr.w.String())
	}
	r, err := s.Call(tr, "suspend", "")
	if r.ID != 1 || r.OK {
		t.Fatalf("reply: %+v", r)
	}
	var re *ReplyError
	if !errors.As(err, &re) || re.Code != CodeUnimplemented {
		t.Fatalf("call err=%v want unimplemented", err)
	}
	if _, err := s.Call(tr, "frobnicate", ""); !errors.As(err, &re) || re.Code != CodeUnknownVerb {
		t.Fatalf("call err=%v want unknown_verb", err)
	}
	if !strings.Contains(tr.w.String(), `{"id":2,"verb":"frobnicate"}`) {
		t.Fatalf("second request missing: %q", tr.w.String())
	}
}

func TestSessionRefusals(t *testing.T) {
	// Bad-MAC analogue: the host refuses the answer with auth_failed.
	tr := &scripted{r: &bytes.Buffer{}, w: &bytes.Buffer{}}
	tr.r.WriteString(greetingLine("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
	tr.r.WriteString(`{"ok":false,"error":{"code":"auth_failed","message":"bad mac"}}` + "\n")
	var re *ReplyError
	if err := NewSession(pinKey).Handshake(tr); !errors.As(err, &re) || re.Code != CodeAuthFailed {
		t.Fatalf("handshake err=%v want auth_failed", err)
	}

	// A malformed greeting is refused before any auth bytes are sent.
	tr = &scripted{r: &bytes.Buffer{}, w: &bytes.Buffer{}}
	tr.r.WriteString("garbage\n")
	if err := NewSession(pinKey).Handshake(tr); err != ErrProtocol {
		t.Fatalf("handshake err=%v want ErrProtocol", err)
	}
	if tr.w.Len() != 0 {
		t.Fatalf("client sent %q on a malformed greeting", tr.w.String())
	}
}

// M128d (#2608): `profile-info` is a bare-verb request on the wire, and
// its ok reply carries the flat `result` object the kernel relays. The
// guest-side field decode lives in vi (slot 93 owns the relay); this is
// the wire shape the transport-level session must pass through.
func TestProfileInfoOnTheWire(t *testing.T) {
	req, err := EncodeRequest(7, "profile-info", "")
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if string(req) != `{"id":7,"verb":"profile-info"}`+"\n" {
		t.Fatalf("request = %q (must carry no name member)", req)
	}
	r, err := ParseReply([]byte(`{"id":7,"ok":true,"result":{"profile":"prof","base":"disk.img","rollback":true,"snapshots":2}}`))
	if err != nil || !r.OK || r.ID != 7 {
		t.Fatalf("result reply: %+v err=%v", r, err)
	}
	// A name member on profile-info is the host's bad_request refusal.
	r, err = ParseReply([]byte(`{"id":8,"ok":false,"error":{"code":"bad_request","message":"profile-info takes no name"}}`))
	if err != nil || r.OK || r.Code != "bad_request" {
		t.Fatalf("bad_request reply: %+v err=%v", r, err)
	}
}
