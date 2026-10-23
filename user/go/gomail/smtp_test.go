package main

// smtp_test.go — recorded SMTP submission sessions through the fake
// WireConn: reply codes, multiline EHLO, the AUTH PLAIN credential line,
// and dot-stuffing on the DATA payload.

import (
	"strings"
	"testing"
)

func smtpScript() string {
	var b strings.Builder
	b.WriteString("220 fixture ESMTP ready\r\n")
	b.WriteString("250-fixture greets virelai\r\n")
	b.WriteString("250 AUTH PLAIN\r\n")
	b.WriteString("235 2.7.0 authenticated\r\n")
	b.WriteString("250 2.1.0 sender ok\r\n")
	b.WriteString("250 2.1.5 rcpt ok\r\n")
	b.WriteString("354 end with <CR><LF>.<CR><LF>\r\n")
	b.WriteString("250 2.0.0 queued as m001\r\n")
	b.WriteString("221 2.0.0 bye\r\n")
	return b.String()
}

func TestSMTPRecordedSession(t *testing.T) {
	fc := &fakeConn{reads: []byte(smtpScript())}
	s := newSMTP(fc)
	s.now = func() int64 { return 0 }

	if err := s.hello("gate", "gate-pass"); err != nil {
		t.Fatalf("hello: %v", err)
	}
	msg := buildMessage("gate@fixture.local", []string{"alice@fixture.local"},
		"gate-one", "see report\r\n.dot line\r\nend")
	if err := s.submit("gate@fixture.local", []string{"alice@fixture.local"}, msg); err != nil {
		t.Fatalf("submit: %v", err)
	}

	w := allWrites(fc)
	for _, want := range []string{
		"EHLO virelai\r\n",
		"AUTH PLAIN " + b64encode([]byte("\x00gate\x00gate-pass")) + "\r\n",
		"MAIL FROM:<gate@fixture.local>\r\n",
		"RCPT TO:<alice@fixture.local>\r\n",
		"DATA\r\n",
		"QUIT\r\n",
	} {
		if !strings.Contains(w, want) {
			t.Fatalf("write %q missing from %q", want, w)
		}
	}
	// The leading-dot body line must be stuffed ('..' on the wire) and
	// the DATA phase must end with the lone-dot terminator.
	if !strings.Contains(w, "\r\n..dot line\r\n") {
		t.Fatalf("dot-stuffing missing in %q", w)
	}
	if !strings.HasSuffix(w, "\r\n.\r\nQUIT\r\n") {
		t.Fatalf("terminator/QUIT tail wrong in %q", w)
	}
	// The credential is exactly b64("\0gate\0gate-pass").
	if b64encode([]byte("\x00gate\x00gate-pass")) != "AGdhdGUAZ2F0ZS1wYXNz" {
		t.Fatal("b64encode drift")
	}
}

func TestSMTPRefusals(t *testing.T) {
	// greeting refusal
	fc := &fakeConn{reads: []byte("554 go away\r\n")}
	s := newSMTP(fc)
	s.now = func() int64 { return 0 }
	if err := s.hello("gate", "x"); err == nil ||
		!strings.Contains(err.Error(), "greeting refused") {
		t.Fatalf("greeting refusal %v", err)
	}

	// RCPT refusal names the server code+text.
	fc2 := &fakeConn{reads: []byte(
		"220 ready\r\n250 ehlo ok\r\n235 auth ok\r\n250 sender ok\r\n" +
			"550 5.1.1 no such user\r\n")}
	s2 := newSMTP(fc2)
	s2.now = func() int64 { return 0 }
	if err := s2.hello("gate", "x"); err != nil {
		t.Fatalf("hello2: %v", err)
	}
	err := s2.submit("g@f", []string{"nobody@f"}, []byte("x\r\n"))
	if err == nil || !strings.Contains(err.Error(), "rcpt refused") ||
		!strings.Contains(err.Error(), "550") {
		t.Fatalf("rcpt refusal %v", err)
	}
}

func TestDotStuff(t *testing.T) {
	in := "a\r\n.b\r\n..c\r\n"
	out := string(dotStuff([]byte(in)))
	if out != "a\r\n..b\r\n...c\r\n" {
		t.Fatalf("dotStuff %q", out)
	}
}
