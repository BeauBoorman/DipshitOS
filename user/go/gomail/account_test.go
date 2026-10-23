package main

// account_test.go — the settings-file codec + the consent rule, pinned
// on the pure decode half (accountApply has no vi dependency).

import "testing"

func TestAccountApply(t *testing.T) {
	var c Config
	ok := c.accountApply([]byte(
		"# gate fixture account\n" +
			"host=10.0.0.2\n" +
			"user=gate\n" +
			"pass=gate-pass\n" +
			"from=gate@fixture.local\n" +
			"sni=leaf.example.com\n" +
			"tls=on\n" +
			"imap_port=1993\n" +
			"max_headers=8\n"))
	if !ok {
		t.Fatal("decode refused a good file")
	}
	if c.Host != "10.0.0.2" || c.User != "gate" || c.Pass != "gate-pass" ||
		c.From != "gate@fixture.local" || c.ServerName != "leaf.example.com" ||
		!c.TLS || c.AllowPlain || c.IMAPPort != 1993 || c.MaxHeaders != 8 {
		t.Fatalf("decoded %+v", c)
	}
	// Transport-default ports.
	if c.smtpPort() != 465 {
		t.Fatalf("smtpPort %d", c.smtpPort())
	}
	c2 := Config{}
	if c2.imapPort() != 143 || c2.smtpPort() != 587 {
		t.Fatalf("plain defaults %d %d", c2.imapPort(), c2.smtpPort())
	}
	c2.TLS = true
	if c2.imapPort() != 993 {
		t.Fatalf("tls default %d", c2.imapPort())
	}
}

func TestAccountRefusals(t *testing.T) {
	for _, bad := range []string{
		"host",              // no '='
		"bogus=1",           // unknown key
		"tls=maybe",         // bad bool
		"imap_port=abc",     // bad number
		"imap_port=70000",   // over port bound
		"max_headers=0",     // under bound
		"max_headers=99999", // over bound
	} {
		var c Config
		if c.accountApply([]byte(bad)) {
			t.Fatalf("accepted %q", bad)
		}
	}
	// The consent rule: plain=on is the stored answer; absent = no consent.
	var c Config
	if !c.accountApply([]byte("plain=on")) || !c.AllowPlain {
		t.Fatal("plain=on consent not stored")
	}
	var c2 Config
	if !c2.accountApply([]byte("host=x")) || c2.AllowPlain {
		t.Fatal("absent plain granted consent")
	}
}
