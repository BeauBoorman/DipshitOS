package main

// cache_test.go — the class-A half of M193a: the corpus codecs, the
// named bounds + LRU, substring search, and the offline legs — all over
// a map-backed share, no syscalls.

import "testing"

// fakeCacheHost is the map-backed share seam.
type fakeCacheHost struct {
	dir   string
	files map[string][]byte
}

func (f *fakeCacheHost) CacheDir() string             { return f.dir }
func (f *fakeCacheHost) MkdirShare(path string) error { return nil }
func (f *fakeCacheHost) ReadShare(path string, max int) ([]byte, bool) {
	b, ok := f.files[path]
	return b, ok
}
func (f *fakeCacheHost) WriteShare(path string, b []byte) error {
	f.files[path] = append([]byte(nil), b...)
	return nil
}

// swapCache installs the fake share and a deterministic LRU clock.
func swapCache(t *testing.T) *fakeCacheHost {
	t.Helper()
	f := &fakeCacheHost{dir: "/host/MAIL", files: map[string][]byte{}}
	oldH, oldClock := cacheH, cacheClock
	var tick int64
	cacheH = f
	cacheClock = func() int64 { tick++; return tick }
	t.Cleanup(func() { cacheH, cacheClock = oldH, oldClock })
	return f
}

func (f *fakeCacheHost) put(name, body string) {
	f.files[f.dir+"/"+name] = []byte(body)
}

func (f *fakeCacheHost) get(name string) string {
	return string(f.files[f.dir+"/"+name])
}

func hdrRow(seq int, from, subject string) Header {
	return Header{Seq: seq, From: from, Subject: subject, Date: "d"}
}

func TestHdrsCodecAndCaps(t *testing.T) {
	f := swapCache(t)
	cacheSaveHdrs("INBOX", []Header{hdrRow(1, "Alice", "gate hello"), hdrRow(2, "bob@f", "html issue")})
	cacheSaveHdrs("Sent", []Header{hdrRow(1, "me", "sent one")})

	rows := cacheHdrsFor("INBOX")
	if len(rows) != 2 || rows[0].from != "Alice" || rows[1].subject != "html issue" {
		t.Fatalf("INBOX rows %+v", rows)
	}
	if rows := cacheHdrsFor("Sent"); len(rows) != 1 || rows[0].subject != "sent one" {
		t.Fatalf("Sent rows %+v", rows)
	}
	// A second save of the same box replaces its rows, not appends.
	cacheSaveHdrs("INBOX", []Header{hdrRow(5, "Carol", "new window")})
	if rows := cacheHdrsFor("INBOX"); len(rows) != 1 || rows[0].seq != 5 {
		t.Fatalf("replaced rows %+v", rows)
	}
	if rows := cacheHdrsFor("Sent"); len(rows) != 1 {
		t.Fatal("other box lost")
	}
	// Per-box cap: the newest cacheHdrPerBox rows survive.
	var many []Header
	for i := 1; i <= cacheHdrPerBox+10; i++ {
		many = append(many, hdrRow(i, "x", "s"))
	}
	cacheSaveHdrs("Lists", many)
	rows = cacheHdrsFor("Lists")
	if len(rows) != cacheHdrPerBox || rows[0].seq != 11 {
		t.Fatalf("per-box cap kept %d rows first=%d", len(rows), rows[0].seq)
	}
	_ = f
}

func TestBodiesCodecAndLRU(t *testing.T) {
	f := swapCache(t)
	// A payload that LOOKS like a record head must not tear the codec.
	evil := []byte("body\n@INBOX\t9\t9\ttext/plain\t5\nxxxxx\nmore")
	cachePutBody("INBOX", 1, "text/plain", evil)
	recs := parseBodies([]byte(f.get("BODIES")))
	if len(recs) != 1 || string(recs[0].data) != string(evil) {
		t.Fatalf("payload roundtrip %+v", recs)
	}
	// Same (box, seq) replaces rather than duplicating.
	cachePutBody("INBOX", 1, "text/plain", []byte("v2"))
	recs = parseBodies([]byte(f.get("BODIES")))
	if len(recs) != 1 || string(recs[0].data) != "v2" {
		t.Fatalf("replace kept %+v", recs)
	}
	// Per-box N: the N+1th body evicts the least-recently-USED one.
	for i := 1; i <= cacheBodiesBox; i++ {
		cachePutBody("B", i, "text/plain", []byte{byte('a' + i)})
	}
	// Touch seq 1 so seq 2 becomes the LRU victim.
	if _, ok := cacheGetBody("B", 1); !ok {
		t.Fatal("get B/1 missed")
	}
	cachePutBody("B", 99, "text/plain", []byte("z"))
	recs = parseBodies([]byte(f.get("BODIES")))
	var seqs []int
	inBox := 0
	for _, r := range recs {
		if r.box == "B" {
			inBox++
			seqs = append(seqs, r.seq)
		}
	}
	if inBox != cacheBodiesBox {
		t.Fatalf("box bound kept %d", inBox)
	}
	for _, s := range seqs {
		if s == 2 {
			t.Fatalf("LRU victim survived: %v", seqs)
		}
	}
	// The global byte cap evicts LRU across boxes: one giant body
	// forces smaller older ones out.
	f.files = map[string][]byte{}
	cachePutBody("B", 1, "text/plain", make([]byte, cacheBytesMax/2))
	cachePutBody("B", 2, "text/plain", make([]byte, cacheBytesMax/2))
	cachePutBody("B", 3, "text/plain", []byte("small"))
	recs = parseBodies([]byte(f.get("BODIES")))
	total := 0
	for _, r := range recs {
		total += len(r.data)
	}
	if total > cacheBytesMax || len(recs) != 2 {
		t.Fatalf("byte cap: %d recs %d bytes", len(recs), total)
	}
	if _, ok := cacheGetBody("B", 1); ok {
		t.Fatal("evicted body still served")
	}
	if _, ok := cacheGetBody("B", 3); !ok {
		t.Fatal("newest body evicted")
	}
}

func TestCacheSearch(t *testing.T) {
	f := swapCache(t)
	f.put("HDRS", "INBOX\t1\tAlice\tgate hello\tWed\n"+
		"INBOX\t2\tbob@f\thtml issue\tWed\n"+
		"Lists\t7\tdana@fixture.local\tweekly digest\tWed\n")
	f.put("BODIES", "@Lists\t9\t1\ttext/html\t13\n<body>orchid\n")

	hits := cacheSearch("gate")
	if len(hits) != 1 || hits[0].box != "INBOX" || hits[0].seq != 1 || !hits[0].haveHdr || hits[0].bodyOnly {
		t.Fatalf("hdr hit %+v", hits)
	}
	// Case folds; a from-field match is an envelope hit too.
	hits = cacheSearch("WEEKLY")
	if len(hits) != 1 || hits[0].seq != 7 {
		t.Fatalf("fold hit %+v", hits)
	}
	hits = cacheSearch("DANA@FIXTURE")
	if len(hits) != 1 {
		t.Fatalf("from hit %+v", hits)
	}
	// Body-only hit with no envelope still names the ref.
	hits = cacheSearch("orchid")
	if len(hits) != 1 || hits[0].box != "Lists" || hits[0].seq != 9 || !hits[0].bodyOnly || hits[0].haveHdr {
		t.Fatalf("body hit %+v", hits)
	}
	// A message matching in BOTH places reports once, as an envelope.
	f.put("BODIES", "@INBOX\t1\t1\ttext/plain\t10\ngate hello\n")
	hits = cacheSearch("gate")
	if len(hits) != 1 || hits[0].bodyOnly {
		t.Fatalf("dedupe hit %+v", hits)
	}
	// Body hit joined to its envelope keeps the header line.
	f.put("BODIES", "@INBOX\t2\t1\ttext/plain\t5\nzzzzq\n")
	hits = cacheSearch("zzzzq")
	if len(hits) != 1 || !hits[0].bodyOnly || !hits[0].haveHdr || hits[0].from != "bob@f" {
		t.Fatalf("joined hit %+v", hits)
	}
	if hits := cacheSearch("nothing-like-this"); len(hits) != 0 {
		t.Fatalf("miss hit %+v", hits)
	}
}

func TestOfflineLegs(t *testing.T) {
	f := swapCache(t)
	f.put("BOXES", "INBOX\nSent\n")
	f.put("HDRS", "INBOX\t1\tAlice\tgate hello\tWed\n")
	f.put("BODIES", "@INBOX\t1\t1\ttext/plain\t4\nbody\n")

	if err := offlineBoxes(); err != nil {
		t.Fatalf("offlineBoxes %v", err)
	}
	if err := offlineHeaders("INBOX"); err != nil {
		t.Fatalf("offlineHeaders %v", err)
	}
	if err := offlineHeaders("Nope"); err == nil || err.Error() != "gomail: cache-miss Nope" {
		t.Fatalf("offlineHeaders miss %v", err)
	}
	if err := offlineRead("INBOX", 1); err != nil {
		t.Fatalf("offlineRead hit %v", err)
	}
	if err := offlineRead("INBOX", 9); err == nil || err.Error() != "gomail: cache-miss INBOX 9" {
		t.Fatalf("offlineRead miss %v", err)
	}
	if err := offlineFetch("INBOX", []int{1}); err != nil {
		t.Fatalf("offlineFetch %v", err)
	}
	if err := offlineFetch("INBOX", []int{1, 9}); err == nil ||
		err.Error() != "gomail: cache-miss INBOX 9" {
		t.Fatalf("offlineFetch miss %v", err)
	}
	// An empty cache names itself rather than painting nothing.
	f.files = map[string][]byte{}
	if err := offlineBoxes(); err == nil || err.Error() != "gomail: cache-miss boxes" {
		t.Fatalf("empty offlineBoxes %v", err)
	}
}

func TestOfflineOr(t *testing.T) {
	// A dead transport routes to the cache leg; named refusals pass.
	var ran bool
	leg := func() error { ran = true; return nil }
	if err := offlineOr(dialError{mailError{"dial dead"}}, leg); err != nil || !ran {
		t.Fatalf("dialError routed err=%v ran=%v", err, ran)
	}
	ran = false
	refused := protoErr("refuse plaintext", "")
	if err := offlineOr(refused, leg); err != refused || ran {
		t.Fatalf("refusal passed err=%v ran=%v", err, ran)
	}
}
