package appkit

import (
	"testing"

	"virelai/draw"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

func TestProgressSetClampsAndReportsChange(t *testing.T) {
	p := NewProgress(widgets.Rect{X: 0, Y: 0, W: 200, H: 16}, 50)
	if !p.Set(25) || p.Value != 25 {
		t.Fatalf("Set(25) value=%d", p.Value)
	}
	if p.Set(25) {
		t.Fatal("a no-op Set reported a change")
	}
	p.Set(999)
	if p.Value != 50 || p.Percent() != 100 || !p.Complete() {
		t.Fatalf("over-total Set value=%d pct=%d", p.Value, p.Percent())
	}
	p.Set(-5)
	if p.Value != 0 || p.Percent() != 0 {
		t.Fatalf("negative Set value=%d pct=%d", p.Value, p.Percent())
	}
	p = NewProgress(widgets.Rect{W: 10, H: 10}, 0)
	if p.Max != 100 {
		t.Fatalf("zero max -> %d, want 100", p.Max)
	}
	if !p.Advance(30) || p.Value != 30 {
		t.Fatalf("Advance value=%d", p.Value)
	}
}

func TestProgressFillGeometry(t *testing.T) {
	p := NewProgress(widgets.Rect{X: 10, Y: 20, W: 208, H: 12}, 200)
	p.Set(50)
	got := p.fillRect()
	wantW := (208 - 2*progressBarInset) * 50 / 200
	if got.X != 12 || got.Y != 22 || got.W != wantW || got.H != 8 {
		t.Fatalf("fill = %+v, want x=12 y=22 w=%d h=8", got, wantW)
	}
	p.Set(200)
	if got := p.fillRect(); got.W != 204 {
		t.Fatalf("complete fill w=%d, want the full track 204", got.W)
	}
	p.Set(0)
	if got := p.fillRect(); !got.Empty() && got.W != 0 {
		t.Fatalf("empty fill = %+v", got)
	}
}

func TestProgressIndeterminateSweepIsATriangleWave(t *testing.T) {
	p := NewProgress(widgets.Rect{X: 0, Y: 0, W: 104, H: 10}, 0)
	p.Indeterminate = true
	inner := p.inner()
	seg := inner.W / progressSweepDenominator
	travel := inner.W - seg
	var xs []int
	for i := 0; i <= 2*travel; i++ {
		p.Phase = i
		xs = append(xs, p.fillRect().X-inner.X)
	}
	if xs[0] != 0 || xs[travel] != travel || xs[2*travel] != 0 {
		t.Fatalf("sweep endpoints %d,%d,%d want 0,%d,0", xs[0], xs[travel], xs[2*travel], travel)
	}
	for i := 1; i < len(xs); i++ {
		d := xs[i] - xs[i-1]
		if d != 1 && d != -1 {
			t.Fatalf("sweep step %d->%d is not unit", xs[i-1], xs[i])
		}
	}
	p.Phase = 0
	p.Tick()
	if p.Phase != 1 {
		t.Fatalf("Tick phase=%d", p.Phase)
	}
	p.Indeterminate = false
	p.Tick()
	if p.Phase != 1 {
		t.Fatal("a determinate bar advanced its sweep phase")
	}
}

func TestProgressDrawPaintsTrackAndFill(t *testing.T) {
	savedTheme := theme.Current
	theme.Current = theme.Dark
	defer func() { theme.Current = savedTheme }()
	p := NewProgress(widgets.Rect{X: 0, Y: 0, W: 100, H: 12}, 100)
	p.Set(50)
	buf := make([]byte, 100*12*4)
	c, err := draw.BytesCanvas(buf, 100, 12)
	if err != nil {
		t.Fatal(err)
	}
	p.Draw(c)
	mid := c.Pix[6*100+40]
	if mid != draw.Opaque(theme.Dark.Accent) {
		t.Fatalf("bar mid pixel = %#08x, want Accent %#08x", mid, draw.Opaque(theme.Dark.Accent))
	}
	past := c.Pix[6*100+95]
	if past != draw.Opaque(theme.Dark.ChromeBg) {
		t.Fatalf("unfilled pixel = %#08x, want track %#08x", past, draw.Opaque(theme.Dark.ChromeBg))
	}
}

func TestProgressReportUsesTheSeatWire(t *testing.T) {
	saved := notifyProgressReport
	defer func() { notifyProgressReport = saved }()
	var gotWin uint32
	var gotOp uint8
	var gotPct int
	var gotLabel, gotName string
	notifyProgressReport = func(w uint32, o uint8, pct int, l, n string) bool {
		gotWin, gotOp, gotPct, gotLabel, gotName = w, o, pct, l, n
		return true
	}
	p := NewProgress(widgets.Rect{W: 10, H: 10}, 200)
	p.Label = "Copying"
	p.Set(50)
	if p.Report(4, "APP.ELF") {
		t.Fatal("a widget with Op 0 reported to the seat")
	}
	p.Op = 7
	if !p.Report(4, "APP.ELF") {
		t.Fatal("report refused")
	}
	if gotWin != 4 || gotOp != 7 || gotPct != 25 || gotLabel != "Copying" || gotName != "APP.ELF" {
		t.Fatalf("wire = win=%d op=%d pct=%d label=%q name=%q",
			gotWin, gotOp, gotPct, gotLabel, gotName)
	}
	p.Indeterminate = true
	p.Report(4, "APP.ELF")
	if gotPct != vi.ProgressIndeterminate {
		t.Fatalf("indeterminate report pct=%d, want %d", gotPct, vi.ProgressIndeterminate)
	}
}
