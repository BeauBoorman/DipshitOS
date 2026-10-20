package main

import (
	"strings"
	"testing"
)

func TestParseProfiles(t *testing.T) {
	body := `# comment
dusk.font_size = large
dusk.theme = custom
dusk.palette_fg = e0e6ed
dusk.palette_bg = 0b1020
dusk.palette_accent = 7AA2F7
paper.font_size=small
paper.theme=light
bad name.font_size=large
dusk.bogus = x
dusk.font_size = bogus
`
	ps := parseProfiles(body)
	if len(ps) != 2 {
		t.Fatalf("profiles = %+v", ps)
	}
	if ps[0].name != "dusk" || len(ps[0].vals) != 5 {
		t.Fatalf("dusk = %+v", ps[0])
	}
	if ps[1].name != "paper" || len(ps[1].vals) != 2 {
		t.Fatalf("paper = %+v", ps[1])
	}
	if ps[0].keys[0] != "font_size" || ps[0].vals[0] != "large" {
		t.Fatalf("dusk = %+v %+v", ps[0].keys, ps[0].vals)
	}
}

func TestApplyProfileBody(t *testing.T) {
	p := &termProfile{name: "dusk",
		keys: []string{"font_size", "theme", "palette_bg"},
		vals: []string{"large", "custom", "0b1020"}}
	body := "#v2\nhostname=virelai\nfont_size=small\ntheme=dark\nprompt=gosh> \n"
	out := applyProfileBody(body, p)
	for _, want := range []string{
		"font_size=large", "theme=custom", "palette_bg=0b1020",
		"term_profile=dusk", "hostname=virelai", "prompt=gosh> ",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("merged body missing %q:\n%s", want, out)
		}
	}
	if strings.Count(out, "font_size=") != 1 || strings.Count(out, "theme=") != 1 {
		t.Fatalf("duplicate keys in merged body:\n%s", out)
	}
}

func TestProfileCmd(t *testing.T) {
	if n, l, ok := profileCmd("term-profile"); !ok || !l || n != "" {
		t.Fatal("bare term-profile")
	}
	if n, l, ok := profileCmd("term-profile dusk"); !ok || l || n != "dusk" {
		t.Fatal("named term-profile")
	}
	if _, _, ok := profileCmd("term-profile a b"); ok {
		t.Fatal("extra args accepted")
	}
	if _, _, ok := profileCmd("exit"); ok {
		t.Fatal("non-command accepted")
	}
}
