package main

import "testing"

// Search ranking (M146a): the fuzz must order by match quality, not table
// order — a whole-word hit on a short name beats the same letters
// scattered through a long one, aliases rank beside names, and a
// non-subsequence query is a refusal, not a weak match.

func glyphOrder(q string) []rune {
	idx := filter(q, len(glyphs), func(i int) (string, []string) {
		return glyphs[i].Name, glyphs[i].Aliases
	})
	var cps []rune
	for _, i := range idx {
		cps = append(cps, glyphs[i].CP)
	}
	return cps
}

func TestFilterExact(t *testing.T) {
	got := glyphOrder("fire")
	if len(got) != 1 || got[0] != 0x1F525 {
		t.Fatalf("fire -> %v, want exactly [U+1F525]", got)
	}
}

func TestFilterRanksWordHead(t *testing.T) {
	// "sun" is a whole name AND sits inside "sunglasses": the short
	// whole-name hit must rank first, the prefix hit second.
	got := glyphOrder("sun")
	if len(got) < 2 || got[0] != 0x2600 || got[1] != 0x1F60E {
		t.Fatalf("sun -> %v, want [U+2600 sun, U+1F60E sunglasses, ...]", got[:2])
	}
}

func TestFilterSubsequence(t *testing.T) {
	// "sgls" is not a substring of anything; it must still find
	// sunglasses by subsequence, and only that.
	got := glyphOrder("sgls")
	if len(got) != 1 || got[0] != 0x1F60E {
		t.Fatalf("sgls -> %v, want [U+1F60E]", got)
	}
}

func TestFilterAlias(t *testing.T) {
	// "applause" only exists as an alias of clap.
	got := glyphOrder("applause")
	if len(got) != 1 || got[0] != 0x1F44F {
		t.Fatalf("applause -> %v, want [U+1F44F]", got)
	}
}

func TestFilterRefuses(t *testing.T) {
	if got := glyphOrder("zzz"); len(got) != 0 {
		t.Fatalf("zzz -> %v, want no matches", got)
	}
	// Subsequence means ORDER: "es" cannot match "se" backwards.
	if got := glyphOrder("tsunami"); len(got) != 0 {
		t.Fatalf("tsunami -> %v, want no matches", got)
	}
}

func TestFilterEmptyIsTableOrder(t *testing.T) {
	got := glyphOrder("")
	if len(got) != len(glyphs) {
		t.Fatalf("empty query -> %d rows, want all %d", len(got), len(glyphs))
	}
	for i, cp := range got {
		if cp != glyphs[i].CP {
			t.Fatalf("empty query reordered: [%d] = U+%04X, want U+%04X", i, cp, glyphs[i].CP)
		}
	}
}

func TestFilterCase(t *testing.T) {
	got := glyphOrder("FIRE")
	if len(got) != 1 || got[0] != 0x1F525 {
		t.Fatalf("FIRE -> %v, want [U+1F525]", got)
	}
}

func TestScoreBounds(t *testing.T) {
	if scoreString("", "anything") != 0 {
		t.Fatal("empty query must score, not refuse")
	}
	if scoreString("x", "anything") >= 0 {
		t.Fatal("absent rune must refuse")
	}
	if scoreString("up", "up") <= scoreString("up", "thumbs up") {
		t.Fatal("the tighter whole-name hit must outrank the embedded one")
	}
}
