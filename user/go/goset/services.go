package main

import (
	"bytes"
	"errors"
	"strings"

	"virelai/svcgraph"
	"virelai/svcmanifest"
	"virelai/vi"
)

var consoleLine = vi.ConsoleLine

type serviceStore struct {
	read    func(string, int) ([]byte, int64)
	stage   func(string, []byte) int64
	publish func(string) int64
}

// vi.WriteFileSafe split at the rename. stageFile leaves the body durable in
// the `~` sibling, which no poller reads; publishFile's delete+rename is the
// one moment the new bytes become observable at path. Splitting them lets
// Save's receipts land while the new manifest is still invisible to init's
// ~1ms reloader — otherwise `svc: start` can interpose between the rename and
// the `goset: service saved` receipt it was caused by (the toggle race).
func stageFile(path string, b []byte) int64 {
	tmp := path + "~"
	// The `path + "~"` concat must sit at the FileOpen call site: the M81e2
	// publish guard reads it literally to exempt the sacrificial temp.
	h, r := vi.FileOpen(path+"~", vi.ModeWrite|vi.ModeCreate)
	if r < 0 {
		return r
	}
	if _, wr := vi.FileWriteAll(uint32(h), b); wr < 0 {
		vi.FileClose(uint32(h))
		_ = vi.FileDelete(tmp)
		return wr
	}
	if rc := vi.FileSync(uint32(h)); rc < 0 {
		vi.FileClose(uint32(h))
		_ = vi.FileDelete(tmp)
		return rc
	}
	vi.FileClose(uint32(h))
	return 0
}

func publishFile(path string) int64 {
	tmp := path + "~"
	if rc := vi.FileDelete(path); rc < 0 && rc != vi.ErrFileNotFound {
		_ = vi.FileDelete(tmp)
		return rc
	}
	if rc := vi.FileRename(tmp, path); rc < 0 {
		_ = vi.FileDelete(tmp)
		return rc
	}
	return 0
}

type servicesView struct {
	store    serviceStore
	manifest svcmanifest.Manifest
	body     []byte
	reason   string
}

func serviceReason(err error) string {
	if schema, ok := err.(*svcmanifest.Error); ok {
		return string(schema.Code)
	}
	return err.Error()
}

func serviceGraph(m svcmanifest.Manifest) error {
	if err := svcmanifest.Validate(m); err != nil {
		return err
	}
	var nodes []svcgraph.Node
	for _, s := range m.Services {
		if s.Enabled {
			nodes = append(nodes, svcgraph.Node{Name: s.Name, Requires: s.Requires, Wants: s.Wants})
		}
	}
	_, _, err := svcgraph.Resolve(nodes)
	return err
}

// Keep the last valid rows visible on refusal, but make the whole view
// read-only. Never heal a document that init refused.
func (v *servicesView) Refresh() bool {
	body, rc := v.store.read(svcmanifest.Path, svcmanifest.MaxBytes+1)
	if rc < 0 {
		reason := "manifest-read"
		if rc == -vi.ErrENOENT {
			reason = "missing-manifest"
		}
		changed := v.reason != reason
		v.reason = reason
		return changed
	}
	if v.reason == "" && bytes.Equal(v.body, body) {
		return false
	}
	m, err := svcmanifest.Parse(body)
	if err == nil {
		err = serviceGraph(m)
	}
	if err != nil {
		reason := serviceReason(err)
		changed := v.reason != reason || !bytes.Equal(v.body, body)
		v.reason, v.body = reason, append(v.body[:0], body...)
		return changed
	}
	v.manifest, v.body, v.reason = m, append(v.body[:0], body...), ""
	return true
}

func (v *servicesView) Labels() []string {
	var rows []string
	for _, s := range v.manifest.Services {
		line := s.Name + "  " + s.Class + "  enabled=" + serviceState(s.Enabled)
		if s.Class == "boot" {
			line += "  (applies at next boot)"
		}
		rows = append(rows, line)
	}
	return rows
}

func serviceState(enabled bool) string {
	if enabled {
		return "on"
	}
	return "off"
}

func (v *servicesView) Set(name string, enabled bool) error {
	if v.reason != "" {
		return errors.New(v.reason)
	}
	for i := range v.manifest.Services {
		if v.manifest.Services[i].Name == name {
			v.manifest.Services[i].Enabled = enabled
			return nil
		}
	}
	return errors.New("unknown-service")
}

func (v *servicesView) Save(receipts func()) error {
	// Re-read before publishing, so a corrupt or concurrently replaced file
	// cannot be overwritten by an old panel. Refresh reports it in the UI.
	body, rc := v.store.read(svcmanifest.Path, svcmanifest.MaxBytes+1)
	if rc < 0 || !bytes.Equal(body, v.body) {
		v.Refresh()
		if v.reason != "" {
			return errors.New(v.reason)
		}
		return errors.New("config-changed")
	}
	if v.reason != "" {
		return errors.New(v.reason)
	}
	if err := serviceGraph(v.manifest); err != nil {
		return err
	}
	body, err := svcmanifest.Format(v.manifest)
	if err != nil {
		return err
	}
	if rc = v.store.stage(svcmanifest.Path, body); rc < 0 {
		return errors.New("manifest-write rc=" + vi.Itoa64(rc))
	}
	// Receipts are the ordering anchor: the staged manifest is durable but
	// still invisible at svcmanifest.Path, so they hit the serial before any
	// poller can observe the publish and answer it with `svc: start`.
	if receipts != nil {
		receipts()
	}
	if rc = v.store.publish(svcmanifest.Path); rc < 0 {
		return errors.New("manifest-publish rc=" + vi.Itoa64(rc))
	}
	v.body = append(v.body[:0], body...)
	return nil
}

// M122e (#2574): the open moved into panel.showTab — the tab-strip cell,
// the typed `services` line and Esc's pop all land the same switch.

func (a *panel) serviceStatus() {
	if a.services.reason != "" {
		a.status = "services refused: " + a.services.reason + " (read-only)"
		consoleLine("goset: services refuse " + a.services.reason)
		return
	}
	a.status = "name=on|off + Enter, click a row, or Tab then Left/Right, Enter; Esc returns"
}

func (a *panel) serviceInput() {
	line := strings.TrimSpace(a.input.Value())
	a.input.Clear()
	if line == "settings" {
		a.showTab(tabSettings)
		return
	}
	if line != "" {
		name, value, ok := strings.Cut(line, "=")
		if !ok || value != "on" && value != "off" {
			a.status = "services: name=on or name=off"
			return
		}
		if err := a.services.Set(name, value == "on"); err != nil {
			a.status = "services refused: " + serviceReason(err)
			consoleLine("goset: services refuse " + serviceReason(err))
			return
		}
	}
	a.saveServices()
}

func (a *panel) saveServices() {
	err := a.services.Save(func() {
		for _, s := range a.services.manifest.Services {
			consoleLine("goset: service saved name=" + s.Name + " enabled=" + serviceState(s.Enabled))
		}
	})
	if err != nil {
		a.status = "services refused: " + serviceReason(err)
		consoleLine("goset: services refuse " + serviceReason(err))
		return
	}
	a.status = "saved " + svcmanifest.Path
}
