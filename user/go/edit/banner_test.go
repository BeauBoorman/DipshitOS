package main

import (
	"testing"

	"virelai/appkit"
	"virelai/vi"
)

// banner_test.go pins the M123d (#2578) wiring: which failures raise the
// shared strip, the markers' literal shapes (the go-edit gate greps them),
// the keyboard/mouse ownership while it stands, and the Copy Error arm's
// clipboard seam.

// swapClip substitutes the slot-38 write seam and hands back what the Copy
// Error arm published.
func swapClip(t *testing.T, rc int64) *[]byte {
	t.Helper()
	var got []byte
	old := clipWrite
	clipWrite = func(p []byte) (int, int64) {
		got = append([]byte{}, p...)
		return len(p), rc
	}
	t.Cleanup(func() { clipWrite = old })
	return &got
}

func TestBannerMarkerShapes(t *testing.T) {
	if markerBanner != "goedit: banner " || markerBannerAct != "goedit: banner act " {
		t.Fatalf("banner markers drifted: %q / %q", markerBanner, markerBannerAct)
	}
}

// The create path: a plain missing file (ENOENT) is the empty-buffer answer,
// never a banner. Every other refusal is the failure the strip exists for.
func TestLoadRefusalRaisesBanner(t *testing.T) {
	old := bufRead
	t.Cleanup(func() { bufRead = old })

	bufRead = func(string, int) ([]byte, int64) { return nil, -vi.ErrENOENT }
	e := usEditor("")
	e.path = "/host/EDIT/FRESH.TXT"
	e.load()
	if e.banner.Open {
		t.Fatal("a missing file is the create path, not a banner")
	}

	bufRead = func(string, int) ([]byte, int64) { return nil, -int64(1) } // EINVAL: a directory
	e = usEditor("")
	e.path = "/host/EDIT"
	e.load()
	if !e.banner.Open {
		t.Fatal("a refused open must raise the banner")
	}
	if e.banner.Text != "open /host/EDIT failed rc=-1" {
		t.Fatalf("banner text = %q", e.banner.Text)
	}
	if !e.bannerFresh {
		t.Fatal("the raise must latch bannerFresh for the post-paint marker")
	}
	e.bannerFlush()
	if e.bannerFresh {
		t.Fatal("flush must clear the latch")
	}
}

// A save refused by a live foreign lease raises the strip — the same refusal
// the save-error marker reports, now standing inline.
func TestSaveRefusalRaisesBanner(t *testing.T) {
	const target = "/host/EDIT/SEED.TXT"
	k := installEditKernel(t, 1000)
	k.files[vi.LeasePathFor(target)] = []byte(
		"VLEASE1\npid=0\nts=1000\ntoken=0102030405060708\npath=" + target + "\n")
	e := &editor{doc: doc{path: target, buf: []byte("XYZ"), dirty: true}}
	if e.save() {
		t.Fatal("save must refuse under a live lease")
	}
	if !e.banner.Open {
		t.Fatal("a refused save must raise the banner")
	}
	if e.banner.Text != "save "+target+" refused rc=-11" {
		t.Fatalf("banner text = %q", e.banner.Text)
	}
}

// While the strip stands it owns the keyboard outright: letters never reach
// the document, and the resolution vocabulary is the appkit one — c copies
// the text through the slot-38 seam, Escape dismisses.
func TestBannerOwnsKeysAndCopies(t *testing.T) {
	got := swapClip(t, 0)
	e := usEditor("seed")
	e.raiseBanner("open /x failed rc=-1")

	// A letter key is the strip's, never an insert.
	if !e.key(usDown(0x2c, 0, 'z')) || string(e.buf) != "seed" {
		t.Fatal("a key under the banner must not type into the document")
	}
	// c is Copy Error: the seam sees exactly the strip's text.
	e.key(usDown(0x06, 0, 'c'))
	if e.banner.Open {
		t.Fatal("the banner must close on a choice")
	}
	if string(*got) != "open /x failed rc=-1" {
		t.Fatalf("copied = %q", string(*got))
	}
}

// Escape resolves to dismiss; a refused copy reports the seam's code on the
// act marker (the M97g-F4 boundary — unprivileged editors get -EACCES).
func TestBannerDismissAndRefusedCopy(t *testing.T) {
	e := usEditor("seed")
	e.raiseBanner("save /x refused rc=-11")
	e.key(usDown(usageEsc, 0, codeEscape))
	if e.banner.Open || e.banner.Choice != "" {
		t.Fatalf("dismiss must close the strip and consume the choice: open=%v choice=%q",
			e.banner.Open, e.banner.Choice)
	}

	got := swapClip(t, -vi.ErrEACCES)
	e.raiseBanner("save /x refused rc=-11")
	e.key(usDown(0x06, 0, 'c'))
	if e.banner.Open {
		t.Fatal("a refused copy still resolves the banner")
	}
	if len(*got) == 0 {
		t.Fatal("the copy arm must attempt the clipboard write")
	}
}

// A press inside the strip is consumed; a press outside is not the banner's.
func TestBannerPress(t *testing.T) {
	e := usEditor("seed")
	e.raiseBanner("open /x failed rc=-1")
	r := e.bannerRect()
	if e.bannerPress(r.Right()+1, r.Y+1) {
		t.Fatal("a click outside the strip is not the banner's")
	}
	if !e.bannerPress(r.X+2, r.Y+r.H/2) {
		t.Fatal("a click inside the strip is consumed")
	}
	if !e.banner.Open {
		t.Fatal("a bare-plate press swallows without resolving")
	}
}

// The strip paints through the window canvas in the guest; host-side the
// raise is what the draw gate needs — R sits on the document band under the
// chrome row.
func TestBannerRect(t *testing.T) {
	e := usEditor("")
	r := e.bannerRect()
	if r.X != 0 || r.Y != chromeH || r.H != appkit.BannerHeight() || r.W != natW {
		t.Fatalf("banner rect = %+v", r)
	}
}
