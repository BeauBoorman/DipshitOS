package appkit

import (
	"testing"

	"virelai/draw"
	"virelai/theme"
	"virelai/widgets"
)

func TestErrorBannerDefaultsAndDismiss(t *testing.T) {
	var b ErrorBanner
	b.Show("rename: name exists", BannerAction{ID: "replace", Label: "Replace"}, BannerAction{ID: "cancel", Label: "Cancel"})
	if !b.Open || b.Text != "rename: name exists" {
		t.Fatalf("show = %+v", b)
	}
	// Focus defaults to the LAST action — the safe-default convention:
	// Enter arms Cancel, never Replace.
	if b.Focus != 1 {
		t.Fatalf("focus = %d, want 1 (Cancel)", b.Focus)
	}
	if changed, done := b.HandleKey(key(0x29, 0x1b)); !changed || !done || b.Open || b.Choice != BannerDismiss {
		t.Fatalf("escape: changed=%v done=%v banner=%+v", changed, done, b)
	}
}

func TestErrorBannerActivateAndCopy(t *testing.T) {
	var b ErrorBanner
	b.Show("open launch refused EACCES", BannerAction{ID: "retry", Label: "Retry"})

	// Digit 1 activates the first action directly.
	if changed, done := b.HandleKey(key(0, '1')); !changed || !done || b.Choice != "retry" {
		t.Fatalf("digit: changed=%v done=%v choice=%q", changed, done, b.Choice)
	}

	// c is Copy Error — the same result as activating the last button.
	b.Show("exec refused", BannerAction{ID: "retry", Label: "Retry"})
	if changed, done := b.HandleKey(key(0, 'c')); !changed || !done || b.Choice != BannerCopy {
		t.Fatalf("c: changed=%v done=%v choice=%q", changed, done, b.Choice)
	}

	// Ctrl+C keeps its own contract: usage 0x06 with a control symbol is
	// NOT the copy chord.
	b.Show("exec refused")
	if changed, done := b.HandleKey(key(0x06, 0x03)); changed || done || !b.Open {
		t.Fatalf("ctrl+c: changed=%v done=%v open=%v", changed, done, b.Open)
	}
	// Tab wraps onto the only button; Enter takes it (Copy Error).
	if _, done := b.HandleKey(key(0x2b, '\t')); done {
		t.Fatal("tab resolved the banner")
	}
	if _, done := b.HandleKey(key(0x28, '\r')); !done || b.Choice != BannerCopy {
		t.Fatalf("enter on copy: done=%v choice=%q", done, b.Choice)
	}
}

func TestErrorBannerMouse(t *testing.T) {
	var b ErrorBanner
	b.R = widgets.Rect{X: 8, Y: 4, W: 320, H: 30}
	b.Show("rename: name exists", BannerAction{ID: "replace", Label: "Replace"}, BannerAction{ID: "cancel", Label: "Cancel"})

	buttons, dismiss := b.layout()
	if len(buttons) != 3 { // Replace, Cancel, Copy Error
		t.Fatalf("buttons = %d, want 3", len(buttons))
	}
	// A press inside the strip but off every control is consumed, not
	// passed to the surface beneath — the click never falls through.
	mid := widgets.Rect{X: buttons[0].Right() + 2, Y: b.R.Y + 2, W: 4, H: 4}
	if !b.Contains(mid.X, mid.Y) {
		t.Fatal("strip interior not contained")
	}
	if changed, done := b.HandleMouse(mid.X, mid.Y, true); !changed || done || !b.Open {
		t.Fatalf("interior click: changed=%v done=%v", changed, done)
	}
	// The dismiss × closes with the dismiss result.
	if _, done := b.HandleMouse(dismiss.X+2, dismiss.Y+2, true); !done || b.Choice != BannerDismiss {
		t.Fatalf("dismiss click: done=%v choice=%q", done, b.Choice)
	}
	// A button press chooses by hit rect — paint and hit share layout().
	b.Show("rename: name exists", BannerAction{ID: "replace", Label: "Replace"}, BannerAction{ID: "cancel", Label: "Cancel"})
	if _, done := b.HandleMouse(buttons[0].X+2, buttons[0].Y+2, true); !done || b.Choice != "replace" {
		t.Fatalf("replace click: done=%v choice=%q", done, b.Choice)
	}
	// A press outside the strip is not the banner's at all.
	b.Show("err")
	if changed, done := b.HandleMouse(1, 1, true); changed || done || !b.Open {
		t.Fatalf("outside click: changed=%v done=%v", changed, done)
	}
}

func TestErrorBannerLineVT(t *testing.T) {
	var b ErrorBanner
	b.Show("rename: name exists", BannerAction{ID: "replace", Label: "Replace"}, BannerAction{ID: "cancel", Label: "Cancel"})
	got := b.Line(80)
	want := "! rename: name exists [1] Replace [2] Cancel [c] copy [esc]"
	if got != want {
		t.Fatalf("line = %q, want %q", got, want)
	}
	if len(b.Line(20)) != 20 {
		t.Fatalf("clipped line len = %d", len(b.Line(20)))
	}
	b.Dismiss()
	if b.Line(80) != "" {
		t.Fatal("a dismissed banner renders nothing")
	}
}

func TestErrorBannerDrawPaintsStripAndButtons(t *testing.T) {
	savedTheme := theme.Current
	theme.Current = theme.Dark
	defer func() { theme.Current = savedTheme }()

	var b ErrorBanner
	b.R = widgets.Rect{X: 4, Y: 4, W: 200, H: 30}
	b.Show("save refused", BannerAction{ID: "retry", Label: "Retry"})
	buf := make([]byte, 208*38*4)
	c, err := draw.BytesCanvas(buf, 208, 38)
	if err != nil {
		t.Fatal(err)
	}
	b.Draw(c)
	// The plate body is opaque Surface inside R — a row below the buttons,
	// clear of every glyph and border band.
	mid := c.Pix[32*208+30]
	if mid != draw.Opaque(theme.Dark.Surface) {
		t.Fatalf("plate pixel = %#08x, want Surface %#08x", mid, draw.Opaque(theme.Dark.Surface))
	}
	// …and the focused (only) action button paints its hover face — a
	// mid-height pixel just right of the border ring, left of the label.
	buttons, _ := b.layout()
	btn := c.Pix[(buttons[0].Y+buttons[0].H/2)*208+buttons[0].X+3]
	if btn != draw.Opaque(theme.Dark.BtnHover) {
		t.Fatalf("focused button = %#08x, want BtnHover %#08x", btn, draw.Opaque(theme.Dark.BtnHover))
	}
	// Closed, the strip paints nothing at all.
	b.Dismiss()
	for i := range c.Pix {
		c.Pix[i] = 0
	}
	b.Draw(c)
	if c.Pix[32*208+30] != 0 {
		t.Fatal("a dismissed banner still paints")
	}
}

func TestErrorBannerDigitOutOfRange(t *testing.T) {
	var b ErrorBanner
	b.Show("err", BannerAction{ID: "a", Label: "A"})
	// '9' with one action is a no-op — a stray digit never arms anything.
	if changed, done := b.HandleKey(key(0x26, '9')); changed || done || !b.Open {
		t.Fatalf("digit 9: changed=%v done=%v open=%v", changed, done, b)
	}
	if changed, done := b.HandleKey(key(0, '1')); !changed || !done || b.Choice != "a" {
		t.Fatalf("digit 1: changed=%v done=%v choice=%q", changed, done, b.Choice)
	}
}
