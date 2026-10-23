package main

// mime_test.go — the BODYSTRUCTURE policy half: readable-part picking,
// attachment naming/refusal, and the HTML stripper.

import (
	"strings"
	"testing"
)

func mustParse(t *testing.T, s string) []form {
	t.Helper()
	toks, err := parseRecord([]byte(s))
	if err != nil {
		t.Fatalf("parse %q: %v", s, err)
	}
	l, ok := formList(toks[0])
	if !ok {
		t.Fatalf("not a list: %q", s)
	}
	return l
}

func TestWalkSinglePart(t *testing.T) {
	root := walkPart(mustParse(t,
		`("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL "7BIT" 52 3)`), "")
	if root.media != "text" || root.sub != "plain" || root.size != 52 {
		t.Fatalf("leaf %+v", root)
	}
	if !root.isReadable() || root.isAttachment() {
		t.Fatalf("readable leaf %+v", root)
	}
	if root.section() != "TEXT" {
		t.Fatalf("section %q", root.section())
	}
}

func TestWalkMultipart(t *testing.T) {
	root := walkPart(mustParse(t,
		`(("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL "7BIT" 16 1) ("APPLICATION" "PDF" NIL NIL NIL "BASE64" 2048 NIL ("attachment" ("filename" "report.pdf")) NIL NIL) "MIXED")`), "")
	if root.media != "multipart" || root.multiSub != "mixed" || len(root.kids) != 2 {
		t.Fatalf("multipart %+v", root)
	}
	pdf := root.kids[1]
	if !pdf.isAttachment() || pdf.attachName() != "report.pdf" ||
		pdf.mimeType() != "application/pdf" {
		t.Fatalf("attachment %+v name=%q", pdf, pdf.attachName())
	}
	body := pickBody(root)
	if body == nil || body.num != "1" || body.section() != "1" {
		t.Fatalf("pickBody %+v", body)
	}
	atts := attachments(root)
	if len(atts) != 1 || atts[0].attachName() != "report.pdf" {
		t.Fatalf("attachments %v", atts)
	}
}

func TestPickBodyPrefersPlain(t *testing.T) {
	// multipart/alternative: plain first or not, plain wins.
	root := walkPart(mustParse(t,
		`(("TEXT" "HTML" NIL NIL NIL "7BIT" 40) ("TEXT" "PLAIN" NIL NIL NIL "7BIT" 30) "ALTERNATIVE")`), "")
	body := pickBody(root)
	if body == nil || body.sub != "plain" || body.num != "2" {
		t.Fatalf("pickBody %+v", body)
	}
	// HTML-only falls back to the html part (rendered stripped).
	root2 := walkPart(mustParse(t,
		`(("TEXT" "HTML" NIL NIL NIL "7BIT" 40) "ALTERNATIVE")`), "")
	// one-child alternative is degenerate but walkable
	body2 := pickBody(root2)
	if body2 == nil || body2.sub != "html" {
		t.Fatalf("pickBody html-only %+v", body2)
	}
	// No readable part at all → nil (the caller's named refusal).
	root3 := walkPart(mustParse(t,
		`(("APPLICATION" "PDF" NIL NIL NIL "BASE64" 9 NIL ("attachment" ("filename" "a.pdf")) NIL NIL) "MIXED")`), "")
	if pickBody(root3) != nil {
		t.Fatal("picked an attachment")
	}
}

func TestAttachNameFallback(t *testing.T) {
	p := walkPart(mustParse(t,
		`("IMAGE" "PNG" NIL NIL NIL "BASE64" 999)`), "2")
	if p.attachName() != "part-2.png" {
		t.Fatalf("attachName %q", p.attachName())
	}
	// text/calendar is M187d's domain: lists, refuses here.
	cal := walkPart(mustParse(t,
		`("TEXT" "CALENDAR" ("NAME" "invite.ics") NIL "7BIT" 100)`), "3")
	if !cal.isAttachment() || cal.attachName() != "invite.ics" {
		t.Fatalf("calendar %+v name=%q", cal, cal.attachName())
	}
}

func TestStripHTML(t *testing.T) {
	in := "<html><head><style>body{color:red}</style></head>" +
		"<body><p>html <b>hello</b></p><p>second &amp; third&nbsp;x</p>" +
		"<script>var x=1;</script></body></html>"
	out := stripHTML(in)
	if strings.Contains(out, "color:red") || strings.Contains(out, "var x") ||
		strings.Contains(out, "<") || strings.Contains(out, "&amp;") ||
		strings.Contains(out, "&nbsp;") {
		t.Fatalf("strip leaked markup: %q", out)
	}
	for _, want := range []string{"html hello", "second & third x"} {
		if !strings.Contains(out, want) {
			t.Fatalf("strip missing %q in %q", want, out)
		}
	}
}
