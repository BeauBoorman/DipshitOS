package appkit

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"os"
	"testing"

	"virelai/draw"
	"virelai/ttf"
	"virelai/vi"
)

func key(usage, symbol uint32) vi.Event {
	return vi.Event{Kind: vi.EvKeyDown, Arg0: usage, Arg1: symbol}
}

func TestDialogCancelAndConfirm(t *testing.T) {
	d := NewConfirm("Save?", "Overwrite the file?")
	if !d.Open || d.Focus != 1 {
		t.Fatalf("new confirm = %+v", d)
	}
	if _, done := d.HandleKey(key(0x28, '\r')); !done || d.Open || d.Result != "No" {
		t.Fatalf("default confirm result = %+v", d)
	}

	d = NewConfirm("Save?", "Overwrite the file?")
	if changed, done := d.HandleKey(key(0x2b, '\t')); !changed || done {
		t.Fatalf("tab: changed=%v done=%v", changed, done)
	}
	if d.Focus != 0 {
		t.Fatalf("focus = %d, want 0", d.Focus)
	}
	if _, done := d.HandleKey(key(0x28, '\r')); !done || d.Open || d.Result != "Yes" {
		t.Fatalf("confirm result = %+v", d)
	}

	d = NewMessage("Notice", "Saved")
	if _, done := d.HandleKey(key(0x29, 0x1b)); !done || d.Open || d.Result != "cancel" {
		t.Fatalf("escape result = %+v", d)
	}
}

func TestDialogPromptEditsAndSelects(t *testing.T) {
	d := NewPrompt("Path", "Enter a file")
	for _, ch := range []uint32{'a', 'b', 'c'} {
		if changed, done := d.HandleKey(key(0, ch)); !changed || done {
			t.Fatalf("printable %c: changed=%v done=%v", ch, changed, done)
		}
	}
	if d.Input != "abc" {
		t.Fatalf("input = %q, want abc", d.Input)
	}
	if changed, done := d.HandleKey(key(0x2a, 0)); !changed || done {
		t.Fatalf("backspace: changed=%v done=%v", changed, done)
	}
	if d.Input != "ab" || !d.Open {
		t.Fatalf("after backspace = %+v", d)
	}
	if _, done := d.HandleKey(key(0x28, '\r')); !done || d.Open || d.Result != "ab" {
		t.Fatalf("prompt result = %+v", d)
	}
}

func TestDialogMouseChoosesHitButton(t *testing.T) {
	d := NewConfirm("Save?", "Overwrite?")
	button := d.Buttons[1]
	if _, done := d.HandleMouse(button.R.X+1, button.R.Y+1, true); !done {
		t.Fatal("button click did not complete dialog")
	}
	if d.Result != "No" || d.Open {
		t.Fatalf("mouse result = %+v", d)
	}
}

func TestDialogPrimitiveChrome(t *testing.T) {
	ui, err := os.ReadFile("../../../image/fonts/Inter-Regular.ttf")
	if err != nil {
		t.Fatal(err)
	}
	chrome, err := os.ReadFile("../../../image/fonts/VirelaiChrome-Regular.ttf")
	if err != nil {
		t.Fatal(err)
	}
	d := NewPrompt("Open file", "Enter a path to open")
	d.UIFace, err = ttf.Parse(ui)
	if err != nil {
		t.Fatal(err)
	}
	d.IconFace, err = ttf.Parse(chrome)
	if err != nil {
		t.Fatal(err)
	}
	d.Input = "notes.txt"
	const w, h = 512, 384
	c := &draw.BufferCanvas{Pix: make([]uint32, w*h), W: w, H: h}
	draw.FillRect(c, d.R, draw.Opaque(0x182026))
	d.Draw(c)
	pixel := func(x, y int) uint32 { return c.Pix[y*w+x] }
	if pixel(96, 72) != draw.Opaque(0x182026) {
		t.Fatalf("corner is not rounded: %#x", pixel(96, 72))
	}
	if pixel(256, 72) != draw.Opaque(0x334155) {
		t.Fatalf("top border missing: %#x", pixel(256, 72))
	}
	if pixel(180, 160) != draw.Opaque(0x11171c) {
		t.Fatalf("recessed input missing: %#x", pixel(180, 160))
	}
	if pixel(284, 189) != draw.Opaque(0x3b82f6) {
		t.Fatalf("inside focus ring missing: %#x", pixel(284, 189))
	}
	iconInk := 0
	for y := 84; y < 108; y++ {
		for x := 108; x < 124; x++ {
			if pixel(x, y) == draw.Opaque(0x3b82f6) {
				iconInk++
			}
		}
	}
	if iconInk < 8 {
		t.Fatalf("chrome PUA icon missing: %d pixels", iconInk)
	}
	if got := d.Buttons[len(d.Buttons)-1].R.Right(); got != d.R.Right()-12 {
		t.Fatalf("last button not right aligned: %d", got)
	}
	// Composite golden in a byte vector: the host and guest use the same
	// integer shape rasterizer, font masks, and 0xAARRGGBB canvas path.
	var bytes [w * h * 4]byte
	for i, px := range c.Pix {
		binary.LittleEndian.PutUint32(bytes[4*i:], px)
	}
	const golden = "a6e30042a6052d53340d7679aa9b13552e658680f059ae85bc6cc5839ebdc2d9"
	if got := fmt.Sprintf("%x", sha256.Sum256(bytes[:])); got != golden {
		t.Fatalf("dialog composite SHA-256 = %s (want %s)", got, golden)
	}
	// Each dialog kind must resolve a distinct shipped PUA glyph by name.
	seen := map[[32]byte]bool{}
	for _, kind := range []DialogKind{PromptDialog, MessageDialog, ConfirmDialog} {
		other := newDialog(kind, "Title", "Body", kind == PromptDialog)
		other.IconFace = d.IconFace
		canvas := &draw.BufferCanvas{Pix: make([]uint32, w*h), W: w, H: h}
		other.Draw(canvas)
		mask := make([]byte, 0, 16*24*4)
		ink := 0
		for y := 84; y < 108; y++ {
			for x := 108; x < 124; x++ {
				var px [4]byte
				binary.LittleEndian.PutUint32(px[:], canvas.Pix[y*w+x])
				mask = append(mask, px[:]...)
				if canvas.Pix[y*w+x] == draw.Opaque(0x3b82f6) {
					ink++
				}
			}
		}
		if ink < 8 {
			t.Fatalf("dialog kind %d has no chrome icon: %d pixels", kind, ink)
		}
		sum := sha256.Sum256(mask)
		if seen[sum] {
			t.Fatalf("dialog kind %d reused an icon", kind)
		}
		seen[sum] = true
	}
	// A moved dialog reuses its paint rects for pointer hit-testing.
	d.R.X += 12
	d.Draw(c)
	if d.Buttons[1].R.Right() != d.R.Right()-12 {
		t.Fatal("moved dialog left stale button hit rect")
	}
}
