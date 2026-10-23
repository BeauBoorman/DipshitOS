package layout

// ime.go — M178b (#3145): a romaji->kana composer behind the Composer
// seam stage.go names. Typed romaji accumulates as a live pre-edit shown
// in hiragana; Space cycles the shown form hiragana -> katakana -> the
// raw romaji; Return commits the shown form; Escape drops the buffer;
// Backspace shortens it; any other non-text key commits the shown form
// and then does its own job, the same don't-swallow rule Stage follows.
//
// The table is Hepburn plus the common kunrei spellings (si/ti/tu/hu,
// zi/di/du, the sya/tya rows), the small-kana x/l spellings, doubled
// consonants to the small tsu, and n/nn/n' to ん. Kanji conversion is
// refused by design: there is no dictionary (D7).

// usageSpace is the USB HID usage for the spacebar — the candidate-cycle
// key while a pre-edit is staged.
const usageSpace = 0x2c

const (
	usageEnterKey = 0x28
	usageEscKey   = 0x29
)

// kanaTable is the romaji->hiragana spelling table. Three-letter
// spellings (the yo-on rows and the small-kana prefixes) are tried before
// two-letter ones and those before single vowels, so the map's iteration
// order never decides a match. The doubled consonant and the 'n' forms
// are rules in convert, not rows: their resolution depends on the next
// letter, which a flat row cannot see.
var kanaTable = map[string]string{
	// vowels
	"a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",
	"yi": "い", "ye": "え",
	// k / g rows
	"ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
	"ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
	// s / z rows — si is the kunrei shi
	"sa": "さ", "shi": "し", "si": "し", "su": "す", "se": "せ", "so": "そ",
	"za": "ざ", "ji": "じ", "zi": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
	// t / d rows — ti/tu are the kunrei chi/tsu, di/du the kunrei ぢ/づ
	"ta": "た", "chi": "ち", "ti": "ち", "tsu": "つ", "tu": "つ",
	"te": "て", "to": "と",
	"da": "だ", "di": "ぢ", "du": "づ", "dzu": "づ", "de": "で", "do": "ど",
	// n row — ん itself is a rule (n/nn/n' and n before a consonant)
	"na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
	// h / b / p rows — hu is the kunrei fu
	"ha": "は", "hi": "ひ", "hu": "ふ", "fu": "ふ", "he": "へ", "ho": "ほ",
	"ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
	"pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
	// m / y / r / w rows — ゐ/ゑ are the historical wi/we
	"ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
	"ya": "や", "yu": "ゆ", "yo": "よ",
	"ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
	"wa": "わ", "wi": "ゐ", "we": "ゑ", "wo": "を",
	// yo-on: Hepburn sha/cha/ja and the kunrei sya/tya/zya spellings
	"kya": "きゃ", "kyu": "きゅ", "kyo": "きょ",
	"gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
	"sha": "しゃ", "shu": "しゅ", "she": "しぇ", "sho": "しょ",
	"sya": "しゃ", "syu": "しゅ", "sye": "しぇ", "syo": "しょ",
	"ja": "じゃ", "ju": "じゅ", "je": "じぇ", "jo": "じょ",
	"zya": "じゃ", "zyu": "じゅ", "zye": "じぇ", "zyo": "じょ",
	"cha": "ちゃ", "chu": "ちゅ", "che": "ちぇ", "cho": "ちょ",
	"tya": "ちゃ", "tyu": "ちゅ", "tye": "ちぇ", "tyo": "ちょ",
	"dya": "ぢゃ", "dyu": "ぢゅ", "dyo": "ぢょ",
	"nya": "にゃ", "nyu": "にゅ", "nyo": "にょ",
	"hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ",
	"bya": "びゃ", "byu": "びゅ", "byo": "びょ",
	"pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
	"mya": "みゃ", "myu": "みゅ", "myo": "みょ",
	"rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
	// loanword rows: the f and q spellings loanword kana needs
	"fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ", "fyu": "ふゅ",
	"qa": "くぁ", "qi": "くぃ", "qe": "くぇ", "qo": "くぉ",
	// small kana: x and l both spell the small forms
	"xa": "ぁ", "xi": "ぃ", "xu": "ぅ", "xe": "ぇ", "xo": "ぉ",
	"la": "ぁ", "li": "ぃ", "lu": "ぅ", "le": "ぇ", "lo": "ぉ",
	"xya": "ゃ", "xyu": "ゅ", "xyo": "ょ",
	"lya": "ゃ", "lyu": "ゅ", "lyo": "ょ",
	"xtu": "っ", "ltu": "っ",
	"xwa": "ゎ", "lwa": "ゎ",
}

// IME is a romaji->kana composer: the second Composer the field's seam
// was cut for. Its buffer is the raw romaji the user typed; the shown
// pre-edit is that buffer converted to hiragana, katakana, or echoed raw
// — Space walks the three forms while a buffer is staged. The zero value
// is a ready composer.
type IME struct {
	buf []rune
	sel int // 0 hiragana, 1 katakana, 2 raw romaji
}

// Preedit is the form the staged buffer currently shows, "" when the
// buffer is empty. The pending half of a syllable stays romaji — "nihon"
// shows にほn until the next letter resolves the n.
func (i *IME) Preedit() string {
	if len(i.buf) == 0 {
		return ""
	}
	return i.shown()
}

// Candidates lists the three forms the staged buffer can commit —
// hiragana, katakana, raw romaji — in cycle order, with the index of the
// one Preedit shows. (nil, 0) with nothing staged.
func (i *IME) Candidates() ([]string, int) {
	if len(i.buf) == 0 {
		return nil, 0
	}
	h := convertKana(i.buf, false)
	return []string{h, toKatakana(h), string(i.buf)}, i.sel
}

// Cancel drops the staged romaji without typing it.
func (i *IME) Cancel() {
	i.buf = i.buf[:0]
	i.sel = 0
}

// Flush types the shown form — a trailing 'n' resolves to ん, since a
// committed word cannot end mid-syllable — and clears the buffer.
func (i *IME) Flush() []rune {
	if len(i.buf) == 0 {
		return nil
	}
	out := []rune(i.final())
	i.Cancel()
	return out
}

// Feed advances the composer by one key-down.
//
// With an empty buffer only a romaji letter is consumed; anything else
// passes. With a buffer staged:
//   - a letter extends the romaji and drops back to the hiragana form;
//     ' does the same only right after an n, where it is the ん escape
//     ("n'a" -> んあ, not な);
//   - Space cycles the shown form hiragana -> katakana -> raw romaji;
//   - Return commits the shown form and is consumed — the surface's own
//     Return action does not fire on a key that ended a composition;
//   - Escape drops the buffer;
//   - Backspace edits the romaji one letter;
//   - any other printable key commits the shown form and then types
//     itself; every non-text key (arrows, Tab, chords) commits and then
//     does its own job — the same don't-swallow rule Stage encodes.
func (i *IME) Feed(in Input) Step {
	if in.Chord {
		return Step{Commit: i.Flush(), Pass: true}
	}
	if len(i.buf) == 0 {
		if isRomaji(in.Sym) {
			i.buf = append(i.buf, in.Sym)
			return Step{}
		}
		return Step{Pass: true}
	}
	switch {
	case isBackspace(in):
		i.buf = i.buf[:len(i.buf)-1]
		if len(i.buf) == 0 {
			i.sel = 0
		}
		return Step{}
	case isEnter(in):
		// Consumed: Return commits the shown form; it does not also do
		// the surface's Return job (a prompt's send, a dialog's accept).
		return Step{Commit: i.Flush()}
	case isEscape(in):
		i.Cancel()
		return Step{}
	case in.Sym == ' ' || in.Usage == usageSpace:
		i.sel = (i.sel + 1) % 3
		return Step{}
	case in.Sym == '\'' && i.buf[len(i.buf)-1] == 'n':
		i.buf = append(i.buf, '\'')
		i.sel = 0
		return Step{}
	case isRomaji(in.Sym):
		i.buf = append(i.buf, in.Sym)
		i.sel = 0
		return Step{}
	}
	// Everything else — a printable non-letter or a non-text key — ends
	// the composition like Stage ends a dead-key sequence: the shown form
	// commits and the key still does its job.
	return Step{Commit: i.Flush(), Pass: true}
}

// shown is the pre-edit text: the buffer converted to hiragana with any
// pending syllable left in romaji, katakana when cycled to it, or the
// romaji itself.
func (i *IME) shown() string {
	switch i.sel {
	case 1:
		return toKatakana(convertKana(i.buf, false))
	case 2:
		return string(i.buf)
	}
	return convertKana(i.buf, false)
}

// final is the committed form: the shown form with a trailing pending n
// resolved to ん (raw romaji shows the romaji regardless).
func (i *IME) final() string {
	switch i.sel {
	case 1:
		return toKatakana(convertKana(i.buf, true))
	case 2:
		return string(i.buf)
	}
	return convertKana(i.buf, true)
}

// isRomaji reports whether r is a letter the romaji buffer accepts —
// lowercase ASCII only: a shifted letter is the user's literal capital,
// typed through the commit-and-pass path instead of being swallowed into
// a syllable.
func isRomaji(r rune) bool { return r >= 'a' && r <= 'z' }

func isVowel(r rune) bool {
	return r == 'a' || r == 'i' || r == 'u' || r == 'e' || r == 'o'
}

func isConsonant(r rune) bool { return isRomaji(r) && !isVowel(r) }

func isEnter(in Input) bool {
	return in.Usage == usageEnterKey ||
		in.Usage == 0 && (in.Sym == '\r' || in.Sym == '\n')
}

func isEscape(in Input) bool {
	return in.Usage == usageEscKey || in.Usage == 0 && in.Sym == 0x1b
}

// convertKana renders a romaji buffer as hiragana. Greedy longest match:
// 'n' disambiguates by what follows it (a vowel or 'y' keeps it in the
// na/nya rows, ' makes it ん outright, a doubled 'nn' is ん — except
// before a vowel, where "nna" is ん + な — and any other consonant
// resolves it to ん, so "kanji" is かんじ), and a doubled non-n consonant
// is the small tsu, as is the 't' of "tch". final resolves a trailing
// pending 'n' to ん for the committed form. A rune no row or rule owns
// stays as literal text in the output.
func convertKana(buf []rune, final bool) string {
	out := make([]rune, 0, len(buf))
	emit := func(s string) { out = append(out, []rune(s)...) }
	for i := 0; i < len(buf); {
		if buf[i] == 'n' {
			if i+1 >= len(buf) {
				if final {
					emit("ん")
				} else {
					out = append(out, 'n')
				}
				i++
				continue
			}
			switch next := buf[i+1]; {
			case next == '\'':
				emit("ん")
				i += 2
				continue
			case isVowel(next) || next == 'y':
				// na-row or nya-row: the table match below takes it.
			case next == 'n':
				emit("ん")
				if i+2 < len(buf) && (isVowel(buf[i+2]) || buf[i+2] == 'y') {
					i++ // "nna" is ん + な: only the first n is the ん
				} else {
					i += 2 // "nn" is ん outright
				}
				continue
			default:
				emit("ん") // n before a consonant: "kanji" -> かんじ
				i++
				continue
			}
		} else if i+1 < len(buf) {
			// A doubled consonant is the small tsu; so is the 't' of
			// "tch" (icchi/tchi).
			if buf[i] == buf[i+1] && isConsonant(buf[i]) ||
				buf[i] == 't' && buf[i+1] == 'c' {
				emit("っ")
				i++
				continue
			}
		}
		matched := false
		for n := 3; n >= 1 && !matched; n-- {
			if i+n > len(buf) {
				continue
			}
			if s, ok := kanaTable[string(buf[i:i+n])]; ok {
				emit(s)
				i += n
				matched = true
			}
		}
		if !matched {
			out = append(out, buf[i])
			i++
		}
	}
	return string(out)
}

// toKatakana maps every hiragana rune to its katakana partner (the two
// blocks sit 0x60 apart); runes outside hiragana — a pending romaji n, a
// stray literal — pass through unchanged.
func toKatakana(s string) string {
	out := []rune(s)
	for i, r := range out {
		if r >= 0x3041 && r <= 0x3096 {
			out[i] = r + 0x60
		}
	}
	return string(out)
}

var _ Composer = (*IME)(nil)
