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
	// next/prev parse as names — linkact resolves them against the file.
	if n, l, ok := profileCmd("term-profile next"); !ok || l || n != "next" {
		t.Fatal("term-profile next")
	}
	if n, l, ok := profileCmd("term-profile prev"); !ok || l || n != "prev" {
		t.Fatal("term-profile prev")
	}
	if _, _, ok := profileCmd("term-profile a b"); ok {
		t.Fatal("extra args accepted")
	}
	if _, _, ok := profileCmd("exit"); ok {
		t.Fatal("non-command accepted")
	}
}

// next/prev walk the file's order and wrap at the ends; an unset or
// file-absent current enters at the head (next) or tail (prev).
func TestCycleProfile(t *testing.T) {
	ps := []termProfile{{name: "dawn"}, {name: "dusk"}, {name: "amber"}}
	if p := cycleProfile(ps, "dusk", 1); p == nil || p.name != "amber" {
		t.Fatalf("next from dusk = %+v", p)
	}
	if p := cycleProfile(ps, "amber", 1); p == nil || p.name != "dawn" {
		t.Fatalf("next from tail did not wrap: %+v", p)
	}
	if p := cycleProfile(ps, "dusk", -1); p == nil || p.name != "dawn" {
		t.Fatalf("prev from dusk = %+v", p)
	}
	if p := cycleProfile(ps, "dawn", -1); p == nil || p.name != "amber" {
		t.Fatalf("prev from head did not wrap: %+v", p)
	}
	// Entry points: no current, or a current the file no longer carries.
	for _, cur := range []string{"", "ghost"} {
		if p := cycleProfile(ps, cur, 1); p == nil || p.name != "dawn" {
			t.Fatalf("next from %q = %+v", cur, p)
		}
		if p := cycleProfile(ps, cur, -1); p == nil || p.name != "amber" {
			t.Fatalf("prev from %q = %+v", cur, p)
		}
	}
	if p := cycleProfile(nil, "dusk", 1); p != nil {
		t.Fatalf("empty file cycled to %+v", p)
	}
}

// The blob's saved name applies when the file still has it; a name the
// file dropped falls back to the file's head (the default).
func TestResolveRestore(t *testing.T) {
	ps := []termProfile{{name: "dawn"}, {name: "dusk"}}
	if p, fb := resolveRestore(ps, "dusk"); fb || p == nil || p.name != "dusk" {
		t.Fatalf("named restore = %+v fallback=%v", p, fb)
	}
	if p, fb := resolveRestore(ps, "ghost"); !fb || p == nil || p.name != "dawn" {
		t.Fatalf("absent-name restore = %+v fallback=%v", p, fb)
	}
	if p, fb := resolveRestore(nil, "dusk"); fb || p != nil {
		t.Fatalf("empty-file restore = %+v fallback=%v", p, fb)
	}
}

// The bare list stars the active profile — and nothing when none is set.
func TestProfileNamesMarked(t *testing.T) {
	ps := []termProfile{{name: "dawn"}, {name: "dusk"}}
	if got := profileNamesMarked(ps, "dusk"); got != "dawn *dusk" {
		t.Fatalf("marked list = %q", got)
	}
	if got := profileNamesMarked(ps, ""); got != "dawn dusk" {
		t.Fatalf("unset list = %q", got)
	}
}
