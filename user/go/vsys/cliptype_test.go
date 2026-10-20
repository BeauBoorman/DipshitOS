package vsys

import "testing"

// M124c (#2582): the typed clipboard's pure half. The kernel buffer stays
// raw bytes, so the contract being pinned here is the classification (the
// READING rule both the seat badge and the host lane share) and the
// declared-mime validation (the WRITE rule that keeps a label honest).
// The slot traffic itself is clipboard_test.go's already.

// The classify table: magic beats shape, shape beats plain, unclassifiable
// is octet-stream — never a guess.
func TestClipboardClassify(t *testing.T) {
	cases := []struct {
		body []byte
		want string
	}{
		{[]byte("hello"), ClipText},
		{[]byte(""), ClipText},
		{[]byte("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"), ClipPNG},
		{[]byte("qoif\x00\x00\x00\x10"), ClipQOI},
		{[]byte("GIF89a\x01\x00"), ClipGIF},
		{[]byte("\xff\xd8\xff\xe0JFIF"), ClipJPEG},
		{[]byte("BM\x00\x00"), ClipBMP},
		{[]byte("file:///host/NOTES.TXT"), ClipURIList},
		{[]byte("file:///a\nfile:///b\n"), ClipURIList},
		{[]byte("https://x.invalid/y"), ClipURIList},
		{[]byte("<html><body>hi</body></html>"), ClipHTML},
		{[]byte("<!DOCTYPE html><p>x</p>"), ClipHTML},
		{[]byte("<b>bold</b>"), ClipHTML},
		{[]byte("plain < prose"), ClipText},
		{[]byte("/host/NOTES.TXT"), ClipText},        // a bare path is text, not a URI
		{[]byte("see file:///a for details"), ClipText}, // URI inside prose is prose
		{[]byte("a,b\n1,2\n"), ClipText}, // csv bytes classify as plain text (M132b: no shape detection)
		{[]byte("\n\n"), ClipText},
		{[]byte{0xff, 0xfe, 'n'}, ClipOctet},
		{[]byte{0x89, 'P', 'N', 'G'}, ClipOctet}, // near-magic is not magic
	}
	for _, c := range cases {
		if got := ClipboardClassify(c.body); got != c.want {
			t.Fatalf("ClipboardClassify(%q) = %q want %q", c.body, got, c.want)
		}
	}
}

// The spelling rule: type/subtype, one slash, the URI-safe alphabet,
// inside ClipMimeMax.
func TestClipSpellingOK(t *testing.T) {
	for _, ok := range []string{
		"text/plain", "text/uri-list", "text/html", "text/csv", "image/png",
		"application/octet-stream", "image/svg+xml",
	} {
		if !ClipSpellingOK(ok) {
			t.Fatalf("ClipSpellingOK(%q) = false want true", ok)
		}
	}
	for _, bad := range []string{
		"", "textplain", "text/", "/plain", "text/a/b", "TEXT/PLAIN",
		"text plain", "text_pl", "text/plain;x", "a/" + string(make([]byte, 0)),
		"text/plain-longer-than-24chars",
	} {
		if ClipSpellingOK(bad) {
			t.Fatalf("ClipSpellingOK(%q) = true want false", bad)
		}
	}
}

// Shape is the honesty check: the declared mime must be a thing the bytes
// can BE. A PNG-labelled text body and a text-labelled PNG are both
// refusals — the drag arm's "label never lies about the bytes" rule.
func TestClipShapeOK(t *testing.T) {
	png := []byte("\x89PNG\r\n\x1a\nrest")
	if !ClipShapeOK(ClipPNG, png) {
		t.Fatal("png bytes refused as image/png")
	}
	if ClipShapeOK(ClipPNG, []byte("not a png")) {
		t.Fatal("text accepted as image/png")
	}
	if ClipShapeOK(ClipText, png) {
		t.Fatal("png bytes accepted as text/plain")
	}
	if !ClipShapeOK(ClipURIList, []byte("file:///a\n")) {
		t.Fatal("uri-list shape refused")
	}
	if ClipShapeOK(ClipURIList, []byte("file:///a is nice")) {
		t.Fatal("prose with a URI token accepted as uri-list")
	}
	if !ClipShapeOK(ClipCSV, []byte("a,b\n1,2\n")) {
		t.Fatal("csv body refused as text/csv")
	}
	if ClipShapeOK(ClipCSV, png) {
		t.Fatal("png bytes accepted as text/csv")
	}
	if !ClipShapeOK(ClipHTML, []byte("<html><body>x</body></html>")) {
		t.Fatal("html shape refused")
	}
	if ClipShapeOK(ClipHTML, []byte("a < b and c > d")) {
		t.Fatal("prose with angle brackets accepted as html")
	}
	if !ClipShapeOK(ClipOctet, []byte{0xff, 0x00}) {
		t.Fatal("octet-stream refused binary")
	}
	if ClipShapeOK("video/mp4", []byte("x")) {
		t.Fatal("out-of-vocabulary mime accepted")
	}
}

// ClipboardSetTyped: the validation failures are (0, -EINVAL) before any
// syscall; a valid pair stores the blob raw through slot 38.
func TestClipboardSetTyped(t *testing.T) {
	png := []byte("\x89PNG\r\n\x1a\nbody")

	// Refusals never reach the kernel: no slot traffic on a bad mime, a
	// shape lie, or an over-bound blob.
	called := false
	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		called = true
		return 0
	})
	if n, rc := ClipboardSetTyped("bogus", png); n != 0 || rc != -ErrEINVAL || called {
		t.Fatalf("bad spelling = (%d,%d) called=%v", n, rc, called)
	}
	if n, rc := ClipboardSetTyped(ClipPNG, []byte("text")); n != 0 || rc != -ErrEINVAL || called {
		t.Fatalf("shape lie = (%d,%d) called=%v", n, rc, called)
	}
	if n, rc := ClipboardSetTyped(ClipText, make([]byte, ClipKernelMax+1)); n != 0 || rc != -ErrEINVAL || called {
		t.Fatalf("over-bound = (%d,%d) called=%v", n, rc, called)
	}

	// A valid pair stores the blob raw — the kernel buffer IS the store.
	var gotLen uintptr
	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotLen = a1
		return int64(a1)
	})
	n, rc := ClipboardSetTyped(ClipPNG, png)
	if gotLen != uintptr(len(png)) || n != len(png) || rc < 0 {
		t.Fatalf("typed set = len %d (%d,%d)", gotLen, n, rc)
	}
}

// ClipboardGetTyped: the mime is read off the bytes the kernel handed
// back — a buffer that was SET untyped still classifies on the way out.
// The host seam cannot do uaccess, so buf is pre-filled the way the
// kernel's copy_out would leave it and the fake returns the count.
func TestClipboardGetTyped(t *testing.T) {
	png := []byte("\x89PNG\r\n\x1a\nbody")
	var buf [64]byte
	copy(buf[:], png)
	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		return int64(len(png))
	})
	mime, n, rc := ClipboardGetTyped(buf[:])
	if n != len(png) || rc < 0 {
		t.Fatalf("get typed = (%d,%d)", n, rc)
	}
	if mime != ClipPNG {
		t.Fatalf("classified %q want %q", mime, ClipPNG)
	}

	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return 0 })
	if mime, n, rc = ClipboardGetTyped(buf[:]); mime != "" || n != 0 || rc != 0 {
		t.Fatalf("empty = (%q,%d,%d)", mime, n, rc)
	}
	fakeKernel(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return -ErrEACCES })
	if mime, n, rc = ClipboardGetTyped(buf[:]); mime != "" || n != 0 || rc != -ErrEACCES {
		t.Fatalf("refused = (%q,%d,%d)", mime, n, rc)
	}
}
