package main

// cache.go — M193a (#3253): the bounded local corpus GOMAIL remembers.
// Fetched envelopes and the last-N bodies per mailbox publish whole-file
// through vi.WriteFileSafe into the movable data root's MAIL/ subtree
// (data_root resolves /host by default — the seat's own rule), so a later
// run can paint folders, headers and bodies the wire already proved, and
// `search` can answer without a dial. What the cache does NOT hold the
// offline leg names as a cache-miss — memory is evidence, never invention.
//
// Files (under <data-root>/MAIL/, all small bounded codecs):
//
//	BOXES   folder names from the last real LIST, one per line
//	USE     the selected mailbox `use` recorded, one line
//	HDRS    envelope rows: box \t seq \t from \t subject \t date
//	BODIES  length-prefixed records: @box \t seq \t at \t mime \t len\n
//	        <len bytes>\n — 'at' is the last-use vi.Nanos the LRU reads
//
// Bounds are named constants, not flags: N bodies per mailbox, one byte
// cap across every cached body, a per-box and total envelope row cap,
// and a printed-hits cap for search. BODIES stays under vi's
// ReadFileAll bound by keeping cacheBytesMax well below it — a torn
// tail read would otherwise silently drop the newest record on the next
// whole-file rewrite.

import (
	"errors"
	"strconv"
	"strings"

	"virelai/settings"
	"virelai/vi"
)

const (
	cacheBoxesMax  = 32          // folder names BOXES keeps
	cacheHdrPerBox = 64          // envelope rows kept per mailbox
	cacheHdrRows   = 200         // envelope rows kept across all mailboxes
	cacheBodiesBox = 8           // N: bodies kept per mailbox
	cacheBodyBytes = bodyByteMax // one cached body's byte bound (the wire bound)
	cacheBytesMax  = 128 * 1024  // byte cap across every cached body
	cacheHitMax    = 32          // search result rows printed
	cacheFileMax   = 192 * 1024  // ReadFileAll bound — over every file's cap
	cacheFieldMax  = 160         // one record field's byte bound
)

// cacheClock is the LRU clock — vi.Nanos on the guest, injected in tests.
var cacheClock = vi.Nanos

// mailCacheHost is the platform seam (the goirc logHost shape): the guest
// implementation talks to /host (or the resolved data root) through vi;
// tests inject a map.
type mailCacheHost interface {
	// CacheDir resolves the MAIL/ subtree for this boot.
	CacheDir() string
	// MkdirShare creates the share directory; EEXIST is not an error.
	MkdirShare(path string) error
	// ReadShare reads a whole cache file; ok=false means absent.
	ReadShare(path string, max int) ([]byte, bool)
	// WriteShare publishes a cache file crash-safe (WriteFileSafe).
	WriteShare(path string, b []byte) error
}

type guestCacheHost struct{}

func (guestCacheHost) CacheDir() string {
	root, fellBack := settings.Load().ResolveDataRoot()
	if fellBack {
		// data_root=disk asked for the volume and none mounted — the
		// resolver already answered /host; this is the consumer's one
		// named line for the fallback.
		say("gomail: cache data_root fallback /host")
	}
	return root + "/MAIL"
}

func (guestCacheHost) MkdirShare(path string) error {
	h, rc := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if rc == 0 {
		vi.FileClose(uint32(h))
		return nil
	}
	if rc == -9 { // EEXIST
		return nil
	}
	return errors.New("mkdir " + strconv.FormatInt(rc, 10))
}

func (guestCacheHost) ReadShare(path string, max int) ([]byte, bool) {
	b, rc := vi.ReadFileAll(path, max)
	if rc < 0 {
		return nil, false
	}
	return b, true
}

func (guestCacheHost) WriteShare(path string, b []byte) error {
	if rc := vi.WriteFileSafe(path, b); rc < 0 {
		return errors.New("publish " + strconv.FormatInt(rc, 10))
	}
	return nil
}

var cacheH mailCacheHost = guestCacheHost{}

func cachePath(name string) string { return cacheH.CacheDir() + "/" + name }

func cacheRead(name string) []byte {
	b, _ := cacheH.ReadShare(cachePath(name), cacheFileMax)
	return b
}

// cacheWrite publishes one cache file. A failed publish is a named
// marker, never a verb failure — the cache is memory, not the wire.
func cacheWrite(name string, b []byte) {
	if err := cacheH.MkdirShare(cacheH.CacheDir()); err != nil {
		say("gomail: cache-fail " + cachePath(name) + " " + err.Error())
		return
	}
	if err := cacheH.WriteShare(cachePath(name), b); err != nil {
		say("gomail: cache-fail " + cachePath(name) + " " + err.Error())
		return
	}
	say("gomail: cache " + cachePath(name))
}

// field renders s one-line and bounded: the row grammar's separators
// fold to spaces so no field can break a record.
func field(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c == '\t' || c == '\r' || c == '\n' {
			b[i] = ' '
		}
	}
	if len(b) > cacheFieldMax {
		b = b[:cacheFieldMax]
	}
	return string(b)
}

func fields(line string) []string { return strings.Split(line, "\t") }

// --- HDRS: the envelope corpus ------------------------------------------

// cachedHdr is one remembered envelope row.
type cachedHdr struct {
	box     string
	seq     int
	from    string
	subject string
	date    string
}

func parseHdrs(b []byte) []cachedHdr {
	var out []cachedHdr
	for _, line := range strings.Split(string(b), "\n") {
		if line == "" {
			continue
		}
		f := fields(line)
		if len(f) != 5 {
			continue
		}
		n, ok := parseUint(f[1])
		if !ok || n <= 0 {
			continue
		}
		out = append(out, cachedHdr{box: f[0], seq: int(n), from: f[2], subject: f[3], date: f[4]})
	}
	return out
}

func formatHdrs(rows []cachedHdr) []byte {
	var b strings.Builder
	for _, h := range rows {
		b.WriteString(h.box)
		b.WriteByte('\t')
		b.WriteString(itoa(int64(h.seq)))
		b.WriteByte('\t')
		b.WriteString(h.from)
		b.WriteByte('\t')
		b.WriteString(h.subject)
		b.WriteByte('\t')
		b.WriteString(h.date)
		b.WriteByte('\n')
	}
	return []byte(b.String())
}

// cacheSaveHdrs merges a fetched window into HDRS: the box's old rows
// are replaced by what the wire just proved, other boxes' rows survive;
// per-box and total caps keep the newest rows.
func cacheSaveHdrs(box string, hdrs []Header) {
	rows := parseHdrs(cacheRead("HDRS"))
	var kept []cachedHdr
	for _, h := range rows {
		if h.box != box {
			kept = append(kept, h)
		}
	}
	for _, h := range hdrs {
		kept = append(kept, cachedHdr{
			box: field(box), seq: h.Seq,
			from: field(h.From), subject: field(h.Subject), date: field(h.Date),
		})
	}
	// Per-box cap: drop the box's oldest rows (file order is fetch order).
	for i := 0; i < len(kept); {
		n := 0
		for _, h := range kept {
			if h.box == box {
				n++
			}
		}
		if n <= cacheHdrPerBox {
			break
		}
		if kept[i].box == box {
			kept = append(kept[:i], kept[i+1:]...)
			continue
		}
		i++
	}
	for len(kept) > cacheHdrRows {
		kept = kept[1:]
	}
	cacheWrite("HDRS", formatHdrs(kept))
}

// cacheHdrsFor returns the box's remembered envelope rows.
func cacheHdrsFor(box string) []cachedHdr {
	var out []cachedHdr
	for _, h := range parseHdrs(cacheRead("HDRS")) {
		if h.box == box {
			out = append(out, h)
		}
	}
	return out
}

// --- BODIES: the last-N corpus ------------------------------------------

// cachedBody is one remembered body: the bytes the wire returned, the
// mime that picked the render, and the last-use instant the LRU reads.
type cachedBody struct {
	box  string
	seq  int
	at   int64
	mime string
	data []byte
}

// parseBodyHead decodes one '@box \t seq \t at \t mime \t len' record
// head (without the '@'). Returns the record sans payload and len.
func parseBodyHead(s string) (cachedBody, int, bool) {
	f := fields(s)
	if len(f) != 5 {
		return cachedBody{}, 0, false
	}
	seq, ok1 := parseUint(f[1])
	at, ok2 := parseUint(f[2])
	n, ok3 := parseUint(f[4])
	if !ok1 || !ok2 || !ok3 || seq <= 0 || n < 0 || n > cacheBodyBytes {
		return cachedBody{}, 0, false
	}
	return cachedBody{box: f[0], seq: int(seq), at: at, mime: f[3]}, int(n), true
}

// parseBodies walks the record stream: a head line, then exactly len
// payload bytes, then the record's closing newline. Malformed spans are
// skipped line-wise — a torn file degrades to fewer records, never to
// invented ones.
func parseBodies(b []byte) []cachedBody {
	var out []cachedBody
	for i := 0; i < len(b); {
		j := i
		for j < len(b) && b[j] != '\n' {
			j++
		}
		line := b[i:j]
		next := j
		if next < len(b) {
			next++
		}
		if len(line) > 0 && line[0] == '@' {
			rec, n, ok := parseBodyHead(string(line[1:]))
			if ok && n <= len(b)-next {
				rec.data = b[next : next+n]
				out = append(out, rec)
				i = next + n
				if i < len(b) && b[i] == '\n' {
					i++
				}
				continue
			}
		}
		i = next
	}
	return out
}

func formatBodies(recs []cachedBody) []byte {
	var b []byte
	for _, r := range recs {
		b = append(b, '@')
		b = append(b, r.box...)
		b = append(b, '\t')
		b = append(b, itoa(int64(r.seq))...)
		b = append(b, '\t')
		b = append(b, itoa(r.at)...)
		b = append(b, '\t')
		b = append(b, r.mime...)
		b = append(b, '\t')
		b = append(b, itoa(int64(len(r.data)))...)
		b = append(b, '\n')
		b = append(b, r.data...)
		b = append(b, '\n')
	}
	return b
}

// dropMinAt removes the least-recently-used record; box non-empty scopes
// the choice to one mailbox.
func dropMinAt(recs []cachedBody, box string) []cachedBody {
	idx := -1
	for i := range recs {
		if box != "" && recs[i].box != box {
			continue
		}
		if idx < 0 || recs[i].at < recs[idx].at {
			idx = i
		}
	}
	if idx < 0 {
		return recs
	}
	return append(recs[:idx], recs[idx+1:]...)
}

// evictBodies enforces the named bounds: at most cacheBodiesBox records
// per mailbox, cacheBytesMax bytes across them all — LRU loses either
// way.
func evictBodies(recs []cachedBody) []cachedBody {
	for {
		counts := map[string]int{}
		for _, r := range recs {
			counts[r.box]++
		}
		victim := ""
		for box, n := range counts {
			if n > cacheBodiesBox {
				victim = box
				break
			}
		}
		if victim != "" {
			recs = dropMinAt(recs, victim)
			continue
		}
		total := 0
		for _, r := range recs {
			total += len(r.data)
		}
		if total <= cacheBytesMax || len(recs) == 0 {
			return recs
		}
		recs = dropMinAt(recs, "")
	}
}

// cachePutBody remembers one fetched body: the same (box, seq) replaces,
// the bounds evict LRU, the whole file republishes.
func cachePutBody(box string, seq int, mime string, data []byte) {
	if len(data) > cacheBodyBytes {
		data = data[:cacheBodyBytes]
	}
	recs := parseBodies(cacheRead("BODIES"))
	var kept []cachedBody
	for _, r := range recs {
		if r.box == box && r.seq == seq {
			continue
		}
		kept = append(kept, r)
	}
	kept = append(kept, cachedBody{
		box: field(box), seq: seq, at: cacheClock(), mime: field(mime), data: data,
	})
	cacheWrite("BODIES", formatBodies(evictBodies(kept)))
}

// cacheGetBody returns a remembered body; the hit counts as a use, so
// 'at' advances and the file republishes — LRU means what it says.
func cacheGetBody(box string, seq int) (cachedBody, bool) {
	recs := parseBodies(cacheRead("BODIES"))
	for i := range recs {
		if recs[i].box == box && recs[i].seq == seq {
			recs[i].at = cacheClock()
			cacheWrite("BODIES", formatBodies(recs))
			return recs[i], true
		}
	}
	return cachedBody{}, false
}

// --- search ---------------------------------------------------------------

// fold ASCII-lowercases for the substring compare; bytes ≥ 0x80 compare
// case-sensitively (the named bound of a no-tables fold).
func fold(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + ('a' - 'A')
		}
	}
	return string(b)
}

// searchHit is one result: the message ref (box + seq), the envelope
// line when HDRS holds one, and whether the match lived in a body.
type searchHit struct {
	box      string
	seq      int
	from     string
	subject  string
	haveHdr  bool
	bodyOnly bool
}

// cacheSearch runs the substring query over the whole corpus: envelope
// from/subject first, then bodies — each (box, seq) reports once, an
// envelope row outranking a bare body ref.
func cacheSearch(q string) []searchHit {
	fq := fold(q)
	if fq == "" {
		return nil
	}
	hdrs := parseHdrs(cacheRead("HDRS"))
	bodies := parseBodies(cacheRead("BODIES"))
	seen := map[string]bool{}
	key := func(box string, seq int) string { return box + "\t" + itoa(int64(seq)) }
	var hits []searchHit
	for _, h := range hdrs {
		if strings.Contains(fold(h.from), fq) || strings.Contains(fold(h.subject), fq) {
			hits = append(hits, searchHit{box: h.box, seq: h.seq, from: h.from, subject: h.subject, haveHdr: true})
			seen[key(h.box, h.seq)] = true
		}
	}
	for _, r := range bodies {
		if seen[key(r.box, r.seq)] || !strings.Contains(fold(string(r.data)), fq) {
			continue
		}
		h := searchHit{box: r.box, seq: r.seq, bodyOnly: true}
		for _, e := range hdrs {
			if e.box == r.box && e.seq == r.seq {
				h.from, h.subject, h.haveHdr = e.from, e.subject, true
				break
			}
		}
		seen[key(r.box, r.seq)] = true
		hits = append(hits, h)
	}
	return hits
}

// --- the offline legs -------------------------------------------------------

// dialError marks the transport itself failing — the signal a cache leg
// may answer. A mailError from dialOne (the plaintext consent refusal)
// is a named refusal, not a dead wire, and never reads the cache.
type dialError struct{ err error }

func (e dialError) Error() string { return e.err.Error() }
func (e dialError) Unwrap() error { return e.err }

// offlineOr routes a dead transport to the verb's cache leg; every other
// error — consent refusals, session failures — passes through untouched.
func offlineOr(err error, leg func() error) error {
	if _, dead := err.(dialError); dead {
		return leg()
	}
	return err
}

// printBodyRows emits the body rows readOne and the offline render
// share, so a remembered body paints exactly like a fetched one.
func printBodyRows(seq int, mime string, html bool, data []byte) {
	say("gomail: body " + itoa(int64(seq)) + " " + mime + " bytes=" + itoa(int64(len(data))))
	text := string(data)
	if html {
		say("gomail: html-stripped " + itoa(int64(seq)))
		text = stripHTML(text)
	}
	lines := strings.Split(text, "\n")
	for i, l := range lines {
		if i >= bodyLineMax {
			say("gomail: text …")
			break
		}
		say("gomail: text " + strings.TrimRight(l, "\r"))
	}
}

// offlineBoxes answers 'boxes' from the remembered LIST.
func offlineBoxes() error {
	say("gomail: offline boxes")
	boxes := cacheLoadBoxes()
	if len(boxes) == 0 {
		return protoErr("cache-miss ", "boxes")
	}
	for _, b := range boxes {
		say("gomail: box " + b)
	}
	return nil
}

// offlineHeaders answers 'headers' from the box's remembered envelopes.
func offlineHeaders(mbox string) error {
	say("gomail: offline headers " + mbox)
	rows := cacheHdrsFor(mbox)
	if len(rows) == 0 {
		return protoErr("cache-miss ", mbox)
	}
	for _, h := range rows {
		say("gomail: hdr " + itoa(int64(h.seq)) + " " + h.from + ": " + h.subject)
	}
	return nil
}

// offlineRead answers 'read' from a remembered body; a miss is named.
func offlineRead(mbox string, seq int) error {
	say("gomail: offline read " + mbox + " " + itoa(int64(seq)))
	rec, ok := cacheGetBody(mbox, seq)
	if !ok {
		return protoErr("cache-miss ", mbox+" "+itoa(int64(seq)))
	}
	printBodyRows(seq, rec.mime, rec.mime == "text/html", rec.data)
	return nil
}

// offlineFetch is the composite offline leg: remembered folders, the
// box's remembered envelopes, then each requested body — the first miss
// names itself, nothing is fabricated.
func offlineFetch(mbox string, seqs []int) error {
	say("gomail: offline fetch " + mbox)
	boxes := cacheLoadBoxes()
	if len(boxes) == 0 {
		return protoErr("cache-miss ", "boxes")
	}
	for _, b := range boxes {
		say("gomail: box " + b)
	}
	rows := cacheHdrsFor(mbox)
	if len(rows) == 0 {
		return protoErr("cache-miss ", mbox)
	}
	for _, h := range rows {
		say("gomail: hdr " + itoa(int64(h.seq)) + " " + h.from + ": " + h.subject)
	}
	for _, seq := range seqs {
		rec, ok := cacheGetBody(mbox, seq)
		if !ok {
			return protoErr("cache-miss ", mbox+" "+itoa(int64(seq)))
		}
		printBodyRows(seq, rec.mime, rec.mime == "text/html", rec.data)
	}
	return nil
}
