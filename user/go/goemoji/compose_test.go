package main

// The drift test (M146a): the Compose tab's list is the kernel's own
// compose_table, so the test re-derives the triples from
// kernel/src/input.zig and requires the Go mirror to match exactly —
// order included (the kernel shows the pairs in table order, and so does
// the tab).

import (
	"os"
	"regexp"
	"strconv"
	"testing"
)

func kernelComposePairs(t *testing.T) []Compose {
	t.Helper()
	src, err := os.ReadFile("../../../kernel/src/input.zig")
	if err != nil {
		t.Fatalf("read kernel/src/input.zig: %v (this test only runs in-tree)", err)
	}
	re := regexp.MustCompile(`\.\{ \.first = 0x([0-9A-Fa-f]+), \.second = 0x([0-9A-Fa-f]+), \.codepoint = 0x([0-9A-Fa-f]+) \}`)
	var pairs []Compose
	for _, m := range re.FindAllSubmatch(src, -1) {
		var c Compose
		for i, dst := range []*uint8{&c.First, &c.Second} {
			v, err := strconv.ParseUint(string(m[i+1]), 16, 8)
			if err != nil {
				t.Fatalf("input.zig compose usage %q: %v", m[i+1], err)
			}
			*dst = uint8(v)
		}
		v, err := strconv.ParseUint(string(m[3]), 16, 21)
		if err != nil {
			t.Fatalf("input.zig compose codepoint %q: %v", m[3], err)
		}
		c.CP = rune(v)
		pairs = append(pairs, c)
	}
	if len(pairs) == 0 {
		t.Fatal("input.zig: no compose_table rows found — the parse pattern went stale")
	}
	return pairs
}

func TestComposeDrift(t *testing.T) {
	pairs := kernelComposePairs(t)
	if len(pairs) != len(compose) {
		t.Fatalf("kernel compose_table has %d pairs, tab lists %d", len(pairs), len(compose))
	}
	for i, p := range pairs {
		if compose[i] != p {
			t.Fatalf("pair[%d]: tab alt+%02x+%02x=U+%04X, kernel alt+%02x+%02x=U+%04X",
				i, compose[i].First, compose[i].Second, compose[i].CP,
				p.First, p.Second, p.CP)
		}
	}
}

// Every compose key the kernel can name must map to a keycap letter — the
// tab's "alt+e+a" label uses the same hid_to_ascii alphabet.
func TestComposeKeysRenderable(t *testing.T) {
	for _, c := range compose {
		if _, ok := hidKey(c.First); !ok {
			t.Errorf("first usage 0x%02x has no keycap letter", c.First)
		}
		if _, ok := hidKey(c.Second); !ok {
			t.Errorf("second usage 0x%02x has no keycap letter", c.Second)
		}
	}
}
