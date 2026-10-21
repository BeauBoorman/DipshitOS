package vi

import (
	"encoding/binary"
	"strings"
	"unsafe"
)

// M113d (issue #2420, ADR 0054 Part II D10): the Go half of slot 89
// `sys_grant_admin` — the ONE in-guest read/write path for the user rows
// of GRANTS.TXT (kernel/src/grant.zig). The kernel gates BOTH ops before
// any argument is touched: the registered WM seat or CAP_PROC_ADMIN, and
// never the app the row names (`grant_row_names_caller` refuses a write
// whose row resolves to the caller's own recorded image — seat-held
// consent can never widen the consenting app itself).
//
//   - op 0 READ: marshal user row `index` as its grants line
//     (`name<TAB>sha256|*<TAB>words`, no newline); ENOENT past the end,
//     EINVAL when the caller's buffer cannot hold the line.
//   - op 1 WRITE: parse the line strictly (EINVAL answers a malformed
//     line — the file's poison rule is for files, not a named syscall),
//     insert-or-update by name, persist GRANTS.TXT through the kernel
//     channel. ENOSPC at the bounded table, ENXIO with no host channel,
//     EIO rolls the table back.
//   - op 2 DENIAL_READ (issue #2982, wave-3 W1): the kernel's denial
//     receipts readable at EL0 — a 32-entry ring of the verbatim RCPT
//     lines emit_denial publishes to serial. The buffer gets [next
//     cursor u64le] then whole newline-terminated receipts with
//     sequence > cursor, as many as fit; EINVAL below 8 + receipt_max.
//
// Off the guest every call degrades to -ENOSYS like the rest of the SDK;
// the host tests ride the syscallHook seam (grant_test.go).

const (
	grantAdminRead    uint64 = 0
	grantAdminWrite   uint64 = 1
	grantAdminDenials uint64 = 2
)

// GrantNameMax and GrantLineMax mirror kernel grant.name_max/line_max —
// the row name is the exec-recorded share path, and the serialized line
// is name + TAB + sha256 + TAB + the widest word list.
const (
	GrantNameMax = 64
	GrantLineMax = GrantNameMax + 1 + 64 + 1 + 64
)

// GrantRow is one GRANTS.TXT user row. SHA is 64 lowercase hex, or "*"
// for the wildcard that may only narrow. Words is the row's
// comma-separated word list exactly as the file serializes it ("-" or
// "" narrows the row to nothing).
type GrantRow struct {
	Name  string
	SHA   string
	Words string
}

// GrantWordVocab is the caps=/grant word vocabulary (kernel grant.vocab,
// ADR 0054 D9): one word means one slot group, and baseline is every
// word set — the ambient authority a row can only narrow. Order is the
// kernel's bit order; renderers canonicalize to it.
var GrantWordVocab = [9]string{
	"file", "window", "audio", "timer", "memory", "process", "debug", "net", "term",
}

// GrantWordKnown reports whether w is a word of the grant vocabulary.
func GrantWordKnown(w string) bool {
	for _, v := range GrantWordVocab {
		if v == w {
			return true
		}
	}
	return false
}

// GrantWordsCanonical renders a word list in vocabulary order — the one
// byte-shape a row line, a state field, or a display column should ever
// carry. Unknown words pass through at the tail: callers validating a
// grammar refuse them first, so this only ever sees known words plus the
// empty list ("-").
func GrantWordsCanonical(words []string) string {
	out := make([]string, 0, len(words))
	var extra []string
	for _, v := range GrantWordVocab {
		for _, w := range words {
			if w == v {
				out = append(out, v)
				break
			}
		}
	}
	for _, w := range words {
		if !GrantWordKnown(w) {
			extra = append(extra, w)
		}
	}
	out = append(out, extra...)
	if len(out) == 0 {
		return "-"
	}
	return strings.Join(out, ",")
}

// GrantWordsSubset reports whether every word of a is in b — the
// non-widening test ADR 0054 D10 names for an update's declared words
// against the words a consent already granted.
func GrantWordsSubset(a, b []string) bool {
	for _, w := range a {
		found := false
		for _, v := range b {
			if w == v {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// GrantLine serializes r as its GRANTS.TXT line (no trailing newline) —
// the byte shape op 1 writes and op 0 hands back.
func GrantLine(r GrantRow) string {
	sha := r.SHA
	if sha == "" {
		sha = "*"
	}
	words := r.Words
	if words == "" {
		words = "-"
	}
	return r.Name + "\t" + sha + "\t" + words
}

// ParseGrantLine decodes one `name<TAB>sha|*<TAB>words` line — the read
// half of the op-0 shape. Field shapes are checked loosely: the kernel
// is the strict parser, and a line it emitted is well-formed by
// construction. False when the line does not carry three TAB-separated
// fields or the name is empty.
func ParseGrantLine(line string) (GrantRow, bool) {
	f0 := strings.IndexByte(line, '\t')
	if f0 <= 0 {
		return GrantRow{}, false
	}
	rest := line[f0+1:]
	f1 := strings.IndexByte(rest, '\t')
	if f1 < 0 || strings.IndexByte(rest[f1+1:], '\t') >= 0 {
		return GrantRow{}, false
	}
	return GrantRow{Name: line[:f0], SHA: rest[:f1], Words: rest[f1+1:]}, true
}

// GrantReadRow marshals user row `index` (slot 89 op 0) into buf and
// returns the line length written; a negative return is the kernel's raw
// errno — -EACCES when the caller is neither the registered seat nor a
// CAP_PROC_ADMIN principal, -ENOENT past the table's end, -EINVAL when
// buf cannot hold the line.
func GrantReadRow(index uint64, buf []byte) (int, int64) {
	if len(buf) == 0 {
		return 0, -ErrEINVAL
	}
	r := svc4(SlotGrantAdmin, uintptr(grantAdminRead), uintptr(index),
		uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if r < 0 {
		return 0, r
	}
	return int(r), r
}

// GrantWriteLine parses the grants line strictly and insert-or-updates
// its row (slot 89 op 1). 0 is the write; the negative kernel errno is
// handed back unmangled — -EACCES (unauthorized, or the row names the
// caller itself), -EINVAL (malformed line or over GrantLineMax), -ENOSPC
// (table full), -ENXIO (no host channel), -EIO (persist failed, rolled
// back).
func GrantWriteLine(line string) int64 {
	return svc4(SlotGrantAdmin, uintptr(grantAdminWrite), 0, strPtr(line), uintptr(len(line)))
}

// GrantWriteRow is GrantWriteLine for a structured row.
func GrantWriteRow(r GrantRow) int64 {
	return GrantWriteLine(GrantLine(r))
}

// GrantRows drains the op-0 index walk into a row table — the granted
// half of the grants pane's declared-vs-granted view. A negative second
// return is the kernel errno that stopped the walk: -EACCES leaves rows
// nil so a refused caller sees "granted unknown", never an empty table
// dressed as baseline.
func GrantRows() ([]GrantRow, int64) {
	var buf [GrantLineMax]byte
	var rows []GrantRow
	for i := uint64(0); ; i++ {
		n, rc := GrantReadRow(i, buf[:])
		if rc == -ErrENOENT {
			return rows, 0
		}
		if rc < 0 {
			return nil, rc
		}
		r, ok := ParseGrantLine(string(buf[:n]))
		if !ok {
			return nil, -ErrEINVAL
		}
		rows = append(rows, r)
	}
}

// GrantReceiptMax mirrors kernel measure.receipt_max — the longest
// receipt line the denial ring can hold, and the kernel's EINVAL bound
// for an op-2 buffer is 8 + this. GrantDenialsBuf drains the whole
// 32-entry ring in one call.
const (
	GrantReceiptMax = 176
	GrantDenialsBuf = 8 + 32*GrantReceiptMax
)

// GrantDenials drains the kernel's denial-receipt ring (slot 89 op 2):
// every receipt the kernel published for a word or scope denial this
// boot whose sequence is newer than cursor. lines are the verbatim RCPT
// lines (newline stripped); next is the cursor the next call should
// pass — the newest sequence actually returned, so a partial drain
// resumes mid-ring rather than skipping. dropped is the sequence gap
// the ring evicted between cursor and the first returned receipt
// (next - cursor - len(lines)); a caller that keeps pace sees 0.
// rc is the kernel errno — -EACCES for a caller outside the seat /
// CAP_PROC_ADMIN gate (lines nil, so a refused caller reads "unknown",
// never "no denials").
func GrantDenials(cursor uint64) (lines []string, next uint64, dropped uint64, rc int64) {
	var buf [GrantDenialsBuf]byte
	r := svc4(SlotGrantAdmin, uintptr(grantAdminDenials), uintptr(cursor),
		uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if r < 0 {
		return nil, cursor, 0, r
	}
	n := int(r)
	if n < 8 || n > len(buf) {
		return nil, cursor, 0, -ErrEINVAL
	}
	next = binary.LittleEndian.Uint64(buf[:8])
	for _, l := range strings.Split(string(buf[8:n]), "\n") {
		if l != "" {
			lines = append(lines, l)
		}
	}
	if gap := int64(next) - int64(cursor) - int64(len(lines)); gap > 0 {
		dropped = uint64(gap)
	}
	return lines, next, dropped, 0
}
