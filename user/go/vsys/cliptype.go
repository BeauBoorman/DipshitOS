package vsys

// Milestone 124c (#2582): the typed clipboard. The kernel buffer stays a
// raw byte store — clipboard.go's comment on image bytes applies here too,
// so there is no envelope slot, no sideband and no kernel diff. The TYPE is
// a reading of the bytes, not a field: ClipboardClassify derives it (magic
// for images, shape for the text types), so every writer — a cap holder's
// Set, the monitor's `clip`, the seat's lane apply — is classified by the
// same rule, and every legacy reader (slot 39, the kernel's own paste
// chords) still sees the blob, undisturbed. "paste as PNG" works because
// the buffer holds the PNG; "paste path" works because text/uri-list IS
// text.
//
// The consequence for writers is honesty, not ceremony: ClipboardSetTyped
// takes the caller's DECLARED mime and refuses it when the bytes cannot be
// that thing — the same rule the drag arm pins ("the ghost's label and the
// delivered bytes can never describe different things"). A reader never
// sees the declaration at all; it sees the classification of the bytes.
//
// Bounds: the blob is the kernel buffer's own 512 (ClipboardSetAll's
// bound — the lane the seat drives is the same 512 minus the typed
// envelope's header), the mime spelling is ClipMimeMax = the drag frame's
// title bound, and this file spends no error interface for the same reason
// clipboard.go does not.

import "unicode/utf8"

// The M124c vocabulary. The image spellings are the formats the in-tree
// mime table's magic rules already cover (mime/mime.go); ClipOctet is the
// "bytes we cannot name" answer, never a label a writer should reach for.
const (
	ClipText    = "text/plain"
	ClipURIList = "text/uri-list"
	ClipHTML    = "text/html"
	// M132b (#2753): a CSV body is a text/plain refinement — same UTF-8
	// shape rule, a name GOSHEET's paste lane can declare honestly.
	ClipCSV     = "text/csv"
	ClipPNG     = "image/png"
	ClipQOI     = "image/qoi"
	ClipGIF     = "image/gif"
	ClipJPEG    = "image/jpeg"
	ClipBMP     = "image/bmp"
	ClipOctet   = "application/octet-stream"
)

// ClipMimeMax bounds a mime spelling: 24, the WM_RPC frame's title budget
// (vi.WmRpcTitleMax) — a type the drag arm could not carry does not belong
// on the clipboard either.
const ClipMimeMax = 24

// ClipKernelMax is the kernel buffer's capacity — the typed API's blob
// bound, re-stated so callers do not have to know which file owns it.
const ClipKernelMax = 512

// ClipboardClassify derives the mime a byte body IS. Empty is text/plain
// (an empty clipboard is a state, not a type — callers check len first).
// The order is the card's order: magic first, then the text shapes, then
// the honest fallback. A PNG called "notes.txt" is image/png; a text body
// that is a URI on every line is text/uri-list; markup is text/html; any
// other valid UTF-8 is text/plain; anything else is octet-stream.
func ClipboardClassify(b []byte) string {
	if len(b) == 0 {
		return ClipText
	}
	if m := clipImageMagic(b); m != "" {
		return m
	}
	if !utf8.Valid(b) {
		return ClipOctet
	}
	if clipURIListShape(b) {
		return ClipURIList
	}
	if clipHTMLShape(b) {
		return ClipHTML
	}
	return ClipText
}

// ClipSpellingOK validates a mime spelling: "type/subtype" — lowercase
// letters, digits, '+', '-', '.', exactly one '/', neither side empty, and
// the whole thing inside ClipMimeMax.
func ClipSpellingOK(mime string) bool {
	if len(mime) == 0 || len(mime) > ClipMimeMax {
		return false
	}
	slash := -1
	for i := 0; i < len(mime); i++ {
		c := mime[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9',
			c == '+', c == '-', c == '.':
		case c == '/':
			if slash >= 0 {
				return false
			}
			slash = i
		default:
			return false
		}
	}
	return slash > 0 && slash < len(mime)-1
}

// ClipShapeOK reports whether blob can honestly carry the declared mime.
// The vocabulary is closed — the spellings above plus ClipOctet — because a
// type nobody can read back is a label that lies. text/plain requires valid
// UTF-8 (a "text" that is not text is the lane refusal this check exists to
// catch at write time); the text types add their shape rule; the image
// types require their magic; octet-stream takes anything (it claims
// nothing).
func ClipShapeOK(mime string, blob []byte) bool {
	switch mime {
	case ClipText, ClipCSV:
		return utf8.Valid(blob)
	case ClipURIList:
		return utf8.Valid(blob) && clipURIListShape(blob)
	case ClipHTML:
		return utf8.Valid(blob) && clipHTMLShape(blob)
	case ClipPNG, ClipQOI, ClipGIF, ClipJPEG, ClipBMP:
		return clipImageMagic(blob) == mime
	case ClipOctet:
		return true
	}
	return false
}

// clipImageMagic is the image half of classify — the subset of
// mime/mime.go's magic table the clipboard vocabulary names.
func clipImageMagic(b []byte) string {
	switch {
	case hasBytesPrefix(b, "\x89PNG\r\n\x1a\n"):
		return ClipPNG
	case hasBytesPrefix(b, "qoif"):
		return ClipQOI
	case hasBytesPrefix(b, "GIF87a"), hasBytesPrefix(b, "GIF89a"):
		return ClipGIF
	case hasBytesPrefix(b, "\xff\xd8\xff"):
		return ClipJPEG
	case hasBytesPrefix(b, "BM"):
		return ClipBMP
	}
	return ""
}

// clipURIListShape is the RFC 2483 reading: every non-empty line is a URI —
// a scheme token ('a-z0-9+.-' then ':') with no spaces. A body whose lines
// are not all URIs is not a list; a URI set inside prose is not a list
// either.
func clipURIListShape(b []byte) bool {
	nonempty := 0
	start := 0
	for i := 0; i <= len(b); i++ {
		if i != len(b) && b[i] != '\n' {
			continue
		}
		line := b[start:i]
		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}
		// Blank lines are skippable layout; every NON-empty line must be
		// a URI or the body is prose, not a list.
		if len(line) > 0 {
			nonempty++
			if !clipIsURI(line) {
				return false
			}
		}
		start = i + 1
	}
	return nonempty > 0
}

// clipIsURI is the line rule: scheme ':' rest, scheme from the URI
// alphabet, and no whitespace anywhere.
func clipIsURI(line []byte) bool {
	colon := -1
	for i := 0; i < len(line); i++ {
		c := line[i]
		if c == ' ' || c == '\t' || c < 0x20 {
			return false
		}
		if c == ':' && colon < 0 {
			colon = i
		}
	}
	if colon <= 0 {
		return false
	}
	for i := 0; i < colon; i++ {
		c := line[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' {
			continue
		}
		if i > 0 && (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.') {
			continue
		}
		return false
	}
	return true
}

// clipHTMLShape reads markup: the body starts with an HTML-ish open
// ('<!doctype', '<html', '<?xml' — case-insensitive on the alpha part) or
// carries a '<tag…>'/'</tag>' pair somewhere. A plain text note containing
// a stray '<' is not markup.
func clipHTMLShape(b []byte) bool {
	if len(b) >= 5 && asciiLowerEq(b[:5], "<html") {
		return true
	}
	if len(b) >= 9 && asciiLowerEq(b[:9], "<!doctype") {
		return true
	}
	if len(b) >= 5 && hasBytesPrefix(b, "<?xml") {
		return true
	}
	// The pair rule: a '<x' open followed later by "</". Deliberately
	// cheap — clipboard markup is a hint, not a parse.
	for i := 0; i+2 < len(b); i++ {
		if b[i] == '<' && isASCIILetter(b[i+1]) {
			for j := i + 2; j+1 < len(b); j++ {
				if b[j] == '<' && b[j+1] == '/' {
					return true
				}
			}
			return false
		}
	}
	return false
}

func hasBytesPrefix(b []byte, prefix string) bool {
	if len(b) < len(prefix) {
		return false
	}
	for i := 0; i < len(prefix); i++ {
		if b[i] != prefix[i] {
			return false
		}
	}
	return true
}

func isASCIILetter(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

// asciiLowerEq compares b to lowercase want without an allocation.
func asciiLowerEq(b []byte, want string) bool {
	if len(b) < len(want) {
		return false
	}
	for i := 0; i < len(want); i++ {
		c := b[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != want[i] {
			return false
		}
	}
	return true
}

// ClipboardSetTyped is ClipboardSetAll with a declared mime. The mime must
// spell correctly AND the bytes must be able to carry it (ClipShapeOK) —
// the refusal is -(ErrEINVAL), a raw result like the rest of this package,
// so a caller can print the code and move on. The blob rides slot 38 at the
// kernel's own 512 bound; a longer body is refused whole rather than
// truncated mid-type — half a PNG is not a PNG.
func ClipboardSetTyped(mime string, blob []byte) (int, int64) {
	if !ClipSpellingOK(mime) || !ClipShapeOK(mime, blob) {
		return 0, -ErrEINVAL
	}
	if len(blob) > ClipKernelMax {
		return 0, -ErrEINVAL
	}
	return ClipboardSetAll(blob)
}

// ClipboardGetTyped is ClipboardGetInto with the classification attached:
// the mime is derived from the bytes the kernel returned, never from what
// a writer claimed. buf is the caller's uaccess-valid region (the 512-bound
// callers use for the lane).
func ClipboardGetTyped(buf []byte) (mime string, n int, rc int64) {
	n, rc = ClipboardGetInto(buf)
	if rc < 0 || n == 0 {
		return "", n, rc
	}
	return ClipboardClassify(buf[:n]), n, rc
}
