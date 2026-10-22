package main

// M167c (issue #2993): the tar browser's class-A pins. Fixture archives
// are built in the test — no tar is committed: plain ustar, a pax long
// path, a GNU long name, a bad checksum, truncation, `..`/absolute/empty
// names, a symlink, the entry and stream bounds, a small .tgz, an
// oversized .tgz, the read-only refusals, and QuickLook on a text and an
// image member.

import (
	"strings"
	"testing"

	"virelai/flate"
	"virelai/rss/keys"
)

// putOctal writes a NUL-terminated octal field (the POSIX layout).
func putOctal(b []byte, v int64) {
	s := ""
	if v == 0 {
		s = "0"
	}
	for v > 0 {
		s = string(rune('0'+v&7)) + s
		v >>= 3
	}
	for len(s) < len(b)-1 {
		s = "0" + s
	}
	copy(b, s)
	b[len(b)-1] = 0
}

// tarHdr assembles one 512-byte header with a computed checksum.
func tarHdr(name, link, prefix string, size, mt int64, flag byte) []byte {
	h := make([]byte, 512)
	copy(h[0:100], name)
	putOctal(h[100:108], 0o644)
	putOctal(h[108:116], 0)
	putOctal(h[116:124], 0)
	putOctal(h[124:136], size)
	putOctal(h[136:148], mt)
	for i := 148; i < 156; i++ {
		h[i] = ' '
	}
	h[156] = flag
	copy(h[157:257], link)
	copy(h[257:263], "ustar\x00")
	copy(h[263:265], "00")
	copy(h[345:500], prefix)
	var sum int64
	for _, b := range h {
		sum += int64(b)
	}
	putOctal(h[148:156], sum)
	return h
}

func tarPad(b []byte) []byte {
	pad := (len(b) + 511) / 512 * 512
	return append(b, make([]byte, pad-len(b))...)
}

func tarFile(name string, body []byte, mt int64) []byte {
	out := tarHdr(name, "", "", int64(len(body)), mt, '0')
	return append(out, tarPad(body)...)
}

func tarDirE(name string) []byte { return tarHdr(name+"/", "", "", 0, 1700000000, '5') }

func tarLinkE(name, target string) []byte {
	return tarHdr(name, target, "", 0, 1700000000, '2')
}

// paxRec renders one "len key=val\n" record (len includes itself).
func paxRec(key, val string) []byte {
	base := len(key) + len(val) + 2 // " " + "=" ... "\n" counted below
	l := base + 1
	for {
		s := itoa(int64(l)) + " " + key + "=" + val + "\n"
		if len(s) == l {
			return []byte(s)
		}
		l = len(s)
	}
}

func tarXrec(body []byte) []byte {
	out := tarHdr("PAX.TMP", "", "", int64(len(body)), 0, 'x')
	return append(out, tarPad(body)...)
}

func tarFixture(parts ...[]byte) []byte {
	var out []byte
	for _, p := range parts {
		out = append(out, p...)
	}
	return append(out, make([]byte, 1024)...)
}

// tarBacker points the tarOpenSrc seam at a fixture table.
func tarBacker(t *testing.T, files map[string][]byte) {
	t.Helper()
	prev := tarOpenSrc
	tarOpenSrc = func(path string) (tarSrc, int64) {
		if b, ok := files[path]; ok {
			return &memTarSrc{buf: b}, 0
		}
		return nil, -2
	}
	t.Cleanup(func() { tarOpenSrc = prev })
}

// enterTarFixture builds a model whose single entry is an archive backed
// by fixture, and opens it.
func enterTarFixture(t *testing.T, fixture []byte) model {
	t.Helper()
	tarBacker(t, map[string][]byte{"/host/FM/SAMPLE.TAR": fixture})
	m := testModel(entry("SAMPLE.TAR", false))
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	return m
}

func TestTarOpenBrowseLeave(t *testing.T) {
	fix := tarFixture(
		tarDirE("DEEP"),
		tarFile("INNER.TXT", []byte("tar-inner-line\ntwo\n"), 1700000000),
		tarFile("PIC.QOI", qoi(4, 4, 255, 0, 0), 1700000000),
	)
	m := enterTarFixture(t, fix)
	got := pendingJoined(&m)
	for _, want := range []string{
		"gofiles: tar open SAMPLE.TAR entries=3 bytes=",
		"gofiles: list /host/FM/SAMPLE.TAR/ n=3",
		"gofiles: entry DEEP dir",
		"gofiles: entry INNER.TXT file",
		"gofiles: entry PIC.QOI file",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("missing %q in markers:\n%s", want, got)
		}
	}
	if m.path != "/host/FM/SAMPLE.TAR/" {
		t.Fatalf("path bar = %q", m.path)
	}
	// Rows sort dirs-first: DEEP/, INNER.TXT, PIC.QOI. Enter descends.
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	if m.tarSub != "DEEP/" || m.n != 0 {
		t.Fatalf("descend into DEEP: sub=%q n=%d", m.tarSub, m.n)
	}
	if got := pendingJoined(&m); !strings.Contains(got, "empty /host/FM/SAMPLE.TAR/DEEP/") {
		t.Fatalf("empty subdir marker missing: %q", got)
	}
	// h ascends inside, h at root leaves back to the real listing.
	m.handleKey(runeKey('h'))
	if m.tarSub != "" || m.path != "/host/FM/SAMPLE.TAR/" {
		t.Fatalf("ascend: sub=%q path=%q", m.tarSub, m.path)
	}
	m.handleKey(runeKey('h'))
	got = pendingJoined(&m)
	if m.tar != nil || m.path != "/host/FM" {
		t.Fatalf("h at root must leave: tar=%v path=%q", m.tar != nil, m.path)
	}
	if !strings.Contains(got, "gofiles: tar close SAMPLE.TAR") ||
		!strings.Contains(got, "gofiles: cd /host/FM") {
		t.Fatalf("leave markers missing: %q", got)
	}
}

func TestTarPaxAndGnuLongNames(t *testing.T) {
	long := "deep/" + strings.Repeat("a", 110) + ".txt" // >100 chars
	gnu := strings.Repeat("g", 90) + ".txt"
	body := append(paxRec("path", long), paxRec("size", "5")...)
	fix := tarFixture(
		append(tarXrec(body), tarHdr("short", "", "", 5, 0, '0')...), // pax overrides path+size
		tarPad([]byte("hello")),
		append(tarHdr("L", "", "", int64(len(gnu)), 0, 'L'), tarPad([]byte(gnu))...),
		tarFileTail("stub.txt", "x"),
	)
	ents, _, refuse := tarParse(&memTarSrc{buf: fix})
	if refuse != "" {
		t.Fatalf("pax+gnu fixture refused: %s", refuse)
	}
	if len(ents) != 2 || ents[0].name != long || ents[1].name != gnu {
		t.Fatalf("names = %#v", ents)
	}
	if ents[0].size != 5 {
		t.Fatalf("pax size override = %d, want 5", ents[0].size)
	}
}

// tarFileTail is tarFile without the trailing zeros (callers compose).
func tarFileTail(name, body string) []byte {
	return tarFile(name, []byte(body), 1700000000)
}

func TestTarRefusedShapes(t *testing.T) {
	good := tarFixture(tarFileTail("A.TXT", "a"))
	// Bad checksum: corrupt one name byte after the sum was computed.
	bad := append([]byte(nil), good...)
	bad[0] = 'Z'
	// Truncated: cut mid-member-data.
	trunc := good[:512+1]
	// Malformed: a non-octal size field.
	malf := append([]byte(nil), good...)
	malf[124] = 'x'
	malf[125] = '!'
	malf[126] = '!'
	malf[127] = '!'
	malf[128] = ' '
	// recompute checksum so ONLY the octal parse can refuse
	for i := 148; i < 156; i++ {
		malf[i] = ' '
	}
	var sum int64
	for _, b := range malf[:512] {
		sum += int64(b)
	}
	putOctal(malf[148:156], sum)
	cases := []struct {
		name   string
		fix    []byte
		reason string
	}{
		{"checksum", bad, "checksum"},
		{"truncated", trunc, "truncated"},
		{"malformed", malf, "malformed"},
		{"empty", nil, "truncated"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := enterTarFixture(t, c.fix)
			got := pendingJoined(&m)
			if !strings.Contains(got, "gofiles: tar refused SAMPLE.TAR "+c.reason) {
				t.Fatalf("%s refusal missing: %q", c.reason, got)
			}
			if m.tar != nil {
				t.Fatalf("%s must not open the archive", c.reason)
			}
		})
	}
}

func TestTarTraversalAndLinkRows(t *testing.T) {
	fix := tarFixture(
		tarHdr("../EVIL.TXT", "", "", 3, 0, '0'),
		tarPad([]byte("bad")),
		tarHdr("/ABS.TXT", "", "", 2, 0, '0'),
		tarPad([]byte("ab")),
		tarHdr("", "", "", 0, 0, '0'),
		tarLinkE("LNK.TXT", "INNER.TXT"),
		tarFileTail("OK.TXT", "ok"),
	)
	m := enterTarFixture(t, fix)
	got := pendingJoined(&m)
	for _, want := range []string{
		"gofiles: tar open SAMPLE.TAR entries=5",
		"gofiles: entry ../EVIL.TXT refused",
		"gofiles: entry /ABS.TXT refused",
		"gofiles: entry LNK.TXT link",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("missing %q:\n%s", want, got)
		}
	}
	// The refused rows never resolve: Enter on them is a read-only open
	// refusal, never a cd. Find the ../EVIL.TXT row and press Enter.
	for i := 0; i < m.n; i++ {
		if m.entries[i].NameString() == "../EVIL.TXT" {
			m.sel = i
		}
	}
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	got = pendingJoined(&m)
	if !strings.Contains(got, "gofiles: tar read-only open") {
		t.Fatalf("refused-row open must be read-only refused: %q", got)
	}
	if m.tarSub != "" {
		t.Fatal("a refused name must never resolve into a subdir")
	}
	// The link row lists but is never followed: same refusal.
	for i := 0; i < m.n; i++ {
		if m.entries[i].NameString() == "LNK.TXT" {
			m.sel = i
		}
	}
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	got = pendingJoined(&m)
	if !strings.Contains(got, "gofiles: tar read-only open") {
		t.Fatalf("link-row open must refuse: %q", got)
	}
	if !strings.Contains(m.render(), "LNK.TXT -> INNER.TXT") {
		t.Fatal("the link row must spell its unfollowed target")
	}
}

func TestTarEntryBound(t *testing.T) {
	// 513 zero-length members cross the 512-entry bound mid-scan.
	var parts [][]byte
	for i := 0; i < 513; i++ {
		parts = append(parts, tarHdr("F"+itoa(int64(i)), "", "", 0, 0, '0'))
	}
	m := enterTarFixture(t, tarFixture(parts...))
	if got := pendingJoined(&m); !strings.Contains(got, "gofiles: tar refused SAMPLE.TAR entries") {
		t.Fatalf("entries bound refusal missing: %q", got)
	}
}

// genTarSrc streams a synthesized archive without holding it: hdr+data
// per file, endlessly regenerating. The stream bound fires before the
// fixture's nominal end.
type genTarSrc struct {
	left  int // headers still to emit
	fsize int64
	hdr   []byte
	at    int
	data  int64 // zero data bytes still owed for the current member
}

func (s *genTarSrc) read(dst []byte) (int, int64) {
	n := 0
	for n < len(dst) {
		switch {
		case len(s.hdr) > 0:
			k := copy(dst[n:], s.hdr[s.at:])
			s.at += k
			n += k
			if s.at == len(s.hdr) {
				s.hdr = nil
				s.data = s.fsize
			}
		case s.data > 0:
			take := int64(len(dst) - n)
			if take > s.data {
				take = s.data
			}
			// dst is caller scratch — write zeros explicitly
			for i := n; i < n+int(take); i++ {
				dst[i] = 0
			}
			n += int(take)
			s.data -= take
		case s.left > 0:
			s.left--
			s.hdr = tarHdr("B"+itoa(int64(s.left)), "", "", s.fsize, 0, '0')
			s.at = 0
		default:
			// end of archive: zero blocks
			for i := n; i < len(dst); i++ {
				dst[i] = 0
			}
			return len(dst), int64(len(dst))
		}
	}
	return n, int64(n)
}
func (s *genTarSrc) close() {}

func TestTarStreamBound(t *testing.T) {
	// Nine 8 MiB members: entries bound untouched, the 64 MiB stream
	// bound crossed during data skips.
	prev := tarOpenSrc
	tarOpenSrc = func(string) (tarSrc, int64) {
		return &genTarSrc{left: 9, fsize: 8 << 20}, 0
	}
	t.Cleanup(func() { tarOpenSrc = prev })
	m := testModel(entry("SAMPLE.TAR", false))
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	if got := pendingJoined(&m); !strings.Contains(got, "gofiles: tar refused SAMPLE.TAR stream") {
		t.Fatalf("stream bound refusal missing: %q", got)
	}
}

func TestTarGzipBounds(t *testing.T) {
	inner := tarFixture(tarFileTail("A.TXT", "alpha\n"))
	comp := flate.CompressZlib(inner)
	deflate := comp[2 : len(comp)-4] // strip the zlib wrapper
	gz := append([]byte{0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff}, deflate...)
	var crc uint32 = 0xffffffff
	for _, b := range inner {
		crc ^= uint32(b)
		for j := 0; j < 8; j++ {
			if crc&1 != 0 {
				crc = 0xedb88320 ^ (crc >> 1)
			} else {
				crc >>= 1
			}
		}
	}
	crc = ^crc
	for i := 0; i < 4; i++ {
		gz = append(gz, byte(crc>>(8*i)))
	}
	for i := 0; i < 4; i++ {
		gz = append(gz, byte(uint32(len(inner))>>(8*i)))
	}
	tarBacker(t, map[string][]byte{"/host/FM/S.TGZ": gz})
	m := testModel(entry("S.TGZ", false))
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	got := pendingJoined(&m)
	if !strings.Contains(got, "gofiles: tar open S.TGZ entries=1") {
		t.Fatalf("tgz did not open: %q", got)
	}
	if m.tar == nil || m.tar.img == nil {
		t.Fatal("the tgz image must be held for the session")
	}

	// Compressed bound: the dir row's own size says >256 KiB — refused
	// before a byte is read.
	e := entry("BIG.TGZ", false)
	e.Size = tgzMaxComp + 1
	m = testModel(e)
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	got = pendingJoined(&m)
	if !strings.Contains(got, "gofiles: tar refused BIG.TGZ compressed") {
		t.Fatalf("compressed bound missing: %q", got)
	}

	// Inflated bound: a tiny compressed stream decoding to >2 MiB.
	big := make([]byte, tgzMaxInflate+1)
	bz := flate.CompressZlib(big)
	bdef := bz[2 : len(bz)-4]
	bgz := append([]byte{0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff}, bdef...)
	var bcrc uint32 = 0xffffffff
	for _, b := range big {
		bcrc ^= uint32(b)
		for j := 0; j < 8; j++ {
			if bcrc&1 != 0 {
				bcrc = 0xedb88320 ^ (bcrc >> 1)
			} else {
				bcrc >>= 1
			}
		}
	}
	bcrc = ^bcrc
	for i := 0; i < 4; i++ {
		bgz = append(bgz, byte(bcrc>>(8*i)))
	}
	for i := 0; i < 4; i++ {
		bgz = append(bgz, byte(uint32(len(big)))>>(8*i))
	}
	_ = bcrc
	tarBacker(t, map[string][]byte{"/host/FM/WIDE.TGZ": bgz})
	e = entry("WIDE.TGZ", false)
	e.Size = uint32(len(bgz))
	m = testModel(e)
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	got = pendingJoined(&m)
	if !strings.Contains(got, "gofiles: tar refused WIDE.TGZ inflated") {
		t.Fatalf("inflated bound missing: %q", got)
	}
}

func TestTarReadOnlyOps(t *testing.T) {
	fix := tarFixture(tarFileTail("A.TXT", "a\n"))
	m := enterTarFixture(t, fix)
	ops := []struct {
		key keys.Event
		op  string
	}{
		{runeKey('d'), "delete"},
		{runeKey('r'), "rename"},
		{runeKey('x'), "cut"},
		{runeKey('c'), "copy"},
		{runeKey('p'), "paste"},
		{runeKey('m'), "mark"},
		{runeKey('o'), "open-with"},
		{runeKey('e'), "export"},
		{runeKey('/'), "search"},
		{runeKey('b'), "pin"},
		{runeKey('t'), "grid"},
		{keys.Event{Key: keys.KeyEnter}, "open"},
	}
	for _, c := range ops {
		m.handleKey(c.key)
		if got := pendingJoined(&m); !strings.Contains(got, "gofiles: tar read-only "+c.op) {
			t.Fatalf("op %s missing read-only refusal: %q", c.op, got)
		}
	}
}

func TestTarQuickLookTextAndImage(t *testing.T) {
	var lines strings.Builder
	for i := 1; i <= 3; i++ {
		lines.WriteString("tar-line\n")
	}
	fix := tarFixture(
		tarFile("INNER.TXT", []byte(lines.String()), 1700000000),
		tarFile("PIC.QOI", qoi(4, 4, 0, 255, 0), 1700000000),
	)
	m := enterTarFixture(t, fix)
	m.handleKey(runeKey(' '))
	got := pendingJoined(&m)
	if m.ql.kind != qlText || len(m.ql.lines) != 3 {
		t.Fatalf("text arm: kind=%d lines=%d", m.ql.kind, len(m.ql.lines))
	}
	if !strings.Contains(got, "gofiles: quicklook INNER.TXT kind=text lines=3") {
		t.Fatalf("text quicklook marker missing: %q", got)
	}
	m.handleKey(runeKey(' '))
	// j onto PIC.QOI, space: the image arm decodes the member bytes.
	m.handleKey(runeKey('j'))
	m.handleKey(runeKey(' '))
	got = pendingJoined(&m)
	if m.ql.kind != qlImage {
		t.Fatalf("image arm: kind=%d", m.ql.kind)
	}
	if !strings.Contains(got, "gofiles: quicklook PIC.QOI kind=image 4x4") {
		t.Fatalf("image quicklook marker missing: %q", got)
	}
	// The member mtime is the header's own stamp, no stat wire.
	if !m.ql.mtOK || m.ql.mtSec != 1700000000 {
		t.Fatalf("member mtime = %d ok=%v", m.ql.mtSec, m.ql.mtOK)
	}
}

func TestTarPropsAndPreviewInside(t *testing.T) {
	fix := tarFixture(
		tarDirE("DEEP"),
		tarFile("INNER.TXT", []byte("inside\n"), 1700000000),
	)
	m := enterTarFixture(t, fix)
	// sel=0 is DEEP/; the preview is the dir note, `i` a directory card.
	if !strings.Contains(m.preview, "directory") {
		t.Fatalf("dir preview = %q", m.preview)
	}
	m.handleKey(runeKey('i'))
	got := pendingJoined(&m)
	if m.props.kind != "directory" {
		t.Fatalf("dir props kind = %q", m.props.kind)
	}
	if !strings.Contains(got, "files: props /host/FM/SAMPLE.TAR/DEEP") {
		t.Fatalf("props marker missing: %q", got)
	}
	m.handleKey(keys.Event{Key: keys.KeyEsc})
	// j onto INNER.TXT: preview shows member bytes, i a file card with
	// the header's own mtime.
	m.handleKey(runeKey('j'))
	if !strings.Contains(m.preview, "inside") {
		t.Fatalf("file preview = %q", m.preview)
	}
	m.handleKey(runeKey('i'))
	got = pendingJoined(&m)
	if !strings.Contains(got, "files: props /host/FM/SAMPLE.TAR/INNER.TXT mtime=1700000000 mime=text") {
		t.Fatalf("file props marker missing: %q", got)
	}
}
