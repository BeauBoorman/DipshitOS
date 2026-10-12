package shlib

import "testing"

// ADR 0044 D3: the accept/refuse table for the gosh.run line gate. Every
// refusal class the ADR names is a row, plus the boundary cases that decide
// them — quoted operators pass, comments and escapes that would swallow
// the appended redirect do not.
func TestCheckAgentLine(t *testing.T) {
	accept := []string{
		"echo hello",
		"cat /host/SEED.TXT",
		"cat < /host/SEED.TXT",        // input redirect cannot write
		"echo a | cat",                // a pipe still captures the last stage
		"echo 'a>b'",                  // quoted > is data
		"echo \"a>>b\"",               // quoted >> is data
		"echo 'a&b'",                  // quoted & is data
		"echo a\\>b",                  // escaped > is a word byte
		"echo a#b",                    // # mid-word is a word byte
		"true",
		"echo a|cat",                  // pipe without spaces
		"echo ${X} $? $HOME",          // expansions are the engine's job
		"echo a\\ b",                  // escaped space inside the word
		"echo \\\"",                   // escaped quote char, no open quote
		"echo 'it'\"s\"",              // adjacent quoted segments
		"echo 'a\\'",                  // \\ inside ' is literal: a closed word
	}
	refuse := []string{
		"echo a > X",                  // the daemon owns the one redirect
		"echo a>X",                    //   ... attached or detached
		"echo a >> X",                 // append is still a redirect
		"echo a &",                    // background escapes the wait
		"a&b",                         // unquoted & anywhere
		"echo 'a",                     // unbalanced ' quote
		"echo \"a",                    // unbalanced \" quote
		"echo a\\",                    // trailing backslash
		"echo a #c",                   // a comment eats the appended redirect
		"echo a #",                    //   even an empty one
		"echo a #> X",                 //   and one holding a fake redirect
	}
	for _, c := range accept {
		if !CheckAgentLine(c) {
			t.Errorf("CheckAgentLine(%q) = refuse, want accept", c)
		}
	}
	for _, c := range refuse {
		if CheckAgentLine(c) {
			t.Errorf("CheckAgentLine(%q) = accept, want refuse", c)
		}
	}
}

// ADR 0044 D2 pinned vector: key = ASCII "a5" x 32, challenge = 00..1f,
// MAC over "VIRELAI-AGENT/1 hmac-sha256" || 0x00 || challenge. The domain
// string lives in agentd; this test proves the primitive reproduces the
// ADR's figure.
func TestHMACSHA256PinnedVector(t *testing.T) {
	k := make([]byte, 0, 64)
	for i := 0; i < 32; i++ {
		k = append(k, 'a', '5')
	}
	m := append([]byte("VIRELAI-AGENT/1 hmac-sha256"), 0)
	for i := 0; i < 32; i++ {
		m = append(m, byte(i))
	}
	got := HMACSHA256(k, m)
	var want [32]byte
	const hexv = "e907b2015a16de6504cc2bc61da0d60156c3abe2b035601372840acb58feff04"
	for i := 0; i < 32; i++ {
		var v int
		for _, c := range hexv[2*i : 2*i+2] {
			v <<= 4
			switch {
			case c >= '0' && c <= '9':
				v |= int(c - '0')
			default:
				v |= int(c-'a') + 10
			}
		}
		want[i] = byte(v)
	}
	if got != want {
		t.Fatalf("HMACSHA256 pinned vector = %x, want %x", got, want)
	}
}
