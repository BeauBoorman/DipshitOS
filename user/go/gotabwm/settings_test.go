package main

import (
	"testing"

	"virelai/settings"
	"virelai/theme"
	"virelai/vi"
)

// ---------------------------------------------------------------------------
// M66b (#1444) / M71f (#1565): the seat's settings MARKERS
//
// The schema-v2 codec itself moved to virelai/settings (settings_test.go
// there), because the Go settings panel GOSET.ELF reads and writes the same
// file through it. What stays here is what the seat owns: the gate grep
// targets, which no other consumer may rename silently.
// ---------------------------------------------------------------------------

// The seat's markers are gate grep targets: the corrupt line names itself,
// the good line carries the decoded seat.
func TestSettingsMarkerShapes(t *testing.T) {
	if MarkerSettingsBad != "gotabwm: settings bad" {
		t.Fatalf("bad marker = %q", MarkerSettingsBad)
	}
	if MarkerSettingsWM != "gotabwm: settings wm=" {
		t.Fatalf("wm marker = %q", MarkerSettingsWM)
	}
	if MarkerTokens != "gotabwm: tokens " {
		t.Fatalf("tokens marker = %q", MarkerTokens)
	}
}

// M177a (#3142): the boot read applies a11y.contrast beside the theme —
// the seat's own chrome is an ApplySettings consumer now. A file with no
// a11y rows leaves the boot default untouched, so the token probe go-wm-hid
// pins keeps its shape.
func TestLoadSettingsAppliesContrast(t *testing.T) {
	savedLoad := loadSettingsFile
	savedTheme, savedContrast := theme.Current, theme.Contrast()
	savedValues := settingsBusValues
	t.Cleanup(func() {
		loadSettingsFile = savedLoad
		theme.SetContrast(false)
		theme.Set("dark")
		theme.Current = savedTheme
		theme.SetContrast(savedContrast == "high")
		settingsBusValues = savedValues
	})

	loadSettingsFile = func() settings.File {
		return settings.File{State: settings.StateOK, Rows: []settings.Setting{
			{Key: "theme", Val: "dark"},
			{Key: "a11y.contrast", Val: "high"},
		}}
	}
	if wm := loadSettings(); wm != "gotabwm" {
		t.Fatalf("wm = %q want gotabwm", wm)
	}
	if theme.Contrast() != "high" || theme.Current != theme.DarkHC {
		t.Fatalf("contrast boot: Contrast()=%q Current.Bg=%#x want high/DarkHC",
			theme.Contrast(), theme.Current.Bg)
	}

	// No a11y rows: the effective default is off and the dark table is the
	// plain one — the MarkerTokens line a boot prints is unchanged.
	loadSettingsFile = func() settings.File {
		return settings.File{State: settings.StateOK, Rows: []settings.Setting{
			{Key: "theme", Val: "dark"},
		}}
	}
	theme.SetContrast(true)
	loadSettings()
	if theme.Contrast() != "off" || theme.Current != theme.Dark {
		t.Fatalf("no-a11y boot: Contrast()=%q want off/Dark", theme.Contrast())
	}

	// A corrupt file stays fails-closed: the contrast switch is not read.
	loadSettingsFile = func() settings.File {
		return settings.File{State: settings.StateCorrupt}
	}
	theme.SetContrast(true)
	loadSettings()
	if theme.Contrast() != "high" {
		t.Fatalf("corrupt boot moved the contrast switch")
	}
}

// M177a (#3142): a GOSET publish of a11y.contrast applies to the seat live
// AND reaches its subscribers — the same door `theme=` already used.
func TestSettingsPublishAppliesContrast(t *testing.T) {
	savedTabs := tabs
	savedLoad, savedSend := loadSettingsForBus, sendSettingsNotice
	savedSubs := settingsSubscriptions
	savedValues := settingsBusValues
	savedTheme, savedContrast := theme.Current, theme.Contrast()
	t.Cleanup(func() {
		tabs = savedTabs
		loadSettingsForBus, sendSettingsNotice = savedLoad, savedSend
		settingsSubscriptions = savedSubs
		settingsBusValues = savedValues
		theme.SetContrast(false)
		theme.Set("dark")
		theme.Current = savedTheme
		theme.SetContrast(savedContrast == "high")
	})
	tabs = TabStrip{}
	resetSettingsSubscriptions()
	if !tabs.OpenTab(4, "view") || !tabs.OpenTab(5, "settings") {
		t.Fatal("open subscriber and publisher tabs")
	}
	var told vi.WmRpc
	sendSettingsNotice = func(pid uint32, body []byte) int64 {
		told, _ = vi.DecodeWmRpc(body)
		return int64(len(body))
	}
	sub := vi.WmRpc{Kind: vi.WmRpcKindSettingsSubscribe, ID: 4, ReplyTo: 77}
	sub.SetTitle(settings.A11yContrastKey)
	if !applyRPC(sub) {
		t.Fatal("a11y.contrast is a subscribable key")
	}

	seedSettingsBusValues(settings.File{State: settings.StateOK})
	file := func(val string) settings.File {
		return settings.File{State: settings.StateOK, Rows: []settings.Setting{
			{Key: settings.A11yContrastKey, Val: val},
		}}
	}
	publish := vi.WmRpc{Kind: vi.WmRpcKindSettingsPublish, ID: 5, ReplyTo: 88}
	publish.SetTitle(settings.A11yContrastKey)

	loadSettingsForBus = func() settings.File { return file("high") }
	if !applyRPC(publish) {
		t.Fatal("publishing a11y.contrast=high refused")
	}
	if theme.Contrast() != "high" || theme.Current != theme.DarkHC {
		t.Fatalf("contrast publish: Contrast()=%q want high/DarkHC", theme.Contrast())
	}
	if told.Kind != vi.WmRpcKindSettingsChanged || told.TitleString() != settings.A11yContrastKey {
		t.Fatalf("subscriber told %+v", told)
	}
	loadSettingsForBus = func() settings.File { return file("off") }
	if !applyRPC(publish) || theme.Contrast() != "off" || theme.Current != theme.Dark {
		t.Fatalf("publishing a11y.contrast=off: Contrast()=%q", theme.Contrast())
	}
}
