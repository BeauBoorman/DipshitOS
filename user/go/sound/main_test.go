// main_test.go — the play-mode argv pin: parsePlayArgs picks the first
// non-flag argument as the path and --resampler=sinc|linear the engine,
// unknown values falling back to the default rather than refusing.
package main

import (
	"testing"

	"virelai/pcm"
)

func TestParsePlayArgs(t *testing.T) {
	cases := []struct {
		args []string
		path string
		rs   pcm.Resampler
	}{
		{[]string{"/host/x.wav"}, "/host/x.wav", pcm.ResampleSinc},
		{[]string{"/host/x.wav", "--resampler=linear"}, "/host/x.wav", pcm.ResampleLinear},
		{[]string{"--resampler=linear", "/host/x.wav"}, "/host/x.wav", pcm.ResampleLinear},
		{[]string{"--resampler=sinc", "/host/x.wav"}, "/host/x.wav", pcm.ResampleSinc},
		// An unknown value falls back to the default, not a refusal.
		{[]string{"--resampler=bogus", "/host/x.wav"}, "/host/x.wav", pcm.ResampleSinc},
		{nil, "", pcm.ResampleSinc},
	}
	for i, c := range cases {
		path, rs := parsePlayArgs(c.args)
		if path != c.path || rs != c.rs {
			t.Fatalf("case %d: got (%q,%d), want (%q,%d)", i, path, rs, c.path, c.rs)
		}
	}
}
