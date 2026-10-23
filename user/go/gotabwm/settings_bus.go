package main

import (
	"virelai/settings"
	"virelai/theme"
	"virelai/vi"
)

const (
	MarkerSettingsSubscribe = "gotabwm: settings subscribe pid="
	MarkerSettingsBroadcast = "gotabwm: settings broadcast key="

	maxSettingsSubscriptions = MaxTabs * settings.MaxKeys
)

type settingSubscription struct {
	active bool
	id     uint8
	pid    uint8
	key    [vi.WmRpcTitleMax]byte
	length uint8
}

var settingsSubscriptions [maxSettingsSubscriptions]settingSubscription
var settingsBusValues [settings.MaxKeys + 4]settingValue

type settingValue struct {
	key   string
	value string
}

// The file and send seams keep dispatch testable without a guest.
var (
	loadSettingsForBus = settings.Load
	sendSettingsNotice = vi.IpcSend
)

func applySettingsSubscribe(req vi.WmRpc) bool {
	key := req.TitleString()
	if req.ReplyTo == 0 || tabs.index(uint32(req.ID)) < 0 || !settings.Editable(key) {
		return false
	}
	if !rememberSettingsSubscription(req.ID, req.ReplyTo, key) {
		return false
	}
	vi.ConsoleLine(MarkerSettingsSubscribe + vi.Itoa64(int64(req.ReplyTo)) + " key=" + key)
	return true
}

func rememberSettingsSubscription(id, pid uint8, key string) bool {
	if key == "" || len(key) > vi.WmRpcTitleMax {
		return false
	}
	for i := range settingsSubscriptions {
		s := &settingsSubscriptions[i]
		if s.active && s.id == id && s.pid == pid && string(s.key[:s.length]) == key {
			return true
		}
	}
	for i := range settingsSubscriptions {
		s := &settingsSubscriptions[i]
		if s.active {
			continue
		}
		s.active = true
		s.id = id
		s.pid = pid
		s.length = uint8(len(key))
		copy(s.key[:], key)
		return true
	}
	return false
}

func applySettingsPublish(req vi.WmRpc) bool {
	key := req.TitleString()
	if req.ReplyTo == 0 || tabs.index(uint32(req.ID)) < 0 || !settings.Editable(key) {
		return false
	}
	file := loadSettingsForBus()
	if file.State != settings.StateOK {
		return false
	}
	value, ok := file.Effective(key)
	if !ok || !updateSettingsBusValue(key, value) {
		return false
	}
	if key == "theme" {
		_ = theme.Set(value)
	}
	// The a11y.contrast switch applies live like `theme=`: the next
	// composite repaints the seat's chrome out of the table it selects.
	if settings.IsA11yContrastKey(key) {
		if high, ok := settings.A11yContrast(value); ok {
			theme.SetContrast(high)
		}
	}
	if settings.IsNotifyDNDKey(key) {
		applyNotifyDNDSetting(value)
	}
	listeners := broadcastSettingsChange(key)
	vi.ConsoleLine(MarkerSettingsBroadcast + key + " listeners=" + vi.Itoa64(int64(listeners)))
	return true
}

// seedSettingsBusValues records the effective startup table. The seat only
// broadcasts an actual value transition, not a duplicate or an unpersisted
// writer claim.
func seedSettingsBusValues(file settings.File) {
	for i := range settingsBusValues {
		settingsBusValues[i] = settingValue{}
	}
	i := 0
	appendKey := func(key string) {
		if i >= len(settingsBusValues) {
			return
		}
		if value, ok := file.Effective(key); ok {
			settingsBusValues[i] = settingValue{key: key, value: value}
			i++
		}
	}
	for _, key := range settings.KnownKeys {
		appendKey(key.Name)
	}
	for _, key := range settings.PaletteKeys {
		appendKey(key.Name)
	}
	for _, key := range settings.FontKeys {
		appendKey(key.Name)
	}
	for _, key := range settings.NotifyKeys {
		appendKey(key.Name)
	}
	for _, key := range settings.A11yKeys {
		appendKey(key.Name)
	}
}

func updateSettingsBusValue(key, value string) bool {
	for i := range settingsBusValues {
		if settingsBusValues[i].key != key {
			continue
		}
		if settingsBusValues[i].value == value {
			return false
		}
		settingsBusValues[i].value = value
		return true
	}
	return false
}

func broadcastSettingsChange(key string) int {
	listeners := 0
	for _, s := range settingsSubscriptions {
		if !s.active || string(s.key[:s.length]) != key {
			continue
		}
		var event vi.WmRpc
		event.Kind = vi.WmRpcKindSettingsChanged
		event.ID = s.id
		event.SetTitle(key)
		// M97g-F2 (#2080): a bound window accepts only notices quoting its
		// session token — carry it so the client's own auth check passes.
		if b := rpcBindings[s.id]; b.token != 0 {
			event.Pad = vi.WmRpcPadBound
			vi.SetWmAuth(&event, b.token)
		}
		if sendSettingsNotice(uint32(s.pid), event.Encode()) >= 0 {
			listeners++
		}
	}
	return listeners
}

// Called at TabStrip.CloseTab's single teardown point so an id reused by a
// later app cannot inherit a prior app's subscriptions.
func clearSettingsSubscriptions(id uint32) {
	for i := range settingsSubscriptions {
		if settingsSubscriptions[i].active && uint32(settingsSubscriptions[i].id) == id {
			settingsSubscriptions[i] = settingSubscription{}
		}
	}
}

func resetSettingsSubscriptions() {
	settingsSubscriptions = [maxSettingsSubscriptions]settingSubscription{}
}
