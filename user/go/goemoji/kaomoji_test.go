package main

// The kaomoji coverage test (M146a): the fixed dozen's runes must all
// resolve through the image's real ui cascade — the same manifest and the
// same chain shape the app's chainText paints with. A rune nothing covers
// lands on the primary's .notdef and bumps the registry's notdef counter;
// this test drives Split over every kaomoji and requires the counter to
// stay at zero, so a Kaomoji tab row can never paint '?' for the app's
// own strings.

import (
	"errors"
	"os"
	"testing"

	"virelai/ttf"
)

// stagedFonts maps each manifest 8.3 share name to its image/fonts source
// — the same pairs tools/session.sh's copy block writes into the share.
var stagedFonts = map[string]string{
	"INTER.TTF":    "Inter-Regular.ttf",
	"INTERB.TTF":   "Inter-Bold.ttf",
	"INTERI.TTF":   "Inter-Italic.ttf",
	"INTERBI.TTF":  "Inter-BoldItalic.ttf",
	"FIRACODE.TTF": "FiraCode-Regular.ttf",
	"NOTOSERF.TTF": "NotoSerif-Regular.ttf",
	"CHROME.TTF":   "VirelaiChrome-Regular.ttf",
	"NOTOCJK.TTF":  "NotoSansJP-Regular.ttf",
}

// imageChain builds the ui chain over the shipped manifest and faces —
// the cascade the guest assembles from /host/FONTS.TXT.
func imageChain(t *testing.T) (*ttf.Registry, *ttf.Chain) {
	t.Helper()
	manifest, err := os.ReadFile("../../../image/fonts/fonts.txt")
	if err != nil {
		t.Fatalf("read image/fonts/fonts.txt: %v (this test only runs in-tree)", err)
	}
	specs, err := ttf.ParseManifest(manifest)
	if err != nil {
		t.Fatalf("shipped manifest does not parse: %v", err)
	}
	reg := ttf.NewRegistry(specs, func(file string) (*ttf.Face, error) {
		name, ok := stagedFonts[file]
		if !ok {
			return nil, errors.New("manifest row " + file + " has no staged source")
		}
		data, err := os.ReadFile("../../../image/fonts/" + name)
		if err != nil {
			return nil, err
		}
		return ttf.Parse(data)
	})
	ch := reg.Chain(ttf.Query{Role: "ui"})
	if ch == nil {
		t.Fatal("the shipped manifest yields no ui chain")
	}
	return reg, ch
}

func TestKaomojiCovered(t *testing.T) {
	reg, ch := imageChain(t)
	for _, k := range kaomoji {
		before := reg.Notdef()
		_ = ch.Split(k.Text)
		if reg.Notdef() != before {
			t.Fatalf("kaomoji %q leaves the cascade: %q has a rune no shipped face covers",
				k.Name, k.Text)
		}
	}
}
