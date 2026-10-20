// Package mime is M81b (issue #1762): one table that says what a file IS,
// and one registry that says which app opens it.
//
// Before this package every app re-derived a file's type from its own name
// rules, and "open this" was a decision each app made differently or not at
// all. The split here is the card's: `Sniff` is PURE (bytes in, one ID out,
// host-testable with no guest and no syscall) and the handler REGISTRY is
// data, so registering a second app for a type is a table edit rather than a
// new branch in every app.
//
// The order of trust is the card's order, and it is load-bearing:
//
//	magic bytes  ->  extension  ->  printable-text heuristic  ->  Unknown
//
// Magic beats the name on purpose: a PNG called `README.TXT` is an image,
// and an app that opened it in a text editor would be lying about the bytes.
// The extension is the fallback for the formats with no distinctive magic
// (every text format), and the heuristic is the last honest resort: bytes
// with no magic, no known extension, and no control noise are text.
//
// This is NOT a MIME database. It is the small table the in-tree apps
// actually need, and it grows by adding a row (M82a's manifest `filetypes`
// column adopts this table later — never the reverse).
package mime

import (
	"strings"
	"unicode/utf8"
)

// ID is a file type in this table. The values are internal; the String form
// is what markers, receipts and menus print, and it is part of the gate
// surface (the go-selftest `mime` receipt and the GOFILES open markers).
type ID uint8

const (
	Unknown ID = iota
	Text
	Image
	Audio
	Archive
	Binary
	// M132b (#2753): documents — PDF today — are their own family so a
	// reader app can claim `opens=document` without pretending the bytes
	// are text. Magic beats the name here too: %PDF- at offset 0.
	Document
)

// String is the type's table name — the word markers and receipts carry.
func (id ID) String() string {
	switch id {
	case Text:
		return "text"
	case Image:
		return "image"
	case Audio:
		return "audio"
	case Archive:
		return "archive"
	case Binary:
		return "binary"
	case Document:
		return "document"
	default:
		return "unknown"
	}
}

// HeadBytes is how much of a file a caller should read before Sniff. It is
// the furthest byte any rule in the table looks at (RIFF's subtype at +8,
// four bytes, so byte 12), rounded up — a peek, not a read of the file.
const HeadBytes = 16

// magicRule matches `magic` at byte `off` of the peeked head, AND `magic2` at
// byte `off2` when magic2 is set. A zero `off`/`off2` is the common case (a
// signature at the start of the file).
//
// The second half is not decoration. Magic outranks the extension, so a rule
// has to be RIGHT or a text file that happens to start with it is dispatched
// to the wrong app: "BM" is two bytes, and prose starts with it ("BMW…").
// Requiring the rest of the signature — BMP's zero reserved fields, RIFF's
// "RIFF" before a "WAVE"/"WEBP" subtype at +8 — is what makes the rule a
// signature rather than a coincidence.
type magicRule struct {
	id     ID
	off    int
	magic  string
	off2   int
	magic2 string
}

// magic is the FIRST stage of Sniff. Order inside the table does not matter
// (no two rules can match the same bytes at the same offset).
var magic = []magicRule{
	// Images: the formats the in-tree decoders know (webrender: QOI, PNG).
	{id: Image, magic: "qoif"},
	{id: Image, magic: "\x89PNG\r\n\x1a\n"},
	{id: Image, magic: "GIF87a"},
	{id: Image, magic: "GIF89a"},
	{id: Image, magic: "\xff\xd8\xff"}, // JPEG
	// Windows bitmap: "BM" alone is two bytes of prose, so the rule also
	// requires the two reserved u16 fields to be zero (bitmap_core.h), which
	// every writer leaves that way. Six bytes of evidence, not two.
	{id: Image, magic: "BM", off2: 6, magic2: "\x00\x00\x00\x00"},
	// The RIFF container: "RIFF" at 0 and the form type at +8. Matching the
	// subtype alone would call any file with the word WAVE at byte 8 a sound.
	{id: Image, magic: "RIFF", off2: 8, magic2: "WEBP"},

	// Audio: enough to tell a sound file from an image of the same name.
	{id: Audio, magic: "RIFF", off2: 8, magic2: "WAVE"},
	{id: Audio, magic: "OggS"},
	{id: Audio, magic: "fLaC"},
	{id: Audio, magic: "ID3"},

	// Documents. "%PDF-" is five bytes of signature, not a word prose
	// starts with, so the rule needs no second half.
	{id: Document, magic: "%PDF-"},

	// Archives.
	{id: Archive, magic: "PK\x03\x04"}, // zip
	{id: Archive, magic: "\x1f\x8b"},   // gzip

	// Guest/native binaries: the files that are certainly not text.
	{id: Binary, magic: "\x7fELF"},
}

// exts maps a lower-case extension (no dot) to its type. This is the
// fallback stage, and it is where most of the table's rows live because text
// formats have no magic at all.
var exts = map[string]ID{
	// text
	"txt": Text, "text": Text, "md": Text, "markdown": Text, "log": Text,
	"csv": Text, "json": Text, "toml": Text, "ini": Text, "cfg": Text,
	"conf": Text, "yaml": Text, "yml": Text, "sh": Text, "go": Text,
	"zig": Text, "c": Text, "h": Text, "py": Text, "rs": Text,
	// image
	"qoi": Image, "png": Image, "jpg": Image, "jpeg": Image, "gif": Image,
	"bmp": Image, "webp": Image, "svg": Image,
	// document
	"pdf": Document,
	// audio
	"wav": Audio, "mp3": Audio, "ogg": Audio, "flac": Audio,
	// archive
	"zip": Archive, "gz": Archive, "tgz": Archive,
	// binary
	"elf": Binary, "bin": Binary, "exe": Binary, "img": Binary,
}

// Sniff is the whole decision: what is this file, given its name and the
// first HeadBytes of it. Pure — no syscall, no globals, no I/O.
func Sniff(name string, head []byte) ID {
	if id, ok := byMagic(head); ok {
		return id
	}
	if id, ok := byExt(name); ok {
		return id
	}
	if looksText(head) {
		return Text
	}
	return Unknown
}

func byMagic(head []byte) (ID, bool) {
	for _, r := range magic {
		if !at(head, r.off, r.magic) {
			continue
		}
		if r.magic2 != "" && !at(head, r.off2, r.magic2) {
			continue
		}
		return r.id, true
	}
	return Unknown, false
}

// at reports whether the bytes at off are exactly want. A rule that would read
// past the peek simply does not match: an unreadable tail is not evidence.
func at(head []byte, off int, want string) bool {
	if off < 0 || len(head) < off+len(want) {
		return false
	}
	return string(head[off:off+len(want)]) == want
}

// byExt resolves the extension case-insensitively. A name with no dot, or a
// leading dot only (".bashrc"), has no extension.
func byExt(name string) (ID, bool) {
	i := strings.LastIndexByte(name, '.')
	if i <= 0 || i == len(name)-1 {
		return Unknown, false
	}
	id, ok := exts[strings.ToLower(name[i+1:])]
	return id, ok
}

// looksText is the last honest resort: no magic, no known extension, and the
// bytes carry no control noise. Valid UTF-8 counts as text (a NOTES.TXT with
// an em dash is still text); a NUL byte never does.
//
// The trailing-rune trim is the part that matters at HeadBytes = 16. The peek
// is a byte count, not a character count, so a multi-byte character can
// straddle the cut: 15 ASCII bytes then a 2-byte em dash leaves half a rune,
// and utf8.Valid calls that invalid — an extensionless UTF-8 note would be
// refused as unknown. A truncated TAIL is an artifact of the peek; only
// invalid bytes anywhere else are a fact about the file.
func looksText(head []byte) bool {
	if len(head) == 0 {
		return false
	}
	for _, b := range head {
		switch {
		case b >= 0x20 && b <= 0x7e:
		case b == '\t' || b == '\n' || b == '\r':
		case b >= 0x80: // decided by the UTF-8 check below
		default:
			return false
		}
	}
	if n := trimPartialRune(head); n < len(head) {
		head = head[:n]
		if len(head) == 0 {
			return false // nothing but a severed rune: not text we can claim
		}
	}
	return utf8.Valid(head)
}

// trimPartialRune returns the length of head with an incomplete trailing
// multi-byte sequence removed, or len(head) when the tail is already whole.
// A UTF-8 lead byte is 11xxxxxx; the sequence is 2, 3 or 4 bytes long, so at
// most the last 3 bytes need looking at. Bytes that are all continuations
// have no lead to find — utf8.Valid rejects them, which is the right answer.
func trimPartialRune(head []byte) int {
	for back := 1; back <= 3 && back <= len(head); back++ {
		b := head[len(head)-back]
		if b < 0x80 || b >= 0xc0 {
			// b is a lead byte (or ASCII): does its sequence fit?
			var want int
			switch {
			case b >= 0xf0:
				want = 4
			case b >= 0xe0:
				want = 3
			case b >= 0xc0:
				want = 2
			default:
				return len(head) // plain ASCII tail
			}
			if back < want {
				return len(head) - back // severed: drop it
			}
			return len(head)
		}
	}
	return len(head)
}

// Handler is one app that can open a type: the binary to exec and the label a
// menu shows for it.
type Handler struct {
	ID    ID
	Bin   string
	Label string
}

// registry is the handler table, in registration order. It is package state
// rather than a constant so an app (or a test) can add a handler without
// editing this file; the guest's registrations all happen in init.
var registry []Handler

// Register adds a handler for a type. The FIRST registration for a type is
// the default one Open dispatches to; later ones are the "Open with…"
// candidates. Re-registering the same binary for a type is a no-op, so an
// app's init cannot double itself into the list.
func Register(id ID, bin, label string) {
	if bin == "" {
		return
	}
	for _, h := range registry {
		if h.ID == id && h.Bin == bin {
			return
		}
	}
	registry = append(registry, Handler{ID: id, Bin: bin, Label: label})
}

// Handlers is the candidate list for a type, in registration order. The
// result is a copy: a caller cannot reorder the table by accident.
func Handlers(id ID) []Handler {
	var out []Handler
	for _, h := range registry {
		if h.ID == id {
			out = append(out, h)
		}
	}
	return out
}

// Default is the handler Open dispatches to — the first registration for the
// type. The bool is false for a type nothing has registered (the caller owes
// the user a named refusal, not a silent no-op).
func Default(id ID) (Handler, bool) {
	for _, h := range registry {
		if h.ID == id {
			return h, true
		}
	}
	return Handler{}, false
}

// ReadFunc reads up to max bytes from a path. Open supplies HeadBytes and
// owns the classification; callers own only the file-channel adapter.
type ReadFunc func(path string, max int) ([]byte, error)

// OpenRequest is the one dispatch decision shared by shell and file manager.
// Target is either the canonical file path passed to a file handler or the
// original HTTPS URL passed to WEB.ELF.
type OpenRequest struct {
	Handler Handler
	Target  string
	Type    ID
	Scheme  string
}

// OpenErrorKind distinguishes a broken target, an unavailable read, and a
// file type for which the system has no registered handler.
type OpenErrorKind uint8

const (
	OpenInvalidTarget OpenErrorKind = iota + 1
	OpenUnsupportedScheme
	OpenUnreadable
	OpenNoHandler
)

// OpenError is an expected, user-reportable refusal from Open.
type OpenError struct {
	Kind   OpenErrorKind
	Type   ID
	Scheme string
}

func (e *OpenError) Error() string {
	switch e.Kind {
	case OpenUnsupportedScheme:
		return "unsupported URL scheme " + e.Scheme
	case OpenUnreadable:
		return "file is unreadable"
	case OpenNoHandler:
		return "no handler for " + e.Type.String()
	default:
		return "invalid file path or URL"
	}
}

// Open routes one local file or HTTPS URL to its default application.
// Local files are sniffed through the MIME table and resolved relative to
// cwd; file:// accepts local absolute paths (including localhost authority).
// HTTPS is handed to WEB.ELF without weakening its own TLS/DNS checks.
// Other URL schemes fail by name rather than being mistaken for file paths.
func Open(target, cwd string, read ReadFunc) (OpenRequest, error) {
	if target == "" {
		return OpenRequest{}, &OpenError{Kind: OpenInvalidTarget}
	}
	if path, ok := localVolumePath(target); ok {
		return openFile(path, cwd, read)
	}
	if scheme, ok := urlScheme(target); ok {
		switch strings.ToLower(scheme) {
		case "https":
			if !validHTTPSURL(target) {
				return OpenRequest{}, &OpenError{Kind: OpenInvalidTarget}
			}
			return OpenRequest{
				Handler: Handler{Bin: "WEB.ELF", Label: "Web Browser"},
				Target:  target,
				Type:    Unknown,
				Scheme:  "https",
			}, nil
		case "file":
			path, ok := localFileURL(target)
			if !ok {
				return OpenRequest{}, &OpenError{Kind: OpenInvalidTarget}
			}
			return openFile(path, cwd, read)
		default:
			return OpenRequest{}, &OpenError{
				Kind: OpenUnsupportedScheme, Scheme: strings.ToLower(scheme),
			}
		}
	}
	return openFile(target, cwd, read)
}

func localVolumePath(target string) (string, bool) {
	i := strings.IndexByte(target, ':')
	if i <= 0 {
		return "", false
	}
	volume := target[:i]
	switch {
	case strings.EqualFold(volume, "host"), strings.EqualFold(volume, "usb"):
	case len(volume) == 4 && strings.EqualFold(volume[:3], "usb") &&
		volume[3] >= '1' && volume[3] <= '4':
	default:
		return "", false
	}
	return "/" + volume + "/" + strings.TrimLeft(target[i+1:], "/"), true
}

func openFile(target, cwd string, read ReadFunc) (OpenRequest, error) {
	path, ok := sharePath(target, cwd)
	if !ok {
		return OpenRequest{}, &OpenError{Kind: OpenInvalidTarget}
	}
	if read == nil {
		return OpenRequest{}, &OpenError{Kind: OpenUnreadable}
	}
	head, err := read(path, HeadBytes)
	if err != nil {
		return OpenRequest{}, &OpenError{Kind: OpenUnreadable}
	}
	if len(head) > HeadBytes {
		head = head[:HeadBytes]
	}
	id := Sniff(baseName(path), head)
	handler, ok := Default(id)
	if !ok {
		return OpenRequest{}, &OpenError{Kind: OpenNoHandler, Type: id}
	}
	return OpenRequest{Handler: handler, Target: path, Type: id, Scheme: "file"}, nil
}

// urlScheme recognizes an RFC 3986 scheme prefix without treating a colon
// inside an absolute path as a scheme separator.
func urlScheme(target string) (string, bool) {
	i := strings.IndexByte(target, ':')
	if i <= 0 || strings.ContainsAny(target[:i], "/?#") {
		return "", false
	}
	for j := 0; j < i; j++ {
		c := target[j]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z':
		case j > 0 && (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.'):
		default:
			return "", false
		}
	}
	return target[:i], true
}

func validHTTPSURL(target string) bool {
	const prefix = "https://"
	if len(target) < len(prefix) || !strings.EqualFold(target[:len(prefix)], prefix) {
		return false
	}
	rest := target[len(prefix):]
	end := strings.IndexAny(rest, "/?#")
	if end >= 0 {
		rest = rest[:end]
	}
	return rest != "" && !strings.ContainsAny(rest, " \t\r\n")
}

func localFileURL(target string) (string, bool) {
	const prefix = "file://"
	if len(target) < len(prefix) || !strings.EqualFold(target[:len(prefix)], prefix) {
		return "", false
	}
	rest := target[len(prefix):]
	var path string
	if strings.HasPrefix(rest, "/") {
		path = rest
	} else {
		slash := strings.IndexByte(rest, '/')
		if slash < 0 || !strings.EqualFold(rest[:slash], "localhost") {
			return "", false
		}
		path = rest[slash:]
	}
	if end := strings.IndexAny(path, "?#"); end >= 0 {
		path = path[:end]
	}
	if path == "" || path[0] != '/' {
		return "", false
	}
	return percentDecode(path)
}

func percentDecode(s string) (string, bool) {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] != '%' {
			out = append(out, s[i])
			continue
		}
		if i+2 >= len(s) {
			return "", false
		}
		hi, okHi := hexValue(s[i+1])
		lo, okLo := hexValue(s[i+2])
		if !okHi || !okLo || hi == 0 && lo == 0 {
			return "", false
		}
		out = append(out, hi<<4|lo)
		i += 2
	}
	return string(out), true
}

func hexValue(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	default:
		return 0, false
	}
}

// sharePath joins relative targets to cwd, rejects traversal, and returns a
// canonical path the kernel's file ABI accepts. The local partitions
// retained here are the host share, the VLFS data volume (/disk — M132b
// #2753, owner decision 2026-10-20), and the read-only USB volumes.
func sharePath(target, cwd string) (string, bool) {
	if target == "" || strings.IndexByte(target, 0) >= 0 {
		return "", false
	}
	full := target
	if !strings.HasPrefix(full, "/") {
		base := cwd
		if base == "" {
			base = "/"
		}
		if strings.HasSuffix(base, "/") {
			full = base + target
		} else {
			full = base + "/" + target
		}
	}
	parts := make([]string, 0, 8)
	for _, part := range strings.Split(full, "/") {
		switch part {
		case "", ".":
			continue
		case "..":
			return "", false
		default:
			parts = append(parts, part)
		}
	}
	prefix := "/host"
	if len(parts) > 0 && strings.EqualFold(parts[0], "host") {
		parts = parts[1:]
	} else if len(parts) > 0 && usbRoot(parts[0]) {
		prefix = "/" + strings.ToLower(parts[0])
		parts = parts[1:]
	} else if len(parts) > 0 && strings.EqualFold(parts[0], "disk") {
		prefix = "/disk"
		parts = parts[1:]
	}
	path := prefix
	if len(parts) > 0 {
		path += "/" + strings.Join(parts, "/")
	}
	if len(path) > 64 {
		return "", false
	}
	return path, true
}

func usbRoot(part string) bool {
	if strings.EqualFold(part, "usb") {
		return true
	}
	return len(part) == 4 && strings.EqualFold(part[:3], "usb") &&
		part[3] >= '0' && part[3] <= '9'
}

func baseName(path string) string {
	if i := strings.LastIndexByte(path, '/'); i >= 0 {
		return path[i+1:]
	}
	return path
}

// init registers the live adopters: GOVIEW.ELF opens images and takes a
// path in argv[1]; GOEDIT.ELF opens text and takes a path in argv[1] as
// well. GOEDIT is ALSO an image handler, second, because GOVIEW refuses
// images it has no decoder for ("this format has no guest decoder") and
// reading the raw bytes is the honest fallback then. GOSOUND.ELF (M99c)
// opens audio and takes the path in argv[1]. Types with no registration —
// Archive, Binary — refuse by name.
//
// M132b (#2753) registers the wave's reserved handlers: GOREADER is the
// Document default, GOSHEET a second Text candidate, GOPAINT a third
// Image one (its binary ships through the store; the registration is the
// reservation, per R9/R12 of index #2734). Order matters — the first
// registration stays the default, so the new names change no dispatch.
func init() {
	Register(Image, "GOVIEW.ELF", "Image Viewer")
	Register(Text, "GOEDIT.ELF", "Code Editor")
	Register(Image, "GOEDIT.ELF", "Code Editor (raw bytes)")
	Register(Audio, "GOSOUND.ELF", "Sound Player")
	Register(Document, "GOREADER.ELF", "Reader")
	Register(Text, "GOSHEET.ELF", "Sheet")
	Register(Image, "GOPAINT.ELF", "Paint")
}
