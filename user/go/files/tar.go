// M167c (issue #2993): browse a tar without extracting it. Enter or `l`
// on a recognised archive (.tar, .tgz, .tar.gz) opens it as a read-only
// virtual directory — the path bar shows `<archive>/`, rows come from the
// member names, and `h`/Backspace at the top hands back the real listing.
//
// The reader is in-tree: 512-byte ustar headers with checksum
// verification, the prefix+name join, octal and base-256 sizes, octal
// mtimes, type flags 0/NUL (file), 5 (dir), 2 (symlink — listed, never
// followed), pax `x` records for path and size, and GNU `L` long names.
// Other types (`S`, `g`, devices) list as unsupported rows. Two zero
// blocks end the archive; `..`, absolute and empty names list as refused
// rows and never resolve.
//
// Bounds: at most tarMaxEntries members and tarMaxStream bytes streamed
// per listing; `.tgz`/`.tar.gz` are accepted only when the compressed
// file is at most tgzMaxComp and inflates to at most tgzMaxInflate
// through flate.InflateGzip (the inflated image is kept for the session —
// entry reads are slices). A plain .tar is never held whole: the scan
// streams through once and a member's bytes are read by re-opening the
// archive and streaming to its offset. Past any bound the open refuses by
// name (`gofiles: tar refused <name> <reason>`).
//
// Read-only inside: rename, delete, cut, copy, paste, marks, open,
// open-with, export, search, pin and the menu refuse with
// `gofiles: tar read-only <op>`. Space on a file member streams to its
// offset and fills the existing text/image QuickLook arms with at most
// vi.MaxFileBytes.
//
// The model stays pure — the one seam is tarOpenSrc (FileOpen/FileRead on
// the guest, a byte-slice stub in host tests), the same shape readHead
// and favRead already use.
package main

import (
	"strings"

	"virelai/flate"
	"virelai/mime"
	"virelai/vi"
)

const (
	tarBlock      = 512
	tarMaxEntries = 512
	tarMaxStream  = 64 << 20  // 64 MiB streamed per listing
	tgzMaxComp    = 256 << 10 // compressed-file bound
	tgzMaxInflate = 2 << 20   // inflated-image bound
)

// Row classes carried on DirEntry.Reserved[0] inside a tar listing (the
// favMissFlag/mount-row pattern — the field means nothing to real rows).
const (
	tarClsFile uint8 = iota + 1
	tarClsDir
	tarClsLink
	tarClsOther // unsupported typeflag — listed, never opens
	tarClsRefused
)

// tarEnt is one scanned member: its archive-internal name (no leading
// slash, no trailing slash), data offset and size, header mtime, and the
// class the listing shows it as. link is the '2' target.
type tarEnt struct {
	name string
	link string
	size uint64
	mt   int64
	off  int64
	cls  uint8
}

// tarArc is the open archive: where it lives, where the browser was when
// it entered, the member list, and — for .tgz — the inflated image the
// entry reads slice. bytes is the stream count the scan consumed.
type tarArc struct {
	name  string
	path  string
	dir   string
	img   []byte
	ents  []tarEnt
	bytes int64
}

// tarSrc is a sequential read end over an archive's tar image: a file
// handle on the guest, a byte slice under tests. The parser consumes it
// forward only; skips are reads that discard.
type tarSrc interface {
	read(dst []byte) (int, int64)
	close()
}

// fileTarSrc wraps a guest file handle — the only source that exists on
// the guest.
type fileTarSrc struct{ h uint32 }

func (s *fileTarSrc) read(dst []byte) (int, int64) { return vi.FileRead(s.h, dst) }
func (s *fileTarSrc) close()                       { vi.FileClose(s.h) }

// memTarSrc serves a held image (an inflated .tgz; test fixtures).
type memTarSrc struct {
	buf []byte
	pos int
}

func (s *memTarSrc) read(dst []byte) (int, int64) {
	if s.pos >= len(s.buf) {
		return 0, 0
	}
	n := copy(dst, s.buf[s.pos:])
	s.pos += n
	return n, int64(n)
}
func (s *memTarSrc) close() {}

// tarOpenSrc is the archive's open seam — vi.FileOpen on the guest,
// stubbed by the host tests (the readHead pattern).
var tarOpenSrc = func(path string) (tarSrc, int64) {
	h, rc := vi.FileOpen(path, vi.ModeRead)
	if rc < 0 {
		return nil, rc
	}
	return &fileTarSrc{h: uint32(h)}, 0
}

// tarFull reads exactly len(dst) from src. Returns the count read — short
// means the stream ended mid-block (a truncated archive).
func tarFull(src tarSrc, dst []byte) int64 {
	var got int64
	for got < int64(len(dst)) {
		n, rc := src.read(dst[got:])
		if n > 0 {
			got += int64(n)
			continue
		}
		if rc < 0 {
			return -1
		}
		break // clean EOF
	}
	return got
}

// tarSkip discards n stream bytes by reading through them — the file
// channel has no seek, so "stream to its offset" is literal.
func tarSkip(src tarSrc, n int64) int64 {
	var scratch [8192]byte
	var done int64
	for done < n {
		take := n - done
		if take > int64(len(scratch)) {
			take = int64(len(scratch))
		}
		got := tarFull(src, scratch[:take])
		if got <= 0 {
			return done
		}
		done += got
		if got < take {
			return done
		}
	}
	return done
}

// isTarName names a recognised archive spelling (case-folded): .tar,
// .tgz, .tar.gz.
func isTarName(name string) bool {
	l := strings.ToLower(name)
	return strings.HasSuffix(l, ".tar") || strings.HasSuffix(l, ".tgz") ||
		strings.HasSuffix(l, ".tar.gz")
}

func isTgz(name string) bool {
	l := strings.ToLower(name)
	return strings.HasSuffix(l, ".tgz") || strings.HasSuffix(l, ".tar.gz")
}

// tarOctal decodes a header numeric field: space/NUL-padded octal, or the
// base-256 big-endian form GNU uses when the high bit of byte 0 is set.
func tarOctal(f []byte) (int64, bool) {
	if len(f) == 0 {
		return 0, false
	}
	if f[0]&0x80 != 0 {
		var v uint64
		for _, b := range f[1:] {
			v = v<<8 | uint64(b)
		}
		return int64(v), true
	}
	var v int64
	seen := false
	for _, b := range f {
		switch {
		case b == ' ' || b == 0:
			if seen {
				return v, true
			}
		case b >= '0' && b <= '7':
			v = v*8 + int64(b-'0')
			seen = true
		default:
			return 0, false
		}
	}
	return v, seen
}

func tarZero(blk []byte) bool {
	for _, b := range blk {
		if b != 0 {
			return false
		}
	}
	return true
}

func tarStr(f []byte) string {
	n := 0
	for n < len(f) && f[n] != 0 {
		n++
	}
	return string(f[:n])
}

// tarCheck verifies a header's checksum: the field reads as octal and
// equals the sum of the 512 bytes with the field itself counted as
// spaces (unsigned arithmetic, the POSIX form).
func tarCheck(blk []byte) bool {
	want, ok := tarOctal(blk[148:156])
	if !ok {
		return false
	}
	var sum int64
	for i, b := range blk {
		if i >= 148 && i < 156 {
			b = ' '
		}
		sum += int64(b)
	}
	return sum == want
}

// tarNameClean validates a member name: an empty name, a leading slash,
// and any ".." component mark the entry refused — it is listed but can
// never resolve. A trailing slash is trimmed (dir spellings carry it).
func tarNameClean(name string) (string, bool) {
	name = strings.TrimSuffix(name, "/")
	if name == "" {
		return name, false
	}
	if name[0] == '/' {
		return name, false
	}
	for i := 0; i <= len(name); {
		j := strings.IndexByte(name[i:], '/')
		var part string
		if j < 0 {
			part = name[i:]
			i = len(name) + 1
		} else {
			part = name[i : i+j]
			i += j + 1
		}
		if part == ".." {
			return name, false
		}
	}
	return name, true
}

// tarPax parses one extended-header body ("len key=value\n" records) for
// the keys this reader honours: path and size.
func tarPax(body []byte) (path string, size int64, hasSize bool) {
	size = -1
	for len(body) > 0 {
		sp := -1
		for i := 0; i < len(body) && i < 32; i++ {
			if body[i] == ' ' {
				sp = i
				break
			}
		}
		if sp <= 0 {
			return
		}
		var l int64
		for _, b := range body[:sp] {
			if b < '0' || b > '9' {
				return
			}
			l = l*10 + int64(b-'0')
		}
		if l < int64(sp)+2 || int(l) > len(body) {
			return
		}
		rec := body[sp+1 : l]
		body = body[l:]
		if len(rec) == 0 || rec[len(rec)-1] != '\n' {
			continue
		}
		rec = rec[:len(rec)-1]
		eq := -1
		for i, b := range rec {
			if b == '=' {
				eq = i
				break
			}
		}
		if eq < 0 {
			continue
		}
		key, val := string(rec[:eq]), string(rec[eq+1:])
		switch key {
		case "path":
			path = val
		case "size":
			var v int64
			ok := true
			for _, b := range []byte(val) {
				if b < '0' || b > '9' {
					ok = false
					break
				}
				v = v*10 + int64(b-'0')
			}
			if ok {
				size, hasSize = v, true
			}
		}
	}
	return
}

// tarParse scans one tar image forward. Helpers that carry state for the
// NEXT real entry (pax x, GNU L/K) never count toward the member list;
// everything else does, refused and unsupported rows included. The reason
// vocabulary is the marker's: stream, entries, checksum, truncated,
// malformed.
func tarParse(src tarSrc) (ents []tarEnt, streamed int64, refuse string) {
	var blk [tarBlock]byte
	var paxName, longName, longLink string
	var paxSize int64 = -1
	for {
		got := tarFull(src, blk[:])
		if got < 0 {
			return nil, streamed, "read"
		}
		if got < tarBlock {
			return nil, streamed, "truncated"
		}
		streamed += tarBlock
		if streamed > tarMaxStream {
			return nil, streamed, "stream"
		}
		if tarZero(blk[:]) {
			var nxt [tarBlock]byte
			g := tarFull(src, nxt[:])
			if g < 0 {
				return nil, streamed, "read"
			}
			streamed += g
			if g == tarBlock && tarZero(nxt[:]) {
				return ents, streamed, ""
			}
			if g == 0 {
				return nil, streamed, "truncated" // one zero block, then EOF
			}
			return nil, streamed, "malformed"
		}
		if !tarCheck(blk[:]) {
			return nil, streamed, "checksum"
		}
		flag := blk[156]
		size, ok := tarOctal(blk[124:136])
		if !ok || size < 0 {
			return nil, streamed, "malformed"
		}
		mt, _ := tarOctal(blk[136:148])
		name := tarStr(blk[0:100])
		link := tarStr(blk[157:257])
		ustar := blk[257] == 'u' && blk[258] == 's' && blk[259] == 't' &&
			blk[260] == 'a' && blk[261] == 'r'
		if ustar {
			if pre := tarStr(blk[345:500]); pre != "" {
				name = pre + "/" + name
			}
		}
		// The data extent belongs to this record whatever its flag is.
		dataPad := (size + tarBlock - 1) &^ (tarBlock - 1)
		off := streamed
		switch flag {
		case 'x': // pax extended header — state for the next member
			body := make([]byte, size)
			if tarFull(src, body) != size {
				return nil, streamed, "truncated"
			}
			streamed += size
			p, s, has := tarPax(body)
			paxName = p
			if has {
				paxSize = s
			}
		case 'g': // pax global header — an unsupported ROW, per the card
			ents = append(ents, tarEnt{name: name, size: uint64(size),
				mt: mt, off: off, cls: tarClsOther})
		case 'L': // GNU long name — applies to the next member
			body := make([]byte, size)
			if tarFull(src, body) != size {
				return nil, streamed, "truncated"
			}
			streamed += size
			longName = tarStr(body)
		case 'K': // GNU long link target
			body := make([]byte, size)
			if tarFull(src, body) != size {
				return nil, streamed, "truncated"
			}
			streamed += size
			longLink = tarStr(body)
		default:
			if longName != "" {
				name, longName = longName, ""
			}
			if paxName != "" {
				name, paxName = paxName, ""
			}
			if paxSize >= 0 {
				size, dataPad = paxSize, (paxSize+tarBlock-1)&^(tarBlock-1)
				paxSize = -1
			}
			if longLink != "" {
				link, longLink = longLink, ""
			}
			clean, ok := tarNameClean(name)
			e := tarEnt{name: clean, size: uint64(size), mt: mt,
				off: off, link: link}
			switch {
			case !ok:
				e.cls = tarClsRefused
			case flag == '5' || flag == '7':
				e.cls = tarClsDir
			case flag == '2':
				e.cls = tarClsLink
			case flag == '0' || flag == 0:
				e.cls = tarClsFile
			default:
				e.cls = tarClsOther
			}
			ents = append(ents, e)
			if len(ents) > tarMaxEntries {
				return nil, streamed, "entries"
			}
		}
		if flag != 'x' && flag != 'L' && flag != 'K' {
			if tarSkip(src, dataPad) != dataPad {
				return nil, streamed, "truncated"
			}
			streamed += dataPad
			if streamed > tarMaxStream {
				return nil, streamed, "stream"
			}
		} else {
			// helper records' data was already consumed above
			pad := dataPad - size
			if pad > 0 && tarSkip(src, pad) != pad {
				return nil, streamed, "truncated"
			}
			streamed += pad
		}
	}
}

// tarLoad opens path and scans it under the card's bounds. refuse is the
// marker's reason word; "" means the archive browsed.
func tarLoad(path, name string, hint uint64) (*tarArc, string) {
	a := &tarArc{name: name, path: path}
	if isTgz(name) {
		if hint > tgzMaxComp {
			return nil, "compressed"
		}
		src, rc := tarOpenSrc(path)
		if rc < 0 {
			return nil, "read"
		}
		comp := make([]byte, 0, hint)
		var part [8192]byte
		for len(comp) <= tgzMaxComp {
			n, r := src.read(part[:])
			if n > 0 {
				comp = append(comp, part[:n]...)
			}
			if r < 0 {
				src.close()
				return nil, "read"
			}
			if n == 0 {
				break
			}
		}
		src.close()
		if len(comp) > tgzMaxComp {
			return nil, "compressed"
		}
		img := make([]byte, tgzMaxInflate)
		n, _, err := flate.InflateGzip(img, comp)
		if err != nil {
			if flate.IsOutputBound(err) {
				return nil, "inflated"
			}
			return nil, "gzip"
		}
		a.img = img[:n]
		ents, b, refuse := tarParse(&memTarSrc{buf: a.img})
		if refuse != "" {
			return nil, refuse
		}
		a.ents, a.bytes = ents, b
		return a, ""
	}
	src, rc := tarOpenSrc(path)
	if rc < 0 {
		return nil, "read"
	}
	ents, b, refuse := tarParse(src)
	src.close()
	if refuse != "" {
		return nil, refuse
	}
	a.ents, a.bytes = ents, b
	return a, ""
}

// readEnt streams to the member's data offset and reads at most max of
// its bytes — at most its own size. The .tgz image answers from memory;
// a .tar re-opens the file and skips forward.
func (a *tarArc) readEnt(e tarEnt, max int) ([]byte, int64) {
	want := int64(max)
	if uint64(want) > e.size {
		want = int64(e.size)
	}
	if want < 0 {
		want = 0
	}
	if a.img != nil {
		if e.off < 0 || e.off >= int64(len(a.img)) {
			return nil, 0
		}
		end := e.off + want
		if end > int64(len(a.img)) {
			end = int64(len(a.img))
		}
		out := a.img[e.off:end]
		return out, int64(len(out))
	}
	src, rc := tarOpenSrc(a.path)
	if rc < 0 {
		return nil, rc
	}
	defer src.close()
	if tarSkip(src, e.off) != e.off {
		return nil, -vi.ErrEIO
	}
	out := make([]byte, want)
	got := tarFull(src, out)
	if got < 0 {
		got = 0
	}
	return out[:got], got
}

// --- model integration -------------------------------------------------

// tarReadOnly is the read-only refusal for op inside an archive: the
// marker names the verb, the status line says why.
func (m *model) tarReadOnly(op string) {
	m.emit(markerTarRO + op)
	m.status = "tar: read-only (" + op + ")"
}

// enterTar is openSel's archive arm: scan under the bounds, and a pass
// becomes the virtual listing while a refusal stays on the outer listing
// with its reason named.
func (m *model) enterTar(e vi.DirEntry) {
	name := e.NameString()
	path, ok := joinPath(m.path, name)
	if !ok {
		m.status = "tar: path too long"
		return
	}
	arc, refuse := tarLoad(path, name, uint64(e.Size))
	if refuse != "" {
		m.emit(markerTarNo + name + " " + refuse)
		m.status = "tar: refused " + refuse
		return
	}
	arc.dir = m.path
	m.tar = arc
	m.tarSub = ""
	m.tarRows = nil
	m.path = path + "/"
	m.sel = 0
	if m.view == viewGrid {
		// The tile cache is keyed on real paths+stats — the archive's
		// rows have neither, so entering an archive steps out of the
		// grid (t inside refuses by name).
		m.view = m.viewUnder
		m.gridFName = ""
	}
	m.emit(markerTarOpen + name + " entries=" + vi.Itoa64(int64(len(arc.ents))) +
		" bytes=" + vi.Itoa64(arc.bytes))
	m.refresh()
}

// openTarRow is Enter/`l` inside the archive: a directory row descends
// (the row may be implied by member names — it has no member of its own);
// every other row is a read-only open refusal.
func (m *model) openTarRow(e vi.DirEntry) {
	if !e.Dir() {
		m.tarReadOnly("open")
		return
	}
	name := e.NameString()
	m.tarSub += name + "/"
	m.path = m.tar.path + "/" + m.tarSub
	m.sel = 0
	m.emit(markerCd + m.path)
	m.refresh()
}

// tarEntAt resolves the selected row to its member through the sorted
// row map.
func (m *model) tarEntAt(i int) (tarEnt, bool) {
	if m.tar == nil || i < 0 || i >= len(m.tarRows) {
		return tarEnt{}, false
	}
	return m.tar.ents[m.tarRows[i]], true
}

// refreshTar is the listing half of the virtual directory: member names
// under m.tarSub become rows — an implied directory when more components
// follow, its own row otherwise. Refused names list only at the archive
// root (they can never resolve anywhere deeper). The row map is sorted
// alongside the entries so row i still names member tarRows[i].
func (m *model) refreshTar() {
	type pair struct {
		e   vi.DirEntry
		idx int
	}
	var rows []pair
	seen := map[string]bool{}
	for i, en := range m.tar.ents {
		rel := en.name
		if en.cls == tarClsRefused {
			if m.tarSub != "" {
				continue
			}
		} else {
			if !strings.HasPrefix(rel, m.tarSub) {
				continue
			}
			rel = rel[len(m.tarSub):]
		}
		if rel == "" {
			continue
		}
		rowName := rel
		isDir := en.cls == tarClsDir
		if en.cls != tarClsRefused {
			if j := strings.IndexByte(rel, '/'); j >= 0 {
				rowName, isDir = rel[:j], true
			}
		}
		if rowName == "" {
			rowName = "(empty)"
		}
		if isDir {
			if seen[rowName] {
				continue
			}
			seen[rowName] = true
		}
		var de vi.DirEntry
		copy(de.Name[:], rowName)
		if isDir {
			de.IsDir = 1
		}
		if en.size > 0xffffffff {
			de.Size = 0xffffffff
		} else {
			de.Size = uint32(en.size)
		}
		// The row's class is authoritative (an implied dir row still maps
		// to a file member for reads) — Reserved[0] carries it.
		if isDir {
			de.Reserved[0] = tarClsDir
		} else {
			de.Reserved[0] = en.cls
		}
		rows = append(rows, pair{de, i})
	}
	// The listing order reuses the app's own sort — the pair sort keeps
	// the row->member map aligned through it.
	for i := 1; i < len(rows); i++ {
		v := rows[i]
		j := i - 1
		for j >= 0 && entryLess(v.e, rows[j].e, m.sort) {
			rows[j+1] = rows[j]
			j--
		}
		rows[j+1] = v
	}
	m.n = 0
	m.tarRows = m.tarRows[:0]
	for _, p := range rows {
		if m.n == len(m.entries) {
			break // the kernel's 16-row window applies here too
		}
		m.entries[m.n] = p.e
		m.tarRows = append(m.tarRows, p.idx)
		m.n++
	}
	m.clampSel()
	m.pruneMarks()
	m.watcher.Adopt(vi.DirSnapshot{OK: false})
	m.emit(markerList + m.path + " n=" + vi.Itoa64(int64(m.n)))
	for i := 0; i < m.n; i++ {
		e := m.entries[i]
		kind := "file"
		switch e.Reserved[0] {
		case tarClsDir:
			kind = "dir"
		case tarClsLink:
			kind = "link"
		case tarClsRefused:
			kind = "refused"
		case tarClsOther:
			kind = "unsupported"
		}
		m.emit(markerEntry + e.NameString() + " " + kind +
			" size=" + vi.Itoa64(int64(e.Size)))
	}
	m.status = "listed"
	if m.n == 0 {
		m.emit(markerEmpty + m.path)
	}
	m.loadPreview()
}

// tarPreview is the preview arm for an archive row: directories, links,
// refused and unsupported rows get an honest note; a file member streams
// to its offset and previews like any file (the view marker names it).
func (m *model) tarPreview(e vi.DirEntry, name string) {
	m.previewOf = name
	ent, ok := m.tarEntAt(m.sel)
	if !ok {
		m.preview = "(no member)"
		return
	}
	switch e.Reserved[0] {
	case tarClsDir:
		m.preview = "(directory — enter to open)"
	case tarClsLink:
		m.preview = "(symlink -> " + ent.link + " — not followed)"
	case tarClsRefused:
		m.preview = "(refused name — never resolves)"
	case tarClsOther:
		m.preview = "(unsupported entry)"
	default:
		body, rc := m.tar.readEnt(ent, maxPreviewBytes)
		if rc < 0 {
			m.preview = "read err " + vi.Itoa64(rc)
			return
		}
		m.preview = sanitizePreview(body)
		m.previewBig = int64(len(body)) >= maxPreviewBytes &&
			ent.size > uint64(len(body))
		if m.previewBig {
			m.preview += "\n… (first " + vi.Itoa64(int64(len(body))) + " of " +
				vi.Itoa64(int64(ent.size)) + " bytes)"
		}
		m.emit(markerView + name + " bytes=" + vi.Itoa64(int64(len(body))))
	}
}

// qlTar arms the QuickLook pane on an archive member: a file row streams
// to its offset (at most vi.MaxFileBytes) and answers the same
// image/text/card arms a real file would; directories, links, refused and
// unsupported rows card by class. The mtime is the member header's own
// stamp — no stat wire exists for a path inside an archive.
func (m *model) qlTar(ql *quickLook, e vi.DirEntry) {
	ql.kind = qlCard
	ql.path = m.path + e.NameString()
	ent, ok := m.tarEntAt(m.sel)
	if !ok {
		ql.typeName = "entry"
		return
	}
	ql.size = ent.size
	if ent.mt > 0 {
		ql.mtOK = true
		ql.mtSec = ent.mt
	}
	switch e.Reserved[0] {
	case tarClsDir:
		ql.typeName = "directory"
	case tarClsLink:
		ql.typeName = "symlink"
	case tarClsRefused:
		ql.typeName = "refused"
	case tarClsOther:
		ql.typeName = "unsupported"
	default:
		data, rc := m.tar.readEnt(ent, maxQuickBytes)
		var head []byte
		if rc >= 0 {
			head = data
		}
		id := mime.Sniff(ql.name, head)
		ql.typeName = id.String()
		switch {
		case rc < 0:
			// stays on the card
		case id == mime.Image && ql.armImage(data):
			// armImage set kind/dims/sixel
		case id == mime.Text:
			ql.kind = qlText
			ql.lines = quickLines(data)
		}
	}
}
