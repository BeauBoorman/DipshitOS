package main

import (
	"virelai/ttf"
	"virelai/vi"
	"virelai/webrender"
	"virelai/webstyle"
)

// Text plumbing for the browser: load the faces the share stages, pick a text
// engine, and republish what was chosen on the serial line so a gate can assert
// the page is not silently back on the 8x8 grid.

// Share names frozen by M69d #1531 D1. Zig ui.init_fonts (#1536) consumes the
// same paths; this card only reads them.
const (
	fontUIPath         = "/host/INTER.TTF"
	fontBoldPath       = "/host/INTERB.TTF"
	fontItalicPath     = "/host/INTERI.TTF"
	fontBoldItalicPath = "/host/INTERBI.TTF"
	fontMonoPath       = "/host/FIRACODE.TTF"
	fontSerifPath      = "/host/NOTOSERF.TTF"

	// fontManifestPath is the M99l registry manifest, staged from
	// image/fonts/fonts.txt. It is Go-registry input only — the frozen Zig
	// engine never reads it (ADR 0034).
	fontManifestPath = "/host/FONTS.TXT"
)

// maxManifestBytes bounds the manifest read; apps.txt's readers use the same
// 4096-byte buffer for the same line format.
const maxManifestBytes = 4096

// maxFontBytes bounds one face read. Inter Regular is 411,640 bytes, Bold
// 420,428, Italic 417,388, Fira Code 289,624 — 512 KiB holds each with room
// for a slightly larger licensed build. It is deliberately NOT vi.MaxFileBytes
// (256 KiB): that cap is a policy for the browser's PAGE loads, and reusing it
// here silently truncated Inter in half and dropped the renderer back onto the
// bitmap. A face past this bound fails to parse and the renderer falls back —
// visible, never blank.
const maxFontBytes = 512 * 1024

// maxImageBytes bounds one <img> read from the share.
const maxImageBytes = webstyle.MaxImageBytes

// readWholeFile reads up to max bytes of a share file. It is the browser's own
// reader rather than vi.ReadFileAll because that helper clamps every request to
// vi.MaxFileBytes (see maxFontBytes).
func readWholeFile(path string, max int) []byte {
	h, rc := vi.FileOpen(path, vi.ModeRead)
	if rc < 0 || h < 0 {
		return nil
	}
	defer vi.FileClose(uint32(h))
	out := make([]byte, 0, 64*1024)
	buf := make([]byte, 16*1024)
	for len(out) < max {
		n, rr := vi.FileRead(uint32(h), buf)
		if rr < 0 || n <= 0 {
			break
		}
		take := n
		if len(out)+take > max {
			take = max - len(out)
		}
		out = append(out, buf[:take]...)
		if take < n {
			break
		}
	}
	return out
}

// faceState is the per-role half of the `web: fonts` marker pair.
func faceState(f *ttf.Face) string {
	if f == nil {
		return "missing"
	}
	return "truetype"
}

// loadRegistryEngine reads the staged manifest and builds the M99l cascade
// engine over it. The second return is the marker payload —
// "manifest=ok faces=N" or "manifest=malformed <why>" — and false means the
// caller takes the no-manifest path (missing manifest, or a refused one per
// the card's malformed-then-hard-coded rule).
func loadRegistryEngine() (webrender.Fonts, string, bool) {
	data := readWholeFile(fontManifestPath, maxManifestBytes)
	if data == nil {
		return webrender.Fonts{}, "manifest=missing", false
	}
	specs, err := ttf.ParseManifest(data)
	if err != nil {
		return webrender.Fonts{}, "manifest=malformed " + err.Error(), false
	}
	reg := ttf.NewRegistry(specs, func(file string) (*ttf.Face, error) {
		return ttf.Parse(readWholeFile("/host/"+file, maxFontBytes))
	})
	// The card's `fonts: notdef=N` marker: every rune that exhausted its
	// chain increments the count on the serial line.
	reg.OnNotdef = func(n int) {
		vi.ConsoleLine("fonts: notdef=" + itoa(n))
	}
	return webrender.RegistryFonts(reg), "manifest=ok faces=" + itoa(len(specs)), true
}

// loadTextEngine loads the staged faces and returns the engine to render with.
// A valid manifest selects the registry engine; a missing or refused manifest
// keeps today's four hard-coded faces. Either way the serial line says which
// path was taken, so a gate can assert the manifest was honored rather than
// silently ignored.
func loadTextEngine() (webrender.Fonts, string, string, string) {
	f, marker, ok := loadRegistryEngine()
	vi.ConsoleLine("fonts: " + marker)
	if ok {
		return f, faceState(f.UI), faceState(f.Mono), faceState(f.Serif)
	}
	ui := readWholeFile(fontUIPath, maxFontBytes)
	mono := readWholeFile(fontMonoPath, maxFontBytes)
	serif := readWholeFile(fontSerifPath, maxFontBytes)
	bold := readWholeFile(fontBoldPath, maxFontBytes)
	italic := readWholeFile(fontItalicPath, maxFontBytes)
	boldItalic := readWholeFile(fontBoldItalicPath, maxFontBytes)
	f = webrender.LoadFonts(webrender.FontFiles{UI: ui, Mono: mono, Serif: serif, Bold: bold, Italic: italic, BoldItalic: boldItalic})
	return f, faceState(f.UI), faceState(f.Mono), faceState(f.Serif)
}

// textProbeString is the Inter-or-grid probe, published on the serial line.
//
// It is deliberately made of FACTS a gate can assert rather than adjectives:
// the engine's name, whether advances are per-glyph, the line heights the layout
// actually uses, and three measured advances. On the 8x8 fallback every advance
// is 8 and the h1 line box is 18px; on Inter at 13px the advances differ per
// glyph and the h1 line box is 33px. Those numbers cannot both be true, so a
// silent regression back to the grid fails the gate instead of merely looking
// slightly off in a screenshot.
func textProbeString(t webrender.TextEngine) string {
	if t == nil {
		t = webrender.Bitmap{}
	}
	body := webrender.Style{Size: 1, Color: webrender.ColorText}
	h1 := webrender.Style{Size: 2, Color: webrender.ColorText}
	mono := webrender.Style{Size: 1, Mono: true}
	serif := webrender.Style{Size: 1, Serif: true}
	boldFace, boldHeavier, italicFace, biFace, biResolve := "no", "no", "no", "no", "none"
	serifFace, serifResolve := "no", "none"
	if f, ok := t.(webrender.Fonts); ok {
		if f.Serif != nil {
			serifFace = "yes"
		}
		serifResolve = f.ResolvedName(serif)
		if f.Bold != nil {
			boldFace = "yes"
			if f.BoldHeavier() {
				boldHeavier = "yes"
			}
		}
		if f.Italic != nil {
			italicFace = "yes"
		}
		if f.BoldItalic != nil {
			biFace = "yes"
		}
		// What does a CSS bold+italic style actually resolve to? The named
		// face, not an adjective: bolditalic when INTERBI.TTF is loaded,
		// the degrade name (bold, italic, ui) when it is not.
		biResolve = f.ResolvedName(webrender.Style{Size: 1, Bold: true, Italic: true})
	}
	return "face=" + t.Name() +
		" proportional=" + boolStr(t.Proportional()) +
		" body-lineh=" + itoa(t.LineHeight(body)) +
		" h1-lineh=" + itoa(t.LineHeight(h1)) +
		" mono-lineh=" + itoa(t.LineHeight(mono)) +
		" adv-i=" + itoa(t.Measure("i", body)) +
		" adv-W=" + itoa(t.Measure("W", body)) +
		" adv-space=" + itoa(t.Measure(" ", body)) +
		" bold-face=" + boldFace +
		" bold-heavier=" + boldHeavier +
		" italic-face=" + italicFace +
		" bi-face=" + biFace +
		" bi-resolve=" + biResolve +
		" serif-face=" + serifFace +
		" serif-resolve=" + serifResolve
}

// resolveImage returns only preflighted sources during layout. Resource reads
// and decoded-pixel accounting happen before building boxes.
func (a *app) resolveImage(src string) ([]byte, bool) {
	if src == "" {
		return nil, false
	}
	if a.imageSources != nil {
		data := a.imageSources[src]
		return data, len(data) > 0
	}
	// Host-test/direct callers retain a bounded resource refusal path.
	target := relativeTo(a.target, src)
	resolved, kind := resolveInput(target)
	if kind != "file" {
		return nil, false
	}
	data := readWholeFile(resolved, maxImageBytes+1)
	return data, len(data) > 0 && len(data) <= maxImageBytes
}
