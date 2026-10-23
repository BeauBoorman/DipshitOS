package main

// folders_test.go — the class-A half of the folder leg: the BOXES/USE
// codecs, the box resolution order, and the `use` leg over a recorded
// session — including the refusal to select a folder the LIST never
// carried.

import (
	"strings"
	"testing"
)

func TestBoxesCodec(t *testing.T) {
	f := swapCache(t)
	if got := cacheLoadBoxes(); len(got) != 0 {
		t.Fatalf("empty cache listed %v", got)
	}
	cacheSaveBoxes([]string{"INBOX", "Sent Items", "Lists"})
	if got := cacheLoadBoxes(); len(got) != 3 || got[1] != "Sent Items" {
		t.Fatalf("roundtrip %v", got)
	}
	// The bound keeps the first cacheBoxesMax names.
	var many []string
	for i := 0; i < cacheBoxesMax+10; i++ {
		many = append(many, "B")
	}
	cacheSaveBoxes(many)
	if got := cacheLoadBoxes(); len(got) != cacheBoxesMax {
		t.Fatalf("bound kept %d", len(got))
	}
	// A name carrying the row separator is sanitized, never torn.
	cacheSaveBoxes([]string{"weird\tname\nline"})
	if got := cacheLoadBoxes(); len(got) != 1 || got[0] != "weird name line" {
		t.Fatalf("sanitized %v", got)
	}
	_ = f
}

func TestResolveBox(t *testing.T) {
	f := swapCache(t)
	if got := resolveBox("Sent"); got != "Sent" {
		t.Fatalf("explicit %q", got)
	}
	if got := resolveBox(""); got != "INBOX" {
		t.Fatalf("default %q", got)
	}
	f.put("USE", "Lists\n")
	if got := resolveBox(""); got != "Lists" {
		t.Fatalf("remembered %q", got)
	}
	if got := resolveBox("Archive"); got != "Archive" {
		t.Fatalf("explicit over remembered %q", got)
	}
}

// useScript answers LOGIN, LIST (INBOX + Sent), SELECT (3 EXISTS) — the
// same fixture rows imapScript() serves, minus the FETCH tail.
func useScript() string {
	var b strings.Builder
	b.WriteString("* OK fixture IMAP4rev1 ready\r\n")
	b.WriteString("a1 OK Login completed\r\n")
	b.WriteString("* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n")
	b.WriteString("* LIST (\\HasNoChildren) \"/\" \"Sent\"\r\n")
	b.WriteString("a2 OK List completed\r\n")
	b.WriteString("* 3 EXISTS\r\n")
	b.WriteString("* 1 RECENT\r\n")
	b.WriteString("a3 OK [READ-WRITE] Select completed\r\n")
	return b.String()
}

func TestUseLegSelectsAndRemembers(t *testing.T) {
	f := swapCache(t)
	c, fc := newScriptedIMAP(useScript())
	if err := c.greeting(); err != nil {
		t.Fatalf("greeting %v", err)
	}
	if err := c.login("gate", "gate-pass"); err != nil {
		t.Fatalf("login %v", err)
	}
	if err := useLeg(c, "Sent"); err != nil {
		t.Fatalf("useLeg %v", err)
	}
	if got := cacheLoadUse(); got != "Sent" {
		t.Fatalf("remembered %q", got)
	}
	if got := cacheLoadBoxes(); len(got) != 2 || got[1] != "Sent" {
		t.Fatalf("cached list %v", got)
	}
	w := allWrites(fc)
	if !strings.Contains(w, "LIST \"\" \"*\"") || !strings.Contains(w, "SELECT \"Sent\"") {
		t.Fatalf("wire %q", w)
	}
	_ = f
}

func TestUseLegRefusesFakeFolder(t *testing.T) {
	swapCache(t)
	c, fc := newScriptedIMAP(useScript())
	if err := c.greeting(); err != nil {
		t.Fatalf("greeting %v", err)
	}
	if err := c.login("gate", "gate-pass"); err != nil {
		t.Fatalf("login %v", err)
	}
	err := useLeg(c, "Nope")
	if err == nil || err.Error() != "gomail: refuse use Nope" {
		t.Fatalf("fake folder %v", err)
	}
	if strings.Contains(allWrites(fc), "SELECT") {
		t.Fatal("SELECTed a folder the LIST never carried")
	}
	if got := cacheLoadUse(); got != "" {
		t.Fatalf("remembered a refusal %q", got)
	}
	// The proved LIST still cached — memory of real folders.
	if got := cacheLoadBoxes(); len(got) != 2 {
		t.Fatalf("cached list %v", got)
	}
}

func TestOfflineUse(t *testing.T) {
	f := swapCache(t)
	f.put("BOXES", "INBOX\nSent\n")
	if err := offlineUse("Sent"); err != nil {
		t.Fatalf("offlineUse %v", err)
	}
	if got := cacheLoadUse(); got != "Sent" {
		t.Fatalf("remembered %q", got)
	}
	err := offlineUse("Nope")
	if err == nil || err.Error() != "gomail: cache-miss use Nope" {
		t.Fatalf("unknown box %v", err)
	}
}
