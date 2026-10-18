// Package outbox is the OUTBOX lane's guest-app half (ADR 0051 V2-D5):
// the directory, the name rule, the REQ-<8hex> intent-marker grammar,
// and the staging gesture GOSH `export` and GOFILES "Export to Host"
// share.
//
// Intent and provenance are split: the app writes the payload and an
// UNSIGNED REQ marker naming it; the seat (the only signer) emits one
// signed OUTBOX record per REQ-marked payload while the adopted mask
// carries lane_outbox. An unmarked file in OUTBOX/ is inert — the mirror
// of an unannounced INBOX plant.
//
// This is a leaf package on purpose: it imports only vi, so the shell
// (which hostint's codec cannot see — hostint imports shlib for its MAC)
// can stage exports without an import cycle.
package outbox

import "virelai/vi"

const (
	// Dir is the export lane's share directory in kernel path form — the
	// runner creates it at arm (the SDK has no mkdir), the seat polls it
	// beside the lane dir once per tick.
	Dir = "/host/OUTBOX"
	// NameMax bounds a payload basename — the D4 rule carried symmetric
	// (48 keeps "/host/OUTBOX/<name>" inside the path bound).
	NameMax = 48
	// FileMax is the per-file cap — the D4 64 MiB bound the host
	// re-checks at move time.
	FileMax = 64 << 20
	// ReqPrefix is the intent marker's stem: REQ-<8hex>, the payload
	// basename verbatim as its whole content.
	ReqPrefix = "REQ-"
)

// The refusal words Export returns — the lane vocabulary (hostint's
// refusal table). The apps only ever surface them; the seat and the host
// name the same reasons on their own refusal lines.
const (
	RefuseNameRejected = "name_rejected"
	RefuseGone         = "gone"
	RefuseUnsupported  = "unsupported_kind"
	RefuseTooLarge     = "payload_too_large"
	RefuseIO           = "io_error"
)

// alnumByte reports the D4 charset's leading-byte rule.
func alnumByte(c byte) bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
}

// nameByte reports the D4 charset: [A-Za-z0-9._-].
func nameByte(c byte) bool {
	return alnumByte(c) || c == '.' || c == '_' || c == '-'
}

// Name renders a file's basename as a lawful OUTBOX payload name — the
// D4 sanitize the runner applies on the way in, mirrored for the way
// out: bytes outside the charset fold to '_', a leading non-alphanumeric
// gains an 'F' prefix, the result is cut at NameMax. ok=false when no
// honest name exists (an empty basename).
func Name(base string) (string, bool) {
	out := make([]byte, 0, len(base)+1)
	for i := 0; i < len(base); i++ {
		c := base[i]
		if !nameByte(c) {
			c = '_'
		}
		out = append(out, c)
	}
	if len(out) == 0 {
		return "", false
	}
	if !alnumByte(out[0]) {
		out = append([]byte{'F'}, out...)
	}
	if len(out) > NameMax {
		out = out[:NameMax]
	}
	return string(out), true
}

// NameValid is the strict check the seat applies to a REQ's content (and
// the host to a record's name) — the payload basename must already
// satisfy the rule the apps fold to: ≤ NameMax of the charset, leading
// alnum.
func NameValid(name string) bool {
	if len(name) == 0 || len(name) > NameMax || !alnumByte(name[0]) {
		return false
	}
	for i := 0; i < len(name); i++ {
		if !nameByte(name[i]) {
			return false
		}
	}
	return true
}

const hexDigits = "0123456789abcdef"

// hex8 renders v as exactly 8 lowercase hex digits — the REQ suffix.
func hex8(v uint32) string {
	var b [8]byte
	for i := 0; i < 8; i++ {
		b[i] = hexDigits[(v>>uint((7-i)*4))&0xf]
	}
	return string(b[:])
}

// ReqName is the intent marker's filename for an app-chosen 32-bit
// suffix. The suffix needs only per-app uniqueness — the content is
// authoritative and a collision just coalesces two requests for the same
// intent.
func ReqName(id uint32) string { return ReqPrefix + hex8(id) }

// IsReqName reports whether name is a REQ-<8hex> intent marker. Hex case
// is accepted like the lane's record-name parse (the share's filesystem
// is case-insensitive anyway).
func IsReqName(name string) bool {
	if len(name) != len(ReqPrefix)+8 || name[:len(ReqPrefix)] != ReqPrefix {
		return false
	}
	for i := len(ReqPrefix); i < len(name); i++ {
		c := name[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') && (c < 'A' || c > 'F') {
			return false
		}
	}
	return true
}

// IO is the file-op seam set the staging gesture takes — the share's
// file ABI plus a uniqueness source for the REQ suffix. The production
// value wires vi; tests drive the whole gesture in memory.
type IO struct {
	// Open opens path with the vi mode flags (ModeRead/ModeWrite|ModeCreate).
	Open func(path string, flags uint32) (int64, int64)
	// Read fills buf from an open handle: (n, result).
	Read func(h uint32, buf []byte) (int, int64)
	// WriteAll streams b through an open handle: (n, result) — the vi
	// FileWriteAll confirmed-count contract.
	WriteAll func(h uint32, b []byte) (int, int64)
	// Sync flushes an open handle (slot 77).
	Sync func(h uint32) int64
	// Close closes a handle.
	Close func(h uint32)
	// Delete removes path (a missing path returns ErrFileNotFound).
	Delete func(path string) int64
	// Rename moves oldPath to newPath (the HF rename refuses a live dst).
	Rename func(oldPath, newPath string) int64
	// IsDir reports whether path lists as a directory (vi.DirList's
	// success on it).
	IsDir func(path string) bool
	// WriteSafe publishes b at path through the share's temp+rename rule.
	WriteSafe func(path string, b []byte) int64
	// Rand fills p with the REQ suffix entropy (vi.Random; time is the
	// caller's fallback when it fails).
	Rand func(p []byte) (int, error)
}

// Guest is the production seam set: the vi file ABI, verbatim.
var Guest = IO{
	Open:      vi.FileOpen,
	Read:      vi.FileRead,
	WriteAll:  vi.FileWriteAll,
	Sync:      vi.FileSync,
	Close:     vi.FileClose,
	Delete:    vi.FileDelete,
	Rename:    vi.FileRename,
	WriteSafe: vi.WriteFileSafe,
	Rand:      vi.Random,
	IsDir: func(path string) bool {
		var rows [vi.MaxDirEntries]vi.DirEntry
		_, rc := vi.DirList(path, rows[:])
		return rc >= 0
	},
}

// Export copies srcPath into Dir under the D4-sanitized basename and
// posts the REQ intent marker: payload first (temp+rename per the
// share's atomicity rule), the marker second — the seat signs only what
// is both present and REQ-marked. Returns the landed payload name, or a
// refusal word: name_rejected (no honest name), gone (source absent),
// unsupported_kind (a directory), payload_too_large (> 64 MiB — counted
// while streaming so a sparse giant is refused before it lands), or
// io_error.
func (io IO) Export(srcPath string) (string, string) {
	base := srcPath
	for i := len(srcPath) - 1; i >= 0; i-- {
		if srcPath[i] == '/' {
			base = srcPath[i+1:]
			break
		}
	}
	name, ok := Name(base)
	if !ok {
		return "", RefuseNameRejected
	}
	if io.IsDir != nil && io.IsDir(srcPath) {
		return "", RefuseUnsupported
	}
	sh, rc := io.Open(srcPath, vi.ModeRead)
	if rc < 0 {
		if rc == vi.ErrFileNotFound {
			return "", RefuseGone
		}
		return "", RefuseIO
	}
	dst := Dir + "/" + name
	tmp := dst + "~"
	dh, rc := io.Open(tmp, vi.ModeWrite|vi.ModeCreate)
	if rc < 0 {
		io.Close(uint32(sh))
		return "", RefuseIO
	}
	buf := make([]byte, 32768)
	total := uint64(0)
	tooLarge := false
	fail := false
	for {
		n, r := io.Read(uint32(sh), buf)
		if r < 0 {
			fail = true
			break
		}
		if n == 0 {
			break
		}
		total += uint64(n)
		if total > FileMax {
			tooLarge, fail = true, true
			break
		}
		if _, wr := io.WriteAll(uint32(dh), buf[:n]); wr < 0 {
			fail = true
			break
		}
	}
	if !fail && io.Sync(uint32(dh)) < 0 {
		fail = true
	}
	io.Close(uint32(dh))
	io.Close(uint32(sh))
	if fail {
		_ = io.Delete(tmp)
		if tooLarge {
			return "", RefuseTooLarge
		}
		return "", RefuseIO
	}
	// Publish the payload (delete+rename — the WriteFileSafe order), then
	// the marker. A failed publish removes the temp and reports io_error.
	if rc := io.Delete(dst); rc < 0 && rc != vi.ErrFileNotFound {
		_ = io.Delete(tmp)
		return "", RefuseIO
	}
	if rc := io.Rename(tmp, dst); rc < 0 {
		_ = io.Delete(tmp)
		return "", RefuseIO
	}
	var suf [4]byte
	if io.Rand != nil {
		_, _ = io.Rand(suf[:])
	}
	v := uint32(suf[0]) | uint32(suf[1])<<8 | uint32(suf[2])<<16 | uint32(suf[3])<<24
	if v == 0 {
		v = uint32(vi.Time()) | 1 // entropy-free fallback stays nonzero
	}
	if rc := io.WriteSafe(Dir+"/"+ReqName(v), []byte(name)); rc < 0 {
		// The marker failed — the payload sits unmarked, inert by rule.
		return "", RefuseIO
	}
	return name, ""
}
