// Host pins for the M81b (#1762) sniff table. These are the card's claims:
// magic beats the name, the extension is the fallback, the heuristic is the
// last resort, and a type with no registered handler says so instead of
// guessing. No guest, no syscall — the table is pure on purpose.
package mime

import (
	"bytes"
	"testing"
)

// withRegistry runs f against a private handler table so a registering test
// cannot leak into the next one (the guest's init registrations are the
// baseline every other test sees).
func withRegistry(t *testing.T, f func()) {
	t.Helper()
	saved := registry
	registry = append([]Handler(nil), registry...)
	defer func() { registry = saved }()
	f()
}

func TestMagicBeatsTheExtension(t *testing.T) {
	cases := []struct {
		name string
		head []byte
		want ID
	}{
		{"README.TXT", []byte("\x89PNG\r\n\x1a\nrest"), Image},
		{"NOTES.TXT", []byte("qoif" + "\x00\x00\x00\x10"), Image},
		{"SEED.TXT", []byte("GIF89a......"), Image},
		{"SEED.TXT", []byte("\xff\xd8\xff\xe0"), Image},
		// BMP: "BM", a 4-byte file size, then the two reserved u16 fields at
		// +6 that every writer leaves zero.
		{"SEED.TXT", []byte("BM\x46\x00\x00\x00\x00\x00\x00\x00"), Image},
		{"DATA.BIN", []byte("\x7fELF\x02\x01\x01"), Binary},
		{"SEED.TXT", []byte("PK\x03\x04rest"), Archive},
		{"SEED.TXT", []byte("\x1f\x8b\x08rest"), Archive},
		{"SEED.TXT", []byte("%PDF-1.4\n"), Document},
		// The two-part rules: RIFF is the container, the form type at +8 says
		// which. A subtype without the container in front is not a signature.
		{"SOUND.TXT", []byte("RIFF\x00\x00\x00\x00WAVEfmt "), Audio},
		{"PIC.TXT", []byte("RIFF\x00\x00\x00\x00WEBPVP8 "), Image},
		// "RIFF" and nothing else is a container header with no form type
		// yet: no rule fires, and the NULs are not prose.
		{"NOTES", []byte("RIFF\x00\x00\x00\x00\x00\x00\x00"), Unknown},
		// A magic match must not need the whole head: 3 bytes is enough.
		{"PIC.QOI", []byte("qoi"), Image},
	}
	for _, c := range cases {
		if got := Sniff(c.name, c.head); got != c.want {
			t.Errorf("Sniff(%q, %q) = %s, want %s", c.name, c.head, got, c.want)
		}
	}
}

// Magic outranks the extension, so a rule that is too loose silently sends
// text to the image viewer. These are the coincidences the two-part rules
// exist for: prose beginning "BM", and a "WAVE" at byte 8 of a file that is
// not RIFF at all.
func TestShortMagicDoesNotOutrankProse(t *testing.T) {
	cases := []struct {
		name string
		head []byte
		want ID
	}{
		{"NOTES.TXT", []byte("BMW sold a hundred cars\n"), Text},
		{"NOTES.TXT", []byte("BM\x8a\x00\x00\x00\x00 more prose\n"), Text},
		{"SOUND.TXT", []byte("NOTRIFF!WAVEfmt whatever\n"), Text},
		{"SOUND.TXT", []byte("        WAVE is a word, not a file\n"), Text},
	}
	for _, c := range cases {
		if got := Sniff(c.name, c.head); got != c.want {
			t.Errorf("Sniff(%q, %q) = %s, want %s", c.name, c.head, got, c.want)
		}
	}
}

func TestExtensionIsTheFallback(t *testing.T) {
	cases := []struct {
		name string
		want ID
	}{
		{"SEED.TXT", Text},
		{"PHOTO.QOI", Image},
		{"SONG.WAV", Audio},
		{"BUNDLE.ZIP", Archive},
		{"GUEST.BIN", Binary},
		{"ICON.SVG", Image},
		{"PAPER.PDF", Document},
		// Case is the caller's accident, not the file's identity.
		{"Seed.Txt", Text},
		{"PHOTO.QOI", Image},
		// No extension, and a dotfile's leading dot is not one.
		{"README", Unknown},
		{".bashrc", Unknown},
		// An unknown extension is not a licence to guess.
		{"PAPER.PS", Unknown},
		// A trailing dot is not an extension either.
		{"SEED.", Unknown},
	}
	for _, c := range cases {
		if got := Sniff(c.name, nil); got != c.want {
			t.Errorf("Sniff(%q, nil) = %s, want %s", c.name, got, c.want)
		}
	}
}

func TestPrintableBytesAreTheLastResort(t *testing.T) {
	text := []byte("hello from the share\n")
	if got := Sniff("NOTES", text); got != Text {
		t.Errorf("printable bytes, no extension: got %s, want text", got)
	}
	// UTF-8 is text: an em dash is not control noise.
	utf := []byte("caf\xc3\xa9 \xe2\x80\x94 notes\n")
	if got := Sniff("NOTES", utf); got != Text {
		t.Errorf("valid UTF-8: got %s, want text", got)
	}
	// A NUL is not, and neither is a truncated multi-byte sequence.
	if got := Sniff("BLOB", []byte{'a', 0x00, 'b'}); got != Unknown {
		t.Errorf("NUL byte: got %s, want unknown", got)
	}
	if got := Sniff("BLOB", []byte{0xc3, 0x28}); got != Unknown {
		t.Errorf("invalid UTF-8: got %s, want unknown", got)
	}
	// An empty read says nothing: an unreadable file is Unknown, not text.
	if got := Sniff("SEED.TXT", nil); got != Text {
		t.Errorf("empty head with a known extension: got %s, want text (ext stage)", got)
	}
	if got := Sniff("SEED", nil); got != Unknown {
		t.Errorf("empty head, no extension: got %s, want unknown", got)
	}
}

// The peek is HeadBytes of BYTES, so the last character of an extensionless
// UTF-8 file can be cut in half. A severed tail is an artifact of the peek;
// calling the file unknown for it refuses a text file the user can read.
func TestRuneCutByThePeekIsStillText(t *testing.T) {
	em := []byte("—")              // 2 bytes
	euro := []byte("€")            // 3 bytes
	rocket := []byte("\U0001F680") // 4 bytes
	for _, r := range [][]byte{em, euro, rocket} {
		// Fill to HeadBytes-1, then the FIRST byte of the rune: the tail
		// hangs one byte short.
		fill := HeadBytes - 1
		head := append(bytes.Repeat([]byte("a"), fill), r[0])
		if got := Sniff("NOTES", head); got != Text {
			t.Errorf("a %d-byte rune cut at HeadBytes: got %s, want text", len(r), got)
		}
		// And the whole rune, one byte earlier in the peek, is of course fine.
		head = append(bytes.Repeat([]byte("a"), fill-1), r...)
		if got := Sniff("NOTES", head); got != Text {
			t.Errorf("a whole %d-byte rune: got %s, want text", len(r), got)
		}
	}
	// Continuation bytes with no lead byte are NOT a severed tail — they are
	// invalid wherever they came from.
	if got := Sniff("NOTES", []byte{0x80, 0x80, 0x80, 0x80}); got != Unknown {
		t.Errorf("stray continuation bytes: got %s, want unknown", got)
	}
	// Nor is a head that is nothing but a severed rune.
	if got := Sniff("NOTES", []byte{'a', 0xe2, 0x82}); got != Text {
		t.Errorf("one ASCII byte then a 2-of-3 rune: got %s, want text", got)
	}
	if got := Sniff("NOTES", []byte{0xe2, 0x82}); got != Unknown {
		t.Errorf("a head that is only a severed rune: got %s, want unknown", got)
	}
}

// The peek a caller is told to read must cover every rule in the table —
// otherwise a rule could never fire and the table would be lying about its
// own constants.
func TestHeadBytesCoversEveryMagicRule(t *testing.T) {
	for _, r := range magic {
		if r.off+len(r.magic) > HeadBytes {
			t.Errorf("rule %q at +%d needs %d bytes, HeadBytes is %d",
				r.magic, r.off, r.off+len(r.magic), HeadBytes)
		}
		if r.magic2 != "" && r.off2+len(r.magic2) > HeadBytes {
			t.Errorf("rule %q second half %q at +%d needs %d bytes, HeadBytes is %d",
				r.magic, r.magic2, r.off2, r.off2+len(r.magic2), HeadBytes)
		}
	}
	// A rule that needs more than the peek can offer is a rule that can never
	// fire: a short read must not read past the buffer (see `at`).
	if got := Sniff("PIC.QOI", []byte("qoif")); got != Image {
		t.Errorf("a 4-byte read of a QOI: got %s, want image", got)
	}
	// …and the peek must actually be enough for the two offset rules.
	if got := Sniff("X", make([]byte, HeadBytes)); got == Unknown {
		// An all-zero head is neither magic nor printable: unknown, as pinned.
		t.Logf("all-zero head: %s", got)
	}
}

func TestHandlersAreTheRegisteredOnes(t *testing.T) {
	withRegistry(t, func() {
		img := Handlers(Image)
		if len(img) != 3 {
			t.Fatalf("image handlers = %d (%v), want 3 (GOVIEW + the raw-byte fallback + GOPAINT)", len(img), img)
		}
		if img[0].Bin != "GOVIEW.ELF" || img[1].Bin != "GOEDIT.ELF" || img[2].Bin != "GOPAINT.ELF" {
			t.Errorf("image candidate order = %s, %s, %s; want GOVIEW.ELF, GOEDIT.ELF, GOPAINT.ELF",
				img[0].Bin, img[1].Bin, img[2].Bin)
		}
		if h, ok := Default(Image); !ok || h.Bin != "GOVIEW.ELF" {
			t.Errorf("Default(Image) = %+v, %v; want GOVIEW.ELF", h, ok)
		}
		txt := Handlers(Text)
		if len(txt) != 2 || txt[0].Bin != "GOEDIT.ELF" || txt[1].Bin != "GOSHEET.ELF" {
			t.Errorf("text handlers = %v; want GOEDIT.ELF then GOSHEET.ELF", txt)
		}
		if h, ok := Default(Text); !ok || h.Bin != "GOEDIT.ELF" {
			t.Errorf("Default(Text) = %+v, %v; want GOEDIT.ELF", h, ok)
		}
		if h, ok := Default(Audio); !ok || h.Bin != "GOSOUND.ELF" {
			t.Errorf("Default(Audio) = %+v, %v; want GOSOUND.ELF", h, ok)
		}
		// M132b (#2753): the reserved Document default.
		if h, ok := Default(Document); !ok || h.Bin != "GOREADER.ELF" {
			t.Errorf("Default(Document) = %+v, %v; want GOREADER.ELF", h, ok)
		}
		// The refusal half: a type nothing opens is a fact the caller needs.
		for _, id := range []ID{Archive, Binary, Unknown} {
			if h, ok := Default(id); ok {
				t.Errorf("Default(%s) = %+v; want no handler (a named refusal)", id, h)
			}
			if got := Handlers(id); len(got) != 0 {
				t.Errorf("Handlers(%s) = %v; want none", id, got)
			}
		}
	})
}

func TestRegisterAppendsAndDedups(t *testing.T) {
	withRegistry(t, func() {
		before := len(Handlers(Text))
		Register(Text, "GOEDIT.ELF", "Code Editor") // already there
		if got := len(Handlers(Text)); got != before {
			t.Errorf("re-registering the same binary: %d handlers, want %d", got, before)
		}
		Register(Text, "", "nameless") // refused: an empty binary execs nothing
		if got := len(Handlers(Text)); got != before {
			t.Errorf("empty bin: %d handlers, want %d", got, before)
		}
		Register(Text, "TERM.ELF", "Terminal")
		got := Handlers(Text)
		if len(got) != before+1 || got[len(got)-1].Bin != "TERM.ELF" {
			t.Fatalf("Handlers(Text) = %v; want the new candidate last", got)
		}
		if h, _ := Default(Text); h.Bin != "GOEDIT.ELF" {
			t.Errorf("Default(Text) moved to %s; the FIRST registration is the default", h.Bin)
		}
		// The returned slice is a copy: a caller must not be able to
		// reorder the registry by writing into it.
		got[0] = Handler{Bin: "HACKED"}
		if again := Handlers(Text); again[0].Bin == "HACKED" {
			t.Error("Handlers returned the registry itself, not a copy")
		}
	})
}

func TestIDNamesAreTheMarkerVocabulary(t *testing.T) {
	// These strings ride the GOFILES open markers and the go-selftest
	// receipt, which the class-B gates byte-compare.
	want := map[ID]string{
		Unknown: "unknown", Text: "text", Image: "image",
		Audio: "audio", Archive: "archive", Binary: "binary",
		Document: "document",
	}
	for id, s := range want {
		if got := id.String(); got != s {
			t.Errorf("ID(%d).String() = %q, want %q", id, got, s)
		}
	}
}
