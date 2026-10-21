// receipts.go — M148b (issue #2805): the vault's own receipts file. Every
// unlock, reveal, copy and failed unlock appends one row; the Receipts view
// lists them back. A row carries time, action and entry name — NEVER the
// secret, the note or the passphrase — and lives OUTSIDE the sealed body
// deliberately: a failed unlock holds no key, so its receipt could never be
// written into the vault it refused to open. Plaintext on the share is the
// file's own contract, the same one the marker vocabulary runs under.
//
// Row shape (one line per receipt):
//
//	<epoch-seconds> <action> <name>\n
//
// epoch is the ADR 0007 wall-clock slot (vi.Time); name is the rest of the
// line, so a multi-word entry name needs no escaping — the field contract
// already refuses newlines. A vault-level action (unlock, unlock-failed)
// records "-" for the name. A line that does not parse is kept verbatim for
// the view: an audit row that was hand-mangled on the share is still a row,
// and hiding it would be the dishonest answer.
package main

import (
	"strconv"
	"strings"
)

// Action vocabulary — the receiptable events: the M148b four, plus the
// M156c bundle arc. Export and import are vault-level rows — an export moves
// every secret out under a second passphrase and an import folds a bundle
// in; both are exactly what the audit file is for. Import's name field
// carries the merge counts (added=N skipped=M), never an entry's name.
const (
	actUnlock      = "unlock"
	actUnlockFail  = "unlock-failed"
	actReveal      = "reveal"
	actCopy        = "copy"
	actExport      = "export"
	actImport      = "import"
	rcptCorruptRow = "corrupt" // serial marker for a row that did not parse
)

// receipt is one parsed row. ok=false means the line was not a receipt row;
// raw holds it verbatim so the view can still show it.
type receipt struct {
	epoch  int64
	action string
	name   string
	ok     bool
	raw    string
}

// receiptLine renders one row. An empty name becomes "-" — the vault-level
// placeholder — so every row keeps its three fields.
func receiptLine(epoch int64, action, name string) []byte {
	if name == "" {
		name = "-"
	}
	return []byte(strconv.FormatInt(epoch, 10) + " " + action + " " + name + "\n")
}

// parseReceipts reads the file back into rows. Blank lines drop; a line that
// is not "<int> <word> <rest>" is preserved with ok=false and its action
// reported as rcptCorruptRow.
func parseReceipts(data []byte) []receipt {
	var out []receipt
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" {
			continue
		}
		r := receipt{raw: line, action: rcptCorruptRow}
		lead, rest, ok1 := strings.Cut(line, " ")
		action, name, ok2 := strings.Cut(rest, " ")
		if ok1 && ok2 {
			if epoch, err := strconv.ParseInt(lead, 10, 64); err == nil {
				r.epoch, r.action, r.name, r.ok = epoch, action, name, true
			}
		}
		out = append(out, r)
	}
	return out
}
