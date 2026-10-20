package main

import (
	"strings"
	"testing"
)

// M126e (#2597): the download decision is pure — the gate's click lands on
// a .qoi link, and "save instead of navigate" is decided by the mime
// table's extension stage before a byte is fetched.
func TestWantsDownload(t *testing.T) {
	for _, c := range []struct {
		target string
		want   bool
	}{
		{"/host/DLPIC.QOI", true},
		{"/host/RDRPDF.PDF", true},
		{"http://10.0.0.2/pic.png", true},
		{"https://example.com/pack.zip", true},
		{"/host/BUILD.ELF", true},
		{"http://10.0.0.2/song.WAV", true},
		{"/host/PAGE.HTML", false},
		{"/host/NOTES.TXT", false},
		{"http://10.0.0.2/", false},
		{"http://10.0.0.2/index.html", false},
		{"/host/NOEXT", false},
	} {
		if got := wantsDownload(c.target); got != c.want {
			t.Fatalf("wantsDownload(%q) = %v want %v", c.target, got, c.want)
		}
	}
}

// The kernel's path ceiling is 64 bytes; "/host/WEB-DL-" spends 13, so a
// hostile or just-long URL basename is bounded, never handed to FileOpen
// to be refused (or worse, silently wrong) at the syscall.
func TestDownloadNameBounded(t *testing.T) {
	long := "http://10.0.0.2/" + strings.Repeat("a", 200) + ".png"
	name := downloadName(long)
	if len(name) != dlNameMax {
		t.Fatalf("downloadName length = %d, cap %d", len(name), dlNameMax)
	}
	if len(downloadFmt+name) > 64 {
		t.Fatalf("path length = %d over the kernel's 64", len(downloadFmt+name))
	}
}

// The completion plate's chips are the Open/Folder actions — pin their
// hit zones against dlChips so paint and click can never disagree.
func TestDlChipHit(t *testing.T) {
	for i, c := range dlChips {
		mx, my := c.r.X+c.r.W/2, c.r.Y+c.r.H/2
		got, ok := dlChipHit(mx, my)
		if !ok || got != i {
			t.Fatalf("dlChipHit(center of %s) = %d,%v want %d,true", c.label, got, ok, i)
		}
	}
	if _, ok := dlChipHit(-1, -1); ok {
		t.Fatal("dlChipHit(-1,-1) hit")
	}
	if _, ok := dlChipHit(dlToastW/2, dlToastH/2); ok {
		t.Fatal("dlChipHit(plate middle) hit")
	}
}

func TestDlToastOrigin(t *testing.T) {
	x, y := dlToastOrigin(512, 384)
	if x != 512-dlToastW-8 || y != 384-statusH-dlToastH-8 {
		t.Fatalf("dlToastOrigin = %d,%d", x, y)
	}
}
