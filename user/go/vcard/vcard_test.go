package vcard

// vcard_test.go — host pins for the M187d (#3185) VCARD bound: the
// honoured shapes land as cards and every refused shape names its why.

import "testing"

func card(body string) string {
	return "BEGIN:VCARD\r\n" + body + "END:VCARD\r\n"
}

func TestParseFullCard(t *testing.T) {
	r, ok := Parse([]byte(card(
		"VERSION:4.0\r\n" +
			"FN:Grace Hopper\r\n" +
			"ORG:Cognition;Compiler Division\r\n" +
			"TEL;TYPE=cell:+1-555-0100\r\n" +
			"TEL;TYPE=work:+1-555-0101\r\n" +
			"EMAIL;TYPE=work:grace@example.com\r\n" +
			"N:Hopper;Grace;;;\r\n")))
	if !ok || r.Total != 1 || len(r.Cards) != 1 || len(r.Refusals) != 0 {
		t.Fatalf("r=%+v ok=%v", r, ok)
	}
	c := r.Cards[0]
	if c.FN != "Grace Hopper" || c.ORG != "Cognition;Compiler Division" {
		t.Fatalf("card=%+v", c)
	}
	if len(c.TEL) != 2 || c.TEL[0] != "+1-555-0100" || c.TEL[1] != "+1-555-0101" {
		t.Fatalf("tel=%v", c.TEL)
	}
	if len(c.EMAIL) != 1 || c.EMAIL[0] != "grace@example.com" {
		t.Fatalf("email=%v", c.EMAIL)
	}
}

func TestVersion30Reads(t *testing.T) {
	r, ok := Parse([]byte(card(
		"VERSION:3.0\r\nFN:Ada Lovelace\r\nEMAIL:ada@example.com\r\n")))
	if !ok || len(r.Cards) != 1 || r.Cards[0].FN != "Ada Lovelace" {
		t.Fatalf("r=%+v ok=%v", r, ok)
	}
}

func TestRefusalsAreNamed(t *testing.T) {
	if _, ok := Parse([]byte("just some text\n")); ok {
		t.Fatal("plain text parsed as vcard")
	}
	cases := []struct {
		name, body, why string
	}{
		{"version", "VERSION:2.1\r\nFN:X\r\n", "version"},
		{"no-fn", "VERSION:4.0\r\nN:Doe;Jane;;;\r\n", "no-fn"},
	}
	for _, c := range cases {
		r, ok := Parse([]byte(card(c.body)))
		if !ok || r.Total != 1 {
			t.Fatalf("%s: r=%+v ok=%v", c.name, r, ok)
		}
		if len(r.Cards) != 0 || len(r.Refusals) != 1 || r.Refusals[0].Why != c.why {
			t.Fatalf("%s: cards=%d refusals=%+v want why=%s",
				c.name, len(r.Cards), r.Refusals, c.why)
		}
	}
}

func TestFoldedAndEscapedFields(t *testing.T) {
	r, ok := Parse([]byte(card(
		"VERSION:4.0\r\n" +
			"FN:Dr. Strange\\, MD\r\n" +
			"ORG:A very long organisation name that an exporter fold\r\n" +
			" ed at the bound\r\n")))
	if !ok || len(r.Cards) != 1 {
		t.Fatalf("r=%+v ok=%v", r, ok)
	}
	c := r.Cards[0]
	if c.FN != "Dr. Strange, MD" {
		t.Fatalf("fn=%q", c.FN)
	}
	if c.ORG != "A very long organisation name that an exporter folded at the bound" {
		t.Fatalf("org=%q", c.ORG)
	}
}

func TestMultiCardFirstN(t *testing.T) {
	body := ""
	for i := 0; i < MaxCards+2; i++ {
		body += card("VERSION:4.0\r\nFN:Person\r\n")
	}
	r, ok := Parse([]byte(body))
	if !ok || r.Total != MaxCards+2 || len(r.Cards) != MaxCards {
		t.Fatalf("r=%+v ok=%v", r, ok)
	}
}
