package main

import (
	"strings"

	"virelai/vi"
	"virelai/webrender"
)

func webrenderSetCookies(head string) []webrender.Cookie { return webrender.SetCookieHeaders(head) }

func webrenderAcceptCookies(cs []webrender.Cookie, host string) []webrender.Cookie {
	return webrender.AcceptCookies(cs, host)
}

func webrenderCookieHeader(rows []string, host, path string) string {
	return webrender.CookieHeader(rows, host, path)
}

// ledgerFieldOK reports whether s is safe to store as one tab-separated
// ledger field (M97f F8, #2105): printable bytes only — a tab shifts the
// column layout, a CR or LF injects a whole row. This is the one field check
// every ledger write passes through (history, bookmarks, cookies, cache
// index, downloads): a remote-derived value is refused, never rewritten.
func ledgerFieldOK(s string) bool {
	for i := 0; i < len(s); i++ {
		if b := s[i]; b < 0x20 || b == 0x7f {
			return false
		}
	}
	return true
}

// The browser's persistent stores. All of them are plain text on the host
// file channel so a person can read them with any tool: one schema line, then
// one tab-separated row per record. Nothing is a binary blob, and nothing is
// stored outside the share the OS handed this app.
const (
	bookmarkPath = "/host/WEB-BOOKMARKS.TXT"
	cookiePath   = "/host/WEB-COOKIES.TXT"
	cacheIdxPath = "/host/WEB-CACHE.TXT"
	cacheBodyFmt = "/host/WEB-C-" // + 16 hex digits + ".BIN"
	downloadFmt  = "/host/WEB-DL-"
)

const (
	bookmarkSchema = "# virelai-web-bookmarks v1 (unix-seconds<TAB>target<TAB>title)"
	cookieSchema   = "# virelai-web-cookies v1 (unix-seconds<TAB>name<TAB>value<TAB>domain<TAB>path<TAB>flags)"
	cacheSchema    = "# virelai-web-cache v1 (key<TAB>url<TAB>bytes<TAB>unix-seconds<TAB>body-file)"
)

// ledgerMax bounds every ledger read (a store is not a page).
const ledgerMax = 64 * 1024

// fnv1a64 names cache bodies. It is a filename convention, not a security
// boundary: the cache holds pages this browser fetched for itself.
func fnv1a64(s string) uint64 {
	const offset = 14695981039346656037
	const prime = 1099511628211
	h := uint64(offset)
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= prime
	}
	return h
}

func hex16(v uint64) string {
	const digits = "0123456789abcdef"
	var b [16]byte
	for i := 15; i >= 0; i-- {
		b[i] = digits[v&0xf]
		v >>= 4
	}
	return string(b[:])
}

// cacheKey is the cache directory key for a URL.
func cacheKey(url string) string { return hex16(fnv1a64(url)) }

func cacheBodyPath(url string) string { return cacheBodyFmt + cacheKey(url) + ".BIN" }

// ledgerRows returns the data rows of a store (schema and blank lines are
// dropped). A missing store is an empty store.
func ledgerRows(path string) []string {
	b, rc := vi.ReadFileAll(path, ledgerMax)
	if rc < 0 || len(b) == 0 {
		return nil
	}
	var out []string
	for _, ln := range strings.Split(string(b), "\n") {
		ln = strings.TrimRight(ln, "\r")
		if ln == "" || strings.HasPrefix(ln, "#") {
			continue
		}
		out = append(out, ln)
	}
	return out
}

func ledgerCount(path string) int { return len(ledgerRows(path)) }

// ledgerAppend writes the schema line on first use, then appends the row.
func ledgerAppend(path, schema, row string) bool {
	if !vi.FileExists(path) {
		vi.FileAppend(path, []byte(schema+"\n"))
	}
	return vi.FileAppend(path, []byte(row+"\n"))
}

// writeFileAll replaces a file's contents (open, truncate, write) — the
// compaction half of delete/clear.
// writeFileAll replaces a store's contents crash-safe (M81e #1765) — the
// compaction half of delete/clear. vi.WriteFileSafe publishes via a
// sacrificial temp (fsync before close, then delete-then-rename), so a crash
// mid-compaction leaves the OLD ledger or none, never a half-written row. The
// empty body still publishes an empty file: that is what clear means.
func writeFileAll(path string, b []byte) bool {
	return vi.WriteFileSafe(path, b) >= 0
}

// ledgerRewrite replaces a store with schema + rows (delete/clear).
func ledgerRewrite(path, schema string, rows []string) bool {
	var b strings.Builder
	b.WriteString(schema)
	b.WriteByte('\n')
	for _, r := range rows {
		b.WriteString(r)
		b.WriteByte('\n')
	}
	return writeFileAll(path, []byte(b.String()))
}

// --- cache ---------------------------------------------------------------

// cacheStore records a fetched page body and its index row.
func (a *app) cacheStore(url string, body []byte) bool {
	if !ledgerFieldOK(url) {
		return false
	}
	path := cacheBodyPath(url)
	if !writeFileAll(path, body) {
		return false
	}
	row := cacheKey(url) + "\t" + url + "\t" + itoa(len(body)) + "\t" + itoa64(vi.Time()) + "\t" + path
	if !ledgerAppend(cacheIdxPath, cacheSchema, row) {
		return false
	}
	vi.ConsoleLine(markerCache + itoa(len(body)) + " " + url)
	return true
}

// cacheLookup returns a cached body for a URL, if this browser stored one.
func (a *app) cacheLookup(url string) ([]byte, bool) {
	key := cacheKey(url)
	for _, row := range ledgerRows(cacheIdxPath) {
		f := strings.Split(row, "\t")
		if len(f) < 2 || f[0] != key || f[1] != url {
			continue
		}
		body, rc := vi.ReadFileAll(cacheBodyPath(url), vi.MaxFileBytes)
		if rc < 0 || len(body) == 0 {
			return nil, false
		}
		return body, true
	}
	return nil, false
}

// clearCache drops every cached body and empties the index.
func (a *app) clearCache() int {
	rows := ledgerRows(cacheIdxPath)
	n := 0
	for _, row := range rows {
		f := strings.Split(row, "\t")
		if len(f) >= 2 && ledgerFieldOK(f[1]) {
			// The body path is DERIVED from the row's URL, never read from
			// the row: a shifted or injected row must not point the delete
			// at a file it did not store (M97f F8, #2105).
			if vi.FileDelete(cacheBodyPath(f[1])) >= 0 {
				n++
			}
		}
	}
	ledgerRewrite(cacheIdxPath, cacheSchema, nil)
	return n
}

// --- history / bookmarks / cookies ---------------------------------------

// historyDeleteNewest removes the most recent row (the "delete an entry"
// control); a browser that cannot forget is not inspectable in any useful
// sense.
func (a *app) historyDeleteNewest() bool {
	rows := ledgerRows(historyPath)
	if len(rows) == 0 {
		return false
	}
	return ledgerRewrite(historyPath, historySchema, rows[:len(rows)-1])
}

// bookmarkToggle moved to bookmarks.go (M126b #2594): the store is now the
// FLINT workspace atom table, not this ledger. bookmarkPath/bookmarkSchema
// stay — loadBookmarks folds their rows into atoms once, on upgrade.

// cookieMaxRows bounds the cookie ledger (M97f F2, #2105): a store is a
// bounded jar, not a bottomless one — new rows past the cap evict the
// oldest first.
const cookieMaxRows = 512

// boundCookieRows drops the oldest rows so appending `add` more keeps the
// ledger within cookieMaxRows.
func boundCookieRows(rows []string, add int) []string {
	if len(rows)+add <= cookieMaxRows {
		return rows
	}
	drop := len(rows) + add - cookieMaxRows
	if drop > len(rows) {
		drop = len(rows)
	}
	return rows[drop:]
}

// persistCookies records the Set-Cookie rows a response from host carried,
// under the bounded subset ADR 0028 D §7 declares (M97f F1+F2, #2105):
// AcceptCookies already refused every Domain that does not name the request
// host exactly, so only origin-exact rows are ever stored, and every field
// passes the ledger-field check before it is appended.
func (a *app) persistCookies(head, host string) int {
	cs := webrenderAcceptCookies(webrenderSetCookies(head), host)
	if len(cs) == 0 {
		return 0
	}
	if rows := ledgerRows(cookiePath); len(rows)+len(cs) > cookieMaxRows {
		ledgerRewrite(cookiePath, cookieSchema, boundCookieRows(rows, len(cs)))
	}
	for _, c := range cs {
		if !ledgerFieldOK(c.Name) || !ledgerFieldOK(c.Value) ||
			!ledgerFieldOK(c.Domain) || !ledgerFieldOK(c.Path) || !ledgerFieldOK(c.Flags) {
			continue
		}
		row := itoa64(vi.Time()) + "\t" + c.Name + "\t" + c.Value + "\t" + c.Domain + "\t" + c.Path + "\t" + c.Flags
		ledgerAppend(cookiePath, cookieSchema, row)
	}
	return len(cs)
}

// cookieHeaderFor builds the request Cookie header for a target.
func (a *app) cookieHeaderFor(host, path string) string {
	return webrenderCookieHeader(ledgerRows(cookiePath), host, path)
}

func (a *app) clearCookies() int {
	n := ledgerCount(cookiePath)
	ledgerRewrite(cookiePath, cookieSchema, nil)
	return n
}

// --- downloads -----------------------------------------------------------

// saveDownload writes the current page body to the share and records it.
func (a *app) saveDownload() bool {
	return a.saveDownloadTo(downloadFmt + downloadName(a.target))
}

// saveDownloadTo is the write+ledger leg shared by the fixed download and
// the M124b picker's chosen path.
func (a *app) saveDownloadTo(path string) bool {
	if len(a.lastBody) == 0 || a.target == "" || !ledgerFieldOK(a.target) {
		return false
	}
	// M153e (#2925): a .pdf name takes the raster leg — the laid-out
	// document sliced to Letter pages through pdfwrite, not the body bytes.
	if isPDFName(path) {
		return a.savePDFTo(path)
	}
	if !writeFileAll(path, a.lastBody) {
		return false
	}
	ledgerAppend("/host/WEB-DOWNLOADS.TXT",
		"# virelai-web-downloads v1 (unix-seconds<TAB>target<TAB>file<TAB>bytes)",
		itoa64(vi.Time())+"\t"+a.target+"\t"+path+"\t"+itoa(len(a.lastBody)))
	vi.ConsoleLine(markerDownload + path + " " + itoa(len(a.lastBody)))
	return true
}

// downloadName derives a filesystem-safe name from a target.
// downloadName derives a filesystem-safe name from a target, bounded to
// dlNameMax so "/host/WEB-DL-"+name stays inside the kernel's 64-byte
// path ceiling. The staged write itself lives in downloads.go (M126e).
func downloadName(target string) string {
	s := target
	if i := strings.Index(s, "://"); i >= 0 {
		s = s[i+3:]
		if j := strings.IndexByte(s, '/'); j >= 0 {
			s = s[j+1:]
		} else {
			s = ""
		}
	}
	if i := strings.IndexAny(s, "?#"); i >= 0 {
		s = s[:i]
	}
	if i := strings.LastIndexByte(s, '/'); i >= 0 {
		s = s[i+1:]
	}
	if s == "" {
		s = "PAGE.HTML"
	}
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		ch := s[i]
		switch {
		case ch >= 'a' && ch <= 'z', ch >= 'A' && ch <= 'Z', ch >= '0' && ch <= '9', ch == '.', ch == '-', ch == '_':
			out = append(out, ch)
		default:
			out = append(out, '_')
		}
	}
	if len(out) > dlNameMax {
		out = out[:dlNameMax]
	}
	return string(out)
}

// storeSummary is the boot-time inventory the gate reads: it proves the
// stores are populated from disk, not from memory.
func (a *app) storeSummary() string {
	return markerStores +
		"history=" + itoa(ledgerCount(historyPath)) +
		" bookmarks=" + itoa(len(a.books)) +
		" cookies=" + itoa(ledgerCount(cookiePath)) +
		" cache=" + itoa(ledgerCount(cacheIdxPath)) +
		" downloads=" + itoa(ledgerCount("/host/WEB-DOWNLOADS.TXT"))
}
