package main

import (
	"strings"
	"testing"

	"virelai/appkit"
	"virelai/vi"
	"virelai/webrender"
)

// M123d (#2578): the banner adoption — raise points, key routing, and the
// resolve arms, all pinned host-side (vi.Exec/vsys are ENOSYS here, so the
// copy arm proves itself by its marker, not a readback).

func TestLoadErrorRaisesBanner(t *testing.T) {
	a := &app{hist: newHistory(), text: webrender.Bitmap{}}
	a.setError("dns", "http://10.0.0.2/x")
	if !a.banner.Open {
		t.Fatal("a transient load failure must raise the banner")
	}
	if len(a.banner.Actions) != 1 || a.banner.Actions[0].ID != "retry" {
		t.Fatalf("dns failure should offer Retry: %+v", a.banner.Actions)
	}
	if !strings.Contains(a.banner.Text, "dns") {
		t.Fatalf("banner text = %q", a.banner.Text)
	}
	// Enter takes the focused action — the single action IS the default
	// (safe-last convention: Retry is the only button ahead of Copy). The
	// retry arm replays the target through navigate; on the host the fetch
	// is refused again, which honestly raises the NEXT banner.
	a.bannerKeyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: 0x28, Arg1: '\r'})
	if a.target != "http://10.0.0.2/x" {
		t.Fatalf("retry did not navigate: target=%q", a.target)
	}
	if a.banner.Open && !strings.Contains(a.banner.Text, "tcp") && !strings.Contains(a.banner.Text, "dns") {
		t.Fatalf("the retry's own failure should name its kind: %q", a.banner.Text)
	}
}

func TestCancelledLoadRaisesNoBanner(t *testing.T) {
	a := &app{}
	a.setError("cancelled", "http://10.0.0.2/x")
	if a.banner.Open {
		t.Fatal("the user's own stop is not a failure to answer")
	}
}

func TestPermanentErrorBannerHasNoRetry(t *testing.T) {
	a := &app{}
	a.setError("tls-expired", "https://10.0.0.2/x")
	if !a.banner.Open {
		t.Fatal("a permanent failure still raises the banner")
	}
	if len(a.banner.Actions) != 0 {
		t.Fatalf("tls-expired must not offer Retry: %+v", a.banner.Actions)
	}
	// 'c' is Copy Error: the text publishes through the clip seam and the
	// act marker lands — on the host the write is refused, which is itself
	// the named outcome.
	a.bannerKeyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: 0x06, Arg1: 'c'})
	if a.banner.Open || a.status != "error copied" {
		t.Fatalf("copy resolve: open=%v status=%q", a.banner.Open, a.status)
	}
}

func TestBannerKeysStayOffThePage(t *testing.T) {
	a := &app{hist: newHistory()}
	a.raiseBanner("", "exec MISSING.ELF refused: ENOENT", "")
	// While the banner stands, browsing keys are the banner's: 'c' resolves
	// as Copy Error, not the cookies-clear chord.
	a.bannerKeyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: 0x06, Arg1: 'c'})
	if a.banner.Open {
		t.Fatal("c did not resolve the banner")
	}
	if a.status != "error copied" {
		t.Fatalf("copy status = %q", a.status)
	}
	// And a click inside the strip is consumed, not a page click.
	a.raiseBanner("", "boom", "")
	if !a.bannerClick(a.bannerRect().X+2, a.bannerRect().Y+2) {
		t.Fatal("a press inside the strip must be consumed")
	}
	if a.bannerClick(4, a.bannerRect().Bottom()+40) {
		t.Fatal("a press below the strip leaked into the banner")
	}
}

func TestBannerDismissByEscape(t *testing.T) {
	a := &app{}
	a.raiseBanner("load", "load failed: tcp — http://10.0.0.2/x", "http://10.0.0.2/x",
		appkit.BannerAction{ID: "retry", Label: "Retry"})
	a.bannerKeyEvent(vi.Event{Kind: vi.EvKeyDown, Arg0: 0x29, Arg1: 0x1b})
	if a.banner.Open || a.bannerOp != "" {
		t.Fatalf("esc dismiss: open=%v op=%q", a.banner.Open, a.bannerOp)
	}
}

func TestNavigationRetiresBanner(t *testing.T) {
	a := &app{hist: newHistory()}
	a.raiseBanner("", "exec X.ELF refused", "")
	// A fresh navigation retires the standing strip; when THAT navigation
	// fails on the host resolver it raises its own — what must not survive
	// is the stale exec refusal text.
	a.navigate("ftp://D", "")
	if a.banner.Open && strings.Contains(a.banner.Text, "exec X.ELF") {
		t.Fatalf("the old banner survived navigation: %q", a.banner.Text)
	}
}
