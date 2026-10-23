package layout

import "testing"

// type keys one romaji string into the composer, the way the kernel
// delivers it: usage for the key plus the symbol it carries. Letters are
// looked up by symbol alone, so a bare Sym is the honest synthetic press.
func typeRomaji(i *IME, s string) {
	for _, r := range s {
		i.Feed(Input{Sym: r})
	}
}

func TestRomajiTableRoundTrips(t *testing.T) {
	for in, want := range kanaTable {
		var i IME
		typeRomaji(&i, in)
		if i.Preedit() != want {
			t.Errorf("%q: preedit = %q, want %q", in, i.Preedit(), want)
		}
	}
}

func TestRomajiBecomesHiragana(t *testing.T) {
	var i IME
	typeRomaji(&i, "nihongo")
	if i.Preedit() != "にほんご" {
		t.Fatalf("preedit = %q, want にほんご", i.Preedit())
	}
	want(t, i.Feed(Input{Usage: 0x28}), false, "にほんご")
	if i.Preedit() != "" {
		t.Fatal("a committed buffer must clear")
	}
}

func TestIMEKunreiSpellings(t *testing.T) {
	cases := map[string]string{
		"susi":   "すし",
		"uti":    "うち",
		"tuki":   "つき",
		"hune":   "ふね",
		"zikan":  "じかん",
		"sya":    "しゃ",
		"tya":    "ちゃ",
		"zyouzu": "じょうず",
		"midu":   "みづ",
	}
	for in, wantKana := range cases {
		var i IME
		typeRomaji(&i, in)
		// The committed form is the pin: spellings ending in n still hold
		// it pending in the pre-edit.
		if got := string(i.Flush()); got != wantKana {
			t.Errorf("%q: commit = %q, want %q", in, got, wantKana)
		}
	}
}

func TestIMEDoubledConsonantIsSmallTsu(t *testing.T) {
	cases := map[string]string{
		"gakkou": "がっこう",
		"kitte":  "きって",
		"issyo":  "いっしょ",
		"icchi":  "いっち", // the "tch" spelling
		"kekka":  "けっか",
		"zassi":  "ざっし",
	}
	for in, wantKana := range cases {
		var i IME
		typeRomaji(&i, in)
		if i.Preedit() != wantKana {
			t.Errorf("%q: preedit = %q, want %q", in, i.Preedit(), wantKana)
		}
	}
}

func TestIMENForms(t *testing.T) {
	cases := map[string]struct {
		preedit, commit string
	}{
		// pending n stays romaji in the pre-edit and resolves on commit.
		"nihon":  {"にほn", "にほん"},
		"nn":     {"ん", "ん"},
		"kanji":  {"かんじ", "かんじ"},
		"onna":   {"おんな", "おんな"},
		"genki":  {"げんき", "げんき"},
		"sinbun": {"しんぶn", "しんぶん"},
		"kin'ya": {"きんや", "きんや"}, // n' forces the ん reading, not にゃ
		"kin'en": {"きんえn", "きんえん"},
	}
	for in, want := range cases {
		var i IME
		typeRomaji(&i, in)
		if i.Preedit() != want.preedit {
			t.Errorf("%q: preedit = %q, want %q", in, i.Preedit(), want.preedit)
		}
		if got := string(i.Flush()); got != want.commit {
			t.Errorf("%q: flush = %q, want %q", in, got, want.commit)
		}
	}
	// The n' escape is what keeps んあ out of the na row.
	var i IME
	typeRomaji(&i, "n'a")
	if i.Preedit() != "んあ" {
		t.Fatalf("n'a: preedit = %q, want んあ", i.Preedit())
	}
	var j IME
	typeRomaji(&j, "na")
	if j.Preedit() != "な" {
		t.Fatalf("na: preedit = %q, want な", j.Preedit())
	}
}

func TestIMECyclesThreeForms(t *testing.T) {
	var i IME
	typeRomaji(&i, "sushi")
	space := Input{Usage: usageSpace, Sym: ' '}
	forms := []string{"すし", "スシ", "sushi"}
	for want, form := range forms {
		got, sel := i.Candidates()
		if len(got) != 3 || got[0] != "すし" || got[1] != "スシ" || got[2] != "sushi" {
			t.Fatalf("candidates = %v, want the three forms", got)
		}
		if sel != want || i.Preedit() != form {
			t.Fatalf("cycle %d: sel=%d preedit=%q, want sel=%d preedit=%q", want, sel, i.Preedit(), want, form)
		}
		i.Feed(space)
	}
	// The fourth space wraps to hiragana, and Return commits that form.
	if i.Preedit() != "すし" {
		t.Fatalf("wrapped cycle shows %q, want すし", i.Preedit())
	}
	want(t, i.Feed(Input{Usage: 0x28}), false, "すし")
}

func TestIMECommitShowsTheCycledForm(t *testing.T) {
	var i IME
	typeRomaji(&i, "sushi")
	i.Feed(Input{Usage: usageSpace, Sym: ' '}) // -> katakana
	want(t, i.Feed(Input{Usage: 0x28}), false, "スシ")
	var j IME
	typeRomaji(&j, "sushi")
	j.Feed(Input{Usage: usageSpace, Sym: ' '})
	j.Feed(Input{Usage: usageSpace, Sym: ' '}) // -> raw romaji
	want(t, j.Feed(Input{Usage: 0x28}), false, "sushi")
}

func TestIMEEditsAndCancels(t *testing.T) {
	var i IME
	typeRomaji(&i, "niho")
	want(t, i.Feed(Input{Usage: keyBksp}), false, "")
	if i.Preedit() != "にh" {
		t.Fatalf("backspace: preedit = %q, want にh", i.Preedit())
	}
	// Escape drops the buffer and is consumed; nothing reaches the text.
	want(t, i.Feed(Input{Usage: keyEsc}), false, "")
	if i.Preedit() != "" {
		t.Fatal("escape must clear the buffer")
	}
	// Backspace to empty is a clean slate: the next letter starts fresh.
	typeRomaji(&i, "ka")
	want(t, i.Feed(Input{Usage: keyBksp}), false, "")
	want(t, i.Feed(Input{Usage: keyBksp}), false, "")
	if i.Preedit() != "" {
		t.Fatal("deleting the buffer must end composition")
	}
	// The next Backspace is the surface's own.
	want(t, i.Feed(Input{Usage: keyBksp}), true, "")
}

func TestIMENonTextKeysCommitThenDoTheirJob(t *testing.T) {
	keys := []struct {
		name string
		in   Input
	}{
		{"tab", Input{Usage: keyTab}},
		{"left arrow", Input{Usage: keyLeft}},
		{"punct", Input{Usage: 0x36, Sym: ','}},
		{"digit", Input{Usage: 0x1e, Sym: '1'}},
		{"ctrl+s", Input{Usage: 0x16, Chord: true, Sym: 0x13}},
		{"capital", Input{Usage: 0x04, Shift: true, Sym: 'A'}},
	}
	for _, k := range keys {
		var i IME
		typeRomaji(&i, "sushi")
		step := i.Feed(k.in)
		if !step.Pass || string(step.Commit) != "すし" {
			t.Errorf("%s: step = {commit %q pass %v}, want the shown form then the key", k.name, string(step.Commit), step.Pass)
		}
		if i.Preedit() != "" {
			t.Errorf("%s: buffer still staged", k.name)
		}
	}
}

func TestIMEWithEmptyBufferPassesEverything(t *testing.T) {
	var i IME
	for _, in := range []Input{
		{Usage: usageSpace, Sym: ' '},
		{Usage: 0x28},
		{Usage: 0x29},
		{Sym: '\''},
		{Sym: '1'},
		{Usage: 0x16, Chord: true},
	} {
		if step := i.Feed(in); !step.Pass || len(step.Commit) != 0 {
			t.Fatalf("input %+v: empty composer must pass untouched, got %+v", in, step)
		}
	}
	// A return after the pass still passes — the surface's send fires.
	if step := i.Feed(Input{Usage: 0x28}); !step.Pass {
		t.Fatal("Return on an empty buffer is the surface's own")
	}
}

func TestIMEFlushAndCancelAlone(t *testing.T) {
	var i IME
	if got := i.Flush(); got != nil {
		t.Fatalf("empty flush = %q", string(got))
	}
	typeRomaji(&i, "kana")
	i.Cancel()
	if i.Preedit() != "" {
		t.Fatal("cancel must clear")
	}
	typeRomaji(&i, "kana")
	if got := string(i.Flush()); got != "かな" {
		t.Fatalf("flush = %q, want かな", got)
	}
}

// A flushed form is exactly what the pre-edit showed — the field never
// commits a different shape than the painter drew, save the pending n.
func TestIMECommittedTextIsTheShownForm(t *testing.T) {
	for sel := 0; sel < 3; sel++ {
		var i IME
		typeRomaji(&i, "tokyo")
		for k := 0; k < sel; k++ {
			i.Feed(Input{Usage: usageSpace, Sym: ' '})
		}
		shown := i.Preedit()
		if got := string(i.Flush()); got != shown {
			t.Fatalf("sel %d: flush %q != shown %q", sel, got, shown)
		}
	}
}
