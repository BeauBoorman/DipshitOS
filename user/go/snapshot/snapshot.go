// Package snapshot is the M81g (#1767) snapshot bundle codec: the container
// that carries the state a person would hate to lose — the settings table,
// the session strip and a selection of documents — across a restore into a
// fresh boot.
//
// The card's deliverable is the RESTORE DRILL, not the archive step, so the
// codec is built to fail closed and whole. A bundle is either every entry it
// claims or it is nothing: `Parse` validates the WHOLE container before a
// caller writes a single byte, and any doubt is a refusal. That is the same
// rule the schema-v2 settings header already follows (virelai/settings refuses
// a newer schema whole rather than half-reading it), and it is why this is a
// package rather than a helper in one app: the seat (GOTABWM.ELF) writes and
// restores bundles, and the self-test (GOSELF.ELF) proves the round-trip, and
// "one codec, two consumers" is the M71f arrangement that stopped the seat's
// decode and the panel's from drifting.
//
// # Format
//
//	#vb1 <entries>\n
//	<name> <nbytes>\n
//	<nbytes of raw body>
//	<name> <nbytes>\n
//	<nbytes of raw body>
//	...
//
// One header line carrying the version AND the entry count, then entries.
// Each entry is a one-line header naming the entry and its EXACT body length
// in bytes, followed by exactly that many raw bytes.
//
// The framing is unambiguous BY CONSTRUCTION: a parser consumes exactly nbytes
// of body and never re-interprets a body byte as a header. A body may
// therefore hold any bytes at all — SESSION.TABS is the binary `.tabs` v2
// strip, and a line-oriented text format could not carry it.
//
// The ENTRY COUNT in the header is what makes truncation detectable at an
// entry BOUNDARY, and without it the "whole or nothing" promise is only half
// true: a bundle cut cleanly after its first entry is a perfectly well-formed
// one-entry bundle, indistinguishable from a producer that meant to write one
// entry. A restore would then succeed on half the state and report success.
// With the count, a short bundle is a refusal at any cut point — which is the
// property go-selftest's `TestNoTruncatedPrefixOfABundleParses` pins.
//
// There is no compression, no dedup and no directory structure: a bundle is a
// flat list of named blobs, and "which file does this name mean on the share"
// is the CALLER's mapping, not the codec's.
//
// # Refusals
//
// Every refusal is whole, and each carries a reason so a marker line can name
// the one thing that was wrong. The reasons are deliberately distinct: "this
// file is not a bundle" (header) and "this bundle claims more than we
// understand" (entry-name) are different diagnoses, and a gate that asserts a
// refusal wants to pin which one fired.
package snapshot

const (
	// HeaderPrefix is the first token of the header line. The version is a
	// suffix so a future shape is a NEW header (`#vb2`), and a consumer that
	// meets one it does not know refuses whole rather than guessing at the
	// body.
	HeaderPrefix = "#vb1"

	// EntrySettings and EntrySession are the two entries the seat always
	// carries. The names are the contract between this package and the
	// consumer's share-path mapping, not paths: a bundle never names a share
	// path, so a bundle cannot be replayed somewhere it does not belong.
	// EntryPanes is the M137a (#2771) session sidecar: the pane-tree blob
	// the seat keeps beside SESSION.TABS, carried so a restore on a fresh
	// share still rehydrates the split layout.
	EntrySettings = "settings"
	EntrySession  = "session"
	EntryPanes    = "panes"

	// DocsPrefix namespaces the documents selection. A docs entry is
	// DocsPrefix + the file name, so the share root the caller maps it onto
	// is fixed by the caller, never by the bundle.
	DocsPrefix = "docs/"

	// MaxEntries bounds the entry count (the two state entries plus a
	// documents selection). A bundle claiming more is refused whole.
	MaxEntries = 8
	// MaxNameLen bounds one entry name. The kernel's sys_dir_list row
	// carries name[32], so a document name that came off a listing is at
	// most 31 bytes anyway; this is the container's own cap, checked before
	// the mapping, not after.
	MaxNameLen = 32
	// MaxBody bounds ONE entry body. M125a (#2586): the session strip now
	// carries a per-app state trailer (the `.tabs` v2 app_state blobs), so
	// the entry cap moved to cover a session at its own 96 KiB file bound
	// with room to spare; it exists so a corrupt length field cannot ask a
	// reader for an unbounded allocation.
	MaxBody = 128 * 1024
	// MaxBundle bounds the WHOLE bundle. Chosen so settings + session + a
	// full selection of documents still fits under vi.MaxFileBytes (256 KB),
	// which is the hard ceiling of the share's reader — a bundle the reader
	// could not load whole would be a bundle we could never verify.
	MaxBundle = 200 * 1024
)

// Refusal reasons. Every one of these means NOTHING was written: Parse
// validates the whole container, so a caller that acts on a false return has
// not yet touched the share.
const (
	// ReasonEmpty is a container that parsed but carries no entry. A bundle
	// that claims no state is not a bundle: accepting it would let a
	// truncated-to-header file pass for a successful restore.
	ReasonEmpty = "empty"
	// ReasonHeader is a first line that is not a header this codec writes.
	ReasonHeader = "header"
	// ReasonEntryHeader is a line that is not `<name> <nbytes>`.
	ReasonEntryHeader = "entry-header"
	// ReasonEntryName is a name this consumer cannot map: a byte outside
	// the accepted charset, a name too long, a name that would escape the
	// directory it is namespaced into, or one this version does not know.
	ReasonEntryName = "entry-name"
	// ReasonEntrySize is a length that is not a plain decimal count, or one
	// past MaxBody.
	ReasonEntrySize = "entry-size"
	// ReasonTruncated is an entry whose declared body runs past the end of
	// the file — the shape a crash mid-write used to leave behind.
	ReasonTruncated = "truncated"
	// ReasonDuplicate is a name claimed twice. Last-wins would silently
	// discard one of two bodies the bundle vouches for, so it is a refusal.
	ReasonDuplicate = "duplicate"
	// ReasonTooMany is a bundle claiming more than MaxEntries.
	ReasonTooMany = "too-many"
	// ReasonEntryCount is a bundle whose header promises N entries and whose
	// body did not yield N — the signature of a container cut short at an
	// entry boundary. This is the reason that makes "whole or nothing" true
	// at every cut point rather than only mid-entry.
	ReasonEntryCount = "entry-count"
	// ReasonCount is a header whose entry count is not a plain decimal
	// number, or is zero (a bundle that claims no state is not a bundle).
	ReasonCount = "count"
)

// Header returns the header line for a bundle of n entries. Exported so a
// test can forge a container without calling Build — the refusal tests are
// only meaningful if they can write bundles Build would never produce.
func Header(n int) []byte {
	out := make([]byte, 0, len(HeaderPrefix)+12)
	out = append(out, HeaderPrefix...)
	out = append(out, ' ')
	out = appendDecimal(out, n)
	return append(out, '\n')
}

// Entry is one named blob: the bundle's whole data model.
type Entry struct {
	Name string
	Body []byte
}

// Bundle is a parsed container, in file order.
type Bundle struct {
	Entries []Entry
}

// Get returns the first body stored under name and whether it was there.
func (b Bundle) Get(name string) ([]byte, bool) {
	for _, e := range b.Entries {
		if e.Name == name {
			return e.Body, true
		}
	}
	return nil, false
}

// DocsCount returns how many entries carry the docs namespace — the size of
// the documents selection, which is what a capture/restore marker reports.
func (b Bundle) DocsCount() int { return len(b.Docs()) }

// Docs returns the documents selection as name (bare, no DocsPrefix) and body
// pairs, in file order. The name is bare so the caller joins it onto its own
// directory; a consumer that put a prefix in front of it would be trusting the
// bundle to choose where a file lands.
func (b Bundle) Docs() []Entry {
	var out []Entry
	for _, e := range b.Entries {
		if len(e.Name) > len(DocsPrefix) && e.Name[:len(DocsPrefix)] == DocsPrefix {
			out = append(out, Entry{
				Name: e.Name[len(DocsPrefix):],
				Body: e.Body,
			})
		}
	}
	return out
}

// ValidName reports whether s is one path SEGMENT this codec is willing to
// carry inside the docs namespace. It is exported for a caller that is
// selecting documents off a share listing: a share name the container would
// refuse is better found at CAPTURE time than at restore time on a later boot.
func ValidName(s string) bool { return validSegment(s) == "" }

// validSegment returns "" when s is an acceptable single path segment, else
// the reason it is not. Kept as one function so the builder and the parser
// cannot drift: a name that builds is a name that parses.
func validSegment(s string) string {
	if s == "" || len(s) > MaxNameLen {
		return ReasonEntryName
	}
	// A leading dot is refused so a bundle can never name `.` or `..`: the
	// docs namespace is mapped onto a real directory by the consumer, and a
	// name that walks out of it is a path traversal, not a document. This is
	// the reason the charset below allows '.' internally but not first.
	if s[0] == '.' {
		return ReasonEntryName
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '.' || c == '-' || c == '_':
		default:
			// Notably NOT '/': a segment is one component. The only
			// separator this codec understands is the docs namespace, and
			// it introduces that itself — the bundle author never does.
			return ReasonEntryName
		}
	}
	return ""
}

// Build serializes entries into a bundle. It refuses (nil, false) the same
// shapes Parse refuses — an unusable name, an oversized or empty entry list, a
// duplicate name, a body past MaxBody — so a bundle this package produces is
// always a bundle it accepts. Callers that build a bundle from whatever the
// share holds therefore learn about a bad document name HERE, at capture
// time, instead of at restore time on some later boot.
func Build(entries []Entry) ([]byte, bool) {
	if len(entries) == 0 {
		return nil, false
	}
	if len(entries) > MaxEntries {
		return nil, false
	}
	out := make([]byte, 0, len(Header(len(entries)))+256)
	out = append(out, Header(len(entries))...)
	for i, e := range entries {
		if !KnownEntry(e.Name) || len(e.Body) > MaxBody {
			return nil, false
		}
		for j := 0; j < i; j++ {
			if entries[j].Name == e.Name {
				return nil, false
			}
		}
		out = append(out, e.Name...)
		out = append(out, ' ')
		out = appendDecimal(out, len(e.Body))
		out = append(out, '\n')
		out = append(out, e.Body...)
	}
	if len(out) > MaxBundle {
		return nil, false
	}
	return out, true
}

// Parse decodes a bundle. ok is false for EVERY refusal, and reason then names
// the one that fired; a caller must write nothing when ok is false, which is
// what makes the restore all-or-nothing: validation completes over the whole
// container before the first write, so a bundle whose LAST entry is corrupt
// has not already republished its first.
//
// A name Parse does not recognise is ReasonEntryName, not a skip: a bundle
// that carries an entry this version cannot map is a bundle from a producer
// this version does not understand, and the settings header gate's rule —
// refuse the newer thing whole — is the one that keeps a restore honest.
func Parse(b []byte) (Bundle, bool, string) {
	var out Bundle
	line, rest := cutLine(b)
	want := len(HeaderPrefix) + 1
	if len(line) <= want ||
		string(line[:len(HeaderPrefix)]) != HeaderPrefix ||
		line[len(HeaderPrefix)] != ' ' {
		return out, false, ReasonHeader
	}
	declared, ok := parseCount(line[want:])
	if !ok {
		return out, false, ReasonCount
	}
	for len(rest) > 0 {
		var line []byte
		line, rest = cutLine(rest)
		name, num, reason := splitEntryHeader(line)
		if reason != "" {
			return Bundle{}, false, reason
		}
		if !KnownEntry(name) {
			return Bundle{}, false, ReasonEntryName
		}
		for _, e := range out.Entries {
			if e.Name == name {
				return Bundle{}, false, ReasonDuplicate
			}
		}
		if len(out.Entries) >= MaxEntries {
			return Bundle{}, false, ReasonTooMany
		}
		if len(rest) < num {
			return Bundle{}, false, ReasonTruncated
		}
		out.Entries = append(out.Entries, Entry{Name: name, Body: rest[:num]})
		rest = rest[num:]
	}
	if declared == 0 || len(out.Entries) == 0 {
		// A header that promises nothing, and a body that delivered nothing.
		return Bundle{}, false, ReasonEmpty
	}
	if len(out.Entries) != declared {
		// The container was cut short (or padded) at an entry boundary:
		// every entry it DID yield is individually well-formed, so without
		// this check a half-restored bundle would look like a success.
		return Bundle{}, false, ReasonEntryCount
	}
	return out, true, ""
}

// KnownEntry reports whether name is an entry this version maps: one of the
// two state entries, or a document in the docs namespace whose bare name is an
// acceptable path segment. It is the whole entry-name check, so Build and
// Parse apply exactly this and cannot drift.
//
// A name that fails here is refused, never skipped: a bundle carrying an entry
// this version cannot map is a bundle from a producer this version does not
// understand, and the settings header gate's rule — refuse the newer thing
// whole — is what keeps a restore from silently dropping state.
func KnownEntry(name string) bool {
	switch name {
	case EntrySettings, EntrySession, EntryPanes:
		return true
	}
	if len(name) > len(DocsPrefix) && name[:len(DocsPrefix)] == DocsPrefix {
		// The bare document name gets the same treatment as a whole entry
		// name: a leading dot cannot walk out of the directory, and the
		// bare name is what a consumer joins onto its own root.
		return validSegment(name[len(DocsPrefix):]) == ""
	}
	return false
}

// splitEntryHeader parses one `<name> <nbytes>` line. The grammar is strict on
// purpose — a single space, digits only, no sign, no leading '+', no
// whitespace padding — because this line is the only thing standing between a
// corrupt length and a huge allocation. Anything else is ReasonEntryHeader.
func splitEntryHeader(line []byte) (name string, num int, reason string) {
	i := 0
	for i < len(line) && line[i] != ' ' {
		i++
	}
	if i == 0 || i >= len(line) {
		return "", 0, ReasonEntryHeader
	}
	// A name is pure ASCII by validName's charset, so this conversion can
	// never mangle a byte into a different character — and a name that is
	// not ASCII is refused by validName right after, not decoded wrongly.
	name = string(line[:i])
	digits := line[i+1:]
	if len(digits) == 0 || len(digits) > 9 {
		return "", 0, ReasonEntryHeader
	}
	n := 0
	for j := 0; j < len(digits); j++ {
		c := digits[j]
		if c < '0' || c > '9' {
			return "", 0, ReasonEntryHeader
		}
		n = n*10 + int(c-'0')
	}
	if n > MaxBody {
		return "", 0, ReasonEntrySize
	}
	return name, n, ""
}

// parseCount reads the entry count out of the header's tail. Strict for the
// same reason splitEntryHeader is: digits only, bounded length, and a value
// that must be at least 1 and at most MaxEntries. A LEADING ZERO is refused
// too, so both numeric fields in the container share one grammar and there is
// a single way to spell a count.
func parseCount(d []byte) (int, bool) {
	if len(d) == 0 || len(d) > 3 {
		return 0, false
	}
	if len(d) > 1 && d[0] == '0' {
		return 0, false
	}
	n := 0
	for i := 0; i < len(d); i++ {
		c := d[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
	}
	if n < 1 || n > MaxEntries {
		return 0, false
	}
	return n, true
}

// appendDecimal writes v in decimal. Hand-rolled rather than strconv so the
// container's only dependency stays zero and the digit grammar is the one
// splitEntryHeader accepts.
func appendDecimal(b []byte, v int) []byte {
	if v == 0 {
		return append(b, '0')
	}
	var tmp [20]byte
	i := len(tmp)
	for v > 0 {
		i--
		tmp[i] = byte('0' + v%10)
		v /= 10
	}
	return append(b, tmp[i:]...)
}

// cutLine splits s after the first newline (if any), keeping the newline out
// of the line. A final segment with no trailing newline is returned whole —
// which is how a truncated bundle's last header line is caught: it parses as
// far as the digits and then reports ReasonTruncated on the missing body.
func cutLine(b []byte) (line, rest []byte) {
	for i := 0; i < len(b); i++ {
		if b[i] == '\n' {
			return b[:i], b[i+1:]
		}
	}
	return b, nil
}
