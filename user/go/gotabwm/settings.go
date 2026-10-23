// GOTABWM.ELF — M66b (#1444): the schema-v2 SETTINGS.TXT decode, the
// corrupt-fails-closed twin of M62e's `.tabs` v2 session handling.
//
// M71f (#1565) moved the codec itself to virelai/settings, because the Go
// settings panel (GOSET.ELF) reads and writes the same file: one codec, two
// consumers, one verdict. The seat keeps only what is seat business — the
// markers its own gates grep, the `wm` report, and the token probe — so the
// decode the seat rejects and the decode the panel rejects cannot drift.
//
// A bad file is reported and IGNORED: the seat boots on its own defaults,
// nothing is written back, and a corrupt file is never laundered into a
// half-parsed one. (The panel reads the same verdict and refuses to write.)
package main

import (
	"strings"

	"virelai/settings"
	"virelai/theme"
	"virelai/vi"
)

// Marker lines for the class-B gates (the seat prints each only after the
// syscall that backs it returned). MarkerSettingsWM carries the decoded
// `wm` value; a corrupt file names itself and nothing else is trusted.
const (
	MarkerSettingsWM  = "gotabwm: settings wm="
	MarkerSettingsBad = "gotabwm: settings bad"
	MarkerTokens      = "gotabwm: tokens "
)

// loadSettingsFile is the decode seam for the boot read — settings.Load on
// the guest, stubbed in host tests (the paletteSettings/notifySettingsLoad
// discipline).
var loadSettingsFile = settings.Load

// loadSettings reads and decodes /host/SETTINGS.TXT at seat start. Missing is
// silent (a first boot, or the pre-seed default flow); a file that fails the
// decode is corrupt-fails-closed — one marker line, then the seat runs on its
// own defaults, never a boot failure. A good decode names the `wm` seat the
// file carries (the key the boot default turns on) and applies the theme —
// base AND the a11y.contrast switch, composed the way ApplySettings composes
// them so a high-contrast boot paints the seat's own chrome in the HC table.
func loadSettings() string {
	f := loadSettingsFile()
	if f.State == settings.StateCorrupt {
		seedSettingsBusValues(settings.File{State: settings.StateMissing})
		vi.ConsoleLine(MarkerSettingsBad)
		return "gotabwm"
	}
	seedSettingsBusValues(f)
	wm, ok := f.Effective("wm")
	if !ok {
		wm = "gotabwm"
	}
	if v, found := settings.Get(f.Rows, "theme"); found {
		_ = theme.Set(v)
	}
	if v, found := f.Effective(settings.A11yContrastKey); found {
		if high, valid := settings.A11yContrast(v); valid {
			theme.SetContrast(high)
		}
	}
	vi.ConsoleLine(MarkerSettingsWM + wm + " keys=" + vi.Itoa64(int64(len(f.Rows))))
	return wm
}

// emitTokens prints the serial token probe go-wm-hid greps. Same shape as Zig
// `emit_tokens_marker` so a pixel/serial probe can pin one OS look.
func emitTokens() {
	t := theme.Current
	vi.ConsoleLine(MarkerTokens + "theme=" + theme.Name() +
		" bg=" + theme.Hex6(t.Bg) +
		" surface=" + theme.Hex6(t.Surface) +
		" border=" + theme.Hex6(t.Border) +
		" accent=" + theme.Hex6(t.Accent))
}

// cutLine splits s after the first newline (if any); the remainder keeps its
// newline handling for the next round. The APPS.TXT manifest parser
// (apps.go) reads through it.
func cutLine(s string) (line, rest string) {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i], s[i+1:]
	}
	return s, ""
}
